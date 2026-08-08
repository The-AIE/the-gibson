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
| `lane` | 1–3 | One lane record per line (see below). Fleet WIP doctrine caps concurrent lanes at **3**; a fourth lane fails closed with zero launches. |

### Scalar uniqueness

Each scalar key (`version`, `name`, `repo`, `slug`, and the optional path /
runner / budget keys) may appear **at most once**. A second assignment is
malformed and fails closed (no last-wins). Repeated `lane=` records are
required and allowed (subject to unique lane ids and disjoint issues/scopes).

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
3. Fill `lane=` lines from **open, non-gated** issues only (see preflight rules).
4. Keep credentials out of the file (auth stays in CLI logins / env).

Migrating Chatterbuilt: copy your current `LANES=(...)` entries into a **local**
profile as `lane=` lines. Do not land that live queue or `$HOME/...` paths in
the generic template.

### Gibson self-dogfood sketch (#96 / Autonomy Readiness)

The example file shows a two-lane Gibson shape (`docs` + `harness`) seeded
with `#96-style` intent. Before overnight:

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

### Operator prerequisites

- **Bash 3.2+** (macOS stock `/bin/bash` is fine)
- **Git** on `PATH`
- **GitHub CLI `gh` ≥ 1.9.0** — required for the built-in `--json`, `--jq`,
  and `--template` flows used by open-PR inventory (`gh pr list`) and
  claim/body re-verification (`gh pr view`). Older `gh` lacks those flags and
  will fail closed at preflight. No external `jq`, Python, or Perl is required
  on the production PR-ownership path (optional tools may still be used when
  present for wall-timeout process groups or label pretty-printing).
- Builder / reviewer / release CLIs for the three-role split (see below)

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

- Profile parse / version / required fields / absolute safe paths / **no duplicate scalars**
- Inter-lane scope overlap and duplicate issue ids
- `origin` slug matches profile `slug`
- Canonical checkout is clean (`git status --porcelain` must succeed; a failed
  probe is **not** treated as clean)
- Builder / reviewer / release three-role separation
- Open-PR inventory is parsed fail-closed (`gh pr list` via built-in
  `--template` emits strict metadata-only TSV of `number<TAB>headRefName`;
  only empty TSV output is zero-pair success; malformed output, missing
  fields, duplicates, or hitting the list limit all refuse)

#### Unstarted and future queue items (strict)

For issues the lane has **not** already recorded as current work:

- Issue must exist and be **OPEN**
- Must not carry gated labels: `needs-mark`, `decision`, `blocked`, `tier-c`,
  `gibson-halt`
- Must not carry `agent-claimed`
- Must not have an open PR whose head is `feat/<issue>-*` or `fix/<issue>-*`
  (or the bare `feat/<issue>` / `fix/<issue>` forms)

#### State-bound dead-lane resumption (exception)

When a lane worktree already has a valid `gibson/loop-state.md` whose `issue:`
is still in the configured queue and the lane is **not** running, the driver
treats that recorded issue as **own** work:

- Prior queue items before the recorded issue may be **CLOSED** (the lane
  advanced). Any still-**OPEN** prior item fails closed (no skip/park policy).
- The recorded issue may carry `agent-claimed` **only if** loop-state binds
  ownership via `pr:` and/or `handoff:` and that binding matches a single open
  PR (number and/or head branch).
- The matching PR body must contain **exactly one** machine-readable line:
  `- Active-work claim: issue-<issue>-<slug>`
  where `<slug>` is consistent with the bound head branch
  (`feat/<issue>-<slug>` or `fix/<issue>-<slug>`). Missing, duplicate,
  malformed, foreign-issue, or foreign-slug claims fail closed.
- Future queue items after the recorded issue stay under the **strict** rules
  above.

Healthy (still-running) lanes are left alone only after the per-lane
`.fleet-identity` marker matches, loop-state is valid, and the recorded issue
is in the configured queue. A live PID with missing/invalid state fails closed.

### Fingerprinted default namespaces

When `fleet_dir` / `log_dir` are omitted, defaults are namespaced by profile
**name** and a portable fingerprint of `profile_path` + physical `repo` +
`slug`. Two profiles that share a short `name=` but target different repos or
paths therefore get **distinct** lane bases, pidfiles, logs, and watchdogs.
Explicit `fleet_dir=` / `log_dir=` (or env `FLEET_DIR` / `LOG_DIR`) still win.

### `.fleet-identity` reuse checks

On first use the driver writes `.fleet-identity` under the fleet dir, log dir,
and each lane worktree (`name`, `profile_path`, `repo`, `slug`, and `lane=` for
per-lane markers). Before reusing any existing namespace, `--start`,
`--status`, and `--halt` validate those markers against the currently loaded
profile. A foreign or mismatched marker fails closed and does **not** mutate
pidfiles, HALT files, or loop-state. Per-lane identity is checked **before**
any pid helper that might delete a stale pidfile.

`--status` also reads `hat:` through the same space / no-space field grammar as
`loop.sh` (`hat: reviewer` and `hat:reviewer` both display).

## Related

- Driver: [`scripts/loop-fleet.sh`](../../scripts/loop-fleet.sh)
- Sensors: [`scripts/tests/loop-fleet.test.sh`](../../scripts/tests/loop-fleet.test.sh)
- Solo loop doctrine: [`docs/11-solo-loop.md`](../../docs/11-solo-loop.md)
- Concurrency / scopes: [`docs/05-concurrency.md`](../../docs/05-concurrency.md)
- Overnight single-loop dogfood: [`playbooks/dogfood-overnight.md`](../../playbooks/dogfood-overnight.md)
- Follow-up: issue **#141** (per-lane runner / pool routing)
