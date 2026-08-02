---
name: gibson-run
description: "Start and supervise the Gibson development loop against a wired repo: cost-routed runners (Grok volume, Codex second/review, Claude judgment, Devin merge captain), error budgets, escalation, kill switch, and a plain-English digest for the owner. Final stage of the /gibson pipeline; also standalone ('start the loop', 'run the fleet on <repo>', 'resume gibson development')."
---

# gibson-run — the loop itself

The loop is `scripts/loop.sh` in the Gibson clone (doctrine: `docs/11`). This
skill's job is to invoke and SUPERVISE it — not to reimplement it.

## Starting

```bash
# default shape (routing table from gibson-resources):
./scripts/loop.sh --runner grok --repo <target-worktree> \
    --escalate-after 2 --reviewers codex,claude
# add ONLY after the owner's explicit ACU-spend OK for this run:  --supervisor devin
```

**Two preconditions before the first invocation, no exceptions:**
- `<target-worktree>` must be a dedicated worktree/clone — `loop.sh` writes
  `gibson/loop-state.md` + journal into the repo it's pointed at, so pointing
  it at the canonical checkout violates Law 3.
- `--supervisor devin` makes `loop.sh` run `ensure` (creates a billed session
  if none exists) AND every branch handoff spends ACUs even against a live
  session. Both are spend: get the owner's explicit OK to enable the supervisor
  for this run before passing the flag — a pre-existing live session does NOT
  waive that, since the handoffs themselves bill.

- `--runner`: implementer from the routing table (Grok default — flat-rate).
- `--escalate-after 2 --reviewers codex,claude`: two consecutive failures buys
  a cross-vendor second opinion BEFORE the error budget kills the lane —
  judgment tokens spent exactly when cheap volume has failed twice.
- `--supervisor devin`: finished branches hand off to the cloud supervisor
  (docs/22) via `handoff:` in loop-state. **Default handoff = Devin reviews the
  handed-off branch and opens/owns the PR but leaves the merge to a human.**
  The handoff now pins the exact head SHA (loop-state's `handoff_sha`, or the
  remote tip): the driver fetches that commit if this clone lacks it, requires a
  distinct-vendor review of that exact SHA against the repo's resolved default
  branch, and passes `--sha` so the supervisor rejects the handoff if the tip has
  moved. Any failure in that chain blocks the handoff and leaves the branch
  queued in loop-state — no review, no handoff. Automated
  non-Tier-C merges require the `--merge` handoff mode per docs/22 — and note
  honestly: `loop.sh` currently invokes handoff WITHOUT `--merge`, so full
  auto-merge needs either that flag wired into the loop or a direct
  `devin-supervisor.sh handoff --merge` call. Don't tell the owner merges are
  automated until that's true. Tier C parks at the human gate in every mode.
- No Devin wired? Drop the flag; the loop's own review path applies, and the
  digest tells the owner what wiring Devin would take.

## Supervising (the orchestrator's own loop)

Check in on a cadence (10–30 min): read `gibson/loop-state.md` + journal tail.
- **Progressing** → log one line, next check-in.
- **Same failure twice across check-ins** → that's a harness gap (docs/09):
  capture it as a lesson in `memory/LESSONS.md`, adjust, don't just watch it
  burn budget.
- **Loop stopped** (error budget, HALT, or done) → diagnose from the journal;
  restart, reroute the failing lane to a different vendor, or report — never
  silently leave the fleet dead.
- **Owner-gate items** (Tier C parks, product-direction questions from
  builders) → batch into the digest; interrupt only per `docs/14`.

## The digest (the owner's entire view)

Plain English, Ask Contract for anything needing a decision. Shipped / in
review / parked-awaiting-you / blocked+why / cost notes (which pools carried
the load; flag if Claude-cap headroom or Devin ACUs are running hot). Never
show raw diffs or expect the owner to read code — describe behavior changes.

## Hard lines

- Kill switch respected instantly: the `gibson/HALT` file is the permanent stop
  `loop.sh` checks every iteration, and `GIBSON_HALT=1` is checked
  unconditionally beside it — neither depends on `gh`. The `gibson-halt` label
  is only a soft cue, honored when `gh` happens to be available; making a stop
  permanent still means the HALT file.
- Law 5 always: reroute so no lane ever reviews its own work, even when a
  vendor is down. **The supervisor handoff path is now machine-enforced:
  `loop.sh` runs a mandatory distinct-vendor review of the exact SHA it is about
  to hand off, and a missing, stale, or failed review blocks the handoff — the
  branch stays queued in loop-state rather than reaching Devin. The remaining
  gap is the loop's ordinary per-hat path (no supervisor configured): a
  same-vendor self-pass there is still only caught by you, so keep checking the
  journal each cadence for reviewer-hat entries by the authoring vendor and
  reroute.**
- Cost discipline (docs/15): if Grok saturates, overflow to Codex. Claude's
  pool buys judgment first and skilled feature work when the capability bar
  genuinely requires it — what it never buys is VOLUME work a flat-rate pool
  could grind, and never quietly out of convenience.
- One repo, one loop: check `gibson/loop-state.md` for a live claim before
  starting a second driver against the same target.
