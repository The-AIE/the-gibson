# Review evidence

`scripts/pr-review-evidence.mjs` decides, for an exact PR head, whether a cross-vendor review exists. The script only reads GitHub and prints JSON (`state`, `reason`, `detail`, `headSha`). The `PR review evidence` workflow runs it with `--sweep` and posts the `review-evidence` commit status.

## Sub-features

- `evidence-suite` proves the resolution rules offline (vendors, unvendored commits, same-vendor rejection, stale heads).
- `evidence-help` prints usage on stderr and exits 2.

## How to get to it (user POV)

- Comment on a PR or push a head; the `PR review evidence` workflow evaluates it. Locally, run the suite.

## Driving it with capture.sh

Preconditions: doctor is ok.

- **Usage.** `capture.sh review-evidence help -- node scripts/pr-review-evidence.mjs --help`. Exit `2` (this script treats `--help` as a usage error); `.err` starts with `pr-review-evidence.mjs: help` and contains `usage:`.
- **Suite.** `capture.sh review-evidence suite -- bash scripts/tests/pr-review-evidence.test.sh`. Exit `0`; the last line ends `0 failed`.

## Gotchas

- The resolver itself never writes a status; only the workflow does. Against a live PR it only makes GitHub GET calls, but it still spends API quota and reads private review data. Prefer reading the published status: `gh api "repos/{owner}/{repo}/commits/<sha>/statuses" --jq '.[]|select(.context=="review-evidence")'`.
- An owner-identity commit with no `Agent-Vendor` trailer resolves as `owner-unvendored` only when it also lacks an exact-head `owner-review-attestation:v1`. Unvendored heads fail `identity-unresolved` unless some evidence identity has vendor `independent`.
