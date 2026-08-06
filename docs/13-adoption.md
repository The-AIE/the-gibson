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

Required sensor: `scripts/git-configure.sh --audit --repo owner/name --path <checkout>`
(issue #68). Reports live Git/GitHub/Vercel wiring vs Gibson contract. `--apply`
only mutates reversible settings (labels, `.gitignore` gibson/ state, squash +
delete-branch-on-merge). Protection / production-branch / DCO remain owner gates.


Score the repo's ambient affordances before promising autonomy:

- [ ] Typed language / strict mode on
- [ ] Deterministic gate exists (typecheck + lint + test + build all runnable)
- [ ] Clear module boundaries; hot files identifiable
- [ ] Hand-edited barrels/nav that should be generated (de-hot candidates)
- [ ] Test framework present; E2E possible (Playwright installable)
- [ ] CI present; branch protection on
- [ ] Vercel wiring: which branch is REALLY the Production Branch (verify in
      project settings, not docs); preview deployments on
- [ ] **Delivery control** ([docs/23](23-delivery-control.md)): run
      `scripts/delivery-control/audit.sh --repo owner/name` — fail or P0 the
      fix-list if the production write path is unprotected (`enforce_admins`,
      required reviews, strict checks, prod branch protection in model B)
- [ ] Schema/migration model (Prisma? migration files? who applies to prod?)
- [ ] Secrets hygiene (.env* ignored, no committed secrets — run gitleaks once)

Alongside the repo audit, run the **deployment audit** (doc 17 inspect mode) —
its baseline numbers become the budgets the UX-eval and drift sensors enforce.

Output: an adoption report with a harnessability grade and a fix-list. Low-grade
repos get affordance-improvement issues *first* — autonomy on an illegible codebase
is how you buy incidents.

## Step 2 — Install the contract (harness-neutral)

The target repo does **not** become a Gibson repo. It publishes an *autonomous
development contract* — the facts a machine needs to work here safely — and The
Gibson is one of several harnesses that can read it. A bare Claude Code session,
a Codex run, or a harness that does not exist yet gets the same affordances. The
coupling points one way: Gibson knows about the repo, the repo knows nothing
about Gibson.

Why that way round: a target that names its harness rots the moment you change
harnesses, and it teaches every passing agent a vocabulary it has no way to look
up. Repo facts age with the repo; process doctrine ages with the harness. Keep
them in separate files owned by separate repos.

1. Add the *Autonomous development contract* section to the target's `AGENTS.md`
   from `templates/target-repo/AGENTS-section.md` — repo-specifics only: gate
   commands, ground rules, hot files, framework warnings (pinned-version
   gotchas), deploy truth, the human-only action list, commit conventions. No
   harness name, no vendor name, no link into this repo's doctrine.
2. Copy `templates/target-repo/gate.json` to the target's `.agents/gate.json` —
   the machine-readable twin of the gate commands. `scripts/gate.sh` and
   `scripts/gate-baseline.sh` read it (falling back to the legacy
   `.gibson-gate.json` for repos adopted before the split).
3. `CLAUDE.md` → `@AGENTS.md` if not already.
4. Give the repo a claim mechanism if it has none, and name it in the contract —
   a `docs/active-work.md` table, or open-PR-body claims for repos that already
   coordinate through GitHub. Whatever the repo already does wins.
5. Labels: `tier-a/b/c`, `agent-claimed`, `blocked`, `halt`. Prefix them only if
   the repo needs to distinguish fleets.

Gibson-side state (`gibson/loop-state.md`, `gibson/journal.md`, `gibson/HALT`)
is created by the loop at runtime and is the *harness's* footprint, not the
repo's contract. Gitignore it in the target unless the team wants the journal.

## Step 3 — Install enforcement

From `ci/` and `templates/target-repo/`:

1. `gibson-gate.yml` — the green gate in CI (generate/typecheck/lint/test/build +
   claim-isolation check). Rename it on the way in if the target should stay
   vendor-neutral in its Actions tab; nothing depends on the filename.
2. `security.yml` — layers 1–3 hard-fail wiring (gitleaks, Semgrep, audit/OSV);
   layer 4 route-inventory scaffold; ZAP baseline job against preview URL.
3. Playwright config + `tests/e2e/flows/` scaffold with preview-URL wiring.
4. Schema-guard workflow when a schema exists.
5. DCO check if the repo signs commits.
6. Optional `.gibson-delivery.json` from
   `templates/target-repo/gibson-delivery.json` (branch model + required check
   context names). Harden only with operator apply approval:
   `scripts/delivery-control/apply-branch-protection.sh --apply`.
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
[← 12 · Shipping to Vercel safely](12-vercel.md) · [Home](../index.md) · [14 · The sixteen interruptions →](14-human-gates.md) · [20 · Delivery control](23-delivery-control.md)
