---
title: Lesson proof
---

# Lesson proof

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

`scripts/lesson-proof.mjs` reads `memory/LESSONS.md` and reports whether a closure has a replayable proof. It reads the Status line and the Proof line. Every other ledger field is ignored. The checker does not edit the ledger, reopen an issue, post a comment, or set a commit status.

## Closures

A Status is a fix closure when it begins with `fixed`. A Status is a non-fix closure when it begins with `wontfix`, `obsolete`, `duplicate`, `working as designed`, `no fix needed`, `not a bug`, `closed`, or `superseded`. Anything else, including `fix-pending`, `reconstructed`, and `intake`, is not a closure.

A missing Status is unknown. Two Status lines, two Proof lines, or two headings with the same id are unknown. The checker does not pick one of them.

## Proof

A closure with no Proof line is unproven. That row is a downgrade candidate in the report. The checker does not skip it and does not rewrite it.

The Proof value `unknown` on a closure means the replay cannot be evaluated. That row is unknown, which is not a pass. A lesson that is not a closure stays `not-closure` when its Proof line is `unknown`. That line is not replayed, and `--strict` does not fail on it.

Any other Proof value must be one line of exactly three fields, separated by one space:

`**Proof:** <sha> <entrypoint> <fixture-dir>`

`<sha>` is 40 lowercase hex characters. `<entrypoint>` and `<fixture-dir>` are repository-relative paths with no absolute path and no `..` segment. The fields are separated by exactly one space, and a path cannot contain a space. A missing piece, a second space, an uppercase digest, an absolute path, or a `..` segment is unproven.

## Replay

For a bound proof the checker loads that commit from the local repository. It does not fetch. It runs the entrypoint blob from that commit, not a stand-in, as `entrypoint --fixture <directory>`. The fixture directory must contain `bad/` and `valid/`.

Replay copies only the entrypoint blob and the fixture tree into a temporary directory. It does not check out the rest of the commit. A relative import or source of another repository file is not available. When the file still parses, both runs exit non-zero and the row is unproven, not unknown. Use a standalone entrypoint.

Three results are required before a fix closure can be proven:

- the bad directory exits non-zero
- the valid directory exits zero
- after the one disarm edit, the bad directory exits zero

The disarm edit rewrites exactly one line in that entrypoint file: `const LESSON_PROOF_ENFORCE = true;` becomes `false`, or `LESSON_PROOF_ENFORCE=1` becomes `0`. Zero matches or more than one match is unknown. A bad directory that still fails after that edit is unproven: the flag did not change the result, so the replay did not show the protection firing.

A check that cannot run is unknown. That includes a commit that is not in the local repository, a missing entrypoint, a fixture without `bad/` and `valid/`, a file that does not parse, a timeout, and a spawn failure. Unknown is never proven.

A non-fix closure is never proven. An accepted-risk sign-off is not a Status or Proof field, so a passing replay on a non-fix closure stays unknown.

Gate stdout and stderr are not copied into the report. Each invocation stops at 5 seconds. On expiry the checker kills the gate and every descendant, including a child that left the process group, before it removes the temporary directory. The child process receives `PATH`, `HOME`, `TMPDIR`, and locale only.

## Report

The text report and the JSON report (`gibson.lesson-proof.report.v1`) list each lesson as `proven`, `unproven`, `unknown`, or `not-closure`. A finished report exits 0. `--strict` exits non-zero when any closure is not proven, including a closure that is unknown. A ledger that cannot be read exits non-zero and is not an empty pass.

`.github/workflows/lesson-proof.yml` runs the checker without `--strict` on pull requests, on manual dispatch, and on a daily schedule. The job is not a required check. It does not block a merge. sensor-health grades that scheduled heartbeat.

## What this does not claim

The checker does not read fixture bytes. The entrypoint decides what the bad directory means. A gate that rejects the directory name, and flips that reject when the flag is off, can still be reported proven.

A protection that lives in an imported library, with no enforce line in the entrypoint file, is not shown to fire. If the bad directory still fails after disarm, the row is unproven.

A full-suite entrypoint that needs more than 5 seconds, or needs a credential, is unknown. The checker does not call a private runner and does not wrap the blob in another harness.

The checker does not treat every closure without a landed fix as unproven. The three shapes exercised here are unproven: no Proof line, a gate that exits 0 on the bad directory, and a bad directory the gate accepts. A gate that rejects the directory name, and flips that reject when the flag is off, can still be reported proven. Those three shapes are the ones behind the old closures on issues 2, 4, and 9. The checker does not special-case an issue number.

## Promotion

Promotion to a blocking check is not implemented. The list below is proposed criteria for a later change that might pass `--strict` from a required workflow. It is not a binding gate. This page adds no rule. The proposed record on the promotion issue is:

- Named owner: the repository owner of The-AIE/the-gibson, a person. This checker does not add a supervisor role.
- Measured false-positive rate at or below 2 percent across 30 consecutive report-only runs. A false positive is a proven verdict whose bad fixture does not represent the incident, or an unproven verdict the owner overturns in that review. An unknown verdict is unevaluated. It is not counted as a false positive, and any unknown closure blocks promotion on its own.
- Dated review on or after the last of those 30 runs, before any change that makes the check blocking.

Until that review, an unproven row is a downgrade candidate in the report only.
