---
title: "Decisions"
nav_exclude: true
---

# Decisions (ADR-lite, append-only)

Format: what was decided · alternatives rejected · revisit condition.

## D-001 · 2026-07-24 · Git-markdown is the memory substrate
Decided: fleet memory = Markdown in this repo (lessons/decisions/incidents);
Mission Control's Supabase `memory` table stays for runtime coordination only.
Rejected: vector DB as primary store (ruflo's own data: HNSW pays off after ~1,000
trajectories; we have dozens), MC-table-as-primary (not versioned, not reviewable,
vendor-tied query path).
Revisit when: lessons exceed ~500 entries or grep-recall demonstrably misses.

## D-002 · 2026-07-24 · Agent-agnostic core, vendor-thin adapters
Decided: doctrine only in Markdown + scripts + CI; anything expressible only as a
vendor skill/hook is doctrine-debt.
Rejected: Claude-skills-first (locks the fleet to one runtime; ConferenceOS audit
showed skills were the only non-portable layer).
Revisit when: a runtime emerges that can't consume the core (would indicate the
core grew vendor assumptions).

## D-003 · 2026-07-24 · The Gibson governs itself with its own pipeline
Decided: harness changes are PRs through the same gates; human-gate list, tiers,
and hard-fail thresholds are Tier C.
Rejected: harness-as-config-anyone-edits (self-modification without gates is how a
fleet lobotomizes itself).
Revisit when: never — this one is load-bearing.

## D-004 · 2026-07-24 · Grind/Skilled/Frontier routing with flat-rate-first
Decided: G/S/F task grading; flat-rate pools absorb volume; metered tokens buy
judgment only; escalate on signal (2 same-criterion failures), de-escalate
quarterly on evidence.
Rejected: best-model-for-everything (cost pathology, L-003); cheapest-for-everything
(Tier C evaluation floor is S-grade — bad review is more expensive than good
tokens).
Revisit when: pool pricing changes materially.

## D-005 · 2026-07-24 · Foreman/CodeWright ship free inside the AIE subscription
Decided: no standalone paywall — the Chatterbuilt product (CodeWright + Foreman)
is a free add-on to the theaie.net membership; the MCP token is issued against
the subscription; monetization is the AIE flywheel (users → subscribers →
content → users).
Rejected (for now): audit-free/Blueprint-free/Foreman-paid gradient; standalone
suite pricing.
Revisit when: Foreman usage meaningfully exceeds AIE conversion, or fleet
compute costs per user demand direct pricing.

## D-006 · 2026-08-01 · Adoption is a ladder: enforcement before orchestration
Decided: a target repo adopts The Gibson in two separable steps, and the first one
does not imply the second.

- **Rung 1 — enforcement + doctrine.** Install `templates/target-repo/AGENTS-section.md`
  and `ci/gibson-gate.yml` (plus `ci/security.yml` / `ci/ux-eval.yml` where the repo
  has a preview deployment). Deterministic gates and a written agent contract. An
  interactive coordinator still carves scope, dispatches, and drives the merge train.
- **Rung 2 — orchestration.** Hand the repo to `scripts/loop.sh` / the solo loop
  (`docs/11-solo-loop.md`) to run unattended against its backlog.

A repo may sit on rung 1 indefinitely. Rung 2 requires all of: (a) the repo passes
`playbooks/adopt.md` cleanly, (b) at least one *other* target has demonstrated the
Phase 4 ratchet — an agent-authored harness PR merged through the pipeline, and
(c) the repo's production write path is hardened per `docs/20-delivery-control.md`
if merge ships to production.

First application: **ConferenceOS takes rung 1 now, rung 2 not yet.** It is the
largest target, carries a protected `release` branch and a live merge train, and
chatterbuilt (Phase 3) has not yet closed Phase 4. Adopting both rungs at once
would mean debugging the harness and the product in the same window.

Rejected: all-or-nothing adoption (made ConferenceOS look like a Phase 5 blocker
when its CI could benefit immediately); skipping the harness for big repos entirely
(loses the gates, which are the cheap half).
Revisit when: the Phase 4 ratchet closes on chatterbuilt — then re-evaluate each
rung-1 target for promotion rather than adopting a new one.

## D-007 · 2026-08-04 · Dependency/scope graphs are sensors, not an engine
Decided: keep graph structure implicit in the core; add narrow deterministic graph
*sensors* only where a failure class exists and only because they help build Gibson
itself — (1) a decomposition cycle + critical-path check beside `decompose-lint`, and
(2) a claim scope-overlap (independent-set) check in the claim path. No graph
database, no graph library, no "graph engine" in the core.
Rejected: rebuilding the harness as a "graph engineering harness" (violates D-002 and
primitives-not-features; the graphs are tiny — ≤ ~10 issues, ≤ 3 lanes — so
topological/critical-path/coloring buy nothing that `Blocked by` + serialization do
not); leaving both gaps unsensed (`decompose-lint` cannot catch a dependency cycle;
concurrency relies on string scope-match, the L-023 / 2026-07-18 clobber class).
Revisit when: a single plan routinely exceeds ~30 interdependent issues, or lanes
exceed ~8, where computed graph algorithms materially beat hand rules.

## D-008 · 2026-08-04 · Agent governance — adopt the vocabulary, not the runtime
Decided: The Gibson governs build-time SDLC; runtime agent governance (Microsoft
Agent Governance Toolkit, Mission Control) is a separate, downstream layer. Borrow the
shared standards — map the eight security layers to the OWASP Agentic Top 10, adopt
zero-trust per-actor identity (GitHub App / machine user per lane) to close the
shared-credential seam (docs/20), derive a trust score from retro evidence for routing
(docs/15) — but take no runtime-governance dependency into the core. See docs/25.
Rejected: adopting Microsoft AGT (or similar) as Gibson infrastructure (runtime-only,
Python middleware overlay — wrong layer, heavy vendor dependency, violates D-002);
ignoring the emerging standards (forfeits a governance claim buyers already
understand).
Revisit when: a runtime-governance need appears inside the harness itself (not the
products it ships), or the OWASP/CSA agentic standards consolidate enough to pin a
version.

## D-009 · 2026-08-04 · Per-project coordination knowledge graph is target-side
Decided: a knowledge graph to aid agent coordination belongs to the **target
project**, not the Gibson core — built as an adapter over that repo's existing issues
/ markdown / git (nodes: issues, claims, files/routes, lessons, decisions; edges:
blocks, touches, owns, supersedes), answering "what depends on this / who touches this
file / which lessons touch this route." Same adapter-over-substrate rule as
D-001 / docs/09. It enters the Gibson core only if it demonstrably helps develop the
Gibson (the D-007 sensors are the only current instance).
Rejected: a graph in the Gibson core for every project (couples the harness to a
graph runtime, violates D-002); a mandatory graph DB per target (heavy; most repos
are served by grep + labels); no coordination graph at all (leaves fast
"what depends on what" recall on the table for large targets like ConferenceOS).
Revisit when: a target's coordination load (issues × lanes × hot files) makes
grep-recall miss, or a spike shows the adapter beats labels/serialization on a real
repo.
