---
title: Lesson ledger freshness
nav_order: 31
---

# Lesson ledger freshness

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> In plain English: the lesson file can go quiet while commits still land, and a rewrite of an old lesson can look like new memory. This sensor reports that. It does not block merges, and a run it cannot finish is not a pass.

Tracks [#571](https://github.com/The-AIE/the-gibson/issues/571), which extends [#418](https://github.com/The-AIE/the-gibson/issues/418). The check is [`scripts/lesson-ledger-freshness.mjs`](../scripts/lesson-ledger-freshness.mjs). The window and the prose-only count live in [`config/lesson-debt-baseline.json`](../config/lesson-debt-baseline.json). The scheduled job is [`.github/workflows/lesson-ledger-freshness.yml`](../.github/workflows/lesson-ledger-freshness.yml).

## What it reports

Freshness is one of three states:

| State | Meaning |
| --- | --- |
| `healthy` | The window was observed, and either nothing landed on the ref, or a new lesson id landed. |
| `stale` | At least one commit on the ref landed inside the window, and the ledger gained no new lesson id. |
| `unknown` | Activity, the ledger, or the baseline could not be evaluated. Unknown is never printed as healthy. |

The shipped window is 14 days (`windowDays` in the baseline). `--window-days` overrides it for one run. A smaller window is allowed. A larger window than the copy committed on the ref is a loosened ratchet.

Intake is the set of lesson ids in the current ledger that are absent from the ledger at the last commit strictly before the window. It is not the file's modification time, not the date written in the heading, and not "any diff". Whitespace, link, and wording edits do not reset freshness. Rewriting the date or the slug of an existing id does not reset freshness. A lesson added and then removed inside the window is not intake.

A quiet window is healthy: activity was readable and zero commits fell inside it. That is the [#418](https://github.com/The-AIE/the-gibson/issues/418) "no evidence, stay quiet" case, under the #571 vocabulary. There is no separate quiet state.

Debt is the count of lessons whose first `Status` line contains the marker `no sensor yet`. The count may fall. It must not rise above `proseOnlyCount`. The sensor does not rewrite the baseline. Age is whole UTC days from a full `YYYY-MM-DD` heading date to `--now`. A month-only heading (`YYYY-MM`) stays a lesson and reports `ageDays=unknown`.

`--annotate` prints `untrusted, verify before acting` for the ledger and for each lesson when freshness is `stale` or `unknown`. When freshness is `healthy`, that phrase is absent. Annotate follows freshness only. A debt-ratchet failure with healthy freshness is in the full report and is not an annotate mark.

## Verdict and exit

`GREEN` means the observation is complete and neither freshness nor the debt ratchet is a finding. `RED` means the observation is complete and freshness is stale, or the debt ratchet is over, or both. `UNKNOWN` means the observation is incomplete.

Exit 0 is a completed observation (`GREEN` or `RED`). Exit 1 is `UNKNOWN`. Exit 2 is usage. A process exit of 0 is not a healthy ledger. Read the `verdict` line. `RED` and `UNKNOWN` also print a `::warning::` line on stdout. `--annotate` does not.

[#418](https://github.com/The-AIE/the-gibson/issues/418) asked a sensor to fail closed when the newest lesson was old and incident evidence existed. This dispatch is report-only, so a stale ledger is `verdict: RED` with exit 0. A missing ledger, a missing ref, or unreadable activity is `UNKNOWN` with exit 1. This workflow does not edit `sensor-health` and is not a pull-request check.

## How a run decides

Live mode reads `memory/LESSONS.md` and local git. It does not call the network. The ref is `--activity-ref`, otherwise `origin/main`, otherwise `main`. It does not fall through to `HEAD`. Every commit on that ref counts, by committer date, including squash commits. A commit exactly at the window start counts. A commit one second earlier does not. A commit after `--now` does not.

The prior ledger is `git show` of `memory/LESSONS.md` at the last commit older than the window start. A young repository whose every root commit is inside the window has an empty prior, so every current id is intake. A shallow repository is `unknown` (`shallow-history`), including a one-commit clone whose only commit sits inside the window. Treating that clone as a young repository would call every current heading intake and report healthy. The workflow checks out with `fetch-depth: 0` for that reason.

Headings match `## L-NNN · YYYY-MM-DD · slug`, and the date may be `YYYY-MM`. The separator is the middle dot used in `memory/LESSONS.md`. A `## L-` line that does not match fails the parse (`malformed-heading`) instead of skipping the lesson. Duplicate ids fail the parse. Headings and status lines inside a fence indented by at most three spaces are not lessons. The marker counts only on the first status line outside a fence.

## Baseline ratchet

`config/lesson-debt-baseline.json` uses schema `gibson.lesson-debt-baseline.v1`. `proseOnlyCount` was measured on 2026-10-25 from `memory/LESSONS.md` (34 lessons whose status contains the marker). The test recomputes that count from the ledger and requires the file to match. It is not a hard-coded assumption.

On a live run the sensor also reads the baseline committed on the ref. The count in the working file may not exceed that committed count (`baseline-raised`). The window may not exceed the committed window (`window-loosened`). A file that is not on the ref yet is `committedBaseline: absent` and is not a failure. That is the state of the first pull request that adds the file. After it merges, the committed copy is the ratchet. An unexpected git failure while the ref exists is `unreadable` and the observation is `UNKNOWN`.

## Workflow

`.github/workflows/lesson-ledger-freshness.yml` runs on a daily schedule and on `workflow_dispatch`. It requests `contents: read`. It does not post issues, does not merge, and does not add a supervisor. L-096 says a supervision job has to name a failure the gates would miss; this job only reports. The job copies stdout into the step summary with `tee`. The script itself does not write that file.

L-092 says a sensor must not grade its own latest non-success. This workflow is not in the sensor-health inventory. A later wiring has to use freshness mode (did a run succeed inside the observation window), not latest-non-success, and it has to accept this limit: a stale ledger exits 0, so a freshness-mode observer that only checks job success will not fail on `verdict: RED`. `UNKNOWN` exits 1, so a run that cannot evaluate fails the job. Promoting `RED` to a failing job, or teaching sensor-health to read the verdict line, is a separate change. Neither is done here.

A coordinator registration for `config/sensor-health-observation.v1.json` would add:

```json
{
  "path": ".github/workflows/lesson-ledger-freshness.yml",
  "mode": "freshness",
  "events": ["schedule", "workflow_dispatch"],
  "windowDays": 2
}
```

`windowDays` 2 there is the observation window used by the daily sensor-health job. It is not the 14-day ledger window. This document does not add that row. Adding the workflow file without the row makes the sensor-health inventory test report an unconfigured workflow. Adding the row without the file reports the workflow missing. Both have to land in the same tree.

## Limits

- Report-only. It does not block merges and it does not auto-merge.
- Exit 0 on `RED` means a green scheduled run can still be a stale ledger. The verdict line and the warning are the result.
- `--annotate` does not show a debt-ratchet failure.
- Fences indented by four or more spaces are not skipped. A heading inside one counts.
- Month-only dates report `ageDays=unknown`.
- Uncommitted heading additions in the worktree count as intake. The current ledger is the working tree, not `HEAD`, when the file is dirty.
- `--baseline` outside the repository is the working file. The committed comparison still reads `config/lesson-debt-baseline.json` on the ref.
- This sensor does not check that lesson ids increase. `scripts/lesson-ledger-lint.mjs` does.
- The step summary is the workflow's copy of stdout. A local run has no summary file.
