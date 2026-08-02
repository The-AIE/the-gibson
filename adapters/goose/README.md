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

### 1. Install Goose CLI (pinned v1.45.0, verify then run)

Do **not** pipe a download straight into a shell. Download the pinned
`download_cli.sh`, verify its SHA-256, then execute:

```bash
# Pinned Goose CLI installer for v1.45.0
# Official asset digest (SHA-256 of download_cli.sh):
# 54d64de9b10befba030d3fdc4f6c316de55557c203abeaa9525c04f450c34280
ASSET_URL="https://github.com/aaif-goose/goose/releases/download/v1.45.0/download_cli.sh"
EXPECTED_SHA256="54d64de9b10befba030d3fdc4f6c316de55557c203abeaa9525c04f450c34280"
curl -fsSL "$ASSET_URL" -o /tmp/goose-download_cli-v1.45.0.sh
echo "${EXPECTED_SHA256}  /tmp/goose-download_cli-v1.45.0.sh" | shasum -a 256 -c -
bash /tmp/goose-download_cli-v1.45.0.sh
goose --version
```

| Field | Text |
|---|---|
| What I'm asking | Install a **pinned** Goose CLI after checking its installer digest. |
| What it does | Provides the agent loop, MCP extension host, and recipes. |
| Why | Stops reinventing plumbing; Gibson owns brand + gates. |
| Risks | Upstream CLI on PATH; pin the version (docs/GOOSE-LICENSE-VERIFICATION §3). A failed SHA check means stop — do not run the script. |

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
# Worktree path after claim (see §3) — never the target's canonical checkout
REPO=~/Code/app-wt-42-feature-slug

goose run --recipe "$GIBSON/playbooks/recipes/builder.yml" \
  --params "repo=$REPO" --params "issue=42" --params "gibson=$GIBSON"
```

### 3. Session lifecycle (Laws 2, 3, 4, 10)

Claim from the **target repo's canonical checkout** (not from inside a worktree).
The claim script creates a sibling worktree; all mutation happens there.

```bash
GIBSON=~/Code/the-gibson
# Start in the target's canonical clone
cd ~/Code/app

# Claim + worktree (never edit canonical)
$GIBSON/scripts/claim.sh 42 feature-slug 'path/globs/**'
cd ../wt-42-feature-slug   # sibling worktree created by claim.sh

# Run role on Goose (direct recipe — current scaffold path)
goose run --recipe "$GIBSON/playbooks/recipes/builder.yml" \
  --params "repo=$(pwd)" --params "issue=42" --params "gibson=$GIBSON"

# Green gate before commit
$GIBSON/scripts/gate.sh

# After merge
$GIBSON/scripts/release-claim.sh 42
```

### 4. loop.sh integration (follow-up — not wired yet)

`scripts/loop.sh` currently accepts `--runner` values
`grok|hermes|claude|codex` only. Passing `--runner goose` exits with
**unknown runner**. Wiring a Goose runner into `loop.sh` is a **follow-up**
(epic #30 / adapter hardening after #28 runtime work) — do not document it as
available today.

**Current scaffold path:** invoke recipes directly with `goose run --recipe …`
as in §2–§3 above. Prefer recipes for role-shaped work once the CLI is installed
and the #28 live spike has been run.

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
| Adapter README + recipe path | This PR (docs/config scaffold only) |
| End-to-end builder session transcript | #33 / #28 |
| Gate enforcement inside session | #35 |
| Funnel extension | #36 (publish Mark-gated) |
| `loop.sh --runner goose` | Not implemented — follow-up |
