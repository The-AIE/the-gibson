---
name: verify-gibson
description: Drive The Gibson's own scripts the way an agent or operator does and capture proof (command, stdout, stderr, exit code) before claiming a change works. Use for "verify this change in the Gibson", before the first push of any change to scripts/, playbooks/ or config/, or when a PR is red on a convention probe. Gibson has no UI or server; its surface is bash and node CLIs.
---

# Verify the Gibson

The Gibson is a repository of bash and node tools, not an app. A change is verified when the tool it changed was **run on a real input and its exit code and output were captured**, not when it parses. Read `features/README.md`, pick the feature your change touches, and follow its recipe.

## Launch

There is nothing to start. Work from a dedicated git worktree of the Gibson (never the shared checkout), branched from `origin/main`:

```bash
git fetch -q origin && git worktree add ../wt-<slug> -b feat/<slug> origin/main && cd ../wt-<slug>
```

## Doctor

One read-only check that this checkout is worth driving. Run it first, and again after any failed drive:

```bash
node scripts/gibson-verify.mjs doctor
```

Require `"ok": true`. Required tools are git, node, bash, jq, gh (authenticated), the gate script, and a git repo. `shellcheck` and the `MC_*` / `GH_REVIEWER_TOKEN` variables are optional; unset is not a failure. If `receipts:gitignored` is not ok, stop: evidence below would be committed.

## Drive

Each feature file lists exact commands. Wrap every command in the capture helper so the proof is recorded the same way every time:

```bash
bash .agents/skills/verify-gibson/scripts/capture.sh <feature-id> <label> -- <command> [args...]
```

Run `scripts/prepush.sh` first on every change: it takes seconds and covers the probes that fail first push most often. It is not the gate; CI stays the authority, and `NOT RUN` is not a pass.

## Evidence

`capture.sh` writes `<label>.cmd`, `.out`, `.err` and `.rc` under `.gibson-receipts/verify-gibson/<run-id>/<feature-id>/`. That directory is gitignored and is **never deleted by cleanup**. `<run-id>` is `$VERIFY_RUN_ID` or a UTC timestamp. Proof standards:

- Drive the real script on a real input, not a unit test of a copy. A unit suite counts only where the feature file says so.
- Record the action and the result: the command, its exit code, and the line or file that shows the outcome.
- For a mutation (a file written, a label changed), add a read-only second view of the stored value.
- A path you could not run is reported with the command and the unmet precondition, never as verified through another path.

## Cleanup

Remove only what this run created: temporary scratch repos under `$TMPDIR`, and the worktree when the PR has merged (`git worktree remove ../wt-<slug>`). Do not remove `.gibson-receipts/`. Never kill processes by name; stop only ones you started.

## Features

See [features/README.md](features/README.md).
