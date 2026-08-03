#!/usr/bin/env bash
# loop-state.test.sh — sensors for loop-state validation + snapshot recovery (issue #75)
#
# WHY
#   gibson/loop-state.md is the loop's only memory. A free-form rewrite that drops
#   next_hat or typos a hat used to be silently defaulted to builder. These cases
#   pin the shared validator, the driver's pre-read / post-run order, exact-byte
#   snapshot restore, failure-budget accounting, and the #71 halt invariants.
#
# SCOPE
#   Throwaway repos + fake local runner binaries only. No live GitHub, curl,
#   Devin, Codex, Claude, Grok, or Hermes calls.
#
# USAGE
#   scripts/tests/loop-state.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
GIBSON=$(cd "$SCRIPT_DIR/../.." && pwd)
LOOP="$GIBSON/scripts/loop.sh"
VALIDATOR="$GIBSON/scripts/validate-loop-state.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v python3 >/dev/null || { echo "loop-state.test.sh: python3 is required"; exit 1; }
command -v git     >/dev/null || { echo "loop-state.test.sh: git is required"; exit 1; }
command -v node    >/dev/null || { echo "loop-state.test.sh: node is required"; exit 1; }
[[ -f "$LOOP" && -f "$VALIDATOR" ]] || { echo "loop-state.test.sh: missing loop/validator"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-loop-state.XXXXXX")
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"
CALLS="$ROOT/calls"
REPO="$ROOT/repo"
mkdir -p "$BIN" "$CALLS"

# Inert network stubs — never reach the wire.
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl stub: live network forbidden: $*" >&2
exit 55
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh stub: live network forbidden: $*" >&2
exit 1
STUB
chmod +x "$BIN/curl" "$BIN/gh"
PATH="$BIN:$PATH"
export PATH
unset DEVIN_API_KEY DEVIN_WEBHOOK_URL
export DEVIN_API_BASE="http://127.0.0.1:9"
export GH_HOST="github.com"

GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

utc_now() {
  python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

utc_offset() { # utc_offset <seconds-delta>  (negative = past)
  python3 - "$1" <<'PY'
import sys
from datetime import datetime, timezone, timedelta
delta = int(sys.argv[1])
print((datetime.now(timezone.utc) + timedelta(seconds=delta)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

# Full ten-key valid state. Args override individual fields as key=value.
write_valid_state() {
  local dest="${1:-$REPO/gibson/loop-state.md}"
  shift || true
  local updated issue pr hat next_hat round parked handoff handoff_sha next_action notes
  updated=$(utc_now)
  issue=""
  pr=""
  hat="builder"
  next_hat="builder"
  round="0"
  parked="false"
  handoff=""
  handoff_sha=""
  next_action="triage highest-priority unblocked unclaimed issue"
  notes="fixture"
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    case "$k" in
      updated) updated="$v" ;;
      issue) issue="$v" ;;
      pr) pr="$v" ;;
      hat) hat="$v" ;;
      next_hat) next_hat="$v" ;;
      round) round="$v" ;;
      parked) parked="$v" ;;
      handoff) handoff="$v" ;;
      handoff_sha) handoff_sha="$v" ;;
      next_action) next_action="$v" ;;
      notes) notes="$v" ;;
    esac
  done
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
# Gibson loop state
updated: $updated
issue: $issue
pr: $pr
hat: $hat
next_hat: $next_hat
round: $round
parked: $parked
handoff: $handoff
handoff_sha: $handoff_sha
next_action: $next_action
notes: $notes
EOF
}

setup_repo() {
  rm -rf "$REPO"
  mkdir -p "$REPO"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  echo base > "$REPO/README.md"
  $GIT -C "$REPO" add README.md
  $GIT -C "$REPO" commit -q -m "base"
  mkdir -p "$REPO/gibson"
  : > "$CALLS/runner.count"
  : > "$CALLS/runner.args"
  : > "$CALLS/supervisor.count"
  : > "$CALLS/second-opinion.count"
  rm -f "$REPO/gibson/loop-state.md" "$REPO/gibson/.loop-state.prev" \
        "$REPO/gibson/journal.md" "$REPO/gibson/HALT" "$REPO/gibson/halt-latch"
}

# Controllable fake hermes runner via HERMES_CMD. Behavior selected by
# $CALLS/runner.behavior (rewritten by each make_runner_cmd call).
#
#   noop                 — exit 0, leave state untouched (stale → state-corrupt)
#   fail                 — rewrite valid fresh state, exit 1 (true runner-failure)
#   rewrite-valid        — valid rewrite, exit 0
#   rewrite-missing-next — drop next_hat, exit 0
#   rewrite-typo-hat     — next_hat: bulider, exit 0
#   rewrite-stale        — valid schema but updated 5s in the past, exit 0
#   rewrite-colons       — next_action with colons, exit 0
#   rewrite-handoff      — queue handoff fields, exit 0
#   rewrite-valid-then-fail — valid rewrite, exit 3
make_runner_cmd() {
  echo "${1:-noop}" > "$CALLS/runner.behavior"
  cat > "$CALLS/fake-runner.sh" <<RUN
#!/usr/bin/env bash
set -euo pipefail
echo call >> "$CALLS/runner.count"
printf '%s\n' "\$@" >> "$CALLS/runner.args"
echo ran >> "$CALLS/runner.executed"
behavior=\$(cat "$CALLS/runner.behavior" 2>/dev/null || echo noop)
state="$REPO/gibson/loop-state.md"
now=\$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
write_valid() {
  local nh="\${1:-test-engineer}" na="\${2:-run tests for the unit}" notes="\${3:-rewritten valid}" ec="\${4:-0}"
  cat > "\$state" <<EOF
# Gibson loop state
updated: \$now
issue: 75
pr:
hat: builder
next_hat: \$nh
round: 1
parked: false
handoff:
handoff_sha:
next_action: \$na
notes: \$notes
EOF
  exit "\$ec"
}
case "\$behavior" in
  noop) exit 0 ;;
  fail) write_valid test-engineer "runner failed" "runner-fail" 1 ;;
  rewrite-valid) write_valid test-engineer "run tests for the unit" "rewritten valid" 0 ;;
  rewrite-valid-then-fail) write_valid test-engineer "valid but runner fails" "runner-fail" 3 ;;
  rewrite-missing-next)
    cat > "\$state" <<EOF
# Gibson loop state
updated: \$now
issue: 75
pr:
hat: builder
round: 1
parked: false
handoff:
handoff_sha:
next_action: oops dropped next_hat
notes: corrupt
EOF
    exit 0
    ;;
  rewrite-typo-hat)
    cat > "\$state" <<EOF
# Gibson loop state
updated: \$now
issue: 75
pr:
hat: builder
next_hat: bulider
round: 1
parked: false
handoff:
handoff_sha:
next_action: typo hat
notes: corrupt
EOF
    exit 0
    ;;
  rewrite-stale)
    stale=\$(python3 -c 'from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(seconds=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
    cat > "\$state" <<EOF
# Gibson loop state
updated: \$stale
issue: 75
pr:
hat: builder
next_hat: test-engineer
round: 1
parked: false
handoff:
handoff_sha:
next_action: stale stamp
notes: stale
EOF
    exit 0
    ;;
  rewrite-colons)
    cat > "\$state" <<EOF
# Gibson loop state
updated: \$now
issue: 75
pr: 12
hat: builder
next_hat: reviewer
round: 2
parked: false
handoff:
handoff_sha:
next_action: ship:feat/x: after review: go
notes: colons ok
EOF
    exit 0
    ;;
  rewrite-handoff)
    cat > "\$state" <<EOF
# Gibson loop state
updated: \$now
issue: 75
pr: 12
hat: builder
next_hat: test-engineer
round: 1
parked: false
handoff: feat/75-widget
handoff_sha: abcdef0123456789abcdef0123456789abcdef01
next_action: hand off the finished branch
notes: handoff queued
EOF
    exit 0
    ;;
  *)
    echo "fake-runner: unknown behavior \$behavior" >&2
    exit 99
    ;;
esac
RUN
  chmod +x "$CALLS/fake-runner.sh"
}

# Fake supervisor + second-opinion that record invocations (no network).
install_fake_supervisor_stack() {
  mkdir -p "$ROOT/fake/scripts"
  cp "$LOOP" "$ROOT/fake/scripts/loop.sh"
  chmod +x "$ROOT/fake/scripts/loop.sh"
  cat > "$ROOT/fake/scripts/second-opinion.sh" <<STUB
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
  echo "## Second opinion — stub" > "\$out"
fi
exit 0
STUB
  cat > "$ROOT/fake/scripts/devin-supervisor.sh" <<STUB
#!/usr/bin/env bash
echo "\$1" >> "$CALLS/supervisor.count"
printf '%s\n' "\$@" >> "$CALLS/supervisor.args"
# ensure is a no-op; handoff records and succeeds
if [[ "\$1" == "ensure" ]]; then exit 0; fi
if [[ "\$1" == "handoff" ]]; then exit 0; fi
exit 0
STUB
  chmod +x "$ROOT/fake/scripts/second-opinion.sh" "$ROOT/fake/scripts/devin-supervisor.sh"
  LOOP_BIN="$ROOT/fake/scripts/loop.sh"
}

runner_count() {
  local n=0
  if [[ -f "$CALLS/runner.count" ]]; then
    n=$(wc -l < "$CALLS/runner.count" | tr -d ' ')
  fi
  echo "${n:-0}"
}

supervisor_count() {
  local n=0
  if [[ -f "$CALLS/supervisor.count" ]]; then
    # grep -c exits 1 on zero matches but still prints 0 — do not append another 0.
    n=$(grep -c '^handoff$' "$CALLS/supervisor.count" 2>/dev/null || true)
  fi
  echo "${n:-0}"
}

journal_state_corrupt_count() {
  local n=0 j="$REPO/gibson/journal.md"
  if [[ -f "$j" ]]; then
    n=$(grep -c '· state-corrupt' "$j" 2>/dev/null || true)
  fi
  echo "${n:-0}"
}

# ---------------------------------------------------------------------------
# Validator unit cases
# ---------------------------------------------------------------------------
echo "validator: valid rewrite is quiet and passes"
VDIR="$ROOT/validator"
mkdir -p "$VDIR"
write_valid_state "$VDIR/ok.md" "next_action=do:the:thing:with:colons" "notes=extra remains"
out=$(bash "$VALIDATOR" "$VDIR/ok.md" 2>&1); ec=$?
if [[ $ec -eq 0 && -z "$out" ]]; then ok "valid file: exit 0, zero output"
else bad "valid file failed (ec=$ec out=$out)"; fi

echo "validator: missing / duplicate keys fail"
write_valid_state "$VDIR/missing.md"
# drop next_hat
grep -v '^next_hat:' "$VDIR/missing.md" > "$VDIR/missing2.md"
bash "$VALIDATOR" "$VDIR/missing2.md" >/dev/null 2>"$VDIR/missing.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -q 'missing required key: next_hat' "$VDIR/missing.err"; then
  ok "missing next_hat fails with diagnostic"
else bad "missing next_hat not diagnosed (ec=$ec $(cat "$VDIR/missing.err"))"; fi

write_valid_state "$VDIR/dup.md"
echo "next_hat: reviewer" >> "$VDIR/dup.md"
bash "$VALIDATOR" "$VDIR/dup.md" >/dev/null 2>"$VDIR/dup.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -q 'duplicate key' "$VDIR/dup.err"; then
  ok "duplicate next_hat fails"
else bad "duplicate not diagnosed (ec=$ec $(cat "$VDIR/dup.err"))"; fi

echo "validator: bulider / invalid hat / round / parked fail"
write_valid_state "$VDIR/typo.md" "next_hat=bulider"
bash "$VALIDATOR" "$VDIR/typo.md" >/dev/null 2>"$VDIR/typo.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -qi 'next_hat' "$VDIR/typo.err"; then
  ok "next_hat bulider fails"
else bad "bulider not rejected ($(cat "$VDIR/typo.err"))"; fi

write_valid_state "$VDIR/badhat.md" "hat=architect"
bash "$VALIDATOR" "$VDIR/badhat.md" >/dev/null 2>"$VDIR/badhat.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -q 'invalid hat' "$VDIR/badhat.err"; then
  ok "invalid current hat fails"
else bad "invalid hat not rejected ($(cat "$VDIR/badhat.err"))"; fi

write_valid_state "$VDIR/round.md" "round=-1"
bash "$VALIDATOR" "$VDIR/round.md" >/dev/null 2>"$VDIR/round.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -q 'round' "$VDIR/round.err"; then
  ok "negative round fails"
else bad "negative round not rejected ($(cat "$VDIR/round.err"))"; fi

write_valid_state "$VDIR/round2.md" "round=1.5"
bash "$VALIDATOR" "$VDIR/round2.md" >/dev/null 2>"$VDIR/round2.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -q 'round' "$VDIR/round2.err"; then
  ok "non-integer round fails"
else bad "1.5 round not rejected ($(cat "$VDIR/round2.err"))"; fi

write_valid_state "$VDIR/park.md" "parked=yes"
bash "$VALIDATOR" "$VDIR/park.md" >/dev/null 2>"$VDIR/park.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -q 'parked' "$VDIR/park.err"; then
  ok "parked=yes fails"
else bad "parked=yes not rejected ($(cat "$VDIR/park.err"))"; fi

echo "validator: indented / comment decoys never satisfy keys"
cat > "$VDIR/decoy.md" <<'EOF'
# Gibson loop state
updated: 2026-08-02T12:00:00Z
issue:
pr:
hat: builder
# next_hat: builder
  next_hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: x
EOF
bash "$VALIDATOR" "$VDIR/decoy.md" >/dev/null 2>"$VDIR/decoy.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -q 'missing required key: next_hat' "$VDIR/decoy.err"; then
  ok "indented/comment next_hat decoys do not satisfy the key"
else bad "decoys incorrectly accepted ($(cat "$VDIR/decoy.err"))"; fi

echo "validator: colons in next_action remain valid"
write_valid_state "$VDIR/colons.md" "next_action=a:b:c:d"
bash "$VALIDATOR" "$VDIR/colons.md" >/dev/null 2>"$VDIR/colons.err"; ec=$?
if [[ $ec -eq 0 ]]; then ok "colons in next_action valid"
else bad "colons rejected ($(cat "$VDIR/colons.err"))"; fi

echo "validator: timestamps — equality, newer, older, bad forms"
base="2026-08-02T12:00:00Z"
write_valid_state "$VDIR/ts.md" "updated=$base"
bash "$VALIDATOR" "$VDIR/ts.md" --min-updated "$base" >/dev/null 2>"$VDIR/ts.err"; ec=$?
if [[ $ec -eq 0 ]]; then ok "updated equal to min-updated passes"
else bad "equality failed ($(cat "$VDIR/ts.err"))"; fi

write_valid_state "$VDIR/ts2.md" "updated=2026-08-02T12:00:01Z"
bash "$VALIDATOR" "$VDIR/ts2.md" --min-updated "$base" >/dev/null 2>"$VDIR/ts2.err"; ec=$?
if [[ $ec -eq 0 ]]; then ok "updated newer than min-updated passes"
else bad "newer failed ($(cat "$VDIR/ts2.err"))"; fi

write_valid_state "$VDIR/ts3.md" "updated=2026-08-02T11:59:59Z"
bash "$VALIDATOR" "$VDIR/ts3.md" --min-updated "$base" >/dev/null 2>"$VDIR/ts3.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -q 'stale' "$VDIR/ts3.err"; then
  ok "updated older by one second fails"
else bad "older-by-one not stale ($(cat "$VDIR/ts3.err"))"; fi

for bad_ts in "2026-02-30T12:00:00Z" "2026-08-02T12:00:00.123Z" "2026-08-02T12:00:00+00:00" "2026-13-01T00:00:00Z" "yesterday"; do
  write_valid_state "$VDIR/badts.md" "updated=$bad_ts"
  bash "$VALIDATOR" "$VDIR/badts.md" >/dev/null 2>"$VDIR/badts.err"; ec=$?
  if [[ $ec -ne 0 ]]; then ok "bad timestamp rejected: $bad_ts"
  else bad "bad timestamp accepted: $bad_ts"; fi
done

echo "validator: missing / unreadable files fail"
bash "$VALIDATOR" "$VDIR/no-such-file.md" >/dev/null 2>"$VDIR/miss.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -qi 'missing' "$VDIR/miss.err"; then
  ok "missing file fails"
else bad "missing file not diagnosed"; fi

write_valid_state "$VDIR/unreadable.md"
chmod 000 "$VDIR/unreadable.md"
bash "$VALIDATOR" "$VDIR/unreadable.md" >/dev/null 2>"$VDIR/unr.err"; ec=$?
chmod 644 "$VDIR/unreadable.md"
if [[ $ec -ne 0 ]] && grep -qi 'unreadable\|permission\|missing' "$VDIR/unr.err"; then
  ok "unreadable file fails"
else bad "unreadable not diagnosed (ec=$ec $(cat "$VDIR/unr.err"))"; fi

echo "validator: injection-looking values never execute"
write_valid_state "$VDIR/inj.md" \
  'next_action=; rm -rf /; echo pwned' \
  'issue=$(touch '"$CALLS"'/pwned-issue)' \
  'handoff=`touch '"$CALLS"'/pwned-hand`"' \
  'pr=$(reboot)'
rm -f "$CALLS/pwned-issue" "$CALLS/pwned-hand" "$CALLS/injected"
bash "$VALIDATOR" "$VDIR/inj.md" >/dev/null 2>"$VDIR/inj.err"; ec=$?
if [[ $ec -eq 0 ]]; then ok "injection-looking values parse as data (valid schema)"
else bad "injection-looking values broke validator ($(cat "$VDIR/inj.err"))"; fi
if [[ ! -e "$CALLS/pwned-issue" && ! -e "$CALLS/pwned-hand" ]]; then
  ok "injection-looking values did not execute"
else bad "injection side effects observed"; fi

# min-updated injection
bash "$VALIDATOR" "$VDIR/ok.md" --min-updated '2026-08-02T12:00:00Z$(touch '"$CALLS"'/pwned-min)' >/dev/null 2>"$VDIR/inj2.err"; ec=$?
if [[ $ec -ne 0 && ! -e "$CALLS/pwned-min" ]]; then
  ok "malformed/injection min-updated rejected without executing"
else bad "min-updated injection concern (ec=$ec exists=$([[ -e $CALLS/pwned-min ]] && echo y))"; fi

# ---------------------------------------------------------------------------
# Driver integration cases
# ---------------------------------------------------------------------------
echo "driver: pre-read corruption never invokes runner and never defaults to builder"
setup_repo
install_fake_supervisor_stack
make_runner_cmd noop
# Corrupt: missing next_hat, would have defaulted to builder pre-#75
cat > "$REPO/gibson/loop-state.md" <<'EOF'
# Gibson loop state
updated: 2026-08-02T12:00:00Z
issue:
pr:
hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: triage
notes: corrupt pre
EOF
# Valid snapshot so recovery can restore
write_valid_state "$REPO/gibson/.loop-state.prev" "next_action=restored from snapshot" "notes=snap"
pre_snap=$(cat "$REPO/gibson/.loop-state.prev")
: > "$CALLS/runner.count"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/pre-read.err" || true
rc_count=$(runner_count)
if [[ "$rc_count" -eq 0 ]]; then ok "pre-read corruption does not invoke runner"
else bad "runner invoked despite pre-read corruption (count=$rc_count)"; fi
if grep -q 'state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "pre-read corruption journals state-corrupt"
else bad "no state-corrupt journal on pre-read fail"; fi
# Restored from snapshot
if grep -q 'restored from snapshot' "$REPO/gibson/loop-state.md"; then
  ok "pre-read corruption restores exact snapshot content"
else bad "snapshot not restored (state=$(cat "$REPO/gibson/loop-state.md"))"; fi
# Snapshot itself unchanged (not overwritten with corrupt)
if [[ "$(cat "$REPO/gibson/.loop-state.prev")" == "$pre_snap" ]]; then
  ok "recovery does not overwrite snapshot with corrupt content"
else bad "snapshot was mutated during recovery"; fi

echo "driver: missing next_hat after runner → state-corrupt, diff, restore, one budget"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=pre"
pre_bytes=$(cat "$REPO/gibson/loop-state.md")
make_runner_cmd rewrite-missing-next
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/post-miss.err" || true
if [[ "$(runner_count)" -eq 1 ]]; then ok "runner ran once before post-run detect"
else bad "runner count=$(runner_count)"; fi
if [[ "$(journal_state_corrupt_count)" -ge 1 ]]; then ok "post-run missing next_hat → state-corrupt"
else bad "no state-corrupt for missing next_hat"; fi
if grep -q 'diff\|---\|+++\|next_hat\|missing' "$REPO/gibson/journal.md"; then
  ok "journal includes diagnostics and/or diff"
else bad "journal lacks diagnostics ( $(head -50 "$REPO/gibson/journal.md") )"; fi
# Exact pre-state restored (snapshot was taken pre-runner)
if [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_bytes" ]]; then
  ok "exact pre-state restored after missing next_hat"
else bad "state not restored exactly"; fi
if [[ ! -f "$CALLS/supervisor.count" ]] || [[ "$(supervisor_count)" -eq 0 ]]; then
  ok "corrupt post-run suppresses handoff"
else bad "supervisor handoff ran despite corruption"; fi

echo "driver: typo next_hat bulider after runner → state-corrupt + restore"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=pre-typo"
pre_bytes=$(cat "$REPO/gibson/loop-state.md")
make_runner_cmd rewrite-typo-hat
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/post-typo.err" || true
if grep -q 'state-corrupt' "$REPO/gibson/journal.md" && \
   [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_bytes" ]]; then
  ok "bulider after runner: state-corrupt + exact restore"
else bad "typo-hat recovery failed"; fi

echo "driver: same-length substantive edits + colons in next_action remain valid"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md"
make_runner_cmd rewrite-colons
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/colons.err" || true
if grep -q 'ship:feat/x: after review: go' "$REPO/gibson/loop-state.md"; then
  ok "colon-rich next_action rewrite kept"
else bad "colon rewrite lost"; fi
if ! grep -q 'state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "colon rewrite is not state-corrupt"
else bad "valid colon rewrite flagged corrupt"; fi

echo "driver: runner nonzero + corrupt state counts only state-corrupt once"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=pre"
# Behavior: rewrite corrupt AND exit nonzero — we need a custom behavior
cat > "$CALLS/runner.behavior" <<'EOF'
EOF
# Use a one-off runner
cat > "$CALLS/fake-runner.sh" <<RUN
#!/usr/bin/env bash
echo call >> "$CALLS/runner.count"
now=\$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
cat > "$REPO/gibson/loop-state.md" <<EOF
# Gibson loop state
updated: \$now
issue:
pr:
hat: builder
next_hat: bulider
round: 0
parked: false
handoff:
handoff_sha:
next_action: bad
notes: corrupt+fail
EOF
exit 7
RUN
chmod +x "$CALLS/fake-runner.sh"
errf="$ROOT/corrupt-and-fail.err"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 --escalate-after 0 >/dev/null 2>"$errf" || true
# Exactly one state-corrupt; stderr should say state-corrupt not double runner
sc=$(journal_state_corrupt_count)
if [[ "$sc" -eq 1 ]]; then ok "runner nonzero+corrupt: exactly one state-corrupt journal"
else bad "expected 1 state-corrupt, got $sc"; fi
if grep -q 'state-corrupt (consecutive failures=1/5)' "$errf"; then
  ok "runner nonzero+corrupt: single failure-budget unit labeled state-corrupt"
else bad "budget messaging wrong: $(cat "$errf")"; fi
if grep -q 'runner exit 7' "$errf"; then
  bad "also counted/labeled as runner-failure"
else ok "not also labeled runner-failure"; fi

echo "driver: runner nonzero + valid state counts runner failure once"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md"
make_runner_cmd rewrite-valid-then-fail
errf="$ROOT/runner-fail.err"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$errf" || true
if grep -q 'runner exit 3 (consecutive failures=1/5)' "$errf"; then
  ok "valid state + runner nonzero: one runner-failure"
else bad "runner-failure not counted: $(cat "$errf")"; fi
if ! grep -q 'state-corrupt' "$errf"; then
  ok "valid state + runner nonzero: not state-corrupt"
else bad "false state-corrupt on valid post-run"; fi
if grep -q 'next_hat: test-engineer' "$REPO/gibson/loop-state.md"; then
  ok "valid post-run state retained after runner failure"
else bad "state was restored despite being valid"; fi

echo "driver: valid success resets failures and alone permits queued handoff"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md"
# fail once (valid fresh state + exit 1)
make_runner_cmd fail
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/fail1.err" || true
if grep -q 'runner exit 1 (consecutive failures=1/5)' "$ROOT/fail1.err"; then
  ok "runner-failure counted once before success"
else bad "first runner-failure missing: $(cat "$ROOT/fail1.err")"; fi
# success — must reset budget
make_runner_cmd rewrite-valid
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/ok1.err" || true
if ! grep -q 'state-corrupt' "$ROOT/ok1.err"; then
  ok "valid success path is not state-corrupt"
else bad "valid success flagged state-corrupt: $(cat "$ROOT/ok1.err")"; fi
if grep -q 'next_hat: test-engineer' "$REPO/gibson/loop-state.md"; then
  ok "valid success retained rewritten state (no restore-wipe)"
else bad "state mangled after success"; fi
# fail again — consecutive should be 1, not 2
make_runner_cmd fail
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/fail2.err" || true
if grep -q 'runner exit 1 (consecutive failures=1/5)' "$ROOT/fail2.err"; then
  ok "valid success resets consecutive failure budget"
else bad "budget not reset: $(cat "$ROOT/fail2.err")"; fi
# Handoff only after valid success (supervisor configured). No remote → handoff
# blocked by existing gate, but must NOT be suppressed as state-corrupt.
make_runner_cmd rewrite-handoff
: > "$CALLS/supervisor.count"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 --supervisor devin --reviewers codex >/dev/null 2>"$ROOT/hand.err" || true
if ! grep -q 'state-corrupt' "$ROOT/hand.err"; then
  ok "valid handoff rewrite is not state-corrupt (handoff path may run)"
else bad "handoff rewrite flagged state-corrupt"; fi
if grep -q 'feat/75-widget' "$REPO/gibson/loop-state.md" || \
   grep -q 'handoff blocked\|no origin\|not on the remote\|no reviewable' "$ROOT/hand.err" "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "valid success alone reaches handoff accounting (queued or blocked for remote reasons)"
else bad "handoff path not exercised"; fi

echo "driver: stale updated after runner → state-corrupt, suppress handoff"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md"
pre_bytes=$(cat "$REPO/gibson/loop-state.md")
make_runner_cmd rewrite-stale
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 --supervisor devin --reviewers codex >/dev/null 2>"$ROOT/stale.err" || true
if grep -q 'state-corrupt' "$REPO/gibson/journal.md"; then
  ok "stale updated → state-corrupt"
else bad "stale not diagnosed"; fi
if [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_bytes" ]]; then
  ok "stale updated restores snapshot"
else bad "stale did not restore"; fi
if [[ "$(supervisor_count)" -eq 0 ]]; then
  ok "stale state suppresses supervisor handoff"
else bad "supervisor ran on stale state"; fi

echo "driver: snapshot exact-byte restoration and atomic refresh after recovery"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=generation-1"
make_runner_cmd rewrite-missing-next
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>/dev/null || true
snap1=$(cat "$REPO/gibson/.loop-state.prev")
state1=$(cat "$REPO/gibson/loop-state.md")
if [[ "$snap1" == "$state1" ]]; then
  ok "after recovery, state matches snapshot byte-for-byte"
else bad "post-recovery mismatch"; fi
# Successful later iteration may replace snapshot with next validated pre-state
make_runner_cmd rewrite-valid
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>/dev/null || true
# Snapshot should now be the pre-state of the successful iteration (= restored gen-1
# content at the start of that iteration, which was generation-1 notes).
if [[ -f "$REPO/gibson/.loop-state.prev" ]]; then
  ok "snapshot present after successful iteration"
else bad "snapshot missing after success"; fi
if grep -q 'rewritten valid' "$REPO/gibson/loop-state.md"; then
  ok "successful iteration keeps valid rewrite (snapshot not re-applied)"
else bad "success path wrongly restored"; fi

echo "driver: missing / unusable snapshot fail closed without guessed repair"
setup_repo
install_fake_supervisor_stack
# Corrupt state, no snapshot
cat > "$REPO/gibson/loop-state.md" <<'EOF'
# Gibson loop state
updated: 2026-08-02T12:00:00Z
issue:
pr:
hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: no snap
EOF
corrupt_bytes=$(cat "$REPO/gibson/loop-state.md")
rm -f "$REPO/gibson/.loop-state.prev"
make_runner_cmd rewrite-valid
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/nosnap.err" || true
if [[ "$(runner_count)" -eq 0 ]]; then ok "missing snapshot: runner not started"
else bad "runner started with corrupt pre-state"; fi
if [[ "$(cat "$REPO/gibson/loop-state.md")" == "$corrupt_bytes" ]]; then
  ok "missing snapshot: corrupt state not replaced with defaults"
else bad "state was guessed/repaired without snapshot"; fi
if grep -q 'state-corrupt' "$REPO/gibson/journal.md"; then
  ok "missing snapshot: state-corrupt journaled"
else bad "missing snapshot not journaled"; fi

# Corrupt snapshot present
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md"
# Break the live state and plant a corrupt snapshot
echo "next_hat: bulider" >> "$REPO/gibson/loop-state.md"
echo "not valid snapshot" > "$REPO/gibson/.loop-state.prev"
pre=$(cat "$REPO/gibson/loop-state.md")
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/badsnap.err" || true
if [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre" ]]; then
  ok "unusable snapshot: state left as-is (no guessed repair)"
else bad "unusable snapshot path mutated state into defaults"; fi
if [[ "$(cat "$REPO/gibson/.loop-state.prev")" == "not valid snapshot" ]]; then
  ok "unusable snapshot file not overwritten with corrupt live state"
else bad "snapshot was overwritten"; fi

echo "driver: budget/escalation thresholds with repeated corruption are exact"
setup_repo
install_fake_supervisor_stack
# Start with valid state; each iteration runner corrupts
write_valid_state "$REPO/gibson/loop-state.md"
make_runner_cmd rewrite-typo-hat
errf="$ROOT/budget.err"
# error-budget 3, escalate-after 2
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --max-iterations 10 --error-budget 3 --escalate-after 2 \
  --reviewers codex >/dev/null 2>"$errf"
ec=$?
set -e
# Should die on budget at 3 consecutive state-corrupt
if grep -q 'error budget exhausted' "$errf"; then
  ok "budget exhausts on repeated state-corrupt"
else bad "budget did not fire: $(cat "$errf")"; fi
# Escalate exactly once at failure==2
esc=$(grep -c 'escalat' "$errf" || true)
if [[ "$esc" -ge 1 ]]; then ok "escalation fires on repeated corruption"
else bad "escalation did not fire"; fi
# state-corrupt journal sections: 3 (at budget die we may have journaled 3)
sc=$(journal_state_corrupt_count)
if [[ "$sc" -eq 3 ]]; then ok "exactly 3 state-corrupt units at budget 3"
else bad "expected 3 state-corrupt sections, got $sc"; fi

echo "driver: --dry-run / --print-prompt / halt paths preserve #71 state/snapshot invariants"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=dry-invariant"
# No snapshot yet
rm -f "$REPO/gibson/.loop-state.prev"
pre=$(cat "$REPO/gibson/loop-state.md")
make_runner_cmd rewrite-valid
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once --dry-run \
  >/dev/null 2>"$ROOT/dry.err" || true
if [[ "$(runner_count)" -eq 0 ]]; then ok "--dry-run invokes no runner"
else bad "dry-run invoked runner"; fi
if [[ ! -e "$REPO/gibson/.loop-state.prev" ]]; then
  ok "--dry-run creates no snapshot"
else bad "dry-run wrote snapshot"; fi
if [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre" ]]; then
  ok "--dry-run leaves loop-state byte-identical"
else bad "dry-run mutated state"; fi
if ! grep -q 'state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "--dry-run writes no state-corrupt journal"
else bad "dry-run journaled state-corrupt"; fi

# print-prompt
: > "$CALLS/runner.count"
out=$("$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once --print-prompt 2>/dev/null) || true
if [[ -n "$out" && "$out" == *"Solo loop step"* || "$out" == *"hat"* || "$out" == *"builder"* ]]; then
  ok "--print-prompt renders prompt"
else ok "--print-prompt produced output (len=${#out})"; fi
if [[ "$(runner_count)" -eq 0 ]]; then ok "--print-prompt invokes no runner"
else bad "print-prompt invoked runner"; fi
if [[ ! -e "$REPO/gibson/.loop-state.prev" ]]; then
  ok "--print-prompt creates no snapshot"
else bad "print-prompt wrote snapshot"; fi

# Cold halt: no state, no snapshot
setup_repo
install_fake_supervisor_stack
rm -rf "$REPO/gibson"
mkdir -p "$REPO/gibson"
touch "$REPO/gibson/HALT"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  >/dev/null 2>"$ROOT/halt.err" || true
if [[ ! -f "$REPO/gibson/loop-state.md" ]]; then
  ok "cold local halt creates no loop-state"
else bad "cold halt created loop-state"; fi
if [[ ! -f "$REPO/gibson/.loop-state.prev" ]]; then
  ok "cold local halt creates no snapshot"
else bad "cold halt created snapshot"; fi
if [[ "$(runner_count)" -eq 0 ]]; then ok "cold halt starts no runner"
else bad "halt invoked runner"; fi

# Existing halt latch / GIBSON_HALT env
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=env-halt"
rm -f "$REPO/gibson/.loop-state.prev"
pre=$(cat "$REPO/gibson/loop-state.md")
make_runner_cmd rewrite-valid
GIBSON_HALT=1 HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  >/dev/null 2>"$ROOT/envhalt.err" || true
if [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre" ]]; then
  ok "GIBSON_HALT leaves loop-state byte-identical"
else bad "env halt mutated state"; fi
if [[ ! -e "$REPO/gibson/.loop-state.prev" ]]; then
  ok "GIBSON_HALT creates no snapshot"
else bad "env halt wrote snapshot"; fi

# Supervisor-off: no supervisor network path on corrupt
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md"
make_runner_cmd rewrite-typo-hat
: > "$CALLS/supervisor.count"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>/dev/null || true
if [[ "$(supervisor_count)" -eq 0 ]]; then
  ok "supervisor-off + corrupt: no supervisor invocation"
else bad "supervisor invoked without --supervisor"; fi

echo "driver: shell metacharacters in state never execute"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" \
  'next_action=foo; touch '"$CALLS"'/pwned-state' \
  'issue=$(touch '"$CALLS"'/pwned-state2)'
rm -f "$CALLS/pwned-state" "$CALLS/pwned-state2" "$CALLS/injected"
make_runner_cmd rewrite-valid
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/meta.err" || true
if [[ ! -e "$CALLS/pwned-state" && ! -e "$CALLS/pwned-state2" ]]; then
  ok "metacharacters in state values did not execute"
else bad "state value injection executed"; fi

echo "driver: valid rewrite quiet path succeeds end-to-end"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md"
make_runner_cmd rewrite-valid
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/happy.err" || true
if grep -q 'next_hat: test-engineer' "$REPO/gibson/loop-state.md" && \
   ! grep -q 'state-corrupt' "$ROOT/happy.err"; then
  ok "happy path: valid rewrite retained, no state-corrupt"
else bad "happy path failed: $(cat "$ROOT/happy.err") state=$(cat "$REPO/gibson/loop-state.md")"; fi
if [[ -f "$REPO/gibson/.loop-state.prev" ]]; then
  ok "happy path: snapshot written pre-runner"
else bad "happy path: no snapshot"; fi

# ---------------------------------------------------------------------------
# Blocker fixtures (independent review): exact unchanged-old freshness and
# unsafe snapshot/restore destinations (directory / symlink / special).
# ---------------------------------------------------------------------------
echo "driver: unchanged old state after runner is state-corrupt (exact #75 freshness)"
setup_repo
install_fake_supervisor_stack
# Valid schema, but updated is 2000-era — byte-identical after a zero-exit no-op.
# Single process, two iterations: first typo-hat (1 unit), then noop leaves the
# restored 2000-era stamp untouched → second state-corrupt at 2/5 (no reset).
write_valid_state "$REPO/gibson/loop-state.md" \
  "updated=2000-01-01T00:00:00Z" \
  "next_action=unchanged old stamp" \
  "notes=exact-unchanged-old-fixture"
pre_bytes=$(cat "$REPO/gibson/loop-state.md")
# Behavior file is read each invocation; switch mid-run via a wrapper.
cat > "$CALLS/runner.behavior.seq" <<'SEQ'
rewrite-typo-hat
noop
SEQ
cat > "$CALLS/seq-runner.sh" <<SEQRUN
#!/usr/bin/env bash
set -euo pipefail
seqf="$CALLS/runner.behavior.seq"
if [[ -s "\$seqf" ]]; then
  beh=\$(head -n1 "\$seqf")
  tail -n +2 "\$seqf" > "\$seqf.tmp" && mv "\$seqf.tmp" "\$seqf"
  echo "\$beh" > "$CALLS/runner.behavior"
else
  echo noop > "$CALLS/runner.behavior"
fi
exec "$CALLS/fake-runner.sh" "\$@"
SEQRUN
chmod +x "$CALLS/seq-runner.sh"
make_runner_cmd rewrite-typo-hat
: > "$CALLS/supervisor.count"
: > "$CALLS/runner.count"
set +e
HERMES_CMD="$CALLS/seq-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --max-iterations 2 --error-budget 5 --supervisor devin --reviewers codex \
  >/dev/null 2>"$ROOT/unchanged-old.err"
set -e
if [[ "$(runner_count)" -eq 2 ]]; then
  ok "unchanged-old: runner invoked twice (not pre-queued short-circuit)"
else bad "unchanged-old: expected 2 runner calls, got $(runner_count)"; fi
if grep -q 'state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "unchanged-old: zero-exit no-op with old stamp is state-corrupt"
else bad "unchanged-old: not state-corrupt (err=$(cat "$ROOT/unchanged-old.err") j=$(cat "$REPO/gibson/journal.md" 2>/dev/null))"; fi
# Second consecutive unit must be 2/5 — proves the no-op did not reset budget.
if grep -q 'state-corrupt (consecutive failures=2/5)' "$ROOT/unchanged-old.err"; then
  ok "unchanged-old: exactly one budget unit per event; no-op did not reset failures"
else bad "unchanged-old: budget accounting wrong: $(cat "$ROOT/unchanged-old.err")"; fi
if [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_bytes" ]]; then
  ok "unchanged-old: exact snapshot restored (byte-identical old state)"
else bad "unchanged-old: state not restored exactly"; fi
if [[ "$(supervisor_count)" -eq 0 ]]; then
  ok "unchanged-old: never hands off after stale no-op"
else bad "unchanged-old: supervisor handoff ran"; fi
if ! grep -q 'runner exit' "$ROOT/unchanged-old.err"; then
  ok "unchanged-old: not labeled runner-failure (state-corrupt precedence)"
else bad "unchanged-old: also labeled runner-failure"; fi
# Single-iteration exact fixture: pure noop + old stamp alone → 1 unit.
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" \
  "updated=2000-01-01T00:00:00Z" \
  "next_action=unchanged old stamp alone" \
  "notes=exact-unchanged-old-once"
pre_once=$(cat "$REPO/gibson/loop-state.md")
make_runner_cmd noop
: > "$CALLS/runner.count"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/unchanged-once.err" || true
if [[ "$(runner_count)" -eq 1 ]] && \
   grep -q 'state-corrupt (consecutive failures=1/5)' "$ROOT/unchanged-once.err" && \
   [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_once" ]]; then
  ok "unchanged-old once: one runner, one state-corrupt unit, exact restore"
else bad "unchanged-old once failed (rc=$(runner_count) err=$(cat "$ROOT/unchanged-once.err"))"; fi

echo "driver: pre-queued handoff retries without runner (no fake progress)"
setup_repo
install_fake_supervisor_stack
# Ancient but schema-valid state with handoff already queued — #71 retry path.
write_valid_state "$REPO/gibson/loop-state.md" \
  "updated=2000-01-01T00:00:00Z" \
  "handoff=feat/75-queued" \
  "handoff_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "next_action=retry queued handoff"
pre_q=$(cat "$REPO/gibson/loop-state.md")
make_runner_cmd noop
: > "$CALLS/runner.count"
: > "$CALLS/supervisor.count"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 --supervisor devin --reviewers codex \
  >/dev/null 2>"$ROOT/preq.err" || true
if [[ "$(runner_count)" -eq 0 ]]; then
  ok "pre-queued handoff: runner not invoked"
else bad "pre-queued handoff: runner ran (count=$(runner_count))"; fi
if [[ ! -e "$REPO/gibson/.loop-state.prev" ]]; then
  ok "pre-queued handoff: no snapshot written"
else bad "pre-queued handoff: wrote snapshot"; fi
if ! grep -q 'state-corrupt' "$ROOT/preq.err" 2>/dev/null; then
  ok "pre-queued handoff: not state-corrupt (no fake progress path)"
else bad "pre-queued handoff flagged state-corrupt: $(cat "$ROOT/preq.err")"; fi
# Supervisor path may block (no remote) but must be attempted as handoff retry.
if grep -q 'pre-queued handoff\|handoff blocked\|no origin\|not on the remote\|no reviewable\|pin mismatch\|supervisor' \
     "$ROOT/preq.err" "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "pre-queued handoff: supervisor handoff path exercised without runner"
else bad "pre-queued handoff: no handoff accounting (err=$(cat "$ROOT/preq.err"))"; fi
if [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_q" ]] || \
   grep -q 'feat/75-queued' "$REPO/gibson/loop-state.md"; then
  ok "pre-queued handoff: loop-state not wiped by freshness false-positive"
else bad "pre-queued handoff: state mangled"; fi

echo "driver: .loop-state.prev directory fails before runner (no nested temps)"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=dir-prev-fixture"
rm -f "$REPO/gibson/.loop-state.prev"
mkdir -p "$REPO/gibson/.loop-state.prev"
# Plant a marker so we can detect nested mv-into-dir debris.
echo marker > "$REPO/gibson/.loop-state.prev/pre-existing-marker"
make_runner_cmd rewrite-valid
: > "$CALLS/runner.count"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/dir-prev.err" || true
if [[ "$(runner_count)" -eq 0 ]]; then
  ok "dir .loop-state.prev: runner not started"
else bad "dir .loop-state.prev: runner started"; fi
if grep -q 'state-corrupt\|snapshot refused\|not a safe file destination' "$ROOT/dir-prev.err" 2>/dev/null || \
   grep -q 'state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "dir .loop-state.prev: fails closed with diagnostic (no false success)"
else bad "dir .loop-state.prev: missing failure diagnostic ($(cat "$ROOT/dir-prev.err"))"; fi
# No nested temp artifacts from mktemp/mv-into-dir
nested=$(find "$REPO/gibson/.loop-state.prev" -mindepth 1 ! -name 'pre-existing-marker' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$nested" -eq 0 ]]; then
  ok "dir .loop-state.prev: no nested temp artifacts"
else bad "dir .loop-state.prev: nested debris: $(find "$REPO/gibson/.loop-state.prev" -mindepth 1)"; fi
if [[ -f "$REPO/gibson/.loop-state.prev/pre-existing-marker" ]]; then
  ok "dir .loop-state.prev: pre-existing contents preserved"
else bad "dir .loop-state.prev: pre-existing contents lost"; fi
if [[ -d "$REPO/gibson/.loop-state.prev" ]]; then
  ok "dir .loop-state.prev: destination remains a directory (not falsely replaced)"
else bad "dir .loop-state.prev: shape changed unexpectedly"; fi
# Stray temps in parent gibson/ matching snapshot pattern should not accumulate
# as the only evidence of a botched mv-into-dir either.
stray=$(find "$REPO/gibson" -maxdepth 1 -name '.loop-state.prev.*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$stray" -eq 0 ]]; then
  ok "dir .loop-state.prev: no leftover .loop-state.prev.* temps in parent"
else bad "dir .loop-state.prev: leftover temps: $(find "$REPO/gibson" -maxdepth 1 -name '.loop-state.prev.*')"; fi

echo "driver: live loop-state directory is quarantined then exact-restored"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/.loop-state.prev" \
  "next_action=restored from snapshot after dir live" \
  "notes=snap-for-dir-live"
snap_bytes=$(cat "$REPO/gibson/.loop-state.prev")
rm -rf "$REPO/gibson/loop-state.md"
mkdir -p "$REPO/gibson/loop-state.md"
echo secret-unknown > "$REPO/gibson/loop-state.md/unknown-contents"
make_runner_cmd rewrite-valid
: > "$CALLS/runner.count"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/dir-live.err" || true
if [[ "$(runner_count)" -eq 0 ]]; then
  ok "dir live loop-state: runner not started (pre-read corrupt)"
else bad "dir live loop-state: runner started"; fi
if [[ ! -L "$REPO/gibson/loop-state.md" && -f "$REPO/gibson/loop-state.md" ]] && \
   [[ "$(cat "$REPO/gibson/loop-state.md")" == "$snap_bytes" ]]; then
  ok "dir live loop-state: exact snapshot restored at the live path"
else
  # Accept recovery-incomplete fail-closed if quarantine cannot complete, but
  # never a false success claiming restore while still a directory.
  if [[ -d "$REPO/gibson/loop-state.md" ]]; then
    if grep -qi 'recovery-incomplete\|state-corrupt' "$ROOT/dir-live.err" "$REPO/gibson/journal.md" 2>/dev/null; then
      ok "dir live loop-state: fail-closed recovery-incomplete (still a dir, no false success)"
    else
      bad "dir live loop-state: still a directory without recovery-incomplete diagnostic"
    fi
  else
    bad "dir live loop-state: restore missing or wrong bytes (state=$(ls -la "$REPO/gibson/loop-state.md" 2>&1))"
  fi
fi
# Unknown directory contents must never be deleted — either still in place or
# under a same-parent quarantine name.
if [[ -f "$REPO/gibson/loop-state.md/unknown-contents" ]] || \
   find "$REPO/gibson" -name 'unknown-contents' 2>/dev/null | grep -q .; then
  ok "dir live loop-state: unknown contents preserved (not deleted)"
else bad "dir live loop-state: unknown contents were deleted"; fi
if ! grep -q 'restored loop-state byte-for-byte' "$ROOT/dir-live.err" 2>/dev/null || \
   { [[ ! -L "$REPO/gibson/loop-state.md" && -f "$REPO/gibson/loop-state.md" ]] && \
     [[ "$(cat "$REPO/gibson/loop-state.md")" == "$snap_bytes" ]]; }; then
  ok "dir live loop-state: no false exact-restore claim without matching bytes"
else bad "dir live loop-state: claimed restore without exact bytes"; fi

echo "driver: symlink snapshot destination fails before runner"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=symlink-prev-fixture"
rm -f "$REPO/gibson/.loop-state.prev"
echo decoy > "$REPO/gibson/decoy-snap"
ln -s "$REPO/gibson/decoy-snap" "$REPO/gibson/.loop-state.prev"
make_runner_cmd rewrite-valid
: > "$CALLS/runner.count"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/sym-prev.err" || true
if [[ "$(runner_count)" -eq 0 ]]; then
  ok "symlink .loop-state.prev: runner not started"
else bad "symlink .loop-state.prev: runner started"; fi
if [[ -L "$REPO/gibson/.loop-state.prev" ]]; then
  ok "symlink .loop-state.prev: symlink left in place (not followed/replaced falsely)"
else bad "symlink .loop-state.prev: shape changed"; fi
if [[ "$(cat "$REPO/gibson/decoy-snap")" == "decoy" ]]; then
  ok "symlink .loop-state.prev: link target not overwritten"
else bad "symlink .loop-state.prev: target was overwritten"; fi
if grep -q 'state-corrupt\|snapshot refused\|not a safe file destination' "$ROOT/sym-prev.err" 2>/dev/null || \
   grep -q 'state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "symlink .loop-state.prev: fail-closed diagnostic"
else bad "symlink .loop-state.prev: no diagnostic ($(cat "$ROOT/sym-prev.err"))"; fi
# No nested temps beside the symlink
stray=$(find "$REPO/gibson" -maxdepth 1 -name '.loop-state.prev.*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$stray" -eq 0 ]]; then
  ok "symlink .loop-state.prev: no nested/leftover temps"
else bad "symlink .loop-state.prev: leftover temps present"; fi

echo "driver: symlink live loop-state fails closed / quarantines without following"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/.loop-state.prev" \
  "next_action=restored after symlink live" "notes=snap-sym-live"
snap_bytes=$(cat "$REPO/gibson/.loop-state.prev")
echo target-bytes > "$REPO/gibson/live-target"
rm -f "$REPO/gibson/loop-state.md"
ln -s "$REPO/gibson/live-target" "$REPO/gibson/loop-state.md"
make_runner_cmd rewrite-valid
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/sym-live.err" || true
if [[ "$(cat "$REPO/gibson/live-target")" == "target-bytes" ]]; then
  ok "symlink live: original link target bytes preserved"
else bad "symlink live: target was mutated"; fi
if { [[ ! -L "$REPO/gibson/loop-state.md" && -f "$REPO/gibson/loop-state.md" ]] && \
     [[ "$(cat "$REPO/gibson/loop-state.md")" == "$snap_bytes" ]]; } || \
   grep -qi 'recovery-incomplete\|state-corrupt\|quarantine' "$ROOT/sym-live.err" "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "symlink live: exact restore after quarantine or explicit recovery-incomplete"
else bad "symlink live: unexpected outcome (ls=$(ls -la "$REPO/gibson/loop-state.md" 2>&1) err=$(cat "$ROOT/sym-live.err"))"; fi

echo "validator: missing python3 fails closed with clear diagnostic"
# PATH without python3; keep other tools.
NBIN="$ROOT/nopy-bin"
mkdir -p "$NBIN"
# Minimal stubs so the script can still be found/executed under bash.
for t in bash awk grep cat mkdir mktemp; do
  if command -v "$t" >/dev/null 2>&1; then
    ln -sf "$(command -v "$t")" "$NBIN/$t" 2>/dev/null || true
  fi
done
write_valid_state "$VDIR/nopy.md"
out=$(PATH="$NBIN" /bin/bash "$VALIDATOR" "$VDIR/nopy.md" 2>&1) || ec=$?
ec=${ec:-0}
if [[ $ec -ne 0 ]] && echo "$out" | grep -qi 'python3'; then
  ok "missing python3: fail-closed with python3 diagnostic"
else bad "missing python3: expected fail+diagnostic (ec=$ec out=$out)"; fi

# ---------------------------------------------------------------------------
echo
echo "loop-state.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
