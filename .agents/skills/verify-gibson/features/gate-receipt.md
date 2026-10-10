# Gate and verification receipt

`scripts/gibson-verify.mjs` checks the environment (`doctor`), runs the gate and writes an exact-head receipt (`prove`). Receipts are local evidence, never merge authority.

## Sub-features

- `doctor-ok` reports `"ok": true` with each required tool present.
- `prove-receipt` writes `.gibson-receipts/<HEAD>.json` for a head that passed the gate.

## How to get to it (user POV)

- `node scripts/gibson-verify.mjs doctor` before work; `prove` before claiming done (step 4b of `playbooks/builder.md`).

## Driving it with capture.sh

Preconditions: a clean tree with at least one commit ahead of `origin/main`.

- **Doctor.** `capture.sh gate doctor -- node scripts/gibson-verify.mjs doctor`. Exit `0`; `.out` contains `"ok": true`.
- **Prove (long).** `capture.sh gate prove -- node scripts/gibson-verify.mjs prove --gate scripts/tests/run-all.sh`. Runs the full suite (about 15 minutes). Exit `0` and `.gibson-receipts/<HEAD>.json` exists. Skip it when the change is small and report `prove` as not run.

## Gotchas

- `prove` fails a no-op diff, a dirty tree, a red gate, and a log that says NOT RUN.
- On some macOS hosts `run-all.sh` fails locally on environment grounds (suites exiting with no tally, a bash 3.2 step); CI is the authority. Say so rather than hiding it.
