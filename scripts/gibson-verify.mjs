#!/usr/bin/env node
/**
 * gibson-verify.mjs — the verification lever: doctor, check, prove, verdict
 * lint, report (#447). Run `--help` for the full contract.
 *
 * WHAT IT DOES
 *   Produces JSON proof bound to an exact head SHA before an agent says
 *   "done": doctor (preflight), check (clean tree + non-empty diff + gate +
 *   truthful-status), prove (check + .gibson-receipts/<HEAD>.json), verdict
 *   lint (second-opinion.sh parse_isolated_verdict, mirrored), report
 *   (Agent Kontrol /api/ingest milestone: verified or claim-only).
 *
 * WHY
 *   Law 8 / L-008: prose is not proof and a no-op run is not success.
 *
 * RISKS
 *   check/prove run the gate (its runtime). Receipts are local, gitignored
 *   evidence, never merge authority; CI stays authoritative. report without
 *   --dry-run POSTs with MC_TOKEN. Env values are never printed.
 *
 * EXIT  0 ok/verified/parseable · 1 failed/claim-only/unparseable/I-O · 2 usage
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync, lstatSync, realpathSync, rmSync } from "node:fs";
import { join, dirname, resolve, isAbsolute } from "node:path";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { parseFlags, dieUsage } from "./lib/args.mjs";
import { inspectTooling, cachedTooling, proveTooling } from "./lib/tooling-readiness.mjs";

const GIBSON = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SCHEMA = "gibson.verify-receipt.v1";
const RECEIPT_DIR = ".gibson-receipts";
const PREFIX = "gibson-verify: ";

function help() {
  console.log(`gibson-verify.mjs — verification lever (#447)

WHAT IT DOES
  Machine-readable proof bound to an exact head SHA before an agent claims
  done; reports verified or claim-only to Agent Kontrol.

WHY
  Law 8 / L-008: prose is not proof; a run that changed nothing is not success.

RISKS
  check/prove run the gate. Receipts are local evidence, never merge
  authority. report without --dry-run POSTs with MC_TOKEN.

USAGE
  gibson-verify.mjs doctor [--repo DIR] [--gate FILE] [--base REF] [--tooling-only]
                         [--require-proof] [--adoption]
  gibson-verify.mjs check  [--repo DIR] [--base REF] [--gate FILE] [--gate-arg ARG]...
  gibson-verify.mjs prove  (same flags as check; writes ${RECEIPT_DIR}/<HEAD>.json)
                         [--adoption] [--refresh-tooling]
  gibson-verify.mjs verdict lint FILE
  gibson-verify.mjs report --agent ID [--repo DIR] [--receipt FILE] [--pr N]
                           [--issue N] [--platform P] [--dry-run]

  Defaults: --repo cwd, --base origin/main, --gate <gibson>/scripts/gate.sh
  (in the Gibson repo itself: --gate scripts/tests/run-all.sh).

EXIT
  0 ok/verified/parseable  1 failed/claim-only/unparseable  2 usage`);
}

const out = (obj) => console.log(JSON.stringify(obj, null, 2));
const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");
const firstLine = (s) => String(s).split("\n")[0].trim();

function run(cmd, args, opts = {}) {
  const t = Date.now();
  const r = spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, ...opts });
  // A signal or spawn error has no exit status; never read that as success.
  const code = r.error || r.status === null ? 127 : r.status;
  return { code, stdout: r.stdout || "", stderr: r.stderr || "", ms: Date.now() - t };
}

function git(repo, args) {
  const r = run("git", ["-C", repo, ...args]);
  if (r.code !== 0) throw new Error(`git ${args.join(" ")}: ${firstLine(r.stderr) || `exit ${r.code}`}`);
  return r.stdout.trim();
}

const toplevel = (dir) => git(resolve(dir || "."), ["rev-parse", "--show-toplevel"]);
const gatePath = (repo, gate) => (!gate ? join(GIBSON, "scripts", "gate.sh") : isAbsolute(gate) ? gate : join(repo, gate));

function isExecutable(p) {
  try { const st = statSync(p); return st.isFile() && (st.mode & 0o111) !== 0; } catch { return false; }
}

// ---------------------------------------------------------------- doctor
function doctor(o) {
  if (o.toolingOnly) {
    const repo = resolve(o.repo || ".");
    const tooling = inspectTooling({ repo, base: o.base, adoption: o.adoption, run, git });
    const proof = o.requireProof && tooling.configured ? cachedTooling(repo, tooling, git(repo, ["rev-parse", "HEAD"]), o.adoption) : null;
    const ok = !tooling.required || (tooling.configured && (!o.requireProof || Boolean(proof)));
    out({ subcommand: "doctor", ok, tooling, proof: proof ? { verified: true, reused_from: proof.reused_from } : { verified: false, detail: "static findings are not executed proof; run prove to establish controls" } });
    return ok ? 0 : 1;
  }
  const checks = [];
  const add = (name, ok, required, detail) => checks.push({ name, ok, required, detail });
  for (const [tool, required] of [["git", true], ["node", true], ["bash", true], ["jq", true], ["gh", true], ["shellcheck", false]]) {
    const r = run(tool, ["--version"]);
    add(`tool:${tool}`, r.code === 0, required, r.code === 0 ? firstLine(r.stdout) : "not found on PATH");
  }
  const gh = run("gh", ["auth", "status"]);
  add("gh:auth", gh.code === 0, true, gh.code === 0 ? "authenticated" : "gh auth status failed");
  let repo = null;
  try {
    repo = toplevel(o.repo);
    add("repo:git", true, true, repo);
  } catch (e) {
    add("repo:git", false, true, e.message);
  }
  if (repo) {
    const tooling = inspectTooling({ repo, base: o.base, adoption: o.adoption, run, git });
    add("tooling:configuration", tooling.configured, tooling.required, tooling.findings);
    const gate = gatePath(repo, o.gate);
    add("gate:executable", isExecutable(gate), true, gate);
    const ign = run("git", ["-C", repo, "check-ignore", "-q", `${RECEIPT_DIR}/probe.json`]);
    add("receipts:gitignored", ign.code === 0, false, ign.code === 0 ? RECEIPT_DIR : `add ${RECEIPT_DIR}/ to .gitignore`);
  }
  for (const name of ["MC_URL", "MC_TOKEN", "GH_REVIEWER_TOKEN"]) {
    add(`env:${name}`, Boolean(process.env[name]), false, process.env[name] ? "set" : "unset");
  }
  const ok = checks.every((c) => c.ok || !c.required);
  out({ subcommand: "doctor", ok, checks });
  return ok ? 0 : 1;
}

// ---------------------------------------------------------------- check / prove
const REQUIRED_STEPS = ["clean-tree", "non-empty-diff", "gate", "truthful-status"];

function baselineSnapshot(repo, args = []) {
  let path = join(repo, ".gibson-baseline.json");
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--baseline" && args[i + 1]) path = resolve(repo, args[++i]);
  }
  const entries = [];
  for (let p = path; ; p = dirname(p)) {
    try {
      const st = lstatSync(p);
      if (p === path && !st.isFile()) throw new Error("baseline is not a regular file");
      entries.push([p, st.dev, st.ino, st.mode, realpathSync(p), p === path ? sha256(readFileSync(p)) : null]);
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
      entries.push([p, null]);
    }
    if (dirname(p) === p) break;
  }
  return sha256(JSON.stringify(entries));
}

function checkWithTooling(o) {
  const repo = toplevel(o.repo);
  const head = git(repo, ["rev-parse", "HEAD"]);
  const base = o.base || "origin/main";
  const steps = [];
  const step = (name, ok, detail, extra = {}) => steps.push({ name, ok, detail, ...extra });

  // Receipts and gate logs live in the worktree; they never count as dirt.
  const dirty = git(repo, ["status", "--porcelain", "--", ".", `:(exclude)${RECEIPT_DIR}`]);
  step("clean-tree", dirty === "", dirty === "" ? "worktree clean" : `uncommitted changes: ${dirty.split("\n").length} path(s)`);

  let [files, mergeBase] = [[], null];
  try {
    mergeBase = git(repo, ["merge-base", base, "HEAD"]);
    files = git(repo, ["diff", "--name-only", mergeBase, "HEAD"]).split("\n").filter(Boolean);
    step("non-empty-diff", files.length > 0, files.length > 0 ? `${files.length} file(s) changed vs ${base}` : `no changes vs ${base} (L-008: a no-op is not success)`);
  } catch (e) {
    step("non-empty-diff", false, `cannot diff against ${base}: ${e.message}`);
  }

  const dir = join(repo, RECEIPT_DIR);
  mkdirSync(dir, { recursive: true });
  // Version/control commands must not rewrite the baseline before gate.sh
  // establishes its own authority snapshot.
  const baseline = baselineSnapshot(repo, o.gateArgs || []);
  const plan = inspectTooling({ repo, base, adoption: o.adoption, run, git });
  let tooling = { schema: plan.schema, fingerprint: plan.fingerprint, verified: false, findings: plan.findings };
  if (steps.every((s) => s.ok) && plan.configured) {
    tooling = (!o.refreshTooling && cachedTooling(repo, plan, head, o.adoption)) || proveTooling(repo, plan, run);
    const afterControls = inspectTooling({ repo, base, adoption: o.adoption, run, git });
    if (!afterControls.configured || afterControls.fingerprint !== plan.fingerprint) tooling.verified = false;
    // The gate can consume these real control results without running them a
    // second time. This interim receipt expressly does not claim a green gate.
    writeFileSync(join(dir, `${head}.json`), `${JSON.stringify({ schema: SCHEMA, head, verified: false, tooling })}\n`);
  }
  const toolingBaselineStable = baselineSnapshot(repo, o.gateArgs || []) === baseline;
  if (!toolingBaselineStable) tooling.verified = false;
  step("tooling-baseline-stable", toolingBaselineStable, "baseline authority checked around tooling commands");
  step("tooling", !plan.required || tooling.verified, plan.required ? (tooling.verified ? "tooling controls verified; product gate still required" : "required tooling missing/unproven") : "audit only; tooling findings do not block legacy repositories", { required: plan.required, findings: plan.findings });
  if (steps.every((s) => s.ok)) {
    const gate = gatePath(repo, o.gate);
    const log = join(dir, `${head}.gate.log`);
    const gateArgs = [...(o.gateArgs || [])];
    if (gate === join(GIBSON, "scripts", "gate.sh")) gateArgs.push("--tooling-base", base);
    const g = isExecutable(gate) ? run(gate, gateArgs, { cwd: repo }) : { code: 127, stdout: "", stderr: `gate not executable: ${gate}\n`, ms: 0 };
    const text = g.stdout + g.stderr;
    writeFileSync(log, text);
    step("gate", g.code === 0, `${gate} exit ${g.code}`, {
      exit: g.code, ms: g.ms, log: `${RECEIPT_DIR}/${head}.gate.log`, log_sha256: sha256(text),
      tail: text.trimEnd().split("\n").slice(-15),
    });
    const t = run(process.execPath, [join(GIBSON, "scripts", "truthful-status.mjs"), "--claimed", "success", "--log-file", log, "--gate-exit", String(g.code)]);
    step("truthful-status", t.code === 0, firstLine(t.stdout + t.stderr) || `exit ${t.code}`, { exit: t.code });
    if (plan.configured) {
      const afterGate = inspectTooling({ repo, base, adoption: o.adoption, run, git });
      if (!afterGate.configured || afterGate.fingerprint !== plan.fingerprint) {
        tooling.verified = false;
        step("tooling-inputs-stable", !plan.required, "tooling inputs changed during gate; proof invalidated");
      }
    }
  }
  const gateBaselineStable = baselineSnapshot(repo, o.gateArgs || []) === baseline;
  if (!gateBaselineStable) tooling.verified = false;
  step("gate-baseline-stable", gateBaselineStable, "baseline authority checked through final tooling observation");
  for (const name of REQUIRED_STEPS) {
    if (!steps.some((s) => s.name === name)) step(name, false, "skipped: an earlier step failed");
  }
  // Fail closed on a vacuous step list: every required step must be present AND ok.
  const verified = steps.every((s) => s.ok) && REQUIRED_STEPS.every((n) => steps.some((s) => s.name === n && s.ok === true));
  return {
    schema: SCHEMA, head, base, merge_base: mergeBase, files, steps, verified, tooling,
    generated_at: new Date().toISOString(), generator: "scripts/gibson-verify.mjs",
  };
}

function check(o) {
  const repo = toplevel(o.repo);
  const path = join(repo, RECEIPT_DIR, `${git(repo, ["rev-parse", "HEAD"])}.json`);
  const previous = existsSync(path) ? readFileSync(path) : null;
  try { return checkWithTooling(o); }
  finally {
    // check is nonpublishing. Temporary control evidence serves gate.sh only
    // during this call; it cannot replace an existing prove receipt.
    if (previous === null) rmSync(path, { force: true });
    else writeFileSync(path, previous);
  }
}

function prove(o) {
  const result = check(o);
  const bytes = `${JSON.stringify(result, null, 2)}\n`;
  writeFileSync(join(toplevel(o.repo), RECEIPT_DIR, `${result.head}.json`), bytes);
  out({ subcommand: "prove", verified: result.verified, head: result.head, receipt: `${RECEIPT_DIR}/${result.head}.json`, receipt_sha256: sha256(bytes), steps: result.steps.map(({ name, ok, detail }) => ({ name, ok, detail })) });
  return result.verified ? 0 : 1;
}

// ---------------------------------------------------------------- verdict lint
// Mirror of second-opinion.sh: trim_ws / strip_list_marker / exact_verdict_event
// / verdict_shaped_line / parse_isolated_verdict. [[:space:]] is the C-locale
// class, so trimming uses that set rather than String.prototype.trim.
const WS = " \\t\\n\\v\\f\\r";
const trimWs = (s) => s.replace(new RegExp(`^[${WS}]+`), "").replace(new RegExp(`[${WS}]+$`), "");
const LIST_MARKER = new RegExp(`^[0-9]+\\.[${WS}]+(.*)$`, "s");
const SHAPED = new RegExp(`^VERDICT:[${WS}]+[^${WS}]`);

function stripListMarker(s) {
  const m = LIST_MARKER.exec(s);
  return m ? trimWs(m[1]) : s;
}

function exactVerdictEvent(s) {
  if (s === "VERDICT: APPROVE" || s === "VERDICT: approve") return "approve";
  if (s === "VERDICT: REQUEST_CHANGES" || s === "VERDICT: changes-requested") return "request-changes";
  return "";
}

function parseIsolatedVerdict(text) {
  if (text === null) return "empty";
  let firstNonblank = "";
  let [shaped, permitted, sawApprove, sawRc] = [0, 0, false, false];
  for (let line of text.split("\n")) {
    line = trimWs(line.replace(/\r$/, ""));
    if (line === "") continue;
    if (firstNonblank === "") firstNonblank = line;
    const candidate = stripListMarker(line);
    const event = exactVerdictEvent(candidate);
    if (event) {
      permitted += 1;
      shaped += 1;
      if (event === "approve") sawApprove = true; else sawRc = true;
    } else if (SHAPED.test(candidate)) {
      shaped += 1;
    }
  }
  if (firstNonblank === "") return "empty";
  const firstEvent = exactVerdictEvent(stripListMarker(firstNonblank));
  if (!firstEvent) return permitted > 0 ? "invalid" : "no-verdict";
  if (shaped > 1) {
    if (sawApprove && sawRc) return "contradictory";
    return permitted > 1 ? "duplicate" : "invalid";
  }
  return firstEvent;
}

function verdictLint(file) {
  let text = null;
  try {
    // latin1 keeps bytes 1:1, as bash `read` sees them.
    if (statSync(file).isFile()) text = readFileSync(file, "latin1");
  } catch {
    text = null;
  }
  const state = parseIsolatedVerdict(text);
  const ok = state === "approve" || state === "request-changes";
  out({ subcommand: "verdict lint", file, state, ok });
  return ok ? 0 : 1;
}

// ---------------------------------------------------------------- report
async function report(o) {
  if (!o.agent) dieUsage(`${PREFIX}report requires --agent`);
  const repo = toplevel(o.repo);
  const head = git(repo, ["rev-parse", "HEAD"]);
  const path = o.receipt ? resolve(o.receipt) : join(repo, RECEIPT_DIR, `${head}.json`);
  let [status, reason, receiptSha, failed] = ["claim-only", "", null, []];
  if (!existsSync(path)) {
    reason = `no receipt for HEAD ${head.slice(0, 12)}`;
  } else {
    const bytes = readFileSync(path);
    receiptSha = sha256(bytes);
    let r = null;
    try {
      r = JSON.parse(bytes.toString("utf8"));
    } catch {
      reason = "receipt is not valid JSON";
    }
    if (r && r.schema !== SCHEMA) reason = `receipt schema is not ${SCHEMA}`;
    else if (r && r.head !== head) reason = `stale receipt: for ${String(r.head).slice(0, 12)}, HEAD is ${head.slice(0, 12)}`;
    else if (r && r.verified !== true) {
      failed = (r.steps || []).filter((s) => s.ok !== true).map((s) => s.name);
      reason = "receipt records failed checks";
    } else if (r) {
      status = "verified";
      reason = "receipt at HEAD, all required steps ok";
    }
  }
  const payload = {
    agent_id: o.agent,
    kind: "milestone",
    title: `verification: ${status}`,
    detail: { event: "verification", status, reason, head, receipt_sha256: receiptSha, failed_steps: failed, pr: o.pr, issue: o.issue },
  };
  if (o.platform) payload.platform = o.platform;
  if (o.dryRun) {
    out({ subcommand: "report", dry_run: true, status, payload });
    return status === "verified" ? 0 : 1;
  }
  const url = process.env.MC_URL;
  const token = process.env.MC_TOKEN;
  if (!url || !token) {
    console.error(`${PREFIX}report needs MC_URL and MC_TOKEN (or use --dry-run)`);
    return 1;
  }
  let [res, body] = [null, {}];
  try {
    res = await fetch(`${url.replace(/\/+$/, "")}/api/ingest`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(15000),
    });
    body = await res.json().catch(() => ({}));
  } catch (e) {
    console.error(`${PREFIX}report POST failed: ${e.message}`);
    return 1;
  }
  // Agent Kontrol answers {ok:true, demo:true} when it has no database: the
  // event was dropped. A dropped event is not a delivered report (L-008).
  const delivered = res.ok && body.ok === true && body.demo !== true;
  out({ subcommand: "report", dry_run: false, status, delivered, http_status: res.status, payload });
  if (!delivered) return 1;
  return status === "verified" ? 0 : 1;
}

// ---------------------------------------------------------------- main
const COMMON = { "--repo": { key: "repo" } };
const TOOLING_FLAGS = { "--base": { key: "base" }, "--adoption": { key: "adoption", type: "boolean" } };
const CHECK_FLAGS = { ...COMMON, ...TOOLING_FLAGS, "--refresh-tooling": { key: "refreshTooling", type: "boolean" }, "--gate": { key: "gate" }, "--gate-arg": { key: "gateArgs", multiple: true } };
const SPECS = {
  doctor: { ...COMMON, ...TOOLING_FLAGS, "--gate": { key: "gate" }, "--tooling-only": { key: "toolingOnly", type: "boolean" }, "--require-proof": { key: "requireProof", type: "boolean" } },
  check: CHECK_FLAGS,
  prove: CHECK_FLAGS,
  report: {
    ...COMMON, "--agent": { key: "agent" }, "--receipt": { key: "receipt" }, "--pr": { key: "pr" },
    "--issue": { key: "issue" }, "--platform": { key: "platform" }, "--dry-run": { key: "dryRun", type: "boolean" },
  },
};

async function main(argv) {
  const [sub, ...rest] = argv;
  if (!sub || argv.includes("-h") || argv.includes("--help")) {
    help();
    return sub ? 0 : 2;
  }
  if (sub === "verdict") {
    const o = parseFlags(rest, { flags: {}, allowPositionals: true, prefix: PREFIX });
    const [action, file, ...extra] = o._;
    if (action !== "lint" || !file || extra.length) dieUsage(`${PREFIX}usage: verdict lint FILE`);
    return verdictLint(file);
  }
  if (!SPECS[sub]) {
    if (sub.startsWith("-")) dieUsage(`unknown flag: ${sub}`);
    dieUsage(`${PREFIX}unknown subcommand: ${sub} (doctor|check|prove|verdict|report)`);
  }
  const o = parseFlags(rest, { flags: SPECS[sub], prefix: PREFIX });
  if (sub === "doctor") return doctor(o);
  if (sub === "check") {
    const result = check(o);
    out({ subcommand: "check", ...result });
    return result.verified ? 0 : 1;
  }
  if (sub === "prove") return prove(o);
  return report(o);
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (e) => {
    console.error(`${PREFIX}ERROR: ${e.message}`);
    process.exit(1);
  },
);
