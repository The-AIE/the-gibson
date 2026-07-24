---
title: "Adapter · Codex"
nav_exclude: true
---

# Adapter — OpenAI Codex

Contract: [docs/10](../../docs/10-vendor-adapters.md). Ergonomics only — **zero private rules**.

## How to use this

### 1. Install CLI

```bash
# Per current OpenAI Codex CLI install
codex --version
```

| Field | Text |
|---|---|
| What I'm asking | Install the Codex CLI. |
| What it does | Runs OpenAI coding agents against a repo from the terminal. |
| Why | Strong terminal-heavy builder/fan-out worker (docs/15 S-grade). |
| Risks | Uses your OpenAI plan/limits. Can edit files when not in read-only mode. |

### 2. Auth

```bash
codex login   # or env-based auth per current docs
```

### 3. Doctrine loading

Codex reads `AGENTS.md` natively when present in the project root. For Gibson:

1. Target repo has Gibson section in `AGENTS.md` (docs/13).
2. Point the session at the worktree (not the canonical checkout for edits).
3. Optionally prepend:

```bash
codex exec --full-auto "First read AGENTS.md and memory/LESSONS.md (if present). Then: $(cat playbooks/builder.md) …"
```

### 4. Role dispatch

```bash
GIBSON=~/Code/the-gibson
cd ../wt-42-slug

codex exec --full-auto "$(cat $GIBSON/playbooks/builder.md)

Issue: #42
"

# Review (read-only sandbox)
codex exec -s read-only "$(cat $GIBSON/playbooks/reviewer.md)

PR: #123
"
```

### 5. Telemetry

No lifecycle hooks like Claude. Options:

- Session watcher daemon (Mission Control pattern)
- Best-effort MCP `report_status` if configured
- Always: PR + claim table as ground truth for "who's working"

### 6. Cost capture

If the CLI does not emit exact USD, record dispatcher-side estimates on the task
(docs/15). Prefer flat-rate pools for volume; use Codex where S-grade is needed.

### 7. Solo loop

```bash
$GIBSON/scripts/loop.sh --runner codex --repo ~/Code/app --once
```

## Smoke test

```bash
codex exec -s read-only "Summarize the Ten Laws from AGENTS.md in ten bullets."
```
