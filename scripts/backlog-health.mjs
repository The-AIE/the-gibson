#!/usr/bin/env node
/**
 * backlog-health.mjs — blocked-share classifier for the open issue queue (#309).
 *
 * WHAT IT DOES
 *   Loads every open issue (abortable GraphQL, or --fixture JSON), decides
 *   which ones are blocked, finds top blockers, and prints one verdict:
 *   INCOMPLETE, RED, YELLOW, or GREEN. A steady-state RED/YELLOW/GREEN exits
 *   0 so a daily workflow can report the colour without failing itself.
 *
 * WHY
 *   "Clear the blocker before decomposing behind it" was prose. When most of
 *   the queue carries dependency-blocked and the top blockers are quiet, this
 *   sensor turns red.
 *
 * RISKS
 *   Markdown parse of ## Dependencies only — work on a blocker that never
 *   references #N is invisible. --repo mode needs network + a token.
 *   Read-only; never mutates GitHub. The loader never calls process.exit.
 *
 * USAGE
 *   node scripts/backlog-health.mjs --fixture world.json --now ISO
 *   node scripts/backlog-health.mjs --graphql-stub stub.json --repo OWNER/NAME --now ISO
 *   node scripts/backlog-health.mjs --repo OWNER/NAME [--now ISO]
 *   node scripts/backlog-health.mjs --help
 *
 * EXIT
 *   0  RED / YELLOW / GREEN (complete observation)
 *   1  INCOMPLETE
 *   2  usage / unknown flag
 */

import { readFileSync, existsSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseFlags } from "./lib/args.mjs";

export const PAGE_SIZE = 100;
export const PAGE_CAP = 100;
export const DEFAULT_CONFIG_REL = "config/backlog-health.v1.json";
export const GRAPHQL_URL = "https://api.github.com/graphql";

/** Byte-identical to scripts/decompose-graph.mjs's blocked-by regex `.source`. */
export const DEPENDENCY_CITATION_RE_SOURCE =
  "(?:blocked\\s*by|depends\\s*on|requires|after)\\s*:?\\s*#?(\\d+)";

export const INCOMPLETE = Object.freeze({
  API_NON_SUCCESS: "API_NON_SUCCESS",
  TIMEOUT: "TIMEOUT",
  PAGE_CAP: "PAGE_CAP",
  GRAPHQL_ERRORS: "GRAPHQL_ERRORS",
  COUNT_MISMATCH: "COUNT_MISMATCH",
  HAS_NEXT_PAGE: "HAS_NEXT_PAGE",
  MISSING_LABEL: "MISSING_LABEL",
  UNRESOLVED_LOOKUP: "UNRESOLVED_LOOKUP",
});

const CONFIG_KEYS = [
  "blockedLabel",
  "blockedRatioMax",
  "blockerQuietDays",
  "minDependents",
  "requestTimeoutMs",
];

function help() {
  console.log(`backlog-health.mjs — blocked-share classifier for the open issue queue (#309)

WHAT IT DOES
  Measures the share of open issues that are blocked (configured label, or a
  ## Dependencies citation to a resolvable open issue) and whether any top
  blocker moved inside the quiet window. Prints INCOMPLETE, RED, YELLOW, or
  GREEN. First matching verdict wins.

WHY
  A queue that is mostly waiting on quiet blockers should turn red. Slice B
  publishes this colour; a steady-state RED must not fail the daily job.

RISKS
  Parses only ## Dependencies (identical regex to decompose-graph.mjs).
  Work on a blocker that never references #N is invisible. Read-only.
  Live mode needs GITHUB_TOKEN / GH_TOKEN and --repo. Loader never exits.

USAGE
  node scripts/backlog-health.mjs --fixture world.json --now ISO [--config FILE]
  node scripts/backlog-health.mjs --graphql-stub stub.json --repo OWNER/NAME --now ISO
  node scripts/backlog-health.mjs --repo OWNER/NAME [--now ISO] [--config FILE]
  node scripts/backlog-health.mjs --help

  --page-cap N   pagination cap (default 100; completeness protocol)

EXIT
  0  RED / YELLOW / GREEN   1  INCOMPLETE   2  usage
`);
}

function dieUsage(msg) {
  console.error(`backlog-health: ${msg}`);
  process.exit(2);
}

function isMain() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    try {
      return resolve(entry) === fileURLToPath(import.meta.url);
    } catch {
      return false;
    }
  }
}

function incompleteResult(reason, extra = {}) {
  return {
    rows: extra.rows || [],
    complete: false,
    incompleteReason: reason,
    citedMap: extra.citedMap || {},
    timelines: extra.timelines || {},
    reachableOids: extra.reachableOids || new Set(),
  };
}

export function dependencyCitationRe() {
  return new RegExp(DEPENDENCY_CITATION_RE_SOURCE, "gi");
}

export function section(body, name) {
  if (!body) return null;
  const re = new RegExp(
    `##\\s*${name}\\s*\\n([\\s\\S]*?)(?=\\n##\\s|$)`,
    "i"
  );
  const m = body.match(re);
  return m ? m[1].trim() : null;
}

/** Copy of decompose-graph.mjs blockedBy — parse ONLY ## Dependencies. */
export function parseDependencies(body) {
  const deps = section(body, "Dependencies");
  if (deps === null) return [];
  const t = deps.trim();
  if (!t || /^none\b/i.test(t)) return [];
  const src = deps;
  const out = new Set();
  const re = dependencyCitationRe();
  let m;
  while ((m = re.exec(src)) !== null) {
    out.add(Number(m[1]));
  }
  for (const line of src.split("\n")) {
    const bare = line.match(/^\s*[-*]?\s*#(\d+)\s*$/);
    if (bare) out.add(Number(bare[1]));
  }
  return [...out];
}

export function loadConfigFile(path) {
  if (!existsSync(path)) {
    throw new Error(`config not found: ${path}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    throw new Error(`config is not JSON: ${e.message}`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("config must be an object");
  }
  for (const k of CONFIG_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(parsed, k)) {
      throw new Error(`config missing ${k}`);
    }
  }
  const blockedRatioMax = Number(parsed.blockedRatioMax);
  const blockerQuietDays = Number(parsed.blockerQuietDays);
  const minDependents = Number(parsed.minDependents);
  const requestTimeoutMs = Number(parsed.requestTimeoutMs);
  if (!parsed.blockedLabel || typeof parsed.blockedLabel !== "string") {
    throw new Error("config blockedLabel must be a nonempty string");
  }
  if (!Number.isFinite(blockedRatioMax) || blockedRatioMax < 0) {
    throw new Error("config blockedRatioMax must be a finite number ≥ 0");
  }
  if (!Number.isFinite(blockerQuietDays) || blockerQuietDays < 0) {
    throw new Error("config blockerQuietDays must be a finite number ≥ 0");
  }
  if (!Number.isInteger(minDependents) || minDependents < 1) {
    throw new Error("config minDependents must be an integer ≥ 1");
  }
  if (!Number.isFinite(requestTimeoutMs) || requestTimeoutMs < 1) {
    throw new Error("config requestTimeoutMs must be a finite number ≥ 1");
  }
  return {
    blockedLabel: parsed.blockedLabel,
    blockedRatioMax,
    blockerQuietDays,
    minDependents,
    requestTimeoutMs,
  };
}

function parseIso(iso) {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : NaN;
}

export function inMovedWindow(createdAt, observationTime, blockerQuietDays) {
  const t = parseIso(createdAt);
  const now = parseIso(observationTime);
  if (!Number.isFinite(t) || !Number.isFinite(now)) return false;
  const start = now - blockerQuietDays * 86400 * 1000;
  return t > start && t <= now;
}

function prSource(event) {
  // CrossReferencedEvent and ConnectedEvent both expose the referencing
  // issue/PR as `source`. ConnectedEvent.subject is the connected issue
  // (often this blocker), not the merged PR — do not fall back to it.
  return (event && event.source) || null;
}

export function eventQualifies(event, reachableOids) {
  if (!event || typeof event !== "object") return false;
  const t = event.__typename;
  if (t === "ClosedEvent" || t === "ReopenedEvent") return true;
  if (t === "ReferencedEvent") {
    const oid = event.commit && event.commit.oid;
    if (!oid) return false;
    const set = reachableOids instanceof Set ? reachableOids : new Set(reachableOids || []);
    return set.has(oid);
  }
  if (t === "CrossReferencedEvent" || t === "ConnectedEvent") {
    const src = prSource(event);
    if (!src) return false;
    if (src.__typename === "PullRequest" && src.merged === true) return true;
    return false;
  }
  return false;
}

export function describeEvent(event) {
  const t = event.__typename || "UnknownEvent";
  if (t === "CrossReferencedEvent" || t === "ConnectedEvent") {
    const src = prSource(event);
    if (src && src.__typename === "PullRequest" && src.merged === true) {
      return `${t} merged-pr`;
    }
  }
  return t;
}

function resolveCited(n, rows, citedMap) {
  const fromRows = rows.find((r) => r.number === n);
  if (fromRows) return { number: fromRows.number, state: "OPEN" };
  if (!citedMap || !Object.prototype.hasOwnProperty.call(citedMap, String(n))) {
    return undefined;
  }
  const v = citedMap[String(n)];
  if (v == null) return null;
  return { number: Number(v.number || n), state: v.state || "OPEN" };
}

function citedIsOpen(n, rows, citedMap) {
  const r = resolveCited(n, rows, citedMap);
  return Boolean(r && r.state === "OPEN");
}

/**
 * One blocked predicate drives both the ratio and blocker discovery.
 * citedMap values: issue object, null (does not exist), undefined (not loaded).
 */
export function discover(rows, citedMap, config) {
  const blocked = [];
  for (const row of rows) {
    const citations = parseDependencies(row.body || "");
    const labelled = (row.labels || []).includes(config.blockedLabel);
    const openCite = citations.some((n) => citedIsOpen(n, rows, citedMap));
    if (labelled || openCite) {
      blocked.push({ number: row.number, citations, labelled, row });
    }
  }

  let unresolved = 0;
  const dependents = new Map();
  for (const b of blocked) {
    const unique = [...new Set(b.citations)];
    for (const n of unique) {
      const resolved = resolveCited(n, rows, citedMap);
      if (resolved === undefined) continue;
      if (resolved === null) {
        unresolved += 1;
        continue;
      }
      if (!dependents.has(n)) dependents.set(n, new Set());
      dependents.get(n).add(b.number);
    }
  }

  const topBlockers = [];
  for (const [n, deps] of dependents) {
    if (deps.size >= config.minDependents) {
      topBlockers.push({
        number: n,
        dependentCount: deps.size,
        issue: resolveCited(n, rows, citedMap),
      });
    }
  }
  topBlockers.sort((a, b) => a.number - b.number);

  return {
    blocked,
    blockedCount: blocked.length,
    openCount: rows.length,
    unresolved,
    topBlockers,
    dependents,
  };
}

function latestQualifying(events, reachableOids) {
  const qualifying = (events || []).filter((e) => eventQualifies(e, reachableOids));
  if (qualifying.length === 0) return { lastMovedAt: null, qualifying };
  const latest = qualifying.reduce((a, b) =>
    parseIso(a.createdAt) >= parseIso(b.createdAt) ? a : b
  );
  const ms = parseIso(latest.createdAt);
  return {
    lastMovedAt: Number.isFinite(ms) ? new Date(ms).toISOString() : null,
    qualifying,
    latest,
  };
}

export function buildSnapshot(loaded, config, observationTime) {
  const rows = loaded.rows || [];
  const citedMap = loaded.citedMap || {};
  const reachableOids =
    loaded.reachableOids instanceof Set
      ? loaded.reachableOids
      : new Set(loaded.reachableOids || []);
  const found = discover(rows, citedMap, config);

  let complete = loaded.complete !== false;
  let incompleteReason = loaded.incompleteReason;

  const timelines = loaded.timelines || {};
  for (const tb of found.topBlockers) {
    const tl = timelines[tb.number] || timelines[String(tb.number)];
    if (tl && Array.isArray(tl.errors) && tl.errors.length > 0) {
      complete = false;
      if (!incompleteReason) incompleteReason = INCOMPLETE.GRAPHQL_ERRORS;
    }
    if (tl && tl.hasNextPage) {
      complete = false;
      if (!incompleteReason) incompleteReason = INCOMPLETE.HAS_NEXT_PAGE;
    }
    if (loaded.timelineLookupFailed && loaded.timelineLookupFailed.has(tb.number)) {
      complete = false;
      if (!incompleteReason) incompleteReason = INCOMPLETE.GRAPHQL_ERRORS;
    }
  }

  const moved = [];
  const lastMovedAt = {};
  for (const tb of found.topBlockers) {
    const tl = timelines[tb.number] || timelines[String(tb.number)] || {};
    const info = latestQualifying(tl.nodes || [], reachableOids);
    lastMovedAt[tb.number] = info.lastMovedAt;
    const inWindow = (info.qualifying || []).filter((e) =>
      inMovedWindow(e.createdAt, observationTime, config.blockerQuietDays)
    );
    if (inWindow.length > 0) {
      const latest = inWindow.reduce((a, b) =>
        parseIso(a.createdAt) >= parseIso(b.createdAt) ? a : b
      );
      moved.push({ number: tb.number, event: latest });
    }
  }
  moved.sort((a, b) => a.number - b.number);

  return {
    complete,
    incompleteReason,
    openCount: found.openCount,
    blockedCount: found.blockedCount,
    blockedNumbers: found.blocked.map((b) => b.number).sort((a, b) => a - b),
    topBlockers: found.topBlockers,
    moved,
    lastMovedAt,
    unresolved: found.unresolved,
    rows,
    observationTime,
  };
}

function formatMax(max) {
  return Number(max).toFixed(2);
}

function formatRatio(blocked, open) {
  if (open === 0) return "0.000";
  return (blocked / open).toFixed(3);
}

export function classify(snapshot, config) {
  // VERDICT_PRECEDENCE_INCOMPLETE_WINS
  if (!snapshot.complete) {
    const code = snapshot.incompleteReason || INCOMPLETE.API_NON_SUCCESS;
    return {
      verdict: "INCOMPLETE",
      code,
      exitCode: 1,
      snapshot,
    };
  }
  // VERDICT_PRECEDENCE_INCOMPLETE_WINS_END

  const ratio =
    snapshot.openCount === 0 ? 0 : snapshot.blockedCount / snapshot.openCount;

  // VERDICT_PRECEDENCE_RED
  if (
    ratio > config.blockedRatioMax &&
    (snapshot.topBlockers.length === 0 || snapshot.moved.length === 0)
  ) {
    return { verdict: "RED", exitCode: 0, snapshot, ratio };
  }
  // VERDICT_PRECEDENCE_RED_END

  // VERDICT_PRECEDENCE_YELLOW
  if (ratio > config.blockedRatioMax && snapshot.moved.length > 0) {
    return { verdict: "YELLOW", exitCode: 0, snapshot, ratio };
  }
  // VERDICT_PRECEDENCE_YELLOW_END

  return { verdict: "GREEN", exitCode: 0, snapshot, ratio };
}

export function formatVerdict(result, config) {
  if (result.verdict === "INCOMPLETE") {
    return `INCOMPLETE: ${result.code}\n`;
  }
  const s = result.snapshot;
  const ratioCmp =
    s.openCount === 0
      ? 0
      : s.blockedCount / s.openCount > config.blockedRatioMax
        ? ">"
        : "≤";
  const head = `${result.verdict} ${s.blockedCount}/${s.openCount} blocked (${formatRatio(
    s.blockedCount,
    s.openCount
  )} ${ratioCmp} ${formatMax(config.blockedRatioMax)})`;
  if (result.verdict === "GREEN") {
    return `${head}\n`;
  }
  const lines = [head];
  if (s.topBlockers.length === 0) {
    lines.push(
      "top blockers: none (no issue cited by ≥ minDependents blocked issues)"
    );
  } else if (result.verdict === "RED") {
    for (const tb of s.topBlockers) {
      const at = s.lastMovedAt[tb.number];
      lines.push(`#${tb.number} lastMovedAt: ${at || "never"}`);
    }
  } else if (result.verdict === "YELLOW") {
    for (const m of s.moved) {
      const when = m.event && m.event.createdAt ? m.event.createdAt : "";
      const iso = Number.isFinite(parseIso(when))
        ? new Date(parseIso(when)).toISOString()
        : when;
      lines.push(`moved: #${m.number} ${describeEvent(m.event)} at ${iso}`);
    }
  }
  lines.push(`unresolved: ${s.unresolved}`);
  return `${lines.join("\n")}\n`;
}

function nodeLabels(node) {
  if (Array.isArray(node.labels)) {
    return node.labels.map((l) => (typeof l === "string" ? l : l && l.name)).filter(Boolean);
  }
  if (node.labels && Array.isArray(node.labels.nodes)) {
    return node.labels.nodes.map((l) => l && l.name).filter(Boolean);
  }
  return [];
}

function toRow(node) {
  return {
    number: Number(node.number),
    title: node.title || "",
    body: node.body || "",
    state: node.state || "OPEN",
    labels: nodeLabels(node),
  };
}

const QUERY_ISSUES = `query BacklogOpenIssues($owner: String!, $name: String!, $after: String, $label: String!) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name target { oid } }
    label(name: $label) { name }
    issues(first: 100, after: $after, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes {
        number title body state
        labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
      }
    }
  }
}`;

const QUERY_ISSUE = `query BacklogIssue($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) { number state }
  }
}`;

const QUERY_TIMELINE = `query BacklogTimeline($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      timelineItems(first: 100, after: $after) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on ClosedEvent { createdAt }
          ... on ReopenedEvent { createdAt }
          ... on ReferencedEvent { createdAt commit { oid } }
          ... on CrossReferencedEvent {
            createdAt
            source {
              __typename
              ... on PullRequest { number merged state }
              ... on Issue { number }
            }
          }
          ... on ConnectedEvent {
            createdAt
            source {
              __typename
              ... on PullRequest { number merged state }
              ... on Issue { number }
            }
          }
          ... on IssueComment { createdAt }
          ... on LabeledEvent { createdAt }
          ... on UnlabeledEvent { createdAt }
          ... on RenamedTitleEvent { createdAt }
          ... on AssignedEvent { createdAt }
        }
      }
    }
  }
}`;

// object(oid:) is GitObjectID; compare(headRef:) is String!. Same SHA, two
// variables — GraphQL checks each usage against its own argument type.
// Ref.compare treats the named ref as base and $headRef as head, so BEHIND
// means the referenced commit is an ancestor of the default branch.
// GitHub GraphQL has no two-OID compare (Repository/Commit have no compare
// field), so the base is the live default-branch tip, not the OID observed
// at listing time.
const QUERY_REACHABLE = `query BacklogReachable($owner: String!, $name: String!, $oid: GitObjectID!, $headRef: String!, $refName: String!) {
  repository(owner: $owner, name: $name) {
    object(oid: $oid) { ... on Commit { oid } }
    ref(qualifiedName: $refName) {
      compare(headRef: $headRef) { status behindBy }
    }
  }
}`;

function isAbortError(err) {
  const name = err && err.name;
  return name === "TimeoutError" || name === "AbortError";
}

function timeoutError() {
  try {
    return new DOMException("The operation was aborted.", "TimeoutError");
  } catch {
    const e = new Error("The operation was aborted.");
    e.name = "TimeoutError";
    return e;
  }
}

/**
 * Abortable GraphQL POST. Never calls process.exit.
 * Returns { complete, incompleteReason?, data? }.
 */
export async function graphqlRequest({
  fetchImpl,
  token,
  timeoutMs,
  query,
  variables,
}) {
  const impl = fetchImpl || fetch;
  let response;
  try {
    response = await impl(GRAPHQL_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        Authorization: token ? `Bearer ${token}` : "",
        "User-Agent": "gibson-backlog-health",
      },
      body: JSON.stringify({ query, variables }),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    if (isAbortError(err)) {
      return { complete: false, incompleteReason: INCOMPLETE.TIMEOUT };
    }
    return { complete: false, incompleteReason: INCOMPLETE.API_NON_SUCCESS };
  }
  if (!response || typeof response.ok !== "boolean") {
    return { complete: false, incompleteReason: INCOMPLETE.API_NON_SUCCESS };
  }
  if (!response.ok) {
    return { complete: false, incompleteReason: INCOMPLETE.API_NON_SUCCESS };
  }
  let body;
  try {
    body = await response.json();
  } catch {
    return { complete: false, incompleteReason: INCOMPLETE.API_NON_SUCCESS };
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return { complete: false, incompleteReason: INCOMPLETE.API_NON_SUCCESS };
  }
  if (Array.isArray(body.errors) && body.errors.length > 0) {
    return {
      complete: false,
      incompleteReason: INCOMPLETE.GRAPHQL_ERRORS,
      data: body.data || null,
      errors: body.errors,
    };
  }
  return { complete: true, data: body.data };
}

function detectOp(query) {
  if (typeof query !== "string") return "unknown";
  if (query.includes("BacklogOpenIssues")) return "issues";
  if (query.includes("BacklogTimeline")) return "timeline";
  if (query.includes("BacklogReachable")) return "reachable";
  if (query.includes("BacklogIssue")) return "issue";
  return "unknown";
}

function sameAfter(a, b) {
  const na = a == null || a === "null" ? null : a;
  const nb = b == null || b === "null" ? null : b;
  return na === nb;
}

export function createStubFetch(stub) {
  const ops = (stub && stub.ops) || [];
  return async function stubFetch(_url, init) {
    const payload = JSON.parse(init.body);
    const op = detectOp(payload.query);
    const vars = payload.variables || {};
    const hit = ops.find((entry) => {
      if (entry.op !== op) return false;
      if (op === "issues") return sameAfter(entry.after, vars.after);
      if (op === "issue") return Number(entry.number) === Number(vars.number);
      if (op === "timeline") {
        return (
          Number(entry.number) === Number(vars.number) &&
          sameAfter(entry.after, vars.after)
        );
      }
      if (op === "reachable") return entry.oid === vars.oid;
      return false;
    });
    if (!hit) {
      return new Response(JSON.stringify({ message: "no stub" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }
    if (hit.timeout) {
      // Honour the AbortSignal the loader always passes via AbortSignal.timeout.
      // Throw immediately so tests do not wait out requestTimeoutMs; a separate
      // test waits on a short timeout to prove the signal actually fires.
      if (!(init && init.signal)) {
        throw new Error("timeout stub: AbortSignal missing");
      }
      throw timeoutError();
    }
    const status = hit.status == null ? 200 : hit.status;
    return new Response(JSON.stringify(hit.body == null ? {} : hit.body), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  };
}

function gqlIssueNode(node) {
  return {
    number: node.number,
    title: node.title || "",
    body: node.body || "",
    state: node.state || "OPEN",
    labels: {
      pageInfo: { hasNextPage: Boolean(node.labelsHasNextPage) },
      nodes: (node.labels || []).map((name) =>
        typeof name === "string" ? { name } : { name: name && name.name }
      ),
    },
  };
}

export function graphqlStubFromWorld(world) {
  const ops = [];
  const oid =
    world.defaultBranchOid || "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const refName = world.defaultBranchName || "main";
  const status = world.httpStatus == null ? 200 : world.httpStatus;
  const listing = world.issues || { totalCount: 0, hasNextPage: false, nodes: [] };
  const pages = Array.isArray(world.issuePages)
    ? world.issuePages
    : [
        {
          after: null,
          totalCount: listing.totalCount == null ? (listing.nodes || []).length : listing.totalCount,
          hasNextPage: Boolean(listing.hasNextPage),
          endCursor: listing.endCursor == null ? null : listing.endCursor,
          nodes: listing.nodes || [],
        },
      ];

  pages.forEach((page, i) => {
    const after = i === 0 ? null : pages[i - 1].endCursor || page.after || null;
    const body = {
      data: {
        repository: {
          defaultBranchRef: { name: refName, target: { oid } },
          label:
            world.labelPresent === false
              ? null
              : { name: world.blockedLabel || "dependency-blocked" },
          issues: {
            totalCount: page.totalCount,
            pageInfo: {
              hasNextPage: Boolean(page.hasNextPage),
              endCursor: page.endCursor == null ? null : page.endCursor,
            },
            nodes: (page.nodes || []).map(gqlIssueNode),
          },
        },
      },
    };
    if (Array.isArray(world.listingErrors) && world.listingErrors.length > 0 && i === 0) {
      body.errors = world.listingErrors;
    }
    ops.push({
      op: "issues",
      after,
      status,
      timeout: Boolean(world.timeout) && i === 0,
      body,
    });
  });

  const cited = world.cited || {};
  const lookupFailures = new Set((world.lookupFailures || []).map(Number));
  for (const [num, info] of Object.entries(cited)) {
    const n = Number(num);
    if (lookupFailures.has(n)) {
      ops.push({
        op: "issue",
        number: n,
        status: 500,
        body: { message: "lookup failed" },
      });
      continue;
    }
    ops.push({
      op: "issue",
      number: n,
      status: 200,
      body: {
        data: {
          repository: {
            issue: info == null ? null : { number: info.number || n, state: info.state || "OPEN" },
          },
        },
      },
    });
    if (info == null) continue;
    const tlErrors = info.timelineErrors || [];
    const tlBody = {
      data: {
        repository: {
          issue: {
            timelineItems: {
              totalCount: (info.timeline || []).length,
              pageInfo: {
                hasNextPage: Boolean(info.timelineHasNextPage),
                endCursor: info.timelineHasNextPage ? "tl-next" : null,
              },
              nodes: info.timeline || [],
            },
          },
        },
      },
    };
    if (tlErrors.length > 0) tlBody.errors = tlErrors;
    ops.push({
      op: "timeline",
      number: n,
      after: null,
      status: 200,
      body: tlBody,
    });
  }
  for (const n of lookupFailures) {
    if (!ops.some((e) => e.op === "issue" && Number(e.number) === n)) {
      ops.push({
        op: "issue",
        number: n,
        status: 500,
        body: { message: "lookup failed" },
      });
    }
  }

  const reachable = new Set(world.reachableOids || []);
  const identicalOids = new Set(world.identicalOids || []);
  const aheadOids = new Set(world.aheadOids || []);
  const reachableFailures = new Set(world.reachableFailures || []);
  const compareBody = (commitOid, compareStatus) => ({
    data: {
      repository: {
        object: { oid: commitOid },
        ref: {
          compare: {
            status: compareStatus,
            behindBy:
              compareStatus === "BEHIND" || compareStatus === "DIVERGED" ? 1 : 0,
          },
        },
      },
    },
  });
  const pushReachable = (commitOid, compareStatus) => {
    if (ops.some((e) => e.op === "reachable" && e.oid === commitOid)) return;
    ops.push({
      op: "reachable",
      oid: commitOid,
      status: 200,
      body: compareBody(commitOid, compareStatus),
    });
  };
  for (const commitOid of reachable) {
    if (reachableFailures.has(commitOid)) {
      ops.push({
        op: "reachable",
        oid: commitOid,
        status: 500,
        body: { message: "unreachable lookup" },
      });
      continue;
    }
    pushReachable(commitOid, identicalOids.has(commitOid) ? "IDENTICAL" : "BEHIND");
  }
  const allOids = new Set(reachable);
  for (const extra of aheadOids) allOids.add(extra);
  for (const extra of identicalOids) allOids.add(extra);
  for (const info of Object.values(cited)) {
    for (const ev of (info && info.timeline) || []) {
      if (ev && ev.__typename === "ReferencedEvent" && ev.commit && ev.commit.oid) {
        allOids.add(ev.commit.oid);
      }
    }
  }
  for (const commitOid of allOids) {
    if (ops.some((e) => e.op === "reachable" && e.oid === commitOid)) continue;
    if (reachableFailures.has(commitOid)) continue;
    pushReachable(commitOid, aheadOids.has(commitOid) ? "AHEAD" : "DIVERGED");
  }

  const listingNodes = [];
  if (Array.isArray(world.issuePages)) {
    for (const page of world.issuePages) listingNodes.push(...(page.nodes || []));
  } else {
    listingNodes.push(...((world.issues && world.issues.nodes) || []));
  }
  const citationNums = new Set();
  for (const node of listingNodes) {
    for (const n of parseDependencies(node.body || "")) citationNums.add(n);
  }
  for (const n of citationNums) {
    if (!ops.some((e) => e.op === "timeline" && Number(e.number) === n)) {
      ops.push({
        op: "timeline",
        number: n,
        after: null,
        status: 200,
        body: {
          data: {
            repository: {
              issue: {
                timelineItems: {
                  totalCount: 0,
                  pageInfo: { hasNextPage: false, endCursor: null },
                  nodes: [],
                },
              },
            },
          },
        },
      });
    }
    if (
      !listingNodes.some((node) => node.number === n) &&
      !ops.some((e) => e.op === "issue" && Number(e.number) === n)
    ) {
      ops.push({
        op: "issue",
        number: n,
        status: 200,
        body: { data: { repository: { issue: null } } },
      });
    }
  }

  return { ops };
}

function collectCitationNumbers(rows) {
  const nums = new Set();
  for (const row of rows) {
    for (const n of parseDependencies(row.body || "")) nums.add(n);
  }
  return [...nums];
}

export function loadFromFixture(world, opts = {}) {
  const pageCap = opts.pageCap == null ? PAGE_CAP : opts.pageCap;
  if (world.timeout) return incompleteResult(INCOMPLETE.TIMEOUT);
  const status = world.httpStatus == null ? 200 : world.httpStatus;
  if (status < 200 || status >= 300) {
    return incompleteResult(INCOMPLETE.API_NON_SUCCESS);
  }
  if (Array.isArray(world.listingErrors) && world.listingErrors.length > 0) {
    return incompleteResult(INCOMPLETE.GRAPHQL_ERRORS);
  }
  if (world.labelPresent === false) {
    return incompleteResult(INCOMPLETE.MISSING_LABEL);
  }

  const pages = Array.isArray(world.issuePages)
    ? world.issuePages
    : [
        {
          totalCount:
            (world.issues && world.issues.totalCount) != null
              ? world.issues.totalCount
              : ((world.issues && world.issues.nodes) || []).length,
          hasNextPage: Boolean(world.issues && world.issues.hasNextPage),
          endCursor: world.issues ? world.issues.endCursor : null,
          nodes: (world.issues && world.issues.nodes) || [],
        },
      ];

  const rows = [];
  let totalCount = null;
  for (let i = 0; i < pages.length; i++) {
    if (i >= pageCap) {
      return incompleteResult(INCOMPLETE.PAGE_CAP, { rows });
    }
    const page = pages[i];
    if (totalCount == null) totalCount = page.totalCount;
    else if (page.totalCount !== totalCount) {
      return incompleteResult(INCOMPLETE.COUNT_MISMATCH, { rows });
    }
    for (const n of page.nodes || []) {
      if (n.labelsHasNextPage) {
        rows.push(toRow(n));
        return incompleteResult(INCOMPLETE.HAS_NEXT_PAGE, { rows });
      }
      rows.push(toRow(n));
    }
    if (page.hasNextPage) {
      if (i + 1 >= pageCap) {
        return incompleteResult(INCOMPLETE.PAGE_CAP, { rows });
      }
      if (i === pages.length - 1) {
        return incompleteResult(INCOMPLETE.HAS_NEXT_PAGE, { rows });
      }
    }
  }
  if (totalCount != null && rows.length !== totalCount) {
    return incompleteResult(INCOMPLETE.COUNT_MISMATCH, { rows });
  }

  const citedMap = {};
  const timelines = {};
  const lookupFailures = new Set((world.lookupFailures || []).map(Number));
  const cited = world.cited || {};

  for (const n of collectCitationNumbers(rows)) {
    if (rows.some((r) => r.number === n)) {
      citedMap[String(n)] = { number: n, state: "OPEN" };
      continue;
    }
    if (lookupFailures.has(n)) {
      return incompleteResult(INCOMPLETE.UNRESOLVED_LOOKUP, { rows, citedMap });
    }
    if (Object.prototype.hasOwnProperty.call(cited, String(n))) {
      const info = cited[String(n)];
      citedMap[String(n)] = info == null ? null : { number: info.number || n, state: info.state || "OPEN" };
    } else {
      citedMap[String(n)] = null;
    }
  }
  for (const [num, info] of Object.entries(cited)) {
    if (!Object.prototype.hasOwnProperty.call(citedMap, num)) {
      citedMap[num] =
        info == null ? null : { number: info.number || Number(num), state: info.state || "OPEN" };
    }
    if (info && Array.isArray(info.timeline)) {
      timelines[Number(num)] = {
        nodes: info.timeline,
        hasNextPage: Boolean(info.timelineHasNextPage),
        errors: info.timelineErrors || [],
      };
    }
  }

  return {
    rows,
    complete: true,
    citedMap,
    timelines,
    reachableOids: new Set(world.reachableOids || []),
  };
}

/**
 * Abortable GraphQL loader. Never calls process.exit.
 * Returns { rows, complete, incompleteReason?, citedMap, timelines, reachableOids }.
 */
export async function loadFromGraphql({
  owner,
  name,
  config,
  token,
  fetchImpl,
  pageCap = PAGE_CAP,
  timeoutMs,
}) {
  const ms = timeoutMs == null ? config.requestTimeoutMs : timeoutMs;
  const req = (query, variables) =>
    graphqlRequest({ fetchImpl, token, timeoutMs: ms, query, variables });

  const rows = [];
  let after = null;
  let pages = 0;
  let totalCount = null;
  let defaultRefName = "refs/heads/main";
  let labelSeen = false;

  while (true) {
    if (pages >= pageCap) {
      return incompleteResult(INCOMPLETE.PAGE_CAP, { rows });
    }
    pages += 1;
    const result = await req(QUERY_ISSUES, {
      owner,
      name,
      after,
      label: config.blockedLabel,
    });
    if (!result.complete) {
      return incompleteResult(result.incompleteReason, { rows });
    }
    const repo = result.data && result.data.repository;
    if (!repo) {
      return incompleteResult(INCOMPLETE.API_NON_SUCCESS, { rows });
    }
    if (!labelSeen) {
      if (repo.label == null) {
        return incompleteResult(INCOMPLETE.MISSING_LABEL, { rows });
      }
      labelSeen = true;
      if (repo.defaultBranchRef && repo.defaultBranchRef.name) {
        const n = repo.defaultBranchRef.name;
        defaultRefName = n.startsWith("refs/") ? n : `refs/heads/${n}`;
      }
    }
    const conn = repo.issues;
    if (!conn || !Array.isArray(conn.nodes)) {
      return incompleteResult(INCOMPLETE.API_NON_SUCCESS, { rows });
    }
    if (totalCount == null) totalCount = conn.totalCount;
    else if (conn.totalCount !== totalCount) {
      return incompleteResult(INCOMPLETE.COUNT_MISMATCH, { rows });
    }
    const pageInfo = conn.pageInfo || {};
    for (const node of conn.nodes) {
      if (node && node.labels && node.labels.pageInfo && node.labels.pageInfo.hasNextPage) {
        rows.push(toRow(node));
        return incompleteResult(INCOMPLETE.HAS_NEXT_PAGE, { rows });
      }
      rows.push(toRow(node));
    }
    if (pageInfo.hasNextPage) {
      if (typeof pageInfo.endCursor !== "string" || pageInfo.endCursor.length === 0) {
        return incompleteResult(INCOMPLETE.HAS_NEXT_PAGE, { rows });
      }
      after = pageInfo.endCursor;
      continue;
    }
    break;
  }
  if (totalCount != null && rows.length !== totalCount) {
    return incompleteResult(INCOMPLETE.COUNT_MISMATCH, { rows });
  }

  const citedMap = {};
  for (const row of rows) {
    citedMap[String(row.number)] = { number: row.number, state: "OPEN" };
  }
  const needed = collectCitationNumbers(rows).filter((n) => !citedMap[String(n)]);
  for (const n of needed) {
    const result = await req(QUERY_ISSUE, { owner, name, number: n });
    if (!result.complete) {
      const reason =
        result.incompleteReason === INCOMPLETE.GRAPHQL_ERRORS
          ? INCOMPLETE.UNRESOLVED_LOOKUP
          : result.incompleteReason === INCOMPLETE.API_NON_SUCCESS
            ? INCOMPLETE.UNRESOLVED_LOOKUP
            : result.incompleteReason;
      return incompleteResult(reason, { rows, citedMap });
    }
    const issue = result.data && result.data.repository && result.data.repository.issue;
    citedMap[String(n)] =
      issue == null ? null : { number: issue.number || n, state: issue.state || "OPEN" };
  }

  const found = discover(rows, citedMap, config);
  const timelines = {};
  const reachableOids = new Set();

  for (const tb of found.topBlockers) {
    const nodes = [];
    let tlAfter = null;
    let tlPages = 0;
    while (true) {
      if (tlPages >= pageCap) {
        return incompleteResult(INCOMPLETE.PAGE_CAP, { rows, citedMap, timelines, reachableOids });
      }
      tlPages += 1;
      const result = await req(QUERY_TIMELINE, {
        owner,
        name,
        number: tb.number,
        after: tlAfter,
      });
      if (!result.complete) {
        timelines[tb.number] = { nodes, hasNextPage: false, errors: result.errors || [{ message: "timeline" }] };
        return incompleteResult(
          result.incompleteReason === INCOMPLETE.TIMEOUT
            ? INCOMPLETE.TIMEOUT
            : result.incompleteReason === INCOMPLETE.API_NON_SUCCESS
              ? INCOMPLETE.API_NON_SUCCESS
              : INCOMPLETE.GRAPHQL_ERRORS,
          { rows, citedMap, timelines, reachableOids }
        );
      }
      const items =
        result.data &&
        result.data.repository &&
        result.data.repository.issue &&
        result.data.repository.issue.timelineItems;
      if (!items || !Array.isArray(items.nodes)) {
        return incompleteResult(INCOMPLETE.API_NON_SUCCESS, {
          rows,
          citedMap,
          timelines,
          reachableOids,
        });
      }
      nodes.push(...items.nodes);
      const pageInfo = items.pageInfo || {};
      if (pageInfo.hasNextPage) {
        if (typeof pageInfo.endCursor !== "string" || pageInfo.endCursor.length === 0) {
          timelines[tb.number] = { nodes, hasNextPage: true, errors: [] };
          return incompleteResult(INCOMPLETE.HAS_NEXT_PAGE, {
            rows,
            citedMap,
            timelines,
            reachableOids,
          });
        }
        tlAfter = pageInfo.endCursor;
        continue;
      }
      break;
    }
    timelines[tb.number] = { nodes, hasNextPage: false, errors: [] };
  }

  const pendingOids = new Set();
  for (const tl of Object.values(timelines)) {
    for (const ev of tl.nodes || []) {
      if (ev && ev.__typename === "ReferencedEvent" && ev.commit && ev.commit.oid) {
        pendingOids.add(ev.commit.oid);
      }
    }
  }
  for (const commitOid of pendingOids) {
    const result = await req(QUERY_REACHABLE, {
      owner,
      name,
      oid: commitOid,
      headRef: commitOid,
      refName: defaultRefName,
    });
    if (!result.complete) {
      return incompleteResult(result.incompleteReason, {
        rows,
        citedMap,
        timelines,
        reachableOids,
      });
    }
    const repo = result.data && result.data.repository;
    const obj = repo && repo.object;
    const cmp = repo && repo.ref && repo.ref.compare;
    // Default branch is the base; $headRef is the referenced commit. BEHIND
    // (head is ancestor of base) and IDENTICAL mean reachable from main.
    // AHEAD is a descendant/unmerged commit — the opposite.
    const reachable =
      Boolean(obj && obj.oid) &&
      cmp &&
      (cmp.status === "BEHIND" || cmp.status === "IDENTICAL");
    if (reachable) reachableOids.add(commitOid);
  }

  return {
    rows,
    complete: true,
    citedMap,
    timelines,
    reachableOids,
  };
}

export function runLoaded(loaded, config, observationTime) {
  const snapshot = buildSnapshot(loaded, config, observationTime);
  const result = classify(snapshot, config);
  return { result, text: formatVerdict(result, config) };
}

function parseNow(raw) {
  if (!raw) return new Date().toISOString();
  const t = Date.parse(raw);
  if (!Number.isFinite(t)) dieUsage("--now must be ISO-8601");
  return new Date(t).toISOString();
}

function parseRepo(repo) {
  const parts = String(repo || "").split("/");
  if (parts.length !== 2 || !parts[0] || !parts[1]) {
    dieUsage("--repo must be owner/name");
  }
  return { owner: parts[0], name: parts[1] };
}

export async function main(argv = process.argv.slice(2)) {
  if (argv.includes("-h") || argv.includes("--help")) {
    help();
    return 0;
  }
  const opt = parseFlags(argv, {
    prefix: "backlog-health: ",
    flags: {
      "--fixture": { key: "fixture", default: null },
      "--graphql-stub": { key: "graphqlStub", default: null },
      "--repo": { key: "repo", default: null },
      "--now": { key: "now", default: null },
      "--config": { key: "config", default: DEFAULT_CONFIG_REL },
      "--page-cap": {
        key: "pageCap",
        default: String(PAGE_CAP),
        transform: (v) => v,
      },
    },
  });
  if (opt.fixture && opt.graphqlStub) {
    dieUsage("--fixture and --graphql-stub cannot be combined");
  }
  let config;
  try {
    config = loadConfigFile(resolve(opt.config));
  } catch (e) {
    dieUsage(e.message);
  }
  const pageCap = Number(opt.pageCap);
  if (!Number.isInteger(pageCap) || pageCap < 1) {
    dieUsage("--page-cap must be an integer ≥ 1");
  }
  const observationTime = parseNow(opt.now);

  let loaded;
  if (opt.fixture) {
    if (!existsSync(opt.fixture)) dieUsage(`--fixture not found: ${opt.fixture}`);
    let world;
    try {
      world = JSON.parse(readFileSync(opt.fixture, "utf8"));
    } catch (e) {
      dieUsage(`--fixture is not JSON: ${e.message}`);
    }
    loaded = loadFromFixture(world, { pageCap });
  } else if (opt.graphqlStub) {
    if (!existsSync(opt.graphqlStub)) {
      dieUsage(`--graphql-stub not found: ${opt.graphqlStub}`);
    }
    let stub;
    try {
      stub = JSON.parse(readFileSync(opt.graphqlStub, "utf8"));
    } catch (e) {
      dieUsage(`--graphql-stub is not JSON: ${e.message}`);
    }
    const repo = opt.repo || process.env.GITHUB_REPOSITORY;
    const { owner, name } = parseRepo(repo);
    loaded = await loadFromGraphql({
      owner,
      name,
      config,
      token: process.env.GITHUB_TOKEN || process.env.GH_TOKEN || "stub",
      fetchImpl: createStubFetch(stub),
      pageCap,
      timeoutMs: config.requestTimeoutMs,
    });
  } else {
    const repo = opt.repo || process.env.GITHUB_REPOSITORY;
    if (!repo) dieUsage("--repo is required (or set GITHUB_REPOSITORY)");
    const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
    if (!token) dieUsage("GITHUB_TOKEN (or GH_TOKEN) is required for live mode");
    const { owner, name } = parseRepo(repo);
    loaded = await loadFromGraphql({
      owner,
      name,
      config,
      token,
      fetchImpl: fetch,
      pageCap,
      timeoutMs: config.requestTimeoutMs,
    });
  }

  const { result, text } = runLoaded(loaded, config, observationTime);
  process.stdout.write(text);
  return result.exitCode;
}

if (isMain()) {
  main().then(
    (code) => process.exit(code),
    (err) => {
      console.error(err && err.stack ? err.stack : err);
      process.exit(1);
    }
  );
}
