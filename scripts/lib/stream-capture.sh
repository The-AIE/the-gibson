#!/usr/bin/env bash
# stream-capture.sh — fail-closed stdout/stderr capture helper (#153 P2/P3)
#
# Source this from release-claim.sh (and from sensors that exercise the real
# production helper in-process). Free of env-var test hooks; never eval's
# attacker-controlled data.
#
# Capture stdout and stderr of an exact argv separately, preserving exit
# status. Only stdout is authoritative data for the caller; stderr is
# diagnostics only.
#
# Fail-closed contract:
#   * Each allocated temp is tracked and signal-protected immediately —
#     there is no HUP/INT/TERM window with an untracked allocated path.
#   * Temp handles are retained until successful unlink is verified.
#   * Any stdout read or cleanup (unlink) failure poisons stdout as
#     authoritative evidence (_RC_CAP_STDOUT cleared, nonzero return).
#   * Successfully read stderr is retained strictly as diagnostic data on
#     a later unlink failure; it never becomes evidence rows.
#   * Caller's prior traps are restored exactly on every ordinary return.
#   * Signal handlers unlink temps, clear capture traps, and re-raise so
#     the signal's default disposition terminates the process.
#   * Explicit argv only — "$@" is the full reader. Never eval of the
#     command under test. trap -p restore text is shell-owned, not user data.
#
# Sets after a successful capture of both streams (child exit still returned):
#   _RC_CAP_STDOUT  authoritative stdout body
#   _RC_CAP_STDERR  diagnostic stderr body
#
# On capture failure (nonzero):
#   _RC_CAP_STDOUT  always empty (poisoned)
#   _RC_CAP_STDERR  diagnostic only when stderr was successfully read before
#                   an unlink failure; otherwise empty
#
# Bash 3.2-safe: no process substitution, no pipeline status games.

_RC_CAP_OUTF=""
_RC_CAP_ERRF=""
_RC_CAP_STDOUT=""
_RC_CAP_STDERR=""

# Best-effort unlink from a signal handler. Ordinary paths check rm status
# and only clear handles after a verified successful unlink.
_rc_capture_cleanup_temps() {
  [[ -n "${_RC_CAP_OUTF:-}" ]] && rm -f -- "$_RC_CAP_OUTF" 2>/dev/null || true
  [[ -n "${_RC_CAP_ERRF:-}" ]] && rm -f -- "$_RC_CAP_ERRF" 2>/dev/null || true
  _RC_CAP_OUTF=""
  _RC_CAP_ERRF=""
}

# Restore prior traps from trap -p snapshots. Shell-owned text only.
_rc_capture_restore_traps() {
  local prev_hup="$1" prev_int="$2" prev_term="$3"
  if [[ -n "$prev_hup" ]]; then eval "$prev_hup"; else trap - HUP; fi
  if [[ -n "$prev_int" ]]; then eval "$prev_int"; else trap - INT; fi
  if [[ -n "$prev_term" ]]; then eval "$prev_term"; else trap - TERM; fi
}

# Install signal cleanup. Unlink tracked temps (via globals), drop capture
# traps, re-raise so default disposition terminates the process. Prior traps
# are NOT restored on the signal path — the process is exiting. Ordinary
# return paths restore them via _rc_capture_restore_traps.
_rc_capture_install_signal_traps() {
  trap '_rc_capture_cleanup_temps; trap - HUP INT TERM; kill -s HUP $$' HUP
  trap '_rc_capture_cleanup_temps; trap - HUP INT TERM; kill -s INT $$' INT
  trap '_rc_capture_cleanup_temps; trap - HUP INT TERM; kill -s TERM $$' TERM
}

# Unlink both temps with status check. Retains handles until each path is
# proven gone. Any first-attempt unlink failure is a capture failure even if
# a later retry succeeds (cleanup failure poisons stdout authority). Retries
# exist only to leave zero leaked temps; they never turn a failed cleanup
# into capture success.
_rc_capture_unlink_verified() {
  local outf="${_RC_CAP_OUTF:-}" errf="${_RC_CAP_ERRF:-}" first_fail=0
  if [[ -n "$outf" ]]; then
    if ! rm -f -- "$outf" || [[ -e "$outf" ]]; then
      first_fail=1
    else
      _RC_CAP_OUTF=""
    fi
  fi
  if [[ -n "$errf" ]]; then
    if ! rm -f -- "$errf" || [[ -e "$errf" ]]; then
      first_fail=1
    else
      _RC_CAP_ERRF=""
    fi
  fi
  # Retry any still-tracked handle so a sticky first failure does not leave
  # evidence on disk. Success here still does not green a first_fail capture.
  if [[ -n "${_RC_CAP_OUTF:-}" ]]; then
    if rm -f -- "$_RC_CAP_OUTF" 2>/dev/null && [[ ! -e "$_RC_CAP_OUTF" ]]; then
      _RC_CAP_OUTF=""
    fi
  fi
  if [[ -n "${_RC_CAP_ERRF:-}" ]]; then
    if rm -f -- "$_RC_CAP_ERRF" 2>/dev/null && [[ ! -e "$_RC_CAP_ERRF" ]]; then
      _RC_CAP_ERRF=""
    fi
  fi
  if [[ "$first_fail" -ne 0 || -n "${_RC_CAP_OUTF:-}" || -n "${_RC_CAP_ERRF:-}" ]]; then
    return 1
  fi
  return 0
}

_rc_capture_streams() {
  local outf errf rc=0
  local prev_hup prev_int prev_term
  local out_data err_data
  _RC_CAP_STDOUT=""
  _RC_CAP_STDERR=""
  _RC_CAP_OUTF=""
  _RC_CAP_ERRF=""

  # Snapshot caller traps before any allocation so ordinary-return restore
  # is always accurate. Bash 3.2: trap -p prints nothing when unset.
  prev_hup=$(trap -p HUP 2>/dev/null || true)
  prev_int=$(trap -p INT 2>/dev/null || true)
  prev_term=$(trap -p TERM 2>/dev/null || true)

  # First temp: track + protect immediately — no signal window with an
  # untracked allocated path.
  outf=$(mktemp "${TMPDIR:-/tmp}/gibson-rc-cap-out.XXXXXX") || return 127
  _RC_CAP_OUTF="$outf"
  _rc_capture_install_signal_traps

  # Second temp: same immediate protect.
  errf=$(mktemp "${TMPDIR:-/tmp}/gibson-rc-cap-err.XXXXXX") || {
    _rc_capture_cleanup_temps
    _rc_capture_restore_traps "$prev_hup" "$prev_int" "$prev_term"
    return 127
  }
  _RC_CAP_ERRF="$errf"
  # Handler already reads globals; reinstall is a no-op of the same body but
  # documents that both handles are live under protection.
  _rc_capture_install_signal_traps

  # Explicit argv only — never eval of the command under test.
  "$@" >"$outf" 2>"$errf" || rc=$?

  # Read both streams before unlinking. A failed read poisons stdout
  # authority. Handles stay set until unlink is verified.
  if ! out_data=$(cat -- "$outf" 2>/dev/null); then
    _RC_CAP_STDOUT=""
    _RC_CAP_STDERR=""
    _rc_capture_unlink_verified || true
    _rc_capture_cleanup_temps
    _rc_capture_restore_traps "$prev_hup" "$prev_int" "$prev_term"
    return 1
  fi
  if ! err_data=$(cat -- "$errf" 2>/dev/null); then
    # Stdout was read but is not authoritative without a complete capture.
    _RC_CAP_STDOUT=""
    _RC_CAP_STDERR=""
    _rc_capture_unlink_verified || true
    _rc_capture_cleanup_temps
    _rc_capture_restore_traps "$prev_hup" "$prev_int" "$prev_term"
    return 1
  fi

  # Both streams read. Unlink with verification; retain diagnostic stderr and
  # poison stdout authority if unlink cannot be proved.
  if ! _rc_capture_unlink_verified; then
    _RC_CAP_STDOUT=""
    # Retain successfully-read stderr strictly as diagnostics.
    _RC_CAP_STDERR="$err_data"
    _rc_capture_cleanup_temps
    _rc_capture_restore_traps "$prev_hup" "$prev_int" "$prev_term"
    return 1
  fi

  _rc_capture_restore_traps "$prev_hup" "$prev_int" "$prev_term"
  _RC_CAP_STDOUT="$out_data"
  _RC_CAP_STDERR="$err_data"
  return "$rc"
}
