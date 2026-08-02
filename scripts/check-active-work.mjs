#!/usr/bin/env node
/**
 * check-active-work.mjs — claim-isolation sensor for CI (docs/05, issue #55)
 *
 * Intended to run on pull_request in the target repo's gibson-gate workflow.
 * Refuses a PR that edits another live claim's row or claim file, so two
 * concurrent lanes cannot silently overwrite each other.
 *
 * This script is deliberately tolerant: if docs/claims/ or the older
 * docs/active-work.md do not exist, it exits 0. Missing claim infrastructure
 * is not a gate failure; a conflicting edit of a live claim is.
 */

import { execSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const EVENT = process.env.GITHUB_EVENT_NAME || "";
if (EVENT && EVENT !== "pull_request") {
  console.log("check-active-work: not a pull_request event — skipping");
  process.exit(0);
}

const base = process.env.GITHUB_BASE_REF || "main";
const head = process.env.GITHUB_HEAD_REF || "HEAD";

function sh(cmd) {
  try {
    return execSync(cmd, { encoding: "utf8" }).trim();
  } catch {
    return "";
  }
}

const changed = sh(
  `git diff --name-only origin/${base}...${head} 2>/dev/null || git diff --name-only ${base}...HEAD 2>/dev/null`
)
  .split("\n")
  .filter(Boolean);

if (changed.length === 0) {
  console.log("check-active-work: no changed files detected — ok");
  process.exit(0);
}

const claimFiles = changed.filter(
  (f) => f.startsWith("docs/claims/") && f.endsWith(".md")
);
const touchesActiveWork = changed.includes("docs/active-work.md");

if (claimFiles.length === 0 && !touchesActiveWork) {
  console.log("check-active-work: PR does not touch claim ledger — ok");
  process.exit(0);
}

const liveClaimIds = new Set();

if (existsSync("docs/claims")) {
  for (const name of readdirSync("docs/claims")) {
    if (name.endsWith(".md") && name.startsWith("issue-")) {
      liveClaimIds.add(name.replace(/\.md$/, ""));
    }
  }
}

if (existsSync("docs/active-work.md")) {
  const table = readFileSync("docs/active-work.md", "utf8");
  for (const line of table.split("\n")) {
    const m = line.match(/\|\s*(issue-\d+-[a-z0-9-]+)\s*\|/i);
    if (m) liveClaimIds.add(m[1]);
  }
}

let violations = 0;

for (const f of claimFiles) {
  const id = f.replace(/^docs\/claims\//, "").replace(/\.md$/, "");
  const existedOnBase = sh(`git cat-file -e origin/${base}:${f} 2>/dev/null && echo yes || true`);
  if (existedOnBase === "yes" && liveClaimIds.has(id)) {
    console.error(
      `check-active-work: PR mutates live claim file ${f} (claim ${id}). ` +
        `Only the lane that owns the claim may edit it. Coordinate or release first (docs/05).`
    );
    violations++;
  }
}

if (touchesActiveWork) {
  if (liveClaimIds.size > 0) {
    console.error(
      "check-active-work: PR edits docs/active-work.md while other claims are live. " +
        "Prefer docs/claims/<id>.md (one file per claim). Concurrent table edits race (L-023)."
    );
    violations++;
  } else {
    console.log(
      "check-active-work: docs/active-work.md touched but no other live claims — allowed"
    );
  }
}

if (violations > 0) {
  console.error(`check-active-work: ${violations} claim-isolation violation(s)`);
  process.exit(1);
}

console.log("check-active-work: claim isolation ok");
process.exit(0);
