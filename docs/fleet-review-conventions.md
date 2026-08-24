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
