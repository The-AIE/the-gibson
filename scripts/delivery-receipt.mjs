#!/usr/bin/env node
/**
 * delivery-receipt.mjs — report-only delivery receipt for one pull request (#160).
 *
 * WHAT IT DOES
 *   `collect` is the only networked step: it shells `gh api` (or an injected
 *   runner), allowlists fields, re-serializes markers, and writes a frozen
 *   evidence bundle. `project` turns that bundle into a byte-stable
 *   `gibson.delivery.v1` receipt. `verify` fails closed when the receipt
 *   disagrees with its digest, its bundle, or the rules below.
 *   Nothing here merges, deploys, or authorizes.
 *
 * WHY
 *   #160 asked for one read model over the facts that already decide a change.
 *   D-014 / D-015 removed owner attestation. G12 for Tier C is E3 at the exact
 *   head plus required checks (memory/DECISIONS.md). Anything this slice cannot
 *   source is `unknown`.
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
import { appendFileSync, existsSync, lstatSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
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
// Core is the check that remains if the full pattern assignment is removed.
const HOST_PATH_CORE_RE = /\/Users\/|\/home\/|\/private\/var\/|[A-Za-z]:\\/;
// macOS temps, volume and package prefixes, and tilde-home. A quoted JSON
// value counts: the character after the path may be /, ", \, or end.
const HOST_PATH_RE = /\/Users\/|\/home\/|\/private\/var\/|\/private\/tmp(?:\/|["\\]|$)|\/var\/folders(?:\/|["\\]|$)|\/tmp(?:\/|["\\]|$)|\/Volumes\/|\/opt\/homebrew(?:\/|["\\]|$)|\/usr\/local(?:\/|["\\]|$)|~\/|[A-Za-z]:\\/;

/** Injected gh runner for tests. Production uses spawnSync("gh") unless GIBSON_DELIVERY_GH_FIXTURE is set. */
let injectedGhRunner = null;

export function setGhRunner(fn) {
  injectedGhRunner = typeof fn === "function" ? fn : null;
}

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

function assertNoHostLeak(text) {
  let hit = HOST_PATH_CORE_RE.test(text);
  hit = HOST_PATH_RE.test(text); // MUTATION_ANCHOR_HOST_PATH
  if (hit) throw new Error("redaction:absolute-path");
}

const INSTANT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z$/;

/**
 * Milliseconds since the epoch for a UTC RFC3339 instant. Fractional seconds
 * are kept (Date millisecond resolution). Anything else is null. Callers that
 * cannot place a row fail closed to unknown rather than treating it as early.
 */
function instantMs(value) {
  if (typeof value !== "string" || !INSTANT_RE.test(value)) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

/** Second-resolution UTC stamp for receipt fields. Null when the instant is not RFC3339. */
function stamp(value) {
  if (instantMs(value) == null) return null;
  return value.replace(/\.\d+Z$/, "Z");
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
    merged_at: typeof p?.merged_at === "string" && instantMs(p.merged_at) != null ? p.merged_at : null,
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
  assertNoHostLeak(raw);
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
  // A commit status matches on context. When the requirement names an app id,
  // the status must carry that app id (explicit app.id, or the id in the
  // avatar, already folded into run.appId). No app id is unknown provenance,
  // whether or not a creator login is present, and it does not match. Only a
  // requirement that names no app id matches on context alone.
  if (run?.kind === "status") {
    if (req.appId == null) return true;
    if (run.appId != null && run.appId !== req.appId) return false; // MUTATION_ANCHOR_STATUS_APP
    if (run.appId == null) return false; // MUTATION_ANCHOR_STATUS_PROVENANCE
    return true;
  }
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
    if (hit.kind !== "status" && (typeof hit.appSlug !== "string" || hit.appSlug.length === 0)) {
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
  if (VENDORS.has(ev?.vendor) && ev.vendor !== "unknown") return ev.vendor;
  if (VENDORS.has(ev?.runner) && ev.runner !== "unknown") return ev.runner;
  if (VENDORS.has(ev?.provider) && ev.provider !== "unknown") return ev.provider;
  return "unknown";
}

function costNumber(v) {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : null;
}

/** Receipt row. usdTotal is never summed. A missing amount stays null. */
function costRow(ev) {
  const model = typeof ev?.model === "string" && ev.model.length > 0 && ev.model.length <= 80 ? ev.model : null;
  return {
    ts: ev.ts,
    vendor: costVendor(ev),
    model,
    usd: costNumber(ev?.usd),
    tokensIn: costNumber(ev?.tokensIn),
    tokensOut: costNumber(ev?.tokensOut),
  };
}

function legacyCostEvent(ev) {
  return !!ev && (
    Object.hasOwn(ev, "schema")
    || Object.hasOwn(ev, "join_key")
    || Object.hasOwn(ev, "runner")
    || Object.hasOwn(ev, "provider")
  );
}

function sortCostRows(rows) {
  rows.sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : a.vendor < b.vendor ? -1 : a.vendor > b.vendor ? 1 : 0));
  return { status: "joined", rows, usdTotal: null };
}

/** Allowlisted ledger rows: pr was resolved at collect. No join_key remains. */
function joinSealedCost(events, prNumber) {
  const rows = [];
  for (const ev of events) {
    if (!ev || typeof ev.ts !== "string") return { status: "unknown" };
    if (ev.repo != null && safeRepo(ev.repo) !== ev.repo) return { status: "unknown" };
    if (ev.pr != null && (!Number.isInteger(ev.pr) || ev.pr < 0)) return { status: "unknown" };
    if (ev.pr !== prNumber) continue;
    rows.push(costRow(ev));
  }
  if (rows.length === 0) return { status: "unknown" };
  return sortCostRows(rows);
}

/** gibson.cost.v1 join: a conflicting join_key, or no unique PR match, is unknown. Never summed. */
export function joinCost(events, prNumber) {
  if (!Array.isArray(events) || events.length === 0) return { status: "unknown" };
  if (!events.some(legacyCostEvent)) return joinSealedCost(events, prNumber);
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
    rows.push(costRow(ev));
  }
  if (rows.length === 0) return { status: "unknown" };
  return sortCostRows(rows);
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

/** Vendor evaluate() stored on one evidence identity. Not a login-table lookup. */
function attestedVendor(result, login) {
  const rows = Array.isArray(result?.evidenceRows) ? result.evidenceRows : [];
  const hits = rows.filter((r) => r && r.login === login && r.result === "pass");
  if (hits.length !== 1) return "unknown";
  return asVendor(hits[0].vendor);
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
  "repos/{repository}/commits/{head}/status",
  "repos/{repository}/branches/{branch}/protection/required_status_checks",
  "repos/{repository}/rules/branches/{branch}",
  "graphql:closing-issues",
  "graphql:comment-editors",
];

const PULLS_FOR_HEAD_TEMPLATE = "repos/{repository}/commits/{head}/pulls";
const COMBINED_STATUS_TEMPLATE = "repos/{repository}/commits/{head}/status";

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
    const login = shaped.passLogins[0];
    shaped.reviewerLogin = login;
    const listed = vendorOfLogin(config, login);
    // A listed login keeps the identity-table vendor. owner-attested-review is
    // not a row: its vendor is the one evaluate() already accepted on that
    // evidence identity. Unknown stays unknown. The login is not a vendor.
    if (listed !== "unknown") shaped.review.reviewerVendor = listed;
    else shaped.review.reviewerVendor = attestedVendor(ev.result, login); // MUTATION_ANCHOR_ATTESTED_VENDOR
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
  const state = typeof pull?.state === "string" ? pull.state : "";
  const mergedAtRaw = typeof pull?.merged_at === "string" ? pull.merged_at : null;
  const mergedAtMs = instantMs(mergedAtRaw);
  const merged = state === "closed" && pull?.merged === true && mergeSha != null;
  let requiredChecks = normalizeRequired(inputs.requiredChecks);
  // An unreadable combined-status source is unknown. Check runs must not
  // satisfy the required set while that source is missing. Old bundles that
  // never recorded the field fail closed the same way.
  if (inputs.combinedStatus !== "known") requiredChecks = { status: "unknown", entries: [] }; // MUTATION_ANCHOR_STATUS_UNKNOWN
  // Open PRs keep the combined status. A merged PR is judged at merged_at.
  // No merged_at means the pre-merge row cannot be picked, so the set is unknown.
  let gates = normalizeGates(inputs.checkRuns, head);
  let postMerge = [];
  const mode = gateMode(merged);
  if (mode === "as-of" && mergedAtMs != null) {
    const picked = asOfGates(inputs.checkRuns, inputs.statusHistory, head, mergedAtRaw);
    if (picked.unknown) {
      requiredChecks = { status: "unknown", entries: [] };
      gates = [];
      postMerge = [];
    } else {
      gates = picked.gates;
      postMerge = picked.postMerge;
    }
  }
  if (mode === "as-of" && mergedAtMs == null) requiredChecks = { status: "unknown", entries: [] }; // MUTATION_ANCHOR_MERGED_AT
  const cost = joinCost(inputs.costEvents, pr);
  const baseRef = safeRef(pull?.base?.ref);
  const defaultBranch = safeRef(inputs.repository?.defaultBranch);
  const paginationExhausted = sourceGate.paginationExhausted;
  const commentEditors = inputs.commentEditors?.status === "known" ? { status: "known" } : { status: "unknown" };
  const contradictory = pull?.merged === true && pull?.state === "open";
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
    postMerge,
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
    const completedAt = typeof r?.completedAt === "string" ? r.completedAt : null;
    const kind = r?.kind === "status" ? "status" : "check";
    let creatorLogin = null;
    if (r?.creatorLogin != null) {
      if (typeof r.creatorLogin !== "string" || safeLogin(r.creatorLogin) !== r.creatorLogin) continue;
      creatorLogin = r.creatorLogin;
    }
    gates.push({
      name,
      conclusion: mapConclusion(r?.conclusion),
      appSlug,
      appId,
      headSha: sha,
      completedAt,
      kind,
      creatorLogin,
    });
  }
  gates.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : (a.appId ?? -1) - (b.appId ?? -1)));
  return gates;
}

/** Open PRs use the latest combined status. Merged PRs are judged at merged_at. */
function gateMode(merged) {
  if (!merged) return "latest"; // MUTATION_ANCHOR_OPEN_LATEST
  return "as-of";
}

function rowClock(row) {
  if (!row) return null;
  return row.kind === "status" ? row.createdAt : row.completedAt;
}

/**
 * Split on the full instant. Equal to merged_at is pre-merge. A present clock
 * that is not RFC3339 is unknown (the caller fails closed). A missing clock
 * is skipped. The truncated compare is what remains if the millisecond
 * assignment is removed: that is the fractional-second bug.
 */
function splitAtMerge(rows, mergedAt) {
  const mergedMs = instantMs(mergedAt);
  const mergedTrunc = stamp(mergedAt);
  if (mergedMs == null || mergedTrunc == null) return { before: [], after: [], unknown: true };
  const before = [];
  const after = [];
  for (const row of rows) {
    const raw = rowClock(row);
    if (raw == null) continue;
    const atMs = instantMs(raw);
    const atTrunc = stamp(raw);
    if (atMs == null || atTrunc == null) return { before: [], after: [], unknown: true }; // MUTATION_ANCHOR_STAMP_CLOSED
    let afterMerge = atTrunc > mergedTrunc;
    afterMerge = atMs > mergedMs; // MUTATION_ANCHOR_FRACTIONAL_STAMP
    if (afterMerge) { after.push(row); continue; } // MUTATION_ANCHOR_AS_OF_MERGE
    before.push(row);
  }
  return { before, after, unknown: false };
}

/** Every row that shares the newest instant. A tie is not one row. */
function selectLatest(rows) {
  const byName = new Map();
  for (const row of rows) {
    const list = byName.get(row.name) ?? [];
    list.push(row);
    byName.set(row.name, list);
  }
  const selected = [];
  for (const list of byName.values()) {
    let max = null;
    for (const row of list) {
      const at = instantMs(rowClock(row));
      if (at == null) continue;
      if (max == null || at > max) max = at;
    }
    if (max == null) continue;
    for (const row of list) if (instantMs(rowClock(row)) === max) selected.push(row);
  }
  return selected;
}

function normalizeHistory(rows, head) {
  if (!Array.isArray(rows)) return [];
  const out = [];
  for (const r of rows) {
    const name = typeof r?.name === "string" ? r.name : (typeof r?.context === "string" ? r.context : "");
    if (!name || name.length > 200 || unsafePath(name)) continue;
    const sha = typeof r?.headSha === "string" ? r.headSha.toLowerCase() : "";
    if (sha !== head) continue;
    const appId = r?.appId == null ? null : normalizeAppId(r.appId);
    let creatorLogin = null;
    if (r?.creatorLogin != null) {
      if (typeof r.creatorLogin !== "string" || safeLogin(r.creatorLogin) !== r.creatorLogin) continue;
      creatorLogin = r.creatorLogin;
    }
    out.push({
      name,
      conclusion: mapConclusion(r?.conclusion ?? r?.state),
      appSlug: null,
      appId,
      headSha: sha,
      createdAt: typeof r?.createdAt === "string" ? r.createdAt : null,
      kind: "status",
      creatorLogin,
    });
  }
  return out;
}

function asGate(row) {
  const completedAt = stamp(row.kind === "status" ? row.createdAt : row.completedAt);
  return {
    name: row.name,
    conclusion: row.conclusion,
    appSlug: row.appSlug ?? null,
    appId: row.appId ?? null,
    headSha: row.headSha,
    completedAt,
    kind: row.kind === "status" ? "status" : "check",
    creatorLogin: row.creatorLogin ?? null,
  };
}

function toNote(row) {
  const at = stamp(row.kind === "status" ? row.createdAt : row.completedAt);
  if (typeof at !== "string") return null;
  return {
    name: row.name,
    kind: row.kind === "status" ? "status" : "check",
    conclusion: row.conclusion,
    at,
    appId: row.appId ?? null,
  };
}

/**
 * Check runs by completed_at, statuses by created_at. The combined status is
 * not a merged-PR source. Rows after merged_at are a note, not a verdict.
 */
function asOfGates(checkRuns, statusHistory, head, mergedAt) {
  const checks = normalizeGates(checkRuns, head).filter((g) => g.kind !== "status");
  const statuses = normalizeHistory(statusHistory, head);
  const checkSplit = splitAtMerge(checks, mergedAt);
  const statusSplit = splitAtMerge(statuses, mergedAt);
  if (checkSplit.unknown || statusSplit.unknown) return { gates: [], postMerge: [], unknown: true };
  const gates = [...selectLatest(checkSplit.before), ...selectLatest(statusSplit.before)].map(asGate);
  gates.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : (a.appId ?? -1) - (b.appId ?? -1)));
  const postMerge = [...checkSplit.after, ...statusSplit.after].map(toNote).filter(Boolean);
  postMerge.sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : a.name < b.name ? -1 : a.name > b.name ? 1 : (a.appId ?? -1) - (b.appId ?? -1)));
  return { gates, postMerge, unknown: false };
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
  // postMerge is optional so a receipt projected before the note still verifies.
  // A new projection always sets it.
  const optional = ["postMerge"];
  for (const k of need) if (!keys.has(k)) fail(`missing:${k}`);
  for (const k of keys) if (!need.includes(k) && !optional.includes(k)) fail(`unknown-key:${k}`);
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
  if (keys.has("postMerge")) assertPostMerge(r.postMerge);
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
  for (const k of keys) if (!need.includes(k) && k !== "kind" && k !== "creatorLogin") fail(`unknown-key:${k}`);
  if (typeof g.name !== "string" || g.name.length < 1 || g.name.length > 200 || unsafePath(g.name)) fail("name");
  if (!CONCLUSIONS.has(g.conclusion)) fail("conclusion");
  if (!(g.appSlug === null || (typeof g.appSlug === "string" && /^[A-Za-z0-9_.-]{1,80}$/.test(g.appSlug)))) fail("appSlug");
  if (!(g.appId === null || (Number.isInteger(g.appId) && g.appId >= 0))) fail("appId");
  if (!isSha(g.headSha)) fail("headSha");
  if (!(g.completedAt === null || (typeof g.completedAt === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(g.completedAt)))) fail("completedAt");
  // kind and creatorLogin are optional so a receipt written before commit
  // statuses were a match source still verifies. A new projection always sets both.
  if ("kind" in g && g.kind !== "check" && g.kind !== "status") fail("kind");
  if ("creatorLogin" in g && !(g.creatorLogin === null || (typeof g.creatorLogin === "string" && safeLogin(g.creatorLogin) === g.creatorLogin))) fail("creatorLogin");
}

function assertPostMerge(notes) {
  const fail = (d) => { throw new Error(`postMerge:${d}`); };
  if (!Array.isArray(notes)) fail("type");
  for (const n of notes) {
    if (!n || typeof n !== "object" || Array.isArray(n)) fail("note");
    const nk = Object.keys(n);
    for (const k of ["name", "kind", "conclusion", "at", "appId"]) if (!nk.includes(k)) fail(`missing:${k}`);
    for (const k of nk) if (!["name", "kind", "conclusion", "at", "appId"].includes(k)) fail(`unknown-key:${k}`);
    if (typeof n.name !== "string" || n.name.length < 1 || n.name.length > 200 || unsafePath(n.name)) fail("name");
    if (n.kind !== "check" && n.kind !== "status") fail("kind");
    if (!CONCLUSIONS.has(n.conclusion)) fail("conclusion");
    if (stamp(n.at) !== n.at) fail("at");
    if (!(n.appId === null || (Number.isInteger(n.appId) && n.appId >= 0))) fail("appId");
  }
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

export function ghCallKey(args) {
  if (!Array.isArray(args) || args[0] !== "api") return `cmd:${(args ?? []).join(" ")}`.slice(0, 200);
  if (args.includes("graphql")) {
    const joined = args.join("\n");
    if (joined.includes("closingIssuesReferences")) return "graphql:closing-issues";
    if (joined.includes("lastEditedAt") || joined.includes("editor{login}")) return "graphql:comment-editors";
    return "graphql:unknown";
  }
  if (args.includes("-i")) return "headers";
  return String(args[args.length - 1] ?? "");
}

function recordGhCall(args) {
  const log = process.env.GIBSON_DELIVERY_GH_LOG;
  if (typeof log !== "string" || log.length === 0) return;
  appendFileSync(log, `${JSON.stringify(args)}\n`, { encoding: "utf8" });
}

function fixtureGhSpawn(dir, args) {
  let map;
  try {
    const st = lstatSync(dir);
    if (!st.isDirectory() || st.isSymbolicLink()) {
      return { status: 1, stdout: "", stderr: "HTTP 500 fixture-dir", error: null };
    }
    map = JSON.parse(readFileSync(join(dir, "map.json"), "utf8"));
  } catch {
    return { status: 1, stdout: "", stderr: "HTTP 500 fixture-unreadable", error: null };
  }
  const key = ghCallKey(args);
  const row = map && typeof map === "object" && !Array.isArray(map) ? map[key] : null;
  if (!row || typeof row !== "object" || Array.isArray(row)) {
    return { status: 1, stdout: "", stderr: `HTTP 404 missing-fixture ${key}`, error: null };
  }
  if (row.ok === false) {
    return {
      status: Number.isInteger(row.status) ? row.status : 1,
      stdout: "",
      stderr: String(row.stderr ?? "HTTP 404"),
      error: null,
    };
  }
  if (typeof row.stdout === "string") {
    return { status: 0, stdout: row.stdout, stderr: "", error: null };
  }
  try {
    return { status: 0, stdout: `${JSON.stringify(row.body)}\n`, stderr: "", error: null };
  } catch {
    return { status: 1, stdout: "", stderr: "HTTP 500 fixture-body", error: null };
  }
}

function ghSpawn(args) {
  recordGhCall(args);
  if (injectedGhRunner) return injectedGhRunner(args);
  const fixtureDir = process.env.GIBSON_DELIVERY_GH_FIXTURE;
  if (typeof fixtureDir === "string" && fixtureDir.length > 0) return fixtureGhSpawn(fixtureDir, args);
  return spawnSync("gh", args, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    timeout: 120_000,
    env: ghEnv(),
  });
}

function httpClass(stderr) {
  const m = String(stderr ?? "").match(/HTTP\s+(\d{3})/);
  return m ? `http-${m[1]}` : "unreadable";
}

function sha256Text(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/**
 * Paginated gh api. Returns {ok, pages, bodies, sha256, error}.
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

function ledgerStrings(value, out) {
  if (typeof value === "string") {
    out.push(value);
    return;
  }
  if (!value || typeof value !== "object") return;
  const list = Array.isArray(value) ? value : Object.values(value);
  for (const item of list) ledgerStrings(item, out);
}

function assertLedgerClean(ev) {
  const parts = [];
  ledgerStrings(ev, parts);
  assertNoHostLeak(parts.join("\n"));
}

/** Wide copy. The seal assignment replaces it; deleting that assignment keeps these fields. */
function wideLedgerCopy(ev) {
  const copy = {};
  if (ev.schema != null) copy.schema = ev.schema;
  if (ev.ts != null) copy.ts = ev.ts;
  for (const key of ["runner", "provider", "join_key", "repo", "note", "model", "vendor"]) {
    if (typeof ev[key] === "string") copy[key] = ev[key];
  }
  if (ev.pr != null) copy.pr = ev.pr;
  for (const key of ["usd", "tokensIn", "tokensOut"]) {
    if (typeof ev[key] === "number") copy[key] = ev[key];
  }
  return copy;
}

/**
 * Fields copied into the bundle: ts, vendor, model, usd, tokensIn, tokensOut,
 * pr, and repo. repo must be an owner/name slug. join_key is not copied.
 */
function sealLedgerEvent(ev) {
  if (!ev || ev.schema !== "gibson.cost.v1") return null;
  if (typeof ev.ts !== "string" || ev.ts.length < 1 || ev.ts.length > 40) return null;
  if (ev.pr != null && (!Number.isInteger(ev.pr) || ev.pr < 0)) return null;
  if (ev.repo != null && safeRepo(ev.repo) !== ev.repo) return null;
  if (ev.model != null && (typeof ev.model !== "string" || ev.model.length < 1 || ev.model.length > 80)) return null;
  for (const key of ["usd", "tokensIn", "tokensOut"]) {
    if (ev[key] == null) continue;
    if (costNumber(ev[key]) == null) return null;
  }
  const out = { ts: ev.ts, vendor: costVendor(ev) };
  if (typeof ev.model === "string") out.model = ev.model;
  for (const key of ["usd", "tokensIn", "tokensOut"]) {
    if (ev[key] != null) out[key] = ev[key];
  }
  if (ev.pr != null) out.pr = ev.pr;
  if (typeof ev.repo === "string") out.repo = ev.repo;
  return out;
}

/** One join_key must name one PR. The key is applied, then dropped. */
function resolveLedgerPrs(events) {
  const joinToPr = new Map();
  for (const ev of events) {
    if (typeof ev.join_key !== "string" || !ev.join_key || !Number.isInteger(ev.pr)) continue;
    if (joinToPr.has(ev.join_key) && joinToPr.get(ev.join_key) !== ev.pr) return null;
    joinToPr.set(ev.join_key, ev.pr);
  }
  return events.map((ev) => {
    if (Number.isInteger(ev.pr)) return ev;
    if (typeof ev.join_key === "string" && ev.join_key && joinToPr.has(ev.join_key)) {
      return { ...ev, pr: joinToPr.get(ev.join_key) };
    }
    return ev;
  });
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
  const raw = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      return null;
    }
    if (!ev || ev.schema !== "gibson.cost.v1") return null;
    raw.push(ev);
  }
  const resolved = resolveLedgerPrs(raw);
  if (resolved == null) return null;
  const events = [];
  for (const ev of resolved) {
    assertLedgerClean(ev);
    let stored = wideLedgerCopy(ev);
    stored = sealLedgerEvent(ev); // MUTATION_ANCHOR_LEDGER_ALLOW
    if (stored == null) return null;
    assertLedgerClean(stored);
    events.push(stored);
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

/** App id GitHub puts in a combined-status avatar when the status object has no app field. */
function appIdFromStatusAvatar(url) {
  if (typeof url !== "string") return null;
  const m = url.match(/^https:\/\/avatars\.githubusercontent\.com\/in\/([0-9]+)(?:[/?#].*)?$/);
  if (!m) return null;
  return normalizeAppId(Number(m[1]));
}

/**
 * Combined status (`GET .../commits/{sha}/status`) is one latest row per context.
 * `gh api --paginate --slurp` returns one object per page. A short read, a
 * disagreeing app id, or an unreadable creator is not a match set.
 */
function readCombinedStatuses(call, head) {
  if (!call?.ok) return { ok: false, items: [] };
  const items = [];
  let total = null;
  for (const page of call.bodies ?? []) {
    if (!page || typeof page !== "object" || Array.isArray(page) || !Array.isArray(page.statuses)) return { ok: false, items: [] };
    if (!Number.isInteger(page.total_count) || page.total_count < 0) return { ok: false, items: [] };
    if (total == null) total = page.total_count;
    else if (total !== page.total_count) return { ok: false, items: [] };
    for (const s of page.statuses) {
      const explicit = normalizeAppId(s?.app?.id ?? s?.app_id);
      const avatar = appIdFromStatusAvatar(s?.avatar_url);
      if (explicit != null && avatar != null && explicit !== avatar) return { ok: false, items: [] };
      const rawCreator = s?.creator?.login;
      let creatorLogin = null;
      if (rawCreator != null) {
        if (typeof rawCreator !== "string" || safeLogin(rawCreator) !== rawCreator) return { ok: false, items: [] };
        creatorLogin = rawCreator;
      }
      const completed = typeof s?.updated_at === "string" ? s.updated_at : (typeof s?.created_at === "string" ? s.created_at : null);
      items.push({
        name: typeof s?.context === "string" ? s.context : null,
        conclusion: s?.state ?? null,
        appSlug: null,
        appId: explicit != null ? explicit : avatar,
        headSha: head,
        completedAt: typeof completed === "string" ? completed : null,
        kind: "status",
        creatorLogin,
      });
    }
  }
  if (total == null || items.length !== total) return { ok: false, items: [] };
  return { ok: true, items };
}

/** Every `/statuses` stamp. created_at is the clock. A bad app id fails the page. */
function readStatusHistory(call, head) {
  if (!call?.ok) return { ok: false, items: [] };
  const flat = flattenPages(call, (p) => (Array.isArray(p) ? p : null));
  if (!flat.ok) return { ok: false, items: [] };
  const items = [];
  for (const s of flat.items) {
    const explicit = normalizeAppId(s?.app?.id ?? s?.app_id);
    const avatar = appIdFromStatusAvatar(s?.avatar_url);
    if (explicit != null && avatar != null && explicit !== avatar) return { ok: false, items: [] };
    const rawCreator = s?.creator?.login;
    let creatorLogin = null;
    if (rawCreator != null) {
      if (typeof rawCreator !== "string" || safeLogin(rawCreator) !== rawCreator) return { ok: false, items: [] };
      creatorLogin = rawCreator;
    }
    items.push({
      name: typeof s?.context === "string" ? s.context : null,
      conclusion: s?.state ?? null,
      appId: explicit != null ? explicit : avatar,
      headSha: head,
      createdAt: typeof s?.created_at === "string" ? s.created_at : null,
      kind: "status",
      creatorLogin,
    });
  }
  return { ok: true, items };
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
  if (existsSync(resolve(args.out))) usage("--out already exists"); // MUTATION_ANCHOR_OUT_BEFORE_GH
  const ledger = loadLedger(args.ledger);
  if (ledger == null) usage("--ledger is unreadable"); // MUTATION_ANCHOR_LEDGER_BEFORE_GH
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
  const combinedCall = ghPages(`${base}/commits/${head}/status?per_page=100`);
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
          completedAt: typeof cr?.completed_at === "string" ? cr.completed_at : null,
        });
      }
    }
  }
  // `/statuses` is every stamp. Open PRs match the combined status. A merged
  // PR matches the latest row at or before merged_at. History stays out of
  // checkRuns: folding it in made one context look like several runs.
  let statusesExhausted = statusesCall.ok === true;
  let statusHistory = [];
  if (statusesCall.ok) {
    const history = readStatusHistory(statusesCall, head);
    if (!history.ok) statusesExhausted = false;
    else statusHistory = history.items;
  }
  const combined = readCombinedStatuses(combinedCall, head);
  const combinedKnown = combined.ok === true;
  if (combinedKnown) {
    for (const s of combined.items) checkRuns.push(s);
  }
  let requiredChecks;
  if (!protectionCall.ok || !rulesCall.ok || !combinedKnown) requiredChecks = { status: "unknown", entries: [] };
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
    source(ep(COMBINED_STATUS_TEMPLATE), combinedCall.ok ? combinedCall : { ok: false, pages: 0, error: combinedCall.error }, combinedKnown),
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
      combinedStatus: combinedKnown ? "known" : "unknown",
      checkRuns,
      statusHistory,
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
