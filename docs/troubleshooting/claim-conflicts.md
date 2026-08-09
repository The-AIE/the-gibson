---
title: "Claim conflicts"
nav_exclude: true
---

# Claim conflicts

> 🙂 **In plain English:** "Claiming" an issue is how an agent says "I'm working on
> this, don't start it too." Today that claim usually lives in the body text of a
> draft pull request (a proposed change waiting for review) — not in a shared file
> anyone has to edit. This page is what to do when a claim looks stuck, conflicts
> with another one, or won't release.

## Symptoms

- `claim.sh` exits: scope overlap with live claim
- Two worktrees both editing `schema.prisma`
- Stale claim row >24h with no activity
- `release-claim.sh <issue> --claim-id <id>` says "no live claim ... at
  origin/main" even though the draft PR for that claim already merged or closed

## Why

Claims isolate *logical* scope; worktrees isolate *files* ([docs/05](../05-concurrency.md)).
Racing a live claim re-creates L-001.

There are two places a claim can live, and both are checked together — this is
the **one authoritative live-claim view** (issue #153): the **validated union**
of live *open* PR-body claims and legacy ledger rows.

1. **PR-body claims (current, primary).** `claim.sh` opens a draft pull
   request whose description carries the claim (`- Active-work claim: ...`).
   This is what `claim.sh`/`release-claim.sh`/`scope-overlap.mjs` mean by a
   "live PR-body claim." Every row is validated before it counts — non-empty
   scope, a safe head branch, a PR URL whose own repository matches the one
   being queried (never trusted from the query argument alone) — malformed,
   truncated, or foreign-repo evidence refuses rather than silently dropping
   or under-counting a claim. It is released the moment that PR reaches a
   **terminal** state — merged or closed — and needs no file anyone edits. A
   terminal PR is *not* itself a live claim: it is **release authorization**,
   evidence used once to clean up, and the claim it names must be gone from
   the live view afterward.
2. **Legacy main-ledger rows (still supported).** Older claims recorded a row
   in `docs/active-work.md` or a file under `docs/claims/`. New claims never
   write one; existing rows are still read and released for backward
   compatibility.

**Precedence when releasing one exact claim id:** a live *open* PR-body claim
is released by closing that PR; otherwise a live ledger row is released by
removing it; otherwise — if the claim's PR has already **merged or closed**
and no ledger row was ever written — `release-claim.sh --claim-id <id>`
verifies the exact issue, claim id, PR number, head branch, exact head SHA,
base repository (re-derived from the PR's own URL), cross-repository=false,
and terminal state directly against that finished PR. Only after every one of
those checks passes does it prove the *registered* worktree at the exact
expected path is on that exact branch, clean, and at that exact head SHA (or
safely contained in the merge) — and only then remove the worktree, branch,
and label. It never `rm -rf`s an unregistered/default-path directory, never
force-removes a dirty worktree, and never invents a ledger row. An **open** PR
is never accepted as terminal evidence — wait for it to merge or close, or
release the open reservation the normal way (bare `release-claim.sh <issue>`,
no `--claim-id`, closes the still-open draft PR). A CLOSED-but-unmerged PR is
cleaned up only when that same exact-branch/exact-SHA proof holds — it is
never reported as "merged". After mutation, the GitHub reread that decides the
label is **fail-closed**: a query failure or malformed result there preserves
`agent-claimed` and reports incomplete rather than guessing.

## Checklist

| Check | Action |
|---|---|
| See live claims | `scripts/pr-claims.sh list owner/repo` (PR-body) and `docs/active-work.md` / `docs/claims/` (legacy) |
| Same hot file | Serialize with `Blocked by #N`; don't parallelize |
| Stale >24h | Verify worktree/branch activity; renew timestamp **or** release after verification |
| Wrong session | Never strip someone else's claim without verification |
| Label without any claim | `release-claim.sh` or manual: remove label |
| "no live claim ... at origin/main" but the draft PR already merged/closed | Re-run with the exact `--claim-id <id> --repo owner/name` — release-claim.sh now verifies against the finished PR directly (see Recovery) |

## Recovery

```bash
# See live claims (PR-body — the current, primary form)
./scripts/pr-claims.sh list owner/repo

# See live claims (legacy ledger — still supported)
cat docs/active-work.md
ls docs/claims/

# If your claim's PR is still open and you're abandoning it
./scripts/release-claim.sh <issue>

# If your claim's PR already merged or closed and release said "no live
# claim" — release the exact claim id against that finished PR:
./scripts/release-claim.sh <issue> --claim-id <exact-claim-id> --repo owner/name

# If conflict: different issue or wait — never force
```

A release that reports `INCOMPLETE` (exit 3) means the label or the finished
PR's evidence didn't verify cleanly — fix by hand and re-run rather than
assuming it worked.

## Human gate

G13 — two agents want conflicting approaches and re-queue didn't resolve → decision
card for Mark.
