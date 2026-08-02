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
#   These cases pin the four ways it must fail closed, and the one way it may
#   pass. They drive the real scripts/loop.sh against stub reviewer/supervisor
#   CLIs, so a regression in the driver — not in the stubs — is what turns them
#   red.
#
# USAGE
#   scripts/tests/loop-handoff.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
GIBSON=$(cd "$SCRIPT_DIR/../.." && pwd)
LOOP="$GIBSON/scripts/loop.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "loop-handoff.test.sh: node is required"; exit 1; }
command -v git  >/dev/null || { echo "loop-handoff.test.sh: git is required"; exit 1; }

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
setup_repo() { # setup_repo [with-remote]
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
  if [[ "${1:-}" == "with-remote" ]]; then
    $GIT init -q --bare "$REMOTE"
    git -C "$REPO" remote add origin "$REMOTE"
    git -C "$REPO" push -q origin "$BRANCH"
  fi
  : > "$CALLS/second-opinion.args"
  : > "$CALLS/second-opinion.count"
  : > "$CALLS/devin.cmds"
  : > "$CALLS/devin.args"
}

head_sha() { git -C "$REPO" rev-parse --verify "refs/heads/$BRANCH"; }

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

echo "a reviewer that fails blocks the handoff"
setup_repo
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

echo "a stale second-opinion.md does not satisfy the gate"
setup_repo
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

echo "a reviewer list with no distinct vendor blocks the handoff"
setup_repo
write_state "$BRANCH" ""
run_loop --reviewers hermes
if handoff_invoked; then bad "the runner must never be its own reviewer (Law 5)"
else ok "same-vendor-only reviewer list blocks the handoff"; fi
if review_invoked; then bad "no reviewer should have been dispatched"
else ok "refused before dispatching the runner against itself"; fi

echo "the pinned SHA is honoured when it matches the remote tip"
setup_repo with-remote
write_state "$BRANCH" "$(head_sha)"
run_loop
if handoff_invoked; then ok "a pin matching the remote tip hands off"
else bad "a matching pin was wrongly blocked"; fi

echo
echo "loop-handoff.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
