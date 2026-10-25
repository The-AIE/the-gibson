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
 *   Tracked path names are scanned too. A path that contains a protected term is
 *   reported as `<redacted-path sha256:...>` (never by name); use --path-digest to
 *   get the digest an allow entry needs.
 *
 *   What is scanned: the tracked Git blobs (`git ls-files -s` + `git cat-file`),
 *   not the working tree. A symlink is scanned as the target text Git stores, a
 *   dangling or non-regular path is not skipped, and nothing depends on the
 *   checkout. NUL bytes are stripped before scanning, so UTF-16 text is scanned,
 *   and no file is skipped for its extension.
 *
 *   Allow entries: `{path|pathDigest, reason}` skips that file entirely. Add
 *   `ids: ["H04", ...]` to scope the exemption to those deny-list entries only:
 *   the file is still scanned and any other finding in it still fails. Prefer
 *   `ids` whenever the exemption exists for one specific term.
 *
 *   Fail closed: the config file itself is scanned (its free-text fields must not
 *   name a protected term), a blob too large to scan is a finding, and a blob Git
 *   cannot read is a finding. Never a silent skip.
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
 *   node scripts/public-hygiene.mjs --path-digest PATH     # print a path's allow-list digest
 *   node scripts/public-hygiene.mjs --help
 *
 * EXIT
 *   0 clean   1 findings   2 usage or config error
 */
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_CONFIG = "config/public-hygiene.v1.json";
// Oversized tracked text files are not skipped: they fail closed (a term could hide in one).
const MAX_BYTES = Number(process.env.PUBLIC_HYGIENE_MAX_BYTES) || 16 * 1024 * 1024;
// Longest term, in words, the scanner can match. --digest refuses anything longer so a
// stored hash can never be one the scanner is unable to find.
export const MAX_WORDS = 6;

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
  const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  for (const a of allow) {
    if (!a || typeof a !== "object") die(`${path}: every allow entry must be an object`);
    const hasPath = has(a, "path");
    const hasDigest = has(a, "pathDigest");
    if (hasPath === hasDigest) die(`${path}: every allow entry needs exactly one of path or pathDigest`);
    if (hasPath && (typeof a.path !== "string" || a.path === "")) die(`${path}: allow path must be a non-empty string`);
    if (hasDigest && !(typeof a.pathDigest === "string" && /^[0-9a-f]{64}$/.test(a.pathDigest))) {
      die(`${path}: allow pathDigest must be 64 lowercase hex characters`);
    }
    if (typeof a.reason !== "string" || a.reason.trim() === "") die(`${path}: every allow entry needs a non-empty reason`);
    if (has(a, "ids") && !(Array.isArray(a.ids) && a.ids.length > 0 && a.ids.every((x) => typeof x === "string" && ids.has(x)))) {
      die(`${path}: allow ids must be a non-empty array of deny-list entry ids`);
    }
  }
  return cfg;
}

/** Read Git blobs by sha in one process. Returns Map<sha, Buffer>; a missing blob is absent. */
export function readBlobs(root, shas) {
  const map = new Map();
  if (shas.length === 0) return map;
  const out = execFileSync("git", ["-C", root, "cat-file", "--batch"], {
    input: shas.join("\n") + "\n",
    maxBuffer: 1024 * 1024 * 1024,
  });
  let pos = 0;
  for (const sha of shas) {
    const nl = out.indexOf(10, pos);
    if (nl < 0) break;
    const header = out.toString("utf8", pos, nl).split(" ");
    pos = nl + 1;
    if (header[1] === "missing") continue;
    const size = Number(header[2]);
    map.set(sha, out.subarray(pos, pos + size));
    pos += size + 1; // trailing newline after each object
  }
  return map;
}

export function scan(root, cfg) {
  const byDigest = new Map(cfg.denylist.map((e) => [e.digest, e.id]));
  // An entry names a path in plain text, or by the SHA-256 of the path when the
  // path itself contains a protected term and so must not be spelled in this file.
  const allow = cfg.allow || [];
  const whole = (a) => !Object.prototype.hasOwnProperty.call(a, "ids");
  const allowed = new Set(allow.filter((a) => whole(a) && typeof a.path === "string").map((a) => a.path));
  const allowedDigests = new Set(allow.filter((a) => whole(a) && typeof a.pathDigest === "string").map((a) => a.pathDigest));
  // Id-scoped exemptions: the file is still scanned; only these deny-list ids are suppressed in it.
  const scoped = new Map();
  for (const a of allow.filter((x) => !whole(x))) {
    scoped.set(typeof a.path === "string" ? `p:${a.path}` : `d:${a.pathDigest}`, new Set(a.ids));
  }
  // Entry ids whose digest matches any candidate token of `text`.
  const idsIn = (text) => {
    const hit = new Set();
    for (const c of candidates(text)) {
      const id = byDigest.get(digest(c));
      if (id) hit.add(id);
    }
    return hit;
  };
  const listing = execFileSync("git", ["-C", root, "ls-files", "-s", "-z"], { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 })
    .split("\0")
    .filter(Boolean);
  // Each record is "<mode> <blob-sha> <stage>\t<path>".
  const entries = [];
  for (const rec of listing) {
    const tab = rec.indexOf("\t");
    const [mode, sha] = rec.slice(0, tab).split(" ");
    entries.push({ mode, sha, rel: rec.slice(tab + 1) });
  }
  const findings = [];
  const want = entries.filter((e) => e.mode !== "160000" && !(allowed.has(e.rel) || allowedDigests.has(digest(e.rel))));
  const blobs = readBlobs(root, [...new Set(want.map((e) => e.sha))]);
  for (const { sha, rel } of want) {
    // A path that itself contains a protected term is reported by digest, never by name.
    const pathIds = idsIn(rel);
    const shown = pathIds.size > 0 ? `<redacted-path sha256:${digest(rel).slice(0, 12)}>` : rel;
    const exempt = new Set([...(scoped.get(`p:${rel}`) || []), ...(scoped.get(`d:${digest(rel)}`) || [])]);
    // Exempt ids only ever name deny-list entries, so an UNSCANNABLE finding is never suppressed.
    const push = (f) => {
      if (!exempt.has(f.id)) findings.push(f);
    };
    for (const id of pathIds) push({ path: shown, line: 0, id });
    const blob = blobs.get(sha);
    if (!blob) {
      push({ path: shown, line: 0, id: "UNSCANNABLE-unreadable" });
      continue;
    }
    if (blob.length > MAX_BYTES) {
      push({ path: shown, line: 0, id: "UNSCANNABLE-too-large" });
      continue;
    }
    // UTF-16 text has a NUL between letters; stripping NULs makes it scannable.
    const text = (blob.includes(0) ? Buffer.from(blob.filter((b) => b !== 0)) : blob).toString("utf8");
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      for (const id of idsIn(lines[i])) push({ path: shown, line: i + 1, id });
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
    if (a === "--path-digest") {
      if (i + 1 >= argv.length) die("--path-digest needs a value");
      console.log(digest(String(argv[i + 1])));
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

// Compare real paths: a spaced or symlinked checkout path must not make main() silently not run.
function isEntrypoint() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
  } catch {
    return false;
  }
}

if (isEntrypoint()) main(process.argv.slice(2));
