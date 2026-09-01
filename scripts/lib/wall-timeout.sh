#!/usr/bin/env bash
# wall-timeout.sh — sourceable: run_with_wall_timeout <secs> <cmd...>
# Runs a command under a wall-clock cap and kills its WHOLE process tree on
# expiry (perl/python setpgrp), returning 124 on timeout. A naive kill leaks
# orphaned children (verified) — this is the hardened version.
#
# ORIGIN: scripts/loop-fleet.sh's run_with_wall_timeout. Callers that must not
# inherit stdin redirect </dev/null at the call site; the backgrounded runner
# is launched with `<&0` so a non-interactive shell still forwards the caller's
# already-redirected stdin (loop.sh stdin-fed runners; loop-fleet probes).
#
# Cancellation (#269): HUP/INT/TERM snapshot+restore+re-raise. Sourcing this
# file has no trap side effect. The function never installs EXIT or RETURN.

# Tracked identities for the in-flight invocation. Empty except while
# run_with_wall_timeout is active. Signal handlers read only these globals
# (function locals are not visible to a separate trap function).
_WT_PREV_HUP=""
_WT_PREV_INT=""
_WT_PREV_TERM=""
_WT_PID=""
_WT_PGID=""
_WT_GUARDIAN=""
_WT_WATCHER=""
_WT_PGRP_OK=0
_WT_PGRP_READY=""
_WT_STATUS_FILE=""
_WT_WAITED=0
_WT_WAIT_ACTIVE=0
_WT_IN_SIGNAL=0
_WT_CANCEL_RC=0
_WT_CANCEL_SIG=""
_WT_DEFER_SIGNAL=0
_WT_LIVE_CHILD=0
_WT_NESTED_CALLER=0

_wt_sig_status() {
  case "$1" in
    HUP) printf '%s\n' 129 ;;
    INT) printf '%s\n' 130 ;;
    TERM) printf '%s\n' 143 ;;
    *) printf '%s\n' 128 ;;
  esac
}

# Restore prior traps from trap -p snapshots. Shell-owned text only.
_wt_restore_traps() {
  local prev_hup="${_WT_PREV_HUP:-}"
  local prev_int="${_WT_PREV_INT:-}"
  local prev_term="${_WT_PREV_TERM:-}"
  if [[ -n "$prev_hup" ]]; then eval "$prev_hup"; else trap - HUP; fi
  if [[ -n "$prev_int" ]]; then eval "$prev_int"; else trap - INT; fi
  if [[ -n "$prev_term" ]]; then eval "$prev_term"; else trap - TERM; fi
}

_wt_clear_identities() {
  _WT_PID=""
  _WT_PGID=""
  _WT_GUARDIAN=""
  _WT_WATCHER=""
  _WT_PGRP_OK=0
  _WT_PGRP_READY=""
  _WT_STATUS_FILE=""
  _WT_WAITED=0
  _WT_WAIT_ACTIVE=0
  _WT_IN_SIGNAL=0
  _WT_CANCEL_RC=0
  _WT_CANCEL_SIG=""
  _WT_DEFER_SIGNAL=0
  _WT_LIVE_CHILD=0
  _WT_NESTED_CALLER=0
}

# Test hook: publish a production identity/state file. Never supplies
# identities to the helper, never enables cleanup, never changes policy.
_wt_publish() {
  local name="$1" val="$2"
  local dir="${FLEET_WALL_TIMEOUT_TEST_PUBLISH:-}"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  [[ -n "$name" ]] || return 0
  printf '%s\n' "$val" > "$dir/$name" 2>/dev/null || true
}

# Test hook: delay a production transition while $1 exists. Bounded.
_wt_hold_path() {
  local hold="$1"
  local i=0
  [[ -n "$hold" ]] || return 0
  while [[ -e "$hold" && $i -lt 200 ]]; do
    if [[ "${_WT_CANCEL_RC:-0}" -ne 0 ]]; then
      return 0
    fi
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i + 1))
  done
}

# Publish "in_grace" then optionally delay before the production 1s grace.
_wt_grace_hook() {
  _wt_publish in_grace 1
  _wt_hold_path "${FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE:-}"
}

# After our mandatory full TERM grace, allow a group-leading shell to finish
# one nested run_with_wall_timeout signal handler. The inner helper owns one
# full second of TERM grace; two seconds here covers that budget plus bounded
# scheduling/cleanup margin. A helper already identified as nested does not add
# another settlement, so the supported one-level cascade remains bounded.
_wt_settle_signal_cascade() {
  local pid="$1" i=0 st
  [[ "${_WT_NESTED_CALLER:-0}" -eq 0 ]] || return 0
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  while [[ $i -lt 40 ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    st=$(ps -p "$pid" -o state= 2>/dev/null || true)
    if [[ -z "$st" ]]; then
      st=$(ps -p "$pid" -o stat= 2>/dev/null || true)
    fi
    st=$(printf '%s' "$st" | tr -d '[:space:]')
    case "$st" in
      Z*|'') return 0 ;;
    esac
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i + 1))
  done
}

_wt_stop_guardian() {
  local guard="${_WT_GUARDIAN:-}" expected="${_WT_PID:-}" i=0 st guard_pgid
  local ready_pid="" ready_guard=""
  # The launcher may publish after the initial bounded proof window. Ordinary
  # and timeout cleanup must adopt that late guardian just as cancellation does;
  # otherwise pgrp_ok=0 could return successfully while the guardian survives.
  if [[ ! "$guard" =~ ^[1-9][0-9]*$ && "$expected" =~ ^[1-9][0-9]*$ \
    && -s "${_WT_PGRP_READY:-}" ]]; then
    read -r ready_pid ready_guard < "${_WT_PGRP_READY}" || true
    if [[ "$ready_pid" == "$expected" && "$ready_guard" =~ ^[1-9][0-9]*$ ]]; then
      guard="$ready_guard"
    fi
  fi
  _WT_GUARDIAN=""
  [[ "$guard" =~ ^[1-9][0-9]*$ && "$expected" =~ ^[1-9][0-9]*$ ]] || return 0
  _wt_publish guardian.pid "$guard"
  while kill -0 "$guard" 2>/dev/null && [[ $i -lt 20 ]]; do
    guard_pgid=$(ps -p "$guard" -o pgid= 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$guard_pgid" == "$expected" ]] || return 0
    st=$(ps -p "$guard" -o state= 2>/dev/null | tr -d '[:space:]' || true)
    case "$st" in Z*|'') break ;; esac
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  if kill -0 "$guard" 2>/dev/null; then
    guard_pgid=$(ps -p "$guard" -o pgid= 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$guard_pgid" == "$expected" ]]; then
      kill -KILL "$guard" 2>/dev/null || true
    fi
  fi
}

_wt_stop_reap_watcher() {
  local w="${_WT_WATCHER:-}"
  _WT_WATCHER=""
  [[ "$w" =~ ^[1-9][0-9]*$ ]] || return 0
  if kill -0 "$w" 2>/dev/null; then
    kill -TERM "$w" 2>/dev/null || true
    sleep 0.05 2>/dev/null || true
    kill -KILL "$w" 2>/dev/null || true
  fi
  wait "$w" 2>/dev/null || true
}

# Re-check live child identity. The ready marker is historical evidence only;
# group signals require a live trusted guardian whose current PGID is the exact
# leader PID. Before readiness, a current direct child may be signaled by exact
# PID (or group only when its current PGID is its PID). This closes the
# wait/latch boundary where a reaped PID could otherwise be reused.
_wt_recheck_pgrp_ok() {
  local pid="${_WT_PID:-}" guard="${_WT_GUARDIAN:-}" row=""
  local cand_ppid="" cand_pgid="" ready_pid="" ready_guard=""
  _WT_PGRP_OK=0
  _WT_LIVE_CHILD=0
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1

  # The trusted launcher writes leader+guardian after setpgrp and before exec.
  # The TERM-ignoring guardian keeps this exact PGID allocated through grace.
  if [[ ! "$guard" =~ ^[1-9][0-9]*$ && -s "${_WT_PGRP_READY:-}" ]]; then
    read -r ready_pid ready_guard < "${_WT_PGRP_READY}" || true
    if [[ "$ready_pid" == "$pid" && "$ready_guard" =~ ^[1-9][0-9]*$ ]]; then
      guard="$ready_guard"
      _WT_GUARDIAN="$guard"
    fi
  fi
  if [[ "$guard" =~ ^[1-9][0-9]*$ ]]; then
    cand_pgid=$(ps -p "$guard" -o pgid= 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$cand_pgid" == "$pid" ]]; then
      _wt_publish guardian.pid "$guard"
      _WT_LIVE_CHILD=1
      _WT_PGID=$pid
      _WT_PGRP_OK=1
      return 0
    fi
  fi

  # Before guardian readiness, a current direct child may still be signaled;
  # own-group proof permits the group, otherwise exact PID only.
  row=$(ps -p "$pid" -o ppid= -o pgid= 2>/dev/null || true)
  set -- $row
  cand_ppid="${1:-}"
  cand_pgid="${2:-}"
  [[ "$cand_ppid" == "$$" ]] || return 1
  _WT_LIVE_CHILD=1
  if [[ "$cand_pgid" == "$pid" ]]; then
    _WT_PGID=$pid
    _WT_PGRP_OK=1
    return 0
  fi
  return 1
}

# Clean the launched command. After wait, never group-signal (PID/PGID reuse).
# Before proof: exact leader PID only. Proven pgid==pid: TERM group, full 1s
# grace, KILL, reap. Never our own wrapper group ($$).
_wt_cancel_command() {
  local pid="${_WT_PID:-}"
  if [[ "${_WT_WAITED:-0}" -ne 0 && "${_WT_WAIT_ACTIVE:-0}" -eq 0 ]]; then
    return 0
  fi
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0

  _wt_recheck_pgrp_ok || true
  if [[ "${_WT_LIVE_CHILD:-0}" -ne 1 ]]; then
    wait "$pid" 2>/dev/null || true
    _wt_stop_guardian
    _WT_WAIT_ACTIVE=0
    _WT_WAITED=1
    return 0
  fi

  if [[ "${_WT_PGRP_OK:-0}" -eq 1 && "${_WT_PGID:-}" == "$pid" && "$pid" != "$$" ]]; then
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    _wt_grace_hook
    sleep 1
    _wt_settle_signal_cascade "$pid"
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
    _wt_grace_hook
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  _wt_stop_guardian
  _WT_WAIT_ACTIVE=0
  _WT_WAITED=1
}

_wt_on_signal() {
  local requested="$1" sig rc
  if [[ "${_WT_IN_SIGNAL:-0}" -ne 0 ]]; then
    return 0
  fi
  _WT_IN_SIGNAL=1
  if [[ "${_WT_CANCEL_RC:-0}" -eq 0 ]]; then
    _WT_CANCEL_SIG="$requested"
    _WT_CANCEL_RC=$(_wt_sig_status "$requested")
  fi
  sig="${_WT_CANCEL_SIG:-$requested}"
  rc="${_WT_CANCEL_RC}"

  # Bash may dispatch a trap between starting a background process and the
  # immediately following `$!` assignment. Latch the first signal but let that
  # two-command critical section publish the exact PID before cleanup.
  if [[ "${_WT_DEFER_SIGNAL:-0}" -ne 0 ]]; then
    _WT_IN_SIGNAL=0
    return 0
  fi
  # Cancellation is not a wall-clock timeout. Never set timed_out / write 124.

  _wt_stop_reap_watcher
  _wt_cancel_command

  rm -f "${_WT_STATUS_FILE:-}" "${_WT_PGRP_READY:-}"
  _WT_STATUS_FILE=""
  _WT_PGRP_READY=""
  _WT_PID=""
  _WT_PGID=""
  _WT_PGRP_OK=0
  _WT_WAITED=1

  _wt_restore_traps
  _WT_IN_SIGNAL=0
  _WT_CANCEL_SIG=""
  _WT_CANCEL_RC=0
  kill -s "$sig" "$$" 2>/dev/null || true
  return "$rc"
}

_wt_drain_deferred_signal() {
  local sig="${_WT_CANCEL_SIG:-}"
  [[ "${_WT_CANCEL_RC:-0}" -ne 0 && -n "$sig" ]] || return 0
  _wt_on_signal "$sig"
}

_wt_install_signal_traps() {
  # `|| return $?` returns from run_with_wall_timeout when the first handler
  # reports a cancel status (ignored/custom dispositions that continue).
  # Recursive entry returns 0 so the outer handler keeps running.
  trap '_wt_on_signal HUP || return $?' HUP
  trap '_wt_on_signal INT || return $?' INT
  trap '_wt_on_signal TERM || return $?' TERM
}

_wt_ordinary_end() {
  local status_file="${_WT_STATUS_FILE:-}" ready="${_WT_PGRP_READY:-}"
  rm -f "$status_file" "$ready"
  _wt_restore_traps
  _wt_clear_identities
}

run_with_wall_timeout() {
  local limit="$1"
  shift
  local pid watcher rc=0 status_file timed_out=0 st poll now pgid guardian
  local elapsed watcher_wait_bound i settle pgrp_ok=0 pgrp_ready arm_path
  local ready_pid ready_guard guard_pgid
  local arm_spec arm_mode pfb_precond=0 now_force
  local parent_marker_was_set=0 parent_marker_prev=""
  # parent_forced=1 when *this* shell wrote the timeout flag via the real
  # date/tick ownership branches. The watcher exits early on that flag without
  # signaling, so residual cleanup must own the full TERM → grace → KILL contract.
  local parent_forced=0
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "fleet: bad wall timeout: $limit" >&2; return 1; }

  # Fail closed BEFORE launch if we cannot establish a process group.
  # A bare-child fallback cannot guarantee descendant cleanup on expiry.
  if ! command -v perl >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    echo "fleet: wall-timeout requires perl or python3 to establish a process group (no bare-child fallback)" >&2
    return 1
  fi

  # Snapshot caller HUP/INT/TERM, then install handlers while identities are
  # empty. Sourcing this file does not run this block. Never EXIT/RETURN.
  _wt_clear_identities
  if [[ "${FLEET_WALL_TIMEOUT_PARENT_WRAPPER:-}" =~ ^[1-9][0-9]*$ \
    && "${FLEET_WALL_TIMEOUT_PARENT_WRAPPER:-}" == "$PPID" ]]; then
    _WT_NESTED_CALLER=1
  fi
  _WT_PREV_HUP=$(trap -p HUP 2>/dev/null || true)
  _WT_PREV_INT=$(trap -p INT 2>/dev/null || true)
  _WT_PREV_TERM=$(trap -p TERM 2>/dev/null || true)
  _wt_install_signal_traps

  status_file=$(mktemp "${TMPDIR:-/tmp}/fleet-wall.XXXXXX") || {
    _wt_ordinary_end
    return 1
  }
  _WT_STATUS_FILE="$status_file"
  # Marker written by the trusted launcher after setpgrp+guardian creation and
  # before exec. The live TERM-ignoring guardian anchors the exact PGID even if
  # the command leader exits. The marker alone never authorizes group signals.
  pgrp_ready=$(mktemp "${TMPDIR:-/tmp}/fleet-pgrp.XXXXXX") || {
    rm -f "$status_file"
    _wt_ordinary_end
    return 1
  }
  _WT_PGRP_READY="$pgrp_ready"

  # Become process-group leader so we can terminate only this tree.
  # Ready protocol: launcher writes leader+guardian after setpgrp, then execs.
  # HOLD_READY delays publication of that marker (test hook: delay only).
  if [[ "${FLEET_WALL_TIMEOUT_PARENT_WRAPPER+x}" == x ]]; then
    parent_marker_was_set=1
    parent_marker_prev="${FLEET_WALL_TIMEOUT_PARENT_WRAPPER}"
  fi
  FLEET_WALL_TIMEOUT_PARENT_WRAPPER="$$"
  export FLEET_WALL_TIMEOUT_PARENT_WRAPPER
  _WT_DEFER_SIGNAL=1
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      my $hold = $ENV{FLEET_WALL_TIMEOUT_TEST_HOLD_READY};
      if (defined $hold && length $hold) {
        my $i = 0;
        while ($i < 200 && -e $hold) {
          select(undef, undef, undef, 0.05);
          $i++;
        }
      }
      setpgrp(0,0);
      my $guard = fork();
      exit 127 unless defined $guard;
      if ($guard == 0) {
        $SIG{HUP} = "IGNORE";
        $SIG{INT} = "IGNORE";
        $SIG{TERM} = "IGNORE";
        while (1) { sleep 60; }
        exit 0;
      }
      my $rf = $ARGV[0];
      if (open my $fh, ">", $rf) { print $fh "$$ $guard\n"; close $fh; }
      exec { $ARGV[1] } @ARGV[1..$#ARGV] or exit 127;
    ' "$pgrp_ready" "$@" <&0 &
    pid=$!
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os, signal, sys, time
hold = os.environ.get("FLEET_WALL_TIMEOUT_TEST_HOLD_READY") or ""
if hold:
    i = 0
    while i < 200 and os.path.exists(hold):
        time.sleep(0.05)
        i += 1
os.setpgrp()
guard = os.fork()
if guard == 0:
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(60)
rf = sys.argv[1]
try:
    with open(rf, "w") as f:
        f.write("%d %d\n" % (os.getpid(), guard))
except Exception:
    pass
os.execvp(sys.argv[2], sys.argv[2:])
' "$pgrp_ready" "$@" <&0 &
    pid=$!
  else
    # Unreachable: guarded above. Keep as hard fail-closed, never bare child.
    if [[ $parent_marker_was_set -eq 1 ]]; then
      FLEET_WALL_TIMEOUT_PARENT_WRAPPER="$parent_marker_prev"
      export FLEET_WALL_TIMEOUT_PARENT_WRAPPER
    else
      unset FLEET_WALL_TIMEOUT_PARENT_WRAPPER
    fi
    _WT_DEFER_SIGNAL=0
    if [[ "${_WT_CANCEL_RC:-0}" -ne 0 ]]; then
      _wt_drain_deferred_signal || return $?
    fi
    echo "fleet: wall-timeout process-group mechanism vanished before launch" >&2
    rm -f "$status_file" "$pgrp_ready"
    _wt_ordinary_end
    return 1
  fi
  if [[ $parent_marker_was_set -eq 1 ]]; then
    FLEET_WALL_TIMEOUT_PARENT_WRAPPER="$parent_marker_prev"
    export FLEET_WALL_TIMEOUT_PARENT_WRAPPER
  else
    unset FLEET_WALL_TIMEOUT_PARENT_WRAPPER
  fi
  _wt_publish before_leader_track 1
  _wt_hold_path "${FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_LEADER_TRACK:-}"
  _WT_PID=$pid
  _WT_PGID=$pid
  _wt_publish wrapper.pid "$$"
  _wt_publish leader.pid "$pid"
  _WT_DEFER_SIGNAL=0
  if [[ "${_WT_CANCEL_RC:-0}" -ne 0 ]]; then
    _wt_drain_deferred_signal || return $?
  fi

  # Wait for live group proof. Reading ps too early can return the parent
  # shell's group; require the trusted marker plus guardian pgid == leader pid.
  pgid=$pid
  pgrp_ok=0
  settle=0
  while [[ $settle -lt 100 ]]; do
    ready_pid=""
    ready_guard=""
    if [[ -s "$pgrp_ready" ]]; then
      read -r ready_pid ready_guard < "$pgrp_ready" || true
      if [[ "$ready_pid" == "$pid" && "$ready_guard" =~ ^[1-9][0-9]*$ ]]; then
        guard_pgid=$(ps -p "$ready_guard" -o pgid= 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$guard_pgid" == "$pid" ]]; then
          guardian=$ready_guard
          _WT_GUARDIAN=$guardian
          pgid=$pid
          pgrp_ok=1
          break
        fi
      fi
    fi
    if ! kill -0 "$pid" 2>/dev/null && [[ $settle -gt 5 ]]; then
      # Leader gone without a live exact guardian: never trust stale evidence.
      break
    fi
    sleep 0.01 2>/dev/null || true
    settle=$((settle + 1))
  done
  # Keep the ready file until ordinary/cancel cleanup so a re-check after
  # leader exit can still prove pgid==pid. Never rm before wait.
  _WT_PGRP_OK=$pgrp_ok
  _WT_PGID=$pgid
  _wt_publish guardian.pid "${guardian:-}"
  _wt_publish pgid "$pgid"
  _wt_publish pgrp_ok "$pgrp_ok"

  # Watcher: wall-clock bound. On expiry: TERM → full 1s grace → KILL, exact
  # PGID only when pgrp_ok. On natural leader exit the watcher exits without
  # signaling so the parent residual path owns orphan cleanup (and ordering).
  _WT_DEFER_SIGNAL=1
  (
    elapsed=0
    while [[ $elapsed -lt $limit ]]; do
      if [[ -f "$status_file" ]] && grep -q '^timeout$' "$status_file" 2>/dev/null; then
        exit 0
      fi
      if ! kill -0 "$pid" 2>/dev/null; then
        # Leader gone from kill-0 view — parent residual owns cleanup.
        exit 0
      fi
      st=$(ps -p "$pid" -o state= 2>/dev/null || true)
      if [[ -z "$st" ]]; then
        st=$(ps -p "$pid" -o stat= 2>/dev/null || true)
      fi
      st=$(printf '%s' "$st" | tr -d '[:space:]')
      case "$st" in
        Z*|'')
          # Leader zombie/gone: parent residual owns group sweep.
          exit 0
          ;;
      esac
      sleep 1
      elapsed=$((elapsed + 1))
    done
    # Still alive after wall clock — terminate only this process group.
    # Full TERM grace before KILL (do not short-circuit).
    if kill -0 "$pid" 2>/dev/null; then
      printf 'timeout\n' > "$status_file"
      if [[ $pgrp_ok -eq 1 ]]; then
        kill -TERM -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        # Publish/delay only; still wait the production 1s grace after.
        if [[ -n "${FLEET_WALL_TIMEOUT_TEST_PUBLISH:-}" ]]; then
          printf '1\n' > "${FLEET_WALL_TIMEOUT_TEST_PUBLISH}/in_grace" 2>/dev/null || true
        fi
        if [[ -n "${FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE:-}" ]]; then
          i=0
          while [[ -e "${FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE}" && $i -lt 200 ]]; do
            sleep 0.05 2>/dev/null || sleep 1
            i=$((i + 1))
          done
        fi
        sleep 1
        kill -KILL -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      else
        # No confirmed own-group: exact-PID only (never parent PGID).
        kill -TERM "$pid" 2>/dev/null || true
        if [[ -n "${FLEET_WALL_TIMEOUT_TEST_PUBLISH:-}" ]]; then
          printf '1\n' > "${FLEET_WALL_TIMEOUT_TEST_PUBLISH}/in_grace" 2>/dev/null || true
        fi
        if [[ -n "${FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE:-}" ]]; then
          i=0
          while [[ -e "${FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE}" && $i -lt 200 ]]; do
            sleep 0.05 2>/dev/null || sleep 1
            i=$((i + 1))
          done
        fi
        sleep 1
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
  ) &
  watcher=$!
  _wt_publish before_watcher_track 1
  _wt_hold_path "${FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_WATCHER_TRACK:-}"
  _WT_WATCHER=$watcher
  _wt_publish watcher.pid "$watcher"
  _wt_publish identities.ready 1
  _WT_DEFER_SIGNAL=0
  if [[ "${_WT_CANCEL_RC:-0}" -ne 0 ]]; then
    _wt_drain_deferred_signal || return $?
  fi

  # Poll until leader is reaped-ready (zombie/gone) or timeout is flagged.
  # Bound by wall clock + grace so parent sequencing never hangs forever.
  # Use a tick counter as well as date so a stuck/failed date clock cannot
  # leave this loop unbounded.
  poll=$(date +%s 2>/dev/null || echo 0)
  settle=0
  while true; do
    if [[ "${_WT_CANCEL_RC:-0}" -ne 0 ]]; then
      rc="${_WT_CANCEL_RC}"
      _wt_ordinary_end
      return "$rc"
    fi
    # Sensor-only: after child arms TERM trap (creates <path>), force only the
    # real date or tick branch *precondition* so production ownership body runs.
    # Format: date:<arm_path> | tick:<arm_path>. Never writes timeout, never sets
    # parent_forced, never breaks past the production branches. Unset = inert.
    if [[ -n "${FLEET_WALL_TIMEOUT_TEST_PARENT_FALLBACK:-}" && $pfb_precond -eq 0 ]]; then
      arm_spec="${FLEET_WALL_TIMEOUT_TEST_PARENT_FALLBACK}"
      arm_mode=""
      arm_path=""
      case "$arm_spec" in
        date:?*|tick:?*)
          arm_mode="${arm_spec%%:*}"
          arm_path="${arm_spec#*:}"
          ;;
      esac
      if [[ -n "$arm_mode" && -n "$arm_path" ]]; then
        i=0
        while [[ $i -lt 100 ]]; do
          [[ -f "$arm_path" ]] && break
          if ! kill -0 "$pid" 2>/dev/null; then
            break
          fi
          sleep 0.05 2>/dev/null || sleep 1
          i=$((i + 1))
        done
        if [[ -f "$arm_path" ]] && kill -0 "$pid" 2>/dev/null; then
          case "$arm_mode" in
            date)
              # Force (now - poll) >= (limit + 3) on the date branch below.
              poll=1
              ;;
            tick)
              # Keep date branch false; force tick threshold after settle++ below.
              now_force=$(date +%s 2>/dev/null || echo 0)
              if [[ "$now_force" =~ ^[0-9]+$ && "$now_force" -gt 0 ]]; then
                poll=$now_force
              fi
              settle=$(( (limit + 3) * 10 + 20 ))
              ;;
          esac
          pfb_precond=1
        fi
      fi
    fi
    if [[ -f "$status_file" ]] && grep -q '^timeout$' "$status_file" 2>/dev/null; then
      timed_out=1
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    st=$(ps -p "$pid" -o state= 2>/dev/null || true)
    if [[ -z "$st" ]]; then
      st=$(ps -p "$pid" -o stat= 2>/dev/null || true)
    fi
    st=$(printf '%s' "$st" | tr -d '[:space:]')
    case "$st" in
      Z*|'') break ;;
    esac
    now=$(date +%s 2>/dev/null || echo 0)
    if [[ "$poll" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$now" -gt 0 && "$poll" -gt 0 ]]; then
      # limit + TERM grace (1) + settle slack (2)
      if [[ $((now - poll)) -ge $((limit + 3)) ]]; then
        # Wall clock elapsed from parent view — treat as timeout if status
        # not yet written (watcher race). Parent-owned write means residual
        # must deliver TERM → grace → KILL (watcher may exit on the flag).
        if [[ -f "$status_file" ]] && grep -q '^timeout$' "$status_file" 2>/dev/null; then
          timed_out=1
        elif kill -0 "$pid" 2>/dev/null; then
          printf 'timeout\n' > "$status_file" 2>/dev/null || true
          parent_forced=1
          timed_out=1
        fi
        break
      fi
    fi
    # Tick bound: ~10 polls/sec → (limit+3)*10 + slack, independent of date(1).
    settle=$((settle + 1))
    if [[ $settle -ge $(((limit + 3) * 10 + 20)) ]]; then
      if kill -0 "$pid" 2>/dev/null; then
        # Only claim parent ownership when we are the writer; if the watcher
        # already flagged timeout, leave residual as KILL-only after its grace.
        if [[ -f "$status_file" ]] && grep -q '^timeout$' "$status_file" 2>/dev/null; then
          timed_out=1
        else
          printf 'timeout\n' > "$status_file" 2>/dev/null || true
          parent_forced=1
          timed_out=1
        fi
      fi
      break
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done

  if [[ "${_WT_CANCEL_RC:-0}" -ne 0 ]]; then
    rc="${_WT_CANCEL_RC}"
    _wt_ordinary_end
    return "$rc"
  fi

  if [[ -f "$status_file" ]] && grep -q '^timeout$' "$status_file" 2>/dev/null; then
    timed_out=1
  fi

  # Delay wait/reap only (test hook). Leader may already have exited.
  if [[ $timed_out -eq 0 ]]; then
    _wt_publish leader_exited 1
  fi
  _wt_hold_path "${FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_WAIT:-}"

  if [[ "${_WT_CANCEL_RC:-0}" -ne 0 ]]; then
    rc="${_WT_CANCEL_RC}"
    _wt_ordinary_end
    return "$rc"
  fi

  # Stop/reap the watcher BEFORE wait-reaping the leader so no post-reap PGID
  # signal is possible from the watcher. On timeout, let the watcher finish
  # its full TERM grace + KILL (do not kill it mid-grace). Bound is grace+settle
  # only — never scales with a large configured wall-clock limit.
  if [[ $timed_out -eq 1 ]]; then
    watcher_wait_bound=30   # ~3s at 0.1s polls (grace is 1s + settle)
    i=0
    while kill -0 "$watcher" 2>/dev/null && [[ $i -lt $watcher_wait_bound ]]; do
      if [[ "${_WT_CANCEL_RC:-0}" -ne 0 ]]; then
        rc="${_WT_CANCEL_RC}"
        _wt_ordinary_end
        return "$rc"
      fi
      sleep 0.1 2>/dev/null || sleep 1
      i=$((i + 1))
    done
    # If still alive after bound, stop it without pattern kill.
    if kill -0 "$watcher" 2>/dev/null; then
      kill -TERM "$watcher" 2>/dev/null || true
      sleep 0.05 2>/dev/null || true
      kill -KILL "$watcher" 2>/dev/null || true
    fi
    wait "$watcher" 2>/dev/null || true
    _WT_WATCHER=""
    # Pre-wait residual while leader is still unreaped (no PID/PGID reuse).
    # Parent-forced path: watcher may have exited on the flag without TERM —
    # guarantee TERM → full 1s grace → KILL on exact identity.
    # Watcher-owned path: residual exact KILL only (watcher already graced).
    if [[ $parent_forced -eq 1 ]]; then
      if [[ $pgrp_ok -eq 1 ]]; then
        kill -TERM -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        kill -KILL -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      else
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$pid" 2>/dev/null || true
      fi
    else
      if [[ $pgrp_ok -eq 1 ]]; then
        kill -KILL -"$pgid" 2>/dev/null || true
      else
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
  else
    # Natural exit: stop watcher first so it cannot later timeout-signal.
    kill -TERM "$watcher" 2>/dev/null || true
    sleep 0.05 2>/dev/null || true
    kill -KILL "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    _WT_WATCHER=""
    # Residual exact-PGID cleanup for orphaned descendants BEFORE wait.
    # Only when we confirmed pgid==pid (own group). kill -0 on the leader may
    # already fail on macOS once the leader has exited; the recorded pgid still
    # addresses residual members. Never a pattern kill; never parent PGID.
    if [[ $pgrp_ok -eq 1 ]]; then
      kill -KILL -"$pgid" 2>/dev/null || true
    fi
  fi

  # The guardian must be gone before the wait fence and before normal return.
  # Group cleanup should already have killed it; exact fallback is bounded and
  # uses only the guardian PID obtained from the trusted launcher's ready file.
  _wt_stop_guardian

  # Capture wait status without tripping set -e (killed children are nonzero).
  rc=0
  # Fence the non-atomic wait/latch boundary. A trap during wait may still
  # clean a live child; after wait returns, no stale PID/PGID may be signaled.
  _WT_WAIT_ACTIVE=1
  _WT_WAITED=1
  wait "$pid" 2>/dev/null || rc=$?
  _WT_WAIT_ACTIVE=0
  _wt_publish after_leader_wait 1
  _wt_hold_path "${FLEET_WALL_TIMEOUT_TEST_HOLD_AFTER_LEADER_WAIT:-}"

  if [[ "${_WT_CANCEL_RC:-0}" -ne 0 ]]; then
    rc="${_WT_CANCEL_RC}"
    _wt_ordinary_end
    return "$rc"
  fi

  # Re-check timeout flag after watcher completion (race-safe).
  if [[ -f "$status_file" ]] && grep -q '^timeout$' "$status_file" 2>/dev/null; then
    timed_out=1
  fi

  # No post-wait group kill: the leader PID/PGID may already be recycled.

  if [[ $timed_out -eq 1 ]]; then
    _wt_ordinary_end
    return 124
  fi
  _wt_ordinary_end
  return "$rc"
}
