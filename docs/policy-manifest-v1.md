---
title: "Policy manifest v1 (generated views)"
parent: The Doctrine
nav_order: 27
---

# Policy manifest v1 — canonical manifest, generated views, and offline validator


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** This is the checklist of today's approved rules
> (when to stop, who reviews what, which jobs cannot grade themselves) written
> so a computer can read it. Three marked blocks in `AGENTS.md` are generated
> from it. It is **not** merge authority. A drift check fails if those blocks
> are edited by hand.

## What this is

Issue **#188** ships the first reversible slice of parent architecture issue
**#164**:

| Artifact | Path | Role |
|---|---|---|
| JSON Schema (documentation of shape) | `config/policy/schema/policy-manifest-v1.schema.json` | Stable schema id + version contract |
| Canonical manifest | `config/policy/gibson-core-v1.json` | Source of the three generated AGENTS.md blocks |
| Pure offline validator | `scripts/policy-manifest.mjs` | Fail-closed validation + byte-stable report |
| Focused sensors | `scripts/tests/policy-manifest.test.sh` | Fixtures + mutation receipts |
| This guide | `docs/policy-manifest-v1.md` | Compatibility, forks, upgrade/rollback |

The manifest carries:

- stable **schema id / schema version**, **manifest id / version**
- **status** `canonical`, **authority** `generated-views`, **activated** `true`
- **generatorVersion** and **validatorVersion**
- **source path + sha256 digest** provenance: exactly one `AGENTS.md` source with role `human-readable-contract`; every `docs/**` pin is `explanatory-history` (never `canonical-doctrine` or `compatibility-doctrine`)
- a documented **compatibility** policy (semver major break; namespaced forks)

It encodes, without adding/removing/tightening/loosening approved semantics
owned by `AGENTS.md`:

- human gates **G1–G16** (authority: `AGENTS.md`; `docs/14` is explanatory history)
- risk tiers **A / B / C** and evidence minimums (authority: `AGENTS.md`; `docs/06` is explanation)
- nine roles and forbidden same-unit pairs (authority: `AGENTS.md`; `docs/03` is explanation)
- review-independence relationships (Law 5, tier floors, Tier C cross-vendor floor + G12)
- workflow stage names **plan → retro** (authority: `AGENTS.md`; `docs/02` is explanation)

## What this is not

- **Not** merge, gate, or release authority. `#208` made `AGENTS.md` the
  sole always-mandatory human-readable contract. This file is the source of
  three generated blocks and is not merge authority. `check-drift` fails if a
  block, digest, or marker is wrong. Reports still say they do not activate
  policy authority.
- **Not** a consumer for the context compiler (**#166** consumes a *later*
  resolved bundle, not this manifest by implication).
- Parent **#164** owns this generated-view slice. Runtime merge authority
  stays out of scope.

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

# Rewrite the three marked blocks, then prove a second run is a no-op
node scripts/policy-manifest.mjs render --write
node scripts/policy-manifest.mjs check-drift
```

View markers are `<!-- pv:gates d=<12 hex> -->`, `<!-- pv:tiers d=<12 hex> -->`,
`<!-- pv:roles d=<12 hex> -->`, closed by `<!-- /pv -->`. The digest is the
first 12 hex characters of sha256 over the inner block bytes.

Exit codes: `0` pass, `1` validation, consistency, or view errors (`check-drift`
and `render` also use `1` for unreadable inputs), `2` usage/IO for the other
commands.

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
- for this generated-views manifest, **any** ambiguous override shape (duplicate
  precedence entries, non-`refuse` disposition, core-namespace shadow) is a
  validation **error**.

### Generated-view boundaries

Generated views (the human-gates list, the risk-tier table, and the roles
table) are **outputs**, not merge authority:

- each block is wrapped by a `<!-- pv:… -->` marker whose digest is sha256 of
  the inner bytes;
- `render --write` rewrites only those three blocks and is byte-stable;
- adapters (Claude/Codex/Goose/pi host files) cannot become policy sources.

### Upgrade

1. Bump `manifestVersion` for additive, behavior-preserving clarifications.
2. Refresh provenance digests with `policy-manifest.mjs digest` when the
   candidate intentionally re-pins doctrine sources after a separate doctrine PR.
3. Schema major bumps require a parallel validator that understands the new
   major; old validators must fail closed on the new major.

### Rollback

The manifest is not merge authority. Rollback restores the generated views:

1. Revert the manifest, the three marked blocks, and the validator together.
2. Nothing in this slice reads the file as merge or release authority.

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
  - `ri.tier-c` → tier `C`, `cross-vendor` / preferred `cross-vendor`, gate `G12`
    (Tier C floor is E3 cross-vendor at the exact head + required checks, D-015);
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
  filter would discard root disappearance after the AGENTS.md doctrine read and
  falsely emit `I_CONSISTENCY_OK`
- no approve-then-reopen path API: hashing and loads require root-relative
  containment and verified bytes from the opened fd
- ambiguous overrides (duplicate precedence, non-refuse disposition)
- `activated: false`, a non-`canonical` status, or authority other than `generated-views`
- G12 as a human merge stop, a Tier C `humanMergeGate` of true, or a loosened ratchet / delivery-control notice
- a generated block that does not match `render`, a stale digest, or a missing, duplicate, or unpaired marker (`check-drift`, exit 1)

## Consistency check (report-only)

`check-consistency` compares selected live enumerations in `AGENTS.md` to the
candidate (never falling back to explanatory `docs/`):

- G1–G16 closed-list bullets in `AGENTS.md` (exact multiplicity)
- role enumeration in `AGENTS.md`
- Tier A/B/C table rows in `AGENTS.md`
- Ten stages backtick list in `AGENTS.md`
- forbidden role pairs in `AGENTS.md`
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
- replaces the root **after the AGENTS.md doctrine read / at final revalidation**
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

## What #164 did and what it left

This slice of **#164** promotes the manifest to `config/policy/gibson-core-v1.json`
(`status` canonical, `authority` generated-views, `activated` true), renders
three AGENTS.md blocks, and hard-fails `check-drift` inside the existing
`sensors` job. G12 is the D-015 review floor (`stop: false`). It does **not**
wire merge or release authority, and it does not change G6 or the other human
stops. Runtime consumers remain later work. Any semantic change to G1–G16,
tiers, or hard-fail controls is still Tier C with an owner decision.

## Tier and owner boundary

This slice is **Tier B** control-plane representation. Building and reviewing
the inert encoding may proceed autonomously. **Merge remains an explicit owner
checkpoint** because it introduces a versioned policy schema, even though it
does not activate that schema.

---
[← Doctrine index](00-INDEX.md) · [Home](../index.md)
