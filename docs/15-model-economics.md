---
title: "15 · Spending AI money wisely"
parent: The Doctrine
nav_order: 15
---

# 15 — Model Economics: Which Mind for Which Task

Routing has two axes: **capability required** (can this model clear the quality bar
for this task class?) and **marginal cost** (what does the next token actually
cost us?). The fleet's pricing reality makes the second axis sharp: flat-rate
subscription pools have **near-zero marginal cost until saturated**; metered API
tokens are real dollars every time.

## The pools

| Pool | Plan shape | Marginal cost | Saturation risk |
|---|---|---|---|
| **Grok** | ~$99/mo, near-unlimited | ~zero | low — burn freely |
| **Claude** (Max) | subscription + usage limits | zero until cap, then real | medium — reserve headroom for hard work |
| **Codex** | subscription tier | low | medium |
| **Metered APIs** (any vendor) | per-token | full price | n/a — spend deliberately |

Standing order: **flat-rate pools absorb all volume work; metered tokens buy only
judgment.** Never pay API prices for work a saturable subscription could grind.
(Baseline for why this matters: one unbounded coordinator session once cost $119.65.
Bounded workers + routing discipline is the fix, not austerity.)

## Task-class → tier heuristic

Grade every dispatch **G / S / F** (Grind / Skilled / Frontier):

| Grade | Definition | Route to | Examples |
|---|---|---|---|
| **G — Grind** | High volume, verifiable by deterministic gates; wrong answers are cheap because sensors catch them | **Grok first**, Codex second | solo-loop iterations, Tier A builds, test scaffolding, lint/mechanical refactors, research sweeps, route-inventory generation, retry-until-green |
| **S — Skilled** | Multi-file reasoning, framework subtlety, real debugging; gates catch *some* failure | Codex / Claude (Sonnet-class); Grok acceptable with escalation trigger armed | Tier B builds, integration tests, decomposition of a clear plan, standard reviews, UX eval runs |
| **F — Frontier** | Judgment-heavy; failure is expensive or invisible to sensors; taste matters | Claude (Opus/Fable-class), best available | planning + design language, Tier C adversarial review, security exploit reasoning, architecture decisions, incident response, harness changes |

Two structural rules on top:

1. **Generation may be cheap; evaluation of Tier B/C may not be graded below S.**
   A G-grade generator with an F-grade reviewer is a good trade — the reviewer is
   reading a bounded diff, the generator burned free tokens getting there.
2. **Cross-vendor beats same-vendor at equal grade** (independent failure modes),
   so prefer the *other* pool's equal-grade model for review even when your own is
   available.

## The escalation ladder

Start at the cheapest grade plausibly sufficient; escalate on signal, never on vibes:

```
attempt at grade N
  → gate fails twice on the same criterion   → retry once with enriched context
  → fails again (3rd)                        → escalate one grade, hand over the
                                                loop-state + failure history
  → F-grade fails twice                      → it's not a model problem: park it,
                                                file a lesson (bad decomposition
                                                or bad contract — doc 09)
```

De-escalation is equally mandatory: the historian's quarterly review moves task
classes *down* a grade when a cheaper pool's success rate on that class exceeds 90%
(model improvements make yesterday's S-task today's G-task — principle 1's
downward stress-test, applied to money).

## Token-shape rules (all grades)

- **Bounded workers:** one issue, exact file list, short output contract. Unbounded
  coordinators are the documented cost pathology.
- **Fresh context per hat** (doc 11) beats one long session — cheaper *and* better.
- **Checkpoint before half the context window** on long metered sessions.
- **No-model checks stay no-model:** health checks, claim verification, gate runs
  are scripts, not prompts.
- **Cost telemetry:** every MC task records `cost_usd` (exact where the runtime
  reports it, dispatcher-estimated otherwise). The weekly retro reports
  cost-per-merged-PR per pool — the number this whole doc exists to push down.

## Worked default (today's fleet)

- Solo loop grinding a backlog overnight → **Grok** (G), escalating individual hats
  per the ladder; Tier C review hats shell out to **Claude read-only** (F).
- Daytime feature work → **Codex/Claude** builders (S) with **cross-vendor review**;
  planning sessions with Mark → **Frontier Claude**.
- Research sweeps, second opinions, X-adjacent anything → **Grok** (G/S).
- Messaging, digests, cron ops → **Hermes** with a cheap model (G) — it's the
  fleet's voice, not its brain.
