---
title: "Recipes"
nav_exclude: true
---

# playbooks/recipes/ — machine-readable Goose mirrors


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../../AGENTS.md). This file must not add, drop, or weaken those rules.

Prose playbooks in `playbooks/*.md` and `playbooks/red-team/` remain the
**human-readable source of truth**. Recipes here are the **schema mirror** for
the Goose runtime (epic #30 / #25): YAML that must validate against the pinned
Goose Recipe type.

## Scaffold boundary — not operationally executable yet

Gibson recipe maturity **v0** is a **validation-only scaffold**. The shipped
recipes prove field shape, parameter binding, and (for red-team) toolchain
pins for Goose CLI **v1.45.0**. They are **not** authorized operational sessions.

**Do not** treat these files as runnable fleet dispatch until:

1. **#28** — live runtime / red-team spike has been completed under Mark's
   supervised read-only lab approval (fake data, test payment mode, exact
   target, cost/credential approval), and
2. **#35** — permission and in-session gate enforcement are in place
   (separate decision; not claimed by this scaffold).

Recipe settings cannot encode a Goose permission mode. This scaffold does **not**
set `GOOSE_MODE` or adopt a permission preset. Authorized today:

- Offline sensor: `scripts/tests/goose-recipes.test.sh` (required green gate)
- Optional: `goose recipe validate` on the absolute path to a recipe under this
  directory — only if the pinned CLI is already installed. Absence is **NOT RUN**,
  not a pass.

Issue **#25 remains open** until a Mark-authorized #28 run produces a stamped
findings ledger. This slice is partial (`Related: #25` only — never a closing keyword).

## Two version axes (do not conflate)

| Axis | What it is | This scaffold |
|---|---|---|
| **Goose Recipe schema `version`** | Official Recipe type field (Goose v1.45.0 → `1.0.0`) | Set on each YAML as `version: "1.0.0"` |
| **Gibson recipe maturity** | How far Gibson has hardened recipes as fleet artifacts | **v0** — validation-only scaffold; role mirrors + playbook-sha256 drift sensor (#34); live run only after #28 + #35 |

## Core role recipes (#34)

| Recipe | Prose source of truth | Notes |
|---|---|---|
| `builder.yaml` | `playbooks/builder.md` | claim → baseline → implement → gate |
| `reviewer.yaml` | `playbooks/reviewer.md` | read-only six-lens review; never merges |
| `security.yaml` | `playbooks/security.md` | eight-layer interpretation + filing |
| `red-team.yaml` | `playbooks/red-team/PROTOCOL.md` | toolchain pins in sibling lock |

Each role recipe carries:

```text
# playbook: playbooks/<role>.md
# playbook-sha256: <sha256 of the prose playbook file>
```

`scripts/tests/goose-recipes.test.sh` fails when the playbook bytes change without
updating the pin (drift). When you edit a playbook, recompute:

```bash
sha256sum playbooks/reviewer.md   # or builder.md / security.md
# paste into the matching recipe's # playbook-sha256: line
```

### Audit stamp

Live or dry-run sessions end by calling:

```bash
scripts/recipe-stamp.sh --role reviewer \
  --recipe playbooks/recipes/reviewer.yaml \
  --issue 42 --repo /path/to/worktree --pr 123
```

Rows append to `memory/recipe-runs.md` (no secrets / home paths).

## Format (Goose Recipe type `1.0.0`)

Only fields supported by the official Goose Recipe type. No custom top-level keys
(e.g. do **not** add a `playbook:` or `toolchain:` field — document the mirror
target in this README table and comments instead; bind pins in a sibling
`*.toolchain.json` for red-team).

Official top-level keys recognized here: `version`, `title`, `description`,
`instructions`, `prompt`, `extensions`, `settings`, `activities`, `author`,
`parameters`, `response`, `sub_recipes`, `retry`. Gibson recipes in this tree
use the minimal subset matching `builder.yaml` / `red-team.yaml`.

```yaml
version: "1.0.0"
title: string
description: string
instructions: |
  Multi-line instructions. Prefer referencing doctrine files on disk
  rather than forking their text. Use declared parameters as
  {{ key }} template variables.
parameters:
  - key: repo
    input_type: string
    requirement: required
    description: Absolute path to the worktree / target repo
  - key: issue
    input_type: string
    requirement: required
    description: GitHub issue number (required when instructions interpolate it)
  - key: gibson
    input_type: string
    requirement: required
    description: Absolute path to the Gibson clone
extensions:
  # Bundled in the pinned Goose CLI (v1.45.0): shell + filesystem.
  - type: builtin
    name: developer
# Future external MCP extensions still require exact pinned versions
# (never "latest") once #33 maps target-repo needs. Example only:
# - type: stdio
#   name: example
#   cmd: npx
#   args: ["-y", "some-mcp@1.2.3"]
```

Each parameter **must** include `key`, `input_type`, `requirement`, and
`description` (Goose Recipe parameter schema). Use `parameters` (not `params`).

The format example matches the shipped builder recipe: the **bundled**
`developer` builtin is listed so schema mirrors stay consistent with what
validation expects. Future **external** extensions remain exactly pin-gated
(rule 1). Bundled extensions may be named without an external package version
only when docs clearly identify them as bundled with the pinned Goose binary.

## Toolchain lock (red-team)

`red-team.toolchain.json` is deterministic JSON binding every external CLI /
package / container / MCP identity the red-team recipe or protocol references:

- Schema/version field + unique tool `id`s
- Exact releases/commits/digests only (no `latest`, `stable`, `main`/`master`,
  `*`, `x`, caret/tilde ranges, mutable tags, unqualified npx packages, or
  floating git refs)
- Compact authoritative `source_url` / `source_meta_url` + `retrieved_utc`
- Goose CLI v1.45.0 macOS arm64 asset SHA-256 as already recorded in
  `adapters/goose/README.md` (strategy pin — do not silently change)
- Paid clients (e.g. Socket CLI) are pinned exactly and marked
  `execution: owner-gated` — do not invent a token or claim they ran
- Digest instructions for recipe + lock using `shasum -a 256` / `sha256sum`
  (macOS-available). **Do not commit generated run digests.**

## Rules

1. **No floating pins** — every external extension/package/image version is exact.
2. **No doctrine fork** — instructions tell the model to read `AGENTS.md` /
   playbook / protocol files; do not paste full law or protocol text into the recipe.
3. **Declared variables only** — every `{{ name }}` in instructions/prompt must
   match a parameter `key` (or a Goose built-in such as `recipe_dir`).
4. **Required when interpolated** — if instructions use `{{ issue }}`, `issue`
   must be `requirement: required` (not optional).
5. **Drift** — when a playbook's front-matter or acceptance contract changes,
   touch the matching recipe in the same PR (sensor TBD in #34).
6. **Audit** — runs should stamp recipe + toolchain digests into the findings
   ledger (red-team) or `gibson/journal.md` / `memory/` notes (roles), and may
   also note Gibson maturity.
7. **No live run before #28 + #35** — validating schema is allowed; dispatching
   a Goose session against a repository/target is not authorized by this v0
   scaffold. #28 live red-team additionally requires Mark's supervised lab gate.

## Offline sensor vs official Goose vs live

| Layer | What it proves | Gate |
|---|---|---|
| `scripts/tests/goose-recipes.test.sh` | Structure, params, pins, lock JSON, findings stamp fields | **Required** offline green |
| `goose recipe validate` | Official Goose schema acceptance | Optional; **NOT RUN** if binary absent |
| Live `goose run` / target attack | Real audit | **Owner-gated** (#28 Mark approval + later #35 enforcement) |

## Files

| Recipe | Mirrors (human playbook) | Goose schema | Gibson maturity | Toolchain lock |
|---|---|---|---|---|
| `builder.yaml` | `playbooks/builder.md` | `1.0.0` | v0 (validation-only; live run blocked on #28 + #35) | — |
| `red-team.yaml` | `playbooks/red-team/PROTOCOL.md` + `targets/*` + `findings/TEMPLATE.md` | `1.0.0` | v0 (validation-only; live #28 Mark-gated) | `red-team.toolchain.json` |
| `reviewer.yaml` | `playbooks/reviewer.md` | (follow-up #34) | — | — |
| `security.yaml` | `playbooks/security.md` | (follow-up #34) | — | — |
