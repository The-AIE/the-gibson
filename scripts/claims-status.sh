#!/usr/bin/env bash
# claims-status.sh — render the live claim table from per-lane claim files (docs/05)
set -uo pipefail

usage() {
  cat <<'EOF'
claims-status.sh — show who holds what, right now

WHAT IT DOES
  Reads docs/claims/*.md (one file per claim) plus any legacy rows still in
  docs/active-work.md, and prints them as one table, newest last. Flags claims
  older than 24h as STALE.

WHY
  Claims stopped being a shared table so that two lanes claiming at the same
  moment stop conflicting on the ledger (L-023) — but the fleet still needs the
  single view the table gave it. This is that view, generated instead of
  hand-maintained, which is the same de-hot move docs/05 asks of any target repo.

USAGE
  claims-status.sh [--ref <git-ref>] [--issue <n>] [--markdown]
  claims-status.sh --help

  --ref       read from a git ref instead of the working tree (default origin/main,
              falling back to the local branch) — the working tree lies when your
              checkout is behind
  --issue     only claims on this issue number, namespaced ones included
  --markdown  emit the docs/active-work.md table format

CLOCK
  GIBSON_CLAIMS_NOW_EPOCH  optional. When set to a decimal Unix epoch (UTC seconds),
                           staleness is computed against this fixed "now" instead of
                           the wall clock. Sensors use this so the exact 24-hour
                           boundary is deterministic. Production leaves it unset.
                           Unset → wall clock. Explicitly empty, non-digit, or out of
                           signed 64-bit range → exit 2 (fail closed; never silently
                           fall back to the wall clock or invent ages). Leading zeros
                           are decimal (0086400 = 86400). Scope is this script only —
                           it is not a general test clock.

DATE-ONLY SEMANTICS
  A claim timestamp that is only a calendar day (YYYY-MM-DD, no time) is treated as
  that day at 00:00:00 UTC. It must not inherit the current wall-clock hour/minute/
  second. On BSD/macOS, bare `date -j -f %Y-%m-%d` fills missing fields from "now",
  which can race the NOW snapshot and report 23 whole hours for a full calendar day.

EXIT
  0  claims printed (or none live)
  2  usage error
EOF
}

REF=""
ONLY_ISSUE=""
MARKDOWN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --ref) REF="${2:-}"; shift ;;
    --issue) ONLY_ISSUE="${2:-}"; shift ;;
    --markdown) MARKDOWN=1 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

command -v git >/dev/null || { echo "claims-status.sh: ERROR: git required" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  { echo "claims-status.sh: ERROR: not a git repo" >&2; exit 2; }

if [[ -z "$REF" ]]; then
  BASE=main
  git show-ref --verify --quiet refs/heads/main || BASE=master
  git fetch origin "$BASE" >/dev/null 2>&1 || true
  REF="origin/$BASE"
  git rev-parse --verify --quiet "$REF" >/dev/null || REF="$BASE"
fi

# Injectable clock for sensors (issue #62). Production: leave unset → wall clock.
# Bash 3.2 portable set-vs-unset: ${var+x} expands to "x" when set (even empty).
# Do not use [[ -n "${var:-}" ]] — that treats set-empty as unset and would
# silently fall back to the wall clock, making the empty validation arm dead.
if [[ ${GIBSON_CLAIMS_NOW_EPOCH+x} ]]; then
  raw="$GIBSON_CLAIMS_NOW_EPOCH"
  case "$raw" in
    ''|*[!0-9]*)
      echo "claims-status.sh: ERROR: GIBSON_CLAIMS_NOW_EPOCH must be decimal Unix epoch seconds" >&2
      exit 2
      ;;
  esac
  # Normalize leading zeros as a string first. Never feed raw 0-prefixed digits
  # to $((...)): bare arithmetic is octal; 10# still accepts huge strings that
  # wrap or invent nonsense ages. Strip to a canonical no-leading-zero decimal,
  # then enforce the signed 64-bit bound before any arithmetic.
  canon="$raw"
  while [[ "$canon" == 0* && ${#canon} -gt 1 ]]; do
    canon="${canon#0}"
  done
  # 2^63-1 = 9223372036854775807 — bash signed integer max on 64-bit hosts.
  # Equal-length digit strings compare lexicographically in the same order as
  # numerically; use string order so the bound is enforced without $((...)).
  max_epoch="9223372036854775807"
  # shellcheck disable=SC2071 # intentional string order for equal-length digit bounds
  if [[ ${#canon} -gt ${#max_epoch} ]] ||
     { [[ ${#canon} -eq ${#max_epoch} ]] && [[ "$canon" > "$max_epoch" ]]; }; then
    echo "claims-status.sh: ERROR: GIBSON_CLAIMS_NOW_EPOCH must be decimal Unix epoch seconds" >&2
    exit 2
  fi
  NOW=$((10#$canon))
else
  NOW=$(date -u +%s)
fi
ROWS=""

# Parse a claim timestamp to Unix epoch (UTC). Date-only YYYY-MM-DD → midnight UTC.
# Never hand a bare date to BSD `date -j -f %Y-%m-%d` — it fills H:M:S from the
# wall clock and can under-count age by one second across a boundary (issue #62).
# Portable: GNU `date -d` first, then BSD `date -j -f` for ISO-Z.
claim_to_epoch() {
  local claimed="$1" normalized
  if [[ "$claimed" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    normalized="${claimed}T00:00:00Z"
  else
    normalized="$claimed"
  fi
  date -u -d "$normalized" +%s 2>/dev/null ||
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$normalized" +%s 2>/dev/null ||
    echo ""
}

emit() { # claimed | claim-id | scope | session
  local claimed="$1" id="$2" scope="$3" session="$4"
  if [[ -n "$ONLY_ISSUE" ]]; then
    echo "$id" | grep -qE "^issue-([A-Za-z][A-Za-z0-9]*-)?${ONLY_ISSUE}-" || return 0
  fi
  local age="" stamp
  # A claim with an unparseable date is still a claim (no STALE marker).
  stamp=$(claim_to_epoch "$claimed")
  if [[ -n "$stamp" ]]; then
    local hours=$(( (NOW - stamp) / 3600 ))
    [[ "$hours" -ge 24 ]] && age=" STALE(${hours}h)"
  fi
  ROWS="${ROWS}| ${claimed} | ${id} | ${scope} | ${session}${age} |"$'\n'
}

for path in $(git ls-tree --name-only "$REF" docs/claims/ 2>/dev/null); do
  case "$path" in *.md) ;; *) continue ;; esac
  body=$(git show "$REF:$path" 2>/dev/null) || continue
  id=$(echo "$body" | sed -n 's/^claim: //p' | head -1)
  [[ -n "$id" ]] || id=$(basename "$path" .md)
  emit "$(echo "$body" | sed -n 's/^claimed: //p' | head -1)" \
       "$id" \
       "$(echo "$body" | sed -n 's/^scope: //p' | head -1)" \
       "$(echo "$body" | sed -n 's/^session: //p' | head -1)"
done

# Legacy rows: still authoritative until their lane releases them.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  id=$(echo "$line" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  echo "$id" | grep -qE '^issue-' || continue
  emit "$(echo "$line" | awk -F'|' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
       "$id" \
       "$(echo "$line" | awk -F'|' '{print $4}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
       "$(echo "$line" | awk -F'|' '{print $5}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') (legacy row)"
done <<< "$(git show "$REF:docs/active-work.md" 2>/dev/null | grep -E '^\| ' || true)"

if [[ -z "$ROWS" ]]; then
  echo "no live claims${ONLY_ISSUE:+ for issue $ONLY_ISSUE} at $REF"
  exit 0
fi

SORTED=$(echo "$ROWS" | sed '/^$/d' | sort)
if [[ "$MARKDOWN" -eq 1 ]]; then
  echo "| claimed (UTC) | claim | scope | session |"
  echo "|---|---|---|---|"
  echo "$SORTED"
else
  echo "live claims at $REF"
  echo
  echo "$SORTED" | sed 's/^| //;s/ |$//;s/ | / · /g;s/^/  /'
fi
