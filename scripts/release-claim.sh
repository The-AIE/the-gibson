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

WHY
  Abandoned claims block the fleet (Law 10). Cleanup must be as automatic as claim.

RISKS
  - Deletes worktree directory (uncommitted work there is lost). Check first.
  - Commits to main (claim-row removal only).
  - Removes GitHub label. Low risk; re-claim if you still need the issue.

USAGE
  release-claim.sh <issue> [--keep-branch] [--dry-run]
  release-claim.sh --help

ENV
  GIBSON_CANONICAL   target repo path (default: cwd)

EXAMPLES
  cd ~/Code/acme-app
  /path/to/the-gibson/scripts/release-claim.sh 42

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
DRY=0
for a in "$@"; do
  case "$a" in
    --keep-branch) KEEP_BRANCH=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "unknown arg: $a" >&2; usage; exit 2 ;;
  esac
done

CANONICAL="${GIBSON_CANONICAL:-$(pwd)}"
ACTIVE="$CANONICAL/docs/active-work.md"
die() { echo "release-claim.sh: ERROR: $*" >&2; exit 1; }
info() { echo "release-claim.sh: $*"; }

cd "$CANONICAL"
[[ -f "$ACTIVE" ]] || die "missing $ACTIVE"

# Find claim rows matching issue-N-
MAPFILE=()
while IFS= read -r line; do
  MAPFILE+=("$line")
done < <(grep -E "issue-${ISSUE}-" "$ACTIVE" || true)

if [[ ${#MAPFILE[@]} -eq 0 ]]; then
  info "no claim row for issue $ISSUE — will still try label/worktree cleanup"
fi

CLAIM_ID=""
SLUG=""
if [[ ${#MAPFILE[@]} -gt 0 ]]; then
  CLAIM_ID=$(echo "${MAPFILE[0]}" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  SLUG="${CLAIM_ID#issue-${ISSUE}-}"
fi

WT_DIR="$(cd "$CANONICAL/.." && pwd)/wt-${ISSUE}-${SLUG}"
BRANCH="feat/${ISSUE}-${SLUG}"

if [[ "$DRY" -eq 1 ]]; then
  echo "DRY RUN would:"
  echo "  remove worktree: $WT_DIR"
  echo "  delete branch:   $BRANCH"
  echo "  strip claim rows matching issue-${ISSUE}-"
  echo "  remove label agent-claimed from #$ISSUE"
  exit 0
fi

# Worktree remove
if [[ -n "$SLUG" && -d "$WT_DIR" ]]; then
  info "removing worktree $WT_DIR"
  git worktree remove --force "$WT_DIR" 2>/dev/null || rm -rf "$WT_DIR"
  git worktree prune 2>/dev/null || true
fi

# Also catch any wt-<issue>-* dirs
for d in "$(cd "$CANONICAL/.." && pwd)"/wt-${ISSUE}-*; do
  [[ -e "$d" ]] || continue
  info "removing leftover worktree $d"
  git worktree remove --force "$d" 2>/dev/null || rm -rf "$d"
done

# Branch delete
if [[ -n "$SLUG" && "$KEEP_BRANCH" -eq 0 ]]; then
  git branch -D "$BRANCH" 2>/dev/null || true
  git push origin --delete "$BRANCH" 2>/dev/null || true
fi

# Strip claim rows on main
CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT" != "main" && "$CURRENT" != "master" ]]; then
  git checkout main 2>/dev/null || git checkout master
fi
git pull --ff-only 2>/dev/null || true

if grep -E "issue-${ISSUE}-" "$ACTIVE" >/dev/null 2>&1; then
  tmp=$(mktemp)
  grep -v -E "issue-${ISSUE}-" "$ACTIVE" > "$tmp"
  mv "$tmp" "$ACTIVE"
  git add docs/active-work.md
  git commit -s -m "release-claim: issue-${ISSUE}

Post-merge cleanup per Law 10 / docs/05."
  git push origin HEAD
  info "claim row removed"
else
  info "no claim row to remove"
fi

# Label
if command -v gh >/dev/null; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  if [[ -n "${REPO:-}" ]]; then
    gh issue edit "$ISSUE" --repo "$REPO" --remove-label agent-claimed 2>/dev/null || true
    info "removed agent-claimed from #$ISSUE"
  fi
fi

info "OK — claim released for issue $ISSUE"
