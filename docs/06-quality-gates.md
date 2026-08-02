---
title: "06 · Must-pass quality checks"
parent: The Doctrine
nav_order: 6
---

# 06 — Quality Gates: Green Gate, Tiers, Lenses

> 🙂 **In plain English:** Before any change is saved, automatic checks must pass: does
> the code type-check, stay clean, pass tests, and build? Harder or riskier changes get
> stricter review. Nothing ships on hope alone.

## The green gate (computational, every commit)

Before **every** commit, in the worktree:

```bash
<generate step>        # e.g. npx prisma generate — stale clients break the NEXT agent
<typecheck>            # e.g. npx tsc --noEmit
<lint>                 # e.g. npm run lint
<unit tests>           # e.g. npx vitest run
<build>                # e.g. npm run build — catches what tsc can't (route types)
```

**Zero NEW failures vs. the branch point.** Record the baseline when you branch
(`scripts/gate-baseline.sh`); pre-existing failures from other branches aren't yours
— but they're also not an excuse to skip the gate. The build step is not optional:
frameworks catch classes of errors only at build (e.g. Next.js async route params
that plain `tsc` misses).

The same gate runs in CI (`ci/gibson-gate.yml`) so it holds regardless of which
runtime wrote the code. Local gate is a courtesy to your own iteration speed; CI
gate is the law.

## Test-integrity (count ratchet — issue #70)

The green gate used to treat "deleted the failing test" the same as "fixed the
failing test." That is the highest-leverage way a model optimizing for green
goes legitimately green while reducing coverage. The **test-integrity** sensor
closes that bypass:

| Signal | Gate result |
|---|---|
| Test **total** drops vs trusted baseline | hard-fail `test-integrity` with exact delta (`N → M`) |
| **skip + todo** rises vs trusted baseline | hard-fail `test-integrity` with exact delta |
| Total rises / skips fall | pass (no waiver needed) |
| Exact visible waiver covers the delta | pass, and the waiver is **surfaced** in gate output for the reviewer |

### Waiver (visible, exact, delta-consistent)

PR body or commit text is **inert data** — matched as text, never evaluated as
code. Accepted forms (optional leading `- `):

```
Test-integrity: removed <n> for <reason>
Test-integrity: skip +<n> for <reason>
Test-integrity: removed <n>, skip +<m> for <reason>
```

Fail closed (do **not** authorize):

- Hidden in HTML comments (`<!-- ... -->`)
- Near-matches (`test-integrity:`, `Test integrity:`, `removed three`, missing `for <reason>`)
- Wrong delta (`removed 2` when 3 tests disappeared)
- Malformed / zero-delta noise

### Trusted baseline (local now; CI in phase 2)

| Context | Authority |
|---|---|
| Local `gate.sh` | `.gibson-baseline.json` from `gate-baseline.sh` (gitignored, worktree-local) |
| CI `pull_request` | **Not wired in this bootstrap PR.** Phase 2 (after this helper is on main) adds an isolated grading job that re-derives metrics at the PR base SHA using the **immutable merge-base copy** of `scripts/test-integrity.mjs` |

**Phase-1 bootstrap (this change):** ships the reviewed helper, local
`gate.sh` / `gate-baseline.sh` integration, focused adversarial sensors, and
reviewer guidance. It deliberately **does not** change `ci/gibson-gate.yml`.
Wiring CI before main owns the helper would either (a) fall back to the PR-head
copy and self-grade, or (b) use a fixed temp path that untrusted head steps can
pre-poison. Do not treat the current CI template as protected for test-integrity.

**Phase 2 (follow-up, after merge):** from a base that already contains
`scripts/test-integrity.mjs`, wire an isolated CI job that copies the helper
from the merge-base worktree, re-runs the base suite, and compares with
`--trusted-source merge-base:<sha>`. That job must never load the PR-head helper
or follow attacker-controlled symlinks for the trusted binary.

### Baseline regeneration (journaled)

An intentional suite reduction is not a side effect of re-recording the baseline:

```bash
gate-baseline.sh --regenerate --reason "removed obsolete flaky suite after #70"
```

Requires a nonempty `--reason`. Appends one JSON line to
`.gibson/test-integrity-journal.jsonl` with timestamp, SHA, old/new metrics, and
reason. Overwriting a reduced baseline without the flag hard-fails.

### Summary contract (metric parsing)

Prefer an explicit machine line from the suite (vendor-blind):

```
GIBSON_TEST_METRICS total=42 skipped=2 todo=0
# or JSON:
GIBSON_TEST_METRICS {"total":42,"skipped":2,"todo":0}
```

Also recognized: Vitest `Tests … (N)` summaries, Jest `Tests: … total`,
node:test `# tests` / `# skip` / `# todo`, TAP `1..N` plans.

**No self-authorization:** explicit `GIBSON_TEST_METRICS` lines do **not** outrank
runner summaries. **Every** explicit KV/JSON line and **every** matching native
runner summary block (Vitest / Jest / node:test / TAP plan) is collected — never
first-match or last-match only. If any two sources disagree on total/skipped/todo
the parse fails closed; counters from different repeated native blocks are never
mixed into one fabricated metric. A test's stdout must never self-authorize head
metrics — e.g. honest `Tests 7 passed (7)` plus a fake `GIBSON_TEST_METRICS
total=10`, multi-explicit `total=10` then `total=7`, or conflicting repeated
native lines such as Jest `Tests: 10 … total` then `Tests: 7 … total`, node:test
`# tests 10` then `# tests 7`, TAP `1..10` then `1..7`, or Vitest honest-then-fake
/ fake-then-honest summary blocks.

**Fail closed:** unparseable, negative, non-integer, non-`Number.isSafeInteger`,
or skip+todo > total metrics never silently become zero — the sensor errors
instead. Values beyond `Number.MAX_SAFE_INTEGER` (e.g. `9007199254740993`) are
rejected so precision loss cannot mask a real delta.

**Waiver both axes:** claimed `removed` and `skip` must each equal
`max(actual_delta, 0)`. Overclaiming the unused axis, or a waiver with no
integrity reduction, fails closed.
**Known limit:** count-only comparison cannot detect "deleted A, added B of equal
count." Prefer named test identities in product harnesses that can do that
cheaply without ballooning scope; The Gibson's own gate stays count-based and
vendor-blind on purpose. Sensors live in `scripts/test-integrity.mjs` and
`scripts/tests/gate.test.sh`.

## Risk tiers

| Tier | Definition | Treatment |
|---|---|---|
| **A** | Routine: UI copy, isolated components, docs, tests | Solo review pass; standard gates |
| **B** | Elevated: shared modules, API routes, data reads, >150 lines or >6 files | Full-lens review; UX eval if visible |
| **C** | Money, auth, consent/PII, security boundaries, schema, incident alerting, prod data | Everything below + adversarial review + human merge gate + serialized where stateful |

Tier is assigned at decomposition and re-checked at review (diffs drift into Tier C;
they never drift out without a reviewer saying so).

## Review lenses

Six lenses; findings cite file:line and state the failure scenario, not just the smell:

1. **Correctness** — logic, edge cases, error paths, concurrency.
2. **Security** — authn/z, injection, IDOR, secrets, SSRF, unsafe deserialization.
3. **Consent / PII** — data collection lawful+minimal, consent flags respected,
   PII handling per checklist, retrieved/user content treated as untrusted in prompts.
4. **Money** — billing, pricing, idempotent retries, no float math on currency,
   webhooks verified.
5. **Performance** — N+1s, unbounded queries, payload size, cache correctness.
6. **Maintainability** — matches repo idiom, no dead code, right altitude, tested.

## Review depth (cost-shaped)

- **SOLO pass** (default): one reviewer, all lenses, one report. Cheap, fast.
- **FAN-OUT** (triggers: Tier C; touches schema/middleware/API auth surface; large
  diffs): parallel per-lens reviewers, then an adversarial verification pass — 1–2
  skeptics per finding prompted to *refute* it. Findings that survive go to the PR;
  refuted findings die quietly (plausible-but-wrong findings are the failure mode
  of inferential review).
- Cross-vendor by default: reviewer runtime ≠ builder runtime when available,
  reviewer runs **read-only**, verdict must end `VERDICT: APPROVE` or
  `VERDICT: REQUEST_CHANGES`.
- **Fail closed:** a missing or broken reviewer blocks the merge; it never silently
  skips. (Deliberate hardening of Mission Control's current lenient behavior.)

## Merge gate

`release` role verifies, in order:
1. `Closes #<issue>` present; issue contract checkboxes all verified.
2. CI green (gate + tests + security hard-fail layers).
3. Review verdict APPROVE; UX eval pass (when applicable).
4. DCO/`Signed-off-by` survives the squash.
5. Tier C / schema → **human approval recorded** (comment or approval from Mark).
6. Schema PRs: serialized, migration file present (schema-guard CI check).

## Drift sensors (continuous, outside change cycles)

Run on schedule, not per-PR: dependency CVE watch, Lighthouse budgets on production,
flaky-test detector, merge-cadence report, unresolved-`test.todo` trend, claim-row
staleness. Findings become issues, filed by `monitor`/`historian` — this is the
"quality right" complement to keeping quality left.

---
[← 05 · How agents avoid collisions](05-concurrency.md) · [Home](../index.md) · [07 · Testing the look and feel →](07-uiux-evaluation.md)
