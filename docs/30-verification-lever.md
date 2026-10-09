---
title: Verification lever
nav_order: 30
---

# 30 — The Verification Lever: Receipts, Not Claims

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** Before an agent says "done", it runs one command. That
> command checks the work and writes a small receipt tied to the exact commit. If
> there is no receipt for the commit being reported, the dashboard shows the status
> as **claim-only** instead of done.

**Status:** `scripts/gibson-verify.mjs` ships with this doc (#447). It is called from
[`playbooks/builder.md`](../playbooks/builder.md) step 4b. It is not a required CI
check, and a receipt never authorizes a merge: CI and `review-evidence` stay
authoritative. Mission Control does not yet have a `verification` column; `report`
uses the existing `milestone` event kind.

## The problem this names

Law 8 says never mark done what you didn't verify. In practice, most of the
recent fleet failures share one root cause: no machine-checkable proof at the
moment of the claim.

| Failure class | Where it shows up | What `gibson-verify` does |
|---|---|---|
| Ran fine, did nothing | L-008, L-081, #419 | `check` fails when the diff against the base is empty |
| Green over a red or skipped gate | L-070, truthful-status (#97) | `check` runs the gate, then `truthful-status.mjs` on its log; exit 0 with `NOT RUN` fails |
| Review evidence nobody can parse | #428, `second-opinion.sh` #290 | `verdict lint` classifies a verdict file the same way `parse_isolated_verdict` does |
| Setup found broken mid-run | unreadable keys, missing `gh` auth, missing tools | `doctor` checks tools, `gh auth`, the gate script, the receipts ignore rule, and which env vars are set (never their values) |
| Proof written as prose | PR bodies that say "tests pass" | `prove` writes `.gibson-receipts/<HEAD>.json`; the PR body quotes its summary |
| A dashboard that can't tell done from said-done | Mission Control `/api/ingest` | `report` posts `kind: "milestone"` with `detail.status` = `verified` or `claim-only` |

## How it works

```text
doctor ──► check ──► prove ──► report
           │          │          └─ verified only when a receipt exists for HEAD,
           │          │             its schema matches, and every step was ok
           │          └─ .gibson-receipts/<HEAD>.json (gitignored), plus the gate log
           └─ clean-tree → non-empty-diff → gate → truthful-status
```

- **Bound to a SHA.** The receipt names the head commit. Any new commit makes it
  stale, and `report` turns stale into claim-only.
- **Fail closed.** A step that was skipped because an earlier one failed is recorded
  as not ok. `verified` needs all four required steps present *and* ok, so an empty
  or partial step list cannot pass.
- **The gate is the repo's gate.** The default is `scripts/gate.sh` (the target
  repo's `.agents/gate.json`). In the Gibson repo itself, pass
  `--gate scripts/tests/run-all.sh`.
- **Dropped is not delivered.** Mission Control answers `{ok: true, demo: true}`
  when it has no database. `report` treats that as not delivered and exits 1.
- **Verdict parity is tested, not asserted.** `scripts/tests/gibson-verify.test.sh`
  extracts the five verdict functions from `second-opinion.sh` and runs them on the
  same fixtures as the node mirror. If either side changes alone, the suite goes red.

## What a feature map is here

pstack's verification skills pair a CLI with a *feature map*: how to reach each
user-facing feature and drive it from a script. For the Gibson the useful
equivalent is a **gate map** per adopted repo: which gate command proves which kind
of change (API route, UI surface, migration, doctrine). That belongs in each target
repo next to `.agents/gate.json` and is follow-up work, not part of this script.

## Keeping it honest (maintain routine)

1. When a failure slips past `check`, add the smallest check that would have caught
   it, plus a fixture in `gibson-verify.test.sh` that fails without it.
2. When `second-opinion.sh` changes its verdict grammar, the differential test fails
   until the mirror is updated in the same PR.
3. Re-read receipts that say `verified` on PRs that later failed CI. Each one is a
   missing check.

The first run of `prove` on its own PR already paid for itself: `truthful-status.mjs`
read run-all's self-test line "RED with aggregate metrics" as a red **gate** (the
pattern had no word boundary on `gate`), so the Gibson's own green gate could never
verify. The same PR fixes the pattern and pins both directions in
`laws-sensors.test.sh`.

## Measuring whether it helps

Before/after on one agent (for example Carmack): for two weeks before adoption,
count PRs and status reports that claimed done with no machine-checkable proof at
the reported head (claim-only rate). After adoption, the same count comes straight
from `report` events in Mission Control. The target is a falling claim-only rate
with no rise in red CI on PRs reported as verified.
