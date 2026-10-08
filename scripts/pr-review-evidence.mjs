#!/usr/bin/env node
/**
 * pr-review-evidence.mjs — Law 5 on the interactive path (#308).
 *
 * WHAT IT DOES
 *   Decides whether a pull request's CURRENT head carries an independent,
 *   authenticated review receipt, and reports success / pending / failure with
 *   a closed reason token. It is the evaluator behind the `review-evidence`
 *   commit status published by `.github/workflows/pr-review-evidence.yml`.
 *
 *   - Introduced commits come from the PR commits API (never `git log`: the
 *     workflow runs trusted default-branch code and has no PR objects).
 *   - Every commit author/committer must resolve through the closed identity
 *     table in config/review-evidence.v1.json. Unresolved → failure
 *     (`identity-unresolved`). Since D-014 (2026-10-08) no head requires the
 *     owner: the former carve-out classes (see CARVE_OUT_PATTERNS) are only
 *     named in the status description. Lane bots resolve to their vendor even
 *     unsigned, owner-identity commits resolve through their `Agent-Vendor:`
 *     trailer, and an `independent` reviewer clears a trailerless owner
 *     commit. An owner attestation (`author-vendor:`) is honoured as an
 *     identity statement when present but is never required.
 *   - Evidence: formal reviews at the exact head by a listed Bot identity
 *     (APPROVED / CHANGES_REQUESTED; DISMISSED, PENDING, COMMENTED ignored),
 *     an App-authored `review-evidence:v1` comment at the exact head, or an
 *     owner-countersigned `owner-attested-review:v1` comment (#366) for a
 *     vendor with no GitHub App on this repo (e.g. Codex, run locally) —
 *     refused for any vendor that already has a real App reviewer identity.
 *     Per identity the newest evidence at this head wins.
 *   - Eligibility: the reviewer's vendor differs from every resolved author
 *     vendor; `unknown` is never eligible. Human reviews and comments from
 *     an unlisted App, or a listed App but the wrong slug/id, are not
 *     evidence unless they carry an owner-attested-review receipt instead.
 *
 * WHY
 *   Retro 2026-09-04: 16 of 34 merges had no cross-vendor verdict on GitHub,
 *   8 had no review event at all, one PR was built and reviewed by the same
 *   vendor. AGENTS.md Law 5 was prose on the merge button.
 *
 * RISKS / LIMITS
 *   Commits made under the owner identity cannot be attributed to a vendor by
 *   machine; an owner attestation is trusted on the owner's word. The durable
 *   fix is per-lane bot identities (#67). This script never mutates GitHub.
 *
 * USAGE
 *   node scripts/pr-review-evidence.mjs --repo OWNER/REPO --pr N --expected-head SHA
 *        [--config config/review-evidence.v1.json] [--github-output FILE]
 *        [--fixture DIR]   # offline: DIR/pull.json commits.json reviews.json comments.json
 *   Exit 0 on success or pending (pending blocks merge but is not a fault);
 *   exit 1 on failure. Unknown flag → exit 2.
 */

import { execFile } from "node:child_process";
import { appendFile, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const REASONS = Object.freeze({
  pass: "success",
  "no-receipt-at-head": "pending",
  "stale-head-only": "pending",
  "stale-base": "pending",
  "evidence-deleted": "pending",
  "same-vendor-reviewer": "failure",
  "identity-unresolved": "failure",
  "changes-requested": "failure",
  "head-moved": "failure",
  "ambiguous-head": "failure",
  "config-error": "failure",
  "api-error": "failure",
});

const SHA40 = /^[0-9a-f]{40}$/;
// `independent`: a reviewer-only identity that never authors commits (e.g. the
// aie-independent-review App), so it is cross-vendor to every author by
// construction. It is the delegated reviewer for commits whose vendor cannot be
// named (owner-identity, no Agent-Vendor trailer) outside the carve-outs.
const VENDORS = new Set(["grok", "codex", "claude", "devin", "coderabbit", "independent", "owner", "unknown"]);
const AUTHOR_COMMIT_VENDORS = new Set(["grok", "codex", "claude", "devin"]);
const ROLES = new Set(["author", "reviewer"]);
const CONFIG_KEYS = new Set(["schemaVersion", "context", "ownerLogin", "attestationVendors", "identities"]);
const IDENTITY_KEYS = new Set(["login", "appSlug", "appId", "vendor", "roles", "authorCommits"]);
// GitHub's own committer for web-UI edits; not a vendor, not an author of record.
const GITHUB_WEB_FLOW = "web-flow";

// Owner out of the loop (Mark, 2026-10-08: "Remove me from the loop"). The owner
// (mrhinkle) is never a gate. Every head, including the former carve-outs
// (agent rule and control-plane files, secrets/billing, schema and
// migrations), is cleared by the same thing: an independent cross-vendor
// review at the exact head. Identity resolution is always relaxed: a listed
// lane bot resolves to its vendor even unsigned, an owner-identity commit
// resolves through its `Agent-Vendor:` trailer, and an owner-identity commit
// with no trailer is cleared only by an `independent` reviewer. An owner
// attestation is still honoured as an identity statement (it unions vendors
// into the author set) but is never required. `carveOutPath()` is kept for
// the status description so a reviewer can see what class of file a head
// touches; it no longer changes the verdict. History: the 2026-10-05
// carve-out model (D-013) is superseded by D-014.
const LANE_BOT_LOGIN = /^aie-agent-lanes-[a-z0-9-]+\[bot\]$/;
const AGENT_RULE_FILE_NAMES = new Set(["agents.md", "claude.md"]);
const CARVE_OUT_PATTERNS = [
  // (a) agent rule and control-plane files: agent config roots, workflows,
  // the review-evidence trust config + evaluator, merge-gating sensors and
  // their config, the policy manifest, and the human-gates doctrine page.
  /^\.(grok|codex|claude|agents)\//i,
  /^\.github\//i,
  /^config\/(review-evidence|pr-size)\.v1\.json$/i,
  /^config\/policy\//i,
  /^scripts\/(pr-review-evidence|pr-size|check-active-work|policy-manifest|contract-authority)\.mjs$/i,
  /^scripts\/lib\/authority-config-canonical\.mjs$/i,
  /^scripts\/loop-fleet\.sh$/i,
  /^docs\/14-human-gates\.md$/i,
  // (b) secrets, Stripe, billing, checkout, payments, api keys
  /(^|\/)[^/]*(secret|stripe)[^/]*\.[cm]?[jt]sx?$/i,
  /(^|\/)[^/]*api[-_]?key[^/]*\.[cm]?[jt]sx?$/i,
  /(^|\/)(checkout|billing|payments?)(\/|$)/i,
  /(^|\/)\.env($|\.)/i,
  // (c) schema and migrations
  /(^|\/)migrations?\//i,
  /(^|\/)schema\.prisma$/i,
  /\.sql$/i,
];
// GitHub's PR files endpoint returns at most 3000 files, silently.
const PR_FILES_API_CAP = 3000;

/** First carve-out path a PR touches, `null` if none; `"<unknown>"` when the file list is not known. */
export function carveOutPath(files) {
  if (!Array.isArray(files) || files.length >= PR_FILES_API_CAP) return "<unknown>";
  for (const f of files) {
    const names = [f?.filename, f?.previous_filename].filter((n) => n !== undefined && n !== null);
    if (names.length === 0) return "<unknown>";
    for (const n of names) {
      if (typeof n !== "string" || n === "") return "<unknown>";
      const base = n.split("/").pop().toLowerCase();
      if (AGENT_RULE_FILE_NAMES.has(base) || CARVE_OUT_PATTERNS.some((re) => re.test(n))) return n;
    }
  }
  return null;
}

/** Vendors named by `Agent-Vendor:` trailers in a commit message (only real author vendors). */
export function trailerVendors(message) {
  if (typeof message !== "string") return [];
  const out = new Set();
  for (const m of message.matchAll(/^Agent-Vendor:[ \t]*([A-Za-z0-9_-]+)[ \t]*$/gim)) {
    const v = norm(m[1]);
    if (AUTHOR_COMMIT_VENDORS.has(v)) out.add(v);
  }
  return [...out];
}

const norm = (v) => (typeof v === "string" ? v.trim().toLowerCase() : "");

function usage(msg) {
  process.stderr.write(`pr-review-evidence.mjs: ${msg}\nusage: node scripts/pr-review-evidence.mjs --repo OWNER/REPO --pr N --expected-head SHA [--config FILE] [--github-output FILE] [--fixture DIR]\n`);
  process.exit(2);
}

export function parseArgs(argv) {
  const args = { repo: null, pr: null, expectedHead: null, config: "config/review-evidence.v1.json", githubOutput: null, fixture: null, sweep: false };
  const map = { "--repo": "repo", "--pr": "pr", "--expected-head": "expectedHead", "--config": "config", "--github-output": "githubOutput", "--fixture": "fixture" };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--help" || a === "-h") { usage("help"); }
    if (a === "--sweep") { args.sweep = true; continue; }
    if (!(a in map)) usage(`unknown flag: ${a}`);
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) usage(`${a} requires a value`);
    args[map[a]] = v; i += 1;
  }
  if (!args.repo) usage("--repo is required");
  if (args.sweep) {
    // --sweep: evaluate EVERY open PR at its current head; one JSON line each.
    if (args.pr || args.expectedHead || args.fixture) usage("--sweep takes no --pr/--expected-head/--fixture");
    return args;
  }
  for (const k of ["pr", "expectedHead"]) if (!args[k]) usage(`--${k === "expectedHead" ? "expected-head" : k} is required`);
  if (!SHA40.test(args.expectedHead)) usage("--expected-head must be a 40-hex SHA");
  if (!/^\d+$/.test(args.pr)) usage("--pr must be a number");
  return args;
}

/** Strict config validation. Throws Error(`config-error:<detail>`). */
export function validateConfig(cfg) {
  const fail = (d) => { throw new Error(`config-error:${d}`); };
  if (!cfg || typeof cfg !== "object" || Array.isArray(cfg)) fail("not-an-object");
  for (const k of Object.keys(cfg)) if (!CONFIG_KEYS.has(k)) fail(`unknown-key:${k}`);
  if (cfg.schemaVersion !== "1.0.0") fail("schemaVersion");
  if (cfg.context !== "review-evidence") fail("context");
  if (typeof cfg.ownerLogin !== "string" || !cfg.ownerLogin) fail("ownerLogin");
  if (!Array.isArray(cfg.attestationVendors) || cfg.attestationVendors.length === 0) fail("attestationVendors");
  for (const v of cfg.attestationVendors) {
    const known = VENDORS.has(v) || v === "human";
    if (!known || v === "unknown" || v === "owner" || v === "coderabbit" || v === "independent") fail(`attestationVendors:${v}`);
  }
  if (!Array.isArray(cfg.identities) || cfg.identities.length === 0) fail("identities");
  const seen = new Set();
  for (const id of cfg.identities) {
    if (!id || typeof id !== "object") fail("identity:not-an-object");
    for (const k of Object.keys(id)) if (!IDENTITY_KEYS.has(k)) fail(`identity-unknown-key:${k}`);
    if (typeof id.login !== "string" || !id.login) fail("identity:login");
    if (seen.has(norm(id.login))) fail(`identity-duplicate:${id.login}`);
    seen.add(norm(id.login));
    if (!(id.appSlug === null || (typeof id.appSlug === "string" && id.appSlug))) fail(`identity:appSlug:${id.login}`);
    if (!(id.appId === null || Number.isInteger(id.appId))) fail(`identity:appId:${id.login}`);
    if (!VENDORS.has(id.vendor)) fail(`identity:vendor:${id.login}`);
    if (!Array.isArray(id.roles) || id.roles.length === 0 || id.roles.some((r) => !ROLES.has(r))) fail(`identity:roles:${id.login}`);
    if (id.roles.includes("reviewer") && id.login.endsWith("[bot]") && !id.appSlug) fail(`identity:reviewer-needs-appSlug:${id.login}`);
    // An independent reviewer is only independent if it can never author and
    // its receipts are bound to one GitHub App (slug AND id).
    if (id.vendor === "independent" && (id.roles.length !== 1 || id.roles[0] !== "reviewer" || !id.appSlug || !Number.isInteger(id.appId))) fail(`identity:independent-reviewer-only:${id.login}`);
    if (Object.prototype.hasOwnProperty.call(id, "authorCommits")) {
      const ac = id.authorCommits;
      if (!Array.isArray(ac) || ac.length === 0) fail(`identity:authorCommits:${id.login}`);
      const seenSha = new Set();
      for (const sha of ac) {
        if (typeof sha !== "string" || !SHA40.test(sha)) fail(`identity:authorCommits:${id.login}`);
        if (seenSha.has(sha)) fail(`identity:authorCommits:${id.login}`);
        seenSha.add(sha);
      }
      const authorOnly = id.roles.length === 1 && id.roles[0] === "author";
      const vendorOk = AUTHOR_COMMIT_VENDORS.has(id.vendor) && cfg.attestationVendors.includes(id.vendor);
      if (!authorOnly || !vendorOk) fail(`identity:authorCommits:${id.login}`);
    }
  }
  return cfg;
}

function parseBlock(body, marker, fields) {
  if (typeof body !== "string") return null;
  const esc = marker.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const lines = fields.map((f) => `${f}:\\s*([^\\r\\n]+?)\\s*\\r?\\n`).join("");
  const m = body.match(new RegExp(`<!--\\s*${esc}\\s*\\r?\\n${lines}?-->`, "i"));
  if (!m) return null;
  const out = {};
  fields.forEach((f, i) => { out[f] = norm(m[i + 1]); });
  return out;
}

function timestamp(item) {
  for (const v of [item?.submitted_at, item?.updated_at, item?.created_at]) {
    const t = Date.parse(v ?? "");
    if (Number.isFinite(t)) return t;
  }
  return 0;
}

/**
 * Resolve every introduced commit's author+committer to a vendor.
 * Returns { vendors:Set, unresolved:[login...], unvendored:[login...] }.
 * `unvendored`: relaxed-mode owner-identity commits with no Agent-Vendor
 * trailer and no attestation; only an `independent` reviewer can clear them.
 *
 * Identity boundary (Codex review of #315, finding 1): GitHub resolves a
 * commit's `author.login` / `committer.login` from the raw git email, which any
 * pusher can set. So a login is trusted ONLY when GitHub itself signed the
 * commit (`commit.verification.verified === true`: API-created commits, web
 * UI commits). An UNVERIFIED commit — every CLI-made commit, including the lane
 * bots' — resolves only through the owner attestation at the exact head, which
 * names the vendor on the owner's word. Never from raw email metadata.
 */
export function resolveAuthors(commits, identities, attestedVendor, { relaxed = false } = {}) {
  const byLogin = new Map(identities.map((i) => [norm(i.login), i]));
  const vendors = new Set();
  const unresolved = [];
  const unvendored = [];
  for (const c of commits) {
    const verified = c?.commit?.verification?.verified === true;
    // Runtime SHA may be absent or a non-string; never throw on `.slice` before
    // the per-identity allowlist can return a structured denial.
    const sha = typeof c?.sha === "string" ? c.sha : "";
    const short = typeof c?.sha === "string" ? c.sha.slice(0, 7) : "?";
    for (const side of ["author", "committer"]) {
      const login = c?.[side]?.login ?? null;
      if (!login) { unresolved.push(`${side}:${short}:no-login`); continue; }
      if (norm(login) === GITHUB_WEB_FLOW) {
        if (!verified) unresolved.push(`${side}:${short}:web-flow-unverified`);
        continue;
      }
      const id = byLogin.get(norm(login));
      if (!id || !id.roles.includes("author")) { unresolved.push(login); continue; }
      if (Array.isArray(id.authorCommits)) {
        // Restriction precedes verified-commit handling and owner attestation.
        // Compare complete immutable SHAs only — no prefix, case-fold, or range.
        if (!id.authorCommits.includes(sha)) {
          unresolved.push(`${login}:commit-not-allowed`);
          continue;
        }
      }
      const vendor = id.vendor;
      if (vendor === "unknown") { unresolved.push(`${login}:vendor-unknown`); continue; }
      // Outside the carve-outs (2026-10-05): a listed lane bot resolves to its
      // vendor even unsigned, and an owner-identity commit resolves through its
      // Agent-Vendor trailer. An attestation still unions in its vendors.
      if (relaxed && !verified && vendor !== "owner" && LANE_BOT_LOGIN.test(norm(login)) && AUTHOR_COMMIT_VENDORS.has(vendor)) {
        vendors.add(vendor);
        if (attestedVendor) for (const v of attestedVendor) if (v !== "human") vendors.add(v);
        continue;
      }
      if (relaxed && vendor === "owner") {
        const tv = trailerVendors(c?.commit?.message);
        if (tv.length > 0) {
          for (const v of tv) vendors.add(v);
          if (attestedVendor) for (const v of attestedVendor) if (v !== "human") vendors.add(v);
          continue;
        }
        if (!attestedVendor) { unvendored.push(`${login}:owner-unvendored`); continue; }
      }
      if (vendor === "owner" || !verified) {
        if (!attestedVendor) { unresolved.push(`${login}:${vendor === "owner" ? "owner" : "unverified"}-unattested`); continue; }
        // Attestation is head-wide, so it UNIONS with what the login claims
        // (Codex round 2, finding 1): an unsigned Devin commit under an
        // attestation of `grok` makes BOTH devin and grok author vendors. The
        // attestation can add vendors to the author set, never remove one.
        for (const v of attestedVendor) if (v !== "human") vendors.add(v);
        if (vendor !== "owner") vendors.add(vendor);
        continue;
      }
      vendors.add(vendor);
    }
  }
  return { vendors, unresolved, unvendored };
}

/**
 * Owner attestation at the exact head: { vendors: [...], id } or null.
 * `author-vendor:` is a comma-separated list; every value must be in the
 * allowed vocabulary or the attestation is ignored (fail closed, not partial).
 */
export function ownerAttestation(comments, ownerLogin, headSha, allowed) {
  // Select the NEWEST owner attestation for this head by creation time, THEN
  // validate it. A tampered newer attestation is a tombstone, not an absence
  // (Codex round 6, finding 1): it must not fall through to an older one.
  const hits = comments
    .filter((c) => norm(c?.user?.login) === norm(ownerLogin) && ["OWNER", "MEMBER"].includes(c?.author_association))
    .map((c) => ({ c, b: parseBlock(c?.body, "owner-review-attestation:v1", ["head-sha", "author-vendor"]) }))
    .filter((x) => editedByOther(x.c) || (x.b && x.b["head-sha"] === headSha))
    // Order by CREATION: an edit moves updated_at and must not promote an
    // older attestation over a newer one (Codex round 5, finding 5). Same
    // second → higher comment id is newer (round 7 note).
    .sort((l, r) => ((Date.parse(r.c?.created_at ?? "") || 0) - (Date.parse(l.c?.created_at ?? "") || 0)) || (Number(r.c?.id ?? 0) - Number(l.c?.id ?? 0)));
  const top = hits[0];
  if (!top || editedByOther(top.c)) return null;
  const vendors = [...new Set(top.b["author-vendor"].split(",").map((v) => norm(v)).filter(Boolean))];
  if (vendors.length === 0 || !vendors.every((v) => allowed.includes(v))) return null;
  return { vendors, id: top.c.id };
}

/**
 * Collect review evidence. Returns per-identity newest evidence at head plus
 * whether any receipt exists at another head.
 */
/** A comment edited by anyone other than its creator is not that creator's word (round 4, finding 1). */
export function editedByOther(c) {
  const editor = c?.editor?.login ?? c?.editor ?? null;
  // Edited with no recorded editor (deleted account, API gap) is unknown
  // provenance: fail closed (Codex round 5, finding 6).
  if (c?.edited === true && !editor) return true;
  return !!editor && norm(editor) !== norm(c?.user?.login);
}
/** An App receipt is machine-written; ANY edit voids it (round 5, finding 1). */
export function editedAtAll(c) {
  return c?.edited === true || !!(c?.editor?.login ?? c?.editor ?? null);
}

/**
 * Vendors that already have a real GitHub-App reviewer identity in the
 * config: `ownerAttestedReview` refuses to countersign for these — the
 * external path exists ONLY for a vendor with no App presence (Codex,
 * Claude, human), never as a weaker shortcut around one that could post
 * real, machine-verified evidence itself.
 */
function appReviewerVendors(identities) {
  return new Set(identities.filter((i) => i.roles.includes("reviewer") && i.appSlug).map((i) => i.vendor));
}

// The identity key every `owner-attested-review:v1` item is filed under in
// `collectEvidence`'s per-identity newest-wins map. Fixed and NOT derived
// from the comment body (see below) — every such comment shares one poster
// (the owner), so `reviewer-vendor` is the only thing that could otherwise
// distinguish one from another, and it lives in the exact content an edit
// can tamper with.
const OWNER_EXTERNAL_REVIEW_LOGIN = "owner-attested-review";

/**
 * Owner-countersigned review from a vendor with no GitHub App on this repo
 * (e.g. Codex, run locally via codex-review.sh — there is no "codex[bot]"
 * App to post a `review-evidence:v1` comment through). Mirrors
 * `ownerAttestation`'s exact trust boundary (OWNER/MEMBER login match,
 * exact-head bound) but carries a review verdict rather than an
 * author-vendor claim. Returns a synthetic reviewer "identity" item, a
 * `{ stale: true }` marker, or null (not evidence at all).
 *
 * Tombstone binding (#366 review round 1, finding 1): every App-authored
 * receipt tombs by a login GitHub itself signs (`c.user.login`), which an
 * edit cannot change. An owner-attested-review comment has no such
 * body-independent signal — `reviewer-vendor` IS the claim, and an editor
 * who is not the owner can rewrite it. So `editedByOther` is checked FIRST,
 * before any attempt to parse the (possibly rewritten) body, and the
 * tombstone is filed under the ONE FIXED key every owner-attested-review
 * comment uses (`OWNER_EXTERNAL_REVIEW_LOGIN`), never a vendor read from
 * current content. This means a tampered comment tombs the whole
 * owner-countersigned-review slot regardless of what it now claims — the
 * safe direction, since which vendor it USED to claim is unknowable from
 * the API's current-state view. (Consequence, accepted for now: only one
 * App-less vendor's review is tracked at a time per head; a second
 * concurrent one would compete for the same slot. Not this repo's use
 * case today — extend with a stable per-comment-id key if it becomes one.)
 */
export function ownerAttestedReview(c, ownerLogin, headSha, allowedVendors, blockedVendors) {
  if (norm(c?.user?.login) !== norm(ownerLogin) || !["OWNER", "MEMBER"].includes(c?.author_association)) return null;
  const at = Date.parse(c?.created_at ?? "") || timestamp(c);
  if (editedByOther(c)) {
    return { identity: { login: OWNER_EXTERNAL_REVIEW_LOGIN, vendor: "unknown", roles: ["reviewer"] }, result: "none", at, id: Number(c?.id ?? 0), source: "comment" };
  }
  const b = parseBlock(c?.body, "owner-attested-review:v1", ["head-sha", "reviewer-vendor", "result"]);
  if (!b) return null;
  const vendor = b["reviewer-vendor"];
  if (!vendor || !allowedVendors.includes(vendor) || vendor === "unknown" || vendor === "owner") return null;
  if (blockedVendors.has(vendor)) return null;
  if (!["pass", "fail"].includes(b.result)) return null;
  if (b["head-sha"] !== headSha) return { stale: true };
  return { identity: { login: OWNER_EXTERNAL_REVIEW_LOGIN, vendor, roles: ["reviewer"] }, result: b.result, at, id: Number(c?.id ?? 0), source: "comment" };
}

export function collectEvidence({ reviews, comments, identities, headSha, notBefore = 0, ownerLogin = null, attestationVendors = [] }) {
  const reviewers = identities.filter((i) => i.roles.includes("reviewer"));
  const byLogin = new Map(reviewers.map((i) => [norm(i.login), i]));
  const blockedVendors = appReviewerVendors(identities);
  const items = [];
  let staleReceipts = 0;
  let staleBase = 0;
  for (const r of reviews ?? []) {
    const id = byLogin.get(norm(r?.user?.login));
    if (!id || r?.user?.type !== "Bot") continue;
    const state = norm(r?.state);
    // DISMISSED takes part in newest-wins with result "none" (round 4,
    // finding 1b): an author-dismissed CHANGES_REQUESTED must not resurrect
    // an older APPROVE. PENDING/COMMENTED carry no verdict and are ignored.
    if (state !== "approved" && state !== "changes_requested" && state !== "dismissed") continue;
    if (norm(r?.commit_id) !== headSha) { staleReceipts += 1; continue; }
    const at = timestamp(r);
    // `<=`: a retarget in the same second as the review is not provably after it (round 5, finding 4).
    if (notBefore > 0 && at <= notBefore) { staleBase += 1; continue; }
    const result = state === "approved" ? "pass" : state === "changes_requested" ? "fail" : "none";
    items.push({ identity: id, result, at, id: Number(r?.id ?? 0), source: "review" });
  }
  for (const c of comments ?? []) {
    const id = byLogin.get(norm(c?.user?.login));
    if (id && id.appSlug) {
      const app = c?.performed_via_github_app;
      if (app && norm(app.slug) === norm(id.appSlug) && (id.appId === null || Number(app.id) === id.appId)) {
        const b = parseBlock(c?.body, "review-evidence:v1", ["head-sha", "result"]);
        // Provenance is the CREATION; an edit moves updated_at, so order by created_at.
        const at = Date.parse(c?.created_at ?? "") || timestamp(c);
        // An edited machine receipt is a TOMBSTONE, not an absence (Codex round 6,
        // finding 1): it still takes its place in newest-wins with no verdict, so
        // editing a newer `fail` can never resurrect an older `pass`. The body may
        // have been rewritten, so bind the tombstone by the identity alone.
        if (editedAtAll(c)) { items.push({ identity: id, result: "none", at, id: Number(c?.id ?? 0), source: "comment" }); continue; }
        if (b && ["pass", "fail"].includes(b.result)) {
          if (b["head-sha"] !== headSha) { staleReceipts += 1; continue; }
          if (notBefore > 0 && at <= notBefore) { staleBase += 1; continue; }
          items.push({ identity: id, result: b.result, at, id: Number(c?.id ?? 0), source: "comment" });
        }
        continue;
      }
    }
    // Owner-countersigned review for a vendor with no GitHub App on this
    // repo (Codex, Claude, human) — see ownerAttestedReview above.
    if (ownerLogin) {
      const ext = ownerAttestedReview(c, ownerLogin, headSha, attestationVendors, blockedVendors);
      if (ext) {
        if (ext.stale) { staleReceipts += 1; continue; }
        if (ext.result === "none") { items.push(ext); continue; }
        if (notBefore > 0 && ext.at <= notBefore) { staleBase += 1; continue; }
        items.push(ext);
      }
    }
  }
  // Newest per identity. Review ids and comment ids are different resource
  // types with no cross-resource ordering, so a same-second tie between a
  // review and a comment cannot be broken by id: on a tie, `fail` dominates
  // (Codex review of #315, finding 5 — fail closed, never fail open).
  const newest = new Map();
  for (const it of items) {
    const k = norm(it.identity.login);
    const cur = newest.get(k);
    if (!cur || it.at > cur.at) { newest.set(k, it); continue; }
    if (it.at === cur.at) {
      // Same source: ids are monotonic, so the higher id is newer whatever its
      // result — a same-second dismissal replaces an older approve (Codex
      // round 6, finding 3). Cross-source: no ordering exists; fail dominates.
      if (it.source === cur.source) { if (it.id > cur.id) newest.set(k, it); }
      else if (it.result === "fail" && cur.result !== "fail") newest.set(k, it);
    }
  }
  // An identity whose newest evidence is a dismissal contributes nothing.
  return { newest: [...newest.values()].filter((e) => e.result !== "none"), staleReceipts, staleBase };
}

export function evaluate({ headSha, expectedHead, prNumber, pull, pullsForHead, commits, reviews, comments, timeline, config, files }) {
  const head = norm(headSha);
  if (head !== norm(expectedHead)) return { state: "failure", reason: "head-moved", detail: `pr head ${head.slice(0, 7)} != expected ${norm(expectedHead).slice(0, 7)}` };
  // A commit status is keyed by SHA, not by PR (Codex review of #315, finding 3):
  // two open PRs sharing a head would overwrite each other's verdict. Refuse
  // to publish a verdict for a head that belongs to more than one open PR.
  // The commits/{sha}/pulls endpoint returns PRs *associated* with a commit
  // (ancestors included), so filter to PRs whose HEAD is this SHA (round 2,
  // finding 3): a stacked PR that merely contains this head is not a sibling.
  let openForHead = (pullsForHead ?? [])
    .filter((p) => norm(p?.state) === "open" && norm(p?.head?.sha) === head)
    .map((p) => Number(p?.number));
  // A fork head is not a commit of the base repository, so the
  // commits/{sha}/pulls listing returns nothing for it (#455). The PR under
  // evaluation is, by its own record, one owner of its head: when the listing
  // is EMPTY and the PR's own head matches, evaluate it as the sole owner.
  // A non-empty listing that does not name this PR is still ambiguous.
  if (openForHead.length === 0 && norm(pull?.state) === "open" && norm(pull?.head?.sha) === head) {
    openForHead = [Number(prNumber)];
  }
  if (openForHead.length !== 1 || openForHead[0] !== Number(prNumber)) {
    return { state: "failure", reason: "ambiguous-head", detail: `head is the head of open PRs [${openForHead.join(",")}], evaluating #${prNumber}` };
  }
  // The commits endpoint caps at 250 silently (finding 4): an omitted commit is
  // an unresolved author we never saw. Require the count to match the PR's own.
  const declared = Number(pull?.commits);
  if (!Number.isInteger(declared) || declared !== (commits ?? []).length || declared > PR_COMMITS_API_CAP) {
    return { state: "failure", reason: "api-error", detail: `commits-truncated: pr declares ${declared}, fetched ${(commits ?? []).length}, cap ${PR_COMMITS_API_CAP}` };
  }
  const att = ownerAttestation(comments ?? [], config.ownerLogin, head, config.attestationVendors);
  // Owner out of the loop (2026-10-08, D-014): identity resolution is always
  // relaxed; the carve-out class is reported in the description only.
  const carveOut = carveOutPath(files);
  const authors = resolveAuthors(commits ?? [], config.identities, att?.vendors ?? null, { relaxed: true });
  if (authors.unresolved.length > 0) {
    const why = carveOut && carveOut !== "<unknown>" ? `;touches:${carveOut}` : "";
    return { state: "failure", reason: "identity-unresolved", detail: `${[...new Set(authors.unresolved)].join(",")}${why}`, authorVendors: [...authors.vendors], attestation: att, carveOut };
  }
  // A base retarget keeps the head SHA but changes the diff (round 4,
  // finding 3): evidence created before the last base_ref_changed is stale.
  const notBefore = lastBaseChange(timeline);
  const { newest, staleReceipts, staleBase } = collectEvidence({ reviews, comments, identities: config.identities, headSha: head, notBefore, ownerLogin: config.ownerLogin, attestationVendors: config.attestationVendors });
  // Owner-identity commits with no named vendor (outside the carve-outs): the
  // author's vendor is unknowable, so only an `independent` reviewer is
  // provably cross-vendor. Without one, the identity stays unresolved.
  const unvendored = authors.unvendored.length > 0;
  if (unvendored && !newest.some((e) => e.identity.vendor === "independent")) {
    return { state: "failure", reason: "identity-unresolved", detail: `${[...new Set(authors.unvendored)].join(",")};needs Agent-Vendor trailer or independent review`, authorVendors: [...authors.vendors], attestation: att, carveOut };
  }
  // With unvendored commits a pass counts only from an independent reviewer;
  // a cross-vendor fail still counts (fail closed).
  const crossVendor = newest.filter((e) => e.identity.vendor !== "unknown" && !authors.vendors.has(e.identity.vendor));
  const eligible = unvendored ? crossVendor.filter((e) => e.identity.vendor === "independent" || e.result === "fail") : crossVendor;
  const ineligible = newest.filter((e) => !eligible.includes(e));
  const base = { authorVendors: [...authors.vendors], attestation: att, evidence: newest.map((e) => `${e.identity.login}:${e.result}:${e.source}`) };
  if (eligible.some((e) => e.result === "fail")) return { state: "failure", reason: "changes-requested", detail: eligible.filter((e) => e.result === "fail").map((e) => e.identity.login).join(","), ...base };
  if (eligible.some((e) => e.result === "pass")) {
    // A deleted comment is invisible to REST, so a writer could delete an
    // App's newer `fail` receipt and resurrect an older `pass` (round 5,
    // finding 1). The timeline records `comment_deleted`: any deletion at or
    // after the newest eligible pass voids that pass until a fresh review.
    const newestPass = Math.max(...eligible.filter((e) => e.result === "pass").map((e) => e.at));
    const deletedAfter = (timeline ?? []).filter((ev) => norm(ev?.event) === "comment_deleted" && (Date.parse(ev?.created_at ?? "") || 0) >= newestPass).length;
    if (deletedAfter > 0) return { state: "pending", reason: "evidence-deleted", detail: `${deletedAfter} comment(s) deleted at/after the newest pass; review again`, ...base };
    // D-014: no owner attestation on any head. The class of file touched is
    // surfaced in the description for the record, never as a gate.
    const touched = carveOut && carveOut !== "<unknown>" ? `; touches:${carveOut}` : "";
    return { state: "success", reason: "pass", detail: `${eligible.filter((e) => e.result === "pass").map((e) => e.identity.login).join(",")}${touched}`, ...base, carveOut };
  }
  if (ineligible.length > 0) return { state: "failure", reason: "same-vendor-reviewer", detail: ineligible.map((e) => `${e.identity.login}(${e.identity.vendor})`).join(","), ...base };
  if (staleBase > 0) return { state: "pending", reason: "stale-base", detail: `${staleBase} receipt(s) predate the last base retarget; review again`, ...base };
  if (staleReceipts > 0) return { state: "pending", reason: "stale-head-only", detail: `${staleReceipts} receipt(s) at other heads`, ...base };
  return { state: "pending", reason: "no-receipt-at-head", detail: "no listed reviewer has reviewed this head", ...base };
}

async function ghJson(args) {
  try {
    const { stdout } = await execFileAsync("gh", ["api", ...args], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024, env: process.env, timeout: 60_000 });
    return JSON.parse(stdout);
  } catch (e) {
    throw new Error(`api-error:${(e?.message ?? String(e)).replace(/[\r\n]+/g, " ").slice(0, 100)}`);
  }
}
async function ghPages(endpoint) {
  const pages = await ghJson(["--paginate", "--slurp", endpoint]);
  return Array.isArray(pages) ? pages.flat() : [];
}

// GitHub's PR commits endpoint returns at most 250 commits, silently.
const PR_COMMITS_API_CAP = 250;

async function loadInputs(args) {
  if (args.fixture) {
    const rd = async (n, optional) => {
      try { return JSON.parse(await readFile(join(args.fixture, n), "utf8")); }
      catch (e) { if (optional && e.code === "ENOENT") return undefined; throw e; }
    };
    try {
      const pull = await rd("pull.json");
      // pulls-for-head.json: open PRs whose head is this SHA (default: just this PR)
      const pullsForHead = (await rd("pulls-for-head.json", true)) ?? [{ number: pull?.number ?? Number(args.pr), state: "open", head: { sha: pull?.head?.sha } }];
      // timeline.json: issue timeline events (base_ref_changed matters); default none.
      const timeline = (await rd("timeline.json", true)) ?? [];
      // comments.json entries may carry `editor` (login) — the GraphQL editor field.
      // files.json: PR files (filename/previous_filename); absent = unknown list,
      // which keeps the strict owner-attestation path (fail closed).
      const files = await rd("files.json", true);
      return { pull, commits: await rd("commits.json"), reviews: await rd("reviews.json"), comments: await rd("comments.json"), pullsForHead, timeline, files };
    } catch (e) { throw new Error(`api-error:fixture:${e.message.slice(0, 80)}`); }
  }
  const base = `repos/${args.repo}`;
  const pull = await ghJson([`${base}/pulls/${args.pr}`]);
  const head = norm(pull?.head?.sha ?? "");
  if (!SHA40.test(head)) throw new Error("api-error:pull-head-missing");
  const [commits, reviews, comments, pullsForHead, timeline, files] = await Promise.all([
    ghPages(`${base}/pulls/${args.pr}/commits?per_page=100`),
    ghPages(`${base}/pulls/${args.pr}/reviews?per_page=100`),
    ghPages(`${base}/issues/${args.pr}/comments?per_page=100`),
    ghPages(`${base}/commits/${head}/pulls?per_page=100`),
    ghPages(`${base}/issues/${args.pr}/timeline?per_page=100`),
    ghPages(`${base}/pulls/${args.pr}/files?per_page=100`),
  ]);
  // REST does not expose who last edited a comment; GraphQL does. A receipt or
  // attestation edited by anyone but its creator is not that creator's word
  // (round 4, finding 1). Fail closed if this lookup fails.
  const [owner, name] = args.repo.split("/");
  const edits = new Map(); // databaseId -> { editor: login|null }
  let cursor = null;
  let complete = false;
  for (let page = 0; page < 20; page += 1) {
    const q = `query($o:String!,$r:String!,$n:Int!,$c:String){repository(owner:$o,name:$r){pullRequest(number:$n){comments(first:100,after:$c){nodes{databaseId lastEditedAt editor{login}} pageInfo{hasNextPage endCursor}}}}}`;
    const res = await ghJson(["graphql", "-f", `query=${q}`, "-F", `o=${owner}`, "-F", `r=${name}`, "-F", `n=${Number(args.pr)}`, ...(cursor ? ["-F", `c=${cursor}`] : [])]).catch((e) => { throw new Error(`api-error:graphql-editors:${(e.message ?? "").slice(0, 60)}`); });
    const conn = res?.data?.repository?.pullRequest?.comments;
    if (!conn || !Array.isArray(conn.nodes)) throw new Error("api-error:graphql-editors:malformed");
    // Any lastEditedAt marks the comment edited, even with no editor login
    // (round 5, finding 6): unknown provenance fails closed downstream.
    for (const n of conn.nodes) if (n?.lastEditedAt) edits.set(Number(n.databaseId), { editor: n?.editor?.login ?? null });
    if (!conn.pageInfo?.hasNextPage) { complete = true; break; }
    cursor = conn.pageInfo.endCursor;
  }
  if (!complete) throw new Error("api-error:graphql-editors:too-many-pages");
  for (const c of comments) {
    const e = edits.get(Number(c?.id));
    if (e) { c.edited = true; if (e.editor) c.editor = e.editor; }
  }
  return { pull, commits, reviews, comments, pullsForHead, timeline, files };
}

/** Timestamp of the PR's most recent base retarget, or 0. Receipts older than it are `stale-base`. */
export function lastBaseChange(timeline) {
  let t = 0;
  for (const ev of timeline ?? []) {
    if (norm(ev?.event) !== "base_ref_changed") continue;
    const ts = Date.parse(ev?.created_at ?? "");
    if (Number.isFinite(ts) && ts > t) t = ts;
  }
  return t;
}

function outputLines(head, r) {
  const desc = `${r.reason}${r.detail ? `: ${r.detail}` : ""}`.replace(/[\r\n]+/g, " ").slice(0, 140);
  return [`head_sha=${head}`, `state=${r.state}`, `reason=${r.reason}`, `description=${desc}`];
}

async function loadConfig(path) {
  const text = await readFile(path, "utf8").catch((e) => { throw new Error(`config-error:unreadable:${e.code ?? e.message}`); });
  let raw;
  try { raw = JSON.parse(text); } catch (e) { throw new Error(`config-error:invalid-json:${e.message.slice(0, 60)}`); }
  return validateConfig(raw);
}

function faultResult(e) {
  const msg = e?.message ?? String(e);
  if (msg.startsWith("config-error:") || msg.startsWith("api-error:")) {
    const [reason, ...rest] = msg.split(":");
    return { state: "failure", reason, detail: rest.join(":") };
  }
  return { state: "failure", reason: "api-error", detail: `evaluator-crashed:${msg.slice(0, 80)}` };
}

/** Evaluate one PR. Never throws; a fault is a failure result. */
async function evaluateOne(args, config) {
  let head = norm(args.expectedHead ?? "");
  try {
    const inputs = await loadInputs(args);
    if (!SHA40.test(norm(inputs.pull?.head?.sha ?? ""))) throw new Error("api-error:pull-head-missing");
    head = norm(inputs.pull.head.sha);
    const expectedHead = args.expectedHead ?? head;
    const result = evaluate({ headSha: head, expectedHead, prNumber: Number(args.pr), pull: inputs.pull, pullsForHead: inputs.pullsForHead, commits: inputs.commits, reviews: inputs.reviews, comments: inputs.comments, timeline: inputs.timeline, config, files: inputs.files });
    return { headSha: head, ...result, pull: inputs.pull };
  } catch (e) {
    return { headSha: head, ...faultResult(e) };
  }
}

export async function main(argv) {
  const args = parseArgs(argv);
  let config;
  try { config = await loadConfig(args.config); } catch (e) {
    const r = { headSha: norm(args.expectedHead ?? ""), ...faultResult(e) };
    if (args.githubOutput) await appendFile(args.githubOutput, `${outputLines(r.headSha, r).join("\n")}\n`);
    process.stdout.write(`${JSON.stringify(args.sweep ? { number: null, ...r } : r)}\n`);
    process.exitCode = 1;
    return;
  }
  if (args.sweep) {
    // Full-state sweep (round 4, finding 2): every run re-evaluates EVERY open
    // PR at its current head, so a queued run that GitHub replaces is harmless
    // — the next run corrects every head. One JSON line per PR; exit 0 unless
    // the PR list itself could not be read (that is a fault the caller must
    // publish as failure on whatever head it knows).
    let open;
    try { open = await ghPages(`repos/${args.repo}/pulls?state=open&per_page=100`); }
    catch (e) { process.stdout.write(`${JSON.stringify({ number: null, headSha: "", ...faultResult(e) })}\n`); process.exitCode = 1; return; }
    for (const p of open) {
      const n = Number(p?.number);
      const r = await evaluateOne({ ...args, pr: String(n), expectedHead: norm(p?.head?.sha ?? "") || null }, config);
      // State fingerprint at evaluation time; the publisher re-reads it right
      // before writing a `success` and downgrades to pending if it moved
      // (Codex round 6, finding 2). Same shape as the workflow's `fingerprint()`.
      const fingerprint = r.pull
        ? `${r.pull.updated_at ?? ""}|${norm(r.pull.head?.sha ?? "")}|${norm(r.pull.base?.sha ?? "")}|${r.pull.comments ?? ""}|${r.pull.review_comments ?? ""}|${r.pull.commits ?? ""}`
        : "";
      const { pull: _omit, ...rest } = r;
      process.stdout.write(`${JSON.stringify({ number: n, ...rest, fingerprint, description: `${r.reason}${r.detail ? `: ${r.detail}` : ""}`.replace(/[\r\n]+/g, " ").slice(0, 140) })}\n`);
    }
    return;
  }
  const { pull: _omit, ...result } = await evaluateOne(args, config);
  if (args.githubOutput) await appendFile(args.githubOutput, `${outputLines(result.headSha, result).join("\n")}\n`);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  if (result.state === "failure") process.exitCode = 1;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main(process.argv.slice(2)).catch((e) => {
    process.stderr.write(`pr-review-evidence.mjs: ${e?.message ?? e}\n`);
    process.exitCode = 1;
  });
}
