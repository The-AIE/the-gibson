#!/usr/bin/env node
/**
 * contract-met.mjs — Law 6: acceptance criteria are the contract (#97)
 *
 * WHAT IT DOES
 *   When a PR (or ship body) claims to close/fix/resolve issue(s), verifies
 *   that each target issue's sprint-contract checkboxes are either checked on
 *   the issue OR explicitly evidenced in the PR body. A closing keyword with
 *   open unchecked criteria and no evidence is a refuse.
 *
 * WHY
 *   release-preflight checks that a close keyword is *present*, not that the
 *   contract is *met*. Closing an issue is not finishing it (Law 6).
 *
 * RISKS
 *   - Markdown checkbox heuristics; follow docs/04 sprint-contract template.
 *   - --repo needs gh auth. Read-only.
 *
 * USAGE
 *   node scripts/contract-met.mjs --issue-file issue.json --pr-body-file pr.md
 *   node scripts/contract-met.mjs --repo owner/name --pr 42
 *   node scripts/contract-met.mjs --help
 */

import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";

function help() {
  console.log(`contract-met.mjs — Law 6 acceptance-criteria sensor (#97)

WHAT IT DOES
  For each issue a PR claims to close, require every sprint-contract
  checkbox to be checked on the issue OR evidenced in the PR body.

WHY
  A close keyword without a met contract is an unfinished ship (Law 6).

RISKS
  Checkbox + evidence heuristics. Read-only. --repo needs gh.

USAGE
  node scripts/contract-met.mjs --issue-file i.json --pr-body-file body.md
  node scripts/contract-met.mjs --repo acme/app --pr 12
  node scripts/contract-met.mjs --help

issue.json: { "number": 1, "title": "...", "body": "..." }
  or an array of issues. Closing refs are taken from the PR body/title.
`);
}

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help") || args.length === 0) {
  help();
  process.exit(args.includes("-h") || args.includes("--help") ? 0 : 2);
}

function parseArgs(argv) {
  const out = {
    issueFile: null,
    prBodyFile: null,
    prTitle: "",
    repo: null,
    pr: null,
  };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--issue-file") out.issueFile = argv[++i];
    else if (argv[i] === "--pr-body-file") out.prBodyFile = argv[++i];
    else if (argv[i] === "--pr-title") out.prTitle = argv[++i] || "";
    else if (argv[i] === "--repo") out.repo = argv[++i];
    else if (argv[i] === "--pr") out.pr = argv[++i];
  }
  return out;
}

const opt = parseArgs(args);

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
  return lines.map((l) => {
    const checked = /^\s*[-*]\s+\[[xX]\]/.test(l);
    const text = l.replace(/^\s*[-*]\s+\[[ xX]\]\s*/, "").trim();
    return { checked, text, raw: l.trim() };
  });
}

/** Closing keywords GitHub honors (and partial negations we ignore). */
function closingIssueNumbers(title, body) {
  const text = `${title || ""}\n${body || ""}`;
  const nums = new Set();
  // Negative forms must not count (L-013)
  const cleaned = text
    .replace(/\b(?:does\s+not|don't|do\s+not|partial(?:ly)?)\s+(?:fully\s+)?(?:fix|close|resolve)s?\b[^\n]*/gi, " ")
    .replace(/\b(?:related|see|refs?|towards?)\s*#?\d+/gi, " ");
  const re =
    /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s*#?(\d+)\b/gi;
  let m;
  while ((m = re.exec(cleaned)) !== null) nums.add(Number(m[1]));
  // Closes #1, #2
  const multi =
    /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s*((?:#?\d+\s*,\s*)+#?\d+)/gi;
  while ((m = multi.exec(cleaned)) !== null) {
    for (const part of m[1].split(/[,\s]+/)) {
      const n = part.replace("#", "");
      if (/^\d+$/.test(n)) nums.add(Number(n));
    }
  }
  return [...nums];
}

/**
 * Evidence in PR body for a criterion: AC id, checkbox text stem, or
 * explicit "AC1:" / "criterion:" line.
 */
function evidencedInPr(crit, prBody) {
  if (!prBody) return false;
  const body = prBody.toLowerCase();
  // Checked box repeated in PR
  if (new RegExp(`\\[[xX]\\]\\s*.{0,40}${escapeRe(crit.text.slice(0, 40).toLowerCase())}`).test(body))
    return true;
  // AC1 / AC 1 markers when criterion text starts with AC1
  const ac = crit.text.match(/^(AC\s*\d+)\b/i);
  if (ac && body.includes(ac[1].toLowerCase().replace(/\s+/g, ""))) return true;
  if (ac && body.includes(ac[1].toLowerCase())) return true;
  // "Verified: <stem>" or "Done: <stem>"
  const stem = crit.text.slice(0, 48).toLowerCase();
  if (stem.length >= 12 && body.includes(stem)) return true;
  // Explicit contract-met receipt section
  if (/##\s*contract\s*met/i.test(prBody) && stem.length >= 8 && body.includes(stem.slice(0, 24)))
    return true;
  return false;
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function loadFromGh() {
  if (!opt.repo || !opt.pr) return null;
  const pr = spawnSync(
    "gh",
    [
      "pr",
      "view",
      String(opt.pr),
      "-R",
      opt.repo,
      "--json",
      "title,body,closingIssuesReferences",
    ],
    { encoding: "utf8" }
  );
  if (pr.status !== 0) {
    console.error(pr.stderr || "gh pr view failed");
    process.exit(2);
  }
  const prj = JSON.parse(pr.stdout);
  const refs = (prj.closingIssuesReferences || []).map((x) => x.number);
  const fromText = closingIssueNumbers(prj.title, prj.body);
  const allNums = [...new Set([...refs, ...fromText])];
  const issues = [];
  for (const n of allNums) {
    const ir = spawnSync(
      "gh",
      ["issue", "view", String(n), "-R", opt.repo, "--json", "number,title,body"],
      { encoding: "utf8" }
    );
    if (ir.status !== 0) {
      console.error(ir.stderr || `gh issue view #${n} failed`);
      process.exit(2);
    }
    issues.push(JSON.parse(ir.stdout));
  }
  return { issues, prTitle: prj.title || "", prBody: prj.body || "" };
}

let issues = [];
let prTitle = opt.prTitle || "";
let prBody = "";

if (opt.issueFile || opt.prBodyFile) {
  if (!opt.issueFile || !opt.prBodyFile) {
    console.error("contract-met: --issue-file and --pr-body-file are required together");
    process.exit(2);
  }
  if (!existsSync(opt.issueFile) || !existsSync(opt.prBodyFile)) {
    console.error("contract-met: missing input file");
    process.exit(2);
  }
  const raw = JSON.parse(readFileSync(opt.issueFile, "utf8"));
  issues = Array.isArray(raw) ? raw : [raw];
  prBody = readFileSync(opt.prBodyFile, "utf8");
} else if (opt.repo && opt.pr) {
  const g = loadFromGh();
  issues = g.issues;
  prTitle = g.prTitle;
  prBody = g.prBody;
} else {
  console.error("contract-met: provide file inputs or --repo/--pr");
  process.exit(2);
}

const closing = closingIssueNumbers(prTitle, prBody);
// Also map by issue numbers we were given when using files
const targets =
  closing.length > 0
    ? issues.filter((i) => closing.includes(Number(i.number)))
    : [];

if (closing.length === 0) {
  console.log(
    "contract-met: OK — no close/fix/resolve keywords; Law 6 N/A for this body"
  );
  process.exit(0);
}

if (targets.length === 0 && issues.length) {
  // File mode: PR closes N but issue set doesn't include N
  console.log(
    `contract-met: FAIL — closes ${closing.map((n) => `#${n}`).join(", ")} but no matching issue bodies were provided`
  );
  process.exit(1);
}

let errors = 0;
const report = [];

for (const issue of targets.length ? targets : issues) {
  const n = Number(issue.number);
  if (closing.length && !closing.includes(n)) continue;
  const crit = criteria(issue.body || "");
  if (crit.length === 0) {
    errors++;
    report.push(
      `#${n}: closing keyword present but issue has no sprint-contract checkboxes — cannot verify Law 6`
    );
    continue;
  }
  for (const c of crit) {
    if (c.checked) continue;
    if (evidencedInPr(c, prBody)) continue;
    errors++;
    report.push(
      `#${n}: open criterion not evidenced in PR: "${c.text.slice(0, 80)}"`
    );
  }
}

if (errors) {
  console.log("contract-met: FAIL — Law 6 (acceptance criteria are the contract)\n");
  for (const line of report) console.log(`  - ${line}`);
  process.exit(1);
}

console.log(
  `contract-met: OK — ${closing.map((n) => `#${n}`).join(", ")} criteria met or evidenced`
);
process.exit(0);
