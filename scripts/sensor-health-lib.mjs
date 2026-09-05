#!/usr/bin/env node
// sensor-health-lib.mjs — #256 classifier + audit.
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
export const SCHEMA_ID = "gibson.sensor-health.observation.v1";
export const SCHEMA_VERSION = "1.0.0";
export const STANDING_ISSUE_NUMBER = 212;
export const DEFAULT_RUN_PAGE_CAP = 5;
export const DEFAULT_PER_PAGE = 100;
export const MIN_RUNS_FOR_BLIND = 3;
/** Official GitHub rerun limit: 30 days after the initial run. */
export const GITHUB_WORKFLOW_RERUN_HORIZON_DAYS = 30;
/** Extra UTC calendar day so date-granular `created` queries cover the exact 30*86400s floor. */
export const FRESHNESS_CREATED_QUERY_SLACK_DAYS = 1;
export const REGISTRY_REL = "config/sensor-health-observation.v1.json";
export const REASON = Object.freeze({
  CURRENT_HEAD_RED: "current-head-red",
  CURRENT_HEAD_ABSENT: "current-head-absent",
  LATEST_NON_SUCCESS: "latest-non-success",
  NEVER_GREEN: "never-green",
  IDLE_WINDOW: "idle-window",
  API_ERROR: "api-error",
  PAGINATION_CAP: "pagination-cap",
  MALFORMED_EVIDENCE: "malformed-evidence",
  POLICY_INVALID: "policy-invalid",
  UNCONFIGURED_WORKFLOW: "unconfigured-workflow",
  CONFIGURED_WORKFLOW_MISSING: "configured-workflow-missing",
  MISSING_TARGET_CHECK: "missing-target-check",
  HEAD_DRIFT: "head-drift",
});
export const STATES = Object.freeze({
  OK: "OK",
  FAILING: "FAILING",
  BLIND: "BLIND",
  IDLE: "IDLE",
  UNKNOWN: "UNKNOWN",
});
const MODES = new Set(["current-head", "freshness", "pr-sample"]);
const NON_SUCCESS = new Set([
  "failure",
  "cancelled",
  "timed_out",
  "action_required",
  "startup_failure",
  "stale",
  "neutral",
  "skipped",
]);
const KNOWN_CONCLUSIONS = new Set(["success", ...NON_SUCCESS]);
const PENDING_STATUSES = new Set([
  "queued",
  "in_progress",
  "waiting",
  "requested",
  "pending",
]);
export const REVIEW_EVIDENCE_WORKFLOW_PATH = ".github/workflows/pr-review-evidence.yml";
export const REVIEW_EVIDENCE_EVENTS = Object.freeze([
  "pull_request_target",
  "issue_comment",
  "schedule",
]);
export const REVIEW_EVIDENCE_WINDOW_DAYS = 1;
export const REQUIRED_REPO_OWNED_PATHS = Object.freeze([
  ".github/workflows/gibson-self-gate.yml",
  ".github/workflows/sensor-health.yml",
  REVIEW_EVIDENCE_WORKFLOW_PATH,
]);
export const PAGES_WORKFLOW_PATH = "dynamic/pages/pages-build-deployment";
export const CHECKED_IN_WORKFLOW_DIR = ".github/workflows";
/**
 * Closed exact path ↔ capability-reason bindings used by inventory.
 * Empty: every checked-in workflow is a standing sensor. A future
 * exclusion is an explicit code/test change that names both the path
 * and the reason; callers cannot supply an allowlist.
 */
export const CHECKED_IN_INVENTORY_EXCLUSIONS = Object.freeze([]);
/** Closed reason vocabulary. A listed reason is not sufficient without an exact path binding. */
export const INVENTORY_CAPABILITY_REASONS = Object.freeze([
  "capability-disabled:has_pages=false",
]);
export function repoRootFromModule(moduleUrl = import.meta.url) {
  return resolve(dirname(fileURLToPath(moduleUrl)), "..");
}
function failRegistry(message, errors = [message]) {
  const err = new Error(message);
  err.code = "E_POLICY";
  err.errors = errors;
  throw err;
}
function requireNonEmptyStringArray(value, loc, errors) {
  if (!Array.isArray(value)) {
    errors.push(`${loc} must be an array when present`);
    return;
  }
  if (value.length === 0) {
    errors.push(`${loc} must be non-empty when present`);
    return;
  }
  if (value.some((x) => typeof x !== "string" || !x)) {
    errors.push(`${loc} entries must be non-empty strings`);
  }
}
function sameStringSet(actual, required) {
  if (!Array.isArray(actual) || actual.length !== required.length) return false;
  if (actual.some((e) => typeof e !== "string" || !e)) return false;
  if (new Set(actual).size !== required.length) return false;
  const got = new Set(actual);
  return required.every((e) => got.has(e));
}
/** Only accepted capability condition: { repoField: "has_pages", equals: true }. */
function assertClosedEnabledWhen(ew, loc, errors) {
  if (!ew || typeof ew !== "object" || Array.isArray(ew)) {
    errors.push(`${loc} must be an object`);
    return;
  }
  const keys = Object.keys(ew);
  if (keys.length !== 2 || !keys.includes("repoField") || !keys.includes("equals")) {
    errors.push(`${loc} must have exactly keys repoField and equals`);
    return;
  }
  if (ew.repoField !== "has_pages") {
    errors.push(`${loc}.repoField must be exactly "has_pages"`);
  }
  if (ew.equals !== true) {
    errors.push(`${loc}.equals must be exactly boolean true`);
  }
}
export function loadRegistryFile(repoRoot, rel = REGISTRY_REL) {
  const abs = join(repoRoot, rel);
  let raw;
  try {
    raw = readFileSync(abs, "utf8");
  } catch (err) {
    const e = new Error(`registry unreadable at ${rel}: ${err.message}`);
    e.code = "E_REGISTRY";
    throw e;
  }
  let doc;
  try {
    doc = JSON.parse(raw);
  } catch (err) {
    const e = new Error(`registry JSON malformed at ${rel}: ${err.message}`);
    e.code = "E_REGISTRY";
    throw e;
  }
  return validateRegistry(doc);
}
export function validateRegistry(doc) {
  const errors = [];
  if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
    return failRegistry("registry must be a JSON object");
  }
  if (doc.schemaId !== SCHEMA_ID) errors.push(`schemaId must be ${SCHEMA_ID}`);
  if (doc.schemaVersion !== SCHEMA_VERSION) {
    errors.push(`schemaVersion must be ${SCHEMA_VERSION}`);
  }
  if (!Array.isArray(doc.policies)) {
    return failRegistry("policies must be an array", errors);
  }
  if (doc.policies.length === 0) errors.push("policies must be non-empty");
  const seen = new Set();
  for (let i = 0; i < doc.policies.length; i++) {
    const p = doc.policies[i];
    const loc = `policies[${i}]`;
    if (!p || typeof p !== "object" || Array.isArray(p)) {
      errors.push(`${loc} must be an object`);
      continue;
    }
    if (typeof p.path !== "string" || !p.path) {
      errors.push(`${loc}.path must be a non-empty string`);
    } else if (seen.has(p.path)) {
      errors.push(`${loc}.path duplicate: ${p.path}`);
    } else {
      seen.add(p.path);
    }
    if (!MODES.has(p.mode)) {
      errors.push(`${loc}.mode must be one of ${[...MODES].join("|")}`);
    }
    if (!Array.isArray(p.events)) {
      errors.push(`${loc}.events must be an array`);
    } else if (p.events.length === 0) {
      errors.push(`${loc}.events must be non-empty (empty list is invalid)`);
    } else if (p.events.some((e) => typeof e !== "string" || !e)) {
      errors.push(`${loc}.events entries must be non-empty strings`);
    }
    if ("windowDays" in p) {
      if (
        typeof p.windowDays !== "number" ||
        !Number.isInteger(p.windowDays) ||
        p.windowDays <= 0
      ) {
        errors.push(`${loc}.windowDays must be a positive integer when present`);
      }
    } else if (p.mode === "freshness" || p.mode === "pr-sample") {
      errors.push(`${loc}.windowDays is required for mode ${p.mode}`);
    }
    if ("targetChecks" in p) requireNonEmptyStringArray(p.targetChecks, `${loc}.targetChecks`, errors);
    if ("targetActors" in p) requireNonEmptyStringArray(p.targetActors, `${loc}.targetActors`, errors);
    if ("enabledWhen" in p) {
      if (p.path !== PAGES_WORKFLOW_PATH) {
        errors.push(`${loc}.enabledWhen is allowed only on ${PAGES_WORKFLOW_PATH}`);
      }
      assertClosedEnabledWhen(p.enabledWhen, `${loc}.enabledWhen`, errors);
    } else if (p.path === PAGES_WORKFLOW_PATH) {
      errors.push(`${loc} Pages policy requires enabledWhen`);
    }
  }
  for (const req of REQUIRED_REPO_OWNED_PATHS) {
    if (!seen.has(req)) errors.push(`missing required repo-owned policy path: ${req}`);
  }
  const selfGate = doc.policies.find((p) => p?.path === ".github/workflows/gibson-self-gate.yml");
  if (selfGate) {
    if (selfGate.mode !== "current-head") errors.push("gibson-self-gate mode must remain current-head");
    if (!Array.isArray(selfGate.events) || selfGate.events.length !== 1 || selfGate.events[0] !== "push") {
      errors.push('gibson-self-gate events must remain exactly ["push"]');
    }
    if (
      !Array.isArray(selfGate.targetChecks) ||
      selfGate.targetChecks.length !== 1 ||
      selfGate.targetChecks[0] !== "sensors"
    ) {
      errors.push('gibson-self-gate targetChecks must remain exactly ["sensors"]');
    }
  }
  const sensorHealth = doc.policies.find((p) => p?.path === ".github/workflows/sensor-health.yml");
  if (sensorHealth) {
    if (sensorHealth.mode !== "freshness") errors.push("sensor-health mode must remain freshness");
    if (sensorHealth.windowDays !== 2) errors.push("sensor-health windowDays must remain 2");
  }
  const reviewEvidence = doc.policies.find((p) => p?.path === REVIEW_EVIDENCE_WORKFLOW_PATH);
  if (reviewEvidence) {
    if (reviewEvidence.mode !== "freshness") {
      errors.push("pr-review-evidence mode must remain freshness");
    }
    if (
      typeof reviewEvidence.windowDays === "number" &&
      Number.isInteger(reviewEvidence.windowDays) &&
      reviewEvidence.windowDays > REVIEW_EVIDENCE_WINDOW_DAYS
    ) {
      errors.push("pr-review-evidence freshness windowDays must not exceed 1");
    } else if (reviewEvidence.windowDays !== REVIEW_EVIDENCE_WINDOW_DAYS) {
      errors.push("pr-review-evidence windowDays must remain 1");
    }
    if (!sameStringSet(reviewEvidence.events, REVIEW_EVIDENCE_EVENTS)) {
      errors.push(
        "pr-review-evidence events must be exactly pull_request_target, issue_comment, and schedule"
      );
    }
  }
  if (errors.length) return failRegistry(errors.join("; "), errors);
  return {
    schemaId: doc.schemaId,
    schemaVersion: doc.schemaVersion,
    policies: doc.policies.map((p) => ({
      path: p.path,
      mode: p.mode,
      events: [...p.events],
      ...(p.windowDays != null ? { windowDays: p.windowDays } : {}),
      ...(p.targetChecks ? { targetChecks: [...p.targetChecks] } : {}),
      ...(p.targetActors ? { targetActors: [...p.targetActors] } : {}),
      ...(p.enabledWhen
        ? { enabledWhen: { repoField: "has_pages", equals: true } }
        : {}),
    })),
  };
}
function unknownCtx(detail, reasonClass) {
  return { ok: false, detail, reasonClass };
}
export function freezeContext({
  repo,
  branch,
  observationTime,
  expectedFullName = null,
}) {
  if (!repo || typeof repo !== "object") {
    return unknownCtx("malformed repo payload", REASON.MALFORMED_EVIDENCE);
  }
  if (!branch || typeof branch !== "object") {
    return unknownCtx("malformed branch payload", REASON.MALFORMED_EVIDENCE);
  }
  const full = repo.full_name;
  const defaultBranch = repo.default_branch;
  const headSha = branch.commit?.sha;
  const branchName = branch.name;
  if (typeof full !== "string" || !full.includes("/")) {
    return unknownCtx("repo.full_name missing", REASON.MALFORMED_EVIDENCE);
  }
  if (typeof expectedFullName === "string" && expectedFullName && full !== expectedFullName) {
    return unknownCtx(
      `repo.full_name ${full} does not equal requested ${expectedFullName}`,
      REASON.MALFORMED_EVIDENCE
    );
  }
  if (typeof defaultBranch !== "string" || !defaultBranch) {
    return unknownCtx("repo.default_branch missing", REASON.MALFORMED_EVIDENCE);
  }
  if (typeof branchName !== "string" || branchName !== defaultBranch) {
    return unknownCtx("branch.name does not match default_branch", REASON.HEAD_DRIFT);
  }
  if (typeof headSha !== "string" || !/^[0-9a-f]{40}$/i.test(headSha)) {
    return unknownCtx("branch.commit.sha missing or malformed", REASON.MALFORMED_EVIDENCE);
  }
  const [owner, name] = full.split("/");
  const ts =
    observationTime instanceof Date
      ? observationTime
      : new Date(observationTime ?? Date.now());
  if (Number.isNaN(ts.getTime())) {
    return unknownCtx("observationTime malformed", REASON.MALFORMED_EVIDENCE);
  }
  let hasPages;
  if (!Object.prototype.hasOwnProperty.call(repo, "has_pages")) {
    hasPages = { ok: false, detail: "repo.has_pages missing" };
  } else if (typeof repo.has_pages !== "boolean") {
    hasPages = { ok: false, detail: "repo.has_pages non-boolean" };
  } else {
    hasPages = { ok: true, value: repo.has_pages };
  }
  return {
    ok: true,
    owner,
    repo: name,
    fullName: full,
    defaultBranch,
    headSha: headSha.toLowerCase(),
    observationTime: ts,
    observationTimeIso: ts.toISOString(),
    hasPages,
  };
}
export function joinPolicies(activeWorkflows, policies) {
  const active = Array.isArray(activeWorkflows) ? activeWorkflows : [];
  const pathCounts = new Map();
  const activeByPath = new Map();
  const rows = [];
  const unmatchedPolicies = [];
  for (const wf of active) {
    if (!wf || typeof wf !== "object") {
      rows.push({
        name: "(malformed)",
        path: "",
        workflowId: null,
        policy: null,
        joinError: REASON.MALFORMED_EVIDENCE,
      });
      continue;
    }
    // Missing/empty/non-string state is malformed, never silently active.
    if (typeof wf.state !== "string" || !wf.state) {
      rows.push({
        name: wf.name ?? "(malformed)",
        path: typeof wf.path === "string" ? wf.path : String(wf.path ?? ""),
        workflowId: wf.id ?? null,
        policy: null,
        joinError: REASON.MALFORMED_EVIDENCE,
      });
      continue;
    }
    // Exact non-active string => inactive, ignored by the active join.
    if (wf.state !== "active") continue;
    if (typeof wf.path !== "string" || !wf.path) {
      rows.push({
        name: wf.name ?? "(malformed)",
        path: String(wf.path ?? ""),
        workflowId: wf.id ?? null,
        policy: null,
        joinError: REASON.MALFORMED_EVIDENCE,
      });
      continue;
    }
    if (wf.id == null || !Number.isFinite(Number(wf.id))) {
      rows.push({
        name: wf.name ?? "(malformed)",
        path: wf.path,
        workflowId: wf.id ?? null,
        policy: null,
        joinError: REASON.MALFORMED_EVIDENCE,
      });
      continue;
    }
    pathCounts.set(wf.path, (pathCounts.get(wf.path) || 0) + 1);
    if (!activeByPath.has(wf.path)) activeByPath.set(wf.path, wf);
  }
  const duplicatePaths = new Set(
    [...pathCounts.entries()].filter(([, n]) => n > 1).map(([p]) => p)
  );
  for (const policy of policies) {
    const wf = activeByPath.get(policy.path);
    if (!wf) {
      unmatchedPolicies.push(policy);
      rows.push({
        name: policy.path,
        path: policy.path,
        workflowId: null,
        policy,
        joinError: REASON.CONFIGURED_WORKFLOW_MISSING,
      });
      continue;
    }
    if (duplicatePaths.has(policy.path)) {
      rows.push({
        name: wf.name ?? policy.path,
        path: policy.path,
        workflowId: wf.id,
        policy,
        joinError: REASON.MALFORMED_EVIDENCE,
      });
      activeByPath.delete(policy.path);
      duplicatePaths.delete(policy.path);
      continue;
    }
    rows.push({
      name: wf.name ?? policy.path,
      path: policy.path,
      workflowId: wf.id,
      policy,
      joinError: null,
    });
    activeByPath.delete(policy.path);
  }
  for (const [, wf] of activeByPath) {
    rows.push({
      name: wf.name ?? wf.path,
      path: wf.path,
      workflowId: wf.id,
      policy: null,
      joinError:
        pathCounts.get(wf.path) > 1
          ? REASON.MALFORMED_EVIDENCE
          : REASON.UNCONFIGURED_WORKFLOW,
    });
  }
  return { rows, unmatchedPolicies };
}
/**
 * Evaluate closed enabledWhen before the bidirectional join.
 * Exact has_pages:false => exclusion; true => enabled; non-boolean/missing => UNKNOWN.
 */
export function evaluateCapabilities(policies, hasPages) {
  const enabled = [];
  const exclusions = [];
  const capabilityUnknown = [];
  for (const policy of policies) {
    if (!policy.enabledWhen) {
      enabled.push(policy);
      continue;
    }
    if (!hasPages || !hasPages.ok) {
      capabilityUnknown.push({
        path: policy.path,
        name: policy.path,
        detail: hasPages?.detail || "capability evidence unreadable",
        reasonClass: REASON.MALFORMED_EVIDENCE,
      });
      continue;
    }
    if (hasPages.value === true) {
      enabled.push(policy);
    } else {
      exclusions.push({
        path: policy.path,
        name: policy.path,
        evidence: "repo.has_pages=false",
      });
    }
  }
  return { enabled, exclusions, capabilityUnknown };
}
function isExactExclusionBinding(entry, bindings) {
  return bindings.some(
    (b) => b.path === entry.path && b.capabilityReason === entry.capabilityReason
  );
}
export function validateInventoryExclusions(exclusions) {
  if (!Array.isArray(exclusions)) {
    return failRegistry("inventory exclusions must be an array");
  }
  const errors = [];
  const seen = new Set();
  const required = new Set(REQUIRED_REPO_OWNED_PATHS);
  const allowedReasons = new Set(INVENTORY_CAPABILITY_REASONS);
  const allowedBindings = CHECKED_IN_INVENTORY_EXCLUSIONS;
  for (let i = 0; i < exclusions.length; i++) {
    const x = exclusions[i];
    const loc = `inventoryExclusions[${i}]`;
    if (!x || typeof x !== "object" || Array.isArray(x)) {
      errors.push(`${loc} must be an object`);
      continue;
    }
    let pathOk = false;
    if (typeof x.path !== "string" || !x.path) {
      errors.push(`${loc}.path must be a non-empty string`);
    } else if (seen.has(x.path)) {
      errors.push(`${loc}.path duplicate: ${x.path}`);
    } else if (required.has(x.path)) {
      errors.push(`${loc}.path cannot exclude required sensor ${x.path}`);
    } else {
      seen.add(x.path);
      pathOk = true;
    }
    const reasonOk =
      typeof x.capabilityReason === "string" && allowedReasons.has(x.capabilityReason);
    if (!reasonOk) {
      errors.push(`${loc}.capabilityReason must be a tested closed capability reason`);
    } else if (pathOk && !isExactExclusionBinding(x, allowedBindings)) {
      errors.push(
        `${loc} must bind an exact tested workflow path to its exact capability reason`
      );
    }
  }
  if (errors.length) return failRegistry(errors.join("; "), errors);
  return exclusions.map((x) => ({ path: x.path, capabilityReason: x.capabilityReason }));
}
export function discoverCheckedInWorkflows(repoRoot) {
  const dir = join(repoRoot, CHECKED_IN_WORKFLOW_DIR);
  let ents;
  try {
    ents = readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    const e = new Error(
      `checked-in workflow directory unreadable at ${CHECKED_IN_WORKFLOW_DIR}: ${err.message}`
    );
    e.code = "E_INVENTORY";
    throw e;
  }
  const files = [];
  for (const ent of ents) {
    if (!ent.isFile() && !ent.isSymbolicLink()) continue;
    if (!/\.ya?ml$/i.test(ent.name)) continue;
    files.push(`${CHECKED_IN_WORKFLOW_DIR}/${ent.name}`);
  }
  files.sort();
  return files;
}
export function inventoryCheckedInWorkflows({
  checkedInPaths,
  policies,
  exclusions = CHECKED_IN_INVENTORY_EXCLUSIONS,
} = {}) {
  if (!Array.isArray(checkedInPaths)) {
    return failRegistry("checked-in workflow inventory paths must be an array");
  }
  const validated = validateInventoryExclusions(exclusions);
  const excluded = new Set(validated.map((e) => e.path));
  const active = [];
  for (let i = 0; i < checkedInPaths.length; i++) {
    const path = checkedInPaths[i];
    if (typeof path !== "string" || !path) {
      active.push({
        id: i + 1,
        name: "(malformed)",
        path: String(path ?? ""),
        state: "active",
      });
      continue;
    }
    if (excluded.has(path)) continue;
    active.push({
      id: i + 1,
      name: path,
      path,
      state: "active",
    });
  }
  const repoOwned = (policies || []).filter(
    (p) => typeof p?.path === "string" && p.path.startsWith(`${CHECKED_IN_WORKFLOW_DIR}/`)
  );
  return joinPolicies(active, repoOwned);
}
function hasPagesFrozenEqual(a, b) {
  if (!a?.ok && !b?.ok) return (a?.detail || "") === (b?.detail || "");
  if (!a?.ok || !b?.ok) return false;
  return a.value === b.value;
}
/** Only exact-path exact-active well-formed items may be capability-suppressed. */
function isWellFormedActiveWorkflow(wf) {
  return (
    !!wf &&
    typeof wf === "object" &&
    typeof wf.state === "string" &&
    wf.state === "active" &&
    typeof wf.path === "string" &&
    !!wf.path &&
    wf.id != null &&
    Number.isFinite(Number(wf.id))
  );
}
export function compareUpdatedAtThenId(a, b) {
  const ta = Date.parse(a?.updated_at ?? "");
  const tb = Date.parse(b?.updated_at ?? "");
  const aOk = !Number.isNaN(ta);
  const bOk = !Number.isNaN(tb);
  if (aOk && bOk && ta !== tb) return tb - ta;
  if (aOk !== bOk) return aOk ? -1 : 1;
  const ida = Number(a?.id);
  const idb = Number(b?.id);
  if (Number.isFinite(ida) && Number.isFinite(idb) && ida !== idb) return idb - ida;
  return 0;
}
export function selectLatestRun(runs) {
  return Array.isArray(runs) && runs.length
    ? [...runs].sort(compareUpdatedAtThenId)[0] ?? null
    : null;
}
function actorLogin(run) {
  return run?.actor?.login ?? run?.triggering_actor?.login ?? null;
}
export function isExemptNonTargetSkip(run, policy) {
  if (!policy?.targetActors) return false;
  if (run?.status !== "completed") return false;
  if (typeof run?.event !== "string" || !policy.events.includes(run.event)) return false;
  const conclusion = run?.conclusion;
  if (conclusion !== "skipped" && conclusion !== "neutral") return false;
  const login = actorLogin(run);
  return typeof login === "string" && !policy.targetActors.includes(login);
}
function inWindow(run, policy, ctx) {
  const updated = Date.parse(run?.updated_at ?? "");
  if (Number.isNaN(updated)) return null;
  return updated >= ctx.observationTime.getTime() - (policy.windowDays ?? 0) * 86400_000;
}
export function assessRun(
  run,
  policy,
  ctx,
  { enforceHead = false, enforceWindow = false } = {}
) {
  if (!run || typeof run !== "object") {
    return { kind: "malformed", detail: "run is not an object" };
  }
  const eventOk = typeof run.event === "string" && policy.events.includes(run.event);
  if (typeof run.event === "string" && !policy.events.includes(run.event)) {
    return { kind: "irrelevant", detail: "event mismatch" };
  }
  const needHead = enforceHead || policy.mode === "current-head";
  const needWindow = enforceWindow || policy.mode === "freshness" || policy.mode === "pr-sample";
  if (needHead) {
    if (typeof run.head_sha === "string" && run.head_sha && ctx?.headSha) {
      if (run.head_sha.toLowerCase() !== ctx.headSha) {
        return { kind: "irrelevant", detail: "head sha mismatch" };
      }
    }
    if (typeof run.head_branch === "string" && run.head_branch && ctx?.defaultBranch) {
      if (run.head_branch !== ctx.defaultBranch) {
        return { kind: "irrelevant", detail: "head branch mismatch" };
      }
    }
  }
  if (!eventOk) {
    return { kind: "malformed", detail: "missing/malformed event on relevant run" };
  }
  if (typeof run.status !== "string" || !run.status) {
    return { kind: "malformed", detail: "missing/malformed status" };
  }
  if (needWindow) {
    if (typeof run.updated_at !== "string" || Number.isNaN(Date.parse(run.updated_at))) {
      return { kind: "malformed", detail: "missing/malformed updated_at" };
    }
    if (inWindow(run, policy, ctx) !== true) {
      return { kind: "irrelevant", detail: "outside window" };
    }
  }
  if (isExemptNonTargetSkip(run, policy)) {
    return { kind: "irrelevant", detail: "exempt non-target skip" };
  }
  if (typeof run.updated_at !== "string" || Number.isNaN(Date.parse(run.updated_at))) {
    return { kind: "malformed", detail: "missing/malformed updated_at" };
  }
  if (needHead) {
    if (typeof run.head_sha !== "string" || !run.head_sha) {
      return { kind: "malformed", detail: "missing/malformed head_sha" };
    }
    if (run.head_sha.toLowerCase() !== ctx.headSha) {
      return { kind: "irrelevant", detail: "head sha mismatch" };
    }
    if (typeof run.head_branch !== "string" || run.head_branch !== ctx.defaultBranch) {
      return { kind: "malformed", detail: "missing/malformed head_branch" };
    }
  }
  if (PENDING_STATUSES.has(run.status)) {
    return { kind: "pending", detail: `status=${run.status}` };
  }
  if (run.status !== "completed") {
    return { kind: "malformed", detail: `unrecognized status ${run.status}` };
  }
  if (typeof run.conclusion !== "string" || !run.conclusion) {
    return { kind: "malformed", detail: "missing/malformed conclusion" };
  }
  if (!KNOWN_CONCLUSIONS.has(run.conclusion)) {
    return { kind: "malformed", detail: `unknown conclusion ${run.conclusion}` };
  }
  if (run.id == null || !Number.isFinite(Number(run.id))) {
    return { kind: "malformed", detail: "missing/malformed id" };
  }
  return { kind: "qualifying", detail: null };
}
export function partitionRuns(runs, policy, ctx, opts) {
  const qualifying = [];
  const pending = [];
  const malformed = [];
  for (const run of runs || []) {
    const a = assessRun(run, policy, ctx, opts);
    if (a.kind === "qualifying") qualifying.push(run);
    else if (a.kind === "pending") pending.push(run);
    else if (a.kind === "malformed") malformed.push({ run, detail: a.detail });
  }
  return { qualifying, pending, malformed };
}
function runEvidenceFields(run) {
  if (!run) {
    return { selectedRunId: null, headSha: null, conclusion: null, updatedAt: null };
  }
  return {
    selectedRunId: run.id ?? null,
    headSha: run.head_sha ?? null,
    conclusion: run.conclusion ?? null,
    updatedAt: run.updated_at ?? null,
  };
}
function rowResult({
  name,
  path,
  mode,
  state,
  reasonClass,
  detail,
  run = null,
  selectedJobIds = null,
}) {
  return {
    name,
    path,
    mode: mode ?? null,
    state,
    reasonClass,
    detail,
    selectedJobIds,
    ...runEvidenceFields(run),
  };
}
export function evaluateTargetJobs(jobs, targetChecks) {
  if (!Array.isArray(targetChecks) || targetChecks.length === 0) {
    return { ok: true, selectedJobIds: [], reasonClass: null, detail: null, failing: false };
  }
  if (!Array.isArray(jobs)) {
    return {
      ok: false,
      selectedJobIds: [],
      reasonClass: REASON.MALFORMED_EVIDENCE,
      detail: "jobs payload malformed",
      failing: false,
    };
  }
  const selectedJobIds = [];
  for (const check of targetChecks) {
    const matches = jobs.filter((j) => j && j.name === check);
    if (matches.length !== 1) {
      return {
        ok: false,
        selectedJobIds,
        reasonClass: REASON.MISSING_TARGET_CHECK,
        detail:
          matches.length === 0
            ? `target job ${check} missing`
            : `target job ${check} ambiguous (${matches.length} matches)`,
        failing: false,
      };
    }
    const job = matches[0];
    if (job.id == null || !Number.isFinite(Number(job.id))) {
      return {
        ok: false,
        selectedJobIds,
        reasonClass: REASON.MALFORMED_EVIDENCE,
        detail: `target job ${check} missing/malformed id`,
        failing: false,
      };
    }
    selectedJobIds.push(job.id);
    if (typeof job.status !== "string" || !job.status) {
      return {
        ok: false,
        selectedJobIds,
        reasonClass: REASON.MALFORMED_EVIDENCE,
        detail: `target job ${check} missing/malformed status`,
        failing: false,
      };
    }
    if (job.status !== "completed") {
      return {
        ok: false,
        selectedJobIds,
        reasonClass: PENDING_STATUSES.has(job.status)
          ? REASON.MISSING_TARGET_CHECK
          : REASON.MALFORMED_EVIDENCE,
        detail: `target job ${check} status=${job.status}`,
        failing: false,
      };
    }
    if (typeof job.conclusion !== "string" || !job.conclusion) {
      return {
        ok: false,
        selectedJobIds,
        reasonClass: REASON.MALFORMED_EVIDENCE,
        detail: `target job ${check} missing/malformed conclusion`,
        failing: false,
      };
    }
    if (!KNOWN_CONCLUSIONS.has(job.conclusion)) {
      return {
        ok: false,
        selectedJobIds,
        reasonClass: REASON.MALFORMED_EVIDENCE,
        detail: `target job ${check} unknown conclusion ${job.conclusion}`,
        failing: false,
      };
    }
    if (job.conclusion !== "success") {
      return {
        ok: false,
        selectedJobIds,
        reasonClass: REASON.LATEST_NON_SUCCESS,
        detail: `target job ${check} conclusion=${job.conclusion}`,
        failing: true,
        conclusion: job.conclusion,
      };
    }
  }
  return { ok: true, selectedJobIds, reasonClass: null, detail: null, failing: false };
}
export function classifySensor({
  name,
  path,
  policy,
  runs,
  jobs = null,
  ctx,
  evidenceComplete = true,
  apiError = null,
  capExhausted = false,
  joinError = null,
}) {
  if (joinError) {
    return rowResult({
      name,
      path,
      mode: policy?.mode,
      state: STATES.UNKNOWN,
      reasonClass: joinError,
      detail: joinError,
    });
  }
  if (apiError) {
    return rowResult({
      name,
      path,
      mode: policy?.mode,
      state: STATES.UNKNOWN,
      reasonClass: REASON.API_ERROR,
      detail: String(apiError),
    });
  }
  if (!policy) {
    return rowResult({
      name,
      path,
      mode: null,
      state: STATES.UNKNOWN,
      reasonClass: REASON.UNCONFIGURED_WORKFLOW,
      detail: "active workflow has no observation policy",
    });
  }
  if (!ctx?.ok) {
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.UNKNOWN,
      reasonClass: ctx?.reasonClass ?? REASON.MALFORMED_EVIDENCE,
      detail: ctx?.detail ?? "observation context invalid",
    });
  }
  if (capExhausted && !evidenceComplete) {
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.UNKNOWN,
      reasonClass: REASON.PAGINATION_CAP,
      detail: "pagination cap reached before evidence complete",
    });
  }
  if (!evidenceComplete) {
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.UNKNOWN,
      reasonClass: REASON.MALFORMED_EVIDENCE,
      detail: "evidence incomplete",
    });
  }
  if (!Array.isArray(runs)) {
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.UNKNOWN,
      reasonClass: REASON.MALFORMED_EVIDENCE,
      detail: "runs payload malformed",
    });
  }
  if (policy.mode === "current-head") {
    return classifyCurrentHead({ name, path, policy, runs, jobs, ctx });
  }
  if (policy.mode === "freshness") {
    return classifyWindowed({ name, path, policy, runs, ctx, allowBlind: false });
  }
  if (policy.mode === "pr-sample") {
    return classifyWindowed({ name, path, policy, runs, ctx, allowBlind: true });
  }
  return rowResult({
    name,
    path,
    mode: policy.mode,
    state: STATES.UNKNOWN,
    reasonClass: REASON.POLICY_INVALID,
    detail: `unsupported mode ${policy.mode}`,
  });
}
function partitionBlock({
  name,
  path,
  policy,
  malformed,
  pending,
  qualifying,
  currentHead,
}) {
  if (malformed.length > 0) {
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.UNKNOWN,
      reasonClass: REASON.MALFORMED_EVIDENCE,
      detail: malformed[0].detail,
    });
  }
  if (qualifying.length > 0) return null;
  if (currentHead) {
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.UNKNOWN,
      reasonClass: pending.length ? REASON.MALFORMED_EVIDENCE : REASON.CURRENT_HEAD_ABSENT,
      detail: pending.length
        ? "current-head has incomplete non-completed run evidence"
        : "no completed qualifying run for current default-branch head",
    });
  }
  if (pending.length > 0) {
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.UNKNOWN,
      reasonClass: REASON.MALFORMED_EVIDENCE,
      detail: "in-window non-completed run without qualifying completed evidence",
    });
  }
  return rowResult({
    name,
    path,
    mode: policy.mode,
    state: STATES.IDLE,
    reasonClass: REASON.IDLE_WINDOW,
    detail: `no qualifying completed run in ${policy.windowDays}d window`,
  });
}
function classifyCurrentHead({ name, path, policy, runs, jobs, ctx }) {
  const { qualifying, pending, malformed } = partitionRuns(runs, policy, ctx, {
    enforceHead: true,
    enforceWindow: false,
  });
  const blocked = partitionBlock({ name, path, policy, malformed, pending, qualifying, currentHead: true });
  if (blocked) return blocked;
  const latest = selectLatestRun(qualifying);
  if (policy.targetChecks) {
    const jobEval = evaluateTargetJobs(jobs, policy.targetChecks);
    if (!jobEval.ok && !jobEval.failing) {
      return rowResult({
        name,
        path,
        mode: policy.mode,
        state: STATES.UNKNOWN,
        reasonClass: jobEval.reasonClass,
        detail: jobEval.detail,
        run: latest,
        selectedJobIds: jobEval.selectedJobIds,
      });
    }
    if (jobEval.failing || latest.conclusion !== "success") {
      return rowResult({
        name,
        path,
        mode: policy.mode,
        state: STATES.FAILING,
        reasonClass: REASON.CURRENT_HEAD_RED,
        detail: jobEval.failing
          ? jobEval.detail
          : `workflow conclusion ${latest.conclusion}`,
        run: latest,
        selectedJobIds: jobEval.selectedJobIds,
      });
    }
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.OK,
      reasonClass: null,
      detail: `current head green; jobs ${policy.targetChecks.join(",")}`,
      run: latest,
      selectedJobIds: jobEval.selectedJobIds,
    });
  }
  if (latest.conclusion === "success") {
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.OK,
      reasonClass: null,
      detail: "current head green",
      run: latest,
    });
  }
  return rowResult({
    name,
    path,
    mode: policy.mode,
    state: STATES.FAILING,
    reasonClass: REASON.CURRENT_HEAD_RED,
    detail: `current head conclusion ${latest.conclusion}`,
    run: latest,
  });
}
function classifyWindowed({ name, path, policy, runs, ctx, allowBlind }) {
  const { qualifying, pending, malformed } = partitionRuns(runs, policy, ctx, {
    enforceHead: false,
    enforceWindow: true,
  });
  const blocked = partitionBlock({
    name,
    path,
    policy,
    malformed,
    pending,
    qualifying,
    currentHead: false,
  });
  if (blocked) return blocked;
  const latest = selectLatestRun(qualifying);
  const successes = qualifying.filter((r) => r.conclusion === "success");
  if (allowBlind && qualifying.length >= MIN_RUNS_FOR_BLIND && successes.length === 0) {
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.BLIND,
      reasonClass: REASON.NEVER_GREEN,
      detail: `${qualifying.length} qualifying completed runs, never green`,
      run: latest,
    });
  }
  if (latest.conclusion === "success") {
    return rowResult({
      name,
      path,
      mode: policy.mode,
      state: STATES.OK,
      reasonClass: null,
      detail: `last green ${String(latest.updated_at).slice(0, 10)}`,
      run: latest,
    });
  }
  return rowResult({
    name,
    path,
    mode: policy.mode,
    state: STATES.FAILING,
    reasonClass: REASON.LATEST_NON_SUCCESS,
    detail: `latest conclusion ${latest.conclusion}`,
    run: latest,
  });
}
function findingsFromRows(rows) {
  return rows.filter((r) => r.state !== STATES.OK);
}
export function buildFingerprint(rows) {
  return buildFingerprintWithExclusions(rows, []);
}
export function buildFingerprintWithExclusions(rows, exclusions = []) {
  const findings = findingsFromRows(rows);
  if (findings.length === 0 && (!exclusions || exclusions.length === 0)) return "clean";
  return [
    ...findings.map((f) => `${f.state}:${f.path}:${f.reasonClass ?? "none"}`),
    ...(exclusions || []).map((e) => `EXCLUDED:${e.path}:${e.evidence}`),
  ]
    .sort()
    .join("|");
}
export function shouldComment(previousBody, fingerprint) {
  const prev = String(previousBody || "").match(/<!-- sensor-health-fingerprint: (.*) -->/);
  return !prev || prev[1] !== fingerprint;
}
const ICON = { BLIND: "🔴", FAILING: "🟠", IDLE: "⚪", OK: "🟢", UNKNOWN: "🟣" };
export function renderIssueBody(report) {
  const { context, rows, fingerprint, budget, exclusions = [] } = report;
  const findings = findingsFromRows(rows);
  const exclusionLines =
    exclusions.length === 0
      ? []
      : [
          "",
          "## Excluded (capability disabled)",
          ...exclusions
            .slice()
            .sort((a, b) => a.path.localeCompare(b.path))
            .map((e) => `- \`${e.path}\` — ${e.evidence}`),
        ];
  const allClear =
    findings.length === 0
      ? exclusions.length === 0
        ? "**All configured/active sensors are OK.**"
        : "**All expected sensors are OK.** Capability-disabled exclusions are listed below."
      : `**${findings.length} sensor(s) need attention.** IDLE is informational but not OK; UNKNOWN is fail-closed.`;
  return [
    `Sensor-health audit for \`${context.fullName}\` — default branch \`${context.defaultBranch}\` @ \`${context.headSha}\`.`,
    "",
    `Observation time: \`${context.observationTimeIso}\` (frozen).`,
    "",
    "States: **OK** only on exact latest qualifying success; older greens never override current-head red. **UNKNOWN** means incomplete or ambiguous evidence.",
    "",
    "| Sensor | State | Reason | Run | Head | Conclusion | Updated | Detail |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ...rows.map((r) => {
      const icon = ICON[r.state] ?? "❓";
      return `| ${r.name} (\`${r.path}\`) | ${icon} ${r.state} | ${r.reasonClass ?? "—"} | ${r.selectedRunId ?? "—"} | \`${r.headSha ?? "—"}\` | ${r.conclusion ?? "—"} | ${r.updatedAt ?? "—"} | ${r.detail} |`;
    }),
    "",
    allClear,
    ...exclusionLines,
    "",
    `Budget: requests=${budget.requests} pages=${budget.pages} capsHit=${budget.capsHit} cacheHits=${budget.cacheHits}.`,
    "",
    `<!-- sensor-health-fingerprint: ${fingerprint} -->`,
  ].join("\n");
}
function createBudget() {
  return { requests: 0, pages: 0, capsHit: 0, cacheHits: 0 };
}
/** True only for checked-in `.github/workflows` freshness policies, never dynamic/pseudo sensors. */
export function isCheckedInRepoOwnedFreshnessPolicy(policy) {
  return (
    !!policy &&
    policy.mode === "freshness" &&
    typeof policy.path === "string" &&
    policy.path.startsWith(`${CHECKED_IN_WORKFLOW_DIR}/`)
  );
}

/** UTC date of observationTime minus windowDays (local freshness window date, not the server query). */
export function freshnessCreatedQueryFloor(observationTime, windowDays) {
  const ts = observationTime instanceof Date ? observationTime : new Date(observationTime);
  const days = Number.isInteger(windowDays) && windowDays > 0 ? windowDays : 0;
  return new Date(ts.getTime() - days * 86400_000).toISOString().slice(0, 10);
}

function utcDateString(instant) {
  const ts = instant instanceof Date ? instant : new Date(instant);
  if (Number.isNaN(ts.getTime())) return null;
  return ts.toISOString().slice(0, 10);
}

function nextUtcDate(dateStr) {
  const t = Date.parse(`${dateStr}T00:00:00.000Z`);
  if (Number.isNaN(t)) return null;
  return new Date(t + 86400_000).toISOString().slice(0, 10);
}

/** Created-time lookback that covers windowDays + GitHub rerun horizon + date-floor slack. */
export function freshnessCreatedQueryLookbackDays(windowDays) {
  const days = Number.isInteger(windowDays) && windowDays > 0 ? windowDays : 0;
  return days + GITHUB_WORKFLOW_RERUN_HORIZON_DAYS + FRESHNESS_CREATED_QUERY_SLACK_DAYS;
}

/**
 * Disjoint per-UTC-day `created` shards covering every run that can still have
 * `updated_at` inside the local freshness window (rerunnable horizon + slack).
 */
export function freshnessCreatedQueryShards(observationTime, windowDays) {
  const end = utcDateString(observationTime);
  if (!end) return [];
  const ts = observationTime instanceof Date ? observationTime : new Date(observationTime);
  const start = new Date(ts.getTime() - freshnessCreatedQueryLookbackDays(windowDays) * 86400_000)
    .toISOString()
    .slice(0, 10);
  if (start > end) return [];
  const shards = [];
  for (let d = start; d && d <= end; d = nextUtcDate(d)) {
    shards.push({ created: d });
  }
  return shards;
}

/** Deterministic by numeric id: keep the record that sorts first by updated_at then id. */
export function mergeWorkflowRunsById(runs) {
  const byId = new Map();
  const withoutId = [];
  for (const run of runs || []) {
    const id = Number(run?.id);
    if (!run || typeof run !== "object" || !Number.isFinite(id)) {
      withoutId.push(run);
      continue;
    }
    const prev = byId.get(id);
    if (prev === undefined || compareUpdatedAtThenId(run, prev) < 0) {
      byId.set(id, run);
    }
  }
  return [...byId.values(), ...withoutId];
}

export async function paginateList({
  fetchPage,
  perPage = DEFAULT_PER_PAGE,
  capPages = DEFAULT_RUN_PAGE_CAP,
}) {
  const items = [];
  let page = 1;
  let capExhausted = false;
  let complete = false;
  while (page <= capPages) {
    const { items: batch, incomplete } = await fetchPage(page, perPage);
    const list = Array.isArray(batch) ? batch : null;
    if (list == null) {
      const err = new Error("list page malformed");
      err.code = "E_MALFORMED";
      throw err;
    }
    items.push(...list);
    if (list.length < perPage) {
      complete = true;
      break;
    }
    if (incomplete || page === capPages) {
      capExhausted = true;
      break;
    }
    page += 1;
  }
  return { items, pagesRead: Math.min(page, capPages), capExhausted, complete };
}
function exitCodeForRows(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return 1;
  return rows.every((r) => r.state === STATES.OK) ? 0 : 1;
}
export function buildReport({ context, rows, budget }) {
  return buildReportWithExclusions({ context, rows, budget, exclusions: [] });
}
export function buildReportWithExclusions({ context, rows, budget, exclusions = [] }) {
  const fingerprint = buildFingerprintWithExclusions(rows, exclusions);
  return {
    context,
    rows,
    exclusions,
    fingerprint,
    budget: { ...budget },
    body: renderIssueBody({ context, rows, fingerprint, budget, exclusions }),
    exitCode: exitCodeForRows(rows),
  };
}
function createGhClient({ token, fetchImpl, budget, apiBase = "https://api.github.com" }) {
  return async function gh(path, init = {}) {
    budget.requests += 1;
    const res = await fetchImpl(`${apiBase}${path}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        ...(init.headers || {}),
      },
    });
    if (!res.ok) {
      const body = await res.text();
      const err = new Error(
        `${init.method || "GET"} ${path} -> ${res.status}: ${String(body).slice(0, 200)}`
      );
      err.code = "E_API";
      err.status = res.status;
      throw err;
    }
    if (init.method && init.method !== "GET") {
      const text = await res.text();
      if (!text) return null;
      try {
        return JSON.parse(text);
      } catch {
        return null;
      }
    }
    return res.json();
  };
}
async function postStandingIssue({
  gh,
  repository,
  issueNumber,
  report,
  hardExitCode = null,
}) {
  try {
    const issue = await gh(`/repos/${repository}/issues/${issueNumber}`);
    if (!issue || issue.pull_request) {
      return {
        report,
        posted: false,
        commented: false,
        issueNumber,
        exitCode: 1,
        postError: `standing issue #${issueNumber} not reachable`,
      };
    }
    if (issue.state === "closed") {
      await gh(`/repos/${repository}/issues/${issueNumber}`, {
        method: "PATCH",
        body: JSON.stringify({ state: "open" }),
      });
    }
    const commented = shouldComment(issue.body, report.fingerprint);
    await gh(`/repos/${repository}/issues/${issueNumber}`, {
      method: "PATCH",
      body: JSON.stringify({ body: report.body }),
    });
    if (commented) {
      const findings = findingsFromRows(report.rows);
      const exclusions = report.exclusions || [];
      let delta;
      if (findings.length === 0 && exclusions.length === 0) {
        delta = "All previously reported sensors are healthy again. ✅";
      } else if (findings.length === 0) {
        const listed = exclusions
          .slice()
          .sort((a, b) => a.path.localeCompare(b.path))
          .map((e) => `${e.path} (${e.evidence})`)
          .join("; ");
        delta = `All expected sensors are OK. Excluded (capability disabled): ${listed}.`;
      } else {
        delta = `Finding set changed. Current: ${findings
          .map((f) => `${f.state} ${f.path} (${f.reasonClass})`)
          .join("; ")}.`;
      }
      await gh(`/repos/${repository}/issues/${issueNumber}/comments`, {
        method: "POST",
        body: JSON.stringify({ body: delta }),
      });
    }
    return {
      report,
      posted: true,
      commented,
      issueNumber,
      exitCode: hardExitCode ?? report.exitCode,
    };
  } catch (err) {
    return {
      report,
      posted: false,
      commented: false,
      issueNumber,
      exitCode: 1,
      postError: err.message || String(err),
    };
  }
}
function requireWorkflowRuns(data) {
  if (!data || !Array.isArray(data.workflow_runs)) {
    const err = new Error("workflow_runs payload malformed");
    err.code = "E_MALFORMED";
    throw err;
  }
  return data.workflow_runs;
}
function requireJobs(data) {
  if (!data || !Array.isArray(data.jobs)) {
    const err = new Error("jobs payload malformed");
    err.code = "E_MALFORMED";
    throw err;
  }
  return data.jobs;
}
export async function runSensorHealthAudit({
  token,
  repository,
  registry,
  fetchImpl = globalThis.fetch,
  observationTime = new Date(),
  post = false,
  issueNumber = STANDING_ISSUE_NUMBER,
  runPageCap = DEFAULT_RUN_PAGE_CAP,
  perPage = DEFAULT_PER_PAGE,
  maxHeadRetries = 1,
}) {
  if (!token) {
    const err = new Error("GITHUB_TOKEN is required");
    err.code = "E_ENV";
    throw err;
  }
  if (!repository || !String(repository).includes("/")) {
    const err = new Error("GITHUB_REPOSITORY must be owner/repo");
    err.code = "E_ENV";
    throw err;
  }
  const budget = createBudget();
  const jobCache = new Map();
  const obsTime =
    observationTime instanceof Date ? observationTime : new Date(observationTime);
  const gh = createGhClient({ token, fetchImpl, budget });
  async function observeHead() {
    const repo = await gh(`/repos/${repository}`);
    const branch = await gh(
      `/repos/${repository}/branches/${encodeURIComponent(repo.default_branch)}`
    );
    return freezeContext({
      repo,
      branch,
      observationTime: obsTime,
      expectedFullName: repository,
    });
  }
  function unknownReport(reasonClass, detail, ctx) {
    return buildReport({
      context: {
        fullName: repository,
        defaultBranch: ctx?.defaultBranch || "?",
        headSha: ctx?.headSha || "?",
        observationTimeIso: obsTime.toISOString(),
      },
      rows: [
        rowResult({
          name: repository,
          path: "(audit)",
          mode: null,
          state: STATES.UNKNOWN,
          reasonClass,
          detail,
        }),
      ],
      budget,
    });
  }
  async function finish(report, { hardFail = false } = {}) {
    const exitCode = hardFail ? 1 : report.exitCode;
    if (!post) {
      return { report, posted: false, commented: false, issueNumber, exitCode };
    }
    return postStandingIssue({
      gh,
      repository,
      issueNumber,
      report: { ...report, exitCode },
      hardExitCode: exitCode,
    });
  }
  async function paginateWorkflowField(pathBuilder, fieldRequire) {
    return paginateList({
      perPage,
      capPages: runPageCap,
      fetchPage: async (page, pp) => {
        budget.pages += 1;
        const data = await gh(pathBuilder(page, pp));
        return { items: fieldRequire(data), incomplete: false };
      },
    });
  }
  let attempts = 0;
  const maxAttempts = 1 + Math.max(0, maxHeadRetries);
  while (attempts < maxAttempts) {
    attempts += 1;
    let ctx;
    try {
      ctx = await observeHead();
    } catch (err) {
      return finish(unknownReport(REASON.API_ERROR, err.message || String(err), null), {
        hardFail: true,
      });
    }
    if (!ctx.ok) {
      return finish(unknownReport(ctx.reasonClass, ctx.detail, null), { hardFail: true });
    }
    let wfPages;
    try {
      wfPages = await paginateList({
        perPage,
        capPages: runPageCap,
        fetchPage: async (page, pp) => {
          budget.pages += 1;
          const data = await gh(
            `/repos/${repository}/actions/workflows?per_page=${pp}&page=${page}`
          );
          if (!data || !Array.isArray(data.workflows)) {
            const err = new Error("workflows payload malformed");
            err.code = "E_MALFORMED";
            throw err;
          }
          return { items: data.workflows, incomplete: false };
        },
      });
    } catch (err) {
      const reason =
        err.code === "E_MALFORMED" ? REASON.MALFORMED_EVIDENCE : REASON.API_ERROR;
      return finish(unknownReport(reason, err.message || String(err), ctx), {
        hardFail: true,
      });
    }
    if (wfPages.capExhausted && !wfPages.complete) {
      budget.capsHit += 1;
      return finish(
        unknownReport(
          REASON.PAGINATION_CAP,
          "workflow list pagination cap reached before completeness",
          ctx
        ),
        { hardFail: true }
      );
    }
    const { enabled, exclusions, capabilityUnknown } = evaluateCapabilities(
      registry.policies,
      ctx.hasPages
    );
    const suppressed = new Set([
      ...exclusions.map((e) => e.path),
      ...capabilityUnknown.map((e) => e.path),
    ]);
    const activeForJoin = (wfPages.items || []).filter((w) => {
      // Malformed/inactive items must reach joinPolicies; only suppress well-formed actives.
      if (!isWellFormedActiveWorkflow(w)) return true;
      return !suppressed.has(w.path);
    });
    const { rows: joined } = joinPolicies(activeForJoin, enabled);
    const classified = [];
    for (const bad of capabilityUnknown) {
      classified.push({
        name: bad.name,
        path: bad.path,
        mode: null,
        state: STATES.UNKNOWN,
        reasonClass: bad.reasonClass,
        detail: bad.detail,
        selectedJobIds: null,
        selectedRunId: null,
        headSha: null,
        conclusion: null,
        updatedAt: null,
      });
    }
    for (const joinRow of joined) {
      if (joinRow.joinError) {
        classified.push(
          classifySensor({
            name: joinRow.name,
            path: joinRow.path,
            policy: joinRow.policy,
            runs: [],
            ctx,
            joinError: joinRow.joinError,
          })
        );
        continue;
      }
      const policy = joinRow.policy;
      let runs = [];
      let evidenceComplete = true;
      let apiError = null;
      let capExhausted = false;
      let jobs = null;
      try {
        if (policy.mode === "current-head") {
          const merged = [];
          for (const event of policy.events) {
            const result = await paginateWorkflowField(
              (page, pp) => {
                const q = new URLSearchParams({
                  branch: ctx.defaultBranch,
                  head_sha: ctx.headSha,
                  event,
                  status: "completed",
                  per_page: String(pp),
                  page: String(page),
                });
                return `/repos/${repository}/actions/workflows/${joinRow.workflowId}/runs?${q}`;
              },
              requireWorkflowRuns
            );
            if (result.capExhausted && !result.complete) {
              capExhausted = true;
              evidenceComplete = false;
              budget.capsHit += 1;
            }
            merged.push(...result.items);
          }
          if (!capExhausted) {
            const preview = partitionRuns(merged, policy, ctx, {
              enforceHead: true,
              enforceWindow: false,
            });
            if (preview.qualifying.length === 0) {
              for (const event of policy.events) {
                for (const status of PENDING_STATUSES) {
                  budget.pages += 1;
                  const q = new URLSearchParams({
                    branch: ctx.defaultBranch,
                    head_sha: ctx.headSha,
                    event,
                    status,
                    per_page: String(perPage),
                    page: "1",
                  });
                  const data = await gh(
                    `/repos/${repository}/actions/workflows/${joinRow.workflowId}/runs?${q}`
                  );
                  merged.push(...requireWorkflowRuns(data));
                }
              }
            }
          }
          runs = merged;
          const qualifying = partitionRuns(runs, policy, ctx, {
            enforceHead: true,
            enforceWindow: false,
          }).qualifying;
          const latest = selectLatestRun(qualifying);
          if (!capExhausted && latest && policy.targetChecks) {
            const cacheKey = String(latest.id);
            if (jobCache.has(cacheKey)) {
              budget.cacheHits += 1;
              jobs = jobCache.get(cacheKey);
            } else {
              const jobPages = await paginateWorkflowField(
                (page, pp) =>
                  `/repos/${repository}/actions/runs/${latest.id}/jobs?filter=latest&per_page=${pp}&page=${page}`,
                requireJobs
              );
              if (jobPages.capExhausted && !jobPages.complete) {
                capExhausted = true;
                evidenceComplete = false;
                budget.capsHit += 1;
                jobs = null;
              } else {
                jobs = jobPages.items;
                jobCache.set(cacheKey, jobs);
              }
            }
          }
        } else if (isCheckedInRepoOwnedFreshnessPolicy(policy)) {
          const shards = freshnessCreatedQueryShards(ctx.observationTime, policy.windowDays);
          if (shards.length === 0) {
            evidenceComplete = false;
          } else {
            const merged = [];
            for (const event of policy.events) {
              for (const shard of shards) {
                const result = await paginateWorkflowField(
                  (page, pp) => {
                    const q = new URLSearchParams({
                      event,
                      created: shard.created,
                      per_page: String(pp),
                      page: String(page),
                    });
                    return `/repos/${repository}/actions/workflows/${joinRow.workflowId}/runs?${q}`;
                  },
                  requireWorkflowRuns
                );
                if (result.capExhausted && !result.complete) {
                  capExhausted = true;
                  evidenceComplete = false;
                  budget.capsHit += 1;
                }
                merged.push(...result.items);
              }
            }
            runs = mergeWorkflowRunsById(merged);
          }
        } else {
          const result = await paginateWorkflowField(
            (page, pp) =>
              `/repos/${repository}/actions/workflows/${joinRow.workflowId}/runs?per_page=${pp}&page=${page}`,
            requireWorkflowRuns
          );
          runs = result.items;
          if (result.capExhausted && !result.complete) {
            capExhausted = true;
            evidenceComplete = false;
            budget.capsHit += 1;
          }
        }
      } catch (err) {
        if (err.code === "E_MALFORMED") evidenceComplete = false;
        else apiError = err.message || String(err);
      }
      classified.push(
        classifySensor({
          name: joinRow.name,
          path: joinRow.path,
          policy,
          runs,
          jobs,
          ctx,
          evidenceComplete,
          apiError,
          capExhausted,
        })
      );
    }
    let ctxAfter;
    try {
      ctxAfter = await observeHead();
    } catch (err) {
      if (attempts < maxAttempts) continue;
      return finish(
        unknownReport(REASON.API_ERROR, `drift re-fetch failed: ${err.message || err}`, ctx),
        { hardFail: true }
      );
    }
    const drifted =
      !ctxAfter.ok ||
      ctxAfter.fullName !== ctx.fullName ||
      ctxAfter.defaultBranch !== ctx.defaultBranch ||
      ctxAfter.headSha !== ctx.headSha ||
      !hasPagesFrozenEqual(ctx.hasPages, ctxAfter.hasPages);
    if (drifted) {
      if (attempts < maxAttempts) continue;
      return finish(
        unknownReport(
          REASON.HEAD_DRIFT,
          `observation identity changed during audit (${ctx.fullName}@${ctx.defaultBranch}:${ctx.headSha} -> ${
            ctxAfter.ok
              ? `${ctxAfter.fullName}@${ctxAfter.defaultBranch}:${ctxAfter.headSha}`
              : "unreadable"
          })`,
          ctx
        ),
        { hardFail: true }
      );
    }
    return finish(
      buildReportWithExclusions({
        context: ctx,
        rows: classified,
        budget,
        exclusions,
      })
    );
  }
  return finish(unknownReport(REASON.HEAD_DRIFT, "retry exhausted", null), {
    hardFail: true,
  });
}
export async function publishStandingUnknown({
  token,
  repository,
  fetchImpl = globalThis.fetch,
  issueNumber = STANDING_ISSUE_NUMBER,
  reasonClass = REASON.POLICY_INVALID,
  detail,
  observationTime = new Date(),
}) {
  if (!token || !repository || !String(repository).includes("/")) {
    return { posted: false, commented: false, issueNumber, exitCode: 1, postError: "missing token/repository" };
  }
  const obsTime = observationTime instanceof Date ? observationTime : new Date(observationTime);
  const budget = createBudget();
  const gh = createGhClient({ token, fetchImpl, budget });
  const report = buildReport({
    context: { fullName: repository, defaultBranch: "?", headSha: "?", observationTimeIso: obsTime.toISOString() },
    rows: [
      rowResult({
        name: repository,
        path: "(registry)",
        mode: null,
        state: STATES.UNKNOWN,
        reasonClass,
        detail: detail || reasonClass,
      }),
    ],
    budget,
  });
  return postStandingIssue({ gh, repository, issueNumber, report: { ...report, exitCode: 1 }, hardExitCode: 1 });
}
function isMainModule() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return pathToFileURL(resolve(entry)).href === import.meta.url;
  } catch {
    return false;
  }
}
if (isMainModule()) {
  const unknown = process.argv.slice(2).filter((a) => a.startsWith("-"));
  if (unknown.length > 0) {
    console.error(`sensor-health-lib: unknown flag: ${unknown.join(" ")}\nusage: import from scripts/sensor-health-lib.mjs`);
    process.exit(2);
  }
  console.log(JSON.stringify({ schemaId: SCHEMA_ID, standingIssue: STANDING_ISSUE_NUMBER, registryRel: REGISTRY_REL }));
}
