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
emits one event for that head, in two forms:

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
| `ts` | UTC emit time, `YYYY-MM-DDTHH:MM:SSZ` |

Rules: one event per head (a re-run finds the existing `review-ready` success at that head
and emits nothing, so a consumer never sees a duplicate); nothing for drafts, fork heads, a
failed or non-pull-request run, a pull request that has since moved to a newer head or been
closed, or events other than the two below. The status is the record of truth; if the
dispatch call fails after the status is posted the summary says so and nothing retries.

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
unchanged: required checks plus two independent vendor verdicts at the exact head. A
deliberate skip (draft, fork, stale head, gate not green, already emitted) leaves the run green.
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

The independent-review controller (the job that posts the reviewer App's verdicts) reviews
the named head immediately in a per-repository lane, instead of waiting for its 900 s tick.
The tick stays as the fallback sweep. The controller holds an outbound connection to a relay;
its host has no inbound path. Its change is tracked in #562 (item 2). Note that GitHub does
not deliver `repository_dispatch` to a GitHub App's webhook: an App-fed relay keys on the
`status` event for context `review-ready` (the App needs Commit statuses read and a `status`
subscription).

## Measurement

The job summary prints `pr_opened_at`, `sensors_green_at` (the `sensors` job's completion
time) and `ready_emitted_at`, plus the seconds between the last two. Together with the verdict
time on the review-evidence comment this gives `open → verdict` and `sensors green → verdict`
per PR, for the drain-rate sensor (#559).
