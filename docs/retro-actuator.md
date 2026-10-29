---
title: Retro actuator
nav_order: 32
---

# Retro actuator

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

Issue [#569](https://github.com/The-AIE/the-gibson/issues/569) records one repair
incident for a repeated CI failure or a review-cap breach. The program is
`scripts/retro-actuator.mjs`. Signature normalization lives in
`scripts/lib/retro-signature.mjs` at `signature_schema_version` 1.

This page describes that program. It does not add a merge check, a supervisor,
or a lesson-ledger write.

## What a run reads

A run reads JSON lines from `--events FILE` or from stdin (`--events -`, or no
`--events` flag). The kinds it understands are `ci-failure`, `review-cap`,
`lifecycle`, `budget-override`, and `detector-status`.

No live collector is wired. Tests drive the program from fixtures and do not
use the network.

Two identifiers:

- `event_id` = (`repo`, `attempt_id`, `head_sha`, `detector_version`, `raw_signature`).
  This is delivery identity. A repeated line is one delivery.
- `incident_key` = (`repo`, normalized signature, `signature_schema_version`).
  Attempt id and head SHA are stored as evidence. They are not dedup inputs.
  Two deliveries of the same attempt id are one attempt, even when the head SHA differs.

The first distinct failed attempt of a new key is pending. The second distinct
attempt, or one review-cap breach (`review_rounds` greater than the tier cap,
not equal to it), records one incident and one repair-issue request. Replaying
the file, interleaving the same lines, or running two processes against the
same state file still yields one incident and one request.

Review caps are read from `config/review-round-caps.json`. An omitted tier uses
that file's `default`. An unknown tier, a missing round count, or an unreadable
caps file is UNKNOWN. The run writes no state.

## Lifecycle

States move `detected` to `triaged` to `artifact-verified` to `deployed` to
`effective`, and `deployed` or `effective` can move to `reopened`. `reopened`
can move back to `triaged`. Any other edge is rejected, the state stays put,
and a later replay of that same rejection is rejected again.

`deployed` is stored only with a 40-hex lowercase `remediation_sha`, a
`workers_evidence_ref` that is non-empty and not the literal `unknown`, and an
RFC3339 `recorded_at`. `effective` is stored only with `detector_health` equal
to `healthy`, an exposure window whose end is after its start, a
`minimum_sample` of at least 1, a `sample_count` at least that minimum, and a
`measurement_ref` that is non-empty and not the literal `unknown`.

A later failed attempt while the incident is `deployed` or `effective` reopens
that same incident and revokes the claim it left. This program does not edit
`memory/LESSONS.md`.

## Flood, budget, drift

At most one real repair issue is requested per incident key per 7 days, measured
from `--now` (or the clock, when `--now` is omitted). A suppressed repeat does
not consume the repair budget.

Each incident keeps the repair budget it was created with (default 2). When
that budget is exhausted, automatic requeue stops and the run records an
escalation. `--escalate-to NAME` stores that name. If the flag is absent and no
named escalation is already stored, the human is the literal `unknown`,
requeue stays blocked, and the evaluation is UNKNOWN. A later run that omits
the flag keeps a name already stored. A `budget-override` event with a named
actor resets the used count and starts a new budget of the same size. An actor
of `unknown` is rejected and does not reset the count.

If the state's trusted signature schema is not version 1, or an event brings a
detector version the state does not trust yet, the run reports drifted open
keys and does not apply the batch and does not call `gh`. The following run
that repeats those versions promotes trust and then applies. A further new
detector version withholds again. Open incident keys are not rewritten in place.
A fresh empty state trusts the current schema and the versions in that first
batch. A state that already has incidents but no trusted schema is refused.

## Mode and the workflow

The default mode is dry-run. The report lists the issue the program would open.
`--apply` is the only path that runs `gh issue create`. Dry-run still writes
the state file, so a second dry-run against the same `--state` path dedups.

`.github/workflows/retro-actuator.yml` is a new workflow. It runs on a weekly
schedule and on `workflow_dispatch`. It passes no `--apply`. Its state path is
under the runner temp directory, so a scheduled run does not remember a previous
run and will print the same plan again when the same events are still there.
It does not create issues. The events path it reads is
`retro-actuator-events.jsonl` at the workspace root. That file is not part of
this program. When it is absent, the run exits 3. That exit means the run is
blind, not that the tree is healthy. The workflow is not a pull-request check.

The in-repo default state path, used only when `--state` is omitted, is
`docs/retro-actuator-state.json` under `--root` (the repo root by default).
That file is local runtime state. It is not a committed ledger.

## Exit codes

| Exit | Meaning |
| --- | --- |
| 0 | The batch was evaluated. Drift reported on this run is still exit 0. Exit 0 is not a health claim about the repository. |
| 1 | A transition was rejected, the state file was corrupt or the wrong shape, or the state file could not be saved. |
| 2 | Usage. |
| 3 | UNKNOWN. The run could not evaluate. `gh issue create` failed, or a previous create did not finish. |

UNKNOWN writes `retro-actuator: UNKNOWN: ...` on stderr. A usage error writes
`unknown flag:` for a flag the program does not recognize.

## Limits

These are limits of this program, not properties it has proven.

- `deployed` and `effective` check evidence shape only. This program does not observe which SHA workers run, and it does not measure the exposure window itself.
- A missing, failed, stale, or empty detector batch is UNKNOWN. It is not a healthy result, and it writes no state.
- Dry-run is the default. `gh issue create` runs only with `--apply`. Nothing here merges pull requests, claims work, or adds a supervisor.
- The program does not edit the lesson ledger.
- Dedup holds only for a `--state` file that is reused. The scheduled workflow's temp state does not remember an earlier run.
- Seen event ids are kept for the life of that state file and are not a bounded log.
- Duplicate JSON object keys follow the runtime JSON parser.
- No live event collector is wired.
- The literal `unknown` does not satisfy a human name, a workers-evidence ref, or a measurement ref.
