#!/usr/bin/env bash
# policy-manifest.test.sh — focused + mutation-receipt sensors for #188
#
# Offline, deterministic, Bash 3.2-compatible. Pure Node validator only — no
# network, no model, no gh. Proves structural validation, report byte-stability,
# doctrine consistency, and mutation receipts for gate/review/pair/digest/version.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
TOOL="$SCRIPT_DIR/../policy-manifest.mjs"
CANDIDATE="$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json"
SCHEMA="$REPO_ROOT/config/policy/schema/policy-manifest-v1.schema.json"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

command_not_found_handle() {
  bad "the suite invoked an undefined command '$1' — a shell error may never coexist with a green tally"
  return 127
}

command -v node >/dev/null || { echo "policy-manifest.test.sh: node required"; exit 1; }

# Hostile PATH stubs for network/model tools — pure validator must never call them.
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-policy-manifest.XXXXXX")
trap 'rm -rf -- "${ROOT:?}"' EXIT
BIN="$ROOT/bin"
mkdir -p "$BIN"
FORBIDDEN_LOG="$ROOT/forbidden.log"
: > "$FORBIDDEN_LOG"
for cmd in gh curl wget nc ssh openssl-net hermes ollama python python3 npm npx; do
  cat > "$BIN/$cmd" <<'STUB'
#!/usr/bin/env bash
echo "INVOKED_FORBIDDEN:$(basename "$0") $*" >> "${FORBIDDEN_LOG:-/dev/null}"
exit 99
STUB
  chmod +x "$BIN/$cmd"
done
# Keep system node/bash/coreutils; put stubs first for the names above.
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
# Resolve real node if PATH hid it
if ! command -v node >/dev/null 2>&1 || [[ "$(command -v node)" == "$BIN/node" ]]; then
  # Prefer known locations; fall back to /usr/bin/env search without stubs
  for cand in /Users/mrhinkle/.local/bin/node /usr/local/bin/node /opt/homebrew/bin/node; do
    if [[ -x "$cand" ]]; then
      _node_dir=$(dirname "$cand")
      PATH="$_node_dir:$PATH"
      export PATH
      unset _node_dir
      break
    fi
  done
fi
# Never stub node — find a real one
REAL_NODE=$(command -v node)
if [[ -z "$REAL_NODE" || "$REAL_NODE" == "$BIN/node" ]]; then
  echo "policy-manifest.test.sh: cannot locate a real node binary"
  exit 1
fi
NODE="$REAL_NODE"

# Ensure we did not put a node stub
if [[ -e "$BIN/node" ]]; then rm -f "$BIN/node"; fi

run_tool() {
  "$NODE" "$TOOL" "$@"
}

json_get() {
  # Tiny pure-node field reader (no jq dependency required for assertions).
  local file="$1" expr="$2"
  "$NODE" -e '
    const fs = require("fs");
    const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const path = process.argv[2].split(".");
    let cur = data;
    for (const p of path) {
      if (cur == null) { process.stdout.write("null"); process.exit(0); }
      cur = cur[p];
    }
    if (typeof cur === "object") process.stdout.write(JSON.stringify(cur));
    else process.stdout.write(String(cur));
  ' "$file" "$expr"
}

mutate_json() {
  # mutate_json SRC DST JS_MUTATOR
  # mutator receives object as `c` and may modify it; writes to DST.
  local src="$1" dst="$2" body="$3"
  "$NODE" -e '
    const fs = require("fs");
    const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const fn = new Function("c", process.argv[3]);
    fn(c);
    fs.writeFileSync(process.argv[2], JSON.stringify(c, null, 2) + "\n");
  ' "$src" "$dst" "$body"
}

echo "=== fixtures present ==="
[[ -f "$CANDIDATE" ]] && ok "candidate present" || bad "candidate missing"
[[ -f "$SCHEMA" ]] && ok "schema present" || bad "schema missing"
[[ -f "$TOOL" ]] && ok "validator present" || bad "validator missing"
schema_id=$(json_get "$CANDIDATE" "schemaId")
check "candidate schemaId" "$schema_id" "gibson.policy.manifest.schema.v1"
activated=$(json_get "$CANDIDATE" "activated")
check "candidate activated=false" "$activated" "false"
authority=$(json_get "$CANDIDATE" "authority")
check "candidate authority=report-only" "$authority" "report-only"

echo
echo "=== help / usage ==="
out=$(run_tool --help 2>&1) || true
has "help mentions report-only" "$out" "report-only"
has "help mentions no subprocess" "$out" "subprocess"
rc=0; run_tool >/dev/null 2>&1 || rc=$?
check "no-args exits 2" "$rc" "2"

echo
echo "=== validate clean candidate ==="
out=$(run_tool validate --repo-root "$REPO_ROOT" 2>&1); rc=$?
check "validate exits 0" "$rc" "0"
has "validate PASS" "$out" "verdict: PASS"
has "validate report-only notice" "$out" "report-only"
lacks "validate does not claim activation" "$out" "is an activated policy authority"

echo
echo "=== check-consistency clean ==="
out=$(run_tool check-consistency --repo-root "$REPO_ROOT" 2>&1); rc=$?
check "consistency exits 0" "$rc" "0"
has "consistency PASS" "$out" "consistency: PASS"

echo
echo "=== report mode: JSON + text, byte-stable ==="
R1="$ROOT/r1.json"
R2="$ROOT/r2.json"
run_tool report --repo-root "$REPO_ROOT" --format json > "$R1"; rc=$?
check "report json exits 0" "$rc" "0"
run_tool report --repo-root "$REPO_ROOT" --format json > "$R2"; rc=$?
check "report json second run exits 0" "$rc" "0"
if cmp -s "$R1" "$R2"; then ok "report JSON is byte-stable across runs"; else bad "report JSON not byte-stable"; fi
# Frozen fixture is committed under config/policy/fixtures/. Missing must fail closed
# — the suite must never write into the repo working tree (no silent mutation).
FIXTURE_DIR="$REPO_ROOT/config/policy/fixtures"
FROZEN="$FIXTURE_DIR/report-snapshot.json"
if [[ ! -f "$FROZEN" ]]; then
  bad "missing committed frozen fixture config/policy/fixtures/report-snapshot.json (fail closed; suite does not create it)"
elif cmp -s "$R1" "$FROZEN"; then
  ok "report matches frozen fixture"
else
  bad "report does not match frozen fixture (update config/policy/fixtures/report-snapshot.json if intentional)"
  echo "         tip: node scripts/policy-manifest.mjs report --format json > config/policy/fixtures/report-snapshot.json"
fi
ok_field=$(json_get "$R1" "ok")
check "report.ok true" "$ok_field" "true"
act_field=$(json_get "$R1" "activated")
check "report.activated false" "$act_field" "false"
auth_field=$(json_get "$R1" "authority")
check "report.authority report-only" "$auth_field" "report-only"
notice=$(json_get "$R1" "notice")
has "report notice denies activation" "$notice" "does NOT activate"
# human text
out=$(run_tool report --repo-root "$REPO_ROOT" --format text 2>&1); rc=$?
check "report text exits 0" "$rc" "0"
has "text verdict PASS" "$out" "verdict: PASS"
has "text activation note" "$out" "not an activated policy authority"

echo
echo "=== pure validator: no forbidden subprocess ==="
: > "$FORBIDDEN_LOG"
run_tool validate --repo-root "$REPO_ROOT" >/dev/null 2>&1 || true
run_tool report --repo-root "$REPO_ROOT" --format json >/dev/null 2>&1 || true
run_tool check-consistency --repo-root "$REPO_ROOT" >/dev/null 2>&1 || true
if [[ -s "$FORBIDDEN_LOG" ]]; then
  bad "validator invoked forbidden tool: $(cat "$FORBIDDEN_LOG")"
else
  ok "validator made no network/model/subprocess tool calls"
fi
# Static: source must not import child_process
if grep -q "child_process" "$TOOL"; then
  bad "validator source imports child_process"
else
  ok "validator source has no child_process import"
fi
if grep -Eq "spawn|execFile|execSync|spawnSync" "$TOOL"; then
  bad "validator source references process spawning"
else
  ok "validator source has no spawn/exec APIs"
fi

echo
echo "=== identity / provenance fields present ==="
for field in schemaId schemaVersion manifestId manifestVersion status authority \
             activated generatorVersion validatorVersion; do
  val=$(json_get "$CANDIDATE" "$field")
  if [[ -n "$val" && "$val" != "null" ]]; then ok "field $field set"; else bad "field $field missing"; fi
done
# provenance digests
src_count=$("$NODE" -e 'const c=require(process.argv[1]); process.stdout.write(String(c.provenance.sources.length))' "$CANDIDATE")
[[ "$src_count" -ge 4 ]] && ok "at least 4 provenance sources" || bad "provenance sources=$src_count"

echo
echo "=== encodes G1-G16, tiers, roles, stages ==="
gate_n=$("$NODE" -e 'const c=require(process.argv[1]); process.stdout.write(String(c.humanGates.length))' "$CANDIDATE")
check "16 human gates" "$gate_n" "16"
tier_n=$("$NODE" -e 'const c=require(process.argv[1]); process.stdout.write(String(c.riskTiers.length))' "$CANDIDATE")
check "3 risk tiers" "$tier_n" "3"
role_n=$("$NODE" -e 'const c=require(process.argv[1]); process.stdout.write(String(c.roles.length))' "$CANDIDATE")
check "9 roles" "$role_n" "9"
stage_n=$("$NODE" -e 'const c=require(process.argv[1]); process.stdout.write(String(c.workflowStages.length))' "$CANDIDATE")
check "10 workflow stages" "$stage_n" "10"

echo
echo "=== mutation receipts ==="

# 1) delete a gate
M="$ROOT/m-delete-gate.json"
mutate_json "$CANDIDATE" "$M" 'c.humanGates = c.humanGates.filter(g => g.id !== "G7");'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "delete gate fails closed" || bad "delete gate unexpectedly passed"
has "delete gate code" "$out" "E_GATE_MISSING"

# 2) rename a gate
M="$ROOT/m-rename-gate.json"
mutate_json "$CANDIDATE" "$M" 'c.humanGates = c.humanGates.map(g => g.id === "G7" ? Object.assign({}, g, { id: "G99" }) : g);'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "rename gate fails closed" || bad "rename gate unexpectedly passed"
# either unknown id or missing G7
if echo "$out" | grep -Eq 'E_UNKNOWN_ID|E_GATE_ID|E_GATE_MISSING'; then
  ok "rename gate diagnosed"
else
  bad "rename gate missing expected error code"
fi

# 3) change minimum review relationship (Tier C human-gate → independent-approve)
M="$ROOT/m-ri.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-c"
      ? Object.assign({}, r, { minimumRelationship: "independent-approve", humanGateId: "G12" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "review relationship change fails closed" || bad "review relationship change passed"
has "review relationship code" "$out" "E_RI_TIER_C"

# 4) change forbidden role pairing (drop builder↔reviewer)
M="$ROOT/m-pair.json"
mutate_json "$CANDIDATE" "$M" '
  c.forbiddenRolePairs = c.forbiddenRolePairs.filter(p =>
    !( (p.a === "builder" && p.b === "reviewer") || (p.a === "reviewer" && p.b === "builder") )
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "forbidden pair change fails closed" || bad "forbidden pair change passed"
has "forbidden pair code" "$out" "E_PAIR_REQUIRED"

# 4b) asymmetry
M="$ROOT/m-asym.json"
mutate_json "$CANDIDATE" "$M" '
  c.forbiddenRolePairs = c.forbiddenRolePairs.map(p =>
    (p.a === "builder" && p.b === "reviewer")
      ? Object.assign({}, p, { symmetric: false })
      : p
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "pair asymmetry fails closed" || bad "pair asymmetry passed"
has "pair asymmetry code" "$out" "E_PAIR_ASYMMETRY"

# 5) corrupt source digest
M="$ROOT/m-digest.json"
mutate_json "$CANDIDATE" "$M" '
  c.provenance.sources[0].digest = "0".repeat(64);
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "corrupt digest fails closed" || bad "corrupt digest passed"
has "digest mismatch code" "$out" "E_PROVENANCE_DIGEST_MISMATCH"

# 5b) malformed digest
M="$ROOT/m-digest-bad.json"
mutate_json "$CANDIDATE" "$M" '
  c.provenance.sources[0].digest = "not-a-digest";
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "malformed digest fails closed" || bad "malformed digest passed"
has "malformed digest code" "$out" "E_PROVENANCE_DIGEST"

# 6) unsupported version
M="$ROOT/m-ver.json"
mutate_json "$CANDIDATE" "$M" 'c.schemaVersion = "2.0.0";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "unsupported version fails closed" || bad "unsupported version passed"
has "unsupported version code" "$out" "E_UNSUPPORTED_VERSION"

# 7) duplicate gate id
M="$ROOT/m-dup.json"
mutate_json "$CANDIDATE" "$M" '
  c.humanGates.push(Object.assign({}, c.humanGates[0], { id: "G1", summary: "dup" }));
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "duplicate id fails closed" || bad "duplicate id passed"
has "duplicate id code" "$out" "E_DUPLICATE_ID"

# 8) broken reference (stage points at unknown role)
M="$ROOT/m-ref.json"
mutate_json "$CANDIDATE" "$M" 'c.workflowStages[0].roleId = "not-a-role";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "broken reference fails closed" || bad "broken reference passed"
has "broken ref code" "$out" "E_BROKEN_REF"

# 9) contradictory tier/gate mapping (G12 → A)
M="$ROOT/m-tgm.json"
mutate_json "$CANDIDATE" "$M" '
  c.tierGateMappings.push({ tierId: "A", gateIds: ["G12"], rationale: "wrong" });
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "contradictory tier/gate fails closed" || bad "contradictory tier/gate passed"
has "tier/gate contradiction code" "$out" "E_TIER_GATE_CONTRADICTION"

# 10) unsafe fork namespace (shadow core)
M="$ROOT/m-fork.json"
mutate_json "$CANDIDATE" "$M" 'c.forkExtensions.allowedNamespaces = ["gibson."];'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "unsafe fork namespace fails closed" || bad "unsafe fork namespace passed"
has "fork ns code" "$out" "E_FORK_NS_CORE"

# 11) ambiguous overrides (duplicate precedence + non-refuse)
M="$ROOT/m-ambig.json"
mutate_json "$CANDIDATE" "$M" '
  c.forkExtensions.precedence = ["task", "task", "global"];
  c.forkExtensions.conflictDisposition = "merge";
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ambiguous override fails closed" || bad "ambiguous override passed"
if echo "$out" | grep -q "E_AMBIGUOUS_OVERRIDE"; then
  ok "ambiguous override code"
else
  bad "ambiguous override missing E_AMBIGUOUS_OVERRIDE"
fi

# 12) claim activation
M="$ROOT/m-act.json"
mutate_json "$CANDIDATE" "$M" 'c.activated = true; c.authority = "active";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "activation claim fails closed" || bad "activation claim passed"

# 13) unknown root property (additionalProperties:false parity)
M="$ROOT/m-unk-root.json"
mutate_json "$CANDIDATE" "$M" 'c.secretControlPlane = { "enabled": true };'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "unknown root property fails closed" || bad "unknown root property passed"
has "unknown root property code" "$out" "E_UNKNOWN_PROPERTY"

# 14) unknown nested property
M="$ROOT/m-unk-nested.json"
mutate_json "$CANDIDATE" "$M" 'c.compatibility.extraLever = "loosen";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "unknown nested property fails closed" || bad "unknown nested property passed"
has "unknown nested property code" "$out" "E_UNKNOWN_PROPERTY"

# 15) unknown reviewIndependence id (closed set)
M="$ROOT/m-ri-unk.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence.push({
    id: "ri.unknown",
    description: "should fail",
    minimumRelationship: "independent-approve"
  });
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "unknown RI id fails closed" || bad "unknown RI id passed"
has "unknown RI id code" "$out" "E_RI_UNKNOWN_ID"

# 15b) missing required RI id (closed set completeness)
M="$ROOT/m-ri-miss.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.filter(r => r.id !== "ri.tier-a");
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing required RI id fails closed" || bad "missing required RI id passed"
has "missing RI required code" "$out" "E_RI_REQUIRED"

# 15c) unknown nested field on a reviewIndependence entry
M="$ROOT/m-ri-prop.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.law5" ? Object.assign({}, r, { shadowAuthority: true }) : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "unknown RI nested property fails closed" || bad "unknown RI nested property passed"
has "unknown RI nested property code" "$out" "E_UNKNOWN_PROPERTY"

# ---------------------------------------------------------------------------
# Schema value parity receipts (runtime must reject every schema value rule)
# Representative enum / boolean / integer-or-string / cardinality / const /
# missing-required failures across shapes. Codes are E_SCHEMA_*.
# ---------------------------------------------------------------------------

# 17) enum: humanGates category outside published enum
M="$ROOT/m-schema-enum-cat.json"
mutate_json "$CANDIDATE" "$M" 'c.humanGates[0].category = "bogus";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema enum category fails closed" || bad "schema enum category passed"
has "schema enum category code" "$out" "E_SCHEMA_ENUM"

# 17b) enum: status
M="$ROOT/m-schema-enum-status.json"
mutate_json "$CANDIDATE" "$M" 'c.status = "active";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema enum status fails closed" || bad "schema enum status passed"
has "schema enum status code" "$out" "E_SCHEMA_ENUM"

# 17c) enum: evidence reviewDepth
M="$ROOT/m-schema-enum-depth.json"
mutate_json "$CANDIDATE" "$M" 'c.riskTiers[0].evidenceMinimums.reviewDepth = "shallow";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema enum reviewDepth fails closed" || bad "schema enum reviewDepth passed"
has "schema enum reviewDepth code" "$out" "E_SCHEMA_ENUM"

# 18) boolean type: uxEvalIfVisible string "yes" (schema type boolean)
M="$ROOT/m-schema-bool.json"
mutate_json "$CANDIDATE" "$M" 'c.riskTiers[1].evidenceMinimums.uxEvalIfVisible = "yes";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema boolean type fails closed" || bad "schema boolean type passed"
has "schema boolean type code" "$out" "E_SCHEMA_TYPE"

# 18b) boolean type: severity as string
M="$ROOT/m-schema-bool-sev.json"
mutate_json "$CANDIDATE" "$M" 'c.humanGates[0].severity = "true";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema severity type fails closed" || bad "schema severity type passed"
has "schema severity type code" "$out" "E_SCHEMA_TYPE"

# 19) integer/string mismatch: notices.generatedViews must be string
M="$ROOT/m-schema-int-str.json"
mutate_json "$CANDIDATE" "$M" 'c.notices.generatedViews = 17;'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema generatedViews type fails closed" || bad "schema generatedViews type passed"
has "schema generatedViews type code" "$out" "E_SCHEMA_TYPE"

# 19b) integer bounds: workflowStages.order out of range
M="$ROOT/m-schema-order-max.json"
mutate_json "$CANDIDATE" "$M" 'c.workflowStages[0].order = 99;'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema order maximum fails closed" || bad "schema order maximum passed"
has "schema order maximum code" "$out" "E_SCHEMA_MAXIMUM"

# 19c) integer type: order as float
M="$ROOT/m-schema-order-float.json"
mutate_json "$CANDIDATE" "$M" 'c.workflowStages[0].order = 1.5;'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema order integer type fails closed" || bad "schema order integer type passed"
has "schema order integer type code" "$out" "E_SCHEMA_TYPE"

# 20) array cardinality: humanGates below minItems 16
M="$ROOT/m-schema-minitems.json"
mutate_json "$CANDIDATE" "$M" 'c.humanGates = c.humanGates.slice(0, 10);'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema minItems fails closed" || bad "schema minItems passed"
has "schema minItems code" "$out" "E_SCHEMA_MIN_ITEMS"

# 20b) array cardinality: roles above maxItems 9 (duplicate-like extra entry)
M="$ROOT/m-schema-maxitems.json"
mutate_json "$CANDIDATE" "$M" '
  c.roles.push({ id: "planner", summary: "extra beyond maxItems" });
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema maxItems fails closed" || bad "schema maxItems passed"
has "schema maxItems code" "$out" "E_SCHEMA_MAX_ITEMS"

# 20c) uniqueness/cardinality companion: empty provenance.sources (minItems 1)
M="$ROOT/m-schema-sources-empty.json"
mutate_json "$CANDIDATE" "$M" 'c.provenance.sources = [];'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema sources minItems fails closed" || bad "schema sources minItems passed"
has "schema sources minItems code" "$out" "E_SCHEMA_MIN_ITEMS"

# 21) const: authority must be report-only
M="$ROOT/m-schema-const-auth.json"
mutate_json "$CANDIDATE" "$M" 'c.authority = "advisory";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema const authority fails closed" || bad "schema const authority passed"
has "schema const authority code" "$out" "E_SCHEMA_CONST"

# 21b) const: forkExtensions.forbiddenCoreShadow must be true
M="$ROOT/m-schema-const-shadow.json"
mutate_json "$CANDIDATE" "$M" 'c.forkExtensions.forbiddenCoreShadow = false;'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema const forbiddenCoreShadow fails closed" || bad "schema const forbiddenCoreShadow passed"
has "schema const forbiddenCoreShadow code" "$out" "E_SCHEMA_CONST"

# 21c) const: activated must be false
M="$ROOT/m-schema-const-act.json"
mutate_json "$CANDIDATE" "$M" 'c.activated = true;'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema const activated fails closed" || bad "schema const activated passed"
has "schema const activated code" "$out" "E_SCHEMA_CONST"

# 22) missing required field: gate without category
M="$ROOT/m-schema-required.json"
mutate_json "$CANDIDATE" "$M" 'delete c.humanGates[0].category;'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema required category fails closed" || bad "schema required category passed"
has "schema required category code" "$out" "E_SCHEMA_REQUIRED"

# 22b) missing required root field
M="$ROOT/m-schema-required-root.json"
mutate_json "$CANDIDATE" "$M" 'delete c.notices;'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema required notices fails closed" || bad "schema required notices passed"
has "schema required notices code" "$out" "E_SCHEMA_REQUIRED"

# 22c) pattern: malformed provenance source id
M="$ROOT/m-schema-pattern.json"
mutate_json "$CANDIDATE" "$M" 'c.provenance.sources[0].id = "bad-id";'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema pattern source id fails closed" || bad "schema pattern source id passed"
has "schema pattern source id code" "$out" "E_SCHEMA_PATTERN"

# ---------------------------------------------------------------------------
# reviewIndependence semantic pins — each id's full defining tuple
# Mutations use individually schema-valid values that are semantically wrong.
# ---------------------------------------------------------------------------

# 23) ri.law5: different-agent → human-gate (schema-valid enum, wrong meaning)
M="$ROOT/m-ri-law5-min.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.law5"
      ? Object.assign({}, r, { minimumRelationship: "human-gate" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.law5 min relationship pin fails closed" || bad "ri.law5 min relationship pin passed"
has "ri.law5 pin code" "$out" "E_RI_LAW5"

# 23b) ri.law5: generatorMustNotEqual → builder (schema-valid role, wrong pin)
M="$ROOT/m-ri-law5-gen.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.law5"
      ? Object.assign({}, r, { generatorMustNotEqual: "builder" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.law5 generator pin fails closed" || bad "ri.law5 generator pin passed"
has "ri.law5 generator pin code" "$out" "E_RI_LAW5"

# 23c) ri.law5: preferredRelationship → human-gate
M="$ROOT/m-ri-law5-pref.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.law5"
      ? Object.assign({}, r, { preferredRelationship: "human-gate" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.law5 preferred pin fails closed" || bad "ri.law5 preferred pin passed"
has "ri.law5 preferred pin code" "$out" "E_RI_LAW5"

# 24) ri.tier-a: independent-approve → different-agent
M="$ROOT/m-ri-a-min.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-a"
      ? Object.assign({}, r, { minimumRelationship: "different-agent" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.tier-a min pin fails closed" || bad "ri.tier-a min pin passed"
has "ri.tier-a pin code" "$out" "E_RI_TIER_A"

# 24b) ri.tier-a: tierId A → B (schema-valid tier enum, wrong binding)
M="$ROOT/m-ri-a-tier.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-a"
      ? Object.assign({}, r, { tierId: "B" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.tier-a tierId pin fails closed" || bad "ri.tier-a tierId pin passed"
has "ri.tier-a tierId pin code" "$out" "E_RI_TIER_A"

# 24c) ri.tier-a: preferred cross-vendor → two-fresh-context-approve
M="$ROOT/m-ri-a-pref.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-a"
      ? Object.assign({}, r, { preferredRelationship: "two-fresh-context-approve" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.tier-a preferred pin fails closed" || bad "ri.tier-a preferred pin passed"
has "ri.tier-a preferred pin code" "$out" "E_RI_TIER_A"

# 25) ri.tier-b: preferred two-fresh-context-approve → cross-vendor
M="$ROOT/m-ri-b-pref.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-b"
      ? Object.assign({}, r, { preferredRelationship: "cross-vendor" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.tier-b preferred pin fails closed" || bad "ri.tier-b preferred pin passed"
has "ri.tier-b pin code" "$out" "E_RI_TIER_B"

# 25b) ri.tier-b: minimum independent-approve → human-gate
M="$ROOT/m-ri-b-min.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-b"
      ? Object.assign({}, r, { minimumRelationship: "human-gate" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.tier-b min pin fails closed" || bad "ri.tier-b min pin passed"
has "ri.tier-b min pin code" "$out" "E_RI_TIER_B"

# 25c) ri.tier-b: tierId B → A
M="$ROOT/m-ri-b-tier.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-b"
      ? Object.assign({}, r, { tierId: "A" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.tier-b tierId pin fails closed" || bad "ri.tier-b tierId pin passed"
has "ri.tier-b tierId pin code" "$out" "E_RI_TIER_B"

# 26) ri.tier-c: preferred human-gate → cross-vendor (schema-valid, wrong)
M="$ROOT/m-ri-c-pref.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-c"
      ? Object.assign({}, r, { preferredRelationship: "cross-vendor" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.tier-c preferred pin fails closed" || bad "ri.tier-c preferred pin passed"
has "ri.tier-c preferred pin code" "$out" "E_RI_TIER_C"

# 26b) ri.tier-c: humanGateId G12 → G1 (schema-valid gate, wrong pin)
M="$ROOT/m-ri-c-gate.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-c"
      ? Object.assign({}, r, { humanGateId: "G1" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.tier-c humanGateId pin fails closed" || bad "ri.tier-c humanGateId pin passed"
has "ri.tier-c humanGateId pin code" "$out" "E_RI_TIER_C"

# 26c) ri.tier-c: tierId C → B
M="$ROOT/m-ri-c-tier.json"
mutate_json "$CANDIDATE" "$M" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-c"
      ? Object.assign({}, r, { tierId: "B" })
      : r
  );
'
out=$(run_tool validate --manifest "$M" --repo-root "$REPO_ROOT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "ri.tier-c tierId pin fails closed" || bad "ri.tier-c tierId pin passed"
has "ri.tier-c tierId pin code" "$out" "E_RI_TIER_C"

# 16) adversarial symlink escape: repo-relative symlink to outside must fail digest check
# Build a disposable mini-repo so we never touch the real checkout.
MINI="$ROOT/mini-repo"
OUTSIDE_FOR_LINK="$ROOT/outside-secret"
mkdir -p "$MINI/docs" "$MINI/config/policy/candidates" "$OUTSIDE_FOR_LINK"
echo "secret-bytes-not-in-repo" > "$OUTSIDE_FOR_LINK/leaked.txt"
# Legitimate in-repo doctrine stubs so other fields can be valid if needed
printf '# gates\n**G1**\n' > "$MINI/docs/14-human-gates.md"
# Symlink that looks repo-relative but realpaths outside
ln -s "$OUTSIDE_FOR_LINK/leaked.txt" "$MINI/docs/escape-link.md"
# Candidate with a provenance path pointing at the symlink
M="$ROOT/m-symlink.json"
mutate_json "$CANDIDATE" "$M" '
  c.provenance.sources = [{
    id: "src.escape",
    path: "docs/escape-link.md",
    digestAlgorithm: "sha256",
    digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    role: "canonical-doctrine"
  }];
'
# Copy mutated candidate into mini repo (validator resolves relative to --repo-root)
cp "$M" "$MINI/config/policy/candidates/gibson-core-v1.candidate.json"
out=$(run_tool validate --manifest "config/policy/candidates/gibson-core-v1.candidate.json" --repo-root "$MINI" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "symlink escape fails closed" || bad "symlink escape passed (rc=$rc)"
if echo "$out" | grep -Eq 'E_PROVENANCE_PATH_ESCAPE|realpath escapes|symlink'; then
  ok "symlink escape diagnosed"
else
  bad "symlink escape missing escape diagnosis (out=$out)"
fi
# Also prove digest CLI refuses
out=$(run_tool digest --path docs/escape-link.md --repo-root "$MINI" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "digest CLI refuses symlink escape" || bad "digest CLI followed symlink escape"

# Control: legitimate in-repo path still works under realpath containment
echo "legit" > "$MINI/docs/legit.md"
out=$(run_tool digest --path docs/legit.md --repo-root "$MINI" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "legitimate in-repo path still digests" || bad "legitimate path refused (out=$out)"

echo
echo "=== docs guide present ==="
GUIDE="$REPO_ROOT/docs/policy-manifest-v1.md"
if [[ -f "$GUIDE" ]]; then
  ok "compatibility guide present"
  for needle in "namespaced" "precedence" "rollback" "activation" "#164" "generated"; do
    if grep -qi "$needle" "$GUIDE"; then ok "guide mentions $needle"; else bad "guide missing $needle"; fi
  done
else
  bad "compatibility guide missing"
fi

echo
echo "=== README inventory lists validator ==="
if grep -q "policy-manifest.mjs" "$REPO_ROOT/scripts/README.md"; then
  ok "scripts/README.md inventories policy-manifest.mjs"
else
  bad "scripts/README.md missing policy-manifest.mjs"
fi
if grep -q "policy-manifest.test.sh" "$REPO_ROOT/scripts/README.md"; then
  ok "scripts/README.md inventories policy-manifest.test.sh"
else
  bad "scripts/README.md missing policy-manifest.test.sh"
fi

echo
echo "policy-manifest.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
