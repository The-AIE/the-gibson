# Gibson x Goose — Strategy Decision

> STATUS: RECOMMENDATION for Mark. Companion to POSITIONING.md.
> Question: should Gibson compete with Goose, build on it, interoperate, or be a plugin to it?

## The facts (as of this decision)
- **Goose** is a mature, Apache-2.0 agent harness governed by the Agentic AI Foundation (AAIF)
  under the Linux Foundation. Permissive license + vendor-neutral governance = safe to build on;
  no single vendor can pull the rug. `OPEN`: confirm license terms formally before we depend on it.
- **How you build on it:** MCP extensions; recipes/subrecipes (declarative YAML, one agent can
  delegate to others); ACP (Goose runs as a daemon, can be embedded in editors AND consume other
  ACP agents bidirectionally); daemon mode for orchestration/CI.
- **Where Goose is strong today:** the agent loop, multi-host, adapters, MCP, local models,
  security hardening (Pale Fire), community (~tens of thousands of stars).
- **Where Goose is still early:** multi-agent *fleet* primitives — agent-to-agent coordination,
  shared memory, subagent hierarchies are not solved yet. This is exactly what the Crew needs.

## The core insight
Gibson has two facets, and they get **different answers**:
1. **Gibson-as-plumbing** (orchestration, adapters, memory, multi-model): do NOT reinvent this.
   Goose already did it, and we would lose that race to an LF-backed project. **Build on it.**
2. **Gibson-as-brand/front-door** (the open source identity that anchors the Chatterbuilt funnel):
   do NOT subordinate this to Goose. metaharness's own rule is "separate the factory from the
   product; users see YOUR brand." A plugin buried in Goose's marketplace makes *Goose* the brand
   and Gibson a component. **Own the front door.**

## Options considered
- **A. Compete (from-scratch harness).** Rejected. Wrong fight; we lose to a foundation-backed,
  multi-year-ahead project, and harness plumbing is undifferentiated.
- **B. Borrow patterns only, stay fully independent.** Weak. Reinvents the agent loop for no moat.
- **C. Make Gibson *only* a Goose plugin.** Rejected *as Gibson's identity* — it surrenders brand
  and funnel to Goose. But keep this idea: a plugin is a great *acquisition channel* (see below).
- **D. Build ON Goose + interoperate + also ship a Goose extension as a funnel.** **RECOMMENDED.**

## Recommendation (embrace the engine, own the front door)
1. **Engine:** build Gibson on Goose's Apache-2.0 runtime (agent loop, adapters, MCP, recipes).
   Inherit the maturity and hardening; spend our effort where the moat is.
2. **Brand:** Gibson keeps its own name, CLI, and identity. It is the harness people install —
   even though Goose is under the hood. Not a plugin, not buried.
3. **Interop:** Gibson speaks MCP + ACP so it plays bidirectionally in the Goose ecosystem (and
   Zed/JetBrains/etc.). Reach without subordination.
4. **Funnel tactic (this is where "plugin" is RIGHT):** ALSO publish a thin "Gibson for Goose"
   extension / recipe pack. Meet the existing Goose community where they are and pull them toward
   Gibson -> Chatterbuilt. A plugin as an on-ramp, not as the product's identity.
5. **Crew caveat:** Goose's fleet primitives are still early. So build the *single-builder* Gibson
   on Goose now; keep the **Crew / fleet layer (Chatterbuilt)** as our own IP until Goose's
   multi-agent story matures, then re-evaluate whether the Crew rides on Goose too.

The one-liner: **Gibson is our branded harness, built on Goose's engine, that funnels into the
Chatterbuilt bundle.** The moat is never the plumbing — it is the Crew bridge, the Employee
Handbook, and the non-coder DX. This is the Red Hat move: don't rebuild the kernel, build the
thing businesses pay for on top of it.

## What to verify / the spike
- Confirm Goose's Apache-2.0 terms and that we can embed the runtime as a dependency, fully
  re-brand (factory invisible), and pin/vendor it so an upstream change can't break the fleet.
- Time-boxed spike: rebuild ONE Gibson capability on Goose — the **red-team playbook run against
  ConferenceOS**, packaged both as a Gibson command and as a Goose recipe/extension. Measure:
  plumbing saved vs. brand/control retained. If it holds, adopt option D; if re-brand or
  dependency terms fail, fall back to option B (borrow patterns, keep a thin own harness).


---

## metaharness vs Goose — foundation vs pattern library

Both are meta-harness-class projects. Only one should be the substrate.

- **Goose = the foundation.** Apache-2.0, LF / AAIF-governed, mature, tens of thousands of users,
  a public security track record. Un-rug-pullable. Build Gibson's engine on this.
- **metaharness (ruv) = the pattern library + thesis validation.** Its philosophy ("separate the
  factory from the product; the model is replaceable, the harness is the product") *is* our
  structure, and it targets Hermes. But it is effectively a single-maintainer project (Reuven
  Cohen / rUv) with several overlapping meta-harness repos (metaharness, ruflo), young, with bold
  unverified claims and an unconfirmed license -- too much single-point risk to be load-bearing.

**Decision: build on Goose; mine metaharness for patterns; do not build on both.**

Patterns to mine from metaharness (mostly Chatterbuilt / fleet-side):
- **Cost-aware routing** (cheap -> frontier cascade) + Weight-EFT -- a Managed-tier margin lever
  (ties to the source-of-truth panel finding on API metering; chatterbuilt#268).
- **Default-deny governance + `mcp-scan`** ("npm audit for agent tools").
- **Darwin-mode self-improvement** (frozen model; mutate -> sandbox-test -> keep only measurably
  better) -- the discipline for the Crew's self-improving loop.
- **Witness-signed releases** (Ed25519 / SLSA-style provenance) -- defense against poisoned
  handbook updates (the-gibson#23, #26).
- **RVM hardware isolation** for untrusted callers (the Answering agent).
- **SBOM / threat-model subcommands** as a sellable trust signal for the Managed tier.

`OPEN`: confirm metaharness's license before touching any of its code. Prefer engaging ruv
(Reuven Cohen) directly -- compare notes / collaborate -- rather than depending on it.
