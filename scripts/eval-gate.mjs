#!/usr/bin/env node
/**
 * eval-gate.mjs — pass/fail gate over a saved eval run (#583).
 *
 * WHAT IT DOES
 *   Reads .gibson-evals/runs/<variant>.json (written by eval-run.mjs) and exits
 *   nonzero when the pass rate is below --min-pass-rate. It fails closed: a
 *   missing, unparsable or empty result is NOT a pass, and neither is a run
 *   where a configured grader errored on any case.
 *
 * WHY
 *   Some happy paths must always work. This is the deployment gate that checks
 *   them, and a gate that passes on missing evidence is worse than no gate.
 *
 * RISKS
 *   It trusts the run file it is given. It does not re-run anything. Keep the
 *   job opt-in until the dataset has earned a threshold you believe.
 *
 * USAGE
 *   node scripts/eval-gate.mjs --variant NAME --min-pass-rate 0.8 [--out-dir DIR]
 *   node scripts/eval-gate.mjs --help
 *
 * EXIT
 *   0 at or above threshold   1 below threshold, or evidence missing/invalid   2 usage
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseFlags } from "./lib/args.mjs";
import { DEFAULT_OUT_DIR } from "./lib/eval-core.mjs";

if (process.argv.includes("--help") || process.argv.includes("-h")) {
  const src = readFileSync(new URL(import.meta.url), "utf8");
  const m = src.match(/\/\*\*([\s\S]*?)\*\//);
  console.log((m ? m[1] : "").replace(/^ \* ?/gm, "").trim());
  process.exit(0);
}

const toRate = (v) => {
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0 || n > 1) {
    console.error(`eval-gate: --min-pass-rate must be between 0 and 1, got ${JSON.stringify(v)}`);
    process.exit(2);
  }
  return n;
};

const args = parseFlags(process.argv.slice(2), {
  flags: {
    "--variant": { key: "variant" },
    "--min-pass-rate": { key: "min", transform: toRate },
    "--out-dir": { key: "outDir", default: DEFAULT_OUT_DIR },
  },
  prefix: "eval-gate: ",
});

if (!args.variant || args.min === null) {
  console.error("eval-gate: --variant NAME and --min-pass-rate N are required");
  process.exit(2);
}
if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(String(args.variant))) {
  console.error("eval-gate: --variant has characters outside [A-Za-z0-9._-]");
  process.exit(2);
}

const file = join(String(args.outDir), "runs", `${args.variant}.json`);
let run;
try {
  run = JSON.parse(readFileSync(file, "utf8"));
} catch (e) {
  console.error(`eval-gate: FAIL — no usable result at ${file} (${e instanceof Error ? e.message : e}). Missing evidence is not a pass.`);
  process.exit(1);
}

if (
  !run ||
  run.schema !== "gibson.eval-run.v1" ||
  !Number.isInteger(run.total) ||
  run.total < 1 ||
  !Number.isInteger(run.passed) ||
  run.passed < 0 ||
  run.passed > run.total
) {
  console.error(`eval-gate: FAIL — ${file} is not a valid, non-empty gibson.eval-run.v1 result`);
  process.exit(1);
}

// Recompute from the cases rather than trusting the stored rate.
const cases = Array.isArray(run.cases) ? run.cases : [];
const counted = cases.filter((c) => c && c.pass === true).length;
if (cases.length !== run.total || counted !== run.passed) {
  console.error(`eval-gate: FAIL — ${file} summary does not match its case list (tampered or truncated)`);
  process.exit(1);
}

if (run.grader_configured && run.grader_errors > 0) {
  console.error(`eval-gate: FAIL — grader errored on ${run.grader_errors} case(s); an unreadable grade is not a pass`);
  process.exit(1);
}

const rate = run.passed / run.total;
const line = `${run.variant}: ${run.passed}/${run.total} (${(rate * 100).toFixed(1)}%), threshold ${(args.min * 100).toFixed(1)}%`;
if (rate < args.min) {
  console.error(`eval-gate: FAIL — ${line}`);
  for (const c of cases.filter((x) => !x.pass).slice(0, 10)) console.error(`  - ${c.id}: ${c.reason}`);
  process.exit(1);
}
console.log(`eval-gate: PASS — ${line}`);
