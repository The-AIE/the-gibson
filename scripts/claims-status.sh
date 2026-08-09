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
  0  claims printed (or none live — after a successful inventory read)
  1  live PR-body claim inventory unreadable (auth, pagination, malformed
     evidence, or missing reader) — never reported as "no live claims";
     also a failed docs/claims ls-tree or an unreadable claim/table blob
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Normalize a git remote URL to github.com owner/name, or return 1.
# Mirrors release-claim.sh's contract so a checkout whose origin is GitHub
# still requires the PR inventory when `gh` is missing or `gh repo view`
# fails (#153 review round 7) — never report "no live claims" because
# repository discovery failed.
normalize_github_repo_url() {
  local url="$1" rest hostport host path owner name
  [[ -n "$url" ]] || return 1
  case "$url" in
    https://*|http://*)  rest="${url#*://}"; rest="${rest#*@}" ;;
    ssh://*)             rest="${url#ssh://}"; rest="${rest#*@}" ;;
    git://*)             rest="${url#git://}"; rest="${rest#*@}" ;;
    */*:*)               return 1 ;;
    *:*)
      rest="${url#*@}"
      rest="${rest%%:*}/${rest#*:}"
      ;;
    *) return 1 ;;
  esac
  [[ "$rest" == */* ]] || return 1
  hostport="${rest%%/*}"
  path="${rest#*/}"
  host="${hostport%%:*}"
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  case "$host" in
    github.com|www.github.com|ssh.github.com) ;;
    *) return 1 ;;
  esac
  path="${path%/}"
  path="${path%.git}"
  path="${path%/}"
  [[ "$path" == */* ]] || return 1
  owner="${path%%/*}"
  name="${path#*/}"
  [[ "$name" != */* ]] || return 1
  [[ "$owner" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s/%s\n' "$owner" "$name"
}

REPO=""
if command -v gh >/dev/null 2>&1; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  # Fall back when gh is a test shim that only prints owner/name (no --json).
  if [[ -z "$REPO" ]]; then
    REPO=$(gh repo view 2>/dev/null | head -1 | tr -d "[:space:]" || true)
  fi
fi
# When gh is unavailable or cannot name the repository, derive owner/name
# from the canonical checkout's origin if it is a GitHub URL. A GitHub
# origin makes the PR inventory authoritative; discovery failure is not
# "no live claims".
if [[ -z "$REPO" ]] || [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  _origin_url=$(git config --get remote.origin.url 2>/dev/null || true)
  if [[ -n "$_origin_url" ]]; then
    if _from_origin=$(normalize_github_repo_url "$_origin_url"); then
      REPO="$_from_origin"
    fi
  fi
  unset _origin_url _from_origin
fi
if [[ -n "$REPO" && ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  REPO=""
fi

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

emit_pr() { # number | claim-id | scope | head | url | created | updated
  local number="$1" id="$2" scope="$3" head="$4" url="$5" created="$6" updated="$7"
  if [[ -n "$ONLY_ISSUE" ]]; then
    echo "$id" | grep -qE "^issue-([A-Za-z][A-Za-z0-9]*-)?${ONLY_ISSUE}-" || return 0
  fi
  local stamp age="" claimed="$created"
  stamp=$(claim_to_epoch "$claimed")
  if [[ -n "$stamp" ]]; then
    local hours=$(( (NOW - stamp) / 3600 ))
    [[ "$hours" -ge 24 ]] && age=" STALE(${hours}h)"
  fi
  ROWS="${ROWS}| ${claimed} | ${id} | ${scope} | PR #${number} (${head})${age} |"$'\n'
}

# Live PR-body claims are authoritative (#153 review round 6, P2). When we
# can name a repository, the reader must succeed: authentication, pagination,
# malformed evidence, or a missing reader are "I could not find out", never
# "no live claims". Suppressing a failed `pr-claims.sh list` and then printing
# absence is a false green.
if [[ -n "$REPO" ]]; then
  if [[ ! -x "$SCRIPT_DIR/pr-claims.sh" ]]; then
    echo "claims-status.sh: ERROR: the authoritative PR-claim reader $SCRIPT_DIR/pr-claims.sh is missing or not executable — cannot read live claims for $REPO; refuse rather than report 'no live claims' on an unread inventory" >&2
    exit 1
  fi
  # Avoid process substitution (< <(...)) — some sandboxes have no /dev/fd
  # (bash still implements it via /dev/fd/N). Capture then read. Keep stderr
  # on failure so the diagnostic names the real cause.
  _pr_claims_err=""
  if ! _pr_claims_out=$("$SCRIPT_DIR/pr-claims.sh" list "$REPO" 2>&1); then
    _pr_claims_err="$_pr_claims_out"
    echo "claims-status.sh: ERROR: live claim inventory for $REPO is unreadable — ${_pr_claims_err}" >&2
    exit 1
  fi
  # 8 fields since #153 review round 5 — the trailing column is the PR's
  # repository identity. Read it explicitly so it cannot be absorbed into
  # $updated, which drives the age column below. Prefixed `_` because this
  # status view does not surface repository identity (release-claim.sh and
  # claim.sh enforce it before any mutation).
  while IFS=$'\t' read -r number id scope head url created updated _cross; do
    [[ -n "$id" ]] || continue
    emit_pr "$number" "$id" "$scope" "$head" "$url" "$created" "$updated"
  done <<EOF
${_pr_claims_out}
EOF
  unset _pr_claims_out _pr_claims_err
fi

# Per-file claim leaves. Genuine absence of docs/claims/ is empty evidence
# (ls-tree exit 0, empty stdout). An unreadable tree listing or unreadable
# claim blob is a hard failure — never a silent skip that under-reports
# live claims (#153 review round 7).
if ! _claims_ls_out=$(git ls-tree --name-only "$REF" docs/claims/ 2>&1); then
  echo "claims-status.sh: ERROR: cannot list docs/claims/ at $REF — ${_claims_ls_out}" >&2
  exit 1
fi
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "$path" in *.md) ;; *) continue ;; esac
  if ! body=$(git show "$REF:$path" 2>&1); then
    echo "claims-status.sh: ERROR: cannot read claim blob $REF:$path — ${body}" >&2
    exit 1
  fi
  id=$(echo "$body" | sed -n 's/^claim: //p' | head -1)
  [[ -n "$id" ]] || id=$(basename "$path" .md)
  emit "$(echo "$body" | sed -n 's/^claimed: //p' | head -1)" \
       "$id" \
       "$(echo "$body" | sed -n 's/^scope: //p' | head -1)" \
       "$(echo "$body" | sed -n 's/^session: //p' | head -1)"
done <<EOF
${_claims_ls_out}
EOF
unset _claims_ls_out body

# Legacy rows: still authoritative until their lane releases them.
# Genuine absence of the table (no tree entry) is empty; a tree entry whose
# blob is missing/unreadable fails closed — never a silent skip (#153 r7).
_legacy_table=""
_legacy_ls_err=""
if ! _legacy_ls=$(git ls-tree "$REF" -- docs/active-work.md 2>&1); then
  _legacy_ls_err="$_legacy_ls"
  echo "claims-status.sh: ERROR: cannot list legacy claim table at $REF — ${_legacy_ls_err}" >&2
  exit 1
fi
if [[ -n "$_legacy_ls" ]]; then
  # Path is present in the tree — the blob must be readable.
  if ! _legacy_table=$(git show "$REF:docs/active-work.md" 2>&1); then
    echo "claims-status.sh: ERROR: cannot read legacy claim table $REF:docs/active-work.md — ${_legacy_table}" >&2
    exit 1
  fi
fi
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  id=$(echo "$line" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  echo "$id" | grep -qE '^issue-' || continue
  emit "$(echo "$line" | awk -F'|' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
       "$id" \
       "$(echo "$line" | awk -F'|' '{print $4}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
       "$(echo "$line" | awk -F'|' '{print $5}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') (legacy row)"
done <<< "$(printf '%s\n' "$_legacy_table" | grep -E '^\| ' || true)"
unset _legacy_table _legacy_ls _legacy_ls_err

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
