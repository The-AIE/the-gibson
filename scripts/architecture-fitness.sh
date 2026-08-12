#!/usr/bin/env bash
# architecture-fitness.sh — deterministic architecture fitness collector (issue #184 / parent #159)
#
# Offline, report-only observability. Emits gibson.architecture-fitness-report.v1.
# Does not invent hard-fail budgets, canonical policy authority, or claim that
# regex/test counts prove correctness. Canonical policy-drift enforcement is
# deferred to #164. Promotion to hard-fail budgets requires a later reviewed
# change after calibration.
#
# Portable on macOS Bash 3.2 and Linux. Requires node and git on PATH.
set -euo pipefail

COLLECTOR_VERSION="1.0.0"
SCHEMA="gibson.architecture-fitness-report.v1"
DEFAULT_BASELINE="config/architecture-fitness-baseline.v1.json"

usage() {
  cat <<'EOF'
architecture-fitness.sh — deterministic architecture fitness collector (report-only)

WHAT IT DOES
  Scans a Git commit tree (or a clean worktree) and emits a byte-stable
  architecture fitness report: file classification counts, safety-critical
  driver size/proxies, shell include edges, policy-identifier diagnostics,
  mutation-receipt category evidence, and a report-only comparison against
  the committed baseline.

  This is observability only. Observed metric regressions exit 0 in this
  first slice. Malformed inputs, unresolved refs, dirty exact-SHA requests,
  incomplete evidence, or collector failure exit nonzero.

WHAT IT DOES NOT DO
  No network, no model calls, no secrets, no absolute user paths in output.
  No hard-fail budgets, no waivers, no claim that counts prove correctness.
  Canonical policy-drift enforcement is deferred to issue #164.

USAGE
  architecture-fitness.sh [--ref REF | --worktree]
                          [--baseline PATH] [--no-baseline]
                          [--format json|human] [--emit-baseline PATH]
                          [--repo PATH]
  architecture-fitness.sh --help

SOURCE SELECTION
  --ref REF       Scan the exact Git commit tree for REF (object database).
                  Dirty worktree does not affect this mode. Unresolved REF
                  fails closed.
  --worktree      Scan the current worktree index-tracked paths from disk.
                  Dirty tree is refused for exact-SHA results (never labels
                  a dirty tree exact-SHA). Default without --ref/--worktree
                  is the HEAD commit tree (exact, object database).

OPTIONS
  --baseline PATH     Baseline JSON to compare (default: config/...).
  --no-baseline       Skip comparison (still emits a full report).
  --format MODE       json (default) or human (concise summary + JSON).
  --emit-baseline PATH
                      Write a baseline artifact (report without comparison)
                      to PATH. Source commit/tree are recorded; collector
                      provenance is recorded separately and truthfully.
  --repo PATH         Repository root (default: current directory).

EXIT
  0  Report produced (including report-only regressions).
  2  Usage / bad flags.
  3  Unresolved ref, dirty exact refusal, malformed baseline/schema,
     incomplete required evidence, or collector failure.

EOF
}

die_usage() { echo "architecture-fitness.sh: $*" >&2; exit 2; }
die_fail()  { echo "architecture-fitness.sh: $*" >&2; exit 3; }
info()      { echo "architecture-fitness.sh: $*" >&2; }

REF=""
WORKTREE=0
BASELINE=""
NO_BASELINE=0
FORMAT="json"
EMIT_BASELINE=""
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --ref)
      [[ $# -ge 2 ]] || die_usage "--ref requires a value"
      REF="$2"
      shift 2
      ;;
    --worktree) WORKTREE=1; shift ;;
    --baseline)
      [[ $# -ge 2 ]] || die_usage "--baseline requires a path"
      BASELINE="$2"
      shift 2
      ;;
    --no-baseline) NO_BASELINE=1; shift ;;
    --format)
      [[ $# -ge 2 ]] || die_usage "--format requires json|human"
      FORMAT="$2"
      shift 2
      ;;
    --emit-baseline)
      [[ $# -ge 2 ]] || die_usage "--emit-baseline requires a path"
      EMIT_BASELINE="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || die_usage "--repo requires a path"
      REPO="$2"
      shift 2
      ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

case "$FORMAT" in
  json|human) ;;
  *) die_usage "--format must be json or human" ;;
esac

if [[ "$WORKTREE" -eq 1 && -n "$REF" ]]; then
  die_usage "--ref and --worktree are mutually exclusive"
fi

command -v git >/dev/null 2>&1 || die_fail "git is required"
command -v node >/dev/null 2>&1 || die_fail "node is required"

SCRIPT_PATH=$(CDPATH='' cd "$(dirname "$0")" && pwd)/$(basename "$0")
if [[ ! -f "$SCRIPT_PATH" ]]; then
  die_fail "cannot resolve collector script path"
fi

if [[ -z "$REPO" ]]; then
  REPO=$(pwd)
fi
# Resolve repo to a real directory without embedding it in report output.
REPO=$(CDPATH='' cd "$REPO" && pwd) || die_fail "cannot enter --repo path"

git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die_fail "not a git repository: (repo path withheld)"

# Collector digest: stable SHA-256 of this script's bytes (provenance, not source).
COLLECTOR_DIGEST=$(
  node -e '
const fs = require("fs");
const crypto = require("crypto");
const p = process.argv[1];
const buf = fs.readFileSync(p);
process.stdout.write(crypto.createHash("sha256").update(buf).digest("hex"));
' "$SCRIPT_PATH"
) || die_fail "failed to digest collector script"

if [[ "$NO_BASELINE" -eq 1 ]]; then
  BASELINE=""
elif [[ -z "$BASELINE" ]]; then
  if [[ -f "$REPO/$DEFAULT_BASELINE" ]]; then
    BASELINE="$REPO/$DEFAULT_BASELINE"
  else
    BASELINE=""
  fi
elif [[ "$BASELINE" != /* ]]; then
  BASELINE="$REPO/$BASELINE"
fi

export AF_REPO="$REPO"
export AF_REF="$REF"
export AF_WORKTREE="$WORKTREE"
export AF_BASELINE="${BASELINE:-}"
export AF_FORMAT="$FORMAT"
export AF_EMIT_BASELINE="${EMIT_BASELINE:-}"
export AF_COLLECTOR_VERSION="$COLLECTOR_VERSION"
export AF_COLLECTOR_DIGEST="$COLLECTOR_DIGEST"
export AF_SCHEMA="$SCHEMA"
export AF_DEFAULT_BASELINE="$DEFAULT_BASELINE"

# Node performs deterministic analysis and emits the report.
# shellcheck disable=SC2090
node <<'NODE'
"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync, spawnSync } = require("child_process");

const SCHEMA = process.env.AF_SCHEMA;
const REPO = process.env.AF_REPO;
const REF_ARG = process.env.AF_REF || "";
const WORKTREE = process.env.AF_WORKTREE === "1";
const BASELINE_PATH = process.env.AF_BASELINE || "";
const FORMAT = process.env.AF_FORMAT || "json";
const EMIT_BASELINE = process.env.AF_EMIT_BASELINE || "";
const COLLECTOR_VERSION = process.env.AF_COLLECTOR_VERSION;
const COLLECTOR_DIGEST = process.env.AF_COLLECTOR_DIGEST;
const DEFAULT_BASELINE = process.env.AF_DEFAULT_BASELINE;

function fail(msg, code) {
  process.stderr.write("architecture-fitness.sh: " + msg + "\n");
  process.exit(code == null ? 3 : code);
}

function git(args, opts) {
  const r = spawnSync("git", args, {
    cwd: REPO,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    env: Object.assign({}, process.env, {
      // Keep git deterministic and offline.
      GIT_TERMINAL_PROMPT: "0",
      LC_ALL: "C",
      LANG: "C",
    }),
    ...(opts || {}),
  });
  if (r.error) fail("git failed to start: " + r.error.message);
  return r;
}

function gitOk(args) {
  const r = git(args);
  if (r.status !== 0) {
    const err = (r.stderr || r.stdout || "").trim().split("\n")[0] || "git error";
    fail("git " + args.join(" ") + " failed: " + err.replace(REPO, "<repo>"));
  }
  return (r.stdout || "").replace(/\n$/, "");
}

function isDirty() {
  const r = git(["status", "--porcelain", "--untracked-files=normal"]);
  if (r.status !== 0) fail("unable to determine worktree cleanliness");
  return (r.stdout || "").trim().length > 0;
}

// ---------------------------------------------------------------------------
// Source resolution
// ---------------------------------------------------------------------------
let sourceMode; // "commit" | "worktree"
let sourceCommit = null;
let sourceTree = null;
let exact = false;
let dirty = false;

if (WORKTREE) {
  sourceMode = "worktree";
  dirty = isDirty();
  const head = git(["rev-parse", "HEAD"]);
  if (head.status !== 0) fail("unresolved HEAD for worktree scan");
  sourceCommit = head.stdout.trim();
  const treeR = git(["rev-parse", "HEAD^{tree}"]);
  if (treeR.status !== 0) fail("unable to resolve HEAD tree");
  sourceTree = treeR.stdout.trim();
  if (dirty) {
    // Never label a dirty tree exact-SHA.
    exact = false;
    fail(
      "refusing exact-SHA result for dirty worktree " +
        "(comparison/capture must not claim a dirty tree is exact-SHA; " +
        "commit changes or use --ref <commit>)"
    );
  }
  exact = true;
} else {
  sourceMode = "commit";
  const ref = REF_ARG || "HEAD";
  const r = git(["rev-parse", "--verify", ref + "^{commit}"]);
  if (r.status !== 0) {
    fail("unresolved ref: " + ref + " (fail closed; no report)");
  }
  sourceCommit = r.stdout.trim();
  // Full 40-char form
  sourceCommit = gitOk(["rev-parse", sourceCommit]);
  const treeR = git(["rev-parse", sourceCommit + "^{tree}"]);
  if (treeR.status !== 0) fail("unable to resolve tree for " + sourceCommit);
  sourceTree = treeR.stdout.trim();
  exact = true;
  dirty = false;
}

// ---------------------------------------------------------------------------
// Load tracked paths + contents (never follow symlinks; stay in git tree)
// ---------------------------------------------------------------------------
function listCommitFiles(treeOid) {
  const out = gitOk(["ls-tree", "-r", "--name-only", "-z", treeOid]);
  if (!out) return [];
  return out.split("\0").filter(Boolean).sort();
}

function listWorktreeFiles() {
  // Tracked files only; do not invent untracked as architecture.
  const out = gitOk(["ls-files", "-z", "-c", "--"]);
  if (!out) return [];
  return out.split("\0").filter(Boolean).sort();
}

function readWorktreeFile(filePath) {
  const abs = path.join(REPO, filePath);
  let st;
  try {
    st = fs.lstatSync(abs);
  } catch (e) {
    return null;
  }
  if (st.isSymbolicLink()) {
    // Do not follow symlinks.
    return { binary: true, text: "", symlink: true };
  }
  if (!st.isFile()) return { binary: true, text: "" };
  const buf = fs.readFileSync(abs);
  if (buf.indexOf(0) !== -1) return { binary: true, text: "" };
  return { binary: false, text: buf.toString("utf8") };
}

// Batch-load all commit blobs via git cat-file --batch (deterministic, offline).
function loadCommitFiles(commit, pathList) {
  const input = pathList.map((p) => commit + ":" + p).join("\n") + "\n";
  const r = spawnSync("git", ["cat-file", "--batch"], {
    cwd: REPO,
    input: input,
    encoding: null, // Buffer — binary-safe batch parse
    maxBuffer: 128 * 1024 * 1024,
    env: Object.assign({}, process.env, {
      GIT_TERMINAL_PROMPT: "0",
      LC_ALL: "C",
      LANG: "C",
    }),
  });
  if (r.error) fail("git cat-file batch failed to start: " + r.error.message);
  if (r.status !== 0) fail("git cat-file batch failed");
  const buf = Buffer.isBuffer(r.stdout) ? r.stdout : Buffer.from(r.stdout || "");
  const out = [];
  let offset = 0;
  for (let i = 0; i < pathList.length; i++) {
    // header line: <sha> <type> <size>\n  OR  <spec> missing\n
    let nl = buf.indexOf(0x0a, offset);
    if (nl < 0) fail("incomplete evidence: truncated cat-file batch header");
    const header = buf.slice(offset, nl).toString("utf8");
    offset = nl + 1;
    if (/\smissing$/.test(header)) {
      fail("incomplete evidence: cannot read " + pathList[i]);
    }
    const parts = header.split(" ");
    if (parts.length < 3) fail("incomplete evidence: bad cat-file header for " + pathList[i]);
    const size = parseInt(parts[2], 10);
    if (!Number.isFinite(size) || size < 0) {
      fail("incomplete evidence: bad blob size for " + pathList[i]);
    }
    if (offset + size > buf.length) fail("incomplete evidence: truncated blob " + pathList[i]);
    const content = buf.slice(offset, offset + size);
    offset += size;
    // batch format: content followed by \n
    if (offset < buf.length && buf[offset] === 0x0a) offset += 1;
    const binary = content.indexOf(0) !== -1;
    out.push({
      path: pathList[i],
      binary: binary,
      text: binary ? "" : content.toString("utf8"),
    });
  }
  return out;
}

const rawPaths = sourceMode === "worktree" ? listWorktreeFiles() : listCommitFiles(sourceTree);
if (rawPaths.length === 0) fail("incomplete evidence: source tree has zero tracked files");

const paths = [];
for (const p of rawPaths) {
  const rel = p.replace(/\\/g, "/").replace(/^\.\//, "");
  if (rel.includes("\0") || rel.split("/").some((c) => c === ".." || c === "")) {
    fail("unsafe path in tree: rejected");
  }
  paths.push(rel);
}

let files;
if (sourceMode === "worktree") {
  files = [];
  for (const rel of paths) {
    const body = readWorktreeFile(rel);
    if (body == null) fail("incomplete evidence: cannot read " + rel);
    files.push({ path: rel, binary: !!body.binary, text: body.binary ? "" : body.text });
  }
} else {
  files = loadCommitFiles(sourceCommit, paths);
}

// ---------------------------------------------------------------------------
// Classification (first match wins; deterministic order)
// ---------------------------------------------------------------------------
const CATEGORIES = [
  "generated",
  "tests",
  "documentation",
  "config_workflows",
  "production",
  "other",
];

function classify(relPath) {
  const p = relPath;
  const base = path.posix.basename(p);
  const lower = p.toLowerCase();

  // generated
  if (
    /(^|\/)dist\//.test(p) ||
    /(^|\/)build\//.test(p) ||
    /(^|\/)coverage\//.test(p) ||
    /\.generated\./.test(base) ||
    base === "package-lock.json" ||
    base === "pnpm-lock.yaml" ||
    base === "yarn.lock" ||
    base.endsWith(".min.js") ||
    base.endsWith(".min.css")
  ) {
    return "generated";
  }

  // tests
  if (
    /(^|\/)tests\//.test(p) ||
    /(^|\/)__tests__\//.test(p) ||
    /(^|\/)fixtures\//.test(p) ||
    /\.test\.(sh|js|mjs|cjs|ts|tsx|jsx)$/.test(base) ||
    /\.spec\.(js|mjs|cjs|ts|tsx|jsx)$/.test(base) ||
    base.endsWith("_test.sh") ||
    base === "run-all.sh" && /(^|\/)tests\//.test(p) ||
    base === "shellcheck-baseline.txt" && /(^|\/)tests\//.test(p)
  ) {
    return "tests";
  }

  // documentation
  if (
    /(^|\/)docs\//.test(p) ||
    /(^|\/)playbooks\//.test(p) ||
    /(^|\/)memory\//.test(p) ||
    base.endsWith(".md") ||
    base === "LICENSE" ||
    base === "CHANGELOG" ||
    base.startsWith("CHANGELOG.")
  ) {
    return "documentation";
  }

  // config / workflows
  if (
    /(^|\/)\.github\//.test(p) ||
    /(^|\/)ci\//.test(p) ||
    /(^|\/)config\//.test(p) ||
    /(^|\/)\.agents\//.test(p) ||
    /(^|\/)adapters\//.test(p) ||
    /(^|\/)templates\//.test(p) ||
    base === "package.json" ||
    base === ".gitignore" ||
    base === ".gitattributes" ||
    base === ".editorconfig" ||
    base === ".shellcheckrc" ||
    base.endsWith(".yml") ||
    base.endsWith(".yaml") ||
    base.endsWith(".json") && !/(^|\/)scripts\//.test(p)
  ) {
    return "config_workflows";
  }

  // production (executable harness / product code)
  if (
    /(^|\/)scripts\//.test(p) ||
    /\.(sh|mjs|js|cjs|ts|tsx|jsx|py|go|rs)$/.test(base)
  ) {
    return "production";
  }

  return "other";
}

function countLines(text) {
  if (!text) return 0;
  // Count newline-separated lines; trailing newline does not add an extra blank
  // beyond POSIX "lines" if file ends with \n — use split keep semantics:
  // non-empty file without trailing newline still counts its last line.
  if (text.length === 0) return 0;
  let n = 0;
  let i = 0;
  while (i < text.length) {
    const j = text.indexOf("\n", i);
    if (j === -1) {
      n += 1;
      break;
    }
    n += 1;
    i = j + 1;
  }
  return n;
}

const classification = {};
for (const c of CATEGORIES) classification[c] = { files: 0, lines: 0 };

const classified = [];
for (const f of files) {
  const cat = classify(f.path);
  const lines = f.binary ? 0 : countLines(f.text);
  classification[cat].files += 1;
  classification[cat].lines += lines;
  classified.push({ path: f.path, category: cat, lines: lines, binary: f.binary });
}

// ---------------------------------------------------------------------------
// Safety-critical drivers (explicit responsibility map)
// ---------------------------------------------------------------------------
// Proxies are DOCUMENTATION COUNTS of control-flow / decision tokens.
// They are NOT semantic cyclomatic complexity and must never be labeled as such.
const DRIVER_MAP = [
  { id: "claim", path: "scripts/claim.sh" },
  { id: "release-claim", path: "scripts/release-claim.sh" },
  { id: "claim-reaper", path: "scripts/claim-reaper.sh" },
  { id: "loop-fleet", path: "scripts/loop-fleet.sh" },
  { id: "loop-handoff", path: "scripts/loop.sh", note: "handoff gate lives in loop.sh" },
  { id: "gate", path: "scripts/gate.sh" },
  { id: "gate-baseline", path: "scripts/gate-baseline.sh" },
  { id: "release-preflight", path: "scripts/release-preflight.sh" },
];

const BRANCH_PROXY_RE =
  /^\s*(if|elif|else|fi|case|esac|while|until|for|done|select)\b/;
// Decision-ish tokens: explicit exits, dies, verdicts, refuse/allow/block.
const DECISION_PROXY_RE =
  /\b(die|die_|exit\s+[0-9]|return\s+[0-9]|REFUSE|APPROVE|BLOCK|ALLOW|HALT|FAIL_CLOSED|fail closed|fail-closed)\b/i;

function proxyCounts(text) {
  let branch = 0;
  let decision = 0;
  const lines = text.split("\n");
  for (const line of lines) {
    // Strip comments for proxy scan of branch keywords at line start.
    const code = line.replace(/(^|[^\\])#.*$/, "$1");
    if (BRANCH_PROXY_RE.test(code)) branch += 1;
    if (DECISION_PROXY_RE.test(code)) decision += 1;
  }
  return { branch_proxy_count: branch, decision_proxy_count: decision };
}

const fileByPath = new Map(files.map((f) => [f.path, f]));
const safetyCriticalDrivers = [];
for (const d of DRIVER_MAP) {
  const f = fileByPath.get(d.path);
  if (!f) {
    safetyCriticalDrivers.push({
      id: d.id,
      path: d.path,
      present: false,
      lines: 0,
      branch_proxy_count: 0,
      decision_proxy_count: 0,
      proxy_label: "documented decision/branch proxies; not semantic complexity",
      note: d.note || null,
    });
    continue;
  }
  const pc = f.binary ? { branch_proxy_count: 0, decision_proxy_count: 0 } : proxyCounts(f.text);
  safetyCriticalDrivers.push({
    id: d.id,
    path: d.path,
    present: true,
    lines: f.binary ? 0 : countLines(f.text),
    branch_proxy_count: pc.branch_proxy_count,
    decision_proxy_count: pc.decision_proxy_count,
    proxy_label: "documented decision/branch proxies; not semantic complexity",
    note: d.note || null,
  });
}

// ---------------------------------------------------------------------------
// Shell source/include dependency edges (static only)
// ---------------------------------------------------------------------------
const SOURCE_LINE_RE = /^\s*(?:\.|source)\s+(.*)$/;

function parseSourceTarget(raw) {
  let s = raw.trim();
  // Drop trailing operators/comments roughly.
  s = s.replace(/\s*(?:\|\||&&|;|\)).*$/, "").trim();
  s = s.replace(/\s+#.*$/, "").trim();
  // Strip surrounding quotes.
  if (
    (s.startsWith('"') && s.endsWith('"')) ||
    (s.startsWith("'") && s.endsWith("'"))
  ) {
    s = s.slice(1, -1);
  }
  return s;
}

function isDynamic(target) {
  // Command substitution, process substitution, or expansions other than a
  // complete path under one of the three documented static roots.
  if (!target) return true;
  if (/[`]/.test(target)) return true;
  if (/\$\(/.test(target)) return true;
  if (target.includes("$")) {
    const knownStaticRoot = new RegExp(
      "^\\$(?:\\{(?:SCRIPT_DIR|RELEASE_LIB_DIR|GIBSON)\\}|" +
        "(?:SCRIPT_DIR|RELEASE_LIB_DIR|GIBSON))(?:/[A-Za-z0-9_.-]+)+$"
    );
    if (!knownStaticRoot.test(target)) return true;
  }
  return false;
}

function resolveStatic(fromPath, target) {
  // Map known roots relative to scripts/
  let t = target;
  const fromDir = path.posix.dirname(fromPath);
  t = t.replace(/^\$\{SCRIPT_DIR\}\//, fromDir + "/");
  t = t.replace(/^\$SCRIPT_DIR\//, fromDir + "/");
  t = t.replace(/^\$\{RELEASE_LIB_DIR\}\//, "scripts/lib/");
  t = t.replace(/^\$RELEASE_LIB_DIR\//, "scripts/lib/");
  t = t.replace(/^\$\{GIBSON\}\//, "");
  t = t.replace(/^\$GIBSON\//, "");
  // Relative to the including file's directory
  if (!t.startsWith("scripts/") && !t.includes("/")) {
    const dir = path.posix.dirname(fromPath);
    t = path.posix.normalize(dir + "/" + t);
  } else if (t.startsWith("./") || t.startsWith("../")) {
    const dir = path.posix.dirname(fromPath);
    t = path.posix.normalize(dir + "/" + t);
  }
  t = t.replace(/\\/g, "/");
  if (t.startsWith("/")) return null; // absolute — never invent edges; unknown
  if (t.split("/").includes("..")) return null;
  return t;
}

const depEdges = [];
const depUnknowns = [];
const shellFiles = files.filter(
  (f) =>
    !f.binary &&
    classify(f.path) === "production" &&
    (f.path.endsWith(".sh") || f.path.endsWith(".bash"))
);

for (const f of shellFiles) {
  const lines = f.text.split("\n");
  const heredocs = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (heredocs.length > 0) {
      const current = heredocs[0];
      const candidate = current.stripTabs ? line.replace(/^\t+/, "") : line;
      if (candidate === current.delimiter) heredocs.shift();
      continue;
    }
    if (/^\s*#/.test(line)) continue;
    const m = line.match(SOURCE_LINE_RE);
    const heredocRe = /<<(-)?\s*(?:'([^']+)'|"([^"]+)"|([A-Za-z_][A-Za-z0-9_]*))/g;
    let heredocMatch;
    while ((heredocMatch = heredocRe.exec(line)) !== null) {
      heredocs.push({
        stripTabs: !!heredocMatch[1],
        delimiter: heredocMatch[2] || heredocMatch[3] || heredocMatch[4],
      });
    }
    if (!m) continue;
    const raw = parseSourceTarget(m[1]);
    const loc = f.path + ":" + (i + 1);
    if (isDynamic(raw)) {
      depUnknowns.push({
        from: f.path,
        line: i + 1,
        raw: raw,
        reason: "dynamic_or_unresolved_include",
        location: loc,
      });
      continue;
    }
    const resolved = resolveStatic(f.path, raw);
    if (!resolved) {
      depUnknowns.push({
        from: f.path,
        line: i + 1,
        raw: raw,
        reason: "unresolved_static_target",
        location: loc,
      });
      continue;
    }
    if (!fileByPath.has(resolved)) {
      depUnknowns.push({
        from: f.path,
        line: i + 1,
        raw: raw,
        reason: "missing_static_target",
        location: loc,
      });
      continue;
    }
    depEdges.push({
      from: f.path,
      to: resolved,
      kind: "static_source",
      line: i + 1,
      location: loc,
    });
  }
}

// Deterministic sort
depEdges.sort((a, b) => {
  if (a.from !== b.from) return a.from < b.from ? -1 : 1;
  if (a.line !== b.line) return a.line - b.line;
  return a.to < b.to ? -1 : a.to > b.to ? 1 : 0;
});
depUnknowns.sort((a, b) => {
  if (a.from !== b.from) return a.from < b.from ? -1 : 1;
  return a.line - b.line;
});

// ---------------------------------------------------------------------------
// Policy / law / gate identifier diagnostics (NOT enforcement — see #164)
// ---------------------------------------------------------------------------
const ID_PATTERNS = [
  { kind: "human_gate", re: /\bG([1-9]|1[0-6])\b/g },
  { kind: "law", re: /\bLaw\s+([1-9]|10)\b/g },
  { kind: "lesson", re: /\bL-(\d{3})\b/g },
  { kind: "risk_tier", re: /\btier-([abc])\b/gi },
];

const idOccurrences = new Map(); // id -> [{path, line, kind}]

for (const f of files) {
  if (f.binary) continue;
  // Skip binary-ish and lockfiles already handled; scan text.
  const lines = f.text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    for (const pat of ID_PATTERNS) {
      pat.re.lastIndex = 0;
      let m;
      while ((m = pat.re.exec(line)) !== null) {
        let id;
        if (pat.kind === "human_gate") id = "G" + m[1];
        else if (pat.kind === "law") id = "Law-" + m[1];
        else if (pat.kind === "lesson") id = "L-" + m[1];
        else if (pat.kind === "risk_tier") id = "tier-" + m[1].toLowerCase();
        else id = m[0];
        if (!idOccurrences.has(id)) idOccurrences.set(id, []);
        idOccurrences.get(id).push({
          id: id,
          kind: pat.kind,
          path: f.path,
          line: i + 1,
          location: f.path + ":" + (i + 1),
        });
      }
    }
  }
}

const idList = [...idOccurrences.keys()].sort();
const occurrencesSummary = idList.map((id) => {
  const locs = idOccurrences.get(id);
  const paths = [...new Set(locs.map((l) => l.path))].sort();
  // First location per file (stable, compact). Full line dumps are not needed
  // for report-only diagnostics and would bloat the committed baseline.
  const firstPerFile = [];
  const seenPath = new Set();
  for (const l of locs.slice().sort((a, b) => {
    if (a.path !== b.path) return a.path < b.path ? -1 : 1;
    return a.line - b.line;
  })) {
    if (seenPath.has(l.path)) continue;
    seenPath.add(l.path);
    firstPerFile.push(l.location);
  }
  return {
    id: id,
    kind: locs[0].kind,
    count: locs.length,
    files: paths,
    sample_locations: firstPerFile.slice(0, 10),
  };
});

// Duplicates: same id appearing in 2+ distinct files (diagnostic).
const duplicates = occurrencesSummary
  .filter((o) => o.files.length >= 2)
  .map((o) => ({
    id: o.id,
    kind: o.kind,
    file_count: o.files.length,
    files: o.files,
    sample_locations: o.sample_locations,
  }));

// ---------------------------------------------------------------------------
// Mutation-receipt categories (#159) — diagnostic only
// ---------------------------------------------------------------------------
const MUTATION_CATEGORIES = [
  {
    id: "review_bypass",
    label: "review bypass",
    // Explicit tags first; then stable diagnostic phrases.
    patterns: [
      /mutation-category:\s*review_bypass\b/i,
      /mutation receipt:.*review\s+bypass/i,
      /\breview bypass\b/i,
      /pre-handoff.*without.*review/i,
      /missing review.*handoff/i,
      /no review, no handoff/i,
    ],
  },
  {
    id: "stale_head_acceptance",
    label: "stale-head acceptance",
    patterns: [
      /mutation-category:\s*stale_head_acceptance\b/i,
      /mutation receipt:.*stale[- ]head/i,
      /\bstale-head\b/i,
      /\bstale head\b/i,
      /stale-head APPROVE/i,
    ],
  },
  {
    id: "halt_bypass",
    label: "halt bypass",
    patterns: [
      /mutation-category:\s*halt_bypass\b/i,
      /mutation receipt:.*halt\s+bypass/i,
      /\bhalt bypass\b/i,
      /parked.*bypass/i,
      /suppresses?\s+halt/i,
    ],
  },
  {
    id: "corrupt_state_progress",
    label: "corrupt-state progress",
    patterns: [
      /mutation-category:\s*corrupt_state_progress\b/i,
      /mutation receipt:.*corrupt[- ]state/i,
      /\bcorrupt-state\b/i,
      /\bcorrupt state\b/i,
      /state-corrupt/i,
    ],
  },
  {
    id: "claim_ambiguity",
    label: "claim ambiguity",
    patterns: [
      /mutation-category:\s*claim_ambiguity\b/i,
      /mutation receipt:.*claim\s+ambiguity/i,
      /\bclaim ambiguity\b/i,
      /mixed (guard|REFUSE|representation)/i,
      /dual (delete|representation)/i,
    ],
  },
  {
    id: "false_delivery_success",
    label: "false delivery success",
    patterns: [
      /mutation-category:\s*false_delivery_success\b/i,
      /mutation receipt:.*false\s+delivery/i,
      /\bfalse delivery success\b/i,
      /\bsilent[- ]noop\b/i,
      /certifies an L-008/i,
      /swallow(?:ing)?\s+stdout cat greened/i,
      /clock-only .update. never trips/i,
    ],
  },
  {
    id: "incomplete_cleanup",
    label: "incomplete cleanup",
    patterns: [
      /mutation-category:\s*incomplete_cleanup\b/i,
      /mutation receipt:.*incomplete\s+cleanup/i,
      /\bincomplete cleanup\b/i,
      /residual sibling/i,
      /agent-claimed left in place/i,
    ],
  },
];

const mutationCategories = [];
for (const cat of MUTATION_CATEGORIES) {
  const explicitLocations = [];
  const heuristicLocations = [];
  const explicitTag = new RegExp(
    "\\bmutation-category:\\s*" + cat.id + "\\b",
    "i"
  );
  for (const f of files) {
    // Coverage evidence must come from tests. Prose, production diagnostics,
    // and this collector's own fixtures/pattern definitions cannot prove a receipt.
    if (
      f.binary ||
      classify(f.path) !== "tests" ||
      f.path === "scripts/tests/architecture-fitness.test.sh"
    ) continue;
    const lines = f.text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      if (explicitTag.test(lines[i])) {
        explicitLocations.push({
          path: f.path,
          line: i + 1,
          location: f.path + ":" + (i + 1),
        });
        continue;
      }
      for (const re of cat.patterns) {
        re.lastIndex = 0;
        if (re.test(lines[i])) {
          heuristicLocations.push({
            path: f.path,
            line: i + 1,
            location: f.path + ":" + (i + 1),
          });
          break;
        }
      }
    }
  }
  function stableUniqueLocations(locations) {
    locations.sort((a, b) => {
      if (a.path !== b.path) return a.path < b.path ? -1 : 1;
      return a.line - b.line;
    });
    const seen = new Set();
    const uniq = [];
    for (const loc of locations) {
      if (seen.has(loc.location)) continue;
      seen.add(loc.location);
      uniq.push(loc);
    }
    return uniq;
  }
  const explicit = stableUniqueLocations(explicitLocations);
  const heuristic = stableUniqueLocations(heuristicLocations);
  let status = "missing";
  let evidence = "none";
  let selected = [];
  if (explicit.length > 0) {
    status = "present";
    evidence = "explicit_test_tag";
    selected = explicit;
  } else if (heuristic.length > 0) {
    status = "unknown";
    evidence = "heuristic_test_match_only";
    selected = heuristic;
  }
  mutationCategories.push({
    id: cat.id,
    label: cat.label,
    status: status,
    evidence: evidence,
    match_count: selected.length,
    locations: selected.slice(0, 50).map((l) => l.location),
  });
}

// ---------------------------------------------------------------------------
// Build report object
// ---------------------------------------------------------------------------
function stableStringify(obj) {
  return JSON.stringify(obj, null, 2) + "\n";
}

const report = {
  schema: SCHEMA,
  disposition: "report-only",
  comparison_mode: "report-only",
  notes: {
    authority:
      "Observability only. Counts and proxies do not prove correctness. " +
      "Canonical policy-drift enforcement is deferred to issue #164. " +
      "Hard-fail budgets require a later reviewed promotion after calibration.",
    proxies:
      "branch_proxy_count and decision_proxy_count are documented decision/branch " +
      "proxies, not semantic complexity.",
    mutation:
      "Mutation-receipt category counts are diagnostic; test quantity alone is " +
      "insufficient proof of correctness.",
    collector_provenance:
      "Collector version/digest record the tool that produced this report. " +
      "The collector may not have existed at source.commit; provenance is " +
      "independent of the scanned source tree.",
  },
  source: {
    mode: sourceMode,
    commit: sourceCommit,
    tree: sourceTree,
    ref: REF_ARG || (WORKTREE ? "WORKTREE" : "HEAD"),
    exact: exact,
    dirty: dirty,
  },
  collector: {
    version: COLLECTOR_VERSION,
    digest: COLLECTOR_DIGEST,
    schema: SCHEMA,
  },
  classification: classification,
  safety_critical_drivers: safetyCriticalDrivers,
  shell_dependencies: {
    edges: depEdges,
    unknowns: depUnknowns,
    note:
      "Only statically discoverable executable production source/include edges are listed. " +
      "Dynamic or unresolved includes are explicit unknowns; edges are never guessed.",
  },
  policy_identifiers: {
    note:
      "Diagnostics only. Duplicate/occurrence data is not canonical policy authority. " +
      "Canonical drift enforcement is deferred to issue #164.",
    occurrence_count: occurrencesSummary.length,
    occurrences: occurrencesSummary,
    duplicates: duplicates,
  },
  mutation_receipts: {
    note:
      "Seven #159 categories. present requires an explicit mutation-category tag " +
      "in a test other than this collector's fixture sensor; heuristic-only test " +
      "matches are unknown; no test evidence is missing. " +
      "Counts are diagnostic; test quantity is insufficient proof.",
    categories: mutationCategories,
  },
  comparison: null,
};

// ---------------------------------------------------------------------------
// Baseline compare (report-only)
// ---------------------------------------------------------------------------
function loadBaseline(bp) {
  let raw;
  let fd = null;
  try {
    const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0);
    fd = fs.openSync(bp, flags);
    if (!fs.fstatSync(fd).isFile()) fail("unsafe baseline path: regular file required");
    raw = fs.readFileSync(fd, "utf8");
  } catch (e) {
    fail("cannot read baseline: " + e.message.replace(REPO, "<repo>"));
  } finally {
    if (fd !== null) fs.closeSync(fd);
  }
  let obj;
  try {
    obj = JSON.parse(raw);
  } catch (e) {
    fail("malformed baseline JSON: " + e.message);
  }
  if (!obj || typeof obj !== "object") fail("malformed baseline: not an object");
  if (obj.schema !== SCHEMA && obj.schema !== "gibson.architecture-fitness-baseline.v1") {
    fail(
      "malformed baseline schema: expected " +
        SCHEMA +
        " or gibson.architecture-fitness-baseline.v1, got " +
        String(obj.schema)
    );
  }
  function evidenceFail(field) {
    fail("incomplete baseline evidence: " + field);
  }
  function nonNegativeInteger(value) {
    return Number.isSafeInteger(value) && value >= 0;
  }
  function relativeLocation(value) {
    if (typeof value !== "string" || value.startsWith("/") || value.includes("\\")) {
      return false;
    }
    const parts = value.replace(/:\d+$/, "").split("/");
    return /:\d+$/.test(value) && !parts.some((part) => part === ".." || part === "");
  }

  // Required evidence in baseline. Fail closed on plausible-looking but
  // structurally incomplete or impossible values.
  if (
    !obj.source ||
    !/^[0-9a-f]{40}$/.test(String(obj.source.commit || "")) ||
    !/^[0-9a-f]{40}$/.test(String(obj.source.tree || ""))
  ) {
    fail("incomplete baseline evidence: source.commit and source.tree required");
  }
  if (
    !obj.collector ||
    typeof obj.collector.version !== "string" ||
    !/^[0-9a-f]{64}$/.test(String(obj.collector.digest || ""))
  ) {
    evidenceFail("collector version and digest");
  }
  if (!obj.classification || typeof obj.classification !== "object") {
    fail("incomplete baseline evidence: classification required");
  }
  for (const c of CATEGORIES) {
    const metrics = obj.classification[c];
    if (
      !metrics ||
      !nonNegativeInteger(metrics.files) ||
      !nonNegativeInteger(metrics.lines)
    ) {
      evidenceFail("classification." + c + " files/lines");
    }
  }
  if (
    !Array.isArray(obj.safety_critical_drivers) ||
    obj.safety_critical_drivers.length !== DRIVER_MAP.length
  ) {
    evidenceFail("safety_critical_drivers");
  }
  const baselineDrivers = new Map();
  for (const driver of obj.safety_critical_drivers) {
    if (!driver || typeof driver.id !== "string" || baselineDrivers.has(driver.id)) {
      evidenceFail("unique safety_critical_drivers ids");
    }
    baselineDrivers.set(driver.id, driver);
  }
  for (const expected of DRIVER_MAP) {
    const driver = baselineDrivers.get(expected.id);
    if (
      !driver ||
      driver.path !== expected.path ||
      typeof driver.present !== "boolean" ||
      !nonNegativeInteger(driver.lines) ||
      !nonNegativeInteger(driver.branch_proxy_count) ||
      !nonNegativeInteger(driver.decision_proxy_count)
    ) {
      evidenceFail("safety_critical_drivers." + expected.id);
    }
  }
  if (
    !obj.shell_dependencies ||
    !Array.isArray(obj.shell_dependencies.edges) ||
    !Array.isArray(obj.shell_dependencies.unknowns)
  ) {
    evidenceFail("shell_dependencies edges/unknowns");
  }
  if (
    !obj.policy_identifiers ||
    !Array.isArray(obj.policy_identifiers.occurrences) ||
    !Array.isArray(obj.policy_identifiers.duplicates)
  ) {
    evidenceFail("policy_identifiers occurrences/duplicates");
  }
  if (!obj.mutation_receipts || !Array.isArray(obj.mutation_receipts.categories)) {
    evidenceFail("mutation_receipts.categories");
  }
  if (obj.mutation_receipts.categories.length !== MUTATION_CATEGORIES.length) {
    evidenceFail("expected " + MUTATION_CATEGORIES.length + " mutation categories");
  }
  const baselineMutations = new Map();
  for (const mutation of obj.mutation_receipts.categories) {
    if (!mutation || typeof mutation.id !== "string" || baselineMutations.has(mutation.id)) {
      evidenceFail("unique mutation category ids");
    }
    baselineMutations.set(mutation.id, mutation);
  }
  for (const expected of MUTATION_CATEGORIES) {
    const mutation = baselineMutations.get(expected.id);
    if (
      !mutation ||
      !["present", "unknown", "missing"].includes(mutation.status) ||
      !nonNegativeInteger(mutation.match_count) ||
      !Array.isArray(mutation.locations) ||
      !mutation.locations.every(relativeLocation) ||
      (mutation.status === "missing" &&
        (mutation.match_count !== 0 || mutation.locations.length !== 0)) ||
      (mutation.status !== "missing" && mutation.match_count < 1)
    ) {
      evidenceFail("mutation_receipts." + expected.id);
    }
  }
  return obj;
}

function compareReports(current, baseline) {
  const perResponsibility = [];
  const baseDrivers = new Map(
    (baseline.safety_critical_drivers || []).map((d) => [d.id, d])
  );
  for (const d of current.safety_critical_drivers) {
    const b = baseDrivers.get(d.id);
    if (!b) {
      perResponsibility.push({
        id: d.id,
        metric: "lines",
        baseline: null,
        current: d.lines,
        delta: null,
        trend: "unknown",
      });
      continue;
    }
    for (const metric of ["lines", "branch_proxy_count", "decision_proxy_count"]) {
      const bv = b[metric];
      const cv = d[metric];
      let trend;
      if (
        b.present !== true ||
        d.present !== true ||
        typeof bv !== "number" ||
        typeof cv !== "number"
      ) trend = "unknown";
      else if (cv > bv) trend = "increase";
      else if (cv < bv) trend = "decrease";
      else trend = "unchanged";
      perResponsibility.push({
        id: d.id,
        metric: metric,
        baseline: typeof bv === "number" ? bv : null,
        current: typeof cv === "number" ? cv : null,
        delta:
          typeof bv === "number" && typeof cv === "number" ? cv - bv : null,
        trend: trend,
      });
    }
  }

  const perCategory = [];
  for (const c of CATEGORIES) {
    for (const metric of ["files", "lines"]) {
      const bv = baseline.classification[c][metric];
      const cv = current.classification[c][metric];
      let trend;
      if (typeof bv !== "number" || typeof cv !== "number") trend = "unknown";
      else if (cv > bv) trend = "increase";
      else if (cv < bv) trend = "decrease";
      else trend = "unchanged";
      perCategory.push({
        category: c,
        metric: metric,
        baseline: bv,
        current: cv,
        delta: typeof bv === "number" && typeof cv === "number" ? cv - bv : null,
        trend: trend,
      });
    }
  }

  // Mutation category presence changes
  const baseMut = new Map(
    (baseline.mutation_receipts.categories || []).map((c) => [c.id, c])
  );
  const perMutation = [];
  for (const m of current.mutation_receipts.categories) {
    const b = baseMut.get(m.id);
    if (!b) {
      perMutation.push({
        id: m.id,
        baseline_status: null,
        current_status: m.status,
        trend: "unknown",
      });
      continue;
    }
    let trend = "unchanged";
    if (b.status === "unknown" || m.status === "unknown") {
      trend = "unknown";
    } else if (b.status !== m.status) {
      if (b.status === "present" && m.status === "missing") trend = "decrease";
      else if (b.status === "missing" && m.status === "present") trend = "increase";
      else trend = "unknown";
    }
    perMutation.push({
      id: m.id,
      baseline_status: b.status,
      current_status: m.status,
      baseline_match_count: b.match_count,
      current_match_count: m.match_count,
      trend: trend,
    });
  }

  const allTrends = [
    ...perResponsibility.map((x) => x.trend),
    ...perCategory.map((x) => x.trend),
    ...perMutation.map((x) => x.trend),
  ];
  const summary = {
    increases: allTrends.filter((t) => t === "increase").length,
    decreases: allTrends.filter((t) => t === "decrease").length,
    unchanged: allTrends.filter((t) => t === "unchanged").length,
    unknowns: allTrends.filter((t) => t === "unknown").length,
  };

  return {
    mode: "report-only",
    exit_policy:
      "Observed regressions remain exit 0 in this report-only slice. " +
      "Malformed schema/baseline, unsafe input, collector failure, or incomplete " +
      "required evidence exit nonzero.",
    baseline_source: {
      commit: baseline.source.commit,
      tree: baseline.source.tree,
    },
    per_responsibility: perResponsibility,
    per_category: perCategory,
    per_mutation_category: perMutation,
    summary: summary,
  };
}

function displayBaselinePath(bp) {
  const absolute = path.resolve(bp);
  const relative = path.relative(REPO, absolute).replace(/\\/g, "/");
  if (relative && relative !== ".." && !relative.startsWith("../")) return relative;
  return "<external-baseline>";
}

if (BASELINE_PATH) {
  const baseline = loadBaseline(BASELINE_PATH);
  report.baseline = {
    path: displayBaselinePath(BASELINE_PATH),
    source_commit: baseline.source.commit,
    source_tree: baseline.source.tree,
    present: true,
  };
  report.comparison = compareReports(report, baseline);
} else {
  report.baseline = {
    path: null,
    source_commit: null,
    source_tree: null,
    present: false,
  };
  report.comparison = {
    mode: "report-only",
    exit_policy:
      "No baseline loaded; comparison skipped. Report-only disposition still applies.",
    baseline_source: null,
    per_responsibility: [],
    per_category: [],
    per_mutation_category: [],
    summary: { increases: 0, decreases: 0, unchanged: 0, unknowns: 0 },
  };
}

// ---------------------------------------------------------------------------
// Emit baseline artifact (no comparison; truthful provenance)
// ---------------------------------------------------------------------------
if (EMIT_BASELINE) {
  const baselineDoc = {
    schema: "gibson.architecture-fitness-baseline.v1",
    disposition: "report-only-baseline",
    notes: {
      authority: report.notes.authority,
      collector_provenance:
        "This baseline was generated by a collector that may not have existed at " +
        "source.commit. source records the scanned main tree; collector records " +
        "the tool provenance separately and truthfully.",
      proxies: report.notes.proxies,
      mutation: report.notes.mutation,
    },
    source: {
      commit: sourceCommit,
      tree: sourceTree,
      mode: sourceMode,
      exact: exact,
      dirty: dirty,
      ref: REF_ARG || (WORKTREE ? "WORKTREE" : sourceCommit),
    },
    collector: {
      version: COLLECTOR_VERSION,
      digest: COLLECTOR_DIGEST,
      note:
        "Collector did not necessarily exist at source.commit; digest is of the " +
        "collector that produced this baseline artifact.",
    },
    classification: classification,
    safety_critical_drivers: safetyCriticalDrivers,
    shell_dependencies: {
      edges: depEdges,
      unknowns: depUnknowns,
      note: report.shell_dependencies.note,
    },
    policy_identifiers: {
      note: report.policy_identifiers.note,
      occurrence_count: occurrencesSummary.length,
      occurrences: occurrencesSummary,
      duplicates: duplicates,
    },
    mutation_receipts: {
      note: report.mutation_receipts.note,
      categories: mutationCategories,
    },
  };
  const requestedPath = path.isAbsolute(EMIT_BASELINE)
    ? path.resolve(EMIT_BASELINE)
    : path.resolve(REPO, EMIT_BASELINE);
  const requestedParent = path.dirname(requestedPath);
  const baseName = path.basename(requestedPath);
  let parentStat;
  try {
    parentStat = fs.lstatSync(requestedParent);
  } catch (e) {
    fail("unsafe baseline output path: parent directory does not exist");
  }
  if (parentStat.isSymbolicLink() || !parentStat.isDirectory()) {
    fail("unsafe baseline output path: real parent directory required");
  }
  const realParent = fs.realpathSync(requestedParent);
  const outPath = path.join(realParent, baseName);
  try {
    const st = fs.lstatSync(outPath);
    if (st.isSymbolicLink() || !st.isFile()) {
      fail("unsafe baseline output path: regular file or missing target required");
    }
  } catch (e) {
    if (e && e.code !== "ENOENT") throw e;
  }
  let tempDir = null;
  let tmp = null;
  try {
    tempDir = fs.mkdtempSync(path.join(realParent, ".architecture-fitness-"));
    tmp = path.join(tempDir, "baseline.json");
    fs.writeFileSync(tmp, stableStringify(baselineDoc), {
      encoding: "utf8",
      mode: 0o644,
      flag: "wx",
    });
    fs.renameSync(tmp, outPath);
    tmp = null;
  } catch (e) {
    fail("cannot safely write baseline: " + e.message.replace(REPO, "<repo>"));
  } finally {
    if (tmp !== null) {
      try { fs.unlinkSync(tmp); } catch (e) { /* best effort */ }
    }
    if (tempDir !== null) {
      try { fs.rmdirSync(tempDir); } catch (e) { /* best effort */ }
    }
  }
}

// ---------------------------------------------------------------------------
// Absolute path leakage guard on emitted JSON
// ---------------------------------------------------------------------------
const json = stableStringify(report);
// Detect home-like absolute paths or the repo path leaking.
if (json.includes(REPO)) {
  fail("internal error: report contains absolute repo path");
}
if (/\/Users\/|\/home\/|\/private\/var\/folders\/|\/tmp\/gibson-/i.test(json)) {
  fail("internal error: report appears to contain absolute user/temp paths");
}

function humanSummary(rep) {
  const lines = [];
  lines.push("Architecture fitness report (report-only)");
  lines.push("schema: " + rep.schema);
  lines.push(
    "source: commit=" +
      rep.source.commit.slice(0, 12) +
      " tree=" +
      rep.source.tree.slice(0, 12) +
      " exact=" +
      rep.source.exact
  );
  lines.push(
    "collector: v" + rep.collector.version + " digest=" + rep.collector.digest.slice(0, 12)
  );
  if (rep.baseline && rep.baseline.present) {
    lines.push(
      "baseline: commit=" +
        String(rep.baseline.source_commit).slice(0, 12) +
        " tree=" +
        String(rep.baseline.source_tree).slice(0, 12)
    );
  } else {
    lines.push("baseline: (none)");
  }
  lines.push("classification:");
  for (const c of CATEGORIES) {
    const x = rep.classification[c];
    lines.push("  " + c + ": files=" + x.files + " lines=" + x.lines);
  }
  lines.push("safety-critical drivers (proxies, not semantic complexity):");
  for (const d of rep.safety_critical_drivers) {
    lines.push(
      "  " +
        d.id +
        " path=" +
        d.path +
        " lines=" +
        d.lines +
        " branch_proxy=" +
        d.branch_proxy_count +
        " decision_proxy=" +
        d.decision_proxy_count
    );
  }
  lines.push(
    "shell deps: edges=" +
      rep.shell_dependencies.edges.length +
      " unknowns=" +
      rep.shell_dependencies.unknowns.length
  );
  lines.push(
    "policy ids: " +
      rep.policy_identifiers.occurrence_count +
      " distinct, duplicates=" +
      rep.policy_identifiers.duplicates.length +
      " (diagnostic; #164 owns canonical enforcement)"
  );
  lines.push("mutation-receipt categories (diagnostic; quantity ≠ proof):");
  for (const m of rep.mutation_receipts.categories) {
    lines.push("  " + m.id + ": " + m.status + " matches=" + m.match_count);
  }
  if (rep.comparison && rep.comparison.summary) {
    const s = rep.comparison.summary;
    lines.push(
      "comparison (report-only): increases=" +
        s.increases +
        " decreases=" +
        s.decreases +
        " unchanged=" +
        s.unchanged +
        " unknowns=" +
        s.unknowns
    );
  }
  lines.push("disposition: report-only (regressions do not fail this slice)");
  return lines.join("\n") + "\n";
}

if (FORMAT === "human") {
  process.stdout.write(humanSummary(report));
  process.stdout.write("\n--- JSON ---\n");
}
process.stdout.write(json);
process.exit(0);
NODE
