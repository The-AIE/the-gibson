---
title: "25 · Trust, vibecoding, and agent governance"
parent: The Doctrine
nav_order: 25
---

# 25 — Trust for Vibecoding, and Where Agent Governance Fits

> 🙂 **In plain English:** Vibecoding made it easy to *build* software. It did nothing
> to make the result *trustworthy*. The Gibson's whole job is the second part — the
> gates, the second opinion, the paper trail — so a non-technical owner can stand
> behind what ships. This page says why trust is a property of the harness, not the
> model, and where other people's "agent governance" tools do and do not belong.

## 1. Trust is a harness property, not a model property

Vibecoding removed the friction of writing code. The bottleneck moved from "can we
build it" to "can we believe it" — is it correct, secure, private, reversible, and
accountable? You do not get there by renting a smarter model. You get there by
trusting the process the model is forced through. The model is rented; the harness is
yours and compounds ([README](../README.md), after
[Fowler](https://martinfowler.com/articles/harness-engineering.html)).

This is the early web again. Anyone could View Source and stand up a page in 1996 —
the fun part. Commerce did not arrive until the boring trust plumbing did: TLS,
payment gateways, audit logs, shared standards. Vibecoding is at the
personal-homepage stage. The Gibson is the plumbing that lets a business put weight
on it.

## 2. The five mechanisms that produce trust

Each already exists in the harness:

1. **Separation of powers — never grade your own homework.** Generation and
   evaluation are different agents, ideally different vendors; the reviewer verifies
   against running software, not the diff ([docs/01](01-principles.md),
   [docs/20](20-multi-model-orchestration.md)).
2. **Deterministic gates.** Green gate, eight-layer security, route×role authz, and
   Playwright-vs-preview UX grading — trust that does not depend on a model being
   sharp today ([docs/02](02-sdlc-pipeline.md), [docs/06](06-quality-gates.md),
   [docs/08](08-security.md)).
3. **A paper trail anyone can read.** Git is the audit and memory substrate; the Ask
   Contract states *what / does / why / risks* in plain language so a non-technical
   owner can actually consent ([docs/09](09-memory-and-self-improvement.md), README).
4. **Bounded autonomy, few human gates.** Autonomy by default for reversible work; a
   one-page closed list of mandatory stops; everything reversible; "pause everything"
   always available ([docs/14](14-human-gates.md)).
5. **The ratchet.** A failure that happens twice becomes a permanent sensor, so trust
   compounds instead of decaying ([docs/09](09-memory-and-self-improvement.md)).

## 3. Build-time trust vs runtime trust

The Gibson governs **build-time**: how a fleet safely produces software. It stops at
ship. A deployed agent that *acts in the world at runtime* — books, pays, moves data —
is a different trust problem, owned by a **runtime governor** (Mission Control for our
own dispatch; a runtime policy layer for the agentic products we ship). The two
compose:

```
Gibson (build-time trust)  --ships-->  product
                                         | if the product itself runs agents:
                                         v
                         runtime governor (policy, identity, kill-switch)
```

We do not fold a runtime governor into the harness. See §4.

## 4. Agent-governance interop: adopt the vocabulary, not the runtime

The market is standardizing on a shared language for agent risk — the
[OWASP Agentic Top 10](https://genai.owasp.org/initiatives/agentic-security-initiative/)
and zero-trust-for-agents
([CSA Agentic Trust Framework](https://cloudsecurityalliance.org/blog/2026/02/02/the-agentic-trust-framework-zero-trust-governance-for-ai-agents)).
Runtime toolkits such as Microsoft's
[Agent Governance Toolkit](https://github.com/microsoft/agent-governance-toolkit)
(policy engine, zero-trust identity, execution rings, tamper-evident audit) are
explicitly *runtime-only* and do not touch the SDLC.

Doctrine ([D-008](../memory/DECISIONS.md)): **borrow the vocabulary and standards;
take no runtime dependency into the core.**

- **Map our gates to the OWASP Agentic Top 10.** The eight security layers already
  cover much of the agent-produces-code surface; publishing the mapping turns
  build-time discipline into a governance claim buyers already understand.
- **Close the shared-credential seam with per-actor identity.** One token across
  lanes means an honest action can read as forgery
  ([docs/20](20-multi-model-orchestration.md)); the fix is a GitHub App / machine
  user per lane — the zero-trust identity idea on a Gibson-native substrate.
- **Trust scoring from our own evidence.** Derive a per-vendor / per-lane score from
  retro data (pass rates, defects caught, cost overruns) to route work
  ([docs/15](15-model-economics.md)) — reinforcing §2.1.
- **Recommend a runtime governor downstream, not upstream.** When The Gibson builds a
  product that itself runs agents, that product is governed at runtime by Mission
  Control or a toolkit like AGT. The Gibson consumes neither.

## 5. Graphs: where they belong, and where they do not

The Gibson already *thinks* in graphs — the pipeline DAG, the decomposition
"dependency DAG" ([docs/04](04-plan-to-issues.md)), the "task graph" a coordinator
owns ([docs/20](20-multi-model-orchestration.md)), the conflict graph behind claims
([docs/05](05-concurrency.md)). None of it is *computed*: there is no graph store, no
traversal, no cycle or critical-path check. That is correct by default
([D-002](../memory/DECISIONS.md): agent-agnostic, boring substrate). A "graph engine"
in the core would be architecture for its own sake — the graphs are tiny (≤ ~10
issues, ≤ 3 lanes).

The three-way boundary:

- **Gibson core — graph-free.** Keep structure implicit: diagrams, `Blocked by #N`,
  agent reasoning, serialization.
- **Gibson dev — two graph *sensors*, because they help build Gibson itself.** A
  decomposition cycle / critical-path check, and a claim scope-overlap
  (independent-set) check that retires the L-023 / 2026-07-18 clobber class. These are
  deterministic sensors, not an engine ([D-007](../memory/DECISIONS.md); tracked as
  issues).
- **Target projects — an optional per-project coordination knowledge graph.** A repo
  the fleet works may benefit from a small graph that answers coordination questions
  faster than grep — *what depends on this issue, who is touching this file, which
  lessons touch this route, what decision supersedes which*. It is **target-side**,
  built as an **adapter over the existing issues / markdown / git substrate** (the
  same "index is an adapter over the files" rule as
  [docs/09](09-memory-and-self-improvement.md)), and it never enters the Gibson core.
  It is a coordination aid for agents working a product, not harness machinery
  ([D-009](../memory/DECISIONS.md); spike tracked as an issue).

Rule of thumb: a graph earns its place when it removes a coordination failure or
answers a live "what depends on what" question — not because relationships exist.

---
[← 24 · Agent memory conventions](24-agent-memory-conventions.md) · [Home](../index.md) · [01 · Principles](01-principles.md)
