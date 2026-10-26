#!/usr/bin/env node
/**
 * lesson-ledger-lint.mjs — Law 9 ledger integrity sensor (#306)
 *
 * WHAT IT DOES
 *   Reads memory/LESSONS.md and fails closed when:
 *     1. An L-NNN cited under scripts/, ci/, docs/, playbooks/, config/,
 *        .github/, adapters/, or templates/ has no heading in the ledger.
 *     2. A lesson's **Status:** is `fix-pending (issue #N)` and issue N is
 *        closed (gh api). `--offline` skips only this check and says so.
 *     3. A lesson is not `fixed` but a file under scripts/tests/ names its
 *        ID via an explicit pin marker (`# pins L-NNN`, `pin: L-NNN`,
 *        `regression: L-NNN`) or a test/case name containing that ID.
 *        A `fixed (pinned by X)` claim is checked against the same rule.
 *     4. IDs are not strictly increasing in file order, an ID appears twice,
 *        or an entry lacks **Status:** or **Tags:**.
 *     5. Evidence schema (docs/schemas/lesson-ledger.md). Lessons below
 *        L-098 may omit Evidence, Proof, Occurred, Ingested, and Reverted
 *        attempt: omission is reported `unknown` and does not fail. From
 *        L-098 on, those lines must be present (the value may be `unknown`).
 *        `unknown` is not a pass. Status `fixed` with Proof `unknown` fails.
 *        A shaped Proof whose paths exist is `unverified`: this lint does
 *        not run the gate, resolve the commit, or fetch URLs. Incident files
 *        under memory/incidents/ must map 1:1 through INDEX.md to one
 *        existing lesson. Privacy rules on Evidence, Proof, Reverted
 *        attempt, Occurred, and Ingested, and on the full text of
 *        memory/incidents/, fail closed. A fenced copy is not a lesson
 *        field (same parser as Status). Incident files are scrubbed in
 *        full, fences included.
 *
 * WHY
 *   A ledger nobody can trust stops being read, then stops being fed (Law 9).
 *   Missing evidence must not read as proof.
 *
 * RISKS
 *   Citation scan is a token match, not a parser. gh api is fail-closed
 *   (nonzero on any error) unless --offline. Read-only; never mutates.
 *   Privacy rules are patterns, not the public-hygiene deny-list. Historical
 *   lesson prose is not privacy-scanned (that would fail the existing ledger).
 *
 * USAGE
 *   node scripts/lesson-ledger-lint.mjs
 *   node scripts/lesson-ledger-lint.mjs --root PATH [--ledger PATH] [--offline] [--repo owner/name]
 *   node scripts/lesson-ledger-lint.mjs --help
 */

import { spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  readdirSync,
  readFileSync,
} from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { parseFlags } from "./lib/args.mjs";

const PREFIX = "lesson-ledger-lint:";
const LEDGER_REL = "memory/LESSONS.md";
const SCAN_ROOTS = [
  "scripts",
  "ci",
  "docs",
  "playbooks",
  "config",
  ".github",
  "adapters",
  "templates",
];
const SKIP_DIRS = new Set([
  ".git",
  "node_modules",
  ".venv",
  "dist",
  "coverage",
  "vendor",
]);
const BINARY_EXT = new Set([
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".webp",
  ".ico",
  ".woff",
  ".woff2",
  ".ttf",
  ".eot",
  ".zip",
  ".gz",
  ".tgz",
  ".wasm",
  ".pdf",
  ".mp4",
  ".mp3",
  ".bin",
  ".DS_Store",
]);
const ID_RE = /(?<![A-Za-z0-9])L-(\d{3})(?!\d)/g;
const HEADING_RE = /^## (L-(\d{3}))\b/;
const PENDING_ISSUE_RE = /fix-pending\s*\(\s*issue\s*#(\d+)/i;
const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const PINNED_BY_PATH_RE = /scripts\/tests\/[A-Za-z0-9._/-]+\.test\.sh/g;
const GH_TIMEOUT_MS = 20000;

function fenceOpen(line) {
  const m = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line);
  if (!m) return null;
  const marker = m[2];
  const info = m[3];
  // CommonMark: a backtick fence's info string may not contain a backtick.
  if (marker[0] === "`" && info.includes("`")) return null;
  return { char: marker[0], len: marker.length };
}

function isFenceClose(line, fence) {
  if (!fence) return false;
  const m = /^( {0,3})(`{3,}|~{3,})\s*$/.exec(line);
  if (!m) return false;
  const marker = m[2];
  return marker[0] === fence.char && marker.length >= fence.len;
}

function help() {
  console.log(`lesson-ledger-lint.mjs — Law 9 ledger integrity sensor (#306)

WHAT IT DOES
  Fails when a cited lesson identifier is absent from the ledger; when a
  lesson is fix-pending on a closed GitHub issue; when a test pins a lesson
  that is not fixed (explicit pin marker or test/case name only); or when
  ledger IDs are duplicated, not strictly increasing, or missing **Status:**
  / **Tags:**. From L-098 on, Evidence, Proof, Occurred, Ingested, and
  Reverted attempt must be present. A missing older field is reported
  unknown and is not a pass. Status fixed with Proof unknown fails.
  A shaped Proof is unverified: this command does not run it. Incident
  files must match memory/incidents/INDEX.md and point at one real lesson.
  Privacy rules on those evidence fields, and on memory/incidents/ text,
  fail closed.

WHY
  Status that nobody reads is not a ratchet. The ledger has to be mechanically
  honest or Law 9 produces prose instead of fixes. unknown is not correct.

RISKS
  Token scan, not a markdown AST. Closed-issue check calls gh api and fails
  closed on any error unless --offline (which skips only that check and says
  so). Read-only. Does not resolve commits or URLs. Does not scan historical
  lesson prose for private paths.

USAGE
  node scripts/lesson-ledger-lint.mjs
  node scripts/lesson-ledger-lint.mjs --root PATH [--ledger PATH]
  node scripts/lesson-ledger-lint.mjs --offline --repo owner/name
  node scripts/lesson-ledger-lint.mjs --help

EXIT
  0  structure is consistent. Unknown or unverified evidence is NOT a pass
     and is not correct. The evidence-report line counts those states.
  1  findings, or an error path (missing ledger, gh failure, unreadable file,
     privacy rule, broken incident map, fixed with Proof unknown)
  2  usage
`);
}

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
  help();
  process.exit(0);
}

const opt = parseFlags(args, {
  flags: {
    "--root": { key: "root", default: null },
    "--ledger": { key: "ledger", default: null },
    "--offline": { key: "offline", type: "boolean" },
    "--repo": { key: "repo", default: null },
  },
  prefix: `${PREFIX} `,
});

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = resolve(HERE, "..");

function die(msg, code = 1) {
  console.error(`${PREFIX} ${msg}`);
  process.exit(code);
}

function relPosix(root, abs) {
  return relative(root, abs).split(sep).join("/");
}

function isFixedStatus(status) {
  return /^\s*fixed\b/i.test(status || "");
}

function fieldValue(body, name) {
  const lines = body.split(/\r?\n/);
  const re = new RegExp(`^\\*\\*${name}:\\*\\*\\s*(.*)$`);
  let fence = null;
  let htmlComment = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (fence) {
      if (isFenceClose(line, fence)) fence = null;
      continue;
    }
    if (htmlComment) { if (line.includes("-->")) { htmlComment = htmlScan(line.slice(line.indexOf("-->") + 3)).opensUnclosed; } continue; }
    const st = htmlScan(line);
    if (st.opensUnclosed) htmlComment = true;
    if (st.hadComment) continue; // a field on a line that also carries comment markup is not a clean field
    const open = fenceOpen(line);
    if (open) {
      fence = open;
      continue;
    }
    const m = line.match(re);
    if (!m) continue;
    const parts = [m[1]];
    for (let j = i + 1; j < lines.length; j++) {
      const cont = lines[j];
      if (fenceOpen(cont)) break;
      if (/^\*\*[A-Za-z][^:*]*:\*\*/.test(cont)) break;
      if (/^##\s/.test(cont)) break;
      if (cont.trim() === "") continue;
      parts.push(cont.trim());
    }
    return parts.join(" ").trim();
  }
  return null;
}

/**
 * Walk every `<!--` / `-->` on one line. Returns the text outside comments
 * (`visible`), whether the line ends inside an unclosed comment
 * (`opensUnclosed`), and whether any comment appeared (`hadComment`).
 */
function htmlScan(line) {
  let visible = ""; let i = 0; let inside = false; let hadComment = false;
  while (i < line.length) {
    if (!inside) {
      const o = line.indexOf("<!--", i);
      if (o < 0) { visible += line.slice(i); break; }
      visible += line.slice(i, o); inside = true; hadComment = true; i = o + 4;
    } else {
      const c = line.indexOf("-->", i);
      if (c < 0) { i = line.length; break; }
      inside = false; i = c + 3;
    }
  }
  return { visible, opensUnclosed: inside, hadComment };
}

function parseLedger(text) {
  const lines = text.split(/\r?\n/);
  const entries = [];
  let current = null;
  let fence = null;
  const flush = (endLine) => {
    if (!current) return;
    current.endLine = endLine;
    current.body = lines.slice(current.startLine, endLine).join("\n");
    current.status = fieldValue(current.body, "Status");
    current.tags = fieldValue(current.body, "Tags");
    current.evidence = fieldValue(current.body, "Evidence");
    current.proof = fieldValue(current.body, "Proof");
    current.reverted = fieldValue(current.body, "Reverted attempt");
    current.occurred = fieldValue(current.body, "Occurred");
    current.ingested = fieldValue(current.body, "Ingested");
    entries.push(current);
    current = null;
  };
  let htmlComment = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (fence) {
      if (isFenceClose(line, fence)) fence = null;
      continue;
    }
    // An HTML comment block is not ledger content (Codex #316 round 3,
    // finding 4): a commented-out template must not become an entry.
    if (htmlComment) {
      if (line.includes("-->")) htmlComment = htmlScan(line.slice(line.indexOf("-->") + 3)).opensUnclosed;
      continue;
    }
    // A comment may open mid-line, and a line may hold several openers and
    // closers (`<!-- x --> <!--`): walk them all; the state after the LAST
    // one wins (Codex #316 rounds 4–5). Content before the first opener is
    // still content (a heading before a comment still counts).
    const st = htmlScan(line);
    if (st.opensUnclosed) htmlComment = true;
    if (st.visible.trim() === "" && (st.opensUnclosed || st.hadComment)) continue;
    if (st.hadComment) { const mh = st.visible.match(HEADING_RE); if (mh) { flush(i); current = { id: mh[1], num: Number(mh[2]), headingLine: i + 1, startLine: i, headingText: st.visible.trim() }; } continue; }
    const open = fenceOpen(line);
    if (open) {
      fence = open;
      continue;
    }
    const m = line.match(HEADING_RE);
    if (m) {
      flush(i);
      current = {
        id: m[1],
        num: Number(m[2]),
        headingLine: i + 1,
        startLine: i,
        headingText: line,
      };
    }
  }
  const unclosedFence = fence != null;
  flush(lines.length);
  return { entries, unclosedFence };
}

function walkFiles(rootAbs, relDir, acc) {
  const absDir = join(rootAbs, relDir);
  let ents;
  try {
    ents = readdirSync(absDir, { withFileTypes: true });
  } catch (err) {
    throw new Error(`cannot read ${relDir}: ${err.message}`);
  }
  for (const ent of ents) {
    if (ent.name === "." || ent.name === "..") continue;
    const rel = relDir ? `${relDir}/${ent.name}` : ent.name;
    const abs = join(rootAbs, rel);
    let st;
    try {
      st = lstatSync(abs);
    } catch (err) {
      throw new Error(`cannot stat ${rel}: ${err.message}`);
    }
    if (st.isSymbolicLink()) continue;
    if (st.isDirectory()) {
      if (SKIP_DIRS.has(ent.name)) continue;
      walkFiles(rootAbs, rel, acc);
      continue;
    }
    if (!st.isFile()) continue;
    const dot = ent.name.lastIndexOf(".");
    const ext = dot >= 0 ? ent.name.slice(dot).toLowerCase() : "";
    if (BINARY_EXT.has(ext) || ent.name === ".DS_Store") continue;
    acc.push(rel);
  }
}

function collectIds(text) {
  const hits = [];
  ID_RE.lastIndex = 0;
  let m;
  while ((m = ID_RE.exec(text)) !== null) {
    const line = text.slice(0, m.index).split(/\r?\n/).length;
    hits.push({ id: `L-${m[1]}`, line });
  }
  return hits;
}

function isCommentLine(line) {
  const trimmed = line.replace(/^\s+/, "");
  return /^#/.test(trimmed) || /^\/\//.test(trimmed);
}

function quotedContainsId(line, id) {
  const re = /(["'])(?:\\.|(?!\1).)*\1/g;
  let m;
  while ((m = re.exec(line)) !== null) {
    if (m[0].includes(id)) return true;
  }
  return false;
}

function isExplicitPinMarker(line, id) {
  if (!line.includes(id)) return false;
  const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // A marker inside quoted data (`printf '%s\n' '# pins L-020' > fixture`) is
  // fixture text, not a pin (Codex #316 round 3, finding 2). Only a line that
  // IS a comment, or a bare `pin:`/`regression:` line, counts.
  const trimmed = line.trim();
  const markerRe = new RegExp(`#\\s*(?:pins?|pin:|regression:)\\s*${escaped}\\b`, "i");
  if (/^#/.test(trimmed)) return markerRe.test(trimmed);
  // Split the line into code and trailing comment at the first `#` that is
  // outside quotes (Codex #316 round 5, finding 1): a quoted copy of the ID
  // in the code part (`grep -q 'L-001' … # pins L-001`) must not veto the
  // real marker in the comment part.
  let q = null; let cut = -1;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (q) { if (ch === "\\" && q === '"') { i++; continue; } if (ch === q) q = null; continue; }
    if (ch === '"' || ch === "'") { q = ch; continue; }
    if (ch === "#") { cut = i; break; }
  }
  const code = cut >= 0 ? line.slice(0, cut) : line;
  const comment = cut >= 0 ? line.slice(cut) : "";
  if (comment && markerRe.test(comment)) return true;
  if (quotedContainsId(code, id)) return false;
  if (new RegExp(`\\b(?:pin|regression):\\s*${escaped}\\b`, "i").test(code)) return true;
  return false;
}

/**
 * The TITLE of a test-name line is the first quoted argument after a
 * title-bearing command at line start: `ok "…"`, `bad "…"`, `expect "…"`,
 * `check "…"`, `@test "…"`, `test("…")`, `it("…")`, `describe("…")`, or a
 * bare `echo "…"` with no pipe/redirect. Only that argument is judged
 * (Codex #316 round 6): a fixture line that merely CONTAINS such text
 * (`printf … '@test "L-NNN"' > fixture`) starts with printf and has no title;
 * an assertion string later on the line is not the title.
 */
function titleOf(line) {
  // ok/bad/expect/check may take one bare subcommand word before the title
  // (`expect none "…"`, `check file "…"`).
  const m = line.match(/^\s*(?:(?:ok|bad|expect|check)\s+(?:[A-Za-z_][A-Za-z0-9_-]*\s+)?|@(?:test|it)\s+|(?:test|it|describe)\s*\(\s*|echo\s+)(["'])((?:\\.|(?!\1).)*)\1/);
  if (!m) return null;
  if (/^\s*echo\b/.test(line) && /[|>]/.test(line)) return null;
  return { text: m[2], isEcho: /^\s*echo\b/.test(line) };
}

function isTestNameLine(line, id) {
  if (isCommentLine(line)) return false;
  if (!line.includes(id)) return false;
  const t = titleOf(line);
  if (!t) return false;
  const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // A title containing the ID pins it (the issue's rule); a bare echo title
  // must LEAD with the ID (`echo "# L-NNN · …"`) so needles never qualify.
  if (t.isEcho) return new RegExp(`^(?:#\\s*)?${escaped}(?:\\s|·|:|$)`).test(t.text);
  return new RegExp(`(?:^|[^A-Za-z0-9])${escaped}(?![0-9])`).test(t.text);
}

function filePinsId(rel, text, id) {
  if (!rel.startsWith("scripts/tests/") || rel === "scripts/tests") return false;
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.includes(id)) continue;
    if (isExplicitPinMarker(line, id)) return true;
    if (isTestNameLine(line, id)) return true;
  }
  return false;
}

function claimedPinPaths(status) {
  if (!status || !/pinned by/i.test(status)) return [];
  const idx = status.toLowerCase().lastIndexOf("pinned by");
  const after = idx >= 0 ? status.slice(idx) : status;
  const paths = [];
  const re = new RegExp(PINNED_BY_PATH_RE.source, "g");
  let m;
  while ((m = re.exec(after)) !== null) paths.push(m[0]);
  return paths;
}

function resolveRoot(raw) {
  const root = resolve(raw || DEFAULT_ROOT);
  if (!existsSync(root)) die(`--root not found: ${root}`);
  let st;
  try {
    st = lstatSync(root);
  } catch (err) {
    die(`cannot stat --root ${root}: ${err.message}`);
  }
  if (st.isSymbolicLink()) die(`refusing to follow symlink --root: ${root}`);
  if (!st.isDirectory()) die(`--root is not a directory: ${root}`);
  return root;
}

function resolveLedger(root, raw) {
  const abs = raw
    ? raw.startsWith("/")
      ? resolve(raw)
      : resolve(root, raw)
    : resolve(root, LEDGER_REL);
  if (!existsSync(abs)) die(`ledger not found: ${abs}`);
  let st;
  try {
    st = lstatSync(abs);
  } catch (err) {
    die(`cannot stat ledger ${abs}: ${err.message}`);
  }
  if (st.isSymbolicLink()) die(`refusing to follow symlink ledger: ${abs}`);
  if (!st.isFile()) die(`ledger is not a regular file: ${abs}`);
  return abs;
}

function resolveRepo(flag, opts = {}) {
  if (flag) {
    if (!REPO_RE.test(flag)) die(`--repo must be owner/name (got ${JSON.stringify(flag)})`);
    return flag;
  }
  const cwd = opts.cwd || process.cwd();
  const ignoreAmbientRepo = Boolean(opts.ignoreAmbientRepo);
  const env = {
    ...process.env,
    GH_PROMPT_DISABLED: "1",
    NO_COLOR: "1",
  };
  if (ignoreAmbientRepo) {
    delete env.GITHUB_REPOSITORY;
    delete env.GH_REPO;
  } else {
    const envRepo = process.env.GITHUB_REPOSITORY || "";
    if (envRepo && REPO_RE.test(envRepo)) return envRepo;
  }
  const r = spawnSync(
    "gh",
    ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
    {
      encoding: "utf8",
      timeout: GH_TIMEOUT_MS,
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    }
  );
  if (r.error) {
    die(`cannot resolve repo (gh repo view): ${r.error.message}`);
  }
  if (r.status !== 0) {
    const detail = (r.stderr || r.stdout || "").trim() || `exit ${r.status}`;
    die(`cannot resolve repo (gh repo view): ${detail}`);
  }
  const name = (r.stdout || "").trim();
  if (!REPO_RE.test(name)) {
    die(`cannot resolve repo: unusable gh repo view output ${JSON.stringify(name)}`);
  }
  return name;
}

function ghIssueState(repo, n) {
  const r = spawnSync(
    "gh",
    ["api", `repos/${repo}/issues/${n}`, "-q", ".state"],
    {
      encoding: "utf8",
      timeout: GH_TIMEOUT_MS,
      env: { ...process.env, GH_PROMPT_DISABLED: "1", NO_COLOR: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    }
  );
  if (r.error) {
    throw new Error(`${r.error.message}`);
  }
  if (r.status !== 0) {
    const detail = (r.stderr || r.stdout || "").trim() || `exit ${r.status}`;
    throw new Error(detail);
  }
  const state = (r.stdout || "").trim();
  if (state !== "open" && state !== "closed") {
    throw new Error(`unusable state ${JSON.stringify(state)}`);
  }
  return state;
}

// Lessons at this id and after are schema records: the lines must exist.
// Older lessons omit them; omission is reported unknown and does not fail.
const SCHEMA_LESSON_MIN = 98;
const STRICT_HEADING_RE = /^## L-\d{3} · \d{4}-\d{2}-\d{2} · [a-z0-9-]+$/;
const INCIDENT_HEADING_RE = /^## (I-\d{3}) · (\d{4}-\d{2}-\d{2}) · ([a-z0-9-]+)$/;
const INCIDENT_FILE_RE = /^I-(\d{3})\.md$/;
const INDEX_ROW_RE = /^(I-\d{3}) (L-\d{3})$/;
const PROOF_RE = /^([0-9a-f]{40}) ([A-Za-z0-9._/-]+) ([A-Za-z0-9._/-]+)$/;
const PUBLIC_REF_RE =
  /^(?:https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/(?:issues|pull|commit|actions)\/[A-Za-z0-9_./-]+|[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#\d+|[0-9a-f]{40})$/;
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const PRIVACY_RULES = [
  { id: "home-users", re: /\/Users\// },
  { id: "home-posix", re: /\/home\// },
  { id: "tilde-path", re: /~\// },
  {
    id: "internal-host",
    re: /(?:^|[^A-Za-z0-9.-])(?:[A-Za-z0-9-]+\.)+(?:internal|local)(?![A-Za-z0-9-])/,
  },
  { id: "pem-key", re: /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/ },
  {
    id: "assigned-secret",
    re: /\b(?:api[_-]?key|token|password|secret)\s*[:=]\s*\S{8,}/i,
  },
];
const SCHEMA_FIELDS = [
  ["Evidence", "evidence"],
  ["Proof", "proof"],
  ["Reverted attempt", "reverted"],
  ["Occurred", "occurred"],
  ["Ingested", "ingested"],
];

function isYmd(value) {
  const m = DATE_RE.exec(value || "");
  if (!m) return false;
  const month = Number(m[2]);
  const day = Number(m[3]);
  return month >= 1 && month <= 12 && day >= 1 && day <= 31;
}

function isRepoRel(p) {
  if (!p || p.startsWith("/") || p.includes("\\") || p.includes("\0")) return false;
  if (!/^[A-Za-z0-9._/-]+$/.test(p)) return false;
  return p.split("/").every((part) => part !== "" && part !== "." && part !== "..");
}

function privacyHits(text) {
  if (!text) return [];
  const hits = [];
  for (const rule of PRIVACY_RULES) {
    if (rule.re.test(text)) hits.push(rule.id);
  }
  return hits;
}

function classifyProof(value) {
  if (value == null) return { state: "unknown" };
  if (value === "unknown") return { state: "unknown" };
  const m = PROOF_RE.exec(value);
  if (!m) return { state: "invalid" };
  if (!isRepoRel(m[2]) || !isRepoRel(m[3])) return { state: "invalid" };
  return { state: "shaped", sha: m[1], entry: m[2], fixture: m[3] };
}

function classifyEvidence(value) {
  if (value == null) return { state: "unknown" };
  if (value === "unknown") return { state: "unknown" };
  const tokens = value.split(/\s+/).filter(Boolean);
  if (tokens.length === 0 || !tokens.every((t) => PUBLIC_REF_RE.test(t))) {
    return { state: "invalid" };
  }
  return { state: "well-formed" };
}

function pathKind(root, rel) {
  if (!isRepoRel(rel)) return "invalid";
  const abs = resolve(root, rel);
  const rootAbs = resolve(root);
  if (abs !== rootAbs && !abs.startsWith(rootAbs + sep)) return "invalid";
  let st;
  try {
    st = lstatSync(abs);
  } catch {
    return "absent";
  }
  if (st.isSymbolicLink()) return "symlink";
  if (st.isFile()) return "file";
  if (st.isDirectory()) return "dir";
  return "absent";
}

function collectLessonEvidence(root, entries, findings, reports, ledgerRel) {
  let proofUnknown = 0;
  let proofUnverified = 0;
  let evidenceUnknown = 0;
  for (const e of entries) {
    if (e.num >= SCHEMA_LESSON_MIN && !STRICT_HEADING_RE.test(e.headingText || "")) {
      findings.push(
        `${e.id} heading is not '## L-NNN · YYYY-MM-DD · slug' (${ledgerRel}:${e.headingLine})`
      );
    }
    for (const [label, key] of SCHEMA_FIELDS) {
      const raw = e[key];
      if (raw == null && e.num >= SCHEMA_LESSON_MIN) {
        findings.push(
          `${e.id} is missing **${label}:** (the absent value is not unknown; write the word unknown) (${ledgerRel}:${e.headingLine})`
        );
      }
      if (raw == null) continue;
      for (const rule of privacyHits(raw)) {
        findings.push(
          `${e.id} field ${label} matches privacy rule ${rule} (${ledgerRel}:${e.headingLine})`
        );
      }
    }
    if (e.occurred != null && !isYmd(e.occurred)) {
      findings.push(`${e.id} Occurred is not YYYY-MM-DD (${ledgerRel}:${e.headingLine})`);
    }
    if (e.ingested != null && !isYmd(e.ingested)) {
      findings.push(`${e.id} Ingested is not YYYY-MM-DD (${ledgerRel}:${e.headingLine})`);
    }
    const evidence = classifyEvidence(e.evidence);
    const proof = classifyProof(e.proof);
    if (evidence.state === "unknown") evidenceUnknown += 1;
    if (e.evidence != null && evidence.state === "invalid") {
      findings.push(
        `${e.id} Evidence is not unknown and not a list of public refs (${ledgerRel}:${e.headingLine})`
      );
    }
    if (proof.state === "unknown") proofUnknown += 1;
    if (e.proof != null && proof.state === "invalid") {
      findings.push(
        `${e.id} Proof is not unknown and not '<40-hex> <repo-relative entrypoint> <repo-relative fixture dir>' (${ledgerRel}:${e.headingLine})`
      );
    }
    if (proof.state === "shaped") {
      const entryKind = pathKind(root, proof.entry);
      const fixtureKind = pathKind(root, proof.fixture);
      if (entryKind === "symlink" || fixtureKind === "symlink") {
        proof.state = "invalid";
        findings.push(
          `${e.id} Proof path is a symlink; this lint does not follow it (${ledgerRel}:${e.headingLine})`
        );
      } else if (entryKind !== "file") {
        proof.state = "invalid";
        findings.push(
          `${e.id} Proof entrypoint is ${entryKind}: ${proof.entry} (${ledgerRel}:${e.headingLine})`
        );
      } else if (fixtureKind !== "dir") {
        proof.state = "invalid";
        findings.push(
          `${e.id} Proof fixture dir is ${fixtureKind}: ${proof.fixture} (${ledgerRel}:${e.headingLine})`
        );
      } else {
        proof.state = "unverified";
        proofUnverified += 1;
      }
    }
    if (isFixedStatus(e.status) && e.proof != null && classifyProof(e.proof).state === "unknown") {
      findings.push(
        `${e.id} status is fixed but Proof is unknown; unknown is not correct (${ledgerRel}:${e.headingLine})`
      );
    }
    if (/^\s*reverted\b/i.test(e.status || "") && (e.reverted == null || e.reverted === "unknown")) {
      findings.push(
        `${e.id} status is reverted but Reverted attempt is unknown (${ledgerRel}:${e.headingLine})`
      );
    }
    const revertedWord =
      e.reverted == null || e.reverted === "unknown" ? "unknown" : "recorded";
    reports.push(
      `${e.id} evidence=${evidence.state} proof=${proof.state} reverted=${revertedWord}`
    );
  }
  return { proofUnknown, proofUnverified, evidenceUnknown };
}

function privacyFileHits(text) {
  const lines = text.split(/\r?\n/);
  const hits = [];
  for (let i = 0; i < lines.length; i++) {
    for (const rule of PRIVACY_RULES) {
      if (rule.re.test(lines[i])) hits.push({ line: i + 1, rule: rule.id });
    }
  }
  return hits;
}

function collectIncidents(root, byId, findings, reports) {
  const dirRel = "memory/incidents";
  const dir = join(root, dirRel);
  if (!existsSync(dir)) {
    return 0;
  }
  let dirStat;
  try {
    dirStat = lstatSync(dir);
  } catch (err) {
    findings.push(`cannot stat ${dirRel}: ${err.message}`);
    return 0;
  }
  if (dirStat.isSymbolicLink() || !dirStat.isDirectory()) {
    findings.push(`refusing to follow non-directory ${dirRel}`);
    return 0;
  }
  const names = [];
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const abs = join(dir, ent.name);
    let st;
    try {
      st = lstatSync(abs);
    } catch (err) {
      findings.push(`cannot stat ${dirRel}/${ent.name}: ${err.message}`);
      continue;
    }
    if (st.isSymbolicLink()) {
      findings.push(`refusing to follow symlink ${dirRel}/${ent.name}`);
      continue;
    }
    if (!st.isFile()) {
      findings.push(
        `${dirRel}/${ent.name} is not an incident file, INDEX.md, or README.md`
      );
      continue;
    }
    names.push(ent.name);
  }
  const incidentNames = names.filter((name) => INCIDENT_FILE_RE.test(name)).sort();
  const allowed = new Set(["INDEX.md", "README.md", ...incidentNames]);
  for (const name of names) {
    if (!allowed.has(name)) {
      findings.push(`${dirRel}/${name} is not an incident file, INDEX.md, or README.md`);
    }
  }
  const indexAbs = join(dir, "INDEX.md");
  const indexRows = new Map();
  if (incidentNames.length > 0 && !names.includes("INDEX.md")) {
    findings.push(`${dirRel}/INDEX.md is missing; incident files are unmapped`);
  }
  if (names.includes("INDEX.md")) {
    let indexText;
    try {
      indexText = readFileSync(indexAbs, "utf8");
    } catch (err) {
      findings.push(`cannot read ${dirRel}/INDEX.md: ${err.message}`);
      indexText = "";
    }
    for (const hit of privacyFileHits(indexText)) {
      findings.push(
        `${dirRel}/INDEX.md:${hit.line} matches privacy rule ${hit.rule}`
      );
    }
    const seen = new Set();
    for (const line of indexText.split(/\r?\n/)) {
      if (line.trim() === "" || line.startsWith("#")) continue;
      const m = line.match(INDEX_ROW_RE);
      if (!m) {
        findings.push(`${dirRel}/INDEX.md has a non-mapping line`);
        continue;
      }
      if (seen.has(m[1])) findings.push(`duplicate incident ID ${m[1]} in ${dirRel}/INDEX.md`);
      seen.add(m[1]);
      indexRows.set(m[1], m[2]);
    }
  }
  if (names.includes("README.md")) {
    let readme;
    try {
      readme = readFileSync(join(dir, "README.md"), "utf8");
    } catch (err) {
      findings.push(`cannot read ${dirRel}/README.md: ${err.message}`);
      readme = "";
    }
    for (const hit of privacyFileHits(readme)) {
      findings.push(`${dirRel}/README.md:${hit.line} matches privacy rule ${hit.rule}`);
    }
  }
  const fileIds = new Set();
  for (const name of incidentNames) {
    const id = name.slice(0, -3);
    fileIds.add(id);
    const rel = `${dirRel}/${name}`;
    let text;
    try {
      text = readFileSync(join(dir, name), "utf8");
    } catch (err) {
      findings.push(`cannot read ${rel}: ${err.message}`);
      continue;
    }
    if (text.includes("\0")) {
      findings.push(`${rel} contains NUL; refusing to treat it as text`);
      continue;
    }
    for (const hit of privacyFileHits(text)) {
      findings.push(`${rel}:${hit.line} matches privacy rule ${hit.rule}`);
    }
    const headings = [];
    for (const line of text.split(/\r?\n/)) {
      const m = line.match(INCIDENT_HEADING_RE);
      if (m) headings.push(m);
    }
    if (headings.length !== 1) {
      findings.push(`${rel} must contain exactly one '## I-NNN · YYYY-MM-DD · slug' heading`);
      continue;
    }
    if (headings[0][1] !== id) {
      findings.push(`${rel} heading ${headings[0][1]} does not match the file name`);
    }
    const occurred = fieldValue(text, "Occurred");
    const ingested = fieldValue(text, "Ingested");
    const lesson = fieldValue(text, "Lesson");
    const evidence = fieldValue(text, "Evidence");
    const proof = fieldValue(text, "Proof");
    const reverted = fieldValue(text, "Reverted attempt");
    const status = fieldValue(text, "Status");
    if (occurred == null) findings.push(`${id} is missing **Occurred:** (${rel})`);
    else if (!isYmd(occurred)) findings.push(`${id} Occurred is not YYYY-MM-DD (${rel})`);
    else if (occurred !== headings[0][2]) {
      findings.push(`${id} Occurred ${occurred} does not match heading date ${headings[0][2]} (${rel})`);
    }
    if (ingested == null) findings.push(`${id} is missing **Ingested:** (${rel})`);
    else if (!isYmd(ingested)) findings.push(`${id} Ingested is not YYYY-MM-DD (${rel})`);
    if (evidence == null) {
      findings.push(`${id} is missing **Evidence:** (write the word unknown) (${rel})`);
    } else {
      const ev = classifyEvidence(evidence);
      if (ev.state === "invalid") {
        findings.push(`${id} Evidence is not unknown and not a list of public refs (${rel})`);
      }
    }
    const proofClass = classifyProof(proof);
    let proofWord = proofClass.state;
    if (proof == null) {
      findings.push(`${id} is missing **Proof:** (write the word unknown) (${rel})`);
    } else if (proofClass.state === "invalid") {
      findings.push(
        `${id} Proof is not unknown and not '<40-hex> <repo-relative entrypoint> <repo-relative fixture dir>' (${rel})`
      );
    } else if (proofClass.state === "shaped") {
      const entryKind = pathKind(root, proofClass.entry);
      const fixtureKind = pathKind(root, proofClass.fixture);
      if (entryKind === "symlink" || fixtureKind === "symlink") {
        proofWord = "invalid";
        findings.push(`${id} Proof path is a symlink; this lint does not follow it (${rel})`);
      } else if (entryKind !== "file" || fixtureKind !== "dir") {
        proofWord = "invalid";
        findings.push(
          `${id} Proof paths are not an existing file and fixture dir (${rel})`
        );
      } else {
        proofWord = "unverified";
      }
    }
    if (reverted == null) {
      findings.push(`${id} is missing **Reverted attempt:** (write the word unknown) (${rel})`);
    }
    if (status == null) findings.push(`${id} is missing **Status:** (${rel})`);
    if (isFixedStatus(status) && (proof == null || proof === "unknown")) {
      findings.push(
        `${id} status is fixed but Proof is unknown; unknown is not correct (${rel})`
      );
    }
    const lessonIds = lesson == null ? [] : lesson.split(/\s+/).filter((t) => /^L-\d{3}$/.test(t));
    if (lesson == null || lessonIds.length === 0) {
      findings.push(`${id} is unmapped (no **Lesson:** L-NNN) (${rel})`);
    } else if (lesson !== lessonIds[0] || lessonIds.length !== 1) {
      findings.push(`${id} is multiply mapped (${rel})`);
    } else if (!byId.has(lesson)) {
      findings.push(`${id} maps to ${lesson} which is absent from ${LEDGER_REL} (${rel})`);
    }
    const indexed = indexRows.get(id);
    if (names.includes("INDEX.md") && indexed == null) {
      findings.push(`${id} is missing from ${dirRel}/INDEX.md`);
    } else if (indexed != null && lesson != null && indexed !== lesson) {
      findings.push(
        `${id} INDEX.md maps to ${indexed} but **Lesson:** is ${lesson} (${rel})`
      );
    }
    reports.push(
      `${id} lesson=${lesson == null ? "unmapped" : lesson} evidence=${classifyEvidence(evidence).state} proof=${proofWord}`
    );
  }
  for (const [id, lesson] of indexRows) {
    if (!fileIds.has(id)) findings.push(`${dirRel}/INDEX.md maps ${id} but ${dirRel}/${id}.md is absent`);
    if (!byId.has(lesson)) {
      findings.push(`${dirRel}/INDEX.md maps ${id} to ${lesson} which is absent from ${LEDGER_REL}`);
    }
  }
  return incidentNames.length;
}

const rootFlagSet = opt.root != null;
const root = resolveRoot(opt.root);
const ledgerAbs = resolveLedger(root, opt.ledger);
const ledgerRel = relPosix(root, ledgerAbs) || LEDGER_REL;

let ledgerText;
try {
  ledgerText = readFileSync(ledgerAbs, "utf8");
} catch (err) {
  die(`cannot read ledger ${ledgerRel}: ${err.message}`);
}

const parsed = parseLedger(ledgerText);
const entries = parsed.entries;
const findings = [];
const byId = new Map();
if (parsed.unclosedFence) {
  findings.push(`unclosed fenced code block in ${ledgerRel}`);
}

let prevNum = 0;
for (const e of entries) {
  if (byId.has(e.id)) {
    findings.push(`duplicate lesson ID ${e.id} (${ledgerRel}:${e.headingLine})`);
  } else {
    byId.set(e.id, e);
  }
  if (e.num <= prevNum) {
    const prev = entries.find((x) => x.num === prevNum);
    const prevId = prev ? prev.id : `L-${String(prevNum).padStart(3, "0")}`;
    findings.push(
      `lesson IDs are not strictly increasing in file order: ${prevId} followed by ${e.id} (${ledgerRel}:${e.headingLine})`
    );
  }
  prevNum = e.num;
  if (e.status === null) {
    findings.push(`${e.id} is missing **Status:** (${ledgerRel}:${e.headingLine})`);
  }
  if (e.tags === null) {
    findings.push(`${e.id} is missing **Tags:** (${ledgerRel}:${e.headingLine})`);
  }
}

const fileTexts = new Map();
for (const scanRel of SCAN_ROOTS) {
  const abs = join(root, scanRel);
  if (!existsSync(abs)) continue;
  let st;
  try {
    st = lstatSync(abs);
  } catch (err) {
    die(`cannot stat ${scanRel}: ${err.message}`);
  }
  if (st.isSymbolicLink()) {
    die(`refusing to follow symlink: ${scanRel}`);
  }
  if (!st.isDirectory()) continue;
  const files = [];
  try {
    walkFiles(root, scanRel, files);
  } catch (err) {
    die(err.message);
  }
  for (const rel of files) {
    const absFile = join(root, rel);
    let buf;
    try {
      buf = readFileSync(absFile);
    } catch (err) {
      die(`cannot read ${rel}: ${err.message}`);
    }
    if (buf.includes(0)) continue;
    const text = buf.toString("utf8");
    fileTexts.set(rel, text);
  }
}

for (const [rel, text] of fileTexts) {
  for (const hit of collectIds(text)) {
    if (!byId.has(hit.id)) {
      findings.push(
        `cited ${hit.id} is absent from ${LEDGER_REL} (${rel}:${hit.line})`
      );
    }
  }
}

for (const e of entries) {
  if (!isFixedStatus(e.status)) {
    const pinners = [];
    for (const [rel, text] of fileTexts) {
      if (filePinsId(rel, text, e.id)) pinners.push(rel);
    }
    for (const rel of pinners) {
      findings.push(`${e.id} is not fixed but ${rel} pins it`);
    }
  }
  // A `pinned by` claim that names no recognisable scripts/tests/*.test.sh
  // path must not bypass verification (Codex #316 round 3, finding 3).
  if (/pinned by/i.test(e.status || "") && claimedPinPaths(e.status).length === 0) {
    findings.push(`${e.id} status claims 'pinned by' but names no scripts/tests/*.test.sh path`);
  }
  for (const rel of claimedPinPaths(e.status)) {
    const text = fileTexts.get(rel);
    if (text == null) {
      findings.push(
        `${e.id} status claims pinned by ${rel} but that file is absent`
      );
      continue;
    }
    if (!filePinsId(rel, text, e.id)) {
      findings.push(
        `${e.id} status claims pinned by ${rel} but ${rel} does not pin it`
      );
    }
  }
}

const reports = [];
const evidenceStats = collectLessonEvidence(root, entries, findings, reports, ledgerRel);
const incidentCount = collectIncidents(root, byId, findings, reports);

if (opt.offline) {
  console.error(`${PREFIX} --offline: skipping closed-issue check`);
} else {
  const pending = [];
  for (const e of entries) {
    if (!e.status) continue;
    const m = e.status.match(PENDING_ISSUE_RE);
    if (m) pending.push({ id: e.id, issue: m[1], headingLine: e.headingLine });
  }
  if (pending.length > 0) {
    let repo;
    try {
      repo = resolveRepo(opt.repo, {
        cwd: root,
        ignoreAmbientRepo: rootFlagSet,
      });
    } catch (err) {
      die(err.message || String(err));
    }
    const seen = new Map();
    for (const p of pending) {
      let state;
      if (seen.has(p.issue)) {
        state = seen.get(p.issue);
      } else {
        try {
          state = ghIssueState(repo, p.issue);
        } catch (err) {
          die(
            `gh api failed for issue #${p.issue} (${p.id}): ${err.message}`
          );
        }
        seen.set(p.issue, state);
      }
      if (state === "closed") {
        findings.push(
          `${p.id} status is fix-pending (issue #${p.issue}) but issue #${p.issue} is closed (${ledgerRel}:${p.headingLine})`
        );
      }
    }
  }
}

console.log(
  `${PREFIX} evidence-report lessons=${entries.length} proof-unknown=${evidenceStats.proofUnknown} proof-unverified=${evidenceStats.proofUnverified} evidence-unknown=${evidenceStats.evidenceUnknown} incidents=${incidentCount}`
);
for (const line of reports) console.log(`${PREFIX} ${line}`);

if (findings.length > 0) {
  for (const f of findings) console.error(`${PREFIX} ${f}`);
  console.error(`${PREFIX} ${findings.length} finding(s)`);
  process.exit(1);
}

console.log(`${PREFIX} OK`);
process.exit(0);
