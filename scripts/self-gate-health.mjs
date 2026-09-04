#!/usr/bin/env node
// self-gate-health.mjs — false-red and feedback-time budgets for the self-gate.
//
// WHAT IT DOES
//   Reads recent gibson-self-gate workflow runs and checks them against the
//   budgets in config/self-gate-health.v1.json: how often main goes red, how
//   often PR runs go red or get cancelled, and how long a green run takes.
//   Nonzero exit when any budget is exceeded. Report-only otherwise.
//
// WHY
//   The ratchet only ever added sensors; nothing measured whether the gate
//   itself was getting slower or noisier. Between Aug and Sep 2026 the gate
//   grew to 16 minutes serial and one non-hermetic suite produced half of all
//   red runs, and no sensor said so. A harness that cannot see its own false
//   reds cannot improve — it can only tighten.
//
// RISKS
//   Rates are over a bounded window and need minRuns samples before a budget
//   applies (insufficient data is reported, not failed). GITHUB_TOKEN needs
//   actions:read. No writes.
//
// USAGE
//   node scripts/self-gate-health.mjs                # live: GITHUB_TOKEN + GITHUB_REPOSITORY
//   node scripts/self-gate-health.mjs --runs FILE    # offline: JSON {workflow_runs:[...]} or [...]
//   node scripts/self-gate-health.mjs --config PATH
//   node scripts/self-gate-health.mjs --format json|text
//
// EXIT
//   0 every budget holds (or insufficient data)   1 a budget is exceeded
//   2 usage / IO / API

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_CONFIG_REL = "config/self-gate-health.v1.json";
const GREEN = new Set(["success"]);
const RED = new Set(["failure", "timed_out", "startup_failure"]);

function dieUsage(msg) {
  console.error(`self-gate-health: ${msg}`);
  process.exit(2);
}

function parseArgs(argv) {
  const out = { runsFile: null, configPath: null, format: "text" };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "-h" || a === "--help") {
      console.log(`self-gate-health.mjs — false-red and feedback-time budgets for the self-gate

USAGE
  node scripts/self-gate-health.mjs                # live: GITHUB_TOKEN + GITHUB_REPOSITORY
  node scripts/self-gate-health.mjs --runs FILE    # offline: JSON {workflow_runs:[...]} or [...]
  node scripts/self-gate-health.mjs --config PATH [--format json|text]

EXIT
  0 every budget holds (or insufficient data)   1 a budget is exceeded   2 usage / IO / API`);
      process.exit(0);
    } else if (a === "--runs") {
      out.runsFile = argv[++i] || dieUsage("--runs wants a file");
    } else if (a === "--config") {
      out.configPath = argv[++i] || dieUsage("--config wants a path");
    } else if (a === "--format") {
      const v = argv[++i];
      if (v !== "json" && v !== "text") dieUsage("--format wants json|text");
      out.format = v;
    } else {
      dieUsage(`unknown flag: ${a}`);
    }
  }
  return out;
}

export function loadConfig(path) {
  let cfg;
  try {
    cfg = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    throw new Error(`cannot read config ${path}: ${e.message}`);
  }
  const num = (v, name, { min = 0, max = Infinity, integer = false } = {}) => {
    if (typeof v !== "number" || !Number.isFinite(v) || v < min || v > max || (integer && !Number.isInteger(v))) {
      throw new Error(`config ${name} must be a number in [${min}, ${max}]${integer ? " (integer)" : ""}; got ${JSON.stringify(v)}`);
    }
    return v;
  };
  if (typeof cfg.workflowFile !== "string" || !cfg.workflowFile) throw new Error("config workflowFile must be a non-empty string");
  const b = cfg.budgets || {};
  return {
    workflowFile: cfg.workflowFile,
    windowRuns: num(cfg.windowRuns, "windowRuns", { min: 1, max: 1000, integer: true }),
    minRuns: num(cfg.minRuns, "minRuns", { min: 1, max: 1000, integer: true }),
    budgets: {
      mainRedRate: num(b.mainRedRate, "budgets.mainRedRate", { max: 1 }),
      prRedRate: num(b.prRedRate, "budgets.prRedRate", { max: 1 }),
      prCancelledRate: num(b.prCancelledRate, "budgets.prCancelledRate", { max: 1 }),
      medianGreenWallSeconds: num(b.medianGreenWallSeconds, "budgets.medianGreenWallSeconds", { min: 1, integer: true }),
    },
  };
}

function wallSeconds(run) {
  const a = Date.parse(run.run_started_at || run.created_at || "");
  const b = Date.parse(run.updated_at || "");
  if (!Number.isFinite(a) || !Number.isFinite(b) || b < a) return null;
  return Math.round((b - a) / 1000);
}

function median(nums) {
  if (nums.length === 0) return null;
  const s = [...nums].sort((x, y) => x - y);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : Math.round((s[mid - 1] + s[mid]) / 2);
}

function rate(n, d) {
  return d === 0 ? 0 : n / d;
}

function pct(x) {
  return `${(x * 100).toFixed(1)}%`;
}

// Pure: runs -> { metrics, findings, ok }. Runs must be completed workflow
// runs of the self-gate (any event), newest first is fine but not required.
export function evaluate(runsInput, cfg) {
  const runs = (Array.isArray(runsInput) ? runsInput : runsInput?.workflow_runs) || null;
  if (!Array.isArray(runs)) {
    const err = new Error("runs must be an array or {workflow_runs: [...]}");
    err.code = "E_MALFORMED";
    throw err;
  }
  const completed = runs
    .filter((r) => r && r.status === "completed" && typeof r.conclusion === "string")
    .slice(0, cfg.windowRuns);

  const main = completed.filter((r) => r.event === "push" && r.head_branch === "main");
  const pr = completed.filter((r) => r.event === "pull_request");

  const mainRed = main.filter((r) => RED.has(r.conclusion)).length;
  const prRed = pr.filter((r) => RED.has(r.conclusion)).length;
  const prCancelled = pr.filter((r) => r.conclusion === "cancelled").length;
  const greenWalls = completed.filter((r) => GREEN.has(r.conclusion)).map(wallSeconds).filter((s) => s != null);

  const metrics = {
    window: completed.length,
    main: { runs: main.length, red: mainRed, redRate: rate(mainRed, main.length) },
    pr: {
      runs: pr.length,
      red: prRed,
      redRate: rate(prRed, pr.length),
      cancelled: prCancelled,
      cancelledRate: rate(prCancelled, pr.length),
    },
    green: { runs: greenWalls.length, medianWallSeconds: median(greenWalls) },
  };

  const findings = [];
  const insufficient = [];
  const check = (name, samples, value, budget, fmt) => {
    if (samples < cfg.minRuns) {
      insufficient.push(`${name}: ${samples} sample(s) < minRuns ${cfg.minRuns}; budget not applied`);
      return;
    }
    if (value > budget) {
      findings.push({ code: `E_${name.toUpperCase()}`, message: `${name} ${fmt(value)} exceeds budget ${fmt(budget)} over ${samples} run(s)` });
    }
  };
  check("mainRedRate", main.length, metrics.main.redRate, cfg.budgets.mainRedRate, pct);
  check("prRedRate", pr.length, metrics.pr.redRate, cfg.budgets.prRedRate, pct);
  check("prCancelledRate", pr.length, metrics.pr.cancelledRate, cfg.budgets.prCancelledRate, pct);
  if (metrics.green.medianWallSeconds != null) {
    check("medianGreenWallSeconds", greenWalls.length, metrics.green.medianWallSeconds, cfg.budgets.medianGreenWallSeconds, (s) => `${s}s`);
  } else {
    insufficient.push("medianGreenWallSeconds: no green runs with timestamps; budget not applied");
  }

  return { ok: findings.length === 0, metrics, findings, insufficient, budgets: cfg.budgets };
}

export function renderText(result) {
  const m = result.metrics;
  const lines = [
    `self-gate-health: window ${m.window} completed run(s)`,
    `  main: ${m.main.red}/${m.main.runs} red (${pct(m.main.redRate)}; budget ${pct(result.budgets.mainRedRate)})`,
    `  pr:   ${m.pr.red}/${m.pr.runs} red (${pct(m.pr.redRate)}; budget ${pct(result.budgets.prRedRate)}), ` +
      `${m.pr.cancelled}/${m.pr.runs} cancelled (${pct(m.pr.cancelledRate)}; budget ${pct(result.budgets.prCancelledRate)})`,
    `  green median wall: ${m.green.medianWallSeconds == null ? "n/a" : `${m.green.medianWallSeconds}s`} over ${m.green.runs} run(s) (budget ${result.budgets.medianGreenWallSeconds}s)`,
  ];
  for (const s of result.insufficient) lines.push(`  note: ${s}`);
  for (const f of result.findings) lines.push(`  ${f.code}: ${f.message}`);
  lines.push(
    result.ok
      ? "self-gate-health: OK — false-red and feedback-time budgets hold"
      : "self-gate-health: RED — a budget is exceeded. Fix the noisy or slow sensor; raising a budget is a ratchet loosening and needs owner sign-off."
  );
  return lines.join("\n");
}

async function fetchRuns({ token, repository, workflowFile, windowRuns }) {
  const perPage = Math.min(100, windowRuns);
  const items = [];
  let page = 1;
  const completedCount = () => items.filter((r) => r && r.status === "completed").length;
  while (completedCount() < windowRuns && page <= 10) {
    const url = `https://api.github.com/repos/${repository}/actions/workflows/${encodeURIComponent(workflowFile)}/runs?per_page=${perPage}&page=${page}`;
    const res = await fetch(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    });
    if (!res.ok) {
      const err = new Error(`GET ${url} -> ${res.status}`);
      err.code = "E_API";
      throw err;
    }
    const data = await res.json();
    const batch = Array.isArray(data?.workflow_runs) ? data.workflow_runs : null;
    if (batch == null) {
      const err = new Error("workflow runs page malformed");
      err.code = "E_MALFORMED";
      throw err;
    }
    items.push(...batch);
    if (batch.length < perPage) break;
    page += 1;
  }
  return items;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  let cfg;
  try {
    cfg = loadConfig(args.configPath || resolve(repoRoot, DEFAULT_CONFIG_REL));
  } catch (e) {
    dieUsage(e.message);
  }
  let runs;
  try {
    if (args.runsFile) {
      runs = JSON.parse(readFileSync(args.runsFile, "utf8"));
    } else {
      const token = process.env.GITHUB_TOKEN;
      const repository = process.env.GITHUB_REPOSITORY;
      if (!token || !repository) dieUsage("GITHUB_TOKEN and GITHUB_REPOSITORY are required (or pass --runs FILE)");
      runs = await fetchRuns({ token, repository, workflowFile: cfg.workflowFile, windowRuns: cfg.windowRuns });
    }
  } catch (e) {
    dieUsage(e.message);
  }
  let result;
  try {
    result = evaluate(runs, cfg);
  } catch (e) {
    dieUsage(e.message);
  }
  if (args.format === "json") {
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.log(renderText(result));
  }
  process.exit(result.ok ? 0 : 1);
}

function isMainModule() {
  try {
    return resolve(process.argv[1] || "") === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
}

if (isMainModule()) {
  main().catch((e) => dieUsage(e.message));
}
