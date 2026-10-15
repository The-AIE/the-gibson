# Gate and verification receipt

`scripts/gibson-verify.mjs` checks the environment (`doctor`), runs the gate and writes an exact-head receipt (`prove`). Receipts are local evidence, never merge authority.

## Sub-features

- `doctor-ok` reports `"ok": true` only when every required check passes: `git`, `node`, `bash`, `jq`, `gh` present, `gh` authenticated, a git repo, and an executable gate. `shellcheck` and the `MC_*` / `GH_REVIEWER_TOKEN` checks are optional.
- `prove-receipt` always writes `.gibson-receipts/<HEAD>.json` (schema `gibson.verify-receipt.v1`), including for a head that failed. Exit `0` and `"verified": true` together mean it passed.

## How to get to it (user POV)

- `node scripts/gibson-verify.mjs doctor` before work; `prove` before claiming done (step 4b of `playbooks/builder.md`). Plain `prove` uses the default gate `scripts/gate.sh`, which runs the `test` command in `.agents/gate.json` plus test-integrity. The recipe below passes `--gate scripts/tests/run-all.sh` to run the suite directly.

## Driving it with capture.sh

Preconditions: doctor needs none. `prove` needs a clean tree (`.gibson-receipts/` excepted) and a non-empty file diff against the merge-base with `origin/main`. A branch whose only commit is empty fails the `non-empty-diff` step.

- **Doctor.** `capture.sh gate-receipt doctor -- node scripts/gibson-verify.mjs doctor`. Exit `0`; `.out` contains `"ok": true`.
- **Prove (long).** `capture.sh gate-receipt prove -- node scripts/gibson-verify.mjs prove --gate scripts/tests/run-all.sh`. Runs the full suite (about 15 minutes). Exit `0`, and `.gibson-receipts/<HEAD>.json` exists with `"verified": true`. The file existing is not enough on its own. Skip it when the change is small and report `prove` as not run.

## Gotchas

- `prove` fails a no-op diff, a dirty tree, a red gate, and a log that says NOT RUN.
- On some macOS hosts `run-all.sh` fails locally on environment grounds (suites exiting with no tally, a bash 3.2 step); CI is the authority. Say so rather than hiding it.
