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

# Temporary root: fail immediately unless mktemp -d succeeds with a nonempty
# existing directory. Check BEFORE installing traps or constructing/writing any
# child paths — a failed/empty ROOT would otherwise resolve hostile stubs toward
# /bin, $HOME, or the repository.
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-policy-manifest.XXXXXX") || {
  echo "policy-manifest.test.sh: mktemp -d failed; refusing to continue" >&2
  exit 1
}
if [[ -z "${ROOT}" || ! -d "${ROOT}" ]]; then
  echo "policy-manifest.test.sh: mktemp -d did not return an existing directory; refusing to continue" >&2
  exit 1
fi
# Only after a validated temporary root: install cleanup and write child paths.
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
# Deterministic injected path-swap (TOCTOU) + integrity / FIFO / root-swap
# Proves open → BigInt identity/containment bind fails closed when the path is
# switched after open; higher-level manifest load + doctrine consistency;
# root-swap cannot poison schema; FIFO rejects promptly; sensor receipts are
# exact (unique set + count + terminal sentinel grammar).
# ---------------------------------------------------------------------------

echo
echo "=== deterministic injected path-swap (TOCTOU) + integrity ==="

# Exact unique receipt set the production sensor must emit (one each).
# SENSOR_DONE N is required as the terminal physical line with N == receipt count.
EXPECTED_SWAP_RECEIPTS="control readContainedFile inside text
control sha256ContainedFile
control loadPolicySchema (json/schema class)
control loadManifestCandidate (higher-level)
control checkDoctrineConsistency (higher-level)
bigint identity on production open path
bigint identity comparator rejects Number-colliding values
swap-to-outside fails closed (escape/identity)
swap-to-outside did not return outside bytes as success
swap-to-other-inside fails closed (identity bind)
digest-class sha256ContainedFile swap fails closed
schema-class loadPolicySchema swap fails closed
manifest-class loadManifestCandidate swap fails closed
doctrine-class checkDoctrineConsistency swap fails closed
root directory replacement within operation fails closed
root-swap schema re-read (no cache poison)
post-swap hook cleared; normal hash works
fifo rejected promptly as non-regular"

# Strict receipt grammar over a **raw byte file** (never a Bash variable):
# Bash command substitution strips NUL, so capture must be file/stream first.
#   1) Raw byte gate: only printable ASCII 0x20-0x7E and LF (0x0A).
#      Reject NUL, ESC/ANSI, CR, other C0/C1, high/invalid bytes, empty lines.
#   2) Line grammar:
#        ^SENSOR_OK <id>$
#        ^SENSOR_BAD <msg>$
#        ^SENSOR_DONE <uint>$
#      Final physical line must be exactly SENSOR_DONE <expected_count>;
#      exactly one SENSOR_OK per expected id; no SENSOR_BAD on success;
#      no early sentinel / trailing junk / duplicates / truncation.
tally_sensor_receipts_file() {
  local raw_file="$1"
  local expected_count
  expected_count=$(printf '%s\n' "$EXPECTED_SWAP_RECEIPTS" | grep -c . || true)
  local lines_file="$ROOT/sensor-receipt-lines.txt"
  local raw_err="$ROOT/sensor-raw-err.txt"
  local byte_rc=0
  local line_n=0
  local ok_lines=0
  local bad_lines=0
  local done_lines=0
  local last_line=""
  local seen_oks=""

  if [[ ! -f "$raw_file" ]]; then
    bad "sensor raw receipt file missing"
    return 0
  fi

  # Step 1: validate raw bytes from the file (Buffer — preserves NUL for reject).
  "$NODE" -e '
    const fs = require("fs");
    const rawPath = process.argv[1];
    const outPath = process.argv[2];
    const buf = fs.readFileSync(rawPath);
    if (buf.length === 0) {
      process.stderr.write("SENSOR_RAW_EMPTY\n");
      process.exit(3);
    }
    for (let i = 0; i < buf.length; i++) {
      const b = buf[i];
      // Permit only LF line separators and printable ASCII receipt charset.
      // Reject NUL (0x00), CR (0x0D), ESC (0x1B), other C0/C1, and high bytes.
      if (b === 0x0a) continue;
      if (b >= 0x20 && b <= 0x7e) continue;
      process.stderr.write("SENSOR_RAW_BAD_BYTE offset=" + i + " byte=" + b + "\n");
      process.exit(2);
    }
    const text = buf.toString("latin1");
    const endsWithLf = buf[buf.length - 1] === 0x0a;
    let lines = text.split("\n");
    if (endsWithLf) lines = lines.slice(0, -1);
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].length === 0) {
        process.stderr.write("SENSOR_RAW_EMPTY_LINE index=" + (i + 1) + "\n");
        process.exit(4);
      }
    }
    fs.writeFileSync(outPath, lines.length ? lines.join("\n") + "\n" : "");
    process.exit(0);
  ' "$raw_file" "$lines_file" 2>"$raw_err" || byte_rc=$?

  if [[ "$byte_rc" -ne 0 ]]; then
    local err_snip
    err_snip=$(tr "\n" " " < "$raw_err" 2>/dev/null | head -c 200)
    bad "sensor raw byte/line reject (rc=$byte_rc $err_snip)"
    return 0
  fi

  if [[ ! -s "$lines_file" ]]; then
    bad "sensor blank output (no receipts)"
    return 0
  fi

  # Step 2: grammar parse on validated printable lines (NULs already refused).
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_n=$((line_n + 1))
    last_line="$line"
    if [[ -z "$line" ]]; then
      bad "sensor empty physical line at index $line_n"
      continue
    fi
    case "$line" in
      SENSOR_OK\ *)
        if [[ "$line" != SENSOR_OK\ * || "$line" == "SENSOR_OK " ]]; then
          bad "sensor SENSOR_OK grammar reject: $(printf '%q' "$line")"
          continue
        fi
        ok_lines=$((ok_lines + 1))
        local body="${line#SENSOR_OK }"
        if printf '%s\n' "$seen_oks" | grep -qxF -- "$body"; then
          bad "sensor duplicate receipt: $body"
        else
          seen_oks="${seen_oks}${body}"$'\n'
        fi
        if ! printf '%s\n' "$EXPECTED_SWAP_RECEIPTS" | grep -qxF -- "$body"; then
          bad "sensor unexpected receipt: $body"
        fi
        ;;
      SENSOR_BAD\ *)
        if [[ "$line" == "SENSOR_BAD " || "$line" == "SENSOR_BAD" ]]; then
          bad "sensor SENSOR_BAD grammar reject: $(printf '%q' "$line")"
          continue
        fi
        bad_lines=$((bad_lines + 1))
        bad "${line#SENSOR_BAD }"
        ;;
      SENSOR_DONE\ *)
        local done_rest="${line#SENSOR_DONE }"
        if [[ "$line" != "SENSOR_DONE $done_rest" || ! "$done_rest" =~ ^[0-9]+$ ]]; then
          bad "sensor SENSOR_DONE grammar reject: $(printf '%q' "$line")"
          continue
        fi
        done_lines=$((done_lines + 1))
        ;;
      *)
        bad "sensor unexpected line (strict grammar): $(printf '%q' "$line")"
        ;;
    esac
  done < "$lines_file"

  if [[ "$last_line" != "SENSOR_DONE $expected_count" ]]; then
    bad "sensor final line want 'SENSOR_DONE $expected_count' got $(printf '%q' "$last_line")"
  else
    ok "sensor final line SENSOR_DONE $expected_count"
  fi

  if [[ "$done_lines" -ne 1 ]]; then
    bad "sensor SENSOR_DONE count want 1 got $done_lines (early sentinel or missing)"
  fi

  while IFS= read -r exp; do
    [[ -z "$exp" ]] && continue
    local n
    n=$(grep -cxF "SENSOR_OK $exp" "$lines_file" || true)
    if [[ "$n" -eq 0 ]]; then
      bad "sensor missing receipt: $exp"
    elif [[ "$n" -gt 1 ]]; then
      bad "sensor duplicate receipt: $exp (count=$n)"
    else
      ok "$exp"
    fi
  done <<< "$EXPECTED_SWAP_RECEIPTS"

  if [[ "$ok_lines" -ne "$expected_count" ]]; then
    bad "sensor SENSOR_OK count want $expected_count got $ok_lines"
  else
    ok "sensor SENSOR_OK exact count $expected_count"
  fi

  if [[ "$bad_lines" -ne 0 ]]; then
    bad "sensor SENSOR_BAD present (count=$bad_lines)"
  fi
}

# --- aggregator mutation checks (blank / partial / duplicate / missing /
# early sentinel / trailing junk / ANSI / NUL prefix / truncation) ---
echo
echo "=== sensor aggregator integrity mutations ==="
# Production path only: write payload bytes to a raw file, then tally that file.
# Never pass hostile bytes through a Bash variable (NUL would be stripped).
agg_mut_check_file() {
  local name="$1"
  local raw_file="$2"
  local before_fail=$FAIL
  local before_pass=$PASS
  tally_sensor_receipts_file "$raw_file" >/dev/null 2>&1 || true
  if [[ "$FAIL" -gt "$before_fail" ]]; then
    FAIL=$before_fail
    PASS=$before_pass
    ok "aggregator rejects $name"
  else
    FAIL=$before_fail
    PASS=$before_pass
    bad "aggregator accepted $name (should fail)"
  fi
}

# Write a text payload to a raw file and run the production tally path.
agg_mut_check() {
  local name="$1"
  local payload="$2"
  local f="$ROOT/agg-mut.raw"
  if [[ -z "$payload" ]]; then
    : > "$f"
  else
    # printf %s preserves content already in the shell string (no NUL expected here).
    printf '%s\n' "$payload" > "$f"
  fi
  agg_mut_check_file "$name" "$f"
}

_build_full_ok_body() {
  printf '%s\n' "$EXPECTED_SWAP_RECEIPTS" | while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    printf 'SENSOR_OK %s\n' "$r"
  done
}
_EXPECTED_COUNT=$(printf '%s\n' "$EXPECTED_SWAP_RECEIPTS" | grep -c . || true)
_full_ok=$(_build_full_ok_body)

agg_mut_check "blank output" ""
agg_mut_check "partial receipts" "$(printf '%s\n' "SENSOR_OK control readContainedFile inside text" "SENSOR_DONE 1")"
agg_mut_check "duplicate receipt" "$(printf '%s\n' "SENSOR_OK control readContainedFile inside text" "SENSOR_OK control readContainedFile inside text" "SENSOR_DONE 1")"
agg_mut_check "missing sentinel" "$_full_ok"
agg_mut_check "early sentinel" "$(printf '%s\n' "SENSOR_DONE $_EXPECTED_COUNT" "$_full_ok" "SENSOR_DONE $_EXPECTED_COUNT")"
agg_mut_check "trailing junk" "$(printf '%s\n' "$_full_ok" "SENSOR_DONE $_EXPECTED_COUNT" "TRAILING_JUNK")"
# ANSI/control-prefixed "duplicate"/BAD must not be sanitized into valid receipts
agg_mut_check "ANSI-prefixed SENSOR_OK" "$(printf '%s\n' $'\033[32mSENSOR_OK control readContainedFile inside text' "SENSOR_DONE 1")"
agg_mut_check "ANSI-prefixed SENSOR_BAD" "$(printf '%s\n' $'\033[31mSENSOR_BAD hostile' "SENSOR_DONE 0")"
# Truncation: full OKs but cut off before complete SENSOR_DONE line
agg_mut_check "truncation before DONE" "$(printf '%s\n' "$_full_ok" "SENSOR_DO")"
agg_mut_check "truncation mid-count" "$(printf '%s\n' "$_full_ok" "SENSOR_DONE")"
# NUL-prefixed *otherwise complete and valid* stream must fail at raw-byte gate.
# Write via printf to a file — Bash variables would strip the NUL.
_NUL_RAW="$ROOT/sensor-nul-prefixed.raw"
{
  printf '\0'
  printf '%s\n' "$_full_ok"
  printf 'SENSOR_DONE %s\n' "$_EXPECTED_COUNT"
} > "$_NUL_RAW"
agg_mut_check_file "NUL-prefixed complete stream" "$_NUL_RAW"
# CR and other C0 controls similarly fail closed on the raw path.
_CR_RAW="$ROOT/sensor-cr-prefixed.raw"
{
  printf '\r'
  printf '%s\n' "$_full_ok"
  printf 'SENSOR_DONE %s\n' "$_EXPECTED_COUNT"
} > "$_CR_RAW"
agg_mut_check_file "CR-prefixed complete stream" "$_CR_RAW"
unset _full_ok _EXPECTED_COUNT _NUL_RAW _CR_RAW

# Static proof: production path is file-based (raw capture), not a shell variable.
if grep -q 'tally_sensor_receipts_file' "$SCRIPT_DIR/policy-manifest.test.sh" && \
   grep -q 'SENSOR_RAW_BAD_BYTE' "$SCRIPT_DIR/policy-manifest.test.sh" && \
   grep -q 'SWAP_RAW=' "$SCRIPT_DIR/policy-manifest.test.sh" && \
   ! grep -E '^[[:space:]]*SWAP_OUT=' "$SCRIPT_DIR/policy-manifest.test.sh"; then
  ok "sensor capture uses raw file path (not shell variable)"
else
  bad "sensor capture still uses shell variable or missing raw-byte gate"
fi

SWAP_RC=0
SWAP_RAW="$ROOT/sensor-swap-receipts.raw"
: > "$SWAP_RAW"
# Paths via env (not argv): importing the tool module must not trip isMain()
# which treats process.argv[1] === tool path as a CLI invocation.
# Capture to a raw byte file — never a Bash variable (NUL-preserving).
PM_TOOL="$TOOL" PM_SCHEMA="$SCHEMA" PM_CANDIDATE="$CANDIDATE" \
  "$NODE" --input-type=module -e '
import {
  mkdirSync,
  writeFileSync,
  unlinkSync,
  symlinkSync,
  rmSync,
  cpSync,
  renameSync,
} from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";

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
  setRootIdentityRecheckHook,
  loadPolicySchema,
  clearPolicySchemaCache,
  loadManifestCandidate,
  checkDoctrineConsistency,
  resolveCanonicalRepoRoot,
  rootIdentitiesEqual,
  assertRootIdentity,
} = await import(pathToFileURL(toolPath).href);

let fail = 0;
let okCount = 0;
function ok(m) { console.log("SENSOR_OK " + m); okCount++; }
function bad(m) { console.log("SENSOR_BAD " + m); fail++; }

const root = join(tmpdir(), "gibson-pm-swap-" + process.pid + "-" + Date.now());
const outside = join(tmpdir(), "gibson-pm-outside-" + process.pid + "-" + Date.now());
const rootA = join(tmpdir(), "gibson-pm-rootA-" + process.pid + "-" + Date.now());
const rootB = join(tmpdir(), "gibson-pm-rootB-" + process.pid + "-" + Date.now());
const rootLink = join(tmpdir(), "gibson-pm-rootLink-" + process.pid + "-" + Date.now());

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
  // Minimal doctrine markers so checkDoctrineConsistency can parse (or report)
  writeFileSync(join(root, "docs/14-human-gates.md"), "# gates\n**G1**\n");
  writeFileSync(join(root, "docs/03-roles.md"), "## planner\n");
  writeFileSync(join(root, "docs/06-quality-gates.md"), "## Risk tiers\n**A**\n**B**\n**C**\n");
  writeFileSync(join(root, "docs/02-sdlc-pipeline.md"), "## Stage 0 — Plan\n");

  // Control: no hook → shared primitive accepts normal files
  setSafeReadAfterOpenHook(null);
  clearPolicySchemaCache();
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
  // Higher-level manifest load path (not bare readContainedFile)
  try {
    const man = loadManifestCandidate(
      root,
      "config/policy/candidates/gibson-core-v1.candidate.json"
    );
    if (man && typeof man === "object" && man.schemaId) {
      ok("control loadManifestCandidate (higher-level)");
    } else {
      bad("control loadManifestCandidate missing schemaId");
    }
  } catch (e) {
    bad("control loadManifestCandidate failed: " + e.message);
  }
  // Higher-level doctrine consistency path
  try {
    const cand = loadManifestCandidate(
      root,
      "config/policy/candidates/gibson-core-v1.candidate.json"
    );
    const findings = checkDoctrineConsistency(cand, root);
    if (Array.isArray(findings)) {
      ok("control checkDoctrineConsistency (higher-level)");
    } else {
      bad("control checkDoctrineConsistency non-array");
    }
  } catch (e) {
    bad("control checkDoctrineConsistency failed: " + e.message);
  }

  // BigInt identity: production open path must surface bigint dev/ino
  let sawBigInt = false;
  setSafeReadAfterOpenHook(({ openedDev, openedIno }) => {
    if (typeof openedDev === "bigint" && typeof openedIno === "bigint") {
      sawBigInt = true;
    } else {
      throw new Error(
        "identity: expected bigint dev/ino, got " +
          typeof openedDev +
          "/" +
          typeof openedIno
      );
    }
  });
  try {
    readContainedFile(root, "docs/inside.txt", "utf8");
    if (sawBigInt) ok("bigint identity on production open path");
    else bad("bigint identity hook did not observe BigInt stats");
  } catch (e) {
    bad("bigint identity path failed: " + (e && e.message ? e.message : e));
  }
  setSafeReadAfterOpenHook(null);

  // Behavioral BigInt comparator: two distinct identities above 2^53 that
  // collide when coerced through Number must NOT compare equal. Lossy
  // Number(dev)===Number(dev) would falsely accept a replacement root.
  {
    const hi1 = BigInt(Number.MAX_SAFE_INTEGER) + 1n; // 2^53
    const hi2 = BigInt(Number.MAX_SAFE_INTEGER) + 2n; // 2^53+1
    // Sanity: Number rounds both into the same float neighborhood.
    const numberCollides =
      Number(hi1) === Number(hi2) ||
      Number(hi1) === Number(hi1 + 1n);
    const a = { dev: hi1, ino: hi1 };
    const b = { dev: hi2, ino: hi2 };
    const same = { dev: hi1, ino: hi1 };
    const eqAB = rootIdentitiesEqual(a, b);
    const eqAA = rootIdentitiesEqual(a, same);
    const lossyWouldMatch = Number(a.dev) === Number(b.dev) && Number(a.ino) === Number(b.ino);
    if (
      typeof a.dev === "bigint" &&
      eqAA === true &&
      eqAB === false &&
      lossyWouldMatch === true &&
      numberCollides
    ) {
      ok("bigint identity comparator rejects Number-colliding values");
    } else {
      bad(
        "bigint comparator behavior unexpected: " +
          JSON.stringify({
            eqAA,
            eqAB,
            lossyWouldMatch,
            numberCollides,
            n1: Number(hi1),
            n2: Number(hi2),
          })
      );
    }
  }

  // Injected swap A: after open, replace path with symlink to outside.
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
  try { unlinkSync(join(root, "docs/inside.txt")); } catch { /* ignore */ }
  writeFileSync(join(root, "docs/inside.txt"), "INSIDE_BYTES_v1\n");

  if (threw && /realpath escapes|symlink|identity changed|swap or race/i.test(msg)) {
    ok("swap-to-outside fails closed (escape/identity)");
  } else if (threw) {
    bad("swap-to-outside threw unexpected: " + msg);
  } else {
    bad("swap-to-outside did not fail closed");
  }
  if (threw) ok("swap-to-outside did not return outside bytes as success");
  else bad("swap-to-outside returned success (would leak outside bytes)");

  // Injected swap B: after open, replace with different in-root file.
  setSafeReadAfterOpenHook(({ absPath }) => {
    try { unlinkSync(absPath); } catch { /* ignore */ }
    writeFileSync(absPath, "OTHER_INSIDE\n");
  });
  threw = false;
  msg = "";
  try {
    const leaked = readContainedFile(root, "docs/inside.txt", "utf8");
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

  // Digest-class swap
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

  // Schema-class swap via loadPolicySchema
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
  if (threw && /realpath escapes|symlink|identity changed|swap or race|schema|cannot read/i.test(msg)) {
    ok("schema-class loadPolicySchema swap fails closed");
  } else {
    bad("schema-class swap not diagnosed (threw=" + threw + " msg=" + msg + ")");
  }

  // Higher-level manifest load path with swap
  const manRel = "config/policy/candidates/gibson-core-v1.candidate.json";
  setSafeReadAfterOpenHook(({ absPath, relPath }) => {
    if (relPath === manRel || /gibson-core-v1\.candidate\.json$/.test(absPath)) {
      try { unlinkSync(absPath); } catch { /* ignore */ }
      symlinkSync(join(outside, "leaked.txt"), absPath);
    }
  });
  threw = false;
  msg = "";
  try {
    loadManifestCandidate(root, manRel);
  } catch (e) {
    threw = true;
    msg = e && e.message ? e.message : String(e);
  }
  setSafeReadAfterOpenHook(null);
  try { unlinkSync(join(root, manRel)); } catch { /* ignore */ }
  cpSync(candidateSrc, join(root, manRel));
  if (threw && /realpath escapes|symlink|identity changed|swap or race|cannot read/i.test(msg)) {
    ok("manifest-class loadManifestCandidate swap fails closed");
  } else {
    bad("manifest-class swap not diagnosed (threw=" + threw + " msg=" + msg + ")");
  }

  // Doctrine-class: checkDoctrineConsistency with swap on a doctrine path
  setSafeReadAfterOpenHook(({ absPath, relPath }) => {
    if (relPath === "docs/14-human-gates.md" || /14-human-gates\.md$/.test(absPath)) {
      try { unlinkSync(absPath); } catch { /* ignore */ }
      symlinkSync(join(outside, "leaked.txt"), absPath);
    }
  });
  threw = false;
  msg = "";
  try {
    const cand = loadManifestCandidate(root, manRel);
    // loadManifest may succeed; consistency should surface escape as findings or throw
    const findings = checkDoctrineConsistency(cand, root);
    const hasEscape = findings.some(
      (f) =>
        f.severity === "error" &&
        /realpath escapes|symlink|identity changed|swap or race|cannot read|E_CONSISTENCY_READ/i.test(
          String(f.message) + " " + String(f.code)
        )
    );
    if (hasEscape) {
      ok("doctrine-class checkDoctrineConsistency swap fails closed");
    } else {
      bad(
        "doctrine-class swap not in findings: " +
          JSON.stringify(findings.map((f) => f.code + ":" + f.message))
      );
    }
  } catch (e) {
    threw = true;
    msg = e && e.message ? e.message : String(e);
    if (/realpath escapes|symlink|identity changed|swap or race|cannot read/i.test(msg)) {
      ok("doctrine-class checkDoctrineConsistency swap fails closed");
    } else {
      bad("doctrine-class swap threw unexpected: " + msg);
    }
  }
  setSafeReadAfterOpenHook(null);
  try { unlinkSync(join(root, "docs/14-human-gates.md")); } catch { /* ignore */ }
  writeFileSync(join(root, "docs/14-human-gates.md"), "# gates\n**G1**\n");

  // Root directory replacement WITHIN one multi-file operation: freeze a
  // RootIdentity, then rename/replace the actual directory between reads of
  // checkDoctrineConsistency. Prior symlink-swap between independent calls is
  // insufficient — this proves the frozen token is re-asserted per read.
  {
    const liveRoot = join(tmpdir(), "gibson-pm-rootlive-" + process.pid + "-" + Date.now());
    const liveMoved = liveRoot + ".moved-aside";
    const liveReplacement = liveRoot + ".replacement-staging";
    try {
      mkdirSync(join(liveRoot, "docs"), { recursive: true });
      mkdirSync(join(liveRoot, "config/policy/schema"), { recursive: true });
      mkdirSync(join(liveRoot, "config/policy/candidates"), { recursive: true });
      writeFileSync(join(liveRoot, "docs/14-human-gates.md"), "# gates\n**G1**\n**G2**\n");
      writeFileSync(join(liveRoot, "docs/03-roles.md"), "## planner\n");
      writeFileSync(join(liveRoot, "docs/06-quality-gates.md"), "## Risk tiers\n**A**\n**B**\n**C**\n");
      writeFileSync(join(liveRoot, "docs/02-sdlc-pipeline.md"), "## Stage 0 — Plan\n");
      cpSync(schemaSrc, join(liveRoot, "config/policy/schema/policy-manifest-v1.schema.json"));
      cpSync(candidateSrc, join(liveRoot, "config/policy/candidates/gibson-core-v1.candidate.json"));

      const frozen = resolveCanonicalRepoRoot(liveRoot);
      // Build a hostile replacement directory with different inode at same path.
      mkdirSync(join(liveReplacement, "docs"), { recursive: true });
      mkdirSync(join(liveReplacement, "config/policy/schema"), { recursive: true });
      mkdirSync(join(liveReplacement, "config/policy/candidates"), { recursive: true });
      writeFileSync(join(liveReplacement, "docs/14-human-gates.md"), "# REPLACED\n**G1**\n");
      writeFileSync(join(liveReplacement, "docs/03-roles.md"), "## planner\n");
      writeFileSync(join(liveReplacement, "docs/06-quality-gates.md"), "## Risk tiers\n**A**\n");
      writeFileSync(join(liveReplacement, "docs/02-sdlc-pipeline.md"), "## Stage 0 — Plan\n");
      cpSync(schemaSrc, join(liveReplacement, "config/policy/schema/policy-manifest-v1.schema.json"));
      cpSync(candidateSrc, join(liveReplacement, "config/policy/candidates/gibson-core-v1.candidate.json"));

      // Load candidate first without replacement so the multi-file op under
      // test is checkDoctrineConsistency itself (not the prior manifest load).
      const cand = loadManifestCandidate(
        frozen,
        "config/policy/candidates/gibson-core-v1.candidate.json"
      );

      let opensSeen = 0;
      let replaced = false;
      setSafeReadAfterOpenHook(() => {
        opensSeen += 1;
      });
      setRootIdentityRecheckHook((rootId) => {
        // After the first doctrine open inside this operation, replace the
        // canonical directory at the frozen pathname with a different inode.
        if (opensSeen < 1 || replaced) return;
        if (rootId.path !== frozen.path) return;
        replaced = true;
        try {
          renameSync(rootId.path, liveMoved);
          renameSync(liveReplacement, rootId.path);
        } catch (e) {
          throw new Error("test root replace setup failed: " + e.message);
        }
      });

      let refused = false;
      let refuseMsg = "";
      try {
        const findings = checkDoctrineConsistency(cand, frozen);
        const hasRootFail = findings.some(
          (f) =>
            f.severity === "error" &&
            /repo root identity changed|repo root disappeared|repo root path no longer canonical|cannot read|cannot bind|identity changed|swap or race/i.test(
              String(f.message) + " " + String(f.code)
            )
        );
        if (hasRootFail) {
          refused = true;
          refuseMsg = "findings";
        } else {
          refuseMsg =
            "no root-identity finding: " +
            JSON.stringify(findings.map((f) => f.code + ":" + f.message));
        }
      } catch (e) {
        refuseMsg = e && e.message ? e.message : String(e);
        if (
          /repo root identity changed|repo root disappeared|repo root path no longer canonical|cannot read|cannot bind|identity changed|swap or race/i.test(
            refuseMsg
          )
        ) {
          refused = true;
        }
      }
      setRootIdentityRecheckHook(null);
      setSafeReadAfterOpenHook(null);

      // Frozen token must still refuse the live path (replacement inode).
      let directRefuse = false;
      try {
        assertRootIdentity(frozen);
      } catch (e) {
        if (
          /repo root identity changed|repo root disappeared|no longer canonical/i.test(
            e && e.message ? e.message : String(e)
          )
        ) {
          directRefuse = true;
        }
      }

      if (refused && replaced && directRefuse) {
        ok("root directory replacement within operation fails closed");
      } else {
        bad(
          "root directory replacement not refused: " +
            JSON.stringify({ refused, replaced, directRefuse, refuseMsg, opensSeen })
        );
      }
    } finally {
      setRootIdentityRecheckHook(null);
      setSafeReadAfterOpenHook(null);
      try { rmSync(liveRoot, { recursive: true, force: true }); } catch { /* ignore */ }
      try { rmSync(liveMoved, { recursive: true, force: true }); } catch { /* ignore */ }
      try { rmSync(liveReplacement, { recursive: true, force: true }); } catch { /* ignore */ }
    }
  }

  // Root-swap / no cache poison: symlink root → A, load; retarget → B, load must
  // see B; retarget → A, load must see A again (never sticky B under A identity).
  function writeMiniRoot(dir, marker) {
    mkdirSync(join(dir, "config/policy/schema"), { recursive: true });
    mkdirSync(join(dir, "config/policy/candidates"), { recursive: true });
    // Minimal schema object; marker in a custom top-level field is fine for load-only
    const schema = {
      $schema: "https://json-schema.org/draft/2020-12/schema",
      type: "object",
      title: marker,
    };
    writeFileSync(
      join(dir, "config/policy/schema/policy-manifest-v1.schema.json"),
      JSON.stringify(schema) + "\n"
    );
  }
  writeMiniRoot(rootA, "SCHEMA_ROOT_A");
  writeMiniRoot(rootB, "SCHEMA_ROOT_B");
  try { unlinkSync(rootLink); } catch { /* ignore */ }
  symlinkSync(rootA, rootLink);
  clearPolicySchemaCache();
  let s1;
  try {
    s1 = loadPolicySchema(null, rootLink);
  } catch (e) {
    bad("root-swap load A failed: " + e.message);
    s1 = null;
  }
  try { unlinkSync(rootLink); } catch { /* ignore */ }
  symlinkSync(rootB, rootLink);
  clearPolicySchemaCache();
  let s2;
  try {
    s2 = loadPolicySchema(null, rootLink);
  } catch (e) {
    bad("root-swap load B failed: " + e.message);
    s2 = null;
  }
  try { unlinkSync(rootLink); } catch { /* ignore */ }
  symlinkSync(rootA, rootLink);
  clearPolicySchemaCache();
  let s3;
  try {
    s3 = loadPolicySchema(null, rootLink);
  } catch (e) {
    bad("root-swap load A2 failed: " + e.message);
    s3 = null;
  }
  if (
    s1 &&
    s2 &&
    s3 &&
    s1.title === "SCHEMA_ROOT_A" &&
    s2.title === "SCHEMA_ROOT_B" &&
    s3.title === "SCHEMA_ROOT_A" &&
    s1.title !== s2.title
  ) {
    ok("root-swap schema re-read (no cache poison)");
  } else {
    bad(
      "root-swap cache poison or mismatch: " +
        JSON.stringify({
          s1: s1 && s1.title,
          s2: s2 && s2.title,
          s3: s3 && s3.title,
        })
    );
  }
  // Also: direct realpath of A after B load must not return B if ever cached under A
  const realA = resolveCanonicalRepoRoot(rootA);
  clearPolicySchemaCache();
  const sDirectA = loadPolicySchema(null, realA);
  if (sDirectA.title !== "SCHEMA_ROOT_A") {
    bad("direct rootA after B load returned " + sDirectA.title);
  }

  // Hook cleared; normal path works
  setSafeReadAfterOpenHook(null);
  try {
    sha256ContainedFile(root, "docs/inside.txt");
    ok("post-swap hook cleared; normal hash works");
  } catch (e) {
    bad("post-swap normal hash failed: " + e.message);
  }

  // FIFO: nonblocking open + reject non-regular promptly (bounded wall clock).
  // Use mkfifo(1) only — no nested shell (outer sensor is bash single-quoted).
  const fifoPath = join(root, "docs/fifo-pipe");
  const mk = spawnSync("mkfifo", [fifoPath], { encoding: "utf8" });
  if (mk.status !== 0) {
    bad("fifo setup failed (mkfifo unavailable status=" + mk.status + ")");
  } else {
    const t0 = Date.now();
    let fifoThrew = false;
    let fifoMsg = "";
    try {
      readContainedFile(root, "docs/fifo-pipe", "utf8");
    } catch (e) {
      fifoThrew = true;
      fifoMsg = e && e.message ? e.message : String(e);
    }
    const elapsed = Date.now() - t0;
    if (
      fifoThrew &&
      /not a regular file|cannot open/i.test(fifoMsg) &&
      elapsed < 2000
    ) {
      ok("fifo rejected promptly as non-regular");
    } else if (!fifoThrew) {
      bad("fifo was accepted as a regular file");
    } else if (elapsed >= 2000) {
      bad("fifo open hung ms=" + elapsed + " msg=" + fifoMsg);
    } else {
      bad("fifo reject unexpected: ms=" + elapsed + " msg=" + fifoMsg);
    }
  }
} finally {
  // Outer finally: never leak hook or cache across failures
  setSafeReadAfterOpenHook(null);
  setRootIdentityRecheckHook(null);
  clearPolicySchemaCache();
  try { rmSync(root, { recursive: true, force: true }); } catch { /* ignore */ }
  try { rmSync(outside, { recursive: true, force: true }); } catch { /* ignore */ }
  try { rmSync(rootA, { recursive: true, force: true }); } catch { /* ignore */ }
  try { rmSync(rootB, { recursive: true, force: true }); } catch { /* ignore */ }
  try { unlinkSync(rootLink); } catch { /* ignore */ }
  try { rmSync(rootLink, { recursive: true, force: true }); } catch { /* ignore */ }
}
console.log("SENSOR_DONE " + okCount);
process.exit(fail === 0 ? 0 : 1);
' >"$SWAP_RAW" 2>"$ROOT/sensor-swap.err" || SWAP_RC=$?

# Strict aggregator on the raw byte file (NUL-preserving capture path)
tally_sensor_receipts_file "$SWAP_RAW"
if [[ "$SWAP_RC" -ne 0 ]] && ! grep -a -q "^SENSOR_BAD " "$SWAP_RAW" 2>/dev/null; then
  bad "injected-swap sensor exited non-zero without SENSOR_BAD (rc=$SWAP_RC)"
fi

# Static proof: production identity path uses bigint Stats options + comparator
if grep -q 'fstatSync(fd, { bigint: true })' "$TOOL" && \
   grep -q 'statSync(real, { bigint: true })' "$TOOL" && \
   grep -q 'export function rootIdentitiesEqual' "$TOOL"; then
  ok "source uses BigInt fstatSync/statSync and rootIdentitiesEqual"
else
  bad "source missing BigInt stats options or rootIdentitiesEqual"
fi
if grep -q 'O_RDONLY' "$TOOL" && grep -q 'O_NONBLOCK' "$TOOL"; then
  ok "source opens with O_RDONLY|O_NONBLOCK"
else
  bad "source missing nonblocking open flags"
fi
# Root identity token (path + BigInt dev/ino) must be captured, not path-only
if grep -q 'export function resolveCanonicalRepoRoot' "$TOOL" && \
   grep -q 'export function assertRootIdentity' "$TOOL" && \
   grep -q 'dev: st.dev' "$TOOL" && \
   grep -q 'ino: st.ino' "$TOOL"; then
  ok "source captures root identity path+dev+ino token"
else
  bad "source missing root identity token capture"
fi
# No approve-then-reopen legacy exports
if grep -q 'export function resolveUnderRoot' "$TOOL" || \
   grep -q 'export function sha256File' "$TOOL"; then
  bad "unsafe legacy resolveUnderRoot/sha256File still exported"
else
  ok "unsafe legacy resolveUnderRoot/sha256File removed"
fi

# ---------------------------------------------------------------------------
# Consistency must fail closed on ALL provenance errors (not only digest /
# missing-file). Fifth/later provenance sources are traversed; path escape
# and later-source symlink swap must surface as E_PROVENANCE_* findings.
# ---------------------------------------------------------------------------
echo
echo "=== consistency fail-closed on provenance errors (incl. later sources) ==="

# Disposable mini-repo for relative --manifest containment
MINI_PROV="$ROOT/mini-prov"
mkdir -p "$MINI_PROV/docs" "$MINI_PROV/config/policy/schema" "$MINI_PROV/config/policy/candidates"
for d in docs/14-human-gates.md docs/03-roles.md docs/06-quality-gates.md docs/02-sdlc-pipeline.md; do
  mkdir -p "$MINI_PROV/$(dirname "$d")"
  cp "$REPO_ROOT/$d" "$MINI_PROV/$d"
done
cp "$SCHEMA" "$MINI_PROV/config/policy/schema/policy-manifest-v1.schema.json"
# Also copy any other provenance paths the candidate pins so digests can be re-pinned
"$NODE" -e '
  const fs = require("fs");
  const path = require("path");
  const repo = process.argv[1];
  const mini = process.argv[2];
  const cand = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
  for (const s of cand.provenance.sources) {
    if (typeof s.path !== "string") continue;
    const src = path.join(repo, s.path);
    const dst = path.join(mini, s.path);
    if (fs.existsSync(src) && fs.statSync(src).isFile()) {
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      fs.copyFileSync(src, dst);
    }
  }
' "$REPO_ROOT" "$MINI_PROV" "$CANDIDATE"

# Fifth provenance source with exact .. traversal path (relative manifest only)
mutate_json "$CANDIDATE" "$MINI_PROV/fifth-escape.json" '
  c.provenance.sources.push({
    id: "src.fifth-outside",
    path: "../outside.md",
    digestAlgorithm: "sha256",
    digest: "0".repeat(64),
    role: "supporting"
  });
'
# Re-pin digests for the original sources under the mini root so only the fifth fails
"$NODE" -e '
  const fs = require("fs");
  const crypto = require("crypto");
  const path = require("path");
  const root = process.argv[1];
  const p = process.argv[2];
  const c = JSON.parse(fs.readFileSync(p, "utf8"));
  for (const s of c.provenance.sources) {
    if (s.path === "../outside.md") continue;
    const abs = path.join(root, s.path);
    if (fs.existsSync(abs) && fs.statSync(abs).isFile()) {
      s.digest = crypto.createHash("sha256").update(fs.readFileSync(abs)).digest("hex");
    }
  }
  fs.writeFileSync(p, JSON.stringify(c, null, 2) + "\n");
' "$MINI_PROV" "$MINI_PROV/fifth-escape.json"
out=$(run_tool check-consistency --repo-root "$MINI_PROV" --manifest "fifth-escape.json" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "fifth provenance ../outside.md fails consistency" || bad "fifth provenance ../outside.md accepted (out=$out)"
has "fifth source path error code" "$out" "E_PROVENANCE_PATH"
# Must not claim consistency OK while discarding escape
lacks "fifth source no false I_CONSISTENCY_OK alone" "$out" "I_CONSISTENCY_OK"

# Later (5th) source that is a symlink escaping the root
OUTSIDE_PROV="$ROOT/outside-prov"
mkdir -p "$OUTSIDE_PROV"
printf 'OUTSIDE_PROV_SECRET\n' > "$OUTSIDE_PROV/leaked.md"
ln -sfn "$OUTSIDE_PROV/leaked.md" "$MINI_PROV/docs/later-escape.md"
"$NODE" -e '
  const fs = require("fs");
  const crypto = require("crypto");
  const path = require("path");
  const root = process.argv[1];
  const candPath = process.argv[2];
  const outPath = process.argv[3];
  const c = JSON.parse(fs.readFileSync(candPath, "utf8"));
  function dig(rel) {
    return crypto.createHash("sha256").update(fs.readFileSync(path.join(root, rel))).digest("hex");
  }
  for (const s of c.provenance.sources) {
    const abs = path.join(root, s.path);
    try {
      if (fs.existsSync(abs) && fs.statSync(abs).isFile() && !fs.lstatSync(abs).isSymbolicLink()) {
        s.digest = dig(s.path);
      }
    } catch { /* skip */ }
  }
  c.provenance.sources.push({
    id: "src.later-symlink-escape",
    path: "docs/later-escape.md",
    digestAlgorithm: "sha256",
    digest: "a".repeat(64),
    role: "supporting"
  });
  fs.writeFileSync(outPath, JSON.stringify(c, null, 2) + "\n");
' "$MINI_PROV" "$CANDIDATE" "$MINI_PROV/cand-later.json"
out=$(run_tool check-consistency --repo-root "$MINI_PROV" --manifest "cand-later.json" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "later provenance symlink escape fails consistency" || bad "later symlink escape accepted (out=$out)"
if echo "$out" | grep -Eq 'E_PROVENANCE_PATH_ESCAPE|E_PROVENANCE_PATH'; then
  ok "later source emits provenance path/escape code"
else
  bad "later source missing provenance escape code (out=$out)"
fi
lacks "later source no false consistency OK" "$out" "I_CONSISTENCY_OK"

# Source-level proof: consistency revalidation propagates E_PROVENANCE_* AND
# E_SCHEMA_LOAD / root-identity failures (not a narrow E_PROVENANCE-only filter).
if grep -q 'export function isConsistencyRevalidationError' "$TOOL" && \
   grep -q 'E_SCHEMA_LOAD' "$TOOL" && \
   grep -q 'startsWith("E_PROVENANCE")' "$TOOL"; then
  ok "consistency revalidation keeps provenance + schema/root errors"
else
  bad "consistency missing broad revalidation error propagation"
fi

# ---------------------------------------------------------------------------
# Final revalidation root identity failure: after the four doctrine reads,
# replace the frozen root before schema/provenance revalidation. Must produce
# an error and must NEVER emit I_CONSISTENCY_OK. Early mid-read replacement
# alone is not sufficient.
# ---------------------------------------------------------------------------
echo
echo "=== final revalidation root identity failure (post four doctrine reads) ==="
FINAL_RV_RC=0
FINAL_RV_OUT=$(
  PM_TOOL="$TOOL" PM_CANDIDATE="$CANDIDATE" PM_REPO="$REPO_ROOT" \
  "$NODE" --input-type=module -e '
import {
  mkdirSync,
  writeFileSync,
  rmSync,
  cpSync,
  renameSync,
  readFileSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

const toolPath = process.env.PM_TOOL;
const candidateSrc = process.env.PM_CANDIDATE;
const repo = process.env.PM_REPO;
const {
  checkDoctrineConsistency,
  resolveCanonicalRepoRoot,
  setRootIdentityRecheckHook,
  setSafeReadAfterOpenHook,
  tryOpenRootDirFd,
  closeRootDirFd,
  assertRootIdentity,
} = await import(pathToFileURL(toolPath).href);

const liveRoot = join(tmpdir(), "gibson-pm-finalrv-" + process.pid + "-" + Date.now());
const liveMoved = liveRoot + ".moved";
try {
  rmSync(liveRoot, { recursive: true, force: true });
  rmSync(liveMoved, { recursive: true, force: true });
  mkdirSync(liveRoot, { recursive: true });

  const cand0 = JSON.parse(readFileSync(candidateSrc, "utf8"));
  const paths = new Set([
    "docs/14-human-gates.md",
    "docs/03-roles.md",
    "docs/06-quality-gates.md",
    "docs/02-sdlc-pipeline.md",
    "config/policy/schema/policy-manifest-v1.schema.json",
  ]);
  for (const s of cand0.provenance.sources) {
    if (typeof s.path === "string") paths.add(s.path);
  }
  for (const d of paths) {
    mkdirSync(join(liveRoot, d.split("/").slice(0, -1).join("/") || "."), {
      recursive: true,
    });
    cpSync(join(repo, d), join(liveRoot, d));
  }
  const cand = JSON.parse(JSON.stringify(cand0));
  for (const s of cand.provenance.sources) {
    s.digest = createHash("sha256")
      .update(readFileSync(join(liveRoot, s.path)))
      .digest("hex");
  }

  const frozen = resolveCanonicalRepoRoot(liveRoot);

  // Prove retained dir fd open/close works on this platform (or null fallback).
  const fd = tryOpenRootDirFd(frozen);
  if (fd != null) {
    assertRootIdentity(frozen, { rootDirFd: fd });
    closeRootDirFd(fd);
    closeRootDirFd(fd); // deterministic double-close safety
    console.log("FINAL_RV_DIRFD_OK");
  } else {
    console.log("FINAL_RV_DIRFD_NULL");
  }

  let opens = 0;
  let checksAtFour = 0;
  let replaced = false;
  setSafeReadAfterOpenHook(() => {
    opens += 1;
  });
  setRootIdentityRecheckHook((rootId) => {
    if (opens < 4) return;
    checksAtFour += 1;
    // checksAtFour===1: post-open assert of the fourth doctrine file — leave intact.
    // checksAtFour===2: first assert of final revalidation — replace root here.
    if (checksAtFour === 2 && !replaced) {
      replaced = true;
      renameSync(rootId.path, liveMoved);
      mkdirSync(rootId.path, { recursive: true });
      mkdirSync(join(rootId.path, "config/policy/schema"), { recursive: true });
      // Hostile replacement at same pathname, different inode; schema bind fails.
      writeFileSync(
        join(rootId.path, "config/policy/schema/policy-manifest-v1.schema.json"),
        "{}\n"
      );
    }
  });

  const findings = checkDoctrineConsistency(cand, frozen);
  setRootIdentityRecheckHook(null);
  setSafeReadAfterOpenHook(null);

  const codes = findings.map((f) => f.code);
  const hasOk = codes.includes("I_CONSISTENCY_OK");
  const hasError = findings.some((f) => f.severity === "error");
  const hasRootOrSchema = findings.some(
    (f) =>
      f.severity === "error" &&
      (f.code === "E_SCHEMA_LOAD" ||
        f.code === "E_CONSISTENCY_READ" ||
        /repo root identity|cannot bind repo root|E_SCHEMA_LOAD/i.test(
          String(f.code) + " " + String(f.message)
        ))
  );

  console.log(
    "FINAL_RV_RESULT " +
      JSON.stringify({
        opens,
        checksAtFour,
        replaced,
        hasOk,
        hasError,
        hasRootOrSchema,
        codes,
      })
  );

  if (opens !== 4 || !replaced) {
    console.log("FINAL_RV_FAIL setup opens=" + opens + " replaced=" + replaced);
    process.exit(2);
  }
  if (hasOk || !hasError || !hasRootOrSchema) {
    console.log("FINAL_RV_FAIL false-OK or missing error");
    process.exit(1);
  }
  console.log("FINAL_RV_PASS");
  process.exit(0);
} catch (e) {
  setRootIdentityRecheckHook(null);
  setSafeReadAfterOpenHook(null);
  console.log("FINAL_RV_FAIL " + (e && e.message ? e.message : e));
  process.exit(2);
} finally {
  try { rmSync(liveRoot, { recursive: true, force: true }); } catch { /* ignore */ }
  try { rmSync(liveMoved, { recursive: true, force: true }); } catch { /* ignore */ }
}
' 2>&1
) || FINAL_RV_RC=$?

if [[ "$FINAL_RV_RC" -eq 0 ]] && echo "$FINAL_RV_OUT" | grep -q "FINAL_RV_PASS"; then
  ok "final revalidation root identity failure errors without I_CONSISTENCY_OK"
else
  bad "final revalidation root identity failure not fail-closed (rc=$FINAL_RV_RC out=$FINAL_RV_OUT)"
fi
if echo "$FINAL_RV_OUT" | grep -q "FINAL_RV_DIRFD_OK\|FINAL_RV_DIRFD_NULL"; then
  ok "root dir fd open/close path exercised (or portable null fallback)"
else
  bad "root dir fd path not exercised"
fi
lacks "final revalidation no I_CONSISTENCY_OK in probe" "$FINAL_RV_OUT" '"hasOk":true'

# Mutation proof: narrow E_PROVENANCE_* filter discards E_SCHEMA_LOAD and the
# focused final-revalidation case would falsely pass — prove the suite fails
# when production is reverted to that narrow filter.
echo
echo "=== mutation: narrow E_PROVENANCE filter must break final-revalidation proof ==="
NARROW_TOOL="$ROOT/policy-manifest-narrow-filter.mjs"
cp "$TOOL" "$NARROW_TOOL"
# Force isConsistencyRevalidationError to the defective narrow filter and
# remove the before/after final-revalidation root asserts (exact-head shape).
"$NODE" -e '
  const fs = require("fs");
  const p = process.argv[1];
  let s = fs.readFileSync(p, "utf8");
  function replaceFunction(src, name, body) {
    const start = src.indexOf("export function " + name);
    if (start < 0) throw new Error("missing " + name);
    const brace = src.indexOf("{", start);
    let depth = 0, end = -1;
    for (let i = brace; i < src.length; i++) {
      if (src[i] === "{") depth++;
      else if (src[i] === "}") {
        depth--;
        if (depth === 0) { end = i + 1; break; }
      }
    }
    if (end < 0) throw new Error("cannot find end of " + name);
    return src.slice(0, start) + body + src.slice(end);
  }
  s = replaceFunction(
    s,
    "isConsistencyRevalidationError",
    "export function isConsistencyRevalidationError(f) {\n" +
      "  // MUTATION: defective narrow filter (round-7 defect) — discards E_SCHEMA_LOAD\n" +
      "  return !!(f && typeof f.code === \"string\" && f.code.startsWith(\"E_PROVENANCE\"));\n" +
      "}"
  );
  // Marker sits inside the catch template string, which is AFTER "catch (e)".
  // Walk back: catch → try, then brace-match the catch body only.
  for (const marker of [
    "repo root identity failed before final revalidation",
    "repo root identity failed after final revalidation",
  ]) {
    const mi = s.indexOf(marker);
    if (mi < 0) throw new Error("missing marker " + marker);
    const catchIdx = s.lastIndexOf("catch (e)", mi);
    if (catchIdx < 0) throw new Error("missing catch for " + marker);
    const tryIdx = s.lastIndexOf("try {", catchIdx);
    if (tryIdx < 0) throw new Error("missing try for " + marker);
    const catchBrace = s.indexOf("{", catchIdx);
    let depth = 0, end = -1;
    for (let i = catchBrace; i < s.length; i++) {
      if (s[i] === "{") depth++;
      else if (s[i] === "}") {
        depth--;
        if (depth === 0) { end = i + 1; break; }
      }
    }
    if (end < 0 || end <= mi) throw new Error("cannot end catch for " + marker);
    s = s.slice(0, tryIdx) + "/* mutated: removed " + marker + " */" + s.slice(end);
  }
  fs.writeFileSync(p, s);
  // Syntax must remain valid after mutation surgery.
  try {
    new Function(s);
  } catch (e) {
    // ESM export syntax is not valid for Function(); fall back to node --check via write.
  }
' "$NARROW_TOOL"
if ! "$NODE" --check "$NARROW_TOOL" 2>/dev/null; then
  bad "narrow filter mutation produced invalid syntax"
fi
NARROW_OUT=$(
  PM_TOOL="$NARROW_TOOL" PM_CANDIDATE="$CANDIDATE" PM_REPO="$REPO_ROOT" \
  "$NODE" --input-type=module -e '
import {
  mkdirSync, writeFileSync, rmSync, cpSync, renameSync, readFileSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

const toolPath = process.env.PM_TOOL;
const candidateSrc = process.env.PM_CANDIDATE;
const repo = process.env.PM_REPO;
const {
  checkDoctrineConsistency,
  resolveCanonicalRepoRoot,
  setRootIdentityRecheckHook,
  setSafeReadAfterOpenHook,
} = await import(pathToFileURL(toolPath).href);

const liveRoot = join(tmpdir(), "gibson-pm-narrow-" + process.pid + "-" + Date.now());
const liveMoved = liveRoot + ".moved";
try {
  mkdirSync(liveRoot, { recursive: true });
  const cand0 = JSON.parse(readFileSync(candidateSrc, "utf8"));
  const paths = new Set([
    "docs/14-human-gates.md","docs/03-roles.md","docs/06-quality-gates.md",
    "docs/02-sdlc-pipeline.md","config/policy/schema/policy-manifest-v1.schema.json",
  ]);
  for (const s of cand0.provenance.sources) if (typeof s.path === "string") paths.add(s.path);
  for (const d of paths) {
    mkdirSync(join(liveRoot, d.split("/").slice(0, -1).join("/") || "."), { recursive: true });
    cpSync(join(repo, d), join(liveRoot, d));
  }
  const cand = JSON.parse(JSON.stringify(cand0));
  for (const s of cand.provenance.sources) {
    s.digest = createHash("sha256").update(readFileSync(join(liveRoot, s.path))).digest("hex");
  }
  const frozen = resolveCanonicalRepoRoot(liveRoot);
  let opens = 0, checksAtFour = 0, replaced = false;
  setSafeReadAfterOpenHook(() => { opens += 1; });
  setRootIdentityRecheckHook((rootId) => {
    if (opens < 4) return;
    checksAtFour += 1;
    if (checksAtFour === 2 && !replaced) {
      replaced = true;
      renameSync(rootId.path, liveMoved);
      mkdirSync(rootId.path, { recursive: true });
      mkdirSync(join(rootId.path, "config/policy/schema"), { recursive: true });
      writeFileSync(join(rootId.path, "config/policy/schema/policy-manifest-v1.schema.json"), "{}\n");
    }
  });
  const findings = checkDoctrineConsistency(cand, frozen);
  setRootIdentityRecheckHook(null);
  setSafeReadAfterOpenHook(null);
  const hasOk = findings.some((f) => f.code === "I_CONSISTENCY_OK");
  const hasError = findings.some((f) => f.severity === "error");
  // Defect signature: false I_CONSISTENCY_OK after final-revalidation root replace.
  if (replaced && opens === 4 && hasOk && !hasError) {
    console.log("NARROW_DEFECT_REPRODUCED");
    process.exit(0);
  }
  console.log("NARROW_UNEXPECTED " + JSON.stringify(findings.map((f) => f.code)));
  process.exit(1);
} finally {
  try { rmSync(liveRoot, { recursive: true, force: true }); } catch { /* ignore */ }
  try { rmSync(liveMoved, { recursive: true, force: true }); } catch { /* ignore */ }
}
' 2>&1
) || true
if echo "$NARROW_OUT" | grep -q "NARROW_DEFECT_REPRODUCED"; then
  ok "narrow E_PROVENANCE filter mutation reproduces false I_CONSISTENCY_OK"
else
  bad "narrow filter mutation did not reproduce defect (out=$NARROW_OUT)"
fi

# ---------------------------------------------------------------------------
# mktemp -d failure must stop before traps / child path construction.
# Inject a failing mktemp; prove the suite-equivalent preamble exits without
# creating or writing under /bin, $HOME, or the repository.
# ---------------------------------------------------------------------------
echo
echo "=== mktemp -d failure stops before hostile path writes ==="
MKTEMP_PROBE="$ROOT/mktemp-probe"
mkdir -p "$MKTEMP_PROBE/bin" "$MKTEMP_PROBE/watch"
# Marker path that must remain untouched if ROOT were empty/wrong
MARKER_BIN="$MKTEMP_PROBE/watch/bin-marker"
# Fake mktemp that fails
cat > "$MKTEMP_PROBE/bin/mktemp" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$MKTEMP_PROBE/bin/mktemp"
# Probe script mirrors the suite's fail-closed preamble (not the full suite)
cat > "$MKTEMP_PROBE/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
# If ROOT were empty, these would resolve to broad paths — we must never write.
# Use env overrides so the probe never targets real /bin or $HOME.
export PATH="${FAKE_BIN}:/usr/bin:/bin"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-policy-manifest-probe.XXXXXX") || {
  echo "PROBE_MKTEMP_FAILED"
  exit 1
}
if [[ -z "${ROOT}" || ! -d "${ROOT}" ]]; then
  echo "PROBE_MKTEMP_EMPTY"
  exit 1
fi
# Only after validation may we install trap / write children.
trap 'rm -rf -- "${ROOT:?}"' EXIT
mkdir -p "$ROOT/bin"
echo "STUB_WRITTEN" > "$ROOT/bin/hostile-stub"
echo "PROBE_UNEXPECTED_SUCCESS"
exit 0
PROBE
chmod +x "$MKTEMP_PROBE/probe.sh"
PROBE_OUT=$(
  FAKE_BIN="$MKTEMP_PROBE/bin" \
  TMPDIR="$MKTEMP_PROBE/tmp-should-not-matter" \
  bash "$MKTEMP_PROBE/probe.sh" 2>&1
) || PROBE_RC=$?
PROBE_RC=${PROBE_RC:-0}
if [[ "$PROBE_RC" -ne 0 ]] && echo "$PROBE_OUT" | grep -q "PROBE_MKTEMP_FAILED"; then
  ok "mktemp failure exits before trap/child writes"
else
  bad "mktemp failure probe did not fail closed (rc=$PROBE_RC out=$PROBE_OUT)"
fi
# Prove no write escaped into the watch markers / real broad paths via empty ROOT
if [[ -e "$MARKER_BIN" || -e "/bin/hostile-stub-policy-manifest-probe" ]]; then
  bad "mktemp failure wrote under bin-like path"
else
  ok "mktemp failure did not write bin marker"
fi
# Empty-ROOT simulation: without the guard, ROOT="" + mkdir -p "$ROOT/bin" → /bin
# Prove the guard rejects empty ROOT before mkdir.
cat > "$MKTEMP_PROBE/probe-empty.sh" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
# Simulate mktemp returning empty string without exiting (hostile)
ROOT=""
if [[ -z "${ROOT}" || ! -d "${ROOT}" ]]; then
  echo "PROBE_EMPTY_REJECTED"
  exit 1
fi
# Would resolve to /bin if we got here
mkdir -p "$ROOT/bin"
echo "owned" > "$ROOT/bin/hostile-stub-policy-manifest-probe"
echo "PROBE_EMPTY_WRITTEN"
exit 0
PROBE
EMPTY_OUT=$(bash "$MKTEMP_PROBE/probe-empty.sh" 2>&1) || EMPTY_RC=$?
EMPTY_RC=${EMPTY_RC:-0}
if [[ "$EMPTY_RC" -ne 0 ]] && echo "$EMPTY_OUT" | grep -q "PROBE_EMPTY_REJECTED"; then
  ok "empty ROOT rejected before child path construction"
else
  bad "empty ROOT not rejected (rc=$EMPTY_RC out=$EMPTY_OUT)"
fi
if [[ -e /bin/hostile-stub-policy-manifest-probe ]]; then
  bad "empty ROOT simulation wrote /bin/hostile-stub-policy-manifest-probe"
  rm -f /bin/hostile-stub-policy-manifest-probe 2>/dev/null || true
else
  ok "empty ROOT simulation did not write under /bin"
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
