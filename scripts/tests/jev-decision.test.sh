#!/usr/bin/env bash
# Auto-discovered offline checks for the optional Jev advisory boundary.
set -euo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
unset TYPESAFE_API_KEY GIBSON_JEV_ENABLED GIBSON_JEV_OPERATOR_MODE
LOG=$(mktemp "${TMPDIR:-/tmp}/gibson-jev-tests.XXXXXX")
trap 'rm -f "$LOG"' EXIT
if node --test --test-reporter=tap "$SCRIPT_DIR/jev-decision.test.mjs" >"$LOG" 2>&1; then
  RESULT=0
else
  RESULT=$?
fi
cat "$LOG"
PASS=$(awk '/^# pass [0-9]+$/ {n=$3} END {print n}' "$LOG")
FAIL=$(awk '/^# fail [0-9]+$/ {n=$3} END {print n}' "$LOG")
SKIPPED=$(awk '/^# skipped [0-9]+$/ {n=$3} END {print n}' "$LOG")
TODO=$(awk '/^# todo [0-9]+$/ {n=$3} END {print n}' "$LOG")
if [[ ! "$PASS" =~ ^[0-9]+$ || ! "$FAIL" =~ ^[0-9]+$ || ! "$SKIPPED" =~ ^[0-9]+$ || ! "$TODO" =~ ^[0-9]+$ ]]; then
  echo 'jev-decision.test.sh: test totals missing or malformed' >&2
  exit 1
fi
echo "jev-decision.test.sh: $PASS passed, $FAIL failed, $SKIPPED skipped, $TODO todo"
[[ "$RESULT" -eq 0 && "$PASS" -gt 0 && "$FAIL" -eq 0 && "$SKIPPED" -eq 0 && "$TODO" -eq 0 ]]
