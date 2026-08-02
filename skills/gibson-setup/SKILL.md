---
name: gibson-setup
description: "Wire a repository for autonomous fleet development: install the Gibson guardrail bundle (AGENTS section, CI gates, labels, branch protection, kill switch) and connect the Devin cloud supervisor as merge captain. Consumes gibson-audit's gap list; idempotent. Third stage of the /gibson pipeline; also standalone ('set up this repo for the fleet', 'gibson-ify this repo', 'install the guardrails')."
---

# gibson-setup — teeth, not just prose

An `AGENTS.md` alone is policy in prose; agents drift from it and nothing
notices. This skill installs the ENFORCEMENT bundle so the rules are checked by
machines. Source of truth: `templates/target-repo/` in the Gibson clone (currently thin —
one file — plus the `ci/` workflows; be honest about that). When a target repo
needs something the templates lack, write it for the target, then contribute
the generalized version back to the Gibson **via a normal worktree branch + PR
(Law 3: never edit the canonical clone directly)** so the next repo gets it
for free.

## Install checklist (drive from the audit's gap list; skip what exists)

1. **AGENTS section** — append `templates/target-repo/AGENTS-section.md` to the
   target's `AGENTS.md` (create if absent). Never overwrite existing content.
2. **CI gates** — test/lint/typecheck/build on every PR, as required checks.
   Reuse the repo's existing CI if present; add the missing jobs only.
   **Verify every referenced script actually exists before installing any
   workflow from `ci/`** — e.g. `ci/gibson-gate.yml` currently references
   `scripts/check-active-work.mjs`, which does not exist in the Gibson repo
   (tracked issue): installed blind, every target PR fails module-not-found.
   Vendor or stub each referenced script, or trim the job.
3. **Risk classifier** — Tier-C auto-labeling for ALL Law 7 categories: money,
   auth, consent/PII, security boundaries, production data (schema/migrations
   included). Start from the Gibson's own `ci/` workflows; where a needed gate
   has no template yet, port the concept from a proven external implementation
   (e.g. conference-os's risk classifier — lives in that repo, not this one)
   and contribute the generalized version back via PR (see rule below).
4. **Review-evidence gate** — PRs need independent review evidence before
   merge; owner attestation path for humans; trusted-provider list for bots
   (Devin's App belongs here IF the owner approves — that file is a security
   boundary, adding to it is always an explicit owner decision, never implied).
   **No local template for this exists yet** — port it from a proven external
   implementation and contribute the generalized version back (rule below).
   Until installed, say plainly the repo has no machine-checked review gate.
5. **Labels + kill switch** — `agent-claimed`, tier labels, and `gibson-halt`.
   The label is SIGNAL-ONLY: `loop.sh` checks the `gibson/HALT` file, not
   labels. Either also install the small translation workflow (label applied →
   touch `gibson/HALT`) or state plainly that the label is unwired and humans
   must create the HALT file to actually stop the fleet.
6. **Branch protection** — required checks + no force-push on the default
   branch. Needs owner-level auth; if unavailable, emit the exact settings as
   an Ask Contract item instead of failing silently.
7. **DCO/sign-off** convention if the repo wants it.
8. **Devin supervisor wiring** — `scripts/devin-supervisor.sh ensure --repo <path>`
   **creates a billed cloud session if none exists (ACUs = real money): this is
   an owner-gated step, always. Ask Contract first, run only on an explicit
   yes** (needs `DEVIN_API_KEY`; set `DEVIN_MAX_ACU` as the cap). Optional
   webhook wake per `adapters/devin/README.md`. Devin = merge captain: reviews
   finished branches and owns PRs; it merges only in the explicit `--merge`
   handoff mode (docs/22) — the default leaves every merge to a human. Tier C
   ends at the human gate in every mode (Law 7).

## Rules

- **Idempotent**: re-running against an already-wired repo changes nothing and
  says so. Diff-then-write, never blind-write.
- **Right-sized, never under-gated**: install the lean baseline everywhere; add
  the heavy machinery where the audit found risk surfaces. But Law 7 is not
  profile-dependent — if ANY money/auth/consent/PII/security/prod-data surface
  exists, its human merge gate gets wired regardless of chosen profile. A
  static brochure site with a contact form still has a PII surface.
- Every owner-credential step (branch protection, App installs, API keys) is an
  Ask Contract item — batched, never a drip.
- Commit the wiring via a normal PR to the target repo, reviewed cross-vendor
  like any other change. Setup is not exempt from the rules it installs.
