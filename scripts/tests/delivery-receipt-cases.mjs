#!/usr/bin/env node
/**
 * Materialize delivery-receipt case bundles.
 * One base bundle plus an RFC 6902 patch list per case. The patches are the
 * diff; project and verify still see the same object each full bundle was.
 *
 *   node scripts/tests/delivery-receipt-cases.mjs
 * Prints the temp directory that holds the materialized bundles.
 */
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "delivery-receipt");

function decode(seg) {
  return seg.replace(/~1/g, "/").replace(/~0/g, "~");
}

export function applyOps(doc, ops) {
  for (const op of ops) {
    if (typeof op.path !== "string" || !op.path.startsWith("/")) {
      throw new Error(`bad patch path ${JSON.stringify(op.path)}`);
    }
    const parts = op.path.split("/").slice(1).map(decode);
    let cur = doc;
    for (let i = 0; i < parts.length - 1; i += 1) {
      const key = Array.isArray(cur) ? Number(parts[i]) : parts[i];
      if (cur == null || cur[key] == null) throw new Error(`missing ${op.path}`);
      cur = cur[key];
    }
    const last = parts[parts.length - 1];
    if (op.op === "remove") {
      if (Array.isArray(cur)) cur.splice(Number(last), 1);
      else delete cur[last];
    } else if (op.op === "add" || op.op === "replace") {
      const value = structuredClone(op.value);
      if (Array.isArray(cur)) {
        const index = last === "-" ? cur.length : Number(last);
        if (op.op === "add") cur.splice(index, 0, value);
        else cur[index] = value;
      } else {
        cur[last] = value;
      }
    } else {
      throw new Error(`bad patch op ${op.op}`);
    }
  }
  return doc;
}

function main() {
  if (process.argv.length > 2) {
    process.stderr.write("usage: node scripts/tests/delivery-receipt-cases.mjs\n");
    process.exit(2);
  }
  const out = mkdtempSync(join(tmpdir(), "gibson-delivery-cases-"));
  const base = JSON.parse(readFileSync(join(FIXTURES, "delivered-tier-c.json"), "utf8"));
  const overlays = JSON.parse(readFileSync(join(FIXTURES, "overlays.json"), "utf8"));
  writeFileSync(join(out, "delivered-tier-c.json"), JSON.stringify(base));
  for (const [name, ops] of Object.entries(overlays)) {
    if (name.startsWith("_")) continue;
    if (!/^[a-z0-9-]+$/.test(name)) {
      process.stderr.write(`overlay name is invalid\n`);
      process.exit(2);
    }
    if (!Array.isArray(ops)) {
      process.stderr.write(`overlay ${name} is not a patch list\n`);
      process.exit(2);
    }
    const doc = structuredClone(base);
    applyOps(doc, ops);
    writeFileSync(join(out, `${name}.json`), JSON.stringify(doc));
  }
  process.stdout.write(`${out}\n`);
}

if (process.argv[1] && process.argv[1].endsWith("delivery-receipt-cases.mjs")) main();
