#!/usr/bin/env node
/**
 * check-active-work.mjs — claim-isolation sensor for CI (docs/05, issue #55)
 *
 * Intended to run on pull_request in the target repo's gibson-gate workflow.
 * Refuses a PR that edits *someone else's* live claim, so two concurrent lanes
 * cannot silently overwrite each other.
 *
 * It compares base against head rather than reading the working tree, because
 * the normal Law 2 operation — append your own claim row / add your own claim
 * file — is indistinguishable from a conflicting edit if you only look at the
 * checked-out state. Appending is allowed; touching a row or file that already
 * existed on the base is not.
 *
 * Fails loudly when the base ref cannot be resolved. A sensor that cannot see
 * the diff reports that fact and exits non-zero; it does not print "no changed
 * files" and hand the PR a green check it never earned (issue #55). Requires
 * enough history to reach the merge base — `fetch-depth: 0` in ci/gibson-gate.yml.
 *
 * Still deliberately tolerant of missing claim infrastructure: a repo with
 * neither docs/claims/ nor docs/active-work.md passes. Missing infrastructure is
 * not a gate failure; a conflicting edit of a live claim is.
 */

import { execFileSync } from "node:child_process";

const log = (msg) => console.log(`check-active-work: ${msg}`);
const err = (msg) => console.error(`check-active-work: ${msg}`);

function die(msg) {
  err(msg);
  process.exit(1);
}

const EVENT = process.env.GITHUB_EVENT_NAME || "";
if (EVENT && EVENT !== "pull_request") {
  log("not a pull_request event — skipping");
  process.exit(0);
}

/**
 * Argument-based, never shell-interpolated: refs and paths here come from the
 * PR (GITHUB_BASE_REF, GITHUB_HEAD_REF, changed filenames), and a branch named
 * `;rm -rf /` must stay a bad ref rather than becoming a command (docs/08).
 */
function git(args, { allowFail = false } = {}) {
  try {
    return execFileSync("git", args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch (cause) {
    if (allowFail) return null;
    die(`git ${args.join(" ")} failed: ${(cause.stderr || cause.message || "").toString().trim()}`);
    return null; // unreachable; die() exits
  }
}

const rev = (ref) => {
  const out = git(["rev-parse", "--verify", "--quiet", `${ref}^{commit}`], { allowFail: true });
  return out ? out.trim() : null;
};

const shallow = (git(["rev-parse", "--is-shallow-repository"], { allowFail: true }) || "").trim() === "true";
const DEPTH_HINT =
  "Give the gate job enough history to reach the merge base " +
  "(actions/checkout `fetch-depth: 0`, and fetch the base branch) — see ci/gibson-gate.yml.";

const headSha = rev("HEAD");
if (!headSha) die(`cannot resolve HEAD in this checkout. ${DEPTH_HINT}`);

const baseRef = process.env.GITHUB_BASE_REF || "main";
const headRef = process.env.GITHUB_HEAD_REF || "";

let baseSha = null;
let baseName = null;
for (const candidate of [`origin/${baseRef}`, `refs/remotes/origin/${baseRef}`, baseRef]) {
  const sha = rev(candidate);
  if (sha) {
    baseSha = sha;
    baseName = candidate;
    break;
  }
}
if (!baseSha) {
  die(
    `cannot resolve the base ref '${baseRef}' (tried origin/${baseRef}, ` +
      `refs/remotes/origin/${baseRef}, ${baseRef}${shallow ? "; this checkout is shallow" : ""}). ` +
      `Refusing to report "no changed files" from a diff that never ran. ${DEPTH_HINT}`
  );
}

// The merge base, not the base tip: on a pull_request event the checkout is the
// merge commit, and diffing against a moved base tip would attribute other
// lanes' commits to this PR.
const mergeBaseOut = git(["merge-base", baseSha, headSha], { allowFail: true });
const diffBase = mergeBaseOut ? mergeBaseOut.trim() : null;
if (!diffBase) {
  die(
    `no merge base between ${baseName} (${baseSha.slice(0, 12)}) and HEAD (${headSha.slice(0, 12)})` +
      `${shallow ? " — this checkout is shallow" : ""}. ${DEPTH_HINT}`
  );
}

const changed = git(["diff", "--name-only", diffBase, headSha])
  .split("\n")
  .map((f) => f.trim())
  .filter(Boolean);

log(`comparing ${baseName} (${diffBase.slice(0, 12)}) → HEAD (${headSha.slice(0, 12)}): ${changed.length} changed file(s)`);

const claimFiles = changed.filter((f) => f.startsWith("docs/claims/") && f.endsWith(".md"));
const touchesActiveWork = changed.includes("docs/active-work.md");

if (claimFiles.length === 0 && !touchesActiveWork) {
  log("PR does not touch the claim ledger — ok");
  process.exit(0);
}

/** File content at a commit, or null when the path does not exist there. */
const fileAt = (ref, path) => git(["show", `${ref}:${path}`], { allowFail: true });

const CLAIM_ID = /^issue-[a-z0-9][a-z0-9-]*$/i;

/**
 * Claim rows keyed by claim id. The legacy table is `| UTC | claim | scope |
 * session |` (playbooks/adopt.md), but the id is located by shape rather than by
 * column index so a repo that added a column still gets checked.
 */
function claimRows(text) {
  const rows = new Map();
  if (text == null) return rows;
  for (const line of text.split("\n")) {
    if (!line.trim().startsWith("|")) continue;
    const cells = line.split("|").map((c) => c.trim());
    const id = cells.find((c) => CLAIM_ID.test(c));
    if (!id) continue;
    rows.set(id.toLowerCase(), cells.join(" | "));
  }
  return rows;
}

/** docs/05: a claim file records the lane's `branch:`. That is the ownership proof. */
function claimBranch(text) {
  if (text == null) return null;
  for (const line of text.split("\n")) {
    const m = line.match(/^branch:\s*(\S+)\s*$/);
    if (m) return m[1];
  }
  return null;
}

const violations = [];

for (const f of claimFiles) {
  const baseContent = fileAt(diffBase, f);
  if (baseContent === null) {
    log(`${f} is new on this branch — allowed (Law 2: claim before you touch)`);
    continue;
  }
  const headContent = fileAt(headSha, f);
  if (headContent === baseContent) continue; // renamed-into, mode change, etc.

  // The one precise ownership mechanism the doctrine gives us: the claim file
  // recorded on the BASE names the branch that owns it, so head cannot forge it.
  const owner = claimBranch(baseContent);
  if (owner && headRef && owner === headRef) {
    log(`${f} is owned by this PR's branch (${headRef}) per its own claim record — allowed`);
    continue;
  }
  const verb = headContent === null ? "deletes" : "modifies";
  violations.push(
    `PR ${verb} live claim file ${f}${owner ? ` (owned by branch ${owner})` : ""}. ` +
      `Only the lane that owns the claim may touch it; release it with ` +
      `scripts/release-claim.sh on main, not through this PR (docs/05).`
  );
}

if (touchesActiveWork) {
  const baseRows = claimRows(fileAt(diffBase, "docs/active-work.md"));
  const headRows = claimRows(fileAt(headSha, "docs/active-work.md"));

  for (const [id, row] of baseRows) {
    if (!headRows.has(id)) {
      violations.push(
        `PR removes pre-existing claim row ${id} from docs/active-work.md. ` +
          `Release a claim with scripts/release-claim.sh on main (docs/05), not by editing another lane's row.`
      );
    } else if (headRows.get(id) !== row) {
      violations.push(
        `PR modifies pre-existing claim row ${id} in docs/active-work.md. ` +
          `Concurrent table edits race (L-023) — append your own row, never rewrite someone else's.`
      );
    }
  }

  const appended = [...headRows.keys()].filter((id) => !baseRows.has(id));
  if (appended.length > 0) {
    log(`docs/active-work.md appends ${appended.length} new claim row(s): ${appended.join(", ")} — allowed (Law 2)`);
  }
  if (appended.length === 0 && baseRows.size === 0) {
    log("docs/active-work.md touched but carries no claim rows on either side — allowed");
  }
}

if (violations.length > 0) {
  for (const v of violations) err(v);
  die(`${violations.length} claim-isolation violation(s)`);
}

log("claim isolation ok");
process.exit(0);
