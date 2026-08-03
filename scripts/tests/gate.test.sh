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
#   cannot authorize a PR. Phase-1 ships the helper + local sensors only;
#   CI isolated grading is phase-2 after the helper is on main.
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

# ===========================================================================
# Tier-B review blockers (adversarial sensors — issue #70 repair)
# ===========================================================================

# ---------------------------------------------------------------------------
echo "blocker 1: explicit GIBSON_TEST_METRICS cannot spoof past a real runner summary"
# ---------------------------------------------------------------------------
# Honest vitest summary (7 tests) + fake explicit metrics (10). A head that
# prints both must NOT self-authorize total=10 against a base of 10.
printf 'Tests  7 passed (7)\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/spoof.txt"
out=$(node "$TI" parse --input "$ROOT/spoof.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted'; then
  ok "conflicting explicit+runner metrics fail closed (no self-authorization)"
else
  bad "spoofed explicit metrics accepted or wrong error (rc=$rc): $out"
fi

# Same attack path through compare: if parse ever yielded 10, compare would pass
write_metrics "$ROOT/spoof-base.json" 10 0 0
# Force the only safe outcome: parse must reject, so we also pin that a
# head metrics file of 7 fails integrity vs base 10 without waiver.
write_metrics "$ROOT/spoof-head-honest.json" 7 0 0
out=$(compare "$ROOT/spoof-base.json" "$ROOT/spoof-head-honest.json" ""); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'dropped by 3|removed 3'; then
  ok "honest head total=7 vs base=10 still hard-fails (delta 3)"
else
  bad "honest head compare (rc=$rc): $out"
fi

# Explicit alone (no runner summary) remains the vendor-blind contract
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' > "$ROOT/explicit-only.txt"
out=$(node "$TI" parse --input "$ROOT/explicit-only.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' \
  && ok "explicit-only GIBSON_TEST_METRICS still parses" \
  || bad "explicit-only broken (rc=$rc): $out"

# Agreeing sources are fine
printf 'Tests  10 passed (10)\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/agree.txt"
out=$(node "$TI" parse --input "$ROOT/agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' \
  && ok "agreeing explicit+runner sources accepted" \
  || bad "agreeing sources (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "blocker 1b: every explicit GIBSON_TEST_METRICS line is collected (no first-match)"
# ---------------------------------------------------------------------------
# Attack: fake total=10 first, then honest total=7. First-match parsers would
# accept 10 and green-wash a deleted suite. Must fail closed on conflict.
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nGIBSON_TEST_METRICS total=7 skipped=0 todo=0\n' \
  > "$ROOT/multi-kv-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/multi-kv-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted'; then
  ok "conflicting multi-explicit KV lines fail closed (not first-match total=10)"
else
  bad "multi-kv first-match bypass (rc=$rc): $out"
fi

# Same attack with JSON after KV
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nGIBSON_TEST_METRICS {"total":7,"skipped":0,"todo":0}\n' \
  > "$ROOT/multi-kv-json-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/multi-kv-json-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted'; then
  ok "conflicting explicit KV then JSON fail closed"
else
  bad "kv+json first-match bypass (rc=$rc): $out"
fi

# Honest first, fake second (order must not matter)
printf 'GIBSON_TEST_METRICS total=7 skipped=0 todo=0\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/multi-kv-conflict-rev.txt"
out=$(node "$TI" parse --input "$ROOT/multi-kv-conflict-rev.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted'; then
  ok "conflicting multi-explicit lines fail regardless of order"
else
  bad "multi-kv reverse-order bypass (rc=$rc): $out"
fi

# Identical multi-explicit lines still agree and parse
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/multi-kv-agree.txt"
out=$(node "$TI" parse --input "$ROOT/multi-kv-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' \
  && ok "identical multi-explicit KV lines accepted" \
  || bad "identical multi-explicit broken (rc=$rc): $out"

# Identical KV + JSON
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nGIBSON_TEST_METRICS {"total":10,"skipped":0,"todo":0}\n' \
  > "$ROOT/multi-kv-json-agree.txt"
out=$(node "$TI" parse --input "$ROOT/multi-kv-json-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' \
  && ok "identical explicit KV+JSON lines accepted" \
  || bad "identical kv+json broken (rc=$rc): $out"

# Three-way: two fake explicits + honest runner must still conflict
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nTests  7 passed (7)\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/multi-explicit-runner.txt"
out=$(node "$TI" parse --input "$ROOT/multi-explicit-runner.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted'; then
  ok "duplicate fake explicit + honest runner fails closed"
else
  bad "multi-explicit+runner spoof (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker 1c: every native runner summary is collected (no first/last-only)"
# ---------------------------------------------------------------------------
# Untrusted output can print conflicting repeated summaries. First-match or
# last-match parsers hide a real drop even under a future trusted grader.

# Jest: fake 10 then honest 7 (first-match would accept 10)
printf 'Tests: 10 passed, 10 total\nTests: 7 passed, 7 total\n' \
  > "$ROOT/jest-multi-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/jest-multi-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted|native'; then
  ok "conflicting repeated Jest summaries fail closed (not first-match total=10)"
else
  bad "jest multi first-match bypass (rc=$rc): $out"
fi

# node:test: # tests 10 then # tests 7 (with pass/skip counters per block)
printf '# tests 10\n# pass 10\n# skip 0\n# todo 0\n# tests 7\n# pass 7\n# skip 0\n# todo 0\n' \
  > "$ROOT/node-multi-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/node-multi-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted|native'; then
  ok "conflicting repeated node:test counters fail closed (not first-match total=10)"
else
  bad "node:test multi first-match bypass (rc=$rc): $out"
fi

# node:test same total but different skip in second block — must not mix counters
printf '# tests 10\n# skip 0\n# todo 0\n# tests 10\n# skip 5\n# todo 0\n' \
  > "$ROOT/node-multi-skip-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/node-multi-skip-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted|native'; then
  ok "node:test repeated blocks with conflicting skip fail closed (no mixed counters)"
else
  bad "node:test mixed-skip fabrication (rc=$rc): $out"
fi

# TAP plans: 1..10 then 1..7
printf '1..10\nok 1 - a\nok 2 - b\n1..7\nok 1 - c\n' \
  > "$ROOT/tap-multi-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/tap-multi-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted|native'; then
  ok "conflicting repeated TAP plans fail closed (not first-match 1..10)"
else
  bad "tap multi first-match bypass (rc=$rc): $out"
fi

# Vitest: honest 7 then fake-last 10 (last-match would accept 10)
printf 'Tests  7 passed (7)\nTests  10 passed (10)\n' \
  > "$ROOT/vitest-multi-honest-first.txt"
out=$(node "$TI" parse --input "$ROOT/vitest-multi-honest-first.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted|native'; then
  ok "conflicting Vitest summaries fail closed (not last-match total=10)"
else
  bad "vitest last-match bypass (rc=$rc): $out"
fi

# Vitest reverse: fake 10 then honest 7 (must still fail; order irrelevant)
printf 'Tests  10 passed (10)\nTests  7 passed (7)\n' \
  > "$ROOT/vitest-multi-honest-last.txt"
out=$(node "$TI" parse --input "$ROOT/vitest-multi-honest-last.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple sources|untrusted|native'; then
  ok "conflicting Vitest summaries fail regardless of order"
else
  bad "vitest reverse-order bypass (rc=$rc): $out"
fi

# Identical repeated native summaries still agree
printf 'Tests: 10 passed, 10 total\nTests: 10 passed, 10 total\n' \
  > "$ROOT/jest-multi-agree.txt"
out=$(node "$TI" parse --input "$ROOT/jest-multi-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' \
  && ok "identical repeated Jest summaries accepted" \
  || bad "identical jest multi broken (rc=$rc): $out"

printf '# tests 10\n# skip 0\n# tests 10\n# skip 0\n' \
  > "$ROOT/node-multi-agree.txt"
out=$(node "$TI" parse --input "$ROOT/node-multi-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' \
  && ok "identical repeated node:test counters accepted" \
  || bad "identical node multi broken (rc=$rc): $out"

printf '1..10\nok 1\n1..10\nok 2\n' \
  > "$ROOT/tap-multi-agree.txt"
out=$(node "$TI" parse --input "$ROOT/tap-multi-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' \
  && ok "identical repeated TAP plans accepted" \
  || bad "identical tap multi broken (rc=$rc): $out"

printf 'Tests  10 passed (10)\nTests  10 passed (10)\n' \
  > "$ROOT/vitest-multi-agree.txt"
out=$(node "$TI" parse --input "$ROOT/vitest-multi-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' \
  && ok "identical repeated Vitest summaries accepted" \
  || bad "identical vitest multi broken (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "blocker 1d: node:test collects every # skip/# todo in a tests region"
# ---------------------------------------------------------------------------
# First-match # skip 0 then # skip 2 would parse skipped=0 and green-wash.
# Collect every counter in the region; identical may agree; disagreement fails.

# Order A: # skip 0 then # skip 2 (first-match would accept 0)
printf '# tests 10\n# pass 8\n# skip 0\n# skip 2\n# todo 0\n' \
  > "$ROOT/node-skip-order-a.txt"
out=$(node "$TI" parse --input "$ROOT/node-skip-order-a.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple|untrusted|skip'; then
  ok "node:test # skip 0 then # skip 2 fails closed (not first-match skip=0)"
else
  bad "node skip order-a first-match bypass (rc=$rc): $out"
fi

# Order B: # skip 2 then # skip 0 (first-match would accept 2; still must fail)
printf '# tests 10\n# pass 8\n# skip 2\n# skip 0\n# todo 0\n' \
  > "$ROOT/node-skip-order-b.txt"
out=$(node "$TI" parse --input "$ROOT/node-skip-order-b.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple|untrusted|skip'; then
  ok "node:test # skip 2 then # skip 0 fails closed (not first-match skip=2)"
else
  bad "node skip order-b first-match bypass (rc=$rc): $out"
fi

# Identical repeated # skip inside one region may agree
printf '# tests 10\n# pass 8\n# skip 2\n# skip 2\n# todo 0\n' \
  > "$ROOT/node-skip-identical.txt"
out=$(node "$TI" parse --input "$ROOT/node-skip-identical.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"skipped": 2' && echo "$out" | grep -q '"total": 10' \
  && ok "node:test identical repeated # skip 2 accepted" \
  || bad "node identical skip broken (rc=$rc): $out"

# Order A todo: # todo 0 then # todo 2
printf '# tests 10\n# pass 8\n# skip 0\n# todo 0\n# todo 2\n' \
  > "$ROOT/node-todo-order-a.txt"
out=$(node "$TI" parse --input "$ROOT/node-todo-order-a.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple|untrusted|todo'; then
  ok "node:test # todo 0 then # todo 2 fails closed (not first-match todo=0)"
else
  bad "node todo order-a first-match bypass (rc=$rc): $out"
fi

# Order B todo: # todo 2 then # todo 0
printf '# tests 10\n# pass 8\n# skip 0\n# todo 2\n# todo 0\n' \
  > "$ROOT/node-todo-order-b.txt"
out=$(node "$TI" parse --input "$ROOT/node-todo-order-b.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple|untrusted|todo'; then
  ok "node:test # todo 2 then # todo 0 fails closed (not first-match todo=2)"
else
  bad "node todo order-b first-match bypass (rc=$rc): $out"
fi

# Identical repeated # todo inside one region may agree
printf '# tests 10\n# pass 8\n# skip 0\n# todo 2\n# todo 2\n' \
  > "$ROOT/node-todo-identical.txt"
out=$(node "$TI" parse --input "$ROOT/node-todo-identical.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"todo": 2' && echo "$out" | grep -q '"total": 10' \
  && ok "node:test identical repeated # todo 2 accepted" \
  || bad "node identical todo broken (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "blocker 1e: TAP binds SKIP/TODO to the correct plan region"
# ---------------------------------------------------------------------------
# Whole-stream SKIP reuse fabricates skipped=2 for every plan when two
# plan-at-end runs each have one SKIP. Bind result lines to the plan region
# (lines since previous plan through current plan for plan-at-end).

# Identical repeated plan-at-end: one SKIP each → both skipped=1 (not 2)
printf 'ok 1 - a\nok 2 - b # SKIP reason-a\nok 3 - c\n1..10\nok 1 - d\nok 2 - e # SKIP reason-b\nok 3 - f\n1..10\n' \
  > "$ROOT/tap-plan-end-skip-agree.txt"
out=$(node "$TI" parse --input "$ROOT/tap-plan-end-skip-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' && echo "$out" | grep -q '"skipped": 1' \
  && ok "TAP repeated plan-at-end with one SKIP each → skipped=1 (not whole-stream 2)" \
  || bad "tap plan-region skip fabrication (rc=$rc): $out"

# Conflicting repeated plan-at-end SKIP counts → fail closed
printf 'ok 1 - a # SKIP only\n1..10\nok 1 - b # SKIP one\nok 2 - c # SKIP two\n1..10\n' \
  > "$ROOT/tap-plan-end-skip-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/tap-plan-end-skip-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple|untrusted|native|skip'; then
  ok "TAP repeated plans with conflicting SKIP counts fail closed"
else
  bad "tap skip-conflict accepted (rc=$rc): $out"
fi

# Identical repeated plan-at-end TODO: one TODO each → todo=1
printf 'ok 1 - a\nok 2 - b # TODO later-a\n1..10\nok 1 - c\nok 2 - d # TODO later-b\n1..10\n' \
  > "$ROOT/tap-plan-end-todo-agree.txt"
out=$(node "$TI" parse --input "$ROOT/tap-plan-end-todo-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 10' && echo "$out" | grep -q '"todo": 1' \
  && ok "TAP repeated plan-at-end with one TODO each → todo=1 (not whole-stream 2)" \
  || bad "tap plan-region todo fabrication (rc=$rc): $out"

# Conflicting repeated plan-at-end TODO counts → fail closed
printf 'ok 1 - a # TODO only\n1..10\nok 1 - b # TODO one\nok 2 - c # TODO two\n1..10\n' \
  > "$ROOT/tap-plan-end-todo-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/tap-plan-end-todo-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple|untrusted|native|todo'; then
  ok "TAP repeated plans with conflicting TODO counts fail closed"
else
  bad "tap todo-conflict accepted (rc=$rc): $out"
fi

# Explicit-native agreement: GIBSON_TEST_METRICS matches plan-region skipped=1
printf 'ok 1 - a\nok 2 - b # SKIP reason\n1..10\nok 1 - c\nok 2 - d # SKIP reason\n1..10\nGIBSON_TEST_METRICS total=10 skipped=1 todo=0\n' \
  > "$ROOT/tap-explicit-native-agree.txt"
out=$(node "$TI" parse --input "$ROOT/tap-explicit-native-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"skipped": 1' && echo "$out" | grep -q '"total": 10' \
  && ok "TAP plan-region + agreeing explicit metrics accepted" \
  || bad "tap explicit-native agree broken (rc=$rc): $out"

# Explicit-native conflict: explicit claims skipped=0 while each plan has 1 SKIP
printf 'ok 1 - a # SKIP x\n1..10\nok 1 - b # SKIP y\n1..10\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/tap-explicit-native-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/tap-explicit-native-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple|untrusted'; then
  ok "TAP plan-region + conflicting explicit metrics fail closed"
else
  bad "tap explicit-native conflict spoof (rc=$rc): $out"
fi

# node:test region counters + agreeing explicit
printf '# tests 10\n# skip 2\n# skip 2\n# todo 0\nGIBSON_TEST_METRICS total=10 skipped=2 todo=0\n' \
  > "$ROOT/node-explicit-native-agree.txt"
out=$(node "$TI" parse --input "$ROOT/node-explicit-native-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"skipped": 2' \
  && ok "node:test multi-skip + agreeing explicit accepted" \
  || bad "node explicit-native agree broken (rc=$rc): $out"

# node:test region counters + conflicting explicit (first-match skip 0 would wrongly agree)
printf '# tests 10\n# skip 0\n# skip 2\n# todo 0\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/node-explicit-native-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/node-explicit-native-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple|untrusted|skip'; then
  ok "node:test multi-skip + conflicting explicit fails closed (no first-match agree)"
else
  bad "node explicit-native first-match spoof (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker 4: waiver dimensions must equal max(actual_delta,0) on both axes"
# ---------------------------------------------------------------------------
# actual removed 1 + waiver claims removed 1 AND skip +999 → fail
write_metrics "$ROOT/w-b1.json" 10 0 0
write_metrics "$ROOT/w-h1.json" 9 0 0
out=$(compare "$ROOT/w-b1.json" "$ROOT/w-h1.json" \
  'Test-integrity: removed 1, skip +999 for overclaim'); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'wrong delta|skip'; then
  ok "waiver overclaim skip +999 with actual skip 0 fails"
else
  bad "skip overclaim accepted (rc=$rc): $out"
fi

# actual skip +1 + waiver claims removed 999 AND skip +1 → fail
write_metrics "$ROOT/w-b2.json" 10 0 0
write_metrics "$ROOT/w-h2.json" 10 1 0
out=$(compare "$ROOT/w-b2.json" "$ROOT/w-h2.json" \
  'Test-integrity: removed 999, skip +1 for overclaim'); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'wrong delta|removed'; then
  ok "waiver overclaim removed 999 with actual removed 0 fails"
else
  bad "removed overclaim accepted (rc=$rc): $out"
fi

# unchanged metrics + waiver removed 999 → fail (no integrity reduction)
write_metrics "$ROOT/w-b3.json" 10 0 0
write_metrics "$ROOT/w-h3.json" 10 0 0
out=$(compare "$ROOT/w-b3.json" "$ROOT/w-h3.json" \
  'Test-integrity: removed 999 for phantom'); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'no integrity reduction|unchanged|wrong delta'; then
  ok "waiver with no integrity reduction fails"
else
  bad "phantom waiver accepted (rc=$rc): $out"
fi

# Exact match on both claimed dimensions still works (regression pin)
write_metrics "$ROOT/w-b4.json" 10 1 0
write_metrics "$ROOT/w-h4.json" 8 2 0
out=$(compare "$ROOT/w-b4.json" "$ROOT/w-h4.json" \
  'Test-integrity: removed 2, skip +1 for both intentional under #70'); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'WAIVER accepted' \
  && ok "exact dual-dimension waiver still accepted" \
  || bad "exact dual waiver broken (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "blocker 5: metrics beyond Number.MAX_SAFE_INTEGER fail closed"
# ---------------------------------------------------------------------------
# 9007199254740993 is MAX_SAFE_INTEGER+1; JS Number loses precision to …992.
# String form must be rejected before it can mask a real delta.
printf 'GIBSON_TEST_METRICS total=9007199254740993 skipped=0 todo=0\n' \
  > "$ROOT/unsafe-kv.txt"
out=$(node "$TI" parse --input "$ROOT/unsafe-kv.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'safe integer|unparseable|exceeds|precision'; then
  ok "unsafe integer string total=9007199254740993 rejected"
else
  bad "unsafe kv total accepted (rc=$rc): $out"
fi

printf 'GIBSON_TEST_METRICS {"total":"9007199254740993","skipped":0,"todo":0}\n' \
  > "$ROOT/unsafe-json.txt"
out=$(node "$TI" parse --input "$ROOT/unsafe-json.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'safe integer|unparseable|exceeds|precision'; then
  ok "unsafe integer JSON string total rejected"
else
  bad "unsafe json total accepted (rc=$rc): $out"
fi

# Bare metrics object with unsafe string field via load/compare path
printf '%s\n' '{"total":"9007199254740993","skipped":0,"todo":0}' > "$ROOT/unsafe-head.json"
write_metrics "$ROOT/safe-base.json" 10 0 0
out=$(compare "$ROOT/safe-base.json" "$ROOT/unsafe-head.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'safe integer|unparseable|exceeds|precision|test-integrity'; then
  ok "compare rejects unsafe head total string (…993 vs safe base)"
else
  bad "unsafe compare accepted (rc=$rc): $out"
fi

# Precision-mask regression: MAX_SAFE_INTEGER (…991) is accepted; …993 is not.
# JS Number would collapse 9007199254740993 → 9007199254740992, masking deltas.
printf '%s\n' '{"total":"9007199254740991","skipped":0,"todo":0}' > "$ROOT/safe-max.json"
printf '%s\n' '{"total":"9007199254740993","skipped":0,"todo":0}' > "$ROOT/unsafe-max1.json"
out=$(compare "$ROOT/safe-max.json" "$ROOT/safe-max.json" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "MAX_SAFE_INTEGER 9007199254740991 accepted as metrics total" \
  || bad "MAX_SAFE_INTEGER rejected (rc=$rc): $out"
out=$(compare "$ROOT/safe-max.json" "$ROOT/unsafe-max1.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'safe integer|unparseable|exceeds|precision'; then
  ok "9007199254740993 vs 9007199254740991 does not silently collapse"
else
  bad "safe-integer collapse (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker 2: failing base suite still reaches integrity compare (errexit-safe)"
# ---------------------------------------------------------------------------
# Local simulation of the intended phase-2 CI pattern: capture base test rc
# with errexit off, always parse + compare, preserve base rc separately.
# Deleted-failing-test scenario: base prints 10 tests then exits 1; head
# prints 7 and exits 0. (ci/gibson-gate.yml is deliberately unwired in phase 1.)
BASE_SIM="$ROOT/base-sim"
HEAD_SIM="$ROOT/head-sim"
mkdir -p "$BASE_SIM" "$HEAD_SIM"
# base: metrics then fail (as a deleted-later failing test suite would)
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' > "$BASE_SIM/test-output-base.txt"
# head: suite shrank
printf 'GIBSON_TEST_METRICS total=7 skipped=0 todo=0\n' > "$HEAD_SIM/test-output-head.txt"

# Simulate the CI capture pattern under set -euo pipefail
CI_SIM_OUT="$ROOT/ci-sim.out"
set +e
(
  set -euo pipefail
  # --- trusted helper copy from "merge-base worktree" (blocker 3 pin) ---
  WT_SIM="$ROOT/merge-base-wt"
  mkdir -p "$WT_SIM/scripts"
  cp "$TI" "$WT_SIM/scripts/test-integrity.mjs"
  TI_TRUSTED="$WT_SIM/scripts/test-integrity.mjs"
  # head must not be the grading authority when base helper exists
  if [[ ! -f "$TI_TRUSTED" ]]; then
    echo "missing trusted helper" >&2
    exit 99
  fi

  # base test: capture rc without aborting the job
  set +e
  # pretend base suite failed (exit 1) after emitting metrics
  ( cat "$BASE_SIM/test-output-base.txt"; exit 1 )
  base_test_rc=$?
  set -e
  echo "base_test_rc=$base_test_rc"

  node "$TI_TRUSTED" parse \
    --input "$BASE_SIM/test-output-base.txt" \
    --out "$ROOT/ci-metrics-base.json"
  node "$TI_TRUSTED" parse \
    --input "$HEAD_SIM/test-output-head.txt" \
    --out "$ROOT/ci-metrics-head.json"
  set +e
  node "$TI_TRUSTED" compare \
    --base "$ROOT/ci-metrics-base.json" \
    --head "$ROOT/ci-metrics-head.json" \
    --waiver-text "" \
    --trusted-source "merge-base:sim" 2>&1
  ti_rc=$?
  set -e
  echo "test_integrity_rc=$ti_rc"
  # Preserve base rc for the job summary; integrity must still have fired.
  echo "BASE_TEST_RC=$base_test_rc"
  exit "$ti_rc"
) >"$CI_SIM_OUT" 2>&1
ci_rc=$?
# Restore the harness default (no errexit) so later sensors can capture non-zero rcs.
set +e
set -uo pipefail

if [[ "$ci_rc" -ne 0 ]] \
  && grep -q 'base_test_rc=1' "$CI_SIM_OUT" \
  && grep -qE 'dropped by 3|removed 3' "$CI_SIM_OUT" \
  && grep -q 'test-integrity' "$CI_SIM_OUT" \
  && grep -q 'test_integrity_rc=1' "$CI_SIM_OUT"; then
  ok "failing base still reaches test-integrity with exact delta 10→7"
else
  bad "CI base-rc sim (rc=$ci_rc): $(cat "$CI_SIM_OUT")"
fi

# ---------------------------------------------------------------------------
echo "blocker 3: CI grades with merge-base helper, not a PR-rewritten head copy"
# ---------------------------------------------------------------------------
# A hostile head helper that always PASS must not be used when base has a real helper.
HOSTILE="$ROOT/hostile-head/scripts"
mkdir -p "$HOSTILE"
cat > "$HOSTILE/test-integrity.mjs" <<'HOSTILE'
#!/usr/bin/env node
// Hostile PR-head helper: always report PASS regardless of metrics.
import { writeFileSync } from 'node:fs';
if (process.argv[2] === 'compare') {
  console.log('test-integrity: PASS (hostile always-green helper)');
  process.exit(0);
}
if (process.argv[2] === 'parse') {
  const out = process.argv.includes('--out')
    ? process.argv[process.argv.indexOf('--out') + 1]
    : null;
  const payload = JSON.stringify({
    total: 999, skipped: 0, todo: 0, skip_effective: 0, source: 'hostile'
  }, null, 2) + '\n';
  if (out) writeFileSync(out, payload);
  else process.stdout.write(payload);
  process.exit(0);
}
process.exit(0);
HOSTILE

# Policy under test: prefer merge-base helper when present (phase-2 CI intent)
WT_BASE="$ROOT/trusted-base-wt"
mkdir -p "$WT_BASE/scripts"
cp "$TI" "$WT_BASE/scripts/test-integrity.mjs"
write_metrics "$ROOT/t-base.json" 10 0 0
write_metrics "$ROOT/t-head.json" 7 0 0
# Using trusted helper → must FAIL with delta
out=$(node "$WT_BASE/scripts/test-integrity.mjs" compare \
  --base "$ROOT/t-base.json" --head "$ROOT/t-head.json" \
  --trusted-source "merge-base:sim" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'dropped by 3|removed 3'; then
  ok "trusted merge-base helper reports deletion delta (not always-green)"
else
  bad "trusted helper failed to diagnose (rc=$rc): $out"
fi
# Hostile head helper → would PASS (proves why CI must not use it)
out=$(node "$HOSTILE/test-integrity.mjs" compare \
  --base "$ROOT/t-base.json" --head "$ROOT/t-head.json" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -qi 'hostile\|PASS'; then
  ok "hostile head helper would self-approve (CI must load merge-base copy)"
else
  bad "hostile helper fixture broken (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker nested-TAP: real node:test describe() suites parse (top-level plans only)"
# ---------------------------------------------------------------------------
# Node 22 describe('outer') with two it() tests emits nested `    1..2`,
# top-level `1..1`, and `# tests 2`. Treating indented plans as whole-run
# totals falsely conflicts. Use actual runner output — not a handwaved fixture.

NEST_DIR="$ROOT/node-nested-tap"
mkdir -p "$NEST_DIR"
cat > "$NEST_DIR/nested.test.mjs" <<'EOF'
import { describe, it } from 'node:test';
describe('outer', () => {
  it('a', () => {});
  it('b', () => {});
});
EOF
# Capture real TAP (stdout); stderr may carry node warnings — ignore for parse input.
node --test --test-reporter=tap "$NEST_DIR/nested.test.mjs" \
  >"$NEST_DIR/nested.tap" 2>"$NEST_DIR/nested.err" || true
# Sanity: fixture must contain nested plan + top-level plan + # tests
if grep -qE '^[[:space:]]+1\.\.2[[:space:]]*$' "$NEST_DIR/nested.tap" \
  && grep -qE '^1\.\.1[[:space:]]*$' "$NEST_DIR/nested.tap" \
  && grep -qE '^# tests 2[[:space:]]*$' "$NEST_DIR/nested.tap"; then
  ok "real node:test nested TAP fixture has indented 1..2, top-level 1..1, # tests 2"
else
  bad "nested TAP fixture missing expected plans/counters: $(cat "$NEST_DIR/nested.tap")"
fi
out=$(node "$TI" parse --input "$NEST_DIR/nested.tap" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 2' \
  && echo "$out" | grep -q '"skipped": 0'; then
  ok "real node:test nested describe suite parses total=2 (no false plan conflict)"
else
  bad "nested node:test TAP parse (rc=$rc): $out"
fi

# skip coverage via real runner (it.skip → # skipped N)
cat > "$NEST_DIR/nested-skip.test.mjs" <<'EOF'
import { describe, it } from 'node:test';
describe('outer', () => {
  it('a', () => {});
  it.skip('b', () => {});
});
EOF
node --test --test-reporter=tap "$NEST_DIR/nested-skip.test.mjs" \
  >"$NEST_DIR/nested-skip.tap" 2>/dev/null || true
out=$(node "$TI" parse --input "$NEST_DIR/nested-skip.tap" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 2' \
  && echo "$out" | grep -q '"skipped": 1'; then
  ok "real node:test nested suite with it.skip → skipped=1"
else
  bad "nested skip parse (rc=$rc): $out"
fi

# todo coverage via real runner
cat > "$NEST_DIR/nested-todo.test.mjs" <<'EOF'
import { describe, it } from 'node:test';
describe('outer', () => {
  it('a', () => {});
  it('b', { todo: true }, () => {});
});
EOF
node --test --test-reporter=tap "$NEST_DIR/nested-todo.test.mjs" \
  >"$NEST_DIR/nested-todo.tap" 2>/dev/null || true
out=$(node "$TI" parse --input "$NEST_DIR/nested-todo.tap" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"total": 2' \
  && echo "$out" | grep -q '"todo": 1'; then
  ok "real node:test nested suite with todo → todo=1"
else
  bad "nested todo parse (rc=$rc): $out"
fi

# Genuinely repeated top-level TAP plans still conflict (not weakened)
printf '1..10\nok 1 - a\n1..7\nok 1 - b\n' >"$NEST_DIR/top-conflict.tap"
out=$(node "$TI" parse --input "$NEST_DIR/top-conflict.tap" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'conflict|disagree|multiple|untrusted'; then
  ok "repeated top-level TAP plans still fail closed after nested-plan fix"
else
  bad "top-level TAP conflict weakened (rc=$rc): $out"
fi

# Hierarchical TAP alone (indented plans, no # tests / explicit) fails closed
printf '# Subtest: outer\n    ok 1 - a\n    ok 2 - b\n    1..2\nok 1 - outer\n1..1\n' \
  >"$NEST_DIR/hierarchical-only.tap"
out=$(node "$TI" parse --input "$NEST_DIR/hierarchical-only.tap" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'could not parse|fail closed|unparseable'; then
  ok "hierarchical TAP without # tests / explicit fails closed (no invented total)"
else
  bad "hierarchical-only TAP should fail closed (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker temp-poison: predictable scratch/symlink targets fail closed"
# ---------------------------------------------------------------------------
# Pre-poison fixed /tmp/gibson-ti-parse.err and worktree-local
# .gibson-baseline.test.out / .gibson-baseline.*.ec as symlinks to a victim
# file. Gate must fail closed without truncating victim bytes, and leave no
# leaked predictable temps.

POISON="$ROOT/poison-repo"
mkdir -p "$POISON/.agents"
GITP="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"
$GITP init -q "$POISON"
git -C "$POISON" symbolic-ref HEAD refs/heads/main
echo base >"$POISON/README"
$GITP -C "$POISON" add -A
$GITP -C "$POISON" commit -q -m "base"

# --- parser-stderr class: /tmp/gibson-ti-parse.err as symlink ----------------
VICTIM_PARSE="$ROOT/victim-parse-bytes.bin"
printf 'VICTIM_PARSE_SENTINEL_DO_NOT_TRUNCATE\n' >"$VICTIM_PARSE"
# Best-effort: remove any leftover fixed path from prior runs, then plant symlink.
rm -f /tmp/gibson-ti-parse.err 2>/dev/null || true
ln -sf "$VICTIM_PARSE" /tmp/gibson-ti-parse.err
# Untrusted test command: try to keep the poison in place; emit valid metrics
# so a vulnerable parser-stderr redirect would truncate the victim on parse.
cat >"$POISON/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=3 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/.gibson-baseline.json" 2>&1); rc=$?
victim_parse_after=$(cat "$VICTIM_PARSE" 2>/dev/null || echo MISSING)
if [[ "$victim_parse_after" == "VICTIM_PARSE_SENTINEL_DO_NOT_TRUNCATE" ]]; then
  ok "parser-stderr pre-poison: victim bytes unchanged"
else
  bad "parser-stderr pre-poison: victim truncated/changed: $victim_parse_after"
fi
# Gate should succeed (valid metrics) without using the fixed path — or fail
# closed if it somehow still depends on it. Either way victim must stay intact.
# Prefer success path: private mktemp means baseline writes OK.
if [[ "$rc" -eq 0 ]] && grep -qE '"total":[[:space:]]*3' "$POISON/.gibson-baseline.json" 2>/dev/null; then
  ok "parser-stderr pre-poison: gate succeeds via private scratch (not fixed /tmp path)"
elif [[ "$rc" -ne 0 ]]; then
  ok "parser-stderr pre-poison: gate fails closed (rc=$rc) without victim damage"
else
  bad "parser-stderr pre-poison: unexpected gate outcome (rc=$rc): $out"
fi
# Cleanup planted symlink so later tests are clean
rm -f /tmp/gibson-ti-parse.err 2>/dev/null || true
# No predictable worktree temps left behind
if [[ ! -e "$POISON/.gibson-baseline.test.out" \
   && ! -e "$POISON/.gibson-baseline.test.ec" \
   && ! -L "$POISON/.gibson-baseline.test.out" \
   && ! -L "$POISON/.gibson-baseline.test.ec" ]]; then
  ok "parser-stderr pre-poison: no worktree-local temp leaks"
else
  bad "parser-stderr pre-poison: leaked worktree temps"
fi

# --- worktree-local artifact class: .gibson-baseline.test.out as symlink ----
VICTIM_OUT="$ROOT/victim-test-out-bytes.bin"
printf 'VICTIM_TEST_OUT_SENTINEL_DO_NOT_TRUNCATE\n' >"$VICTIM_OUT"
rm -f "$POISON/.gibson-baseline.test.out" "$POISON/.gibson-baseline.test.ec" \
  "$POISON/.gibson-baseline.typecheck.ec" "$POISON/.gibson-baseline.lint.ec" \
  "$POISON/.gibson-baseline.build.ec" 2>/dev/null || true
ln -sf "$VICTIM_OUT" "$POISON/.gibson-baseline.test.out"
# Hostile test also re-plants the symlink mid-run (in case gate rm's first)
cat >"$POISON/.agents/gate.json" <<JSON
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "ln -sfn '$VICTIM_OUT' .gibson-baseline.test.out; printf 'GIBSON_TEST_METRICS total=4 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/.gibson-baseline.json" 2>&1); rc=$?
victim_out_after=$(cat "$VICTIM_OUT" 2>/dev/null || echo MISSING)
if [[ "$victim_out_after" == "VICTIM_TEST_OUT_SENTINEL_DO_NOT_TRUNCATE" ]]; then
  ok "worktree test.out pre-poison: victim bytes unchanged"
else
  bad "worktree test.out pre-poison: victim truncated/changed: $victim_out_after"
fi
if [[ "$rc" -eq 0 ]] && grep -qE '"total":[[:space:]]*4' "$POISON/.gibson-baseline.json" 2>/dev/null; then
  ok "worktree test.out pre-poison: gate succeeds without writing through symlink"
elif [[ "$rc" -ne 0 ]]; then
  ok "worktree test.out pre-poison: gate fails closed (rc=$rc) without victim damage"
else
  bad "worktree test.out pre-poison: unexpected (rc=$rc): $out"
fi
# Predictable temps must not remain as regular files we created (symlink the
# hostile command planted may still exist — that is the attacker's file, not
# our leak). We must not leave our own .ec scratch files.
leaked=0
for f in .gibson-baseline.typecheck.ec .gibson-baseline.lint.ec \
         .gibson-baseline.test.ec .gibson-baseline.build.ec; do
  if [[ -f "$POISON/$f" && ! -L "$POISON/$f" ]]; then
    leaked=1
  fi
done
if [[ "$leaked" -eq 0 ]]; then
  ok "worktree pre-poison: no gate-owned .ec temp leaks"
else
  bad "worktree pre-poison: gate-owned .ec temps leaked"
fi
rm -f "$POISON/.gibson-baseline.test.out" 2>/dev/null || true

# --- .ec class: pre-poison exit-code path as symlink ------------------------
VICTIM_EC="$ROOT/victim-ec-bytes.bin"
printf 'VICTIM_EC_SENTINEL_DO_NOT_TRUNCATE\n' >"$VICTIM_EC"
ln -sf "$VICTIM_EC" "$POISON/.gibson-baseline.test.ec"
cat >"$POISON/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=5 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/.gibson-baseline.json" 2>&1); rc=$?
victim_ec_after=$(cat "$VICTIM_EC" 2>/dev/null || echo MISSING)
if [[ "$victim_ec_after" == "VICTIM_EC_SENTINEL_DO_NOT_TRUNCATE" ]]; then
  ok "worktree .ec pre-poison: victim bytes unchanged"
else
  bad "worktree .ec pre-poison: victim truncated/changed: $victim_ec_after"
fi
if [[ "$rc" -eq 0 ]] && grep -qE '"total":[[:space:]]*5' "$POISON/.gibson-baseline.json" 2>/dev/null; then
  ok "worktree .ec pre-poison: gate succeeds via in-memory exit codes"
elif [[ "$rc" -ne 0 ]]; then
  ok "worktree .ec pre-poison: gate fails closed without victim damage"
else
  bad "worktree .ec pre-poison: unexpected (rc=$rc): $out"
fi
rm -f "$POISON/.gibson-baseline.test.ec" 2>/dev/null || true

# --- OUT path as symlink: must fail closed, victim untouched ----------------
VICTIM_BASELINE="$ROOT/victim-baseline-bytes.bin"
printf 'VICTIM_BASELINE_SENTINEL_DO_NOT_TRUNCATE\n' >"$VICTIM_BASELINE"
rm -f "$POISON/out-link.json" 2>/dev/null || true
ln -sf "$VICTIM_BASELINE" "$POISON/out-link.json"
cat >"$POISON/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=6 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/out-link.json" 2>&1); rc=$?
victim_bl_after=$(cat "$VICTIM_BASELINE" 2>/dev/null || echo MISSING)
if [[ "$victim_bl_after" == "VICTIM_BASELINE_SENTINEL_DO_NOT_TRUNCATE" ]]; then
  ok "OUT symlink pre-poison: victim bytes unchanged"
else
  bad "OUT symlink pre-poison: victim truncated/changed: $victim_bl_after"
fi
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'symlink|refuse|fail closed'; then
  ok "OUT symlink pre-poison: gate fails closed"
else
  bad "OUT symlink pre-poison: expected fail closed (rc=$rc): $out"
fi

# --- JOURNAL path as symlink during regenerate ------------------------------
VICTIM_JOURNAL="$ROOT/victim-journal-bytes.bin"
printf 'VICTIM_JOURNAL_SENTINEL_DO_NOT_TRUNCATE\n' >"$VICTIM_JOURNAL"
# Establish a real baseline first
cat >"$POISON/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=8 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/.gibson-baseline.json") >/dev/null 2>&1 || true
mkdir -p "$POISON/.gibson"
rm -f "$POISON/.gibson/test-integrity-journal.jsonl" 2>/dev/null || true
ln -sf "$VICTIM_JOURNAL" "$POISON/.gibson/test-integrity-journal.jsonl"
# Shrink suite to force journal append
cat >"$POISON/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=2 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/.gibson-baseline.json" \
  --regenerate --reason 'intentional shrink for poison test' 2>&1); rc=$?
victim_j_after=$(cat "$VICTIM_JOURNAL" 2>/dev/null || echo MISSING)
if [[ "$victim_j_after" == "VICTIM_JOURNAL_SENTINEL_DO_NOT_TRUNCATE" ]]; then
  ok "JOURNAL symlink pre-poison: victim bytes unchanged"
else
  bad "JOURNAL symlink pre-poison: victim truncated/changed: $victim_j_after"
fi
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'symlink|refuse|fail closed|journal'; then
  ok "JOURNAL symlink pre-poison: gate fails closed"
else
  bad "JOURNAL symlink pre-poison: expected fail closed (rc=$rc): $out"
fi
rm -f "$POISON/.gibson/test-integrity-journal.jsonl" 2>/dev/null || true

# ---------------------------------------------------------------------------
echo "blocker scratch-lifecycle: no discoverable scratch before configured command"
# ---------------------------------------------------------------------------
# Configured command scans for gibson-baseline.* scratch dirs and plants a
# symlink at test.out → victim. Pre-command scratch creation allowed write-
# through + silent test_metrics:null. Must keep victim bytes and emit correct
# non-null metrics (or hard-fail). Never GREEN with null metrics after a test.
SCRATCH_LIFE="$ROOT/scratch-lifecycle"
mkdir -p "$SCRATCH_LIFE/.agents"
$GITP init -q "$SCRATCH_LIFE"
git -C "$SCRATCH_LIFE" symbolic-ref HEAD refs/heads/main
echo base >"$SCRATCH_LIFE/README"
$GITP -C "$SCRATCH_LIFE" add -A
$GITP -C "$SCRATCH_LIFE" commit -q -m "base"

VICTIM_SCRATCH="$ROOT/victim-scratch-lifecycle.bin"
printf 'VICTIM_SCRATCH_LIFECYCLE_SENTINEL\n' >"$VICTIM_SCRATCH"
# Hostile test: poison any discoverable pre-command scratch class.
cat >"$SCRATCH_LIFE/.agents/gate.json" <<EOF
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "for d in ${TMPDIR:-/tmp}/gibson-baseline.*; do if [ -d \"\$d\" ]; then ln -sfn '$VICTIM_SCRATCH' \"\$d/test.out\"; ln -sfn '$VICTIM_SCRATCH' \"\$d/test.out.XXXXXX\" 2>/dev/null || true; fi; done; printf 'GIBSON_TEST_METRICS total=11 skipped=0 todo=0\\\\n'",
  "build": ""
}
EOF
out=$(cd "$SCRATCH_LIFE" && bash "$BASELINE_SH" --out "$SCRATCH_LIFE/.gibson-baseline.json" 2>&1); rc=$?
victim_sl_after=$(cat "$VICTIM_SCRATCH" 2>/dev/null || echo MISSING)
if [[ "$victim_sl_after" == "VICTIM_SCRATCH_LIFECYCLE_SENTINEL" ]]; then
  ok "scratch-lifecycle pre-poison: victim bytes unchanged"
else
  bad "scratch-lifecycle pre-poison: victim truncated/changed: $victim_sl_after"
fi
if [[ "$rc" -eq 0 ]] \
  && grep -qE '"total":[[:space:]]*11' "$SCRATCH_LIFE/.gibson-baseline.json" 2>/dev/null \
  && ! grep -qE '"test_metrics":[[:space:]]*null' "$SCRATCH_LIFE/.gibson-baseline.json" 2>/dev/null; then
  ok "scratch-lifecycle pre-poison: correct non-null metrics (total=11), no write-through"
elif [[ "$rc" -ne 0 ]] && ! grep -qE '"test_metrics":[[:space:]]*null' "$SCRATCH_LIFE/.gibson-baseline.json" 2>/dev/null; then
  ok "scratch-lifecycle pre-poison: gate fails closed without null-metrics bypass (rc=$rc)"
else
  bad "scratch-lifecycle pre-poison: unexpected (rc=$rc metrics=$(grep test_metrics "$SCRATCH_LIFE/.gibson-baseline.json" 2>/dev/null || echo none)): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker baseline-authority: deletion/replacement/content drift during gate.sh"
# ---------------------------------------------------------------------------
# gate.sh must snapshot baseline before any configured command and compare
# against that snapshot only. Deletion, replacement, or byte change mid-run
# with a lower total must RED — never GREEN.
AUTH="$ROOT/baseline-auth"
mkdir -p "$AUTH/.agents"
$GITP init -q "$AUTH"
git -C "$AUTH" symbolic-ref HEAD refs/heads/main
echo base >"$AUTH/README"
$GITP -C "$AUTH" add -A
$GITP -C "$AUTH" commit -q -m "base"
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
(cd "$AUTH" && bash "$BASELINE_SH" --out "$AUTH/.gibson-baseline.json") >/dev/null 2>&1

# --- deletion during lower-total test ---
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "rm -f .gibson-baseline.json; printf 'GIBSON_TEST_METRICS total=3 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$AUTH" && bash "$GATE" --baseline "$AUTH/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'authority drift|disappeared|baseline' \
  && ! echo "$out" | grep -q 'GREEN'; then
  ok "baseline authority: deletion during lower-total test is RED (no GREEN)"
else
  bad "baseline deletion allowed GREEN or wrong error (rc=$rc): $out"
fi

# Restore baseline for next attack
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
(cd "$AUTH" && bash "$BASELINE_SH" --out "$AUTH/.gibson-baseline.json") >/dev/null 2>&1

# --- replacement with matching lower metrics (would self-authorize on re-read) ---
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "cat > .gibson-baseline.json <<'BL'\n{\"failures\":{\"typecheck\":0,\"lint\":0,\"test\":0,\"build\":0},\"exit_codes\":{\"typecheck\":0,\"lint\":0,\"test\":0,\"build\":0},\"test_metrics\":{\"total\":3,\"skipped\":0,\"todo\":0,\"skip_effective\":0,\"source\":\"hostile\"}}\nBL\nprintf 'GIBSON_TEST_METRICS total=3 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$AUTH" && bash "$GATE" --baseline "$AUTH/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'authority drift|content changed|replaced|leaf' \
  && ! echo "$out" | grep -q 'GREEN'; then
  ok "baseline authority: replacement during lower-total test is RED (no GREEN)"
else
  bad "baseline replacement allowed GREEN or wrong error (rc=$rc): $out"
fi

# Restore
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
(cd "$AUTH" && bash "$BASELINE_SH" --out "$AUTH/.gibson-baseline.json") >/dev/null 2>&1

# --- content byte change (append) during lower-total test ---
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'x' >> .gibson-baseline.json; printf 'GIBSON_TEST_METRICS total=3 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$AUTH" && bash "$GATE" --baseline "$AUTH/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'authority drift|content changed' \
  && ! echo "$out" | grep -q 'GREEN'; then
  ok "baseline authority: content change during lower-total test is RED (no GREEN)"
else
  bad "baseline content change allowed GREEN or wrong error (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker parent-stability: OUT/JOURNAL parent replace fails closed"
# ---------------------------------------------------------------------------
# A configured command that replaces a parent directory must not let the final
# atomic OUT write or JOURNAL append follow the new path. Victim bytes (if any)
# unchanged; nonzero exit; no partial output in the evil parent; no temp leaks.

PARENT_ATK="$ROOT/parent-attack"
mkdir -p "$PARENT_ATK/.agents" "$PARENT_ATK/out nest/sub"
$GITP init -q "$PARENT_ATK"
git -C "$PARENT_ATK" symbolic-ref HEAD refs/heads/main
echo base >"$PARENT_ATK/README"
$GITP -C "$PARENT_ATK" add -A
$GITP -C "$PARENT_ATK" commit -q -m "base"

# Establish a real OUT under a nested parent (path with spaces)
OUT_NEST="$PARENT_ATK/out nest/sub/base.json"
cat >"$PARENT_ATK/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=8 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
(cd "$PARENT_ATK" && bash "$BASELINE_SH" --out "$OUT_NEST") >/dev/null 2>&1
[[ -f "$OUT_NEST" ]] && ok "parent-stability setup: wrote baseline under path with spaces" \
  || bad "parent-stability setup failed to write $OUT_NEST"

# Replace immediate parent "out nest/sub" with symlink to evil during test
EVIL_OUT="$ROOT/evil-out-parent"
mkdir -p "$EVIL_OUT"
VICTIM_PARENT="$ROOT/victim-parent-out.bin"
printf 'VICTIM_PARENT_OUT_SENTINEL\n' >"$VICTIM_PARENT"
cat >"$PARENT_ATK/.agents/gate.json" <<EOF
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "rm -rf '$PARENT_ATK/out nest/sub'; mkdir -p '$EVIL_OUT'; ln -sfn '$EVIL_OUT' '$PARENT_ATK/out nest/sub'; printf 'GIBSON_TEST_METRICS total=8 skipped=0 todo=0\\\\n'",
  "build": ""
}
EOF
out=$(cd "$PARENT_ATK" && bash "$BASELINE_SH" --out "$OUT_NEST" 2>&1); rc=$?
evil_count=$(find "$EVIL_OUT" -type f 2>/dev/null | wc -l | tr -d ' ')
# No new baseline/temp files should land in the evil parent
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'parent|symlink|authority drift|refuse' \
  && [[ "$evil_count" -eq 0 ]]; then
  ok "OUT parent replace: fails closed, no partial write into evil parent"
else
  bad "OUT parent replace (rc=$rc evil_files=$evil_count): $out"
fi
# No temp leaks under evil or the (now symlink) nest path as gate-owned regulars
leaked_parent=0
if find "$EVIL_OUT" -name '.base.json.*' 2>/dev/null | grep -q .; then
  leaked_parent=1
fi
if [[ "$leaked_parent" -eq 0 ]]; then
  ok "OUT parent replace: no temp leaks in evil parent"
else
  bad "OUT parent replace: temp leaks in evil parent"
fi

# --- JOURNAL parent replace during regenerate ---
# Fresh repo so prior OUT state is clean
JATK="$ROOT/journal-parent-attack"
mkdir -p "$JATK/.agents" "$JATK/.gibson"
$GITP init -q "$JATK"
git -C "$JATK" symbolic-ref HEAD refs/heads/main
echo base >"$JATK/README"
$GITP -C "$JATK" add -A
$GITP -C "$JATK" commit -q -m "base"
cat >"$JATK/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=8 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
(cd "$JATK" && bash "$BASELINE_SH" --out "$JATK/.gibson-baseline.json") >/dev/null 2>&1
EVIL_J="$ROOT/evil-journal-parent"
mkdir -p "$EVIL_J"
VICTIM_JPARENT="$ROOT/victim-journal-parent.bin"
printf 'VICTIM_JOURNAL_PARENT_SENTINEL\n' >"$VICTIM_JPARENT"
# Shrink + replace .gibson parent with symlink to evil during the test step
cat >"$JATK/.agents/gate.json" <<EOF
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "rm -rf '$JATK/.gibson'; mkdir -p '$EVIL_J'; ln -sfn '$EVIL_J' '$JATK/.gibson'; printf 'GIBSON_TEST_METRICS total=2 skipped=0 todo=0\\\\n'",
  "build": ""
}
EOF
out=$(cd "$JATK" && bash "$BASELINE_SH" --out "$JATK/.gibson-baseline.json" \
  --regenerate --reason 'intentional shrink parent-attack' \
  --journal "$JATK/.gibson/test-integrity-journal.jsonl" 2>&1); rc=$?
evil_j_count=$(find "$EVIL_J" -type f 2>/dev/null | wc -l | tr -d ' ')
victim_jp_after=$(cat "$VICTIM_JPARENT" 2>/dev/null || echo MISSING)
if [[ "$victim_jp_after" == "VICTIM_JOURNAL_PARENT_SENTINEL" ]]; then
  ok "JOURNAL parent replace: victim bytes unchanged"
else
  bad "JOURNAL parent replace: victim changed: $victim_jp_after"
fi
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'parent|symlink|authority drift|refuse|journal' \
  && [[ "$evil_j_count" -eq 0 ]] \
  && ! echo "$out" | grep -q 'GREEN'; then
  ok "JOURNAL parent replace: fails closed, no journal partial in evil parent"
else
  bad "JOURNAL parent replace (rc=$rc evil_files=$evil_j_count): $out"
fi

# Phase-1 bootstrap pin: ci/gibson-gate.yml must NOT wire test-integrity yet.
# Wiring CI before main owns the helper self-grades (workspace-bootstrap) or
# races a fixed RUNNER_TEMP path. Phase 2 adds the isolated job after merge.
CI_YML="$SCRIPT_DIR/../../ci/gibson-gate.yml"
if [[ -f "$CI_YML" ]] \
  && ! grep -q 'TI_TRUSTED\|test-integrity\.trusted\|test-integrity\.mjs\|GIBSON_TEST_METRICS\|workspace-bootstrap' "$CI_YML"; then
  ok "ci/gibson-gate.yml unwired for test-integrity (phase-1 bootstrap; phase-2 after helper on main)"
else
  bad "ci/gibson-gate.yml has premature test-integrity CI wiring (phase-1 must leave template unchanged)"
fi

# Phase-1 also must not claim a fixed-path trusted binary in the CI template
if [[ -f "$CI_YML" ]] \
  && ! grep -qE 'RUNNER_TEMP.*test-integrity|test-integrity\.trusted' "$CI_YML"; then
  ok "ci/gibson-gate.yml has no fixed-path test-integrity symlink target"
else
  bad "ci/gibson-gate.yml still references fixed-path trusted helper (symlink race class)"
fi

# ---------------------------------------------------------------------------
echo
echo "gate.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
