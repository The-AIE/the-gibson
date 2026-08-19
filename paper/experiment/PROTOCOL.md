# AB-219 protocol — harness+LLM vs raw LLM (gibson#219)

> **AMENDED 2026-08-19 — deviation D-1 (see `DEVIATIONS.md`).** The registered text
> below is preserved unedited for the record. Where it conflicts with the
> **Amendment D-1** section at the end of this file, the amendment governs:
> the unit of analysis is now a frozen replay set, the preempt rule binds the
> harness arm only, and a shallow-clone leakage control is mandatory.

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

---

## Amendment D-1 (2026-08-19) — governs where it conflicts with the above

Cause and full accounting: `DEVIATIONS.md`. In short, live-backlog enrollment and the
preempt rule drew on the same queue, production always won, and five of six seed tasks
were merged by ordinary development before any arm ran.

### Unit of analysis

A task is an already-closed issue plus a **base commit** — the first parent of the merge
commit of the PR that closed it. Both arms implement the issue text against that base.
`assignments.json` v2 carries the resolved `fixing_pr`, `merge_commit`, and `base_commit`
for all twelve tasks.

### Leakage control (mandatory, load-bearing)

Every replayed issue's real fix exists later in the same repository's history. Each arm
runs against a **shallow clone truncated at the base commit**:

```bash
git init -q "$SCRATCH"
git -C "$SCRATCH" remote add origin file:///Users/mrhinkle/Code/conference-os
git -C "$SCRATCH" fetch --depth 1 --no-tags origin <base_commit>
git -C "$SCRATCH" checkout -q FETCH_HEAD
git -C "$SCRATCH" remote remove origin
```

Verified 2026-08-19 on git 2.50.1: leaves exactly one commit reachable
(`git rev-list --count --all` = 1) and later `main` commits absent from the object
store. Check it per run before handing the tree to an implementer:

```bash
test "$(git -C "$SCRATCH" rev-list --count --all)" = 1 || echo "LEAK: history not truncated"
```

A run whose transcript shows the implementer reaching any commit after `base_commit`
is **void and re-run** — never patched up after the fact.

### Arms (amended)

- **raw**: unchanged in substance — one implementer session, issue text only, no spec
  gate, no cross-vendor review, no bot identity, no claim. Work stays in the scratch
  clone; branches, if pushed at all, go to `ab219/raw/<issue>` and are never merged and
  never carry a PR. Done = implementer's own definition + `npx prisma generate &&
  npm run typecheck:ci` green.
- **harness**: the normal full pipeline, run against the frozen base rather than `main`.
  Its output is measured, then discarded — it is **not** merged, because the real fix
  already shipped.

### Priority rule (amended)

The preempt rule now binds the **harness arm only**, which consumes fleet review
capacity: a harness replay starts only when fewer than 2 non-experiment implementation
lanes are active. **Raw-arm replays are exempt** — one implementer session, no review,
no lane. Owner intent is preserved: production never queues behind the experiment.

### Metrics (amended)

Registered metrics 1–4 stand. Registered metric 5 (post-merge fixes within 14 days) is
**dropped**, not redefined: replayed harness output is never merged, so there is no
production window to observe. For the two harness tasks that did traverse the real
pipeline before this amendment (`cos#1220`, `cos#1313`), review rounds are reconstructable
from PR history; **wall-clock and inference cost for those two are recorded as missing
and are not estimated.**

### Limitation created by this amendment

Replay measures task difficulty under each arm, not whether a change would have shipped.
This is stated as a limitation of the design in the paper. It is not argued away.
