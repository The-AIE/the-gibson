---
name: gibson-audit
description: "Audit any repository for Gibson-readiness: what the product is, stack, test/CI/gate coverage, backlog shape, risk surfaces (money/auth/PII), and a plain-English readiness report with concrete gaps. First stage of the /gibson pipeline; also useful standalone ('audit this repo', 'is this repo ready for the fleet', 'gibson readiness check')."
---

# gibson-audit — know the repo before touching it

Input: a repo path or GitHub URL (clone to a scratch location if URL-only).
Output: a readiness report the owner can read without knowing how to code, plus
a machine-usable gap list the `gibson-setup` skill consumes.

## What to inspect (read-only — this skill NEVER mutates the target)

1. **Product identity** — README, package.json/pyproject, deployed URLs. One
   paragraph: what this software does, for whom.
2. **Stack + build reality** — language, framework, how to build/test/run.
   Actually run the test suite if cheap; report pass/fail truthfully.
3. **Guardrails present vs missing** — checklist against the Gibson baseline:
   - `AGENTS.md` (or section) with fleet rules?
   - CI running tests on PRs? Required checks configured?
   - Branch protection on the default branch?
   - Risk classifier / Tier-C gating (money/auth/PII paths)?
   - DCO or sign-off convention?
   - Secrets hygiene (gitleaks or equivalent)?
   - Kill switch (`gibson/HALT` support comes free with the loop)?
4. **Backlog shape** — open issues: how many are well-scoped with acceptance
   criteria vs vague? Is there a plan doc? (No usable backlog → the pipeline
   must run `gibson-direct` before `gibson-run`.)
5. **Risk surfaces** — grep for payment/auth/PII/schema code. These paths get
   Tier-C treatment (Law 7) regardless of what the repo's own docs say.
6. **Deployment posture** — if a live/preview URL exists, run
   `scripts/posture-probe.sh <url>` from the Gibson clone for headers/cookies/
   rate-limit reality. Preview/staging only — never burst production.

## Report format

Two parts, always both:
- **For the owner (plain English, Ask Contract style):** what the repo is, how
  healthy it is, what's missing before agents can safely run unattended, and
  anything that genuinely needs their decision. No jargon unexplained.
- **`gibson/audit.md` gap list (machine part):** checkbox list of missing
  guardrails with the exact `gibson-setup` action for each. Write it into the
  target repo's `gibson/` dir only if asked to persist; otherwise return inline.

Truthfulness rule (Law 8): report what IS, including pre-existing test failures
and scary findings. Never soften a gap because it's awkward.
