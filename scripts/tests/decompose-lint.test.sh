#!/usr/bin/env bash
# decompose-lint.test.sh — smoke sensors for issue-set contract lint (#192)
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SENSOR="$SCRIPT_DIR/../decompose-lint.mjs"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "decompose-lint.test.sh: node required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-decompose-lint.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

run() {
  local file="$1"
  node "$SENSOR" --file "$file" 2>&1
}

# --- help / usage ---
out=$(node "$SENSOR" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'WHAT IT DOES' && ok "help exits 0 with WHAT/WHY" \
  || bad "help (rc=$rc): $out"
out=$(node "$SENSOR" 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && ok "no-args exits 2" || bad "no-args want 2 got $rc"

# --- unknown flag ---
out=$(node "$SENSOR" --definitely-not-a-flag 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -q 'unknown flag: --definitely-not-a-flag' \
  && ok "unknown flag exits 2" \
  || bad "unknown flag (rc=$rc): $out"

# --- missing value ---
out=$(node "$SENSOR" --file 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -q 'requires a value' \
  && ok "--file without value exits 2" \
  || bad "--file missing (rc=$rc): $out"

# --- clean issue set ---
cat > "$ROOT/clean.json" <<'JSON'
[
  {
    "number": 1,
    "title": "Add login",
    "body": "## Sprint contract\n- [ ] unit tests pass\n- [ ] e2e covers login\n## Affected area\napp/auth\n## Dependencies\nnone\n## Tier\nA\n",
    "labels": ["tier-a"]
  }
]
JSON
out=$(run "$ROOT/clean.json"); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'OK' && ok "clean issue exits 0" \
  || bad "clean (rc=$rc): $out"

# --- missing sprint contract ---
cat > "$ROOT/nocontract.json" <<'JSON'
[
  {
    "number": 2,
    "title": "Thing",
    "body": "## Affected area\nx\n## Dependencies\nnone\n## Tier\nB\n",
    "labels": ["tier-b"]
  }
]
JSON
out=$(run "$ROOT/nocontract.json"); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'sprint contract\|contract' \
  && ok "missing contract fails" \
  || bad "nocontract (rc=$rc): $out"

# --- missing affected area ---
cat > "$ROOT/noarea.json" <<'JSON'
[
  {
    "number": 3,
    "title": "Thing",
    "body": "## Sprint contract\n- [ ] a\n## Dependencies\nnone\n## Tier\nA\n",
    "labels": []
  }
]
JSON
out=$(run "$ROOT/noarea.json"); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'Affected area' \
  && ok "missing affected area fails" \
  || bad "noarea (rc=$rc): $out"

# --- too many criteria (>10) ---
{
  echo '['
  echo '  {"number":4,"title":"Big","body":"## Sprint contract\n'
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    echo "- [ ] criterion $i"
  done
  echo '## Affected area\nx\n## Dependencies\nnone\n## Tier\nA\n","labels":[]}'
  echo ']'
} > "$ROOT/toobig.json"
out=$(run "$ROOT/toobig.json"); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qE '>10|11' \
  && ok ">10 criteria fails" \
  || bad "toobig (rc=$rc): $out"

# --- missing file ---
out=$(node "$SENSOR" --file "$ROOT/nope.json" 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && ok "missing file exits 2" || bad "missing file (rc=$rc): $out"

echo
echo "decompose-lint.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
