#!/usr/bin/env node
/**
 * decompose-lint.mjs — validate issue set contracts (docs/04)
 *
 * WHAT IT DOES
 *   Checks that every issue has sprint contract, affected area, tier, and
 *   dependencies; contract criteria ≤10; schema-ish titles are standalone.
 *
 * WHY
 *   Bad decomposition is the root of thrash (docs/04 sizing heuristics). Catch
 *   it before builders claim.
 *
 * RISKS
 *   - False positives on free-form markdown (tune body sections to the template).
 *   - --repo mode needs network + gh auth.
 *   - Read-only; never mutates issues.
 *
 * USAGE
 *   node decompose-lint.mjs --file issues.json
 *   node decompose-lint.mjs --repo org/name --all-open
 *   node decompose-lint.mjs --repo org/name --label name
 *   node decompose-lint.mjs --help
 *
 * issues.json shape:
 *   [{ "number": 1, "title": "...", "body": "...", "labels": ["tier-b"] }, ...]
 */

import { parseFlags } from "./lib/args.mjs";
import { loadIssueSet } from "./lib/issue-loader.mjs";

function help() {
  console.log(`decompose-lint.mjs — validate decomposition quality (docs/04)

WHAT IT DOES
  Ensures each issue has: sprint contract criteria, affected area, tier,
  dependencies section; ≤10 criteria; schema changes look standalone.

WHY
  Units cut wrong fail twice (doc 09). Lint before the queue opens.

RISKS
  Heuristic markdown parse — follow docs/04 template for reliability.
  --repo calls GitHub API via gh.

USAGE
  node scripts/decompose-lint.mjs --file draft.json
  node scripts/decompose-lint.mjs --repo acme/app --all-open
  node scripts/decompose-lint.mjs --repo acme/app --label name
  node scripts/decompose-lint.mjs --help
  --allow-empty  changes a valid empty repository selection to INTENTIONAL_EMPTY exit 0

EXAMPLES
  # After drafting bodies:
  node scripts/decompose-lint.mjs --file /tmp/issues.json
  echo \$?  # 0 = clean, 1 = findings or EMPTY_SELECTION, 2 = usage, 3 = INCOMPLETE
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
    "--label": { key: "label", multiple: true },
    "--all-open": { key: "allOpen", type: "boolean" },
    "--allow-empty": { key: "allowEmpty", type: "boolean" },
  },
});

function loadIssues() {
  return loadIssueSet({
    file: opt.file,
    repo: opt.repo,
    labels: opt.label,
    allOpen: opt.allOpen,
    allowEmpty: opt.allowEmpty,
  });
}

function labelsOf(issue) {
  const L = issue.labels || [];
  return L.map((x) => (typeof x === "string" ? x : x.name || "")).map((s) =>
    s.toLowerCase()
  );
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

function criteria(body) {
  const sc =
    section(body, "Sprint contract(?:\\s*\\(acceptance criteria\\))?") ||
    section(body, "Acceptance criteria") ||
    "";
  const lines = sc.split("\n").filter((l) => /^\s*[-*]\s+\[[ xX]\]/.test(l));
  return lines;
}

const issues = loadIssues();
let errors = 0;
const report = [];

function err(n, msg) {
  errors++;
  report.push(`#${n}: ${msg}`);
}

const schemaTitles = [];
const all = [];

for (const issue of issues) {
  const n = issue.number ?? issue.title ?? "?";
  const body = issue.body || "";
  const title = issue.title || "";
  const labs = labelsOf(issue);
  all.push({ n, title, body, labs });

  const crit = criteria(body);
  if (crit.length === 0) err(n, "missing sprint contract checkboxes (- [ ] …)");
  if (crit.length > 10)
    err(n, `contract has ${crit.length} criteria (>10 → split per docs/04)`);

  const area = section(body, "Affected area");
  if (!area || area.length < 3) err(n, "missing or empty ## Affected area");

  const deps = section(body, "Dependencies");
  if (!deps) err(n, "missing ## Dependencies (use 'none' if unblocked)");

  const tierSection = section(body, "Tier");
  const hasTierLabel = labs.some((l) => /^tier-[abc]$/.test(l));
  const hasTierBody =
    tierSection && /\b[ABC]\b/i.test(tierSection.replace(/tier/gi, ""));
  if (!hasTierLabel && !hasTierBody)
    err(n, "missing tier (label tier-a|b|c or ## Tier section)");

  const schemaish =
    /schema|prisma|migration|drizzle/i.test(title) ||
    /schema\.(prisma|ts|sql)/i.test(body);
  if (schemaish) schemaTitles.push({ n, title });
}

// Schema standalone heuristic: if title is feature-like AND body mentions schema models heavily
for (const issue of all) {
  const schemaInArea = /schema\.(prisma)|migrations?\//i.test(
    section(issue.body, "Affected area") || ""
  );
  const featureTitle = /feat|feature|ui|page|button/i.test(issue.title);
  if (schemaInArea && featureTitle && !/schema|migration/i.test(issue.title)) {
    err(
      issue.n,
      "schema path in Affected area on a feature title — schema changes should be standalone issues (docs/04, L-002)"
    );
  }
}

if (report.length) {
  console.log("decompose-lint: FAIL\n");
  for (const line of report) console.log(`  - ${line}`);
} else {
  console.log(`decompose-lint: OK (${issues.length} issues)`);
}

process.exit(errors ? 1 : 0);
