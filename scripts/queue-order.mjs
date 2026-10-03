#!/usr/bin/env node
/**
 * queue-order.mjs — newest explicit owner order for one repository (#424).
 *
 * WHAT IT DOES
 *   Reads append-only gibson.owner-order.v1 JSON Lines and prints the single
 *   newest order for --repo, or a HOLD. Instants are strict RFC 3339 values
 *   compared as UTC instants, including every fractional digit. Date.parse
 *   is intentionally not used.
 *
 * WHY
 *   Dispatch must follow an explicit owner instruction. A tie, a bad line, or
 *   a missing file stops the captain instead of guessing from prose or order
 *   in the file.
 *
 * RISKS
 *   HOLD blocks dispatch from this record set. --check-issues shells out to
 *   the installed gh binary with an argument array and never reads tokens.
 *   Read-only on the order file.
 *
 * USAGE
 *   node scripts/queue-order.mjs --file F --repo OWNER/REPO [--check-issues]
 *   node scripts/queue-order.mjs --help
 *
 * EXIT
 *   0 winning order JSON   2 usage   3 HOLD
 */

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const RESOLUTION_SCHEMA = "gibson.owner-order-resolution/v1";
const RECORD_SCHEMA = "gibson.owner-order.v1";
const ALLOWED_KEYS = new Set([
  "schema",
  "issued_at",
  "repo",
  "order",
  "source",
  "supersedes",
]);

// Strict RFC 3339: T separator, seconds, optional fraction, Z or numeric offset.
const RFC3339 =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;

function help() {
  process.stdout.write(`queue-order.mjs — resolve the newest explicit owner order for one repository

WHAT I'M ASKING
  Run this when you need the current owner order for one repository.

WHAT IT DOES
  Reads an append-only JSON Lines file of gibson.owner-order.v1 records and
  prints the single newest order for --repo, or one HOLD line. issued_at must
  be a strict RFC 3339 timestamp (T, and Z or a numeric UTC offset). Valid
  timestamps are compared as instants, not as text, calendar dates, or file
  position. Exact duplicate records collapse. Any other records for that
  repository at the same newest instant are a tie. Records for other
  repositories are ignored. The command never reads prose or an epic map.

WHY
  A merge captain should dispatch from an explicit owner instruction. The
  newest instant wins. A tie or a bad record holds so nothing is inferred.

RISKS
  A HOLD blocks dispatch from this record set until a newer unambiguous order
  is recorded. --check-issues asks the gh command already on this machine
  which winning issues are closed; this tool never reads, prints, or forwards
  token values, and it does not change the winning order. A wrong --file or
  --repo reports that input only. This command does not write the file.
  Undo is to stop using the output and record a new order.

EXAMPLES
  node scripts/queue-order.mjs --help
  node scripts/queue-order.mjs --file orders.jsonl --repo The-AIE/the-gibson
  node scripts/queue-order.mjs --file orders.jsonl --repo The-AIE/the-gibson --check-issues

EXIT
  0  one winning order as JSON
  2  usage: missing, duplicate, or unknown flag
  3  HOLD: no order, malformed evidence, a tie, or an issue check that failed
`);
}

function usage(msg) {
  process.stderr.write(
    `queue-order.mjs: ${msg}\n` +
      "Usage: node scripts/queue-order.mjs --file F --repo OWNER/REPO [--check-issues]\n" +
      "       node scripts/queue-order.mjs --help\n"
  );
  process.exit(2);
}

function hold(msg) {
  process.stdout.write(`${msg}\n`);
  process.exit(3);
}

function parseArgs(argv) {
  if (argv.length === 1 && (argv[0] === "--help" || argv[0] === "-h")) {
    help();
    process.exit(0);
  }
  const seen = new Set();
  let file = null;
  let repo = null;
  let checkIssues = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") usage("--help cannot be combined with other arguments");
    if (a === "--check-issues") {
      if (seen.has(a)) usage(`duplicate flag: ${a}`);
      seen.add(a);
      checkIssues = true;
      continue;
    }
    if (a === "--file" || a === "--repo") {
      if (seen.has(a)) usage(`duplicate flag: ${a}`);
      seen.add(a);
      if (i + 1 >= argv.length) usage(`${a} requires a value`);
      const value = argv[++i];
      if (value === "") usage(`${a} requires a value`);
      if (a === "--file") file = value;
      else repo = value;
      continue;
    }
    if (a.startsWith("-")) usage(`unknown flag: ${a}`);
    usage(`unexpected argument: ${a}`);
  }
  if (file === null) usage("required flag missing: --file");
  if (repo === null) usage("required flag missing: --repo");
  return { file, repo, checkIssues };
}

function daysInMonth(year, month) {
  if (month === 2) {
    const leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
    return leap ? 29 : 28;
  }
  if (month === 4 || month === 6 || month === 9 || month === 11) return 30;
  return 31;
}

// Digit strings are a decimal fraction. Trailing zeros do not change the value,
// and the run is not truncated: the grammar accepts any nonempty length.
function cmpDigitFraction(left, right) {
  const width = left.length > right.length ? left.length : right.length;
  const zero = "0".charCodeAt(0);
  for (let i = 0; i < width; i++) {
    const a = i < left.length ? left.charCodeAt(i) : zero;
    const b = i < right.length ? right.charCodeAt(i) : zero;
    if (a < b) return -1;
    if (a > b) return 1;
  }
  return 0;
}

/**
 * @param {{ epochMs: number, fraction: string }} left
 * @param {{ epochMs: number, fraction: string }} right
 * @returns {number}
 */
function cmpInstant(left, right) {
  if (left.epochMs < right.epochMs) return -1;
  if (left.epochMs > right.epochMs) return 1;
  return cmpDigitFraction(left.fraction, right.fraction);
}

/**
 * @param {unknown} value
 * @returns {{ epochMs: number, fraction: string } | null}
 *   UTC whole second plus the exact fractional digits, or null when not strict RFC 3339
 */
function parseInstant(value) {
  if (typeof value !== "string") return null;
  const match = RFC3339.exec(value);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const fraction = match[7] ? match[7].slice(1) : "";
  const zone = match[8];
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > daysInMonth(year, month)) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;
  let offsetMin = 0;
  if (zone !== "Z") {
    const sign = zone[0] === "-" ? -1 : 1;
    const offsetHour = Number(zone.slice(1, 3));
    const offsetMinute = Number(zone.slice(4, 6));
    if (offsetHour > 23 || offsetMinute > 59) return null;
    offsetMin = sign * (offsetHour * 60 + offsetMinute);
  }
  // Date.UTC maps years 0–99 onto 1900+y. Probe the civil fields and reject
  // that rollover instead of calling Date.parse. Fractional digits stay out of
  // this value: folding them into milliseconds would collapse later instants
  // that the grammar still accepts.
  const wall = Date.UTC(year, month - 1, day, hour, minute, second, 0);
  if (!Number.isFinite(wall)) return null;
  const probe = new Date(wall);
  if (
    probe.getUTCFullYear() !== year ||
    probe.getUTCMonth() !== month - 1 ||
    probe.getUTCDate() !== day ||
    probe.getUTCHours() !== hour ||
    probe.getUTCMinutes() !== minute ||
    probe.getUTCSeconds() !== second ||
    probe.getUTCMilliseconds() !== 0
  ) {
    return null;
  }
  return { epochMs: wall - offsetMin * 60000, fraction };
}

function badLine(lineNo) {
  hold(`HOLD: malformed owner order at line ${lineNo}`);
}

function parseOrder(value, lineNo) {
  if (!Array.isArray(value) || value.length === 0) badLine(lineNo);
  const seen = new Set();
  const order = [];
  for (const item of value) {
    if (typeof item !== "number" || !Number.isSafeInteger(item) || item <= 0) badLine(lineNo);
    if (seen.has(item)) badLine(lineNo);
    seen.add(item);
    order.push(item);
  }
  return order;
}

function parseRecord(obj, lineNo) {
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) badLine(lineNo);
  for (const key of Object.keys(obj)) {
    if (!ALLOWED_KEYS.has(key)) badLine(lineNo);
  }
  if (!Object.prototype.hasOwnProperty.call(obj, "schema")) badLine(lineNo);
  if (!Object.prototype.hasOwnProperty.call(obj, "issued_at")) badLine(lineNo);
  if (!Object.prototype.hasOwnProperty.call(obj, "repo")) badLine(lineNo);
  if (!Object.prototype.hasOwnProperty.call(obj, "order")) badLine(lineNo);
  if (!Object.prototype.hasOwnProperty.call(obj, "source")) badLine(lineNo);
  if (obj.schema !== RECORD_SCHEMA) badLine(lineNo);
  const instant = parseInstant(obj.issued_at);
  if (instant === null) badLine(lineNo);
  if (typeof obj.repo !== "string" || obj.repo.length === 0) badLine(lineNo);
  if (typeof obj.source !== "string" || obj.source.length === 0) badLine(lineNo);
  const order = parseOrder(obj.order, lineNo);
  let supersedes = null;
  if (Object.prototype.hasOwnProperty.call(obj, "supersedes")) {
    const supersedesInstant = parseInstant(obj.supersedes);
    if (supersedesInstant === null) badLine(lineNo);
    supersedes = obj.supersedes;
  }
  return {
    schema: obj.schema,
    issued_at: obj.issued_at,
    instant,
    repo: obj.repo,
    order,
    source: obj.source,
    supersedes,
  };
}

function canonical(rec) {
  return JSON.stringify({
    schema: rec.schema,
    issued_at: rec.issued_at,
    repo: rec.repo,
    order: rec.order,
    source: rec.source,
    supersedes: rec.supersedes,
  });
}

function loadRecords(file, repo) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (err) {
    if (err && err.code === "ENOENT") hold("HOLD: no owner order recorded");
    hold("HOLD: cannot read owner order file");
  }
  if (text.length === 0) hold("HOLD: no owner order recorded");
  const lines = text.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  const target = [];
  for (let i = 0; i < lines.length; i++) {
    const lineNo = i + 1;
    const line = lines[i];
    if (line.trim() === "") badLine(lineNo);
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      badLine(lineNo);
    }
    const rec = parseRecord(parsed, lineNo);
    if (rec.repo === repo) target.push(rec);
  }
  return target;
}

function selectWinner(records) {
  if (records.length === 0) hold("HOLD: no owner order recorded");
  let max = records[0].instant;
  for (const rec of records) {
    if (cmpInstant(rec.instant, max) > 0) max = rec.instant;
  }
  const atMax = records.filter((rec) => cmpInstant(rec.instant, max) === 0);
  const unique = [];
  const seen = new Set();
  for (const rec of atMax) {
    const key = canonical(rec);
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(rec);
  }
  if (unique.length !== 1) {
    const sources = unique
      .slice()
      .sort((a, b) => {
        if (a.source < b.source) return -1;
        if (a.source > b.source) return 1;
        const left = canonical(a);
        const right = canonical(b);
        if (left < right) return -1;
        if (left > right) return 1;
        return 0;
      })
      .map((rec) => JSON.stringify(rec.source));
    hold(`HOLD: ambiguous owner order; sources: ${sources.join(" | ")}`);
  }
  return unique[0];
}

function lookupIssueState(repo, number) {
  const result = spawnSync(
    "gh",
    ["issue", "view", String(number), "--repo", repo, "--json", "state"],
    {
      encoding: "utf8",
      shell: false,
      windowsHide: true,
      timeout: 30000,
    }
  );
  if (result.error && result.error.code === "ENOENT") {
    return { hold: "HOLD: gh is not available" };
  }
  if (result.error || result.status !== 0) {
    return { hold: `HOLD: issue lookup failed for ${number}` };
  }
  let parsed;
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    return { hold: `HOLD: malformed issue state for ${number}` };
  }
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    Array.isArray(parsed) ||
    typeof parsed.state !== "string"
  ) {
    return { hold: `HOLD: malformed issue state for ${number}` };
  }
  const state = parsed.state.toLowerCase();
  if (state !== "open" && state !== "closed") {
    return { hold: `HOLD: unknown issue state for ${number}` };
  }
  return { state };
}

function emitWinner(rec, closedIssues) {
  const out = {
    schema: RESOLUTION_SCHEMA,
    repo: rec.repo,
    issued_at: rec.issued_at,
    source: rec.source,
    order: rec.order,
  };
  if (closedIssues) out.closed_issues = closedIssues;
  process.stdout.write(`${JSON.stringify(out)}\n`);
  process.exit(0);
}

const args = parseArgs(process.argv.slice(2));
const records = loadRecords(args.file, args.repo);
const winner = selectWinner(records);
if (!args.checkIssues) emitWinner(winner, null);
const closed = [];
for (const number of winner.order) {
  const looked = lookupIssueState(args.repo, number);
  if (looked.hold) hold(looked.hold);
  if (looked.state === "closed") closed.push(number);
}
emitWinner(winner, closed);
