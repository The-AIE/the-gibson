#!/usr/bin/env bash
# decision-ledger.test.sh — offline sensors for scripts/decision-ledger.sh (issue #72)
#
# Network-free, deterministic, Bash 3.2-compatible. Proves PENDING-only ledger
# semantics, stable ids, locks, validation, and that no delivery/approval path runs.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
TOOL="$SCRIPT_DIR/../decision-ledger.sh"
PASS=0
FAIL=0

ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-dl-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"
mkdir -p "$BIN"
# Hostile PATH: fake network/delivery tools that must never run.
for cmd in gh hermes mail mailx sendmail curl wget nc ssh openssl-net webhook \
           iMessage osascript open; do
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
# Spin budget: high enough for concurrent writers; held-lock test overrides lower.
export DECISION_LEDGER_LOCK_TRIES=200

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
NOW="2026-08-01T12:00:00Z"

# Portable card flags (Bash 3.2 — no arrays of arrays). Call as:
#   add_ok "$ledger" --repo … --gate … --source-type … --source-id … --source-sha … 
# and card fields are appended by add_card unless ADD_NO_CARD=1.
add_ok() {
  local ledger="$1"; shift
  if [[ "${ADD_NO_CARD:-0}" == "1" ]]; then
    "$TOOL" add --ledger "$ledger" --created-at "$NOW" "$@"
  else
    "$TOOL" add --ledger "$ledger" --created-at "$NOW" "$@" \
      --what "Ready to accept a change that touches sign-in." \
      --why-you "Login and security changes always need the owner." \
      --risk-level medium \
      --risk-consequence "A bug could lock people out" \
      --risk-undo "Roll back the deploy in about a minute" \
      --recommend Approve \
      --recommend-rationale "Tests and two reviewers signed off" \
      --if-you-wait "The change stays off the live site. Other work continues." \
      --source-ref "PR #42 at tip"
  fi
}

echo "=== help / usage ==="
out=$("$TOOL" --help 2>&1) || true
echo "$out" | grep -q "PENDING" && ok "help mentions PENDING-only" || bad "help missing PENDING"
echo "$out" | grep -q "EXIT" && ok "help documents exit codes" || bad "help missing EXIT"
rc=0; "$TOOL" 2>/dev/null || rc=$?
check "no-args exits 2" "$rc" "2"

echo
echo "=== stable id + idempotent retry ==="
L="$ROOT/l1.jsonl"
id1=$(add_ok "$L" --repo acme/app --gate G12 --source-type pr --source-id 42 --source-sha "$SHA_A" 2>/dev/null)
id2=$(add_ok "$L" --repo acme/app --gate G12 --source-type pr --source-id 42 --source-sha "$SHA_A" 2>/dev/null)
check "stable id length 64" "${#id1}" "64"
check "retry same id" "$id1" "$id2"
lines=$(wc -l < "$L" | tr -d '[:space:]')
check "one line after retry" "$lines" "1"
# deterministic: recompute expected via second ledger
L2="$ROOT/l1b.jsonl"
id3=$(add_ok "$L2" --repo acme/app --gate G12 --source-type pr --source-id 42 --source-sha "$SHA_A" 2>/dev/null)
check "id deterministic across ledgers" "$id1" "$id3"

echo
echo "=== conflicting duplicate refusal ==="
rc=0
ADD_NO_CARD=1 add_ok "$L" --repo acme/app --gate G12 --source-type pr --source-id 42 --source-sha "$SHA_A" \
  --what "DIFFERENT decision text" \
  --why-you "Login and security changes always need the owner." \
  --risk-level medium --risk-consequence "A bug could lock people out" \
  --risk-undo "Roll back the deploy in about a minute" \
  --recommend Approve --recommend-rationale "Tests and two reviewers signed off" \
  --if-you-wait "The change stays off the live site. Other work continues." \
  --source-ref "PR #42 at tip" 2>/dev/null || rc=$?
check "conflict exits 3" "$rc" "3"
lines=$(wc -l < "$L" | tr -d '[:space:]')
check "conflict leaves one line" "$lines" "1"

echo
echo "=== all gates G1-G16 accepted; G0/G17/case rejected ==="
LG="$ROOT/gates.jsonl"
for g in $(seq 1 16); do
  rc=0
  add_ok "$LG" --repo acme/app --gate "G$g" --source-type manual --source-id "g$g" --source-sha "$SHA_A" \
    >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then ok "G$g accepted"; else bad "G$g rejected (rc=$rc)"; fi
done
for badg in G0 G17 g12 G01 GX G; do
  rc=0
  add_ok "$ROOT/badg.jsonl" --repo acme/app --gate "$badg" --source-type pr --source-id 1 --source-sha "$SHA_A" \
    >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then ok "gate $badg rejected (2)"; else bad "gate $badg rc=$rc want 2"; fi
done

echo
echo "=== repo / source / SHA / time validation ==="
rc=0
add_ok "$ROOT/badrepo.jsonl" --repo "../evil/x" --gate G1 --source-type pr --source-id 1 --source-sha "$SHA_A" \
  >/dev/null 2>&1 || rc=$?
check "path-like repo rejected" "$rc" "2"
rc=0
add_ok "$ROOT/badsha.jsonl" --repo acme/app --gate G1 --source-type pr --source-id 1 --source-sha "deadbeef" \
  >/dev/null 2>&1 || rc=$?
check "short sha rejected" "$rc" "2"
rc=0
add_ok "$ROOT/badsha2.jsonl" --repo acme/app --gate G1 --source-type pr --source-id 1 \
  --source-sha "gggggggggggggggggggggggggggggggggggggggg" >/dev/null 2>&1 || rc=$?
check "non-hex sha rejected" "$rc" "2"
rc=0
ADD_NO_CARD=1 "$TOOL" add --ledger "$ROOT/badts.jsonl" --created-at "2026-02-31T00:00:00Z" \
  --repo acme/app --gate G1 --source-type pr --source-id 1 --source-sha "$SHA_A" \
  --what "w" --why-you "y" --risk-level low --risk-consequence "c" --risk-undo "u" \
  --recommend Wait --recommend-rationale "r" --if-you-wait "i" --source-ref "s" \
  >/dev/null 2>&1 || rc=$?
check "impossible calendar ts rejected" "$rc" "2"
rc=0
add_ok "$ROOT/badst.jsonl" --repo acme/app --gate G1 --source-type pull-request --source-id 1 --source-sha "$SHA_A" \
  >/dev/null 2>&1 || rc=$?
check "invalid source-type rejected" "$rc" "2"

echo
echo "=== JSON escaping (quotes, backslash, unicode) ==="
LE="$ROOT/escape.jsonl"
id_esc=$(ADD_NO_CARD=1 add_ok "$LE" --repo acme/app --gate G5 --source-type issue --source-id 7 --source-sha "$SHA_B" \
  --what 'Say "hello" and use \ backslash' \
  --why-you "Spend needs owner" \
  --risk-level low --risk-consequence "Money spent" --risk-undo "Cancel plan" \
  --recommend Decline --recommend-rationale "Wait for budget" \
  --if-you-wait "No spend occurs" --source-ref 'issue #7 "billing"' 2>/dev/null)
python3 - "$LE" <<'PY' && ok "escaped JSON parses" || bad "escaped JSON broken"
import json,sys
line=open(sys.argv[1]).read().strip()
o=json.loads(line)
assert '"hello"' in o["card"]["what"]
assert "\\" in o["card"]["what"] or "backslash" in o["card"]["what"]
print("ok")
PY

echo
echo "=== long / control / newline / injection inputs ==="
long=$(python3 -c 'print("x"*5000)')
rc=0
ADD_NO_CARD=1 add_ok "$ROOT/long.jsonl" --repo acme/app --gate G1 --source-type pr --source-id 1 --source-sha "$SHA_A" \
  --what "$long" --why-you "y" --risk-level low --risk-consequence "c" --risk-undo "u" \
  --recommend Wait --recommend-rationale "r" --if-you-wait "w" --source-ref "s" >/dev/null 2>&1 || rc=$?
check "overlong scalar rejected" "$rc" "2"
rc=0
ADD_NO_CARD=1 add_ok "$ROOT/nl.jsonl" --repo acme/app --gate G1 --source-type pr --source-id 1 --source-sha "$SHA_A" \
  --what $'line1\nline2' --why-you "y" --risk-level low --risk-consequence "c" --risk-undo "u" \
  --recommend Wait --recommend-rationale "r" --if-you-wait "w" --source-ref "s" >/dev/null 2>&1 || rc=$?
check "newline in what rejected" "$rc" "2"
rc=0
ADD_NO_CARD=1 add_ok "$ROOT/ctrl.jsonl" --repo acme/app --gate G1 --source-type pr --source-id 1 --source-sha "$SHA_A" \
  --what $'bell\a' --why-you "y" --risk-level low --risk-consequence "c" --risk-undo "u" \
  --recommend Wait --recommend-rationale "r" --if-you-wait "w" --source-ref "s" >/dev/null 2>&1 || rc=$?
check "control char rejected" "$rc" "2"
rc=0
ADD_NO_CARD=1 add_ok "$ROOT/inj.jsonl" --repo acme/app --gate G1 --source-type pr --source-id '$(reboot)' --source-sha "$SHA_A" \
  --what '; rm -rf /' --why-you 'y' --risk-level low --risk-consequence 'c' --risk-undo 'u' \
  --recommend Wait --recommend-rationale 'r' --if-you-wait 'w' --source-ref 's' >/dev/null 2>&1 || rc=$?
# injection-looking text as data is OK if no control chars — must NOT execute
if [[ "$rc" -eq 0 ]]; then
  ok "injection-like text stored as data (no exec)"
  # prove shell didn't expand — source_id literal
  grep -q '$(reboot)' "$ROOT/inj.jsonl" && ok "literal \$(reboot) in ledger" || bad "source_id mangled"
else
  # also acceptable if we refuse $() as a hard pattern — but we treat as data
  bad "injection-like scalar unexpectedly rejected (rc=$rc)"
fi

echo
echo "=== secrets refused ==="
rc=0
ADD_NO_CARD=1 add_ok "$ROOT/sec.jsonl" --repo acme/app --gate G1 --source-type pr --source-id 1 --source-sha "$SHA_A" \
  --what "key is sk-abcdefghijklmnopqrstuvwxyz0123456789" --why-you "y" \
  --risk-level low --risk-consequence "c" --risk-undo "u" \
  --recommend Wait --recommend-rationale "r" --if-you-wait "w" --source-ref "s" >/dev/null 2>&1 || rc=$?
check "openai-like secret value rejected" "$rc" "2"

echo
echo "=== malformed / truncated / noncanonical / unknown-schema JSONL ==="
printf '%s\n' '{"schema":"decision-ledger:v1","id":"ab"}' > "$ROOT/mal.jsonl"
rc=0; "$TOOL" list --ledger "$ROOT/mal.jsonl" >/dev/null 2>&1 || rc=$?
check "malformed event exits 3" "$rc" "3"
printf '%s' '{"schema":"decision-ledger:v1","id":"' > "$ROOT/trunc.jsonl"
rc=0; "$TOOL" list --ledger "$ROOT/trunc.jsonl" >/dev/null 2>&1 || rc=$?
check "truncated JSONL exits 3" "$rc" "3"
printf '%s\n' '{"schema":"other:v0","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"PENDING","repo":"a/b","gate":"G1","source_type":"pr","source_id":"1","source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","created_at":"2026-08-01T00:00:00Z","card":{"what":"w","why_you":"y","risk_level":"low","risk_consequence":"c","risk_undo":"u","recommend":"Wait","recommend_rationale":"r","if_you_wait":"i","source_ref":"s"}}' > "$ROOT/uschema.jsonl"
rc=0; "$TOOL" list --ledger "$ROOT/uschema.jsonl" >/dev/null 2>&1 || rc=$?
check "unknown schema exits 3" "$rc" "3"

# duplicate conflicting lines
id_fixed="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
line_a='{"card":{"if_you_wait":"i","recommend":"Wait","recommend_rationale":"r","risk_consequence":"c","risk_level":"low","risk_undo":"u","source_ref":"s","what":"one","why_you":"y"},"created_at":"2026-08-01T00:00:00Z","gate":"G1","id":"'"$id_fixed"'","repo":"acme/app","schema":"decision-ledger:v1","source_id":"1","source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_type":"pr","status":"PENDING"}'
line_b='{"card":{"if_you_wait":"i","recommend":"Wait","recommend_rationale":"r","risk_consequence":"c","risk_level":"low","risk_undo":"u","source_ref":"s","what":"two","why_you":"y"},"created_at":"2026-08-01T00:00:00Z","gate":"G1","id":"'"$id_fixed"'","repo":"acme/app","schema":"decision-ledger:v1","source_id":"1","source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_type":"pr","status":"PENDING"}'
printf '%s\n%s\n' "$line_a" "$line_b" > "$ROOT/dupconf.jsonl"
rc=0; "$TOOL" list --ledger "$ROOT/dupconf.jsonl" >/dev/null 2>&1 || rc=$?
check "duplicate conflicting lines exit 3" "$rc" "3"

# non-PENDING status refused
line_appr='{"card":{"if_you_wait":"i","recommend":"Approve","recommend_rationale":"r","risk_consequence":"c","risk_level":"low","risk_undo":"u","source_ref":"s","what":"w","why_you":"y"},"created_at":"2026-08-01T00:00:00Z","gate":"G1","id":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","repo":"acme/app","schema":"decision-ledger:v1","source_id":"9","source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_type":"pr","status":"APPROVED"}'
printf '%s\n' "$line_appr" > "$ROOT/approved.jsonl"
rc=0; "$TOOL" list --ledger "$ROOT/approved.jsonl" >/dev/null 2>&1 || rc=$?
check "APPROVED status fails closed" "$rc" "3"

echo
echo "=== symlink / FIFO / directory / unwritable target ==="
mkdir -p "$ROOT/dirled"
rc=0; "$TOOL" list --ledger "$ROOT/dirled" >/dev/null 2>&1 || rc=$?
check "directory ledger exits 3" "$rc" "3"
ln -s "$L" "$ROOT/sym.ledger"
rc=0; "$TOOL" list --ledger "$ROOT/sym.ledger" >/dev/null 2>&1 || rc=$?
check "symlink ledger exits 3" "$rc" "3"
if mkfifo "$ROOT/fifo.ledger" 2>/dev/null; then
  # Must refuse without opening the FIFO for read (open would block forever).
  rc=0
  "$TOOL" list --ledger "$ROOT/fifo.ledger" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 3 ]]; then ok "FIFO ledger exits 3"; else bad "FIFO rc=$rc want 3"; fi
else
  ok "FIFO skip (mkfifo unavailable)"
fi

echo
echo "=== held lock / concurrent append ==="
LOCKL="$ROOT/lockme.jsonl"
add_ok "$LOCKL" --repo acme/app --gate G3 --source-type pr --source-id 3 --source-sha "$SHA_A" \
  >/dev/null 2>&1
mkdir "${LOCKL}.lock"
# Use current shell pid to simulate live holder
# Held by a live process: tiny spin budget must fail closed (exit 4), not hang.
sleep 120 &
holder=$!
printf '%s\n' "$holder" > "${LOCKL}.lock/pid"
rc=0
DECISION_LEDGER_LOCK_TRIES=5 add_ok "$LOCKL" --repo acme/app --gate G4 \
  --source-type pr --source-id 4 --source-sha "$SHA_A" \
  >/dev/null 2>&1 || rc=$?
check "held lock exits 4" "$rc" "4"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
rm -f "${LOCKL}.lock/pid"; rmdir "${LOCKL}.lock" 2>/dev/null || true

# concurrent appends of different ids (serialize via mkdir lock)
CL="$ROOT/concurrent.jsonl"
: > "$CL"
pids=""
for i in 1 2 3 4 5; do
  (
    add_ok "$CL" --repo acme/app --gate G1 --source-type pr --source-id "c$i" --source-sha "$SHA_A" \
      >/dev/null 2>&1
  ) &
  pids="$pids $!"
done
fail_conc=0
for p in $pids; do
  if ! wait "$p"; then fail_conc=$((fail_conc + 1)); fi
done
n=$(wc -l < "$CL" | tr -d '[:space:]')
if [[ "$n" -eq 5 && "$fail_conc" -eq 0 ]]; then
  ok "concurrent appends preserved 5 events"
else
  bad "concurrent append count=$n fail_conc=$fail_conc want 5/0"
fi
rc=0; "$TOOL" list --ledger "$CL" >/dev/null 2>&1 || rc=$?
check "concurrent ledger still validates" "$rc" "0"

echo
echo "=== interrupted-temp preservation ==="
# Seed ledger, then simulate: failed write must not truncate existing bytes
IT="$ROOT/interrupt.jsonl"
add_ok "$IT" --repo acme/app --gate G6 --source-type pr --source-id 6 --source-sha "$SHA_A" \
  >/dev/null 2>&1
before=$(cat "$IT")
# Create a temp sibling that looks like our mktemp pattern — writer should not delete ledger
: > "$ROOT/.interrupt.jsonl.FAKE"
# Failed write path: make parent unwritable briefly if possible
if chmod a-w "$ROOT" 2>/dev/null; then
  rc=0
  add_ok "$IT" --repo acme/app --gate G7 --source-type pr --source-id 7 --source-sha "$SHA_A" \
    >/dev/null 2>&1 || rc=$?
  chmod u+w "$ROOT" 2>/dev/null || true
  after=$(cat "$IT")
  if [[ "$before" == "$after" ]]; then ok "failed write preserved ledger bytes"; else bad "ledger mutated on write failure"; fi
  if [[ "$rc" -ne 0 ]]; then ok "unwritable parent fails non-zero"; else bad "unwritable parent wrongly succeeded"; fi
else
  ok "skip unwritable parent (chmod not permitted)"
fi

echo
echo "=== forbidden commands never run; no auto-approve path ==="
rc=0; "$TOOL" approve --ledger "$L" 2>/dev/null || rc=$?
check "approve command exits 2" "$rc" "2"
rc=0; "$TOOL" ingest --ledger "$L" 2>/dev/null || rc=$?
check "ingest command exits 2" "$rc" "2"
rc=0; "$TOOL" add --ledger "$L" --status APPROVED --repo a/b --gate G1 2>/dev/null || rc=$?
check "--status option exits 2" "$rc" "2"
if [[ ! -s "$FORBIDDEN_LOG" ]]; then
  ok "no forbidden commands invoked"
else
  bad "forbidden commands ran: $(cat "$FORBIDDEN_LOG")"
fi

echo
echo "=== list/status formats ==="
out=$("$TOOL" status --ledger "$L" 2>/dev/null)
echo "$out" | grep -q "pending:" && ok "status has pending" || bad "status missing pending"
out=$("$TOOL" list --ledger "$L" --format markdown 2>/dev/null)
echo "$out" | grep -q "WHAT:" && ok "markdown list has WHAT" || bad "markdown missing WHAT"
echo "$out" | grep -q "IF YOU WAIT:" && ok "markdown list has IF YOU WAIT" || bad "markdown missing IF YOU WAIT"
out=$("$TOOL" list --ledger "$L" --format json 2>/dev/null)
python3 -c 'import json,sys; o=json.loads(sys.stdin.read()); assert o["schema"]=="decision-ledger-list:v1"' <<<"$out" \
  && ok "json list schema" || bad "json list schema"

echo
echo "=== mutation: cannot record approval via add ==="
# status field is always PENDING — prove by inspecting event
python3 - "$L" <<'PY' && ok "all events PENDING" || bad "non-PENDING slipped in"
import json,sys
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    o=json.loads(line)
    assert o["status"]=="PENDING", o
print("ok")
PY

echo
echo "=== summary ==="
echo "PASS=$PASS FAIL=$FAIL"
if [[ ! -s "$FORBIDDEN_LOG" ]]; then
  :
else
  echo "FORBIDDEN LOG:"; cat "$FORBIDDEN_LOG"
  FAIL=$((FAIL + 1))
fi
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
