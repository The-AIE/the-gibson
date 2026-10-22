---
title: "ADR-0003: Land routine PRs without the base-tip lock; verify post-merge and pre-deploy; roll back cheap"
nav_exclude: true
---

# ADR-0003 · 2026-10-21 · Land routine PRs without the base-tip lock; verify post-merge and pre-deploy; roll back cheap

**Status:** Proposed. This record documents a hypothesis and the experiment that tests it. It changes no gate by itself.
**Owner decision required:** AGENTS.md says loosening a merge gate needs the owner's sign-off. Mark approved writing this ADR on 2026-10-21 ("let's do that, and document the hypothesis"). The experiment starts only when he ticks the sign-off line in "Rollout".
**Decision record:** `memory/DECISIONS.md` D-020 points here.
**Related:** ADR-0001 (the-gibson#511, ready probe), ADR-0002 (the-gibson#513, reviewer survives a provably identical base-only move). This ADR assumes ADR-0002 lands; it does not duplicate it.

## Context

Anthropic's engineering post "Redesigning source control at Anthropic" (2026-10-13; Scion, the source control system, and Antique, the review tool) reports merges rising from about 2,500 a day in May 2026 to over 30,000 in September, and says: "A proper merge queue doesn't make much sense at agent scale." They "haven't been able to effectively replicate the industry standard of a global repository lock," so they "invested in post-merge and pre-deploy automated testing," accept that concurrent changes conflict, and let Claude fix the conflicts. Antique approvals carry semantic constraints that separate comment-only changes from sensitive logic. Human reviewers examine intent, and their main job is to say "no". All numbers are Anthropic's own and unverified.

Our fleet is at the opposite extreme. On The-AIE/conference-os every PR needs exact-head review evidence; `merge-on-green.mjs` refuses any head that does not contain the current `main` tip; a later rebase is a new head that resets review unless the carryover rule applies; and the Mac Mini reviewer's snapshot pinned the base sha, so a merge to main during a review discarded it (ADR-0002 fixes the provably identical case). PR conference-os#2357 (2026-10-21) took over two hours from first push to a verdict, 31.5 minutes of it waiting on ticks, and one paid review was discarded because another PR merged (ADR-0001 timeline). The storage half of Scion does not apply to us: our repos are small and git is not our bottleneck. The process half might.

## Hypothesis

For **routine** changes (the risk classifier's `routine` class: not schema, not Tier C, not production data, not control-plane files), requiring the head to contain the base tip before merge buys little safety and costs most of the queue latency. If main is tested after every merge and production is tested before and after every promote, and if rollback at each layer is cheap and proven, routine PRs can land without the base-tip requirement with no increase in escaped defects.

Falsifiable form: over the experiment window, median push-to-merge time for routine PRs at least halves, every red main is reverted automatically within 15 minutes, and no production incident needs more than a rollback.

## Where rollback is cheap, and where it is not

| Layer | Rollback | Cost | Verdict |
|---|---|---|---|
| `main` after a bad merge | Revert PR of the last merge (at our volume, a few merges an hour, there is nothing to bisect) | Minutes, automated | cheap |
| Code on Vercel | `vercel rollback` to the previous READY production deployment (rollback candidates exist today on `conference-os-ata`) | Seconds | cheap |
| Schema | None. Migrations are additive-only with `prisma migrate deploy`; no down path; PITR is an incident, not a rollback | Hours, owner-led | not cheap |
| Production data written by new code | None | Unbounded | not cheap |
| Control plane (workflows, trust files, merge captain) | Revert possible, but a bad change can disable the gates that would catch it | High blast radius | not cheap |

So the pattern applies to routine code only. Everything in the last three rows keeps today's gates, serialized, unchanged.

## Design

1. **Merge policy for routine PRs.** Keep the required contexts (conference-os: `DCO`, `quality`, `build-e2e-required`; the-gibson: `claim-isolation`, `sensors`) and one independent review at the exact head. In `scripts/merge-on-green.mjs`, stop requiring the head to contain the `main` tip when nothing that landed on main since the merge base touches any file the PR touches. That is the same forward-only, no-overlap test `scripts/pr-review-carryover.mjs` already applies to review evidence. Overlap still blocks; GitHub still refuses textual conflicts.
2. **Post-merge gate on main.** `ci.yml` already runs on push to `main` and `preview-deploy-smoke.yml` follows. Add a workflow that, when CI on main completes with failure after a merge, opens a revert PR of that merge, labels it `revert`, and notifies. A revert of a reviewed change is cleared by CI alone (new evidence class; one line in the trust config). This is the rollback for main.
3. **Pre-deploy gate and production rollback.** Promotion stays a separate step (core: `release`; events.allthingsai.org: a CLI deploy from the merged install repo, see gibson-ship's deployments card). Before promote: smoke on the exact SHA plus the feature-map receipts of docs/30. After promote: smoke on the public host; on failure, `vercel rollback` to the previous READY deployment, and the rollback is recorded on the sync PR. For CLI deploys, the previous deployment URL is written down before deploying.
4. **Semantic approval classes.** Add a `trivial` class to the risk classifier (docs-only, test-only, comment-only, as detected from the diff, never from labels) with a cheaper evidence requirement: CI plus one vendor verdict, no second vendor. This is the Antique idea at our scale.
5. **Unchanged.** Schema, Tier C, production data and control-plane files: today's gates, serialized, owner-gated where they are now.

## Rollback drills (before anything is loosened)

- **Vercel:** in a quiet window, `vercel rollback` `conference-os-ata` to the previous READY deployment, verify events.allthingsai.org serves it, roll forward, verify again. Production action: Mark runs it or says "go" with the command in front of him. Record the two deployment ids here.
- **Auto-revert:** canary the revert workflow on the-gibson first. It has no application deploy, so a deliberately red merge there costs nothing. Required: the revert PR opens within 15 minutes of the red CI run, carries the right base and head, and is cleared by CI alone.
- Neither drill has been run as of this ADR.

## Experiment

- **Scope:** routine PRs on The-AIE/conference-os, two weeks after the drills pass and the sign-off is ticked.
- **Baseline:** the same metrics for the two weeks before, from the Mini journal, `review-evidence` status timestamps and `merge-on-green` decisions. The Mini journal is the only source for discarded reviews.
- **Metrics:** push-to-merge time (median, p90); reviews discarded (`snapshot-changed` count); re-reviews per PR; red-main incidents; auto-reverts opened and time-to-revert; production rollbacks; escaped defects (bugs filed against a routine change within 7 days of its deploy).
- **Decision rule, set now:** adopt if median push-to-merge halves and every red main is auto-reverted within 15 minutes and escaped defects do not rise. Abort immediately on any production incident that needs more than a rollback, or on a second red main in one day that was not auto-reverted.
- **What this does not measure:** semantic conflicts between non-overlapping files that no test catches. The bound on that risk is the same as carryover's: the reviewed lines are unchanged and nothing under them moved.

## Alternatives considered

- **Keep the base-tip lock and only speed up the reviewer** (ADR-0001, ADR-0002). Worth doing regardless; it does not remove the restack-and-re-review cycle that serialized merges force.
- **A GitHub merge queue.** Validates groups against the updated base, but requires every required check to answer the `merge_group` event, and the Gibson keeps merge queues off until equivalent support is implemented and canaried (gibson-setup). Also the thing Anthropic says stops making sense at scale.
- **Adopt the storage half too.** Not applicable: small repos, no checkout pressure, and Anthropic itself says Scion "is by no means a suitable replacement for git for general use."

## Rollout

- [ ] Owner sign-off to run the experiment (Mark): ____ (date)
- [ ] Vercel rollback drill done; deployment ids recorded above
- [ ] Auto-revert canary passed on the-gibson
- [ ] Baseline metrics captured (two weeks)
- [ ] `merge-on-green.mjs` routine stale-base relaxation behind a feature flag, default off
- [ ] Experiment window opened; results appended to this ADR; decision recorded in D-020

## Sources

- Anthropic, "Redesigning source control at Anthropic", 2026-10-13: https://www.anthropic.com/engineering/redesigning-source-control
- Simon Willison, 2026-10-13: https://simonwillison.net/2026/Oct/13/redesigning-source-control-at-anthropic/
- Hacker News thread: https://news.ycombinator.com/item?id=50073633
- conference-os: `.github/workflows/merge-on-green.yml`, `scripts/merge-on-green.mjs`, `scripts/pr-review-carryover.mjs`, `docs/RELEASING.md` § Rollback (read 2026-10-21)
- Gibson: docs/23 delivery control, docs/29 guarded state transitions, docs/30 verification lever
