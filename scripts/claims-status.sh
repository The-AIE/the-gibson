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

NOW=$(date -u +%s)
ROWS=""

emit() { # claimed | claim-id | scope | session
  local claimed="$1" id="$2" scope="$3" session="$4"
  if [[ -n "$ONLY_ISSUE" ]]; then
    echo "$id" | grep -qE "^issue-([A-Za-z][A-Za-z0-9]*-)?${ONLY_ISSUE}-" || return 0
  fi
  local age="" stamp
  # date -d is GNU, -j -f is BSD; a claim with an unparseable date is still a claim.
  stamp=$(date -u -d "$claimed" +%s 2>/dev/null ||
          date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$claimed" +%s 2>/dev/null || echo "")
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
