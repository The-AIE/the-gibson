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
 *
 * WHY
 *   A ledger nobody can trust stops being read, then stops being fed (Law 9).
 *
 * RISKS
 *   Citation scan is a token match, not a parser. gh api is fail-closed
 *   (nonzero on any error) unless --offline. Read-only; never mutates.
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
  / **Tags:**.

WHY
  Status that nobody reads is not a ratchet. The ledger has to be mechanically
  honest or Law 9 produces prose instead of fixes.

RISKS
  Token scan, not a markdown AST. Closed-issue check calls gh api and fails
  closed on any error unless --offline (which skips only that check and says
  so). Read-only.

USAGE
  node scripts/lesson-ledger-lint.mjs
  node scripts/lesson-ledger-lint.mjs --root PATH [--ledger PATH]
  node scripts/lesson-ledger-lint.mjs --offline --repo owner/name
  node scripts/lesson-ledger-lint.mjs --help

EXIT
  0  ledger and citations are consistent
  1  findings, or an error path (missing ledger, gh failure, unreadable file)
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
    if (htmlComment) { if (line.includes("-->")) htmlComment = false; continue; }
    const openIdx = line.indexOf("<!--");
    if (openIdx >= 0 && line.indexOf("-->", openIdx) < 0) { htmlComment = true; continue; }
    if (/^\s*<!--.*-->\s*$/.test(line)) continue;
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
      if (line.includes("-->")) htmlComment = false;
      continue;
    }
    // A comment may open mid-line (`prose <!--`): everything after `<!--`
    // until `-->` is not ledger content (Codex #316 round 4, finding 1).
    const openIdx = line.indexOf("<!--");
    if (openIdx >= 0 && line.indexOf("-->", openIdx) < 0) {
      htmlComment = true;
      if (!/^\s*$/.test(line.slice(0, openIdx)) && HEADING_RE.test(line.slice(0, openIdx))) { /* heading before the comment still counts */ } else { continue; }
    }
    if (/^\s*<!--.*-->\s*$/.test(line)) continue;
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
  if (/^#/.test(trimmed)) return new RegExp(`#\\s*(?:pins?|pin:|regression:)\\s*${escaped}\\b`, "i").test(trimmed);
  if (quotedContainsId(line, id)) return false;
  // A trailing shell comment on a code line (`[[ … ]] # pins L-NNN`) is an
  // explicit marker too (Codex #316 round 4, finding 2); the ID is outside
  // quotes by the check above, so the `#` is a real comment.
  if (new RegExp(`#\\s*(?:pins?|pin:|regression:)\\s*${escaped}\\b`, "i").test(line)) return true;
  if (new RegExp(`\\b(?:pin|regression):\\s*${escaped}\\b`, "i").test(line)) return true;
  return false;
}

function isTestNameLine(line, id) {
  if (isCommentLine(line)) return false;
  if (!line.includes(id)) return false;
  // A quoted grep/needle is not a test name.
  if (/\bgrep\b/.test(line)) return false;
  const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  if (new RegExp(`@(?:test|it)\\s+["'](?:#\\s*)?${escaped}\\b`).test(line)) return true;
  if (!quotedContainsId(line, id)) return false;
  // The ID must LEAD the quoted title (`ok "L-020 releases the lane"`,
  // `echo "# L-020 · …"`, `it("L-020 …")`), so a needle or fixture string that
  // merely mentions the ID (`echo "L-020"` written to a file, an assertion on
  // fixture output) is not a test name (finding 2).
  const leads = new RegExp(`["'](?:#\\s*)?${escaped}(?:\\s|·|:|$)`);
  if (!leads.test(line)) return false;
  if (/^\s*(?:test|it|describe)\s*\(/.test(line)) return true;
  if (/^\s*(ok|bad|expect|check)\b/.test(line)) return true;
  // This repo's case titles: echo "# L-NNN · …" with no pipe or redirect.
  if (/^\s*echo\s+["']/.test(line) && !/[|>]/.test(line)) return true;
  return false;
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

if (findings.length > 0) {
  for (const f of findings) console.error(`${PREFIX} ${f}`);
  console.error(`${PREFIX} ${findings.length} finding(s)`);
  process.exit(1);
}

console.log(`${PREFIX} OK`);
process.exit(0);
