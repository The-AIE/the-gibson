---
title: "Operator message templates (docs/16)"
nav_exclude: true
---

# Operator message templates (docs/16)


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../../AGENTS.md). This file must not add, drop, or weaken those rules.

Hermes (or any messaging front-end) renders **exactly four shapes**. Fill the
`{{placeholders}}`; never invent a fifth shape for Operators.

| Template | When |
|---|---|
| [decision-card.md](decision-card.md) | Human gate (docs/14) — one decision only |
| [status.md](status.md) | Shipped / in progress; nothing needed from owner |
| [intake-question.md](intake-question.md) | Planner needs one business fact |
| [incident-notice.md](incident-notice.md) | Something broke; one-sentence story + action or none |

## Plain-language translation rules

1. No jargon word uncarried — first use explains inline.
2. One decision per card; recommendation mandatory.
3. "Do nothing" is always described; silence never auto-approves.
4. Questions answered before yes/no is accepted.
5. If it cannot be phrased in the operator's vocabulary, it is not their question
   — route to Engineer tier or resolve autonomously.

## Confusion is a bug

If the operator replies "I don't understand this", treat it like a failed test:

1. Explain on the thread in simpler words.
2. File a lesson ([docs/09](../../docs/09-memory-and-self-improvement.md)) and
   rewrite the template/wording so the next person is not confused.
