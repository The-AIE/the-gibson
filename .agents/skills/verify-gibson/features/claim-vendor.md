# Claim requires a vendor

`scripts/claim.sh` claims an issue and opens a draft PR with a reservation commit. Since #467 it requires an agent vendor and refuses, before touching anything, when none is given, so the reservation carries an `Agent-Vendor` trailer. Since the 2026-10-21 closures it also declares that vendor on the lane worktree (`git config --worktree gibson.agentVendor`) and wires `.githooks` for it, so every later commit on the lane carries the trailer too (`prepare-commit-msg` adds it, `commit-msg` refuses a lane commit without it, with another vendor's, or authored under a `.invalid` email).

## Sub-features

- `claim-no-vendor` refuses with exit 1 and `no agent vendor`.
- `claim-unknown-vendor` refuses with exit 1 and `unknown agent vendor`.
- `claim-suite` proves the full claim, trailer, provenance and release paths offline, including a declared lane whose plain `git commit` carries the trailer and a `.invalid`-identity lane refused at the reservation.
- `hooks-suite` (`scripts/tests/setup-hooks.test.sh`) drives the hooks directly: trailer added, reservation shape left alone, the refusals, and the vendor lists agreeing with `pr-review-evidence.mjs`.

## How to get to it (user POV)

- Run `scripts/claim.sh <issue> <slug> <scope...> --vendor=<claude|codex|grok|devin>` or export `GIBSON_AGENT_VENDOR`.

## Driving it with capture.sh

Preconditions: doctor is ok. The two refusal recipes are safe offline: they exit before any GitHub call or mutation.

- **No vendor.** `capture.sh claim-vendor no-vendor -- env -u GIBSON_AGENT_VENDOR scripts/claim.sh 1 verify-probe 'a/**'`. Exit `1`; `.err` contains `no agent vendor`.
- **Unknown vendor.** `capture.sh claim-vendor unknown-vendor -- scripts/claim.sh 1 verify-probe 'a/**' --vendor=bogus`. Exit `1`; `.err` contains `unknown agent vendor`.
- **Full path (suite).** `capture.sh claim-vendor suite -- bash scripts/tests/claim.test.sh`. Takes about 2.5 minutes. Exit `0`; the last line of `.out` ends `0 failed`.
- **Hooks (suite).** `capture.sh claim-vendor hooks-suite -- bash scripts/tests/setup-hooks.test.sh`. Seconds. Exit `0`; the last line of `.out` ends `0 failed`.

## Gotchas

- Never run a real `claim.sh <issue> ...` against the live repo to "see it work": it adds a label and opens a PR. Use the suite, which uses a fake `gh`.
- Anything that calls `claim.sh` (lane runners, Mini jobs) must pass a vendor now, or it refuses.
- A lane made by hand (`git worktree add`) is not declared: run `scripts/setup-hooks.sh --vendor <name>` inside it, or its commits go out without the trailer exactly as before. A lane whose `user.email` is a `.invalid` address cannot commit on a declared lane at all.
- Tests that use the fake `gh` share state: add new test blocks at the end of the file.
