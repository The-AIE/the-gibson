#!/usr/bin/env node
// flaky-guard.mjs — flags the cheap ways of papering over a flaky test (#756).
//
// WHAT IT DOES
//   Reads the added lines of a diff (`git diff -U0 base...head`, or a saved
//   diff with --diff FILE) and reports three kinds of change inside test files:
//     sleep  a fixed wait added to a test (sleep N, setTimeout(resolve, N), ...)
//     skip   a skip marker added to a test (.skip(, xit(, pytest skip, ...)
//     retry  a retry-until-green device (retryTimes, retries: N, --reruns, ...)
//   An agent that adds one of these is teaching the fleet to rerun instead of
//   fix. The rule is in playbooks/builder.md and playbooks/test-engineer.md:
//   find the root cause; if you cannot, quarantine with an issue link or delete
//   the test and say why.
//
// WAIVER
//   A line may carry `flaky-guard: allow <reason>` (reason of at least 8
//   characters) on the same added line or the added line directly above it.
//   A waiver with no reason is itself a finding (waiver-no-reason).
//
// WHY / RISKS
//   Report-only first (docs/28: new checks are advisory, then promote after a
//   baseline). Only ADDED lines are read, so existing sleeps never fire and
//   deleted tests are test-integrity.mjs's job, not this script's. Matching is
//   by line pattern, not by parsing: a pattern can miss a rewritten form and
//   can fire on an unrelated word. Diff text is inert data, matched and never
//   evaluated. Fixture, snapshot and markdown paths are not test code and are
//   ignored.
//
// USAGE
//   node scripts/flaky-guard.mjs [--base REF] [--head REF] [--format text|json]
//                                [--strict]
//   node scripts/flaky-guard.mjs --diff FILE      # offline: saved `git diff -U0`
//   Env: GIBSON_PR_BASE (default origin/main)
//   Under GITHUB_ACTIONS=true each finding is also a ::warning:: annotation.
//
// EXIT
//   0 no findings, or findings in report-only mode   1 findings with --strict
//   2 usage / git / read error

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const GIT_TIMEOUT_MS = 30_000;
const GIT_MAX_BUFFER = 32 * 1024 * 1024;
const MAX_ANNOTATIONS = 50;
const SNIPPET_MAX = 120;
const MIN_REASON = 8;

// Closed pattern list. Extending it is a reviewed change to this file.
export const PATTERNS = [
  { id: "sleep", re: /(^|[\s;&|(`])sleep\s+(\d|\$)/, why: "fixed shell sleep in a test" },
  { id: "sleep", re: /\btime\.[Ss]leep\(/, why: "fixed sleep in a test" },
  { id: "sleep", re: /\bThread\.sleep\(/, why: "fixed sleep in a test" },
  { id: "sleep", re: /\bsetTimeout\(\s*[A-Za-z_$][\w$]*\s*,\s*\d+/, why: "timer used as a sleep in a test" },
  { id: "sleep", re: /\bawait\s+(sleep|delay|wait)\(\s*\d+/, why: "fixed wait in a test" },
  { id: "sleep", re: /\b(waitForTimeout|cy\.wait)\(\s*\d+/, why: "fixed wait in a test" },
  { id: "skip", re: /\b(it|test|describe|context|suite)\.(skip|fixme)\b/, why: "skip marker added to a test" },
  { id: "skip", re: /\bx(it|describe|test)\(/, why: "disabled test (x-prefixed)" },
  { id: "skip", re: /@pytest\.mark\.(skip|skipif|xfail)\b|\bpytest\.(skip|xfail)\(/, why: "skip marker added to a test" },
  { id: "skip", re: /\bunittest\.skip(If|Unless)?\b|\bt\.Skip(f|Now)?\(/, why: "skip marker added to a test" },
  { id: "skip", re: /@(Ignore|Disabled)\b/, why: "skip marker added to a test" },
  { id: "skip", re: /\{\s*skip\s*:\s*(true|["'`])/, why: "skip option added to a test" },
  { id: "retry", re: /\bjest\.retryTimes\(/, why: "retry-until-green device" },
  { id: "retry", re: /\bretries\s*:\s*[1-9]/, why: "retry-until-green device" },
  { id: "retry", re: /--(retries|reruns)(=|\s)\s*[1-9]|\brerunfailures\b/, why: "retry-until-green device" },
  { id: "retry", re: /@flaky\b|\bpytest\.mark\.flaky\b|\bflaky\(/, why: "test marked flaky instead of fixed" },
  { id: "retry", re: /\b(until|while\s+!?)\s*(bash\s+\S*|npm\s+(run\s+)?|npx\s+|pnpm\s+|yarn\s+|pytest|vitest|jest|go\s+)test/, why: "rerun loop around a test command" },
];

const WAIVER = /flaky-guard:\s*allow(\s+(\S[^\n]*))?/;

const CODE_EXT = /\.(mjs|cjs|js|jsx|ts|tsx|py|rb|go|java|kt|rs|sh|bash|zsh)$/;
const NOT_TEST_CODE = /(^|\/)(fixtures|__fixtures__|__snapshots__)\//;
const TEST_PATH = [
  /(^|\/)(tests?|__tests__|e2e|spec)\//,
  /\.(test|spec)\.[^/]+$/,
  /(^|\/)test_[^/]+\.py$/,
  /_test\.(go|py|rb)$/,
];
const TEST_CONFIG = /(^|\/)(playwright|jest|vitest|cypress)\.config\.[^/]+$/;

export function isTestFile(path) {
  if (NOT_TEST_CODE.test(path)) return false;
  if (TEST_CONFIG.test(path)) return true;
  if (!CODE_EXT.test(path)) return false;
  return TEST_PATH.some((re) => re.test(path));
}

/** Parse `git diff -U0` text into [{ path, line, text }] for added lines. */
export function addedLines(diffText) {
  const out = [];
  let path = null;
  let next = 0;
  for (const raw of diffText.split("\n")) {
    if (raw.startsWith("+++ ")) {
      const p = raw.slice(4).split("\t")[0].replace(/^"|"$/g, "");
      path = p === "/dev/null" ? null : p.replace(/^b\//, "");
      continue;
    }
    if (raw.startsWith("--- ") || raw.startsWith("diff --git")) continue;
    const hunk = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(raw);
    if (hunk) {
      next = Number(hunk[1]);
      continue;
    }
    if (path === null) continue;
    if (raw.startsWith("+")) {
      out.push({ path, line: next, text: raw.slice(1) });
      next += 1;
    }
  }
  return out;
}

function snippet(text) {
  const t = text.trim().replace(/\s+/g, " ");
  return t.length > SNIPPET_MAX ? `${t.slice(0, SNIPPET_MAX - 1)}…` : t;
}

/** @returns {{findings: object[], waived: number, files: number}} */
export function scan(diffText) {
  const added = addedLines(diffText).filter((a) => isTestFile(a.path));
  const byKey = new Map(added.map((a) => [`${a.path}:${a.line}`, a]));
  const findings = [];
  let waived = 0;
  const files = new Set();

  for (const a of added) {
    const own = WAIVER.exec(a.text);
    const above = byKey.get(`${a.path}:${a.line - 1}`);
    // A waiver on the line above counts only when that line is a bare pragma
    // comment; a waiver riding on a code line covers that line alone.
    const aboveW = above ? WAIVER.exec(above.text) : null;
    const aboveBare = aboveW && above.text.replace(WAIVER, "").replace(/[#/*\-\s]/g, "") === "";
    const pragma = own || (aboveBare ? aboveW : null);
    const reason = pragma && pragma[2] ? pragma[2].trim() : "";
    const reasoned = reason.length >= MIN_REASON;

    if (own && !reasoned) {
      findings.push({ path: a.path, line: a.line, id: "waiver-no-reason", why: `waiver needs a reason of at least ${MIN_REASON} characters`, text: snippet(a.text) });
      files.add(a.path);
    }
    const hit = PATTERNS.find((p) => p.re.test(a.text.replace(WAIVER, "")));
    if (!hit) continue;
    if (reasoned) {
      waived += 1;
      continue;
    }
    findings.push({ path: a.path, line: a.line, id: hit.id, why: hit.why, text: snippet(a.text) });
    files.add(a.path);
  }
  return { findings, waived, files: files.size };
}

function dieUsage(msg) {
  console.error(`flaky-guard: ${msg}`);
  process.exit(2);
}

function parseArgs(argv) {
  const o = { base: process.env.GIBSON_PR_BASE || "origin/main", head: "HEAD", diff: null, format: "text", strict: false };
  const takes = new Set(["--base", "--head", "--diff", "--format"]);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--strict") o.strict = true;
    else if (a === "--help" || a === "-h") {
      console.log("usage: flaky-guard.mjs [--base REF] [--head REF] [--diff FILE] [--format text|json] [--strict]");
      process.exit(0);
    } else if (takes.has(a)) {
      if (i + 1 >= argv.length) dieUsage(`${a} requires a value`);
      const v = argv[++i];
      if (a === "--base") o.base = v;
      else if (a === "--head") o.head = v;
      else if (a === "--diff") o.diff = v;
      else o.format = v;
    } else dieUsage(`unknown flag: ${a}`);
  }
  if (!["text", "json"].includes(o.format)) dieUsage("--format must be text or json");
  return o;
}

function readDiff(o) {
  if (o.diff) {
    try {
      return readFileSync(o.diff, "utf8");
    } catch (e) {
      dieUsage(`cannot read ${o.diff}: ${e.message}`);
    }
  }
  try {
    return execFileSync("git", ["diff", "-U0", "--no-color", "--no-renames", `${o.base}...${o.head}`, "--"], {
      encoding: "utf8",
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: GIT_MAX_BUFFER,
    });
  } catch (e) {
    return dieUsage(`git diff ${o.base}...${o.head} failed: ${String(e.message).split("\n")[0]}`);
  }
}

function main(argv) {
  const o = parseArgs(argv);
  const { findings, waived, files } = scan(readDiff(o));
  const mode = o.strict ? "strict" : "report-only";

  if (o.format === "json") {
    console.log(JSON.stringify({ mode, findings, waived, files }, null, 2));
  } else {
    console.log(`flaky-guard: ${findings.length} finding(s) in ${files} test file(s), ${waived} waived (${mode})`);
    for (const f of findings) console.log(`  ${f.path}:${f.line} [${f.id}] ${f.why}: ${f.text}`);
    if (findings.length) {
      console.log("  Fix the root cause. If you cannot, quarantine with an issue link or delete the test and say why.");
      console.log("  A deliberate wait may carry: flaky-guard: allow <reason>");
    }
  }
  if (process.env.GITHUB_ACTIONS === "true") {
    for (const f of findings.slice(0, MAX_ANNOTATIONS)) {
      console.log(`::warning file=${f.path},line=${f.line},title=flaky-guard ${f.id}::${f.why}`);
    }
  }
  process.exit(o.strict && findings.length ? 1 : 0);
}

import { fileURLToPath } from "node:url";
import { realpathSync } from "node:fs";
const self = (() => { try { return realpathSync(fileURLToPath(import.meta.url)); } catch { return fileURLToPath(import.meta.url); } })();
const entry = (() => { try { return realpathSync(process.argv[1] || ""); } catch { return process.argv[1] || ""; } })();
if (self === entry) main(process.argv.slice(2));
