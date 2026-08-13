#!/usr/bin/env bash
# silent-noop.sh — L-008 progress sensor for solo-loop drivers (issue #18 / #63)
#
# Source this from loop.sh (or any driver). It detects whether gibson/loop-state.md
# advanced between iterations. Exit-code budgets only catch crashes; this catches
# "runner exited 0 and did nothing" (L-008).
#
# WHY IT FINGERPRINTS WHAT IT DOES
#   The failure this exists to catch is a runner that looks healthy while doing
#   nothing. `updated:` is a clock, not progress: playbooks/loop-step.md tells every
#   hat to stamp a UTC timestamp when it rewrites loop-state, so a runner that
#   narrates its instructions and stamps the clock would reset the streak forever
#   and the budget would never trip — the sensor would certify exactly the L-008
#   run it was written to stop. So the fingerprint covers the *substantive* state
#   (issue, pr, hat, next_hat, round, parked, handoff, next_action, notes, …) and
#   deliberately excludes only the column-zero `updated:` line.
#
#   Every other path fails closed. A state file that is missing, unreadable,
#   a symlink/directory/device, or un-hashable yields a constant sentinel rather
#   than an empty string, so stagnation still accrues. An empty fingerprint would
#   silently disable the sensor for the rest of the run.
#
# Preferred driver API (stateless — issue #63):
#   source "$SCRIPT_DIR/silent-noop.sh"
#   if silent_noop_progressed "$STATE_SNAPSHOT" "$STATE_FILE"; then
#     # substantive progress — reset budgets, may hand off
#   else
#     # no-progress (including clock-only updated: rewrites)
#   fi
#
# Legacy streak API (stateful — still supported for out-of-tree drivers):
#   STATE_FILE=... silent_noop_init ; silent_noop_check
#
# silent_noop_check returns 1 when the budget is exhausted; the driver decides how
# loudly to die. It never exits on the caller's behalf.
#
# Env (legacy streak API only):
#   NOOP_BUDGET   consecutive stagnant iterations before hard fail (default 3)

# Named `silent_noop_usage`, not the sibling scripts' bare `usage`, because this
# file is sourced into the driver's own namespace and loop.sh already defines a
# `usage`. A library that silently replaces its caller's function is the same
# class of bug this sensor exists to catch.
silent_noop_usage() {
  cat <<'EOF'
silent-noop.sh — L-008 progress sensor for solo-loop drivers (sourceable library)

WHAT I'M ASKING
  Nothing, if you ran this by hand — there is no command here to run. This file
  is meant to be `source`d by a loop driver so the driver can ask, once per
  iteration, "did the runner actually move gibson/loop-state.md?"

WHAT IT DOES
  Defines shell functions in the caller's shell:

    silent_noop_progressed BEFORE AFTER
                            preferred, stateless API (issue #63 / loop.sh):
                            return 0 if substantive state advanced between the
                            two files, 1 if not (including fail-closed cases)
    silent_noop_init        legacy streak seed (once, at driver startup)
    silent_noop_check       legacy streak compare (once per iteration)
    _silent_noop_fp [PATH]  internal — print a fingerprint of PATH (or $STATE_FILE)

  The fingerprint covers the substantive loop state and deliberately EXCLUDES
  only the column-zero `updated:` line. Clock-only rewrites are no-progress.
  Missing, unreadable, symlink, directory, device, or un-hashable inputs never
  count as progress. A digest transition to `sentinel:unhashable` fails closed.

  Wired into scripts/loop.sh (issue #63): after a valid post-run state and
  runner exit 0, the driver compares the exact pre-run snapshot
  (gibson/.loop-state.prev) to live loop-state via silent_noop_progressed.
  No-progress journals once, increments the shared failure budget and the
  --stale-budget counter once each, and does not reset, restore, or hand off.

WHY
  Exit-code budgets only catch crashes. They cannot see the failure this exists
  for: a runner that exits 0 and does nothing (L-008), burning iterations while
  the harness reports health.

  `updated:` is a clock, not progress — playbooks/loop-step.md tells every hat to
  stamp a UTC timestamp when it rewrites loop-state, so a runner that narrates
  its instructions and stamps the clock would reset the streak forever. Hashing
  that line would make this sensor certify exactly the run it was written to stop.

RISKS
  - Read-only. It reads the given paths / $STATE_FILE and writes nothing but
    stderr warnings.
  - It fails CLOSED, on purpose: a state file that is missing, unreadable,
    un-hashable, or an unsafe path shape yields a constant sentinel, so the
    streak keeps accruing and silent_noop_progressed reports no progress.
    Expect a trip — not a silent pass — from a mis-set path. That is the design;
    an empty fingerprint would disable the sensor for the rest of the run.
  - A false trip stops a loop that was in fact working. The fix is to correct the
    runner or its permissions. Do NOT raise NOOP_BUDGET / --stale-budget to quiet
    it — that only restores the fail-open behaviour this replaces.
  - Running this file directly does nothing and is therefore a usage error (exit
    2), never a quiet exit 0.

USAGE
  # preferred (loop.sh / issue #63):
  source /path/to/the-gibson/scripts/silent-noop.sh
  silent_noop_progressed /path/to/.loop-state.prev /path/to/loop-state.md

  # legacy streak API:
  source /path/to/the-gibson/scripts/silent-noop.sh
  silent_noop_init
  while run_one_iteration; do
    silent_noop_check || { echo "runner is not advancing loop-state" >&2; exit 1; }
  done

  silent-noop.sh --help      # this text (the only direct invocation that works)

ENV
  NOOP_BUDGET   consecutive stagnant iterations before silent_noop_check returns 1.
                Default 3. Must be a positive integer: `[[ x -ge $NOOP_BUDGET ]]`
                is an arithmetic context, so anything else is both a nonsense
                budget and a command-substitution surface. An invalid value is
                rejected with a warning and replaced by 3.
                (Not used by silent_noop_progressed — the driver owns budgets.)
  STATE_FILE    path used by the legacy streak API when _silent_noop_fp is called
                with no argument. Read at every check, so the driver may set it
                after sourcing.

EXAMPLES
  # inside a driver (issue #63 wiring)
  SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  source "$SCRIPT_DIR/silent-noop.sh"
  if silent_noop_progressed "$STATE_SNAPSHOT" "$STATE_FILE"; then
    failures=0; stale=0
  else
    # journal no-progress; increment failures and stale once each
    :
  fi

  # legacy streak with a tighter budget
  NOOP_BUDGET=2 driver.sh

EXIT (direct invocation only)
  0  --help / -h printed this text
  2  anything else — this is a library; there is nothing to execute
EOF
}

# Sourced or executed? Decided by whether `return` is legal, NOT by comparing
# ${BASH_SOURCE[0]} to "$0". $0 is whatever the caller says it is — `bash -c
# 'source "$0"' /path/to/silent-noop.sh` is a genuine SOURCE whose $0 is this
# very file, and the harness used to invoke it exactly that way. That comparison
# would call it a direct run and exit 2 in the middle of a sourced test. `return`
# succeeds only inside a sourced file or a function, and no caller can spoof it.
#
# Sourcing must stay silent; a direct run must fail loudly. A library that exits
# 0 having done nothing is precisely the silent success this sensor is for.
if ! (return 0 2>/dev/null); then
  case "${1:-}" in
    -h|--help)
      silent_noop_usage
      exit 0
      ;;
    "")
      echo "silent-noop: ERROR: nothing to run — this file is a sourceable library, not a command." >&2
      echo "silent-noop: source it from your loop driver, or run 'silent-noop.sh --help'." >&2
      silent_noop_usage >&2
      exit 2
      ;;
    *)
      echo "silent-noop: ERROR: unknown argument '$1' — this file is a sourceable library, not a command." >&2
      echo "silent-noop: source it from your loop driver, or run 'silent-noop.sh --help'." >&2
      silent_noop_usage >&2
      exit 2
      ;;
  esac
fi

# A budget is only meaningful as a positive integer. `[[ x -ge $NOOP_BUDGET ]]`
# evaluates its operands as arithmetic, so an unvalidated value is both a nonsense
# budget (`abc` resolves to 0 and trips on the first stagnant iteration) and a
# command-substitution surface (`x[$(...)]` runs). Validate once, at source time.
if [[ ! ${NOOP_BUDGET:-3} =~ ^[1-9][0-9]*$ ]]; then
  echo "silent-noop: WARNING: ignoring invalid NOOP_BUDGET='${NOOP_BUDGET:-}' (want a positive integer); using 3" >&2
  NOOP_BUDGET=3
else
  NOOP_BUDGET="${NOOP_BUDGET:-3}"
fi

_silent_noop_streak=0
_silent_noop_last=""
_silent_noop_ready=0

# Print a fingerprint of the substantive loop state. Always prints something
# non-empty, always returns 0.
#
# Optional path argument: _silent_noop_fp [PATH]
#   When PATH is given, fingerprint that file (stateless API).
#   When omitted, use $STATE_FILE (legacy streak API).
#
# Path hostility: treat symlink / directory / device / missing / unreadable as
# distinct fail-closed sentinels. Never follow a symlink leaf (-L before -f).
_silent_noop_fp() {
  local file body digest
  if [[ $# -ge 1 ]]; then
    file="$1"
  else
    file="${STATE_FILE:-}"
  fi
  if [[ -z "$file" ]]; then
    printf 'sentinel:absent'
    return 0
  fi
  # Symlink leaf: refuse without following (even if the target is a regular file).
  if [[ -L "$file" ]]; then
    printf 'sentinel:symlink'
    return 0
  fi
  if [[ -d "$file" ]]; then
    printf 'sentinel:directory'
    return 0
  fi
  if [[ ! -f "$file" ]]; then
    if [[ -e "$file" ]]; then
      printf 'sentinel:special'
    else
      printf 'sentinel:absent'
    fi
    return 0
  fi
  if [[ ! -r "$file" ]]; then
    printf 'sentinel:unreadable'
    return 0
  fi

  # Drop only the column-zero `updated:` clock line; hash everything else.
  # Extraction/normalization failure is unhashable immediately: never fall back to
  # an empty (or partial) body and mint a real `state:*` digest from it. That would
  # fail open when only one side's awk failed (empty digest ≠ real digest → "progress"
  # → budget reset / handoff on unhashable AFTER). A successful awk that yields a
  # legitimately empty body (file is only clock lines) still hashes below.
  if ! body=$(awk '!/^updated:/' "$file" 2>/dev/null); then
    printf 'sentinel:unhashable'
    return 0
  fi

  # Every digest assignment ends in `|| digest=""`. The driver sources this under
  # `set -euo pipefail`, and a hash binary that *exists but fails* (broken install,
  # sandbox denial, exhausted fd/memory) makes the pipeline non-zero under pipefail.
  # A bare assignment would then abort the caller before the sentinel below is ever
  # printed — the sensor would take the loop down instead of failing closed. Collapse
  # to an empty digest and let `sentinel:unhashable` stand. Deliberately no byte-count
  # fallback here: `wc -c` cannot see `round: 1` become `round: 2`, so it would report
  # stagnation as progress — fail-open, the one thing this sensor may never do.
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s\n' "$body" | sha256sum 2>/dev/null | awk '{print $1}') || digest=""
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s\n' "$body" | shasum -a 256 2>/dev/null | awk '{print $1}') || digest=""
  else
    # POSIX fallback. Weaker than a digest but still content-sensitive, unlike a
    # byte count, which cannot see `round: 1` become `round: 2`.
    digest=$(printf '%s\n' "$body" | cksum 2>/dev/null | awk '{print $1 "-" $2}') || digest=""
  fi

  if [[ -z "$digest" ]]; then
    printf 'sentinel:unhashable'
  else
    printf 'state:%s' "$digest"
  fi
  return 0
}

# Stateless progress check (issue #63). Return 0 if substantive state advanced
# from BEFORE to AFTER; return 1 for no-progress and every fail-closed case.
#
# Progress requires BOTH paths to fingerprint as real digests (`state:…`) AND
# those digests to differ. Any sentinel on either side — including a transition
# from a working digest to `sentinel:unhashable` — is no-progress (never "changed").
# Does not read or write library-private streak globals; loop.sh owns counters.
silent_noop_progressed() {
  local before after fb fa
  if [[ $# -ne 2 ]]; then
    echo "silent-noop: WARNING: silent_noop_progressed requires exactly two paths (BEFORE AFTER)" >&2
    return 1
  fi
  before="$1"
  after="$2"
  fb=$(_silent_noop_fp "$before")
  fa=$(_silent_noop_fp "$after")

  case "$fb" in
    state:*) ;;
    *) return 1 ;;
  esac
  case "$fa" in
    state:*) ;;
    *) return 1 ;;
  esac

  if [[ "$fb" == "$fa" ]]; then
    return 1
  fi
  return 0
}

silent_noop_init() {
  _silent_noop_streak=0
  _silent_noop_last=$(_silent_noop_fp)
  _silent_noop_ready=1
  return 0
}

silent_noop_check() {
  local now
  now=$(_silent_noop_fp)

  # Seed on first use even if the driver forgot to call silent_noop_init, but say
  # so — a silently self-seeding sensor hides a wiring bug.
  if [[ $_silent_noop_ready -eq 0 ]]; then
    echo "silent-noop: WARNING: silent_noop_check called before silent_noop_init; seeding now" >&2
    _silent_noop_last="$now"
    _silent_noop_ready=1
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
