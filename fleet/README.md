# fleet/ — the lane pre-push layer, tracked

The per-worktree git layer every fleet lane pushes through (FLEET.md "Coder owns the green loop",
adopted 2026-10-15; rationale in `~/.claude/fleet/doctrine/green-loop.md`). Each lane worktree gets a
`pre-push` hook that refuses pushes to main/master/release and any force-push, refuses any introduced
commit with no vendor marker, and runs the repo's local gate before the push leaves the machine.

Until 2026-10-23 these files existed only under `~/.claude/fleet` on one Mac, which is not a git
checkout. A defect fixed there (L-098: empty `LANG`/`LC_ALL` from the Cowork shell killed six
conference-os postgres suites) could be recorded in `memory/LESSONS.md` but not reviewed or
versioned. This directory is the tracked home; `~/.claude/fleet` holds symlinks into it.

## Files

| File | Does | Fails closed? |
|---|---|---|
| `hooks/pre-push` | refuses main/master/release targets, non-fast-forward pushes, and any introduced commit (`--not origin/main`) with no lane-bot email or real `Agent-Vendor:` trailer; then runs the gate | yes; unresolvable `origin/main` refuses |
| `pre-push-gate.sh [worktree]` | `.fleet-gate` (only when byte-identical to `origin/main`'s) → known repo by origin URL → `package.json` typecheck/lint/test; exports a default locale; no skip variable | yes: unknown gate, unresolvable base, or a touched package with no check is red |
| `gibson-isolated-gate.sh <worktree>` | the-gibson's gate in a throwaway clone (the suites rewrite the shared `.git` when run in a lane); one gate at a time per host; red is classified against the merge-base | yes |
| `install-lane-hooks.sh <worktree>` | worktree-scoped `core.hooksPath` → `hooks/`; refuses the main checkout | yes: exit 66 on any step |
| `prepush-review.sh <worktree> [coder-vendor]` | one-pass cross-vendor read of the diff vs `origin/main` before the first push; 0 PASS / 1 CHANGES / 2 no verdict | 2 is not a pass |
| `install.sh [--check] [--target DIR]` | links the six files above into `~/.claude/fleet`; `--check` reports drift | refuses to overwrite a live file that differs |
| `test/prepush.test.sh` | the suite for all of the above (no network, no gh, no codex, no claude) | run before changing any of them |

`scripts/prepush.sh` at the repo root is a different tool (the #465 convention probes, report-only).

## How the live copy stays in sync

```bash
bash ~/Code/the-gibson/fleet/install.sh            # once, from a checkout on main: links the six files
bash ~/Code/the-gibson/fleet/install.sh --check    # any time: ok | missing | dangling | not-a-link | drift | wrong-target
```

- Each path under `~/.claude/fleet` (`pre-push-gate.sh`, `hooks/pre-push`, `install-lane-hooks.sh`,
  `prepush-review.sh`, `gibson-isolated-gate.sh`, `test/prepush.test.sh`) becomes a symlink to this
  directory. `install.sh` itself is not linked; run it from the checkout.
- A live file that differs from the tracked one is **refused**, never overwritten. Read the diff, land
  it here as a PR if it is a fix, then move the live file aside and re-run.
- The links follow whatever branch the checkout has out. Install from main; after switching branches
  run `--check`. A dangling `hooks/pre-push` is fail-closed at lane setup (`install-lane-hooks.sh`
  tests `-x`, `lane-sync.sh` refuses the lane) but git runs no hook that is missing at push time, so do
  not leave it dangling under a lane mid-flight.
- Every script resolves its siblings from its own location (`HERE`), never from an environment
  variable: through the links that is `~/.claude/fleet`, which is also where the untracked parts
  still live (`codex-review.sh`, `lane-sync.sh`, `bot-*.sh`, `identities/`, `logs/`, `reviews/`,
  `state/`). `prepush-review.sh` keeps `$HOME/.claude/fleet` for `codex-review.sh` and its review
  output; run from a bare checkout with no `codex-review.sh` beside it, the Codex path reports no
  verdict (exit 2), which is not a pass.

Knobs the tests use, all defaulting to the live paths: `FLEET_LOG_DIR` (gate log, default
`~/.claude/fleet/logs`), `FLEET_IDENTITIES_DIR` (lane-bot emails), `FLEET_HOOKS_DIR` (installer),
`PREPUSH_REVIEW_OUTDIR` / `PREPUSH_CODEX_REVIEW` / `PREPUSH_CLAUDE_BIN` (review). The provenance
boundaries (`origin/main` as the vendor-check scope and the diff base) are not knobs.

## Tests

```bash
bash fleet/test/prepush.test.sh                        # the copy beside the test
FLEET_DIR=~/.claude/fleet bash fleet/test/prepush.test.sh   # the installed copy
bash scripts/tests/run-all.sh --only fleet-prepush      # as the Gibson sensor (shim: scripts/tests/fleet-prepush.test.sh)
```

Hermetic: a bare origin and lane clones under `mktemp`, fake reviewers, and every runtime path
pointed at the temp dir. Nothing under `~/.claude/fleet` is read or written. Not yet in the
`shellcheck`/bash-3.2 file set of `run-all.sh` (that set is pinned by `bash32-syntax-each.test.sh`);
run `shellcheck -S warning fleet/*.sh fleet/hooks/pre-push fleet/test/prepush.test.sh` by hand.
