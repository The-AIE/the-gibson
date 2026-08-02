---
title: "Autonomy modes"
parent: The Doctrine
nav_order: 24
---

# Autonomy modes — Crew Chief / downstream boundary

> 🙂 **In plain English:** four settings for how much the AI may do alone, plus
> per-tool overrides for dangerous actions. Low-risk work can run while you sleep;
> money, secrets, and irreversible actions still require a human.

**Provenance:** adapted from Goose's four-mode + per-tool permission model for
Gibson / Chatterbuilt Crew Chief (issue #24, epic #30). Vocabulary is Gibson's;
mapping to Goose is recorded so the adapter can wire the same tiers.

## Four session modes

| Gibson mode | Meaning | Goose analogue |
|---|---|---|
| **Autonomous** | Act without asking inside claimed scope and non-gate work | Completely Autonomous |
| **Smart approval** | Act on routine steps; ask on judgment / ambiguity | Smart Approval |
| **Manual approval** | Ask before consequential tool calls | Manual Approval |
| **Chat only** | Advise only; no tools that mutate | Chat-Only |

Default for unattended solo-loop grind: **Autonomous** inside a claimed Tier A
scope, with per-tool overrides below still hard-blocking gate classes.

Default for Operator-tier (non-technical owner): **Smart approval**, so decision
cards still fire for the closed human-gate list ([docs/14](14-human-gates.md)).

## Per-tool overrides

These **supersede** the session mode for a specific tool or action class:

| Override | Meaning |
|---|---|
| **Always allow** | Never prompt (reads, typecheck, list files) |
| **Ask before** | Prompt every time (push, open PR, install deps) |
| **Never allow** | Hard block (force-push, secret print, production destroy) |

## Mandatory escalations (never autonomous)

Regardless of mode, the following always require a human (docs/14, Law 7):

- Money / pricing / billing code merges
- Production launch of new user-visible surfaces
- Schema-destructive changes, data deletion, force-push
- Secret rotation
- Customer PII / consent boundary changes

Map Critical/High red-team findings → owner card; never self-remediate those classes
unattended.

## Adapter wiring (Goose)

When `adapters/goose` runs a session, map:

- Session mode → Goose autonomy preset
- Gibson gate scripts → recipe-mandated shell steps or MCP tools with **Ask/Never**
  on mutate paths (#35)
- Operator decision cards → stay on the Hermes / chat path; Goose does not auto-approve

## Cross-links

- [docs/14-human-gates.md](14-human-gates.md)
- [docs/08-security.md](08-security.md)
- [docs/GOOSE-STRATEGY.md](GOOSE-STRATEGY.md)
- Chatterbuilt Crew Chief approval gate (downstream product)
