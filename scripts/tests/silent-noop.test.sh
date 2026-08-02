#!/usr/bin/env bash
# silent-noop.test.sh — sensors for the L-008 progress sensor (issue #18)
#
# WHY
#   This sensor's whole job is to refuse to certify a runner that exits 0 and does
#   nothing. Every bug in it is therefore a fail-OPEN bug: the loop keeps burning
#   iterations and the harness reports health. These cases pin the ways it must
#   still trip — a clock-only "update", an unreadable or missing state file, a
#   garbage budget — and the one way it must stay quiet: real progress.
#
# USAGE
#   scripts/tests/silent-noop.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SENSOR="$SCRIPT_DIR/../silent-noop.sh"
PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-noop-test.XXXXXX")
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

# The real schema loop.sh writes (scripts/loop.sh, "# Gibson loop state").
write_state() { # file updated_ts extra_line
  cat > "$1" <<EOF
# Gibson loop state
updated: $2
issue:
pr:
hat: builder
next_hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: ${3:-triage highest-priority unblocked unclaimed issue}
notes: initialized by loop.sh
EOF
}

# Each scenario runs in its own bash so sourced state never leaks between cases.
# Prints one line per iteration: "PASS" (sensor allowed it) or "TRIP".
run_case() { # budget setup_body iteration_body iterations
  env NOOP_BUDGET="$1" bash -c '
    set -uo pipefail
    source "$0"
    STATE="$1"
    eval "$2"
    silent_noop_init
    for i in $(seq 1 "$4"); do
      eval "$3"
      if silent_noop_check 2>/dev/null; then echo PASS; else echo TRIP; fi
    done
  ' "$SENSOR" "$ROOT/loop-state.md" "$2" "$3" "$4"
}

echo "the L-008 failure mode itself"
# A runner that narrates its instructions and stamps the clock is doing nothing.
out=$(run_case 3 \
  'STATE_FILE="$STATE"; write_state() { :; }; printf "# Gibson loop state\nupdated: 2026-08-02T00:00:00Z\nhat: builder\nround: 0\n" > "$STATE"' \
  'printf "# Gibson loop state\nupdated: 2026-08-02T00:00:0${i}Z\nhat: builder\nround: 0\n" > "$STATE"' \
  5)
if echo "$out" | grep -q TRIP; then
  ok "a clock-only 'update' still trips the budget"
else
  bad "clock-only update never trips — sensor certifies an L-008 run ($(echo "$out" | tr '\n' ' '))"
fi
[[ "$(echo "$out" | grep -c TRIP)" -ge 1 && "$(echo "$out" | head -3 | grep -c PASS)" -eq 2 ]] \
  && ok "trips on the 3rd stagnant iteration, not before" \
  || bad "wrong trip point ($(echo "$out" | tr '\n' ' '))"

echo
echo "real progress keeps the loop running"
out=$(run_case 3 \
  'STATE_FILE="$STATE"; printf "# Gibson loop state\nupdated: t\nhat: builder\nround: 0\n" > "$STATE"' \
  'printf "# Gibson loop state\nupdated: t\nhat: builder\nround: %s\n" "$i" > "$STATE"' \
  5)
if echo "$out" | grep -q TRIP; then
  bad "advancing state wrongly tripped ($(echo "$out" | tr '\n' ' '))"
else
  ok "advancing round= never trips"
fi
# Same byte count, different content — the case a `wc -c` fingerprint cannot see.
out=$(run_case 2 \
  'STATE_FILE="$STATE"; printf "hat: builder\nround: 1\n" > "$STATE"' \
  'printf "hat: builder\nround: %s\n" "$((i + 1))" > "$STATE"' \
  4)
echo "$out" | grep -q TRIP \
  && bad "same-length content change read as stagnation ($(echo "$out" | tr '\n' ' '))" \
  || ok "same-length content change counts as progress"

echo
echo "fails closed when it cannot read the state"
out=$(run_case 2 'STATE_FILE="$STATE"; rm -f "$STATE"' ':' 4)
echo "$out" | grep -q TRIP \
  && ok "a missing state file trips" \
  || bad "missing state file never trips ($(echo "$out" | tr '\n' ' '))"

out=$(run_case 2 \
  'STATE_FILE="$STATE"; printf "hat: builder\n" > "$STATE"; chmod 000 "$STATE"' ':' 4)
echo "$out" | grep -q TRIP \
  && ok "an unreadable state file trips" \
  || bad "unreadable state file never trips — sensor silently disabled ($(echo "$out" | tr '\n' ' '))"
chmod 644 "$ROOT/loop-state.md" 2>/dev/null

out=$(run_case 2 'STATE_FILE=""' ':' 4)
echo "$out" | grep -q TRIP \
  && ok "an unset STATE_FILE trips" \
  || bad "unset STATE_FILE never trips ($(echo "$out" | tr '\n' ' '))"

echo
echo "the budget is a positive integer or it is the default"
# `[[ x -ge $NOOP_BUDGET ]]` is an arithmetic context: an unvalidated value can run
# commands. Assert on a filesystem side-effect, not on the text — the rejection
# warning quotes the offending value back, so the payload appears either way.
rm -f "$ROOT/pwned"
out=$(env NOOP_BUDGET="x[\$(touch '$ROOT/pwned')]" bash -c '
  source "$0"
  STATE_FILE="$1"; printf "hat: builder\n" > "$STATE_FILE"
  silent_noop_init
  silent_noop_check; silent_noop_check; silent_noop_check; silent_noop_check
  echo "budget=$NOOP_BUDGET"' "$SENSOR" "$ROOT/loop-state.md" 2>&1)
[[ -e "$ROOT/pwned" ]] \
  && bad "NOOP_BUDGET was evaluated as arithmetic — command substitution ran" \
  || ok "a command-substitution NOOP_BUDGET does not execute"
echo "$out" | grep -q 'budget=3' \
  && ok "invalid NOOP_BUDGET falls back to 3" \
  || bad "invalid NOOP_BUDGET did not fall back ($out)"

for badval in 0 -1 abc '2x' ' '; do
  out=$(env NOOP_BUDGET="$badval" bash -c 'source "$0"; echo "$NOOP_BUDGET"' "$SENSOR" 2>/dev/null)
  [[ "$out" == "3" ]] && ok "rejects NOOP_BUDGET='$badval'" || bad "accepted NOOP_BUDGET='$badval' (got $out)"
done
out=$(env NOOP_BUDGET=7 bash -c 'source "$0"; echo "$NOOP_BUDGET"' "$SENSOR" 2>/dev/null)
[[ "$out" == "7" ]] && ok "honours a valid NOOP_BUDGET" || bad "mangled a valid NOOP_BUDGET (got $out)"

echo
echo "it survives the driver's shell settings"
# loop.sh runs under `set -euo pipefail`; a sensor that returns non-zero from its
# fingerprint helper would kill the driver mid-iteration.
write_state "$ROOT/strict.md" "2026-08-02T00:00:00Z"
out=$(env -u NOOP_BUDGET bash -c '
  set -euo pipefail
  source "$0"
  STATE_FILE="$1"
  silent_noop_init
  silent_noop_check && echo SURVIVED
' "$SENSOR" "$ROOT/strict.md" 2>&1)
echo "$out" | grep -q SURVIVED \
  && ok "clean iteration under set -euo pipefail" \
  || bad "died under set -euo pipefail ($out)"

echo
echo "a hash command that exists but fails cannot take the driver down"
# The digest assignments are the last place this sensor can fail OPEN in a way the
# other cases miss. Under `set -euo pipefail` a hasher that exists but exits
# non-zero makes the pipeline non-zero (pipefail), so a bare assignment would abort
# the caller *before* the sentinel is printed: instead of failing closed the sensor
# kills the loop it was supposed to measure. Shadow all three candidates so whichever
# one this platform selects is the broken one.
FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
for hasher in sha256sum shasum cksum; do
  printf '#!/bin/sh\nexit 7\n' > "$FAKEBIN/$hasher"
  chmod +x "$FAKEBIN/$hasher"
done
write_state "$ROOT/nohash.md" "2026-08-02T00:00:00Z"

# Control: with a working hasher the same state fingerprints as a real digest, so a
# `sentinel:unhashable` below is the shadow's doing and not some unrelated breakage.
out=$(bash -c 'source "$0"; STATE_FILE="$1"; _silent_noop_fp' "$SENSOR" "$ROOT/nohash.md" 2>&1)
[[ "$out" == state:* ]] \
  && ok "control: a working hasher still yields state:<digest>" \
  || bad "control case did not produce a digest (got '$out')"

# Called directly rather than through `$(...)`: bash 3.2 swallows a `set -e` abort
# raised inside a command substitution, so exercising this only through
# silent_noop_check would pass on macOS and kill the driver on CI's bash 5.
out=$(PATH="$FAKEBIN:$PATH" bash -c '
  set -euo pipefail
  source "$0"
  STATE_FILE="$1"
  _silent_noop_fp
  printf " SURVIVED"
' "$SENSOR" "$ROOT/nohash.md" 2>&1)
[[ "$out" == "sentinel:unhashable SURVIVED" ]] \
  && ok "a failing hasher yields sentinel:unhashable and returns 0" \
  || bad "failing hasher killed _silent_noop_fp or changed its output (got '$out')"

out=$(PATH="$FAKEBIN:$PATH" bash -c '
  set -euo pipefail
  source "$0"
  STATE_FILE="$1"
  silent_noop_init
  silent_noop_check && printf SURVIVED
' "$SENSOR" "$ROOT/nohash.md" 2>/dev/null)
[[ "$out" == "SURVIVED" ]] \
  && ok "init + check survive a failing hasher under set -euo pipefail" \
  || bad "a failing hasher killed the driver mid-iteration (got '$out')"

# The state file changes every iteration and the budget must still trip: an
# un-hashable state is stagnation the sensor cannot see through, so it accrues
# instead of re-seeding forever. This is also what pins the absence of a byte-count
# or raw-content fallback — either would read these writes as progress and fail open.
out=$(NOOP_BUDGET=2 PATH="$FAKEBIN:$PATH" bash -c '
  set -uo pipefail
  source "$0"
  STATE_FILE="$1"
  silent_noop_init
  for i in 1 2 3; do
    printf "hat: builder\nround: %s\n" "$i" > "$STATE_FILE"
    if silent_noop_check 2>/dev/null; then echo PASS; else echo TRIP; fi
  done
' "$SENSOR" "$ROOT/nohash.md")
[[ "$(echo "$out" | head -1)" == PASS && "$(echo "$out" | grep -c TRIP)" -ge 1 ]] \
  && ok "repeated un-hashable state accrues and trips NOOP_BUDGET" \
  || bad "un-hashable state never trips the budget ($(echo "$out" | tr '\n' ' '))"

echo
echo "it does not wire itself into the driver"
# The wiring is a deliberate follow-up; this pins that the PR did not sneak it in.
grep -q 'silent-noop' "$SCRIPT_DIR/../loop.sh" \
  && bad "loop.sh references silent-noop — wiring is a separate change" \
  || ok "loop.sh is untouched by this sensor"

echo
echo "silent-noop.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
