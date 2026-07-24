---
title: "10 · Any AI, same rules"
parent: The Doctrine
nav_order: 10
---

# 10 — Vendor Adapters: One Doctrine, Any Runtime

> 🙂 **In plain English:** The rules are the same no matter which AI brand you use.
> Brand-specific folders only add convenience. They never invent private rules that
> other tools would not know about.

The portability test: **could a brand-new runtime join the fleet with nothing but
git, a shell, and the ability to read Markdown?** Yes — because the core is
`AGENTS.md` + `docs/` + `scripts/` + CI, all vendor-neutral. Adapters add ergonomics
per runtime; they never carry rules of their own. (MetaHarness ships nine host
adapters over one core — same shape.)

## The adapter contract

Each `adapters/<vendor>/` provides, in whatever form the runtime supports:

1. **Doctrine loading** — get `AGENTS.md` (Gibson + target repo) into context at
   session start.
2. **Role dispatch** — run a `playbooks/<role>.md` prompt with an issue/PR argument.
3. **Telemetry** — deterministic liveness reporting to Mission Control (hooks or
   watcher), plus semantic reporting via MCP (`report_status`, `remember`/`recall`,
   `claim_task`).
4. **Cost capture** — report tokens/cost per run when the runtime exposes it;
   dispatcher-side estimate when it doesn't.

## Adapter matrix

| Runtime | Doctrine | Dispatch | Telemetry | Notes |
|---|---|---|---|---|
| **Claude Code** | `CLAUDE.md → @AGENTS.md`; skills mirror playbooks | `claude -p --output-format json --permission-mode acceptEdits`; skills interactively | lifecycle hooks (SessionStart/Stop/etc.) → MC ingest — the gold standard | exact `total_cost_usd`; richest adapter, still zero private rules |
| **OpenAI Codex** | reads `AGENTS.md` natively | `codex exec --full-auto "<playbook prompt>"`; `-s read-only` for review | session watcher daemon | terminal-heavy fan-out workhorse |
| **Grok** | `AGENTS.md` via prompt preamble | `grok -p "<playbook prompt>"`; solo loop (doc 11) | MC MCP calls + curl heartbeat | near-unlimited flat-rate pool — see doc 15 |
| **Hermes** | persona instruction + `AGENTS.md` | **first-class runner**: cron-driven role dispatch, solo loop driver, and messaging front-end (digests, escalations, "ping Mark") | MC MCP + cron heartbeat | model-agnostic (Nous/OpenRouter/Anthropic/OpenAI); the fleet's voice *and* a worker |
| **pi** | `AGENTS.md` natively | extension wrapping playbook dispatch | extension → MC ingest | primitives-native; good experimentation host |

## Known asymmetries (managed, not hidden)

- **Telemetry:** only Claude Code has true lifecycle hooks; others use watchers or
  best-effort MCP. Mitigation: liveness truth comes from the deterministic layer
  wherever it exists; the 15-minute-silence → offline rule covers the rest.
- **Cost:** exact for Claude Code, estimated elsewhere (doc 15's tables account for
  this).
- **Skills:** Claude skills are ergonomic wrappers. Anything expressible *only* as a
  skill is doctrine-debt — port it to a playbook.

## Playbooks are the portable skill format

`playbooks/<role>.md` = frontmatter (role, inputs, gates) + the dispatch prompt.
Claude skills, Codex prompts, Grok loop steps, and Hermes cron jobs all render from
the same playbook file. One source, five runtimes.

## Cross-vendor review wiring

The queue's `reviewer_platform` field stays the mechanism: worker finishes →
dispatcher runs the reviewer runtime read-only with the review playbook → verdict
appended → REQUEST_CHANGES re-queues for the builder. Gibson hardening: reviewer
unavailable = **block, don't skip** (doc 06).

---
[← 09 · How it learns from mistakes](09-memory-and-self-improvement.md) · [Home](../index.md) · [11 · One agent, running all night →](11-solo-loop.md)
