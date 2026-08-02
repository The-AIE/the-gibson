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

## Scaffold boundary (read first)

This adapter is a **docs/config scaffold** for epic #30. The shipped
`playbooks/recipes/builder.yaml` is **validation-only**: it proves the official
Goose Recipe schema shape for pinned CLI **v1.45.0**. It is **not** an authorized
operational builder session.

**Do not** run `goose run` (or any other live Goose session) against a target
repository with this recipe until:

1. **#28** — live runtime / red-team spike has been completed, and
2. **#35** — permission and gate enforcement for in-session work is in place.

Recipe settings cannot encode a Goose permission mode. Pinned Goose v1.45.0's
own defaults are autonomous. This scaffold deliberately does **not** choose or
document a Gibson `GOOSE_MODE` / permission preset. That decision stays with
#28 / #35 and any separate adoption of [docs/autonomy-modes.md](../../docs/autonomy-modes.md).

**Authorized today:** install the pinned CLI (lab), and run
`goose recipe validate` on the absolute Gibson recipe path (smoke test below).

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

### 2. Doctrine mounting (scaffold)

Goose loads session instructions from recipes and optional project hints. Gibson
always mounts doctrine **explicitly** (never rely on ambient config alone):

1. Gibson `AGENTS.md`
2. Optional Gibson `local/AGENTS.local.md` (fork overlay, if present)
3. Target repo `AGENTS.md` (if present)
4. Role playbook from `playbooks/<role>.md`
5. `memory/LESSONS.md` (relevant slice)

The operator path is a Gibson recipe that **references** those files on disk —
see `playbooks/recipes/`. The builder recipe's instructions list that load
order; validating the recipe (smoke test) confirms the schema and template
shape only.

**Not authorized on this PR:** a live `goose run` against a repository. That
wait remains until #28 and #35 (see Scaffold boundary above).

### 3. Planned session lifecycle (Laws 2, 3, 4, 10) — future sequence

After #28 and #35 authorize live Goose builder sessions, the intended sequence
is the same claim → worktree → gate → release path used by other adapters.
Documented here as **planned sequence only** — not an executable Goose builder
invocation.

```bash
GIBSON=~/Code/the-gibson   # absolute path to the Gibson clone
# Start in the target's canonical clone
cd ~/Code/app

# Claim + worktree (never edit canonical)
$GIBSON/scripts/claim.sh 42 feature-slug 'path/globs/**'
cd ../wt-42-feature-slug   # sibling worktree created by claim.sh

# --- future: authorized Goose builder session (blocked until #28 + #35) ---
# Do not run goose run / recipe-driven mutation against the worktree yet.
# Permission mode and in-session gate enforcement are not encoded in the
# recipe; they land with #28 / #35, not this scaffold.

# Green gate before commit (Gibson scripts; independent of Goose)
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

**Current authorized scaffold path:** `goose recipe validate` against the
absolute Gibson recipe path (smoke test). Prefer that over any `goose run`
until #28 and #35 clear live sessions.

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

## Smoke test (validation only)

Use the absolute path to the Gibson clone. This checks recipe schema only; it
does **not** authorize a live builder session.

```bash
GIBSON=~/Code/the-gibson   # absolute path to your Gibson clone
goose --version            # expect 1.45.0 (pinned)
goose recipe validate "$GIBSON/playbooks/recipes/builder.yaml"
```

## Status (epic #30)

| Piece | State |
|---|---|
| Adapter README + recipe path | This PR (docs/config scaffold only; validation-only) |
| Live `goose run` against repositories | **Not authorized** until #28 + #35 |
| End-to-end builder session transcript | #33 / #28 |
| Gate enforcement inside session | #35 |
| Funnel extension | #36 (publish Mark-gated) |
| `loop.sh --runner goose` | Not implemented — follow-up |
