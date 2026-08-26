#!/usr/bin/env bash
# wall-timeout.sh — sourceable: run_with_wall_timeout <secs> <cmd...>
# Runs a command under a wall-clock cap and kills its WHOLE process tree on
# expiry (perl/python setpgrp), returning 124 on timeout. A naive kill leaks
# orphaned children (verified) — this is the hardened version.
# ORIGIN: scripts/loop-fleet.sh's run_with_wall_timeout, with ONE deliberate change:
# the backgrounded runner is launched with `<&0` so the caller's stdin reaches it.
# A backgrounded process in a non-interactive shell otherwise gets /dev/null stdin,
# which would starve loop.sh's stdin-fed runners (claude/codex/hermes read the prompt
# from stdin). The change is a no-op for loop-fleet.sh's callers (they feed no stdin).
# TODO(dedupe): loop-fleet.sh should source this too (and inherit the stdin fix);
#   kept as a copy for now to avoid destabilizing that proven file in this PR.

run_with_wall_timeout() {
  local limit="$1"
  shift
  local pid watcher rc=0 status_file timed_out=0 st poll now pgid
  local elapsed watcher_wait_bound i settle pgrp_ok=0 cand pgrp_ready arm_path
  local arm_spec arm_mode pfb_precond=0 now_force
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

  status_file=$(mktemp "${TMPDIR:-/tmp}/fleet-wall.XXXXXX") || return 1
  # Marker written by the child *after* setpgrp and *before* exec so a
  # fast-exiting leader still proves own-group leadership (pgid == pid).
  # Never signal a PGID unless this marker confirms setpgrp ran for $pid.
  pgrp_ready=$(mktemp "${TMPDIR:-/tmp}/fleet-pgrp.XXXXXX") || {
    rm -f "$status_file"
    return 1
  }

  # Become process-group leader so we can terminate only this tree.
  # Ready-file protocol: child writes its pid after setpgrp, then execs.
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      setpgrp(0,0);
      my $rf = $ARGV[0];
      if (open my $fh, ">", $rf) { print $fh "$$\n"; close $fh; }
      exec { $ARGV[1] } @ARGV[1..$#ARGV] or exit 127;
    ' "$pgrp_ready" "$@" <&0 &
    pid=$!
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os, sys
os.setpgrp()
rf = sys.argv[1]
try:
    with open(rf, "w") as f:
        f.write("%d\n" % os.getpid())
except Exception:
    pass
os.execvp(sys.argv[2], sys.argv[2:])
' "$pgrp_ready" "$@" <&0 &
    pid=$!
  else
    # Unreachable: guarded above. Keep as hard fail-closed, never bare child.
    echo "fleet: wall-timeout process-group mechanism vanished before launch" >&2
    rm -f "$status_file" "$pgrp_ready"
    return 1
  fi

  # Wait for setpgrp proof (ready file contains exact leader pid). Reading
  # ps pgid too early returns the *parent* shell's group — never signal that.
  pgid=$pid
  pgrp_ok=0
  settle=0
  while [[ $settle -lt 100 ]]; do
    if [[ -s "$pgrp_ready" ]]; then
      cand=$(tr -d '[:space:]' < "$pgrp_ready" 2>/dev/null || true)
      if [[ "$cand" == "$pid" ]]; then
        pgid=$pid
        pgrp_ok=1
        break
      fi
    fi
    # Also accept ps-visible own-group while still live (ready file races).
    if kill -0 "$pid" 2>/dev/null; then
      cand=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]' || true)
      if [[ "$cand" == "$pid" ]]; then
        pgid=$pid
        pgrp_ok=1
        break
      fi
    elif [[ -s "$pgrp_ready" ]]; then
      cand=$(tr -d '[:space:]' < "$pgrp_ready" 2>/dev/null || true)
      if [[ "$cand" == "$pid" ]]; then
        pgid=$pid
        pgrp_ok=1
        break
      fi
      break
    elif [[ $settle -gt 5 ]]; then
      # Process gone and no ready marker — cannot safely group-signal.
      break
    fi
    sleep 0.01 2>/dev/null || true
    settle=$((settle + 1))
  done
  rm -f "$pgrp_ready"

  # Watcher: wall-clock bound. On expiry: TERM → full 1s grace → KILL, exact
  # PGID only when pgrp_ok. On natural leader exit the watcher exits without
  # signaling so the parent residual path owns orphan cleanup (and ordering).
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
        sleep 1
        kill -KILL -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      else
        # No confirmed own-group: exact-PID only (never parent PGID).
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
  ) &
  watcher=$!

  # Poll until leader is reaped-ready (zombie/gone) or timeout is flagged.
  # Bound by wall clock + grace so parent sequencing never hangs forever.
  # Use a tick counter as well as date so a stuck/failed date clock cannot
  # leave this loop unbounded.
  poll=$(date +%s 2>/dev/null || echo 0)
  settle=0
  while true; do
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

  if [[ -f "$status_file" ]] && grep -q '^timeout$' "$status_file" 2>/dev/null; then
    timed_out=1
  fi

  # Stop/reap the watcher BEFORE wait-reaping the leader so no post-reap PGID
  # signal is possible from the watcher. On timeout, let the watcher finish
  # its full TERM grace + KILL (do not kill it mid-grace). Bound is grace+settle
  # only — never scales with a large configured wall-clock limit.
  if [[ $timed_out -eq 1 ]]; then
    watcher_wait_bound=30   # ~3s at 0.1s polls (grace is 1s + settle)
    i=0
    while kill -0 "$watcher" 2>/dev/null && [[ $i -lt $watcher_wait_bound ]]; do
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
    # Residual exact-PGID cleanup for orphaned descendants BEFORE wait.
    # Only when we confirmed pgid==pid (own group). kill -0 on the leader may
    # already fail on macOS once the leader has exited; the recorded pgid still
    # addresses residual members. Never a pattern kill; never parent PGID.
    if [[ $pgrp_ok -eq 1 ]]; then
      kill -KILL -"$pgid" 2>/dev/null || true
    fi
  fi

  # Capture wait status without tripping set -e (killed children are nonzero).
  rc=0
  wait "$pid" 2>/dev/null || rc=$?

  # Re-check timeout flag after watcher completion (race-safe).
  if [[ -f "$status_file" ]] && grep -q '^timeout$' "$status_file" 2>/dev/null; then
    timed_out=1
  fi
  rm -f "$status_file"

  # No post-wait group kill: the leader PID/PGID may already be recycled.

  if [[ $timed_out -eq 1 ]]; then
    return 124
  fi
  return "$rc"
}
