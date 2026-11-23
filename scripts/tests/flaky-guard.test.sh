#!/usr/bin/env bash
# flaky-guard.test.sh — flaky-test papering-over sensor (scripts/flaky-guard.mjs, #756).
set -uo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT" || exit 1
PASS=0
FAIL=0
ok() { echo "  ok — $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/flaky-guard.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
SENSOR="scripts/flaky-guard.mjs"
FX="scripts/tests/fixtures/flaky-guard"
MIXED="$FX/mixed.diff"
CLEAN="$FX/clean.diff"

# Hermetic: the suite may itself run under Actions; only the explicit test opts in.
run() { env -u GITHUB_ACTIONS node "$SENSOR" "$@"; }

[[ -f "$SENSOR" ]] && ok "sensor present" || bad "missing $SENSOR"
[[ -f "$MIXED" && -f "$CLEAN" ]] && ok "fixtures present" || bad "missing fixtures under $FX"

run --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help failed"

# --- report-only: findings never fail the run
out=$(run --diff "$MIXED" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "report-only exits 0 with findings" || bad "report-only rc=$rc"
[[ "$out" == *"9 finding(s) in 6 test file(s), 1 waived (report-only)"* ]] && ok "summary line counts findings, files and waivers" || bad "wrong summary: $out"

# --- exact findings, not just a count
json=$(run --diff "$MIXED" --format json 2>&1)
node -e '
  const j = JSON.parse(process.argv[1]);
  const want = [
    "scripts/tests/a.test.sh:10:sleep", "web/app.test.ts:5:skip", "web/app.test.ts:6:sleep",
    "playwright.config.ts:3:retry", "tests/test_x.py:1:skip", "tests/test_x.py:4:sleep",
    "tests/w.test.js:3:sleep", "tests/n.test.js:1:waiver-no-reason", "tests/n.test.js:1:sleep",
  ].sort();
  const got = j.findings.map((f) => `${f.path}:${f.line}:${f.id}`).sort();
  if (JSON.stringify(got) !== JSON.stringify(want)) { console.error("got", got); process.exit(1); }
  if (j.waived !== 1 || j.files !== 6 || j.mode !== "report-only") process.exit(2);
' "$json" && ok "json lists exactly the expected path:line:id findings" || bad "findings differ: $json"

# --- what must NOT be flagged
for path in "src/app.ts" "tests/NOTES.md" "scripts/tests/fixtures/x/foo.test.sh" "tests/old.test.sh" "tests/gone.test.sh"; do
  [[ "$json" != *"\"$path\""* ]] && ok "not flagged: $path" || bad "wrongly flagged: $path"
done
node -e '
  const f = JSON.parse(process.argv[1]).findings.filter((x) => x.path === "tests/w.test.js");
  if (f.some((x) => x.line === 2)) process.exit(1);
  if (!f.some((x) => x.line === 3 && x.id === "sleep")) process.exit(2);
' "$json" && ok "reasoned waiver covers the next line only; the line after it is still flagged" || bad "waiver scope wrong"

# --- strict promotes findings to a failure; a clean diff stays green
run --diff "$MIXED" --strict >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]] && ok "--strict exits 1 with findings" || bad "--strict rc=$rc"
(cd "$TMP" && node "$REPO_ROOT/$SENSOR" --diff "$REPO_ROOT/$CLEAN" --strict >"$TMP/clean.out" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "--strict exits 0 on a clean diff (todo and prose are fine)" || bad "clean diff rc=$rc: $(cat "$TMP/clean.out")"
[[ ! -e "$TMP/PWNED" ]] && ok "diff text is inert, never evaluated" || bad "diff text was executed"

# --- usage errors fail closed with exit 2
run --bogus >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "unknown flag exits 2" || bad "unknown flag rc=$rc"
run --diff >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "missing value exits 2" || bad "missing value rc=$rc"
run --diff "$MIXED" --format yaml >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "bad --format exits 2" || bad "bad --format rc=$rc"
run --diff "$TMP/does-not-exist.diff" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "unreadable diff exits 2" || bad "unreadable diff rc=$rc"

# --- git mode: only ADDED lines count; an old wait in base never fires
R="$TMP/repo"
mkdir -p "$R/tests"
git_in() { git -C "$R" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
git init -q -b main "$R" 2>/dev/null || { git init -q "$R"; git_in checkout -q -b main; }
printf 'old=1\nsleep 3\n' >"$R/tests/old.test.sh"
git_in add -A && git_in commit -q -m base
git_in checkout -q -b work
printf 'old=1\nsleep 3\nsleep 7\n' >"$R/tests/old.test.sh"
git_in add -A && git_in commit -q -m change
out=$(cd "$R" && env -u GITHUB_ACTIONS node "$REPO_ROOT/$SENSOR" --base main --head work --format json 2>&1); rc=$?
node -e '
  const j = JSON.parse(process.argv[1]);
  const f = j.findings;
  if (f.length !== 1 || f[0].path !== "tests/old.test.sh" || f[0].line !== 3) { console.error(f); process.exit(1); }
' "$out" && ok "git mode flags only the added wait, not the one already in base" || bad "git mode wrong (rc=$rc): $out"
(cd "$R" && env -u GITHUB_ACTIONS node "$REPO_ROOT/$SENSOR" --base nope --head work >/dev/null 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "unresolvable base ref exits 2" || bad "bad ref rc=$rc"

# --- Actions annotations
out=$(GITHUB_ACTIONS=true node "$SENSOR" --diff "$MIXED" 2>&1)
[[ "$out" == *"::warning file=web/app.test.ts,line=5,title=flaky-guard skip::"* ]] && ok "Actions run emits a ::warning:: annotation" || bad "no annotation: $out"

# --- edge cases (independent review: GLM 5.3)
EDGE="$FX/edge.diff"
node -e '
  const j = JSON.parse(process.argv[1]);
  const got = j.findings.map((f) => `${f.path}:${f.line}:${f.id}`).sort();
  const want = ["tests/e.test.js:2:sleep", "tests/e.test.js:3:sleep", "tests/a:b,c.test.js:1:sleep"].sort();
  if (JSON.stringify(got) !== JSON.stringify(want)) { console.error("got", got); process.exit(1); }
' "$(run --diff "$EDGE" --format json 2>&1)" && ok "an added line starting '++ ' is content, not a file header; arrow setTimeout is caught" || bad "edge findings differ"
out=$(GITHUB_ACTIONS=true node "$SENSOR" --diff "$EDGE" 2>&1)
[[ "$out" == *"::warning file=tests/a%3Ab%2Cc.test.js,line=1,"* ]] && ok "annotation properties are escaped (no workflow-command injection)" || bad "annotation not escaped: $out"

# --- mutation: knock out the skip patterns; the exact-finding check must go red
sed 's/(it|test|describe|context|suite)/(NEVER)/' "$SENSOR" >"$TMP/mutant.mjs"
mj=$(env -u GITHUB_ACTIONS node "$TMP/mutant.mjs" --diff "$MIXED" --format json 2>&1)
node -e '
  const f = JSON.parse(process.argv[1]).findings;
  if (f.length !== 8 || f.some((x) => x.path === "web/app.test.ts" && x.line === 5)) process.exit(1);
' "$mj" && ok "mutation (skip pattern removed) drops the skip finding" || bad "mutation not detected: $mj"

echo
echo "flaky-guard.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
