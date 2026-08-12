---
title: "Roadmap"
nav_exclude: true
---

# ROADMAP

The Gibson dogfoods itself: each phase ships via its own pipeline, and phase
boundaries are working demos, not doc milestones.

## Substrate first — conventions before features (2026-08-12, #190)

Before the remaining phases take new feature work, the codebase itself becomes
the foundation for success: conventions written down, sensor-enforced, and
retrofitted. Rationale: the 2026-08-12 three-lens review found every tier's
flagship file already embodies the right rule (`gibson-gate.yml`, `run-all.sh`,
`formal-review.sh`) while the rest of that tier drifts below it — and lessons
marked *fixed* in target repos (L-055, L-056) were never applied to the
artifacts this repo ships. Features built on that substrate inherit its drift.

- **[docs/CONVENTIONS.md](docs/CONVENTIONS.md)** is the contract: shell, `.mjs`,
  Actions/templates, secrets, gate/control-plane, doc-system, lesson ledger,
  vendoring. Every rule names its enforcement; every retrofit batch lands its
  sensor in the same PR, so fixes can't regress.
- **Order:** Batch D first (control-plane protected paths + secret handling —
  live exposure, tiny diffs), then A (CI hardening: pins, permissions,
  concurrency, visible skips), B (script conventions), C (doc sensors),
  E (vendoring hygiene). Judgment-tier items (kill-switch canonical statement,
  phantom lesson IDs, waiver policy) stay owner-gated.
- **Meta-rule now in force:** a lesson is not `fixed` until Gibson's own shipped
  artifacts reflect it. Fixed-in-target-only is `fix-pending (issue #N)`, where
  the issue tracks the harness-side work.
- **Exit demo:** the self-gate runs the new sensors green on this repo, and a
  deliberately planted violation of each convention class fails CI.

## Phase 1 — Doctrine (this commit)
Design docs 01–15, operator guide, memory seeds, templates, specs. ✅

## Phase 2 — Enforcement minimum
- scripts: `claim.sh`, `gate.sh`/`gate-baseline.sh`, `preview-url.sh`, `loop.sh`
- ci: `gibson-gate.yml` live on one sandbox repo; security layers 1–3 hard-fail
- playbooks: `builder`, `reviewer`, `loop-step` (DOC-BACKLOG P0)
- Mission Control patch: reviewer-absent → **block** (L-005); dispatched tasks run
  the claim protocol (docs/05 seam)
- **Demo:** one Tier A issue flows end-to-end on the sandbox, zero human touches.


## Dogfood status (issue #96)

- **Prep (this harness):** `scripts/dogfood-prep.sh` + `playbooks/dogfood-overnight.md` +
  `memory/dogfood/` evidence home — preflight and launch contract, offline sensors green.
- **Run (operator host):** overnight `loop.sh` still needs a machine with a runner CLI
  and Mark's confirm; not blocked on more code in this repo.
- **Parked (do not include in dogfood backlog):** live Goose path #28 / #33 / #36 and
  Mark-gated publish — operator deferred testing. Offline Goose enforce/session already
  landed (#35 / #134).

## Phase 3 — First real adoption
- Adopt one production repo (candidate: chatterbuilt — small, Vercel, active)
- Playwright ux-eval job vs. preview deployments; authz matrix + ZAP baseline
- Solo loop overnight on Grok against its backlog, digest via Hermes
- **Demo:** morning digest shows merged PRs Mark never touched + a queued Tier C gate.

## Phase 4 — The ratchet runs itself
- `retro.yml` weekly sweep + historian playbook; lessons → harness PRs measured
- Cost telemetry: cost-per-merged-PR per pool on the digest
- De-escalation review #1 (docs/15)
- **Demo:** a harness-improvement PR authored by an agent, triggered by a lesson,
  merged through the pipeline.

## Phase 5 — Scale-out
- Adopt ConferenceOS (its cos-* skills become thin wrappers over playbooks) and
  remaining portfolio repos
- Adapter READMEs tested on the Mac Mini fleet; pi adapter experiment
- Quarterly downward stress-test of controls; vector-memory decision revisit (D-001)

**Adoption is a ladder, not a switch (D-006).** "Adopt" above means rung 2 —
unattended loop. Rung 1 (target `AGENTS.md` + `ci/gibson-gate.yml`, coordinator
still human-driven) is available to any repo at any phase and does not wait on
Phase 4. ConferenceOS is on rung 1 as of 2026-08-01; it climbs to rung 2 only
once the Phase 4 ratchet closes on chatterbuilt.

## AQ externalization (from conference-os #694, 2026-07-30)

Development-process machinery leaves product repos; the harness owns it
portably. Migrated here from conference-os (originals closed with pointers):

- **Worker return evidence** (was #697/#702): coordinator derives Git/GitHub
  facts; a worker's PASS is never proof. Portable evidence collector.
- **Harness write-back + refactor hotspots** (was #696): scheduled runs report
  hotspots and reconcile state; they do not manufacture refactors.
- **Fleet control plane** (was #699): issue dispatch, exact-SHA review binding,
  reconciliation — GitHub-native, repo-agnostic.

- **Merge-queue controls** (was conference-os #774/#847): audit-derived
  enforceable controls; serial integration queue (one head + Preview READY
  before next). Control-plane hardening, repo-agnostic.

Boundary rule proven in production 2026-07-29/30: repos keep only the thin
ENFORCEMENT layer (CI gates with teeth: build/tests, schema guards, DCO,
secrets, review-evidence until per-actor identity); all orchestration and
prescription lives here. See docs/20-multi-model-orchestration.md.
