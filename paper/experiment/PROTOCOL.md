# AB-219 protocol — harness+LLM vs raw LLM (gibson#219)

Registered 2026-08-15, before any arm executed. Owner directives: run continuously
until done; **ConferenceOS and Gibson development always preempt it** (background
priority); task set picked to represent common coding needs.

## Enrollment

Seed set (n=6, spanning common classes — styling fix, file upload, data-model
feature, hardening, API validation, refactor) randomized with seed **219**
(`assignments.json`). Prospective rule: each new eligible Tier A/B product issue
(not meta/harness, not Tier C) is enrolled on arrival until **n=12**; late
assignments balance arms to 6/6 (stratified, same seed sequence).

## Arms

- **raw**: one implementer session (same platform mix as harness arm's
  implementers), given only the issue text. No spec gate, no cross-vendor review,
  no bot identity, no claim protocol. Work lands on `ab219/raw/<issue>` branches —
  **never merged to a real branch, no PR opened**. Done = implementer's own
  definition + green local CI-equivalent (`prisma generate`, `typecheck:ci`,
  `npm test` where applicable).
- **harness**: the normal full pipeline (spec gate → identity-bearing lane →
  sensors → cross-vendor review → evidence gate → captain). Merges land for real.

## Blinding

At judging time, every task's final diff is exported as a unified patch with
normalized metadata (no author, branch, PR body, or commit messages) under a
random code name; the code→arm mapping lives only in `sealed-mapping.json`,
which the judge never receives. Judge = a platform that implemented **neither**
arm of that task (Devin or Codex; never Claude, which coordinates). Judge
receives: issue text + blinded patch; returns: defect list with severities.

## Metrics (primary first)

1. Defects surviving to done, per blind judging.
2. Rework rounds consumed (harness arm) / self-corrections (raw arm).
3. Inference cost per completed task (logged per lane).
4. Wall-clock agent time.
5. For harness-arm merges: post-merge fixes within 14 days.

## Priority rule (owner-set)

The daily advance step runs **only when** fewer than 2 non-experiment
implementation lanes are active across COS/Gibson — development work always
preempts. Skipped days are normal and logged as no-ops.

## Pre-registered prediction (addendum to PREREGISTRATION.md)

**H7:** the harness arm shows fewer surviving defects per task at higher
per-task cost, and lower cost per *defect-free* completion on Tier B tasks.
Null or reversed results are reported as such.

## State

Progress is tracked as comments on gibson#219 (stigmergic — any session can
resume it). Raw-arm branches are deleted after judging; patches retained under
`paper/experiment/diffs/`.
