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

Require `"ok": true`. Required tools are git, node, bash, jq, gh (authenticated), the gate script, and a git repo. `shellcheck` and the `MC_*` / `GH_REVIEWER_TOKEN` variables are optional; unset is not a failure. 

## Drive

Each feature file lists exact commands. Wrap every command in the capture helper so the proof is recorded the same way every time:

```bash
bash .agents/skills/verify-gibson/scripts/capture.sh <feature-id> <label> -- <command> [args...]
```

Run `scripts/prepush.sh` first on every change: it takes seconds and covers the probes that fail first push most often. It is not the gate; CI stays the authority, and `NOT RUN` is not a pass.

## Evidence

`capture.sh` writes `<label>.cmd` (the command, shell-quoted so it can be replayed exactly), `.out`, `.err` and `.rc` under `<git-common-dir>/gibson-verify-evidence/<run-id>/<feature-id>/`, in the shared `.git` directory of the repository (`git rev-parse --path-format=absolute --git-common-dir` prints it). That location is outside every worktree, so `git worktree remove` never deletes it, it is never committed, and cleanup must not touch it. `<run-id>` is `$VERIFY_RUN_ID` or a UTC timestamp. `capture.sh` refuses to overwrite: to repeat a recipe, use a new label or a new `VERIFY_RUN_ID`. The `<label>.lock` directory beside the files is the atomic claim that makes the refusal safe under concurrent runs; leave it in place. Proof standards:

- Drive the real script on a real input, not a unit test of a copy. A unit suite counts only where the feature file says so.
- Record the action and the result: the command, its exit code, and the line or file that shows the outcome.
- For a mutation (a file written, a label changed), add a read-only second view of the stored value.
- A path you could not run is reported with the command and the unmet precondition, never as verified through another path.

## Cleanup

Remove only what this run created: temporary scratch repos under `$TMPDIR`, and the worktree when the PR has merged (`git worktree remove ../wt-<slug>`). Do not remove the evidence directory; `git worktree remove` is safe because evidence is not inside the worktree. Paste the paths of the files that prove your claim into the PR body before you remove the worktree. Never kill processes by name; stop only ones you started.

## Features

See [features/README.md](features/README.md).
