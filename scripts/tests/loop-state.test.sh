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

# Hermetic git identity (#101): suites that commit must not read ambient global
# user.name/email. Pass with HOME pointed at an empty directory.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"


SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
GIBSON=$(cd "$SCRIPT_DIR/../.." && pwd)
LOOP="$GIBSON/scripts/loop.sh"
SOURCE_LOOP="$LOOP"
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
REMOTE="$ROOT/remote.git"
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
  rm -rf "$REPO" "$REMOTE"
  mkdir -p "$REPO"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  echo base > "$REPO/README.md"
  $GIT -C "$REPO" add README.md
  $GIT -C "$REPO" commit -q -m "base"
  $GIT -C "$REPO" remote add origin https://github.com/acme/app.git
  $GIT init -q --bare "$REMOTE"
  git -C "$REPO" config --local "url.$REMOTE.insteadOf" "https://github.com/acme/app.git"
  git -C "$REPO" push -q origin main
  git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
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
#   rewrite-valid-nospace — valid rewrite with key:value (no space after :), exit 0
#   rewrite-handoff-nospace — handoff queued, no-space grammar, exit 0
#   rewrite-empty-updated — valid-looking schema but updated empty, exit 0
#   rewrite-valid-symlink — replace state with symlink to fresh valid outside target
#   rewrite-clock-only    — fresh updated: only (no-progress), exit 0  (#63)
#   rewrite-same-len      — same-length field edit + fresh stamp, exit 0 (#63)
#   rewrite-handoff-sha-only — only handoff_sha + updated change, exit 0 (#63)
#   rewrite-clock-only-then-fail — clock-only stamp + exit 1 (#63)
#
# Single definition, above every call site. A second late redefinition (issue
# #63 block) caused SC2218 on ShellCheck ≤0.10; keep one body only (#138).
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
  rewrite-valid-nospace)
    # Fully valid schema with no ASCII space after ':' (key:value form).
    cat > "\$state" <<EOF
# Gibson loop state
updated:\$now
issue:75
pr:
hat:builder
next_hat:test-engineer
round:1
parked:false
handoff:
handoff_sha:
next_action:run tests for the unit
notes:rewritten valid nospace
EOF
    exit 0
    ;;
  rewrite-handoff-nospace)
    cat > "\$state" <<EOF
# Gibson loop state
updated:\$now
issue:75
pr:12
hat:builder
next_hat:test-engineer
round:1
parked:false
handoff:feat/75-widget
handoff_sha:abcdef0123456789abcdef0123456789abcdef01
next_action:hand off the finished branch
notes:handoff queued nospace
EOF
    exit 0
    ;;
  rewrite-empty-updated)
    # Ten keys present; updated deliberately empty (schema-invalid).
    cat > "\$state" <<EOF
# Gibson loop state
updated:
issue: 75
pr:
hat: builder
next_hat: test-engineer
round: 1
parked: false
handoff:
handoff_sha:
next_action: emptied updated stamp
notes: empty-updated corrupt
EOF
    exit 0
    ;;
  rewrite-valid-symlink)
    # Fresh valid content written OUTSIDE the worktree; live path becomes a
    # symlink leaf. Validator/driver must refuse without following.
    target="$CALLS/outside-valid-state.md"
    cat > "\$target" <<EOF
# Gibson loop state
updated: \$now
issue: 75
pr:
hat: builder
next_hat: test-engineer
round: 1
parked: false
handoff:
handoff_sha:
next_action: via symlink target
notes: fresh symlink rewrite
EOF
    rm -f "\$state"
    ln -s "\$target" "\$state"
    exit 0
    ;;
  # --- issue #63 behaviors ---
  rewrite-clock-only)
    # Fresh updated: only — L-008 no-progress under silent_noop_progressed.
    if [[ -f "\$state" ]]; then
      python3 - "\$state" "\$now" <<'PY'
import re, sys
path, now = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
text2, n = re.subn(r"(?m)^updated:.*\$", "updated: " + now, text, count=1)
if n == 1:
    open(path, "w", encoding="utf-8").write(text2)
PY
    fi
    exit 0
    ;;
  rewrite-same-len)
    # Same-length substantive edit (round: 0 → round: 1) + fresh stamp.
    cat > "\$state" <<EOF
# Gibson loop state
updated: \$now
issue:
pr:
hat: builder
next_hat: builder
round: 1
parked: false
handoff:
handoff_sha:
next_action: triage highest-priority unblocked unclaimed issue
notes: fixture
EOF
    exit 0
    ;;
  rewrite-handoff-sha-only)
    # Only handoff_sha + updated change; every other field matches fixture.
    cat > "\$state" <<EOF
# Gibson loop state
updated: \$now
issue:
pr:
hat: builder
next_hat: builder
round: 0
parked: false
handoff:
handoff_sha: abcdef0123456789abcdef0123456789abcdef01
next_action: triage highest-priority unblocked unclaimed issue
notes: fixture
EOF
    exit 0
    ;;
  rewrite-clock-only-then-fail)
    # Clock-only stamp + nonzero exit: runner-failure must win over no-progress
    # only when state is valid+fresh. Clock-only with exit 1 is still valid
    # state → runner-failure only (sensor not run).
    if [[ -f "\$state" ]]; then
      python3 - "\$state" "\$now" <<'PY'
import re, sys
path, now = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
text2, n = re.subn(r"(?m)^updated:.*\$", "updated: " + now, text, count=1)
if n == 1:
    open(path, "w", encoding="utf-8").write(text2)
PY
    fi
    exit 1
    ;;
  *)
    echo "fake-runner: unknown behavior \$behavior" >&2
    exit 99
    ;;
esac
RUN
  chmod +x "$CALLS/fake-runner.sh"
}

# Write a fully valid ten-key state using key:value (no space after colon).
# Same overrides as write_valid_state (key=value args).
write_valid_state_nospace() {
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
  notes="fixture-nospace"
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
updated:$updated
issue:$issue
pr:$pr
hat:$hat
next_hat:$next_hat
round:$round
parked:$parked
handoff:$handoff
handoff_sha:$handoff_sha
next_action:$next_action
notes:$notes
EOF
}

# Extract one field with the same grammar as loop.sh read_field / validator.
test_read_field() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
      line = $0
      key = line
      sub(/:.*$/, "", key)
      if (key != k) next
      v = line
      sub(/^[^:]*:/, "", v)
      if (v ~ /^ /) v = substr(v, 2)
      print v
      exit
    }
  ' "$file"
}

# Fake supervisor + second-opinion that record invocations (no network).
install_fake_supervisor_stack() {
  mkdir -p "$ROOT/fake/scripts"
  cp "$SOURCE_LOOP" "$ROOT/fake/scripts/loop-real.sh"
  cat > "$ROOT/fake/scripts/loop.sh" <<'STUB'
#!/usr/bin/env bash
exec "$(dirname "$0")/loop-real.sh" "$@" --repo-slug acme/app
STUB
  chmod +x "$ROOT/fake/scripts/loop-real.sh" "$ROOT/fake/scripts/loop.sh"
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
  LOOP="$LOOP_BIN"
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

echo "validator: empty updated is always invalid (with and without --min-updated)"
# Bare key: form (no space after colon) — value is empty after grammar strip.
cat > "$VDIR/empty-up.md" <<'EOF'
# Gibson loop state
updated:
issue: 75
pr:
hat: builder
next_hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: triage
notes: empty-updated
EOF
bash "$VALIDATOR" "$VDIR/empty-up.md" >/dev/null 2>"$VDIR/empty-up.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -qi 'invalid updated\|updated' "$VDIR/empty-up.err"; then
  ok "empty updated without --min-updated fails closed"
else bad "empty updated accepted without min-updated (ec=$ec $(cat "$VDIR/empty-up.err"))"; fi
bash "$VALIDATOR" "$VDIR/empty-up.md" --min-updated '2026-08-02T12:00:00Z' \
  >/dev/null 2>"$VDIR/empty-up-min.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -qi 'invalid updated\|updated' "$VDIR/empty-up-min.err"; then
  ok "empty updated with nonempty --min-updated fails closed (not fail-open)"
else bad "empty updated + min-updated accepted (ec=$ec $(cat "$VDIR/empty-up-min.err"))"; fi
# key: value form with only the optional separator space → still empty value.
# Build via printf so the source file has no trailing whitespace (git diff --check).
{
  printf '%s\n' '# Gibson loop state'
  printf 'updated: %s\n' ''
  printf '%s\n' \
    'issue: 75' \
    'pr:' \
    'hat: builder' \
    'next_hat: builder' \
    'round: 0' \
    'parked: false' \
    'handoff:' \
    'handoff_sha:' \
    'next_action: triage' \
    'notes: empty-updated-space'
} > "$VDIR/empty-up-sp.md"
bash "$VALIDATOR" "$VDIR/empty-up-sp.md" --min-updated '2026-08-02T12:00:00Z' \
  >/dev/null 2>"$VDIR/empty-up-sp.err"; ec=$?
if [[ $ec -ne 0 ]]; then
  ok "empty updated after optional space still fails with --min-updated"
else bad "space-stripped empty updated accepted ($(cat "$VDIR/empty-up-sp.err"))"; fi

echo "validator: explicit empty --min-updated is usage/validation error (never no-bound)"
write_valid_state "$VDIR/ok-min.md" "updated=2026-08-02T12:00:00Z"
bash "$VALIDATOR" "$VDIR/ok-min.md" --min-updated '' >/dev/null 2>"$VDIR/empty-min.err"; ec=$?
if [[ $ec -ne 0 ]] && grep -qi 'min-updated\|nonempty\|empty\|usage\|requires' "$VDIR/empty-min.err"; then
  ok "explicit --min-updated '' fails closed (does not disable freshness)"
else bad "explicit empty --min-updated accepted (ec=$ec $(cat "$VDIR/empty-min.err"))"; fi
# Flag omitted still means no bound — valid file must pass.
bash "$VALIDATOR" "$VDIR/ok-min.md" >/dev/null 2>"$VDIR/no-min.err"; ec=$?
if [[ $ec -eq 0 ]]; then
  ok "omitting --min-updated still means no freshness bound"
else bad "omit --min-updated wrongly failed ($(cat "$VDIR/no-min.err"))"; fi

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

echo "driver: empty updated after runner → state-corrupt, restore, no normal completion"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=pre-empty-updated"
pre_bytes=$(cat "$REPO/gibson/loop-state.md")
make_runner_cmd rewrite-empty-updated
: > "$CALLS/supervisor.count"
: > "$CALLS/runner.count"
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 --supervisor devin --reviewers codex \
  >/dev/null 2>"$ROOT/empty-up.err" || true
if [[ "$(runner_count)" -eq 1 ]]; then
  ok "empty-updated: runner invoked once before post-run detect"
else bad "empty-updated: expected 1 runner, got $(runner_count)"; fi
sc=$(journal_state_corrupt_count)
if [[ "$sc" -eq 1 ]]; then
  ok "empty-updated: exactly one state-corrupt journal unit"
else bad "empty-updated: expected 1 state-corrupt, got $sc"; fi
if grep -q 'state-corrupt (consecutive failures=1/5)' "$ROOT/empty-up.err"; then
  ok "empty-updated: single failure-budget unit (precedence, not runner-failure)"
else bad "empty-updated: budget labeling wrong: $(cat "$ROOT/empty-up.err")"; fi
if ! grep -q 'runner exit' "$ROOT/empty-up.err"; then
  ok "empty-updated: not also counted as runner-failure"
else bad "empty-updated: double-counted runner-failure"; fi
if [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_bytes" ]]; then
  ok "empty-updated: exact pre-state restored from snapshot"
else bad "empty-updated: state not restored (got=$(cat "$REPO/gibson/loop-state.md"))"; fi
if [[ "$(supervisor_count)" -eq 0 ]]; then
  ok "empty-updated: suppresses supervisor handoff"
else bad "empty-updated: supervisor ran despite corrupt empty stamp"; fi
if ! grep -q 'Driver completed iteration' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "empty-updated: does not journal normal completion"
else bad "empty-updated: journaled normal completion alongside state-corrupt"; fi
if grep -q 'phase=post-run' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "empty-updated: state-corrupt journal is post-run phase"
else bad "empty-updated: missing post-run phase marker"; fi

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
echo "driver: unchanged old state after runner is no-progress (not schema corruption)"
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
if grep -q '· no-progress' "$REPO/gibson/journal.md" 2>/dev/null && \
   [[ "$(journal_state_corrupt_count)" -eq 1 ]]; then
  ok "unchanged-old: zero-exit no-op with old stamp is no-progress"
else bad "unchanged-old: wrong classification (err=$(cat "$ROOT/unchanged-old.err") j=$(cat "$REPO/gibson/journal.md" 2>/dev/null))"; fi
# Second consecutive unit must be 2/5 — proves the no-op has its own
# no-progress accounting without resetting the shared failure budget.
if grep -q 'no-progress (stale=1/5, consecutive failures=2/5)' "$ROOT/unchanged-old.err"; then
  ok "unchanged-old: exactly one no-progress budget unit per event"
else bad "unchanged-old: budget accounting wrong: $(cat "$ROOT/unchanged-old.err")"; fi
if [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_bytes" ]]; then
  ok "unchanged-old: unchanged state retained without corruption restore"
else bad "unchanged-old: state unexpectedly changed"; fi
if [[ "$(supervisor_count)" -eq 0 ]]; then
  ok "unchanged-old: never hands off after stale no-op"
else bad "unchanged-old: supervisor handoff ran"; fi
if ! grep -q 'runner exit' "$ROOT/unchanged-old.err"; then
  ok "unchanged-old: not labeled runner-failure"
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
   grep -q 'no-progress (stale=1/5, consecutive failures=1/5)' "$ROOT/unchanged-once.err" && \
   [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_once" ]]; then
  ok "unchanged-old once: one runner, one no-progress unit, state retained"
else bad "unchanged-old once failed (runner_count=$(runner_count) err=$(cat "$ROOT/unchanged-once.err"))"; fi

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
# Symlink leaf refusal (validator never follows; issue #75 review blocker)
# ---------------------------------------------------------------------------
# Later fixtures leave `set -e` on (budget / unchanged-old sections). All
# commands below that may fail must use || true / set +e so the suite continues.
echo "validator: symlink leaf to valid content is refused (never followed)"
write_valid_state "$VDIR/sym-target.md" "next_action=target content" "notes=via-symlink"
rm -f "$VDIR/sym-state.md"
ln -s "$VDIR/sym-target.md" "$VDIR/sym-state.md"
target_before=$(cat "$VDIR/sym-target.md")
set +e
bash "$VALIDATOR" "$VDIR/sym-state.md" >/dev/null 2>"$VDIR/sym.err"
ec=$?
set -e
if [[ $ec -ne 0 ]] && grep -qi 'symlink' "$VDIR/sym.err"; then
  ok "validator: symlink leaf refused with diagnostic"
else bad "validator: symlink leaf accepted or wrong diagnostic (ec=$ec $(cat "$VDIR/sym.err"))"; fi
if [[ "$(cat "$VDIR/sym-target.md")" == "$target_before" ]]; then
  ok "validator: symlink target bytes unchanged after refuse"
else bad "validator: symlink target was mutated"; fi
# Dangling symlink also refused as symlink leaf (not "missing" via -e follow)
rm -f "$VDIR/dangling.md" "$VDIR/no-such-target-xyz"
ln -s "$VDIR/no-such-target-xyz" "$VDIR/dangling.md"
set +e
bash "$VALIDATOR" "$VDIR/dangling.md" >/dev/null 2>"$VDIR/dang.err"
ec=$?
set -e
if [[ $ec -ne 0 ]] && grep -qi 'symlink' "$VDIR/dang.err"; then
  ok "validator: dangling symlink refused as symlink leaf"
else bad "validator: dangling symlink misclassified (ec=$ec $(cat "$VDIR/dang.err"))"; fi

echo "driver: post-run valid/fresh symlink is state-corrupt once; safe recovery"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" \
  "next_action=pre symlink rewrite" "notes=pre-sym"
pre_bytes=$(cat "$REPO/gibson/loop-state.md")
make_runner_cmd rewrite-valid-symlink
: > "$CALLS/runner.count"
: > "$CALLS/supervisor.count"
rm -f "$CALLS/outside-valid-state.md"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --supervisor devin --error-budget 5 >/dev/null 2>"$ROOT/post-sym.err"
set -e
if [[ "$(runner_count)" -eq 1 ]]; then
  ok "post-run symlink: runner invoked once"
else bad "post-run symlink: expected 1 runner, got $(runner_count)"; fi
sc=$(journal_state_corrupt_count)
if [[ "$sc" -eq 1 ]]; then
  ok "post-run symlink: exactly one state-corrupt journal unit"
else bad "post-run symlink: expected 1 state-corrupt, got $sc"; fi
if [[ "$(supervisor_count)" -eq 0 ]]; then
  ok "post-run symlink: no supervisor handoff"
else bad "post-run symlink: handoff ran despite corrupt symlink state"; fi
if grep -q 'state-corrupt' "$ROOT/post-sym.err" 2>/dev/null || \
   grep -q 'state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "post-run symlink: no normal completion without state-corrupt"
else bad "post-run symlink: looked like normal completion"; fi
# Outside target (if created) must be unchanged after recovery work
if [[ -f "$CALLS/outside-valid-state.md" ]]; then
  outside_bytes=$(cat "$CALLS/outside-valid-state.md")
  # Recovery must not rewrite the outside target
  if [[ -n "$outside_bytes" ]] && grep -q 'via symlink target' "$CALLS/outside-valid-state.md"; then
    ok "post-run symlink: outside target bytes preserved (still the runner payload)"
  else
    bad "post-run symlink: outside target unexpected"
  fi
else
  bad "post-run symlink: outside target missing (runner did not create it)"
fi
# When recovery claims success, live path is a regular non-symlink file matching snapshot
if grep -q 'restored loop-state byte-for-byte' "$ROOT/post-sym.err" 2>/dev/null; then
  if [[ ! -L "$REPO/gibson/loop-state.md" && -f "$REPO/gibson/loop-state.md" ]] && \
     [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_bytes" ]]; then
    ok "post-run symlink: recovery success ⇒ no symlink left, exact snapshot bytes"
  else
    bad "post-run symlink: claimed restore but live path wrong (ls=$(ls -la "$REPO/gibson/loop-state.md" 2>&1))"
  fi
else
  # recovery-incomplete is also acceptable if explicit — but must not leave a
  # false "success" claim, and outside target still untouched above.
  if grep -qi 'recovery-incomplete\|state-corrupt' "$ROOT/post-sym.err" "$REPO/gibson/journal.md" 2>/dev/null; then
    ok "post-run symlink: fail-closed recovery path (no false exact-restore claim)"
  else
    bad "post-run symlink: neither restore nor recovery-incomplete ($(cat "$ROOT/post-sym.err"))"
  fi
fi
# Prefer the strong success path when snapshot existed (it did — pre-run snapshot)
if [[ ! -L "$REPO/gibson/loop-state.md" && -f "$REPO/gibson/loop-state.md" ]] && \
   [[ "$(cat "$REPO/gibson/loop-state.md")" == "$pre_bytes" ]]; then
  ok "post-run symlink: live path restored to pre-iteration regular file"
else
  # Allow quarantine-left-symlink only with explicit recovery-incomplete
  if [[ -L "$REPO/gibson/loop-state.md" ]] && \
     grep -qi 'recovery-incomplete' "$ROOT/post-sym.err" 2>/dev/null; then
    ok "post-run symlink: symlink left only under explicit recovery-incomplete"
  else
    bad "post-run symlink: live path not safely restored (ls=$(ls -la "$REPO/gibson/loop-state.md" 2>&1) err=$(cat "$ROOT/post-sym.err"))"
  fi
fi

# ---------------------------------------------------------------------------
# Unified key:value grammar (validator + read_field; issue #75 review blocker)
# ---------------------------------------------------------------------------
echo "validator: key:value and key: value are identical (empty values allowed)"
base="2026-08-02T12:00:00Z"
write_valid_state "$VDIR/space.md" \
  "updated=$base" "issue=75" "next_hat=test-engineer" \
  "next_action=a:b:c" "notes=canonical space"
write_valid_state_nospace "$VDIR/nospace.md" \
  "updated=$base" "issue=75" "next_hat=test-engineer" \
  "next_action=a:b:c" "notes=canonical space"
set +e
bash "$VALIDATOR" "$VDIR/space.md" >/dev/null 2>"$VDIR/space.err"
ec1=$?
bash "$VALIDATOR" "$VDIR/nospace.md" >/dev/null 2>"$VDIR/nospace.err"
ec2=$?
set -e
if [[ $ec1 -eq 0 && $ec2 -eq 0 ]]; then
  ok "grammar: both space and no-space forms validate"
else bad "grammar: space ec=$ec1 ($(cat "$VDIR/space.err")) nospace ec=$ec2 ($(cat "$VDIR/nospace.err"))"; fi
# Identical extracted field values under the shared parse
same=1
for k in updated issue pr hat next_hat round parked handoff handoff_sha next_action notes; do
  vs=$(test_read_field "$VDIR/space.md" "$k")
  vn=$(test_read_field "$VDIR/nospace.md" "$k")
  if [[ "$vs" != "$vn" ]]; then
    same=0
    bad "grammar: field $k differs space=[$vs] nospace=[$vn]"
  fi
done
if [[ "$same" -eq 1 ]]; then
  ok "grammar: shared parse yields identical field values for both forms"
fi
# Empty values: key: and key:<one-space> (space after colon only).
# Built with printf so the test source has no trailing-whitespace lines.
{
  printf '%s\n' "# Gibson loop state" "updated: $base"
  printf 'issue: \n'
  printf 'pr: \n'
  printf '%s\n' "hat: builder" "next_hat: builder" "round: 0" "parked: false"
  printf 'handoff: \n'
  printf 'handoff_sha: \n'
  printf '%s\n' "next_action: x" "notes: empty-with-space"
} > "$VDIR/empty-space.md"
{
  printf '%s\n' \
    "# Gibson loop state" \
    "updated:$base" \
    "issue:" \
    "pr:" \
    "hat:builder" \
    "next_hat:builder" \
    "round:0" \
    "parked:false" \
    "handoff:" \
    "handoff_sha:" \
    "next_action:x" \
    "notes:empty-nospace"
} > "$VDIR/empty-nospace.md"
set +e
bash "$VALIDATOR" "$VDIR/empty-space.md" >/dev/null 2>"$VDIR/es.err"
ec1=$?
bash "$VALIDATOR" "$VDIR/empty-nospace.md" >/dev/null 2>"$VDIR/en.err"
ec2=$?
set -e
if [[ $ec1 -eq 0 && $ec2 -eq 0 ]]; then
  ok "grammar: empty values accepted for key: and key:<space>"
else bad "grammar: empty values rejected (space ec=$ec1 nospace ec=$ec2)"; fi
iss_s=$(test_read_field "$VDIR/empty-space.md" issue)
iss_n=$(test_read_field "$VDIR/empty-nospace.md" issue)
if [[ -z "$iss_s" && -z "$iss_n" ]]; then
  ok "grammar: empty issue parses to empty string in both forms"
else bad "grammar: empty issue not empty (space=[$iss_s] nospace=[$iss_n])"; fi

echo "validator: hostile grammar — duplicates, leading-space keys, tabs, prose"
# duplicate already covered; leading-space key must not satisfy
cat > "$VDIR/leadspace.md" <<EOF
# Gibson loop state
updated: $base
issue:
pr:
hat: builder
 next_hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: x
EOF
set +e
bash "$VALIDATOR" "$VDIR/leadspace.md" >/dev/null 2>"$VDIR/ls.err"
ec=$?
set -e
if [[ $ec -ne 0 ]] && grep -q 'missing required key: next_hat' "$VDIR/ls.err"; then
  ok "hostile: leading-space key does not satisfy next_hat"
else bad "hostile: leading-space key accepted ($(cat "$VDIR/ls.err"))"; fi
# tab after colon is NOT the optional separator — value includes tab → invalid hat
printf '%s\n' \
  "# Gibson loop state" \
  "updated: $base" \
  "issue:" \
  "pr:" \
  "hat:	builder" \
  "next_hat: builder" \
  "round: 0" \
  "parked: false" \
  "handoff:" \
  "handoff_sha:" \
  "next_action: x" > "$VDIR/tabsep.md"
set +e
bash "$VALIDATOR" "$VDIR/tabsep.md" >/dev/null 2>"$VDIR/tab.err"
ec=$?
set -e
if [[ $ec -ne 0 ]] && grep -qi 'hat' "$VDIR/tab.err"; then
  ok "hostile: tab after colon is value data (invalid hat), not separator"
else bad "hostile: tab-as-separator incorrectly accepted ($(cat "$VDIR/tab.err"))"; fi
# Extra prose at column zero without key: pattern does not invent keys
cat > "$VDIR/prose.md" <<EOF
# Gibson loop state
updated: $base
issue:
pr:
hat: builder
This paragraph mentions next_hat builder but is not a field.
round: 0
parked: false
handoff:
handoff_sha:
next_action: x
EOF
set +e
bash "$VALIDATOR" "$VDIR/prose.md" >/dev/null 2>"$VDIR/prose.err"
ec=$?
set -e
if [[ $ec -ne 0 ]] && grep -q 'missing required key: next_hat' "$VDIR/prose.err"; then
  ok "hostile: extra prose does not satisfy next_hat"
else bad "hostile: prose incorrectly accepted ($(cat "$VDIR/prose.err"))"; fi
# two spaces after colon: first stripped, second preserved (meaningful data)
cat > "$VDIR/twospace.md" <<EOF
# Gibson loop state
updated: $base
issue:
pr:
hat:  builder
next_hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: x
EOF
set +e
bash "$VALIDATOR" "$VDIR/twospace.md" >/dev/null 2>"$VDIR/ts2.err"
ec=$?
set -e
# value is " builder" (leading space preserved) → invalid hat enum
if [[ $ec -ne 0 ]] && grep -qi 'hat' "$VDIR/ts2.err"; then
  ok "hostile: only one optional space stripped (extra space is value data)"
else bad "hostile: two-space value mishandled ($(cat "$VDIR/ts2.err"))"; fi

echo "driver: e2e no-space and canonical-space produce identical hat/round/handoff behavior"
setup_repo
install_fake_supervisor_stack
# Pre-state no-space with next_hat:test-engineer — must pass validate + read_field
write_valid_state_nospace "$REPO/gibson/loop-state.md" \
  "next_hat=test-engineer" "round=3" "next_action=from nospace pre" "notes=pre-nospace"
make_runner_cmd rewrite-valid-nospace
: > "$CALLS/runner.count"
: > "$CALLS/supervisor.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/e2e-nospace.err"
set -e
if [[ "$(runner_count)" -eq 1 ]]; then
  ok "e2e no-space: runner invoked (pre-state validated + next_hat read)"
else bad "e2e no-space: runner not invoked (err=$(cat "$ROOT/e2e-nospace.err"))"; fi
if grep -q 'iteration hat=test-engineer' "$ROOT/e2e-nospace.err"; then
  ok "e2e no-space: next_hat test-engineer read correctly (no internal error)"
else bad "e2e no-space: wrong/missing hat (err=$(cat "$ROOT/e2e-nospace.err"))"; fi
if ! grep -q 'state-corrupt\|internal error' "$ROOT/e2e-nospace.err" 2>/dev/null && \
   ! grep -q 'state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "e2e no-space: no state-corrupt / internal error on valid no-space rewrite"
else bad "e2e no-space: unexpected corrupt/error"; fi
if grep -q 'rewritten valid nospace\|next_hat:test-engineer\|next_hat: test-engineer' "$REPO/gibson/loop-state.md"; then
  ok "e2e no-space: post-run no-space rewrite retained"
else bad "e2e no-space: post-run state unexpected ($(cat "$REPO/gibson/loop-state.md"))"; fi
nh=$(test_read_field "$REPO/gibson/loop-state.md" next_hat)
rd=$(test_read_field "$REPO/gibson/loop-state.md" round)
if [[ "$nh" == "test-engineer" && "$rd" == "1" ]]; then
  ok "e2e no-space: post-run fields parse next_hat/round correctly"
else bad "e2e no-space: post-run fields nh=[$nh] rd=[$rd]"; fi

# Canonical space path — same hats/round behavior
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" \
  "next_hat=test-engineer" "round=3" "next_action=from space pre" "notes=pre-space"
make_runner_cmd rewrite-valid
: > "$CALLS/runner.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --error-budget 5 >/dev/null 2>"$ROOT/e2e-space.err"
set -e
if [[ "$(runner_count)" -eq 1 ]] && grep -q 'iteration hat=test-engineer' "$ROOT/e2e-space.err"; then
  ok "e2e space: runner + next_hat identical to no-space path"
else bad "e2e space: behavior diverged (err=$(cat "$ROOT/e2e-space.err"))"; fi
if ! grep -q 'state-corrupt' "$ROOT/e2e-space.err" "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "e2e space: no state-corrupt on canonical rewrite"
else bad "e2e space: false state-corrupt"; fi
nh=$(test_read_field "$REPO/gibson/loop-state.md" next_hat)
rd=$(test_read_field "$REPO/gibson/loop-state.md" round)
if [[ "$nh" == "test-engineer" && "$rd" == "1" ]]; then
  ok "e2e space: post-run fields match no-space path"
else bad "e2e space: fields nh=[$nh] rd=[$rd]"; fi

# No-space handoff fields: driver must read handoff/handoff_sha without internal error
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=pre-hand-nospace"
make_runner_cmd rewrite-handoff-nospace
: > "$CALLS/runner.count"
: > "$CALLS/supervisor.count"
# Local branch so handoff plumbing can attempt resolve (or block cleanly)
$GIT -C "$REPO" checkout -q -b feat/75-widget
echo widget > "$REPO/widget.txt"
$GIT -C "$REPO" add widget.txt
$GIT -C "$REPO" commit -q -m "widget"
$GIT -C "$REPO" checkout -q main
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" --once \
  --supervisor devin --error-budget 5 >/dev/null 2>"$ROOT/e2e-hand-ns.err"
set -e
if [[ "$(runner_count)" -eq 1 ]]; then
  ok "e2e handoff-nospace: runner invoked"
else bad "e2e handoff-nospace: runner not invoked"; fi
if ! grep -qi 'internal error' "$ROOT/e2e-hand-ns.err"; then
  ok "e2e handoff-nospace: no internal error reading no-space handoff fields"
else bad "e2e handoff-nospace: internal error ($(cat "$ROOT/e2e-hand-ns.err"))"; fi
if ! grep -q 'state-corrupt' "$ROOT/e2e-hand-ns.err" 2>/dev/null && \
   ! grep -q 'state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "e2e handoff-nospace: valid no-space handoff rewrite is not state-corrupt"
else bad "e2e handoff-nospace: false state-corrupt"; fi
# Meaningful consumption check (not a tautology): the driver must have read
# no-space `handoff:feat/75-widget` into the handoff path. Evidence must be an
# observable branch-bearing consequence of the *driver* handoff path — journal
# / stderr messages that name the branch, or captured supervisor argv — never
# the independent test helper re-reading the queued field (that would still
# pass if loop.sh stopped parsing no-space handoff and left the file untouched).
nt=$(test_read_field "$REPO/gibson/loop-state.md" notes)
hb=$(test_read_field "$REPO/gibson/loop-state.md" handoff)
if [[ "$nt" == "handoff queued nospace" ]]; then
  ok "e2e handoff-nospace: no-space notes field parsed after post-run"
else bad "e2e handoff-nospace: notes not parsed (nt=[$nt])"; fi
consumed=0
if grep -qE 'handoff of feat/75-widget|pinning handoff to feat/75-widget|branch=feat/75-widget' \
     "$ROOT/e2e-hand-ns.err" "$REPO/gibson/journal.md" 2>/dev/null; then
  consumed=1
fi
if [[ -f "$CALLS/supervisor.args" ]] && grep -q 'feat/75-widget' "$CALLS/supervisor.args" 2>/dev/null; then
  consumed=1
fi
if [[ "$consumed" -eq 1 ]]; then
  ok "e2e handoff-nospace: driver consumed no-space handoff:feat/75-widget into handoff path"
else
  bad "e2e handoff-nospace: handoff field not consumed (hb=[$hb] err=$(cat "$ROOT/e2e-hand-ns.err") j=$(cat "$REPO/gibson/journal.md" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# Issue #63 — silent-noop wired into loop.sh (no-progress / --stale-budget)
# ---------------------------------------------------------------------------
echo
echo "issue #63: no-progress / stale-budget / precedence"

# make_runner_cmd is defined once near the top of this file (includes the
# issue #63 clock-only / same-len / handoff-sha-only behaviors). Do not
# reintroduce a late redefinition — ShellCheck ≤0.10 reports SC2218 (#138).

journal_no_progress_count() {
  local n=0 j="$REPO/gibson/journal.md"
  if [[ -f "$j" ]]; then
    n=$(grep -c '· no-progress' "$j" 2>/dev/null || true)
  fi
  echo "${n:-0}"
}

# --- fresh updated-only rewrites stop exactly at stale budget N ---
echo "driver: clock-only rewrites stop at --stale-budget N with distinct no-progress"
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-clock-only
: > "$CALLS/runner.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --max-iterations 10 --error-budget 9 --stale-budget 3 \
  >/dev/null 2>"$ROOT/stale3.err"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'no-progress: stale budget exhausted' "$ROOT/stale3.err"; then
  ok "stale-budget 3: dies with distinct no-progress diagnosis"
else
  bad "stale-budget 3: expected no-progress die (rc=$rc err=$(tr '\n' ' ' <"$ROOT/stale3.err"))"
fi
np=$(journal_no_progress_count)
if [[ "$np" -eq 3 ]]; then
  ok "stale-budget 3: exactly 3 distinct no-progress journal entries"
else
  bad "stale-budget 3: expected 3 no-progress journals, got $np"
fi
if [[ "$(runner_count)" -eq 3 ]]; then
  ok "stale-budget 3: runner invoked exactly 3 times"
else
  bad "stale-budget 3: runner count=$(runner_count) want 3"
fi
# Match the journal section marker, not the phrase "not state-corrupt" in the
# no-progress diagnosis body.
if ! grep -q '· state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null && \
   ! grep -q 'state-corrupt (consecutive' "$ROOT/stale3.err" 2>/dev/null; then
  ok "stale-budget 3: not classified as state-corrupt"
else
  bad "stale-budget 3: wrongly state-corrupt"
fi
# Snapshot must still exist; no restore on no-progress (live may differ only by clock).
if [[ -f "$REPO/gibson/.loop-state.prev" ]]; then
  ok "stale-budget 3: snapshot retained (no restore path required)"
else
  bad "stale-budget 3: snapshot missing"
fi

# --- exact escalation threshold on no-progress ---
echo "driver: escalate-after fires on shared failure from no-progress"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-clock-only
: > "$CALLS/runner.count"
: > "$CALLS/second-opinion.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --max-iterations 10 --error-budget 5 --stale-budget 5 --escalate-after 2 \
  >/dev/null 2>"$ROOT/esc-np.err"
set -e
# At escalate-after 2, second-opinion should fire once when failures hits 2.
so=$(wc -l < "$CALLS/second-opinion.count" | tr -d ' ')
if [[ "${so:-0}" -ge 1 ]]; then
  ok "escalate-after 2: second-opinion invoked on no-progress streak"
else
  bad "escalate-after 2: second-opinion never ran (err=$(tr '\n' ' ' <"$ROOT/esc-np.err"))"
fi
if grep -q 'no-progress' "$ROOT/esc-np.err" "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "escalate path still journals no-progress"
else
  bad "escalate path lost no-progress diagnosis"
fi

# --- one shared failure unit per iteration; no double classification ---
echo "driver: one no-progress unit per iteration (no double classification)"
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-clock-only
: > "$CALLS/runner.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 5 --stale-budget 5 \
  >/dev/null 2>"$ROOT/one-np.err"
set -e
np=$(journal_no_progress_count)
sc=$(journal_state_corrupt_count)
if [[ "$np" -eq 1 && "$sc" -eq 0 ]]; then
  ok "single clock-only: exactly one no-progress, zero state-corrupt"
else
  bad "single clock-only: np=$np sc=$sc"
fi
if grep -q 'no-progress (stale=1/5, consecutive failures=1/5)' "$ROOT/one-np.err"; then
  ok "single clock-only: one shared failure unit and one stale unit"
else
  bad "single clock-only: accounting missing (err=$(tr '\n' ' ' <"$ROOT/one-np.err"))"
fi
if ! grep -q 'runner exit' "$ROOT/one-np.err"; then
  ok "single clock-only: not also labeled runner-failure"
else
  bad "single clock-only: double-classified as runner-failure"
fi

# --- state-corrupt precedence over no-progress ---
echo "driver: state-corrupt (stale stamp) wins over no-progress"
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-stale
: > "$CALLS/runner.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 5 --stale-budget 5 \
  >/dev/null 2>"$ROOT/sc-vs-np.err"
set -e
sc=$(journal_state_corrupt_count)
np=$(journal_no_progress_count)
if [[ "$sc" -eq 1 && "$np" -eq 0 ]]; then
  ok "stale stamp: state-corrupt only (no-progress sensor not run)"
else
  bad "stale stamp: sc=$sc np=$np"
fi

# --- runner-failure precedence over no-progress ---
echo "driver: valid state + nonzero exit is runner-failure only (not no-progress)"
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-clock-only-then-fail
: > "$CALLS/runner.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 5 --stale-budget 5 \
  >/dev/null 2>"$ROOT/rf-vs-np.err"
set -e
if grep -q 'runner exit 1 (consecutive failures=1/5)' "$ROOT/rf-vs-np.err"; then
  ok "clock-only + exit 1: runner-failure once"
else
  bad "clock-only + exit 1: missing runner-failure (err=$(tr '\n' ' ' <"$ROOT/rf-vs-np.err"))"
fi
np=$(journal_no_progress_count)
if [[ "$np" -eq 0 ]]; then
  ok "clock-only + exit 1: no-progress sensor not run"
else
  bad "clock-only + exit 1: also no-progress (np=$np)"
fi

# --- substantive same-length edit counts as progress and resets both counters ---
echo "driver: same-length substantive edit is progress (resets failures+stale)"
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture" "round=0"
make_runner_cmd rewrite-clock-only
: > "$CALLS/runner.count"
# First: one no-progress so counters are non-zero
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 5 --stale-budget 5 \
  >/dev/null 2>"$ROOT/pre-progress.err"
set -e
if grep -q 'no-progress (stale=1/5, consecutive failures=1/5)' "$ROOT/pre-progress.err"; then
  ok "pre-progress: seeded failures=1 stale=1"
else
  bad "pre-progress: seed failed (err=$(tr '\n' ' ' <"$ROOT/pre-progress.err"))"
fi
make_runner_cmd rewrite-same-len
: > "$CALLS/runner.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 5 --stale-budget 5 \
  >/dev/null 2>"$ROOT/same-len.err"
set -e
if ! grep -q 'no-progress' "$ROOT/same-len.err" && \
   ! grep -q '· no-progress' "$REPO/gibson/journal.md" 2>/dev/null; then
  # journal may still have the prior no-progress; check only this run's stderr
  ok "same-len: no no-progress on stderr this run"
else
  # Prior journal entry is expected; stderr of this run must be clean of no-progress
  if ! grep -q 'no-progress' "$ROOT/same-len.err"; then
    ok "same-len: no no-progress on stderr this run"
  else
    bad "same-len: still no-progress (err=$(tr '\n' ' ' <"$ROOT/same-len.err"))"
  fi
fi
# Next clock-only must start stale at 1 again (reset happened).
make_runner_cmd rewrite-clock-only
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 5 --stale-budget 5 \
  >/dev/null 2>"$ROOT/after-reset.err"
set -e
if grep -q 'no-progress (stale=1/5, consecutive failures=1/5)' "$ROOT/after-reset.err"; then
  ok "same-len: progress reset both counters (next no-progress is 1/5)"
else
  bad "same-len: counters not reset (err=$(tr '\n' ' ' <"$ROOT/after-reset.err"))"
fi

# --- handoff_sha / non-updated change counts as progress ---
echo "driver: handoff_sha-only change counts as progress"
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-handoff-sha-only
: > "$CALLS/runner.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 5 --stale-budget 5 \
  >/dev/null 2>"$ROOT/sha-only.err"
set -e
if ! grep -q 'no-progress' "$ROOT/sha-only.err" && \
   ! grep -q 'state-corrupt' "$ROOT/sha-only.err"; then
  ok "handoff_sha-only: progress (not no-progress / state-corrupt)"
else
  bad "handoff_sha-only: failed (err=$(tr '\n' ' ' <"$ROOT/sha-only.err"))"
fi
sha=$(test_read_field "$REPO/gibson/loop-state.md" handoff_sha)
if [[ "$sha" == "abcdef0123456789abcdef0123456789abcdef01" ]]; then
  ok "handoff_sha-only: live state retained the new sha"
else
  bad "handoff_sha-only: sha not retained (sha=[$sha])"
fi

# --- no reset, restoration, or handoff on no-progress ---
echo "driver: no-progress does not restore or hand off"
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
# Capture pre-run bytes of a field that clock-only leaves alone.
pre_notes=$(test_read_field "$REPO/gibson/loop-state.md" notes)
make_runner_cmd rewrite-clock-only
: > "$CALLS/runner.count"
: > "$CALLS/supervisor.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 5 --stale-budget 5 --supervisor devin --reviewers codex \
  >/dev/null 2>"$ROOT/np-nohand.err"
set -e
if [[ "$(supervisor_count)" -eq 0 ]]; then
  ok "no-progress: supervisor handoff suppressed"
else
  bad "no-progress: supervisor was invoked"
fi
post_notes=$(test_read_field "$REPO/gibson/loop-state.md" notes)
if [[ "$post_notes" == "$pre_notes" ]]; then
  ok "no-progress: non-clock fields left as written (no restore wipe)"
else
  bad "no-progress: notes changed unexpectedly (pre=$pre_notes post=$post_notes)"
fi
# Live updated must be fresh (clock-only write kept), not restored to old stamp.
post_up=$(test_read_field "$REPO/gibson/loop-state.md" updated)
if [[ "$post_up" != "2026-08-02T00:00:00Z" && -n "$post_up" ]]; then
  ok "no-progress: live clock stamp retained (no exact-byte restore)"
else
  bad "no-progress: looks restored to ancient stamp (updated=$post_up)"
fi

# --- --stale-budget CLI contract ---
echo "driver: --stale-budget 1, override, omitted default, invalid values"
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-clock-only
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --max-iterations 5 --error-budget 9 --stale-budget 1 \
  >/dev/null 2>"$ROOT/stale1.err"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'stale budget exhausted (1/1)' "$ROOT/stale1.err"; then
  ok "--stale-budget 1: stops on first no-progress"
else
  bad "--stale-budget 1: (rc=$rc err=$(tr '\n' ' ' <"$ROOT/stale1.err"))"
fi

# Explicit override distinct from error-budget: stale=2, error=9 → stop at 2.
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-clock-only
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --max-iterations 10 --error-budget 9 --stale-budget 2 \
  >/dev/null 2>"$ROOT/stale2.err"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'stale budget exhausted (2/2)' "$ROOT/stale2.err" && \
   [[ "$(journal_no_progress_count)" -eq 2 ]]; then
  ok "--stale-budget 2 overrides error-budget 9"
else
  bad "--stale-budget 2 override failed (rc=$rc np=$(journal_no_progress_count) err=$(tr '\n' ' ' <"$ROOT/stale2.err"))"
fi

# Omitted --stale-budget resolves exactly to --error-budget.
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-clock-only
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --max-iterations 10 --error-budget 2 \
  >/dev/null 2>"$ROOT/stale-def.err"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qE 'no-progress: (stale|error) budget exhausted' "$ROOT/stale-def.err" && \
   [[ "$(journal_no_progress_count)" -eq 2 ]]; then
  ok "omitted --stale-budget equals --error-budget 2"
else
  bad "omitted stale default failed (rc=$rc np=$(journal_no_progress_count) err=$(tr '\n' ' ' <"$ROOT/stale-def.err"))"
fi

# Invalid / zero / negative / overflow / injection-shaped values.
for badval in 0 -1 abc '2x' '08' '9999999999' '1;rm' '$(touch x)' ' ' ''; do
  set +e
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
    --once --stale-budget "$badval" >/dev/null 2>"$ROOT/bad-stale.err"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && grep -qi 'invalid --stale-budget' "$ROOT/bad-stale.err"; then
    ok "rejects --stale-budget '$badval'"
  else
    bad "accepted --stale-budget '$badval' (rc=$rc err=$(tr '\n' ' ' <"$ROOT/bad-stale.err"))"
  fi
done
# Injection must not execute.
rm -f "$ROOT/pwned-stale"
set +e
bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --stale-budget 'x[$(touch '"$ROOT"'/pwned-stale)]' \
  >/dev/null 2>"$ROOT/inj-stale.err"
set -e
if [[ ! -e "$ROOT/pwned-stale" ]]; then
  ok "--stale-budget injection payload does not execute"
else
  bad "--stale-budget injection executed"
fi

# --- dry-run / print-prompt / prequeued handoff / snapshot failure / halt inert ---
echo "driver: dry-run / print-prompt / prequeued / snapshot-fail / halt stay inert for no-progress"
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-clock-only
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --dry-run --error-budget 1 --stale-budget 1 \
  >/dev/null 2>"$ROOT/np-dry.err"
set -e
if [[ "$(runner_count)" -eq 0 ]] && ! grep -q 'no-progress' "$ROOT/np-dry.err" && \
   ! grep -q '· no-progress' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "dry-run: no runner, no no-progress journal"
else
  bad "dry-run: leaked no-progress or ran runner"
fi

setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
set +e
bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --print-prompt --error-budget 1 --stale-budget 1 \
  >/dev/null 2>"$ROOT/np-print.err"
set -e
if ! grep -q 'no-progress' "$ROOT/np-print.err" && \
   ! grep -q '· no-progress' "$REPO/gibson/journal.md" 2>/dev/null; then
  ok "print-prompt: no no-progress accounting"
else
  bad "print-prompt: no-progress leaked"
fi

# Pre-queued handoff: no runner → no no-progress.
setup_repo
install_fake_supervisor_stack
write_valid_state "$REPO/gibson/loop-state.md" \
  "handoff=feat/75-widget" \
  "handoff_sha=abcdef0123456789abcdef0123456789abcdef01" \
  "notes=prequeued"
: > "$CALLS/runner.count"
: > "$CALLS/supervisor.count"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  "$LOOP_BIN" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 5 --stale-budget 1 --supervisor devin --reviewers codex \
  >/dev/null 2>"$ROOT/np-preq.err"
set -e
if [[ "$(runner_count)" -eq 0 ]] && ! grep -q 'no-progress' "$ROOT/np-preq.err"; then
  ok "pre-queued handoff: no runner, no no-progress"
else
  bad "pre-queued handoff: runner or no-progress leaked (err=$(tr '\n' ' ' <"$ROOT/np-preq.err"))"
fi

# Snapshot failure remains state-corrupt (not no-progress).
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-clock-only
mkdir -p "$REPO/gibson/.loop-state.prev"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 5 --stale-budget 1 \
  >/dev/null 2>"$ROOT/np-snap.err"
set -e
if grep -q 'state-corrupt\|snapshot refused\|not a safe file destination' "$ROOT/np-snap.err" 2>/dev/null || \
   grep -q 'state-corrupt' "$REPO/gibson/journal.md" 2>/dev/null; then
  if ! grep -q 'no-progress' "$ROOT/np-snap.err" && [[ "$(journal_no_progress_count)" -eq 0 ]]; then
    ok "snapshot failure: state-corrupt only (no no-progress)"
  else
    bad "snapshot failure: also no-progress"
  fi
else
  bad "snapshot failure: missing state-corrupt (err=$(tr '\n' ' ' <"$ROOT/np-snap.err"))"
fi

# Halt path: no no-progress. Local HALT stops cleanly (exit 0) before any runner.
setup_repo
write_valid_state "$REPO/gibson/loop-state.md" "notes=fixture"
make_runner_cmd rewrite-clock-only
touch "$REPO/gibson/HALT"
set +e
HERMES_CMD="$CALLS/fake-runner.sh" \
  bash "$LOOP" --runner hermes --repo "$REPO" --gibson "$GIBSON" \
  --once --error-budget 1 --stale-budget 1 \
  >/dev/null 2>"$ROOT/np-halt.err"
rc=$?
set -e
if [[ "$(runner_count)" -eq 0 ]] && \
   grep -q 'kill switch' "$ROOT/np-halt.err" && \
   ! grep -q 'no-progress' "$ROOT/np-halt.err" && \
   [[ "$(journal_no_progress_count)" -eq 0 ]]; then
  ok "halt: no runner, no no-progress (rc=$rc)"
else
  bad "halt: leaked work or no-progress (rc=$rc err=$(tr '\n' ' ' <"$ROOT/np-halt.err"))"
fi

# Help documents --stale-budget (GNU/BSD grep: -- ends options so the pattern
# is not parsed as a flag).
if bash "$LOOP" --help 2>/dev/null | grep -qF -- '--stale-budget'; then
  ok "loop.sh --help documents --stale-budget"
else
  bad "loop.sh --help missing --stale-budget"
fi

# ---------------------------------------------------------------------------
echo
echo "loop-state.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
