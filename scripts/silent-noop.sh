#!/usr/bin/env bash
# silent-noop.sh — L-008 progress sensor for solo-loop drivers (issue #18)
#
# Source this from loop.sh (or any driver). It tracks whether gibson/loop-state.md
# advances between iterations. Exit-code budgets only catch crashes; this catches
# "runner exited 0 and did nothing" (L-008).
#
# Usage (inside the driver, after each successful or attempted iteration):
#   STATE_FILE=...  # path to gibson/loop-state.md
#   source "$SCRIPT_DIR/silent-noop.sh"
#   silent_noop_init          # once at startup
#   silent_noop_check         # each iteration after the runner returns
#
# Env:
#   NOOP_BUDGET   consecutive stagnant iterations before hard fail (default 3)

NOOP_BUDGET="${NOOP_BUDGET:-3}"
_silent_noop_streak=0
_silent_noop_last=""

_silent_noop_fp() {
  local u
  if [[ -f "${STATE_FILE:-}" ]]; then
    u=$(awk -F': ' '$1=="updated" {sub(/^[^:]+: /,""); print; exit}' "$STATE_FILE" 2>/dev/null || true)
    if [[ -n "$u" ]]; then
      printf '%s' "$u"
      return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$STATE_FILE" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$STATE_FILE" 2>/dev/null | awk '{print $1}'
    else
      wc -c < "$STATE_FILE" | tr -d ' '
    fi
  else
    printf 'missing'
  fi
}

silent_noop_init() {
  _silent_noop_streak=0
  _silent_noop_last=$(_silent_noop_fp)
}

silent_noop_check() {
  local now
  now=$(_silent_noop_fp)
  if [[ -z "$_silent_noop_last" ]]; then
    _silent_noop_last="$now"
    return 0
  fi
  if [[ "$now" == "$_silent_noop_last" ]]; then
    _silent_noop_streak=$((_silent_noop_streak + 1))
    echo "silent-noop: loop-state unchanged ($_silent_noop_streak/$NOOP_BUDGET) — L-008" >&2
    if [[ $_silent_noop_streak -ge $NOOP_BUDGET ]]; then
      echo "silent-noop: ERROR: budget exhausted — runner not advancing loop-state (L-008). Fix runner/permissions; do not raise NOOP_BUDGET." >&2
      return 1
    fi
  else
    _silent_noop_streak=0
    _silent_noop_last="$now"
  fi
  return 0
}
