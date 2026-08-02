#!/usr/bin/env bash
# gate.test.sh — adversarial sensors for test-integrity (issue #70)
#
# WHY
#   The green gate used to treat "deleted the failing test" the same as
#   "fixed the failing test." Models optimizing for green discover that
#   immediately. These cases pin the unattended-merge safety control:
#   count drops and skip inflation hard-fail with exact deltas; only an
#   exact visible waiver may authorize a reduction; hidden/near/wrong-delta
#   waivers fail closed; metric garbage never becomes zero; baseline
#   regeneration is an explicit journaled act; a local/gitignored baseline
#   cannot authorize a PR (CI uses a trusted source label).
#
# USAGE
#   scripts/tests/gate.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
TI="$SCRIPT_DIR/../test-integrity.mjs"
GATE="$SCRIPT_DIR/../gate.sh"
BASELINE_SH="$SCRIPT_DIR/../gate-baseline.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "gate.test.sh: node is required"; exit 1; }
command -v git  >/dev/null || { echo "gate.test.sh: git is required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-gate-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

write_metrics() { # file total skipped todo
  cat > "$1" <<EOF
{"total": $2, "skipped": $3, "todo": $4}
EOF
}

compare() { # base head waiver_text [trusted]
  local base="$1" head="$2" waiver="${3:-}" trusted="${4:-baseline}"
  node "$TI" compare --base "$base" --head "$head" \
    --waiver-text "$waiver" --trusted-source "$trusted" 2>&1
}

# ---------------------------------------------------------------------------
echo "deletion without waiver hard-fails with exact total delta"
# ---------------------------------------------------------------------------
write_metrics "$ROOT/b1.json" 10 0 0
write_metrics "$ROOT/h1.json" 7 0 0
out=$(compare "$ROOT/b1.json" "$ROOT/h1.json" ""); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'test-integrity' \
  && echo "$out" | grep -qE 'dropped by 3|removed 3' \
  && echo "$out" | grep -q '10' && echo "$out" | grep -q '7'; then
  ok "deletion/no waiver fails with test-integrity and delta 3 (10→7)"
else
  bad "deletion/no waiver (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "new skip/todo without waiver hard-fails with exact skip delta"
# ---------------------------------------------------------------------------
write_metrics "$ROOT/b2.json" 10 0 0
write_metrics "$ROOT/h2.json" 10 2 1
out=$(compare "$ROOT/b2.json" "$ROOT/h2.json" ""); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'test-integrity' \
  && echo "$out" | grep -qE 'skip/todo rose by 3|skip \+3'; then
  ok "new skip/todo/no waiver fails with exact skip delta 3"
else
  bad "new skip/no waiver (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "exact visible delta-consistent waiver passes and is surfaced"
# ---------------------------------------------------------------------------
write_metrics "$ROOT/b3.json" 10 1 0
write_metrics "$ROOT/h3.json" 8 2 0
waiver=$'## Notes\nTest-integrity: removed 2 for obsolete fixtures after #70\nTest-integrity: skip +1 for flaky external API pending #71\n'
out=$(compare "$ROOT/b3.json" "$ROOT/h3.json" "$waiver"); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'WAIVER accepted' \
  && echo "$out" | grep -q 'removed 2' && echo "$out" | grep -q 'skip +1' \
  && echo "$out" | grep -q 'obsolete fixtures'; then
  ok "exact visible delta-consistent waiver passes and surfaces reason"
else
  bad "exact waiver (rc=$rc): $out"
fi

# Combined single-line form
waiver2='Test-integrity: removed 2, skip +1 for both intentional under #70'
out=$(compare "$ROOT/b3.json" "$ROOT/h3.json" "$waiver2"); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'WAIVER accepted' \
  && ok "combined waiver line accepted" \
  || bad "combined waiver (rc=$rc): $out"

# Leading markdown list dash
waiver3='- Test-integrity: removed 2 for obsolete fixtures after #70
- Test-integrity: skip +1 for flaky external API'
out=$(compare "$ROOT/b3.json" "$ROOT/h3.json" "$waiver3"); rc=$?
[[ "$rc" -eq 0 ]] && ok "markdown-list waiver form accepted" \
  || bad "markdown-list waiver (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "hidden / near-match / wrong-delta waivers fail closed"
# ---------------------------------------------------------------------------
# Hidden in HTML comment
hidden=$'Looks fine\n<!--\nTest-integrity: removed 3 for secretly gone\n-->\n'
write_metrics "$ROOT/b4.json" 10 0 0
write_metrics "$ROOT/h4.json" 7 0 0
out=$(compare "$ROOT/b4.json" "$ROOT/h4.json" "$hidden"); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'dropped by 3' \
  && ! echo "$out" | grep -q 'WAIVER accepted'; then
  ok "HTML-comment waiver cannot authorize a deletion"
else
  bad "hidden HTML waiver (rc=$rc): $out"
fi

# Near-match labels / spellings
for near in \
  'test-integrity: removed 3 for almost' \
  'Test integrity: removed 3 for almost' \
  'Test-Integrity: removed 3 for almost' \
  'Test-integrity: remove 3 for almost' \
  'Test-integrity: removed 3 obsolete tests' \
  'Test-integrity: intentional #70' \
  'Test-integrity: removed three for almost'
do
  out=$(compare "$ROOT/b4.json" "$ROOT/h4.json" "$near"); rc=$?
  if [[ "$rc" -ne 0 ]]; then
    ok "near-match fails closed: ${near:0:40}…"
  else
    bad "near-match wrongly accepted: $near"
  fi
done

# Wrong delta
out=$(compare "$ROOT/b4.json" "$ROOT/h4.json" \
  'Test-integrity: removed 2 for undercount'); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'wrong delta'; then
  ok "wrong-delta waiver fails closed"
else
  bad "wrong-delta waiver (rc=$rc): $out"
fi

# Wrong skip delta
write_metrics "$ROOT/b4s.json" 10 0 0
write_metrics "$ROOT/h4s.json" 10 4 0
out=$(compare "$ROOT/b4s.json" "$ROOT/h4s.json" \
  'Test-integrity: skip +2 for undercount'); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'wrong delta'; then
  ok "wrong skip-delta waiver fails closed"
else
  bad "wrong skip-delta (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "malformed metrics fail closed (never silently become zero)"
# ---------------------------------------------------------------------------
for badjson in \
  '{"total":"nope","skipped":0,"todo":0}' \
  '{"total":-1,"skipped":0,"todo":0}' \
  '{"total":1.5,"skipped":0,"todo":0}' \
  '{"total":null,"skipped":0,"todo":0}' \
  '{"skipped":0,"todo":0}' \
  '{"total":5,"skipped":-2,"todo":0}' \
  '{"total":2,"skipped":5,"todo":0}'
do
  printf '%s\n' "$badjson" > "$ROOT/bad.json"
  write_metrics "$ROOT/ok.json" 5 0 0
  out=$(compare "$ROOT/ok.json" "$ROOT/bad.json" 2>&1); rc=$?
  if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'unparseable|must be|exceeds|test-integrity'; then
    ok "malformed metrics rejected: ${badjson:0:40}…"
  else
    bad "malformed metrics accepted: $badjson → $out"
  fi
done

# Unparseable runner output
printf 'all good, trust me\n' > "$ROOT/garbage.txt"
out=$(node "$TI" parse --input "$ROOT/garbage.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'could not parse'; then
  ok "unparseable runner output fails closed"
else
  bad "unparseable runner output (rc=$rc): $out"
fi

# Explicit metrics contract
printf 'GIBSON_TEST_METRICS total=12 skipped=1 todo=2\n' > "$ROOT/explicit.txt"
out=$(node "$TI" parse --input "$ROOT/explicit.txt" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 12' \
  && echo "$out" | grep -q '"skipped": 1' && echo "$out" | grep -q '"todo": 2'; then
  ok "GIBSON_TEST_METRICS kv contract parses"
else
  bad "explicit kv parse (rc=$rc): $out"
fi

printf 'GIBSON_TEST_METRICS {"total":9,"skipped":0,"todo":1}\n' > "$ROOT/explicitj.txt"
out=$(node "$TI" parse --input "$ROOT/explicitj.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 9' \
  && ok "GIBSON_TEST_METRICS JSON contract parses" \
  || bad "explicit json parse (rc=$rc): $out"

# Vitest / jest / node:test shapes
printf 'Tests  8 passed | 2 skipped (10)\n' > "$ROOT/vitest.txt"
out=$(node "$TI" parse --input "$ROOT/vitest.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' && echo "$out" | grep -q '"skipped": 2' \
  && ok "vitest summary parses" || bad "vitest parse (rc=$rc): $out"

printf 'Tests:       1 skipped, 9 passed, 10 total\n' > "$ROOT/jest.txt"
out=$(node "$TI" parse --input "$ROOT/jest.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' \
  && ok "jest summary parses" || bad "jest parse (rc=$rc): $out"

printf '# tests 10\n# pass 8\n# skip 1\n# todo 1\n# fail 0\n' > "$ROOT/node.txt"
out=$(node "$TI" parse --input "$ROOT/node.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"todo": 1' \
  && ok "node:test counters parse" || bad "node:test parse (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "added tests / reduced skips pass without waiver"
# ---------------------------------------------------------------------------
write_metrics "$ROOT/b5.json" 10 3 0
write_metrics "$ROOT/h5.json" 14 1 0
out=$(compare "$ROOT/b5.json" "$ROOT/h5.json" ""); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -qiE 'rose by 4|PASS'; then
  ok "added tests and reduced skips pass without waiver"
else
  bad "improvement path (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "regeneration without flag/reason fails; auditable regeneration works"
# ---------------------------------------------------------------------------
# Build a tiny fake target repo that gate-baseline can run against.
FAKE="$ROOT/fake-repo"
mkdir -p "$FAKE/.agents"
GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"
$GIT init -q "$FAKE"
git -C "$FAKE" symbolic-ref HEAD refs/heads/main
# Gate config: only the test step, a deterministic metrics-emitting command
cat > "$FAKE/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
echo base > "$FAKE/README"
$GIT -C "$FAKE" add -A
$GIT -C "$FAKE" commit -q -m "base"

# First baseline — no regenerate needed
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -qE '"total":[[:space:]]*10' "$FAKE/.gibson-baseline.json"; then
  ok "initial baseline records test_metrics.total=10"
else
  bad "initial baseline (rc=$rc): $out"
fi

# Shrink suite without --regenerate / --reason → refuse
cat > "$FAKE/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=7 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'regenerat|--reason|test-integrity'; then
  ok "baseline reduction without --regenerate/--reason fails closed"
else
  bad "silent baseline shrink (rc=$rc): $out"
fi

# Still has old total
grep -qE '"total":[[:space:]]*10' "$FAKE/.gibson-baseline.json" \
  && ok "refused regenerate left prior baseline intact" \
  || bad "baseline was overwritten despite refusal"

# --regenerate without --reason
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" \
  --regenerate 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'reason'; then
  ok "regenerate without --reason fails closed"
else
  bad "regenerate without reason (rc=$rc): $out"
fi

# --regenerate with empty reason
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" \
  --regenerate --reason '' 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then
  ok "regenerate with empty reason fails closed"
else
  bad "empty reason accepted (rc=$rc): $out"
fi

# Legitimate journaled regenerate
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" \
  --regenerate --reason 'removed obsolete suite after #70' 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -qE '"total":[[:space:]]*7' "$FAKE/.gibson-baseline.json"; then
  ok "regenerate with reason rewrites baseline metrics"
else
  bad "journaled regenerate (rc=$rc): $out"
fi

JOURNAL="$FAKE/.gibson/test-integrity-journal.jsonl"
if [[ -f "$JOURNAL" ]] \
  && grep -q 'removed obsolete suite after #70' "$JOURNAL" \
  && grep -qE '"total":[[:space:]]*10' "$JOURNAL" \
  && grep -qE '"total":[[:space:]]*7' "$JOURNAL"; then
  ok "append-only journal records timestamp/reason/old/new metrics"
else
  bad "journal missing or incomplete: $(cat "$JOURNAL" 2>/dev/null || echo none)"
fi

# Second regenerate appends (does not rewrite)
cat > "$FAKE/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=6 skipped=1 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" \
  --regenerate --reason 'one more obsolete under #70' 2>&1); rc=$?
lines=$(wc -l < "$JOURNAL" | tr -d ' ')
if [[ "$rc" -eq 0 && "$lines" -ge 2 ]]; then
  ok "journal is append-only across regenerations (lines=$lines)"
else
  bad "journal append (rc=$rc lines=$lines): $out"
fi

# ---------------------------------------------------------------------------
echo "gate.sh hard-fails on integrity; surfaces waiver; preserves failure baseline"
# ---------------------------------------------------------------------------
# Fresh fake repo for gate.sh
GDIR="$ROOT/gate-run"
mkdir -p "$GDIR/.agents"
$GIT init -q "$GDIR"
git -C "$GDIR" symbolic-ref HEAD refs/heads/main
cat > "$GDIR/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=5 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
echo x > "$GDIR/README"
$GIT -C "$GDIR" add -A
$GIT -C "$GDIR" commit -q -m "g"

# Baseline at 5 tests
(cd "$GDIR" && bash "$BASELINE_SH" --out "$GDIR/.gibson-baseline.json") >/dev/null 2>&1

# Shrink tests → gate must fail with test-integrity
cat > "$GDIR/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=3 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$GDIR" && bash "$GATE" --baseline "$GDIR/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'test-integrity' \
  && echo "$out" | grep -qE 'dropped by 2|removed 2'; then
  ok "gate.sh fails on deletion with test-integrity diagnosis"
else
  bad "gate.sh deletion (rc=$rc): $out"
fi

# With correct waiver via env (inert PR body)
out=$(cd "$GDIR" && GIBSON_TEST_INTEGRITY_TEXT='Test-integrity: removed 2 for obsolete under #70' \
  bash "$GATE" --baseline "$GDIR/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'WAIVER accepted' \
  && echo "$out" | grep -q 'obsolete under #70'; then
  ok "gate.sh accepts exact waiver and surfaces it for the reviewer"
else
  bad "gate.sh waiver (rc=$rc): $out"
fi

# New skips
cat > "$GDIR/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=5 skipped=2 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$GDIR" && bash "$GATE" --baseline "$GDIR/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'test-integrity' \
  && echo "$out" | grep -qE 'skip/todo rose by 2|skip \+2'; then
  ok "gate.sh fails on new skips with exact delta"
else
  bad "gate.sh new skips (rc=$rc): $out"
fi

# Trusted-source labeling: CI path never treats a local baseline as self-authorizing
write_metrics "$ROOT/ci-base.json" 10 0 0
write_metrics "$ROOT/ci-head.json" 9 0 0
out=$(compare "$ROOT/ci-base.json" "$ROOT/ci-head.json" "" "merge-base"); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'merge-base'; then
  ok "compare surfaces trusted-source=merge-base (CI anchor, not local baseline)"
else
  bad "trusted-source labeling (rc=$rc): $out"
fi

# PR text is inert: a payload that would be dangerous if eval'd must stay data
payload='Test-integrity: removed 1 for $(touch '"$ROOT"'/pwned) and `touch '"$ROOT"'/pwned2`'
write_metrics "$ROOT/ev-b.json" 10 0 0
write_metrics "$ROOT/ev-h.json" 9 0 0
out=$(compare "$ROOT/ev-b.json" "$ROOT/ev-h.json" "$payload"); rc=$?
if [[ "$rc" -eq 0 && ! -e "$ROOT/pwned" && ! -e "$ROOT/pwned2" ]]; then
  ok "waiver text is inert data (no shell eval of PR body)"
else
  bad "waiver text may have been evaluated (rc=$rc pwned=$(ls "$ROOT"/pwned* 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
echo "existing green-gate failure comparison is preserved"
# ---------------------------------------------------------------------------
# typecheck newly red must still fail the gate (integrity must not weaken it)
cat > "$GDIR/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "false",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=5 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$GDIR" && bash "$GATE" --baseline "$GDIR/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'typecheck|newly failing|FAIL'; then
  ok "gate.sh still hard-fails on new typecheck failures"
else
  bad "failure baseline weakened (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo
echo "gate.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
