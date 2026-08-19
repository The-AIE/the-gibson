---
title: "24 · AGENTS.md and MEMORY.md conventions"
parent: The Doctrine
nav_order: 24
---

# 24 — AGENTS.md and shared MEMORY conventions


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** Every project gets two simple text files agents read and
> update. One is the rulebook (`AGENTS.md`). One is the shared notebook of lessons
> (`MEMORY.md` or `memory/`). Updating the notebook does not need a full test run.

This is the **canonical** place for how target repos use agent instruction and
memory files. Templates live under `templates/target-repo/`. Target product repos
**copy** these files at adoption; they do not take a runtime git dependency on The
Gibson.

## Two files, two jobs

| File | Job | Who writes |
|------|-----|------------|
| **`AGENTS.md`** | Operating contract: gates, claims, hot files, deploy truth, human-only actions | Humans + rare structural PRs; agents follow it |
| **`MEMORY.md`** (or `memory.md` / `memory/`) | Durable shared lessons so the next agent is not amnesiac | Any agent, dual-write, append-first |

`AGENTS.md` is policy. Memory is scar tissue. Do not dump long session logs into
`AGENTS.md`; do not hide hard rules only in private chat memory.

## Target layout (recommended)

```text
AGENTS.md                 # includes Autonomous development contract (+ memory section)
MEMORY.md                 # short always-loaded index (or memory.md)
memory/                   # optional: LESSONS.md, DECISIONS.md, incidents/
CLAUDE.md                 # @AGENTS.md
.agents/gate.json         # machine-readable green gate
```

Name flexibility: root `MEMORY.md`, root `memory.md`, or `memory/LESSONS.md` are
all fine. Pick one primary index and name it in `AGENTS.md` so every runtime loads
the same file.

## What belongs in memory

**Do put:**

- Failure classes that hit twice (or once and were expensive)
- Merge/claim/CI gotchas specific to this repo
- Deploy truth corrections ("docs said X; host settings say Y")
- Hot-file and concurrency lessons
- Short pointers to harness fixes (issue/PR links)

**Do not put:**

- Secrets, tokens, Production connection strings, API keys
- Full chat transcripts
- Product code or schema changes
- Style commitments that still need the owner (open a decision item instead)

Prefer a **sensor** (test/CI rule) over a long essay when the same failure class
recurs. Memory is the weakest form of the ratchet; sensors are strongest
([docs/09](09-memory-and-self-improvement.md)).

## Dual-write rule

If a runtime keeps local memory (Grok local store, Claude auto-memory, etc.),
**also** write durable facts into the repo memory file in the same session. Local
stores do not survive machine or vendor swaps; git does.

## No CI loop for pure memory commits

**Commits that touch only shared memory markdown skip the product green gate and CI.**

Allowed paths for this fast path (configure per repo in `AGENTS.md`):

- Root `MEMORY.md` / `memory.md`
- `docs/fleet-memory.md` (if used)
- Files under `memory/` (LESSONS, DECISIONS, incidents)

Rules:

1. Do **not** run typecheck / lint / test / build for that commit.
2. Do **not** require product PR review, review-evidence, or post-merge smoke.
3. Prefer a small signed commit that lands on the default branch quickly so other
   agents see the lesson.
4. Any commit that **mixes** memory with product code, workflows, or lockfiles
   follows the normal PR + green gate.
5. Still no secrets in memory files.

This keeps the ratchet cheap. Lessons must not wait behind a full CI cycle.

## Concurrent writers

Two agents may write the same memory file. Risk is merge conflict or lost notes,
not broken builds.

**Default discipline:**

1. **Append-only** — new dated section at the bottom (`## YYYY-MM-DD` or
   `## YYYY-MM-DD — slug`).
2. **Rebase/pull immediately before writing.**
3. **Tiny memory-only commits.**
4. On conflict in dated sections, **keep both** sides.
5. Structural rewrites (reorganize, delete stale blocks) — one agent at a time.

If concurrency stays high, split by topic or day under `memory/` and keep a short
root index.

## AGENTS.md memory block (required on adopt)

Every adopted target should include a short section equivalent to
`templates/target-repo/AGENTS-section.md` → **Shared agent memory**. It must:

- Name the memory file(s) to read at session start
- State dual-write
- State the no-CI exception for pure memory commits
- Forbid secrets

## Relationship to Gibson fleet memory

| Store | Scope |
|-------|--------|
| Target `MEMORY.md` / `memory/` | Lessons about **that product repo** |
| Gibson `memory/LESSONS.md` | Lessons about **the harness** and cross-repo patterns |
| Mission Control memory | Short-lived runtime coordination |

Promote a target lesson into Gibson `memory/LESSONS.md` when it is harness-general
(e.g. a gate bug, a worktree rule). Keep product-specific merge gotchas in the
target.

## Adoption checklist (memory slice)

From [docs/13](13-adoption.md):

1. Append/merge `templates/target-repo/AGENTS-section.md` (includes memory block).
2. Seed `MEMORY.md` from `templates/target-repo/MEMORY.md` (or `memory/LESSONS.md`).
3. Point `CLAUDE.md` at `@AGENTS.md`.
4. Confirm agents can land a pure memory commit without running the product gate.

## Templates

| Path | Purpose |
|------|--------|
| [`templates/target-repo/AGENTS-section.md`](../templates/target-repo/AGENTS-section.md) | Contract section to append, including memory |
| [`templates/target-repo/MEMORY.md`](../templates/target-repo/MEMORY.md) | Seed index for a target repo |

---
[← 23 · Delivery control](23-delivery-control.md) · [Home](../index.md) · [09 · Memory and self-improvement](09-memory-and-self-improvement.md)
