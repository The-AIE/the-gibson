#!/usr/bin/env bash
# run-all.sh — Gibson's own green gate (issue #89)
set -uo pipefail

usage() {
  cat <<'EOF'
run-all.sh — run every Gibson sensor and report one verdict

WHAT IT DOES
  1. shellcheck -S warning over scripts/*.sh and scripts/tests/*.sh, compared to
     scripts/tests/shellcheck-baseline.txt — a NEW finding fails, a fixed one
     tells you to shrink the baseline.
  2. bash -n over the same files (and, when docker is available, bash 3.2 too,
     because stock macOS ships 3.2 and half our portability scars come from it).
  3. scripts/injection-scan.sh over everything an agent ingests.
  4. Every scripts/tests/*.test.sh.

  Suites listed in the QUARANTINE block below are known-red with a burn-down
  issue. They still run, they are still reported, and they do not fail the gate
  — but a quarantined suite that starts PASSING also fails the gate, so the list
  can only shrink (Law 9). Nothing here is ever silently skipped (Law 8).

WHY
  Gibson had thirteen sensor suites and no CI, so four of them were red on main
  and nobody noticed (#90). A sensor nobody runs is documentation.

USAGE
  scripts/tests/run-all.sh [--only PATTERN] [--timeout SECONDS]
                           [--no-quarantine] [--list-quarantine] [--quiet]
  scripts/tests/run-all.sh --help

  --only PATTERN     run only suites whose filename matches PATTERN
  --timeout SECONDS  per-suite timeout (default 600; 0 disables)
  --no-quarantine    treat quarantined suites as required — the burn-down view
  --list-quarantine  print the quarantine list with issue links and exit
  --quiet            suite summary lines only, no per-assertion output

EXIT
  0  everything required is green
  1  a required check failed, or a quarantined suite unexpectedly passed
  2  usage error
EOF
}

# --- quarantine -------------------------------------------------------------
# suite<TAB>issue<TAB>one-line reason. Shrink this; never grow it without a PR
# that says why in the body.
QUARANTINE=$(cat <<'EOF'
loop-handoff.test.sh	92	halt reclaim gate fails on Linux (kernel-gate burn-down in progress)
EOF
)

# Minimum jq. release-preflight validates approval timestamps through jq, and on
# jq 1.6 an impossible calendar date parses instead of erroring — the merge gate
# then returns READY on evidence it cannot verify (#91). Ubuntu 22.04 ships 1.6,
# so this is not hypothetical. A gate that changes its verdict with the host's jq
# is not a gate.
JQ_MIN_MAJOR=1
JQ_MIN_MINOR=7

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
BASELINE="$SCRIPT_DIR/shellcheck-baseline.txt"

ONLY=""
TIMEOUT=600
USE_QUARANTINE=1
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --no-quarantine) USE_QUARANTINE=0; shift ;;
    --quiet) QUIET=1; shift ;;
    --list-quarantine)
      echo "$QUARANTINE" | while IFS="$(printf '\t')" read -r s i r; do
        [[ -n "$s" ]] || continue
        printf '%-28s #%-4s %s\n' "$s" "$i" "$r"
      done
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run-all.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*) echo "run-all.sh: --timeout wants a whole number of seconds" >&2; exit 2 ;;
esac

cd "$REPO_ROOT" || exit 2

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
[[ -t 1 ]] || { RED=""; GRN=""; YEL=""; OFF=""; }

FAILED=""      # names of required checks that failed
QUARANTINED="" # quarantined suites that failed as expected
ESCAPED=""     # quarantined suites that passed — shrink the list

quarantine_issue() {
  echo "$QUARANTINE" | awk -F'\t' -v s="$1" '$1 == s { print $2; exit }'
}

is_quarantined() {
  [[ "$USE_QUARANTINE" -eq 1 ]] && [[ -n "$(quarantine_issue "$1")" ]]
}

# Run a command with a timeout when one is available; 124 means it hung.
run_limited() {
  if [[ "$TIMEOUT" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" "$@"
  else
    "$@"
  fi
}

SH_FILES=$(find scripts -name '*.sh' -type f | sort)

# --- 0. toolchain -----------------------------------------------------------
echo "== toolchain"
if command -v jq >/dev/null 2>&1; then
  JQ_V=$(jq --version 2>/dev/null | sed 's/^jq-//')
  JQ_MAJ=${JQ_V%%.*}; JQ_REST=${JQ_V#*.}; JQ_MIN=${JQ_REST%%.*}
  case "$JQ_MAJ$JQ_MIN" in
    *[!0-9]*|'') echo "${RED}  FAIL${OFF} — cannot read jq version ('$JQ_V')"; FAILED="$FAILED jq-version" ;;
    *)
      if [[ "$JQ_MAJ" -gt "$JQ_MIN_MAJOR" ]] ||
         { [[ "$JQ_MAJ" -eq "$JQ_MIN_MAJOR" ]] && [[ "$JQ_MIN" -ge "$JQ_MIN_MINOR" ]]; }; then
        echo "${GRN}  ok${OFF}   — jq $JQ_V"
      else
        echo "${RED}  FAIL${OFF} — jq $JQ_V is below ${JQ_MIN_MAJOR}.${JQ_MIN_MINOR}: release-preflight accepts"
        echo "         unverifiable approval timestamps on this jq and returns READY (#91)"
        FAILED="$FAILED jq-too-old"
      fi ;;
  esac
else
  echo "${RED}  FAIL${OFF} — jq not installed; preflight and several sensors need it"
  FAILED="$FAILED jq-missing"
fi

# The claim suites build throwaway repos and commit into them, so they need an
# identity. Inherit one if the host has it; otherwise supply a local one rather
# than failing for a reason that has nothing to do with the code under test.
if [[ -z "${GIT_AUTHOR_EMAIL:-}" ]] && ! git config user.email >/dev/null 2>&1; then
  export GIT_AUTHOR_NAME="gibson-run-all" GIT_AUTHOR_EMAIL="run-all@gibson.invalid"
  export GIT_COMMITTER_NAME="gibson-run-all" GIT_COMMITTER_EMAIL="run-all@gibson.invalid"
  echo "${YEL}  NOTE${OFF} — no git identity on this host; using a throwaway one (#101)"
fi

# --- 1. shellcheck vs baseline ---------------------------------------------
echo "== shellcheck (-S warning, vs baseline)"
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  # awk, not sed: "\t" in a sed replacement is a literal t on BSD sed (#93 is
  # the same lesson one layer down — portability shims that work by accident).
  CURRENT=$(shellcheck -S warning -f gcc $SH_FILES 2>/dev/null |
    awk 'match($0, /\[SC[0-9]+\]$/) {
           code = substr($0, RSTART + 1, RLENGTH - 2)
           split($0, a, ":")
           print a[1] "\t" code
         }' | sort -u || true)
  BASE=$( [[ -f "$BASELINE" ]] && grep -vE '^\s*(#|$)' "$BASELINE" | sort || true )

  NEWF=$(comm -23 <(echo "$CURRENT") <(echo "$BASE") | grep -E '\S' || true)
  GONE=$(comm -13 <(echo "$CURRENT") <(echo "$BASE") | grep -E '\S' || true)

  if [[ -n "$NEWF" ]]; then
    echo "${RED}  FAIL${OFF} — new shellcheck findings not in the baseline:"
    echo "$NEWF" | sed 's/^/         /'
    FAILED="$FAILED shellcheck"
  elif [[ -n "$GONE" ]]; then
    echo "${RED}  FAIL${OFF} — baseline entries no longer reported; delete them from"
    echo "         $(basename "$BASELINE") so the ratchet holds:"
    echo "$GONE" | sed 's/^/         /'
    FAILED="$FAILED shellcheck-baseline-stale"
  else
    echo "${GRN}  ok${OFF}   — no findings outside the baseline"
  fi
else
  echo "${RED}  FAIL${OFF} — shellcheck not installed; the gate cannot vouch for these scripts"
  FAILED="$FAILED shellcheck-missing"
fi

# --- 2. syntax --------------------------------------------------------------
echo "== bash -n"
SYNTAX_BAD=""
for f in $SH_FILES; do
  bash -n "$f" 2>/tmp/run-all-syntax.$$ || {
    echo "${RED}  FAIL${OFF} — $f"; sed 's/^/         /' /tmp/run-all-syntax.$$
    SYNTAX_BAD=1
  }
done
rm -f /tmp/run-all-syntax.$$
if [[ -n "$SYNTAX_BAD" ]]; then FAILED="$FAILED bash-n"; else
  echo "${GRN}  ok${OFF}   — $(echo "$SH_FILES" | wc -l | tr -d ' ') scripts parse"
fi

echo "== bash 3.2 (stock macOS)"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  if run_limited docker run --rm -v "$REPO_ROOT:/w" -w /w bash:3.2 \
       bash -n $SH_FILES >/tmp/run-all-32.$$ 2>&1; then
    echo "${GRN}  ok${OFF}   — parses under bash 3.2"
  else
    echo "${RED}  FAIL${OFF} — bash 3.2 syntax:"; sed 's/^/         /' /tmp/run-all-32.$$
    FAILED="$FAILED bash-3.2"
  fi
  rm -f /tmp/run-all-32.$$
else
  echo "${YEL}  SKIP${OFF} — no usable docker; bash 3.2 unverified on this host"
fi

# --- 3. injection scan ------------------------------------------------------
echo "== injection-scan"
if [[ -x scripts/injection-scan.sh ]]; then
  if OUT=$(./scripts/injection-scan.sh 2>&1); then
    echo "${GRN}  ok${OFF}   — ${OUT##*$'\n'}"
  else
    echo "${RED}  FAIL${OFF} — invisible characters found:"; echo "$OUT" | sed 's/^/         /'
    FAILED="$FAILED injection-scan"
  fi
else
  echo "${RED}  FAIL${OFF} — scripts/injection-scan.sh missing or not executable"
  FAILED="$FAILED injection-scan-missing"
fi

# --- 4. sensor suites -------------------------------------------------------
echo "== sensors"
for suite in scripts/tests/*.test.sh; do
  name=$(basename "$suite")
  [[ -z "$ONLY" || "$name" == *"$ONLY"* ]] || continue

  if [[ ! -x "$suite" ]]; then
    echo "${RED}  FAIL${OFF} — $name is not executable"
    FAILED="$FAILED $name"
    continue
  fi

  out=$(run_limited "$suite" 2>&1); ec=$?
  # grep -o, not a greedy sed capture: `.*([0-9]+ passed` eats all but the last
  # digit and turns "42 passed" into "2 passed".
  tally=$(echo "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -1)
  [[ -n "$tally" ]] || tally="no tally line"
  [[ "$ec" -eq 124 ]] && tally="timed out after ${TIMEOUT}s"

  if [[ "$QUIET" -eq 0 && "$ec" -ne 0 ]]; then
    echo "$out" | grep -E '^\s*FAIL|unbound variable|command not found' |
      head -20 | sed 's/^/         /'
  fi

  if [[ "$ec" -eq 0 ]]; then
    if is_quarantined "$name"; then
      echo "${RED}  FAIL${OFF} — $name PASSES but is quarantined (#$(quarantine_issue "$name")) — remove it from the list"
      ESCAPED="$ESCAPED $name"
    else
      echo "${GRN}  ok${OFF}   — $name: $tally"
    fi
  elif is_quarantined "$name"; then
    echo "${YEL}  KNOWN${OFF}— $name: $tally (quarantined, #$(quarantine_issue "$name"))"
    QUARANTINED="$QUARANTINED $name"
  else
    echo "${RED}  FAIL${OFF} — $name: $tally (exit $ec)"
    FAILED="$FAILED $name"
  fi
done

# --- verdict ----------------------------------------------------------------
echo
n_fail=$(echo "$FAILED" | wc -w | tr -d ' ')
n_quar=$(echo "$QUARANTINED" | wc -w | tr -d ' ')
n_esc=$(echo "$ESCAPED" | wc -w | tr -d ' ')

if [[ "$n_quar" -gt 0 ]]; then
  echo "quarantined (known red, burn-down issues open):$QUARANTINED"
fi
if [[ "$n_esc" -gt 0 ]]; then
  echo "quarantined but passing — shrink the list:$ESCAPED"
fi
if [[ "$n_fail" -gt 0 ]]; then
  echo "failed:$FAILED"
fi

if [[ "$n_fail" -eq 0 && "$n_esc" -eq 0 ]]; then
  echo "run-all: GREEN — 0 failed, $n_quar quarantined"
  exit 0
fi
echo "run-all: RED — $n_fail failed, $n_esc escaped quarantine, $n_quar quarantined"
exit 1
