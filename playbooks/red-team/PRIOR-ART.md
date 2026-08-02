# Prior Art & Credits

Gibson did not appear from nothing. Two open source projects shaped how we think about
agent harnesses, and we have borrowed liberally from both. This file credits them, records
exactly what we took, and says — per item — whether we **build on** it or **borrow** the idea.

At the harness level, **Goose and metaharness are peers, not inputs to a red-team tool.**
They solve the same class of problem Gibson does. The comparisons below are harness-to-harness;
nothing here says Gibson *is* the red-team playbook (see `README.md` — red-team is one playbook
Gibson runs).

**Build on vs. borrow.** *Build on* = we depend on their artifact at runtime (their code, their
runtime, their protocol). *Borrow* = we reimplement the idea inside Gibson's own
Markdown/shell/CI substrate and owe them the credit.

## Hat tips

### Goose — Block, now governed by the Linux Foundation
Repo: https://github.com/aaif-goose/goose · Docs: https://goose-docs.ai/

A model-agnostic, MCP-native coding agent. Block handed governance to the Linux Foundation,
which makes its vendor-neutrality a structural fact rather than a marketing claim.

What we learned and borrowed:
- **Autonomy model.** Four modes — Completely Autonomous, Smart Approval (risk-calibrated,
  escalates only high-risk actions), Manual Approval, Chat-Only — plus per-tool overrides
  (Always Allow / Ask Before / Never Allow). This is the basis for the Gibson → Chatterbuilt
  Crew Chief autonomy boundary. (See the-gibson#24.)
- **Recipes.** Declarative, version-pinned run definitions that make a run reproducible and
  reviewable in version control. Basis for making a Gibson pass auditable. (See the-gibson#25.)
- **"Operation Pale Fire" red-team disclosure.** Zero-width Unicode prompt injection hidden
  inside shared config files, plus a five-layer remediation (diff-preview before execute,
  strip non-printing chars at load, granular per-action permission dialogs, MCP-server
  scanning, secondary-LLM injection monitoring). This directly shapes our prompt-injection
  phase and hardening checklist. (See the-gibson#23 and the-gibson#26.)

### metaharness — ruvnet
Repo: https://github.com/ruvnet/metaharness

A *factory* that scaffolds branded agent harnesses — each with its own npx CLI, MCP adapter
layer, scoped memory, a learning loop, witness-signed releases, and an optional
hardware-isolated sandbox (RVM). Its stated philosophy: "The model is replaceable. The
harness is the product." It explicitly targets Hermes, which is the runtime under Chatterbuilt
Crew Chief.

What we learned and borrowed:
- **Default-deny tool governance.** Network, shell, file I/O, and secrets are opt-in from
  zero trust — not granted by default.
- **`mcp-scan` — "npm audit for agent tools."** Static analysis of MCP tools that flags shell
  access, network grants, missing timeouts, and unpinned dependencies. We fold this into
  Gibson's Phase-2 automated sweep and the shared-config integrity checks.
- **Threat-model and SBOM as first-class artifacts.** A harness should emit its own compliance
  artifacts. Gibson's dated findings ledger is our version of this.
- **Witness-signed, reproducible releases.** Provenance so a consumer can verify what they ran.
  Reinforces the recipe / reproducibility work.
- **"The model is replaceable, the harness is the product."** This validates our whole thesis:
  Gibson and Chatterbuilt are the durable IP, not any single model.

## Where each project sits relative to Gibson

- **Goose — a peer runtime we intend to build *on*.** Goose executes tasks; Gibson governs how
  work moves from plan to production. Those compose: Gibson's doctrine and gates can ride on
  Goose's runtime rather than competing with it. That is the-gibson#30 (EPIC) and #33
  (`adapters/goose`). Goose's autonomy model (#24) and recipes (#25) we *borrow* as specs.
- **metaharness — a peer factory whose patterns we *borrow*.** metaharness generates branded
  harnesses; Gibson is one opinionated harness. We reimplement its best patterns — default-deny
  tool governance, `mcp-scan`-style tool auditing, threat-model/SBOM as artifacts,
  witness-signed reproducible releases — in Gibson's own substrate. **The metaharness spike
  applies to Gibson first**, not to Chatterbuilt: Gibson is the harness, so harness-shaped
  patterns land here and only graduate downstream once proven.
- **Orchestration is Gibson's differentiator.** Goose is deliberately single-agent (manual
  session chaining); metaharness leaves orchestration to the host. Gibson's fleet, claims, and
  staged gates are the part neither peer provides — which is exactly why building *on* Goose's
  runtime costs us nothing we value.

The short version: we took their best ideas — autonomy tiers, reproducible recipes,
default-deny governance, injection hardening, provenance — and kept the orchestration and
enforcement that are ours. The model is replaceable; **the harness is the product.**

---

**Note for the Chatterbuilt side.** Once a metaharness pattern is proven in Gibson, several of
them (cost-aware model routing, sandboxed self-improvement within
safety bounds, hardware isolation for untrusted peers, witness-signed fleet releases) deserve
their own evaluation there, tracked alongside chatterbuilt#268.
