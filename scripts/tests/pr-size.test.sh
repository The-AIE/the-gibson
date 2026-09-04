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
run_sensor() { node "$SENSOR" --config "$TMP/cfg.json" --numstat "$@"; }

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
grep -q 'scripts/pr-size.mjs' "$WF" && ok "self-gate runs pr-size" || bad "self-gate does not run pr-size"
grep -q "size-exception" "$WF" && ok "self-gate maps the size-exception label" || bad "label not wired"
grep -E 'pr-size.mjs.*\|\| *true' "$WF" >/dev/null && bad "pr-size result swallowed with || true" || ok "pr-size result not swallowed"
TPL="ci/gibson-gate.yml"
grep -q 'scripts/pr-size.mjs' "$TPL" && ok "target-repo template runs pr-size" || bad "template does not run pr-size"

echo
echo "pr-size.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
