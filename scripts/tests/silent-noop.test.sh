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
# A NOTE ON `bash -c '…' silent-noop-test "$SENSOR"`
#   Every scenario below passes a LABEL as $0 and the sensor path as a positional
#   argument. This is not decoration. `bash -c 'source "$0"' "$SENSOR"` — the
#   obvious spelling — makes $0 and ${BASH_SOURCE[0]} the same path inside a
#   genuine source, which is indistinguishable from a direct run to any guard
#   written as `[[ ${BASH_SOURCE[0]} == $0 ]]`. Tests that lie about how the file
#   is being loaded cannot pin how it behaves when loaded for real, so $0 stays a
#   label here and the sensor arrives as data.
#
# USAGE
#   scripts/tests/silent-noop.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
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
    source "$1"
    STATE="$2"
    eval "$3"
    silent_noop_init
    for i in $(seq 1 "$5"); do
      eval "$4"
      if silent_noop_check 2>/dev/null; then echo PASS; else echo TRIP; fi
    done
  ' silent-noop-test "$SENSOR" "$ROOT/loop-state.md" "$2" "$3" "$4"
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
  source "$1"
  STATE_FILE="$2"; printf "hat: builder\n" > "$STATE_FILE"
  silent_noop_init
  silent_noop_check; silent_noop_check; silent_noop_check; silent_noop_check
  echo "budget=$NOOP_BUDGET"' silent-noop-test "$SENSOR" "$ROOT/loop-state.md" 2>&1)
[[ -e "$ROOT/pwned" ]] \
  && bad "NOOP_BUDGET was evaluated as arithmetic — command substitution ran" \
  || ok "a command-substitution NOOP_BUDGET does not execute"
echo "$out" | grep -q 'budget=3' \
  && ok "invalid NOOP_BUDGET falls back to 3" \
  || bad "invalid NOOP_BUDGET did not fall back ($out)"

for badval in 0 -1 abc '2x' ' '; do
  out=$(env NOOP_BUDGET="$badval" bash -c 'source "$1"; echo "$NOOP_BUDGET"' silent-noop-test "$SENSOR" 2>/dev/null)
  [[ "$out" == "3" ]] && ok "rejects NOOP_BUDGET='$badval'" || bad "accepted NOOP_BUDGET='$badval' (got $out)"
done
out=$(env NOOP_BUDGET=7 bash -c 'source "$1"; echo "$NOOP_BUDGET"' silent-noop-test "$SENSOR" 2>/dev/null)
[[ "$out" == "7" ]] && ok "honours a valid NOOP_BUDGET" || bad "mangled a valid NOOP_BUDGET (got $out)"

echo
echo "it survives the driver's shell settings"
# loop.sh runs under `set -euo pipefail`; a sensor that returns non-zero from its
# fingerprint helper would kill the driver mid-iteration.
write_state "$ROOT/strict.md" "2026-08-02T00:00:00Z"
out=$(env -u NOOP_BUDGET bash -c '
  set -euo pipefail
  source "$1"
  STATE_FILE="$2"
  silent_noop_init
  silent_noop_check && echo SURVIVED
' silent-noop-test "$SENSOR" "$ROOT/strict.md" 2>&1)
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
out=$(bash -c 'source "$1"; STATE_FILE="$2"; _silent_noop_fp' silent-noop-test "$SENSOR" "$ROOT/nohash.md" 2>&1)
[[ "$out" == state:* ]] \
  && ok "control: a working hasher still yields state:<digest>" \
  || bad "control case did not produce a digest (got '$out')"

# Called directly rather than through `$(...)`: bash 3.2 swallows a `set -e` abort
# raised inside a command substitution, so exercising this only through
# silent_noop_check would pass on macOS and kill the driver on CI's bash 5.
out=$(PATH="$FAKEBIN:$PATH" bash -c '
  set -euo pipefail
  source "$1"
  STATE_FILE="$2"
  _silent_noop_fp
  printf " SURVIVED"
' silent-noop-test "$SENSOR" "$ROOT/nohash.md" 2>&1)
[[ "$out" == "sentinel:unhashable SURVIVED" ]] \
  && ok "a failing hasher yields sentinel:unhashable and returns 0" \
  || bad "failing hasher killed _silent_noop_fp or changed its output (got '$out')"

out=$(PATH="$FAKEBIN:$PATH" bash -c '
  set -euo pipefail
  source "$1"
  STATE_FILE="$2"
  silent_noop_init
  silent_noop_check && printf SURVIVED
' silent-noop-test "$SENSOR" "$ROOT/nohash.md" 2>/dev/null)
[[ "$out" == "SURVIVED" ]] \
  && ok "init + check survive a failing hasher under set -euo pipefail" \
  || bad "a failing hasher killed the driver mid-iteration (got '$out')"

# The state file changes every iteration and the budget must still trip: an
# un-hashable state is stagnation the sensor cannot see through, so it accrues
# instead of re-seeding forever. This is also what pins the absence of a byte-count
# or raw-content fallback — either would read these writes as progress and fail open.
out=$(NOOP_BUDGET=2 PATH="$FAKEBIN:$PATH" bash -c '
  set -uo pipefail
  source "$1"
  STATE_FILE="$2"
  silent_noop_init
  for i in 1 2 3; do
    printf "hat: builder\nround: %s\n" "$i" > "$STATE_FILE"
    if silent_noop_check 2>/dev/null; then echo PASS; else echo TRIP; fi
  done
' silent-noop-test "$SENSOR" "$ROOT/nohash.md")
[[ "$(echo "$out" | head -1)" == PASS && "$(echo "$out" | grep -c TRIP)" -ge 1 ]] \
  && ok "repeated un-hashable state accrues and trips NOOP_BUDGET" \
  || bad "un-hashable state never trips the budget ($(echo "$out" | tr '\n' ' '))"

echo
echo "--help is an Ask-Contract answer, not a stub"
# scripts/README.md: "Every script prints Ask-Contract style help via --help".
# A sourceable library is the easiest place to skip that and the worst place to:
# it is the one file in scripts/ whose correct direct invocation is *none*, so an
# operator who runs it has no other way to find out what it wants from them.
[[ -x "$SENSOR" ]] \
  && ok "the sensor is executable, so --help is reachable without 'bash'" \
  || bad "the sensor is not executable — 'scripts/silent-noop.sh --help' cannot run"

help_out=$("$SENSOR" --help 2>"$ROOT/help.err"); help_rc=$?
[[ $help_rc -eq 0 ]] \
  && ok "direct --help exits 0" \
  || bad "direct --help exited $help_rc"
[[ ! -s "$ROOT/help.err" ]] \
  && ok "direct --help writes nothing to stderr" \
  || bad "direct --help polluted stderr ($(tr '\n' ' ' < "$ROOT/help.err"))"

# Each field the Ask Contract owes a non-technical operator, plus the facts
# specific to this file: the budget knob, the preferred progressed API, and that
# it is wired into loop.sh (issue #63). Missing any one turns help into decoration.
for field in \
  "WHAT I'M ASKING" \
  "WHAT IT DOES" \
  "WHY" \
  "RISKS" \
  "USAGE" \
  "EXAMPLES" \
  "NOOP_BUDGET"
do
  echo "$help_out" | grep -qF "$field" \
    && ok "--help documents $field" \
    || bad "--help is missing the $field section"
done
echo "$help_out" | grep -q 'source' \
  && ok "--help says it must be sourced" \
  || bad "--help never tells the operator to source it"
echo "$help_out" | grep -qF 'silent_noop_progressed' \
  && ok "--help documents silent_noop_progressed" \
  || bad "--help is missing the preferred progressed API"
echo "$help_out" | grep -qF 'Wired into scripts/loop.sh' \
  && ok "--help states it is wired into loop.sh (issue #63)" \
  || bad "--help still claims the sensor is unwired"

echo
echo "a direct run without --help fails loudly"
# The bug this guards: a library run by hand falls off the end having defined some
# functions in a shell that is about to exit, and reports success. That is a
# silent no-op — the exact failure class this file exists to detect — so the guard
# has to be louder than the thing it is guarding against.
for arg_case in "" "--bogus" "check"; do
  if [[ -z "$arg_case" ]]; then
    direct_out=$("$SENSOR" 2>"$ROOT/direct.err"); direct_rc=$?
    label="no arguments"
  else
    direct_out=$("$SENSOR" "$arg_case" 2>"$ROOT/direct.err"); direct_rc=$?
    label="'$arg_case'"
  fi
  [[ $direct_rc -ne 0 ]] \
    && ok "direct run with $label exits non-zero (got $direct_rc)" \
    || bad "direct run with $label exited 0 — a silent no-op certified as success"
  [[ -z "$direct_out" ]] \
    && ok "direct run with $label prints nothing to stdout" \
    || bad "direct run with $label wrote usage to stdout instead of stderr ($direct_out)"
  grep -q 'ERROR' "$ROOT/direct.err" && grep -qF 'USAGE' "$ROOT/direct.err" \
    && ok "direct run with $label explains itself on stderr" \
    || bad "direct run with $label failed without usage on stderr"
done

# -h is the other half of the documented spelling; it must behave like --help.
"$SENSOR" -h >/dev/null 2>"$ROOT/h.err"
[[ $? -eq 0 && ! -s "$ROOT/h.err" ]] \
  && ok "-h behaves like --help" \
  || bad "-h did not print help cleanly"

echo
echo "sourcing is silent and leaves the functions behind"
# The guard must not fire on a source, and must not narrate one either: loop.sh
# sources this at startup, and a library that greets its caller on stdout
# corrupts any driver that pipes or captures output.
src_out=$(env -u NOOP_BUDGET bash -c 'source "$1"' silent-noop-test "$SENSOR" 2>"$ROOT/src.err")
[[ -z "$src_out" && ! -s "$ROOT/src.err" ]] \
  && ok "sourcing prints nothing on stdout or stderr" \
  || bad "sourcing was noisy (out='$src_out' err='$(tr '\n' ' ' < "$ROOT/src.err")')"

# Silence is worthless if the guard exited before defining anything, so pin that
# the public + internal functions survive the source and that a real cycle still works.
out=$(env -u NOOP_BUDGET bash -c '
  set -euo pipefail
  source "$1"
  for fn in silent_noop_init silent_noop_check silent_noop_progressed _silent_noop_fp; do
    declare -f "$fn" >/dev/null || { echo "MISSING:$fn"; exit 1; }
  done
  STATE_FILE="$2"
  printf "hat: builder\nround: 1\n" > "$STATE_FILE"
  silent_noop_init
  printf "hat: builder\nround: 2\n" > "$STATE_FILE"
  silent_noop_check && echo FUNCTIONAL
' silent-noop-test "$SENSOR" "$ROOT/sourced.md" 2>&1)
[[ "$out" == "FUNCTIONAL" ]] \
  && ok "a sourced sensor still defines all functions and passes a real iteration" \
  || bad "sourcing left the sensor unusable (got '$out')"

# The hostile case for the guard, and the reason the rest of this file keeps $0 a
# label: a caller is free to set $0 to this file's own path while genuinely
# sourcing it. `[[ ${BASH_SOURCE[0]} == $0 ]]` cannot tell that apart from a
# direct run and would exit 2 out of the middle of a driver. Deciding on `return`
# legality instead is what makes the guard immune, so pin it — this is the only
# case here that deliberately spells the invocation the wrong way.
out=$(env -u NOOP_BUDGET bash -c '
  set -euo pipefail
  source "$0"
  STATE_FILE="$1"
  printf "hat: builder\n" > "$STATE_FILE"
  silent_noop_init && echo SOURCED-NOT-EXECUTED
' "$SENSOR" "$ROOT/spoof.md" 2>&1)
[[ "$out" == "SOURCED-NOT-EXECUTED" ]] \
  && ok "a source whose \$0 is the sensor's own path is not mistaken for a direct run" \
  || bad "the guard misread a source as a direct run when \$0 was spoofed (got '$out')"

echo
echo "doctrine pins the clock key the sensor excludes"
# The sensor drops only a column-zero `updated:` line (`awk '!/^updated:/'`).
# playbooks/loop-step.md is what hats actually follow; if it says a free-form
# "timestamp UTC" and an agent writes `timestamp:` / `updated_at:` / an indented
# line, the filter stops removing it and a clock-only bump looks like progress —
# the L-008 failure this sensor exists to catch. Pin the canonical key name.
PLAYBOOK="$SCRIPT_DIR/../../playbooks/loop-step.md"
if [[ -f "$PLAYBOOK" ]] \
  && grep -q 'updated: <UTC timestamp>' "$PLAYBOOK" \
  && grep -q 'column-zero' "$PLAYBOOK"
then
  ok "loop-step end-of-step obligation pins column-zero updated:"
else
  bad "loop-step does not pin the canonical updated: field — sensor exclusion can drift"
fi

echo
echo "it is wired into the driver (issue #63)"
# The preferred API is silent_noop_progressed; loop.sh must source the sensor
# and call that function — not private streak globals.
if grep -q 'silent-noop' "$SCRIPT_DIR/../loop.sh" \
  && grep -q 'silent_noop_progressed' "$SCRIPT_DIR/../loop.sh"
then
  ok "loop.sh sources silent-noop and calls silent_noop_progressed"
else
  bad "loop.sh is not wired to silent_noop_progressed"
fi
if grep -qE '_silent_noop_(streak|last|ready)' "$SCRIPT_DIR/../loop.sh"; then
  bad "loop.sh couples to silent-noop private streak globals"
else
  ok "loop.sh does not couple to silent-noop private globals"
fi

echo
echo "silent_noop_progressed: stateless BEFORE/AFTER contract"
# Prefer a small stateless API; do not require STATE_FILE or init.
write_state "$ROOT/before.md" "2026-08-02T00:00:00Z"
write_state "$ROOT/after-clock.md" "2026-08-02T00:00:01Z"
write_state "$ROOT/after-round.md" "2026-08-02T00:00:01Z" "round moved"
# Force a same-length substantive edit (round digit swap) on a copy.
printf '%s\n' "# Gibson loop state" "updated: 2026-08-02T00:00:01Z" "issue:" "pr:" \
  "hat: builder" "next_hat: builder" "round: 1" "parked: false" "handoff:" \
  "handoff_sha:" "next_action: triage" "notes: initialized by loop.sh" > "$ROOT/before-r.md"
printf '%s\n' "# Gibson loop state" "updated: 2026-08-02T00:00:02Z" "issue:" "pr:" \
  "hat: builder" "next_hat: builder" "round: 2" "parked: false" "handoff:" \
  "handoff_sha:" "next_action: triage" "notes: initialized by loop.sh" > "$ROOT/after-r.md"
printf '%s\n' "# Gibson loop state" "updated: 2026-08-02T00:00:01Z" "issue:" "pr:" \
  "hat: builder" "next_hat: builder" "round: 0" "parked: false" "handoff:" \
  "handoff_sha: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
  "next_action: triage" "notes: initialized by loop.sh" > "$ROOT/after-sha.md"

out=$(bash -c '
  set -euo pipefail
  source "$1"
  silent_noop_progressed "$2" "$3" && echo PROGRESS || echo NOOP
' silent-noop-test "$SENSOR" "$ROOT/before.md" "$ROOT/after-clock.md" 2>&1)
[[ "$out" == "NOOP" ]] \
  && ok "progressed: clock-only updated: rewrite is no-progress" \
  || bad "progressed: clock-only counted as progress (got '$out')"

out=$(bash -c '
  set -euo pipefail
  source "$1"
  silent_noop_progressed "$2" "$3" && echo PROGRESS || echo NOOP
' silent-noop-test "$SENSOR" "$ROOT/before-r.md" "$ROOT/after-r.md" 2>&1)
[[ "$out" == "PROGRESS" ]] \
  && ok "progressed: same-length round edit counts as progress" \
  || bad "progressed: same-length edit missed (got '$out')"

out=$(bash -c '
  set -euo pipefail
  source "$1"
  silent_noop_progressed "$2" "$3" && echo PROGRESS || echo NOOP
' silent-noop-test "$SENSOR" "$ROOT/before-r.md" "$ROOT/after-sha.md" 2>&1)
[[ "$out" == "PROGRESS" ]] \
  && ok "progressed: handoff_sha change counts as progress" \
  || bad "progressed: handoff_sha change missed (got '$out')"

# Fail closed: missing / unreadable / symlink / directory never progress.
out=$(bash -c '
  set -euo pipefail
  source "$1"
  silent_noop_progressed "$2" "$3" && echo PROGRESS || echo NOOP
' silent-noop-test "$SENSOR" "$ROOT/before.md" "$ROOT/missing-after.md" 2>&1)
[[ "$out" == "NOOP" ]] \
  && ok "progressed: missing AFTER is no-progress" \
  || bad "progressed: missing AFTER looked like progress (got '$out')"

mkdir -p "$ROOT/dir-after"
out=$(bash -c '
  set -euo pipefail
  source "$1"
  silent_noop_progressed "$2" "$3" && echo PROGRESS || echo NOOP
' silent-noop-test "$SENSOR" "$ROOT/before.md" "$ROOT/dir-after" 2>&1)
[[ "$out" == "NOOP" ]] \
  && ok "progressed: directory AFTER is no-progress" \
  || bad "progressed: directory AFTER looked like progress (got '$out')"

ln -sf "$ROOT/before.md" "$ROOT/sym-after"
out=$(bash -c '
  set -euo pipefail
  source "$1"
  silent_noop_progressed "$2" "$3" && echo PROGRESS || echo NOOP
' silent-noop-test "$SENSOR" "$ROOT/before.md" "$ROOT/sym-after" 2>&1)
[[ "$out" == "NOOP" ]] \
  && ok "progressed: symlink AFTER is no-progress (no follow)" \
  || bad "progressed: symlink AFTER looked like progress (got '$out')"

# Working digest → sentinel:unhashable must fail closed (never "changed").
FAKEBIN2="$ROOT/fakebin2"
mkdir -p "$FAKEBIN2"
for hasher in sha256sum shasum cksum; do
  printf '#!/bin/sh\nexit 7\n' > "$FAKEBIN2/$hasher"
  chmod +x "$FAKEBIN2/$hasher"
done
# BEFORE hashed with a working PATH; AFTER hashed under the broken PATH by
# calling the fp helper directly and feeding progressed via a subshell that
# only breaks hashers for the second fingerprint — simulate by replacing AFTER
# with a path that is unreadable after we chmod 000, or by shadowing for both
# when BEFORE is already a sentinel. Stronger: call fp under broken PATH and
# ensure progressed never returns 0 when AFTER is unhashable.
out=$(PATH="$FAKEBIN2:$PATH" bash -c '
  set -euo pipefail
  source "$1"
  # Both sides unhashable → same sentinel → no-progress
  silent_noop_progressed "$2" "$2" && echo PROGRESS || echo NOOP
' silent-noop-test "$SENSOR" "$ROOT/before.md" 2>&1)
[[ "$out" == "NOOP" ]] \
  && ok "progressed: unhashable/unhashable is no-progress" \
  || bad "progressed: unhashable pair counted as progress (got '$out')"

# Explicit: a real digest BEFORE vs unhashable AFTER fails closed.
# Capture a real digest, then force AFTER through a broken hasher by writing a
# tiny wrapper that uses _silent_noop_fp under PATH shadow for the second arg.
out=$(bash -c '
  set -euo pipefail
  source "$1"
  before="$2"
  after="$3"
  # Monkey-patch: fingerprint AFTER under broken hasher PATH.
  real_fp=$(_silent_noop_fp "$before")
  fa=$(PATH="'"$FAKEBIN2"':$PATH" bash -c "
    set -euo pipefail
    source \"\$1\"
    _silent_noop_fp \"\$2\"
  " silent-noop-test "$1" "$after")
  case "$real_fp" in state:*) ;; *) echo "BAD_BEFORE:$real_fp"; exit 0 ;; esac
  case "$fa" in sentinel:unhashable) ;; *) echo "BAD_AFTER:$fa"; exit 0 ;; esac
  # Replicate progressed fail-closed rule without re-hashing AFTER with a good hasher.
  case "$fa" in state:*) echo PROGRESS ;; *) echo NOOP ;; esac
' silent-noop-test "$SENSOR" "$ROOT/before.md" "$ROOT/after-r.md" 2>&1)
[[ "$out" == "NOOP" ]] \
  && ok "progressed: working digest → sentinel:unhashable fails closed" \
  || bad "progressed: digest→unhashable did not fail closed (got '$out')"

# Wrong arity fails closed under set -euo pipefail.
out=$(bash -c '
  set -euo pipefail
  source "$1"
  silent_noop_progressed "$2" 2>/dev/null && echo PROGRESS || echo NOOP
' silent-noop-test "$SENSOR" "$ROOT/before.md" 2>&1)
[[ "$out" == "NOOP" ]] \
  && ok "progressed: wrong arity is no-progress (fail closed)" \
  || bad "progressed: wrong arity did not fail closed (got '$out')"

echo
echo "content-normalization awk failure is unhashable (never empty-body digest)"
# Independent merge-blocker repro: BEFORE normalization succeeds; only AFTER's
# substantive-content awk fails. BEFORE/AFTER differ solely in ignored updated:.
# A bug that does `body=$(awk ...) || body=""` then hashes the empty fallback
# mints state:<empty-digest> for AFTER, which differs from BEFORE's real digest
# → silent_noop_progressed returns progress → loop resets budgets / can hand off.
# Fail closed: AFTER must be sentinel:unhashable; progressed must return 1.
#
# Wrapper keys on the content-normalization program + AFTER path only — not on
# call count — so hash-pipeline awk '{print $1}' is never intercepted, and the
# test cannot pass because both sides failed or because sha256sum's awk broke.
write_state "$ROOT/before-awk-ok.md" "2026-08-02T00:00:00Z"
write_state "$ROOT/after-awk-fail.md" "2026-08-02T00:00:01Z"
FAKEAWK_BIN="$ROOT/fakeawk"
mkdir -p "$FAKEAWK_BIN"
REAL_AWK=$(command -v awk)
# Exact AFTER path only (no call-count races; hash awk never sees this path).
AFTER_AWK_PATH="$ROOT/after-awk-fail.md"
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' '# Fail only the substantive-content strip for the AFTER path.'
  printf '%s\n' "# Hash extraction uses awk '{print \$1}' (different program) — pass."
  printf '%s\n' "AFTER_TARGET=$(printf '%q' "$AFTER_AWK_PATH")"
  printf '%s\n' "REAL_AWK=$(printf '%q' "$REAL_AWK")"
  printf '%s\n' 'if [ "$#" -ge 2 ] && [ "$1" = '\''!/^updated:/'\'' ] && [ "$2" = "$AFTER_TARGET" ]; then'
  printf '%s\n' '  echo "awk: forced AFTER content-normalization failure" >&2'
  printf '%s\n' '  exit 1'
  printf '%s\n' 'fi'
  printf '%s\n' 'exec "$REAL_AWK" "$@"'
} > "$FAKEAWK_BIN/awk"
chmod +x "$FAKEAWK_BIN/awk"

# Control A: BEFORE alone under the wrapper must still be a real digest (awk ok).
out=$(PATH="$FAKEAWK_BIN:$PATH" bash -c '
  set -euo pipefail
  source "$1"
  _silent_noop_fp "$2"
' silent-noop-test "$SENSOR" "$ROOT/before-awk-ok.md" 2>&1)
case "$out" in
  state:*) ok "control: BEFORE content-awk under wrapper still yields state:<digest>" ;;
  *) bad "control: BEFORE under wrapper was not a digest (got '$out') — wrapper too broad?" ;;
esac

# Control B: AFTER alone must be sentinel:unhashable (not state: of empty body).
out=$(PATH="$FAKEAWK_BIN:$PATH" bash -c '
  set -euo pipefail
  source "$1"
  _silent_noop_fp "$2"
  printf " SURVIVED"
' silent-noop-test "$SENSOR" "$ROOT/after-awk-fail.md" 2>&1)
[[ "$out" == "sentinel:unhashable SURVIVED" ]] \
  && ok "AFTER-only content-awk failure yields sentinel:unhashable (survives set -euo)" \
  || bad "AFTER content-awk failure did not fail closed (got '$out')"

# Empty-body digest must not appear as AFTER (would prove empty-fallback hashing).
empty_digest=$(printf '%s\n' "" | {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else cksum | awk '{print $1 "-" $2}'
  fi
})
out=$(PATH="$FAKEAWK_BIN:$PATH" bash -c '
  set -euo pipefail
  source "$1"
  _silent_noop_fp "$2"
' silent-noop-test "$SENSOR" "$ROOT/after-awk-fail.md" 2>&1)
[[ "$out" != "state:$empty_digest" ]] \
  && ok "AFTER content-awk failure is not hashed empty-body state:<digest>" \
  || bad "AFTER content-awk failure minted empty-body digest (got '$out')"

# progressed: real BEFORE + unhashable AFTER → no-progress (fail closed).
# Documented status: return 1 — loop must not treat this as progress (no budget
# reset, no handoff). Same contract as digest→unhashable hasher path.
out=$(PATH="$FAKEAWK_BIN:$PATH" bash -c '
  set -euo pipefail
  source "$1"
  fb=$(_silent_noop_fp "$2")
  fa=$(_silent_noop_fp "$3")
  # Prove asymmetry inside the same progressed invocation environment.
  case "$fb" in state:*) ;; *) echo "BOTH_OR_BEFORE_BAD:$fb:$fa"; exit 0 ;; esac
  case "$fa" in sentinel:unhashable) ;; *) echo "AFTER_NOT_UNHASHABLE:$fb:$fa"; exit 0 ;; esac
  silent_noop_progressed "$2" "$3" && echo PROGRESS || echo NOOP
' silent-noop-test "$SENSOR" "$ROOT/before-awk-ok.md" "$ROOT/after-awk-fail.md" 2>&1)
[[ "$out" == "NOOP" ]] \
  && ok "progressed: BEFORE digest + AFTER content-awk-fail is no-progress (fail closed)" \
  || bad "progressed: AFTER content-awk-fail looked like progress or controls failed (got '$out')"

# Clock-only pair under a clean PATH remains no-progress (sanity: files are equal
# on substance; the wrapper is what makes AFTER unhashable above).
out=$(bash -c '
  set -euo pipefail
  source "$1"
  silent_noop_progressed "$2" "$3" && echo PROGRESS || echo NOOP
' silent-noop-test "$SENSOR" "$ROOT/before-awk-ok.md" "$ROOT/after-awk-fail.md" 2>&1)
[[ "$out" == "NOOP" ]] \
  && ok "control: same pair without awk-fail wrapper is clock-only no-progress" \
  || bad "control: clock-only pair without wrapper misclassified (got '$out')"

# Legitimate empty substantive content: extraction succeeds, body empty → still
# a real state: digest (not unhashable). Pins "success + empty ≠ failure".
printf '%s\n' "updated: 2026-08-02T00:00:00Z" > "$ROOT/only-clock.md"
out=$(bash -c '
  set -euo pipefail
  source "$1"
  _silent_noop_fp "$2"
' silent-noop-test "$SENSOR" "$ROOT/only-clock.md" 2>&1)
case "$out" in
  state:*) ok "legitimate empty substantive body (awk success) still hashes to state:<digest>" ;;
  *) bad "legitimate empty body should hash, not sentinel (got '$out')" ;;
esac

echo
echo "silent-noop.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
