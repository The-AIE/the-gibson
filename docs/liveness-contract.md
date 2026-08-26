# The Liveness Contract

> **Authority:** Non-normative. On-demand detail for the binding one-line rule in
> [`AGENTS.md`](../AGENTS.md) ("Never hang; bound your work and finish"). This file
> elaborates that rule; it must not add, drop, or weaken it.

## Why

An agent that HANGS is worse than one that fails: a failure feeds the error budget
and the loop moves on; a hang wedges the loop until a human notices (observed
2026-08-26 — a Grok spec-review froze with no timeout and hung a driver run for 80
minutes; a human caught it, not the system). So every agent, and every tool it
invokes, must be able to FINISH and must make its progress legible.

This is also enforced from **outside** — runner wall-clock timeouts and the
liveness watchdog — precisely because a stalled runtime cannot rescue itself. The
clauses below are what make that external enforcement rare and exact: an agent that
honors them rarely needs killing, and one that can't (a frozen black-box runtime)
is legible enough for the watchdog to catch.

## The clauses (binding)

1. **Bound your work.** Every task and sub-step carries a budget (time or
   iterations). On reaching it, STOP and report state — never grind past it.
2. **Emit progress.** Write a progress line to your log/status on a cadence.
   Silence is indistinguishable from a stall; a watchdog treats no-progress as
   dead. Working invisibly is the same as not working (extends L-008).
3. **Fail loud, hand back — never hang, never silently no-op.** Blocked, stuck, or
   handed input you cannot process → exit non-zero with the reason. A no-op MUST be
   distinguishable from success (a pass a watchdog can forge for free is not a pass).
4. **Never wait unbounded.** Every `wait` / subprocess / network call an agent or
   script issues carries a timeout; on expiry, kill the whole process **tree**
   (orphaned children are the zombies) and report.
5. **Right-size or route.** If a task exceeds what your runner can do — a spec too
   large for the model, a context that overflows — split it or hand it to a more
   capable runner. Do not attempt-and-stall.
6. **Release on exit.** `trap EXIT` releases every claim, lock, and worktree hold on
   completion OR failure. A dead agent must never keep a lane (with L-010).
7. **Be resumable.** Checkpoint enough that a restart continues rather than redoes;
   assume you can be killed and re-run at any point.
