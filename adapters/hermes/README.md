# Adapter — Hermes

Contract: [docs/10](../../docs/10-vendor-adapters.md). Hermes is the fleet's **voice**
(digests, escalations, Operator chat) and a **cron-shaped** worker — model-agnostic
backend (Nous/OpenRouter/Anthropic/OpenAI per your Hermes config).

## How to use this

### 1. Install / run Hermes

Follow your Hermes deployment (often a always-on agent with messaging channels:
iMessage, Slack, etc.). Confirm it can:

- Read files on the machine that holds repo checkouts
- Run shell commands in a sandbox you accept
- Post messages to Mark / Operator channels

| Field | Text |
|---|---|
| What I'm asking | Connect Hermes so the AI team can text you status and questions. |
| What it does | Sends digests, decision cards, and incident notes in plain language. |
| Why | You should not need a terminal to run the product (docs/16). |
| Risks | Messaging access to your chat apps; scope the bot's permissions. Revoke channel access to undo. |

### 2. Doctrine loading

Persona / system instruction should include:

```
You operate under The Gibson AGENTS.md. Load it from <path>/AGENTS.md every session.
Playbooks live in <path>/playbooks/. Operator messages use playbooks/templates/ only
(four shapes). Ask Contract on every human ask.
```

### 3. Role dispatch

**Cron iteration (solo loop shape):**

```bash
# crontab example: every 30 minutes during grind window
*/30 * * * * MC_HEARTBEAT_URL=… /path/to/the-gibson/scripts/loop.sh \
  --runner hermes --repo /path/to/app --once >> /var/log/gibson-loop.log 2>&1
```

Set `HERMES_CMD` if the binary is nonstandard:

```bash
export HERMES_CMD='hermes run --prompt-file /dev/stdin'
```

**On-demand role:**

```bash
hermes run --prompt "$(cat /path/to/the-gibson/playbooks/historian.md)

Mode: weekly-retro
"
```

### 4. Operator messaging

Render only:

- `playbooks/templates/decision-card.md`
- `playbooks/templates/status.md`
- `playbooks/templates/intake-question.md`
- `playbooks/templates/incident-notice.md`

Confusion replies ("I don't understand") → explain + file lesson (docs/16 / docs/09).

### 5. Telemetry

- Cron heartbeat + MC MCP
- Digests are themselves liveness signals to humans

### 6. Cost capture

Hermes often uses a cheap model for messaging (G-grade). Log model id + token
usage when the backend exposes it; do not burn frontier models on status pings.

## Smoke test

1. Ask Hermes: "What's waiting on me?" → should list open decision cards or say none.
2. Trigger a dry decision card from a test gate → six fields present, recommendation
   mandatory.
