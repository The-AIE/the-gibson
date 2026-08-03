#!/usr/bin/env bash
# validate-loop-state.sh — shared schema + optional freshness check for gibson/loop-state.md
#
# Quiet on success (exit 0, zero output). Nonzero + diagnostics on stderr when invalid.
# The solo-loop driver (scripts/loop.sh) and the future no-progress sensor (#63) share
# this primitive so there is exactly one timestamp parser and one key contract.
#
# Runtime dependency: python3 on PATH for strict UTC calendar validation and optional
# --min-updated comparison. Absence fails closed with an explicit diagnostic; values
# are never shell-eval'd (python3 argv only).
#
# Portable on macOS Bash 3.2 and Linux (no associative arrays).
set -euo pipefail

usage() {
  cat <<'EOF'
validate-loop-state.sh — validate gibson/loop-state.md (quiet on success)

WHAT IT DOES
  Reads a loop-state file and asserts the ten required column-zero keys are each
  present exactly once, with hat/next_hat enum, round, parked, and strict UTC
  `updated` rules. Optionally requires `updated` to be at or after a lower bound.

WHY
  loop-state is the loop's only memory. A free-form rewrite that drops next_hat
  or typos a hat used to be silently defaulted to builder. One shared validator
  makes corruption loud and gives #63's staleness sensor the same parser.

USAGE
  validate-loop-state.sh <file>
  validate-loop-state.sh <file> --min-updated 'YYYY-MM-DDTHH:MM:SSZ'

  <file>              path to gibson/loop-state.md (or any candidate)
  --min-updated TS    require updated >= TS (exact strict UTC instant; quote it).
                      TS must be nonempty valid strict UTC; an explicit empty
                      argument is a usage error (never means "no bound").

OPTIONS
  -h, --help          this text

EXIT
  0  valid (and fresh enough when --min-updated is set); zero stdout/stderr
  1  invalid / stale / unreadable / missing / missing python3; diagnostics on stderr
  2  bad invocation

CONTRACT (ten required keys, column zero, exactly once each)
  updated, issue, pr, hat, next_hat, round, parked, handoff, handoff_sha, next_action

  The operational contract is ten keys. Early issue prose sometimes enumerated
  nine and omitted `handoff_sha`; the live schema and this validator always
  require `handoff_sha` (empty value allowed). Missing `handoff_sha` fails closed
  as schema corruption — migration is "add the key", never silent default.

  Extra keys (e.g. notes) are allowed. Indentation and # comments never satisfy
  a required key. Duplicates fail.

  FIELD GRAMMAR (shared with scripts/loop.sh read_field — one contract)
    Column-zero keys only: ^[A-Za-z_][A-Za-z0-9_]*:
    After the first colon, exactly one optional ASCII space is stripped from the
    value; no further trim. So `key:value` and `key: value` are identical.
    Empty values are permitted (`key:` and `key: `). Colons inside values are
    fine. Tabs are NOT the optional separator (a tab after `:` is value data).
    Leading-space keys, duplicate keys, and non-column-zero lookalikes fail or
    do not satisfy a required key. Canonical writer form is `key: value`.

  hat / next_hat ∈ builder | test-engineer | reviewer | ux-evaluator | security
                   | release | historian | decomposer | planner
  round          non-negative base-10 integer (digits only)
  parked         exactly true or false
  updated        real strict UTC YYYY-MM-DDTHH:MM:SSZ (no fractions, no offsets,
                 calendar-valid — not a Date.parse rollover). Empty is invalid
                 even without --min-updated; the ten-key schema always requires
                 a real timestamp here.

RUNTIME
  python3 must be on PATH. It validates calendar-real timestamps and compares
  --min-updated bounds. Timestamps and state values are passed as argv data only
  — never interpolated into python source and never shell-eval'd.

SAFETY
  Values are never evaluated as shell. Paths and timestamps are data only.
  The path argument must be a regular non-symlink file leaf — a symlink is
  refused without following (even when the target would otherwise validate).
EOF
}

die_usage() { echo "validate-loop-state.sh: $*" >&2; usage >&2; exit 2; }
fail() { echo "validate-loop-state.sh: $*" >&2; exit 1; }

FILE=""
MIN_UPDATED=""
# Distinguish "flag absent" from "flag present with empty value". An explicit
# --min-updated '' must fail closed as usage error — never silently mean no bound.
MIN_UPDATED_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --min-updated)
      [[ $# -ge 2 ]] || die_usage "--min-updated requires a UTC timestamp argument"
      MIN_UPDATED="$2"
      MIN_UPDATED_SET=1
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      if [[ -z "$FILE" ]]; then
        FILE="$1"
      else
        die_usage "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "$FILE" ]] || die_usage "missing <file>"
if [[ "$MIN_UPDATED_SET" -eq 1 ]]; then
  if [[ -z "$MIN_UPDATED" ]]; then
    die_usage "--min-updated requires a nonempty UTC timestamp (omit the flag for no bound; empty is never 'no bound')"
  fi
  if ! printf '%s' "$MIN_UPDATED" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    fail "invalid --min-updated (want YYYY-MM-DDTHH:MM:SSZ): $MIN_UPDATED"
  fi
fi

# Refuse symlink leaves before any read. -f follows links and would accept a
# fresh valid target via a replaced loop-state.md symlink; never follow for
# validation (issue #75 independent-review blocker).
if [[ -L "$FILE" ]]; then
  fail "refusing symlink leaf (will not follow for validation): $FILE"
fi
if [[ ! -e "$FILE" ]]; then
  fail "missing file: $FILE"
fi
if [[ ! -f "$FILE" ]]; then
  fail "not a regular file: $FILE"
fi
if [[ ! -r "$FILE" ]]; then
  fail "unreadable file: $FILE"
fi

# python3 is required for strict UTC calendar checks and --min-updated compare.
# Fail closed with a clear diagnostic; never skip the timestamp gate.
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required for strict UTC timestamp validation (issue #75); install python3 or put it on PATH"
fi

# Single-pass validation in awk (Bash 3.2-safe; values never shell-eval'd).
# Prints diagnostic lines to stdout; exit status via END.
# Optional min-updated is validated in python after awk confirms grammar.
export _VLS_FILE="$FILE"
export _VLS_MIN_UPDATED="$MIN_UPDATED"

# shellcheck disable=SC2016
DIAG=$(awk '
  BEGIN {
    req_n = split("updated issue pr hat next_hat round parked handoff handoff_sha next_action", req, " ")
    for (i = 1; i <= req_n; i++) {
      need[req[i]] = 1
      count[req[i]] = 0
      val[req[i]] = ""
    }
    hat_n = split("builder test-engineer reviewer ux-evaluator security release historian decomposer planner", hats, " ")
    for (i = 1; i <= hat_n; i++) hat_ok[hats[i]] = 1
    errors = 0
  }
  # Column-zero keys only: no leading whitespace, not a markdown heading/comment decoy.
  /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
    line = $0
    key = line
    sub(/:.*$/, "", key)
    v = line
    sub(/^[^:]*:/, "", v)
    if (v ~ /^ /) v = substr(v, 2)
    if (key in need) {
      count[key]++
      if (count[key] == 1) val[key] = v
    }
    next
  }
  END {
    for (i = 1; i <= req_n; i++) {
      k = req[i]
      if (count[k] == 0) {
        print "missing required key: " k
        errors++
      } else if (count[k] > 1) {
        print "duplicate key (must appear exactly once): " k " (" count[k] " times)"
        errors++
      }
    }
    if (count["hat"] == 1 && !(val["hat"] in hat_ok)) {
      print "invalid hat (not in enum): " val["hat"]
      errors++
    }
    if (count["next_hat"] == 1 && !(val["next_hat"] in hat_ok)) {
      print "invalid next_hat (not in enum): " val["next_hat"]
      errors++
    }
    if (count["round"] == 1 && val["round"] !~ /^[0-9]+$/) {
      print "invalid round (want non-negative base-10 integer): " val["round"]
      errors++
    }
    if (count["parked"] == 1 && val["parked"] != "true" && val["parked"] != "false") {
      print "invalid parked (want exactly true or false): " val["parked"]
      errors++
    }
    # Emit updated value for the python strict-time check (even if missing — empty).
    if (count["updated"] == 1) {
      print "UPDATED_VALUE\t" val["updated"]
    }
    if (errors > 0) exit 1
    exit 0
  }
' "$FILE") || awk_rc=$?
awk_rc=${awk_rc:-0}

errors=0
updated_value=""
# 1 when awk emitted UPDATED_VALUE (key present exactly once, value may be empty).
got_updated_value=0
while IFS= read -r line || [[ -n "${line:-}" ]]; do
  [[ -n "$line" ]] || continue
  case "$line" in
    UPDATED_VALUE$'\t'*)
      updated_value="${line#*$'\t'}"
      got_updated_value=1
      ;;
    *)
      echo "validate-loop-state.sh: $line" >&2
      errors=$((errors + 1))
      ;;
  esac
done <<< "$DIAG"

# Strict UTC for updated (and optional min-updated comparison).
# python3 argv — never interpolate into source; never shell-eval the timestamp.
strict_utc_check() {
  # $1 = timestamp; prints "ok" or "bad" on stdout; exit 0 always for capture.
  python3 - "$1" <<'PY'
import sys
from datetime import datetime
ts = sys.argv[1]
if not ts:
    print("bad")
    sys.exit(0)
# Grammar: exactly YYYY-MM-DDTHH:MM:SSZ
import re
if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", ts):
    print("bad")
    sys.exit(0)
try:
    datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
except ValueError:
    print("bad")
    sys.exit(0)
print("ok")
PY
}

utc_epoch() {
  python3 - "$1" <<'PY'
import sys
from datetime import datetime, timezone
ts = sys.argv[1]
dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
PY
}

# updated is required to be a real strict UTC timestamp whenever the key is
# present. Empty fails closed even without --min-updated (ten-key schema).
if [[ "$got_updated_value" -eq 1 ]]; then
  case "$(strict_utc_check "$updated_value")" in
    ok) ;;
    *)
      echo "validate-loop-state.sh: invalid updated (want real UTC YYYY-MM-DDTHH:MM:SSZ): $updated_value" >&2
      errors=$((errors + 1))
      updated_value=""
      ;;
  esac
fi

if [[ "$MIN_UPDATED_SET" -eq 1 && -n "$MIN_UPDATED" ]]; then
  case "$(strict_utc_check "$MIN_UPDATED")" in
    ok) ;;
    *)
      echo "validate-loop-state.sh: invalid --min-updated (not a real UTC instant): $MIN_UPDATED" >&2
      errors=$((errors + 1))
      MIN_UPDATED=""
      ;;
  esac
fi

if [[ -n "$updated_value" && -n "$MIN_UPDATED" && "$errors" -eq 0 ]]; then
  u_epoch=$(utc_epoch "$updated_value")
  m_epoch=$(utc_epoch "$MIN_UPDATED")
  if [[ "$u_epoch" -lt "$m_epoch" ]]; then
    echo "validate-loop-state.sh: stale updated: $updated_value is older than min-updated $MIN_UPDATED" >&2
    errors=$((errors + 1))
  fi
fi

# If awk failed only because of schema errors we already printed; if it failed for
# other reasons and we have no diagnostics, surface a generic parse failure.
if [[ "$awk_rc" -ne 0 && "$errors" -eq 0 && -z "$updated_value" ]]; then
  echo "validate-loop-state.sh: failed to parse: $FILE" >&2
  errors=1
fi

if [[ "$errors" -gt 0 ]]; then
  exit 1
fi
exit 0
