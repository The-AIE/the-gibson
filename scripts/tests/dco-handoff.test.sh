#!/usr/bin/env bash
# dco-handoff.test.sh — sensors for Signed-off-by refusal on handoff (issue #204)
# and for the Agent-Vendor walk beside it (follow-up to the-gibson#520/#523)
#
# WHY
#   CI must not be the first thing that notices an unsigned commit. Supervisor
#   handoff (including --dry-run) and the loop handoff path refuse any commit
#   in the handed-off range that lacks a Signed-off-by trailer. The *base*
#   commit is outside that range and is left unsigned on purpose.
#   Likewise review time must not be the first place to learn a lane commit
#   resolves to no vendor: the loop walks the same range for commits with no
#   Agent-Vendor trailer, more than one vendor, an unknown vendor, or a
#   `.invalid` author/committer email (lane-bot commits resolve by identity),
#   and scripts/prepush.sh reports the same rule through cp_agent_vendor_walk.
#
# USAGE
#   scripts/tests/dco-handoff.test.sh
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GIBSON=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
LOOP="$GIBSON/scripts/loop.sh"
SUPERVISOR="$GIBSON/scripts/devin-supervisor.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v git >/dev/null || { echo "dco-handoff.test.sh: git is required"; exit 1; }
command -v node >/dev/null || { echo "dco-handoff.test.sh: node is required"; exit 1; }
[[ -x "$LOOP" && -x "$SUPERVISOR" ]] || { echo "dco-handoff.test.sh: missing loop/supervisor"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-dco-handoff.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

CALLS="$ROOT/calls"
FAKE_SCRIPTS="$ROOT/fake/scripts"
BIN="$ROOT/bin"
REPO="$ROOT/repo"
REMOTE="$ROOT/remote.git"
BRANCH="feat/1-widget"
mkdir -p "$CALLS" "$FAKE_SCRIPTS" "$BIN"

unset DEVIN_API_KEY DEVIN_WEBHOOK_URL
export DEVIN_API_BASE="http://127.0.0.1:9"

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl stub: live network forbidden: $*" >&2
exit 55
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/curl" "$BIN/gh"
PATH="$BIN:$PATH"
export PATH

GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

# The hermetic identity above is sensor@gibson.invalid on purpose: `.invalid`
# is the no-login class the Agent-Vendor walk refuses. Work that must be handed
# off is therefore committed as a resolvable-looking lane address with one
# trailer; a lane-bot address resolves by identity and needs no trailer.
LANE_EMAIL=lane@gibson.test
BOT_EMAIL='317307306+aie-agent-lanes-grok[bot]@users.noreply.github.com'
work_commit() { # email [git-commit args...] — signed, -a
  local email="$1"; shift
  GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_EMAIL="$email" $GIT -C "$REPO" commit -q -s -a "$@"
}

# base stays unsigned on purpose; work commits are shaped per caller:
#   signed         one Agent-Vendor trailer, lane email (hands off)
#   unsigned       no Signed-off-by (DCO refuses first)
#   unvendored     signed, lane email, no trailer           (#506 class)
#   invalid-email  signed, trailer, author/committer .invalid (#503/#504 class)
#   two-vendors    signed, two distinct Agent-Vendor trailers
#   unknown-vendor signed, Agent-Vendor: bogus
#   bot            signed, lane-bot email, no trailer       (resolves by login)
#   bot-invalid-committer  lane-bot author, .invalid committer, no trailer
#   bare-invalid   signed, trailer, author/committer `codex@invalid` (bare form)
setup_repo() { # setup_repo <mode>
  local mode="${1:-signed}"
  rm -rf "$REPO" "$REMOTE"
  mkdir -p "$REPO"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  echo base > "$REPO/README.md"
  $GIT -C "$REPO" add README.md
  $GIT -C "$REPO" commit -q -m "base"
  $GIT -C "$REPO" checkout -q -b "$BRANCH"
  echo work >> "$REPO/README.md"
  case "$mode" in
    signed)         work_commit "$LANE_EMAIL" -m "work" -m "Agent-Vendor: claude" ;;
    unsigned)       $GIT -C "$REPO" commit -q -am "work" ;;
    unvendored)     work_commit "$LANE_EMAIL" -m "work" ;;
    invalid-email)  work_commit sensor@gibson.invalid -m "work" -m "Agent-Vendor: claude" ;;
    two-vendors)    work_commit "$LANE_EMAIL" -m "work" -m "Agent-Vendor: claude" -m "Agent-Vendor: codex" ;;
    unknown-vendor) work_commit "$LANE_EMAIL" -m "work" -m "Agent-Vendor: bogus" ;;
    bot)            work_commit "$BOT_EMAIL" -m "work" ;;
    bare-invalid)   work_commit codex@invalid -m "work" -m "Agent-Vendor: codex" ;;
    bot-invalid-committer)
      # Lane-bot author, .invalid committer, no trailer: review-evidence fails
      # committer:<sha>:no-login, so the walk must not take the bot fast path
      # before looking at both identities (Codex review of #525).
      GIT_AUTHOR_EMAIL="$BOT_EMAIL" GIT_COMMITTER_EMAIL=sensor@gibson.invalid $GIT -C "$REPO" commit -q -s -a -m "work" ;;
    *) echo "setup_repo: unknown mode $mode" >&2; exit 1 ;;
  esac
  $GIT -C "$REPO" checkout -q main
  $GIT init -q --bare "$REMOTE"
  git -C "$REPO" remote add origin "https://github.com/acme/widget.git"
  git -C "$REPO" config --local "url.${REMOTE}.insteadOf" "https://github.com/acme/widget.git"
  git -C "$REPO" push -q origin main "$BRANCH"
  git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
  : > "$CALLS/devin.cmds"
  : > "$CALLS/devin.args"
  : > "$CALLS/second-opinion.count"
}

head_sha() { git -C "$REPO" rev-parse --verify "refs/heads/$BRANCH"; }
base_sha() { git -C "$REPO" rev-parse --verify refs/heads/main; }

write_state() {
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

cat > "$FAKE_SCRIPTS/second-opinion.sh" <<STUB
#!/usr/bin/env bash
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
exit 0
STUB

cat > "$FAKE_SCRIPTS/devin-supervisor.sh" <<STUB
#!/usr/bin/env bash
echo "\$1" >> "$CALLS/devin.cmds"
printf '%s\n' "\$@" >> "$CALLS/devin.args"
exit 0
STUB

cp "$LOOP" "$FAKE_SCRIPTS/loop.sh"
chmod +x "$FAKE_SCRIPTS/second-opinion.sh" "$FAKE_SCRIPTS/devin-supervisor.sh" "$FAKE_SCRIPTS/loop.sh"

run_loop() {
  HERMES_CMD='cat >/dev/null' \
  "$FAKE_SCRIPTS/loop.sh" --runner hermes --repo "$REPO" --repo-slug acme/widget \
    --gibson "$GIBSON" --once --supervisor devin >/dev/null 2>"$1"
  return $?
}

handoff_invoked() { grep -qx handoff "$CALLS/devin.cmds"; }

echo "supervisor handoff --dry-run of unsigned work exits nonzero and names Signed-off-by"
setup_repo unsigned
SHA=$(head_sha)
BASE=$(base_sha)
# Prove the base itself is unsigned — a whole-history check would refuse this.
if git -C "$REPO" log -1 --format=%B "$BASE" | grep -iE '^Signed-off-by:[[:space:]]+' >/dev/null; then
  bad "fixture bug: base commit must stay unsigned"
else
  ok "fixture: base commit is unsigned (range-only check)"
fi
if git -C "$REPO" log -1 --format=%B "$SHA" | grep -iE '^Signed-off-by:[[:space:]]+' >/dev/null; then
  bad "fixture bug: work commit must be unsigned in this case"
else
  ok "fixture: work commit is unsigned"
fi
set +e
sup_out=$("$SUPERVISOR" handoff --repo "$REPO" --branch "$BRANCH" --base main \
  --base-sha "$BASE" --sha "$SHA" --task "unsigned sensor" --dry-run 2>"$ROOT/unsigned.err")
sup_rc=$?
set -e
if [[ "$sup_rc" -ne 0 ]]; then
  ok "unsigned range: supervisor --dry-run exits nonzero (rc=$sup_rc)"
else
  bad "unsigned range: supervisor --dry-run must refuse, not succeed"
fi
if grep -qi 'Signed-off-by' "$ROOT/unsigned.err" && grep -q "$SHA" "$ROOT/unsigned.err"; then
  ok "unsigned range: refusal names Signed-off-by and the unsigned SHA"
else
  bad "unsigned range: refusal unclear: $(cat "$ROOT/unsigned.err")"
fi
if [[ -z "${sup_out:-}" ]] || ! grep -q 'New candidate from the Gibson loop' <<<"${sup_out:-}"; then
  ok "unsigned range: no would-send / handoff message on stdout"
else
  bad "unsigned range: printed a would-send message despite unsigned work"
fi

echo "supervisor handoff --dry-run of a fully signed range does not refuse for DCO"
setup_repo signed
SHA=$(head_sha)
BASE=$(base_sha)
if git -C "$REPO" log -1 --format=%B "$BASE" | grep -iE '^Signed-off-by:[[:space:]]+' >/dev/null; then
  bad "fixture bug: signed-range case must keep the base unsigned"
else
  ok "fixture: signed-range base is still unsigned"
fi
if git -C "$REPO" log -1 --format=%B "$SHA" | grep -iE '^Signed-off-by:[[:space:]]+' >/dev/null; then
  ok "fixture: work commit is signed"
else
  bad "fixture bug: work commit is not signed"
fi
set +e
sup_out=$("$SUPERVISOR" handoff --repo "$REPO" --branch "$BRANCH" --base main \
  --base-sha "$BASE" --sha "$SHA" --task "signed sensor" --dry-run 2>"$ROOT/signed.err")
sup_rc=$?
set -e
if [[ "$sup_rc" -eq 0 ]]; then
  ok "signed range: supervisor --dry-run succeeds"
else
  bad "signed range: supervisor --dry-run failed (rc=$sup_rc stderr=$(cat "$ROOT/signed.err"))"
fi
if grep -qi 'Signed-off-by' "$ROOT/signed.err"; then
  bad "signed range: must not refuse for DCO (stderr=$(cat "$ROOT/signed.err"))"
else
  ok "signed range: no DCO refusal"
fi
if grep -q 'New candidate from the Gibson loop' <<<"$sup_out"; then
  ok "signed range: dry-run still renders the handoff message"
else
  bad "signed range: dry-run message missing"
fi

echo "empty range is fine (no commits to sign)"
setup_repo signed
# Hand the base commit to itself: <base>..<base> is empty.
BASE=$(base_sha)
set +e
"$SUPERVISOR" handoff --repo "$REPO" --branch main --base main \
  --base-sha "$BASE" --sha "$BASE" --task "empty range sensor" --dry-run \
  >/dev/null 2>"$ROOT/empty.err"
empty_rc=$?
set -e
if [[ "$empty_rc" -eq 0 ]]; then
  ok "empty range: supervisor --dry-run succeeds"
else
  bad "empty range must pass (rc=$empty_rc stderr=$(cat "$ROOT/empty.err"))"
fi

echo "loop handoff path refuses unsigned work before invoking the supervisor"
setup_repo unsigned
SHA=$(head_sha)
write_state "$BRANCH" "$SHA"
run_loop "$ROOT/loop-unsigned.err"
if handoff_invoked; then
  bad "loop must not invoke the supervisor for unsigned work"
else
  ok "loop does not invoke the supervisor for unsigned work"
fi
if [[ -s "$CALLS/second-opinion.count" ]]; then
  bad "loop must not spend a reviewer on unsigned work"
else
  ok "loop does not spend a reviewer on unsigned work"
fi
if grep -qi 'Signed-off-by' "$REPO/gibson/journal.md" &&
   grep -q "$SHA" "$REPO/gibson/journal.md"; then
  ok "loop journals the unsigned SHA and Signed-off-by"
else
  bad "loop journal missing DCO reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"
fi
if grep -qx "handoff: $BRANCH" "$REPO/gibson/loop-state.md"; then
  ok "unsigned loop handoff stays queued"
else
  bad "unsigned loop handoff was cleared from loop-state"
fi
if grep -qi 'Signed-off-by' "$ROOT/loop-unsigned.err"; then
  ok "loop stderr names Signed-off-by"
else
  bad "loop stderr silent on DCO: $(tr '\n' ' ' <"$ROOT/loop-unsigned.err")"
fi

echo "loop handoff path lets signed work through (unsigned base ignored)"
setup_repo signed
SHA=$(head_sha)
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-signed.err"
if handoff_invoked; then
  ok "loop hands off a signed range"
else
  bad "loop blocked a signed range (stderr=$(tr '\n' ' ' <"$ROOT/loop-signed.err") journal=$([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent))"
fi

# ---------------------------------------------------------------------------
# Agent-Vendor walk (follow-up to the-gibson#520/#523)
# ---------------------------------------------------------------------------
echo "Agent-Vendor walk: the loop refuses work review-evidence would not resolve, before reviewer or supervisor"
for mode in unvendored invalid-email two-vendors unknown-vendor; do
  setup_repo "$mode"
  SHA=$(head_sha)
  write_state "$BRANCH" "$SHA"
  run_loop "$ROOT/loop-$mode.err"
  if handoff_invoked; then bad "$mode: loop invoked the supervisor"
  else ok "$mode: loop does not invoke the supervisor"; fi
  if [[ -s "$CALLS/second-opinion.count" ]]; then bad "$mode: loop spent a reviewer"
  else ok "$mode: loop does not spend a reviewer"; fi
  if grep -q 'Agent-Vendor' "$REPO/gibson/journal.md" && grep -q "$SHA" "$REPO/gibson/journal.md" \
     && grep -q 'setup-hooks.sh --vendor from-reservation' "$REPO/gibson/journal.md" \
     && grep -q 'git commit --amend' "$REPO/gibson/journal.md"; then
    ok "$mode: journal names Agent-Vendor, the SHA and the fix (setup-hooks.sh --vendor, amend/rebase)"
  else
    bad "$mode: journal missing the Agent-Vendor reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"
  fi
  if grep -qi 'Signed-off-by trailer' "$REPO/gibson/journal.md"; then bad "$mode: refused for DCO, not for Agent-Vendor (fixture is signed)"
  else ok "$mode: the DCO walk passed; only the Agent-Vendor walk refused"; fi
  if grep -qx "handoff: $BRANCH" "$REPO/gibson/loop-state.md"; then ok "$mode: handoff stays queued"
  else bad "$mode: handoff was cleared from loop-state"; fi
done
# The reason the journal gives must be the evaluator's class, per mode.
setup_repo unvendored;     SHA=$(head_sha); write_state "$BRANCH" "$SHA"; run_loop "$ROOT/r1.err"
grep -q "$SHA no-trailer" "$REPO/gibson/journal.md" && ok "unvendored: reason is no-trailer" || bad "unvendored reason: $(cat "$REPO/gibson/journal.md")"
setup_repo invalid-email;  SHA=$(head_sha); write_state "$BRANCH" "$SHA"; run_loop "$ROOT/r2.err"
grep -q "$SHA invalid-email:sensor@gibson.invalid" "$REPO/gibson/journal.md" && ok "invalid-email: reason names the .invalid address" || bad "invalid-email reason: $(cat "$REPO/gibson/journal.md")"
setup_repo two-vendors;    SHA=$(head_sha); write_state "$BRANCH" "$SHA"; run_loop "$ROOT/r3.err"
grep -q "$SHA multi-vendor:claude,codex" "$REPO/gibson/journal.md" && ok "two-vendors: reason lists both" || bad "two-vendors reason: $(cat "$REPO/gibson/journal.md")"
setup_repo unknown-vendor; SHA=$(head_sha); write_state "$BRANCH" "$SHA"; run_loop "$ROOT/r4.err"
grep -q "$SHA unknown-vendor:bogus" "$REPO/gibson/journal.md" && ok "unknown-vendor: reason names bogus" || bad "unknown-vendor reason: $(cat "$REPO/gibson/journal.md")"

echo "Agent-Vendor walk: the bare user@invalid form is refused like .invalid (#523 round five)"
setup_repo bare-invalid
SHA=$(head_sha)
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-bare-invalid.err"
if handoff_invoked; then bad "bare-invalid: loop handed off a codex@invalid commit"
else ok "bare-invalid: loop does not invoke the supervisor"; fi
if grep -q "$SHA invalid-email:codex@invalid" "$REPO/gibson/journal.md"; then ok "bare-invalid: journal names codex@invalid"
else bad "bare-invalid: journal reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"; fi

echo "Agent-Vendor walk: a lane-bot author does not excuse a .invalid committer (mixed identity)"
setup_repo bot-invalid-committer
SHA=$(head_sha)
if [[ "$(git -C "$REPO" log -1 --format=%ae "$SHA")" == "$BOT_EMAIL" && "$(git -C "$REPO" log -1 --format=%ce "$SHA")" == "sensor@gibson.invalid" ]]; then ok "fixture: author is the lane bot, committer is .invalid"
else bad "fixture bug: identities $(git -C "$REPO" log -1 --format='%ae %ce' "$SHA")"; fi
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-bot-invalid.err"
if handoff_invoked; then bad "bot-invalid-committer: loop handed off a commit review-evidence rejects as committer no-login"
else ok "bot-invalid-committer: loop does not invoke the supervisor"; fi
if grep -q "$SHA invalid-email:sensor@gibson.invalid" "$REPO/gibson/journal.md"; then ok "bot-invalid-committer: journal names the .invalid committer"
else bad "bot-invalid-committer: journal reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"; fi

echo "Agent-Vendor walk: a lane-bot commit resolves by identity and is handed off without a trailer"
setup_repo bot
SHA=$(head_sha)
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-bot.err"
if handoff_invoked; then ok "lane-bot authored range is handed off"
else bad "lane-bot range blocked (stderr=$(tr '\n' ' ' <"$ROOT/loop-bot.err") journal=$([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent))"; fi

echo "Agent-Vendor walk: the same rule, as scripts/lib/agent-vendor.sh and prepush's cp_agent_vendor_walk"
# Probe return codes are data here, not failures: keep errexit off.
set +e
# shellcheck source=../lib/convention-probes.sh
. "$GIBSON/scripts/lib/convention-probes.sh"
# shellcheck source=../lib/agent-vendor.sh
. "$GIBSON/scripts/lib/agent-vendor.sh"
if [[ "$AGENT_VENDORS" == "claude codex grok devin" ]]; then ok "lib vendor list is the evaluator's four"
else bad "lib vendor list drifted: $AGENT_VENDORS"; fi
setup_repo unvendored
SHA=$(head_sha); BASE=$(base_sha)
out=$(agent_vendor_unresolved_shas "$REPO" "$BASE" "$SHA"); rc=$?
[[ "$rc" -eq 0 && "$out" == "$SHA no-trailer" ]] && ok "agent_vendor_unresolved_shas: readable range, one finding '<sha> no-trailer'" || bad "walk rc=$rc out='$out'"
out=$(agent_vendor_unresolved_shas "$REPO" "$BASE" "$BASE"); rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] && ok "agent_vendor_unresolved_shas: empty range is clean (the unsigned, .invalid base is outside it)" || bad "empty range rc=$rc out='$out'"
if agent_vendor_unresolved_shas "$REPO" "$BASE" deadbeef >/dev/null 2>&1; then bad "unreadable head must return 1"
else ok "agent_vendor_unresolved_shas: unreadable head returns 1 (caller fails closed)"; fi
agent_vendor_lane_bot_email "$BOT_EMAIL" && ok "lane-bot email recognised" || bad "lane-bot email not recognised"
setup_repo bot-invalid-committer
why=$(agent_vendor_commit_problem "$REPO" "$(head_sha)")
[[ "$why" == "invalid-email:sensor@gibson.invalid" ]] && ok "agent_vendor_commit_problem: bot author + .invalid committer → invalid-email (identities before the bot fast path)" || bad "mixed identity reason was '$why'"
setup_repo bot
why=$(agent_vendor_commit_problem "$REPO" "$(head_sha)")
[[ -z "$why" ]] && ok "agent_vendor_commit_problem: bot author + bot committer, no trailer → resolves" || bad "bot commit reason was '$why'"
agent_vendor_lane_bot_email "$LANE_EMAIL" && bad "lane email mistaken for a bot" || ok "a lane email is not a bot"
agent_vendor_lane_bot_email "x+dependabot[bot]@users.noreply.github.com" && bad "another bot mistaken for a lane bot" || ok "a non-lane bot is not a lane bot"
# Probe: run from inside the lane branch, undeclared → 3 (report only), declared → 1, fixed → 0, bad base → 2.
setup_repo unvendored
SHA=$(head_sha)
git -C "$REPO" checkout -q "$BRANCH"
out=$(cd "$REPO" && cp_agent_vendor_walk main); rc=$?
[[ "$rc" -eq 3 && "$out" == *"$SHA no-trailer"* && "$out" == *"fix: "* && "$out" == *"report only"* ]] && ok "cp_agent_vendor_walk: undeclared checkout → 3 with SHA, reason, fix" || bad "probe undeclared rc=$rc: $out"
# A --local-only value is not a declaration (the hooks read worktree scope only,
# gated on extensions.worktreeConfig): still report-only.
git -C "$REPO" config gibson.agentVendor claude
out=$(cd "$REPO" && cp_agent_vendor_walk main); rc=$?
[[ "$rc" -eq 3 ]] && ok "cp_agent_vendor_walk: --local-only gibson.agentVendor is not a declaration → still 3" || bad "probe local-only rc=$rc: $out"
git -C "$REPO" config --unset gibson.agentVendor
git -C "$REPO" config extensions.worktreeConfig true
git -C "$REPO" config --worktree gibson.agentVendor claude
[[ "$(agent_vendor_declared "$REPO")" == "claude" ]] && ok "agent_vendor_declared: worktree scope + extension on → claude" || bad "agent_vendor_declared read '$(agent_vendor_declared "$REPO")'"
out=$(cd "$REPO" && cp_agent_vendor_walk main); rc=$?
[[ "$rc" -eq 1 && "$out" == *"$SHA no-trailer"* ]] && ok "cp_agent_vendor_walk: declared lane (worktree scope, extension on) → 1" || bad "probe declared rc=$rc: $out"
git -C "$REPO" config --worktree --unset gibson.agentVendor
git -C "$REPO" config --unset extensions.worktreeConfig
out=$(cd "$REPO" && cp_agent_vendor_walk refs/heads/nope); rc=$?
[[ "$rc" -eq 2 ]] && ok "cp_agent_vendor_walk: unresolvable base → 2 (cannot run), never a pass" || bad "probe bad base rc=$rc: $out"
setup_repo signed
git -C "$REPO" checkout -q "$BRANCH"
out=$(cd "$REPO" && cp_agent_vendor_walk main); rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] && ok "cp_agent_vendor_walk: one known trailer under a resolvable email → 0" || bad "probe clean rc=$rc: $out"
git -C "$REPO" checkout -q main

echo
echo "dco-handoff.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
