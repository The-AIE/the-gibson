# scripts/ — deterministic harness tooling

No-model by design ([docs/15](../docs/15-model-economics.md): "no-model checks stay
no-model"). POSIX bash + plain Node. **No package dependencies.** Every script
prints Ask-Contract style help via `--help` (what / why / risks / examples).

## Inventory

| Script | Contract |
|---|---|
| [`claim.sh`](claim.sh) `<issue> <slug> <scope…>` | Atomic claim: `agent-claimed` label → verify no live-claim overlap in `docs/active-work.md` → append claim row, commit `-s` to main, push → create worktree `../wt-<issue>-<slug>` + branch. Exit non-zero (and undo label) on conflict. |
| [`release-claim.sh`](release-claim.sh) `<issue> [--claim-id id] [--prefix ns] [--repo owner/name]` | Post-merge cleanup: remove worktree, delete branch, delete claim row (signed commit from a throwaway main worktree, so the canonical checkout never moves), remove label and **verify** it is gone. `--claim-id` releases one slice of a multi-slice issue and keeps the label while siblings remain. Exit 3 = ran but did not finish (row or label still live). |
| [`release-preflight.sh`](release-preflight.sh) `<pr> [--partial] [--launched] [--json]` | Read-only pre-merge verdict: READY (0) / BLOCKED (1) / ADMIN-CANDIDATE (4). Checks what GitHub will actually close (L-013), accepts a `VERDICT: APPROVE` comment when same-author blocks formal review (L-015/L-021), and separates GHA `startup_failure` infra from product red (L-033). Tier C and `--launched` have no admin path. |
| [`gate-baseline.sh`](gate-baseline.sh) | Record branch-point failure counts to `.gibson-baseline.json`. |
| [`gate.sh`](gate.sh) | Run target gate commands; fail on any **new** failure vs. baseline. |
| [`decompose-lint.mjs`](decompose-lint.mjs) | Validate issue set: contract / area / tier / dependencies; ≤10 criteria; schema standalone. |
| [`route-inventory.mjs`](route-inventory.mjs) | Emit route×role authz matrix scaffold (Next.js App Router). [docs/08](../docs/08-security.md) layer 4. |
| [`posture-probe.sh`](posture-probe.sh) `<url>` | Headers (CSP/HSTS/frame), cookie flags, optional POST burst → 429. Layer 8. |
| [`loop.sh`](loop.sh) `--runner … --repo …` | Solo-loop driver ([docs/11](../docs/11-solo-loop.md)): kill switch, hat dispatch, error budget, journal. `--escalate-after N` gets a cross-vendor second opinion before the budget runs out; `--supervisor devin` forwards the branch named by loop-state's `handoff:` field. |
| [`second-opinion.sh`](second-opinion.sh) `--repo … [--author grok]` | Cross-vendor read-only review of a diff ([docs/20](../docs/20-multi-model-orchestration.md) rule 1). Refuses to let a runner review its own work; writes `gibson/second-opinion.md`. |
| [`devin-supervisor.sh`](devin-supervisor.sh) `ensure\|status\|wake\|handoff` | Persistent Devin cloud supervisor ([docs/22](../docs/22-devin-cloud-supervisor.md)): reviews the diff and owns GitHub. Wakes a dead session via `DEVIN_WEBHOOK_URL`, falling back to the API. |
| [`preview-url.sh`](preview-url.sh) `<pr> [--bypass] [--probe]` | Resolve PR Vercel preview URL from GitHub deployments — only from a **success** status, so a building deployment never gets graded. `--bypass` uses `VERCEL_AUTOMATION_BYPASS_SECRET` for protected previews; `--probe` turns a 401/403 into a loud error instead of a URL. Default timeout 300s under `CI`. |
| [`ux-surface.sh`](ux-surface.sh) `--pr <n> \| --diff <base> \| --files …` | Does this change touch a user-visible surface? Exit 0 = none (the UX gate may skip), 1 = ui (it must run and produce a result). Per-repo patterns in `.gibson/ux-surface.conf`. |
| [`deploy-audit.sh`](deploy-audit.sh) `--url …` | Doc 17 inspect: scorecard report + top-5 shell. |
| [`tests/ux-surface.test.sh`](tests/ux-surface.test.sh) | Sensors for the UX path filter in both directions (L-034 skip vs. L-012 false skip). |
| [`tests/release-claim.test.sh`](tests/release-claim.test.sh) | Sensors for the release-claim contract (L-009 / L-024 / L-027 / L-037). Temp git repos only — no network, no `gh`. |
| [`upstream-sync.sh`](upstream-sync.sh) | Doc 18 sync: fetch upstream, merge branch, override-shadow report, sync PR; Tier C when gates change. |

## How to use (quick path)

```bash
GIBSON=~/Code/the-gibson
cd ~/Code/acme-app

# Claim + worktree
$GIBSON/scripts/claim.sh 42 password-reset 'app/api/auth/**'

cd ../wt-42-password-reset
$GIBSON/scripts/gate-baseline.sh
# ... implement ...
$GIBSON/scripts/gate.sh && git commit -s -m "feat(#42): reset tokens"

# After merge
cd ~/Code/acme-app
$GIBSON/scripts/release-claim.sh 42

# Solo grind
$GIBSON/scripts/loop.sh --runner grok --repo ~/Code/acme-app

# Preview for UX eval
export BASE_URL="$($GIBSON/scripts/preview-url.sh 123)"
```

## Gate command configuration

Resolution order per step (`generate` / `typecheck` / `lint` / `test` / `build`):

1. Env: `GIBSON_TYPECHECK`, etc.
2. `.gibson-gate.json` in the target repo
3. Commands recorded in `.gibson-baseline.json`
4. `package.json` scripts (`typecheck`, `lint`, `test`, `build`)
5. Defaults (`npx tsc --noEmit`, `npm run lint`, …)

Example `.gibson-gate.json`:

```json
{
  "generate": "npx prisma generate",
  "typecheck": "npx tsc --noEmit",
  "lint": "npm run lint",
  "test": "npx vitest run",
  "build": "npm run build"
}
```

## Design notes

- **claim commits on main** are the intentional exception to worktree isolation
  ([docs/05](../docs/05-concurrency.md)) — claims must be visible instantly.
- **upstream-sync** never touches `local/` (covenant in [docs/18](../docs/18-fork-and-upstream.md)).
- Prefer fixing the harness over adding script flags for one-off exceptions.
