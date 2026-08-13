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
 * Renames are scored as delete + add, and deleting a live claim file is refused
 * even for the lane that owns it: a claim is released on main, not in a PR.
 *
 * Still deliberately tolerant of missing claim infrastructure: a repo with
 * neither docs/claims/ nor docs/active-work.md passes. Missing infrastructure is
 * not a gate failure; a conflicting edit of a live claim is.
 */

import { execFileSync } from "node:child_process";

// inlined from lib/args.mjs — this file must stay single-file (vendored by gibson-gate.yml sparse-checkout)
function dieUsage(msg) {
  console.error(msg);
  process.exit(2);
}

function unknownFlag(flag) {
  dieUsage(`unknown flag: ${flag}`);
}

function rejectUnknownFlags(argv, allowed, opts = {}) {
  const allow = new Set(allowed);
  const valueFlags = new Set(
    opts.valueFlags ||
      [...allow].filter((f) => f !== "-h" && f !== "--help" && f !== "--json")
  );
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

const log = (msg) => console.log(`check-active-work: ${msg}`);
const err = (msg) => console.error(`check-active-work: ${msg}`);

function die(msg) {
  err(msg);
  process.exit(1);
}

// Env-driven (no flags). Still fail closed on typos so a CI misconfig is loud (#192).
const cliArgs = process.argv.slice(2);
if (cliArgs.includes("-h") || cliArgs.includes("--help")) {
  console.log(`check-active-work.mjs — claim-isolation sensor (docs/05, #55)

Driven by GITHUB_* env (pull_request). No flags.
`);
  process.exit(0);
}
rejectUnknownFlags(cliArgs, ["-h", "--help"]);

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

// --no-renames on purpose. With rename detection on, moving
// docs/claims/issue-7-*.md to any other path reports only the DESTINATION, so the
// deletion of a protected base-side claim file never appears in `changed` and the
// gate waves the rename through — whether it lands on another claim id or leaves
// docs/claims/ entirely. Scored as delete + add, the source deletion is visible
// and the destination is judged on its own as a new file.
//
// -z, and nothing is trimmed. Without -z, `git diff --name-only` C-quotes any path
// git considers unusual: every non-ASCII byte under the default core.quotePath,
// plus quotes, backslashes and control characters. `docs/claims/issue-7-café.md`
// then arrives as `"docs/claims/issue-7-caf\303\251.md"`, which does not start with
// `docs/claims/` — so the entire non-ASCII half of the ledger fell out of the
// filter below and was never checked at all. -z emits the raw bytes with a NUL
// terminator instead.
//
// Trimming is equally wrong: leading and trailing spaces, tabs and newlines are
// valid bytes in a filename, and a trimmed path names a different file or no file.
// Only the empty field after the final NUL terminator is dropped.
const changed = git(["diff", "--name-only", "-z", "--no-renames", diffBase, headSha]).split("\0");
if (changed.length > 0 && changed[changed.length - 1] === "") changed.pop();

log(`comparing ${baseName} (${diffBase.slice(0, 12)}) → HEAD (${headSha.slice(0, 12)}): ${changed.length} changed file(s)`);

// Node decodes git's output as UTF-8 and re-encodes every argument it passes back
// as UTF-8, so a path whose bytes are not valid UTF-8 cannot survive the round
// trip: it arrives carrying U+FFFD, and the lookup below then asks about a path
// that is not the one that changed. That reads as "not present on the base — new
// on this branch, allowed (Law 2)" and waves an edit of a live claim through.
// There is no argv encoding this process can use to say otherwise, so the honest
// answer is to refuse the diff rather than to mis-classify it (Law 8).
const undecodable = changed.filter((f) => f.startsWith("docs/claims/") && f.includes("�"));
if (undecodable.length > 0) {
  die(
    `${undecodable.length} changed path(s) under docs/claims/ are not valid UTF-8, so this sensor ` +
      `cannot name them back to git and cannot tell whether they are live claims ` +
      `(first: ${JSON.stringify(undecodable[0])}). Rename them to UTF-8 paths, then re-run. ` +
      `Refusing to classify a claim path the gate cannot address.`
  );
}

const claimFiles = changed.filter((f) => f.startsWith("docs/claims/") && f.endsWith(".md"));
const touchesActiveWork = changed.includes("docs/active-work.md");

if (claimFiles.length === 0 && !touchesActiveWork) {
  log("PR does not touch the claim ledger — ok");
  process.exit(0);
}

/**
 * File content at a commit, or null when the path genuinely does not exist there.
 *
 * Absence is established by asking the commit's tree, never by watching
 * `git show` fail. `show` also fails on a path it cannot READ — a corrupt or
 * pruned object, a partial clone that never fetched the blob, content past
 * maxBuffer — and mapping every one of those to null makes a claim file the
 * sensor cannot read indistinguishable from one that is not there. On the base
 * side that reads as "new on this branch — allowed (Law 2)" and waves the PR
 * through; on the head side it reads as a deletion and accuses the wrong lane.
 * Both are silent, and both are wrong. ls-tree answers presence from a commit
 * this sensor already resolved; any read failure after that dies loudly (Law 8).
 */
const fileAt = (ref, path) => {
  // --full-tree so the pathspec is repo-root-relative like `git show ref:path`,
  // rather than relative to wherever the gate job happened to be invoked from.
  //
  // `:(literal)` because everything after `--` is a PATHSPEC, and a changed path
  // is data, not a pattern. A claim file whose name contains `*`, `?`, `[…]` or a
  // leading `:` would otherwise be matched as a glob or read as pathspec magic —
  // it could answer for a different file, or fail to answer for itself, and a
  // claim path that fails to answer for itself reads as "not on the base — new on
  // this branch, allowed (Law 2)". The literal prefix also survives an inherited
  // GIT_GLOB_PATHSPECS=1, which the `--literal-pathspecs` option does not (git
  // rejects the combination outright).
  const entry = git(["ls-tree", "-z", "--full-tree", "--full-name", ref, "--", `:(literal)${path}`]);
  if (!entry.trim()) return null;
  // `<rev>:<path>` is an object name, not a pathspec — no glob, no magic.
  return git(["show", `${ref}:${path}`]);
};

/**
 * What counts as a legacy claim id, and why it is only a prefix test.
 *
 * scripts/claims-status.sh is the authoritative reader of the legacy table: it
 * trims a cell and keeps it if `grep -qE '^issue-'` matches — any suffix at all.
 * This sensor used to demand /^issue-[a-z0-9][a-z0-9-]*$/, which is strictly
 * narrower, so ids the fleet is told every day are LIVE — `issue-7_password_reset`,
 * `issue-7.1-followup` — were live to claims-status and invisible to the gate.
 * Another lane could rewrite or delete exactly those rows with a green check.
 * The protected set must be a superset of the live set, so the shape matches the
 * authoritative reader (the /i is deliberate over-coverage: claims-status is
 * case-sensitive, and protecting a row it would not print costs nothing).
 */
const CLAIM_ID = /^issue-/i;

/**
 * Claim rows keyed by claim id. The legacy table is `| UTC | claim | scope |
 * session |` (playbooks/adopt.md), but the id is located by shape rather than by
 * column index so a repo that added a column still gets checked.
 *
 * The key keeps the id's case. Folding it would let `issue-7` and `Issue-7` — two
 * distinct rows to claims-status — collide on one map entry, and a collision hides
 * whichever of the two the head rewrote.
 */
function claimRows(text) {
  const rows = new Map();
  if (text == null) return rows;
  for (const line of text.split("\n")) {
    if (!line.trim().startsWith("|")) continue;
    const cells = line.split("|").map((c) => c.trim());
    const id = cells.find((c) => CLAIM_ID.test(c));
    if (!id) continue;
    rows.set(id, cells.join(" | "));
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
  if (headContent === baseContent) continue; // mode change, identical rewrite, etc.

  // The one precise ownership mechanism the doctrine gives us: the claim file
  // recorded on the BASE names the branch that owns it, so head cannot forge it.
  const owner = claimBranch(baseContent);

  // Deletion is checked BEFORE the ownership exemption, deliberately. A claim is
  // released on main with scripts/release-claim.sh (docs/05) so the ledger stops
  // being authoritative only once the work has actually landed; allowing the
  // delete here would let the product PR itself release the claim the moment it
  // merges, bypassing that required release-claim.sh-on-main step. Owning the
  // claim buys the right to renew it, never the right to drop it here. This also
  // catches the delete half of a rename (see --no-renames above), so a lane
  // cannot launder a deletion into a move of its own claim.
  if (headContent === null) {
    violations.push(
      `PR deletes live claim file ${f}${owner ? ` (owned by branch ${owner})` : ""}. ` +
        `A claim is released on main with scripts/release-claim.sh, never by deleting ` +
        `or renaming the file in a PR — owning the claim does not authorize dropping ` +
        `it here (docs/05).`
    );
    continue;
  }

  if (owner && headRef && owner === headRef) {
    log(`${f} is owned by this PR's branch (${headRef}) per its own claim record — allowed`);
    continue;
  }
  violations.push(
    `PR modifies live claim file ${f}${owner ? ` (owned by branch ${owner})` : ""}. ` +
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
