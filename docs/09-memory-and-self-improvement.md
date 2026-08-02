---
title: "09 · How it learns from mistakes"
parent: The Doctrine
nav_order: 9
---

# 09 — Memory and Self-Improvement

> 🙂 **In plain English:** The crew remembers mistakes in simple shared files, not in one
> AI's private memory. When something fails twice, the lesson is written down so the
> next agent does not repeat it.

The Gibson's memory answer is deliberately boring: **git is the memory substrate.**
Markdown files in `memory/`, versioned, reviewable, greppable, vendor-neutral, and
carried to every runtime by `git pull`. Ruflo's lesson applies — hooks + memory
storage unlock most of the value — and its HNSW vector store needs ~1,000
trajectories before beating grep. We are not there; when we are, a vector index is
an *adapter over* these files, not a replacement.

**Target repos** use the same idea: root `MEMORY.md` / `memory.md` (and optional
`memory/`) plus an `AGENTS.md` block. Full target convention, dual-write, concurrent
writers, and **no CI for pure memory commits**:
[docs/24-agent-memory-conventions.md](24-agent-memory-conventions.md).
Templates: `templates/target-repo/MEMORY.md`, `templates/target-repo/AGENTS-section.md`.

Two stores, two jobs (harness side):

| Store | Job | Medium |
|---|---|---|
| **The Gibson `memory/`** | Durable doctrine-adjacent knowledge: lessons, decisions, incidents | Markdown in this repo |
| **Mission Control `memory` table** | Runtime coordination: project status, handoffs, "who's doing what" | Supabase via MCP `remember`/`recall` |

Rule of thumb: if it should still matter in a month, it's a Gibson memory; if it
matters until the task closes, it's an MC memory. The historian promotes the former
out of the latter. Product-specific scar tissue lives in the **target** `MEMORY.md`,
not only here.

## The memory files

**`memory/LESSONS.md`** — append-only. One entry per lesson:

```markdown
## L-047 · 2026-07-24 · <slug>
**What happened:** <failure/surprise, with repo + PR/issue links>
**Root cause:** <one sentence>
**Harness fix:** <the guide or sensor that now prevents it — link the PR>
**Status:** fixed | fix-pending (issue #N)
**Tags:** #security #nextjs #decomposition ...
```

**`memory/DECISIONS.md`** — architecture/process decisions with rationale (ADR-lite):
what was decided, alternatives rejected, revisit condition.

**`memory/incidents/`** — one file per real incident (data loss, outage, security
event): timeline, impact, resolution, lessons spawned.

Agents **read** lessons at session start (Law 1) — tag-filtered to their role and
target area, so it stays cheap. Agents **write** lessons per Law 9.

**Pure `memory/`-only commits on this repo skip the green gate** (AGENTS.md Law 4
exception) so lessons land without a full CI cycle. Same rule is required on
adopted targets (doc 24).

## The ratchet (the self-correcting loop)

The loop, from Fowler, made mandatory:

```
failure/surprise ──▶ lesson filed ──▶ harness fix PR'd ──▶ gate/doc improved
      ▲                                                          │
      └────────────── future agents can't hit it ◀───────────────┘
```

**Trigger conditions** (any one suffices):
- The same failure occurred twice, anywhere in the fleet.
- A failure passed every gate and was caught late (review, eval, prod).
- A task cost ≥ 3× its estimate, or failed twice on dispatch
  ("prompts that need better acceptance criteria, not better models").
- An agent was surprised — the docs said X, reality said Y.

**Fix forms, in order of preference** (most deterministic first):
1. A **sensor**: lint/Semgrep rule, test, CI check, generated-file guard. Best,
   because it's self-enforcing forever.
2. A **guide**: a doc/AGENTS.md/playbook edit. Good, but only as strong as Law 1.
3. A **memory**: a lesson alone, when no general fix exists yet. Weakest; the
   historian revisits these monthly looking for the emergent pattern.

**Who fixes:** the agent that hit it, in the same session, when the fix is small
(Fowler: "agents can help build their own controls"). Otherwise it files a
`harness-improvement` issue on The Gibson and the fleet builds it like any other work
— The Gibson dogfoods its own pipeline.

## Automated retro (the sweep)

A scheduled workflow (weekly) + the historian role:

1. Pull the exhaust: merged PRs, CI failure history, review verdicts,
   REQUEST_CHANGES reasons, eval reports, MC task outcomes and `cost_usd`,
   twice-failed tasks.
2. Cluster recurring causes; check each against existing lessons.
3. File lessons + `harness-improvement` issues; post a digest (via Hermes) to Mark:
   what the fleet learned this week, what it changed about itself, cost trend.

This converts Mission Control's *manual weekly human ritual* into an automated sweep
with a human-readable digest — the compounding is no longer optional.

## Self-modification bounds

pi.dev normalizes agents extending their own harness; The Gibson allows it with
gates:
- Harness changes go through the same pipeline (PR + review) as product changes —
  the harness never gets a lower bar than the code it governs.
- Changes to **human gates** (doc 14), Tier definitions, or hard-fail security
  layers are themselves Tier C: human approval required. The ratchet may tighten
  autonomously; it may only loosen with Mark's sign-off.
- The quarterly *downward* stress-test (principle 1): the historian proposes removing
  controls that stronger models have made into pure friction, with evidence.

---
[← 08 · The security system](08-security.md) · [Home](../index.md) · [10 · Any AI, same rules →](10-vendor-adapters.md) · [24 · AGENTS + MEMORY conventions](24-agent-memory-conventions.md)
