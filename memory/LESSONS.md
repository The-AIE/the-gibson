---
title: "Fleet Lessons"
nav_exclude: true
---

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

## L-006 · 2026-07-24 · doc-backlog-handoff-scope
**What happened:** DOC-BACKLOG P0–P2 handoff executed as focused commits on
`main` per operator instruction, while Law 3 / target-repo rules still say
mutation only in worktrees. Harness self-work on this repo is operator-gated.
**Root cause:** operational contract for *target* repos vs. harness-authoring
workflow were not spelled out as separate lanes.
**Harness fix:** When editing The Gibson itself under an explicit human handoff
to `main`, record it; for product target repos, Law 3 remains absolute. Future:
prefer harness changes via PR + cross-runtime review (D-003) even when the
operator allows direct main for speed.
**Status:** fix-pending (process note; no code gate yet)
**Tags:** #process #gibson #docs

## L-007 · 2026-07-24 · grok-runner-frontmatter-arg-parsing
**What happened:** `scripts/loop.sh`'s grok runner invoked `grok -p "$(cat "$prompt_file")"`.
Rendered playbooks start with YAML frontmatter (`---`), which grok's clap-style
arg parser mis-reads as an unrecognized flag when passed as a value string
rather than a file path — every solo-loop iteration would have failed before
doing any work. Same root cause hit manually during chatterbuilt adoption
(`grok -p "$(cat adopt.md)..."` failed identically; fixed there with
`--prompt-file`).
**Root cause:** passing multi-line, dash-prefixed content as a `-p`/`--single`
argument value instead of via `--prompt-file <path>`.
**Harness fix:** `invoke_runner`'s grok branch now uses `grok --prompt-file
"$prompt_file"`. Untested: whether `claude`/`codex`/`hermes` branches have the
same exposure (same playbook content, different flag conventions) — worth a
dry-run check before relying on them unattended.
**Status:** fixed (grok branch only)
**Tags:** #grok #cli #harness-bug

## L-008 · 2026-07-24 · grok-runner-silent-noop-without-permission-mode
**What happened:** Even after fixing L-007's arg-parsing bug, the solo loop
still burned 100+ iterations against mrhinkle/chatterbuilt with zero real
work — no claim, no worktree, no commit, `gibson/loop-state.md` never
updated. Each iteration returned a shallow one-line paraphrase of its own
instructions in under 10 seconds and exited cleanly (exit 0), so the driver's
error budget never tripped — it looked healthy while doing nothing.
**Root cause:** `invoke_runner`'s grok branch never passed a permission-mode
flag. In headless/non-interactive invocation there's no TTY to approve tool
calls, so grok can't act — it can only narrate. The `claude` branch already
had `--permission-mode acceptEdits`; `codex` had `--full-auto`; grok had
neither.
**Harness fix:** grok branch now passes `--permission-mode bypassPermissions`.
**Detection gap this exposes:** exit-code-based error budgets don't catch
"ran fine, did nothing" — only "crashed." Consider a stronger sensor: if
`gibson/loop-state.md`'s `updated:` timestamp hasn't advanced after N
iterations, treat that as a failure too, not just non-zero exit.
**Status:** fixed (grok branch); detection-gap fix not yet implemented
**Tags:** #grok #cli #harness-bug #permissions
