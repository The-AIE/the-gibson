---
title: "15 · Spending AI money wisely"
parent: The Doctrine
nav_order: 15
---

# 15 — Model Economics: Which Mind for Which Task


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** Different tasks need different AI strength and cost different
> amounts. Use the cheaper option when it is good enough, and save the expensive models
> for hard problems that truly need them.

**Operator procedure** (routing table, budgets, capsules, telemetry, checklist):
[playbooks/token-efficiency.md](../playbooks/token-efficiency.md). This doc is
doctrine only — *why* the grades and pool shapes exist. It does **not** record
current vendor list prices or billing settings; those change and must not be
copied into prompts as facts.

Routing has two axes: **capability required** (can this model clear the quality bar
for this task class?) and **marginal cost** (what does the next unit of work
actually cost in *this* pool?). Flat-rate / saturable subscription pools have
**near-zero marginal cost until saturated**; metered API usage is full price every
time. Do not hard-code dollar amounts here.

## Efficiency is not minimization

Pushing cost-per-merged-PR down is the goal of this doc **only while** green gate,
exact-head CI, cross-vendor review, security, and owner gates stay absolute. Skipping
sensors, truncating required evidence, reusing a stale review, or grading high-stakes
evaluation below its floor is not thrift — it is quality debt. See the playbook's
"Efficiency ≠ minimization" table.

## The pools (by plan shape, not by today's sticker price)

| Pool shape | Marginal cost character | Saturation risk | Role in the fleet |
|---|---|---|---|
| **Flat-rate / high-cap subscription** (any vendor that fits) | Near-zero until saturated | Usually low — prefer for volume | Default grind implementer and bulk solo-loop |
| **Subscription with usage caps** | Zero until cap, then real | Medium — reserve headroom for hard work | Skilled feature work; judgment when the bar requires it |
| **Metered APIs** (any vendor) | Full price per use | n/a — spend deliberately | Only work that truly needs that metered surface |

Standing order: **flat-rate pools absorb all volume work; metered usage buys only
judgment.** Never pay metered rates for work a saturable subscription could grind.
(Baseline for why this matters: one unbounded coordinator session once cost on the
order of a triple-digit dollar bill — L-003. Bounded workers + routing discipline is
the fix, not austerity or invented price tables.)

Name specific runners (Grok, Codex, Claude, Hermes) only as **examples of where a
shape often sits today**. Re-validate against your installed CLIs and current plan
pages; never treat a remembered monthly fee as doctrine.

## Task-class → tier heuristic

Grade every dispatch **G / S / F** (Grind / Skilled / Frontier):

| Grade | Definition | Route by shape | Examples |
|---|---|---|---|
| **G — Grind** | High volume, verifiable by deterministic gates; wrong answers are cheap because sensors catch them | Flat-rate / high-cap first; second pool only if needed | solo-loop iterations, Tier A builds, test scaffolding, lint/mechanical refactors, research sweeps, route-inventory generation, retry-until-green |
| **S — Skilled** | Multi-file reasoning, framework subtlety, real debugging; gates catch *some* failure | Cap-aware subscription or flat-rate if it clears the bar; escalation armed | Tier B builds, integration tests, decomposition of a clear plan, standard reviews, UX eval runs |
| **F — Frontier** | Judgment-heavy; failure is expensive or invisible to sensors; taste matters | Best available model that clears the bar (often a reserved subscription or metered peak) | planning + design language, Tier C adversarial review, security exploit reasoning, architecture decisions, incident response, harness changes |

Two structural rules on top:

1. **Generation may be cheap; evaluation is not.** Tier B evaluation must be at
   least **S**. Tier C review (adversarial / merge-gate judgment) must be **F** —
   never imply that an S-grade review clears Tier C. A G-grade generator with an
   F-grade reviewer is a good trade — the reviewer is reading a bounded diff, the
   generator burned low-marginal-cost tokens getting there.
2. **Cross-vendor beats same-vendor at equal grade** (independent failure modes),
   so prefer the *other* pool's equal-grade model for review even when your own is
   available.

## The escalation ladder

Start at the cheapest grade plausibly sufficient; escalate on signal, never on vibes:

```text
attempt at grade N
  → gate fails twice on the same criterion   → retry once with enriched context
  → fails again (3rd)                        → escalate one grade, hand over the
                                                loop-state + failure history
  → F-grade fails twice                      → it's not a model problem: park it,
                                                file a lesson (bad decomposition
                                                or bad contract — doc 09)
```

Operational budgets (`--error-budget`, `--stale-budget`, `--escalate-after`,
`--max-iterations`) live in `scripts/loop.sh` and the token-efficiency playbook —
not as magic numbers re-derived per prompt.

De-escalation is equally mandatory: the historian's quarterly review moves task
classes *down* a grade when a cheaper pool's success rate on that class exceeds 90%
(model improvements make yesterday's S-task today's G-task — principle 1's
downward stress-test, applied to money).

## Token-shape rules (all grades)

- **Bounded workers:** one issue, exact file list, short output contract. Unbounded
  coordinators are the documented cost pathology (L-003).
- **Fresh context per hat** (doc 11) beats one long session — cheaper *and* better.
- **Checkpoint before half the context window** on long metered sessions.
- **No-model checks stay no-model:** health checks, claim verification, gate runs
  are scripts, not prompts.
- **Cost telemetry:** `scripts/cost-ledger.sh` records only supported usage and
  context fields (runner/pool, wall time, tokens/ACUs **when the runtime reports
  them**, issue/PR/iteration, optional note). Merge outcome is **not** a ledger
  field — track it separately via GitHub or the journal (and optional
  `summarize --merged-since` input you already have). Missing usage stays unknown
  — never invent tokens or dollars. The weekly retro reports cost- or
  effort-per-merged-PR per pool — the number this whole doc exists to push down
  **without** lowering the quality bar.

## Worked default (illustrative fleet shape)

Re-check which CLIs you actually have installed before treating names as law:

- Solo loop grinding a backlog overnight → **flat-rate grind runner** (G), escalating
  individual hats per the ladder; Tier C review hats shell out to a **different-vendor
  frontier read-only** (F).
- Daytime feature work → **skilled** builders (S) with **cross-vendor review**;
  planning sessions with the owner → **Frontier**.
- Research sweeps, second opinions, X-adjacent anything → grind/skilled on the
  high-cap pool (G/S).
- Messaging, digests, cron ops → **Hermes** (or equivalent) with a cheap model (G) —
  fleet voice, not fleet brain.

For copy/paste invocation, WIP limits, operator checklist, and measurement steps,
use [playbooks/token-efficiency.md](../playbooks/token-efficiency.md).

---
[← 14 · The sixteen interruptions](14-human-gates.md) · [Home](../index.md) · [16 · No terminal required →](16-nontechnical-operation.md)
