---
title: Self-learning loops
nav_order: 28
---

# Self-learning loops — a lesson only sticks if it is executable

Epic: [#210](https://github.com/The-AIE/the-gibson/issues/210). Owner
hypothesis (Mark, 2026-08-15): the fleet repeats mistakes because lessons live
as prose. Confirmed by evidence the day it was raised: a CI lane red for its
entire life with nobody noticing (conference-os#1336), an org transfer that
silently broke three independent consumers of one fact, review rounds burned
twice on unsigned commits after the fix already existed in a sibling repo,
and two knowledge stores (an auditor's premise and an agent's memory) holding
the same wrong fact while the machine config held the right one.

## The artifact ladder

Every retro, incident, or repeated failure must produce the **highest
feasible tier** — prose-only lessons are tracked as debt:

| Tier | Artifact | Property |
| --- | --- | --- |
| 1 | Executable check (CI sensor, commit hook, lint rule, retired-fact rule) | Unskippable, agent-agnostic |
| 2 | Doctrine rule + compliance auditor script (measure first, promote to blocking after baseline) | Auditable |
| 3 | Repo memory (`memory/`, `MEMORY.md`) | Cross-agent readable |
| 4 | Agent-local memory (Claude/Devin session memory) | **Never** the only home of a lesson that affects other agents |

## The standing loops

1. **Sensor health (daily, live)** — `scripts/sensor-health.mjs` via
   `.github/workflows/sensor-health.yml`. A lane that has never been green is
   **blind, not passing**; blindness becomes visible within a day. Deployed to
   the-gibson, conference-os, chatterbuilt; each copy is self-contained on the
   repo's own `GITHUB_TOKEN`.
2. **Merge quality (weekly)** — conference-os `scripts/audit-merges.mjs`
   with `reviewPath` classification; feeds the outcome ledger.
3. **Retro-to-artifact** — every review round past the tier cap (#205) and
   every CI failure class seen twice gets a retro whose output is a Tier 1/2
   artifact PR.
4. **Cross-repo propagation** — when a countermeasure lands in one repo, ask
   in the same PR whether the sibling repos share the exposure (#204 is this
   loop running by hand, a week late).
5. **Process audit (monthly)** — the 2026-08-14 Devin audit pattern: sample
   merges, classify review paths, find blind sensors and doc/config drift.
   Cross-vendor: a different platform reviews the auditor's findings.
6. **Knowledge drift** — corrected wrong beliefs become retired-fact rules
   (conference-os `scripts/check-doc-facts.mjs` is the house pattern; port
   pending here).

## The spec gate (pre-work)

Fleet doctrine 2026-08-10 already says top-tier scoping is policy; #210 makes
it enforceable: a versioned spec rubric (problem, testable acceptance
criteria, edge cases, overlap claim, test plan with exact verification
commands, rollback, tier); a Fable/Opus-class adversarial review of Tier B/C
specs **before** an implementer sees them; briefs generated only from gated
specs. Record spec-gate scores and correlate with review rounds and
post-merge fixes — if the gate doesn't reduce rework, fix or drop the gate.

## Invariants

No existing gate weakens. New checks are advisory first and promote to
blocking only after baseline data. Human owner gates (money, consent,
schema, production) unchanged.
