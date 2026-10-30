---
title: "Hypothesis and product definition"
nav_exclude: true
---

> **Authority:** Non-normative research proposal. Binding behavior remains in AGENTS.md; this document adds no gate, permission or deployed capability.

# Hypothesis and product definition

## The problem worth solving

A domain expert can explain the desired outcome, but the explanation often loses meaning as it becomes a specification, architecture, issues, agent prompts, code, tests and a release. Teams then reconstruct intent from disconnected documents and status badges. More generated code does not resolve wrong requirements, unusable workflows, or uncertainty about what was actually released.

The product hypothesis is that a small, understandable chain of accepted intent, useful increments and trustworthy evidence can improve both decisions and delivery. Each link must be tested, including the possibility that existing tools plus a thin integration already solve the problem adequately.

## Primary user and first market wedge

The initial candidate user is a nontechnical business/domain owner shipping a bounded internal workflow on an existing supported repository and deployment stack, using one primary coding agent. The owner can recognize a useful outcome and answer consequential business questions but should not need to operate worktrees, interpret CI internals or reassemble agent transcripts.

Secondary users are engineering/review, security, operations and delivery leads who need inspectable source, risk boundaries and release evidence. Their responsibilities do not disappear because the owner used natural language.

This wedge is proposed, not validated demand. Research must compare it with the alternative wedge of an engineering team needing accountable AI change delivery. Do not assume both segments want the same onboarding, price, assurance or interface.

## Product promise

An owner can describe a desired capability, see a faithful and editable specification, understand the first useful increment and its boundaries, authorize consequential decisions, and receive a demonstrably working result with an explanation of evidence, limitations and the next increment.

The owner-facing experience can be integrated while repository artifacts remain portable. The system should recommend a safe next step, keep useful work moving within existing authority, and ask about consequences rather than present internal tool configuration as product decisions.

## Hypotheses and falsification

| Hypothesis | Evidence that supports it | Evidence that defeats or narrows it |
|---|---|---|
| H1: A readable specification reduces expensive rework | Fewer material owner corrections after implementation at matched effort | Equally good results from the existing prompt/playbook baseline |
| H2: Traceability preserves intent through decomposition | Every material requirement is covered or explicitly deferred, including changed requirements | A polished plan still drops constraints or invents business rules |
| H3: Useful slices accelerate value | Earlier independently demonstrated capability, without worse defects or hidden deferrals | More small PRs but no earlier useful result |
| H4: An integrated operator journey reduces coordination cost | Better task completion, fewer context switches/interventions and consistent state | Integration adds its own confusing status or blocks standalone use |
| H5: Existing tools can remain interchangeable | The same artifact/evidence contract works with more than one supported adapter | Implicit dependence on one model, editor, host or private service |
| H6: Learning improves design as well as code | A scoped design/process correction improves later representative outcomes | The system only accumulates checks, memory and operating cost |

Thresholds for the later comparative trial must be declared before examining its results. No trial or statistically established gain is claimed here.

## What “enterprise-grade” means

The phrase must resolve to an applicable assurance profile: functional behavior; identity and authorization; data/tenant boundaries; privacy/retention; security and supply chain; reliability/recovery; operations/SLOs; deployment/migration/rollback; auditability; and accessibility/usability.

Each applicable claim needs an owner, criterion, verification method, source/deployment binding and observed status. Planned, unavailable and unknown evidence remain distinct from passed evidence. A feature cannot inherit a certification or production-readiness badge from a green CI run. Organizational compliance and legal duties require their own competent authority.

## Scope of Goal 1

Description → clarified intent → versioned product specification → release-sized scope of work → implementation/evaluation → authorized release → observed outcome.

The first implementation hypothesis uses Markdown plus a small machine-readable index, existing planner/decomposer procedures and the current delivery tooling. It does not require a new specification language, mandatory multi-model debate, graph database, proprietary runner or full control-plane rewrite.

## Non-goals

- Guaranteeing that any vague prompt can produce any enterprise product.
- Replacing product discovery, domain expertise or independent evaluation.
- Making four or five models a prerequisite for routine delivery.
- Building another IDE, VCS, coding model or generic telemetry backend.
- Treating generated plans, source claims or model confidence as release permission.
- Changing current owner, identity, review, spend, data or production boundaries.

## Research decisions, not hidden defaults

The first customer segment, real pilot outcome, applicable assurance profile, integrated-product experience and adoption of optional adapters need explicit recorded decisions. Ordinary implementation choices within the accepted scope remain with the engineering/review process. A specification does not add a general confirmation checkpoint before every reversible action.

## Existing direction to preserve

The [north star](https://github.com/The-AIE/the-gibson/issues/18) already specifies one primary frontier model and a non-coder. The [architecture epic](https://github.com/The-AIE/the-gibson/issues/165) already proposes a portable kernel, typed ports and evidence. This research should select and demonstrate their smallest useful subset rather than declare a competing architecture.
