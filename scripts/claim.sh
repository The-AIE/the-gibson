#!/usr/bin/env bash
# claim.sh — atomic issue claim + worktree (docs/05)
set -euo pipefail

usage() {
  cat <<'EOF'
claim.sh — claim a GitHub issue and open an isolated worktree

WHAT IT DOES
  Marks the issue as agent-claimed, refuses to claim something already claimed,
  writes ONE claim file at docs/claims/<claim-id>.md on main (signed commit), and
  creates a git worktree + branch for the work.

  One file per claim, never a shared table: two lanes claiming at the same moment
  touch different paths, so their claim commits do not conflict. `docs/active-work.md`
  is still read for claims made by older versions, and is now a rendered view
  (`claims-status.sh`) rather than a file anyone appends to.

WHY
  Two agents editing the same files silently destroyed each other's work (L-001).
  Two agents claiming the *same issue* under different slugs wasted a full build
  each, twice (L-028). And the shared claim table itself became the merge conflict
  — a green product PR blocked on a ledger hunk for issues it never touched
  (L-023). Claims must be cheap enough that nobody is tempted to skip them.

RISKS
  - Pushes a small commit to main (claim file only). Undo: release-claim.sh.
  - Adds the agent-claimed label. Undo: gh issue edit --remove-label.
  - Creates ../wt-<issue>-<slug> next to the canonical checkout.
  - Exits non-zero and removes the label if a conflict is found.
  - Does NOT move your canonical checkout: the claim commit is made in a throwaway
    worktree, so a dirty feature branch is fine (L-009).

USAGE
  claim.sh <issue> <slug> <scope...> [--slice]
  claim.sh --help

  issue   GitHub issue number
  slug    short branch slug (e.g. password-reset)
  scope   file globs/paths that become the claim scope (one or more)
  --slice deliberate additional lane on an already-claimed issue. Required to get
          past the dual-claim refusal, and it is not a formality: the scopes must
          not overlap, and whoever releases a slice must use
          `release-claim.sh <issue> --claim-id <id>` so the siblings survive.

ENV
  GIBSON_CANONICAL   path to target repo canonical checkout (default: cwd)
  GIBSON_SESSION     session id recorded in the claim (default: $USER@host)

EXAMPLES
  cd ~/Code/acme-app
  /path/to/the-gibson/scripts/claim.sh 42 password-reset 'app/api/auth/**' 'lib/email.ts'

  GIBSON_CANONICAL=~/Code/acme-app /path/to/the-gibson/scripts/claim.sh 7 nav-gen 'components/nav/**'

  # second lane on a big issue, different files, eyes open
  claim.sh 15 demo-page 'app/demo/**' --slice
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
SLICE=0
SCOPE_PARTS=()
for arg in "$@"; do
  if [[ "$arg" == "--slice" ]]; then SLICE=1; else SCOPE_PARTS+=("$arg"); fi
done
SCOPE="${SCOPE_PARTS[*]}"
[[ -n "$SCOPE" ]] || { echo "claim.sh: ERROR: no scope given" >&2; exit 2; }

CANONICAL="${GIBSON_CANONICAL:-$(pwd)}"
SESSION="${GIBSON_SESSION:-${USER:-agent}@$(hostname -s 2>/dev/null || echo host)}"
CLAIM_ID="issue-${ISSUE}-${SLUG}"
BRANCH="feat/${ISSUE}-${SLUG}"
WT_DIR="$(cd "$CANONICAL/.." && pwd)/wt-${ISSUE}-${SLUG}"
UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

die() { echo "claim.sh: ERROR: $*" >&2; exit 1; }
info() { echo "claim.sh: $*"; }

command -v git >/dev/null || die "git required"
command -v gh >/dev/null || die "gh (GitHub CLI) required"

[[ -d "$CANONICAL/.git" || -f "$CANONICAL/.git" ]] || die "not a git repo: $CANONICAL"

cd "$CANONICAL"
git fetch origin 2>/dev/null || true

# Live claims are read from origin's tip, not the working tree: the canonical
# checkout may be parked on an old branch, and a stale read is how two lanes end
# up believing they are alone.
BASE=main
git show-ref --verify --quiet refs/heads/main || BASE=master
REF="origin/$BASE"
git rev-parse --verify --quiet "$REF" >/dev/null || REF="$BASE"

live_claim_ids() {
  git ls-tree --name-only "$REF" docs/claims/ 2>/dev/null |
    sed 's|^docs/claims/||;s|\.md$||' | grep -E '^issue-' || true
  git show "$REF:docs/active-work.md" 2>/dev/null |
    grep -E '^\| ' | awk -F'|' '{print $3}' |
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^issue-' || true
}

claim_scope() {
  git show "$REF:docs/claims/$1.md" 2>/dev/null | sed -n 's/^scope: //p' && return 0
  git show "$REF:docs/active-work.md" 2>/dev/null |
    grep -F "| $1 |" | head -1 | awk -F'|' '{print $4}' |
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

LIVE_IDS=$(live_claim_ids | sort -u)

# --- L-028 / #11: refuse an accidental second claim on the same issue ---
# A deliberate second lane is legitimate (L-024 ships big issues in slices), so
# --slice is the difference between "I meant this" and the duplicate builds that
# happened twice.
SAME_ISSUE=$(echo "$LIVE_IDS" | grep -E "^issue-${ISSUE}-" || true)
if [[ -n "$SAME_ISSUE" && "$SLICE" -eq 0 ]]; then
  die "issue #$ISSUE is already claimed: $(echo "$SAME_ISSUE" | tr '\n' ' ')
  If someone else holds it, coordinate — do not race (L-028).
  If this is a deliberate second slice with non-overlapping scope, re-run with --slice."
fi
if [[ -z "$SAME_ISSUE" ]]; then
  EXISTING_LABELS=$(gh issue view "$ISSUE" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "")
  if echo ",$EXISTING_LABELS," | grep -q ',agent-claimed,'; then
    die "issue #$ISSUE carries agent-claimed but no claim file exists.
  Either a lane is mid-claim right now, or a previous release left the label behind.
  Check, then remove the stale label by hand before claiming."
  fi
fi
if [[ -n "$SAME_ISSUE" && "$SLICE" -eq 1 ]]; then
  info "slice claim: #$ISSUE also held by $(echo "$SAME_ISSUE" | tr '\n' ' ')"
fi

if echo "$LIVE_IDS" | grep -qx "$CLAIM_ID"; then
  die "claim $CLAIM_ID already exists — pick another slug, or release it first"
fi

# --- scope overlap against every live claim ---
for id in $LIVE_IDS; do
  row_scope=$(claim_scope "$id")
  [[ -z "$row_scope" ]] && continue
  for s in $SCOPE; do
    stem="${s%%\**}"
    [[ -z "$stem" ]] && continue
    if echo " $row_scope " | grep -F "$stem" >/dev/null 2>&1; then
      die "scope overlap with live claim $id (scope: $row_scope). Coordinate; do not race."
    fi
    for t in $row_scope; do
      tstem="${t%%\**}"
      [[ -z "$tstem" ]] && continue
      if echo " $SCOPE " | grep -F "$tstem" >/dev/null 2>&1; then
        die "scope overlap with live claim $id (scope: $row_scope). Coordinate; do not race."
      fi
    done
  done
done

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

# Commit the claim from a throwaway worktree — the canonical checkout is not
# ours to move, and it may be dirty or on a long-lived branch (Law 3 / L-009).
TMPWT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-claim.XXXXXX")
rm -rf "$TMPWT"
cleanup_wt() { git worktree remove --force "$TMPWT" >/dev/null 2>&1 || rm -rf "$TMPWT"; }
git worktree add --detach "$TMPWT" "$REF" >/dev/null 2>&1 ||
  die "could not create a temporary worktree at $REF for the claim commit"

(
  cd "$TMPWT" || exit 1
  mkdir -p docs/claims
  cat > "docs/claims/${CLAIM_ID}.md" <<EOF
claim: $CLAIM_ID
issue: $ISSUE
claimed: $UTC
scope: $SCOPE
session: $SESSION
branch: $BRANCH
worktree: $WT_DIR
EOF
  git add "docs/claims/${CLAIM_ID}.md"
  git commit -s -q -m "claim: $CLAIM_ID

Scope: $SCOPE
Session: $SESSION

Signed claim per docs/05. One file per claim so concurrent lanes never
conflict on the ledger (L-023)."
  git push -q origin "HEAD:$BASE"
) || { cleanup_wt; die "claim commit failed — no claim was recorded; re-run after resolving"; }
cleanup_wt

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
