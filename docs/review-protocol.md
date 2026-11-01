---
title: One independent review
nav_exclude: true
---

# One independent review

> **Authority:** Non-normative explanation of [AGENTS.md](../AGENTS.md).
> The reviewer and release playbooks are the operational dispatch prompts.

The delivery loop is: **build → passing checks → one independent review →
combined corrections if needed → source merge → verify main**. A source merge
does not authorize deployment, migration, spending, or removal of an owner hold.

## What changes

One reviewer who did not generate the change reviews the complete introduced
range at the current head. Cross-vendor is preferred, not required. The same
reviewer examines applicable correctness, security, consent/PII, money,
performance and maintainability risks. Tier C needs adversarial cases, not a
mandatory second reviewer, fan-out, E2/E3 certificate, or per-lens N/A ceremony.

Use a native GitHub APPROVED or CHANGES_REQUESTED review as the verdict. A job
that ran successfully, a sweep that found no receipt, or a conversational
"finished" message does not establish approval. Partial source inspection is
incomplete review. A builder cannot approve its own work by changing hats or
posting an owner's approval comment.

A blocker names a reachable trigger, wrong outcome and file:line or unmet
acceptance criterion. Nits, speculative risks and optional improvements are
notes; a real defect is still blocking when labeled "Minor". Read the actual
findings rather than turning every comment into another repair round.

## Repair and service failures

Combine actionable fixes into one author response. The same reviewer checks
the delta and its effect on the full range. Keep unresolved findings visible;
do not discard them when a PR is replaced. After two substantive repair rounds,
the captain explicitly chooses finish, split, redesign or park. That is a
delivery decision, not a request for another automatic reviewer.

Track queued, running, rate-limited, unavailable, verdict returned and
publication-uncertain separately, keyed by repository, PR, head and attempt.
Use the service's request/run reference when available. A no-verdict attempt
does not count as a product defect. Reconcile an uncertain request or publish
before sending another one. Use at most one delayed included-service retry
after a terminal failure and verified eligibility, only within the remaining
authorized allowance. Never buy capacity, reset a counter, or infer a reset
time from a generic rate-limit reply.

This source change does not alter `config/review-round-caps.json`, existing
service quotas, the Mini controller's consumed attempts, or an explicit
PR-specific retry cap. Preserve those records during migration. Where a cap
already prevents another attempt, the captain records the precise bounded
exception needed instead of silently routing around it.

## Captain's merge check

- Refresh the head, base and full introduced range, retained ownership,
  acceptance evidence and outstanding findings.
- Require one genuine independent native approval covering that head/range
  and actual passing required code/security checks. A helper's READY output
  cannot replace either. Check that a dependency integration did not invalidate
  the reviewed range; do not repeat an unchanged valid review merely because
  a status message is stale.
- Preserve DCO/vendor provenance and existing owner/dependency holds. Keep
  two deliveries actively moving; integrate one change at a time. Waiting for
  review is not permission to fill the queue with extra implementations.
- Check automatic publish/migration effects before a source-only merge.
  Use the expected-head merge guard; read back the merge SHA/target and verify
  permitted post-main checks. Report source integration separately from live
  activation. No admin bypass or fabricated approval.

## Rollout

This PR changes the repository process, policy mirrors and supervisor handoff.
The loop reuses accepted current-head PR evidence instead of dispatching again;
its default selects one different-vendor reviewer. Pending, rejected, ambiguous
or unreadable PR evidence blocks handoff without another request. Before a PR
exists, the existing local-review receipt path remains available. None of these
handoff decisions authorizes a merge or changes the Mini service. This PR does **not**
change GitHub protection, retire a workflow, install a controller or send a new
review. Existing protection stays effective until the separately reviewed
cutover below is applied. A prose amendment cannot make a pending check green.

1. Review and merge the coherent process-source change. Use an eligible native
   reviewer; the existing review-evidence evaluator already recognizes genuine
   current-head CodeRabbit approval for Codex-authored work. Do not reset old
   attempts or infer another allowance from this document.
2. Audit the live rules and prepare a dry-run that adds one required native
   approving review, dismisses stale approvals, requires approval after the last
   push, and preserves actual code/security checks and all unrelated settings.
   Confirm the chosen App/identity's real approval satisfies the rule. Apply
   only under the explicit delivery-control authorization required by AGENTS.
3. Read back that working approval protection **before** removing the duplicate
   required `review-evidence` status. Never create an interval with no independent
   review protection. Preserve `sensors`, `claim-isolation`, their App bindings,
   and existing deployment/migration holds.
4. Retire the duplicate evidence-sweep workflow and its sensor-health inventory
   entries/fixtures together in a coordinated follow-up. Do not disable an
   inventoried workflow in isolation or change another lane's claimed evaluator
   files. Keep failed findings and replacement ancestry; park obsolete review
   infrastructure only after the native path is demonstrated.

Until cutover, an old required check may still block some identities even after
the new source process lands. Report that compatibility limitation explicitly;
do not claim the workflow is already simplified in production.

## Measure the result

Count a delivery only after integration and permitted post-main verification.
Record review eligibility, queue/start/verdict times, substantive repair rounds
and no-verdict attempts separately. Replacement PRs count once per logical
delivery. Use these observations to judge whether a safeguard earns its cost;
PR count, sweep success, and time from CI success to verdict alone are not
delivery or isolated scheduler-wait measures.

## Manifest compatibility

Schema v1 keeps the legacy `E3-exact-head` enum token alongside
`independent-approval-exact-head`. Existing v1 documents remain structurally
valid. The amended canonical policy uses the latter token; an unmigrated core
manifest is diagnosed as policy drift, not an invalid schema enum. Upgrade the
core manifest, AGENTS generated views and validator pins together. Historical
policy/decision records remain readable and are not silently reinterpreted.

## Decision and related work

This implements the owner's November 1 direction in [#622](https://github.com/The-AIE/the-gibson/issues/622),
following the [concrete proposal on #545](https://github.com/The-AIE/the-gibson/pull/545#issuecomment-6559028831).
It supersedes the mandatory review-strength ladder and fan-out in the amended
contract; D-015's removal of an extra human merge click remains intact. Historic
decision entries are preserved. Coordination and queue history remain on
[#562](https://github.com/The-AIE/the-gibson/issues/562); #534's registry/evaluator
claim and #614's preflight correction chain are separate retained work.
