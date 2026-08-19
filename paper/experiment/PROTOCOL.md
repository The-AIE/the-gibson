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

## Amendment D-1 (2026-08-19, revised same day under cross-vendor review) — governs where it conflicts with the above

Cause and full accounting: `DEVIATIONS.md`. In short, live-backlog enrollment and the
preempt rule drew on the same queue, production always won, and five of six seed tasks
were merged by ordinary development before any arm ran. A first draft of this amendment
was FAILED by an independent Codex review on 2026-08-19; the revisions it forced are
logged in `DEVIATIONS.md` ("Revisions under cross-vendor review").

### Unit of analysis

A task is an already-closed issue plus a **base commit** — the first parent of the merge
commit of the PR that closed it. Both arms implement the issue text against that base.
`assignments.json` v2 carries the resolved `fixing_pr`, `merge_commit`, and `base_commit`
for all twelve tasks. **Each task is replayed exactly once, in its assigned arm** —
twelve runs total, six raw and six harness, a between-task randomized comparison exactly
as registered; there is no crossover. The clarification this amendment makes is that the
harness measurements for `cos#1220` and `cos#1313` come from **fresh harness replays**,
not from their historical pipeline traversals: that historical PR data (review rounds)
is reported as **supplementary observational data only**, never mixed into the replay
measurements, and its missing cost/wall-clock figures are reported as missing, not
estimated.

### Eligibility (clarified)

Excluded: issues carrying any `owner-gate-*` label, and any task whose replay would
require touching real external services, real user data, or live credentials. Issues
whose fixes *touch* schema, auth code paths, or PII handling are **eligible**: in replay,
neither arm's output is ever merged, deployed, or applied to any database, so the
blast-radius rationale behind the registered "no Tier C" rule does not arise. This is a
change in wording, not in the enrolled set — the registered v1 seed itself enrolled
schema-adjacent tasks (`cos#1221`, `cos#1313`) on the same logic, and the discrepancy
between v1's stated exclusion and its actual seed is now on the record rather than
papered over.

### Leakage control (mandatory, fail-closed)

Every replayed issue's real fix exists later in the same repository's history, and the
implementer runs on a machine where the canonical checkout and GitHub access exist.
The control has three layers; a run failing any one of them is **void and re-run**:

1. **Truncated tree, proven clean by total census.** Always a FRESH scratch directory
(`mktemp -d`), never reused. The whole block runs under `set -euo pipefail` — any
failing command aborts the run; nothing proceeds on a warning:

```bash
set -euo pipefail
SCRATCH=$(mktemp -d)
git init -q "$SCRATCH"
git -C "$SCRATCH" remote add origin file:///Users/mrhinkle/Code/conference-os
git -C "$SCRATCH" fetch --depth 1 --no-tags origin <base_commit>
git -C "$SCRATCH" checkout -q FETCH_HEAD
git -C "$SCRATCH" remote remove origin
# assertions — every one is fail-closed
test "$(git -C "$SCRATCH" rev-list --count --all)" = 1
test "$(git -C "$SCRATCH" remote | wc -l | tr -d ' ')" = 0
# TOTAL object census: the store must contain exactly the objects reachable from
# HEAD (the base commit and its tree closure) — nothing else. This is total, not
# sampled: ANY unreachable commit, tree, or blob fails the diff.
diff <(git -C "$SCRATCH" cat-file --batch-all-objects --batch-check='%(objectname)' | sort) \
     <(git -C "$SCRATCH" rev-list --objects HEAD | awk '{print $1}' | sort -u)
```

Verified 2026-08-19 on git 2.50.1: a depth-1 fetch of a real base commit passes the
census (3,125 objects, store == HEAD closure, zero unreachable), and an adversarial
check — writing one later-history object into the scratch store with `hash-object -w`
— makes the census fail, as required.

2. **Blind brief.** The implementer's brief contains the issue text and the scratch path
only — never the canonical repo path, the issue URL, or the PR number.

3. **Transcript audit.** The truncated tree prevents *accidental* leakage; it is not
isolation — the implementer could still read the canonical checkout or GitHub. So after
every run, grep the full transcript/log for: the canonical repo path, `github.com`,
`gh ` invocations, `git fetch`/`git remote add`, the issue number outside the brief, and
the fixing PR number. Any hit ⇒ the run is void and re-run. This is an audit for a
detectable act, not a prevention — the residual risk that an implementer consulted the
fix undetectably is acknowledged in the paper's limitations.

### Arms (amended)

- **raw**: one implementer session, blind brief only, no spec gate, no cross-vendor
  review, no bot identity, no claim. All work stays in the scratch clone; **nothing is
  ever pushed anywhere** — the deliverable is an exported patch. Done = implementer's
  own definition + `npx prisma generate && npm run typecheck:ci` green **+ `npm test`
  where applicable** (the registered raw-arm gate, unchanged).
- **harness**: the normal full pipeline, run against the frozen base rather than `main`.
  Its output is measured, then discarded — it is **not** merged, because the real fix
  already shipped.

### Priority rule (amended)

The preempt rule now binds the **harness arm only**, which consumes fleet review
capacity: a harness replay starts only when fewer than 2 non-experiment implementation
lanes are active. **Raw-arm replays are exempt** — one implementer session, no review,
no lane. Owner intent is preserved: production never queues behind the experiment.

### Metrics (amended)

Registered metrics 1–4 apply to the replay runs, where all four are captured per run.
Registered metric 5 (post-merge fixes within 14 days) is **dropped**, not redefined:
replayed output is never merged, so there is no production window to observe. The
supplementary historical data for `cos#1220`/`cos#1313` covers metric 2 only (rounds);
its metrics 3–4 are missing and reported as missing.

### Task selection for the seven continuation enrollments (limitation, stated)

The seven new tasks were selected by the coordinator from the eligible closed-issue pool
to span distinct common-need classes, **before any replay ran** — selection preceded all
arm outcomes. The selection itself is judgment-based and not algorithmically
reproducible; only the subsequent arm ASSIGNMENT (seed-219 shuffle) is exactly
reproducible. Both facts go in the paper: the assignment is verifiable, the selection is
a stated limitation.

### Limitation created by this amendment

Replay measures task difficulty under each arm, not whether a change would have shipped;
the leakage audit detects consultation of the real fix but cannot make it impossible.
Both are stated as limitations of the design in the paper. Neither is argued away.
