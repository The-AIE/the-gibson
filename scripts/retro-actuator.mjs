#!/usr/bin/env node
/**
 * retro-actuator.mjs — one deduped repair incident for a repeated failure (#569).
 *
 * WHAT IT DOES
 *   Reads CI-failure and review-cap events (JSON lines). The second distinct
 *   failed attempt of one incident key, or one review-cap breach, records one
 *   incident and one repair-issue request. Replays and overlapping processes
 *   share an atomic state file and do not double those records.
 *
 * WHY
 *   Doc 28 loop 3 had no trigger. A repeated failure had to be remembered.
 *
 * RISKS
 *   Default mode prints the request and does not call gh. --apply is the only
 *   path that runs `gh issue create`. A missing, failed, or stale detector is
 *   UNKNOWN, never a healthy result. deployed/effective evidence is a shape
 *   check; this process does not observe what workers run. Nothing here merges
 *   or claims work.
 *
 * USAGE
 *   node scripts/retro-actuator.mjs --events FILE --state FILE [--now ISO] [--apply]
 *   node scripts/retro-actuator.mjs --help
 *
 * EXIT
 *   0  evaluation finished. Drift reported on this run is still exit 0.
 *      Exit 0 is not a health claim about the repository.
 *   1  rejected transition, corrupt state, or state could not be saved
 *   2  usage
 *   3  UNKNOWN (cannot evaluate, gh create failed, or a create did not finish)
 */
import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { realpathSync } from "node:fs";

import { parseFlags } from "./lib/args.mjs";
import {
  SIGNATURE_SCHEMA_VERSION,
  eventId,
  incidentKey,
  normalizeSignature,
} from "./lib/retro-signature.mjs";

const REPORT_SCHEMA = "gibson.retro-actuator-report.v1";
const STATE_SCHEMA = "gibson.retro-actuator-state.v1";
const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
const DEFAULT_REPAIR_BUDGET = 2;
const MAX_EVENT_BYTES = 2 * 1024 * 1024;
const MAX_EVENTS = 10000;
const REAL_ISSUE = new Set(["planned", "creating", "created"]);
const LIFECYCLE = new Set([
  "detected",
  "triaged",
  "artifact-verified",
  "deployed",
  "effective",
  "reopened",
]);
const EDGES = {
  detected: ["triaged"],
  triaged: ["artifact-verified"],
  "artifact-verified": ["deployed"],
  deployed: ["effective", "reopened"],
  effective: ["reopened"],
  reopened: ["triaged"],
};
const LIMITS = [
  "deployed and effective accept evidence fields only; this actuator does not check that workers run the remediation SHA",
  "a missing, failed, or stale detector is UNKNOWN and is not a healthy result",
  "dry-run is the default; gh issue create runs only with --apply",
  "this actuator does not merge pull requests, does not claim work, and does not add a supervisor",
  "it does not edit the lesson ledger",
  "duplicate JSON object keys follow the runtime JSON parser",
  "dedup holds only for a --state file that is reused; a discarded state path does not remember an earlier run",
  "seen event ids are kept for the life of that state file and are not a bounded log",
  "no live event collector is wired; a run reads only the events file or stdin",
];

const RFC3339 =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;

function help() {
  process.stdout.write(`retro-actuator.mjs — record one repair incident for a repeated failure

WHAT I'M ASKING
  Run this when a file of CI-failure or review-cap events should be folded
  into the incident ledger.

WHAT IT DOES
  Normalizes failure text, counts distinct attempt ids, and on the second
  distinct failure of one incident key — or on one review-cap breach — records
  one incident and one repair-issue request. The default run prints that
  request. It calls gh issue create only when you pass --apply.

WHY
  A repeated failure should become one repair request, not a new issue per retry.

RISKS
  --apply opens a GitHub issue in the event's repository. Dry-run does not.
  A detector that is missing, failed, or stale ends UNKNOWN and opens nothing.
  Undo a dry-run by deleting the state file you passed. Undo an applied issue
  in GitHub; this tool does not close it.

LIMITS
${LIMITS.map((line) => `  - ${line}`).join("\n")}

EXAMPLES
  node scripts/retro-actuator.mjs --help
  node scripts/retro-actuator.mjs --events events.jsonl --state /tmp/retro-state.json --now 2026-01-01T00:00:00Z
  node scripts/retro-actuator.mjs --events events.jsonl --state /tmp/retro-state.json --apply --escalate-to duty-human

EXIT
  0  evaluation finished
  1  rejected transition, corrupt state, or state could not be saved
  2  usage
  3  UNKNOWN (cannot evaluate, gh create failed, or a create did not finish)
`);
}

function repoRoot() {
  return resolve(dirname(fileURLToPath(import.meta.url)), "..");
}

function parseRfc3339(value) {
  if (typeof value !== "string") return null;
  const match = RFC3339.exec(value);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 60) return null;
  let ms = Date.UTC(year, month - 1, day, hour, minute, second);
  const check = new Date(ms);
  if (
    check.getUTCFullYear() !== year ||
    check.getUTCMonth() !== month - 1 ||
    check.getUTCDate() !== day
  ) {
    return null;
  }
  if (match[8] !== "Z") {
    const sign = match[8][0] === "+" ? 1 : -1;
    const offH = Number(match[8].slice(1, 3));
    const offM = Number(match[8].slice(4, 6));
    if (offH > 23 || offM > 59) return null;
    ms -= sign * (offH * 60 + offM) * 60000;
  }
  return ms;
}

function iso(ms) {
  return new Date(ms).toISOString().replace(".000Z", "Z");
}

function positiveInt(flag, raw) {
  if (!/^[1-9]\d*$/.test(raw)) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return Number(raw);
}

function nonNegativeInt(flag, raw) {
  if (!/^\d+$/.test(raw)) {
    throw new Error(`${flag} must be a non-negative integer`);
  }
  return Number(raw);
}

function sleepMs(ms) {
  if (ms <= 0) return;
  try {
    const view = new Int32Array(new SharedArrayBuffer(4));
    Atomics.wait(view, 0, 0, ms);
  } catch {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      /* bounded fallback when Atomics.wait is unavailable */
    }
  }
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

function lockIsStale(lockPath) {
  let text = "";
  try {
    text = readFileSync(lockPath, "utf8").trim();
  } catch {
    return false;
  }
  const pid = Number(text);
  if (Number.isInteger(pid) && pid > 0) return !pidAlive(pid);
  try {
    return Date.now() - statSync(lockPath).mtimeMs > 60000;
  } catch {
    return false;
  }
}

function acquireLock(lockPath, timeoutMs) {
  const start = Date.now();
  mkdirSync(dirname(lockPath), { recursive: true });
  for (;;) {
    try {
      const fd = openSync(lockPath, "wx", 0o600);
      writeFileSync(fd, String(process.pid));
      fsyncSync(fd);
      return { ok: true, fd, path: lockPath };
    } catch (error) {
      if (error.code !== "EEXIST") return { ok: false, reason: "lock-failed" };
      if (lockIsStale(lockPath)) {
        try {
          unlinkSync(lockPath);
          continue;
        } catch {
          /* another waiter took it */
        }
      }
      if (Date.now() - start >= timeoutMs) return { ok: false, reason: "lock-timeout" };
      sleepMs(Math.min(20, Math.max(0, timeoutMs - (Date.now() - start))));
    }
  }
}

function releaseLock(lock) {
  if (!lock || !lock.ok) return;
  try {
    closeSync(lock.fd);
  } catch {
    /* already closed */
  }
  try {
    const current = readFileSync(lock.path, "utf8").trim();
    if (current === String(process.pid)) unlinkSync(lock.path);
  } catch {
    /* lock already gone */
  }
}

function assertRegularFile(path) {
  if (!existsSync(path)) return { ok: true };
  const st = lstatSync(path);
  if (st.isSymbolicLink() || !st.isFile()) {
    return { ok: false, reason: "state path must be a regular file" };
  }
  return { ok: true };
}

function writeAtomic(path, text) {
  const check = assertRegularFile(path);
  if (!check.ok) {
    const error = new Error(check.reason);
    error.code = "E_STATE";
    throw error;
  }
  const dir = dirname(path);
  mkdirSync(dir, { recursive: true });
  const tmp = join(
    dir,
    `.${basename(path)}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`
  );
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeFileSync(fd, text);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, path);
}

function freshState() {
  return {
    schema: STATE_SCHEMA,
    trusted_signature_schema_version: null,
    trusted_detector_versions: [],
    drift_gate: null,
    incidents: {},
    pending: {},
    seen_event_ids: [],
  };
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function loadState(path) {
  if (!existsSync(path)) return { ok: true, state: freshState() };
  const check = assertRegularFile(path);
  if (!check.ok) return check;
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return { ok: false, reason: "state file is not JSON" };
  }
  if (!isObject(parsed) || parsed.schema !== STATE_SCHEMA) {
    return { ok: false, reason: "state schema is not recognized" };
  }
  if (
    parsed.trusted_signature_schema_version !== null &&
    !Number.isInteger(parsed.trusted_signature_schema_version)
  ) {
    return { ok: false, reason: "trusted signature schema is invalid" };
  }
  if (
    !Array.isArray(parsed.trusted_detector_versions) ||
    parsed.trusted_detector_versions.some((v) => typeof v !== "string")
  ) {
    return { ok: false, reason: "trusted detector versions are invalid" };
  }
  if (!isObject(parsed.incidents) || !isObject(parsed.pending)) {
    return { ok: false, reason: "state records are invalid" };
  }
  if (
    !Array.isArray(parsed.seen_event_ids) ||
    parsed.seen_event_ids.some((v) => typeof v !== "string")
  ) {
    return { ok: false, reason: "seen events are invalid" };
  }
  for (const inc of Object.values(parsed.incidents)) {
    if (!isObject(inc) || !LIFECYCLE.has(inc.state) || typeof inc.incident_key !== "string") {
      return { ok: false, reason: "an incident record is invalid" };
    }
    if (!Array.isArray(inc.attempts) || !Array.isArray(inc.issue_requests)) {
      return { ok: false, reason: "an incident record is invalid" };
    }
    if (inc.automatic_requeue !== "allowed" && inc.automatic_requeue !== "blocked") {
      return { ok: false, reason: "an incident requeue flag is invalid" };
    }
    if (!Number.isInteger(inc.repair_budget) || inc.repair_budget < 1) {
      return { ok: false, reason: "an incident budget is invalid" };
    }
    if (!Number.isInteger(inc.repair_attempts_used) || inc.repair_attempts_used < 0) {
      return { ok: false, reason: "an incident budget is invalid" };
    }
  }
  for (const pending of Object.values(parsed.pending)) {
    if (!isObject(pending) || !Array.isArray(pending.attempts)) {
      return { ok: false, reason: "a pending record is invalid" };
    }
  }
  return { ok: true, state: parsed };
}

function blankReport(apply) {
  return {
    schema: REPORT_SCHEMA,
    mode: apply ? "apply" : "dry-run",
    evaluation: "complete",
    detector: "healthy",
    signature_schema_version: SIGNATURE_SCHEMA_VERSION,
    trust: "trusted",
    new_keys_trusted: true,
    drifted_keys: [],
    pending_count: 0,
    incidents: [],
    issue_requests: [],
    alerts: [],
    escalations: [],
    rejected_transitions: [],
    unknown_reason: null,
    gh_invocations: 0,
    limits: LIMITS,
  };
}

function unknownReport(apply, reason) {
  const report = blankReport(apply);
  report.evaluation = "UNKNOWN";
  report.detector = "UNKNOWN";
  report.trust = "untrusted";
  report.new_keys_trusted = false;
  report.unknown_reason = reason;
  report.alerts.push({ reason: "triage-alert", detail: reason });
  return report;
}

function readEvents(file) {
  if (!file || file === "-") {
    const text = readFileSync(0, "utf8");
    if (Buffer.byteLength(text) > MAX_EVENT_BYTES) {
      return { ok: false, reason: "events exceed 2 MiB" };
    }
    return { ok: true, text };
  }
  if (!existsSync(file)) return { ok: false, reason: "events file not found" };
  let st;
  try {
    st = statSync(file);
  } catch {
    return { ok: false, reason: "events file cannot be read" };
  }
  if (!st.isFile()) return { ok: false, reason: "events path is not a file" };
  if (st.size > MAX_EVENT_BYTES) return { ok: false, reason: "events exceed 2 MiB" };
  try {
    return { ok: true, text: readFileSync(file, "utf8") };
  } catch {
    return { ok: false, reason: "events file cannot be read" };
  }
}

function ident(value, max) {
  return typeof value === "string" && /^[A-Za-z0-9._:-]{1,200}$/.test(value) && value.length <= max;
}

function parseEvents(text) {
  const events = [];
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    if (line.length > 65536) return { ok: false, reason: `line ${i + 1} is too long` };
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      return { ok: false, reason: `line ${i + 1} is not JSON` };
    }
    const checked = validateEvent(obj, i + 1);
    if (!checked.ok) return checked;
    events.push(checked.event);
    if (events.length > MAX_EVENTS) return { ok: false, reason: "too many events" };
  }
  return { ok: true, events };
}

function validateEvent(obj, lineNo) {
  if (!isObject(obj)) return { ok: false, reason: `line ${lineNo} is not an object` };
  const kind = obj.kind;
  const kinds = new Set([
    "ci-failure",
    "review-cap",
    "lifecycle",
    "budget-override",
    "detector-status",
  ]);
  if (!kinds.has(kind)) return { ok: false, reason: `line ${lineNo} has an unknown kind` };
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(obj.repo || "")) {
    return { ok: false, reason: `line ${lineNo} has a bad repo` };
  }
  if (parseRfc3339(obj.observed_at) === null) {
    return { ok: false, reason: `line ${lineNo} has a bad observed_at` };
  }
  if (typeof obj.detector_health !== "string") {
    return { ok: false, reason: `line ${lineNo} has no detector_health` };
  }
  if (!ident(obj.detector_version, 80)) {
    return { ok: false, reason: `line ${lineNo} has a bad detector_version` };
  }
  const event = {
    kind,
    repo: obj.repo,
    observed_at: obj.observed_at,
    detector_health: obj.detector_health,
    detector_version: obj.detector_version,
  };
  if (kind === "ci-failure" || kind === "review-cap") {
    if (!ident(obj.attempt_id, 200)) {
      return { ok: false, reason: `line ${lineNo} has a bad attempt_id` };
    }
    if (!(obj.head_sha === "unknown" || /^[0-9a-f]{40}$/.test(obj.head_sha || ""))) {
      return { ok: false, reason: `line ${lineNo} has a bad head_sha` };
    }
    if (typeof obj.raw_signature !== "string" || obj.raw_signature.length < 1 || obj.raw_signature.length > 10000) {
      return { ok: false, reason: `line ${lineNo} has a bad raw_signature` };
    }
    if (obj.raw_signature.includes("\0")) {
      return { ok: false, reason: `line ${lineNo} has a bad raw_signature` };
    }
    event.attempt_id = obj.attempt_id;
    event.head_sha = obj.head_sha;
    event.raw_signature = obj.raw_signature;
  }
  if (kind === "review-cap") {
    if (obj.tier != null && typeof obj.tier !== "string") {
      return { ok: false, reason: `line ${lineNo} has a bad tier` };
    }
    if (!Number.isInteger(obj.review_rounds) || obj.review_rounds < 0) {
      return { ok: false, reason: `line ${lineNo} has a bad review_rounds` };
    }
    event.tier = obj.tier == null || obj.tier === "" ? null : obj.tier;
    event.review_rounds = obj.review_rounds;
  }
  if (kind === "lifecycle" || kind === "budget-override") {
    if (typeof obj.incident_key !== "string" || obj.incident_key.length < 1 || obj.incident_key.length > 4000) {
      return { ok: false, reason: `line ${lineNo} has a bad incident_key` };
    }
    event.incident_key = obj.incident_key;
  }
  if (kind === "lifecycle") {
    if (!LIFECYCLE.has(obj.to)) return { ok: false, reason: `line ${lineNo} has a bad to state` };
    if (obj.evidence != null && !isObject(obj.evidence)) {
      return { ok: false, reason: `line ${lineNo} has bad evidence` };
    }
    event.to = obj.to;
    event.evidence = obj.evidence || {};
  }
  if (kind === "budget-override") {
    if (typeof obj.actor !== "string" || !/^[A-Za-z0-9._: -]{1,80}$/.test(obj.actor)) {
      return { ok: false, reason: `line ${lineNo} has a bad actor` };
    }
    event.actor = obj.actor;
  }
  return { ok: true, event };
}

function batchDetector(events) {
  if (events.length === 0) return "UNKNOWN";
  for (const event of events) {
    if (event.detector_health !== "healthy") return "UNKNOWN";
  }
  return "healthy";
}

function loadCaps(root) {
  const path = join(root, "config", "review-round-caps.json");
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return { ok: false, reason: "review-round caps cannot be read" };
  }
  if (!isObject(parsed) || typeof parsed.default !== "string") {
    return { ok: false, reason: "review-round caps are invalid" };
  }
  const caps = Object.create(null);
  caps.default = parsed.default;
  for (const key of Object.keys(parsed)) {
    if (key === "default") continue;
    if (!Number.isInteger(parsed[key]) || parsed[key] < 0) {
      return { ok: false, reason: "review-round caps are invalid" };
    }
    caps[key] = parsed[key];
  }
  if (!Object.prototype.hasOwnProperty.call(caps, caps.default)) {
    return { ok: false, reason: "review-round caps default is missing" };
  }
  return { ok: true, caps };
}

function resolveCap(caps, tier) {
  const name = tier == null || tier === "" ? caps.default : tier;
  if (typeof name !== "string" || !Object.prototype.hasOwnProperty.call(caps, name)) return null;
  const value = caps[name];
  if (!Number.isInteger(value) || value < 0) return null;
  return value;
}

function driftedKeys(state, incoming) {
  const incomingSet = new Set(incoming);
  const schemaMismatch = state.trusted_signature_schema_version !== SIGNATURE_SCHEMA_VERSION;
  const keys = [];
  for (const inc of Object.values(state.incidents)) {
    let drift = schemaMismatch || inc.signature_schema_version !== SIGNATURE_SCHEMA_VERSION;
    const raws = Array.isArray(inc.raw_signatures) ? inc.raw_signatures : [];
    for (const raw of raws) {
      if (typeof raw === "string" && normalizeSignature(raw) !== inc.normalized_signature) drift = true;
    }
    const dets = Array.isArray(inc.detector_versions) ? inc.detector_versions : [];
    if (dets.length > 0 && incoming.length > 0 && dets.every((d) => !incomingSet.has(d))) drift = true;
    if (drift) keys.push(inc.incident_key);
  }
  keys.sort();
  return keys;
}

function assessGate(state, events) {
  const incoming = [...new Set(events.map((event) => event.detector_version))].sort();
  const hasRecords =
    Object.keys(state.incidents).length > 0 || Object.keys(state.pending).length > 0;
  if (state.trusted_signature_schema_version == null) {
    if (hasRecords) return { action: "bad-state", reason: "untrusted state already has incidents" };
    return { action: "bootstrap", incoming };
  }
  const schemaMismatch = state.trusted_signature_schema_version !== SIGNATURE_SCHEMA_VERSION;
  const known = new Set(state.trusted_detector_versions);
  const novel = incoming.filter((version) => !known.has(version));
  if (!schemaMismatch && novel.length === 0) return { action: "ready", incoming };
  const gate = state.drift_gate;
  const gateCovers =
    isObject(gate) &&
    gate.signature_schema_version === SIGNATURE_SCHEMA_VERSION &&
    Array.isArray(gate.detector_versions) &&
    incoming.every((version) => gate.detector_versions.includes(version));
  if (gateCovers) return { action: "promote", incoming };
  return {
    action: "withhold",
    incoming,
    drifted_keys: driftedKeys(state, incoming),
  };
}

function applyTrust(state, incoming) {
  state.trusted_signature_schema_version = SIGNATURE_SCHEMA_VERSION;
  const versions = new Set(state.trusted_detector_versions);
  for (const version of incoming) versions.add(version);
  state.trusted_detector_versions = [...versions].sort();
  state.drift_gate = null;
}

function shortHash(value) {
  return createHash("sha256").update(value).digest("hex").slice(0, 12);
}

function blankIncident(key, repo, normalized, budget) {
  return {
    incident_key: key,
    repo,
    normalized_signature: normalized,
    signature_schema_version: SIGNATURE_SCHEMA_VERSION,
    raw_signatures: [],
    detector_versions: [],
    state: "detected",
    attempts: [],
    issue_requests: [],
    repair_attempts_used: 0,
    repair_budget: budget,
    budget_overrides: [],
    escalation: null,
    escalation_history: [],
    automatic_requeue: "allowed",
    revoked_claims: [],
    history: [],
    evidence: {},
  };
}

function noteEvidence(bucket, event) {
  if (!bucket.raw_signatures.includes(event.raw_signature)) {
    bucket.raw_signatures.push(event.raw_signature);
  }
  if (!bucket.detector_versions.includes(event.detector_version)) {
    bucket.detector_versions.push(event.detector_version);
  }
}

function addAttempt(bucket, event, id) {
  const known = bucket.attempts.find((attempt) => attempt.attempt_id === event.attempt_id);
  if (known) {
    if (!known.head_shas.includes(event.head_sha)) known.head_shas.push(event.head_sha);
    if (!known.event_ids.includes(id)) known.event_ids.push(id);
    return false;
  }
  bucket.attempts.push({
    attempt_id: event.attempt_id,
    head_shas: [event.head_sha],
    event_ids: [id],
    observed_at: event.observed_at,
  });
  return true;
}

function realIssueCount(inc) {
  return inc.issue_requests.filter((request) => REAL_ISSUE.has(request.status)).length;
}

function latestRealIssue(inc) {
  const real = inc.issue_requests.filter((request) => REAL_ISSUE.has(request.status));
  return real.length === 0 ? null : real[real.length - 1];
}

function issueBody(inc) {
  const attempts = inc.attempts
    .map(
      (attempt) =>
        `- attempt_id=${attempt.attempt_id} head_sha=${attempt.head_shas.join(",")} observed_at=${attempt.observed_at}`
    )
    .join("\n");
  return [
    "Advisory repair request from the retro actuator.",
    "",
    "This request does not merge pull requests and does not claim the work.",
    "",
    `Incident key: ${inc.incident_key}`,
    `State: ${inc.state}`,
    `Normalized signature: ${inc.normalized_signature}`,
    `Signature schema version: ${inc.signature_schema_version}`,
    "Distinct attempts:",
    attempts || "- none",
    "",
    "Limit: deployed and effective evidence is checked for shape only. This actuator does not observe which SHA workers run.",
    "",
  ].join("\n");
}

function maybeIssue(inc, nowMs, report, opts, reason) {
  const latest = latestRealIssue(inc);
  if (latest) {
    const then = parseRfc3339(latest.requested_at);
    if (then !== null && nowMs - then < WEEK_MS) {
      inc.issue_requests.push({
        status: "suppressed-flood",
        requested_at: iso(nowMs),
        reason,
        title: null,
      });
      report.issue_requests.push({
        action: "suppressed-flood",
        incident_key: inc.incident_key,
        title: null,
        reason,
      });
      return;
    }
  }
  if (inc.automatic_requeue === "blocked" || inc.repair_attempts_used >= inc.repair_budget) {
    inc.automatic_requeue = "blocked";
    let human = opts.escalateTo || "";
    if (!human && inc.escalation && inc.escalation.human && inc.escalation.human !== "unknown") {
      human = inc.escalation.human;
    }
    if (!human) human = "unknown";
    if (!inc.escalation || inc.escalation.human !== human) {
      if (inc.escalation) inc.escalation_history.push(inc.escalation);
      inc.escalation = {
        human,
        at: iso(nowMs),
        reason: "attempt-budget-exhausted",
        incident_key: inc.incident_key,
      };
    }
    const escalation = inc.escalation;
    inc.issue_requests.push({
      status: "suppressed-budget",
      requested_at: iso(nowMs),
      reason,
      title: null,
    });
    report.escalations.push(escalation);
    report.issue_requests.push({
      action: "suppressed-budget",
      incident_key: inc.incident_key,
      title: null,
      reason,
    });
    if (human === "unknown") {
      report.evaluation = "UNKNOWN";
      report.unknown_reason = "escalation human is unknown";
      report.alerts.push({ reason: "triage-alert", detail: "escalation human is unknown" });
    }
    return;
  }
  const title = `Repair repeated failure ${shortHash(inc.incident_key)}`;
  inc.issue_requests.push({
    status: "planned",
    requested_at: iso(nowMs),
    reason,
    title,
    body: issueBody(inc),
    gh_url: null,
    gh_number: null,
  });
  inc.repair_attempts_used += 1;
  report.issue_requests.push({
    action: "would-create",
    incident_key: inc.incident_key,
    title,
    reason,
  });
}

function openIncident(state, event, budget) {
  const normalized = normalizeSignature(event.raw_signature);
  const key = incidentKey({
    repo: event.repo,
    normalizedSignature: normalized,
    signatureSchemaVersion: SIGNATURE_SCHEMA_VERSION,
  });
  const inc = blankIncident(key, event.repo, normalized, budget);
  inc.history.push({ from: null, to: "detected", at: event.observed_at });
  state.incidents[key] = inc;
  return inc;
}

function reject(report, incidentKeyValue, from, to, reason) {
  report.rejected_transitions.push({
    incident_key: incidentKeyValue,
    from,
    to,
    reason,
  });
}

function nonEmptyRef(value) {
  return typeof value === "string" && value.trim() !== "" && value !== "unknown" && value.length <= 500;
}

function checkDeployed(evidence) {
  if (!isObject(evidence)) return { ok: false, reason: "missing-remediation-sha" };
  if (typeof evidence.remediation_sha !== "string") {
    return { ok: false, reason: "missing-remediation-sha" };
  }
  if (!/^[0-9a-f]{40}$/.test(evidence.remediation_sha)) {
    return { ok: false, reason: "bad-remediation-sha" };
  }
  if (!nonEmptyRef(evidence.workers_evidence_ref)) {
    return {
      ok: false,
      reason:
        evidence.workers_evidence_ref === "unknown"
          ? "workers-evidence-unknown"
          : "missing-workers-evidence",
    };
  }
  if (parseRfc3339(evidence.recorded_at) === null) {
    return { ok: false, reason: "missing-recorded-at" };
  }
  return { ok: true };
}

function checkEffective(evidence) {
  if (!isObject(evidence)) return { ok: false, reason: "detector-not-healthy" };
  if (evidence.detector_health !== "healthy") {
    return { ok: false, reason: "detector-not-healthy" };
  }
  const start = parseRfc3339(evidence.exposure_start);
  const end = parseRfc3339(evidence.exposure_end);
  if (start === null || end === null) return { ok: false, reason: "missing-exposure-window" };
  if (end <= start) return { ok: false, reason: "bad-exposure-window" };
  if (!Number.isInteger(evidence.minimum_sample) || evidence.minimum_sample < 1) {
    return { ok: false, reason: "missing-minimum-sample" };
  }
  if (!Number.isInteger(evidence.sample_count) || evidence.sample_count < evidence.minimum_sample) {
    return { ok: false, reason: "sample-below-minimum" };
  }
  if (!nonEmptyRef(evidence.measurement_ref)) {
    return { ok: false, reason: "measurement-unknown" };
  }
  return { ok: true };
}

function transition(inc, to, evidence, at, report) {
  const allowed = EDGES[inc.state] || [];
  if (!allowed.includes(to)) {
    reject(report, inc.incident_key, inc.state, to, "illegal-transition");
    return false;
  }
  if (to === "deployed") {
    const checked = checkDeployed(evidence);
    if (!checked.ok) {
      reject(report, inc.incident_key, inc.state, to, checked.reason);
      return false;
    }
  }
  if (to === "effective") {
    const checked = checkEffective(evidence);
    if (!checked.ok) {
      reject(report, inc.incident_key, inc.state, to, checked.reason);
      return false;
    }
  }
  const from = inc.state;
  inc.state = to;
  inc.history.push({ from, to, at });
  if (to === "reopened") inc.revoked_claims.push({ claim: from, at });
  if (to === "deployed" || to === "effective") inc.evidence[to] = evidence;
  return true;
}

function onFailure(state, event, id, nowMs, report, opts) {
  const normalized = normalizeSignature(event.raw_signature);
  const key = incidentKey({
    repo: event.repo,
    normalizedSignature: normalized,
    signatureSchemaVersion: SIGNATURE_SCHEMA_VERSION,
  });
  const existing = state.incidents[key];
  if (existing) {
    noteEvidence(existing, event);
    const fresh = addAttempt(existing, event, id);
    if (!fresh) return;
    if (existing.state === "effective" || existing.state === "deployed") {
      const from = existing.state;
      existing.state = "reopened";
      existing.history.push({ from, to: "reopened", at: event.observed_at });
      existing.revoked_claims.push({ claim: from, at: event.observed_at });
      maybeIssue(existing, nowMs, report, opts, "escape");
      return;
    }
    if (existing.state === "reopened") {
      maybeIssue(existing, nowMs, report, opts, "escape");
    }
    return;
  }
  let pending = state.pending[key];
  if (!pending) {
    pending = {
      incident_key: key,
      repo: event.repo,
      normalized_signature: normalized,
      signature_schema_version: SIGNATURE_SCHEMA_VERSION,
      raw_signatures: [],
      detector_versions: [],
      attempts: [],
    };
    state.pending[key] = pending;
  }
  noteEvidence(pending, event);
  addAttempt(pending, event, id);
  if (pending.attempts.length < 2) return;
  const inc = blankIncident(key, event.repo, normalized, opts.repairBudget);
  inc.raw_signatures = pending.raw_signatures.slice();
  inc.detector_versions = pending.detector_versions.slice();
  inc.attempts = pending.attempts.slice();
  inc.history.push({ from: null, to: "detected", at: event.observed_at });
  delete state.pending[key];
  state.incidents[key] = inc;
  maybeIssue(inc, nowMs, report, opts, "second-attempt");
}

function onReviewCap(state, event, id, nowMs, report, opts, caps) {
  const cap = resolveCap(caps, event.tier);
  if (cap === null) {
    report.evaluation = "UNKNOWN";
    report.unknown_reason = "review cap cannot be resolved";
    report.alerts.push({ reason: "triage-alert", detail: "review cap cannot be resolved" });
    return;
  }
  if (event.review_rounds <= cap) return;
  const key = incidentKey({
    repo: event.repo,
    normalizedSignature: normalizeSignature(event.raw_signature),
    signatureSchemaVersion: SIGNATURE_SCHEMA_VERSION,
  });
  let inc = state.incidents[key];
  if (!inc) {
    inc = openIncident(state, event, opts.repairBudget);
    const pending = state.pending[key];
    if (pending) {
      inc.attempts = pending.attempts.slice();
      inc.raw_signatures = pending.raw_signatures.slice();
      inc.detector_versions = pending.detector_versions.slice();
      delete state.pending[key];
    }
  }
  noteEvidence(inc, event);
  addAttempt(inc, event, id);
  if (inc.state === "effective" || inc.state === "deployed") {
    const from = inc.state;
    inc.state = "reopened";
    inc.history.push({ from, to: "reopened", at: event.observed_at });
    inc.revoked_claims.push({ claim: from, at: event.observed_at });
    maybeIssue(inc, nowMs, report, opts, "escape");
    return;
  }
  if (realIssueCount(inc) === 0) maybeIssue(inc, nowMs, report, opts, "review-cap");
}

function controlEventId(event) {
  if (event.kind === "lifecycle") {
    return JSON.stringify([
      "lifecycle",
      event.incident_key,
      event.to,
      event.observed_at,
      event.detector_version,
    ]);
  }
  if (event.kind === "budget-override") {
    return JSON.stringify([
      "budget-override",
      event.incident_key,
      event.actor,
      event.observed_at,
    ]);
  }
  return null;
}

function applyEvent(state, event, nowMs, report, opts, caps) {
  if (event.kind === "lifecycle" || event.kind === "budget-override") {
    const cid = controlEventId(event);
    if (cid && state.seen_event_ids.includes(cid)) return;
    const inc = state.incidents[event.incident_key];
    if (!inc) {
      reject(report, event.incident_key, null, event.to || "budget-override", "unknown-incident");
      return;
    }
    if (event.kind === "budget-override") {
      if (event.actor === "unknown") {
        reject(report, event.incident_key, inc.state, "budget-override", "unnamed-actor");
        return;
      }
      inc.budget_overrides.push({ at: event.observed_at, actor: event.actor });
      inc.repair_attempts_used = 0;
      inc.automatic_requeue = "allowed";
      if (inc.escalation) {
        inc.escalation_history.push(inc.escalation);
        inc.escalation = null;
      }
      if (cid) state.seen_event_ids.push(cid);
      return;
    }
    const moved = transition(inc, event.to, event.evidence, event.observed_at, report);
    if (moved && cid) state.seen_event_ids.push(cid);
    return;
  }
  if (event.kind === "detector-status") return;
  const id = eventId({
    repo: event.repo,
    attemptId: event.attempt_id,
    headSha: event.head_sha,
    detectorVersion: event.detector_version,
    rawSignature: event.raw_signature,
  });
  if (state.seen_event_ids.includes(id)) return;
  state.seen_event_ids.push(id);
  if (event.kind === "ci-failure") onFailure(state, event, id, nowMs, report, opts);
  if (event.kind === "review-cap") onReviewCap(state, event, id, nowMs, report, opts, caps);
}

function fillReport(state, report) {
  report.pending_count = Object.keys(state.pending).length;
  report.incidents = Object.values(state.incidents)
    .map((inc) => ({
      incident_key: inc.incident_key,
      state: inc.state,
      distinct_attempts: inc.attempts.length,
      real_issue_requests: realIssueCount(inc),
      repair_attempts_used: inc.repair_attempts_used,
      automatic_requeue: inc.automatic_requeue,
      escalation: inc.escalation,
      revoked_claims: inc.revoked_claims,
    }))
    .sort((a, b) => (a.incident_key < b.incident_key ? -1 : 1));
}

function applyIssues(state, report) {
  for (const inc of Object.values(state.incidents)) {
    for (const request of inc.issue_requests) {
      if (request.status === "creating") {
        report.evaluation = "UNKNOWN";
        report.unknown_reason = "a previous create did not finish";
        report.alerts.push({ reason: "triage-alert", detail: "a previous create did not finish" });
        return;
      }
    }
  }
  for (const inc of Object.values(state.incidents)) {
    for (const request of inc.issue_requests) {
      if (request.status !== "planned") continue;
      request.status = "creating";
      request.body = issueBody(inc);
      const bodyPath = join(
        tmpdir(),
        `retro-actuator-body-${process.pid}-${randomBytes(4).toString("hex")}.txt`
      );
      writeFileSync(bodyPath, request.body, { mode: 0o600 });
      const result = spawnSync(
        "gh",
        ["issue", "create", "--repo", inc.repo, "--title", request.title, "--body-file", bodyPath],
        { encoding: "utf8" }
      );
      report.gh_invocations += 1;
      try {
        unlinkSync(bodyPath);
      } catch {
        /* temp body already gone */
      }
      if (!result || result.error || result.status !== 0) {
        request.status = "planned";
        report.evaluation = "UNKNOWN";
        report.unknown_reason = "gh issue create failed";
        report.alerts.push({ reason: "triage-alert", detail: "gh issue create failed" });
        return;
      }
      const url = String(result.stdout || "").trim();
      const matched = /^https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/issues\/(\d+)$/.exec(url);
      if (!matched) {
        request.status = "creating";
        report.evaluation = "UNKNOWN";
        report.unknown_reason = "gh issue create returned no issue url";
        report.alerts.push({
          reason: "triage-alert",
          detail: "gh issue create returned no issue url",
        });
        return;
      }
      request.status = "created";
      request.gh_url = url;
      request.gh_number = Number(matched[1]);
      const printed = report.issue_requests.find(
        (item) => item.action === "would-create" && item.incident_key === inc.incident_key && item.title === request.title
      );
      if (printed) printed.action = "created";
    }
  }
}

function emit(report, code) {
  process.stdout.write(`${JSON.stringify(report)}\n`);
  if (report.evaluation === "UNKNOWN") {
    process.stderr.write(`retro-actuator: UNKNOWN: ${report.unknown_reason}\n`);
  }
  process.exitCode = code;
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("--help") || argv.includes("-h")) {
    help();
    return;
  }
  let args;
  try {
    args = parseFlags(argv, {
      prefix: "retro-actuator: ",
      flags: {
        "--events": { key: "events", type: "string" },
        "--state": { key: "state", type: "string" },
        "--now": { key: "now", type: "string" },
        "--root": { key: "root", type: "string" },
        "--apply": { key: "apply", type: "boolean" },
        "--escalate-to": { key: "escalateTo", type: "string" },
        "--repair-budget": {
          key: "repairBudget",
          type: "string",
          default: () => DEFAULT_REPAIR_BUDGET,
          transform: (raw) => positiveInt("--repair-budget", raw),
        },
        "--lock-timeout-ms": {
          key: "lockTimeoutMs",
          type: "string",
          default: () => 5000,
          transform: (raw) => nonNegativeInt("--lock-timeout-ms", raw),
        },
      },
    });
  } catch (error) {
    if (error && error.message && !String(error.message).startsWith("retro-actuator:")) {
      process.stderr.write(`retro-actuator: ${error.message}\n`);
      process.exit(2);
    }
    throw error;
  }
  if (typeof args.repairBudget !== "number") args.repairBudget = DEFAULT_REPAIR_BUDGET;
  if (typeof args.lockTimeoutMs !== "number") args.lockTimeoutMs = 5000;

  let nowMs = Date.now();
  if (args.now != null) {
    nowMs = parseRfc3339(args.now);
    if (nowMs === null) {
      process.stderr.write("retro-actuator: --now must be an RFC3339 timestamp\n");
      process.exit(2);
    }
  }

  const root = args.root ? resolve(args.root) : repoRoot();
  const statePath = args.state
    ? resolve(args.state)
    : join(root, "docs", "retro-actuator-state.json");
  const apply = args.apply === true;
  const opts = {
    repairBudget: args.repairBudget,
    escalateTo: args.escalateTo || "",
  };

  const eventsFile = readEvents(args.events);
  if (!eventsFile.ok) {
    emit(unknownReport(apply, eventsFile.reason), 3);
    return;
  }
  const parsed = parseEvents(eventsFile.text);
  if (!parsed.ok) {
    emit(unknownReport(apply, parsed.reason), 3);
    return;
  }
  if (batchDetector(parsed.events) !== "healthy") {
    emit(unknownReport(apply, "detector is not healthy"), 3);
    return;
  }
  const needsCaps = parsed.events.some((event) => event.kind === "review-cap");
  let caps = null;
  if (needsCaps) {
    const loadedCaps = loadCaps(root);
    if (!loadedCaps.ok) {
      emit(unknownReport(apply, loadedCaps.reason), 3);
      return;
    }
    caps = loadedCaps.caps;
    for (const event of parsed.events) {
      if (event.kind === "review-cap" && resolveCap(caps, event.tier) === null) {
        emit(unknownReport(apply, "review cap cannot be resolved"), 3);
        return;
      }
    }
  }

  const lock = acquireLock(`${statePath}.lock`, args.lockTimeoutMs);
  if (!lock.ok) {
    emit(unknownReport(apply, lock.reason), 3);
    return;
  }
  let code = 0;
  let report = blankReport(apply);
  try {
    const loaded = loadState(statePath);
    if (!loaded.ok) {
      report = unknownReport(apply, loaded.reason);
      code = 1;
    } else {
      const state = loaded.state;
      const gate = assessGate(state, parsed.events);
      if (gate.action === "bad-state") {
        report = unknownReport(apply, gate.reason);
        code = 1;
      } else if (gate.action === "withhold") {
        state.drift_gate = {
          signature_schema_version: SIGNATURE_SCHEMA_VERSION,
          detector_versions: gate.incoming,
          reported_at: iso(nowMs),
          drifted_keys: gate.drifted_keys,
        };
        report.trust = "drift-reported";
        report.new_keys_trusted = false;
        report.drifted_keys = gate.drifted_keys;
        writeAtomic(statePath, `${JSON.stringify(state)}\n`);
        fillReport(state, report);
      } else {
        if (gate.action === "bootstrap" || gate.action === "promote") {
          applyTrust(state, gate.incoming);
        }
        for (const event of parsed.events) {
          applyEvent(state, event, nowMs, report, opts, caps);
        }
        if (apply && report.evaluation !== "UNKNOWN") applyIssues(state, report);
        writeAtomic(statePath, `${JSON.stringify(state)}\n`);
        fillReport(state, report);
        if (report.evaluation === "UNKNOWN") code = 3;
        else if (report.rejected_transitions.length > 0) code = 1;
      }
    }
  } catch (error) {
    report = unknownReport(apply, "state could not be saved");
    code = 1;
    if (error && error.code === "E_STATE") report.unknown_reason = error.message;
  } finally {
    releaseLock(lock);
  }
  emit(report, code);
}

function invokedAsCli() {
  // macOS TMPDIR is /var, which realpaths to /private/var. import.meta.url uses
  // the real path; argv keeps the path the caller typed.
  if (!process.argv[1]) return false;
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(resolve(process.argv[1]));
  } catch {
    return false;
  }
}

if (invokedAsCli()) main();
