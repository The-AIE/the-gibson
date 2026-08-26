#!/usr/bin/env bash
# wall-timeout.test.sh — sensors for scripts/lib/wall-timeout.sh (Liveness Contract clause 4).
#
# WHY
#   loop.sh bounds its runner with run_with_wall_timeout so a hung runner cannot
#   stall the loop. These pin the contract that wrapper MUST honor:
#   - it passes the command's stdin / stdout / exit code through unchanged
#     (claude/codex/hermes read the PROMPT from stdin — a wrapper that swallows
#      stdin starves them; a backgrounded process otherwise gets /dev/null stdin),
#   - it returns 124 on timeout, and
#   - it kills the WHOLE process tree, not just the direct child (a naive kill
#     leaks the runner's children as the exact zombies this guards against).
set -uo pipefail
DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "$DIR/../lib/wall-timeout.sh"

fails=0
ok()  { printf '  ok   — %s\n' "$1"; }
bad() { printf '  FAIL — %s\n' "$1"; fails=$((fails + 1)); }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

echo "wall-timeout: passthrough + timeout + whole-tree kill"

run_with_wall_timeout 30 bash -c 'exit 0'; eq "exit 0 passes through" "$?" "0"
run_with_wall_timeout 30 bash -c 'exit 7'; eq "nonzero exit passes through" "$?" "7"
eq "stdout passes through" "$(run_with_wall_timeout 30 bash -c 'printf OUT')" "OUT"
eq "stdin passes through"  "$(printf IN | run_with_wall_timeout 30 cat)" "IN"

# A distinctive duration so the child sleeps are identifiable in the process table.
run_with_wall_timeout 2 bash -c 'sleep 39701 & sleep 39701'
eq "timeout returns 124" "$?" "124"
sleep 1
eq "whole tree killed — no orphaned children" "$(pgrep -f 'sleep 39701' | wc -l | tr -d ' ')" "0"
pkill -f 'sleep 39701' 2>/dev/null || true

if [[ "$fails" -gt 0 ]]; then echo "wall-timeout: $fails FAILED"; exit 1; fi
echo "wall-timeout: all passed"
