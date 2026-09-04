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

**Every run is a full-state sweep.** Stamp `pending` on every open PR head first →
evaluate every open PR at its current head (`--sweep`) → publish every head in an
`if: always()` step. A crash or timeout publishes `failure` on every stamped head; a
cancellation publishes `pending`. A prior `success` never survives a re-evaluation
(the conference-os #1458 fail-open window). Runs are **serialized repo-wide and never
cancelled** (`# gibson:stateful-ci`): the result is keyed by commit SHA but comment and
review events carry no SHA, so per-PR groups let two PRs sharing a head race. GitHub
may still replace a queued run with a newer one; because every run re-derives every
head, a dropped run is harmless. A PR that closes needs no special recovery — its
former sibling is just another open PR in the next sweep.

**Evidence provenance is the creation, not the last edit.** GitHub lets any writer
edit anyone's comment, so a receipt or attestation whose GraphQL `editor` is not its
creator is ignored, and comments are ordered by `created_at`. A `DISMISSED` review
takes part in newest-wins with no verdict, so dismissing a `CHANGES_REQUESTED` never
resurrects an older `APPROVED`. Evidence created before the PR's most recent
`base_ref_changed` timeline event is `stale-base` (pending): a retarget keeps the head
SHA but changes the diff, so it must be reviewed again.
