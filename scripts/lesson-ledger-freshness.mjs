#!/usr/bin/env node
/**
 * lesson-ledger-freshness.mjs — ledger freshness and prose-only debt (#571, extends #418).
 *
 * WHAT IT DOES
 *   Reads a lesson ledger and an activity record. Prints freshness
 *   (healthy, stale, or unknown), the prose-only debt count (Status lines
 *   containing the configured marker, shipped as "no sensor yet"), each
 *   lesson's age, and a ratchet against config/lesson-debt-baseline.json.
 *   --annotate prints "untrusted, verify before acting" when freshness is
 *   stale or unknown.
 *
 * WHY
 *   A ledger that stops taking lessons while commits still land on main is
 *   a silent ratchet. Cosmetic edits must not look like intake. A check
 *   that cannot run must not look healthy.
 *
 * RISKS
 *   Report-only. Exit 0 covers a completed RED finding as well as GREEN.
 *   Only UNKNOWN exits 1. This file does not block merges, does not merge
 *   anything, and does not write the ledger or the baseline. Live mode
 *   counts every commit on the ref in the window (squash merges count). It
 *   does not call the network. Shallow or missing history is unknown.
 *   Intake is heading ids present now and absent before the window, so a
 *   lesson added and removed inside the window is not intake. --annotate
 *   follows freshness only; a debt-ratchet failure is in the full report.
 *   Stdout is the result. The scheduled workflow copies it into the job
 *   summary. This process does not write that file. A RED verdict exits 0,
 *   so a later observer that only checks the job succeeded will not see it.
 *
 * USAGE
 *   node scripts/lesson-ledger-freshness.mjs --fixture DIR --now ISO [--baseline FILE]
 *   node scripts/lesson-ledger-freshness.mjs --lessons FILE --activity FILE --now ISO
 *   node scripts/lesson-ledger-freshness.mjs --root DIR [--now ISO] [--activity-ref REF]
 *   node scripts/lesson-ledger-freshness.mjs --annotate
 *   node scripts/lesson-ledger-freshness.mjs --help
 *
 * EXIT
 *   0  observation complete (verdict GREEN or RED)
 *   1  UNKNOWN (activity, ledger, or baseline could not be evaluated)
 *   2  usage
 */

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseFlags } from "./lib/args.mjs";

const SCHEMA = "gibson.lesson-debt-baseline.v1";
const DEFAULT_BASELINE_REL = "config/lesson-debt-baseline.json";
const DEFAULT_LESSONS_REL = "memory/LESSONS.md";
const MS_DAY = 86400000;
const HEADING_RE = /^## (L-\d{3}) · (\d{4}-\d{2}(?:-\d{2})?) · ([A-Za-z0-9-]+)[ \t]*$/;
const STATUS_RE = /^\*\*Status:\*\*[ \t]*(.*)$/;
const UNTRUSTED = "untrusted, verify before acting";

function help() {
  console.log(`lesson-ledger-freshness.mjs — ledger freshness and prose-only debt (#571, extends #418)

WHAT IT DOES
  Reports freshness as healthy, stale, or unknown. Stale means commits landed
  on the ref during the window and the ledger gained no new lesson heading.
  Unknown means activity, the ledger, or the baseline could not be evaluated.
  Unknown is never printed as healthy. Cosmetic edits (whitespace, links,
  wording, or a rewritten date on an existing heading id) do not reset
  freshness. Debt is the count of lessons whose Status line contains the
  configured marker. The count may fall against the baseline and must not
  rise. Per-lesson age is days from a full heading date to --now.

WHY
  Law 9 has no sensor for a ledger that goes quiet while main keeps moving.
  Prose-only lessons (the marker, shipped as "no sensor yet") are tracked
  debt. A check that cannot run must not look correct.

RISKS
  Read-only. Does not block merges and does not merge anything. Exit 0 is a
  completed observation: verdict RED (stale or debt over baseline) and
  verdict GREEN both exit 0. Exit 1 is UNKNOWN. A green process exit is not
  a healthy ledger; read the verdict line. Live mode uses local git only.
  Shallow history, a missing ref, or an unreadable baseline is unknown.
  Intake ignores body text. A heading added and then removed inside the
  window is not intake. Month-only heading dates report ageDays=unknown.
  --annotate marks lessons only when freshness is stale or unknown. This
  script does not grade its own workflow run.

USAGE
  node scripts/lesson-ledger-freshness.mjs --fixture DIR --now ISO [--baseline FILE] [--annotate]
  node scripts/lesson-ledger-freshness.mjs --lessons FILE --prior-lessons FILE --activity FILE --now ISO [--baseline FILE]
  node scripts/lesson-ledger-freshness.mjs --root DIR [--now ISO] [--activity-ref REF] [--baseline FILE]
  node scripts/lesson-ledger-freshness.mjs --committed-baseline FILE
  node scripts/lesson-ledger-freshness.mjs --help

  --window-days N    override the baseline window (positive integer).
                     The shipped baseline window is 14 days.

EXIT
  0  GREEN or RED (complete)    1  UNKNOWN    2  usage
`);
}

function dieUsage(msg) {
  console.error(`lesson-ledger-freshness: ${msg}`);
  process.exit(2);
}

function isMain() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(resolve(entry)) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

function gitEnv() {
  const env = { ...process.env };
  for (const key of [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_PREFIX",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_NAMESPACE",
  ]) {
    delete env[key];
  }
  env.GIT_TERMINAL_PROMPT = "0";
  return env;
}

function git(root, args) {
  try {
    const stdout = execFileSync("git", ["-C", root, ...args], {
      encoding: "utf8",
      env: gitEnv(),
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 16 * 1024 * 1024,
    });
    return { ok: true, stdout, stderr: "" };
  } catch (error) {
    const stderr = error && error.stderr ? String(error.stderr) : "";
    const stdout = error && error.stdout ? String(error.stdout) : "";
    return { ok: false, stdout, stderr, status: error && error.status ? error.status : 1 };
  }
}

function readText(path) {
  try {
    return { ok: true, text: readFileSync(path, "utf8") };
  } catch (error) {
    const code = error && error.code ? error.code : "";
    return { ok: false, code, message: error && error.message ? error.message : "read failed" };
  }
}

/**
 * Fence-aware ledger parse. Headings inside a fence are not lessons.
 * The first Status line outside a fence is the status. A heading that does
 * not match the ledger shape fails the whole parse (unknown, not a guess).
 *
 * @param {string} text
 * @param {string} marker
 */
export function parseLedger(text, marker) {
  const lessons = [];
  const seen = new Set();
  let fence = null;
  let current = null;
  const lines = String(text).replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
  const closeCurrent = () => {
    if (!current) return;
    lessons.push(current);
    current = null;
  };
  for (const line of lines) {
    const markerMatch = /^(?: {0,3})(`{3,}|~{3,})(.*)$/.exec(line); // MUTATION_FENCE
    if (fence) {
      if (
        markerMatch &&
        markerMatch[1][0] === fence.char &&
        markerMatch[1].length >= fence.len &&
        markerMatch[2].trim() === ""
      ) {
        fence = null;
      }
      continue;
    }
    if (markerMatch) {
      fence = { char: markerMatch[1][0], len: markerMatch[1].length };
      continue;
    }
    if (line.startsWith("## L-")) {
      const heading = HEADING_RE.exec(line);
      if (!heading) {
        return { ok: false, reason: "malformed-heading", lessons: [], text };
      }
      closeCurrent();
      const id = heading[1];
      if (seen.has(id)) {
        return { ok: false, reason: "duplicate-lesson-id", lessons: [], text };
      }
      seen.add(id);
      current = {
        id,
        date: heading[2],
        slug: heading[3],
        status: null,
        proseOnly: false,
      };
      continue;
    }
    if (current && current.status === null) {
      const status = STATUS_RE.exec(line);
      if (status) {
        current.status = status[1];
        current.proseOnly = current.status.includes(marker);
      }
    }
  }
  closeCurrent();
  return { ok: true, reason: "ok", lessons, text };
}

export function ageDays(headingDate, nowMs) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(headingDate)) return null;
  const parsed = Date.parse(`${headingDate}T00:00:00.000Z`);
  if (Number.isNaN(parsed)) return null;
  return Math.floor(nowMs / MS_DAY) - Math.floor(parsed / MS_DAY);
}

function loadBaseline(path) {
  const read = readText(path);
  if (!read.ok) {
    return { ok: false, reason: read.code === "ENOENT" ? "baseline-missing" : "baseline-unreadable" };
  }
  let parsed;
  try {
    parsed = JSON.parse(read.text);
  } catch {
    return { ok: false, reason: "baseline-malformed" };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, reason: "baseline-malformed" };
  }
  if (parsed.schema !== SCHEMA) return { ok: false, reason: "baseline-malformed" };
  if (!Number.isInteger(parsed.windowDays) || parsed.windowDays < 1) {
    return { ok: false, reason: "baseline-malformed" };
  }
  if (!Number.isInteger(parsed.proseOnlyCount) || parsed.proseOnlyCount < 0) {
    return { ok: false, reason: "baseline-malformed" };
  }
  if (typeof parsed.statusMarker !== "string" || parsed.statusMarker.length === 0) {
    return { ok: false, reason: "baseline-malformed" };
  }
  if (parsed.measuredOn !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(parsed.measuredOn)) {
    return { ok: false, reason: "baseline-malformed" };
  }
  return {
    ok: true,
    windowDays: parsed.windowDays,
    proseOnlyCount: parsed.proseOnlyCount,
    statusMarker: parsed.statusMarker,
  };
}

function loadActivity(path) {
  const read = readText(path);
  if (!read.ok) {
    return { available: false, reason: "activity-unavailable", merges: [] };
  }
  let parsed;
  try {
    parsed = JSON.parse(read.text);
  } catch {
    return { available: false, reason: "activity-unparseable", merges: [] };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || typeof parsed.available !== "boolean") {
    return { available: false, reason: "activity-unparseable", merges: [] };
  }
  if (parsed.available !== true) {
    const reason = typeof parsed.reason === "string" && parsed.reason.length > 0
      ? parsed.reason
      : "activity-unavailable";
    return { available: false, reason, merges: [] };
  }
  if (!Array.isArray(parsed.merges)) {
    return { available: false, reason: "activity-unparseable", merges: [] };
  }
  const merges = [];
  for (const row of parsed.merges) {
    if (!row || typeof row !== "object" || typeof row.committedAt !== "string") {
      return { available: false, reason: "activity-unparseable", merges: [] };
    }
    if (Number.isNaN(Date.parse(row.committedAt))) {
      return { available: false, reason: "activity-unparseable", merges: [] };
    }
    if (row.sha !== undefined && (typeof row.sha !== "string" || !/^[0-9a-f]{40}$/.test(row.sha))) {
      return { available: false, reason: "activity-unparseable", merges: [] };
    }
    merges.push({ sha: row.sha || "", committedAt: row.committedAt });
  }
  return { available: true, reason: "ok", merges };
}

function freshnessUnknown(reason) {
  return {
    freshness: "unknown",
    reason,
    mergesInWindow: null,
    newHeadings: null,
    cosmeticOnly: null,
  };
}

/**
 * @param {{ activity: { available: boolean, reason: string, merges: { committedAt: string }[] }, prior: { ok: boolean, reason?: string, lessons: { id: string }[], text: string }, current: { ok: boolean, reason?: string, lessons: { id: string }[], text: string }, windowStartMs: number, nowMs: number }} input
 */
export function decideFreshness(input) {
  const activity = input.activity;
  if (!activity || activity.available !== true) {
    return { freshness: "unknown", reason: activity && activity.reason ? activity.reason : "activity-unavailable", mergesInWindow: null, newHeadings: null, cosmeticOnly: null }; // MUTATION_ACTIVITY
  }
  if (!input.current || !input.current.ok) {
    return freshnessUnknown(input.current && input.current.reason ? input.current.reason : "ledger-missing"); // MUTATION_LEDGER
  }
  let mergesInWindow = 0;
  for (const merge of activity.merges) {
    const stamp = Date.parse(merge.committedAt);
    if (Number.isNaN(stamp)) return freshnessUnknown("activity-unparseable");
    if (stamp >= input.windowStartMs && stamp <= input.nowMs) mergesInWindow += 1;
  }
  const priorOk = Boolean(input.prior && input.prior.ok);
  const priorIds = priorOk ? new Set(input.prior.lessons.map((lesson) => lesson.id)) : null;
  const added = priorOk ? input.current.lessons.filter((lesson) => !priorIds.has(lesson.id)) : [];
  const priorText = priorOk ? input.prior.text : "";
  const currentText = input.current.text;
  const bodyDiff = priorOk && priorText !== currentText;
  const cosmeticOnly = priorOk ? added.length === 0 && bodyDiff : null;
  const intake = added.length > 0; // MUTATION_COSMETIC
  if (mergesInWindow === 0) {
    return {
      freshness: "healthy",
      reason: priorOk && added.length > 0 ? "intake-without-merges" : "inactivity",
      mergesInWindow,
      newHeadings: priorOk ? added.length : null,
      cosmeticOnly,
    }; // MUTATION_QUIET
  }
  if (!priorOk) {
    return freshnessUnknown(input.prior && input.prior.reason ? input.prior.reason : "prior-ledger-missing");
  }
  if (mergesInWindow > 0 && !intake) {
    return {
      freshness: "stale",
      reason: "merges-without-intake",
      mergesInWindow,
      newHeadings: added.length,
      cosmeticOnly,
    }; // MUTATION_STALE
  }
  return {
    freshness: "healthy",
    reason: "intake",
    mergesInWindow,
    newHeadings: added.length,
    cosmeticOnly,
  };
}

function debtDecision(debtCount, baseline, committed) {
  if (!baseline.ok) {
    return { debtRatchet: "unknown", debtReason: baseline.reason, debtBaseline: null };
  }
  if (committed && committed.checked && !committed.ok) {
    return { debtRatchet: "unknown", debtReason: committed.reason, debtBaseline: baseline.proseOnlyCount };
  }
  if (!Number.isInteger(debtCount) || debtCount < 0) {
    return { debtRatchet: "unknown", debtReason: "debt-unknown", debtBaseline: baseline.proseOnlyCount };
  }
  const reasons = [];
  if (debtCount > baseline.proseOnlyCount) reasons.push("count-rose"); // MUTATION_DEBT
  if (committed && committed.ok && !committed.absent) {
    if (baseline.proseOnlyCount > committed.proseOnlyCount) reasons.push("baseline-raised"); // MUTATION_BASELINE
    if (baseline.windowDays > committed.windowDays) reasons.push("window-loosened"); // MUTATION_WINDOW
  }
  if (reasons.length > 0) {
    return { debtRatchet: "over", debtReason: reasons.join("+"), debtBaseline: baseline.proseOnlyCount };
  }
  return {
    debtRatchet: "ok",
    debtReason: debtCount < baseline.proseOnlyCount ? "below-baseline" : "ok", // MUTATION_FALL
    debtBaseline: baseline.proseOnlyCount,
  };
}

function showField(value) {
  if (value === null || value === undefined) return "unknown";
  if (value === true) return "yes";
  if (value === false) return "no";
  return String(value);
}

function formatReport(report, annotate) {
  if (annotate) {
    const lines = [`freshness: ${report.freshness}`];
    const untrusted = report.freshness === "stale" || report.freshness === "unknown"; // MUTATION_ANNOTATE
    if (untrusted) {
      lines.push(`ledger: ${UNTRUSTED}`);
      for (const lesson of report.lessons) lines.push(`${lesson.id} ${UNTRUSTED}`);
    }
    return lines.join("\n") + "\n";
  }
  const lines = [
    `verdict: ${report.verdict}`,
    `freshness: ${report.freshness}`,
    `reason: ${report.reason}`,
    `observation: ${report.observation}`,
    `windowDays: ${showField(report.windowDays)}`,
    `now: ${report.now}`,
    `windowStart: ${showField(report.windowStart)}`,
    `mergesInWindow: ${showField(report.mergesInWindow)}`,
    `newHeadings: ${showField(report.newHeadings)}`,
    `cosmeticOnly: ${showField(report.cosmeticOnly)}`,
    `debtCount: ${showField(report.debtCount)}`,
    `debtBaseline: ${showField(report.debtBaseline)}`,
    `debtRatchet: ${report.debtRatchet}`,
    `debtReason: ${report.debtReason}`,
    `committedBaseline: ${report.committedBaseline}`,
  ];
  for (const lesson of report.lessons) {
    lines.push(
      `lesson: ${lesson.id} date=${lesson.date} ageDays=${showField(lesson.ageDays)} proseOnly=${lesson.proseOnly ? "yes" : "no"}`
    );
  }
  if (report.verdict === "RED") {
    lines.push(
      `::warning::lesson-ledger-freshness verdict RED freshness=${report.freshness} debtRatchet=${report.debtRatchet}`
    );
  } else if (report.verdict === "UNKNOWN") {
    lines.push(
      `::warning::lesson-ledger-freshness cannot evaluate freshness=${report.freshness} debtRatchet=${report.debtRatchet}`
    );
  }
  return lines.join("\n") + "\n";
}

function missingPath(reason) {
  return { ok: false, reason, lessons: [], text: "" };
}

function parseFile(path, marker, missingReason) {
  if (!path) return missingPath(missingReason);
  const read = readText(path);
  if (!read.ok) {
    return missingPath(read.code === "ENOENT" ? missingReason : "ledger-unreadable");
  }
  const parsed = parseLedger(read.text, marker);
  if (!parsed.ok) return { ok: false, reason: parsed.reason, lessons: [], text: read.text };
  return parsed;
}

function resolveRef(root, requested) {
  if (requested) {
    const verified = git(root, ["rev-parse", "--verify", "--quiet", `${requested}^{commit}`]);
    return verified.ok ? requested : null;
  }
  for (const candidate of ["origin/main", "main"]) {
    const verified = git(root, ["rev-parse", "--verify", "--quiet", `${candidate}^{commit}`]);
    if (verified.ok) return candidate;
  }
  return null;
}

function gitPathMissing(result) {
  const blob = `${result.stderr}\n${result.stdout}`;
  return /does not exist|exists on disk, but not in|Path .* exists on disk/i.test(blob);
}

function loadGitSnapshot(root, ref, lessonsRel, windowStartMs) {
  const shallow = git(root, ["rev-parse", "--is-shallow-repository"]);
  if (!shallow.ok) return { activity: { available: false, reason: "activity-unavailable", merges: [] }, priorText: null };
  if (shallow.stdout.trim() === "true") { // MUTATION_SHALLOW
    return { activity: { available: false, reason: "shallow-history", merges: [] }, priorText: null };
  }
  const before = git(root, ["rev-list", "-1", `--before=${new Date(windowStartMs).toISOString()}`, ref]);
  if (!before.ok) return { activity: { available: false, reason: "activity-unavailable", merges: [] }, priorText: null };
  const beforeSha = before.stdout.trim();
  const roots = git(root, ["rev-list", "--max-parents=0", ref]);
  if (!roots.ok) return { activity: { available: false, reason: "activity-unavailable", merges: [] }, priorText: null };
  const rootShas = roots.stdout.trim().split("\n").filter(Boolean);
  if (rootShas.length === 0) {
    return { activity: { available: false, reason: "activity-unavailable", merges: [] }, priorText: null };
  }
  let priorText = "";
  if (!beforeSha) {
    for (const rootSha of rootShas) {
      const dated = git(root, ["log", "-1", "--format=%cI", rootSha]);
      if (!dated.ok) return { activity: { available: false, reason: "activity-unavailable", merges: [] }, priorText: null };
      const stamp = Date.parse(dated.stdout.trim());
      if (Number.isNaN(stamp) || stamp < windowStartMs) {
        return { activity: { available: false, reason: "activity-unavailable", merges: [] }, priorText: null };
      }
    }
    priorText = "";
  } else {
    const shown = git(root, ["show", `${beforeSha}:${lessonsRel}`]);
    if (!shown.ok) {
      if (!gitPathMissing(shown)) {
        return { activity: { available: false, reason: "prior-ledger-unreadable", merges: [] }, priorText: null };
      }
      priorText = "";
    } else {
      priorText = shown.stdout;
    }
  }
  const log = git(root, ["log", ref, "--format=%H%x09%cI"]);
  if (!log.ok) return { activity: { available: false, reason: "activity-unavailable", merges: [] }, priorText: null };
  const merges = [];
  for (const line of log.stdout.split("\n")) {
    if (!line) continue;
    const tab = line.indexOf("\t");
    if (tab < 1) return { activity: { available: false, reason: "activity-unparseable", merges: [] }, priorText: null };
    const sha = line.slice(0, tab);
    const committedAt = line.slice(tab + 1).trim();
    if (!/^[0-9a-f]{40}$/.test(sha) || Number.isNaN(Date.parse(committedAt))) {
      return { activity: { available: false, reason: "activity-unparseable", merges: [] }, priorText: null };
    }
    merges.push({ sha, committedAt });
  }
  return { activity: { available: true, reason: "ok", merges }, priorText };
}

function loadCommittedBaseline(root, rel, ref, explicitPath) {
  if (explicitPath) {
    const loaded = loadBaseline(explicitPath);
    if (!loaded.ok) return { checked: true, ok: false, absent: false, reason: loaded.reason, state: "unreadable" };
    return { checked: true, ok: true, absent: false, ...loaded, state: "compared" };
  }
  if (!ref) return { checked: false, ok: true, absent: true, state: "not-checked" };
  const shown = git(root, ["show", `${ref}:${rel}`]);
  if (!shown.ok) {
    if (gitPathMissing(shown)) return { checked: true, ok: true, absent: true, state: "absent" };
    return { checked: true, ok: false, absent: false, reason: "committed-baseline-unreadable", state: "unreadable" };
  }
  const tempNote = shown.stdout;
  let parsed;
  try {
    parsed = JSON.parse(tempNote);
  } catch {
    return { checked: true, ok: false, absent: false, reason: "baseline-malformed", state: "unreadable" };
  }
  if (!parsed || parsed.schema !== SCHEMA) {
    return { checked: true, ok: false, absent: false, reason: "baseline-malformed", state: "unreadable" };
  }
  if (!Number.isInteger(parsed.windowDays) || parsed.windowDays < 1) {
    return { checked: true, ok: false, absent: false, reason: "baseline-malformed", state: "unreadable" };
  }
  if (!Number.isInteger(parsed.proseOnlyCount) || parsed.proseOnlyCount < 0) {
    return { checked: true, ok: false, absent: false, reason: "baseline-malformed", state: "unreadable" };
  }
  return {
    checked: true,
    ok: true,
    absent: false,
    windowDays: parsed.windowDays,
    proseOnlyCount: parsed.proseOnlyCount,
    state: "compared",
  };
}

function insideRoot(root, path) {
  const rel = relative(root, path);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

function assemble(options) {
  const nowMs = options.nowMs;
  const baseline = options.baseline;
  const windowDays = options.windowDaysOverride || (baseline.ok ? baseline.windowDays : null);
  const windowStartMs = windowDays ? nowMs - windowDays * MS_DAY : null;
  const activity = options.activity;
  const prior = options.prior || missingPath("prior-ledger-missing");
  const current = options.current || missingPath("ledger-missing");
  let freshness;
  if (!windowStartMs) {
    freshness = freshnessUnknown(baseline.ok ? "window-invalid" : baseline.reason);
  } else if (!activity) {
    freshness = freshnessUnknown("activity-unavailable");
  } else {
    freshness = decideFreshness({ activity, prior, current, windowStartMs, nowMs });
  }
  let debtCount = null;
  let lessons = [];
  if (current.ok) {
    lessons = current.lessons.map((lesson) => ({
      ...lesson,
      ageDays: ageDays(lesson.date, nowMs),
    }));
    lessons.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    debtCount = lessons.filter((lesson) => lesson.proseOnly).length;
  }
  const debt = debtDecision(current.ok ? debtCount : null, baseline, options.committed);
  if (!current.ok) {
    debt.debtRatchet = "unknown";
    debt.debtReason = current.reason || "ledger-unreadable";
  }
  const freshnessKnown = freshness.freshness === "healthy" || freshness.freshness === "stale";
  const debtKnown = debt.debtRatchet === "ok" || debt.debtRatchet === "over";
  const complete = freshnessKnown && debtKnown && Boolean(windowDays);
  let verdict = "UNKNOWN";
  if (complete && (freshness.freshness === "stale" || debt.debtRatchet === "over")) verdict = "RED";
  else if (complete) verdict = "GREEN";
  const committedBaseline = options.committed && options.committed.state ? options.committed.state : "not-checked";
  return {
    verdict,
    freshness: freshness.freshness,
    reason: freshness.reason,
    observation: complete ? "complete" : "incomplete",
    windowDays,
    now: new Date(nowMs).toISOString(),
    windowStart: windowStartMs ? new Date(windowStartMs).toISOString() : null,
    mergesInWindow: freshness.mergesInWindow,
    newHeadings: freshness.newHeadings,
    cosmeticOnly: freshness.cosmeticOnly,
    debtCount: current.ok ? debtCount : null,
    debtBaseline: debt.debtBaseline,
    debtRatchet: debt.debtRatchet,
    debtReason: debt.debtReason,
    committedBaseline,
    lessons: current.ok ? lessons : [],
  };
}

function positiveInt(raw, flag) {
  if (!/^[1-9][0-9]*$/.test(raw)) dieUsage(`${flag} must be a positive integer`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) dieUsage(`${flag} must be a positive integer`);
  return value;
}

function main(argv) {
  const opt = parseFlags(argv, {
    prefix: "lesson-ledger-freshness: ",
    flags: {
      "--help": { key: "help", type: "boolean" },
      "--annotate": { key: "annotate", type: "boolean" },
      "--fixture": { key: "fixture" },
      "--root": { key: "root" },
      "--now": { key: "now" },
      "--baseline": { key: "baseline" },
      "--committed-baseline": { key: "committedBaseline" },
      "--window-days": { key: "windowDays" },
      "--activity-ref": { key: "activityRef" },
      "--lessons": { key: "lessons" },
      "--prior-lessons": { key: "priorLessons" },
      "--activity": { key: "activity" },
    },
  });
  if (opt.help) {
    help();
    return 0;
  }
  const explicit = Boolean(opt.lessons || opt.activity || opt.priorLessons);
  if (opt.fixture && explicit) dieUsage("pass --fixture or --lessons/--activity, not both");
  if (opt.fixture && opt.root) dieUsage("pass --fixture or --root, not both");
  if (explicit && (!opt.lessons || !opt.activity)) {
    dieUsage("explicit mode requires both --lessons and --activity");
  }
  if (!opt.fixture && !explicit && opt.priorLessons) dieUsage("--prior-lessons is only valid with --lessons");
  if ((opt.fixture || explicit) && opt.activityRef) dieUsage("--activity-ref is only valid in live --root mode");
  const windowDaysOverride = opt.windowDays ? positiveInt(opt.windowDays, "--window-days") : null;
  let nowMs;
  if (opt.now) {
    nowMs = Date.parse(opt.now);
    if (Number.isNaN(nowMs)) dieUsage("--now must be an ISO timestamp");
  } else if (opt.fixture || explicit) {
    dieUsage("--now is required with --fixture or --lessons");
  } else {
    nowMs = Date.now();
  }

  const live = !opt.fixture && !explicit;
  const root = resolve(opt.root || (live ? process.cwd() : process.cwd()));
  const baselinePath = opt.baseline
    ? resolve(opt.baseline)
    : opt.fixture
      ? join(resolve(opt.fixture), "baseline.json")
      : join(root, DEFAULT_BASELINE_REL);
  let baseline = loadBaseline(baselinePath);
  if (windowDaysOverride && baseline.ok) baseline = { ...baseline, windowDays: windowDaysOverride };
  const marker = baseline.ok ? baseline.statusMarker : "no sensor yet";
  const windowDays = baseline.ok ? baseline.windowDays : windowDaysOverride;
  const windowStartMs = windowDays ? nowMs - windowDays * MS_DAY : nowMs;

  let activity;
  let prior;
  let current;
  let committed;
  if (opt.fixture) {
    const dir = resolve(opt.fixture);
    activity = loadActivity(join(dir, "activity.json"));
    current = parseFile(join(dir, "lessons.md"), marker, "ledger-missing");
    prior = parseFile(join(dir, "prior-lessons.md"), marker, "prior-ledger-missing");
    committed = loadCommittedBaseline(root, DEFAULT_BASELINE_REL, null, opt.committedBaseline);
  } else if (explicit) {
    activity = loadActivity(resolve(opt.activity));
    current = parseFile(resolve(opt.lessons), marker, "ledger-missing");
    prior = opt.priorLessons
      ? parseFile(resolve(opt.priorLessons), marker, "prior-ledger-missing")
      : missingPath("prior-ledger-missing");
    committed = loadCommittedBaseline(root, DEFAULT_BASELINE_REL, null, opt.committedBaseline);
  } else {
    if (!existsSync(root) || !statSync(root).isDirectory()) dieUsage("--root is not a directory");
    const lessonsPath = join(root, DEFAULT_LESSONS_REL);
    const ref = resolveRef(root, opt.activityRef || null);
    if (!ref) {
      activity = { available: false, reason: "activity-ref-missing", merges: [] };
      prior = missingPath("prior-ledger-missing");
    } else if (!windowDays) {
      activity = { available: false, reason: baseline.reason || "baseline-missing", merges: [] };
      prior = missingPath("prior-ledger-missing");
    } else {
      const snap = loadGitSnapshot(root, ref, DEFAULT_LESSONS_REL, windowStartMs);
      activity = snap.activity;
      if (snap.priorText === null) prior = missingPath("prior-ledger-missing");
      else prior = parseLedger(snap.priorText, marker);
    }
    current = parseFile(lessonsPath, marker, "ledger-missing");
    const baselineRel = opt.baseline && insideRoot(root, resolve(opt.baseline))
      ? relative(root, resolve(opt.baseline))
      : DEFAULT_BASELINE_REL;
    committed = loadCommittedBaseline(root, baselineRel, ref, opt.committedBaseline);
  }

  const report = assemble({
    nowMs,
    baseline,
    windowDaysOverride,
    activity,
    prior,
    current,
    committed,
  });
  const text = formatReport(report, Boolean(opt.annotate));
  process.stdout.write(text);
  return report.verdict === "UNKNOWN" ? 1 : 0;
}

if (isMain()) {
  process.exit(main(process.argv.slice(2)));
}
