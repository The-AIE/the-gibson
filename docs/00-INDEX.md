---
title: Reading Order
nav_order: 8
---

# Documentation index — reading order by audience

If you only open one file, use the row that matches you. Glossary:
[00-glossary.md](00-glossary.md).

## 🙂 Non-technical owner (Operator)

1. [VIBECODING.md](../VIBECODING.md) — the only page you need  
2. Optionally: decision-card shape in [playbooks/templates/](../playbooks/templates/)  
3. Stop. You do not need the rest of this repo.

## 🔧 Fleet operator (Mark / Engineer tier)

1. [QUICKSTART.md](../QUICKSTART.md) — clone → first adopted repo  
2. [GUIDE.md](../GUIDE.md) — day-to-day: briefs, gates, loop, adopt  
3. [AGENTS.md](../AGENTS.md) — the contract agents load  
4. [docs/14-human-gates.md](14-human-gates.md) — closed list of stops  
5. [docs/15-model-economics.md](15-model-economics.md) — who runs what  
6. [docs/16-nontechnical-operation.md](16-nontechnical-operation.md) — how to talk to Operators  
7. [docs/13-adoption.md](13-adoption.md) + [playbooks/adopt.md](../playbooks/adopt.md)  
8. [scripts/README.md](../scripts/README.md) + [ci/README.md](../ci/README.md)

## 🍴 Fork owner

1. [docs/18-fork-and-upstream.md](18-fork-and-upstream.md)  
2. [local/README.md](../local/README.md)  
3. [scripts/upstream-sync.sh](../scripts/upstream-sync.sh) (`--help`)  
4. [CHANGELOG.md](../CHANGELOG.md)  
5. Then fleet-operator path above

## 🤖 Agent (any runtime)

1. [AGENTS.md](../AGENTS.md)  
2. `local/AGENTS.local.md` if present  
3. Target repo `AGENTS.md`  
4. [memory/LESSONS.md](../memory/LESSONS.md) (tag-filter)  
5. Role playbook under [playbooks/](../playbooks/)  
6. Stage detail only as needed from the map below

## 📚 Doctrine map (full set)

| Order | Doc | One-line job |
|---|---|---|
| 01 | [principles](01-principles.md) | Why the rules exist |
| 02 | [sdlc-pipeline](02-sdlc-pipeline.md) | Ten stages, entry/exit/gate |
| 03 | [roles](03-roles.md) | Nine contracts |
| 04 | [plan-to-issues](04-plan-to-issues.md) | Decomposition |
| 05 | [concurrency](05-concurrency.md) | Worktrees, claims, hot files |
| 06 | [quality-gates](06-quality-gates.md) | Green gate, tiers, lenses |
| 07 | [uiux-evaluation](07-uiux-evaluation.md) | Playwright vs preview |
| 08 | [security](08-security.md) | Eight layers |
| 09 | [memory](09-memory-and-self-improvement.md) | Lessons + ratchet |
| 10 | [vendor-adapters](10-vendor-adapters.md) | Runtime matrix |
| 11 | [solo-loop](11-solo-loop.md) | One agent continuously |
| 12 | [vercel](12-vercel.md) | Deploy doctrine |
| 13 | [adoption](13-adoption.md) | Install on a repo |
| 14 | [human-gates](14-human-gates.md) | Only reasons to stop |
| 15 | [model-economics](15-model-economics.md) | G/S/F routing |
| 16 | [nontechnical-op](16-nontechnical-operation.md) | Operator mode |
| 17 | [deploy-opt](17-deployment-optimization.md) | Inspect/optimize |
| 18 | [fork-upstream](18-fork-and-upstream.md) | Fork without pain |
| 19 | [product-mcp](19-product-and-mcp.md) | Foreman / CodeWright |
| 20 | [multi-model](20-multi-model-orchestration.md) | Coordinator pattern |

## Worked examples & ops

| Need | Where |
|---|---|
| PLAN → issues sample | [examples/04-plan-to-issues-sample.md](examples/04-plan-to-issues-sample.md) |
| UX eval sample | [examples/07-ux-eval-sample.md](examples/07-ux-eval-sample.md) |
| AuthZ matrix sample | [examples/08-authz-matrix-sample.md](examples/08-authz-matrix-sample.md) |
| Troubleshooting | [troubleshooting/](troubleshooting/) |
| Doc build queue | [DOC-BACKLOG.md](DOC-BACKLOG.md) |
| FAQ | [../FAQ.md](../FAQ.md) |
