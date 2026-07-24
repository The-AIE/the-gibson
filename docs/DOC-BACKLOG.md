# Documentation Backlog — status

Design docs (01–19) are the spec and carry the *why*. This file tracks expansion
into runnable playbooks, scripts, CI, and operator docs.

**Style contract:** every rule cites its why; tables over prose walls; plain
language first; runnable beats descriptive. Never contradict docs 01–19 silently.

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

## Also delivered (usage docs)

- [QUICKSTART.md](../QUICKSTART.md) — clone → adopted  
- [GUIDE.md](../GUIDE.md) §7 — end-to-end fictional walkthrough  
- How-to sections on every playbook and `--help` Ask Contract on every script  

## Rules for remaining work

- Harness PRs still go through review by a different runtime when available (doc 09).
- Runnable > descriptive.
- 5d and 12 need human / production data — not inventable.
