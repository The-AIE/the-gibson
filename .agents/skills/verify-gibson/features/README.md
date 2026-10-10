# Gibson verification map

The maintained source for verifying what the Gibson's scripts do. Read this index, then use the feature file for the tool your change touches.

## Baseline preconditions

- Work in a dedicated worktree of the Gibson branched from `origin/main`; the shared checkout is read-only.
- `node scripts/gibson-verify.mjs doctor` reports `"ok": true`.
- Run from the worktree root. Every command below is relative to it.
- Wrap each drive in `bash .agents/skills/verify-gibson/scripts/capture.sh <feature-id> <label> -- <command...>`.
- Set `VERIFY_RUN_ID` once per run so all features share one evidence directory.

## Driving conventions

- Start from a clean tree. Plant the input a recipe needs, drive, then remove what you planted. A recipe says which files it plants.
- Treat exit codes as part of the contract: assert the code and the line named, not only that output appeared.
- Never run a recipe that mutates GitHub (a claim, a label, a review, a merge) unless the recipe says it is safe; the offline refusal and suite recipes below do not touch GitHub.
- Local `scripts/tests/run-all.sh` can fail for environmental reasons on some hosts; CI is the authority for it. The per-suite recipes below are reliable.

## Proof and skip reporting

- Evidence lives in `<git-common-dir>/gibson-verify-evidence/<run-id>/<feature-id>/` (the shared `.git` directory, outside every worktree) and survives `git worktree remove`.
- Report an unreachable path with the command and the unmet precondition; do not report it verified through a different path.
- A suite counts as proof only for the feature file that names it, and only with `0 failed`.

## Features

- [prepush](./prepush.md): the local pre-push check, clear and failing.
- [claim-vendor](./claim-vendor.md): `claim.sh` requires a vendor and refuses before any mutation.
- [reviewer-findings-lint](./reviewer-findings-lint.md): the finding-contract linter on good and bad review bodies.
- [review-evidence](./review-evidence.md): the review-evidence resolver, through its suite.
- [gate-receipt](./gate-receipt.md): doctor, the gate and the verification receipt.
- [sensor-health](./sensor-health.md): the sensor-health report, through its unit suite and the live run.
