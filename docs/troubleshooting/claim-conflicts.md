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
assuming it worked. Releasing a still-**open** claim is normally two steps: the
first run closes the PR (that IS the release) and reports `INCOMPLETE` with a
`RECOVERY:` line, because the just-closed PR's terminal evidence is what binds
the worktree and branches it would remove. Re-run the bound form it prints
(`--claim-id <id> --repo owner/name --pr <number>`) to finish the cleanup.
Exit **1** means "refused, nothing done"; exit **3** means "did part of the work,
here is exactly what is left".

## Human gate

G13 — two agents want conflicting approaches and re-queue didn't resolve → decision
card for Mark.

## "repository binding mismatch" on release

`release-claim.sh` refused before touching anything, saying the checkout's origin
repository is not the repository the PR-body claim evidence came from.

That is the intended answer, not a bug. A fork, a mirror, or a second clone
contains the same branch names and the same commits as the original — so "the
branch is here and the commits match" cannot tell you that a worktree and a
branch belong to the claim you are releasing. Only repository identity can.

Check where you are standing:

```bash
git -C "$GIBSON_CANONICAL" config --get-all remote.origin.url
```

- **Wrong checkout** — `cd` to the clone of the repository that owns the PR, or
  set `GIBSON_CANONICAL` to it. Do not pass `--repo` to silence the message;
  `--repo` names the issue/label repository, and it cannot make a different
  clone into the right one.
- **No origin, or more than one `remote.origin.url`** — the checkout has no
  single repository identity. Fix the remote before releasing.
- **A non-GitHub origin** (a bare path, a mirror) — there can be no PR-body
  claim for that checkout, so the release falls back to the ledger and says so.

## "is not the branch this claim id derives" on release

`release-claim.sh` refused **before closing anything**: the open PR carrying this
claim marker has a head branch that is not `feat/<issue>-<slug>`.

`gh pr close` is irreversible, so the PR's identity has to be bound before it, not
discovered afterwards. An exact claim marker in the body of a PR on an unrelated
branch is not authority to close that PR — someone may have copied a marker, or the
lane may have been re-branched by hand. Nothing was mutated: the PR is still open,
the label untouched, the worktree and both branch refs untouched.

Look at the PR before doing anything else. If it really is the claim's PR and the
branch was renamed deliberately, close it by hand and then release the claim
against the now-terminal PR with `--pr <number>`.

## "PR #N is STILL OPEN ... a removed or rewritten marker is not a released claim"

The close reported success and the claim id vanished from the claim inventory —
but the PR itself is still open. The claim inventory only lists a PR while it
carries a well-formed claim marker, so a marker that was deleted or rewritten makes
a live PR *look* closed. `release-claim.sh` cross-checks the exact PR number against
a body-agnostic open-PR inventory and refuses success on the mismatch, preserving
`agent-claimed`, the worktree and both branches.

```bash
gh pr view <number> --repo owner/name --json state,headRefName,body
scripts/pr-claims.sh list-open-numbers owner/name    # is it really still open?
```

Find out why the marker changed before cleaning anything up: either the PR is
genuinely still holding the issue, or somebody edited a claim body by hand.

## "no exact terminal PR-body evidence came back" after a close

The PR was closed — so the claim **is** released — but the run could not read that
PR's own terminal evidence back, so it could not prove the identity of the worktree
or branches it would have removed. It preserved all of them plus `agent-claimed`
and exited 3 with a `RECOVERY:` line. This is the normal two-step shape when the
PR list lags behind the close; it is not an error you have to fix.

Re-run the bound form once the evidence reads cleanly:

```bash
scripts/pr-claims.sh find-terminal-pr owner/name issue-<n>-<slug> <number>   # look first
release-claim.sh <n> --claim-id issue-<n>-<slug> --repo owner/name --pr <number>
```

That path runs the exact verified cleanup and removes the label only after proving
it. The close-only path never removes `agent-claimed` — an absent terminal row is
not evidence that there is nothing left, it is evidence the run cannot see the PR
it just closed.

## "ambiguous terminal PR-body evidence" for a claim id

Two (or more) terminal pull requests carry the same claim id. That is legal: a
claim id is free again once its PR is terminal, so a later lane may reuse it —
and then "which PR is this claim?" genuinely has more than one answer.

Releasing the claim that is still open never hits this; that path binds to the PR
it just closed. To release a specific generation by hand, name it:

```bash
scripts/pr-claims.sh find-terminal-pr owner/name issue-<n>-<slug> <pr-number>   # look first
release-claim.sh <n> --claim-id issue-<n>-<slug> --pr <pr-number> --repo owner/name
```

Naming the PR narrows the question. It does not relax any check: that PR must
still match the claim id, the issue, the derived head branch, the exact head SHA,
the base repository, cross-repository=false, and a terminal state.

## A concurrent lane's claim was refused after its PR was created

Output contains `post-create admission refused`, and the lane rolled back its own
PR, branch, worktree, and label.

This is a race resolving itself, and there are two shapes of it.

**Overlapping scope, different issues.** Two lanes can both pass the pre-create
overlap check, because at the moment each of them looked, neither claim existed
yet. `claim.sh` re-checks after publishing its claim and stands down if an
overlapping claim holds a lower PR number — deterministically, so exactly one lane
survives **provided each lane's PR became visible to the other inside its own
quiescence window** (see the publication barrier below). That window is bounded;
eventual-consistency lag is not, so this is a strong guarantee, not an absolute
one.

**Same issue, disjoint scopes.** Two lanes on one issue under different slugs also
both pass the pre-create duplicate check, and a scope-only re-check clears them
because their files genuinely do not touch. That is one issue being built twice
(L-028). Without `--slice` the same-issue rule is re-applied after publication and
exactly one lane survives; the loser's message says `issue #<n> is already held`.
If a second lane really is what you want, it needs `--slice` **and** a
non-overlapping scope.

Nothing of the winner's is touched: the refused lane closed its own PR, and only
*after* proving that close made its claim stop being live did it delete its own
local and remote branch and remove its own worktree. It left `agent-claimed` alone
whenever a sibling claim on that issue survives, or whenever it could not prove its
own PR was closed. Re-run the claim once the winning lane releases, or claim a
disjoint scope.

## "could not obtain a stable live-claim inventory"

The claim was refused because the live-claim inventory never went quiet. Admission
will not decide from a single read: GitHub's PR listing is eventually consistent, so
a rival created moments before yours can be missing from the page you are served
even after your own claim shows up in it. `claim.sh` re-reads until the inventory
comes back identical on `GIBSON_CLAIM_ADMIT_STABLE_READS` (default 2) consecutive
reads, spaced by `GIBSON_CLAIM_ADMIT_DELAY` (default 2s), giving up after
`GIBSON_CLAIM_ADMIT_ATTEMPTS` (default 6). The reads are taken by
`scope-overlap.mjs` itself — it is not given an inventory by anyone.

You see this when the API is failing, or when the repository is claiming and
releasing fast enough that the view keeps changing under the barrier. It is a
**fail-closed refusal**: the lane rolled back and nothing was admitted on a view it
could not stabilise. Just re-run the claim. If a busy repository trips it
repeatedly, widen the window: **raise** the attempts and the delay.

You cannot lower it. The barrier has a production floor of 2 matching reads spaced
at least 1 second apart; `GIBSON_CLAIM_ADMIT_STABLE_READS=1` or
`GIBSON_CLAIM_ADMIT_DELAY=0` is refused as a usage error rather than honoured,
because a single sample brings back the both-lanes-survive race. There is no
supported switch that turns the barrier off.

## "node required" — the claim refused before it did anything

`scope-overlap.mjs` is the only implementation of the overlap and admission
decision, so `claim.sh` refuses outright on a host without `node`. It refuses
*before* the label, branch, PR or worktree exist, so there is nothing to clean up:
install node (or run the lane from a host that has it) and re-run. The old
stem-grep fallback is gone on purpose — it answered a weaker question, and it ran
only after everything had already been created.

The same shape applies to a failed read: an unreadable or malformed live-claim
inventory refuses before the first mutation. "I could not find out" is never
recorded as "there are no live claims".

## `claim.sh: INCOMPLETE` — a rollback left something behind

A refused claim rolls itself back, but it will not destroy work it cannot prove is
its own and untouched. If, during the admission window, its worktree picked up
uncommitted or untracked files, its branch advanced, the worktree was moved or
switched to another branch, or the remote could not be read, the rollback **keeps**
that artifact, prints `INCOMPLETE` with every leftover named, and exits non-zero.

Rollback does the **claim itself first**, and the artifacts only after. If the run
could not positively bind its own claim PR, could not close it, or could not
freshly prove it stopped being a live claim, then *everything* is retained —
worktree, both branches, and the issue-wide `agent-claimed` label — because they
are all backing a claim that may still be open. Those messages name what happened:

| Leftover message | What actually happened | What to do |
|---|---|---|
| `gh pr close failed` | The PR may still be open, so the claim may still be LIVE. | Close the named PR by hand, then re-run the claim. |
| `STILL a live claim after gh pr close reported success` | GitHub accepted the close but still lists the claim. | Re-check the PR on GitHub; it may be lag, or the close may not have stuck. |
| `could not be re-read to prove the claim is gone` | The close probably worked; the proving read failed. | Re-read `pr-claims.sh list <owner/repo>` yourself, then clean up by hand. |
| `could not be parsed into a PR number ... may exist and be unpublished` | `gh pr create` exited 0 but printed something unparseable. **A PR may exist that nothing here knows the number of.** | Look for an open draft PR on the claim's head branch, close it, then re-run. |
| `gh pr create exited N ... not proof GitHub created nothing` | The create call FAILED and the live inventory shows no claim — but a nonzero exit is only the client's view of the call. GitHub can create the PR and lose the response, and the PR list is eventually consistent, so one empty read proves nothing either. **A real, open claim PR may exist.** | Look for an open draft PR on the claim's head branch (`gh pr list --head feat/<issue>-<slug>`), close it if it is there, then remove the retained worktree/branch by hand and re-claim. Nothing was destroyed on your behalf. |
| `not provably this lane's` | A live PR matched by number but carries someone else's claim id or head branch. | Investigate before touching anything — this lane refused to close a PR it could not prove was its own. |

That output is the work list. For each named item:

```bash
git -C <canonical> worktree list --porcelain        # what is actually registered
git -C <worktree> status --porcelain                # what is in there that you'd lose
git -C <canonical> log --oneline <branch> -3        # what the branch advanced to
git ls-remote --heads origin <branch>               # what origin still has
```

Decide deliberately: keep the work (move the branch somewhere safe, or let the lane
own it again), or remove the artifact by hand once you have looked at it. Never
`rm -rf` a listed worktree without reading its status first — the whole point of the
refusal is that something in there was not accounted for. Note that a kept worktree
also keeps its branches on purpose: a retained tree must not be orphaned from its
own history.

## A lane that was KILLED leaves everything behind

Rollback runs from an EXIT trap, so it protects a lane that fails or refuses — not
one that is destroyed. SIGKILL, a power loss, or a terminal closed before the trap
finishes can leave **all** of: an open draft PR (which is still a LIVE claim), the
`agent-claimed` label, a pushed branch, and a worktree. None of that self-heals and
nothing periodically sweeps it.

Clear it with the reaper, which decides from evidence rather than assertion:

```bash
scripts/claim-reaper.sh                 # dry-run: what it would expire, and why
scripts/claim-reaper.sh --apply         # act
```

If the reaper will not act (it refuses anything it cannot prove is dead), recover
by hand in this order — the claim first, the artifacts after:

```bash
scripts/pr-claims.sh list <owner>/<repo>          # is the claim still live? which PR?
gh pr close <number> --repo <owner>/<repo>        # the close IS the release
scripts/pr-claims.sh list <owner>/<repo>          # prove it stopped being live
scripts/release-claim.sh <issue> --claim-id <id> --repo <owner>/<repo> --pr <number>
```

That last command runs the exact verified cleanup (registered-worktree proof,
head-SHA containment, compare-and-swap branch deletes) and removes `agent-claimed`
only after proving no sibling claim still needs it. Do not delete the worktree or
the branch first: their identity proof is anchored to the terminal PR's head SHA.
