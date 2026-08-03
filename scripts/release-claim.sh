#!/usr/bin/env bash
# release-claim.sh — post-merge cleanup (docs/05, Law 10)
set -euo pipefail

usage() {
  cat <<'EOF'
release-claim.sh — release a claim after merge (cleanup)

WHAT IT DOES
  Finds the claim row for an issue, removes the git worktree and local branch,
  deletes the claim row with a signed commit on main, removes the agent-claimed
  label, and optionally deletes the remote feature branch.

  It never moves the canonical checkout off its current branch: the claim-row
  commit happens in a disposable worktree on main (L-009). Sibling claims on the
  same issue survive unless you name them (L-024), and the label removal is
  verified rather than assumed (L-027).

WHY
  Abandoned claims block the fleet (Law 10). Cleanup must be as automatic as claim.

RISKS
  - Deletes worktree directory (uncommitted work there is lost). Check first.
  - Commits to main (claim-row removal only), from a temporary worktree.
  - Removes GitHub label. Low risk; re-claim if you still need the issue.

USAGE
  release-claim.sh <issue> [--claim-id <id>] [--prefix <ns>] [--repo owner/name]
                           [--keep-branch] [--keep-label] [--dry-run]
  release-claim.sh --help

  <issue>        issue number, e.g. 42
  --claim-id     release exactly this claim id (e.g. issue-42-password-reset)
                 and leave every sibling row for the issue alone (L-024)
  --prefix       namespace for cross-repo claim ids: --prefix template matches
                 issue-template-<N>-* as well as issue-<N>-* (L-036 / L-037)
  --repo         product repo for the issue/label, when the issue does not live
                 in the claim-table repo (L-037)
  --keep-branch  do not delete the local/remote feature branch
  --keep-label   keep agent-claimed even when the ledger has no residual row
                 for this issue (live sibling lane whose claim file is absent
                 or lives elsewhere). Verifies the live GitHub label is present
                 (exit 3 if the product repo is unresolved or the label is
                 absent/unreadable). Without this flag, a no-residual cleanup
                 removes the label — the final completed lane path.
  --dry-run      print what would happen, touch nothing

  Matching: issue-<N>-* plus issue-<alpha-ns>-<N>-*. issue-1<N>-* never matches.
  Bare multi-claim: if more than one live claim exists for the issue and you
  did not pass --claim-id, the script refuses (exit 1) before any plan or
  mutation and prints the exact ids so you can pick one. A single live claim
  may still be released with the bare form; that exact id is frozen first.
  --claim-id is always a *literal* exact id (never an ERE/glob). It must
  belong to the positional issue (and --prefix when given). Legacy table
  rows are matched on the claim-id column only — text in scope/session/notes
  never selects or deletes a row.

  Empty ledger: when a *valid* ledger ref with a *readable* tree has no
  docs/claims/* and no docs/active-work.md tree entry, that is a valid empty
  ledger (no live claims), not a hard fail. A missing/unborn/invalid
  main|master ref, a commit whose referenced tree is unavailable/corrupt, or
  a ledger path that still exists in the tree but whose blob/object is
  unreadable/corrupt, is NOT an empty ledger — the script fails hard before
  any label mutation. True path absence is allowed; unreadable live blobs are
  not. Cleanup of worktrees/labels can still complete truthfully without
  inventing a row when the ref is valid, the tree is readable, and the ledger
  is empty.

ENV
  GIBSON_CANONICAL   claim-table repo path (default: cwd)

EXIT
  0  claim fully released (or truthfully nothing to release + label policy done)
  1  a hard precondition failed (nothing was cleaned)
  3  cleanup ran but did not finish: the claim row and/or the agent-claimed
     label postcondition is incomplete. Strip/push failure, a target still
     live after cleanup, or a failed/unreadable post-mutation reread preserves
     agent-claimed and never claims the label was removed. The message names
     which. Never silent half-cleanup (L-009).

EXAMPLES
  cd ~/Code/acme-app
  /path/to/the-gibson/scripts/release-claim.sh 42

  # multi-slice issue: release only the merged slice, keep the residual lane
  release-claim.sh 15 --claim-id issue-15-checkout-totals

  # empty ledger + live sibling still working the issue (no claim file on main)
  release-claim.sh 18 --repo acme/app --keep-label

  # empty ledger + final lane done: remove agent-claimed (default)
  release-claim.sh 18 --repo acme/app

  # cross-repo template work: claim row in the monorepo, issue in the template repo
  GIBSON_CANONICAL=~/Code/monorepo \
    release-claim.sh 5 --prefix template --repo acme/acme-template

  GIBSON_CANONICAL=~/Code/acme-app release-claim.sh 42 --dry-run
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
  exit 2
fi

ISSUE="$1"
shift || true
KEEP_BRANCH=0
KEEP_LABEL=0
DRY=0
CLAIM_ID_ARG=""
CLAIM_ID_SET=0
PREFIX=""
REPO_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-branch) KEEP_BRANCH=1 ;;
    --keep-label) KEEP_LABEL=1 ;;
    --dry-run) DRY=1 ;;
    --claim-id)
      CLAIM_ID_SET=1
      CLAIM_ID_ARG="${2:-}"
      shift
      ;;
    --prefix) PREFIX="${2:-}"; shift ;;
    --repo) REPO_ARG="${2:-}"; shift ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

CANONICAL="${GIBSON_CANONICAL:-$(pwd)}"
die() { echo "release-claim.sh: ERROR: $*" >&2; exit 1; }
info() { echo "release-claim.sh: $*"; }
warn() { echo "release-claim.sh: WARNING: $*" >&2; }

[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue must be a number, got '$ISSUE'"
if [[ -n "$PREFIX" && ! "$PREFIX" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]]; then
  die "--prefix must start with a letter, got '$PREFIX'"
fi
if [[ "$CLAIM_ID_SET" -eq 1 && -z "$CLAIM_ID_ARG" ]]; then
  die "--claim-id requires a non-empty literal claim id"
fi

cd "$CANONICAL"
git fetch origin >/dev/null 2>&1 || true

# Resolve the ledger ref. Prefer origin/main, then origin/master, then local
# main/master. An unborn, missing, or non-commit ref is a hard fail — never
# treat a failed ref read as an "empty ledger".
resolve_ledger_ref() {
  local candidate
  for candidate in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

REF=""
if ! REF=$(resolve_ledger_ref); then
  die "cannot resolve a valid ledger commit ref (tried origin/main, origin/master, main, master). A missing/unborn/invalid ref is not an empty ledger — fix the remote or pass a claim-table checkout with a real main."
fi
info "ledger ref: $REF ($(git rev-parse --short "$REF" 2>/dev/null || echo '?'))"

# The commit object resolving is not enough: the referenced tree must be
# readable. A missing/corrupt tree is NOT an empty ledger — hard-fail before
# any label mutation or "no live claims" classification.
if ! git rev-parse --verify --quiet "${REF}^{commit}" >/dev/null 2>&1; then
  die "ledger ref $REF does not resolve to a commit object — not an empty ledger"
fi
# Prefer peeling ^{tree}; if the object store cannot peel (deleted tree object),
# fall back to the commit's tree field so we can still name the missing SHA.
TREE_SHA=$(git rev-parse --verify "${REF}^{tree}" 2>/dev/null || true)
if [[ -z "$TREE_SHA" ]]; then
  TREE_SHA=$(git cat-file -p "${REF}^{commit}" 2>/dev/null | awk '/^tree / {print $2; exit}')
fi
[[ -n "$TREE_SHA" ]] || \
  die "ledger commit at $REF has no tree pointer — unreadable/corrupt tree is not an empty ledger; refuse label mutation"
if ! git cat-file -e "$TREE_SHA" 2>/dev/null; then
  die "ledger commit at $REF references an unreadable/corrupt tree ($TREE_SHA) — not an empty ledger; refuse label mutation until the object store is repaired"
fi
# Prove the tree is listable (cat-file -e alone is not enough on some stores).
if ! git ls-tree "$TREE_SHA" >/dev/null 2>&1; then
  die "cannot list tree for ledger commit $REF (unreadable/corrupt tree $TREE_SHA) — not an empty ledger; refuse label mutation"
fi

# A missing docs/claims path and absent active-work.md on a *valid, readable*
# tree is a valid *empty* ledger (every claim already released, or never filed)
# — not corruption. Treat it as zero live claims and continue label/worktree
# cleanup. A named --claim-id that is not present still hard-fails below.
# Tree-read failures above already exited; do not reclassify them as empty.
#
# Inspect tree entries first. git cat-file -e ref:path fails both when the
# path is absent AND when the path exists but its blob is missing/corrupt.
# Only true absence is an empty-ledger signal; an unreadable live blob must
# hard-fail before any label mutation.
#
# Fail-closed for the *per-file* ledger too: listing docs/claims/ by pathname
# alone is not enough. Every live tree entry under docs/claims/ must be a
# readable regular blob (mode 100644/100755) before any worktree, branch,
# claim-row, or label cleanup proceeds. A missing/corrupt claim blob is not
# an empty ledger (same contract as docs/active-work.md).
HAS_ACTIVE=0
HAS_CLAIMS_TREE=0

# Prove a tree line is a readable regular blob (legacy table or per-claim file).
# Args: path mode type object-sha
require_readable_regular_blob() {
  local path="$1" mode="$2" typ="$3" obj="$4"
  if [[ "$typ" != "blob" ]] || [[ "$mode" != "100644" && "$mode" != "100755" ]]; then
    die "$path at $REF has unexpected Git mode/type ($mode $typ${obj:+ $obj}) — refuse mutation until the ledger is repaired"
  fi
  if [[ -z "$obj" ]]; then
    die "$path at $REF has no object id — unreadable/corrupt ledger entry; refuse mutation"
  fi
  if ! git cat-file -e "$obj" 2>/dev/null; then
    die "$path exists in the ledger tree at $REF but its blob is unreadable/corrupt/unfetchable ($obj) — not an empty ledger; refuse label mutation until the object store is repaired"
  fi
  local got_type
  got_type=$(git cat-file -t "$obj" 2>/dev/null || true)
  if [[ "$got_type" != "blob" ]]; then
    die "$path at $REF object $obj has unexpected type '${got_type:-unreadable}' (want blob) — refuse mutation until the object store is repaired"
  fi
  # Prove the payload is fetchable, not only that the object header exists.
  if ! git cat-file blob "$obj" >/dev/null 2>&1; then
    die "$path exists in the ledger tree at $REF but its blob payload is unreadable/corrupt ($obj) — not an empty ledger; refuse label mutation until the object store is repaired"
  fi
}

ACTIVE_LS_ERR=""
ACTIVE_LINE=$(git ls-tree "$REF" -- docs/active-work.md 2>&1) || {
  ACTIVE_LS_ERR=$?
}
if [[ -n "$ACTIVE_LS_ERR" ]]; then
  die "cannot list docs/active-work.md at $REF (git ls-tree failed) — unreadable ledger tree is not an empty ledger"
fi
if [[ -n "$ACTIVE_LINE" ]]; then
  # Entry exists in the tree — mode/type + blob must be a readable regular file.
  active_mode=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $1; exit}')
  active_type=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $2; exit}')
  active_blob=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $3; exit}')
  require_readable_regular_blob "docs/active-work.md" "$active_mode" "$active_type" "$active_blob"
  HAS_ACTIVE=1
fi

# docs/claims self-entry: absent is empty; present must be a tree (not a blob
# /symlink/gitlink). Then every child must be a readable regular blob.
CLAIMS_SELF_ERR=""
CLAIMS_SELF=$(git ls-tree "$REF" -- docs/claims 2>&1) || {
  CLAIMS_SELF_ERR=$?
}
if [[ -n "$CLAIMS_SELF_ERR" ]]; then
  die "cannot list docs/claims at $REF (git ls-tree failed) — unreadable ledger tree is not an empty ledger"
fi
if [[ -n "$CLAIMS_SELF" ]]; then
  claims_self_mode=$(printf '%s\n' "$CLAIMS_SELF" | awk '{print $1; exit}')
  claims_self_type=$(printf '%s\n' "$CLAIMS_SELF" | awk '{print $2; exit}')
  claims_self_obj=$(printf '%s\n' "$CLAIMS_SELF" | awk '{print $3; exit}')
  if [[ "$claims_self_type" != "tree" ]] || [[ "$claims_self_mode" != "040000" ]]; then
    die "docs/claims at $REF has unexpected Git mode/type ($claims_self_mode $claims_self_type${claims_self_obj:+ $claims_self_obj}) — want 040000 tree; refuse mutation until the ledger is repaired"
  fi
  if [[ -z "$claims_self_obj" ]] || ! git cat-file -e "$claims_self_obj" 2>/dev/null; then
    die "docs/claims tree at $REF is unreadable/corrupt${claims_self_obj:+ ($claims_self_obj)} — not an empty ledger; refuse label mutation until the object store is repaired"
  fi
  if ! git ls-tree "$claims_self_obj" >/dev/null 2>&1; then
    die "cannot list docs/claims tree at $REF (unreadable/corrupt tree ${claims_self_obj}) — not an empty ledger; refuse label mutation"
  fi

  # Enumerate *exact* live children from the authoritative ref. Pathname-only
  # matching without blob proof is how a missing claim object slipped through
  # to label/worktree mutation (issue #61).
  CLAIMS_LS_ERR=""
  CLAIMS_LINES=$(git ls-tree "$REF" docs/claims/ 2>&1) || {
    CLAIMS_LS_ERR=$?
  }
  if [[ -n "$CLAIMS_LS_ERR" ]]; then
    die "cannot read docs/claims/ at $REF (git ls-tree failed) — unreadable ledger tree is not an empty ledger"
  fi
  if [[ -n "$CLAIMS_LINES" ]]; then
    HAS_CLAIMS_TREE=1
    while IFS= read -r claim_line; do
      [[ -n "$claim_line" ]] || continue
      claim_mode=$(printf '%s\n' "$claim_line" | awk '{print $1; exit}')
      claim_type=$(printf '%s\n' "$claim_line" | awk '{print $2; exit}')
      claim_obj=$(printf '%s\n' "$claim_line" | awk '{print $3; exit}')
      # Path is after the first tab (mode SP type SP object TAB path).
      claim_path="${claim_line#*$'\t'}"
      [[ -n "$claim_path" ]] || claim_path="docs/claims/<unknown>"
      require_readable_regular_blob "$claim_path" "$claim_mode" "$claim_type" "$claim_obj"
    done <<EOF
$CLAIMS_LINES
EOF
  fi
fi

if [[ "$HAS_ACTIVE" -eq 0 && "$HAS_CLAIMS_TREE" -eq 0 ]]; then
  info "claim ledger at $REF is empty (no docs/claims/* and no docs/active-work.md) — treating as no live claims"
fi

# Claims live one-per-file in docs/claims/ (L-023); rows in docs/active-work.md
# are the legacy form and are still released. Prints *all* live claim ids
# (deduped, sorted) on stdout — never filters by ERE. Returns 1 if the ledger
# tree cannot be read (caller must hard-fail — never treat a failed tree read
# as an empty match set).
# Startup already proved every live claims/* blob is a readable regular file;
# re-check here so a mid-run object-store loss still fails closed instead of
# inventing ids from pathnames alone.
claim_ids_all() {
  local claims_out active_out active_entry active_blob claims_line
  local c_mode c_type c_obj
  claims_out=""
  if ! claims_line=$(git ls-tree "$REF" -- docs/claims 2>/dev/null); then
    echo "release-claim.sh: ERROR: cannot list docs/claims at $REF — unreadable ledger tree is not an empty ledger" >&2
    return 1
  fi
  if [[ -n "$claims_line" ]]; then
    c_mode=$(printf '%s\n' "$claims_line" | awk '{print $1; exit}')
    c_type=$(printf '%s\n' "$claims_line" | awk '{print $2; exit}')
    c_obj=$(printf '%s\n' "$claims_line" | awk '{print $3; exit}')
    if [[ "$c_type" != "tree" ]] || [[ "$c_mode" != "040000" ]]; then
      echo "release-claim.sh: ERROR: docs/claims at $REF has unexpected Git mode/type ($c_mode $c_type${c_obj:+ $c_obj}) — want 040000 tree" >&2
      return 1
    fi
    if ! claims_out=$(git ls-tree --name-only "$REF" docs/claims/ 2>/dev/null); then
      echo "release-claim.sh: ERROR: cannot list docs/claims/ at $REF — unreadable ledger tree is not an empty ledger" >&2
      return 1
    fi
    # Pathname list is only valid when every listed object is still a readable blob.
    local entry_line entry_mode entry_type entry_obj entry_path
    while IFS= read -r entry_line; do
      [[ -n "$entry_line" ]] || continue
      entry_mode=$(printf '%s\n' "$entry_line" | awk '{print $1; exit}')
      entry_type=$(printf '%s\n' "$entry_line" | awk '{print $2; exit}')
      entry_obj=$(printf '%s\n' "$entry_line" | awk '{print $3; exit}')
      entry_path="${entry_line#*$'\t'}"
      if [[ "$entry_type" != "blob" ]] || [[ "$entry_mode" != "100644" && "$entry_mode" != "100755" ]]; then
        echo "release-claim.sh: ERROR: ${entry_path:-docs/claims/<unknown>} at $REF has unexpected Git mode/type ($entry_mode $entry_type${entry_obj:+ $entry_obj})" >&2
        return 1
      fi
      if [[ -z "$entry_obj" ]] || ! git cat-file -e "$entry_obj" 2>/dev/null; then
        echo "release-claim.sh: ERROR: ${entry_path:-docs/claims/<unknown>} exists in the ledger tree at $REF but its blob is unreadable/corrupt${entry_obj:+ ($entry_obj)} — not an empty ledger" >&2
        return 1
      fi
    done <<EOF
$(git ls-tree "$REF" docs/claims/ 2>/dev/null || true)
EOF
  fi
  active_out=""
  # Tree entry first: absence is empty content; present-but-unreadable hard-fails.
  if ! active_entry=$(git ls-tree "$REF" -- docs/active-work.md 2>/dev/null); then
    echo "release-claim.sh: ERROR: cannot list docs/active-work.md at $REF — unreadable ledger tree is not an empty ledger" >&2
    return 1
  fi
  if [[ -n "$active_entry" ]]; then
    active_blob=$(printf '%s\n' "$active_entry" | awk '{print $3; exit}')
    if ! git cat-file -e "${active_blob:-$REF:docs/active-work.md}" 2>/dev/null; then
      echo "release-claim.sh: ERROR: docs/active-work.md exists in the ledger tree at $REF but its blob is unreadable/corrupt${active_blob:+ ($active_blob)} — not an empty ledger" >&2
      return 1
    fi
    if ! active_out=$(git show "$REF:docs/active-work.md" 2>/dev/null); then
      echo "release-claim.sh: ERROR: cannot read docs/active-work.md at $REF — unreadable/corrupt blob is not an empty ledger" >&2
      return 1
    fi
  elif ! git cat-file -e "$TREE_SHA" 2>/dev/null; then
    echo "release-claim.sh: ERROR: ledger tree $TREE_SHA became unreadable while matching claims — not an empty ledger" >&2
    return 1
  fi
  {
    printf '%s\n' "$claims_out" |
      sed 's|^docs/claims/||;s|\.md$||'
    # Legacy table: claim-id is column 3 only. Never scan scope/session/notes.
    printf '%s\n' "$active_out" |
      grep -E '^\| ' |
      awk -F'|' '{print $3}' |
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
  } | grep -E '^issue-' | sort -u || true
  return 0
}

# True when claim id $1 belongs to the positional issue (and --prefix when set).
# issue-1<N>- never matches issue-<N>-. Alpha namespace is optional without --prefix.
claim_id_for_issue() {
  local id="$1"
  [[ -n "$id" ]] || return 1
  if [[ -n "$PREFIX" ]]; then
    case "$id" in
      "issue-${ISSUE}-"*) return 0 ;;
      "issue-${PREFIX}-${ISSUE}-"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "$id" in
    "issue-${ISSUE}-"*) return 0 ;;
  esac
  # Optional alpha namespace: issue-<ns>-<N>-… (ns starts with a letter).
  if [[ "$id" =~ ^issue-[A-Za-z][A-Za-z0-9]*-${ISSUE}- ]]; then
    return 0
  fi
  return 1
}

# Filter a newline list of ids down to those belonging to this issue.
issue_claim_ids_from() {
  local id
  printf '%s\n' "$1" | while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if claim_id_for_issue "$id"; then
      printf '%s\n' "$id"
    fi
  done | sort -u
}

ALL_LIVE_IDS=$(claim_ids_all) || \
  die "cannot read claim ledger at $REF — unreadable tree is not an empty ledger"
# Every live row for this issue (broad: any alpha-ns or bare issue-N), so we
# can tell "released the last one" from "released one slice of several" (L-024).
ALL_IDS=$(issue_claim_ids_from "$ALL_LIVE_IDS")
TARGET_IDS=""

if [[ "$CLAIM_ID_SET" -eq 1 ]]; then
  # --claim-id is always a *literal* exact id. Reject empty, ERE/glob-looking,
  # and malformed values before any mutation. Never pass the arg through grep -E.
  if [[ ! "$CLAIM_ID_ARG" =~ ^issue-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    die "--claim-id must be a literal exact claim id (no wildcards/regex); got '$CLAIM_ID_ARG'"
  fi
  if ! claim_id_for_issue "$CLAIM_ID_ARG"; then
    die "--claim-id '$CLAIM_ID_ARG' does not belong to issue $ISSUE${PREFIX:+ (prefix $PREFIX)}"
  fi
  if ! printf '%s\n' "$ALL_IDS" | grep -qxF -- "$CLAIM_ID_ARG"; then
    if printf '%s\n' "$ALL_LIVE_IDS" | grep -qxF -- "$CLAIM_ID_ARG"; then
      die "--claim-id '$CLAIM_ID_ARG' is live but not a claim for issue $ISSUE${PREFIX:+ (prefix $PREFIX)}"
    fi
    die "no live claim '$CLAIM_ID_ARG' at $REF"
  fi
  # Exactly one logical match (legacy + per-file already deduped by sort -u).
  TARGET_IDS="$CLAIM_ID_ARG"
else
  # Bare invocation: freeze zero or one exact id. Never carry a broad issue
  # regex into cleanup. Multi-claim without --claim-id is a hard refuse.
  n_issue=0
  if [[ -n "$ALL_IDS" ]]; then
    n_issue=$(printf '%s\n' "$ALL_IDS" | grep -c . || true)
  fi
  if [[ "$n_issue" -gt 1 ]]; then
    echo "release-claim.sh: ERROR: issue $ISSUE has ${n_issue} live claims; pass --claim-id with exactly one of:" >&2
    printf '%s\n' "$ALL_IDS" | sed 's/^/  /' >&2
    exit 1
  fi
  if [[ "$n_issue" -eq 1 ]]; then
    TARGET_IDS=$(printf '%s\n' "$ALL_IDS")
    info "bare release freezes single claim id: $TARGET_IDS"
  fi
fi

if [[ -z "$TARGET_IDS" ]]; then
  info "no live claim for issue $ISSUE — will still try label/worktree cleanup"
fi

WT_PARENT="$(cd "$CANONICAL/.." && pwd)"

# Worktree/branch per released claim id, derived from the id rather than
# assumed, so namespaced ids (issue-template-5-x) resolve correctly (L-037).
wt_dir_for() { echo "$WT_PARENT/wt-${1#issue-}"; }
branch_for() { echo "feat/${1#issue-}"; }

residual_after_release() {
  # ids in ALL_IDS that are not in TARGET_IDS (exact id compare only)
  local id
  printf '%s\n' "$ALL_IDS" | while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    printf '%s\n' "$TARGET_IDS" | grep -qxF -- "$id" || printf '%s\n' "$id"
  done
}
RESIDUAL_IDS=$(residual_after_release)

if [[ "$DRY" -eq 1 ]]; then
  echo "DRY RUN would:"
  echo "  claim-table repo: $CANONICAL (branch: $(git rev-parse --abbrev-ref HEAD), left untouched)"
  echo "  product repo:     ${REPO_ARG:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '(gh default)')}"
  if [[ -n "$TARGET_IDS" ]]; then
    printf '%s\n' "$TARGET_IDS" | while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      echo "  release claim:   $id"
      echo "    remove worktree: $(wt_dir_for "$id")"
      echo "    delete branch:   $(branch_for "$id")"
    done
  else
    echo "  release claim:   (none matched for issue $ISSUE)"
  fi
  if [[ -n "$RESIDUAL_IDS" ]]; then
    printf '%s\n' "$RESIDUAL_IDS" | while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      echo "  KEEP sibling claim: $id (and keep the agent-claimed label)"
    done
  elif [[ "$KEEP_LABEL" -eq 1 ]]; then
    echo "  KEEP label agent-claimed on #$ISSUE (--keep-label: live sibling outside ledger)"
  else
    echo "  remove label agent-claimed from #$ISSUE"
  fi
  exit 0
fi

INCOMPLETE=0

# --- worktrees + branches -------------------------------------------------
if [[ -n "$TARGET_IDS" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    wt=$(wt_dir_for "$id")
    if [[ -d "$wt" ]]; then
      info "removing worktree $wt"
      git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    fi
    if [[ "$KEEP_BRANCH" -eq 0 ]]; then
      br=$(branch_for "$id")
      git branch -D "$br" 2>/dev/null || true
      git push origin --delete "$br" 2>/dev/null || true
    fi
  done <<EOF
$TARGET_IDS
EOF
  git worktree prune 2>/dev/null || true
fi

# --- claim rows, from a disposable main worktree --------------------------
# L-009: never `git checkout main` in the caller's tree. It may be on a
# long-lived branch or dirty, and aborting here used to strand the claim row.
#
# CLEANUP_BASE / CLEANUP_PUSHED_SHA / CLEANUP_DID_PUSH are written for the
# post-mutation reread: that path must bind only to origin/$CLEANUP_BASE (the
# exact remote branch that received the cleanup push) and prove it contains
# $CLEANUP_PUSHED_SHA. Never fall back to local main|master after mutation.
# After a successful cleanup push, missing/unreadable CLEANUP_PUSHED_SHA is a
# hard release failure — lineage proof is mandatory, never skippable.
CLEANUP_BASE=""
CLEANUP_PUSHED_SHA=""
CLEANUP_DID_PUSH=0

strip_claim_rows() {
  CLEANUP_PUSHED_SHA=""
  CLEANUP_DID_PUSH=0
  local base
  base=main
  git show-ref --verify --quiet refs/heads/main || base=master
  CLEANUP_BASE="$base"

  local tmpwt
  tmpwt=$(mktemp -d "${TMPDIR:-/tmp}/gibson-release-claim.XXXXXX") || return 1
  rm -rf "$tmpwt"

  git fetch origin "$base" >/dev/null 2>&1 || true
  git worktree add --detach "$tmpwt" "origin/$base" >/dev/null 2>&1 ||
    git worktree add --detach "$tmpwt" "$base" >/dev/null 2>&1 || return 1

  local rc=0
  (
    cd "$tmpwt" || exit 1
    local touched=0

    # per-lane claim files (current form) — exact id only
    local id
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      if [[ -f "docs/claims/$id.md" ]]; then
        git rm -q "docs/claims/$id.md" || exit 1
        touched=1
      fi
    done <<EOF
$TARGET_IDS
EOF

    # legacy shared table — compare only the claim-id column (field 3). Text
    # in scope/session/notes that mentions a target id must never delete a row.
    local active=docs/active-work.md
    if [[ -f "$active" ]]; then
      local tmp line cid keep id touched_legacy
      tmp=$(mktemp) || exit 1
      touched_legacy=0
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\| ]]; then
          cid=$(printf '%s\n' "$line" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          keep=1
          if [[ -n "$cid" && "$cid" != "claim-id" && "$cid" != "---" && ! "$cid" =~ ^-+$ ]]; then
            while IFS= read -r id; do
              [[ -n "$id" ]] || continue
              if [[ "$cid" == "$id" ]]; then
                keep=0
                touched_legacy=1
                break
              fi
            done <<EOF
$TARGET_IDS
EOF
          fi
          if [[ "$keep" -eq 1 ]]; then
            printf '%s\n' "$line" >> "$tmp"
          fi
        else
          printf '%s\n' "$line" >> "$tmp"
        fi
      done < "$active"
      if [[ "$touched_legacy" -eq 1 ]]; then
        mv "$tmp" "$active"
        git add "$active" || exit 1
        touched=1
      else
        rm -f "$tmp"
      fi
    fi

    [[ "$touched" -eq 1 ]] || exit 2  # nothing to strip
    git commit -s -q -m "release-claim: ${TARGET_IDS:-issue-${ISSUE}}

Post-merge cleanup per Law 10 / docs/05." || exit 1
    git push origin "HEAD:$base" || exit 1
  ) || rc=$?

  # Capture the exact pushed cleanup commit while the disposable worktree still
  # holds it — post-mutation reread must prove origin/$base contains this SHA.
  # Push already succeeded: capture failure is incomplete (exit 3 path), not a
  # re-run of strip — do not claim the row is still live, and do not skip lineage.
  if [[ $rc -eq 0 ]]; then
    CLEANUP_DID_PUSH=1
    CLEANUP_PUSHED_SHA=$(git -C "$tmpwt" rev-parse HEAD 2>/dev/null || true)
    if [[ -z "$CLEANUP_PUSHED_SHA" ]]; then
      warn "cleanup push succeeded but cleanup-pushed SHA is missing/unreadable — cannot prove lineage; preserving agent-claimed"
    fi
  fi

  git worktree remove --force "$tmpwt" >/dev/null 2>&1 || rm -rf "$tmpwt"
  git worktree prune >/dev/null 2>&1 || true
  return $rc
}

# Soft-fail twin of require_readable_regular_blob for post-mutation reread.
# Same predicates as #61 startup; returns 1 with an exact path/object reason
# instead of dying (mutation already ran → incomplete is exit 3, not 1).
soft_require_readable_regular_blob() {
  local path="$1" mode="$2" typ="$3" obj="$4"
  if [[ "$typ" != "blob" ]] || [[ "$mode" != "100644" && "$mode" != "100755" ]]; then
    warn "$path at $REF has unexpected Git mode/type ($mode $typ${obj:+ $obj}) — post-cleanup ledger unusable for label decision"
    return 1
  fi
  if [[ -z "$obj" ]]; then
    warn "$path at $REF has no object id — post-cleanup ledger unusable for label decision"
    return 1
  fi
  if ! git cat-file -e "$obj" 2>/dev/null; then
    warn "$path exists in the ledger tree at $REF but its blob is unreadable/corrupt/unfetchable ($obj) — post-cleanup ledger unusable for label decision"
    return 1
  fi
  local got_type
  got_type=$(git cat-file -t "$obj" 2>/dev/null || true)
  if [[ "$got_type" != "blob" ]]; then
    warn "$path at $REF object $obj has unexpected type '${got_type:-unreadable}' (want blob) — post-cleanup ledger unusable for label decision"
    return 1
  fi
  if ! git cat-file blob "$obj" >/dev/null 2>&1; then
    warn "$path exists in the ledger tree at $REF but its blob payload is unreadable/corrupt ($obj) — post-cleanup ledger unusable for label decision"
    return 1
  fi
  return 0
}

# Authoritative post-mutation reread of the exact remote-tracking ref that
# received the cleanup push (origin/$CLEANUP_BASE). Reuses #61's strict
# ref/tree/per-claim blob validation (fetch that branch → resolve only that
# origin ref → tree → active-work → claims tree → every claim leaf →
# claim_ids_all) and proves the ref contains the just-pushed cleanup commit.
# On success updates REF, TREE_SHA and sets POST_ISSUE_IDS to issue-scoped ids
# actually present. On any failure: warn the exact reason and return 1.
# NEVER falls back to local main|master, HEAD, a cached pre-mutation residual
# plan, or any other branch — that is how a stale empty local main falsely
# authorized remove-label after origin/$CLEANUP_BASE became unreadable.
authoritative_post_mutation_reread() {
  POST_ISSUE_IDS=""
  local base="${CLEANUP_BASE:-}"
  if [[ -z "$base" ]]; then
    warn "post-cleanup: cleanup base branch unset — cannot bind reread to the pushed remote ref; preserving agent-claimed"
    return 1
  fi
  local remote_ref="origin/${base}"

  # Fetch only the exact branch that received the cleanup push.
  if ! git fetch origin "$base" >/dev/null 2>&1; then
    warn "post-cleanup fetch of origin failed — cannot revalidate ledger ref ${remote_ref} for label decision; preserving agent-claimed"
    return 1
  fi

  # Strict: only origin/$base. No resolve_ledger_ref local main|master fallback.
  if ! git rev-parse --verify --quiet "${remote_ref}^{commit}" >/dev/null 2>&1; then
    warn "post-cleanup: exact remote ledger ref ${remote_ref} is absent/unreadable after fetch — preserving agent-claimed (no local fallback)"
    return 1
  fi

  # Just-pushed cleanup must be on that remote-tracking ref. After a successful
  # cleanup push, lineage proof is mandatory — never skip when the capture SHA
  # is empty/unreadable (that used to authorize remove-label + OK).
  if [[ "${CLEANUP_DID_PUSH:-0}" -eq 1 ]]; then
    if [[ -z "${CLEANUP_PUSHED_SHA:-}" ]]; then
      warn "post-cleanup: cleanup-pushed SHA missing/unreadable after successful push — cannot prove lineage on ${remote_ref}; preserving agent-claimed"
      return 1
    fi
    if ! git rev-parse --verify --quiet "${CLEANUP_PUSHED_SHA}^{commit}" >/dev/null 2>&1; then
      warn "post-cleanup: just-pushed cleanup commit ${CLEANUP_PUSHED_SHA} is unreadable — preserving agent-claimed"
      return 1
    fi
    if ! git merge-base --is-ancestor "$CLEANUP_PUSHED_SHA" "$remote_ref" 2>/dev/null; then
      warn "post-cleanup: ${remote_ref} does not contain just-pushed cleanup commit ${CLEANUP_PUSHED_SHA} — preserving agent-claimed"
      return 1
    fi
  fi

  REF="$remote_ref"
  if ! git rev-parse --verify --quiet "${REF}^{commit}" >/dev/null 2>&1; then
    warn "post-cleanup: ledger ref $REF does not resolve to a commit — preserving agent-claimed"
    return 1
  fi
  TREE_SHA=$(git rev-parse --verify "${REF}^{tree}" 2>/dev/null || true)
  if [[ -z "$TREE_SHA" ]]; then
    TREE_SHA=$(git cat-file -p "${REF}^{commit}" 2>/dev/null | awk '/^tree / {print $2; exit}')
  fi
  if [[ -z "$TREE_SHA" ]]; then
    warn "post-cleanup: ledger commit at $REF has no tree pointer — preserving agent-claimed"
    return 1
  fi
  if ! git cat-file -e "$TREE_SHA" 2>/dev/null; then
    warn "post-cleanup: ledger commit at $REF references an unreadable/corrupt tree ($TREE_SHA) — preserving agent-claimed"
    return 1
  fi
  if ! git ls-tree "$TREE_SHA" >/dev/null 2>&1; then
    warn "post-cleanup: cannot list tree for ledger commit $REF (unreadable/corrupt tree $TREE_SHA) — preserving agent-claimed"
    return 1
  fi

  local active_line active_ls_err="" claims_self claims_self_err="" claims_lines claims_ls_err=""
  active_line=$(git ls-tree "$REF" -- docs/active-work.md 2>&1) || active_ls_err=$?
  if [[ -n "$active_ls_err" ]]; then
    warn "post-cleanup: cannot list docs/active-work.md at $REF — preserving agent-claimed"
    return 1
  fi
  if [[ -n "$active_line" ]]; then
    local amode atype ablob
    amode=$(printf '%s\n' "$active_line" | awk '{print $1; exit}')
    atype=$(printf '%s\n' "$active_line" | awk '{print $2; exit}')
    ablob=$(printf '%s\n' "$active_line" | awk '{print $3; exit}')
    soft_require_readable_regular_blob "docs/active-work.md" "$amode" "$atype" "$ablob" || return 1
  fi

  claims_self=$(git ls-tree "$REF" -- docs/claims 2>&1) || claims_self_err=$?
  if [[ -n "$claims_self_err" ]]; then
    warn "post-cleanup: cannot list docs/claims at $REF — preserving agent-claimed"
    return 1
  fi
  if [[ -n "$claims_self" ]]; then
    local csmode cstype csobj
    csmode=$(printf '%s\n' "$claims_self" | awk '{print $1; exit}')
    cstype=$(printf '%s\n' "$claims_self" | awk '{print $2; exit}')
    csobj=$(printf '%s\n' "$claims_self" | awk '{print $3; exit}')
    if [[ "$cstype" != "tree" ]] || [[ "$csmode" != "040000" ]]; then
      warn "post-cleanup: docs/claims at $REF has unexpected Git mode/type ($csmode $cstype${csobj:+ $csobj}) — want 040000 tree; preserving agent-claimed"
      return 1
    fi
    if [[ -z "$csobj" ]] || ! git cat-file -e "$csobj" 2>/dev/null; then
      warn "post-cleanup: docs/claims tree at $REF is unreadable/corrupt${csobj:+ ($csobj)} — preserving agent-claimed"
      return 1
    fi
    if ! git ls-tree "$csobj" >/dev/null 2>&1; then
      warn "post-cleanup: cannot list docs/claims tree at $REF (unreadable/corrupt tree ${csobj}) — preserving agent-claimed"
      return 1
    fi
    claims_lines=$(git ls-tree "$REF" docs/claims/ 2>&1) || claims_ls_err=$?
    if [[ -n "$claims_ls_err" ]]; then
      warn "post-cleanup: cannot read docs/claims/ at $REF — preserving agent-claimed"
      return 1
    fi
    if [[ -n "$claims_lines" ]]; then
      local claim_line claim_mode claim_type claim_obj claim_path
      while IFS= read -r claim_line; do
        [[ -n "$claim_line" ]] || continue
        claim_mode=$(printf '%s\n' "$claim_line" | awk '{print $1; exit}')
        claim_type=$(printf '%s\n' "$claim_line" | awk '{print $2; exit}')
        claim_obj=$(printf '%s\n' "$claim_line" | awk '{print $3; exit}')
        claim_path="${claim_line#*$'\t'}"
        [[ -n "$claim_path" ]] || claim_path="docs/claims/<unknown>"
        soft_require_readable_regular_blob "$claim_path" "$claim_mode" "$claim_type" "$claim_obj" || return 1
      done <<EOF
$claims_lines
EOF
    fi
  fi

  local post_live
  if ! post_live=$(claim_ids_all); then
    warn "post-cleanup: claim ledger parse incomplete/ambiguous at $REF — preserving agent-claimed"
    return 1
  fi
  POST_ISSUE_IDS=$(issue_claim_ids_from "$post_live")
  return 0
}

# Label removal is permitted only after BOTH:
#   (a) every requested target representation was successfully removed and pushed
#       (or was already absent — strip rc 2); and
#   (b) a fresh, fully validated authoritative reread of the exact remote-
#       tracking ref that received the cleanup push (origin/$CLEANUP_BASE)
#       proves no target remains and no sibling for the issue remains. That
#       path never falls back to local main|master.
# Strip/push failure, target still live, fetch/ref/tree/blob failure, missing
# cleanup lineage, or incomplete parse → incomplete, preserve label, never
# claim it was removed.
PRESERVE_LABEL=0
STRIP_OK=1

if [[ -n "$TARGET_IDS" ]]; then
  set +e
  strip_claim_rows
  strip_rc=$?
  set -e
  case "$strip_rc" in
    0) info "claim removed" ;;
    2) info "no claim to remove at $REF" ;;
    *)
      warn "claim NOT removed for issue $ISSUE — strip failed (rc=$strip_rc)."
      warn "Fix by hand on main: git rm the docs/claims/<id>.md file(s) for exact id(s) '$TARGET_IDS' (or drop those claim-id column rows from docs/active-work.md), then push."
      INCOMPLETE=1
      STRIP_OK=0
      PRESERVE_LABEL=1
      ;;
  esac

  # Discard the pre-mutation residual plan. Only an authoritative reread of
  # live ids may decide label policy — never subtract TARGET_IDS from stale state.
  RESIDUAL_IDS=""
  ALL_IDS=""
  POST_ISSUE_IDS=""

  if ! authoritative_post_mutation_reread; then
    INCOMPLETE=1
    PRESERVE_LABEL=1
  else
    ALL_IDS="$POST_ISSUE_IDS"
    # Classify from ids actually present on the validated reread.
    # Use if/then (not grep &&) so set -e cannot abort on a non-target id.
    targets_remaining=$(
      printf '%s\n' "$ALL_IDS" | while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if printf '%s\n' "$TARGET_IDS" | grep -qxF -- "$id"; then
          printf '%s\n' "$id"
        fi
      done
    )
    RESIDUAL_IDS=$(
      printf '%s\n' "$ALL_IDS" | while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if printf '%s\n' "$TARGET_IDS" | grep -qxF -- "$id"; then
          :
        else
          printf '%s\n' "$id"
        fi
      done
    )
    if [[ -n "$targets_remaining" ]]; then
      warn "target claim(s) still live on $REF after cleanup attempt:"
      printf '%s\n' "$targets_remaining" | sed 's/^/  /' >&2
      INCOMPLETE=1
      PRESERVE_LABEL=1
    elif [[ "$STRIP_OK" -eq 0 ]]; then
      # Strip/push failed even if the reread looks empty — do not remove label.
      PRESERVE_LABEL=1
    fi
  fi
else
  info "no claim to remove"
fi

# --- label ----------------------------------------------------------------
# L-027: the old code swallowed gh's stderr and logged success unconditionally.
if command -v gh >/dev/null; then
  REPO="$REPO_ARG"
  if [[ -z "$REPO" ]]; then
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  fi
  if [[ "$PRESERVE_LABEL" -eq 1 ]]; then
    # Incomplete cleanup (strip/push/reread/target still live): never call
    # remove-label. A live claim with no agent-claimed label is the defect.
    info "preserving agent-claimed on #$ISSUE — incomplete cleanup; not removing label"
  elif [[ -n "$RESIDUAL_IDS" ]]; then
    # L-024: siblings are still working this issue; the label is still true.
    # Residual rows on the ledger are themselves the verification — leaving
    # the label is the complete policy without a GitHub round-trip.
    info "keeping agent-claimed on #$ISSUE — residual claims remain:"
    printf '%s\n' "$RESIDUAL_IDS" | sed 's/^/  /'
  elif [[ "$KEEP_LABEL" -eq 1 ]]; then
    # Empty ledger + live sibling whose claim is not on this ref (or was never
    # filed). Explicit operator path — do not invent a row, do not strip the
    # label. Preservation is a postcondition that must be verified against
    # GitHub; a blind "kept" log while the label is absent is a false green.
    if [[ -z "${REPO:-}" ]]; then
      warn "could not resolve the product repo — --keep-label cannot verify agent-claimed on #$ISSUE (pass --repo owner/name)"
      INCOMPLETE=1
    else
      LABELS=$(gh issue view "$ISSUE" --repo "$REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$LABELS" == "?" ]]; then
        warn "could not read labels on $REPO#$ISSUE — --keep-label preservation UNVERIFIED"
        INCOMPLETE=1
      elif ! echo ",$LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is ABSENT on $REPO#$ISSUE — --keep-label required the label to stay, but it is not present. Re-add it or re-claim before declaring Law 10 done."
        INCOMPLETE=1
      else
        info "keeping agent-claimed on $REPO#$ISSUE — --keep-label verified (live sibling outside ledger; no claim row invented)"
      fi
    fi
  elif [[ -z "${REPO:-}" ]]; then
    warn "could not resolve the product repo — agent-claimed NOT removed from #$ISSUE (pass --repo owner/name)"
    INCOMPLETE=1
  else
    if ! gh issue edit "$ISSUE" --repo "$REPO" --remove-label agent-claimed; then
      warn "gh issue edit failed for #$ISSUE in $REPO"
    fi
    # Verify rather than assume.
    LABELS=$(gh issue view "$ISSUE" --repo "$REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
    if [[ "$LABELS" == "?" ]]; then
      warn "could not re-read labels on #$ISSUE — agent-claimed removal UNVERIFIED"
      INCOMPLETE=1
    elif echo ",$LABELS," | grep -q ',agent-claimed,'; then
      warn "agent-claimed is STILL on $REPO#$ISSUE — remove it by hand before declaring Law 10 done"
      INCOMPLETE=1
    else
      info "removed agent-claimed from $REPO#$ISSUE (verified)"
    fi
  fi
else
  if [[ "$PRESERVE_LABEL" -eq 1 ]]; then
    info "gh not found — agent-claimed left in place (incomplete cleanup; not removing label)"
  elif [[ -n "$RESIDUAL_IDS" ]]; then
    info "gh not found — agent-claimed left in place (residual claims on ledger)"
  elif [[ "$KEEP_LABEL" -eq 1 ]]; then
    warn "gh not found — --keep-label cannot verify agent-claimed on #$ISSUE"
    INCOMPLETE=1
  else
    warn "gh not found — agent-claimed NOT removed from #$ISSUE"
    INCOMPLETE=1
  fi
fi

if [[ "$INCOMPLETE" -eq 1 ]]; then
  echo "release-claim.sh: INCOMPLETE — cleanup did not finish for issue $ISSUE (see warnings above)" >&2
  exit 3
fi

if [[ -z "$TARGET_IDS" ]]; then
  info "OK — no claim row to release for issue $ISSUE; label policy applied"
else
  info "OK — claim released for issue $ISSUE"
fi
