---
title: "Goose Strategy"
parent: The Doctrine
nav_order: 22
---

# Goose Strategy — build The Gibson on Goose's engine, own the front door


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** Goose is an open-source AI-agent engine run by a
> neutral foundation. Instead of building and maintaining our own plumbing
> (the agent loop, tool connections, run configs), The Gibson will run on
> Goose's engine underneath — while everything you see and touch stays
> Gibson. Like a car maker buying a proven engine and building its own car
> around it.

**Provenance (read this first):** this document RECOVERS a strategy that was
decided and cited but never committed. Epic [#30](https://github.com/mrhinkle/the-gibson/issues/30),
issue [#28](https://github.com/mrhinkle/the-gibson/issues/28), and chatterbuilt's
`docs/POSITIONING.md` + `docs/GOOSE-FLEET-REEVALUATION.md` all reference
`docs/GOOSE-STRATEGY.md`; the original was written in an ephemeral session and
lost (see issue [#32](https://github.com/mrhinkle/the-gibson/issues/32)). This
restatement is reconstructed from the ratified decisions and the surviving
citations — it records existing decisions and does not make new ones.

**Decision status:**
- The posture below was **blessed by Mark on 2026-07-31** (recorded as
  chatterbuilt DECISIONS #30).
- The build was **authorized by Mark on 2026-08-01** ("use Gibson to manage
  Goose").
- Committing code that depends on the Goose runtime still waits on the
  epic's own gates: [#29](https://github.com/mrhinkle/the-gibson/issues/29)
  (license/embed/pin verification) and [#28](https://github.com/mrhinkle/the-gibson/issues/28)
  (time-boxed spike with an explicit fall-back to borrow-patterns +
  thin own harness if re-branding or dependency terms fail).

## The recommendation (four parts, from epic #30)

1. **Engine:** build the single-builder Gibson on Goose's runtime — agent
   loop, vendor adapters, MCP extension wiring, recipes. Stop reinventing
   plumbing a foundation-governed project maintains for us.
2. **Brand:** Gibson keeps its own name, CLI, and identity. Goose is under
   the hood, not the brand. If full re-branding proves impossible, that is
   a #28/#29 failure and the fall-back fires.
3. **Interop:** Gibson speaks **MCP + ACP** so it plays bidirectionally in
   the Goose ecosystem (and editors that speak ACP) regardless of how deep
   the engine adoption goes.
4. **Funnel:** publish a thin "Gibson for Goose" extension as an
   acquisition on-ramp to Goose's community, pulling users toward Gibson →
   Chatterbuilt. The plugin is a channel, **not** an identity
   ([#36](https://github.com/mrhinkle/the-gibson/issues/36); publication is
   Mark-gated as an outward-facing action).

## The Crew caveat (fleet layer stays put)

Goose's multi-agent primitives — agent-to-agent coordination, shared
memory, subagent hierarchies — are still maturing. The Chatterbuilt Crew's
fleet-orchestration layer therefore stays Chatterbuilt's own IP for now,
interoperating via MCP + ACP so a future move is a migration, not a
rewrite. The re-evaluation trigger (all three primitive families shipped
stable, documented, versioned, with the injection-hardening posture
covering multi-agent surfaces) is specified in chatterbuilt
`docs/GOOSE-FLEET-REEVALUATION.md`. Whether the Crew ever rides on Goose is
Mark's call, recorded in DECISIONS when made.

## Upstream snapshot (dated capture — verify fresh before depending on it)

As checked 2026-08-01 against `aaif-goose/goose`:

- License **Apache-2.0**; governed by the **Agentic AI Foundation (AAIF)
  at the Linux Foundation** (GOVERNANCE.md in-repo) — the single-vendor
  rug-pull concern #29 verifies is at least structurally addressed.
- Latest stable **v1.45.0 (2026-07-29)**; ~52k stars; 70+ MCP extensions;
  recipes are first-class (declarative YAML with pinned extension
  versions — prior art for [#25](https://github.com/mrhinkle/the-gibson/issues/25)/[#34](https://github.com/mrhinkle/the-gibson/issues/34)).
- **ACP under active development** (session system-prompt setter, slash
  commands in ACP server, elicitation improvements across v1.43–v1.45).
- **"Summon" subagent/delegate features emerging** (v1.44) — real, but not
  yet the three stable primitive families the Crew trigger requires. The
  trigger has **not** fired.

## Work plan

The build is tracked by epic [#30](https://github.com/mrhinkle/the-gibson/issues/30).
Sequence: #29 (license) → #28 (spike, decision gate) → #33 (adapters/goose)
→ #34 (recipe mirrors) + #35 (gates enforced in-session) → #36 (funnel
extension; publish Mark-gated). Independent: #24 (autonomy modes),
#23/#25/#26 (injection hardening + recipe format, pending #31's layout
cleanup).

## Non-goals

- No fleet/multi-agent layer on Goose until the trigger fires and Mark
  opts in.
- No renaming: the harness is The Gibson; Goose is credited as engine and
  prior art, never surfaced as the product identity.
- No pricing, tiers, or customer-facing copy — this is engineering
  doctrine only.
