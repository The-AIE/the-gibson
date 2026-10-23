#!/usr/bin/env node
/**
 * public-hygiene.mjs — fail when the public tree names something private (#529)
 *
 * WHAT IT DOES
 *   Scans every tracked text file for terms on a deny-list and exits 1 on any
 *   match, printing path:line and the list entry id. The deny-list is stored as
 *   SHA-256 hashes of normalized tokens (config/public-hygiene.v1.json), so the
 *   list does not publish the names it protects, and this script never echoes
 *   the matched text.
 *
 *   Normalization: a line is split into alphanumeric words, lowercased. Every
 *   run of 1 to MAX_WORDS adjacent words, joined, is hashed. So `Foo-Bar`,
 *   `foo_bar`, `FooBar`, and `foo bar` all normalize to the same token and match
 *   one entry. `--digest` rejects terms longer than MAX_WORDS words.
 *
 *   Fail closed: the config file itself is scanned (its free-text fields must not
 *   name a protected term), and a tracked text file too large to scan is a
 *   finding, never a silent skip.
 *
 * WHY
 *   Agents write back into this public repository (lessons, decisions, ADRs,
 *   fixtures). Nothing else stops a lane from writing a private host name,
 *   private repository name or local path into a write-back.
 *
 * RISKS
 *   Hashes of short, guessable names can be brute-forced; this prevents
 *   accidental disclosure, not a determined reverse-engineer. Word-level
 *   matching means a term embedded inside a longer unseparated word is not
 *   caught. Read-only; never mutates the tree.
 *
 * USAGE
 *   node scripts/public-hygiene.mjs [--root PATH] [--config PATH]
 *   node scripts/public-hygiene.mjs --digest "some term"   # print its entry hash
 *   node scripts/public-hygiene.mjs --help
 *
 * EXIT
 *   0 clean   1 findings   2 usage or config error
 */
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

const DEFAULT_CONFIG = "config/public-hygiene.v1.json";
// Oversized tracked text files are not skipped: they fail closed (a term could hide in one).
const MAX_BYTES = Number(process.env.PUBLIC_HYGIENE_MAX_BYTES) || 16 * 1024 * 1024;
// Longest term, in words, the scanner can match. --digest refuses anything longer so a
// stored hash can never be one the scanner is unable to find.
export const MAX_WORDS = 6;
const BINARY_EXT = /\.(png|jpe?g|gif|ico|webp|pdf|woff2?|ttf|otf|zip|gz|mp4|mov)$/i;

function usage() {
  console.log(
    "usage: node scripts/public-hygiene.mjs [--root PATH] [--config PATH] | --digest TERM | --help\n" +
      "Fails (exit 1) when a tracked text file contains a deny-listed term.\n" +
      "Deny-list is hashes only: config/public-hygiene.v1.json."
  );
}

function die(msg) {
  console.error(`public-hygiene: ${msg}`);
  process.exit(2);
}

/** Normalize free text into the same token form the config stores hashes of. */
export function normalizeTerm(text) {
  return (String(text).toLowerCase().match(/[a-z0-9]+/g) || []).join("");
}

export function digest(token) {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

/** Candidate tokens for one line: every run of 1..MAX_WORDS adjacent words, joined. */
export function candidates(line) {
  const words = line.toLowerCase().match(/[a-z0-9]+/g) || [];
  const out = new Set();
  for (let i = 0; i < words.length; i++) {
    let joined = "";
    for (let n = 0; n < MAX_WORDS && i + n < words.length; n++) {
      joined += words[i + n];
      out.add(joined);
    }
  }
  return out;
}

export function loadConfig(path) {
  let cfg;
  try {
    cfg = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    die(`cannot read ${path}: ${e.message}`);
  }
  if (cfg.version !== 1) die(`${path}: version must be 1`);
  if (cfg.algorithm !== "sha256") die(`${path}: algorithm must be sha256`);
  if (!Array.isArray(cfg.denylist) || cfg.denylist.length === 0) die(`${path}: denylist must be a non-empty array`);
  const ids = new Set();
  for (const e of cfg.denylist) {
    if (!e || typeof e.id !== "string" || !/^[0-9a-f]{64}$/.test(e.digest || "")) die(`${path}: bad denylist entry`);
    if (ids.has(e.id)) die(`${path}: duplicate denylist id ${e.id}`);
    ids.add(e.id);
  }
  const allow = cfg.allow || [];
  for (const a of allow) {
    const hasPath = a && typeof a.path === "string" && a.path !== "";
    const hasDigest = a && typeof a.pathDigest === "string" && /^[0-9a-f]{64}$/.test(a.pathDigest);
    if (!a || hasPath === hasDigest || typeof a.reason !== "string" || a.reason.trim() === "") {
      die(`${path}: every allow entry needs exactly one of path or pathDigest, and a non-empty reason`);
    }
  }
  return cfg;
}

export function scan(root, cfg) {
  const byDigest = new Map(cfg.denylist.map((e) => [e.digest, e.id]));
  // An entry names a path in plain text, or by the SHA-256 of the path when the
  // path itself contains a protected term and so must not be spelled in this file.
  const allowed = new Set((cfg.allow || []).filter((a) => a.path).map((a) => a.path));
  const allowedDigests = new Set((cfg.allow || []).filter((a) => a.pathDigest).map((a) => a.pathDigest));
  const files = execFileSync("git", ["-C", root, "ls-files", "-z"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })
    .split("\0")
    .filter(Boolean);
  const findings = [];
  for (const rel of files) {
    if (allowed.has(rel) || allowedDigests.has(digest(rel)) || BINARY_EXT.test(rel)) continue;
    const abs = join(root, rel);
    if (!existsSync(abs)) continue;
    const st = statSync(abs);
    if (!st.isFile()) continue;
    if (st.size > MAX_BYTES) {
      findings.push({ path: rel, line: 0, id: "UNSCANNABLE-too-large" });
      continue;
    }
    const buf = readFileSync(abs);
    if (buf.includes(0)) continue; // binary
    const lines = buf.toString("utf8").split("\n");
    for (let i = 0; i < lines.length; i++) {
      const hit = new Set();
      for (const c of candidates(lines[i])) {
        const id = byDigest.get(digest(c));
        if (id) hit.add(id);
      }
      for (const id of hit) findings.push({ path: rel, line: i + 1, id });
    }
  }
  return findings;
}

function main(argv) {
  let root = process.cwd();
  let configPath = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") return usage();
    if (a === "--digest") {
      if (i + 1 >= argv.length) die("--digest needs a value");
      const words = (String(argv[i + 1]).toLowerCase().match(/[a-z0-9]+/g) || []).length;
      if (words === 0) die("--digest term has no letters or digits");
      if (words > MAX_WORDS) die(`--digest term has ${words} words; the scanner matches at most ${MAX_WORDS}`);
      console.log(digest(normalizeTerm(argv[i + 1])));
      return;
    }
    if (a === "--root") root = resolve(argv[++i] ?? die("--root needs a value"));
    else if (a === "--config") configPath = resolve(argv[++i] ?? die("--config needs a value"));
    else die(`unknown flag: ${a}`);
  }
  const cfgFile = configPath || join(root, DEFAULT_CONFIG);
  const cfg = loadConfig(cfgFile);
  const findings = scan(root, cfg);
  if (findings.length === 0) {
    console.log(`public-hygiene: OK (${cfg.denylist.length} entries, tree clean)`);
    return;
  }
  console.error(`public-hygiene: FAIL — ${findings.length} finding(s); matched text is not printed`);
  for (const f of findings) console.error(`  ${f.path}:${f.line}  [${f.id}]`);
  console.error("Remove the private reference, or move the record to the operator's private repo.");
  if (findings.some((f) => f.id.startsWith("UNSCANNABLE"))) {
    console.error("UNSCANNABLE: a tracked text file exceeds the scan limit; split it, or allow-list it with a reason.");
  }
  process.exit(1);
}

if (import.meta.url === `file://${process.argv[1]}`) main(process.argv.slice(2));
