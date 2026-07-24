# 04 — Plan → Issues (Decomposition Protocol)

The gap this closes: ConferenceOS normalizes *one committed ask at a time*
(`cos-feature-request`) and keeps 80KB backlog docs as human-read design references —
nothing turns a plan into a batch of well-scoped issues. The `decomposer` role does.

## Invariants

1. **GitHub Issues are the live work queue.** Plans and backlog docs are references;
   if it isn't an issue, no agent will build it.
2. **One issue = one mergeable unit.** A builder should finish it in one session
   (≤ ~1 day of agent work, ≤ ~150 lines / 6 files preferred — above that, split).
   Bounded workers are also the cost lesson: one issue, exact file list, short
   output contract.
3. **Every issue carries its sprint contract.** Testable done-criteria written
   *before* implementation; the evaluator and test-engineer grade against them.
4. **Dedup before create.** Search open+closed issues and the shipped code. The
   plan's item may already exist or already be live.
5. **Dependencies are explicit.** `Blocked by #N` in the body; the queue only
   dispatches unblocked issues.

## Issue template

```markdown
## Context
<one paragraph: why, linked to PLAN.md section>

## Sprint contract (acceptance criteria)
- [ ] AC1 — <testable statement, phrased so a sensor can verify it>
- [ ] AC2 — ...
(UI work: each user flow is a criterion the ux-evaluator will drive via Playwright)

## Affected area
<dirs/files expected — this becomes the builder's scope claim>

## Out of scope
<explicit exclusions, prevents scope creep>

## Dependencies
Blocked by #N / none

## Tier
A (routine) | B (elevated) | C (money/auth/PII/security/schema)
```

## Labels

Reuse the target repo's existing taxonomy; The Gibson requires only:
`gibson`, `tier-a|b|c`, area labels, `P0|P1|P2`, and the coordination labels
`agent-claimed` / `blocked`. Never invent parallel taxonomies.

## Decomposition procedure

1. Read `PLAN.md`, the target `AGENTS.md`, and `memory/LESSONS.md` (past
   decomposition lessons: units that failed twice were usually cut wrong).
2. Draft the issue set as a dependency DAG; verify each unit is independently
   mergeable and demo-able.
3. Dedup sweep (`gh issue list --search`, code search).
4. File issues; record the DAG order in a tracking issue ("epic") that links all
   children and mirrors PLAN.md's deliverables.
5. **Gate:** run the decomposition lint (every issue has contract / area / tier /
   dependencies) and have a second agent spot-check for overlap and for units too
   large. Then the queue is open.

## Worked example

Full PLAN.md → epic → four issues (schema serialized, contracts, labels):  
[examples/04-plan-to-issues-sample.md](examples/04-plan-to-issues-sample.md)  
Lint fixture: `examples/fixtures/04-issues.json` + `scripts/decompose-lint.mjs`.

## Sizing heuristics (lessons encoded)

- If the contract needs >10 criteria, it's two issues.
- If two issues name the same hot file (schema, package.json), serialize them via
  `Blocked by`, don't parallelize.
- Schema changes are their own issues, never riders on feature issues
  (ConferenceOS #442: schema-edit-without-migration blocked ~20 consecutive deploys).
- Anything Tier C gets decomposed finer, not coarser — small diffs make adversarial
  review tractable.
