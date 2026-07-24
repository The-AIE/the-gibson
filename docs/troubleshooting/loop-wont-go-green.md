---
title: "Loop won't go green"
nav_exclude: true
---

# Loop won't go green

## Symptoms

- `loop.sh` stops with **error budget exhausted**
- journal shows the same hat failing repeatedly
- PR CI red across iterations

## Why this matters

A loop that can't go green is usually a **harness or contract bug**, not a model
problem ([docs/11](../11-solo-loop.md)). Burning more tokens makes it worse.

## Checklist

| Check | Action |
|---|---|
| Kill switch | Remove `gibson/HALT`; ensure no `GIBSON_HALT=1` |
| Baseline missing | Run `gate-baseline.sh` at branch point; commit? No — keep local |
| Gate commands wrong | Set `.gibson-gate.json` to real scripts |
| Pre-existing red | Baseline should allow non-worse red; if whole suite broken, burn-down first (docs/13) |
| Same AC fails 3× | Escalate grade once ([docs/15](../15-model-economics.md)); then **park** with handoff |
| Contract untestable | Decomposer bug — split issue / rewrite ACs |
| Preview never ready | See [preview-url-failures.md](preview-url-failures.md); UX/security hats can't pass |

## Recovery

```bash
# Inspect state
cat gibson/loop-state.md
tail -n 50 gibson/journal.md

# Manual single hat with stronger runner
./scripts/loop.sh --runner claude --repo . --hat reviewer --once

# Park and move on
# set parked: true in loop-state; pick next issue
```

## Do not

- Raise error budget silently to "push through"
- Self-APPROVE Tier C to clear the queue
- Delete failing tests to green the gate
