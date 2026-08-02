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

### 1. Install Goose CLI (pinned v1.45.0, verify the release asset)

Do **not** pipe a download straight into a shell. Do **not** execute
upstream `download_cli.sh`: even when fetched from the v1.45.0 tag, that
wrapper subsequently downloads an **unverified** second-stage payload and
defaults to **stable** unless `GOOSE_VERSION` is set. Pin and verify the
actual release binary asset for your OS/architecture instead.

**Lab example — macOS arm64 only** (do not reuse this digest elsewhere):

```bash
# Lab example: macOS arm64 — Goose CLI v1.45.0 binary asset
# Asset: goose-aarch64-apple-darwin.tar.gz
# Official SHA-256:
# 90c50d653d7fd978ec5d436b548eca8613dc2d26d028b486b7c52271267ec500
# Other OS/architectures: pick the exact v1.45.0 asset and its published
# digest from the release notes — do not reuse this macOS arm64 digest.
set -eu
ASSET_URL="https://github.com/aaif-goose/goose/releases/download/v1.45.0/goose-aarch64-apple-darwin.tar.gz"
EXPECTED_SHA256="90c50d653d7fd978ec5d436b548eca8613dc2d26d028b486b7c52271267ec500"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/goose-install-v1.45.0.XXXXXX")"
ARCHIVE="${WORKDIR}/goose-aarch64-apple-darwin.tar.gz"
trap 'rm -rf "$WORKDIR"' EXIT
curl -fsSL "$ASSET_URL" -o "$ARCHIVE"
if command -v sha256sum >/dev/null 2>&1; then
  echo "${EXPECTED_SHA256}  ${ARCHIVE}" | sha256sum -c -
elif command -v shasum >/dev/null 2>&1; then
  echo "${EXPECTED_SHA256}  ${ARCHIVE}" | shasum -a 256 -c -
else
  echo "error: need sha256sum or shasum to verify the Goose asset" >&2
  exit 1
fi
tar -xzf "$ARCHIVE" -C "$WORKDIR"
mkdir -p "${HOME}/.local/bin"
install -m 755 "${WORKDIR}/goose" "${HOME}/.local/bin/goose"
# Ensure ~/.local/bin is on PATH, then:
goose --version
```

| Field | Text |
|---|---|
| What I'm asking | Install a **pinned** Goose CLI after checking the release asset digest. |
| What it does | Provides the agent loop, MCP extension host, and recipes. |
| Why | Stops reinventing plumbing; Gibson owns brand + gates. |
| Risks | Upstream CLI on PATH; pin the version (docs/GOOSE-LICENSE-VERIFICATION §3). A failed SHA check means stop — do not install the binary. Other OS/architectures must use their own v1.45.0 asset + published digest. |

### 2. Doctrine mounting

Goose loads session instructions from recipes and optional project hints. Gibson
always mounts doctrine **explicitly** (never rely on ambient config alone):

1. Gibson `AGENTS.md`
2. Optional Gibson `local/AGENTS.local.md` (fork overlay, if present)
3. Target repo `AGENTS.md` (if present)
4. Role playbook from `playbooks/<role>.md`
5. `memory/LESSONS.md` (relevant slice)

The operator path is a Gibson recipe that references those files (and
instructs Goose to read them from disk) — see `playbooks/recipes/`. For
ad-hoc sessions:

```bash
GIBSON=~/Code/the-gibson
# Worktree path after claim (see §3) — never the target's canonical checkout
REPO=~/Code/wt-42-feature-slug

goose run --recipe "$GIBSON/playbooks/recipes/builder.yaml" \
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
goose run --recipe "$GIBSON/playbooks/recipes/builder.yaml" \
  --params "repo=$(pwd)" --params "issue=42" --params "gibson=$GIBSON"

# Green gate before commit
$GIBSON/scripts/gate.sh

# After merge — return to the target's canonical checkout first
# (release-claim defaults GIBSON_CANONICAL to cwd; Law 10 / L-029)
cd ~/Code/app
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

- Disable upstream telemetry on fleet hosts: `export GOOSE_TELEMETRY_ENABLED=false`
- Cost is the **LLM provider** bill (BYOK). Log wall time + iterations like Grok.

## Smoke test

```bash
GIBSON=~/Code/the-gibson   # or your Gibson clone path
goose --version
test -f "$GIBSON/playbooks/recipes/builder.yaml" && echo recipe_ok
```

## Status (epic #30)

| Piece | State |
|---|---|
| Adapter README + recipe path | This PR (docs/config scaffold only) |
| End-to-end builder session transcript | #33 / #28 |
| Gate enforcement inside session | #35 |
| Funnel extension | #36 (publish Mark-gated) |
| `loop.sh --runner goose` | Not implemented — follow-up |
