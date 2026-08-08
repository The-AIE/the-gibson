# scripts/ — deterministic harness tooling

No-model by design ([docs/15](../docs/15-model-economics.md): "no-model checks stay
no-model"). POSIX bash + plain Node. **No package dependencies.** Every script
prints Ask-Contract style help via `--help` (what / why / risks / examples).

## Inventory

| Script | Contract |
|---|---|
| [`claim.sh`](claim.sh) `<issue> <slug> <scope…> [--slice]` | Atomic claim: `agent-claimed` label → refuse a second claim on the same issue (`--slice` for a deliberate lane) → verify no scope overlap against live claims read from `origin/main` → write `docs/claims/<claim-id>.md`, commit `-s` from a throwaway worktree, push → create worktree `../wt-<issue>-<slug>` + branch. One file per claim, so concurrent lanes never conflict on the ledger. Exit non-zero (and undo label) on conflict. |
| [`claims-status.sh`](claims-status.sh) `[--issue n] [--markdown]` | The live claim table, rendered from `docs/claims/*.md` plus legacy `docs/active-work.md` rows. Flags claims older than 24h as STALE. |
| [`release-claim.sh`](release-claim.sh) `<issue> [--claim-id id] [--prefix ns] [--repo owner/name]` | Post-merge cleanup: remove worktree, delete branch, delete the claim file and any legacy row (signed commit from a throwaway main worktree, so the canonical checkout never moves), remove label and **verify** it is gone. `--claim-id` releases one slice of a multi-slice issue and keeps the label while siblings remain. Exit 3 = ran but did not finish (claim or label still live). |
| [`release-preflight.sh`](release-preflight.sh) `<pr> [--partial] [--launched] [--json]` | Read-only pre-merge verdict: READY (0) / BLOCKED (1) / ADMIN-CANDIDATE (4). Checks what GitHub will actually close (L-013), accepts a `VERDICT: APPROVE` comment when same-author blocks formal review (L-015/L-021), and separates GHA `startup_failure` infra from product red (L-033). Tier C and `--launched` have no admin path. |
| [`gate-baseline.sh`](gate-baseline.sh) | Record branch-point failure counts **and** test metrics (`total` / `skipped` / `todo`) to `.gibson-baseline.json`. Intentional suite reductions require `--regenerate --reason` and append `.gibson/test-integrity-journal.jsonl`. |
| [`gate.sh`](gate.sh) | Run target gate commands; fail on any **new** failure vs. baseline. Also hard-fails `test-integrity` when test total drops or skip/todo rises without an exact visible waiver (`GIBSON_TEST_INTEGRITY_TEXT` / `--waiver-text`). |
| [`test-integrity.mjs`](test-integrity.mjs) | Count-based test-deletion / skip-inflation sensor (issue #70). `parse` / `compare` / `journal-append`. PR body is inert data (`--waiver-file` in CI). Local `gate.sh` uses `.gibson-baseline.json`; protected CI grades with the **merge-base** copy only (`--trusted-source merge-base:<sha>` in `ci/gibson-gate.yml`). Never grade from a PR-head copy. Every explicit metrics line **and every** native summary block is collected (no first/last-only); conflicts fail closed; safe-integer only; waivers must match both axes. |
| [`decompose-lint.mjs`](decompose-lint.mjs) | Validate issue set: contract / area / tier / dependencies; ≤10 criteria; schema standalone. |
| [`route-inventory.mjs`](route-inventory.mjs) | Emit route×role authz matrix scaffold (Next.js App Router). [docs/08](../docs/08-security.md) layer 4. |
| [`posture-probe.sh`](posture-probe.sh) `<url>` | Headers (CSP/HSTS/frame), cookie flags, optional POST burst → 429. Layer 8. |
| [`loop.sh`](loop.sh) `--runner … --repo …` | Solo-loop driver ([docs/11](../docs/11-solo-loop.md)): kill switch, hat dispatch, error budget, journal. `--escalate-after N` gets a cross-vendor second opinion before the budget runs out, written to `gibson/second-opinion.md` for the next hat; `--supervisor devin` forwards the branch named by loop-state's `handoff:` field, gated on a distinct-vendor review of that exact SHA written to `gibson/pre-handoff-review.md` — separate files, so a routine handoff review never overwrites the escalation one. |
| [`loop-fleet.sh`](loop-fleet.sh) `--profile PATH` / `FLEET_PROFILE=…` | Portable multi-lane fleet driver ([issue #139](https://github.com/mrhinkle/the-gibson/issues/139)): loads a **versioned declarative profile** (target repo, expected slug, lane id/queue/scope/intent) — never embeds one product's queues. Fail-closed preflight (slug match, clean checkout, open non-gated issues, claim/PR conflicts, inter-lane scope overlap via path/glob containment). Long-lived `lane-*` worktrees (never `wt-*`). Preserves three-role defaults (`RUNNER` / `REVIEWER_CMD` / `RELEASE_CMD`). Per-lane runner pools are follow-up [#141](https://github.com/mrhinkle/the-gibson/issues/141). Template: [`templates/fleet/`](../templates/fleet/). |
| [`dogfood-prep.sh`](dogfood-prep.sh) `--repo … --repo-slug … [--runner …]` | Preflight (and optional confirmed launch) for unattended overnight dogfood ([issue #96](https://github.com/mrhinkle/the-gibson/issues/96), [playbooks/dogfood-overnight.md](../playbooks/dogfood-overnight.md)): origin/slug match, HALT clear, budgets, runner name, self-gate presence, print-prompt smoke. `--run` requires `--confirm YES`. Goose runner rejected while live path parked (#28/#33). Evidence template under `memory/dogfood/`.
| [`second-opinion.sh`](second-opinion.sh) `--repo … [--author grok]` | Cross-vendor read-only review of a diff ([docs/20](../docs/20-multi-model-orchestration.md) rule 1). Refuses to let a runner review its own work; writes wherever `--out` says (default `gibson/second-opinion.md`, which `loop.sh` uses for escalation only — its pre-handoff reviews pass `--out gibson/pre-handoff-review.md`). |
| [`devin-supervisor.sh`](devin-supervisor.sh) `ensure\|status\|wake\|handoff` | Persistent Devin cloud supervisor ([docs/22](../docs/22-devin-cloud-supervisor.md)): reviews the diff and owns GitHub. Wakes a dead session via `DEVIN_WEBHOOK_URL`, falling back to the API. A pinned handoff (`--sha`, plus `--base-sha` for the base) fails unless the remote branch exists and still matches, and describes the change by those exact commits rather than by branch names that may have moved. |
| [`git-configure.sh`](git-configure.sh) `[--audit\|--apply]` | Audit (default) or safely apply Git/GitHub adoption settings (labels, merge methods, gibson/ gitignore). Never applies branch protection. |
| [`preview-url.sh`](preview-url.sh) `<pr>` | Resolve PR Vercel preview URL from GitHub deployments. |
| [`injection-scan.sh`](injection-scan.sh) `[paths…] [--all]` | Invisible/deceptive Unicode (zero-width, bidi overrides, BOM, soft hyphen) in anything a model ingests — skills, prompts, recipes, shared config. Red-team Phase 2; exit 1 on a hit. The Pale Fire class: invisible in a diff, fully tokenized by the LLM. |
| [`recipe-stamp.sh`](recipe-stamp.sh) `--role … --recipe PATH` | Append a Goose recipe-run audit row to `memory/recipe-runs.md` (role, schema, playbook-sha256 pin, issue). No secrets or home paths. |
| [`../adapters/goose/enforce.sh`](../adapters/goose/enforce.sh) | Fail-closed claim/worktree/gate/release for Goose sessions (#35). Same exit codes as `claim.sh`/`gate.sh`/`release-claim.sh`. No Goose binary required. |
| [`decision-ledger.sh`](decision-ledger.sh) | Offline owner decision-card ledger (append-only JSONL). |
| [`digest.sh`](digest.sh) | Render morning digest from ledger + loop/PR signals (Hermes-ready markdown). |
| [`preview-url.sh`](preview-url.sh) `<pr> [--bypass] [--probe]` | Resolve PR Vercel preview URL from GitHub deployments — only from a **success** status, so a building deployment never gets graded. `--bypass` uses `VERCEL_AUTOMATION_BYPASS_SECRET` for protected previews; `--probe` turns a 401/403 into a loud error instead of a URL. Default timeout 300s under `CI`. |
| [`ux-surface.sh`](ux-surface.sh) `--pr <n> \| --diff <base> \| --files …` | Does this change touch a user-visible surface? Exit 0 = none (the UX gate may skip), 1 = ui (it must run and produce a result). Per-repo patterns in `.gibson/ux-surface.conf`. |
| [`deploy-audit.sh`](deploy-audit.sh) `--url …` | Doc 17 inspect: scorecard report + top-5 shell. |
| [`silent-noop.sh`](silent-noop.sh) `--help` | Sourceable L-008 progress sensor for solo-loop drivers: fingerprints `gibson/loop-state.md` between iterations so a runner that exits 0 and advances nothing trips `NOOP_BUDGET` (default 3) instead of burning the loop. Fingerprints the substantive state and **excludes** the `updated:` line — a clock is not progress, and hashing it would certify exactly the L-008 run this exists to stop. Missing, unreadable, or un-hashable state is a constant sentinel, never an empty string, so the streak keeps accruing — including when the hash binary itself exists but fails, which under the driver's `set -euo pipefail` must collapse to the sentinel rather than abort the caller. The only script here that is `source`d rather than run, so it carries the same Ask-Contract `--help` as its siblings and a direct run without `--help` is a loud usage error (exit 2) — a library that exits 0 having done nothing is the very failure it detects. Sourced/executed is decided by `return` legality, not `${BASH_SOURCE[0]} == $0`, which a caller's `$0` can spoof into misreading a real source. Wired into `loop.sh` (issue #63 / L-008): exit-0 no-progress trips the shared failure + stale budgets. |
| [`check-active-work.mjs`](check-active-work.mjs) | Claim-isolation gate for CI `pull_request` runs ([docs/05](../docs/05-concurrency.md)): diffs the merge base against the head, so appending your own claim passes while touching a claim that already existed on the base fails. Renames are scored as delete + add, and deleting a live claim file is refused even for the branch that owns it — a claim is released on main with `release-claim.sh`. Changed paths are read NUL-separated and addressed as literal pathspecs, so a claim whose filename is non-ASCII or carries glob characters is checked like any other; legacy `docs/active-work.md` rows are protected on the same `issue-` shape `claims-status.sh` treats as live. A base ref it cannot resolve is a loud error, never a green "no changed files". |
| [`tests/gate.test.sh`](tests/gate.test.sh) | Adversarial sensors for test-integrity (issue #70): deletion/no waiver, new skip/no waiver, exact visible delta-consistent waiver, hidden/near-match/wrong-delta waiver, malformed metrics, added tests/reduced skips, regeneration without flag/reason, auditable journal, gate.sh wiring, inert PR text, explicit/runner conflict, multi-explicit-line conflict, multi-native-summary conflict (Jest/node:test/TAP/Vitest first/last-match bypasses), dual-axis waiver overclaim, safe-integer rejection, local trusted-helper simulation, **phase-2 protected CI contract** (four jobs, always(), least permissions, immutable action SHAs, artifact validation, hostile-helper, failing-base 10→7, fork head SHA, missing-helper rebase message). |
| [`tests/injection-scan.test.sh`](tests/injection-scan.test.sh) | Pins each codepoint the scan must catch, and that ordinary prose stays quiet. |
| [`tests/check-active-work.test.sh`](tests/check-active-work.test.sh) | Sensors for the claim-isolation gate in both directions: append/renew allowed, another lane's claim untouchable, rename-as-deletion caught, owner-side deletion refused, non-ASCII and glob-character claim filenames protected rather than skipped, underscore/dot legacy row ids protected, and an unresolvable or shallow base failing loudly. Temp git repos only — no network, no `gh`. |
| [`tests/loop-handoff.test.sh`](tests/loop-handoff.test.sh) | Sensors for the Law 5 gate in front of a supervisor handoff: the ways it must fail closed (a missing, stale, or failed review; an unpublished branch; an unfetchable SHA or base) and the ways it may pass, plus the separation of the two review artifacts: an escalation `gibson/second-opinion.md` survives a routine pre-handoff review untouched, and a receipt whose `gibson/pre-handoff-review.md` is gone or empty does not pass. Drives the real `loop.sh` against stub reviewer/supervisor CLIs, plus `devin-supervisor.sh --dry-run` for the guard and message it renders itself — no Devin API is contacted. |
| [`tests/second-opinion.test.sh`](tests/second-opinion.test.sh) | Sensors for the diff `second-opinion.sh` actually reviews: named refs are reviewed as committed history, and an unresolvable base or branch dies loudly instead of falling through to a working-tree diff and producing a review of the wrong change. An empty diff is refused rather than spent on a reviewer. |
| [`tests/claim.test.sh`](tests/claim.test.sh) | Sensors for the claim contract (L-023 / L-024 / L-028 / L-009). Fake `gh`, temp git repos. |
| [`tests/ux-surface.test.sh`](tests/ux-surface.test.sh) | Sensors for the UX path filter in both directions (L-034 skip vs. L-012 false skip). |
| [`tests/release-claim.test.sh`](tests/release-claim.test.sh) | Sensors for the release-claim contract (L-009 / L-024 / L-027 / L-037). Temp git repos only — no network, no `gh`. |
| [`tests/silent-noop.test.sh`](tests/silent-noop.test.sh) | Sensors for the L-008 progress sensor, all of whose bugs are fail-open: a clock-only `updated:` bump still trips, real progress (including a same-length edit a byte count cannot see) never trips, and a missing, unreadable, or unset state file trips rather than silently disabling the sensor. Pins `NOOP_BUDGET` to a positive integer — `[[ x -ge $BUDGET ]]` is an arithmetic context, so an unvalidated value both mis-budgets and runs command substitution. Shadows the hash binaries in `PATH` with a failing stub to prove a broken hasher yields `sentinel:unhashable` and trips the budget instead of killing a `set -euo pipefail` driver. Pins the sourced-vs-executed contract from both sides: `--help` exits 0 with every Ask-Contract field, a direct run without it exits non-zero with usage on stderr, and sourcing is silent while leaving the functions usable — including a source whose `$0` is the sensor's own path, the case a `${BASH_SOURCE[0]} == $0` guard gets wrong. Scenarios pass the sensor as an argument and keep `$0` a label, so the tests cannot lie about how the file is loaded. Also pins that `loop.sh` sources and calls `silent_noop_progressed`. |
| [`tests/dogfood-prep.test.sh`](tests/dogfood-prep.test.sh) | Offline sensors for dogfood preflight: slug mismatch fail-closed, HALT present, `--run` without confirm refused, unknown/goose runner rejected, playbook + evidence README present, bash -n.
| [`tests/loop-fleet.test.sh`](tests/loop-fleet.test.sh) | Offline sensors for fleet profiles (#139): throwaway repos + stub `gh`/runner/`loop.sh`; valid Gibson- and Chatterbuilt-shaped fixtures; hostile/malformed profiles, wrong slug, dirty checkout, gated labels, overlap, duplicate lanes; proves fail-closed paths launch zero runners. |
| [`upstream-sync.sh`](upstream-sync.sh) | Doc 18 sync: fetch upstream, merge branch, override-shadow report, sync PR; Tier C when gates change. |
| [`delivery-control/`](delivery-control/) | Doc 20: audit/harden branch protection + Production env; promote/hotfix (portable). **Never rotates secrets.** |

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

# Intentional suite reduction (journaled; not a side effect of re-baseline):
$GIBSON/scripts/gate-baseline.sh --regenerate --reason "removed obsolete flaky suite after #42"
# And put a matching visible waiver on the PR:
#   Test-integrity: removed N for <reason>

# After merge
cd ~/Code/acme-app
$GIBSON/scripts/release-claim.sh 42

# Solo grind
$GIBSON/scripts/loop.sh --runner grok --repo ~/Code/acme-app

# Multi-lane fleet (profile is local — see templates/fleet/)
export FLEET_PROFILE=/absolute/path/to/local.profile
$GIBSON/scripts/loop-fleet.sh --status
$GIBSON/scripts/loop-fleet.sh --start
$GIBSON/scripts/loop-fleet.sh --halt

# Preview for UX eval
export BASE_URL="$($GIBSON/scripts/preview-url.sh 123)"
```

## Gate command configuration

Resolution order per step (`generate` / `typecheck` / `lint` / `test` / `build`):

1. Env: `GIBSON_TYPECHECK`, etc.
2. `.agents/gate.json` in the target repo (legacy fallback: `.gibson-gate.json`)
3. Commands recorded in `.gibson-baseline.json`
4. `package.json` scripts (`typecheck`, `lint`, `test`, `build`)
5. Defaults (`npx tsc --noEmit`, `npm run lint`, …)

Example `.agents/gate.json` — vendor-neutral on purpose, so a target repo can be
driven by any harness (docs/13):

```json
{
  "generate": "npx prisma generate",
  "typecheck": "npx tsc --noEmit",
  "lint": "npm run lint",
  "test": "npx vitest run",
  "build": "npm run build"
}
```

## Test-integrity summary contract (issue #70)

Prefer an explicit machine line from the test suite (works with any runner):

```
GIBSON_TEST_METRICS total=42 skipped=2 todo=0
```

Also parsed: Vitest / Jest / node:test / TAP summary shapes. Unparseable,
negative, or non-integer metrics **fail closed** (never become zero). Known
limit: count-only comparison cannot detect equal-count swap of one test for
another — see [docs/06](../docs/06-quality-gates.md).

Local `gate.sh` uses `.gibson-baseline.json` (gitignored). A PR-local baseline
never authorizes a remote merge: `ci/gibson-gate.yml` ships the protected
four-job template that re-derives metrics at the merge-base with the immutable
base-owned helper and compares via `--trusted-source merge-base:<sha>`. The
template is **inert until an owner activates** the unique required check
`test-integrity` under issue #68 — installing the file alone is not protection.

## Design notes

- **claim commits on main** are the intentional exception to worktree isolation
  ([docs/05](../docs/05-concurrency.md)) — claims must be visible instantly.
- **upstream-sync** never touches `local/` (covenant in [docs/18](../docs/18-fork-and-upstream.md)).
- Prefer fixing the harness over adding script flags for one-off exceptions.
