#!/usr/bin/env bash
# prepush.sh — sub-60s local run of the convention probes that keep failing on first push (#465)
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd)

usage() {
  cat <<'EOF'
prepush.sh — run the cheap convention probes before the first push

WHAT IT DOES
  Runs, from the repo root: sensor-reachability (no orphan scripts), the mjs
  unknown-flag probe, the recipe playbook-sha256 pins, `bash -n` on changed
  shell scripts, and the test suites
  your diff touches (a changed scripts/tests/X.test.sh, or scripts/X.{sh,mjs}
  with a scripts/tests/X.test.sh beside it; at most 6, each capped at 25s via
  PREPUSH_TEST_TIMEOUT, all together within PREPUSH_BUDGET seconds, default 55;
  any suite that is skipped for the cap, the budget or a timeout is NOT RUN).
  The probes are the same
  functions run-all.sh uses (scripts/lib/convention-probes.sh), not copies.

WHY
  A CI miss costs a push, a re-review at the new head and a fresh approval.
  The full suite (scripts/tests/run-all.sh) takes ~15 minutes, so it gets
  skipped. These probes are the ones that failed first-push in practice.

RISKS
  Report-only: it changes nothing and is not a merge gate. A green result is
  NOT a green gate; CI stays the authority. A probe that cannot run (missing
  node, or a suite over its time cap) prints NOT RUN and does not count as a pass. Touched-test mapping is by
  filename only, so a change with no matching test runs no suite.

USAGE
  scripts/prepush.sh [--base REF] [--no-tests]
  scripts/prepush.sh --help

EXAMPLES
  scripts/prepush.sh                 # diff against origin/main
  scripts/prepush.sh --base HEAD~3

EXIT
  0 all clear   1 a probe failed (its name is the last line)   2 usage
EOF
}

BASE="origin/main"
TEST_TIMEOUT="${PREPUSH_TEST_TIMEOUT:-25}"
TEST_BUDGET="${PREPUSH_BUDGET:-55}"
MAX_TESTS=6
RUN_TESTS=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [[ $# -ge 2 ]] || { echo "unknown flag: --base requires a value" >&2; exit 2; }; BASE="$2"; shift 2 ;;
    --no-tests) RUN_TESTS=0; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT" || exit 2
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "prepush: --base ref not found: $BASE" >&2; exit 2; }
# shellcheck source=lib/convention-probes.sh
. "$SCRIPT_DIR/lib/convention-probes.sh"
# shellcheck source=lib/wall-timeout.sh
. "$SCRIPT_DIR/lib/wall-timeout.sh"

FAILED=()
note_fail() { FAILED+=("$1"); }

# run_probe NAME CMD... — prints PASS/FAIL/NOT RUN (rc 2 means a tool is missing).
run_probe() {
  local name="$1" out rc=0
  shift
  out=$("$@" 2>&1) || rc=$?
  case "$rc" in
    0) echo "  PASS     $name" ;;
    2) echo "  NOT RUN  $name (a required tool is missing)"; note_fail "$name" ;;
    124) echo "  NOT RUN  $name (timed out after ${TEST_TIMEOUT_USED:-$TEST_TIMEOUT}s; run it directly or rely on CI)"; note_fail "$name" ;;
    *) echo "  FAIL     $name"; printf '%s\n' "$out" | tail -n 8 | sed 's/^/           /'; note_fail "$name" ;;
  esac
}

# Files changed against BASE (committed, staged, unstaged) plus untracked.
changed_files() {
  local mb
  mb=$(git merge-base HEAD "$BASE" 2>/dev/null) || mb="$BASE"
  { git diff --name-only "$mb" 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u
}
CHANGED=$(changed_files)

echo "prepush: base=$BASE changed=$(printf '%s\n' "$CHANGED" | grep -c . || true)"

if command -v node >/dev/null 2>&1; then
  run_probe sensor-reachability node scripts/sensor-reachability.mjs
else
  echo "  NOT RUN  sensor-reachability (node missing)"; note_fail sensor-reachability
fi
run_probe mjs-unknown-flag cp_mjs_unknown_flag
run_probe recipe-hash cp_recipe_hash_all

SH_CHANGED=()
while IFS= read -r f; do
  [[ "$f" == *.sh && -f "$f" ]] && SH_CHANGED+=("$f")
done <<< "$CHANGED"
if [[ ${#SH_CHANGED[@]} -gt 0 ]]; then
  run_probe bash-n cp_bash_n "${SH_CHANGED[@]}"
else
  echo "  PASS     bash-n (no changed shell scripts)"
fi

SKIPPED_TESTS=0
if [[ "$RUN_TESTS" -ne 1 ]]; then
  SKIPPED_TESTS=1
  echo "  SKIPPED  touched-tests (--no-tests: the suites your diff touches were NOT run)"
fi
if [[ "$RUN_TESTS" -eq 1 ]]; then
  TESTS=()
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
      scripts/tests/*.test.sh) [[ -f "$f" ]] && TESTS+=("$f") ;;
      scripts/*.sh|scripts/*.mjs)
        base=$(basename "$f"); base="${base%.*}"
        [[ -f "scripts/tests/$base.test.sh" ]] && TESTS+=("scripts/tests/$base.test.sh") ;;
    esac
  done <<< "$CHANGED"
  # De-duplicate (bash 3.2: no associative arrays).
  UNIQ=()
  for t in ${TESTS[@]+"${TESTS[@]}"}; do
    dup=0
    for u in ${UNIQ[@]+"${UNIQ[@]}"}; do [[ "$u" == "$t" ]] && dup=1; done
    [[ "$dup" -eq 0 ]] && UNIQ+=("$t")
  done
  if [[ ${#UNIQ[@]} -eq 0 ]]; then
    echo "  PASS     touched-tests (none map to this diff)"
  else
    START=$SECONDS
    n=0
    for t in "${UNIQ[@]}"; do
      n=$((n + 1))
      left=$((TEST_BUDGET - (SECONDS - START)))
      if [[ "$n" -gt "$MAX_TESTS" ]]; then
        echo "  NOT RUN  test:$(basename "$t") (over the $MAX_TESTS-suite cap; run it directly)"; note_fail "test:$(basename "$t")"
      elif [[ "$left" -le 0 ]]; then
        echo "  NOT RUN  test:$(basename "$t") (over the ${TEST_BUDGET}s budget; run it directly)"; note_fail "test:$(basename "$t")"
      else
        cap=$TEST_TIMEOUT; [[ "$left" -lt "$cap" ]] && cap=$left
        TEST_TIMEOUT_USED=$cap
        run_probe "test:$(basename "$t")" run_with_wall_timeout "$cap" bash "$t"
      fi
    done
  fi
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "prepush: FAILED ${FAILED[*]}"
  exit 1
fi
if [[ "$SKIPPED_TESTS" -eq 1 ]]; then
  echo "prepush: probes clear, touched tests SKIPPED (CI is still the authority)"
else
  echo "prepush: all clear (CI is still the authority)"
fi
