---
title: Guarded state transitions
nav_order: 29
---

# 29 — Guarded State Transitions: Illegal Moves Fail Loud

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** Claims, loop state, and decisions each move through a small
> set of stages — claimed, released, frozen, approved, and so on. This doc says: write
> down which moves are allowed, and make anything else fail with a clear error instead
> of quietly writing bad data.

**Status:** doctrine only — no shipped enforcement sensor yet. Tracked in
[DOC-BACKLOG.md](DOC-BACKLOG.md). Per [CONVENTIONS.md](CONVENTIONS.md)'s meta-rule,
this doc does not claim any existing script already implements it.

## The problem this names

Several of the Gibson's durable objects — a claim file, `gibson/loop-state.md`, a
`memory/DECISIONS.md` entry — move through an implicit lifecycle (unclaimed →
claimed → released; draft → approved) that today lives only in prose and in whatever
order the scripts happen to write fields. `scripts/validate-loop-state.sh` checks the
**shape** of loop-state (required keys, freshness) but nothing in the harness today
checks whether a given write is a **legal move** from the state before it. A script
bug, a race between two writers, or a stale worktree can write a technically
well-formed but logically impossible transition (a claim released twice, a decision
marked `approved` with no `frozen` predecessor) and nothing objects.

## The rule

**Name the allowed transitions. Refuse anything else, loudly.**

For any durable object with a status field, the doctrine that owns it names:

1. The full set of states.
2. For each state, the states it may legally move to next.
3. What guard (which identity, which precondition) is required to make that move.

A script that writes a new status checks the move against this table first. An
illegal move is a **nonzero exit with the attempted and current state named**, not a
silent write — the same "fail closed" posture [doc 26](26-architecture-fitness.md)
already uses for broken evidence.

## Worked example (illustrative — not a claim about current script behavior)

A claim's natural lifecycle:

```text
unclaimed ──claim(session_id)──▶ claimed ──release(session_id)──▶ released
                                     │
                                     └──timeout──▶ expired
```

Illegal moves a guard would reject: `claimed → claimed` (double-claim by a different
session), `release()` called by a session ID that doesn't match the claimant,
`released → released` (double-release), any direct write to a state not reachable
from the current one. The guard's job is narrow: check the move, not re-implement
claim semantics — [doc 05](05-concurrency.md) still owns those.

## Frozen decision packages — a transition, not a new mechanism

[Doc 23](23-delivery-control.md)'s promote step already binds a production advance to
a **verified SHA on `main`** rather than a loose "looks done." The same discipline
generalizes to any formal review point, including Tier C approval and Blueprint
sign-off: treat a decision or spec artifact as moving through its own small state
machine —

```text
draft ──▶ rfi-resolved ──▶ frozen ──▶ approved ──▶ superseded
```

**Frozen** means the artifact's content hash is recorded at the moment of formal
review — the same object a human approved is the object whose hash a later diff can
be checked against, so drift after approval (an edit that lands without a fresh
approval) is detectable rather than assumed away. **Superseded** entries are never
rewritten; a correction is a new entry that links back, matching the append-only
convention `memory/DECISIONS.md` and `memory/LESSONS.md` already use.

This is not a new gate — G10/G12 ([doc 14](14-human-gates.md)) still decide *when* a
human reviews something. This only says: once reviewed, record what exactly was
reviewed, so "approved" can't silently drift to mean "approved, plus whatever changed
after."

## What this does not do

- It does not replace [doc 05](05-concurrency.md)'s claim/worktree/hot-file rules —
  it adds a legality check on top of them.
- It does not change any of G1–G16 ([doc 14](14-human-gates.md)) or Tier definitions.
- It does not mandate a specific implementation (a JSON transition table, a shell
  case statement, a jq guard) — the shape is doctrine; the enforcement script is
  follow-up work, tracked in [DOC-BACKLOG.md](DOC-BACKLOG.md).

---
[← 28 · Self-learning loops](28-self-learning-loops.md) · [Home](../index.md)
