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
 *   Structured semantic comparison of enumerations and obligation objects,
 *   not a full legal parser. Independent review still applies. Read-only.
 *   Does not activate the report-only candidate.
 *
 * USAGE
 *   node scripts/contract-authority.mjs
 *   node scripts/contract-authority.mjs --measure
 *   node scripts/contract-authority.mjs --repo-root PATH --config PATH
 *   node scripts/contract-authority.mjs --help
 */

import { existsSync, realpathSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { parseFlags } from "./lib/args.mjs";
import {
  coerceRootIdentity,
  readContainedFile,
  loadJsonContained,
  hasDotDotSegment,
} from "./policy-manifest.mjs";
import {
  parseFrontmatter,
  frontmatterHasOperativeKeys,
  parseYamlList,
  extractSection,
  extractNumberedItems,
  extractMarkdownTable,
  findNonNormativeOperativeContradiction,
  findDocsAuthorityClaims,
  provenanceRoleFindings,
  structuredAgentsEnumerationFindings,
  diffObligationMatrix,
  remapRoleCodesToJob,
  listEq,
  collapseWs,
  EXPECTED_ASK_FIELDS,
  EXPECTED_ROLES,
} from "./lib/contract-semantics.mjs";
import {
  isGenuineMissingPath,
  setDiscoverAfterOpenHook,
  setDiscoverBeforeOpendirHook,
  walkMdFiles,
  discoverMdFiles,
} from "./lib/authority-discover.mjs";
import {
  CANONICAL_MANDATORY_FILES,
  CANONICAL_DOCS_GLOBS,
  CANONICAL_PLAYBOOK_GLOBS,
  CANONICAL_LOCAL_OVERRIDE,
  CANONICAL_ROLE_PATH,
  CANONICAL_DOCS_MARKER,
  CANONICAL_PLAYBOOK_NON_NORM,
  CANONICAL_DISPATCH_MARKER,
  CANONICAL_ON_DEMAND,
  CANONICAL_DEFAULT_ROLE,
  CANONICAL_DEFAULT_PATH,
  CANONICAL_ROLE_CONTRACTS,
  CANONICAL_MIRROR,
  CANONICAL_AUDIT,
  CANONICAL_JOB_PROMPTS,
  CANONICAL_DISCLOSURE_PHRASES,
  CANONICAL_BINDING_FAMILIES,
  CANONICAL_FORBIDDEN_CONTRACT_PATTERNS,
  CANONICAL_FORBIDDEN_REPO_CLAIMS,
  CANONICAL_MACHINE_SOURCE_PATHS,
  CANONICAL_REQUIRED_RULE_PATTERNS,
  CANONICAL_PRE_CHANGE,
  CANONICAL_BYTE_BUDGET,
  pinReadChainConfig,
  diffRuleMigrationAudit,
} from "./lib/authority-config-canonical.mjs";

export {
  isGenuineMissingPath,
  setDiscoverAfterOpenHook,
  setDiscoverBeforeOpendirHook,
  walkMdFiles,
  discoverMdFiles,
};

const DEFAULT_CONFIG_REL = "config/policy/mandatory-read-chain.v1.json";

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
  Structured semantic sensor, not a full legal proof. Read-only.

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

function dieUsage(msg) {
  console.error(`contract-authority: ${msg}`);
  process.exit(2);
}

function isCliMain() {
  const self = fileURLToPath(import.meta.url);
  const inv = process.argv[1] ? resolve(process.argv[1]) : "";
  try {
    return realpathSync(self) === realpathSync(inv);
  } catch {
    return resolve(self) === resolve(inv);
  }
}

function scriptDir() {
  return dirname(fileURLToPath(import.meta.url));
}

function defaultRepoRoot() {
  return resolve(scriptDir(), "..");
}

function readAuthorityText(rootId, relPath) {
  return /** @type {string} */ (readContainedFile(rootId, relPath, "utf8"));
}

function loadAuthorityJson(rootId, relPath) {
  return loadJsonContained(rootId, relPath);
}

function utf8Bytes(text) {
  return Buffer.byteLength(text, "utf8");
}

function approxTokens(bytes) {
  return Math.ceil(bytes / 4);
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

function gitShowBytes(root, ref, relPath) {
  const r = spawnSync("git", ["-C", root, "show", `${ref}:${relPath}`], {
    encoding: "buffer",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (r.status !== 0) return null;
  return r.stdout.length;
}

export function main(args = process.argv.slice(2)) {
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

const repoRootArg = resolve(
  typeof parsed.repoRoot === "string" && parsed.repoRoot
    ? parsed.repoRoot
    : defaultRepoRoot()
);
if (!existsSync(repoRootArg) || !statSync(repoRootArg).isDirectory()) {
  dieUsage(`repo root is not a directory: ${repoRootArg}`);
}

let rootId;
try {
  rootId = coerceRootIdentity(repoRootArg);
} catch (e) {
  dieUsage(e.message);
}
const repoRoot = rootId.path;
const configRel = parsed.configRel || DEFAULT_CONFIG_REL;

let cfg;
try {
  cfg = loadAuthorityJson(rootId, configRel);
} catch (e) {
  dieUsage(e.message);
}
const findings = [];

function fail(code, message) {
  findings.push({ code, message });
}

function sameStringList(actual, expected) {
  return (
    Array.isArray(actual) &&
    actual.length === expected.length &&
    actual.every((v, i) => v === expected[i])
  );
}

pinReadChainConfig(cfg, fail);

const mandatoryFiles = CANONICAL_MANDATORY_FILES;
const byteBudget = CANONICAL_BYTE_BUDGET;
const agentsBudget = CANONICAL_BYTE_BUDGET["AGENTS.md"];
const chainBudget = CANONICAL_BYTE_BUDGET.mandatoryChain;

let agentsText = "";
let agentsBytes = 0;
const chainFiles = [];
for (const rel of mandatoryFiles) {
  let text;
  try {
    text = readAuthorityText(rootId, rel);
  } catch (e) {
    const msg = String(e && e.message ? e.message : e);
    if (isGenuineMissingPath(msg)) {
      fail("E_MISSING", `mandatory file missing: ${rel}`);
    } else {
      fail("E_PATH", `${rel}: ${msg}`);
    }
    continue;
  }
  const bytes = utf8Bytes(text);
  chainFiles.push({ path: rel, bytes, approxTokens: approxTokens(bytes) });
  if (rel === "AGENTS.md") {
    agentsText = text;
    agentsBytes = bytes;
  }
}

const chainBytes = chainFiles.reduce((s, f) => s + f.bytes, 0);

if (Number.isInteger(agentsBudget) && agentsBudget > 0 && agentsBytes > agentsBudget) {
  fail(
    "E_BUDGET",
    `AGENTS.md is ${agentsBytes} bytes (budget ${agentsBudget})`
  );
}
if (Number.isInteger(chainBudget) && chainBudget > 0 && chainBytes > chainBudget) {
  fail(
    "E_BUDGET",
    `mandatory chain is ${chainBytes} bytes (budget ${chainBudget})`
  );
}

const pre = CANONICAL_PRE_CHANGE;
const beforeCommit = pre.commit;
const beforeFiles = pre.impliedMandatoryFiles;
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
const roleIds = EXPECTED_ROLES;
if (!dispatchCfg || dispatchCfg.pathTemplate !== CANONICAL_ROLE_PATH) {
  fail(
    "E_DISPATCH_CONFIG",
    `conditionalDispatchPrompts.pathTemplate must be ${JSON.stringify(CANONICAL_ROLE_PATH)}; got ${JSON.stringify(dispatchCfg && dispatchCfg.pathTemplate)}`
  );
}
const rolePathTemplate = CANONICAL_ROLE_PATH;
const jobPromptList = CANONICAL_JOB_PROMPTS;

if (cfg.playbookDispatchMarker !== CANONICAL_DISPATCH_MARKER) {
  fail(
    "E_CONFIG",
    `playbookDispatchMarker must be the contract-defined value; got ${JSON.stringify(cfg.playbookDispatchMarker ?? null)}`
  );
}
const playbookDispatchMarker = CANONICAL_DISPATCH_MARKER;

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
  const globs = Array.isArray(cfg.playbookGlobs) ? cfg.playbookGlobs : [];
  if (!sameStringList(globs, CANONICAL_PLAYBOOK_GLOBS)) {
    fail(
      "E_GLOB",
      `playbookGlobs must be ${JSON.stringify(CANONICAL_PLAYBOOK_GLOBS)}; got ${JSON.stringify(globs)}`
    );
  } else {
    discoverMdFiles(rootId, "playbooks", playbooksToDiscover, fail, { optional: true });
  }
  const seen = new Set();
  for (const rel of playbooksToDiscover) {
    if (seen.has(rel)) continue;
    seen.add(rel);
    let text;
    try {
      text = readAuthorityText(rootId, rel);
    } catch (e) {
      fail("E_PATH", `${rel}: ${e.message}`);
      continue;
    }
    if (text.includes(playbookDispatchMarker)) discoveredDispatch.push(rel);
  }
  discoveredDispatch.sort();
}

if (
  !dispatchCfg ||
  dispatchCfg.localOverrideTemplate !== CANONICAL_LOCAL_OVERRIDE
) {
  fail(
    "E_CONFIG",
    `localOverrideTemplate must be ${JSON.stringify(CANONICAL_LOCAL_OVERRIDE)}; got ${JSON.stringify(dispatchCfg && dispatchCfg.localOverrideTemplate)}`
  );
}
const localOverrideTemplate = CANONICAL_LOCAL_OVERRIDE;
const effectiveRoleTexts = new Map();
const jobTexts = new Map();
const dispatchPrompts = [];
let dispatchBytesMin = null;
let dispatchBytesMax = 0;
let dispatchBytesSum = 0;
for (const entry of closedEntries) {
  const rel = entry.path;
  let text;
  try {
    text = readAuthorityText(rootId, rel);
  } catch (e) {
    const msg = String(e && e.message ? e.message : e);
    if (isGenuineMissingPath(msg)) {
      fail("E_DISPATCH_PROMPT_MISSING", `conditional dispatch prompt missing: ${rel}`);
    } else {
      fail("E_DISPATCH_PROMPT_PATH", `${rel}: ${msg}`);
    }
    continue;
  }
  if (!text.includes(playbookDispatchMarker)) {
    fail(
      "E_DISPATCH_SET",
      `manifest dispatch prompt is not marked as a dispatch prompt: ${rel}`
    );
  }
  let effectiveRel = rel;
  let effectiveText = text;
  let overrideRel = null;
  if (entry.kind === "role") {
    overrideRel = localOverrideTemplate.replace("{role}", entry.id);
    try {
      const overrideText = readAuthorityText(rootId, overrideRel);
      effectiveRel = overrideRel;
      effectiveText = overrideText;
    } catch (e) {
      const msg = String(e && e.message ? e.message : e);
      if (isGenuineMissingPath(msg)) {
        overrideRel = null;
      } else {
        fail("E_PATH", `local override ${overrideRel}: ${msg}`);
        overrideRel = null;
      }
    }
    effectiveRoleTexts.set(entry.id, {
      path: effectiveRel,
      corePath: rel,
      text: effectiveText,
      override: Boolean(overrideRel && effectiveRel === overrideRel),
    });
  } else {
    jobTexts.set(entry.id, { path: rel, text: effectiveText });
  }
  const bytes = utf8Bytes(effectiveText);
  const rec = {
    path: effectiveRel,
    kind: entry.kind,
    bytes,
    approxTokens: approxTokens(bytes),
  };
  if (entry.kind === "role") {
    rec.role = entry.id;
    if (effectiveRel !== rel) {
      rec.corePath = rel;
      rec.effective = "local-override";
    } else {
      rec.effective = "core";
    }
  } else {
    rec.job = entry.id;
    rec.effective = "core";
  }
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

const auditRel = CANONICAL_AUDIT;
let audit;
let auditParsed = false;
try {
  audit = loadAuthorityJson(rootId, auditRel);
  auditParsed = true;
} catch (e) {
  fail("E_AUDIT", e.message);
}

let mirror = null;
const mirrorRel = CANONICAL_MIRROR;
try {
  mirror = loadAuthorityJson(rootId, mirrorRel);
} catch (e) {
  fail("E_MIRROR", e.message);
}

const roleContractsRel = CANONICAL_ROLE_CONTRACTS;
const jobContractsRel = CANONICAL_ROLE_CONTRACTS;
let roleContracts = null;
try {
  roleContracts = loadAuthorityJson(rootId, roleContractsRel);
} catch (e) {
  fail("E_ROLE_CONTRACTS", e.message);
}
let jobContracts = roleContracts;
if (jobContractsRel !== roleContractsRel) {
  try {
    jobContracts = loadAuthorityJson(rootId, jobContractsRel);
  } catch (e) {
    fail("E_JOB_CONTRACTS", e.message);
    jobContracts = null;
  }
}
if (roleContracts) {
  if (roleContracts.authority === "report-only" || roleContracts.activated === false) {
    fail(
      "E_ROLE_CONTRACTS",
      `${roleContractsRel} must be an activated machine source (not the report-only #164 candidate)`
    );
  }
  if (roleContracts.designatedBy !== "AGENTS.md") {
    fail(
      "E_ROLE_CONTRACTS",
      `${roleContractsRel} must be designated by AGENTS.md`
    );
  }
  if (!roleContracts.roles || typeof roleContracts.roles !== "object") {
    fail("E_ROLE_CONTRACTS", `${roleContractsRel} missing roles object`);
  }
}

if (agentsText) {
  const canonicalBlock = extractSection(agentsText, "AGENTS.md — The Gibson Operational Contract")
    || agentsText.slice(0, 2500);
  const authorityObj = {
    soleAlwaysMandatory: /sole always-mandatory human-readable/.test(canonicalBlock),
    docsOnDemand: /on-demand and non-normative/.test(agentsText),
    checkedMirror: /checked mirror/.test(agentsText),
    activatedFalse: /activated=false/.test(agentsText),
  };
  for (const [k, v] of Object.entries(authorityObj)) {
    if (!v) fail("E_AUTHORITY", `AGENTS.md missing authority property ${k}`);
  }
  if (/one of several always-mandatory/.test(agentsText) || /not the sole always-mandatory/.test(agentsText)) {
    fail("E_AUTHORITY", "AGENTS.md weakens sole always-mandatory authority");
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

  if (
    typeof cfg.onDemandSectionHeading === "string" &&
    cfg.onDemandSectionHeading !== CANONICAL_ON_DEMAND
  ) {
    fail(
      "E_CONFIG",
      `onDemandSectionHeading must be ${JSON.stringify(CANONICAL_ON_DEMAND)}; got ${JSON.stringify(cfg.onDemandSectionHeading)}`
    );
  }
  const heading = CANONICAL_ON_DEMAND;
  if (!agentsText.includes(`## ${heading}`)) {
    fail("E_ON_DEMAND", `AGENTS.md missing heading ## ${heading}`);
  }
  const requiredRules = CANONICAL_REQUIRED_RULE_PATTERNS;
  const agentsFlat = collapseWs(agentsText);
  for (const p of requiredRules) {
    if (typeof p !== "string" || !p) {
      fail("E_CONFIG", "requiredRulePatterns entries must be non-empty strings");
      continue;
    }
    if (!agentsText.includes(p) && !agentsFlat.includes(collapseWs(p))) {
      fail("E_RULE", `AGENTS.md missing required rule pattern: ${p}`);
    }
  }

  const loadSection = extractSection(agentsText, "Authority and mandatory load");
  const loadHay = loadSection || agentsText;
  const loadFlat = collapseWs(loadHay);
  for (const phrase of CANONICAL_DISCLOSURE_PHRASES) {
    if (!loadHay.includes(phrase) && !loadFlat.includes(collapseWs(phrase))) {
      fail("E_ROLE_DISCLOSURE", `AGENTS.md omits ${phrase}`);
    }
  }
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

  const families = CANONICAL_BINDING_FAMILIES;
  for (const fam of families) {
    if (!fam || typeof fam.id !== "string") continue;
    const sectionName = typeof fam.section === "string" ? fam.section : "";
    const section = sectionName ? extractSection(agentsText, sectionName) : "";
    const expectedItems = Array.isArray(fam.requiredItems) ? fam.requiredItems : [];
    if (sectionName && !section) {
      fail(
        "E_BINDING_FAMILY",
        `AGENTS.md missing binding-family ${fam.id} section: ${sectionName}`
      );
      continue;
    }
    if (expectedItems.length) {
      const got = extractNumberedItems(section);
      if (!listEq(got, expectedItems)) {
        fail(
          "E_BINDING_FAMILY",
          `AGENTS.md binding-family ${fam.id} items ${JSON.stringify(got)} != ${JSON.stringify(expectedItems)}`
        );
      }
    }
    for (const p of Array.isArray(fam.patterns) ? fam.patterns : []) {
      if (typeof p !== "string" || !p) continue;
      if (!agentsText.includes(p) && !collapseWs(agentsText).includes(collapseWs(p))) {
        fail(
          "E_BINDING_FAMILY",
          `AGENTS.md binding-family ${fam.id} omits required statement: ${p}`
        );
      }
    }
    if (section && /\b(optional|advisory|non-binding)\b/i.test(section.split("\n")[0] || "")) {
      fail(
        "E_BINDING_FAMILY",
        `AGENTS.md binding-family ${fam.id} weakened in section heading`
      );
    }
  }

  if (auditParsed) {
    for (const f of diffRuleMigrationAudit(audit)) {
      fail(f.code, f.message);
    }
  }

  for (const f of structuredAgentsEnumerationFindings(agentsText, mirror)) {
    fail(f.code, f.message);
  }

  const implied = findDocsAuthorityClaims(agentsText).filter((h) =>
    /docs\/(03|14)|candidate\.json/.test(h.snippet + h.id)
  );
  for (const hit of implied) {
    fail(
      "E_IMPLIED_BINDING",
      `AGENTS.md still treats a docs/ file or candidate as the contract via: ${hit.id}`
    );
  }
  const forbidden = CANONICAL_FORBIDDEN_CONTRACT_PATTERNS;
  for (const p of forbidden) {
    if (agentsText.includes(p)) {
      fail(
        "E_IMPLIED_BINDING",
        `AGENTS.md still treats a docs/ file or candidate as the contract via: ${p}`
      );
    }
  }

  const sources = CANONICAL_MACHINE_SOURCE_PATHS;
  const sourceTable = extractMarkdownTable(agentsText, [
    "Topic",
    "Authoritative / operational source",
  ]);
  const namedSources = new Set(
    sourceTable.map((r) => r[1].replace(/`/g, "").trim())
  );
  for (const p of sources) {
    if (![...namedSources].some((s) => s.includes(p)) && !agentsText.includes(p)) {
      fail("E_MACHINE_SOURCE", `AGENTS.md does not name canonical source ${p}`);
    }
  }
  if (
    !agentsText.includes(roleContractsRel) ||
    !/activated machine source/.test(agentsText) ||
    !/per-job/.test(agentsText)
  ) {
    fail(
      "E_MACHINE_SOURCE",
      `AGENTS.md must designate ${roleContractsRel} as the activated per-role and per-job contract source`
    );
  }

  const askSection = extractSection(agentsText, "The Ask Contract (how you talk to the user)");
  const askFields = [];
  const askRe = /^\s*\d+\.\s+\*\*([^*]+)\*\*/gm;
  let askM;
  while ((askM = askRe.exec(askSection)) !== null) askFields.push(askM[1].trim());
  if (!listEq(askFields, EXPECTED_ASK_FIELDS)) {
    fail("E_RULE", `AGENTS.md Ask Contract fields ${JSON.stringify(askFields)} != ${JSON.stringify(EXPECTED_ASK_FIELDS)}`);
  }

  const roleSection = extractSection(agentsText, "Your role this session");
  if (!listEq(roleIds, EXPECTED_ROLES)) {
    fail(
      "E_DISPATCH_CONFIG",
      `conditionalDispatchPrompts.roles ${JSON.stringify(roleIds)} != ${JSON.stringify(EXPECTED_ROLES)}`
    );
  }

  const defaultCfg = {
    id: CANONICAL_DEFAULT_ROLE,
    whenUnnamed: true,
    path: CANONICAL_DEFAULT_PATH,
  };
  const defaultId = defaultCfg.id;
  const defaultPath = defaultCfg.path;
  if (defaultId !== CANONICAL_DEFAULT_ROLE || defaultPath !== CANONICAL_DEFAULT_PATH) {
    fail(
      "E_DEFAULT_BUILDER",
      `defaultRole must be id=${CANONICAL_DEFAULT_ROLE} path=${CANONICAL_DEFAULT_PATH}; got ${JSON.stringify(defaultCfg)}`
    );
  }
  const unnamedResolves =
    /If no role is named, the resolved role is `builder`/.test(roleSection) ||
    /If your dispatch prompt doesn't name a role, you are a `builder`/.test(roleSection);
  const builderPlaybookRequired =
    /playbooks\/builder\.md/.test(roleSection + "\n" + (loadSection || "")) &&
    (/conditionally mandatory/.test(roleSection) ||
      /conditionally mandatory/.test(loadSection || "") ||
      /including default assignment/.test(roleSection + (loadSection || "")));
  const skipBuilder =
    /skip\s+`?playbooks\/builder\.md`?/.test(roleSection + (loadSection || "")) ||
    /may skip playbooks\/builder\.md/.test(roleSection + (loadSection || "")) ||
    /builder playbook is optional/.test(roleSection + (loadSection || ""));
  if (defaultId !== "builder" || defaultPath !== "playbooks/builder.md") {
    fail(
      "E_DEFAULT_BUILDER",
      "defaultRole must resolve unnamed roles to builder via playbooks/builder.md"
    );
  }
  if (!unnamedResolves || !builderPlaybookRequired || skipBuilder) {
    fail(
      "E_DEFAULT_BUILDER",
      "AGENTS.md must resolve an unnamed role to builder and make playbooks/builder.md the conditional session-start load"
    );
  }
  if (!closedSeen.has(CANONICAL_DEFAULT_PATH)) {
    fail(
      "E_DEFAULT_BUILDER",
      `default builder dispatch prompt omitted from the closed list: ${CANONICAL_DEFAULT_PATH}`
    );
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
    const prov = mirror.provenance && typeof mirror.provenance === "object"
      ? mirror.provenance
      : null;
    const provSources = prov && Array.isArray(prov.sources) ? prov.sources : [];
    for (const f of provenanceRoleFindings(provSources)) {
      fail(f.code, f.message);
    }
  }
}

function checkRepoAuthorityClaims(rel, text) {
  const hits = findDocsAuthorityClaims(text);
  for (const hit of hits) {
    fail(
      "E_REPO_CLAIM",
      `${rel} implies docs are authority (${hit.id}): ${hit.snippet}`
    );
  }
}

// Forbidden misleading repo claims (README/docs describing docs as the contract).
const repoClaims = CANONICAL_FORBIDDEN_REPO_CLAIMS;
function tryAuthorityText(rel) {
  try {
    return readAuthorityText(rootId, rel);
  } catch (e) {
    const msg = String(e && e.message ? e.message : e);
    if (isGenuineMissingPath(msg)) {
      return null;
    }
    fail("E_PATH", `${rel}: ${msg}`);
    return null;
  }
}

for (const claim of repoClaims) {
  if (!claim || typeof claim.path !== "string") continue;
  const text = tryAuthorityText(claim.path);
  if (text == null) continue;
  const patterns = Array.isArray(claim.patterns) ? claim.patterns : [];
  for (const p of patterns) {
    if (text.includes(p)) {
      fail(
        "E_REPO_CLAIM",
        `${claim.path} still claims binding rules live in docs/playbooks: ${p}`
      );
    }
  }
  checkRepoAuthorityClaims(claim.path, text);
}

for (const extra of ["README.md", "HOW-IT-WORKS.md", "adapters/goose/README.md"]) {
  if (repoClaims.some((c) => c && c.path === extra)) continue;
  const text = tryAuthorityText(extra);
  if (text == null) continue;
  checkRepoAuthorityClaims(extra, text);
}

if (cfg.docsNonNormativeMarker !== CANONICAL_DOCS_MARKER) {
  fail(
    "E_CONFIG",
    `docsNonNormativeMarker must be the contract-defined value; got ${JSON.stringify(cfg.docsNonNormativeMarker ?? null)}`
  );
}
if (cfg.playbookNonNormativeMarker !== CANONICAL_PLAYBOOK_NON_NORM) {
  fail(
    "E_CONFIG",
    `playbookNonNormativeMarker must be the contract-defined value; got ${JSON.stringify(cfg.playbookNonNormativeMarker ?? null)}`
  );
}
const docsMarker = CANONICAL_DOCS_MARKER;
const playbookNonNormativeMarker = CANONICAL_PLAYBOOK_NON_NORM;
const docsGlobs = Array.isArray(cfg.docsNonNormativeGlobs)
  ? cfg.docsNonNormativeGlobs
  : [];
const playbookGlobs = Array.isArray(cfg.playbookGlobs) ? cfg.playbookGlobs : [];
if (!sameStringList(docsGlobs, CANONICAL_DOCS_GLOBS)) {
  fail(
    "E_GLOB",
    `docsNonNormativeGlobs must be ${JSON.stringify(CANONICAL_DOCS_GLOBS)}; got ${JSON.stringify(docsGlobs)}`
  );
}
if (!sameStringList(playbookGlobs, CANONICAL_PLAYBOOK_GLOBS)) {
  fail(
    "E_GLOB",
    `playbookGlobs must be ${JSON.stringify(CANONICAL_PLAYBOOK_GLOBS)}; got ${JSON.stringify(playbookGlobs)}`
  );
}

const markedDocs = [];
const checkedPlaybooks = [];
{
  const docsToCheck = [];
  discoverMdFiles(rootId, "docs", docsToCheck, fail, { optional: true });
  const seenDocs = new Set();
  for (const rel of docsToCheck) {
    if (seenDocs.has(rel)) continue;
    seenDocs.add(rel);
    let text;
    try {
      text = readAuthorityText(rootId, rel);
    } catch (e) {
      fail("E_PATH", `${rel}: ${e.message}`);
      continue;
    }
    if (!text.includes(docsMarker)) {
      fail("E_BANNER", `${rel} missing non-normative marker`);
    } else {
      markedDocs.push(rel);
      const contra = findNonNormativeOperativeContradiction(text, docsMarker);
      for (const hit of contra) {
        fail(
          "E_AUTHORITY_CONTRADICTION",
          `${rel} has a non-normative banner then asserts a closed/authoritative/operative list (${hit.id}): ${hit.snippet}`
        );
      }
    }
  }

  const playbooksToCheck = [];
  discoverMdFiles(rootId, "playbooks", playbooksToCheck, fail, { optional: true });
  const seenPb = new Set();
  for (const rel of playbooksToCheck) {
    if (seenPb.has(rel)) continue;
    seenPb.add(rel);
    let text;
    try {
      text = readAuthorityText(rootId, rel);
    } catch (e) {
      fail("E_PATH", `${rel}: ${e.message}`);
      continue;
    }
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

    const bodyHits = findDocsAuthorityClaims(fm.body || text);
    for (const hit of bodyHits) {
      fail(
        "E_AUTHORITY_CONTRADICTION",
        `${rel} asserts docs as stop/role authority (${hit.id}): ${hit.snippet}`
      );
    }
  }

  if (roleContracts && roleContracts.roles) {
    for (const role of roleIds) {
      if (!Object.prototype.hasOwnProperty.call(roleContracts.roles, role)) {
        fail("E_ROLE_CONTRACTS", `role-contracts missing role ${role}`);
        continue;
      }
      const rec = roleContracts.roles[role];
      for (const bucket of ["outputs", "gates", "forbidden"]) {
        if (!Array.isArray(rec[bucket]) || rec[bucket].length === 0) {
          fail(
            "E_ROLE_CONTRACTS",
            `role-contracts ${role} missing ${bucket} list`
          );
        }
      }
      const loaded = effectiveRoleTexts.get(role);
      if (!loaded) continue;
      const fm = parseFrontmatter(loaded.text);
      const pbBuckets = {
        outputs: parseYamlList(fm.raw, "outputs"),
        gates: parseYamlList(fm.raw, "gates"),
        forbidden: parseYamlList(fm.raw, "forbidden"),
      };
      const authBuckets = {
        outputs: Array.isArray(rec.outputs) ? rec.outputs : [],
        gates: Array.isArray(rec.gates) ? rec.gates : [],
        forbidden: Array.isArray(rec.forbidden) ? rec.forbidden : [],
      };
      for (const diff of diffObligationMatrix(role, authBuckets, pbBuckets)) {
        fail(diff.code, diff.message);
      }
    }
  }

  const jobsObj =
    jobContracts && jobContracts.jobs && typeof jobContracts.jobs === "object"
      ? jobContracts.jobs
      : null;
  if (!jobsObj) {
    fail(
      "E_JOB_CONTRACTS",
      `${jobContractsRel} missing jobs object (activated per-job contract)`
    );
  } else {
    const jobIds = Array.isArray(jobPromptList)
      ? jobPromptList.map((p) => playbookStem(p))
      : [];
    for (const job of jobIds) {
      if (!Object.prototype.hasOwnProperty.call(jobsObj, job)) {
        fail("E_JOB_CONTRACTS", `job-contracts missing job ${job}`);
        continue;
      }
      const rec = jobsObj[job];
      for (const bucket of ["outputs", "gates", "forbidden"]) {
        if (!Array.isArray(rec[bucket]) || rec[bucket].length === 0) {
          fail("E_JOB_CONTRACTS", `job-contracts ${job} missing ${bucket} list`);
        }
      }
      const loaded = jobTexts.get(job);
      if (!loaded) continue;
      const fm = parseFrontmatter(loaded.text);
      const pbBuckets = {
        outputs: parseYamlList(fm.raw, "outputs"),
        gates: parseYamlList(fm.raw, "gates"),
        forbidden: parseYamlList(fm.raw, "forbidden"),
      };
      const authBuckets = {
        outputs: Array.isArray(rec.outputs) ? rec.outputs : [],
        gates: Array.isArray(rec.gates) ? rec.gates : [],
        forbidden: Array.isArray(rec.forbidden) ? rec.forbidden : [],
      };
      for (const diff of remapRoleCodesToJob(
        diffObligationMatrix(job, authBuckets, pbBuckets)
      )) {
        fail(diff.code, diff.message);
      }
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
  defaultRole: {
    id: (cfg.defaultRole && cfg.defaultRole.id) || "builder",
    path: (cfg.defaultRole && cfg.defaultRole.path) || "playbooks/builder.md",
    whenUnnamed: true,
  },
  roleContractsPath: roleContractsRel,
  jobContractsPath: jobContractsRel,
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
      const effective =
        f.effective === "local-override" ? " local-override" : "";
      lines.push(
        `    ${f.path}: ${f.bytes} bytes (~${f.approxTokens} tokens) [${label}${effective}]`
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
  if (parsed.measureOnly && findings.length === 0) {
    console.log(lines.join("\n"));
    return;
  }
  if (findings.length === 0) {
    lines.push("contract-authority: OK — authority boundary and budget hold");
    console.log(lines.join("\n"));
  } else {
    if (parsed.measureOnly) {
      lines.push(`contract-authority: FAIL — ${findings.length} finding(s)`);
    } else {
      lines.push(`contract-authority: FAIL — ${findings.length} finding(s)`);
    }
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

  return {
    report,
    findings,
    exitCode: findings.length === 0 ? 0 : 1,
  };
}

if (isCliMain()) {
  const result = main();
  process.exit(result.exitCode);
}
