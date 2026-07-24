---
title: "Adapter · Claude Code"
nav_exclude: true
---

# Adapter — Claude Code

Contract: [docs/10](../../docs/10-vendor-adapters.md). This adapter adds ergonomics only
— **zero private rules**.

## How to use this

### 1. Install CLI

```bash
# Follow current Anthropic Claude Code install docs for your OS
claude --version
```

**Ask Contract (install):**

| Field | Text |
|---|---|
| What I'm asking | Install the Claude Code command-line tool on this machine. |
| What it does | Lets agents run Claude with your project files under your login. |
| Why | Claude is the fleet's strong reviewer/planner pool (docs/15). |
| Risks | Uses your Anthropic account/subscription limits. Uninstall removes the CLI; does not change GitHub by itself. |

### 2. Auth

```bash
claude auth status   # or login flow per current CLI
```

### 3. Doctrine loading

In **each target repo** (and in The Gibson itself):

```markdown
# CLAUDE.md
@AGENTS.md
```

Claude Code pulls `AGENTS.md` via `@` includes. Also ensure Gibson doctrine is
reachable (clone path or submodule). Law 1: agents read Gibson AGENTS + target
AGENTS + `memory/LESSONS.md` at session start.

Optional local overlay: `local/AGENTS.local.md` (forks).

### 4. Role dispatch

**Interactive skill-style:** open Claude in the worktree; paste or `@playbooks/builder.md`
with issue number.

**Headless:**

```bash
GIBSON=~/Code/the-gibson
claude -p --output-format json --permission-mode acceptEdits \
  "$(cat $GIBSON/playbooks/builder.md)

Issue: #42
Target: $(pwd)
"
```

**Read-only review:**

```bash
claude -p --permission-mode plan \
  "$(cat $GIBSON/playbooks/reviewer.md)

PR: #123
"
```

### 5. Telemetry (Mission Control)

Claude Code lifecycle hooks are the gold standard for liveness. Wire SessionStart /
Stop / etc. to MC ingest per Mission Control's `agents/claude-code` docs when MC is
deployed. Until then: PR comments + honest status are the minimum.

### 6. Cost capture

Claude Code reports `total_cost_usd` in JSON output — record on the MC task or PR
comment for the weekly cost-per-merged-PR number (docs/15).

### 7. Solo loop

Prefer Grok for grind; use Claude for hard hats:

```bash
$GIBSON/scripts/loop.sh --runner claude --repo ~/Code/app --hat reviewer --once
```

## Smoke test

```bash
cd ~/Code/some-adopted-repo
claude -p "Read AGENTS.md and reply with the green-gate commands only."
```

Expect the target's typecheck/lint/test/build lines — proves doctrine loaded.
