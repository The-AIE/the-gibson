---
title: "Autonomy modes"
parent: The Doctrine
nav_order: 25
---

# Autonomy modes — Crew Chief / downstream boundary

> 🙂 **In plain English:** four settings for how much the AI may do alone, plus
> per-tool overrides for dangerous actions. This page **defines and maps** the
> modes so adapters and products share vocabulary. It does **not** adopt new
> session defaults for Gibson; existing human gates remain authoritative.

**Provenance:** adapted from Goose's four-mode + per-tool permission model for
Gibson / Chatterbuilt Crew Chief (issue #24, epic #30). Vocabulary is Gibson's;
mapping to Goose is recorded so the adapter can wire the same tiers later.

## Four session modes (definitions only)

| Gibson mode | Meaning | Goose analogue |
|---|---|---|
| **Autonomous** | Act without asking inside claimed scope and non-gate work | Completely Autonomous |
| **Smart approval** | Act on routine steps; ask on judgment / ambiguity | Smart Approval |
| **Manual approval** | Ask before consequential tool calls | Manual Approval |
| **Chat only** | Advise only; no tools that mutate | Chat-Only |

### Deployment defaults — not chosen here

This scaffold **does not** set new unattended or Operator session defaults for
Gibson. Until a **separate adoption decision** (issue #24 acceptance / owner
gate) records otherwise:

- **Authoritative stops** remain the closed list in
  [docs/14-human-gates.md](14-human-gates.md) and Law 7 (Tier C).
- Existing solo-loop / operator docs keep whatever posture they already state;
  do not read this page as changing unattended grind or Operator-tier defaults.
- Products that map these modes (e.g. Chatterbuilt Crew Chief) choose their own
  product defaults under their own decision process — still subject to docs/14
  when operating as Gibson fleet work.

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

Offline wiring lives in [`adapters/goose/permission-map.yaml`](../adapters/goose/permission-map.yaml)
and is enforced by [`adapters/goose/enforce.sh`](../adapters/goose/enforce.sh) (#35):

- Session mode → Goose autonomy analogue (table above); **defaults still not forced**
  unattended — docs/14 remains authoritative until a separate adoption decision
- Gibson gate/claim/release → recipe-mandated shell steps via `enforce.sh`
  (`pre-edit`, `pre-commit`, `release`); green-gate tools are **Always allow** so
  permission prompts cannot skip the gate
- Destructive classes (force-push, secrets, prod destroy, money, PII) → **Never allow**
- Operator decision cards → Hermes / chat path; Goose does not auto-approve
- Live `goose run` still waits on **#28**; enforcement does not require the Goose binary

## Cross-links

- [docs/14-human-gates.md](14-human-gates.md)
- [docs/08-security.md](08-security.md)
- [docs/GOOSE-STRATEGY.md](GOOSE-STRATEGY.md)
- [docs/GOOSE-SPIKE-FINDINGS.md](GOOSE-SPIKE-FINDINGS.md)
- Chatterbuilt Crew Chief approval gate (downstream product)
