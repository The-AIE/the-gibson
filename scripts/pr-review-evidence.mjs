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
 *     (`identity-unresolved`). Owner-identity commits resolve only through an
 *     owner attestation at the exact head (`author-vendor:`).
 *   - Evidence: formal reviews at the exact head by a listed Bot identity
 *     (APPROVED / CHANGES_REQUESTED; DISMISSED, PENDING, COMMENTED ignored),
 *     or an App-authored `review-evidence:v1` comment at the exact head.
 *     Per identity the newest evidence at this head wins.
 *   - Eligibility: the reviewer's vendor differs from every resolved author
 *     vendor; `unknown` is never eligible. Human reviews, unlisted Apps, and
 *     comments not performed via a listed App are not evidence.
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
const VENDORS = new Set(["grok", "codex", "claude", "devin", "coderabbit", "owner", "unknown"]);
const ROLES = new Set(["author", "reviewer"]);
const CONFIG_KEYS = new Set(["schemaVersion", "context", "ownerLogin", "attestationVendors", "identities"]);
const IDENTITY_KEYS = new Set(["login", "appSlug", "appId", "vendor", "roles"]);
// GitHub's own committer for web-UI edits; not a vendor, not an author of record.
const GITHUB_WEB_FLOW = "web-flow";

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
    if (!known || v === "unknown" || v === "owner" || v === "coderabbit") fail(`attestationVendors:${v}`);
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
 * Returns { vendors:Set, unresolved:[login...] }.
 *
 * Identity boundary (Codex review of #315, finding 1): GitHub resolves a
 * commit's `author.login` / `committer.login` from the raw git email, which any
 * pusher can set. So a login is trusted ONLY when GitHub itself signed the
 * commit (`commit.verification.verified === true`: API-created commits, web
 * UI commits). An UNVERIFIED commit — every CLI-made commit, including the lane
 * bots' — resolves only through the owner attestation at the exact head, which
 * names the vendor on the owner's word. Never from raw email metadata.
 */
export function resolveAuthors(commits, identities, attestedVendor) {
  const byLogin = new Map(identities.map((i) => [norm(i.login), i]));
  const vendors = new Set();
  const unresolved = [];
  for (const c of commits) {
    const verified = c?.commit?.verification?.verified === true;
    const short = c?.sha?.slice(0, 7) ?? "?";
    for (const side of ["author", "committer"]) {
      const login = c?.[side]?.login ?? null;
      if (!login) { unresolved.push(`${side}:${short}:no-login`); continue; }
      if (norm(login) === GITHUB_WEB_FLOW) {
        if (!verified) unresolved.push(`${side}:${short}:web-flow-unverified`);
        continue;
      }
      const id = byLogin.get(norm(login));
      if (!id || !id.roles.includes("author")) { unresolved.push(login); continue; }
      const vendor = id.vendor;
      if (vendor === "unknown") { unresolved.push(`${login}:vendor-unknown`); continue; }
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
  return { vendors, unresolved };
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

export function collectEvidence({ reviews, comments, identities, headSha, notBefore = 0 }) {
  const reviewers = identities.filter((i) => i.roles.includes("reviewer"));
  const byLogin = new Map(reviewers.map((i) => [norm(i.login), i]));
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
    if (!id || !id.appSlug) continue;
    const app = c?.performed_via_github_app;
    if (!app || norm(app.slug) !== norm(id.appSlug)) continue;
    if (id.appId !== null && Number(app.id) !== id.appId) continue;
    const b = parseBlock(c?.body, "review-evidence:v1", ["head-sha", "result"]);
    // Provenance is the CREATION; an edit moves updated_at, so order by created_at.
    const at = Date.parse(c?.created_at ?? "") || timestamp(c);
    // An edited machine receipt is a TOMBSTONE, not an absence (Codex round 6,
    // finding 1): it still takes its place in newest-wins with no verdict, so
    // editing a newer `fail` can never resurrect an older `pass`. The body may
    // have been rewritten, so bind the tombstone by the identity alone.
    if (editedAtAll(c)) { items.push({ identity: id, result: "none", at, id: Number(c?.id ?? 0), source: "comment" }); continue; }
    if (!b || !["pass", "fail"].includes(b.result)) continue;
    if (b["head-sha"] !== headSha) { staleReceipts += 1; continue; }
    if (notBefore > 0 && at <= notBefore) { staleBase += 1; continue; }
    items.push({ identity: id, result: b.result, at, id: Number(c?.id ?? 0), source: "comment" });
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

export function evaluate({ headSha, expectedHead, prNumber, pull, pullsForHead, commits, reviews, comments, timeline, config }) {
  const head = norm(headSha);
  if (head !== norm(expectedHead)) return { state: "failure", reason: "head-moved", detail: `pr head ${head.slice(0, 7)} != expected ${norm(expectedHead).slice(0, 7)}` };
  // A commit status is keyed by SHA, not by PR (Codex review of #315, finding 3):
  // two open PRs sharing a head would overwrite each other's verdict. Refuse
  // to publish a verdict for a head that belongs to more than one open PR.
  // The commits/{sha}/pulls endpoint returns PRs *associated* with a commit
  // (ancestors included), so filter to PRs whose HEAD is this SHA (round 2,
  // finding 3): a stacked PR that merely contains this head is not a sibling.
  const openForHead = (pullsForHead ?? [])
    .filter((p) => norm(p?.state) === "open" && norm(p?.head?.sha) === head)
    .map((p) => Number(p?.number));
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
  const authors = resolveAuthors(commits ?? [], config.identities, att?.vendors ?? null);
  if (authors.unresolved.length > 0) return { state: "failure", reason: "identity-unresolved", detail: [...new Set(authors.unresolved)].join(","), authorVendors: [...authors.vendors], attestation: att };
  // A base retarget keeps the head SHA but changes the diff (round 4,
  // finding 3): evidence created before the last base_ref_changed is stale.
  const notBefore = lastBaseChange(timeline);
  const { newest, staleReceipts, staleBase } = collectEvidence({ reviews, comments, identities: config.identities, headSha: head, notBefore });
  const eligible = newest.filter((e) => e.identity.vendor !== "unknown" && !authors.vendors.has(e.identity.vendor));
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
    return { state: "success", reason: "pass", detail: eligible.filter((e) => e.result === "pass").map((e) => e.identity.login).join(","), ...base };
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
      return { pull, commits: await rd("commits.json"), reviews: await rd("reviews.json"), comments: await rd("comments.json"), pullsForHead, timeline };
    } catch (e) { throw new Error(`api-error:fixture:${e.message.slice(0, 80)}`); }
  }
  const base = `repos/${args.repo}`;
  const pull = await ghJson([`${base}/pulls/${args.pr}`]);
  const head = norm(pull?.head?.sha ?? "");
  if (!SHA40.test(head)) throw new Error("api-error:pull-head-missing");
  const [commits, reviews, comments, pullsForHead, timeline] = await Promise.all([
    ghPages(`${base}/pulls/${args.pr}/commits?per_page=100`),
    ghPages(`${base}/pulls/${args.pr}/reviews?per_page=100`),
    ghPages(`${base}/issues/${args.pr}/comments?per_page=100`),
    ghPages(`${base}/commits/${head}/pulls?per_page=100`),
    ghPages(`${base}/issues/${args.pr}/timeline?per_page=100`),
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
  return { pull, commits, reviews, comments, pullsForHead, timeline };
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
    const result = evaluate({ headSha: head, expectedHead, prNumber: Number(args.pr), pull: inputs.pull, pullsForHead: inputs.pullsForHead, commits: inputs.commits, reviews: inputs.reviews, comments: inputs.comments, timeline: inputs.timeline, config });
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
