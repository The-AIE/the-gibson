---
title: "Adapter · Goose"
nav_exclude: true
---

# Adapter — Goose (engine under the hood)

Contract: [docs/10](../../docs/10-vendor-adapters.md). Strategy: [docs/GOOSE-STRATEGY.md](../../docs/GOOSE-STRATEGY.md).
License gate: [docs/GOOSE-LICENSE-VERIFICATION.md](../../docs/GOOSE-LICENSE-VERIFICATION.md) (**passed**).

Goose is the **runtime engine**. The product identity remains **The Gibson**. Users
should see Gibson doctrine, Gibson CLI entry points, and Gibson gates — not a
Goose-branded experience (Apache-2.0 §6 + CUSTOM_DISTROS.md upstream).

## How to use this

### 1. Install Goose CLI (pinned)

```bash
# Prefer a pinned release over `stable` floating for fleet machines
curl -fsSL https://github.com/aaif-goose/goose/releases/download/v1.45.0/download_cli.sh | bash
goose --version
```

| Field | Text |
|---|---|
| What I'm asking | Install a **pinned** Goose CLI. |
| What it does | Provides the agent loop, MCP extension host, and recipes. |
| Why | Stops reinventing plumbing; Gibson owns brand + gates. |
| Risks | Upstream CLI on PATH; pin the version (docs/GOOSE-LICENSE-VERIFICATION §3). |

### 2. Doctrine mounting

Goose loads session instructions from recipes and optional project hints. Gibson
always mounts doctrine **explicitly** (never rely on ambient config alone):

1. `AGENTS.md` (target) + Gibson `AGENTS.md`
2. Role playbook from `playbooks/<role>.md`
3. `memory/LESSONS.md` (relevant slice)

The operator path is a Gibson recipe that embeds those files (see
`playbooks/recipes/`). For ad-hoc sessions:

```bash
GIBSON=~/Code/the-gibson
REPO=~/Code/app

goose run --recipe "$GIBSON/playbooks/recipes/builder.yml" \
  --params "repo=$REPO" --params "issue=42" --params "gibson=$GIBSON"
```

### 3. Session lifecycle (Laws 2, 3, 4, 10)

Always:

```bash
# Claim + worktree (never edit canonical)
$GIBSON/scripts/claim.sh 42 feature-slug 'path/globs/**'
cd ../wt-42-feature-slug

# Run role on Goose
goose run --recipe "$GIBSON/playbooks/recipes/builder.yml" \
  --params "repo=$(pwd)" --params "issue=42" --params "gibson=$GIBSON"

# Green gate before commit
$GIBSON/scripts/gate.sh

# After merge
$GIBSON/scripts/release-claim.sh 42
```

### 4. loop.sh integration

```bash
$GIBSON/scripts/loop.sh --runner goose --repo ~/Code/app
```

The `goose` runner invokes `goose run` with the rendered loop-step prompt file
(same headless contract as other runners). Prefer recipes for role-shaped work;
use loop for continuous solo grind.

### 5. Brand / re-brand notes

Upstream documents **custom distributions** (white-label): config-only, extension
bundles, recipe workflows, and full UI rebrand
(https://github.com/aaif-goose/goose/blob/main/CUSTOM_DISTROS.md). Gibson's
posture:

- **Now:** recipe + adapter wrapper — Goose CLI may appear in process lists;
  operator-facing docs and Ask Contract stay Gibson-branded.
- **Later (optional distro):** custom system prompt + bundle name so end users
  never see the word Goose (spike #28 measures depth).

### 6. Telemetry & cost

- Disable upstream telemetry on fleet hosts: `export GOOSE_DISABLE_TELEMETRY=1`
- Cost is the **LLM provider** bill (BYOK). Log wall time + iterations like Grok.

## Smoke test

```bash
goose --version
test -f playbooks/recipes/builder.yml && echo recipe_ok
```

## Status (epic #30)

| Piece | State |
|---|---|
| Adapter README + recipe path | This PR |
| End-to-end builder session transcript | #33 / #28 |
| Gate enforcement inside session | #35 |
| Funnel extension | #36 (publish Mark-gated) |
