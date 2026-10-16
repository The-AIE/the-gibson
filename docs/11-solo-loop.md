---
title: "11 · One agent, running all night"
parent: The Doctrine
nav_order: 11
---

# 11 — The Solo Loop: One Agent, Continuously


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

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
   require `updated >= iteration_start` before any success path. The one
   exception is a runner that exits 0 and leaves `loop-state.md` byte-for-byte
   unchanged: the pre-run state already passed schema validation, so this is
   the distinct no-progress condition below, not schema corruption. Any changed
   state with an old stamp remains `state-corrupt`; do not weaken that freshness
   gate.
6. **Post-run corrupt/stale:** distinct `state-corrupt` journal section
   (validator diagnostics + diff), exact-byte restore, exactly one failure,
   suppress handoff. Precedence over runner-failure **and** no-progress even
   when the runner also exited nonzero — do not double-count or label it
   runner-failure / no-progress. The no-progress sensor is **not** run.
7. **Valid state + runner nonzero:** runner-failure only, count exactly one;
   do not classify no-progress.
8. **Valid state + runner exit 0 (issue #63 / L-008):** compare the exact
   pre-run snapshot (`gibson/.loop-state.prev`) to live state with
   `silent_noop_progressed` from `scripts/silent-noop.sh`. Only the
   column-zero `updated:` clock is ignored — clock-only rewrites are
   **no-progress**, as is a byte-identical state even when its `updated:` stamp
   is old. Substantive change (including same-length edits and
   `handoff_sha` / any other non-updated field) resets **both** the shared
   failure counter and the stale counter; handoff may proceed. No substantive
   change journals exactly one `no-progress` section, increments shared
   failure once and stale once, and does **not** reset, restore, or hand off.
9. **Budgets / escalation:** `--stale-budget N` (positive safe decimal integer;
   omitted resolves exactly to `--error-budget`) stops on consecutive
   no-progress. Escalation (`--escalate-after`) uses the same shared failure
   counter and fires **before** stop. Stop at the earlier of error-budget or
   stale-budget exhaustion; when no-progress caused the stop, the diagnosis is
   always the distinct no-progress form (never a bare "harness bug" crash line).
10. **`--dry-run` / `--print-prompt`:** inert for snapshot, recovery,
    state-corrupt, and no-progress journal mutations; no runner, no handoff.

The #75 freshness gate and the #63 no-progress sensor are complementary:
freshness requires a real `updated >= iteration_start` stamp (reuses
`validate-loop-state.sh`); no-progress asks whether anything **other than**
that clock moved, reusing the exact pre-run snapshot so recovery cannot
compare against a stale baseline.

## Safety rails (unattended ≠ unbounded)

- **Bounded retries:** 3 fix→review rounds per PR, then park with a handoff note.
  Parked ≠ failed; it's queued for a different mind (or Mark).
- **Error budget:** N consecutive gate failures (default 5) → stop, report, wait.
  A loop that can't go green is burning tokens on a harness bug. Shared with
  no-progress (below): each no-progress iteration counts one failure unit.
- **Stale budget (issue #63 / L-008):** N consecutive no-progress iterations
  (default: same as `--error-budget`; override with `--stale-budget N`) → stop
  with a distinct no-progress diagnosis. A runner that exits 0 and only rewrites
  the `updated:` clock is no-progress — exit-code budgets alone cannot see it.
  Sensor: `scripts/silent-noop.sh` (`silent_noop_progressed`), wired into
  `scripts/loop.sh`.
- **Session budget (issue #409 / L-003):** a loop that never fails still stops.
  Defaults are **50 iterations**, **480 minutes** of wall clock, and **USD 20**
  of measured ledger cost (`--max-iterations`, `--max-wall-min`,
  `--max-cost-usd`, or `GIBSON_MAX_ITERATIONS` / `GIBSON_MAX_WALL_MIN` /
  `GIBSON_MAX_COST_USD`). A flag wins over the env var. `0` on one dimension,
  or `--unbounded` for all three, is an explicit opt-out and is journaled.
  If that line cannot be written, the launch is refused and that launch
  removes the allowance it created. Removal happens after the engine lock
  is released. A second launch can resume the file in that gap; see the
  stated limits below.
  Invalid values use the same positive-safe-integer rule as `--stale-budget`
  (no leading zeros, no fractions); `0` is the only extra accepted value.
  Checks run only at iteration boundaries. The session budget never kills a
  runner. Per-iteration kills stay with `--runner-timeout`. Wall time can
  therefore overshoot the cap by the remainder of the last iteration.
  When several caps are exhausted at the same boundary, the diagnosis is
  `budget: iterations`, then `budget: wall`, then `budget: cost`. Halt,
  state-corrupt, error-budget, and stale-budget still exit through their own
  paths first.
  Cost is an exact sum of JSON-string `cost_usd` values on `gibson.cost.v1`
  ledger lines whose `session_id` is this allowance. Tokens, ACUs, and
  `flat_rate` are never converted into dollars. No matching `cost_usd` means
  the receipt says `cost: not measured` (not $0), and that session does not
  stop on the cost cap. Iterations and wall clock still bound it.
  `scripts/cost-ledger.sh` writes no `cost_usd`, no `session_id`, and no
  session-complete marker, so any matching `cost_usd` stays
  `cost: partial <amount>` and the receipt says "not every iteration measured".
  One `cost_usd` line does not establish complete session spend, and neither
  does a line on every completed iteration. `cost_status: complete` is not
  emitted. A partial sum that reaches the cap does stop.
  The allowance is `gibson/session-budget.json` (session id, lane, repo, start
  time, limits, consumed starts, completed iterations, and the loop pid while
  a start is reserved). Ordinary relaunch
  resumes it. Only `--reset-session-budget` creates a fresh one, and that is
  journaled under the allowance lock before the allowance or the latch is
  deleted. A crash after that line and before either delete leaves the old
  allowance; the journal line is not proof the files are gone. If that line
  cannot be written, or the latch is a symlink or not a regular file, the
  allowance is left unchanged and the launch is refused.
  Reset is refused while the recorded loop pid is still alive. An interrupted
  start with no pid, or a pid that is not alive, is discarded by that flag.
  Ordinary relaunch still keeps that start consumed. A dangling latch is not
  treated as a missing latch, and it does not start a runner. An unreadable-ledger
  latch records the lane and the repo. A different lane does not clear it.
  An interrupted start stays consumed. A different lane id or repo
  slug refuses the launch rather than charging this allowance to someone else.
  A stop writes one `gibson.session-budget.v1` receipt and the latch
  (`gibson/session-budget-latch`) as one transaction under the allowance lock.
  The latch is renamed into place first. Its receipt id comes from the session
  id, the allowance id (the persisted session id), and the reason. The receipt
  is appended to the journal only when a final `receipt_end:` line for that
  id is absent. A fragment that contains the receipt id is not that line. A
  later launch that finds the latch without the end line publishes the stored
  snapshot once and still stops. A latched stop for a different lane or repo
  is refused and does not publish.
  `iterations_completed` is the count at the stop. `in_flight: 1` means a
  consumed start had not completed, so the count is not a final total. A
  launchd KeepAlive relaunch that observes the latch does not start another
  runner or append another receipt. Two launches that both enter during the
  lock race in the stated limits below can still publish two receipts. The
  latch does not unload the job. `loop-fleet.sh --status` prints
  one rollup line per lane. A missing journal is `receipt=none`. A symlink or
  other non-regular journal is `receipt=unreadable`.
  PRs merged are counted only when a ledger line for this session carries
  boolean `merged` and an integer `pr`. The #74 append path does not write
  those fields, so a normal receipt says `prs_merged: not measured`.
  `--dry-run` and `--print-prompt` do not create or reset an allowance.
  The allowance file is writable by the same user and by the runner. It is
  not a security boundary. The smallest wall cap is one minute.
  A recycled pid can look alive until that other process exits, so reset
  can refuse for a pid that is no longer this loop.
  Stated limits from the 2026-10-16 pre-push read (The-AIE/the-gibson#499;
  not closed here; an honest gap, not a stronger guard):
  The allowance lock is a directory plus a pid file. Two launches that
  overlap after `session-budget.lock` exists and before its pid file is
  durable can both enter. Allowance updates can overwrite each other, and
  two stop receipts can be published.
  An opt-out (`--unbounded` or a zero dimension) whose journal line cannot
  be written removes the allowance after the engine releases the lock. A
  second launch that resumed that allowance in the gap loses the file.
  The next boundary then has no allowance, and a later reserve can create
  a fresh session, so earlier consumed starts are not on the new allowance.
  `--reset-session-budget` appends the reset line, then deletes. If the
  process is killed or the machine loses power before either delete, the
  next ordinary launch resumes the old allowance even though the journal
  says the reset completed.
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

## Owner digest (issue #72)

`scripts/digest.sh` renders a morning digest from the offline decision ledger
(`scripts/decision-ledger.sh`) plus loop/PR signals. Delivery is via `DIGEST_CMD`
(Hermes when present) — same env-hook pattern as `HERMES_CMD`. The loop remains
correct without delivery; gated work is visible once the channel is wired.

## Single-platform mode (`--solo-platform`, issue #69)

Cross-vendor review is preferred (docs/20). When **exactly one** AI vendor CLI is
installed and no second vendor is available, run:

```bash
./scripts/loop.sh --runner grok --repo ~/Code/acme --repo-slug owner/acme \
  --solo-platform --escalate-after 2
```

### Contract

| Concern | Multi-vendor (default) | Single-platform (`--solo-platform`) |
|---|---|---|
| Pre-handoff review | Distinct vendor CLI required | Same vendor, **different model** / fresh-context plan pass (`vendor:model`) |
| Law 5 | Different vendor | Fresh context + alt model counts as present reviewer |
| Escalation | `--reviewers codex,claude` | Same-vendor alt-model second opinion (no deadlock) |
| Tier B | One independent APPROVE | Prefer **two** independent fresh-context APPROVE verdicts when available |
| Tier C | Human gate (docs/14 G12) | **Unchanged** — still human-gated |
| Missing review path | Fail closed (block handoff) | Fail closed only if the configured solo review path itself breaks |

Default `--reviewers` under `--solo-platform` becomes `<runner>:review` (e.g.
`grok:review`, `claude:sonnet`) when the operator does not pass `--reviewers`.

This is a **documented degraded mode**, not a silent skip. Pair with a dedicated
reviewer GitHub identity (#67) so branch protection remains satisfiable under
L-015/L-021.

