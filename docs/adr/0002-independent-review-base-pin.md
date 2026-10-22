---
title: "ADR-0002: The reviewer keeps pinning the base sha, and survives a base-only move when the diff is provably the same"
nav_exclude: true
---

# ADR-0002 · 2026-10-22 · The reviewer keeps pinning the base sha, and survives a base-only move when the diff is provably the same

**Status:** Proposed (PR open; nothing applied to the Mini).
**Owner decision required:** the change edits the live controller `neuro-independent-review.py` on the Mac Mini. The exact diff is [`independent-review-base-pin/neuro-independent-review.base-pin.patch`](independent-review-base-pin/neuro-independent-review.base-pin.patch) (102 lines, applies to the controller whose sha256 is `1f5467c94f2574f3c34408429036c98e3cf11e2349eb619e65c6794081b7bc4e`). Mark applies it, or says "apply" with the diff in front of him.
**Decision record:** `memory/DECISIONS.md` D-019 points here. Follows up the first follow-up in [ADR-0001](0001-independent-review-ready-probe.md).

## Context

Before a paid Grok+Codex review starts, `_snapshot()` pins the pull request: head sha, **base sha**, base ref, open/draft state, head repo, the commit shas, the reviewed paths, and the PR and linked-issue labels. After the vendors return, `_recheck()` rebuilds the same snapshot and raises `SkipPull("snapshot-changed")` if any field differs. The review is discarded and the attempt is not counted; the next tick (or the ADR-0001 probe) starts it again from zero.

The diff the reviewers read comes from GitHub's compare endpoint, `base...head`, which is a **three-dot** compare: it diffs the head against the merge base of base and head, not against the base tip. So when the default branch advances past the merge base, the commits, the file list and the patch do not change. The only pinned field that changes is the base sha. The reviewers also read every touched file at the pinned base sha (`_prepare_workdir` fetches `file_content_at_ref(..., base)`), so the base-side context they saw is the base tip, not the merge base.

With merge-on-green landing the reviewer's own passes, main moves during almost every busy evening. ADR-0001 measured the cost on conference-os#2357: head `b78ed59` never moved, #2356 merged at 00:00:14, and the review was discarded at 00:13:39 after ~15 minutes of paid vendor time.

### What the journal shows

The journal on the Mini (`independent-review/state/journal.jsonl`) begins 2026-10-04T20:50Z, so it covers 17 days of the 30 asked for. In that span: 27 paid reviews, 4 `snapshot-changed` skips. Each skip was classified from the PR's commit dates, its timeline, and the commits that landed on main during the review window (review start taken as the journal record just before the skip, since the controller reviews one PR at a time).

| PR | Review window (UTC) | Paid time discarded | What moved | Class |
|---|---|---|---|---|
| #2173 | 10-06 01:49 → 02:11 | ~22 min | head `dc55980` pushed 02:08:45 | **head push** |
| #2208 | 10-09 01:12 → 01:29 | ~18 min | PR merged 01:20:00 by someone else; state closed | **merged mid-review** |
| #2247 | 10-12 03:40 → 03:45 | ~5.5 min | PR merged 03:43:50; state closed | **merged mid-review** |
| #2357 | 10-21 23:58 → 00:13 | ~15 min | #2356 merged to main 00:00:14; head unchanged | **base-only move** |

Count: 4 `snapshot-changed` skips, of which 1 base-only move, 1 head push, 2 PRs merged out from under the reviewer. About 60 minutes of paid review discarded in total, 15 of them (25%) to the base-only case. #2356 touched two files (`src/lib/mcp-oauth-metadata.ts`, one test); #2357 touched 23; the sets are disjoint, so the design below would have accepted that review.

The two merged-mid-review skips are a different problem (a PR merged without the independent verdict it was being gated on) and are out of scope here.

## Decision

**Keep the base sha in the pin.** It is the only field that records what base-side context the reviewers read, and dropping it would accept every base move, including a main that was force-pushed or that rewrote a file under review.

**Option (a). Add one escape hatch in `_recheck()`:** when `fresh != pinned`, the review is still accepted if `_base_only_move()` proves all of the following, and otherwise `snapshot-changed` is raised exactly as today.

1. Every pinned field other than `base` is identical, including a new field `diff_sha256`, the SHA-256 of the patch text the reviewers were given. Files and commits already come from the three-dot compare; the hash makes "byte-identical diff" a check, not an assumption.
2. `compare(old_base, new_base)` is complete and its `status` is `ahead`: the old base is an ancestor of the new one (a fast-forward, not a force-push or a diverged branch). `interpret_compare` now carries `status` through from the GitHub payload.
3. No path changed by that advance (new or previous filename) is one of the reviewed paths. This is what keeps the base-side files the reviewers read identical at the new base, so the verdict still describes the same change against the same context. An overlap means main changed a file under review; that review is discarded, which is today's behaviour.

An accepted base move writes a journal record `{"result": "base-moved", "head", "base_from", "base_to", ...}` so the saving is countable. The probe from ADR-0001 re-arms only on `"snapshot-changed"`, so it does not fire for this record. Nothing else on the Mini reads the journal.

Cost per base-only move: one extra compare call pair (JSON + diff) against the App rate limit. Nothing new is written to GitHub. Policy, `state.json`, the launchd job and the probe are unchanged.

### What is not changed

- A head push, a label change, a closed or drafted PR, a changed head repo, a changed classification, a lost required context, or a reviewer-selection change still discard the review.
- Where the verdict comes from and how it is posted are untouched; the change only decides whether a finished verdict is still about the pull request in front of it.

## Alternatives rejected

- **(b) Drop base sha from the pin and rely on commits and files.** Commits and files come from the same three-dot compare and never change on a base move either, so (b) accepts every base move unconditionally: a force-pushed main, a main that rewrote a reviewed file, or a diverged base. It also loses the record of which base the reviewers' file context came from. It saves the same 15 minutes in the #2357 case and nothing more; (a) saves the same minutes while still refusing the unsafe subset.
- **Re-pin on every base move and re-fetch base files for the reviewers.** The vendors have already returned; re-fetching changes nothing they saw. Only a fresh review would, which is the status quo.
- **Pin the merge-base sha instead of the base tip.** Would make the pin stable across fast-forwards, but silently keeps accepting when main rewrote a reviewed file, because the merge base does not move then either. Rejected for the same reason as (b).
- **Leave it.** One in four discarded reviews, measured over 17 days, is a base-only move, and the probe in ADR-0001 makes reviews start sooner and therefore overlap main's merges more often, not less.

## Verification done before opening this PR

- Controller copied from the Mini read-only (sha256 above); patch generated against it; the patched copy compiles under `python3 -m py_compile`.
- [`test_base_pin.py`](independent-review-base-pin/test_base_pin.py) exercises `_snapshot`, `_base_only_move` and `interpret_compare` with fakes: base-only + disjoint accepts; overlap, rename-over-reviewed-path, `diverged`, incomplete compare, `IncompleteRead`, head change, patch-hash change and label change all refuse; the compare call is skipped when any non-base field moved.
- Nothing was applied on the Mini. The live job, policy and state are as they were.

## Rollout (owner-applied)

1. On the Mini: `shasum -a 256 ~/Library/Application\ Support/Neuro/bin/neuro-independent-review.py` must print `1f5467c9…`; otherwise stop, the controller moved.
2. `cp neuro-independent-review.py neuro-independent-review.py.bak-$(date +%Y%m%d)-basepin` (the existing convention in that directory).
3. `patch neuro-independent-review.py < neuro-independent-review.base-pin.patch`, then `python3 -m py_compile neuro-independent-review.py` and `python3 -I test_base_pin.py neuro-independent-review.py`.
4. Nothing to restart: launchd runs the script fresh each tick.
5. Rollback: copy the `.bak-…-basepin` file back. The one new journal field is additive.

Revisit when: a `base-moved` record is followed by a verdict that a human later disputes because of main's change (none expected: the reviewed paths are proven disjoint), or when the journal shows merged-mid-review skips outnumbering base-only moves, which is the next defect to take on.
