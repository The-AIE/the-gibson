/**
 * Closed canonical values for mandatory-read-chain.v1.json.
 * The on-disk config is validated against this object. A same-PR edit of
 * the JSON cannot redirect or disable a protected control.
 */

import {
  EXPECTED_ROLES,
  diffClosedSequence,
  listEq,
} from "./contract-semantics.mjs";

export const CANONICAL_SCHEMA_ID = "gibson.mandatory-read-chain.v1";
export const CANONICAL_SCHEMA_VERSION = "1.2.0";
export const CANONICAL_AUTHORITY =
  "AGENTS.md is the sole always-mandatory human-readable contract for commit/PR/merge behavior. Role playbooks are conditionally mandatory session-start load when a role is dispatched. Non-role job dispatch prompts are conditionally mandatory when that job is active. docs/ is on-demand and non-normative. The policy-manifest candidate remains report-only / activated=false until #164 and is only a checked mirror.";

export const CANONICAL_MANDATORY_FILES = ["AGENTS.md"];
export const CANONICAL_DOCS_GLOBS = ["docs/**/*.md"];
export const CANONICAL_PLAYBOOK_GLOBS = ["playbooks/**/*.md"];
export const CANONICAL_LOCAL_OVERRIDE = "local/playbooks/{role}.md";
export const CANONICAL_ROLE_PATH = "playbooks/{role}.md";
export const CANONICAL_DOCS_MARKER = "**Authority:** Non-normative";
export const CANONICAL_PLAYBOOK_NON_NORM = "**Authority:** Non-normative";
export const CANONICAL_DISPATCH_MARKER =
  "**Authority:** Conditionally mandatory dispatch prompt";
export const CANONICAL_ON_DEMAND = "On-demand (non-normative)";
export const CANONICAL_DEFAULT_ROLE = "builder";
export const CANONICAL_DEFAULT_PATH = "playbooks/builder.md";
export const CANONICAL_ROLE_CONTRACTS = "config/policy/role-contracts.v1.json";
export const CANONICAL_MIRROR =
  "config/policy/candidates/gibson-core-v1.candidate.json";
export const CANONICAL_AUDIT = "config/policy/rule-migration-audit.v1.json";
export const CANONICAL_RULE_MIGRATION_AUDIT_SCHEMA_ID =
  "gibson.rule-migration-audit.v1";
export const CANONICAL_RULE_MIGRATION_AUDIT_FAMILY_KEYS = [
  "id",
  "label",
  "home",
  "machine",
];
/** Descriptive `note` may vary. Every other root/family key is closed. */
export const CANONICAL_RULE_MIGRATION_AUDIT_ROOT_KEYS = [
  "schemaId",
  "schemaVersion",
  "issue",
  "authority",
  "families",
];
export const CANONICAL_RULE_MIGRATION_AUDIT = {
  schemaId: CANONICAL_RULE_MIGRATION_AUDIT_SCHEMA_ID,
  schemaVersion: "1.0.0",
  issue: 208,
  authority: "AGENTS.md",
  families: [
    {
      id: "authority-load-order",
      label:
        "Authority, fixed vs conditional load, fork overlay, target contract, tag-filtered lessons",
      home: "AGENTS.md: Authority and mandatory load",
      machine: [
        "config/policy/mandatory-read-chain.v1.json",
        "scripts/contract-authority.mjs",
        "scripts/contract-read-check.mjs",
      ],
    },
    {
      id: "ten-laws",
      label: "Ten Laws",
      home: "AGENTS.md: The Ten Laws",
      machine: [
        "scripts/gate.sh",
        "scripts/test-integrity.mjs",
        "scripts/scope-overlap.mjs",
        "scripts/release-claim.sh",
        "scripts/contract-met.mjs",
        "scripts/truthful-status.mjs",
      ],
    },
    {
      id: "ask-contract",
      label: "Ask Contract four fields",
      home: "AGENTS.md: The Ask Contract",
      machine: ["scripts/contract-authority.mjs"],
    },
    {
      id: "role-outputs-prohibitions",
      label: "Nine roles and per-role outputs/prohibitions",
      home: "AGENTS.md: Your role this session + config/policy/role-contracts.v1.json",
      machine: [
        "config/policy/role-contracts.v1.json",
        "scripts/contract-authority.mjs",
      ],
    },
    {
      id: "forbidden-role-pairs",
      label: "Forbidden builder/reviewer/UX pairs and cross-vendor default",
      home: "AGENTS.md: Your role this session",
      machine: ["scripts/contract-authority.mjs"],
    },
    {
      id: "six-lens-review",
      label: "Six-lens review with file:line findings",
      home: "AGENTS.md: Review lenses (binding)",
      machine: ["scripts/contract-authority.mjs"],
    },
    {
      id: "tier-c-adversarial-tests",
      label: "Tier C adversarial test cases required",
      home: "AGENTS.md: Your role this session (test-engineer)",
      machine: ["scripts/contract-authority.mjs"],
    },
    {
      id: "no-destructive-prod-testing",
      label: "No destructive production testing / DAST vs preview-staging only",
      home: "AGENTS.md: Your role this session (security) + Security layers",
      machine: ["scripts/contract-authority.mjs"],
    },
    {
      id: "eight-security-layers",
      label: "Eight security layers",
      home: "AGENTS.md: Security layers (binding)",
      machine: ["scripts/contract-authority.mjs"],
    },
    {
      id: "self-modification-gates",
      label:
        "Self-modification gates for human gates / tiers / hard-fail security layers",
      home: "AGENTS.md: Self-modification bounds (binding)",
      machine: ["scripts/contract-authority.mjs"],
    },
    {
      id: "delivery-control",
      label: "Delivery-control audit, dry-run, human-apply",
      home: "AGENTS.md: Delivery control (binding)",
      machine: ["scripts/delivery-control/", "scripts/contract-authority.mjs"],
    },
    {
      id: "workflow-stages",
      label: "Ten workflow stages and skip recording",
      home: "AGENTS.md: The pipeline you are inside",
      machine: ["scripts/contract-authority.mjs"],
    },
    {
      id: "human-gates",
      label: "G1–G16 closed stop list and explicit non-gates",
      home: "AGENTS.md: Human gates",
      machine: ["scripts/contract-authority.mjs"],
    },
    {
      id: "style-commitments",
      label: "Style commitments versus technical decisions",
      home: "AGENTS.md: Style commitments",
      machine: ["scripts/contract-authority.mjs"],
    },
    {
      id: "risk-tiers",
      label:
        "Tier A/B/C definitions, escalation, review strength, stateful serialization",
      home: "AGENTS.md: Risk tiers",
      machine: [
        "config/review-round-caps.json",
        "scripts/contract-authority.mjs",
      ],
    },
    {
      id: "commit-pr-merge",
      label: "Pre-commit pipeline, DCO, exact-head review, merge order",
      home: "AGENTS.md: Commit, PR, and merge",
      machine: [
        "scripts/gate.sh",
        "scripts/setup-hooks.sh",
        "scripts/release-claim.sh",
        "scripts/contract-met.mjs",
      ],
    },
    {
      id: "concurrency",
      label:
        "Claims, worktrees, hot files, lane limit, rebase, no shared force-push",
      home: "AGENTS.md: Concurrency",
      machine: [
        "scripts/scope-overlap.mjs",
        "scripts/claim.sh",
        "scripts/release-claim.sh",
      ],
    },
  ],
};
export const CANONICAL_RULE_MIGRATION_AUDIT_FAMILY_IDS =
  CANONICAL_RULE_MIGRATION_AUDIT.families.map((f) => f.id);

export const CANONICAL_JOB_PROMPTS = [
  "playbooks/adopt.md",
  "playbooks/delivery-control.md",
  "playbooks/deploy-audit.md",
  "playbooks/dogfood-overnight.md",
  "playbooks/loop-step.md",
  "playbooks/token-efficiency.md",
];

export const CANONICAL_DISCLOSURE_PHRASES = [
  "Conditional session-start human-readable load",
  "when a role is dispatched",
  "playbooks/<role>.md",
  "When a non-role job is dispatched",
  "role/job dispatch prompt",
];

export const CANONICAL_SESSION_START_NOT_BUDGETED = [
  "local/AGENTS.local.md",
  "<target>/AGENTS.md",
  "memory/LESSONS.md (tag-filtered consult; attested, not full-file ingest)",
];

export const CANONICAL_TOKEN_PROXY = {
  id: "utf8-bytes-div-4",
  formula: "ceil(utf8_bytes / 4)",
};

export const CANONICAL_MACHINE_CANONICAL = {
  humanGates: "AGENTS.md",
  roles: "AGENTS.md",
  roleContracts: CANONICAL_ROLE_CONTRACTS,
  jobContracts: CANONICAL_ROLE_CONTRACTS,
  riskTiers: "AGENTS.md",
  workflowStages: "AGENTS.md",
  forbiddenRolePairs: "AGENTS.md",
  policyManifestMirror: CANONICAL_MIRROR,
  reviewRoundCaps: "config/review-round-caps.json",
  testIntegrity: "scripts/test-integrity.mjs",
  claimOverlap: "scripts/scope-overlap.mjs",
  greenGate: "scripts/gate.sh",
  dcoHook: "scripts/setup-hooks.sh",
  exactHeadRelease: "scripts/release-claim.sh",
  ruleMigrationAudit: CANONICAL_AUDIT,
};

export const CANONICAL_MACHINE_SOURCE_PATHS = [
  CANONICAL_MIRROR,
  "config/review-round-caps.json",
  "scripts/test-integrity.mjs",
  "scripts/scope-overlap.mjs",
  "scripts/gate.sh",
  "scripts/setup-hooks.sh",
  "scripts/release-claim.sh",
  "config/policy/mandatory-read-chain.v1.json",
  CANONICAL_AUDIT,
  CANONICAL_ROLE_CONTRACTS,
];

export const CANONICAL_REQUIRED_RULE_PATTERNS = [
  "sole always-mandatory human-readable",
  "on-demand and non-normative",
  "checked mirror",
  "activated=false",
  "Conditional session-start human-readable load",
  "when a role is dispatched",
  "playbooks/<role>.md",
  "When a non-role job is dispatched",
  "role/job dispatch prompt",
  "One issue = one claim = one worktree = one branch",
  "canonical checkout",
  "generate",
  "typecheck",
  "zero new failures",
  "test-integrity",
  "Never grade your own homework",
  "exact committed head SHA",
  "Signed-off-by",
  "Acceptance criteria are the contract",
  "Tier C is sacred",
  "failures verbatim",
  "memory/LESSONS.md",
  "release-claim.sh",
  "What I'm asking",
  "What it does",
  "Why it should be done",
  "The risks",
  "additive-only",
  "Max **3**",
  "agent-claimed",
  "VERDICT: APPROVE",
  "fail closed",
  "Ask Contract",
  "six lenses",
  "file:line",
  "adversarial cases required",
  "destructive production testing",
  "Eight layers",
  "human gates",
  "Tier definitions",
  "hard-fail security layers",
  "audit",
  "dry-run",
  "explicit human apply",
];

export const CANONICAL_BINDING_FAMILIES = [
  {
    id: "authority-load-order",
    label: "Authority, mandatory load order, overlays, and lesson consult",
    section: "Authority and mandatory load",
    patterns: [
      "Fixed mandatory human-readable load (byte-budgeted)",
      "Conditional session-start human-readable load",
      "local/AGENTS.local.md",
      "The **target repo's** `AGENTS.md`",
      "memory/LESSONS.md",
      "on-demand and non-normative",
    ],
  },
  {
    id: "ten-laws",
    label: "Ten Laws",
    section: "The Ten Laws",
    requiredItems: [
      "Read before you act.",
      "Claim before you touch.",
      "Never edit in the canonical checkout.",
      "The green gate is absolute.",
      "Never grade your own homework.",
      "Acceptance criteria are the contract.",
      "Tier C is sacred.",
      "Report truthfully, loudly, and in the right place.",
      "Feed the ratchet.",
      "Clean up after merge.",
    ],
    patterns: [
      "One issue = one claim = one worktree = one branch",
      "generate → typecheck → lint → test → build",
      "exact committed head SHA",
      "failures verbatim",
      "release-claim.sh",
    ],
  },
  {
    id: "ask-contract",
    label: "Ask Contract four fields",
    section: "The Ask Contract (how you talk to the user)",
    requiredItems: [
      "What I'm asking",
      "What it does",
      "Why it should be done",
      "The risks",
    ],
    patterns: ["Never hand the user a bare command or a bare yes/no"],
  },
  {
    id: "role-outputs-prohibitions",
    label: "Per-role outputs, prohibitions, and durable handoffs",
    section: "Your role this session",
    patterns: [
      "Per-role and per-job outputs, gates, and prohibitions are canonical",
      "Handoffs are **files and GitHub objects, never chat memory**",
    ],
  },
  {
    id: "forbidden-role-pairs",
    label: "Forbidden role pairs and cross-vendor review",
    section: "Your role this session",
    patterns: [
      "Forbidden pairs on the same unit of work",
      "Cross-vendor review is the default when more than one runtime is available",
    ],
  },
  {
    id: "six-lens-review",
    label: "Six-lens review with file:line findings",
    section: "Review lenses (binding)",
    requiredItems: [
      "Correctness",
      "Security",
      "Consent / PII",
      "Money",
      "Performance",
      "Maintainability",
    ],
    patterns: ["file:line", "VERDICT: REQUEST_CHANGES"],
  },
  {
    id: "tier-c-adversarial-tests",
    label: "Tier C adversarial tests (test-engineer)",
    section: "Your role this session",
    patterns: ["adversarial cases required"],
  },
  {
    id: "no-destructive-prod-testing",
    label: "Prohibition on destructive production testing",
    section: "Your role this session",
    patterns: ["destructive production testing"],
  },
  {
    id: "eight-security-layers",
    label: "Eight security layers",
    section: "Security layers (binding)",
    patterns: [
      "Eight layers",
      "hard-fail blocks merge/release",
      "AuthZ matrix",
      "never destructive payloads against production",
      "Runtime posture",
    ],
  },
  {
    id: "self-modification-gates",
    label: "Self-modification gates for tier/security/human-gate controls",
    section: "Self-modification bounds (binding)",
    patterns: [
      "Harness changes use the same PR + review pipeline as product changes",
      "Tier definitions",
      "hard-fail security layers",
      "themselves Tier C (**G12**)",
    ],
  },
  {
    id: "delivery-control",
    label: "Delivery-control audit, dry-run, and human-apply",
    section: "Delivery control (binding)",
    patterns: ["audit", "dry-run", "explicit human apply", "Never rotate secrets"],
  },
  {
    id: "workflow-stages",
    label: "Ten workflow stages and skip recording",
    section: "The pipeline you are inside",
    patterns: [
      "plan → decompose → build → test → review → ux-eval → security → merge → deploy → retro",
      "Ten stages (`PLAN`, `DECOMPOSE`, `BUILD`, `TEST`, `REVIEW`, `UX-EVAL`, `SECURITY`, `MERGE`, `DEPLOY+VERIFY`, `RETRO`)",
      "record the skip on the PR",
    ],
  },
  {
    id: "human-gates",
    label: "G1-G16 closed stop list and explicit non-gates",
    section: "Human gates (the ONLY reasons to stop)",
    patterns: [
      "This list is **closed**. Changing it is Tier C",
      "### Explicit non-gates",
      "Failing tests · red CI · flaky infrastructure · merge conflicts · missing docs",
      "the gates decide, not the feeling",
    ],
  },
  {
    id: "style-commitments",
    label: "Style commitments versus technical decisions",
    section: "Human gates (the ONLY reasons to stop)",
    patterns: [
      "### Style commitments (owner taste, not a numbered G)",
      "Technical correctness is an agent + CI decision; taste is the owner's",
      "open a decision item for the taste call rather than self-approving it",
      "stop and ask",
    ],
  },
  {
    id: "risk-tiers",
    label: "Risk tiers, escalation, and stateful serialization",
    section: "Risk tiers",
    patterns: [
      "| **A** | Routine:",
      "| **B** | Elevated:",
      "| **C** | Money, auth, consent/PII, security boundaries, schema, incident alerting, prod data.",
      "**G12**",
      "serialize when stateful",
      "Diffs may drift **into** Tier C; they never drift out without a reviewer saying so",
    ],
  },
  {
    id: "commit-pr-merge",
    label: "Pre-commit pipeline, DCO, exact-head review, and merge order",
    section: "Commit, PR, and merge",
    patterns: [
      "generate → typecheck → lint → test → build",
      "Signed-off-by",
      "exact committed head SHA",
      "`release` verifies, in order",
      "Tier C / schema → **G12** human approval recorded",
    ],
  },
  {
    id: "concurrency",
    label: "Claims, worktrees, lane limit, rebase, and no shared force-push",
    section: "Concurrency (compact)",
    patterns: [
      "One issue, one worktree, one branch",
      "agent-claimed",
      "Max **3** active mutating lanes per target repo",
      "Before push: rebase onto the remote default branch in *your* worktree",
      "Never force-push a shared branch (**G3**)",
    ],
  },
];

export const CANONICAL_FORBIDDEN_CONTRACT_PATTERNS = [
  "Complete list with rationale in `docs/14-human-gates.md`",
  "Roles and their contracts are in `docs/03-roles.md`",
  "Stage rules: `docs/02-sdlc-pipeline.md`",
  "the full presentation rules are `docs/16-nontechnical-operation.md`",
  "are canonical in `config/policy/candidates/gibson-core-v1.candidate.json`",
];

export const CANONICAL_FORBIDDEN_REPO_CLAIMS = [
  {
    path: "README.md",
    patterns: [
      "Rules, roles, gates, playbooks every agent follows | `AGENTS.md`, `docs/`, `playbooks/`",
      "The development team: nine roles, their contracts and handoffs",
      "The only reasons an agent may stop",
      "The complete list of mandatory stops fits on one page: [docs/14-human-gates.md](docs/14-human-gates.md)",
    ],
  },
];

export const CANONICAL_PRE_CHANGE = {
  commit: "dcca0c18d39488d3a18842901a3d46efee0e280b",
  impliedMandatoryFiles: [
    "AGENTS.md",
    "docs/02-sdlc-pipeline.md",
    "docs/03-roles.md",
    "docs/05-concurrency.md",
    "docs/06-quality-gates.md",
    "docs/09-memory-and-self-improvement.md",
    "docs/11-solo-loop.md",
    "docs/14-human-gates.md",
    "docs/16-nontechnical-operation.md",
    "docs/18-fork-and-upstream.md",
    "docs/23-delivery-control.md",
    "playbooks/delivery-control.md",
  ],
  impliedMandatoryBytes: 125317,
  lessonsBytes: 66857,
  agentsBytes: 7404,
};

export const CANONICAL_BYTE_BUDGET = {
  "AGENTS.md": 20480,
  mandatoryChain: 20480,
};

export const CANONICAL_READ_CHAIN = {
  schemaId: CANONICAL_SCHEMA_ID,
  schemaVersion: CANONICAL_SCHEMA_VERSION,
  authority: CANONICAL_AUTHORITY,
  mandatoryFiles: CANONICAL_MANDATORY_FILES,
  allowedMandatoryFiles: CANONICAL_MANDATORY_FILES,
  fixedMandatoryFiles: CANONICAL_MANDATORY_FILES,
  conditionalDispatchPrompts: {
    roles: [...EXPECTED_ROLES],
    pathTemplate: CANONICAL_ROLE_PATH,
    localOverrideTemplate: CANONICAL_LOCAL_OVERRIDE,
    jobPrompts: CANONICAL_JOB_PROMPTS,
    disclosurePhrases: CANONICAL_DISCLOSURE_PHRASES,
  },
  defaultRole: {
    id: CANONICAL_DEFAULT_ROLE,
    whenUnnamed: true,
    path: CANONICAL_DEFAULT_PATH,
  },
  roleContractsPath: CANONICAL_ROLE_CONTRACTS,
  jobContractsPath: CANONICAL_ROLE_CONTRACTS,
  sessionStartNotBudgeted: CANONICAL_SESSION_START_NOT_BUDGETED,
  byteBudget: CANONICAL_BYTE_BUDGET,
  tokenProxy: CANONICAL_TOKEN_PROXY,
  machineCanonical: CANONICAL_MACHINE_CANONICAL,
  requiredMachineSourcePaths: CANONICAL_MACHINE_SOURCE_PATHS,
  requiredRulePatterns: CANONICAL_REQUIRED_RULE_PATTERNS,
  requiredBindingFamilies: CANONICAL_BINDING_FAMILIES,
  forbiddenContractPatterns: CANONICAL_FORBIDDEN_CONTRACT_PATTERNS,
  forbiddenRepoClaims: CANONICAL_FORBIDDEN_REPO_CLAIMS,
  docsNonNormativeGlobs: CANONICAL_DOCS_GLOBS,
  docsNonNormativeMarker: CANONICAL_DOCS_MARKER,
  playbookGlobs: CANONICAL_PLAYBOOK_GLOBS,
  playbookDispatchMarker: CANONICAL_DISPATCH_MARKER,
  playbookNonNormativeMarker: CANONICAL_PLAYBOOK_NON_NORM,
  onDemandSectionHeading: CANONICAL_ON_DEMAND,
  policyManifestMirrorPath: CANONICAL_MIRROR,
  ruleMigrationAuditPath: CANONICAL_AUDIT,
  preChangeAt: CANONICAL_PRE_CHANGE,
};

function isPlainObject(v) {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

function pinCode(path) {
  if (/mandatoryFiles|allowedMandatoryFiles|fixedMandatoryFiles/.test(path)) {
    return "E_MANDATORY_SET";
  }
  if (/byteBudget/.test(path)) return "E_BUDGET";
  if (/docsNonNormativeGlobs|playbookGlobs/.test(path)) return "E_GLOB";
  return "E_CONFIG";
}

export function canonicalEq(actual, expected, path, fail) {
  if (typeof expected === "string" || typeof expected === "number" || typeof expected === "boolean") {
    if (actual !== expected) {
      fail(
        pinCode(path),
        `${path} must be ${JSON.stringify(expected)}; got ${JSON.stringify(actual)}`
      );
    }
    return;
  }
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length) {
      fail(
        pinCode(path),
        `${path} must equal the contract-defined list; got ${JSON.stringify(actual)}`
      );
      return;
    }
    for (let i = 0; i < expected.length; i++) {
      canonicalEq(actual[i], expected[i], `${path}[${i}]`, fail);
    }
    return;
  }
  if (isPlainObject(expected)) {
    if (!isPlainObject(actual)) {
      fail("E_CONFIG", `${path} must be an object`);
      return;
    }
    for (const k of Object.keys(expected)) {
      canonicalEq(actual[k], expected[k], `${path}.${k}`, fail);
    }
    for (const k of Object.keys(actual)) {
      if (k === "note") continue;
      if (!Object.prototype.hasOwnProperty.call(expected, k)) {
        fail(pinCode(path), `${path} has unknown key ${k}`);
      }
    }
    return;
  }
}

/**
 * Closed 17-family rule-migration audit. Root identity and each family's
 * id/label/home/machine mapping are hardcoded so a same-PR JSON edit
 * cannot redirect a rule home. Descriptive `note` may vary; unknown
 * root or family keys fail closed.
 */
export function diffRuleMigrationAudit(audit) {
  const findings = [];
  if (!audit || typeof audit !== "object" || Array.isArray(audit)) {
    findings.push({
      code: "E_AUDIT",
      message: "rule-migration audit must be an object",
    });
    return findings;
  }
  const allowedRoot = new Set([
    ...CANONICAL_RULE_MIGRATION_AUDIT_ROOT_KEYS,
    "note",
  ]);
  for (const k of Object.keys(audit)) {
    if (!allowedRoot.has(k)) {
      findings.push({
        code: "E_AUDIT",
        message: `rule-migration audit has unknown key ${k}`,
      });
    }
  }
  const canon = CANONICAL_RULE_MIGRATION_AUDIT;
  if (audit.schemaId !== canon.schemaId) {
    findings.push({
      code: "E_AUDIT",
      message: `rule-migration audit schemaId must be ${canon.schemaId}`,
    });
  }
  if (audit.schemaVersion !== canon.schemaVersion) {
    findings.push({
      code: "E_AUDIT",
      message: `rule-migration audit schemaVersion must be ${JSON.stringify(canon.schemaVersion)}`,
    });
  }
  if (audit.issue !== canon.issue) {
    findings.push({
      code: "E_AUDIT",
      message: `rule-migration audit issue must be ${canon.issue}`,
    });
  }
  if (audit.authority !== canon.authority) {
    findings.push({
      code: "E_AUDIT",
      message: `rule-migration audit authority must be ${canon.authority}`,
    });
  }
  if ("note" in audit && typeof audit.note !== "string") {
    findings.push({
      code: "E_AUDIT",
      message: "rule-migration audit note must be a string when present",
    });
  }
  if (!Array.isArray(audit.families)) {
    findings.push({
      code: "E_AUDIT",
      message: "rule-migration audit families must be an array",
    });
    return findings;
  }
  const byId = new Map(canon.families.map((f) => [f.id, f]));
  const ids = [];
  audit.families.forEach((fam, i) => {
    const loc = `families[${i}]`;
    if (!fam || typeof fam !== "object" || Array.isArray(fam)) {
      findings.push({
        code: "E_AUDIT_FAMILY",
        message: `rule-migration audit ${loc} is malformed`,
      });
      return;
    }
    for (const k of Object.keys(fam)) {
      if (!CANONICAL_RULE_MIGRATION_AUDIT_FAMILY_KEYS.includes(k)) {
        findings.push({
          code: "E_AUDIT_FAMILY",
          message: `rule-migration audit ${loc} has unknown key ${k}`,
        });
      }
    }
    if (typeof fam.id !== "string" || !fam.id) {
      findings.push({
        code: "E_AUDIT_FAMILY",
        message: `rule-migration audit ${loc} missing id`,
      });
    } else {
      ids.push(fam.id);
    }
    if (typeof fam.label !== "string" || !fam.label) {
      findings.push({
        code: "E_AUDIT_FAMILY",
        message: `rule-migration audit ${loc} missing label`,
      });
    }
    if (typeof fam.home !== "string" || !fam.home) {
      findings.push({
        code: "E_AUDIT_FAMILY",
        message: `rule-migration audit ${loc} missing home`,
      });
    }
    if (!Array.isArray(fam.machine)) {
      findings.push({
        code: "E_AUDIT_FAMILY",
        message: `rule-migration audit ${loc} missing machine`,
      });
    } else {
      fam.machine.forEach((entry, j) => {
        if (typeof entry !== "string" || !entry) {
          findings.push({
            code: "E_AUDIT_FAMILY",
            message: `rule-migration audit ${loc} machine[${j}] is not a nonempty string`,
          });
        }
      });
    }
    const want = fam.id && byId.get(fam.id);
    if (!want) return;
    if (typeof fam.label === "string" && fam.label !== want.label) {
      findings.push({
        code: "E_AUDIT_FAMILY",
        message: `rule-migration audit ${loc} label drifted from ${want.id} home mapping`,
      });
    }
    if (typeof fam.home === "string" && fam.home !== want.home) {
      findings.push({
        code: "E_AUDIT_FAMILY",
        message: `rule-migration audit ${loc} home drifted from ${want.id} mapping`,
      });
    }
    if (Array.isArray(fam.machine) && !listEq(fam.machine, want.machine)) {
      findings.push({
        code: "E_AUDIT_FAMILY",
        message: `rule-migration audit ${loc} machine mapping drifted from ${want.id}`,
      });
    }
  });
  for (const f of diffClosedSequence(
    "AUDIT_FAMILY",
    ids,
    CANONICAL_RULE_MIGRATION_AUDIT_FAMILY_IDS
  )) {
    findings.push(f);
  }
  return findings;
}

/**
 * Pin every authority/discovery/accounting/dispatch/forbidden-claim control.
 * Documentary `note` keys may exist but cannot replace a missing control.
 */
export function pinReadChainConfig(cfg, fail) {
  if (!isPlainObject(cfg)) {
    fail("E_CONFIG", "mandatory-read-chain config must be an object");
    return;
  }
  canonicalEq(cfg, CANONICAL_READ_CHAIN, "config", fail);
}
