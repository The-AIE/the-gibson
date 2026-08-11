#!/usr/bin/env bash
# claim-reaper.sh — expire dead lanes' claims from evidence (issue #73 / docs/05)
#
# Standalone Tier B janitor. Dry-run by default. Never closes an issue.
# Automatic scheduling and Mission Control integration are follow-ups.
set -euo pipefail

usage() {
  cat <<'EOF'
claim-reaper.sh — expire dead lanes' claims from evidence

WHAT IT DOES
  Reads the live remote claim ledger (never the caller's working tree), derives
  liveness from evidence (claim timestamp, local branch tip, exact live remote
  feature-branch tip, registered worktree tracked-file mtime, optional
  heartbeat file), and plans release of claims stale beyond a threshold
  (default 14400 seconds / 4 hours). Feature-branch activity is always resolved
  with a live remote query (never a stale origin/<feature> cache).

  Dry-run by default: prints a reviewable plan with zero mutations. --apply
  releases exactly one claim id at a time via release-claim.sh, journals each
  operation, and only after release-claim returns success and authoritative
  postconditions prove the claim absent posts a deduplicated handoff comment.
  Feature branch and worktree are preserved by default. --prune-worktrees may
  remove only the exact registered target worktree after CAS + verified cleanup
  push succeed.

  An open PR always protects a claim. API/ref failures, malformed evidence,
  unreadable worktrees, unregistered or unsafe paths, symlink/device evidence,
  future-clock evidence, or race-time activity fail closed (refuse reaping).
  When GitHub-native claims apply, a failed or successful-but-malformed
  pr-claims.sh list is a hard refusal — never an empty plan. The entire
  inventory is validated all-or-none against the shipped list contract before
  any planning or mutation; genuine empty success remains valid. The reaper
  never closes the target issue.

WHY
  Doctrine assumes dead lanes eventually free the issue, but nothing enforces
  it: a crashed lane leaves claim row + agent-claimed + worktree forever, and
  the fleet honors the claim. Conservative reaping from evidence is the janitor.

RISKS
  - Releases a claim row on main (via release-claim). Undo: re-claim the issue.
  - Optional worktree removal with --prune-worktrees (uncommitted work lost).
  - Posts an issue comment only after verified release. Deduplicated; no
    absolute worktree paths. Never claims release on CAS/renewal/incomplete.
  - Does NOT close issues. Does NOT delete branches by default.

USAGE
  claim-reaper.sh [--apply] [--stale-seconds N] [--prune-worktrees]
                  [--claim-id <id>] [--repo owner/name]
                  [--heartbeat-dir DIR] [--max-claims N]
  claim-reaper.sh --help

  --apply            perform releases (default is dry-run)
  --stale-seconds N  age threshold in seconds (default: 14400)
  --prune-worktrees  allow release-claim to remove the exact registered
                     target worktree (default: keep worktree)
  --claim-id ID      only consider this exact claim id
  --repo owner/name  product repo for PR queries and issue comments
  --heartbeat-dir D  directory of per-claim heartbeat files (name = claim id
                     or claim-id.heartbeat). Optional liveness evidence.
  --max-claims N     stop after planning/applying N reapable claims (default: all)

ENV
  GIBSON_CANONICAL           claim-table repo path (default: cwd)
  GIBSON_CLAIMS_NOW_EPOCH    fixed "now" as decimal Unix epoch (sensors)
  GIBSON_REAPER_STATE_DIR    journal + lock directory (default: <canonical>/gibson)
  GIBSON_REAPER_JOURNAL      journal file path override
  GIBSON_REAPER_LOCK_DIR     single-instance lock directory (apply mode)
  GIBSON_REAPER_RELEASE_CMD  override path to release-claim.sh (tests)

EXIT
  0  dry-run plan printed, or apply completed with no incomplete reaps
  1  hard precondition failed (ledger/lock/usage of hostile inputs)
  2  usage error
  3  apply ran but one or more reaps were incomplete/refused at mutation time

SECURITY
  Treat ledger, paths, timestamps, branch names, heartbeat contents, journal
  and comment strings as hostile. No eval of untrusted data. Fail closed when
  liveness cannot be proven. Never publish absolute local worktree paths.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

APPLY=0
STALE_SECONDS=14400
PRUNE_WORKTREES=0
CLAIM_ID_FILTER=""
CLAIM_ID_FILTER_SET=0
REPO_ARG=""
HEARTBEAT_DIR=""
MAX_CLAIMS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --stale-seconds)
      STALE_SECONDS="${2:-}"
      shift
      ;;
    --prune-worktrees) PRUNE_WORKTREES=1 ;;
    --claim-id)
      CLAIM_ID_FILTER_SET=1
      CLAIM_ID_FILTER="${2:-}"
      shift
      ;;
    --repo)
      REPO_ARG="${2:-}"
      shift
      ;;
    --heartbeat-dir)
      HEARTBEAT_DIR="${2:-}"
      shift
      ;;
    --max-claims)
      MAX_CLAIMS="${2:-}"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "claim-reaper.sh: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

die() { echo "claim-reaper.sh: ERROR: $*" >&2; exit 1; }
usage_die() { echo "claim-reaper.sh: ERROR: $*" >&2; exit 2; }
info() { echo "claim-reaper.sh: $*"; }
warn() { echo "claim-reaper.sh: WARNING: $*" >&2; }

# Safe non-negative decimal integer parse. Lexical + bounded string compare
# against signed 64-bit max BEFORE any Bash arithmetic. Never wrap/normalize
# overflow into a smaller value. Prints canonical decimal on success.
# Max safe: 9223372036854775807 (2^63-1).
MAX_SAFE_INT="9223372036854775807"
parse_nonneg_int() {
  local raw="$1" canon
  case "$raw" in
    ''|*[!0-9]*) return 1 ;;
  esac
  canon="$raw"
  while [[ "$canon" == 0* && ${#canon} -gt 1 ]]; do
    canon="${canon#0}"
  done
  # shellcheck disable=SC2071
  if [[ ${#canon} -gt ${#MAX_SAFE_INT} ]] ||
     { [[ ${#canon} -eq ${#MAX_SAFE_INT} ]] && [[ "$canon" > "$MAX_SAFE_INT" ]]; }; then
    return 1
  fi
  printf '%s\n' "$canon"
  return 0
}

# Safe numeric greater-than for two already-parsed non-negative decimals.
int_gt() {
  local a="$1" b="$2"
  # Prefer string compare by length then lexical (both digit-only, no leading zeros except 0).
  if [[ ${#a} -gt ${#b} ]]; then return 0; fi
  if [[ ${#a} -lt ${#b} ]]; then return 1; fi
  [[ "$a" > "$b" ]]
}

# --- arg validation (fail closed on hostile/malformed) --------------------
_stale_parsed=""
if ! _stale_parsed=$(parse_nonneg_int "$STALE_SECONDS"); then
  usage_die "--stale-seconds must be a non-negative decimal integer in safe range (0..${MAX_SAFE_INT}); got '$STALE_SECONDS'"
fi
STALE_SECONDS="$_stale_parsed"

if [[ "$CLAIM_ID_FILTER_SET" -eq 1 ]]; then
  [[ -n "$CLAIM_ID_FILTER" ]] || die "--claim-id requires a non-empty literal claim id"
  if [[ ! "$CLAIM_ID_FILTER" =~ ^issue-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    die "--claim-id must be a literal exact claim id (no wildcards/regex); got '$CLAIM_ID_FILTER'"
  fi
fi

if [[ -n "$REPO_ARG" && ! "$REPO_ARG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  die "--repo must look like owner/name; got '$REPO_ARG'"
fi

if [[ -n "$MAX_CLAIMS" ]]; then
  _mc=""
  if ! _mc=$(parse_nonneg_int "$MAX_CLAIMS"); then
    usage_die "--max-claims must be a positive decimal integer in safe range; got '$MAX_CLAIMS'"
  fi
  MAX_CLAIMS="$_mc"
  # Safe: already bounded; arithmetic only after parse_nonneg_int.
  if [[ "$MAX_CLAIMS" -lt 1 ]]; then
    usage_die "--max-claims must be >= 1"
  fi
fi

if [[ -n "$HEARTBEAT_DIR" ]]; then
  case "$HEARTBEAT_DIR" in
    /*) ;;
    *) die "--heartbeat-dir must be an absolute path" ;;
  esac
  case "$HEARTBEAT_DIR" in
    *..*) die "--heartbeat-dir must not contain '..'" ;;
  esac
fi

CANONICAL="${GIBSON_CANONICAL:-$(pwd)}"
[[ -d "$CANONICAL" ]] || die "canonical path is not a directory: $CANONICAL"
cd "$CANONICAL" || die "cannot cd to $CANONICAL"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $CANONICAL"

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
RELEASE_CMD="${GIBSON_REAPER_RELEASE_CMD:-$SCRIPT_DIR/release-claim.sh}"
[[ -x "$RELEASE_CMD" || -f "$RELEASE_CMD" ]] || die "release-claim not found: $RELEASE_CMD"

STATE_DIR="${GIBSON_REAPER_STATE_DIR:-$CANONICAL/gibson}"
JOURNAL="${GIBSON_REAPER_JOURNAL:-$STATE_DIR/claim-reaper-journal.md}"
LOCK_DIR="${GIBSON_REAPER_LOCK_DIR:-$STATE_DIR/claim-reaper.lock}"

# Injectable clock (same contract as claims-status #62).
if [[ ${GIBSON_CLAIMS_NOW_EPOCH+x} ]]; then
  raw="$GIBSON_CLAIMS_NOW_EPOCH"
  canon=""
  if ! canon=$(parse_nonneg_int "$raw"); then
    die "GIBSON_CLAIMS_NOW_EPOCH must be decimal Unix epoch seconds in safe range"
  fi
  NOW=$((10#$canon))
else
  NOW=$(date -u +%s)
fi

# GitHub-native claims are authoritative for migrated repositories. Keep the
# legacy ledger scan below intact, but reap stale open-PR claims from the same
# source that claims-status and claim.sh use.
#
# Resolve PR repository identity: explicit --repo, then gh, then a GitHub
# origin URL. When GitHub-native claims are applicable, a failed/malformed
# pr-claims.sh list is a hard refusal — never an empty plan or "nothing to
# reap" (#153 review round 7). A successful empty inventory may continue to
# the legacy ledger.
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

PR_REPO="${REPO_ARG:-}"
if [[ -z "$PR_REPO" ]]; then
  PR_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
fi
if [[ -z "$PR_REPO" || ! "$PR_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  _origin_url=$(git config --get remote.origin.url 2>/dev/null || true)
  if [[ -n "$_origin_url" ]]; then
    if _from_origin=$(normalize_github_repo_url "$_origin_url"); then
      PR_REPO="$_from_origin"
    else
      PR_REPO=""
    fi
  else
    PR_REPO=""
  fi
  unset _origin_url _from_origin
fi
if [[ -n "$PR_REPO" && ! "$PR_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  PR_REPO=""
fi

PR_CLAIMS_FOUND=0
if [[ -n "$PR_REPO" ]]; then
  if [[ ! -x "$SCRIPT_DIR/pr-claims.sh" ]]; then
    die "the authoritative PR-claim reader $SCRIPT_DIR/pr-claims.sh is missing or not executable — cannot inventory live claims for $PR_REPO; refuse rather than plan 'nothing to reap' on an unread inventory"
  fi
  # Keep stderr so a failed/malformed inventory names the real cause. Never
  # `|| true` this into an empty plan (#153 review round 7).
  _pr_list_err=""
  if ! PR_ROWS=$("$SCRIPT_DIR/pr-claims.sh" list "$PR_REPO" 2>&1); then
    _pr_list_err="$PR_ROWS"
    die "live claim inventory for $PR_REPO is unreadable — ${_pr_list_err}"
  fi
  unset _pr_list_err
  # Successful exit is not enough: a reader that exits 0 while printing
  # malformed text must never become "nothing to reap" (#153 review round 8).
  # Validate the entire inventory all-or-none against the shipped
  # pr-claims.sh list contract (same shape claim.sh / release-claim.sh /
  # scope-overlap.mjs defend) before any planning or mutation. Genuine empty
  # success (no non-empty rows) remains valid.
  _pr_bad_row=""
  while IFS= read -r _pr_row; do
    [[ -n "$_pr_row" ]] || continue
    _pr_fields=$(awk -F'\t' '{print NF}' <<<"$_pr_row")
    _pr_number=$(cut -f1 <<<"$_pr_row")
    _pr_id=$(cut -f2 <<<"$_pr_row")
    _pr_scope=$(cut -f3 <<<"$_pr_row")
    _pr_head=$(cut -f4 <<<"$_pr_row")
    _pr_url=$(cut -f5 <<<"$_pr_row")
    _pr_created=$(cut -f6 <<<"$_pr_row")
    _pr_updated=$(cut -f7 <<<"$_pr_row")
    _pr_cross=$(cut -f8 <<<"$_pr_row")
    if [[ "$_pr_fields" -ne 8 ]]; then
      _pr_bad_row="want 8 tab-separated fields, got ${_pr_fields}: ${_pr_row}"
      break
    fi
    # GitHub pull-request numbers are positive canonical decimals: first digit
    # 1-9, then zero or more digits. Reject zero and leading-zero forms such as
    # 0999 before any classification, planning, journaling, or release
    # (#153 review-ten P1). Do not normalize malformed input into a valid identity.
    if [[ ! "$_pr_number" =~ ^[1-9][0-9]*$ ]]; then
      _pr_bad_row="PR number is noncanonical/unsafe (want positive decimal without leading zeros): ${_pr_row}"
      break
    fi
    # Issue-bound claim id: issue-[optional-ns-]<digits>-<slug>, same family
    # pr-claims.sh / claim-reaper already require for live claims.
    if [[ ! "$_pr_id" =~ ^issue-([A-Za-z][A-Za-z0-9]*-)?[0-9]+-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
      _pr_bad_row="claim id is not a valid issue-bound id: ${_pr_row}"
      break
    fi
    if [[ -z "$_pr_scope" ]]; then
      _pr_bad_row="empty claim scope: ${_pr_row}"
      break
    fi
    if [[ -z "$_pr_head" || ! "$_pr_head" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      _pr_bad_row="missing/unsafe head branch: ${_pr_row}"
      break
    fi
    # URL /pull/N must independently be the same positive canonical decimal —
    # not merely digit-only. Zero and leading-zero URL components fail here
    # even if a future change loosened the row check (#153 review-ten P1).
    if [[ -z "$_pr_url" || ! "$_pr_url" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)$ ]]; then
      _pr_bad_row="missing/malformed PR URL (pull number is noncanonical/unsafe; want positive decimal without leading zeros): ${_pr_row}"
      break
    fi
    # Conjunctive identity binding (#153 review-nine P1): a plausible PR URL
    # shape is not enough. The URL's owner/repo must equal PR_REPO and its
    # /pull/N must equal the row number before the row may be classified or
    # released. Do not case-fold or rewrite URL components — GitHub identity
    # comparison is exact string equality on the captured path segments
    # (same rule pr-claims.sh / scope-overlap.mjs already enforce).
    _pr_url_repo="${BASH_REMATCH[1]}"
    _pr_url_num="${BASH_REMATCH[2]}"
    if [[ "$_pr_url_repo" != "$PR_REPO" ]]; then
      _pr_bad_row="PR URL repository ('${_pr_url_repo}') does not match inventory repository ('${PR_REPO}'): ${_pr_row}"
      break
    fi
    if [[ "$_pr_url_num" != "$_pr_number" ]]; then
      _pr_bad_row="PR URL pull-number ('${_pr_url_num}') does not match row PR number ('${_pr_number}'): ${_pr_row}"
      break
    fi
    if [[ -z "$_pr_created" || -z "$_pr_updated" ]]; then
      _pr_bad_row="missing created/updated timestamp: ${_pr_row}"
      break
    fi
    if [[ "$_pr_cross" != "true" && "$_pr_cross" != "false" ]]; then
      _pr_bad_row="repository-identity column is neither 'true' nor 'false' ('${_pr_cross:-<empty>}'): ${_pr_row}"
      break
    fi
  done <<EOF
$PR_ROWS
EOF
  if [[ -n "$_pr_bad_row" ]]; then
    die "live claim inventory for $PR_REPO returned a malformed/truncated row — refuse rather than treat unreadable evidence as an empty plan: ${_pr_bad_row}"
  fi
  unset _pr_bad_row _pr_row _pr_fields _pr_number _pr_id _pr_scope _pr_head _pr_url _pr_url_repo _pr_url_num _pr_created _pr_updated _pr_cross
  # shellcheck disable=SC2034
  # 8 fields since #153 review round 5: the last is the PR's repository
  # identity (`true`/`false`). It is read so the timestamp column is not
  # silently absorbed into it; this reaper only proposes a release, and
  # release-claim.sh re-reads and enforces identity itself before any mutation.
  # Inventory shape was already proven all-or-none above; this loop only
  # plans/acts. cut avoids IFS tab collapsing (belt after the validator).
  while IFS= read -r _pr_line; do
    [[ -n "$_pr_line" ]] || continue
    pr_number=$(cut -f1 <<<"$_pr_line")
    pr_id=$(cut -f2 <<<"$_pr_line")
    pr_scope=$(cut -f3 <<<"$_pr_line")
    pr_head=$(cut -f4 <<<"$_pr_line")
    pr_url=$(cut -f5 <<<"$_pr_line")
    pr_created=$(cut -f6 <<<"$_pr_line")
    pr_updated=$(cut -f7 <<<"$_pr_line")
    pr_cross=$(cut -f8 <<<"$_pr_line")
    [[ -n "$pr_id" ]] || continue
    PR_CLAIMS_FOUND=1
    if [[ "$CLAIM_ID_FILTER_SET" -eq 1 && "$pr_id" != "$CLAIM_ID_FILTER" ]]; then
      continue
    fi
    if [[ ! "$pr_id" =~ ^issue-([0-9]+)- ]]; then
      warn "refusing malformed PR claim id '$pr_id' on PR #$pr_number"
      continue
    fi
    pr_issue="${BASH_REMATCH[1]}"
    stamp="$pr_updated"
    [[ -n "$stamp" ]] || stamp="$pr_created"
    epoch=$(date -u -d "$stamp" +%s 2>/dev/null ||
      date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$stamp" +%s 2>/dev/null || echo "")
    if [[ -z "$epoch" || ! "$epoch" =~ ^[0-9]+$ ]]; then
      warn "refusing PR #$pr_number claim '$pr_id' with unreadable activity timestamp"
      continue
    fi
    age=$((NOW - epoch))
    if [[ "$age" -lt "$STALE_SECONDS" ]]; then
      info "PR #$pr_number claim $pr_id is protected (activity ${age}s ago)"
      continue
    fi
    info "STALE PR #$pr_number claim $pr_id (activity ${age}s ago)"
    if [[ "$APPLY" -eq 1 ]]; then
      "$RELEASE_CMD" "$pr_issue" --claim-id "$pr_id" --repo "$PR_REPO" \
        --keep-branch --keep-worktree
    fi
  done <<EOF
$PR_ROWS
EOF
  unset _pr_line pr_number pr_id pr_scope pr_head pr_url pr_created pr_updated pr_cross
  # A migrated repository can have no legacy tree at all. Do not misclassify
  # that valid state as an unreadable ledger after processing PR claims.
  if [[ "$PR_CLAIMS_FOUND" -eq 1 ]]; then
    legacy_entries=$(git ls-tree --name-only HEAD docs/claims/ docs/active-work.md 2>/dev/null || true)
    if [[ -z "$legacy_entries" ]]; then
      exit 0
    fi
  fi
fi

# --- ledger ref: require successful fetch of exact remote base ------------
# Never fall back to local main/master, cached stale origin refs after a
# failed fetch, HEAD, or another branch.
fetch_remote_ledger_ref() {
  local base ref
  for base in main master; do
    if git fetch origin "$base" >/dev/null 2>&1; then
      ref="origin/${base}"
      if git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
        printf '%s\n' "$ref"
        return 0
      fi
    fi
  done
  return 1
}

REF=""
if ! REF=$(fetch_remote_ledger_ref); then
  die "cannot fetch exact remote ledger base (origin main/master) — refuse (no local/cached fallback)"
fi

if ! git rev-parse --verify --quiet "${REF}^{commit}" >/dev/null 2>&1; then
  die "ledger ref $REF does not resolve to a commit object"
fi
TREE_SHA=$(git rev-parse --verify "${REF}^{tree}" 2>/dev/null || true)
if [[ -z "$TREE_SHA" ]]; then
  TREE_SHA=$(git cat-file -p "${REF}^{commit}" 2>/dev/null | awk '/^tree / {print $2; exit}')
fi
[[ -n "$TREE_SHA" ]] || die "ledger commit at $REF has no tree pointer"
if ! git cat-file -e "$TREE_SHA" 2>/dev/null; then
  die "ledger commit at $REF references unreadable/corrupt tree ($TREE_SHA)"
fi
if ! git ls-tree "$TREE_SHA" >/dev/null 2>&1; then
  die "cannot list tree for ledger commit $REF"
fi

require_readable_regular_blob() {
  local path="$1" mode="$2" typ="$3" obj="$4"
  if [[ "$typ" != "blob" ]] || [[ "$mode" != "100644" && "$mode" != "100755" ]]; then
    die "$path at $REF has unexpected Git mode/type ($mode $typ${obj:+ $obj})"
  fi
  if [[ -z "$obj" ]]; then
    die "$path at $REF has no object id"
  fi
  if ! git cat-file -e "$obj" 2>/dev/null; then
    die "$path exists at $REF but blob is unreadable/corrupt ($obj)"
  fi
  local got_type
  got_type=$(git cat-file -t "$obj" 2>/dev/null || true)
  if [[ "$got_type" != "blob" ]]; then
    die "$path at $REF object $obj has unexpected type '${got_type:-unreadable}'"
  fi
  if ! git cat-file blob "$obj" >/dev/null 2>&1; then
    die "$path at $REF blob payload unreadable ($obj)"
  fi
}

HAS_ACTIVE=0
HAS_CLAIMS_TREE=0

ACTIVE_LS_ERR=""
ACTIVE_LINE=$(git ls-tree "$REF" -- docs/active-work.md 2>&1) || ACTIVE_LS_ERR=$?
if [[ -n "$ACTIVE_LS_ERR" ]]; then
  die "cannot list docs/active-work.md at $REF"
fi
if [[ -n "$ACTIVE_LINE" ]]; then
  active_mode=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $1; exit}')
  active_type=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $2; exit}')
  active_blob=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $3; exit}')
  require_readable_regular_blob "docs/active-work.md" "$active_mode" "$active_type" "$active_blob"
  HAS_ACTIVE=1
fi

CLAIMS_SELF_ERR=""
CLAIMS_SELF=$(git ls-tree "$REF" -- docs/claims 2>&1) || CLAIMS_SELF_ERR=$?
if [[ -n "$CLAIMS_SELF_ERR" ]]; then
  die "cannot list docs/claims at $REF"
fi
if [[ -n "$CLAIMS_SELF" ]]; then
  claims_self_mode=$(printf '%s\n' "$CLAIMS_SELF" | awk '{print $1; exit}')
  claims_self_type=$(printf '%s\n' "$CLAIMS_SELF" | awk '{print $2; exit}')
  claims_self_obj=$(printf '%s\n' "$CLAIMS_SELF" | awk '{print $3; exit}')
  if [[ "$claims_self_type" != "tree" ]] || [[ "$claims_self_mode" != "040000" ]]; then
    die "docs/claims at $REF has unexpected Git mode/type ($claims_self_mode $claims_self_type)"
  fi
  if [[ -z "$claims_self_obj" ]] || ! git cat-file -e "$claims_self_obj" 2>/dev/null; then
    die "docs/claims tree at $REF is unreadable/corrupt"
  fi
  CLAIMS_LS_ERR=""
  CLAIMS_LINES=$(git ls-tree "$REF" docs/claims/ 2>&1) || CLAIMS_LS_ERR=$?
  if [[ -n "$CLAIMS_LS_ERR" ]]; then
    die "cannot read docs/claims/ at $REF"
  fi
  if [[ -n "$CLAIMS_LINES" ]]; then
    HAS_CLAIMS_TREE=1
    while IFS= read -r claim_line; do
      [[ -n "$claim_line" ]] || continue
      claim_mode=$(printf '%s\n' "$claim_line" | awk '{print $1; exit}')
      claim_type=$(printf '%s\n' "$claim_line" | awk '{print $2; exit}')
      claim_obj=$(printf '%s\n' "$claim_line" | awk '{print $3; exit}')
      claim_path="${claim_line#*$'\t'}"
      [[ -n "$claim_path" ]] || claim_path="docs/claims/<unknown>"
      require_readable_regular_blob "$claim_path" "$claim_mode" "$claim_type" "$claim_obj"
    done <<EOF
$CLAIMS_LINES
EOF
  fi
fi

if [[ "$HAS_ACTIVE" -eq 0 && "$HAS_CLAIMS_TREE" -eq 0 ]]; then
  info "claim ledger at $REF is empty — nothing to reap"
  if [[ "$APPLY" -eq 0 ]]; then
    echo "DRY RUN plan: (empty ledger — zero mutations)"
  fi
  exit 0
fi

# --- helpers --------------------------------------------------------------

# Parse claim timestamp → Unix epoch. Date-only → midnight UTC. Empty on fail.
claim_to_epoch() {
  local claimed="$1" normalized
  if [[ "$claimed" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    normalized="${claimed}T00:00:00Z"
  else
    normalized="$claimed"
  fi
  # Accept only strict ISO-Z forms (no free-form date -d injection surface).
  if [[ ! "$normalized" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo ""
    return 0
  fi
  date -u -d "$normalized" +%s 2>/dev/null ||
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$normalized" +%s 2>/dev/null ||
    echo ""
}

# Safe field extract: first line matching ^key: value (literal key).
field_from_body() {
  local body="$1" key="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "${key}: "*)
        printf '%s\n' "${line#*: }"
        return 0
        ;;
    esac
  done <<EOF
$body
EOF
  echo ""
}

# Validate claim id shape (same contract as release-claim).
valid_claim_id() {
  [[ "$1" =~ ^issue-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

# Derive issue number from claim id. Empty on failure.
issue_from_claim_id() {
  local id="$1"
  if [[ "$id" =~ ^issue-([0-9]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$id" =~ ^issue-[A-Za-z][A-Za-z0-9]*-([0-9]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  echo ""
}

branch_for() { echo "feat/${1#issue-}"; }

# Default worktree path next to canonical (never published to GitHub).
default_wt_for() {
  local parent
  parent=$(cd "$CANONICAL/.." && pwd) || return 1
  echo "$parent/wt-${1#issue-}"
}

# File mtime as epoch. Empty on failure. Regular files only.
file_mtime_epoch() {
  local f="$1" mt
  [[ -e "$f" ]] || { echo ""; return 0; }
  if [[ -L "$f" ]]; then
    echo "SYMLINK"
    return 0
  fi
  if [[ -b "$f" || -c "$f" || -p "$f" || -S "$f" ]]; then
    echo "DEVICE"
    return 0
  fi
  if [[ ! -f "$f" ]]; then
    echo ""
    return 0
  fi
  # GNU first: `stat -f %m` on Linux is --file-system (mount point / garbage),
  # not mtime. L-050 / #99.
  mt=$(stat -c %Y -- "$f" 2>/dev/null || stat -f %m -- "$f" 2>/dev/null) || mt=""
  case "$mt" in
    ''|*[!0-9]*) echo "" ;;
    *) echo "$mt" ;;
  esac
}

# Max of already-safe non-negative decimal args; empty if none.
# Uses length+lexical compare — never Bash arithmetic on untrusted magnitudes.
max_epoch() {
  local m="" x
  for x in "$@"; do
    [[ -n "$x" ]] || continue
    case "$x" in *[!0-9]*) continue ;; esac
    # Reject overflow candidates that slipped past callers
    if ! parse_nonneg_int "$x" >/dev/null; then
      continue
    fi
    if [[ -z "$m" ]] || int_gt "$x" "$m"; then
      m="$x"
    fi
  done
  printf '%s' "$m"
}

# Product repo for gh.
resolve_repo() {
  if [[ -n "$REPO_ARG" ]]; then
    printf '%s\n' "$REPO_ARG"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo ""
    return 1
  fi
  local r
  r=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  if [[ -n "$r" && "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf '%s\n' "$r"
    return 0
  fi
  echo ""
  return 1
}

# Open-PR query. Prints "open", "none", or "fail".
open_pr_status() {
  local branch="$1" repo="$2"
  if ! command -v gh >/dev/null 2>&1; then
    echo "fail"
    return 0
  fi
  # head filter: owner:branch. Branch names treated as data (no eval).
  local owner head_q out rc
  owner="${repo%%/*}"
  head_q="${owner}:${branch}"
  set +e
  out=$(gh pr list --repo "$repo" --head "$head_q" --state open --json number --jq 'length' 2>/dev/null)
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "fail"
    return 0
  fi
  case "$out" in
    ''|*[!0-9]*) echo "fail" ;;
    0) echo "none" ;;
    *) echo "open" ;;
  esac
}

# Physical path for comparison (macOS /var vs /private/var). Does not require
# the final component to be non-symlink for normalization of parents; callers
# that must refuse symlink worktrees check -L separately.
phys_path() {
  local p="$1" dir base
  p="${p%/}"
  [[ -n "$p" ]] || { echo ""; return 0; }
  if [[ -d "$p" && ! -L "$p" ]]; then
    (CDPATH='' cd "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"
    return 0
  fi
  dir=$(dirname -- "$p" 2>/dev/null || echo ".")
  base=$(basename -- "$p" 2>/dev/null || echo "$p")
  if [[ -d "$dir" ]]; then
    printf '%s/%s\n' "$(CDPATH='' cd "$dir" 2>/dev/null && pwd -P)" "$base"
  else
    printf '%s\n' "$p"
  fi
}

# Is path a registered git worktree of CANONICAL? (porcelain list; physical match)
worktree_registered() {
  local want="$1" line cur="" want_phys cur_phys
  want="${want%/}"
  want_phys=$(phys_path "$want")
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        cur="${line#worktree }"
        cur="${cur%/}"
        if [[ "$cur" == "$want" ]]; then
          return 0
        fi
        cur_phys=$(phys_path "$cur")
        if [[ -n "$want_phys" && -n "$cur_phys" && "$cur_phys" == "$want_phys" ]]; then
          return 0
        fi
        ;;
    esac
  done <<EOF
$(git worktree list --porcelain 2>/dev/null || true)
EOF
  return 1
}

# Collect max tracked-file mtime in a registered worktree.
# Prints epoch, or FAIL:<reason> on fail-closed conditions.
worktree_tracked_mtime() {
  local wt="$1"
  local max_mt="" f full mt

  if [[ -L "$wt" ]]; then
    echo "FAIL:worktree_is_symlink"
    return 0
  fi
  if [[ ! -d "$wt" ]]; then
    echo "FAIL:worktree_not_directory"
    return 0
  fi
  if ! worktree_registered "$wt"; then
    echo "FAIL:worktree_unregistered"
    return 0
  fi

  # git ls-files -z (NUL-separated) so paths with spaces stay intact.
  # Process substitution keeps the loop in this shell (Bash 3.2 portable).
  if ! git -C "$wt" ls-files -z >/dev/null 2>&1; then
    echo "FAIL:worktree_ls_files"
    return 0
  fi

  while IFS= read -r -d '' f || [[ -n "$f" ]]; do
    [[ -n "$f" ]] || continue
    case "$f" in
      /*|*\.\./*|*\.\.) echo "FAIL:tracked_path_unsafe"; return 0 ;;
    esac
    full="$wt/$f"
    if [[ -L "$full" ]]; then
      echo "FAIL:tracked_symlink"
      return 0
    fi
    if [[ -b "$full" || -c "$full" || -p "$full" || -S "$full" ]]; then
      echo "FAIL:tracked_device"
      return 0
    fi
    [[ -e "$full" ]] || continue
    if [[ -f "$full" ]]; then
      mt=$(file_mtime_epoch "$full")
      case "$mt" in
        SYMLINK) echo "FAIL:tracked_symlink"; return 0 ;;
        DEVICE) echo "FAIL:tracked_device"; return 0 ;;
        '') continue ;;
        *)
          if [[ -z "$max_mt" ]] || [[ "$mt" -gt "$max_mt" ]]; then
            max_mt="$mt"
          fi
          ;;
      esac
    fi
  done < <(git -C "$wt" ls-files -z 2>/dev/null)

  printf '%s\n' "$max_mt"
}

# Branch tip committer epoch for a local ref name. Empty if missing. FAIL: on error.
# Never use this for origin/<feature> liveness — use live_remote_branch_evidence.
branch_tip_epoch() {
  local ref="$1" ts
  if ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
    echo ""
    return 0
  fi
  ts=$(git log -1 --format=%ct "$ref" 2>/dev/null || true)
  case "$ts" in
    ''|*[!0-9]*) echo "FAIL:branch_tip_unreadable" ;;
    *) echo "$ts" ;;
  esac
}

# Safe feature-branch name for live remote queries (no shell/Git metachar injection).
# Rejects empty, path tricks, @{, leading dash, double-dot, trailing .lock, etc.
valid_feature_branch_name() {
  local b="$1"
  [[ -n "$b" ]] || return 1
  # Same surface as plan-time branch check, plus reject leading '.' and '-' and '@'.
  [[ "$b" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
  case "$b" in
    *..*|*@\{*|*//*|*/./*|*/.|.*) return 1 ;;
  esac
  case "$b" in
    *.lock) return 1 ;;
  esac
  return 0
}

# Exact live remote feature-branch evidence — never trust cached origin/<branch>.
# Validates branch syntax, then ls-remote + fetch of the exact heads ref.
# stdout (single line):
#   OK:<sha>:<epoch>   — live remote tip proven; tracking ref updated to that SHA
#   ABSENT             — successful query proved the remote branch does not exist
#                        (stale refs/remotes/origin/<branch> is deleted when possible)
#   FAIL:<reason>      — query/auth/network/malformed/multiple-result/fetch failure
live_remote_branch_evidence() {
  local branch="$1" ls_out ls_rc n sha got ts fetch_ok=0
  if ! valid_feature_branch_name "$branch"; then
    echo "FAIL:malformed_branch"
    return 0
  fi

  set +e
  ls_out=$(git ls-remote --heads origin "refs/heads/${branch}" 2>/dev/null)
  ls_rc=$?
  set -e
  if [[ "$ls_rc" -ne 0 ]]; then
    echo "FAIL:remote_query_failed"
    return 0
  fi

  n=$(printf '%s\n' "$ls_out" | awk 'NF { c++ } END { print c+0 }')
  if [[ "$n" -eq 0 ]]; then
    # Proven absent: drop stale cached remote-tracking evidence so it cannot KEEP.
    git update-ref -d "refs/remotes/origin/${branch}" >/dev/null 2>&1 || true
    echo "ABSENT"
    return 0
  fi
  if [[ "$n" -ne 1 ]]; then
    echo "FAIL:remote_multiple_results"
    return 0
  fi

  sha=$(printf '%s\n' "$ls_out" | awk 'NF { print $1; exit }')
  if [[ ! "$sha" =~ ^[0-9a-f]{40,64}$ ]]; then
    echo "FAIL:remote_sha_malformed"
    return 0
  fi

  # Fetch the exact live heads ref into the remote-tracking ref (force update).
  set +e
  git fetch -q origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" >/dev/null 2>&1
  fetch_ok=$?
  set -e
  if [[ "$fetch_ok" -ne 0 ]]; then
    # Retry as object fetch of the live SHA only.
    set +e
    git fetch -q origin "$sha" >/dev/null 2>&1
    fetch_ok=$?
    set -e
    if [[ "$fetch_ok" -ne 0 ]]; then
      echo "FAIL:remote_fetch_failed"
      return 0
    fi
    if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
      echo "FAIL:remote_fetch_failed"
      return 0
    fi
    git update-ref "refs/remotes/origin/${branch}" "$sha" >/dev/null 2>&1 || true
  fi

  got=$(git rev-parse --verify --quiet "refs/remotes/origin/${branch}^{commit}" 2>/dev/null || true)
  if [[ -z "$got" ]]; then
    # Tracking ref may be missing; accept the live SHA object if present.
    got=$(git rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null || true)
  fi
  if [[ -z "$got" ]]; then
    echo "FAIL:remote_fetch_failed"
    return 0
  fi
  if [[ "$got" != "$sha" ]]; then
    # Exact fetch proved a different tip than ls-remote reported (stale query,
    # mid-flight advance, or race). Fail closed — never reset the tracking ref
    # back to the earlier queried SHA and never treat that SHA as live evidence.
    echo "FAIL:remote_branch_changed"
    return 0
  fi

  ts=$(git log -1 --format=%ct "$sha" 2>/dev/null || true)
  case "$ts" in
    ''|*[!0-9]*)
      echo "FAIL:branch_tip_unreadable"
      return 0
      ;;
  esac
  if ! parse_nonneg_int "$ts" >/dev/null; then
    echo "FAIL:branch_tip_unreadable"
    return 0
  fi
  echo "OK:${sha}:${ts}"
}

# Parse one heartbeat file → epoch or FAIL:reason.
# Nonempty malformed content is FAIL (never mtime fallback). Empty content may
# use regular-file mtime. Symlink/device/non-file always FAIL.
heartbeat_file_epoch() {
  local f="$1" first content_epoch mt
  if [[ -L "$f" ]]; then
    echo "FAIL:heartbeat_symlink"
    return 0
  fi
  if [[ -b "$f" || -c "$f" || -p "$f" || -S "$f" ]]; then
    echo "FAIL:heartbeat_device"
    return 0
  fi
  if [[ ! -f "$f" ]]; then
    echo "FAIL:heartbeat_not_file"
    return 0
  fi
  first=$(head -n 1 "$f" 2>/dev/null || true)
  first=$(printf '%s' "$first" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ -n "$first" ]]; then
    # Nonempty content is authoritative — refuse if unparseable/overflow.
    case "$first" in
      *[!0-9]*)
        content_epoch=$(claim_to_epoch "$first")
        if [[ -z "$content_epoch" ]]; then
          echo "FAIL:heartbeat_malformed"
          return 0
        fi
        if ! content_epoch=$(parse_nonneg_int "$content_epoch"); then
          echo "FAIL:heartbeat_malformed"
          return 0
        fi
        ;;
      *)
        if ! content_epoch=$(parse_nonneg_int "$first"); then
          echo "FAIL:heartbeat_malformed"
          return 0
        fi
        ;;
    esac
    printf '%s\n' "$content_epoch"
    return 0
  fi
  # Empty content: mtime only (regular file already proven).
  mt=$(file_mtime_epoch "$f")
  case "$mt" in
    SYMLINK) echo "FAIL:heartbeat_symlink"; return 0 ;;
    DEVICE) echo "FAIL:heartbeat_device"; return 0 ;;
    '') echo "FAIL:heartbeat_unreadable"; return 0 ;;
    *)
      if ! mt=$(parse_nonneg_int "$mt"); then
        echo "FAIL:heartbeat_malformed"
        return 0
      fi
      printf '%s\n' "$mt"
      ;;
  esac
}

# Heartbeat evidence for a claim id. Inspects EVERY supported name:
#   <dir>/<id>  and  <dir>/<id>.heartbeat
# Any present unsafe/malformed/symlink/device evidence refuses the claim.
# Otherwise returns the maximum valid timestamp among present files.
# Prints epoch, FAIL:reason, or empty (no heartbeat files).
heartbeat_epoch() {
  local id="$1"
  [[ -n "$HEARTBEAT_DIR" ]] || { echo ""; return 0; }
  local f1="$HEARTBEAT_DIR/$id" f2="$HEARTBEAT_DIR/${id}.heartbeat"
  local f ep max="" any=0
  for f in "$f1" "$f2"; do
    if [[ -e "$f" || -L "$f" ]]; then
      any=1
      ep=$(heartbeat_file_epoch "$f")
      case "$ep" in
        FAIL:*)
          printf '%s\n' "$ep"
          return 0
          ;;
        '')
          echo "FAIL:heartbeat_unreadable"
          return 0
          ;;
        *)
          if [[ -z "$max" ]] || int_gt "$ep" "$max"; then
            max="$ep"
          fi
          ;;
      esac
    fi
  done
  if [[ "$any" -eq 0 ]]; then
    echo ""
    return 0
  fi
  printf '%s\n' "$max"
}

# Comment dedupe marker (inert HTML comment; no path secrets).
comment_marker() {
  local id="$1"
  printf '<!-- gibson-claim-reaper:%s -->' "$id"
}

# True if issue already has a handoff comment with our marker.
comment_already_posted() {
  local issue="$1" repo="$2" id="$3" marker body
  marker=$(comment_marker "$id")
  if ! command -v gh >/dev/null 2>&1; then
    return 1
  fi
  body=$(gh api "repos/${repo}/issues/${issue}/comments" --paginate -q '.[].body' 2>/dev/null || true)
  # Fail closed if we cannot query: treat as "unknown" by returning 2 via caller.
  # Here: empty body from API failure vs no comments — use a side channel.
  printf '%s' "$body" | grep -qF -- "$marker"
}

# Post handoff comment. Never include absolute worktree paths.
# Callers MUST invoke this only after release-claim success (or authoritative
# claim absence on retry) — never before mutation, never on CAS/renewal failure.
# Returns 0 when the inert marker is already present (dedupe) or freshly posted.
post_handoff_comment() {
  local issue="$1" repo="$2" id="$3" branch="$4" last_active="$5"
  local marker body
  marker=$(comment_marker "$id")
  # Sanitize fields for comment body (hostile claim data).
  case "$last_active" in
    ''|*[!0-9]*) last_active="unknown" ;;
  esac
  body=$(cat <<EOF
Lane presumed dead (no liveness evidence within the reaper threshold).

- claim: \`${id}\`
- last-active (UTC epoch): ${last_active}
- work preserved on branch: \`${branch}\`
- claim row released by claim-reaper; feature branch and worktree kept by default

${marker}
EOF
)
  # If already present, skip (dedupe). Marker only exists after a verified success
  # under the Law 8 ordering contract — incomplete attempts never post.
  set +e
  local existing
  existing=$(gh api "repos/${repo}/issues/${issue}/comments" --paginate -q '.[].body' 2>/dev/null)
  local api_rc=$?
  set -e
  if [[ $api_rc -ne 0 ]]; then
    warn "could not list comments on $repo#$issue — refusing comment post (fail closed)"
    return 1
  fi
  if printf '%s' "$existing" | grep -qF -- "$marker"; then
    info "handoff comment already present for $id — skipping post"
    return 0
  fi
  if ! gh issue comment "$issue" --repo "$repo" --body "$body" >/dev/null 2>&1; then
    warn "failed to post handoff comment on $repo#$issue"
    return 1
  fi
  info "posted handoff comment on $repo#$issue for $id"
  return 0
}

# Ensure the success handoff marker is present for a claim that is already
# authoritatively absent (idempotent retry after cleanup-without-comment).
# Returns 0 on success/already-present; 1 on failure (caller journals incomplete).
ensure_absent_handoff_comment() {
  local issue="$1" repo="$2" id="$3" branch="$4" last_active="${5:-unknown}"
  if [[ -z "$repo" || -z "$issue" || -z "$id" ]]; then
    warn "cannot post handoff for $id — repo/issue unresolved"
    return 1
  fi
  post_handoff_comment "$issue" "$repo" "$id" "${branch:-$(branch_for "$id")}" "$last_active"
}

# Journal helpers — path-safe, never write through a symlink.
# The journal target and its immediate parent must not themselves be symlinks
# (system path components like /var → /private/var on macOS are fine).
# Uses same-directory temp + replace so append cannot write through a symlink
# target: mv replaces a symlink inode, leaving any victim file unchanged.
ensure_journal() {
  local jparent tmp
  jparent=$(dirname -- "$JOURNAL")
  mkdir -p "$jparent" 2>/dev/null || die "cannot create journal parent: $jparent"
  if [[ -L "$jparent" ]]; then
    die "journal parent is a symlink — refuse write-through: $jparent"
  fi
  if [[ -e "$JOURNAL" ]]; then
    if [[ -L "$JOURNAL" ]]; then
      die "journal target is a symlink — refuse write-through: $JOURNAL"
    fi
    if [[ ! -f "$JOURNAL" ]]; then
      die "journal target exists but is not a regular file: $JOURNAL"
    fi
    return 0
  fi
  # Create new regular file: write temp in parent then mv into place.
  # If JOURNAL is already a symlink, refuse before any write that would
  # follow it (never use > "$JOURNAL" which writes through).
  if [[ -L "$JOURNAL" ]]; then
    die "journal target is a symlink — refuse create write-through: $JOURNAL"
  fi
  tmp=$(mktemp "${jparent}/.claim-reaper-journal.XXXXXX") || die "cannot create journal temp"
  printf '# claim-reaper journal\n\n' > "$tmp"
  if [[ -L "$JOURNAL" ]]; then
    rm -f "$tmp"
    die "journal became a symlink during create — refuse"
  fi
  # mv replaces a symlink node at JOURNAL (if raced) without writing the victim.
  mv -f "$tmp" "$JOURNAL" || { rm -f "$tmp"; die "cannot create journal at $JOURNAL"; }
  if [[ -L "$JOURNAL" || ! -f "$JOURNAL" ]]; then
    die "journal path not a regular file after create: $JOURNAL"
  fi
}

journal_append() {
  local line="$1" jparent tmp
  # Single-line records only; strip newlines from hostile inputs.
  line=$(printf '%s' "$line" | tr '\n\r' '  ')
  jparent=$(dirname -- "$JOURNAL")
  if [[ -L "$jparent" ]]; then
    die "journal parent is a symlink — refuse append: $jparent"
  fi
  if [[ -L "$JOURNAL" ]]; then
    die "journal is a symlink — refuse append (no write-through)"
  fi
  ensure_journal
  if [[ -L "$JOURNAL" ]]; then
    die "journal is a symlink — refuse append (no write-through)"
  fi
  if [[ ! -f "$JOURNAL" ]]; then
    die "journal is not a regular file — refuse append"
  fi
  tmp=$(mktemp "${jparent}/.claim-reaper-journal.XXXXXX") || die "cannot create journal temp"
  # Copy existing regular file only (cat would follow symlink — already refused -L).
  cat "$JOURNAL" > "$tmp" || { rm -f "$tmp"; die "cannot read journal for append"; }
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo ts)" "$line" >> "$tmp"
  if [[ -L "$JOURNAL" ]]; then
    rm -f "$tmp"
    die "journal became a symlink during append — refuse"
  fi
  # Replace journal path: if a symlink appeared, mv replaces the symlink node
  # (victim file at old symlink target is unchanged). Prefer refusing if still
  # a symlink before replace so we never claim a successful journal write
  # that only swapped a symlink for a new file silently.
  if [[ -L "$JOURNAL" ]]; then
    rm -f "$tmp"
    die "journal is a symlink — refuse append"
  fi
  mv -f "$tmp" "$JOURNAL" || { rm -f "$tmp"; die "cannot write journal"; }
  if [[ -L "$JOURNAL" || ! -f "$JOURNAL" ]]; then
    die "journal path not a regular file after append: $JOURNAL"
  fi
}

# True if COMPLETED record exists for op id.
journal_has_completed() {
  local op="$1"
  [[ -f "$JOURNAL" && ! -L "$JOURNAL" ]] || return 1
  grep -qF -- " COMPLETED op=${op} " "$JOURNAL" 2>/dev/null || \
    grep -qE -- " COMPLETED op=${op}( |$)" "$JOURNAL" 2>/dev/null
}

# True if the journal proves a prior successful reaper cleanup for this exact
# claim id whose official handoff comment failed (Law 8 recovery only).
# Requires claim_released=1 + handoff_comment_failed on an op scoped to this id
# (op=reap:<id>:...). Mere absence without that proof is not success evidence.
journal_has_claim_released_handoff_failed() {
  local id="$1" line
  [[ -n "$id" ]] || return 1
  [[ -f "$JOURNAL" && ! -L "$JOURNAL" ]] || return 1
  # Fixed prefix after op=reap: so issue-1 never matches issue-10.
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      *" INCOMPLETE op=reap:${id}:"*)
        if printf '%s' "$line" | grep -qF 'reason=handoff_comment_failed' \
          && printf '%s' "$line" | grep -qE '(^|[[:space:]])claim_released=1([[:space:]]|$)'; then
          return 0
        fi
        ;;
    esac
  done < "$JOURNAL"
  return 1
}

# Single-instance lock (mkdir atomic; macOS Bash 3.2).
LOCK_HELD=0
acquire_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    LOCK_HELD=1
    return 0
  fi
  # Stale reclaim: dead pid only.
  local opid
  opid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [[ -n "$opid" && "$opid" =~ ^[0-9]+$ ]] && ! kill -0 "$opid" 2>/dev/null; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
      LOCK_HELD=1
      return 0
    fi
  fi
  return 1
}

release_lock() {
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
}
trap release_lock EXIT

# --- enumerate live claims (dedupe legacy + per-file) ----------------------
# Record format (tab-separated, one per logical claim id after dedupe):
# id \t issue \t claimed_raw \t branch \t worktree \t blob_oid \t source \t path \t identity_status
# identity_status: ok | refuse:<reason>
# path is the actual ledger path (docs/claims/<id>.md or docs/active-work.md).

CLAIMS_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-reaper-claims.XXXXXX")
PLAN_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-reaper-plan.XXXXXX")
IDENTITY_REFUSE_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-reaper-idref.XXXXXX")
trap 'release_lock; rm -f "$CLAIMS_TMP" "$PLAN_TMP" "$IDENTITY_REFUSE_TMP"' EXIT

# Collect raw rows into CLAIMS_TMP then dedupe by id (prefer per-file over legacy).
: > "$CLAIMS_TMP"
: > "$IDENTITY_REFUSE_TMP"
# Track seen body claim ids for duplicate detection (file form).
SEEN_IDS_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-reaper-seen.XXXXXX")
: > "$SEEN_IDS_TMP"
trap 'release_lock; rm -f "$CLAIMS_TMP" "$PLAN_TMP" "$IDENTITY_REFUSE_TMP" "$SEEN_IDS_TMP"' EXIT

# Per-file claims — retain actual path; require path == docs/claims/<body-claim-id>.md
if [[ "$HAS_CLAIMS_TREE" -eq 1 ]]; then
  while IFS= read -r claim_line; do
    [[ -n "$claim_line" ]] || continue
    claim_mode=$(printf '%s\n' "$claim_line" | awk '{print $1; exit}')
    claim_type=$(printf '%s\n' "$claim_line" | awk '{print $2; exit}')
    claim_obj=$(printf '%s\n' "$claim_line" | awk '{print $3; exit}')
    claim_path="${claim_line#*$'\t'}"
    case "$claim_path" in
      docs/claims/*.md) ;;
      *)
        printf 'REFUSE\t%s\t\t\t\t\tmalformed_claim_path\t%s\t\t\n' \
          "${claim_path:-unknown}" "$claim_path" >> "$IDENTITY_REFUSE_TMP"
        continue
        ;;
    esac
    if [[ "$claim_type" != "blob" ]] || [[ "$claim_mode" != "100644" && "$claim_mode" != "100755" ]]; then
      printf 'REFUSE\t%s\t\t\t\t\twrong_object_mode\t%s\t\t\n' \
        "$(basename "$claim_path" .md)" "$claim_path" >> "$IDENTITY_REFUSE_TMP"
      continue
    fi
    body=$(git cat-file blob "$claim_obj" 2>/dev/null) || die "cannot read $claim_path blob $claim_obj"
    body_id=$(field_from_body "$body" "claim")
    fname_id=$(basename "$claim_path" .md)
    if [[ -z "$body_id" ]]; then
      printf 'REFUSE\t%s\t\t\t\t\tmissing_body_claim_id\t%s\t\t\n' \
        "$fname_id" "$claim_path" >> "$IDENTITY_REFUSE_TMP"
      continue
    fi
    # Duplicate logical body claim IDs (any path aliasing the same body id)
    # refuse the new path and drop any earlier accepted row for that id.
    if grep -qxF -- "$body_id" "$SEEN_IDS_TMP" 2>/dev/null; then
      printf 'REFUSE\t%s\t\t\t\t\tduplicate_claim_id\t%s\t\t\n' \
        "$body_id" "$claim_path" >> "$IDENTITY_REFUSE_TMP"
      awk -F'\t' -v id="$body_id" 'BEGIN{OFS="\t"} $1==id {next} {print}' "$CLAIMS_TMP" > "${CLAIMS_TMP}.x" \
        && mv "${CLAIMS_TMP}.x" "$CLAIMS_TMP"
      printf 'REFUSE\t%s\t\t\t\t\tduplicate_claim_id\t%s\t\t\n' \
        "$body_id" "docs/claims/${body_id}.md" >> "$IDENTITY_REFUSE_TMP"
      continue
    fi
    printf '%s\n' "$body_id" >> "$SEEN_IDS_TMP"
    if [[ "$body_id" != "$fname_id" ]]; then
      # Filename/body mismatch: refuse; do NOT treat as already-absent under body id.
      printf 'REFUSE\t%s\t\t\t\t\tfilename_body_mismatch\t%s\t\t\n' \
        "$body_id" "$claim_path" >> "$IDENTITY_REFUSE_TMP"
      continue
    fi
    if [[ "$claim_path" != "docs/claims/${body_id}.md" ]]; then
      printf 'REFUSE\t%s\t\t\t\t\tpath_not_canonical\t%s\t\t\n' \
        "$body_id" "$claim_path" >> "$IDENTITY_REFUSE_TMP"
      continue
    fi
    if ! valid_claim_id "$body_id"; then
      printf 'REFUSE\t%s\t\t\t\t\tmalformed_claim_id\t%s\t\t\n' \
        "$body_id" "$claim_path" >> "$IDENTITY_REFUSE_TMP"
      continue
    fi

    claimed=$(field_from_body "$body" "claimed")
    issue=$(field_from_body "$body" "issue")
    branch=$(field_from_body "$body" "branch")
    worktree=$(field_from_body "$body" "worktree")
    derived_issue=$(issue_from_claim_id "$body_id")
    # issue: field, derived-from-id, and canonical claim id must agree.
    if [[ -z "$issue" ]]; then
      issue="$derived_issue"
    fi
    if [[ -z "$issue" || ! "$issue" =~ ^[0-9]+$ ]]; then
      printf 'REFUSE\t%s\t%s\t\t\t\tmalformed_issue\t%s\t\t\n' \
        "$body_id" "${issue:-}" "$claim_path" >> "$IDENTITY_REFUSE_TMP"
      continue
    fi
    if [[ -n "$derived_issue" && "$issue" != "$derived_issue" ]]; then
      printf 'REFUSE\t%s\t%s\t\t\t\tissue_id_mismatch\t%s\t\t\n' \
        "$body_id" "$issue" "$claim_path" >> "$IDENTITY_REFUSE_TMP"
      continue
    fi
    [[ -n "$branch" ]] || branch=$(branch_for "$body_id")
    # id issue claimed branch worktree blob source path status
    printf '%s\t%s\t%s\t%s\t%s\t%s\tfile\t%s\tok\n' \
      "$body_id" "$issue" "$claimed" "$branch" "$worktree" "$claim_obj" "$claim_path" >> "$CLAIMS_TMP"
  done <<EOF
$(git ls-tree "$REF" docs/claims/ 2>/dev/null || true)
EOF
fi

# Drop any rows marked __DROP__ from duplicate handling
if [[ -s "$CLAIMS_TMP" ]]; then
  grep -v '^__DROP__$' "$CLAIMS_TMP" > "${CLAIMS_TMP}.y" || true
  mv "${CLAIMS_TMP}.y" "$CLAIMS_TMP"
fi

# Legacy rows (column 3 = claim-id only)
if [[ "$HAS_ACTIVE" -eq 1 ]]; then
  active_body=$(git show "$REF:docs/active-work.md" 2>/dev/null) || die "cannot read docs/active-work.md"
  active_blob=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $3; exit}')
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^\| ]] || continue
    cid=$(printf '%s\n' "$line" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$cid" ]] || continue
    [[ "$cid" == "claim-id" || "$cid" == "---" ]] && continue
    [[ "$cid" =~ ^-+$ ]] && continue
    echo "$cid" | grep -qE '^issue-' || continue
    if ! valid_claim_id "$cid"; then
      printf 'REFUSE\t%s\t\t\t\t\tmalformed_claim_id\tdocs/active-work.md\t\t\n' \
        "$cid" >> "$IDENTITY_REFUSE_TMP"
      continue
    fi
    claimed=$(printf '%s\n' "$line" | awk -F'|' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    issue=$(issue_from_claim_id "$cid")
    if [[ -z "$issue" || ! "$issue" =~ ^[0-9]+$ ]]; then
      printf 'REFUSE\t%s\t%s\t\t\t\tmalformed_issue\tdocs/active-work.md\t\t\n' \
        "$cid" "${issue:-}" >> "$IDENTITY_REFUSE_TMP"
      continue
    fi
    branch=$(branch_for "$cid")
    worktree=""
    # blob oid for legacy: active-work blob + claim id (CAS key)
    printf '%s\t%s\t%s\t%s\t%s\t%s\tlegacy\t%s\tok\n' \
      "$cid" "$issue" "$claimed" "$branch" "$worktree" "${active_blob}:$cid" "docs/active-work.md" >> "$CLAIMS_TMP"
  done <<EOF
$active_body
EOF
fi

# Dedupe: for each id keep file over legacy, else first.
DEDUP_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-reaper-dedup.XXXXXX")
trap 'release_lock; rm -f "$CLAIMS_TMP" "$PLAN_TMP" "$IDENTITY_REFUSE_TMP" "$SEEN_IDS_TMP" "$DEDUP_TMP"' EXIT
: > "$DEDUP_TMP"
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  src=$(printf '%s\n' "$row" | awk -F'\t' '{print $7}')
  [[ "$src" == "file" ]] || continue
  printf '%s\n' "$row" >> "$DEDUP_TMP"
done < "$CLAIMS_TMP"
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  src=$(printf '%s\n' "$row" | awk -F'\t' '{print $7}')
  [[ "$src" == "legacy" ]] || continue
  id="${row%%$'\t'*}"
  if awk -F'\t' -v id="$id" '$1==id {found=1} END{exit !found}' "$DEDUP_TMP" 2>/dev/null; then
    continue
  fi
  printf '%s\n' "$row" >> "$DEDUP_TMP"
done < "$CLAIMS_TMP"
mv "$DEDUP_TMP" "$CLAIMS_TMP"
DEDUP_TMP=""

# Optional filter
if [[ "$CLAIM_ID_FILTER_SET" -eq 1 ]]; then
  FILTERED=$(mktemp "${TMPDIR:-/tmp}/gibson-reaper-filt.XXXXXX")
  awk -F'\t' -v id="$CLAIM_ID_FILTER" '$1==id' "$CLAIMS_TMP" > "$FILTERED"
  # Also keep identity refuses for this id so dry-run shows REFUSE not silent skip
  awk -F'\t' -v id="$CLAIM_ID_FILTER" '$2==id' "$IDENTITY_REFUSE_TMP" > "${FILTERED}.ref" || true
  mv "$FILTERED" "$CLAIMS_TMP"
  if [[ ! -s "$CLAIMS_TMP" && ! -s "${FILTERED}.ref" ]]; then
    # Apply against an already-released id is a successful no-op (idempotent).
    # Acquire lock BEFORE any journal write (including already-absent).
    if [[ "$APPLY" -eq 1 ]]; then
      if ! acquire_lock; then
        die "another claim-reaper apply holds the lock at $LOCK_DIR (concurrent applies serialize)"
      fi
      # Re-fetch and re-prove absence on authoritative remote before journaling.
      if ! REF=$(fetch_remote_ledger_ref); then
        die "cannot re-fetch remote ledger to prove absence of '$CLAIM_ID_FILTER'"
      fi
      if git cat-file -e "$REF:docs/claims/${CLAIM_ID_FILTER}.md" 2>/dev/null; then
        die "claim '$CLAIM_ID_FILTER' reappeared during absence check — refuse already_absent"
      fi
      # Also refuse if a legacy active-work row for this id is still live.
      if git show "${REF}:docs/active-work.md" 2>/dev/null | awk -F'|' -v want="$CLAIM_ID_FILTER" '
        /^\|/ {
          cid=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",cid);
          if (cid==want) found=1
        }
        END { exit !found }'; then
        die "claim '$CLAIM_ID_FILTER' still live as legacy row — refuse already_absent"
      fi
      info "no live claim '$CLAIM_ID_FILTER' at $REF — nothing to reap (idempotent)"
      ensure_journal
      # Absence alone is a no-op. Only when the journal proves this exact claim
      # was released by a prior reaper op whose official handoff comment failed
      # (claim_released=1 + handoff_comment_failed) may we retry the success
      # handoff. Never post a presumed-dead/released comment without that proof.
      if journal_has_claim_released_handoff_failed "$CLAIM_ID_FILTER"; then
        _abs_repo=$(resolve_repo 2>/dev/null || true)
        _abs_issue=$(issue_from_claim_id "$CLAIM_ID_FILTER")
        _abs_branch=$(branch_for "$CLAIM_ID_FILTER")
        if ! ensure_absent_handoff_comment "$_abs_issue" "$_abs_repo" "$CLAIM_ID_FILTER" "$_abs_branch" "unknown"; then
          journal_append "INCOMPLETE op=reap:${CLAIM_ID_FILTER}:absent reason=handoff_comment_failed claim_absent=1"
          warn "claim absent but handoff comment incomplete for $CLAIM_ID_FILTER — exit incomplete (retry can post once)"
          exit 3
        fi
        journal_append "COMPLETED op=reap:${CLAIM_ID_FILTER}:absent result=already_absent recovery_handoff=1"
        exit 0
      fi
      journal_append "COMPLETED op=reap:${CLAIM_ID_FILTER}:absent result=already_absent"
      exit 0
    fi
    die "no live claim '$CLAIM_ID_FILTER' at $REF"
  fi
  # Merge identity refuses for filtered id into plan later via IDENTITY_REFUSE_TMP
  if [[ -s "${FILTERED}.ref" ]]; then
    cat "${FILTERED}.ref" > "$IDENTITY_REFUSE_TMP"
  else
    : > "$IDENTITY_REFUSE_TMP"
  fi
  rm -f "${FILTERED}.ref"
fi

info "ledger ref: $REF; scanning claims (stale>${STALE_SECONDS}s)"

# --- evaluate each claim --------------------------------------------------
: > "$PLAN_TMP"
# plan columns:
# action\tid\tissue\tbranch\tlast_active\tage\treason\tblob\twt\tclaimed_raw\tsource\tpath\tremote_sha
# remote_sha is the frozen live remote tip SHA (empty when proven ABSENT or unused).

REPO=$(resolve_repo 2>/dev/null || true)

# Emit one plan row. Uses caller's id/issue/branch/blob/claimed_raw/source/path/remote_sha.
# Args: action reason last_active age worktree_path
plan_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$id" "$issue" "$branch" "${3:-}" "${4:-}" "$2" "$blob" "${5:-}" "$claimed_raw" \
    "${source:-}" "${claim_path:-}" "${remote_sha:-}"
}

# Identity refuses (filename/body mismatch, issue mismatch, duplicates, …)
while IFS= read -r irow || [[ -n "$irow" ]]; do
  [[ -n "$irow" ]] || continue
  # REFUSE \t id \t issue \t ... \t reason \t path
  id=$(printf '%s\n' "$irow" | awk -F'\t' '{print $2}')
  issue=$(printf '%s\n' "$irow" | awk -F'\t' '{print $3}')
  reason=$(printf '%s\n' "$irow" | awk -F'\t' '{print $7}')
  claim_path=$(printf '%s\n' "$irow" | awk -F'\t' '{print $8}')
  branch=""
  blob=""
  claimed_raw=""
  source=""
  plan_row REFUSE "${reason:-identity_refuse}" "" "" "" >> "$PLAN_TMP"
done < "$IDENTITY_REFUSE_TMP"

while IFS= read -r row || [[ -n "$row" ]]; do
  [[ -n "$row" ]] || continue
  # Parse TSV safely
  id=$(printf '%s\n' "$row" | awk -F'\t' '{print $1}')
  issue=$(printf '%s\n' "$row" | awk -F'\t' '{print $2}')
  claimed_raw=$(printf '%s\n' "$row" | awk -F'\t' '{print $3}')
  branch=$(printf '%s\n' "$row" | awk -F'\t' '{print $4}')
  worktree=$(printf '%s\n' "$row" | awk -F'\t' '{print $5}')
  blob=$(printf '%s\n' "$row" | awk -F'\t' '{print $6}')
  source=$(printf '%s\n' "$row" | awk -F'\t' '{print $7}')
  claim_path=$(printf '%s\n' "$row" | awk -F'\t' '{print $8}')

  last_active=""
  age=""

  if ! valid_claim_id "$id"; then
    plan_row REFUSE malformed_claim_id "" "" "$worktree" >> "$PLAN_TMP"
    continue
  fi
  if [[ -z "$issue" || ! "$issue" =~ ^[0-9]+$ ]]; then
    plan_row REFUSE malformed_issue "" "" "$worktree" >> "$PLAN_TMP"
    continue
  fi
  # Bind issue field / derived id / positional agreement again at plan time.
  _derived=$(issue_from_claim_id "$id")
  if [[ -n "$_derived" && "$issue" != "$_derived" ]]; then
    plan_row REFUSE issue_id_mismatch "" "" "$worktree" >> "$PLAN_TMP"
    continue
  fi
  if [[ "$source" == "file" ]]; then
    if [[ "$claim_path" != "docs/claims/${id}.md" ]]; then
      plan_row REFUSE path_not_canonical "" "" "$worktree" >> "$PLAN_TMP"
      continue
    fi
  fi

  # Claim timestamp is required evidence base.
  claim_epoch=$(claim_to_epoch "$claimed_raw")
  if [[ -z "$claim_epoch" ]]; then
    plan_row REFUSE malformed_timestamp "" "" "$worktree" >> "$PLAN_TMP"
    continue
  fi
  if ! claim_epoch=$(parse_nonneg_int "$claim_epoch"); then
    plan_row REFUSE malformed_timestamp "" "" "$worktree" >> "$PLAN_TMP"
    continue
  fi

  # Branch name safety: only allow simple feat/… forms (no shell metachar).
  if [[ -n "$branch" && ! "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    plan_row REFUSE malformed_branch "" "" "$worktree" >> "$PLAN_TMP"
    continue
  fi

  # Collect evidence epochs
  evidence_fail=""
  local_tip=""
  remote_tip=""
  remote_sha=""
  remote_ev=""
  wt_mt=""
  hb_ep=""

  if [[ -n "$branch" ]]; then
    # Validate branch syntax before any Git command that interpolates it.
    if ! valid_feature_branch_name "$branch"; then
      evidence_fail="malformed_branch"
    else
      local_tip=$(branch_tip_epoch "$branch")
      case "$local_tip" in
        FAIL:*) evidence_fail="${local_tip#FAIL:}"; local_tip="" ;;
        '') ;;
        *)
          if ! local_tip=$(parse_nonneg_int "$local_tip"); then
            evidence_fail="branch_tip_unreadable"
            local_tip=""
          fi
          ;;
      esac
    fi
    # Live remote feature-branch only — never cached origin/<branch>.
    if [[ -z "$evidence_fail" ]]; then
      remote_ev=$(live_remote_branch_evidence "$branch")
      case "$remote_ev" in
        FAIL:*)
          evidence_fail="${remote_ev#FAIL:}"
          remote_tip=""
          remote_sha=""
          ;;
        ABSENT)
          # Proven absent: ignore any prior stale cache (already deleted).
          remote_tip=""
          remote_sha=""
          ;;
        OK:*)
          remote_sha="${remote_ev#OK:}"
          remote_tip="${remote_sha#*:}"
          remote_sha="${remote_sha%%:*}"
          if [[ ! "$remote_sha" =~ ^[0-9a-f]{40,64}$ ]]; then
            evidence_fail="remote_sha_malformed"
            remote_tip=""
            remote_sha=""
          elif ! remote_tip=$(parse_nonneg_int "$remote_tip"); then
            evidence_fail="branch_tip_unreadable"
            remote_tip=""
            remote_sha=""
          fi
          ;;
        *)
          evidence_fail="remote_query_failed"
          remote_tip=""
          remote_sha=""
          ;;
      esac
    fi
  fi

  # Worktree: if listed in claim, must be absolute and safe; if absent, try default
  # only when that path is a registered worktree (evidence only — prune never
  # derives a different path). Unregistered listed path → refuse.
  wt_path="$worktree"
  if [[ -z "$wt_path" ]]; then
    wt_path=$(default_wt_for "$id" 2>/dev/null || true)
    if [[ -n "$wt_path" ]] && worktree_registered "$wt_path"; then
      :
    else
      wt_path=""
    fi
  else
    case "$wt_path" in
      /*) ;;
      *) evidence_fail="worktree_not_absolute"; wt_path="" ;;
    esac
    case "$wt_path" in
      *..*) evidence_fail="worktree_path_traversal"; wt_path="" ;;
    esac
  fi

  if [[ -z "$evidence_fail" && -n "$wt_path" ]]; then
    if [[ -n "$worktree" ]]; then
      if [[ -L "$wt_path" ]]; then
        evidence_fail="worktree_is_symlink"
      elif [[ ! -d "$wt_path" ]]; then
        evidence_fail="worktree_missing_or_unreadable"
      elif ! worktree_registered "$wt_path"; then
        evidence_fail="worktree_unregistered"
      else
        wt_mt=$(worktree_tracked_mtime "$wt_path")
        case "$wt_mt" in
          FAIL:*) evidence_fail="${wt_mt#FAIL:}"; wt_mt="" ;;
          '') ;;
          *)
            if ! wt_mt=$(parse_nonneg_int "$wt_mt"); then
              evidence_fail="worktree_mtime_unreadable"
              wt_mt=""
            fi
            ;;
        esac
      fi
    else
      wt_mt=$(worktree_tracked_mtime "$wt_path")
      case "$wt_mt" in
        FAIL:*) evidence_fail="${wt_mt#FAIL:}"; wt_mt="" ;;
        '') ;;
        *)
          if ! wt_mt=$(parse_nonneg_int "$wt_mt"); then
            evidence_fail="worktree_mtime_unreadable"
            wt_mt=""
          fi
          ;;
      esac
    fi
  fi

  if [[ -z "$evidence_fail" ]]; then
    hb_ep=$(heartbeat_epoch "$id")
    case "$hb_ep" in
      FAIL:*) evidence_fail="${hb_ep#FAIL:}"; hb_ep="" ;;
    esac
  fi

  if [[ -n "$evidence_fail" ]]; then
    plan_row REFUSE "$evidence_fail" "" "" "${wt_path:-$worktree}" >> "$PLAN_TMP"
    continue
  fi

  last_active=$(max_epoch "$claim_epoch" "$local_tip" "$remote_tip" "$wt_mt" "$hb_ep")
  if [[ -z "$last_active" ]]; then
    plan_row REFUSE no_valid_evidence "" "" "${wt_path:-}" >> "$PLAN_TMP"
    continue
  fi

  # Future-clock evidence fails closed (safe compare; both already bounded).
  if int_gt "$last_active" "$NOW"; then
    plan_row REFUSE future_clock_evidence "$last_active" "" "${wt_path:-}" >> "$PLAN_TMP"
    continue
  fi

  # age = NOW - last_active; both safe → arithmetic is safe.
  age=$((10#$NOW - 10#$last_active))

  # Open PR protects (successful query only).
  if [[ -z "$REPO" ]]; then
    plan_row REFUSE repo_unresolved_for_pr_check "$last_active" "$age" "${wt_path:-}" >> "$PLAN_TMP"
    continue
  fi
  pr_st=$(open_pr_status "$branch" "$REPO")
  case "$pr_st" in
    open)
      plan_row KEEP open_pr "$last_active" "$age" "${wt_path:-}" >> "$PLAN_TMP"
      continue
      ;;
    fail)
      plan_row REFUSE pr_query_failed "$last_active" "$age" "${wt_path:-}" >> "$PLAN_TMP"
      continue
      ;;
    none) ;;
    *)
      plan_row REFUSE pr_query_failed "$last_active" "$age" "${wt_path:-}" >> "$PLAN_TMP"
      continue
      ;;
  esac

  if [[ "$age" -gt "$STALE_SECONDS" ]]; then
    plan_row REAP stale "$last_active" "$age" "${wt_path:-}" >> "$PLAN_TMP"
  else
    plan_row KEEP recent_activity "$last_active" "$age" "${wt_path:-}" >> "$PLAN_TMP"
  fi
done < "$CLAIMS_TMP"

# --- print plan -----------------------------------------------------------
echo "=== claim-reaper plan (ref=$REF now=$NOW stale_seconds=$STALE_SECONDS apply=$APPLY prune_worktrees=$PRUNE_WORKTREES) ==="
reap_count=0
keep_count=0
refuse_count=0
while IFS= read -r prow || [[ -n "$prow" ]]; do
  [[ -n "$prow" ]] || continue
  p_action=$(printf '%s\n' "$prow" | awk -F'\t' '{print $1}')
  p_id=$(printf '%s\n' "$prow" | awk -F'\t' '{print $2}')
  p_issue=$(printf '%s\n' "$prow" | awk -F'\t' '{print $3}')
  p_branch=$(printf '%s\n' "$prow" | awk -F'\t' '{print $4}')
  p_last=$(printf '%s\n' "$prow" | awk -F'\t' '{print $5}')
  p_age=$(printf '%s\n' "$prow" | awk -F'\t' '{print $6}')
  p_reason=$(printf '%s\n' "$prow" | awk -F'\t' '{print $7}')
  case "$p_action" in
    REAP)
      reap_count=$((reap_count + 1))
      echo "  REAP   $p_id  issue=#$p_issue  branch=$p_branch  last_active=$p_last  age=${p_age}s  ($p_reason)"
      ;;
    KEEP)
      keep_count=$((keep_count + 1))
      echo "  KEEP   $p_id  issue=#$p_issue  branch=$p_branch  last_active=$p_last  age=${p_age}s  ($p_reason)"
      ;;
    REFUSE)
      refuse_count=$((refuse_count + 1))
      echo "  REFUSE $p_id  issue=#$p_issue  branch=$p_branch  ($p_reason)"
      ;;
  esac
done < "$PLAN_TMP"
echo "summary: reap=$reap_count keep=$keep_count refuse=$refuse_count"
echo "defaults on reap: keep-branch=yes keep-worktree=$([[ "$PRUNE_WORKTREES" -eq 1 ]] && echo no || echo yes) close-issue=never"

if [[ "$APPLY" -eq 0 ]]; then
  echo "DRY RUN — zero mutations (pass --apply to release)"
  exit 0
fi

# --- apply ----------------------------------------------------------------
# Acquire the single-instance lock BEFORE any journal/comment/release write.
if ! acquire_lock; then
  die "another claim-reaper apply holds the lock at $LOCK_DIR (concurrent applies serialize)"
fi

ensure_journal
INCOMPLETE=0
applied=0

# Reparse frozen claim fields from authoritative remote path+blob and compare.
# Sets globals: _rp_status (ok|FAIL:reason), _rp_issue, _rp_claimed, _rp_branch, _rp_wt.
# Must NOT be run in a command-substitution subshell (would drop globals).
_rp_status=""
_rp_issue=""
_rp_claimed=""
_rp_branch=""
_rp_wt=""
reparse_claim_fields() {
  local ref="$1" path="$2" expect_blob="$3" expect_id="$4" expect_source="$5"
  local body cur_blob body_id body_issue body_claimed body_branch body_wt active_blob _derived
  _rp_status=""
  _rp_issue=""
  _rp_claimed=""
  _rp_branch=""
  _rp_wt=""
  if [[ "$expect_source" == "file" ]]; then
    if ! git cat-file -e "${ref}:${path}" 2>/dev/null; then
      _rp_status="FAIL:absent"
      return 0
    fi
    cur_blob=$(git ls-tree "$ref" -- "$path" 2>/dev/null | awk '{print $3; exit}')
    if [[ -z "$cur_blob" || "$cur_blob" != "$expect_blob" ]]; then
      _rp_status="FAIL:blob_oid_changed"
      return 0
    fi
    body=$(git cat-file blob "$cur_blob" 2>/dev/null) || { _rp_status="FAIL:blob_unreadable"; return 0; }
    body_id=$(field_from_body "$body" "claim")
    if [[ "$body_id" != "$expect_id" ]]; then
      _rp_status="FAIL:body_id_mismatch"
      return 0
    fi
    if [[ "$path" != "docs/claims/${expect_id}.md" ]]; then
      _rp_status="FAIL:path_not_canonical"
      return 0
    fi
    body_issue=$(field_from_body "$body" "issue")
    body_claimed=$(field_from_body "$body" "claimed")
    body_branch=$(field_from_body "$body" "branch")
    body_wt=$(field_from_body "$body" "worktree")
    [[ -n "$body_issue" ]] || body_issue=$(issue_from_claim_id "$expect_id")
    [[ -n "$body_branch" ]] || body_branch=$(branch_for "$expect_id")
    if [[ -z "$body_issue" || ! "$body_issue" =~ ^[0-9]+$ ]]; then
      _rp_status="FAIL:malformed_issue"
      return 0
    fi
    _derived=$(issue_from_claim_id "$expect_id")
    if [[ -n "$_derived" && "$body_issue" != "$_derived" ]]; then
      _rp_status="FAIL:issue_id_mismatch"
      return 0
    fi
    _rp_issue="$body_issue"
    _rp_claimed="$body_claimed"
    _rp_branch="$body_branch"
    _rp_wt="$body_wt"
    _rp_status="ok"
    return 0
  fi
  # legacy: expect_blob = activeblob:claimid
  active_blob="${expect_blob%%:*}"
  if ! git cat-file -e "${ref}:docs/active-work.md" 2>/dev/null; then
    _rp_status="FAIL:absent"
    return 0
  fi
  cur_blob=$(git ls-tree "$ref" -- docs/active-work.md 2>/dev/null | awk '{print $3; exit}')
  if [[ -z "$cur_blob" || "$cur_blob" != "$active_blob" ]]; then
    _rp_status="FAIL:blob_oid_changed"
    return 0
  fi
  if ! git show "${ref}:docs/active-work.md" 2>/dev/null | awk -F'|' -v id="$expect_id" '
    /^\|/ {
      cid=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",cid);
      if (cid==id) found=1
    }
    END { exit !found }'; then
    _rp_status="FAIL:absent"
    return 0
  fi
  _rp_issue=$(issue_from_claim_id "$expect_id")
  _rp_claimed=$(git show "${ref}:docs/active-work.md" 2>/dev/null | awk -F'|' -v id="$expect_id" '
    /^\|/ {
      cid=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",cid);
      if (cid==id) {
        w=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",w); print w; exit
      }
    }')
  _rp_branch=$(branch_for "$expect_id")
  _rp_wt=""
  _rp_status="ok"
  return 0
}

claim_live_on_ref() {
  local ref="$1" id="$2" source="$3" path="$4" blob="$5"
  if [[ "$source" == "file" ]]; then
    git cat-file -e "${ref}:${path}" 2>/dev/null && return 0
    return 1
  fi
  git show "${ref}:docs/active-work.md" 2>/dev/null | awk -F'|' -v want="$id" '
    /^\|/ {
      cid=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",cid);
      if (cid==want) found=1
    }
    END { exit !found }'
}

while IFS= read -r prow || [[ -n "$prow" ]]; do
  [[ -n "$prow" ]] || continue
  p_action=$(printf '%s\n' "$prow" | awk -F'\t' '{print $1}')
  [[ "$p_action" == "REAP" ]] || continue

  p_id=$(printf '%s\n' "$prow" | awk -F'\t' '{print $2}')
  p_issue=$(printf '%s\n' "$prow" | awk -F'\t' '{print $3}')
  p_branch=$(printf '%s\n' "$prow" | awk -F'\t' '{print $4}')
  p_last=$(printf '%s\n' "$prow" | awk -F'\t' '{print $5}')
  p_blob=$(printf '%s\n' "$prow" | awk -F'\t' '{print $8}')
  p_wt=$(printf '%s\n' "$prow" | awk -F'\t' '{print $9}')
  p_claimed=$(printf '%s\n' "$prow" | awk -F'\t' '{print $10}')
  p_source=$(printf '%s\n' "$prow" | awk -F'\t' '{print $11}')
  p_path=$(printf '%s\n' "$prow" | awk -F'\t' '{print $12}')
  p_remote_sha=$(printf '%s\n' "$prow" | awk -F'\t' '{print $13}')
  [[ -n "$p_source" ]] || p_source="file"
  if [[ -z "$p_path" ]]; then
    if [[ "$p_source" == "legacy" ]]; then
      p_path="docs/active-work.md"
    else
      p_path="docs/claims/${p_id}.md"
    fi
  fi

  if [[ -n "$MAX_CLAIMS" && "$applied" -ge "$MAX_CLAIMS" ]]; then
    info "max-claims $MAX_CLAIMS reached — stopping"
    break
  fi

  # Stable operation id from claim id + frozen blob oid.
  op="reap:${p_id}:${p_blob}"

  # COMPLETED is idempotent only when authoritative remote proves the exact
  # claim is still absent. A re-added/live claim must not be silently skipped.
  if journal_has_completed "$op"; then
    if ! REF=$(fetch_remote_ledger_ref); then
      warn "COMPLETED op=$op but cannot re-fetch ledger — refuse skip (incomplete)"
      journal_append "INCOMPLETE op=${op} reason=completed_but_fetch_failed"
      INCOMPLETE=1
      continue
    fi
    if claim_live_on_ref "$REF" "$p_id" "$p_source" "$p_path" "$p_blob"; then
      warn "COMPLETED journal for $p_id but claim is live/re-added at $REF — re-evaluating (never silently skip)"
      journal_append "WARN op=${op} reason=completed_but_still_live reevaluate=1"
      # Continue under a new operation identity so mutation can proceed after checks.
      op="reap:${p_id}:${p_blob}:revivify"
    else
      # COMPLETED + absent: still ensure the success marker exists (covers an
      # older incomplete path that wrote COMPLETED without a handoff, and is a
      # no-op when the marker is already present).
      if ! ensure_absent_handoff_comment "$p_issue" "$REPO" "$p_id" "$p_branch" "${p_last:-unknown}"; then
        warn "COMPLETED journal for $p_id but handoff comment still missing — incomplete"
        journal_append "INCOMPLETE op=${op} reason=handoff_comment_failed after=completed_skip"
        INCOMPLETE=1
        continue
      fi
      info "skip $p_id — journal COMPLETED and claim absent at $REF (idempotent)"
      continue
    fi
  fi

  journal_append "STARTED op=${op} claim=${p_id} issue=${p_issue} blob=${p_blob} path=${p_path} source=${p_source}"

  # ---- pre-mutation recheck (race): require successful exact remote fetch ----
  if ! REF=$(fetch_remote_ledger_ref); then
    warn "pre-mutation: exact remote fetch failed — refuse $p_id (no local fallback)"
    journal_append "INCOMPLETE op=${op} reason=ledger_fetch_failed"
    INCOMPLETE=1
    continue
  fi

  reparse_claim_fields "$REF" "$p_path" "$p_blob" "$p_id" "$p_source"
  case "$_rp_status" in
    FAIL:absent)
      # Row already gone (e.g. prior release succeeded, comment failed). Post
      # the missing success handoff exactly once; never claim COMPLETED without it.
      info "claim $p_id already absent at $REF — ensuring handoff comment (idempotent)"
      if ! ensure_absent_handoff_comment "$p_issue" "$REPO" "$p_id" "$p_branch" "${p_last:-unknown}"; then
        journal_append "INCOMPLETE op=${op} reason=handoff_comment_failed claim_absent=1"
        warn "claim absent but handoff comment incomplete for $p_id"
        INCOMPLETE=1
        continue
      fi
      journal_append "COMPLETED op=${op} result=already_absent"
      continue
      ;;
    FAIL:*)
      warn "pre-mutation: reparse ${_rp_status} for $p_id — refuse (label/claim survive)"
      journal_append "INCOMPLETE op=${op} reason=${_rp_status#FAIL:}"
      INCOMPLETE=1
      continue
      ;;
    ok)
      # Frozen fields must still match what we planned against.
      if [[ -n "$_rp_issue" && "$_rp_issue" != "$p_issue" ]]; then
        warn "pre-mutation: issue field changed for $p_id — refuse"
        journal_append "INCOMPLETE op=${op} reason=issue_field_changed"
        INCOMPLETE=1
        continue
      fi
      if [[ -n "$_rp_branch" && "$_rp_branch" != "$p_branch" ]]; then
        warn "pre-mutation: branch field changed for $p_id — refuse"
        journal_append "INCOMPLETE op=${op} reason=branch_field_changed"
        INCOMPLETE=1
        continue
      fi
      if [[ -n "$_rp_claimed" && "$_rp_claimed" != "$p_claimed" ]]; then
        warn "pre-mutation: claimed timestamp changed for $p_id — refuse (renewal)"
        journal_append "INCOMPLETE op=${op} reason=claimed_changed"
        INCOMPLETE=1
        continue
      fi
      # Worktree field change: only matter for prune path; refuse if planned wt drifted.
      if [[ -n "$p_wt" && -n "$_rp_wt" && "$_rp_wt" != "$p_wt" ]]; then
        warn "pre-mutation: worktree field changed for $p_id — refuse"
        journal_append "INCOMPLETE op=${op} reason=worktree_field_changed"
        INCOMPLETE=1
        continue
      fi
      p_claimed="${_rp_claimed:-$p_claimed}"
      p_branch="${_rp_branch:-$p_branch}"
      p_issue="${_rp_issue:-$p_issue}"
      ;;
    *)
      warn "pre-mutation: unexpected reparse result '${_rp_status}' for $p_id — refuse"
      journal_append "INCOMPLETE op=${op} reason=reparse_unknown"
      INCOMPLETE=1
      continue
      ;;
  esac

  # Recompute last_active; refuse if fresher or fail.
  claim_epoch=$(claim_to_epoch "$p_claimed")
  if [[ -z "$claim_epoch" ]] || ! claim_epoch=$(parse_nonneg_int "$claim_epoch"); then
    warn "pre-mutation: claim timestamp unreadable for $p_id — refuse"
    journal_append "INCOMPLETE op=${op} reason=malformed_timestamp"
    INCOMPLETE=1
    continue
  fi
  local_tip=""
  remote_tip=""
  if [[ -n "$p_branch" ]]; then
    if ! valid_feature_branch_name "$p_branch"; then
      warn "pre-mutation: malformed branch for $p_id — refuse"
      journal_append "INCOMPLETE op=${op} reason=malformed_branch"
      INCOMPLETE=1
      continue
    fi
    local_tip=$(branch_tip_epoch "$p_branch")
    case "$local_tip" in
      FAIL:*)
        warn "pre-mutation: $local_tip"
        journal_append "INCOMPLETE op=${op} reason=branch_tip"
        INCOMPLETE=1
        continue
        ;;
    esac
    # Immediate re-check of the exact live remote feature branch (not cache).
    remote_ev=$(live_remote_branch_evidence "$p_branch")
    case "$remote_ev" in
      FAIL:*)
        warn "pre-mutation: live remote branch check failed for $p_id ($remote_ev) — refuse"
        journal_append "INCOMPLETE op=${op} reason=remote_tip"
        INCOMPLETE=1
        continue
        ;;
      ABSENT)
        # If plan froze a live SHA, the branch disappeared mid-flight — refuse.
        if [[ -n "$p_remote_sha" ]]; then
          warn "pre-mutation: live remote branch for $p_id gone (was $p_remote_sha) — refuse"
          journal_append "INCOMPLETE op=${op} reason=remote_branch_disappeared"
          INCOMPLETE=1
          continue
        fi
        remote_tip=""
        ;;
      OK:*)
        new_remote_sha="${remote_ev#OK:}"
        remote_tip="${new_remote_sha#*:}"
        new_remote_sha="${new_remote_sha%%:*}"
        if [[ ! "$new_remote_sha" =~ ^[0-9a-f]{40,64}$ ]] || ! remote_tip=$(parse_nonneg_int "$remote_tip"); then
          warn "pre-mutation: live remote tip unreadable for $p_id — refuse"
          journal_append "INCOMPLETE op=${op} reason=remote_tip"
          INCOMPLETE=1
          continue
        fi
        # Frozen SHA/timestamp must still match; any change keeps/refuses.
        if [[ -z "$p_remote_sha" ]]; then
          warn "pre-mutation: live remote branch for $p_id appeared since plan — refuse"
          journal_append "INCOMPLETE op=${op} reason=remote_branch_appeared"
          INCOMPLETE=1
          continue
        fi
        if [[ "$new_remote_sha" != "$p_remote_sha" ]]; then
          warn "pre-mutation: live remote branch SHA changed for $p_id ($p_remote_sha -> $new_remote_sha) — refuse (no release)"
          journal_append "INCOMPLETE op=${op} reason=remote_branch_changed"
          INCOMPLETE=1
          continue
        fi
        ;;
      *)
        warn "pre-mutation: unexpected live remote result for $p_id — refuse"
        journal_append "INCOMPLETE op=${op} reason=remote_tip"
        INCOMPLETE=1
        continue
        ;;
    esac
  fi
  wt_mt=""
  if [[ -n "$p_wt" ]]; then
    if [[ -L "$p_wt" ]] || [[ ! -d "$p_wt" ]] || ! worktree_registered "$p_wt"; then
      warn "pre-mutation: worktree unsafe/unregistered for $p_id — refuse"
      journal_append "INCOMPLETE op=${op} reason=worktree_race"
      INCOMPLETE=1
      continue
    fi
    wt_mt=$(worktree_tracked_mtime "$p_wt")
    case "$wt_mt" in
      FAIL:*)
        warn "pre-mutation: worktree evidence ${wt_mt} for $p_id — refuse"
        journal_append "INCOMPLETE op=${op} reason=worktree_evidence"
        INCOMPLETE=1
        continue
        ;;
    esac
  fi
  hb_ep=$(heartbeat_epoch "$p_id")
  case "$hb_ep" in
    FAIL:*)
      warn "pre-mutation: heartbeat ${hb_ep} for $p_id — refuse"
      journal_append "INCOMPLETE op=${op} reason=heartbeat"
      INCOMPLETE=1
      continue
      ;;
  esac
  new_last=$(max_epoch "$claim_epoch" "$local_tip" "$remote_tip" "$wt_mt" "$hb_ep")
  if [[ -z "$new_last" ]]; then
    warn "pre-mutation: no evidence for $p_id — refuse"
    journal_append "INCOMPLETE op=${op} reason=no_evidence"
    INCOMPLETE=1
    continue
  fi
  if int_gt "$new_last" "$NOW"; then
    warn "pre-mutation: future clock for $p_id — refuse"
    journal_append "INCOMPLETE op=${op} reason=future_clock"
    INCOMPLETE=1
    continue
  fi
  # Moving evidence / fresher activity: refuse if last_active advanced or age no longer stale.
  if int_gt "$new_last" "$p_last"; then
    warn "pre-mutation: evidence moved forward for $p_id ($p_last -> $new_last) — refuse"
    journal_append "INCOMPLETE op=${op} reason=moving_evidence"
    INCOMPLETE=1
    continue
  fi
  new_age=$((10#$NOW - 10#$new_last))
  if [[ "$new_age" -le "$STALE_SECONDS" ]]; then
    warn "pre-mutation: $p_id no longer stale (age=${new_age}s) — refuse"
    journal_append "INCOMPLETE op=${op} reason=no_longer_stale"
    INCOMPLETE=1
    continue
  fi

  pr_st=$(open_pr_status "$p_branch" "$REPO")
  if [[ "$pr_st" != "none" ]]; then
    warn "pre-mutation: PR status=$pr_st for $p_id — refuse"
    journal_append "INCOMPLETE op=${op} reason=pr_${pr_st}"
    INCOMPLETE=1
    continue
  fi

  # release-claim FIRST. Handoff comment posts only after success + verified
  # postconditions (Law 8). CAS mismatch, renewal, push rejection, prune
  # failure, or any incomplete release must leave no "released" comment.
  rc_args=("$p_issue" --claim-id "$p_id" --keep-branch --repo "$REPO"
    --expected-claim-blob "$p_blob" --expected-source "$p_source")
  if [[ "$p_source" == "file" ]]; then
    rc_args+=(--expected-claim-path "$p_path")
  fi
  if [[ "$PRUNE_WORKTREES" -eq 0 ]]; then
    rc_args+=(--keep-worktree)
  else
    # Pass exact frozen registered worktree path only — never derive default.
    if [[ -z "$p_wt" ]]; then
      warn "prune requested but no frozen registered worktree for $p_id — refuse prune (claim still released with keep-worktree)"
      rc_args+=(--keep-worktree)
    else
      if [[ -L "$p_wt" ]] || [[ ! -d "$p_wt" ]] || ! worktree_registered "$p_wt"; then
        warn "pre-release: prune target unsafe/unregistered for $p_id — refuse mutation"
        journal_append "INCOMPLETE op=${op} reason=prune_target_invalid"
        INCOMPLETE=1
        continue
      fi
      rc_args+=(--worktree-path "$p_wt" --expected-branch "$p_branch")
    fi
  fi

  info "releasing $p_id via release-claim (CAS blob=${p_blob} path=${p_path} source=${p_source})"
  set +e
  release_out=$(cd "$CANONICAL" && GIBSON_CANONICAL="$CANONICAL" "$RELEASE_CMD" "${rc_args[@]}" 2>&1)
  release_rc=$?
  set -e
  printf '%s\n' "$release_out" | sed 's/^/  | /'

  if [[ "$release_rc" -eq 0 ]]; then
    # Authoritative postcondition: claim must be absent before any success marker.
    if ! REF=$(fetch_remote_ledger_ref); then
      warn "release-claim rc=0 but cannot re-fetch ledger to prove absence for $p_id — incomplete (no success comment)"
      journal_append "INCOMPLETE op=${op} reason=post_release_fetch_failed"
      INCOMPLETE=1
      applied=$((applied + 1))
      continue
    fi
    if claim_live_on_ref "$REF" "$p_id" "$p_source" "$p_path" "$p_blob"; then
      warn "release-claim rc=0 but claim still live at $REF for $p_id — incomplete (no success comment)"
      journal_append "INCOMPLETE op=${op} reason=post_release_still_live"
      INCOMPLETE=1
      applied=$((applied + 1))
      continue
    fi
    # Post handoff only after verified release. Comment failure leaves the
    # operation incomplete so a later retry (claim absent) can post exactly once.
    if ! post_handoff_comment "$p_issue" "$REPO" "$p_id" "$p_branch" "$new_last"; then
      warn "release verified for $p_id but handoff comment failed — incomplete (no overall success; retry can post once)"
      journal_append "INCOMPLETE op=${op} reason=handoff_comment_failed claim_released=1"
      INCOMPLETE=1
      applied=$((applied + 1))
      continue
    fi
    journal_append "COMPLETED op=${op} result=released rc=0"
    info "OK released $p_id"
    applied=$((applied + 1))
  elif [[ "$release_rc" -eq 3 ]]; then
    # Incomplete cleanup — claim/label/worktree may survive. Never post released comment.
    journal_append "INCOMPLETE op=${op} reason=release_claim_incomplete rc=3"
    warn "release-claim incomplete for $p_id (no success handoff comment)"
    INCOMPLETE=1
    applied=$((applied + 1))
  else
    # CAS mismatch, renewal, push rejection, etc. — never post released comment.
    journal_append "INCOMPLETE op=${op} reason=release_claim_failed rc=${release_rc}"
    warn "release-claim failed for $p_id (rc=$release_rc; no success handoff comment)"
    INCOMPLETE=1
  fi
done < "$PLAN_TMP"

release_lock
trap 'rm -f "$CLAIMS_TMP" "$PLAN_TMP" "$IDENTITY_REFUSE_TMP" "$SEEN_IDS_TMP"' EXIT

info "apply finished: applied=$applied incomplete=$INCOMPLETE"
if [[ "$INCOMPLETE" -eq 1 ]]; then
  exit 3
fi
exit 0
