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

# Disposable sandbox under --repo-root: schema + doctrine copies so mutations
# use relative --manifest only (absolute paths are refused by containment).
MUT="$ROOT/mut-sandbox"
mkdir -p "$MUT/config/policy/schema" "$MUT/docs"
cp "$SCHEMA" "$MUT/config/policy/schema/policy-manifest-v1.schema.json"
for _doc in 14-human-gates.md 06-quality-gates.md 03-roles.md 02-sdlc-pipeline.md 18-fork-and-upstream.md; do
  cp "$REPO_ROOT/docs/$_doc" "$MUT/docs/"
done

# mut_validate REL_NAME JS_BODY [extra validator args...]
# Writes mutated candidate at MUT/REL_NAME and validates with --repo-root MUT.
mut_validate() {
  local rel="$1"
  local body="$2"
  shift 2
  mutate_json "$CANDIDATE" "$MUT/$rel" "$body"
  out=$(run_tool validate --manifest "$rel" --repo-root "$MUT" "$@" 2>&1); rc=$?
}

# 1) delete a gate
mut_validate "m-delete-gate.json" 'c.humanGates = c.humanGates.filter(g => g.id !== "G7");' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "delete gate fails closed" || bad "delete gate unexpectedly passed"
has "delete gate code" "$out" "E_GATE_MISSING"

# 2) rename a gate
mut_validate "m-rename-gate.json" 'c.humanGates = c.humanGates.map(g => g.id === "G7" ? Object.assign({}, g, { id: "G99" }) : g);' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "rename gate fails closed" || bad "rename gate unexpectedly passed"
# either unknown id or missing G7
if echo "$out" | grep -Eq 'E_UNKNOWN_ID|E_GATE_ID|E_GATE_MISSING'; then
  ok "rename gate diagnosed"
else
  bad "rename gate missing expected error code"
fi

# 3) change minimum review relationship (Tier C human-gate → independent-approve)
mut_validate "m-ri.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-c"
      ? Object.assign({}, r, { minimumRelationship: "independent-approve", humanGateId: "G12" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "review relationship change fails closed" || bad "review relationship change passed"
has "review relationship code" "$out" "E_RI_TIER_C"

# 4) change forbidden role pairing (drop builder↔reviewer)
mut_validate "m-pair.json" '
  c.forbiddenRolePairs = c.forbiddenRolePairs.filter(p =>
    !( (p.a === "builder" && p.b === "reviewer") || (p.a === "reviewer" && p.b === "builder") )
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "forbidden pair change fails closed" || bad "forbidden pair change passed"
has "forbidden pair code" "$out" "E_PAIR_REQUIRED"

# 4b) asymmetry
mut_validate "m-asym.json" '
  c.forbiddenRolePairs = c.forbiddenRolePairs.map(p =>
    (p.a === "builder" && p.b === "reviewer")
      ? Object.assign({}, p, { symmetric: false })
      : p
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "pair asymmetry fails closed" || bad "pair asymmetry passed"
has "pair asymmetry code" "$out" "E_PAIR_ASYMMETRY"

# 5) corrupt source digest
mut_validate "m-digest.json" '
  c.provenance.sources[0].digest = "0".repeat(64);
'
[[ "$rc" -ne 0 ]] && ok "corrupt digest fails closed" || bad "corrupt digest passed"
has "digest mismatch code" "$out" "E_PROVENANCE_DIGEST_MISMATCH"

# 5b) malformed digest
mut_validate "m-digest-bad.json" '
  c.provenance.sources[0].digest = "not-a-digest";
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "malformed digest fails closed" || bad "malformed digest passed"
has "malformed digest code" "$out" "E_PROVENANCE_DIGEST"

# 6) unsupported version
mut_validate "m-ver.json" 'c.schemaVersion = "2.0.0";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "unsupported version fails closed" || bad "unsupported version passed"
has "unsupported version code" "$out" "E_UNSUPPORTED_VERSION"

# 7) duplicate gate id
mut_validate "m-dup.json" '
  c.humanGates.push(Object.assign({}, c.humanGates[0], { id: "G1", summary: "dup" }));
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "duplicate id fails closed" || bad "duplicate id passed"
has "duplicate id code" "$out" "E_DUPLICATE_ID"

# 8) broken reference (stage points at unknown role)
mut_validate "m-ref.json" 'c.workflowStages[0].roleId = "not-a-role";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "broken reference fails closed" || bad "broken reference passed"
has "broken ref code" "$out" "E_BROKEN_REF"

# 9) contradictory tier/gate mapping (G12 → A)
mut_validate "m-tgm.json" '
  c.tierGateMappings.push({ tierId: "A", gateIds: ["G12"], rationale: "wrong" });
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "contradictory tier/gate fails closed" || bad "contradictory tier/gate passed"
has "tier/gate contradiction code" "$out" "E_TIER_GATE_CONTRADICTION"

# 10) unsafe fork namespace (shadow core)
mut_validate "m-fork.json" 'c.forkExtensions.allowedNamespaces = ["gibson."];' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "unsafe fork namespace fails closed" || bad "unsafe fork namespace passed"
has "fork ns code" "$out" "E_FORK_NS_CORE"

# 11) ambiguous overrides (duplicate precedence + non-refuse)
mut_validate "m-ambig.json" '
  c.forkExtensions.precedence = ["task", "task", "global"];
  c.forkExtensions.conflictDisposition = "merge";
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ambiguous override fails closed" || bad "ambiguous override passed"
if echo "$out" | grep -q "E_AMBIGUOUS_OVERRIDE"; then
  ok "ambiguous override code"
else
  bad "ambiguous override missing E_AMBIGUOUS_OVERRIDE"
fi

# 12) claim activation
mut_validate "m-act.json" 'c.activated = true; c.authority = "active";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "activation claim fails closed" || bad "activation claim passed"

# 13) unknown root property (additionalProperties:false parity)
mut_validate "m-unk-root.json" 'c.secretControlPlane = { "enabled": true };' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "unknown root property fails closed" || bad "unknown root property passed"
has "unknown root property code" "$out" "E_UNKNOWN_PROPERTY"

# 14) unknown nested property
mut_validate "m-unk-nested.json" 'c.compatibility.extraLever = "loosen";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "unknown nested property fails closed" || bad "unknown nested property passed"
has "unknown nested property code" "$out" "E_UNKNOWN_PROPERTY"

# 15) unknown reviewIndependence id (closed set)
mut_validate "m-ri-unk.json" '
  c.reviewIndependence.push({
    id: "ri.unknown",
    description: "should fail",
    minimumRelationship: "independent-approve"
  });
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "unknown RI id fails closed" || bad "unknown RI id passed"
has "unknown RI id code" "$out" "E_RI_UNKNOWN_ID"

# 15b) missing required RI id (closed set completeness)
mut_validate "m-ri-miss.json" '
  c.reviewIndependence = c.reviewIndependence.filter(r => r.id !== "ri.tier-a");
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "missing required RI id fails closed" || bad "missing required RI id passed"
has "missing RI required code" "$out" "E_RI_REQUIRED"

# 15c) unknown nested field on a reviewIndependence entry
mut_validate "m-ri-prop.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.law5" ? Object.assign({}, r, { shadowAuthority: true }) : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "unknown RI nested property fails closed" || bad "unknown RI nested property passed"
has "unknown RI nested property code" "$out" "E_UNKNOWN_PROPERTY"

# ---------------------------------------------------------------------------
# Schema value parity receipts (runtime must reject every schema value rule)
# Representative enum / boolean / integer-or-string / cardinality / const /
# missing-required failures across shapes. Codes are E_SCHEMA_*.
# ---------------------------------------------------------------------------

# 17) enum: humanGates category outside published enum
mut_validate "m-schema-enum-cat.json" 'c.humanGates[0].category = "bogus";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema enum category fails closed" || bad "schema enum category passed"
has "schema enum category code" "$out" "E_SCHEMA_ENUM"

# 17b) enum: status
mut_validate "m-schema-enum-status.json" 'c.status = "active";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema enum status fails closed" || bad "schema enum status passed"
has "schema enum status code" "$out" "E_SCHEMA_ENUM"

# 17c) enum: evidence reviewDepth
mut_validate "m-schema-enum-depth.json" 'c.riskTiers[0].evidenceMinimums.reviewDepth = "shallow";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema enum reviewDepth fails closed" || bad "schema enum reviewDepth passed"
has "schema enum reviewDepth code" "$out" "E_SCHEMA_ENUM"

# 18) boolean type: uxEvalIfVisible string "yes" (schema type boolean)
mut_validate "m-schema-bool.json" 'c.riskTiers[1].evidenceMinimums.uxEvalIfVisible = "yes";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema boolean type fails closed" || bad "schema boolean type passed"
has "schema boolean type code" "$out" "E_SCHEMA_TYPE"

# 18b) boolean type: severity as string
mut_validate "m-schema-bool-sev.json" 'c.humanGates[0].severity = "true";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema severity type fails closed" || bad "schema severity type passed"
has "schema severity type code" "$out" "E_SCHEMA_TYPE"

# 19) integer/string mismatch: notices.generatedViews must be string
mut_validate "m-schema-int-str.json" 'c.notices.generatedViews = 17;' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema generatedViews type fails closed" || bad "schema generatedViews type passed"
has "schema generatedViews type code" "$out" "E_SCHEMA_TYPE"

# 19b) integer bounds: workflowStages.order out of range
mut_validate "m-schema-order-max.json" 'c.workflowStages[0].order = 99;' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema order maximum fails closed" || bad "schema order maximum passed"
has "schema order maximum code" "$out" "E_SCHEMA_MAXIMUM"

# 19c) integer type: order as float
mut_validate "m-schema-order-float.json" 'c.workflowStages[0].order = 1.5;' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema order integer type fails closed" || bad "schema order integer type passed"
has "schema order integer type code" "$out" "E_SCHEMA_TYPE"

# 20) array cardinality: humanGates below minItems 16
mut_validate "m-schema-minitems.json" 'c.humanGates = c.humanGates.slice(0, 10);' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema minItems fails closed" || bad "schema minItems passed"
has "schema minItems code" "$out" "E_SCHEMA_MIN_ITEMS"

# 20b) array cardinality: roles above maxItems 9 (duplicate-like extra entry)
mut_validate "m-schema-maxitems.json" '
  c.roles.push({ id: "planner", summary: "extra beyond maxItems" });
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema maxItems fails closed" || bad "schema maxItems passed"
has "schema maxItems code" "$out" "E_SCHEMA_MAX_ITEMS"

# 20c) uniqueness/cardinality companion: empty provenance.sources (minItems 1)
mut_validate "m-schema-sources-empty.json" 'c.provenance.sources = [];' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema sources minItems fails closed" || bad "schema sources minItems passed"
has "schema sources minItems code" "$out" "E_SCHEMA_MIN_ITEMS"

# 21) const: authority must be report-only
mut_validate "m-schema-const-auth.json" 'c.authority = "advisory";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema const authority fails closed" || bad "schema const authority passed"
has "schema const authority code" "$out" "E_SCHEMA_CONST"

# 21b) const: forkExtensions.forbiddenCoreShadow must be true
mut_validate "m-schema-const-shadow.json" 'c.forkExtensions.forbiddenCoreShadow = false;' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema const forbiddenCoreShadow fails closed" || bad "schema const forbiddenCoreShadow passed"
has "schema const forbiddenCoreShadow code" "$out" "E_SCHEMA_CONST"

# 21c) const: activated must be false
mut_validate "m-schema-const-act.json" 'c.activated = true;' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema const activated fails closed" || bad "schema const activated passed"
has "schema const activated code" "$out" "E_SCHEMA_CONST"

# 22) missing required field: gate without category
mut_validate "m-schema-required.json" 'delete c.humanGates[0].category;' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema required category fails closed" || bad "schema required category passed"
has "schema required category code" "$out" "E_SCHEMA_REQUIRED"

# 22b) missing required root field
mut_validate "m-schema-required-root.json" 'delete c.notices;' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema required notices fails closed" || bad "schema required notices passed"
has "schema required notices code" "$out" "E_SCHEMA_REQUIRED"

# 22c) pattern: malformed provenance source id
mut_validate "m-schema-pattern.json" 'c.provenance.sources[0].id = "bad-id";' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "schema pattern source id fails closed" || bad "schema pattern source id passed"
has "schema pattern source id code" "$out" "E_SCHEMA_PATTERN"

# ---------------------------------------------------------------------------
# reviewIndependence semantic pins — each id's full defining tuple
# Mutations use individually schema-valid values that are semantically wrong.
# ---------------------------------------------------------------------------

# 23) ri.law5: different-agent → human-gate (schema-valid enum, wrong meaning)
mut_validate "m-ri-law5-min.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.law5"
      ? Object.assign({}, r, { minimumRelationship: "human-gate" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.law5 min relationship pin fails closed" || bad "ri.law5 min relationship pin passed"
has "ri.law5 pin code" "$out" "E_RI_LAW5"

# 23b) ri.law5: generatorMustNotEqual → builder (schema-valid role, wrong pin)
mut_validate "m-ri-law5-gen.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.law5"
      ? Object.assign({}, r, { generatorMustNotEqual: "builder" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.law5 generator pin fails closed" || bad "ri.law5 generator pin passed"
has "ri.law5 generator pin code" "$out" "E_RI_LAW5"

# 23c) ri.law5: preferredRelationship → human-gate
mut_validate "m-ri-law5-pref.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.law5"
      ? Object.assign({}, r, { preferredRelationship: "human-gate" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.law5 preferred pin fails closed" || bad "ri.law5 preferred pin passed"
has "ri.law5 preferred pin code" "$out" "E_RI_LAW5"

# 24) ri.tier-a: independent-approve → different-agent
mut_validate "m-ri-a-min.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-a"
      ? Object.assign({}, r, { minimumRelationship: "different-agent" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-a min pin fails closed" || bad "ri.tier-a min pin passed"
has "ri.tier-a pin code" "$out" "E_RI_TIER_A"

# 24b) ri.tier-a: tierId A → B (schema-valid tier enum, wrong binding)
mut_validate "m-ri-a-tier.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-a"
      ? Object.assign({}, r, { tierId: "B" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-a tierId pin fails closed" || bad "ri.tier-a tierId pin passed"
has "ri.tier-a tierId pin code" "$out" "E_RI_TIER_A"

# 24c) ri.tier-a: preferred cross-vendor → two-fresh-context-approve
mut_validate "m-ri-a-pref.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-a"
      ? Object.assign({}, r, { preferredRelationship: "two-fresh-context-approve" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-a preferred pin fails closed" || bad "ri.tier-a preferred pin passed"
has "ri.tier-a preferred pin code" "$out" "E_RI_TIER_A"

# 25) ri.tier-b: preferred two-fresh-context-approve → cross-vendor
mut_validate "m-ri-b-pref.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-b"
      ? Object.assign({}, r, { preferredRelationship: "cross-vendor" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-b preferred pin fails closed" || bad "ri.tier-b preferred pin passed"
has "ri.tier-b pin code" "$out" "E_RI_TIER_B"

# 25b) ri.tier-b: minimum independent-approve → human-gate
mut_validate "m-ri-b-min.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-b"
      ? Object.assign({}, r, { minimumRelationship: "human-gate" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-b min pin fails closed" || bad "ri.tier-b min pin passed"
has "ri.tier-b min pin code" "$out" "E_RI_TIER_B"

# 25c) ri.tier-b: tierId B → A
mut_validate "m-ri-b-tier.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-b"
      ? Object.assign({}, r, { tierId: "A" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-b tierId pin fails closed" || bad "ri.tier-b tierId pin passed"
has "ri.tier-b tierId pin code" "$out" "E_RI_TIER_B"

# 26) ri.tier-c: preferred human-gate → cross-vendor (schema-valid, wrong)
mut_validate "m-ri-c-pref.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-c"
      ? Object.assign({}, r, { preferredRelationship: "cross-vendor" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-c preferred pin fails closed" || bad "ri.tier-c preferred pin passed"
has "ri.tier-c preferred pin code" "$out" "E_RI_TIER_C"

# 26b) ri.tier-c: humanGateId G12 → G1 (schema-valid gate, wrong pin)
mut_validate "m-ri-c-gate.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-c"
      ? Object.assign({}, r, { humanGateId: "G1" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-c humanGateId pin fails closed" || bad "ri.tier-c humanGateId pin passed"
has "ri.tier-c humanGateId pin code" "$out" "E_RI_TIER_C"

# 26c) ri.tier-c: tierId C → B
mut_validate "m-ri-c-tier.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-c"
      ? Object.assign({}, r, { tierId: "B" })
      : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-c tierId pin fails closed" || bad "ri.tier-c tierId pin passed"
has "ri.tier-c tierId pin code" "$out" "E_RI_TIER_C"

# ---------------------------------------------------------------------------
# RI exact presence/absence — schema-valid optional semantic fields forbidden
# for each id. Proven zero-error escapes: law5+tierId, tier-a+humanGateId,
# tier-b+generatorMustNotEqual, tier-c+generatorMustNotEqual.
# ---------------------------------------------------------------------------

# 27) ri.law5 must not carry tierId (schema-valid enum, forbidden for law5)
mut_validate "m-ri-law5-tier-absent.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.law5" ? Object.assign({}, r, { tierId: "C" }) : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.law5 forbids tierId" || bad "ri.law5 accepted tierId"
has "ri.law5 forbid tierId code" "$out" "E_RI_LAW5"

# 27b) ri.law5 must not carry humanGateId
mut_validate "m-ri-law5-gate-absent.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.law5" ? Object.assign({}, r, { humanGateId: "G12" }) : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.law5 forbids humanGateId" || bad "ri.law5 accepted humanGateId"
has "ri.law5 forbid humanGateId code" "$out" "E_RI_LAW5"

# 28) ri.tier-a must not carry humanGateId
mut_validate "m-ri-a-gate-absent.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-a" ? Object.assign({}, r, { humanGateId: "G12" }) : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-a forbids humanGateId" || bad "ri.tier-a accepted humanGateId"
has "ri.tier-a forbid humanGateId code" "$out" "E_RI_TIER_A"

# 28b) ri.tier-a must not carry generatorMustNotEqual
mut_validate "m-ri-a-gen-absent.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-a" ? Object.assign({}, r, { generatorMustNotEqual: "builder" }) : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-a forbids generatorMustNotEqual" || bad "ri.tier-a accepted generatorMustNotEqual"
has "ri.tier-a forbid generator code" "$out" "E_RI_TIER_A"

# 29) ri.tier-b must not carry generatorMustNotEqual
mut_validate "m-ri-b-gen-absent.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-b" ? Object.assign({}, r, { generatorMustNotEqual: "builder" }) : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-b forbids generatorMustNotEqual" || bad "ri.tier-b accepted generatorMustNotEqual"
has "ri.tier-b forbid generator code" "$out" "E_RI_TIER_B"

# 29b) ri.tier-b must not carry humanGateId
mut_validate "m-ri-b-gate-absent.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-b" ? Object.assign({}, r, { humanGateId: "G12" }) : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-b forbids humanGateId" || bad "ri.tier-b accepted humanGateId"
has "ri.tier-b forbid humanGateId code" "$out" "E_RI_TIER_B"

# 30) ri.tier-c must not carry generatorMustNotEqual
mut_validate "m-ri-c-gen-absent.json" '
  c.reviewIndependence = c.reviewIndependence.map(r =>
    r.id === "ri.tier-c" ? Object.assign({}, r, { generatorMustNotEqual: "builder" }) : r
  );
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "ri.tier-c forbids generatorMustNotEqual" || bad "ri.tier-c accepted generatorMustNotEqual"
has "ri.tier-c forbid generator code" "$out" "E_RI_TIER_C"

# ---------------------------------------------------------------------------
# --repo-root containment for manifest + schema reads
# ---------------------------------------------------------------------------

echo
echo "=== --repo-root containment (manifest + schema) ==="

# Absolute --manifest outside declared root must fail (not validate PASS)
ABS_OUTSIDE="$ROOT/outside-candidate.json"
cp "$CANDIDATE" "$ABS_OUTSIDE"
out=$(run_tool validate --manifest "$ABS_OUTSIDE" --repo-root "$MUT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "absolute manifest outside root refused" || bad "absolute manifest outside root accepted"
if echo "$out" | grep -Eqi 'absolute|refused|repo-root'; then
  ok "absolute manifest escape diagnosed"
else
  bad "absolute manifest escape missing diagnosis (out=$out)"
fi

# Absolute path that happens to lie under MUT still refused (boundary is explicit)
ABS_INSIDE="$MUT/m-abs-inside.json"
cp "$CANDIDATE" "$ABS_INSIDE"
out=$(run_tool validate --manifest "$ABS_INSIDE" --repo-root "$MUT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "absolute in-root manifest refused" || bad "absolute in-root manifest accepted"

# Manifest symlink escape: relative path whose realpath leaves --repo-root
OUTSIDE_FOR_MANIFEST="$ROOT/outside-manifest-secret"
mkdir -p "$OUTSIDE_FOR_MANIFEST"
cp "$CANDIDATE" "$OUTSIDE_FOR_MANIFEST/leaked-candidate.json"
ln -s "$OUTSIDE_FOR_MANIFEST/leaked-candidate.json" "$MUT/m-manifest-escape.json"
out=$(run_tool validate --manifest "m-manifest-escape.json" --repo-root "$MUT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "manifest symlink escape refused" || bad "manifest symlink escape accepted"
if echo "$out" | grep -Eqi 'realpath escapes|symlink|absolute|unsafe|refused'; then
  ok "manifest symlink escape diagnosed"
else
  bad "manifest symlink escape missing diagnosis (out=$out)"
fi

# Schema symlink escape: schema path under root realpaths outside
SCHEMA_ESCAPE_MINI="$ROOT/schema-escape-mini"
OUTSIDE_SCHEMA="$ROOT/outside-schema.json"
mkdir -p "$SCHEMA_ESCAPE_MINI/config/policy/schema" "$SCHEMA_ESCAPE_MINI/config/policy/candidates"
# Foreign schema bytes outside root
printf '%s\n' '{"type":"object"}' > "$OUTSIDE_SCHEMA"
ln -s "$OUTSIDE_SCHEMA" "$SCHEMA_ESCAPE_MINI/config/policy/schema/policy-manifest-v1.schema.json"
cp "$CANDIDATE" "$SCHEMA_ESCAPE_MINI/config/policy/candidates/gibson-core-v1.candidate.json"
out=$(run_tool validate --manifest "config/policy/candidates/gibson-core-v1.candidate.json" --repo-root "$SCHEMA_ESCAPE_MINI" --no-digest-check 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "schema symlink escape refused" || bad "schema symlink escape accepted"
if echo "$out" | grep -Eqi 'realpath escapes|symlink|schema|path:'; then
  ok "schema symlink escape diagnosed"
else
  bad "schema symlink escape missing diagnosis (out=$out)"
fi

# Legitimate relative in-root manifest + schema still PASS under sandbox
cp "$CANDIDATE" "$MUT/m-legit-inroot.json"
out=$(run_tool validate --manifest "m-legit-inroot.json" --repo-root "$MUT" --no-digest-check 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "legitimate in-root relative manifest+schema PASS" || bad "legitimate in-root refused (out=$out)"
has "legitimate in-root verdict" "$out" "verdict: PASS"

# ---------------------------------------------------------------------------
# Provenance path: segment-exact ".." only (a..b.md is schema-valid)
# ---------------------------------------------------------------------------

echo
echo "=== provenance path segment rules (a..b.md) ==="

# Positive: in-root file named a..b.md is accepted and digests
printf 'dotdot-name-ok\n' > "$MUT/docs/a..b.md"
out=$(run_tool digest --path "docs/a..b.md" --repo-root "$MUT" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "digest accepts docs/a..b.md" || bad "digest rejected docs/a..b.md (out=$out)"
DOTDOT_DIGEST=$(echo "$out" | awk '{print $1}')
if [[ ${#DOTDOT_DIGEST} -eq 64 ]]; then
  ok "docs/a..b.md produced sha256 digest"
else
  bad "docs/a..b.md digest shape wrong: $DOTDOT_DIGEST"
fi
# Full validate with provenance pointing at a..b.md
mut_validate "m-prov-dotdot-name.json" "
  c.provenance.sources = [{
    id: 'src.dotdot-name',
    path: 'docs/a..b.md',
    digestAlgorithm: 'sha256',
    digest: '$DOTDOT_DIGEST',
    role: 'supporting'
  }];
"
[[ "$rc" -eq 0 ]] && ok "validate accepts provenance path docs/a..b.md" || bad "validate rejected docs/a..b.md (out=$out)"

# Negative: exact ".." segment still rejected at path validation
mut_validate "m-prov-dotdot-seg.json" '
  c.provenance.sources = [{
    id: "src.traversal",
    path: "docs/../secret.md",
    digestAlgorithm: "sha256",
    digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    role: "supporting"
  }];
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "exact .. segment provenance path fails closed" || bad "exact .. segment accepted"
has "exact .. segment path code" "$out" "E_PROVENANCE_PATH"

# Negative: leading ../ traversal
mut_validate "m-prov-dotdot-lead.json" '
  c.provenance.sources = [{
    id: "src.lead",
    path: "../outside.md",
    digestAlgorithm: "sha256",
    digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    role: "supporting"
  }];
' --no-digest-check
[[ "$rc" -ne 0 ]] && ok "leading ../ provenance path fails closed" || bad "leading ../ accepted"

# 16) adversarial symlink escape: repo-relative symlink to outside must fail digest check
# Build a disposable mini-repo so we never touch the real checkout.
MINI="$ROOT/mini-repo"
OUTSIDE_FOR_LINK="$ROOT/outside-secret"
mkdir -p "$MINI/docs" "$MINI/config/policy/candidates" "$MINI/config/policy/schema" "$OUTSIDE_FOR_LINK"
# Schema must live inside the declared mini-repo root (containment).
cp "$SCHEMA" "$MINI/config/policy/schema/policy-manifest-v1.schema.json"
echo "secret-bytes-not-in-repo" > "$OUTSIDE_FOR_LINK/leaked.txt"
# Legitimate in-repo doctrine stubs so other fields can be valid if needed
printf '# gates\n**G1**\n' > "$MINI/docs/14-human-gates.md"
# Symlink that looks repo-relative but realpaths outside
ln -s "$OUTSIDE_FOR_LINK/leaked.txt" "$MINI/docs/escape-link.md"
# Candidate with a provenance path pointing at the symlink (relative write under MINI)
mutate_json "$CANDIDATE" "$MINI/config/policy/candidates/gibson-core-v1.candidate.json" '
  c.provenance.sources = [{
    id: "src.escape",
    path: "docs/escape-link.md",
    digestAlgorithm: "sha256",
    digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    role: "canonical-doctrine"
  }];
'
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

# Safe name with leading-dot segment that is NOT exact ".." (segment-exact only)
mkdir -p "$MUT/docs/..hidden"
printf 'hidden-ok\n' > "$MUT/docs/..hidden/x.md"
out=$(run_tool digest --path "docs/..hidden/x.md" --repo-root "$MUT" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "digest accepts docs/..hidden/x.md" || bad "digest rejected docs/..hidden/x.md (out=$out)"

# ---------------------------------------------------------------------------
# Deterministic injected path-swap (TOCTOU) — not timing-flaky
# Proves open → identity/containment bind fails closed when the path is
# switched after open and before acceptance; shared primitive covers all
# read classes (text / hash / json) used by digest, doctrine, schema, manifest.
# ---------------------------------------------------------------------------

echo
echo "=== deterministic injected path-swap (TOCTOU) ==="

SWAP_RC=0
# Paths via env (not argv): importing the tool module must not trip isMain()
# which treats process.argv[1] === tool path as a CLI invocation.
SWAP_OUT=$(
  PM_TOOL="$TOOL" PM_SCHEMA="$SCHEMA" PM_CANDIDATE="$CANDIDATE" \
  "$NODE" --input-type=module -e '
import {
  mkdirSync,
  writeFileSync,
  unlinkSync,
  symlinkSync,
  rmSync,
  cpSync,
} from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";

const toolPath = process.env.PM_TOOL;
const schemaSrc = process.env.PM_SCHEMA;
const candidateSrc = process.env.PM_CANDIDATE;
if (!toolPath || !schemaSrc || !candidateSrc) {
  console.log("SENSOR_BAD missing PM_TOOL/PM_SCHEMA/PM_CANDIDATE env");
  process.exit(1);
}

const {
  readContainedFile,
  sha256ContainedFile,
  setSafeReadAfterOpenHook,
  loadPolicySchema,
  clearPolicySchemaCache,
} = await import(pathToFileURL(toolPath).href);

let fail = 0;
function ok(m) { console.log("SENSOR_OK " + m); }
function bad(m) { console.log("SENSOR_BAD " + m); fail++; }

const root = join(tmpdir(), "gibson-pm-swap-" + process.pid + "-" + Date.now());
const outside = join(tmpdir(), "gibson-pm-outside-" + process.pid + "-" + Date.now());
try {
  mkdirSync(join(root, "docs"), { recursive: true });
  mkdirSync(join(root, "config/policy/schema"), { recursive: true });
  mkdirSync(join(root, "config/policy/candidates"), { recursive: true });
  mkdirSync(outside, { recursive: true });

  writeFileSync(join(root, "docs/inside.txt"), "INSIDE_BYTES_v1\n");
  writeFileSync(join(root, "docs/other.txt"), "OTHER_INSIDE\n");
  writeFileSync(join(outside, "leaked.txt"), "OUTSIDE_SECRET_BYTES\n");
  cpSync(schemaSrc, join(root, "config/policy/schema/policy-manifest-v1.schema.json"));
  cpSync(candidateSrc, join(root, "config/policy/candidates/gibson-core-v1.candidate.json"));
  // Doctrine stubs for representative doctrine-class read
  writeFileSync(join(root, "docs/14-human-gates.md"), "# gates\n**G1**\n");

  // Control: no hook → shared primitive accepts normal files
  setSafeReadAfterOpenHook(null);
  const text = readContainedFile(root, "docs/inside.txt", "utf8");
  if (text === "INSIDE_BYTES_v1\n") ok("control readContainedFile inside text");
  else bad("control readContainedFile wrong bytes");
  const dig = sha256ContainedFile(root, "docs/inside.txt");
  const expect = createHash("sha256").update("INSIDE_BYTES_v1\n").digest("hex");
  if (dig === expect) ok("control sha256ContainedFile");
  else bad("control sha256ContainedFile mismatch");
  try {
    loadPolicySchema(null, root);
    ok("control loadPolicySchema (json/schema class)");
  } catch (e) {
    bad("control loadPolicySchema failed: " + e.message);
  }
  try {
    const man = readContainedFile(
      root,
      "config/policy/candidates/gibson-core-v1.candidate.json",
      "utf8"
    );
    JSON.parse(man);
    ok("control manifest json class read");
  } catch (e) {
    bad("control manifest read failed: " + e.message);
  }
  try {
    const d = readContainedFile(root, "docs/14-human-gates.md", "utf8");
    if (d.includes("**G1**")) ok("control doctrine class read");
    else bad("control doctrine missing marker");
  } catch (e) {
    bad("control doctrine read failed: " + e.message);
  }

  // Injected swap A: after open, replace path with symlink to outside.
  // Fail closed on realpath escape; must not accept outside identity.
  setSafeReadAfterOpenHook(({ absPath }) => {
    try { unlinkSync(absPath); } catch { /* ignore */ }
    symlinkSync(join(outside, "leaked.txt"), absPath);
  });
  let threw = false;
  let msg = "";
  try {
    readContainedFile(root, "docs/inside.txt", "utf8");
  } catch (e) {
    threw = true;
    msg = e && e.message ? e.message : String(e);
  }
  setSafeReadAfterOpenHook(null);
  // Restore inside file for subsequent cases
  try { unlinkSync(join(root, "docs/inside.txt")); } catch { /* ignore */ }
  writeFileSync(join(root, "docs/inside.txt"), "INSIDE_BYTES_v1\n");

  if (threw && /realpath escapes|symlink|identity changed|swap or race/i.test(msg)) {
    ok("swap-to-outside fails closed (escape/identity)");
  } else if (threw) {
    bad("swap-to-outside threw unexpected: " + msg);
  } else {
    bad("swap-to-outside did not fail closed");
  }
  // Prove we did not return outside secret as a successful read (already threw)
  if (threw) ok("swap-to-outside did not return outside bytes as success");
  else bad("swap-to-outside returned success (would leak outside bytes)");

  // Injected swap B: after open, replace with different in-root file.
  // Opened fd identity must not match new realpath → fail closed.
  setSafeReadAfterOpenHook(({ absPath }) => {
    try { unlinkSync(absPath); } catch { /* ignore */ }
    // hard-link alternative: copy other file into place (new inode)
    writeFileSync(absPath, "OTHER_INSIDE\n");
  });
  threw = false;
  msg = "";
  try {
    const leaked = readContainedFile(root, "docs/inside.txt", "utf8");
    // If somehow succeeds, must not be the swapped-in content from a new inode
    // without identity bind — success here is a defect.
    if (leaked === "OTHER_INSIDE\n") {
      bad("swap-to-other-inside accepted replacement bytes");
    } else {
      bad("swap-to-other-inside succeeded unexpectedly with: " + JSON.stringify(leaked));
    }
  } catch (e) {
    threw = true;
    msg = e && e.message ? e.message : String(e);
  }
  setSafeReadAfterOpenHook(null);
  try { unlinkSync(join(root, "docs/inside.txt")); } catch { /* ignore */ }
  writeFileSync(join(root, "docs/inside.txt"), "INSIDE_BYTES_v1\n");

  if (threw && /identity changed|swap or race|realpath escapes/i.test(msg)) {
    ok("swap-to-other-inside fails closed (identity bind)");
  } else if (threw) {
    bad("swap-to-other-inside threw unexpected: " + msg);
  } else {
    bad("swap-to-other-inside did not fail closed");
  }

  // Same shared primitive via hash path (digest class)
  setSafeReadAfterOpenHook(({ absPath }) => {
    try { unlinkSync(absPath); } catch { /* ignore */ }
    symlinkSync(join(outside, "leaked.txt"), absPath);
  });
  threw = false;
  msg = "";
  try {
    sha256ContainedFile(root, "docs/inside.txt");
  } catch (e) {
    threw = true;
    msg = e && e.message ? e.message : String(e);
  }
  setSafeReadAfterOpenHook(null);
  try { unlinkSync(join(root, "docs/inside.txt")); } catch { /* ignore */ }
  writeFileSync(join(root, "docs/inside.txt"), "INSIDE_BYTES_v1\n");
  if (threw && /realpath escapes|symlink|identity changed|swap or race/i.test(msg)) {
    ok("digest-class sha256ContainedFile swap fails closed");
  } else {
    bad("digest-class swap not diagnosed (threw=" + threw + " msg=" + msg + ")");
  }

  // Schema-class swap via loadPolicySchema (json under DEFAULT_SCHEMA_REL).
  // Clear cache so the open+identity path runs again (control already filled it).
  clearPolicySchemaCache();
  const schemaRel = "config/policy/schema/policy-manifest-v1.schema.json";
  setSafeReadAfterOpenHook(({ relPath, absPath }) => {
    if (relPath === schemaRel || /policy-manifest-v1\.schema\.json$/.test(absPath)) {
      try { unlinkSync(absPath); } catch { /* ignore */ }
      symlinkSync(join(outside, "leaked.txt"), absPath);
    }
  });
  threw = false;
  msg = "";
  try {
    loadPolicySchema(null, root);
  } catch (e) {
    threw = true;
    msg = e && e.message ? e.message : String(e);
  }
  setSafeReadAfterOpenHook(null);
  clearPolicySchemaCache();
  try { unlinkSync(join(root, schemaRel)); } catch { /* ignore */ }
  cpSync(schemaSrc, join(root, schemaRel));
  if (threw && /realpath escapes|symlink|identity changed|swap or race|schema/i.test(msg)) {
    ok("schema-class loadPolicySchema swap fails closed");
  } else {
    bad("schema-class swap not diagnosed (threw=" + threw + " msg=" + msg + ")");
  }

  // Manifest-class: readContainedFile on candidate path with swap
  const manRel = "config/policy/candidates/gibson-core-v1.candidate.json";
  setSafeReadAfterOpenHook(({ absPath }) => {
    try { unlinkSync(absPath); } catch { /* ignore */ }
    symlinkSync(join(outside, "leaked.txt"), absPath);
  });
  threw = false;
  msg = "";
  try {
    readContainedFile(root, manRel, "utf8");
  } catch (e) {
    threw = true;
    msg = e && e.message ? e.message : String(e);
  }
  setSafeReadAfterOpenHook(null);
  try { unlinkSync(join(root, manRel)); } catch { /* ignore */ }
  cpSync(candidateSrc, join(root, manRel));
  if (threw && /realpath escapes|symlink|identity changed|swap or race/i.test(msg)) {
    ok("manifest-class readContainedFile swap fails closed");
  } else {
    bad("manifest-class swap not diagnosed (threw=" + threw + " msg=" + msg + ")");
  }

  // Representative CLI path: digest command must also fail closed on static escape
  // (end-to-end already covered elsewhere; here prove hook is cleared and normal ok)
  setSafeReadAfterOpenHook(null);
  try {
    sha256ContainedFile(root, "docs/inside.txt");
    ok("post-swap hook cleared; normal hash works");
  } catch (e) {
    bad("post-swap normal hash failed: " + e.message);
  }
} finally {
  setSafeReadAfterOpenHook(null);
  try { rmSync(root, { recursive: true, force: true }); } catch { /* ignore */ }
  try { rmSync(outside, { recursive: true, force: true }); } catch { /* ignore */ }
}
process.exit(fail === 0 ? 0 : 1);
' 2>&1) || SWAP_RC=$?

# Map SENSOR_OK / SENSOR_BAD lines into suite tally
while IFS= read -r line; do
  case "$line" in
    SENSOR_OK\ *) ok "${line#SENSOR_OK }" ;;
    SENSOR_BAD\ *) bad "${line#SENSOR_BAD }" ;;
    *) ;; # ignore node warnings / noise
  esac
done <<< "$SWAP_OUT"
if [[ "$SWAP_RC" -ne 0 ]] && ! echo "$SWAP_OUT" | grep -q "SENSOR_BAD "; then
  bad "injected-swap sensor exited non-zero without SENSOR_BAD (out=$SWAP_OUT)"
fi

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
