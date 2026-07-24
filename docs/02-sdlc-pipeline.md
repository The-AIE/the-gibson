# 02 — The SDLC Pipeline

Ten stages. Every stage has an **entry artifact**, an **exit artifact**, and a
**gate**. Gates are sensors — deterministic where possible, inferential where
necessary. No stage may be skipped on confidence; a stage may be skipped only when
its entry condition genuinely doesn't apply (e.g. UX eval on a pure API change), and
the skip is recorded in the PR.

```
0 PLAN → 1 DECOMPOSE → 2 BUILD → 3 TEST → 4 REVIEW → 5 UX-EVAL → 6 SECURITY
                                                                      │
                    9 RETRO ← 8 DEPLOY+VERIFY ← 7 MERGE ←─────────────┘
```

## Stage 0 — Plan

**Entry:** a topic, feature request, or product brief from Mark (or a standing goal).
**Role:** `planner`.
**Work:** expand the brief into a spec: problem, users, scope/non-scope, architecture
sketch, risks, and — for anything with a UI — a **design language** (typography,
color, spacing, aesthetic intent) authored with the frontend-design skill, so the
UX evaluator later has something objective to grade against. Constrain to
*deliverables*, not implementation detail: let builders find the path.
**Exit artifact:** `PLAN.md` (or a GitHub Discussion) with numbered, testable
acceptance criteria per deliverable.
**Gate:** human — Mark approves the plan. This is the cheapest place to be wrong.

## Stage 1 — Decompose

**Entry:** an approved plan. **Role:** `decomposer`.
**Work:** turn the plan into GitHub issues — the live work queue. Each issue is one
mergeable unit with a sprint contract. Dedup against open issues and shipped code
first. Order by dependency; label by area/priority/risk-tier.
**Exit artifact:** labeled, dependency-ordered issues. **Gate:** decomposition
lint (`scripts/` — every issue has contract, files-touched estimate, tier label);
spot-check by a second agent for scope overlap.
Full protocol: `docs/04-plan-to-issues.md`.

## Stage 2 — Build

**Entry:** an unclaimed, unblocked issue. **Role:** `builder`.
**Work:** claim (row + label) → worktree → implement per target-repo conventions →
keep the unit small. Read the target's `AGENTS.md` and pinned-framework notes first
(e.g. ConferenceOS's "this is NOT the Next.js you know").
**Exit artifact:** a branch passing the green gate, and a PR.
**Gate:** the **green gate** — generate → typecheck → lint → unit tests → build,
zero new failures vs. recorded branch-point baseline. Concurrency rules:
`docs/05-concurrency.md`.

## Stage 3 — Test

**Entry:** a PR claiming contract criteria. **Role:** `test-engineer` (may be the
builder for small units; must be a different agent for Tier C).
**Work:** every contract criterion gets an executable check — unit, integration, or
E2E. Every bug fixed gets a regression test in the same PR. Spec lines start as
`test.todo`; the todo-count must go down in feature PRs. Flaky tests are quarantined
within 24h and filed as harness lessons.
**Exit artifact:** tests in the PR; contract criteria mapped to test IDs.
**Gate:** CI test job green; coverage of contract criteria complete (not % coverage —
*criterion* coverage).

## Stage 4 — Review

**Entry:** a green PR. **Role:** `reviewer` — a different agent, cross-vendor when
available.
**Work:** multi-lens review — Correctness, Security, Consent/PII, Money, Performance,
Maintainability. Tiered depth: solo pass for routine diffs; parallel per-lens fan-out
with adversarial "try to refute this" verification for **Tier C** (money / auth /
consent / PII / security / schema / >150 lines or >6 files).
**Exit artifact:** verdict — `APPROVE` or `REQUEST_CHANGES` with specific findings.
**Gate:** verdict recorded on the PR. A missing/broken reviewer **blocks** (fail
closed) — it does not silently skip. Details: `docs/06-quality-gates.md`.

## Stage 5 — UX Evaluation

**Entry:** a PR with user-visible surface + its **Vercel preview deployment**.
**Role:** `ux-evaluator` — never the builder.
**Work:** Playwright scripts drive the *live preview URL*: click through the
contract's user flows as a user, screenshot each step, run axe-core and visual
regression, then grade — Design quality, Originality, Craft, Functionality — against
the plan's design language, plus Nielsen heuristics. File failures as specific,
reproducible bugs ("Tool only places tiles at drag start/end instead of filling the
region"), not scores alone.
**Exit artifact:** eval report + screenshots attached to the PR.
**Gate:** all contract flows pass; axe critical/serious = 0; visual diff approved;
grades ≥ threshold. Details: `docs/07-uiux-evaluation.md`.

## Stage 6 — Security

**Entry:** every PR (light layers); Tier C and release (full layers).
**Role:** `security` + CI.
**Work & gate:** the eight-layer system — secrets, SAST, supply chain, authz matrix,
DAST vs. preview deployment, adversarial inferential review, LLM-feature injection
review, runtime posture. Hard-fail layers block merge; report-only layers file
issues. Details: `docs/08-security.md`.

## Stage 7 — Merge

**Entry:** PR with review APPROVE + all gates green. **Role:** `release`.
**Work:** verify `Closes #issue`, DCO/signoff intact through squash, CI green,
gates green. **Human gate** applies to Tier C and schema PRs. Schema merges are
serialized — one in flight at a time.
**Exit artifact:** merged main.

## Stage 8 — Deploy + Verify

**Entry:** merged main. **Role:** `release` + `monitor`.
**Work:** Vercel deploy; verify the deployment matches the expected commit and
reaches READY; run post-deploy smoke (Playwright happy-path against production);
watch the window. Mechanical failures auto-remediated; judgment failures escalate.
**Exit artifact:** verified deployment; claim released; worktree/branch cleaned.
**Gate:** smoke green. Doctrine incl. schema safety: `docs/12-vercel.md`.

## Stage 9 — Retro (the ratchet)

**Entry:** continuous + weekly. **Role:** `historian`.
**Work:** sweep merged PRs, CI failures, review verdicts, eval reports, task
cost/outcomes. Anything that failed twice, surprised an agent, or cost 3× estimate
becomes a lesson — and lessons become harness PRs (new gate, new doc, new lint rule).
**Exit artifact:** `memory/LESSONS.md` entries + harness improvement PRs/issues.
Details: `docs/09-memory-and-self-improvement.md`.

## Pipeline variants

- **Fleet mode:** stages run as separate dispatched agents (Mission Control queue),
  many issues in flight, max 3 mutating lanes per repo.
- **Solo loop:** one agent (e.g. Grok, continuously) cycles all stages with file
  handoffs between role hats: `docs/11-solo-loop.md`.
- **Hotfix:** compressed path (build → test → review → merge → deploy) with the
  same gates at higher urgency; triage doctrine per target repo (e.g. ConferenceOS
  `mercury-fixes`).
