#!/usr/bin/env node
/** Advisory exact-suite selection. It never executes tests or authorizes skipping them. */
import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const RUN_SCHEMA = "gibson.ci-full-run/v1";
const SHADOW_SCHEMA = "gibson.ci-suite-selection/v1";
const POLICY_SCHEMA = "gibson.ci-suite-selection-policy/v1";
const MAX_EVIDENCE_BYTES = 128 * 1024;
const ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const ALWAYS = ["architecture-fitness.test.sh", "ci-suite-selection.test.sh", "contract-authority.test.sh", "convention-sensors.test.sh", "laws-sensors.test.sh", "policy-manifest.test.sh"];
const sort = (values) => [...values].sort();
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const unique = (values) => Array.isArray(values) && values.every((v) => typeof v === "string" && v.length > 0) && new Set(values).size === values.length;
const integer = (v) => Number.isSafeInteger(v) && v >= 0;

function git(repo, args) {
  // Output is complete or the command fails; execFile never interpolates filenames.
  const bytes = execFileSync("git", ["-C", repo, ...args], { maxBuffer: 64 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
  const text = bytes.toString("utf8");
  if (!Buffer.from(text).equals(bytes)) throw new Error("non-UTF-8 Git evidence requires full fallback");
  return text;
}
function commit(repo, value) {
  if (!value || !/^[0-9a-f]{40}$/.test(value)) throw new Error("expected a full commit SHA");
  const actual = git(repo, ["rev-parse", "--verify", `${value}^{commit}`]).trim();
  if (actual !== value) throw new Error("commit identity mismatch");
  return actual;
}
function inventory(repo) {
  return sort(readdirSync(resolve(repo, "scripts/tests"), { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".test.sh")).map((entry) => entry.name));
}
function nulFile(path) {
  const text = readFileSync(path, "utf8");
  if (!text.endsWith("\0")) throw new Error("unterminated inventory or receipt stream");
  return text.slice(0, -1).split("\0");
}
function parseArgs(argv) {
  const command = argv.shift();
  if (command === "--help" || command === "-h") return { command: "help" };
  const allowed = command === "write-report"
    ? ["repo", "records", "inventory", "executed-inventory", "base", "head", "executed", "exit", "wall", "global-failures", "mode", "output"]
    : command === "compare" ? ["repo", "report", "base", "head", "output", "summary", "gate-outcome", "policy-outcome"] : [];
  if (!allowed.length) throw new Error(command?.startsWith("-") ? `unknown option: ${command}` : "expected write-report or compare (see --help)");
  const options = { command, repo: ROOT };
  while (argv.length) {
    const flag = argv.shift();
    const name = flag?.startsWith("--") ? flag.slice(2) : "";
    if (!allowed.includes(name) || Object.hasOwn(options, name) && name !== "repo") throw new Error(`unknown option: ${flag} (unsupported or repeated)`);
    if (!argv.length || argv[0].startsWith("--")) throw new Error(`missing value: ${flag}`);
    options[name] = argv.shift();
  }
  for (const key of command === "write-report" ? allowed.filter((v) => v !== "repo") : ["report", "base", "head", "output"]) {
    if (!Object.hasOwn(options, key)) throw new Error(`missing --${key}`);
  }
  return options;
}
function write(path, value) { writeFileSync(path, JSON.stringify(value, null, 2) + "\n"); }

function writeReport(o) {
  const discovered = nulFile(o.inventory);
  const executedInventory = readFileSync(o["executed-inventory"]).length ? nulFile(o["executed-inventory"]) : [];
  const fields = readFileSync(o.records).length ? nulFile(o.records) : [];
  if (fields.length % 6) throw new Error("truncated suite receipt");
  const suites = [];
  for (let i = 0; i < fields.length; i += 6) {
    suites.push({ id: fields[i], verdict: fields[i + 1], exit: Number(fields[i + 2]), elapsed_seconds: Number(fields[i + 3]), metric_failure: fields[i + 4] === "1", reason: fields[i + 5] });
  }
  const suiteIds = new Set(executedInventory);
  const globalFailures = o["global-failures"].split(/\s+/).filter((id) => id && !suiteIds.has(id));
  const dirty = git(o.repo, ["status", "--porcelain", "-z", "--untracked-files=normal"]).length > 0;
  write(o.output, {
    schema: RUN_SCHEMA, base_sha: o.base, pr_head_sha: o.head, executed_sha: o.executed,
    executed_tree: git(o.repo, ["rev-parse", `${o.executed}^{tree}`]).trim(), dirty_checkout: dirty,
    complete: true, mode: o.mode, inventory: sort(discovered), executed_inventory: sort(executedInventory),
    suites: suites.sort((a, b) => a.id.localeCompare(b.id)),
    full_gate: { verdict: Number(o.exit) === 0 ? "pass" : "fail", exit: Number(o.exit), global_failures: sort([...new Set(globalFailures)]) },
    wall_seconds: Number(o.wall),
  });
}

function plan(o, actualInventory, policy) {
  const reasons = [];
  let base = null, head = null, diff = [], invalid = false;
  const selected = new Set(ALWAYS);
  try {
    if (policy.schema !== POLICY_SCHEMA || !equal(sort(policy.always_on || []), ALWAYS)) throw new Error("invalid policy/authority inventory");
    if (!actualInventory.length || !unique(actualInventory) || !ALWAYS.every((id) => actualInventory.includes(id))) throw new Error("missing/invalid suite inventory");
    base = commit(o.repo, o.base); head = commit(o.repo, o.head);
    const raw = git(o.repo, ["diff", "--name-status", "-z", "--find-renames", `${base}...${head}`, "--"]);
    if (raw && !raw.endsWith("\0")) throw new Error("truncated diff");
    const fields = raw ? raw.slice(0, -1).split("\0") : [];
    for (let i = 0; i < fields.length;) {
      const status = fields[i++], path = fields[i++];
      if (!status || path === undefined) throw new Error("malformed diff");
      let oldPath = null;
      if (/^[RC]/.test(status)) { oldPath = path; if (fields[i] === undefined) throw new Error("truncated rename"); }
      const destination = oldPath === null ? path : fields[i++];
      diff.push({ status, path: destination, ...(oldPath === null ? {} : { old_path: oldPath }) });
      const match = /^scripts\/tests\/([^/]+\.test\.sh)$/.exec(destination);
      if (status === "M" && match && actualInventory.includes(match[1])) {
        git(o.repo, ["cat-file", "-e", `${base}:${destination}`]);
        selected.add(match[1]);
      } else reasons.push(`${status}: ${JSON.stringify(destination)} requires full coverage`);
    }
    if (!diff.length) { reasons.push("no changes: no selection evidence"); invalid = true; }
  } catch (error) {
    reasons.push(`unavailable plan evidence: ${error.message}`); invalid = true;
  }
  const mode = reasons.length ? "full" : "subset";
  const chosen = mode === "full" ? actualInventory : sort([...selected]);
  return { mode, reasons, base_sha: base, pr_head_sha: head, changes: diff, selected: chosen, omitted: actualInventory.filter((id) => !chosen.includes(id)), invalid };
}

function compare(o) {
  let discovered = [], policy = {}, report = null;
  const errors = [];
  try { discovered = inventory(o.repo); } catch (error) { errors.push(`inventory: ${error.message}`); }
  try { policy = JSON.parse(readFileSync(resolve(o.repo, "config/ci-suite-selection.v1.json"), "utf8")); } catch (error) { errors.push(`policy: ${error.message}`); }
  const selection = plan(o, discovered, policy);
  try { report = JSON.parse(readFileSync(o.report, "utf8")); } catch (error) { errors.push(`full report unavailable: ${error.message}`); }
  let missing = [], duplicates = [], partial = false;
  if (report) {
    try {
      if (report.schema !== RUN_SCHEMA || report.complete !== true) throw new Error("wrong schema or incomplete run");
      if (report.base_sha !== o.base || report.pr_head_sha !== o.head) throw new Error("stale head/base binding");
      commit(o.repo, report.executed_sha);
      const checkout = git(o.repo, ["rev-parse", "HEAD"]).trim();
      if (checkout !== report.executed_sha || report.executed_tree !== git(o.repo, ["rev-parse", `${checkout}^{tree}`]).trim()) throw new Error("executed checkout/tree mismatch");
      const parents = git(o.repo, ["rev-list", "--parents", "-n", "1", checkout]).trim().split(" ").slice(1);
      if (checkout !== o.head && (parents.length !== 2 || !parents.includes(o.head) || !parents.includes(o.base))) throw new Error("executed merge does not bind both PR head and base");
      if (report.dirty_checkout !== false) throw new Error("dirty checkout is not exact-head evidence");
      if (git(o.repo, ["status", "--porcelain", "-z", "--untracked-files=normal"]).length) throw new Error("current working tree changed after report creation");
      if (!unique(report.inventory) || !equal(sort(report.inventory), discovered)) throw new Error("discovered inventory mismatch");
      if (!unique(report.executed_inventory) || !report.executed_inventory.every((id) => discovered.includes(id))) throw new Error("invalid executed inventory");
      if (!Array.isArray(report.suites)) throw new Error("missing suite receipts");
      const ids = report.suites.map((s) => s.id);
      duplicates = ids.filter((id, i) => ids.indexOf(id) !== i);
      missing = report.executed_inventory.filter((id) => !ids.includes(id));
      if (duplicates.length || missing.length || !equal(sort(ids), sort(report.executed_inventory))) throw new Error("missing/duplicate/extra suite receipts");
      for (const suite of report.suites) {
        if (!["pass", "fail", "quarantined"].includes(suite.verdict) || !integer(suite.exit) || suite.exit > 255 || !Number.isFinite(suite.elapsed_seconds) || suite.elapsed_seconds < 0 || typeof suite.metric_failure !== "boolean" || typeof suite.reason !== "string") throw new Error("invalid suite receipt");
        if (suite.verdict === "pass" && (suite.exit !== 0 || suite.metric_failure)) throw new Error("contradictory passing receipt");
        if ([129, 130, 143].includes(suite.exit) || ["missing-capture", "not-executable"].includes(suite.reason)) throw new Error("suite execution is missing or interrupted");
      }
      if (!report.full_gate || !["pass", "fail"].includes(report.full_gate.verdict) || !integer(report.full_gate.exit) || !Array.isArray(report.full_gate.global_failures) || !report.full_gate.global_failures.every((id) => typeof id === "string") || !Number.isFinite(report.wall_seconds) || report.wall_seconds < 0) throw new Error("invalid full-gate result");
      const hasFailures = report.suites.some((s) => s.verdict !== "pass") || report.full_gate.global_failures.length > 0;
      if (report.full_gate.verdict === "pass" && (report.full_gate.exit !== 0 || hasFailures)) throw new Error("false-green full-gate result");
      if (report.full_gate.verdict === "fail" && report.full_gate.exit === 0) throw new Error("contradictory full-gate exit");
      if (report.full_gate.verdict === "fail" && !hasFailures) throw new Error("unexplained failing gate result");
      if (o["gate-outcome"] && !["success", "failure"].includes(o["gate-outcome"])) throw new Error("full gate did not complete");
      if (o["gate-outcome"] && (o["gate-outcome"] === "success") !== (report.full_gate.verdict === "pass")) throw new Error("workflow/runner outcome mismatch");
      if (o["policy-outcome"] === "failure") {
        report.full_gate = { verdict: "fail", exit: 1, global_failures: [...report.full_gate.global_failures, "policy-view-drift"] };
      } else if (o["policy-outcome"] && o["policy-outcome"] !== "success" && report.full_gate.verdict === "pass") {
        throw new Error("policy-view drift did not complete");
      }
      if (!["full", "partial"].includes(report.mode)) throw new Error("invalid run mode");
      partial = report.mode === "partial";
      if (!partial && !equal(sort(report.executed_inventory), discovered)) throw new Error("incomplete full-run inventory");
    } catch (error) { errors.push(error.message); }
  }
  const valid = errors.length === 0 && !selection.invalid && !partial;
  const selectedFailures = valid ? report.suites.filter((s) => selection.selected.includes(s.id) && s.verdict !== "pass").map((s) => s.id) : [];
  const omittedFailures = valid ? report.suites.filter((s) => selection.omitted.includes(s.id) && s.verdict !== "pass").map((s) => s.id) : [];
  let assessment = !valid ? (partial && !errors.length ? "NOT_COMPARABLE_PARTIAL" : "UNKNOWN") : report.full_gate.verdict === "pass" ? "COMPLETE_PASS" : "COMPLETE_FAIL";
  let result = {
    schema: SHADOW_SCHEMA, authority: "advisory-only", assessment,
    base_sha: selection.base_sha, pr_head_sha: selection.pr_head_sha, executed_sha: report?.executed_sha ?? null,
    mode: selection.mode, reasons: selection.reasons, changes: selection.changes,
    inventory: discovered, executed_inventory: report?.executed_inventory ?? [], selected: selection.selected, omitted: selection.omitted,
    completeness: { valid, errors, missing, duplicates, partial },
    full_gate: report?.full_gate ?? null, suites: report?.suites ?? [],
    retained_global_checks: { policy_view_drift: o["policy-outcome"] || "unreported", runner_global_failures: report?.full_gate?.global_failures ?? null },
    selected_failures: selectedFailures, omitted_failures: omittedFailures,
    would_false_green: valid && o["policy-outcome"] === "success" && report.full_gate.global_failures.length === 0 ? selectedFailures.length === 0 && omittedFailures.length > 0 : null,
    wall_seconds: valid ? report.wall_seconds : null,
    omitted_suite_seconds: valid ? report.suites.filter((s) => selection.omitted.includes(s.id)).reduce((n, s) => n + s.elapsed_seconds, 0) : null,
    note: "Shadow only: the existing gate runs unchanged. Suite-seconds are not wall-time savings. Production dependency closure is not established.",
  };
  // Bound the final serialized comparison before either output or summary can
  // claim completeness. Never persist a truncated selection or receipt list.
  if (Buffer.byteLength(JSON.stringify(result, null, 2) + "\n") > MAX_EVIDENCE_BYTES) {
    assessment = "UNKNOWN";
    result = {
      schema: SHADOW_SCHEMA, authority: "advisory-only", assessment, mode: "full",
      base_sha: selection.base_sha, pr_head_sha: selection.pr_head_sha, executed_sha: report?.executed_sha ?? null,
      completeness: { valid: false, errors: ["complete comparison exceeds 128 KiB persistence limit"] },
      evidence_omitted_due_to_size: true, would_false_green: null,
      note: "Complete comparison withheld because it exceeds the persistence limit. No partial selection or receipts are emitted; the required gate remains unchanged.",
    };
  }
  write(o.output, result);
  const counts = result.evidence_omitted_due_to_size ? "Selection counts unavailable (oversize evidence)." : `Selected ${result.selected.length}/${result.inventory.length}; omitted ${result.omitted.length}.`;
  const summary = `### CI suite selection (shadow only)\n\nAssessment: **${assessment}**. Mode: **${result.mode}**. ${counts}\n\nFull gate: ${result.full_gate?.verdict ?? "unknown"}. Omitted failures: ${result.omitted_failures?.length ?? "unknown"}. Would false-green: ${result.would_false_green ?? "unknown/not comparable"}.\n\nActual wall seconds: ${result.wall_seconds ?? "unknown"}; omitted suite-seconds: ${result.omitted_suite_seconds ?? "unknown"} (not wall-time savings).\n\n${result.note}\n\nReasons/errors: ${[...(result.reasons ?? []), ...result.completeness.errors].map((s) => JSON.stringify(s)).join("; ") || "exact modified-test mapping"}\n`;
  if (o.summary) appendFileSync(o.summary, summary);
  console.log(JSON.stringify({ assessment, mode: result.mode, output: o.output }));
  return assessment === "UNKNOWN" ? 1 : 0;
}

function main() {
  try {
    const o = parseArgs(process.argv.slice(2));
    if (o.command === "help") {
      console.log("ci-suite-selection.mjs — advisory shadow evidence; never runs tests\ncompare --report FILE --base SHA --head SHA --output FILE [--summary FILE] [--repo DIR]\nwrite-report --records FILE --inventory FILE --executed-inventory FILE --base SHA --head SHA --executed SHA --exit N --wall N --global-failures TEXT --mode full|partial --output FILE [--repo DIR]");
      return 0;
    }
    if (o.command === "write-report") { writeReport(o); return 0; }
    return compare(o);
  } catch (error) { console.error(`ci-suite-selection: ${error.message}`); return 2; }
}
// Resolve both sides: /var and /private/var (and ordinary symlinks) name the same executable.
if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) process.exitCode = main();
