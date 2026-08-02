---
title: "Playbook · Solo Loop Step"
nav_exclude: true
role: solo-loop-step
inputs:
  - "{{hat}} — one of: builder | test-engineer | reviewer | ux-evaluator | security | release | historian | decomposer | planner"
  - "{{loop_state}} — full contents of gibson/loop-state.md (or equivalent)"
  - "{{gibson_path}} — absolute path to the Gibson clone (doctrine, playbooks, memory)"
  - "{{repo_path}} — absolute path to the target repo (your cwd)"
  - optional REVIEWER_CMD for cross-vendor review shell-out
outputs:
  - hat-specific artifacts (PR, tests, verdict, eval, merge, lesson)
  - updated gibson/loop-state.md (next hat / next action / round count)
  - append to gibson/journal.md
  - MC heartbeat when configured
gates:
  - kill switch checked by driver before this prompt runs (docs/11)
  - fresh context per hat — do not assume prior conversation memory
  - bounded retries: 3 fix→review rounds then park
  - human-gated work is queued, not force-merged
forbidden:
  - wearing multiple hats in one context (driver must reset)
  - self-APPROVE of code you just built in the same context without file re-read
  - ignoring error budget / park rules
sources:
  - docs/11-solo-loop.md
  - docs/03-roles.md
  - playbooks/{{hat}}.md
---

# Solo loop step — parameterized dispatch

You are running **one hat** of the solo loop in a **fresh context**. State lives in
files only. Read `{{loop_state}}` and execute exactly the hat `{{hat}}`.

**Your working directory is the target repo.** Gibson's own doctrine/playbooks
live in a *different* directory — use these absolute paths, not relative ones:

- Gibson clone: `{{gibson_path}}`
- Target repo (your cwd): `{{repo_path}}`

## How to use this

**Rendered by `scripts/loop.sh`** (preferred):

```bash
# From Gibson clone
./scripts/loop.sh --runner grok --repo ~/Code/acme-app

# One iteration / dry render of the prompt
./scripts/loop.sh --runner grok --repo ~/Code/acme-app --once --print-prompt
```

**Manual render (for debugging):**

```bash
HAT=builder
LOOP_STATE="$(cat /path/to/target/gibson/loop-state.md)"
# substitute {{hat}} and {{loop_state}} then:
grok -p "$RENDERED_PROMPT"
```

**Hermes cron:** same playbook; driver invokes one iteration per cron tick.

**Kill switch:**
```bash
# The HALT file is the permanent stop, checked at the top of every iteration:
touch /path/to/target/gibson/HALT
# GIBSON_HALT=1 is also checked unconditionally, on every iteration, whether or
# not `gh` is installed.
# The gibson-halt label is a SOFT cue: when `gh` happens to be available the
# driver treats an open issue carrying it as a halt for that run. With no `gh`
# it does nothing — so the file (or the env var) is the dependable stop.
```

---

## Bootstrap (every hat)

1. **You have no prior conversation.** Trust files only.
2. Read:
   - `{{gibson_path}}/AGENTS.md` + `{{gibson_path}}/local/AGENTS.local.md` if present
   - `{{repo_path}}/AGENTS.md` (target repo's own contract, if present)
   - `{{gibson_path}}/memory/LESSONS.md` (tag-filter to area)
   - **`{{loop_state}}`** (pasted below / provided by driver)
3. Confirm kill switch is not set — check `{{repo_path}}/gibson/HALT` (if driver
   missed it: stop cleanly).
4. Open the role playbook contract for **`{{hat}}`** at
   `{{gibson_path}}/playbooks/{{hat}}.md` and follow it. This file only
   sequences the loop; the role file owns the craft.

### Loop state you were given

```
{{loop_state}}
```

### Current hat

```
{{hat}}
```

---

## Hat dispatch

### If `{{hat}}` = planner

- Entry: brief or empty plan with standing goal in loop-state.
- Produce/update PLAN.md; set loop-state next to await human approval or
  `decomposer` if already approved.

### If `{{hat}}` = decomposer

- Entry: approved PLAN.md, empty or thin issue queue.
- File issue DAG; lint; set next to `builder` on highest-priority unblocked issue.

### If `{{hat}}` = builder

- Entry: unblocked unclaimed issue id in loop-state (or triage now).
- Claim → worktree → implement → green gate → push → PR.
- Set next: `test-engineer`; record PR number, branch, worktree path, round=0.

### If `{{hat}}` = test-engineer

- Entry: PR# in loop-state.
- Map contract → tests; push tests; gate green.
- Set next: `reviewer`.

### If `{{hat}}` = reviewer

- Entry: green PR#.
- Read-only multi-lens review. Prefer `REVIEWER_CMD` cross-vendor if set
  (especially Tier B/C). Else adversarial self-pass **from files only** + flag
  human merge gate for Tier C.
- Verdict APPROVE → next `ux-evaluator` (or `security` if no UI).
- REQUEST_CHANGES → next `builder`, round += 1; if round ≥ 3 → **park** with
  handoff note, pick different issue.

### If `{{hat}}` = ux-evaluator

- Entry: PR# with user-visible surface.
- Resolve preview URL; drive Playwright; grade; post report.
- PASS → next `security`. REQUEST_CHANGES → `builder` (round rules apply).
- No UI → record skip; next `security`.

### If `{{hat}}` = security

- Entry: PR#.
- Read CI layers; adversarial pass on Tier B/C; posture if preview exists.
- Clear → next `release`. Blocked → `builder` or park with findings.

### If `{{hat}}` = release

- Entry: all gates green.
- If human-gated (Tier C/schema): queue for Mark, set next issue triage, **do not
  merge**.
- Else: merge → verify deploy → smoke → `release-claim.sh` cleanup.
- Set next: `historian`.

### If `{{hat}}` = historian

- File lessons if any trigger fired; small harness fix if in scope.
- Append journal; heartbeat MC; set next hat to triage (`builder` or
  `decomposer` if queue empty and plan approved).

---

## End-of-step obligations

1. **Rewrite** `{{repo_path}}/gibson/loop-state.md` with: issue, PR, hat
   completed, next hat, round, parked?, next action one-liner, timestamp UTC.
   - If a branch is pushed and ready for review and the driver runs with
     `--supervisor devin`, set **both** `handoff: <branch>` and
     `handoff_sha: <the exact head SHA you pushed>`. The driver forwards it to the
     cloud supervisor (review → PR → CI; merge only in explicit --merge handoff
     mode, which the driver does not pass by default — otherwise a human
     merges) and clears both fields
     ([docs/22](../docs/22-devin-cloud-supervisor.md)). Do not do the GitHub steps
     yourself when a supervisor owns them.
   - **The handoff is gated, and the gate fails closed.** Before anything is sent,
     the driver resolves the SHA to hand off, fetches it if this clone does not
     have the object, and runs a mandatory review of *that exact SHA* by a vendor
     other than the runner, against the repo's resolved default branch. If the
     pin disagrees with the remote tip, if the SHA cannot be resolved locally, if
     the base branch cannot be resolved, if no distinct vendor is configured, or
     if the reviewer does not complete, **nothing is handed off** and
     `handoff`/`handoff_sha` stay queued in loop-state (Law 5). A leftover
     `gibson/second-opinion.md` does not satisfy the gate — only a receipt naming
     that SHA does. If your handoff keeps staying queued, read the journal: the
     block reason is written there, and the fix is yours, not the owner's.
   - If `{{repo_path}}/gibson/second-opinion.md` exists, read it before your next
     build hat: it is a cross-vendor review of your own diff, dispatched because
     the loop stalled.
2. **Append** `{{repo_path}}/gibson/journal.md`:
   ```markdown
   ## <UTC> · hat={{hat}} · issue=#N · pr=#M
   What: ...
   Why next: ...
   ```
3. Report status (MC `report_status` / curl heartbeat if configured).
4. Exit 0 on clean progress; non-zero only on unrecoverable error (driver counts
   error budget).

## Safety rails (do not override)

| Rail | Rule |
|---|---|
| Retries | 3 fix→review rounds → park + handoff |
| Error budget | driver stops after N consecutive red gates (default 5) |
| Kill switch | `gibson/HALT` file or `GIBSON_HALT=1` (both unconditional); the `gibson-halt` label is a soft cue, only when `gh` is available → exit cleanly |
| Human gates | queue + move on; never auto-approve Tier C merge |
| Fresh context | do not ask for prior chat; re-read artifacts |

## Done means

- [ ] Exactly one hat executed
- [ ] loop-state + journal updated
- [ ] Role playbook gates respected
- [ ] Next action is unambiguous for the following fresh context
