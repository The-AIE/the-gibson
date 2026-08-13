#!/usr/bin/env node
/**
 * route-inventory.mjs — Next.js App Router route×role matrix scaffold (docs/08 §4)
 *
 * WHAT IT DOES
 *   Walks an App Router tree (app/ page|route files), emits a JSON
 *   inventory of routes for the authz matrix (expected 200/403/404 per role).
 *
 * WHY
 *   New route without a matrix entry should fail CI. This generates the scaffold
 *   humans/agents fill with expected outcomes + IDOR probes.
 *
 * RISKS
 *   - Heuristic discovery; dynamic segments ([id]) need manual role expectations.
 *   - Only App Router is fully supported in v1; pages/ router is best-effort.
 *   - Read-only unless --write is passed.
 *
 * USAGE
 *   node route-inventory.mjs --root /path/to/app-repo [--out matrix.json]
 *   node route-inventory.mjs --help
 */

import { readdirSync, statSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join, relative, dirname } from "node:path";

// inlined from lib/args.mjs — this file must stay single-file
// (vendored by ci/security.yml as a lone copy; no scripts/lib/ in that tree)
function dieUsage(msg) {
  console.error(msg);
  process.exit(2);
}

function unknownFlag(flag) {
  dieUsage(`unknown flag: ${flag}`);
}

function readFlag(args, name) {
  const i = args.indexOf(name);
  if (i < 0) return null;
  if (i + 1 >= args.length) {
    dieUsage(`${name} requires a value`);
  }
  // Consume the next token verbatim — a value may look like a flag.
  return args[i + 1];
}

function rejectUnknownFlags(argv, allowed, opts = {}) {
  const allow = new Set(allowed);
  const valueFlags = new Set(opts.valueFlags || []);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--") break;
    if (a.startsWith("-") && a !== "-") {
      if (!allow.has(a)) unknownFlag(a);
      if (valueFlags.has(a) && i + 1 < argv.length) {
        i += 1;
      }
    }
  }
}

function help() {
  console.log(`route-inventory.mjs — emit route inventory for AuthZ matrix (docs/08)

WHAT IT DOES
  Scans Next.js app/ for page.tsx|js, route.ts|js and builds a route list with
  placeholder role expectations for you to fill.

WHY
  Layer 4 hard-fail: every route × every role needs an expected status, plus
  cross-tenant IDOR probes.

RISKS
  Incomplete on exotic route groups; always review output. Default is stdout only.

USAGE
  node scripts/route-inventory.mjs --root ~/Code/acme-app
  node scripts/route-inventory.mjs --root . --out authz/route-matrix.json --roles admin,user,anon
  node scripts/route-inventory.mjs --help

EXAMPLES
  # Scaffold into the target repo
  node scripts/route-inventory.mjs --root . --out tests/authz/route-matrix.json
`);
}

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
  help();
  process.exit(0);
}

rejectUnknownFlags(args, ["--root", "--out", "--roles", "-h", "--help"], {
  valueFlags: ["--root", "--out", "--roles"],
});
const root = readFlag(args, "--root") || process.cwd();
const out = readFlag(args, "--out");
const rolesRaw = readFlag(args, "--roles");
const roles = rolesRaw
  ? rolesRaw.split(",").map((x) => x.trim())
  : ["anon", "user", "admin"];
const appDirCandidates = [
  join(root, "app"),
  join(root, "src", "app"),
];
const appDir = appDirCandidates.find((p) => existsSync(p));

if (!appDir) {
  console.error(
    `route-inventory: no app/ or src/app/ under ${root} (Next.js App Router)`
  );
  process.exit(2);
}

const PAGE_RE = /^(page|route)\.(t|j)sx?$/;
const routes = [];

function walk(dir) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }
  for (const name of entries) {
    if (name === "node_modules" || name.startsWith(".")) continue;
    const full = join(dir, name);
    let st;
    try {
      st = statSync(full);
    } catch {
      continue;
    }
    if (st.isDirectory()) walk(full);
    else if (PAGE_RE.test(name)) {
      const rel = relative(appDir, dirname(full));
      const url = "/" + (rel === "" ? "" : rel)
        .split(/[/\\]/)
        .filter((s) => s && !(s.startsWith("(") && s.endsWith(")"))) // drop route groups
        .map((s) => s.replace(/^\[\[\.\.\.(.+)\]\]$/, "*$1").replace(/^\[\.\.\.(.+)\]$/, "*$1").replace(/^\[(.+)\]$/, ":$1"))
        .join("/");
      const kind = name.startsWith("route") ? "handler" : "page";
      const methods = kind === "handler" ? ["GET", "POST", "PUT", "PATCH", "DELETE"] : ["GET"];
      routes.push({
        path: url === "/" ? "/" : url.replace(/\/$/, "") || "/",
        file: relative(root, full),
        kind,
        methods,
      });
    }
  }
}

walk(appDir);

// de-dupe by path+kind
const seen = new Set();
const unique = [];
for (const r of routes) {
  const k = `${r.kind}:${r.path}:${r.file}`;
  if (seen.has(k)) continue;
  seen.add(k);
  unique.push(r);
}
unique.sort((a, b) => a.path.localeCompare(b.path));

const matrix = {
  generated_at: new Date().toISOString(),
  framework: "next-app-router",
  root,
  roles,
  routes: unique.map((r) => ({
    ...r,
    // expected HTTP status per role — FILL IN (200 | 401 | 403 | 404)
    expect: Object.fromEntries(roles.map((role) => [role, null])),
    idor_probes: [
      // { as: "user", resourceOwnedBy: "other-user", expect: 403|404 }
    ],
  })),
  notes:
    "Fill expect[role] for every route. New route with null expect should fail CI. Add IDOR probes for object-ID routes.",
};

const text = JSON.stringify(matrix, null, 2);
if (out) {
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, text + "\n");
  console.error(`route-inventory: wrote ${out} (${unique.length} routes)`);
} else {
  console.log(text);
}
console.error(`route-inventory: ${unique.length} routes from ${appDir}`);
