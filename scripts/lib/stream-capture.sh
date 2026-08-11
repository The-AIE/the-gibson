#!/usr/bin/env bash
# stream-capture.sh — fail-closed stdout/stderr capture helper (#153 P2/P3)
#
# Source this from release-claim.sh (and from sensors that exercise the real
# production helper in-process). Free of env-var test hooks; never eval's
# attacker-controlled data (only shell-owned `trap -p` restore text).
#
# Capture stdout and stderr of an exact argv separately, preserving exit
# status. Only stdout is authoritative data for the caller; stderr is
# diagnostics only.
#
# Fail-closed contract:
#   * Signal traps are installed BEFORE any temp allocation. There is no
#     untracked first-allocation window: the only resources that can exist
#     are already listed in the tracked globals the handler cleans.
#   * Temp handles are retained until successful unlink is verified.
#     Persistent unlink failure never clears handles, poisons stdout
#     authority, returns nonzero, and preserves diagnostic stderr when it
#     was read successfully. No recursive best-effort rm -rf fallback.
#   * Caller's prior HUP/INT/TERM dispositions are restored exactly on
#     ordinary return.
#   * On signal: clean tracked artifacts with verified unlink only, restore
#     the prior disposition for each of HUP/INT/TERM, re-deliver the received
#     signal so prior/default/ignored semantics are honored without recursion.
#     If unlink cannot be proved, handles stay set so recoverable diagnostics
#     remain visible when a prior disposition lets the process continue.
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

_RC_CAP_DIR=""
_RC_CAP_OUTF=""
_RC_CAP_ERRF=""
_RC_CAP_STDOUT=""
_RC_CAP_STDERR=""
_RC_CAP_PREV_HUP=""
_RC_CAP_PREV_INT=""
_RC_CAP_PREV_TERM=""
_RC_CAP_IN_SIGNAL=0
_RC_CAP_UNLINK_FAIL=0

# Verified unlink of one path. Returns 0 only when the path is gone.
# Does NOT clear the caller's handle variable — caller clears only on success.
_rc_capture_unlink_one() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi
  if ! rm -f -- "$path" 2>/dev/null; then
    return 1
  fi
  if [[ -e "$path" || -L "$path" ]]; then
    return 1
  fi
  return 0
}

# Signal/ordinary cleanup of tracked temps. NEVER clears a handle unless that
# path's unlink is verified. NEVER uses recursive rm -rf. On persistent failure
# leaves handles set and sets _RC_CAP_UNLINK_FAIL=1 so callers poison authority.
_rc_capture_cleanup_temps() {
  local fail=0
  if [[ -n "${_RC_CAP_OUTF:-}" ]]; then
    if _rc_capture_unlink_one "$_RC_CAP_OUTF"; then
      _RC_CAP_OUTF=""
    else
      fail=1
    fi
  fi
  if [[ -n "${_RC_CAP_ERRF:-}" ]]; then
    if _rc_capture_unlink_one "$_RC_CAP_ERRF"; then
      _RC_CAP_ERRF=""
    else
      fail=1
    fi
  fi
  # Parent dir: only rmdir when both children are verified gone. No rm -rf.
  if [[ -z "${_RC_CAP_OUTF:-}" && -z "${_RC_CAP_ERRF:-}" && -n "${_RC_CAP_DIR:-}" ]]; then
    if [[ ! -e "$_RC_CAP_DIR" && ! -L "$_RC_CAP_DIR" ]]; then
      _RC_CAP_DIR=""
    elif rmdir -- "$_RC_CAP_DIR" 2>/dev/null; then
      _RC_CAP_DIR=""
    elif [[ ! -e "$_RC_CAP_DIR" && ! -L "$_RC_CAP_DIR" ]]; then
      _RC_CAP_DIR=""
    else
      fail=1
    fi
  fi
  if [[ "$fail" -ne 0 || -n "${_RC_CAP_OUTF:-}" || -n "${_RC_CAP_ERRF:-}" || -n "${_RC_CAP_DIR:-}" ]]; then
    _RC_CAP_UNLINK_FAIL=1
    return 1
  fi
  _RC_CAP_UNLINK_FAIL=0
  return 0
}

# Restore prior traps from trap -p snapshots. Shell-owned text only.
# Prefer explicit args when provided; otherwise use the globals snapshotted
# at capture start (signal path and ordinary return both work).
_rc_capture_restore_traps() {
  local prev_hup prev_int prev_term
  if [[ $# -ge 3 ]]; then
    prev_hup="$1"
    prev_int="$2"
    prev_term="$3"
  else
    prev_hup="$_RC_CAP_PREV_HUP"
    prev_int="$_RC_CAP_PREV_INT"
    prev_term="$_RC_CAP_PREV_TERM"
  fi
  if [[ -n "$prev_hup" ]]; then eval "$prev_hup"; else trap - HUP; fi
  if [[ -n "$prev_int" ]]; then eval "$prev_int"; else trap - INT; fi
  if [[ -n "$prev_term" ]]; then eval "$prev_term"; else trap - TERM; fi
}

# Signal path: clean tracked temps (handles retained on unlink failure),
# restore prior dispositions, re-deliver the received signal so prior/default/
# ignored semantics run without recursion.
_rc_capture_on_signal() {
  local sig="$1"
  # Guard against re-entrancy if a restored handler re-raises while we clean.
  if [[ "${_RC_CAP_IN_SIGNAL:-0}" -ne 0 ]]; then
    return 0
  fi
  _RC_CAP_IN_SIGNAL=1
  # Best effort clean; never clear handles without verified unlink. Persistent
  # failure leaves handles and marks unlink fail so a continued process (ignored
  # disposition) cannot later treat capture output as authoritative.
  _rc_capture_cleanup_temps || true
  _RC_CAP_STDOUT=""
  # Restore caller's exact prior dispositions for all three, then re-raise.
  _rc_capture_restore_traps "$_RC_CAP_PREV_HUP" "$_RC_CAP_PREV_INT" "$_RC_CAP_PREV_TERM"
  _RC_CAP_IN_SIGNAL=0
  # Re-deliver so prior custom / ignored / default disposition is honored.
  kill -s "$sig" $$
}

_rc_capture_install_signal_traps() {
  trap '_rc_capture_on_signal HUP' HUP
  trap '_rc_capture_on_signal INT' INT
  trap '_rc_capture_on_signal TERM' TERM
}

# Unlink both temps with status check. Retains handles until each path is
# proven gone. Any first-attempt unlink failure is a capture failure even if
# a later retry succeeds (cleanup failure poisons stdout authority). Retries
# exist only to leave zero leaked temps; they never turn a failed cleanup
# into capture success. On persistent failure, handles STAY SET.
_rc_capture_unlink_verified() {
  local outf="${_RC_CAP_OUTF:-}" errf="${_RC_CAP_ERRF:-}" dir="${_RC_CAP_DIR:-}" first_fail=0
  if [[ -n "$outf" ]]; then
    if ! _rc_capture_unlink_one "$outf"; then
      first_fail=1
    else
      _RC_CAP_OUTF=""
    fi
  fi
  if [[ -n "$errf" ]]; then
    if ! _rc_capture_unlink_one "$errf"; then
      first_fail=1
    else
      _RC_CAP_ERRF=""
    fi
  fi
  # Retry any still-tracked handle so a sticky first failure does not leave
  # evidence on disk when a later attempt can succeed. Success here still
  # does not green a first_fail capture.
  if [[ -n "${_RC_CAP_OUTF:-}" ]]; then
    if _rc_capture_unlink_one "$_RC_CAP_OUTF"; then
      _RC_CAP_OUTF=""
    fi
  fi
  if [[ -n "${_RC_CAP_ERRF:-}" ]]; then
    if _rc_capture_unlink_one "$_RC_CAP_ERRF"; then
      _RC_CAP_ERRF=""
    fi
  fi
  # Parent dir: only remove when both children are verified gone. No rm -rf.
  if [[ -z "${_RC_CAP_OUTF:-}" && -z "${_RC_CAP_ERRF:-}" && -n "$dir" ]]; then
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
      _RC_CAP_DIR=""
    elif rmdir -- "$dir" 2>/dev/null; then
      _RC_CAP_DIR=""
    elif [[ ! -e "$dir" && ! -L "$dir" ]]; then
      _RC_CAP_DIR=""
    else
      first_fail=1
    fi
  fi
  if [[ "$first_fail" -ne 0 || -n "${_RC_CAP_OUTF:-}" || -n "${_RC_CAP_ERRF:-}" || -n "${_RC_CAP_DIR:-}" ]]; then
    _RC_CAP_UNLINK_FAIL=1
    return 1
  fi
  _RC_CAP_UNLINK_FAIL=0
  return 0
}

_rc_capture_streams() {
  local outf errf rc=0
  local out_data err_data
  local new_dir=""
  _RC_CAP_STDOUT=""
  _RC_CAP_STDERR=""
  _RC_CAP_OUTF=""
  _RC_CAP_ERRF=""
  _RC_CAP_DIR=""
  _RC_CAP_IN_SIGNAL=0
  _RC_CAP_UNLINK_FAIL=0

  # Snapshot caller traps before any allocation so ordinary-return restore
  # is always accurate. Bash 3.2: trap -p prints nothing when unset.
  _RC_CAP_PREV_HUP=$(trap -p HUP 2>/dev/null || true)
  _RC_CAP_PREV_INT=$(trap -p INT 2>/dev/null || true)
  _RC_CAP_PREV_TERM=$(trap -p TERM 2>/dev/null || true)

  # Install signal traps BEFORE any allocation. Tracked globals start empty,
  # so a signal in this window cleans nothing and re-raises — no untracked
  # resource can exist yet.
  _rc_capture_install_signal_traps

  # Parent directory: allocate, then immediately publish into the tracked
  # global so any signal after creation sees a protected handle. There is no
  # gap where a created resource is untracked: the only assignment that makes
  # the path observable to later code is the global assignment itself.
  new_dir=$(mktemp -d "${TMPDIR:-/tmp}/gibson-rc-cap.XXXXXX") || {
    _rc_capture_restore_traps
    return 127
  }
  _RC_CAP_DIR="$new_dir"
  new_dir=""

  # Child files inside the protected parent (creation cannot outrun tracking).
  # Names keep the gibson-rc-cap-* prefix so leak sensors and hostile-path
  # fixtures that match that pattern still see every allocation.
  outf="$_RC_CAP_DIR/gibson-rc-cap-out"
  errf="$_RC_CAP_DIR/gibson-rc-cap-err"
  # Create empty files under the already-protected directory.
  if ! : >"$outf" 2>/dev/null; then
    _rc_capture_cleanup_temps || true
    _RC_CAP_STDOUT=""
    _rc_capture_restore_traps
    return 127
  fi
  _RC_CAP_OUTF="$outf"
  if ! : >"$errf" 2>/dev/null; then
    _rc_capture_cleanup_temps || true
    _RC_CAP_STDOUT=""
    _rc_capture_restore_traps
    return 127
  fi
  _RC_CAP_ERRF="$errf"

  # Explicit argv only — never eval of the command under test.
  "$@" >"$outf" 2>"$errf" || rc=$?

  # Read both streams before unlinking. A failed read poisons stdout
  # authority. Handles stay set until unlink is verified.
  if ! out_data=$(cat -- "$outf" 2>/dev/null); then
    _RC_CAP_STDOUT=""
    _RC_CAP_STDERR=""
    _rc_capture_unlink_verified || true
    # Do not clear handles on persistent unlink failure.
    _rc_capture_restore_traps
    return 1
  fi
  if ! err_data=$(cat -- "$errf" 2>/dev/null); then
    # Stdout was read but is not authoritative without a complete capture.
    _RC_CAP_STDOUT=""
    _RC_CAP_STDERR=""
    _rc_capture_unlink_verified || true
    _rc_capture_restore_traps
    return 1
  fi

  # Both streams read. Unlink with verification; retain diagnostic stderr and
  # poison stdout authority if unlink cannot be proved. NEVER clear handles
  # on persistent failure — they remain visible/recoverable.
  if ! _rc_capture_unlink_verified; then
    _RC_CAP_STDOUT=""
    # Retain successfully-read stderr strictly as diagnostics.
    _RC_CAP_STDERR="$err_data"
    # Handles intentionally NOT cleared — persistent unlink remains visible.
    _rc_capture_restore_traps
    return 1
  fi

  _rc_capture_restore_traps
  _RC_CAP_STDOUT="$out_data"
  _RC_CAP_STDERR="$err_data"
  return "$rc"
}
