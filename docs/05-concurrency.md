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
2. **Claim file:** `scripts/claim.sh` writes **one file per claim** at
   `docs/claims/issue-<N>-<slug>.md`, committed **directly to main** and pushed
   immediately (the single exception to worktree isolation — claims must be visible
   instantly):

   ```
   claim: issue-42-password-reset
   issue: 42
   claimed: 2026-08-02T10:14:07Z
   scope: app/api/auth/** lib/email.ts
   session: grok@fleet-2
   branch: feat/42-password-reset
   worktree: /Code/wt-42-password-reset
   ```

   It used to be an appended row in a shared `docs/active-work.md` table, and that
   table became exactly the hot file this doc tells you to eliminate: every lane
   appended to the same last line, so claiming and releasing conflicted with each
   other and blocked green product PRs that touched none of those issues (L-023).
   Separate paths cannot conflict. Legacy rows are still read and still released,
   so a target repo mid-migration is safe.

   Read the ledger with `scripts/claims-status.sh` (`--issue <n>`, `--markdown`),
   which merges both forms and flags claims older than 24h. It reads `origin/main`,
   not your working tree — a stale local checkout is how two lanes each conclude
   they are alone.

**One issue, one lane — unless you say otherwise.** `claim.sh` refuses an issue that
already has a live claim: two builders took the same issue under different slugs and
burned a full build each, twice (L-028). A big issue legitimately ships in slices
(L-024), so a deliberate second lane passes `--slice` and must have non-overlapping
scope. Release a slice with `release-claim.sh <issue> --claim-id <id>`, which keeps
the siblings and keeps the label.

Before claiming: read live claims. Overlap with your intended scope → stop and
coordinate (different issue, or wait). Never race a live claim.

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
  re-added live claim is re-evaluated, never silently skipped. Posts a
  deduplicated handoff comment (no absolute worktree paths). `--prune-worktrees`
  may remove only the exact frozen registered worktree path, and only **after**
  CAS validation, cleanup push, and authoritative post-mutation reread prove the
  exact target claim is absent (revalidated immediately before removal; no
  default-path derivation; no `rm -rf` fallback). Renewal, push rejection, OID
  mismatch, or reread failure leave the registered worktree and branch
  untouched. Final worktree-removal failure reports incomplete (no false OK).
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
