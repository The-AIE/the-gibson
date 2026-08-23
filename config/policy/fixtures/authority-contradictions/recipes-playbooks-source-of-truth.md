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
