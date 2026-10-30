---
title: "Should Gibson and Agent Kontrol become one product?"
nav_exclude: true
---

> **Authority:** Non-normative research proposal. Binding behavior remains in AGENTS.md; this document adds no gate, permission or deployed capability.

# Should Gibson and Agent Kontrol become one product?

## Proposed decision

Test **one integrated operator experience and shared versioned contracts**, while retaining a portable Gibson core and explicit runtime/service boundaries. Defer a literal repository or deployment merger until comparative evidence supports it.

This is a proposal awaiting product/architecture decisions, not an accepted rename, migration or implementation order.

## Existing foundation

[Agent Kontrol's Gibson document](https://github.com/mrhinkle/agent-kontrol/blob/847b22b56f6203abadf3c1a41f9ba326c0bbe3ac/docs/GIBSON.md) already separates the runtime manager from repository gate authority. Agent Kontrol can stand alone. Gibson remains portable. That is compatible with an integrated product experience; the user need not see the component boundary on every step.

The current [architecture](https://github.com/mrhinkle/agent-kontrol/blob/847b22b56f6203abadf3c1a41f9ba326c0bbe3ac/docs/ARCHITECTURE.md) and [telemetry](https://github.com/mrhinkle/agent-kontrol/blob/847b22b56f6203abadf3c1a41f9ba326c0bbe3ac/docs/TELEMETRY.md) are sources to reuse, not permission to claim all proposed integrations or exporters are live.

## Options

| Option | Advantage | Cost/risk | When it earns adoption |
|---|---|---|---|
| Separate products and current handoffs | Independence; smallest immediate migration | Owner reconciles state/context and integrations | Baseline for comparison; sufficient for some technical users |
| One experience, shared artifact/identity contracts, separate components | Coherent owner journey, portable repo tooling, incremental rollout | Contract/version compatibility and state projection must be designed | Users complete the journey with fewer errors/interventions |
| Monorepo with modular packages/services | Coordinated contract changes and developer workflow | Dependency/release coupling; larger review/build surface | Repeated measured cross-repo change cost exceeds independence value |
| One tightly coupled deployment/service | Simple apparent installation for a narrow hosted offering | Portability, offline use, failure domain, auth/data and operational coupling | A validated segment prefers it and assurance/exit requirements are met |

“One product” does not logically require the last two options. Repository consolidation also does not provide missing event consumption, atomic ownership or working tool connections.

## First integrated journey to evaluate

1. Owner enters or imports the product description.
2. Sees a faithful specification, unknowns and consequential decisions.
3. Sees the smallest useful increment and explicit deferrals.
4. Starts only the work already authorized and admitted.
5. Sees evidence, current blocked reason and what action resolves it.
6. Receives a verified running capability and its limitations.
7. Sees the outcome of later use and the next justified increment.

Reuse existing decision/task/progress surfaces before designing a new console. Product implementation detail appears only when it helps the owner make a meaningful choice.

## Shared contracts to test

Product/specification version, requirement, increment, task/work reference, actor, attempt, evidence, bounded decision, deployment/release and observed outcome need stable cross-component references. Decide the canonical home of each fact and which read models are disposable projections. Do not duplicate gate truth into a second writable authority store.

Compatibility should be testable with exported artifacts and at least two supported execution paths before mandatory adoption. Keep model-provider and observation adapters optional.

## Evaluation and reversibility

Compare the integrated prototype with the current GitHub-native path on the same owner tasks and information. Measure completion, comprehension, wrong turns, context switching, interventions, consistency after retries and total delivery cost. Separate product confusion from missing credentials, blocked external operations and unavailable tools.

Start as an additive read/projection path with a clear fallback to existing artifacts. Do not migrate historical state, permissions, credentials, production databases or release authority merely to test the experience.

A later monorepo decision should include frequency/cost of cross-repo schema changes, duplicated code, compatibility incidents, release coordination, packaging/deployment burden, ownership and rollback/exit cost. Use those observations rather than brand aesthetics or a cleaner diagram.

## Decision conditions

Proceed with unified UX/contracts if it materially improves the owner journey at acceptable cost while standalone use and authority remain clear. Narrow or reject it if users prefer the simpler artifact path or integration introduces persistent conflicting state. Consider codebase consolidation only after the chosen boundary has worked across repeated real increments.
