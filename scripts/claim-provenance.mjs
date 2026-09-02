#!/usr/bin/env node
/**
 * claim-provenance.mjs — report-only reservation classifier (#273).
 *
 * WHAT IT DOES
 *   Reads one pull request's live body, head, and introduced commits, then
 *   reports at most one cryptographically bound v1 reservation separately
 *   from ordinary implementation provenance. The stable JSON schema is
 *   gibson.claim-provenance/v1. This tool reports evidence only: it never
 *   returns READY, APPROVE, merge, or release authority, and it never infers
 *   vendor, platform, or reviewer independence from Git metadata.
 *
 * WHY
 *   Coordinators otherwise treat the empty reservation commit as owner
 *   implementation work and close a sound bot-authored lane just to remove it.
 *
 * RISKS
 *   - Live GitHub reads can lag. Before/after head and claim-body projection
 *     must match or the reservation is not verified.
 *   - A truncated, forked, unreadable, or drifting view fails closed as
 *     ordinary introduced provenance.
 *   - Production CLI always resolves live evidence itself. Caller-supplied
 *     JSON is never authoritative.
 *
 * USAGE
 *   node scripts/claim-provenance.mjs --repo owner/name --pr N \
 *     --expected-head <40-hex> --claim-id ID --issue N --branch NAME \
 *     [--repo-path PATH] [--base main|master] \
 *     [--require-verified-reservation <40-hex>]
 *   node scripts/claim-provenance.mjs --help
 *
 * EXIT
 *   0  wrote a report (verified or not, unless --require-verified-reservation)
 *   1  unreadable evidence, or required reservation was not verified
 *   2  usage
 */
import { execFileSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseFlags } from "./lib/args.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

export const SCHEMA = "gibson.claim-provenance/v1";
export const AUTHORITY = "report-only";
export const CLAIM_SCHEMA_V2 = "gibson.claim/v2";
export const RESERVATION_TRAILER_VERSION = "v1";

export const REASON = Object.freeze({
  MISSING_MARKER: "missing_marker",
  DUPLICATE_MARKER: "duplicate_marker",
  REORDERED_MARKER: "reordered_marker",
  CONFLICTING_MARKER: "conflicting_marker",
  MALFORMED_MARKER: "malformed_marker",
  MISSING_TRAILER: "missing_trailer",
  DUPLICATE_TRAILER: "duplicate_trailer",
  REORDERED_TRAILER: "reordered_trailer",
  CONFLICTING_TRAILER: "conflicting_trailer",
  MALFORMED_TRAILER: "malformed_trailer",
  NONEMPTY_TREE: "nonempty_tree",
  WRONG_PARENT: "wrong_parent",
  MULTIPLE_PARENTS: "multiple_parents",
  REBASED_RESERVATION: "rebased_reservation",
  COPIED_RESERVATION: "copied_reservation",
  NOT_FIRST_INTRODUCED: "not_first_introduced",
  FORGED_MESSAGE: "forged_message",
  DCO_MISMATCH: "dco_mismatch",
  AUTHOR_COMMITTER_AMBIGUITY: "author_committer_ambiguity",
  LOGIN_AMBIGUITY: "login_ambiguity",
  FORK_PR: "fork_pr",
  TRUNCATED_API: "truncated_api",
  UNSTABLE_HEAD: "unstable_head",
  UNSTABLE_BODY: "unstable_body",
  UNREADABLE_OBJECT: "unreadable_object",
  HEAD_MISMATCH: "head_mismatch",
  UNSTABLE_IDENTITY: "unstable_identity",
  ORDINARY_INTRODUCED: "ordinary_introduced",
  MISSING_V2_SCHEMA: "missing_v2_schema",
  RESERVATION_NOT_IN_HISTORY: "reservation_not_in_history",
  BINDING_MISMATCH: "binding_mismatch",
});

const HEX40 = /^[0-9a-f]{40}$/;
const CLAIM_ID_RE = /^issue-(?:[A-Za-z][A-Za-z0-9]*-)?([0-9]+)-([A-Za-z0-9][A-Za-z0-9-]*)$/;
const ISSUE_LINE_RE = /^[0-9]+$/;
const LOGIN_RE = /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\[bot\])?$/;
const DCO_RE = /^Signed-off-by: (.+) <([^<>]+)>$/;
const TRAILER_LINE_RE = /^([A-Za-z0-9][A-Za-z0-9-]*): (.+)$/;
const RESERVE_SUBJECT_RE =
  /^chore: reserve issue #([0-9]+) for (issue-(?:[A-Za-z][A-Za-z0-9]*-)?[0-9]+-[A-Za-z0-9][A-Za-z0-9-]*)$/;

export const MARKER_SPECS = Object.freeze([
  {
    key: "schema",
    prefix: "- Claim schema: ",
    pattern: /^gibson\.claim\/v2$/,
  },
  {
    key: "claimId",
    prefix: "- Active-work claim: ",
    pattern: CLAIM_ID_RE,
  },
  {
    key: "issue",
    prefix: "- Issue: #",
    pattern: ISSUE_LINE_RE,
  },
  {
    key: "scope",
    prefix: "- Claim scope: ",
    pattern: /\S/,
  },
  {
    key: "originalBranchPoint",
    prefix: "- Original branch point: ",
    pattern: HEX40,
  },
  {
    key: "reservationCommit",
    prefix: "- Reservation commit: ",
    pattern: HEX40,
  },
]);

export const TRAILER_SPECS = Object.freeze([
  {
    key: "reservation",
    token: "Gibson-Reservation",
    pattern: /^v1$/,
  },
  {
    key: "claimId",
    token: "Gibson-Claim-ID",
    pattern: CLAIM_ID_RE,
  },
  {
    key: "issue",
    token: "Gibson-Issue",
    pattern: /^#[0-9]+$/,
  },
  {
    key: "branch",
    token: "Gibson-Branch",
    pattern: /\S/,
  },
  {
    key: "dco",
    token: "Signed-off-by",
    pattern: /.+ <[^<>]+>$/,
  },
]);

const MARKER_KEYS = MARKER_SPECS.map((s) => s.key);
const TRAILER_KEYS = TRAILER_SPECS.map((s) => s.key);

function addReason(reasons, code) {
  if (!code) return;
  if (!reasons.includes(code)) reasons.push(code);
}

function linesOf(text) {
  return String(text ?? "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .split("\n");
}

function specForPrefix(line) {
  for (const spec of MARKER_SPECS) {
    if (line.startsWith(spec.prefix)) return spec;
  }
  return null;
}

function issueFromClaimId(claimId) {
  const m = String(claimId ?? "").match(CLAIM_ID_RE);
  return m ? m[1] : null;
}

function identityFields(raw) {
  const name = raw?.name == null ? "" : String(raw.name);
  const email = raw?.email == null ? "" : String(raw.email);
  const loginRaw = raw?.login;
  const login =
    loginRaw == null || loginRaw === "" ? null : String(loginRaw);
  return { name, email, login };
}

function stableIdentity(raw) {
  const id = identityFields(raw);
  return { name: id.name, email: id.email, login: id.login };
}

function parseDco(value) {
  const m = `Signed-off-by: ${value}`.match(DCO_RE);
  if (!m) return null;
  return { name: m[1], email: m[2] };
}

export function projectClaimBody(body) {
  const out = [];
  for (const line of linesOf(body)) {
    if (specForPrefix(line)) out.push(line);
  }
  return out.join("\n");
}

export function parseV2BodyMarkers(body) {
  const reasons = [];
  const values = {};
  const seen = [];
  const counts = Object.fromEntries(MARKER_KEYS.map((k) => [k, 0]));
  const malformedKeys = new Set();

  for (const line of linesOf(body)) {
    const spec = specForPrefix(line);
    if (!spec) continue;
    const value = line.slice(spec.prefix.length);
    counts[spec.key] += 1;
    seen.push(spec.key);
    if (!spec.pattern.test(value)) {
      malformedKeys.add(spec.key);
      addReason(reasons, REASON.MALFORMED_MARKER);
      continue;
    }
    if (counts[spec.key] === 1) values[spec.key] = value;
  }

  for (const spec of MARKER_SPECS) {
    if (counts[spec.key] === 0) {
      addReason(reasons, REASON.MISSING_MARKER);
      if (spec.key === "schema") addReason(reasons, REASON.MISSING_V2_SCHEMA);
    } else if (counts[spec.key] > 1) {
      addReason(reasons, REASON.DUPLICATE_MARKER);
    }
  }

  const firstHits = [];
  const seenKeys = new Set();
  for (const key of seen) {
    if (seenKeys.has(key)) continue;
    seenKeys.add(key);
    firstHits.push(key);
  }
  const expectedOrder = MARKER_KEYS.filter((k) => counts[k] > 0);
  if (
    firstHits.length === expectedOrder.length &&
    firstHits.some((k, i) => k !== expectedOrder[i])
  ) {
    addReason(reasons, REASON.REORDERED_MARKER);
  }

  const complete =
    MARKER_KEYS.every((k) => counts[k] === 1) &&
    !malformedKeys.size &&
    !reasons.includes(REASON.REORDERED_MARKER);

  return {
    complete,
    values,
    counts,
    reasons,
    seen,
  };
}

export function parseReservationTrailers(message) {
  const reasons = [];
  const all = linesOf(message);
  let end = all.length;
  while (end > 0 && all[end - 1] === "") end -= 1;
  let start = end;
  while (start > 0 && TRAILER_LINE_RE.test(all[start - 1])) start -= 1;
  const block = all.slice(start, end);

  const values = {};
  const seen = [];
  const counts = Object.fromEntries(TRAILER_KEYS.map((k) => [k, 0]));
  const extra = [];
  const malformedKeys = new Set();

  for (const line of block) {
    const m = line.match(TRAILER_LINE_RE);
    if (!m) continue;
    const token = m[1];
    const value = m[2];
    const spec = TRAILER_SPECS.find((s) => s.token === token);
    if (!spec) {
      extra.push(token);
      continue;
    }
    counts[spec.key] += 1;
    seen.push(spec.key);
    if (!spec.pattern.test(value)) {
      malformedKeys.add(spec.key);
      addReason(reasons, REASON.MALFORMED_TRAILER);
      continue;
    }
    if (counts[spec.key] === 1) values[spec.key] = value;
  }

  if (extra.length) addReason(reasons, REASON.MALFORMED_TRAILER);
  for (const spec of TRAILER_SPECS) {
    if (counts[spec.key] === 0) addReason(reasons, REASON.MISSING_TRAILER);
    else if (counts[spec.key] > 1) addReason(reasons, REASON.DUPLICATE_TRAILER);
  }

  const firstHits = [];
  const seenKeys = new Set();
  for (const key of seen) {
    if (seenKeys.has(key)) continue;
    seenKeys.add(key);
    firstHits.push(key);
  }
  const expectedOrder = TRAILER_KEYS.filter((k) => counts[k] > 0);
  if (
    firstHits.length === expectedOrder.length &&
    firstHits.some((k, i) => k !== expectedOrder[i])
  ) {
    addReason(reasons, REASON.REORDERED_TRAILER);
  }

  const complete =
    TRAILER_KEYS.every((k) => counts[k] === 1) &&
    extra.length === 0 &&
    !malformedKeys.size &&
    !reasons.includes(REASON.REORDERED_TRAILER);

  return { complete, values, counts, reasons, seen, extra };
}

function identityAmbiguous(id) {
  if (!id.name || !id.email) return true;
  if (id.login == null || id.login === "") return true;
  if (!LOGIN_RE.test(id.login)) return true;
  return false;
}

function subjectForged(message, claimId, issue) {
  const subject = linesOf(message)[0] || "";
  const m = subject.match(RESERVE_SUBJECT_RE);
  if (!m) return true;
  return m[1] !== String(issue) || m[2] !== String(claimId);
}

function sameText(a, b) {
  return String(a ?? "") === String(b ?? "");
}

function commitRecord(c) {
  return {
    sha: c.sha,
    author: stableIdentity(c.author),
    committer: stableIdentity(c.committer),
    tree: c.tree || null,
    parents: Array.isArray(c.parents) ? c.parents.slice() : [],
    reasons: Array.isArray(c.reasons) ? c.reasons.slice() : [],
  };
}

function emptyResult(partial) {
  return {
    schema: SCHEMA,
    authority: AUTHORITY,
    repository: partial.repository ?? null,
    pr: partial.pr ?? null,
    base: partial.base ?? null,
    head: partial.head ?? null,
    claimId: partial.claimId ?? null,
    issue: partial.issue ?? null,
    branch: partial.branch ?? null,
    reservation: Object.prototype.hasOwnProperty.call(partial, "reservation")
      ? partial.reservation
      : null,
    implementation: partial.implementation ?? [],
    unverified: partial.unverified ?? [],
    reasons: partial.reasons ?? [],
    stable: partial.stable !== false,
  };
}

export const VALID_PR_STATES = Object.freeze(["OPEN", "CLOSED", "MERGED"]);

const LIVE_IDENTITY_KEYS = Object.freeze([
  "number",
  "branch",
  "base",
  "baseOid",
  "isCrossRepository",
  "baseRepository",
  "state",
  "head",
]);

function snapshotIdentity(snap) {
  return {
    number: snap?.number ?? null,
    branch: snap?.branch ?? null,
    base: snap?.base ?? null,
    baseOid: snap?.baseOid ?? null,
    isCrossRepository: snap?.isCrossRepository,
    baseRepository: snap?.baseRepository ?? null,
    state: snap?.state ?? null,
    head: snap?.head ?? null,
  };
}

function identityValuePresent(value) {
  if (value == null) return false;
  if (typeof value === "boolean") return true;
  if (typeof value === "number") return true;
  return String(value) !== "";
}

function addIncompleteIdentity(reasons) {
  addReason(reasons, REASON.BINDING_MISMATCH);
  addReason(reasons, REASON.UNREADABLE_OBJECT);
}

export function liveIdentityEquals(a, b) {
  const left = snapshotIdentity(a);
  const right = snapshotIdentity(b);
  return LIVE_IDENTITY_KEYS.every((k) => String(left[k] ?? "") === String(right[k] ?? ""));
}

/**
 * Bind a live PR snapshot to the requested identity. A complete snapshot
 * always includes PR number, exact head branch/OID, base ref/OID/repository,
 * a boolean cross-repository flag, and a valid state (OPEN|CLOSED|MERGED).
 * Writer predicate mode additionally requires OPEN. A cross-repository PR
 * is not a parse error here — that remains FORK_PR at classify time.
 */
export function bindLiveSnapshot(snap, expected) {
  const reasons = [];
  const id = snapshotIdentity(snap);
  if (
    id.number == null ||
    !Number.isFinite(Number(id.number)) ||
    Number(id.number) <= 0
  ) {
    addIncompleteIdentity(reasons);
  }
  if (!identityValuePresent(id.branch)) addIncompleteIdentity(reasons);
  if (!HEX40.test(id.head || "")) addIncompleteIdentity(reasons);
  if (!identityValuePresent(id.base)) addIncompleteIdentity(reasons);
  if (!HEX40.test(id.baseOid || "")) addIncompleteIdentity(reasons);
  if (!identityValuePresent(id.baseRepository)) addIncompleteIdentity(reasons);
  if (typeof id.isCrossRepository !== "boolean") addIncompleteIdentity(reasons);
  if (!VALID_PR_STATES.includes(id.state)) addIncompleteIdentity(reasons);

  if (expected?.pr != null && Number(id.number) !== Number(expected.pr)) {
    addReason(reasons, REASON.BINDING_MISMATCH);
  }
  if (expected?.branch && id.branch !== expected.branch) {
    addReason(reasons, REASON.BINDING_MISMATCH);
  }
  if (expected?.base && id.base !== expected.base) {
    addReason(reasons, REASON.BINDING_MISMATCH);
  }
  if (expected?.repo && id.baseRepository !== expected.repo) {
    addReason(reasons, REASON.BINDING_MISMATCH);
    addReason(reasons, REASON.FORK_PR);
  }
  if (expected?.requireOpen === true && id.state !== "OPEN") {
    addReason(reasons, REASON.BINDING_MISMATCH);
  }
  return { ok: reasons.length === 0, reasons, identity: id };
}

/**
 * Tree of the candidate's actual sole parent. The live base tree may be
 * used only when that parent SHA is exactly the live base OID.
 */
function parentTreeOfCandidate(c, bySha, liveBaseOid, evidenceParentTree) {
  const parents = Array.isArray(c.parents) ? c.parents : [];
  if (parents.length !== 1) return null;
  const parentSha = parents[0];
  if (typeof c.parentTree === "string" && HEX40.test(c.parentTree)) {
    return c.parentTree;
  }
  const parent = parentSha ? bySha.get(parentSha) : null;
  if (typeof parent?.tree === "string" && HEX40.test(parent.tree)) {
    return parent.tree;
  }
  if (
    parentSha &&
    liveBaseOid &&
    parentSha === liveBaseOid &&
    typeof evidenceParentTree === "string" &&
    HEX40.test(evidenceParentTree)
  ) {
    return evidenceParentTree;
  }
  return null;
}

function reasonsForUnverifiedCandidate(recReasons, candidateReasons, globalReasons) {
  const out = [];
  for (const r of recReasons || []) addReason(out, r);
  for (const r of candidateReasons || []) addReason(out, r);
  for (const r of globalReasons || []) addReason(out, r);
  if (!out.length) addReason(out, REASON.BINDING_MISMATCH);
  return out;
}

/**
 * Pure classifier. Callers supply already-captured evidence. Production CLI
 * never accepts that object from the operator; it builds it from live reads.
 *
 * @param {object} evidence
 */
export function classifyClaimProvenance(evidence) {
  const reasons = [];
  const unverified = [];
  const repository = evidence?.repository ?? null;
  const pr = evidence?.pr ?? null;
  const expectedHead = evidence?.expectedHead ?? null;
  const expectedClaimId = evidence?.expectedClaimId ?? null;
  const expectedIssue =
    evidence?.expectedIssue == null ? null : String(evidence.expectedIssue);
  const expectedBranch = evidence?.expectedBranch ?? null;
  const base = evidence?.base ?? null;
  const before = evidence?.before || {};
  const after = evidence?.after || {};
  const commits = Array.isArray(evidence?.commits) ? evidence.commits : [];
  const introducedOrder = Array.isArray(evidence?.introducedOrder)
    ? evidence.introducedOrder
    : [];
  const bySha = new Map();
  for (const c of commits) {
    if (c && HEX40.test(c.sha)) bySha.set(c.sha, c);
  }

  const beforeHead = before.head || null;
  const afterHead = after.head || null;
  const beforeProj = projectClaimBody(before.body || "");
  const afterProj = projectClaimBody(after.body || "");
  let stable = true;

  if (evidence?.truncated) {
    addReason(reasons, REASON.TRUNCATED_API);
    stable = false;
  }
  if (evidence?.unreadable) {
    addReason(reasons, REASON.UNREADABLE_OBJECT);
    stable = false;
  }
  if (!beforeHead || !HEX40.test(beforeHead) || !afterHead || !HEX40.test(afterHead)) {
    addReason(reasons, REASON.UNREADABLE_OBJECT);
    stable = false;
  } else if (beforeHead !== afterHead) {
    addReason(reasons, REASON.UNSTABLE_HEAD);
    stable = false;
  }
  if (beforeProj !== afterProj) {
    addReason(reasons, REASON.UNSTABLE_BODY);
    stable = false;
  }
  if (expectedHead && HEX40.test(expectedHead) && beforeHead && expectedHead !== beforeHead) {
    addReason(reasons, REASON.HEAD_MISMATCH);
    stable = false;
  }

  const isCross = evidence?.isCrossRepository;
  const baseRepo = evidence?.baseRepository ?? null;
  if (isCross !== false || !baseRepo || baseRepo !== repository) {
    addReason(reasons, REASON.FORK_PR);
  }

  const liveExpected = {
    pr,
    branch: expectedBranch,
    base,
    repo: repository,
    requireOpen: evidence?.requireOpen === true,
  };
  const beforeBind = bindLiveSnapshot(before, liveExpected);
  const afterBind = bindLiveSnapshot(after, liveExpected);
  for (const r of beforeBind.reasons) addReason(reasons, r);
  for (const r of afterBind.reasons) addReason(reasons, r);
  if (!liveIdentityEquals(before, after)) {
    addReason(reasons, REASON.UNSTABLE_IDENTITY);
    stable = false;
  }
  if (!beforeBind.ok || !afterBind.ok) stable = false;

  const markers = parseV2BodyMarkers(before.body || "");
  for (const r of markers.reasons) addReason(reasons, r);

  if (expectedClaimId && markers.values.claimId && markers.values.claimId !== expectedClaimId) {
    addReason(reasons, REASON.BINDING_MISMATCH);
    addReason(reasons, REASON.CONFLICTING_MARKER);
  }
  if (expectedIssue && markers.values.issue && markers.values.issue !== expectedIssue) {
    addReason(reasons, REASON.BINDING_MISMATCH);
    addReason(reasons, REASON.CONFLICTING_MARKER);
  }
  if (
    markers.values.claimId &&
    markers.values.issue &&
    issueFromClaimId(markers.values.claimId) !== markers.values.issue
  ) {
    addReason(reasons, REASON.CONFLICTING_MARKER);
  }
  if (expectedBranch && markers.complete && expectedBranch) {
    // Branch is bound by trailer + CLI, not a required v2 body marker.
  }

  const claimId = markers.values.claimId || expectedClaimId || null;
  const issue = markers.values.issue || expectedIssue || null;
  const liveBranch =
    typeof before.branch === "string" && before.branch
      ? before.branch
      : typeof after.branch === "string" && after.branch
        ? after.branch
        : null;
  const branch = liveBranch || expectedBranch || null;
  const liveBaseRef =
    typeof before.base === "string" && before.base
      ? before.base
      : typeof after.base === "string" && after.base
        ? after.base
        : null;
  const reportedBase = liveBaseRef || base;
  const originalBranchPoint = markers.values.originalBranchPoint || null;
  const bodyReservation = markers.values.reservationCommit || null;

  const implementation = [];
  const firstSha = introducedOrder[0] || null;
  let verified = null;

  const canVerify =
    stable &&
    markers.complete &&
    !reasons.includes(REASON.FORK_PR) &&
    !reasons.includes(REASON.BINDING_MISMATCH) &&
    !reasons.includes(REASON.CONFLICTING_MARKER) &&
    !reasons.includes(REASON.UNSTABLE_IDENTITY) &&
    HEX40.test(bodyReservation || "") &&
    HEX40.test(originalBranchPoint || "");

  const candidateReasons = [];
  if (bodyReservation && HEX40.test(bodyReservation)) {
    if (!introducedOrder.includes(bodyReservation)) {
      addReason(candidateReasons, REASON.RESERVATION_NOT_IN_HISTORY);
      addReason(candidateReasons, REASON.REBASED_RESERVATION);
    } else if (firstSha !== bodyReservation) {
      addReason(candidateReasons, REASON.NOT_FIRST_INTRODUCED);
    }
  }

  for (const sha of introducedOrder) {
    const c = bySha.get(sha);
    const recReasons = [];
    if (!c || c.readable === false) {
      addReason(recReasons, REASON.UNREADABLE_OBJECT);
      addReason(reasons, REASON.UNREADABLE_OBJECT);
      implementation.push({
        sha,
        author: stableIdentity({}),
        committer: stableIdentity({}),
        tree: null,
        parents: [],
        reasons: recReasons.concat([REASON.ORDINARY_INTRODUCED]),
      });
      continue;
    }
    const author = identityFields(c.author);
    const committer = identityFields(c.committer);
    if (identityAmbiguous(author) || identityAmbiguous(committer)) {
      addReason(recReasons, REASON.LOGIN_AMBIGUITY);
      if (!author.name || !author.email || !committer.name || !committer.email) {
        addReason(recReasons, REASON.AUTHOR_COMMITTER_AMBIGUITY);
      }
    }

    const isCandidate = sha === bodyReservation || (!bodyReservation && sha === firstSha);
    if (isCandidate && bodyReservation) {
      const trailers = parseReservationTrailers(c.message || "");
      for (const r of trailers.reasons) addReason(candidateReasons, r);
      const parents = Array.isArray(c.parents) ? c.parents : [];
      if (parents.length !== 1) {
        addReason(candidateReasons, REASON.MULTIPLE_PARENTS);
        if (parents.length > 1) addReason(candidateReasons, REASON.REBASED_RESERVATION);
      } else if (originalBranchPoint && parents[0] !== originalBranchPoint) {
        addReason(candidateReasons, REASON.WRONG_PARENT);
        addReason(candidateReasons, REASON.REBASED_RESERVATION);
      }
      const parentSha = parents[0] || null;
      const liveBaseOid =
        (HEX40.test(before.baseOid || "") && before.baseOid) ||
        (HEX40.test(after.baseOid || "") && after.baseOid) ||
        evidence?.baseOid ||
        null;
      const parentTree = parentTreeOfCandidate(
        c,
        bySha,
        liveBaseOid,
        evidence?.parentTree
      );
      if (!c.tree || !parentTree) {
        addReason(candidateReasons, REASON.UNREADABLE_OBJECT);
      } else if (c.tree !== parentTree) {
        addReason(candidateReasons, REASON.NONEMPTY_TREE);
      }
      const dco = trailers.values.dco ? parseDco(trailers.values.dco) : null;
      if (!dco || dco.name !== author.name || dco.email !== author.email) {
        addReason(candidateReasons, REASON.DCO_MISMATCH);
      }
      if (subjectForged(c.message || "", claimId, issue)) {
        addReason(candidateReasons, REASON.FORGED_MESSAGE);
      }
      if (trailers.values.claimId && claimId && trailers.values.claimId !== claimId) {
        addReason(candidateReasons, REASON.CONFLICTING_TRAILER);
        addReason(candidateReasons, REASON.COPIED_RESERVATION);
      }
      if (trailers.values.issue && issue && trailers.values.issue !== `#${issue}`) {
        addReason(candidateReasons, REASON.CONFLICTING_TRAILER);
        addReason(candidateReasons, REASON.COPIED_RESERVATION);
      }
      if (trailers.values.branch && branch && trailers.values.branch !== branch) {
        addReason(candidateReasons, REASON.CONFLICTING_TRAILER);
        addReason(candidateReasons, REASON.COPIED_RESERVATION);
      }
      if (expectedClaimId && trailers.values.claimId && trailers.values.claimId !== expectedClaimId) {
        addReason(candidateReasons, REASON.BINDING_MISMATCH);
        addReason(candidateReasons, REASON.COPIED_RESERVATION);
      }
      if (expectedIssue && trailers.values.issue && trailers.values.issue !== `#${expectedIssue}`) {
        addReason(candidateReasons, REASON.BINDING_MISMATCH);
        addReason(candidateReasons, REASON.COPIED_RESERVATION);
      }
      if (expectedBranch && trailers.values.branch && trailers.values.branch !== expectedBranch) {
        addReason(candidateReasons, REASON.BINDING_MISMATCH);
        addReason(candidateReasons, REASON.COPIED_RESERVATION);
      }
      if (trailers.values.claimId && trailers.values.issue) {
        const trailerIssue = String(trailers.values.issue).replace(/^#/, "");
        if (issueFromClaimId(trailers.values.claimId) !== trailerIssue) {
          addReason(candidateReasons, REASON.CONFLICTING_TRAILER);
        }
      }
    }

    const candidateFailed = isCandidate && bodyReservation
      ? candidateReasons.length > 0 || !canVerify || recReasons.length > 0
      : true;

    if (isCandidate && bodyReservation && !candidateFailed && canVerify) {
      const trailers = parseReservationTrailers(c.message || "");
      const dco = parseDco(trailers.values.dco);
      verified = {
        sha,
        verified: true,
        author: stableIdentity(author),
        committer: stableIdentity(committer),
        tree: c.tree,
        parent: (c.parents || [])[0] || null,
        dco: dco ? { name: dco.name, email: dco.email } : null,
      };
    } else {
      if (isCandidate && (bodyReservation || markers.complete === false)) {
        const ureasons = reasonsForUnverifiedCandidate(
          recReasons,
          candidateReasons,
          reasons
        );
        if (!markers.complete && !bodyReservation) {
          addReason(ureasons, REASON.MISSING_V2_SCHEMA);
        }
        unverified.push({ sha, reasons: ureasons.slice() });
        for (const r of ureasons) addReason(reasons, r);
      }
      const implReasons = recReasons.concat([REASON.ORDINARY_INTRODUCED]);
      implementation.push({
        sha,
        author: stableIdentity(author),
        committer: stableIdentity(committer),
        tree: c.tree || null,
        parents: Array.isArray(c.parents) ? c.parents.slice() : [],
        reasons: implReasons,
      });
    }
  }

  if (bodyReservation && HEX40.test(bodyReservation) && !introducedOrder.includes(bodyReservation)) {
    const ureasons = reasonsForUnverifiedCandidate([], candidateReasons, reasons);
    unverified.push({ sha: bodyReservation, reasons: ureasons });
    for (const r of ureasons) addReason(reasons, r);
  }

  if (verified) {
    // A verified reservation cannot launder later ordinary commits; they stay
    // in implementation. Drop reservation-only reasons that only applied to
    // the successful candidate from the top-level report.
    const keep = reasons.filter(
      (r) =>
        r === REASON.TRUNCATED_API ||
        r === REASON.UNSTABLE_HEAD ||
        r === REASON.UNSTABLE_BODY ||
        r === REASON.UNSTABLE_IDENTITY ||
        r === REASON.UNREADABLE_OBJECT ||
        r === REASON.HEAD_MISMATCH ||
        r === REASON.FORK_PR
    );
    reasons.length = 0;
    for (const r of keep) addReason(reasons, r);
  }

  return emptyResult({
    repository,
    pr,
    base: reportedBase,
    head: beforeHead,
    claimId,
    issue: issue == null ? null : Number(issue) || issue,
    branch,
    reservation: verified,
    implementation,
    unverified,
    reasons,
    stable,
  });
}

function usage() {
  return `claim-provenance.mjs — report-only reservation classifier

WHAT IT DOES
  Reads one pull request's live body, head, and introduced commits, then
  reports at most one verified gibson-reservation/v1 commit separately from
  ordinary implementation provenance. JSON schema: ${SCHEMA}.
  Authority is ${AUTHORITY} only.

WHY
  Empty reservation commits are operational metadata. Without a bound reader,
  coordinators treat them as implementation work.

RISKS
  - Live reads that drift, truncate, or come from a fork fail closed.
  - This tool never authorizes merge, review, or release.
  - Production mode always resolves GitHub and git itself; it does not accept
    caller-supplied JSON as proof.

USAGE
  node scripts/claim-provenance.mjs --repo owner/name --pr N \\
    --expected-head <40-hex> --claim-id ID --issue N --branch NAME \\
    [--repo-path PATH] [--base main|master] \\
    [--require-verified-reservation <40-hex>]
  node scripts/claim-provenance.mjs --help

EXIT
  0 report written
  1 unreadable evidence, or required reservation not verified
  2 usage
`;
}

function git(repoPath, args) {
  return execFileSync("git", ["-C", repoPath, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 16 * 1024 * 1024,
  }).trimEnd();
}

function ghJson(args) {
  const env = { ...process.env, GH_PROMPT_DISABLED: "1", NO_COLOR: "1" };
  delete env.FORCE_COLOR;
  delete env.CLICOLOR_FORCE;
  delete env.GH_FORCE_TTY;
  const out = execFileSync("gh", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 16 * 1024 * 1024,
    env,
  });
  return JSON.parse(out);
}

function readPr(repo, pr) {
  return ghJson([
    "pr",
    "view",
    String(pr),
    "--repo",
    repo,
    "--json",
    "number,url,body,headRefOid,headRefName,isCrossRepository,baseRefName,baseRefOid,state",
  ]);
}

/**
 * Exact GitHub pull-request URL. Accepts solely:
 *   https://github.com/<owner>/<repo>/pull/<positive-decimal-number>
 * No suffix, query, fragment, extra path, trailing slash, alternate scheme,
 * credentials, port, or lookalike host. Production `gh pr view` has no
 * `baseRepository` field; this URL is the repository identity.
 *
 * @returns {{ repo: string, number: number } | null}
 */
export function parseExactGitHubPrUrl(url) {
  if (typeof url !== "string" || url === "") return null;
  if (/[\s\u0000-\u001f\u007f]/.test(url)) return null;
  const m = url.match(
    /^https:\/\/github\.com\/([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)\/([A-Za-z0-9._-]+)\/pull\/([1-9][0-9]{0,15})$/
  );
  if (!m) return null;
  const number = Number(m[3]);
  if (!Number.isSafeInteger(number) || number <= 0) return null;
  return { repo: `${m[1]}/${m[2]}`, number };
}

/**
 * Production snapshots take repository identity from the exact PR URL only.
 * A present URL that is malformed, or whose parsed number disagrees with
 * JSON `.number`, yields no repository identity (incomplete / binding
 * mismatch). Unsupported `baseRepository` is never consulted.
 */
function baseRepositoryFromPrJson(prJson) {
  const url = prJson?.url;
  if (url == null || url === "") return null;
  const parsed = parseExactGitHubPrUrl(url);
  if (!parsed) return null;
  const jsonNumber = Number(prJson?.number);
  if (!Number.isSafeInteger(jsonNumber) || jsonNumber !== parsed.number) {
    return null;
  }
  return parsed.repo;
}

function readCommitGit(repoPath, sha) {
  const raw = git(repoPath, [
    "log",
    "-1",
    "--format=%H%n%P%n%T%n%an%n%ae%n%cn%n%ce%n%B",
    sha,
  ]);
  const parts = raw.split("\n");
  if (parts.length < 7) {
    const err = new Error(`unreadable commit ${sha}`);
    err.code = REASON.UNREADABLE_OBJECT;
    throw err;
  }
  return {
    sha: parts[0],
    parents: parts[1] ? parts[1].split(" ").filter(Boolean) : [],
    tree: parts[2],
    author: { name: parts[3], email: parts[4], login: null },
    committer: { name: parts[5], email: parts[6], login: null },
    message: parts.slice(7).join("\n").replace(/\n$/, ""),
    readable: true,
  };
}

export function commitLoginsFromPayload(json, requestedSha) {
  if (json && json.truncated === true) {
    const err = new Error(`truncated commit payload for ${requestedSha}`);
    err.code = REASON.TRUNCATED_API;
    throw err;
  }
  const payloadSha = json?.sha == null ? "" : String(json.sha);
  if (!HEX40.test(payloadSha)) {
    const err = new Error(
      `commit REST sha missing or not 40-hex for ${requestedSha}`
    );
    err.code = REASON.UNREADABLE_OBJECT;
    throw err;
  }
  if (payloadSha !== requestedSha) {
    const err = new Error(
      `commit REST sha mismatch: requested ${requestedSha}, payload ${payloadSha}`
    );
    err.code = REASON.BINDING_MISMATCH;
    throw err;
  }
  return {
    authorLogin: json?.author?.login ?? null,
    committerLogin: json?.committer?.login ?? null,
  };
}

function readCommitLogins(repo, sha) {
  const path = `repos/${repo}/commits/${sha}`;
  const json = ghJson(["api", path]);
  return commitLoginsFromPayload(json, sha);
}

function ensureCommit(repoPath, sha, pr) {
  const exists = () => git(repoPath, ["cat-file", "-e", `${sha}^{commit}`]);
  try {
    exists();
    return;
  } catch {
    // fall through
  }
  try {
    git(repoPath, ["fetch", "--no-tags", "origin", sha]);
    exists();
    return;
  } catch {
    // fall through
  }
  if (pr) {
    git(repoPath, ["fetch", "--no-tags", "origin", `pull/${pr}/head`]);
    exists();
    return;
  }
  const err = new Error(`commit ${sha} is not available locally`);
  err.code = REASON.UNREADABLE_OBJECT;
  throw err;
}

/**
 * Complete commits reachable from live head but not live base, including
 * merge-side commits, oldest-first topological order. The body original
 * branch point is never the range bound.
 */
export function introducedShas(repoPath, baseOid, headOid) {
  if (!HEX40.test(baseOid || "") || !HEX40.test(headOid || "")) {
    const err = new Error("introduced range requires live base and head OIDs");
    err.code = REASON.UNREADABLE_OBJECT;
    throw err;
  }
  const out = git(repoPath, [
    "rev-list",
    "--reverse",
    "--topo-order",
    `${baseOid}..${headOid}`,
  ]);
  if (!out) return [];
  return out.split("\n").filter((s) => HEX40.test(s));
}

export function snapshotFromPr(prJson) {
  return {
    head: prJson?.headRefOid || null,
    body: prJson?.body || "",
    branch: prJson?.headRefName || null,
    number: prJson?.number ?? null,
    isCrossRepository: prJson?.isCrossRepository,
    baseRepository: baseRepositoryFromPrJson(prJson),
    base: prJson?.baseRefName || null,
    baseOid: prJson?.baseRefOid || null,
    state: prJson?.state || null,
  };
}

export async function resolveLiveEvidence(opts) {
  const repo = opts.repo;
  const pr = opts.pr;
  const repoPath = opts.repoPath;
  const expected = {
    pr,
    branch: opts.branch,
    base: opts.base || "main",
    repo,
  };
  const beforeJson = readPr(repo, pr);
  const before = snapshotFromPr(beforeJson);
  const beforeBind = bindLiveSnapshot(before, expected);
  if (!beforeBind.ok) {
    const err = new Error(
      `before live PR identity failed: ${beforeBind.reasons.join(",")}`
    );
    err.code = beforeBind.reasons.includes(REASON.BINDING_MISMATCH)
      ? REASON.BINDING_MISMATCH
      : REASON.UNREADABLE_OBJECT;
    throw err;
  }

  const head = before.head;
  const baseOid = before.baseOid;
  ensureCommit(repoPath, head, pr);
  ensureCommit(repoPath, baseOid, pr);

  const order = introducedShas(repoPath, baseOid, head);

  const markers = parseV2BodyMarkers(before.body);
  const original = markers.values.originalBranchPoint || null;
  if (markers.complete && original && HEX40.test(original)) {
    try {
      ensureCommit(repoPath, original, pr);
    } catch {
      // Preserve the unreadable parent as classification evidence. Report-only
      // mode must still return ordinary provenance; the writer predicate will
      // refuse because no reservation can verify without this object.
    }
  }

  const commits = [];
  let parentTree = null;
  try {
    parentTree = git(repoPath, ["rev-parse", `${baseOid}^{tree}`]);
  } catch {
    parentTree = null;
  }
  for (const sha of order) {
    ensureCommit(repoPath, sha, pr);
    const rec = readCommitGit(repoPath, sha);
    const logins = readCommitLogins(repo, sha);
    rec.author.login = logins.authorLogin;
    rec.committer.login = logins.committerLogin;
    if (rec.parents.length === 1) {
      const parentSha = rec.parents[0];
      try {
        rec.parentTree = git(repoPath, ["rev-parse", `${parentSha}^{tree}`]);
      } catch {
        if (parentSha === baseOid && parentTree) {
          rec.parentTree = parentTree;
        } else {
          rec.parentTree = null;
        }
      }
    }
    commits.push(rec);
  }
  if (!commits.some((c) => c.sha === baseOid)) {
    try {
      const baseCommit = readCommitGit(repoPath, baseOid);
      commits.push({ ...baseCommit, readable: true });
    } catch {
      // live base tree is already in parentTree when parent SHA === baseOid
    }
  }
  if (
    original &&
    HEX40.test(original) &&
    original !== baseOid &&
    !commits.some((c) => c.sha === original)
  ) {
    try {
      const origCommit = readCommitGit(repoPath, original);
      commits.push({ ...origCommit, readable: true });
    } catch {
      // A missing body-supplied original is not a live-read failure. The
      // classifier keeps every introduced commit ordinary and records the
      // missing marker/object evidence instead of substituting the base tree.
    }
  }

  const afterJson = readPr(repo, pr);
  const after = snapshotFromPr(afterJson);
  const afterBind = bindLiveSnapshot(after, expected);
  if (!afterBind.ok) {
    const err = new Error(
      `after live PR identity failed: ${afterBind.reasons.join(",")}`
    );
    err.code = afterBind.reasons.includes(REASON.BINDING_MISMATCH)
      ? REASON.BINDING_MISMATCH
      : REASON.UNREADABLE_OBJECT;
    throw err;
  }

  return {
    repository: repo,
    pr: Number(pr),
    expectedHead: opts.expectedHead,
    expectedClaimId: opts.claimId,
    expectedIssue: opts.issue,
    expectedBranch: opts.branch,
    base: before.base,
    isCrossRepository: before.isCrossRepository,
    baseRepository: before.baseRepository,
    before,
    after,
    truncated: false,
    unreadable: false,
    commits,
    introducedOrder: order,
    parentTree,
    baseOid,
  };
}

export async function main(argv = process.argv.slice(2)) {
  if (argv.includes("-h") || argv.includes("--help")) {
    process.stdout.write(usage());
    return 0;
  }
  for (const banned of ["--evidence", "--fixture", "--evidence-file", "--json-in"]) {
    if (argv.includes(banned)) {
      console.error(
        `claim-provenance: ${banned} is not accepted — production CLI resolves live evidence itself and never takes caller-supplied JSON as authority`
      );
      return 2;
    }
  }

  const opt = parseFlags(argv, {
    prefix: "claim-provenance: ",
    flags: {
      "--repo": { key: "repo", type: "string" },
      "--pr": { key: "pr", type: "string" },
      "--expected-head": { key: "expectedHead", type: "string" },
      "--claim-id": { key: "claimId", type: "string" },
      "--issue": { key: "issue", type: "string" },
      "--branch": { key: "branch", type: "string" },
      "--repo-path": { key: "repoPath", type: "string", default: process.cwd() },
      "--base": { key: "base", type: "string", default: "main" },
      "--require-verified-reservation": {
        key: "requireVerified",
        type: "string",
      },
    },
  });

  if (!opt.repo || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(opt.repo)) {
    console.error("claim-provenance: --repo owner/name is required");
    return 2;
  }
  if (!opt.pr || !/^[0-9]+$/.test(opt.pr)) {
    console.error("claim-provenance: --pr N is required");
    return 2;
  }
  if (!opt.expectedHead || !HEX40.test(opt.expectedHead)) {
    console.error("claim-provenance: --expected-head <40-lowercase-hex> is required");
    return 2;
  }
  if (!opt.claimId || !CLAIM_ID_RE.test(opt.claimId)) {
    console.error("claim-provenance: --claim-id is required");
    return 2;
  }
  if (!opt.issue || !/^[0-9]+$/.test(opt.issue)) {
    console.error("claim-provenance: --issue N is required");
    return 2;
  }
  if (!opt.branch) {
    console.error("claim-provenance: --branch is required");
    return 2;
  }
  if (opt.requireVerified && !HEX40.test(opt.requireVerified)) {
    console.error(
      "claim-provenance: --require-verified-reservation must be 40-lowercase-hex"
    );
    return 2;
  }
  const repoPath = resolve(String(opt.repoPath || process.cwd()));
  if (!existsSync(repoPath)) {
    console.error(`claim-provenance: --repo-path does not exist: ${repoPath}`);
    return 2;
  }

  let evidence;
  try {
    evidence = await resolveLiveEvidence({
      repo: opt.repo,
      pr: opt.pr,
      expectedHead: opt.expectedHead,
      claimId: opt.claimId,
      issue: opt.issue,
      branch: opt.branch,
      repoPath,
      base: opt.base,
    });
  } catch (err) {
    const failCode =
      err?.code === REASON.TRUNCATED_API ||
      err?.code === REASON.BINDING_MISMATCH ||
      err?.code === REASON.UNSTABLE_IDENTITY ||
      err?.code === REASON.FORK_PR
        ? err.code
        : REASON.UNREADABLE_OBJECT;
    const report = emptyResult({
      repository: opt.repo,
      pr: Number(opt.pr),
      base: opt.base,
      head: opt.expectedHead,
      claimId: opt.claimId,
      issue: Number(opt.issue),
      branch: opt.branch,
      reasons: [failCode],
      stable: false,
      unverified: [{ sha: opt.expectedHead, reasons: [failCode] }],
    });
    process.stdout.write(`${JSON.stringify(report)}\n`);
    console.error(`claim-provenance: live evidence unreadable: ${err?.message || err}`);
    return 1;
  }

  if (opt.requireVerified) evidence.requireOpen = true;
  const report = classifyClaimProvenance(evidence);
  process.stdout.write(`${JSON.stringify(report)}\n`);
  if (opt.requireVerified) {
    if (!report.reservation || report.reservation.sha !== opt.requireVerified) {
      console.error(
        `claim-provenance: required reservation ${opt.requireVerified} was not verified`
      );
      return 1;
    }
  }
  return 0;
}

function isMain() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    try {
      return pathToFileURL(resolve(entry)).href === import.meta.url;
    } catch {
      return /claim-provenance\.mjs$/.test(entry);
    }
  }
}

if (isMain()) {
  main(process.argv.slice(2))
    .then((code) => process.exit(code))
    .catch((err) => {
      console.error(String(err?.stack || err));
      process.exit(1);
    });
}
