/**
 * Shared GitHub issue loader for decompose-lint / decompose-graph (#257).
 *
 * Report-only: complete GraphQL cursor pagination, totalCount proof, a
 * 100-page cap, repeated-label OR-union (canonical argv: nonempty, no
 * controls, exact-deduped, sorted for digest and query order), duplicate
 * consistency, and a before/after default-branch SHA + (number, updatedAt)
 * observation. Never edits GitHub and never classifies claims, readiness,
 * or authority.
 *
 * Pure library — import, do not execute.
 */

import { createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dieUsage } from "./args.mjs";

export const PAGE_SIZE = 100;
export const PAGE_CAP = 100;

const ANSI_RE = /\x1b\[/;
const CONTROL_RE = /[\u0000-\u001F\u007F-\u009F]/;
const OID_RE = /^[0-9a-f]{40}$/;
const TIMESTAMP_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
const DAYS_IN_MONTH = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

const INCOMPLETE_REASONS = new Set([
  "API_FAILURE",
  "ANSI_OUTPUT",
  "INVALID_JSON",
  "INVALID_SHAPE",
  "STALE_OBSERVATION",
  "COUNT_MISMATCH",
  "CURSOR",
  "PAGE_CAP",
  "CONFLICTING_DUPLICATE",
  "GRAPHQL_ERRORS",
  "INVALID_OID",
  "OVERFULL_PAGE",
  "LABELS_INCOMPLETE",
  "INVALID_NODE",
  "INVALID_COUNT",
]);

const INCOMPLETE_DETAILS = new Set([
  "GH_NOT_FOUND",
  "GH_EXIT",
  "EMPTY_STDOUT",
]);

function incomplete(reason, detail) {
  const code = INCOMPLETE_REASONS.has(reason) ? reason : "INVALID_SHAPE";
  const extra = INCOMPLETE_DETAILS.has(detail) ? detail : null;
  console.log(extra ? `INCOMPLETE: ${code}: ${extra}` : `INCOMPLETE: ${code}`);
  process.exit(3);
}

function labelDigest(labels) {
  return createHash("sha256").update(JSON.stringify(labels), "utf8").digest("hex");
}

/** Nonempty, no controls, no leading --, exact-deduped, sorted. OR-union query order follows this. */
function canonicalizeLabels(labels) {
  const unique = [];
  const seen = new Set();
  for (const l of labels) {
    if (!l) dieUsage("--label requires a nonempty name");
    if (CONTROL_RE.test(l)) dieUsage("--label contains a control character");
    if (l.startsWith("--")) {
      dieUsage("combined selectors: --label value must not begin with --");
    }
    if (seen.has(l)) continue;
    seen.add(l);
    unique.push(l);
  }
  unique.sort();
  return unique;
}

function selectorText(allOpen, labels) {
  if (allOpen) return "all-open";
  return `labels count=${labels.length} digest=${labelDigest(labels)}`;
}

function parseRepo(repo) {
  const parts = String(repo).split("/");
  if (parts.length !== 2 || !parts[0] || !parts[1]) {
    dieUsage("--repo must be owner/name");
  }
  return { owner: parts[0], name: parts[1] };
}

function buildQuery(kind, labeled) {
  const nodeFields =
    kind === "load"
      ? "number title body updatedAt labels(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { name } }"
      : "number updatedAt";
  const varDecl = labeled
    ? "$owner: String!, $name: String!, $after: String, $label: String!"
    : "$owner: String!, $name: String!, $after: String";
  const labelsArg = labeled ? ", labels: [$label]" : "";
  return `query(${varDecl}) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { target { oid } }
    issues(first: 100, after: $after, states: [OPEN]${labelsArg}, orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes { ${nodeFields} }
    }
  }
}`;
}

function parseGhJson(stdout, status) {
  if (status !== 0) {
    incomplete("API_FAILURE", "GH_EXIT");
  }
  if (stdout == null || String(stdout).length === 0) {
    incomplete("API_FAILURE", "EMPTY_STDOUT");
  }
  const text = String(stdout);
  if (ANSI_RE.test(text)) incomplete("ANSI_OUTPUT");
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    incomplete("INVALID_JSON");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    incomplete("INVALID_SHAPE");
  }
  if (parsed.errors != null) incomplete("GRAPHQL_ERRORS");
  return parsed;
}

function ghGraphql(query, vars) {
  const args = ["api", "graphql", "-f", `query=${query}`];
  args.push("-f", `owner=${vars.owner}`, "-f", `name=${vars.name}`);
  if (vars.after == null) args.push("-F", "after=null");
  else args.push("-f", `after=${vars.after}`);
  if (vars.label != null) args.push("-f", `label=${vars.label}`);
  const r = spawnSync("gh", args, {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (r.error && r.error.code === "ENOENT") {
    incomplete("API_FAILURE", "GH_NOT_FOUND");
  }
  return parseGhJson(r.stdout, r.status);
}

function issuesConnection(parsed) {
  const repo = parsed && parsed.data && parsed.data.repository;
  if (!repo || typeof repo !== "object") incomplete("INVALID_SHAPE");
  const oid =
    repo.defaultBranchRef &&
    repo.defaultBranchRef.target &&
    repo.defaultBranchRef.target.oid;
  if (typeof oid !== "string" || !OID_RE.test(oid)) incomplete("INVALID_OID");
  const issues = repo.issues;
  if (!issues || typeof issues !== "object") incomplete("INVALID_SHAPE");
  if (!Number.isInteger(issues.totalCount) || issues.totalCount < 0) {
    incomplete("INVALID_COUNT");
  }
  const pageInfo = issues.pageInfo;
  if (!pageInfo || typeof pageInfo !== "object") incomplete("INVALID_SHAPE");
  if (typeof pageInfo.hasNextPage !== "boolean") incomplete("INVALID_SHAPE");
  if (!Array.isArray(issues.nodes)) incomplete("INVALID_SHAPE");
  if (issues.nodes.length > PAGE_SIZE) incomplete("OVERFULL_PAGE");
  return {
    oid,
    totalCount: issues.totalCount,
    pageInfo,
    nodes: issues.nodes,
  };
}

function isLeapYear(year) {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

function isValidTimestamp(value) {
  if (typeof value !== "string" || value.length === 0) return false;
  if (!TIMESTAMP_RE.test(value)) return false;
  // Date.parse normalizes impossible calendar dates (2026-02-30 → March 2).
  const year = Number(value.slice(0, 4));
  const month = Number(value.slice(5, 7));
  const day = Number(value.slice(8, 10));
  const hour = Number(value.slice(11, 13));
  const minute = Number(value.slice(14, 16));
  const second = Number(value.slice(17, 19));
  if (month < 1 || month > 12) return false;
  const dim = month === 2 && isLeapYear(year) ? 29 : DAYS_IN_MONTH[month];
  if (day < 1 || day > dim) return false;
  if (hour > 23 || minute > 59 || second > 59) return false;
  if (!value.endsWith("Z")) {
    const zoneHour = Number(value.slice(-5, -3));
    const zoneMinute = Number(value.slice(-2));
    if (zoneHour > 23 || zoneMinute > 59) return false;
  }
  return true;
}

function normalizeObserve(node) {
  if (!node || typeof node !== "object") incomplete("INVALID_NODE");
  const number = node.number;
  if (!Number.isInteger(number) || number <= 0) incomplete("INVALID_NODE");
  if (!isValidTimestamp(node.updatedAt)) incomplete("INVALID_NODE");
  return { number, updatedAt: node.updatedAt };
}

function normalizeLabels(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    incomplete("LABELS_INCOMPLETE");
  }
  if (!Number.isInteger(raw.totalCount) || raw.totalCount < 0) {
    incomplete("LABELS_INCOMPLETE");
  }
  if (raw.totalCount > PAGE_SIZE) incomplete("LABELS_INCOMPLETE");
  const pageInfo = raw.pageInfo;
  if (!pageInfo || typeof pageInfo !== "object") incomplete("LABELS_INCOMPLETE");
  if (pageInfo.hasNextPage !== false) incomplete("LABELS_INCOMPLETE");
  if (!Object.prototype.hasOwnProperty.call(pageInfo, "endCursor")) {
    incomplete("LABELS_INCOMPLETE");
  }
  if (
    pageInfo.endCursor !== null &&
    (typeof pageInfo.endCursor !== "string" || pageInfo.endCursor.length === 0)
  ) {
    incomplete("LABELS_INCOMPLETE");
  }
  if (!Array.isArray(raw.nodes)) incomplete("LABELS_INCOMPLETE");
  if (raw.totalCount !== raw.nodes.length) incomplete("LABELS_INCOMPLETE");
  const names = [];
  for (const lab of raw.nodes) {
    if (!lab || typeof lab !== "object" || typeof lab.name !== "string") {
      incomplete("LABELS_INCOMPLETE");
    }
    names.push(lab.name);
  }
  return names.slice().sort();
}

function normalizeLoad(node) {
  const base = normalizeObserve(node);
  if (typeof node.title !== "string") incomplete("INVALID_NODE");
  if (typeof node.body !== "string") incomplete("INVALID_NODE");
  if (!Object.prototype.hasOwnProperty.call(node, "labels")) {
    incomplete("LABELS_INCOMPLETE");
  }
  return {
    ...base,
    title: node.title,
    body: node.body,
    labels: normalizeLabels(node.labels),
  };
}

function sameIssue(a, b) {
  return (
    a.number === b.number &&
    a.updatedAt === b.updatedAt &&
    a.title === b.title &&
    a.body === b.body &&
    JSON.stringify(a.labels || []) === JSON.stringify(b.labels || [])
  );
}

function pairsKey(rows) {
  const pairs = rows
    .map((r) => [r.number, r.updatedAt])
    .sort((a, b) => a[0] - b[0] || String(a[1]).localeCompare(String(b[1])));
  return JSON.stringify(pairs);
}

function unionRows(sets, kind) {
  const map = new Map();
  for (const rows of sets) {
    for (const row of rows) {
      if (map.has(row.number)) {
        const prev = map.get(row.number);
        const same =
          kind === "load"
            ? sameIssue(prev, row)
            : prev.updatedAt === row.updatedAt;
        if (!same) incomplete("CONFLICTING_DUPLICATE");
      } else {
        map.set(row.number, row);
      }
    }
  }
  return [...map.values()].sort((a, b) => a.number - b.number);
}

function paginate({ owner, name, label, kind }) {
  const labeled = label != null;
  const query = buildQuery(kind, labeled);
  const rows = [];
  const seenNumbers = new Map();
  const seenCursors = new Set();
  let after = null;
  let pages = 0;
  let totalCount = null;
  let sha = null;

  while (true) {
    if (pages >= PAGE_CAP) incomplete("PAGE_CAP");
    pages += 1;
    const vars = { owner, name, after };
    if (labeled) vars.label = label;
    const conn = issuesConnection(ghGraphql(query, vars));
    if (sha == null) sha = conn.oid;
    else if (conn.oid !== sha) incomplete("STALE_OBSERVATION");
    if (totalCount == null) totalCount = conn.totalCount;
    else if (conn.totalCount !== totalCount) incomplete("COUNT_MISMATCH");

    const { hasNextPage, endCursor } = conn.pageInfo;
    if (!Object.prototype.hasOwnProperty.call(conn.pageInfo, "endCursor")) {
      incomplete("CURSOR");
    }
    if (
      endCursor !== null &&
      (typeof endCursor !== "string" || endCursor.length === 0)
    ) {
      incomplete("CURSOR");
    }
    if (hasNextPage) {
      if (typeof endCursor !== "string" || endCursor.length === 0) {
        incomplete("CURSOR");
      }
      if (seenCursors.has(endCursor)) incomplete("CURSOR");
      seenCursors.add(endCursor);
    }
    if (hasNextPage && conn.nodes.length === 0) incomplete("INVALID_SHAPE");

    for (const raw of conn.nodes) {
      const row = kind === "load" ? normalizeLoad(raw) : normalizeObserve(raw);
      if (seenNumbers.has(row.number)) {
        const prev = seenNumbers.get(row.number);
        const same =
          kind === "load"
            ? sameIssue(prev, row)
            : prev.updatedAt === row.updatedAt;
        if (!same) incomplete("CONFLICTING_DUPLICATE");
        continue;
      }
      seenNumbers.set(row.number, row);
      rows.push(row);
    }

    if (!hasNextPage) break;
    after = endCursor;
  }

  if (rows.length !== totalCount) incomplete("COUNT_MISMATCH");
  return { sha, rows, totalCount };
}

function emptySelection(selector, allowEmpty) {
  if (allowEmpty) {
    console.log(`INTENTIONAL_EMPTY: ${selector}`);
    process.exit(0);
  }
  console.log(`EMPTY_SELECTION: ${selector}`);
  process.exit(1);
}

function printReceipt({ allOpen, selector, sha, loaded, totalCount, sourceTotals }) {
  if (allOpen) {
    console.log(
      `issue-loader: selector=${selector} sha=${sha} loaded=${loaded} totalCount=${totalCount}`
    );
    return;
  }
  console.log(
    `issue-loader: selector=${selector} sha=${sha} loaded=${loaded} unionTotal=${loaded} sourceTotals=${sourceTotals.join(",")}`
  );
}

/**
 * Load an issue set from --file or a live GitHub repository selector.
 *
 * Repository mode requires exactly one selector family (--all-open XOR
 * one-or-more --label) and never defaults a label. Usage errors exit 2
 * before any `gh` invocation. Completeness failures print INCOMPLETE and
 * exit 3. A proven zero-row repository selection prints EMPTY_SELECTION
 * (exit 1) or INTENTIONAL_EMPTY (exit 0 with --allow-empty).
 *
 * @param {object} opts
 * @param {string|null} [opts.file]
 * @param {string|null} [opts.repo]
 * @param {string[]} [opts.labels]
 * @param {boolean} [opts.allOpen]
 * @param {boolean} [opts.allowEmpty]
 * @returns {object[]}
 */
export function loadIssueSet(opts) {
  const file = opts.file || null;
  const repo = opts.repo || null;
  const labels = Array.isArray(opts.labels) ? opts.labels.map(String) : [];
  const allOpen = Boolean(opts.allOpen);
  const allowEmpty = Boolean(opts.allowEmpty);
  const hasRepoSelector = allOpen || labels.length > 0;

  if (file && (repo || hasRepoSelector)) {
    dieUsage("cannot combine --file with --repo/--all-open/--label");
  }
  if (file) {
    if (!existsSync(file)) {
      dieUsage(`missing file: ${file}`);
    }
    return JSON.parse(readFileSync(file, "utf8"));
  }
  if (!repo && hasRepoSelector) {
    dieUsage("repository selector requires --repo");
  }
  if (!repo) {
    dieUsage("provide --file or --repo");
  }
  if (allOpen && labels.length > 0) {
    dieUsage("combined selectors: use either --all-open or --label, not both");
  }
  if (!allOpen && labels.length === 0) {
    dieUsage("missing repository selector: provide --all-open or --label <name>");
  }
  const canonicalLabels = canonicalizeLabels(labels);

  const { owner, name } = parseRepo(repo);
  const selector = selectorText(allOpen, canonicalLabels);
  const queries = allOpen ? [null] : canonicalLabels;

  function observeAll() {
    const sets = [];
    let sha = null;
    for (const label of queries) {
      const result = paginate({ owner, name, label, kind: "observe" });
      if (sha == null) sha = result.sha;
      else if (result.sha !== sha) incomplete("STALE_OBSERVATION");
      sets.push(result.rows);
    }
    return { sha, rows: unionRows(sets, "observe") };
  }

  const before = observeAll();
  const loadSets = [];
  const sourceTotals = [];
  for (const label of queries) {
    const result = paginate({ owner, name, label, kind: "load" });
    if (result.sha !== before.sha) incomplete("STALE_OBSERVATION");
    loadSets.push(result.rows);
    sourceTotals.push(result.totalCount);
  }
  const loaded = unionRows(loadSets, "load");
  const after = observeAll();

  if (after.sha !== before.sha) incomplete("STALE_OBSERVATION");
  if (pairsKey(before.rows) !== pairsKey(after.rows)) incomplete("STALE_OBSERVATION");
  if (pairsKey(loaded) !== pairsKey(before.rows)) incomplete("STALE_OBSERVATION");

  if (loaded.length === 0) {
    emptySelection(selector, allowEmpty);
  }

  const totalCount = allOpen ? sourceTotals[0] : loaded.length;
  printReceipt({
    allOpen,
    selector,
    sha: before.sha,
    loaded: loaded.length,
    totalCount,
    sourceTotals,
  });
  return loaded;
}
