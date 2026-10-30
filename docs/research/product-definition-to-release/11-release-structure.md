---
title: "Organize outcomes as epics and deliveries as releases"
nav_exclude: true
---

> **Authority:** Non-normative sequencing proposal. Existing owner priorities, claims, independent review, cumulative allowances and live/merge holds remain binding. No milestone, parent relation, label or dispatch state is changed here.

# Release plan, work grouping and time estimates

**Planning estimate:** roughly **2–5 working weeks to the first useful product release**, **3–7 weeks to the integrated operator pilot**, and **4–8 weeks through the first measured improvement** if observation overlaps delivery. These ranges cover the bounded slices below, not every open issue or a general enterprise platform.

Estimates assume at most two active implementation lanes, an existing supported application/deployment stack, one small first workflow, timely independent review and available required operator decisions. A working day means elapsed delivery time under that capacity, not hours of uninterrupted model execution. External review, access, live-activation and owner holds can extend calendar time and are not silently counted as zero. No hardware purchase or increased model concurrency is assumed.

## Are we doing too much?

The recovery evidence and source research support reducing parallel work and building fewer overlapping platform primitives. There are already specification procedures, execution controls, a runtime manager and ecosystem alternatives. The missing product proof is one understandable, useful journey through them. More architecture, model panels or issue splits cannot substitute for that demonstration.

Keep **two deliveries active**, with a third lane only for a concrete blocker. Waiting for review does not automatically admit another build. Read-only research can proceed without becoming another implementation program. The current research branch adds a proposal, not a fourth delivery priority.

## Use both levels

| Level | Purpose | Example |
|---|---|---|
| Epic | Lasting user/operator outcome spanning several deliveries | A nontechnical owner can turn intent into dependable software |
| Release | A small coherent capability with explicit evidence and limits | One accepted product spec becomes useful, bounded work |
| Change/issue/PR | Bounded executable work inside a release | Connect one requirement/scenario to existing evidence |
| Worktree/claim | Isolation and ownership of the admitted change | One issue, declared scope, one branch under the existing rules |

An epic can span releases; a release may draw necessary work from several epics. Do not finish every architecture child before demonstrating value. OpenSpec proposals/tasks can feed this structure without becoming another independent backlog or release authority.

## Proposed release order

R1–R5 below are planning names, not created GitHub milestones or version/date commitments. This study has not inventoried all live release milestones. Preserve existing owner priority, including #400 and the recorded #409 → #393 → #394 → #408 sequence; do not silently reschedule those lanes through this table.

| Release checkpoint | Estimated elapsed delivery time | Useful result and smallest scope | Existing work and exit evidence |
|---|---|---|---|
| R1: Reliable delivery and review | **3–7 working days**, medium-low confidence | Finish the existing repair and functioning review handoff before expanding work | #609/#375 and #562, with relevant #210 protection work. Current-source checks/review; #562's existing three-real-PR, two-vendor timeliness acceptance under other-repository load; authorized post-main/live checks where applicable |
| R2: Description to accepted spec and useful scope | **3–5 working days after R1**, medium confidence | One owner can understand/correct a spec and see its first useful increment | #18/#165/#167; current planner/decomposer plus a pinned OpenSpec trial. Faithful requirements, explicit unknowns/deferrals, useful dependency order and a changed-requirement case |
| R3: First complete useful product release | **5–10 working days after R2**, low confidence until the real pilot is selected | Carry that same small capability through implementation and real-use proof | Existing #18/#165 evidence/execution seams; bounded #214/#549 onboarding work where needed. Actual user scenario, required assurance/review, source-to-deployment identity and recovery evidence |
| R4: One integrated operator journey | **5–10 working days after R3**, medium-low confidence | Project the same intent/work/evidence into existing Agent Kontrol surfaces | Existing manager APIs/task/decision/progress. Better owner task completion/comprehension, retry/head-change consistency and portable fallback; manager cannot override repo gates |
| R5: Measured improvement | **3–5 working days for the first change**, plus **1–2 weeks of observation** that can overlap R3/R4 | One observed design/process failure leads to a bounded, independently evaluated improvement | #210/#214 learning/advisory propagation. A later comparable outcome improves at acceptable cost; ineffective changes are revised or retired through current authority |

The delivery ranges sum to **19–37 working days**. The first complete product slice (through R3) is **11–22 working days**; the integrated pilot (through R4) is **16–32**. Add observation time if it cannot overlap, or if too few comparable deliveries occur. These are engineering planning judgments from the inspected current assets and remaining seams, not estimates validated by a throughput experiment. Re-estimate at the end of R1 and when R3's actual user workflow/assurance profile is selected.

**What makes the ranges grow:** R1 still needs real independent review and the relevant operator/live-activation decisions; R2 grows if two editable spec sources are maintained; R3 grows materially for new billing, complex tenancy, major data migration or regulated-data requirements; R4 grows if it becomes a codebase/deployment merger; R5 grows if it becomes a general telemetry platform. Those expansions need their own scope/estimate rather than being hidden in the first slice.

R1's two execution priorities remain the existing #609 repair/review lane and existing review-dispatch implementation. Reuse their current work and retained owners; do not start replacements. Claim-concurrency work is a supporting candidate only after owner/scope/allowance coordination. Diagnostic expiry or non-acquiring renewal alone cannot be called full automatic recovery. Preserve malformed reservations and existing overlap holds.

The owner-readable packet in [P1–P4](05-incremental-plan.md) is the first product experiment over existing assets. R2/R3 use it to test the complete description-to-release path. It does not delay recovery while a general product platform is built.

## Current work sorted into release buckets

The open PR inventory was refreshed on October 30: **16 open PRs**, including this research draft. The following groups preserve the earlier dispositions; a candidate bucket is not permission to resume an executor or consume a new correction round. The [machine-readable map](release-work-map.csv) contains one row per current PR, accountable captain and concrete next step.

| Bucket | Current work | Disposition |
|---|---|---|
| R1 active delivery | #609/#375 and existing #562 review-dispatch work | Finish the existing lanes; no replacement implementation. Obtain retained-executor acknowledgement before resuming a lane |
| R1 supporting backlog, only if it blocks the selected path | #564/#557, #582/#568 and routine #563 maintenance | #564 needs claim-state redesign; #582 follows the settled claim contract. Dependency maintenance waits unless it is a demonstrated blocker |
| R2 planning support | #615/#617, current #18/#165/#167 artifacts and the proposed OpenSpec trial | Deliver the release plan; next admit only the missing spec/handoff adapter for one pilot |
| R3 evidence candidates | #577/#572 and #578/#570 | Park until the selected pilot needs them; preserve existing fixes and repair metadata/registration together |
| R4 operator/recovery candidates | #579/#571, #580/#569 and #601/#600 | Park; prove the required behavior before activating recovery or promoting architecture prose |
| R5 optional measurement | #584/#583 | Park until a chosen evaluation question warrants the integration, credentials, operating cost and applicable approval |
| Independent decision holds | #534, #545 and #597/#598/#614 | Park policy decisions; treat the three docs PRs as one replacement chain with #614 the survivor, preserving its failed finding and cumulative allowance |

The parked candidates are **excluded from the initial release estimates unless the selected contract actually requires them**. Their presence in the backlog is not a reason to finish an entire subsystem before the release. Existing #400 priority and the #409 → #393 → #394 → #408 sequence continue to govern admission of that owner-prioritized work. Keep the current independent decisions separate from the documentation-only testing exception below.

## Release membership and issue selection

For the next selected release, record its user outcome, acceptance/negative cases, included/deferred requirements, genuinely blocking dependencies, existing issues/PRs, accountable owner and required evidence. Use one ordinary release/milestone association when that grouping is authorized. Keep epic parentage stable unless a concrete reviewed reorganization is accepted.

Use existing issue triage for priority, status, area, dependency and risk. Live scope/claim evidence determines whether two items can safely run in separate worktrees; a label alone cannot establish independence or ownership. Do not apply an automation-triggering readiness label merely to document a recommendation.

Park optional VCS migration, broad observability infrastructure, repository consolidation, another scheduler and compulsory multi-model operation until a selected release has a demonstrated need. Add the smallest required adapter to a useful slice instead of opening a parallel platform program.

## Measures and stop conditions

Track verified useful deliveries, time from eligible review to verdict with actual attempt phases where available, code/design repair rounds, no-verdict attempts, owner intervention and observed total cost. Count replacement ancestry once. Source merged, code tested, user behavior demonstrated and deployed release remain separate states.

Do not diagnose hardware saturation from elapsed time or permission failures. Compare observed queue, execution, tool failure and hold intervals before buying capacity. A new safeguard earns its cost when it detects a demonstrated harmful failure at acceptable false-block/maintenance burden while preserving applicable quality.

The next decision is the first real pilot/user and its assurance profile. This proposal supplies the release order; it does not mass-move issues, dispatch implementation, bypass an exhausted correction round or lift independent owner gates.

## Documentation handling for this plan

The owner explicitly instructed that further full test runs are unnecessary for these documentation updates and asked for release ordering and time estimates instead. This plan update therefore skips another aggregate test/proof cycle. Read back the published files and report any automatic CI separately; earlier-head test results do not certify a later documentation commit. This session instruction does not modify the repository's code/runtime gates or authorize a merge of held implementation PRs.
