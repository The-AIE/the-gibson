---
title: "glm-5.3 public-source-informed delta"
nav_exclude: true
---

> **Authority:** Non-normative research delta. Public source summaries were supplied; the model did not browse or audit code. This is not formal release review.

Model: z-ai/glm-5.3

Response: gen-1793376834-zppNeIoJgDugdikyqB20

Finish reason: stop

---

# Delta Memo: Revisions in light of the source snapshot

Advisory only; I did not inspect code, run validators, or verify any claimed state. The snapshot shows a partially built system; my first memo assumed more greenfield than warranted.

---

## A. Reuse vs. smallest missing slice

**Reuse, do not rebuild:** planner (PLAN.md), decomposer, issue contracts, scope/dependency validators, repo-claim/workspace, automated checks, test-integrity, local proof, and independent-review machinery. My Increment 3 ("isolated workspace + check harness + evidence bundle") and most of Increment 2 are substantially covered. Re-proposing them would be churn, and my Stage-1 recommendation ("toolkit only") is effectively reached.

**Smallest missing slice — the delivery receipt.** Per finding 3, collection/deployment proof is incomplete in that slice, and the criterion-marker helper is linkage hygiene, not behavioral acceptance. So the highest-value first slice is:

1. **Behavioral acceptance bridge:** map each numbered acceptance criterion to the check(s) that exercise it, distinguishing "linked" from "behaviorally covered," with the latter defined as scenario execution plus held-out or independent review — not marker closure.
2. **Delivery receipt closure:** exact, reproducible collection of the evidence that exists today into one portable artifact, with explicit gaps marked (e.g., "deployment proof: absent").

**Second slice (new):** the integrated journey — finding 6 says no integrated running-user journey or comparative productivity result exists. That is now the product's central unproven claim, ahead of any new infrastructure.

## B. Portable artifacts vs. transactional runtime state

I retract "all writes land in Git; the plane is never the system of record" as stated. Agent Kontrol's documented boundary — repository gate remains authoritative for its checks, manager cannot override it, manager may stand alone — is exactly the **canonical-home-per-fact** model, and it is right. Forced Git-only state would either serialize legitimately concurrent runtime operations into commit noise or lose them.

Reconciled rule:

- **Durable intent and evidence** (specs, accepted changes, receipts, review outcomes) live in the repository, portably, in the toolkit's formats.
- **Ephemeral coordination and execution state** (task/fleet/progress/decisions-in-flight) lives in the manager's database, legitimately.
- **Each runtime fact carries provenance back to its repo anchor** (issue/spec version/contract). Any manager state without an anchor is provisional by definition.
- **The gate is the single crossing point:** runtime cannot self-certify; only repo-side checks can. This preserves my original evidence-independence concern while conceding the database.

The open design question: what is the receipt format for a *manager-driven* collection — i.e., deployment performed by Kontrol — so the bundle remains verifiable without trusting the manager's log? Unproven; I'd prototype it, not assume it.

## C. Incremental integrated product plan (existing toolkit + plane)

1. **Close the delivery receipt slice** (above). User benefit: the owner can distinguish "linked," "checked," and "actually delivered" for the first time.
2. **End-to-end journey on one fixture:** owner → spec acceptance → increment → evidence → receipt, with the manager driving execution but the repo gate deciding.
3. **Comparative pilot (my Section E):** toolkit+Kontrol vs. plain GitHub baseline on difficulty-matched tasks, third-party held-out acceptance suite, defect-escape as primary measure. Do this *before* adding features; finding 6 makes it the gating unknown.
4. **Enterprise profile conformance mapping:** for each receipt, emit which enterprise-readiness dimensions are evidenced vs. absent. Note a real conflict: finding 4 — existing independent-review and authority requirements are binding — means my earlier "deterministic checks as sole verification authority" framing is too strong. Deterministic checks are necessary but not sufficient; independent review is already part of the toolkit and must remain.

**Concrete first-user benefit:** an owner reads one page per release — "criterion N: passed via check X, reviewed by Y, deployment proof absent" — instead of reconciling issues, PRs, and manager status.

**Negative acceptance case:** a criterion marked "covered" where the linked check is tautological (asserts the marker, not the behavior) — the receipt must render this as *linked-only*, and a planted seeded defect passing a "covered" receipt fails the release. Second case: a manager-side completion claim with no repo-gate evidence must appear as "claimed, unverified."

## D. Changes, retractions, disagreements

**Change/retract:**
- Increment plan compressed: 1–4 of my original ladder exist; the ladder now starts at behavioral-acceptance + receipt closure, then integration, then measurement, then enterprise profile.
- "Plane never stores truth" → canonical homes per fact, with repo as authority for certification-relevant facts.
- "Deterministic-only verification" → deterministic checks plus the existing binding independent-review machinery; my concern about model self-certification stands but is already partly mitigated.
- Persona skepticism softens: existing validators and review machinery suggest some owner-value evidence exists, though finding 6 says productivity claims remain unproven — skepticism on *productivity* stands.

**Important disagreement/uncertainty:** I would resist treating the small-fixture validator success as generalization. Finding 1 is explicit that arbitrary product completeness is unproven; the highest-risk path is scaling the planner/validators to messy real descriptions before the comparative pilot exists. **Uncertainty worth naming:** whether the manager's database and the repo anchor model stay consistent under failure (manager mid-task when repo advances) — no supplied fact covers reconciliation-on-conflict, and I would not certify any release path that depends on it until that behavior is specified and tested.
