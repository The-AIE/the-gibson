#!/usr/bin/env node
/**
 * decompose-graph.mjs — dependency DAG sensor for issue sets (docs/04, #104)
 *
 * WHAT IT DOES
 *   Builds a directed graph from `Blocked by #N` edges in each issue's
 *   Dependencies section (and free-form "Blocked by #N" mentions). Detects
 *   cycles (fail closed). On a valid DAG, prints a topological order and the
 *   critical path (longest dependency chain).
 *
 * WHY
 *   decompose-lint.mjs only checks each issue in isolation — a cycle
 *   (A blocks B blocks A) passes and can deadlock a sprint. Graph sensors are
 *   the sanctioned exception to a graph-free core (D-007, docs/25 §5).
 *
 * RISKS
 *   - Heuristic markdown parse; follow docs/04 Dependencies section.
 *   - --repo mode needs network + gh auth.
 *   - Read-only; never mutates issues.
 *
 * USAGE
 *   node scripts/decompose-graph.mjs --file issues.json
 *   node scripts/decompose-graph.mjs --repo org/name --label gibson
 *   node scripts/decompose-graph.mjs --help
 *
 * issues.json shape:
 *   [{ "number": 1, "title": "...", "body": "...", "labels": ["tier-b"] }, ...]
 */

import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { parseFlags } from "./lib/args.mjs";

function help() {
  console.log(`decompose-graph.mjs — dependency cycle + critical-path sensor (#104)

WHAT IT DOES
  Builds a directed graph from Blocked by #N edges across an issue set.
  Exits non-zero on a cycle; on a DAG prints topological order and the
  critical path (longest chain of blocked-by edges).

WHY
  Isolation lint cannot see A→B→A. A cycle deadlocks the claim queue.

RISKS
  Markdown heuristics — use a ## Dependencies section (or "none").
  --repo calls GitHub via gh. Read-only.

USAGE
  node scripts/decompose-graph.mjs --file draft.json
  node scripts/decompose-graph.mjs --repo acme/app --label gibson
  node scripts/decompose-graph.mjs --help

EXAMPLES
  node scripts/decompose-graph.mjs --file /tmp/issues.json
  echo $?  # 0 = DAG, 1 = cycle, 2 = usage
`);
}

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help") || args.length === 0) {
  help();
  process.exit(args.includes("-h") || args.includes("--help") ? 0 : 2);
}

const opt = parseFlags(args, {
  flags: {
    "--file": { key: "file", default: null },
    "--repo": { key: "repo", default: null },
    "--label": { key: "label", default: "gibson" },
  },
});

function loadIssues() {
  if (opt.file) {
    if (!existsSync(opt.file)) {
      console.error(`missing file: ${opt.file}`);
      process.exit(2);
    }
    return JSON.parse(readFileSync(opt.file, "utf8"));
  }
  if (opt.repo) {
    const r = spawnSync(
      "gh",
      [
        "issue",
        "list",
        "-R",
        opt.repo,
        "--label",
        opt.label,
        "--state",
        "open",
        "--limit",
        "200",
        "--json",
        "number,title,body,labels",
      ],
      { encoding: "utf8" }
    );
    if (r.status !== 0) {
      console.error(r.stderr || "gh issue list failed");
      process.exit(2);
    }
    return JSON.parse(r.stdout);
  }
  console.error("provide --file or --repo");
  process.exit(2);
}

function section(body, name) {
  if (!body) return null;
  const re = new RegExp(
    `##\\s*${name}\\s*\\n([\\s\\S]*?)(?=\\n##\\s|$)`,
    "i"
  );
  const m = body.match(re);
  return m ? m[1].trim() : null;
}

/** Parse Blocked by #N edges from Dependencies (and whole body as fallback). */
function blockedBy(body) {
  const deps = section(body, "Dependencies");
  // Missing / empty / "none" → no edges (tolerated like the lint).
  if (deps === null) return [];
  const t = deps.trim();
  if (!t || /^none\b/i.test(t)) return [];
  const src = deps;
  const out = new Set();
  // Blocked by #12, blocked-by: #12, depends on #12, blocked by 12
  const re =
    /(?:blocked\s*by|depends\s*on|requires|after)\s*:?\s*#?(\d+)/gi;
  let m;
  while ((m = re.exec(src)) !== null) {
    out.add(Number(m[1]));
  }
  // bare #N lines under Dependencies (common template form)
  for (const line of src.split("\n")) {
    const bare = line.match(/^\s*[-*]?\s*#(\d+)\s*$/);
    if (bare) out.add(Number(bare[1]));
  }
  return [...out];
}

const issues = loadIssues();
if (!Array.isArray(issues) || issues.length === 0) {
  console.log("decompose-graph: OK (0 issues, empty graph)");
  process.exit(0);
}

// nodes: only issues in the set (edges to external numbers are recorded but
// do not create phantom nodes that break topo of the set)
const nodes = new Map(); // number -> { title, blockedBy: number[] }
for (const issue of issues) {
  const n = Number(issue.number);
  if (!Number.isFinite(n)) continue;
  nodes.set(n, {
    title: issue.title || "",
    blockedBy: blockedBy(issue.body || ""),
  });
}

// adj: dependency edge A → B means "A is blocked by B" (A waits on B).
// Critical path = longest chain following these edges toward roots.
const adj = new Map(); // n -> Set of blockers (edges n → blocker)
const indeg = new Map(); // for reverse topo (leaves first): count of dependents
for (const n of nodes.keys()) {
  adj.set(n, new Set());
  indeg.set(n, 0);
}
for (const [n, meta] of nodes) {
  for (const b of meta.blockedBy) {
    if (!nodes.has(b)) continue; // external dep — ignore for cycle/topo of set
    adj.get(n).add(b);
  }
}

// Cycle detection via DFS (colors: 0 white, 1 gray, 2 black)
const color = new Map();
for (const n of nodes.keys()) color.set(n, 0);
const cyclePath = [];

function dfs(u, stack) {
  color.set(u, 1);
  stack.push(u);
  for (const v of adj.get(u) || []) {
    if (color.get(v) === 1) {
      // cycle: from v to end of stack + v
      const i = stack.indexOf(v);
      cyclePath.push(...stack.slice(i), v);
      return true;
    }
    if (color.get(v) === 0 && dfs(v, stack)) return true;
  }
  stack.pop();
  color.set(u, 2);
  return false;
}

for (const n of nodes.keys()) {
  if (color.get(n) === 0 && dfs(n, [])) break;
}

if (cyclePath.length) {
  console.log("decompose-graph: FAIL — dependency cycle detected");
  console.log(`  cycle: ${cyclePath.map((x) => `#${x}`).join(" → ")}`);
  process.exit(1);
}

// Topological order: Kahn on reverse edges (blockers before blocked)
// Build reverse: blocker → dependents
const rev = new Map();
const revIndeg = new Map();
for (const n of nodes.keys()) {
  rev.set(n, new Set());
  revIndeg.set(n, 0);
}
for (const [n, blockers] of adj) {
  for (const b of blockers) {
    rev.get(b).add(n);
    revIndeg.set(n, (revIndeg.get(n) || 0) + 1);
  }
}

const queue = [];
for (const [n, d] of revIndeg) {
  if (d === 0) queue.push(n);
}
queue.sort((a, b) => a - b);
const topo = [];
while (queue.length) {
  const u = queue.shift();
  topo.push(u);
  const next = [...(rev.get(u) || [])].sort((a, b) => a - b);
  for (const v of next) {
    revIndeg.set(v, revIndeg.get(v) - 1);
    if (revIndeg.get(v) === 0) queue.push(v);
  }
  queue.sort((a, b) => a - b);
}

if (topo.length !== nodes.size) {
  // Should not happen after DFS cycle check; fail closed.
  console.log("decompose-graph: FAIL — graph not fully ordered (hidden cycle?)");
  process.exit(1);
}

// Critical path: longest path in the DAG following blocked-by edges (n → blocker)
// Distance from leaves: for each node, 1 + max(dist of blockers) or 1 if none
const dist = new Map();
const pred = new Map();
for (const n of topo) {
  // process in reverse topo so blockers are processed first
}
// topo is blockers-first; iterate reverse for dependents-first? 
// We want: path length following edges n→blocker toward roots.
// Process nodes after their blockers: use topo order (blockers first).
for (const n of topo) {
  const blockers = [...(adj.get(n) || [])];
  if (blockers.length === 0) {
    dist.set(n, 1);
    pred.set(n, null);
  } else {
    let best = null;
    let bestD = -1;
    for (const b of blockers) {
      const d = (dist.get(b) || 1) + 1;
      if (d > bestD || (d === bestD && (best === null || b < best))) {
        bestD = d;
        best = b;
      }
    }
    dist.set(n, bestD);
    pred.set(n, best);
  }
}

let end = null;
let endD = -1;
for (const [n, d] of dist) {
  if (d > endD || (d === endD && (end === null || n < end))) {
    endD = d;
    end = n;
  }
}

const crit = [];
let cur = end;
while (cur != null) {
  crit.push(cur);
  cur = pred.get(cur) ?? null;
}
// crit is leaf → ... → root; print root → leaf for "build order"
const critRootFirst = [...crit].reverse();

console.log(`decompose-graph: OK (${nodes.size} issues, DAG)`);
console.log(
  `  topological order: ${topo.map((n) => `#${n}`).join(" → ")}`
);
console.log(
  `  critical path (${endD} issue${endD === 1 ? "" : "s"}): ${critRootFirst
    .map((n) => `#${n}`)
    .join(" → ")}`
);
process.exit(0);
