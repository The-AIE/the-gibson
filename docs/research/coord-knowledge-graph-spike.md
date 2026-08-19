---
title: "Spike: per-project coordination knowledge graph"
nav_exclude: true
---

# Spike: per-project coordination knowledge graph (#105)


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../../AGENTS.md). This file must not add, drop, or weaken those rules.

**Status:** spike findings (2026-08-06)  
**Doctrine:** D-009 / docs/25 §5 — graph is **target-side adapter over existing
substrate**, never a Gibson-core database.  
**Prototype:** `scripts/prototypes/coord-graph-prototype.mjs` (throwaway).

## Node / edge model

| Node kind | Source of truth | Id |
|-----------|-----------------|----|
| `issue` | GitHub issue (or draft JSON) | `#N` |
| `claim` | `docs/claims/<id>.md` or PR-body claim / legacy `active-work.md` | claim id |
| `file` / `route` | claim `scope:` globs; optional `Affected area` paths | path token |
| `lesson` | `memory/LESSONS.md` `## L-NNN` headings | `L-NNN` |
| `decision` | `memory/DECISIONS.md` `## D-NNN` | `D-NNN` |

| Edge | From → To | Source |
|------|-----------|--------|
| `blocks` | issue → issue | `Blocked by #N` / Dependencies (same parser as `decompose-graph.mjs`) |
| `touches` | claim → file | claim `scope:` tokens |
| `owns` | claim → issue | claim id `issue-N-*` or `issue:` field |
| `supersedes` | decision → decision | prose `supersedes D-NNN` in DECISIONS body |
| `tags` | lesson → file/route | `#tags` line / path mentions in lesson body |

## What the prototype proves

1. **Build from substrate only** — no graph store; one Node script reads a
   checkout + optional issue JSON and prints nodes/edges + a simple query
   ("who touches `app/api/**`?", "what blocks #N?").
2. **Overlap with existing sensors** — `blocks` reuses the decompose-graph edge
   idea; `touches` reuses scope-overlap tokens. The graph is a *view*, not a
   second ledger.
3. **Fail closed on missing substrate** — absent `docs/claims` is an empty claim
   set, not a synthetic "unknown" node that authorizes work.

## Recommendation (spike gate)

| Option | Verdict |
|--------|---------|
| **A. Ship as target-side adapter** | **Yes** — keep under `scripts/prototypes/` or later `adapters/coord-graph/` if a target opts in. Never import from core loop/claim/gate path. |
| **B. Promote into Gibson core** | **No** — violates D-009; core stays graph-free except sanctioned sensors (#104/#106). |
| **C. Drop** | **No** — useful for multi-lane targets (ConferenceOS-scale) as an opt-in view. |

### Follow-ups (not this spike)

- Optional `gh` issue pull for `blocks` edges without a hand-written JSON file.
- Wire a read-only Mission Control panel only if a target asks (still adapter).
- Do **not** replace claim/scope sensors with graph queries — sensors stay the teeth.

## How to run the prototype

```bash
node scripts/prototypes/coord-graph-prototype.mjs \
  --repo-path /path/to/target \
  --issues-file /tmp/issues.json \
  --query 'touches:app/api'
```

Exit 0 always for the spike (informational). Production sensors remain the
fail-closed path.
