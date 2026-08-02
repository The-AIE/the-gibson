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

  Empty ledger: when a *valid* ledger ref has no docs/claims/* and no
  docs/active-work.md, that is a valid empty ledger (no live claims), not a
  hard fail. A missing/unborn/invalid main|master ref is NOT an empty ledger —
  the script fails hard. Cleanup of worktrees/labels can still complete
  truthfully without inventing a row when the ref is valid and empty.

ENV
  GIBSON_CANONICAL   claim-table repo path (default: cwd)

EXIT
  0  claim fully released (or truthfully nothing to release + label policy done)
  1  a hard precondition failed (nothing was cleaned)
  3  cleanup ran but did not finish: the claim row or the agent-claimed label
     is still live. The message names which. Never silent half-cleanup (L-009).

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
PREFIX=""
REPO_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-branch) KEEP_BRANCH=1 ;;
    --keep-label) KEEP_LABEL=1 ;;
    --dry-run) DRY=1 ;;
    --claim-id) CLAIM_ID_ARG="${2:-}"; shift ;;
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

# A missing docs/claims tree and absent active-work.md on a *valid* commit is
# a valid *empty* ledger (every claim already released, or never filed) — not
# corruption. Treat it as zero live claims and continue label/worktree cleanup.
# A named --claim-id that is not present still hard-fails below.
HAS_ACTIVE=0
HAS_CLAIMS_TREE=0
if git cat-file -e "$REF:docs/active-work.md" 2>/dev/null; then
  HAS_ACTIVE=1
fi
if [[ -n "$(git ls-tree --name-only "$REF" docs/claims/ 2>/dev/null)" ]]; then
  HAS_CLAIMS_TREE=1
fi
if [[ "$HAS_ACTIVE" -eq 0 && "$HAS_CLAIMS_TREE" -eq 0 ]]; then
  info "claim ledger at $REF is empty (no docs/claims/* and no docs/active-work.md) — treating as no live claims"
fi

# Claim ids we own. issue-<N>-…, plus issue-<ns>-<N>-… when --prefix is given.
# The alpha namespace is what keeps issue-1<N>- from matching issue-<N>-.
if [[ -n "$CLAIM_ID_ARG" ]]; then
  MATCH_RE="(^|[^A-Za-z0-9-])${CLAIM_ID_ARG}([^A-Za-z0-9-]|$)"
elif [[ -n "$PREFIX" ]]; then
  MATCH_RE="issue-(${PREFIX}-)?${ISSUE}-"
else
  MATCH_RE="issue-([A-Za-z][A-Za-z0-9]*-)?${ISSUE}-"
fi

# Claims live one-per-file in docs/claims/ (L-023); rows in docs/active-work.md
# are the legacy form and are still released.
claim_ids_matching() {
  {
    git ls-tree --name-only "$REF" docs/claims/ 2>/dev/null |
      sed 's|^docs/claims/||;s|\.md$||'
    git show "$REF:docs/active-work.md" 2>/dev/null |
      grep -E '^\| ' |
      awk -F'|' '{print $3}' |
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
  } | grep -E '^issue-' | grep -E "$1" | sort -u || true
}

# Every live row for this issue, so we can tell "released the last one" from
# "released one slice of several" (L-024).
ALL_RE="issue-([A-Za-z][A-Za-z0-9]*-)?${ISSUE}-"
ALL_IDS=$(claim_ids_matching "$ALL_RE")
TARGET_IDS=$(claim_ids_matching "$MATCH_RE")

if [[ -z "$TARGET_IDS" ]]; then
  if [[ -n "$CLAIM_ID_ARG" ]]; then
    die "no live claim '$CLAIM_ID_ARG' at $REF"
  fi
  info "no live claim for issue $ISSUE — will still try label/worktree cleanup"
fi

WT_PARENT="$(cd "$CANONICAL/.." && pwd)"

# Worktree/branch per released claim id, derived from the id rather than
# assumed, so namespaced ids (issue-template-5-x) resolve correctly (L-037).
wt_dir_for() { echo "$WT_PARENT/wt-${1#issue-}"; }
branch_for() { echo "feat/${1#issue-}"; }

residual_after_release() {
  # ids in ALL_IDS that are not in TARGET_IDS
  local id
  echo "$ALL_IDS" | while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    echo "$TARGET_IDS" | grep -qxF "$id" || echo "$id"
  done
}
RESIDUAL_IDS=$(residual_after_release)

if [[ "$DRY" -eq 1 ]]; then
  echo "DRY RUN would:"
  echo "  claim-table repo: $CANONICAL (branch: $(git rev-parse --abbrev-ref HEAD), left untouched)"
  echo "  product repo:     ${REPO_ARG:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '(gh default)')}"
  if [[ -n "$TARGET_IDS" ]]; then
    echo "$TARGET_IDS" | while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      echo "  release claim:   $id"
      echo "    remove worktree: $(wt_dir_for "$id")"
      echo "    delete branch:   $(branch_for "$id")"
    done
  else
    echo "  release claim:   (none matched $MATCH_RE)"
  fi
  if [[ -n "$RESIDUAL_IDS" ]]; then
    echo "$RESIDUAL_IDS" | while IFS= read -r id; do
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
strip_claim_rows() {
  local tmpwt
  tmpwt=$(mktemp -d "${TMPDIR:-/tmp}/gibson-release-claim.XXXXXX") || return 1
  rm -rf "$tmpwt"

  local base
  base=main
  git show-ref --verify --quiet refs/heads/main || base=master

  git fetch origin "$base" >/dev/null 2>&1 || true
  git worktree add --detach "$tmpwt" "origin/$base" >/dev/null 2>&1 ||
    git worktree add --detach "$tmpwt" "$base" >/dev/null 2>&1 || return 1

  local rc=0
  (
    cd "$tmpwt" || exit 1
    local touched=0

    # per-lane claim files (current form)
    local id
    for id in $TARGET_IDS; do
      if [[ -f "docs/claims/$id.md" ]]; then
        git rm -q "docs/claims/$id.md" || exit 1
        touched=1
      fi
    done

    # legacy shared table
    local active=docs/active-work.md
    if [[ -f "$active" ]] && grep -E "$MATCH_RE" "$active" >/dev/null 2>&1; then
      local tmp
      tmp=$(mktemp) || exit 1
      grep -v -E "$MATCH_RE" "$active" > "$tmp"
      mv "$tmp" "$active"
      git add "$active" || exit 1
      touched=1
    fi

    [[ "$touched" -eq 1 ]] || exit 2  # nothing to strip
    git commit -s -q -m "release-claim: ${CLAIM_ID_ARG:-issue-${ISSUE}}

Post-merge cleanup per Law 10 / docs/05." || exit 1
    git push origin "HEAD:$base" || exit 1
  ) || rc=$?

  git worktree remove --force "$tmpwt" >/dev/null 2>&1 || rm -rf "$tmpwt"
  git worktree prune >/dev/null 2>&1 || true
  return $rc
}

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
      warn "Fix by hand on main: git rm the docs/claims/<id>.md files (or drop rows matching '$MATCH_RE' from docs/active-work.md), then push."
      INCOMPLETE=1
      ;;
  esac
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
  if [[ -n "$RESIDUAL_IDS" ]]; then
    # L-024: siblings are still working this issue; the label is still true.
    # Residual rows on the ledger are themselves the verification — leaving
    # the label is the complete policy without a GitHub round-trip.
    info "keeping agent-claimed on #$ISSUE — residual claims remain:"
    echo "$RESIDUAL_IDS" | sed 's/^/  /'
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
  if [[ -n "$RESIDUAL_IDS" ]]; then
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
