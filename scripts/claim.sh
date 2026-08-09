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
  exists (#153 review P1), by `scope-overlap.mjs --admit-pr`. That pass waits
  for the authoritative inventory to go quiet, requires this lane's own PR to
  be visible in it, and refuses if an overlapping live PR-body claim holds a
  LOWER PR number. GitHub assigns PR numbers uniquely and monotonically, so
  both racers reach the same verdict from the same evidence. A lane that loses
  rolls back only what it created (its PR, worktree, branch, and the label if
  it was the one that added it) and exits nonzero.

  THE PUBLICATION BARRIER (why one read is not enough)
  Seeing your own PR in the inventory does not prove you can see everyone
  else's. GitHub's PR list is eventually consistent, so a rival PR created a
  moment before yours can still be missing from the page you are served after
  your own row has appeared. Deciding there lets both lanes admit themselves.
  So admission does not decide on the first read that contains this lane: it
  decides only once the claim-relevant projection of the inventory (PR number,
  claim id, scope) has come back IDENTICAL on several consecutive spaced reads
  that all contain this lane's own claim.

    Invariant: the verdict is computed from a quiescent inventory — one that
    stopped changing across a window of at least
    (STABLE_READS - 1) x DELAY seconds — and never from a single sample.

  The barrier lives inside scope-overlap.mjs, which takes those reads itself.
  Nothing hands it an inventory: an option to supply one would be a forged-
  evidence path, and no cross-process handoff of caller-supplied data can be
  made unforgeable. It enforces a production floor of at least 2 matching
  reads spaced at least 1 second apart. GIBSON_CLAIM_ADMIT_* may RAISE that
  floor; a value below it is a usage error, not a silent clamp. There is no
  supported way to switch the barrier off.

  WHAT THE BARRIER DOES AND DOES NOT GIVE YOU
  Within the window, the barrier gives a DETERMINISTIC winner: when every
  racing lane's PR becomes visible to every other racing lane inside its own
  quiescence window, all of them compute the same lowest PR number and exactly
  one is admitted. That condition is what makes "exactly one" true — it is not
  unconditional. Eventual-consistency lag is not bounded by anything this
  script controls, so a replica that hides a rival for longer than the whole
  window can still admit two lanes, and no client-side read can fix that.
  Everything outside the window fails CLOSED: an inventory that never settles,
  or reads that keep failing, exhaust the attempts and the claim is refused and
  rolled back rather than admitted on evidence it could not stabilise. Refusal
  is safe and re-runnable; admitting on a partial view is neither.

  Same-issue exclusivity is decided on that same quiescent inventory. Two lanes
  on the SAME issue with different slugs and disjoint scopes both pass the
  pre-create duplicate check (neither is published yet) and both pass a
  scope-only re-check, which is how one issue got built twice. Without --slice
  exactly one survives — the lower PR number, the same deterministic tie-break
  the scope race uses. With --slice, same-issue siblings are exactly as legal
  as they always were, provided their scopes are disjoint.

  ROLLBACK NEVER DESTROYS WORK
  A losing lane rolls back with the same protections release-claim.sh uses for
  terminal cleanup, shared as lib/claim-guards.sh rather than copied. Rollback
  is ORDERED: nothing is destroyed until this lane's own claim PR has been
  positively bound, positively closed, and freshly proven to be no longer a
  live claim. Only then are the worktree, branches and issue-wide label
  considered — the worktree resolved from `git worktree list --porcelain`
  (never assumed from its path), required to be the exact path THIS lane
  created, on this lane's branch, clean, and still at the exact commit this
  lane made; local and remote branch deletion compare-and-swap against that
  same commit. Anything that cannot be proven is kept, named, and reported —
  the run exits nonzero and INCOMPLETE instead of force-removing a worktree
  that went dirty, deleting a branch that moved, or stripping an issue-wide
  label while this lane's PR may still be open.

  From the instant `gh pr create` is INVOKED, a PR may exist no matter what
  the command reports. A nonzero exit is the client's view of the call, not
  authoritative evidence about server-side state: GitHub can create the PR and
  then lose the response, and the eventually consistent PR list can be empty
  for a while afterwards. So a failed create plus an inventory that does not
  show the claim retains EVERYTHING — worktree, both branches, agent-claimed —
  names the PR that may exist unpublished, and exits INCOMPLETE. Close it by
  hand before re-claiming. Nothing is destroyed on one negative read.

  WHAT A KILLED LANE LEAVES BEHIND (be honest about this)
  Rollback runs from an EXIT trap, so it protects a lane that fails or refuses
  — not one that is destroyed. SIGKILL, a power loss, or a terminated shell
  before the trap finishes can leave an open draft PR (a LIVE claim), the
  agent-claimed label, a pushed branch, and a worktree behind. Those do not
  self-heal: `claim-reaper.sh` and the manual recovery in
  docs/troubleshooting/claim-conflicts.md are how they get cleared.

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
  - Exits non-zero on a conflict, and removes the label only after proving its
    own PR is closed and no sibling claim still holds the issue. Anything it
    cannot prove is kept and reported INCOMPLETE.
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

REQUIREMENTS
  git, gh, and node. node is required BEFORE any mutation: scope-overlap.mjs is
  the authoritative overlap and admission decision, and there is no weaker
  fallback for it. A host without node refuses the claim outright rather than
  labelling an issue, pushing a branch and opening a PR on a check it could not
  run (#153 review round 3, P1).

ENV
  GIBSON_CANONICAL   path to target repo canonical checkout (default: cwd)
  GIBSON_SESSION     session id recorded in the claim (default: $USER@host)
  GIBSON_CLAIM_ADMIT_ATTEMPTS
                     the most times the admission pass will read the live
                     inventory while waiting for it to contain this lane's own
                     PR and then go quiet (default 6, minimum 2). Patience
                     only — it never changes the verdict, and running out
                     still refuses the claim and rolls it back.
  GIBSON_CLAIM_ADMIT_STABLE_READS
                     how many CONSECUTIVE reads must return an identical
                     claim inventory (and contain this lane's own claim)
                     before admission will decide (default 2, minimum 2).
  GIBSON_CLAIM_ADMIT_DELAY
                     seconds between those reads (default 2, minimum 1). The
                     quiescence window is (STABLE_READS - 1) x DELAY; a rival
                     that publishes within it is seen, one that takes longer is
                     not, and everything unproven refuses.
                     These three may only RAISE the barrier. A value below the
                     production minimum is refused as a usage error — the
                     barrier cannot be weakened or switched off from the
                     environment.

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
# Joined form is display / PR-body metadata ONLY. Execution and validation
# always iterate SCOPE_PARTS unflattened so a quoted literal `*`, `**`, or
# `a/**/b` reaches the sensor byte-for-byte (#153 review round 7).
SCOPE="${SCOPE_PARTS[*]}"
[[ ${#SCOPE_PARTS[@]} -gt 0 ]] || { echo "claim.sh: ERROR: no scope given" >&2; exit 2; }

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
# node is a HARD requirement, checked before anything is mutated (#153 review
# round 3, P1). scope-overlap.mjs is the authoritative overlap and admission
# decision; the old stem-grep fallback answered a weaker question and, worse,
# ran only after the label, branch, PR and worktree already existed. A host
# that cannot run the real check must not claim at all.
command -v node >/dev/null ||
  die "node required — scope-overlap.mjs is the authoritative claim-overlap and admission check and there is no weaker fallback; refusing to claim on a host that cannot run it"

# --- run the sensor without inherited Node runtime configuration ------------
# (#153 review round 5, P1) NODE_OPTIONS is code injection with a boring name:
# `NODE_OPTIONS='--import=data:text/javascript,<js>'` runs arbitrary JavaScript
# inside the sensor process before its first line, which is enough to replace
# the publication barrier's blocking primitive and turn a configured
# fail-closed spacing barrier into a successful immediate read. The sensor
# defends itself too (it measures the wait rather than trusting it), but
# production must not be the thing that hands the payload in: an environment
# variable that names code to execute IS an execution path, exactly like the
# PATH-resolved `sleep` this replaced.
#
# `env -u` (POSIX, present on macOS's bash 3.2) unsets the variable for the
# child only; the caller's environment is untouched. NODE_REPL_EXTERNAL_MODULE
# goes with it — it is the same class of "load this module for me" knob.
#
# This is defence in depth, not a claim to resist a hostile local operator:
# anyone who can set NODE_OPTIONS can usually also edit the sensor or replace
# `node`. What it does buy is that inherited runtime configuration — a stray
# export in a shell profile, a CI job template, a wrapper script — cannot
# silently weaken the barrier.
run_sensor() { env -u NODE_OPTIONS -u NODE_REPL_EXTERNAL_MODULE node "$@"; }
[[ -f "$SCRIPT_DIR/scope-overlap.mjs" ]] ||
  die "cannot find $SCRIPT_DIR/scope-overlap.mjs — refusing to claim without the authoritative overlap/admission sensor"
[[ -x "$SCRIPT_DIR/pr-claims.sh" ]] ||
  die "cannot execute $SCRIPT_DIR/pr-claims.sh — refusing to claim without the authoritative live-claim reader"

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
#
# Discover the default branch from ORIGIN, not from the local checkout (#153
# Linux CI / race fixtures). A bare origin whose HEAD still points at a
# nonexistent `master` (Ubuntu `git init --bare` default when
# init.defaultBranch is unset) leaves a second clone with only
# `refs/remotes/origin/main` and no local `main`. Inferring BASE from the local
# branch name then tried `git fetch origin master`, which does not exist, and
# both concurrent lanes died before PR creation — a real portability bug that
# never reproduced on macOS hosts whose init.defaultBranch is already `main`.
if git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  BASE=main
elif git ls-remote --exit-code --heads origin master >/dev/null 2>&1; then
  BASE=master
else
  die "cannot find origin/main or origin/master — refuse claim (no local/stale ledger fallback; #106)"
fi
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

# Read + shape-validate `pr-claims.sh list` for $REPO. Sets INVENTORY_ROWS on
# success; on failure sets INVENTORY_ERR and returns 1. Every caller treats an
# unreadable or malformed inventory as UNREADABLE, never as empty: "no live
# claims" and "I could not find out" are different answers, and only one of
# them licenses a mutation (#153 review round 3, P1).
INVENTORY_ROWS=""
INVENTORY_ERR=""
read_live_inventory() {
  local rows row fields id num cross
  INVENTORY_ROWS=""
  INVENTORY_ERR=""
  if ! rows=$("$SCRIPT_DIR/pr-claims.sh" list "$REPO" 2>&1); then
    INVENTORY_ERR="the live claim inventory for $REPO is unreadable — $rows"
    return 1
  fi
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    fields=$(awk -F'\t' '{print NF}' <<<"$row")
    num=$(awk -F'\t' '{print $1}' <<<"$row")
    id=$(awk -F'\t' '{print $2}' <<<"$row")
    # Column 8 is repository identity (#153 review round 5, P1). It is
    # `true`/`false` and nothing else; an absent or unparseable value is
    # unreadable evidence, not "same repository".
    cross=$(awk -F'\t' '{print $8}' <<<"$row")
    if [[ "$fields" -ne 8 || -z "$id" || "$id" != issue-* || ! "$num" =~ ^[0-9]+$ ]]; then
      INVENTORY_ERR="the live claim inventory for $REPO returned a malformed/truncated row — $row"
      return 1
    fi
    if [[ "$cross" != "true" && "$cross" != "false" ]]; then
      INVENTORY_ERR="the live claim inventory for $REPO returned a row whose repository identity is neither 'true' nor 'false' ('${cross:-<empty>}') — $row"
      return 1
    fi
  done <<EOF
$rows
EOF
  INVENTORY_ROWS="$rows"
  return 0
}

# --- body-agnostic open-PR inventory (#153 review round 5, P1) --------------
# `pr-claims.sh list` only lists a PR while that PR carries a well-formed claim
# marker, so "our claim id is gone from the inventory" is satisfied BOTH by a
# PR that really closed and by a PR that is wide open with its marker deleted
# or rewritten. rollback_pr used to accept the first reading and then destroy
# the worktree, both branches and the issue-wide label behind a PR that may
# still be holding the issue. `list-open-numbers` is keyed on the PR NUMBER,
# which no body edit can change, so it can tell the two apart.
#
# Sets OPEN_NUMBERS on success (possibly empty). Sets OPEN_NUMBERS_ERR and
# returns 1 when the read failed or returned a non-decimal row — an unreadable
# inventory is not proof that a PR closed.
OPEN_NUMBERS=""
OPEN_NUMBERS_ERR=""
read_open_pr_numbers() {
  local out line
  OPEN_NUMBERS=""
  OPEN_NUMBERS_ERR=""
  if ! out=$("$SCRIPT_DIR/pr-claims.sh" list-open-numbers "$REPO" 2>&1); then
    OPEN_NUMBERS_ERR="the open pull-request inventory for $REPO is unreadable — $out"
    return 1
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ ! "$line" =~ ^[0-9]+$ ]]; then
      OPEN_NUMBERS_ERR="the open pull-request inventory for $REPO returned a non-numeric row '$line'"
      return 1
    fi
  done <<EOF
$out
EOF
  OPEN_NUMBERS="$out"
  return 0
}

# True when PR number $1 is still listed as open. Callers must have proven the
# read itself succeeded via read_open_pr_numbers first.
open_pr_number_present() {
  printf '%s\n' "$OPEN_NUMBERS" | grep -qxF -- "$1"
}

# Every live claim id: PR-body claims (authoritative) plus the legacy ledger
# forms still read for claims made by older versions. Prints ids on stdout and
# the reason on stderr; returns 1 when ANY of those reads could not be
# completed. A swallowed read here is how a lane walks past a live claim.
live_claim_ids() {
  local tree table body
  if ! read_live_inventory; then
    echo "claim.sh: $INVENTORY_ERR" >&2
    return 1
  fi
  if [[ -n "$INVENTORY_ROWS" ]]; then
    printf '%s\n' "$INVENTORY_ROWS" | awk -F '\t' 'NF>0 {print $2}'
  fi
  if ! tree=$(git ls-tree --name-only "$REF" docs/claims/ 2>&1); then
    echo "claim.sh: cannot read the claim ledger tree at $REF:docs/claims/ — an unreadable tree is not an empty one: $tree" >&2
    return 1
  fi
  if [[ -n "$tree" ]]; then
    printf '%s\n' "$tree" | sed 's|^docs/claims/||;s|\.md$||' | grep -E '^issue-' || true
  fi
  # Presence first, then content: `git show` on a path that does not exist and
  # `git show` on a tree it cannot read both fail, and only one of those means
  # "there is no legacy table".
  if ! table=$(git ls-tree --name-only "$REF" docs/active-work.md 2>&1); then
    echo "claim.sh: cannot read $REF:docs/active-work.md — an unreadable path is not an absent one: $table" >&2
    return 1
  fi
  if [[ -n "$table" ]]; then
    if ! body=$(git show "$REF:docs/active-work.md" 2>&1); then
      echo "claim.sh: cannot read the legacy claim table $REF:docs/active-work.md: $body" >&2
      return 1
    fi
    printf '%s\n' "$body" | grep -E '^\| ' | awk -F'|' '{print $3}' |
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^issue-' || true
  fi
  return 0
}

if ! LIVE_IDS_RAW=$(live_claim_ids); then
  die "cannot read the authoritative live-claim inventory for $REPO (reason above) — refusing to claim against a view that was never read"
fi
LIVE_IDS=$(printf '%s\n' "$LIVE_IDS_RAW" | sed '/^$/d' | sort -u)

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
# The dedicated sensor is the ONLY implementation (node was proven above).
# Build argv from the original SCOPE_PARTS array — never flatten+re-split, or a
# quoted literal `*` undergoes pathname expansion against matching paths in
# the working tree and the validator never sees the real token (#153 r7).
_so_args=(--repo-path "$CANONICAL" --base "$BASE" --claim-id "$CLAIM_ID" --repo "$REPO" --issue "$ISSUE")
for s in "${SCOPE_PARTS[@]}"; do
  _so_args+=(--scope "$s")
done
if [[ "$SLICE" -eq 1 ]]; then
  _so_args+=(--slice)
fi
if ! run_sensor "$SCRIPT_DIR/scope-overlap.mjs" "${_so_args[@]}"; then
  die "scope overlap (or ledger unreadable) — coordinate; do not race (#106)"
fi

LABEL_ADDED=0
LABEL_PRE_PRESENT=0
WORKTREE_CREATED=0
BRANCH_PUSHED=0
PR_NUMBER=""
# Set to 1 the instant `gh pr create` is INVOKED, before its result is known.
# A PR can exist even when the command reported failure or printed something
# unparseable, and a rollback that assumes otherwise deletes a worktree and a
# branch out from under an open claim PR (#153 review round 3, P1).
PR_CREATE_ATTEMPTED=0
PR_CREATE_RC=1
CLAIM_COMPLETE=0
# The exact commit this lane put on its own branch. Fixed at creation time and
# never re-read from the ref later: a value read immediately before a delete
# trivially equals itself, so only a value pinned back here can catch a branch
# that advanced during the admission window (#153 review P1 0D).
CLAIM_EXPECTED_OID=""
ROLLBACK_LEFTOVERS=""

leftover() { ROLLBACK_LEFTOVERS="${ROLLBACK_LEFTOVERS}  - $1"$'\n'; }

# --- rollback phase 1: this lane's own claim PR ----------------------------
# Nothing else may be destroyed until this returns 0. The claim IS the open PR:
# while it may still be open, the worktree and branch are the live work behind
# a live claim, and agent-claimed is the issue-wide flag that claim still needs.
#
# Returns 0 only when it is PROVEN that this lane holds no live claim PR:
#   * `gh pr create` was never invoked (nothing to own), or
#   * it was invoked, the inventory is readable and well formed, and it carries
#     no claim of ours and the create itself failed, or
#   * the PR was positively bound to this lane (exact claim id AND exact head
#     branch, and the number this lane created when it knows one), positively
#     closed, and a FRESH read of the inventory proves it is no longer live.
# Everything else returns 1: the artifacts are retained and the uncertainty is
# named. A `gh pr close` that failed, a close that reported success while the
# claim is still live, an unreadable/malformed/ambiguous inventory, and a
# create whose output could not be parsed all land here.
ROLLBACK_INVENTORY_FRESH=0
rollback_pr() {
  local matches="" count row num id head cross
  ROLLBACK_INVENTORY_FRESH=0
  if [[ "$PR_CREATE_ATTEMPTED" -ne 1 ]]; then
    return 0
  fi

  if ! read_live_inventory; then
    leftover "this lane's draft claim PR${PR_NUMBER:+ #$PR_NUMBER} for $CLAIM_ID (kept: $INVENTORY_ERR — an unread inventory cannot prove whether the claim is still live)"
    return 1
  fi

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    num=$(awk -F'\t' '{print $1}' <<<"$row")
    id=$(awk -F'\t' '{print $2}' <<<"$row")
    head=$(awk -F'\t' '{print $4}' <<<"$row")
    cross=$(awk -F'\t' '{print $8}' <<<"$row")
    if [[ "$id" == "$CLAIM_ID" ]] || { [[ -n "$PR_NUMBER" ]] && [[ "$num" == "$PR_NUMBER" ]]; }; then
      matches="${matches}${num}"$'\t'"${id}"$'\t'"${head}"$'\t'"${cross}"$'\n'
    fi
  done <<EOF
$INVENTORY_ROWS
EOF
  count=$(printf '%s' "$matches" | grep -c . || true)

  if [[ "$count" -gt 1 ]]; then
    leftover "this lane's draft claim PR for $CLAIM_ID (kept: $count live claim rows match claim id '$CLAIM_ID'${PR_NUMBER:+ or PR #$PR_NUMBER} — ambiguous evidence, refusing to close or clean up anything)"
    return 1
  fi

  if [[ "$count" -eq 1 ]]; then
    num=$(printf '%s' "$matches" | cut -f1)
    id=$(printf '%s' "$matches" | cut -f2)
    head=$(printf '%s' "$matches" | cut -f3)
    cross=$(printf '%s' "$matches" | cut -f4)
    if [[ "$id" != "$CLAIM_ID" || "$head" != "$BRANCH" ]]; then
      leftover "PR #$num (kept: it matched by number but carries claim '$id' on head branch '$head', not this lane's '$CLAIM_ID' on '$BRANCH' — refusing to close a PR that is not provably this lane's)"
      return 1
    fi
    # (#153 review round 5, P1) This lane pushed its branch into $REPO itself,
    # so its own claim PR is same-repository by construction. A row that says
    # otherwise — or that cannot say — is not this lane's PR, whatever its
    # marker and branch name claim, and `gh pr close` is irreversible.
    if [[ "$cross" != "false" ]]; then
      leftover "PR #$num (kept: it is not provably a same-repository pull request (isCrossRepository='${cross:-<missing>}', want 'false') — this lane pushed $BRANCH into $REPO itself, so a fork PR carrying its claim marker is unexplained evidence and must not be closed)"
      return 1
    fi
    if [[ -n "$PR_NUMBER" && "$num" != "$PR_NUMBER" ]]; then
      leftover "PR #$num (kept: this lane created PR #$PR_NUMBER, so a different live PR carrying its claim id is unexplained evidence)"
      return 1
    fi
    PR_NUMBER="$num"
  elif [[ -z "$PR_NUMBER" ]]; then
    # (#153 review round 4, P1) `gh pr create` was invoked and this lane has
    # no PR number, and the live inventory shows no claim of ours. That is
    # TWO different worlds, and the command's exit status cannot tell them
    # apart:
    #
    #   * the request never reached GitHub, or was rejected before the PR was
    #     created — there is genuinely nothing to close; or
    #   * GitHub created the PR and the response or the network died on the
    #     way back, or the create succeeded and its output was unparseable.
    #     The PR exists, it is a LIVE claim, and the eventually-consistent
    #     list simply has not published it yet.
    #
    # A nonzero exit is evidence about the CLIENT's view of the call, never
    # authoritative evidence about server-side state, and one negative read of
    # an eventually consistent inventory is not proof of absence either. The
    # old code treated `rc != 0` plus one empty read as proof there was no PR
    # and returned 0 — which let PHASE 2 delete the worktree, both branches,
    # and the issue-wide label out from under a PR that may be open right now.
    #
    # There is no authoritative pre-creation proof available here, so this
    # fails closed the only honest way: retain every artifact, keep
    # agent-claimed, name the PR that may exist, and exit INCOMPLETE. Refusal
    # is recoverable by hand; a destroyed branch behind an open claim is not.
    if [[ "$PR_CREATE_RC" -ne 0 ]]; then
      leftover "a possible draft claim PR for $CLAIM_ID (kept: gh pr create exited $PR_CREATE_RC and the live inventory does not show the claim — but a nonzero exit is the client's view of the call, not proof GitHub created nothing, and one read of an eventually consistent inventory is not proof of absence. The PR may exist and be unpublished. Find and close it by hand before re-claiming this issue)"
      return 1
    fi
    # gh pr create reported SUCCESS but its output could not be parsed into a
    # number. The PR may exist and simply not be published to this view yet —
    # and absence from an eventually consistent view is not proof of absence.
    leftover "a possible draft claim PR for $CLAIM_ID (kept: gh pr create reported success but its output could not be parsed into a PR number, and the live inventory does not show the claim; the PR may exist and be unpublished. Find and close it by hand before re-claiming this issue)"
    return 1
  fi

  # PR_NUMBER is bound here — either parsed from this lane's own create, or
  # discovered above and proven to carry this lane's claim id and branch.
  if ! gh pr close "$PR_NUMBER" --repo "$REPO" >/dev/null 2>&1; then
    leftover "PR #$PR_NUMBER (kept: gh pr close failed — this lane's claim may still be LIVE. Close it by hand; nothing else was removed)"
    return 1
  fi
  info "rollback: closed this lane's own PR #$PR_NUMBER"

  # A close that reported success is not proof the claim stopped being live.
  # The authoritative inventory saying so is.
  if ! read_live_inventory; then
    leftover "PR #$PR_NUMBER (kept: gh pr close reported success but the post-close inventory could not be re-read to prove the claim is gone — $INVENTORY_ERR)"
    return 1
  fi
  if printf '%s\n' "$INVENTORY_ROWS" |
     awk -F'\t' -v c="$CLAIM_ID" -v n="$PR_NUMBER" 'NF>0 && ($2==c || $1==n) {f=1} END{exit !f}'; then
    leftover "PR #$PR_NUMBER (kept: it is STILL a live claim after gh pr close reported success — refusing to destroy anything while the claim may be held)"
    return 1
  fi
  # (#153 review round 5, P1) The reread above is the CLAIM inventory, and a PR
  # drops out of it the moment its claim marker is deleted or rewritten —
  # whether or not the PR closed. So "our row is gone" is satisfied by a lying
  # close just as well as by a real one, and everything phase 2 destroys (the
  # worktree, both branch refs, the issue-wide label) is the live work behind
  # that possibly-still-open PR. Bind the proof to the exact PR NUMBER, which
  # no body edit can forge, using the body-agnostic open-PR inventory. An
  # unreadable inventory or a number that is still open retains EVERYTHING.
  if ! read_open_pr_numbers; then
    leftover "PR #$PR_NUMBER (kept: gh pr close reported success and this lane's claim row is gone, but the body-agnostic open pull-request inventory could not be read to prove PR #$PR_NUMBER is actually closed — $OPEN_NUMBERS_ERR. A claim row can disappear because the marker was edited, not because the PR closed)"
    return 1
  fi
  if open_pr_number_present "$PR_NUMBER"; then
    leftover "PR #$PR_NUMBER (kept: it is STILL OPEN in $REPO although its claim marker no longer appears in the claim inventory — a removed or rewritten marker is not a closed PR. Refusing to destroy the worktree, branches or label behind a pull request that may still hold issue #$ISSUE)"
    return 1
  fi
  # This same freshly-read, post-close inventory is what the label step below
  # reasons about: one authoritative read, taken after this claim stopped
  # being live, instead of two that could disagree.
  ROLLBACK_INVENTORY_FRESH=1
  return 0
}

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
  local rows sibling_ids="" unparseable="" _row row_num row_id
  if [[ "$LABEL_ADDED" -ne 1 ]]; then
    return 0
  fi
  if [[ "$LABEL_PRE_PRESENT" -eq 1 ]]; then
    info "rollback: leaving agent-claimed on #$ISSUE — it was already there before this claim"
    return 0
  fi

  if [[ "$ROLLBACK_INVENTORY_FRESH" -eq 1 ]]; then
    # rollback_pr already took a validated read AFTER this lane's PR stopped
    # being live. Re-reading here would only introduce a second view that can
    # disagree with the one the PR phase proved its postcondition against.
    rows="$INVENTORY_ROWS"
  elif read_live_inventory; then
    rows="$INVENTORY_ROWS"
  else
    leftover "agent-claimed on #$ISSUE (kept: $INVENTORY_ERR, so a sibling lane cannot be ruled out)"
    return 1
  fi
  while IFS= read -r _row; do
    [[ -n "$_row" ]] || continue
    row_num=$(awk -F'\t' '{print $1}' <<<"$_row")
    row_id=$(awk -F'\t' '{print $2}' <<<"$_row")
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

  # PHASE 1 — the claim itself. Bind, close, and freshly prove this lane's own
  # PR is no longer a live claim. Until that holds, the worktree, the branches
  # and the issue-wide label are all still backing a claim that may be live,
  # and destroying any of them is destroying work behind an open PR (#153
  # review round 3, P1). Anything unproven retains EVERYTHING.
  if ! rollback_pr; then
    if [[ "$WORKTREE_CREATED" -eq 1 ]]; then
      leftover "worktree $WT_DIR (kept: this lane's claim PR could not be proven closed and no longer live)"
    fi
    if [[ "$WORKTREE_CREATED" -eq 1 || "$BRANCH_PUSHED" -eq 1 ]]; then
      leftover "local and remote branch $BRANCH (kept: this lane's claim PR could not be proven closed and no longer live)"
    fi
    if [[ "$LABEL_ADDED" -eq 1 && "$LABEL_PRE_PRESENT" -ne 1 ]]; then
      leftover "agent-claimed on #$ISSUE (kept: agent-claimed is issue-wide and this lane's claim PR may still be open — removing it would unflag a live claim)"
    fi
    echo "claim.sh: INCOMPLETE — rollback preserved work instead of destroying it. Left behind:" >&2
    printf '%s' "$ROLLBACK_LEFTOVERS" >&2
    echo "claim.sh: resolve these by hand. Nothing was force-removed, and no issue-wide label was touched." >&2
    [[ "$rc" -eq 0 ]] && rc=1
    exit "$rc"
  fi

  # PHASE 2 — only now, with no live claim of ours left, the artifacts.
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
# Use the already-proven remote base end-to-end (#153 review round 6, P1).
# $BASE was selected from the live remote via ls-remote and fetched above;
# $REF is origin/$BASE and was verified after fetch. Independently preferring
# a cached origin/main (or falling back to a different branch) can create a
# worktree from the wrong history when the remote only has master but a stale
# origin/main remains cached at a different OID — and the PR --base, claim
# metadata, and branch ancestry would then disagree. Fail closed if the exact
# proven ref is unavailable; never substitute another branch.
DEFAULT_REMOTE_BRANCH="origin/$BASE"
if ! git rev-parse --verify --quiet "$DEFAULT_REMOTE_BRANCH^{commit}" >/dev/null; then
  die "cannot resolve $DEFAULT_REMOTE_BRANCH after fetch — refuse claim (the selected remote base must be available; no fallback to a different branch; #153)"
fi

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
# Mark the attempt BEFORE the call. From this line on, a PR may exist no
# matter what gh reports, and rollback must bind and close it before it
# destroys anything (#153 review round 3, P1).
PR_CREATE_ATTEMPTED=1
PR_CREATE_RC=0
PR_CREATE_OUT=$(gh pr create --repo "$REPO" --draft --base "$BASE" --head "$BRANCH" \
  --title "WIP: claim #$ISSUE — $SLUG" --body-file "$BODY" 2>&1) || PR_CREATE_RC=$?
rm -f "$BODY"
if [[ "$PR_CREATE_RC" -eq 0 ]]; then
  PR_NUMBER=$(printf '%s\n' "$PR_CREATE_OUT" | sed -n 's|.*/pull/\([0-9][0-9]*\).*|\1|p' | head -1)
fi
if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  PR_NUMBER=""
  # Two different failures, one honest message: gh may have failed outright,
  # or it may have created the PR and printed something this cannot parse. The
  # rollback below decides which by asking the authoritative inventory, and
  # retains everything if it cannot tell.
  die "draft PR creation did not yield a usable PR number (gh exit $PR_CREATE_RC): ${PR_CREATE_OUT:-<no output>}"
fi

# --- post-create admission (#153 review P1: cross-issue overlap TOCTOU) -----
# The pre-create check above read an inventory that could not yet contain a
# concurrent lane's claim. Re-decide now that this claim IS published. The
# publication barrier and the decision both live in scope-overlap.mjs, which
# takes its own live reads: nothing hands it an inventory, because an option to
# supply one is a forged-evidence path (#153 review round 3, P1). Losing here
# rolls this lane back through cleanup_claim — its own PR first, and the
# worktree, branch and label only once that PR is proven closed — and exits
# nonzero.
_adm_args=(--repo-path "$CANONICAL" --base "$BASE" --claim-id "$CLAIM_ID" --repo "$REPO" --issue "$ISSUE" --admit-pr "$PR_NUMBER")
# Same unflattened SCOPE_PARTS as pre-create — admission must see the exact
# tokens the operator typed, including literal `*` / `**` / `a/**/b` (#153 r7).
for s in "${SCOPE_PARTS[@]}"; do
  _adm_args+=(--scope "$s")
done
if [[ "$SLICE" -eq 1 ]]; then
  _adm_args+=(--slice)
fi
if ! run_sensor "$SCRIPT_DIR/scope-overlap.mjs" "${_adm_args[@]}"; then
  die "post-create admission refused for $CLAIM_ID (PR #$PR_NUMBER) — see the reason above.
  Either a live claim with a stronger prior holds this issue or overlapping scope (the race resolving deterministically: the lower PR number wins), or the live inventory could not be settled and read, which is refused rather than guessed.
  This lane's PR is being closed and its branch, worktree and label rolled back only once that close is proven; re-run once the other lane releases, claim a disjoint scope, or pass --slice if a deliberate second lane with non-overlapping scope on this issue is really what you want."
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
