#!/usr/bin/env node
/**
 * truthful-status.mjs — Law 8: report failures truthfully (#97)
 *
 * WHAT IT DOES
 *   Compares a claimed status (success/green/pass/READY) against gate or suite
 *   output. Refuses when the claim is success but the log shows failures,
 *   "NOT RUN", red checks, or non-zero summary tallies.
 *
 * WHY
 *   silent-noop catches do-nothing; this catches "said green over a red gate"
 *   (the goose-recipes NOT-RUN-exits-0 class of lie).
 *
 * RISKS
 *   - Log-text heuristics; prefer structured --gate-exit when available.
 *   - Read-only.
 *
 * USAGE
 *   node scripts/truthful-status.mjs --claimed success --log-file gate.log
 *   node scripts/truthful-status.mjs --claimed success --gate-exit 1
 *   node scripts/truthful-status.mjs --help
 */

import { readFileSync, existsSync } from "node:fs";
import { parseFlags } from "./lib/args.mjs";

function help() {
  console.log(`truthful-status.mjs — Law 8 truthful-report sensor (#97)

WHAT IT DOES
  Refuses a success claim when the gate/suite log shows failure or NOT RUN.

WHY
  A green report over a red gate is worse than a red report (Law 8).

RISKS
  Log heuristics. Prefer --gate-exit for hard evidence. Read-only.

USAGE
  node scripts/truthful-status.mjs --claimed success --log-file out.txt
  node scripts/truthful-status.mjs --claimed success --gate-exit 1
  node scripts/truthful-status.mjs --help
`);
}

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help") || args.length === 0) {
  help();
  process.exit(args.includes("-h") || args.includes("--help") ? 0 : 2);
}

const parsed = parseFlags(args, {
  flags: {
    "--claimed": {
      key: "claimed",
      default: null,
      transform: (s) => (s || "").toLowerCase(),
    },
    "--log-file": { key: "logFile", default: null },
    "--gate-exit": { key: "gateExit", default: null },
  },
});
let claimed = parsed.claimed;
let logFile = parsed.logFile;
let gateExit = parsed.gateExit;

if (!claimed) {
  console.error("truthful-status: --claimed is required");
  process.exit(2);
}

const successWords = new Set([
  "success",
  "successful",
  "green",
  "pass",
  "passed",
  "ok",
  "ready",
  "ship",
  "shipped",
  "done",
]);
const isSuccessClaim = successWords.has(claimed);

function fail(msg) {
  console.log(`truthful-status: FAIL — ${msg}`);
  process.exit(1);
}
function ok(msg) {
  console.log(`truthful-status: OK — ${msg}`);
  process.exit(0);
}

if (!isSuccessClaim) {
  ok(`claimed '${claimed}' is not a success claim — nothing to contradict`);
}

if (gateExit != null && gateExit !== "") {
  const ec = Number(gateExit);
  if (!Number.isFinite(ec)) {
    console.error("truthful-status: --gate-exit must be a number");
    process.exit(2);
  }
  if (ec !== 0) fail(`claimed success but --gate-exit=${ec}`);
}

let log = "";
if (logFile) {
  if (!existsSync(logFile)) fail(`log missing: ${logFile}`);
  log = readFileSync(logFile, "utf8");
}

if (log) {
  // NOT RUN while exiting success is the goose-recipes class bug
  if (/status:\s*NOT RUN/i.test(log) || /\bNOT RUN\b/.test(log)) {
    if (/exit(?:ed| code)?\s*[:=]?\s*0\b/i.test(log) || /0 failed/i.test(log)) {
      fail("log reports NOT RUN under a success-shaped tally (Law 8)");
    }
    fail("log reports NOT RUN — cannot claim success");
  }
  // N failed with N>0
  const failTally = log.match(/(\d+)\s+failed/gi) || [];
  for (const f of failTally) {
    const n = Number((f.match(/(\d+)/) || [])[1]);
    if (n > 0) fail(`log reports ${n} failed but claim is success`);
  }
  if (/\bFAIL\b/.test(log) && /run-all:\s*RED/i.test(log)) {
    fail("log reports run-all RED under success claim");
  }
  if (/gate:\s*RED/i.test(log) || /\bRED\b.*gate/i.test(log)) {
    fail("log reports gate RED under success claim");
  }
  if (/Process completed with exit code [1-9]/i.test(log)) {
    fail("log reports non-zero process exit under success claim");
  }
}

if (gateExit == null && !logFile) {
  console.error("truthful-status: provide --gate-exit and/or --log-file");
  process.exit(2);
}

ok("success claim consistent with gate/log evidence");
