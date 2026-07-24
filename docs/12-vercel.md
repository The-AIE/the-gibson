---
title: "12 · Shipping to Vercel safely"
parent: The Doctrine
nav_order: 12
---

# 12 — Vercel Deployment Doctrine

> 🙂 **In plain English:** The preferred host is Vercel because every proposed change
> gets its own temporary website for testing. That free preview is how the crew tries
> things before they touch the real site.

The Gibson targets software deployed to Vercel. Vercel's model is also load-bearing
for the harness itself: **per-PR preview deployments are what make deployment-driving
UX evaluation (doc 07) and DAST (doc 08) free.**

## Environments

| Env | Branch | Purpose | Gibson usage |
|---|---|---|---|
| Preview | every PR | ephemeral, prod-like build per push | UX eval target, ZAP baseline target, posture probe |
| Staging | `main` (or `staging`) | integration surface | nightly active DAST, load tests |
| Production | `release` (target model) | users | smoke only; never active-scanned, never test-written without seeded data discipline |

**Branch-model honesty:** document what is *actually* wired, not the aspiration.
ConferenceOS's lesson: RELEASING.md described `release`→prod while Vercel's
Production Branch was `main` — so every main merge was a silent prod deploy. At
adoption (doc 13), verify the Production Branch setting and write the true model
into the target's AGENTS.md. If merge-to-main deploys prod, the merge gate IS the
deploy gate and inherits its weight.

## Deploy verification (release role)

1. Deployment exists for the expected commit SHA (`vercel inspect` / API).
2. State reaches READY (a merge that never deploys is a failure, not a skip).
3. Post-deploy smoke: contract-flow Playwright happy paths against the deployed URL
   (doc 07), plus the runtime posture probe (doc 08).
4. Failure → mechanical remediation (retry, redeploy) if mechanical; escalate with
   logs if judgment-shaped. Rollback = promote the previous READY deployment
   (instant on Vercel), then diagnose in a worktree — never debug in prod.

## Database schema safety (the sharpest edge)

For repos where deploys apply schema (Prisma + Neon/Postgres pattern):

- **Additive-only** schema changes; one schema claimant fleet-wide; models named in
  the claim; human gate on merge (docs 05, 06).
- The build script guards the apply: diff the deployment's environment-scoped
  `DATABASE_URL`, **reject destructive or unknown SQL and required-fields-on-
  existing-tables**, apply only approved additive drift. Never `--accept-data-loss`,
  never `--force-reset`.
- Schema-PR-without-migration-file = CI failure (schema-guard workflow), preventing
  the drift class that once blocked ~20 consecutive deploys.
- Migration history: production uses replayable migrations (`migrate deploy`), and
  the migration-replay diff check keeps history ⇄ schema honest.

## Env vars & secrets

- Set via Vercel envs (or `vercel env`), never committed; preview envs get
  non-production credentials — a preview deployment is a *semi-public* URL and gets
  scanned by our own DAST; treat its secrets accordingly.
- `DATABASE_URL` is environment-scoped; agents never read one env's value into
  another's context.

## Cost/hygiene sensors

Drift sensors (doc 06) include: Lighthouse budgets against production, deployment
failure-rate trend, and preview-deployment pileup (stale PRs holding previews open —
close or draft them).

---
[← 11 · One agent, running all night](11-solo-loop.md) · [Home](../index.md) · [13 · Adopting a project →](13-adoption.md)
