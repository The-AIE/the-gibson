#!/usr/bin/env node
/**
 * eval-trace.mjs — turn cost-ledger iteration rows into Langfuse traces (#583).
 *
 * WHAT IT DOES
 *   Reads rows from a cost ledger (scripts/cost-ledger.sh JSONL), converts each
 *   into a Langfuse `trace-create` event, writes it to a local JSONL sink
 *   (.gibson-evals/traces.jsonl), and ships it to Langfuse over REST when
 *   LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY are set.
 *
 * WHY
 *   A run you cannot see is a run you cannot grade. Traces are the entry point
 *   for datasets, experiments and the CI gate (docs/eval-layer.md).
 *
 * RISKS
 *   Traces can carry prompts. Everything is redacted for key-shaped tokens and
 *   the LANGFUSE_* values before it is written or sent, but redaction is a
 *   backstop, not a license to put secrets in ledger rows. Without keys the
 *   script still exits 0 and says it skipped shipping. A failed upload never
 *   fails the run (the local copy is the record).
 *
 * USAGE
 *   node scripts/eval-trace.mjs --ledger PATH [--all] [--out-dir DIR]
 *   node scripts/eval-trace.mjs --help
 *
 *   --ledger PATH   cost-ledger JSONL (required)
 *   --all           convert every row (default: only the last row)
 *   --out-dir DIR   local sink directory (default .gibson-evals)
 *
 * EXIT
 *   0 converted (shipped or locally recorded)   1 ledger unreadable / no valid rows   2 usage
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseFlags } from "./lib/args.mjs";
import { DEFAULT_OUT_DIR, describeEmit, emit, envelope } from "./lib/eval-core.mjs";

if (process.argv.includes("--help") || process.argv.includes("-h")) {
  const src = readFileSync(new URL(import.meta.url), "utf8");
  const m = src.match(/\/\*\*([\s\S]*?)\*\//);
  console.log((m ? m[1] : "").replace(/^ \* ?/gm, "").trim());
  process.exit(0);
}

const args = parseFlags(process.argv.slice(2), {
  flags: {
    "--ledger": { key: "ledger" },
    "--all": { key: "all", type: "boolean" },
    "--out-dir": { key: "outDir", default: DEFAULT_OUT_DIR },
  },
});

if (!args.ledger) {
  console.error("eval-trace: --ledger PATH is required");
  process.exit(2);
}

/** @param {string} line */
function parseRow(line) {
  try {
    const row = JSON.parse(line);
    return row && typeof row === "object" && typeof row.ts === "string" ? row : null;
  } catch {
    return null;
  }
}

let text;
try {
  text = readFileSync(String(args.ledger), "utf8");
} catch (e) {
  console.error(`eval-trace: cannot read ledger: ${e instanceof Error ? e.message : e}`);
  process.exit(1);
}

const rows = text
  .split("\n")
  .filter((l) => l.trim())
  .map(parseRow)
  .filter(Boolean);

if (rows.length === 0) {
  console.error("eval-trace: no valid ledger rows (each needs a JSON object with a ts field)");
  process.exit(1);
}

const picked = args.all ? rows : rows.slice(-1);

const events = picked.map((row) => {
  const tags = ["gibson", `hat:${row.hat ?? "unknown"}`, `runner:${row.runner ?? "unknown"}`];
  if (row.pool) tags.push(`pool:${row.pool}`);
  return envelope(
    "trace-create",
    {
      id: `gibson-${row.issue ?? "x"}-${row.iteration ?? "x"}-${row.ts}`,
      name: `gibson.${row.hat ?? "iteration"}`,
      timestamp: row.ts,
      tags,
      metadata: {
        issue: row.issue ?? null,
        pr: row.pr ?? null,
        iteration: row.iteration ?? null,
        wall_ms: row.wall_ms ?? null,
        tokens: row.tokens ?? null, // null = unknown, never invented
        flat_rate: row.flat_rate ?? null,
        schema: row.schema ?? null,
      },
    },
    row.ts,
  );
});

const result = await emit(events, { localFile: join(String(args.outDir), "traces.jsonl") });
console.log(`eval-trace: ${events.length} trace(s) from ${args.ledger}`);
console.log(describeEmit(result));
process.exit(0);
