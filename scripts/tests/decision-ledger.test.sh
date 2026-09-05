#!/usr/bin/env bash
# decision-ledger.test.sh — offline sensors for scripts/decision-ledger.sh (issue #72)
#
# Network-free, deterministic, Bash 3.2-compatible. Proves PENDING-only ledger
# semantics, stable ids, locks, validation, and that no delivery/approval path runs.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
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
echo "$out" | grep "PENDING" >/dev/null && ok "help mentions PENDING-only" || bad "help missing PENDING"
echo "$out" | grep "EXIT" >/dev/null && ok "help documents exit codes" || bad "help missing EXIT"
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
check "escaped event id length 64" "${#id_esc}" "64"
python3 - "$LE" "$id_esc" <<'PY' && ok "escaped JSON parses with stable id" || bad "escaped JSON broken"
import json,sys
line=open(sys.argv[1]).read().strip()
o=json.loads(line)
assert o["id"] == sys.argv[2]
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
if [[ "$(id -u)" -eq 0 ]]; then
  ok "skip unwritable parent (root can write mode-000)"
  ok "skip ledger mutation check under root"
elif chmod a-w "$ROOT" 2>/dev/null; then
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
echo "$out" | grep "pending:" >/dev/null && ok "status has pending" || bad "status missing pending"
out=$("$TOOL" list --ledger "$L" --format markdown 2>/dev/null)
echo "$out" | grep "WHAT:" >/dev/null && ok "markdown list has WHAT" || bad "markdown missing WHAT"
echo "$out" | grep "IF YOU WAIT:" >/dev/null && ok "markdown list has IF YOU WAIT" || bad "markdown missing IF YOU WAIT"
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
echo "=== P1: forged id / G01 / control-in-top / noncanonical / recomputed id ==="
# Forged 64-hex id that does not match identity tuple
python3 - <<PY
import json
card={"what":"w","why_you":"y","risk_level":"low","risk_consequence":"c","risk_undo":"u",
      "recommend":"Wait","recommend_rationale":"r","if_you_wait":"i","source_ref":"s"}
obj={"schema":"decision-ledger:v1","id":"0"*64,"status":"PENDING","repo":"acme/app","gate":"G1",
     "source_type":"pr","source_id":"1","source_sha":"a"*40,"created_at":"2026-08-01T00:00:00Z","card":card}
open("$ROOT/forged.jsonl","w").write(json.dumps(obj,separators=(",",":"),sort_keys=True)+"\n")
PY
rc=0; "$TOOL" list --ledger "$ROOT/forged.jsonl" >/dev/null 2>&1 || rc=$?
check "forged id exits 3" "$rc" "3"

# G01 stored with matching forged-style id for G01 string — still reject gate form
python3 - <<PY
import hashlib, json
def cid(repo,gate,st,sid,sha):
    c=f"decision-ledger:v1\nrepo={repo}\ngate={gate}\nsource_type={st}\nsource_id={sid}\nsource_sha={sha}\n"
    return hashlib.sha256(c.encode()).hexdigest()
card={"what":"w","why_you":"y","risk_level":"low","risk_consequence":"c","risk_undo":"u",
      "recommend":"Wait","recommend_rationale":"r","if_you_wait":"i","source_ref":"s"}
gate="G01"
obj={"schema":"decision-ledger:v1","id":cid("acme/app",gate,"pr","1","a"*40),"status":"PENDING",
     "repo":"acme/app","gate":gate,"source_type":"pr","source_id":"1","source_sha":"a"*40,
     "created_at":"2026-08-01T00:00:00Z","card":card}
open("$ROOT/g01.jsonl","w").write(json.dumps(obj,separators=(",",":"),sort_keys=True)+"\n")
PY
rc=0; "$TOOL" list --ledger "$ROOT/g01.jsonl" >/dev/null 2>&1 || rc=$?
check "stored G01 gate exits 3" "$rc" "3"

# Control char in top-level source_id
python3 - <<PY
import hashlib, json
def cid(repo,gate,st,sid,sha):
    c=f"decision-ledger:v1\nrepo={repo}\ngate={gate}\nsource_type={st}\nsource_id={sid}\nsource_sha={sha}\n"
    return hashlib.sha256(c.encode()).hexdigest()
sid="x\x07y"
card={"what":"w","why_you":"y","risk_level":"low","risk_consequence":"c","risk_undo":"u",
      "recommend":"Wait","recommend_rationale":"r","if_you_wait":"i","source_ref":"s"}
obj={"schema":"decision-ledger:v1","id":cid("acme/app","G1","pr",sid,"a"*40),"status":"PENDING",
     "repo":"acme/app","gate":"G1","source_type":"pr","source_id":sid,"source_sha":"a"*40,
     "created_at":"2026-08-01T00:00:00Z","card":card}
# noncanonical may also fail; write raw with ensure_ascii escape then re-load would lose control —
# write via json which escapes \u0007 so line is canonical but value has control
open("$ROOT/ctrl_top.jsonl","w").write(json.dumps(obj,separators=(",",":"),sort_keys=True,ensure_ascii=False)+"\n")
PY
rc=0; "$TOOL" list --ledger "$ROOT/ctrl_top.jsonl" >/dev/null 2>&1 || rc=$?
check "control in top-level source_id exits 3" "$rc" "3"

# Noncanonical JSON (spaces after colon)
python3 - <<PY
import hashlib, json
def cid(repo,gate,st,sid,sha):
    c=f"decision-ledger:v1\nrepo={repo}\ngate={gate}\nsource_type={st}\nsource_id={sid}\nsource_sha={sha}\n"
    return hashlib.sha256(c.encode()).hexdigest()
card={"what":"w","why_you":"y","risk_level":"low","risk_consequence":"c","risk_undo":"u",
      "recommend":"Wait","recommend_rationale":"r","if_you_wait":"i","source_ref":"s"}
eid=cid("acme/app","G1","pr","1","a"*40)
# deliberate spaces
line='{"card": {"if_you_wait":"i","recommend":"Wait","recommend_rationale":"r","risk_consequence":"c","risk_level":"low","risk_undo":"u","source_ref":"s","what":"w","why_you":"y"},"created_at":"2026-08-01T00:00:00Z","gate":"G1","id":"%s","repo":"acme/app","schema":"decision-ledger:v1","source_id":"1","source_sha":"%s","source_type":"pr","status":"PENDING"}' % (eid, "a"*40)
open("$ROOT/noncanon.jsonl","w").write(line+"\n")
PY
rc=0; "$TOOL" list --ledger "$ROOT/noncanon.jsonl" >/dev/null 2>&1 || rc=$?
check "noncanonical JSON encoding exits 3" "$rc" "3"

# Missing final newline on otherwise-valid event
python3 - <<PY
import hashlib, json
def cid(repo,gate,st,sid,sha):
    c=f"decision-ledger:v1\nrepo={repo}\ngate={gate}\nsource_type={st}\nsource_id={sid}\nsource_sha={sha}\n"
    return hashlib.sha256(c.encode()).hexdigest()
card={"what":"w","why_you":"y","risk_level":"low","risk_consequence":"c","risk_undo":"u",
      "recommend":"Wait","recommend_rationale":"r","if_you_wait":"i","source_ref":"s"}
obj={"schema":"decision-ledger:v1","id":cid("acme/app","G1","pr","1","a"*40),"status":"PENDING",
     "repo":"acme/app","gate":"G1","source_type":"pr","source_id":"1","source_sha":"a"*40,
     "created_at":"2026-08-01T00:00:00Z","card":card}
open("$ROOT/nofinal.jsonl","wb").write(json.dumps(obj,separators=(",",":"),sort_keys=True).encode())
PY
rc=0; "$TOOL" list --ledger "$ROOT/nofinal.jsonl" >/dev/null 2>&1 || rc=$?
check "valid event missing final newline exits 3" "$rc" "3"

# Invalid UTF-8
printf '\xff\xfe{"schema":"decision-ledger:v1"}\n' > "$ROOT/badutf.jsonl"
rc=0; "$TOOL" list --ledger "$ROOT/badutf.jsonl" >/dev/null 2>&1 || rc=$?
check "invalid UTF-8 exits 3" "$rc" "3"

echo
echo "=== P1: append-only prefix / order / hash fixtures (3+ events) ==="
ORD="$ROOT/order.jsonl"
# Choose source_ids whose ids sort opposite to insert order
python3 - <<'PY' > "$ROOT/sid_order.txt"
import hashlib
sha="a"*40
pairs=[]
for i in range(80):
    c=f"decision-ledger:v1\nrepo=r/r\ngate=G1\nsource_type=pr\nsource_id={i}\nsource_sha={sha}\n"
    pairs.append((hashlib.sha256(c.encode()).hexdigest(), str(i)))
pairs.sort()
# insert high, mid, low hash order
print(pairs[-1][1])
print(pairs[40][1])
print(pairs[0][1])
PY
s_hi=$(sed -n '1p' "$ROOT/sid_order.txt")
s_mid=$(sed -n '2p' "$ROOT/sid_order.txt")
s_lo=$(sed -n '3p' "$ROOT/sid_order.txt")
# Capture progressive content hashes so prefix growth is independently measurable.
prev_hash=""
for sid in "$s_hi" "$s_mid" "$s_lo"; do
  add_ok "$ORD" --repo r/r --gate G1 --source-type pr --source-id "$sid" --source-sha "$SHA_A" \
    >/dev/null 2>&1
  cur_hash=$(python3 - "$ORD" <<'PY'
import hashlib,sys
data=open(sys.argv[1],"rb").read()
print(hashlib.sha256(data).hexdigest())
PY
)
  if [[ -n "$prev_hash" && "$cur_hash" == "$prev_hash" ]]; then
    bad "append did not change ledger content hash for source-id $sid"
  fi
  prev_hash="$cur_hash"
done
# On-disk order must be insert order (hi, mid, lo), NOT sorted by id
python3 - "$ORD" "$s_hi" "$s_mid" "$s_lo" <<'PY' && ok "3-event append order preserved (not sorted by id)" || bad "append reordered events"
import json,sys
path, a,b,c = sys.argv[1:5]
ids=[json.loads(l)["source_id"] for l in open(path) if l.strip()]
assert ids == [a,b,c], ids
# and id order is NOT ascending
eids=[json.loads(l)["id"] for l in open(path) if l.strip()]
assert eids != sorted(eids), "ids happened to sort in insert order; pick different sids"
print("ok")
PY
# Prefix preservation: after each append, prior bytes are exact prefix
python3 - "$ORD" <<'PY' && ok "3-event file is valid JSONL with final newline" || bad "order ledger shape"
import sys
raw=open(sys.argv[1],"rb").read()
assert raw.endswith(b"\n") and not raw.endswith(b"\n\n")
assert raw.count(b"\n")==3
print("ok")
PY
# Fourth append: capture exact bytes before, verify prefix after
cp "$ORD" "$ROOT/pre_bytes.bin"
add_ok "$ORD" --repo r/r --gate G1 --source-type pr --source-id "prefix-check" --source-sha "$SHA_B" \
  >/dev/null 2>&1
python3 - "$ROOT/pre_bytes.bin" "$ORD" <<'PY' && ok "hash-prefix: old bytes exact prefix of new" || bad "hash-prefix failed"
import sys
old=open(sys.argv[1],"rb").read()
new=open(sys.argv[2],"rb").read()
assert new.startswith(old), (len(old), len(new))
assert len(new) > len(old)
print("ok")
PY
# Idempotent retry leaves bytes unchanged
idemp_before=$(shasum -a 256 "$ORD" | awk '{print $1}')
add_ok "$ORD" --repo r/r --gate G1 --source-type pr --source-id "prefix-check" --source-sha "$SHA_B" \
  >/dev/null 2>&1
idemp_after=$(shasum -a 256 "$ORD" | awk '{print $1}')
check "idempotent retry leaves bytes unchanged" "$idemp_before" "$idemp_after"

echo
echo "=== P1: symlink lock never deletes victim pid/bytes ==="
VL="$ROOT/vicledger.jsonl"
add_ok "$VL" --repo acme/app --gate G2 --source-type pr --source-id 99 --source-sha "$SHA_A" \
  >/dev/null 2>&1
mkdir -p "$ROOT/lock_victim"
printf '999999\n' > "$ROOT/lock_victim/pid"
printf 'OWNED_BY_VICTIM\n' > "$ROOT/lock_victim/data"
printf 'tok\n' > "$ROOT/lock_victim/owner"
ln -sfn "$ROOT/lock_victim" "${VL}.lock"
rc=0
DECISION_LEDGER_LOCK_TRIES=3 "$TOOL" list --ledger "$VL" >/dev/null 2>&1 || rc=$?
# Must fail (lock) and preserve every victim byte
if [[ "$rc" -eq 4 || "$rc" -eq 3 ]]; then
  ok "symlinked lock fails closed (rc=$rc)"
else
  bad "symlinked lock rc=$rc want 3 or 4"
fi
if [[ -f "$ROOT/lock_victim/pid" && -f "$ROOT/lock_victim/data" && -f "$ROOT/lock_victim/owner" ]]; then
  vpid=$(cat "$ROOT/lock_victim/pid")
  vdata=$(cat "$ROOT/lock_victim/data")
  if [[ "$vpid" == "999999" && "$vdata" == "OWNED_BY_VICTIM" ]]; then
    ok "symlinked lock did not delete victim pid/data"
  else
    bad "victim contents mutated: pid=$vpid data=$vdata"
  fi
else
  bad "victim files missing after lock attempt"
fi
# list must not leave a real lock dir that replaced the symlink into the victim
if [[ -L "${VL}.lock" ]]; then
  ok "lock path still symlink (not replaced with real dir reclaim)"
else
  bad "lock path no longer symlink"
fi
rm -f "${VL}.lock"

echo
echo "=== P1: ancestor symlink / FIFO leaf refuse ==="
mkdir -p "$ROOT/realdir"
ln -sfn "$ROOT/realdir" "$ROOT/planted_anc"
rc=0
"$TOOL" list --ledger "$ROOT/planted_anc/ledger.jsonl" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 3 || "$rc" -eq 2 ]]; then
  ok "planted ancestor symlink refused (rc=$rc)"
else
  bad "planted ancestor rc=$rc"
fi
if mkfifo "$ROOT/fifo2.jsonl" 2>/dev/null; then
  rc=0
  "$TOOL" add --ledger "$ROOT/fifo2.jsonl" --repo acme/app --gate G1 --source-type pr \
    --source-id fifo --source-sha "$SHA_A" --created-at "$NOW" \
    --what w --why-you y --risk-level low --risk-consequence c --risk-undo u \
    --recommend Wait --recommend-rationale r --if-you-wait i --source-ref s \
    >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 3 || "$rc" -eq 4 ]]; then
    ok "FIFO ledger add refuses without hang (rc=$rc)"
  else
    bad "FIFO add rc=$rc"
  fi
else
  ok "FIFO skip (mkfifo unavailable)"
fi

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
