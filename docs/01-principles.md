---
title: "01 · Why it's built this way"
parent: The Doctrine
nav_order: 1
---

# 01 — Design Principles


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** This chapter is the "why" behind every rule. Each rule comes
> from a real mistake or a proven idea. When two rules disagree, you follow the one that
> better protects people and the software.

Every rule in this repo traces to one of these principles, and every principle traces
to a source that earned it — a production incident, a published harness design, or a
measured result. When a rule and a principle conflict, the principle wins and the rule
gets a PR.

## 1. Agent = Model + Harness — and only the harness compounds

Models improve on the vendor's schedule; the harness improves on ours. Every dollar of
effort goes into artifacts that survive a model swap: Markdown doctrine, deterministic
scripts, CI gates, versioned memory. (Fowler; ruvnet's "harness-not-model" thesis.)

**Corollary:** the harness must be *stress-tested downward* as models improve. Every
component encodes an assumption about what the model can't do alone; Anthropic found
sprint structure necessary for Sonnet 4.5 and overhead for Opus 4.6. Re-evaluate
components quarterly — the ratchet removes controls too, when they've become friction.

## 2. Guides and Sensors

Two control types, from Fowler:

- **Guides (feedforward):** steer before action — AGENTS.md, architecture docs,
  conventions, scaffolds, bootstrap scripts, design languages, playbooks.
- **Sensors (feedback):** observe and correct after — typecheckers, linters, tests,
  build gates, DAST scans, review agents, UX evaluators, drift monitors.

Sensors split further into **computational** (deterministic, fast, cheap — run them
early and always) and **inferential** (LLM judgment — slower, probabilistic, richer —
spend them where determinism can't reach: semantics, security reasoning, taste).
"Keep quality left": cheap checks pre-commit, expensive checks post-integration,
drift sensors continuously.

## 3. Never grade your own homework

Anthropic's strongest finding: generators praise their own work regardless of quality;
a *separate evaluator tuned to skepticism* is far more tractable than a self-critical
generator. Mission Control operationalizes this as cross-vendor review by default
(`reviewer_platform` ≠ worker platform). The Gibson extends it: evaluation runs
against **running software** — Playwright clicking a live deployment — never against
the generator's summary of what it built.

## 4. The contract precedes the code

Sprint contracts (Anthropic): testable done-criteria agreed *before* implementation
begins, embedded in the issue. The evaluator grades against the contract, not vibes.
ConferenceOS's `test.todo`-per-spec-line is the same idea in Vitest form: the contract
becomes executable and its todo-count must go down.

## 5. Primitives, not features

pi.dev's stance, validated negatively by ruflo (35 plugins → "lite" install path as an
admission of overload) and positively by Mission Control (borrowed the queen/worker
concept, skipped the 210-tool install). The Gibson core is: Markdown + git + shell +
GitHub Actions. Everything else — skills, hooks, dashboards, vector memory — is an
adapter or extension that can be dropped without breaking doctrine.

Ruflo's own 80/20, which we adopt: **hooks + memory storage unlock most of the
coordination value.** Trust scoring, consensus topologies, and vector indexes come
later, if ever, when measured need appears.

## 6. The ratchet: failures become infrastructure

Fowler: "Whenever an issue happens multiple times, the feedforward and feedback
controls should be improved to make the issue less probable." Mission Control's weekly
ritual: tasks that failed twice are prompts needing better acceptance criteria, not
better models.

The Gibson makes this a **standing obligation, not a ritual**: any agent hitting a
repeated or uncaught failure files a lesson (`memory/LESSONS.md`) and, where possible,
PRs the fix to the harness itself — a new lint rule, a new gate, a doc correction.
Agents build their own controls. The historian role and the weekly retro workflow
sweep whatever individual agents missed. Details: `docs/09-memory-and-self-improvement.md`.

## 7. Isolation is physical, coordination is explicit

ConferenceOS learned this from a real incident (2026-07-18: silently clobbered schema
work, ~75 type errors): worktrees isolate *files* so collisions are physically
impossible; claim rows + labels isolate *logical scope*; hot-file rules isolate
*merge conflicts*; schema serialization isolates the *production database*. Four
layers, each for a distinct failure mode. None optional.

## 8. Autonomy by default, human gates by exception — and enumerated

An agent that stops to ask "shall I proceed?" on reversible, in-scope work has failed.
An agent that proceeds through a human gate has failed worse. The resolution is a
**closed, one-page list** of mandatory stops in `AGENTS.md` (rationale:
`docs/14-human-gates.md`). If a situation isn't on the AGENTS.md list, keep
working. If the list is wrong, PR the list.

## 9. Truthful telemetry, owned store

Mission Control doctrine: agents push, nobody polls; deterministic reporting (hooks,
watchers) is ground truth for liveness, semantic reporting (MCP) is ground truth for
meaning; everything lands in a store *we* own. And reporting is honest: failures
verbatim, skips named, "done" only after verification.

## 10. Harnessability is a property of the target repo

Fowler's "ambient affordances": typed languages, clear module boundaries, generated
barrels instead of hand-edited hot files, auto-discovered nav/reports — these make a
codebase tractable to agents. Adoption of The Gibson (`docs/13-adoption.md`) therefore
includes a harnessability audit, and builders are licensed to *improve* affordances
(de-hot files, add generators) as first-class work.

---
[Home](../index.md) · [02 · The assembly line →](02-sdlc-pipeline.md)
