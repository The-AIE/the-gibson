---
title: "Roadmap"
nav_exclude: true
---

# ROADMAP

The Gibson dogfoods itself: each phase ships via its own pipeline, and phase
boundaries are working demos, not doc milestones.

## Phase 1 — Doctrine (this commit)
Design docs 01–15, operator guide, memory seeds, templates, specs. ✅

## Phase 2 — Enforcement minimum
- scripts: `claim.sh`, `gate.sh`/`gate-baseline.sh`, `preview-url.sh`, `loop.sh`
- ci: `gibson-gate.yml` live on one sandbox repo; security layers 1–3 hard-fail
- playbooks: `builder`, `reviewer`, `loop-step` (DOC-BACKLOG P0)
- Mission Control patch: reviewer-absent → **block** (L-005); dispatched tasks run
  the claim protocol (docs/05 seam)
- **Demo:** one Tier A issue flows end-to-end on the sandbox, zero human touches.

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
