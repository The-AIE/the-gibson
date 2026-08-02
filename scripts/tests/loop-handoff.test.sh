#!/usr/bin/env bash
# loop-handoff.test.sh — sensors for the Law 5 gate in front of a supervisor handoff
#
# WHY
#   The gate used to advertise a mandatory cross-vendor review and then fail
#   open: any non-empty gibson/second-opinion.md satisfied it, the reviewer was
#   never told which tip to inspect, and a reviewer that failed only printed a
#   warning before the handoff went out anyway. A gate that cannot say no is
#   documentation, not a gate (issue #55, AGENTS.md Law 5).
#
#   These cases pin the ways it must fail closed, and the ways it may pass. They
#   drive the real scripts/loop.sh against stub reviewer/supervisor CLIs, so a
#   regression in the driver — not in the stubs — is what turns them red. Two
#   cases at the end drive the real scripts/devin-supervisor.sh with --dry-run
#   instead, because the guard and the diffstat they sense live there: no Devin
#   API is contacted.
#
# USAGE
#   scripts/tests/loop-handoff.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
GIBSON=$(cd "$SCRIPT_DIR/../.." && pwd)
LOOP="$GIBSON/scripts/loop.sh"
# The real supervisor, driven with --dry-run only: it renders the handoff message
# and never touches the Devin API, so its guards and its diffstat can be sensed
# directly rather than through the driver's stub.
SUPERVISOR="$GIBSON/scripts/devin-supervisor.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "loop-handoff.test.sh: node is required"; exit 1; }
command -v git  >/dev/null || { echo "loop-handoff.test.sh: git is required"; exit 1; }
# devin-supervisor.sh checks for curl before it ever looks at --dry-run.
command -v curl >/dev/null || { echo "loop-handoff.test.sh: curl is required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-loop-handoff.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

CALLS="$ROOT/calls"
FAKE_SCRIPTS="$ROOT/fake/scripts"
BIN="$ROOT/bin"
REPO="$ROOT/repo"
REMOTE="$ROOT/remote.git"
BRANCH="feat/1-widget"

mkdir -p "$CALLS" "$FAKE_SCRIPTS" "$BIN"

# `gh` would reach the network from halted(); the driver treats a non-zero gh as
# "no halt label", which is what this stub returns instantly.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

# Stub reviewer. Records its argv, always writes the --out artifact (a failed
# reviewer leaves a partial file behind in real life — that file must not be
# mistaken for a passing review), and exits STUB_SECOND_OPINION_RC.
cat > "$FAKE_SCRIPTS/second-opinion.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$CALLS/second-opinion.args"
echo call >> "$CALLS/second-opinion.count"
out=""
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--out" ]] && out="\$a"
  prev="\$a"
done
if [[ -n "\$out" ]]; then
  mkdir -p "\$(dirname "\$out")"
  echo "## Second opinion — stub reviewer" > "\$out"
fi
exit "\${STUB_SECOND_OPINION_RC:-0}"
STUB

# Stub supervisor. Records the subcommand and the full argv.
cat > "$FAKE_SCRIPTS/devin-supervisor.sh" <<STUB
#!/usr/bin/env bash
echo "\$1" >> "$CALLS/devin.cmds"
printf '%s\n' "\$@" >> "$CALLS/devin.args"
exit "\${STUB_DEVIN_RC:-0}"
STUB

cp "$LOOP" "$FAKE_SCRIPTS/loop.sh"
chmod +x "$BIN/gh" "$FAKE_SCRIPTS/second-opinion.sh" "$FAKE_SCRIPTS/devin-supervisor.sh" "$FAKE_SCRIPTS/loop.sh"
PATH="$BIN:$PATH"
export PATH

GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

# A target repo with one branch to hand off, and a bare remote it is pushed to.
# `with-remote` is the realistic default: a supervisor handoff only means anything
# for a branch that exists on a remote, so every case that expects a review to run
# or a handoff to complete uses it.
#   (none)                   — no origin at all: a genuinely local-only repo, and
#                              therefore a repo that can never hand off
#   with-remote              — origin configured, main and the branch pushed
#   with-remote-unpublished  — origin configured, only main pushed; the finished
#                              branch exists in this checkout and nowhere else
setup_repo() { # setup_repo [with-remote|with-remote-unpublished]
  rm -rf "$REPO" "$REMOTE"
  mkdir -p "$REPO"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  echo base > "$REPO/README.md"
  $GIT -C "$REPO" add README.md
  $GIT -C "$REPO" commit -q -m "base"
  $GIT -C "$REPO" checkout -q -b "$BRANCH"
  echo work >> "$REPO/README.md"
  $GIT -C "$REPO" commit -q -am "work"
  $GIT -C "$REPO" checkout -q main
  if [[ "${1:-}" == "with-remote" || "${1:-}" == "with-remote-unpublished" ]]; then
    $GIT init -q --bare "$REMOTE"
    git -C "$REPO" remote add origin "$REMOTE"
    if [[ "$1" == "with-remote" ]]; then
      git -C "$REPO" push -q origin main "$BRANCH"
    else
      git -C "$REPO" push -q origin main
    fi
    # Pinned explicitly so the machine's init.defaultBranch cannot decide what
    # the driver resolves as the base.
    git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
  fi
  : > "$CALLS/second-opinion.args"
  : > "$CALLS/second-opinion.count"
  : > "$CALLS/devin.cmds"
  : > "$CALLS/devin.args"
}

# A target repo whose trunk is NOT `main`. The driver used to let
# second-opinion.sh and devin-supervisor.sh fall back to their own `main`
# default, so every non-main repo was reviewed against a ref that does not
# exist. `origin_head` picks what local metadata the driver must NOT be fooled by:
#   stale-local — refs/remotes/origin/HEAD points at a decoy; only the remote's
#                 advertised HEAD names the real trunk, and that is the answer
#   remote      — no local origin/HEAD at all; same remote-derived answer
#   none        — no origin; resolution falls back to a local main/master, and a
#                 repo with neither cannot be reviewed
setup_repo_trunk() { # setup_repo_trunk <trunk> <stale-local|remote|none>
  local trunk="$1" origin_head="${2:-stale-local}"
  rm -rf "$REPO" "$REMOTE"
  mkdir -p "$REPO"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD "refs/heads/$trunk"
  echo base > "$REPO/README.md"
  $GIT -C "$REPO" add README.md
  $GIT -C "$REPO" commit -q -m "base"
  $GIT -C "$REPO" checkout -q -b "$BRANCH"
  echo work >> "$REPO/README.md"
  $GIT -C "$REPO" commit -q -am "work"
  $GIT -C "$REPO" checkout -q "$trunk"
  if [[ "$origin_head" != "none" ]]; then
    $GIT init -q --bare "$REMOTE"
    git -C "$REPO" remote add origin "$REMOTE"
    git -C "$REPO" push -q origin "$trunk" "$BRANCH"
    git -C "$REMOTE" symbolic-ref HEAD "refs/heads/$trunk"
    if [[ "$origin_head" == "stale-local" ]]; then
      # Cached local metadata that disagrees with the remote — exactly what a
      # default-branch rename leaves behind. A driver that trusts it resolves
      # `decoy` and reviews the wrong diff.
      git -C "$REPO" update-ref refs/remotes/origin/decoy \
        "$(git -C "$REPO" rev-parse --verify "refs/heads/$trunk")"
      git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/decoy
    else
      git -C "$REPO" remote set-head origin --delete 2>/dev/null || true
    fi
  fi
  : > "$CALLS/second-opinion.args"
  : > "$CALLS/second-opinion.count"
  : > "$CALLS/devin.cmds"
  : > "$CALLS/devin.args"
}

head_sha() { git -C "$REPO" rev-parse --verify "refs/heads/$BRANCH"; }

# The value passed to <flag> in a recorded argv (one argument per line).
arg_after() { # arg_after <file> <flag>
  awk -v flag="$2" 'prev == flag { print; exit } { prev = $0 }' "$1"
}

write_state() { # write_state <handoff-branch> <handoff-sha>
  mkdir -p "$REPO/gibson"
  cat > "$REPO/gibson/loop-state.md" <<EOF
# Gibson loop state
updated: 2026-08-02T00:00:00Z
issue: 1
pr:
hat: builder
next_hat: builder
round: 1
parked: false
handoff: ${1:-}
handoff_sha: ${2:-}
next_action: hand the finished branch to the supervisor
notes: fixture
EOF
}

run_loop() { # run_loop [extra loop.sh args...]
  HERMES_CMD='cat >/dev/null' \
  "$FAKE_SCRIPTS/loop.sh" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
    --once --supervisor devin "$@" >/dev/null 2>&1
}

handoff_invoked() { grep -qx handoff "$CALLS/devin.cmds"; }
review_invoked()  { [[ -s "$CALLS/second-opinion.count" ]]; }
still_queued()    { grep -qx "handoff: $BRANCH" "$REPO/gibson/loop-state.md"; }

JOURNAL="$REPO/gibson/journal.md"

# playbooks/loop-step.md sends the next fresh-context agent to the journal to
# find out why a handoff is still queued. stderr does not survive the run, so a
# refusal that only prints there leaves that agent with a stuck branch and no
# reason — and every blocked path below is a path that used to do exactly that.
# Each case asserts its OWN reason, not merely that something was written: a
# generic "blocked" line would satisfy a blanket check while telling the reader
# nothing they can act on.
journal_says() { # journal_says <substring>
  [[ -f "$JOURNAL" ]] && grep -qF -- "$1" "$JOURNAL"
}
journal_blocks() { # count of block entries — one failed attempt, one entry
  [[ -f "$JOURNAL" ]] || { echo 0; return; }
  grep -c '· handoff blocked' "$JOURNAL" || true
}

# check_block <reason-substring> <label>: the reason is in the journal AND the
# branch is still queued, which is the pair the contract actually promises.
check_block() {
  if journal_says "$1"; then
    ok "the journal records the actionable reason ($2)"
  else
    bad "the journal does not name the reason ($2). Journal: $([[ -f "$JOURNAL" ]] && cat "$JOURNAL" || echo '<absent>')"
  fi
  if still_queued; then
    ok "the branch is still queued alongside that journal entry ($2)"
  else
    bad "the branch was cleared despite a blocked handoff ($2)"
  fi
}

echo "a reviewer that fails blocks the handoff"
setup_repo with-remote
write_state "$BRANCH" ""
STUB_SECOND_OPINION_RC=1 run_loop
if handoff_invoked; then bad "reviewer failure must not reach devin-supervisor.sh handoff"
else ok "reviewer failure blocks the supervisor invocation"; fi
if review_invoked; then ok "the reviewer was actually attempted"
else bad "the reviewer was never attempted"; fi
if still_queued; then ok "blocked handoff stays queued in loop-state"
else bad "blocked handoff was cleared from loop-state"; fi
if [[ -e "$REPO/gibson/second-opinion.receipt" ]]; then
  bad "a failed review must not leave a receipt"
else ok "a failed review leaves no receipt"; fi
check_block "pre-handoff review failed" "reviewer did not complete"
# One blocked attempt, one entry. A journal that repeats the same refusal per
# resolve step is as unreadable as one that records nothing.
if [[ "$(journal_blocks)" -eq 1 ]]; then
  ok "a single failed attempt left exactly one block entry"
else
  bad "expected exactly 1 block entry, found $(journal_blocks)"
fi

echo "a stale second-opinion.md does not satisfy the gate"
setup_repo with-remote
write_state "$BRANCH" ""
mkdir -p "$REPO/gibson"
cat > "$REPO/gibson/second-opinion.md" <<'STALE'
## Second opinion — codex
VERDICT: approve
(written days ago, against a tip nobody remembers)
STALE
run_loop
if review_invoked; then ok "a stale artifact still forces a fresh review"
else bad "the stale artifact was accepted as the review"; fi

echo "the review is run against the exact handed-off SHA"
SHA=$(head_sha)
if grep -qx -- "--branch" "$CALLS/second-opinion.args" &&
   grep -qxF -- "$SHA" "$CALLS/second-opinion.args"; then
  ok "reviewer was pinned to $SHA, not to a branch name or HEAD"
else
  bad "reviewer was not told to inspect $SHA"
fi

echo "a completed distinct-vendor review lets the handoff through"
if handoff_invoked; then ok "supervisor received the handoff"
else bad "supervisor never received the handoff"; fi
if grep -qxF -- "$SHA" "$CALLS/devin.args" && grep -qx -- "--sha" "$CALLS/devin.args"; then
  ok "handoff pinned the same SHA the reviewer saw"
else
  bad "handoff did not pin $SHA"
fi
if still_queued; then bad "a completed handoff must clear loop-state"
else ok "a completed handoff clears handoff/handoff_sha"; fi

echo "a loop-state pin that disagrees with the remote tip blocks the handoff"
setup_repo with-remote
write_state "$BRANCH" "0000000000000000000000000000000000000001"
run_loop
if handoff_invoked; then bad "a stale pin must not be handed off"
else ok "pin/remote-tip mismatch blocks the handoff"; fi
if review_invoked; then bad "a mismatched pin must not even spend a review"
else ok "mismatched pin is refused before spending a reviewer"; fi
if still_queued; then ok "mismatched pin stays queued"
else bad "mismatched pin was cleared from loop-state"; fi
check_block "pin mismatch" "loop-state pin disagrees with the remote tip"
if [[ "$(journal_blocks)" -eq 1 ]]; then
  ok "the mismatched pin left exactly one block entry"
else
  bad "expected exactly 1 block entry for the mismatched pin, found $(journal_blocks)"
fi

echo "a reviewer list with no distinct vendor blocks the handoff"
# Remote-backed on purpose: everything else about this handoff is in order, so
# the ONLY thing that can block it is the Law 5 vendor check.
setup_repo with-remote
write_state "$BRANCH" ""
run_loop --reviewers hermes
if handoff_invoked; then bad "the runner must never be its own reviewer (Law 5)"
else ok "same-vendor-only reviewer list blocks the handoff"; fi
if review_invoked; then bad "no reviewer should have been dispatched"
else ok "refused before dispatching the runner against itself"; fi
check_block "no distinct vendor" "reviewer list names only the runner's vendor"

echo "an empty reviewer list blocks the handoff and says so in the journal"
# Distinct from the case above: there is no vendor at all, not merely no vendor
# other than the runner. Both used to leave nothing behind but a stderr line.
setup_repo with-remote
write_state "$BRANCH" ""
run_loop --reviewers ""
if handoff_invoked; then bad "an empty reviewer list must not hand off (Law 5)"
else ok "an empty reviewer list blocks the supervisor invocation"; fi
if review_invoked; then bad "there was no reviewer to dispatch"
else ok "refused before dispatching anyone"; fi
check_block "no reviewers configured" "--reviewers is empty"

echo "the pinned SHA is honoured when it matches the remote tip"
setup_repo with-remote
write_state "$BRANCH" "$(head_sha)"
run_loop
if handoff_invoked; then ok "a pin matching the remote tip hands off"
else bad "a matching pin was wrongly blocked"; fi

echo "a finished branch that was never pushed blocks the handoff"
# The gate's premise is that the reviewer and the supervisor look at the same
# commit. The supervisor opens the PR from the REMOTE branch, so a branch that
# lives only in this checkout has no reviewable remote tip at all. The driver
# used to fall back to refs/heads/<branch> here and review — and hand off — a
# commit the supervisor could never see. Local refs never answer now: neither an
# origin-less repo nor an unpublished branch is a valid Devin handoff, and each
# is tested separately (the unpublished branch here, the origin-less repo below).
setup_repo with-remote-unpublished
write_state "$BRANCH" ""
if [[ -n "$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" 2>/dev/null)" ]]; then
  bad "fixture bug: the finished branch is on the remote after all"
else
  ok "the finished branch exists only in the local checkout"
fi
run_loop
if review_invoked; then bad "an unpublished branch must not be sent to a reviewer"
else ok "an unpublished branch is refused before spending a reviewer"; fi
if handoff_invoked; then bad "an unpublished branch must never reach the supervisor"
else ok "an unpublished branch blocks the supervisor invocation"; fi
if [[ -e "$REPO/gibson/second-opinion.receipt" ]]; then
  bad "an unpublished branch must not leave a receipt"
else ok "an unpublished branch leaves no receipt"; fi
if still_queued; then ok "the branch stays queued until it is pushed"
else bad "the handoff was cleared for a branch the supervisor cannot fetch"; fi
check_block "branch not on the remote" "the finished branch was never pushed"

echo "devin-supervisor.sh itself refuses a pinned handoff for an unpublished branch"
# The driver is not the only caller (docs/22 documents a by-hand handoff), so the
# same hole is sensed one layer down, with --dry-run: no Devin API is touched.
sup_err="$ROOT/supervisor.err"
if sup_out=$("$SUPERVISOR" handoff --repo "$REPO" --branch "$BRANCH" --base main \
    --sha "$(head_sha)" --task "unpublished-branch sensor" --dry-run 2>"$sup_err"); then
  bad "a pinned handoff for an unpushed branch must fail, not render a message"
else
  ok "the pinned handoff failed closed for an unpushed branch"
fi
if grep -q "never pushed" "$sup_err"; then
  ok "the failure names the real reason (no remote branch)"
else
  bad "the failure did not explain that origin has no such branch: $(cat "$sup_err")"
fi
if [[ -z "${sup_out:-}" ]]; then
  ok "no handoff message was rendered for an unpublished branch"
else
  bad "a handoff message was rendered despite the missing remote branch"
fi

echo "a repo with no origin at all blocks the handoff before the review"
# The other half of the same premise. supervisor_handoff runs only for the Devin
# supervisor, and the supervisor opens the PR from a REMOTE branch — so a repo
# with no remote has nothing to hand off, whatever its local refs say. The driver
# used to resolve refs/heads/<branch> here, spend the distinct-vendor review on
# it, and only then hit devin-supervisor.sh's own no-origin refusal. The review
# is the expensive part; it must not be spent on a handoff that cannot succeed.
setup_repo
write_state "$BRANCH" ""
if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  bad "fixture bug: the local-only repo has an origin after all"
else
  ok "the fixture repo has no origin at all"
fi
run_loop
if review_invoked; then bad "an origin-less repo must not spend a distinct-vendor review"
else ok "an origin-less repo is refused before spending a reviewer"; fi
if handoff_invoked; then bad "an origin-less repo must never reach the supervisor"
else ok "an origin-less repo blocks the supervisor invocation"; fi
if [[ -e "$REPO/gibson/second-opinion.receipt" ]]; then
  bad "an origin-less repo must not leave a receipt"
else ok "an origin-less repo leaves no receipt"; fi
if still_queued; then ok "the branch stays queued until the repo has a remote"
else bad "the handoff was cleared for a repo the supervisor cannot pull from"; fi
check_block "no origin configured" "the repo has no remote at all"

echo "devin-supervisor.sh itself refuses a pinned handoff in a repo with no origin"
# The layer below, again with --dry-run: this is the refusal the driver would
# otherwise reach only after the review had already been spent.
sup_err="$ROOT/supervisor-no-origin.err"
if sup_out=$("$SUPERVISOR" handoff --repo "$REPO" --branch "$BRANCH" --base main \
    --sha "$(head_sha)" --task "no-origin sensor" --dry-run 2>"$sup_err"); then
  bad "a pinned handoff in an origin-less repo must fail, not render a message"
else
  ok "the pinned handoff failed closed with no origin configured"
fi
if grep -q "no origin configured" "$sup_err"; then
  ok "the failure names the real reason (no origin to confirm the pin against)"
else
  bad "the failure did not explain that the repo has no origin: $(cat "$sup_err")"
fi
if [[ -z "${sup_out:-}" ]]; then
  ok "no handoff message was rendered without an origin"
else
  bad "a handoff message was rendered despite the missing origin"
fi

echo "a master-trunk repo is reviewed against master's exact tip and handed off to master"
setup_repo_trunk master stale-local
write_state "$BRANCH" ""
run_loop
master_tip=$(git -C "$REPO" rev-parse --verify "refs/heads/master")
review_base=$(arg_after "$CALLS/second-opinion.args" --base)
devin_base=$(arg_after "$CALLS/devin.args" --base)
if [[ "$review_base" == "$master_tip" ]]; then
  ok "the pre-handoff review diffed against master's exact tip $master_tip"
else
  bad "review base was '${review_base:-<none>}' — expected master's tip $master_tip, not a decoy or the hardcoded default"
fi
if [[ "$devin_base" == "master" ]]; then
  ok "the supervisor handoff carried the base NAME master"
else
  bad "handoff base was '${devin_base:-<none>}' — expected master"
fi
if [[ "$(arg_after "$CALLS/devin.args" --base-sha)" == "$master_tip" ]]; then
  ok "the supervisor handoff also carried the exact base SHA $master_tip"
else
  bad "handoff --base-sha was '$(arg_after "$CALLS/devin.args" --base-sha)' — expected $master_tip"
fi
if grep -qxF "base: master" "$REPO/gibson/second-opinion.receipt" &&
   grep -qxF "base_sha: $master_tip" "$REPO/gibson/second-opinion.receipt"; then
  ok "the receipt recorded both the base name and the base SHA"
else
  bad "the receipt did not bind base master @ $master_tip"
fi
if handoff_invoked; then ok "the non-main handoff completed"
else bad "a master-trunk repo could not hand off at all"; fi

echo "a master-trunk repo with no local origin/HEAD resolves the base from the remote"
setup_repo_trunk master remote
write_state "$BRANCH" ""
run_loop
master_tip=$(git -C "$REPO" rev-parse --verify "refs/heads/master")
review_base=$(arg_after "$CALLS/second-opinion.args" --base)
if [[ "$review_base" == "$master_tip" ]]; then
  ok "the remote's advertised HEAD resolved the base and its tip"
else
  bad "review base was '${review_base:-<none>}' — the ls-remote --symref path did not resolve master @ $master_tip"
fi

echo "a repo whose base cannot be resolved blocks the handoff"
setup_repo_trunk dev none
write_state "$BRANCH" ""
run_loop
if review_invoked; then bad "no base means no reviewable diff — the reviewer must not be spent"
else ok "an unresolvable base is refused before dispatching a reviewer"; fi
if handoff_invoked; then bad "an unresolvable base must never reach the supervisor"
else ok "an unresolvable base blocks the supervisor invocation"; fi
if still_queued; then ok "the branch stays queued when the base is unresolvable"
else bad "the handoff was cleared despite an unresolvable base"; fi
check_block "base unresolvable" "no base branch could be resolved"

echo "a remote tip missing from the local object database is fetched, not faked"
setup_repo with-remote
OTHER="$ROOT/other"
rm -rf "$OTHER"
git clone -q "$REMOTE" "$OTHER"
git -C "$OTHER" checkout -q -B "$BRANCH" "origin/$BRANCH"
echo advanced >> "$OTHER/README.md"
$GIT -C "$OTHER" commit -q -am "advance the remote from a second clone"
git -C "$OTHER" push -q origin "$BRANCH"
ADVANCED=$(git -C "$OTHER" rev-parse HEAD)
if git -C "$REPO" rev-parse --verify --quiet "$ADVANCED^{commit}" >/dev/null 2>&1; then
  bad "fixture bug: the advanced commit is already in the target clone"
else
  ok "the advanced remote tip starts out absent from the target clone"
fi
write_state "$BRANCH" ""
run_loop
if [[ "$(arg_after "$CALLS/second-opinion.args" --branch)" == "$ADVANCED" ]]; then
  ok "the reviewer was pinned to the real remote tip $ADVANCED"
else
  bad "the reviewer was not pointed at the remote tip $ADVANCED"
fi
if git -C "$REPO" rev-parse --verify --quiet "$ADVANCED^{commit}" >/dev/null 2>&1; then
  ok "the driver fetched the missing object before reviewing it"
else
  bad "the driver recorded a review of a commit it never fetched"
fi
if grep -qxF -- "$ADVANCED" "$CALLS/devin.args"; then
  ok "the handoff pinned the fetched remote tip"
else
  bad "the handoff did not pin $ADVANCED"
fi

echo "a base branch that advances on the remote re-pins the review and voids the receipt"
# The head side has been pinned to an exact SHA since issue #55; the base side was
# still a branch NAME. `main` moving under a branch changes the diff just as much
# as the branch tip moving — and because the receipt only named the base by name,
# the same head against a newer base looked already-reviewed.
setup_repo with-remote
write_state "$BRANCH" ""
run_loop
HEAD_SHA=$(head_sha)
FIRST_BASE=$(git -C "$REPO" rev-parse --verify refs/heads/main)
if [[ "$(arg_after "$CALLS/second-opinion.args" --base)" == "$FIRST_BASE" ]]; then
  ok "the first review was pinned to the base tip $FIRST_BASE, not to the name main"
else
  bad "the first review base was '$(arg_after "$CALLS/second-opinion.args" --base)' — expected $FIRST_BASE"
fi
RECEIPT="$REPO/gibson/second-opinion.receipt"
if grep -qxF "base_sha: $FIRST_BASE" "$RECEIPT" && grep -qxF "sha: $HEAD_SHA" "$RECEIPT" &&
   grep -qxF "base: main" "$RECEIPT" && grep -qxF "branch: $BRANCH" "$RECEIPT"; then
  ok "the receipt bound both endpoints: main @ $FIRST_BASE ... $BRANCH @ $HEAD_SHA"
else
  bad "the receipt did not bind both endpoints of the reviewed diff"
fi

# Advance ONLY the base, from a second clone, so this clone keeps a stale
# refs/heads/main AND a stale refs/remotes/origin/main.
BASE_CLONE="$ROOT/base-clone"
rm -rf "$BASE_CLONE"
git clone -q "$REMOTE" "$BASE_CLONE"
git -C "$BASE_CLONE" checkout -q main
echo "trunk moved" > "$BASE_CLONE/NOTES.md"
$GIT -C "$BASE_CLONE" add NOTES.md
$GIT -C "$BASE_CLONE" commit -q -m "advance the base from a second clone"
git -C "$BASE_CLONE" push -q origin main
ADVANCED_BASE=$(git -C "$BASE_CLONE" rev-parse HEAD)
if [[ "$(git -C "$REPO" rev-parse --verify refs/heads/main)" == "$FIRST_BASE" &&
      "$(git -C "$REPO" rev-parse --verify refs/remotes/origin/main)" == "$FIRST_BASE" ]]; then
  ok "the target clone's local main and origin/main are both stale"
else
  bad "fixture bug: the target clone's base refs are not stale"
fi
if git -C "$REPO" rev-parse --verify --quiet "$ADVANCED_BASE^{commit}" >/dev/null 2>&1; then
  bad "fixture bug: the advanced base commit is already in the target clone"
else
  ok "the advanced base tip starts out absent from the target clone"
fi

# Same head, same author, same reviewers, same base NAME — only the base tip moved.
: > "$CALLS/second-opinion.args"
: > "$CALLS/second-opinion.count"
: > "$CALLS/devin.cmds"
: > "$CALLS/devin.args"
write_state "$BRANCH" ""
run_loop
if review_invoked; then
  ok "a receipt naming the previous base SHA is not reused once the base advances"
else
  bad "the stale receipt was reused against a base that had moved"
fi
if [[ "$(arg_after "$CALLS/second-opinion.args" --base)" == "$ADVANCED_BASE" ]]; then
  ok "the re-review was pinned to the new base tip $ADVANCED_BASE"
else
  bad "the re-review base was '$(arg_after "$CALLS/second-opinion.args" --base)' — expected $ADVANCED_BASE"
fi
if git -C "$REPO" rev-parse --verify --quiet "$ADVANCED_BASE^{commit}" >/dev/null 2>&1; then
  ok "the driver fetched the new base object before reviewing against it"
else
  bad "the driver reviewed against a base commit it never fetched"
fi
if [[ "$(arg_after "$CALLS/devin.args" --base)" == "main" ]]; then
  ok "the supervisor still received the base NAME main"
else
  bad "handoff base was '$(arg_after "$CALLS/devin.args" --base)' — the supervisor needs the branch name"
fi
# The names are for PR targeting; the SHAs are what the diffstat must be built
# from. Both endpoints handed to the supervisor must be the endpoints that were
# actually reviewed — in this clone `refs/heads/main` still points at the old
# base, so a supervisor given only names would describe a diff nobody reviewed.
if [[ "$(arg_after "$CALLS/devin.args" --base-sha)" == "$(arg_after "$CALLS/second-opinion.args" --base)" &&
      "$(arg_after "$CALLS/devin.args" --sha)" == "$(arg_after "$CALLS/second-opinion.args" --branch)" ]]; then
  ok "the supervisor's --base-sha/--sha are exactly the reviewer's two endpoints"
else
  bad "supervisor endpoints ($(arg_after "$CALLS/devin.args" --base-sha)...$(arg_after "$CALLS/devin.args" --sha)) differ from the reviewed ones ($(arg_after "$CALLS/second-opinion.args" --base)...$(arg_after "$CALLS/second-opinion.args" --branch))"
fi
if [[ "$(arg_after "$CALLS/devin.args" --base-sha)" == "$ADVANCED_BASE" &&
      "$(arg_after "$CALLS/devin.args" --sha)" == "$HEAD_SHA" ]]; then
  ok "the handoff pinned the advanced base $ADVANCED_BASE and the head $HEAD_SHA"
else
  bad "the handoff did not pin $ADVANCED_BASE...$HEAD_SHA"
fi
if grep -qxF "base_sha: $ADVANCED_BASE" "$RECEIPT" && grep -qxF "base: main" "$RECEIPT"; then
  ok "the new receipt records the exact advanced base SHA"
else
  bad "the receipt did not record base_sha $ADVANCED_BASE"
fi

echo "a pinned SHA that cannot be resolved locally blocks without a receipt"
# Remote-backed, but the advertised tip is unobtainable: origin still answers for
# refs/heads/<branch> while the object behind it is gone, which is what a pruned
# or garbage-collected tip looks like from here. The pin agrees with what the
# remote advertises, so nothing upstream of the fetch objects — and the fetch
# still cannot produce the commit, so there is no diff anyone could have
# reviewed. Recording a receipt for an object nobody can read would record a
# review that never happened.
setup_repo with-remote
DANGLING=0123456789abcdef0123456789abcdef01234567
mkdir -p "$(dirname "$REMOTE/refs/heads/$BRANCH")"
printf '%s\n' "$DANGLING" > "$REMOTE/refs/heads/$BRANCH"
if [[ "$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" | awk 'NR==1 {print $1}')" == "$DANGLING" ]] &&
   ! git -C "$REPO" rev-parse --verify --quiet "$DANGLING^{commit}" >/dev/null 2>&1; then
  ok "fixture: origin advertises $DANGLING and this clone cannot read it"
else
  bad "fixture bug: the dangling remote tip is not advertised, or is readable locally"
fi
write_state "$BRANCH" "$DANGLING"
run_loop
if review_invoked; then bad "an unfetchable SHA must not be sent to a reviewer"
else ok "an unresolvable pin is refused before spending a reviewer"; fi
if handoff_invoked; then bad "an unfetchable SHA must never reach the supervisor"
else ok "an unresolvable pin blocks the supervisor invocation"; fi
if [[ -e "$REPO/gibson/second-opinion.receipt" ]]; then
  bad "an unresolvable pin must not leave a receipt"
else ok "an unresolvable pin leaves no receipt"; fi
if still_queued; then ok "the branch stays queued when its pin is unresolvable"
else bad "the handoff was cleared despite an unresolvable pin"; fi
check_block "head object unfetchable" "the pinned commit cannot be fetched"

echo "a supervisor that rejects the handoff says so in the journal"
# The end of the gate, and the one refusal the driver does not own: everything
# passed, the review completed, and devin-supervisor.sh still said no. The
# branch correctly stays queued — but the next agent has to be told why, or it
# re-queues the same handoff into the same refusal forever.
setup_repo with-remote
write_state "$BRANCH" ""
STUB_DEVIN_RC=1 run_loop
if handoff_invoked; then ok "the supervisor was actually invoked"
else bad "the supervisor was never invoked, so this is not the case under test"; fi
check_block "supervisor rejected the handoff" "devin-supervisor.sh exited non-zero"

echo "the handoff diffstat is rendered from the exact reviewed SHAs, not from stale local refs"
# The message the supervisor reads is the only description of the change it gets
# before it looks for itself. Building the diffstat from `$BASE...$BRANCH` reads
# whatever those NAMES point at in the handing-off clone — refs that go stale the
# moment either side advances elsewhere, and that a local-only commit can make up
# entirely. Here both remote endpoints have moved and the local refs disagree, so
# a name-built diffstat describes a diff that exists nowhere.
setup_repo with-remote
DIFF_CLONE="$ROOT/diff-clone"
rm -rf "$DIFF_CLONE"
git clone -q "$REMOTE" "$DIFF_CLONE"
git -C "$DIFF_CLONE" checkout -q -B "$BRANCH" "origin/$BRANCH"
echo head > "$DIFF_CLONE/REMOTE-HEAD-ONLY.md"
$GIT -C "$DIFF_CLONE" add REMOTE-HEAD-ONLY.md
$GIT -C "$DIFF_CLONE" commit -q -m "advance the head on the remote"
git -C "$DIFF_CLONE" push -q origin "$BRANCH"
EXACT_HEAD=$(git -C "$DIFF_CLONE" rev-parse HEAD)
git -C "$DIFF_CLONE" checkout -q main
echo base > "$DIFF_CLONE/REMOTE-BASE-ONLY.md"
$GIT -C "$DIFF_CLONE" add REMOTE-BASE-ONLY.md
$GIT -C "$DIFF_CLONE" commit -q -m "advance the base on the remote"
git -C "$DIFF_CLONE" push -q origin main
EXACT_BASE=$(git -C "$DIFF_CLONE" rev-parse HEAD)

# A local-only commit on the stale branch ref: `main...$BRANCH` in this clone now
# names a diff that exists on no remote.
$GIT -C "$REPO" checkout -q "$BRANCH"
echo stale > "$REPO/STALE-LOCAL-ONLY.md"
$GIT -C "$REPO" add STALE-LOCAL-ONLY.md
$GIT -C "$REPO" commit -q -m "a local-only commit the remote never saw"
$GIT -C "$REPO" checkout -q main
# Fetch the objects without moving refs/heads/*: the clone can READ both reviewed
# commits (as the driver guarantees before any review) while its branch names
# still point somewhere else.
git -C "$REPO" fetch -q origin main "$BRANCH"
if git -C "$REPO" diff --stat "main...$BRANCH" | grep -q 'STALE-LOCAL-ONLY'; then
  ok "fixture: the local branch names describe a diff of their own"
else
  bad "fixture bug: the local refs are not stale"
fi

sup_msg=$("$SUPERVISOR" handoff --repo "$REPO" --branch "$BRANCH" --base main \
  --base-sha "$EXACT_BASE" --sha "$EXACT_HEAD" --task "diffstat sensor" --dry-run 2>/dev/null)
sup_rc=$?
if [[ "$sup_rc" -eq 0 ]]; then
  ok "the pinned handoff rendered with both exact endpoints"
else
  bad "the pinned handoff failed (rc=$sup_rc) even though both objects are present"
fi
if grep -qF 'REMOTE-HEAD-ONLY.md' <<<"$sup_msg"; then
  ok "the diffstat contains the path committed on the reviewed head $EXACT_HEAD"
else
  bad "the diffstat does not name REMOTE-HEAD-ONLY.md — it was not built from $EXACT_BASE...$EXACT_HEAD"
fi
if grep -qF 'STALE-LOCAL-ONLY.md' <<<"$sup_msg"; then
  bad "the diffstat describes the stale local branch diff, not the reviewed one"
else
  ok "the stale local-only commit is absent from the diffstat"
fi
if grep -qF 'REMOTE-BASE-ONLY.md' <<<"$sup_msg"; then
  bad "the diffstat leaked base-only changes — it is not a $EXACT_BASE...$EXACT_HEAD three-dot diff"
else
  ok "base-only changes are absent, as a three-dot diff of the reviewed endpoints requires"
fi
if grep -qF "Branch: \`$BRANCH\`" <<<"$sup_msg" && grep -qF 'Base: `main`' <<<"$sup_msg"; then
  ok "the human message still names both branches, so the PR can be targeted"
else
  bad "the message lost the branch names the supervisor opens the PR between"
fi
# The claim of exactness is only true when the diffstat was actually generated
# from those two commits — which it was here, so it must be made.
if grep -qF "the diffstat below is exactly \`$EXACT_BASE...$EXACT_HEAD\`" <<<"$sup_msg"; then
  ok "the message claims exactness for a diffstat it really did generate"
else
  bad "the message dropped the exactness claim for a diffstat built from $EXACT_BASE...$EXACT_HEAD"
fi

echo "an unavailable exact diffstat is never described as the reviewed diff"
# The other half of the same sentence. The message used to say "the diffstat
# below is exactly <base>...<head>, the diff that was reviewed" from the pinned
# clause while the diffstat itself was the string "n/a" — the two halves are
# built in different places and neither knew what the other did. A supervisor
# reading that is told the reviewed diff is in front of it when nothing was
# generated at all, and it is under instruction to review what it is given.
# Here the base object is genuinely absent from the clone while the head pin
# still matches the remote tip, so the guard passes and the diffstat cannot be
# built.
ABSENT_BASE=0123456789abcdef0123456789abcdef01234567
if git -C "$REPO" rev-parse --verify --quiet "$ABSENT_BASE^{commit}" >/dev/null 2>&1; then
  bad "fixture bug: the absent base commit is readable in the target clone"
else
  ok "fixture: the pinned base commit is absent from the handing-off clone"
fi
unavail_msg=$("$SUPERVISOR" handoff --repo "$REPO" --branch "$BRANCH" --base main \
  --base-sha "$ABSENT_BASE" --sha "$EXACT_HEAD" --task "diffstat unavailable sensor" --dry-run 2>/dev/null)
unavail_rc=$?
if [[ "$unavail_rc" -eq 0 ]]; then
  ok "the handoff still renders when the exact diffstat cannot be built"
else
  bad "the handoff failed (rc=$unavail_rc) instead of rendering an honest n/a"
fi
if grep -qF 'is exactly' <<<"$unavail_msg"; then
  bad "the message claims the diffstat is exactly the reviewed diff when none was generated"
else
  ok "no false exactness claim when the diffstat is unavailable"
fi
if grep -qF 'n/a' <<<"$unavail_msg"; then
  ok "the diffstat section says n/a outright"
else
  bad "the unavailable diffstat was not reported as n/a"
fi
if grep -qF "Reviewed against base commit: \`$ABSENT_BASE\`" <<<"$unavail_msg"; then
  ok "the reviewed base commit is still named, so the supervisor can rebuild the diff"
else
  bad "the message dropped the reviewed base commit $ABSENT_BASE"
fi
if grep -qF "Branch: \`$BRANCH\`" <<<"$unavail_msg" && grep -qF 'Base: `main`' <<<"$unavail_msg"; then
  ok "the unavailable-diffstat message still names both branches"
else
  bad "the unavailable-diffstat message lost the branch names"
fi

# The pinned-SHA clause is concatenated, not heredoc'd, so its trailing newline is
# easy to drop — and without it the last bullet runs straight into `## Task`,
# which stops being a Markdown heading. Assert the rendered blank line, not the
# shell that produces it: `awk` reports the line before every `## Task`, and every
# one of them must be empty. Checked for both the pinned and unpinned renderings,
# since they reach the same heading by different paths.
task_prev_lines() { awk '/^## Task$/ { print prev } { prev = $0 }' <<<"$1"; }

if grep -q '^## Task$' <<<"$sup_msg"; then
  ok "the pinned message still carries a '## Task' heading"
else
  bad "the pinned message has no '## Task' heading to check the spacing of"
fi
if [[ -n "$(task_prev_lines "$sup_msg" | tr -d '[:space:]')" ]]; then
  bad "no blank line before '## Task' in the pinned message — the heading is glued to the SHA clause"
else
  ok "a real blank line separates the pinned-SHA clause from '## Task'"
fi

# The unavailable-diffstat rendering reaches '## Task' through a third branch of
# the same concatenated clause, so it can lose the blank line on its own.
if ! grep -q '^## Task$' <<<"$unavail_msg"; then
  bad "the unavailable-diffstat message has no '## Task' heading to check the spacing of"
elif [[ -n "$(task_prev_lines "$unavail_msg" | tr -d '[:space:]')" ]]; then
  bad "no blank line before '## Task' in the unavailable-diffstat message"
else
  ok "the unavailable-diffstat message keeps its blank line before '## Task'"
fi

# Same render with no --sha: the template's own newline has to supply the blank
# line, so this half regresses independently of the clause above.
unpinned_msg=$("$SUPERVISOR" handoff --repo "$REPO" --branch "$BRANCH" --base main \
  --task "unpinned spacing sensor" --dry-run 2>/dev/null)
if grep -q '^## Pinned head' <<<"$unpinned_msg"; then
  bad "the unpinned message rendered a pinned-head clause anyway"
elif [[ -n "$(task_prev_lines "$unpinned_msg" | tr -d '[:space:]')" ]]; then
  bad "no blank line before '## Task' in the unpinned message"
else
  ok "the unpinned message keeps its blank line before '## Task' too"
fi

echo
echo "loop-handoff.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
