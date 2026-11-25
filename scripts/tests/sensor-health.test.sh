#!/usr/bin/env bash
# sensor-health.test.sh — gate-discovered sensors for #256 (case 15 + node suite).
set -euo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"
PASS=0
FAIL=0
ok() { echo "  ok — $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $*"; FAIL=$((FAIL + 1)); }
WF=".github/workflows/sensor-health.yml"
[[ -f "$WF" ]] && ok "workflow present" || bad "missing $WF"
if grep -nE '^[[:space:]]*continue-on-error[[:space:]]*:' "$WF" >/dev/null 2>&1; then
  bad "$WF declares continue-on-error (forbidden for fail-closed audit)"
else
  ok "no continue-on-error in $WF"
fi
audit_run_cmd_lines() {
  # Executable run: scalar only — YAML comments must not satisfy this.
  grep -nE '^[[:space:]]*run:[[:space:]]+node[[:space:]]+scripts/sensor-health\.mjs[[:space:]]+--post([[:space:]]*(#.*)?)?$' "$1" || true
}
AUDIT_LINE=$(audit_run_cmd_lines "$WF")
[[ -n "$AUDIT_LINE" ]] && ok "executable audit run: present: $AUDIT_LINE" || bad "executable audit run: missing"
if grep -nE 'sensor-health\.mjs.*\|\|[[:space:]]*true' "$WF" >/dev/null 2>&1; then
  bad "audit step swallows failure with || true"
else
  ok "audit step not wrapped in || true"
fi
if grep -vE '^[[:space:]]*#' "$WF" | grep -nE 'set[[:space:]]+\+e' >/dev/null 2>&1; then
  bad "workflow uses set +e outside comments"
else
  ok "no set +e in workflow executable lines"
fi
grep -qi 'Advisory: this job stays green' "$WF" && bad "advisory always-green wording present" || ok "advisory always-green wording removed"
grep -qi 'Fail-closed' "$WF" && ok "fail-closed wording present" || bad "missing Fail-closed note"
grep -q '#212' "$WF" && ok "standing issue #212 referenced" || bad "workflow should mention #212"
PLANT2=""
PLANT3=""
PLANT=$(mktemp "${TMPDIR:-/tmp}/sensor-health-plant.XXXXXX")
trap 'rm -f "$PLANT" "$PLANT2" "$PLANT3"' EXIT
cat >"$PLANT" <<'YAML'
jobs:
  sensor-health:
    steps:
      - name: Audit
        continue-on-error: true
        run: node scripts/sensor-health.mjs --post || true
YAML
plant_fail=0
grep -nE '^[[:space:]]*continue-on-error[[:space:]]*:' "$PLANT" >/dev/null && plant_fail=1
grep -nE 'sensor-health\.mjs.*\|\|[[:space:]]*true' "$PLANT" >/dev/null && plant_fail=1
[[ "$plant_fail" -eq 1 ]] && ok "planted continue-on-error / || true detectable" || bad "planted anti-patterns missed"
PLANT2=$(mktemp "${TMPDIR:-/tmp}/sensor-health-plant2.XXXXXX")
cat >"$PLANT2" <<'YAML'
jobs:
  sensor-health:
    steps:
      - run: |
          set +e
          node scripts/sensor-health.mjs --post
YAML
grep -nE 'set[[:space:]]+\+e' "$PLANT2" >/dev/null && ok "planted set +e detectable" || bad "planted set +e missed"
PLANT3=$(mktemp "${TMPDIR:-/tmp}/sensor-health-plant3.XXXXXX")
cat >"$PLANT3" <<'YAML'
jobs:
  sensor-health:
    steps:
      - name: Audit
        # run: node scripts/sensor-health.mjs --post
YAML
if [[ -n "$(audit_run_cmd_lines "$PLANT3")" ]]; then
  bad "comment-only audit command falsely accepted"
else
  ok "comment-only audit command rejected"
fi
if ! command -v node >/dev/null 2>&1; then
  bad "node not installed"
elif node --test "$REPO_ROOT/scripts/sensor-health.test.mjs"; then
  ok "node --test scripts/sensor-health.test.mjs"
else
  bad "node --test scripts/sensor-health.test.mjs"
fi
for mjs in scripts/sensor-health.mjs scripts/sensor-health-lib.mjs; do
  set +e
  err=$(node "$REPO_ROOT/$mjs" --definitely-not-a-flag 2>&1 >/dev/null)
  rc=$?
  set -e
  if [[ "$rc" -eq 2 ]] && grep -qE 'unknown (flag|option):' <<<"$err"; then
    ok "$mjs rejects unknown flag (rc=2)"
  else
    bad "$mjs unknown-flag contract (rc=$rc err=$err)"
  fi
done
[[ -f config/sensor-health-observation.v1.json ]] && ok "registry present" || bad "missing registry"
set +e
INV_OUT=$(node --input-type=module <<'JS'
import {
  CHECKED_IN_INVENTORY_EXCLUSIONS,
  REVIEW_EVIDENCE_EVENTS,
  REVIEW_EVIDENCE_WINDOW_DAYS,
  REVIEW_EVIDENCE_WORKFLOW_PATH,
  REASON,
  discoverCheckedInWorkflows,
  inventoryCheckedInWorkflows,
  loadRegistryFile,
  validateInventoryExclusions,
  validateRegistry,
} from "./scripts/sensor-health-lib.mjs";
const root = process.cwd();
const r = loadRegistryFile(root);
const row = r.policies.find((p) => p.path === REVIEW_EVIDENCE_WORKFLOW_PATH);
if (!row) throw new Error("review-evidence row missing");
if (row.mode !== "freshness") throw new Error(`mode ${row.mode}`);
if (row.windowDays !== REVIEW_EVIDENCE_WINDOW_DAYS) throw new Error(`windowDays ${row.windowDays}`);
const got = new Set(row.events);
if (REVIEW_EVIDENCE_EVENTS.some((e) => !got.has(e)) || row.events.length !== REVIEW_EVIDENCE_EVENTS.length) {
  throw new Error(`events ${JSON.stringify(row.events)}`);
}
const files = discoverCheckedInWorkflows(root);
const live = inventoryCheckedInWorkflows({ checkedInPaths: files, policies: r.policies });
if (live.rows.some((x) => x.joinError)) throw new Error("live inventory not clean");
const deleted = inventoryCheckedInWorkflows({
  checkedInPaths: files,
  policies: r.policies.filter((p) => p.path !== REVIEW_EVIDENCE_WORKFLOW_PATH),
});
if (!deleted.rows.some((x) => x.path === REVIEW_EVIDENCE_WORKFLOW_PATH && x.joinError === REASON.UNCONFIGURED_WORKFLOW)) {
  throw new Error("row deletion did not yield unconfigured-workflow");
}
const extra = ".github/workflows/unregistered-plant.yml";
const planted = inventoryCheckedInWorkflows({
  checkedInPaths: [...files, extra],
  policies: r.policies,
});
if (!planted.rows.some((x) => x.path === extra && x.joinError === REASON.UNCONFIGURED_WORKFLOW)) {
  throw new Error("planted workflow did not yield unconfigured-workflow");
}
if (CHECKED_IN_INVENTORY_EXCLUSIONS.length !== 0) {
  throw new Error("live inventory exclusions must remain empty");
}
const pagesPlant = { path: extra, capabilityReason: "capability-disabled:has_pages=false" };
let pagesPlantThrew = false;
try {
  validateInventoryExclusions([pagesPlant]);
} catch {
  pagesPlantThrew = true;
}
if (!pagesPlantThrew) throw new Error("planted workflow with Pages reason did not fail closed");
let pagesPlantInvThrew = false;
try {
  inventoryCheckedInWorkflows({
    checkedInPaths: [...files, extra],
    policies: r.policies,
    exclusions: [pagesPlant],
  });
} catch {
  pagesPlantInvThrew = true;
}
if (!pagesPlantInvThrew) throw new Error("inventory accepted planted workflow with Pages reason");
let requiredExclThrew = false;
try {
  validateInventoryExclusions([{
    path: REVIEW_EVIDENCE_WORKFLOW_PATH,
    capabilityReason: "capability-disabled:has_pages=false",
  }]);
} catch {
  requiredExclThrew = true;
}
if (!requiredExclThrew) throw new Error("required sensor exclusion did not fail closed");
let dupExclThrew = false;
try {
  validateInventoryExclusions([pagesPlant, { ...pagesPlant }]);
} catch {
  dupExclThrew = true;
}
if (!dupExclThrew) throw new Error("duplicate exclusion did not fail closed");
let malformedExclThrew = false;
try {
  validateInventoryExclusions([null]);
} catch {
  malformedExclThrew = true;
}
if (!malformedExclThrew) throw new Error("malformed exclusion did not fail closed");
for (const drop of REVIEW_EVIDENCE_EVENTS) {
  let threw = false;
  try {
    validateRegistry({
      ...r,
      policies: r.policies.map((p) =>
        p.path === REVIEW_EVIDENCE_WORKFLOW_PATH
          ? { ...p, events: p.events.filter((e) => e !== drop) }
          : p
      ),
    });
  } catch {
    threw = true;
  }
  if (!threw) throw new Error(`trigger mutation ${drop} did not fail`);
}
let wideThrew = false;
try {
  validateRegistry({
    ...r,
    policies: r.policies.map((p) =>
      p.path === REVIEW_EVIDENCE_WORKFLOW_PATH ? { ...p, windowDays: 2 } : p
    ),
  });
} catch {
  wideThrew = true;
}
if (!wideThrew) throw new Error("windowDays 2 did not fail");
let modeThrew = false;
try {
  validateRegistry({
    ...r,
    policies: r.policies.map((p) =>
      p.path === REVIEW_EVIDENCE_WORKFLOW_PATH ? { ...p, mode: "hourly" } : p
    ),
  });
} catch {
  modeThrew = true;
}
if (!modeThrew) throw new Error("unsupported mode did not fail");
console.log("inventory-and-mutation-witnesses-ok");
JS
)
INV_RC=$?
set -e
if [[ "$INV_RC" -eq 0 ]] && grep -q 'inventory-and-mutation-witnesses-ok' <<<"$INV_OUT"; then
  ok "review-evidence inventory + mutation witnesses"
else
  bad "review-evidence inventory + mutation witnesses (rc=$INV_RC out=$INV_OUT)"
fi
set +e
SHARD_OUT=$(node --input-type=module <<'JS'
import {
  FRESHNESS_CREATED_QUERY_SLACK_DAYS,
  GITHUB_WORKFLOW_RERUN_HORIZON_DAYS,
  REVIEW_EVIDENCE_WINDOW_DAYS,
  freshnessCreatedQueryFloor,
  freshnessCreatedQueryLookbackDays,
  freshnessCreatedQueryShards,
} from "./scripts/sensor-health-lib.mjs";
const obs = new Date("2026-08-30T12:00:00.000Z");
const oneDay = freshnessCreatedQueryFloor(obs, REVIEW_EVIDENCE_WINDOW_DAYS);
if (oneDay !== "2026-08-29") throw new Error(`one-day floor ${oneDay}`);
if (GITHUB_WORKFLOW_RERUN_HORIZON_DAYS !== 30) throw new Error("rerun horizon");
if (FRESHNESS_CREATED_QUERY_SLACK_DAYS !== 1) throw new Error("date slack");
if (freshnessCreatedQueryLookbackDays(1) !== 32) throw new Error("lookback");
const shards = freshnessCreatedQueryShards(obs, 1);
if (shards.length !== 33) throw new Error(`shard count ${shards.length}`);
if (shards[0].created !== "2026-07-29") throw new Error(`first ${shards[0].created}`);
if (shards.at(-1).created !== "2026-08-30") throw new Error(`last ${shards.at(-1).created}`);
if (!(shards[0].created < oneDay)) throw new Error("shards collapsed to one-day created floor");
if (shards.some((s) => !/^\d{4}-\d{2}-\d{2}$/.test(s.created))) throw new Error("unbounded or ranged shard");
if (shards.some((s) => s.created.startsWith(">="))) throw new Error("open created>= shard");
const seen = new Set();
for (const s of shards) {
  if (seen.has(s.created)) throw new Error(`duplicate shard ${s.created}`);
  seen.add(s.created);
}
console.log("created-shard-boundaries-ok");
JS
)
SHARD_RC=$?
set -e
if [[ "$SHARD_RC" -eq 0 ]] && grep -q 'created-shard-boundaries-ok' <<<"$SHARD_OUT"; then
  ok "freshness created-shard boundaries"
else
  bad "freshness created-shard boundaries (rc=$SHARD_RC out=$SHARD_OUT)"
fi
# AC5 (#384): one evaluator reads literal step-level if: strings from a workflow
# path and simulates checkout, audit, self-gate, and backlog. Omitted step-level
# if: is implicit success(). An earlier reporter failure does not suppress a later
# eligible reporter. Any executed step that fails without continue-on-error makes
# the simulated job failure. Unsupported expressions and duplicate named reporters
# fail closed. This file does not call git merge-base.
echo "# AC5 reporter eligibility"
AC5_TEMPS=()
ac5_cleanup() {
  rm -f "$PLANT" "$PLANT2" "$PLANT3"
  if [[ ${#AC5_TEMPS[@]} -gt 0 ]]; then
    rm -f "${AC5_TEMPS[@]}"
  fi
}
trap ac5_cleanup EXIT

ac5_new_temp() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/sensor-health-wf.XXXXXX")
  AC5_TEMPS+=("$f")
  printf '%s\n' "$f"
}

ac5_eval() {
  AC5_WF="$1" node --input-type=module <<'JS'
import fs from "fs";

const wfPath = process.env.AC5_WF;
if (!wfPath) {
  console.log("ac5-error missing-path");
  process.exit(2);
}
console.log(`ac5-evaluated ${wfPath}`);

const AUDIT_NAME = "Audit sensors and upsert report issue #212";
const SELFGATE_NAME = "Self-gate false-red and feedback-time budgets (config/self-gate-health.v1.json)";
const BACKLOG_NAME = "Classify backlog health and comment on #212";

function unquote(value) {
  const trimmed = value.trim();
  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"') && trimmed.length >= 2) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'") && trimmed.length >= 2)
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function cleanUses(value) {
  const hash = value.indexOf(" #");
  return unquote(hash === -1 ? value : value.slice(0, hash));
}

function fail(message) {
  console.log(`ac5-error ${message}`);
  process.exit(2);
}

let text;
try {
  text = fs.readFileSync(wfPath, "utf8");
} catch (error) {
  fail(`unreadable ${error.message}`);
}

const steps = [];
let current = null;
let inRun = false;

function startStep() {
  current = {
    name: null,
    id: null,
    uses: null,
    rawIf: null,
    ifDup: false,
    continueOnError: false,
  };
  steps.push(current);
}

function applyKey(key, value) {
  if (key === "name") current.name = unquote(value);
  else if (key === "id") current.id = unquote(value);
  else if (key === "uses") current.uses = cleanUses(value);
  else if (key === "if") {
    if (current.rawIf != null || value === "|" || value === ">" || value === "|-" || value === ">-") {
      current.ifDup = true;
    }
    current.rawIf = value.trim();
    if (value === "|" || value === ">" || value === "|-" || value === ">-") current.rawIf = "MULTILINE";
  } else if (key === "continue-on-error") {
    current.continueOnError = unquote(value) === "true";
  } else if (key === "run" && (value === "|" || value === ">" || value === "|-" || value === ">-")) {
    inRun = true;
  }
}

for (const line of text.split("\n")) {
  const stepLine = line.match(/^      - (.*)$/);
  if (stepLine) {
    inRun = false;
    startStep();
    const keyed = stepLine[1].match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (keyed) applyKey(keyed[1], keyed[2]);
    continue;
  }
  if (!current) continue;
  if (inRun) {
    if (line.trim() === "") continue;
    const indent = line.match(/^ */)[0].length;
    if (indent > 8) continue;
    inRun = false;
  }
  const keyed = line.match(/^        ([A-Za-z0-9_-]+):\s*(.*)$/);
  if (keyed) applyKey(keyed[1], keyed[2]);
}

function roleOf(step) {
  if (step.uses && step.uses.startsWith("actions/checkout@")) return "checkout";
  if (step.name === AUDIT_NAME) return "audit";
  if (step.name === SELFGATE_NAME) return "self-gate";
  if (step.name === BACKLOG_NAME) return "backlog";
  return null;
}

function parseExpr(raw) {
  if (raw == null) return { kind: "implicit-success" };
  if (raw === "MULTILINE") return { error: "multiline-if" };
  const wrapped = raw.match(/^\$\{\{\s*(.*?)\s*\}\}$/);
  if (!wrapped) return { error: `unsupported-wrapper:${raw}` };
  const parts = wrapped[1].trim().split("&&").map((part) => part.trim());
  if (parts.some((part) => part.length === 0)) return { error: "empty-atom" };
  if (parts.length === 1 && parts[0] === "success()") return { kind: "success" };
  const atoms = [];
  for (const part of parts) {
    if (part === "!cancelled()") atoms.push({ op: "not-cancelled" });
    else if (part === "success()") atoms.push({ op: "success" });
    else {
      const outcome = part.match(/^steps\.([A-Za-z_][A-Za-z0-9_-]*)\.outcome == '([^']*)'$/);
      if (!outcome) return { error: `unsupported-atom:${part}` };
      atoms.push({ op: "outcome", id: outcome[1], value: outcome[2] });
    }
  }
  return { kind: "and", atoms };
}

for (const step of steps) {
  if (step.ifDup) fail("duplicate-step-if");
  const parsed = parseExpr(step.rawIf);
  if (parsed.error) fail(parsed.error);
  step.expr = parsed;
}

for (const role of ["checkout", "audit", "self-gate", "backlog"]) {
  const found = steps.filter((step) => roleOf(step) === role);
  if ((role === "self-gate" || role === "backlog") && found.length > 1) {
    fail(`duplicate-named-reporter ${role}`);
  }
  if (found.length !== 1) fail(`step-identity ${role} count=${found.length}`);
}

const checkout = steps.find((step) => roleOf(step) === "checkout");
if (checkout.id !== "checkout") fail(`checkout-id ${checkout.id || "missing"}`);

function truth(expr, ctx) {
  const succeeded = !ctx.cancelled && !ctx.previousHardFailure;
  if (expr.kind === "implicit-success" || expr.kind === "success") return succeeded;
  for (const atom of expr.atoms) {
    if (atom.op === "not-cancelled" && ctx.cancelled) return false;
    if (atom.op === "success" && !succeeded) return false;
    if (atom.op === "outcome" && ctx.outcomes[atom.id] !== atom.value) return false;
  }
  return true;
}

function simulate(cancelAfter, results) {
  const ctx = { cancelled: false, previousHardFailure: false, jobFailed: false, outcomes: {} };
  const trace = { checkout: "missing", audit: "missing", "self-gate": "missing", backlog: "missing" };
  for (const step of steps) {
    const role = roleOf(step);
    const run = truth(step.expr, ctx);
    if (role) trace[role] = run ? "run" : "skip";
    let outcome = "skipped";
    if (run) {
      outcome = (role && results[role]) || "success";
      if ((outcome === "failure" || outcome === "cancelled") && !step.continueOnError) {
        ctx.previousHardFailure = true;
        ctx.jobFailed = true;
      }
    }
    if (step.id) ctx.outcomes[step.id] = outcome;
    if (role && cancelAfter === role) ctx.cancelled = true;
  }
  for (const role of ["checkout", "audit", "self-gate", "backlog"]) {
    if (trace[role] === "missing") fail(`untraced ${role}`);
  }
  let job = "success";
  if (ctx.jobFailed) job = "failure";
  else if (ctx.cancelled) job = "cancelled";
  return { trace, job };
}

const scenarios = [
  ["all-succeed", null, { checkout: "success", audit: "success", "self-gate": "success", backlog: "success" }],
  ["audit-fails", null, { checkout: "success", audit: "failure", "self-gate": "success", backlog: "success" }],
  ["self-gate-fails", null, { checkout: "success", audit: "success", "self-gate": "failure", backlog: "success" }],
  ["checkout-fails", null, { checkout: "failure" }],
  ["cancelled-after-checkout", "checkout", { checkout: "success" }],
  ["cancelled-after-audit-failure", "audit", { checkout: "success", audit: "failure" }],
];

console.log(`ac5-order ${steps.map((step) => roleOf(step) || "other").join(",")}`);
for (const step of steps) {
  const role = roleOf(step);
  if (!role) continue;
  if (step.rawIf == null) console.log(`ac5-if ${role} implicit-success`);
  else console.log(`ac5-if ${role} ${step.rawIf}`);
  console.log(`ac5-coe ${role} ${step.continueOnError ? "true" : "false"}`);
}
for (const [name, cancelAfter, results] of scenarios) {
  const { trace, job } = simulate(cancelAfter, results);
  console.log(`ac5-matrix ${name} self-gate=${trace["self-gate"]} backlog=${trace.backlog} job=${job}`);
}
JS
}

ac5_has() {
  grep -Fqx -- "$2" <<<"$1"
}

EXACT_IF='        if: ${{ !cancelled() && steps.checkout.outcome == '"'"'success'"'"' }}'
EXPECT_IF='${{ !cancelled() && steps.checkout.outcome == '"'"'success'"'"' }}'
LIVE_WF="$REPO_ROOT/$WF"

id_count=$(grep -cF 'id: checkout' "$WF" || true)
if [[ "$id_count" -eq 1 ]]; then
  ok "exactly one id: checkout"
else
  bad "id: checkout count=$id_count (want 1)"
fi
exact_if_count=$(grep -cF -- "$EXACT_IF" "$WF" || true)
if [[ "$exact_if_count" -eq 2 ]]; then
  ok "both reporters carry the checkout-success continuation if"
else
  bad "continuation if count=$exact_if_count (want 2)"
fi
other_if=$(grep -E '^[[:space:]]*if:' "$WF" | grep -Fvx -- "$EXACT_IF" || true)
if [[ -z "$other_if" ]]; then
  ok "no other step-level if"
else
  bad "unexpected step-level if: $other_if"
fi
if grep -nE '^[[:space:]]*(strategy:|retry:|max-attempts:)' "$WF" >/dev/null 2>&1; then
  bad "workflow introduces retry or a matrix strategy"
else
  ok "no retry or matrix strategy"
fi

set +e
live_out=$(ac5_eval "$LIVE_WF")
live_rc=$?
set -e
printf '%s\n' "$live_out"
if [[ "$live_rc" -ne 0 ]]; then
  bad "live workflow evaluator failed rc=$live_rc"
else
  ok "live workflow evaluator rc=0"
fi
if ac5_has "$live_out" "ac5-evaluated $LIVE_WF"; then
  ok "evaluator read the live workflow path"
else
  bad "evaluator did not report the live workflow path"
fi
if ac5_has "$live_out" "ac5-order checkout,audit,self-gate,backlog"; then
  ok "steps evaluated in YAML order"
else
  bad "step order was not checkout,audit,self-gate,backlog"
fi
for role in checkout audit; do
  if ac5_has "$live_out" "ac5-if $role implicit-success"; then
    ok "$role if is implicit success()"
  else
    bad "$role if is not implicit success()"
  fi
done
for role in self-gate backlog; do
  if ac5_has "$live_out" "ac5-if $role $EXPECT_IF"; then
    ok "$role if is the literal continuation expression"
  else
    bad "$role if was not read literally"
  fi
done
AC5_MATRIX=(
  "ac5-matrix all-succeed self-gate=run backlog=run job=success"
  "ac5-matrix audit-fails self-gate=run backlog=run job=failure"
  "ac5-matrix self-gate-fails self-gate=run backlog=run job=failure"
  "ac5-matrix checkout-fails self-gate=skip backlog=skip job=failure"
  "ac5-matrix cancelled-after-checkout self-gate=skip backlog=skip job=cancelled"
  "ac5-matrix cancelled-after-audit-failure self-gate=skip backlog=skip job=failure"
)
for line in "${AC5_MATRIX[@]}"; do
  if ac5_has "$live_out" "$line"; then
    ok "$line"
  else
    bad "missing $line"
  fi
done

ac5_mutate() {
  local name="$1" src="$2" dest="$3"
  case "$name" in
    'remove !cancelled()')
      awk -v bit='!cancelled() && ' '
        BEGIN { c = 0 }
        {
          if (c == 0) {
            pos = index($0, bit)
            if (pos > 0) {
              $0 = substr($0, 1, pos - 1) substr($0, pos + length(bit))
              c = 1
            }
          }
          print
        }
        END { if (c != 1) exit 3 }
      ' "$src" >"$dest"
      ;;
    'remove checkout clause')
      awk -v bit=" && steps.checkout.outcome == 'success'" '
        BEGIN { c = 0 }
        {
          if (c == 0) {
            pos = index($0, bit)
            if (pos > 0) {
              $0 = substr($0, 1, pos - 1) substr($0, pos + length(bit))
              c = 1
            }
          }
          print
        }
        END { if (c != 1) exit 3 }
      ' "$src" >"$dest"
      ;;
    'success()')
      awk -v old="$EXACT_IF" -v neu='        if: ${{ success() }}' '
        BEGIN { c = 0 }
        {
          if (c == 0 && $0 == old) { print neu; c = 1; next }
          print
        }
        END { if (c != 1) exit 3 }
      ' "$src" >"$dest"
      ;;
    'always() && steps.checkout.outcome == '"'"'success'"'"'')
      awk -v old="$EXACT_IF" -v neu="        if: \${{ always() && steps.checkout.outcome == 'success' }}" '
        BEGIN { c = 0 }
        {
          if (c == 0 && $0 == old) { print neu; c = 1; next }
          print
        }
        END { if (c != 1) exit 3 }
      ' "$src" >"$dest"
      ;;
    'audit continue-on-error')
      awk -v name='      - name: Audit sensors and upsert report issue #212' '
        BEGIN { c = 0 }
        {
          print
          if (c == 0 && $0 == name) { print "        continue-on-error: true"; c = 1 }
        }
        END { if (c != 1) exit 3 }
      ' "$src" >"$dest"
      ;;
    *)
      echo "unknown mutant $name" >&2
      return 2
      ;;
  esac
}

ac5_reject_mutant() {
  local name="$1" want="$2"
  local f out rc
  f=$(ac5_new_temp)
  if ! ac5_mutate "$name" "$LIVE_WF" "$f"; then
    bad "mutant $name was not generated from the live workflow"
    return
  fi
  if cmp -s "$LIVE_WF" "$f"; then
    bad "mutant $name did not change the live workflow"
    return
  fi
  set +e
  out=$(ac5_eval "$f")
  rc=$?
  set -e
  if ! ac5_has "$out" "ac5-evaluated $f"; then
    bad "mutant $name was not the file passed to the evaluator"
    return
  fi
  if ac5_has "$out" "ac5-evaluated $LIVE_WF"; then
    bad "mutant $name evaluator reported the live path"
    return
  fi
  if [[ "$name" == "always() && steps.checkout.outcome == 'success'" ]]; then
    if [[ "$rc" -ne 0 ]] && ac5_has "$out" "ac5-error unsupported-atom:always()" && ! ac5_has "$out" "${AC5_MATRIX[0]}"; then
      echo "mutant $name: rejected"
      ok "mutant $name rejected"
    else
      bad "mutant $name was not rejected as an unsupported expression (rc=$rc)"
      printf '%s\n' "$out"
    fi
    return
  fi
  if [[ "$rc" -ne 0 ]]; then
    bad "mutant $name failed closed before the matrix (rc=$rc)"
    printf '%s\n' "$out"
    return
  fi
  if ac5_has "$out" "$want"; then
    local missing_good=0
    local line
    for line in "${AC5_MATRIX[@]}"; do
      if ! ac5_has "$out" "$line"; then
        missing_good=1
      fi
    done
    if [[ "$missing_good" -eq 1 ]]; then
      echo "mutant $name: rejected"
      ok "mutant $name rejected ($want)"
    else
      bad "mutant $name still satisfied the live matrix"
      printf '%s\n' "$out"
    fi
  else
    bad "mutant $name did not produce the expected broken matrix line"
    printf '%s\n' "$out"
  fi
}

ac5_reject_mutant 'remove !cancelled()' 'ac5-matrix cancelled-after-checkout self-gate=run backlog=skip job=cancelled'
ac5_reject_mutant 'remove checkout clause' 'ac5-matrix checkout-fails self-gate=run backlog=skip job=failure'
ac5_reject_mutant 'success()' 'ac5-matrix audit-fails self-gate=skip backlog=run job=failure'
ac5_reject_mutant "always() && steps.checkout.outcome == 'success'" 'unsupported'
ac5_reject_mutant 'audit continue-on-error' 'ac5-matrix audit-fails self-gate=run backlog=run job=success'

dup_wf=$(ac5_new_temp)
if ! cat "$LIVE_WF" >"$dup_wf"; then
  bad "could not copy live workflow for duplicate reporter"
else
  cat >>"$dup_wf" <<'YAML'
      - name: Classify backlog health and comment on #212
        run: node scripts/backlog-health.mjs
YAML
  set +e
  dup_out=$(ac5_eval "$dup_wf")
  dup_rc=$?
  set -e
  if [[ "$dup_rc" -ne 0 ]] && ac5_has "$dup_out" "ac5-evaluated $dup_wf" && ac5_has "$dup_out" "ac5-error duplicate-named-reporter backlog" && ! ac5_has "$dup_out" "${AC5_MATRIX[0]}"; then
    ok "duplicate named reporter rejected"
  else
    bad "duplicate named reporter was not rejected (rc=$dup_rc)"
    printf '%s\n' "$dup_out"
  fi
fi

runblock_wf=$(ac5_new_temp)
if ! awk '
  BEGIN { c = 0 }
  {
    print
    if (c == 0 && $0 == "        run: |") {
      print "          if: ${{ always() }}"
      c = 1
    }
  }
  END { if (c != 1) exit 3 }
' "$LIVE_WF" >"$runblock_wf"; then
  bad "could not plant an if inside the run block"
else
  if ! grep -Fqx '          if: ${{ always() }}' "$runblock_wf"; then
    bad "run-block if plant missing from the temp workflow"
  fi
  set +e
  run_out=$(ac5_eval "$runblock_wf")
  run_rc=$?
  set -e
  run_ok=1
  if [[ "$run_rc" -ne 0 ]] || ! ac5_has "$run_out" "ac5-evaluated $runblock_wf" || ! ac5_has "$run_out" "ac5-if backlog $EXPECT_IF"; then
    run_ok=0
  fi
  for line in "${AC5_MATRIX[@]}"; do
    if ! ac5_has "$run_out" "$line"; then
      run_ok=0
    fi
  done
  if [[ "$run_ok" -eq 1 ]]; then
    ok "if inside run: | is not a step condition"
  else
    bad "if inside run: | changed step eligibility (rc=$run_rc)"
    printf '%s\n' "$run_out"
  fi
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "sensor-health.test.sh: $PASS passed, 0 failed"
  exit 0
fi
echo "sensor-health.test.sh: $PASS passed, $FAIL failed"
exit 1
