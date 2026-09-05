---
title: "Playbook · Adopt"
nav_exclude: true
role: adopt
inputs:
  - target repository (local path and/or GitHub remote)
  - Gibson clone path
  - intended runtimes (claude-code / codex / grok / hermes)
outputs:
  - adoption report (harnessability grade + fix-list)
  - PR(s) installing AGENTS section, labels, CI, Playwright scaffold, active-work.md
  - baseline failure record + burn-down issues
  - canary Tier A issue per runtime
gates:
  - every human ask uses the Ask Contract (what / does / why / risks)
  - no irreversible install without approval (PRs, not force-push)
  - low harnessability → affordance issues first, not full autonomy promises
forbidden:
  - transplanting CI without calibration
  - claiming "adopted" before Tier A flows end-to-end with zero human touches
sources:
  - docs/13-adoption.md
  - docs/17-deployment-optimization.md (inspect alongside audit)
  - docs/23-delivery-control.md
  - docs/16-nontechnical-operation.md
  - templates/target-repo/
  - ci/
  - scripts/delivery-control/
---

# Adopt — point The Gibson at a repository


> **Authority:** Conditionally mandatory dispatch prompt when this role/job is active. Binding commit/PR/merge rules live only in [`AGENTS.md`](../AGENTS.md). Frontmatter `gates:` / `forbidden:` / role outputs are routing mirrors of that contract and must not introduce obligations absent from AGENTS.md.

You are running **adoption**. Target: install doctrine + enforcement so a Tier A
issue can flow plan→…→verified deploy with zero human touches, and Tier C stops
only at documented human gates.

## How to use this

```bash
# Headless
grok -p "$(cat playbooks/adopt.md)

Target: ~/Code/acme-app
Remote: acme/acme-app
Gibson: ~/Code/the-gibson
Runtimes: grok, claude-code
"

# Or interactive: "Adopt the acme-app repo"
```

## Repository boundary

Follow the canonical boundary in
[docs/13](../docs/13-adoption.md#repository-boundary-and-user-journey): this is
one agent session with two repository roles.

- Treat the Gibson canonical checkout as a read-only harness source.
- Treat the target canonical checkout as a read-only audit source and worktree
  anchor.
- Make adoption changes only in a claimed, isolated worktree of the target repo.
- Open the adoption PR against the target repo, never against Gibson.
- Never copy the application into Gibson or edit application code there.

Starting the session in Gibson only loads this playbook. It does not change the
working-repository boundary, and it does not require a second agent session.

**Typical human approvals you'll request (Ask Contract each time):**

1. Permission to open an adoption PR (CI + AGENTS section).
2. Permission to create labels / enable branch protection settings they control.
3. Approval of burn-down spending if tools/services are paid (G5).
4. Merge of the adoption PR.

---

## Step 1 — Harnessability audit (read-only)

### Git/GitHub wiring (required)

Run the configurator **before** claiming the repo is adopted. It senses live settings
(not prose) — L-004 class:

```bash
<path-to-gibson>/scripts/git-configure.sh --audit --repo owner/name --path /path/to/checkout
# fix safe drift when ready:
<path-to-gibson>/scripts/git-configure.sh --dry-run --repo owner/name --path /path/to/checkout
<path-to-gibson>/scripts/git-configure.sh --apply  --repo owner/name --path /path/to/checkout
```

Hard-stop adoption on unresolved FAILs (missing labels, wrong merge methods,
gitignore without `gibson/` runtime state, required-check name drift, Vercel
production-branch contradiction). Branch protection changes are owner-only
(printed remediation; never auto-applied).


Score ambient affordances **before** promising autonomy. Output
`reports/adoption-<repo>-<date>.md`.

### Repo checklist (inline)

- [ ] Typed language / strict mode on
- [ ] Deterministic gate exists (typecheck + lint + test + build all runnable)
- [ ] Clear module boundaries; hot files identifiable
- [ ] Hand-edited barrels/nav that should be generated (de-hot candidates)
- [ ] Test framework present; E2E possible (Playwright installable)
- [ ] CI present; branch protection on
- [ ] Vercel wiring: **Production Branch verified in project settings**, not docs
- [ ] Preview deployments on
- [ ] **Delivery control** (docs/23): `scripts/delivery-control/audit.sh --repo owner/name`
      — P0 fix-list if production write path is unprotected
- [ ] Schema/migration model documented (who applies to prod?)
- [ ] Secrets hygiene (`.env*` ignored; gitleaks clean once; secret rotation = G4 only)

### Deployment audit (doc 17 inspect)

Run inspect mode (or `scripts/deploy-audit.sh` when credentials exist). Baseline
numbers become UX-eval and drift budgets.

### Grade

| Grade | Meaning | Next |
|---|---|---|
| **A** | Gate runnable, boundaries clear, CI/deploy truth known | Proceed install |
| **B** | Gaps fixable in adoption PR | Install + file affordance issues |
| **C** | Illegible / no tests / no gate | Affordance issues **first**; limited autonomy only |

Low-grade repos get affordance-improvement issues first — autonomy on an illegible
codebase buys incidents.

---

## Step 2 — Install the contract

Present each change as a PR (Ask Contract before merge).

1. Append Gibson section from `templates/target-repo/AGENTS-section.md` —
   **repo-specifics only** (hot files, gate commands, framework warnings, deploy
   truth, Tier C map). Doctrine stays in Gibson; target *points*, doesn't *copy*.
2. `CLAUDE.md` → `@AGENTS.md` if missing.
3. Create `docs/active-work.md` with claim-table header:
   ```markdown
   # Active work (claims)

   | UTC | claim | scope | session |
   |---|---|---|---|
   ```
4. Labels: `gibson`, `tier-a`, `tier-b`, `tier-c`, `agent-claimed`, `blocked`,
   `gibson-halt`.

**Ask Contract example (labels):**

| Field | Text |
|---|---|
| What I'm asking | Add a few labels on your GitHub project so the AI team can mark work status. |
| What it does | Labels like "claimed" and "blocked" show which task an agent is working on so two agents don't collide. |
| Why | Prevents two workers from editing the same files at once (that once cost a full day of broken code). |
| Risks | Low. Labels are metadata only; removable any time; they never change your live site. |

---

## Step 3 — Install enforcement

From Gibson `ci/` and `templates/target-repo/`:

1. `.github/workflows/gibson-gate.yml` — green gate + security layers 1–3.
2. `security.yml` — authz/DAST/posture as repo matures.
3. Playwright config + `tests/e2e/flows/` with `BASE_URL` preview wiring.
4. `schema-guard.yml` when a schema exists.
5. DCO check if the org signs commits.

**Calibrate, don't transplant:** Lighthouse/size budgets start at Gibson defaults,
then tune to measured baseline from Step 1.5.

---

## Step 4 — Baseline and burn-down

```bash
# In target worktree after install
<path-to-gibson>/scripts/gate-baseline.sh
<path-to-gibson>/scripts/gate.sh   # expect failures on legacy debt
```

Record failures as **baseline**, not shame. File burn-down issues with promotion
schedule (report-only → hard-fail per docs/08). New regressions hard-fail
immediately; whole-codebase hard-fail when burn-down completes.

---

## Step 5 — Wire the fleet

1. Register repo in Mission Control (project name, workdir per machine).
2. Verify each runtime can: clone, run gate, reach MC.
3. **Canary:** one real Tier A issue per runtime through the full pipeline.
4. Seed memory: adoption report → first DECISIONS entries (fork or target as
   appropriate).

## Step 6 — Hand off the day-to-day operating model

End adoption with an owner-facing handoff that names both paths and makes the
working boundary unambiguous:

1. **Interactive command or prompt:** open the target as the workspace and name
   the Gibson checkout as the harness unless an adapter injects it already.
2. **Unattended command:** give the exact
   `<gibson>/scripts/loop.sh --repo <target> --repo-slug <owner/repo>` form for
   the installed runtime.
3. **Where truth lives:** product issues, claims, pull requests, CI, and deploy
   evidence live with the target; reusable doctrine and launch scripts live with
   Gibson.
4. **Where work happens:** all application mutations remain in target-repo
   worktrees, never either canonical checkout.
5. **How to add another repo:** repeat adoption against the new target using the
   same Gibson checkout unless the owner intentionally selects another fork or
   policy version.

Do not report adoption complete while leaving the user with the impression that
future application work starts by editing or developing inside the Gibson repo.

---

## Definition of adopted

| Check | Pass |
|---|---|
| Tier A issue | plan→issue→build→test→review→eval→merge→deploy→verified with **zero** human touches |
| Tier C issue | stops at **exactly** the human gates in AGENTS.md, nowhere else |
| Deploy truth | Production Branch written from verified settings |
| Claims | active-work.md + labels live |
| Gate | CI gibson-gate green on a canary PR |

## Done means

- [ ] Adoption report filed
- [ ] Install PR merged (or awaiting human with clear card)
- [ ] Baseline + burn-down issues filed
- [ ] Canaries green (or scheduled with owners)
- [ ] "Adopted" only claimed when definition above holds
