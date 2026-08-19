#!/usr/bin/env node
/**
 * contract-authority.mjs — #208 authority boundary + mandatory-read budget
 *
 * WHAT IT DOES
 *   Enforces that AGENTS.md is the sole mandatory human-readable contract,
 *   that enumerated gates/roles/tiers/stages/pairs match the policy-manifest
 *   candidate, that the mandatory read chain stays inside a byte budget, and
 *   that previously implied-binding docs/playbooks carry a non-normative
 *   marker. Reports a reproducible UTF-8-bytes/4 token proxy.
 *
 * WHY
 *   Mixed-authority prose made agents ingest ~100KB+ of explanation as if it
 *   were the contract. This sensor keeps the split from regressing.
 *
 * RISKS
 *   Grep/substring checks, not a prose parser. A determined rewriter can
 *   satisfy markers while changing meaning; independent review still applies.
 *   Read-only. Does not activate the report-only policy-manifest.
 *
 * USAGE
 *   node scripts/contract-authority.mjs
 *   node scripts/contract-authority.mjs --measure
 *   node scripts/contract-authority.mjs --repo-root PATH --config PATH
 *   node scripts/contract-authority.mjs --help
 */

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { parseFlags } from "./lib/args.mjs";

const DEFAULT_CONFIG_REL = "config/policy/mandatory-read-chain.v1.json";
const GATE_ID_RE = /\*\*G([1-9]|1[0-6])\*\*/g;

function help() {
  console.log(`contract-authority.mjs — #208 authority boundary + read-chain budget

WHAT IT DOES
  Checks AGENTS.md is the sole mandatory human-readable contract, matches
  policy-manifest enumerations, stays inside the byte budget, and that
  docs/playbooks carry a non-normative marker.

WHY
  Prevents the contract from growing back into a 100KB+ implied read chain.

RISKS
  Marker/substring sensor, not a semantic proof. Read-only.

USAGE
  node scripts/contract-authority.mjs
  node scripts/contract-authority.mjs --measure
  node scripts/contract-authority.mjs --repo-root PATH [--config RELPATH]
  node scripts/contract-authority.mjs --format json|text
  node scripts/contract-authority.mjs --help

EXIT
  0  pass (or --measure succeeded)
  1  check failed
  2  usage / IO
`);
}

const args = process.argv.slice(2);
if (args.includes("-h") || args.includes("--help")) {
  help();
  process.exit(0);
}

const parsed = parseFlags(args, {
  prefix: "contract-authority: ",
  flags: {
    "--repo-root": { key: "repoRoot", default: null },
    "--config": { key: "configRel", default: DEFAULT_CONFIG_REL },
    "--measure": { key: "measureOnly", type: "boolean" },
    "--format": {
      key: "format",
      type: "enum",
      values: ["text", "json"],
      default: "text",
    },
  },
});

function dieUsage(msg) {
  console.error(`contract-authority: ${msg}`);
  process.exit(2);
}

function scriptDir() {
  return dirname(fileURLToPath(import.meta.url));
}

function defaultRepoRoot() {
  return resolve(scriptDir(), "..");
}

function hasDotDotSegment(p) {
  return p.replace(/\\/g, "/").split("/").includes("..");
}

function resolveUnderRoot(root, relPath) {
  if (typeof relPath !== "string" || !relPath) {
    throw new Error("empty path");
  }
  if (isAbsolute(relPath) || relPath.includes("\0") || hasDotDotSegment(relPath)) {
    throw new Error(`unsafe path: ${relPath}`);
  }
  const abs = resolve(root, relPath);
  const rel = relative(root, abs);
  if (rel.startsWith("..") || isAbsolute(rel) || hasDotDotSegment(rel)) {
    throw new Error(`path escapes repo root: ${relPath}`);
  }
  return abs;
}

function utf8Bytes(text) {
  return Buffer.byteLength(text, "utf8");
}

function approxTokens(bytes) {
  return Math.ceil(bytes / 4);
}

function collapseWs(s) {
  return String(s).replace(/\s+/g, " ").trim();
}

function loadJson(absPath) {
  let raw;
  try {
    raw = readFileSync(absPath, "utf8");
  } catch (e) {
    throw new Error(`cannot read ${absPath}: ${e.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (e) {
    throw new Error(`invalid JSON ${absPath}: ${e.message}`);
  }
}

function walkMdFiles(root, relDir, acc) {
  const abs = join(root, relDir);
  if (!existsSync(abs)) return;
  let st;
  try {
    st = statSync(abs);
  } catch {
    return;
  }
  if (!st.isDirectory()) return;
  let ents;
  try {
    ents = readdirSync(abs, { withFileTypes: true });
  } catch {
    return;
  }
  for (const ent of ents) {
    if (ent.name === ".git" || ent.name === "node_modules") continue;
    const rel = `${relDir}/${ent.name}`.replace(/\\/g, "/");
    if (ent.isDirectory()) {
      walkMdFiles(root, rel, acc);
    } else if (ent.isFile() && ent.name.endsWith(".md")) {
      acc.push(rel);
    }
  }
}

function gitShowBytes(root, ref, relPath) {
  const r = spawnSync("git", ["-C", root, "show", `${ref}:${relPath}`], {
    encoding: "buffer",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (r.status !== 0) return null;
  return r.stdout.length;
}

const repoRoot = resolve(
  typeof parsed.repoRoot === "string" && parsed.repoRoot
    ? parsed.repoRoot
    : defaultRepoRoot()
);
if (!existsSync(repoRoot) || !statSync(repoRoot).isDirectory()) {
  dieUsage(`repo root is not a directory: ${repoRoot}`);
}

let configAbs;
try {
  configAbs = resolveUnderRoot(repoRoot, parsed.configRel || DEFAULT_CONFIG_REL);
} catch (e) {
  dieUsage(e.message);
}
if (!existsSync(configAbs)) {
  dieUsage(`config missing: ${parsed.configRel}`);
}

const cfg = loadJson(configAbs);
const findings = [];

function fail(code, message) {
  findings.push({ code, message });
}

const mandatoryFiles = Array.isArray(cfg.mandatoryFiles) ? cfg.mandatoryFiles : [];
const allowed = Array.isArray(cfg.allowedMandatoryFiles)
  ? cfg.allowedMandatoryFiles
  : ["AGENTS.md"];
if (
  mandatoryFiles.length !== allowed.length ||
  mandatoryFiles.some((f, i) => f !== allowed[i])
) {
  fail(
    "E_MANDATORY_SET",
    `mandatoryFiles must equal allowedMandatoryFiles (${allowed.join(", ")}); got ${JSON.stringify(mandatoryFiles)}`
  );
}
if (allowed.length !== 1 || allowed[0] !== "AGENTS.md") {
  fail(
    "E_MANDATORY_SET",
    "allowedMandatoryFiles is a closed set: only AGENTS.md"
  );
}

const byteBudget = cfg.byteBudget || {};
const agentsBudget = Number(byteBudget["AGENTS.md"] || 0);
const chainBudget = Number(byteBudget.mandatoryChain || 0);

let agentsText = "";
let agentsBytes = 0;
const chainFiles = [];
for (const rel of mandatoryFiles) {
  let abs;
  try {
    abs = resolveUnderRoot(repoRoot, rel);
  } catch (e) {
    fail("E_PATH", `${rel}: ${e.message}`);
    continue;
  }
  if (!existsSync(abs)) {
    fail("E_MISSING", `mandatory file missing: ${rel}`);
    continue;
  }
  const text = readFileSync(abs, "utf8");
  const bytes = utf8Bytes(text);
  chainFiles.push({ path: rel, bytes, approxTokens: approxTokens(bytes) });
  if (rel === "AGENTS.md") {
    agentsText = text;
    agentsBytes = bytes;
  }
}

const chainBytes = chainFiles.reduce((s, f) => s + f.bytes, 0);

if (agentsBudget > 0 && agentsBytes > agentsBudget) {
  fail(
    "E_BUDGET",
    `AGENTS.md is ${agentsBytes} bytes (budget ${agentsBudget})`
  );
}
if (chainBudget > 0 && chainBytes > chainBudget) {
  fail(
    "E_BUDGET",
    `mandatory chain is ${chainBytes} bytes (budget ${chainBudget})`
  );
}

const pre = cfg.preChangeAt && typeof cfg.preChangeAt === "object" ? cfg.preChangeAt : {};
const beforeCommit = typeof pre.commit === "string" ? pre.commit : "";
const beforeFiles = Array.isArray(pre.impliedMandatoryFiles)
  ? pre.impliedMandatoryFiles
  : [];
let beforeBytesFromGit = 0;
let beforeGitOk = true;
const beforePerFile = [];
if (beforeCommit && beforeFiles.length) {
  for (const rel of beforeFiles) {
    const b = gitShowBytes(repoRoot, beforeCommit, rel);
    if (b == null) {
      beforeGitOk = false;
      beforePerFile.push({ path: rel, bytes: null });
    } else {
      beforeBytesFromGit += b;
      beforePerFile.push({ path: rel, bytes: b });
    }
  }
  if (beforeGitOk && typeof pre.impliedMandatoryBytes === "number") {
    if (beforeBytesFromGit !== pre.impliedMandatoryBytes) {
      fail(
        "E_BEFORE_PIN",
        `preChangeAt.impliedMandatoryBytes pin ${pre.impliedMandatoryBytes} != git show ${beforeCommit} sum ${beforeBytesFromGit}`
      );
    }
  }
  if (beforeGitOk && chainBytes >= beforeBytesFromGit) {
    fail(
      "E_NO_SHRINK",
      `mandatory chain ${chainBytes} bytes is not smaller than pre-change implied chain ${beforeBytesFromGit}`
    );
  }
}

let manifest = null;
const manifestRel =
  typeof cfg.policyManifestPath === "string"
    ? cfg.policyManifestPath
    : "config/policy/candidates/gibson-core-v1.candidate.json";
try {
  manifest = loadJson(resolveUnderRoot(repoRoot, manifestRel));
} catch (e) {
  fail("E_MANIFEST", e.message);
}

if (agentsText) {
  const authorityPhrases = [
    "sole mandatory human-readable",
    "on-demand and non-normative",
  ];
  for (const p of authorityPhrases) {
    if (!agentsText.toLowerCase().includes(p.toLowerCase())) {
      fail("E_AUTHORITY", `AGENTS.md missing authority phrase: ${p}`);
    }
  }

  const heading = cfg.onDemandSectionHeading || "On-demand (non-normative)";
  if (!agentsText.includes(`## ${heading}`)) {
    fail("E_ON_DEMAND", `AGENTS.md missing heading ## ${heading}`);
  }

  const patterns = Array.isArray(cfg.requiredRulePatterns)
    ? cfg.requiredRulePatterns
    : [];
  const agentsFlat = collapseWs(agentsText);
  for (const p of patterns) {
    if (!agentsFlat.includes(collapseWs(p))) {
      fail("E_RULE", `AGENTS.md missing required rule pattern: ${p}`);
    }
  }

  const forbidden = Array.isArray(cfg.forbiddenContractPatterns)
    ? cfg.forbiddenContractPatterns
    : [];
  for (const p of forbidden) {
    if (agentsText.includes(p)) {
      fail(
        "E_IMPLIED_BINDING",
        `AGENTS.md still treats a docs/ file as the contract via: ${p}`
      );
    }
  }

  const sources = Array.isArray(cfg.requiredMachineSourcePaths)
    ? cfg.requiredMachineSourcePaths
    : [];
  for (const p of sources) {
    if (!agentsText.includes(p)) {
      fail("E_MACHINE_SOURCE", `AGENTS.md does not name canonical source ${p}`);
    }
  }

  if (manifest && Array.isArray(manifest.humanGates)) {
    const present = new Set();
    let m;
    const re = new RegExp(GATE_ID_RE.source, "g");
    while ((m = re.exec(agentsText)) !== null) {
      present.add(`G${m[1]}`);
    }
    for (const g of manifest.humanGates) {
      if (!g || typeof g.id !== "string") continue;
      if (!present.has(g.id)) {
        fail("E_GATE", `AGENTS.md missing ${g.id}`);
      }
      if (typeof g.summary === "string" && g.summary && !agentsText.includes(g.summary)) {
        fail(
          "E_GATE_DRIFT",
          `AGENTS.md missing canonical ${g.id} summary from ${manifestRel}`
        );
      }
    }
    for (const id of present) {
      if (!manifest.humanGates.some((g) => g && g.id === id)) {
        fail("E_GATE_DRIFT", `AGENTS.md has ${id} not in ${manifestRel}`);
      }
    }
  }

  if (manifest && Array.isArray(manifest.roles)) {
    for (const r of manifest.roles) {
      if (!r || typeof r.id !== "string") continue;
      if (!agentsText.includes("`" + r.id + "`") && !agentsText.includes(`| ${r.id} |`)) {
        fail("E_ROLE", `AGENTS.md missing role ${r.id}`);
      }
    }
  }

  if (manifest && Array.isArray(manifest.riskTiers)) {
    for (const t of manifest.riskTiers) {
      if (!t || typeof t.id !== "string") continue;
      if (!new RegExp(`\\*\\*${t.id}\\*\\*`).test(agentsText)) {
        fail("E_TIER", `AGENTS.md missing risk tier **${t.id}**`);
      }
    }
  }

  if (manifest && Array.isArray(manifest.workflowStages)) {
    for (const s of manifest.workflowStages) {
      if (!s || typeof s.name !== "string") continue;
      if (!agentsText.includes(s.name)) {
        fail("E_STAGE", `AGENTS.md missing stage name ${s.name}`);
      }
    }
  }

  if (manifest && Array.isArray(manifest.forbiddenRolePairs)) {
    for (const pair of manifest.forbiddenRolePairs) {
      if (!pair || typeof pair.a !== "string" || typeof pair.b !== "string") continue;
      const a = pair.a;
      const b = pair.b;
      const ok =
        agentsText.includes("`" + a + "` ≠ `" + b + "`") ||
        agentsText.includes("`" + a + "` ≠\n`" + b + "`") ||
        (agentsText.includes("`" + a + "`") &&
          agentsText.includes("`" + b + "`") &&
          /forbidden pairs/i.test(agentsText));
      if (!ok) {
        fail("E_PAIR", `AGENTS.md missing forbidden pair ${a} ≠ ${b}`);
      }
    }
  }
}

const marker = cfg.nonNormativeMarker || "**Authority:** Non-normative";
const globs = Array.isArray(cfg.nonNormativeGlobs) ? cfg.nonNormativeGlobs : [];
const markedFiles = [];
if (!parsed.measureOnly) {
  const toCheck = [];
  for (const g of globs) {
    if (g === "docs/**/*.md") walkMdFiles(repoRoot, "docs", toCheck);
    else if (g === "playbooks/**/*.md") walkMdFiles(repoRoot, "playbooks", toCheck);
    else fail("E_GLOB", `unsupported nonNormativeGlob: ${g}`);
  }
  const seen = new Set();
  for (const rel of toCheck) {
    if (seen.has(rel)) continue;
    seen.add(rel);
    let abs;
    try {
      abs = resolveUnderRoot(repoRoot, rel);
    } catch (e) {
      fail("E_PATH", `${rel}: ${e.message}`);
      continue;
    }
    const text = readFileSync(abs, "utf8");
    if (!text.includes(marker)) {
      fail("E_BANNER", `${rel} missing non-normative marker`);
    } else {
      markedFiles.push(rel);
    }
  }
}

const report = {
  schemaId: "gibson.mandatory-read-chain.report.v1",
  repoRootLabel: "<repo>",
  mandatoryFiles: chainFiles,
  mandatoryChainBytes: chainBytes,
  mandatoryChainApproxTokens: approxTokens(chainBytes),
  tokenProxy: cfg.tokenProxy || { id: "utf8-bytes-div-4" },
  byteBudget,
  preChange: {
    commit: beforeCommit || null,
    impliedMandatoryBytesPin: pre.impliedMandatoryBytes || null,
    impliedMandatoryBytesGit: beforeGitOk ? beforeBytesFromGit : null,
    impliedApproxTokens: beforeGitOk ? approxTokens(beforeBytesFromGit) : null,
    lessonsBytesPin: pre.lessonsBytes || null,
    agentsBytesPin: pre.agentsBytes || null,
    files: beforePerFile,
  },
  nonNormativeMarked: markedFiles.length,
  findings,
  ok: findings.length === 0,
};

function printText() {
  const lines = [];
  lines.push(
    `contract-authority: mandatory chain ${chainBytes} bytes (~${approxTokens(chainBytes)} tokens via utf8-bytes-div-4)`
  );
  for (const f of chainFiles) {
    lines.push(`  ${f.path}: ${f.bytes} bytes (~${f.approxTokens} tokens)`);
  }
  if (beforeGitOk && beforeBytesFromGit) {
    lines.push(
      `  pre-change implied chain at ${beforeCommit.slice(0, 12)}: ${beforeBytesFromGit} bytes (~${approxTokens(beforeBytesFromGit)} tokens)`
    );
    lines.push(
      `  delta: ${chainBytes - beforeBytesFromGit} bytes (${Math.round((chainBytes / beforeBytesFromGit) * 1000) / 10}% of prior implied chain)`
    );
  }
  if (typeof pre.lessonsBytes === "number") {
    lines.push(
      `  memory/LESSONS.md at branch point (consult, not full ingest): ${pre.lessonsBytes} bytes (~${approxTokens(pre.lessonsBytes)} tokens)`
    );
  }
  if (parsed.measureOnly) {
    console.log(lines.join("\n"));
    return;
  }
  if (findings.length === 0) {
    lines.push("contract-authority: OK — authority boundary and budget hold");
    console.log(lines.join("\n"));
  } else {
    lines.push(`contract-authority: FAIL — ${findings.length} finding(s)`);
    for (const f of findings) {
      lines.push(`  ${f.code}: ${f.message}`);
    }
    console.log(lines.join("\n"));
  }
}

if (parsed.format === "json") {
  console.log(JSON.stringify(report, null, 2) + "\n");
} else {
  printText();
}

if (parsed.measureOnly) {
  process.exit(0);
}
process.exit(findings.length === 0 ? 0 : 1);
