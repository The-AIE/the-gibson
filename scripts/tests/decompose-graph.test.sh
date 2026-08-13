#!/usr/bin/env bash
# decompose-graph.test.sh — sensors for dependency DAG check (#104)
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SENSOR="$SCRIPT_DIR/../decompose-graph.mjs"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "decompose-graph.test.sh: node required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-decompose-graph.XXXXXX")
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

# --- cycle fails ---
cat > "$ROOT/cycle.json" <<'JSON'
[
  {
    "number": 1,
    "title": "A",
    "body": "## Sprint contract\n- [ ] a\n## Affected area\nx\n## Dependencies\nBlocked by #2\n## Tier\nA",
    "labels": ["tier-a"]
  },
  {
    "number": 2,
    "title": "B",
    "body": "## Sprint contract\n- [ ] b\n## Affected area\nx\n## Dependencies\nBlocked by #1\n## Tier\nA",
    "labels": ["tier-a"]
  }
]
JSON
out=$(run "$ROOT/cycle.json"); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi cycle && ok "cycle exits non-zero and names cycle" \
  || bad "cycle (rc=$rc): $out"
echo "$out" | grep -qE '#1 → #2 → #1|#2 → #1 → #2' && ok "cycle prints closed path" \
  || bad "cycle path format: $out"

# --- three-node cycle ---
cat > "$ROOT/cycle3.json" <<'JSON'
[
  {"number":10,"title":"A","body":"## Dependencies\nBlocked by #11\n","labels":[]},
  {"number":11,"title":"B","body":"## Dependencies\nBlocked by #12\n","labels":[]},
  {"number":12,"title":"C","body":"## Dependencies\nBlocked by #10\n","labels":[]}
]
JSON
out=$(run "$ROOT/cycle3.json"); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi cycle && ok "3-cycle fails" || bad "3-cycle (rc=$rc): $out"

# --- valid DAG: topo + critical path ---
# 1 blocked by none; 2 blocked by 1; 3 blocked by 2; 4 blocked by 1
# critical path: 1 → 2 → 3 (length 3)
cat > "$ROOT/dag.json" <<'JSON'
[
  {"number":1,"title":"root","body":"## Dependencies\nnone\n","labels":[]},
  {"number":2,"title":"mid","body":"## Dependencies\nBlocked by #1\n","labels":[]},
  {"number":3,"title":"leaf","body":"## Dependencies\nBlocked by #2\n","labels":[]},
  {"number":4,"title":"side","body":"## Dependencies\nBlocked by #1\n","labels":[]}
]
JSON
out=$(run "$ROOT/dag.json"); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'OK' && ok "valid DAG exits 0" || bad "DAG (rc=$rc): $out"
echo "$out" | grep -q 'topological order:' && ok "prints topological order" || bad "no topo: $out"
# topo must have 1 before 2 before 3
order=$(echo "$out" | sed -n 's/.*topological order: //p' | head -1)
echo "$order" | grep -q '#1' && echo "$order" | grep -q '#2' && echo "$order" | grep -q '#3' \
  && ok "topo names all nodes" || bad "topo incomplete: $order"
# positions: #1 before #2 before #3
python3 - <<PY
import re,sys
order="""$order"""
nums=[int(x) for x in re.findall(r'#(\d+)', order)]
try:
  assert nums.index(1) < nums.index(2) < nums.index(3)
  print("ok-order")
except Exception as e:
  print("bad-order", nums, e)
  sys.exit(1)
PY
[[ $? -eq 0 ]] && ok "topo respects 1 before 2 before 3" || bad "topo order wrong: $order"

crit=$(echo "$out" | sed -n 's/.*critical path[^:]*: //p' | head -1)
echo "$crit" | grep -q '#1' && echo "$crit" | grep -q '#2' && echo "$crit" | grep -q '#3' \
  && ok "critical path includes 1→2→3 chain" || bad "critical path: $crit"
# side branch 4 should not extend past 3
echo "$out" | grep -qE 'critical path \(3 issues?\)' && ok "critical path length 3" \
  || bad "critical path length: $out"

# --- missing / empty / none deps tolerated ---
cat > "$ROOT/emptydeps.json" <<'JSON'
[
  {"number":5,"title":"solo","body":"## Sprint contract\n- [ ] x\n## Affected area\ny\n## Tier\nA\n","labels":[]},
  {"number":6,"title":"none","body":"## Dependencies\nnone\n","labels":[]}
]
JSON
out=$(run "$ROOT/emptydeps.json"); rc=$?
[[ "$rc" -eq 0 ]] && ok "missing/empty deps tolerated (DAG)" || bad "empty deps (rc=$rc): $out"

# --- external blocker not in set does not invent cycle ---
cat > "$ROOT/external.json" <<'JSON'
[
  {"number":20,"title":"only","body":"## Dependencies\nBlocked by #999\n","labels":[]}
]
JSON
out=$(run "$ROOT/external.json"); rc=$?
[[ "$rc" -eq 0 ]] && ok "external blocker ignored for set DAG" || bad "external (rc=$rc): $out"

# --- bare #N under Dependencies ---
cat > "$ROOT/bare.json" <<'JSON'
[
  {"number":30,"title":"a","body":"## Dependencies\n- #31\n","labels":[]},
  {"number":31,"title":"b","body":"## Dependencies\nnone\n","labels":[]}
]
JSON
out=$(run "$ROOT/bare.json"); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '#31' && ok "bare #N dependency edge" \
  || bad "bare (rc=$rc): $out"

# --- missing file ---
out=$(node "$SENSOR" --file "$ROOT/nope.json" 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && ok "missing file exits 2" || bad "missing file (rc=$rc): $out"

echo
echo "decompose-graph.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
