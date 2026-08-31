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

fails=0
ok()  { printf '  ok   — %s\n' "$1"; }
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
  if [[ "$ec" -eq 2 ]] && printf '%s\n' "$out" | grep -Fq 'whole number of seconds'; then
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
if [[ "$ec" -eq 2 ]] && printf '%s\n' "$out" | grep -Fq 'requires perl or python3'; then
  ok "missing portable runtime fails before suites with remediation"
else
  bad "portable-runtime preflight was not reached (exit $ec): $out"
fi

grep -Fq 'timed out after ${TIMEOUT}s' "$RUN_ALL" \
  && ok "timed-out disposition remains distinct" \
  || bad "timed-out disposition message is missing"

if [[ "$fails" -gt 0 ]]; then
  echo "wall-timeout: $fails FAILED"
  exit 1
fi
echo "wall-timeout: all passed"
exit 0
