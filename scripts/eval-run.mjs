#!/usr/bin/env node
/**
 * eval-run.mjs — run a dataset against a runner variant and score it (#583).
 *
 * WHAT IT DOES
 *   For each case in the dataset it runs your --runner command with the case as
 *   JSON on stdin, scores stdout/exit code against the case's `expect`, and
 *   writes .gibson-evals/runs/<variant>.json with pass rate, wall time and cost.
 *   An optional --grader command (the Deming quality-agent seam) also sees each
 *   result and must return a verdict. Traces and scores go to the local sink and,
 *   when LANGFUSE_* keys are set, to Langfuse. `--compare A B` diffs two saved runs.
 *
 * RUNNER CONTRACT
 *   stdin:  {"id": "...", "input": ..., "tier": "A"}
 *   stdout: the output to score
 *   stderr: optionally one line  GIBSON_EVAL_COST {"usd": 0.01, "tokens": 1234}
 *           Cost not reported = cost unknown (null). It is never invented.
 *
 * GRADER CONTRACT
 *   stdin:  {"case": {...}, "output": "...", "exit_code": 0}
 *   stdout: {"verdict": "pass" | "fail", "reason": "..."}
 *   A grader that crashes, times out, prints non-JSON or an unknown verdict
 *   FAILS the case (grader_error). It never passes by default (Law 5).
 *
 * WHY
 *   Compare builder/reviewer combos on pass rate and cost instead of vibes,
 *   and give the CI gate something real to check.
 *
 * RISKS
 *   --runner and --grader are executed with `sh -c`: they are operator-supplied
 *   commands, run with your privileges. Do not pass untrusted strings. Dataset
 *   cases are data, never commands. Output is redacted before it is stored.
 *
 * USAGE
 *   node scripts/eval-run.mjs --variant NAME --runner CMD [--dataset PATH]
 *        [--grader CMD] [--timeout-ms N] [--out-dir DIR]
 *   node scripts/eval-run.mjs --compare A B [--out-dir DIR]
 *   node scripts/eval-run.mjs --help
 *
 * EXIT
 *   0 run completed (pass rate is the gate's job, see eval-gate.mjs)
 *   1 dataset unreadable / invalid, or a compare input is missing   2 usage
 */
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseFlags } from "./lib/args.mjs";
import { DEFAULT_OUT_DIR, describeEmit, emit, envelope, redact } from "./lib/eval-core.mjs";
import { checkExpect, validateExpect } from "./lib/eval-expect.mjs";

if (process.argv.includes("--help") || process.argv.includes("-h")) {
  const src = readFileSync(new URL(import.meta.url), "utf8");
  const m = src.match(/\/\*\*([\s\S]*?)\*\//);
  console.log((m ? m[1] : "").replace(/^ \* ?/gm, "").trim());
  process.exit(0);
}

const toMs = (v) => {
  const n = Number(v);
  if (!Number.isInteger(n) || n < 1) {
    console.error(`eval-run: --timeout-ms must be a positive integer, got ${JSON.stringify(v)}`);
    process.exit(2);
  }
  return n;
};

const args = parseFlags(process.argv.slice(2), {
  flags: {
    "--variant": { key: "variant" },
    "--runner": { key: "runner" },
    "--dataset": { key: "dataset", default: "evals/dataset.v1.jsonl" },
    "--grader": { key: "grader" },
    "--timeout-ms": { key: "timeoutMs", default: 60000, transform: toMs },
    "--out-dir": { key: "outDir", default: DEFAULT_OUT_DIR },
    "--compare": { key: "compare", multiple: true },
  },
  allowPositionals: true,
  prefix: "eval-run: ",
});

const outDir = String(args.outDir);
const SAFE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

/** @param {string} name */
function runFile(name) {
  if (!SAFE_NAME.test(name)) {
    console.error(`eval-run: variant name ${JSON.stringify(name)} must match ${SAFE_NAME}`);
    process.exit(2);
  }
  return join(outDir, "runs", `${name}.json`);
}

// ---------------------------------------------------------------- compare ---
if (args.compare.length > 0) {
  const names = [...args.compare, ...args._];
  if (names.length !== 2 || args.variant || args.runner) {
    console.error("eval-run: --compare takes exactly two variant names: --compare A B");
    process.exit(2);
  }
  const [a, b] = names.map((n) => {
    try {
      return JSON.parse(readFileSync(runFile(n), "utf8"));
    } catch (e) {
      console.error(`eval-run: cannot read run for variant ${n}: ${e instanceof Error ? e.message : e}`);
      process.exit(1);
    }
  });
  const pct = (r) => `${(r.pass_rate * 100).toFixed(1)}%`;
  const cost = (r) => (r.cost_usd_total === null ? "unknown" : `$${r.cost_usd_total.toFixed(4)}`);
  console.log(`variant        pass-rate   passed/total   wall-ms   cost`);
  for (const r of [a, b]) {
    console.log(
      `${String(r.variant).padEnd(14)} ${pct(r).padEnd(11)} ${`${r.passed}/${r.total}`.padEnd(14)} ${String(r.wall_ms_total).padEnd(9)} ${cost(r)}`,
    );
  }
  const d = (b.pass_rate - a.pass_rate) * 100;
  console.log(`delta (${b.variant} - ${a.variant}): ${d >= 0 ? "+" : ""}${d.toFixed(1)} pts pass rate`);
  if (a.cost_usd_total === null || b.cost_usd_total === null) {
    console.log("cost delta: not computable (at least one variant did not report cost)");
  } else {
    console.log(`cost delta: ${(b.cost_usd_total - a.cost_usd_total >= 0 ? "+" : "")}$${(b.cost_usd_total - a.cost_usd_total).toFixed(4)}`);
  }
  process.exit(0);
}

// -------------------------------------------------------------------- run ---
if (!args.variant || !args.runner) {
  console.error("eval-run: --variant NAME and --runner CMD are required (or use --compare A B)");
  process.exit(2);
}
if (args._.length > 0) {
  console.error(`eval-run: unexpected argument: ${args._[0]}`);
  process.exit(2);
}
const variantFile = runFile(String(args.variant));

/** @type {Array<{id:string,input:unknown,expect:unknown,tier:string}>} */
let cases;
try {
  cases = readFileSync(String(args.dataset), "utf8")
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l));
} catch (e) {
  console.error(`eval-run: cannot read dataset ${args.dataset}: ${e instanceof Error ? e.message : e}`);
  process.exit(1);
}
if (cases.length === 0) {
  console.error(`eval-run: dataset ${args.dataset} has no cases`);
  process.exit(1);
}
const dupes = new Set();
for (const c of cases) {
  if (!c || typeof c.id !== "string" || !c.id) {
    console.error("eval-run: every case needs a string id (run eval-dataset-lint.mjs)");
    process.exit(1);
  }
  if (dupes.has(c.id)) {
    console.error(`eval-run: duplicate case id ${JSON.stringify(c.id)}`);
    process.exit(1);
  }
  dupes.add(c.id);
}

/**
 * Run `sh -c cmd` with JSON on stdin, bounded by a timeout.
 * @param {string} cmd
 * @param {unknown} payload
 * @param {number} timeoutMs
 * @param {Record<string, string>} extraEnv
 * @returns {Promise<{stdout:string, stderr:string, exitCode:number|null, timedOut:boolean, error:string|null}>}
 */
function sh(cmd, payload, timeoutMs, extraEnv) {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const MAX = 1_000_000; // cap captured output so a runaway runner cannot eat memory
    // The runner is the agent under test: it never needs the Langfuse keys, so it never gets them.
    const baseEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("LANGFUSE_")));
    const child = spawn("sh", ["-c", cmd], {
      env: { ...baseEnv, ...extraEnv },
      stdio: ["pipe", "pipe", "pipe"],
      detached: true,
    });
    const timer = setTimeout(() => {
      timedOut = true;
      try {
        process.kill(-child.pid, "SIGKILL"); // whole process group
      } catch {
        child.kill("SIGKILL");
      }
    }, timeoutMs);
    child.stdout.on("data", (d) => {
      if (stdout.length < MAX) stdout += d;
    });
    child.stderr.on("data", (d) => {
      if (stderr.length < MAX) stderr += d;
    });
    child.stdin.on("error", () => {}); // runner may exit without reading stdin
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ stdout, stderr, exitCode: null, timedOut, error: e.message });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ stdout, stderr, exitCode: code, timedOut, error: null });
    });
    child.stdin.end(JSON.stringify(payload));
  });
}

/** @param {string} stderr */
function parseCost(stderr) {
  const m = stderr.match(/^GIBSON_EVAL_COST\s+(\{.*\})\s*$/m);
  if (!m) return { usd: null, tokens: null };
  try {
    const o = JSON.parse(m[1]);
    return {
      usd: typeof o.usd === "number" && o.usd >= 0 ? o.usd : null,
      tokens: Number.isInteger(o.tokens) && o.tokens >= 0 ? o.tokens : null,
    };
  } catch {
    return { usd: null, tokens: null };
  }
}

const results = [];
const events = [];
const startedAt = new Date().toISOString();
const traceBase = `gibson-eval-${args.variant}-${Date.now()}`;

for (const c of cases) {
  const t0 = Date.now();
  const run = await sh(
    String(args.runner),
    { id: c.id, input: c.input, tier: c.tier },
    args.timeoutMs,
    { GIBSON_EVAL_CASE_ID: c.id, GIBSON_EVAL_VARIANT: String(args.variant) },
  );
  const wallMs = Date.now() - t0;
  const output = redact(run.stdout);
  const cost = parseCost(run.stderr);

  let score;
  if (run.error) score = { pass: false, reason: `runner failed to start: ${run.error}` };
  else if (run.timedOut) score = { pass: false, reason: `runner timed out after ${args.timeoutMs}ms` };
  else score = checkExpect(c.expect, { stdout: run.stdout, exitCode: run.exitCode });

  let grader = null;
  if (args.grader) {
    const g = await sh(
      String(args.grader),
      { case: { id: c.id, input: c.input, expect: c.expect, tier: c.tier }, output, exit_code: run.exitCode },
      args.timeoutMs,
      { GIBSON_EVAL_CASE_ID: c.id, GIBSON_EVAL_VARIANT: String(args.variant) },
    );
    let verdict = null;
    let reason = "";
    if (g.error) reason = `grader failed to start: ${g.error}`;
    else if (g.timedOut) reason = `grader timed out after ${args.timeoutMs}ms`;
    else if (g.exitCode !== 0) reason = `grader exited ${g.exitCode}`;
    else {
      try {
        const parsed = JSON.parse(g.stdout);
        if (parsed && (parsed.verdict === "pass" || parsed.verdict === "fail")) {
          verdict = parsed.verdict;
          reason = typeof parsed.reason === "string" ? parsed.reason : "";
        } else reason = "grader verdict must be pass or fail";
      } catch {
        reason = "grader output was not JSON";
      }
    }
    grader = verdict
      ? { verdict, reason: redact(reason) }
      : { verdict: "grader_error", reason: redact(reason) };
  }

  const graderOk = !args.grader || grader?.verdict === "pass";
  const pass = score.pass && graderOk;
  const failWhy = !score.pass
    ? score.reason
    : grader?.verdict === "grader_error"
      ? `grader_error: ${grader.reason}`
      : grader?.verdict === "fail"
        ? `grader said fail: ${grader.reason}`
        : "";

  const result = {
    id: c.id,
    tier: c.tier ?? null,
    pass,
    reason: pass ? score.reason : failWhy,
    exit_code: run.exitCode,
    wall_ms: wallMs,
    cost_usd: cost.usd,
    tokens: cost.tokens,
    grader: grader ? grader.verdict : null,
  };
  results.push(result);

  const traceId = `${traceBase}-${c.id}`;
  events.push(
    envelope("trace-create", {
      id: traceId,
      name: "gibson.eval.case",
      tags: ["gibson", "eval", `variant:${args.variant}`, `tier:${c.tier ?? "?"}`],
      input: redact(typeof c.input === "string" ? c.input : JSON.stringify(c.input)),
      output: output.slice(0, 4000),
      metadata: { case_id: c.id, variant: args.variant, wall_ms: wallMs, cost_usd: cost.usd },
    }),
    envelope("score-create", {
      traceId,
      name: "pass",
      value: pass ? 1 : 0,
      dataType: "NUMERIC",
      comment: redact(result.reason),
    }),
  );
  if (grader) {
    events.push(
      envelope("score-create", {
        traceId,
        name: "grader",
        value: grader.verdict === "pass" ? 1 : 0,
        dataType: "NUMERIC",
        comment: redact(`${grader.verdict}: ${grader.reason}`),
      }),
    );
  }
  console.log(`  ${pass ? "pass" : "FAIL"}  ${c.id}${pass ? "" : `  — ${result.reason}`}`);
}

const passed = results.filter((r) => r.pass).length;
const costKnown = results.every((r) => r.cost_usd !== null);
const summary = {
  schema: "gibson.eval-run.v1",
  variant: String(args.variant),
  dataset: String(args.dataset),
  started_at: startedAt,
  total: results.length,
  passed,
  pass_rate: passed / results.length,
  wall_ms_total: results.reduce((s, r) => s + r.wall_ms, 0),
  // null unless EVERY case reported cost: a partial sum would read as a real total.
  cost_usd_total: costKnown ? results.reduce((s, r) => s + (r.cost_usd ?? 0), 0) : null,
  grader_configured: Boolean(args.grader),
  grader_errors: results.filter((r) => r.grader === "grader_error").length,
  cases: results,
};

mkdirSync(join(outDir, "runs"), { recursive: true });
writeFileSync(variantFile, `${JSON.stringify(summary, null, 2)}\n`, "utf8");

const shipped = await emit(events, { localFile: join(outDir, "traces.jsonl") });
console.log(
  `eval-run: ${args.variant}: ${passed}/${results.length} passed (${(summary.pass_rate * 100).toFixed(1)}%), ` +
    `cost ${summary.cost_usd_total === null ? "unknown" : `$${summary.cost_usd_total.toFixed(4)}`}, ` +
    `wall ${summary.wall_ms_total}ms`,
);
console.log(`eval-run: saved ${variantFile}`);
console.log(describeEmit(shipped));
process.exit(0);
