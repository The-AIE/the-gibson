---
title: The review-ready event
nav_order: 31
---

# 31 — The `review-ready` event

> **Authority:** Non-normative. Explanation of a CI signal; binding merge rules live in [`AGENTS.md`](../AGENTS.md).
>
> Agents push, nobody polls ([01-principles.md](01-principles.md)). This is the push
> that tells the independent reviewer a head is worth reading. Tracking issue: #562.

## Contract

When `claim-isolation` **and** `sensors` both succeed on a non-draft `pull_request` whose
head is in this repository, the `review-ready` job in
`.github/workflows/gibson-self-gate.yml` emits one event for the exact head SHA, in two
forms:

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
| `base_sha` | the base at the time of the run |
| `tier-unknown` | always `true`: the job does not classify the PR; the consumer does |
| `ts` | UTC emit time, `YYYY-MM-DDTHH:MM:SSZ` |

Rules: one event per head (a re-run finds the existing `review-ready` success at that head
and emits nothing, so a consumer never sees a duplicate); nothing on drafts, on fork heads
(`GITHUB_TOKEN` is read-only there), or on events other than `pull_request`; a draft marked
ready is picked up because `ready_for_review` is a trigger. The status is the record of
truth; if the dispatch call fails after the status is posted the job says so in its summary
and does not retry (the next head emits again).

## A signal, not a gate

`review-ready` is not a required check and no rule may name it as one. It says "checks are
green, a reviewer's time is now well spent"; it says nothing about whether the PR may merge.
The merge gate is unchanged: required checks plus two independent vendor verdicts at the exact
head. The emit step is `continue-on-error`, so a failure to emit never turns a PR red; the
reason is written to the job summary, and the controller's fallback sweep still finds the head.
The job checks out nothing: no code from the PR runs with its write scopes
(`statuses: write`, `contents: write` for the dispatch endpoint, `actions: read` for the
timestamps below).

## Who consumes it

The independent-review controller (the job that posts the reviewer App's verdicts) reviews the named head
immediately in a per-repository lane, instead of waiting for its 900 s tick. The tick stays as
the fallback sweep. The controller holds an outbound connection to a relay; its host has no
inbound path. Its change is tracked in #562 (item 2).

## Measurement

The job summary prints `pr_opened_at`, `sensors_green_at` (the `sensors` job's completion
time) and `ready_emitted_at`, plus the seconds between the last two. Together with the
verdict time on the review-evidence comment this gives `open → verdict` and
`sensors green → verdict` per PR, for the drain-rate sensor (#559).
