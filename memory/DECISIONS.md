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
