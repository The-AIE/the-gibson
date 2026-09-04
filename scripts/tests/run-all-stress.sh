#!/usr/bin/env bash
# run-all-stress.sh — N parallel-mode full-suite runs (#319)
set -uo pipefail

usage() {
  cat <<'EOF'
run-all-stress.sh — run the Gibson self-gate N times in parallel mode

WHAT IT DOES
  Invokes scripts/tests/run-all.sh --no-quarantine --jobs J, N times.
  Any red run fails the stress (exit 1) with the failing run named.
  Does not raise budgets or quarantine suites.

USAGE
  scripts/tests/run-all-stress.sh [--runs N] [--jobs J] [--timeout S]
  scripts/tests/run-all-stress.sh --help

  --runs N     repetitions (default 5)
  --jobs J     passed to run-all --jobs (default 8)
  --timeout S  passed to run-all --timeout (omit = run-all default)

EXIT
  0  every repetition was green
  1  a repetition went red
  2  usage error
EOF
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN_ALL="$SCRIPT_DIR/run-all.sh"

RUNS=5
JOBS=8
TIMEOUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="${2:-}"; shift 2 ;;
    --jobs) JOBS="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run-all-stress.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$RUNS" in
  ''|*[!0-9]*|0) echo "run-all-stress.sh: --runs wants a whole number >= 1" >&2; exit 2 ;;
esac
case "$JOBS" in
  ''|*[!0-9]*|0) echo "run-all-stress.sh: --jobs wants a whole number >= 1" >&2; exit 2 ;;
esac
if [[ -n "$TIMEOUT" ]]; then
  case "$TIMEOUT" in
    ''|*[!0-9]*) echo "run-all-stress.sh: --timeout wants a whole number of seconds" >&2; exit 2 ;;
  esac
fi

if [[ ! -f "$RUN_ALL" ]]; then
  echo "run-all-stress.sh: missing $RUN_ALL" >&2
  exit 2
fi

fail=0
failed_runs=""
i=1
while [[ "$i" -le "$RUNS" ]]; do
  echo "run-all-stress: run $i/$RUNS jobs=$JOBS"
  rc=0
  if [[ -n "$TIMEOUT" ]]; then
    bash "$RUN_ALL" --no-quarantine --jobs "$JOBS" --timeout "$TIMEOUT" || rc=$?
  else
    bash "$RUN_ALL" --no-quarantine --jobs "$JOBS" || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "run-all-stress: RED on run $i/$RUNS (exit $rc)"
    fail=1
    failed_runs="${failed_runs}${failed_runs:+ }$i"
  else
    echo "run-all-stress: GREEN on run $i/$RUNS"
  fi
  i=$((i + 1))
done

if [[ "$fail" -ne 0 ]]; then
  echo "run-all-stress: FAIL (red runs:${failed_runs})"
  exit 1
fi
echo "run-all-stress: PASS ($RUNS/$RUNS green, jobs=$JOBS)"
exit 0
