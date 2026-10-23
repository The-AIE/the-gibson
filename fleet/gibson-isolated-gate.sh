#!/usr/bin/env bash
# gibson-isolated-gate.sh — run the-gibson's test suites in a THROWAWAY CLONE, never in a lane.
#
# Why (2026-10-15 incident): the-gibson's sensor suites commit into throwaway repos and rewrite git
# config. Run inside a linked worktree they wrote into the SHARED .git of every Gibson worktree:
# core.bare=true, origin URL replaced, refs/heads/main deleted, user.name=gate-test, dozens of
# url.insteadOf keys, the lane HEAD moved to an unborn branch. CI never sees this because it runs in a
# fresh clone. So locally we do the same: clone the lane into a temp dir, run there, delete it.
# They also fail on the fleet's worktree-scoped core.hooksPath (setup-hooks.test.sh); the clone has none.
#
# Usage:
#   gibson-isolated-gate.sh <worktree>                      # full gate: baseline at merge-base, then gate.sh on the lane
#   gibson-isolated-gate.sh <worktree> --only PATTERN[,..]  # focused suites via run-all.sh --only (uncommitted work included)
# Env: GIBSON_TEST_JOBS (default 4 — the Mac is shared with other lanes; 10 jobs took the load to 250)
# Exit: run-all / gate.sh exit code; 64 usage; 65 cannot resolve origin/main (fail closed)
set -uo pipefail
WT="${1:?usage: gibson-isolated-gate.sh <worktree> [--only PATTERN]}"; shift || true
ONLY=""; [ "${1:-}" = "--only" ] && { ONLY="${2:?--only needs a pattern}"; shift 2; }
cd "$WT" 2>/dev/null || { echo "gibson-isolated-gate: no worktree at $WT" >&2; exit 64; }
git rev-parse --verify -q "origin/main^{commit}" >/dev/null || { echo "gibson-isolated-gate: origin/main unresolvable — FAILING CLOSED (fetch first)" >&2; exit 65; }
BASE="$(git merge-base origin/main HEAD)" || { echo "gibson-isolated-gate: no merge base with origin/main — FAILING CLOSED" >&2; exit 65; }
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
export GIBSON_TEST_JOBS="${GIBSON_TEST_JOBS:-4}"
# CI-like environment: the harness shells export FORCE_COLOR, which makes node print a "NO_COLOR is ignored"
# warning on stderr and breaks suites that parse node output (pr-review-evidence.test.sh, 2026-10-16).
unset FORCE_COLOR NO_COLOR CLICOLOR_FORCE
# Toolchain like CI's: Homebrew first (working python3, jq, shellcheck). The macOS system python3 on this Mac is
# broken (xcrun shim), which fails bash32-syntax-each.test.sh's clock benchmark (2026-10-16, found by the #409 lane).
export PATH="/opt/homebrew/bin:$PATH"
# ONE Gibson gate at a time on this Mac (2026-10-15 night): two concurrent full gates made even the
# unmodified baseline time out a suite (exit 124 at 604 s) and flipped counts by one (118 vs 117).
# mkdir is atomic; a lock whose pid is dead is stale and is taken over. Wait INSIDE this script so
# a headless worker never has to end its turn to wait.
LOCK="${HOME}/.claude/fleet/state/gibson-gate.lock"; mkdir -p "$(dirname "$LOCK")"
waited=0
while ! mkdir "$LOCK" 2>/dev/null; do
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then echo "gibson-isolated-gate: taking over stale lock from dead pid $holder"; rm -rf "$LOCK"; continue; fi
  [ $((waited % 300)) -eq 0 ] && echo "gibson-isolated-gate: another Gibson gate holds the lock (pid ${holder:-?}); waiting ($((waited/60)) min so far)"
  sleep 15; waited=$((waited+15))
  [ $waited -gt 5400 ] && { echo "gibson-isolated-gate: waited 90 min for the lock — FAILING CLOSED" >&2; exit 66; }
done
echo $$ > "$LOCK/pid"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gibson-iso.XXXXXX")"; trap 'rm -rf "$TMP" "$LOCK"' EXIT
git clone -q --no-hardlinks "$WT" "$TMP/repo" || { echo "gibson-isolated-gate: clone failed" >&2; exit 1; }
cd "$TMP/repo" || exit 1
git config user.name "gibson-isolated-gate"; git config user.email "isolated-gate@fleet.invalid"
git config --unset core.hooksPath 2>/dev/null || true
# Bring uncommitted work along (tracked diff + untracked, excluding ignored) so focused runs test what the coder has.
# Fail closed when any of it cannot be brought: a clone missing part of the lane would gate something other than
# what the coder has and could report green for it (Codex read-only review 2026-10-23). Commit or stash, then retry.
( cd "$WT" && git diff --binary HEAD ) | git apply --allow-empty \
  || { echo "gibson-isolated-gate: cannot apply the lane's uncommitted diff to the clone — FAILING CLOSED (commit or stash it)" >&2; exit 1; }
( cd "$WT" && git ls-files --others --exclude-standard -z ) | while IFS= read -r -d '' f; do mkdir -p "$(dirname "$f")" && cp "$WT/$f" "$f" || exit 1; done \
  || { echo "gibson-isolated-gate: cannot copy an untracked lane file into the clone — FAILING CLOSED" >&2; exit 1; }
echo "gibson-isolated-gate: clone of $BRANCH at $(git rev-parse --short HEAD) in $TMP/repo (jobs=$GIBSON_TEST_JOBS)"
if [ -n "$ONLY" ]; then
  bash scripts/tests/run-all.sh --only "$ONLY"; exit $?   # (lock + temp dir released by the EXIT trap)
fi
# FULL GATE = what CI's `sensors` job runs: `bash scripts/tests/run-all.sh --no-quarantine`, judged by its
# EXIT STATUS, in the clean clone. (2026-10-16: the previous design ran gate.sh, which counts output LINES
# containing words like "failed" against a baseline — every passing suite's "N passed, 0 failed" summary
# counted as a failure, so ANY added suite or any load jitter moved 117 -> 118 and refused a correct push.
# CI never judges that way.)
# If the branch run is red, classify by SUITE NAME, not by line count: run the same thing at the merge-base
# and fail only on suites that fail on the branch but not at the baseline (pre-existing red is reported,
# never inherited as guilt or excused as new).
failing_suites() { sed -n 's/^  FAIL — \([A-Za-z0-9_.-]*\.test\.sh\):.*/\1/p' "$1" | sort -u; }   # suite-level lines only (exactly 2 spaces), not per-case detail
echo "gibson-isolated-gate: running run-all.sh --no-quarantine on $BRANCH (the CI sensors job)"
bash scripts/tests/run-all.sh --no-quarantine > "$TMP/branch.log" 2>&1; rc=$?
tail -4 "$TMP/branch.log" | grep -E "run-all" || true
[ $rc -eq 0 ] && { echo "gibson-isolated-gate: GREEN"; exit 0; }
failing_suites "$TMP/branch.log" > "$TMP/branch.fail"
if [ ! -s "$TMP/branch.fail" ]; then
  echo "gibson-isolated-gate: run-all exited $rc with no named failing suite (timeout/crash) — FAILING CLOSED; log: $TMP/branch.log (kept)" >&2
  trap 'rm -rf "$LOCK"' EXIT; exit "$rc"
fi
echo "gibson-isolated-gate: branch red ($(wc -l < "$TMP/branch.fail" | tr -d ' ') suite(s)); checking the same at merge-base $(git rev-parse --short "$BASE")"
git stash -q --include-untracked 2>/dev/null || true
git checkout -q "$BASE" || { echo "gibson-isolated-gate: cannot checkout merge-base" >&2; exit 1; }
bash scripts/tests/run-all.sh --no-quarantine > "$TMP/base.log" 2>&1
failing_suites "$TMP/base.log" > "$TMP/base.fail"
comm -23 "$TMP/branch.fail" "$TMP/base.fail" > "$TMP/new.fail"
if [ -s "$TMP/new.fail" ]; then
  echo "gibson-isolated-gate: RED — suites failing on the branch but not at the baseline:" >&2; sed 's/^/  NEW  /' "$TMP/new.fail" >&2
  cp "$TMP/branch.log" "$HOME/.claude/fleet/logs/gibson-gate-branch-$(date +%H%M%S).log"; echo "(full log saved under ~/.claude/fleet/logs/)" >&2
  exit 1
fi
echo "gibson-isolated-gate: GREEN vs baseline — every failing suite also fails at the merge-base (pre-existing):"; sed 's/^/  PRE  /' "$TMP/branch.fail"
exit 0
