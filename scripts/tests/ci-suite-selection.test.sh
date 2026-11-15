#!/usr/bin/env bash
# Offline shadow-planner and actual runner reporting controls (#746).
set -uo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/gibson-ci-suite-selection.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/check.mjs" <<'JS'
import assert from "node:assert/strict";
import { spawnSync, execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, symlinkSync, writeFileSync, chmodSync } from "node:fs";
import { resolve } from "node:path";
const [root, scratch] = process.argv.slice(2);
const cli = resolve(root, "scripts/ci-suite-selection.mjs");
const policy = JSON.parse(readFileSync(resolve(root, "config/ci-suite-selection.v1.json")));
let passed = 0, failed = 0, count = 0;
const quote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
function check(name, fn) { try { fn(); passed++; console.log(`ok - ${name}`); } catch (e) { failed++; console.log(`FAIL - ${name}: ${e.stack}`); } }
function git(dir, ...args) { return execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim(); }
function file(dir, name, content) { mkdirSync(resolve(dir, name, ".."), { recursive: true }); writeFileSync(resolve(dir, name), content); }
function fixture(change = (dir) => file(dir, "scripts/tests/alpha.test.sh", "#!/bin/bash\necho changed\n")) {
  const dir = resolve(scratch, `repo-${count++}`); mkdirSync(dir);
  git(dir, "init", "-q"); git(dir, "config", "user.name", "fixture"); git(dir, "config", "user.email", "fixture@example.invalid"); git(dir, "config", "commit.gpgsign", "false"); git(dir, "config", "core.hooksPath", "/dev/null");
  copyFileSync(cli, resolve(scratch, "current-cli.mjs"));
  file(dir, "config/ci-suite-selection.v1.json", JSON.stringify(policy));
  file(dir, "scripts/ci-suite-selection.mjs", readFileSync(cli));
  for (const id of [...policy.always_on, "alpha.test.sh", "alpha-extra.test.sh", "other.test.sh", "space test.test.sh", "line\nbreak.test.sh"]) file(dir, `scripts/tests/${id}`, `#!/bin/bash\necho executed >> ${quote(resolve(scratch, "planner-executed"))}\necho '1 passed, 0 failed'\n`);
  for (const name of ["scripts/digest.sh", "scripts/decision-ledger.sh", "scripts/queue-order.mjs", "scripts/lib/shared.sh", "scripts/tests/fixtures/shared.txt", "README.md"]) file(dir, name, "original\n");
  for (const id of readdirSync(resolve(dir, "scripts/tests")).filter((name) => name.endsWith(".test.sh"))) chmodSync(resolve(dir, "scripts/tests", id), 0o755);
  git(dir, "add", "."); git(dir, "commit", "-qm", "base"); const base = git(dir, "rev-parse", "HEAD");
  change(dir);
  git(dir, "add", "-A"); git(dir, "commit", "--allow-empty", "-qm", "candidate"); const head = git(dir, "rev-parse", "HEAD");
  const ids = readdirSync(resolve(dir, "scripts/tests")).filter((name) => name.endsWith(".test.sh")).sort();
  const report = { schema: "gibson.ci-full-run/v1", base_sha: base, pr_head_sha: head, executed_sha: head, executed_tree: git(dir, "rev-parse", "HEAD^{tree}"), dirty_checkout: false, complete: true, mode: "full", inventory: ids, executed_inventory: ids, suites: ids.map((id) => ({ id, verdict: "pass", exit: 0, elapsed_seconds: 2, metric_failure: false, reason: "passed" })), full_gate: { verdict: "pass", exit: 0, global_failures: [] }, wall_seconds: 3 };
  return { dir, base, head, report };
}
function compare(f, mutate = () => {}, extra = [], executable = cli) {
  const report = structuredClone(f.report); mutate(report);
  const input = resolve(scratch, `report-${count++}.json`), output = resolve(scratch, `comparison-${count++}.json`);
  writeFileSync(input, JSON.stringify(report));
  const result = spawnSync(process.execPath, [executable, "compare", "--repo", f.dir, "--report", input, "--base", f.base, "--head", f.head, "--output", output, ...extra], { encoding: "utf8", timeout: 15000 });
  assert.equal(result.error, undefined);
  return { result, value: JSON.parse(readFileSync(output)) };
}
function unknown(f, mutate, extra = []) { const { result, value } = compare(f, mutate, extra); assert.equal(result.status, 1); assert.equal(value.assessment, "UNKNOWN"); assert.equal(value.would_false_green, null); }
const f = fixture();
check("exact modified suite, no substring expansion, exhaustive partition", () => {
  const { result, value } = compare(f); assert.equal(result.status, 0); assert.equal(value.mode, "subset"); assert.equal(value.assessment, "COMPLETE_PASS");
  assert(value.selected.includes("alpha.test.sh")); assert(value.omitted.includes("alpha-extra.test.sh"));
  assert.deepEqual(value.selected, [...policy.always_on, "alpha.test.sh"].sort());
  assert.deepEqual([...value.selected, ...value.omitted].sort(), f.report.inventory); assert.equal(value.omitted_suite_seconds, value.omitted.length * 2); assert.equal(value.wall_seconds, 3);
});
for (const path of ["scripts/digest.sh", "scripts/decision-ledger.sh", "scripts/queue-order.mjs", "scripts/lib/shared.sh", "scripts/tests/fixtures/shared.txt", "config/ci-suite-selection.v1.json", "README.md", "unknown path.txt", ".github/workflows/change.yml", "scripts/tests/new.test.sh"]) {
  check(`conservative full fallback: ${path}`, () => {
    const candidate = fixture((dir) => file(dir, path, path.endsWith(".json") ? JSON.stringify(policy, null, 4) : "changed\n"));
    const { value } = compare(candidate); assert.equal(value.mode, "full"); assert.equal(value.omitted.length, 0); assert(value.reasons.length > 0);
  });
}
check("deleted file falls back full", () => { const c = fixture((dir) => git(dir, "rm", "scripts/tests/alpha.test.sh")); assert.equal(compare(c).value.mode, "full"); });
check("renamed file falls back full and retains both paths", () => { const c = fixture((dir) => git(dir, "mv", "scripts/tests/alpha.test.sh", "scripts/tests/renamed.test.sh")); const v = compare(c).value; assert.equal(v.mode, "full"); assert(v.changes.some((x) => x.old_path === "scripts/tests/alpha.test.sh")); });
for (const id of ["space test.test.sh", "line\nbreak.test.sh"]) check(`NUL-safe exact filename ${JSON.stringify(id)}`, () => { const c = fixture((dir) => file(dir, `scripts/tests/${id}`, "changed\n")); const v = compare(c).value; assert.equal(v.mode, "subset"); assert(v.selected.includes(id)); assert.equal(v.changes.length, 1); });
check("invalid base falls back full and is unknown", () => { const c = { ...f, base: "0".repeat(40) }; const { value } = compare(c); assert.equal(value.mode, "full"); assert.equal(value.assessment, "UNKNOWN"); });
check("no-op is never selection success", () => unknown(fixture(() => {}), () => {}));
check("synthetic merge binds both actual base and PR head", () => {
  const c = fixture(); const originalHead = c.head;
  git(c.dir, "checkout", "-qb", "main-side", c.base); file(c.dir, "README.md", "main advanced\n"); git(c.dir, "add", "."); git(c.dir, "commit", "-qm", "base advance");
  c.base = git(c.dir, "rev-parse", "HEAD"); git(c.dir, "merge", "--no-ff", "-qm", "merge candidate", originalHead);
  c.report.base_sha = c.base; c.report.executed_sha = git(c.dir, "rev-parse", "HEAD"); c.report.executed_tree = git(c.dir, "rev-parse", "HEAD^{tree}");
  assert.equal(compare(c).value.assessment, "COMPLETE_PASS");
  const oldBase = git(c.dir, "rev-parse", `${c.base}^`); const wrong = { ...c, base: oldBase }; wrong.report = structuredClone(c.report); wrong.report.base_sha = oldBase;
  unknown(wrong, () => {});
});
check("selected failure is exposed", () => { const { value } = compare(f, (r) => { Object.assign(r.suites.find((s) => s.id === "alpha.test.sh"), { verdict: "fail", exit: 1 }); r.full_gate = { verdict: "fail", exit: 1, global_failures: [] }; }, ["--policy-outcome", "success"]); assert.equal(value.assessment, "COMPLETE_FAIL"); assert.deepEqual(value.selected_failures, ["alpha.test.sh"]); assert.equal(value.would_false_green, false); });
check("omitted failure exposes hypothetical false green", () => { const { value } = compare(f, (r) => { Object.assign(r.suites.find((s) => s.id === "other.test.sh"), { verdict: "fail", exit: 1 }); r.full_gate = { verdict: "fail", exit: 1, global_failures: [] }; }, ["--policy-outcome", "success"]); assert.equal(value.assessment, "COMPLETE_FAIL"); assert.deepEqual(value.omitted_failures, ["other.test.sh"]); assert.equal(value.would_false_green, true); });
for (const outcome of ["skipped", null]) check(`omitted failure with ${outcome || "missing"} policy outcome remains unknown`, () => {
  const extra = ["--gate-outcome", "failure", ...(outcome ? ["--policy-outcome", outcome] : [])];
  const { value } = compare(f, (r) => { Object.assign(r.suites.find((s) => s.id === "other.test.sh"), { verdict: "fail", exit: 1 }); r.full_gate = { verdict: "fail", exit: 1, global_failures: [] }; }, extra);
  assert.equal(value.assessment, "COMPLETE_FAIL"); assert.deepEqual(value.omitted_failures, ["other.test.sh"]); assert.equal(value.would_false_green, null);
  assert.equal(value.retained_global_checks.policy_view_drift, outcome || "unreported");
});
check("actual tracked edit after a clean report invalidates unchanged HEAD", () => {
  const path = resolve(f.dir, "README.md"), original = readFileSync(path);
  try { writeFileSync(path, "changed after report\n"); assert.equal(git(f.dir, "rev-parse", "HEAD"), f.head); unknown(f, () => {}); }
  finally { writeFileSync(path, original); }
});
check("global failure cannot imply safe selection", () => { const { value } = compare(f, (r) => { r.full_gate = { verdict: "fail", exit: 1, global_failures: ["injection-scan"] }; }); assert.equal(value.assessment, "COMPLETE_FAIL"); assert.equal(value.would_false_green, null); });
check("policy drift failure remains a full gate failure", () => { const { value } = compare(f, () => {}, ["--gate-outcome", "success", "--policy-outcome", "failure"]); assert.equal(value.assessment, "COMPLETE_FAIL"); assert(value.full_gate.global_failures.includes("policy-view-drift")); });
check("cancelled workflow result is unknown", () => unknown(f, () => {}, ["--gate-outcome", "cancelled"]));
check("workflow/runner contradiction is unknown", () => unknown(f, () => {}, ["--gate-outcome", "failure"]));
for (const [name, mutate] of [
  ["incomplete", (r) => { r.complete = false; }],
  ["interrupted suite", (r) => { Object.assign(r.suites[0], { verdict: "fail", exit: 143 }); r.full_gate = { verdict: "fail", exit: 1, global_failures: [] }; }],
  ["missing capture", (r) => { Object.assign(r.suites[0], { verdict: "fail", exit: 1, reason: "missing-capture" }); r.full_gate = { verdict: "fail", exit: 1, global_failures: [] }; }],
  ["missing", (r) => { r.suites.pop(); }],
  ["duplicate", (r) => { r.suites.push(r.suites[0]); }],
  ["empty", (r) => { r.inventory = []; r.executed_inventory = []; r.suites = []; }],
  ["inventory drift", (r) => { r.inventory.pop(); }],
  ["stale head", (r) => { r.pr_head_sha = f.base; }],
  ["stale executed checkout", (r) => { r.executed_sha = f.base; }],
  ["tree mismatch", (r) => { r.executed_tree = "0".repeat(40); }],
  ["dirty source", (r) => { r.dirty_checkout = true; }],
  ["exit-zero metric failure falsely passed", (r) => { r.suites[0].metric_failure = true; }],
  ["contradictory green gate", (r) => { r.suites[0].verdict = "fail"; }],
]) check(`${name} report is unknown`, () => unknown(f, mutate));
check("intentional docs partial evidence is not comparable", () => { const { result, value } = compare(f, (r) => { r.mode = "partial"; r.executed_inventory = policy.always_on; r.suites = r.suites.filter((s) => policy.always_on.includes(s.id)); }); assert.equal(result.status, 0); assert.equal(value.assessment, "NOT_COMPARABLE_PARTIAL"); assert.equal(value.completeness.valid, false); assert.equal(value.would_false_green, null); });
for (const type of ["missing", "truncated"]) check(`${type} file emits unknown evidence`, () => {
  const input = resolve(scratch, `${type}.json`), output = resolve(scratch, `${type}-out.json`);
  if (type === "truncated") writeFileSync(input, '{"schema":');
  const r = spawnSync(process.execPath, [cli, "compare", "--repo", f.dir, "--report", input, "--base", f.base, "--head", f.head, "--output", output]);
  assert.equal(r.status, 1); assert.equal(JSON.parse(readFileSync(output)).assessment, "UNKNOWN");
});
const link = resolve(scratch, "selector-link.mjs"); symlinkSync(cli, link);
for (const executable of [cli, realpathSync(cli), link]) check(`real CLI bad flags: ${executable === link ? "symlink" : "canonical"}`, () => {
  for (const args of [["--definitely-not-a-flag"], ["compare", "--head"], ["compare", "--unknown", "value"]]) {
    const r = spawnSync(process.execPath, [executable, ...args], { timeout: 3000 }); assert.equal(r.status, 2); assert(r.stderr.length > 0);
    if (args.length !== 2) assert.match(r.stderr.toString(), /unknown (flag|option):/);
  }
  assert.equal(compare(f, () => {}, [], executable).value.assessment, "COMPLETE_PASS");
});

check("planner never executes selected or omitted suites", () => assert.equal(existsSync(resolve(scratch, "planner-executed")), false));

check("real runner early exits list reporting flags and reject missing value before suites", () => {
  const dir = resolve(scratch, "early-exit-copy"), runner = resolve(dir, "scripts/tests/run-all.sh");
  file(dir, "scripts/tests/run-all.sh", readFileSync(resolve(root, "scripts/tests/run-all.sh")));
  for (const helper of ["scripts/tests/lib/convention-sensors.sh", "scripts/lib/convention-probes.sh"]) file(dir, helper, readFileSync(resolve(root, helper)));
  const sentinel = resolve(scratch, "early-exit-suite-ran");
  file(dir, "scripts/tests/should-not-run.test.sh", `#!/bin/bash\ntouch ${quote(sentinel)}\n`); chmodSync(resolve(dir, "scripts/tests/should-not-run.test.sh"), 0o755);
  const help = spawnSync("bash", [runner, "--help"], { cwd: dir, encoding: "utf8", timeout: 3000 });
  assert.equal(help.status, 0, help.stderr); assert(help.stdout.includes("--results-json")); assert(help.stdout.includes("--results-base")); assert(help.stdout.includes("--results-head"));
  const missing = spawnSync("bash", [runner, "--results-json"], { cwd: dir, encoding: "utf8", timeout: 3000 });
  assert.equal(missing.status, 2, missing.stdout + missing.stderr); assert(missing.stderr.includes("requires a value")); assert.equal(existsSync(sentinel), false);
});

check("actual runner option parser accepts env defaults and CLI overrides", () => {
  const source = readFileSync(resolve(root, "scripts/tests/run-all.sh"), "utf8");
  const start = source.indexOf('ONLY=""\nTIMEOUT=600'), end = source.indexOf("# GIBSON_METRICS_CONTRACT_FIXTURE_SKIP_PREAMBLE");
  assert(start > 0 && end > start);
  const parser = resolve(scratch, "runner-options.sh");
  writeFileSync(parser, "#!/bin/bash\nset -uo pipefail\n" + source.slice(start, end) + 'printf "%s\\0%s\\0%s\\0" "$RESULTS_JSON" "$RESULTS_BASE" "$RESULTS_HEAD"\n');
  const env = { ...process.env, GIBSON_SUITE_REPORT_PATH: "/fixture/report path.json", GIBSON_SUITE_REPORT_BASE: "base", GIBSON_SUITE_REPORT_HEAD: "head" };
  const defaults = spawnSync("bash", [parser], { env, encoding: "utf8" }); assert.equal(defaults.status, 0); assert.equal(defaults.stdout, "/fixture/report path.json\0base\0head\0");
  const flags = spawnSync("bash", [parser, "--results-json", "/override.json", "--results-base", "override-base", "--results-head", "override-head"], { env, encoding: "utf8" }); assert.equal(flags.status, 0); assert.equal(flags.stdout, "/override.json\0override-base\0override-head\0");
});

check("runner report opt-in is consumed before child processes", () => {
  const parser = resolve(scratch, "runner-options.sh"), script = resolve(scratch, "runner-child-env.sh"), report = resolve(scratch, "parent-owned-report.json");
  writeFileSync(report, "parent owns this report");
  const child = 'const fs=require("node:fs"); if(process.env.GIBSON_SUITE_REPORT_PATH) fs.writeFileSync(process.env.GIBSON_SUITE_REPORT_PATH,"overwritten"); console.log(JSON.stringify([process.env.GIBSON_SUITE_REPORT_PATH??null,process.env.GIBSON_SUITE_REPORT_BASE??null,process.env.GIBSON_SUITE_REPORT_HEAD??null]));';
  writeFileSync(script, readFileSync(parser, "utf8") + `${quote(process.execPath)} -e ${quote(child)}\n`);
  const r = spawnSync("bash", [script], { encoding: "utf8", env: { ...process.env, GIBSON_SUITE_REPORT_PATH: report, GIBSON_SUITE_REPORT_BASE: "base", GIBSON_SUITE_REPORT_HEAD: "head" } });
  assert.equal(r.status, 0, r.stderr); assert.equal(readFileSync(report, "utf8"), "parent owns this report");
  assert.deepEqual(JSON.parse(r.stdout.split("\0").slice(3).join("\0")), [null, null, null]);
});

function persistWorkflow(f, contents) {
  const workflow = readFileSync(resolve(root, ".github/workflows/gibson-self-gate.yml"), "utf8");
  const section = workflow.split("      - name: Compare shadow suite selection (advisory)\n")[1].split("      # Advisory: the burn-down view.")[0];
  const body = section.split("        run: |\n")[1].split("\n").map((line) => line.startsWith("          ") ? line.slice(10) : line).join("\n");
  assert(body.includes("GIBSON_CI_SHADOW_JSON_BEGIN"));
  const temp = resolve(scratch, `persistence-${count++}`); mkdirSync(temp);
  if (contents !== null) writeFileSync(resolve(temp, "ci-suite-results.json"), contents);
  const summary = resolve(temp, "summary.md"), script = resolve(temp, "step.sh"); writeFileSync(script, body);
  const result = spawnSync("bash", ["-eo", "pipefail", script], { cwd: f.dir, encoding: "utf8", timeout: 15000, env: { ...process.env, RUNNER_TEMP: temp, GITHUB_STEP_SUMMARY: summary, SELECTION_BASE: f.base, SELECTION_HEAD: f.head, SENSOR_OUTCOME: "success", POLICY_OUTCOME: "success" } });
  assert.equal(result.error, undefined);
  return { result, summary: readFileSync(summary, "utf8"), comparison: JSON.parse(readFileSync(resolve(temp, "ci-suite-selection.json"))) };
}
check("actual advisory workflow persists complete JSON in summary and log", () => {
  const f = fixture(), raw = JSON.stringify(f.report), p = persistWorkflow(f, raw);
  assert.equal(p.result.status, 0, p.result.stderr); assert.equal(p.comparison.assessment, "COMPLETE_PASS");
  assert(p.summary.includes(raw)); assert(p.result.stdout.includes(raw));
  for (const name of ["ci-suite-results.json", "ci-suite-selection.json"]) { assert(p.result.stdout.includes(`GIBSON_CI_SHADOW_JSON_BEGIN ${name}`)); assert(p.result.stdout.includes(`GIBSON_CI_SHADOW_JSON_END ${name}`)); assert(p.summary.includes(`<summary>${name}</summary>`)); }
});
check("actual advisory workflow persists UNKNOWN on missing report and comparison failure", () => {
  const p = persistWorkflow(fixture(), null); assert.equal(p.result.status, 1); assert.equal(p.comparison.assessment, "UNKNOWN");
  assert(p.result.stdout.includes("GIBSON_CI_SHADOW_JSON_UNAVAILABLE ci-suite-results.json assessment=UNKNOWN")); assert(p.result.stdout.includes("GIBSON_CI_SHADOW_JSON_END ci-suite-selection.json")); assert(p.summary.includes("UNKNOWN/incomplete evidence"));
});
check("actual advisory workflow marks oversize evidence UNKNOWN without truncation", () => {
  const f = fixture(), p = persistWorkflow(f, JSON.stringify(f.report) + " ".repeat(131072));
  assert.equal(p.result.status, 1); assert.equal(p.comparison.assessment, "UNKNOWN"); assert.equal(p.comparison.completeness.valid, false);
  assert(!p.result.stdout.includes("GIBSON_CI_SHADOW_JSON_BEGIN ci-suite-results.json")); assert(!p.result.stdout.includes("COMPLETE_PASS")); assert(p.summary.includes("larger than 128 KiB"));
});

check("oversize comparison becomes bounded UNKNOWN before summary or log claims", () => {
  const f = fixture((dir) => { for (let i = 0; i < 700; i++) file(dir, `production/${i}-${"x".repeat(160)}.txt`, "new\n"); });
  const raw = JSON.stringify(f.report); assert(Buffer.byteLength(raw) < 131072);
  const p = persistWorkflow(f, raw); assert.equal(p.result.status, 1); assert.equal(p.comparison.assessment, "UNKNOWN");
  assert.equal(p.comparison.evidence_omitted_due_to_size, true); assert.equal(p.comparison.completeness.valid, false); assert.equal(p.comparison.would_false_green, null);
  assert(Buffer.byteLength(JSON.stringify(p.comparison, null, 2)) < 131072); assert(!p.summary.includes("COMPLETE_PASS")); assert(!p.result.stdout.includes("COMPLETE_PASS"));
  assert(p.result.stdout.includes("GIBSON_CI_SHADOW_JSON_END ci-suite-selection.json"));
});

// Exercise the production metrics, capture, semantic classification and export loop
// verbatim, with only its unrelated preamble replaced by bounded fixture inputs.
// No production test-skipping switch is added to run-all.
check("actual runner capture/classifier exports exit-zero diagnostics and metric failures once", () => {
  const dir = resolve(scratch, "runner-fixture"); mkdirSync(dir);
  file(dir, "scripts/ci-suite-selection.mjs", readFileSync(cli));
  file(dir, "scripts/queue-order.mjs", "// fixture help succeeds\n");
  const bodies = {
    "pass.test.sh": "echo '1 passed, 0 failed'\n",
    "bash32-syntax-each.test.sh": "echo '1 passed, 0 failed'\n",
    "diagnostic.test.sh": "echo 'fixture.sh: line 2: sample: command not found'\necho '1 passed, 0 failed'\n",
    "metric.test.sh": "echo 'GIBSON_TEST_METRICS total=oops skipped=0 todo=0'\n",
  };
  for (const [name, body] of Object.entries(bodies)) { file(dir, `scripts/tests/${name}`, `#!/bin/bash\nprintf '%s\\n' '${name}' >> '${scratch}/executions'\n${body}`); chmodSync(resolve(dir, "scripts/tests", name), 0o755); }
  git(dir, "init", "-q"); git(dir, "config", "user.name", "fixture"); git(dir, "config", "user.email", "fixture@example.invalid"); git(dir, "config", "commit.gpgsign", "false"); git(dir, "config", "core.hooksPath", "/dev/null"); git(dir, "add", "."); git(dir, "commit", "-qm", "fixture");
  const sha = git(dir, "rev-parse", "HEAD");
  const source = readFileSync(resolve(root, "scripts/tests/run-all.sh"), "utf8");
  const marker = "# --- aggregate metrics production seam (#274/#279)";
  assert.equal(source.split(marker).length, 2);
  const report = resolve(scratch, "actual-runner-results.json");
  const header = `#!/bin/bash\nset -uo pipefail\nREPO_ROOT=${quote(dir)}\ncd "$REPO_ROOT"\nMETRICS_CONTRACT_FIXTURE=0\nRUN_ALL_T0=$SECONDS\nFAILED=\nESCAPED=\nQUARANTINED=\nRED=\nGRN=\nYEL=\nOFF=\nONLY=\nTIMEOUT=0\nJOBS=1\nQUIET=1\nWALL_BUDGET=0\nBASH32_DOCKER_USABLE=1\nBASH32_PATHS_SHA256=${"a".repeat(64)}\n${source.split("\n").filter((line) => /^(RESULTS_(JSON|BASE|HEAD)=|unset GIBSON_SUITE_REPORT_PATH )/.test(line)).join("\n")}\nrun_limited() { bash "$1"; }\nis_quarantined() { return 1; }\nquarantine_issue() { return 1; }\n`;
  const harness = resolve(scratch, "runner-harness.sh"); writeFileSync(harness, header + marker + source.split(marker)[1]);
  const reportEnv = { ...process.env, GIBSON_SUITE_REPORT_PATH: report, GIBSON_SUITE_REPORT_BASE: sha, GIBSON_SUITE_REPORT_HEAD: sha };
  const r = spawnSync("bash", [harness], { env: reportEnv, encoding: "utf8", timeout: 20000 });
  assert.equal(r.error, undefined); assert.equal(r.status, 1, r.stdout + r.stderr);
  const actual = JSON.parse(readFileSync(report)); assert.equal(actual.full_gate.verdict, "fail");
  assert.equal(actual.suites.length, 4); assert.equal(actual.suites.find((s) => s.id === "pass.test.sh").verdict, "pass");
  assert.equal(actual.suites.find((s) => s.id === "bash32-syntax-each.test.sh").reason, "bash32-receipt");
  const diagnostic = actual.suites.find((s) => s.id === "diagnostic.test.sh"); assert.equal(diagnostic.exit, 0); assert.equal(diagnostic.verdict, "fail"); assert.equal(diagnostic.reason, "shell-diagnostic");
  const metric = actual.suites.find((s) => s.id === "metric.test.sh"); assert.equal(metric.exit, 0); assert.equal(metric.verdict, "fail"); assert.equal(metric.metric_failure, true);
  const executions = readFileSync(resolve(scratch, "executions"), "utf8").trim().split("\n"); assert.equal(executions.length, 4); assert.equal(new Set(executions).size, 4);
  // A passing fixture preserves terminal machine metrics and its exit status.
  file(dir, "scripts/tests/diagnostic.test.sh", "#!/bin/bash\necho '1 passed, 0 failed'\n");
  file(dir, "scripts/tests/metric.test.sh", "#!/bin/bash\necho '1 passed, 0 failed'\n");
  writeFileSync(harness, readFileSync(harness, "utf8").replace("BASH32_DOCKER_USABLE=1", "BASH32_DOCKER_USABLE=0"));
  const green = spawnSync("bash", [harness], { env: reportEnv, encoding: "utf8", timeout: 20000 }); assert.equal(green.status, 0, green.stdout + green.stderr);
  assert.match(green.stdout.trim().split("\n").at(-1), /^GIBSON_TEST_METRICS total=4 skipped=0 todo=0$/);
  assert.equal(JSON.parse(readFileSync(report)).full_gate.verdict, "pass");
});
console.log(`ci-suite-selection.test.sh: ${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
JS
node "$TMP/check.mjs" "$REPO_ROOT" "$TMP"
