---
title: "Dogfood evidence"
nav_exclude: true
---

# Dogfood evidence (`memory/dogfood/`)

Append-only home for overnight loop journals and morning notes (issue #96).

## File naming

`YYYY-MM-DD.md` (UTC date the run started) or `YYYY-MM-DD-journal.md` for a raw
copy of `<repo>/gibson/journal.md`.

## Template

```markdown
# Dogfood run — YYYY-MM-DD

## Command
```
scripts/dogfood-prep.sh --repo … --repo-slug … --runner … --run --confirm YES
```

## Host
- runner CLI + version:
- solo-platform: yes/no
- max-iterations / error-budget / stale-budget:

## Outcome
- iterations completed:
- halt reason (HALT file / budget / max / other):
- PRs opened:
- PRs merged (no human between start and review):

## Journal excerpt
(paste or link failures verbatim)

## Lessons filed
- L-NNN …

## Follow-ups
- …
```

Do **not** put secrets, tokens, or private home paths in these files.
