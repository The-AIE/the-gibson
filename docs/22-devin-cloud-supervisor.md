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

The loop agent asks for review by writing two lines into `gibson/loop-state.md`:

```
handoff: gibson/42-password-reset
handoff_sha: 9f1c0b3e5a7d2c4f6081b3d5e7a9c1f3b5d7e9a1
```

`handoff_sha` is the exact head the agent pushed. It is what makes the review
mean something: a later push cannot invalidate a completed review without the
driver and the supervisor both noticing.

The driver forwards that branch (with the task, the diffstat, and the
cross-vendor second opinion) to the supervisor and clears both fields. This keeps
the same discipline as the rest of the loop: **state lives in files, not in a
conversation.**

### The exact-SHA gate (issue #55)

Before a single ACU is spent, the driver runs a gate that **fails closed** — every
failure below leaves `handoff`/`handoff_sha` queued in loop-state and sends
nothing:

1. **Resolve and pin the base.** Reviews and handoffs use the target repo's own
   default branch, resolved as *both* a name and an exact commit. When an origin
   is configured, one live `ls-remote --symref` gives the current default branch
   and its current tip; stale local metadata is not trusted, because
   `refs/remotes/origin/HEAD` survives a rename and `refs/heads/main` can be many
   commits behind `origin/main`. A repo with no origin at all falls back to a
   verified local `main`/`master`. The supervisor gets the branch *name* (it opens
   a PR into it); the reviewer gets the exact base SHA, for the same reason the
   head side is pinned. A base that cannot be resolved or confirmed blocks the
   handoff instead of falling back to a guessed `main`.
2. **Resolve the SHA.** `handoff_sha` if pinned, otherwise the remote tip. A pin
   that disagrees with the remote tip is refused before a reviewer is spent.
3. **Make sure both objects are actually here.** Either tip may have been pushed
   from another worktree, so the commit can be missing from this clone. The driver
   fetches the exact branch (then the exact SHA) and verifies `<sha>^{commit}`
   resolves locally — for the base as well as the head. A commit nobody here can
   read cannot be reviewed, and is blocked instead of recorded.
4. **Require a distinct-vendor review of that exact diff.** `second-opinion.sh` is
   run with `--base <base sha> --branch <head sha>` — two exact commits, not two
   moving names; the runner is excluded from its own review (Law 5). Success
   writes `gibson/second-opinion.receipt` naming the head branch and SHA, the base
   branch and SHA, the author, and the reviewers. Reuse requires all of them to
   match, so a base branch that advances voids the receipt just as a new head
   commit does. A leftover `gibson/second-opinion.md` proves nothing and does not
   satisfy the gate — only a matching receipt does.
5. **Hand off with the pin.** `devin-supervisor.sh handoff --base <base> --sha
   <sha>` re-checks the remote tip and instructs the supervisor to reject the
   handoff if it has moved.

Handoffs can also be made by hand — note that the by-hand path skips the driver's
Law 5 gate, so you own the cross-vendor review yourself:

```bash
./scripts/devin-supervisor.sh handoff --repo ~/Code/acme-app \
  --branch gibson/42-password-reset --base main \
  --sha 9f1c0b3e5a7d2c4f6081b3d5e7a9c1f3b5d7e9a1 \
  --task-file gibson/issue-42.md --wait
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
[← 21 · Operator readiness](21-operator-readiness.md) · [Home](../index.md) · [23 · Delivery control →](23-delivery-control.md)
