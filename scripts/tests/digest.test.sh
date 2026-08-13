#!/usr/bin/env bash
# digest.test.sh — offline sensors for scripts/digest.sh (issue #72)
#
# Network-free, deterministic, Bash 3.2-compatible. Proves local-only render,
# quiet-week status, card fields, fail-closed inputs, atomic output, dry-run
# byte preservation, and that delivery/ingest/hostile cmds never run.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DIGEST="$SCRIPT_DIR/../digest.sh"
LEDGER_TOOL="$SCRIPT_DIR/../decision-ledger.sh"
PASS=0
FAIL=0

ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-digest-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"
mkdir -p "$BIN"
for cmd in gh hermes mail mailx sendmail curl wget nc ssh webhook iMessage osascript; do
  cat > "$BIN/$cmd" <<'STUB'
#!/usr/bin/env bash
echo "INVOKED_FORBIDDEN:$(basename "$0") $*" >> "${FORBIDDEN_LOG:-/dev/null}"
exit 99
STUB
  chmod +x "$BIN/$cmd"
done
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export FORBIDDEN_LOG="$ROOT/forbidden.log"
: > "$FORBIDDEN_LOG"
export HERMES_CMD="$BIN/hermes"
export DIGEST_CMD="$BIN/webhook"

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
NOW="2026-08-03T12:00:00Z"
PERIOD="2026-07-27T12:00:00Z"

seed_decision() {
  local ledger="$1" repo="$2" gate="$3" sid="$4" sha="$5" what="$6"
  "$LEDGER_TOOL" add --ledger "$ledger" --created-at "2026-08-01T00:00:00Z" \
    --repo "$repo" --gate "$gate" --source-type pr --source-id "$sid" --source-sha "$sha" \
    --what "$what" \
    --why-you "Owner decision required by doctrine" \
    --risk-level medium \
    --risk-consequence "Something could go wrong" \
    --risk-undo "Roll back" \
    --recommend Approve \
    --recommend-rationale "Fleet recommends this" \
    --if-you-wait "Other work continues; nothing auto-approves" \
    --source-ref "PR #$sid" >/dev/null
}

echo "=== help / ingest hard fail ==="
out=$("$DIGEST" --help 2>&1) || true
contains "help mentions offline" "$out" "offline"
contains "help mentions owner-gated" "$out" "owner-gated"
rc=0; "$DIGEST" --ingest --ledger /dev/null 2>"$ROOT/ingest.err" || rc=$?
check "--ingest exits 2" "$rc" "2"
contains "--ingest boundary message" "$(cat "$ROOT/ingest.err")" "Owner-gated boundary"
rc=0; "$DIGEST" --deliver --ledger /dev/null 2>/dev/null || rc=$?
check "--deliver exits 2" "$rc" "2"
rc=0; "$DIGEST" --hermes --ledger /dev/null 2>/dev/null || rc=$?
check "--hermes exits 2" "$rc" "2"

echo
echo "=== deterministic sorting + time injection ==="
L="$ROOT/ledger.jsonl"
seed_decision "$L" "zebra/app" "G12" "10" "$SHA_A" "Zebra decision"
seed_decision "$L" "acme/app" "G6" "1" "$SHA_A" "Acme pricing decision"
seed_decision "$L" "acme/app" "G12" "2" "$SHA_B" "Acme auth decision"
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" 2>/dev/null)
# Order: acme G6, acme G12, zebra G12
python3 - "$out" <<'PY' && ok "decisions sorted repo then gate then id" || bad "sort order wrong"
import sys
text = sys.argv[1]
# headings ### GATE · repo
import re
heads = re.findall(r'^### (G\d+) · ([^ ]+)', text, re.M)
assert heads[0] == ("G6", "acme/app"), heads
assert heads[1][1] == "acme/app" and heads[1][0] == "G12", heads
assert heads[2] == ("G12", "zebra/app"), heads
print("ok")
PY
contains "injected period start" "$out" "$PERIOD"
contains "injected now" "$out" "$NOW"

echo
echo "=== quiet active week with zero ships ==="
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" 2>/dev/null)
contains "quiet week message" "$out" "quiet active week"
contains "silence is not death" "$out" "not death"
contains "zero ships" "$out" "Ships this period: 0"

echo
echo "=== missing / unknown health labeled honestly ==="
contains "loop health unknown" "$out" "Loop health: unknown"
contains "parked unknown" "$out" "Parked work: unknown"
contains "journal not supplied" "$out" "Journal: not supplied"

# with loop-state
cat > "$ROOT/loop-state.md" <<'EOF'
# Gibson loop state
updated: 2026-08-02T00:00:00Z
issue: 72
pr:
hat: release
next_hat: historian
round: 1
parked: false
handoff:
handoff_sha:
next_action: queue decision card
notes: test
EOF
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --loop-state "$ROOT/loop-state.md" 2>/dev/null)
contains "loop health present" "$out" "hat=release"
# future loop-state fails
cat > "$ROOT/loop-future.md" <<'EOF'
# Gibson loop state
updated: 2026-12-01T00:00:00Z
issue: 1
pr:
hat: builder
next_hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: none
EOF
rc=0
"$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --loop-state "$ROOT/loop-future.md" >/dev/null 2>&1 || rc=$?
check "future loop-state exits 3" "$rc" "3"

echo
echo "=== one card per pending decision with mandatory fields ==="
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" 2>/dev/null)
for field in "WHAT:" "WHY YOU:" "RISK:" "RECOMMEND:" "IF YOU WAIT:" "SOURCE:" "ID:"; do
  n=$(echo "$out" | grep -cF "$field" || true)
  if [[ "$n" -eq 3 ]]; then ok "field $field appears thrice"; else bad "field $field count=$n want 3"; fi
done
contains "reply notes offline" "$out" "owner channel not wired"

echo
echo "=== multiple repos/sources in status ==="
contains "acme decision present" "$out" "Acme pricing decision"
contains "zebra decision present" "$out" "Zebra decision"
out_f=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" --repo acme/app 2>/dev/null)
contains "filter acme" "$out_f" "acme/app"
lacks "filter excludes zebra card" "$out_f" "Zebra decision"

echo
echo "=== merged snapshot ships + source mismatch ==="
cat > "$ROOT/merged.json" <<EOF
{"schema":"digest-merged-since:v1","repo":"acme/app","as_of":"2026-08-02T00:00:00Z","merges":[{"repo":"acme/app","title":"Ship password reset","pr":12,"merged_at":"2026-08-01T15:00:00Z"}]}
EOF
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --repo acme/app --merged-since "$ROOT/merged.json" 2>/dev/null)
contains "ship count 1" "$out" "Ships this period: 1"
contains "ship title" "$out" "Ship password reset"
# mismatch
cat > "$ROOT/merged-bad.json" <<EOF
{"schema":"digest-merged-since:v1","repo":"other/app","as_of":"2026-08-02T00:00:00Z","merges":[]}
EOF
rc=0
"$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --repo acme/app --merged-since "$ROOT/merged-bad.json" >/dev/null 2>&1 || rc=$?
check "merged repo mismatch exits 3" "$rc" "3"
# future merge
cat > "$ROOT/merged-future.json" <<EOF
{"schema":"digest-merged-since:v1","as_of":"2026-08-02T00:00:00Z","merges":[{"title":"x","merged_at":"2026-09-01T00:00:00Z"}]}
EOF
rc=0
"$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --merged-since "$ROOT/merged-future.json" >/dev/null 2>&1 || rc=$?
check "future merge exits 3" "$rc" "3"

echo
echo "=== parked snapshot ==="
cat > "$ROOT/parked.json" <<EOF
{"schema":"digest-parked:v1","repo":"acme/app","as_of":"2026-08-02T00:00:00Z","items":[{"pr":9,"reason":"parked after 3 fix rounds"}]}
EOF
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --repo acme/app --parked "$ROOT/parked.json" 2>/dev/null)
contains "parked count" "$out" "Parked work: 1"
contains "parked reason" "$out" "parked after 3 fix rounds"

echo
echo "=== malformed ledger fails before partial output ==="
printf '%s\n' '{not json' > "$ROOT/bad-ledger.jsonl"
rc=0
out=$("$DIGEST" --ledger "$ROOT/bad-ledger.jsonl" --now "$NOW" 2>"$ROOT/bad.err") || rc=$?
check "malformed ledger non-zero" "$rc" "3"
if [[ -z "$out" ]]; then ok "no partial stdout on malformed ledger"; else bad "partial stdout: $out"; fi

echo
echo "=== atomic output success / failure / symlink refusal ==="
OUTF="$ROOT/out.md"
rc=0
"$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" --output "$OUTF" 2>/dev/null || rc=$?
check "output write exit 0" "$rc" "0"
[[ -f "$OUTF" && -s "$OUTF" ]] && ok "output file non-empty" || bad "output missing/empty"
# stdout equivalence
stdout=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" 2>/dev/null)
if cmp -s "$OUTF" <(printf '%s' "$stdout"); then
  ok "stdout/output equivalence"
else
  # allow trailing newline differences
  if [[ "$(cat "$OUTF")" == "$stdout" ]]; then
    ok "stdout/output equivalence (cat)"
  else
    bad "stdout differs from --output"
  fi
fi
# symlink refuse
ln -s "$OUTF" "$ROOT/out-link.md"
rc=0
"$DIGEST" --ledger "$L" --now "$NOW" --output "$ROOT/out-link.md" 2>/dev/null || rc=$?
check "symlink output exits 4" "$rc" "4"
# directory refuse
mkdir -p "$ROOT/outdir"
rc=0
"$DIGEST" --ledger "$L" --now "$NOW" --output "$ROOT/outdir" 2>/dev/null || rc=$?
check "directory output non-zero" "$rc" "4"
# FIFO refuse
if mkfifo "$ROOT/out.fifo" 2>/dev/null; then
  rc=0
  "$DIGEST" --ledger "$L" --now "$NOW" --output "$ROOT/out.fifo" 2>/dev/null || rc=$?
  if [[ "$rc" -eq 4 ]]; then ok "FIFO output exits 4"; else bad "FIFO output rc=$rc"; fi
else
  ok "FIFO skip"
fi

echo
echo "=== dry-run byte preservation ==="
printf 'ORIGINAL_BYTES_DO_NOT_TOUCH\n' > "$OUTF"
before=$(cat "$OUTF")
sum_before=$(shasum -a 256 "$OUTF" | awk '{print $1}')
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" --output "$OUTF" --dry-run 2>/dev/null)
after=$(cat "$OUTF")
sum_after=$(shasum -a 256 "$OUTF" | awk '{print $1}')
check "dry-run preserves bytes" "$before" "$after"
check "dry-run preserves sha256" "$sum_before" "$sum_after"
contains "dry-run still renders" "$out" "Owner digest"

echo
echo "=== machine-readable JSON schema ==="
jout=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" --format json 2>/dev/null)
python3 -c '
import json,sys
o=json.loads(sys.stdin.read())
assert o["schema"]=="owner-digest:v1"
assert o["quiet_active_week"] is True
assert o["invariants"]["no_auto_approve"] is True
assert o["invariants"]["delivery_owner_gated"] is True
assert o["pending_count"]==3
assert o["phase"]=="offline-foundation"
' <<<"$jout" && ok "json schema owner-digest:v1" || bad "json schema invalid"

echo
echo "=== hostile HERMES_CMD / DIGEST_CMD never executed ==="
# error paths too
"$DIGEST" --ingest --ledger "$L" 2>/dev/null || true
"$DIGEST" --ledger "$ROOT/missing-ledger.jsonl" 2>/dev/null || true
"$DIGEST" --ledger "$L" --now "$NOW" --merged-since "$ROOT/merged-bad.json" --repo acme/app 2>/dev/null || true
if [[ ! -s "$FORBIDDEN_LOG" ]]; then
  ok "forbidden tools never invoked (including error paths)"
else
  bad "forbidden invoked: $(cat "$FORBIDDEN_LOG")"
fi

echo
echo "=== mutation invariants: no auto-approve, no ledger mutate, no answer consume ==="
before=$(cat "$L")
"$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" >/dev/null 2>&1 || true
after=$(cat "$L")
check "digest does not mutate ledger" "$before" "$after"
# prove no APPROVED written anywhere by digest
if grep -r "APPROVED\|auto-approve\|delivered" "$OUTF" 2>/dev/null | grep -vi "never auto-approve\|not an approval\|not delivered\|no_auto_approve" >/dev/null; then
  bad "output suggests approval/delivery"
else
  ok "output does not claim approval or delivery"
fi
contains "invariants restated" "$out" "never auto-approve"

echo
echo "=== journal optional ==="
printf '## iteration 1\nhello\n' > "$ROOT/journal.md"
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" --journal "$ROOT/journal.md" 2>/dev/null)
contains "journal present" "$out" "Journal: lines="

echo
echo "=== P1: future ledger decisions refused ==="
LF="$ROOT/future-ledger.jsonl"
# created_at after --now
"$LEDGER_TOOL" add --ledger "$LF" --created-at "2026-12-01T00:00:00Z" \
  --repo acme/app --gate G1 --source-type pr --source-id fut --source-sha "$SHA_A" \
  --what "future decision" --why-you "y" --risk-level low --risk-consequence c --risk-undo u \
  --recommend Wait --recommend-rationale r --if-you-wait i --source-ref s >/dev/null 2>&1
rc=0
out=$("$DIGEST" --ledger "$LF" --now "$NOW" --period-start "$PERIOD" 2>"$ROOT/fut.err") || rc=$?
check "future created_at decision exits 3" "$rc" "3"
if [[ -z "$out" ]]; then ok "future decision produces no render"; else bad "future decision partially rendered"; fi

echo
echo "=== P1: merge without merged_at never ships; period/stale mutants ==="
cat > "$ROOT/merged-ghost.json" <<EOF
{"schema":"digest-merged-since:v1","repo":"acme/app","as_of":"2026-08-02T00:00:00Z","merges":[{"repo":"acme/app","title":"ghost ship"}]}
EOF
rc=0
"$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --repo acme/app --merged-since "$ROOT/merged-ghost.json" >/dev/null 2>&1 || rc=$?
check "merge missing merged_at exits 3" "$rc" "3"

# Outside-period merge must not increment ship count
cat > "$ROOT/merged-old.json" <<EOF
{"schema":"digest-merged-since:v1","repo":"acme/app","as_of":"2026-08-02T00:00:00Z","merges":[{"repo":"acme/app","title":"ancient ship","merged_at":"2026-01-01T00:00:00Z"}]}
EOF
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --repo acme/app --merged-since "$ROOT/merged-old.json" 2>/dev/null)
contains "outside-period merge not counted" "$out" "Ships this period: 0"
contains "outside-period still quiet week" "$out" "quiet active week"

# Stale merged snapshot as_of before period-start
cat > "$ROOT/merged-stale.json" <<EOF
{"schema":"digest-merged-since:v1","repo":"acme/app","as_of":"2026-07-01T00:00:00Z","merges":[{"repo":"acme/app","title":"should not ship","merged_at":"2026-06-15T00:00:00Z"}]}
EOF
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --repo acme/app --merged-since "$ROOT/merged-stale.json" 2>/dev/null)
contains "stale merged ships 0" "$out" "Ships this period: 0"
contains "stale merged labeled" "$out" "unknown/stale"

# Missing as_of fails closed
cat > "$ROOT/merged-no-asof.json" <<EOF
{"schema":"digest-merged-since:v1","repo":"acme/app","merges":[]}
EOF
rc=0
"$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --merged-since "$ROOT/merged-no-asof.json" >/dev/null 2>&1 || rc=$?
check "merged missing as_of exits 3" "$rc" "3"

# Loop-state before period-start is stale/unknown not healthy
cat > "$ROOT/loop-stale.md" <<'EOF'
# Gibson loop state
updated: 2026-07-01T00:00:00Z
issue: 72
pr:
hat: release
next_hat: historian
round: 1
parked: false
handoff:
handoff_sha:
next_action: queue decision card
notes: test
EOF
out=$("$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
  --loop-state "$ROOT/loop-stale.md" 2>/dev/null)
contains "stale loop not healthy" "$out" "unknown/stale"
lacks "stale loop does not claim hat=release as healthy current" "$out" "Loop health: hat=release"

echo
echo "=== P1: FIFO dry-run no hang (bounded child PID kill) ==="
if mkfifo "$ROOT/out.fifo" 2>/dev/null; then
  # Victim bytes beside the FIFO must remain untouched.
  printf 'VICTIM_UNTOUCHED\n' > "$ROOT/fifo-victim.txt"
  pidfile="$ROOT/digest-fifo.pid"
  (
    "$DIGEST" --ledger "$L" --now "$NOW" --period-start "$PERIOD" \
      --output "$ROOT/out.fifo" --dry-run >/dev/null 2>"$ROOT/fifo.err"
    echo $? > "$ROOT/fifo.rc"
  ) &
  child=$!
  echo "$child" > "$pidfile"
  # Bound: wait up to ~3s for child to exit; kill only that captured PID.
  waited=0
  while [[ $waited -lt 30 ]]; do
    if ! kill -0 "$child" 2>/dev/null; then
      break
    fi
    sleep 0.1 2>/dev/null || sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    bad "FIFO dry-run hung (killed captured pid $child)"
  else
    wait "$child" 2>/dev/null || true
    frc=$(cat "$ROOT/fifo.rc" 2>/dev/null || echo missing)
    if [[ "$frc" == "4" || "$frc" == "3" ]]; then
      ok "FIFO dry-run exits promptly rc=$frc"
    else
      bad "FIFO dry-run rc=$frc want 3 or 4"
    fi
  fi
  v=$(cat "$ROOT/fifo-victim.txt" 2>/dev/null || echo gone)
  check "FIFO dry-run left victim bytes" "$v" "VICTIM_UNTOUCHED"
else
  ok "FIFO skip (mkfifo unavailable)"
fi

echo
echo "=== P1: digest input symlink/FIFO refuse without hang ==="
ln -sfn "$L" "$ROOT/ledger-link.jsonl"
rc=0
"$DIGEST" --ledger "$ROOT/ledger-link.jsonl" --now "$NOW" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 3 ]]; then ok "symlink ledger input exits 3"; else bad "symlink ledger rc=$rc"; fi

echo
echo "=== summary ==="
echo "PASS=$PASS FAIL=$FAIL"
if [[ -s "$FORBIDDEN_LOG" ]]; then
  echo "FORBIDDEN:"; cat "$FORBIDDEN_LOG"
  FAIL=$((FAIL + 1))
fi
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
