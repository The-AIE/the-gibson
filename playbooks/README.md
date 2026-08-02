---
title: "Playbooks"
nav_exclude: true
---

# playbooks/ — the portable skill format

One file per role ([docs/03](../docs/03-roles.md)) plus loop, adopt, and deploy-audit
helpers. A playbook = YAML frontmatter (role, inputs, outputs, gates, forbidden) +
the full dispatch prompt + a **How to use this** section with copy-paste examples.

Same file → every runtime ([docs/10](../docs/10-vendor-adapters.md)): Claude skill
wrapper, Codex/Grok inline (`codex exec --full-auto "$(cat …)"` /
`grok -p "$(cat …)"`), Hermes cron. One source, five runtimes. Anything expressible
only as a vendor skill is doctrine-debt.

## Inventory

| File | Role / job | Source docs |
|---|---|---|
| [planner.md](planner.md) | Plan from brief → PLAN.md | 02§0, 03, 16 |
| [decomposer.md](decomposer.md) | PLAN.md → issues + contracts | 02§1, 03, 04 |
| [builder.md](builder.md) | Issue → green PR | 02§2, 03, 05, 06 |
| [test-engineer.md](test-engineer.md) | Contract → executable checks | 02§3, 03, 06 |
| [reviewer.md](reviewer.md) | Multi-lens verdict | 02§4, 03, 06 |
| [ux-evaluator.md](ux-evaluator.md) | Playwright vs. preview | 02§5, 03, 07 |
| [security.md](security.md) | Eight-layer security | 02§6, 03, 08 |
| [release.md](release.md) | Merge, deploy, cleanup | 02§7–8, 03, 12, 20 |
| [delivery-control.md](delivery-control.md) | Production write-path audit/harden/promote | 20, 12, 14 |
| [historian.md](historian.md) | Lessons + ratchet | 02§9, 03, 09 |
| [loop-step.md](loop-step.md) | Solo-loop one-hat step (`{{hat}}`, `{{loop_state}}`) | 11 |
| [adopt.md](adopt.md) | Install Gibson on a target repo | 13, 17, 20 |
| [deploy-audit.md](deploy-audit.md) | Doc 17 inspect scorecard | 17 |
| [red-team/](red-team/) | Scheduled adversarial audit of a target app | 03, 08 |

## How to use any playbook

```bash
# Generic pattern
RUNTIME=grok   # or: claude -p / codex exec --full-auto
$RUNTIME "$(cat playbooks/<role>.md)

# Arguments the prompt expects:
Issue/PR: …
Target repo: …
"
```

**Local override:** `local/playbooks/<same-filename>.md` replaces the core file at
dispatch time ([docs/18](../docs/18-fork-and-upstream.md)).

**Templates for Operator messaging:** [templates/](templates/) (decision cards,
status, intake, incident — docs/16).

## Authoring rules

- Frontmatter must list inputs, outputs, gates, forbidden.
- Every rule in the prompt cites its why (doc link or incident).
- **How to use this** with at least one copy-paste invocation is mandatory.
- Never put vendor-only rules here — put them in `adapters/<vendor>/`.
