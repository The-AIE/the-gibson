---
title: Drain ratchet (report-only)
nav_order: 31
---

# Drain ratchet — the backlog drain rate is a protected measure (#559)

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** The process has to keep emptying the backlog. Once a
> week this sensor compares how much work was finished with how much arrived. If
> that falls well below normal two windows in a row, it points at the process
> changes (a gate, a workflow, a freeze) merged around then and, once enforced,
> opens one recovery issue with an owner, a deadline and a default action: undo
> the change or lift the stop. Today it only reports.

## Why

The 2026-10-08 freeze parked six PRs for one to five weeks. They merged in a single
day once it lifted. Reviewers were fast when they ran; the lane was parked, and
nothing in the harness measured the slowdown or forced a recovery. The ratchet rule
already stops gates from loosening (D-016); this extends it so a process change
cannot lower the drain rate either.

## The measure

Over a rolling 14-day window:

`drain rate = (PRs merged + PRs closed unmerged + issues closed) / (PRs opened + issues opened)`

Also reported: open-to-merge median and p90 (hours) and the number of open PRs
older than 7 days. "PRs closed" counts every unmerged close until the close-reason
enum from #556 exists. The ratchet's own recovery issues are excluded from the counts.

The **baseline** is the same measure over the 28 days before the window. A window is
**below** when `rate < baseline × (1 − marginPct/100)`. A **breach** is every one of
the last `consecutiveWindows` windows below, subject to `floorOpened`: a window (or its
baseline) in which fewer items opened cannot breach, so a quiet week stays quiet.
All three values live in [`config/drain-ratchet.v1.json`](../config/drain-ratchet.v1.json).

## Attribution

The process-change log is derived, not hand-kept: merged PRs whose files match
`processPaths` (workflows, `AGENTS.md`, gate and sensor scripts, review, pr-size and
policy config) and issues labelled `freeze`/`stop` or titled `FREEZE` (capitals). On a
breach the changes inside the drop window are the suspects, newest first. Suspicion is
correlation: the report names where to look, it does not prove a cause.

## Recovery plan

On a breach the sensor plans exactly one issue titled `Drain ratchet breach: <date>`:
the suspects, a recovery owner (author of the most recent suspect), a deadline (7 days,
kept on later runs), and the default action if the deadline passes: revert the suspect,
or for an open freeze lift it and make the parked queue the first day's work (a drain
day). If an issue is already open it is updated, never duplicated; the next run where
the breach clears closes it.

## Report-only, and flipping it

`mode: report-only` (shipped) writes the summary only: no issue is opened, edited or
closed, and nothing blocks a PR. The first month is for calibration. Before anyone flips
`mode` to `enforce` (an owner decision, since it makes the sensor write to the repo):

1. A month of weekly reports exists and the margin, window count and floor were checked
   against them: no false breach in a normal week, a true breach in the October freeze.
2. The close-reason enum (#556) is in place, or the "PRs closed" definition was reviewed.
3. The recovery owner and the deadline behaviour were agreed with the owner.

## Run it

```bash
node scripts/drain-ratchet.mjs --repo The-AIE/the-gibson          # read-only report
node scripts/drain-ratchet.mjs --repo The-AIE/the-gibson --now 2026-10-08T12:00:00Z
bash scripts/tests/drain-ratchet.test.sh                           # fixtures + mutants
```

Exit 0 is a report (breach or not); exit 1 is INCOMPLETE (bad data or API failure,
never reported as "no breach"); exit 2 is usage.
