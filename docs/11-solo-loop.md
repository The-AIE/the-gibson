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
  **Schema (issue #75):** ten required column-zero keys, exactly once each —
  `updated`, `issue`, `pr`, `hat`, `next_hat`, `round`, `parked`, `handoff`,
  `handoff_sha`, `next_action`. Extra keys (e.g. `notes`) are allowed.
  Early issue prose sometimes listed nine keys and omitted `handoff_sha`; the
  operational contract is ten. Missing `handoff_sha` fails closed (add the key;
  empty value is fine) — never a silent default. `hat` / `next_hat` are the
  nine-hat enum; `round` is a non-negative base-10 integer; `parked` is exactly
  `true` / `false`; `updated` is a real strict UTC `YYYY-MM-DDTHH:MM:SSZ`
  instant. Shared checker: `scripts/validate-loop-state.sh` (quiet on success;
  requires **python3** on PATH for calendar-real timestamps — absence fails
  closed; state values are never shell-eval'd). Indentation and comments never
  satisfy a required key.
  **Field grammar (one contract for validator + driver):** after the first
  colon, exactly one optional ASCII space may be stripped — `key:value` and
  `key: value` are identical; empty values are allowed (`key:` / `key: `);
  no further trim of meaningful value data; tabs after `:` are value bytes, not
  the optional separator. Canonical writers emit `key: value`. The driver
  `read_field` uses this same parse (never a stricter `key: value`-only form).
  **Path safety:** validation and recovery refuse a symlink leaf without
  following it (even when the target would otherwise be valid schema); live
  directory/device shapes are quarantined or fail closed — never write through
  them.
- **`gibson/.loop-state.prev`**: last validated pre-iteration snapshot. The driver
  copies loop-state here atomically (temp + rename) immediately before a real
  runner invocation. Destination must be a regular non-symlink file (or
  missing) — a pre-existing directory/symlink/device fails closed before the
  runner and must not accumulate nested temp files. Recovery restores **exact
  bytes** from this file; corrupt content must never overwrite it. A successful
  later iteration may replace it with the next validated pre-state.
- **`gibson/journal.md`**: append-only run log — one entry per loop iteration.
  Feeds the historian and Mark's digest. `state-corrupt` sections are distinct
  from runner-failure and halt entries.

### Validation / snapshot / recovery order (issue #75)

Every real iteration (not `--dry-run` / `--print-prompt`) follows this order:

1. **Halt first** (issue #71): every kill-switch path runs before default-state
   creation, validation, or snapshotting. A halted cold or existing repo leaves
   both `loop-state.md` and `.loop-state.prev` byte-identical or absent, starts
   no work, and queues no handoff.
2. **Validate before reading `next_hat`:** never silently default a missing or
   malformed `next_hat` to `builder`. If current state is corrupt → classify
   exactly once as `state-corrupt`, journal diagnostics + unified diff, restore
   exact bytes from the last valid snapshot **if that snapshot still validates**,
   count one failure-budget unit, and do not run or hand off. Missing/unusable
   snapshot → fail closed, journal, count once, never invent default content.
   Unsafe live path shapes (directory/symlink/device) are quarantined by rename
   in the same parent (contents preserved, never deleted) before exact restore,
   or fail closed with an explicit recovery-incomplete diagnostic — never claim
   exact restore when it did not occur.
3. **Pre-queued handoff retry** (issue #71): when `--supervisor devin` is set
   and `handoff` is already non-empty after a successful schema validate, retry
   `supervisor_handoff` **without** invoking a runner, snapshot, or post-run
   freshness path. Do not treat a zero-work command as successful progress
   (no failure-budget reset). This preserves blocked-handoff retry without
   faking state progress under the #75 freshness gate.
4. **Snapshot** the validated pre-iteration state to `.loop-state.prev` (atomic)
   immediately before the real runner. Snapshot failure starts no runner and
   counts as a single `state-corrupt` / recovery-control failure. Success is
   reported only when the exact destination path is a regular non-symlink file
   byte-identical to the source.
5. **Capture** a strict UTC `iteration_start` immediately before invoking the
   runner. After **every** actual runner exit, re-validate schema **and**
   require `updated >= iteration_start` before resetting failures or calling
   `supervisor_handoff` — including when bytes are identical to the
   pre-iteration snapshot. A zero-exit no-op that leaves a valid but old stamp
   is `state-corrupt` (one budget unit, no reset, no handoff). Pure
   no-progress classification beyond this freshness gate is issue #63; do not
   weaken #75 freshness in anticipation of it.
6. **Post-run corrupt/stale:** distinct `state-corrupt` journal section
   (validator diagnostics + diff), exact-byte restore, exactly one failure,
   suppress handoff. Precedence over runner-failure even when the runner also
   exited nonzero — do not double-count or label it runner-failure / no-progress.
7. **Valid state + runner nonzero:** existing runner-failure behavior, count
   exactly one. **Valid state + runner exit 0:** reset the consecutive failure
   budget and may hand off. Escalation / budget thresholds fire once at the
   existing values.
8. **`--dry-run` / `--print-prompt`:** inert for snapshot, recovery, and
   state-corrupt journal mutations; no runner, no handoff.

The future no-progress sensor (issue #63) will **reuse this timestamp parser**
(`validate-loop-state.sh` / its strict UTC python3 implementation) rather than
inventing another one. This issue does not implement #63's no-progress sensor.

## Safety rails (unattended ≠ unbounded)

- **Bounded retries:** 3 fix→review rounds per PR, then park with a handoff note.
  Parked ≠ failed; it's queued for a different mind (or Mark).
- **Error budget:** N consecutive gate failures (default 5) → stop, report, wait.
  A loop that can't go green is burning tokens on a harness bug.
- **Kill switch:** checked at the top of every iteration (and before any
  supervisor handoff). Three layers, all read-only:
  1. **Local (always):** the `gibson/HALT` file, or `GIBSON_HALT=1` in the
     environment. Neither needs `gh` or a network call. The file is the
     permanent on-box stop.
  2. **Remote label:** when `gh` is installed and authenticated **and** the
     target origin host matches `GH_HOST` (default `github.com`; set for GitHub
     Enterprise), any open issue on the target repo carrying the `gibson-halt`
     label stops the loop. Remove the label and a freshly launched loop runs
     again — the check is on a bounded cadence (below), not process-start-only.
     Phone workflow: [doc 16](16-nontechnical-operation.md).
  3. **Remote sentinel:** a `.gibson-halt` file committed on the target repo's
     **current remote default branch** (usually `main`) also stops the loop.
     Delete the file from the default branch to clear it. Useful when labels are
     awkward or when the operator can only push a file from another device.
  **Cadence / cache:** remote paths are re-checked every iteration with
  `--once`, and every `GIBSON_REMOTE_HALT_INTERVAL` iterations in a hot loop
  (default **3**). A phone label is honored within **up to K iterations**
  (default three), not necessarily the very next hat. The loop process caches
  live results across its own iteration-top and pre-handoff gates so it does not
  double-poll inside one cadence window; the child `devin-supervisor.sh` still
  **deliberately rechecks live** (may spend another pair of `gh` calls) and
  exits **75** on kill-switch refusal so a mid-cadence stop is journaled as a
  halt, never as "supervisor rejected". There is **no** shared-cache elimination
  across processes.
  On remote halt the driver **journals the reason once**, leaves `loop-state`
  untouched (no default state created or rewritten), and suppresses supervisor
  handoffs. A persistent runtime latch under the target repo's
  `gibson/halt-latch` (not a tracked Gibson source file) records the source and
  reason so **launchd KeepAlive relaunches** do not append duplicate journal
  sections while the stop is still active. The read → decide → journal → latch
  transition is serialized with a cross-process lock (`gibson/halt-lock`: complete
  pid+owner token written to a temp file, then atomically published with
  `ln temp lock`; token-checked release; dead/malformed stale recovery; trap
  cleanup) so concurrent launches wait and observe the first latch (or fail
  closed) rather than racing duplicate journal sections or starting work;
  ordinary single-process launchd stays uncontended and fast. Removing `gibson/HALT` / unsetting `GIBSON_HALT` clears the local
  side of the latch; a successful remote recheck that positively clears **both**
  remote paths **on the same host+slug that was latched** clears the remote side
  and permits a fresh launch.
  Remote latches store the exact configured GitHub host and validated
  `owner/repo` slug that confirmed the stop. Changing origin to a different
  (even clear) repository, or losing a parseable matching origin, **stays
  fail-closed** and does **not** query or clear against the new repo — restore
  the original source and clear it successfully, or after operator verification
  explicitly remove `gibson/halt-latch`.
  GitHub/API failure on either remote path:
  - **First-ever** (no remote latch yet) **fails open** to the local file/env
    checks — the loop keeps running — with an explicit
    `remote halt check degraded` warning.
  - **After a confirmed remote halt** has been latched, a later degraded /
    unauthorized / rate-limited recheck **stays fail-closed** until a successful
    same-source check positively clears both remote paths. KeepAlive must not
    resume work just because GitHub flaked.
  A non-matching origin host (GitLab, Bitbucket, unconfigured Enterprise, SSH
  host aliases), an unparseable origin, or exact path segments `.` / `..` in the
  origin URL **never** query `gh` against an unrelated same-named github.com
  repo (explicit `disabled` warning; zero remote-halt `gh` calls). Valid
  leading-dot repository names such as `owner/.github` are accepted. The same
  paths suppress Devin supervisor handoffs
  ([doc 22](22-devin-cloud-supervisor.md)). Origin forms: `https://`,
  `git@host:`, or `ssh://git@host/...` on the configured `GH_HOST`.
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
