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

**Typical human approvals you'll request (Ask Contract each time):**

1. Permission to open an adoption PR (CI + AGENTS section).
2. Permission to create labels / enable branch protection settings they control.
3. Approval of burn-down spending if tools/services are paid (G5).
4. Merge of the adoption PR.

---

## Step 1 — Harnessability audit (read-only)

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
- [ ] **Git/GitHub configure (required):**
      `scripts/git-configure.sh --audit --repo owner/name [--path <checkout>]`
      — **hard-stop adoption** while exit is non-zero (SAFE_DRIFT, OWNER_REQUIRED,
      UNKNOWN, or tool ERROR). Optional safe fix: `--dry-run` then `--apply` for
      labels / `gibson/` gitignore / squash + delete-branch-on-merge only.
      Branch protection, required checks, Environments, DCO app, Vercel
      Production Branch, secrets, and test-integrity live canaries are
      **Mark-owned** (report-only remediation; never applied by this script).
      Partial slice of issue #68 — does not close the issue alone.
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
4. Labels + gitignore + merge settings via
   `scripts/git-configure.sh --dry-run` then `--apply` when Mark approves the
   safe set: `tier-a`/`tier-b`/`tier-c`, `agent-claimed`, `blocked`,
   `gibson-halt`, `halt`; append `gibson/` to `.gitignore`; squash on,
   merge-commit and rebase off, delete-branch-on-merge on. Re-run `--audit`
   until exit 0 or only Mark-owned OWNER_REQUIRED items remain.

**Ask Contract example (labels / safe apply):**

| Field | Text |
|---|---|
| What I'm asking | Add a few labels on your GitHub project and set safe merge defaults so the AI team can mark work status. |
| What it does | Labels like "claimed" and "blocked" show which task an agent is working on so two agents don't collide; squash + delete-branch-on-merge keep history tidy. |
| Why | Prevents two workers from editing the same files at once (that once cost a full day of broken code). |
| Risks | Low. Labels are metadata only; merge-method toggles are reversible in GitHub settings; they never change your live site. Branch protection and Vercel stay Mark-owned. |

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

---

## Definition of adopted

| Check | Pass |
|---|---|
| Tier A issue | plan→issue→build→test→review→eval→merge→deploy→verified with **zero** human touches |
| Tier C issue | stops at **exactly** the human gates in docs/14, nowhere else |
| Deploy truth | Production Branch written from verified settings |
| Claims | active-work.md + labels live |
| Gate | CI gibson-gate green on a canary PR |

## Done means

- [ ] Adoption report filed
- [ ] Install PR merged (or awaiting human with clear card)
- [ ] Baseline + burn-down issues filed
- [ ] Canaries green (or scheduled with owners)
- [ ] "Adopted" only claimed when definition above holds
