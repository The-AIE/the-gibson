---
title: "22 · The cloud supervisor (Devin)"
parent: The Doctrine
nav_order: 22
---

# 22 — The Cloud Supervisor: Devin as Reviewer and Merger

> 🙂 **In plain English:** A cheap, fast agent does the building on your own machine
> all day. When a piece of work is finished, it is handed to one always-available
> cloud agent that checks the work, puts it up on GitHub, waits for the tests, and
> merges it. The builder never touches GitHub; the checker never wrote the code.

This is [doc 20](20-multi-model-orchestration.md)'s coordinator pattern with the
coordinator **outside your machine**: a persistent Devin cloud session per repo,
reachable by webhook, that reviews finished branches and owns everything on GitHub.

## Why this split

| Concern | Where it runs | Why |
|---|---|---|
| Implement, gate, fix, repeat | local runner (Grok by default) | The loop is the token-expensive part and Grok is flat-rate ([doc 15](15-model-economics.md)). |
| Second opinion when the loop stalls | Codex / Claude, read-only | Different vendor, no write access, cheap because it only reads ([doc 20](20-multi-model-orchestration.md) rule 1). |
| Review, PR, CI, merge | Devin cloud | Persistent context and GitHub authority; paid only for a short, diff-scoped run. |

The cost argument is the routing, not the uptime. Devin's own billing docs note that
a sleeping session consumes no usage and idle sessions auto-sleep, so keeping one
supervisor around is not what costs money — an unscoped review is. Hence the
supervisor prompt is scoped to the diff and the session carries `max_acu_limit`.

The doctrine argument is stronger than the cost one: the supervisor **did not write
the code**, so it satisfies Law 5 (never grade your own homework) structurally
rather than by asking a runner to be honest about its own diff.

## The escalation ladder

```
1. grok          implement → green gate → fix        (repeat, flat-rate)
2. codex/claude  read-only second opinion            (after --escalate-after N failures)
3. devin cloud   review the diff, PR, CI, merge      (when the branch is ready)
4. human         the gate list in docs/14            (never automated away)
```

Nothing escalates on a task that goes green on the first pass, which is most of them.

## Wiring

```bash
export DEVIN_API_KEY=...            # https://app.devin.ai/settings/api-keys
export DEVIN_WEBHOOK_URL=...        # optional, see "Waking it" below

./scripts/loop.sh --runner grok --repo ~/Code/acme-app \
  --escalate-after 2 --reviewers codex,claude --supervisor devin
```

- `--escalate-after N` — after N consecutive runner failures the driver runs
  [`second-opinion.sh`](../scripts/second-opinion.sh) and writes the verdicts to
  `gibson/second-opinion.md`. The next hat reads that file (fresh context, file
  handoff — [doc 11](11-solo-loop.md)).
- `--supervisor devin` — the driver ensures a live supervisor at startup and, after
  any successful iteration, forwards whatever branch loop-state names.

### The handoff field

The loop agent asks for review by writing one line into `gibson/loop-state.md`:

```
handoff: gibson/42-password-reset
```

The driver forwards that branch (with the task, the diffstat, and any second
opinion) to the supervisor and clears the field. This keeps the same discipline as
the rest of the loop: **state lives in files, not in a conversation.**

Handoffs can also be made by hand:

```bash
./scripts/devin-supervisor.sh handoff --repo ~/Code/acme-app \
  --branch gibson/42-password-reset --task-file gibson/issue-42.md --wait
```

## Waking it

The session id is cached in `<repo>/gibson/devin-session.json`. Before each handoff
the driver checks the live status; if the session ended (`expired`, `finished`,
suspended), it POSTs to `DEVIN_WEBHOOK_URL` — a Devin **webhook automation** that
spawns a fresh supervisor — and adopts the new session. With no webhook configured
it falls back to creating a session through the API, so the loop never stalls on a
dead supervisor.

To create the automation: Devin → Automations → new automation → trigger
**Webhook** → paste the supervisor brief (`devin-supervisor.sh --help` prints the
same responsibilities) → copy the webhook URL into `DEVIN_WEBHOOK_URL`. Anything
else that should revive the fleet — cron, CI, an on-call alert — can POST the same
URL.

```bash
./scripts/devin-supervisor.sh status --repo ~/Code/acme-app
./scripts/devin-supervisor.sh wake   --repo ~/Code/acme-app --reason "nightly check"
```

## Merge authority

`devin-supervisor.sh handoff --merge` lets the supervisor merge once every required
check is green. Leave it off for Tier C work — money, auth, consent/PII, security
boundaries, production data — where [doc 14](14-human-gates.md) requires a human at
the merge gate. The supervisor is told to wait out required checks before merging
([doc 20](20-multi-model-orchestration.md) rule 4) and to stop rather than rewrite a
change that is fundamentally wrong.

## What the supervisor is told not to do

- Do not explore the whole repository; stay inside the diff (this is the ACU bill).
- Do not trust the runner's PASS; re-read the diff and confirm the checks ran.
- Do not start unrelated work, and do not cross a human gate.

## Running it unattended

The local half is a resident process on whatever machine holds your runners — a Mac
mini works well since Codex and Claude are already logged in there. See
[`adapters/devin/README.md`](../adapters/devin/README.md) for the launchd job, and
[doc 11](11-solo-loop.md) for the loop's kill switch and error budget, both of which
still apply: `gibson/HALT` stops everything, including handoffs.

---
[← 21 · Operator readiness](21-operator-readiness.md) · [Home](../index.md) · [Prompts →](prompts.md)
