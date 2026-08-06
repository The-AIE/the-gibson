#!/usr/bin/env bash
# laws-sensors.test.sh — Law 1 / 6 / 8 deterministic sensors (#97)
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
L1="$SCRIPT_DIR/../contract-read-check.mjs"
L6="$SCRIPT_DIR/../contract-met.mjs"
L8="$SCRIPT_DIR/../truthful-status.mjs"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "laws-sensors.test.sh: node required"; exit 1; }
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-laws.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

echo "# Law 1 — contract-read-check"
out=$(node "$L1" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'Law 1' && ok "L1 help" || bad "L1 help"

cat > "$ROOT/good.receipt" <<'R'
agents=AGENTS.md
lessons=memory/LESSONS.md
read_at=2026-08-06T12:00:00Z
session=tester@box
R
out=$(node "$L1" --receipt "$ROOT/good.receipt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "L1 good receipt" || bad "L1 good (rc=$rc): $out"

cat > "$ROOT/bad.receipt" <<'R'
agents=AGENTS.md
read_at=2026-08-06T12:00:00Z
R
out=$(node "$L1" --receipt "$ROOT/bad.receipt" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "L1 missing lessons refuses" || bad "L1 bad receipt passed"

cat > "$ROOT/body-good.md" <<'B'
## Contracts read
- Read: AGENTS.md
- Read: memory/LESSONS.md
B
out=$(node "$L1" --body-file "$ROOT/body-good.md" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "L1 body attestation" || bad "L1 body good (rc=$rc): $out"

cat > "$ROOT/body-bad.md" <<'B'
## Summary
Shipped the feature. No doctrine mentioned.
B
out=$(node "$L1" --body-file "$ROOT/body-bad.md" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "L1 body without contracts refuses" || bad "L1 body bad passed"

echo "# Law 6 — contract-met"
out=$(node "$L6" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'Law 6' && ok "L6 help" || bad "L6 help"

cat > "$ROOT/issue.json" <<'J'
{
  "number": 42,
  "title": "Add login",
  "body": "## Sprint contract (acceptance criteria)\n- [x] AC1 — unit tests pass\n- [ ] AC2 — e2e covers login\n- [ ] AC3 — docs updated\n## Affected area\napp/auth\n## Dependencies\nnone\n## Tier\nA\n"
}
J
cat > "$ROOT/pr-bad.md" <<'P'
## Summary
Closes #42

All done.
P
out=$(node "$L6" --issue-file "$ROOT/issue.json" --pr-body-file "$ROOT/pr-bad.md" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'AC2' && ok "L6 open criteria refuse close" \
  || bad "L6 bad close (rc=$rc): $out"

cat > "$ROOT/pr-good.md" <<'P'
## Summary
Closes #42

## Contract met
- [x] AC2 — e2e covers login (added tests/e2e/login.spec.ts)
- [x] AC3 — docs updated (README auth section)

Verified: AC2 — e2e covers login
Verified: AC3 — docs updated
P
out=$(node "$L6" --issue-file "$ROOT/issue.json" --pr-body-file "$ROOT/pr-good.md" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "L6 evidenced open criteria pass" || bad "L6 good (rc=$rc): $out"

cat > "$ROOT/pr-noclose.md" <<'P'
## Summary
Work in progress toward #42 — does not fully resolve #42
P
out=$(node "$L6" --issue-file "$ROOT/issue.json" --pr-body-file "$ROOT/pr-noclose.md" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -qi 'N/A\|no close' && ok "L6 no close keyword is N/A" \
  || bad "L6 noclose (rc=$rc): $out"

cat > "$ROOT/issue-all-checked.json" <<'J'
{
  "number": 7,
  "title": "Done",
  "body": "## Sprint contract\n- [x] AC1 — shipped\n- [x] AC2 — tested\n"
}
J
cat > "$ROOT/pr-checked.md" <<'P'
Fixes #7
P
out=$(node "$L6" --issue-file "$ROOT/issue-all-checked.json" --pr-body-file "$ROOT/pr-checked.md" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "L6 all-checked issue allows close" || bad "L6 checked (rc=$rc): $out"

echo "# Law 8 — truthful-status"
out=$(node "$L8" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'Law 8' && ok "L8 help" || bad "L8 help"

out=$(node "$L8" --claimed success --gate-exit 0 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "L8 success + exit 0" || bad "L8 green (rc=$rc): $out"

out=$(node "$L8" --claimed success --gate-exit 1 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "L8 success + exit 1 refuses" || bad "L8 red exit passed"

cat > "$ROOT/notrun.log" <<'L'
goose-recipes.test.sh
status: NOT RUN
197 passed, 0 failed
L
out=$(node "$L8" --claimed success --log-file "$ROOT/notrun.log" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'NOT RUN' && ok "L8 NOT RUN under success refuses" \
  || bad "L8 notrun (rc=$rc): $out"

cat > "$ROOT/failed.log" <<'L'
suite: 10 passed, 3 failed
run-all: RED
L
out=$(node "$L8" --claimed green --log-file "$ROOT/failed.log" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "L8 failed tally refuses green claim" || bad "L8 failed (rc=$rc): $out"

out=$(node "$L8" --claimed blocked --gate-exit 1 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "L8 non-success claim not contradicted" || bad "L8 blocked claim (rc=$rc): $out"

echo
echo "laws-sensors.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
