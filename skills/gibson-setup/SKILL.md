---
name: gibson-setup
description: "Wire a repository for autonomous fleet development: install the Gibson guardrail bundle (AGENTS section, CI gates, labels, branch protection, kill switch) and connect the Devin cloud supervisor as merge captain. Consumes gibson-audit's gap list; idempotent. Third stage of the /gibson pipeline; also standalone ('set up this repo for the fleet', 'gibson-ify this repo', 'install the guardrails')."
---

# gibson-setup — teeth, not just prose

An `AGENTS.md` alone is policy in prose; agents drift from it and nothing
notices. This skill installs the ENFORCEMENT bundle so the rules are checked by
machines. Source of truth: `templates/target-repo/` in the Gibson clone —
extend that template dir when it's missing something, so the next repo gets it
for free (Law 10: leave the harness better than you found it).

## Install checklist (drive from the audit's gap list; skip what exists)

1. **AGENTS section** — append `templates/target-repo/AGENTS-section.md` to the
   target's `AGENTS.md` (create if absent). Never overwrite existing content.
2. **CI gates** — test/lint/typecheck/build on every PR, as required checks.
   Reuse the repo's existing CI if present; add the missing jobs only.
3. **Risk classifier** — Tier-C auto-labeling for money/auth/PII/schema paths
   (pattern: conference-os `scripts/pr-risk-classifier.mjs` — port the concept,
   tune path patterns to THIS repo's layout from the audit's risk-surface map).
4. **Review-evidence gate** — PRs need independent review evidence before
   merge; owner attestation path for humans; trusted-provider list for bots
   (Devin's App belongs here IF the owner approves — that file is a security
   boundary, adding to it is always an explicit owner decision, never implied).
5. **Labels + kill switch** — `agent-claimed`, `gibson-halt`, tier labels.
6. **Branch protection** — required checks + no force-push on the default
   branch. Needs owner-level auth; if unavailable, emit the exact settings as
   an Ask Contract item instead of failing silently.
7. **DCO/sign-off** convention if the repo wants it.
8. **Devin supervisor wiring** — `scripts/devin-supervisor.sh ensure --repo <path>`
   (needs `DEVIN_API_KEY`; recommend `DEVIN_MAX_ACU` cap). Optional webhook wake
   per `adapters/devin/README.md`. Devin = merge captain: reviews finished
   branches, owns PRs/merges. Tier C still ends at the human gate (Law 7).

## Rules

- **Idempotent**: re-running against an already-wired repo changes nothing and
  says so. Diff-then-write, never blind-write.
- **Right-sized**: a static site doesn't need the full Tier-C machinery. Install
  the lean baseline everywhere; add the heavy layer only where the audit found
  real risk surfaces. Say which profile you chose and why.
- Every owner-credential step (branch protection, App installs, API keys) is an
  Ask Contract item — batched, never a drip.
- Commit the wiring via a normal PR to the target repo, reviewed cross-vendor
  like any other change. Setup is not exempt from the rules it installs.
