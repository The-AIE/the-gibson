#!/usr/bin/env bash
# claim.sh — atomic issue claim + worktree (docs/05)
set -euo pipefail

usage() {
  cat <<'EOF'
claim.sh — claim a GitHub issue and open an isolated worktree

WHAT IT DOES
  Marks the issue as agent-claimed, checks that your scope does not overlap a
  live claim, appends a claim row to docs/active-work.md on main (signed commit),
  and creates a git worktree + branch for the work.

WHY
  Two agents editing the same files silently destroyed each other's work
  (lesson L-001). Claims + worktrees make collisions physically hard.

RISKS
  - Pushes a small commit to main (claim row only). Undo: release-claim.sh.
  - Adds the agent-claimed label. Undo: gh issue edit --remove-label.
  - Creates ../wt-<issue>-<slug> next to the canonical checkout.
  - Exits non-zero and removes the label if a conflict is found.

USAGE
  claim.sh <issue> <slug> <scope...>
  claim.sh --help

  issue   GitHub issue number
  slug    short branch slug (e.g. password-reset)
  scope   file globs/paths that become the claim scope (one or more)

ENV
  GIBSON_CANONICAL   path to target repo canonical checkout (default: cwd)
  GIBSON_SESSION     session id recorded in the claim row (default: $USER@host)

EXAMPLES
  cd ~/Code/acme-app
  /path/to/the-gibson/scripts/claim.sh 42 password-reset 'app/api/auth/**' 'lib/email.ts'

  GIBSON_CANONICAL=~/Code/acme-app /path/to/the-gibson/scripts/claim.sh 7 nav-gen 'components/nav/**'
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 3 ]]; then
  usage
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
  exit 2
fi

ISSUE="$1"
SLUG="$2"
shift 2
SCOPE="$*"

CANONICAL="${GIBSON_CANONICAL:-$(pwd)}"
SESSION="${GIBSON_SESSION:-${USER:-agent}@$(hostname -s 2>/dev/null || echo host)}"
CLAIM_ID="issue-${ISSUE}-${SLUG}"
BRANCH="feat/${ISSUE}-${SLUG}"
WT_DIR="$(cd "$CANONICAL/.." && pwd)/wt-${ISSUE}-${SLUG}"
ACTIVE="$CANONICAL/docs/active-work.md"
UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

die() { echo "claim.sh: ERROR: $*" >&2; exit 1; }
info() { echo "claim.sh: $*"; }

command -v git >/dev/null || die "git required"
command -v gh >/dev/null || die "gh (GitHub CLI) required"

[[ -d "$CANONICAL/.git" || -f "$CANONICAL/.git" ]] || die "not a git repo: $CANONICAL"
[[ -f "$ACTIVE" ]] || die "missing $ACTIVE — create claim table first (docs/13)"

# Ensure we operate claim commit on main in canonical
cd "$CANONICAL"
git fetch origin 2>/dev/null || true

# Refuse dirty active-work in a way that would mix product edits (soft check)
if ! git diff --quiet -- docs/active-work.md 2>/dev/null; then
  die "docs/active-work.md has uncommitted local edits — resolve first"
fi

# Overlap check against live claims (any non-header row)
if grep -E '^\| [0-9]{4}-' "$ACTIVE" >/dev/null 2>&1; then
  while IFS= read -r line; do
    # columns: | utc | claim | scope | session |
    row_scope=$(echo "$line" | awk -F'|' '{print $4}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    row_claim=$(echo "$line" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$row_scope" || "$row_scope" == "scope" ]] && continue
    for s in $SCOPE; do
      # crude path overlap: either side contains the other token
      case " $row_scope " in
        *" $s "*|*"${s%%\*}*"*) die "scope overlap with live claim $row_claim (scope: $row_scope). Coordinate; do not race." ;;
      esac
      case " $SCOPE " in
        *)
          # also check if our scope token appears in their scope string
          if echo "$row_scope" | grep -F "${s%%\*}" >/dev/null 2>&1; then
            die "scope overlap with live claim $row_claim (scope: $row_scope)"
          fi
          ;;
      esac
    done
  done < <(grep -E '^\| ' "$ACTIVE" | grep -v 'UTC\|---\|utc')
fi

LABEL_ADDED=0
undo_label() {
  if [[ "$LABEL_ADDED" -eq 1 ]]; then
    info "undo: removing agent-claimed from #$ISSUE"
    gh issue edit "$ISSUE" --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)" --remove-label agent-claimed 2>/dev/null || true
  fi
}
trap undo_label ERR

info "adding agent-claimed to #$ISSUE"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh issue edit "$ISSUE" --repo "$REPO" --add-label agent-claimed
LABEL_ADDED=1

# Append claim row on main
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "main" && "$CURRENT_BRANCH" != "master" ]]; then
  info "checking out main for claim commit (was $CURRENT_BRANCH)"
  git checkout main 2>/dev/null || git checkout master
fi
git pull --ff-only 2>/dev/null || true

ROW="| $UTC | $CLAIM_ID | $SCOPE | session:$SESSION |"
echo "$ROW" >> "$ACTIVE"
git add docs/active-work.md
git commit -s -m "claim: $CLAIM_ID

Scope: $SCOPE
Session: $SESSION

Signed claim row per docs/05."
git push origin HEAD

# Worktree
if [[ -d "$WT_DIR" ]]; then
  die "worktree path already exists: $WT_DIR"
fi
DEFAULT_REMOTE_BRANCH="origin/main"
git rev-parse "$DEFAULT_REMOTE_BRANCH" >/dev/null 2>&1 || DEFAULT_REMOTE_BRANCH="origin/master"

info "creating worktree $WT_DIR branch $BRANCH"
git worktree add "$WT_DIR" -b "$BRANCH" "$DEFAULT_REMOTE_BRANCH"

LABEL_ADDED=0  # success — do not undo label
trap - ERR

cat <<EOF
claim.sh: OK
  issue:    #$ISSUE
  claim:    $CLAIM_ID
  branch:   $BRANCH
  worktree: $WT_DIR
  scope:    $SCOPE

Next:
  cd $WT_DIR
  # install deps if needed, then gate-baseline.sh && implement
EOF
