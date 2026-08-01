---
title: "Adapter · Devin"
nav_exclude: true
---

# Adapter — Devin (cloud supervisor)

Contract: [docs/10](../../docs/10-vendor-adapters.md). Unlike the other adapters,
Devin is wired as the **cloud supervisor** rather than a local runner: it reviews
finished branches and owns GitHub. Doctrine:
[docs/22](../../docs/22-devin-cloud-supervisor.md).

## How to use this

### 1. Get an API key

Create one at <https://app.devin.ai/settings/api-keys> (or under a service user, if
you want the fleet to act as a bot identity rather than as you).

| Field | Text |
|---|---|
| What I'm asking | Create a Devin API key and export it as `DEVIN_API_KEY`. |
| What it does | Lets the harness open one long-lived cloud session that reviews finished work and does the GitHub steps. |
| Why | The reviewer must be a different model than the author (AGENTS.md Law 5), and someone has to own PRs, CI, and merges without you watching. |
| Risks | The key can start sessions that spend ACUs and act on your GitHub repos. Keep it in your shell/keychain, never in the repo, and cap spend with `DEVIN_MAX_ACU`. Revoke it on the same settings page. |

```bash
export DEVIN_API_KEY=...
export DEVIN_MAX_ACU=10          # optional ceiling per supervisor session
./scripts/devin-supervisor.sh ensure --repo ~/Code/acme-app
```

### 2. Webhook wake (optional but recommended)

Devin → Automations → new automation → trigger **Webhook** → prompt it with the
supervisor brief (printed by `./scripts/devin-supervisor.sh --help`) → copy the URL.

```bash
export DEVIN_WEBHOOK_URL=https://api.devin.ai/v1/automations/<id>/webhook
./scripts/devin-supervisor.sh wake --repo ~/Code/acme-app --reason "session ended"
```

| Field | Text |
|---|---|
| What I'm asking | Create a webhook automation and export its URL. |
| What it does | Any dead supervisor gets replaced automatically the next time work is ready. |
| Why | Cloud sessions end; the overnight loop shouldn't stall because one did. |
| Risks | Anyone holding that URL can start a Devin session. Treat it as a secret. Without it the harness still works — it creates sessions through the API instead. |

### 3. Doctrine loading

The supervisor is briefed at session creation with its standing responsibilities
(review scope, GitHub ownership, human gates, "a PASS is a claim, not proof"). Each
handoff message carries the branch, the task, the diffstat, and any cross-vendor
second opinion — a worker's dispatch contract, applied to the coordinator
([docs/20](../../docs/20-multi-model-orchestration.md)).

### 4. Role dispatch

```bash
GIBSON=~/Code/the-gibson

# hand a finished branch over for review + PR + CI + (optional) merge
$GIBSON/scripts/devin-supervisor.sh handoff --repo ~/Code/acme-app \
  --branch gibson/42-password-reset --task-file gibson/issue-42.md --wait

# or let the loop driver do it whenever loop-state carries `handoff:`
$GIBSON/scripts/loop.sh --runner grok --repo ~/Code/acme-app \
  --escalate-after 2 --reviewers codex,claude --supervisor devin
```

### 5. Telemetry

`devin-supervisor.sh status` prints the cached session, its live status, and the PR
it is working on. Session state lives in `<repo>/gibson/devin-session.json`; the
session URL is the ground truth for what it did.

### 6. Cost capture

ACUs are reported per session in the Devin dashboard. Keep handoffs diff-scoped and
set `DEVIN_MAX_ACU`; route bulk implementation to flat-rate runners
([docs/15](../../docs/15-model-economics.md)).

### 7. Running the local half 24/7 (macOS)

The runners and the driver stay on your own machine. On a Mac mini:

```bash
cp adapters/devin/com.gibson.loop.plist ~/Library/LaunchAgents/
# edit paths + env vars inside, then:
launchctl load -w ~/Library/LaunchAgents/com.gibson.loop.plist
tail -f ~/Library/Logs/gibson-loop.log
```

Kill switch is unchanged: `touch <repo>/gibson/HALT` stops the loop and all handoffs.

## Smoke test

```bash
./scripts/devin-supervisor.sh ensure --repo ~/Code/acme-app   # prints session id + URL
./scripts/devin-supervisor.sh status --repo ~/Code/acme-app
```
