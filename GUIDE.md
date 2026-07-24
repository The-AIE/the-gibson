# The Gibson — Operator's Guide

This is Mark's manual. The fleet reads `AGENTS.md`; you read this. It covers the
five things you actually do: start work, approve gates, read the digest, run the
solo loop, and tune the harness. Everything here is *why-linked* — each step points
at the doc that explains its reasoning, because a harness you can't interrogate is
a harness you'll stop trusting.

## 1. Start a body of work

```
You:  a brief — "Build X for <repo>" (a paragraph is enough)
Fleet: planner returns PLAN.md — scope, risks, deliverables with testable
       acceptance criteria, design language if there's UI
You:  approve the plan  ← your highest-leverage moment (docs/02, stage 0)
Fleet: decomposer files the issue DAG; builders start claiming
```

You approve the *plan*, not each implementation choice. If you find yourself
wanting to steer implementation, the plan was too vague — fix the plan (doc 04).

**One-off tasks** skip the ceremony: file an issue with acceptance criteria (or ask
any agent to run `playbooks/decompose.md` on your sentence), and the pipeline picks
it up at stage 2.

## 2. Your approval queue (human gates)

Agents stop only for the 16 gates in [docs/14-human-gates.md](docs/14-human-gates.md)
— destructive ops, money, outward-facing sends/launches, scope breaks, Tier C
merges, credentials. Everything else proceeds without you.

You'll get gate requests batched in the digest (below) and as PR comments tagged
`@mrhinkle` with **exactly one decision** stated. Answer on the PR or via Hermes;
the fleet circles back. A parked gate never blocks unrelated work.

Tempted to add a gate? That's Tier C on the harness itself — the list is closed on
purpose, because every soft "maybe ask first" you add costs autonomy everywhere
(docs/01, principle 8).

## 3. The digest

Hermes sends the daily/weekly digest: shipped PRs, gates awaiting you, parked
work, security findings, cost-per-merged-PR per pool, and **what the harness
learned about itself** (lessons filed + harness PRs — the ratchet, doc 09).

The one number to watch: **cost per merged PR, per pool** (doc 15). Rising cost at
flat quality means decomposition or routing has drifted — say so, the historian
investigates.

## 4. Run the solo loop (Grok overnight, Hermes cron)

```bash
scripts/loop.sh --runner grok --repo ~/Code/<target>     # hot loop, flat-rate pool
scripts/loop.sh --runner hermes --repo ~/Code/<target>   # cron-shaped iterations
```

- **Watch it:** `gibson/journal.md` in the target repo (one entry per iteration),
  plus the MC dashboard heartbeat.
- **Stop it:** add the `gibson-halt` label to the target repo, or drop the kill
  flag — checked at the top of every iteration (doc 11).
- **It stopped itself?** Either the queue is empty, all remaining work is
  human-gated (check the digest), or the error budget tripped (5 consecutive red
  gates = a harness bug, not a retry candidate — doc 11).

## 5. Adopt a new repo

Say "adopt `<repo>`" — an agent runs `playbooks/adopt.md` (doc 13): harnessability
audit → contract install → CI gates → baseline burn-down → canary issue per
runtime. You approve the adoption PR and any burn-down spending. Done means: a
Tier A issue flows end-to-end with zero touches from you.

## 6. Tune the harness

- **Correct behavior:** don't re-instruct agents ad hoc — file a lesson or edit
  the doctrine (PR to this repo). Instructions that live in chat die in chat;
  instructions that live in the harness compound (doc 09).
- **Loosen/tighten:** tier definitions, hard-fail thresholds, and the human-gate
  list are yours to change — via PR, so the change is visible fleet-wide and
  reviewable like everything else.
- **Interrogate:** every rule cites its incident or source. If a rule cites
  nothing, it's a candidate for deletion — say so.

## Quick reference

| I want to… | Do |
|---|---|
| Start a feature | Brief → approve PLAN.md |
| Quick fix | Issue with acceptance criteria |
| See status | MC dashboard / digest / `gh issue list -l gibson` |
| Approve a Tier C merge | Reply on the PR (G12) |
| Stop everything on a repo | `gibson-halt` label |
| Overnight grind | `scripts/loop.sh --runner grok` |
| Teach the fleet | PR a lesson to `memory/LESSONS.md` |
| Add a repo | "adopt `<repo>`" |
