---
title: Architecture Fitness (report-only baseline)
nav_order: 26
---

# Architecture fitness — report-only baseline (#184 / parent #159)


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** This is a health report for Gibson's control-plane shape.
> It measures how big critical scripts are, what depends on what, whether important
> safety tests still exist, and how those numbers drift over time. In this first
> slice it **only reports** — it does not block merges when numbers go up. Later,
> after calibration and a separate review, it can grow into hard budgets.

## Why this exists

Gibson has strong behavioral sensors, but architecture can still degrade while
every local test stays green: safety-critical shell drivers grow without bound,
include graphs become opaque, policy identifiers multiply across files, and
mutation-receipt coverage for critical failure modes quietly disappears.

Parent issue **#159** asks for architecture fitness functions that make that
degradation visible and eventually require an explicit decision when it worsens.
Issue **#184** is the first reversible slice: **collect**, **baseline**, and
**compare in report-only mode**. It does **not** close #159.

## Human meaning (what you can trust)

| You see… | It means… | It does **not** mean… |
|---|---|---|
| File/line counts by class | How much of the tree is production vs tests vs docs vs config vs generated | That production code is “correct” |
| Driver size + proxy counts | Control scripts are growing or shrinking on crude structural proxies | True cyclomatic / semantic complexity |
| Dependency edges / unknowns | Static `source`/`.` includes we can prove; dynamics listed as unknown | A full runtime call graph |
| Policy ID duplicates | The same `G1` / `Law N` / `L-NNN` / `tier-*` string appears in multiple files | Canonical policy authority (that is **#164**) |
| Mutation-category present/unknown/missing | We found an explicit test assertion, only a heuristic lead, or no test evidence for each #159 category | That tests prove the failure mode is impossible |
| Comparison increase/decrease | Metrics moved vs the committed baseline | A merge block (not in this slice) |

## Technical contract

### Entry point

```bash
scripts/architecture-fitness.sh [--ref REF | --worktree]
                                [--baseline PATH] [--no-baseline]
                                [--format json|human]
                                [--emit-baseline PATH]
                                [--repo PATH]
```

- **Offline and deterministic.** No network, no model calls, no secrets, no
  current time in the report, no absolute user/temp paths in output.
- **Bash 3.2-compatible entrypoint.** Uses the repo's required **Node** runtime
  only for safe deterministic JSON processing and tree analysis.
- **Schema:** `gibson.architecture-fitness-report.v1` (JSON, byte-stable for a
  frozen tree). Baseline artifacts use
  `gibson.architecture-fitness-baseline.v1`.
- **Disposition:** always `report-only` in this slice. Observed regressions
  remain **exit 0**. Malformed baseline/schema, unresolved refs, dirty
  exact-SHA worktree capture, incomplete required evidence, or collector
  failure exit **nonzero** (fail closed).

### Exact source binding

- `--ref REF` scans the Git **object database** commit tree for that ref. Dirty
  worktree state does not affect the result. Unresolved refs fail closed.
- `--worktree` scans tracked files on disk. A **dirty** worktree is refused, and
  even a clean worktree is explicitly labeled `exact: false`: clean Git status
  alone cannot prove disk bytes equal `HEAD` when filters, index flags, or a
  concurrent writer may exist. Baseline capture therefore requires `--ref`.
- Default (no flag) is the `HEAD` commit tree (exact, object database).

### Classification

Tracked paths are classified **separately** (first match wins):

1. **generated** — e.g. `dist/`, `build/`, lockfiles, `*.min.js`
2. **tests** — `tests/`, `*.test.*`, fixtures
3. **documentation** — `docs/`, `playbooks/`, `memory/`, `*.md`
4. **config_workflows** — `.github/`, `ci/`, `config/`, `.agents/`, most YAML/JSON config
5. **production** — harness/product scripts and source
6. **other** — remainder

Symlinks are not followed. Reads stay inside the selected Git tree.

### Safety-critical drivers (explicit map)

| Responsibility id | Path | Notes |
|---|---|---|
| `claim` | `scripts/claim.sh` | |
| `release-claim` | `scripts/release-claim.sh` | |
| `claim-reaper` | `scripts/claim-reaper.sh` | |
| `loop-fleet` | `scripts/loop-fleet.sh` | |
| `loop-handoff` | `scripts/loop.sh` | Handoff gate lives in `loop.sh` |
| `gate` | `scripts/gate.sh` | |
| `gate-baseline` | `scripts/gate-baseline.sh` | |
| `release-preflight` | `scripts/release-preflight.sh` | |

For each driver the report records **lines**, **branch_proxy_count**, and
**decision_proxy_count**. These are **documented proxies** (control-flow and
decision-token line hits). They are **not** semantic complexity and must never
be labeled as such.

### Shell dependencies

Only **statically discoverable executable production** `.` / `source` edges
are emitted; test dependencies remain part of the separate test classification.
Line-start and compound-command includes are recognized. Examples inside
heredocs are ignored. Dynamic or unresolvable includes
(command substitution, unknown `$VAR` roots, absolutes, or missing targets)
appear under **unknowns**. Edges are **never guessed**.

### Policy identifiers (diagnostics only)

Stable-looking identifiers (`G1`–`G16`, `Law N`, `L-NNN`, `tier-a|b|c`) are
counted with multi-file duplicates listed for diagnosis.

> **Canonical policy-drift enforcement is deferred to issue #164.** This slice
> does not claim authority over gates, laws, or tiers.

### Mutation-receipt categories (#159)

Seven categories, each with explicit **present** / **unknown** / **missing**
and stable matching locations:

1. `review_bypass`
2. `stale_head_acceptance`
3. `halt_bypass`
4. `corrupt_state_progress`
5. `claim_ambiguity`
6. `false_delivery_success`
7. `incomplete_cleanup`

- **present** requires an explicit `mutation-category:<id>` marker in an
  executable assertion in a test file;
- **unknown** means a test contains a heuristic phrase but no explicit tag;
- **missing** means no matching test evidence was found.

Documentation, production diagnostics, and the collector's own pattern text do
not count as receipt evidence. The collector sensor's own fixture tags are also
excluded, so adding this dashboard cannot improve its coverage score. Even an
explicit assertion only records the intended coverage category: **test quantity
is insufficient proof of correctness.**

### Committed baseline

`config/architecture-fitness-baseline.v1.json` is generated from exact main
commit:

- **source commit:** `01bafdeecadb28ecee7415cd1b2ef57c58b7c4bc`
- **source tree:** `41fcceeb0d8e8d6d46d426e595e1190cad8d2599`

The baseline records **collector version/digest separately**, and each report
fingerprints the exact baseline bytes it loaded. The managed default must
byte-match the copy committed at `HEAD` and its collector digest must match the
running collector; an explicitly supplied `--baseline` is instead labeled
`explicit_file` so historical or external comparisons stay possible without
being represented as the managed committed baseline. It does **not**
claim the collector existed at that source commit; provenance is truthful and
independent of the scanned tree.

Compare with:

```bash
scripts/architecture-fitness.sh --ref HEAD \
  --baseline config/architecture-fitness-baseline.v1.json \
  --format human
```

## Calibration and report-only status

This slice is **calibration / observability**:

- Regressions (increases vs baseline) are **visible** in the comparison section.
- They **do not fail CI** in this first report-only slice.
- Fail-closed conditions are limited to **broken evidence** (bad schema, bad
  baseline, unresolved source, dirty exact capture, incomplete required fields,
  collector failure) — not metric movement.

## Proxy limitations (read before acting on numbers)

- Proxies over-count comments/strings that look like control flow or verdicts.
- Line counts treat text files only; binary blobs contribute zero lines.
- Dependency edges ignore runtime `bash -c`, eval, and indirect dispatch.
- Identifier greps collide with prose and examples; duplicates are a **hint**,
  not a policy verdict (#164).
- Mutation-category presence means “an explicit category assertion exists in a
  test,” not “a mutant was killed in CI today.” Heuristic-only test text stays
  `unknown`; production and documentation text do not establish coverage.

## Dependency on #164

Policy identifier diagnostics in this report are deliberately **non-authoritative**.
Issue **#164** owns the versioned policy manifest, generated views, and CI that
fails on real contract drift. Do not treat architecture-fitness duplicate lists
as a substitute for that work.

## Later promotion path (hard-fail budgets)

Promotion from report-only to hard-fail is a **separate, reviewed change** after
calibration against the exact baseline. Expected shape (not implemented here):

1. Freeze or ratify budgets **per responsibility / category**, not a single repo
   LOC cap.
2. Fail only on **unapproved** increases vs baseline.
3. Require an **ADR / waiver** with owner, reason, expiry/revisit date, and
   deletion or refactor plan for any budget raise.
4. Keep generated code and tests accounted **separately** from production.
5. Re-review exit policy so broken evidence stays fail-closed and metric
   regressions become opt-in hard-fail with expiring waivers.

Until that promotion lands, treat this tool as a **truthful dashboard**, not a
merge gate for architecture size.

## Tests

```bash
bash -n scripts/architecture-fitness.sh
shellcheck -S warning scripts/architecture-fitness.sh
bash scripts/tests/architecture-fitness.test.sh
```

Focused tests use temporary fixture repositories and cover byte stability,
dirty exact refusal, unresolved refs, malformed/incomplete baselines, category
separation, dynamic dependency unknowns, duplicate IDs, missing mutation
categories, heuristic-only mutation uncertainty, symlink-safe baseline I/O,
large piped/redirected report completeness, deep baseline contradictions, a
neutralized dynamic-detector mutant, report-only regression exit 0, and
absolute-path leakage.

## Non-goals (this slice)

- No hard-fail architecture budgets or expiring waivers.
- No canonical policy manifest (#164).
- No model/harness benchmark runner or provider selection.
- No changes to G1–G16, risk tiers, review/merge/deploy authority.
- Completing #184 does **not** close #159.
