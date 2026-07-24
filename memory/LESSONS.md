# Fleet Lessons (append-only)

Format: see docs/09. Newest last. Filed by any agent per Law 9; swept weekly by the
historian. These seeds are imported from pre-Gibson history so the fleet starts
with scar tissue, not amnesia.

## L-001 · 2026-07-18 · worktree-isolation-founding-incident
**What happened:** Two sessions edited the same ConferenceOS checkout; one silently
clobbered the other's uncommitted schema work (Broadcast models, `isVendor`,
`smsConsent`); ~75 type errors, recovered only from a stash.
**Root cause:** shared mutable checkout.
**Harness fix:** canonical checkout read-only; all mutation in per-session worktrees
(docs/05 Layer 1).
**Status:** fixed
**Tags:** #concurrency #git

## L-002 · 2026-07 · schema-without-migration-blocks-deploys
**What happened:** A schema edit without a migration file passed CI, then blocked
~20 consecutive production deploys (ConferenceOS #442).
**Root cause:** CI validated code, not migration-history coherence.
**Harness fix:** schema-guard workflow — schema diff without migration file fails
the PR (docs/12).
**Status:** fixed
**Tags:** #schema #ci #vercel

## L-003 · 2026-07-20 · unbounded-coordinator-cost
**What happened:** One 547-message coordinator session cost $119.65 with no
compaction checkpoint; run total $120.68.
**Root cause:** unbounded scope + unbounded context in a metered pool.
**Harness fix:** bounded workers (one issue, exact file list, short output
contract); fresh-context-per-hat; checkpoint before half the window; grind work
routed to flat-rate pools (docs/15).
**Status:** fixed
**Tags:** #cost #routing

## L-004 · 2026-07 · docs-describe-aspiration-not-wiring
**What happened:** RELEASING.md described `release`→prod while Vercel's Production
Branch was `main` — every main merge was a silent prod deploy.
**Root cause:** documentation recorded intent, not verified configuration.
**Harness fix:** adoption audits verify the real Production Branch and write the
truth into the target AGENTS.md (docs/12, docs/13).
**Status:** fixed
**Tags:** #vercel #docs

## L-005 · 2026-07 · reviewer-absence-silently-skips
**What happened:** Mission Control's dispatcher skipped cross-vendor review when the
reviewer CLI was missing (`shutil.which` guard) — good work shipped unreviewed
without anyone deciding that.
**Root cause:** fail-open default on a quality gate.
**Harness fix:** Gibson rule — missing/broken reviewer blocks the merge (docs/06).
**Status:** fix-pending (dispatcher patch — see ROADMAP Phase 2)
**Tags:** #review #fail-closed
