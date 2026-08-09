#!/usr/bin/env node
/**
 * scope-overlap.mjs — independent-set check over the claim ledger (#106)
 *
 * WHAT IT DOES
 *   Given a proposed claim scope (path/glob tokens) and the live claim ledger
 *   on origin/main (docs/claims/*.md + legacy active-work.md rows), refuses
 *   when the proposed scope overlaps any live claim's scope. Overlap is
 *   path/glob prefix and reciprocal stem matching — the founding clobber class
 *   (L-001 / L-023).
 *
 * WHY
 *   claim.sh already had a thin stem-grep; this extracts a deterministic sensor
 *   with fail-closed remote ledger reads and CI reuse via check-active-work /
 *   claim path.
 *
 * RISKS
 *   - Glob matching is prefix/stem based, not a full gitignore engine.
 *   - Failed fetch of origin refuses (fail closed); never uses a stale local ref.
 *   - Read-only against the ledger; never mutates claims.
 *   - Every ledger read fails CLOSED and keeps "the query failed" apart from
 *     "the path is absent": a failed ls-tree/show over docs/claims/ or
 *     docs/active-work.md refuses the decision instead of becoming an empty
 *     ledger, and a live claim (per-file or legacy row) whose scope metadata is
 *     missing, empty, duplicated, or truncated poisons the decision instead of
 *     becoming a scope that collides with nothing.
 *
 * USAGE
 *   node scripts/scope-overlap.mjs --scope 'app/api/**' [--scope 'lib/x.ts'] \
 *     [--repo-path PATH] [--base main|master] [--slice] [--claim-id ID] \
 *     [--admit-pr N] [--json]
 *   node scripts/scope-overlap.mjs --help
 *
 * ADMISSION MODE (--admit-pr N, #153 review P1)
 *   The pre-create check is inherently a TOCTOU read: two lanes claiming
 *   different issues with overlapping scope can both read an inventory that
 *   does not yet contain the other, both pass, and both survive. --admit-pr
 *   runs the SAME overlap check *after* this lane's claim PR exists, and
 *   decides admission deterministically:
 *     - this lane's own claim (--claim-id on PR #N) must be visible in the
 *       authoritative inventory, or the answer is refuse (fail closed: an
 *       inventory that cannot see us cannot be used to admit us);
 *     - without --slice, another live claim on the SAME issue refuses this
 *       lane unless it holds a strictly higher PR number (L-028: one issue is
 *       one claim, even when the two scopes never touch);
 *     - an overlapping live PR-body claim on a LOWER PR number wins — PR
 *       numbers are assigned by GitHub, unique and monotonic, so both racers
 *       compute the same winner from the same evidence, with no lock and no
 *       shared file to leak. That is the tie-break, not a durability claim:
 *       this sensor is read-only and leaves nothing behind itself, but a lane
 *       that dies still leaves ITS OWN artifacts — an open draft claim PR, the
 *       agent-claimed label, a pushed branch, a worktree. claim.sh rolls those
 *       back from an EXIT trap, which does not run under SIGKILL or power
 *       loss; claim-reaper.sh and docs/troubleshooting/claim-conflicts.md are
 *       how a killed lane's leftovers actually get cleared;
 *     - an overlapping claim on a HIGHER PR number yields to us (that lane
 *       refuses itself on its own admission pass);
 *     - an overlapping ledger claim always wins (it is not part of this race).
 *
 *   THE PUBLICATION BARRIER LIVES HERE (#153 review round 3, P1/P3)
 *   Admission never decides on a single sample. This process takes the live
 *   reads itself, through the pr-claims.sh sitting next to it on disk, and
 *   only decides once the claim-relevant projection of the inventory has come
 *   back IDENTICAL on N consecutive spaced reads that all contain this lane's
 *   own claim. It deliberately does NOT accept an inventory handed in by its
 *   caller: any such option is a forged-evidence path — a caller could pass a
 *   fabricated empty or self-only inventory and be admitted over a live
 *   conflicting claim. There is no way to make a file/stdin handoff
 *   unforgeable without a shared secret, so the handoff is gone and the reads
 *   happen where the decision happens.
 *
 *   The barrier has a PRODUCTION FLOOR that callers may raise and may not
 *   lower (see ADMIT_FLOOR): at least 2 consecutive matching reads spaced at
 *   least 1 second apart. An out-of-range GIBSON_CLAIM_ADMIT_* value is a
 *   usage error, not a silent clamp — there is no supported way to switch the
 *   barrier off.
 *
 * EXIT
 *   0  no overlap (or empty proposed scope with no live claims)
 *   1  overlap / fetch failure / unreadable ledger / admission refused
 *   2  usage
 */

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// --- production floor for the publication barrier (#153 review round 3, P1)
// These are the SMALLEST values production will run with. GIBSON_CLAIM_ADMIT_*
// may raise them; nothing may lower them, and there is no documented knob that
// switches the barrier off. `stableReads: 1` would decide on a single sample —
// exactly the pre-repair behaviour a rival publishing a moment later defeats —
// and `delaySeconds: 0` would take that sample twice in the same instant,
// which proves nothing about whether a rival has finished publishing.
//
// The wait itself is INTERNAL (see spaceReads): production does not execute a
// `sleep` binary resolved through the caller's PATH, so there is no command
// shim that can accelerate or neutralise the barrier from the environment. A
// sensor that needs the wait to be free runs an explicitly patched TEST COPY
// of this file; a sensor that tests the barrier itself pays the real minimum.
const ADMIT_FLOOR = {
  attempts: 2,
  stableReads: 2,
  delaySeconds: 1,
};
const ADMIT_DEFAULT = {
  attempts: 6,
  stableReads: 2,
  delaySeconds: 2,
};
// --- documented upper bounds (#153 review round 4, P2) ---------------------
// A floor alone leaves the other end open, and "as large as you like" is not
// a real contract for a value that drives a bounded wait and a bounded loop.
// `Number("1".repeat(400))` is Infinity and `MAX_SAFE_INTEGER + 1` silently
// loses precision, so both would have produced an unbounded or nonsensical
// barrier: an admission pass that never finishes is a claim attempt that
// never finishes, and a lane wedged forever inside its own admission check is
// worse than a refusal — it holds a live claim PR while making no progress.
//
// These maxima are deliberately conservative and chosen so that the WORST
// case stays operationally bounded: the barrier waits at most
// (attempts - 1) x delaySeconds, i.e. 59 x 60 = 3540s (59 minutes) at the
// extremes. Anything past that is a configuration mistake, not a patience
// setting, and is refused as a usage error the same way a below-floor value
// is. The defaults (6 / 2 / 2) are unchanged and sit far inside this range.
const ADMIT_MAX = {
  attempts: 60,
  stableReads: 30,
  delaySeconds: 60,
};

function help() {
  console.log(`scope-overlap.mjs — claim scope independent-set check (#106)

WHAT IT DOES
  Compares a proposed scope against every live claim on origin/<base>.
  Overlap → exit 1 with the colliding claim id and paths.

WHY
  Two lanes claiming overlapping paths is the founding clobber (L-001).
  A sensor that reads a stale local ref is worse than no sensor.

RISKS
  Prefix/stem glob heuristics — not a full gitignore matcher.
  Failed origin fetch refuses (fail closed). Read-only.
  --repo also pulls live open PR-body claims via pr-claims.sh (gh). Malformed,
  truncated, duplicate, foreign-repo, or unreadable PR-claim evidence refuses
  (#153) — never silently falls back to ledger-only when --repo was given.
  A missing/empty claim scope, a missing/unsafe head branch, an unreadable
  repository-identity column, or a PR URL whose own repository does not match
  --repo also refuses — a missing scope must never silently become an empty
  (non-overlapping) scope.
  Every current-format claim-scope TOKEN must parse under the documented
  grammar: '**' (the whole repository) or a path of plain segments with an
  optional trailing '*'/'**' — 'lib/email.ts', 'app/api/auth/**'. Tokens like
  '*', '/', '../x' or 'a//b' normalise to nothing, so they used to collide
  with nothing; they now refuse. '**' is honoured as a real root-wide scope
  and overlaps EVERY path. A token this tool cannot normalise (from a ledger
  row or from --scope) is treated as overlapping rather than as disjoint.
  The LEDGER reads fail closed the same way: a failed ls-tree/show over
  docs/claims/ or docs/active-work.md refuses rather than becoming an empty
  ledger, and a live per-file claim or legacy row whose scope is missing,
  empty, duplicated, or truncated poisons the decision rather than becoming a
  scope that collides with nothing.

USAGE
  node scripts/scope-overlap.mjs --scope 'app/api/**' --repo-path .
  node scripts/scope-overlap.mjs --scope 'a/**' --scope 'b.ts' --json
  node scripts/scope-overlap.mjs --scope 'a/**' --repo owner/name
  node scripts/scope-overlap.mjs --help

FLAGS
  --scope S       proposed scope token (repeatable; space-split also accepted)
  --repo-path P   git repo root (default: cwd)
  --base B        main or master (default: auto)
  --slice         allow same-issue sibling only when scopes are disjoint
  --claim-id ID   claim being created (excluded from overlap with itself)
  --issue N       issue number (for same-issue detection with --slice)
  --repo O/N      GitHub owner/name — also checks live open PR-body claims
                  (#153). Omit to check the ledger only (legacy behavior).
  --admit-pr N    post-create admission for this lane's own claim PR #N:
                  requires --repo, --claim-id and --issue. Waits for the live
                  inventory to go QUIESCENT (identical claim-relevant rows on
                  several consecutive spaced reads, all containing this claim),
                  then refuses on a same-issue claim (without --slice) or an
                  overlapping claim that holds a LOWER PR number. There is no
                  option to supply the inventory: admission reads it here, so a
                  caller cannot hand in a fabricated one.
  --json          machine-readable result

ENV (admission mode only — these may RAISE the barrier, never lower it)
  GIBSON_CLAIM_ADMIT_ATTEMPTS       most reads before giving up
                                    (default ${ADMIT_DEFAULT.attempts}, min ${ADMIT_FLOOR.attempts}, max ${ADMIT_MAX.attempts})
  GIBSON_CLAIM_ADMIT_STABLE_READS   consecutive identical reads required
                                    (default ${ADMIT_DEFAULT.stableReads}, min ${ADMIT_FLOOR.stableReads}, max ${ADMIT_MAX.stableReads})
  GIBSON_CLAIM_ADMIT_DELAY          seconds between reads
                                    (default ${ADMIT_DEFAULT.delaySeconds}, min ${ADMIT_FLOOR.delaySeconds}, max ${ADMIT_MAX.delaySeconds})
  A value below the floor or above the maximum is a usage error, not a silent
  clamp, and so is anything that is not a finite safe integer. The maxima keep
  a claim attempt operationally bounded: the barrier waits at most
  (attempts - 1) x delay, i.e. ${(ADMIT_MAX.attempts - 1) * ADMIT_MAX.delaySeconds}s at the extremes. Running out of
  attempts refuses the claim; it never admits it on an unsettled view.
  The spacing between reads is an internal timer, not a PATH-resolved 'sleep'
  command, and the wait is MEASURED against the monotonic clock rather than
  trusted: a blocking primitive that returns without blocking (e.g. via an
  inherited NODE_OPTIONS '--import' payload) fails the barrier closed instead
  of collapsing it. claim.sh additionally strips NODE_OPTIONS from this
  process. Neither defends against an operator who can edit this file or
  replace node; both stop INHERITED runtime configuration from turning a
  configured fail-closed barrier into a successful immediate read.
`);
}

const argv = process.argv.slice(2);
if (argv.includes("-h") || argv.includes("--help") || argv.length === 0) {
  help();
  process.exit(argv.includes("-h") || argv.includes("--help") ? 0 : 2);
}

function parseArgs(a) {
  const out = {
    scopes: [],
    repoPath: process.cwd(),
    base: null,
    slice: false,
    claimId: null,
    issue: null,
    json: false,
    repo: null,
    admitPr: null,
  };
  for (let i = 0; i < a.length; i++) {
    const x = a[i];
    if (x === "--scope") {
      const v = a[++i];
      if (!v) dieUsage("--scope requires a value");
      out.scopes.push(...v.split(/\s+/).filter(Boolean));
    } else if (x === "--repo-path") out.repoPath = resolve(a[++i] || "");
    else if (x === "--base") out.base = a[++i];
    else if (x === "--slice") out.slice = true;
    else if (x === "--claim-id") out.claimId = a[++i];
    else if (x === "--issue") out.issue = String(a[++i] || "");
    else if (x === "--repo") out.repo = a[++i];
    else if (x === "--admit-pr") out.admitPr = String(a[++i] || "");
    else if (x === "--json") out.json = true;
    else dieUsage(`unknown argument: ${x}`);
  }
  return out;
}

function dieUsage(msg) {
  console.error(`scope-overlap: ${msg}`);
  process.exit(2);
}

const opt = parseArgs(argv);
if (!opt.scopes.length) dieUsage("at least one --scope is required");
// owner/name only — a malformed --repo is untrusted/foreign-repo evidence,
// never silently ignored (#153 AC2).
if (opt.repo != null && !/^[^\s/]+\/[^\s/]+$/.test(opt.repo)) {
  dieUsage(`--repo must be 'owner/name', got '${opt.repo}'`);
}
// --- admission mode + its publication barrier ------------------------------
let admitBarrier = null;
if (opt.admitPr != null) {
  if (!/^[0-9]+$/.test(opt.admitPr)) {
    dieUsage(`--admit-pr must be a pull-request number, got '${opt.admitPr}'`);
  }
  if (!opt.repo) dieUsage("--admit-pr requires --repo owner/name");
  if (!opt.claimId) dieUsage("--admit-pr requires --claim-id");
  // Same-issue exclusivity is decided here too (#153 review P1 0B), and it
  // cannot be decided without knowing which issue this lane is claiming.
  if (!opt.issue || !/^[0-9]+$/.test(opt.issue)) {
    dieUsage("--admit-pr requires --issue <number> (same-issue exclusivity is decided on the admission inventory)");
  }
  opt.admitPr = Number(opt.admitPr);
  admitBarrier = readAdmitBarrier();
}

/**
 * The barrier's settings, floored. Callers may raise; nothing lowers. A value
 * outside the supported range is refused rather than clamped: silently
 * clamping would let a caller believe it had switched the barrier off, and
 * silently honouring it would actually switch it off.
 */
function readAdmitBarrier() {
  const read = (name, def, floor, max) => {
    const raw = process.env[name];
    if (raw == null || raw === "") return def;
    // Shape first. `^[0-9]+$` alone is not enough: it happily accepts a
    // 400-digit literal, which Number() turns into Infinity, and it accepts
    // MAX_SAFE_INTEGER + 1, which Number() rounds to a neighbouring value.
    // Either would give a barrier whose arithmetic no longer means what the
    // operator typed (#153 review round 4, P2).
    if (!/^[0-9]+$/.test(raw)) {
      dieUsage(`${name} must be a non-negative integer, got '${raw}'`);
    }
    const v = Number(raw);
    if (!Number.isSafeInteger(v)) {
      dieUsage(
        `${name}='${raw}' is not a finite safe integer (values above ${Number.MAX_SAFE_INTEGER} lose precision or become Infinity) — refuse rather than run the publication barrier on a number that does not mean what it says.`
      );
    }
    if (v < floor) {
      dieUsage(
        `${name}=${v} is below the production minimum of ${floor} — the publication barrier cannot be weakened or switched off from the environment (#153). Raise it, or leave it unset.`
      );
    }
    if (v > max) {
      dieUsage(
        `${name}=${v} is above the documented maximum of ${max} — the publication barrier must stay operationally bounded (a claim attempt that never finishes holds a live claim PR while making no progress). Lower it, or leave it unset.`
      );
    }
    return v;
  };
  const stableReads = read(
    "GIBSON_CLAIM_ADMIT_STABLE_READS",
    ADMIT_DEFAULT.stableReads,
    ADMIT_FLOOR.stableReads,
    ADMIT_MAX.stableReads
  );
  const delaySeconds = read(
    "GIBSON_CLAIM_ADMIT_DELAY",
    ADMIT_DEFAULT.delaySeconds,
    ADMIT_FLOOR.delaySeconds,
    ADMIT_MAX.delaySeconds
  );
  const attempts = read(
    "GIBSON_CLAIM_ADMIT_ATTEMPTS",
    ADMIT_DEFAULT.attempts,
    ADMIT_FLOOR.attempts,
    ADMIT_MAX.attempts
  );
  if (attempts < stableReads) {
    dieUsage(
      `GIBSON_CLAIM_ADMIT_ATTEMPTS (${attempts}) cannot be smaller than GIBSON_CLAIM_ADMIT_STABLE_READS (${stableReads}) — that barrier could never be satisfied and every claim would refuse`
    );
  }
  return { attempts, stableReads, delaySeconds };
}

/**
 * git for the queries where a failure and an empty answer mean the same thing
 * to the caller — `rev-parse --verify --quiet`, `show-ref --quiet` — so null
 * is an honest "no". Never use this for a LEDGER read: use gitResult below,
 * which keeps the two apart.
 */
function git(args) {
  try {
    return execFileSync("git", args, {
      cwd: opt.repoPath,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 16 * 1024 * 1024,
    });
  } catch {
    return null;
  }
}

/**
 * git, with the FAILURE kept distinguishable from the ANSWER (#153 review
 * round 4, P1).
 *
 * `git()` above collapses "the command failed" and "the command succeeded and
 * printed nothing" into the same `null`. For the ledger reads that decide
 * whether anyone else already holds these paths, that collapse is the whole
 * bug: a broken object store, a bad ref, a permissions failure, or a git that
 * is not there at all all produced `null`, `null` was falsy, and the sensor
 * carried on with an EMPTY ledger — i.e. "nobody has claimed anything", which
 * is the single most dangerous wrong answer this tool can give. An unreadable
 * ledger is not an empty one; it must refuse the admission decision outright.
 *
 * Returns { ok: true, out } or { ok: false, err }.
 */
function gitResult(args) {
  try {
    return {
      ok: true,
      out: execFileSync("git", args, {
        cwd: opt.repoPath,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        maxBuffer: 16 * 1024 * 1024,
      }),
    };
  } catch (e) {
    const stderr = e && e.stderr ? String(e.stderr).trim() : "";
    return {
      ok: false,
      err: stderr || (e && e.message) || String(e),
    };
  }
}

function fail(msg, extra = {}) {
  if (opt.json) {
    console.log(JSON.stringify({ ok: false, error: msg, ...extra }, null, 2));
  } else {
    console.error(`scope-overlap: ERROR: ${msg}`);
  }
  process.exit(1);
}

function ok(payload) {
  if (opt.json) {
    console.log(JSON.stringify({ ok: true, ...payload }, null, 2));
  } else {
    console.log(
      `scope-overlap: OK (${payload.liveClaims} live claim(s); no overlap)`
    );
  }
  process.exit(0);
}

// --- resolve remote ledger ref (fail closed) ---
if (!existsSync(resolve(opt.repoPath, ".git")) && !existsSync(resolve(opt.repoPath, ".git"))) {
  // worktree .git may be a file
}
const gitDir = git(["rev-parse", "--git-dir"]);
if (!gitDir) fail(`not a git repo: ${opt.repoPath}`);

let base = opt.base;
if (!base) {
  if (git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/main"]) !== null ||
      git(["rev-parse", "--verify", "--quiet", "origin/main"])) {
    base = "main";
  } else if (git(["rev-parse", "--verify", "--quiet", "origin/master"])) {
    base = "master";
  } else {
    base = "main";
  }
}

// AC3: fetch origin; failure REFUSES — never fall back to local-only tip.
const fetch = (() => {
  try {
    execFileSync("git", ["fetch", "origin", base], {
      cwd: opt.repoPath,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return true;
  } catch {
    return false;
  }
})();
if (!fetch) {
  fail(
    `cannot fetch origin/${base} — refuse (no local/stale fallback; #106 AC3)`
  );
}

const ref = `origin/${base}`;
const tip = git(["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
if (!tip) {
  fail(`cannot resolve ${ref} after fetch — refuse (fail closed)`);
}

// --- load live claims (fail closed, #153 review round 4, P1) ---------------
// Every read below distinguishes three outcomes, because only one of them
// licenses a claim:
//   * the query FAILED           → unreadable ledger → refuse the decision
//   * the path is genuinely ABSENT → a real empty ledger → continue
//   * the path is present         → its content must then parse as a claim
// The previous version could not tell the first two apart (`git()` returns
// null for both) and treated failure as absence, so a broken object store read
// as "no live claims" and admitted a lane straight over someone else's work.
function loadClaims() {
  const claims = []; // { id, scope: string[], issue?: string }

  // --- docs/claims/*.md -----------------------------------------------------
  // `git ls-tree --name-only <ref> docs/claims/` exits 0 with empty output
  // when the directory simply is not in the tree, and nonzero when the ref or
  // the tree cannot be read. That distinction is the whole point of using
  // gitResult here.
  const tree = gitResult(["ls-tree", "--name-only", ref, "docs/claims/"]);
  if (!tree.ok) {
    fail(
      `cannot enumerate ${ref}:docs/claims/ — an unreadable ledger tree is not an empty ledger; refuse the claim decision: ${tree.err}`
    );
  }
  for (const path of tree.out.split("\n").filter(Boolean)) {
    if (!path.endsWith(".md")) continue;
    const id = path.replace(/^docs\/claims\//, "").replace(/\.md$/, "");
    if (!/^issue-/.test(id)) continue;
    // A claim FILE that is present must be readable and must carry real scope
    // metadata. Anything else is a live claim whose scope we cannot see, and
    // an unseen scope silently becomes a non-overlapping one — the exact way
    // a real claim stops protecting its own files.
    const body = gitResult(["show", `${ref}:${path}`]);
    if (!body.ok) {
      fail(
        `unreadable claim blob ${ref}:${path} — a live claim whose scope cannot be read must not become an empty scope; refuse: ${body.err}`
      );
    }
    const scopeLines = body.out
      .split("\n")
      .filter((l) => /^scope:/.test(l));
    if (scopeLines.length !== 1) {
      fail(
        `claim file ${ref}:${path} has ${scopeLines.length} 'scope:' lines (want exactly 1) — malformed claim metadata must poison the decision, never become an empty scope; refuse`
      );
    }
    const scope = scopeLines[0]
      .replace(/^scope:\s*/, "")
      .trim()
      .split(/\s+/)
      .filter(Boolean);
    if (!scope.length) {
      fail(
        `claim file ${ref}:${path} has an empty 'scope:' value — a live claim with no readable scope must poison the decision, never become a non-overlapping empty scope; refuse`
      );
    }
    const issueM = body.out.match(/^issue:\s*(\d+)/m);
    claims.push({
      id,
      scope,
      issue: issueM ? issueM[1] : null,
      source: "file",
    });
  }

  // --- legacy docs/active-work.md ------------------------------------------
  // Presence first, then content. `git show <ref>:docs/active-work.md` fails
  // both when the path is absent and when its blob is unreadable, so the
  // tree entry is checked separately: absent is a legitimately empty legacy
  // ledger, unreadable is a refusal.
  const tableEntry = gitResult([
    "ls-tree",
    "--name-only",
    ref,
    "--",
    "docs/active-work.md",
  ]);
  if (!tableEntry.ok) {
    fail(
      `cannot look up ${ref}:docs/active-work.md — an unreadable ledger tree is not an absent legacy table; refuse the claim decision: ${tableEntry.err}`
    );
  }
  if (tableEntry.out.trim()) {
    const table = gitResult(["show", `${ref}:docs/active-work.md`]);
    if (!table.ok) {
      fail(
        `cannot read the legacy claim table ${ref}:docs/active-work.md — it exists in the tree but its blob is unreadable; an unreadable table is not an empty one; refuse: ${table.err}`
      );
    }
    for (const line of table.out.split("\n")) {
      if (!/^\|/.test(line)) continue;
      const cols = line.split("|").map((c) => c.trim());
      // | UTC | claim-id | scope | session |  OR older shapes
      // find claim-id column
      let id = null;
      let idIndex = -1;
      for (let i = 0; i < cols.length; i++) {
        if (/^issue-/.test(cols[i])) {
          id = cols[i];
          idIndex = i;
          break;
        }
      }
      if (!id || id === "claim-id" || id === "claim") continue;
      if (claims.some((c) => c.id === id)) continue; // file form wins
      // This row IS a live claim. Validate the shape overlap actually uses:
      // a scope column must exist and must carry at least one token. The old
      // `cols[i + 1] || ""` turned a truncated row — a row where the claim id
      // is the LAST cell — into a claim with an empty scope, which collides
      // with nothing and therefore protects nothing.
      if (idIndex + 1 >= cols.length) {
        fail(
          `legacy claim row for '${id}' in ${ref}:docs/active-work.md is truncated — it has no scope column at all; a live claim with no readable scope must poison the decision, never become an empty scope; refuse`
        );
      }
      const scope = String(cols[idIndex + 1] || "")
        .trim()
        .split(/\s+/)
        .filter(Boolean);
      if (!scope.length) {
        fail(
          `legacy claim row for '${id}' in ${ref}:docs/active-work.md has an empty scope column — a live claim with no readable scope must poison the decision, never become a non-overlapping empty scope; refuse`
        );
      }
      const im = id.match(/^issue-(\d+)-/);
      claims.push({
        id,
        scope,
        issue: im ? im[1] : null,
        source: "legacy",
      });
    }
  }

  return claims;
}

// --- load live open PR-body claims (#153 AC2) ------------------------------
// Reuses pr-claims.sh (the single gh-facing reader) rather than reimplementing
// gh JSON parsing here, so claim.sh, this sensor, and release-claim.sh see the
// exact same live PR-body claim rows. Only runs when --repo was given; a
// caller that omits --repo gets ledger-only behavior (legacy/back-compat).
// The ONE reader, resolved next to this file — never a path a caller names and
// never data a caller supplies. This is the whole trust boundary: the evidence
// is whatever the pr-claims.sh shipped alongside this sensor returns from
// GitHub, with pr-claims.sh's full body/URL/marker validation already applied,
// and the row-shape checks below on top of it.
function prClaimsScriptPath() {
  const p = resolve(__dirname, "pr-claims.sh");
  if (!existsSync(p)) {
    fail(`--repo given but the authoritative reader pr-claims.sh is missing at ${p} — refuse`);
  }
  return p;
}

/** One live read. Returns the raw stdout, or null when the read itself failed. */
function readPrClaimsOnce() {
  try {
    return execFileSync(prClaimsScriptPath(), ["list", opt.repo], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 16 * 1024 * 1024,
    });
  } catch {
    return null;
  }
}

/**
 * Space two reads apart, using a wait that CANNOT be resolved through the
 * caller's environment (#153 review round 4, P1).
 *
 * This used to `execFileSync("sleep", …)`. That resolves an executable named
 * `sleep` through PATH, which means the barrier's entire spacing — the thing
 * that makes a quiescent inventory quiescent — was replaceable by anyone who
 * could put a directory in front of PATH. An executable chosen by the
 * environment IS an execution path, however it is documented, and "sensors
 * shim it" is not a safety property: a hostile or merely careless PATH
 * silently turns the publication barrier into `stableReads` back-to-back
 * samples taken in the same instant, which is exactly the pre-barrier
 * behaviour a rival publishing a moment later defeats.
 *
 * The replacement is `Atomics.wait` on a private SharedArrayBuffer this
 * process just allocated. It is synchronous (this tool has no async path to
 * hand the wait to), dependency-free, blocks the thread for real, and there is
 * no name for anything to interpose on: no PATH lookup, no env var, no child
 * process. Node has permitted Atomics.wait on the main thread since
 * SharedArrayBuffer/Atomics shipped, so it is portable across every Node this
 * repo supports.
 *
 * A delay we could not take is a barrier we did not apply, so anything other
 * than a full-length wait refuses rather than deciding on unspaced samples.
 *
 * TRUSTING THE RETURN VALUE IS NOT ENOUGH (#153 review round 5, P1)
 * `Atomics.wait` has no PATH entry and no env var, but it is still a property
 * on a mutable global, and Node hands the environment a documented way to run
 * code before this file's first line:
 *
 *   NODE_OPTIONS='--import=data:text/javascript,Atomics.wait%3D()%3D%3E"timed-out"'
 *
 * That payload leaves every structural check intact — the floor, the maxima,
 * the quiescence streak, the self-visibility requirement all still run — while
 * the barrier's only actual guarantee, that two reads are separated in TIME,
 * silently becomes free. A configured fail-closed spacing barrier turns into a
 * successful immediate read, which is exactly the pre-barrier behaviour a
 * rival publishing a moment later defeats.
 *
 * So the wait is MEASURED, not trusted: elapsed time is read from the
 * monotonic clock on both sides of the call and the barrier refuses unless the
 * full delay really passed. A single early return is re-waited for the
 * remainder (a legitimate spurious wakeup is allowed to be retried); a
 * primitive that returns instantly exhausts the bounded round budget without
 * accumulating time and fails closed.
 *
 * The honest limit: this does not resist a fully malicious local operator.
 * Anyone who can set NODE_OPTIONS can usually also patch `process.hrtime`,
 * edit this file, or replace `node`. The invariant it does buy is the one that
 * was missing — INHERITED runtime configuration cannot silently turn a
 * configured fail-closed spacing barrier into a successful immediate read. It
 * pairs with claim.sh, which strips NODE_OPTIONS from the sensor process
 * entirely, so production never hands the payload in to begin with.
 */
const WAIT_MAX_ROUNDS = 8;

/**
 * Block for at least `ms` milliseconds and return the monotonic milliseconds
 * actually spent. Never returns early on its own; a caller must still check
 * the returned figure, because a neutered `Atomics.wait` makes every round
 * free and this returns (truthfully) that almost no time passed.
 */
function blockAtLeast(ms) {
  /* GIBSON_BARRIER_WAIT_BEGIN */
  // A fresh 4-byte shared buffer per call, never observable by anything else,
  // so the wait can only ever time out — nothing holds a reference to notify
  // it early.
  const cell = new Int32Array(new SharedArrayBuffer(4));
  const startNs = process.hrtime.bigint();
  let elapsedMs = 0;
  for (let round = 0; round < WAIT_MAX_ROUNDS; round++) {
    const remaining = Math.ceil(ms - elapsedMs);
    if (remaining <= 0) break;
    const verdict = Atomics.wait(cell, 0, 0, remaining);
    if (verdict !== "timed-out") {
      throw new Error(
        `Atomics.wait returned '${verdict}' instead of 'timed-out' — the shared cell this process just allocated cannot legitimately be notified or found already-changed`
      );
    }
    elapsedMs = Number(process.hrtime.bigint() - startNs) / 1e6;
  }
  return elapsedMs;
  /* GIBSON_BARRIER_WAIT_END */
}

function spaceReads(seconds) {
  const ms = seconds * 1000;
  if (!Number.isSafeInteger(ms) || ms <= 0) {
    fail(
      `cannot space the admission reads ${seconds}s apart (unusable delay) — refuse rather than decide on unspaced samples`
    );
  }
  let waitedMs;
  try {
    waitedMs = blockAtLeast(ms);
  } catch (e) {
    fail(
      `cannot space the admission reads ${seconds}s apart — refuse rather than decide on unspaced samples: ${
        (e && e.message) || e
      }`
    );
  }
  // Sub-millisecond slack only, for clock quantisation — never enough to hide
  // a wait that did not happen.
  if (!(waitedMs >= ms - 1)) {
    fail(
      `the admission read spacing did not actually elapse: ${waitedMs.toFixed(
        3
      )}ms of monotonic time passed where ${ms}ms was required, across ${WAIT_MAX_ROUNDS} wait round(s). The blocking primitive returned without blocking${
        process.env.NODE_OPTIONS
          ? ` (NODE_OPTIONS is set in this process: ${JSON.stringify(
              process.env.NODE_OPTIONS
            )} — inherited Node runtime configuration can execute code before this file loads)`
          : ""
      }. Refuse rather than decide on unspaced samples.`
    );
  }
}

/**
 * THE CURRENT-FORMAT SCOPE GRAMMAR (#153 review round 5, P1)
 *
 * A live PR-body claim's `- Claim scope:` value is space-separated tokens, and
 * every token has to survive `stem()` into something the overlap comparison
 * can actually reason about. It did not: `*`, `**`, `/`, `///` and friends all
 * stem to the empty string, and `tokensOverlap` answered "no overlap" for an
 * empty stem. A live claim whose scope was any of those therefore collided
 * with nothing at all — the single most dangerous wrong answer this tool can
 * give, arrived at from a claim that looked perfectly well-formed to
 * pr-claims.sh (nonempty scope marker, valid id, valid branch, valid URL).
 *
 * The grammar below is deliberately narrow and matches the scopes this repo
 * actually issues (`app/api/auth/**`, `lib/email.ts`, `docs/05-concurrency.md`,
 * `components/nav/**`):
 *
 *   token    := ROOT | path
 *   ROOT     := "**"                       the whole repository
 *   path     := literal ("/" literal)* ("/" wild)?
 *   literal  := [A-Za-z0-9_.-]+  and not "." and not ".."
 *   wild     := "*" | "**"
 *
 * i.e. at least one literal segment, no empty segments (so no leading or
 * trailing "/" and no "//"), no parent-directory escapes, and a wildcard only
 * as a whole trailing segment. A bare "*", a bare "/", a leading double-star
 * segment, "a//b", "../x", "*.ts" and a double-star in the middle of a path
 * are all rejected as ambiguous rather than normalised into something that
 * quietly protects less than it says.
 *
 * ROOT ("**") is the one deliberate root-wide scope, and it is SUPPORTED: it
 * overlaps every path rather than overlapping nothing (see tokensOverlap).
 * Refusing it outright would be defensible too, but silently treating "I claim
 * the whole repository" as "I claim nothing" is not.
 */
const ROOT_SCOPE = "**";
const SCOPE_LITERAL = /^[A-Za-z0-9_.-]+$/;

/** null when the token is valid; otherwise the reason it is not. */
function currentScopeTokenProblem(token) {
  if (typeof token !== "string" || token === "") return "empty token";
  if (token === ROOT_SCOPE) return null;
  const segments = token.split("/");
  let literals = 0;
  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i];
    const last = i === segments.length - 1;
    if (seg === "") {
      return "empty path segment (a leading '/', a trailing '/', or '//')";
    }
    if (seg === "*" || seg === "**") {
      if (!last) return `wildcard segment '${seg}' is only allowed as the final segment`;
      continue;
    }
    if (!SCOPE_LITERAL.test(seg)) {
      return `segment '${seg}' is not a plain path segment ([A-Za-z0-9_.-]+) or a trailing '*'/'**'`;
    }
    if (seg === "." || seg === "..") {
      return `segment '${seg}' is a relative-path escape`;
    }
    literals++;
  }
  if (literals === 0) {
    return "no literal path segment — it normalises to nothing and would collide with nothing";
  }
  return null;
}

function parsePrClaims(out) {
  const seen = new Map(); // claim id -> PR number, to catch duplicates
  const claims = [];
  for (const line of out.split("\n")) {
    if (!line.trim()) continue;
    const cols = line.split("\t");
    if (cols.length !== 8) {
      fail(
        `malformed/truncated PR-body claim row from pr-claims.sh (want 8 tab-separated fields, got ${cols.length}): ${JSON.stringify(
          line
        )}`
      );
    }
    const number = cols[0];
    const id = cols[1];
    const scopeStr = cols[2];
    const headBranch = cols[3];
    const url = cols[4];
    const isCrossRepo = cols[7];
    if (!/^\d+$/.test(number)) {
      fail(`malformed PR-body claim row — PR number not numeric: ${JSON.stringify(line)}`);
    }
    if (!id || !/^issue-/.test(id)) {
      fail(`malformed/truncated PR-body claim row — unreadable claim id: ${JSON.stringify(line)}`);
    }
    // A missing scope must never silently become an empty (non-overlapping)
    // scope — that would let a real live claim's files collide undetected.
    if (!scopeStr || !scopeStr.trim()) {
      fail(
        `live PR-body claim '${id}' (PR #${number}) has a missing/empty claim scope — refuse (#153 AC6 fail-closed)`
      );
    }
    if (!headBranch || !/^[A-Za-z0-9._/-]+$/.test(headBranch)) {
      fail(
        `live PR-body claim '${id}' (PR #${number}) has a missing/unsafe head branch '${headBranch}' — refuse (#153 AC6)`
      );
    }
    const urlMatch = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/\d+$/.exec(url || "");
    if (!urlMatch) {
      fail(
        `live PR-body claim '${id}' (PR #${number}) has an unreadable/malformed PR URL '${url}' — refuse (#153 AC6)`
      );
    }
    if (urlMatch[1] !== opt.repo) {
      fail(
        `live PR-body claim '${id}' (PR #${number}) URL repository '${urlMatch[1]}' does not match the requested repo '${opt.repo}' — refuse (unexpected repository identity, #153 AC3)`
      );
    }
    // Repository identity, strictly (#153 review round 5, P1). pr-claims.sh
    // already refuses a row whose isCrossRepository is not a real boolean;
    // this is the row-shape half of the same contract, so a truncated or
    // rewritten column cannot reach the decision as "same repository".
    if (isCrossRepo !== "true" && isCrossRepo !== "false") {
      fail(
        `live PR-body claim '${id}' (PR #${number}) has an unreadable repository-identity column '${isCrossRepo}' (want 'true' or 'false') — refuse (#153 AC3)`
      );
    }
    if (seen.has(id)) {
      fail(
        `duplicate live PR-body claim id '${id}' on PR #${seen.get(id)} and #${number} — refuse (#153 AC2 fail-closed)`
      );
    }
    seen.set(id, number);
    const scope = scopeStr.trim().split(/\s+/).filter(Boolean);
    // Every token must be a scope the overlap comparison can actually reason
    // about, BEFORE it is compared (#153 review round 5, P1). A token that
    // normalises to nothing used to be silently non-overlapping, so a live
    // claim scoped `*` or `/` protected none of its files while looking
    // entirely well-formed. Invalid or ambiguous evidence refuses; it is never
    // dropped, and never quietly narrowed to the tokens that did parse.
    for (const token of scope) {
      const problem = currentScopeTokenProblem(token);
      if (problem) {
        fail(
          `live PR-body claim '${id}' (PR #${number}) has an invalid claim-scope token ${JSON.stringify(
            token
          )}: ${problem}. A scope this tool cannot compare must poison the decision, never become a scope that collides with nothing — refuse (#153 AC6 fail-closed). Valid tokens are '${ROOT_SCOPE}' (the whole repository) or a path like 'lib/email.ts' / 'app/api/auth/**'.`
        );
      }
    }
    claims.push({
      id,
      scope,
      issue: claimIssueNumber(id),
      source: "pr",
      number: Number(number),
      isCrossRepository: isCrossRepo === "true",
    });
  }
  return claims;
}

/**
 * The issue number a claim id carries, under the same shape pr-claims.sh
 * validates (`issue-[<prefix>-]<n>-<slug>`). null when the id yields none — an
 * id whose issue cannot be read is ambiguous evidence, and admission fails
 * closed on it rather than assuming "different issue".
 */
function claimIssueNumber(id) {
  const m = /^issue-(?:[A-Za-z][A-Za-z0-9]*-)?(\d+)-/.exec(id || "");
  return m ? m[1] : null;
}

/**
 * The claim-relevant projection of an inventory: PR number, claim id, scope,
 * order-independent. Two reads that agree on this agree on everything the
 * admission decision uses; unrelated churn (a body edited elsewhere, a
 * timestamp bumped) does not stop the barrier from settling.
 */
function admitFingerprint(claims) {
  return claims
    .map((c) => `${c.number}\t${c.id}\t${c.scope.join(" ")}`)
    .sort()
    .join("\n");
}

/**
 * THE PUBLICATION BARRIER (#153 review P1 0A, relocated here in round 3).
 *
 * Seeing this lane's own claim in the inventory does not prove it can see
 * everyone else's: GitHub's PR list is eventually consistent, so a rival PR
 * created a moment earlier can still be missing from the page served after
 * this lane's own row appears. Deciding there lets both racers admit
 * themselves. So admission decides only on a QUIESCENT inventory — one whose
 * claim-relevant projection came back identical on `stableReads` consecutive
 * spaced reads that all contained this lane's own claim.
 *
 * Bounded, and honest about it: quiescence bounds the race, it does not
 * abolish it. A replica lagging longer than the whole window can still hide a
 * rival, and no client-side read can fix that. Everything outside the window
 * fails CLOSED — an inventory that never settles, or reads that keep failing,
 * exhaust the attempts and the claim is refused, never admitted.
 */
function settleAdmissionInventory() {
  const { attempts, stableReads, delaySeconds } = admitBarrier;
  let prevFp = null;
  let streak = 0;
  let settled = null;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    if (attempt > 1) spaceReads(delaySeconds);
    const out = readPrClaimsOnce();
    if (out == null) {
      streak = 0;
      prevFp = null;
      console.error(
        `scope-overlap: admission: cannot read the live claim inventory for ${opt.repo} (attempt ${attempt}/${attempts})`
      );
      continue;
    }
    // A malformed row is a present, current defect in the authoritative view,
    // not transient lag — refuse outright rather than waiting for it to settle.
    const claims = parsePrClaims(out);
    const self = claims.find(
      (c) => c.id === opt.claimId && c.number === opt.admitPr
    );
    if (!self) {
      // A read that cannot see this claim is not part of any quiescent window
      // this claim may rely on.
      streak = 0;
      prevFp = null;
      console.error(
        `scope-overlap: admission: PR #${opt.admitPr} is not in the live claim inventory yet (attempt ${attempt}/${attempts})`
      );
      continue;
    }
    // The lane being admitted pushed its own branch into --repo, so its own
    // claim PR is same-repository by construction (#153 review round 5, P1).
    // A row that says otherwise is not this lane's PR however well its marker
    // and branch name match, and admitting on it would hand this lane a claim
    // registered against somebody else's repository.
    if (self.isCrossRepository) {
      fail(
        `admission refused for PR #${opt.admitPr}: the inventory row carrying claim '${opt.claimId}' is a cross-repository (fork) pull request, but this lane pushed its branch into ${opt.repo} itself — that row is not this lane's PR. Refuse rather than admit a claim on foreign-repository evidence.`,
        { admitPr: opt.admitPr, claimId: opt.claimId }
      );
    }
    const fp = admitFingerprint(claims);
    streak = streak > 0 && fp === prevFp ? streak + 1 : 1;
    prevFp = fp;
    settled = claims;
    if (streak >= stableReads) {
      if (!opt.json) {
        console.log(
          `scope-overlap: admission: inventory quiescent for PR #${opt.admitPr} (${stableReads} consecutive matching read(s))`
        );
      }
      return settled;
    }
    console.error(
      `scope-overlap: admission: inventory not yet quiescent for PR #${opt.admitPr} (${streak}/${stableReads} matching read(s), attempt ${attempt}/${attempts})`
    );
  }
  fail(
    `admission: could not obtain a stable live-claim inventory for ${opt.repo} containing this lane's own claim '${opt.claimId}' on PR #${opt.admitPr} — ${stableReads} consecutive matching read(s) required, ${attempts} attempt(s) made. An inventory that cannot see this claim, or that is still changing underneath it, cannot prove no one else holds the scope: a rival PR created before this one may simply not have been published to the view yet. Refusing to hold a claim that is not provably registered against a settled view.`,
    { admitPr: opt.admitPr, claimId: opt.claimId }
  );
  return []; // unreachable: fail() exits
}

const prClaims =
  opt.admitPr != null
    ? settleAdmissionInventory()
    : opt.repo
      ? parsePrClaims(readPrClaimsOnceOrFail())
      : [];

function readPrClaimsOnceOrFail() {
  const out = readPrClaimsOnce();
  if (out == null) {
    fail(
      `cannot read live PR-body claims for ${opt.repo} (pr-claims.sh failed) — refuse (#153 AC2 fail-closed)`
    );
  }
  return out;
}

// --- same-issue exclusivity, decided on the quiescent inventory (#153 P1 0B)
// Two lanes on the SAME issue with different slugs and disjoint scopes each
// pass the pre-create duplicate check (neither is published yet) and each pass
// a scope-only re-check — one issue, two builds, which is L-028 through a
// different door. With --slice, same-issue siblings are legal and the scope
// check below is what keeps them disjoint.
if (opt.admitPr != null && !opt.slice) {
  for (const c of prClaims) {
    if (c.id === opt.claimId || c.number === opt.admitPr) continue;
    if (c.issue == null) {
      fail(
        `admission refused for PR #${opt.admitPr}: live claim id '${c.id}' (PR #${c.number}) carries no readable issue number — it cannot be proven not to be a second lane on issue #${opt.issue}`,
        { admitPr: opt.admitPr, claimId: opt.claimId }
      );
    }
    if (String(c.issue) !== String(opt.issue)) continue;
    if (c.number > opt.admitPr) {
      if (!opt.json) {
        console.log(
          `scope-overlap: later same-issue claim ${c.id} (PR #${c.number}) yields to PR #${opt.admitPr}`
        );
      }
      continue;
    }
    fail(
      `admission refused for PR #${opt.admitPr}: issue #${opt.issue} is already held by the live claim ${c.id} (PR #${c.number}), which holds the stronger prior. One issue is one claim (L-028) — two lanes on it means two builds of the same work, even when their scopes do not touch.`,
      { admitPr: opt.admitPr, claimId: opt.claimId, sameIssue: c.id }
    );
  }
}

const live = [...loadClaims(), ...prClaims].filter((c) => c.id !== opt.claimId);

/** Normalize a scope token for comparison. */
function stem(token) {
  // strip trailing ** / * segments for prefix compare
  return token.replace(/\/\*\*$/, "").replace(/\*\*$/, "").replace(/\*$/, "").replace(/\/$/, "");
}

/**
 * True when two scope tokens collide.
 * - either side is the root-wide scope (`**`) — it contains every path
 * - either side normalises to nothing — unreadable, so assume collision
 * - exact match
 * - either is prefix of the other (after stem)
 * - shared path prefix of at least one directory segment
 */
function tokensOverlap(a, b) {
  if (!a || !b) return false;
  // The deliberate root-wide scope (#153 review round 5, P1). `**` stems to
  // the empty string, so it used to fall through to "no overlap": a claim on
  // the entire repository protected nothing. It contains every path, so it
  // overlaps every token — including another `**`.
  if (a === ROOT_SCOPE || b === ROOT_SCOPE) return true;
  if (a === b) return true;
  const sa = stem(a);
  const sb = stem(b);
  // An empty stem means this comparison has no idea what the token covers.
  // Current-format PR claim scopes can no longer get here (they are validated
  // in parsePrClaims), but ledger rows and operator-supplied --scope tokens
  // are not under that grammar, and "I cannot tell" must never be answered as
  // "they do not touch" on a path that decides whether two lanes may run at
  // once. Fail closed: assume they collide.
  if (!sa || !sb) return true;
  if (sa === sb) return true;
  // prefix: app/api vs app/api/auth/**
  if (sa.startsWith(sb + "/") || sb.startsWith(sa + "/")) return true;
  // reciprocal stem containment used by the old claim.sh grep
  if (sa.includes(sb) || sb.includes(sa)) {
    // avoid matching "app" vs "application" — require boundary
    const boundary = (x, y) =>
      x === y ||
      x.startsWith(y + "/") ||
      x.startsWith(y + ".") ||
      y.startsWith(x + "/") ||
      y.startsWith(x + ".");
    if (boundary(sa, sb) || boundary(sb, sa)) return true;
  }
  return false;
}

function scopesOverlap(proposed, existing) {
  const hits = [];
  for (const p of proposed) {
    for (const e of existing) {
      if (tokensOverlap(p, e)) hits.push({ proposed: p, existing: e });
    }
  }
  return hits;
}

const collisions = [];
const yielded = [];
for (const c of live) {
  // same-issue without --slice is claim.sh's job (L-028); we still report
  // scope overlap. With --slice, same-issue is allowed only when disjoint.
  const hits = scopesOverlap(opt.scopes, c.scope);
  if (!hits.length) continue;
  if (
    opt.slice &&
    opt.issue &&
    c.issue &&
    String(c.issue) === String(opt.issue)
  ) {
    // slice on same issue still requires disjoint scopes — hits mean refuse
  }
  // Admission tie-break (#153 review P1): a *later* PR number is a lane that
  // entered the race after us, so it loses on its own admission pass and we
  // must not refuse ourselves over it — otherwise both racers abort and the
  // work is simply lost. Anything else (a lower PR number, or a ledger claim
  // that was never part of this race) beats us.
  if (
    opt.admitPr != null &&
    c.source === "pr" &&
    Number.isInteger(c.number) &&
    c.number > opt.admitPr
  ) {
    yielded.push({ claim: c, hits });
    continue;
  }
  collisions.push({ claim: c, hits });
}

if (collisions.length) {
  const details = collisions.map((col) => ({
    claimId: col.claim.id,
    source: col.claim.source,
    scope: col.claim.scope,
    prNumber: col.claim.number ?? null,
    hits: col.hits,
  }));
  if (opt.json) {
    console.log(
      JSON.stringify(
        {
          ok: false,
          error: opt.admitPr != null ? "admission refused (scope overlap)" : "scope overlap",
          admitPr: opt.admitPr,
          collisions: details,
        },
        null,
        2
      )
    );
  } else {
    for (const col of collisions) {
      const hitStr = col.hits
        .map((h) => `${h.proposed} ↔ ${h.existing}`)
        .join(", ");
      const who =
        col.claim.source === "pr" && Number.isInteger(col.claim.number)
          ? `${col.claim.id} (PR #${col.claim.number})`
          : col.claim.id;
      console.error(
        `scope-overlap: ERROR: ${
          opt.admitPr != null
            ? `admission refused for PR #${opt.admitPr} — it`
            : "proposed scope"
        } overlaps live claim ${who} (${col.claim.source}) scope=[${col.claim.scope.join(" ")}] collisions: ${hitStr}`
      );
    }
  }
  process.exit(1);
}

if (opt.admitPr != null && yielded.length && !opt.json) {
  for (const y of yielded) {
    console.log(
      `scope-overlap: later overlapping claim ${y.claim.id} (PR #${y.claim.number}) yields to PR #${opt.admitPr}`
    );
  }
}

ok({
  liveClaims: live.length,
  proposed: opt.scopes,
  ref: ref.trim(),
  ...(opt.admitPr != null
    ? {
        admitPr: opt.admitPr,
        yielded: yielded.map((y) => ({
          claimId: y.claim.id,
          prNumber: y.claim.number,
        })),
      }
    : {}),
});
