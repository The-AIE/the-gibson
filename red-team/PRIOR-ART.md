# Prior Art & Credits

Gibson did not appear from nothing. Two open source projects shaped how we think about
agent harnesses, and we have borrowed liberally from both. This file credits them, records
exactly what we took, and explains why Gibson is still its own thing rather than a fork or a
wholesale adoption.

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

## Why Gibson is its own thing (the problem we solve)

Both projects are excellent, and neither is the thing we need:

- **Goose is a doer; Gibson is an auditor.** Goose executes tasks. Gibson is an adversarial
  *methodology* — a red-team discipline that runs on top of whatever agent we already have
  (Cowork / Claude). We do not need another agent runtime; we need an opinionated protocol
  that finds money, PII, and auth flaws before a paid pentest.
- **metaharness is a factory; Gibson is a product with a single job.** metaharness *generates*
  harnesses. We already have Gibson, scoped to one portfolio (AIE Network / Peripety Labs) and
  weighted toward one worst case: payments plus attendee PII in ConferenceOS. We do not need a
  generator or a distributable CLI — we need one auditable protocol that graduates into
  Chatterbuilt's Employee Handbook skill pack.
- **We already have orchestration.** Goose is deliberately single-agent (manual session
  chaining); metaharness leaves orchestration to the host. Our workflow stack already fans out
  and gates — that is our edge, so adopting a harness that assumes we lack it would be a step
  backward.
- **Narrowness is the feature.** A general harness has to serve every repo and every host.
  Gibson serves a handful of known apps with a known worst case, which lets the protocol be
  specific — Stripe test mode, no schema mutation against shared-prod Neon, IDOR on attendee
  objects — where a general tool can only be generic.

The short version: we took their best ideas — autonomy tiers, reproducible recipes,
default-deny governance, injection hardening, provenance — and left behind the parts built for
a generality we do not need. The model is replaceable; **Gibson, the red-team discipline, is
the product.**

---

**Note for the Chatterbuilt side.** metaharness maps far more directly onto Chatterbuilt — a
branded harness product with a fleet, a learning loop, and MCP wiring — than onto Gibson.
Several metaharness patterns (cost-aware model routing, sandboxed self-improvement within
safety bounds, hardware isolation for untrusted peers, witness-signed fleet releases) deserve
their own evaluation there, tracked alongside chatterbuilt#268.
