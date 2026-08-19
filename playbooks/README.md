---
title: "Playbooks"
nav_exclude: true
---

# playbooks/ — the portable skill format


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

Conditionally mandatory dispatch prompts when a role/job is active — not a
second contract. Binding commit/PR/merge rules live only in
[AGENTS.md](../AGENTS.md). If no role is named, the resolved role is builder
and [builder.md](builder.md) is the session-start load. One file per role
(explanation: [docs/03](../docs/03-roles.md)) plus loop, adopt, and
deploy-audit helpers. A playbook = YAML frontmatter
(role, inputs, outputs, gates, forbidden as **routing mirrors** of AGENTS.md) +
the full dispatch prompt + a **How to use this** section with copy-paste
examples. Frontmatter must not introduce obligations absent from AGENTS.md.

Same file → every runtime ([docs/10](../docs/10-vendor-adapters.md)): vendor
adapter, prompt file, or stdin as that CLI actually supports — Claude skill
wrapper, Codex (`codex exec --full-auto` with a prompt path/body per its
adapter), Grok via **`--prompt-file`** (never `grok -p "$(cat …)"` for
YAML-frontmatter playbooks; L-007), Hermes cron. One source, multiple runtimes.
Anything expressible only as a vendor skill is doctrine-debt.

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
| [token-efficiency.md](token-efficiency.md) | Route / bound / measure AI spend without cutting quality | 15, 20, 11, 05, 06, 16 |
| [red-team/](red-team/) | Scheduled adversarial audit of a target app | 03, 08 |
| [recipes/](recipes/) | Validation-only Goose recipe mirrors; live runs gated on #28 + #35 | 10, [GOOSE-STRATEGY](../docs/GOOSE-STRATEGY.md), [adapters/goose](../adapters/goose/), [recipes/README](recipes/README.md) |

## How to use any playbook

Playbooks start with YAML frontmatter (`---`). Do **not** inline that body into
Grok as `grok -p "$(cat …)"` — the dash-prefixed frontmatter is misparsed as a
flag (L-007). Prefer the vendor adapter or a prompt file; for Grok use
`--prompt-file`. Put issue/PR and target-repo context in the same file (or a
short brief that loads the playbook).

```bash
# Grok (portable, L-007-safe) — replace ROLE / issue / paths
GIBSON=~/Code/the-gibson
REPO=~/Code/acme-app
ROLE=builder   # e.g. builder, reviewer, token-efficiency
PROMPT_FILE="$(mktemp -t gibson-dispatch.XXXXXX.md)"
{
  cat "$GIBSON/playbooks/${ROLE}.md"
  printf '\n\n## Dispatch context\n\n'
  printf 'Issue/PR: #149 / #150\n'
  printf 'Target repo: %s\n' "$REPO"
} > "$PROMPT_FILE"
grok --prompt-file "$PROMPT_FILE" --cwd "$REPO" --permission-mode plan
rm -f "$PROMPT_FILE"

# Codex (adapter may accept a body string; prefer file/path when available)
# codex exec --full-auto "$(cat "$GIBSON/playbooks/${ROLE}.md")"   # see adapters/codex

# Claude: load via skill wrapper or paste path — see adapters/claude-code
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
