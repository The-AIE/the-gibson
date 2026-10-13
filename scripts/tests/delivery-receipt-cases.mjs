#!/usr/bin/env node
/**
 * Materialize delivery-receipt case bundles.
 * One base bundle plus an RFC 6902 patch list per case. The patches are the
 * diff; project and verify still see the same object each full bundle was.
 *
 *   node scripts/tests/delivery-receipt-cases.mjs
 * Prints the temp directory that holds the materialized bundles.
 * applyOps throws `${caseName}: ${op} ${path}` and this process exits 1
 * when a patch does not apply. A throw aborts the rest of the suite.
 */
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "delivery-receipt");

function decode(seg) {
  return seg.replace(/~1/g, "/").replace(/~0/g, "~");
}

function arrayIndex(token) {
  if (typeof token !== "string" || !/^(0|[1-9][0-9]*)$/.test(token)) return null;
  const n = Number(token);
  return Number.isSafeInteger(n) ? n : null;
}

function container(value) {
  return value != null && typeof value === "object";
}

function failClosed(caseName, op, path) {
  throw new Error(`${caseName}: ${op} ${path}`); // MUTATION_ANCHOR_PATCH_CLOSED
}

export function applyOps(doc, ops, caseName = "") {
  for (const op of ops) {
    const name = typeof op?.op === "string" ? op.op : "";
    const path = typeof op?.path === "string" ? op.path : "";
    if (name !== "add" && name !== "remove" && name !== "replace") {
      failClosed(caseName, name || "?", path || JSON.stringify(op?.path));
      continue;
    }
    if (!path.startsWith("/")) {
      failClosed(caseName, name, path || JSON.stringify(op?.path));
      continue;
    }
    const parts = path.split("/").slice(1).map(decode);
    let cur = doc;
    let live = true;
    for (let i = 0; i < parts.length - 1; i += 1) {
      const token = parts[i];
      let next;
      if (Array.isArray(cur)) {
        const idx = arrayIndex(token);
        if (idx != null && idx < cur.length) next = cur[idx];
      } else if (container(cur) && Object.hasOwn(cur, token)) {
        next = cur[token];
      }
      if (!container(next)) {
        failClosed(caseName, name, path);
        live = false;
        break;
      }
      cur = next;
    }
    if (!live) continue;
    if (!container(cur)) {
      failClosed(caseName, name, path);
      continue;
    }
    const last = parts[parts.length - 1];
    if (name === "remove") {
      if (Array.isArray(cur)) {
        const idx = arrayIndex(last);
        if (idx == null || idx >= cur.length) {
          failClosed(caseName, name, path);
          continue;
        }
        cur.splice(idx, 1);
      } else if (!Object.hasOwn(cur, last)) {
        failClosed(caseName, name, path);
      } else {
        delete cur[last];
      }
    } else if (Array.isArray(cur)) {
      let idx = 0;
      let indexOk = false;
      if (name === "add" && last === "-") {
        idx = cur.length;
        indexOk = true;
      } else {
        const parsed = arrayIndex(last);
        const limit = name === "add" ? cur.length : cur.length - 1;
        if (parsed != null && parsed <= limit) {
          idx = parsed;
          indexOk = true;
        }
      }
      if (!indexOk) {
        failClosed(caseName, name, path);
        continue;
      }
      const value = structuredClone(op.value);
      if (name === "add") cur.splice(idx, 0, value);
      else cur[idx] = value;
    } else if (name === "replace" && !Object.hasOwn(cur, last)) {
      failClosed(caseName, name, path);
    } else {
      cur[last] = structuredClone(op.value);
    }
  }
  return doc;
}

export function materialize(base, overlays) {
  const docs = [];
  for (const [name, ops] of Object.entries(overlays)) {
    if (name.startsWith("_")) continue;
    if (!/^[a-z0-9-]+$/.test(name)) {
      const err = new Error("overlay name is invalid");
      err.status = 2;
      throw err;
    }
    if (!Array.isArray(ops)) {
      const err = new Error(`overlay ${name} is not a patch list`);
      err.status = 2;
      throw err;
    }
    const doc = structuredClone(base);
    applyOps(doc, ops, name);
    docs.push([name, doc]);
  }
  return docs;
}

function main() {
  if (process.argv.length > 2) {
    process.stderr.write("usage: node scripts/tests/delivery-receipt-cases.mjs\n");
    process.exit(2);
  }
  const out = mkdtempSync(join(tmpdir(), "gibson-delivery-cases-"));
  const base = JSON.parse(readFileSync(join(FIXTURES, "delivered-tier-c.json"), "utf8"));
  const overlays = JSON.parse(readFileSync(join(FIXTURES, "overlays.json"), "utf8"));
  let docs;
  try {
    docs = materialize(base, overlays);
  } catch (err) {
    process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(err.status === 2 ? 2 : 1);
  }
  writeFileSync(join(out, "delivered-tier-c.json"), JSON.stringify(base));
  for (const [name, doc] of docs) {
    writeFileSync(join(out, `${name}.json`), JSON.stringify(doc));
  }
  process.stdout.write(`${out}\n`);
}

if (process.argv[1] && process.argv[1].endsWith("delivery-receipt-cases.mjs")) main();
