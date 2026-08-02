---
title: "13 · Adopting a project"
parent: The Doctrine
nav_order: 13
---

# 13 — Adoption: Pointing The Gibson at a Repo

> 🙂 **In plain English:** Pointing this system at your project is itself a guided job:
> check how ready the project is, install the rule files and safety nets, then run a
> small practice task before trusting the full crew.

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
6. `scripts/preview-url.sh` **and** `scripts/ux-surface.sh` — the UX and DAST
   jobs need both. Without the surface filter every PR is treated as
   UI-affecting; without the preview resolver a UI PR fails closed.

### Preview access (do this at adoption, not at the first red gate)

UX eval, ZAP, and the posture probe all target the **preview deployment**. If the
preview is unreachable, those jobs now fail rather than skipping green — a missing
result is not a pass (L-012). Two settings decide whether they can reach it:

| Setting | Where | Why |
|---|---|---|
| `VERCEL_AUTOMATION_BYPASS_SECRET` | repo secret; value from Vercel → Project → Settings → Deployment Protection | Without it, every CI request to a protected preview gets a 401 login page, and any gate that "passes" against it is lying |
| Preview deployments enabled for PRs | Vercel project | No deployment, no target |

**Which files count as user-visible** is a per-repo question. The defaults assume a
conventional `app/` `components/` `public/` layout; a repo shaped differently adds
`.gibson/ux-surface.conf` (one regex per line, `!` prefix for exceptions). Get this
wrong in the permissive direction and you have silently switched the UX gate off for
those paths — so verify with `scripts/ux-surface.sh --diff main` on a known UI PR
before trusting it.

Calibrate, don't transplant: budgets (Lighthouse, size) start at Gibson defaults and
get tuned to the repo's reality in the adoption PR.

## Step 4 — Baseline and burn-down

Run every gate once. Everything that fails becomes the **baseline** — recorded, not
hidden. File burn-down issues (report-only → hard-fail promotion schedule per gate,
doc 08). The gates go hard-fail on *new* regressions immediately; on the whole
codebase when the burn-down completes.

**A promotion to hard-fail is not done until the promoted path has run.** Static
sensors — a test that greps the workflow yaml, a baseline file that says the flow is
now required — go green whether or not the job ever executed. That is exactly how a
Playwright suite was promoted to hard-fail and merged while CI skipped it every
single run (L-011). Close a burn-down issue only when one of these is true, and say
which on the issue:

- one CI run executed the promoted path and was green (link the run), or
- an explicit, dated deferral is recorded with the local/prod evidence standing in
  for it.

`gibson-ux-eval` now annotates every run where the contract flows did not execute,
so "it looked green" stops being available as an answer.

## Step 5 — Wire the fleet

1. Register the repo in Mission Control (project name, workdir on each machine).
2. Verify each intended runtime can: clone, run the gate, reach MC. One canary
   issue per runtime (a real but Tier A task) proves the loop end-to-end.
3. Seed `memory/`: adoption report becomes the repo's first DECISIONS entries.

## Definition of adopted

A Tier A issue can go plan→issue→build→test→review→eval→merge→deploy→verified with
**zero human touches**, and a Tier C issue stops at exactly the human gates and
nowhere else.

---
[← 12 · Shipping to Vercel safely](12-vercel.md) · [Home](../index.md) · [14 · The sixteen interruptions →](14-human-gates.md)
