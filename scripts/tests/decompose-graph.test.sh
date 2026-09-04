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

# Compact scenario fake for the direct CLI matrix (exhaustive loader is lint).
install_graph_gh() {
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/gh" <<'GH'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const logPath = process.env.GIBSON_GH_LOG;
const scenarioPath = process.env.GIBSON_GH_SCENARIO;
const argv = process.argv.slice(2);
fs.appendFileSync(logPath, JSON.stringify(argv) + "\n");
const statePath = logPath + ".state.json";
let state = { obs: {} };
try { state = Object.assign({ obs: {} }, JSON.parse(fs.readFileSync(statePath, "utf8"))); } catch {}
function parseFields(args) {
  const out = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "-f" || args[i] === "-F") {
      const raw = args[++i] || "";
      const eq = raw.indexOf("=");
      if (eq >= 0) out[raw.slice(0, eq)] = raw.slice(eq + 1);
    }
  }
  return out;
}
const fields = parseFields(argv.slice(2));
const sc = JSON.parse(fs.readFileSync(scenarioPath, "utf8"));
if (sc.failApi) {
  process.stderr.write(sc.rawStderr || "simulated gh failure\n");
  process.exit(typeof sc.rawStatus === "number" ? sc.rawStatus : 1);
}
if (sc.invalidShape) {
  fs.writeFileSync(statePath, JSON.stringify(state));
  process.stdout.write(JSON.stringify({ data: {} }));
  process.exit(0);
}
const query = fields.query || "";
const isLoad = query.includes("title") && query.includes("body");
const key = query.includes("$label") ? String(fields.label || "") : "all-open";
const q = sc.queries && sc.queries[key];
if (!q || !Array.isArray(q.pages)) {
  process.stderr.write("fake gh: no fixture for " + key + "\n");
  process.exit(64);
}
if (!isLoad) state.obs[key] = (state.obs[key] || 0) + 1;
fs.writeFileSync(statePath, JSON.stringify(state));
const after = fields.after;
let page = (!after || after === "null") ? q.pages[0] : null;
if (!page) {
  for (let i = 0; i < q.pages.length; i++) {
    if (q.pages[i].endCursor === after) { page = q.pages[i + 1] || null; break; }
  }
}
if (!page) { process.stderr.write("fake gh: unknown cursor\n"); process.exit(1); }
const afterPhase = !isLoad && (state.obs[key] || 0) > q.pages.length;
const sha = afterPhase && sc.shaAfter ? sc.shaAfter : sc.sha;
const nodes = (page.nodes || []).map((n) => {
  if (!isLoad) return { number: n.number, updatedAt: n.updatedAt };
  const names = Array.isArray(n.labels) ? n.labels : [];
  return { number: n.number, updatedAt: n.updatedAt, title: n.title, body: n.body,
    labels: { totalCount: names.length, pageInfo: { hasNextPage: false, endCursor: names.length ? "le" : null },
      nodes: names.map((name) => ({ name })) } };
});
process.stdout.write(JSON.stringify({ data: { repository: {
  defaultBranchRef: { target: { oid: sha } },
  issues: { totalCount: page.totalCount, pageInfo: { hasNextPage: Boolean(page.hasNextPage),
    endCursor: Object.prototype.hasOwnProperty.call(page, "endCursor") ? page.endCursor : null }, nodes }
} } }));
GH
  chmod +x "$ROOT/bin/gh"
}

reset_gh() { rm -f "$ROOT/gh-calls.log" "$ROOT/gh-calls.log.state.json"; }
count_gh() {
  [[ -f "$ROOT/gh-calls.log" ]] && wc -l < "$ROOT/gh-calls.log" | tr -d '[:space:]' || printf '%s' 0
}
run_repo() {
  reset_gh
  GIBSON_GH_LOG="$ROOT/gh-calls.log" GIBSON_GH_SCENARIO="$ROOT/scenario.json" \
  PATH="$ROOT/bin:$PATH" node "$SENSOR" "$@" 2>&1
}
lacks_queue() {
  local name="$1" out="$2"
  if printf '%s\n' "$out" | node -e '
let s=""; process.stdin.setEncoding("utf8");
process.stdin.on("data",(c)=>{s+=c;});
process.stdin.on("end",()=>{
  const stripped=s.replace(/\b(?:digest|sha)=[0-9a-f]+\b/gi,"");
  const re=/(?<![A-Za-z0-9_-])(OK|DAG|critical-path|critical path|capacity|blocker-first)(?![A-Za-z0-9_-])/i;
  process.exit(re.test(stripped)?1:0);
});
'; then ok "$name: no queue conclusion"; else bad "$name: leaked queue conclusion: $out"; fi
}
expect_calls() {
  local name="$1" want="$2" got
  got=$(count_gh)
  [[ "$got" == "$want" ]] && ok "$name: gh calls=$got" || bad "$name: gh calls want $want got $got"
}

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
ISSUE_BODY='## Sprint contract\n- [ ] a\n- [ ] b\n## Affected area\napp\n## Dependencies\nnone\n## Tier\nA\n'

# --- help / usage ---
out=$(node "$SENSOR" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'WHAT IT DOES' >/dev/null && ok "help exits 0 with WHAT/WHY" \
  || bad "help (rc=$rc): $out"
if printf '%s\n' "$out" | grep -F -- '--allow-empty' | grep 'INTENTIONAL_EMPTY' >/dev/null; then
  ok "help discloses --allow-empty INTENTIONAL_EMPTY exit 0"
else
  bad "help missing --allow-empty INTENTIONAL_EMPTY: $out"
fi
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
[[ "$rc" -ne 0 ]] && echo "$out" | grep -i cycle >/dev/null && ok "cycle exits non-zero and names cycle" \
  || bad "cycle (rc=$rc): $out"
echo "$out" | grep -E '#1 → #2 → #1|#2 → #1 → #2' >/dev/null && ok "cycle prints closed path" \
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
[[ "$rc" -ne 0 ]] && echo "$out" | grep -i cycle >/dev/null && ok "3-cycle fails" || bad "3-cycle (rc=$rc): $out"

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
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null && ok "valid DAG exits 0" || bad "DAG (rc=$rc): $out"
echo "$out" | grep 'topological order:' >/dev/null && ok "prints topological order" || bad "no topo: $out"
# topo must have 1 before 2 before 3
order=$(echo "$out" | sed -n 's/.*topological order: //p' | head -1)
echo "$order" | grep '#1' >/dev/null && echo "$order" | grep '#2' >/dev/null && echo "$order" | grep '#3' >/dev/null \
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
echo "$crit" | grep '#1' >/dev/null && echo "$crit" | grep '#2' >/dev/null && echo "$crit" | grep '#3' >/dev/null \
  && ok "critical path includes 1→2→3 chain" || bad "critical path: $crit"
# side branch 4 should not extend past 3
echo "$out" | grep -E 'critical path \(3 issues?\)' >/dev/null && ok "critical path length 3" \
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
[[ "$rc" -eq 0 ]] && echo "$out" | grep '#31' >/dev/null && ok "bare #N dependency edge" \
  || bad "bare (rc=$rc): $out"

# --- missing file ---
out=$(node "$SENSOR" --file "$ROOT/nope.json" 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && ok "missing file exits 2" || bad "missing file (rc=$rc): $out"

# #257 compact direct integration (exhaustive loader matrix is lint)
install_graph_gh
n1='{"number":101,"updatedAt":"2026-01-01T00:00:00Z","title":"One","body":"'"$ISSUE_BODY"'","labels":["tier-a"]}'
n2='{"number":102,"updatedAt":"2026-01-02T00:00:00Z","title":"Two","body":"'"$ISSUE_BODY"'","labels":["tier-a"]}'
n3='{"number":103,"updatedAt":"2026-01-03T00:00:00Z","title":"Three","body":"'"$ISSUE_BODY"'","labels":["tier-a"]}'
a10='{"number":10,"updatedAt":"2026-01-01T00:00:00Z","title":"Ten","body":"'"$ISSUE_BODY"'","labels":["alpha"]}'
a11='{"number":11,"updatedAt":"2026-01-02T00:00:00Z","title":"Eleven","body":"'"$ISSUE_BODY"'","labels":["alpha","beta"]}'
b12='{"number":12,"updatedAt":"2026-01-03T00:00:00Z","title":"Twelve","body":"'"$ISSUE_BODY"'","labels":["beta"]}'
n7='{"number":7,"updatedAt":"2026-01-01T00:00:00Z","title":"Seven","body":"'"$ISSUE_BODY"'","labels":["tier-a"]}'

out=$(run_repo --repo acme/app); rc=$?
[[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep 'missing repository selector' >/dev/null \
  && ok "missing selector: exit 2 names missing selector" || bad "missing selector (rc=$rc): $out"
expect_calls "missing selector" 0
out=$(run_repo --repo acme/app --allow-empty); rc=$?
[[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep 'missing repository selector' >/dev/null \
  && ! printf '%s\n' "$out" | grep 'unknown flag' >/dev/null \
  && ok "missing selector: --allow-empty is a modifier, not a selector" \
  || bad "missing selector allow-empty (rc=$rc): $out"
expect_calls "missing selector allow-empty" 0

out=$(run_repo --repo acme/app --label --all-open); rc=$?
[[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep 'combined selectors' >/dev/null \
  && ! printf '%s\n' "$out" | grep 'unknown flag' >/dev/null \
  && ok "label swallows --all-open: exit 2 before gh" \
  || bad "label swallows --all-open (rc=$rc): $out"
expect_calls "label swallows --all-open" 0

cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","queries":{"all-open":{"pages":[{"totalCount":0,"hasNextPage":false,"endCursor":null,"nodes":[]}]}}}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
[[ "$rc" -eq 1 ]] && printf '%s\n' "$out" | grep 'EMPTY_SELECTION: all-open' >/dev/null \
  && ok "empty selection: EMPTY_SELECTION exit 1 names all-open" || bad "empty selection (rc=$rc): $out"
lacks_queue "empty selection" "$out"
expect_calls "empty selection" 3
out=$(run_repo --repo acme/app --all-open --allow-empty); rc=$?
[[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep 'INTENTIONAL_EMPTY: all-open' >/dev/null \
  && ok "allowed empty: INTENTIONAL_EMPTY exit 0" || bad "allowed empty (rc=$rc): $out"
lacks_queue "allowed empty" "$out"
expect_calls "allowed empty" 3

cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","queries":{"all-open":{"pages":[
  {"totalCount":3,"hasNextPage":true,"endCursor":"c1","nodes":[$n1]},
  {"totalCount":3,"hasNextPage":true,"endCursor":"c2","nodes":[$n2]},
  {"totalCount":3,"hasNextPage":false,"endCursor":null,"nodes":[$n3]}
]}}}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
[[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep 'OK (3 issues, DAG)' >/dev/null \
  && printf '%s\n' "$out" | grep 'loaded=3' >/dev/null && printf '%s\n' "$out" | grep 'totalCount=3' >/dev/null \
  && printf '%s\n' "$out" | grep '#101' >/dev/null && printf '%s\n' "$out" | grep '#103' >/dev/null \
  && printf '%s\n' "$out" | grep 'critical path' >/dev/null \
  && ok "three-page --all-open: OK 3-issue DAG including page-3 #103" \
  || bad "three-page --all-open (rc=$rc): $out"
expect_calls "three-page --all-open" 9

cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","queries":{
  "alpha":{"pages":[{"totalCount":2,"hasNextPage":false,"endCursor":null,"nodes":[$a10,$a11]}]},
  "beta":{"pages":[{"totalCount":2,"hasNextPage":false,"endCursor":null,"nodes":[$a11,$b12]}]}
}}
JSON
out=$(run_repo --repo acme/app --label alpha --label beta); rc=$?
[[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep 'OK (3 issues, DAG)' >/dev/null \
  && printf '%s\n' "$out" | grep 'loaded=3' >/dev/null && printf '%s\n' "$out" | grep 'unionTotal=3' >/dev/null \
  && printf '%s\n' "$out" | grep 'sourceTotals=2,2' >/dev/null && ! printf '%s\n' "$out" | grep 'totalCount=' >/dev/null \
  && printf '%s\n' "$out" | grep '#10' >/dev/null && printf '%s\n' "$out" | grep '#12' >/dev/null \
  && ok "repeated-label overlapping union: OR-union of 3 issues (not last-label-wins)" \
  || bad "repeated-label overlapping union (rc=$rc): $out"
expect_calls "repeated-label overlapping union" 6
out=$(run_repo --repo acme/app --label beta); rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep 'OK (3 issues, DAG)' >/dev/null \
   && printf '%s\n' "$out" | grep 'loaded=3' >/dev/null && printf '%s\n' "$out" | grep 'unionTotal=3' >/dev/null; then
  bad "last-label-wins: overlapping-union assertion still green"
else
  ok "last-label-wins: overlapping-union assertion red"
fi

HOSTILE_STDERR='OK DAG critical-path capacity blocker-first'
cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","failApi":true,"rawStderr":"$HOSTILE_STDERR","queries":{"all-open":{"pages":[]}}}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
[[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep 'INCOMPLETE: API_FAILURE' >/dev/null \
  && ! printf '%s\n' "$out" | grep -F -q "$HOSTILE_STDERR" \
  && ok "API failure: INCOMPLETE exit 3 with typed code, no raw stderr" \
  || bad "API failure (rc=$rc): $out"
lacks_queue "API failure" "$out"
expect_calls "API failure" 1

out=$(run_repo --repo acme/app --label $'OK\nDAG'); rc=$?
[[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep 'control character' >/dev/null \
  && ok "embedded newline label: usage exit 2 before gh" \
  || bad "embedded newline label (rc=$rc): $out"
lacks_queue "embedded newline label" "$out"
expect_calls "embedded newline label" 0

cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","invalidShape":true,"queries":{}}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
[[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep 'INCOMPLETE' >/dev/null \
  && ok "strict-shape: invalid shape exits 3 INCOMPLETE" || bad "strict-shape (rc=$rc): $out"
lacks_queue "strict-shape" "$out"
expect_calls "strict-shape" 1

cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","shaAfter":"$SHA_B","queries":{"all-open":{"pages":[{"totalCount":1,"hasNextPage":false,"endCursor":null,"nodes":[$n7]}]}}}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
[[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep 'INCOMPLETE: STALE_OBSERVATION' >/dev/null \
  && ok "default-branch drift: INCOMPLETE: STALE_OBSERVATION exit 3" \
  || bad "default-branch drift (rc=$rc): $out"
lacks_queue "default-branch drift" "$out"
expect_calls "default-branch drift" 3

out=$(run_repo --file "$ROOT/dag.json"); rc=$?
[[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep 'OK' >/dev/null && printf '%s\n' "$out" | grep 'DAG' >/dev/null \
  && ok "preserved --file: DAG fixture still OK" || bad "preserved --file (rc=$rc): $out"
expect_calls "preserved --file" 0

echo
echo "decompose-graph.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
