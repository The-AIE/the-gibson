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
 *       compute the same winner from the same evidence, with no lock, no
 *       shared file, and nothing left behind if a lane dies;
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
// Sensors do not lower these. They accelerate the WAIT through the `sleep`
// dependency (a PATH command shim), which changes how long the barrier takes
// and not what it requires, or they run an explicitly patched TEST COPY of
// this file. Neither is reachable from an ordinary inherited environment.
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
  A missing/empty claim scope, a missing/unsafe head branch, or a PR URL whose
  own repository does not match --repo also refuses — a missing scope must
  never silently become an empty (non-overlapping) scope.

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
  GIBSON_CLAIM_ADMIT_ATTEMPTS       most reads before giving up (default ${ADMIT_DEFAULT.attempts}, min ${ADMIT_FLOOR.attempts})
  GIBSON_CLAIM_ADMIT_STABLE_READS   consecutive identical reads required
                                    (default ${ADMIT_DEFAULT.stableReads}, min ${ADMIT_FLOOR.stableReads})
  GIBSON_CLAIM_ADMIT_DELAY          seconds between reads (default ${ADMIT_DEFAULT.delaySeconds}, min ${ADMIT_FLOOR.delaySeconds})
  A value below the floor is a usage error, not a silent clamp. Running out of
  attempts refuses the claim; it never admits it on an unsettled view.
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
  const read = (name, def, floor) => {
    const raw = process.env[name];
    if (raw == null || raw === "") return def;
    if (!/^[0-9]+$/.test(raw)) {
      dieUsage(`${name} must be a non-negative integer, got '${raw}'`);
    }
    const v = Number(raw);
    if (v < floor) {
      dieUsage(
        `${name}=${v} is below the production minimum of ${floor} — the publication barrier cannot be weakened or switched off from the environment (#153). Raise it, or leave it unset.`
      );
    }
    return v;
  };
  const stableReads = read(
    "GIBSON_CLAIM_ADMIT_STABLE_READS",
    ADMIT_DEFAULT.stableReads,
    ADMIT_FLOOR.stableReads
  );
  const delaySeconds = read(
    "GIBSON_CLAIM_ADMIT_DELAY",
    ADMIT_DEFAULT.delaySeconds,
    ADMIT_FLOOR.delaySeconds
  );
  const attempts = read(
    "GIBSON_CLAIM_ADMIT_ATTEMPTS",
    ADMIT_DEFAULT.attempts,
    ADMIT_FLOOR.attempts
  );
  if (attempts < stableReads) {
    dieUsage(
      `GIBSON_CLAIM_ADMIT_ATTEMPTS (${attempts}) cannot be smaller than GIBSON_CLAIM_ADMIT_STABLE_READS (${stableReads}) — that barrier could never be satisfied and every claim would refuse`
    );
  }
  return { attempts, stableReads, delaySeconds };
}

function git(args, { allowFail = false } = {}) {
  try {
    return execFileSync("git", args, {
      cwd: opt.repoPath,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 16 * 1024 * 1024,
    });
  } catch (e) {
    if (allowFail) return null;
    return null;
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
const gitDir = git(["rev-parse", "--git-dir"], { allowFail: true });
if (!gitDir) fail(`not a git repo: ${opt.repoPath}`);

let base = opt.base;
if (!base) {
  if (git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/main"], { allowFail: true }) !== null ||
      git(["rev-parse", "--verify", "--quiet", "origin/main"], { allowFail: true })) {
    base = "main";
  } else if (git(["rev-parse", "--verify", "--quiet", "origin/master"], { allowFail: true })) {
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
const tip = git(["rev-parse", "--verify", "--quiet", `${ref}^{commit}`], {
  allowFail: true,
});
if (!tip) {
  fail(`cannot resolve ${ref} after fetch — refuse (fail closed)`);
}

// --- load live claims ---
function loadClaims() {
  const claims = []; // { id, scope: string[], issue?: string }

  // docs/claims/*.md
  const tree = git(["ls-tree", "--name-only", ref, "docs/claims/"], {
    allowFail: true,
  });
  if (tree) {
    for (const path of tree.split("\n").filter(Boolean)) {
      if (!path.endsWith(".md")) continue;
      const id = path.replace(/^docs\/claims\//, "").replace(/\.md$/, "");
      if (!/^issue-/.test(id)) continue;
      const body = git(["show", `${ref}:${path}`], { allowFail: true });
      if (body == null) {
        fail(`unreadable claim blob ${ref}:${path} — refuse`);
      }
      const scopeLine = (body.match(/^scope:\s*(.+)$/m) || [])[1] || "";
      const scope = scopeLine.trim().split(/\s+/).filter(Boolean);
      const issueM = body.match(/^issue:\s*(\d+)/m);
      claims.push({
        id,
        scope,
        issue: issueM ? issueM[1] : null,
        source: "file",
      });
    }
  }

  // legacy active-work.md
  const table = git(["show", `${ref}:docs/active-work.md`], { allowFail: true });
  if (table) {
    for (const line of table.split("\n")) {
      if (!/^\|/.test(line)) continue;
      const cols = line.split("|").map((c) => c.trim());
      // | UTC | claim-id | scope | session |  OR older shapes
      // find claim-id column
      let id = null;
      let scopeStr = "";
      for (let i = 0; i < cols.length; i++) {
        if (/^issue-/.test(cols[i])) {
          id = cols[i];
          // scope often next non-empty
          scopeStr = cols[i + 1] || "";
          break;
        }
      }
      if (!id || id === "claim-id" || id === "claim") continue;
      if (claims.some((c) => c.id === id)) continue; // file form wins
      const scope = scopeStr.split(/\s+/).filter(Boolean);
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

/** Space two reads apart. A delay we could not take is a barrier we did not
 *  apply, so a failed sleep refuses rather than busy-looping. `sleep` is a PATH
 *  command, which is exactly the seam sensors shim to accelerate the wait
 *  without touching what the barrier requires. */
function spaceReads(seconds) {
  try {
    execFileSync("sleep", [String(seconds)], {
      stdio: ["ignore", "ignore", "ignore"],
    });
  } catch (e) {
    fail(
      `cannot space the admission reads ${seconds}s apart (sleep failed) — refuse rather than decide on unspaced samples: ${
        (e && e.message) || e
      }`
    );
  }
}

function parsePrClaims(out) {
  const seen = new Map(); // claim id -> PR number, to catch duplicates
  const claims = [];
  for (const line of out.split("\n")) {
    if (!line.trim()) continue;
    const cols = line.split("\t");
    if (cols.length !== 7) {
      fail(
        `malformed/truncated PR-body claim row from pr-claims.sh (want 7 tab-separated fields, got ${cols.length}): ${JSON.stringify(
          line
        )}`
      );
    }
    const number = cols[0];
    const id = cols[1];
    const scopeStr = cols[2];
    const headBranch = cols[3];
    const url = cols[4];
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
    if (seen.has(id)) {
      fail(
        `duplicate live PR-body claim id '${id}' on PR #${seen.get(id)} and #${number} — refuse (#153 AC2 fail-closed)`
      );
    }
    seen.set(id, number);
    const scope = scopeStr.trim().split(/\s+/).filter(Boolean);
    claims.push({
      id,
      scope,
      issue: claimIssueNumber(id),
      source: "pr",
      number: Number(number),
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
 * - exact match
 * - either is prefix of the other (after stem)
 * - shared path prefix of at least one directory segment
 */
function tokensOverlap(a, b) {
  if (!a || !b) return false;
  if (a === b) return true;
  const sa = stem(a);
  const sb = stem(b);
  if (!sa || !sb) return false;
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
