#!/usr/bin/env bash
# cost-ledger.test.sh — L-003 / #74 / #141 cost telemetry sensors
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
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
echo "$out" | grep -q 'join-key\|join_key' && ok "help documents join-key" || bad "help missing join-key"
echo "$out" | grep -q 'merged-json' && ok "help documents --merged-json" || bad "help missing merged-json"

echo "append + summarize (legacy rows)"
rm -f "$LEDGER"
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

echo "honest cost-per-merged-PR (legacy pr field)"
cat > "$ROOT/merged.json" <<'J'
[{"number":5,"merged_at":"2026-08-06T11:00:00Z"},{"number":6,"merged_at":"2026-08-06T12:00:00Z"}]
J
out=$("$CL" summarize --ledger "$LEDGER" --merged-json "$ROOT/merged.json" --format text 2>&1)
# Both events have pr=5; PR 6 has no cost data — not zero-cost success.
echo "$out" | grep -qE '1 of 2 merged PRs with cost data' \
  && ok "cpm reports 1 of 2 with cost data" || bad "cpm: $out"
echo "$out" | grep -q 'PR #6: no attributed events' \
  && ok "merged PR without cost not zero-success" || bad "pr6 line: $out"
echo "$out" | grep -q 'PR #5: events=2' \
  && ok "merged PR #5 has 2 events" || bad "pr5 line: $out"

out=$("$CL" summarize --ledger "$LEDGER" --merged-json "$ROOT/merged.json" --format json 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'cost_per_merged_pr' && ok "json summary" || bad "json: $out"
echo "$out" | grep -q '"tokens_known_events": 1' && ok "tokens_known_events=1" || bad "known: $out"
echo "$out" | grep -q '"merged_prs_with_cost": 1' && ok "json merged_prs_with_cost=1" || bad "mwc: $out"
echo "$out" | grep -q '"merged_events": 2' && ok "json merged_events=2" || bad "me: $out"
# Incomplete coverage: total_tokens must be null (not a partial sum presented as total)
py_tt=$(python3 -c '
import json,sys
s=json.loads(sys.argv[1])
assert s.get("tokens_coverage_complete") is False, s
assert s.get("total_tokens") is None, s
assert s.get("tokens_known_sum") == 4000, s
assert s.get("tokens_known_events") == 1 and s.get("tokens_total_events") == 2, s
print("ok")
' "$out" 2>&1) || true
[[ "$py_tt" == "ok" ]] && ok "json total_tokens null on incomplete coverage" || bad "total_tokens honesty: $py_tt out=$out"
# --merged-since alias still works
out=$("$CL" summarize --ledger "$LEDGER" --merged-since "$ROOT/merged.json" --format text 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'cost-per-merged-PR' && ok "merged-since alias" || bad "alias: $out"

echo "optional join fields on append"
rm -f "$LEDGER"
SPACE_LEDGER="$ROOT/dir with spaces/cost ledger.jsonl"
mkdir -p "$ROOT/dir with spaces"
"$CL" append --ledger "$SPACE_LEDGER" --runner "fallback-y" --pool "flat-rate-grok" \
  --hat runner-selection --wall-ms 40 --join-key "fleet-sel:v1:p:docs:primary-x:fallback-y:20260806T100000Z" \
  --requested-runner "primary-x" --provider grok --fallback-reason "primary_not_ready:primary-x=not_ready;selected_fallback" \
  --event-kind selection --issue 502 --repo "acme/widget" --now 2026-08-06T10:00:00Z
"$CL" append --ledger "$SPACE_LEDGER" --runner "fallback-y" --pool "flat-rate-grok" \
  --hat builder --wall-ms 1500 --join-key "fleet-sel:v1:p:docs:primary-x:fallback-y:20260806T100000Z" \
  --requested-runner "primary-x" --provider grok --fallback-reason "primary_not_ready:primary-x=not_ready;selected_fallback" \
  --event-kind iteration --issue 502 --pr 88 --iteration 1 --repo "acme/widget" \
  --now 2026-08-06T10:10:00Z
# Unmerged legacy row (no join, other PR)
"$CL" append --ledger "$SPACE_LEDGER" --runner claude --pool metered --hat reviewer \
  --wall-ms 900 --issue 9 --pr 77 --iteration 1 --now 2026-08-06T10:20:00Z
# Selection-only join for another key never merged
"$CL" append --ledger "$SPACE_LEDGER" --runner grind-a --pool other --hat runner-selection \
  --wall-ms 10 --join-key "fleet-sel:v1:p:docs:grind-a:grind-a:20260806T090000Z" \
  --requested-runner grind-a --provider other --fallback-reason primary_ready \
  --event-kind selection --issue 501 --now 2026-08-06T09:00:00Z

line1=$(head -1 "$SPACE_LEDGER")
echo "$line1" | grep -q '"join_key":"fleet-sel:v1:p:docs:primary-x:fallback-y:20260806T100000Z"' \
  && ok "append join_key" || bad "line1 join: $line1"
echo "$line1" | grep -q '"requested_runner":"primary-x"' \
  && ok "append requested_runner" || bad "line1 req: $line1"
echo "$line1" | grep -q '"event_kind":"selection"' \
  && ok "append event_kind selection" || bad "line1 kind: $line1"
echo "$line1" | grep -qE '"tokens"' \
  && bad "selection row must not invent tokens: $line1" \
  || ok "selection row has no tokens"

echo "join-key merge attribution"
cat > "$ROOT/merged-join.json" <<'J'
[{"number":88,"merged_at":"2026-08-06T12:00:00Z"}]
J
out=$("$CL" summarize --ledger "$SPACE_LEDGER" --merged-json "$ROOT/merged-join.json" --format json 2>&1); rc=$?
[[ "$rc" -eq 0 ]] || bad "join summarize failed rc=$rc: $out"
# Selection (no pr) + iteration (pr=88) share join_key → both merged; pr=77 unmerged; other selection unmerged
echo "$out" | grep -q '"merged_events": 2' && ok "join maps selection+iteration as merged" || bad "merged_events: $out"
echo "$out" | grep -q '"unmerged_events": 2' && ok "unmerged events counted" || bad "unmerged: $out"
echo "$out" | grep -q '"merged_prs_with_cost": 1' && ok "one merged PR with cost" || bad "mwc join: $out"
# wall for merged = 40 + 1500 = 1540
echo "$out" | grep -q '"merged_wall_ms": 1540' && ok "merged wall_ms via join" || bad "mwall: $out"
text=$("$CL" summarize --ledger "$SPACE_LEDGER" --merged-json "$ROOT/merged-join.json" --format text 2>&1)
echo "$text" | grep -q 'PR #88: events=2' && ok "text per-PR via join" || bad "text pr88: $text"

echo "unmerged-only outcome"
cat > "$ROOT/merged-none.json" <<'J'
[{"number":999,"merged_at":"2026-08-06T12:00:00Z"}]
J
out=$("$CL" summarize --ledger "$SPACE_LEDGER" --merged-json "$ROOT/merged-none.json" --format text 2>&1); rc=$?
[[ "$rc" -eq 0 ]] || bad "unmerged summarize rc=$rc"
echo "$out" | grep -q '0 of 1 merged PRs with cost data' \
  && ok "unmerged outcome not zero-cost" || bad "unmerged text: $out"
echo "$out" | grep -q 'PR #999: no attributed events' \
  && ok "unknown merged PR lacks cost data" || bad "pr999: $out"

echo "malformed inputs fail closed"
echo 'not-json' > "$ROOT/bad-merged.json"
out=$("$CL" summarize --ledger "$SPACE_LEDGER" --merged-json "$ROOT/bad-merged.json" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && ok "bad merged JSON → exit 3" || bad "bad merged rc=$rc: $out"

cat > "$ROOT/bad-shape.json" <<'J'
{"number":1}
J
out=$("$CL" summarize --ledger "$SPACE_LEDGER" --merged-json "$ROOT/bad-shape.json" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && ok "merged object (not array) → exit 3" || bad "shape rc=$rc: $out"

cat > "$ROOT/dup-merged.json" <<'J'
[{"number":1},{"number":1}]
J
out=$("$CL" summarize --ledger "$SPACE_LEDGER" --merged-json "$ROOT/dup-merged.json" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && ok "duplicate merged PR → exit 3" || bad "dup rc=$rc: $out"

cat > "$ROOT/bad-num.json" <<'J'
[{"number":"five"}]
J
out=$("$CL" summarize --ledger "$SPACE_LEDGER" --merged-json "$ROOT/bad-num.json" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && ok "non-integer merged number → exit 3" || bad "num rc=$rc: $out"

# Ambiguous join_key → two different PRs
AMB="$ROOT/ambiguous.jsonl"
"$CL" append --ledger "$AMB" --runner a --pool p --hat builder --wall-ms 1 \
  --join-key same-key --pr 1 --now 2026-08-06T10:00:00Z
"$CL" append --ledger "$AMB" --runner a --pool p --hat builder --wall-ms 1 \
  --join-key same-key --pr 2 --now 2026-08-06T10:01:00Z
cat > "$ROOT/merged-amb.json" <<'J'
[{"number":1},{"number":2}]
J
out=$("$CL" summarize --ledger "$AMB" --merged-json "$ROOT/merged-amb.json" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && echo "$out" | grep -qi ambiguous \
  && ok "ambiguous join_key → exit 3" || bad "amb rc=$rc: $out"

# Direct-PR vs join-map: any same join_key with two different PRs is caught
# at map-build time as "ambiguous join_key" (above). A separate resolved_pr
# conflict branch is unreachable once the map is consistent — removed in
# cost-ledger.sh; the ambiguous sensor is the sole contract for this case.

# Newline in join-key refused
out=$("$CL" append --ledger "$LEDGER" --runner x --hat y --wall-ms 1 \
  --join-key $'bad\nkey' 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && ok "newline join-key refused" || bad "nl join rc=$rc: $out"

out=$("$CL" append --ledger "$LEDGER" --runner x --hat y --wall-ms 1 \
  --event-kind weird 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && ok "bad event-kind refused" || bad "kind rc=$rc: $out"

echo "refuse symlink ledger"
ln -s "$SPACE_LEDGER" "$ROOT/sym.jsonl"
out=$("$CL" append --ledger "$ROOT/sym.jsonl" --runner x --hat y --wall-ms 1 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "symlink ledger refused" || bad "symlink allowed"

echo "corrupt line fails summarize"
echo 'not-json' >> "$SPACE_LEDGER"
out=$("$CL" summarize --ledger "$SPACE_LEDGER" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && ok "corrupt JSONL → exit 3" || bad "corrupt rc=$rc: $out"

echo "loop.sh defines cost_ledger_record_iteration + join env"
if grep -q 'cost_ledger_record_iteration' "$SCRIPT_DIR/../loop.sh" \
  && grep -q 'GIBSON_COST_LEDGER' "$SCRIPT_DIR/../loop.sh"; then
  ok "loop.sh cost hook present"
else
  bad "loop.sh missing cost hook"
fi
if grep -q 'GIBSON_COST_JOIN_KEY' "$SCRIPT_DIR/../loop.sh" \
  && grep -q -- '--join-key' "$SCRIPT_DIR/../loop.sh" \
  && grep -q 'GIBSON_COST_FALLBACK_REASON' "$SCRIPT_DIR/../loop.sh" \
  && grep -q 'GIBSON_COST_REQUESTED_RUNNER' "$SCRIPT_DIR/../loop.sh" \
  && grep -q 'GIBSON_COST_PROVIDER' "$SCRIPT_DIR/../loop.sh"; then
  ok "loop.sh propagates join fields"
else
  bad "loop.sh missing join field propagation"
fi

echo "cost_ledger_record_iteration is top-level (not only on SCRIPT_DIR silent-noop branch)"
# Regression: #74 left the function body inside the silent-noop elif, so the
# normal $GIBSON/scripts path never defined it. Structure probe: the function
# definition must appear AFTER the silent-noop fi, not before it.
fn_line=$(grep -n '^cost_ledger_record_iteration()' "$SCRIPT_DIR/../loop.sh" | head -1 | cut -d: -f1)
# function def line must be after "die missing silent-noop"
die_line=$(grep -n 'missing silent-noop.sh' "$SCRIPT_DIR/../loop.sh" | head -1 | cut -d: -f1)
call_line=$(grep -n 'cost_ledger_record_iteration "' "$SCRIPT_DIR/../loop.sh" | head -1 | cut -d: -f1)
if [[ -n "$fn_line" && -n "$die_line" && "$fn_line" -gt "$die_line" ]]; then
  ok "function defined after silent-noop load ($fn_line > $die_line)"
else
  bad "function nested or missing (fn=$fn_line die=$die_line)"
fi
if [[ -n "$call_line" && -n "$fn_line" && "$call_line" -gt "$fn_line" ]]; then
  ok "call site after definition ($call_line > $fn_line)"
else
  bad "call site missing or before def (call=$call_line fn=$fn_line)"
fi
# Call must not sit under L-008 startup before the main loop
if grep -n 'Cost meter' "$SCRIPT_DIR/../loop.sh" | grep -q .; then
  meter_line=$(grep -n 'Cost meter' "$SCRIPT_DIR/../loop.sh" | head -1 | cut -d: -f1)
  loop_line=$(grep -n '^while true; do' "$SCRIPT_DIR/../loop.sh" | head -1 | cut -d: -f1)
  if [[ -n "$meter_line" && -n "$loop_line" && "$meter_line" -gt "$loop_line" ]]; then
    ok "cost meter runs inside main loop ($meter_line > $loop_line)"
  else
    bad "cost meter outside main loop (meter=$meter_line loop=$loop_line)"
  fi
else
  bad "Cost meter comment missing"
fi

echo "loop-fleet wires selection into cost-ledger"
if grep -q 'fleet_cost_ledger_path' "$SCRIPT_DIR/../loop-fleet.sh" \
  && grep -q 'GIBSON_COST_JOIN_KEY' "$SCRIPT_DIR/../loop-fleet.sh" \
  && grep -q 'event-kind selection' "$SCRIPT_DIR/../loop-fleet.sh" \
  && grep -q 'write_runner_selection_telemetry' "$SCRIPT_DIR/../loop-fleet.sh"; then
  ok "loop-fleet selection→cost-ledger wiring present"
else
  bad "loop-fleet missing cost-ledger join wiring"
fi

echo "per-pool merged outcomes (two pools, mixed joins)"
POOL_LEDGER="$ROOT/by-pool.jsonl"
rm -f "$POOL_LEDGER"
# Pool A: selection + iteration → merged PR 10; plus unmerged iteration
"$CL" append --ledger "$POOL_LEDGER" --runner grind-a --pool provider-grind-a \
  --hat runner-selection --wall-ms 50 --join-key join-a --event-kind selection \
  --issue 1 --now 2026-08-06T10:00:00Z
"$CL" append --ledger "$POOL_LEDGER" --runner grind-a --pool provider-grind-a \
  --hat builder --wall-ms 1000 --join-key join-a --event-kind iteration \
  --issue 1 --pr 10 --tokens 2000 --now 2026-08-06T10:05:00Z
"$CL" append --ledger "$POOL_LEDGER" --runner grind-a --pool provider-grind-a \
  --hat builder --wall-ms 400 --join-key join-a-open --event-kind iteration \
  --issue 2 --pr 11 --now 2026-08-06T10:10:00Z
# Pool B: selection + iteration → merged PR 20 (complete tokens); selection only unmerged
"$CL" append --ledger "$POOL_LEDGER" --runner frontier-b --pool provider-frontier-b \
  --hat runner-selection --wall-ms 30 --join-key join-b --event-kind selection \
  --issue 3 --now 2026-08-06T10:15:00Z
"$CL" append --ledger "$POOL_LEDGER" --runner frontier-b --pool provider-frontier-b \
  --hat builder --wall-ms 2000 --join-key join-b --event-kind iteration \
  --issue 3 --pr 20 --tokens 5000 --now 2026-08-06T10:20:00Z
"$CL" append --ledger "$POOL_LEDGER" --runner frontier-b --pool provider-frontier-b \
  --hat runner-selection --wall-ms 20 --join-key join-b-only --event-kind selection \
  --issue 4 --now 2026-08-06T10:25:00Z
cat > "$ROOT/merged-pools.json" <<'J'
[{"number":10},{"number":20}]
J
out=$("$CL" summarize --ledger "$POOL_LEDGER" --merged-json "$ROOT/merged-pools.json" --format json 2>&1); rc=$?
[[ "$rc" -eq 0 ]] || bad "by-pool summarize rc=$rc: $out"
# Extract by_pool via python for structural asserts
py_out=$(python3 -c '
import json,sys
s=json.loads(sys.argv[1])
bp=s["by_pool"]
a=bp["provider-grind-a"]
b=bp["provider-frontier-b"]
assert a["merged_events"]==2, a
assert a["unmerged_events"]==1, a
assert a["merged_prs"]==1, a
assert a["merged_wall_ms"]==1050, a
assert a["wall_ms_per_merged_pr"]==1050.0, a
# Pool A: selection has no tokens, iteration has tokens → incomplete coverage
assert a["tokens_per_merged_pr"] is None, a
assert a["merged_tokens_coverage_complete"] is False, a
assert b["merged_events"]==2, b
assert b["unmerged_events"]==1, b
assert b["merged_prs"]==1, b
assert b["merged_wall_ms"]==2030, b
# Pool B: both selection (no tokens) + iteration (tokens) → incomplete
assert b["tokens_per_merged_pr"] is None, b
print("ok")
' "$out" 2>&1) || true
[[ "$py_out" == "ok" ]] && ok "by_pool merged/unmerged + incomplete tokens" || bad "by_pool struct: $py_out out=$out"

# Complete token coverage on a dedicated pool: both events have tokens
COMP="$ROOT/complete-tok.jsonl"
"$CL" append --ledger "$COMP" --runner x --pool pool-complete --hat builder \
  --wall-ms 100 --pr 30 --tokens 1000 --join-key jc --now 2026-08-06T11:00:00Z
"$CL" append --ledger "$COMP" --runner x --pool pool-complete --hat builder \
  --wall-ms 200 --pr 30 --tokens 3000 --join-key jc --now 2026-08-06T11:01:00Z
cat > "$ROOT/merged-comp.json" <<'J'
[{"number":30}]
J
out=$("$CL" summarize --ledger "$COMP" --merged-json "$ROOT/merged-comp.json" --format json 2>&1)
py_out=$(python3 -c '
import json,sys
s=json.loads(sys.argv[1])
cpm=s["cost_per_merged_pr"]
assert cpm["tokens_coverage_complete"] is True, cpm
assert cpm["tokens_per_merged_pr"]==4000.0, cpm
assert cpm["tokens_known_events"]==2 and cpm["tokens_total_events"]==2, cpm
pr=cpm["per_merged_pr"]["30"]
assert pr["tokens_coverage_complete"] is True and pr["tokens"]==4000, pr
bp=s["by_pool"]["pool-complete"]
assert bp["tokens_per_merged_pr"]==4000.0, bp
assert bp["merged_tokens_coverage_complete"] is True, bp
print("ok")
' "$out" 2>&1) || true
[[ "$py_out" == "ok" ]] && ok "complete token coverage averages" || bad "complete tok: $py_out"

echo "partial token coverage must not invent lower average"
MIX="$ROOT/mixed-tok.jsonl"
"$CL" append --ledger "$MIX" --runner x --pool pool-mix --hat builder \
  --wall-ms 100 --pr 40 --tokens 9000 --join-key jm --now 2026-08-06T12:00:00Z
"$CL" append --ledger "$MIX" --runner x --pool pool-mix --hat builder \
  --wall-ms 100 --pr 40 --join-key jm --now 2026-08-06T12:01:00Z
cat > "$ROOT/merged-mix.json" <<'J'
[{"number":40}]
J
out=$("$CL" summarize --ledger "$MIX" --merged-json "$ROOT/merged-mix.json" --format json 2>&1)
py_out=$(python3 -c '
import json,sys
s=json.loads(sys.argv[1])
cpm=s["cost_per_merged_pr"]
assert cpm["tokens_per_merged_pr"] is None, cpm
assert cpm["tokens_coverage_complete"] is False, cpm
assert cpm["tokens_known_events"]==1 and cpm["tokens_total_events"]==2, cpm
pr=cpm["per_merged_pr"]["40"]
assert pr["tokens"] is None, pr
assert pr["tokens_coverage_complete"] is False, pr
assert pr["tokens_known_events"]==1 and pr["tokens_total_events"]==2, pr
print("ok")
' "$out" 2>&1) || true
[[ "$py_out" == "ok" ]] && ok "mixed known/unknown tokens → null average" || bad "mixed tok: $py_out"
text=$("$CL" summarize --ledger "$MIX" --merged-json "$ROOT/merged-mix.json" --format text 2>&1)
echo "$text" | grep -q 'tokens=unknown' \
  && ok "text reports tokens unknown on partial coverage" || bad "text mixed: $text"

echo "hostile JSONL event types fail closed"
# Boolean pr
printf '%s\n' '{"schema":"gibson.cost.v1","ts":"2026-08-06T10:00:00Z","runner":"x","pool":"p","hat":"h","wall_ms":1,"pr":true}' \
  > "$ROOT/hostile-bool.jsonl"
out=$("$CL" summarize --ledger "$ROOT/hostile-bool.jsonl" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && echo "$out" | grep -qi boolean \
  && ok "boolean pr rejected" || bad "bool pr rc=$rc: $out"
# Numeric string pr
printf '%s\n' '{"schema":"gibson.cost.v1","ts":"2026-08-06T10:00:00Z","runner":"x","pool":"p","hat":"h","wall_ms":1,"pr":"12"}' \
  > "$ROOT/hostile-str.jsonl"
out=$("$CL" summarize --ledger "$ROOT/hostile-str.jsonl" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && echo "$out" | grep -qi string \
  && ok "string pr rejected" || bad "str pr rc=$rc: $out"
# Float wall_ms
printf '%s\n' '{"schema":"gibson.cost.v1","ts":"2026-08-06T10:00:00Z","runner":"x","pool":"p","hat":"h","wall_ms":1.5}' \
  > "$ROOT/hostile-float.jsonl"
out=$("$CL" summarize --ledger "$ROOT/hostile-float.jsonl" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && echo "$out" | grep -qi float \
  && ok "float wall_ms rejected" || bad "float wall rc=$rc: $out"
# Negative tokens
printf '%s\n' '{"schema":"gibson.cost.v1","ts":"2026-08-06T10:00:00Z","runner":"x","pool":"p","hat":"h","wall_ms":1,"tokens":-3}' \
  > "$ROOT/hostile-neg.jsonl"
out=$("$CL" summarize --ledger "$ROOT/hostile-neg.jsonl" 2>&1); rc=$?
[[ "$rc" -eq 3 ]] && echo "$out" | grep -qiE 'non-negative|negative' \
  && ok "negative tokens rejected" || bad "neg tok rc=$rc: $out"
# Valid legacy row still summarizes
LEG="$ROOT/legacy-ok.jsonl"
"$CL" append --ledger "$LEG" --runner grok --pool flat-rate --hat builder \
  --wall-ms 10 --issue 1 --pr 2 --now 2026-08-06T10:00:00Z
out=$("$CL" summarize --ledger "$LEG" --format json 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"events": 1' \
  && ok "valid legacy gibson.cost.v1 still summarizes" || bad "legacy: rc=$rc $out"

echo "loop.sh outcome evidence + telemetry policy structure"
if grep -q 'state_ok' "$SCRIPT_DIR/../loop.sh" \
  && grep -q 'read_field issue' "$SCRIPT_DIR/../loop.sh" \
  && grep -q 'read_field pr' "$SCRIPT_DIR/../loop.sh" \
  && grep -q 'GIBSON_COST_TELEMETRY_REQUIRED' "$SCRIPT_DIR/../loop.sh" \
  && grep -q 'cost-ledger: iteration append failed' "$SCRIPT_DIR/../loop.sh"; then
  ok "loop.sh reads validated issue/pr + telemetry diagnostic"
else
  bad "loop.sh missing outcome/telemetry policy structure"
fi
if grep -q 'make_selection_join_key' "$SCRIPT_DIR/../loop-fleet.sh" \
  && grep -q 'make_join_discriminator' "$SCRIPT_DIR/../loop-fleet.sh" \
  && grep -q 'pool_map' "$SCRIPT_DIR/../loop-fleet.sh" \
  && grep -q "printf 'provider-%s" "$SCRIPT_DIR/../loop-fleet.sh"; then
  ok "loop-fleet join discriminator + truthful pool default present"
else
  bad "loop-fleet missing join/pool honesty structure"
fi
# Must not invent flat-rate/subscription from vendor identity in pool_for_provider.
# Assert the function exists first (fail closed if renamed) before scanning body.
pool_fn=$(grep -n '^pool_for_provider()' "$SCRIPT_DIR/../loop-fleet.sh" || true)
if [[ -z "$pool_fn" ]]; then
  bad "pool_for_provider() definition missing (sensor cannot verify plan-shape honesty)"
else
  # Extract function body until the next top-level function/assignment at column 0
  # (broader than a fixed 20-line window so a reintroduced vendor literal is caught).
  pool_body=$(awk '
    /^pool_for_provider\(\)/ {grab=1}
    grab {print}
    grab && /^\}$/ {exit}
  ' "$SCRIPT_DIR/../loop-fleet.sh")
  if printf '%s\n' "$pool_body" | grep -qE 'flat-rate-grok|subscription-codex'; then
    bad "pool_for_provider still invents plan shape from vendor"
  else
    ok "pool_for_provider does not invent plan shape from vendor"
  fi
fi

echo
echo "cost-ledger.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
