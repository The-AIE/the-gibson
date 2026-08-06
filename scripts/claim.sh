#!/usr/bin/env bash
# claim.sh — atomic issue claim + worktree (GitHub PR-body claims)
set -euo pipefail

usage() {
  cat <<'EOF'
claim.sh — claim a GitHub issue and open an isolated worktree

WHAT IT DOES
  Marks the issue as agent-claimed, refuses to claim something already claimed,
  opens a draft pull request whose body carries the active-work claim, and creates
  a git worktree + branch for the work. The default branch is never mutated.

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
  - Pushes an empty claim commit to a feature branch and opens a draft PR.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "claim.sh: ERROR: $*" >&2; exit 1; }
info() { echo "claim.sh: $*"; }

command -v git >/dev/null || die "git required"
command -v gh >/dev/null || die "gh (GitHub CLI) required"

[[ -d "$CANONICAL/.git" || -f "$CANONICAL/.git" ]] || die "not a git repo: $CANONICAL"

cd "$CANONICAL"
# #106 AC3: claim path refuses when origin cannot be fetched — never a silent
# local fallback for the ledger tip (stale local main is how two lanes clobber).
BASE=main
git show-ref --verify --quiet refs/heads/main || BASE=master
if ! git fetch origin "$BASE" >/dev/null 2>&1; then
  die "cannot fetch origin/$BASE — refuse claim (no local/stale ledger fallback; #106)"
fi
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

# Live claims are read from origin's tip, not the working tree: the canonical
# checkout may be parked on an old branch, and a stale read is how two lanes end
# up believing they are alone.
REF="origin/$BASE"
if ! git rev-parse --verify --quiet "$REF" >/dev/null; then
  die "cannot resolve $REF after fetch — refuse claim (fail closed; #106)"
fi

live_claim_ids() {
  PR_CLAIM_IDS=$("$SCRIPT_DIR/pr-claims.sh" list "$REPO" 2>/dev/null |
    awk -F '\t' '{print $2}' || true)
  if [[ -n "$PR_CLAIM_IDS" ]]; then
    printf '%s\n' "$PR_CLAIM_IDS"
  fi
  git ls-tree --name-only "$REF" docs/claims/ 2>/dev/null |
    sed 's|^docs/claims/||;s|\.md$||' | grep -E '^issue-' || true
  git show "$REF:docs/active-work.md" 2>/dev/null |
    grep -E '^\| ' | awk -F'|' '{print $3}' |
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^issue-' || true
}

claim_scope() {
  PR_CLAIM_SCOPE=$("$SCRIPT_DIR/pr-claims.sh" find "$REPO" "$1" 2>/dev/null |
    awk -F '\t' '{print $3}' || true)
  if [[ -n "$PR_CLAIM_SCOPE" ]]; then
    printf '%s\n' "$PR_CLAIM_SCOPE"
    return 0
  fi
  LEGACY_CLAIM_SCOPE=$(git show "$REF:docs/claims/$1.md" 2>/dev/null |
    sed -n 's/^scope: //p')
  if [[ -n "$LEGACY_CLAIM_SCOPE" ]]; then
    printf '%s\n' "$LEGACY_CLAIM_SCOPE"
    return 0
  fi
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

# --- scope overlap against every live claim (#106 independent-set sensor) ---
# Prefer the dedicated sensor (origin fetch already proven above). Fall back to
# the historical stem check only if node is unavailable (should not happen on
# fleet hosts; still fail closed on overlap).
if command -v node >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/scope-overlap.mjs" ]]; then
  _so_args=(--repo-path "$CANONICAL" --base "$BASE" --claim-id "$CLAIM_ID")
  for s in $SCOPE; do
    _so_args+=(--scope "$s")
  done
  if [[ "$SLICE" -eq 1 ]]; then
    _so_args+=(--slice --issue "$ISSUE")
  fi
  if ! node "$SCRIPT_DIR/scope-overlap.mjs" "${_so_args[@]}"; then
    die "scope overlap (or ledger unreadable) — coordinate; do not race (#106)"
  fi
else
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
fi
  done
done

LABEL_ADDED=0
WORKTREE_CREATED=0
BRANCH_PUSHED=0
PR_NUMBER=""
CLAIM_COMPLETE=0
cleanup_claim() {
  if [[ "$CLAIM_COMPLETE" -eq 1 ]]; then
    return 0
  fi
  if [[ -n "$PR_NUMBER" && "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    gh pr close "$PR_NUMBER" --repo "$REPO" >/dev/null 2>&1 || true
  fi
  if [[ "$WORKTREE_CREATED" -eq 1 ]]; then
    git worktree remove --force "$WT_DIR" >/dev/null 2>&1 || true
  fi
  if [[ "$BRANCH_PUSHED" -eq 1 ]]; then
    git push -q origin --delete "$BRANCH" >/dev/null 2>&1 || true
  fi
  git branch -D "$BRANCH" >/dev/null 2>&1 || true
  if [[ "$LABEL_ADDED" -eq 1 ]]; then
    info "undo: removing agent-claimed from #$ISSUE"
    gh issue edit "$ISSUE" --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)" --remove-label agent-claimed 2>/dev/null || true
  fi
}
trap cleanup_claim EXIT

info "adding agent-claimed to #$ISSUE"
gh issue edit "$ISSUE" --repo "$REPO" --add-label agent-claimed
LABEL_ADDED=1

if [[ -d "$WT_DIR" ]]; then
  die "worktree path already exists: $WT_DIR"
fi
DEFAULT_REMOTE_BRANCH="origin/main"
git rev-parse "$DEFAULT_REMOTE_BRANCH" >/dev/null 2>&1 || DEFAULT_REMOTE_BRANCH="origin/master"

info "creating worktree $WT_DIR branch $BRANCH"
git worktree add "$WT_DIR" -b "$BRANCH" "$DEFAULT_REMOTE_BRANCH"
WORKTREE_CREATED=1

(
  cd "$WT_DIR" || exit 1
  git commit --allow-empty -s -q -m "chore: reserve issue #$ISSUE for $CLAIM_ID"
  git push -q -u origin "$BRANCH"
) || die "claim branch push failed — no PR claim was recorded; re-run after resolving"
BRANCH_PUSHED=1

BODY=$(mktemp "${TMPDIR:-/tmp}/gibson-claim-body.XXXXXX")
cat > "$BODY" <<EOF
## Active work

- Active-work claim: $CLAIM_ID
- Isolation: dedicated worktree
- Issue: #$ISSUE
- Claim scope: $SCOPE
- Session: $SESSION
- Claimed: $UTC

This draft PR reserves the issue before implementation. The claim is released
when this PR closes or merges.
EOF
PR_NUMBER=$(gh pr create --repo "$REPO" --draft --base "$BASE" --head "$BRANCH" \
  --title "WIP: claim #$ISSUE — $SLUG" --body-file "$BODY" |
  sed -n 's|.*/pull/||p')
rm -f "$BODY"
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] ||
  die "draft PR creation failed — no PR claim was recorded; re-run after resolving"

LABEL_ADDED=0  # success — do not undo label
CLAIM_COMPLETE=1
trap - EXIT

cat <<EOF
claim.sh: OK
  issue:    #$ISSUE
  claim:    $CLAIM_ID
  pr:       #$PR_NUMBER
  branch:   $BRANCH
  worktree: $WT_DIR
  scope:    $SCOPE

Next:
  cd $WT_DIR
  # install deps if needed, then gate-baseline.sh && implement
EOF
