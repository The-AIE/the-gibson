#!/usr/bin/env node
/**
 * contract-authority.mjs — #208 authority boundary + mandatory-read budget
 *
 * WHAT IT DOES
 *   Enforces that AGENTS.md is the sole always-mandatory human-readable
 *   contract; that conditionally mandatory role/job dispatch prompts are
 *   disclosed and measured separately (closed list, exact set-equality with
 *   discovered playbook markdown dispatch markers); that docs stay
 *   non-normative; that playbooks with operative gates:/forbidden:
 *   frontmatter do not carry a blanket non-normative banner; that required
 *   binding-rule families remain in AGENTS.md; and that the report-only
 *   policy-manifest candidate mirrors AGENTS.md without becoming authority.
 *
 * WHY
 *   Mixed-authority prose made agents ingest ~100KB+ of explanation as if it
 *   were the contract. PR #226 also pre-activated the candidate and left
 *   banner/frontmatter contradictions.
 *
 * RISKS
 *   Structural + pattern sensors, not a full prose parser. Independent review
 *   still applies. Read-only. Does not activate the report-only candidate.
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
const FRONTMATTER_RE = /^---\r?\n([\s\S]*?)\r?\n---/;

function help() {
  console.log(`contract-authority.mjs — #208 authority boundary + read-chain budget

WHAT IT DOES
  Checks AGENTS.md authority, fixed vs conditional role/job dispatch-prompt
  load, binding-rule families, docs/playbook authority honesty, and
  report-only candidate mirror drift.

WHY
  Prevents the contract from growing back into a 100KB+ implied read chain
  and blocks candidate pre-activation / banner contradictions.

RISKS
  Structural/pattern sensor, not a semantic proof. Read-only.

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

function isPlaybooksMdPath(rel) {
  return (
    typeof rel === "string" &&
    rel.startsWith("playbooks/") &&
    rel.endsWith(".md") &&
    !rel.includes("\\") &&
    !hasDotDotSegment(rel)
  );
}

function playbookStem(rel) {
  return String(rel).replace(/^playbooks\//, "").replace(/\.md$/, "");
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

function parseFrontmatter(text) {
  const m = FRONTMATTER_RE.exec(text);
  if (!m) return { hasFrontmatter: false, body: text, raw: "" };
  return { hasFrontmatter: true, body: text.slice(m[0].length), raw: m[1] };
}

function frontmatterHasOperativeKeys(fmRaw) {
  // Operative dispatch keys at YAML top level (start of line).
  return /^(gates|forbidden)\s*:/m.test(fmRaw);
}

function extractGateSummaries(agentsText) {
  const out = new Map();
  const re = /\*\*(G(?:[1-9]|1[0-6]))\*\*\s*(?:⛔\s*)?—\s*([^\n]+)/g;
  let m;
  while ((m = re.exec(agentsText)) !== null) {
    out.set(m[1], m[2].trim());
  }
  return out;
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

// Conditional role/job dispatch-prompt measurement (separate from fixed budget).
if (
  cfg.conditionalRolePlaybooks &&
  typeof cfg.conditionalRolePlaybooks === "object"
) {
  fail(
    "E_DISPATCH_CONFIG",
    "conditionalRolePlaybooks is retired; use conditionalDispatchPrompts with roles plus jobPrompts"
  );
}
const dispatchCfg =
  cfg.conditionalDispatchPrompts && typeof cfg.conditionalDispatchPrompts === "object"
    ? cfg.conditionalDispatchPrompts
    : null;
if (!dispatchCfg) {
  fail(
    "E_DISPATCH_CONFIG",
    "conditionalDispatchPrompts object is required (closed role + job dispatch-prompt list)"
  );
}
const roleIds = Array.isArray(dispatchCfg && dispatchCfg.roles)
  ? dispatchCfg.roles
  : [];
const rolePathTemplate =
  dispatchCfg && typeof dispatchCfg.pathTemplate === "string"
    ? dispatchCfg.pathTemplate
    : "playbooks/{role}.md";
const jobPromptList = Array.isArray(dispatchCfg && dispatchCfg.jobPrompts)
  ? dispatchCfg.jobPrompts
  : null;
if (dispatchCfg && roleIds.length === 0) {
  fail(
    "E_DISPATCH_CONFIG",
    "conditionalDispatchPrompts.roles must list the dispatched roles"
  );
}
if (dispatchCfg && !Array.isArray(dispatchCfg.jobPrompts)) {
  fail(
    "E_DISPATCH_CONFIG",
    "conditionalDispatchPrompts.jobPrompts must be an array of playbooks/**/*.md paths"
  );
}

const playbookDispatchMarker =
  cfg.playbookDispatchMarker ||
  "**Authority:** Conditionally mandatory dispatch prompt";

const closedEntries = [];
const closedSeen = new Set();
function addClosedDispatch(rel, kind, id) {
  if (!isPlaybooksMdPath(rel)) {
    fail(
      "E_DISPATCH_CONFIG",
      `dispatch prompt path must be playbooks/**/*.md: ${rel}`
    );
    return;
  }
  if (closedSeen.has(rel)) {
    fail("E_DISPATCH_SET", `duplicate closed dispatch-prompt path: ${rel}`);
    return;
  }
  closedSeen.add(rel);
  closedEntries.push({ path: rel, kind, id });
}

for (const role of roleIds) {
  if (typeof role !== "string" || !role) {
    fail("E_DISPATCH_CONFIG", "roles entries must be non-empty strings");
    continue;
  }
  addClosedDispatch(rolePathTemplate.replace("{role}", role), "role", role);
}
if (Array.isArray(jobPromptList)) {
  for (const rel of jobPromptList) {
    if (typeof rel !== "string" || !rel) {
      fail("E_DISPATCH_CONFIG", "jobPrompts entries must be non-empty relative paths");
      continue;
    }
    addClosedDispatch(rel, "job", playbookStem(rel));
  }
}

const discoveredDispatch = [];
{
  const playbooksToDiscover = [];
  const globs = Array.isArray(cfg.playbookGlobs)
    ? cfg.playbookGlobs
    : ["playbooks/**/*.md"];
  for (const g of globs) {
    if (g === "playbooks/**/*.md") walkMdFiles(repoRoot, "playbooks", playbooksToDiscover);
    else fail("E_GLOB", `unsupported playbookGlob: ${g}`);
  }
  const seen = new Set();
  for (const rel of playbooksToDiscover) {
    if (seen.has(rel)) continue;
    seen.add(rel);
    let abs;
    try {
      abs = resolveUnderRoot(repoRoot, rel);
    } catch (e) {
      fail("E_PATH", `${rel}: ${e.message}`);
      continue;
    }
    if (!existsSync(abs)) continue;
    const text = readFileSync(abs, "utf8");
    if (text.includes(playbookDispatchMarker)) discoveredDispatch.push(rel);
  }
  discoveredDispatch.sort();
}

const dispatchPrompts = [];
let dispatchBytesMin = null;
let dispatchBytesMax = 0;
let dispatchBytesSum = 0;
for (const entry of closedEntries) {
  const rel = entry.path;
  let abs;
  try {
    abs = resolveUnderRoot(repoRoot, rel);
  } catch (e) {
    fail("E_DISPATCH_PROMPT_PATH", `${rel}: ${e.message}`);
    continue;
  }
  if (!existsSync(abs)) {
    fail("E_DISPATCH_PROMPT_MISSING", `conditional dispatch prompt missing: ${rel}`);
    continue;
  }
  const text = readFileSync(abs, "utf8");
  if (!text.includes(playbookDispatchMarker)) {
    fail(
      "E_DISPATCH_SET",
      `manifest dispatch prompt is not marked as a dispatch prompt: ${rel}`
    );
  }
  const bytes = utf8Bytes(text);
  const rec = {
    path: rel,
    kind: entry.kind,
    bytes,
    approxTokens: approxTokens(bytes),
  };
  if (entry.kind === "role") rec.role = entry.id;
  else rec.job = entry.id;
  dispatchPrompts.push(rec);
  dispatchBytesSum += bytes;
  dispatchBytesMax = Math.max(dispatchBytesMax, bytes);
  dispatchBytesMin =
    dispatchBytesMin == null ? bytes : Math.min(dispatchBytesMin, bytes);
}
dispatchPrompts.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));

const discoveredSet = new Set(discoveredDispatch);
for (const rel of discoveredDispatch) {
  if (!closedSeen.has(rel)) {
    fail(
      "E_DISPATCH_SET",
      `discovered dispatch prompt omitted from the closed list: ${rel}`
    );
  }
}
for (const rel of [...closedSeen].sort()) {
  if (!discoveredSet.has(rel)) {
    fail(
      "E_DISPATCH_SET",
      `closed-list dispatch prompt was not discovered as marked: ${rel}`
    );
  }
}

const auditRel =
  typeof cfg.ruleMigrationAuditPath === "string"
    ? cfg.ruleMigrationAuditPath
    : "config/policy/rule-migration-audit.v1.json";
let audit = null;
try {
  audit = loadJson(resolveUnderRoot(repoRoot, auditRel));
} catch (e) {
  fail("E_AUDIT", e.message);
}

let mirror = null;
const mirrorRel =
  typeof cfg.policyManifestMirrorPath === "string"
    ? cfg.policyManifestMirrorPath
    : "config/policy/candidates/gibson-core-v1.candidate.json";
try {
  mirror = loadJson(resolveUnderRoot(repoRoot, mirrorRel));
} catch (e) {
  fail("E_MIRROR", e.message);
}

if (agentsText) {
  const authorityPhrases = [
    "sole always-mandatory human-readable",
    "on-demand and non-normative",
    "checked mirror",
    "activated=false",
  ];
  for (const p of authorityPhrases) {
    if (!agentsText.toLowerCase().includes(p.toLowerCase())) {
      fail("E_AUTHORITY", `AGENTS.md missing authority phrase: ${p}`);
    }
  }

  // Must not claim the report-only candidate is canonical/authority.
  if (
    /are canonical in `config\/policy\/candidates\/gibson-core-v1\.candidate\.json`/i.test(
      agentsText
    ) ||
    /Enumerations of gates, roles, tiers, stages, and forbidden pairs are canonical/i.test(
      agentsText
    )
  ) {
    fail(
      "E_CANDIDATE_PREACTIVATION",
      "AGENTS.md must not declare the report-only candidate canonical/authority"
    );
  }

  const heading = cfg.onDemandSectionHeading || "On-demand (non-normative)";
  if (!agentsText.includes(`## ${heading}`)) {
    fail("E_ON_DEMAND", `AGENTS.md missing heading ## ${heading}`);
  }

  // Conditional role/job dispatch-prompt disclosure (honest session-start load).
  const disclosure = Array.isArray(dispatchCfg && dispatchCfg.disclosurePhrases)
    ? dispatchCfg.disclosurePhrases
    : [];
  for (const p of disclosure) {
    if (!agentsText.includes(p)) {
      fail(
        "E_ROLE_DISCLOSURE",
        `AGENTS.md omits conditional dispatch-prompt disclosure phrase: ${p}`
      );
    }
  }
  // Reject the false claim that AGENTS-only is the complete session-start load.
  if (
    /Mandatory human-readable load \(this repository\):\s*this file only/i.test(
      agentsText
    ) &&
    !/Conditional session-start human-readable load/i.test(agentsText)
  ) {
    fail(
      "E_ROLE_DISCLOSURE",
      "AGENTS.md claims AGENTS-only load without disclosing conditional role/job dispatch prompts"
    );
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

  const families = Array.isArray(cfg.requiredBindingFamilies)
    ? cfg.requiredBindingFamilies
    : [];
  for (const fam of families) {
    if (!fam || typeof fam.id !== "string") continue;
    const fps = Array.isArray(fam.patterns) ? fam.patterns : [];
    for (const p of fps) {
      if (!agentsFlat.includes(collapseWs(p))) {
        fail(
          "E_BINDING_FAMILY",
          `AGENTS.md missing binding-family ${fam.id} pattern: ${p}`
        );
      }
    }
  }

  if (audit && Array.isArray(audit.families)) {
    for (const fam of families) {
      if (!fam || typeof fam.id !== "string") continue;
      if (!audit.families.some((a) => a && a.id === fam.id)) {
        fail(
          "E_AUDIT_FAMILY",
          `rule-migration audit missing required family ${fam.id}`
        );
      }
    }
  }

  const forbidden = Array.isArray(cfg.forbiddenContractPatterns)
    ? cfg.forbiddenContractPatterns
    : [];
  for (const p of forbidden) {
    if (agentsText.includes(p)) {
      fail(
        "E_IMPLIED_BINDING",
        `AGENTS.md still treats a docs/ file or candidate as the contract via: ${p}`
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

  // Gate IDs/summaries are owned by AGENTS.md (not supplied by the candidate).
  const agentsGates = extractGateSummaries(agentsText);
  for (let i = 1; i <= 16; i++) {
    const id = `G${i}`;
    if (!agentsGates.has(id)) {
      fail("E_GATE", `AGENTS.md missing ${id}`);
    }
  }
  const present = new Set();
  let m;
  const re = new RegExp(GATE_ID_RE.source, "g");
  while ((m = re.exec(agentsText)) !== null) {
    present.add(`G${m[1]}`);
  }
  for (const id of present) {
    const n = Number(id.slice(1));
    if (!Number.isInteger(n) || n < 1 || n > 16) {
      fail("E_GATE_DRIFT", `AGENTS.md has unexpected gate id ${id}`);
    }
  }

  // Role / tier / stage / pair presence from AGENTS-owned required lists.
  for (const role of roleIds) {
    if (
      !agentsText.includes("`" + role + "`") &&
      !agentsText.includes(`| ${role} |`)
    ) {
      fail("E_ROLE", `AGENTS.md missing role ${role}`);
    }
  }
  for (const t of ["A", "B", "C"]) {
    if (!new RegExp(`\\*\\*${t}\\*\\*`).test(agentsText)) {
      fail("E_TIER", `AGENTS.md missing risk tier **${t}**`);
    }
  }
  const stages = [
    "PLAN",
    "DECOMPOSE",
    "BUILD",
    "TEST",
    "REVIEW",
    "UX-EVAL",
    "SECURITY",
    "MERGE",
    "DEPLOY+VERIFY",
    "RETRO",
  ];
  for (const s of stages) {
    if (!agentsText.includes(s)) {
      fail("E_STAGE", `AGENTS.md missing stage name ${s}`);
    }
  }
  const pairs = [
    ["builder", "reviewer"],
    ["builder", "ux-evaluator"],
    ["reviewer", "ux-evaluator"],
  ];
  for (const [a, b] of pairs) {
    const ok =
      agentsText.includes("`" + a + "` ≠ `" + b + "`") ||
      (agentsText.includes("`" + a + "`") &&
        agentsText.includes("`" + b + "`") &&
        /forbidden pairs/i.test(agentsText));
    if (!ok) {
      fail("E_PAIR", `AGENTS.md missing forbidden pair ${a} ≠ ${b}`);
    }
  }

  // Report-only candidate is a checked mirror of AGENTS authority — never the
  // supplier of binding values, and never activated on this slice.
  if (mirror) {
    if (mirror.activated !== false) {
      fail(
        "E_CANDIDATE_PREACTIVATION",
        `${mirrorRel} must keep activated=false until #164 (got ${JSON.stringify(mirror.activated)})`
      );
    }
    if (mirror.authority !== "report-only") {
      fail(
        "E_CANDIDATE_PREACTIVATION",
        `${mirrorRel} must keep authority=report-only until #164 (got ${JSON.stringify(mirror.authority)})`
      );
    }
    if (Array.isArray(mirror.humanGates)) {
      for (const g of mirror.humanGates) {
        if (!g || typeof g.id !== "string") continue;
        if (!agentsGates.has(g.id)) {
          fail(
            "E_MIRROR_DRIFT",
            `report-only candidate has ${g.id} absent from AGENTS.md authority`
          );
          continue;
        }
        if (
          typeof g.summary === "string" &&
          g.summary &&
          agentsGates.get(g.id) !== g.summary
        ) {
          fail(
            "E_MIRROR_DRIFT",
            `report-only candidate ${g.id} summary drifts from AGENTS.md authority`
          );
        }
      }
      for (const id of agentsGates.keys()) {
        if (!mirror.humanGates.some((g) => g && g.id === id)) {
          fail(
            "E_MIRROR_DRIFT",
            `AGENTS.md has ${id} missing from report-only candidate mirror`
          );
        }
      }
    }
    if (Array.isArray(mirror.roles)) {
      for (const r of mirror.roles) {
        if (!r || typeof r.id !== "string") continue;
        if (
          !agentsText.includes("`" + r.id + "`") &&
          !agentsText.includes(`| ${r.id} |`)
        ) {
          fail(
            "E_MIRROR_DRIFT",
            `report-only candidate role ${r.id} absent from AGENTS.md authority`
          );
        }
      }
    }
    if (Array.isArray(mirror.riskTiers)) {
      for (const t of mirror.riskTiers) {
        if (!t || typeof t.id !== "string") continue;
        if (!new RegExp(`\\*\\*${t.id}\\*\\*`).test(agentsText)) {
          fail(
            "E_MIRROR_DRIFT",
            `report-only candidate tier ${t.id} absent from AGENTS.md authority`
          );
        }
      }
    }
    if (Array.isArray(mirror.workflowStages)) {
      for (const s of mirror.workflowStages) {
        if (!s || typeof s.name !== "string") continue;
        if (!agentsText.includes(s.name)) {
          fail(
            "E_MIRROR_DRIFT",
            `report-only candidate stage ${s.name} absent from AGENTS.md authority`
          );
        }
      }
    }
    if (Array.isArray(mirror.forbiddenRolePairs)) {
      for (const pair of mirror.forbiddenRolePairs) {
        if (!pair || typeof pair.a !== "string" || typeof pair.b !== "string") {
          continue;
        }
        const ok =
          agentsText.includes("`" + pair.a + "` ≠ `" + pair.b + "`") ||
          (agentsText.includes("`" + pair.a + "`") &&
            agentsText.includes("`" + pair.b + "`") &&
            /forbidden pairs/i.test(agentsText));
        if (!ok) {
          fail(
            "E_MIRROR_DRIFT",
            `report-only candidate pair ${pair.a} ≠ ${pair.b} absent from AGENTS.md authority`
          );
        }
      }
    }
  }
}

// Forbidden misleading repo claims (e.g. README saying agents follow docs/playbooks rules).
const repoClaims = Array.isArray(cfg.forbiddenRepoClaims)
  ? cfg.forbiddenRepoClaims
  : [];
for (const claim of repoClaims) {
  if (!claim || typeof claim.path !== "string") continue;
  let abs;
  try {
    abs = resolveUnderRoot(repoRoot, claim.path);
  } catch (e) {
    fail("E_PATH", `${claim.path}: ${e.message}`);
    continue;
  }
  if (!existsSync(abs)) continue;
  const text = readFileSync(abs, "utf8");
  const patterns = Array.isArray(claim.patterns) ? claim.patterns : [];
  for (const p of patterns) {
    if (text.includes(p)) {
      fail(
        "E_REPO_CLAIM",
        `${claim.path} still claims binding rules live in docs/playbooks: ${p}`
      );
    }
  }
}

const docsMarker = cfg.docsNonNormativeMarker || "**Authority:** Non-normative";
const playbookNonNormativeMarker =
  cfg.playbookNonNormativeMarker || "**Authority:** Non-normative";
const docsGlobs = Array.isArray(cfg.docsNonNormativeGlobs)
  ? cfg.docsNonNormativeGlobs
  : Array.isArray(cfg.nonNormativeGlobs)
    ? cfg.nonNormativeGlobs.filter((g) => String(g).startsWith("docs/"))
    : ["docs/**/*.md"];
const playbookGlobs = Array.isArray(cfg.playbookGlobs)
  ? cfg.playbookGlobs
  : ["playbooks/**/*.md"];

const markedDocs = [];
const checkedPlaybooks = [];
if (!parsed.measureOnly) {
  const docsToCheck = [];
  for (const g of docsGlobs) {
    if (g === "docs/**/*.md") walkMdFiles(repoRoot, "docs", docsToCheck);
    else fail("E_GLOB", `unsupported docsNonNormativeGlob: ${g}`);
  }
  const seenDocs = new Set();
  for (const rel of docsToCheck) {
    if (seenDocs.has(rel)) continue;
    seenDocs.add(rel);
    let abs;
    try {
      abs = resolveUnderRoot(repoRoot, rel);
    } catch (e) {
      fail("E_PATH", `${rel}: ${e.message}`);
      continue;
    }
    const text = readFileSync(abs, "utf8");
    if (!text.includes(docsMarker)) {
      fail("E_BANNER", `${rel} missing non-normative marker`);
    } else {
      markedDocs.push(rel);
    }
  }

  const playbooksToCheck = [];
  for (const g of playbookGlobs) {
    if (g === "playbooks/**/*.md") walkMdFiles(repoRoot, "playbooks", playbooksToCheck);
    else fail("E_GLOB", `unsupported playbookGlob: ${g}`);
  }
  const seenPb = new Set();
  for (const rel of playbooksToCheck) {
    if (seenPb.has(rel)) continue;
    seenPb.add(rel);
    let abs;
    try {
      abs = resolveUnderRoot(repoRoot, rel);
    } catch (e) {
      fail("E_PATH", `${rel}: ${e.message}`);
      continue;
    }
    const text = readFileSync(abs, "utf8");
    const fm = parseFrontmatter(text);
    const hasOperative = fm.hasFrontmatter && frontmatterHasOperativeKeys(fm.raw);
    const hasDispatch = text.includes(playbookDispatchMarker);
    const hasNonNorm = text.includes(playbookNonNormativeMarker);

    if (hasOperative && hasNonNorm) {
      fail(
        "E_AUTHORITY_CONTRADICTION",
        `${rel} has operative gates:/forbidden: frontmatter coexisting with a blanket non-normative banner`
      );
    } else if (hasOperative && !hasDispatch) {
      fail(
        "E_PLAYBOOK_AUTHORITY",
        `${rel} has operative gates:/forbidden: but missing dispatch-prompt authority marker`
      );
    } else if (!hasOperative && !hasNonNorm && !hasDispatch) {
      fail(
        "E_BANNER",
        `${rel} missing authority marker (non-normative or conditionally mandatory dispatch)`
      );
    } else {
      checkedPlaybooks.push(rel);
    }
  }
}

const report = {
  schemaId: "gibson.mandatory-read-chain.report.v1",
  repoRootLabel: "<repo>",
  fixedMandatoryFiles: chainFiles,
  mandatoryFiles: chainFiles,
  mandatoryChainBytes: chainBytes,
  mandatoryChainApproxTokens: approxTokens(chainBytes),
  conditionalDispatchPrompts: {
    files: dispatchPrompts,
    count: dispatchPrompts.length,
    bytesSum: dispatchBytesSum,
    bytesMin: dispatchBytesMin,
    bytesMax: dispatchBytesMax,
    approxTokensSum: approxTokens(dispatchBytesSum),
    approxTokensMin:
      dispatchBytesMin == null ? null : approxTokens(dispatchBytesMin),
    approxTokensMax: approxTokens(dispatchBytesMax),
    worstCaseFixedPlusLargestDispatchPrompt:
      dispatchBytesMax > 0 ? chainBytes + dispatchBytesMax : chainBytes,
    worstCaseFixedPlusLargestDispatchPromptApproxTokens: approxTokens(
      dispatchBytesMax > 0 ? chainBytes + dispatchBytesMax : chainBytes
    ),
    roles: roleIds,
    jobPrompts: Array.isArray(jobPromptList) ? jobPromptList : [],
  },
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
  nonNormativeMarkedDocs: markedDocs.length,
  playbooksChecked: checkedPlaybooks.length,
  findings,
  ok: findings.length === 0,
};

function printText() {
  const lines = [];
  lines.push(
    `contract-authority: fixed mandatory chain ${chainBytes} bytes (~${approxTokens(chainBytes)} tokens via utf8-bytes-div-4)`
  );
  for (const f of chainFiles) {
    lines.push(`  ${f.path}: ${f.bytes} bytes (~${f.approxTokens} tokens)`);
  }
  if (dispatchPrompts.length) {
    lines.push(
      `  conditional dispatch prompts: ${dispatchPrompts.length} files; per-file ${dispatchBytesMin}–${dispatchBytesMax} bytes (~${approxTokens(dispatchBytesMin)}–${approxTokens(dispatchBytesMax)} tokens); sum ${dispatchBytesSum} bytes`
    );
    for (const f of dispatchPrompts) {
      const label =
        f.kind === "role" ? `role:${f.role}` : `job:${f.job}`;
      lines.push(
        `    ${f.path}: ${f.bytes} bytes (~${f.approxTokens} tokens) [${label}]`
      );
    }
    lines.push(
      `  worst-case fixed + largest conditional dispatch prompt: ${chainBytes + dispatchBytesMax} bytes (~${approxTokens(chainBytes + dispatchBytesMax)} tokens)`
    );
  }
  if (beforeGitOk && beforeBytesFromGit) {
    lines.push(
      `  pre-change implied chain at ${beforeCommit.slice(0, 12)}: ${beforeBytesFromGit} bytes (~${approxTokens(beforeBytesFromGit)} tokens)`
    );
    lines.push(
      `  fixed-chain delta: ${chainBytes - beforeBytesFromGit} bytes (${Math.round((chainBytes / beforeBytesFromGit) * 1000) / 10}% of prior implied chain)`
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
