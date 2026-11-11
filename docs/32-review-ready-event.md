---
title: The review-ready event
nav_order: 32
---

# 32 — The `review-ready` event

> **Authority:** Non-normative. Explanation of a CI signal; binding merge rules live in [`AGENTS.md`](../AGENTS.md).
>
> Agents push, nobody polls ([01-principles.md](01-principles.md)). This is the push
> that tells the independent reviewer a head is worth reading. Tracking issue: #562.

## Contract

When the self-gate's `claim-isolation` **and** `sensors` jobs both succeeded for the exact
head of an open, non-draft, same-repository pull request, `.github/workflows/review-ready.yml`
records readiness at that head and attempts an advisory notification:

| Form | Value |
|---|---|
| Commit status | context `review-ready`, state `success`, at the head SHA, description `claim-isolation and sensors green; ready for independent review` |
| `repository_dispatch` | `event_type: review-ready`, with `client_payload` below |

`client_payload` has exactly these fields:

| Field | Meaning |
|---|---|
| `repo` | `owner/name` |
| `pr` | pull request number (integer) |
| `head_sha` | the head the checks passed on; the only SHA a consumer may review |
| `base_sha` | the pull request's base at emit time |
| `tier-unknown` | always `true`: the workflow does not classify the PR; the consumer does |
| `ts` | UTC advisory-attempt time, `YYYY-MM-DDTHH:MM:SSZ`; not a deduplication key |

Delivery uses **at-least-once semantics**: each eligible execution attempts a
`repository_dispatch`, including a rerun that finds an existing successful `review-ready`
status. It posts a status only when no success exists at that head. The status records
observed readiness; it is **not** proof that a dispatch or review completed. Separate PRs
sharing a head can reuse that status, but each must independently pass the run, jobs and
current-PR checks before receiving its own PR-numbered advisory.

If status posting succeeds but dispatch fails, the run fails visibly. Rerunning it rechecks
eligibility, reuses the status and retries the dispatch. Successful repeats can also send
another advisory. An unreadable status list or failed status write stops before dispatch;
a failed dispatch remains a failure even when the status was reused. No signal is emitted
for drafts, fork heads, failed or non-pull-request runs, wrong-run associations, closed PRs,
or stale heads. A prior status never bypasses these checks.

This is retryable production of an advisory, not a durable retry queue or a guarantee that
every notification reaches a consumer. Retries need another eligible execution, such as an
Actions rerun; the scheduled heartbeat only checks liveness. Retain the fallback sweep.
A successful dispatch API response confirms acceptance of the request, not consumer processing.

### Consumer deduplication

The consumer must deduplicate durably before starting work, using repository, PR number,
head SHA and its applicable review generation. `base_sha` is supplied for that generation;
the consumer must re-read current repository policy, base and checks when deciding whether
a new review is needed. Repeated `ts` values or changed timestamps do not define new work.
Two different PR numbers must not suppress one another merely because their head SHA matches.

Duplicate and out-of-order advisories must reuse the existing obligation or completed result;
recovery after a consumer crash must reconcile any already-started review before retrying.
The producer does not enforce this consumer contract and does not grant review or merge approval.

## Why it is a separate workflow

A `pull_request` workflow runs the workflow file **from the pull request**. Anything in
`gibson-self-gate.yml` that held `statuses: write` could be rewritten by the PR it judges and
used to post a green status named like a required check. So the emitter lives in its own
file, triggered by `workflow_run` (the self-gate completed) and `pull_request_target`
(`ready_for_review`, for a draft marked ready whose self-gate already finished). Both run the
default-branch version of the file, which a PR cannot change. It checks out nothing, takes
every value through `env`, and re-reads the run, its jobs and the pull request from the API
before writing anything; `gibson-self-gate.yml` holds no write permission, which
`scripts/tests/review-ready.test.sh` asserts by parsing the YAML.

Residual trust: a PR can still edit the self-gate file it is judged by, so "sensors green"
is only as strong as that job. The signal therefore says only "a reviewer's time is now well
spent"; reviewers re-verify the head.

## A signal, not a gate

`review-ready` is not a required check and no rule may name it as one. The merge gate is
defined by `AGENTS.md`: required checks plus a genuine independent approval covering the
complete change at the exact head. A deliberate skip (draft, fork, stale head, gate not green)
leaves the run green.
A failure to emit exits non-zero with the reason in the job summary, so that run goes red in
Actions; there is no `continue-on-error` to hide it. Nothing waits on the run, so no pull
request is blocked. Every failure path is a missing signal, never a false green, and the
controller's fallback sweep still finds the head.

**What sensor-health does and does not watch.** `workflow_run` fires after every self-gate
completion, and most of those runs skip on purpose, so the latest run of this workflow says
nothing about the latest emit: a failed emit followed by an unrelated skip would read green.
Sensor-health therefore grades `review-ready.yml` by its daily `schedule` run only (freshness,
events `[schedule]`): that run is a heartbeat proving the workflow is enabled and its token can
read the API. Individual emits are not monitored by sensor-health; a failed one is visible as a
red run and in its summary, and a missing signal is caught by the controller's sweep.
The workflow only runs from the default branch, so it cannot run on the pull request that
changes it; the first live proof follows the merge.

## Who consumes it

This producer slice does **not** install or activate the event consumer, relay or controller.
The intended controller integration is tracked separately in #562 (item 2): receive an
advisory, reconcile and deduplicate it, then review the eligible head in a per-repository lane,
with the existing tick as fallback. Producer tests do not prove that path is live.

GitHub documents [`repository_dispatch` as a GitHub App webhook event](https://docs.github.com/en/webhooks/webhook-events-and-payloads#repository_dispatch),
with Contents read required for subscription. The selected App, subscription, transport and
actual delivery still need separate configuration and proof; this producer does not verify them.

An alternative relay based on commit `status` events needs Commit statuses read and a `status`
subscription. Reusing an existing status does not create another status webhook, so that
integration must reconcile PRs and retry obligations itself; it cannot assume dispatch retries
generate fresh status events. Neither consumer path is claimed live by this source repair.

## Measurement

The job summary prints `pr_opened_at`, `sensors_green_at` (the `sensors` job's completion
time), `advisory_attempted_at`, whether the status was posted or reused, and whether the
dispatch API accepted the request. Only accepted dispatches print `ready_emitted_at` and
`sensors green to ready emitted`. These measure producer timing, not review latency.

Real consumer receipts and a genuine verdict at the matching head are needed to measure
`open → verdict` and `sensors green → verdict` per PR (#559). Local producer regression tests
cover status-success/dispatch-failure recovery, repeated advisories, and separate PRs sharing
a head. They do not establish live delivery, consumer deduplication or #562's concurrent-repository
latency criterion; those require separate integration evidence after authorized activation.
