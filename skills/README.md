# The Gibson skill layer

The one-command experience: `/gibson <repo> [goal]`. Nested Claude Code skills
that wrap the Gibson's existing scripts, playbooks, and doctrine — they add an
entry point, not a second implementation.

| Skill | Stage | Wraps |
|---|---|---|
| `gibson` | orchestrator | the pipeline below, in order |
| `gibson-audit` | 1 — know the repo | posture-probe.sh, guardrail checklist |
| `gibson-resources` | 2 — inventory the fleet | runner CLIs, devin-supervisor.sh, gh auth |
| `gibson-setup` | 3 — install the teeth | templates/target-repo/, docs/22 wiring |
| `gibson-direct` | 4 — product direction | playbooks/planner.md, decomposer.md |
| `gibson-run` | 5 — the loop | scripts/loop.sh, docs/11, docs/15 routing |

## Install (personal, all sessions)

```bash
mkdir -p ~/.claude/skills
for s in gibson gibson-audit gibson-resources gibson-setup gibson-run gibson-direct; do
  ln -sfn ~/Code/the-gibson/skills/$s ~/.claude/skills/$s
done
```

Symlinks keep the Gibson clone the single source of truth — `git pull` updates
the skills everywhere at once.

Cost doctrine the whole family enforces (docs/15): flat-rate pools absorb all
volume work (Grok first, Codex second); Claude's capped pool buys judgment and
the feature work whose capability bar flat-rate pools can't clear — never
volume for convenience; Devin is the ACU-metered merge captain, never a bulk
coder.
