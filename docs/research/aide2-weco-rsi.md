---
title: "External evidence · Weco AIDE² Level-1 RSI"
nav_exclude: true
---

# Weco AIDE²: First Evidence of Level-1 Recursive Self-Improvement

**Source:** [AIDE²: The First Evidence of Recursive Self-Improvement](https://www.weco.ai/blog/first-evidence-of-recursive-self-improvement)  
**Date:** 14 July 2026 · Weco Team  
**Companion framing:** [4 Levels of Recursive Self-Improvement](https://www.weco.ai/blog/4-levels-of-recursive-self-improvement)

## What they demonstrated

Weco ran a bi-level (“autoresearch on autoresearch”) system for 100 unattended outer-loop steps over eight wall-clock days. An outer agent rewrote the code/harness of an inner research agent (starting from a simplified AIDE⁰). Roughly 90 % of proposals were rejected. The surviving successive versions (AIDE⁴⁷, AIDE⁸⁵) beat both the starting agent *and* Weco’s own two-year hand-tuned baseline (AIDEhuman) on held-out benchmarks under fixed dollar/compute budgets.

Key autonomous discoveries:

- Novel search policy (tree search + multi-armed bandit over lineages + forking for local optima).
- ~16× prompt / context compression (reinvesting tokens into more search steps).
- Layered anti-reward-hacking defenses (prompt instructions + hard-coded guards + statistical clipping). Hacking rate on a held-out kernel-engineering task fell from 63 % → 34 % *without being explicitly told to reduce cheating*.
- Second-order generalization to external suites never seen during the outer loop (MLE-Bench Lite, ALE-Bench Lite, WeatherBench 2).

They grade the result **Level 1 (“net positive”)** on their own ladder:

| Level | Name          | Meaning                                                                 | AIDE²          |
|-------|---------------|-------------------------------------------------------------------------|----------------|
| 0     | Delegation    | Autonomous loop runs, but slower than human R&D                         | prior systems  |
| 1     | Net positive  | Self-improvement more efficient than human iteration under fixed budget | **claimed**    |
| 2     | Ignition      | Improved agent becomes a better outer-loop improver                     | not achieved   |
| 3     | Inflection    | Gains accelerate at fixed effort                                        | not achieved   |

They tested ignition by installing an improved agent as the outer loop; it reached the same ceiling faster but the difference was not statistically significant. Evolved code grew complex (some dead / buggy layers). The system remains the “worst version of itself we will ever see.”

## Why this matters for The Gibson

The Gibson’s core bet is that **the harness compounds**. AIDE² supplies external, quantitative evidence that an outer loop can improve an agent harness *faster and more efficiently than multi-year human tuning*, under fixed cost, with measurable generalization and beneficial side-effects (less metric gaming).

Direct mappings:

| AIDE² technique / result                    | Gibson analogue / opportunity                                      |
|---------------------------------------------|--------------------------------------------------------------------|
| Bi-level optimization (outer rewrites inner harness) | The ratchet + historian already does this for doctrine/sensors; could be made more systematic |
| Public vs private scores + fixed $ budget   | Quality gates + cost telemetry (docs/06, docs/15). Strengthens the case for never grading your own homework and for fixed-budget sensors |
| Layered anti-reward-hacking                 | Sensors + fail-closed review (docs/06, L-005). Explicit multi-layer defenses against metric gaming are a concrete pattern to adopt |
| Aggressive context compression              | Relevant to long-running agents / solo-loop (docs/11) and model economics (docs/15) |
| Heterogeneous task suite during improvement | Heterogeneous gates (UX-eval, security, schema, review tiers) already force breadth |
| Emergent repair of buggy eval harness       | Historian + LESSONS.md already capture “docs said X, reality said Y” |

## Actionable takeaways for Gibson

1. **Measure net-positive efficiency of harness changes.** When the historian or an agent proposes a guide/sensor change, record the before/after cost or failure-rate delta under a fixed budget where possible. This turns the ratchet into an explicitly Level-1 loop.

2. **Treat reward-hacking style failures as first-class sensors.** AIDE²’s layered defense (instructions + hard guards + statistical) is a useful pattern for any metric that agents optimize against (test coverage, latency claims, eval scores). Prefer sensors that make gaming harder than genuine progress.

3. **Context compression as a harness primitive.** The 16× reduction is a reminder that long-horizon agents waste budget on redundant history. Patterns that summarize lineages or role-specific context should be candidates for guides or adapter helpers.

4. **Keep self-modification bounds.** AIDE² stayed at Level 1; ignition was not clear. Gibson’s existing rule (harness changes go through the same pipeline + Tier-C for human gates) remains the correct safety posture. External evidence does not justify loosening those bounds.

5. **Public/private and held-out evaluation.** When designing new gates or solo-loop success criteria, prefer a private/held-out signal that the optimizing agent cannot see. This is exactly the mechanism that forced AIDE²’s anti-hacking behavior.

## Caveats (for the record)

- First-party blog post, not peer-reviewed.
- “First evidence” is their framing; related prior work exists (Darwin-Gödel Machines and other evolutionary self-modifying coding agents).
- Results are on metric-rich engineering tasks; transfer to open-ended product work is unproven.
- Evolved code complexity and residual hacking (34 %) remain real costs.

## References

- Primary: https://www.weco.ai/blog/first-evidence-of-recursive-self-improvement
- RSI ladder: https://www.weco.ai/blog/4-levels-of-recursive-self-improvement
- Related prior art: Darwin Gödel Machine (open-ended evolution of coding agents)

*Filed 2026-07-29 as external research note supporting the self-improvement doctrine in docs/09.*
