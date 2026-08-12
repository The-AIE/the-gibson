#!/usr/bin/env node
/**
 * policy-manifest.mjs — report-only policy-manifest v1 validator (#188)
 *
 * WHAT IT DOES
 *   Validates a frozen policy-manifest candidate offline, emits a byte-stable
 *   JSON report plus concise human text, and optionally checks selected
 *   doctrine identifiers/tables for drift. Report-only: never activates policy,
 *   never rewrites doctrine, never claims merge authority.
 *
 * WHY
 *   Parent #164 needs a behavior-preserving representation of approved
 *   semantics (gates, tiers, roles, forbidden pairs, review independence,
 *   stages) with provenance before any generated view or runtime consumer
 *   migrates.
 *
 * RISKS
 *   - Consistency checks are report sensors; they do not change CI enforcement
 *     outside the focused suite that opts into them.
 *   - Digests pin the doctrine snapshot this candidate was encoded from; a
 *     later doctrine edit surfaces as drift, not silent authority.
 *   - Pure Node only: no network, model, shell subprocess, secrets, or deps.
 *
 * USAGE
 *   node scripts/policy-manifest.mjs validate [--manifest PATH] [--repo-root PATH]
 *   node scripts/policy-manifest.mjs report [--manifest PATH] [--format json|text|both]
 *   node scripts/policy-manifest.mjs check-consistency [--manifest PATH]
 *   node scripts/policy-manifest.mjs digest --path RELATIVE_PATH [--repo-root PATH]
 *   node scripts/policy-manifest.mjs --help
 */

import { createHash } from "node:crypto";
import {
  existsSync,
  readFileSync,
  realpathSync,
  statSync,
} from "node:fs";
import { dirname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

// ---------------------------------------------------------------------------
// Constants (pinned versions for this pure validator)
// ---------------------------------------------------------------------------

export const VALIDATOR_VERSION = "1.0.0";
export const SUPPORTED_SCHEMA_ID = "gibson.policy.manifest.schema.v1";
export const SUPPORTED_SCHEMA_MAJOR = 1;

const REQUIRED_GATE_IDS = Array.from({ length: 16 }, (_, i) => `G${i + 1}`);
const REQUIRED_ROLE_IDS = [
  "planner",
  "decomposer",
  "builder",
  "test-engineer",
  "reviewer",
  "ux-evaluator",
  "security",
  "release",
  "historian",
];
const REQUIRED_TIER_IDS = ["A", "B", "C"];
const REQUIRED_STAGE_IDS = [
  "plan",
  "decompose",
  "build",
  "test",
  "review",
  "ux-eval",
  "security",
  "merge",
  "deploy",
  "retro",
];
const REQUIRED_FORBIDDEN_PAIRS = [
  ["builder", "reviewer"],
  ["builder", "ux-evaluator"],
  ["reviewer", "ux-evaluator"],
];
/** Closed core reviewIndependence id set (schema parity; unknown IDs fail closed). */
const ALLOWED_RI_IDS = ["ri.law5", "ri.tier-a", "ri.tier-b", "ri.tier-c"];
const REQUIRED_RI_IDS = ALLOWED_RI_IDS.slice();

/** additionalProperties:false parity — allowed keys per object shape. */
const ALLOWED_ROOT_KEYS = new Set([
  "schemaId",
  "schemaVersion",
  "manifestId",
  "manifestVersion",
  "status",
  "authority",
  "activated",
  "generatorVersion",
  "validatorVersion",
  "compatibility",
  "provenance",
  "humanGates",
  "riskTiers",
  "roles",
  "forbiddenRolePairs",
  "reviewIndependence",
  "workflowStages",
  "tierGateMappings",
  "forkExtensions",
  "notices",
]);
const ALLOWED_COMPAT_KEYS = new Set([
  "policy",
  "forkExtensionRule",
  "coreIdPrefix",
  "upgrade",
  "rollback",
  "notes",
]);
const ALLOWED_PROVENANCE_KEYS = new Set(["sources"]);
const ALLOWED_SOURCE_KEYS = new Set([
  "id",
  "path",
  "digestAlgorithm",
  "digest",
  "role",
]);
const ALLOWED_GATE_KEYS = new Set([
  "id",
  "category",
  "summary",
  "severity",
  "relatedTierIds",
]);
const ALLOWED_TIER_KEYS = new Set(["id", "definition", "evidenceMinimums"]);
const ALLOWED_EVIDENCE_KEYS = new Set([
  "reviewDepth",
  "adversarialReview",
  "humanMergeGate",
  "humanGateIds",
  "uxEvalIfVisible",
  "serializedWhenStateful",
  "crossVendorPreferred",
]);
const ALLOWED_ROLE_KEYS = new Set(["id", "summary"]);
const ALLOWED_PAIR_KEYS = new Set(["a", "b", "scope", "symmetric", "rationale"]);
const ALLOWED_RI_KEYS = new Set([
  "id",
  "description",
  "tierId",
  "minimumRelationship",
  "preferredRelationship",
  "humanGateId",
  "generatorMustNotEqual",
]);
const ALLOWED_STAGE_KEYS = new Set(["id", "order", "name", "roleId"]);
const ALLOWED_TGM_KEYS = new Set(["tierId", "gateIds", "rationale"]);
const ALLOWED_FORK_KEYS = new Set([
  "allowedNamespaces",
  "forbiddenCoreShadow",
  "precedence",
  "conflictDisposition",
]);
const ALLOWED_NOTICES_KEYS = new Set([
  "authority",
  "activationOwner",
  "generatedViews",
]);

const CORE_ID_PREFIX = "gibson.";
const SAFE_REL_PATH = /^[a-zA-Z0-9][a-zA-Z0-9._/-]*$/;
const SHA256_HEX = /^[a-f0-9]{64}$/;
const GATE_ID_RE = /^G([1-9]|1[0-6])$/;
const DEFAULT_MANIFEST_REL =
  "config/policy/candidates/gibson-core-v1.candidate.json";
const DEFAULT_SCHEMA_REL =
  "config/policy/schema/policy-manifest-v1.schema.json";

// Doctrine identifier extraction patterns (report-only consistency).
const DOCTRINE_GATE_RE = /\*\*G([1-9]|1[0-6])\*\*/g;
const DOCTRINE_ROLE_HEADING_RE =
  /^## (planner|decomposer|builder|test-engineer|reviewer|ux-evaluator|security|release|historian)\s*$/gm;

// ---------------------------------------------------------------------------
// Path / IO helpers — pure fs, no subprocess
// ---------------------------------------------------------------------------

function scriptDir() {
  return dirname(fileURLToPath(import.meta.url));
}

function defaultRepoRoot() {
  return resolve(scriptDir(), "..");
}

/**
 * Resolve a path under repoRoot. Refuse absolute escapes and `..` segments
 * that leave the root. When the path exists (including as a symlink), also
 * require that realpath(path) stays inside the real repo root so a
 * repository-relative symlink cannot escape for later stat/hash/read.
 * Fail closed.
 *
 * @param {string} repoRoot
 * @param {string} relPath
 * @returns {string} absolute path suitable for read/stat/hash (realpath when the entry exists)
 */
export function resolveUnderRoot(repoRoot, relPath) {
  if (typeof relPath !== "string" || !relPath) {
    throw new Error("path: empty");
  }
  if (isAbsolute(relPath) || relPath.includes("\0")) {
    throw new Error(`path: absolute or unsafe: ${relPath}`);
  }
  const norm = normalize(relPath);
  if (norm.startsWith("..") || norm.split(sep).includes("..")) {
    throw new Error(`path: escapes repo root: ${relPath}`);
  }
  if (!SAFE_REL_PATH.test(norm.replace(/\\/g, "/"))) {
    throw new Error(`path: malformed relative path: ${relPath}`);
  }
  let rootReal;
  try {
    rootReal = realpathSync(repoRoot);
  } catch (e) {
    throw new Error(`path: cannot realpath repo root: ${e.message}`);
  }
  // Ensure root is a directory (not a symlink-to-file, etc.)
  try {
    if (!statSync(rootReal).isDirectory()) {
      throw new Error("path: repo root is not a directory");
    }
  } catch (e) {
    if (e.message && e.message.startsWith("path:")) throw e;
    throw new Error(`path: cannot stat repo root: ${e.message}`);
  }

  const abs = resolve(rootReal, norm);
  const rel = relative(rootReal, abs);
  if (rel.startsWith("..") || isAbsolute(rel)) {
    throw new Error(`path: resolves outside repo root: ${relPath}`);
  }

  // Lexical containment is not enough: if any path component is a symlink,
  // subsequent readFile/stat/hash follow it. Refuse realpath escape.
  if (existsSync(abs)) {
    let real;
    try {
      real = realpathSync(abs);
    } catch (e) {
      throw new Error(`path: cannot realpath ${relPath}: ${e.message}`);
    }
    const relReal = relative(rootReal, real);
    if (relReal.startsWith("..") || isAbsolute(relReal)) {
      throw new Error(
        `path: realpath escapes repo root (symlink or link chain): ${relPath}`
      );
    }
    // Return the contained real path so callers hash/read the verified target.
    return real;
  }
  return abs;
}

/**
 * Hash a file only after proving its realpath stays under repoRoot when a
 * root is supplied. Absolute paths from resolveUnderRoot already satisfy this.
 */
export function sha256File(absPath, repoRoot) {
  let target = absPath;
  if (repoRoot) {
    // Re-assert realpath containment for any absolute path handed in.
    let rootReal;
    try {
      rootReal = realpathSync(repoRoot);
    } catch (e) {
      throw new Error(`path: cannot realpath repo root: ${e.message}`);
    }
    let real;
    try {
      real = realpathSync(absPath);
    } catch (e) {
      throw new Error(`path: cannot realpath for hash: ${e.message}`);
    }
    const relReal = relative(rootReal, real);
    if (relReal.startsWith("..") || isAbsolute(relReal)) {
      throw new Error(
        `path: hash target realpath escapes repo root: ${absPath}`
      );
    }
    target = real;
  }
  const buf = readFileSync(target);
  return createHash("sha256").update(buf).digest("hex");
}

export function sha256Text(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/**
 * Deterministic JSON: sorted object keys, arrays preserved, stable separators.
 */
export function stableStringify(value) {
  return JSON.stringify(sortKeys(value), null, 2) + "\n";
}

function sortKeys(value) {
  if (Array.isArray(value)) {
    return value.map(sortKeys);
  }
  if (value && typeof value === "object" && !(value instanceof Date)) {
    const out = {};
    for (const k of Object.keys(value).sort()) {
      out[k] = sortKeys(value[k]);
    }
    return out;
  }
  return value;
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

// ---------------------------------------------------------------------------
// Findings
// ---------------------------------------------------------------------------

/**
 * @typedef {{ code: string, severity: 'error'|'warning'|'info', message: string, path?: string }} Finding
 */

function err(code, message, path) {
  /** @type {Finding} */
  const f = { code, severity: "error", message };
  if (path) f.path = path;
  return f;
}

function warn(code, message, path) {
  /** @type {Finding} */
  const f = { code, severity: "warning", message };
  if (path) f.path = path;
  return f;
}

function info(code, message, path) {
  /** @type {Finding} */
  const f = { code, severity: "info", message };
  if (path) f.path = path;
  return f;
}

function sortFindings(findings) {
  return findings.slice().sort((a, b) => {
    const se = { error: 0, warning: 1, info: 2 };
    const ds = (se[a.severity] ?? 9) - (se[b.severity] ?? 9);
    if (ds !== 0) return ds;
    const dc = a.code.localeCompare(b.code);
    if (dc !== 0) return dc;
    return (a.path || "").localeCompare(b.path || "") ||
      a.message.localeCompare(b.message);
  });
}

/**
 * Schema parity: additionalProperties:false. Unknown keys are errors.
 * @param {Record<string, unknown>} obj
 * @param {Set<string>} allowed
 * @param {string} pathPrefix empty for root
 * @param {(f: Finding) => void} push
 */
function rejectUnknownKeys(obj, allowed, pathPrefix, push) {
  for (const k of Object.keys(obj)) {
    if (!allowed.has(k)) {
      const loc = pathPrefix ? `${pathPrefix}.${k}` : k;
      push(
        err(
          "E_UNKNOWN_PROPERTY",
          `unknown property '${k}' (schema additionalProperties:false)`,
          loc
        )
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Structural + semantic validation (fail closed)
// ---------------------------------------------------------------------------

/**
 * Validate a candidate object. Pure — does not read the filesystem unless
 * `options.checkProvenanceDigests` is true (then uses options.repoRoot).
 *
 * @param {unknown} candidate
 * @param {{
 *   repoRoot?: string,
 *   checkProvenanceDigests?: boolean,
 *   expectedValidatorVersion?: string,
 * }} [options]
 * @returns {Finding[]}
 */
export function validateCandidate(candidate, options = {}) {
  /** @type {Finding[]} */
  const findings = [];
  const push = (f) => findings.push(f);

  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
    push(err("E_ROOT_TYPE", "candidate must be a JSON object"));
    return sortFindings(findings);
  }

  /** @type {Record<string, unknown>} */
  const c = /** @type {Record<string, unknown>} */ (candidate);

  // Schema parity: refuse unknown root controls before field checks.
  rejectUnknownKeys(c, ALLOWED_ROOT_KEYS, "", push);

  // --- identity / versions / authority ------------------------------------
  if (c.schemaId !== SUPPORTED_SCHEMA_ID) {
    push(
      err(
        "E_UNSUPPORTED_SCHEMA_ID",
        `unsupported schemaId ${JSON.stringify(c.schemaId)}; expected ${SUPPORTED_SCHEMA_ID}`,
        "schemaId"
      )
    );
  }
  if (typeof c.schemaVersion !== "string" || !/^\d+\.\d+\.\d+$/.test(c.schemaVersion)) {
    push(err("E_SCHEMA_VERSION_MALFORMED", "schemaVersion must be semver MAJOR.MINOR.PATCH", "schemaVersion"));
  } else {
    const major = Number(c.schemaVersion.split(".")[0]);
    if (major !== SUPPORTED_SCHEMA_MAJOR) {
      push(
        err(
          "E_UNSUPPORTED_VERSION",
          `unsupported schemaVersion major ${major}; this validator supports major ${SUPPORTED_SCHEMA_MAJOR} only`,
          "schemaVersion"
        )
      );
    }
  }
  if (typeof c.manifestId !== "string" || !/^[a-z][a-z0-9.-]*$/.test(c.manifestId)) {
    push(err("E_MANIFEST_ID", "manifestId missing or malformed", "manifestId"));
  }
  if (typeof c.manifestVersion !== "string" || !/^\d+\.\d+\.\d+$/.test(c.manifestVersion)) {
    push(err("E_MANIFEST_VERSION", "manifestVersion must be semver", "manifestVersion"));
  }
  if (c.status !== "candidate" && c.status !== "draft" && c.status !== "superseded") {
    push(err("E_STATUS", "status must be candidate|draft|superseded", "status"));
  }
  if (c.authority !== "report-only") {
    push(
      err(
        "E_AUTHORITY",
        "authority must be the constant 'report-only' for this slice; candidate must not claim activated authority",
        "authority"
      )
    );
  }
  if (c.activated !== false) {
    push(
      err(
        "E_ACTIVATED",
        "activated must be false; activation is owned by #164 and is out of scope for this report-only candidate",
        "activated"
      )
    );
  }
  if (typeof c.generatorVersion !== "string" || !/^\d+\.\d+\.\d+$/.test(c.generatorVersion)) {
    push(err("E_GENERATOR_VERSION", "generatorVersion must be semver", "generatorVersion"));
  }
  if (typeof c.validatorVersion !== "string" || !/^\d+\.\d+\.\d+$/.test(c.validatorVersion)) {
    push(err("E_VALIDATOR_VERSION", "validatorVersion must be semver", "validatorVersion"));
  } else if (
    options.expectedValidatorVersion &&
    c.validatorVersion !== options.expectedValidatorVersion
  ) {
    push(
      err(
        "E_VALIDATOR_VERSION_MISMATCH",
        `candidate validatorVersion ${c.validatorVersion} does not match running validator ${options.expectedValidatorVersion}`,
        "validatorVersion"
      )
    );
  }

  // --- compatibility ------------------------------------------------------
  const compat = c.compatibility;
  if (!compat || typeof compat !== "object" || Array.isArray(compat)) {
    push(err("E_COMPAT", "compatibility object required", "compatibility"));
  } else {
    const k = /** @type {Record<string, unknown>} */ (compat);
    rejectUnknownKeys(k, ALLOWED_COMPAT_KEYS, "compatibility", push);
    if (k.policy !== "semver-major-break") {
      push(err("E_COMPAT_POLICY", "compatibility.policy must be semver-major-break", "compatibility.policy"));
    }
    if (k.forkExtensionRule !== "namespaced-only") {
      push(
        err(
          "E_COMPAT_FORK_RULE",
          "compatibility.forkExtensionRule must be namespaced-only",
          "compatibility.forkExtensionRule"
        )
      );
    }
    if (k.coreIdPrefix !== CORE_ID_PREFIX) {
      push(
        err(
          "E_COMPAT_CORE_PREFIX",
          `compatibility.coreIdPrefix must be ${CORE_ID_PREFIX}`,
          "compatibility.coreIdPrefix"
        )
      );
    }
    for (const field of ["upgrade", "rollback", "notes"]) {
      if (typeof k[field] !== "string" || !k[field]) {
        push(err("E_COMPAT_FIELD", `compatibility.${field} must be a non-empty string`, `compatibility.${field}`));
      }
    }
  }

  // --- provenance ---------------------------------------------------------
  /** @type {Set<string>} */
  const sourceIds = new Set();
  const prov = c.provenance;
  if (!prov || typeof prov !== "object" || Array.isArray(prov)) {
    push(err("E_PROVENANCE", "provenance object required", "provenance"));
  } else {
    rejectUnknownKeys(
      /** @type {Record<string, unknown>} */ (prov),
      ALLOWED_PROVENANCE_KEYS,
      "provenance",
      push
    );
    const sources = /** @type {Record<string, unknown>} */ (prov).sources;
    if (!Array.isArray(sources) || sources.length === 0) {
      push(err("E_PROVENANCE_SOURCES", "provenance.sources must be a non-empty array", "provenance.sources"));
    } else {
      sources.forEach((src, i) => {
        const p = `provenance.sources[${i}]`;
        if (!src || typeof src !== "object" || Array.isArray(src)) {
          push(err("E_PROVENANCE_ITEM", "source entry must be an object", p));
          return;
        }
        const s = /** @type {Record<string, unknown>} */ (src);
        rejectUnknownKeys(s, ALLOWED_SOURCE_KEYS, p, push);
        if (typeof s.id !== "string" || !/^src\.[a-z0-9.-]+$/.test(s.id)) {
          push(err("E_PROVENANCE_ID", "source id malformed", `${p}.id`));
        } else if (sourceIds.has(s.id)) {
          push(err("E_DUPLICATE_ID", `duplicate provenance source id ${s.id}`, `${p}.id`));
        } else {
          sourceIds.add(s.id);
        }
        if (typeof s.path !== "string" || !SAFE_REL_PATH.test(s.path) || s.path.includes("..")) {
          push(err("E_PROVENANCE_PATH", "source path must be a safe repo-relative path", `${p}.path`));
        }
        if (s.digestAlgorithm !== "sha256") {
          push(err("E_PROVENANCE_ALG", "digestAlgorithm must be sha256", `${p}.digestAlgorithm`));
        }
        if (typeof s.digest !== "string" || !SHA256_HEX.test(s.digest)) {
          push(
            err(
              "E_PROVENANCE_DIGEST",
              "digest must be 64-char lowercase hex sha256",
              `${p}.digest`
            )
          );
        }
        if (
          s.role !== "canonical-doctrine" &&
          s.role !== "compatibility-doctrine" &&
          s.role !== "supporting"
        ) {
          push(err("E_PROVENANCE_ROLE", "source role unknown", `${p}.role`));
        }

        if (
          options.checkProvenanceDigests &&
          options.repoRoot &&
          typeof s.path === "string" &&
          typeof s.digest === "string" &&
          SHA256_HEX.test(s.digest) &&
          SAFE_REL_PATH.test(s.path) &&
          !s.path.includes("..")
        ) {
          try {
            const abs = resolveUnderRoot(options.repoRoot, s.path);
            if (!existsSync(abs) || !statSync(abs).isFile()) {
              push(err("E_PROVENANCE_MISSING_FILE", `source file missing: ${s.path}`, `${p}.path`));
            } else {
              const live = sha256File(abs, options.repoRoot);
              if (live !== s.digest) {
                push(
                  err(
                    "E_PROVENANCE_DIGEST_MISMATCH",
                    `source digest drift for ${s.path}: candidate=${s.digest} live=${live}`,
                    `${p}.digest`
                  )
                );
              }
            }
          } catch (e) {
            // Symlink escape / path refusal — fail closed (not a soft warning).
            const msg = e && e.message ? e.message : String(e);
            if (/realpath escapes|symlink/i.test(msg)) {
              push(err("E_PROVENANCE_PATH_ESCAPE", msg, `${p}.path`));
            } else {
              push(err("E_PROVENANCE_PATH", msg, `${p}.path`));
            }
          }
        }
      });
    }
  }

  // --- human gates --------------------------------------------------------
  /** @type {Set<string>} */
  const gateIds = new Set();
  if (!Array.isArray(c.humanGates)) {
    push(err("E_GATES_TYPE", "humanGates must be an array", "humanGates"));
  } else {
    c.humanGates.forEach((g, i) => {
      const p = `humanGates[${i}]`;
      if (!g || typeof g !== "object" || Array.isArray(g)) {
        push(err("E_GATE_ITEM", "gate must be an object", p));
        return;
      }
      const gate = /** @type {Record<string, unknown>} */ (g);
      rejectUnknownKeys(gate, ALLOWED_GATE_KEYS, p, push);
      if (typeof gate.id !== "string" || !GATE_ID_RE.test(gate.id)) {
        push(err("E_GATE_ID", `unknown or malformed gate id ${JSON.stringify(gate.id)}`, `${p}.id`));
      } else if (gateIds.has(gate.id)) {
        push(err("E_DUPLICATE_ID", `duplicate gate id ${gate.id}`, `${p}.id`));
      } else {
        gateIds.add(gate.id);
      }
      if (typeof gate.category !== "string" || !gate.category) {
        push(err("E_GATE_CATEGORY", "gate category required", `${p}.category`));
      }
      if (typeof gate.summary !== "string" || !gate.summary) {
        push(err("E_GATE_SUMMARY", "gate summary required", `${p}.summary`));
      }
      if (typeof gate.severity !== "boolean") {
        push(err("E_GATE_SEVERITY", "gate severity must be boolean", `${p}.severity`));
      }
      if (gate.relatedTierIds !== undefined) {
        if (!Array.isArray(gate.relatedTierIds)) {
          push(err("E_GATE_TIERS", "relatedTierIds must be an array", `${p}.relatedTierIds`));
        } else {
          for (const t of gate.relatedTierIds) {
            if (!REQUIRED_TIER_IDS.includes(/** @type {string} */ (t))) {
              push(err("E_UNKNOWN_ID", `unknown tier id ${t} on gate`, `${p}.relatedTierIds`));
            }
          }
        }
      }
    });
    for (const need of REQUIRED_GATE_IDS) {
      if (!gateIds.has(need)) {
        push(err("E_GATE_MISSING", `required human gate ${need} is missing`, "humanGates"));
      }
    }
    // Closed list: no extras beyond G1-G16 in core candidate encoding.
    for (const id of gateIds) {
      if (!REQUIRED_GATE_IDS.includes(id)) {
        push(err("E_UNKNOWN_ID", `unknown gate id ${id} (core list is G1-G16)`, "humanGates"));
      }
    }
    // Severity pins for G15/G16
    const byId = new Map(
      (/** @type {unknown[]} */ (c.humanGates))
        .filter((x) => x && typeof x === "object")
        .map((x) => {
          const o = /** @type {Record<string, unknown>} */ (x);
          return [o.id, o];
        })
    );
    for (const haltId of ["G15", "G16"]) {
      const g = byId.get(haltId);
      if (g && g.severity !== true) {
        push(
          err(
            "E_GATE_HALT",
            `${haltId} must have severity=true (docs/14 halt gates)`,
            "humanGates"
          )
        );
      }
    }
  }

  // --- risk tiers ---------------------------------------------------------
  /** @type {Set<string>} */
  const tierIds = new Set();
  /** @type {Map<string, Record<string, unknown>>} */
  const tierById = new Map();
  if (!Array.isArray(c.riskTiers)) {
    push(err("E_TIERS_TYPE", "riskTiers must be an array", "riskTiers"));
  } else {
    c.riskTiers.forEach((t, i) => {
      const p = `riskTiers[${i}]`;
      if (!t || typeof t !== "object" || Array.isArray(t)) {
        push(err("E_TIER_ITEM", "tier must be an object", p));
        return;
      }
      const tier = /** @type {Record<string, unknown>} */ (t);
      rejectUnknownKeys(tier, ALLOWED_TIER_KEYS, p, push);
      if (!REQUIRED_TIER_IDS.includes(/** @type {string} */ (tier.id))) {
        push(err("E_UNKNOWN_ID", `unknown tier id ${JSON.stringify(tier.id)}`, `${p}.id`));
      } else if (tierIds.has(/** @type {string} */ (tier.id))) {
        push(err("E_DUPLICATE_ID", `duplicate tier id ${tier.id}`, `${p}.id`));
      } else {
        tierIds.add(/** @type {string} */ (tier.id));
        tierById.set(/** @type {string} */ (tier.id), tier);
      }
      if (typeof tier.definition !== "string" || !tier.definition) {
        push(err("E_TIER_DEF", "tier definition required", `${p}.definition`));
      }
      const em = tier.evidenceMinimums;
      if (!em || typeof em !== "object" || Array.isArray(em)) {
        push(err("E_TIER_EVIDENCE", "evidenceMinimums object required", `${p}.evidenceMinimums`));
      } else {
        const e = /** @type {Record<string, unknown>} */ (em);
        rejectUnknownKeys(e, ALLOWED_EVIDENCE_KEYS, `${p}.evidenceMinimums`, push);
        const depths = ["solo", "full-lens", "fan-out"];
        if (!depths.includes(/** @type {string} */ (e.reviewDepth))) {
          push(err("E_TIER_REVIEW_DEPTH", "reviewDepth invalid", `${p}.evidenceMinimums.reviewDepth`));
        }
        if (typeof e.adversarialReview !== "boolean") {
          push(err("E_TIER_ADV", "adversarialReview must be boolean", `${p}.evidenceMinimums.adversarialReview`));
        }
        if (typeof e.humanMergeGate !== "boolean") {
          push(err("E_TIER_HUMAN", "humanMergeGate must be boolean", `${p}.evidenceMinimums.humanMergeGate`));
        }
        if (e.humanGateIds !== undefined) {
          if (!Array.isArray(e.humanGateIds)) {
            push(err("E_TIER_GATE_IDS", "humanGateIds must be an array", `${p}.evidenceMinimums.humanGateIds`));
          } else {
            for (const gid of e.humanGateIds) {
              if (typeof gid !== "string" || !GATE_ID_RE.test(gid)) {
                push(err("E_UNKNOWN_ID", `unknown gate id ${gid} in tier evidence`, `${p}.evidenceMinimums.humanGateIds`));
              } else if (gateIds.size && !gateIds.has(gid)) {
                push(err("E_BROKEN_REF", `tier references missing gate ${gid}`, `${p}.evidenceMinimums.humanGateIds`));
              }
            }
          }
        }
      }
    });
    for (const need of REQUIRED_TIER_IDS) {
      if (!tierIds.has(need)) {
        push(err("E_TIER_MISSING", `required tier ${need} is missing`, "riskTiers"));
      }
    }
    // Evidence minimum monotonicity (current approved semantics, docs/06):
    // A: solo, no adversarial, no human merge
    // B: full-lens, no adversarial, no human merge
    // C: fan-out, adversarial, human merge + G12
    const a = tierById.get("A");
    const b = tierById.get("B");
    const cTier = tierById.get("C");
    if (a?.evidenceMinimums) {
      const e = /** @type {Record<string, unknown>} */ (a.evidenceMinimums);
      if (e.reviewDepth !== "solo" || e.adversarialReview !== false || e.humanMergeGate !== false) {
        push(
          err(
            "E_TIER_EVIDENCE_CONTRADICTION",
            "Tier A evidence must be solo review, adversarialReview=false, humanMergeGate=false",
            "riskTiers"
          )
        );
      }
    }
    if (b?.evidenceMinimums) {
      const e = /** @type {Record<string, unknown>} */ (b.evidenceMinimums);
      if (e.reviewDepth !== "full-lens" || e.adversarialReview !== false || e.humanMergeGate !== false) {
        push(
          err(
            "E_TIER_EVIDENCE_CONTRADICTION",
            "Tier B evidence must be full-lens, adversarialReview=false, humanMergeGate=false",
            "riskTiers"
          )
        );
      }
    }
    if (cTier?.evidenceMinimums) {
      const e = /** @type {Record<string, unknown>} */ (cTier.evidenceMinimums);
      if (e.reviewDepth !== "fan-out" || e.adversarialReview !== true || e.humanMergeGate !== true) {
        push(
          err(
            "E_TIER_EVIDENCE_CONTRADICTION",
            "Tier C evidence must be fan-out, adversarialReview=true, humanMergeGate=true",
            "riskTiers"
          )
        );
      }
      const gids = Array.isArray(e.humanGateIds) ? e.humanGateIds : [];
      if (!gids.includes("G12")) {
        push(
          err(
            "E_TIER_GATE_MAPPING",
            "Tier C humanGateIds must include G12",
            "riskTiers"
          )
        );
      }
    }
  }

  // --- roles --------------------------------------------------------------
  /** @type {Set<string>} */
  const roleIds = new Set();
  if (!Array.isArray(c.roles)) {
    push(err("E_ROLES_TYPE", "roles must be an array", "roles"));
  } else {
    c.roles.forEach((r, i) => {
      const p = `roles[${i}]`;
      if (!r || typeof r !== "object" || Array.isArray(r)) {
        push(err("E_ROLE_ITEM", "role must be an object", p));
        return;
      }
      const role = /** @type {Record<string, unknown>} */ (r);
      rejectUnknownKeys(role, ALLOWED_ROLE_KEYS, p, push);
      if (!REQUIRED_ROLE_IDS.includes(/** @type {string} */ (role.id))) {
        push(err("E_UNKNOWN_ID", `unknown role id ${JSON.stringify(role.id)}`, `${p}.id`));
      } else if (roleIds.has(/** @type {string} */ (role.id))) {
        push(err("E_DUPLICATE_ID", `duplicate role id ${role.id}`, `${p}.id`));
      } else {
        roleIds.add(/** @type {string} */ (role.id));
      }
      if (typeof role.summary !== "string" || !role.summary) {
        push(err("E_ROLE_SUMMARY", "role summary required", `${p}.summary`));
      }
    });
    for (const need of REQUIRED_ROLE_IDS) {
      if (!roleIds.has(need)) {
        push(err("E_ROLE_MISSING", `required role ${need} is missing`, "roles"));
      }
    }
  }

  // --- forbidden role pairs -----------------------------------------------
  /** @type {Set<string>} */
  const pairKeys = new Set();
  if (!Array.isArray(c.forbiddenRolePairs)) {
    push(err("E_PAIRS_TYPE", "forbiddenRolePairs must be an array", "forbiddenRolePairs"));
  } else {
    c.forbiddenRolePairs.forEach((pair, i) => {
      const p = `forbiddenRolePairs[${i}]`;
      if (!pair || typeof pair !== "object" || Array.isArray(pair)) {
        push(err("E_PAIR_ITEM", "pair must be an object", p));
        return;
      }
      const fp = /** @type {Record<string, unknown>} */ (pair);
      rejectUnknownKeys(fp, ALLOWED_PAIR_KEYS, p, push);
      if (typeof fp.a !== "string" || (roleIds.size && !roleIds.has(fp.a))) {
        push(err("E_BROKEN_REF", `forbidden pair.a unknown role ${JSON.stringify(fp.a)}`, `${p}.a`));
      }
      if (typeof fp.b !== "string" || (roleIds.size && !roleIds.has(fp.b))) {
        push(err("E_BROKEN_REF", `forbidden pair.b unknown role ${JSON.stringify(fp.b)}`, `${p}.b`));
      }
      if (fp.a === fp.b) {
        push(err("E_PAIR_SELF", "forbidden pair cannot reference the same role twice", p));
      }
      if (fp.scope !== "same-unit-of-work") {
        push(err("E_PAIR_SCOPE", "scope must be same-unit-of-work", `${p}.scope`));
      }
      if (typeof fp.symmetric !== "boolean") {
        push(err("E_PAIR_SYM_TYPE", "symmetric must be boolean", `${p}.symmetric`));
      }
      if (typeof fp.rationale !== "string" || !fp.rationale) {
        push(err("E_PAIR_RATIONALE", "rationale required", `${p}.rationale`));
      }
      if (typeof fp.a === "string" && typeof fp.b === "string") {
        const canon = [fp.a, fp.b].slice().sort().join("|");
        if (pairKeys.has(canon)) {
          push(err("E_DUPLICATE_ID", `duplicate forbidden pair ${canon}`, p));
        } else {
          pairKeys.add(canon);
        }
        // Asymmetry: if symmetric=false, require the reverse edge also listed.
        if (fp.symmetric === false) {
          const hasReverse = (/** @type {unknown[]} */ (c.forbiddenRolePairs)).some((other) => {
            if (!other || typeof other !== "object") return false;
            const o = /** @type {Record<string, unknown>} */ (other);
            return o.a === fp.b && o.b === fp.a;
          });
          if (!hasReverse) {
            push(
              err(
                "E_PAIR_ASYMMETRY",
                `forbidden pair ${fp.a}->${fp.b} is asymmetric without reverse edge`,
                p
              )
            );
          }
        }
      }
    });
    for (const [a, b] of REQUIRED_FORBIDDEN_PAIRS) {
      const canon = [a, b].slice().sort().join("|");
      if (!pairKeys.has(canon)) {
        push(
          err(
            "E_PAIR_REQUIRED",
            `required forbidden role pair missing: ${a} ↔ ${b}`,
            "forbiddenRolePairs"
          )
        );
      }
    }
  }

  // --- review independence ------------------------------------------------
  /** @type {Set<string>} */
  const riIds = new Set();
  if (!Array.isArray(c.reviewIndependence)) {
    push(err("E_RI_TYPE", "reviewIndependence must be an array", "reviewIndependence"));
  } else {
    c.reviewIndependence.forEach((ri, i) => {
      const p = `reviewIndependence[${i}]`;
      if (!ri || typeof ri !== "object" || Array.isArray(ri)) {
        push(err("E_RI_ITEM", "reviewIndependence entry must be an object", p));
        return;
      }
      const r = /** @type {Record<string, unknown>} */ (ri);
      rejectUnknownKeys(r, ALLOWED_RI_KEYS, p, push);
      if (typeof r.id !== "string" || !/^ri\.[a-z0-9.-]+$/.test(r.id)) {
        push(err("E_RI_ID", "reviewIndependence id malformed", `${p}.id`));
      } else if (!ALLOWED_RI_IDS.includes(r.id)) {
        // Closed set: ri.unknown and any non-core id fail closed.
        push(
          err(
            "E_RI_UNKNOWN_ID",
            `unknown reviewIndependence id ${r.id}; allowed: ${ALLOWED_RI_IDS.join(", ")}`,
            `${p}.id`
          )
        );
      } else if (riIds.has(r.id)) {
        push(err("E_DUPLICATE_ID", `duplicate reviewIndependence id ${r.id}`, `${p}.id`));
      } else {
        riIds.add(r.id);
      }
      if (typeof r.description !== "string" || !r.description) {
        push(err("E_RI_DESC", "description required", `${p}.description`));
      }
      const allowedMin = [
        "different-agent",
        "independent-approve",
        "cross-vendor-preferred",
        "human-gate",
      ];
      if (!allowedMin.includes(/** @type {string} */ (r.minimumRelationship))) {
        push(
          err(
            "E_RI_MIN",
            `unknown minimumRelationship ${JSON.stringify(r.minimumRelationship)}`,
            `${p}.minimumRelationship`
          )
        );
      }
      if (r.preferredRelationship !== undefined) {
        const allowedPref = [
          "cross-vendor",
          "two-fresh-context-approve",
          "human-gate",
        ];
        if (!allowedPref.includes(/** @type {string} */ (r.preferredRelationship))) {
          push(
            err(
              "E_RI_PREF",
              `unknown preferredRelationship ${JSON.stringify(r.preferredRelationship)}`,
              `${p}.preferredRelationship`
            )
          );
        }
      }
      if (r.tierId !== undefined) {
        if (!REQUIRED_TIER_IDS.includes(/** @type {string} */ (r.tierId))) {
          push(err("E_UNKNOWN_ID", `unknown tierId ${r.tierId}`, `${p}.tierId`));
        } else if (tierIds.size && !tierIds.has(/** @type {string} */ (r.tierId))) {
          push(err("E_BROKEN_REF", `reviewIndependence references missing tier ${r.tierId}`, `${p}.tierId`));
        }
      }
      if (r.humanGateId !== undefined) {
        if (typeof r.humanGateId !== "string" || !GATE_ID_RE.test(r.humanGateId)) {
          push(err("E_UNKNOWN_ID", `unknown humanGateId ${r.humanGateId}`, `${p}.humanGateId`));
        } else if (gateIds.size && !gateIds.has(r.humanGateId)) {
          push(err("E_BROKEN_REF", `reviewIndependence references missing gate ${r.humanGateId}`, `${p}.humanGateId`));
        }
      }
      if (r.generatorMustNotEqual !== undefined) {
        if (
          typeof r.generatorMustNotEqual !== "string" ||
          (roleIds.size && !roleIds.has(r.generatorMustNotEqual))
        ) {
          push(
            err(
              "E_BROKEN_REF",
              `generatorMustNotEqual unknown role ${JSON.stringify(r.generatorMustNotEqual)}`,
              `${p}.generatorMustNotEqual`
            )
          );
        }
      }
    });
    // Closed required set for core candidate encoding.
    for (const need of REQUIRED_RI_IDS) {
      if (!riIds.has(need)) {
        push(
          err(
            "E_RI_REQUIRED",
            `reviewIndependence must include ${need}`,
            "reviewIndependence"
          )
        );
      }
    }
    const tierC = (/** @type {unknown[]} */ (c.reviewIndependence || [])).find((x) => {
      if (!x || typeof x !== "object") return false;
      return /** @type {Record<string, unknown>} */ (x).id === "ri.tier-c";
    });
    if (tierC && typeof tierC === "object") {
      const r = /** @type {Record<string, unknown>} */ (tierC);
      if (r.minimumRelationship !== "human-gate" || r.humanGateId !== "G12") {
        push(
          err(
            "E_RI_TIER_C",
            "ri.tier-c must require human-gate with humanGateId G12",
            "reviewIndependence"
          )
        );
      }
    }
  }

  // --- workflow stages ----------------------------------------------------
  /** @type {Set<string>} */
  const stageIds = new Set();
  /** @type {Set<number>} */
  const stageOrders = new Set();
  if (!Array.isArray(c.workflowStages)) {
    push(err("E_STAGES_TYPE", "workflowStages must be an array", "workflowStages"));
  } else {
    c.workflowStages.forEach((st, i) => {
      const p = `workflowStages[${i}]`;
      if (!st || typeof st !== "object" || Array.isArray(st)) {
        push(err("E_STAGE_ITEM", "stage must be an object", p));
        return;
      }
      const s = /** @type {Record<string, unknown>} */ (st);
      rejectUnknownKeys(s, ALLOWED_STAGE_KEYS, p, push);
      if (!REQUIRED_STAGE_IDS.includes(/** @type {string} */ (s.id))) {
        push(err("E_UNKNOWN_ID", `unknown stage id ${JSON.stringify(s.id)}`, `${p}.id`));
      } else if (stageIds.has(/** @type {string} */ (s.id))) {
        push(err("E_DUPLICATE_ID", `duplicate stage id ${s.id}`, `${p}.id`));
      } else {
        stageIds.add(/** @type {string} */ (s.id));
      }
      if (typeof s.order !== "number" || !Number.isInteger(s.order) || s.order < 0 || s.order > 9) {
        push(err("E_STAGE_ORDER", "stage order must be integer 0..9", `${p}.order`));
      } else if (stageOrders.has(s.order)) {
        push(err("E_DUPLICATE_ID", `duplicate stage order ${s.order}`, `${p}.order`));
      } else {
        stageOrders.add(s.order);
      }
      if (typeof s.name !== "string" || !s.name) {
        push(err("E_STAGE_NAME", "stage name required", `${p}.name`));
      }
      if (typeof s.roleId !== "string" || (roleIds.size && !roleIds.has(s.roleId))) {
        push(err("E_BROKEN_REF", `stage roleId unknown ${JSON.stringify(s.roleId)}`, `${p}.roleId`));
      }
    });
    for (const need of REQUIRED_STAGE_IDS) {
      if (!stageIds.has(need)) {
        push(err("E_STAGE_MISSING", `required workflow stage ${need} is missing`, "workflowStages"));
      }
    }
  }

  // --- tier ↔ gate mappings -----------------------------------------------
  if (!Array.isArray(c.tierGateMappings)) {
    push(err("E_TGM_TYPE", "tierGateMappings must be an array", "tierGateMappings"));
  } else {
    let sawTierCG12 = false;
    let sawTierCG6 = false;
    c.tierGateMappings.forEach((m, i) => {
      const p = `tierGateMappings[${i}]`;
      if (!m || typeof m !== "object" || Array.isArray(m)) {
        push(err("E_TGM_ITEM", "mapping must be an object", p));
        return;
      }
      const map = /** @type {Record<string, unknown>} */ (m);
      rejectUnknownKeys(map, ALLOWED_TGM_KEYS, p, push);
      if (!REQUIRED_TIER_IDS.includes(/** @type {string} */ (map.tierId))) {
        push(err("E_UNKNOWN_ID", `unknown tierId ${map.tierId}`, `${p}.tierId`));
      }
      if (!Array.isArray(map.gateIds) || map.gateIds.length === 0) {
        push(err("E_TGM_GATES", "gateIds must be a non-empty array", `${p}.gateIds`));
      } else {
        for (const gid of map.gateIds) {
          if (typeof gid !== "string" || !GATE_ID_RE.test(gid)) {
            push(err("E_UNKNOWN_ID", `unknown gate id ${gid}`, `${p}.gateIds`));
          } else if (gateIds.size && !gateIds.has(gid)) {
            push(err("E_BROKEN_REF", `mapping references missing gate ${gid}`, `${p}.gateIds`));
          }
          if (map.tierId === "C" && gid === "G12") sawTierCG12 = true;
          if (map.tierId === "C" && gid === "G6") sawTierCG6 = true;
          // Contradictory: G12/G6 must not be mapped exclusively under A or as A-only.
          if ((gid === "G12" || gid === "G6") && map.tierId === "A") {
            push(
              err(
                "E_TIER_GATE_CONTRADICTION",
                `${gid} cannot map to Tier A (docs/14 + docs/06: Tier C merge/billing gates)`,
                p
              )
            );
          }
        }
      }
      if (typeof map.rationale !== "string" || !map.rationale) {
        push(err("E_TGM_RATIONALE", "rationale required", `${p}.rationale`));
      }
    });
    if (!sawTierCG12 || !sawTierCG6) {
      push(
        err(
          "E_TIER_GATE_MAPPING",
          "tierGateMappings must bind G6 and G12 to Tier C",
          "tierGateMappings"
        )
      );
    }
  }

  // --- fork extensions ----------------------------------------------------
  const fe = c.forkExtensions;
  if (!fe || typeof fe !== "object" || Array.isArray(fe)) {
    push(err("E_FORK", "forkExtensions object required", "forkExtensions"));
  } else {
    const f = /** @type {Record<string, unknown>} */ (fe);
    rejectUnknownKeys(f, ALLOWED_FORK_KEYS, "forkExtensions", push);
    if (!Array.isArray(f.allowedNamespaces) || f.allowedNamespaces.length === 0) {
      push(err("E_FORK_NS", "allowedNamespaces must be a non-empty array", "forkExtensions.allowedNamespaces"));
    } else {
      /** @type {Set<string>} */
      const seenNs = new Set();
      for (const ns of f.allowedNamespaces) {
        if (typeof ns !== "string" || !/^[a-z][a-z0-9-]*\.$/.test(ns)) {
          push(err("E_FORK_NS_UNSAFE", `unsafe fork namespace ${JSON.stringify(ns)}`, "forkExtensions.allowedNamespaces"));
          continue;
        }
        if (ns === CORE_ID_PREFIX || ns.startsWith(CORE_ID_PREFIX)) {
          push(
            err(
              "E_FORK_NS_CORE",
              `fork namespace must not use or shadow core prefix ${CORE_ID_PREFIX}`,
              "forkExtensions.allowedNamespaces"
            )
          );
        }
        if (seenNs.has(ns)) {
          push(err("E_DUPLICATE_ID", `duplicate fork namespace ${ns}`, "forkExtensions.allowedNamespaces"));
        }
        seenNs.add(ns);
      }
    }
    if (f.forbiddenCoreShadow !== true) {
      push(
        err(
          "E_FORK_SHADOW",
          "forbiddenCoreShadow must be true",
          "forkExtensions.forbiddenCoreShadow"
        )
      );
    }
    const allowedPrec = [
      "task",
      "role",
      "directory",
      "target-repo",
      "fork-local",
      "gibson",
      "global",
    ];
    if (!Array.isArray(f.precedence) || f.precedence.length === 0) {
      push(err("E_FORK_PREC", "precedence must be a non-empty array", "forkExtensions.precedence"));
    } else {
      /** @type {Set<string>} */
      const seenP = new Set();
      for (const layer of f.precedence) {
        if (!allowedPrec.includes(/** @type {string} */ (layer))) {
          push(err("E_UNKNOWN_ID", `unknown precedence layer ${layer}`, "forkExtensions.precedence"));
        } else if (seenP.has(/** @type {string} */ (layer))) {
          push(
            err(
              "E_AMBIGUOUS_OVERRIDE",
              `duplicate precedence layer ${layer} makes override order ambiguous`,
              "forkExtensions.precedence"
            )
          );
        } else {
          seenP.add(/** @type {string} */ (layer));
        }
      }
    }
    if (f.conflictDisposition !== "refuse") {
      push(
        err(
          "E_AMBIGUOUS_OVERRIDE",
          "conflictDisposition must be 'refuse' (fail closed on ambiguous overrides)",
          "forkExtensions.conflictDisposition"
        )
      );
    }
  }

  // --- notices ------------------------------------------------------------
  const notices = c.notices;
  if (!notices || typeof notices !== "object" || Array.isArray(notices)) {
    push(err("E_NOTICES", "notices object required", "notices"));
  } else {
    const n = /** @type {Record<string, unknown>} */ (notices);
    rejectUnknownKeys(n, ALLOWED_NOTICES_KEYS, "notices", push);
    if (typeof n.authority !== "string" || !/report-only/i.test(n.authority)) {
      push(
        err(
          "E_NOTICES_AUTHORITY",
          "notices.authority must state that this candidate is report-only",
          "notices.authority"
        )
      );
    }
    if (typeof n.activationOwner !== "string" || !n.activationOwner) {
      push(err("E_NOTICES_OWNER", "notices.activationOwner required", "notices.activationOwner"));
    }
    // Never allow a notice that claims activation.
    if (typeof n.authority === "string" && /activated policy authority/i.test(n.authority) &&
        !/NOT an activated/i.test(n.authority)) {
      push(
        err(
          "E_NOTICES_ACTIVATION_CLAIM",
          "notices must not claim the candidate is an activated policy authority",
          "notices.authority"
        )
      );
    }
  }

  return sortFindings(findings);
}

// ---------------------------------------------------------------------------
// Report-only doctrine consistency (identifier / table drift)
// ---------------------------------------------------------------------------

/**
 * Extract selected identifiers from live doctrine files and compare to the
 * candidate. Does not mutate doctrine. Uses fs only.
 *
 * @param {Record<string, unknown>} candidate
 * @param {string} repoRoot
 * @returns {Finding[]}
 */
export function checkDoctrineConsistency(candidate, repoRoot) {
  /** @type {Finding[]} */
  const findings = [];

  const gatePath = "docs/14-human-gates.md";
  const rolesPath = "docs/03-roles.md";
  const tiersPath = "docs/06-quality-gates.md";
  const stagesPath = "docs/02-sdlc-pipeline.md";

  /** @type {Set<string>} */
  let doctrineGates = new Set();
  /** @type {Set<string>} */
  let doctrineRoles = new Set();
  /** @type {Set<string>} */
  let doctrineTiers = new Set();
  /** @type {Set<string>} */
  let doctrineStages = new Set();

  try {
    const text = readFileSync(resolveUnderRoot(repoRoot, gatePath), "utf8");
    let m;
    const re = new RegExp(DOCTRINE_GATE_RE.source, "g");
    while ((m = re.exec(text)) !== null) {
      doctrineGates.add(`G${m[1]}`);
    }
  } catch (e) {
    findings.push(err("E_CONSISTENCY_READ", `cannot read ${gatePath}: ${e.message}`, gatePath));
  }

  try {
    const text = readFileSync(resolveUnderRoot(repoRoot, rolesPath), "utf8");
    let m;
    const re = new RegExp(DOCTRINE_ROLE_HEADING_RE.source, "gm");
    while ((m = re.exec(text)) !== null) {
      doctrineRoles.add(m[1]);
    }
  } catch (e) {
    findings.push(err("E_CONSISTENCY_READ", `cannot read ${rolesPath}: ${e.message}`, rolesPath));
  }

  try {
    const text = readFileSync(resolveUnderRoot(repoRoot, tiersPath), "utf8");
    // Risk tiers table rows: **A** / **B** / **C** under "## Risk tiers"
    if (/##\s*Risk tiers/i.test(text)) {
      const section = text.split(/##\s*Risk tiers/i)[1]?.split(/\n##\s+/)[0] || "";
      for (const t of ["A", "B", "C"]) {
        if (new RegExp(`\\*\\*${t}\\*\\*`).test(section)) doctrineTiers.add(t);
      }
    }
  } catch (e) {
    findings.push(err("E_CONSISTENCY_READ", `cannot read ${tiersPath}: ${e.message}`, tiersPath));
  }

  try {
    const text = readFileSync(resolveUnderRoot(repoRoot, stagesPath), "utf8");
    // Stage headings: "## Stage N — Name"
    const stageNameToId = {
      Plan: "plan",
      Decompose: "decompose",
      Build: "build",
      Test: "test",
      Review: "review",
      "UX Evaluation": "ux-eval",
      Security: "security",
      Merge: "merge",
      "Deploy + Verify": "deploy",
      "Retro (the ratchet)": "retro",
    };
    const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    for (const [name, id] of Object.entries(stageNameToId)) {
      // Em dash (—) or hyphen between stage number and title (docs/02).
      const re = new RegExp(
        `##\\s*Stage\\s+\\d+\\s*[\\u2014\\-]\\s*${escapeRe(name)}`,
        "i"
      );
      if (re.test(text)) {
        doctrineStages.add(id);
      }
    }
  } catch (e) {
    findings.push(err("E_CONSISTENCY_READ", `cannot read ${stagesPath}: ${e.message}`, stagesPath));
  }

  const candGates = new Set(
    (Array.isArray(candidate.humanGates) ? candidate.humanGates : [])
      .map((g) => (g && typeof g === "object" ? /** @type {any} */ (g).id : null))
      .filter(Boolean)
  );
  const candRoles = new Set(
    (Array.isArray(candidate.roles) ? candidate.roles : [])
      .map((r) => (r && typeof r === "object" ? /** @type {any} */ (r).id : null))
      .filter(Boolean)
  );
  const candTiers = new Set(
    (Array.isArray(candidate.riskTiers) ? candidate.riskTiers : [])
      .map((t) => (t && typeof t === "object" ? /** @type {any} */ (t).id : null))
      .filter(Boolean)
  );
  const candStages = new Set(
    (Array.isArray(candidate.workflowStages) ? candidate.workflowStages : [])
      .map((s) => (s && typeof s === "object" ? /** @type {any} */ (s).id : null))
      .filter(Boolean)
  );

  function diffSets(label, doctrine, cand) {
    for (const id of doctrine) {
      if (!cand.has(id)) {
        findings.push(
          err(
            "E_CONSISTENCY_DRIFT",
            `doctrine has ${label} ${id} but candidate does not`,
            label
          )
        );
      }
    }
    for (const id of cand) {
      if (!doctrine.has(id)) {
        findings.push(
          err(
            "E_CONSISTENCY_DRIFT",
            `candidate has ${label} ${id} but selected doctrine tables do not`,
            label
          )
        );
      }
    }
  }

  if (doctrineGates.size) diffSets("gate", doctrineGates, candGates);
  else if (!findings.some((f) => f.path === gatePath)) {
    findings.push(err("E_CONSISTENCY_PARSE", "no G1-G16 markers found in doctrine", gatePath));
  }

  if (doctrineRoles.size) diffSets("role", doctrineRoles, candRoles);
  else if (!findings.some((f) => f.path === rolesPath)) {
    findings.push(err("E_CONSISTENCY_PARSE", "no role headings found in doctrine", rolesPath));
  }

  if (doctrineTiers.size) diffSets("tier", doctrineTiers, candTiers);
  else if (!findings.some((f) => f.path === tiersPath)) {
    findings.push(err("E_CONSISTENCY_PARSE", "no risk tier markers found in doctrine", tiersPath));
  }

  if (doctrineStages.size) diffSets("stage", doctrineStages, candStages);
  else if (!findings.some((f) => f.path === stagesPath)) {
    findings.push(err("E_CONSISTENCY_PARSE", "no stage headings found in doctrine", stagesPath));
  }

  // Also re-check provenance digests as part of consistency.
  const digestFindings = validateCandidate(candidate, {
    repoRoot,
    checkProvenanceDigests: true,
    expectedValidatorVersion: VALIDATOR_VERSION,
  }).filter((f) => f.code === "E_PROVENANCE_DIGEST_MISMATCH" || f.code === "E_PROVENANCE_MISSING_FILE");
  findings.push(...digestFindings);

  if (!findings.length) {
    findings.push(
      info(
        "I_CONSISTENCY_OK",
        "selected doctrine identifiers/tables match the candidate; digests agree",
        "consistency"
      )
    );
  }

  return sortFindings(findings);
}

// ---------------------------------------------------------------------------
// Report assembly (byte-stable)
// ---------------------------------------------------------------------------

/**
 * @param {Record<string, unknown>} candidate
 * @param {Finding[]} findings
 * @param {{ mode: string, consistencyFindings?: Finding[] }} meta
 */
export function buildReport(candidate, findings, meta) {
  const errors = findings.filter((f) => f.severity === "error");
  const warnings = findings.filter((f) => f.severity === "warning");
  const ok = errors.length === 0;

  const report = {
    tool: "policy-manifest",
    toolVersion: VALIDATOR_VERSION,
    mode: meta.mode,
    ok,
    activated: false,
    authority: "report-only",
    notice:
      "This report validates a report-only policy-manifest candidate. It does NOT activate policy authority, change gates, or authorize merge.",
    candidate: {
      schemaId: candidate.schemaId ?? null,
      schemaVersion: candidate.schemaVersion ?? null,
      manifestId: candidate.manifestId ?? null,
      manifestVersion: candidate.manifestVersion ?? null,
      status: candidate.status ?? null,
      authority: candidate.authority ?? null,
      activated: candidate.activated ?? null,
      generatorVersion: candidate.generatorVersion ?? null,
      validatorVersion: candidate.validatorVersion ?? null,
    },
    counts: {
      errors: errors.length,
      warnings: warnings.length,
      findings: findings.length,
      humanGates: Array.isArray(candidate.humanGates) ? candidate.humanGates.length : 0,
      riskTiers: Array.isArray(candidate.riskTiers) ? candidate.riskTiers.length : 0,
      roles: Array.isArray(candidate.roles) ? candidate.roles.length : 0,
      forbiddenRolePairs: Array.isArray(candidate.forbiddenRolePairs)
        ? candidate.forbiddenRolePairs.length
        : 0,
      reviewIndependence: Array.isArray(candidate.reviewIndependence)
        ? candidate.reviewIndependence.length
        : 0,
      workflowStages: Array.isArray(candidate.workflowStages)
        ? candidate.workflowStages.length
        : 0,
    },
    findings: sortFindings(findings),
  };

  if (meta.consistencyFindings) {
    report.consistency = {
      findings: sortFindings(meta.consistencyFindings),
      ok: !meta.consistencyFindings.some((f) => f.severity === "error"),
    };
  }

  return report;
}

export function formatHumanReport(report) {
  const lines = [];
  lines.push(`policy-manifest ${report.toolVersion} — ${report.mode}`);
  lines.push(`authority: ${report.authority} (activated=${report.activated})`);
  lines.push(report.notice);
  lines.push(
    `candidate: ${report.candidate.manifestId}@${report.candidate.manifestVersion} schema=${report.candidate.schemaId}@${report.candidate.schemaVersion} status=${report.candidate.status}`
  );
  lines.push(
    `counts: gates=${report.counts.humanGates} tiers=${report.counts.riskTiers} roles=${report.counts.roles} stages=${report.counts.workflowStages} errors=${report.counts.errors} warnings=${report.counts.warnings}`
  );
  lines.push(`verdict: ${report.ok ? "PASS" : "FAIL"}`);
  for (const f of report.findings) {
    const loc = f.path ? ` @ ${f.path}` : "";
    lines.push(`  [${f.severity}] ${f.code}${loc}: ${f.message}`);
  }
  if (report.consistency) {
    lines.push(
      `consistency: ${report.consistency.ok ? "PASS" : "FAIL"} (${report.consistency.findings.length} finding(s))`
    );
    for (const f of report.consistency.findings) {
      const loc = f.path ? ` @ ${f.path}` : "";
      lines.push(`  [consistency:${f.severity}] ${f.code}${loc}: ${f.message}`);
    }
  }
  lines.push(
    "NOTE: report-only candidate — not an activated policy authority; activation remains #164."
  );
  return lines.join("\n") + "\n";
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function help() {
  console.log(`policy-manifest.mjs — report-only policy-manifest v1 validator (#188)

WHAT IT DOES
  Validate a frozen policy-manifest candidate offline; emit a byte-stable JSON
  report and concise human text; optionally check doctrine identifier drift.
  Never activates policy, never rewrites doctrine, never opens network.

WHY
  Encode current approved semantics (G1-G16, tiers, roles, forbidden pairs,
  review independence, stages) with source provenance before #164 activation.

RISKS
  Consistency is a report sensor. Digests pin the doctrine snapshot. Pure Node
  only — no subprocess, model, secrets, or new dependency.

USAGE
  node scripts/policy-manifest.mjs validate [--manifest PATH] [--repo-root PATH]
      [--no-digest-check]
  node scripts/policy-manifest.mjs report [--manifest PATH] [--repo-root PATH]
      [--format json|text|both] [--with-consistency]
  node scripts/policy-manifest.mjs check-consistency [--manifest PATH]
      [--repo-root PATH]
  node scripts/policy-manifest.mjs digest --path REL [--repo-root PATH]
  node scripts/policy-manifest.mjs --help

DEFAULTS
  --manifest   ${DEFAULT_MANIFEST_REL}
  --repo-root  repository root (parent of scripts/)
  --format     both

EXIT
  0  validation / consistency pass
  1  validation or consistency errors
  2  usage / IO error

EXAMPLES
  node scripts/policy-manifest.mjs validate
  node scripts/policy-manifest.mjs report --format json
  node scripts/policy-manifest.mjs check-consistency
`);
}

function parseArgs(argv) {
  const out = {
    cmd: null,
    manifest: DEFAULT_MANIFEST_REL,
    repoRoot: null,
    format: "both",
    withConsistency: false,
    noDigestCheck: false,
    path: null,
  };
  const positionals = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") {
      out.cmd = "help";
    } else if (a === "--manifest") {
      out.manifest = argv[++i];
    } else if (a === "--repo-root") {
      out.repoRoot = argv[++i];
    } else if (a === "--format") {
      out.format = argv[++i];
    } else if (a === "--with-consistency") {
      out.withConsistency = true;
    } else if (a === "--no-digest-check") {
      out.noDigestCheck = true;
    } else if (a === "--path") {
      out.path = argv[++i];
    } else if (a.startsWith("-")) {
      throw new Error(`unknown option: ${a}`);
    } else {
      positionals.push(a);
    }
  }
  if (!out.cmd) {
    out.cmd = positionals[0] || null;
  }
  return out;
}

function isMain() {
  const self = fileURLToPath(import.meta.url);
  const inv = process.argv[1] ? resolve(process.argv[1]) : "";
  try {
    return realpathSync(self) === realpathSync(inv);
  } catch {
    return resolve(self) === resolve(inv);
  }
}

function main(argv) {
  let opt;
  try {
    opt = parseArgs(argv);
  } catch (e) {
    console.error(`policy-manifest: ${e.message}`);
    process.exit(2);
  }

  if (!opt.cmd || opt.cmd === "help") {
    help();
    process.exit(opt.cmd === "help" ? 0 : 2);
  }

  const repoRoot = opt.repoRoot ? resolve(opt.repoRoot) : defaultRepoRoot();
  if (!existsSync(repoRoot) || !statSync(repoRoot).isDirectory()) {
    console.error(`policy-manifest: repo root not a directory: ${repoRoot}`);
    process.exit(2);
  }

  if (opt.cmd === "digest") {
    if (!opt.path) {
      console.error("policy-manifest digest: --path REL is required");
      process.exit(2);
    }
    try {
      const abs = resolveUnderRoot(repoRoot, opt.path);
      const digest = sha256File(abs, repoRoot);
      process.stdout.write(`${digest}  ${opt.path.replace(/\\/g, "/")}\n`);
      process.exit(0);
    } catch (e) {
      console.error(`policy-manifest: ${e.message}`);
      process.exit(2);
    }
  }

  let manifestAbs;
  try {
    // Absolute --manifest is allowed for offline fixtures/mutation receipts.
    // Relative paths must stay under repoRoot (fail closed on .. / escapes).
    if (isAbsolute(opt.manifest)) {
      manifestAbs = resolve(opt.manifest);
    } else {
      manifestAbs = resolveUnderRoot(repoRoot, opt.manifest);
    }
  } catch (e) {
    console.error(`policy-manifest: ${e.message}`);
    process.exit(2);
  }
  if (!existsSync(manifestAbs) || !statSync(manifestAbs).isFile()) {
    console.error(`policy-manifest: missing manifest ${opt.manifest}`);
    process.exit(2);
  }

  let candidate;
  try {
    candidate = loadJson(manifestAbs);
  } catch (e) {
    console.error(`policy-manifest: ${e.message}`);
    process.exit(2);
  }

  // Schema file presence is documentation; pure validator does not require a
  // JSON-Schema engine. Still refuse if the default schema path is broken when
  // present in-repo (informational only).
  try {
    const schemaAbs = resolveUnderRoot(repoRoot, DEFAULT_SCHEMA_REL);
    if (!existsSync(schemaAbs)) {
      // non-fatal for validate of alternate fixtures; surface as stderr info
      if (opt.cmd === "validate" || opt.cmd === "report") {
        // keep silent unless default candidate — no dependency on schema engine
      }
    }
  } catch {
    // ignore
  }

  if (opt.cmd === "validate") {
    const findings = validateCandidate(candidate, {
      repoRoot,
      checkProvenanceDigests: !opt.noDigestCheck,
      expectedValidatorVersion: VALIDATOR_VERSION,
    });
    const report = buildReport(candidate, findings, { mode: "validate" });
    process.stdout.write(formatHumanReport(report));
    process.exit(report.ok ? 0 : 1);
  }

  if (opt.cmd === "report") {
    const format = opt.format || "both";
    if (!["json", "text", "both"].includes(format)) {
      console.error("policy-manifest report: --format must be json|text|both");
      process.exit(2);
    }
    const findings = validateCandidate(candidate, {
      repoRoot,
      checkProvenanceDigests: !opt.noDigestCheck,
      expectedValidatorVersion: VALIDATOR_VERSION,
    });
    let consistencyFindings;
    if (opt.withConsistency) {
      consistencyFindings = checkDoctrineConsistency(candidate, repoRoot);
    }
    const report = buildReport(candidate, findings, {
      mode: "report",
      consistencyFindings,
    });
    // Consistency errors also fail the report when requested.
    if (consistencyFindings && consistencyFindings.some((f) => f.severity === "error")) {
      report.ok = false;
    }
    if (format === "json" || format === "both") {
      process.stdout.write(stableStringify(report));
    }
    if (format === "text" || format === "both") {
      if (format === "both") process.stdout.write("---\n");
      process.stdout.write(formatHumanReport(report));
    }
    process.exit(report.ok ? 0 : 1);
  }

  if (opt.cmd === "check-consistency") {
    // Structural first, then doctrine identifiers.
    const structural = validateCandidate(candidate, {
      repoRoot,
      checkProvenanceDigests: true,
      expectedValidatorVersion: VALIDATOR_VERSION,
    });
    const consistency = checkDoctrineConsistency(candidate, repoRoot);
    const report = buildReport(candidate, structural, {
      mode: "check-consistency",
      consistencyFindings: consistency,
    });
    if (structural.some((f) => f.severity === "error") ||
        consistency.some((f) => f.severity === "error")) {
      report.ok = false;
    }
    process.stdout.write(formatHumanReport(report));
    process.exit(report.ok ? 0 : 1);
  }

  console.error(`policy-manifest: unknown command ${opt.cmd}`);
  help();
  process.exit(2);
}

if (isMain()) {
  main(process.argv.slice(2));
}
