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

**The honest limit — owner-identity commits.** Claude, Codex, and Grok CLI lanes often
commit under the owner's identity. A machine cannot attribute those to a vendor, so
they are `identity-unresolved` (failure) unless the owner attests at the exact head:

```
<!-- owner-review-attestation:v1
head-sha: <40 hex>
author-vendor: grok|codex|claude|devin|human
-->
```

An attestation resolves identity only; it is never a review, and it is trusted on
the owner's word. The durable fix is per-lane bot identities (#67).

**Reason tokens** (the status description, ≤140 chars): `pass` → success;
`no-receipt-at-head`, `stale-head-only` → pending (blocks merge, no red);
`same-vendor-reviewer`, `identity-unresolved`, `changes-requested`, `head-moved`,
`config-error:<detail>`, `api-error:<detail>` → failure.

**Publish sequence.** Resolve head via API → POST `pending` first → evaluate → publish
in an `if: always()` step. A crash or timeout publishes `failure`; a cancellation
publishes `pending`. A prior `success` never survives a re-evaluation (the
conference-os #1458 fail-open window).
