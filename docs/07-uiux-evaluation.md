---
title: "07 · Testing the look and feel"
parent: The Doctrine
nav_order: 7
---

# 07 — UI/UX Evaluation: Playwright vs. Live Deployments

> 🙂 **In plain English:** Looking at code is not enough for screens people use. An agent
> opens the real preview website, clicks through like a customer, and grades what it
> actually sees and experiences — not what the builder claimed it would feel like.

**Rule zero: evaluate the deployment, not the diff.** The ux-evaluator drives the
PR's **Vercel preview URL** with Playwright — clicking, typing, scrolling like a
user — and grades what it actually experiences. The builder's description of the UI
is inadmissible evidence. (Anthropic's evaluator "clicked through running
applications like a user... taking screenshots and studying implementations before
scoring.")

## Inputs

1. **Preview URL** — every PR gets one from Vercel automatically; resolve it from
   the GitHub deployment event or `vercel inspect`.
2. **The sprint contract** — each user-flow criterion from the issue.
3. **The design language** — authored at plan time with the frontend-design skill
   (typography, palette, spacing, aesthetic intent). Grading taste against a
   *declared* aesthetic turns a subjective judgment into a conformance check.

## The evaluation script

Per PR with user-visible surface:

1. **Contract flows (functional).** One Playwright script per flow criterion, run
   against the preview URL. Each step screenshots. Failures are filed as specific,
   reproducible bugs — "FAIL: tool only places tiles at drag start/end instead of
   filling the region" — never bare scores.
2. **Accessibility.** axe-core on every reached page state: **critical/serious
   violations = hard fail.** Keyboard-only traversal of each flow.
3. **Visual regression.** Playwright `toHaveScreenshot` against committed baselines
   for stable surfaces; diffs above threshold require explicit approval in the PR
   (an intended redesign updates the baseline in the same PR).
4. **Responsive + theme.** Re-run key flows at mobile/tablet/desktop and light/dark.
5. **Performance budget.** Lighthouse against the preview: perf ≥ 0.85, a11y ≥ 0.95,
   SEO ≥ 0.95, LCP ≤ 2.5s, CLS ≤ 0.1 (calibrated multi-run to kill flake).
6. **Grading.** Four criteria (Anthropic), scored 1–10 against the design language:
   - **Design quality** — coherent aesthetic identity
   - **Originality** — custom decisions vs. generic AI-slop patterns
   - **Craft** — typography, spacing, contrast, states, motion
   - **Functionality** — a user completes the contract tasks
   Plus a Nielsen-heuristics sweep for interaction-design findings.
   Threshold: any criterion < 7 → REQUEST_CHANGES with specific findings.

## Verdict

`PASS` or `REQUEST_CHANGES`, posted on the PR with: score table, screenshot gallery
(attached or linked), bug filings, and — on pass — the statement that every contract
flow was **driven, not assumed**.

## Iteration protocol

The builder fixes findings and pushes; the evaluator re-runs *only* failed flows plus
a smoke of passed ones (new preview deployment per push makes this cheap). After
each round the builder makes a strategic call: refine the current direction if scores
trend up, or pivot the approach if they don't (Anthropic's refine-or-pivot finding —
don't sand a design that's structurally wrong).

## Post-deploy smoke

After production deploy, the same contract-flow scripts run once against production
(non-destructive flows only, seeded test data where writes are needed). This is the
deploy verification's UX half (doc 12).

## Where scripts live

- Target repo: `tests/e2e/flows/` — contract-flow scripts, named `issue-<N>-<flow>.spec.ts`,
  written by the test-engineer/ux-evaluator, kept after merge as the regression suite.
- The Gibson: `templates/target-repo/` carries the Playwright config template with
  preview-URL wiring (`BASE_URL` from the deployment event) so any target repo gets
  this for free at adoption.

## Worked example

Complete Playwright flow spec + graded eval report:  
[examples/07-ux-eval-sample.md](examples/07-ux-eval-sample.md)  
Playbook: [playbooks/ux-evaluator.md](../playbooks/ux-evaluator.md) · preview helper:
`scripts/preview-url.sh`.

## Known gap this closes

ConferenceOS had axe in CI and a manually-invoked UI review skill, but **no automated
visual/UX regression and no deployment-driving evaluator**. This doc + the templates
make UX evaluation a pipeline stage, not a favor.

---
[← 06 · Must-pass quality checks](06-quality-gates.md) · [Home](../index.md) · [08 · The security system →](08-security.md)
