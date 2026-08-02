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
./scripts/loop.sh --runner grok --repo <target> \
    --escalate-after 2 --reviewers codex,claude \
    --supervisor devin
```

- `--runner`: implementer from the routing table (Grok default — flat-rate).
- `--escalate-after 2 --reviewers codex,claude`: two consecutive failures buys
  a cross-vendor second opinion BEFORE the error budget kills the lane —
  judgment tokens spent exactly when cheap volume has failed twice.
- `--supervisor devin`: finished branches hand off to the cloud supervisor
  (docs/22) via `handoff:` in loop-state — Devin reviews the exact head,
  owns the PR, and merges (Tier C still parks at the human gate).
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

- Kill switch respected instantly: `gibson/HALT` file or `gibson-halt` label.
- Law 5 always: reroute so no lane ever reviews its own work, even when a
  vendor is down.
- Cost discipline (docs/15): if Grok saturates, overflow to Codex; Claude only
  for judgment; NEVER quietly fall back to burning metered/judgment tokens on
  volume work because it's convenient.
- One repo, one loop: check `gibson/loop-state.md` for a live claim before
  starting a second driver against the same target.
