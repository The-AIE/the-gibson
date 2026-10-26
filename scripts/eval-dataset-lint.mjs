#!/usr/bin/env node
/**
 * eval-dataset-lint.mjs — validate an eval dataset before anything runs on it (#583).
 *
 * WHAT IT DOES
 *   Checks a JSONL dataset (default evals/dataset.v1.jsonl). Every line must be
 *   a JSON object with: a unique string `id`; a non-empty `input` (string or
 *   object); an `expect` object with a known `type` and the fields that type
 *   needs; and a `tier` of A, B or C. The case count must sit inside
 *   [--min, --max] (default 15..30).
 *
 * WHY
 *   A case without a machine-checkable expectation is an opinion, and the gate
 *   would pass or fail it by accident. Linting first keeps the dataset honest.
 *
 * RISKS
 *   Read-only. It checks shape, not whether a case is a good test.
 *
 * USAGE
 *   node scripts/eval-dataset-lint.mjs [--file PATH] [--min N] [--max N]
 *   node scripts/eval-dataset-lint.mjs --help
 *
 * EXPECT TYPES
 *   contains / not_contains   { "type": "contains", "value": "text" }
 *   regex                     { "type": "regex", "value": "pattern", "flags": "i" }  (flags optional: i, m, s)
 *   exit_code                 { "type": "exit_code", "value": 0 }
 *
 * EXIT
 *   0 clean   1 findings (printed as file:line: message)   2 usage
 */
import { readFileSync } from "node:fs";
import { parseFlags } from "./lib/args.mjs";
import { EXPECT_TYPES, validateExpect } from "./lib/eval-expect.mjs";

if (process.argv.includes("--help") || process.argv.includes("-h")) {
  const src = readFileSync(new URL(import.meta.url), "utf8");
  const m = src.match(/\/\*\*([\s\S]*?)\*\//);
  console.log((m ? m[1] : "").replace(/^ \* ?/gm, "").trim());
  process.exit(0);
}

const toInt = (v) => {
  const n = Number(v);
  if (!Number.isInteger(n) || n < 0) {
    console.error(`eval-dataset-lint: expected a non-negative integer, got ${JSON.stringify(v)}`);
    process.exit(2);
  }
  return n;
};

const args = parseFlags(process.argv.slice(2), {
  flags: {
    "--file": { key: "file", default: "evals/dataset.v1.jsonl" },
    "--min": { key: "min", default: 15, transform: toInt },
    "--max": { key: "max", default: 30, transform: toInt },
  },
});

const file = String(args.file);
let text;
try {
  text = readFileSync(file, "utf8");
} catch (e) {
  console.error(`${file}: cannot read dataset: ${e instanceof Error ? e.message : e}`);
  process.exit(1);
}

/** @type {string[]} */
const findings = [];
const seen = new Set();
let count = 0;

text.split("\n").forEach((line, i) => {
  if (!line.trim()) return;
  const at = `${file}:${i + 1}`;
  let c;
  try {
    c = JSON.parse(line);
  } catch {
    findings.push(`${at}: not valid JSON`);
    return;
  }
  count += 1;
  if (!c || typeof c !== "object" || Array.isArray(c)) {
    findings.push(`${at}: case must be a JSON object`);
    return;
  }
  if (typeof c.id !== "string" || !c.id.trim()) findings.push(`${at}: missing string id`);
  else if (seen.has(c.id)) findings.push(`${at}: duplicate id ${JSON.stringify(c.id)}`);
  else seen.add(c.id);

  const emptyInput =
    c.input === undefined ||
    c.input === null ||
    (typeof c.input === "string" && !c.input.trim()) ||
    (typeof c.input === "object" && Object.keys(c.input).length === 0);
  if (emptyInput) findings.push(`${at}: missing or empty input`);

  if (!["A", "B", "C"].includes(c.tier)) findings.push(`${at}: tier must be A, B or C`);

  const bad = validateExpect(c.expect);
  if (bad) findings.push(`${at}: expect ${bad} (types: ${EXPECT_TYPES.join(", ")})`);
});

if (count < args.min) findings.push(`${file}: ${count} case(s), need at least ${args.min}`);
if (count > args.max) findings.push(`${file}: ${count} case(s), at most ${args.max} for a first dataset`);

if (findings.length) {
  for (const f of findings) console.error(f);
  console.error(`eval-dataset-lint: FAILED (${findings.length} finding(s))`);
  process.exit(1);
}
console.log(`eval-dataset-lint: ok (${count} cases in ${file})`);
