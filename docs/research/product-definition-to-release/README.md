---
title: "Product definition to verified release"
nav_exclude: true
---

> **Authority:** Non-normative research proposal. Binding behavior remains in AGENTS.md; this document adds no gate, permission or deployed capability.

# Product definition to verified release

**Research owner:** the product owner. **Research coordinator and synthesis:** Codex.
**Status:** source-backed product proposal with five actual research contributors; product decisions and experiments remain open. No product decision or implementation below is accepted merely by appearing on this branch.

## Starting hypothesis

For a bounded class of business products, a nontechnical owner and one primary coding agent can turn a human-readable product description into an accepted product specification, useful release-sized work, and a deployed capability with traceable evidence, at less total effort and no loss of required quality compared with current practice.

The hypothesis must earn its scope. “Any prompt to enterprise-grade software” is not a demonstrated capability. Enterprise readiness means a declared assurance profile with evidence for the particular product and release.

## Read this package in order

1. [Hypothesis, user and product definition](01-product-hypothesis.md).
2. [What Gibson and Agent Kontrol currently establish](02-current-state.md).
3. [Ecosystem and positioning](03-ecosystem.md).
4. [Reference architecture and artifact contracts](04-reference-architecture.md).
5. [Incremental product plan](05-incremental-plan.md).
6. [Research method, enterprise assurance and evaluation](06-evaluation.md).
7. [Gibson + Agent Kontrol product decision](07-agent-kontrol.md).
8. [Worked product-description → specification → scope → release example](08-worked-example.md).
9. [Open decisions and adoption sequence](09-decisions.md).
10. [OpenSpec adoption assessment](10-openspec.md).
11. [How epics, releases and work items fit together](11-release-structure.md).
12. [Cross-model synthesis](reviews/synthesis.md), [individual contributions](reviews/README.md), [shared sanitized model brief](reviews/shared-brief.md), and [source register](sources.json).

## Immediate recommendation to test

Keep one owner-facing product journey while preserving portable, explicit component boundaries. Reuse Gibson's repository contracts/checks and Agent Kontrol's existing coordination/presentation. First test one owner-readable acceptance/evidence packet over an existing plan and scoped increment. Distinguish linkage, demonstrated behavior and deployment; implement only the missing connection. Then exercise the complete description/spec/scope/release journey. Optional ecosystem adapters can remove work we would otherwise build.

Use existing epics for durable outcomes and proposed releases for small demonstrated benefits. Keep two delivery items active, with a third lane only for a concrete blocker. Trial OpenSpec as the specification/change layer before building another one; retain Gibson's required PLAN/issue handoffs and evidence authority. These follow-up recommendations are detailed in the two addenda above, without creating release milestones or changing epic parents.

This is a recommendation to evaluate, not permission to merge codebases or deploy the integrated system. The research panel is optional research input; the locked [single-primary-model path](https://github.com/The-AIE/the-gibson/issues/18) remains the product baseline.

## Incremental benefits

| Increment | Benefit the owner receives |
|---|---|
| 1. Description → accepted spec | Understand and correct what will be built before paying for implementation |
| 2. Spec → dry-run useful scope | See the first useful result, dependencies, deferrals and acceptance evidence |
| 3. One scope item → verified release | Receive a working capability and inspect what proves it |
| 4. Unified operator journey | Make decisions and follow progress without reconciling several tools |
| 5. Measured improvement | The next comparable delivery improves in usefulness, quality or total effort |

Enterprise requirements enter the first specification and remain visible throughout; they are not an unbounded final “hardening” phase.

## Evidence and contribution status

Gibson source audit is pinned to **babef4b3ce969289b698c55babffd97c2f5720b7**. Agent Kontrol source references are pinned to **847b22b56f6203abadf3c1a41f9ba326c0bbe3ac**. Official ecosystem documentation was inspected on **2026-10-30**; documentary capabilities are not hands-on performance results.

Codex supplied the current-state audit, initial position and synthesis. GLM 5.3, Kimi, Grok and Claude supplied four completed independent first memos from the same sanitized conceptual brief. A second round supplied the same bounded public-source findings and each model's own first memo: GLM, Kimi and Grok completed; Claude returned partial text with provider finish reason `content_filter`. The partial result is preserved and not counted as a completed follow-up. No request was regenerated. Read the synthesis for retractions, substantive disagreements and recommendations not adopted. The total provider-reported cost for both rounds was **$0.426288949**; this is not a billing audit, product benchmark or release approval.

The OpenSpec and release-organization addenda answer later owner questions using Codex source research. They were not part of the external models' inputs; no model endorsement or additional billed panel is implied. OpenSpec v1.15.0 was inspected as source/documentation, not installed or exercised.

## Collaboration

Research is tracked in [#615](https://github.com/The-AIE/the-gibson/issues/615), under the existing [#18](https://github.com/The-AIE/the-gibson/issues/18) and [#165](https://github.com/The-AIE/the-gibson/issues/165) product/architecture direction. Reuse [#167](https://github.com/The-AIE/the-gibson/issues/167), [#210](https://github.com/The-AIE/the-gibson/issues/210) and [#214](https://github.com/The-AIE/the-gibson/issues/214); do not create competing epics from this document.

Contributors should distinguish observation, inference, hypothesis and proposal; cite a source or scenario; state what would disprove their recommendation; and make bounded edits through the existing claim/review process. Preserve disagreement in the decision record. Model advice is not formal exact-head release review.

No runtime activation, live migration, credential configuration, source-control replacement, policy relaxation, repository merger or release is performed by this research.
