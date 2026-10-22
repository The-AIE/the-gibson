---
title: "ADR-0001: Independent reviewer starts on a 60-second ready probe"
nav_exclude: true
---

> **Authority:** Non-normative. Design record and rationale only; it adds no gate. Binding rules live in [`AGENTS.md`](../../AGENTS.md). The Mini job it describes is operated outside this repo.

# ADR-0001 · 2026-10-22 · The independent reviewer starts on a 60-second ready probe, not the 15-minute tick

**Status:** Proposed (PR open; nothing applied to the Mini).
**Owner decision required:** installing the probe changes a live launchd job on the Mac Mini. The exact files are in [`independent-review-ready-probe/`](independent-review-ready-probe/). Mark applies them, or says "apply" with the diff in front of him.
**Decision record:** `memory/DECISIONS.md` D-018 points here.

## Context

The aie-independent-review App on the Mac Mini gates every conference-os PR behind authenticated Grok+Codex review evidence. It runs as `com.peripety.neuro-independent-review`, `StartInterval 900`, wrapper `neuro-independent-review-run.sh` → `neuro-independent-review.py`. Each run takes a `flock` on `state/controller.lock`, walks every open PR, and skips any whose required contexts (`DCO`, `quality`, `build-e2e-required`) are not all green (`required-context`), or whose pinned snapshot (head, base sha, base ref, commits, files, labels) moved between start and finish (`snapshot-changed`). A head that was published, or exhausted `maxAttemptsPerHead`, is never reviewed again.

The journal shows what the 15-minute tick costs. Reviews themselves take 2–17 minutes (27 reviews, mean 7.4 min). The wait before one starts is up to 15 minutes plus the scan, and the fallback also shows ~2,300 `required-context` skips in a week, so most ticks walk every PR and review nothing.

PR conference-os#2357 on 2026-10-21/22, reconstructed from the journal and the check-run timestamps:

| Event | Time (UTC) | Wait |
|---|---|---|
| Head `b78ed59` pushed; `quality` green | 23:38 → 23:54:18 | |
| Review of #2357 starts (after #2356 finished on the 23:50 tick) | ~23:59 | 5 min |
| #2356 merges, main moves, #2357's pinned base sha changes | 00:00:14 | |
| #2357 review discarded `snapshot-changed` after ~14 min of paid review | 00:13:39 | |
| Review of `b78ed59` restarts on the next tick | ~00:30 | **16 min** |
| Verdict FAIL | 00:44:24 | |
| Head `9315680` pushed; `quality` green | 00:46 → 01:03:08 | |
| 01:00 tick had already skipped it `required-context` at 01:01:25 | | |
| Review of `9315680` starts on the next tick | ~01:18:39 | **15.5 min** |
| Verdict FAIL | 01:35:44 | |

Two findings. First, 31.5 minutes of the round were spent waiting for a tick while the PR was already reviewable. Second, the "push mid-review" cycle was not a push: the head was unchanged, and the snapshot broke because main advanced when the reviewer's own pass on #2356 merged. That is a separate defect (see Follow-ups) and this ADR does not change it.

## Decision

Add a **ready probe**: a second launchd job, `com.peripety.neuro-independent-review-probe`, `StartInterval 60`, running `neuro-independent-review-probe.py`. Each minute it makes **one GraphQL call per covered repository** (open PRs against the default branch, head sha, head repo, draft flag, `statusCheckRollup` of the head commit; measured cost 2 rate-limit points, ~1.5 s). A PR is *ready* when every required context is `COMPLETED/SUCCESS` on its current head, the review-evidence context is not terminal (any completed outcome counts as terminal for the probe, stricter than the controller's success/failure test), the head is not in `state.json.published`, and attempts on the head are below `maxAttemptsPerHead`. When at least one ready head has not been fired for, the probe runs the **existing wrapper** `neuro-independent-review-run.sh` once and waits for it; the controller's own `maxPullsPerRun` decides how many of them that run reviews.

The 900-second job stays loaded, unchanged, as the fallback. The controller, its policy, its journal and `state.json` are not modified.

### Single-flight, no duplicate paid runs

- `state/probe.lock` (`flock`, non-blocking): two probes never overlap; a probe that finds the lock held exits.
- `state/controller.lock` already serialises controller runs. If the probe's run loses that lock to a scheduled run, the wrapper prints `another instance holds the lock`; the probe sees it, records nothing, and retries next minute.
- `state/probe.json` records each `repo@head` the controller has **decided** after a probe-started run. The wrapper prints one line per PR it reaches (`repo#N skip <reason>` or `repo#N <sha> pass|fail`); the probe records a head only when its line is present and the reason is not one that means "try again" (`required-context`, `snapshot-changed`, `snapshot-unreadable`, `halt`). A head the controller skips for a reason the probe cannot see (`missing-vendor-hint`, `diff-incomplete`, `diff-too-large`) is therefore fired **once** and afterwards left to the fallback scan, which is today's behaviour. The dry run on 2026-10-22 listed seven such heads; on install the probe fires one controller run for them (about 20 s of skips, no paid review), then goes quiet.
- A head the controller never reached (`halt`, `vendor-state-not-plain`, a fourth simultaneous head over `maxPullsPerRun`) or abandoned (`snapshot-changed`) has no settling line, is not recorded, and fires again next minute. This is what turns the 16-minute restart above into a 1-minute one.
- The wrapper run has a timeout of `maxPullsPerRun × reviewerTimeoutSeconds + 300 s` so a hung wrapper cannot hold `probe.lock` forever. Heads in a timed-out run are recorded as settled, so the probe does not re-fire a hanging wrapper every minute; they belong to the fallback scan from then on. (The wrapper's `git fetch` runs before the controller takes `controller.lock`, so a hung fetch never holds that lock; a long legitimate review does, for the scheduled job as much as for a probe-started one, exactly as today.)
- Per-head dedupe of paid work stays where it is: `published[repo@head]`, `attempts`, `_existing_evidence` on GitHub, and the daily budget are all enforced by the controller on every run, probe-started or scheduled.

### What the probe does not do

It does not replace the scan. It does not touch the trusted checkout (the wrapper does that only when a run is actually started). It does not write the journal. It does not call the vendors. With no reviewable PR it costs two HTTP requests a minute (installation token + GraphQL), about 2,900 requests a day against a 5,000-per-hour App limit.

## Expected saving per PR round

Wait from "required contexts green" to "review started", counting only the tick wait. Queueing behind another PR's review (2–17 min, serial, `maxPullsPerRun: 3`) is unchanged by this design and is additive in both columns:

| | Today (900 s tick) | With probe (60 s) |
|---|---|---|
| Mean | ~8 min (half the tick + ~40 s scan) | ~1.2 min (half the interval + probe + wrapper + scan) |
| Worst | ~15.7 min | ~1.7 min |
| After `snapshot-changed` | 15–30 min (next tick, maybe behind another PR) | ~1 min |

For #2357's round as measured: 16 min + 15.5 min = **31.5 min saved**, out of a round that took 2 h 0 min from first push to final verdict. A round with one start saves ~7 min on average, 14 min worst; every `snapshot-changed` or `required-context` miss adds another 14–15 min saved. The paid review discarded at 00:13 (~14 min of Grok+Codex time) is not recovered by this change.

## Alternatives rejected

- **GitHub Actions `workflow_run` → `repository_dispatch` → receiver on the Mini.** Needs an always-on inbound path: a self-hosted runner (none exists on the Mini), a Tailscale Funnel listener, or a Tailscale OAuth client plus SSH key stored in conference-os secrets so a hosted runner can reach the Mini. Each is a new always-on service or a new credential that can execute on the Mini, and each still needs the probe's readiness logic to avoid firing on every check completion. Rejected while a no-new-service option meets the one-minute goal.
- **Set the existing job to `StartInterval 60`.** The full scan walks every open PR with 3–5 REST calls each (~40 s and ~60 calls per tick); at 60 s that is ~86,000 calls a day and a trusted-checkout fetch every minute. Rejected.
- **A "review-ready" commit status set by a conference-os workflow.** Needs a workflow change in conference-os and still needs a poller to see it. The probe computes the same thing from `statusCheckRollup` with no repo change.

## Rollout (owner-applied)

1. `scp` `neuro-independent-review-probe.py` to `~/Library/Application Support/Neuro/bin/` on the Mini, `chmod 700`.
2. Replace `__HOME__` in the plist with the Mini account home, copy to `~/Library/LaunchAgents/`, `chmod 600`, then `launchctl bootstrap gui/$(id -u) <plist>`.
3. Watch `independent-review/probe.out.log` for one cycle: expect `trigger …` lines for the seven already-green heads, the wrapper's skip lines, then quiet minutes.
4. Rollback: `launchctl bootout gui/$(id -u)/com.peripety.neuro-independent-review-probe`; delete `state/probe.json` and `state/probe.lock`. The 900-second job never stopped.

Verified before opening this PR: the probe ran on the Mini in `--dry-run` from a scratch directory (reads only; 2.6 s; wrote nothing) and reported the seven green-but-unpublished heads the controller currently skips every tick. `test_probe.py` beside the script covers readiness parsing (latest run wins on re-run names), the settle rules, and the timeout.

The probe imports seven names from the controller (`GitHubClient._repo_json`, `_decode_json`, `_published_key`, `SHA_RE`, `IncompleteRead`, `load_policy`, `load_state`). A controller rename breaks the probe at import, every minute, into `probe.err.log`, while the fallback keeps working. Add that log to the Mini health check when installing.

## Follow-ups (not in this change)

- **`snapshot-changed` on base movement.** `_snapshot` pins `base` sha, so any merge to main during a review discards it. With merge-on-green landing the reviewer's own passes, a busy day makes every review after the first a coin flip. Decide whether base sha belongs in the pin (the review diff is `compare(base, head)`, so a moved base changes the diff) or whether the controller should re-pin on a base-only move and compare the diff instead.
- **Fire only the ready PR.** The wrapper walks every open PR before reaching the ready one (~40 s). A `--only <number>` flag on the controller would make a probe-started run cost one PR's calls. Not needed for the one-minute goal.
- **Second covered repo.** The policy lists only conference-os today; the probe loops over `policy.repositories`, so adding the-gibson is a policy change, not a probe change.

Revisit when: the probe's own journal shows controller runs it started that reviewed nothing for a week (readiness logic drifted from the controller's), or GitHub rate-limit headroom falls below 1,000 points.
