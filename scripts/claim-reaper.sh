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
  liveness from evidence (claim timestamp, local/remote branch tips, registered
  worktree tracked-file mtime, optional heartbeat file), and plans release of
  claims stale beyond a threshold (default 14400 seconds / 4 hours).

  Dry-run by default: prints a reviewable plan with zero mutations. --apply
  releases exactly one claim id at a time via release-claim.sh, journals each
  operation, posts a deduplicated handoff comment, and preserves the feature
  branch and worktree by default. --prune-worktrees may remove only the exact
  registered target worktree after the same safety checks.

  An open PR always protects a claim. API/ref failures, malformed evidence,
  unreadable worktrees, unregistered or unsafe paths, symlink/device evidence,
  future-clock evidence, or race-time activity fail closed (refuse reaping).
  The reaper never closes the target issue.

WHY
  Doctrine assumes dead lanes eventually free the issue, but nothing enforces
  it: a crashed lane leaves claim row + agent-claimed + worktree forever, and
  the fleet honors the claim. Conservative reaping from evidence is the janitor.

RISKS
  - Releases a claim row on main (via release-claim). Undo: re-claim the issue.
  - Optional worktree removal with --prune-worktrees (uncommitted work lost).
  - Posts an issue comment. Deduplicated; no absolute worktree paths.
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
info() { echo "claim-reaper.sh: $*"; }
warn() { echo "claim-reaper.sh: WARNING: $*" >&2; }

# --- arg validation (fail closed on hostile/malformed) --------------------
case "$STALE_SECONDS" in
  ''|*[!0-9]*) die "--stale-seconds must be a non-negative decimal integer" ;;
esac
# Normalize leading zeros without octal traps.
_stale_canon="$STALE_SECONDS"
while [[ "$_stale_canon" == 0* && ${#_stale_canon} -gt 1 ]]; do
  _stale_canon="${_stale_canon#0}"
done
STALE_SECONDS=$((10#$_stale_canon))

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
  case "$MAX_CLAIMS" in
    ''|*[!0-9]*) die "--max-claims must be a positive decimal integer" ;;
  esac
  _mc="$MAX_CLAIMS"
  while [[ "$_mc" == 0* && ${#_mc} -gt 1 ]]; do _mc="${_mc#0}"; done
  MAX_CLAIMS=$((10#$_mc))
  [[ "$MAX_CLAIMS" -ge 1 ]] || die "--max-claims must be >= 1"
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
  case "$raw" in
    ''|*[!0-9]*)
      die "GIBSON_CLAIMS_NOW_EPOCH must be decimal Unix epoch seconds"
      ;;
  esac
  canon="$raw"
  while [[ "$canon" == 0* && ${#canon} -gt 1 ]]; do
    canon="${canon#0}"
  done
  max_epoch="9223372036854775807"
  # shellcheck disable=SC2071
  if [[ ${#canon} -gt ${#max_epoch} ]] ||
     { [[ ${#canon} -eq ${#max_epoch} ]] && [[ "$canon" > "$max_epoch" ]]; }; then
    die "GIBSON_CLAIMS_NOW_EPOCH must be decimal Unix epoch seconds"
  fi
  NOW=$((10#$canon))
else
  NOW=$(date -u +%s)
fi

# --- ledger ref (remote tip; never caller's working tree) ------------------
git fetch origin >/dev/null 2>&1 || true

resolve_ledger_ref() {
  local candidate
  for candidate in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

REF=""
if ! REF=$(resolve_ledger_ref); then
  die "cannot resolve a valid ledger commit ref (tried origin/main, origin/master, main, master)"
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
  mt=$(stat -f %m "$f" 2>/dev/null) || mt=$(stat -c %Y "$f" 2>/dev/null) || mt=""
  case "$mt" in
    ''|*[!0-9]*) echo "" ;;
    *) echo "$mt" ;;
  esac
}

# Max of numeric args; empty if none.
max_epoch() {
  local m="" x
  for x in "$@"; do
    [[ -n "$x" ]] || continue
    case "$x" in *[!0-9]*) continue ;; esac
    if [[ -z "$m" ]] || [[ "$x" -gt "$m" ]]; then
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

# Branch tip committer epoch for a ref name. Empty if missing. FAIL: on error.
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

# Heartbeat file for a claim id. Prints epoch or FAIL:reason or empty.
heartbeat_epoch() {
  local id="$1"
  [[ -n "$HEARTBEAT_DIR" ]] || { echo ""; return 0; }
  local f1="$HEARTBEAT_DIR/$id" f2="$HEARTBEAT_DIR/${id}.heartbeat" f=""
  if [[ -e "$f1" || -L "$f1" ]]; then
    f="$f1"
  elif [[ -e "$f2" || -L "$f2" ]]; then
    f="$f2"
  else
    echo ""
    return 0
  fi
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
  # Prefer first-line content as epoch or ISO-Z (the heartbeat signal). Fall
  # back to file mtime only when content is empty/unparseable — never mix a
  # wall-clock mtime with an explicit content stamp (that would turn a valid
  # past heartbeat into "future" under an injected test clock, and in
  # production the content is the authoritative liveness proof).
  local first content_epoch mt
  first=$(head -n 1 "$f" 2>/dev/null || true)
  first=$(printf '%s' "$first" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ -n "$first" ]]; then
    case "$first" in
      *[!0-9]*)
        content_epoch=$(claim_to_epoch "$first")
        ;;
      *)
        content_epoch="$first"
        while [[ "$content_epoch" == 0* && ${#content_epoch} -gt 1 ]]; do
          content_epoch="${content_epoch#0}"
        done
        case "$content_epoch" in
          ''|*[!0-9]*) content_epoch="" ;;
        esac
        ;;
    esac
  fi
  if [[ -n "${content_epoch:-}" ]]; then
    printf '%s\n' "$content_epoch"
    return 0
  fi
  mt=$(file_mtime_epoch "$f")
  case "$mt" in
    SYMLINK) echo "FAIL:heartbeat_symlink"; return 0 ;;
    DEVICE) echo "FAIL:heartbeat_device"; return 0 ;;
    '') echo "FAIL:heartbeat_unreadable"; return 0 ;;
    *) printf '%s\n' "$mt" ;;
  esac
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
post_handoff_comment() {
  local issue="$1" repo="$2" id="$3" branch="$4" last_active="$5"
  local marker body
  marker=$(comment_marker "$id")
  body=$(cat <<EOF
Lane presumed dead (no liveness evidence within the reaper threshold).

- claim: \`${id}\`
- last-active (UTC epoch): ${last_active}
- work preserved on branch: \`${branch}\`
- claim row released by claim-reaper; feature branch and worktree kept by default

${marker}
EOF
)
  # If already present, skip (dedupe).
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

# Journal helpers (append-only).
ensure_journal() {
  mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null || true
  if [[ ! -f "$JOURNAL" ]]; then
    printf '# claim-reaper journal\n\n' > "$JOURNAL"
  fi
}

journal_append() {
  local line="$1"
  ensure_journal
  # Single-line records only; strip newlines from hostile inputs.
  line=$(printf '%s' "$line" | tr '\n\r' '  ')
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo ts)" "$line" >> "$JOURNAL"
}

# True if COMPLETED record exists for op id.
journal_has_completed() {
  local op="$1"
  [[ -f "$JOURNAL" ]] || return 1
  grep -qF -- " COMPLETED op=${op} " "$JOURNAL" 2>/dev/null || \
    grep -qE -- " COMPLETED op=${op}( |$)" "$JOURNAL" 2>/dev/null
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
# id \t issue \t claimed_raw \t branch \t worktree \t blob_oid \t source

CLAIMS_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-reaper-claims.XXXXXX")
PLAN_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-reaper-plan.XXXXXX")
trap 'release_lock; rm -f "$CLAIMS_TMP" "$PLAN_TMP"' EXIT

# Collect raw rows into CLAIMS_TMP then dedupe by id (prefer per-file over legacy).
: > "$CLAIMS_TMP"

# Per-file claims
if [[ "$HAS_CLAIMS_TREE" -eq 1 ]]; then
  while IFS= read -r claim_line; do
    [[ -n "$claim_line" ]] || continue
    claim_obj=$(printf '%s\n' "$claim_line" | awk '{print $3; exit}')
    claim_path="${claim_line#*$'\t'}"
    case "$claim_path" in
      docs/claims/*.md) ;;
      *) continue ;;
    esac
    body=$(git cat-file blob "$claim_obj" 2>/dev/null) || die "cannot read $claim_path blob $claim_obj"
    id=$(field_from_body "$body" "claim")
    [[ -n "$id" ]] || id=$(basename "$claim_path" .md)
    claimed=$(field_from_body "$body" "claimed")
    issue=$(field_from_body "$body" "issue")
    branch=$(field_from_body "$body" "branch")
    worktree=$(field_from_body "$body" "worktree")
    [[ -n "$issue" ]] || issue=$(issue_from_claim_id "$id")
    [[ -n "$branch" ]] || branch=$(branch_for "$id")
    printf '%s\t%s\t%s\t%s\t%s\t%s\tfile\n' \
      "$id" "$issue" "$claimed" "$branch" "$worktree" "$claim_obj" >> "$CLAIMS_TMP"
  done <<EOF
$(git ls-tree "$REF" docs/claims/ 2>/dev/null || true)
EOF
fi

# Legacy rows (column 3 = claim-id only)
if [[ "$HAS_ACTIVE" -eq 1 ]]; then
  active_body=$(git show "$REF:docs/active-work.md" 2>/dev/null) || die "cannot read docs/active-work.md"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^\| ]] || continue
    cid=$(printf '%s\n' "$line" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$cid" ]] || continue
    [[ "$cid" == "claim-id" || "$cid" == "---" ]] && continue
    [[ "$cid" =~ ^-+$ ]] && continue
    echo "$cid" | grep -qE '^issue-' || continue
    claimed=$(printf '%s\n' "$line" | awk -F'|' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    issue=$(issue_from_claim_id "$cid")
    branch=$(branch_for "$cid")
    worktree=""
    # blob oid for legacy: use active-work blob + claim id as synthetic key
    active_blob=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $3; exit}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\tlegacy\n' \
      "$cid" "$issue" "$claimed" "$branch" "$worktree" "${active_blob:-legacy}:$cid" >> "$CLAIMS_TMP"
  done <<EOF
$active_body
EOF
fi

# Dedupe: for each id keep file over legacy, else first.
DEDUP_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-reaper-dedup.XXXXXX")
trap 'release_lock; rm -f "$CLAIMS_TMP" "$PLAN_TMP" "$DEDUP_TMP"' EXIT
: > "$DEDUP_TMP"
# Sort so "file" source sorts before "legacy" when we keep first after id group…
# Actually: prefer file — process file rows first then legacy skip if id exists.
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  src="${row##*$'\t'}"
  [[ "$src" == "file" ]] || continue
  printf '%s\n' "$row" >> "$DEDUP_TMP"
done < "$CLAIMS_TMP"
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  src="${row##*$'\t'}"
  [[ "$src" == "legacy" ]] || continue
  id="${row%%$'\t'*}"
  if grep -q "^${id}$(printf '\t')" "$DEDUP_TMP" 2>/dev/null; then
    continue
  fi
  # Also match id at start with tab
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
  mv "$FILTERED" "$CLAIMS_TMP"
  if [[ ! -s "$CLAIMS_TMP" ]]; then
    # Apply against an already-released id is a successful no-op (idempotent).
    if [[ "$APPLY" -eq 1 ]]; then
      info "no live claim '$CLAIM_ID_FILTER' at $REF — nothing to reap (idempotent)"
      ensure_journal
      journal_append "COMPLETED op=reap:${CLAIM_ID_FILTER}:absent result=already_absent"
      exit 0
    fi
    die "no live claim '$CLAIM_ID_FILTER' at $REF"
  fi
fi

info "ledger ref: $REF; scanning claims (stale>${STALE_SECONDS}s)"

# --- evaluate each claim --------------------------------------------------
: > "$PLAN_TMP"
# plan columns: action\tid\tissue\tbranch\tlast_active\tage\treason\tblob\twt\tclaimed_raw

REPO=$(resolve_repo 2>/dev/null || true)

# Emit one plan row. Uses caller's id/issue/branch/blob/claimed_raw.
# Args: action reason last_active age worktree_path
plan_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$id" "$issue" "$branch" "${3:-}" "${4:-}" "$2" "$blob" "${5:-}" "$claimed_raw"
}

while IFS= read -r row || [[ -n "$row" ]]; do
  [[ -n "$row" ]] || continue
  # Parse TSV safely
  id=$(printf '%s\n' "$row" | awk -F'\t' '{print $1}')
  issue=$(printf '%s\n' "$row" | awk -F'\t' '{print $2}')
  claimed_raw=$(printf '%s\n' "$row" | awk -F'\t' '{print $3}')
  branch=$(printf '%s\n' "$row" | awk -F'\t' '{print $4}')
  worktree=$(printf '%s\n' "$row" | awk -F'\t' '{print $5}')
  blob=$(printf '%s\n' "$row" | awk -F'\t' '{print $6}')
  # source column ($7: file|legacy) retained in CLAIMS_TMP for audit; unused here.

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

  # Claim timestamp is required evidence base.
  claim_epoch=$(claim_to_epoch "$claimed_raw")
  if [[ -z "$claim_epoch" ]]; then
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
  wt_mt=""
  hb_ep=""

  if [[ -n "$branch" ]]; then
    local_tip=$(branch_tip_epoch "$branch")
    case "$local_tip" in
      FAIL:*) evidence_fail="${local_tip#FAIL:}"; local_tip="" ;;
    esac
    if [[ -z "$evidence_fail" ]]; then
      remote_tip=$(branch_tip_epoch "origin/$branch")
      case "$remote_tip" in
        FAIL:*) evidence_fail="${remote_tip#FAIL:}"; remote_tip="" ;;
      esac
    fi
  fi

  # Worktree: if listed in claim, must be absolute and safe; if absent, try default
  # only when that path is a registered worktree. Unregistered listed path → refuse.
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
        esac
      fi
    else
      wt_mt=$(worktree_tracked_mtime "$wt_path")
      case "$wt_mt" in
        FAIL:*) evidence_fail="${wt_mt#FAIL:}"; wt_mt="" ;;
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

  # Future-clock evidence fails closed.
  if [[ "$last_active" -gt "$NOW" ]]; then
    plan_row REFUSE future_clock_evidence "$last_active" "" "${wt_path:-}" >> "$PLAN_TMP"
    continue
  fi

  age=$((NOW - last_active))

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
if ! acquire_lock; then
  die "another claim-reaper apply holds the lock at $LOCK_DIR (concurrent applies serialize)"
fi

ensure_journal
INCOMPLETE=0
applied=0

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

  if [[ -n "$MAX_CLAIMS" && "$applied" -ge "$MAX_CLAIMS" ]]; then
    info "max-claims $MAX_CLAIMS reached — stopping"
    break
  fi

  # Stable operation id from claim id + frozen blob oid.
  op="reap:${p_id}:${p_blob}"

  if journal_has_completed "$op"; then
    info "skip $p_id — journal already COMPLETED op=$op (idempotent)"
    # If claim already gone, fine; if still live, still skip mutation to avoid loops
    # only when completed. Re-check: if still live after completed, warn.
    continue
  fi

  journal_append "STARTED op=${op} claim=${p_id} issue=${p_issue} blob=${p_blob}"

  # ---- pre-mutation recheck (race) ----
  git fetch origin >/dev/null 2>&1 || true
  if ! REF=$(resolve_ledger_ref); then
    warn "pre-mutation: ledger ref lost — refuse $p_id"
    journal_append "INCOMPLETE op=${op} reason=ledger_ref_lost"
    INCOMPLETE=1
    continue
  fi

  # Exact claim blob/OID recheck for per-file claims.
  still_live=0
  new_blob=""
  if git cat-file -e "$REF:docs/claims/${p_id}.md" 2>/dev/null; then
    still_live=1
    new_blob=$(git ls-tree "$REF" -- "docs/claims/${p_id}.md" 2>/dev/null | awk '{print $3; exit}')
  fi
  # Legacy presence
  if [[ "$still_live" -eq 0 ]]; then
    if git show "$REF:docs/active-work.md" 2>/dev/null | awk -F'|' -v id="$p_id" '
      /^\|/ {
        cid=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",cid);
        if (cid==id) found=1
      }
      END { exit !found }'; then
      still_live=1
      new_blob="$p_blob"
    fi
  fi

  if [[ "$still_live" -eq 0 ]]; then
    info "claim $p_id already absent at $REF — marking completed (idempotent)"
    journal_append "COMPLETED op=${op} result=already_absent"
    continue
  fi

  # Blob OID race (per-file): if changed, activity or rewrite → refuse.
  if [[ "$p_blob" != *":"* ]]; then
    # per-file blob oid
    if [[ -n "$new_blob" && "$new_blob" != "$p_blob" ]]; then
      warn "pre-mutation: claim blob OID changed for $p_id — refuse (race)"
      journal_append "INCOMPLETE op=${op} reason=blob_oid_changed"
      INCOMPLETE=1
      continue
    fi
  fi

  # Recompute last_active; refuse if fresher or fail.
  claim_epoch=$(claim_to_epoch "$p_claimed")
  local_tip=$(branch_tip_epoch "$p_branch")
  case "$local_tip" in FAIL:*) warn "pre-mutation: $local_tip"; journal_append "INCOMPLETE op=${op} reason=branch_tip"; INCOMPLETE=1; continue ;; esac
  remote_tip=$(branch_tip_epoch "origin/$p_branch")
  case "$remote_tip" in FAIL:*) warn "pre-mutation: $remote_tip"; journal_append "INCOMPLETE op=${op} reason=remote_tip"; INCOMPLETE=1; continue ;; esac
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
  if [[ "$new_last" -gt "$NOW" ]]; then
    warn "pre-mutation: future clock for $p_id — refuse"
    journal_append "INCOMPLETE op=${op} reason=future_clock"
    INCOMPLETE=1
    continue
  fi
  # Moving evidence / fresher activity: refuse if last_active advanced or age no longer stale.
  if [[ "$new_last" -gt "$p_last" ]]; then
    warn "pre-mutation: evidence moved forward for $p_id ($p_last -> $new_last) — refuse"
    journal_append "INCOMPLETE op=${op} reason=moving_evidence"
    INCOMPLETE=1
    continue
  fi
  new_age=$((NOW - new_last))
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

  # Handoff comment (deduped; never absolute worktree path)
  if ! post_handoff_comment "$p_issue" "$REPO" "$p_id" "$p_branch" "$new_last"; then
    warn "handoff comment failed for $p_id — refuse mutation (fail closed)"
    journal_append "INCOMPLETE op=${op} reason=comment_failed"
    INCOMPLETE=1
    continue
  fi

  # release-claim: exact id, keep branch, keep worktree unless prune
  rc_args=("$p_issue" --claim-id "$p_id" --keep-branch --repo "$REPO")
  if [[ "$PRUNE_WORKTREES" -eq 0 ]]; then
    rc_args+=(--keep-worktree)
  fi

  info "releasing $p_id via release-claim ${rc_args[*]}"
  set +e
  release_out=$(cd "$CANONICAL" && GIBSON_CANONICAL="$CANONICAL" "$RELEASE_CMD" "${rc_args[@]}" 2>&1)
  release_rc=$?
  set -e
  printf '%s\n' "$release_out" | sed 's/^/  | /'

  if [[ "$release_rc" -eq 0 ]]; then
    journal_append "COMPLETED op=${op} result=released rc=0"
    info "OK released $p_id"
    applied=$((applied + 1))
  elif [[ "$release_rc" -eq 3 ]]; then
    # Incomplete cleanup in release-claim — journal incomplete
    journal_append "INCOMPLETE op=${op} reason=release_claim_incomplete rc=3"
    warn "release-claim incomplete for $p_id"
    INCOMPLETE=1
    applied=$((applied + 1))
  else
    journal_append "INCOMPLETE op=${op} reason=release_claim_failed rc=${release_rc}"
    warn "release-claim failed for $p_id (rc=$release_rc)"
    INCOMPLETE=1
  fi
done < "$PLAN_TMP"

release_lock
trap 'rm -f "$CLAIMS_TMP" "$PLAN_TMP"' EXIT

info "apply finished: applied=$applied incomplete=$INCOMPLETE"
if [[ "$INCOMPLETE" -eq 1 ]]; then
  exit 3
fi
exit 0
