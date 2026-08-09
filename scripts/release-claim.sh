#!/usr/bin/env bash
# release-claim.sh — post-merge cleanup (docs/05, Law 10)
set -euo pipefail

usage() {
  cat <<'EOF'
release-claim.sh — release a claim after merge (cleanup)

WHAT IT DOES
  Finds the claim row for an issue, deletes the claim row with a signed commit
  on main, removes the agent-claimed label, and removes the git worktree and
  local branch when requested.

  With CAS flags or --worktree-path (claimed prune), worktree/branch removal is
  deferred until path/blob CAS validation, the cleanup push, and an
  authoritative post-mutation reread prove the exact target claim is absent.
  A renewal race, push rejection, or OID mismatch leaves the registered
  worktree and branch untouched and exits incomplete (rc=3). Ordinary non-CAS
  cleanup without --worktree-path keeps historical early worktree removal.

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
                           [--keep-branch] [--keep-worktree] [--keep-label]
                           [--expected-claim-path PATH] [--expected-claim-blob OID]
                           [--expected-source file|legacy]
                           [--worktree-path PATH] [--expected-branch BRANCH]
                           [--dry-run]
  release-claim.sh --help

  <issue>        issue number, e.g. 42
  --claim-id     release exactly this claim id (e.g. issue-42-password-reset)
                 and leave every sibling row for the issue alone (L-024)
  --prefix       namespace for cross-repo claim ids: --prefix template matches
                 issue-template-<N>-* as well as issue-<N>-* (L-036 / L-037)
  --repo         product repo for the issue/label, when the issue does not live
                 in the claim-table repo (L-037)
  --keep-branch  do not delete the local/remote feature branch
  --keep-worktree
                 do not remove the registered worktree directory (default still
                 removes it). Used by claim-reaper so a dead lane's claim can be
                 released while preserving the on-disk tree for recovery.
  --keep-label   keep agent-claimed even when the ledger has no residual row
                 for this issue (live sibling lane whose claim file is absent
                 or lives elsewhere). Verifies the live GitHub label is present
                 (exit 3 if the product repo is unresolved or the label is
                 absent/unreadable). Without this flag, a no-residual cleanup
                 removes the label — the final completed lane path.
  --expected-claim-path PATH
                 CAS: exact ledger path of the claim blob (e.g.
                 docs/claims/issue-42-x.md). Bound through fetch/cleanup/push.
  --expected-claim-blob OID
                 CAS: exact blob OID (or legacy "activeblob:claimid") that must
                 still match on the authoritative remote before any strip/push.
  --expected-source file|legacy
                 CAS: claim representation form; required with --expected-claim-blob.
  --worktree-path PATH
                 remove only this exact absolute registered worktree path (no
                 default-path derivation). Claimed prune from claim-reaper.
  --expected-branch BRANCH
                 when --worktree-path is set, the worktree must be checked out
                 on this branch before removal.
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
KEEP_WORKTREE=0
KEEP_LABEL=0
DRY=0
CLAIM_ID_ARG=""
CLAIM_ID_SET=0
PREFIX=""
REPO_ARG=""
EXPECTED_CLAIM_PATH=""
EXPECTED_CLAIM_BLOB=""
EXPECTED_SOURCE=""
WORKTREE_PATH_ARG=""
EXPECTED_BRANCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-branch) KEEP_BRANCH=1 ;;
    --keep-worktree) KEEP_WORKTREE=1 ;;
    --keep-label) KEEP_LABEL=1 ;;
    --dry-run) DRY=1 ;;
    --claim-id)
      CLAIM_ID_SET=1
      CLAIM_ID_ARG="${2:-}"
      shift
      ;;
    --prefix) PREFIX="${2:-}"; shift ;;
    --repo) REPO_ARG="${2:-}"; shift ;;
    --expected-claim-path)
      EXPECTED_CLAIM_PATH="${2:-}"
      shift
      ;;
    --expected-claim-blob)
      EXPECTED_CLAIM_BLOB="${2:-}"
      shift
      ;;
    --expected-source)
      EXPECTED_SOURCE="${2:-}"
      shift
      ;;
    --worktree-path)
      WORKTREE_PATH_ARG="${2:-}"
      shift
      ;;
    --expected-branch)
      EXPECTED_BRANCH="${2:-}"
      shift
      ;;
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
if [[ -n "$EXPECTED_CLAIM_BLOB" || -n "$EXPECTED_CLAIM_PATH" || -n "$EXPECTED_SOURCE" ]]; then
  [[ -n "$EXPECTED_CLAIM_BLOB" ]] || die "--expected-claim-blob is required when CAS expected-* flags are set"
  [[ -n "$EXPECTED_SOURCE" ]] || die "--expected-source is required with --expected-claim-blob"
  case "$EXPECTED_SOURCE" in
    file|legacy) ;;
    *) die "--expected-source must be 'file' or 'legacy'" ;;
  esac
  if [[ "$EXPECTED_SOURCE" == "file" ]]; then
    [[ -n "$EXPECTED_CLAIM_PATH" ]] || die "--expected-claim-path is required for --expected-source file"
    case "$EXPECTED_CLAIM_PATH" in
      docs/claims/*.md) ;;
      *) die "--expected-claim-path must be docs/claims/<id>.md; got '$EXPECTED_CLAIM_PATH'" ;;
    esac
  fi
  if [[ ! "$EXPECTED_CLAIM_BLOB" =~ ^[0-9a-f]{4,64}(:issue-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)?$ ]]; then
    die "--expected-claim-blob must be a hex blob OID (optionally :claim-id for legacy)"
  fi
fi
if [[ -n "$WORKTREE_PATH_ARG" ]]; then
  case "$WORKTREE_PATH_ARG" in
    /*) ;;
    *) die "--worktree-path must be an absolute path" ;;
  esac
  case "$WORKTREE_PATH_ARG" in
    *..*) die "--worktree-path must not contain '..'" ;;
  esac
fi
if [[ -n "$EXPECTED_BRANCH" && ! "$EXPECTED_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  die "--expected-branch has unsafe characters"
fi

cd "$CANONICAL"
WT_PARENT="$(cd "$CANONICAL/.." && pwd)"
# (#153 blocker 1) There is deliberately no pr_wt_dir_for() any more. Deriving
# a worktree path from a claim id is a guess, and the open-PR release path
# used that guess to drive `git worktree remove --force`. Worktree identity is
# resolved from `git worktree list --porcelain` by exact branch, or not at all.

# Physical path for comparison (macOS /var vs /private/var). Defined this
# early so every registered-worktree check in the file — including the
# open-PR-body release path just below — uses the same canonicalized
# comparison; a bare string match here is exactly how a real registered
# worktree was once misclassified as "unregistered" and fell through to a
# destructive rm -rf fallback.
phys_path() {
  local p="$1" dir base
  p="${p%/}"
  [[ -n "$p" ]] || { echo ""; return 0; }
  if [[ -d "$p" && ! -L "$p" ]]; then
    (CDPATH='' cd "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"
    return 0
  fi
  dir=$(dirname -- "$p" 2>/dev/null || echo ".")
  base=$(basename -- "$p" 2>/dev/null || echo "$p")
  if [[ -d "$dir" ]]; then
    printf '%s/%s\n' "$(CDPATH='' cd "$dir" 2>/dev/null && pwd -P)" "$base"
  else
    printf '%s\n' "$p"
  fi
}

# Is path a registered git worktree of CANONICAL?
worktree_registered() {
  local want="$1" line cur="" want_phys cur_phys
  want="${want%/}"
  want_phys=$(phys_path "$want")
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        cur="${line#worktree }"
        cur="${cur%/}"
        if [[ "$cur" == "$want" ]]; then
          return 0
        fi
        cur_phys=$(phys_path "$cur")
        if [[ -n "$want_phys" && -n "$cur_phys" && "$cur_phys" == "$want_phys" ]]; then
          return 0
        fi
        ;;
    esac
  done <<EOF
$(git worktree list --porcelain 2>/dev/null || true)
EOF
  return 1
}

# Registered worktree path's checked-out branch (porcelain), empty if detached/unknown.
worktree_branch() {
  local want="$1" line cur="" branch="" want_phys cur_phys
  want="${want%/}"
  want_phys=$(phys_path "$want")
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        cur="${line#worktree }"
        cur="${cur%/}"
        branch=""
        ;;
      branch\ *)
        branch="${line#branch }"
        # refs/heads/foo → foo
        branch="${branch#refs/heads/}"
        ;;
      "")
        if [[ -n "$cur" ]]; then
          if [[ "$cur" == "$want" ]]; then
            printf '%s\n' "$branch"
            return 0
          fi
          cur_phys=$(phys_path "$cur")
          if [[ -n "$want_phys" && -n "$cur_phys" && "$cur_phys" == "$want_phys" ]]; then
            printf '%s\n' "$branch"
            return 0
          fi
        fi
        cur=""
        branch=""
        ;;
    esac
  done <<EOF
$(git worktree list --porcelain 2>/dev/null || true)
EOF
  # Final record may lack trailing blank line
  if [[ -n "$cur" ]]; then
    if [[ "$cur" == "$want" ]]; then
      printf '%s\n' "$branch"
      return 0
    fi
    cur_phys=$(phys_path "$cur")
    if [[ -n "$want_phys" && -n "$cur_phys" && "$cur_phys" == "$want_phys" ]]; then
      printf '%s\n' "$branch"
      return 0
    fi
  fi
  echo ""
  return 1
}

# CAS mode (claim-reaper): require a successful fetch of the exact remote base
# into origin/<base> and never fall back to local main/master or cached stale
# state. Non-CAS mode keeps the historical local fallback for bare cleanup.
CAS_MODE=0
if [[ -n "$EXPECTED_CLAIM_BLOB" ]]; then
  CAS_MODE=1
fi

# Resolve the ledger ref. Prefer origin/main, then origin/master, then local
# main/master (non-CAS only). An unborn, missing, or non-commit ref is a hard
# fail — never treat a failed ref read as an "empty ledger".
resolve_ledger_ref() {
  local candidate
  if [[ "$CAS_MODE" -eq 1 ]]; then
    for candidate in origin/main origin/master; do
      if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
    return 1
  fi
  for candidate in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}


# Successful fetch of exact remote base into its remote-tracking ref.
# Prints base name (main|master). Fails closed on fetch failure.
fetch_remote_base() {
  local base
  for base in main master; do
    if git fetch origin "$base" >/dev/null 2>&1; then
      if git rev-parse --verify --quiet "origin/${base}^{commit}" >/dev/null 2>&1; then
        printf '%s\n' "$base"
        return 0
      fi
    fi
  done
  return 1
}

if [[ "$CAS_MODE" -eq 1 ]]; then
  if ! CLEANUP_BASE_FETCH=$(fetch_remote_base); then
    die "CAS mode: cannot fetch remote ledger base (origin main/master) — refuse mutation (no local/cached fallback)"
  fi
  info "CAS fetch ok: origin/${CLEANUP_BASE_FETCH}"
else
  git fetch origin >/dev/null 2>&1 || true
fi

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

# Worktree/branch per released claim id, derived from the id rather than
# assumed, so namespaced ids (issue-template-5-x) resolve correctly (L-037).
# Defined here (not just before their removal call sites) so the terminal
# PR-body verification below (#153) can bind head-branch identity too.
wt_dir_for() { echo "$WT_PARENT/wt-${1#issue-}"; }
branch_for() { echo "feat/${1#issue-}"; }

# Terminal (MERGED/CLOSED) PR-body claim fallback (#153). Reachable only for
# an exact --claim-id release, and only outside claim-reaper's CAS mode (CAS
# is ledger-only by contract — never touched by this path). Fires when the
# claim id is absent from the live ledger: the claim's reservation PR may
# already be done and current claim.sh never writes a ledger row at all, so
# "absent from the ledger" is not evidence the claim was never real (that was
# the #139 failure this closes). Verifies exact issue/claim-id/PR-number/
# head-branch/head-SHA/base-repository/terminal-state binding before
# returning success; never invents a ledger row. Ambiguous, open, foreign
# (cross-repo/fork), mismatched, or unreadable evidence dies immediately
# (fail closed) rather than falling through to the generic "no live claim"
# message, so the operator sees exactly which binding failed.
#
# This function only VERIFIES evidence — it never touches a worktree, branch,
# or label. All mutation is deferred to terminal_cleanup_release(), called
# later once every helper it needs (phys_path/worktree_registered/…) is
# defined, only after this function returns 0 (#153 AC1).
TERMINAL_PR_NUMBER=""
TERMINAL_MODE=0
TERMINAL_HEAD_SHA=""
TERMINAL_MERGE_SHA=""
TERMINAL_STATE=""
try_terminal_pr_body_release() {
  local id="$1" rows count
  local t_number t_claim t_scope t_issue t_head t_head_sha t_url t_state t_cross t_merge_sha t_base_repo t_created t_updated
  if [[ -z "${PR_REPO:-}" || ! -x "$SCRIPT_DIR/pr-claims.sh" ]]; then
    return 1
  fi
  if ! rows=$("$SCRIPT_DIR/pr-claims.sh" find-terminal "$PR_REPO" "$id" 2>&1); then
    die "cannot verify terminal PR-body claim evidence for '$id' on $PR_REPO (gh query failed) — refuse mutation: $rows"
  fi
  # grep -c (not wc -l): $rows came from command substitution, which strips
  # the trailing newline, so a single-line result would otherwise undercount
  # to 0 and a two-line result to 1 — wc -l counts newline characters, not lines.
  count=$(printf '%s' "$rows" | grep -c . || true)
  [[ "$count" -gt 0 ]] || return 1
  if [[ "$count" -gt 1 ]]; then
    die "ambiguous terminal PR-body evidence for claim id '$id' on $PR_REPO — multiple PRs matched; resolve by hand"
  fi
  # cut, not `IFS=$'\t' read`: tab is IFS *whitespace*, so bash's read
  # collapses consecutive tabs and silently drops empty fields (e.g. a CLOSED
  # PR's empty merge-SHA column), shifting every field after it. cut treats
  # each tab as an exact delimiter and preserves empty fields.
  t_number=$(cut -f1 <<<"$rows")
  t_claim=$(cut -f2 <<<"$rows")
  t_scope=$(cut -f3 <<<"$rows")
  t_issue=$(cut -f4 <<<"$rows")
  t_head=$(cut -f5 <<<"$rows")
  t_head_sha=$(cut -f6 <<<"$rows")
  # shellcheck disable=SC2034  # url/created/updated read for row-shape parity; not part of the identity checks below
  t_url=$(cut -f7 <<<"$rows")
  t_state=$(cut -f8 <<<"$rows")
  t_cross=$(cut -f9 <<<"$rows")
  t_merge_sha=$(cut -f10 <<<"$rows")
  t_base_repo=$(cut -f11 <<<"$rows")
  # shellcheck disable=SC2034
  t_created=$(cut -f12 <<<"$rows")
  # shellcheck disable=SC2034
  t_updated=$(cut -f13 <<<"$rows")
  [[ -n "$t_number" && -n "$t_claim" && -n "$t_scope" && -n "$t_state" && -n "$t_head" && -n "$t_head_sha" && -n "$t_base_repo" ]] ||
    die "malformed/truncated terminal PR-body evidence for '$id' on $PR_REPO"
  [[ "$t_number" =~ ^[0-9]+$ ]] ||
    die "terminal PR-body claim for '$id' has an unsafe PR number '$t_number' — refuse"
  [[ "$t_claim" == "$id" ]] ||
    die "terminal PR-body claim id mismatch on PR #$t_number (want '$id', got '${t_claim:-?}') — refuse"
  [[ "$t_issue" == "$ISSUE" ]] ||
    die "terminal PR-body claim #$t_number issue mismatch (want #$ISSUE, got '${t_issue:-?}') — refuse"
  case "$t_state" in
    MERGED|CLOSED) ;;
    OPEN)
      die "terminal PR-body claim #$t_number for '$id' is still OPEN — release only after it merges or closes"
      ;;
    *)
      die "terminal PR-body claim #$t_number for '$id' has an unrecognized state '$t_state' — refuse"
      ;;
  esac
  [[ "$t_cross" == "false" ]] ||
    die "terminal PR-body claim #$t_number for '$id' is a cross-repository (fork) PR — refuse (foreign-repo evidence)"
  # Base-repository identity is re-derived by pr-claims.sh from the PR's own
  # URL, never assumed from the --repo query argument alone (#153 AC3).
  [[ "$t_base_repo" == "$PR_REPO" ]] ||
    die "terminal PR-body claim #$t_number for '$id' base-repository mismatch (want '$PR_REPO', got '${t_base_repo:-?}') — refuse (do not infer repository identity from the query argument alone)"
  [[ -n "$t_head" && "$t_head" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    die "terminal PR-body claim #$t_number for '$id' has an unsafe/unreadable head branch — refuse"
  local expect_branch
  expect_branch=$(branch_for "$id")
  [[ "$t_head" == "$expect_branch" ]] ||
    die "terminal PR-body claim #$t_number for '$id' head branch mismatch (want '$expect_branch', got '$t_head') — refuse"
  [[ "$t_head_sha" =~ ^[0-9a-f]{40}$ ]] ||
    die "terminal PR-body claim #$t_number for '$id' has a malformed/missing head SHA '${t_head_sha:-?}' — refuse"
  case "$t_state" in
    MERGED)
      [[ -n "$t_merge_sha" && "$t_merge_sha" =~ ^[0-9a-f]{40}$ ]] ||
        die "terminal PR-body claim #$t_number for '$id' is MERGED but has a malformed/missing merge-commit SHA — refuse"
      ;;
    CLOSED)
      [[ -z "$t_merge_sha" ]] ||
        die "terminal PR-body claim #$t_number for '$id' is CLOSED but carries a merge-commit SHA — state/evidence mismatch, refuse (never call unmerged code merged)"
      ;;
  esac
  info "verified terminal PR-body claim #$t_number ($t_state) for '$id' on $PR_REPO — releasing without a ledger row"
  TERMINAL_PR_NUMBER="$t_number"
  TERMINAL_HEAD_SHA="$t_head_sha"
  TERMINAL_MERGE_SHA="$t_merge_sha"
  TERMINAL_STATE="$t_state"
  TERMINAL_MODE=1
  return 0
}

# Bind the exact refs/heads/<branch> to its real *registered* worktree path
# by enumerating `git worktree list --porcelain` — never derive the path from
# the claim id (#153 blocker 1). A `wt_dir_for` guess is how a registered
# worktree at a non-default path was missed while an unrelated/unregistered
# default-path directory drove the removal decision.
#
# Sets on success (return 0):
#   TERM_WT_PATH   the exact registered worktree path for $br, or "" when no
#                  registered worktree is checked out on that branch.
# Sets on failure (return 1):
#   TERM_WT_REASON why resolution itself could not be trusted — ambiguity
#                  (branch registered at more than one path), a symlinked or
#                  unreadable registered entry, a registered path that
#                  canonicalizes to the caller's own checkout (foreign
#                  canonical path), or an unsafe/unregistered object still
#                  sitting at the historical default-derived path when zero
#                  registered worktrees match the branch. `git worktree list`
#                  itself failing is also unreadable evidence, not "none".
#
# Zero matching registered worktrees is allowed (TERM_WT_PATH="") only when
# there is no unsafe object at the old guessed path: nothing there at all, or
# a *registered* worktree there under some other branch (a real, tracked,
# unrelated worktree — not ours, not touched, not unsafe). An unregistered
# stray directory/symlink/file at that path, or a registered-but-differently-
# branched worktree, is refused rather than silently ignored.
resolve_registered_worktree_for_branch() {
  local br="$1" id="$2"
  local porcelain line cur="" cur_branch="" matches="" match_count=0
  local canon_root wt_phys guess
  TERM_WT_PATH=""
  TERM_WT_REASON=""

  if ! porcelain=$(git worktree list --porcelain 2>&1); then
    TERM_WT_REASON="cannot enumerate registered worktrees (git worktree list --porcelain failed): $porcelain"
    return 1
  fi
  canon_root=$(phys_path "$CANONICAL")

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        cur="${line#worktree }"
        cur="${cur%/}"
        cur_branch=""
        ;;
      branch\ *)
        cur_branch="${line#branch }"
        cur_branch="${cur_branch#refs/heads/}"
        ;;
      "")
        if [[ -n "$cur" && "$cur_branch" == "$br" ]]; then
          matches="${matches}${cur}"$'\n'
          match_count=$((match_count + 1))
        fi
        cur=""
        cur_branch=""
        ;;
    esac
  done <<EOF
$porcelain
EOF
  if [[ -n "$cur" && "$cur_branch" == "$br" ]]; then
    matches="${matches}${cur}"$'\n'
    match_count=$((match_count + 1))
  fi

  if [[ "$match_count" -gt 1 ]]; then
    TERM_WT_REASON="branch '$br' is registered at more than one worktree path — ambiguous, refuse: $(printf '%s' "$matches" | tr '\n' ' ')"
    return 1
  fi

  if [[ "$match_count" -eq 1 ]]; then
    TERM_WT_PATH=$(printf '%s\n' "$matches" | sed -n '1p')
    if [[ -L "$TERM_WT_PATH" ]]; then
      TERM_WT_REASON="registered worktree path is a symlink — refuse: $TERM_WT_PATH"
      return 1
    fi
    if [[ ! -d "$TERM_WT_PATH" ]]; then
      TERM_WT_REASON="registered worktree path is missing or not a directory: $TERM_WT_PATH"
      return 1
    fi
    wt_phys=$(phys_path "$TERM_WT_PATH")
    if [[ -z "$wt_phys" ]]; then
      TERM_WT_REASON="cannot canonicalize registered worktree path: $TERM_WT_PATH"
      return 1
    fi
    if [[ -n "$canon_root" && "$wt_phys" == "$canon_root" ]]; then
      TERM_WT_REASON="registered worktree path resolves to the canonical checkout itself — foreign canonical path, refuse: $TERM_WT_PATH"
      return 1
    fi
    return 0
  fi

  # match_count == 0: the exact branch has no registered worktree anywhere.
  guess=$(wt_dir_for "$id")
  guess="${guess%/}"
  if [[ -e "$guess" || -L "$guess" ]]; then
    if worktree_registered "$guess"; then
      local guess_branch
      guess_branch=$(worktree_branch "$guess" || true)
      TERM_WT_REASON="worktree at the historical default path is checked out on '${guess_branch:-detached/unknown}', expected the exact PR head branch '$br' — refuse rather than assume the branch alone is safe: $guess"
      return 1
    fi
    TERM_WT_REASON="no registered worktree for branch '$br', and the historical default path exists but is not a registered git worktree (no default-path fallback; refuse rm -rf): $guess"
    return 1
  fi
  return 0
}

# Query the *exact* remote branch via `git ls-remote --heads`, distinguishing
# "the query itself failed" (network/auth/read failure — unreadable evidence)
# from "the branch legitimately does not exist" (query succeeded, empty
# output) from "the branch exists" (exactly one well-formed row whose ref
# matches exactly). `git ls-remote --exit-code` alone conflates the first two
# cases into the same nonzero exit — that is exactly the ambiguity #153
# blocker 4 closes (#153).
#
# Sets on success (return 0):
#   REMOTE_BRANCH_STATUS  "present" or "absent"
#   REMOTE_BRANCH_OID     the branch's exact OID when present, else ""
# Sets on failure (return 1):
#   REMOTE_BRANCH_REASON  why the query is unreadable evidence (query
#                         failure, or multiple/malformed rows)
query_remote_branch_exact() {
  local br="$1" out line count oid ref
  REMOTE_BRANCH_STATUS=""
  REMOTE_BRANCH_OID=""
  REMOTE_BRANCH_REASON=""
  if ! out=$(git ls-remote --heads origin "refs/heads/$br" 2>&1); then
    REMOTE_BRANCH_REASON="git ls-remote --heads origin failed for '$br': $out"
    return 1
  fi
  if [[ -z "$out" ]]; then
    REMOTE_BRANCH_STATUS="absent"
    return 0
  fi
  count=$(printf '%s\n' "$out" | grep -c . || true)
  if [[ "$count" -ne 1 ]]; then
    REMOTE_BRANCH_REASON="git ls-remote --heads origin returned multiple/malformed rows for '$br': $out"
    return 1
  fi
  line=$(printf '%s\n' "$out")
  oid=$(awk '{print $1}' <<<"$line")
  ref=$(awk '{print $2}' <<<"$line")
  if [[ ! "$oid" =~ ^[0-9a-f]{40}$ || "$ref" != "refs/heads/$br" ]]; then
    REMOTE_BRANCH_REASON="git ls-remote --heads origin returned a malformed row for '$br': $line"
    return 1
  fi
  REMOTE_BRANCH_STATUS="present"
  REMOTE_BRANCH_OID="$oid"
  return 0
}

# Full mutation + verification for a verified terminal PR-body claim. Called
# only after try_terminal_pr_body_release() has already bound exact PR
# number/head-branch/head-SHA/claim-id/issue/repository/cross-repo=false/
# terminal-state (#153 AC3). This function performs the safety proof (exact
# *registered* worktree bound by branch enumeration — never a guessed path,
# clean status revalidated immediately before removal, exact/contained head
# SHA, exact local/remote branch identity) BEFORE any worktree/branch/label
# mutation (#153 AC1), never rm -rf's an unregistered or default-path
# directory, never force-removes a dirty worktree, and — unlike the
# best-effort ledger-sibling lookup used elsewhere in this script — is
# fail-closed end to end: any GitHub query failure or malformed post-mutation
# evidence preserves agent-claimed and exits 3, never printing a success
# message (#153 AC4/AC5). Always exits the process (0 or 3); it never
# returns.
terminal_cleanup_release() {
  local id="$1" br
  br=$(branch_for "$id")

  [[ -z "$WORKTREE_PATH_ARG" ]] ||
    die "--worktree-path is not supported for a terminal PR-body claim release (claim-reaper CAS flow only)"

  local incomplete=0 preserve_label=0 safe=0 reason=""
  local wt="" wt_present=0 wt_removed=0

  # --- resolve the exact registered worktree, never a guessed path --------
  # (#153 blocker 1)
  if ! resolve_registered_worktree_for_branch "$br" "$id"; then
    reason="$TERM_WT_REASON"
  elif [[ -n "$TERM_WT_PATH" ]]; then
    wt="$TERM_WT_PATH"
    wt_present=1
  fi

  # --- safety proof, before any mutation ----------------------------------
  if [[ -n "$reason" ]]; then
    :  # resolution above already failed; safe stays 0
  elif [[ "$wt_present" -eq 1 ]]; then
    local got_head status_out
    if ! status_out=$(git -C "$wt" status --porcelain 2>&1); then
      reason="cannot read worktree status ($status_out)"
    elif [[ -n "$status_out" ]]; then
      reason="worktree has uncommitted or untracked changes — refuse to remove a dirty worktree"
    else
      got_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
      if [[ -z "$got_head" ]]; then
        reason="cannot read worktree HEAD commit"
      elif [[ "$got_head" == "$TERMINAL_HEAD_SHA" ]]; then
        safe=1
      elif [[ "$TERMINAL_STATE" == "MERGED" && -n "$TERMINAL_MERGE_SHA" ]] &&
           { git -C "$wt" cat-file -e "$TERMINAL_MERGE_SHA" 2>/dev/null || git -C "$wt" fetch origin "$TERMINAL_MERGE_SHA" >/dev/null 2>&1; } &&
           git -C "$wt" merge-base --is-ancestor "$got_head" "$TERMINAL_MERGE_SHA" 2>/dev/null; then
        safe=1
      else
        reason="worktree HEAD ($got_head) is neither the exact terminal PR head SHA ($TERMINAL_HEAD_SHA) nor provably contained in the merged result (${TERMINAL_MERGE_SHA:-n/a}) — refuse"
      fi
    fi
  else
    safe=1  # no registered worktree for the exact branch — nothing unsafe to remove
  fi

  # --- branch identity proof (#153 blocker 3): a missing worktree does not
  # make an advanced/reused branch safe. Prove local/remote branch tip
  # identity against the terminal PR head SHA before any branch deletion —
  # exact equality, or (local only) provable containment in the merge result.
  #
  # local_branch_verified_oid carries the *exact* OID accepted right here
  # forward to the CAS delete below (blocker 2 of the second Codex review).
  # The deletion block must never re-derive its own expected-old value with a
  # fresh `git rev-parse` immediately before deleting: that would silently
  # accept whatever the branch advanced to between this proof and the delete
  # call as the "expected" value, since a value read from the ref always
  # trivially equals itself. Only a value fixed at proof time can catch an
  # advance in that window.
  local local_branch_verified_oid=""
  if [[ "$safe" -eq 1 && "$KEEP_BRANCH" -eq 0 ]]; then
    if git show-ref --verify --quiet "refs/heads/$br"; then
      local local_tip
      local_tip=$(git rev-parse --verify --quiet "refs/heads/$br" 2>/dev/null || true)
      if [[ -z "$local_tip" ]]; then
        safe=0
        reason="cannot read local branch '$br' tip commit"
      elif [[ "$local_tip" == "$TERMINAL_HEAD_SHA" ]]; then
        local_branch_verified_oid="$local_tip"
      elif [[ "$TERMINAL_STATE" == "MERGED" && -n "$TERMINAL_MERGE_SHA" ]] &&
           { git cat-file -e "$TERMINAL_MERGE_SHA" 2>/dev/null || git fetch origin "$TERMINAL_MERGE_SHA" >/dev/null 2>&1; } &&
           git merge-base --is-ancestor "$local_tip" "$TERMINAL_MERGE_SHA" 2>/dev/null; then
        local_branch_verified_oid="$local_tip"
      else
        safe=0
        reason="local branch '$br' tip ($local_tip) is neither the exact terminal PR head SHA ($TERMINAL_HEAD_SHA) nor provably contained in the merged result (${TERMINAL_MERGE_SHA:-n/a}) — refuse (advanced/reused branch)"
      fi
    fi
    if [[ "$safe" -eq 1 ]]; then
      if ! query_remote_branch_exact "$br"; then
        safe=0
        reason="$REMOTE_BRANCH_REASON"
      elif [[ "$REMOTE_BRANCH_STATUS" == "present" && "$REMOTE_BRANCH_OID" != "$TERMINAL_HEAD_SHA" ]]; then
        safe=0
        reason="remote branch '$br' OID ($REMOTE_BRANCH_OID) does not equal the terminal PR head SHA ($TERMINAL_HEAD_SHA) — refuse (advanced/reused branch)"
      fi
    fi
  fi

  if [[ "$safe" -ne 1 ]]; then
    warn "refusing terminal cleanup for '$id' (PR #$TERMINAL_PR_NUMBER, $TERMINAL_STATE): ${reason:-unknown safety failure}"
    warn "worktree and branch left untouched"
    incomplete=1
    preserve_label=1
  fi

  # --- mutation (only after the safety proof above) -----------------------
  if [[ "$safe" -eq 1 ]]; then
    if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
      [[ "$wt_present" -eq 1 ]] && info "keeping worktree $wt (--keep-worktree)"
    elif [[ "$wt_present" -eq 1 ]]; then
      info "removing exact registered worktree $wt (terminal PR #$TERMINAL_PR_NUMBER, $TERMINAL_STATE)"
      # (#153 blocker 3) Close the dirty-worktree TOCTOU: revalidate not only
      # clean status but that the exact registered path still belongs to the
      # expected PR head branch and its HEAD is still the previously accepted
      # exact/contained commit ($got_head, proven safe above) — a
      # deterministic test hook can dirty the tree, switch its branch, or move
      # its HEAD in exactly this window. Use non-force `git worktree remove`
      # so Git itself refuses a tree that went dirty after our own recheck.
      # Never --force, never rm -rf.
      if [[ -n "${RELEASE_CLAIM_TEST_DIRTY_HOOK:-}" ]]; then
        "$RELEASE_CLAIM_TEST_DIRTY_HOOK" "$wt" || true
      fi
      local revalidate_out revalidate_branch revalidate_head
      revalidate_branch=""
      if ! revalidate_out=$(git -C "$wt" status --porcelain 2>&1); then
        warn "cannot revalidate worktree status immediately before removal for $wt ($revalidate_out)"
        incomplete=1
        preserve_label=1
      elif [[ -n "$revalidate_out" ]]; then
        warn "worktree $wt became dirty between the safety proof and removal — refuse to remove (TOCTOU guard)"
        incomplete=1
        preserve_label=1
      elif ! worktree_registered "$wt"; then
        warn "worktree $wt is no longer a registered git worktree immediately before removal — refuse (TOCTOU guard)"
        incomplete=1
        preserve_label=1
      elif revalidate_branch=$(worktree_branch "$wt" || true) && [[ "$revalidate_branch" != "$br" ]]; then
        warn "worktree $wt switched off branch '$br' (now '${revalidate_branch:-detached/unknown}') between the safety proof and removal — refuse to remove (TOCTOU guard)"
        incomplete=1
        preserve_label=1
      elif ! revalidate_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || [[ -z "$revalidate_head" ]]; then
        warn "cannot re-read worktree HEAD immediately before removal for $wt"
        incomplete=1
        preserve_label=1
      elif [[ "$revalidate_head" != "$got_head" ]]; then
        warn "worktree $wt HEAD moved between the safety proof ($got_head) and removal ($revalidate_head) — refuse to remove (TOCTOU guard)"
        incomplete=1
        preserve_label=1
      elif git worktree remove "$wt" 2>/dev/null; then
        git worktree prune 2>/dev/null || true
        if [[ -d "$wt" ]] || worktree_registered "$wt"; then
          warn "worktree $wt still present/registered immediately after removal — refuse to treat as removed"
          incomplete=1
          preserve_label=1
        else
          wt_removed=1
        fi
      else
        warn "git worktree remove failed for $wt — refuse rm -rf fallback"
        incomplete=1
        preserve_label=1
      fi
    fi
  fi

  # --- branch-deletion gate (#153 blocker 1/4): never delete the local or
  # remote branch unless the worktree phase either had nothing to remove, was
  # intentionally kept together with --keep-branch also disabled removal, or
  # completed and its removal postcondition was verified above. A dirty-hook
  # race, a failed `git worktree remove`, or a bare --keep-worktree without
  # --keep-branch must never fall through to branch deletion — that is
  # exactly how the remote branch used to be deleted while a dirty worktree
  # and its local branch survived.
  local wt_phase_ok=0
  if [[ "$safe" -eq 1 ]]; then
    if [[ "$wt_present" -eq 0 ]]; then
      wt_phase_ok=1
    elif [[ "$KEEP_WORKTREE" -eq 1 ]]; then
      if [[ "$KEEP_BRANCH" -eq 1 ]]; then
        wt_phase_ok=1
      else
        warn "refusing branch deletion for '$br' — --keep-worktree retained $wt but --keep-branch was not set; a retained worktree must not lose its branch"
        incomplete=1
        preserve_label=1
      fi
    elif [[ "$wt_removed" -eq 1 ]]; then
      wt_phase_ok=1
    fi
    # else: worktree removal was attempted above and failed/refused —
    # incomplete and preserve_label are already set by that block;
    # wt_phase_ok stays 0 and branch deletion below is skipped entirely.
  fi

  if [[ "$safe" -eq 1 && "$wt_phase_ok" -eq 1 && "$KEEP_BRANCH" -eq 0 ]]; then
    # (#153 blocker 2, hardened after the second Codex review) Check-then-
    # delete is a race: a branch can advance between the identity-proof above
    # and this delete. Use Git's own atomic compare-and-swap primitives so the
    # delete itself — not a separate shell comparison — is the safety
    # boundary. Never an unconditional delete, and never re-derive the
    # expected-old value with a fresh read taken here: local_branch_verified_
    # oid is the exact OID already accepted by the identity proof above, so an
    # advance any time between that proof and this delete (not just between a
    # fresh pre-delete read and the delete call) is caught.
    local local_cas_failed=0
    if [[ -n "$local_branch_verified_oid" ]]; then
      if [[ -n "${RELEASE_CLAIM_TEST_LOCAL_ADVANCE_HOOK:-}" ]]; then
        "$RELEASE_CLAIM_TEST_LOCAL_ADVANCE_HOOK" "$br" || true
      fi
      if ! git update-ref -d "refs/heads/$br" "$local_branch_verified_oid" 2>/dev/null; then
        warn "local branch CAS delete refused for '$br' — branch advanced since the safety proof (expected tip $local_branch_verified_oid) or delete failed"
        incomplete=1
        preserve_label=1
        local_cas_failed=1
      fi
    fi
    # A refused/failed local CAS delete must never be followed by a remote
    # delete in the same run: that is exactly how the remote branch could be
    # deleted while an advanced/reused local branch (and its content) survived.
    if [[ "$local_cas_failed" -eq 1 ]]; then
      warn "skipping remote branch CAS delete for '$br' — local branch CAS delete already failed/refused in this run"
    elif ! query_remote_branch_exact "$br"; then
      warn "cannot verify remote branch '$br' before deletion — refuse mutation: $REMOTE_BRANCH_REASON"
      incomplete=1
      preserve_label=1
    elif [[ "$REMOTE_BRANCH_STATUS" == "present" ]]; then
      if [[ -n "${RELEASE_CLAIM_TEST_REMOTE_ADVANCE_HOOK:-}" ]]; then
        "$RELEASE_CLAIM_TEST_REMOTE_ADVANCE_HOOK" "$br" || true
      fi
      # Exact expected-old lease bound to the verified terminal PR head SHA —
      # never a re-read value. A lease mismatch means the branch advanced/was
      # reused between the precheck and this delete.
      if ! git push --force-with-lease="refs/heads/${br}:${TERMINAL_HEAD_SHA}" origin ":refs/heads/${br}" >/dev/null 2>&1; then
        warn "remote branch CAS delete refused for '$br' — lease on $TERMINAL_HEAD_SHA rejected (branch advanced/reused since the precheck) or delete failed"
        incomplete=1
        preserve_label=1
      fi
    fi
  fi

  # --- fail-closed post-mutation reread: authoritative live-claim view ----
  # (ledger rows UNION live open PR-body claims, #153 AC8). Any query failure
  # or malformed result here preserves agent-claimed and refuses success —
  # the ordinary ledger path's best-effort `2>/dev/null || true` sibling
  # lookup below never applies once GitHub-native terminal evidence drove
  # this cleanup (#153 AC5).
  local sibling_ids="" open_rows fresh_ref fresh_live ledger_siblings="" malformed_row=""
  if ! open_rows=$("$SCRIPT_DIR/pr-claims.sh" list "$PR_REPO" 2>&1); then
    warn "post-mutation reread of live PR-body claims failed for $PR_REPO — cannot verify postcondition: $open_rows"
    incomplete=1
    preserve_label=1
  else
    # Every non-empty row must have exactly 7 tab-separated fields (pr-claims.sh
    # list's contract) and a non-empty issue-* claim id. A malformed/truncated
    # row is unreadable evidence, not proof the claim is gone — refuse rather
    # than silently skip it.
    while IFS= read -r _row; do
      [[ -n "$_row" ]] || continue
      _field_count=$(awk -F'\t' '{print NF}' <<<"$_row")
      _row_id=$(awk -F'\t' '{print $2}' <<<"$_row")
      if [[ "$_field_count" -ne 7 || -z "$_row_id" || ! "$_row_id" =~ ^issue- ]]; then
        malformed_row="$_row"
        break
      fi
    done <<EOF
$open_rows
EOF
    if [[ -n "$malformed_row" ]]; then
      warn "post-mutation reread of live PR-body claims returned a malformed/truncated row for $PR_REPO — cannot verify postcondition: $malformed_row"
      incomplete=1
      preserve_label=1
    elif printf '%s\n' "$open_rows" | awk -F'\t' -v want="$id" '$2==want{f=1} END{exit !f}'; then
      warn "claim '$id' unexpectedly reappeared as a live open PR-body claim after terminal cleanup — refuse success"
      incomplete=1
      preserve_label=1
    else
      while IFS=$'\t' read -r _n _cid _sc _hb _u _c _up; do
        [[ -n "$_cid" ]] || continue
        [[ "$_cid" == "$id" ]] && continue
        claim_id_for_issue "$_cid" || continue
        sibling_ids="${sibling_ids}${_cid}"$'\n'
      done <<EOF
$open_rows
EOF
      sibling_ids=$(printf '%s\n' "$sibling_ids" | grep -E '^issue-' | sort -u || true)
    fi
  fi

  if git fetch origin >/dev/null 2>&1 && fresh_ref=$(resolve_ledger_ref); then
    REF="$fresh_ref"
    if fresh_live=$(claim_ids_all); then
      ledger_siblings=$(issue_claim_ids_from "$fresh_live" | grep -vxF -- "$id" || true)
    else
      warn "post-mutation ledger reread failed at $REF — cannot fully verify sibling policy"
      incomplete=1
      preserve_label=1
    fi
  else
    warn "post-mutation: cannot fetch/resolve ledger ref for a fresh sibling reread — cannot fully verify sibling policy"
    incomplete=1
    preserve_label=1
  fi

  local all_siblings
  all_siblings=$(printf '%s\n%s\n' "$sibling_ids" "$ledger_siblings" | grep -E '^issue-' | sort -u || true)

  # --- verify exact postconditions ----------------------------------------
  # (#153 blocker 4) A remote query failure here is unreadable evidence, not
  # proof of absence — never let it pass the postcondition silently.
  if [[ "$incomplete" -eq 0 ]]; then
    if [[ "$KEEP_WORKTREE" -eq 0 && "$wt_present" -eq 1 ]]; then
      if [[ -d "$wt" ]] || worktree_registered "$wt"; then
        warn "postcondition failed: worktree $wt still present/registered after removal"
        incomplete=1
        preserve_label=1
      fi
    fi
    if [[ "$KEEP_BRANCH" -eq 0 ]]; then
      if git show-ref --verify --quiet "refs/heads/$br"; then
        warn "postcondition failed: local branch $br still present after deletion"
        incomplete=1
        preserve_label=1
      fi
      if ! query_remote_branch_exact "$br"; then
        warn "postcondition: cannot verify remote branch $br absence after deletion — refuse success: $REMOTE_BRANCH_REASON"
        incomplete=1
        preserve_label=1
      elif [[ "$REMOTE_BRANCH_STATUS" == "present" ]]; then
        warn "postcondition failed: remote branch $br still present after deletion"
        incomplete=1
        preserve_label=1
      fi
    fi
  fi

  # --- label policy ---------------------------------------------------------
  if command -v gh >/dev/null; then
    local repo="$PR_REPO"
    if [[ "$preserve_label" -eq 1 || "$incomplete" -eq 1 ]]; then
      info "preserving agent-claimed on #$ISSUE — terminal cleanup incomplete or unverifiable"
    elif [[ -n "$all_siblings" ]]; then
      # (#153 blocker 5) A sibling claim surviving does not by itself prove
      # the label is actually present — re-read GitHub rather than assume.
      LABELS=$(gh issue view "$ISSUE" --repo "$repo" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$LABELS" == "?" ]]; then
        warn "could not read labels on $repo#$ISSUE — sibling-claim label preservation UNVERIFIED"
        incomplete=1
      elif ! echo ",$LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is ABSENT on $repo#$ISSUE — sibling claim(s) remain but the label is missing; re-add it by hand"
        incomplete=1
      else
        info "keeping agent-claimed on #$ISSUE — sibling claim(s) remain (verified):"
        printf '%s\n' "$all_siblings" | sed 's/^/  /'
      fi
    elif [[ "$KEEP_LABEL" -eq 1 ]]; then
      LABELS=$(gh issue view "$ISSUE" --repo "$repo" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$LABELS" == "?" ]]; then
        warn "could not read labels on $repo#$ISSUE — --keep-label preservation UNVERIFIED"
        incomplete=1
      elif ! echo ",$LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is ABSENT on $repo#$ISSUE — --keep-label required the label to stay"
        incomplete=1
      else
        info "keeping agent-claimed on $repo#$ISSUE — --keep-label verified"
      fi
    else
      if ! gh issue edit "$ISSUE" --repo "$repo" --remove-label agent-claimed; then
        warn "gh issue edit failed for #$ISSUE in $repo"
      fi
      LABELS=$(gh issue view "$ISSUE" --repo "$repo" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$LABELS" == "?" ]]; then
        warn "could not re-read labels on #$ISSUE — agent-claimed removal UNVERIFIED"
        incomplete=1
      elif echo ",$LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is STILL on $repo#$ISSUE — remove it by hand"
        incomplete=1
      else
        info "removed agent-claimed from $repo#$ISSUE (verified)"
      fi
    fi
  else
    if [[ "$preserve_label" -eq 1 || "$incomplete" -eq 1 ]]; then
      info "gh not found — agent-claimed left in place (incomplete cleanup)"
    elif [[ -n "$all_siblings" ]]; then
      info "gh not found — agent-claimed left in place (sibling claims remain)"
    else
      warn "gh not found — agent-claimed NOT removed from #$ISSUE"
      incomplete=1
    fi
  fi

  if [[ "$incomplete" -eq 1 ]]; then
    echo "release-claim.sh: INCOMPLETE — terminal cleanup did not finish for issue $ISSUE (see warnings above)" >&2
    exit 3
  fi

  info "OK — claim released for issue $ISSUE (terminal PR-body claim, PR #$TERMINAL_PR_NUMBER, no ledger row involved)"
  exit 0
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

# GitHub-native claims live in open PR bodies. Close the owning PR to release
# them; the legacy ledger path below remains for back-compat.
#
# (#153) This block used to sit far earlier in the file, before the ledger ref
# was even resolved, which is why it grew its own private cleanup: a worktree
# path GUESSED from the claim id, `git worktree remove --force`, and two
# `|| true` branch deletes, followed by an unconditional "released PR-body
# claim". It now runs here, after every helper is defined, so closing the PR
# hands straight over to terminal_cleanup_release() — the same exact,
# verified machinery the terminal path uses (registered-worktree resolution
# by branch enumeration, dirty/TOCTOU revalidation, head-SHA containment
# proof, CAS branch deletes, fail-closed postcondition rereads). The only
# thing it costs is a resolvable ledger ref, which the terminal path already
# required anyway. Where that handover cannot be made safely, the fallback is
# close-only plus an honest INCOMPLETE — never a success message over
# unproven cleanup.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_REPO="${REPO_ARG:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"

# Shape contract for `pr-claims.sh list` output: every non-empty row carries
# exactly 7 tab-separated fields and a non-empty issue-* claim id. A truncated
# or otherwise malformed row is unreadable evidence about who holds this
# issue — never proof that nobody does. Sets OPEN_PR_BAD_ROW and returns 1.
OPEN_PR_BAD_ROW=""
open_pr_rows_valid() {
  local rows="$1" row fields id
  OPEN_PR_BAD_ROW=""
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    fields=$(awk -F'\t' '{print NF}' <<<"$row")
    id=$(awk -F'\t' '{print $2}' <<<"$row")
    if [[ "$fields" -ne 7 || -z "$id" || ! "$id" =~ ^issue- ]]; then
      OPEN_PR_BAD_ROW="$row"
      return 1
    fi
  done <<EOF
$rows
EOF
  return 0
}

# CAS mode (claim-reaper) is ledger-only by contract — the same reason
# try_terminal_pr_body_release() is gated on CAS_MODE -eq 0. A reaper run
# must never close someone's live PR.
if [[ -n "$PR_REPO" && "$CAS_MODE" -eq 0 ]]; then
  # (#153) The live open-PR claim inventory is AUTHORITATIVE, not advisory.
  # This used to be `$(... list ... 2>/dev/null || true)`, which turned a
  # missing reader, an expired token, a rate limit, or a mid-pagination API
  # failure into "no live PR claims" — and then went straight on to close
  # PRs, delete branches, strip the ledger, and remove agent-claimed on the
  # strength of a view it never actually read. Every failure below refuses
  # before ANY PR/label/worktree/branch/ledger mutation.
  [[ -x "$SCRIPT_DIR/pr-claims.sh" ]] ||
    die "the authoritative PR-claim reader $SCRIPT_DIR/pr-claims.sh is missing or not executable — cannot read live PR-body claims for $PR_REPO; refuse to mutate anything on an unread claim view"
  PR_ROWS=$("$SCRIPT_DIR/pr-claims.sh" list "$PR_REPO" 2>&1) ||
    die "cannot read live PR-body claims for $PR_REPO — an unreadable claim inventory is not an empty one; refuse to mutate anything: $PR_ROWS"
  open_pr_rows_valid "$PR_ROWS" ||
    die "live PR-body claim inventory for $PR_REPO returned a malformed/truncated row — refuse to mutate anything: $OPEN_PR_BAD_ROW"
  PR_MATCHES=""
  # cut, not `IFS=$'\t' read`: tab is IFS *whitespace*, so bash's read
  # collapses consecutive tabs and silently drops an empty field (e.g. a
  # malformed empty scope column), shifting pr_head to the wrong value.
  while IFS= read -r pr_row; do
    [[ -n "$pr_row" ]] || continue
    pr_number=$(cut -f1 <<<"$pr_row")
    pr_id=$(cut -f2 <<<"$pr_row")
    pr_head=$(cut -f4 <<<"$pr_row")
    [[ -n "$pr_id" ]] || continue
    echo "$pr_id" | grep -qE "^issue-${ISSUE}-" || continue
    if [[ "$CLAIM_ID_SET" -eq 1 && "$pr_id" != "$CLAIM_ID_ARG" ]]; then
      continue
    fi
    PR_MATCHES="${PR_MATCHES}${pr_number}"$'\t'"${pr_id}"$'\t'"${pr_head}"$'\n'
  done <<EOF
$PR_ROWS
EOF
  PR_COUNT=$(printf '%s' "$PR_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')
  if [[ "$PR_COUNT" -gt 1 && "$CLAIM_ID_SET" -eq 0 ]]; then
    die "issue #$ISSUE has multiple live PR claims; pass --claim-id"
  fi
  if [[ "$PR_COUNT" -eq 1 ]]; then
    PR_NUMBER=$(printf '%s' "$PR_MATCHES" | sed -n '1s/\t.*//p')
    PR_CLAIM_ID=$(printf '%s\n' "$PR_MATCHES" | cut -f2)
    PR_HEAD_BRANCH=$(printf '%s\n' "$PR_MATCHES" | cut -f3)
    # sibling check (#153 AC1/AC4): other live open PR-body claims for this
    # issue keep agent-claimed, same as a ledger sibling does below. current
    # claim.sh never writes a ledger row, so this is the only sibling source
    # for a pure PR-body multi-slice issue.
    PR_SIBLINGS=""
    while IFS=$'\t' read -r _s_n _s_id _s_scope _s_head _s_url _s_created _s_updated; do
      [[ -n "$_s_id" ]] || continue
      [[ "$_s_id" == "$PR_CLAIM_ID" ]] && continue
      echo "$_s_id" | grep -qE "^issue-${ISSUE}-" || continue
      PR_SIBLINGS="${PR_SIBLINGS}${_s_id}"$'\n'
    done <<EOF
$PR_ROWS
EOF
    PR_SIBLINGS=$(printf '%s\n' "$PR_SIBLINGS" | grep -E '^issue-' | sort -u || true)
    [[ "$PR_HEAD_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] ||
      die "owning PR #$PR_NUMBER has an unsafe/empty head branch '${PR_HEAD_BRANCH:-?}' — refuse"
    PR_EXPECT_BRANCH=$(branch_for "$PR_CLAIM_ID")
    if [[ "$DRY" -eq 1 ]]; then
      info "dry-run: would close PR #$PR_NUMBER to release the PR-body claim"
      if [[ "$PR_HEAD_BRANCH" == "$PR_EXPECT_BRANCH" ]]; then
        info "dry-run: would then verify the now-terminal PR and run the exact cleanup for worktree/branch '$PR_HEAD_BRANCH'"
      else
        info "dry-run: PR #$PR_NUMBER head branch '$PR_HEAD_BRANCH' is not the branch this claim id derives ('$PR_EXPECT_BRANCH'), so the release would be close-only and report INCOMPLETE for anything it could not prove cleaned up"
      fi
      if [[ -n "$PR_SIBLINGS" ]]; then
        info "dry-run: would keep agent-claimed — sibling PR-body claim(s) remain: $(printf '%s' "$PR_SIBLINGS" | tr '\n' ' ')"
      fi
      exit 0
    fi
    info "closing PR #$PR_NUMBER to release the PR-body claim"
    if ! gh pr close "$PR_NUMBER" --repo "$PR_REPO" >/dev/null; then
      die "gh pr close failed for PR #$PR_NUMBER in $PR_REPO — the claim is still live; nothing else was mutated"
    fi

    # --- hand over to the shared exact cleanup machinery -------------------
    # The PR is terminal now, so its own terminal evidence (exact head SHA,
    # state, base repository, cross-repo flag) can be re-read and bound before
    # anything is removed. terminal_cleanup_release() always exits: 0 only
    # after it has proven the worktree, both branch refs, and the live-claim
    # postcondition; 3 with agent-claimed preserved otherwise.
    #
    # Gate on the head branch matching the one this claim id derives, because
    # that identity is what the cleanup proof is anchored to. An
    # unconventional head branch is not a reason to guess — it falls through
    # to the close-only report below.
    if [[ "$PR_HEAD_BRANCH" == "$PR_EXPECT_BRANCH" ]] &&
       try_terminal_pr_body_release "$PR_CLAIM_ID"; then
      terminal_cleanup_release "$PR_CLAIM_ID"
    fi

    # --- close-only fallback ----------------------------------------------
    # Reached when the closed PR's own terminal evidence is not (yet)
    # readable, or its head branch is not the one this claim id derives.
    # The claim IS released — the PR is closed — but nothing may be removed
    # on unproven identity, so say exactly that.
    OPEN_INCOMPLETE=0
    OPEN_SIBLINGS=""
    if [[ "$PR_HEAD_BRANCH" != "$PR_EXPECT_BRANCH" ]]; then
      warn "PR #$PR_NUMBER head branch '$PR_HEAD_BRANCH' is not the branch claim id '$PR_CLAIM_ID' derives ('$PR_EXPECT_BRANCH') — refusing to clean up a worktree/branch whose identity cannot be bound to this claim"
      # The exact cleanup never ran, so no worktree/branch state was proven
      # either way. Scanning the PR's own head branch for leftovers below
      # cannot substitute for that proof — say INCOMPLETE and let a human
      # decide what the odd branch was.
      OPEN_INCOMPLETE=1
    else
      warn "PR #$PR_NUMBER is closed but its terminal evidence is not readable yet — refusing to clean up on unproven identity"
    fi

    # --- fail-closed post-close reread ------------------------------------
    # Closing the PR is the release; proving it is a separate step. Re-read
    # the authoritative inventory and require the claim to be gone from it,
    # and derive sibling policy from that FRESH view rather than from the
    # pre-close rows (which by definition still contain the claim we just
    # released, and may be stale about siblings besides).
    if ! POST_PR_ROWS=$("$SCRIPT_DIR/pr-claims.sh" list "$PR_REPO" 2>&1); then
      warn "post-close reread of live PR-body claims failed for $PR_REPO — cannot verify the claim was released: $POST_PR_ROWS"
      OPEN_INCOMPLETE=1
    elif ! open_pr_rows_valid "$POST_PR_ROWS"; then
      warn "post-close reread of live PR-body claims returned a malformed/truncated row for $PR_REPO — cannot verify the claim was released: $OPEN_PR_BAD_ROW"
      OPEN_INCOMPLETE=1
    elif printf '%s\n' "$POST_PR_ROWS" | awk -F'\t' -v want="$PR_CLAIM_ID" '$2 == want { f = 1 } END { exit !f }'; then
      warn "claim '$PR_CLAIM_ID' is STILL a live open PR-body claim after closing PR #$PR_NUMBER — refuse to report success"
      OPEN_INCOMPLETE=1
    else
      while IFS= read -r _post_row; do
        [[ -n "$_post_row" ]] || continue
        _post_id=$(cut -f2 <<<"$_post_row")
        [[ -n "$_post_id" ]] || continue
        [[ "$_post_id" == "$PR_CLAIM_ID" ]] && continue
        echo "$_post_id" | grep -qE "^issue-${ISSUE}-" || continue
        OPEN_SIBLINGS="${OPEN_SIBLINGS}${_post_id}"$'\n'
      done <<EOF
$POST_PR_ROWS
EOF
      OPEN_SIBLINGS=$(printf '%s\n' "$OPEN_SIBLINGS" | grep -E '^issue-' | sort -u || true)
    fi

    # --- close-only: worktree/branch are NOT touched here (#153) -----------
    # This path used to `git worktree remove --force` a path GUESSED from the
    # claim id and then `git branch -D` / `git push --delete` with `|| true`,
    # and print "released PR-body claim" regardless — success reported over
    # best-effort cleanup it never re-read or proved. The exact, verified
    # cleanup machinery (registered-worktree resolution by branch enumeration,
    # dirty/TOCTOU revalidation, head-SHA containment proof, CAS branch
    # deletes, postcondition rereads) lives in terminal_cleanup_release() and
    # is only sound against TERMINAL PR evidence — exactly what this PR
    # becomes the moment we close it, and which this early path (running
    # before the ledger ref is even resolved) cannot yet reach in this
    # process. So: close only, prove only, and report honestly. Anything left
    # over is named and returned as INCOMPLETE rather than assumed done.
    if [[ "$KEEP_WORKTREE" -eq 0 || "$KEEP_BRANCH" -eq 0 ]]; then
      OPEN_LEFTOVERS=""
      if [[ "$KEEP_WORKTREE" -eq 0 ]]; then
        if ! OPEN_WT_LIST=$(git worktree list --porcelain 2>&1); then
          warn "cannot enumerate registered worktrees — cannot prove worktree cleanup for '$PR_HEAD_BRANCH': $OPEN_WT_LIST"
          OPEN_INCOMPLETE=1
        elif printf '%s\n' "$OPEN_WT_LIST" | grep -qxF "branch refs/heads/$PR_HEAD_BRANCH"; then
          OPEN_LEFTOVERS="${OPEN_LEFTOVERS}  registered worktree on branch '$PR_HEAD_BRANCH'"$'\n'
        fi
      fi
      if [[ "$KEEP_BRANCH" -eq 0 ]]; then
        if git show-ref --verify --quiet "refs/heads/$PR_HEAD_BRANCH"; then
          OPEN_LEFTOVERS="${OPEN_LEFTOVERS}  local branch '$PR_HEAD_BRANCH'"$'\n'
        fi
        if ! OPEN_LS_REMOTE=$(git ls-remote --heads origin "refs/heads/$PR_HEAD_BRANCH" 2>&1); then
          warn "cannot read remote branch '$PR_HEAD_BRANCH' — cannot prove branch cleanup: $OPEN_LS_REMOTE"
          OPEN_INCOMPLETE=1
        elif [[ -n "$OPEN_LS_REMOTE" ]]; then
          OPEN_LEFTOVERS="${OPEN_LEFTOVERS}  remote branch '$PR_HEAD_BRANCH'"$'\n'
        fi
      fi
      if [[ -n "$OPEN_LEFTOVERS" ]]; then
        warn "PR #$PR_NUMBER is closed and the claim is released, but this close-only path did not remove:"
        printf '%s' "$OPEN_LEFTOVERS" >&2
        warn "re-run: release-claim.sh $ISSUE --claim-id $PR_CLAIM_ID --repo $PR_REPO — the PR is terminal now, so the exact verified terminal cleanup (registered-worktree proof, head-SHA containment, CAS branch deletes) can run"
        OPEN_INCOMPLETE=1
      fi
    fi

    # --- label policy (verified, never assumed) ----------------------------
    if [[ "$OPEN_INCOMPLETE" -eq 1 ]]; then
      info "preserving agent-claimed on #$ISSUE — open-PR release did not fully complete or could not be verified"
    elif [[ -n "$OPEN_SIBLINGS" ]]; then
      # Sibling policy is unchanged (#153 AC1/AC4): other live PR-body claims
      # on this issue keep agent-claimed. What changed is that the label's
      # presence is re-read rather than assumed.
      OPEN_LABELS=$(gh issue view "$ISSUE" --repo "$PR_REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$OPEN_LABELS" == "?" ]]; then
        warn "could not read labels on $PR_REPO#$ISSUE — sibling-claim label preservation UNVERIFIED"
        OPEN_INCOMPLETE=1
      elif ! echo ",$OPEN_LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is ABSENT on $PR_REPO#$ISSUE — sibling PR-body claim(s) remain but the label is missing; re-add it by hand"
        OPEN_INCOMPLETE=1
      else
        info "keeping agent-claimed on #$ISSUE — sibling PR-body claim(s) remain (verified): $(printf '%s' "$OPEN_SIBLINGS" | tr '\n' ' ')"
      fi
    elif [[ "$KEEP_LABEL" -eq 1 ]]; then
      OPEN_LABELS=$(gh issue view "$ISSUE" --repo "$PR_REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$OPEN_LABELS" == "?" ]]; then
        warn "could not read labels on $PR_REPO#$ISSUE — --keep-label preservation UNVERIFIED"
        OPEN_INCOMPLETE=1
      elif ! echo ",$OPEN_LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is ABSENT on $PR_REPO#$ISSUE — --keep-label required the label to stay"
        OPEN_INCOMPLETE=1
      else
        info "keeping agent-claimed on $PR_REPO#$ISSUE — --keep-label verified"
      fi
    else
      if ! gh issue edit "$ISSUE" --repo "$PR_REPO" --remove-label agent-claimed >/dev/null; then
        warn "gh issue edit failed for #$ISSUE in $PR_REPO"
      fi
      OPEN_LABELS=$(gh issue view "$ISSUE" --repo "$PR_REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$OPEN_LABELS" == "?" ]]; then
        warn "could not re-read labels on #$ISSUE — agent-claimed removal UNVERIFIED"
        OPEN_INCOMPLETE=1
      elif echo ",$OPEN_LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is STILL on $PR_REPO#$ISSUE — remove it by hand before declaring Law 10 done"
        OPEN_INCOMPLETE=1
      else
        info "removed agent-claimed from $PR_REPO#$ISSUE (verified)"
      fi
    fi

    if [[ "$OPEN_INCOMPLETE" -eq 1 ]]; then
      echo "release-claim.sh: INCOMPLETE — open-PR claim release did not finish for issue $ISSUE (see warnings above)" >&2
      exit 3
    fi
    info "OK — released PR-body claim for #$ISSUE (PR #$PR_NUMBER closed and verified no longer live; nothing left to clean up)"
    exit 0
  fi
fi

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
    if [[ "$CAS_MODE" -eq 0 ]] && try_terminal_pr_body_release "$CLAIM_ID_ARG"; then
      :
    else
      die "no live claim '$CLAIM_ID_ARG' at $REF (checked ledger and terminal PR-body evidence)"
    fi
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

# Remove exactly one registered worktree path. No default-path derivation, no
# rm -rf fallback. Fail closed on symlink/unregistered/branch mismatch.
remove_exact_worktree() {
  local wt="$1" expect_br="${2:-}" got_br
  wt="${wt%/}"
  if [[ -L "$wt" ]]; then
    warn "worktree path is a symlink — refuse removal: $wt"
    return 1
  fi
  if [[ ! -d "$wt" ]]; then
    warn "worktree path missing or not a directory — refuse removal: $wt"
    return 1
  fi
  if ! worktree_registered "$wt"; then
    warn "worktree path is not a registered git worktree — refuse removal (no default-path fallback): $wt"
    return 1
  fi
  if [[ -n "$expect_br" ]]; then
    got_br=$(worktree_branch "$wt" || true)
    if [[ "$got_br" != "$expect_br" ]]; then
      warn "worktree branch mismatch at $wt (want '$expect_br', got '${got_br:-detached/unknown}') — refuse removal"
      return 1
    fi
  fi
  info "removing exact registered worktree $wt"
  if ! git worktree remove --force "$wt" 2>/dev/null; then
    warn "git worktree remove failed for $wt — refuse rm -rf fallback"
    return 1
  fi
  return 0
}

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
      if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
        if [[ -n "$WORKTREE_PATH_ARG" ]]; then
          echo "    KEEP worktree:   $WORKTREE_PATH_ARG"
        else
          echo "    KEEP worktree:   $(wt_dir_for "$id")"
        fi
      else
        if [[ -n "$WORKTREE_PATH_ARG" ]]; then
          echo "    remove worktree: $WORKTREE_PATH_ARG (exact registered path only)"
        else
          echo "    remove worktree: $(wt_dir_for "$id")"
        fi
      fi
      if [[ "$KEEP_BRANCH" -eq 1 ]]; then
        echo "    KEEP branch:     ${EXPECTED_BRANCH:-$(branch_for "$id")}"
      else
        echo "    delete branch:   ${EXPECTED_BRANCH:-$(branch_for "$id")}"
      fi
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

# Verified terminal PR-body evidence (#153): a dedicated, self-contained
# mutation path — never the ledger-oriented flow below, which assumes a
# ledger row and its early non-CAS worktree removal is exactly what AC1
# forbids for this claim shape. terminal_cleanup_release() always exits.
if [[ "${TERMINAL_MODE:-0}" -eq 1 ]]; then
  terminal_cleanup_release "$TARGET_IDS"
  exit 3  # unreachable: terminal_cleanup_release always exits above
fi

INCOMPLETE=0
PRESERVE_LABEL_EARLY=0

# --- worktrees + branches -------------------------------------------------
# Ordering contract (#73):
# - Claimed prune (--worktree-path) and CAS mode must NOT destructively remove
#   worktrees/branches before expected-source/path/blob CAS validation, cleanup
#   push, and authoritative post-mutation reread prove the exact target claim
#   is absent. A renewal/push/OID/reread failure leaves worktree+branch intact.
# - Ordinary non-CAS release (no --worktree-path) keeps historical early cleanup.
# - --keep-worktree / --keep-branch never remove (reaper default).
DEFER_WT_BRANCH=0
if [[ -n "$WORKTREE_PATH_ARG" ]] || [[ "$CAS_MODE" -eq 1 ]]; then
  DEFER_WT_BRANCH=1
fi

if [[ -n "$TARGET_IDS" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
      if [[ -n "$WORKTREE_PATH_ARG" && -d "$WORKTREE_PATH_ARG" ]]; then
        info "keeping worktree $WORKTREE_PATH_ARG (--keep-worktree)"
      else
        wt=$(wt_dir_for "$id")
        if [[ -d "$wt" ]]; then
          info "keeping worktree $wt (--keep-worktree)"
        fi
      fi
    elif [[ "$DEFER_WT_BRANCH" -eq 1 ]]; then
      # Non-destructive precheck only for claimed prune path.
      if [[ -n "$WORKTREE_PATH_ARG" ]]; then
        if [[ -L "$WORKTREE_PATH_ARG" ]] || [[ ! -d "$WORKTREE_PATH_ARG" ]] || ! worktree_registered "$WORKTREE_PATH_ARG"; then
          warn "claimed prune target unsafe/unregistered before CAS — will not remove; claim strip may still proceed with incomplete prune"
          # Do not set INCOMPLETE yet: strip may succeed; final prune revalidates.
        elif [[ -n "${EXPECTED_BRANCH:-}" ]]; then
          _pre_br=$(worktree_branch "$WORKTREE_PATH_ARG" || true)
          if [[ "$_pre_br" != "$EXPECTED_BRANCH" ]]; then
            warn "claimed prune branch mismatch before CAS (want '$EXPECTED_BRANCH', got '${_pre_br:-detached}') — will revalidate after ledger removal"
          fi
        fi
        info "deferring exact worktree removal until CAS + verified cleanup push succeed: $WORKTREE_PATH_ARG"
      else
        info "deferring worktree removal until CAS + verified cleanup succeed (CAS mode)"
      fi
    else
      # Ordinary non-CAS path: historical early worktree removal.
      wt=$(wt_dir_for "$id")
      if [[ -d "$wt" ]]; then
        info "removing worktree $wt"
        if worktree_registered "$wt"; then
          git worktree remove --force "$wt" 2>/dev/null || {
            warn "git worktree remove failed for registered $wt — refuse rm -rf"
            INCOMPLETE=1
          }
        else
          rm -rf "$wt"
        fi
      fi
    fi
    if [[ "$KEEP_BRANCH" -eq 1 ]]; then
      :
    elif [[ "$DEFER_WT_BRANCH" -eq 1 ]]; then
      info "deferring branch deletion until CAS + verified cleanup succeed"
    else
      br="${EXPECTED_BRANCH:-$(branch_for "$id")}"
      git branch -D "$br" 2>/dev/null || true
      git push origin --delete "$br" 2>/dev/null || true
    fi
  done <<EOF
$TARGET_IDS
EOF
  if [[ "$KEEP_WORKTREE" -eq 0 && "$DEFER_WT_BRANCH" -eq 0 ]]; then
    git worktree prune 2>/dev/null || true
  fi
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
  if [[ "$CAS_MODE" -eq 1 ]]; then
    # Bind to the exact remote base already fetched; re-fetch and require success.
    if ! base=$(fetch_remote_base); then
      warn "CAS strip: fetch of remote base failed — refuse cleanup (no local fallback)"
      return 1
    fi
  else
    base=main
    git show-ref --verify --quiet refs/heads/main || base=master
    git fetch origin "$base" >/dev/null 2>&1 || true
  fi
  CLEANUP_BASE="$base"

  local tmpwt
  tmpwt=$(mktemp -d "${TMPDIR:-/tmp}/gibson-release-claim.XXXXXX") || return 1
  rm -rf "$tmpwt"

  # Always prefer origin/$base. CAS mode never falls back to local $base.
  if ! git worktree add --detach "$tmpwt" "origin/$base" >/dev/null 2>&1; then
    if [[ "$CAS_MODE" -eq 1 ]]; then
      warn "CAS strip: cannot attach disposable worktree to origin/$base — refuse"
      return 1
    fi
    git worktree add --detach "$tmpwt" "$base" >/dev/null 2>&1 || return 1
  fi

  local rc=0
  (
    cd "$tmpwt" || exit 1
    local touched=0

    # CAS: re-verify exact frozen blob/path (or legacy active-work blob+row)
    # before any mutation. If evidence changed, refuse — renewed claim survives.
    if [[ "${CAS_MODE:-0}" -eq 1 ]]; then
      local id cas_path cas_blob cur_blob active_blob exp_active exp_id
      id=$(printf '%s\n' "$TARGET_IDS" | head -n1)
      if [[ "$EXPECTED_SOURCE" == "file" ]]; then
        cas_path="${EXPECTED_CLAIM_PATH}"
        cas_blob="${EXPECTED_CLAIM_BLOB}"
        if [[ ! -f "$cas_path" ]]; then
          echo "release-claim.sh: ERROR: CAS expected path absent at origin/$base: $cas_path" >&2
          exit 1
        fi
        cur_blob=$(git ls-files -s -- "$cas_path" 2>/dev/null | awk '{print $2; exit}')
        if [[ -z "$cur_blob" ]]; then
          cur_blob=$(git rev-parse "HEAD:$cas_path" 2>/dev/null || true)
        fi
        if [[ -z "$cur_blob" || "$cur_blob" != "$cas_blob" ]]; then
          echo "release-claim.sh: ERROR: CAS blob OID mismatch for $cas_path (want $cas_blob, got ${cur_blob:-absent}) — refuse (renewed/changed claim survives)" >&2
          exit 1
        fi
        # Path must match docs/claims/<claim-id>.md for the frozen id
        if [[ "$cas_path" != "docs/claims/${id}.md" ]]; then
          echo "release-claim.sh: ERROR: CAS path $cas_path does not match frozen claim id $id" >&2
          exit 1
        fi
      elif [[ "$EXPECTED_SOURCE" == "legacy" ]]; then
        # EXPECTED_CLAIM_BLOB = "<active-work-blob>:<claim-id>"
        exp_active="${EXPECTED_CLAIM_BLOB%%:*}"
        exp_id="${EXPECTED_CLAIM_BLOB#*:}"
        if [[ "$exp_id" != "$id" ]]; then
          echo "release-claim.sh: ERROR: CAS legacy blob key claim-id mismatch" >&2
          exit 1
        fi
        if [[ ! -f docs/active-work.md ]]; then
          echo "release-claim.sh: ERROR: CAS legacy active-work.md absent — refuse" >&2
          exit 1
        fi
        active_blob=$(git rev-parse HEAD:docs/active-work.md 2>/dev/null || true)
        if [[ -z "$active_blob" || "$active_blob" != "$exp_active" ]]; then
          echo "release-claim.sh: ERROR: CAS legacy active-work blob mismatch (want $exp_active, got ${active_blob:-absent}) — refuse (renewed row survives)" >&2
          exit 1
        fi
        if ! awk -F'|' -v want="$id" '
          /^\|/ {
            cid=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",cid);
            if (cid==want) found=1
          }
          END { exit !found }
        ' docs/active-work.md; then
          echo "release-claim.sh: ERROR: CAS legacy row for $id absent after blob match — refuse" >&2
          exit 1
        fi
      fi
    fi

    # per-lane claim files (current form) — exact id only
    local id
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      if [[ -f "docs/claims/$id.md" ]]; then
        # Re-check file OID immediately before rm when CAS
        if [[ "${CAS_MODE:-0}" -eq 1 && "$EXPECTED_SOURCE" == "file" ]]; then
          cur_blob=$(git rev-parse "HEAD:docs/claims/${id}.md" 2>/dev/null || true)
          if [[ "$cur_blob" != "$EXPECTED_CLAIM_BLOB" ]]; then
            echo "release-claim.sh: ERROR: CAS pre-rm blob race for $id" >&2
            exit 1
          fi
        fi
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
        # CAS legacy: re-verify active-work blob still matches before replace
        if [[ "${CAS_MODE:-0}" -eq 1 && "$EXPECTED_SOURCE" == "legacy" ]]; then
          active_blob=$(git rev-parse HEAD:docs/active-work.md 2>/dev/null || true)
          exp_active="${EXPECTED_CLAIM_BLOB%%:*}"
          if [[ "$active_blob" != "$exp_active" ]]; then
            rm -f "$tmp"
            echo "release-claim.sh: ERROR: CAS legacy pre-write blob race — refuse" >&2
            exit 1
          fi
        fi
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
    # Normal push only (no force). If remote advanced (renewal) push fails → incomplete.
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
if [[ "${PRESERVE_LABEL_EARLY:-0}" -eq 1 ]]; then
  PRESERVE_LABEL=1
fi

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

  # GitHub-native sibling check (#153 AC1/AC4): the one authoritative live-
  # claim view is ledger rows UNION live open PR-body claims, not the ledger
  # alone — a sibling slice can be a still-open PR-body claim with no ledger
  # row at all. Best-effort like the PR-body lookup above: a gh/pr-claims
  # failure here falls back to ledger-only residual (legacy behavior
  # preserved, #153 AC6) rather than blocking cleanup over evidence gh cannot
  # currently see.
  if [[ -n "${PR_REPO:-}" && -x "$SCRIPT_DIR/pr-claims.sh" ]]; then
    _open_pr_rows=$("$SCRIPT_DIR/pr-claims.sh" list "$PR_REPO" 2>/dev/null || true)
    _open_pr_siblings=""
    while IFS=$'\t' read -r _pr_n _pr_id _pr_s _pr_h _pr_u _pr_c _pr_up; do
      [[ -n "$_pr_id" ]] || continue
      claim_id_for_issue "$_pr_id" || continue
      printf '%s\n' "$TARGET_IDS" | grep -qxF -- "$_pr_id" && continue
      _open_pr_siblings="${_open_pr_siblings}${_pr_id}"$'\n'
    done <<EOF
$_open_pr_rows
EOF
    _open_pr_siblings=$(printf '%s\n' "$_open_pr_siblings" | grep -E '^issue-' | sort -u || true)
    if [[ -n "$_open_pr_siblings" ]]; then
      RESIDUAL_IDS=$(printf '%s\n%s\n' "$RESIDUAL_IDS" "$_open_pr_siblings" | grep -E '^issue-' | sort -u || true)
    fi
  fi
else
  info "no claim to remove"
fi

# --- deferred worktree/branch removal (CAS / claimed prune) ---------------
# Only after successful strip AND authoritative reread proves the exact target
# claim is absent (no renewal/sibling identity confusion). Failures leave
# worktree+branch untouched and report incomplete.
if [[ -n "$TARGET_IDS" && "$DEFER_WT_BRANCH" -eq 1 ]]; then
  deferred_ok=1
  if [[ "$STRIP_OK" -ne 1 || "$INCOMPLETE" -eq 1 || "$PRESERVE_LABEL" -eq 1 ]]; then
    # Renewal, push rejection, OID mismatch, reread failure, or target still live:
    # leave worktree and branch untouched.
    if [[ "$KEEP_WORKTREE" -eq 0 ]]; then
      info "leaving worktree(s) untouched — cleanup incomplete or target still live"
    fi
    if [[ "$KEEP_BRANCH" -eq 0 ]]; then
      info "leaving branch(es) untouched — cleanup incomplete or target still live"
    fi
    deferred_ok=0
  fi

  if [[ "$deferred_ok" -eq 1 ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      if [[ "$KEEP_WORKTREE" -eq 0 ]]; then
        if [[ -n "$WORKTREE_PATH_ARG" ]]; then
          # Revalidate exact registered path/branch identity immediately before removal.
          info "post-CAS: revalidating exact registered worktree before prune"
          if ! remove_exact_worktree "$WORKTREE_PATH_ARG" "${EXPECTED_BRANCH:-}"; then
            warn "final claimed worktree removal failed for $WORKTREE_PATH_ARG — incomplete (claim row already released; not claiming full success)"
            INCOMPLETE=1
            PRESERVE_LABEL=1
            deferred_ok=0
          fi
        else
          wt=$(wt_dir_for "$id")
          if [[ -d "$wt" ]]; then
            info "post-CAS: removing worktree $wt"
            if worktree_registered "$wt"; then
              if ! git worktree remove --force "$wt" 2>/dev/null; then
                warn "git worktree remove failed for registered $wt — refuse rm -rf; incomplete"
                INCOMPLETE=1
                PRESERVE_LABEL=1
                deferred_ok=0
              fi
            else
              # Ordinary default-path leftover under CAS: rm only unregistered dir.
              rm -rf "$wt"
            fi
          fi
        fi
      fi
      if [[ "$KEEP_BRANCH" -eq 0 && "$deferred_ok" -eq 1 ]]; then
        br="${EXPECTED_BRANCH:-$(branch_for "$id")}"
        git branch -D "$br" 2>/dev/null || true
        git push origin --delete "$br" 2>/dev/null || true
      fi
    done <<EOF
$TARGET_IDS
EOF
    if [[ "$KEEP_WORKTREE" -eq 0 && "$deferred_ok" -eq 1 ]]; then
      git worktree prune 2>/dev/null || true
    fi
  fi
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
  # TERMINAL_MODE releases exit from terminal_cleanup_release() above and
  # never reach here — this is always the ledger-row release path.
  info "OK — claim released for issue $ISSUE"
fi
