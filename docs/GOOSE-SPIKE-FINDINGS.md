---
title: "Goose spike findings"
parent: The Doctrine
nav_order: 25
---

# Goose spike findings (#28) — paperwork + architecture pass

> 🙂 **In plain English:** before betting the harness on Goose, we checked license
> (already done) and whether we can keep Gibson's brand while using Goose as the
> engine. This records a paperwork/architecture pass only. Issue #28 remains open.

**Date:** 2026-08-02
**Scope of this pass:** documentation + upstream architecture review only.
**No live runtime spike ran** — no Goose CLI install, no ConferenceOS red-team
session, no end-to-end builder transcript on Goose. Those remain the open #28 work.
**Depends on:** #29 **CLOSED completed** (`docs/GOOSE-LICENSE-VERIFICATION.md`).

## What this PR does *not* claim

- **#28 is still open.** This document is not a closed decision gate for #28.
- **No runtime-dependent build may proceed** solely because of this pass.
  Committing code that *depends on* the Goose runtime still waits on #28's live
  spike and explicit fall-back decision, per
  [docs/GOOSE-STRATEGY.md](GOOSE-STRATEGY.md).
- **This PR only permits docs/config scaffold** (`adapters/goose/`, recipe YAML
  mirrors, autonomy-mode vocabulary) with **no Goose runtime dependency** in CI
  or scripts. The scaffold may exist on disk; fleet code paths must not require
  `goose` on PATH yet.

## Measure 1 — Plumbing saved (from upstream docs / architecture)

Goose already provides (per upstream docs and public surface — not verified by a
live run in this pass):

- Agent loop (CLI + desktop + `goose serve` ACP API)
- Multi-provider LLM routing (15+)
- MCP extension host (70+ community extensions)
- **Recipes** (YAML instructions + pinned extensions) — prior art for #25/#34
- **Custom distributions / white-label** guide (`CUSTOM_DISTROS.md`) — brand path

Gibson should **not** reimplement these once build-on is fully authorized. Gibson
keeps: Ten Laws, claim/worktree scripts, green gate, human gates, memory ratchet,
vibecoding product surface.

## Measure 2 — Brand / control retained (paperwork lean)

| Question | Result |
|---|---|
| Can we avoid shipping the product *as* Goose? | **Yes** (on paper) — Apache-2.0 §6 grants no trademark; custom distros explicitly support rebrand |
| Can config/recipes hide Goose from operators? | **Mostly yes** (on paper) — Gibson recipes + adapter README present Gibson; process name may still be `goose` until a custom bundle |
| Deep binary/UI invisibility | **Feasible** per CUSTOM_DISTROS (system prompt, bundle name, icons) — optional later; confirm in live #28 |
| Pin/vendor | **Yes** — semver tags; pin e.g. `v1.45.0` |

**Direction (already ratified in strategy, not newly decided here):** the
build-on (option D) posture for the single-builder path is the one recorded in
[docs/GOOSE-STRATEGY.md](GOOSE-STRATEGY.md) (Mark-blessed 2026-07-31 / build
authorized 2026-08-01). This pass **does not re-ratify** that decision and
**does not** close the #28 fall-back gate. If live spike findings show re-brand
or dependency terms fail, the strategy's fall-back (borrow patterns + thin own
harness) still applies.

## Measure 3 — Fit for red-team playbook (gaps only until runtime)

| Need | Goose support (docs) | Gap |
|---|---|---|
| Permissions / approval | Four modes + per-tool Allow/Ask/Never | Map in #24/#35 |
| Injection hardening | Upstream Pale Fire layers (Unicode strip, previews, secondary LLM) | Gibson PROTOCOL already tracks (#23/#26 done) |
| Preview / live target | Via extensions + shell | Wire through gate scripts |
| Claim/gate discipline | Not native — must be recipe-mandated | #35 |

Red-team-on-Goose remains a **required follow-up runtime session** once CLI is on
a lab host. This paperwork pass **does not** unblock runtime-dependent merges.

## Scaffold allowed now vs still gated

**Allowed in this foundation PR (docs/config only):**

1. `adapters/goose/` README (install-with-verify, recipe path, no false loop claim)
2. Recipe YAML mirrors at Goose schema `1.0.0` / Gibson maturity v0
3. Autonomy-mode vocabulary map ([docs/autonomy-modes.md](autonomy-modes.md)) —
   define and map only; no new session defaults adopted here
4. Doctrine index + adapter matrix entries

**Still gated on #28 live spike (and subsequent issues):**

1. Closing #28 / declaring the runtime decision gate passed
2. #33 end-to-end builder session transcript on Goose
3. #34 reviewer/security recipes + drift sensor
4. #35 in-session gate enforcement
5. #36 extension build (publish still Mark-gated)
6. `loop.sh --runner goose` (not implemented)

## Non-goals unchanged

- No fleet multi-agent layer on Goose until Crew re-evaluation trigger fires
- No renaming The Gibson
- No public publish of funnel extension without Mark
