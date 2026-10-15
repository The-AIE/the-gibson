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
- **Failing probe.** Plant a shell script with a syntax error: `printf '#!/usr/bin/env bash\nif then\n' > scripts/zz-verify-bad.sh`. Run `capture.sh prepush bad-syntax -- scripts/prepush.sh`. Exit `1`; `.out` has a `FAIL bash-n` line and its last line contains `FAILED bash-n`. Remove the planted file, then run the clear recipe again under a new label (`capture.sh prepush all-clear-after -- scripts/prepush.sh`, because `capture.sh` refuses to reuse a label in the same run) and require exit `0`.
- **Bad base.** `capture.sh prepush bad-base -- scripts/prepush.sh --base no-such-ref`. Exit `2`; `.err` contains `--base ref not found`.
- **Skipped tests.** `capture.sh prepush no-tests -- scripts/prepush.sh --no-tests`. Exit `0`; the last line contains `touched tests SKIPPED` and does not contain `all clear`.

## Gotchas

- A change that touches many `scripts/tests/*.test.sh` makes prepush report the surplus suites `NOT RUN` (cap 6, budget 55s). That is a failure by design: run those suites directly.
- A slow host can time a suite out at 25s (`NOT RUN ... timed out`). Run it directly; do not treat the timeout as a pass.
- The failing-probe recipe leaves `scripts/zz-verify-bad.sh` behind if you skip the removal, and every later prepush fails on it.
- Do not use an unreferenced (orphan) script as the failing probe. `sensor-reachability` fails only when the orphan count is **above** `orphanMax` in `config/sensor-reachability-baseline.v1.json`. The live count sits below the cap, so one planted orphan still exits `0` with `all clear`. That was verified on 2026-10-14 at `de25b2e`: 22 live orphans, cap 23.
