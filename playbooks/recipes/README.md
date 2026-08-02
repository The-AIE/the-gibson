---
title: "Recipes"
nav_exclude: true
---

# playbooks/recipes/ — machine-readable Goose mirrors

Prose playbooks in `playbooks/*.md` remain the **human-readable source of truth**.
Recipes here are the **executable mirror** for the Goose runtime (epic #30 / #25).

## Format (v0)

```yaml
version: "0.1"
title: string
description: string
# Human playbook this mirrors (path relative to Gibson root)
playbook: playbooks/builder.md
instructions: |
  Multi-line instructions. Prefer referencing doctrine files on disk
  rather than forking their text.
params:
  - name: repo
    description: Absolute path to the worktree / target repo
  - name: issue
    description: GitHub issue number (optional)
  - name: gibson
    description: Absolute path to the Gibson clone
extensions: []   # MCP / stdio extensions with pinned versions — never "latest"
```

## Rules

1. **No `latest` pins** — every extension version is exact.
2. **No doctrine fork** — instructions tell the model to read `AGENTS.md` /
   playbook files; do not paste full law text into the recipe.
3. **Drift** — when a playbook's front-matter or acceptance contract changes,
   touch the matching recipe in the same PR (sensor TBD in #34).
4. **Audit** — runs should stamp `recipe: <name>@<version>` into
   `gibson/journal.md` or `memory/` notes.

## Files

| Recipe | Mirrors |
|---|---|
| `builder.yml` | `playbooks/builder.md` |
| `reviewer.yml` | `playbooks/reviewer.md` (follow-up #34) |
| `security.yml` | `playbooks/security.md` (follow-up #34) |
