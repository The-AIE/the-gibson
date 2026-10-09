# Pre-push check

`scripts/prepush.sh` runs the cheap convention probes (sensor-reachability, mjs unknown-flag, recipe hashes, `bash -n` on changed shell, touched test suites) and prints `all clear` or `FAILED <probe>`. It is report-only; CI stays the authority.

## Sub-features

- `prepush-clear` exits 0 and ends with `all clear` on a clean tree.
- `prepush-fail-names-probe` exits 1 and ends with `FAILED <probe>` when a probe fails.
- `prepush-bad-base` exits 2 for a `--base` ref that does not resolve.
- `prepush-skip-says-so` with `--no-tests` ends with `touched tests SKIPPED`, never a plain `all clear`.

## How to get to it (user POV)

- Run `scripts/prepush.sh` before the first push of any change to the Gibson (step 4c of `playbooks/builder.md`).

## Driving it with capture.sh

Preconditions: doctor is ok; the tree is clean (`git status --short` prints nothing).

- **Clear.** `capture.sh prepush all-clear -- scripts/prepush.sh`. Exit `0`; the last line of `.out` starts `prepush: all clear`.
- **Failing probe.** Plant an unreferenced script: `printf '#!/usr/bin/env bash\necho x\n' > scripts/zz-verify-orphan.sh`. Run `capture.sh prepush orphan -- scripts/prepush.sh`. Exit `1`; the last line of `.out` contains `FAILED sensor-reachability`. Remove the planted file, then rerun the clear recipe and require exit `0` again.
- **Bad base.** `capture.sh prepush bad-base -- scripts/prepush.sh --base no-such-ref`. Exit `2`; `.err` contains `--base ref not found`.
- **Skipped tests.** `capture.sh prepush no-tests -- scripts/prepush.sh --no-tests`. Exit `0`; the last line contains `touched tests SKIPPED` and does not contain `all clear`.

## Gotchas

- A change that touches many `scripts/tests/*.test.sh` makes prepush report the surplus suites `NOT RUN` (cap 6, budget 55s). That is a failure by design: run those suites directly.
- A slow host can time a suite out at 25s (`NOT RUN ... timed out`). Run it directly; do not treat the timeout as a pass.
- The orphan recipe leaves a file behind if you skip the removal; the next prepush will fail on it.
