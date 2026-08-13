#!/usr/bin/env node
/**
 * contract-read-check.mjs — Law 1: read contracts first (#97)
 *
 * WHAT IT DOES
 *   Refuses when a ship/PR body (or session receipt) does not evidence that
 *   AGENTS.md and memory/LESSONS.md (or LESSONS.md) were read before work.
 *   Accepts either:
 *     - a gibson/contract-read.receipt file (key=value), or
 *     - a PR/session body section listing both contracts as read.
 *
 * WHY
 *   Law 1 is load-bearing for unattended runs and had no deterministic check.
 *
 * RISKS
 *   - Attestation-based (cannot prove the model actually read the bytes).
 *     Still raises the cost of skipping the doctrine load step.
 *   - Read-only.
 *
 * USAGE
 *   node scripts/contract-read-check.mjs --receipt gibson/contract-read.receipt
 *   node scripts/contract-read-check.mjs --body-file pr.md
 *   node scripts/contract-read-check.mjs --help
 */

import { readFileSync, existsSync } from "node:fs";
import { parseFlags } from "./lib/args.mjs";

function help() {
  console.log(`contract-read-check.mjs — Law 1 contract-read sensor (#97)

WHAT IT DOES
  Requires evidence that AGENTS.md and LESSONS.md were read before the ship.

WHY
  A PR authored without loading the doctrine is how laws get "discovered" mid-run.

RISKS
  Attestation only — not a proof of comprehension. Read-only.

USAGE
  node scripts/contract-read-check.mjs --receipt path/to/contract-read.receipt
  node scripts/contract-read-check.mjs --body-file pr-or-journal.md
  node scripts/contract-read-check.mjs --help

Receipt format (key=value, one per line):
  agents=AGENTS.md
  lessons=memory/LESSONS.md
  read_at=2026-08-06T00:00:00Z
  session=runner@host
`);
}

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help") || args.length === 0) {
  help();
  process.exit(args.includes("-h") || args.includes("--help") ? 0 : 2);
}

const parsed = parseFlags(args, {
  flags: {
    "--receipt": { key: "receiptPath", default: null },
    "--body-file": { key: "bodyPath", default: null },
  },
});
const receiptPath = parsed.receiptPath;
const bodyPath = parsed.bodyPath;

function fail(msg) {
  console.log(`contract-read-check: FAIL — ${msg}`);
  process.exit(1);
}

function ok(msg) {
  console.log(`contract-read-check: OK — ${msg}`);
  process.exit(0);
}

if (receiptPath) {
  if (!existsSync(receiptPath)) fail(`receipt missing: ${receiptPath}`);
  const text = readFileSync(receiptPath, "utf8");
  const map = {};
  for (const line of text.split("\n")) {
    const m = line.match(/^([A-Za-z0-9_]+)=(.*)$/);
    if (m) map[m[1].toLowerCase()] = m[2].trim();
  }
  const agents = map.agents || map.agents_md || "";
  const lessons = map.lessons || map.lessons_md || "";
  if (!/AGENTS\.md/i.test(agents)) fail("receipt missing agents=AGENTS.md");
  if (!/LESSONS\.md/i.test(lessons)) fail("receipt missing lessons=...LESSONS.md");
  if (!map.read_at && !map.read) fail("receipt missing read_at= ISO timestamp");
  ok(`receipt ${receiptPath} names AGENTS.md + LESSONS.md`);
}

if (bodyPath) {
  if (!existsSync(bodyPath)) fail(`body missing: ${bodyPath}`);
  const body = readFileSync(bodyPath, "utf8");
  const hasAgents =
    /(?:read|loaded|reviewed)\s*:?\s*[^\n]*AGENTS\.md/i.test(body) ||
    /AGENTS\.md[^\n]{0,40}(?:read|loaded)/i.test(body) ||
    /##\s*contracts?\s*read[\s\S]{0,200}AGENTS\.md/i.test(body);
  const hasLessons =
    /(?:read|loaded|reviewed)\s*:?\s*[^\n]*LESSONS\.md/i.test(body) ||
    /LESSONS\.md[^\n]{0,40}(?:read|loaded)/i.test(body) ||
    /##\s*contracts?\s*read[\s\S]{0,400}LESSONS\.md/i.test(body);
  if (!hasAgents || !hasLessons) {
    fail(
      "body does not evidence reading AGENTS.md and LESSONS.md (Law 1). " +
        "Add a ## Contracts read section or a gibson/contract-read.receipt"
    );
  }
  ok(`body ${bodyPath} evidences AGENTS.md + LESSONS.md read`);
}

fail("provide --receipt and/or --body-file");
