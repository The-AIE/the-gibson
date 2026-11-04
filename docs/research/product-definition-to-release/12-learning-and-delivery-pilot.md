---
title: "Learning from defects and the hourly delivery pilot"
nav_exclude: true
---

> **Authority:** Non-normative pilot plan. Binding behavior remains in AGENTS.md and current owner instructions. This document enables no check, reviewer, setting, deployment or migration.

# Learning from defects while improving delivery speed

**Owner direction, November 1:** check in the custom-lint learning proposal and work toward closing one PR an hour. Treat that as a hypothesis about **verified source merges**, not a quota for closing work. Use the existing #210 learning epic and #562 captain ledger; do not build another coordinator or measurement service.

## What counts, and how the clock works

The target is **at least one independently approved, required-check-passing source merge per elapsed hour in a declared active delivery window**, with applicable main-branch verification completed. Deployment and user-value proof remain separate. A source merge can count while deployment is explicitly held, but it cannot be reported as a deployed capability.

- Before the window starts, the captain records its start, planned end, eligible queue, owners and capacity in the existing ledger. Count the train's wall-clock hours once, not once per agent.
- Include CI, review, repair, access and service waits inside that window. Do not remove slow intervals afterward to improve the rate. Report full PR lead time separately so work predating the window remains visible.
- Count a merge only when main verification completes inside the window; record earlier merges awaiting verification as pending. Preserve both timestamps. A completion in a later window belongs to that later window.
- Closed-unmerged, superseded, empty reservation and duplicate PRs are not deliveries. Count a replacement chain once for the accepted change. Report raw merge count separately when it differs.
- Separate documentation/process work, maintenance and product-capability work. Do not split useful changes artificially or count this plan's publication as a product release.
- Report the rate with its numerator, denominator, sample size and case mix. A complete recorded hour with zero verified completions is **0/hour** and stays in comparisons; pending or unavailable verification is listed separately and never counted as a completion. A missing or invalid window makes the rate unknown. Also show calendar throughput and backlog age; the active-window rate is not a 24-hour service promise.

Begin with small, already-scoped changes in the captain's current order: #623 first, then #609. Keep at most two delivery items active and integrate one at a time. Preserve existing findings, review allowances, claims and separate holds. A review wait does not automatically open another build lane.

## A one-hour planning budget

Use the following as a diagnostic budget for a small eligible change, not a deadline that overrides checks. Initial implementation or a material redesign may require its own estimate.

| Work | Initial budget | If it takes longer |
| --- | ---: | --- |
| Confirm scope, current head and dependencies | 5 min | Name the real prerequisite or return an unready item to its owner |
| Required checks | 15 min | Record actual runtime, failures and queue time; do not weaken or omit checks |
| Independent review | 15 min | Distinguish queueing, source analysis, unavailable service and missing publication |
| One combined correction, when needed | 10 min | Preserve repair limits; redesign or resize when the change no longer fits |
| Guarded integration and main verification | 10 min | Report merged-but-unverified until the real checks finish |
| Learning note and next item | 5 min | Keep the note short and link evidence already produced |

Checks and source inspection may overlap where the current protocol permits it, using the same pinned change. Approval and merge still need their required evidence. The budget does not grant another review attempt or permission to bypass a failed finding. Measure the actual critical path before changing capacity or buying faster hardware.

## Turn a confirmed failure into the right protection

Add one short prevention decision to the existing finding or retro record: **failure/reproduction → root cause → chosen protection → evidence/owner**. Reuse that record in the merge note; no extra form or approval meeting is needed.

| Kind of problem | First choice |
| --- | --- |
| Runtime behavior, state or data parsing | Fix shared behavior and add a focused regression test |
| Repeated source pattern an existing tool detects | Configure or extend that tool within the authorized scope |
| Concrete source pattern without adequate coverage | Consider a custom lint rule in the repository's existing framework |
| Misunderstood product intent or poor design | Improve the spec, acceptance scenario, abstraction or guidance |
| One-off observation with no reliable general check | Retain evidence and the limitation; do not force a permanent rule |

Custom lint is useful when static analysis can detect the failure reliably, offer an actionable explanation and avoid duplicating existing checks. A single serious incident can justify protection; frequency alone is not the criterion. Prefer syntax-aware rules to broad text matching. Add no dependency or general rule engine until a selected case needs it.

The reproduced file-classification findings select **regression tests**: require both rename endpoints to qualify for a docs exemption; separate documentation eligibility from generated-file classification; exercise punctuation with real Git fixtures and the relevant parser/data-format fix. They do not justify a blanket ban on legitimate filenames or SVGs. Check existing coverage before adding another test.

For an actual custom-rule candidate:

1. Keep the incident and known-broken example, corrected example, benign cases and near misses together.
2. Show that the rule catches the broken case and accepts the controls, and that removing its detection lets the broken case escape.
3. Trial a new rule as report-only through the existing lint invocation. A crashed or skipped rule is an error/unknown observation, not evidence of clean code. Existing required protections and regression tests retain their normal status.
4. Use ordinary independent review for promotion. Cite observed precision, known-broken recall, scope, runtime and author effort; preserve #210's existing promotion requirements. A tiny fixture set alone does not establish field precision, and the author cannot promote its own policy.
5. Consolidate duplicate rules. Propose repair or retirement when a rule is noisy, obsolete or ineffective, preserving incident history and the authority needed for any mandatory control. Mandatory protection never expires automatically.

#227 is closed under the earlier process freeze. This plan neither reopens it nor activates its proposed gates. Selecting a regression test, reusing a tool or rejecting an unnecessary linter is a successful learning outcome.

## One short note per verified merge

The existing captain reads this note before selecting the next item; the per-merge record is not another merge prerequisite. Link the PR and merge SHA, reviewed head, checks and applicable main verification. Then answer:

1. **Did it work?** What accepted behavior or operator outcome was actually verified?
2. **Was it effective?** Which defect or delay was removed, and what remains unknown?
3. **Was there too much process?** Which step caught something useful; which duplicated effort or caused a false block?
4. **Did velocity improve?** Record eligible, queued, review-started, verdict, evidence-green, merged and main-verified times where known, plus repair rounds and operator minutes. Do not label an undifferentiated gap scheduler wait.
5. **Did quality suffer?** Record confirmed catches, rejected findings and escaped defects; check the seven-day post-merge period. Until it matures, quality follow-up remains pending.

Count unavailable, rate-limited, timed-out and incomplete reviews separately from code defects. Unknown cost, time or outcome stays unknown. Record at most one next experiment per learning note and leave it behind current priorities unless it removes a concrete blocker.

## Pilot decision and evidence

Review the first **four verified deliveries** for feasibility and obvious waste, then revisit their quality after each has seven days of follow-up. Reaching one merge/hour once is not sustained throughput or statistical proof. Record whether the rate required unusual case selection or preparation outside the window. Unresolved harmful defects prevent a quality-success claim; no observed escapes in four cases does not prove equivalence.

Keep or simplify a change when confirmed benefit justifies its runtime, maintenance and operator burden. If the target is missed, identify the dominant measured delay and choose one bounded improvement. Do not react by adding compulsory reviewers, new gates, more work in progress or hardware without evidence.

Evidence already available:
- [Historical CodeRabbit audit](https://github.com/The-AIE/the-gibson/pull/545#issuecomment-6563817312): 278 PRs; early adoption did not show an aggregate slowdown, but quality and causal productivity effects remain unproven.
- [Offline replacement-reviewer trial](https://github.com/The-AIE/the-gibson/pull/545#issuecomment-6563622394): three known targets recovered on a selected four-snapshot corpus; optional specialists added no unique confirmed defect. This is not four live pilot deliveries.
- [Custom-lint learning proposal](https://github.com/The-AIE/the-gibson/issues/210#issuecomment-6563857118): existing home, selection criteria and report-only trial.

This check-in records the plan and target. It makes no claim that the pilot rate has been achieved, a custom linter has shipped, review machinery has changed, or deployment/migration holds have been released.
