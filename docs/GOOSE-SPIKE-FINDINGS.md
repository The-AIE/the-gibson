---
title: "Goose spike findings"
parent: The Doctrine
nav_order: 25
---

# Goose spike findings (#28) — paperwork + architecture pass

> 🙂 **In plain English:** before betting the harness on Goose, we checked license
> (already done) and whether we can keep Gibson's brand while using Goose as the
> engine. This records the first spike pass so the build can proceed.

**Date:** 2026-08-02  
**Scope of this pass:** documentation + upstream architecture review (no live
ConferenceOS red-team run yet — that remains a follow-up session with Goose
installed).  
**Depends on:** #29 **CLOSED completed** (`docs/GOOSE-LICENSE-VERIFICATION.md`).

## Measure 1 — Plumbing saved

Goose already provides:

- Agent loop (CLI + desktop + `goose serve` ACP API)
- Multi-provider LLM routing (15+)
- MCP extension host (70+ community extensions)
- **Recipes** (YAML instructions + pinned extensions) — prior art for #25/#34
- **Custom distributions / white-label** guide (`CUSTOM_DISTROS.md`) — brand path

Gibson should **not** reimplement these. Gibson keeps: Ten Laws, claim/worktree
scripts, green gate, human gates, memory ratchet, vibecoding product surface.

## Measure 2 — Brand / control retained

| Question | Result |
|---|---|
| Can we avoid shipping the product *as* Goose? | **Yes** — Apache-2.0 §6 grants no trademark; custom distros explicitly support rebrand |
| Can config/recipes hide Goose from operators? | **Mostly yes** — Gibson recipes + adapter README present Gibson; process name may still be `goose` until a custom bundle |
| Deep binary/UI invisibility | **Feasible** per CUSTOM_DISTROS (system prompt, bundle name, icons) — optional later |
| Pin/vendor | **Yes** — semver tags; pin e.g. `v1.45.0` |

**Decision lean:** commit to **build-on (option D)** for single-builder path.
Fallback (borrow patterns only) is **not** indicated by paperwork or architecture.

## Measure 3 — Fit for red-team playbook

| Need | Goose support | Gap |
|---|---|---|
| Permissions / approval | Four modes + per-tool Allow/Ask/Never | Map in #24/#35 |
| Injection hardening | Upstream Pale Fire layers (Unicode strip, previews, secondary LLM) | Gibson PROTOCOL already tracks (#23/#26 done) |
| Preview / live target | Via extensions + shell | Wire through gate scripts |
| Claim/gate discipline | Not native — must be recipe-mandated | #35 |

Red-team-on-Goose remains a **follow-up runtime session** once CLI is on a lab
host; this pass does not block adapter scaffold (#33).

## Decision gate (epic #30)

**Proceed with build-on.** Next mergeable work:

1. `adapters/goose/` + recipe v0 (**this foundation PR**)
2. #33 end-to-end builder session transcript
3. #34 reviewer/security recipes + drift sensor
4. #35 in-session gate enforcement
5. #36 extension build (publish still Mark-gated)

## Non-goals unchanged

- No fleet multi-agent layer on Goose until Crew re-evaluation trigger fires
- No renaming The Gibson
- No public publish of funnel extension without Mark
