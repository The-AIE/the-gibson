# MEMORY.md — shared agent memory

**Read this early** in any coding, review, or merge session.
**Update it** when the same failure class appears twice (prefer a test/sensor over a long essay).

Keep this file short so every agent loads it. Expand long-form detail in optional
files under `memory/` if the index grows.

### Dual-write rule (mandatory)

Whenever an agent writes durable operational memory in a local runtime store,
**also write here** so other agents and machines share the same context.

### No CI loop for memory-only updates

Commits that touch **only** this file (and optional pure memory paths named in
`AGENTS.md`) do **not** require typecheck, lint, test, build, product PRs, or
required CI. Land the lesson on the default branch quickly.

Mixed memory + product code still uses the normal green gate.

Canonical convention: The Gibson `docs/24-agent-memory-conventions.md`
(copy at adoption; this file is owned by **this** repo thereafter).

_Last updated: YYYY-MM-DD_

---

## Operating notes

| Topic | Rule |
|-------|------|
| Claims | <how this repo claims work> |
| Green gate | See `AGENTS.md` / `.agents/gate.json` |
| Deploy | <production branch and host, verified> |

---

## Lessons (append-only)

### How to add a lesson

1. `git fetch && git rebase origin/<default-branch>` (or equivalent).
2. Append a new dated section at the **bottom** — do not rewrite history.
3. Commit **only** memory files; skip the product CI loop.
4. Never put secrets, tokens, or Production connection strings here.

```markdown
## YYYY-MM-DD — <short-slug>

- **What happened:** …
- **Root cause:** …
- **Fix / rule:** …
- **Links:** issue/PR if any
```

---

## YYYY-MM-DD — adoption-seed

- Repo adopted Gibson agent-memory conventions (AGENTS memory block + this file).
- Pure memory commits skip the product green gate; dual-write is mandatory.
