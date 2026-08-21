/**
 * Markdown discovery for contract-authority.mjs.
 *
 * Committed markdown under docs/ and playbooks/ is taken from `git ls-files`
 * (the index / object names, not a live readdir). Replacing or restoring
 * those directories during a filesystem walk cannot omit a committed file
 * from the check set: the git names are unioned in and then read through
 * the fd-bound contained-file primitive.
 *
 * Live extras are still walked. Node has no portable fd-readdir, so
 * opendirSync is a separate pathname open and is NOT claimed to share the
 * opened fd's identity. Observable identity change of the live directory
 * fails closed. A replace-then-restore window can still make the live
 * listing disagree with the opened fd; git ls-files is what prevents a
 * committed file from disappearing from discovery.
 */

import { spawnSync } from "node:child_process";
import {
  closeSync,
  constants as fsConstants,
  existsSync,
  fstatSync,
  lstatSync,
  opendirSync,
  openSync,
  readdirSync,
} from "node:fs";
import { join } from "node:path";
import {
  assertRootIdentity,
  hasDotDotSegment,
  resolveLexicalUnderRoot,
  rootIdentitiesEqual,
} from "../policy-manifest.mjs";

const OPEN_DIR_FLAGS =
  fsConstants.O_RDONLY |
  (fsConstants.O_DIRECTORY || 0) |
  (fsConstants.O_NOFOLLOW || 0);

/**
 * True when an error message indicates genuine path absence (ENOENT),
 * not a permission, type, loop, symlink, or identity-swap failure.
 */
export function isGenuineMissingPath(msg) {
  const s = String(msg || "");
  if (
    /escape|unsafe|absolute|malformed|identity|symlink|realpath|not a regular file|not a directory|EISDIR|ENOTDIR|EACCES|EPERM|ELOOP|swap or race|directory identity/i.test(
      s
    )
  ) {
    return false;
  }
  return /ENOENT|\bno such file\b/i.test(s);
}

/**
 * Test-only hook: runs after open+fstat and **before** pathname opendirSync.
 * Used to exercise the pre-opendir replace window. Production never sets it.
 *
 * @type {null | ((info: {
 *   relDir: string,
 *   absPath: string,
 *   openedDev: bigint,
 *   openedIno: bigint,
 * }) => void)}
 */
let discoverBeforeOpendirHook = null;

/**
 * Test-only hook: runs after pathname opendirSync (not fd-bound listing).
 * Production code never sets it.
 *
 * @type {null | ((info: {
 *   relDir: string,
 *   absPath: string,
 *   openedDev: bigint,
 *   openedIno: bigint,
 * }) => void)}
 */
let discoverAfterOpenHook = null;

/**
 * @param {null | ((info: object) => void)} fn
 */
export function setDiscoverBeforeOpendirHook(fn) {
  discoverBeforeOpendirHook = typeof fn === "function" ? fn : null;
}

/**
 * @param {null | ((info: object) => void)} fn
 */
export function setDiscoverAfterOpenHook(fn) {
  discoverAfterOpenHook = typeof fn === "function" ? fn : null;
}

function identityOf(st) {
  if (!st || typeof st.dev !== "bigint" || typeof st.ino !== "bigint") {
    return null;
  }
  return { dev: st.dev, ino: st.ino };
}

function failPath(rel, detail) {
  const err = new Error(`${rel}: ${detail}`);
  err.code = "E_PATH";
  throw err;
}

/**
 * Open `relDir` under the frozen root, fstat the directory fd, then list
 * via a separate pathname opendirSync. Observable path-identity change
 * fails closed. The Dir handle is not proven to share the fd identity.
 *
 * @param {import("../policy-manifest.mjs").RootIdentity} rootId
 * @param {string} relDir
 * @returns {{ relDir: string, names: Array<{ name: string, isDirectory: boolean, isFile: boolean, isSymbolicLink: boolean }> }}
 */
export function listBoundDirectory(rootId, relDir) {
  assertRootIdentity(rootId);
  let lex;
  try {
    lex = relDir === "" ? { absPath: rootId.path } : resolveLexicalUnderRoot(rootId, relDir);
  } catch (e) {
    failPath(relDir, e && e.message ? e.message : e);
  }

  let lst;
  try {
    lst = lstatSync(lex.absPath, { bigint: true });
  } catch (e) {
    const msg = String(e && e.message ? e.message : e);
    const code = e && e.code ? String(e.code) : "";
    if (code === "ENOENT" || (isGenuineMissingPath(msg) && /ENOENT|no such file/i.test(msg))) {
      const miss = new Error(`${relDir}: ENOENT`);
      miss.code = "ENOENT";
      throw miss;
    }
    failPath(relDir, msg);
  }
  if (lst.isSymbolicLink()) {
    failPath(relDir, "symlink");
  }
  if (!lst.isDirectory()) {
    failPath(relDir, "not a directory");
  }
  const openedId = identityOf(lst);
  if (!openedId) {
    failPath(relDir, "directory identity must use BigInt dev/ino");
  }

  let fd;
  try {
    fd = openSync(lex.absPath, OPEN_DIR_FLAGS);
  } catch (e) {
    failPath(relDir, e && e.message ? e.message : e);
  }
  let dir = null;
  try {
    const opened = fstatSync(fd, { bigint: true });
    const fdId = identityOf(opened);
    if (!fdId || !rootIdentitiesEqual(openedId, fdId)) {
      failPath(relDir, "directory identity changed (swap or race)");
    }
    if (!opened.isDirectory()) {
      failPath(relDir, "not a directory");
    }
    const hookInfo = {
      relDir,
      absPath: lex.absPath,
      openedDev: fdId.dev,
      openedIno: fdId.ino,
    };
    if (typeof discoverBeforeOpendirHook === "function") {
      discoverBeforeOpendirHook(hookInfo);
    }
    try {
      dir = opendirSync(lex.absPath);
    } catch (e) {
      failPath(relDir, e && e.message ? e.message : e);
    }
    if (typeof discoverAfterOpenHook === "function") {
      discoverAfterOpenHook(hookInfo);
    }
  } finally {
    try {
      closeSync(fd);
    } catch {
      /* ignore */
    }
  }

  const names = [];
  try {
    if (!dir) failPath(relDir, "directory handle missing");
    let ent;
    while ((ent = dir.readSync()) !== null) {
      names.push({
        name: ent.name,
        isDirectory: ent.isDirectory(),
        isFile: ent.isFile(),
        isSymbolicLink: ent.isSymbolicLink(),
      });
    }
  } finally {
    if (dir) {
      try {
        dir.closeSync();
      } catch {
        /* ignore */
      }
    }
  }

  let after;
  try {
    after = lstatSync(lex.absPath, { bigint: true });
  } catch (e) {
    failPath(
      relDir,
      `directory identity changed (swap or race): ${e && e.message ? e.message : e}`
    );
  }
  const afterId = identityOf(after);
  if (!after.isDirectory() || !afterId || !rootIdentitiesEqual(openedId, afterId)) {
    failPath(relDir, "directory identity changed (swap or race)");
  }
  assertRootIdentity(rootId);
  return { relDir, names };
}

/**
 * Live `*.md` walk under `relDir`. A genuinely absent top-level directory
 * is treated as empty. Nested absence, permission, type, loop, symlink,
 * and identity-swap failures are E_PATH. Does not enumerate committed
 * names; callers that must not omit committed files should use
 * {@link discoverMdFiles}.
 *
 * @param {import("../policy-manifest.mjs").RootIdentity} rootId
 * @param {string} relDir
 * @param {string[]} acc
 * @param {(code: string, message: string) => void} fail
 * @param {{ optional?: boolean, skipHidden?: boolean }} [opts]
 */
export function walkMdFiles(rootId, relDir, acc, fail, opts = {}) {
  let listing;
  try {
    listing = listBoundDirectory(rootId, relDir);
  } catch (e) {
    const msg = String(e && e.message ? e.message : e);
    if (
      opts.optional &&
      e &&
      e.code === "ENOENT" &&
      isGenuineMissingPath(msg)
    ) {
      return;
    }
    fail("E_PATH", msg);
    return;
  }
  for (const ent of listing.names) {
    if (ent.name === ".git" || ent.name === "node_modules") continue;
    if (opts.skipHidden && ent.name.startsWith(".")) continue;
    if (ent.name === "." || ent.name === ".." || hasDotDotSegment(ent.name)) {
      continue;
    }
    const rel = `${relDir ? `${relDir}/` : ""}${ent.name}`.replace(/\\/g, "/");
    if (hasDotDotSegment(rel)) continue;
    if (ent.isSymbolicLink) {
      fail("E_PATH", `${rel}: symlink`);
      continue;
    }
    if (ent.isDirectory) {
      walkMdFiles(rootId, rel, acc, fail, {
        optional: false,
        skipHidden: opts.skipHidden,
      });
    } else if (ent.isFile && ent.name.endsWith(".md")) {
      acc.push(rel);
    }
  }
}

/**
 * Presence-only path walk used by mutation tests to prove a directory
 * swap would omit files without identity binding. Not used in production.
 */
export function legacyPathWalkMdFiles(absRoot, relDir, acc) {
  const abs = join(absRoot, relDir);
  let ents;
  try {
    ents = readdirSync(abs, { withFileTypes: true });
  } catch {
    return;
  }
  for (const ent of ents) {
    if (ent.name === ".git" || ent.name === "node_modules") continue;
    if (ent.name === "." || ent.name === "..") continue;
    const rel = `${relDir}/${ent.name}`.replace(/\\/g, "/");
    const child = join(absRoot, rel);
    let st;
    try {
      st = lstatSync(child);
    } catch {
      continue;
    }
    if (st.isSymbolicLink()) continue;
    if (st.isDirectory()) legacyPathWalkMdFiles(absRoot, rel, acc);
    else if (st.isFile() && ent.name.endsWith(".md")) acc.push(rel);
  }
}

/**
 * Committed markdown paths under `relDir` from `git ls-files`. Returns
 * null when the root is not a git work tree. Fail-closed (throws E_PATH)
 * when `.git` exists but ls-files fails.
 */
export function listCommittedMdFiles(repoRoot, relDir) {
  const gitDir = join(repoRoot, ".git");
  if (!existsSync(gitDir)) return null;
  const pathspec = relDir || "*.md";
  const r = spawnSync("git", ["-C", repoRoot, "ls-files", "-z", "--", pathspec], {
    encoding: "buffer",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (r.status !== 0) {
    const err = new Error(
      `${relDir}: git ls-files failed: ${String(r.stderr || r.stdout || "unknown")}`
    );
    err.code = "E_PATH";
    throw err;
  }
  const raw = Buffer.isBuffer(r.stdout) ? r.stdout.toString("utf8") : String(r.stdout || "");
  const prefix = relDir ? `${relDir}/` : "";
  const out = [];
  for (const rel of raw.split("\0")) {
    if (!rel || hasDotDotSegment(rel)) continue;
    if ((prefix && !rel.startsWith(prefix)) || !rel.endsWith(".md")) continue;
    if (rel.includes("\\")) continue;
    out.push(rel.replace(/\\/g, "/"));
  }
  return out;
}

/**
 * Union of the live walk and committed `git ls-files` names. A committed
 * docs/playbook markdown path is always in the result set when git is
 * available, even if a live replace/restore hid it from readdir.
 */
export function discoverMdFiles(rootId, relDir, acc, fail, opts = {}) {
  const live = [];
  walkMdFiles(rootId, relDir, live, fail, opts);
  const seen = new Set();
  for (const rel of live) {
    if (seen.has(rel)) continue;
    seen.add(rel);
    acc.push(rel);
  }
  let committed = null;
  try {
    committed = listCommittedMdFiles(rootId.path, relDir);
  } catch (e) {
    fail("E_PATH", String(e && e.message ? e.message : e));
    return;
  }
  if (!committed) return;
  for (const rel of committed) {
    if (seen.has(rel)) continue;
    seen.add(rel);
    acc.push(rel);
  }
}
