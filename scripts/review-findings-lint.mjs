#!/usr/bin/env node
/**
 * review-findings-lint.mjs — lint the Findings section of a review body (#401)
 *
 * WHAT IT DOES
 *   Parses a review body and reports: a blocking finding without a `trigger:`
 *   line, a finding without `class:`, an unknown class, an unknown kind, and a
 *   missing or non-final VERDICT line. Vocabularies come from
 *   config/review-finding-classes.v1.json.
 *
 * WHY
 *   A finding with no reachable trigger is speculation, and a finding with no
 *   class cannot be counted per class. Both are checkable by machine.
 *
 * RISKS
 *   - Report-only. Not wired into any merge gate by #401.
 *   - Heuristic markdown parse: findings are top-level `- ` bullets under the
 *     `### Findings` heading; `kind:`/`class:`/`trigger:` are continuation lines.
 *
 * USAGE
 *   node scripts/review-findings-lint.mjs --file review.md
 *   gh pr view N --json body -q .body | node scripts/review-findings-lint.mjs
 *   node scripts/review-findings-lint.mjs --help
 *
 * EXIT CODES
 *   0 clean   1 lint findings reported   2 usage or unreadable input/config
 */

import { readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CLASSES = resolve(HERE, "../config/review-finding-classes.v1.json");
const VERDICT_RE = /^VERDICT:\s*(APPROVE|REQUEST_CHANGES)\s*$/;
const FIELD_RE = /^\s*(kind|class|trigger):\s*(.*?)\s*$/i;

function help() {
  console.log(`review-findings-lint.mjs — lint reviewer findings (#401)

WHAT IT DOES
  Checks each finding under "### Findings": blocking finding has a trigger,
  every finding has a known class and kind, VERDICT is the last line.

WHY
  Findings with no trigger are speculation; findings with no class cannot be
  measured per class.

RISKS
  Report-only; not a merge gate. Heuristic markdown parse.

USAGE
  node scripts/review-findings-lint.mjs --file review.md [--classes path]
  <body> | node scripts/review-findings-lint.mjs

EXAMPLES
  node scripts/review-findings-lint.mjs --file review.md; echo $?
  # 0 = clean, 1 = findings reported, 2 = usage / unreadable input
`);
}

export function parseFindings(body) {
  const lines = body.split(/\r?\n/);
  const start = lines.findIndex((l) => /^#{2,4}\s+Findings\s*$/i.test(l));
  if (start === -1) return [];
  const items = [];
  let cur = null;
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    if (/^#{1,4}\s/.test(line) || VERDICT_RE.test(line.trim())) break;
    if (/^[-*]\s+/.test(line)) {
      cur = { line: i + 1, text: line.replace(/^[-*]\s+/, "").trim(), fields: {} };
      items.push(cur);
      const inline = FIELD_RE.exec(cur.text);
      if (inline) cur.fields[inline[1].toLowerCase()] = inline[2];
    } else if (cur && line.trim()) {
      const f = FIELD_RE.exec(line);
      if (f) cur.fields[f[1].toLowerCase()] = f[2];
    }
  }
  return items.filter((it) => !/^(none|no findings)\.?$/i.test(it.text));
}

export function lint(body, vocab) {
  const problems = [];
  const kinds = vocab.kinds;
  const classes = vocab.classes;
  for (const it of parseFindings(body)) {
    const kind = (it.fields.kind || vocab.defaultKind).toLowerCase();
    const cls = (it.fields.class || "").toLowerCase();
    const where = `line ${it.line}`;
    if (!kinds[kind]) problems.push(`${where}: unknown kind '${kind}'`);
    if (!cls) problems.push(`${where}: finding without class`);
    else if (!classes[cls]) problems.push(`${where}: unknown class '${cls}'`);
    if (kinds[kind]?.blocking && !(it.fields.trigger || "").length) {
      problems.push(`${where}: blocking finding without trigger`);
    }
  }
  const nonEmpty = body.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const last = nonEmpty[nonEmpty.length - 1] || "";
  if (!VERDICT_RE.test(last)) {
    problems.push(nonEmpty.some((l) => VERDICT_RE.test(l))
      ? "VERDICT line is not the final line"
      : "missing VERDICT line");
  }
  return problems;
}

function main() {
  const args = process.argv.slice(2);
  if (args.includes("-h") || args.includes("--help")) return help();
  const known = new Set(["--file", "--classes", "-h", "--help"]);
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith("-") && !known.has(args[i])) {
      console.error(`review-findings-lint: unknown flag: ${args[i]} (see --help)`);
      process.exit(2);
    }
    if (args[i] === "--file" || args[i] === "--classes") i++;
  }
  const val = (flag) => {
    const i = args.indexOf(flag);
    return i === -1 ? null : args[i + 1] ?? "";
  };
  const file = val("--file");
  const classesPath = val("--classes") || DEFAULT_CLASSES;
  if (file === "" || classesPath === "") {
    console.error("review-findings-lint: flag requires a value");
    process.exit(2);
  }
  let vocab;
  let body;
  try {
    vocab = JSON.parse(readFileSync(classesPath, "utf8"));
    body = readFileSync(file ?? 0, "utf8");
  } catch (err) {
    console.error(`review-findings-lint: ${err.message}`);
    process.exit(2);
  }
  const problems = lint(body, vocab);
  if (problems.length === 0) {
    console.log("review-findings-lint: clean");
    return;
  }
  for (const p of problems) console.log(`review-findings-lint: ${p}`);
  process.exit(1);
}

function isEntry() {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (process.argv[1] && isEntry()) main();
