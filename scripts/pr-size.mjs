#!/usr/bin/env node
// pr-size.mjs — PR-size budget sensor.
//
// WHAT IT DOES
//   Measures a PR's diff (`git diff --numstat -z -M base...head`), classifies each
//   file as product / tests / docs / generated using config/pr-size.v1.json,
//   and fails when the product or total size exceeds the configured budgets.
//   Local --exception or GIBSON_PR_SIZE_EXCEPTION=1 downgrades a breach to a
//   warning for operator-run checks; CI does not wire labels to this override.
//
// WHY / RISKS
//   Law 5 review is only real if a reviewer can read the whole diff (fleet PRs
//   ranged 36..57 000 lines). Classification is by path pattern; totalLines/
//   totalFiles catch bulk hidden in tests or generated files. Imports and
//   vendoring legitimately exceed the budget; record explicit owner review separately.
//
// USAGE
//   node scripts/pr-size.mjs [--base REF] [--head REF] [--exception]
//                            [--config PATH] [--format text|json]
//   node scripts/pr-size.mjs --numstat FILE    # offline: raw `git diff --numstat [-z]` output
//   Env: GIBSON_PR_BASE (default origin/main), GIBSON_PR_SIZE_EXCEPTION=1
//   Under GITHUB_ACTIONS=true the verdict is also a ::notice::/::warning::/
//   ::error:: annotation plus $GITHUB_STEP_SUMMARY, so an exception is never a
//   silent green step.
//
// TRUST
//   CI must run this script and its config from the trusted base ref, not the
//   PR merge ref (else the PR can raise its own budget) — see the pr-size job.
//
// EXIT
//   0 within budget (or explicit local exception)   1 budget exceeded
//   2 usage / config / git error

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_CONFIG_REL = "config/pr-size.v1.json";
const CLASSES = ["generated", "tests", "docs"];
const BUDGET_KEYS = ["productLines", "productFiles", "totalLines", "totalFiles"];
const GIT_TIMEOUT_MS = 30_000;
const GIT_MAX_BUFFER = 32 * 1024 * 1024;

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
  0 within budget (or explicit local exception)   1 budget exceeded   2 usage / config / git`);
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

function malformed(what) {
  const err = new Error(`malformed numstat: ${what}`);
  err.code = "E_MALFORMED";
  return err;
}

const MAX_SAFE_COUNT = Number.MAX_SAFE_INTEGER;

function parseCount(v, label) {
  if (v === "-") return { value: 0, binary: true };
  if (!/^(0|[1-9]\d*)$/.test(v)) throw malformed(`${label} is not a nonnegative integer: ${v}`);
  const n = Number(v);
  if (!Number.isSafeInteger(n) || n > MAX_SAFE_COUNT) throw malformed(`${label} exceeds safe integer range: ${v}`);
  return { value: n, binary: false };
}

function safeAdd(a, b, label) {
  const n = a + b;
  if (!Number.isSafeInteger(n) || n > MAX_SAFE_COUNT) throw malformed(`${label} exceeds safe integer range`);
  return n;
}

function makeRow(a, d, path) {
  if (!path) throw malformed(JSON.stringify([a, d, path]));
  const added = parseCount(a, "added");
  const deleted = parseCount(d, "deleted");
  if (added.binary !== deleted.binary) throw malformed(`binary row must use '-' for both added and deleted: ${JSON.stringify([a, d, path])}`);
  return { added: added.value, deleted: deleted.value, binary: added.binary, path };
}

// Git C-quotes paths with non-ASCII, control, quote or backslash bytes unless
// core.quotePath=false: "docs/caf\303\251.md". Decode to the real UTF-8 path.
export function unquoteGitPath(s) {
  if (!(s.length >= 2 && s.startsWith('"') && s.endsWith('"'))) return s;
  const inner = s.slice(1, -1);
  const bytes = [];
  const esc = { a: 7, b: 8, f: 12, n: 10, r: 13, t: 9, v: 11, '"': 34, "\\": 92 };
  for (let i = 0; i < inner.length; i += 1) {
    const ch = inner[i];
    if (ch !== "\\") {
      bytes.push(...Buffer.from(ch, "utf8"));
      continue;
    }
    const n = inner[i + 1];
    if (/[0-7]/.test(n)) {
      const oct = inner.slice(i + 1, i + 4).match(/^[0-7]{1,3}/)[0];
      bytes.push(parseInt(oct, 8));
      i += oct.length;
    } else if (n in esc) {
      bytes.push(esc[n]);
      i += 1;
    } else throw malformed(`bad escape in quoted path ${s}`);
  }
  return Buffer.from(bytes).toString("utf8");
}

// NUL-delimited (`--numstat -z`): "<a>\t<d>\t<path>\0" per file; a rename is
// "<a>\t<d>\t\0<old>\0<new>\0". Paths are raw (never quoted), so a literal
// " => " or a tab in a filename cannot be mistaken for rename syntax.
export function parseNumstatZ(text) {
  const rows = [];
  const toks = text.split("\0");
  if (toks[toks.length - 1] !== "") throw malformed("-z output not NUL-terminated");
  toks.pop();
  for (let i = 0; i < toks.length; i += 1) {
    const parts = toks[i].split("\t");
    if (parts.length < 3) throw malformed(JSON.stringify(toks[i]));
    const [a, d] = parts;
    let path = parts.slice(2).join("\t");
    if (path === "") {
      if (i + 2 >= toks.length) throw malformed("truncated rename record");
      path = toks[i + 2];
      i += 2;
    }
    rows.push(makeRow(a, d, path));
  }
  return rows;
}

// Newline-delimited (`--numstat` without -z): "<a>\t<d>\t<path>" where binary
// files show "-\t-", unusual paths are C-quoted, and renames show
// "old => new" or "dir/{a => b}/file". Kept for offline fixtures; CI uses -z.
export function parseNumstatText(text) {
  const rows = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    const parts = line.split("\t");
    if (parts.length < 3) throw malformed(JSON.stringify(line));
    const [a, d] = parts;
    let path = parts.slice(2).join("\t");
    if (path.startsWith('"')) path = unquoteGitPath(path);
    else path = path.replace(/\{[^{}]* => ([^{}]*)\}/g, "$1").replace(/^.* => /, "").replace(/\/\//g, "/");
    rows.push(makeRow(a, d, path));
  }
  return rows;
}

export function parseNumstat(text, { requireNul = false } = {}) {
  if (text.includes("\0")) return parseNumstatZ(text);
  if (requireNul && text !== "") throw malformed("live git numstat output was not NUL-delimited");
  return parseNumstatText(text);
}

export function evaluate(rows, cfg, { exception = false, identity = null } = {}) {
  const byClass = { product: { files: 0, lines: 0 }, tests: { files: 0, lines: 0 }, docs: { files: 0, lines: 0 }, generated: { files: 0, lines: 0 } };
  const files = [];
  for (const r of rows) {
    const cls = classify(r.path, cfg.classes);
    const lines = safeAdd(r.added, r.deleted, `line sum for ${r.path}`);
    byClass[cls].files += 1;
    byClass[cls].lines = safeAdd(byClass[cls].lines, lines, `${cls} line total`);
    files.push({ path: r.path, class: cls, lines, binary: r.binary });
  }
  const totalLines = Object.values(byClass).reduce((s, c) => safeAdd(s, c.lines, "totalLines"), 0);
  const totalFiles = Object.values(byClass).reduce((s, c) => safeAdd(s, c.files, "totalFiles"), 0);
  const metrics = { productLines: byClass.product.lines, productFiles: byClass.product.files, totalLines, totalFiles };
  const findings = [];
  for (const k of BUDGET_KEYS) {
    if (metrics[k] > cfg.budgets[k]) findings.push({ budget: k, value: metrics[k], limit: cfg.budgets[k] });
  }
  const breached = findings.length > 0;
  const verdict = breached ? (exception ? "exception" : "exceeded") : "within-budget";
  return {
    ok: !breached || exception,
    verdict,
    breached,
    exception,
    identity,
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
    `pr-size: ${result.verdict}; product ${m.productLines} lines / ${m.productFiles} files (budget ${cfg.budgets.productLines} / ${cfg.budgets.productFiles}); ` +
      `total ${m.totalLines} lines / ${m.totalFiles} files (budget ${cfg.budgets.totalLines} / ${cfg.budgets.totalFiles})`,
  );
  if (result.identity) {
    out.push(`  base ${result.identity.base}`);
    out.push(`  head ${result.identity.head}`);
    out.push(`  merge-base ${result.identity.mergeBase}`);
  }
  for (const c of ["tests", "docs", "generated"]) {
    const v = result.byClass[c];
    if (v.files) out.push(`  ${c.padEnd(9)} ${v.lines} lines / ${v.files} files (not counted as product)`);
  }
  if (result.largest.some((f) => f.binary)) out.push("  note — binary files have no measurable line count; they still count toward file budgets");
  if (result.breached) {
    const head = result.exception ? `  WARN — over budget under explicit local exception '${cfg.exceptionLabel}':` : "  FAIL — over budget:";
    out.push(head);
    for (const f of result.findings) out.push(`    ${f.budget}: ${f.value} > ${f.limit}`);
    out.push("  Largest files:");
    for (const f of result.largest) out.push(`    ${String(f.lines).padStart(6)}  ${f.class.padEnd(9)} ${f.path}`);
    if (!result.exception) {
      out.push(
        `  Split the PR into reviewable units (one concern each). For imports, vendoring, and mechanical
` +
          `  renames, '${cfg.exceptionLabel}' is informational until authenticated owner-exception wiring exists.`,
      );
    }
  } else {
    out.push("  ok — within budget");
  }
  return out.join("\n");
}

function git(args) {
  return execFileSync("git", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: GIT_MAX_BUFFER,
  }).trimEnd();
}

function gitNumstat(base, head) {
  try {
    const baseSha = git(["rev-parse", "--verify", `${base}^{commit}`]);
    const headSha = git(["rev-parse", "--verify", `${head}^{commit}`]);
    const mergeBase = git(["merge-base", baseSha, headSha]);
    const text = execFileSync("git", ["diff", "--numstat", "-z", "-M", `${baseSha}...${headSha}`, "--"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: GIT_MAX_BUFFER,
    });
    return { text, identity: { base: baseSha, head: headSha, mergeBase } };
  } catch (e) {
    const detail = (e.stderr || e.message || "").toString().trim();
    throw new Error(`git diff ${base}...${head} failed: ${detail}`);
  }
}

// GitHub Actions: a green step must not hide an exception. Annotate the run
// and write the full report to the job summary.
function announceGitHub(result, cfg, text) {
  if (process.env.GITHUB_ACTIONS !== "true") return;
  const m = result.metrics;
  const brief = `product ${m.productLines}/${cfg.budgets.productLines} lines, ${m.productFiles}/${cfg.budgets.productFiles} files; total ${m.totalLines}/${cfg.budgets.totalLines} lines`;
  let line;
  if (!result.breached) line = `::notice title=pr-size::within budget (${brief})`;
  else if (result.exception) line = `::warning title=pr-size::OVER BUDGET — passing only under explicit local exception '${cfg.exceptionLabel}' (${brief})`;
  else line = `::error title=pr-size::over budget (${brief})`;
  console.error(line);
  if (process.env.GITHUB_STEP_SUMMARY) {
    const heading = result.breached ? (result.exception ? `### PR size: over budget — \`${cfg.exceptionLabel}\` applied` : "### PR size: over budget") : "### PR size: within budget";
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${heading}\n\n\`\`\`\n${text}\n\`\`\`\n`);
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const here = dirname(fileURLToPath(import.meta.url));
  const cfgPath = args.configPath || resolve(here, "..", DEFAULT_CONFIG_REL);
  let cfg;
  let rows;
  let result;
  try {
    cfg = loadConfig(cfgPath);
    const input = args.numstatFile ? { text: readFileSync(args.numstatFile, "utf8"), identity: null } : gitNumstat(args.base, args.head);
    rows = parseNumstat(input.text, { requireNul: !args.numstatFile });
    result = evaluate(rows, cfg, { exception: args.exception, identity: input.identity });
  } catch (e) {
    console.error(`pr-size: ${e.message}`);
    process.exit(2);
  }
  const text = renderText(result, cfg);
  if (args.format === "json") console.log(JSON.stringify({ ...result, budgets: cfg.budgets }, null, 2));
  else console.log(text);
  announceGitHub(result, cfg, text);
  process.exit(result.ok ? 0 : 1);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
