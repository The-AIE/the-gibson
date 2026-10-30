---
title: "claude public-source-informed delta"
nav_exclude: true
---

> **Authority:** Non-normative research delta. Public source summaries were supplied; the model did not browse or audit code. This is not formal release review.

Model: anthropic/claude-opus-5.5

Response: gen-1793376834-1zjOnUBOrJQVx1xrEPrW

Finish reason: content_filter

**Incomplete contribution:** The provider returned partial final text ending mid-sentence. The text below is preserved as returned; it is not a completed follow-up, and no missing conclusion is supplied. The independent initial Claude memo completed normally.

---

# Delta to First Memo: Reusing the Existing Toolkit and Control Plane

**Basis:** The supplied findings 1–6 and source links, taken as given. I have not inspected the repositories or run anything. This is advisory only and is not release approval.

## A. Reuse first, then build the smallest missing slice

**Reuse rather than rebuild.** Per findings 1–2, the following already exist and should be reused:
- the PLAN.md planner template, with numbered acceptance criteria,
- the decomposer procedure, issue contracts and scope/dependency validators,
- claim/workspace isolation,
- automated checks, test-integrity checks and local proof,
- exact-source independent review.

My earlier increments 1 and 2 were largely greenfield proposals for things that already exist. **[Unknown]** Findings 1 and 6 also say these components were exercised only on a small fixture, and no integrated journey has been shown.

**What is missing, per finding 3:**
- **Behavioral acceptance.** The criterion-marker helper shows that a criterion is linked and closed. It does not show that the behavior was demonstrated.
- **Collection/deployment proof.** The delivery receipt documentation says this part is incomplete in the current slice.

**Smallest first slice:** bind one numbered PLAN.md criterion to one executable behavioral scenario.
- The scenario runs through the existing checks and is covered by exact-source review.
- The result appears in a receipt that keeps two states visibly apart: *linked/closed* and *behavior demonstrated at commit X*.
- Do not complete deployment proof yet. The receipt should state honestly that it is absent.

## B. Define a canonical home for each fact

I retract "Git as sole system of record" and "control plane as a rebuildable cache." Finding 5 establishes that Agent Kontrol has legitimate database-backed runtime state. Forcing leases, fleet state or progress into Git would add commit noise and race conditions without adding trust.

Instead, publish a small fact-ownership contract:

| Fact | Canonical home |
|---|---|
| Owner description, accepted PLAN, acceptance criteria, scope contracts, intent-changing decisions | Repository, versioned |
| Behavioral scenario definitions, check/review results, receipts | Repository and gate outputs, tied to the exact source |
| Task assignment, fleet status, progress, queued decisions, telemetry | Agent Kontrol database |
| Decision captured at runtime that changes intent or acceptance | Raised in Agent Kontrol, authoritative only once materialized in the repository through the normal reviewed path |

**Reconciliation rules:**
- Runtime records reference repository facts by commit SHA or content hash, not by copying them.
- The manager may display the gate's verdict but cannot override it. This is consistent with the documented boundary in finding 5.
- The toolkit must still run with no manager present.

## C. Incremental integrated plan for the existing system

1. **Fact-ownership contract and shared IDs.** Document which system owns each fact, and use the same criterion and issue IDs in both.
2. **Behavioral acceptance slice.** As described in section A.
3. **Owner receipt view in Agent Kontrol.** Read-only, rendered from repository and gate outputs. For each criterion it shows demonstrated, not demonstrated, or unknown, together with which check and which independent review produced that status.
4. **Changed-requirement impact.** A PLAN version diff that marks the affected criteria and scenarios as needing re-demonstration.
5. **Delivery/deployment proof.** Complete the receipt's collection and deployment section, scoped to an explicitly applicable enterprise profile.

**First-user benefit:** the nontechnical owner can see, in plain language, which promised behaviors are actually shown working on the exact source that was reviewed. They no longer have to infer this from closed issues.

**Negative acceptance case:** a criterion is closed via its marker, but its behavioral scenario fails or does not exist.
- The receipt must show "not demonstrated."
- The repository gate must not pass on behavioral acceptance.
- Any attempt by the manager to present the item as done must be refused or shown as conflicting with the gate.

## D. Changes, retractions and one uncertainty

**Retract:**
- The greenfield framing of increments 1–2.
- Git-only state, as discussed in section B.
- The "read-only dashboard" increment as a speculative build. The control plane already exists, so the question becomes how it integrates, not whether to build it.

**Revise:**
- **Authority wording.** My chain said "owner releases; specialists sign." Finding 4 says the existing independent review and the *applicable* authority requirements remain binding. They should be referenced, not replaced by a new blanket human approval rule or by deterministic self-certification. I would reword the release record to say "required authorities per applicable profile: present or missing."
- **The "non-obvious alternative."** The standalone evidence verifier I proposed largely describes the existing toolkit. The remaining open question is whether the missing behavioral layer, not more orchestration, delivers most of the owner value.

**Keep:** the matched-baseline and held-out evaluation. It still applies unchanged, and finding 6 confirms there is no comparative result yet.

**Important uncertainty:** who
