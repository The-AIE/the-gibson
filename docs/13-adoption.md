---
title: "13 · Adopting a project"
parent: The Doctrine
nav_order: 13
---

# 13 — Adoption: Pointing The Gibson at a Repo

Adoption is itself an agent task with a playbook
([playbooks/adopt.md](../playbooks/adopt.md) — audit checklist inline). Fast path:
[QUICKSTART.md](../QUICKSTART.md). Target:
any repo, optimized for TypeScript/Next.js-on-Vercel, workable for anything with a
typecheck, a test runner, and a build.

Adoption is also where the fleet asks the user for the most: permissions, tokens,
settings changes, installs. **Every one of those asks follows the Ask Contract**
(AGENTS.md / doc 16): what I'm asking, what it does, why, and the risks — with
terminology explained inline and each step narrated. No bare commands, no
unexplained approvals, regardless of how technical the user seems.

## Step 1 — Harnessability audit (read-only)

Score the repo's ambient affordances before promising autonomy:

- [ ] Typed language / strict mode on
- [ ] Deterministic gate exists (typecheck + lint + test + build all runnable)
- [ ] Clear module boundaries; hot files identifiable
- [ ] Hand-edited barrels/nav that should be generated (de-hot candidates)
- [ ] Test framework present; E2E possible (Playwright installable)
- [ ] CI present; branch protection on
- [ ] Vercel wiring: which branch is REALLY the Production Branch (verify in
      project settings, not docs); preview deployments on
- [ ] Schema/migration model (Prisma? migration files? who applies to prod?)
- [ ] Secrets hygiene (.env* ignored, no committed secrets — run gitleaks once)

Alongside the repo audit, run the **deployment audit** (doc 17 inspect mode) —
its baseline numbers become the budgets the UX-eval and drift sensors enforce.

Output: an adoption report with a harnessability grade and a fix-list. Low-grade
repos get affordance-improvement issues *first* — autonomy on an illegible codebase
is how you buy incidents.

## Step 2 — Install the contract

1. Add the Gibson section to the target's `AGENTS.md` from
   `templates/target-repo/AGENTS-section.md` — repo-specifics only: hot files,
   gate commands, framework warnings (pinned-version gotchas), env/deploy truth,
   tier-C surface map. Doctrine stays in The Gibson; the target file *points*, it
   doesn't *copy*.
2. `CLAUDE.md` → `@AGENTS.md` if not already.
3. Create `docs/active-work.md` with the claim-table header.
4. Labels: `gibson`, `tier-a/b/c`, `agent-claimed`, `blocked`, `gibson-halt`.

## Step 3 — Install enforcement

From `ci/` and `templates/target-repo/`:

1. `gibson-gate.yml` — the green gate in CI (generate/typecheck/lint/test/build +
   claim-isolation check).
2. `security.yml` — layers 1–3 hard-fail wiring (gitleaks, Semgrep, audit/OSV);
   layer 4 route-inventory scaffold; ZAP baseline job against preview URL.
3. Playwright config + `tests/e2e/flows/` scaffold with preview-URL wiring.
4. Schema-guard workflow when a schema exists.
5. DCO check if the repo signs commits.

Calibrate, don't transplant: budgets (Lighthouse, size) start at Gibson defaults and
get tuned to the repo's reality in the adoption PR.

## Step 4 — Baseline and burn-down

Run every gate once. Everything that fails becomes the **baseline** — recorded, not
hidden. File burn-down issues (report-only → hard-fail promotion schedule per gate,
doc 08). The gates go hard-fail on *new* regressions immediately; on the whole
codebase when the burn-down completes.

## Step 5 — Wire the fleet

1. Register the repo in Mission Control (project name, workdir on each machine).
2. Verify each intended runtime can: clone, run the gate, reach MC. One canary
   issue per runtime (a real but Tier A task) proves the loop end-to-end.
3. Seed `memory/`: adoption report becomes the repo's first DECISIONS entries.

## Definition of adopted

A Tier A issue can go plan→issue→build→test→review→eval→merge→deploy→verified with
**zero human touches**, and a Tier C issue stops at exactly the human gates and
nowhere else.
