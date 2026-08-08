# Fleet profiles (v1) — portable multi-lane targets

> 🙂 **In plain English:** a small text file tells the overnight fleet *which
> project* to work on, *which issues* each parallel worker gets, and *which
> folders* each worker may touch. Swap the file to aim the same driver at a
> different project — never by only changing the repo path while leaving
> someone else's issue list in place.

## Why

The legacy laptop driver (`~/.claude/fleet/loop-fleet.sh`) exposed `BASE_REPO`
but embedded Chatterbuilt issue queues, scopes, and intent. Pointing
`BASE_REPO` at Gibson (or any other checkout) could open the wrong issue
numbers against the wrong tree. Issue **#139** moves target / queue / scope /
intent into an **explicit versioned profile**. Per-lane runner and pool
balancing is **#141** (not implemented here); the optional lane `runner` field
is accepted so profiles stay forwards-compatible.

## Format version 1

Declarative data only. The driver **parses** the file; it never `source`s or
executes it.

| Key | Required | Meaning |
|---|---|---|
| `version` | yes | Must be `1` for this driver |
| `name` | yes | Short profile id (printed on status/start/halt) |
| `repo` | yes | **Absolute** path to the target checkout |
| `slug` | yes | Expected GitHub `owner/repo` (must match `origin`) |
| `gibson` | no | Absolute path to The Gibson clone |
| `fleet_dir` | no | Absolute dir for long-lived `lane-*` worktrees |
| `log_dir` | no | Absolute dir for per-lane logs |
| `runner` | no | Global builder CLI name (default `grok` / env `RUNNER`) |
| `error_budget` | no | Passed to `loop.sh` |
| `deadline_seconds` | no | Watchdog sleep before graceful `--halt` |
| `lane` | ≥1 | One lane record per line (see below) |

### Lane records

```text
lane=ID|QUEUE|SCOPE|INTENT
lane=ID|QUEUE|SCOPE|INTENT|RUNNER_RESERVED
```

- **ID** — unique; letters/digits/`_`/`-`; must not start with `wt-` (release
  cleanup treats `wt-*` as disposable per-issue worktrees).
- **QUEUE** — comma-separated positive issue numbers, work order left → right.
- **SCOPE** — space-separated path/glob tokens; **disjoint across lanes**
  (prefix/containment check, not string-equality alone).
- **INTENT** — free text the builder re-reads each hat.
- **RUNNER_RESERVED** — optional 5th field for **#141**; accepted, ignored for
  routing in this release (global `runner` / `RUNNER` still applies).

Unknown keys, duplicate lane ids, empty queue/scope/intent, non-absolute or
`..`-bearing paths, and overlapping scopes all **fail closed** before any
runner launches.

## Local profiles (do not commit secrets or machine paths)

1. Copy the example:
   ```bash
   cp templates/fleet/profile.v1.example ~/.config/gibson/profiles/my-target.profile
   # or: local/fleet-my-target.profile  (if local/ is gitignored in your fork)
   ```
2. Set `repo=` and `slug=` to **your** absolute checkout and GitHub slug.
3. Fill `lane=` lines from **open, non-gated** issues only.
4. Keep credentials out of the file (auth stays in CLI logins / env).

Migrating Chatterbuilt: copy your current `LANES=(...)` entries into a **local**
profile as `lane=` lines. Do not land that live queue or `$HOME/...` paths in
the generic template.

### Gibson self-dogfood sketch (#96 / Autonomy Readiness)

The example file shows a two-lane Gibson shape (`docs` + `harness`) seeded with
#96-style intent. Before overnight:

- Prefer issues that pass `scripts/dogfood-prep.sh` / are not parked (#28/#33/#36).
- Single-lane dogfood can still use `scripts/dogfood-prep.sh` + `loop.sh`.
- Multi-lane dogfood uses `scripts/loop-fleet.sh` with a local Gibson profile.

## Driver usage

```bash
GIBSON=/absolute/path/to/the-gibson
PROFILE=/absolute/path/to/local.profile

# Always prints: profile name, absolute target repo, expected slug
$GIBSON/scripts/loop-fleet.sh --profile "$PROFILE" --status
$GIBSON/scripts/loop-fleet.sh --profile "$PROFILE" --start
$GIBSON/scripts/loop-fleet.sh --profile "$PROFILE" --halt

# equivalent:
export FLEET_PROFILE="$PROFILE"
$GIBSON/scripts/loop-fleet.sh --status
```

### Three-role defaults (preserved)

| Role | Default | Rule |
|---|---|---|
| Builder | `RUNNER` / profile `runner` (often `grok`) | Implements |
| Reviewer | `REVIEWER_CMD` → `codex exec -s read-only -` | Cross-vendor; never self-grade |
| Release | `RELEASE_CMD` → Claude with `bypassPermissions` | Third identity; needs Bash+`gh` (L-048) |

Override with env if your machine's CLIs differ — but never set reviewer/release
to the same identity as the builder.

### Preflight (fail closed → zero launches)

Before any `loop.sh` start the driver checks:

- Profile parse / version / required fields / absolute safe paths
- Inter-lane scope overlap and duplicate issue ids
- `origin` slug matches profile `slug`
- Canonical checkout is clean
- Every queued issue exists, is **open**, and lacks gated labels:
  `needs-mark`, `decision`, `blocked`, `tier-c`, `gibson-halt`
- No `agent-claimed` label (claim conflict)
- No open PR whose head branch is `feat/<issue>-*` / `fix/<issue>-*`
- Builder / reviewer / release three-role separation

## Related

- Driver: [`scripts/loop-fleet.sh`](../../scripts/loop-fleet.sh)
- Sensors: [`scripts/tests/loop-fleet.test.sh`](../../scripts/tests/loop-fleet.test.sh)
- Solo loop doctrine: [`docs/11-solo-loop.md`](../../docs/11-solo-loop.md)
- Concurrency / scopes: [`docs/05-concurrency.md`](../../docs/05-concurrency.md)
- Overnight single-loop dogfood: [`playbooks/dogfood-overnight.md`](../../playbooks/dogfood-overnight.md)
- Follow-up: issue **#141** (per-lane runner / pool routing)
