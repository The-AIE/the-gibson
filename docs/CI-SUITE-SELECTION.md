# CI suite selection: shadow pilot

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

The selector gathers evidence for a future decision about selective testing. It does **not** reduce CI execution. The existing `sensors` job still runs its full suite once, with the same preamble checks, no-quarantine setting, policy-view drift check and 900-second wall budget. The existing docs-only authority branch is unchanged in coverage and produces explicitly partial, not-comparable evidence.

The runner can optionally export its semantic results with `--results-json FILE --results-base BASE_SHA --results-head PR_HEAD_SHA`. Without reporting flags or environment opt-in its existing output and checks remain unchanged. Export happens after the real verdict is bound and before capture cleanup and the terminal `GIBSON_TEST_METRICS` output. Shell-construction errors, invalid Bash 3.2 benchmark receipts and per-suite metric errors remain failures even when a process exits zero. The report also records global failures and actual elapsed times. It does not reparse human logs to decide whether tests passed.

`node scripts/ci-suite-selection.mjs compare --report FILE --base BASE_SHA --head PR_HEAD_SHA --output SHADOW_FILE` compares that single run with a hypothetical selection. Use full commit SHAs. `--repo DIR` supports isolated fixture checkouts; `--summary FILE` appends a readable summary. CI also supplies the actual sensor-step and policy-drift outcomes. Reports and summaries are advisory; their errors cannot skip or replace required checks. CI preserves both result files in the advisory step log and summary even when the required gate is red.

## Conservative mapping

An exact modified **existing** `scripts/tests/*.test.sh` path can select its exact suite ID. The policy always adds these suites:

- `contract-authority.test.sh`
- `policy-manifest.test.sh`
- `laws-sensors.test.sh`
- `convention-sensors.test.sh`
- `architecture-fitness.test.sh`
- `ci-suite-selection.test.sh`

The planner never uses `--only`, whose existing matching behavior is substring based. Selected and omitted IDs must be disjoint and cover the complete actual inventory.

All production paths, helpers, fixtures, workflow/runner/selector configuration, dependencies, unknown paths, additions (including new tests), deletions and renames select the full inventory. `digest.sh`, `decision-ledger.sh` and `queue-order.mjs` have no narrowed production mappings: their complete consumer relationships have not been established. Missing or invalid base, diff or inventory evidence also falls back to full. Git diff paths are read with NUL separators, and oversized/unreadable/non-UTF-8 evidence fails closed rather than being truncated into a partial selection.

## Reading the evidence

`gibson.ci-full-run/v1` records base, PR head, executed checkout and tree identities; discovered and executed inventories; one semantic receipt per executed suite; and the full runner verdict and global failures. GitHub normally executes a synthetic merge commit, so its SHA is distinct from the PR head. A dirty checkout is not exact-head comparison evidence. Comparison checks the current working tree as well as the recorded state, so a later edit at unchanged HEAD invalidates the evidence.

`gibson.ci-suite-selection/v1` adds mapping reasons, selected/omitted partitions, completeness errors, selected/omitted failures and a hypothetical false-green indicator. A complete failed run is shown as `COMPLETE_FAIL`; it is never described as a passing selection. Missing, duplicated, malformed, truncated, stale or inconsistent receipts yield `UNKNOWN`. Cancelled or incomplete runs cannot produce a safe comparison. Intentional docs-only coverage yields `NOT_COMPARABLE_PARTIAL` without inventing unexecuted results or changing the existing product check.

An omitted failure with no selected or global failure exposes a hypothetical false green only when the retained policy-view check completed successfully. Skipped, missing or failed retained global checks leave that indicator unknown while preserving the observed omitted failures. This includes the existing workflow's policy step being skipped after a full-suite failure. Even `COMPLETE_PASS` describes only the observed full run and the hypothetical partition; it is not authorization to omit suites on later changes.

`wall_seconds` is the actual runner wall time. `omitted_suite_seconds` sums the measured durations of hypothetically omitted suites. Suites overlap in time, and preamble work remains, so **suite-seconds are not wall-time savings**. This pilot claims no speed improvement yet.

## Verification and promotion

The discovered `ci-suite-selection.test.sh` suite exercises exact matching, conservative fallbacks, unusual filenames, binding/completeness failures, selected/omitted/global failures, partial runs and real canonical/symlink CLI invocation. Its bounded fixture runs the production capture/classification/report section and verifies exit-zero diagnostic and metric failures, terminal metrics, and exactly one execution per suite. It adds no production preamble-skipping switch.

Repository suite runs must use the fleet's isolated gate procedure. The new self-contained test confines its Git operations and generated files to temporary fixtures. Full-gate evidence, independent exact-head review and hosted CI remain required. Expanding mappings or changing actual enforcement is separate reviewed work; measured shadow data alone does not establish production dependency coverage.

CI preserves each complete JSON report between `GIBSON_CI_SHADOW_JSON_BEGIN` / `GIBSON_CI_SHADOW_JSON_END` markers in the advisory step log and in expandable step-summary sections. Download the job log or open its summary to retrieve evidence. Each report is limited to 128 KiB for persistence; missing, empty, or larger reports produce explicit UNKNOWN/incomplete evidence and are never silently truncated. The advisory step keeps its comparison exit status after publishing any available evidence.

The unchanged CI runner commands opt into reporting through `GIBSON_SUITE_REPORT_PATH`, `GIBSON_SUITE_REPORT_BASE`, and `GIBSON_SUITE_REPORT_HEAD`. Local `--results-*` arguments override those defaults; with neither environment opt-in nor flags the runner remains unchanged.

The runner consumes and unsets its report environment inputs before spawning children, so nested runner invocations cannot overwrite the parent report. The comparator also bounds its final serialized output before writing a summary: an oversized comparison becomes a small authoritative `UNKNOWN` record with `evidence_omitted_due_to_size: true`, without partial paths, selections, or receipts.
