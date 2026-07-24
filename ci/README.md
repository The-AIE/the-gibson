# ci/ — reusable workflow templates

Installed into target repos at adoption ([docs/13](../docs/13-adoption.md)),
calibrated per repo. **Principle:** CI is vendor-blind enforcement
([docs/10](../docs/10-vendor-adapters.md)) — it does not care which runtime wrote
the code.

## Templates

| File | Job | Spec |
|---|---|---|
| [`gibson-gate.yml`](gibson-gate.yml) | Green gate + security layers 1–3 (gitleaks, Semgrep, npm audit) | [docs/06](../docs/06-quality-gates.md), [docs/08](../docs/08-security.md) |
| [`security.yml`](security.yml) | Layers 4 (authz matrix), 5 (ZAP baseline vs. preview), 8 (posture); nightly full DAST vs. **staging** | docs/08 |
| [`ux-eval.yml`](ux-eval.yml) | Playwright contract flows + axe + Lighthouse against PR preview URL | [docs/07](../docs/07-uiux-evaluation.md) |
| [`schema-guard.yml`](schema-guard.yml) | Schema diff without migration file fails; bans destructive migrate flags | [docs/12](../docs/12-vercel.md), L-002 |
| [`retro.yml`](retro.yml) | Weekly exhaust → artifact (+ optional issue) for historian | [docs/09](../docs/09-memory-and-self-improvement.md) |

## How to install

```bash
# From target repo
mkdir -p .github/workflows
cp /path/to/the-gibson/ci/gibson-gate.yml .github/workflows/
# Fill <angle> placeholders in gibson-gate.yml from target AGENTS.md gate commands
cp /path/to/the-gibson/ci/security.yml .github/workflows/
cp /path/to/the-gibson/ci/ux-eval.yml .github/workflows/
# If schema exists:
cp /path/to/the-gibson/ci/schema-guard.yml .github/workflows/
cp /path/to/the-gibson/ci/retro.yml .github/workflows/
```

**Also vendor scripts the workflows call** (or submodule / copy into `scripts/`):

- `preview-url.sh`, `posture-probe.sh`, `route-inventory.mjs`

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
