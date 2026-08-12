---
title: "Policy manifest v1 (report-only candidate)"
parent: The Doctrine
nav_order: 27
---

# Policy manifest v1 — report-only candidate and offline validator

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
- **Not** a change to `AGENTS.md`, numbered doctrine, playbooks, CI hard-fail,
  merge authority, or runtime consumers.
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
- unknown or duplicate IDs
- broken references (roles, gates, tiers, stages)
- contradictory tier ↔ gate mappings (e.g. G12 on Tier A)
- missing required forbidden pairs; asymmetric pairs without reverse edges
- unsafe fork namespaces (including core `gibson.` shadow)
- malformed provenance (path escapes, non-sha256 digests)
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
- weakens a minimum review relationship (Tier C)
- drops a forbidden role pairing or makes a pair asymmetric
- corrupts a source digest
- declares an unsupported schema major

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
