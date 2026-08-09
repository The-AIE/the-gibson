---
title: "05 · How agents avoid collisions"
parent: The Doctrine
nav_order: 5
---

# 05 — Concurrency: Worktrees, Claims, Hot Files, Lanes

> 🙂 **In plain English:** When several agents work at once, they must not step on each
> other. Each one gets its own private copy of the project, claims its task out loud,
> and stays out of files another agent is already changing.

Four isolation layers, each for a distinct failure mode. All battle-tested in
ConferenceOS; the founding incident (2026-07-18) was a session silently clobbering
another's uncommitted schema work — ~75 type errors, recovered only from a stash.

## Layer 1 — Worktrees isolate files

- The canonical checkout of a target repo is **read-only**. Always.
- Every mutating session cuts its own worktree:
  ```bash
  git -C <canonical> worktree add ../wt-<issue>-<slug> -b feat/<issue>-<slug> origin/main
  cd ../wt-<issue>-<slug> && npm ci --include=dev   # node_modules never shared
  ```
- Two sessions physically cannot clobber each other — they're never in the same
  directory.
- After merge: `git worktree remove`, delete the branch, in the same cleanup pass
  that releases the claim.

## Layer 2 — Claims isolate logical scope

Two mechanisms, used together:

1. **Atomic pre-claim:** `gh issue edit <N> --add-label agent-claimed` — one API
   call, closes the race window to ~zero.
2. **PR-body claim (current form):** `scripts/claim.sh` opens an empty-commit
   draft pull request whose **body** carries the claim:

   ```
   ## Active work

   - Active-work claim: issue-42-password-reset
   - Isolation: dedicated worktree
   - Issue: #42
   - Claim scope: app/api/auth/** lib/email.ts
   - Session: grok@fleet-2
   - Claimed: 2026-08-02T10:14:07Z
   ```

   No file anyone edits, so two lanes claiming at the same moment never conflict on
   a shared path (the old `docs/active-work.md` table *was* exactly the hot file
   this doc tells you to eliminate — every lane appended to the same last line,
   so claiming and releasing conflicted with each other and blocked green product
   PRs that touched none of those issues, L-023). The claim is released the moment
   that PR reaches a **terminal state** — merged or closed
   (`release-claim.sh <issue> --claim-id <id>`, issue #153) — never by hand-editing
   a row.

   Per-file (`docs/claims/issue-<N>-<slug>.md`) and table
   (`docs/active-work.md`) ledger rows are the **legacy** form: still read, still
   released, kept for backward compatibility with claims made by older tooling —
   but `claim.sh` never writes one anymore.

   **One authoritative live-claim view (#153):** every consumer — claim-time
   overlap enforcement, release-time sibling protection, `claims-status.sh` — reads
   the **validated union** of live *open* PR-body claims and legacy ledger rows,
   not either alone. "Validated" is load-bearing: every PR-body row is checked for
   a non-empty scope, a safe head branch, and a PR URL whose own repository
   matches the repo being queried — a missing scope must never silently become an
   empty (non-overlapping) scope, and repository identity is never inferred from
   the query argument alone. A **terminal** (merged/closed) PR is *not* part of
   this live view — it is **release authorization**: evidence that a PR-body
   claim is done and safe to clean up, not a claim still in flight. Once
   released, that claim must be absent/removed from the post-release live view.

   Precedence when releasing one exact claim id: a live *open* PR-body claim is
   released by closing that PR; otherwise a live ledger row is released by
   removing it; otherwise — PR already merged/closed and no ledger row was ever
   written — `release-claim.sh --claim-id <id>` verifies the exact issue, claim
   id, PR number, head branch, exact head SHA, base repository (re-derived from
   the PR's own URL, not the query argument), cross-repository=false, and
   terminal state directly against that finished PR, then proves the *registered*
   worktree at the exact expected path is on that exact branch, clean, and at
   that exact head SHA (or, for a real merge, safely contained in the merge
   commit) before removing anything — never a `rm -rf` of an unregistered or
   default-path directory, never a force-remove of a dirty worktree. No ledger
   row is ever invented. An **open** PR is never accepted as terminal evidence;
   ambiguous, foreign (cross-repository/fork), mismatched, malformed, or
   unreadable PR evidence refuses before any mutation. A CLOSED-but-unmerged PR
   is only cleaned up when that same exact-branch/exact-SHA safety proof holds —
   it is never described as "merged".

   **Terminal lookup is candidate-first (#153):** `pr-claims.sh list` is an
   *inventory* of live work, so it validates every open PR carrying a claim
   marker — a malformed **live** claim is a current defect and poisoning the
   inventory is the right fail-closed answer. `find-terminal <claim-id>` is a
   *lookup for one exact id* across everything the repository has ever merged
   or closed, so it selects the PRs whose body carries that exact claim id
   **first** and validates only those. Otherwise one unrelated historical PR
   whose body predates the marker format (mrhinkle/the-gibson#114 has an
   Active-work claim line and no Claim scope line) permanently blocks every
   future release for every other claim — a fail-closed answer to a question
   nobody asked. Narrowing *which* PRs are inspected never softens the checks
   on the ones that match: duplicate or malformed markers on a candidate, two
   PRs carrying the same exact id, evidence that disagrees with the PR's own
   state, and any gh/jq/pagination failure all still fail the whole command.

   **Legacy terminal-claim schema (#153):** claims that shipped before the
   machine markers existed carry the claim marker and nothing else
   machine-readable — mrhinkle/the-gibson#143, the real motivating case, has
   exactly one `- Active-work claim: issue-139-fleet-profiles`, an exact
   `Closes #139.`, and a `## Cumulative scope` section of backticked path
   bullets, but no `- Claim scope:` and no `- Issue: #`. Refusing those
   forever would mean a claim that genuinely shipped can never be released,
   so `find-terminal` (and only `find-terminal`) accepts a second, strictly
   defined body schema and **parses that body's own evidence** — it never
   invents, defaults, or infers scope or issue data.

   A candidate qualifies as legacy only when **both** current markers are
   entirely absent; a body carrying one of the two is a current-format claim
   missing a required field and still fails on that. Legacy is not a fallback
   for a malformed current claim. A legacy candidate must then carry exactly
   one `Closes #<n>.` line — that is the issue binding, and the claim id must
   agree with `<n>` under the same rule the current format uses — and exactly
   one `## Cumulative scope` heading whose section (up to the next Markdown
   heading) contains only single backticked path bullets. Those parsed paths,
   space-joined, *are* the claim scope, in the same shape `- Claim scope:`
   carries. A marker-only body, arbitrary prose, a bare un-backticked bullet,
   a missing or duplicated closing/scope section, an empty section, an
   absolute/`..`-bearing/unsafe/repeated path, or duplicate claim markers all
   refuse. `list` is deliberately **not** given this schema: an open claim is
   current work, is written by today's `claim.sh`, and must carry today's
   markers.

   **Fail-closed boundary (#153 AC5):** GitHub reads that gate a *mutation*
   decision — the terminal-evidence check above, and the post-mutation reread
   that decides whether to remove `agent-claimed` after a GitHub-native (PR-body)
   release — never swallow a query failure. A failed or malformed read there
   preserves the label and exits incomplete (`3`), not `0`. The ledger-only path
   (a caller that never asked for GitHub-native evidence) keeps its historical
   best-effort `2>/dev/null || true` sibling lookup — a `gh` hiccup there falls
   back to ledger-only residual rather than blocking a plain ledger release, per
   the same legacy back-compat contract `claims-status.sh` and `scope-overlap.mjs`
   already followed before PR-body claims existed.

   Read live claims with `scripts/pr-claims.sh list <owner/repo>` (PR-body) or
   `scripts/claims-status.sh` (`--issue <n>`, `--markdown`, merges PR-body **and**
   legacy forms, flags claims older than 24h). Both read `origin/main`/live GitHub
   state, not your working tree — a stale local checkout is how two lanes each
   conclude they are alone.

**One issue, one lane — unless you say otherwise.** `claim.sh` refuses an issue that
already has a live claim: two builders took the same issue under different slugs and
burned a full build each, twice (L-028). A big issue legitimately ships in slices
(L-024), so a deliberate second lane passes `--slice` and must have non-overlapping
scope. Release a slice with `release-claim.sh <issue> --claim-id <id>`, which keeps
the siblings and keeps the label.

Before claiming: read live claims. Overlap with your intended scope → stop and
coordinate (different issue, or wait). Never race a live claim.

**Reading live claims is not atomic — so the claim is admitted twice.** Two lanes
claiming *different* issues with overlapping scope can each read an inventory that
does not yet contain the other's claim, both pass the pre-create check, and both
survive with overlapping scope. The same-issue refusal above cannot catch that:
the issues genuinely differ. So `claim.sh` re-runs the overlap check **after** its
draft PR exists (`scope-overlap.mjs --admit-pr <number>`), and resolves the race on
evidence both lanes can read:

- this lane's own claim must be visible in the authoritative inventory, or the
  claim is refused — an inventory that cannot see the claim proves nothing about
  who else holds the scope;
- an overlapping live PR-body claim with a **lower PR number** wins. GitHub
  assigns PR numbers uniquely and monotonically, and the number is issued in the
  same step that publishes the claim, so both racers compute the same winner;
- an overlapping ledger claim always wins — it was never part of this race.

Exactly one lane survives. The loser rolls back **only what it created** — its own
PR, branch, worktree, and the `agent-claimed` label if it was the one that added it
(a label a sibling slice already held is left alone) — and exits non-zero. There is
no lock file and no repo-global state, so a lane that is killed mid-claim leaves
nothing behind for the next one to trip over.

**Seeing yourself is not seeing everyone — so admission waits for the inventory to
go quiet.** GitHub's pull-request listing is eventually consistent. A rival claim PR
created moments *before* this one can still be missing from the page served to this
lane after its own row has appeared, so a lane that decides on the first read
containing itself can admit itself against a rival it simply has not been shown yet
— and the rival, reading a view that does contain this lane, yields to it. Both
survive. Admission therefore does not decide on one sample. It re-reads the
inventory, spaced by `GIBSON_CLAIM_ADMIT_DELAY`, until the claim-relevant projection
of it (PR number, claim id, scope) comes back **identical on
`GIBSON_CLAIM_ADMIT_STABLE_READS` consecutive reads that all contain this lane's own
claim**, and decides on that settled view — the same one handed to
`scope-overlap.mjs` via `--pr-claims-file`, so the barrier is not thrown away by a
re-read one line later.

> **Invariant:** the verdict is computed from a *quiescent* inventory — one that
> stopped changing across a window of at least `(STABLE_READS - 1) x DELAY`
> seconds — never from a single sample.
>
> **Bounded failure, stated plainly:** quiescence bounds the race, it does not
> abolish it. Correctness holds when a rival created before this lane becomes
> visible within that window. A replica lagging longer than the whole window can
> still hide it, and no client-side read can fix that — closing it completely
> needs a strongly-consistent reservation GitHub does not offer. Everything
> outside the window fails **closed**: an inventory that never settles, or reads
> that keep failing, exhaust `GIBSON_CLAIM_ADMIT_ATTEMPTS` and the claim is
> refused and rolled back rather than admitted on evidence it could not stabilise.
> Refusing is safe and re-runnable; admitting on a partial view is neither.

**Same-issue exclusivity is re-decided after publication too.** Two lanes on the
*same* issue with different slugs and **disjoint** scopes both pass the pre-create
duplicate check (neither is published yet) and both pass a scope-only re-check,
because their scopes really do not touch — which is L-028 (one issue, two builds)
happening again through a different door. So the same-issue rule is re-applied
against the quiescent inventory, with the same lower-PR-number tie-break: without
`--slice` exactly one lane survives and the other rolls back; with `--slice`,
same-issue siblings remain legal and the scope check is what keeps them disjoint. A
live claim id whose issue number cannot be parsed is ambiguous evidence about
siblinghood and refuses rather than being assumed to be a different issue.

**A losing lane preserves work it cannot prove is its own.** Rollback runs the same
protections as terminal cleanup — shared as `scripts/lib/claim-guards.sh`, not
copied, so a fix to one is a fix to both. The worktree is the one `git worktree
list --porcelain` says is on this branch (never assumed from its path), and it must
be the exact path this lane created, clean, and still at the exact commit this lane
made; local and remote branch deletion are compare-and-swap against that same
commit. During the admission window a worktree can go dirty and a branch can
advance, so anything unprovable is **kept, named, and reported**: the lane closes
its own PR, prints `INCOMPLETE` with every leftover listed, and exits non-zero
rather than force-removing a dirty worktree or deleting a branch that moved. The
`agent-claimed` label is issue-wide, not this lane's property just because this lane
added it — two racers on one issue can both read it as absent and both add it — so
it is removed only after a fresh authoritative sibling inventory proves no surviving
sibling needs it **and** a fresh label read proves what is actually there. An
unreadable or malformed inventory, or an unreadable label, keeps the label.

**Repository identity is proven, not assumed (release side).** A claim's PR-body
evidence authorizes deleting a worktree, a branch, and a label. Before acting on
it, `release-claim.sh` proves that `GIBSON_CANONICAL`'s own origin remote **is** the
repository that evidence came from: the origin URL is normalized to `owner/name`
(https, `ssh://`, scp-like `git@github.com:owner/name.git`, optional port, optional
`.git`, case-insensitive) and compared. A fork or a second clone contains the same
branch names and the same commits by construction — that is not identity, and it is
refused before any mutation. A missing, multi-valued, or non-GitHub origin is
refused for those paths too, and if repository identity cannot be resolved at all
(no `--repo`, `gh repo view` failing, origin unreadable) the run stops **before**
any mutation rather than skipping the authoritative inventory and cleaning up on a
view it never read.

**A released claim id may be reused — and that makes the id ambiguous forever
after.** Once a claim's PR is terminal the id is free again, so a second generation
can legitimately open a second PR carrying the same id. The id-only terminal lookup
then has two answers and correctly refuses. The resolution is to ask a narrower
question, not to accept a guess: the release path binds to the PR number it already
knows (the open PR it just closed), and an operator releasing an older generation
by hand names it with `release-claim.sh <issue> --claim-id <id> --pr <number>`.
Every evidence check — claim id, issue, derived head branch, exact head SHA, base
repository, cross-repository=false, terminal state — still applies to that exact
PR.

**Staleness:** claims older than 24h are verified (does the branch/worktree show
activity?) before being renewed or released. Renew only the timestamp; never strip
someone else's claim without verification.

**Claim reaper (dead lanes):** when a lane crashes and never releases, the claim
row, `agent-claimed` label, and worktree block the fleet indefinitely. Run
`scripts/claim-reaper.sh` (dry-run by default; `--apply` to act) to expire claims
from **evidence**, not assertion:

- Ledger source is always a **successful fetch** of the exact remote base
  (`origin/main` or `origin/master`). Failed fetch refuses — never fall back to
  local main/master, cached stale refs, HEAD, or another branch.
- Each claim freezes a canonical identity: actual path, regular-blob OID, body
  claim id, filename (`docs/claims/<id>.md` must match body id), issue field
  (must agree with the id-derived issue number), branch, and worktree. Duplicate
  logical ids, filename/body mismatch, wrong object modes, and issue mismatches
  refuse before any plan/comment/mutation. Pre-mutation reparse must match.
- Feature-branch liveness uses an **exact live remote query** (`ls-remote` +
  fetch of `refs/heads/<branch>`), never a cached `origin/<feature>` tip.
  Branch/ref syntax is validated before any Git command. Query/auth/network/
  malformed/multiple-result failures **REFUSE**. A proven-absent remote branch
  drops stale remote-tracking evidence rather than treating it as live. Plan
  freezes the live remote SHA; apply re-checks live and refuses if SHA or
  timestamp moved.
- Last-active time is the maximum valid evidence among: claim timestamp, local
  branch tip, **live** remote branch tip, registered worktree tracked-file mtime,
  and optional heartbeat files (`--heartbeat-dir/<id>` and
  `--heartbeat-dir/<id>.heartbeat`). Nonempty malformed heartbeat content
  refuses (never mtime fallback). Future timestamps and oversized integers
  refuse; integers are validated lexically before any Bash arithmetic.
- Default threshold is **14400 seconds (4 hours)** — deliberately more
  conservative than the 15-minute telemetry "presumed dead" line in docs/11.
- An open PR always protects the claim (parked ≠ dead).
- Fail closed on API/ref failures, malformed evidence, unregistered or unsafe
  worktree paths, symlink/device evidence, future-clock evidence, or race-time
  activity. Never closes the issue.
- Default apply releases the exact claim id via `release-claim.sh --claim-id …
  --keep-branch --keep-worktree`, binding the frozen path/blob OID through
  release-claim's authoritative fetch, cleanup commit, and normal push (CAS).
  If evidence changes after the initial check, before release, or before push,
  mutation is incomplete; the claim row and label survive. Journals under an
  apply lock (never before lock; never through a symlink). A COMPLETED journal
  is idempotent only when remote evidence still proves the claim absent — a
  re-added live claim is re-evaluated, never silently skipped. After
  `release-claim` returns success **and** an authoritative post-release reread
  proves the claim absent, posts exactly one deduplicated handoff comment with
  an inert marker (no absolute worktree paths). A CAS mismatch, renewal,
  fetch/query failure, push rejection, prune failure, or any incomplete release
  must not leave a comment claiming release. If cleanup succeeds but the
  comment post fails, the operation is incomplete (no overall success); a later
  retry with the claim already absent posts the missing success comment exactly
  once. `--prune-worktrees` may remove only the exact frozen registered
  worktree path, and only **after** CAS validation, cleanup push, and
  authoritative post-mutation reread prove the exact target claim is absent
  (revalidated immediately before removal; no default-path derivation; no
  `rm -rf` fallback). Renewal, push rejection, OID mismatch, or reread failure
  leave the registered worktree and branch untouched. Final worktree-removal
  failure reports incomplete (no false OK).
- Removing `agent-claimed` requires a **readable** live claim view. A sibling
  claim on the same issue can be a live *open PR-body* claim with no ledger row
  at all, so a PR-claim inventory the run could not read is not evidence that
  none exists. That read used to be best-effort and an API failure counted as
  "no siblings" — which is how a live lane could lose its label to a janitor.
  A failed or malformed inventory read now preserves the label and reports
  incomplete; the claim is re-reaped on a later run.
- Scheduling and Mission Control integration are follow-ups; this script is the
  standalone Tier B janitor.

## Layer 3 — Hot-file rules isolate merge conflicts

Hot files are files many issues want to touch. Default rules:

- `schema.prisma` (or any DB schema): **additive-only, one claimant at a time**,
  models named in the claim row. Schema changes ride their own issues and PRs.
- `package.json`: avoid new dependencies (prefer REST/fetch over vendor SDKs);
  unavoidable deps land in their own commit.
- **De-hot everything you can.** The superior fix is making the file generated:
  auto-discovered nav/report/route barrels regenerated by script (`npm run gen:*`),
  never hand-edited. Improving affordances like this is first-class builder work.

Target repos list their specific hot files in their `AGENTS.md` Gibson section.

## Layer 4 — Serialization isolates production state

- **One schema merge in flight at a time**, fleet-wide, human-gated.
- Deploy-time guard: the build script diffs schema drift and applies only approved
  additive changes — destructive/unknown SQL is rejected (doc 12).

## Lane limits

- **Max 3 active mutating lanes** per target repo (claims + worktrees). Read-only
  work — recon, review, evaluation, research — parallelizes freely and doesn't
  count.
- Mission Control's dispatcher claims tasks atomically (guarded compare-and-set on
  the queue row), so two dispatchers can't win the same task.
- **Known seam (roadmap):** the MC task queue and per-repo claim rows are separate
  systems. Until the dispatcher understands repo claims, route MC tasks for the
  same repo through the claim protocol above — the dispatched agent's first act is
  claiming, and a claim conflict re-queues the task rather than racing.

## Rebase discipline

Before push: `git fetch origin && git rebase origin/main`; resolve conflicts in
*your* worktree. Merge small units fast — long-lived branches are where clobbering
comes back. Never force-push main.

---
[← 04 · From plan to to-do list](04-plan-to-issues.md) · [Home](../index.md) · [06 · Must-pass quality checks →](06-quality-gates.md)
