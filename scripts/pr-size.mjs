#!/usr/bin/env node
// pr-size.mjs — PR-size budget sensor.
//
// WHAT IT DOES
//   Measures a PR's diff (`git diff --numstat -M base...head`), classifies each
//   file as product / tests / docs / generated using config/pr-size.v1.json,
//   and fails when the product or total size exceeds the configured budgets.
//   The `size-exception` label (owner sign-off) downgrades a breach to a
//   warning; the sensor still prints the numbers so the exception is visible.
//
// WHY
//   Law 5 review is only real if a reviewer can read the whole diff. Merged
//   PRs across the fleet ranged from 36 to 57 000 changed lines; nothing said
//   so. A budget makes "ship small units" (Mission) a sensor instead of advice.
//
// RISKS
//   Classification is by path pattern; a product file under tests/ is counted
//   as tests. totalLines/totalFiles catch a diff that hides bulk in tests or
//   generated files. Repo imports and vendoring legitimately exceed the budget:
//   that is what the label is for.
//
// USAGE
//   node scripts/pr-size.mjs [--base REF] [--head REF] [--exception]
//                            [--config PATH] [--format text|json]
//   node scripts/pr-size.mjs --numstat FILE    # offline: raw `git diff --numstat` output
//   Env: GIBSON_PR_BASE (default origin/main), GIBSON_PR_SIZE_EXCEPTION=1
//
// EXIT
//   0 within budget (or breach under an exception)   1 budget exceeded
//   2 usage / config / git error

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_CONFIG_REL = "config/pr-size.v1.json";
const CLASSES = ["generated", "tests", "docs"];
const BUDGET_KEYS = ["productLines", "productFiles", "totalLines", "totalFiles"];

function dieUsage(msg) {
  console.error(`pr-size: ${msg}`);
  process.exit(2);
}

function parseArgs(argv) {
  const out = {
    base: process.env.GIBSON_PR_BASE || "origin/main",
    head: "HEAD",
    numstatFile: null,
    configPath: null,
    format: "text",
    exception: process.env.GIBSON_PR_SIZE_EXCEPTION === "1",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "-h" || a === "--help") {
      console.log(`pr-size.mjs — PR-size budget sensor

USAGE
  node scripts/pr-size.mjs [--base REF] [--head REF] [--exception] [--config PATH] [--format text|json]
  node scripts/pr-size.mjs --numstat FILE

EXIT
  0 within budget (or breach under an exception)   1 budget exceeded   2 usage / config / git`);
      process.exit(0);
    } else if (a === "--base") out.base = argv[++i] || dieUsage("--base wants a ref");
    else if (a === "--head") out.head = argv[++i] || dieUsage("--head wants a ref");
    else if (a === "--numstat") out.numstatFile = argv[++i] || dieUsage("--numstat wants a file");
    else if (a === "--config") out.configPath = argv[++i] || dieUsage("--config wants a path");
    else if (a === "--exception") out.exception = true;
    else if (a === "--format") {
      const v = argv[++i];
      if (v !== "json" && v !== "text") dieUsage("--format wants json|text");
      out.format = v;
    } else dieUsage(`unknown flag: ${a}`);
  }
  return out;
}

export function loadConfig(path) {
  let cfg;
  try {
    cfg = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    throw new Error(`cannot read config ${path}: ${e.message}`);
  }
  if (typeof cfg.exceptionLabel !== "string" || !cfg.exceptionLabel) {
    throw new Error("config exceptionLabel must be a non-empty string");
  }
  const budgets = {};
  for (const k of BUDGET_KEYS) {
    const v = cfg.budgets?.[k];
    if (!Number.isInteger(v) || v < 1) throw new Error(`config budgets.${k} must be an integer >= 1; got ${JSON.stringify(v)}`);
    budgets[k] = v;
  }
  const classes = {};
  for (const c of CLASSES) {
    const pats = cfg.classes?.[c];
    if (!Array.isArray(pats) || pats.some((p) => typeof p !== "string" || !p)) {
      throw new Error(`config classes.${c} must be an array of non-empty strings`);
    }
    classes[c] = pats;
  }
  return { exceptionLabel: cfg.exceptionLabel, budgets, classes };
}

// Glob subset: `**` = any path prefix/suffix (including empty), `*` = within a
// segment, `?` = one char. A pattern without `/` matches the basename.
export function globToRegExp(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i += 1) {
    const ch = glob[i];
    if (ch === "*") {
      if (glob[i + 1] === "*") {
        i += 1;
        if (glob[i + 1] === "/") {
          i += 1;
          re += "(?:.*/)?";
        } else re += ".*";
      } else re += "[^/]*";
    } else if (ch === "?") re += "[^/]";
    else re += ch.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
}

export function classify(path, classes) {
  const base = path.slice(path.lastIndexOf("/") + 1);
  for (const c of CLASSES) {
    for (const pat of classes[c]) {
      const target = pat.includes("/") ? path : base;
      if (globToRegExp(pat).test(target)) return c;
    }
  }
  return "product";
}

// `git diff --numstat -M` rows: "<added>\t<deleted>\t<path>" where binary
// files show "-\t-" and renames show "old => new" or "dir/{a => b}/file".
export function parseNumstat(text) {
  const rows = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    const parts = line.split("\t");
    if (parts.length < 3) {
      const err = new Error(`malformed numstat line: ${JSON.stringify(line)}`);
      err.code = "E_MALFORMED";
      throw err;
    }
    const [a, d] = parts;
    let path = parts.slice(2).join("\t");
    path = path.replace(/\{[^{}]* => ([^{}]*)\}/g, "$1").replace(/^.* => /, "").replace(/\/\//g, "/");
    rows.push({
      added: a === "-" ? 0 : Number(a),
      deleted: d === "-" ? 0 : Number(d),
      binary: a === "-",
      path,
    });
  }
  return rows;
}

export function evaluate(rows, cfg, { exception = false } = {}) {
  const byClass = { product: { files: 0, lines: 0 }, tests: { files: 0, lines: 0 }, docs: { files: 0, lines: 0 }, generated: { files: 0, lines: 0 } };
  const files = [];
  for (const r of rows) {
    const cls = classify(r.path, cfg.classes);
    const lines = r.added + r.deleted;
    byClass[cls].files += 1;
    byClass[cls].lines += lines;
    files.push({ path: r.path, class: cls, lines });
  }
  const totalLines = Object.values(byClass).reduce((s, c) => s + c.lines, 0);
  const totalFiles = Object.values(byClass).reduce((s, c) => s + c.files, 0);
  const metrics = { productLines: byClass.product.lines, productFiles: byClass.product.files, totalLines, totalFiles };
  const findings = [];
  for (const k of BUDGET_KEYS) {
    if (metrics[k] > cfg.budgets[k]) findings.push({ budget: k, value: metrics[k], limit: cfg.budgets[k] });
  }
  const breached = findings.length > 0;
  return {
    ok: !breached || exception,
    breached,
    exception,
    metrics,
    byClass,
    findings,
    largest: files.sort((x, y) => y.lines - x.lines).slice(0, 8),
  };
}

export function renderText(result, cfg) {
  const out = [];
  const m = result.metrics;
  out.push(
    `pr-size: product ${m.productLines} lines / ${m.productFiles} files (budget ${cfg.budgets.productLines} / ${cfg.budgets.productFiles}); ` +
      `total ${m.totalLines} lines / ${m.totalFiles} files (budget ${cfg.budgets.totalLines} / ${cfg.budgets.totalFiles})`,
  );
  for (const c of ["tests", "docs", "generated"]) {
    const v = result.byClass[c];
    if (v.files) out.push(`  ${c.padEnd(9)} ${v.lines} lines / ${v.files} files (not counted as product)`);
  }
  if (result.breached) {
    const head = result.exception ? `  WARN — over budget under '${cfg.exceptionLabel}' (owner sign-off):` : "  FAIL — over budget:";
    out.push(head);
    for (const f of result.findings) out.push(`    ${f.budget}: ${f.value} > ${f.limit}`);
    out.push("  Largest files:");
    for (const f of result.largest) out.push(`    ${String(f.lines).padStart(6)}  ${f.class.padEnd(9)} ${f.path}`);
    if (!result.exception) {
      out.push(
        `  Split the PR into reviewable units (one concern each), or — for imports, vendoring, and mechanical\n` +
          `  renames — have the owner add the '${cfg.exceptionLabel}' label. Raising the budget is a ratchet loosening.`,
      );
    }
  } else {
    out.push("  ok — within budget");
  }
  return out.join("\n");
}

function gitNumstat(base, head) {
  try {
    return execFileSync("git", ["diff", "--numstat", "-M", `${base}...${head}`, "--"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    throw new Error(`git diff ${base}...${head} failed: ${(e.stderr || e.message || "").toString().trim()}`);
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const here = dirname(fileURLToPath(import.meta.url));
  const cfgPath = args.configPath || resolve(here, "..", DEFAULT_CONFIG_REL);
  let cfg;
  let rows;
  try {
    cfg = loadConfig(cfgPath);
    rows = parseNumstat(args.numstatFile ? readFileSync(args.numstatFile, "utf8") : gitNumstat(args.base, args.head));
  } catch (e) {
    console.error(`pr-size: ${e.message}`);
    process.exit(2);
  }
  const result = evaluate(rows, cfg, { exception: args.exception });
  if (args.format === "json") console.log(JSON.stringify({ ...result, budgets: cfg.budgets }, null, 2));
  else console.log(renderText(result, cfg));
  process.exit(result.ok ? 0 : 1);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
