---
title: "Policy manifest v1 (report-only candidate)"
parent: The Doctrine
nav_order: 27
---

# Policy manifest v1 — report-only candidate and offline validator


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** This is a frozen checklist of today's approved rules
> (when to stop, who reviews what, which jobs cannot grade themselves) written
> so a computer can read it. It does **not** change how the crew runs. It is a
> preparation step so later work can keep the docs and the machines from
> drifting apart.

## What this is

Issue **#188** ships the first reversible slice of parent architecture issue
**#164**:

| Artifact | Path | Role |
|---|---|---|
| JSON Schema (documentation of shape) | `config/policy/schema/policy-manifest-v1.schema.json` | Stable schema id + version contract |
| Candidate manifest | `config/policy/candidates/gibson-core-v1.candidate.json` | Behavior-preserving encoding of approved semantics |
| Pure offline validator | `scripts/policy-manifest.mjs` | Fail-closed validation + byte-stable report |
| Focused sensors | `scripts/tests/policy-manifest.test.sh` | Fixtures + mutation receipts |
| This guide | `docs/policy-manifest-v1.md` | Compatibility, forks, upgrade/rollback |

The candidate carries:

- stable **schema id / schema version**, **manifest id / version**
- **status** `candidate`, **authority** `report-only`, **activated** `false`
- **generatorVersion** and **validatorVersion**
- **source path + sha256 digest** provenance for doctrine files it encodes
- a documented **compatibility** policy (semver major break; namespaced forks)

It encodes, without adding/removing/tightening/loosening approved semantics:

- human gates **G1–G16** (`docs/14-human-gates.md`)
- risk tiers **A / B / C** and evidence minimums (`docs/06-quality-gates.md`)
- nine roles and forbidden same-unit pairs (`docs/03-roles.md`)
- review-independence relationships (Law 5, tier floors, Tier C → G12)
- workflow stage names **plan → retro** (`docs/02-sdlc-pipeline.md`)

## What this is not

- **Not** an activated policy authority. Reports always say so.
- **Not** merge, gate, or CI hard-fail authority. `#208` made `AGENTS.md` the
  sole always-mandatory human-readable contract; this candidate remains a
  **checked mirror** (`report-only`, `activated=false`) of enumerations that
  `AGENTS.md` owns. `scripts/contract-authority.mjs` fails if the mirror drifts
  from `AGENTS.md`; it must not treat the candidate as binding authority.
  Activation is still `#164`.
- **Not** generated doctrine blocks (those remain **#164**).
- **Not** a consumer for the context compiler (**#166** consumes a *later*
  resolved bundle, not this candidate by implication).
- **Not** closure of parent **#164**.

## Running the validator

Pure Node. No network, no model, no shell subprocess, no new dependency.

```bash
# Structural validation (includes live digest check against provenance paths)
node scripts/policy-manifest.mjs validate

# Byte-stable JSON report + human text
node scripts/policy-manifest.mjs report --format both

# Report-only consistency: selected doctrine identifiers/tables vs candidate
node scripts/policy-manifest.mjs check-consistency

# Digest helper for refreshing provenance after an intentional doctrine pin
node scripts/policy-manifest.mjs digest --path docs/14-human-gates.md
```

Exit codes: `0` pass, `1` validation/consistency errors, `2` usage/IO.

Focused suite:

```bash
bash scripts/tests/policy-manifest.test.sh
# or via the full sensor gate
./scripts/tests/run-all.sh --only policy-manifest
```

## Compatibility policy

| Rule | Meaning |
|---|---|
| `semver-major-break` | Within schema major `1`, additive clarifications may bump `manifestVersion` / minor schema. A new major requires a new schema id/version pair; this validator **refuses** unsupported majors. |
| `namespaced-only` fork extensions | Forks may add IDs under declared namespaces (`fork.`, `local.`). They must **not** edit or shadow `gibson.*` core IDs. |
| `conflictDisposition: refuse` | Ambiguous overrides (duplicate precedence layers, conflicting requirements) fail closed — never silently merge. |
| Precedence (most specific first) | `task` → `role` → `directory` → `target-repo` → `fork-local` → `gibson` → `global` |

### Namespaced fork extensions

1. Put fork-local policy under an allowed namespace prefix (`fork.` or `local.`).
2. Never reuse a core gate/role/tier/stage id to mean something else.
3. Record fork-owner decisions that *remove* a human gate in the fork's
   `memory/DECISIONS.md` (see `docs/18-fork-and-upstream.md`); extension is
   different from silent shadowing.
4. Keep overrides in `local/**` for prose/playbooks; machine policy extensions
   that appear in a future activated bundle must remain namespaced.

### Precedence and conflict refusal

When two layers disagree on an enforceable identifier:

- the more specific layer wins **only if** the conflict is an intentional,
  non-ambiguous override allowed by later activation rules;
- for this report-only candidate, **any** ambiguous override shape (duplicate
  precedence entries, non-`refuse` disposition, core-namespace shadow) is a
  validation **error**.

### Generated-view boundaries

Generated views (AGENTS summaries, doctrine tables, adapter host files) are
**outputs**, not authorities:

- a generated block must identify manifest + generator version (when #164 adds
  generation);
- adapters (Claude/Codex/Goose/pi host files) cannot become policy sources;
- this v1 slice does **not** write generated blocks.

### Upgrade

1. Bump `manifestVersion` for additive, behavior-preserving clarifications.
2. Refresh provenance digests with `policy-manifest.mjs digest` when the
   candidate intentionally re-pins doctrine sources after a separate doctrine PR.
3. Schema major bumps require a parallel validator that understands the new
   major; old validators must fail closed on the new major.

### Rollback

Because **activated=false** and nothing in CI/runtime consumes this candidate as
authority:

1. Revert the candidate file (and validator if needed) on the branch.
2. Runtime gates, human-gate list, and CI hard-fail behavior are unchanged by
   that revert.

## Fail-closed validation surface

The pure validator refuses (non-exhaustive):

- unsupported schema id / major version
- **schema value parity** against `policy-manifest-v1.schema.json` (single
  source): every `type`, `enum`, `const`, `required`, `pattern`, `minLength`,
  `minItems` / `maxItems`, and numeric `minimum` / `maximum` — so a
  runtime-valid document cannot be schema-invalid on value constraints
- unknown properties on all object shapes (`additionalProperties: false`)
- unknown or duplicate IDs
- broken references (roles, gates, tiers, stages)
- contradictory tier ↔ gate mappings (e.g. G12 on Tier A)
- missing required forbidden pairs; asymmetric pairs without reverse edges
- **reviewIndependence semantic pins** for each core id — exact field
  **presence and absence** (schema-valid optional semantic fields that are not
  part of an id's meaning are refused with the id's pin code):
  - `ri.law5` → `different-agent` + preferred `cross-vendor` +
    `generatorMustNotEqual: reviewer`; **absent** `tierId`, `humanGateId`
    (`E_RI_LAW5`)
  - `ri.tier-a` → tier `A`, `independent-approve`, preferred `cross-vendor`;
    **absent** `humanGateId`, `generatorMustNotEqual` (`E_RI_TIER_A`)
  - `ri.tier-b` → tier `B`, `independent-approve`, preferred
    `two-fresh-context-approve`; **absent** `humanGateId`,
    `generatorMustNotEqual` (`E_RI_TIER_B`)
  - `ri.tier-c` → tier `C`, `human-gate` / preferred `human-gate`, gate `G12`;
    **absent** `generatorMustNotEqual` (`E_RI_TIER_C`)
  - Descriptive fields (`id`, `description`) remain schema-governed only
- unsafe fork namespaces (including core `gibson.` shadow)
- malformed provenance (exact `..` path segments, non-sha256 digests); filenames
  like `a..b.md` that are not a `..` segment remain legal
- `--manifest` and schema reads that escape the declared `--repo-root`
  (absolute paths, symlink realpath escape); schema is always loaded from
  `config/policy/schema/policy-manifest-v1.schema.json` under that root
- **canonical root identity**: `--repo-root` is `realpath`'d once into an
  immutable token of canonical path + exact **BigInt** `dev`/`ino` (no soft
  fallback if realpath fails). That token is re-asserted before and after every
  manifest/schema/doctrine/provenance open so **observable** root
  disappearance, replacement, type change, or containment failure fails closed —
  a mutable pathname string alone is never trusted across multi-file operations.
  Schema is not cached across roots (root-symlink swap cannot poison root A with
  root B bytes). Every child open re-asserts root BigInt `dev`/`ino`, binds the
  opened fd's BigInt identity under realpath containment, and reads bytes only
  from that verified fd.
  **Portable boundary (residual):** Node has no portable `openat` for
  fd-relative child opens without native addons. Child files are opened by
  pathname (`openSync(absPath)`) after the last pre-open root check; there is
  **no** retained root directory fd anchoring child opens (a root-dir fd would
  only re-`fstat` the root and adds numeric-fd reuse hazard). A same-user
  concurrent **replace-through-open/identity then restore** at the same pathname
  can still leave an fd opened under a temporary replacement accepted if the
  original root is restored before the post-open root assertion. Complete
  closure of that race needs a future native/portable fd-relative open
  capability or external filesystem/process isolation. The focused suite records
  this as a `KNOWN_PORTABLE_BOUNDARY` sensor receipt (not a security PASS that
  the race is impossible). Observable replacements that remain installed still
  fail closed.
- path swaps after open (TOCTOU): every validation read (manifest, schema,
  doctrine, digest) opens once with portable `O_RDONLY|O_NONBLOCK` (FIFO/device
  never hang), binds realpath + **BigInt** `dev`/`ino` fd identity under the
  frozen root, and only then reads bytes from that fd — identity change,
  non-regular type, or realpath escape fails closed before any out-of-root
  replacement is accepted
- **consistency revalidation fail-closed**: `check-consistency` re-asserts the
  frozen root immediately before and after final schema/provenance validation
  and propagates every relevant error — all `E_PROVENANCE_*` findings **and**
  `E_SCHEMA_LOAD` / root-identity bind failures. A narrow `E_PROVENANCE_*`-only
  filter would discard root disappearance after the four doctrine reads and
  falsely emit `I_CONSISTENCY_OK`
- no approve-then-reopen path API: hashing and loads require root-relative
  containment and verified bytes from the opened fd
- ambiguous overrides (duplicate precedence, non-refuse disposition)
- `activated: true` or non-`report-only` authority on this slice

## Consistency check (report-only)

`check-consistency` compares selected live doctrine identifiers to the
candidate:

- G1–G16 markers in `docs/14-human-gates.md`
- role `##` headings in `docs/03-roles.md`
- Tier A/B/C markers under Risk tiers in `docs/06-quality-gates.md`
- Stage headings in `docs/02-sdlc-pipeline.md`
- provenance digests vs live file bytes

It does **not** rewrite doctrine and does **not** change existing CI enforcement
outside the focused suite that runs it.

## Mutation receipts

The focused suite proves the gate fails when a fixture:

- deletes or renames a human gate
- weakens a minimum review relationship (Tier C) or any other core RI pin
- drops a forbidden role pairing or makes a pair asymmetric
- corrupts a source digest
- declares an unsupported schema major
- violates schema value parity (enum / boolean type / integer-or-string /
  array cardinality / const / missing required / pattern)
- substitutes a schema-valid but semantically wrong field on `ri.law5`,
  `ri.tier-a`, `ri.tier-b`, or `ri.tier-c`
- adds a schema-valid optional semantic field that must be **absent** for that
  RI id (e.g. `ri.law5` + `tierId`, `ri.tier-a` + `humanGateId`)
- supplies an absolute `--manifest` or a manifest/schema symlink that escapes
  `--repo-root`
- injects a path swap between open and identity/containment acceptance
  (deterministic TOCTOU sensor; fails closed on escape or identity change;
  covers higher-level `loadManifestCandidate` and `checkDoctrineConsistency`)
- replaces/renames the actual canonical root directory between reads inside one
  `checkDoctrineConsistency` operation (frozen root identity refuses the new
  inode at the same pathname)
- replaces the root **after the four doctrine reads / at final revalidation**
  and proves an error with no `I_CONSISTENCY_OK` (early mid-read replacement
  alone is not sufficient); a mutation that reverts to a narrow
  `E_PROVENANCE_*` filter reproduces the false-OK defect
- exercises the exact **replace-through-open/identity-then-restore** window via
  a narrow test hook and records `KNOWN_PORTABLE_BOUNDARY` (docs match real
  portable Node behavior; acceptance of temporary-replacement fd bytes is not
  claimed as a security PASS)
- swaps the `--repo-root` symlink between schema loads (no cache poison)
- opens a FIFO under the root (rejects promptly as non-regular)
- uses a provenance path with an exact `..` segment (while still accepting
  in-root names like `docs/a..b.md` and `docs/..hidden/x.md`)
- appends a later/fifth provenance source that escapes (`../outside.md` or a
  symlink to outside) and proves consistency fails closed with `E_PROVENANCE_*`
- exercises the production BigInt root-identity comparator with values above
  `2^53` that collide under `Number` coercion
- sensor receipt capture is a **raw byte file** (not a shell variable): NUL,
  ESC/ANSI, CR, other C0/C1 controls, invalid bytes, empty lines, early
  sentinel, trailing junk, duplicates, and truncation all fail closed

## Activation work that remains in #164

Parent **#164** still owns:

- generated, clearly delimited doctrine views in AGENTS and tables
- CI hard-fail on stale generated views / unknown IDs (beyond this report suite)
- runtime consumers and any merge-authority wiring
- any semantic change to G1–G16, tiers, or hard-fail controls (those are Tier C
  with an owner decision card — representation-only work must not smuggle them)

## Tier and owner boundary

This slice is **Tier B** control-plane representation. Building and reviewing
the inert encoding may proceed autonomously. **Merge remains an explicit owner
checkpoint** because it introduces a versioned policy schema, even though it
does not activate that schema.

---
[← Doctrine index](00-INDEX.md) · [Home](../index.md)
