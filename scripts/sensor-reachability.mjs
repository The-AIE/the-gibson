#!/usr/bin/env node
/**
 * sensor-reachability.mjs — ratchet: every scripts/*.sh and scripts/*.mjs
 * must be REACHABLE from a gate caller, or counted as ORPHAN (#307).
 *
 * WHAT IT DOES
 *   Lists top-level scripts/*.sh and scripts/*.mjs (not lib/, tests/,
 *   prototypes/) and classifies each REACHABLE or ORPHAN. A script is
 *   REACHABLE when a non-comment line in one of these callers names it:
 *     scripts/tests/run-all.sh
 *     .github/workflows/*.yml
 *     ci/*.yml
 *     scripts/loop.sh
 *     scripts/loop-fleet.sh
 *     a fenced bash/sh block in playbooks/*.md
 *   Reachable rows print the invoking file:line. Exits 1 when the ORPHAN
 *   count exceeds config/sensor-reachability-baseline.v1.json. --update-baseline
 *   may only lower that count.
 *
 * WHY
 *   A sensor that exists only as a file (or is covered only by its own
 *   unit test) is documentation. Law 9 and a lesson's `fixed` status were
 *   being satisfied by existence. This check makes "nothing calls me"
 *   visible and ratchets the orphan count downward.
 *
 * RISKS
 *   Grep-class path-token match, not an AST. Comments are skipped with a
 *   naive first-`#` cut; quoted hashes can hide a call (accepted evasion).
 *   Being named from a test file does not count — that is the gap this
 *   sensor exists to show. Read-only unless --update-baseline.
 *
 * USAGE
 *   node scripts/sensor-reachability.mjs
 *   node scripts/sensor-reachability.mjs --root PATH [--baseline PATH]
 *   node scripts/sensor-reachability.mjs --update-baseline
 *   node scripts/sensor-reachability.mjs --help
 *
 * EXIT
 *   0  orphan count <= baseline (or baseline lowered)
 *   1  orphan count exceeds baseline, update would raise, or I/O/parse error
 *   2  usage / unknown flag
 */

import {
  readdirSync,
  readFileSync,
  writeFileSync,
  existsSync,
  statSync,
  realpathSync,
} from "node:fs";
import { join, basename } from "node:path";
import { execFileSync } from "node:child_process";
import { parseFlags } from "./lib/args.mjs";

const SCHEMA = "gibson.sensor-reachability-baseline.v1";
const DEFAULT_BASELINE_REL = "config/sensor-reachability-baseline.v1.json";

function help() {
  console.log(`sensor-reachability.mjs — gate-reachability ratchet for scripts/*.sh and scripts/*.mjs (#307)

WHAT IT DOES
  Classifies every top-level scripts/*.sh and scripts/*.mjs as REACHABLE
  (named from a gate caller) or ORPHAN, prints invoking file:line for
  reachable ones, and fails when the ORPHAN count exceeds the committed
  baseline. --update-baseline may only lower that count.

WHY
  Three Law sensors (contract-met, truthful-status, contract-read-check)
  and several others have tests but no runtime caller. "A sensor exists"
  is not the same as "a gate runs it."

RISKS
  Path-token scan, not a parser. Test-only references do not count.
  --update-baseline rewrites the committed baseline file.

USAGE
  node scripts/sensor-reachability.mjs
  node scripts/sensor-reachability.mjs --root PATH [--baseline PATH]
  node scripts/sensor-reachability.mjs --update-baseline
  node scripts/sensor-reachability.mjs --help

EXIT
  0  orphan count <= baseline   1  over baseline / would raise / error   2  usage
`);
}

function dieUsage(msg) {
  console.error(`sensor-reachability: ${msg}`);
  process.exit(2);
}

function dieFail(msg) {
  console.error(`sensor-reachability: ${msg}`);
  process.exit(1);
}

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
  help();
  process.exit(0);
}

const opt = parseFlags(args, {
  prefix: "sensor-reachability: ",
  flags: {
    "--root": { key: "root", default: null },
    "--baseline": { key: "baseline", default: null },
    "--ratchet-ref": { key: "ratchetRef", default: null },
    "--update-baseline": { key: "updateBaseline", type: "boolean" },
  },
});

function isDir(p) {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

function isFile(p) {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

let root;
try {
  root = realpathSync(opt.root || process.cwd());
} catch {
  dieFail(`--root is not a directory`);
}
if (!isDir(root)) {
  dieFail(`--root is not a directory`);
}

const scriptsDir = join(root, "scripts");
if (!isDir(scriptsDir)) {
  dieFail(`missing scripts/ directory`);
}

function listTopLevelScripts(dir) {
  let ents;
  try {
    ents = readdirSync(dir, { withFileTypes: true });
  } catch (e) {
    dieFail(`cannot read scripts/: ${e.message}`);
  }
  const names = [];
  for (const ent of ents) {
    if (!ent.isFile()) continue;
    const n = ent.name;
    if (n.endsWith(".sh") || n.endsWith(".mjs")) names.push(n);
  }
  names.sort();
  return names;
}

const scriptNames = listTopLevelScripts(scriptsDir);
if (scriptNames.length === 0) {
  dieFail(`no scripts/*.sh or scripts/*.mjs found`);
}

/** Strip a trailing # comment. Full-line comments become empty. Naive first-hash cut. */
function stripHashComment(line) {
  const trimmed = line.replace(/\r$/, "");
  const hash = trimmed.indexOf("#");
  if (hash < 0) return trimmed;
  return trimmed.slice(0, hash);
}

// Words that EXECUTE the path that follows them. A path after anything else
// (`echo`, `--input`, `FOO=`, a heredoc line) is data, not an invocation
// (Codex review of #317, finding 3).
const INTERPRETERS = new Set(["bash", "sh", "node", "source", ".", "exec", "command", "time", "nohup", "env"]);
// Words that make the whole command a non-invocation even if the path is at
// argument position: they read or print the path, they do not run it.
const NON_INVOKING = new Set(["echo", "printf", "cat", "grep", "sed", "awk", "ls", "test", "[", "[[", "rm", "cp", "mv", "chmod", "git", "stat", "wc", "head", "tail", "diff", "find", "touch", "readlink", "realpath"]);

/**
 * True when the stripped line INVOKES relPath: the path (optionally `./`-
 * prefixed) sits at command position (line start, after `;`, `&&`, `||`,
 * `|`, `(`, `$(`, `run:`, `-c`) or directly after an interpreter, and the
 * command word of that segment is not a read/print utility.
 */
function pathTokenPresent(line, relPath) {
  const stripped = stripHashComment(line);
  let from = 0;
  while (from <= stripped.length) {
    const idx = stripped.indexOf(relPath, from);
    if (idx < 0) return false;
    from = idx + 1;
    const after = stripped[idx + relPath.length] || "";
    if (after !== "" && /[A-Za-z0-9_.-]/.test(after)) continue;
    // The token may be the tail of a longer path word: `./scripts/x.sh`,
    // `"$ROOT/scripts/x.sh"`, `${DIR}/scripts/x.sh` (finding 4). Walk back to
    // the start of that word; the token must begin the word or follow a `/`.
    // `<>` admits playbook placeholders such as `<path-to-gibson>/scripts/x.sh`.
    let wordStart = idx;
    while (wordStart > 0 && /[A-Za-z0-9_${}<>./-]/.test(stripped[wordStart - 1])) wordStart -= 1;
    if (wordStart !== idx && stripped[idx - 1] !== "/") continue;
    const prefix = stripped.slice(0, wordStart).replace(/["'\\]+$/, "");
    if (isInvocationPosition(prefix)) return true;
  }
  return false;
}

function isInvocationPosition(prefix) {
  // The segment is everything after the last command separator.
  const seg = prefix.split(/(?:\|\||&&|\|;|[;|(]|\$\(|\brun:\s*)/).pop() ?? "";
  const words = seg.trim().split(/\s+/).filter(Boolean).filter((w) => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(w)); // drop VAR=... prefixes
  if (words.length === 0) return true; // command position
  const last = words[words.length - 1];
  const first = words[0];
  if (NON_INVOKING.has(first)) return false;
  // Installing a script as an executable (loop.sh symlinks the boundary guard
  // in as `git`) wires it into a gate: count it.
  if (first === "ln" || first === "install") return true;
  if (INTERPRETERS.has(last)) return true;
  if (last === "-c" && INTERPRETERS.has(words[words.length - 2] ?? "")) return true;
  // interpreter with flags: `bash -x scripts/x.sh`, `node --enable-source-maps scripts/x.mjs`
  if (INTERPRETERS.has(first) && words.slice(1).every((w) => w.startsWith("-"))) return true;
  return false;
}

function readText(abs) {
  try {
    return readFileSync(abs, "utf8");
  } catch (e) {
    dieFail(`cannot read ${relFromRoot(abs)}: ${e.message}`);
    return "";
  }
}

function relFromRoot(abs) {
  let a = abs;
  let r = root;
  try {
    a = realpathSync(abs);
  } catch {
    /* keep abs */
  }
  r = r.replace(/\\/g, "/");
  a = a.replace(/\\/g, "/");
  const prefix = r.endsWith("/") ? r : `${r}/`;
  if (a.startsWith(prefix)) return a.slice(prefix.length);
  return basename(abs);
}

function listDirFiles(dir, pred) {
  if (!isDir(dir)) return [];
  let ents;
  try {
    ents = readdirSync(dir, { withFileTypes: true });
  } catch (e) {
    dieFail(`cannot read directory: ${e.message}`);
  }
  const out = [];
  for (const ent of ents) {
    if (!ent.isFile()) continue;
    if (pred(ent.name)) out.push(join(dir, ent.name));
  }
  out.sort();
  return out;
}

/**
 * Scan a whole file. Returns 1-indexed line numbers whose non-comment text
 * contains the path token.
 */
function scanFileLines(abs, relPath) {
  const text = readText(abs);
  const lines = text.split("\n");
  const hits = [];
  // Heredoc bodies are data, not commands (Codex #317, finding 3): after a
  // line carrying `<<DELIM` / `<<'DELIM'` / `<<-"DELIM"`, skip until the line
  // that is exactly DELIM (leading tabs allowed for `<<-`).
  let heredoc = null;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "");
    if (heredoc !== null) {
      if (line.replace(/^\t+/, "").trim() === heredoc) heredoc = null;
      continue;
    }
    if (pathTokenPresent(line, relPath)) hits.push(i + 1);
    const hd = stripHashComment(line).match(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/);
    if (hd) heredoc = hd[2];
  }
  return hits;
}

const FENCE_OPEN = /^\s*```(bash|sh)(\s|$)/;
const FENCE_CLOSE = /^\s*```/;

/**
 * Scan only fenced bash/sh blocks in a markdown file.
 */
function scanPlaybookFences(abs, relPath) {
  const text = readText(abs);
  const lines = text.split("\n");
  const hits = [];
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!inFence) {
      if (FENCE_OPEN.test(line)) inFence = true;
      continue;
    }
    if (FENCE_CLOSE.test(line)) {
      inFence = false;
      continue;
    }
    if (pathTokenPresent(line, relPath)) hits.push(i + 1);
  }
  return hits;
}

function callerRel(abs) {
  return relFromRoot(abs);
}

function collectCallers() {
  const callers = [];

  const exact = [
    join(root, "scripts", "tests", "run-all.sh"),
    join(root, "scripts", "loop.sh"),
    join(root, "scripts", "loop-fleet.sh"),
  ];
  for (const p of exact) {
    if (isFile(p)) callers.push({ abs: p, kind: "file" });
  }

  for (const p of listDirFiles(join(root, ".github", "workflows"), (n) => n.endsWith(".yml"))) {
    callers.push({ abs: p, kind: "file" });
  }
  for (const p of listDirFiles(join(root, "ci"), (n) => n.endsWith(".yml"))) {
    callers.push({ abs: p, kind: "file" });
  }
  for (const p of listDirFiles(join(root, "playbooks"), (n) => n.endsWith(".md"))) {
    callers.push({ abs: p, kind: "playbook" });
  }
  return callers;
}

const callers = collectCallers();

function findInvokers(relPath) {
  const inv = [];
  for (const c of callers) {
    const lines =
      c.kind === "playbook" ? scanPlaybookFences(c.abs, relPath) : scanFileLines(c.abs, relPath);
    for (const ln of lines) {
      inv.push(`${callerRel(c.abs)}:${ln}`);
    }
  }
  return inv;
}

const rows = [];
for (const name of scriptNames) {
  const relPath = `scripts/${name}`;
  const invokers = findInvokers(relPath);
  rows.push({
    name,
    relPath,
    reachable: invokers.length > 0,
    invokers,
  });
}

const orphans = rows.filter((r) => !r.reachable);
const reachable = rows.filter((r) => r.reachable);

for (const r of rows) {
  if (r.reachable) {
    for (const inv of r.invokers) {
      console.log(`REACHABLE\t${r.relPath}\t${inv}`);
    }
  } else {
    console.log(`ORPHAN\t${r.relPath}`);
  }
}

const baselineRel = opt.baseline || DEFAULT_BASELINE_REL;
const baselineAbs = join(root, baselineRel);

function loadBaseline(abs, rel) {
  if (!existsSync(abs)) {
    dieFail(`missing baseline ${rel}`);
  }
  let raw;
  try {
    raw = readFileSync(abs, "utf8");
  } catch (e) {
    dieFail(`cannot read baseline ${rel}: ${e.message}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    dieFail(`malformed JSON in baseline ${rel}: ${e.message}`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    dieFail(`baseline ${rel} must be a JSON object`);
  }
  if (parsed.schema !== SCHEMA) {
    dieFail(`baseline ${rel} schema must be ${SCHEMA}`);
  }
  const max = parsed.orphanMax;
  if (typeof max !== "number" || !Number.isInteger(max) || max < 0 || !Number.isFinite(max)) {
    dieFail(`baseline ${rel} orphanMax must be a non-negative integer`);
  }
  if (!Array.isArray(parsed.orphans)) {
    dieFail(`baseline ${rel} orphans must be an array of names`);
  }
  for (const n of parsed.orphans) {
    if (typeof n !== "string" || !n) {
      dieFail(`baseline ${rel} orphans must be non-empty strings`);
    }
  }
  return { orphanMax: max, orphans: parsed.orphans };
}

const baseline = loadBaseline(baselineAbs, baselineRel);
const orphanCount = orphans.length;
const orphanNames = orphans.map((r) => r.name);

// The ratchet is enforced against the COMMITTED baseline on the default
// branch, not only against the working-tree file (Codex review of #317,
// finding 5): a hand-edit raising orphanMax alongside a new orphan would
// otherwise pass. Ref from --ratchet-ref or GIBSON_RATCHET_REF (default
// origin/main). Unresolvable ref → warn, never fail (local checkouts).
function committedOrphanMax() {
  const ref = opt.ratchetRef || process.env.GIBSON_RATCHET_REF || "origin/main";
  let text;
  try {
    text = execFileSync("git", ["-C", root, "show", `${ref}:${baselineRel}`], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return { ref, max: null };
  }
  try {
    const parsed = JSON.parse(text);
    return { ref, max: Number.isInteger(parsed?.orphanMax) ? parsed.orphanMax : null };
  } catch {
    return { ref, max: null };
  }
}
const committed = committedOrphanMax();
if (committed.max === null) {
  console.error(`sensor-reachability: note: no committed baseline at ${committed.ref}; ratchet checked against the working-tree file only`);
} else if (baseline.orphanMax > committed.max) {
  console.error(
    `sensor-reachability: baseline orphanMax ${baseline.orphanMax} is HIGHER than the committed ${committed.max} at ${committed.ref}; the ratchet may only fall`
  );
  process.exit(1);
}

console.log(
  `sensor-reachability: scripts=${rows.length} reachable=${reachable.length} orphan=${orphanCount} baseline=${baseline.orphanMax}`
);

if (opt.updateBaseline) {
  if (orphanCount > baseline.orphanMax) {
    console.error(
      `sensor-reachability: --update-baseline may only lower the baseline (current orphan count ${orphanCount} > baseline ${baseline.orphanMax}); refusing to raise`
    );
    process.exit(1);
  }
  const next = {
    schema: SCHEMA,
    $comment:
      "Ratchet: orphanMax may only fall. A new top-level scripts/*.sh or *.mjs with no caller in scripts/tests/run-all.sh, .github/workflows/*.yml, ci/*.yml, scripts/loop.sh, scripts/loop-fleet.sh, or a fenced bash/sh block in playbooks/*.md is an ORPHAN and fails when count exceeds orphanMax. --update-baseline refuses to raise.",
    orphanMax: orphanCount,
    orphans: orphanNames,
  };
  try {
    writeFileSync(baselineAbs, `${JSON.stringify(next, null, 2)}\n`, "utf8");
  } catch (e) {
    dieFail(`cannot write baseline ${baselineRel}: ${e.message}`);
  }
  if (orphanCount < baseline.orphanMax) {
    console.log(
      `sensor-reachability: baseline lowered ${baseline.orphanMax} -> ${orphanCount} (${baselineRel})`
    );
  } else {
    console.log(`sensor-reachability: baseline unchanged at ${orphanCount} (${baselineRel})`);
  }
  process.exit(0);
}

if (orphanCount > baseline.orphanMax) {
  console.error(
    `sensor-reachability: ORPHAN count ${orphanCount} exceeds baseline ${baseline.orphanMax}`
  );
  process.exit(1);
}

process.exit(0);
