#!/usr/bin/env node
/**
 * review-findings-lint.mjs — lint the Findings section of a review body (#401)
 *
 * WHAT IT DOES
 *   Parses a review body and reports: a blocking finding without a `trigger:`
 *   line, a finding missing a field its kind requires (a `pre-existing` finding
 *   needs `trigger:` and `base:` evidence, #758), a finding without `class:`, an unknown class, an unknown kind, and a
 *   missing or non-final VERDICT line. Vocabularies come from
 *   config/review-finding-classes.v1.json. A malformed `requires` list in that
 *   file is a config error: reported once, exit 2, whatever the review contains.
 *   The linter checks that required lines are present. It cannot check that a
 *   `pre-existing` defect is unreached by the diff; that stays reviewer judgment.
 *
 * WHY
 *   A finding with no reachable trigger is speculation, and a finding with no
 *   class cannot be counted per class. Both are checkable by machine.
 *
 * RISKS
 *   - Report-only. Not wired into any merge gate by #401.
 *   - Heuristic markdown parse: findings are top-level `- ` bullets under the
 *     `### Findings` heading; `kind:`/`class:`/`trigger:`/`base:` are continuation lines.
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
import { parseFlags } from "./lib/args.mjs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CLASSES = resolve(HERE, "../config/review-finding-classes.v1.json");
const VERDICT_RE = /^VERDICT:\s*(APPROVE|REQUEST_CHANGES)\s*$/;
// Fields a kind may demand through `requires` in the vocabulary file, with the
// wording used in a report. This is the one list: FIELD_RE is built from it.
const REQUIRABLE = { trigger: "trigger", base: "base evidence" };
const FIELD_RE = new RegExp(
  `^\\s*(kind|class|${Object.keys(REQUIRABLE).join("|")}):\\s*(.*?)\\s*$`,
  "i",
);

function help() {
  console.log(`review-findings-lint.mjs — lint reviewer findings (#401)

WHAT IT DOES
  Checks each finding under "### Findings": blocking finding has a trigger,
  a finding carries every field its kind requires (pre-existing: trigger and
  base evidence), every finding has a known class and an explicit known kind,
  VERDICT is the last line.

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
  # 0 = clean, 1 = findings reported, 2 = usage / unreadable input or config
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

// Errors in the vocabulary file itself, independent of any review body.
export function validateVocab(vocab) {
  const errors = [];
  for (const [name, def] of Object.entries(vocab?.kinds ?? {})) {
    const requires = def?.requires;
    if (requires === undefined) continue;
    if (!Array.isArray(requires)) {
      errors.push(`kind '${name}' has an invalid requires list in the vocabulary`);
      continue;
    }
    for (const field of requires) {
      if (!Object.hasOwn(REQUIRABLE, field)) {
        errors.push(`kind '${name}' requires unknown field '${field}'`);
      }
    }
  }
  return errors;
}

export function lint(body, vocab) {
  const problems = [];
  const kinds = vocab.kinds;
  const classes = vocab.classes;
  for (const it of parseFindings(body)) {
    const kind = (it.fields.kind || vocab.defaultKind).toLowerCase();
    if (!it.fields.kind) problems.push(`line ${it.line}: finding without kind`);
    const cls = (it.fields.class || "").toLowerCase();
    const where = `line ${it.line}`;
    if (!kinds[kind]) problems.push(`${where}: unknown kind '${kind}'`);
    if (!cls) problems.push(`${where}: finding without class`);
    else if (!classes[cls]) problems.push(`${where}: unknown class '${cls}'`);
    // One required-field set per finding: a blocking kind always needs a
    // trigger, and a kind may list more in `requires`. A field in both is
    // reported once. Vocabulary errors are validateVocab's job, not a finding's.
    const def = kinds[kind];
    const required = new Set(def?.blocking ? ["trigger"] : []);
    for (const field of Array.isArray(def?.requires) ? def.requires : []) required.add(field);
    for (const field of required) {
      if (!Object.hasOwn(REQUIRABLE, field) || (it.fields[field] || "").length) continue;
      const subject = def.blocking && field === "trigger" ? "blocking" : kind;
      problems.push(`${where}: ${subject} finding without ${REQUIRABLE[field]}`);
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
  const opt = parseFlags(args, {
    flags: {
      "--file": { key: "file", default: null },
      "--classes": { key: "classes", default: DEFAULT_CLASSES },
    },
  });
  const file = opt.file;
  const classesPath = opt.classes;
  let vocab;
  let body;
  try {
    vocab = JSON.parse(readFileSync(classesPath, "utf8"));
    body = readFileSync(file ?? 0, "utf8");
  } catch (err) {
    console.error(`review-findings-lint: ${err.message}`);
    process.exit(2);
  }
  const vocabErrors = validateVocab(vocab);
  if (vocabErrors.length > 0) {
    for (const e of vocabErrors) console.error(`review-findings-lint: ${classesPath}: ${e}`);
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
