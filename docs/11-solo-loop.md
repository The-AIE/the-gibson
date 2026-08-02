---
title: "11 · One agent, running all night"
parent: The Doctrine
nav_order: 11
---

# 11 — The Solo Loop: One Agent, Continuously

> 🙂 **In plain English:** You can also run one agent alone overnight. It puts on each
> hat in turn — build, test, review, ship — and keeps going until the list is done or it
> hits a decision only a human can make.

Fleet mode assumes a dispatcher and multiple runtimes. The solo loop is the other
deployment shape: **one agent on one platform, running the whole SDLC continuously,
unattended** — e.g. Grok grinding a backlog overnight on the flat-rate plan, or
Hermes running it from a cron. Same doctrine, same gates; what changes is that the
roles execute *sequentially in one loop* instead of in parallel across a fleet.

## Design (why it works)

Two findings from Anthropic's long-running harness work carry the whole design:

1. **Context resets over compaction.** Long-running agents develop "context
   anxiety" — prematurely wrapping up near context limits. The loop therefore runs
   each role hat in a **fresh context**, with state carried in files, never in the
   conversation.
2. **File handoffs are the interface.** Roles already communicate via artifacts
   (PLAN.md, issues, PRs, reports — doc 03). A solo agent re-reading its own
   artifacts with fresh eyes gets a real degree of the "never grade your own
   homework" separation: the evaluator hat has no memory of writing the code, only
   the contract and the deployment. Where a second platform is reachable
   (`REVIEWER_CMD`), Tier B/C review still goes cross-vendor even in solo mode.

## The loop

```
┌─▶ 1. SYNC      git pull --all; read AGENTS.md, LESSONS.md (tag-filtered), loop-state.md
│   2. TRIAGE    pick highest-priority unblocked, unclaimed issue (or: decompose
│                PLAN.md if queue is empty and plan is approved)
│   3. CLAIM     label + claim row + worktree                     [builder hat]
│   4. BUILD     implement small unit; green gate; push; open PR  [builder hat]
│   ── context reset ──
│   5. TEST      contract criteria → executable checks            [test-engineer hat]
│   ── context reset ──
│   6. REVIEW    lens review of the PR; Tier C → cross-vendor if  [reviewer hat]
│                REVIEWER_CMD is set, else adversarial self-pass
│                + flag for human merge gate
│   ── context reset ──
│   7. UX-EVAL   Playwright vs. the PR's preview deployment       [ux-evaluator hat]
│   8. SECURITY  CI layers run on the PR automatically; read      [security hat]
│                results; adversarial pass on Tier B/C
│   9. RESOLVE   REQUEST_CHANGES? → back to 4 (bounded: 3 rounds, [builder hat]
│                then park the PR + write a handoff note)
│  10. MERGE     if gates green and NOT human-gated → merge,      [release hat]
│                verify deploy, smoke, cleanup. Human-gated →
│                queue it for Mark, move on.
│  11. RETRO     any lesson? file it; harness fix if small        [historian hat]
│  12. JOURNAL   append loop-state.md: what/why/next; report to MC
└── 13. REPEAT   next issue. Stop only for: human gate on ALL remaining work,
                 empty queue, kill switch, or error budget exhausted.
```

## State files (the loop's memory)

- **`gibson/loop-state.md`** (in the target repo, gitignored or branch-local):
  current issue, hat, round count, next action. The *only* thing a fresh context
  needs to resume — crash recovery is `git pull` + read this file.
- **`gibson/journal.md`**: append-only run log — one entry per loop iteration.
  Feeds the historian and Mark's digest.

## Safety rails (unattended ≠ unbounded)

- **Bounded retries:** 3 fix→review rounds per PR, then park with a handoff note.
  Parked ≠ failed; it's queued for a different mind (or Mark).
- **Error budget:** N consecutive gate failures (default 5) → stop, report, wait.
  A loop that can't go green is burning tokens on a harness bug.
- **Kill switch:** checked at the top of every iteration (and before any
  supervisor handoff, which reuses the same result). Three layers, all read-only:
  1. **Local (always):** the `gibson/HALT` file, or `GIBSON_HALT=1` in the
     environment. Neither needs `gh` or a network call. The file is the
     permanent on-box stop.
  2. **Remote label:** when `gh` is installed and authenticated, any open issue
     on the target repo carrying the `gibson-halt` label stops the loop. Remove
     the label and a freshly launched loop runs again — the check is on a
     bounded cadence (below), not process-start-only. Phone workflow:
     [doc 16](16-nontechnical-operation.md).
  3. **Remote sentinel:** a `.gibson-halt` file committed on the target repo's
     **current remote default branch** (usually `main`) also stops the loop.
     Delete the file from the default branch to clear it. Useful when labels are
     awkward or when the operator can only push a file from another device.
  **Cadence / cache:** remote paths are re-checked every iteration with
  `--once`, and every `GIBSON_REMOTE_HALT_INTERVAL` iterations in a hot loop
  (default **3**). A halt is still detected within that many iterations; the
  cached result is shared with the pre-handoff check so a handoff never spends a
  second pair of API calls. On remote halt the driver **journals the reason**,
  leaves `loop-state` untouched (no default state created or rewritten), and
  suppresses supervisor handoffs.
  GitHub/API failure on either remote path **fails open** to the local
  file/env checks — the loop keeps running rather than bricking on GitHub
  downtime — and logs a clear `remote halt check degraded` warning so the
  operator knows the remote stop is temporarily blind. The same paths suppress
  Devin supervisor handoffs ([doc 22](22-devin-cloud-supervisor.md)), not just
  the local file/env path. Origin URLs may be `https://`, `git@host:`, or
  `ssh://git@host/...`; the driver parses all three into `owner/repo`.
- **Human-gate queue:** Tier C merges and other stops accumulate in a digest
  (Hermes pings Mark) instead of blocking the loop — the loop moves to the next
  issue and circles back after approval.
- **Heartbeat:** every iteration reports to Mission Control; 15 minutes of silence
  = presumed dead, per fleet telemetry rules.

## Drivers

The loop driver is trivially portable — a shell `while` loop invoking the runtime
headless with the loop playbook and fresh context each hat:

- **Grok:** `scripts/loop.sh --runner grok --repo <path>` renders
  `playbooks/loop-step.md` with `{{hat}}` / `{{loop_state}}` each step. The
  economics make Grok the default solo runner: near-unlimited flat-rate usage
  means the loop's iteration count is free; only quality gates — and doc 15's
  escalation rules for hats that exceed Grok's grade — matter.
  How-to: [playbooks/loop-step.md](../playbooks/loop-step.md), `scripts/loop.sh --help`.
- **Hermes:** cron-triggered iterations rather than a hot loop; same playbook, and
  Hermes doubles as the digest/escalation channel it already owns.
- **Claude Code / Codex:** same driver (`--runner claude|codex`), typically used in
  short bursts on the hard hats rather than the grind (doc 15).

Escalation *within* a solo run is explicitly allowed: the loop can shell out a
single hat to a stronger runtime (e.g. Grok loop dispatches a Tier C review to
`claude -p` read-only) without leaving solo mode — the escalation ladder in doc 15
governs when.

## Methodology lineage — best-of-breed borrowings

The loop above is a synthesis, not an invention. What we took, and what we
deliberately left, from the major loop methodologies:

| Methodology | What it is | We take | We leave |
|---|---|---|---|
| **Ralph loop** (Huntley) | The same prompt in a `while true`, brute-forcing a repo until done; "the loop is the harness" | The unreasonable effectiveness of *dumb persistence* + a journal file; our driver is knowingly a disciplined Ralph | No gates, no fresh context, self-graded "done" — it happily loops on its own bugs |
| **Generator/Evaluator** (Anthropic GAN-style) | Separate planner, generator, skeptical evaluator; sprint contracts; eval vs. running app | The whole spine: hats 4/7 separation, contracts, Playwright evaluation, refine-or-pivot | Fixed sprint structure (overhead for strong models — principle 1's downward stress-test) |
| **Spec-driven dev** (GitHub Spec Kit) | specify → plan → tasks → implement; the spec is the source of truth | Stages 0–1 exactly: PLAN.md → contract-bearing issues before any code | Spec-first *everything* — hotfixes and Tier A tweaks don't need the full ceremony |
| **SPARC** (ruvnet) | Specification → Pseudocode → Architecture → Refinement → Completion per unit | Refinement-as-distinct-phase (our bounded fix rounds); completion criteria stated up front | The five-phase ceremony per unit; pseudocode as a mandatory artifact |
| **TDD red-green loop** | Write the failing test, make it green, refactor | `test.todo` contracts + criterion-coverage gate; regression-test-with-every-bugfix | Strict test-first ordering for exploratory/UI work where the contract is visual |
| **Evaluator-optimizer** (Anthropic patterns) | Tight generate→score→regenerate inner loop | Our round structure (build→eval→fix), with scores trending across rounds | Unbounded optimization — 3 rounds then park (diminishing returns burn budget) |
| **GOAP replanning** (ruflo) | Plan as state-space search; on failure, *replan from current state* rather than restart | Step 9's resolve logic and crash recovery: always resume from `loop-state.md`, never from scratch | Full precondition/effect modeling — overkill at our scale |
| **Reflexion / self-critique** | Agent critiques its own output verbally before finalizing | Only as a pre-gate hygiene step — cheap, catches typos-of-thought | As a *quality gate* — self-critique is exactly the self-grading principle 3 forbids |

The compressed claim: **Ralph's persistence + Spec Kit's front-loading + Anthropic's
adversarial separation + TDD's executable contracts + GOAP's resume-don't-restart**,
with every "am I done?" answered by a sensor instead of the model's own opinion.

---
[← 10 · Any AI, same rules](10-vendor-adapters.md) · [Home](../index.md) · [12 · Shipping to Vercel safely →](12-vercel.md)
