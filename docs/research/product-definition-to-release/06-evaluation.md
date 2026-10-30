---
title: "Research and evaluation protocol"
nav_exclude: true
---

> **Authority:** Non-normative research proposal. Binding behavior remains in AGENTS.md; this document adds no gate, permission or deployed capability.

# Research and evaluation protocol

## What this study can and cannot establish

Repository/source inspection can establish what code or procedure exists. A fixture drive can demonstrate that behavior on the supplied input. Primary vendor documentation establishes documented capabilities. Model memos supply independent design hypotheses. None alone proves customer demand, product usability, enterprise readiness or production effectiveness.

The initial branch is a research foundation. All four external initial memos are received. The source-informed follow-up has three completed responses and one explicitly partial Claude response (`content_filter`). No customer trial, deployed demonstrator, competitive performance result or proof from consensus is claimed.

## Research questions

1. Does the owner recognize the generated specification as faithful, with material unknowns visible?
2. Does decomposition preserve user outcomes, constraints and explicit deferrals?
3. Can released behavior be traced to accepted intent without mistaking prose linkage for evidence?
4. Which architecture/assurance components are actually necessary for the selected product?
5. Does an integrated experience reduce owner errors/intervention while preserving portability?
6. Can external ecosystem tools eliminate work we were about to build?
7. Does measured learning improve design and delivery enough to justify its own cost?

## Source audit

Pin repositories and exact source versions. Distinguish doctrine, implementation, observed fixture behavior, running-product evidence and proposal. Cite decisive source lines and record the limits of an absence search. Never infer live activation from a merged PR, a schema, documentation or a successful unit suite.

Refresh the relevant facts before implementation. Research snapshots are not permanent live admission or release evidence.

## Independent model panel

Requested contributors: GLM 5.3, Kimi, Grok, Claude and Codex. Exact requested provider/model versions and actual receipt status are in [the contribution manifest](reviews/contributions.json).

The external models receive the same [sanitized conceptual brief](reviews/shared-brief.md), before seeing each other's answers. It contains the owner's hypothesis, generic capability descriptions and public ecosystem source descriptions. It excludes operational inventory, private source, recovery records, credentials and user/customer data. The models have no browsing tools in that request; they may reason from supplied material, but cannot claim source access or software inspection.

Codex also performs the source audit and synthesis; its richer source context is an explicit asymmetry, not a matched-model benchmark. Internal Codex audit assistance is not relabeled as one of the four external models.

The second round supplies the same bounded public-source findings and each model's own original memo, without other contributors' opinions. It tests whether the advice changes when existing assets are known; it is still supplied-summary analysis, not independent repository inspection. Preserve first-pass advice and later retractions separately. Claude's partial follow-up stops mid-sentence; no missing conclusion is inferred and no replacement call was made.

Preserve actual returned model IDs, generation/response IDs, input digest, finish reason, limits, usage/cost when observed, response digest and unedited substantive memo. Mark unavailable, timeout, incomplete or no-verdict results explicitly. Reconcile uncertain execution before retries. Missing input is never synthesized in a model's voice.

Synthesize agreement, disagreement, assumptions, counterexamples and decisions. A majority vote is not evidence of a good product, and research participation never supplies formal release review.

## Comparative product experiment

Compare:
- current Gibson chat/planner/decomposer procedures;
- a minimal existing spec-toolkit artifact workflow;
- the proposed thin accepted-intent/spec/scope/evidence package;
- an integrated operator prototype only when that is the question being tested.

Use matched task context, tools, effort/cost budget and applicable controls. Separate comparison of planning artifacts from comparison of running product delivery. Record case mix, missing access, explicit holds and operator intervention.

Public example cases may demonstrate the format. A later independently curated held-out subset should test generalization, including changed/contradictory requirements and already-shipped functionality. No hidden dataset or evaluation result is claimed to exist in this branch.

## Measures

| Dimension | Observed measure | Common false conclusion to avoid |
|---|---|---|
| Product/design | Owner recognition/correction, user task success, time to result, comprehension/recovery | A longer spec or higher LLM score means better design |
| Scope fidelity | Material requirements preserved, explicit deferrals, useful increments, missed constraints | Passing lint means the product contract is complete |
| Delivery | Time to an accepted spec and useful deployed capability; actual queue/start/review/release timestamps | More merged PRs means more user value |
| Reliability | Escaped defects, wrong outcomes, repeat failures, recovery/rollback | A build or smoke pass proves every requirement |
| Rework/cost | Design vs code corrections, no-verdict attempts, owner minutes, observed runtime/model/CI cost | Unknown equals zero or all delay is hardware/scheduler |
| Complexity | Components, operator burden, false blocks, maintenance/exit cost | Every failure warrants another permanent gate |

Keep code defects, unmet/changed product intent, provider/tool failures and owner holds separate. Count replacement ancestry once per logical delivery; preserve actual cumulative review limits independently of descriptive metrics.

## Falsification and trial decisions

Declare the later trial's observation window, effort budget and decision thresholds before inspecting outcomes. Stop or narrow a design if it invents material constraints, loses a requirement, calls stale/unknown evidence passed, confuses preview with production, or fails the intended user's task.

A small successful demonstration establishes feasibility on that case. Repeated representative trials are needed for repeatability and stronger product claims. Before/after anecdotes and correlated model opinions are not causal productivity evidence.

Prefer the simpler path when it performs as well at lower total burden. A useful outcome may be rejecting a new platform component or integrating an existing tool.

## Enterprise assurance matrix

For each applicable dimension, name the criterion, evidence method, responsible role, exact scope/version, actual status and unresolved decision.

| Dimension | Example evidence required by an applicable profile |
|---|---|
| Functional behavior | Positive/negative user scenarios against the actual running version |
| Identity/authorization/tenancy | Role/tenant matrix, forbidden actions and isolation tests |
| Privacy/data | Data flow, minimization, retention/deletion, export handling and applicable residency decisions |
| Security/supply chain | Threat model, relevant scans/dependency/build evidence and independent adversarial review |
| Reliability/recovery | Failure/retry/idempotency scenarios, backup/restore evidence and recovery objectives |
| Operations | Observable health, meaningful alerts, ownership/support and applicable SLO evidence |
| Delivery/data evolution | Source/artifact/deployment binding, migration safety, rollout/rollback and post-release verification |
| Auditability | Bounded decisions, actor/source provenance and inspectable evidence history |
| Usability/accessibility | Independent task completion, keyboard/accessibility and relevant device/error-state behavior |

Statuses include planned, observed pass/fail, unknown and explicitly inapplicable with rationale. Do not promote a plan, configuration assertion or third-party claim to tested evidence. Organizational certification/legal compliance is not conferred by this matrix.

## Learning loop

Observe an actual outcome → establish a plausible cause with a counterexample/test/trace → propose a scoped change → compare against a simpler baseline → independently evaluate → deliver through normal review → observe repeat use → retain, revise or retire.

Design learning may change problem framing, epic order, slice boundaries, architecture, prompts, defaults or interaction guidance. A deterministic regression check is appropriate when it detects a concrete repeatable bad behavior. Existing protected controls and owner policy do not loosen automatically.

## Publication and privacy

Keep public research about general capabilities and public artifacts. Operator/private/customer records stay in their appropriate private home. Default telemetry experiments to identifiers/timings/categories and observed usage; deliberate content/retention/masking decisions precede transcript export. No live service, integration or data export is activated by this study.
