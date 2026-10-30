#!/usr/bin/env node
/**
 * lesson-proof.mjs — report whether a closed lesson has a replayable proof (#570)
 *
 * WHAT IT DOES
 *   Reads a lesson ledger and, for every lesson whose Status is a closure,
 *   requires a Proof line. A bound proof is replayed at that commit: the
 *   entrypoint from that commit must reject the bad fixture, accept the valid
 *   fixture, and stop rejecting the bad fixture after the one disarm mutation
 *   this checker knows. Prints a text report and optional JSON. Each lesson
 *   is proven, unproven, unknown, or not-closure.
 *
 * WHY
 *   A ledger line that says fixed is not evidence that a protection fires.
 *   Issues can be closed with no check in the tree. This report separates
 *   those rows from a replay that actually ran.
 *
 * RISKS
 *   Report-only. Exit 0 after a complete report unless --strict. Does not
 *   edit the ledger, reopen issues, post comments, or set commit statuses.
 *   A replay that cannot run is unknown, never proven. The disarm mutation
 *   is one specific line; a protection that lives somewhere else is not
 *   shown to fire. Non-fix closures are never proven, because an
 *   accepted-risk sign-off is not a ledger field this checker is allowed
 *   to read.
 *
 * USAGE
 *   node scripts/lesson-proof.mjs [--ledger PATH] [--repo PATH] [--json PATH] [--strict]
 *   node scripts/lesson-proof.mjs --help
 */
import { spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { parseFlags } from "./lib/args.mjs";

const PREFIX = "lesson-proof:";
const SCHEMA = "gibson.lesson-proof.report.v1";
const GATE_TIMEOUT_MS = 5000;
const JS_ON = "const LESSON_PROOF_ENFORCE = true;";
const JS_OFF = "const LESSON_PROOF_ENFORCE = false;";
const SH_ON = "LESSON_PROOF_ENFORCE=1";
const SH_OFF = "LESSON_PROOF_ENFORCE=0";
const HEADING_RE = /^## (L-(\d{3}))\b/;
const LIMITS = [
  "Reads Status and Proof only. Every other ledger field is ignored.",
  "Does not edit the ledger and does not reopen issues. unproven is a downgrade candidate in this report.",
  "A closure with no Proof line is unproven. The Proof value unknown means the replay cannot be evaluated.",
  "Non-fix closures are never proven. Accepted-risk sign-off is not a cross-lane ledger field.",
  "Replay executes the entrypoint blob from the stated commit with --fixture. Only bash and node entrypoints are runnable.",
  "The disarm mutation rewrites exactly one LESSON_PROOF_ENFORCE line in that entrypoint file.",
  "Each gate invocation is capped at 5 seconds. A timeout, spawn failure, or missing commit is unknown.",
  "The commit must already exist in the local repository. This checker does not fetch.",
  "The checker does not read fixture bytes. The entrypoint decides what the bad directory means.",
  "A gate process receives PATH, HOME, TMPDIR, and locale only.",
  "A complete report exits 0. --strict exits non-zero when any closure is not proven, including unknown.",
  "Gate stdout and stderr are not copied into the report.",
];

function verdictProofAbsent() {
  return "unproven"; // MUTATION_PROOF_ABSENT
}
function verdictProofUnknown() {
  return "unknown"; // MUTATION_PROOF_UNKNOWN
}
function verdictProofMalformed() {
  return "unproven"; // MUTATION_PROOF_MALFORMED
}
function verdictBadPassed() {
  return "unproven"; // MUTATION_BAD_PASSED
}
function verdictDisarmStillFails() {
  return "unproven"; // MUTATION_DISARM_STILL_FAILS
}
function verdictValidFailed() {
  return "unproven"; // MUTATION_VALID_FAILED
}
function verdictAcceptedRisk() {
  return "unknown"; // MUTATION_ACCEPTED_RISK
}
function strictFailsClosed() {
  return true; // MUTATION_STRICT
}
function reportOnlyExitOk() {
  return true; // MUTATION_REPORT_ONLY
}

const FIX_RE = /^\s*fixed\b/i;
const NONFIX_RES = [
  /^\s*wontfix\b/i,
  /^\s*obsolete\b/i,
  /^\s*duplicate\b/i,
  /^\s*working as designed\b/i,
  /^\s*no fix needed\b/i,
  /^\s*not a bug\b/i,
  /^\s*closed\b/i,
  /^\s*superseded\b/i,
];

function help() {
  console.log(`lesson-proof.mjs — replay proof for closed lessons (#570)

WHAT IT DOES
  Reports proven, unproven, or unknown for every closure in the ledger.
  A closure needs a Proof line. A bound proof is replayed at that commit
  through the entrypoint itself: the bad fixture must fail, the valid
  fixture must pass, and the disarm mutation must stop the bad fixture
  from failing. Non-closure lessons are not-closure.

WHY
  Closed without a landed check must not read as healthy.

RISKS
  Report-only unless --strict. Unknown is not proven. Does not fetch, does
  not edit the ledger, and does not post a status.

USAGE
  node scripts/lesson-proof.mjs [--ledger PATH] [--repo PATH] [--json PATH]
  node scripts/lesson-proof.mjs --strict
  node scripts/lesson-proof.mjs --help

EXIT
  0  complete report (default), or --strict and every closure is proven
  1  incomplete run, or --strict and a closure is unproven or unknown
  2  usage
`);
}

function defaultRoot() {
  return resolve(dirname(fileURLToPath(import.meta.url)), "..");
}

function fenceOpen(line) {
  const m = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line);
  if (!m) return null;
  if (m[2][0] === "`" && m[3].includes("`")) return null;
  return { char: m[2][0], len: m[2].length };
}

function fenceClose(line, fence) {
  if (!fence) return false;
  const m = /^( {0,3})(`{3,}|~{3,})\s*$/.exec(line);
  if (!m) return false;
  return m[2][0] === fence.char && m[2].length >= fence.len;
}

function htmlScan(line) {
  let visible = "";
  let i = 0;
  let inside = false;
  let hadComment = false;
  while (i < line.length) {
    if (!inside) {
      const o = line.indexOf("<!--", i);
      if (o < 0) {
        visible += line.slice(i);
        break;
      }
      visible += line.slice(i, o);
      inside = true;
      hadComment = true;
      i = o + 4;
    } else {
      const c = line.indexOf("-->", i);
      if (c < 0) {
        i = line.length;
        break;
      }
      inside = false;
      i = c + 3;
    }
  }
  return { visible, opensUnclosed: inside, hadComment };
}

function classifyClosure(status) {
  if (status == null) return "unknown";
  if (FIX_RE.test(status)) return "fix";
  for (const re of NONFIX_RES) {
    if (re.test(status)) return "nonfix";
  }
  return "open";
}

function isRepoRel(p) {
  if (typeof p !== "string" || p.length === 0 || p.length > 400) return false;
  if (p.startsWith("/") || p.includes("\\") || p.includes("\0") || p.includes(":")) return false;
  const parts = p.split("/");
  if (parts.some((s) => s === "" || s === "." || s === "..")) return false;
  return true;
}

function parseProof(raw) {
  if (raw == null) return { kind: "absent" };
  const value = raw.trim();
  if (value === "unknown") return { kind: "unknown" };
  const m = /^([0-9a-f]{40}) ([^ ]+) ([^ ]+)$/.exec(value);
  if (!m || !isRepoRel(m[2]) || !isRepoRel(m[3])) return { kind: "malformed", raw: value };
  return { kind: "bound", sha: m[1], entrypoint: m[2], fixtureDir: m[3], raw: value };
}

function parseLedger(text) {
  const lines = text.split(/\r?\n/);
  const entries = [];
  let current = null;
  let fence = null;
  let htmlComment = false;
  const flush = () => {
    if (!current) return;
    entries.push(current);
    current = null;
  };
  const absorb = (entry, name, value, lineNo) => {
    const slot = name === "Status" ? "status" : "proofRaw";
    if (entry[slot] != null || entry[`${slot}Line`] != null) {
      entry.duplicateField = name;
      return;
    }
    entry[slot] = value;
    entry[`${slot}Line`] = lineNo;
    entry.cont = slot;
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (fence) {
      if (fenceClose(line, fence)) fence = null;
      continue;
    }
    if (htmlComment) {
      if (line.includes("-->")) {
        htmlComment = htmlScan(line.slice(line.indexOf("-->") + 3)).opensUnclosed;
      }
      continue;
    }
    const st = htmlScan(line);
    if (st.opensUnclosed) htmlComment = true;
    const visible = st.visible;
    if (st.hadComment && visible.trim() === "") continue;
    const open = fenceOpen(visible);
    if (open) {
      fence = open;
      continue;
    }
    const heading = visible.match(HEADING_RE);
    if (heading && visible.trim().startsWith("## ")) {
      flush();
      current = {
        id: heading[1],
        num: Number(heading[2]),
        line: i + 1,
        status: null,
        proofRaw: null,
        duplicateField: null,
        cont: null,
      };
      continue;
    }
    if (!current) continue;
    const field = visible.match(/^\*\*(Status|Proof):\*\*\s*(.*)$/);
    if (field) {
      absorb(current, field[1], field[2], i + 1);
      continue;
    }
    if (current.cont && visible.trim() !== "" && !/^\*\*[A-Za-z]/.test(visible) && !visible.startsWith("## ")) {
      current[current.cont] = `${current[current.cont]} ${visible.trim()}`;
      continue;
    }
    current.cont = null;
  }
  flush();
  for (const e of entries) {
    e.closure = classifyClosure(e.status);
    e.proof = parseProof(e.proofRaw);
  }
  return entries;
}

function gitEnv() {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (key.startsWith("GIT_") && key !== "GIT_EXEC_PATH") delete env[key];
  }
  return env;
}

function git(repo, args, timeout = 10000) {
  return spawnSync("git", ["-C", repo, ...args], {
    env: gitEnv(),
    encoding: "buffer",
    maxBuffer: 16 * 1024 * 1024,
    timeout,
  });
}

function gitText(result) {
  if (!result || !result.stdout) return "";
  return result.stdout.toString("utf8").replace(/\n$/, "");
}

function isCommit(repo, sha) {
  const r = git(repo, ["cat-file", "-t", `${sha}^{commit}`]);
  return r.status === 0 && gitText(r) === "commit";
}

function objectType(repo, spec) {
  const r = git(repo, ["cat-file", "-t", spec]);
  if (r.status !== 0) return null;
  return gitText(r);
}

function insideDir(root, target) {
  const base = resolve(root);
  const abs = resolve(target);
  return abs === base || abs.startsWith(base + sep);
}

function listBlobs(repo, sha, dir) {
  const r = git(repo, ["ls-tree", "-r", "-z", sha, "--", dir]);
  if (r.status !== 0 || r.error) return { ok: false, reason: "fixture-unreadable" };
  const buf = r.stdout || Buffer.alloc(0);
  const rows = [];
  let start = 0;
  for (let i = 0; i <= buf.length; i++) {
    if (i !== buf.length && buf[i] !== 0) continue;
    if (i === start) {
      start = i + 1;
      continue;
    }
    const rec = buf.slice(start, i).toString("utf8");
    start = i + 1;
    const tab = rec.indexOf("\t");
    if (tab < 0) return { ok: false, reason: "fixture-unreadable" };
    const meta = rec.slice(0, tab).split(" ");
    if (meta.length < 3) return { ok: false, reason: "fixture-unreadable" };
    rows.push({ mode: meta[0], type: meta[1], path: rec.slice(tab + 1) });
  }
  return { ok: true, rows };
}

function extractTree(repo, sha, dir, dest) {
  const listed = listBlobs(repo, sha, dir);
  if (!listed.ok) return listed;
  const prefix = `${dir}/`;
  for (const row of listed.rows) {
    if (row.mode === "120000" || row.type !== "blob") {
      return { ok: false, reason: "fixture-not-a-blob" };
    }
    if (!row.path.startsWith(prefix)) return { ok: false, reason: "fixture-path-escape" };
    const rel = row.path.slice(prefix.length);
    if (!rel || rel.split("/").some((s) => s === "" || s === "." || s === "..")) {
      return { ok: false, reason: "fixture-path-escape" };
    }
    const target = join(dest, rel);
    if (!insideDir(dest, target)) return { ok: false, reason: "fixture-path-escape" };
    const body = git(repo, ["cat-file", "blob", `${sha}:${row.path}`]);
    if (body.status !== 0 || body.error) return { ok: false, reason: "fixture-blob-missing" };
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, body.stdout);
  }
  return { ok: true };
}

function interpreter(file, text) {
  const lower = file.toLowerCase();
  if (lower.endsWith(".mjs") || lower.endsWith(".cjs") || lower.endsWith(".js")) {
    return { bin: process.execPath, check: ["--check", file], run: [file] };
  }
  if (lower.endsWith(".sh")) return { bin: "bash", check: ["-n", file], run: [file] };
  const first = String(text || "").split(/\n/, 1)[0];
  if (first.startsWith("#!") && /\bnode\b/.test(first)) {
    return { bin: process.execPath, check: ["--check", file], run: [file] };
  }
  if (first.startsWith("#!") && /\b(bash|sh)\b/.test(first)) {
    return { bin: "bash", check: ["-n", file], run: [file] };
  }
  return null;
}

function fileParses(file, text) {
  const how = interpreter(file, text);
  if (!how) return { ok: false, reason: "entrypoint-interpreter" };
  const r = spawnSync(how.bin, how.check, {
    encoding: "utf8",
    timeout: 10000,
    env: gitEnv(),
  });
  if (r.error || r.status !== 0) return { ok: false, reason: "entrypoint-does-not-parse", how };
  return { ok: true, how };
}

function gateEnv(work) {
  const path = [process.env.PATH, "/usr/bin", "/bin"].filter(Boolean).join(":");
  return {
    PATH: path,
    HOME: work,
    TMPDIR: work,
    LANG: "C",
    LC_ALL: "C",
  };
}

function runGate(how, file, fixtureDir, work) {
  const r = spawnSync(how.bin, [...how.run, "--fixture", fixtureDir], {
    cwd: work,
    env: gateEnv(work),
    encoding: "utf8",
    timeout: GATE_TIMEOUT_MS,
    maxBuffer: 64 * 1024,
  });
  if (r.error && r.error.code === "ETIMEDOUT") return { ran: false, reason: "gate-timeout" };
  if (r.error || r.signal) return { ran: false, reason: "gate-did-not-run" };
  if (typeof r.status !== "number") return { ran: false, reason: "gate-did-not-run" };
  return { ran: true, exitCode: r.status, reason: null };
}

function disarm(source) {
  const lines = source.split(/\n/);
  const hits = [];
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (trimmed === JS_ON || trimmed === SH_ON) hits.push(i);
  }
  if (hits.length === 0) return { applied: false, reason: "disarm-marker-absent" };
  if (hits.length !== 1) return { applied: false, reason: "disarm-marker-ambiguous" };
  const i = hits[0];
  const trimmed = lines[i].trim();
  const next = trimmed === JS_ON ? JS_OFF : SH_OFF;
  const indent = lines[i].slice(0, lines[i].length - lines[i].trimStart().length);
  lines[i] = indent + next;
  return { applied: true, source: lines.join("\n"), reason: null };
}

function legPublic(leg) {
  return {
    ran: Boolean(leg && leg.ran),
    exitCode: leg && leg.ran ? leg.exitCode : null,
    reason: leg && leg.ran ? null : (leg && leg.reason) || null,
  };
}

function runReplay(repo, proof) {
  const work = mkdtempSync(join(tmpdir(), "lesson-proof-"));
  const empty = {
    bad: { ran: false, reason: "replay-not-run" },
    valid: { ran: false, reason: "replay-not-run" },
    disarmedBad: { ran: false, reason: "replay-not-run" },
    disarm: { applied: false, parsed: false, reason: "replay-not-run" },
  };
  try {
    if (!repo || !existsSync(repo)) return failReplay(empty, "repo-missing");
    let st;
    try {
      st = lstatSync(repo);
    } catch {
      return failReplay(empty, "repo-missing");
    }
    if (!st.isDirectory()) return failReplay(empty, "repo-missing");
    const inside = git(repo, ["rev-parse", "--is-inside-work-tree"]);
    if (inside.status !== 0 || gitText(inside) !== "true") return failReplay(empty, "repo-not-git");
    if (!isCommit(repo, proof.sha)) return failReplay(empty, "sha-absent");
    const entryType = objectType(repo, `${proof.sha}:${proof.entrypoint}`);
    if (entryType == null) return failReplay(empty, "entrypoint-missing");
    if (entryType !== "blob") return failReplay(empty, "entrypoint-not-a-blob");
    const fixtureType = objectType(repo, `${proof.sha}:${proof.fixtureDir}`);
    if (fixtureType == null) return failReplay(empty, "fixture-missing");
    if (fixtureType !== "tree") return failReplay(empty, "fixture-not-a-tree");
    const blob = git(repo, ["cat-file", "blob", `${proof.sha}:${proof.entrypoint}`]);
    if (blob.status !== 0 || blob.error) return failReplay(empty, "entrypoint-unreadable");
    if (blob.stdout.includes(0)) return failReplay(empty, "entrypoint-binary");
    const source = blob.stdout.toString("utf8");
    const entryName = proof.entrypoint.split("/").pop();
    const entryPath = join(work, "entry", entryName);
    mkdirSync(dirname(entryPath), { recursive: true });
    writeFileSync(entryPath, source);
    const parsed = fileParses(entryPath, source);
    if (!parsed.ok) return failReplay(empty, parsed.reason);
    const fixtureRoot = join(work, "fixture");
    mkdirSync(fixtureRoot, { recursive: true });
    const extracted = extractTree(repo, proof.sha, proof.fixtureDir, fixtureRoot);
    if (!extracted.ok) return failReplay(empty, extracted.reason);
    const badDir = join(fixtureRoot, "bad");
    const validDir = join(fixtureRoot, "valid");
    if (!existsSync(badDir) || !lstatSync(badDir).isDirectory()) {
      return failReplay(empty, "fixture-case-missing");
    }
    if (!existsSync(validDir) || !lstatSync(validDir).isDirectory()) {
      return failReplay(empty, "fixture-case-missing");
    }
    const runDir = join(work, "run");
    mkdirSync(runDir, { recursive: true });
    const bad = runGate(parsed.how, entryPath, badDir, runDir);
    const valid = runGate(parsed.how, entryPath, validDir, runDir);
    const turned = disarm(source);
    let disarmedBad = { ran: false, reason: turned.reason || "disarm-not-applied" };
    let disarmInfo = { applied: false, parsed: false, reason: turned.reason || "disarm-not-applied" };
    if (turned.applied) {
      const disPath = join(work, "entry", `disarmed-${entryName}`);
      writeFileSync(disPath, turned.source);
      const disParsed = fileParses(disPath, turned.source);
      disarmInfo = {
        applied: true,
        parsed: disParsed.ok,
        reason: disParsed.ok ? null : "disarm-does-not-parse",
      };
      if (disParsed.ok) disarmedBad = runGate(disParsed.how, disPath, badDir, runDir);
      else disarmedBad = { ran: false, reason: "disarm-does-not-parse" };
    }
    const protectionNotFiring = Boolean(
      disarmInfo.parsed && disarmedBad.ran && disarmedBad.exitCode === 0
    );
    return {
      evaluated: true,
      reason: null,
      bad,
      valid,
      disarmedBad,
      disarm: disarmInfo,
      public: {
        sha: proof.sha,
        entrypoint: proof.entrypoint,
        fixtureDir: proof.fixtureDir,
        bad: legPublic(bad),
        valid: legPublic(valid),
        disarmedBad: {
          ...legPublic(disarmedBad),
          parsed: disarmInfo.parsed,
          protectionNotFiring,
        },
      },
    };
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

function failReplay(empty, reason) {
  return { evaluated: false, reason, ...empty, public: null };
}

function attach(entry, verdict, reason, replay) {
  const row = {
    id: entry.id,
    line: entry.line,
    status: entry.status,
    closure: entry.closure,
    verdict,
    reason,
    downgradeCandidate: verdict === "unproven",
    proof: null,
  };
  if (entry.proof && entry.proof.kind === "bound") {
    row.proof = {
      sha: entry.proof.sha,
      entrypoint: entry.proof.entrypoint,
      fixtureDir: entry.proof.fixtureDir,
    };
  } else if (entry.proofRaw != null) {
    row.proof = entry.proofRaw.trim();
  }
  if (replay && replay.public) row.replay = replay.public;
  return row;
}

function decide(entry, replay) {
  if (entry.duplicateField) return attach(entry, "unknown", "duplicate-field", null);
  if (entry.status == null) return attach(entry, "unknown", "status-missing", null);
  if (entry.closure === "open") return attach(entry, "not-closure", "status-not-closure", null);
  if (entry.proof.kind === "absent") {
    return attach(entry, verdictProofAbsent(), "proof-absent", null);
  }
  if (entry.proof.kind === "unknown") {
    return attach(entry, verdictProofUnknown(), "proof-unknown", null);
  }
  if (entry.proof.kind === "malformed") {
    return attach(entry, verdictProofMalformed(), "proof-malformed", null);
  }
  if (!replay || replay.evaluated !== true) {
    return attach(entry, "unknown", (replay && replay.reason) || "replay-not-run", null);
  }
  if (!replay.bad.ran) return attach(entry, "unknown", replay.bad.reason || "bad-did-not-run", replay);
  if (replay.bad.exitCode === 0) return attach(entry, verdictBadPassed(), "bad-fixture-passed", replay);
  if (!replay.valid.ran) return attach(entry, "unknown", replay.valid.reason || "valid-did-not-run", replay);
  if (replay.valid.exitCode !== 0) {
    return attach(entry, verdictValidFailed(), "valid-fixture-failed", replay);
  }
  if (!replay.disarm.applied) {
    return attach(entry, "unknown", replay.disarm.reason || "disarm-not-applied", replay);
  }
  if (!replay.disarm.parsed) return attach(entry, "unknown", "disarm-does-not-parse", replay);
  if (!replay.disarmedBad.ran) {
    return attach(entry, "unknown", replay.disarmedBad.reason || "disarmed-did-not-run", replay);
  }
  if (replay.disarmedBad.exitCode !== 0) {
    return attach(entry, verdictDisarmStillFails(), "disarm-still-fails", replay);
  }
  if (replay.public && replay.public.disarmedBad.protectionNotFiring !== true) {
    return attach(entry, "unknown", "protection-not-observed", replay);
  }
  if (entry.closure === "nonfix") {
    return attach(entry, verdictAcceptedRisk(), "accepted-risk-not-in-contract", replay);
  }
  return attach(entry, "proven", "replay-passed", replay);
}

function countsOf(lessons) {
  const counts = { proven: 0, unproven: 0, unknown: 0, notClosure: 0 };
  for (const lesson of lessons) {
    if (lesson.verdict === "proven") counts.proven += 1;
    else if (lesson.verdict === "unproven") counts.unproven += 1;
    else if (lesson.verdict === "unknown") counts.unknown += 1;
    else if (lesson.verdict === "not-closure") counts.notClosure += 1;
    else {
      lesson.verdict = "unknown";
      lesson.reason = "verdict-unrecognized";
      counts.unknown += 1;
    }
  }
  return counts;
}

function buildReport(lessons, strict, runStatus, runReason) {
  const counts = countsOf(lessons);
  return {
    schema: SCHEMA,
    mode: "report-only",
    strict: Boolean(strict),
    runStatus,
    runReason: runReason || null,
    limits: LIMITS,
    counts,
    lessons,
  };
}

function renderText(report) {
  const lines = [
    `${PREFIX} report-only`,
    `${PREFIX} unknown is not proven`,
  ];
  for (const lesson of report.lessons) {
    lines.push(
      `${PREFIX} ${lesson.id} verdict=${lesson.verdict} closure=${lesson.closure} reason=${lesson.reason}`
    );
  }
  const c = report.counts;
  lines.push(
    `${PREFIX} counts proven=${c.proven} unproven=${c.unproven} unknown=${c.unknown} not-closure=${c.notClosure}`
  );
  lines.push(`${PREFIX} run ${report.runStatus}${report.runReason ? ` reason=${report.runReason}` : ""}`);
  return `${lines.join("\n")}\n`;
}

function writeJson(path, report) {
  const body = `${JSON.stringify(report, null, 2)}\n`;
  if (!path) return body;
  const dir = dirname(path);
  if (!existsSync(dir)) {
    const err = new Error(`json directory missing: ${dir}`);
    err.code = "E_JSON";
    throw err;
  }
  writeFileSync(path, body);
  return null;
}

function noteSummary(report) {
  const line = `${PREFIX} report-only proven=${report.counts.proven} unproven=${report.counts.unproven} unknown=${report.counts.unknown} not-closure=${report.counts.notClosure}. This job does not block merges.`;
  if (process.env.GITHUB_ACTIONS) console.log(`::notice::${line}`);
  const summary = process.env.GITHUB_STEP_SUMMARY;
  if (summary) {
    writeFileSync(
      summary,
      `### lesson-proof\n\n${line}\n\nAdvisory report. \`--strict\` is not enabled.\n`,
      { flag: "a" }
    );
  }
}

function exitCodeFor(report, strict) {
  if (report.runStatus !== "complete") return 1;
  const pending = report.counts.unproven > 0 || report.counts.unknown > 0;
  if (strict && strictFailsClosed() && pending) return 1;
  if (!reportOnlyExitOk() && pending) return 1;
  return 0;
}

function emit(report, jsonPath) {
  process.stdout.write(renderText(report));
  try {
    const inline = writeJson(jsonPath, report);
    if (inline) process.stdout.write(inline);
  } catch (err) {
    if (err && err.code === "E_JSON") {
      console.error(`${PREFIX} ${err.message}`);
      process.exit(1);
    }
    throw err;
  }
  noteSummary(report);
  return exitCodeFor(report, report.strict);
}

function incomplete(reason, strict, jsonPath) {
  const report = buildReport([], strict, "incomplete", reason);
  process.exit(emit(report, jsonPath));
}

function readLedger(path) {
  let st;
  try {
    st = lstatSync(path);
  } catch {
    return { error: "ledger-missing" };
  }
  if (st.isSymbolicLink()) return { error: "ledger-symlink" };
  if (!st.isFile()) return { error: "ledger-not-a-file" };
  try {
    return { text: readFileSync(path, "utf8") };
  } catch {
    return { error: "ledger-unreadable" };
  }
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("-h") || argv.includes("--help")) {
    help();
    process.exit(0);
  }
  const opt = parseFlags(argv, {
    flags: {
      "--ledger": { key: "ledger", default: null },
      "--repo": { key: "repo", default: null },
      "--json": { key: "json", default: null },
      "--strict": { key: "strict", type: "boolean" },
    },
    prefix: `${PREFIX} `,
  });
  const root = defaultRoot();
  const ledgerPath = resolve(opt.ledger || join(root, "memory", "LESSONS.md"));
  const repo = resolve(opt.repo || root);
  const read = readLedger(ledgerPath);
  if (read.error) incomplete(read.error, opt.strict, opt.json);
  let entries;
  try {
    entries = parseLedger(read.text);
  } catch {
    incomplete("ledger-parse-failed", opt.strict, opt.json);
  }
  const idCounts = new Map();
  for (const entry of entries) {
    idCounts.set(entry.id, (idCounts.get(entry.id) || 0) + 1);
  }
  for (const entry of entries) {
    if (idCounts.get(entry.id) > 1) entry.duplicateField = entry.duplicateField || "id";
  }
  const lessons = [];
  for (const entry of entries) {
    let replay = null;
    const bound = entry.closure !== "open" && entry.proof && entry.proof.kind === "bound" && !entry.duplicateField && entry.status != null;
    if (bound) replay = runReplay(repo, entry.proof);
    lessons.push(decide(entry, replay));
  }
  lessons.sort((a, b) => a.line - b.line);
  const report = buildReport(lessons, opt.strict, "complete", null);
  process.exit(emit(report, opt.json));
}

main();
