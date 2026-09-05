# ci/ — reusable workflow templates

Installed into target repos at adoption ([docs/13](../docs/13-adoption.md)),
calibrated per repo. **Principle:** CI is vendor-blind enforcement
([docs/10](../docs/10-vendor-adapters.md)) — it does not care which runtime wrote
the code.

## Templates

| File | Job | Spec |
|---|---|---|
| [`gibson-gate.yml`](gibson-gate.yml) | Green gate + security layers 1–3 + **protected test-integrity** (four isolated jobs; unique required check `test-integrity`) | [docs/06](../docs/06-quality-gates.md), [docs/08](../docs/08-security.md), issue #70 |
| [`security.yml`](security.yml) | Layers 4 (authz matrix), 5 (ZAP baseline vs. preview), 8 (posture); nightly full DAST vs. **staging** | docs/08 |
| [`ux-eval.yml`](ux-eval.yml) | Playwright contract flows + axe + Lighthouse against PR preview URL | [docs/07](../docs/07-uiux-evaluation.md) |
| [`schema-guard.yml`](schema-guard.yml) | Schema diff without migration file fails; bans destructive migrate flags. The `forbid-destructive-flags` job creates a **new required-check context** — add it to branch protection or a red run will not block merges. | [docs/12](../docs/12-vercel.md), L-002 |
| [`retro.yml`](retro.yml) | Weekly exhaust → artifact (+ optional issue) for historian | [docs/09](../docs/09-memory-and-self-improvement.md) |

## How to install

```bash
# From target repo
mkdir -p .github/workflows
cp /path/to/the-gibson/ci/gibson-gate.yml .github/workflows/
# Calibrate gibson-gate.yml:
#   1. Fill <generate>/<typecheck>/<lint>/<test>/<build> in the gate job
#   2. Set TEST_COMMAND on BOTH test-integrity-base and test-integrity-head
#      to the SAME literal as the gate job test step (e.g. npx vitest run).
#      Never point TEST_COMMAND at .agents/gate.json — that path is PR-head controlled.
#   3. Vendor scripts/test-integrity.mjs, scripts/check-active-work.mjs, scripts/pr-size.mjs
#      (+ config/pr-size.v1.json) into the target
cp /path/to/the-gibson/ci/security.yml .github/workflows/
cp /path/to/the-gibson/ci/ux-eval.yml .github/workflows/
# If schema exists:
cp /path/to/the-gibson/ci/schema-guard.yml .github/workflows/
cp /path/to/the-gibson/ci/retro.yml .github/workflows/
```

## Check copied-template drift

After copying one or more `ci/*.yml` workflows, run:

```bash
/path/to/the-gibson/scripts/gibson-template-drift.sh \
  --gibson /path/to/the-gibson \
  --repo /path/to/your-repo
```

The check covers shipped `ci/*.yml` workflows only; it does not stamp target
repo JSON templates or adapter plists. A copied workflow with a missing,
invalid, or stale content-hash stamp exits 1. Templates that the adopter did
not install are reported but do not fail by default, because adopters may use a
subset. Add `--strict-missing` when the adopter requires the complete template
set and wants any missing workflow to exit 1.

**Also vendor scripts the workflows call** (or submodule / copy into `scripts/`):

- `test-integrity.mjs` (required for protected test-integrity grading)
- `check-active-work.mjs` (claim isolation on the green-gate job)
- `pr-size.mjs` + `config/pr-size.v1.json` (PR-size budget; label `size-exception` = owner sign-off)
- `preview-url.sh`, `posture-probe.sh`, `route-inventory.mjs`

### Protected test-integrity (issue #70) — inert until #68 activates it

`gibson-gate.yml` includes four jobs that never grade with PR-head code:

| Job | Role |
|---|---|
| `test-integrity-resolve` | Exact SHAs + unique `merge-base --all` (fail closed on criss-cross); prove helper is a regular blob at merge-base |
| `test-integrity-base` | Capture suite output at merge-base (separate runner) |
| `test-integrity-head` | Capture suite output at head SHA from head repo (forks included) |
| `test-integrity` | Unique required-check name; `always()`; compare with merge-base helper + inert PR-body waiver file |

**Installing the file is not protection.** Live required-check / branch-protection
audit and apply are owner-owned under **issue #68**. Do not call a target
protected until the #68 canaries pass (no-change pass, deletion fail, skip fail,
exact waiver pass, hostile-helper fail, failing-base deletion fail,
missing-artifact fail, workflow-file modification protection).

**Out of scope for agents / this template:** enabling the required check, branch
protection, rulesets, bypass actors, fork policy, merge-queue policy, credentials,
and canaries — all Mark-owned under #68. **Merge queues:** do not enable a merge
queue against this template until equivalent `merge_group` support is implemented
and canaried.

### Repo variables / secrets

| Name | Used by | Purpose |
|---|---|---|
| `vars.STAGING_URL` | security.yml nightly | Full ZAP target — **never prod** |
| `vars.RETRO_OPEN_ISSUE` | retro.yml | `true` to auto-open weekly issue |
| `secrets.VERCEL_TOKEN` | optional preview helpers | Scoped read token if GitHub deployment events are insufficient |

## Calibration (do not transplant blindly)

1. Run every workflow once on a canary PR.
2. Record failures as **baseline burn-down** issues (docs/13 Step 4).
3. Hard-fail **new** regressions immediately; whole-codebase hard-fail when burn-down
   completes.
4. Lighthouse budgets start at docs/07 defaults; tune from deploy-audit baselines
   (docs/17).

## Ask Contract (enabling CI on a human's repo)

| Field | Text |
|---|---|
| **What I'm asking** | Add automatic safety checkers that run on every proposed change. |
| **What it does** | GitHub runs tests, security scans, and (for UI) checks a private preview link before merge. |
| **Why** | Nothing reaches the live site without inspection — including work done while you sleep. |
| **Risks** | Low–medium: misconfigured checks can block merges (red X). Removable by deleting the workflow files. Never edits production by itself. |
