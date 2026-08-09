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
intent into an **explicit versioned profile**. Per-lane ordered runner routes,
bounded readiness, and selection telemetry are **#141** (this release).

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
| `runner` | no | Default builder when a lane omits its route field (default `grok` / env `RUNNER`) |
| `error_budget` | no | Passed to `loop.sh` |
| `deadline_seconds` | no | Watchdog sleep before graceful `--halt` |
| `pool_map` | no | Optional, **repeatable**: `provider:pool-label` (e.g. `grok:flat-rate-grok`). Declares plan shape for cost telemetry. Default without a map is truthful `provider-<family>` — **no** invented flat-rate/subscription label from vendor identity. |
| `lane` | 1–3 | One lane record per line (see below). Fleet WIP doctrine caps concurrent lanes at **3**; a fourth lane fails closed with zero launches. |

### Scalar uniqueness

Each scalar key (`version`, `name`, `repo`, `slug`, and the optional path /
runner / budget keys) may appear **at most once**. A second assignment is
malformed and fails closed (no last-wins). Repeated `lane=` records are
required and allowed (subject to unique lane ids and disjoint issues/scopes).

### Lane records

```text
lane=ID|QUEUE|SCOPE|INTENT
lane=ID|QUEUE|SCOPE|INTENT|PRIMARY
lane=ID|QUEUE|SCOPE|INTENT|PRIMARY,FALLBACK1,FALLBACK2
```

- **ID** — unique; letters/digits/`_`/`-`; must not start with `wt-` (release
  cleanup treats `wt-*` as disposable per-issue worktrees).
- **QUEUE** — comma-separated positive issue numbers, work order left → right.
- **SCOPE** — space-separated path/glob tokens; **disjoint across lanes**
  (prefix/containment check, not string-equality alone).
- **INTENT** — free text the builder re-reads each hat.
- **ORDERED-RUNNER-ROUTE** — optional 5th field (**#141**): comma-separated CLI
  names, **primary first**, explicit fallbacks after. Empty (or omitted) →
  global `runner` / `RUNNER` only. Only declared tokens may be selected. A
  sixth pipe field still fails closed (forwards-compatible with #139).

### Runner routing (#141)

Before any new lane launch the driver:

1. Builds each lane's declared route (5th field, or global `runner` **only when
   field 5 is omitted**). Global `runner` / `RUNNER` is not required when every
   lane declares an explicit ordered route.
2. Preflights each configured CLI with a **bounded, noninteractive,
   credential-safe** readiness probe (process-group wall timeout; hung checks
   kill only the exact captured group). Probe stdout/stderr is discarded —
   never logged (no tokens, keys, env, or raw credential material).
3. **Auth / usability policy:** only a *positive* provider-specific result may
   select a runner. Codex uses `login status`, Claude `auth status`, Hermes
   `status`, Grok `models` — exit 0 only. Auth/status/models nonzero is
   `auth_fail` and **never** falls back to `--version` (a logged-out but
   installed CLI is not ready; Grok `--version` only proves the binary exists).
   Probe stdout/stderr is discarded — never inspected for classification.
   Unknown families without a stable noninteractive auth probe use one
   bounded minimal non-mutating usability probe (`--version`). Timeout remains
   exit **124** with process-group cleanup of the exact captured group only.
4. Selects the **first ready** runner in declared order. Fail over **only** on
   a classified readiness failure (`not_found`, `timeout`, `not_ready`,
   `auth_fail`). Operator order is preserved (no automatic reordering).
5. Re-checks three-role separation against the **actual selected** builder
   (not an unused global default). A ready candidate that collides with
   reviewer or release **fails closed** (fallback cannot bypass Law 5).
   Reviewer and release identities are validated nonempty and distinct
   globally at preflight. On `--start` against an already-running lane, the
   driver reloads the persisted `selected_runner`, validates it is nonempty
   and safe, and re-checks three-role separation against the *current*
   reviewer/releaser — identity revalidation only (no readiness re-probe).
   A live lane with **missing** `*.runner-status` fails closed (zero new
   launches; live process left untouched): current profile/route is not
   evidence of which executable launched the process. Halt/restart the lane
   or restore verified status before `--start`.
6. If no declared runner is ready/selectable → **fail closed, zero new
   launches**, with a diagnostic naming providers only.
7. Passes the selected runner to `loop.sh --runner`. Status shows
   requested primary, actual runner, and healthy/degraded/fallback reason
   (persisted under the profile log namespace for idempotent restart).
8. Appends fleet-local telemetry:
   - `gibson.fleet.runner_selection.v1` JSONL in `LOG_DIR/runner-selection.jsonl`
   - a matching `gibson.cost.v1` selection row in `LOG_DIR/cost-ledger.jsonl`
     (or `GIBSON_COST_LEDGER` when set)
   Both carry the same stable collision-resistant `join_key`
   (`fleet-sel:v1:…:UTC:discriminator`), selected provider/pool, fallback
   reason, selection wall time, and issue when known. No token counts or
   dollar costs are fabricated. Selection append failure fails closed
   (fleet-required telemetry).
9. Propagates `GIBSON_COST_JOIN_KEY`, `GIBSON_COST_POOL`,
   `GIBSON_COST_PROVIDER`, `GIBSON_COST_REQUESTED_RUNNER`,
   `GIBSON_COST_FALLBACK_REASON`, `GIBSON_COST_LEDGER`, and
   `GIBSON_COST_TELEMETRY_REQUIRED=1` into each lane's `loop.sh` so later
   iteration rows share the join key. `loop.sh` reads `issue:` / `pr:` only
   from **validated** loop-state after the runner (never unvalidated state).

**Flat-rate-first (docs/15):** grind lanes should list preferred flat-rate
runners first and metered/frontier providers only at escalation positions.
The driver does **not** inspect billing, plans, keys, or paid settings and
does **not** reorder the route. Pool labels default to `provider-<family>`
unless the operator declares `pool_map=provider:label` (plan shape is not a
permanent vendor property).

**Cost-ledger join (#141):** selection and iteration events share
`join_key`. `scripts/cost-ledger.sh summarize --merged-json PATH` attributes
an event as merged only when its own `pr`, or a same-`join_key` event's
`pr`, appears in the merged JSON. Merged PRs with no attributed events are
reported as lacking cost data — never as zero-cost success. Per-pool
merged/unmerged counts and per-merged-PR metrics support load balancing.
Token averages are null unless coverage is complete for every event in that
metric. Ambiguous join→PR maps and corrupt merged input fail closed.
Telemetry stays local and redacted (no secrets, no billing policy, no
provider-plan mutation).

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
- Reviewer / release identities nonempty and distinct; global `runner` is
  required/on-PATH **only** when a lane omits field 5. Builder separation is
  enforced against each **actual selected** runner after readiness (an unused
  global default is not role-checked and need not exist)
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
- Runner routing: issue **#141** (ordered routes, readiness, selection telemetry)
