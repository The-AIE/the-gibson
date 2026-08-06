#!/usr/bin/env bash
# cost-ledger.test.sh — L-003 / #74 cost telemetry sensors
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
CL="$SCRIPT_DIR/../cost-ledger.sh"
PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-cost.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
LEDGER="$ROOT/cost-ledger.jsonl"

echo "help"
out=$("$CL" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'L-003' && ok "help" || bad "help"

echo "append + summarize"
"$CL" append --ledger "$LEDGER" --runner grok --pool flat-rate --hat builder \
  --wall-ms 1200 --flat-rate true --issue 10 --pr 5 --iteration 1 --now 2026-08-06T10:00:00Z
"$CL" append --ledger "$LEDGER" --runner claude --pool metered --hat reviewer \
  --wall-ms 800 --tokens 4000 --issue 10 --pr 5 --iteration 2 --now 2026-08-06T10:05:00Z
[[ -f "$LEDGER" ]] && ok "ledger file created" || bad "no ledger"
lines=$(wc -l < "$LEDGER" | tr -d ' ')
[[ "$lines" = "2" ]] && ok "two JSONL events" || bad "lines=$lines"

out=$("$CL" summarize --ledger "$LEDGER" --format text 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '2 event' && ok "summarize text" || bad "sum (rc=$rc): $out"
echo "$out" | grep -q 'tokens: unknown\|tokens (from' && ok "tokens honesty line" || bad "tokens line: $out"
echo "$out" | grep -q 'flat-rate' && ok "by pool includes flat-rate" || bad "pool: $out"
echo "$out" | grep -q 'metered' && ok "by pool includes metered" || bad "metered: $out"

echo "cost-per-merged-PR"
cat > "$ROOT/merged.json" <<'J'
[{"number":5,"merged_at":"2026-08-06T11:00:00Z"},{"number":6,"merged_at":"2026-08-06T12:00:00Z"}]
J
out=$("$CL" summarize --ledger "$LEDGER" --merged-since "$ROOT/merged.json" --format text 2>&1)
echo "$out" | grep -q 'cost-per-merged-PR (2 merged)' && ok "cpm with 2 merged" || bad "cpm: $out"

out=$("$CL" summarize --ledger "$LEDGER" --merged-since "$ROOT/merged.json" --format json 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'cost_per_merged_pr' && ok "json summary" || bad "json: $out"
# missing tokens must not become 0 on events without tokens — total_tokens only from known
echo "$out" | grep -q '"tokens_known_events": 1' && ok "tokens_known_events=1" || bad "known: $out"

echo "refuse symlink ledger"
ln -s "$LEDGER" "$ROOT/sym.jsonl"
out=$("$CL" append --ledger "$ROOT/sym.jsonl" --runner x --hat y --wall-ms 1 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "symlink ledger refused" || bad "symlink allowed"

echo "corrupt line fails summarize"
echo 'not-json' >> "$LEDGER"
out=$("$CL" summarize --ledger "$LEDGER" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && ok "corrupt JSONL → exit 3" || bad "corrupt rc=$rc: $out"

echo "loop.sh defines cost_ledger_record_iteration"
if grep -q 'cost_ledger_record_iteration' "$SCRIPT_DIR/../loop.sh" \
  && grep -q 'GIBSON_COST_LEDGER' "$SCRIPT_DIR/../loop.sh"; then
  ok "loop.sh cost hook present"
else
  bad "loop.sh missing cost hook"
fi

echo
echo "cost-ledger.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
