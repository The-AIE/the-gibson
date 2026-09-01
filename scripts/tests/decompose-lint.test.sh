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

echo
echo "decompose-lint.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
