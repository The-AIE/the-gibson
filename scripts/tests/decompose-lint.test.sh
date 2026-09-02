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

# --- #257 live repository loader (fake gh; exact call counts) ---------------
install_loader_gh() {
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/gh" <<'GH'
#!/usr/bin/env node
"use strict";
const fs = require("fs");

const logPath = process.env.GIBSON_GH_LOG;
const scenarioPath = process.env.GIBSON_GH_SCENARIO;
if (!logPath || !scenarioPath) {
  process.stderr.write("fake gh: missing GIBSON_GH_LOG or GIBSON_GH_SCENARIO\n");
  process.exit(64);
}

const argv = process.argv.slice(2);
fs.appendFileSync(logPath, JSON.stringify(argv) + "\n");

const statePath = logPath + ".state.json";
function readState() {
  try {
    return JSON.parse(fs.readFileSync(statePath, "utf8"));
  } catch {
    return { observeCalls: {}, loadCalls: {}, totalCalls: 0 };
  }
}
function writeState(s) {
  fs.writeFileSync(statePath, JSON.stringify(s));
}

const state = readState();
state.totalCalls = (state.totalCalls || 0) + 1;
if (state.totalCalls > 150) {
  process.stderr.write("fake gh: call cap (implementation failed to stop)\n");
  writeState(state);
  process.exit(1);
}

if (argv[0] !== "api" || argv[1] !== "graphql") {
  process.stderr.write("fake gh: unmodelled: gh " + argv.join(" ") + "\n");
  writeState(state);
  process.exit(64);
}

function parseFields(args) {
  const out = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "-f" || args[i] === "-F") {
      const raw = args[i + 1] || "";
      i += 1;
      const eq = raw.indexOf("=");
      if (eq < 0) continue;
      out[raw.slice(0, eq)] = raw.slice(eq + 1);
    }
  }
  return out;
}

const fields = parseFields(argv.slice(2));
const query = fields.query || "";
const compact = query.replace(/\s+/g, "");
const modelled =
  compact.includes("states:[OPEN]") &&
  compact.includes("$owner:String!") &&
  compact.includes("$name:String!") &&
  compact.includes("defaultBranchRef{target{oid}}") &&
  compact.includes("issues(first:100") &&
  /issues\([^)]*\)\{totalCount/.test(compact) &&
  compact.includes("pageInfo{hasNextPageendCursor}") &&
  Boolean(fields.owner) &&
  Boolean(fields.name);
const isLoadQuery = compact.includes("title") && compact.includes("body");
const loadOk =
  !isLoadQuery ||
  (compact.includes(
    "labels(first:100){totalCountpageInfo{hasNextPageendCursor}nodes{name}}"
  ) &&
    compact.includes("nodes{numbertitlebodyupdatedAtlabels(first:100)"));
const observeOk = isLoadQuery || compact.includes("nodes{numberupdatedAt}");
if (!modelled || !loadOk || !observeOk) {
  process.stderr.write("fake gh: unmodelled GraphQL query shape\n");
  writeState(state);
  process.exit(64);
}

let scenario;
try {
  scenario = JSON.parse(fs.readFileSync(scenarioPath, "utf8"));
} catch (e) {
  process.stderr.write("fake gh: bad scenario: " + e.message + "\n");
  writeState(state);
  process.exit(64);
}

if (scenario.failApi) {
  writeState(state);
  process.stderr.write(scenario.rawStderr || "simulated gh failure\n");
  process.exit(typeof scenario.rawStatus === "number" ? scenario.rawStatus : 1);
}

if (scenario.invalidJson) {
  writeState(state);
  process.stdout.write("{not json\n");
  process.exit(0);
}

const isLoad = compact.includes("title") && compact.includes("body");
const isLabeled = query.includes("$label");
const key = isLabeled ? String(fields.label || "") : "all-open";
if (isLabeled && !fields.label) {
  process.stderr.write("fake gh: labeled query missing label var\n");
  writeState(state);
  process.exit(64);
}

function asLoadNode(n) {
  if (n && n.raw) return n.raw;
  const out = {};
  if (Object.prototype.hasOwnProperty.call(n, "number")) out.number = n.number;
  if (Object.prototype.hasOwnProperty.call(n, "updatedAt")) out.updatedAt = n.updatedAt;
  if (Object.prototype.hasOwnProperty.call(n, "title")) out.title = n.title;
  if (Object.prototype.hasOwnProperty.call(n, "body")) out.body = n.body;
  if (Object.prototype.hasOwnProperty.call(n, "labelsConnection")) {
    out.labels = n.labelsConnection;
  } else if (Object.prototype.hasOwnProperty.call(n, "labels")) {
    if (Array.isArray(n.labels)) {
      const names = n.labels.map((x) =>
        typeof x === "string" ? x : x && x.name
      );
      out.labels = {
        totalCount: names.length,
        pageInfo: { hasNextPage: false, endCursor: names.length ? "label-end" : null },
        nodes: names.map((name) => ({ name })),
      };
    } else {
      out.labels = n.labels;
    }
  }
  return out;
}
function asObserveNode(n) {
  return { number: n.number, updatedAt: n.updatedAt };
}

function findPage(pages, after) {
  if (!pages || !pages.length) return null;
  if (!after || after === "null") return pages[0];
  for (let i = 0; i < pages.length; i++) {
    if (pages[i].endCursor === after) return pages[i + 1] || null;
  }
  return null;
}

const q = (scenario.queries && scenario.queries[key]) || null;
if (!q && !scenario.invalidShape) {
  process.stderr.write("fake gh: no fixture for query key " + key + "\n");
  writeState(state);
  process.exit(64);
}

if (isLoad) {
  state.loadCalls[key] = (state.loadCalls[key] || 0) + 1;
} else {
  state.observeCalls[key] = (state.observeCalls[key] || 0) + 1;
}

const after = fields.after;
const pageCount = q && Array.isArray(q.pages) ? q.pages.length : 1;
const observeN = state.observeCalls[key] || 0;
const afterPhase = !isLoad && observeN > pageCount;

let page;
if (scenario.invalidShape) {
  writeState(state);
  let payload = JSON.stringify({ data: {} });
  if (scenario.ansi) payload = "\u001b[32m" + payload + "\u001b[0m";
  process.stdout.write(payload);
  process.exit(0);
} else {
  const pages = afterPhase && q.pagesAfter ? q.pagesAfter : q.pages;
  page = findPage(pages, after);
  if (!page) {
    process.stderr.write(
      "fake gh: unknown cursor " + String(after) + " for " + key + "\n"
    );
    writeState(state);
    process.exit(1);
  }
}

const sha = afterPhase && scenario.shaAfter ? scenario.shaAfter : scenario.sha;
const nodes = (page.nodes || []).map((n) =>
  isLoad ? asLoadNode(n) : asObserveNode(n)
);
const payloadObj = {
  data: {
    repository: {
      defaultBranchRef: { target: { oid: sha } },
      issues: {
        totalCount: page.totalCount,
        pageInfo: {
          hasNextPage: Boolean(page.hasNextPage),
          endCursor: Object.prototype.hasOwnProperty.call(page, "endCursor")
            ? page.endCursor
            : null,
        },
        nodes,
      },
    },
  },
};

if (scenario.dropPageInfo) {
  delete payloadObj.data.repository.issues.pageInfo;
}
if (scenario.graphqlErrors) {
  payloadObj.errors = Array.isArray(scenario.graphqlErrors)
    ? scenario.graphqlErrors
    : [{ message: "OK DAG critical-path capacity blocker-first" }];
}

writeState(state);
let text = JSON.stringify(payloadObj);
if (scenario.ansi) text = "\u001b[32m" + text + "\u001b[0m";
process.stdout.write(text);
process.exit(0);
GH
  chmod +x "$ROOT/bin/gh"
}

# Shell gh for the 100-page cap: one /bin/sh spawn per call, not Node.
install_page_cap_gh() {
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/gh" <<'GH'
#!/bin/sh
log="${GIBSON_GH_LOG:?}"
printf 'call\n' >> "$log"
n=$(wc -l < "$log" | tr -d '[:space:]')
if [ "$n" -gt 150 ]; then
  printf 'fake gh: call cap (implementation failed to stop)\n' >&2
  exit 1
fi
printf '%s' "{\"data\":{\"repository\":{\"defaultBranchRef\":{\"target\":{\"oid\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}},\"issues\":{\"totalCount\":10001,\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"c${n}\"},\"nodes\":[{\"number\":${n},\"updatedAt\":\"2026-01-01T00:00:00Z\"}]}}}}"
GH
  chmod +x "$ROOT/bin/gh"
}

reset_gh() {
  rm -f "$ROOT/gh-calls.log" "$ROOT/gh-calls.log.state.json"
}

count_gh() {
  if [[ ! -f "$ROOT/gh-calls.log" ]]; then
    printf '%s' 0
    return
  fi
  wc -l < "$ROOT/gh-calls.log" | tr -d '[:space:]'
}

run_repo() {
  reset_gh
  GIBSON_GH_LOG="$ROOT/gh-calls.log" \
  GIBSON_GH_SCENARIO="$ROOT/scenario.json" \
  PATH="$ROOT/bin:$PATH" \
  node "$SENSOR" "$@" 2>&1
}

lacks_queue() {
  local name="$1" out="$2"
  if printf '%s\n' "$out" | node -e '
let s = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => { s += c; });
process.stdin.on("end", () => {
  const stripped = s.replace(/\b(?:digest|sha)=[0-9a-f]+\b/gi, "");
  const re = /(?<![A-Za-z0-9_-])(OK|DAG|critical-path|critical path|capacity|blocker-first)(?![A-Za-z0-9_-])/i;
  process.exit(re.test(stripped) ? 1 : 0);
});
'; then
    ok "$name: no queue conclusion"
  else
    bad "$name: leaked queue conclusion: $out"
  fi
}

expect_calls() {
  local name="$1" want="$2"
  local got
  got=$(count_gh)
  if [[ "$got" == "$want" ]]; then
    ok "$name: gh calls=$got"
  else
    bad "$name: gh calls want $want got $got"
  fi
}

expect_incomplete() {
  local name="$1" calls="$2"
  shift 2
  out=$(run_repo "$@"); rc=$?
  if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
    ok "$name: INCOMPLETE exit 3"
  else
    bad "$name (rc=$rc): $out"
  fi
  lacks_queue "$name" "$out"
  expect_calls "$name" "$calls"
}

assert_missing_selector() {
  local rc="$1" out="$2"
  [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q 'missing repository selector'
}

assert_three_page_lint() {
  local rc="$1" out="$2"
  [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'OK (3 issues)' \
    && printf '%s\n' "$out" | grep -q 'loaded=3' \
    && printf '%s\n' "$out" | grep -q 'totalCount=3'
}

assert_overlap_union() {
  local rc="$1" out="$2"
  [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'OK (3 issues)' \
    && printf '%s\n' "$out" | grep -q 'loaded=3' \
    && printf '%s\n' "$out" | grep -q 'unionTotal=3' \
    && printf '%s\n' "$out" | grep -q 'sourceTotals=2,2' \
    && ! printf '%s\n' "$out" | grep -q 'totalCount='
}

assert_stale() {
  local rc="$1" out="$2"
  [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE: STALE_OBSERVATION'
}

check_logged_queries() {
  node - "$ROOT/gh-calls.log" <<'NODE'
const fs = require("fs");
const log = fs.readFileSync(process.argv[2], "utf8").trim();
if (!log) {
  process.stdout.write("QUERY_FAIL empty log\n");
  process.exit(1);
}
function compact(q) { return String(q).replace(/\s+/g, ""); }
function missingFeatures(q) {
  const c = compact(q);
  const missing = [];
  if (!c.includes("states:[OPEN]")) missing.push("OPEN");
  if (!c.includes("$owner:String!")) missing.push("owner");
  if (!c.includes("$name:String!")) missing.push("name");
  if (!c.includes("defaultBranchRef{target{oid}}")) missing.push("oid");
  if (!c.includes("issues(first:100")) missing.push("pageSize");
  if (!/issues\([^)]*\)\{totalCount/.test(c)) missing.push("issueTotalCount");
  const load = c.includes("title") && c.includes("body");
  if (load) {
    if (!c.includes("labels(first:100){totalCountpageInfo{hasNextPageendCursor}nodes{name}}")) {
      missing.push("labelEvidence");
    }
    if (!c.includes("nodes{numbertitlebodyupdatedAtlabels(first:100)")) {
      missing.push("loadFields");
    }
  } else if (!c.includes("nodes{numberupdatedAt}")) {
    missing.push("observeFields");
  }
  return missing;
}
function queryOf(argv) {
  for (let i = 0; i < argv.length; i++) {
    if ((argv[i] === "-f" || argv[i] === "-F") && argv[i + 1] && argv[i + 1].indexOf("query=") === 0) {
      return argv[i + 1].slice("query=".length);
    }
  }
  return "";
}
const queries = log.split("\n").map((line) => queryOf(JSON.parse(line))).filter(Boolean);
let fail = false;
for (const q of queries) {
  const missing = missingFeatures(q);
  if (missing.length) {
    process.stdout.write("QUERY_FAIL " + missing.join(",") + "\n");
    fail = true;
  }
}
const loadQ = queries.find((q) => compact(q).includes("title"));
if (!loadQ) {
  process.stdout.write("QUERY_FAIL no-load-query\n");
  process.exit(1);
}
const dropOpen = loadQ.replace("states: [OPEN]", "").replace("states:[OPEN]", "");
if (missingFeatures(dropOpen).indexOf("OPEN") >= 0) {
  process.stdout.write("QUERY_SHAPE_CONTROL drop-OPEN\n");
} else {
  process.stdout.write("QUERY_SHAPE_STILL_ACCEPTED drop-OPEN\n");
  fail = true;
}
const dropCount = loadQ.replace(
  /issues(\([^)]*\))\s*\{\s*totalCount/,
  "issues$1 {"
);
if (missingFeatures(dropCount).indexOf("issueTotalCount") >= 0) {
  process.stdout.write("QUERY_SHAPE_CONTROL drop-totalCount\n");
} else {
  process.stdout.write("QUERY_SHAPE_STILL_ACCEPTED drop-totalCount\n");
  fail = true;
}
if (!fail) process.stdout.write("QUERY_OK count=" + queries.length + "\n");
process.exit(fail ? 1 : 0);
NODE
}

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
ISSUE_BODY='## Sprint contract\n- [ ] a\n- [ ] b\n## Affected area\napp\n## Dependencies\nnone\n## Tier\nA\n'

# Shared artifact validator. Inspects the exact path production receives.
# Grammar for heading boundaries and checkbox lines is the same as
# scripts/decompose-lint.mjs (section() / criteria()) — not a raw-byte grep.
# Exit 0 = parse+shape ok; 1 = JSON parse failure; 2 = shape/count failure;
# 3 = unreadable. Parse failure never continues into shape success tokens.
validate_issue_artifact() {
  local file="$1"
  node - "$file" <<'NODE'
const fs = require("fs");
const file = process.argv[2];

function section(body, name) {
  if (!body) return null;
  const re = new RegExp(
    `##\\s*${name}\\s*\\n([\\s\\S]*?)(?=\\n##\\s|$)`,
    "i"
  );
  const m = body.match(re);
  return m ? m[1].trim() : null;
}

function criteria(body) {
  const sc =
    section(body, "Sprint contract(?:\\s*\\(acceptance criteria\\))?") ||
    section(body, "Acceptance criteria") ||
    "";
  const lines = sc.split("\n").filter((l) => /^\s*[-*]\s+\[[ xX]\]/.test(l));
  return lines;
}

let raw;
try {
  raw = fs.readFileSync(file);
} catch (e) {
  process.stdout.write("READ_FAIL " + (e && e.message ? e.message : String(e)) + "\n");
  process.exit(3);
}

let parsed;
try {
  parsed = JSON.parse(raw.toString("utf8"));
} catch (e) {
  const name = e && e.name ? e.name : "Error";
  const msg = e && e.message ? e.message : String(e);
  process.stdout.write("PARSE_FAIL " + name + ": " + msg + "\n");
  process.exit(1);
}

process.stdout.write("PARSE_OK\n");

let shapeFail = false;
function shape(ok, token, msg) {
  if (ok) process.stdout.write(token + "\n");
  else {
    process.stdout.write("SHAPE_FAIL " + msg + "\n");
    shapeFail = true;
  }
}

shape(
  Array.isArray(parsed) && parsed.length === 1,
  "issues=1",
  "expected exactly one issue, got " + (Array.isArray(parsed) ? parsed.length : typeof parsed)
);

const issue = Array.isArray(parsed) ? parsed[0] || {} : {};
shape(issue.number === 4, "number=4", "issue number want 4 got " + String(issue.number));

const body = issue.body || "";
const sc =
  section(body, "Sprint contract(?:\\s*\\(acceptance criteria\\))?") ||
  section(body, "Acceptance criteria");
shape(!!sc, "sprint-contract-present", "missing Sprint contract section");

const crit = criteria(body);
shape(
  crit.length === 11,
  "sprint-contract-checkboxes=11",
  "sprint-contract-checkboxes want 11 got " + crit.length
);

const area = section(body, "Affected area");
const deps = section(body, "Dependencies");
const tier = section(body, "Tier");
shape(!!area, "affected-area=nonempty", "empty Affected area");
shape(!!deps, "dependencies=nonempty", "empty Dependencies");
shape(!!tier, "tier=nonempty", "empty Tier");

process.exit(shapeFail ? 2 : 0);
NODE
}

# Exact production-policy oracle for the valid >10 fixture.
# rc must be 1 (not generic nonzero). Finding must be exactly one line.
# Rejects parse errors, usage, stacks, and runtime banners.
assert_exact_toobig_policy() {
  local rc="$1" outfile="$2"
  node - "$rc" "$outfile" <<'NODE'
const fs = require("fs");
const rc = Number(process.argv[2]);
const out = fs.readFileSync(process.argv[3], "utf8");
const expected = "#4: contract has 11 criteria (>10 \u2192 split per docs/04)";
const banned = [
  /SyntaxError/,
  /Bad control character/,
  /missing file:/,
  /unknown flag:/,
  /WHAT IT DOES/,
  /provide --file or --repo/,
  /Node\.js v/,
];
if (rc !== 1) {
  process.stdout.write("POLICY_FAIL rc want 1 got " + rc + "\n");
  process.exit(1);
}
if (!/^decompose-lint: FAIL$/m.test(out)) {
  process.stdout.write("POLICY_FAIL missing FAIL header\n");
  process.exit(1);
}
const findings = out.split(/\n/).filter((l) => /^  - #/.test(l));
if (findings.length !== 1) {
  process.stdout.write("POLICY_FAIL finding count want 1 got " + findings.length + "\n");
  process.exit(1);
}
if (findings[0] !== "  - " + expected) {
  process.stdout.write("POLICY_FAIL finding mismatch: " + findings[0] + "\n");
  process.exit(1);
}
for (let i = 0; i < banned.length; i++) {
  if (banned[i].test(out)) {
    process.stdout.write("POLICY_FAIL banned pattern " + banned[i] + "\n");
    process.exit(1);
  }
}
if (/^\s+at /m.test(out)) {
  process.stdout.write("POLICY_FAIL stack frame present\n");
  process.exit(1);
}
process.stdout.write("POLICY_OK\n");
process.exit(0);
NODE
}

fixture_sha256() {
  local file="$1"
  node - "$file" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const buf = fs.readFileSync(process.argv[2]);
process.stdout.write(crypto.createHash("sha256").update(buf).digest("hex"));
NODE
}

# One receipt string for local stdout and the hosted job summary (no drift).
# run-all.sh re-emits only the suite tally, so GitHub logs never see stdout
# evidence; append the same line to $GITHUB_STEP_SUMMARY when both Actions
# variables are set. Local runs must not require those variables.
emit_toobig_receipt() {
  local receipt="$1"
  printf '%s\n' "$receipt"
  if [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$receipt" >> "$GITHUB_STEP_SUMMARY"
  fi
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
# One JSON.stringify of the complete issue object (no line-oriented echo
# inside an open JSON string).
node - "$ROOT/toobig.json" <<'NODE'
const fs = require("fs");
const dest = process.argv[2];
const lines = [];
for (let i = 1; i <= 11; i++) lines.push("- [ ] criterion " + i);
const body =
  "## Sprint contract\n" +
  lines.join("\n") +
  "\n## Affected area\napp\n## Dependencies\nnone\n## Tier\nA\n";
const issues = [{ number: 4, title: "Big", body, labels: [] }];
fs.writeFileSync(dest, JSON.stringify(issues) + "\n");
NODE

# Prove the exact path production will receive, before invoking production.
vout=$(validate_issue_artifact "$ROOT/toobig.json" 2>&1); vrc=$?
printf '%s\n' "$vout" | grep -qx 'PARSE_OK' \
  && ok "toobig.json is valid JSON" \
  || bad "toobig.json parse (rc=$vrc): $vout"
printf '%s\n' "$vout" | grep -qx 'issues=1' \
  && ok "toobig.json parses as one issue" \
  || bad "toobig.json issue count: $vout"
printf '%s\n' "$vout" | grep -qx 'number=4' \
  && ok "toobig.json issue number is 4" \
  || bad "toobig.json issue number: $vout"
printf '%s\n' "$vout" | grep -qx 'sprint-contract-present' \
  && ok "toobig.json has Sprint contract section" \
  || bad "toobig.json Sprint contract section: $vout"
# Count is the already-captured validator token, not a second parse of the file.
checkbox_n=$(printf '%s\n' "$vout" | sed -n 's/^sprint-contract-checkboxes=\([0-9][0-9]*\)$/\1/p')
if [[ "$checkbox_n" == "11" ]]; then
  ok "toobig.json sprint contract has 11 checkboxes"
else
  bad "toobig.json checkbox count: $vout"
fi
printf '%s\n' "$vout" | grep -qx 'affected-area=nonempty' \
  && ok "toobig.json Affected area nonempty" \
  || bad "toobig.json Affected area: $vout"
printf '%s\n' "$vout" | grep -qx 'dependencies=nonempty' \
  && ok "toobig.json Dependencies nonempty" \
  || bad "toobig.json Dependencies: $vout"
printf '%s\n' "$vout" | grep -qx 'tier=nonempty' \
  && ok "toobig.json Tier nonempty" \
  || bad "toobig.json Tier: $vout"

digest=$(fixture_sha256 "$ROOT/toobig.json")
if printf '%s' "$digest" | grep -Eq '^[0-9a-f]{64}$'; then
  if printf '%s' "$checkbox_n" | grep -Eq '^[0-9]+$'; then
    emit_toobig_receipt "toobig sha256=${digest} sprint-contract-checkboxes=${checkbox_n}"
  fi
  ok "toobig fixture sha256 is 64-hex"
else
  bad "toobig fixture sha256 not 64-hex: $digest"
fi

# Non-vacuity mutation: copy the valid artifact, inject one raw newline into
# a JSON string, send that exact mutated path through the same validator.
# The test script itself must remain bash -n clean; production-policy success
# must not be credited from the mutant.
node - "$ROOT/toobig.json" "$ROOT/toobig.mut.json" <<'NODE'
const fs = require("fs");
const srcPath = process.argv[2];
const dstPath = process.argv[3];
const src = fs.readFileSync(srcPath, "utf8");
const needle = "## Sprint contract";
const idx = src.indexOf(needle);
if (idx < 0) {
  process.stdout.write("MUTATION_FAIL needle not found\n");
  process.exit(2);
}
const mutated = src.slice(0, idx + needle.length) + "\n" + src.slice(idx + needle.length);
fs.writeFileSync(dstPath, mutated);
NODE

[[ -s "$ROOT/toobig.mut.json" ]] \
  && ok "mutated artifact exists" \
  || bad "mutated artifact missing"
if cmp -s "$ROOT/toobig.json" "$ROOT/toobig.mut.json"; then
  bad "mutated artifact identical to valid fixture"
else
  ok "mutated artifact differs from valid fixture"
fi

bnout=$(bash -n "$SCRIPT_DIR/decompose-lint.test.sh" 2>&1); bnrc=$?
[[ "$bnrc" -eq 0 ]] \
  && ok "test script still bash -n clean after mutation" \
  || bad "test script bash -n failed after mutation: $bnout"

mvout=$(validate_issue_artifact "$ROOT/toobig.mut.json" 2>&1); mvrc=$?
if [[ "$mvrc" -eq 1 ]] \
   && printf '%s\n' "$mvout" | grep -q '^PARSE_FAIL' \
   && printf '%s\n' "$mvout" | grep -qE 'SyntaxError|Bad control character'; then
  ok "mutated artifact fails JSON parse (not policy)"
else
  bad "mutant validator want PARSE_FAIL rc=1 got rc=$mvrc: $mvout"
fi

mout=$(run "$ROOT/toobig.mut.json"); mrc=$?
printf '%s\n' "$mout" > "$ROOT/toobig.mut.out"
if assert_exact_toobig_policy "$mrc" "$ROOT/toobig.mut.out" >/dev/null 2>&1; then
  bad "mutant production output credited as >10 policy"
else
  ok "mutant production not credited as >10 policy"
fi

digest_after=$(fixture_sha256 "$ROOT/toobig.json")
[[ "$digest" == "$digest_after" ]] \
  && ok "valid artifact unchanged after mutation" \
  || bad "valid artifact digest changed ($digest -> $digest_after)"

# Production oracle on the unchanged valid artifact only.
out=$(run "$ROOT/toobig.json"); rc=$?
printf '%s\n' "$out" > "$ROOT/toobig.out"
if assert_exact_toobig_policy "$rc" "$ROOT/toobig.out" >/dev/null; then
  ok ">10 criteria fails"
else
  bad "toobig (rc=$rc): $out"
fi

# --- missing file ---
out=$(node "$SENSOR" --file "$ROOT/nope.json" 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && ok "missing file exits 2" || bad "missing file (rc=$rc): $out"

# =============================================================================
# #257 repository loader cases (criterion 7) — fake gh, named exit/output/calls
# =============================================================================
install_loader_gh
cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","queries":{}}
JSON

# --- missing selector ---
out=$(run_repo --repo acme/app); rc=$?
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q 'missing repository selector'; then
  ok "missing selector: exit 2 names missing selector"
else
  bad "missing selector (rc=$rc): $out"
fi
expect_calls "missing selector" 0
if printf '%s\n' "$out" | grep -q 'unknown flag'; then
  bad "missing selector: should not be unknown-flag"
else
  ok "missing selector: not an unknown-flag miss"
fi

out=$(run_repo --repo acme/app --allow-empty); rc=$?
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q 'missing repository selector' \
   && ! printf '%s\n' "$out" | grep -q 'unknown flag'; then
  ok "missing selector: --allow-empty is a modifier, not a selector"
else
  bad "missing selector allow-empty (rc=$rc): $out"
fi
expect_calls "missing selector allow-empty" 0

# --- combined selectors ---
out=$(run_repo --repo acme/app --all-open --label alpha); rc=$?
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q 'combined selectors'; then
  ok "combined selectors: exit 2"
else
  bad "combined selectors (rc=$rc): $out"
fi
expect_calls "combined selectors" 0
if printf '%s\n' "$out" | grep -q 'unknown flag'; then
  bad "combined selectors: should not be unknown-flag"
else
  ok "combined selectors: not an unknown-flag miss"
fi

# --- repository selector plus --file ---
out=$(run_repo --file "$ROOT/clean.json" --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q -- '--file'; then
  ok "repository selector plus --file: --all-open exits 2"
else
  bad "file+all-open (rc=$rc): $out"
fi
expect_calls "file+all-open" 0

out=$(run_repo --file "$ROOT/clean.json" --label alpha); rc=$?
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q -- '--file'; then
  ok "repository selector plus --file: --label exits 2"
else
  bad "file+label (rc=$rc): $out"
fi
expect_calls "file+label" 0

out=$(run_repo --file "$ROOT/nope.json" --all-open); rc=$?
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q -- '--file'; then
  ok "repository selector plus --file: missing file still selector error"
else
  bad "file-missing+all-open (rc=$rc): $out"
fi
expect_calls "file-missing+all-open" 0

# --- empty selection ---
cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "all-open": {
      "pages": [
        {"totalCount": 0, "hasNextPage": false, "endCursor": null, "nodes": []}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s\n' "$out" | grep -q 'EMPTY_SELECTION: all-open'; then
  ok "empty selection: EMPTY_SELECTION exit 1 names all-open"
else
  bad "empty selection (rc=$rc): $out"
fi
lacks_queue "empty selection" "$out"
expect_calls "empty selection" 3

# --- allowed empty ---
out=$(run_repo --repo acme/app --all-open --allow-empty); rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'INTENTIONAL_EMPTY: all-open'; then
  ok "allowed empty: INTENTIONAL_EMPTY exit 0"
else
  bad "allowed empty (rc=$rc): $out"
fi
lacks_queue "allowed empty" "$out"
expect_calls "allowed empty" 3

# --- three-page --all-open ---
cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "all-open": {
      "pages": [
        {"totalCount": 3, "hasNextPage": true, "endCursor": "c1", "nodes": [{"number": 101, "updatedAt": "2026-01-01T00:00:00Z", "title": "One", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]},
        {"totalCount": 3, "hasNextPage": true, "endCursor": "c2", "nodes": [{"number": 102, "updatedAt": "2026-01-02T00:00:00Z", "title": "Two", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]},
        {"totalCount": 3, "hasNextPage": false, "endCursor": null, "nodes": [{"number": 103, "updatedAt": "2026-01-03T00:00:00Z", "title": "Three", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if assert_three_page_lint "$rc" "$out"; then
  ok "three-page --all-open: OK 3 issues with loaded===totalCount"
else
  bad "three-page --all-open (rc=$rc): $out"
fi
if grep -q graphql "$ROOT/gh-calls.log" 2>/dev/null; then
  ok "three-page --all-open: uses graphql"
else
  bad "three-page --all-open: did not use graphql"
fi
expect_calls "three-page --all-open" 9
qout=$(check_logged_queries 2>&1); qrc=$?
if [[ "$qrc" -eq 0 ]] && printf '%s\n' "$qout" | grep -q 'QUERY_OK' \
   && printf '%s\n' "$qout" | grep -q 'QUERY_SHAPE_CONTROL drop-OPEN' \
   && printf '%s\n' "$qout" | grep -q 'QUERY_SHAPE_CONTROL drop-totalCount'; then
  ok "logged-query shape control: required OPEN/totalCount present; static drop of each fails the checker"
else
  bad "logged-query shape control (rc=$qrc): $qout"
fi

# --- repeated-label disjoint union ---
cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "alpha": {
      "pages": [
        {"totalCount": 1, "hasNextPage": false, "endCursor": null, "nodes": [{"number": 10, "updatedAt": "2026-01-01T00:00:00Z", "title": "Alpha", "body": "$ISSUE_BODY", "labels": ["alpha"]}]}
      ]
    },
    "beta": {
      "pages": [
        {"totalCount": 1, "hasNextPage": false, "endCursor": null, "nodes": [{"number": 20, "updatedAt": "2026-01-02T00:00:00Z", "title": "Beta", "body": "$ISSUE_BODY", "labels": ["beta"]}]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --label alpha --label beta); rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'OK (2 issues)' \
   && printf '%s\n' "$out" | grep -q 'loaded=2' \
   && printf '%s\n' "$out" | grep -q 'unionTotal=2' \
   && printf '%s\n' "$out" | grep -q 'sourceTotals=1,1' \
   && ! printf '%s\n' "$out" | grep -q 'totalCount='; then
  ok "repeated-label disjoint union: OK 2 issues with unionTotal not API totalCount"
else
  bad "repeated-label disjoint union (rc=$rc): $out"
fi
expect_calls "repeated-label disjoint union" 6

# --- repeated-label overlapping union ---
cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "alpha": {
      "pages": [
        {"totalCount": 2, "hasNextPage": false, "endCursor": null, "nodes": [
          {"number": 10, "updatedAt": "2026-01-01T00:00:00Z", "title": "Ten", "body": "$ISSUE_BODY", "labels": ["alpha"]},
          {"number": 11, "updatedAt": "2026-01-02T00:00:00Z", "title": "Eleven", "body": "$ISSUE_BODY", "labels": ["alpha", "beta"]}
        ]}
      ]
    },
    "beta": {
      "pages": [
        {"totalCount": 2, "hasNextPage": false, "endCursor": null, "nodes": [
          {"number": 11, "updatedAt": "2026-01-02T00:00:00Z", "title": "Eleven", "body": "$ISSUE_BODY", "labels": ["alpha", "beta"]},
          {"number": 12, "updatedAt": "2026-01-03T00:00:00Z", "title": "Twelve", "body": "$ISSUE_BODY", "labels": ["beta"]}
        ]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --label alpha --label beta); rc=$?
if assert_overlap_union "$rc" "$out"; then
  ok "repeated-label overlapping union: OR-union of 3 issues (not last-label-wins)"
else
  bad "repeated-label overlapping union (rc=$rc): $out"
fi
expect_calls "repeated-label overlapping union" 6

# --- canonical label argv: order/duplicates share digest + source query count ---
receipt_digest() { printf '%s\n' "$1" | sed -n 's/.*digest=\([0-9a-f]\{64\}\).*/\1/p' | head -1; }
receipt_totals() { printf '%s\n' "$1" | sed -n 's/.*sourceTotals=\([^[:space:]]*\).*/\1/p' | head -1; }
receipt_loaded() { printf '%s\n' "$1" | sed -n 's/.*loaded=\([0-9][0-9]*\).*/\1/p' | head -1; }
receipt_lcount() { printf '%s\n' "$1" | sed -n 's/.*labels count=\([0-9][0-9]*\).*/\1/p' | head -1; }
out_ab=$(run_repo --repo acme/app --label alpha --label beta); rc_ab=$?
digest_ab=$(receipt_digest "$out_ab")
totals_ab=$(receipt_totals "$out_ab")
loaded_ab=$(receipt_loaded "$out_ab")
lcount_ab=$(receipt_lcount "$out_ab")
calls_ab=$(count_gh)
out_dup=$(run_repo --repo acme/app --label beta --label alpha --label alpha); rc_dup=$?
digest_dup=$(receipt_digest "$out_dup")
totals_dup=$(receipt_totals "$out_dup")
loaded_dup=$(receipt_loaded "$out_dup")
lcount_dup=$(receipt_lcount "$out_dup")
calls_dup=$(count_gh)
if [[ "$rc_ab" -eq 0 && "$rc_dup" -eq 0 \
   && "$digest_ab" == "$digest_dup" && ${#digest_ab} -eq 64 \
   && "$totals_ab" == "$totals_dup" && "$totals_ab" == "2,2" \
   && "$loaded_ab" == "$loaded_dup" && "$loaded_ab" == "3" \
   && "$lcount_ab" == "2" && "$lcount_dup" == "2" \
   && "$calls_ab" == "6" && "$calls_dup" == "6" ]]; then
  ok "canonical labels: order/duplicate argv share digest, sourceTotals, loaded, query count"
else
  bad "canonical labels (rc $rc_ab/$rc_dup digest $digest_ab/$digest_dup totals $totals_ab/$totals_dup loaded $loaded_ab/$loaded_dup count $lcount_ab/$lcount_dup calls $calls_ab/$calls_dup)"
fi

# --- API failure ---
HOSTILE_STDERR='OK DAG critical-path capacity blocker-first INCOMPLETE: READY'
cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","failApi":true,"rawStderr":"$HOSTILE_STDERR","queries":{"all-open":{"pages":[]}}}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE: API_FAILURE' \
   && ! printf '%s\n' "$out" | grep -F -q "$HOSTILE_STDERR"; then
  ok "API failure: INCOMPLETE exit 3 with typed code, no raw stderr"
else
  bad "API failure (rc=$rc): $out"
fi
lacks_queue "API failure" "$out"
expect_calls "API failure" 1

# --- invalid JSON/ANSI ---
cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","invalidJson":true,"queries":{"all-open":{"pages":[]}}}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
  ok "invalid JSON/ANSI: invalid JSON exits 3 INCOMPLETE"
else
  bad "invalid JSON (rc=$rc): $out"
fi
lacks_queue "invalid JSON" "$out"
expect_calls "invalid JSON" 1

cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "ansi": true,
  "queries": {
    "all-open": {
      "pages": [
        {"totalCount": 0, "hasNextPage": false, "endCursor": null, "nodes": []}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
  ok "invalid JSON/ANSI: ANSI-contaminated output exits 3 INCOMPLETE"
else
  bad "ANSI output (rc=$rc): $out"
fi
lacks_queue "ANSI output" "$out"
expect_calls "ANSI output" 1

# --- invalid shape/count ---
cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","invalidShape":true,"queries":{}}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
  ok "invalid shape/count: invalid shape exits 3 INCOMPLETE"
else
  bad "invalid shape (rc=$rc): $out"
fi
lacks_queue "invalid shape" "$out"
expect_calls "invalid shape" 1

cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "all-open": {
      "pages": [
        {"totalCount": 5, "hasNextPage": false, "endCursor": null, "nodes": [{"number": 1, "updatedAt": "2026-01-01T00:00:00Z", "title": "One", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
  ok "invalid shape/count: count mismatch exits 3 INCOMPLETE"
else
  bad "count mismatch (rc=$rc): $out"
fi
lacks_queue "count mismatch" "$out"
expect_calls "count mismatch" 1

# --- repeated/missing cursor ---
cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "all-open": {
      "pages": [
        {"totalCount": 2, "hasNextPage": true, "endCursor": null, "nodes": [{"number": 1, "updatedAt": "2026-01-01T00:00:00Z", "title": "One", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
  ok "repeated/missing cursor: missing cursor exits 3 INCOMPLETE"
else
  bad "missing cursor (rc=$rc): $out"
fi
lacks_queue "missing cursor" "$out"
expect_calls "missing cursor" 1

cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "all-open": {
      "pages": [
        {"totalCount": 3, "hasNextPage": true, "endCursor": "c1", "nodes": [{"number": 1, "updatedAt": "2026-01-01T00:00:00Z", "title": "One", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]},
        {"totalCount": 3, "hasNextPage": true, "endCursor": "c1", "nodes": [{"number": 2, "updatedAt": "2026-01-02T00:00:00Z", "title": "Two", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
  ok "repeated/missing cursor: repeated cursor exits 3 INCOMPLETE"
else
  bad "repeated cursor (rc=$rc): $out"
fi
lacks_queue "repeated cursor" "$out"
expect_calls "repeated cursor" 2

# --- page-cap exhaustion (shell gh; 100 calls, not 100 Node processes) ---
install_page_cap_gh
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE: PAGE_CAP'; then
  ok "page-cap exhaustion: INCOMPLETE: PAGE_CAP exit 3"
else
  bad "page-cap exhaustion (rc=$rc): $out"
fi
lacks_queue "page-cap exhaustion" "$out"
expect_calls "page-cap exhaustion" 100
install_loader_gh

# --- conflicting duplicate ---
cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "alpha": {
      "pages": [
        {"totalCount": 1, "hasNextPage": false, "endCursor": null, "nodes": [{"number": 5, "updatedAt": "2026-01-01T00:00:00Z", "title": "Five-A", "body": "$ISSUE_BODY", "labels": ["alpha"]}]}
      ]
    },
    "beta": {
      "pages": [
        {"totalCount": 1, "hasNextPage": false, "endCursor": null, "nodes": [{"number": 5, "updatedAt": "2026-01-02T00:00:00Z", "title": "Five-B", "body": "$ISSUE_BODY", "labels": ["beta"]}]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --label alpha --label beta); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE'; then
  ok "conflicting duplicate: INCOMPLETE exit 3"
else
  bad "conflicting duplicate (rc=$rc): $out"
fi
lacks_queue "conflicting duplicate" "$out"
expect_calls "conflicting duplicate" 2

# --- default-branch drift ---
cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "shaAfter": "$SHA_B",
  "queries": {
    "all-open": {
      "pages": [
        {"totalCount": 1, "hasNextPage": false, "endCursor": null, "nodes": [{"number": 7, "updatedAt": "2026-01-01T00:00:00Z", "title": "Seven", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE: STALE_OBSERVATION'; then
  ok "default-branch drift: INCOMPLETE: STALE_OBSERVATION exit 3"
else
  bad "default-branch drift (rc=$rc): $out"
fi
lacks_queue "default-branch drift" "$out"
expect_calls "default-branch drift" 3

# --- issue-set drift ---
cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "all-open": {
      "pages": [
        {"totalCount": 1, "hasNextPage": false, "endCursor": null, "nodes": [{"number": 7, "updatedAt": "2026-01-01T00:00:00Z", "title": "Seven", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]}
      ],
      "pagesAfter": [
        {"totalCount": 2, "hasNextPage": false, "endCursor": null, "nodes": [
          {"number": 7, "updatedAt": "2026-01-01T00:00:00Z", "title": "Seven", "body": "$ISSUE_BODY", "labels": ["tier-a"]},
          {"number": 8, "updatedAt": "2026-01-02T00:00:00Z", "title": "Eight", "body": "$ISSUE_BODY", "labels": ["tier-a"]}
        ]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if [[ "$rc" -eq 3 ]] && printf '%s\n' "$out" | grep -q 'INCOMPLETE: STALE_OBSERVATION'; then
  ok "issue-set drift: INCOMPLETE: STALE_OBSERVATION exit 3"
else
  bad "issue-set drift (rc=$rc): $out"
fi
lacks_queue "issue-set drift" "$out"
expect_calls "issue-set drift" 3

# --- hostile labels (empty selection; no raw label / verdict tokens) ---
for lab in OK DAG critical-path capacity; do
  cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "$lab": {
      "pages": [
        {"totalCount": 0, "hasNextPage": false, "endCursor": null, "nodes": []}
      ]
    }
  }
}
JSON
  out=$(run_repo --repo acme/app --label "$lab"); rc=$?
  if [[ "$rc" -eq 1 ]] && printf '%s\n' "$out" | grep -q 'EMPTY_SELECTION: labels count=1 digest=' \
     && printf '%s\n' "$out" | grep -Eq 'digest=[0-9a-f]{64}'; then
    ok "hostile label $lab: EMPTY_SELECTION digest only"
  else
    bad "hostile label $lab (rc=$rc): $out"
  fi
  lacks_queue "hostile label $lab" "$out"
  expect_calls "hostile label $lab" 3
done

cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "OK": {
      "pages": [
        {"totalCount": 0, "hasNextPage": false, "endCursor": null, "nodes": []}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --label OK --allow-empty); rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'INTENTIONAL_EMPTY: labels count=1 digest='; then
  ok "hostile label OK allowed-empty: INTENTIONAL_EMPTY digest only"
else
  bad "hostile label OK allow-empty (rc=$rc): $out"
fi
lacks_queue "hostile label OK allow-empty" "$out"

# --- control-character labels are usage errors before gh ---
out=$(run_repo --repo acme/app --label $'OK\nDAG'); rc=$?
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q 'control character'; then
  ok "embedded newline label: usage exit 2 before gh"
else
  bad "embedded newline label (rc=$rc): $out"
fi
lacks_queue "embedded newline label" "$out"
expect_calls "embedded newline label" 0

out=$(run_repo --repo acme/app --label $'\033[32mOK'); rc=$?
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -q 'control character'; then
  ok "embedded ANSI label: usage exit 2 before gh"
else
  bad "embedded ANSI label (rc=$rc): $out"
fi
lacks_queue "embedded ANSI label" "$out"
expect_calls "embedded ANSI label" 0

# --- GraphQL evidence (partial errors, oid, counts, node fields, labels) ---
node - "$ROOT" "$SHA_A" "$ISSUE_BODY" <<'NODE'
const fs = require("fs");
const root = process.argv[2];
const sha = process.argv[3];
const body = process.argv[4];
const good = {
  number: 1,
  updatedAt: "2026-01-01T00:00:00Z",
  title: "One",
  body,
  labels: ["tier-a"],
};
function allOpen(nodes, extra, pageExtra) {
  const page = Object.assign(
    { totalCount: nodes.length, hasNextPage: false, endCursor: null, nodes },
    pageExtra || {}
  );
  return Object.assign({ sha, queries: { "all-open": { pages: [page] } } }, extra || {});
}
function write(name, obj) {
  fs.writeFileSync(root + "/sc-" + name + ".json", JSON.stringify(obj));
}
write("partial-errors", allOpen([good], { graphqlErrors: true }));
write("bad-oid", allOpen([good], { sha: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }));
write("neg-count", allOpen([good], null, { totalCount: -1 }));
write("frac-count", allOpen([good], null, { totalCount: 1.5 }));
const over = [];
for (let i = 1; i <= 101; i++) {
  over.push({
    number: i,
    updatedAt: "2026-01-01T00:00:00Z",
    title: "T" + i,
    body,
    labels: ["tier-a"],
  });
}
write("overfull", allOpen(over, null, { totalCount: 101 }));
write("impossible-updatedAt", allOpen([Object.assign({}, good, { updatedAt: "2026-02-30T00:00:00Z" })]));
const noTitle = Object.assign({}, good);
delete noTitle.title;
write("missing-title", allOpen([noTitle]));
write("null-body", allOpen([Object.assign({}, good, { body: null })]));
write("malformed-title", allOpen([Object.assign({}, good, { title: 1 })]));
write("null-labels", allOpen([Object.assign({}, good, { labels: null })]));
write("missing-labels", allOpen([(() => { const n = Object.assign({}, good); delete n.labels; return n; })()]));
write("truncated-labels", allOpen([Object.assign({}, good, {
  labelsConnection: {
    totalCount: 3,
    pageInfo: { hasNextPage: false, endCursor: null },
    nodes: [{ name: "tier-a" }],
  },
})]));
write("label-overflow", allOpen([Object.assign({}, good, {
  labelsConnection: {
    totalCount: 101,
    pageInfo: { hasNextPage: false, endCursor: null },
    nodes: Array.from({ length: 101 }, (_, i) => ({ name: "l" + i })),
  },
})]));
write("label-next-page", allOpen([Object.assign({}, good, {
  labelsConnection: {
    totalCount: 1,
    pageInfo: { hasNextPage: true, endCursor: "c1" },
    nodes: [{ name: "tier-a" }],
  },
})]));
write("bad-label-cursor", allOpen([Object.assign({}, good, {
  labelsConnection: {
    totalCount: 1,
    pageInfo: { hasNextPage: false, endCursor: 7 },
    nodes: [{ name: "tier-a" }],
  },
})]));
NODE

cp "$ROOT/sc-partial-errors.json" "$ROOT/scenario.json"
expect_incomplete "partial GraphQL errors" 1 --repo acme/app --all-open
cp "$ROOT/sc-bad-oid.json" "$ROOT/scenario.json"
expect_incomplete "bad OID" 1 --repo acme/app --all-open
cp "$ROOT/sc-neg-count.json" "$ROOT/scenario.json"
expect_incomplete "negative totalCount" 1 --repo acme/app --all-open
cp "$ROOT/sc-frac-count.json" "$ROOT/scenario.json"
expect_incomplete "fractional totalCount" 1 --repo acme/app --all-open
cp "$ROOT/sc-overfull.json" "$ROOT/scenario.json"
expect_incomplete "overfull issue page" 1 --repo acme/app --all-open
cp "$ROOT/sc-impossible-updatedAt.json" "$ROOT/scenario.json"
expect_incomplete "impossible calendar updatedAt" 1 --repo acme/app --all-open
cp "$ROOT/sc-missing-title.json" "$ROOT/scenario.json"
expect_incomplete "missing title" 2 --repo acme/app --all-open
cp "$ROOT/sc-null-body.json" "$ROOT/scenario.json"
expect_incomplete "null body" 2 --repo acme/app --all-open
cp "$ROOT/sc-malformed-title.json" "$ROOT/scenario.json"
expect_incomplete "malformed title" 2 --repo acme/app --all-open
cp "$ROOT/sc-null-labels.json" "$ROOT/scenario.json"
expect_incomplete "null labels" 2 --repo acme/app --all-open
cp "$ROOT/sc-missing-labels.json" "$ROOT/scenario.json"
expect_incomplete "missing labels" 2 --repo acme/app --all-open
cp "$ROOT/sc-truncated-labels.json" "$ROOT/scenario.json"
expect_incomplete "truncated labels" 2 --repo acme/app --all-open
cp "$ROOT/sc-label-overflow.json" "$ROOT/scenario.json"
expect_incomplete "nested-label overflow" 2 --repo acme/app --all-open
cp "$ROOT/sc-label-next-page.json" "$ROOT/scenario.json"
expect_incomplete "nested-label truncation pageInfo" 2 --repo acme/app --all-open
cp "$ROOT/sc-bad-label-cursor.json" "$ROOT/scenario.json"
expect_incomplete "malformed terminal label cursor" 2 --repo acme/app --all-open

# --- mutation / non-vacuity harness ---
cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "gibson": {
      "pages": [
        {"totalCount": 0, "hasNextPage": false, "endCursor": null, "nodes": []}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --label gibson); rc=$?
if assert_missing_selector "$rc" "$out"; then
  bad "restore implicit default: missing-selector assertion still green"
else
  ok "restore implicit default: missing-selector assertion red"
fi

cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "all-open": {
      "pages": [
        {"totalCount": 2, "hasNextPage": true, "endCursor": "c1", "nodes": [{"number": 101, "updatedAt": "2026-01-01T00:00:00Z", "title": "One", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]},
        {"totalCount": 2, "hasNextPage": false, "endCursor": null, "nodes": [{"number": 102, "updatedAt": "2026-01-02T00:00:00Z", "title": "Two", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if assert_three_page_lint "$rc" "$out"; then
  bad "drop one page: three-page assertion still green"
else
  ok "drop one page: three-page assertion red"
fi

cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "alpha": {
      "pages": [
        {"totalCount": 2, "hasNextPage": false, "endCursor": null, "nodes": [
          {"number": 10, "updatedAt": "2026-01-01T00:00:00Z", "title": "Ten", "body": "$ISSUE_BODY", "labels": ["alpha"]},
          {"number": 11, "updatedAt": "2026-01-02T00:00:00Z", "title": "Eleven", "body": "$ISSUE_BODY", "labels": ["alpha", "beta"]}
        ]}
      ]
    },
    "beta": {
      "pages": [
        {"totalCount": 2, "hasNextPage": false, "endCursor": null, "nodes": [
          {"number": 11, "updatedAt": "2026-01-02T00:00:00Z", "title": "Eleven", "body": "$ISSUE_BODY", "labels": ["alpha", "beta"]},
          {"number": 12, "updatedAt": "2026-01-03T00:00:00Z", "title": "Twelve", "body": "$ISSUE_BODY", "labels": ["beta"]}
        ]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --label beta); rc=$?
if assert_overlap_union "$rc" "$out"; then
  bad "last-label-wins: overlapping-union assertion still green"
else
  ok "last-label-wins: overlapping-union assertion red"
fi

cat > "$ROOT/scenario.json" <<JSON
{
  "sha": "$SHA_A",
  "queries": {
    "all-open": {
      "pages": [
        {"totalCount": 1, "hasNextPage": false, "endCursor": null, "nodes": [{"number": 7, "updatedAt": "2026-01-01T00:00:00Z", "title": "Seven", "body": "$ISSUE_BODY", "labels": ["tier-a"]}]}
      ]
    }
  }
}
JSON
out=$(run_repo --repo acme/app --all-open); rc=$?
if assert_stale "$rc" "$out"; then
  bad "ignore before/after drift: stale assertion still green"
else
  ok "ignore before/after drift: stale assertion red"
fi

# --- preserved --file ---
cat > "$ROOT/scenario.json" <<JSON
{"sha":"$SHA_A","queries":{}}
JSON
reset_gh
out=$(
  GIBSON_GH_LOG="$ROOT/gh-calls.log" \
  GIBSON_GH_SCENARIO="$ROOT/scenario.json" \
  PATH="$ROOT/bin:$PATH" \
  node "$SENSOR" --file "$ROOT/clean.json" 2>&1
); rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'OK'; then
  ok "preserved --file: clean fixture still OK"
else
  bad "preserved --file (rc=$rc): $out"
fi
expect_calls "preserved --file" 0

echo
echo "decompose-lint.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
