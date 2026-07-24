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
