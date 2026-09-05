**Authority:** Non-normative — reference conventions, on-demand. The operative gates for this repo are its own (`.gibson-gate.json`, `gate.sh`, contract-authority); this doc describes shared fleet review discipline, it does not add gates here.

## Fleet review conventions (waterfalled from ConferenceOS, 2026-08-24)

These are portable across every fleet repo. The tools live in `~/.claude/fleet/`; the discipline is:

- **Severity contract on reviews.** Only a finding that causes incorrect behaviour, data loss,
  security/privacy exposure, or a false gate signal — with a concrete trigger, reachable in the diff —
  BLOCKS. Everything else is a non-blocking note. `codex-review.sh` appends this automatically. A
  documented limit is a note, not a blocker.
- **Spec-review before implementation.** Run `~/.claude/fleet/spec-review.sh <spec>` before dispatching
  a non-trivial change — parallel adversarial lenses catch design errors while they are cheap. One pass.
- **Self-review before reporting back.** Check your own diff against the seven recurring defect classes
  (fail-open, false gate signal, proxy check, exit-0-after-failure, side-effect-before-check,
  author's-own-example, workflow-expression validity) in `~/.claude/fleet/dispatch-spec-template.md`.
- **Mutation-proof any guard/sensor change.** Break the property, show the test RED, restore, show GREEN.
  A test that cannot fail proves nothing. One mutation proves one mutation — enumerate the evasion space.
- **One working directory per agent.** A git worktree per lane, disjoint file scopes. Never two agents
  in one checkout — they corrupt each other's index and branch state within seconds. This is a hard rule
  with no exceptions; it is separate from, and stricter than, the coordinator rule below.
- **One coordinator per repo.** Count coordinators before adding one. A second coordinator on the same
  branch corrupts work — check for recent driver comments before touching a PR.
- **Clear the blocker before decomposing behind it.** Above ~40% dependency-blocked, stop filing work
  that inherits the blocker; land the blocker.
- **Sync the lane before diagnosing.** A stale lane makes CI report the wrong cause entirely. Run
  `~/.claude/fleet/lane-sync.sh` first.
- **Independence floor.** The coordinator may MERGE after an independent cross-vendor review passes, but
  never REVIEWS its own work. A reviewer that authored (or coordinated) the change cannot vouch for it.

## Review evidence on the Gibson itself (#308, 2026-09-04)

Law 5 ("missing or broken reviewer blocks merge — fail closed") is enforced on the
loop path by `loop-handoff` and `second-opinion.sh`. On the interactive path it was
prose: over 2026-08-15 → 09-04, 16 of 34 merges carried no cross-vendor verdict on
GitHub and 8 had no review event at all. `.github/workflows/pr-review-evidence.yml`
+ `scripts/pr-review-evidence.mjs` publish a `review-evidence` commit status on every
PR head. Making it a required check is the owner's call (G12):

```bash
gh api -X PATCH repos/The-AIE/the-gibson/branches/main/protection/required_status_checks \
  --input <(gh api repos/The-AIE/the-gibson/branches/main/protection/required_status_checks \
    | jq '{strict: .strict, contexts: (.contexts + ["review-evidence"] | unique)}')
```

**What counts as evidence** (anything else is ignored; ignored fails closed):

1. A formal GitHub review at the **current** head (`commit_id == headRefOid`) by a
   listed Bot identity with role `reviewer`, state `APPROVED` or `CHANGES_REQUESTED`.
   `DISMISSED`, `PENDING`, `COMMENTED` are ignored. Per identity the newest wins.
2. An issue comment authored **via a listed App** (`performed_via_github_app.slug`,
   and `.id` when configured) carrying:

   ```
   <!-- review-evidence:v1
   head-sha: <40 hex, the current head>
   result: pass|fail
   -->
   ```

**Who may review what.** `config/review-evidence.v1.json` is a closed identity table
(login → vendor → roles). Introduced commits come from the PR commits API (never
`git log`; the workflow runs trusted default-branch code and has no PR objects).
Every author and committer must resolve through the table; the reviewing identity's
vendor must differ from every author vendor; `unknown` is never eligible.

**The honest limit — unverified commits.** GitHub resolves a commit's login from the raw
git email, which any pusher can set, so a login is trusted only when GitHub itself
signed the commit (`commit.verification.verified`: API-created and web-UI commits,
e.g. Devin's). Every CLI-made commit — the owner's, and the lane bots' via
`bot-commit.sh` — is unsigned and therefore `identity-unresolved` (failure) unless the
owner attests the vendor at the exact head. The coordinator posts this when it commits a
lane; a GitHub-signed commit path for lane bots would retire it:

```
<!-- owner-review-attestation:v1
head-sha: <40 hex>
author-vendor: grok|codex|claude|devin|human
-->
```

`author-vendor:` is a comma-separated list naming EVERY vendor that produced an
unverified commit on this head. It is head-wide and it unions: an unsigned commit whose
login resolves to a listed bot adds that bot's vendor too, so an attestation can add
authors to the exclusion set, never remove one (a mixed Grok+Devin PR attested as
`grok` still excludes Devin as a reviewer). A list containing an unknown value is
ignored whole. An attestation resolves identity only; it is never a review, and it is
trusted on the owner's word. The durable fix is per-lane bot identities (#67).

**Residual window (documented, not hidden).** The workflow resolves the head via the
API and falls back to the event's head so `pending` is stamped even when the API call
fails. Review and comment events carry no head in their payload; if the API is down
during one of those, nothing can be stamped and the step fails loudly with a summary
line. A prior `success` on that head survives until the next event. Making the
context required does not widen this window; it only makes the stale success visible.

**Reason tokens** (the status description, ≤140 chars): `pass` → success;
`no-receipt-at-head`, `stale-head-only` → pending (blocks merge, no red);
`same-vendor-reviewer`, `identity-unresolved`, `changes-requested`, `head-moved`,
`ambiguous-head` (the head is the head of more than one open PR: a commit status is
keyed by SHA, so no verdict is published rather than one PR overwriting another's),
`config-error:<detail>`, `api-error:<detail>` (including `commits-truncated`: the PR
commits endpoint caps at 250 silently, so the count must match the PR's own) → failure.

When activating, bind the required context to the GitHub Actions app so another
write-capable integration cannot set it: pass `checks: [{context: "review-evidence",
app_id: 15368}]` in the branch-protection payload instead of a bare context string.

**Triggers are a trust boundary.** Only events whose workflow file GitHub reads from
the default branch may trigger it: `pull_request_target`, `issue_comment`, `schedule`
(hourly). `pull_request_review` is a `pull_request`-class event that runs the workflow
file from the PR's merge commit, so a collaborator could edit the workflow in a PR and
use its status-write token; `workflow_dispatch` can be pointed at any branch's copy of
the file. Both are deliberately absent (the first was proven live on #315 before it was
removed); a review submitted with no other activity is picked up by the hourly sweep.

**Status churn is a cap.** GitHub allows 1,000 statuses per commit and context; after
that every write fails and whatever was last written freezes. So `pending` is stamped
only on the event's own head (never on every open head, which let a fork author pace
edits to burn a quiet head's budget), every other head is written only when its state
or description differs from the one already on it, scheduled sweeps stamp nothing, and
every status write is checked: a failed write, including a failed pending stamp, makes
the job red and is never counted as published. Residual: a scheduled sweep that crashes
or times out before publishing leaves the previous status until the next successful
sweep, at most an hour.

**Every run is a full-state sweep.** Stamp `pending` on every open PR head FIRST, before
any checkout or tool setup → evaluate every open PR at its current head (`--sweep`) →
publish every head in an `if: always()` step. A `success` is re-checked against a fresh
state fingerprint (updated_at, head, base, comment and commit counts) right before it is
written and downgraded to `pending` if anything moved. A crash or timeout publishes
`failure` on every stamped head; a cancellation publishes `pending`. An edited machine
receipt or a tampered attestation is a tombstone that holds its place in newest-wins,
never an absence that lets an older verdict resurface. A prior `success` never survives a re-evaluation
(the conference-os #1458 fail-open window). Runs are **serialized repo-wide and never
cancelled** (`# gibson:stateful-ci`): the result is keyed by commit SHA but comment and
review events carry no SHA, so per-PR groups let two PRs sharing a head race. GitHub
may still replace a queued run with a newer one; because every run re-derives every
head, a dropped run is harmless. A PR that closes needs no special recovery — its
former sibling is just another open PR in the next sweep.

**Evidence provenance is the creation, not the last edit.** GitHub lets any writer
edit anyone's comment, so: an App receipt that was edited at all is void (machines do
not edit their receipts); an owner attestation edited by anyone but the owner, or
edited with no recorded editor, is ignored; comments and attestations are ordered by
`created_at`. A `DISMISSED` review takes part in newest-wins with no verdict, so
dismissing a `CHANGES_REQUESTED` never resurrects an older `APPROVED`. A deleted
comment is invisible to the API, so any `comment_deleted` timeline event at or after
the newest eligible pass voids that pass (`evidence-deleted`, pending) until a fresh
review. Evidence created at or before the PR's most recent `base_ref_changed` timeline
event is `stale-base` (pending): a retarget keeps the head SHA but changes the diff.
The job has no event narrowing at all: a skipped run still replaces the queued run in
the group, so every event, including a comment on a plain issue, runs the sweep.
