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
  scripts/tests/run-all-stress.sh [--runs N] [--jobs J]
  scripts/tests/run-all-stress.sh --help

  --runs N     repetitions (default 5)
  --jobs J     passed to run-all --jobs (default 8)
  (no --timeout: the canonical per-suite budget is the contract; a stress run
   that widened it would pass suites the real gate fails)

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    # A value flag with no operand is a usage error, never an endless loop
    # (Codex round 2: `shift 2` fails without set -e and re-reads "$1").
    --runs|--jobs)
      [[ $# -ge 2 ]] || { echo "run-all-stress.sh: $1 requires a value" >&2; usage >&2; exit 2; }
      if [[ "$1" == "--runs" ]]; then RUNS="$2"; else JOBS="$2"; fi
      shift 2 ;;
    --timeout) echo "run-all-stress.sh: --timeout is not accepted; the canonical budget is the contract" >&2; exit 2 ;;
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
    bash "$RUN_ALL" --no-quarantine --jobs "$JOBS" || rc=$?
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
