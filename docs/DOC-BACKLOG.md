---
title: "Documentation Backlog"
nav_exclude: true
---

# Documentation Backlog — status


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

Design docs (01–19) are explanation and history — the *why* behind the contract
in AGENTS.md. This file tracks expansion into runnable playbooks, scripts, CI,
and operator docs.

**Style contract:** every rule cites its why; tables over prose walls; plain
language first; runnable beats descriptive. If an explanation here drifts from
AGENTS.md, reconcile it back to AGENTS.md. These docs are not a second spec
and must not be treated as do-not-contradict authority.

## P0 — needed before first fleet run

| # | Item | Status | Notes |
|---|---|---|---|
| 1 | Nine role playbooks | **done** | `playbooks/{planner,decomposer,builder,test-engineer,reviewer,ux-evaluator,security,release,historian}.md` |
| 2 | `playbooks/loop-step.md` | **done** | `{{hat}}` / `{{loop_state}}` |
| 3 | `playbooks/adopt.md` | **done** | checklist inline |
| 4 | scripts implementations | **done** | see `scripts/README.md` |
| 5 | ci workflows | **done** | security, ux-eval, schema-guard, retro (+ existing gibson-gate) |
| 5b | deploy-audit.sh + playbook | **done** | inspect scorecard seed |
| 5c | Decision-card + Operator templates | **done** | `playbooks/templates/` |
| 5d | VIBECODING real-reader test | **open** | Needs 2–3 non-technical humans; cannot close in isolation |
| 5e | upstream-sync.sh | **done** | override-shadow + Tier C flag |

## P1 — depth

| # | Item | Status |
|---|---|---|
| 6 | Per-doc worked examples (04, 07, 08) | **done** — `docs/examples/` |
| 7 | Troubleshooting guides | **done** — `docs/troubleshooting/` |
| 8 | `docs/00-glossary.md` | **done** |
| 9 | Adapter READMEs (4) | **done** — install steps written; machine-specific CLI versions not re-verified here |

## P2 — polish

| # | Item | Status |
|---|---|---|
| 9b | GitHub presentation (Mermaid, INDEX, links) | **done** (social preview image / About topics still manual on GitHub UI) |
| 10 | Architecture diagram in README | **done** |
| 11 | FAQ.md | **done** |
| 12 | Case study first adopted repo | **open** — needs real metrics after first production adoption |
| 13 | Screenshots throughout docs | **open** — real captures, not mockups: a decision card arriving in chat, a PR with gates green, a UX-eval report + screenshot gallery, the solo-loop journal, the MC dashboard. Capture during the Phase 2 end-to-end demo so every image is an artifact of a real run. Store in `docs/assets/`, alt text mandatory, embed in VIBECODING / EXAMPLES / QUICKSTART / GUIDE |
| 14 | Copy-paste prompts library | **open** — `docs/prompts.md` (nav title "Copy-Paste Prompts"): "say this to your agent" blocks for each common moment — start a plan, adopt a repo, claim an issue, request a review, run the solo loop, ask for a site audit. One fenced block per prompt, one when-to-use sentence above it; cross-link from QUICKSTART, GUIDE, and every playbook's How-to section |

## P3 — borrowed-pattern follow-ups (2026-08-27)

Doctrine landed for these; the enforcement/runnable half is still open. Each item
names the doc that owns the doctrine and the artifact tier it should land as
(doc 28's artifact ladder — sensor beats guide beats memory).

| # | Item | Doc | Status |
|---|---|---|---|
| 15 | Guarded state-transition guard (claims, loop-state, decision packages) | [29-guarded-state-transitions](29-guarded-state-transitions.md) | **open** — needs a transition-table format decision + a guard script; illustrative example in the doc is not a claim about current `scripts/claim.sh` behavior |
| 16 | PreToolUse-style lesson injection (Claude Code adapter first) | [09-memory-and-self-improvement](09-memory-and-self-improvement.md) | **open** — blocked on the *memory/LESSONS-INDEX.md* generator (§7.3 of [CONVENTIONS.md](CONVENTIONS.md)) landing first |
| 17 | Rate-limit-window field on `scripts/cost-ledger.sh` | [15-model-economics](15-model-economics.md) | **open** — extend only for runtimes that actually report window state; never invent one |
| 18 | Panel-summary aggregator (branches run / findings / verified-dropped count) | [27-lightweight-mcts-panel](27-lightweight-mcts-panel.md) | **open** — doctrine (union over consensus) is usable without it; this only makes panel coverage visible in one place |

## Also delivered (usage docs)

- [QUICKSTART.md](../QUICKSTART.md) — clone → adopted  
- [GUIDE.md](../GUIDE.md) §7 — end-to-end fictional walkthrough  
- How-to sections on every playbook and `--help` Ask Contract on every script  

## Rules for remaining work

- Harness PRs still go through review by a different runtime when available (doc 09).
- Runnable > descriptive.
- 5d and 12 need human / production data — not inventable.
