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

  The pre-create overlap check is a read, and a read cannot be atomic against
  another lane that has not published its claim yet: two lanes claiming
  DIFFERENT issues with overlapping scope can each see an inventory without the
  other and both pass. So the claim is admitted a second time AFTER its PR
  exists (#153 review P1). The post-create pass re-reads the authoritative
  inventory, requires this lane's own PR to be visible in it, and refuses if an
  overlapping live PR-body claim holds a LOWER PR number. GitHub assigns PR
  numbers uniquely and monotonically, so both racers reach the same verdict from
  the same evidence — exactly one survives, with no lock file, no repo-global
  state, and nothing stale left behind if a lane is killed. A lane that loses
  rolls back only what it created (its PR, worktree, branch, and the label if it
  was the one that added it) and exits nonzero.

  THE PUBLICATION BARRIER (why one read is not enough)
  Seeing your own PR in the inventory does not prove you can see everyone
  else's. GitHub's PR list is eventually consistent, so a rival PR created a
  moment before yours can still be missing from the page you are served after
  your own row has appeared. Deciding there lets both lanes admit themselves.
  So admission does not decide on the first read that contains this lane. It
  reads the inventory repeatedly, spaced by GIBSON_CLAIM_ADMIT_DELAY, and
  decides only once the claim-relevant projection of that inventory (PR number,
  claim id, scope) has come back IDENTICAL on GIBSON_CLAIM_ADMIT_STABLE_READS
  consecutive reads that all contain this lane's own claim.

    Invariant: the verdict is computed from a quiescent inventory — one that
    stopped changing across a window of at least
    (STABLE_READS - 1) x DELAY seconds — and never from a single sample.

  Bounded failure, stated honestly: quiescence bounds the race, it does not
  abolish it. Correctness holds when a rival PR created before ours becomes
  visible to us within that window; a replica lagging longer than the whole
  window can still hide it, and no client-side read can fix that. Everything
  outside the window fails CLOSED — a repository churning so fast the inventory
  never settles, or a read that keeps failing, exhausts
  GIBSON_CLAIM_ADMIT_ATTEMPTS and the claim is refused and rolled back rather
  than admitted on evidence it could not stabilise. Refusal is safe and
  re-runnable; admitting on a partial view is neither.

  Same-issue exclusivity is re-decided on that same quiescent inventory. Two
  lanes on the SAME issue with different slugs and disjoint scopes both pass
  the pre-create duplicate check (neither is published yet) and both pass a
  scope-only re-check, which is how one issue got built twice. Without --slice
  exactly one survives — the lower PR number, the same deterministic tie-break
  the scope race uses. With --slice, same-issue siblings are exactly as legal
  as they always were, provided their scopes are disjoint.

  ROLLBACK NEVER DESTROYS WORK
  A losing lane rolls back with the same protections release-claim.sh uses for
  terminal cleanup, shared as lib/claim-guards.sh rather than copied: the
  worktree is resolved from `git worktree list --porcelain` (never assumed from
  its path), must be the exact path THIS lane created, on this lane's branch,
  clean, and still at the exact commit this lane made; local and remote branch
  deletion are compare-and-swap against that same commit. Anything that cannot
  be proven is kept, named, and reported — the run exits nonzero and INCOMPLETE
  instead of force-removing a worktree that went dirty or a branch that moved
  during the admission window.

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
  GIBSON_CLAIM_ADMIT_ATTEMPTS
                     the most times the post-create admission pass will read
                     the live inventory while waiting for it to contain this
                     lane's own PR and then go quiet (default 6). Patience
                     only — it never changes the verdict, and running out
                     still refuses the claim and rolls it back.
  GIBSON_CLAIM_ADMIT_STABLE_READS
                     how many CONSECUTIVE reads must return an identical
                     claim inventory (and contain this lane's own claim)
                     before admission will decide (default 2). 1 disables the
                     publication barrier and decides on a single sample — it
                     exists for tests and for a repository you know is
                     uncontended, not for a fleet.
  GIBSON_CLAIM_ADMIT_DELAY
                     seconds between those reads (default 2). The quiescence
                     window is (STABLE_READS - 1) x DELAY; a rival that
                     publishes within it is seen, one that takes longer is
                     not, and everything unproven refuses.

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

# Shared cleanup guards (#153 review P1 0D) — the same worktree resolution and
# exact remote-branch query release-claim.sh's terminal cleanup uses. Rollback
# is a destructive path; it must not run without them.
# shellcheck source=lib/claim-guards.sh
. "$SCRIPT_DIR/lib/claim-guards.sh" ||
  die "cannot source $SCRIPT_DIR/lib/claim-guards.sh — refusing to claim without the rollback safety guards"

command -v git >/dev/null || die "git required"
command -v gh >/dev/null || die "gh (GitHub CLI) required"

# Authoritative issue-label read. A gh failure is UNREADABLE, never "no
# labels": treating a failed read as an empty one is how a lane both walked
# past the stale-label guard and later stripped a sibling's label (#153 review
# P1 0C). Sets ISSUE_LABELS; returns 1 with LABEL_READ_ERR.
ISSUE_LABELS=""
LABEL_READ_ERR=""
read_issue_labels() {
  local out
  ISSUE_LABELS=""
  LABEL_READ_ERR=""
  if ! out=$(gh issue view "$ISSUE" --repo "$REPO" --json labels -q '[.labels[].name] | join(",")' 2>&1); then
    LABEL_READ_ERR="$out"
    return 1
  fi
  ISSUE_LABELS="$out"
  return 0
}

# Issue number carried by a claim id, under the same shape pr-claims.sh
# validates (`issue-[<prefix>-]<n>-<slug>`). Returns 1 when the id does not
# yield one — an id whose issue cannot be read is ambiguous evidence, and
# callers must fail closed on it rather than assume "different issue".
CLAIM_ISSUE_NUMBER=""
claim_issue_number() {
  CLAIM_ISSUE_NUMBER=""
  if [[ "${1:-}" =~ ^issue-([A-Za-z][A-Za-z0-9]*-)?([0-9]+)- ]]; then
    CLAIM_ISSUE_NUMBER="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

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

# Historical stem/prefix overlap between two space-separated scope strings.
# Used by the pre-create check and by the post-create admission pass when node
# (and therefore scope-overlap.mjs) is unavailable, so both passes agree on
# what "overlap" means.
legacy_scope_overlap() {
  local a="$1" b="$2" s stem t tstem
  for s in $a; do
    stem="${s%%\**}"
    [[ -z "$stem" ]] && continue
    if echo " $b " | grep -F "$stem" >/dev/null 2>&1; then
      return 0
    fi
  done
  for t in $b; do
    tstem="${t%%\**}"
    [[ -z "$tstem" ]] && continue
    if echo " $a " | grep -F "$tstem" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
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
  # Fail closed (#153 review P1 0C): this read decides whether a stale label is
  # blocking the claim. A gh failure swallowed into an empty string answers
  # "no label" to a question that was never answered at all.
  read_issue_labels ||
    die "cannot read the labels on #$ISSUE from $REPO — refusing to claim on an unread label state: $LABEL_READ_ERR"
  EXISTING_LABELS="$ISSUE_LABELS"
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
  _so_args=(--repo-path "$CANONICAL" --base "$BASE" --claim-id "$CLAIM_ID" --repo "$REPO")
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
    if legacy_scope_overlap "$SCOPE" "$row_scope"; then
      die "scope overlap with live claim $id (scope: $row_scope). Coordinate; do not race."
    fi
  done
fi

LABEL_ADDED=0
LABEL_PRE_PRESENT=0
WORKTREE_CREATED=0
BRANCH_PUSHED=0
PR_NUMBER=""
CLAIM_COMPLETE=0
# The exact commit this lane put on its own branch. Fixed at creation time and
# never re-read from the ref later: a value read immediately before a delete
# trivially equals itself, so only a value pinned back here can catch a branch
# that advanced during the admission window (#153 review P1 0D).
CLAIM_EXPECTED_OID=""
ROLLBACK_LEFTOVERS=""

leftover() { ROLLBACK_LEFTOVERS="${ROLLBACK_LEFTOVERS}  - $1"$'\n'; }

# --- rollback: remove this lane's own worktree, or refuse and say why -------
# Same protections as release-claim.sh's terminal cleanup (shared code, not a
# copy): the worktree is the one GIT says is on this branch, it must be the
# exact path this lane created, clean, and still at this lane's own commit.
# Never --force, never rm -rf. Returns 1 when the worktree phase could not be
# completed safely — the caller must then leave the branches alone too.
rollback_worktree() {
  local wt_expected wt_actual wt_phys status_out head_oid
  wt_expected=$(guard_phys_path "$WT_DIR" || true)

  if ! guard_worktree_paths_for_branch "$BRANCH"; then
    leftover "worktree $WT_DIR (kept: $GUARD_WT_REASON)"
    return 1
  fi
  if [[ "$GUARD_WT_COUNT" -gt 1 ]]; then
    leftover "worktree $WT_DIR (kept: branch $BRANCH is registered at more than one worktree path — ambiguous: $(printf '%s' "$GUARD_WT_PATHS" | tr '\n' ' '))"
    return 1
  fi
  if [[ "$GUARD_WT_COUNT" -eq 0 ]]; then
    # Nothing registered on our branch. Safe only if our own directory is
    # genuinely gone; if something is still sitting there it was moved,
    # re-branched, or replaced, and it is not ours to delete.
    if [[ -e "$WT_DIR" || -L "$WT_DIR" ]]; then
      leftover "worktree $WT_DIR (kept: still present but no longer a registered worktree on branch $BRANCH — refusing to delete a directory git does not vouch for)"
      return 1
    fi
    return 0
  fi

  wt_actual=$(printf '%s\n' "$GUARD_WT_PATHS" | sed -n '1p')
  wt_phys=$(guard_phys_path "$wt_actual" || true)
  if [[ -z "$wt_expected" || -z "$wt_phys" || "$wt_phys" != "$wt_expected" ]]; then
    leftover "worktree $wt_actual (kept: branch $BRANCH is checked out there, not at the $WT_DIR this lane created — refusing to remove another worktree)"
    return 1
  fi
  if ! status_out=$(git -C "$wt_actual" status --porcelain 2>&1); then
    leftover "worktree $wt_actual (kept: cannot read its status — $status_out)"
    return 1
  fi
  if [[ -n "$status_out" ]]; then
    leftover "worktree $wt_actual (kept: it has uncommitted or untracked work — $(printf '%s' "$status_out" | tr '\n' ';'))"
    return 1
  fi
  head_oid=$(git -C "$wt_actual" rev-parse HEAD 2>/dev/null || true)
  if [[ -z "$head_oid" ]]; then
    leftover "worktree $wt_actual (kept: cannot read its HEAD commit)"
    return 1
  fi
  if [[ -n "$CLAIM_EXPECTED_OID" && "$head_oid" != "$CLAIM_EXPECTED_OID" ]]; then
    leftover "worktree $wt_actual (kept: HEAD $head_oid is not the commit this lane created, $CLAIM_EXPECTED_OID — it advanced during the claim)"
    return 1
  fi
  if ! git worktree remove "$wt_actual" >/dev/null 2>&1; then
    leftover "worktree $wt_actual (kept: git worktree remove refused it — no --force fallback)"
    return 1
  fi
  git worktree prune >/dev/null 2>&1 || true
  if [[ -d "$wt_actual" ]]; then
    leftover "worktree $wt_actual (still present after git worktree remove)"
    return 1
  fi
  info "rollback: removed this lane's own worktree $wt_actual"
  return 0
}

# --- rollback: compare-and-swap branch deletion ----------------------------
# Both deletions are CAS against CLAIM_EXPECTED_OID, so a branch that advanced
# during the admission window survives instead of being destroyed. A refused
# local delete blocks the remote delete outright: deleting the published branch
# while an advanced local one lives is how the only copy of work disappears.
rollback_branches() {
  local local_tip local_cas_failed=0 rc=0
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    local_tip=$(git rev-parse --verify --quiet "refs/heads/$BRANCH" 2>/dev/null || true)
    if [[ -z "$local_tip" ]]; then
      leftover "local branch $BRANCH (kept: cannot read its tip commit)"
      local_cas_failed=1
    elif [[ -n "$CLAIM_EXPECTED_OID" && "$local_tip" != "$CLAIM_EXPECTED_OID" ]]; then
      leftover "local branch $BRANCH (kept: tip $local_tip is not the commit this lane created, $CLAIM_EXPECTED_OID — it advanced during the claim)"
      local_cas_failed=1
    elif ! git update-ref -d "refs/heads/$BRANCH" "$CLAIM_EXPECTED_OID" 2>/dev/null; then
      leftover "local branch $BRANCH (kept: compare-and-swap delete expecting $CLAIM_EXPECTED_OID was refused — it moved between the proof and the delete)"
      local_cas_failed=1
    else
      info "rollback: deleted this lane's own local branch $BRANCH"
    fi
  fi

  if [[ "$local_cas_failed" -eq 1 ]]; then
    leftover "remote branch $BRANCH (kept: the local branch delete was refused first — never publish-delete over surviving local work)"
    return 1
  fi

  if ! guard_remote_branch_exact "$BRANCH"; then
    leftover "remote branch $BRANCH (kept: cannot verify it before deletion — $GUARD_REMOTE_REASON)"
    return 1
  fi
  if [[ "$GUARD_REMOTE_STATUS" == "present" ]]; then
    if [[ -n "$CLAIM_EXPECTED_OID" && "$GUARD_REMOTE_OID" != "$CLAIM_EXPECTED_OID" ]]; then
      leftover "remote branch $BRANCH (kept: origin tip $GUARD_REMOTE_OID is not the commit this lane pushed, $CLAIM_EXPECTED_OID — it advanced during the claim)"
      rc=1
    elif ! git push --force-with-lease="refs/heads/${BRANCH}:${CLAIM_EXPECTED_OID}" origin ":refs/heads/${BRANCH}" >/dev/null 2>&1; then
      leftover "remote branch $BRANCH (kept: compare-and-swap delete leased on $CLAIM_EXPECTED_OID was refused — it advanced between the check and the delete)"
      rc=1
    else
      info "rollback: deleted this lane's own remote branch $BRANCH"
    fi
  fi
  return "$rc"
}

# --- rollback: sibling-safe label release ----------------------------------
# agent-claimed is issue-wide, so it is NOT this lane's property just because
# this lane added it: two racers on one issue can both read it as absent and
# both add it, and whoever loses would then strip it off the winner (#153
# review P1 0C). Remove it only after a FRESH authoritative inventory proves no
# surviving sibling still needs it, and a FRESH label read proves what is
# actually there. Any unreadable or malformed evidence keeps the label.
rollback_label() {
  local rows sibling_ids="" malformed="" unparseable="" _row _fields row_num row_id
  if [[ "$LABEL_ADDED" -ne 1 ]]; then
    return 0
  fi
  if [[ "$LABEL_PRE_PRESENT" -eq 1 ]]; then
    info "rollback: leaving agent-claimed on #$ISSUE — it was already there before this claim"
    return 0
  fi

  if ! rows=$("$SCRIPT_DIR/pr-claims.sh" list "$REPO" 2>&1); then
    leftover "agent-claimed on #$ISSUE (kept: the live claim inventory for $REPO is unreadable, so a sibling lane cannot be ruled out — $rows)"
    return 1
  fi
  while IFS= read -r _row; do
    [[ -n "$_row" ]] || continue
    _fields=$(awk -F'\t' '{print NF}' <<<"$_row")
    row_num=$(awk -F'\t' '{print $1}' <<<"$_row")
    row_id=$(awk -F'\t' '{print $2}' <<<"$_row")
    if [[ "$_fields" -ne 7 || -z "$row_id" || "$row_id" != issue-* || ! "$row_num" =~ ^[0-9]+$ ]]; then
      malformed="$_row"
      break
    fi
    # This lane's own row may still be in the inventory: the PR was only just
    # closed and that view is eventually consistent. Exclude it by both keys.
    [[ "$row_id" == "$CLAIM_ID" ]] && continue
    [[ -n "$PR_NUMBER" && "$row_num" == "$PR_NUMBER" ]] && continue
    if ! claim_issue_number "$row_id"; then
      unparseable="$row_id"
      break
    fi
    if [[ "$CLAIM_ISSUE_NUMBER" == "$ISSUE" ]]; then
      sibling_ids="${sibling_ids}    $row_id (PR #$row_num)"$'\n'
    fi
  done <<EOF
$rows
EOF
  if [[ -n "$malformed" ]]; then
    leftover "agent-claimed on #$ISSUE (kept: the live claim inventory returned a malformed row, so a sibling lane cannot be ruled out — $malformed)"
    return 1
  fi
  if [[ -n "$unparseable" ]]; then
    leftover "agent-claimed on #$ISSUE (kept: live claim id '$unparseable' carries no readable issue number, so it cannot be ruled out as a sibling)"
    return 1
  fi
  if [[ -n "$sibling_ids" ]]; then
    info "rollback: leaving agent-claimed on #$ISSUE — surviving sibling claim(s) still hold this issue:"
    printf '%s' "$sibling_ids"
    return 0
  fi

  if ! read_issue_labels; then
    leftover "agent-claimed on #$ISSUE (kept: its current state could not be read — $LABEL_READ_ERR)"
    return 1
  fi
  if ! echo ",$ISSUE_LABELS," | grep -q ',agent-claimed,'; then
    info "rollback: agent-claimed is already absent from #$ISSUE — nothing to remove"
    return 0
  fi
  info "undo: removing agent-claimed from #$ISSUE"
  if ! gh issue edit "$ISSUE" --repo "$REPO" --remove-label agent-claimed >/dev/null 2>&1; then
    leftover "agent-claimed on #$ISSUE (gh issue edit failed — remove it by hand)"
    return 1
  fi
  if ! read_issue_labels; then
    leftover "agent-claimed on #$ISSUE (removal could not be verified — $LABEL_READ_ERR)"
    return 1
  fi
  if echo ",$ISSUE_LABELS," | grep -q ',agent-claimed,'; then
    leftover "agent-claimed on #$ISSUE (still present after removal)"
    return 1
  fi
  info "rollback: removed agent-claimed from #$ISSUE (verified)"
  return 0
}

# Rolls back ONLY what this lane created. Never touches another lane's PR,
# worktree, branch, or label — a losing racer must leave the winner intact —
# and never destroys work it cannot prove is its own and untouched. Anything
# unprovable is preserved, named, and reported as INCOMPLETE with a nonzero
# exit; an unfinished rollback must never look like a clean one.
cleanup_claim() {
  local rc=$?
  if [[ "$CLAIM_COMPLETE" -eq 1 ]]; then
    return 0
  fi
  ROLLBACK_LEFTOVERS=""

  # Deterministic hook for the adversarial rollback sensors: lets a test dirty
  # the worktree, advance a branch, or unregister the worktree in exactly the
  # window a slow admission pass leaves open. Never set in production.
  if [[ -n "${GIBSON_CLAIM_TEST_ROLLBACK_HOOK:-}" ]]; then
    "$GIBSON_CLAIM_TEST_ROLLBACK_HOOK" "$WT_DIR" "$BRANCH" "$CLAIM_EXPECTED_OID" || true
  fi

  # Close this lane's own PR first, bound to the number it created. Doing this
  # before the label step also means the sibling inventory below is read after
  # this claim has stopped being live.
  if [[ -n "$PR_NUMBER" && "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    if gh pr close "$PR_NUMBER" --repo "$REPO" >/dev/null 2>&1; then
      info "rollback: closed this lane's own PR #$PR_NUMBER"
    else
      leftover "PR #$PR_NUMBER (gh pr close failed — close it by hand)"
    fi
  fi

  # Only ever touch a branch this lane actually created. When the run died
  # before `git worktree add`, any branch of that name belongs to someone else
  # — the old unconditional `git branch -D` was willing to delete it.
  local wt_phase_ok=1
  if [[ "$WORKTREE_CREATED" -eq 1 || "$BRANCH_PUSHED" -eq 1 ]]; then
    if [[ "$WORKTREE_CREATED" -eq 1 ]]; then
      rollback_worktree || wt_phase_ok=0
    fi
    if [[ "$wt_phase_ok" -eq 1 ]]; then
      rollback_branches || true
    else
      # A retained worktree must not lose its branch — that is exactly how a
      # dirty tree ends up orphaned with its history deleted out from under it.
      leftover "local and remote branch $BRANCH (kept: the worktree could not be proven safe to remove)"
    fi
  fi

  rollback_label || true

  if [[ -n "$ROLLBACK_LEFTOVERS" ]]; then
    echo "claim.sh: INCOMPLETE — rollback preserved work instead of destroying it. Left behind:" >&2
    printf '%s' "$ROLLBACK_LEFTOVERS" >&2
    echo "claim.sh: resolve these by hand. Nothing was force-removed." >&2
  fi
  # A rollback that ran at all means the claim did not stand. Never exit 0.
  [[ "$rc" -eq 0 ]] && rc=1
  exit "$rc"
}
trap cleanup_claim EXIT

# Read the label BEFORE adding it, so the rollback above can tell "I added
# this" from "a sibling lane already held it". Fail closed: an unread label
# state cannot support either answer (#153 review P1 0C).
read_issue_labels ||
  die "cannot read the labels on #$ISSUE from $REPO before adding agent-claimed — refusing to mutate on an unread label state: $LABEL_READ_ERR"
if echo ",$ISSUE_LABELS," | grep -q ',agent-claimed,'; then
  LABEL_PRE_PRESENT=1
fi

info "adding agent-claimed to #$ISSUE"
gh issue edit "$ISSUE" --repo "$REPO" --add-label agent-claimed
LABEL_ADDED=1

if [[ -d "$WT_DIR" ]]; then
  die "worktree path already exists: $WT_DIR"
fi
DEFAULT_REMOTE_BRANCH="origin/main"
git rev-parse "$DEFAULT_REMOTE_BRANCH" >/dev/null 2>&1 || DEFAULT_REMOTE_BRANCH="origin/master"

# Pin the branch point BEFORE creating anything, so a rollback that has to run
# between `worktree add` and the claim commit still knows the exact OID this
# lane is responsible for (#153 review P1 0D).
CLAIM_EXPECTED_OID=$(git rev-parse --verify --quiet "$DEFAULT_REMOTE_BRANCH^{commit}" 2>/dev/null || true)
[[ -n "$CLAIM_EXPECTED_OID" ]] ||
  die "cannot resolve $DEFAULT_REMOTE_BRANCH to a commit — refusing to branch from an unknown point"

info "creating worktree $WT_DIR branch $BRANCH"
git worktree add "$WT_DIR" -b "$BRANCH" "$DEFAULT_REMOTE_BRANCH"
WORKTREE_CREATED=1

git -C "$WT_DIR" commit --allow-empty -s -q -m "chore: reserve issue #$ISSUE for $CLAIM_ID" ||
  die "claim commit failed — no PR claim was recorded; re-run after resolving"
# Re-pin BEFORE the push, not after it: the claim commit is now what this lane
# owns on that branch, and every later CAS (worktree HEAD, local delete, remote
# lease) is anchored to this exact value. Pinning after the push would leave a
# failed push looking like a branch that advanced behind this lane's back, and
# rollback would then refuse to clean up its own retryable mess.
CLAIM_EXPECTED_OID=$(git -C "$WT_DIR" rev-parse HEAD 2>/dev/null || true)
[[ "$CLAIM_EXPECTED_OID" =~ ^[0-9a-f]{40}$ ]] ||
  die "cannot read the claim commit this lane just created on $BRANCH — refusing to continue without an anchor for rollback"

git -C "$WT_DIR" push -q -u origin "$BRANCH" ||
  die "claim branch push failed — no PR claim was recorded; re-run after resolving"
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

# --- post-create admission (#153 review P1: cross-issue overlap TOCTOU) -----
# The pre-create check above read an inventory that could not yet contain a
# concurrent lane's claim. Re-decide now that this claim IS published, against
# the authoritative inventory, with a deterministic winner: the lower PR
# number. Losing here rolls this lane back through cleanup_claim (its own PR,
# worktree, branch, and label only) and exits nonzero.
ADMIT_ATTEMPTS="${GIBSON_CLAIM_ADMIT_ATTEMPTS:-6}"
ADMIT_DELAY="${GIBSON_CLAIM_ADMIT_DELAY:-2}"
ADMIT_STABLE_READS="${GIBSON_CLAIM_ADMIT_STABLE_READS:-2}"
[[ "$ADMIT_ATTEMPTS" =~ ^[0-9]+$ && "$ADMIT_ATTEMPTS" -ge 1 ]] ||
  die "GIBSON_CLAIM_ADMIT_ATTEMPTS must be a positive integer, got '$ADMIT_ATTEMPTS'"
[[ "$ADMIT_DELAY" =~ ^[0-9]+$ ]] ||
  die "GIBSON_CLAIM_ADMIT_DELAY must be a non-negative integer, got '$ADMIT_DELAY'"
[[ "$ADMIT_STABLE_READS" =~ ^[0-9]+$ && "$ADMIT_STABLE_READS" -ge 1 ]] ||
  die "GIBSON_CLAIM_ADMIT_STABLE_READS must be a positive integer, got '$ADMIT_STABLE_READS'"
[[ "$ADMIT_STABLE_READS" -le "$ADMIT_ATTEMPTS" ]] ||
  die "GIBSON_CLAIM_ADMIT_STABLE_READS ($ADMIT_STABLE_READS) cannot exceed GIBSON_CLAIM_ADMIT_ATTEMPTS ($ADMIT_ATTEMPTS) — that barrier could never be satisfied and every claim would refuse"

# The claim-relevant projection of an inventory: PR number, claim id, scope,
# order-independent. Two reads that agree on this agree on everything the
# admission decision uses; unrelated churn (a PR body edited elsewhere, a
# timestamp bumped) does not stop the barrier from settling.
admit_fingerprint() {
  printf '%s\n' "$1" | awk -F'\t' 'NF>0 {print $1"\t"$2"\t"$3}' | LC_ALL=C sort
}

ADMIT_ROWS=""
ADMIT_QUIESCED=0
_admit_prev_fp=""
_admit_streak=0
_attempt=1
while [[ "$_attempt" -le "$ADMIT_ATTEMPTS" ]]; do
  # Space the reads. Two samples taken in the same instant prove nothing about
  # whether a rival has finished publishing, so the delay is part of the
  # barrier, not a politeness.
  if [[ "$_attempt" -gt 1 && "$ADMIT_DELAY" -gt 0 ]]; then
    sleep "$ADMIT_DELAY"
  fi
  if _rows=$("$SCRIPT_DIR/pr-claims.sh" list "$REPO" 2>&1); then
    if printf '%s\n' "$_rows" |
       awk -F'\t' -v n="$PR_NUMBER" -v c="$CLAIM_ID" '$1==n && $2==c {f=1} END{exit !f}'; then
      _fp=$(admit_fingerprint "$_rows")
      if [[ "$_admit_streak" -gt 0 && "$_fp" == "$_admit_prev_fp" ]]; then
        _admit_streak=$((_admit_streak + 1))
      else
        _admit_streak=1
      fi
      _admit_prev_fp="$_fp"
      ADMIT_ROWS="$_rows"
      if [[ "$_admit_streak" -ge "$ADMIT_STABLE_READS" ]]; then
        ADMIT_QUIESCED=1
        break
      fi
      echo "claim.sh: admission: inventory not yet quiescent for PR #$PR_NUMBER ($_admit_streak/$ADMIT_STABLE_READS matching read(s), attempt $_attempt/$ADMIT_ATTEMPTS)" >&2
    else
      # Not seeing ourselves resets the streak: a read that cannot see this
      # claim is not part of any quiescent window this claim may rely on.
      _admit_streak=0
      _admit_prev_fp=""
      ADMIT_ROWS=""
      echo "claim.sh: admission: PR #$PR_NUMBER is not in the live claim inventory yet (attempt $_attempt/$ADMIT_ATTEMPTS)" >&2
    fi
  else
    _admit_streak=0
    _admit_prev_fp=""
    ADMIT_ROWS=""
    echo "claim.sh: admission: cannot read the live claim inventory for $REPO (attempt $_attempt/$ADMIT_ATTEMPTS): $_rows" >&2
  fi
  _attempt=$((_attempt + 1))
done

if [[ "$ADMIT_QUIESCED" -ne 1 ]]; then
  die "post-create admission: could not obtain a stable live-claim inventory for $REPO containing this lane's own claim PR #$PR_NUMBER — $ADMIT_STABLE_READS consecutive matching read(s) required, $ADMIT_ATTEMPTS attempt(s) made.
  An inventory that cannot see this claim, or that is still changing underneath it, cannot prove no one else holds the scope: a rival PR created before this one may simply not have been published to the view yet.
  Refusing to hold a claim that is not provably registered against a settled view. This lane's PR, branch, worktree and label are being rolled back; re-run once the inventory is readable and quiet."
fi
info "admission: inventory quiescent for PR #$PR_NUMBER ($ADMIT_STABLE_READS consecutive matching read(s))"

# --- same-issue exclusivity, re-decided after publication (#153 review P1 0B)
# Two lanes on the SAME issue with different slugs and disjoint scopes each
# passed the pre-create duplicate check (neither was published yet) and would
# each pass a scope-only re-check — one issue, two builds, which is L-028
# happening again through a different door. Re-decide it here, on the quiescent
# inventory, with the same tie-break the scope race uses. With --slice this
# does not apply: same-issue siblings are legal and the scope check below is
# what keeps them disjoint.
if [[ "$SLICE" -eq 0 ]]; then
  while IFS=$'\t' read -r _si_num _si_id _si_rest; do
    [[ -n "$_si_id" ]] || continue
    [[ "$_si_id" == "$CLAIM_ID" ]] && continue
    [[ -n "$PR_NUMBER" && "$_si_num" == "$PR_NUMBER" ]] && continue
    claim_issue_number "$_si_id" ||
      die "post-create admission: live claim id '$_si_id' (PR #$_si_num) carries no readable issue number — cannot prove it is not a second lane on issue #$ISSUE; rolling this lane back"
    [[ "$CLAIM_ISSUE_NUMBER" == "$ISSUE" ]] || continue
    if [[ "$_si_num" =~ ^[0-9]+$ ]] && [[ "$_si_num" -gt "$PR_NUMBER" ]]; then
      info "admission: later same-issue lane $_si_id (PR #$_si_num) yields to PR #$PR_NUMBER"
      continue
    fi
    die "post-create admission refused for $CLAIM_ID (PR #$PR_NUMBER): issue #$ISSUE is already held by the live claim $_si_id (PR #$_si_num), which holds the stronger prior.
  One issue is one claim (L-028) — two lanes on it means two builds of the same work, even when their scopes do not touch.
  This lane's PR, branch, worktree and label are being rolled back; coordinate with that lane, or re-run with --slice if a deliberate second lane with non-overlapping scope is really what you want."
  done <<EOF
$ADMIT_ROWS
EOF
fi

if command -v node >/dev/null 2>&1 && [[ -f "$SCRIPT_DIR/scope-overlap.mjs" ]]; then
  # Decide on the SAME quiescent inventory the barrier above settled on — not
  # on a fresh read the sensor takes for itself. A re-read here could be served
  # a view where the rival has vanished again, which would throw away the whole
  # publication barrier one line after passing it (#153 review P1 0A).
  ADMIT_ROWS_FILE=$(mktemp "${TMPDIR:-/tmp}/gibson-admit-rows.XXXXXX")
  printf '%s\n' "$ADMIT_ROWS" > "$ADMIT_ROWS_FILE"
  _adm_args=(--repo-path "$CANONICAL" --base "$BASE" --claim-id "$CLAIM_ID" --repo "$REPO" --admit-pr "$PR_NUMBER" --pr-claims-file "$ADMIT_ROWS_FILE")
  for s in $SCOPE; do
    _adm_args+=(--scope "$s")
  done
  if [[ "$SLICE" -eq 1 ]]; then
    _adm_args+=(--slice --issue "$ISSUE")
  fi
  if node "$SCRIPT_DIR/scope-overlap.mjs" "${_adm_args[@]}"; then
    rm -f "$ADMIT_ROWS_FILE"
  else
    rm -f "$ADMIT_ROWS_FILE"
    die "post-create admission refused for $CLAIM_ID (PR #$PR_NUMBER): a live claim with a stronger prior holds overlapping scope.
  This is the concurrent-claim race resolving deterministically — the lower PR number wins.
  This lane's PR, branch, worktree and label are being rolled back; re-run once the other lane releases, or claim a disjoint scope."
  fi
else
  # No node: same decision, same tie-break, using the historical stem overlap.
  while IFS=$'\t' read -r _a_num _a_id _a_scope _a_rest; do
    [[ -n "$_a_id" ]] || continue
    [[ "$_a_id" == "$CLAIM_ID" ]] && continue
    [[ -n "$_a_scope" ]] ||
      die "post-create admission: live claim '$_a_id' (PR #$_a_num) has an empty scope — unreadable evidence; rolling this lane back"
    legacy_scope_overlap "$SCOPE" "$_a_scope" || continue
    if [[ "$_a_num" =~ ^[0-9]+$ ]] && [[ "$_a_num" -gt "$PR_NUMBER" ]]; then
      info "admission: later overlapping claim $_a_id (PR #$_a_num) yields to PR #$PR_NUMBER"
      continue
    fi
    die "post-create admission refused for $CLAIM_ID (PR #$PR_NUMBER): overlapping live claim $_a_id (PR #$_a_num, scope: $_a_scope) holds the stronger prior.
  This lane's PR, branch, worktree and label are being rolled back; re-run once it releases, or claim a disjoint scope."
  done <<EOF
$ADMIT_ROWS
EOF
  for id in $LIVE_IDS; do
    [[ "$id" == "$CLAIM_ID" ]] && continue
    row_scope=$(claim_scope "$id")
    [[ -z "$row_scope" ]] && continue
    if legacy_scope_overlap "$SCOPE" "$row_scope"; then
      die "post-create admission refused for $CLAIM_ID (PR #$PR_NUMBER): ledger claim $id (scope: $row_scope) holds the scope.
  This lane's PR, branch, worktree and label are being rolled back."
    fi
  done
fi
info "admission: PR #$PR_NUMBER holds $CLAIM_ID (verified against the live claim inventory)"

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
