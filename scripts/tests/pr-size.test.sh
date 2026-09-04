#!/usr/bin/env bash
# pr-size.test.sh — PR-size budget sensor (scripts/pr-size.mjs).
set -uo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT" || exit 1
PASS=0
FAIL=0
ok() { echo "  ok — $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pr-size.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
SENSOR="scripts/pr-size.mjs"
CFG="config/pr-size.v1.json"

[[ -f "$SENSOR" ]] && ok "sensor present" || bad "missing $SENSOR"
[[ -f "$CFG" ]] && ok "config present" || bad "missing $CFG"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$CFG" >/dev/null 2>&1 \
  && ok "config is valid JSON" || bad "config is not valid JSON"

# Small config so fixtures stay readable.
cat >"$TMP/cfg.json" <<'EOF'
{
  "exceptionLabel": "size-exception",
  "budgets": { "productLines": 100, "productFiles": 3, "totalLines": 300, "totalFiles": 10 },
  "classes": {
    "generated": ["package-lock.json", "*.snap", "**/dist/**"],
    "tests": ["**/*.test.*", "**/tests/**", "**/fixtures/**"],
    "docs": ["*.md", "**/*.md", "docs/**", "memory/**"]
  }
}
EOF
TAB=$(printf '\t')
# Hermetic: the suite itself may run under Actions; only the explicit tests below opt in.
run_sensor() { env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY node "$SENSOR" --config "$TMP/cfg.json" --numstat "$@"; }
run_sensor_gha() { GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="${GHA_SUMMARY:-}" node "$SENSOR" --config "$TMP/cfg.json" --numstat "$@"; }

# --- within budget
printf '40%s10%ssrc/a.ts\n5%s5%sREADME.md\n200%s0%sscripts/tests/x.test.sh\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >"$TMP/small.txt"
out=$(run_sensor "$TMP/small.txt" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "small PR exits 0" || bad "small PR rc=$rc: $out"
[[ "$out" == *"product 50 lines / 1 files"* ]] && ok "tests and docs are not counted as product" || bad "wrong product count: $out"

# --- product lines breach
printf '90%s20%ssrc/a.ts\n' "$TAB" "$TAB" >"$TMP/lines.txt"
out=$(run_sensor "$TMP/lines.txt" 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "productLines breach exits 1" || bad "productLines breach rc=$rc"
[[ "$out" == *"productLines: 110 > 100"* ]] && ok "breach names the budget and value" || bad "missing finding: $out"
[[ "$out" == *"size-exception"* && "$out" == *"Split the PR"* ]] && ok "breach message says split or label" || bad "no remediation text: $out"

# --- product files breach with tiny diffs
printf '1%s0%ssrc/a.ts\n1%s0%ssrc/b.ts\n1%s0%ssrc/c.ts\n1%s0%ssrc/d.ts\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >"$TMP/files.txt"
run_sensor "$TMP/files.txt" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "productFiles breach exits 1" || bad "productFiles breach rc=$rc"

# --- bulk hidden in tests still trips totalLines
printf '1%s0%ssrc/a.ts\n400%s0%sscripts/tests/big.test.sh\n' "$TAB" "$TAB" "$TAB" "$TAB" >"$TMP/bulk.txt"
out=$(run_sensor "$TMP/bulk.txt" 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"totalLines: 401 > 300"* ]] && ok "bulk in tests trips totalLines" || bad "totalLines not enforced rc=$rc: $out"

# --- generated files are excluded from product but counted in total
printf '5000%s0%spackage-lock.json\n1%s0%ssrc/a.ts\n' "$TAB" "$TAB" "$TAB" "$TAB" >"$TMP/lock.txt"
out=$(run_sensor "$TMP/lock.txt" --format json 2>&1); rc=$?
node -e '
  const j = JSON.parse(process.argv[1]);
  if (j.metrics.productLines !== 1) { console.error("productLines", j.metrics.productLines); process.exit(1); }
  if (j.byClass.generated.lines !== 5000) { console.error("generated", j.byClass.generated); process.exit(1); }
' "$out" && ok "lockfile classified as generated; json output parseable" || bad "generated classification wrong: $out"

# --- exception label: breach becomes a warning, exit 0, numbers still printed
out=$(run_sensor "$TMP/lines.txt" --exception 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "--exception exits 0 on breach" || bad "--exception rc=$rc"
[[ "$out" == *"WARN"* && "$out" == *"productLines: 110 > 100"* ]] && ok "exception still reports the breach" || bad "exception hid numbers: $out"
out=$(GIBSON_PR_SIZE_EXCEPTION=1 run_sensor "$TMP/lines.txt" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "GIBSON_PR_SIZE_EXCEPTION=1 honoured" || bad "env exception rc=$rc"
out=$(GIBSON_PR_SIZE_EXCEPTION=0 run_sensor "$TMP/lines.txt" 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "GIBSON_PR_SIZE_EXCEPTION=0 is not an exception" || bad "env 0 rc=$rc"

# --- binary + rename rows parse; binary counts as a file with 0 lines
printf -- '-%s-%sassets/logo.png\n3%s3%ssrc/{old => new}/mod.ts\n2%s2%sa.ts => b.ts\n' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" >"$TMP/ren.txt"
out=$(run_sensor "$TMP/ren.txt" --format json 2>&1); rc=$?
node -e '
  const j = JSON.parse(process.argv[1]);
  const paths = j.largest.map(f => f.path).sort();
  if (JSON.stringify(paths) !== JSON.stringify(["assets/logo.png","b.ts","src/new/mod.ts"])) { console.error(paths); process.exit(1); }
  if (j.metrics.productFiles !== 3 || j.metrics.productLines !== 10) { console.error(j.metrics); process.exit(1); }
' "$out" && ok "binary and rename numstat rows parse" || bad "numstat parse: $out"

# --- NUL-delimited (-z) rows: raw paths, rename records, literal " => " and non-ASCII
NUL_FIX="$TMP/z.bin"
printf '3\t3\tscripts/tests/t.test.sh\0' >"$NUL_FIX"
printf '2\t2\t\0old/x.ts\0new/y.ts\0' >>"$NUL_FIX"                    # rename record
printf '4\t0\tdocs/caf\303\251.md\0' >>"$NUL_FIX"                       # UTF-8 path, unquoted under -z
printf '1\t0\tsrc/a => b.ts\0' >>"$NUL_FIX"                              # ordinary name containing " => "
printf -- '-\t-\tassets/logo.png\0' >>"$NUL_FIX"                          # binary
out=$(run_sensor "$NUL_FIX" --format json 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "-z fixture exits 0" || bad "-z fixture rc=$rc: $out"
node -e '
  const j = JSON.parse(process.argv[1]);
  const paths = j.largest.map(f => f.path).sort();
  const want = ["assets/logo.png","docs/café.md","new/y.ts","scripts/tests/t.test.sh","src/a => b.ts"];
  if (JSON.stringify(paths) !== JSON.stringify(want)) { console.error(paths); process.exit(1); }
  if (j.byClass.docs.lines !== 4 || j.byClass.docs.files !== 1) { console.error("docs", j.byClass.docs); process.exit(1); }
  if (j.metrics.productFiles !== 3 || j.metrics.productLines !== 5) { console.error(j.metrics); process.exit(1); }
' "$out" && ok "-z: rename, UTF-8 docs path classified as docs, literal ' => ' kept verbatim" || bad "-z parse: $out"
printf '3\t3\tsrc/a.ts\0001\t1\tsrc/b.ts' >"$TMP/z-trunc.bin"
run_sensor "$TMP/z-trunc.bin" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "-z stream missing final NUL exits 2" || bad "truncated -z rc=$rc"
printf '2\t2\t\0old/x.ts\0' >"$TMP/z-ren.bin"
run_sensor "$TMP/z-ren.bin" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "-z truncated rename record exits 2" || bad "truncated rename rc=$rc"

# --- text mode: C-quoted path (core.quotePath default) is decoded and classified
printf '4%s0%s"docs/caf\\303\\251.md"\n' "$TAB" "$TAB" >"$TMP/quoted.txt"
out=$(run_sensor "$TMP/quoted.txt" --format json 2>&1); rc=$?
node -e '
  const j = JSON.parse(process.argv[1]);
  if (j.largest[0].path !== "docs/café.md" || j.byClass.docs.files !== 1 || j.metrics.productFiles !== 0) { console.error(j.largest, j.byClass); process.exit(1); }
' "$out" && ok "C-quoted text path decodes to docs/café.md and counts as docs" || bad "quoted path: rc=$rc $out"

# --- the sensor asks git for -z output
grep -q '"--numstat", "-z"' "$SENSOR" && ok "live git call uses --numstat -z" || bad "git call is not NUL-delimited"

# --- GitHub Actions: exception is announced, never a silent green
SUMMARY="$TMP/summary.md"; : >"$SUMMARY"
out=$(GHA_SUMMARY="$SUMMARY" run_sensor_gha "$TMP/lines.txt" --exception 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"::warning title=pr-size::OVER BUDGET"* && "$out" == *"size-exception"* ]] \
  && ok "exception emits a ::warning:: annotation naming the label" || bad "no annotation on exception rc=$rc: $out"
grep -q 'size-exception' "$SUMMARY" && grep -q 'productLines: 110 > 100' "$SUMMARY" \
  && ok "exception written to GITHUB_STEP_SUMMARY with the numbers" || bad "step summary: $(cat "$SUMMARY")"
: >"$SUMMARY"
out=$(GHA_SUMMARY="$SUMMARY" run_sensor_gha "$TMP/lines.txt" 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"::error title=pr-size::"* ]] && ok "unexcepted breach emits ::error::" || bad "no ::error:: rc=$rc: $out"
out=$(run_sensor_gha "$TMP/small.txt" 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"::notice title=pr-size::within budget"* ]] && ok "within budget emits ::notice::" || bad "no ::notice:: rc=$rc: $out"
out=$(run_sensor "$TMP/lines.txt" --exception 2>&1)
[[ "$out" != *"::warning"* ]] && ok "no annotations outside GitHub Actions" || bad "annotation leaked outside CI"

# --- empty diff is fine
: >"$TMP/empty.txt"
run_sensor "$TMP/empty.txt" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "empty diff exits 0" || bad "empty diff rc=$rc"

# --- malformed input / config exit 2
printf 'not numstat\n' >"$TMP/bad.txt"
run_sensor "$TMP/bad.txt" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "malformed numstat exits 2" || bad "malformed rc=$rc"
echo '{"exceptionLabel":"x","budgets":{"productLines":0},"classes":{}}' >"$TMP/badcfg.json"
node "$SENSOR" --config "$TMP/badcfg.json" --numstat "$TMP/small.txt" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "invalid config exits 2" || bad "invalid config rc=$rc"
node "$SENSOR" --base refs/does/not/exist --head HEAD >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "unknown base ref exits 2 (fails closed, not green)" || bad "unknown base rc=$rc"

# --- live: the shipped config runs against this repo's own git history
node "$SENSOR" --config "$CFG" --base HEAD~1 --head HEAD >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 || $rc -eq 1 ]] && ok "shipped config evaluates a real diff (rc=$rc)" || bad "live run rc=$rc"

# --- workflow wiring: runs on PRs, label maps to the exception env, not swallowed
WF=".github/workflows/gibson-self-gate.yml"
TPL="ci/gibson-gate.yml"
for f in "$WF" "$TPL"; do
  grep -q 'scripts/pr-size.mjs' "$f" && ok "$f runs pr-size" || bad "$f does not run pr-size"
  grep -q "size-exception" "$f" && ok "$f maps the size-exception label" || bad "$f: label not wired"
  grep -E 'pr-size.mjs.*\|\| *true' "$f" >/dev/null && bad "$f: pr-size result swallowed with || true" || ok "$f: pr-size result not swallowed"
  # Trusted-base execution: the sensor and budget come from base.sha via git show,
  # and the run step never executes the PR tree's scripts/pr-size.mjs directly.
  grep -Eq 'git show "\$GIBSON_PR_BASE:\$f"' "$f" && ok "$f materialises sensor+config from the trusted base" || bad "$f: sensor not taken from base"
  grep -Eq 'run: node "\$PR_SIZE_TRUSTED/scripts/pr-size.mjs"' "$f" && ok "$f executes the trusted copy" || bad "$f: does not execute trusted copy"
  grep -Eq '^\s*run: node scripts/pr-size.mjs' "$f" && bad "$f: executes PR-controlled pr-size.mjs" || ok "$f: never executes the PR-controlled sensor"
  grep -q 'config/pr-size.v1.json' "$f" && ok "$f takes the budget config from the trusted base too" || bad "$f: config not from base"
done

echo
echo "pr-size.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
