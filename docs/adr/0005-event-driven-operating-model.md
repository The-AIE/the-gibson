---
title: "ADR-0005: The event-driven operating model"
nav_exclude: true
---

> **Authority:** Non-normative. Design record and rationale only; it adds no gate and changes no gate. Binding rules live in [`AGENTS.md`](../../AGENTS.md). Nothing in this record is applied until the owner decides it.

# ADR-0005 · 2026-10-26 · Every consumer wakes on an event; timers are only the fallback and the absence detector

**Status:** Proposed. Nothing here is built.
**Owner decision required:** this record asks to amend D-018 (the 60 second ready probe) so it becomes a fallback rather than the primary path, and asks who configures the GitHub App webhook.
**Decision record:** `memory/DECISIONS.md` would point here once decided.
**Related:** principle 9 in `docs/01-principles.md`; `docs/33-event-driven-operating-model.md` (the full model); `docs/31-agent-kontrol.md`; D-018; #562; neuro-hermes-chief-of-staff#45; issue #600.

## Context

The owner's direction on 2026-10-25 was that the whole architecture be event-driven. A triage
on 2026-10-26 of why the Hermes coordinator stopped producing work found that the host and
scheduler were healthy, and that six recurring causes (silent pause, alive mistaken for
delivering, a poll-interval floor, a single-threaded consumer, a policy gap that looks like a
stall, stale unowned state) explain every outage since 2026-09-18. Doc 33 has the dated table.

D-018 chose a 60 second probe on the Mini and rejected three alternatives: an Actions
`repository_dispatch` into a Mini receiver, a 60 second full scan, and a CI-set status that
still needs a poller. Its stated reason against the first was the need for an always-on
inbound service or a CI-held credential able to execute on the Mini.

## Decision (proposed)

1. Adopt the six rules in doc 33 as the operating model.
2. One GitHub App webhook into Agent Kontrol is the front door, with a signed, deduplicated
   inbox and a table of deterministic reducers. CI-side events (#562) cover repos without the
   App webhook.
3. Consumers on the Mini hold an **outbound** long-poll to Agent Kontrol with a scoped
   credential. Agent Kontrol never executes on the Mini.
4. A sweeper in Agent Kontrol emits absences as events: `pr-stuck`, `consumer-silent`,
   `pause-unexplained`, `pause-expired`, `decision-aging`.
5. Pause and resume are recorded decisions: reason, citing decision, `until`, default 72
   hours maximum.
6. Each consumer's health is three signals (alive, working, delivering). Idle is acceptable
   only when the queue it serves is empty.
7. D-018's probe remains as the reviewer's fallback sweep. The probe is amended, not
   removed.

## Alternatives considered

- **Per-repository webhooks.** Rejected: manual per repo, zero configured today, does not
  cover new repos.
- **Push into the Mini (inbound receiver, Tailscale funnel, or a CI credential that runs
  there).** Rejected for the reasons D-018 gave; the outbound long-poll gives the same
  latency without them.
- **Shorten every poll.** Rejected: the 616 second review that held three Gibson PRs for 25
  minutes on 2026-10-25 is a single-threaded consumer, which a shorter tick does not fix, and
  a shorter tick costs API calls and model runs at every interval.
- **Keep the model-driven coordinator polling.** Rejected as the primary path: on
  2026-10-26 it ran 32 times, each with a prompt of about 190,000 characters, and reported no
  accepted delivery. It remains the exception handler.

## Consequences

- Latency from green to review start drops from a tick plus queue to seconds.
- A dead consumer becomes a growing, visible backlog, so consumer lag and the dead-man
  switch are part of the decision, not extras.
- The webhook is at least once and can drop; every consumer keeps a slower sweep and counts
  what it catches.
- Adds an inbox table, a receiver route, a long-poll route and a sweeper to Agent Kontrol
  (epic `mrhinkle/agent-kontrol#62`). Adds no gate to the Gibson.

## Revisit when

The fallback sweep finds more than 2 percent of the work an event should have caught for a
week, or inbox lag exceeds one minute at p90.
