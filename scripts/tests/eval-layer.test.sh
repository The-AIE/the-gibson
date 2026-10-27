#!/usr/bin/env bash
# eval-layer.test.sh — #583 eval layer: trace, dataset lint, run, gate, redaction
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
S="$SCRIPT_DIR/.."
REPO=$(CDPATH='' cd -- "$S/.." && pwd)
PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-eval.XXXXXX")
trap 'rm -rf "$ROOT"; [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null' EXIT
OUT="$ROOT/out"

# Never inherit real keys into the test.
unset LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LANGFUSE_HOST

mk_ds() { # file lines...
  local f="$1"; shift
  : > "$f"
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}
case_line() { # id expect-json
  printf '{"id":"%s","tier":"A","input":"q-%s","expect":%s}' "$1" "$1" "$2"
}

# Capture first, grep after: under pipefail, `grep -q` closing the pipe early
# would turn a correct run into a false failure.
# has HAYSTACK NEEDLE — substring test without a pipe (L-077 bans piped quiet grep).
has() { [[ "$1" == *"$2"* ]]; }
lint_says() { # needle label min -- run lint on $D and look for needle
  local out; out=$(node "$S/eval-dataset-lint.mjs" --file "$D" --min "$3" 2>&1)
  [[ "$out" == *"$1"* ]] && ok "$2" || bad "$2 (got: $out)"
}

echo "unknown flags exit 2 (convention 2.3)"
for s in eval-trace eval-dataset-lint eval-run eval-gate; do
  node "$S/$s.mjs" --definitely-not-a-flag >/dev/null 2>"$ROOT/err"; rc=$?
  [[ $rc -eq 2 ]] && grep -q 'unknown flag' "$ROOT/err" && ok "$s rejects unknown flag" || bad "$s unknown flag rc=$rc"
  node "$S/$s.mjs" --help >/dev/null 2>&1 && ok "$s --help exits 0" || bad "$s --help"
done

echo "AC2 dataset lint — shipped dataset"
node "$S/eval-dataset-lint.mjs" --file "$REPO/evals/dataset.v1.jsonl" >/dev/null 2>&1 \
  && ok "shipped dataset lints clean" || bad "shipped dataset failed lint"

echo "AC2 dataset lint — adversarial"
D="$ROOT/d.jsonl"
mk_ds "$D" "$(case_line a '{"type":"contains","value":"x"}')"
node "$S/eval-dataset-lint.mjs" --file "$D" >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "1 case fails default min" || bad "min not enforced"
node "$S/eval-dataset-lint.mjs" --file "$D" --min 1 --max 1 >/dev/null 2>&1 && ok "--min/--max honoured" || bad "min/max override"
mk_ds "$D" '{"id":"a","tier":"A","input":"q"}'
lint_says 'expect' "missing expect named" 1
mk_ds "$D" '{"id":"a","tier":"Z","input":"q","expect":{"type":"contains","value":"x"}}'
lint_says 'tier' "bad tier named" 1
mk_ds "$D" '{"id":"a","tier":"A","input":"  ","expect":{"type":"contains","value":"x"}}'
lint_says 'input' "empty input named" 1
mk_ds "$D" "$(case_line a '{"type":"contains","value":"x"}')" "$(case_line a '{"type":"contains","value":"x"}')"
lint_says 'duplicate' "duplicate id named" 1
mk_ds "$D" 'not json'
lint_says 'not valid JSON' "malformed line named" 0
mk_ds "$D" "$(case_line a '{"type":"regex","value":"(","flags":"i"}')"
lint_says 'compile' "bad regex named" 1
node "$S/eval-dataset-lint.mjs" --file "$ROOT/nope.jsonl" >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "missing file exits 1" || bad "missing file"

echo "AC1 trace — no keys: local sink, exit 0, says skipped"
LED="$ROOT/ledger.jsonl"
"$S/cost-ledger.sh" append --ledger "$LED" --runner grok --pool flat-rate --hat builder --wall-ms 1200 --flat-rate true --issue 10 --pr 5 --iteration 1 --now 2026-08-06T10:00:00Z >/dev/null
"$S/cost-ledger.sh" append --ledger "$LED" --runner claude --pool metered --hat reviewer --wall-ms 800 --tokens 4000 --issue 10 --pr 5 --iteration 2 --now 2026-08-06T10:05:00Z >/dev/null
out=$(node "$S/eval-trace.mjs" --ledger "$LED" --out-dir "$OUT" 2>&1); rc=$?
[[ $rc -eq 0 ]] && has "$out" 'SKIPPED' && ok "no keys: exit 0 and names the skip" || bad "no-key run rc=$rc: $out"
[[ "$(wc -l < "$OUT/traces.jsonl" | tr -d ' ')" = "1" ]] && ok "default converts last row only" || bad "last-row default"
node "$S/eval-trace.mjs" --ledger "$LED" --all --out-dir "$OUT" >/dev/null 2>&1
[[ "$(wc -l < "$OUT/traces.jsonl" | tr -d ' ')" = "3" ]] && ok "--all converts every row" || bad "--all"
grep -q '"tokens":null' "$OUT/traces.jsonl" && ok "unknown tokens stay null, not invented" || bad "tokens honesty"
: > "$ROOT/empty.jsonl"
node "$S/eval-trace.mjs" --ledger "$ROOT/empty.jsonl" --out-dir "$OUT" >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "empty ledger exits 1" || bad "empty ledger"
node "$S/eval-trace.mjs" --ledger "$ROOT/nope" --out-dir "$OUT" >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "missing ledger exits 1" || bad "missing ledger"

echo "AC1/AC6 trace — with keys: ships over REST, auth header, redacted"
cat > "$ROOT/srv.mjs" <<'JS'
import http from "node:http";
import { writeFileSync } from "node:fs";
const dump = process.argv[2];
const srv = http.createServer((req, res) => {
  let b = "";
  req.on("data", (d) => (b += d));
  req.on("end", () => {
    writeFileSync(dump, JSON.stringify({ url: req.url, auth: req.headers.authorization, body: b }));
    res.writeHead(207, { "content-type": "application/json" });
    res.end(JSON.stringify({ successes: [], errors: [] }));
  });
});
srv.listen(0, "127.0.0.1", () => console.log(srv.address().port));
JS
node "$ROOT/srv.mjs" "$ROOT/req.json" > "$ROOT/port" &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$ROOT/port" ]] && break; sleep 0.3; done
PORT=$(cat "$ROOT/port")
SECRET="sk-lf-supersecretvalue1234"
PUB="pk-lf-publicvalue5678"
printf '{"schema":"gibson.cost.v1","ts":"2026-08-06T10:00:00Z","hat":"builder","runner":"grok leaked sk-ant-abcdefghijklmnop1234","iteration":1,"issue":10}\n' > "$ROOT/leaky.jsonl"
out=$(LANGFUSE_PUBLIC_KEY="$PUB" LANGFUSE_SECRET_KEY="$SECRET" LANGFUSE_HOST="http://127.0.0.1:$PORT" \
  node "$S/eval-trace.mjs" --ledger "$ROOT/leaky.jsonl" --out-dir "$ROOT/o2" 2>&1); rc=$?
[[ $rc -eq 0 ]] && has "$out" 'shipped 1' && ok "shipped to local fake Langfuse" || bad "ship rc=$rc: $out"
grep -q '/api/public/ingestion' "$ROOT/req.json" && ok "uses REST ingestion endpoint" || bad "endpoint"
expected_auth="Basic $(printf '%s' "$PUB:$SECRET" | base64 | tr -d '\n')"
node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(r.auth===process.argv[2]?0:1)' "$ROOT/req.json" "$expected_auth" \
  && ok "Basic auth from env keys" || bad "auth header"
if grep -q "$SECRET" "$ROOT/req.json" "$ROOT/o2/traces.jsonl" "$ROOT/err" 2>/dev/null || has "$out" "$SECRET"; then
  bad "secret key leaked into payload, sink or output"
else ok "secret key absent from payload, local sink and output"; fi
grep -q 'sk-ant-abcdefghijklmnop1234' "$ROOT/req.json" "$ROOT/o2/traces.jsonl" && bad "key-shaped token not redacted" || ok "key-shaped token in a ledger row is redacted"
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

echo "AC1 trace — collector down must not fail the run"
out=$(LANGFUSE_PUBLIC_KEY="$PUB" LANGFUSE_SECRET_KEY="$SECRET" LANGFUSE_HOST="http://127.0.0.1:1" \
  node "$S/eval-trace.mjs" --ledger "$LED" --out-dir "$ROOT/o3" 2>&1); rc=$?
[[ $rc -eq 0 ]] && has "$out" 'FAILED' && [[ -s "$ROOT/o3/traces.jsonl" ]] && ok "upload failure: exit 0, says FAILED, local copy kept" || bad "down collector rc=$rc: $out"
has "$out" "$SECRET" && bad "secret in failure output" || ok "no secret in failure output"
out=$(LANGFUSE_PUBLIC_KEY="$PUB" LANGFUSE_SECRET_KEY="$SECRET" LANGFUSE_HOST="http://evil.example.com" \
  node "$S/eval-trace.mjs" --ledger "$LED" --out-dir "$ROOT/o4" 2>&1)
has "$out" 'SKIPPED' && has "$out" 'https' && ok "plain-http remote host refused (keys never sent in clear)" || bad "http host: $out"

echo "AC3 run — scoring and compare"
cat > "$ROOT/runner.sh" <<'SH'
#!/bin/sh
in=$(cat)
case "$in" in
  *'"id":"good"'*) echo "the answer is yes"; echo 'GIBSON_EVAL_COST {"usd": 0.02, "tokens": 100}' >&2 ;;
  *'"id":"wrong"'*) echo "nope"; echo 'GIBSON_EVAL_COST {"usd": 0.03, "tokens": 120}' >&2 ;;
  *'"id":"leak"'*) echo "key is sk-lf-supersecretvalue1234 ok"; echo 'GIBSON_EVAL_COST {"usd": 0.01}' >&2 ;;
  *'"id":"slow"'*) sleep 5; echo yes ;;
  *'"id":"crash"'*) echo partial; exit 3 ;;
esac
SH
chmod +x "$ROOT/runner.sh"
DS="$ROOT/run.jsonl"
mk_ds "$DS" \
  "$(case_line good '{"type":"contains","value":"yes"}')" \
  "$(case_line wrong '{"type":"contains","value":"yes"}')" \
  "$(case_line leak '{"type":"not_contains","value":"zzz"}')" \
  "$(case_line crash '{"type":"exit_code","value":3}')"
cp "$DS" "$ROOT/run4.jsonl" # DS is reassigned for the one-case grader tests below
out=$(node "$S/eval-run.mjs" --variant base --runner "$ROOT/runner.sh" --dataset "$DS" --out-dir "$ROOT/r" 2>&1); rc=$?
[[ $rc -eq 0 ]] && has "$out" '3/4 passed' && ok "scores 3 of 4 (one real failure)" || bad "run rc=$rc: $out"
has "$out" 'FAIL  wrong' && ok "failure reported with its id" || bad "failure line"
[[ -f "$ROOT/r/runs/base.json" ]] && ok "run file written" || bad "run file"
grep -q '"pass_rate": 0.75' "$ROOT/r/runs/base.json" && ok "pass_rate recorded" || bad "pass_rate"
grep -q '"cost_usd_total": null' "$ROOT/r/runs/base.json" && ok "partial cost report => total unknown, not a fake sum" || bad "cost honesty"
grep -q 'sk-lf-supersecretvalue1234' "$ROOT/r/runs/base.json" "$ROOT/r/traces.jsonl" && bad "runner output leaked a key into storage" || ok "key-shaped runner output redacted in run file and traces"
grep -q '"name":"pass"' "$ROOT/r/traces.jsonl" && ok "pass scores written as traces" || bad "score events"

mk_ds "$DS" "$(case_line good '{"type":"contains","value":"yes"}')"
node "$S/eval-run.mjs" --variant cheap --runner "echo yes" --dataset "$DS" --out-dir "$ROOT/r" >/dev/null 2>&1
node "$S/eval-run.mjs" --variant strong --runner "$ROOT/runner.sh" --dataset "$DS" --out-dir "$ROOT/r" >/dev/null 2>&1
out=$(node "$S/eval-run.mjs" --compare cheap strong --out-dir "$ROOT/r" 2>&1); rc=$?
[[ $rc -eq 0 ]] && has "$out" 'delta' && has "$out" 'not computable' && ok "compare diffs two variants; cost delta honest when unknown" || bad "compare rc=$rc: $out"
node "$S/eval-run.mjs" --compare cheap nope --out-dir "$ROOT/r" >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "compare with missing run exits 1" || bad "compare missing"
node "$S/eval-run.mjs" --compare cheap --out-dir "$ROOT/r" >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "compare needs two names" || bad "compare arity"
node "$S/eval-run.mjs" --variant '../evil' --runner true --dataset "$DS" --out-dir "$ROOT/r" >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "path-traversal variant name refused" || bad "variant traversal"
node "$S/eval-run.mjs" --variant x --runner true --dataset "$ROOT/nope" --out-dir "$ROOT/r" >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "missing dataset exits 1" || bad "missing dataset"

echo "runner timeout"
mk_ds "$DS" "$(case_line slow '{"type":"contains","value":"yes"}')"
out=$(node "$S/eval-run.mjs" --variant slow --runner "$ROOT/runner.sh" --dataset "$DS" --timeout-ms 500 --out-dir "$ROOT/r" 2>&1)
has "$out" 'timed out' && ok "hung runner is killed and fails the case" || bad "timeout: $out"

echo "AC4 grader seam — fails closed"
mk_ds "$DS" "$(case_line good '{"type":"contains","value":"yes"}')"
cat > "$ROOT/g_pass.sh" <<'SH'
#!/bin/sh
cat >/dev/null; echo '{"verdict":"pass","reason":"fine"}'
SH
cat > "$ROOT/g_fail.sh" <<'SH'
#!/bin/sh
cat >/dev/null; echo '{"verdict":"fail","reason":"weak answer"}'
SH
cat > "$ROOT/g_crash.sh" <<'SH'
#!/bin/sh
cat >/dev/null; exit 9
SH
cat > "$ROOT/g_junk.sh" <<'SH'
#!/bin/sh
cat >/dev/null; echo 'looks good to me'
SH
cat > "$ROOT/g_odd.sh" <<'SH'
#!/bin/sh
cat >/dev/null; echo '{"verdict":"maybe"}'
SH
cat > "$ROOT/g_slow.sh" <<'SH'
#!/bin/sh
cat >/dev/null; sleep 5; echo '{"verdict":"pass"}'
SH
chmod +x "$ROOT"/g_*.sh
run_g() { node "$S/eval-run.mjs" --variant "g-$1" --runner "$ROOT/runner.sh" --dataset "$DS" --grader "$ROOT/$2" --timeout-ms "${3:-5000}" --out-dir "$ROOT/r" 2>&1; }
has "$(run_g pass g_pass.sh)" '1/1 passed' && ok "grader pass => pass" || bad "grader pass"
has "$(run_g fail g_fail.sh)" '0/1 passed' && ok "grader fail => fail even if expect matched" || bad "grader fail"
has "$(run_g crash g_crash.sh)" '0/1 passed' && ok "grader crash => fail (closed)" || bad "grader crash"
has "$(run_g junk g_junk.sh)" '0/1 passed' && ok "grader non-JSON => fail (closed)" || bad "grader junk"
has "$(run_g odd g_odd.sh)" '0/1 passed' && ok "grader unknown verdict => fail (closed)" || bad "grader odd verdict"
has "$(run_g slow g_slow.sh 600)" '0/1 passed' && ok "grader timeout => fail (closed)" || bad "grader timeout"
has "$(run_g nogr "does-not-exist.sh")" '0/1 passed' && ok "missing grader command => fail (closed)" || bad "grader missing"
grep -q '"grader_errors": 1' "$ROOT/r/runs/g-crash.json" && ok "grader errors are counted in the run file" || bad "grader_errors count"

echo "AC5 gate"
GDS="$ROOT/run4.jsonl"
G() { node "$S/eval-gate.mjs" --out-dir "$ROOT/r" --dataset "$GDS" "$@"; }
GDS="$DS" G --variant g-pass --min-pass-rate 1 >/dev/null 2>&1 && ok "at threshold passes" || bad "gate at threshold"
G --variant base --min-pass-rate 0.8 >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "below threshold fails" || bad "gate below"
G --variant base --min-pass-rate 0.75 >/dev/null 2>&1 && ok "exactly at 0.75 passes" || bad "gate boundary"
G --variant never-ran --min-pass-rate 0 >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "MISSING result fails even at threshold 0" || bad "gate missing result passed"
GDS="$DS" G --variant g-crash --min-pass-rate 0 >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "grader errors fail the gate even at threshold 0" || bad "gate ignored grader errors"
mkdir -p "$ROOT/r/runs"
echo '{"schema":"gibson.eval-run.v1","variant":"empty","total":0,"passed":0,"cases":[]}' > "$ROOT/r/runs/empty.json"
G --variant empty --min-pass-rate 0 >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "zero-case run fails (no evidence)" || bad "empty run passed"
echo 'garbage' > "$ROOT/r/runs/garbage.json"
G --variant garbage --min-pass-rate 0 >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "unparsable result fails" || bad "garbage passed"
echo '{"schema":"gibson.eval-run.v1","variant":"forged","total":10,"passed":10,"pass_rate":1,"cases":[{"id":"a","pass":false}]}' > "$ROOT/r/runs/forged.json"
G --variant forged --min-pass-rate 1 >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "forged summary that disagrees with cases fails" || bad "forged summary passed"
G --variant base --min-pass-rate 2 >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "out-of-range threshold is a usage error" || bad "threshold range"
G --variant base >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "threshold required" || bad "threshold required"
G --variant '../x' --min-pass-rate 0 >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "traversal variant refused" || bad "gate traversal"
G --variant base --min-pass-rate "" >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "empty threshold is a usage error (not 0)" || bad "empty threshold accepted"
G --variant base --min-pass-rate "  " >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "blank threshold is a usage error" || bad "blank threshold accepted"
head -n 3 "$GDS" > "$ROOT/reduced.jsonl"
node "$S/eval-gate.mjs" --out-dir "$ROOT/r" --dataset "$ROOT/reduced.jsonl" --variant base --min-pass-rate 0 >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "run over a different case set fails the gate" || bad "case-set mismatch passed"
node "$S/eval-gate.mjs" --out-dir "$ROOT/r" --dataset "$ROOT/nope.jsonl" --variant base --min-pass-rate 0 >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "unreadable expected dataset fails closed" || bad "missing expected dataset passed"
cat > "$ROOT/envrunner.sh" <<'RUN'
#!/bin/sh
cat >/dev/null
echo "key=${LANGFUSE_SECRET_KEY:-absent} pub=${LANGFUSE_PUBLIC_KEY:-absent}"
RUN
chmod +x "$ROOT/envrunner.sh"
printf '{"id":"env1","input":"x","tier":"A","expect":{"type":"contains","value":"key=absent pub=absent"}}\n' > "$ROOT/env.jsonl"
LANGFUSE_SECRET_KEY=sk-lf-aaaaaaaa LANGFUSE_PUBLIC_KEY=pk-lf-bbbbbbbb LANGFUSE_HOST=http://127.0.0.1:1 \
  node "$S/eval-run.mjs" --variant envcheck --runner "$ROOT/envrunner.sh" --dataset "$ROOT/env.jsonl" --out-dir "$ROOT/r" >/dev/null 2>&1
grep -q '"passed": 1' "$ROOT/r/runs/envcheck.json" && ok "runner child does not receive LANGFUSE_* variables" || bad "LANGFUSE_* leaked to runner"

echo "AC5 workflow wiring (live opt-in job + smoke run)"
WF="$REPO/.github/workflows/eval-gate.yml"
[[ -f "$WF" ]] && ok "live workflow installed at .github/workflows/eval-gate.yml" || bad "workflow missing"
wf=$(<"$WF")
has "$wf" 'workflow_dispatch:' && has "$wf" 'schedule:' && ok "triggers: manual dispatch + schedule" || bad "workflow triggers"
{ has "$wf" 'pull_request' || has "$wf" $'\n  push:'; } && bad "workflow must not trigger on PR/push (opt-in, never required)" || ok "no pull_request / push trigger"
has "$wf" $'\npermissions: {}\n' && ok "top-level permissions: {} (deny by default)" || bad "permissions"
has "$wf" 'continue-on-error:' && bad "continue-on-error is forbidden" || ok "no continue-on-error"
for sc in eval-dataset-lint eval-run eval-gate eval-trace; do
  has "$wf" "scripts/$sc.mjs" && ok "workflow calls $sc.mjs" || bad "workflow does not call $sc.mjs"
done
smoke=${wf#*Smoke run}; smoke=${smoke%%Lint the dataset*}
has "$smoke" 'secrets.' && bad "smoke step must not see secrets" || ok "smoke step gets no secrets"
has "$smoke" 'jq -rj .input' && has "$smoke" '--min-pass-rate 1' && ok "smoke uses the deterministic stub runner at a 100% threshold" || bad "smoke wiring"
has "$wf" "cron:" && ok "weekly schedule present (keeps sensor-health freshness truthful)" || bad "schedule cron"
reg=$(<"$REPO/config/sensor-health-observation.v1.json")
has "$reg" '.github/workflows/eval-gate.yml' && ok "sensor-health inventory lists the workflow" || bad "sensor inventory row"
row=${reg#*eval-gate.yml}; row=${row%%\}*}
has "$row" '"schedule"' && ! has "$row" 'workflow_dispatch' && ok "sensor row watches schedule only (a failed manual run must not turn the sensor red)" || bad "sensor row events"
# Execute the smoke commands exactly as the workflow does (no network, no model).
SM="$ROOT/smoke"
node "$S/eval-dataset-lint.mjs" --file "$REPO/evals/smoke.v1.jsonl" --min 1 --max 10 >/dev/null 2>&1 && ok "smoke dataset lints" || bad "smoke lint"
node "$S/eval-run.mjs" --variant smoke --runner "jq -rj .input" --dataset "$REPO/evals/smoke.v1.jsonl" --out-dir "$SM" >/dev/null 2>&1 \
  && node "$S/eval-gate.mjs" --variant smoke --min-pass-rate 1 --dataset "$REPO/evals/smoke.v1.jsonl" --out-dir "$SM" >/dev/null 2>&1 \
  && ok "smoke run passes the gate end to end" || bad "smoke run/gate"
# Control: a broken stub must FAIL the same gate, so the smoke run proves something.
node "$S/eval-run.mjs" --variant smoke-broken --runner "echo wrong" --dataset "$REPO/evals/smoke.v1.jsonl" --out-dir "$SM" >/dev/null 2>&1
node "$S/eval-gate.mjs" --variant smoke-broken --min-pass-rate 1 --dataset "$REPO/evals/smoke.v1.jsonl" --out-dir "$SM" >/dev/null 2>&1; [[ $? -eq 1 ]] \
  && ok "control: a broken runner fails the smoke gate" || bad "smoke control passed a broken runner"

echo ""
echo "eval-layer: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
