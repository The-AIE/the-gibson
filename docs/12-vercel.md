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

**Delivery control:** locking the git/GitHub write path (protection, reviews,
strict checks, Production env) is [docs/23-delivery-control.md](23-delivery-control.md).
Run `scripts/delivery-control/audit.sh` at adoption and before promotes.

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


## Preview database isolation (Neon branch per Vercel preview)

> Target-side doctrine (from ConferenceOS #934/#678, tracked as Gibson #108).
> Mechanism is generic; first target was `mrhinkle/conference-os`.

### Problem

Shared nonprod databases serialize schema PRs, contaminate previews, and make
`prisma migrate deploy` on a preview a fleet-wide footgun. A green preview that
shared state with another PR is not evidence.

### Pattern

1. **Neon branch per Vercel preview** — Neon’s native Vercel integration (or
   equivalent) creates an ephemeral database branch from the parent (prod or
   staging schema) for each preview deployment.
2. **`DATABASE_URL` is preview-scoped** — injected by the integration; never a
   shared nonprod URL in the Preview environment.
3. **Migrate on the branch** — preview build runs `prisma migrate deploy` (or
   equivalent) against *that* branch only. Schema PRs prove real migrate deploy
   before merge.
4. **Lifecycle** — branch deleted when the Vercel preview / PR is closed (Neon
   integration default, or a cleanup workflow). Stale preview pileup includes
   DB cost — reaper previews and branches together.
5. **Prod is never the parent for experimental data** — parent is a staging
   snapshot or a schema-only baseline when PII is in scope.

### Adoption checklist (target repo)

- [ ] Neon project linked to the Vercel project (Preview env).
- [ ] Preview env has no long-lived shared `DATABASE_URL`.
- [ ] Build/install command runs migrate against the preview branch URL.
- [ ] Schema-guard CI still hard-fails schema-without-migration (L-002).
- [ ] Documented in the target `AGENTS.md` under Deploy / Preview DB.
- [ ] Cost note: ephemeral branches are metered — close stale PRs (preview
      pileup sensor if present).

### What stays in Gibson vs the target

| Layer | Owner |
|-------|--------|
| Doctrine + checklist (this section) | Gibson |
| Neon↔Vercel integration wiring | Target (per project) |
| Schema-guard workflow | Target CI (template in `ci/`) |
| Merge-queue serialization | Optional; isolation removes the *need* to serialize on DB |

### Non-goals

- Gibson does not host Neon credentials or create branches itself.
- Not a substitute for Tier C human review of money/auth/PII schema.


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
[← 11 · One agent, running all night](11-solo-loop.md) · [Home](../index.md) · [13 · Adopting a project →](13-adoption.md) · [20 · Delivery control](23-delivery-control.md)
