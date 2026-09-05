---
title: Lightweight MCTS review panel
nav_order: 27
---

# 27 — Lightweight MCTS Review Panel: Union Over Consensus

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** When more than one reviewer looks at the same change, we
> don't throw away a finding just because only one of them saw it. Every real finding
> gets checked and fixed — reviewers don't have to agree with each other first.

This doc names and generalizes a discipline [doc 20](20-multi-model-orchestration.md)
already practices in one place (rule 3, retroactive adversarial review: "demand
'checked, absent' for every hunted class so silence ≠ safety") into a standing rule
for every multi-reviewer pass. Naming borrowed from Monte Carlo Tree Search: spend the
panel's budget **breadth-first across distinct lenses/branches**, not depth on one —
different reviewers (vendors, or the six lenses in [doc 06](06-quality-gates.md)) miss
different failure classes, so exploring more branches finds more real defects than
running one branch longer.

## The rule

**Union over consensus.** When N reviewers (or N lenses) examine the same diff, the
set of findings that matter is the **union** of everything raised, each verified
independently — never the **intersection** (only what multiple reviewers agreed on).

A finding is kept when it is verified true by re-checking the actual file:line against
the actual diff — the same "claim is not proof" standard as
[doc 20 rule 2](20-multi-model-orchestration.md). A finding is dropped only when
verification refutes it, never because it was a minority report of one.

## Why consensus-gating is the wrong default

Voting schemes ("keep a finding only if 2 of 3 reviewers raised it") optimize for
reviewer agreement, not defect coverage, and agreement is cheapest to get exactly when
it's least informative:

- **Same-vendor reviewers share blind spots.** Two instances of the same model miss
  the same failure class for the same reason. Agreement between them proves nothing
  that one of them running alone didn't already claim.
- **A real, narrow defect is often seen by exactly one lens.** A security-focused pass
  and a UX-focused pass reading the same diff will not converge on each other's
  findings by design — that's the point of running both ([doc 06](06-quality-gates.md)'s
  six lenses exist because no single lens covers the surface).
- **Consensus-gating silently launders coverage.** A dropped single-reviewer finding
  reads, from the outside, identical to a defect class nobody checked for at all. The
  gate can't tell "we looked and it wasn't there" from "only one of us looked."

## What this changes in practice

- **Dispatch stays as-is** ([doc 20](20-multi-model-orchestration.md),
  [doc 10](10-vendor-adapters.md) cross-vendor wiring): cross-vendor review, six
  lenses, retroactive adversarial review when merges outrun review. This doc governs
  only what happens to the findings once they come back.
- **Every returned finding gets independently re-verified** before it's acted on or
  dismissed (rule 2's standard, applied per-finding, not just per-PR).
- **A REQUEST_CHANGES from one reviewer blocks exactly as hard as one from three.**
  Nothing in the merge gate should read "2/3 approved" as a stronger signal than
  "1/1 approved, 1 found a verified defect" — the second state has a known defect in
  it and the first doesn't.
- **Panel budget favors more distinct lenses over more passes of the same lens.**
  Cost is real ([doc 15](15-model-economics.md)) — this is deliberately F-grade,
  judgment-tier spend for Tier C / high-stakes surfaces, not a default for every PR.

## Non-goals

- This does not weaken [doc 20 rule 1](20-multi-model-orchestration.md) (cross-vendor
  review, no exceptions) — it assumes that rule and describes what to do with its
  output.
- This does not mandate a fixed panel size. One reviewer that actually re-verifies is
  still worth more than three that rubber-stamp (doc 03's reviewer contract already
  forbids "LGTM" without findings).
- No dedicated script ships with this doc. It is dispatch-and-verification doctrine
  applied to the existing reviewer role and retroactive-review mechanism — tracked
  follow-up (a panel-summary aggregator that renders "N branches run, M findings,
  0 dropped without a refuting re-check") is in [DOC-BACKLOG.md](DOC-BACKLOG.md).

---
[← 26 · Architecture fitness](26-architecture-fitness.md) · [Home](../index.md) · [28 · Self-learning loops →](28-self-learning-loops.md)
