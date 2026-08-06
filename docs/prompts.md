---
title: "Copy-Paste Prompts"
nav_order: 4
---

# Copy-Paste Prompts

> 🙂 **In plain English:** Ready-made things to say to the crew. Copy one, send it, answer the plain questions that come back.

Use these with Hermes / chat / Mission Control. You do not need to remember special commands.

**Start here if you are not technical:** [VIBECODING.md](../VIBECODING.md) — this page is the cheat sheet of *what to say*; that page is *how the whole thing works for you*.

## For the non-technical owner (Operator)

| When you want… | Say this |
|---|---|
| Something new built | `I want customers to [outcome]. Here's how it works today: …` |
| A fix | `The [page/flow] feels wrong: [what you notice].` |
| Status | `What are you working on?` |
| What's waiting on you | `What's waiting on me?` |
| Site health | `How's my site doing?` |
| Cost | `How much is this costing?` |
| Undo last change | `Undo that last change.` |
| Pause | `Pause everything.` |
| Resume | `Okay, go again.` |
| Confusion | `I don't understand this.` |
| Preview feedback | `The preview looks off: [what feels wrong].` |
| Weekly learning | `What did you learn this week?` |

**Tip:** Describe the problem or the outcome, not the technology. "Customers abandon their carts" is better than "add a popup."

## For starting a plan (anyone)

```
I want [outcome in one sentence].

Who it's for: …
What success looks like: …
What must never happen: …
Rough priority: must-have / nice-to-have
```

## For the fleet operator (Mark / Engineer tier)

| Moment | Prompt |
|---|---|
| Adopt a repo | See playbooks/adopt.md — run the checklist, then: `Adopt [repo] as Operator-tier / Engineer-tier. Target: [url].` |
| Run solo loop (single model) | `Run the solo loop on [repo] against open backlog with one runner only.` |
| Optional cross-vendor review | `Review PR #[n] as reviewer hat. Cross-vendor if available.` |
| Site audit | `Run deploy-audit on [preview or production URL]. Scorecard + top 3 fixes.` |
| Harness improvement | `File a harness-improvement issue for: [failure]. Prefer sensor over guide.` |
| Force a decision card | `Translate gate G[n] into an Operator decision card and send.` |

## Rules these prompts assume

- Ask Contract is always on (docs/16).
- Only the sixteen human gates interrupt the owner (docs/14).
- Confusion from an Operator is treated as a failed test and fixed in the harness (docs/09).
- **Single-model is enough** — [VIBECODING.md § One AI is enough](../VIBECODING.md#one-model-is-enough); multi-model review is an upgrade.

Cross-links: [VIBECODING.md](../VIBECODING.md) · [EXAMPLES.md](../EXAMPLES.md) · [docs/16](16-nontechnical-operation.md) · [Operator Readiness](21-operator-readiness.md) · [QUICKSTART](../QUICKSTART.md)
