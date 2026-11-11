---
title: "Worked example: service request tracker"
nav_exclude: true
---

> **Authority:** Non-normative research proposal. Binding behavior remains in AGENTS.md; this document adds no gate, permission or deployed capability.

# Worked example: service request tracker

## Status and purpose

This is a fictional documentation fixture. It demonstrates the proposed artifact chain; it is not an implemented application, a deployed release, proof of demand, a selected customer pilot or a production-ready reference stack.

A real delivery trial should select an already prioritized bounded adopter journey after the relevant owner/scope/runtime decisions.

## 1. Human-readable product description — PD-1, version 1

“Our small organization needs a place for staff to report office service requests. A requester should see whether their request was received and what is happening. A coordinator needs to triage requests and update the status. People should not see other staff members' requests. We want the first useful version before adding complex automation.”

### Clarifications and unknowns

- Who is allowed to coordinate? Proposed roles are requester and coordinator; the owner must confirm role assignment and any existing identity provider.
- Is priority/SLA automation required? Not specified; defer rather than invent hours, escalation or urgency rules.
- What personal/sensitive data may be entered? Unknown; use synthetic data in the reference preview and require a data-handling decision before real use.
- Are multiple organizations/tenants required? Not specified. Do not silently market single-organization access controls as tenant isolation.
- How is the app operated/backed up, and what failure/recovery objective applies? Required for the selected release profile, not guessed from the prompt.

### Non-goals for the first useful capability

Attachments, billing, external email/SMS, AI triage, automatic escalation, public anonymous requests, multi-organization tenancy and analytics are deferred. Deferral must be visible; it does not mean those features were delivered.

## 2. Product specification — SPEC-1, version 1

The owner-facing summary says: staff can submit and view their own request; a coordinator can triage and update it; forbidden access is rejected; the app accurately reports submission or update failure.

| Requirement | Behavior | Source/decision |
|---|---|---|
| R1 | A requester can report a service request; title/description fields and a durable reference are proposed design/reliability details | Reporting goal from original description; added details derived/proposed for acceptance |
| R2 | A requester can view status and updates for their own request | Original description |
| R3 | A coordinator can see the queue and update the allowed status | Original description; role assignment decision still required |
| R4 | One requester cannot read another request; preventing unauthorized modification is an added authorization requirement | Read privacy from original description; write protection derived/proposed for acceptance |
| R5 | Failed submission/update is reported clearly, with safe retry behavior | Derived reliability requirement, visible for acceptance |
| R6 | Real-data use follows an accepted data/identity/operations profile | Explicit readiness condition; decisions unknown |
| R7 | SLA/AI triage/attachments are not included in the proposed first increment | Explicit proposed deferral for acceptance |
| R8 | The user flow meets the agreed accessibility/device criteria | Derived assurance requirement; exact agreement remains to be recorded |

Added design/reliability/authorization details in R1, R4, R5 and R8 are labeled as derived/proposed, not falsely attributed to the original words. Acceptance of a specification records the meaningful agreement; it does not authorize provider purchases, secrets, external messaging or production launch.

## 3. Acceptance scenarios

- SC1: valid request submission yields one durable reference and the requester can retrieve it.
- SC2: the coordinator finds the submitted request by its durable reference in the queue, updates a valid status, and the requester sees the updated state.
- SC3: a different requester attempts direct URL/API access and receives no other user's request data.
- SC4: an invalid status or unauthorized role change is refused; a requester attempting to modify another person's request through a direct API/URL is refused, and a trusted fixture confirms that the target request remains unchanged.
- SC5: a lost response followed by retry creates one request/effect under the selected idempotency contract.
- SC6: a failed save preserves useful input and communicates the failure without showing success.
- SC7: an independently observed user completes the flow with the agreed accessibility/device behavior.
- SC8: restart/recovery and backup/restore meet the applicable pilot/production profile before claiming that profile.

All scenarios are proposed. Their presence here is not a passing result.

## 4. Release-sized scope of work

SR-I1/SR-I2/SR-I3 are this fictional service-request project’s increments. They are distinct from the five Gibson product-plan increments in 05-incremental-plan.md.

### SR-I1 — Reviewable intent and useful scope

Deliver PD-1/SPEC-1, explicit questions/decisions, requirements/scenarios, applicable assurance, affected existing surfaces and the first release proposal. Owner benefit: clarify the product and approve its boundaries before coding. Reuse the current planner/decomposer and inspect existing application functionality.

Exit: faithful spec, no hidden material assumption, complete coverage/deferral map and a valid dependency order. This increment can provide benefit through chat and versioned artifacts.

### SR-I2 — One complete preview journey

Implement submit → coordinate → view status in a selected existing target/stack, with the required access/error paths and synthetic reference data. Use existing authentication/data modules when they fit; do not recreate providers merely to fill the architecture diagram.

Exit: actual SC1–SC7 evidence on the exact preview/source, current independent review and applicable checks. A preview demonstration is the advertised scope. It is not automatically permission for real data or production use.

### SR-I3 — Bounded real-use release

Resolve R6's identity/data/operations decisions; complete required recovery, rollout/rollback and support evidence; apply only the separately authorized live operations; verify the deployed version and observe intended users.

Exit: the actual applicable assurance profile is satisfied, known gaps are explicit, and running behavior matches the accepted release. This is when a real-use/production claim may be considered, rather than retroactively labeling SR-I2 enterprise-ready.

## 5. Traceability without a new graph database

| Requirement | Increment | Scenario | Work/source reference | Evidence status in this example |
|---|---|---|---|---|
| R1 | SR-I2 | SC1/SC5 | To be selected/admitted | Planned |
| R2 | SR-I2 | SC2 | To be selected/admitted | Planned |
| R3 | SR-I2 | SC2/SC4 | Role decision pending | Unknown |
| R4 | SR-I2 | SC3/SC4 | To be selected/admitted | Planned |
| R5 | SR-I2 | SC5/SC6 | To be selected/admitted | Planned |
| R6 | SR-I3 | SC8 and selected readiness checks | Decisions/target not selected | Unknown |
| R7 | Explicit deferral | Scope inspection | SPEC-1 v1 | Documented proposed deferral, not implementation proof |
| R8 | SR-I2 | SC7 | Accessibility/device agreement to be recorded | Unknown |

A later real record should point to existing issue/claim/PR/source and actual observation artifacts. An issue number or checked box alone cannot change “planned” to “verified.”

## 6. Proposed release record

```json
{
  "example_only": true,
  "product_definition": "PD-1@1",
  "specification": "SPEC-1@1",
  "increment": "SR-I2",
  "source_sha": null,
  "artifact_digest": null,
  "deployment_id": null,
  "independent_review": "unknown",
  "required_checks": "unknown",
  "user_flow_evidence": [],
  "applicable_permission": "unknown",
  "outcome": "not_implemented",
  "limitations": ["Fictional reference example; no release was executed"]
}
```

This is illustrative data, not a new registered receipt schema or a live delivery record.

## 7. Changed requirement

The owner later asks for anonymous public submission. Record SPEC-1 v2/change CR1 and identify impacts on identity, privacy, abuse/rate limits, data exposure, scenarios, scope and applicable authority. Do not quietly add it to an already accepted private staff workflow.

Preserve stable requirement history and distinguish unaffected implementation from stale evidence. The selected new scope must be admitted/reviewed normally. A changed requirement is a product decision; a new source head still requires the existing exact-head review rules.

## 8. Learning from actual use

A real pilot might reveal that requesters cannot understand a status label, coordinators cannot find urgent work, or duplicate retries occur. Those are different failures: interaction design, missing/changed product intent, and implementation/recovery. Evaluate the cause, compare a bounded improvement and observe later use.

Do not call this learning loop complete because a model proposed a new field or a test was added. The intended user must receive the improved result.
