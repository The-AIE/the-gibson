#!/usr/bin/env node
/**
 * coord-graph-prototype.mjs — throwaway per-project coordination graph (#105)
 *
 * NOT a Gibson-core sensor. Target-side view over issues/claims/lessons/decisions.
 * See docs/research/coord-knowledge-graph-spike.md.
 */
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { execFileSync } from "node:child_process";

function help() {
  console.log(`coord-graph-prototype.mjs — #105 spike (NOT a core sensor)

USAGE
  node scripts/prototypes/coord-graph-prototype.mjs --repo-path PATH \\
    [--issues-file issues.json] [--query touches:prefix|blocks:N|owns:N]

Builds nodes/edges from the checkout substrate only (D-009).
`);
}

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help") || args.length === 0) {
  help();
  process.exit(args.includes("-h") || args.includes("--help") ? 0 : 2);
}

let repoPath = process.cwd();
let issuesFile = null;
let query = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--repo-path") repoPath = resolve(args[++i] || "");
  else if (args[i] === "--issues-file") issuesFile = args[++i];
  else if (args[i] === "--query") query = args[++i];
}

const nodes = [];
const edges = [];
const addNode = (kind, id, meta = {}) => {
  if (!nodes.some((n) => n.kind === kind && n.id === id))
    nodes.push({ kind, id, ...meta });
};
const addEdge = (type, from, to, meta = {}) => {
  edges.push({ type, from, to, ...meta });
};

function gitShow(ref, path) {
  try {
    return execFileSync("git", ["show", `${ref}:${path}`], {
      cwd: repoPath,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch {
    return null;
  }
}

function gitLs(ref, prefix) {
  try {
    return execFileSync("git", ["ls-tree", "--name-only", ref, prefix], {
      cwd: repoPath,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    })
      .split("\n")
      .filter(Boolean);
  } catch {
    return [];
  }
}

// Prefer origin/main tip for claims (same as claim path)
let ref = "origin/main";
try {
  execFileSync("git", ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`], {
    cwd: repoPath,
    stdio: "ignore",
  });
} catch {
  ref = "HEAD";
}

// Claims
for (const path of gitLs(ref, "docs/claims/")) {
  if (!path.endsWith(".md")) continue;
  const id = path.replace(/^docs\/claims\//, "").replace(/\.md$/, "");
  const body = gitShow(ref, path) || "";
  const scope = ((body.match(/^scope:\s*(.+)$/m) || [])[1] || "")
    .trim()
    .split(/\s+/)
    .filter(Boolean);
  const issue = ((body.match(/^issue:\s*(\d+)/m) || [])[1]) || null;
  addNode("claim", id, { scope, issue });
  if (issue) {
    addNode("issue", `#${issue}`);
    addEdge("owns", id, `#${issue}`);
  }
  for (const s of scope) {
    addNode("file", s);
    addEdge("touches", id, s);
  }
}

// Issues + blocks
if (issuesFile && existsSync(issuesFile)) {
  const issues = JSON.parse(readFileSync(issuesFile, "utf8"));
  for (const issue of issues) {
    const n = Number(issue.number);
    if (!Number.isFinite(n)) continue;
    addNode("issue", `#${n}`, { title: issue.title || "" });
    const deps = (issue.body || "").match(
      /##\s*Dependencies\s*\n([\s\S]*?)(?=\n##\s|$)/i
    );
    const block = deps ? deps[1] : "";
    if (!block || /^none\b/i.test(block.trim())) continue;
    const re = /(?:blocked\s*by|depends\s*on)\s*:?\s*#?(\d+)/gi;
    let m;
    while ((m = re.exec(block)) !== null) {
      const b = Number(m[1]);
      addNode("issue", `#${b}`);
      addEdge("blocks", `#${n}`, `#${b}`);
    }
  }
}

// Lessons
const lessonsPath = join(repoPath, "memory/LESSONS.md");
if (existsSync(lessonsPath)) {
  const text = readFileSync(lessonsPath, "utf8");
  for (const m of text.matchAll(/^##\s*(L-\d+)\b[^\n]*/gm)) {
    addNode("lesson", m[1], { heading: m[0].slice(0, 80) });
  }
}

// Decisions
const decPath = join(repoPath, "memory/DECISIONS.md");
if (existsSync(decPath)) {
  const text = readFileSync(decPath, "utf8");
  for (const m of text.matchAll(/^##\s*(D-\d+)\b[^\n]*/gm)) {
    addNode("decision", m[1], { heading: m[0].slice(0, 80) });
  }
  for (const m of text.matchAll(
    /(D-\d+)[^\n]{0,120}supersedes\s+(D-\d+)/gi
  )) {
    addEdge("supersedes", m[1].toUpperCase(), m[2].toUpperCase());
  }
}

console.log(
  `coord-graph-prototype: ${nodes.length} nodes, ${edges.length} edges (ref=${ref})`
);

if (query) {
  if (query.startsWith("touches:")) {
    const prefix = query.slice("touches:".length);
    const hits = edges.filter(
      (e) =>
        e.type === "touches" &&
        (e.to === prefix ||
          e.to.startsWith(prefix) ||
          prefix.startsWith(stem(e.to)))
    );
    console.log(`query ${query}:`);
    for (const h of hits) console.log(`  ${h.from} touches ${h.to}`);
    if (!hits.length) console.log("  (none)");
  } else if (query.startsWith("blocks:")) {
    const n = query.slice("blocks:".length).replace(/^#/, "");
    const hits = edges.filter(
      (e) => e.type === "blocks" && (e.from === `#${n}` || e.to === `#${n}`)
    );
    console.log(`query ${query}:`);
    for (const h of hits) console.log(`  ${h.from} blocks ${h.to}`);
    if (!hits.length) console.log("  (none)");
  } else if (query.startsWith("owns:")) {
    const n = query.slice("owns:".length).replace(/^#/, "");
    const hits = edges.filter((e) => e.type === "owns" && e.to === `#${n}`);
    console.log(`query ${query}:`);
    for (const h of hits) console.log(`  ${h.from} owns ${h.to}`);
    if (!hits.length) console.log("  (none)");
  } else {
    console.error(`unknown query: ${query}`);
    process.exit(2);
  }
} else {
  console.log("nodes:", nodes.slice(0, 20));
  if (nodes.length > 20) console.log(`  ... +${nodes.length - 20} more`);
  console.log("edges:", edges.slice(0, 20));
  if (edges.length > 20) console.log(`  ... +${edges.length - 20} more`);
}

function stem(t) {
  return t.replace(/\/\*\*$/, "").replace(/\*\*$/, "").replace(/\*$/, "");
}

process.exit(0);
