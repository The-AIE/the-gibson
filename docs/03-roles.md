---
title: "03 · The crew's nine jobs"
parent: The Doctrine
nav_order: 3
---

# 03 — The Development Team (Roles)

> 🙂 **In plain English:** The crew has nine jobs — planner, builder, tester, reviewer,
> and more. A job is a list of what you may and may not do, not a brand of AI. Any AI
> can wear any hat if it follows the contract for that job.

Nine roles. A role is a **contract** — inputs, outputs, forbidden actions — not a
vendor or a model. Any runtime can wear any hat; Mission Control routes by task
class (deep refactors → claude-code, terminal-heavy fan-out → codex, research and
second opinions → grok, messaging/ops and recurring jobs → hermes), but the contract
is identical wherever it runs. Dispatch prompts live in `playbooks/`.

Separation rules (non-negotiable):
- `builder` ≠ `reviewer` ≠ `ux-evaluator` on the same unit of work.
- Cross-vendor review is the default when more than one runtime is available.
- In solo-loop mode one agent wears all hats *sequentially* with file handoffs;
  the separation rule is then enforced by fresh context per hat (see doc 11).

---

## planner
**In:** a brief from Mark or a standing goal. **Out:** `PLAN.md` — problem, scope /
non-scope, architecture sketch, risks, deliverables with numbered testable
acceptance criteria, and (for UI work) a design language authored with the
frontend-design skill.
**Forbidden:** writing implementation code; specifying granular implementation
detail (constrain to deliverables).
**Gate out:** Mark approves.

## decomposer
**In:** approved plan. **Out:** deduplicated, dependency-ordered GitHub issues, each
one mergeable unit with a sprint contract (doc 04).
**Forbidden:** creating issues that overlap live claims; issues without contracts.

## builder
**In:** one unclaimed, unblocked issue. **Out:** a green-gate-passing branch + PR
referencing `Closes #N`, contract criteria addressed.
**Forbidden:** editing outside the claimed scope; editing the canonical checkout;
touching hot files without the extra rules (doc 05); merging anything; reviewing
own work; adding dependencies casually (prefer REST/fetch over SDKs — hot-file rule).

## test-engineer
**In:** a PR + its contract. **Out:** executable checks for every criterion; regression
test for every bug fixed; `test.todo` count reduced.
**Forbidden:** weakening or deleting failing tests to pass the gate; testing only
the happy path on Tier C (adversarial cases required).

## reviewer
**In:** a green PR. **Out:** `APPROVE` / `REQUEST_CHANGES` with file:line findings
across the six lenses (doc 06); adversarial pass on Tier C.
**Forbidden:** merging; reviewing own generation; rubber-stamping ("LGTM" without
findings or explicit per-lens clearance is a contract violation).

## ux-evaluator
**In:** a PR's Vercel preview URL + the plan's design language + contract flows.
**Out:** a graded eval report (doc 07) with screenshots and reproducible bug filings.
**Forbidden:** evaluating from the diff or the builder's description — only the
running deployment counts; passing a flow it did not actually drive.

## security
**In:** every PR (light), Tier C / release (full). **Out:** layer results (doc 08),
findings as issues with severity, exploit-path reasoning on anything it flags.
**Forbidden:** report-only softening of a hard-fail layer; testing against prod
with destructive payloads (DAST runs against previews/staging).

## release
**In:** an approved, all-gates-green PR. **Out:** merge, verified deploy, smoke pass,
cleanup (worktree, branch, claim, issue).
**Forbidden:** merging Tier C or schema PRs without the human gate; more than one
schema merge in flight; force-pushing main.

## historian
**In:** the exhaust of everything above — CI history, verdicts, eval reports, costs,
incidents. **Out:** `memory/LESSONS.md` entries, `memory/DECISIONS.md` records,
harness-improvement issues and PRs (doc 09).
**Forbidden:** letting a twice-failure pass without a lesson; editing lessons others
wrote (append, don't rewrite history).

---

## Handoff artifacts

Roles communicate through **files and GitHub objects, never chat memory** (Anthropic's
structured-handoff finding — this is also what makes context resets and vendor swaps
free):

| From → To | Artifact |
|---|---|
| planner → decomposer | `PLAN.md` |
| decomposer → builder | GitHub issue + sprint contract |
| builder → test/review/ux | PR + branch + preview deployment |
| reviewer → builder | `REQUEST_CHANGES` findings on the PR |
| ux-evaluator → builder | eval report + bug filings |
| security → builder/release | layer results on the PR + issues |
| release → historian | merge/deploy record |
| historian → everyone | `memory/` + harness PRs |

---
[← 02 · The assembly line](02-sdlc-pipeline.md) · [Home](../index.md) · [04 · From plan to to-do list →](04-plan-to-issues.md)
