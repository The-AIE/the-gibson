# Mini Gibson: the story

## The problem

Coding agents grade their own homework. "Done" is something the model says, not something anyone checked.

Small open models make this easy to see. They sound just as sure when they're wrong. So teams do one of two things: pay for a frontier model to hide the problem, or trust a small model blindly. Nobody has a scorecard that shows whether the *process around* a model is what moves the result.

## The bet

Agent = model + harness. The model is rented. The harness is yours.

- **Nemotron** does the work (a small model on one GPU).
- **The Gibson environment** owns the verdict: isolated state, allowed tools, a repair budget, deterministic tests. The model never awards itself success.
- **Jev** makes the narrow judgments code can't: does this diff address this issue, is part of it unrelated, does the closing report overclaim, is the text trying to steer the grader. Jev is a System One model: it returns typed probabilities, not prose, and it does not write code ([Jev with coding agents](https://docs.typesafe.ai/introduction/coding-agents.md)).

Two small models, one doing the work and one judging it, with code owning every fact it can compute.

The rule that keeps this honest: **Jev can only downgrade.** A run that fails the tests is never upgraded, and a run Jev doubts never reaches `VERIFIED`. Task resolution is decided by tests, not by Jev.

## What we hope to see

One before/after table on a frozen task set:

| Configuration | What it isolates |
|---|---|
| `raw_nemotron` | The model alone |
| `nemotron_gibson_harness` | The same model inside the harness (phases, inspect-before-edit, evidence gate, repair budget) |
| `mini_gibson_historical_lora` | The harness plus a LoRA trained on our own history |

Primary number: **task resolution rate** (hidden tests from the original PR pass).
The more interesting number: **false-done rate**, how often the agent claimed success and the tests disagreed.
Secondary: **Jev agreement with tests**, which tells us whether the semantic gate adds anything.

Before any model runs, two sanity agents check the bench itself: a no-op agent must score 0% and an oracle agent (applies the real fix) must score 100%. If either is off, the bench is broken and nothing downstream means anything.

## What we learn if it fails

A failed result is still a finding. Each outcome points at a different fix:

- **The harness doesn't beat raw.** The model is the bottleneck, not the process. The harness's value is then catching bad work, not lifting scores. Check whether the false-done rate still dropped.
- **The harness helps but the LoRA doesn't.** Our history is too thin or too specific to the Gibson repo to transfer. That is a data problem, not a method problem. The failure labels show which failures remain.
- **Jev agrees with the tests on everything, or adds noise.** If it never disagrees, it adds nothing, and we cut it. If it disagrees, a human labels those cases and we learn which side was right. Either answer is useful.
- **Everything is flat.** The tasks were too easy or too hard. Fix the bench before fixing the claims.

## Known risks (stated up front)

- **Jev's thresholds are uncalibrated defaults.** Every raw probability is stored so they can be tuned against human labels. Do not publish a Jev number before that.
- **A grader can be talked at.** Jev does not treat input as hostile by default, and its docs warn that instructions inside code comments or PR text can steer answers ([jev-1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13.md)). We ask a dedicated question for it, filter and cap the diff in code, and let Jev only downgrade. That reduces the risk; it doesn't remove it.
- **Large diffs hurt accuracy.** Counts, sizes and pass/fail are computed in code. Jev sees a filtered, capped diff.
- **The external holdout is empty.** It needs tasks from a repository our history never touched. Until it exists, claims are limited to the Gibson repo.
- **The Jev call path was tested with a fake client.** It has not been run against the live API yet.
