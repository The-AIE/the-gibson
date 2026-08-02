---
title: "Goose License Verification"
parent: The Doctrine
nav_order: 23
---

# Goose license + embed/re-brand/pin verification — issue #29 findings

> 🙂 **In plain English:** before building The Gibson on Goose's engine, we
> checked the paperwork: the license lets us embed it in a commercial
> product, rebrand the experience so users only see Gibson, and pin an
> exact version so upstream changes can't surprise us — and the project is
> governed by a neutral foundation, not a single company that could pull
> the rug. All four checks pass, with the caveats recorded below.

**Provenance:** verification for
[#29](https://github.com/mrhinkle/the-gibson/issues/29) (first item in the
Goose build sequence — see `docs/GOOSE-STRATEGY.md` § Work plan), performed
2026-08-01 by the cb-finish campaign (driver iteration 45) against the
upstream repository reachable at `github.com/block/goose` (now serving as
`aaif-goose/goose` — see governance finding). This is a dated capture of
upstream facts; re-verify before any distribution-shaped decision that
happens materially later.

**Method + limits (disclosed):** all evidence was read directly from
`github.com` pages (the only external host reachable from the verifying
container; Linux Foundation / AAIF web properties were NOT independently
fetched). No lawyer reviewed this; it is engineering due diligence against
the license text and repo governance files, not legal advice. Items that
need the running software — not the paperwork — are explicitly deferred to
the #28 spike.

## Findings against #29's four checkboxes

### 1. License allows embedding in a commercial product — CONFIRMED

- `LICENSE` at repo root is the **standard, unmodified Apache License
  2.0** text (January 2004), with copyright notice "Copyright 2024 Block,
  Inc." No custom clauses, no Commons-Clause-style riders.
- Apache-2.0 grants a perpetual, worldwide, royalty-free copyright license
  (§2) and an express patent grant (§3) covering use, modification, and
  redistribution — commercial embedding included. The grant on any
  released version is irrevocable; worst-case upstream behavior is
  answered by forking, not by losing the code.
- Obligations when redistributing: retain the license text and copyright
  notices, and state significant changes (§4). **No NOTICE file exists at
  the repo root** (checked 2026-08-01; the path 404s), so §4(d)'s
  NOTICE-propagation duty currently has nothing to propagate — re-check
  this at vendoring time, since upstream can add one.
- Documentation is CC-BY-4.0 (per GOVERNANCE.md) — attribution required if
  we reuse their docs; code and docs licensing are separate.

### 2. Full re-brand (factory invisible) — CONFIRMED legally; runtime depth is #28's

- Apache-2.0 §6 grants **no trademark rights** — which cuts our way: we
  must NOT ship the product under Goose's name, and we don't want to.
  Shipping the experience as The Gibson with Goose invisible is not just
  permitted, it is the §6-compliant posture ("reasonable and customary
  use in describing the origin" — e.g. crediting Goose in an about page or
  this doctrine — remains fine).
- Modification and renaming of the code itself are covered by §2/§4:
  rebrand freely, keep license + copyright notices in source-form
  redistributions, mark significant changes.
- **Deferred to #28:** how deeply the goose name is baked into binaries,
  config paths, CLI strings, and telemetry — that is an engineering
  measurement on the running software (the spike's "brand/control
  retained" line item), not a license question. Nothing legal blocks it.

### 3. Pin/vendor so upstream cannot break the fleet — CONFIRMED

- Releases are semver-tagged (`vMAJOR.MINOR.PATCH`); latest observed
  stable **v1.45.0 (2026-07-29)**, with a regular cadence (v1.44.0
  2026-07-23, v1.43.0 2026-07-14). Pinning a tag or commit is ordinary
  git practice here.
- Apache-2.0 imposes no anti-vendoring terms: forking, vendoring the
  source tree, and freezing at a known-good version are all within the §2
  grant. The irrevocability point in finding 1 is what makes the pin
  durable — an upstream relicense could only affect FUTURE versions, never
  the pinned one.

### 4. AAIF / Linux Foundation governance — CONFIRMED structurally, one caveat

- The README states goose "is part of the Agentic AI Foundation (AAIF) at
  the Linux Foundation," and `GOVERNANCE.md` establishes the project as a
  **Series of LF Projects, LLC** — the standard Linux Foundation neutral-
  home structure. The repo now serves under the `aaif-goose` organization
  (the historical `block/goose` URL redirects), consistent with a
  completed donation out of single-vendor control.
- Governance model: three tiers (Contributors → Maintainers → 3–7 Core
  Maintainers), merit-based nomination with majority vote, consensus via
  PRs/discussions, week-long community review + majority Core Maintainer
  approval for major architectural changes.
- **Caveat (honest, not disqualifying):** GOVERNANCE.md names the
  project's creator, Bradley Axen, as the tie-breaker when Core
  Maintainers deadlock — a residual single-person control point for
  contested decisions. It is not a rug-pull vector in the licensing sense
  (findings 1 and 3 make released code fork-safe regardless of who wins
  any governance fight), but it is a fact to know.

## Verdict

All four #29 checkboxes are satisfied for the purpose they serve —
unblocking the #28 spike. The dependency chain #29 → #28 → #33 may
proceed; nothing found here changes GOOSE-STRATEGY.md's build-on
recommendation or its non-goals (no fleet layer on Goose until the
re-evaluation trigger fires; Goose credited as engine, never surfaced as
product identity).

Re-verification triggers: any upstream relicense announcement, the
appearance of a NOTICE file, a governance change moving the project out of
LF stewardship, or six months elapsing before the vendoring decision is
executed.
