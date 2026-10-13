#!/usr/bin/env node
/**
 * delivery-receipt.mjs — report-only delivery receipt for one pull request (#160).
 *
 * WHAT IT DOES
 *   `collect` is the only networked step: it shells `gh api`, allowlists the
 *   fields, and writes a frozen evidence bundle. `project` turns that bundle
 *   into a byte-stable `gibson.delivery.v1` receipt. `verify` fails closed
 *   when the receipt disagrees with its digest, its bundle, or the rules below.
 *   Nothing here merges, deploys, or authorizes.
 *
 * WHY
 *   #160 asked for one read model over the facts that already decide a change.
 *   D-014 / D-015 removed owner attestation. G12 for Tier C is E3 at the exact
 *   head plus required checks (memory/DECISIONS.md). The #158 workflow journal
 *   does not exist, so this slice reads GitHub and, when a row matches, the
 *   gibson.cost.v1 ledger. Anything this slice cannot source is `unknown`.
 *
 * RISKS
 *   A receipt proves it is consistent with the bundle it names. It does not
 *   prove the bundle still matches GitHub. Re-collect to re-check. `evaluate()`
 *   in pr-review-evidence.mjs is an open-PR predicate: a merged PR is not open,
 *   so a second call is made only when the bundle shows no other open PR on
 *   that head and the pulls-for-head source is present and exhausted. A
 *   marker keeps only the fields pr-review-evidence reads. Cost, deploy,
 *   cleanup, and lessons do not block `delivered` in this slice.
 *   `rolled_back` is reserved and never emitted.
 *
 * USAGE
 *   node scripts/delivery-receipt.mjs collect --repo OWNER/REPO --pr N --out FILE [--ledger PATH] [--config PATH]
 *   node scripts/delivery-receipt.mjs project --bundle FILE
 *   node scripts/delivery-receipt.mjs verify --receipt FILE [--bundle FILE]
 *   Exit 0 pass, 1 verify/project fail, 2 usage or I/O.
 */

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { evaluate, MARKER_FIELDS, parseBlock, resolveAuthors, trailerVendors, validateConfig } from "./pr-review-evidence.mjs";

const SCHEMA = "gibson.delivery.v1";
const BUNDLE_SCHEMA = "gibson.delivery-bundle.v1";
const SHA40 = /^[0-9a-f]{40}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const REPO = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const VENDORS = new Set(["grok", "codex", "claude", "devin", "coderabbit", "independent", "owner", "human", "unknown"]);
const LEVELS = new Set(["E0", "E1", "E2", "E3", "E4", "unknown"]);
const VERDICTS = new Set(["APPROVE", "CHANGES_REQUESTED", "NONE", "unknown"]);
const CONCLUSIONS = new Set(["success", "failure", "neutral", "cancelled", "timed_out", "action_required", "skipped", "stale", "startup_failure", "unknown"]);
const DISPOSITIONS = new Set(["delivered", "parked", "blocked", "failed", "rolled_back", "incomplete"]);
const TIERS = new Set(["A", "B", "C", "unknown"]);
const SAFE_REASON = /^[a-z0-9][a-z0-9_.:/@+-]{0,119}$/;
const MARKER_RE = /<!--\s*(review-evidence:v1|owner-review-attestation:v1|owner-attested-review:v1)\b[\s\S]*?-->/g;
const TRAILER_LINE = /^Agent-Vendor:[ \t]*[A-Za-z0-9_-]+[ \t]*$/i;

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONFIG = join(SCRIPT_DIR, "..", "config", "review-evidence.v1.json");

function usage(msg) {
  process.stderr.write(`delivery-receipt.mjs: ${msg}\nusage: node scripts/delivery-receipt.mjs <collect|project|verify> [flags]\n`);
  process.exit(2);
}

function help() {
  process.stdout.write(`delivery-receipt.mjs — report-only gibson.delivery.v1 receipt (#160)

WHAT IT DOES
  collect  shells gh api once per source, allowlists fields, writes a bundle
  project  pure: bundle file → canonical receipt on stdout
  verify   fails closed; one reason line per incomplete or contradictory field

WHY
  One deterministic read model over GitHub facts for a single pull request.
  Unknown stays unknown. The receipt grants no merge or deploy authority.

RISKS
  Consistency with the bundle is not proof the bundle still matches GitHub.
  Re-collect to re-check. Cost, deployment, cleanup, and lessons are unknown
  placeholders in this slice and do not block delivered. rolled_back is reserved.

USAGE
  node scripts/delivery-receipt.mjs collect --repo OWNER/REPO --pr N --out FILE [--ledger PATH] [--config PATH]
  node scripts/delivery-receipt.mjs project --bundle FILE
  node scripts/delivery-receipt.mjs verify --receipt FILE [--bundle FILE]
EXIT
  0 pass   1 verify or project fail   2 usage or I/O
`);
}

/** Canonical JSON: keys sorted by UTF-16 code unit, no whitespace, JSON.stringify scalars. */
export function canonicalJson(value, omitRootDigest = false) {
  return canonicalize(value, omitRootDigest);
}

function canonicalize(value, omitDigest) {
  if (value === null) return "null";
  const t = typeof value;
  if (t === "string" || t === "boolean") return JSON.stringify(value);
  if (t === "number") {
    if (!Number.isFinite(value)) throw new Error("canonical:non-finite");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map((v) => canonicalize(v, false)).join(",")}]`;
  if (t !== "object") throw new Error("canonical:bad-type");
  const keys = Object.keys(value).filter((k) => !(omitDigest && k === "digest") && value[k] !== undefined);
  keys.sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalize(value[k], false)}`).join(",")}}`;
}

export function digestHex(value, omitRootDigest = false) {
  return createHash("sha256").update(canonicalJson(value, omitRootDigest), "utf8").digest("hex");
}

function isSha(v) {
  return typeof v === "string" && SHA40.test(v);
}

function safeRepo(v) {
  return typeof v === "string" && REPO.test(v) ? v : null;
}

function safeRef(v) {
  if (typeof v !== "string" || v.length === 0 || v.length > 200) return null;
  if (v.startsWith("/") || v.includes("\\") || v.split("/").includes("..")) return null;
  if (!/^[A-Za-z0-9._/-]+$/.test(v)) return null;
  return v;
}

function safeLogin(v) {
  if (v === "unknown") return "unknown";
  if (typeof v !== "string" || v.length < 1 || v.length > 80) return "unknown";
  if (!/^[A-Za-z0-9][A-Za-z0-9_.[\]-]*$/.test(v)) return "unknown";
  return v;
}

function asVendor(v) {
  return typeof v === "string" && VENDORS.has(v) ? v : "unknown";
}

function normalizeAppId(v) {
  if (v === null || v === undefined) return null;
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0) return null;
  return v;
}

function reasonCode(v) {
  return typeof v === "string" && SAFE_REASON.test(v) ? v : null;
}

function uniq(list) {
  return [...new Set(list)];
}

const FIELD_TOKEN = /^[a-z0-9_-]{1,40}$/;

function cleanAuthorVendor(raw) {
  if (typeof raw !== "string") return null;
  const parts = raw.split(",").map((p) => p.trim()).filter(Boolean);
  if (parts.length === 0 || !parts.every((p) => FIELD_TOKEN.test(p))) return null;
  return parts.join(",");
}

/** Re-serialize one marker from the evaluator's field list. Unexpected text is dropped. */
export function redactMarkerBlock(block) {
  if (typeof block !== "string") return "";
  const named = block.match(/<!--\s*(review-evidence:v1|owner-review-attestation:v1|owner-attested-review:v1)\b/i);
  if (!named) return "";
  const marker = Object.keys(MARKER_FIELDS).find((k) => k.toLowerCase() === named[1].toLowerCase());
  if (!marker) return "";
  const spec = MARKER_FIELDS[marker];
  const parsed = parseBlock(block, marker, spec);
  if (!parsed) return "";
  const fields = { ...parsed };
  if (!isSha(fields["head-sha"])) return "";
  if (marker === "owner-review-attestation:v1") {
    const vendors = cleanAuthorVendor(fields["author-vendor"]);
    if (!vendors) return "";
    fields["author-vendor"] = vendors;
  }
  if (marker === "owner-attested-review:v1" && !FIELD_TOKEN.test(fields["reviewer-vendor"] ?? "")) return "";
  if ((marker === "review-evidence:v1" || marker === "owner-attested-review:v1") && fields.result !== "pass" && fields.result !== "fail") return "";
  const lines = [`<!-- ${marker}`];
  for (const f of spec) lines.push(`${f}: ${fields[f]}`);
  lines.push("-->");
  return lines.join("\n");
}

function retainMarker(block) {
  let redacted = null;
  redacted = redactMarkerBlock(block); // MUTATION_ANCHOR_MARKER_REDACT
  if (redacted == null) return block;
  return redacted;
}

export function markerOnly(body) {
  if (typeof body !== "string" || body.length === 0) return "";
  const out = [];
  MARKER_RE.lastIndex = 0;
  let m = MARKER_RE.exec(body);
  while (m) {
    const kept = retainMarker(m[0]);
    if (kept) out.push(kept);
    m = MARKER_RE.exec(body);
  }
  return out.join("\n");
}

function unsafePath(p) {
  if (p == null) return false;
  if (typeof p !== "string") return true;
  if (p.startsWith("/") || /^[A-Za-z]:[\\/]/.test(p)) return true;
  if (p.split(/[/\\]/).includes("..")) return true;
  return false;
}

export function allowlistPull(p) {
  const labels = [];
  if (Array.isArray(p?.labels)) {
    for (const l of p.labels) {
      const name = typeof l === "string" ? l : l?.name;
      if (typeof name === "string" && /^tier-[abc]$/.test(name)) labels.push({ name });
    }
  }
  return {
    number: Number.isInteger(p?.number) ? p.number : null,
    state: typeof p?.state === "string" ? p.state : null,
    merged: p?.merged === true,
    merge_commit_sha: typeof p?.merge_commit_sha === "string" ? p.merge_commit_sha : null,
    commits: Number.isInteger(p?.commits) ? p.commits : null,
    head: { sha: typeof p?.head?.sha === "string" ? p.head.sha : null },
    base: {
      sha: typeof p?.base?.sha === "string" ? p.base.sha : null,
      ref: typeof p?.base?.ref === "string" ? p.base.ref : null,
    },
    labels,
  };
}

export function allowlistCommit(c) {
  const raw = typeof c?.commit?.message === "string" ? c.commit.message : "";
  const message = raw.split(/\r?\n/).filter((line) => TRAILER_LINE.test(line)).join("\n");
  const login = (side) => (typeof c?.[side]?.login === "string" ? c[side].login : null);
  return {
    sha: typeof c?.sha === "string" ? c.sha : null,
    author: { login: login("author") },
    committer: { login: login("committer") },
    commit: {
      message,
      verification: { verified: c?.commit?.verification?.verified === true },
    },
  };
}

export function allowlistReview(r) {
  return {
    id: typeof r?.id === "number" ? r.id : null,
    user: {
      login: typeof r?.user?.login === "string" ? r.user.login : null,
      type: typeof r?.user?.type === "string" ? r.user.type : null,
    },
    state: typeof r?.state === "string" ? r.state : null,
    commit_id: typeof r?.commit_id === "string" ? r.commit_id : null,
    submitted_at: typeof r?.submitted_at === "string" ? r.submitted_at : null,
  };
}

export function allowlistComment(c) {
  const app = c?.performed_via_github_app;
  const editorLogin = c?.editor?.login ?? (typeof c?.editor === "string" ? c.editor : null);
  const out = {
    id: typeof c?.id === "number" ? c.id : null,
    user: {
      login: typeof c?.user?.login === "string" ? c.user.login : null,
      type: typeof c?.user?.type === "string" ? c.user.type : null,
    },
    author_association: typeof c?.author_association === "string" ? c.author_association : null,
    performed_via_github_app: app && typeof app === "object"
      ? { slug: typeof app.slug === "string" ? app.slug : null, id: typeof app.id === "number" ? app.id : null }
      : null,
    created_at: typeof c?.created_at === "string" ? c.created_at : null,
    body: markerOnly(c?.body),
  };
  if (c?.edited === true) out.edited = true;
  if (typeof editorLogin === "string" && editorLogin) out.editor = { login: editorLogin };
  return out;
}

export function allowlistFile(f) {
  const filename = typeof f?.filename === "string" ? f.filename : null;
  const previous = typeof f?.previous_filename === "string" ? f.previous_filename : null;
  if (unsafePath(filename) || unsafePath(previous)) return null;
  const out = { filename };
  if (previous) out.previous_filename = previous;
  return out;
}

export function allowlistTimeline(ev) {
  return {
    event: typeof ev?.event === "string" ? ev.event : null,
    created_at: typeof ev?.created_at === "string" ? ev.created_at : null,
  };
}

export function allowlistPullRef(p) {
  return {
    number: Number.isInteger(p?.number) ? p.number : null,
    state: typeof p?.state === "string" ? p.state : null,
    head: { sha: typeof p?.head?.sha === "string" ? p.head.sha : null },
  };
}

function mapConclusion(raw) {
  if (raw === "error") return "failure";
  if (raw === "pending" || raw === null || raw === undefined || raw === "") return "unknown";
  const v = typeof raw === "string" ? raw : "unknown";
  return CONCLUSIONS.has(v) ? v : "unknown";
}

function tierOf(labels) {
  const names = [];
  if (Array.isArray(labels)) {
    for (const l of labels) {
      const name = typeof l === "string" ? l : l?.name;
      if (typeof name === "string" && /^tier-[abc]$/.test(name)) names.push(name);
    }
  }
  if (names.length !== 1) return "unknown";
  return names[0].slice(-1).toUpperCase();
}

function appMatches(req, run) {
  if (req.appId != null && run.appId !== req.appId) return false; // MUTATION_ANCHOR_APP_ID
  return true;
}

/** A required check matches one run on context, and on app id when the requirement names one. */
export function matchChecks(required, gates, headSha) {
  if (!required || required.status !== "known" || !Array.isArray(required.entries)) {
    return { ok: false, failed: false, reasons: ["required-checks-unknown"] };
  }
  const reasons = [];
  let failed = false;
  const runs = Array.isArray(gates) ? gates : [];
  for (const req of required.entries) {
    const context = typeof req?.context === "string" ? req.context : "";
    const hits = runs.filter((r) => r && r.name === context && r.headSha === headSha && appMatches(req, r));
    if (hits.length !== 1) {
      reasons.push("required-check-unmatched");
      continue;
    }
    const hit = hits[0];
    if (typeof hit.appSlug !== "string" || hit.appSlug.length === 0) {
      reasons.push("required-check-no-app-slug");
      continue;
    }
    if (hit.conclusion === "failure") {
      failed = true;
      reasons.push("required-check-failed");
      continue;
    }
    if (hit.conclusion !== "success") reasons.push("required-check-not-success");
  }
  return { ok: reasons.length === 0, failed, reasons: uniq(reasons) };
}

function costVendor(ev) {
  if (VENDORS.has(ev?.runner) && ev.runner !== "unknown") return ev.runner;
  if (VENDORS.has(ev?.provider) && ev.provider !== "unknown") return ev.provider;
  return "unknown";
}

/** gibson.cost.v1 join: a conflicting join_key, or no unique PR match, is unknown. Never summed. */
export function joinCost(events, prNumber) {
  if (!Array.isArray(events) || events.length === 0) return { status: "unknown" };
  const joinToPr = new Map();
  for (const ev of events) {
    if (!ev || ev.schema !== "gibson.cost.v1" || typeof ev.ts !== "string") return { status: "unknown" };
    if (ev.pr != null && (!Number.isInteger(ev.pr) || ev.pr < 0)) return { status: "unknown" };
    const jk = ev.join_key;
    if (typeof jk === "string" && jk && Number.isInteger(ev.pr)) {
      if (joinToPr.has(jk) && joinToPr.get(jk) !== ev.pr) return { status: "unknown" };
      joinToPr.set(jk, ev.pr);
    }
  }
  const rows = [];
  for (const ev of events) {
    let resolved = Number.isInteger(ev.pr) ? ev.pr : null;
    if (resolved == null && typeof ev.join_key === "string" && ev.join_key && joinToPr.has(ev.join_key)) {
      resolved = joinToPr.get(ev.join_key);
    }
    if (resolved !== prNumber) continue;
    rows.push({
      ts: ev.ts,
      vendor: costVendor(ev),
      model: null,
      usd: null,
      tokensIn: null,
      tokensOut: null,
    });
  }
  if (rows.length === 0) return { status: "unknown" };
  rows.sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : a.vendor < b.vendor ? -1 : a.vendor > b.vendor ? 1 : 0));
  return { status: "joined", rows, usdTotal: null };
}

function actor(login, vendor) {
  return { login: safeLogin(login), vendor: asVendor(vendor) };
}

function singleVendor(list) {
  const vals = uniq((list ?? []).filter((v) => typeof v === "string" && v && v !== "unknown"));
  if (vals.length !== 1) return "unknown";
  return asVendor(vals[0]);
}

/**
 * evaluate() refuses a head that is not the sole open PR at that SHA. A merged
 * PR is not open, so the direct call returns ambiguous-head even when no other
 * open PR shares the head. Replay only in that case, with this PR as the sole
 * open owner. Any other open PR at the head keeps the direct refusal.
 */
export function evaluateBundle(inputs, prNumber) {
  const pull = inputs?.pull ?? {};
  const head = typeof pull?.head?.sha === "string" ? pull.head.sha.toLowerCase() : "";
  const config = inputs?.config;
  const commits = Array.isArray(inputs?.commits) ? inputs.commits : [];
  const reviews = Array.isArray(inputs?.reviews) ? inputs.reviews : [];
  const comments = Array.isArray(inputs?.comments) ? inputs.comments : [];
  const timeline = Array.isArray(inputs?.timeline) ? inputs.timeline : [];
  const pullsForHead = Array.isArray(inputs?.pullsForHead) ? inputs.pullsForHead : null;
  const files = Array.isArray(inputs?.files) ? inputs.files : undefined;
  // R1: call the existing helpers. Do not re-decide identity or evidence.
  const trailers = [];
  for (const c of commits) trailers.push(...trailerVendors(c?.commit?.message));
  const authors = resolveAuthors(commits, config?.identities ?? [], null, { relaxed: true });
  const args = {
    headSha: head,
    expectedHead: head,
    prNumber,
    pull,
    pullsForHead: pullsForHead ?? [],
    commits,
    reviews,
    comments,
    timeline,
    config,
    files,
  };
  let result = evaluate(args);
  let replayed = false;
  const merged = pull?.merged === true && pull?.state === "closed" && isSha(typeof pull?.merge_commit_sha === "string" ? pull.merge_commit_sha.toLowerCase() : "");
  const openOthers = (pullsForHead ?? []).filter((p) => p?.state === "open" && typeof p?.head?.sha === "string" && p.head.sha.toLowerCase() === head && Number(p?.number) !== prNumber);
  if (result?.reason === "ambiguous-head" && merged && Array.isArray(pullsForHead) && openOthers.length === 0 && inputs?.pullsForHeadStatus !== "unknown") {
    result = evaluate({
      ...args,
      pull: { ...pull, state: "open" },
      pullsForHead: [{ number: prNumber, state: "open", head: { sha: head } }],
    });
    replayed = true;
  }
  return { result, authors, trailers, replayed, head };
}

function reviewFromEvaluation(ev, reviews) {
  const result = ev.result ?? {};
  const head = ev.head;
  const authorVendors = Array.isArray(result.authorVendors) ? result.authorVendors : [...(ev.authors?.vendors ?? [])];
  const builderVendor = singleVendor(authorVendors);
  const evidence = Array.isArray(result.evidence) ? result.evidence : [];
  const passLogins = [];
  let source = "unknown";
  for (const row of evidence) {
    const parts = String(row).split(":");
    if (parts.length < 3) continue;
    const login = parts[0];
    const verdict = parts[1];
    const src = parts.slice(2).join(":");
    if (verdict === "pass") {
      passLogins.push(login);
      source = src === "review" || src === "comment" ? src : "unknown";
    }
  }
  const reviewerLogin = passLogins.length === 1 ? passLogins[0] : "unknown";
  const reviewerVendor = "unknown";
  const observed = observedReviewSha(reviews, head);
  let verdict = "NONE";
  let level = "unknown";
  let reviewedHeadSha = observed && observed !== head ? observed : null;
  if (result.state === "success" && result.reason === "pass") {
    verdict = "APPROVE";
    reviewedHeadSha = head;
    level = "E3";
  } else if (result.reason === "changes-requested") {
    verdict = "CHANGES_REQUESTED";
    level = "unknown";
  } else if (result.reason === "same-vendor-reviewer") {
    verdict = evidence.some((row) => String(row).includes(":pass:")) ? "APPROVE" : "NONE";
    level = "E1";
    reviewedHeadSha = head;
  } else if (result.reason === "no-receipt-at-head") {
    verdict = "NONE";
    level = "E0";
  } else if (result.reason === "stale-head-only" || result.reason === "stale-base" || result.reason === "evidence-deleted") {
    verdict = "NONE";
    level = "unknown";
  }
  const token = reasonCode(result.reason);
  return {
    builderVendor,
    reviewerLogin,
    reviewerVendor,
    review: {
      independenceLevel: level,
      reviewedHeadSha,
      reviewerVendor,
      verdict,
      source: verdict === "NONE" || verdict === "unknown" ? "unknown" : source,
    },
    evaluateReason: token,
    passLogins,
    authorVendors,
  };
}

function observedReviewSha(reviews, head) {
  let best = null;
  let bestAt = -1;
  for (const r of reviews ?? []) {
    const sha = typeof r?.commit_id === "string" ? r.commit_id.toLowerCase() : "";
    if (!isSha(sha) || sha === head) continue;
    const at = Date.parse(r?.submitted_at ?? "") || 0;
    if (at >= bestAt) {
      bestAt = at;
      best = sha;
    }
  }
  return best;
}

function vendorOfLogin(config, login) {
  if (!login || login === "unknown") return "unknown";
  const id = (config?.identities ?? []).find((i) => String(i?.login ?? "").toLowerCase() === String(login).toLowerCase());
  return asVendor(id?.vendor);
}

function paginationOk(sources) {
  if (!Array.isArray(sources) || sources.length === 0) return false;
  for (const s of sources) {
    if (!sourceRecordOk(s)) return false;
  }
  return true;
}

/** Every endpoint collect() records, in collect order. `{branch}` is encodeURIComponent(base ref). */
export const REQUIRED_SOURCE_TEMPLATES = [
  "repos/{repository}",
  "repos/{repository}/pulls/{pr}",
  "repos/{repository}/pulls/{pr}/commits",
  "repos/{repository}/pulls/{pr}/reviews",
  "repos/{repository}/issues/{pr}/comments",
  "repos/{repository}/commits/{head}/pulls",
  "repos/{repository}/issues/{pr}/timeline",
  "repos/{repository}/pulls/{pr}/files",
  "repos/{repository}/commits/{head}/check-runs",
  "repos/{repository}/commits/{head}/statuses",
  "repos/{repository}/branches/{branch}/protection/required_status_checks",
  "repos/{repository}/rules/branches/{branch}",
  "graphql:closing-issues",
  "graphql:comment-editors",
];

const PULLS_FOR_HEAD_TEMPLATE = "repos/{repository}/commits/{head}/pulls";

function sourceRecordOk(s) {
  if (!s || typeof s.endpoint !== "string") return false;
  if (s.endpoint.includes("://") || s.endpoint.startsWith("/") || s.endpoint.split("/").includes("..")) return false;
  if (s.exhausted !== true) return false;
  if (!Number.isInteger(s.pages) || s.pages < 1) return false;
  if (typeof s.sha256 !== "string" || !SHA256.test(s.sha256)) return false;
  return true;
}

export function requiredSourceEndpoints(subject) {
  const repository = subject?.repository;
  const pr = subject?.pr;
  const head = typeof subject?.head === "string" ? subject.head.toLowerCase() : "";
  const branch = typeof subject?.branch === "string" ? subject.branch : null;
  if (typeof repository !== "string" || !REPO.test(repository)) return null;
  if (!Number.isInteger(pr) || pr < 1 || !isSha(head) || branch == null) return null;
  const map = {
    "{repository}": repository,
    "{pr}": String(pr),
    "{head}": head,
    "{branch}": encodeURIComponent(branch),
  };
  return REQUIRED_SOURCE_TEMPLATES.map((t) => t.replace(/\{repository\}|\{pr\}|\{head\}|\{branch\}/g, (k) => map[k]));
}

function inventorySatisfied(sources, required) {
  if (!Array.isArray(sources) || !Array.isArray(required)) return false;
  if (sources.length !== required.length) return false;
  const seen = new Set();
  for (const s of sources) {
    if (!s || typeof s.endpoint !== "string" || seen.has(s.endpoint)) return false;
    if (!required.includes(s.endpoint)) return false;
    seen.add(s.endpoint);
  }
  return seen.size === required.length;
}

/**
 * Loose paginationOk accepts any exhausted list. Delivered requires the
 * collector's inventory exactly once, each exhausted. pulls-for-head is
 * "known" only when that source itself is present and exhausted.
 */
export function bindSourceInventory(bundle) {
  const inputs = bundle?.inputs ?? {};
  const pull = inputs.pull ?? {};
  const head = typeof pull?.head?.sha === "string" ? pull.head.sha.toLowerCase() : "";
  const branch = typeof pull?.base?.ref === "string" ? pull.base.ref : "";
  const required = requiredSourceEndpoints({
    repository: bundle?.repository,
    pr: bundle?.pr,
    head,
    branch,
  });
  const sources = Array.isArray(bundle?.sources) ? bundle.sources : [];
  const paginationExhausted = paginationOk(sources) && inventorySatisfied(sources, required);
  let pullsForHeadStatus = "unknown";
  if (required && inputs.pullsForHeadStatus === "known") {
    const ep = required[REQUIRED_SOURCE_TEMPLATES.indexOf(PULLS_FOR_HEAD_TEMPLATE)];
    const hits = sources.filter((s) => s && s.endpoint === ep);
    if (hits.length === 1 && sourceRecordOk(hits[0])) pullsForHeadStatus = "known";
  }
  return { paginationExhausted, pullsForHeadStatus };
}

function deliveredGaps(facts) {
  const reasons = [];
  if (facts.review.verdict !== "APPROVE") reasons.push("review-not-approve");
  if (facts.review.reviewedHeadSha !== facts.subject.headSha) reasons.push("head-mismatch"); // MUTATION_ANCHOR_HEAD_EQUALITY
  if (facts.actors.builder.vendor === "unknown" || facts.review.reviewerVendor === "unknown") reasons.push("vendor-unknown"); // MUTATION_ANCHOR_UNKNOWN_VENDOR
  if (facts.actors.builder.vendor !== "unknown" && facts.review.reviewerVendor === facts.actors.builder.vendor) reasons.push("vendor-not-independent");
  const checks = matchChecks(facts.requiredChecks, facts.gates, facts.subject.headSha);
  if (!checks.ok) reasons.push(...checks.reasons.filter((r) => r !== "required-check-failed"));
  if (facts.g12.applies === true && facts.g12.met !== true) reasons.push("g12-not-met");
  if (facts.paginationExhausted !== true) reasons.push("pagination-not-exhausted"); // MUTATION_ANCHOR_PAGINATION
  if (facts.commentEditors?.status !== "known") reasons.push("comment-editors-unknown");
  if (facts.review.independenceLevel !== "E3") reasons.push("not-e3");
  return uniq(reasons);
}

function deriveG12(facts) {
  const applies = facts.tier === "C" || facts.tier === "unknown";
  const checks = matchChecks(facts.requiredChecks, facts.gates, facts.subject.headSha);
  const headBound = facts.review.reviewedHeadSha === facts.subject.headSha;
  const levelOk = facts.review.independenceLevel === "E3";
  let met;
  if (facts.requiredChecks?.status !== "known") met = "unknown";
  else met = levelOk && headBound && checks.ok;
  const reasons = [];
  reasons.push(facts.tier === "unknown" ? "tier-unknown-assumed-c" : applies ? "tier-c" : "tier-not-c");
  reasons.push(levelOk ? "level-e3" : "level-not-e3");
  reasons.push(headBound ? "head-bound" : "head-unbound");
  if (facts.requiredChecks?.status !== "known") reasons.push("checks-unknown");
  else reasons.push(checks.ok ? "checks-success" : "checks-not-success");
  return { applies, met, reasons };
}

/** First match wins. rolled_back is not a return of this function. */
export function decideDisposition(facts) {
  if (facts.contradictory) return { disposition: "incomplete", reasons: ["contradictory"] };
  if (facts.closedUnmerged) return { disposition: "failed", reasons: ["closed-unmerged"] };
  if (facts.open) {
    const checks = matchChecks(facts.requiredChecks, facts.gates, facts.subject.headSha);
    const reviewFail = facts.review.verdict === "CHANGES_REQUESTED";
    if (checks.failed || reviewFail) {
      const reasons = [];
      if (checks.failed) reasons.push("required-check-failed");
      if (reviewFail) reasons.push("review-fail");
      return { disposition: "blocked", reasons };
    }
    return { disposition: "parked", reasons: ["open"] };
  }
  if (!facts.merged) return { disposition: "incomplete", reasons: ["not-merged"] };
  if (facts.baseRef !== facts.defaultBranch) return { disposition: "incomplete", reasons: ["non-default-base"] }; // MUTATION_ANCHOR_NON_DEFAULT_BASE
  const gaps = deliveredGaps(facts);
  if (gaps.length === 0) return { disposition: "delivered", reasons: [] };
  return { disposition: "incomplete", reasons: gaps };
}

function blankUnknowns() {
  return {
    policyManifestDigest: "unknown",
    deployment: { status: "unknown" },
    cleanup: { status: "unknown" },
    lessons: { status: "unknown" },
  };
}

function factsFromParts(parts) {
  const g12 = deriveG12(parts);
  const facts = { ...parts, g12 };
  const decision = decideDisposition(facts);
  return { facts, decision };
}

export function projectBundle(bundle) {
  if (!bundle || typeof bundle !== "object" || Array.isArray(bundle)) {
    throw new Error("project:not-an-object");
  }
  assertBundleRedacted(bundle); // MUTATION_ANCHOR_BUNDLE_LEAK
  if (bundle.schema !== BUNDLE_SCHEMA) throw new Error("project:bundle-schema");
  const repo = safeRepo(bundle.repository);
  const pr = bundle.pr;
  if (!repo || !Number.isInteger(pr) || pr < 1) throw new Error("project:subject");
  const inputs = bundle.inputs;
  if (!inputs || typeof inputs !== "object") throw new Error("project:inputs");
  let config;
  try {
    config = validateConfig(inputs.config);
  } catch (e) {
    throw new Error(`project:${e.message ?? "config"}`);
  }
  const pull = inputs.pull ?? {};
  const head = typeof pull?.head?.sha === "string" ? pull.head.sha.toLowerCase() : "";
  const base = typeof pull?.base?.sha === "string" ? pull.base.sha.toLowerCase() : "";
  if (!isSha(head) || !isSha(base)) throw new Error("project:subject-sha");
  const mergeRaw = typeof pull?.merge_commit_sha === "string" ? pull.merge_commit_sha.toLowerCase() : null;
  const mergeSha = mergeRaw && isSha(mergeRaw) ? mergeRaw : null;
  const issue = Number.isInteger(inputs.issue) && inputs.issue > 0 ? inputs.issue : null;
  let sourceGate = {
    paginationExhausted: paginationOk(bundle.sources),
    pullsForHeadStatus: inputs.pullsForHeadStatus === "known" ? "known" : "unknown",
  };
  sourceGate = bindSourceInventory(bundle); // MUTATION_ANCHOR_SOURCE_INVENTORY
  const ev = evaluateBundle({ ...inputs, config, pullsForHeadStatus: sourceGate.pullsForHeadStatus }, pr);
  const shaped = reviewFromEvaluation(ev, inputs.reviews);
  if (shaped.passLogins.length === 1) {
    shaped.reviewerLogin = shaped.passLogins[0];
    shaped.review.reviewerVendor = vendorOfLogin(config, shaped.passLogins[0]);
  } else {
    shaped.reviewerLogin = "unknown";
    shaped.review.reviewerVendor = "unknown";
  }
  // evaluate() already refused a same-vendor pass. If the resolved author
  // vendors still contain the reviewer, record E1 so this cannot stay E3.
  // Unknown vendor stays on the actor fields. deliveredGaps rejects it.
  // Downgrading the level here would hide that rejection behind not-e3.
  if (
    shaped.review.verdict === "APPROVE"
    && shaped.review.independenceLevel === "E3"
    && shaped.review.reviewerVendor !== "unknown"
    && shaped.builderVendor !== "unknown"
    && shaped.authorVendors.includes(shaped.review.reviewerVendor)
  ) {
    shaped.review.independenceLevel = "E1";
  }
  const builderLogins = new Set();
  for (const c of inputs.commits ?? []) {
    if (typeof c?.author?.login === "string") builderLogins.add(c.author.login);
  }
  const builderLogin = builderLogins.size === 1 ? [...builderLogins][0] : "unknown";
  const requiredChecks = normalizeRequired(inputs.requiredChecks);
  const gates = normalizeGates(inputs.checkRuns, head);
  const cost = joinCost(inputs.costEvents, pr);
  const baseRef = safeRef(pull?.base?.ref);
  const defaultBranch = safeRef(inputs.repository?.defaultBranch);
  const paginationExhausted = sourceGate.paginationExhausted;
  const commentEditors = inputs.commentEditors?.status === "known" ? { status: "known" } : { status: "unknown" };
  const contradictory = pull?.merged === true && pull?.state === "open";
  const state = typeof pull?.state === "string" ? pull.state : "";
  const merged = state === "closed" && pull?.merged === true && mergeSha != null;
  const closedUnmerged = state === "closed" && !merged;
  const open = state === "open";
  const parts = {
    contradictory,
    closedUnmerged,
    open,
    merged,
    baseRef,
    defaultBranch,
    paginationExhausted,
    commentEditors,
    tier: tierOf(pull?.labels),
    subject: { repository: repo, pr, issue, baseSha: base, headSha: head, mergeSha: merged ? mergeSha : mergeSha },
    actors: {
      builder: actor(builderLogin, shaped.builderVendor),
      reviewer: actor(shaped.reviewerLogin, shaped.review.reviewerVendor),
      releaser: actor("unknown", "unknown"),
    },
    review: {
      ...shaped.review,
      reviewerVendor: shaped.review.reviewerVendor,
    },
    gates,
    requiredChecks,
  };
  // Reviewed head on an APPROVE is the PR head only when evaluate bound it there.
  if (parts.review.verdict === "APPROVE" && parts.review.reviewedHeadSha !== head) {
    parts.contradictory = true;
  }
  const { facts, decision } = factsFromParts(parts);
  const reasons = decision.reasons.slice();
  const receipt = {
    schema: SCHEMA,
    schemaVersion: "1.0.0",
    authority: "report-only",
    subject: {
      repository: repo,
      pr,
      issue,
      baseSha: base,
      headSha: head,
      mergeSha: null,
    },
    actors: facts.actors,
    review: facts.review,
    gates,
    requiredChecks,
    tier: facts.tier,
    g12: facts.g12,
    ...blankUnknowns(),
    cost,
    baseRef,
    defaultBranch,
    paginationExhausted,
    commentEditors,
    disposition: decision.disposition,
    reasons,
    bundleDigest: digestHex(bundle, false),
  };
  if (merged) receipt.subject.mergeSha = mergeSha;
  receipt.digest = digestHex(receipt, true);
  assertReceiptShape(receipt);
  if (receipt.disposition === "rolled_back") throw new Error("project:rolled-back-reserved");
  return receipt;
}

function normalizeRequired(raw) {
  if (!raw || (raw.status !== "known" && raw.status !== "unknown")) return { status: "unknown", entries: [] };
  if (raw.status === "unknown") return { status: "unknown", entries: [] };
  if (!Array.isArray(raw.entries)) return { status: "unknown", entries: [] };
  const entries = [];
  const seen = new Set();
  for (const e of raw.entries) {
    const context = typeof e?.context === "string" ? e.context : "";
    if (!context || context.length > 200 || unsafePath(context)) return { status: "unknown", entries: [] };
    const appId = e?.appId == null ? null : normalizeAppId(e.appId);
    if (e?.appId != null && appId == null) return { status: "unknown", entries: [] };
    const key = `${context}\0${appId}`;
    if (seen.has(key)) continue;
    seen.add(key);
    entries.push({ context, appId });
  }
  entries.sort((a, b) => (a.context < b.context ? -1 : a.context > b.context ? 1 : (a.appId ?? -1) - (b.appId ?? -1)));
  return { status: "known", entries };
}

function normalizeGates(runs, head) {
  if (!Array.isArray(runs)) return [];
  const gates = [];
  for (const r of runs) {
    const name = typeof r?.name === "string" ? r.name : "";
    if (!name || name.length > 200 || unsafePath(name)) continue;
    const sha = typeof r?.headSha === "string" ? r.headSha.toLowerCase() : "";
    if (sha !== head) continue;
    const appId = r?.appId == null ? null : normalizeAppId(r.appId);
    const appSlug = typeof r?.appSlug === "string" && /^[A-Za-z0-9_.-]{1,80}$/.test(r.appSlug) ? r.appSlug : null;
    const completedAt = typeof r?.completedAt === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(r.completedAt) ? r.completedAt : null;
    gates.push({
      name,
      conclusion: mapConclusion(r?.conclusion),
      appSlug,
      appId,
      headSha: sha,
      completedAt,
    });
  }
  gates.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : (a.appId ?? -1) - (b.appId ?? -1)));
  return gates;
}

function factsFromReceipt(receipt) {
  const stateOpen = false;
  return {
    contradictory: false,
    closedUnmerged: receipt.disposition === "failed",
    open: receipt.disposition === "parked" || receipt.disposition === "blocked",
    merged: receipt.subject.mergeSha != null && receipt.disposition !== "failed" && receipt.disposition !== "parked" && receipt.disposition !== "blocked",
    baseRef: receipt.baseRef,
    defaultBranch: receipt.defaultBranch,
    paginationExhausted: receipt.paginationExhausted === true,
    commentEditors: receipt.commentEditors,
    tier: receipt.tier,
    subject: receipt.subject,
    actors: receipt.actors,
    review: receipt.review,
    gates: receipt.gates,
    requiredChecks: receipt.requiredChecks,
    g12: receipt.g12,
  };
}

function digestMismatch(receipt, bundle) {
  let bad = false;
  try {
    if (digestHex(receipt, true) !== receipt.digest) bad = true;
  } catch {
    bad = true;
  }
  if (bundle) {
    try {
      if (digestHex(bundle, false) !== receipt.bundleDigest) bad = true;
    } catch {
      bad = true;
    }
  }
  return bad;
}

export function verifyReceipt(receipt, bundle) {
  const reasons = [];
  const shape = receiptShapeErrors(receipt);
  if (shape.length > 0) return { ok: false, reasons: shape };
  if (digestMismatch(receipt, bundle)) reasons.push("contradictory"); // MUTATION_ANCHOR_DIGEST
  if (bundle) {
    let projected;
    try {
      projected = projectBundle(bundle);
    } catch (e) {
      reasons.push("contradictory");
      return { ok: false, reasons: uniq(reasons) };
    }
    const left = canonicalJson({ ...receipt, digest: undefined }, true);
    const right = canonicalJson({ ...projected, digest: undefined }, true);
    if (left !== right) reasons.push("contradictory");
  } else {
    // Without a bundle, re-derive from the receipt fields. A delivered claim
    // still has to satisfy the same rules. Parked/blocked/failed are trusted
    // only when the field-level rules do not show a stronger contradiction.
    const derived = deriveFromReceiptFields(receipt);
    if (derived.disposition !== receipt.disposition) reasons.push("contradictory");
    else if (canonicalJson(derived.reasons) !== canonicalJson(receipt.reasons)) reasons.push("contradictory");
    const g12 = deriveG12(factsFromReceipt(receipt));
    if (canonicalJson(g12) !== canonicalJson(receipt.g12)) reasons.push("contradictory");
  }
  return { ok: reasons.length === 0, reasons: uniq(reasons) };
}

function deriveFromReceiptFields(receipt) {
  const facts = factsFromReceipt(receipt);
  // The receipt does not store PR state. Disposition is re-checked against the
  // fields the delivered rules need. Non-delivered dispositions must still be
  // internally consistent with those fields.
  if (receipt.disposition === "delivered") {
    facts.merged = true;
    facts.open = false;
    facts.closedUnmerged = false;
    facts.contradictory = false;
    const decision = decideDisposition(facts);
    return decision;
  }
  if (receipt.disposition === "failed") {
    if (receipt.reasons.length === 1 && receipt.reasons[0] === "closed-unmerged") {
      return { disposition: "failed", reasons: ["closed-unmerged"] };
    }
    return { disposition: "incomplete", reasons: ["contradictory"] };
  }
  if (receipt.disposition === "parked" || receipt.disposition === "blocked") {
    facts.open = true;
    facts.merged = false;
    facts.closedUnmerged = false;
    const decision = decideDisposition(facts);
    return decision;
  }
  if (receipt.disposition === "incomplete") {
    facts.merged = receipt.subject.mergeSha != null || receipt.reasons.includes("non-default-base") || receipt.reasons.includes("review-not-approve") || receipt.reasons.includes("head-mismatch") || receipt.reasons.includes("vendor-unknown") || receipt.reasons.includes("g12-not-met") || receipt.reasons.includes("not-e3") || receipt.reasons.includes("pagination-not-exhausted") || receipt.reasons.includes("required-checks-unknown") || receipt.reasons.includes("required-check-unmatched") || receipt.reasons.includes("ambiguous-head") || receipt.reasons.includes("identity-unresolved") || receipt.reasons.includes("stale-head-only") || receipt.reasons.includes("stale-base") || receipt.reasons.includes("same-vendor-reviewer") || receipt.reasons.includes("no-receipt-at-head") || receipt.reasons.includes("not-merged") || receipt.reasons.includes("contradictory") || receipt.reasons.includes("comment-editors-unknown") || receipt.reasons.includes("vendor-not-independent") || receipt.reasons.includes("required-check-no-app-slug") || receipt.reasons.includes("required-check-not-success");
    facts.open = false;
    facts.closedUnmerged = false;
    facts.contradictory = receipt.reasons.includes("contradictory");
    if (facts.contradictory) return { disposition: "incomplete", reasons: ["contradictory"] };
    if (receipt.subject.mergeSha == null && receipt.reasons.includes("not-merged")) {
      facts.merged = false;
    }
    // Merged-shaped incomplete: a merge sha, or reasons that only apply once merged.
    if (receipt.subject.mergeSha != null || receipt.reasons.includes("non-default-base")) {
      facts.merged = true;
      const decision = decideDisposition(facts);
      return decision;
    }
    return { disposition: "incomplete", reasons: receipt.reasons.slice() };
  }
  return { disposition: "incomplete", reasons: ["contradictory"] };
}

function receiptShapeErrors(receipt) {
  try {
    assertReceiptShape(receipt);
    return [];
  } catch (e) {
    return [`schema:${String(e.message ?? "invalid").slice(0, 80)}`];
  }
}

function assertReceiptShape(r) {
  const fail = (d) => { throw new Error(d); };
  if (!r || typeof r !== "object" || Array.isArray(r)) fail("not-an-object");
  const keys = new Set(Object.keys(r));
  const need = ["schema", "schemaVersion", "authority", "subject", "actors", "review", "gates", "requiredChecks", "tier", "g12", "policyManifestDigest", "cost", "deployment", "cleanup", "lessons", "baseRef", "defaultBranch", "paginationExhausted", "commentEditors", "disposition", "reasons", "bundleDigest", "digest"];
  for (const k of need) if (!keys.has(k)) fail(`missing:${k}`);
  for (const k of keys) if (!need.includes(k)) fail(`unknown-key:${k}`);
  if (r.schema !== SCHEMA) fail("schema");
  if (r.schemaVersion !== "1.0.0") fail("schemaVersion");
  if (r.authority !== "report-only") fail("authority");
  if (r.policyManifestDigest !== "unknown") fail("policyManifestDigest");
  if (!TIERS.has(r.tier)) fail("tier");
  if (!DISPOSITIONS.has(r.disposition)) fail("disposition");
  if (typeof r.paginationExhausted !== "boolean") fail("paginationExhausted");
  if (typeof r.bundleDigest !== "string" || !SHA256.test(r.bundleDigest)) fail("bundleDigest");
  if (typeof r.digest !== "string" || !SHA256.test(r.digest)) fail("digest");
  if (r.baseRef !== null && safeRef(r.baseRef) !== r.baseRef) fail("baseRef");
  if (r.defaultBranch !== null && safeRef(r.defaultBranch) !== r.defaultBranch) fail("defaultBranch");
  assertSubject(r.subject);
  assertActors(r.actors);
  assertReview(r.review);
  if (!Array.isArray(r.gates)) fail("gates");
  for (const g of r.gates) assertGate(g);
  assertRequired(r.requiredChecks);
  assertG12(r.g12);
  assertCost(r.cost);
  for (const k of ["deployment", "cleanup", "lessons"]) assertUnknownStatus(r[k], k);
  assertCommentEditors(r.commentEditors);
  if (!Array.isArray(r.reasons)) fail("reasons");
  for (const reason of r.reasons) if (!reasonCode(reason)) fail("reasons");
}

function assertSubject(s) {
  const fail = (d) => { throw new Error(`subject:${d}`); };
  if (!s || typeof s !== "object" || Array.isArray(s)) fail("type");
  const keys = Object.keys(s);
  for (const k of keys) if (!["repository", "pr", "issue", "baseSha", "headSha", "mergeSha"].includes(k)) fail(`unknown-key:${k}`);
  for (const k of ["repository", "pr", "issue", "baseSha", "headSha", "mergeSha"]) if (!keys.includes(k)) fail(`missing:${k}`);
  if (safeRepo(s.repository) !== s.repository) fail("repository");
  if (!Number.isInteger(s.pr) || s.pr < 1) fail("pr");
  if (!(s.issue === null || (Number.isInteger(s.issue) && s.issue > 0))) fail("issue");
  if (!isSha(s.baseSha) || !isSha(s.headSha)) fail("sha");
  if (!(s.mergeSha === null || isSha(s.mergeSha))) fail("mergeSha");
}

function assertActors(a) {
  const fail = (d) => { throw new Error(`actors:${d}`); };
  if (!a || typeof a !== "object" || Array.isArray(a)) fail("type");
  const keys = Object.keys(a);
  for (const k of ["builder", "reviewer", "releaser"]) if (!keys.includes(k)) fail(`missing:${k}`);
  for (const k of keys) if (!["builder", "reviewer", "releaser"].includes(k)) fail(`unknown-key:${k}`);
  for (const role of ["builder", "reviewer", "releaser"]) assertActor(a[role], role);
}

function assertActor(a, role) {
  const fail = (d) => { throw new Error(`${role}:${d}`); };
  if (!a || typeof a !== "object" || Array.isArray(a)) fail("type");
  const keys = Object.keys(a);
  if (keys.length !== 2 || !keys.includes("login") || !keys.includes("vendor")) fail("keys");
  if (safeLogin(a.login) !== a.login) fail("login");
  if (!VENDORS.has(a.vendor)) fail("vendor");
}

function assertReview(rv) {
  const fail = (d) => { throw new Error(`review:${d}`); };
  if (!rv || typeof rv !== "object" || Array.isArray(rv)) fail("type");
  const need = ["independenceLevel", "reviewedHeadSha", "reviewerVendor", "verdict", "source"];
  const keys = Object.keys(rv);
  for (const k of need) if (!keys.includes(k)) fail(`missing:${k}`);
  for (const k of keys) if (!need.includes(k)) fail(`unknown-key:${k}`);
  if (!LEVELS.has(rv.independenceLevel)) fail("independenceLevel");
  if (!(rv.reviewedHeadSha === null || isSha(rv.reviewedHeadSha))) fail("reviewedHeadSha");
  if (!VENDORS.has(rv.reviewerVendor)) fail("reviewerVendor");
  if (!VERDICTS.has(rv.verdict)) fail("verdict");
  if (!["review", "comment", "unknown"].includes(rv.source)) fail("source");
}

function assertGate(g) {
  const fail = (d) => { throw new Error(`gate:${d}`); };
  if (!g || typeof g !== "object" || Array.isArray(g)) fail("type");
  const need = ["name", "conclusion", "appSlug", "appId", "headSha", "completedAt"];
  const keys = Object.keys(g);
  for (const k of need) if (!keys.includes(k)) fail(`missing:${k}`);
  for (const k of keys) if (!need.includes(k)) fail(`unknown-key:${k}`);
  if (typeof g.name !== "string" || g.name.length < 1 || g.name.length > 200 || unsafePath(g.name)) fail("name");
  if (!CONCLUSIONS.has(g.conclusion)) fail("conclusion");
  if (!(g.appSlug === null || (typeof g.appSlug === "string" && /^[A-Za-z0-9_.-]{1,80}$/.test(g.appSlug)))) fail("appSlug");
  if (!(g.appId === null || (Number.isInteger(g.appId) && g.appId >= 0))) fail("appId");
  if (!isSha(g.headSha)) fail("headSha");
  if (!(g.completedAt === null || (typeof g.completedAt === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(g.completedAt)))) fail("completedAt");
}

function assertRequired(req) {
  const fail = (d) => { throw new Error(`requiredChecks:${d}`); };
  if (!req || typeof req !== "object" || Array.isArray(req)) fail("type");
  const keys = Object.keys(req);
  if (keys.length !== 2 || !keys.includes("status") || !keys.includes("entries")) fail("keys");
  if (req.status !== "known" && req.status !== "unknown") fail("status");
  if (!Array.isArray(req.entries)) fail("entries");
  if (req.status === "unknown" && req.entries.length !== 0) fail("unknown-entries");
  for (const e of req.entries) {
    if (!e || typeof e !== "object" || Array.isArray(e)) fail("entry");
    const ek = Object.keys(e);
    if (ek.length !== 2 || !ek.includes("context") || !ek.includes("appId")) fail("entry-keys");
    if (typeof e.context !== "string" || e.context.length < 1 || unsafePath(e.context)) fail("context");
    if (!(e.appId === null || (Number.isInteger(e.appId) && e.appId >= 0))) fail("appId");
  }
}

function assertG12(g) {
  const fail = (d) => { throw new Error(`g12:${d}`); };
  if (!g || typeof g !== "object" || Array.isArray(g)) fail("type");
  const keys = Object.keys(g);
  for (const k of ["applies", "met", "reasons"]) if (!keys.includes(k)) fail(`missing:${k}`);
  for (const k of keys) if (!["applies", "met", "reasons"].includes(k)) fail(`unknown-key:${k}`);
  if (typeof g.applies !== "boolean") fail("applies");
  if (!(g.met === true || g.met === false || g.met === "unknown")) fail("met");
  if (!Array.isArray(g.reasons)) fail("reasons");
  for (const reason of g.reasons) if (!reasonCode(reason)) fail("reason");
}

function assertCost(c) {
  const fail = (d) => { throw new Error(`cost:${d}`); };
  if (!c || typeof c !== "object" || Array.isArray(c)) fail("type");
  if (c.status === "unknown") {
    if (Object.keys(c).length !== 1) fail("unknown-keys");
    return;
  }
  if (c.status !== "joined") fail("status");
  const keys = Object.keys(c);
  for (const k of ["status", "rows", "usdTotal"]) if (!keys.includes(k)) fail(`missing:${k}`);
  for (const k of keys) if (!["status", "rows", "usdTotal"].includes(k)) fail(`unknown-key:${k}`);
  if (!Array.isArray(c.rows) || c.rows.length < 1) fail("rows");
  if (!(c.usdTotal === null || (typeof c.usdTotal === "number" && Number.isFinite(c.usdTotal) && c.usdTotal >= 0))) fail("usdTotal");
  for (const row of c.rows) {
    if (!row || typeof row !== "object" || Array.isArray(row)) fail("row");
    const rk = Object.keys(row);
    for (const k of ["ts", "vendor", "model", "usd", "tokensIn", "tokensOut"]) if (!rk.includes(k)) fail(`row-missing:${k}`);
    for (const k of rk) if (!["ts", "vendor", "model", "usd", "tokensIn", "tokensOut"].includes(k)) fail(`row-key:${k}`);
    if (typeof row.ts !== "string" || row.ts.length < 1 || row.ts.length > 40) fail("ts");
    if (!VENDORS.has(row.vendor)) fail("vendor");
    if (!(row.model === null || (typeof row.model === "string" && row.model.length <= 80))) fail("model");
    for (const k of ["usd", "tokensIn", "tokensOut"]) {
      const v = row[k];
      if (!(v === null || (typeof v === "number" && Number.isFinite(v) && v >= 0))) fail(k);
    }
  }
}

function assertUnknownStatus(o, name) {
  if (!o || typeof o !== "object" || Array.isArray(o)) throw new Error(`${name}:type`);
  const keys = Object.keys(o);
  if (keys.length !== 1 || o.status !== "unknown") throw new Error(`${name}:status`);
}

function assertCommentEditors(o) {
  if (!o || typeof o !== "object" || Array.isArray(o)) throw new Error("commentEditors:type");
  const keys = Object.keys(o);
  if (keys.length !== 1 || (o.status !== "known" && o.status !== "unknown")) throw new Error("commentEditors:status");
}

function readJson(path, label) {
  let text;
  try {
    const st = lstatSync(path);
    if (!st.isFile() || st.isSymbolicLink()) throw new Error("not-a-regular-file");
    text = readFileSync(path, "utf8");
  } catch (e) {
    usage(`${label} unreadable`);
  }
  try {
    return JSON.parse(text);
  } catch {
    usage(`${label} is not json`);
  }
}

function parseArgs(argv) {
  if (argv.length === 0) usage("missing command");
  if (argv.includes("--help") || argv.includes("-h")) {
    help();
    process.exit(0);
  }
  const cmd = argv[0];
  if (cmd.startsWith("-")) usage(`unknown flag: ${cmd}`);
  if (cmd !== "collect" && cmd !== "project" && cmd !== "verify") usage(`unknown command: ${cmd}`);
  const map = {
    "--repo": "repo",
    "--pr": "pr",
    "--out": "out",
    "--ledger": "ledger",
    "--config": "config",
    "--bundle": "bundle",
    "--receipt": "receipt",
  };
  const args = { cmd, repo: null, pr: null, out: null, ledger: null, config: null, bundle: null, receipt: null };
  for (let i = 1; i < argv.length; i += 1) {
    const a = argv[i];
    if (!(a in map)) usage(`unknown flag: ${a}`);
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) usage(`${a} requires a value`);
    args[map[a]] = v;
    i += 1;
  }
  return args;
}

function ghEnv() {
  // gh colorizes JSON when FORCE_COLOR is set, even with stdout redirected.
  // Colored bytes are not evidence. Drop the force flags for this child only.
  const env = { ...process.env };
  delete env.FORCE_COLOR;
  delete env.CLICOLOR_FORCE;
  env.NO_COLOR = "1";
  env.CLICOLOR = "0";
  env.GH_FORCE_TTY = "0";
  return env;
}

function ghSpawn(args) {
  const res = spawnSync("gh", args, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    timeout: 120_000,
    env: ghEnv(),
  });
  return res;
}

function httpClass(stderr) {
  const m = String(stderr ?? "").match(/HTTP\s+(\d{3})/);
  return m ? `http-${m[1]}` : "unreadable";
}

function sha256Text(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/**
 * Paginated gh api. Returns {ok, pages, bodies, rawHash, error}.
 * `bodies` is the slurped page array. Raw stderr is not returned.
 */
function ghPages(endpoint) {
  const res = ghSpawn(["api", "--paginate", "--slurp", endpoint]);
  if (res.error || res.status !== 0) {
    return { ok: false, error: httpClass(res.stderr), pages: 0 };
  }
  let parsed;
  try {
    parsed = JSON.parse(res.stdout);
  } catch {
    return { ok: false, error: "unreadable", pages: 0 };
  }
  if (!Array.isArray(parsed) || parsed.length < 1) return { ok: false, error: "unreadable", pages: 0 };
  return { ok: true, pages: parsed.length, bodies: parsed, sha256: sha256Text(res.stdout) };
}

function flattenPages(pageResult, pick) {
  const items = [];
  for (const page of pageResult.bodies ?? []) {
    const chunk = pick(page);
    if (!Array.isArray(chunk)) return { ok: false, items: [] };
    items.push(...chunk);
  }
  return { ok: true, items };
}

function source(endpoint, pageResult, exhausted) {
  const ok = pageResult.ok === true;
  return {
    endpoint,
    pages: pageResult.pages,
    exhausted: exhausted === undefined ? ok : exhausted === true,
    sha256: ok ? pageResult.sha256 : sha256Text(pageResult.error ?? "unreadable"),
  };
}

function assertNoHostLeak(text) {
  if (/\/Users\/|\/home\/|\/private\/var\/|[A-Za-z]:\\/.test(text)) {
    throw new Error("redaction:absolute-path");
  }
}

function assertMarkersRedacted(body) {
  if (typeof body !== "string" || !body.includes("<!--")) return;
  MARKER_RE.lastIndex = 0;
  let m = MARKER_RE.exec(body);
  while (m) {
    if (m[0] !== redactMarkerBlock(m[0])) throw new Error("redaction:marker");
    m = MARKER_RE.exec(body);
  }
}

function assertBundleRedacted(bundle) {
  assertNoHostLeak(canonicalJson(bundle, false));
  const comments = bundle?.inputs?.comments;
  if (!Array.isArray(comments)) return;
  for (const c of comments) {
    if (c && typeof c.body === "string") assertMarkersRedacted(c.body);
  }
}

function loadLedger(path) {
  if (!path) return [];
  let text;
  try {
    const st = lstatSync(path);
    if (!st.isFile() || st.isSymbolicLink()) return null;
    text = readFileSync(path, "utf8");
  } catch {
    return null;
  }
  const events = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      return null;
    }
    if (!ev || ev.schema !== "gibson.cost.v1") return null;
    const allow = { schema: ev.schema, ts: ev.ts };
    if (typeof ev.runner === "string") allow.runner = ev.runner;
    if (typeof ev.provider === "string") allow.provider = ev.provider;
    if (ev.pr != null) allow.pr = ev.pr;
    if (typeof ev.join_key === "string") allow.join_key = ev.join_key;
    if (typeof ev.repo === "string") allow.repo = ev.repo;
    events.push(allow);
  }
  return events;
}

function unionChecks(protectionBody, rulesBody) {
  const entries = [];
  const seen = new Set();
  const push = (context, appId) => {
    if (typeof context !== "string" || !context) return;
    const id = appId == null ? null : normalizeAppId(appId);
    const key = `${context}\0${id}`;
    if (seen.has(key)) return;
    seen.add(key);
    entries.push({ context, appId: id });
  };
  if (protectionBody && Array.isArray(protectionBody.checks)) {
    for (const c of protectionBody.checks) push(c?.context, c?.app_id);
  } else if (protectionBody && Array.isArray(protectionBody.contexts)) {
    for (const name of protectionBody.contexts) push(name, null);
  }
  const rules = Array.isArray(rulesBody) ? rulesBody : [];
  for (const rule of rules) {
    if (rule?.type !== "required_status_checks") continue;
    const list = rule?.parameters?.required_status_checks;
    if (!Array.isArray(list)) continue;
    for (const c of list) push(c?.context, c?.app_id ?? c?.integration_id);
  }
  return entries;
}

function collectIssueNumber(repo, pr) {
  const [owner, name] = repo.split("/");
  const q = "query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){closingIssuesReferences(first:10){nodes{number}}}}}";
  const res = ghSpawn(["api", "graphql", "-f", `query=${q}`, "-F", `o=${owner}`, "-F", `r=${name}`, "-F", `n=${pr}`]);
  if (res.status !== 0) return { issue: null, source: source("graphql:closing-issues", { ok: false, pages: 0, error: httpClass(res.stderr) }) };
  let parsed;
  try {
    parsed = JSON.parse(res.stdout);
  } catch {
    return { issue: null, source: source("graphql:closing-issues", { ok: false, pages: 0, error: "unreadable" }) };
  }
  const nodes = parsed?.data?.repository?.pullRequest?.closingIssuesReferences?.nodes;
  let issue = null;
  if (Array.isArray(nodes) && nodes.length === 1 && Number.isInteger(nodes[0]?.number)) issue = nodes[0].number;
  return {
    issue,
    source: { endpoint: "graphql:closing-issues", pages: 1, exhausted: true, sha256: sha256Text(res.stdout) },
  };
}

function collectEditors(repo, pr, comments) {
  const [owner, name] = repo.split("/");
  const edits = new Map();
  let cursor = null;
  let pages = 0;
  const raws = [];
  for (let page = 0; page < 20; page += 1) {
    const q = "query($o:String!,$r:String!,$n:Int!,$c:String){repository(owner:$o,name:$r){pullRequest(number:$n){comments(first:100,after:$c){nodes{databaseId lastEditedAt editor{login}} pageInfo{hasNextPage endCursor}}}}}";
    const args = ["api", "graphql", "-f", `query=${q}`, "-F", `o=${owner}`, "-F", `r=${name}`, "-F", `n=${pr}`];
    if (cursor) args.push("-F", `c=${cursor}`);
    const res = ghSpawn(args);
    pages += 1;
    if (res.status !== 0) return { ok: false, pages, comments };
    raws.push(res.stdout);
    let parsed;
    try {
      parsed = JSON.parse(res.stdout);
    } catch {
      return { ok: false, pages, comments };
    }
    const conn = parsed?.data?.repository?.pullRequest?.comments;
    if (!conn || !Array.isArray(conn.nodes)) return { ok: false, pages, comments };
    for (const n of conn.nodes) if (n?.lastEditedAt) edits.set(Number(n.databaseId), { editor: n?.editor?.login ?? null });
    if (!conn.pageInfo?.hasNextPage) {
      const next = comments.map((c) => {
        const e = edits.get(Number(c?.id));
        if (!e) return c;
        return { ...c, edited: true, editor: e.editor ? { login: e.editor } : undefined };
      });
      return { ok: true, pages, comments: next, sha256: sha256Text(raws.join("\n")) };
    }
    cursor = conn.pageInfo.endCursor;
  }
  return { ok: false, pages, comments };
}

function writeBundle(path, bundle) {
  const text = `${canonicalJson(bundle, false)}\n`;
  assertNoHostLeak(text);
  const abs = resolve(path);
  if (existsSync(abs)) {
    process.stderr.write("delivery-receipt.mjs: --out already exists\n");
    process.exit(2);
  }
  const dir = dirname(abs);
  let st;
  try {
    st = lstatSync(dir);
  } catch {
    usage("--out directory missing");
  }
  if (!st.isDirectory() || st.isSymbolicLink()) usage("--out directory is not a real directory");
  const tmp = join(dir, `.delivery-receipt-${process.pid}.tmp`);
  writeFileSync(tmp, text, { encoding: "utf8", flag: "wx" });
  try {
    renameSync(tmp, abs);
  } catch (e) {
    try { unlinkSync(tmp); } catch { /* ignore */ }
    usage("cannot write --out");
  }
}

function collect(args) {
  if (!args.repo || !REPO.test(args.repo)) usage("--repo must be OWNER/REPO");
  if (!args.pr || !/^[1-9][0-9]*$/.test(args.pr)) usage("--pr must be a positive integer");
  if (!args.out) usage("--out is required");
  if (isAbsolute(args.out) && args.out.includes("\0")) usage("--out is invalid");
  if (existsSync(args.out)) usage("--out already exists");
  const ledger = loadLedger(args.ledger);
  if (ledger == null) usage("--ledger is unreadable");
  const pr = Number(args.pr);
  const base = `repos/${args.repo}`;
  let config;
  try {
    const cfgPath = args.config ?? DEFAULT_CONFIG;
    const st = lstatSync(cfgPath);
    if (!st.isFile() || st.isSymbolicLink()) usage("--config is not a regular file");
    config = validateConfig(JSON.parse(readFileSync(cfgPath, "utf8")));
  } catch (e) {
    usage(`config: ${String(e.message ?? e).slice(0, 120)}`);
  }
  const repoCall = ghPages(`${base}`);
  if (!repoCall.ok) usage(`cannot read repository (${repoCall.error})`);
  const repoBody = repoCall.bodies[0];
  const defaultBranch = safeRef(repoBody?.default_branch);
  const versionRes = ghSpawn(["api", "-i", base]);
  let ghApiVersion = "unknown";
  if (versionRes.status === 0) {
    const m = String(versionRes.stdout).match(/^x-github-api-version:\s*(\S+)/im);
    if (m && /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(m[1])) ghApiVersion = m[1];
  }
  const pullCall = ghPages(`${base}/pulls/${pr}`);
  if (!pullCall.ok) usage(`cannot read pull request (${pullCall.error})`);
  const pull = allowlistPull(pullCall.bodies[0]);
  if (!isSha(typeof pull.head.sha === "string" ? pull.head.sha.toLowerCase() : "")) usage("pull request head is missing");
  pull.head.sha = pull.head.sha.toLowerCase();
  if (typeof pull.base.sha === "string") pull.base.sha = pull.base.sha.toLowerCase();
  if (typeof pull.merge_commit_sha === "string") pull.merge_commit_sha = pull.merge_commit_sha.toLowerCase();
  const head = pull.head.sha;
  const commitsCall = ghPages(`${base}/pulls/${pr}/commits?per_page=100`);
  const reviewsCall = ghPages(`${base}/pulls/${pr}/reviews?per_page=100`);
  const commentsCall = ghPages(`${base}/issues/${pr}/comments?per_page=100`);
  const pullsForHeadCall = ghPages(`${base}/commits/${head}/pulls?per_page=100`);
  const timelineCall = ghPages(`${base}/issues/${pr}/timeline?per_page=100`);
  const filesCall = ghPages(`${base}/pulls/${pr}/files?per_page=100`);
  const checkRunsCall = ghPages(`${base}/commits/${head}/check-runs?per_page=100`);
  const statusesCall = ghPages(`${base}/commits/${head}/statuses?per_page=100`);
  const rawBranch = typeof pull.base.ref === "string" ? pull.base.ref : "";
  const endpoints = requiredSourceEndpoints({ repository: args.repo, pr, head, branch: rawBranch });
  if (!endpoints) usage("cannot name required sources");
  const ep = (template) => endpoints[REQUIRED_SOURCE_TEMPLATES.indexOf(template)];
  const protectionCall = ghPages(ep("repos/{repository}/branches/{branch}/protection/required_status_checks"));
  const rulesCall = ghPages(ep("repos/{repository}/rules/branches/{branch}"));
  const must = [commitsCall, reviewsCall, commentsCall, pullsForHeadCall, timelineCall, filesCall];
  for (const call of must) if (!call.ok) usage(`required source unreadable (${call.error})`);
  const commitsFlat = flattenPages(commitsCall, (p) => (Array.isArray(p) ? p : null));
  const reviewsFlat = flattenPages(reviewsCall, (p) => (Array.isArray(p) ? p : null));
  const commentsFlat = flattenPages(commentsCall, (p) => (Array.isArray(p) ? p : null));
  const headFlat = flattenPages(pullsForHeadCall, (p) => (Array.isArray(p) ? p : null));
  const timeFlat = flattenPages(timelineCall, (p) => (Array.isArray(p) ? p : null));
  const filesFlat = flattenPages(filesCall, (p) => (Array.isArray(p) ? p : null));
  if (![commitsFlat, reviewsFlat, commentsFlat, headFlat, timeFlat, filesFlat].every((x) => x.ok)) usage("paginated source was not an array");
  let comments = commentsFlat.items.map(allowlistComment);
  const editors = collectEditors(args.repo, pr, comments);
  const commentEditors = editors.ok ? { status: "known" } : { status: "unknown" };
  if (!editors.ok) comments = comments.map((c) => ({ ...c, body: "" }));
  else comments = editors.comments.map(allowlistComment);
  let files = filesFlat.items.map(allowlistFile);
  if (files.some((f) => f == null)) files = null;
  else files = files.filter(Boolean);
  const checkRuns = [];
  let checkRunsExhausted = checkRunsCall.ok === true;
  if (checkRunsCall.ok) {
    const flat = flattenPages(checkRunsCall, (p) => (Array.isArray(p?.check_runs) ? p.check_runs : null));
    const total = checkRunsCall.bodies.reduce((n, p) => Math.max(n, Number(p?.total_count ?? 0)), 0);
    // A short page is not a complete set. Drop the runs and record the source
    // as not exhausted so a missing page cannot look like a green check.
    if (!flat.ok || flat.items.length < total) checkRunsExhausted = false;
    else {
      for (const cr of flat.items) {
        checkRuns.push({
          name: cr?.name ?? null,
          conclusion: cr?.conclusion ?? null,
          appSlug: cr?.app?.slug ?? null,
          appId: typeof cr?.app?.id === "number" ? cr.app.id : null,
          headSha: typeof cr?.head_sha === "string" ? cr.head_sha.toLowerCase() : null,
          completedAt: typeof cr?.completed_at === "string" ? cr.completed_at.replace(/\.\d+Z$/, "Z") : null,
        });
      }
    }
  }
  let statusesExhausted = statusesCall.ok === true;
  if (statusesCall.ok) {
    const flat = flattenPages(statusesCall, (p) => (Array.isArray(p) ? p : null));
    if (!flat.ok) statusesExhausted = false;
    else {
      for (const s of flat.items) {
        checkRuns.push({
          name: s?.context ?? null,
          conclusion: s?.state ?? null,
          appSlug: null,
          appId: null,
          headSha: head,
          completedAt: typeof s?.updated_at === "string" ? s.updated_at.replace(/\.\d+Z$/, "Z") : null,
        });
      }
    }
  }
  let requiredChecks;
  if (!protectionCall.ok || !rulesCall.ok) requiredChecks = { status: "unknown", entries: [] };
  else {
    const protection = protectionCall.bodies.length === 1 ? protectionCall.bodies[0] : null;
    const rules = rulesCall.bodies.flatMap((p) => (Array.isArray(p) ? p : []));
    requiredChecks = { status: "known", entries: unionChecks(protection, rules) };
  }
  const issueInfo = collectIssueNumber(args.repo, pr);
  const costEvents = ledger;
  const sources = [
    source(ep("repos/{repository}"), repoCall),
    source(ep("repos/{repository}/pulls/{pr}"), pullCall),
    source(ep("repos/{repository}/pulls/{pr}/commits"), commitsCall),
    source(ep("repos/{repository}/pulls/{pr}/reviews"), reviewsCall),
    source(ep("repos/{repository}/issues/{pr}/comments"), commentsCall),
    source(ep(PULLS_FOR_HEAD_TEMPLATE), pullsForHeadCall),
    source(ep("repos/{repository}/issues/{pr}/timeline"), timelineCall),
    source(ep("repos/{repository}/pulls/{pr}/files"), filesCall),
    source(ep("repos/{repository}/commits/{head}/check-runs"), checkRunsCall.ok ? checkRunsCall : { ok: false, pages: 0, error: checkRunsCall.error }, checkRunsExhausted),
    source(ep("repos/{repository}/commits/{head}/statuses"), statusesCall.ok ? statusesCall : { ok: false, pages: 0, error: statusesCall.error }, statusesExhausted),
    source(ep("repos/{repository}/branches/{branch}/protection/required_status_checks"), protectionCall.ok ? protectionCall : { ok: false, pages: 0, error: protectionCall.error }),
    source(ep("repos/{repository}/rules/branches/{branch}"), rulesCall.ok ? rulesCall : { ok: false, pages: 0, error: rulesCall.error }),
    issueInfo.source,
    { endpoint: ep("graphql:comment-editors"), pages: editors.pages || 0, exhausted: editors.ok === true, sha256: editors.ok ? editors.sha256 : sha256Text("unreadable") },
  ];
  // A failed optional source is recorded exhausted:false. project will not
  // call that delivered. Required PR inputs already exited above.
  const bundle = {
    schema: BUNDLE_SCHEMA,
    repository: args.repo,
    pr,
    collectedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    ghApiVersion,
    sources,
    inputs: {
      pull,
      pullsForHead: headFlat.items.map(allowlistPullRef),
      pullsForHeadStatus: "known",
      commits: commitsFlat.items.map(allowlistCommit),
      reviews: reviewsFlat.items.map(allowlistReview),
      comments,
      timeline: timeFlat.items.map(allowlistTimeline),
      files,
      config,
      repository: { defaultBranch },
      requiredChecks,
      checkRuns,
      costEvents,
      commentEditors,
      issue: issueInfo.issue,
    },
  };
  writeBundle(args.out, bundle);
}

function main(argv) {
  const args = parseArgs(argv);
  if (args.cmd === "collect") {
    collect(args);
    return;
  }
  if (args.cmd === "project") {
    if (!args.bundle) usage("--bundle is required");
    if (args.repo || args.pr || args.receipt || args.out || args.ledger) usage("project takes only --bundle");
    const bundle = readJson(args.bundle, "--bundle");
    let receipt;
    try {
      receipt = projectBundle(bundle);
    } catch (e) {
      process.stdout.write(`contradictory: ${String(e.message ?? e).slice(0, 160)}\n`);
      process.exit(1);
    }
    process.stdout.write(`${canonicalJson(receipt, false)}\n`);
    return;
  }
  if (args.cmd === "verify") {
    if (!args.receipt) usage("--receipt is required");
    if (args.repo || args.pr || args.out || args.ledger) usage("verify takes --receipt and optional --bundle");
    const receipt = readJson(args.receipt, "--receipt");
    const bundle = args.bundle ? readJson(args.bundle, "--bundle") : null;
    const result = verifyReceipt(receipt, bundle);
    if (!result.ok) {
      for (const reason of result.reasons) process.stdout.write(`${reason}\n`);
      process.exit(1);
    }
    process.stdout.write(`ok ${receipt.disposition}\n`);
    return;
  }
  usage(`unknown command: ${args.cmd}`);
}

function invokedAsCli() {
  // macOS TMPDIR is /var, which realpaths to /private/var. import.meta.url uses
  // the real path; argv keeps the path the caller typed. A temp copy of this
  // file (the mutation suite) never runs unless both sides are realpathed.
  if (!process.argv[1]) return false;
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(resolve(process.argv[1]));
  } catch {
    return false;
  }
}

if (invokedAsCli()) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`delivery-receipt.mjs: ${String(e?.message ?? e).slice(0, 200)}\n`);
    process.exit(2);
  }
}
