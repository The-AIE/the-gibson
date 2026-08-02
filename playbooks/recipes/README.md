---
title: "Recipes"
nav_exclude: true
---

# playbooks/recipes/ — machine-readable Goose mirrors

Prose playbooks in `playbooks/*.md` remain the **human-readable source of truth**.
Recipes here are the **schema mirror** for the Goose runtime (epic #30 / #25):
YAML that must validate against the pinned Goose Recipe type.

## Scaffold boundary — not operationally executable yet

Gibson recipe maturity **v0** is a **validation-only scaffold**. The current
`builder.yaml` proves field shape and parameter binding for Goose CLI
**v1.45.0**. It is **not** an authorized operational builder session.

**Do not** treat these files as runnable fleet dispatch until:

1. **#28** — live runtime / red-team spike has been completed, and
2. **#35** — permission and in-session gate enforcement are in place.

Recipe settings cannot encode a Goose permission mode. This scaffold does **not**
set `GOOSE_MODE` or adopt a permission preset. Authorized today: `goose recipe
validate` on the absolute path to a recipe under this directory.

## Two version axes (do not conflate)

| Axis | What it is | This scaffold |
|---|---|---|
| **Goose Recipe schema `version`** | Official Recipe type field (Goose v1.45.0 → `1.0.0`) | Set on each YAML as `version: "1.0.0"` |
| **Gibson recipe maturity** | How far Gibson has hardened recipes as fleet artifacts | **v0** — validation-only scaffold; drift sensor + more roles in #34; live run only after #28 + #35 |

## Format (Goose Recipe type `1.0.0`)

Only fields supported by the official Goose Recipe type. No custom top-level keys
(e.g. do **not** add a `playbook:` field — document the mirror target in this
README table and comments instead).

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
(rule 1).

## Rules

1. **No `latest` pins** — every external extension version is exact.
2. **No doctrine fork** — instructions tell the model to read `AGENTS.md` /
   playbook files; do not paste full law text into the recipe.
3. **Declared variables only** — every `{{ name }}` in instructions/prompt must
   match a parameter `key` (or a Goose built-in such as `recipe_dir`).
4. **Required when interpolated** — if instructions use `{{ issue }}`, `issue`
   must be `requirement: required` (not optional).
5. **Drift** — when a playbook's front-matter or acceptance contract changes,
   touch the matching recipe in the same PR (sensor TBD in #34).
6. **Audit** — runs should stamp `recipe: <name>@<goose-schema-version>` into
   `gibson/journal.md` or `memory/` notes, and may also note Gibson maturity.
7. **No live run before #28 + #35** — validating schema is allowed; dispatching
   a Goose builder session against a repository is not authorized by this v0
   scaffold.

## Files

| Recipe | Mirrors (human playbook) | Goose schema | Gibson maturity |
|---|---|---|---|
| `builder.yaml` | `playbooks/builder.md` | `1.0.0` | v0 (validation-only; live run blocked on #28 + #35) |
| `reviewer.yaml` | `playbooks/reviewer.md` | (follow-up #34) | — |
| `security.yaml` | `playbooks/security.md` | (follow-up #34) | — |
