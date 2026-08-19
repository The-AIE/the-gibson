---
title: "OWASP Agentic Top 10 mapping"
nav_exclude: true
---

# OWASP Agentic Top 10 ↔ Gibson's eight security layers


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

**Audience:** Adopters, security reviewers, buyers who already speak
[OWASP Agentic](https://genai.owasp.org/initiatives/agentic-security-initiative/)
vocabulary and want an honest map of what The Gibson covers at **build time**.

**Related:** [docs/08-security.md](08-security.md) (the eight layers),
[docs/25-trust-and-governance.md](25-trust-and-governance.md) §4 (interop doctrine),
[D-008](../memory/DECISIONS.md) (borrow vocabulary, no runtime dependency),
[SECURITY-AUDIT.md](../SECURITY-AUDIT.md).

**Source:** [OWASP Top 10 for Agentic Applications for 2026](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/)
(ASI01–ASI10). This page is a **build-time** map only. Runtime agent governance is
out of core scope — see §Runtime below and D-008.

## Coverage legend

| Mark | Meaning |
|---|---|
| **covered** | A Gibson gate or layer directly addresses the risk for software the fleet *builds* |
| **partial** | Some surface is gated; residual risk remains or depends on adopter wiring |
| **runtime-only** | The risk lives in *products that run agents* after ship — recommend a downstream governor, not a core Gibson dependency |

Gibson is a **build-time trust harness**. It does not claim to govern agents inside
the products it ships. Over-claiming here would violate the red-team PROTOCOL.

## Mapping table

| OWASP ASI (2026) | Risk (short) | Gibson gate(s) / layer(s) | Coverage | Notes |
|---|---|---|---|---|
| **ASI01** | Agent Goal Hijack | Layer 7 AI-surface review; Law 1 (read contracts); claim scope; playbook-bound roles | **partial** | Build-time: agents must follow AGENTS.md + issue contracts; injection-scan on ingested markdown. Runtime goal hijack of a product agent is **runtime-only**. |
| **ASI02** | Tool Misuse & Exploitation | Layer 7 tool-scope checklist; least-privilege tokens; human gates for destructive/spend (docs/14); repo-boundary guard | **partial** | Harness runners are scoped (git guard, no free production write). Product-side tool graphs are **runtime-only**. |
| **ASI03** | Agent Identity & Privilege Abuse | Claims + worktrees (docs/05); per-lane identity seam (docs/20, #67); release review independence (L-015/L-021) | **partial** | Shared credentials across lanes remain a known seam until dedicated identities land. Zero-trust *product* identity is **runtime-only**. |
| **ASI04** | Agentic Supply Chain Compromise | Layer 3 supply chain (npm audit, OSV, Trivy, dependency-review, lockfile-lint); pinned adapters | **covered** | Strong for *code* the fleet commits. Dynamic tool/MCP registries for runtime agents are **runtime-only**. |
| **ASI05** | Unexpected Code Execution | Layers 2 SAST + 5 DAST + 6 adversarial; green gate; sandbox CI | **partial** | Catches unsafe generated *application* code before merge. Sandbox escape of a *product's* agent executor is **runtime-only**. |
| **ASI06** | Memory & Context Poisoning | `memory/` conventions (docs/09, docs/24); injection-scan; Law 9 append-only lessons; no secrets in memory | **partial** | Protects harness memory integrity. Product RAG/session memory is **runtime-only**. |
| **ASI07** | Insecure Inter-Agent Communication | Supervisor SHA pinning; handoff contracts; repo-boundary identity; no trust of runner-authored "PASS" as proof | **partial** | Gibson lanes hand off via git/GitHub facts, not free-form agent-to-agent trust. Multi-agent product meshes are **runtime-only**. |
| **ASI08** | Cascading Agent Failures | Green gate + fail-closed sensors; halt reclaim; quarantine ratchet (Law 9); human gates for go-live | **partial** | Stops bad code cascading into main. Runtime cascade across product agents needs a **runtime** governor. |
| **ASI09** | Human-Agent Trust Exploitation | Decision-card templates (docs/14, docs/16); Ask Contract; never auto-approve Tier C; "never grade your own homework" | **covered** | Owner channel is designed so agents cannot silently approve spend/go-live. Still depends on delivery wiring (#72). |
| **ASI10** | Rogue Agents | Claims, scope, halt labels, supervisor recheck, cross-vendor review (Law 5) | **partial** | Unattended loop has kill-switch + budget. Long-running product agents that drift are **runtime-only**. |

## Honest summary

| Bucket | Count | Categories |
|---|---|---|
| **covered** at build time | 2 | ASI04 (code supply chain), ASI09 (owner trust / human gates) |
| **partial** at build time | 8 | ASI01–03, ASI05–08, ASI10 — solid for *building* software with agents; not a full runtime story |
| **runtime-only** residual | all ten have a runtime half when the *shipped product* runs agents | Point adopters at a runtime governor (Mission Control, CSA Agentic Trust, AGT, etc.) — **not** into Gibson core (D-008) |

We do **not** claim "Gibson implements the OWASP Agentic Top 10." We claim: for the
SDLC surface Gibson owns, these are the gates that address each category, and where
coverage stops.

## Runtime (out of core)

When Gibson ships a product that *itself* runs agents:

```
Gibson (build-time trust)  --ships-->  product
                                         |
                                         v
                         runtime governor (policy, identity, kill-switch)
```

See [docs/25 §4](25-trust-and-governance.md). Gibson consumes neither a runtime
toolkit nor a product agent mesh.

## Cross-links

- Eight layers detail: [docs/08-security.md](08-security.md)
- Trust framing + D-008: [docs/25-trust-and-governance.md](25-trust-and-governance.md)
- Living control inventory: [SECURITY-AUDIT.md](../SECURITY-AUDIT.md)
- OWASP ASI source: [genai.owasp.org — Agentic Top 10 2026](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/)
