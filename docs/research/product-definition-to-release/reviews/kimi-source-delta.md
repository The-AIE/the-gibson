---
title: "kimi public-source-informed delta"
nav_exclude: true
---

> **Authority:** Non-normative research delta. Public source summaries were supplied; the model did not browse or audit code. This is not formal release review.

Model: moonshotai/kimi-k3.1-pro

Response: gen-1793376834-WHlJw9PLle9UnoA2908i

Finish reason: stop

---

## A. Reuse existing capabilities; close the behavioral-evidence gap

Treat the supplied findings as identifying existing assets, subject to normal fit verification—not as independently audited or generally proven capabilities. Reuse Gibson’s planner template, decomposer, issue contracts, scope/dependency validators, repository claim/workspace machinery, automated checks, test-integrity controls, local proof, and exact-source independent review. The first memo’s suggestions to build these file-first should be withdrawn.

The smallest missing slice is **behavioral acceptance evidence for one already-scoped increment, connected honestly to the existing delivery receipt**. Add only the missing contract or adapter that associates:

- The accepted criterion and a separately meaningful behavioral scenario.
- The exact source revision and execution environment.
- The runner, result, and references to retained evidence.
- Explicit limitations, including evidence not collected.

Criterion-marker closure must remain linkage hygiene, not be promoted to behavioral proof. Likewise, the receipt should represent collection and deployment verification as incomplete unless separately supported. Existing independent review and applicable authority requirements remain binding; neither deterministic checks nor a new universal owner-approval step should replace them.

## B. Define canonical homes per fact; do not force everything into Git

The first memo’s portability recommendation was too broad if read as “all state belongs in Git.” Use canonical homes according to state semantics:

- **Git/source artifacts:** accepted intent and revisions, criterion identifiers, issue/scope/dependency contracts, exact source, and the portable receipt or manifest needed to interpret and reproduce repository-gated outcomes.
- **Agent Kontrol’s database:** task attempts, leases or coordination state, fleet status, transient progress, operational decision lifecycle, and other transactional runtime facts.
- **External evidence storage where appropriate:** bulky logs or artifacts, with stable identifiers or digests referenced by portable artifacts.

A decision that changes accepted intent or exercises binding authority needs a durable, attributable record connected to the affected source revision; that does not require every operational decision to become a Git commit. Use explicit identifiers, revision references, and projections rather than dual writable copies. Synchronization must not create a second gate or silently rewrite accepted history.

The documented boundary should remain: Agent Kontrol may coordinate and stand alone, but cannot override the repository gate. Conversely, reproducing that gate must not require reconstructing transient manager state.

## C. Integrate one thin journey before expanding either product

1. **First vertical slice:** Project one accepted plan and scoped issue into Agent Kontrol using their existing identifiers. Coordinate execution through the existing toolkit, return existing gate/review outcomes, and add the single behavioral-evidence result. Display the portable receipt with incomplete delivery stages visibly incomplete.
2. **Change slice:** Exercise one requirement revision through the same journey. Preserve the prior accepted revision and ensure stale behavioral or delivery claims are not presented as current; implement only invalidation or synchronization behavior found missing.
3. **Evaluation before expansion:** Compare the integrated journey with a matched toolkit-only or conventional workflow, including owner and reviewer effort. Expand collection/deployment evidence, optional model support, or enterprise profiles only against separately defined evidence needs.

**Concrete first-user benefit:** a nontechnical owner can see, in one place, that a specific accepted increment has behavioral evidence and exact-source review for an identified revision—while also seeing that collection or deployment remains unverified—without manually assembling these distinctions.

**Negative acceptance case:** a criterion marker is present and local checks pass, but the behavioral scenario fails or was not run. The manager must not display the criterion as behaviorally satisfied or the increment as released, and no manager action may bypass the repository gate or substitute owner approval for required independent authority.

## D. Revisions to the first memo and remaining uncertainty

Retract the greenfield sequencing that proposed building the toolkit, workspaces, validators, and initial evidence machinery before integration. Also revise “defer the control plane”: Agent Kontrol already exists, so the appropriate step is a minimal contract-based integration and journey evaluation, not another manager or an immediate deployment merger. Retain shared contracts, toolkit portability, independent evidence, and skepticism toward blanket enterprise-readiness claims.

The important uncertainty is whether behavioral acceptance can remain portable across product types without product-specific harnesses becoming the dominant cost. The small validator fixture does not establish arbitrary product completeness, and the supplied facts establish neither an integrated running-user journey nor comparative productivity improvement.
