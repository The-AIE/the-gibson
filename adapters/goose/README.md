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

## Boundary (read first)

| Layer | State |
|---|---|
| Recipes (`playbooks/recipes/*.yaml`) | Validation-only schema mirrors (Goose CLI **v1.45.0**) |
| **Enforcement** (`enforce.sh`, `session.sh`, `permission-map.yaml`) | **Landed (#35)** — pure bash; no Goose binary required |
| Live `goose run` against a target repo | **Blocked until #28** live spike |
| `loop.sh --runner goose` | Not wired (follow-up) |

**Do not** run `goose run` against a target repository until **#28** completes.
Enforcement (claim / worktree / gate / release) is invocable **today** via
`adapters/goose/enforce.sh` — same fail-closed exit codes as `scripts/*.sh`.

Permission tiers: [permission-map.yaml](permission-map.yaml) maps
[docs/autonomy-modes.md](../../docs/autonomy-modes.md) Always/Ask/Never classes.
Session defaults are still not forced unattended (AGENTS.md remains the stop authority; docs/14 is rationale).

**Authorized today:**
- `adapters/goose/enforce.sh` / `session.sh` lifecycle (offline sensors in CI)
- `goose recipe validate` on absolute Gibson recipe paths (if CLI installed)

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
4. Role playbook — **replacement, not additive** (Law 1 / docs/18): if no
   role is named, the resolved role is `builder` and `playbooks/builder.md`
   is the conditional load. If `local/playbooks/<role>.md` exists, mount
   **only** that file; otherwise mount core `playbooks/<role>.md`. Never
   mount both.
5. `memory/LESSONS.md` (relevant slice)

The operator path is a Gibson recipe that **references** those files on disk —
see `playbooks/recipes/`. The builder recipe's instructions list that load
order (including the local-playbook replacement rule); validating the recipe
(smoke test) confirms the schema and template shape only.

**Not authorized:** a live `goose run` against a repository until **#28**.
Enforcement helpers above do **not** require Goose and are authorized today.

### 3. Session lifecycle (Laws 2, 3, 4, 10) — executable today

Operator / orchestrator path. Enforcement is Gibson-branded (`enforce.sh`);
Goose is only the optional engine for agent turns after **#28**.

```bash
GIBSON=~/Code/the-gibson   # absolute path to the Gibson clone
CANON=~/Code/app
cd "$CANON"

# Claim + worktree (never edit canonical)
$GIBSON/scripts/claim.sh 42 feature-slug 'path/globs/**'
cd ../wt-42-feature-slug
WT=$(pwd)

# Fail-closed prepare: claim present + not canonical + baseline
$GIBSON/adapters/goose/session.sh prepare \
  --repo "$WT" --issue 42 --canonical "$CANON"

# --- agent work (live goose run still blocked until #28) ---
# When #28 authorizes: goose run with playbooks/recipes/builder.yaml
# Until then: any runtime may edit only after prepare succeeded.

# Before every commit — claim + green gate (exit codes match gate.sh)
$GIBSON/adapters/goose/session.sh pre-commit \
  --repo "$WT" --issue 42 --canonical "$CANON"

# After merge — Law 10 cleanup from canonical
cd "$CANON"
$GIBSON/adapters/goose/enforce.sh release 42
$GIBSON/adapters/goose/session.sh stamp --role builder --issue 42 --repo "$WT"
```

Offline proof of red-gate block (no network, no goose binary):

```bash
$GIBSON/adapters/goose/session.sh dry-run-lifecycle
```

Config templates: [templates/doctrine-mount.md](templates/doctrine-mount.md),
[templates/goosehints.fragment](templates/goosehints.fragment),
[permission-map.yaml](permission-map.yaml).

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
| Adapter README + recipes + templates | Landed |
| Gate/claim/release enforcement (`enforce.sh`) | **Landed (#35)** — offline sensors green |
| Permission map (autonomy-modes wiring) | **Landed** — `permission-map.yaml` |
| Session lifecycle driver (`session.sh`) | **Landed (#33 half)** |
| Live `goose run` / E2E agent transcript on Goose | **#28** (still open) |
| Funnel extension | #36 (publish Mark-gated) |
| `loop.sh --runner goose` | Not implemented — follow-up |
