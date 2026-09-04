#!/usr/bin/env bash
# wall-timeout.test.sh — portable run-all timeout sensors (#260).
#
# The hardened process-group implementation lives in scripts/lib/wall-timeout.sh
# and has deeper coverage in loop-fleet.test.sh. This suite pins the shared
# helper's public contract and run-all's thin integration without duplicating it.
# Cleanup always targets PIDs recorded by the fixture; never process patterns.
set -uo pipefail

DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WALL_LIB="$DIR/../lib/wall-timeout.sh"
RUN_ALL="$DIR/run-all.sh"
# shellcheck disable=SC1090,SC1091
source "$WALL_LIB"

PASS=0
fails=0
ok()  { printf '  ok   — %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL — %s\n' "$1"; fails=$((fails + 1)); }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
alive() { kill -0 "$1" 2>/dev/null; }
reap_exact() {
  local p
  for p in "$@"; do
    [[ "$p" =~ ^[1-9][0-9]*$ ]] || continue
    kill -TERM "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done
}

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wall-timeout-260.XXXXXX") || exit 1
cleanup() {
  local f p
  if [[ -d "$ROOT" ]]; then
    for f in "$ROOT"/*.pid; do
      [[ -f "$f" ]] || continue
      while read -r p; do reap_exact "$p"; done < "$f"
    done
    rm -rf "$ROOT"
  fi
}
trap cleanup EXIT

echo "wall-timeout: shared helper contract"
run_with_wall_timeout 30 bash -c 'exit 0'; eq "exit 0 passes through" "$?" "0"
run_with_wall_timeout 30 bash -c 'exit 7'; eq "nonzero exit passes through" "$?" "7"
eq "stdout passes through" "$(run_with_wall_timeout 30 bash -c 'printf OUT')" "OUT"
eq "stdin passes through" "$(printf IN | run_with_wall_timeout 30 cat)" "IN"

echo "wall-timeout: run-all portable integration"

# Execute the exact production wrapper body after sourcing its production
# dependency. This keeps the test coupled to behavior without sourcing run-all,
# whose top-level purpose is to execute every suite.
RUN_LIMITED_DEF=$(sed -n '/^run_limited()/,/^}/p' "$RUN_ALL")
if [[ -n "$RUN_LIMITED_DEF" ]]; then
  eval "$RUN_LIMITED_DEF"
  ok "run-all exposes one extractable thin wrapper"
else
  bad "run-all thin wrapper is missing"
fi

if grep -Fq 'source "$WALL_TIMEOUT_LIB"' "$RUN_ALL" \
  && grep -Fq 'run_with_wall_timeout "$TIMEOUT" "$@"' "$RUN_ALL" \
  && ! grep -Eq 'command -v timeout|(^|[[:space:]])timeout[[:space:]]+"\$TIMEOUT"' "$RUN_ALL"; then
  ok "run-all sources the shared helper without GNU timeout"
else
  bad "run-all portable-helper wiring is incomplete"
fi

# A controlled PATH models stock macOS: it contains the shared helper's
# declared runtime but deliberately has no executable named `timeout`.
PATH_NOTIME="$ROOT/bin-notime"
mkdir -p "$PATH_NOTIME"
for c in bash perl python3 mktemp rm tr ps grep sleep date cat; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -s "$p" "$PATH_NOTIME/$c"
done
[[ ! -e "$PATH_NOTIME/timeout" ]] || bad "timeout unexpectedly present in fixture PATH"

MARK="$ROOT/over.pid"
: > "$MARK"
(
  PATH="$PATH_NOTIME"; export PATH
  TIMEOUT=2
  run_limited bash -c "sleep 99999 & echo \$! > '$MARK'; sleep 5"
)
eq "timeout-absent over-limit run returns 124" "$?" "124"
sleep 0.5
orphans=0
while read -r p; do
  [[ "$p" =~ ^[1-9][0-9]*$ ]] || continue
  if alive "$p"; then orphans=$((orphans + 1)); reap_exact "$p"; fi
done < "$MARK"
eq "timed-out descendant is reaped" "$orphans" "0"

(
  PATH="$PATH_NOTIME"; export PATH
  TIMEOUT=30
  out=$(run_limited bash -c 'printf UNDER')
  [[ "$?" -eq 0 && "$out" == "UNDER" ]]
)
eq "under-limit stdout succeeds" "$?" "0"

(
  PATH="$PATH_NOTIME"; export PATH
  TIMEOUT=30
  run_limited bash -c 'exit 19'
)
eq "ordinary nonzero exit is preserved" "$?" "19"

TIMEOUT=0
run_limited bash -c 'sleep 1; exit 0'
eq "TIMEOUT=0 is the explicit unbounded path" "$?" "0"

# Natural leader exit with a live child exercises the helper's residual group
# cleanup race, which is distinct from wall-clock expiry.
MARK="$ROOT/race.pid"
: > "$MARK"
export TIMEOUT=5
run_limited bash -c "sleep 99999 & echo \$! > '$MARK'; exit 0"
eq "leader-exit race preserves exit 0" "$?" "0"
sleep 0.5
orphans=0
while read -r p; do
  [[ "$p" =~ ^[1-9][0-9]*$ ]] || continue
  if alive "$p"; then orphans=$((orphans + 1)); reap_exact "$p"; fi
done < "$MARK"
eq "leader-exit residual child is reaped" "$orphans" "0"

echo "wall-timeout: fail-closed input and capability checks"
for invalid in -1 abc 1.5; do
  out=$(bash "$RUN_ALL" --timeout "$invalid" --only NOMATCH 2>&1); ec=$?
  if [[ "$ec" -eq 2 ]] && printf '%s\n' "$out" | grep -F 'whole number of seconds' >/dev/null; then
    ok "invalid timeout '$invalid' is refused"
  else
    bad "invalid timeout '$invalid' was not a usage error (exit $ec)"
  fi
done

# Invoke the real script with enough startup commands but neither declared
# process-group runtime. The exact remediation proves failure occurs at the
# timeout preflight, before suite enumeration.
PATH_INCAPABLE="$ROOT/bin-incapable"
mkdir -p "$PATH_INCAPABLE"
for c in bash cat dirname pwd awk; do
  p=$(command -v "$c" 2>/dev/null) || continue
  ln -s "$p" "$PATH_INCAPABLE/$c"
done
out=$(PATH="$PATH_INCAPABLE" /bin/bash "$RUN_ALL" --timeout 5 --only NOMATCH 2>&1); ec=$?
if [[ "$ec" -eq 2 ]] && printf '%s\n' "$out" | grep -F 'requires perl or python3' >/dev/null; then
  ok "missing portable runtime fails before suites with remediation"
else
  bad "portable-runtime preflight was not reached (exit $ec): $out"
fi

grep -Fq 'timed out after ${timeout}s' "$RUN_ALL" \
  && ok "timed-out disposition remains distinct" \
  || bad "timed-out disposition message is missing"

# =============================================================================
# #269 — cancellation cleanup: traps, exact-group reap, race fixtures
# =============================================================================
echo "wall-timeout: #269 cancellation contract"

wait_file() {
  local f="$1" n="${2:-100}" i=0
  while [[ $i -lt $n ]]; do
    [[ -e "$f" ]] && return 0
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_contains() {
  local f="$1" needle="$2" n="${3:-100}" i=0
  while [[ $i -lt $n ]]; do
    if [[ -f "$f" ]] && grep -Fq "$needle" "$f" 2>/dev/null; then
      return 0
    fi
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_gone() {
  local p="$1" n="${2:-80}" i=0
  [[ "$p" =~ ^[1-9][0-9]*$ ]] || return 0
  while [[ $i -lt $n ]]; do
    kill -0 "$p" 2>/dev/null || return 0
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  return 1
}

read_ident() {
  tr -d '[:space:]' < "$1" 2>/dev/null || true
}

record_captured() {
  local p
  for p in "$@"; do
    [[ "$p" =~ ^[1-9][0-9]*$ ]] || continue
    printf '%s\n' "$p" >> "$ROOT/captured.pid"
  done
}

# Teardown after absence assertions: reap leftovers and fail if that hid
# helper cleanup. expected-alive PIDs are reaped without failing.
assert_absent_or_fail() {
  local name="$1" pid="$2" detail="${3:-}"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  if alive "$pid"; then
    reap_exact "$pid"
    bad "$name PID $pid still alive after helper cleanup (teardown would hide it${detail:+; $detail})"
    return 1
  fi
  ok "$name PID $pid absent after wrapper death"
  return 0
}

assert_published_guardian_absent() {
  local name="$1" dir="$2" guard
  guard=$(read_ident "$dir/guardian.pid")
  if [[ ! "$guard" =~ ^[1-9][0-9]*$ ]]; then
    bad "$name guardian identity was not published"
    return 1
  fi
  record_captured "$guard"
  wait_gone "$guard" 80 || true
  assert_absent_or_fail "$name guardian" "$guard"
}

# Pin guardian teardown across the three ordinary function dispositions. These
# are separate invocations so success, passthrough failure, and timeout cannot
# accidentally share state or make an absence assertion vacuous.
run_guardian_return_fixture() {
  local mode="$1" want="$2" limit="$3" dir="$ROOT/guardian-$1" rc=0
  shift 3
  mkdir -p "$dir"
  FLEET_WALL_TIMEOUT_TEST_PUBLISH="$dir"
  export FLEET_WALL_TIMEOUT_TEST_PUBLISH
  run_with_wall_timeout "$limit" "$@" || rc=$?
  unset FLEET_WALL_TIMEOUT_TEST_PUBLISH
  eq "$mode guardian fixture status" "$rc" "$want"
  assert_published_guardian_absent "$mode return" "$dir"
}

echo "wall-timeout: guardian ordinary-return teardown"
run_guardian_return_fixture success 0 30 /bin/bash -c 'exit 0'
run_guardian_return_fixture nonzero 7 30 /bin/bash -c 'exit 7'
run_guardian_return_fixture timeout 124 1 /bin/bash -c 'sleep 5'

# The trusted launcher can become ready after the parent's bounded proof loop.
# Release HOLD_READY only after pgrp_ok=0 is published, then prove late guardian
# adoption and teardown on both natural and timeout returns.
run_late_guardian_fixture() {
  local mode="$1" want="$2" limit="$3" dir="$ROOT/guardian-late-$1" rc=0 release
  shift 3
  mkdir -p "$dir"
  : > "$dir/hold-ready"
  FLEET_WALL_TIMEOUT_TEST_PUBLISH="$dir"
  FLEET_WALL_TIMEOUT_TEST_HOLD_READY="$dir/hold-ready"
  export FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_READY
  (
    wait_file "$dir/pgrp_ok" 160 || exit 1
    rm -f "$dir/hold-ready"
  ) &
  release=$!
  run_with_wall_timeout "$limit" "$@" || rc=$?
  wait "$release" 2>/dev/null || true
  unset FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_READY
  rm -f "$dir/hold-ready"
  eq "$mode late-guardian fixture status" "$rc" "$want"
  eq "$mode late-guardian initial proof stays fail-closed" "$(read_ident "$dir/pgrp_ok")" "0"
  assert_published_guardian_absent "$mode late return" "$dir"
}

run_late_guardian_fixture success 0 30 /bin/bash -c 'exit 0'
run_late_guardian_fixture timeout 124 1 /bin/bash -c 'sleep 5'

# Sourcing the file must not install traps.
_src_before=$(bash -c 'trap -p HUP; trap -p INT; trap -p TERM' 2>/dev/null || true)
_src_after=$(bash -c 'source "$1"; trap -p HUP; trap -p INT; trap -p TERM' bash "$WALL_LIB" 2>/dev/null || true)
eq "sourcing wall-timeout.sh has no trap side effect" "$_src_after" "$_src_before"

if grep -E '^[[:space:]]*trap .*(EXIT|RETURN)' "$WALL_LIB" >/dev/null; then
  bad "helper installs EXIT or RETURN traps"
else
  ok "helper never installs EXIT or RETURN traps"
fi

# Unset / ignored / custom traps survive a genuine outer -> inner invocation.
# The inner helper runs in the command shell while the outer helper remains
# active, matching run-all executing a suite that uses the same helper.
_trap_dir="$ROOT/traps"
mkdir -p "$_trap_dir"
cat > "$_trap_dir/nested-probe" <<'NESTED_TRAPS'
#!/usr/bin/env bash
mode="$1"
role="$2"
wall_lib="$3"
receipt="$4"
# shellcheck disable=SC1090,SC1091
source "$wall_lib"
case "$mode" in
  unset) trap - HUP INT TERM ;;
  ignored) trap '' HUP; trap '' INT; trap '' TERM ;;
  custom)
    trap 'printf custom-hup >/dev/null' HUP
    trap 'printf custom-int >/dev/null' INT
    trap 'printf custom-term >/dev/null' TERM
    ;;
  *) exit 90 ;;
esac
bh=$(trap -p HUP 2>/dev/null || true)
bi=$(trap -p INT 2>/dev/null || true)
bt=$(trap -p TERM 2>/dev/null || true)
rc=0
if [[ "$role" == "outer" ]]; then
  run_with_wall_timeout 30 /bin/bash "$0" "$mode" inner "$wall_lib" "$receipt.inner" || rc=$?
else
  run_with_wall_timeout 30 true || rc=$?
fi
ah=$(trap -p HUP 2>/dev/null || true)
ai=$(trap -p INT 2>/dev/null || true)
at=$(trap -p TERM 2>/dev/null || true)
[[ "$rc" -eq 0 && "$bh" == "$ah" && "$bi" == "$ai" && "$bt" == "$at" ]] || exit 91
printf '%s\n' "$mode:$role" > "$receipt"
NESTED_TRAPS
chmod +x "$_trap_dir/nested-probe"
for _trap_mode in unset ignored custom; do
  _trap_rc=0
  /bin/bash "$_trap_dir/nested-probe" "$_trap_mode" outer "$WALL_LIB" "$_trap_dir/$_trap_mode.outer" || _trap_rc=$?
  if [[ "$_trap_rc" -eq 0 && -f "$_trap_dir/$_trap_mode.outer" && -f "$_trap_dir/$_trap_mode.outer.inner" ]]; then
    ok "$_trap_mode traps survive genuine nested invocation"
  else
    bad "$_trap_mode traps changed across genuine nested invocation (status=$_trap_rc)"
  fi
done

# Write a TERM-resistant descendant command (records TERM, survives grace).
# Use a fresh bash -c so $$ is the descendant PID (bash 3.2 has no BASHPID;
# $$ in a ( subshell ) is the parent). Ignore HUP so leader-exit HUP is not
# mistaken for the helper's TERM/KILL contract.
write_term_desc_cmd() {
  local cmd="$1" dir="$2"
  cat > "$cmd" <<CMD
#!/usr/bin/env bash
export DESC_DIR="$dir"
printf '%s\\n' "\$\$" > "\$DESC_DIR/cmd_leader.pid"
/bin/bash -c '
  trap "printf TERM >> \"\$DESC_DIR/desc.signals\"" TERM
  trap "" HUP
  printf "%s\\n" \$\$ > "\$DESC_DIR/desc.pid"
  : > "\$DESC_DIR/desc.ready"
  while :; do sleep 1; done
' &
wait
CMD
  chmod +x "$cmd"
}

# Nested-cascade command whose group leader and descendant both resist TERM.
# This forces the inner helper to spend its full grace budget before KILL.
write_resistant_leader_desc_cmd() {
  local cmd="$1" dir="$2"
  cat > "$cmd" <<CMD
#!/usr/bin/env bash
export DESC_DIR="$dir"
trap 'printf LEADER_TERM >> "\$DESC_DIR/leader.signals"' TERM
printf '%s\n' "\$\$" > "\$DESC_DIR/cmd_leader.pid"
/bin/bash -c '
  trap "printf TERM >> \"\$DESC_DIR/desc.signals\"" TERM
  trap "" HUP
  printf "%s\n" \$\$ > "\$DESC_DIR/desc.pid"
  : > "\$DESC_DIR/desc.ready"
  while :; do sleep 1; done
' &
desc=\$!
while :; do
  wait "\$desc" 2>/dev/null || true
done
CMD
  chmod +x "$cmd"
}

# Background bash inherits SIGINT ignored and will not install an INT trap.
# Reset HUP/INT/TERM to default, then exec so the wrapper can trap them.
spawn_wrapper() {
  perl -e '
    $SIG{HUP} = "DEFAULT";
    $SIG{INT} = "DEFAULT";
    $SIG{TERM} = "DEFAULT";
    exec { $ARGV[0] } @ARGV;
  ' /bin/bash "$1" &
}

write_wrapper() {
  local wrap="$1" dir="$2" cmd="$3" limit="${4:-60}"
  cat > "$wrap" <<WRAP
#!/usr/bin/env bash
trap - HUP INT TERM
# shellcheck disable=SC1090,SC1091
source "$WALL_LIB"
run_with_wall_timeout $limit "$cmd"
printf '%s\\n' "\$?" > "$dir/fn.status"
printf 'CONTINUED\\n' > "$dir/continued"
WRAP
  chmod +x "$wrap"
}

# Real HUP / INT / TERM deliveries against the production helper.
run_signal_fixture() {
  local sig="$1" want="$2"
  local dir="$ROOT/sig-$sig"
  mkdir -p "$dir"
  local hold="$dir/hold-grace"
  : > "$hold"
  : > "$dir/desc.signals"
  write_term_desc_cmd "$dir/cmd" "$dir"
  write_wrapper "$dir/wrapper" "$dir" "$dir/cmd" 60

  sleep 99999 &
  local foreign=$!
  record_captured "$foreign"

  FLEET_WALL_TIMEOUT_TEST_PUBLISH="$dir"
  FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE="$hold"
  export FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE
  spawn_wrapper "$dir/wrapper"
  local wrapper=$!
  record_captured "$wrapper"
  unset FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE

  if ! wait_file "$dir/identities.ready" 80; then
    rm -f "$hold"
    reap_exact "$wrapper" "$foreign"
    bad "$sig fixture: identities.ready never published"
    return 1
  fi
  if ! wait_file "$dir/desc.ready" 80; then
    rm -f "$hold"
    reap_exact "$wrapper" "$foreign"
    bad "$sig fixture: descendant never ready"
    return 1
  fi

  local leader pgid guardian watcher desc
  leader=$(read_ident "$dir/leader.pid")
  pgid=$(read_ident "$dir/pgid")
  guardian=$(read_ident "$dir/guardian.pid")
  watcher=$(read_ident "$dir/watcher.pid")
  desc=$(read_ident "$dir/desc.pid")
  record_captured "$leader" "$guardian" "$watcher" "$desc"
  printf 'wrapper=%s leader=%s pgid=%s guardian=%s watcher=%s desc=%s foreign=%s\n' \
    "$wrapper" "$leader" "$pgid" "$guardian" "$watcher" "$desc" "$foreign" > "$dir/ids"

  if [[ ! "$leader" =~ ^[1-9][0-9]*$ || ! "$pgid" =~ ^[1-9][0-9]*$ \
     || ! "$guardian" =~ ^[1-9][0-9]*$ || ! "$watcher" =~ ^[1-9][0-9]*$ \
     || ! "$desc" =~ ^[1-9][0-9]*$ ]]; then
    rm -f "$hold"
    reap_exact "$wrapper" "$foreign" "$leader" "$watcher" "$desc"
    bad "$sig fixture: missing captured identities ($(cat "$dir/ids"))"
    return 1
  fi
  if [[ "$pgid" != "$leader" ]]; then
    rm -f "$hold"
    reap_exact "$wrapper" "$foreign" "$leader" "$watcher" "$desc"
    bad "$sig fixture: pgid $pgid != leader $leader"
    return 1
  fi
  if ! alive "$foreign"; then
    rm -f "$hold"
    bad "$sig fixture: foreign sibling died before delivery"
    return 1
  fi

  kill -s "$sig" "$wrapper" 2>/dev/null || true

  if ! wait_file "$dir/in_grace" 200; then
    rm -f "$hold"
    reap_exact "$wrapper" "$foreign" "$leader" "$watcher" "$desc"
    bad "$sig fixture: in_grace never published"
    return 1
  fi
  if ! wait_contains "$dir/desc.signals" TERM 40; then
    rm -f "$hold"
    reap_exact "$wrapper" "$foreign" "$leader" "$watcher" "$desc"
    bad "$sig fixture: descendant did not record TERM"
    return 1
  fi
  if grep -Fq TERM "$dir/desc.signals" && alive "$desc"; then
    ok "$sig: descendant recorded TERM and survived through grace hold"
  else
    bad "$sig: descendant did not survive TERM through grace (alive=$(alive "$desc" && echo 1 || echo 0) signals=$(cat "$dir/desc.signals" 2>/dev/null))"
  fi

  rm -f "$hold"
  local wrc=0
  wait "$wrapper" 2>/dev/null || wrc=$?
  eq "$sig wrapper wait status" "$wrc" "$want"
  if [[ -f "$dir/continued" ]]; then
    bad "$sig cancellation continued the caller loop"
  else
    ok "$sig cancellation did not continue the caller loop"
  fi
  if [[ -f "$dir/fn.status" ]]; then
    local fns
    fns=$(read_ident "$dir/fn.status")
    if [[ "$fns" == "0" || "$fns" == "124" ]]; then
      bad "$sig function status aliased to success/timeout ($fns)"
    else
      ok "$sig function did not return success or 124"
    fi
  fi

  wait_gone "$desc" 40 || true
  wait_gone "$watcher" 40 || true
  wait_gone "$leader" 40 || true
  assert_absent_or_fail "$sig descendant" "$desc"
  assert_absent_or_fail "$sig watcher" "$watcher"
  assert_absent_or_fail "$sig leader" "$leader"
  assert_published_guardian_absent "$sig cancel" "$dir"
  if alive "$foreign"; then
    ok "$sig foreign sibling in parent group still alive"
    reap_exact "$foreign"
  else
    bad "$sig foreign sibling was killed (helper signaled an unproven/parent group)"
  fi
}

run_signal_fixture HUP 129
run_signal_fixture INT 130
run_signal_fixture TERM 143

# Foreground process-group INT (Ctrl-C): foreign may ignore INT; helper must
# not TERM/KILL it.
echo "wall-timeout: foreground process-group INT"
_fg="$ROOT/fg-int"
mkdir -p "$_fg"
: > "$_fg/hold-grace"
: > "$_fg/desc.signals"
write_term_desc_cmd "$_fg/cmd" "$_fg"
cat > "$_fg/wrapper" <<WRAP
#!/usr/bin/env bash
trap - HUP INT TERM
# shellcheck disable=SC1090,SC1091
source "$WALL_LIB"
run_with_wall_timeout 60 "$_fg/cmd"
printf '%s\\n' "\$?" > "$_fg/fn.status"
printf 'CONTINUED\\n' > "$_fg/continued"
WRAP
chmod +x "$_fg/wrapper"
cat > "$_fg/leader.sh" <<LEAD
#!/usr/bin/env bash
trap '' INT
sleep 99999 &
printf '%s\\n' "\$!" > "$_fg/foreign.pid"
FLEET_WALL_TIMEOUT_TEST_PUBLISH="$_fg"
FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE="$_fg/hold-grace"
export FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE
perl -e '\$SIG{HUP}="DEFAULT"; \$SIG{INT}="DEFAULT"; \$SIG{TERM}="DEFAULT"; exec { \$ARGV[0] } @ARGV' /bin/bash "$_fg/wrapper" &
printf '%s\\n' "\$!" > "$_fg/wrapper.pid"
printf '%s\\n' "\$\$" > "$_fg/group_leader.pid"
ps -p "\$\$" -o pgid= 2>/dev/null | tr -d '[:space:]' > "$_fg/group.pgid"
wait "\$!"
printf '%s\\n' "\$?" > "$_fg/wrapper.status"
LEAD
chmod +x "$_fg/leader.sh"
perl -e 'setpgrp(0,0); $SIG{HUP}="DEFAULT"; $SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec { $ARGV[0] } @ARGV' /bin/bash "$_fg/leader.sh" &
_fg_perl=$!
record_captured "$_fg_perl"

if ! wait_file "$_fg/identities.ready" 80 || ! wait_file "$_fg/desc.ready" 80 \
   || ! wait_file "$_fg/group.pgid" 80 || ! wait_file "$_fg/foreign.pid" 80; then
  rm -f "$_fg/hold-grace"
  reap_exact "$_fg_perl"
  bad "fg-INT: identities never published"
else
  _fg_pgid=$(read_ident "$_fg/group.pgid")
  _fg_wrap=$(read_ident "$_fg/wrapper.pid")
  _fg_foreign=$(read_ident "$_fg/foreign.pid")
  _fg_leader=$(read_ident "$_fg/leader.pid")
  _fg_watch=$(read_ident "$_fg/watcher.pid")
  _fg_desc=$(read_ident "$_fg/desc.pid")
  _fg_gl=$(read_ident "$_fg/group_leader.pid")
  record_captured "$_fg_wrap" "$_fg_foreign" "$_fg_leader" "$_fg_watch" "$_fg_desc" "$_fg_gl"
  printf 'pgid=%s wrap=%s foreign=%s leader=%s watch=%s desc=%s\n' \
    "$_fg_pgid" "$_fg_wrap" "$_fg_foreign" "$_fg_leader" "$_fg_watch" "$_fg_desc" > "$_fg/ids"
  if [[ "$_fg_pgid" =~ ^[1-9][0-9]*$ ]]; then
    kill -INT -"$_fg_pgid" 2>/dev/null || true
    if ! wait_file "$_fg/in_grace" 200; then
      rm -f "$_fg/hold-grace"
      reap_exact "$_fg_perl" "$_fg_wrap" "$_fg_foreign" "$_fg_leader" "$_fg_watch" "$_fg_desc" "$_fg_gl"
      bad "fg-INT: in_grace never published"
    else
      if wait_contains "$_fg/desc.signals" TERM 40 && alive "$_fg_desc"; then
        ok "fg-INT: descendant recorded TERM and survived grace hold"
      else
        bad "fg-INT: descendant TERM/grace not observed"
      fi
      rm -f "$_fg/hold-grace"
      wait_gone "$_fg_wrap" 80 || true
      wait_gone "$_fg_perl" 80 || true
      wrc=$(read_ident "$_fg/wrapper.status")
      eq "fg-INT wrapper status" "$wrc" "130"
      wait_gone "$_fg_desc" 40 || true
      wait_gone "$_fg_watch" 40 || true
      assert_absent_or_fail "fg-INT descendant" "$_fg_desc"
      assert_absent_or_fail "fg-INT watcher" "$_fg_watch"
      if alive "$_fg_foreign"; then
        ok "fg-INT foreign sibling ignored INT and was not TERM/KILL'd"
        reap_exact "$_fg_foreign"
      else
        bad "fg-INT foreign sibling was killed (helper must not TERM/KILL parent-group processes)"
      fi
      reap_exact "$_fg_gl" "$_fg_perl"
    fi
  else
    rm -f "$_fg/hold-grace"
    reap_exact "$_fg_perl"
    bad "fg-INT: missing group pgid"
  fi
fi

# Deterministic races: before ready, during timeout grace, after leader exit
# before wait, after normal return with poisoned identities.
echo "wall-timeout: deterministic cancellation races"

# 0) Trap delivery in the two `$!` tracking windows. The production helper
# latches the first signal until the just-started exact PID is published.
run_tracking_window_fixture() {
  local stage="$1" state="$2" dir="$ROOT/track-$1" hold="$ROOT/track-$1/hold"
  mkdir -p "$dir"
  : > "$hold"
  : > "$dir/desc.signals"
  write_term_desc_cmd "$dir/cmd" "$dir"
  write_wrapper "$dir/wrapper" "$dir" "$dir/cmd" 60
  sleep 99999 &
  local foreign=$!
  record_captured "$foreign"

  FLEET_WALL_TIMEOUT_TEST_PUBLISH="$dir"
  case "$stage" in
    leader) FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_LEADER_TRACK="$hold" ;;
    watcher) FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_WATCHER_TRACK="$hold" ;;
    *) bad "tracking-window: unknown stage $stage"; reap_exact "$foreign"; return 1 ;;
  esac
  export FLEET_WALL_TIMEOUT_TEST_PUBLISH
  export FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_LEADER_TRACK
  export FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_WATCHER_TRACK
  spawn_wrapper "$dir/wrapper"
  local wrapper=$!
  record_captured "$wrapper"
  unset FLEET_WALL_TIMEOUT_TEST_PUBLISH
  unset FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_LEADER_TRACK
  unset FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_WATCHER_TRACK

  if ! wait_file "$dir/$state" 80 || ! wait_file "$dir/desc.ready" 80; then
    rm -f "$hold"
    reap_exact "$wrapper" "$foreign"
    bad "$stage-track: hold window or descendant never became ready"
    return 1
  fi
  if [[ ! -e "$hold" ]]; then
    reap_exact "$wrapper" "$foreign"
    bad "$stage-track: bounded hold expired before signal delivery"
    return 1
  fi

  kill -s TERM "$wrapper" 2>/dev/null || true
  rm -f "$hold"
  local wrc=0 leader watcher desc
  wait "$wrapper" 2>/dev/null || wrc=$?
  eq "$stage-track wrapper status" "$wrc" "143"
  leader=$(read_ident "$dir/leader.pid")
  watcher=""
  [[ -f "$dir/watcher.pid" ]] && watcher=$(read_ident "$dir/watcher.pid")
  desc=$(read_ident "$dir/desc.pid")
  record_captured "$leader" "$watcher" "$desc"
  wait_gone "$desc" 80 || true
  wait_gone "$watcher" 80 || true
  wait_gone "$leader" 80 || true
  assert_absent_or_fail "$stage-track descendant" "$desc"
  assert_absent_or_fail "$stage-track watcher" "$watcher"
  assert_absent_or_fail "$stage-track leader" "$leader"
  if [[ -f "$dir/continued" ]]; then
    bad "$stage-track cancellation continued the caller loop"
  else
    ok "$stage-track cancellation did not continue the caller loop"
  fi
  if alive "$foreign"; then
    ok "$stage-track foreign sibling remained alive"
    reap_exact "$foreign"
  else
    bad "$stage-track foreign sibling was killed"
  fi
}

run_tracking_window_fixture leader before_leader_track
run_tracking_window_fixture watcher before_watcher_track

# 1) Before readiness publication: marker delayed; signal exact leader only.
_br="$ROOT/before-ready"
mkdir -p "$_br"
: > "$_br/hold-ready"
write_term_desc_cmd "$_br/cmd" "$_br"
write_wrapper "$_br/wrapper" "$_br" "$_br/cmd" 60
sleep 99999 &
_br_foreign=$!
record_captured "$_br_foreign"
FLEET_WALL_TIMEOUT_TEST_PUBLISH="$_br"
FLEET_WALL_TIMEOUT_TEST_HOLD_READY="$_br/hold-ready"
export FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_READY
spawn_wrapper "$_br/wrapper"
_br_wrap=$!
record_captured "$_br_wrap"
unset FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_READY
if ! wait_file "$_br/leader.pid" 80; then
  rm -f "$_br/hold-ready"
  reap_exact "$_br_wrap" "$_br_foreign"
  bad "before-ready: leader.pid never published"
else
  _br_leader=$(read_ident "$_br/leader.pid")
  record_captured "$_br_leader"
  wait_file "$_br/identities.ready" 80 || true
  _br_ok=$(read_ident "$_br/pgrp_ok")
  if [[ "$_br_ok" == "0" ]]; then
    ok "before-ready: cancelled before setpgrp proof (pgrp_ok=0)"
  else
    bad "before-ready: proof was established while HOLD_READY still held (pgrp_ok=${_br_ok:-unset})"
  fi
  kill -s TERM "$_br_wrap" 2>/dev/null || true
  wait "$_br_wrap" 2>/dev/null || true
  wait_gone "$_br_leader" 40 || true
  assert_absent_or_fail "before-ready leader" "$_br_leader"
  if alive "$_br_foreign"; then
    ok "before-ready: foreign sibling untouched (no unproven group signal)"
    reap_exact "$_br_foreign"
  else
    bad "before-ready: foreign sibling killed"
  fi
  rm -f "$_br/hold-ready"
fi

# 2) During watcher TERM grace (timeout path), cancel the wrapper.
_dg="$ROOT/during-grace"
mkdir -p "$_dg"
: > "$_dg/hold-grace"
: > "$_dg/desc.signals"
write_term_desc_cmd "$_dg/cmd" "$_dg"
write_wrapper "$_dg/wrapper" "$_dg" "$_dg/cmd" 2
sleep 99999 &
_dg_foreign=$!
record_captured "$_dg_foreign"
FLEET_WALL_TIMEOUT_TEST_PUBLISH="$_dg"
FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE="$_dg/hold-grace"
export FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE
spawn_wrapper "$_dg/wrapper"
_dg_wrap=$!
record_captured "$_dg_wrap"
unset FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE
if ! wait_file "$_dg/identities.ready" 80 || ! wait_file "$_dg/desc.ready" 80; then
  rm -f "$_dg/hold-grace"
  reap_exact "$_dg_wrap" "$_dg_foreign"
  bad "during-grace: identities never published"
else
  _dg_desc=$(read_ident "$_dg/desc.pid")
  _dg_watch=$(read_ident "$_dg/watcher.pid")
  _dg_leader=$(read_ident "$_dg/leader.pid")
  record_captured "$_dg_desc" "$_dg_watch" "$_dg_leader"
  if ! wait_file "$_dg/in_grace" 200; then
    rm -f "$_dg/hold-grace"
    reap_exact "$_dg_wrap" "$_dg_foreign" "$_dg_desc" "$_dg_watch" "$_dg_leader"
    bad "during-grace: timeout grace never published"
  else
    kill -s TERM "$_dg_wrap" 2>/dev/null || true
    rm -f "$_dg/hold-grace"
    _dg_rc=0
    wait "$_dg_wrap" 2>/dev/null || _dg_rc=$?
    if [[ "$_dg_rc" == "124" || "$_dg_rc" == "0" ]]; then
      bad "during-grace: cancel aliased to timeout/success (status=$_dg_rc)"
    else
      eq "during-grace wrapper status is cancel not 124" "$_dg_rc" "143"
    fi
    wait_gone "$_dg_desc" 40 || true
    wait_gone "$_dg_watch" 40 || true
    assert_absent_or_fail "during-grace descendant" "$_dg_desc" \
      "cancel_ps=$(cat "$_dg/cancel_ps" 2>/dev/null) wrapper=$(cat "$_dg/cancel_wrapper" 2>/dev/null) leader=$_dg_leader"
    assert_absent_or_fail "during-grace watcher" "$_dg_watch"
    if alive "$_dg_foreign"; then
      ok "during-grace: foreign sibling alive"
      reap_exact "$_dg_foreign"
    else
      bad "during-grace: foreign sibling killed"
    fi
  fi
fi

# 3) Immediately after leader exit, before wait/reap.
_al="$ROOT/after-leader"
mkdir -p "$_al"
: > "$_al/hold-wait"
cat > "$_al/cmd" <<CMD
#!/usr/bin/env bash
sleep 99999 &
printf '%s\\n' "\$!" > "$_al/desc.pid"
: > "$_al/desc.ready"
exit 0
CMD
chmod +x "$_al/cmd"
write_wrapper "$_al/wrapper" "$_al" "$_al/cmd" 60
sleep 99999 &
_al_foreign=$!
record_captured "$_al_foreign"
FLEET_WALL_TIMEOUT_TEST_PUBLISH="$_al"
FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_WAIT="$_al/hold-wait"
export FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_WAIT
spawn_wrapper "$_al/wrapper"
_al_wrap=$!
record_captured "$_al_wrap"
unset FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_WAIT
if ! wait_file "$_al/leader_exited" 80 || ! wait_file "$_al/desc.ready" 80; then
  rm -f "$_al/hold-wait"
  reap_exact "$_al_wrap" "$_al_foreign"
  bad "after-leader: leader_exited/desc never published"
else
  _al_desc=$(read_ident "$_al/desc.pid")
  _al_watch=$(read_ident "$_al/watcher.pid")
  _al_leader=$(read_ident "$_al/leader.pid")
  record_captured "$_al_desc" "$_al_watch" "$_al_leader"
  if alive "$_al_desc"; then
    ok "after-leader: descendant still live before reap"
  else
    bad "after-leader: descendant already gone before cancel (hold missed the window)"
  fi
  kill -s TERM "$_al_wrap" 2>/dev/null || true
  rm -f "$_al/hold-wait"
  _al_rc=0
  wait "$_al_wrap" 2>/dev/null || _al_rc=$?
  eq "after-leader wrapper cancel status" "$_al_rc" "143"
  wait_gone "$_al_desc" 40 || true
  wait_gone "$_al_watch" 40 || true
  assert_absent_or_fail "after-leader descendant" "$_al_desc" \
    "cancel_ps=$(cat "$_al/cancel_ps" 2>/dev/null) wrapper=$(cat "$_al/cancel_wrapper" 2>/dev/null) leader=$_al_leader"
  assert_absent_or_fail "after-leader watcher" "$_al_watch"
  if alive "$_al_foreign"; then
    ok "after-leader: foreign sibling alive (no post-wait group signal)"
    reap_exact "$_al_foreign"
  else
    bad "after-leader: foreign sibling killed"
  fi
fi

# 4) After leader wait returns but before the reaped fence is released. The
# pending signal must re-raise without trusting the stale ready marker.
_pw="$ROOT/post-wait"
mkdir -p "$_pw"
: > "$_pw/hold-after-wait"
cat > "$_pw/wrapper" <<WRAP
#!/usr/bin/env bash
trap - HUP INT TERM
# shellcheck disable=SC1090,SC1091
source "$WALL_LIB"
run_with_wall_timeout 60 true
: > "$_pw/continued"
WRAP
chmod +x "$_pw/wrapper"
sleep 99999 &
_pw_foreign=$!
record_captured "$_pw_foreign"
FLEET_WALL_TIMEOUT_TEST_PUBLISH="$_pw"
FLEET_WALL_TIMEOUT_TEST_HOLD_AFTER_LEADER_WAIT="$_pw/hold-after-wait"
export FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_AFTER_LEADER_WAIT
spawn_wrapper "$_pw/wrapper"
_pw_wrap=$!
record_captured "$_pw_wrap"
unset FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_AFTER_LEADER_WAIT
if ! wait_file "$_pw/after_leader_wait" 80; then
  rm -f "$_pw/hold-after-wait"
  reap_exact "$_pw_wrap" "$_pw_foreign"
  bad "post-wait: wait/latch hold was not reached"
else
  _pw_leader=$(read_ident "$_pw/leader.pid")
  _pw_watch=$(read_ident "$_pw/watcher.pid")
  record_captured "$_pw_leader" "$_pw_watch"
  kill -s TERM "$_pw_wrap" 2>/dev/null || true
  rm -f "$_pw/hold-after-wait"
  _pw_rc=0
  wait "$_pw_wrap" 2>/dev/null || _pw_rc=$?
  eq "post-wait wrapper status" "$_pw_rc" "143"
  if [[ -f "$_pw/continued" ]]; then
    bad "post-wait cancellation continued the caller loop"
  else
    ok "post-wait cancellation did not continue the caller loop"
  fi
  assert_absent_or_fail "post-wait old leader" "$_pw_leader"
  assert_absent_or_fail "post-wait old watcher" "$_pw_watch"
  assert_published_guardian_absent "post-wait cancel" "$_pw"
  if alive "$_pw_foreign"; then
    ok "post-wait foreign sibling survived stale-marker boundary"
    reap_exact "$_pw_foreign"
  else
    bad "post-wait foreign sibling was killed"
  fi
fi

# 5) After normal return, poison old identities; signal must not kill them.
_po="$ROOT/poison"
mkdir -p "$_po"
sleep 99999 &
_po_foreign=$!
record_captured "$_po_foreign"
cat > "$_po/wrapper" <<WRAP
#!/usr/bin/env bash
trap - HUP INT TERM
# shellcheck disable=SC1090,SC1091
source "$WALL_LIB"
run_with_wall_timeout 30 true
: > "$_po/returned"
_WT_PID="$_po_foreign"
_WT_PGID="$_po_foreign"
_WT_WATCHER="$_po_foreign"
_WT_PGRP_OK=1
sleep 60
WRAP
chmod +x "$_po/wrapper"
spawn_wrapper "$_po/wrapper"
_po_wrap=$!
record_captured "$_po_wrap"
if ! wait_file "$_po/returned" 80; then
  reap_exact "$_po_wrap" "$_po_foreign"
  bad "poison: wrapper never returned from helper"
else
  kill -s TERM "$_po_wrap" 2>/dev/null || true
  wait "$_po_wrap" 2>/dev/null || true
  if alive "$_po_foreign"; then
    ok "poisoned identities after return did not kill the foreign PID"
    reap_exact "$_po_foreign"
  else
    bad "poisoned identities after return were signaled (traps not restored)"
  fi
fi

# Genuine nested cancellation: run-all can bound a suite that calls the same
# helper. The inner command is in a second proven process group, so the outer
# TERM grace must allow the inner handler to finish its exact-group cleanup.
echo "wall-timeout: nested cancellation cascade"
_nc="$ROOT/nested-cancel"
mkdir -p "$_nc/outer" "$_nc/inner"
: > "$_nc/inner/desc.signals"
: > "$_nc/inner/leader.signals"
write_resistant_leader_desc_cmd "$_nc/inner/cmd" "$_nc/inner"
cat > "$_nc/nested-command" <<WRAP
#!/usr/bin/env bash
trap - HUP INT TERM
# shellcheck disable=SC1090,SC1091
source "$WALL_LIB"
FLEET_WALL_TIMEOUT_TEST_PUBLISH="$_nc/inner"
export FLEET_WALL_TIMEOUT_TEST_PUBLISH
run_with_wall_timeout 60 "$_nc/inner/cmd"
printf '%s\n' "\$?" > "$_nc/inner/fn.status"
: > "$_nc/inner/continued"
WRAP
chmod +x "$_nc/nested-command"
cat > "$_nc/wrapper" <<WRAP
#!/usr/bin/env bash
trap - HUP INT TERM
# shellcheck disable=SC1090,SC1091
source "$WALL_LIB"
run_with_wall_timeout 60 "$_nc/nested-command"
printf '%s\n' "\$?" > "$_nc/outer/fn.status"
: > "$_nc/outer/continued"
WRAP
chmod +x "$_nc/wrapper"
sleep 99999 &
_nc_foreign=$!
record_captured "$_nc_foreign"
FLEET_WALL_TIMEOUT_TEST_PUBLISH="$_nc/outer"
export FLEET_WALL_TIMEOUT_TEST_PUBLISH
spawn_wrapper "$_nc/wrapper"
_nc_wrap=$!
record_captured "$_nc_wrap"
unset FLEET_WALL_TIMEOUT_TEST_PUBLISH
if ! wait_file "$_nc/outer/identities.ready" 100 \
  || ! wait_file "$_nc/inner/identities.ready" 100 \
  || ! wait_file "$_nc/inner/desc.ready" 100; then
  reap_exact "$_nc_wrap" "$_nc_foreign"
  bad "nested-cancel: outer/inner identities never became ready"
else
  _nc_outer_leader=$(read_ident "$_nc/outer/leader.pid")
  _nc_outer_watch=$(read_ident "$_nc/outer/watcher.pid")
  _nc_inner_leader=$(read_ident "$_nc/inner/leader.pid")
  _nc_inner_watch=$(read_ident "$_nc/inner/watcher.pid")
  _nc_desc=$(read_ident "$_nc/inner/desc.pid")
  record_captured "$_nc_outer_leader" "$_nc_outer_watch" \
    "$_nc_inner_leader" "$_nc_inner_watch" "$_nc_desc"
  kill -s TERM "$_nc_wrap" 2>/dev/null || true
  _nc_rc=0
  wait "$_nc_wrap" 2>/dev/null || _nc_rc=$?
  eq "nested-cancel wrapper status" "$_nc_rc" "143"
  if [[ -f "$_nc/outer/continued" || -f "$_nc/inner/continued" ]]; then
    bad "nested-cancel continued an outer or inner caller loop"
  else
    ok "nested-cancel did not continue either caller loop"
  fi
  if grep -Fq TERM "$_nc/inner/desc.signals" 2>/dev/null; then
    ok "nested-cancel descendant received TERM before KILL"
  else
    bad "nested-cancel descendant never observed TERM grace"
  fi
  if grep -Fq LEADER_TERM "$_nc/inner/leader.signals" 2>/dev/null; then
    ok "nested-cancel inner leader resisted TERM through its grace"
  else
    bad "nested-cancel inner leader did not exercise the grace budget"
  fi
  wait_gone "$_nc_desc" 80 || true
  wait_gone "$_nc_inner_watch" 80 || true
  wait_gone "$_nc_inner_leader" 80 || true
  wait_gone "$_nc_outer_watch" 80 || true
  wait_gone "$_nc_outer_leader" 80 || true
  assert_absent_or_fail "nested-cancel descendant" "$_nc_desc"
  assert_absent_or_fail "nested-cancel inner watcher" "$_nc_inner_watch"
  assert_absent_or_fail "nested-cancel inner leader" "$_nc_inner_leader"
  assert_absent_or_fail "nested-cancel outer watcher" "$_nc_outer_watch"
  assert_absent_or_fail "nested-cancel outer leader" "$_nc_outer_leader"
  assert_published_guardian_absent "nested-cancel inner" "$_nc/inner"
  assert_published_guardian_absent "nested-cancel outer" "$_nc/outer"
  if alive "$_nc_foreign"; then
    ok "nested-cancel foreign sibling remained alive"
    reap_exact "$_nc_foreign"
  else
    bad "nested-cancel foreign sibling was killed"
  fi
fi

# Ignore/custom continue → function returns 128+signal (not 0/124).
echo "wall-timeout: ignore/custom cancel returns 128+signal"
run_continuing_term_fixture() {
  local mode="$1" dir="$ROOT/continue-$1" trap_line
  mkdir -p "$dir"
  : > "$dir/desc.signals"
  write_term_desc_cmd "$dir/cmd" "$dir"
  case "$mode" in
    ignored) trap_line="trap '' TERM" ;;
    custom) trap_line="trap 'printf custom > \"$dir/custom.called\"' TERM" ;;
    *) bad "continue fixture: unknown mode $mode"; return 1 ;;
  esac
  cat > "$dir/wrapper" <<WRAP
#!/usr/bin/env bash
$trap_line
# shellcheck disable=SC1090,SC1091
source "$WALL_LIB"
run_with_wall_timeout 60 "$dir/cmd"
printf '%s\\n' "\$?" > "$dir/fn.status"
: > "$dir/continued"
WRAP
  chmod +x "$dir/wrapper"
  : > "$dir/hold-grace"
  FLEET_WALL_TIMEOUT_TEST_PUBLISH="$dir"
  FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE="$dir/hold-grace"
  export FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE
  spawn_wrapper "$dir/wrapper"
  local wrapper=$!
  record_captured "$wrapper"
  unset FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE
  if ! wait_file "$dir/identities.ready" 80 || ! wait_file "$dir/desc.ready" 80; then
    rm -f "$dir/hold-grace"
    reap_exact "$wrapper"
    bad "$mode-TERM: identities never published"
    return 1
  fi

  local desc watcher leader fns
  desc=$(read_ident "$dir/desc.pid")
  watcher=$(read_ident "$dir/watcher.pid")
  leader=$(read_ident "$dir/leader.pid")
  record_captured "$desc" "$watcher" "$leader"
  kill -s TERM "$wrapper" 2>/dev/null || true
  if ! wait_file "$dir/in_grace" 200 || ! wait_contains "$dir/desc.signals" TERM 40; then
    rm -f "$dir/hold-grace"
    reap_exact "$wrapper" "$desc" "$watcher" "$leader"
    bad "$mode-TERM: TERM grace was not observed"
    return 1
  fi
  rm -f "$dir/hold-grace"
  if ! wait_file "$dir/continued" 80; then
    reap_exact "$wrapper" "$desc" "$watcher" "$leader"
    bad "$mode-TERM: wrapper did not continue after restored re-raise"
  else
    fns=$(read_ident "$dir/fn.status")
    eq "$mode-TERM returns 128+TERM" "$fns" "143"
    if [[ "$fns" == "0" || "$fns" == "124" ]]; then
      bad "$mode-TERM aliased to success/timeout"
    fi
    if [[ "$mode" == "custom" ]]; then
      [[ -f "$dir/custom.called" ]] \
        && ok "custom-TERM restored handler ran on re-raise" \
        || bad "custom-TERM restored handler did not run"
    fi
    wait_gone "$desc" 40 || true
    wait_gone "$watcher" 40 || true
    wait_gone "$leader" 40 || true
    assert_absent_or_fail "$mode-TERM descendant" "$desc"
    assert_absent_or_fail "$mode-TERM watcher" "$watcher"
    assert_absent_or_fail "$mode-TERM leader" "$leader"
    assert_published_guardian_absent "$mode-TERM cancel" "$dir"
    wait_gone "$wrapper" 20 || reap_exact "$wrapper"
  fi
}

run_continuing_term_fixture ignored
run_continuing_term_fixture custom

# Non-vacuity: frozen pre-#269 helper (no HUP/INT/TERM cleanup) reproduces
# the historical leak (SHA 313127a2e8c53da6890d0ab400c42813a8d14591). Current
# helper must prove the repair. Separate invocations.
echo "wall-timeout: historical leak control vs current repair"
_lk="$ROOT/leak-control"
mkdir -p "$_lk"
write_term_desc_cmd "$_lk/cmd" "$_lk"
cat > "$_lk/pre269.sh" <<'PRE'
#!/usr/bin/env bash
# Frozen minimal pre-#269 helper: process group, no cancellation traps.
# Historical evidence SHA 313127a2e8c53da6890d0ab400c42813a8d14591.
run_with_wall_timeout_pre269_leak() {
  local pid
  perl -e '
    setpgrp(0,0);
    exec { $ARGV[0] } @ARGV or exit 127;
  ' "$@" <&0 &
  pid=$!
  wait "$pid" || return $?
}
PRE
cat > "$_lk/wrapper-leak" <<WRAP
#!/usr/bin/env bash
trap - HUP INT TERM
# shellcheck disable=SC1090
source "$_lk/pre269.sh"
run_with_wall_timeout_pre269_leak "$_lk/cmd"
WRAP
chmod +x "$_lk/wrapper-leak"
bash "$_lk/wrapper-leak" &
_lk_wrap=$!
record_captured "$_lk_wrap"
if ! wait_file "$_lk/desc.ready" 80; then
  reap_exact "$_lk_wrap"
  bad "leak-control: descendant never ready"
else
  _lk_desc=$(read_ident "$_lk/desc.pid")
  record_captured "$_lk_desc"
  kill -s TERM "$_lk_wrap" 2>/dev/null || true
  wait "$_lk_wrap" 2>/dev/null || true
  sleep 0.2 2>/dev/null || sleep 1
  if alive "$_lk_desc"; then
    ok "leak-control: frozen pre-fix helper leaked the descendant (historical red oracle)"
    reap_exact "$_lk_desc"
  else
    bad "leak-control: frozen helper did not reproduce the leak (control is vacuous)"
  fi
fi

# Current helper repair (TERM fixture already proved cleanup; re-run a
# focused replica so the control and the repair stay separate invocations).
_rp="$ROOT/repair"
mkdir -p "$_rp"
: > "$_rp/hold-grace"
: > "$_rp/desc.signals"
write_term_desc_cmd "$_rp/cmd" "$_rp"
write_wrapper "$_rp/wrapper" "$_rp" "$_rp/cmd" 60
FLEET_WALL_TIMEOUT_TEST_PUBLISH="$_rp"
FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE="$_rp/hold-grace"
export FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE
spawn_wrapper "$_rp/wrapper"
_rp_wrap=$!
record_captured "$_rp_wrap"
unset FLEET_WALL_TIMEOUT_TEST_PUBLISH FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE
if ! wait_file "$_rp/identities.ready" 80 || ! wait_file "$_rp/desc.ready" 80; then
  rm -f "$_rp/hold-grace"
  reap_exact "$_rp_wrap"
  bad "repair: identities never published"
else
  _rp_desc=$(read_ident "$_rp/desc.pid")
  _rp_watch=$(read_ident "$_rp/watcher.pid")
  record_captured "$_rp_desc" "$_rp_watch"
  kill -s TERM "$_rp_wrap" 2>/dev/null || true
  wait_file "$_rp/in_grace" 200 || true
  rm -f "$_rp/hold-grace"
  wait "$_rp_wrap" 2>/dev/null || true
  wait_gone "$_rp_desc" 40 || true
  wait_gone "$_rp_watch" 40 || true
  assert_absent_or_fail "repair descendant" "$_rp_desc"
  assert_absent_or_fail "repair watcher" "$_rp_watch"
fi

# =============================================================================
# #319 — capture disposition: timeout never reports as "no tally line"
# =============================================================================
echo "wall-timeout: #319 capture disposition"

CAP_FN="$ROOT/read-capture.sh"
sed -n '/^# gibson_suite_read_capture begin$/,/^# gibson_suite_read_capture end$/p' "$RUN_ALL" > "$CAP_FN"
_gs_out=""; _gs_ec=0; _gs_elapsed=0; _gs_tally=""
if [[ -s "$CAP_FN" ]] && grep -F 'gibson_suite_read_capture()' "$CAP_FN" >/dev/null; then
  ok "run-all exposes gibson_suite_read_capture"
  # shellcheck disable=SC1090,SC1091
  . "$CAP_FN"
else
  bad "run-all missing gibson_suite_read_capture"
fi

if declare -F gibson_suite_read_capture >/dev/null 2>&1; then
  _cdir="$ROOT/cap-disp"
  mkdir -p "$_cdir"

  : > "$_cdir/empty.out"
  printf '124\n' > "$_cdir/empty.ec"
  printf '12\n' > "$_cdir/empty.elapsed"
  gibson_suite_read_capture "$_cdir/empty" 10
  eq "ec 124 with no tally reports timed out" "$_gs_tally" "timed out after 10s"
  eq "ec 124 is preserved" "$_gs_ec" "124"

  printf '3 passed, 1 failed\n' > "$_cdir/tally.out"
  printf '124\n' > "$_cdir/tally.ec"
  printf '12\n' > "$_cdir/tally.elapsed"
  gibson_suite_read_capture "$_cdir/tally" 10
  eq "ec 124 wins over an existing tally line" "$_gs_tally" "timed out after 10s"

  printf '3 passed, 1 failed\n' > "$_cdir/ok.out"
  printf '1\n' > "$_cdir/ok.ec"
  printf '2\n' > "$_cdir/ok.elapsed"
  gibson_suite_read_capture "$_cdir/ok" 10
  eq "ordinary failure keeps the suite tally" "$_gs_tally" "3 passed, 1 failed"
  eq "ordinary failure keeps exit code" "$_gs_ec" "1"

  : > "$_cdir/miss.out"
  rm -f "$_cdir/miss.ec"
  printf '12\n' > "$_cdir/miss.elapsed"
  gibson_suite_read_capture "$_cdir/miss" 10
  eq "missing .ec under timeout reports timed out" "$_gs_tally" "timed out after 10s"
  eq "missing .ec under timeout is 124" "$_gs_ec" "124"

  : > "$_cdir/kill.out"
  printf '137\n' > "$_cdir/kill.ec"
  printf '10\n' > "$_cdir/kill.elapsed"
  gibson_suite_read_capture "$_cdir/kill" 10
  eq "SIGKILL at the wall reports timed out" "$_gs_tally" "timed out after 10s"
  eq "SIGKILL at the wall is classified 124" "$_gs_ec" "124"

  _mut="$ROOT/read-capture.mut.sh"
  sed 's/_gs_ec" -eq 124/_gs_ec" -eq 999999/' "$CAP_FN" > "$_mut"
  # shellcheck disable=SC1090,SC1091
  . "$_mut"
  : > "$_cdir/mut.out"
  printf '124\n' > "$_cdir/mut.ec"
  printf '12\n' > "$_cdir/mut.elapsed"
  gibson_suite_read_capture "$_cdir/mut" 10
  eq "mutation: ignoring 124 yields no tally line" "$_gs_tally" "no tally line"
  # shellcheck disable=SC1090,SC1091
  . "$CAP_FN"
else
  bad "gibson_suite_read_capture is not callable"
fi

echo "wall-timeout: #319 SIGPIPE-safe grep wrapper"
SUITE_ENV="$ROOT/suite-env.sh"
# Rebuild the production wrapper the same way run-all does: pin real grep,
# then the quoted function body.
_GIBSON_REAL_GREP=$(type -P grep 2>/dev/null || true)
if [[ ! -x "$_GIBSON_REAL_GREP" ]]; then
  if [[ -x /usr/bin/grep ]]; then
    _GIBSON_REAL_GREP=/usr/bin/grep
  elif [[ -x /bin/grep ]]; then
    _GIBSON_REAL_GREP=/bin/grep
  fi
fi
{
  printf '_GIBSON_REAL_GREP=%s\n' "$_GIBSON_REAL_GREP"
  sed -n '/^# Sourced via BASH_ENV for every run-all suite/,/^SUITEENV$/p' "$RUN_ALL" \
    | sed '$d'
} > "$SUITE_ENV"
if [[ -s "$SUITE_ENV" ]] && grep -F '_GIBSON_REAL_GREP' "$SUITE_ENV" >/dev/null \
   && grep -F 'Sourced via BASH_ENV' "$SUITE_ENV" >/dev/null; then
  ok "run-all writes a BASH_ENV grep wrapper"
else
  bad "run-all missing BASH_ENV grep wrapper"
  : > "$SUITE_ENV"
fi

# Pipe buffer on macOS is 16KiB; the producer must exceed it or printf
# can finish before grep -q closes and the mutation becomes vacuous.
_payload=$(printf '%s\n' 'cannot be combined' "$(python3 -c 'print("x"*200000)')" 'not a complete gate')
_pipefail_grep_q() {
  local envfile="$1"
  # BASH_ENV empty disables run-all's inherited wrapper (mutation path).
  BASH_ENV="$envfile" bash -c '
    set -uo pipefail
    out="$1"
    if printf "%s\n" "$out" | grep -Fq "cannot be combined"; then
      exit 0
    fi
    exit 1
  ' bash "$_payload"
}
if _pipefail_grep_q "$SUITE_ENV"; then
  ok "BASH_ENV grep wrapper: pipefail + grep -q on match-at-start payload succeeds"
else
  bad "BASH_ENV grep wrapper failed to make grep -q SIGPIPE-safe"
fi
if _pipefail_grep_q ""; then
  bad "mutation: grep -q without the wrapper unexpectedly survived a match-at-start payload"
else
  ok "mutation: grep -q without the wrapper fails closed on match-at-start payload"
fi

echo "wall-timeout: #319 stress harness"
STRESS="$DIR/run-all-stress.sh"
if [[ -x "$STRESS" ]]; then
  ok "run-all-stress.sh is executable"
else
  bad "run-all-stress.sh missing or not executable"
fi
_st_out=$(bash "$STRESS" --help 2>&1); _st_rc=$?
if [[ "$_st_rc" -eq 0 ]] && printf '%s\n' "$_st_out" | grep -F 'N times' >/dev/null; then
  ok "run-all-stress.sh --help names N parallel runs"
else
  bad "run-all-stress.sh --help failed (rc=$_st_rc)"
fi
_st_out=$(bash "$STRESS" --runs 0 2>&1); _st_rc=$?
if [[ "$_st_rc" -eq 2 ]] && printf '%s\n' "$_st_out" | grep -F 'whole number' >/dev/null; then
  ok "run-all-stress.sh --runs 0 is a usage error"
else
  bad "run-all-stress.sh --runs 0 was not refused (rc=$_st_rc)"
fi
_st_out=$(bash "$STRESS" --definitely-not 2>&1); _st_rc=$?
if [[ "$_st_rc" -eq 2 ]] && printf '%s\n' "$_st_out" | grep -F 'unknown argument' >/dev/null; then
  ok "run-all-stress.sh unknown flag exits 2"
else
  bad "run-all-stress.sh unknown flag was not a usage error (rc=$_st_rc)"
fi

echo "wall-timeout.test.sh: $PASS passed, $fails failed"
[[ "$fails" -eq 0 ]]
