---
title: "Adapters"
nav_exclude: true
---

# adapters/ — vendor runtimes

One directory per runtime. Contract and matrix: [docs/10](../docs/10-vendor-adapters.md).

Each adapter provides:

1. **Doctrine loading** — AGENTS.md into context  
2. **Role dispatch** — run `playbooks/<role>.md`  
3. **Telemetry** — deterministic where possible  
4. **Cost capture** — exact or estimated  

Adapters carry **zero rules of their own**.

| Runtime | README |
|---|---|
| Claude Code | [claude-code/README.md](claude-code/README.md) |
| OpenAI Codex | [codex/README.md](codex/README.md) |
| Grok | [grok/README.md](grok/README.md) |
| Hermes | [hermes/README.md](hermes/README.md) |
| Goose (engine) | [goose/README.md](goose/README.md) |
| Devin (cloud supervisor) | [devin/README.md](devin/README.md) |

**Goose** is the preferred **engine under the hood** for single-builder sessions
([docs/GOOSE-STRATEGY.md](../docs/GOOSE-STRATEGY.md)). Gibson remains the brand.

Devin is the odd one out: it is wired as the persistent **cloud supervisor** that
reviews finished branches and owns GitHub, not as a local runner
([docs/22](../docs/22-devin-cloud-supervisor.md)).

Mission Control's `agents/<vendor>/` docs remain the working reference for MC
ingest wiring when that control plane is deployed.
