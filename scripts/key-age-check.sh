#!/usr/bin/env bash
# key-age-check.sh — advisory GitHub App key-file age sensor (issue #221)
#
# Compares each named key file's mtime to a day-count threshold and prints a
# table. Successful runs always exit 0, including when rows are STALE.
# Nonzero only on usage / flag errors. Never prints file contents, never
# calls GitHub, never rotates a key.
#
# Portable on macOS Bash 3.2 and Linux. Docs: docs/runbooks/key-lifecycle.md
set -euo pipefail

usage() {
  cat <<'EOF'
key-age-check.sh — advisory age check for per-lane GitHub App key files

WHAT IT DOES
  Reads the mtime of each key file you name (or the three inventory defaults
  on this machine) and prints a table: path, mtime, age in days, status.
  Status is STALE when age >= --threshold DAYS, otherwise OK. Missing,
  unreadable, symlink, and non-regular files get their own status and still
  do not fail the run.

WHAT IT DOES NOT DO
  Never prints key material. Never calls GitHub. Never rotates, suspends,
  or replaces a key. Never exits nonzero because a key is old.

WHY
  The three lane-bot identities (cos-agent-lanes, aie-agent-lanes-grok,
  aie-agent-lanes-mini) had no expiry alarm (#221). An operator can see
  age without turning age into a merge gate.

RISKS
  - Advisory only: a STALE row is information, not a rotate-now order.
    Secret rotation is human gate G4.
  - Cadence is an OWNER DECISION — proposed 180d, not in force until Mark
    approves. Passing --threshold 180 does not make 180d policy.
  - Defaults point at ~/.claude/secrets/*.pem on the machine you run on.
    Missing files print MISSING; they are not created.

USAGE
  key-age-check.sh --threshold DAYS [--now EPOCH] [KEYFILE...]
  key-age-check.sh --help

  --threshold DAYS   required. Non-negative integer day count.
  --now EPOCH        injectable "now" as unix seconds (tests). Default: clock.
  KEYFILE            one or more paths. If omitted, the inventory defaults:
                       ~/.claude/secrets/cos-agent-app.pem
                       ~/.claude/secrets/aie-agent-lanes-grok.pem
                       ~/.claude/secrets/aie-agent-lanes-mini.pem

EXIT
  0  table printed (advisory — STALE/MISSING/… still 0)
  2  usage error (unknown flag, bad --threshold, bad --now)

EXAMPLES
  ./scripts/key-age-check.sh --threshold 180
  ./scripts/key-age-check.sh --threshold 180 /path/to/one.pem
EOF
}

die_usage() {
  echo "key-age-check.sh: $*" >&2
  exit 2
}

# Non-negative decimal integer, no leading zeros (except a lone 0), length-capped
# so later $(( )) cannot see an overflow candidate.
is_nonneg_int() {
  local s="$1" max="${2:-10}"
  case "$s" in
    ''|*[!0-9]*) return 1 ;;
    0) return 0 ;;
    0*) return 1 ;;
  esac
  [[ ${#s} -le "$max" ]]
}

THRESHOLD=""
NOW=""
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --threshold)
      [[ $# -ge 2 ]] || die_usage "--threshold requires a day count"
      THRESHOLD="$2"
      shift 2
      ;;
    --now)
      [[ $# -ge 2 ]] || die_usage "--now requires a unix epoch"
      NOW="$2"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        FILES+=("$1")
        shift
      done
      break
      ;;
    -*)
      echo "key-age-check.sh: unknown flag: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

[[ -n "$THRESHOLD" ]] || die_usage "--threshold DAYS is required"
is_nonneg_int "$THRESHOLD" 5 || die_usage "--threshold must be a non-negative integer day count (at most 5 digits)"

if [[ -z "$NOW" ]]; then
  NOW=$(date -u +%s) || die_usage "could not read the system clock"
fi
is_nonneg_int "$NOW" 11 || die_usage "--now must be a non-negative unix epoch"

if [[ ${#FILES[@]} -eq 0 ]]; then
  FILES=(
    "${HOME}/.claude/secrets/cos-agent-app.pem"
    "${HOME}/.claude/secrets/aie-agent-lanes-grok.pem"
    "${HOME}/.claude/secrets/aie-agent-lanes-mini.pem"
  )
fi

# GNU first: `stat -f %m` on Linux is --file-system, not mtime. L-050 / #99.
file_mtime_epoch() {
  local f="$1" mt
  mt=$(stat -c %Y -- "$f" 2>/dev/null || stat -f %m -- "$f" 2>/dev/null) || mt=""
  case "$mt" in
    ''|*[!0-9]*) echo "" ;;
    *) echo "$mt" ;;
  esac
}

fmt_iso() {
  local epoch="$1"
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    printf '%s' "$epoch"
}

printf '%-56s %-20s %8s  %s\n' "PATH" "MTIME" "AGE_DAYS" "STATUS"

for f in "${FILES[@]}"; do
  [[ -n "$f" ]] || die_usage "empty key-file path"

  status=""
  mtime_disp="-"
  age_disp="-"

  if [[ -L "$f" ]]; then
    status="SYMLINK"
  elif [[ ! -e "$f" ]]; then
    status="MISSING"
  elif [[ -b "$f" || -c "$f" || -p "$f" || -S "$f" ]]; then
    status="DEVICE"
  elif [[ -d "$f" ]]; then
    status="NOT-A-FILE"
  elif [[ ! -f "$f" ]]; then
    status="NOT-A-FILE"
  else
    mt=$(file_mtime_epoch "$f")
    if [[ -z "$mt" ]]; then
      status="UNREADABLE"
    else
      mtime_disp=$(fmt_iso "$mt")
      if [[ ${#mt} -gt 11 ]]; then
        status="UNREADABLE"
        mtime_disp="-"
      elif [[ "$mt" -gt "$NOW" ]]; then
        status="FUTURE"
        age_disp="0"
      else
        age_disp=$(( (NOW - mt) / 86400 ))
        if [[ "$age_disp" -ge "$THRESHOLD" ]]; then
          status="STALE"
        else
          status="OK"
        fi
      fi
    fi
  fi

  printf '%-56s %-20s %8s  %s\n' "$f" "$mtime_disp" "$age_disp" "$status"
done

exit 0
