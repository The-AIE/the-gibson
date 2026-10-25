#!/usr/bin/env node
/**
 * drain-ratchet.mjs — backlog drain rate as a protected measure (#559).
 *
 * WHAT IT DOES
 *   Over rolling 14-day windows computes drain rate = (PRs merged + PRs closed
 *   unmerged + issues closed) / (PRs opened + issues opened), open-to-merge
 *   median/p90, and the count of open PRs older than 7 days. The baseline is the
 *   same measure over the 28 days before each window. A BREACH is every one of
 *   the last N windows (default 2) below its baseline by more than the margin,
 *   with an absolute floor: a window opening fewer than floorOpened items cannot
 *   breach. On a breach it names the process changes (merged PRs touching gates,
 *   sensors, workflows, AGENTS.md, review/size rules; issues labelled
 *   freeze/stop or titled FREEZE (case-sensitive)) inside the drop window as suspects and plans
 *   ONE recovery issue: owner, 7-day deadline, default action (revert the suspect
 *   or lift the stop). The next run closes that issue when the breach clears.
 *
 * WHY
 *   The 2026-10-08 freeze parked six PRs for 1 to 5 weeks and all merged in one
 *   day once it lifted; nothing measured the slowdown or forced a recovery.
 *
 * RISKS
 *   config.mode "report-only" (the shipped value) never opens, edits or closes an
 *   issue. "enforce" does, through --open-issue. Reads need network + a token in
 *   live mode. "PRs closed" counts every unmerged close: GitHub records no
 *   close-reason enum yet (#556). A bad or incomplete observation exits 1 and
 *   never reports "no breach". Suspects are correlation, not proof.
 *
 * USAGE
 *   node scripts/drain-ratchet.mjs --repo OWNER/NAME [--now ISO] [--open-issue]
 *        [--json-out FILE] [--md-out FILE] [--config FILE]
 *   node scripts/drain-ratchet.mjs --fixture DIR --now ISO [--open-issue --actions-out FILE]
 *     DIR holds pulls.json and issues.json (REST shapes; each PR has files: [paths]).
 *   node scripts/drain-ratchet.mjs --help
 *
 * EXIT
 *   0  report produced (breach or not; this sensor never blocks a PR)
 *   1  INCOMPLETE: unreadable or malformed data, config, or API failure
 *   2  usage / unknown flag
 */

import { readFileSync, existsSync, realpathSync, writeFileSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { parseFlags, dieUsage } from "./lib/args.mjs";

export const DEFAULT_CONFIG_REL = "config/drain-ratchet.v1.json";
export const TITLE_PREFIX = "Drain ratchet breach: ";
export const MARKER = "<!-- drain-ratchet -->";
const DAY = 86_400_000;
const HOUR = 3_600_000;
const PAGE = 100;
const PAGE_CAP = 60;
// GitHub serves at most 3000 files per PR (30 pages of 100).
const FILES_PAGE_CAP = 30;
const CONFIG_KEYS = [
  "mode", "windowDays", "baselineDays", "marginPct", "consecutiveWindows",
  "floorOpened", "stalePrDays", "deadlineDays", "maxSuspects", "stopLabels",
  "stopTitlePattern", "processPaths",
];

export class Incomplete extends Error {}

/** Sensor-owned only when BOTH the title prefix and the hidden marker are present. */
export function isRatchetIssue(x) {
  return x.title.startsWith(TITLE_PREFIX) && x.body.includes(MARKER);
}

function fail(msg) {
  throw new Incomplete(msg);
}

function help() {
  const src = readFileSync(fileURLToPath(import.meta.url), "utf8");
  const m = src.match(/\/\*\*([\s\S]*?)\*\//);
  console.log((m ? m[1] : "").replace(/^ \* ?/gm, "").trim());
}

// ---------------------------------------------------------------- validation

function ts(v, what) {
  if (typeof v !== "string" || Number.isNaN(Date.parse(v))) {
    fail(`${what}: not an ISO timestamp: ${JSON.stringify(v)}`);
  }
  return Date.parse(v);
}
function tsOrNull(v, what) {
  return v === null || v === undefined ? null : ts(v, what);
}

export function validateConfig(c) {
  if (c === null || typeof c !== "object" || Array.isArray(c)) fail("config: not an object");
  for (const k of CONFIG_KEYS) if (!(k in c)) fail(`config: missing key ${k}`);
  if (c.mode !== "report-only" && c.mode !== "enforce") fail(`config.mode: must be report-only|enforce`);
  for (const k of ["windowDays", "baselineDays", "consecutiveWindows", "stalePrDays", "deadlineDays", "maxSuspects"]) {
    if (!Number.isInteger(c[k]) || c[k] < 1) fail(`config.${k}: positive integer required`);
  }
  if (!Number.isInteger(c.floorOpened) || c.floorOpened < 0) fail("config.floorOpened: integer >= 0 required");
  if (typeof c.marginPct !== "number" || c.marginPct < 0 || c.marginPct >= 100) fail("config.marginPct: number in [0,100) required");
  if (!Array.isArray(c.stopLabels) || c.stopLabels.some((x) => typeof x !== "string")) fail("config.stopLabels: string[] required");
  try {
    new RegExp(c.stopTitlePattern);
    if (!Array.isArray(c.processPaths)) fail("config.processPaths: array required");
    for (const p of c.processPaths) {
      if (!p || typeof p.kind !== "string") fail("config.processPaths: kind required");
      new RegExp(p.pattern);
    }
  } catch (e) {
    if (e instanceof Incomplete) throw e;
    fail(`config: bad regular expression: ${e.message}`);
  }
  return c;
}

function normalizePulls(raw, lookbackStart) {
  if (!Array.isArray(raw)) fail("pulls: not an array");
  return raw.map((p, i) => {
    const w = `pulls[${i}]`;
    if (!p || typeof p !== "object" || !Number.isInteger(p.number)) fail(`${w}: number required`);
    const n = `PR #${p.number}`;
    if (typeof p.title !== "string") fail(`${n}: title required`);
    if (p.state !== "open" && p.state !== "closed") fail(`${n}: state must be open|closed`);
    if (!p.user || typeof p.user.login !== "string") fail(`${n}: user.login required`);
    const created = ts(p.created_at, `${n} created_at`);
    const closed = tsOrNull(p.closed_at, `${n} closed_at`);
    const merged = tsOrNull(p.merged_at, `${n} merged_at`);
    if (p.state === "closed" && closed === null) fail(`${n}: closed without closed_at`);
    if (merged !== null && closed === null) fail(`${n}: merged without closed_at`);
    if (p.files !== undefined && (!Array.isArray(p.files) || p.files.some((f) => typeof f !== "string"))) {
      fail(`${n}: files must be string[]`);
    }
    if (merged !== null && merged >= lookbackStart && !Array.isArray(p.files)) fail(`${n}: merged in the lookback but files missing`);
    return {
      number: p.number, title: p.title, open: p.state === "open", draft: Boolean(p.draft),
      created, closed, merged, author: p.user.login, url: p.html_url ?? null, files: p.files ?? [],
    };
  });
}

function normalizeIssues(raw) {
  if (!Array.isArray(raw)) fail("issues: not an array");
  return raw.map((it, i) => {
    const w = `issues[${i}]`;
    if (!it || typeof it !== "object" || !Number.isInteger(it.number)) fail(`${w}: number required`);
    const n = `issue #${it.number}`;
    if (it.pull_request) fail(`${n}: a pull request in issues.json (filter them out)`);
    if (typeof it.title !== "string") fail(`${n}: title required`);
    if (it.state !== "open" && it.state !== "closed") fail(`${n}: state must be open|closed`);
    if (!it.user || typeof it.user.login !== "string") fail(`${n}: user.login required`);
    const created = ts(it.created_at, `${n} created_at`);
    const closed = tsOrNull(it.closed_at, `${n} closed_at`);
    if (it.state === "closed" && closed === null) fail(`${n}: closed without closed_at`);
    const labels = it.labels === undefined ? [] : it.labels;
    if (!Array.isArray(labels)) fail(`${n}: labels must be an array`);
    return {
      number: it.number, title: it.title, open: it.state === "open", created, closed,
      author: it.user.login, url: it.html_url ?? null,
      labels: labels.map((l) => String(typeof l === "string" ? l : l?.name ?? "").toLowerCase()),
      body: typeof it.body === "string" ? it.body : "",
    };
  });
}

// ------------------------------------------------------------------ analysis

const iso = (ms) => new Date(ms).toISOString();
const round = (x, d = 3) => (x === null ? null : Math.round(x * 10 ** d) / 10 ** d);

function percentile(sorted, p) {
  if (sorted.length === 0) return null;
  return sorted[Math.max(0, Math.ceil(p * sorted.length) - 1)];
}

export function measure(pulls, issues, start, end) {
  const inWin = (t) => t !== null && t > start && t <= end;
  const merged = pulls.filter((p) => inWin(p.merged));
  const prClosed = pulls.filter((p) => p.merged === null && inWin(p.closed));
  const issClosed = issues.filter((x) => inWin(x.closed));
  const prOpened = pulls.filter((p) => inWin(p.created)).length;
  const issOpened = issues.filter((x) => inWin(x.created)).length;
  const opened = prOpened + issOpened;
  const drained = merged.length + prClosed.length + issClosed.length;
  const hours = merged.map((p) => (p.merged - p.created) / HOUR).sort((a, b) => a - b);
  return {
    start: iso(start), end: iso(end), opened, prOpened, issuesOpened: issOpened,
    prMerged: merged.length, prClosedUnmerged: prClosed.length, issuesClosed: issClosed.length,
    drained, rate: opened > 0 ? round(drained / opened) : null,
    openToMergeHours: { median: round(percentile(hours, 0.5), 1), p90: round(percentile(hours, 0.9), 1) },
  };
}

function isStop(it, cfg) {
  const re = new RegExp(cfg.stopTitlePattern);
  return it.labels.some((l) => cfg.stopLabels.includes(l)) || re.test(it.title);
}

export function analyze({ pulls, issues, config, now }) {
  const cfg = config;
  const win = cfg.windowDays * DAY;
  const base = cfg.baselineDays * DAY;
  const lookbackStart = now - (cfg.consecutiveWindows * win + base);
  const own = isRatchetIssue;
  const ratchetIssues = issues.filter(own);
  const workIssues = issues.filter((x) => !own(x));

  const windows = [];
  for (let k = 0; k < cfg.consecutiveWindows; k++) {
    const end = now - k * win;
    const start = end - win;
    const cur = measure(pulls, workIssues, start, end);
    const baseline = measure(pulls, workIssues, start - base, start);
    const floorOk = cur.opened >= cfg.floorOpened && baseline.opened >= cfg.floorOpened;
    const below = cur.rate !== null && baseline.rate !== null && cur.rate < baseline.rate * (1 - cfg.marginPct / 100);
    let status = "ok";
    if (cur.rate === null || baseline.rate === null) status = "suppressed-no-data";
    else if (!floorOk) status = "suppressed-floor";
    else if (below) status = "below";
    windows.push({ index: k, ...cur, baseline, belowIgnoringFloor: below, status });
  }
  const breach = windows.every((w) => w.status === "below");
  const wouldBreachWithoutFloor = windows.every((w) => w.belowIgnoringFloor);

  const stale = pulls.filter((p) => p.created <= now && (p.closed === null || p.closed > now) && now - p.created > cfg.stalePrDays * DAY);
  const openPrAge = {
    olderThanDays: cfg.stalePrDays, count: stale.length,
    oldest: stale.sort((a, b) => a.created - b.created).slice(0, 5)
      .map((p) => ({ number: p.number, ageDays: round((now - p.created) / DAY, 1), draft: p.draft })),
  };

  const rules = cfg.processPaths.map((r) => ({ kind: r.kind, re: new RegExp(r.pattern) }));
  const changes = [];
  for (const p of pulls) {
    if (p.merged === null || p.merged < lookbackStart || p.merged > now) continue;
    const kinds = new Set();
    for (const f of p.files) for (const r of rules) if (r.re.test(f)) kinds.add(r.kind);
    if (kinds.size === 0) continue;
    changes.push({
      type: "pr", number: p.number, title: p.title, url: p.url, author: p.author,
      date: iso(p.merged), kinds: [...kinds].sort(),
    });
  }
  for (const it of workIssues) {
    if (!isStop(it, cfg) || it.created > now) continue;
    changes.push({
      type: "stop", number: it.number, title: it.title, url: it.url, author: it.author,
      date: iso(it.created), kinds: ["stop"], lifted: it.closed === null ? null : iso(it.closed),
      open: it.closed === null || it.closed > now,
    });
  }
  changes.sort((a, b) => Date.parse(b.date) - Date.parse(a.date));

  const dropStart = windows[windows.length - 1].start;
  const suspects = breach
    ? changes.filter((c) => (c.type === "pr" ? Date.parse(c.date) >= Date.parse(dropStart)
      : c.open || Date.parse(c.lifted) > Date.parse(dropStart))).slice(0, cfg.maxSuspects)
    : [];

  const deadline = iso(now + cfg.deadlineDays * DAY).slice(0, 10);
  let recovery = null;
  if (breach) {
    const openStop = suspects.find((s) => s.type === "stop" && s.open);
    const recentPr = suspects.find((s) => s.type === "pr");
    const first = suspects[0] ?? null;
    recovery = {
      owner: first ? first.author : null,
      deadline,
      defaultAction: openStop
        ? `Lift stop #${openStop.number} and run a drain day: the parked queue is the first day's work after it lifts.`
        : recentPr ? `Revert PR #${recentPr.number} (${recentPr.title}) unless the drain rate has recovered.`
          : "No suspect found: the owner names the cause or the next run re-checks.",
    };
  }

  return {
    schema: "gibson.drain-ratchet-report/v1", mode: cfg.mode, asOf: iso(now),
    breach, wouldBreachWithoutFloor, windows, openPrAge,
    thresholds: { marginPct: cfg.marginPct, consecutiveWindows: cfg.consecutiveWindows, floorOpened: cfg.floorOpened },
    processChanges: changes, suspects, recovery,
    openRatchetIssues: ratchetIssues.filter((x) => x.open).sort((a, b) => a.number - b.number)
      .map((x) => ({ number: x.number, title: x.title, body: x.body })),
  };
}

// ------------------------------------------------------------------- actions

function issueBody(report, deadline, since) {
  const r = report.recovery;
  const lines = [
    MARKER, "",
    `Backlog drain rate is below its 28-day baseline by more than ${report.thresholds.marginPct}% for ${report.thresholds.consecutiveWindows} consecutive windows (#559).`,
    "", `- Breach first seen: ${since}`, `- Recovery owner: @${r.owner ?? "unassigned"}`,
    `- Recovery deadline: ${deadline}`, `- Default action if the deadline passes: ${r.defaultAction}`, "",
    "| Window | Opened | Drained | Rate | Baseline rate |", "|---|---|---|---|---|",
    ...report.windows.map((w) => `| ${w.start.slice(0, 10)} to ${w.end.slice(0, 10)} | ${w.opened} | ${w.drained} | ${w.rate} | ${w.baseline.rate} |`),
    "", "Suspects (process changes inside the drop window, newest first):",
    ...(report.suspects.length ? report.suspects.map((s) => `- ${s.type === "stop" ? "stop" : "PR"} #${s.number} ${s.title} (${s.kinds.join(", ")}, ${s.date.slice(0, 10)}, @${s.author})`) : ["- none found"]),
    "", "This issue closes itself on the first run where the breach clears.",
  ];
  return lines.join("\n");
}

export function planActions(report) {
  const existing = report.openRatchetIssues;
  const day = report.asOf.slice(0, 10);
  const ops = [];
  if (report.breach) {
    if (existing.length === 0) {
      ops.push({ op: "create", title: `${TITLE_PREFIX}${day}`, body: issueBody(report, report.recovery.deadline, day) });
    } else {
      const keep = existing[0];
      const dl = keep.body.match(/Recovery deadline: (\d{4}-\d{2}-\d{2})/);
      const since = keep.body.match(/Breach first seen: (\d{4}-\d{2}-\d{2})/);
      ops.push({ op: "update", number: keep.number, body: issueBody(report, dl ? dl[1] : report.recovery.deadline, since ? since[1] : day) });
      for (const x of existing.slice(1)) ops.push({ op: "close", number: x.number, comment: `Duplicate of #${keep.number}: exactly one drain-ratchet issue stays open.` });
    }
  } else {
    for (const x of existing) ops.push({ op: "close", number: x.number, comment: `Breach condition no longer met as of ${day}: the drain rate is not below its baseline by more than ${report.thresholds.marginPct}% in every one of the last ${report.thresholds.consecutiveWindows} windows (latest ${report.windows[0].rate} vs baseline ${report.windows[0].baseline.rate}, ${report.windows[0].status}). Closing; the next breach opens a new issue.` });
  }
  return ops;
}

// ------------------------------------------------------------------- reports

export function renderMarkdown(r, applied) {
  const out = [`### Drain ratchet — ${r.asOf.slice(0, 10)} (${r.mode})`, ""];
  out.push(r.breach ? "**BREACH**: drain rate is below baseline in every one of the last windows." : r.wouldBreachWithoutFloor
    ? "No breach: the floor suppressed it (too few items opened)." : "No breach.", "");
  out.push("| Window | Opened | Drained | Rate | Baseline | Open→merge median / p90 (h) | Status |", "|---|---|---|---|---|---|---|");
  for (const w of r.windows) {
    out.push(`| ${w.start.slice(0, 10)} to ${w.end.slice(0, 10)} | ${w.opened} | ${w.drained} (${w.prMerged} merged, ${w.prClosedUnmerged} PR closed, ${w.issuesClosed} issues closed) | ${w.rate} | ${w.baseline.rate} | ${w.openToMergeHours.median} / ${w.openToMergeHours.p90} | ${w.status} |`);
  }
  out.push("", `Open PRs older than ${r.openPrAge.olderThanDays} days: ${r.openPrAge.count}${r.openPrAge.oldest.length ? ` (oldest: ${r.openPrAge.oldest.map((p) => `#${p.number} ${p.ageDays}d`).join(", ")})` : ""}`);
  if (r.breach) {
    out.push("", `Recovery owner: @${r.recovery.owner ?? "unassigned"}; deadline ${r.recovery.deadline}`, `Default action: ${r.recovery.defaultAction}`, "", "Suspects:");
    out.push(...(r.suspects.length ? r.suspects.map((s) => `- ${s.type} #${s.number} ${s.title} [${s.kinds.join(", ")}] ${s.date.slice(0, 10)} @${s.author}`) : ["- none"]));
  }
  out.push("", `Process changes logged in the lookback: ${r.processChanges.length}`);
  const verb = r.mode === "enforce" ? (applied.length ? "applied" : "none needed") : "report-only: nothing opened";
  out.push(`Issue actions (${verb}): ${r.plannedActions.length ? r.plannedActions.map((a) => `${a.op}${a.number ? ` #${a.number}` : ""}`).join(", ") : "none"}`, "");
  return out.join("\n");
}

// ------------------------------------------------------------------- GitHub IO

function gh(args, input) {
  const bin = process.env.DRAIN_RATCHET_GH || "gh";
  const label = args[args.length - 1];
  let last = "";
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = spawnSync(bin, ["api", ...args], { input, encoding: "utf8", maxBuffer: 256 * 1024 * 1024, timeout: 120_000 });
    if (!r.error && r.status === 0) {
      try {
        return JSON.parse(r.stdout);
      } catch {
        return fail(`gh api ${label}: response is not JSON`);
      }
    }
    last = (r.error?.message ?? r.stderr ?? "").trim().slice(0, 300);
    // Only reads are retried: a write that failed midway must not be repeated.
    if (input !== undefined) break;
  }
  return fail(`gh api ${label} failed: ${last}`);
}

function pagedUntil(path, start, key) {
  const all = [];
  for (let page = 1; ; page++) {
    if (page > PAGE_CAP) fail(`${path}: more than ${PAGE_CAP} pages`);
    const sep = path.includes("?") ? "&" : "?";
    const rows = gh([`${path}${sep}per_page=${PAGE}&page=${page}`]);
    if (!Array.isArray(rows)) fail(`${path}: expected an array`);
    all.push(...rows);
    if (rows.length < PAGE) return all;
    if (key && rows.every((x) => Date.parse(x[key]) < start)) return all;
  }
}

function loadLive(repo, lookbackStart) {
  const since = iso(lookbackStart);
  const pulls = pagedUntil(`repos/${repo}/pulls?state=all&sort=updated&direction=desc`, lookbackStart, "updated_at");
  const sinceIssues = pagedUntil(`repos/${repo}/issues?state=all&sort=updated&direction=desc&since=${since}`, lookbackStart, "updated_at");
  const openIssues = pagedUntil(`repos/${repo}/issues?state=open`, 0, null);
  // Open PRs untouched for the whole lookback never reach the updated-sorted list above.
  for (const p of pagedUntil(`repos/${repo}/pulls?state=open`, 0, null)) {
    if (!pulls.some((x) => x.number === p.number)) pulls.push(p);
  }
  const byNumber = new Map();
  for (const x of [...sinceIssues, ...openIssues]) if (!x.pull_request) byNumber.set(x.number, x);
  for (const p of pulls) {
    if (!p.merged_at || Date.parse(p.merged_at) < lookbackStart) continue;
    const files = [];
    const cap = Number(process.env.DRAIN_RATCHET_FILES_PAGE_CAP) || FILES_PAGE_CAP;
    for (let page = 1; ; page++) {
      if (page > cap) fail(`PR #${p.number}: file list not complete after ${cap} full pages`);
      const rows = gh([`repos/${repo}/pulls/${p.number}/files?per_page=${PAGE}&page=${page}`]);
      if (!Array.isArray(rows)) fail(`PR #${p.number} files: expected an array`);
      files.push(...rows.map((f) => f.filename));
      if (rows.length < PAGE) break;
    }
    p.files = files;
  }
  return { pulls, issues: [...byNumber.values()] };
}

function loadFixture(dir) {
  const read = (name) => {
    const f = join(dir, name);
    if (!existsSync(f)) fail(`fixture: ${name} missing in ${dir}`);
    try {
      return JSON.parse(readFileSync(f, "utf8"));
    } catch (e) {
      return fail(`fixture: ${name} is not valid JSON (${e.message})`);
    }
  };
  return { pulls: read("pulls.json"), issues: read("issues.json") };
}

function applyLive(repo, ops) {
  const done = [];
  for (const o of ops) {
    if (o.op === "create") {
      const r = gh(["--method", "POST", `repos/${repo}/issues`, "--input", "-"], JSON.stringify({ title: o.title, body: o.body }));
      done.push({ ...o, number: r.number });
    } else if (o.op === "update") {
      gh(["--method", "PATCH", `repos/${repo}/issues/${o.number}`, "--input", "-"], JSON.stringify({ body: o.body }));
      done.push(o);
    } else {
      gh(["--method", "POST", `repos/${repo}/issues/${o.number}/comments`, "--input", "-"], JSON.stringify({ body: o.comment }));
      gh(["--method", "PATCH", `repos/${repo}/issues/${o.number}`, "--input", "-"], JSON.stringify({ state: "closed", state_reason: "completed" }));
      done.push(o);
    }
  }
  return done;
}

// ----------------------------------------------------------------------- main

function isMain() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return resolve(entry) === fileURLToPath(import.meta.url);
  }
}

export function main(argv) {
  const opt = parseFlags(argv, {
    prefix: "drain-ratchet: ",
    flags: {
      "--help": { key: "help", type: "boolean" },
      "-h": { key: "help", type: "boolean" },
      "--repo": { key: "repo" },
      "--fixture": { key: "fixture" },
      "--now": { key: "now" },
      "--config": { key: "config" },
      "--open-issue": { key: "openIssue", type: "boolean" },
      "--json-out": { key: "jsonOut" },
      "--md-out": { key: "mdOut" },
      "--actions-out": { key: "actionsOut" },
    },
  });
  if (opt.help) {
    help();
    return 0;
  }
  if (Boolean(opt.repo) === Boolean(opt.fixture)) dieUsage("drain-ratchet: exactly one of --repo or --fixture is required");
  if (opt.fixture && !opt.now) dieUsage("drain-ratchet: --fixture requires --now");
  try {
    const cfgPath = opt.config ?? resolve(dirname(fileURLToPath(import.meta.url)), "..", DEFAULT_CONFIG_REL);
    if (!existsSync(cfgPath)) fail(`config not found: ${cfgPath}`);
    let rawCfg;
    try {
      rawCfg = JSON.parse(readFileSync(cfgPath, "utf8"));
    } catch (e) {
      fail(`config is not valid JSON (${e.message})`);
    }
    const config = validateConfig(rawCfg);
    const now = opt.now ? ts(opt.now, "--now") : Date.now();
    const lookbackStart = now - (config.consecutiveWindows * config.windowDays + config.baselineDays) * DAY;
    const raw = opt.fixture ? loadFixture(opt.fixture) : loadLive(opt.repo, lookbackStart);
    const report = analyze({ pulls: normalizePulls(raw.pulls, lookbackStart), issues: normalizeIssues(raw.issues), config, now });
    report.plannedActions = planActions(report);
    let applied = [];
    if (opt.openIssue && config.mode === "enforce") {
      if (opt.fixture) {
        if (!opt.actionsOut) dieUsage("drain-ratchet: --open-issue with --fixture needs --actions-out FILE");
        applied = report.plannedActions;
        writeFileSync(opt.actionsOut, `${JSON.stringify(applied, null, 2)}\n`);
      } else {
        applied = applyLive(opt.repo, report.plannedActions);
      }
    }
    report.applied = applied;
    delete report.openRatchetIssues;
    if (opt.jsonOut) writeFileSync(opt.jsonOut, `${JSON.stringify(report, null, 2)}\n`);
    const md = renderMarkdown(report, applied);
    if (opt.mdOut) writeFileSync(opt.mdOut, `${md}\n`, { flag: "a" });
    console.log(md);
    return 0;
  } catch (e) {
    if (!(e instanceof Incomplete)) throw e;
    console.error(`drain-ratchet: INCOMPLETE: ${e.message}`);
    return 1;
  }
}

if (isMain()) process.exitCode = main(process.argv.slice(2));
