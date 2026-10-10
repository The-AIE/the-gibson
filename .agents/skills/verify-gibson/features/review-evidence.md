# Review evidence

`scripts/pr-review-evidence.mjs` decides, for an exact PR head, whether a cross-vendor review exists. It writes the `review-evidence` commit status in CI.

## Sub-features

- `evidence-suite` proves the resolution rules offline (vendors, unvendored commits, same-vendor rejection, stale heads).
- `evidence-help` prints usage on stderr and exits 2.

## How to get to it (user POV)

- Comment on a PR or push a head; the `PR review evidence` workflow evaluates it. Locally, run the suite.

## Driving it with capture.sh

Preconditions: doctor is ok.

- **Usage.** `capture.sh evidence help -- node scripts/pr-review-evidence.mjs --help`. Exit `2` (this script treats `--help` as a usage error); `.err` starts with `pr-review-evidence.mjs: help` and contains `usage:`.
- **Suite.** `capture.sh evidence suite -- bash scripts/tests/pr-review-evidence.test.sh`. Exit `0`; the last line ends `0 failed`.

## Gotchas

- Do not run the resolver against a live PR to "check": it can stamp a commit status. Read the status with `gh api repos/<owner>/<repo>/commits/<sha>/statuses` instead.
- An owner-identity commit with no `Agent-Vendor` trailer resolves as `owner-unvendored` unless the independent reviewer approves.
