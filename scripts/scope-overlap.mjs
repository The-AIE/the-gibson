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
 *     [--json]
 *   node scripts/scope-overlap.mjs --help
 *
 * EXIT
 *   0  no overlap (or empty proposed scope with no live claims)
 *   1  overlap / fetch failure / unreadable ledger
 *   2  usage
 */

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

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
  --json          machine-readable result
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
function loadPrClaims() {
  if (!opt.repo) return [];
  const prClaimsScript = resolve(__dirname, "pr-claims.sh");
  if (!existsSync(prClaimsScript)) {
    fail(`--repo given but pr-claims.sh is missing at ${prClaimsScript} — refuse`);
  }
  let out;
  try {
    out = execFileSync(prClaimsScript, ["list", opt.repo], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 16 * 1024 * 1024,
    });
  } catch (e) {
    fail(
      `cannot read live PR-body claims for ${opt.repo} (pr-claims.sh failed) — refuse (#153 AC2 fail-closed): ${
        (e && e.message) || e
      }`
    );
  }
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
    const issueM = id.match(/^issue-(\d+)-/);
    claims.push({ id, scope, issue: issueM ? issueM[1] : null, source: "pr" });
  }
  return claims;
}

const live = [...loadClaims(), ...loadPrClaims()].filter(
  (c) => c.id !== opt.claimId
);

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
  collisions.push({ claim: c, hits });
}

if (collisions.length) {
  const details = collisions.map((col) => ({
    claimId: col.claim.id,
    source: col.claim.source,
    scope: col.claim.scope,
    hits: col.hits,
  }));
  if (opt.json) {
    console.log(
      JSON.stringify(
        {
          ok: false,
          error: "scope overlap",
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
      console.error(
        `scope-overlap: ERROR: proposed scope overlaps live claim ${col.claim.id} (${col.claim.source}) scope=[${col.claim.scope.join(" ")}] collisions: ${hitStr}`
      );
    }
  }
  process.exit(1);
}

ok({ liveClaims: live.length, proposed: opt.scopes, ref: ref.trim() });
