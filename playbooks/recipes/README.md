---
title: "Recipes"
nav_exclude: true
---

# playbooks/recipes/ — machine-readable Goose mirrors

Prose playbooks in `playbooks/*.md` remain the **human-readable source of truth**.
Recipes here are the **executable mirror** for the Goose runtime (epic #30 / #25).

## Two version axes (do not conflate)

| Axis | What it is | This scaffold |
|---|---|---|
| **Goose Recipe schema `version`** | Official Recipe type field (Goose v1.45.0 → `1.0.0`) | Set on each YAML as `version: "1.0.0"` |
| **Gibson recipe maturity** | How far Gibson has hardened recipes as fleet artifacts | **v0** — scaffold only; drift sensor + more roles in #34 |

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
extensions: []   # MCP / stdio extensions with pinned versions — never "latest"
```

Each parameter **must** include `key`, `input_type`, `requirement`, and
`description` (Goose Recipe parameter schema). Use `parameters` (not `params`).

## Rules

1. **No `latest` pins** — every extension version is exact.
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

## Files

| Recipe | Mirrors (human playbook) | Goose schema | Gibson maturity |
|---|---|---|---|
| `builder.yaml` | `playbooks/builder.md` | `1.0.0` | v0 |
| `reviewer.yaml` | `playbooks/reviewer.md` | (follow-up #34) | — |
| `security.yaml` | `playbooks/security.md` | (follow-up #34) | — |
