---
title: "21 · Operator readiness (end goal)"
parent: The Doctrine
nav_order: 21
---

# 21 — Operator Readiness Checklist

> 🙂 **In plain English:** This is the definition of done for "a non-coder can get software built with the same rigor as exceptional developers."

The end goal is met when **all** of the following are true on at least one live Operator-tier product.

**Primary path: one frontier model.** Multi-model review is optional for checking work, not required for shipping. See [VIBECODING.md](../VIBECODING.md), [prompts.md](prompts.md), and [QUICKSTART.md](../QUICKSTART.md).

## A. Owner experience (chat-only)

- [ ] Owner never needs a terminal, diff, CI log, or stack trace.
- [ ] All fleet→owner messages use only the four templates (status, decision-card, intake-question, incident-notice).
- [ ] Decision cards always include recommendation + "if you wait" + safe silence.
- [ ] Heartbeat: at least one status message per active week even when nothing shipped.
- [ ] "I don't understand this" is treated as a harness defect and fixed.
- [ ] VIBECODING.md alone is sufficient onboarding for a new non-technical owner.

## B. Rigor without the owner coding

- [ ] Green gate (typecheck/lint/test/build) hard-fails regressions.
- [ ] Generator and evaluator are separate agents (never grade own homework).
- [ ] UX-eval runs against a live preview for user-visible changes (not skip-as-green when preview exists).
- [ ] Security layers 1–3 hard-fail; Tier C surfaces get adversarial review + human gate.
- [ ] Claims + worktrees prevent agents overwriting each other.
- [ ] Ratchet: repeated failures become permanent guides or sensors.
- [ ] Silent-noop detection (L-008): loop does not burn iterations while doing nothing. *(Sensor `scripts/silent-noop.sh` exists and is tested; wiring it into `scripts/loop.sh` is still open, so the box stays unchecked.)*

## C. Autonomy & safety

- [ ] Closed list of ≤16 human gates; everything else resolved without waking the owner.
- [ ] Money, production launch of new surfaces, and customer-data handling always carded.
- [ ] Unanswered cards never auto-approve and never block unrelated work.
- [ ] Rollback path exists and is named on cards that change the live site.

## D. Proven in the real world

- [ ] Phase 2 demo: one Tier A issue flows end-to-end with zero technical human touches.
- [ ] Phase 3: one production repo adopted; morning digests show merged work + queued Tier C cards.
- [ ] At least one external non-technical reader successfully operates via VIBECODING for a real request.
- [ ] Case study with metrics (cycle time, owner minutes per ship, defect escapes) published.

## Current status (2026-08-02)

| Area | Status |
|------|--------|
| A. Owner experience (docs + templates) | **Mostly ready** — VIBECODING, prompts, docs/16, four templates; live Hermes wiring still Phase 3 |
| B. Rigor sensors | **In progress** — scripts/CI exist; L-008 silent-noop sensor tracked with #18 |
| C. Autonomy & safety | **Doctrine complete**; enforcement depends on B |
| D. Real-world proof | **Not yet** — Phase 2/3 demos and external reader test still open |

This checklist is the north star. Harness PRs should move at least one box. Closing the checklist is how we know the end goal is met.

---
[← 19 · Product and MCP](19-product-and-mcp.md) · [Home](../index.md) · [Prompts →](prompts.md) · [VIBECODING](../VIBECODING.md) · [QUICKSTART](../QUICKSTART.md)
