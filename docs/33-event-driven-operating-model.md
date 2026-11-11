---
title: The event-driven operating model
nav_order: 33
---

# 33 — The event-driven operating model

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** Nothing in this system should wake up on a timer to ask
> "is there anything to do?" Something happens, such as a PR going green, an issue
> closing, or a review landing, and the one thing that needs to react reacts within
> a minute. A timer still exists, but only to catch what an event missed and to notice
> when something that should have happened never did. Pausing a job is a recorded
> decision with a reason and an end date, never a quiet switch.

**Status:** Proposed canon, drafted 2026-10-26 from the Hermes stall triage
([#600](https://github.com/The-AIE/the-gibson/issues/600)). The model itself is not built.
The `review-ready` producer ([docs/32](32-review-ready-event.md)) is the one piece already
in the tree. The decision record is [ADR-0005](adr/0005-event-driven-operating-model.md). This extends
principle 9 in [`01-principles.md`](01-principles.md) ("agents push, nobody polls"), which
states the doctrine without a mechanism.

## Why: what actually stalled

The triage began as "why does Hermes not stay awake." It does stay awake. On 2026-10-26 the
Mini's gateway had been up three days, the scheduler's ticker heartbeat was under a minute
old, the host does not sleep, and `hermes doctor` was clean. What stopped, repeatedly, was
the work, and every outage fits one of six causes.

| When | What stopped | What looked healthy | Cause |
|---|---|---|---|
| 2026-09-18 to 09-30 | Hunter's six Friday-writer jobs | Scheduler running, host up | **A** silent pause |
| 2026-10-03 to 10-08 | The coordinator's deliveries | Every run exited cleanly; a dead lock file went unread (L-090) | **B** alive is not delivering |
| 2026-10-15 to 10-25 | Independent reviews on every repo | The reviewer's launchd job ran | **D** single-threaded consumer, **C** poll floor (#562, D-018) |
| 2026-10-08 to 10-26 | Every Dependabot PR on a downstream product repository | Reviewer green; PRs skipped as `missing-vendor-hint` | **E** a policy gap that looks like a stall |
| 2026-10-23 03:36 to 10-25 19:49 | All five coordinator jobs | Gateway, ticker, telemetry all fresh | **A** bulk pause with no reason, then a silent resume against the 10-25 decision to wait |
| 2026-10-25 to 10-26 | Accepted delivery | 32 scheduler runs on 10-26, each a prompt of about 190,000 characters, growing | **B** and **C** |
| ongoing | Issues "blocked" on issues already closed | Labels intact | **F** stale state nobody owns |

The six causes: **A** a state change with no recorded reason or end; **B** a signal that
says "alive" when the outcome is "nothing delivered"; **C** a latency floor set by a poll
interval; **D** one consumer serving many queues; **E** a rule that blocks work silently;
**F** state that goes stale because nothing is responsible for expiring it.

*Re-verify (measured 2026-10-26):* `hermes cron status` and `hermes doctor` on the operator
host; the host sleep setting (`pmset -g`); the coordinator profile's `cron/executions.db`
and `paused_at` in `cron/jobs.json`. The same `executions.db` re-verifies the 32 runs and
the 25 open PRs in "Liveness is not delivery." Repository webhooks, the "0 of 5"
baseline: `gh api repos/<owner>/<repo>/hooks` on each of the five watched repos returned
an empty list. That endpoint lists repository hooks only. It does not count a GitHub App
webhook or an organization webhook, so the empty list is not a claim that those are
absent. The "25 min seen 2026-10-25" review latency is the triage record; no separate
command was captured. The "18 h" evidence-to-merge figure was recorded the same day against a comment
in `merge-on-green.yml`. That file is not in this repository's `.github/workflows/`
(re-verify: list that directory); 18 h stays a historical measurement.

## The six rules

1. **An event wakes a deterministic reducer; a model is called only for judgment.** A timer
   is allowed in exactly two places: as the slow fallback for an event that was lost, and as
   the detector of an absence (rule 4).
2. **An event is a hint; the system of record is the truth.** A consumer re-reads state by
   id and pins the head SHA before it acts. Payloads are untrusted input, the same rule as
   issue text.
3. **At least once, so idempotent.** The guarantee covers an event the inbox has already
   persisted. Consumers deduplicate on that delivery id, so a second delivery of the same id
   is a no-op. That key is the delivery, not the work. Before starting a review, the
   reviewer also deduplicates the obligation durably by repository, pull request number,
   head SHA and the applicable review generation, the consumer contract in
   [docs/32](32-review-ready-event.md). A repeated advisory with a new delivery id and the
   same generation is the same review, not a second one. The producer does not enforce
   that contract. A GitHub webhook that never reached the inbox is outside the guarantee.
   GitHub does not automatically redeliver a failed webhook, and this model does not add a
   redelivery queue; manual or scripted redelivery is a separate operator action
   ([Handling failed webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries)).
   The reconcile sweep does not replay a missed transition. It re-reads the system of record
   and catches work that current state still requires. A transition that happened and left
   no trace, such as a label added and removed between sweeps, is not recovered. Each
   consumer counts how often the sweep finds work an event should have delivered. That count
   is the gauge of event loss; a rising count is the alarm.
4. **Time is an event.** A stuck PR, a silent consumer, an aging decision and an expired
   pause are all things that did not happen. A sweeper emits them as synthetic events with
   their own deadlines.
5. **Every state change carries a reason.** A pause, a resume, a blocking label, a freeze:
   who, why, citing which decision, until when. A state with no reason is itself a finding.
6. **Alive, working and delivering are three signals.** A scheduler that fires is alive. A
   run that produces output is working. A merged and verified change is delivering. Idle is
   acceptable only when no ready work exists.

## The architecture

```
 GitHub App webhook ──┐
 Actions events ──────┤
 agent hooks / ingest ┼─▶ INBOX (Agent Kontrol: signed, deduplicated, retained 30 days)
 sweeper (time) ──────┘            │
                                   ▼
                       REDUCERS (deterministic; one table: event → transition)
                                   │
              ┌────────────────────┼─────────────────────┐
              ▼                    ▼                     ▼
        work items            decisions queue       brief and alerts
              │
              ▼
   consumers hold an OUTBOUND long-poll to Agent Kontrol: dispatcher, reviewer
   controller, merge captain. Each keeps a slow reconcile sweep as the net.
```

- **Front door.** One GitHub App webhook, pointed at Agent Kontrol, covers every installed
  repository, including new ones. A webhook per repository does not self-populate and is
  not used. Where the App is not installed, this tree's only CI signal is #562's
  `review-ready` producer ([docs/32](32-review-ready-event.md)): a commit status and a
  `repository_dispatch` on that GitHub repository. It is an advisory that the self-gate's
  `claim-isolation` and `sensors` jobs succeeded at that head. It is not proof that every
  required context is green, and it does not wait on `review-evidence`. That context
  stays pending while no listed reviewer has reviewed the head, and a review may start
  while it is. Before starting, the consumer re-reads current repository policy,
  the base and the checks, as docs/32 requires. The advisory does not cover
  issue closure, decision-label changes, or the other catalogue rows; those rows have an
  event source only after the App is installed. The producer does not deliver to Agent
  Kontrol. A relay, or an App subscription to `repository_dispatch`, is what would carry
  the advisory into the inbox. With neither configured, the reviewer's fallback sweep is
  what finds the head. Neither path adds an inbound listener on the Mini.
- **Outbound-only last mile.** The Mini is not reachable from the internet, and D-018
  rejected an inbound receiver and a CI-held credential that can execute on the Mini. This
  model needs neither. Each consumer on the Mini opens a held connection to Agent Kontrol
  with its own scoped credential, which can read only that consumer's events. Agent Kontrol
  never executes anything on the Mini.
- **Reducers.** A table of `event → guard → transition → emitted events`, written in code
  and covered by tests. A model is invoked only when the table says "judgment": writing a
  spec, resolving a conflict, reviewing a diff.
- **Security.** Verify the HMAC signature, reject a delivery id seen before, treat every
  field as data, give the App read access except for the specific writes a reducer needs.

## The event catalogue

Each row names a consumer. An event with no consumer is a finding, not a row.

| Event | Source | Consumer and action | Deadline, breach emits |
|---|---|---|---|
| PR opened, pushed, ready | App webhook | Reducer registers the work item, marks superseded heads | 1 min |
| Head worth reviewing | App webhook, or the `review-ready` advisory | Reviewer controller rechecks policy, base and checks, then starts review at that exact head. The advisory means only that `claim-isolation` and `sensors` succeeded. `review-evidence` may still be pending | verdict 4 h Tier A/B, 12 h Tier C from that event |
| Review evidence posted | `issue_comment` | Merge reducer evaluates that PR only | merge within 15 min of evidence |
| Push to main | App webhook | Reducer merges base into PRs now behind and re-requests review at the new head | 5 min |
| PR merged | App webhook | Release the claim, drop `agent-claimed`, unblock dependents only when this merge satisfied their prerequisite, post-merge verify | 5 min |
| PR closed without merge | App webhook | Release the claim and drop `agent-claimed`. Do not unblock dependents; the prerequisite is not in main | 5 min |
| Issue closed | App webhook | Parse `Blocked by #N` in open issues, relabel, emit `became-unblocked` | 5 min |
| Decision label added or removed | App webhook | Upsert or withdraw the decision row | 1 min |
| Session end, milestone | agent ingest | Record a work event | recorded within 5 min; a missing row is a finding in the next brief |
| `pr-stuck` (green over 30 min with no review started, open over 48 h, conflicting) | sweeper | Brief and owner alert | alert once, repeat after 12 h |
| `consumer-silent` (no work event past its limit while ready work exists) | sweeper | Owner alert | 10 min |
| `pause-unexplained` (no reason) | sweeper | Owner alert, listed in the brief | 10 min |
| `pause-incomplete` (a reason, but the decision or `until` is missing or invalid) | sweeper | Owner alert, listed in the brief | 10 min |
| `pause-expired` | sweeper | Owner alert, listed in the brief | 10 min |
| `resume-uncited` (a resume that cites no decision) | sweeper | Owner alert, listed in the brief | 10 min |
| `resume-not-permitted` (a resume whose cited decision is absent from the record, invalid, or does not permit resuming, including a decision that the job stay paused) | sweeper | Owner alert, listed in the brief | 10 min |
| `decision-aging` (14 days) | sweeper | Owner alert | once per row |
| `dispatch-ready-empty` with raw issues waiting | sweeper | Trigger the Spec Writer | 1 h |

## Pause and resume are recorded decisions

The 2026-10-23 pause had no reason anywhere, and the 2026-10-25 resume had none either.
Neither could be explained a day later, and the resume contradicted the decision of record.

- Every pause names the job, who paused it, why, the decision it follows, and `until`. The
  default maximum is 72 hours; renewing is a new recorded decision.
- Every resume cites the decision that permits it. Hermes already accepts a reason when a
  job is created paused (`--paused-reason`); the tooling should require one on pause as
  well.
- The sweeper reads the scheduler's job records. A pause with a valid decision and an
  unexpired `until` is **held**: expected, and shown in the brief as a line, not an alarm.
  A pause with no reason is `pause-unexplained`. A pause that names a reason but whose
  decision or `until` is missing or invalid is `pause-incomplete`: a finding, not silence.
  A pause past `until` is `pause-expired`. A resume with no cited decision emits
  `resume-uncited`. A resume that cites a decision which is absent from the record,
  invalid, or does not permit the resume, including a decision that the job stay paused,
  emits `resume-not-permitted`. Citing a decision is not enough: the cited decision has
  to permit the resume. The 2026-10-25 resume had no citation, so `resume-uncited`
  covers that record; a later resume can cite a decision and still contradict it.
  The catalogue gives each event the same owner alert, due in 10 minutes.
- The dead-man switch's current alert reads "Check the Mini scheduler and resume it." For a
  deliberate pause that wording invites exactly the unrecorded resume it is meant to
  prevent. It should say "paused by decision X until Y" when it has a reason.

## Liveness is not delivery

On 2026-10-26 the coordinator's scheduler ran 32 times and its latest run reported 25 open
PRs and "no new accepted delivery"; its actions were handoff comments awaiting an executor
acknowledgement that no executor was positioned to give. Every health signal was green.

| Consumer | Alive | Working | Delivering | Alarm when |
|---|---|---|---|---|
| Coordinator or dispatcher | scheduler heartbeat | run completes and writes a work event | a lane started or a PR merged | ready work exists and nothing delivered for 24 h |
| Reviewer controller | process and lock held | review published | verdict at exact head within SLA | green PRs waiting past SLA |
| Spec Writer | job ran | issue specced or decision filed | dispatch-ready depth within bounds | raw issues and none specced for 24 h |
| Merge captain | job ran | PR evaluated | PR merged on evidence | evidence present and unmerged past 15 min |

"Idle" is a legitimate state only when the queue it serves is empty. The sweeper computes
that from the inbox, not from the consumer's own report.

## What stays on a timer

| Timer | Why | Cadence |
|---|---|---|
| Sweeper in Agent Kontrol | emits absence events | 5 min |
| Per-consumer reconcile sweep | re-reads current state for work an event should have delivered; counts those misses. Does not replay a transition that left no trace | 30 to 60 min |
| Reviewer fallback probe | D-018's 60-second ready probe, kept as the reviewer's fallback until the owner amends it. This row is not the 30 to 60 min sweep | 60 seconds |
| Dead-man switch | watches the watcher; no model | 10 min |
| Morning brief | one pushed summary | daily 07:00 |

Each timer is labelled in code as a fallback or an absence detector. A timer that is
neither is a poll and is removed.

## Relationship to D-018 and the work in flight

- **D-018** (2026-10-22) chose a 60 second ready probe and rejected three alternatives,
  including "Actions to `repository_dispatch` to a Mini receiver" because that needs an
  inbound service or a CI-held credential that can execute on the Mini. The outbound-only
  design above needs neither, so the rejection does not apply to it. If the owner approves
  ADR-0005, that 60-second probe becomes the reviewer's fallback and D-018 is amended, not
  deleted. It does not move to the 30 to 60 minute cadence used by the other consumers.
- **#562** (CI emits `review-ready`) is the producer of that advisory on a repo without
  the App webhook: `claim-isolation` and `sensors` succeeded, not every required
  context. The producer is already in this tree
  ([docs/32](32-review-ready-event.md), `.github/workflows/review-ready.yml`). Tracking
  issue #562 was still open on 2026-11-11 (`gh issue view 562 --repo The-AIE/the-gibson`).
  The producer writes a GitHub status and a `repository_dispatch`. It needs no Mini
  receiver. It reaches Agent Kontrol only when a relay or an App subscription to
  `repository_dispatch` is configured. Until then the reviewer's 60-second fallback probe
  is what finds the head.
- **Controller repository pull request 45** (per-repository reviewer lanes and event
  dispatch with the tick as fallback) is the consumer side of this model and conforms to
  it. The repository slug stays out of this tree.

## Rollout

1. Finish #562 (the `review-ready` producer is already in the tree) and land controller
   pull request 45. Both address the measured review latency.
2. Agent Kontrol: the GitHub App webhook receiver and the inbox.
3. The dispatcher and reviewer consumers move to the outbound long-poll.
4. The sweeper, starting with `consumer-silent`, `pause-unexplained`, `pause-incomplete`,
   `resume-uncited`, `resume-not-permitted` and `pr-stuck`.
5. merge-on-green moves to events with its cron kept as the fallback sweep.
6. After the owner answers question 3, either retire the model-driven coordinator loop or
   keep it as the exception handler only. A model runs only where the reducer table says
   the step is judgment.

## Measures of success

| Measure | Baseline (measured) | Target |
|---|---|---|
| Head worth reviewing to review started, p90 | up to 15 min tick plus the queue ahead; 25 min seen 2026-10-25 (triage record; no separate command captured). "Worth reviewing" is the `review-ready` advisory or the App event, not every required context | under 2 min |
| Evidence posted to merged, p90 | 18 h, measured 2026-10-26. Cited `merge-on-green.yml` is not in this repo's `.github/workflows/` as of 2026-11-11; historical figure. The 10 min cron sweep is the timer this row replaces | under 15 min |
| Work found by a fallback sweep that an event should have caught | not measured | under 2 percent |
| Paused jobs with no recorded reason | 4 coordinator jobs, 10-23 to 10-25 (`paused_at` in `cron/jobs.json`) | 0 |
| Hours per day a consumer is idle while ready work exists | not measured; the coordinator ran 32 times with 25 open PRs on 2026-10-26 (`executions.db`) | 0 |
| Repository webhooks | 0 of 5 repository hooks, measured 2026-10-26 with `gh api repos/<owner>/<repo>/hooks`. That count excludes GitHub App webhooks and organization webhooks | one App webhook is the front door; a webhook per repository is not the target |

## Non-goals

Replacing the Gibson's gates, which still decide merges. Moving any consumer onto an
inbound listener. Removing the daily brief. Building any of it in this repository; the
receiver, inbox, long-poll consumer and sweeper belong to Agent Kontrol
(`mrhinkle/agent-kontrol` epic #62).

## Questions only the owner can answer

1. Approve amending D-018 so the 60 second probe becomes the fallback once a receiver
   exists.
2. The App webhook has to be configured in the GitHub App's settings, which only the owner
   can change. Use the existing `aie-independent-review` App or a new Agent Kontrol App?
3. When the dispatcher bridge exists, is the model-driven coordinator loop retired or kept as
   the exception handler only?
