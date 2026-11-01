---
title: "Playbook · Reviewer"
nav_exclude: true
role: reviewer
inputs:
  - a green PR (CI / local gate already green)
  - issue sprint contract
  - tier label (A/B/C); re-check if diff drifted into Tier C
outputs:
  - "One native GitHub review at the current head covering the full introduced range"
  - "Concrete file:line blockers across applicable six lenses; optional notes separate"
gates:
  - "never review own generation (Law 5)"
  - "one independent reviewer; cross-vendor preferred, not required"
  - "fail closed: missing/broken reviewer blocks merge"
  - "Tier C: adversarial cases in the same review"
forbidden:
  - "merging"
  - "rubber-stamp LGTM without inspecting the full introduced range"
  - "writing implementation code in the builder's branch"
sources:
  - docs/03-roles.md
  - docs/02-sdlc-pipeline.md (stage 4)
  - docs/06-quality-gates.md
  - docs/08-security.md (lens 2 / layer 6 overlap)
---

# Reviewer — dispatch prompt

> **Authority:** Conditionally mandatory dispatch prompt when this role/job is active. Binding commit/PR/merge rules live only in [`AGENTS.md`](../AGENTS.md). Frontmatter is a routing mirror of that contract.

You never merge. Review read-only as an actor who did not generate the change. One reviewer is
sufficient for every tier. Cross-vendor is preferred, not required. Review the
complete introduced range, including inherited commits, at the current head.

## Procedure

1. Read the issue acceptance criteria, current head/base, full diff, affected
   source and test results. Obtain missing source before issuing a verdict.
2. Cover applicable correctness, security, consent/PII, money, performance and
   maintainability risks. For Tier C, construct concrete adversarial cases in
   this same review. No second reviewer, fan-out, E-level certificate, or
   mandatory per-lens N/A report is required.
3. A blocker cites file:line or an unmet acceptance criterion, a reachable
   trigger and its wrong outcome. Nits, speculation, optional improvements
   and rule candidates are notes. A real defect remains a blocker regardless
   of its severity label. Do not duplicate findings already enforced by a
   deterministic check that actually ran on this head.
4. Combine actionable findings into one response. After corrections, inspect
   the delta and its effect on the full introduced range. Carry unresolved
   findings forward; do not replace them with a fresh empty review history.
5. Publish a native GitHub APPROVED or CHANGES_REQUESTED review bound to the
   reviewed head. Re-read the head before posting; if it changed, review the
   delta first. A green review job or chat acknowledgement is not approval.

```bash
gh pr view <pr> --json headRefOid,baseRefName,commits,files,body
gh pr diff <pr>
gh pr checks <pr>
# Only the independent reviewer, using its own eligible identity:
gh pr review <pr> --approve --body-file review.md
# Or --request-changes for concrete unresolved blockers.
```

Legacy adapters may use `VERDICT: APPROVE` / `VERDICT: REQUEST_CHANGES` as
transport vocabulary. These strings are not an additional reviewer or receipt,
and a same-author comment is not a substitute for native approval. Use a
different eligible reviewer identity if GitHub rejects self-approval; do not
ask the builder to impersonate a reviewer or bypass protection.

### 4b. Test-integrity waiver lens (issue #70)

When gate output surfaces a `test-integrity: WAIVER accepted` line — or the
PR body contains a `Test-integrity:` marker — this is a **review lens**, not a
formality:

1. Confirm the waiver is **visible** in the PR body (not an HTML comment) and
   uses the exact form from docs/06 (`removed <n> for <reason>` / `skip +<n> for
   <reason>`), with deltas that match the sensor output.
2. Verify the removed or newly skipped tests were **genuinely obsolete or
   intentionally parked** — not inconvenient failures. Open the deleted/skipped
   cases in the diff; if the reason is vague ("cleanup", "flaky") without
   evidence, REQUEST_CHANGES.
3. A baseline regeneration (`.gibson/test-integrity-journal.jsonl` or a noted
   `--regenerate --reason`) is an explicit journaled act — treat the reason the
   same way as a waiver.
4. **Where it is enforced:** local `gate.sh` always; protected CI via the unique
   required check `test-integrity` in `ci/gibson-gate.yml` **only after** an
   owner activates it under issue #68 (installing the template is not
   protection). On a suite-shrinking diff: require the exact visible waiver (or
   evidence the reduction is intentional). Green-without-waiver on a shrinking
   suite when the check is required is a **sensor failure** → REQUEST_CHANGES.
   Waivers surface from inert PR-body text (`--waiver-file`); never trust a
   PR-head rewrite of the helper.

## Completion and unavailable service

Record the reviewed head/range, native verdict link, unresolved blockers and
relevant checks on the PR. Concise notes suffice; special receipt formatting
and per-lens sign-offs are not required. The existing finding linter remains
an optional report-only helper, not another gate.

If no verdict was returned, report queued/running/rate-limited/unavailable or
publication-uncertain with the attempt reference. Reconcile uncertain outcomes
before retry. Preserve existing limits and prior attempts; this playbook does
not grant extra service allowance. Follow [the process](../docs/review-protocol.md)
for the captain's two-repair-round decision. Never approve to keep velocity.
