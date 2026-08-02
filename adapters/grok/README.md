---
title: "Adapter · Grok"
nav_exclude: true
---

# Adapter — Grok

Contract: [docs/10](../../docs/10-vendor-adapters.md). Default **solo-loop grind** runner
([docs/11](../../docs/11-solo-loop.md), [docs/15](../../docs/15-model-economics.md)).

## How to use this

### 1. Install CLI

```bash
# Install/auth per current xAI Grok CLI docs for your environment
grok --version
```

| Field | Text |
|---|---|
| What I'm asking | Install the Grok CLI and sign in. |
| What it does | Runs Grok against prompts/files from the terminal. |
| Why | Near-unlimited flat-rate pool makes overnight backlog grinding cheap. |
| Risks | Can edit/push if permissions allow; use worktrees. Subscription limits still exist at extreme volume. |

### 2. Auth — subscription vs. API key (this is the bill)

Two paths, and they bill differently:

| Path | How | Billing |
|---|---|---|
| Subscription | `grok login` (or `grok login --device-code` on a headless box) → token in `~/.grok/auth.json` | Your flat-rate plan — what the overnight loop should use |
| API key | `export XAI_API_KEY=xai-…` from [console.x.ai](https://console.x.ai) | Metered per token |

Per the CLI's own auth docs, **a live session token wins over `XAI_API_KEY`** — the
key is only a fallback for environments with no browser login. So on a resident
loop host: run `grok login` once, and do **not** export `XAI_API_KEY` in the
launchd job. Set the key only on machines that cannot log in interactively (CI,
cloud agents). `grok logout` is what forces the key path.

Confirm:

```bash
grok -p "Reply with pong only."
```

### 3. Doctrine loading

Grok does not auto-load AGENTS.md unless you put it in the prompt (or tool-enabled
workspace). **Always** preamble:

```bash
grok -p "$(cat AGENTS.md)

$(cat /path/to/the-gibson/playbooks/builder.md)

Issue: #42
Target repo: $(pwd)
"
```

`loop.sh` renders `loop-step.md` which instructs the model to re-read doctrine from
files each hat — keep Gibson + target on disk where the runner can read them.

### 4. Role dispatch

```bash
GIBSON=~/Code/the-gibson

grok -p "$(cat $GIBSON/playbooks/reviewer.md)

PR: #123
Repo: ~/Code/app
"
```

### 5. Solo loop (primary use)

```bash
$GIBSON/scripts/loop.sh --runner grok --repo ~/Code/app

# One step debug
$GIBSON/scripts/loop.sh --runner grok --repo ~/Code/app --once --print-prompt | head
$GIBSON/scripts/loop.sh --runner grok --repo ~/Code/app --once
```

**Escalation:** set `REVIEWER_CMD` so Tier B/C review shells out cross-vendor:

```bash
export REVIEWER_CMD='claude -p --permission-mode plan'
# loop-step / reviewer hat should honor REVIEWER_CMD when present
```

### 6. Telemetry

- `MC_HEARTBEAT_URL` env for `loop.sh` curl heartbeat
- MCP `report_status` / `remember` when Mission Control MCP is configured
- 15 minutes silence ⇒ presumed dead (fleet rule)

### 7. Cost capture

Flat-rate: record iterations and wall time; USD may be ~0 marginal until saturation.
Still log outcomes for cost-per-merged-PR quality trends.

## Smoke test

```bash
cd ~/Code/the-gibson
./scripts/loop.sh --runner grok --repo . --once --print-prompt | grep -A2 'Current hat'
```
