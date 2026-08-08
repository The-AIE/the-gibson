#!/usr/bin/env bash
# loop-fleet.sh — portable multi-lane Gibson fleet driver (issue #139)
#
# WHY
#   scripts/loop.sh is serial: one hat, one issue, one runner at a time. This
#   driver fans the same loop across disjoint lanes so unattended hours
#   compound. Target repo, issue queues, exclusive scopes, and intent live in
#   a versioned declarative profile — never embedded for one product repo.
#
# HOW IT STAYS SAFE
#   - Profile is declarative data (key=value / lane= lines). NEVER sourced.
#   - Each lane gets its OWN long-lived worktree (lane-*, never wt-*).
#   - Lanes pin disjoint file scopes; inter-lane overlap is checked with the
#     same path/glob containment heuristics as scripts/scope-overlap.mjs.
#   - Preflight fail-closes before any runner launch (slug, dirty tree,
#     missing/closed/gated issues, claim/PR conflicts, malformed profile).
#   - REVIEWER_CMD is cross-vendor by default; RELEASE_CMD is a third identity.
#     The implementation runner never grades or merges its own work.
#   - Per-lane runner/pool routing is reserved (lane runner field) for #141
#     and is NOT implemented here — global RUNNER only.
#
# PROFILE
#   FLEET_PROFILE=/absolute/path/to/profile
#   and/or --profile /absolute/path/to/profile
#   Format: templates/fleet/profile.v1.example + templates/fleet/README.md
#
# STOP IT
#   loop-fleet.sh --profile PATH --halt   # graceful: lanes finish current hat
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
DEFAULT_GIBSON=$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd)

# --- globals (filled by profile load / env) ---------------------------------
PROFILE_PATH=""
PROFILE_NAME=""
PROFILE_VERSION=""
BASE_REPO=""
EXPECTED_SLUG=""
GIBSON="${GIBSON:-}"
FLEET_DIR="${FLEET_DIR:-}"
LOG_DIR="${LOG_DIR:-}"
RUNNER="${RUNNER:-grok}"
ERROR_BUDGET="${ERROR_BUDGET:-4}"
DEADLINE_SECONDS="${DEADLINE_SECONDS:-79200}"

# Three-role split, cross-vendor at every handoff:
#   build (RUNNER) -> review (Codex/other) -> merge (Claude/third).
# Neither the builder nor the reviewer ever merges its own/co-vendor's work.
export REVIEWER_CMD="${REVIEWER_CMD:-codex exec -s read-only -}"
# RELEASE_CMD needs Bash + gh. Claude acceptEdits blocks Bash/gh (L-048).
export RELEASE_CMD="${RELEASE_CMD:-claude -p --output-format text --permission-mode bypassPermissions}"

# Lane parallel arrays (bash 3.2 — no associative arrays).
LANE_IDS=()
LANE_QUEUES=()
LANE_SCOPES=()
LANE_INTENTS=()
LANE_RUNNERS=()   # reserved for #141; accepted, not used for routing

# Test / ops hooks (PATH stubs preferred; these override when set).
GH_BIN="${GH_BIN:-gh}"
LOOP_SH="${LOOP_SH:-}"          # default: $GIBSON/scripts/loop.sh after load
SLEEP_CMD="${SLEEP_CMD:-sleep}" # tests can set to true / no-op
# Test hooks (unset in production):
#   FLEET_SYNC_LAUNCH=1  — run loop.sh in-foreground (no nohup); deterministic sensors
#   FLEET_NO_WATCHDOG=1  — skip deadline watchdog process
FLEET_SYNC_LAUNCH="${FLEET_SYNC_LAUNCH:-0}"
FLEET_NO_WATCHDOG="${FLEET_NO_WATCHDOG:-0}"
FLEET_SKIP_FETCH="${FLEET_SKIP_FETCH:-0}"

CMD="--start"

usage() {
  cat <<'EOF'
loop-fleet.sh — parallel Gibson loops, one long-lived worktree per lane

WHAT IT DOES
  Loads a versioned declarative fleet profile (target repo, slug, lanes with
  ordered issue queues, exclusive scopes, intent), preflights fail-closed,
  then launches one scripts/loop.sh per lane. Status / halt / start all print
  the resolved profile name, absolute target repo, and expected GitHub slug.

WHY
  Embedding queues/scopes for one product repo and only swapping BASE_REPO aims
  the wrong issues at another target. An explicit profile makes the fleet
  portable (issue #139). Per-lane runner pools are follow-up #141.

USAGE
  FLEET_PROFILE=/absolute/path/to/profile loop-fleet.sh [--start|--halt|--status]
  loop-fleet.sh --profile /absolute/path/to/profile [--start|--halt|--status]
  loop-fleet.sh --help

OPTIONS
  --profile PATH   absolute path to a fleet profile (or set FLEET_PROFILE)
  --start          preflight + create/reuse lane bases + launch (default)
  --halt           write gibson/HALT into every lane (graceful stop)
  --status         show profile identity and per-lane pid/hat/health
  --help           this help

ENV (optional overrides after profile load)
  FLEET_PROFILE    absolute profile path
  GIBSON           Gibson clone (default: parent of scripts/, or profile gibson=)
  FLEET_DIR        directory for lane-* worktrees (must be absolute)
  LOG_DIR          per-lane logs (must be absolute)
  RUNNER           builder CLI name (default: grok) — global until #141
  ERROR_BUDGET     passed to loop.sh (default: 4)
  DEADLINE_SECONDS watchdog sleep before --halt (default: 79200 = 22h)
  REVIEWER_CMD     cross-vendor reviewer (default: codex exec -s read-only -)
  RELEASE_CMD      third-identity release (default: claude … bypassPermissions)
  GH_BIN           gh binary (tests stub this)
  LOOP_SH          loop.sh path (tests stub this)

PROFILE FORMAT (v1) — declarative data only; NEVER source the file
  See templates/fleet/profile.v1.example and templates/fleet/README.md.

RISKS
  Wrong profile → wrong issues on a real repo. Preflight refuses dirty
  checkouts, gated labels, scope overlap, and slug mismatch. Still review
  the profile path before --start on a machine that can push.

EXIT
  0  ok
  1  preflight / runtime failure (fail closed; zero launches on preflight fail)
  2  usage error
EOF
}

info() { echo "fleet: $*" >&2; }
die()  { echo "fleet: ERROR: $*" >&2; exit 1; }
usage_err() { echo "fleet: $*" >&2; usage >&2; exit 2; }

# --- path / string helpers --------------------------------------------------

is_absolute_path() {
  case "${1:-}" in
    /*) return 0 ;;
    *)  return 1 ;;
  esac
}

# Reject empty, relative, tilde, and any ".." segment (unsafe resolution).
assert_safe_abs_path() {
  local label="$1" p="$2"
  [[ -n "$p" ]] || die "$label is empty"
  is_absolute_path "$p" || die "$label must be an absolute path (got: $p)"
  case "$p" in
    *'/../'*|*/..|'/..'*) die "$label must not contain '..' segments (got: $p)" ;;
  esac
  # No control characters / newlines smuggled into paths
  case "$p" in
    *$'\n'*|*$'\r'*|*$'\t'*) die "$label contains illegal control characters" ;;
  esac
}

origin_slug_from_url() {
  # Mirror dogfood-prep / loop.sh normalization (owner/repo only).
  local url="${1:-}" norm
  norm="$url"
  norm=${norm%.git}
  norm=${norm#git@github.com:}
  norm=${norm#https://github.com/}
  norm=${norm#http://github.com/}
  norm=${norm#ssh://git@github.com/}
  # ssh://git@github.com:22/owner/repo
  if [[ "$norm" == git@github.com:* ]]; then
    norm=${norm#git@github.com:}
  fi
  # leftover ssh host forms: github.com:owner/repo
  if [[ "$norm" == github.com:* ]]; then
    norm=${norm#github.com:}
  fi
  # ssh://git@github.com/owner/repo already stripped host prefix above
  # Drop any remaining user@host: or scheme leftovers that leave owner/repo
  if [[ "$norm" == *"/"*"/"* ]]; then
    # path with extra segments — take last two when looks like .../owner/repo
    :
  fi
  printf '%s\n' "$norm"
}

print_identity() {
  info "profile=$PROFILE_NAME"
  info "profile_path=$PROFILE_PATH"
  info "target_repo=$BASE_REPO"
  info "expected_slug=$EXPECTED_SLUG"
  info "gibson=$GIBSON"
}

# --- scope overlap (ported from scripts/scope-overlap.mjs tokensOverlap) ----

scope_stem() {
  local token="$1"
  token="${token%/}"
  # strip trailing /** or /* or *
  token="${token%/\*\*}"
  token="${token%\*\*}"
  token="${token%\*}"
  token="${token%/}"
  printf '%s\n' "$token"
}

scope_tokens_overlap() {
  # True (0) when two scope tokens collide under path/glob containment —
  # NOT string-equality alone (L-001 / #106 class).
  local a="$1" b="$2" sa sb
  [[ -n "$a" && -n "$b" ]] || return 1
  [[ "$a" == "$b" ]] && return 0
  sa=$(scope_stem "$a")
  sb=$(scope_stem "$b")
  [[ -n "$sa" && -n "$sb" ]] || return 1
  [[ "$sa" == "$sb" ]] && return 0
  case "$sa" in
    "$sb"/*) return 0 ;;
  esac
  case "$sb" in
    "$sa"/*) return 0 ;;
  esac
  # boundary-aware stem containment (avoid "app" vs "application")
  case "$sa" in
    "$sb"|"$sb"/*|"$sb".*) return 0 ;;
  esac
  case "$sb" in
    "$sa"|"$sa"/*|"$sa".*) return 0 ;;
  esac
  return 1
}

scopes_lists_overlap() {
  # Args: two space-separated scope lists. Prints colliding pair on stdout if any.
  local list_a="$1" list_b="$2" ta tb
  # shellcheck disable=SC2086
  for ta in $list_a; do
    # shellcheck disable=SC2086
    for tb in $list_b; do
      if scope_tokens_overlap "$ta" "$tb"; then
        printf '%s ↔ %s\n' "$ta" "$tb"
        return 0
      fi
    done
  done
  return 1
}

check_inter_lane_scope_overlap() {
  local i j hit
  local n=${#LANE_IDS[@]}
  [[ "$n" -ge 1 ]] || die "profile has no lanes"
  i=0
  while [[ $i -lt $n ]]; do
    j=$((i + 1))
    while [[ $j -lt $n ]]; do
      if hit=$(scopes_lists_overlap "${LANE_SCOPES[$i]}" "${LANE_SCOPES[$j]}"); then
        die "lane scope overlap: ${LANE_IDS[$i]} ↔ ${LANE_IDS[$j]} ($hit)"
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done
}

# --- profile load (declarative parse — never source) ------------------------

validate_issue_id() {
  local id="$1"
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || die "invalid issue id '$id' (need positive integer)"
}

validate_lane_id() {
  local id="$1"
  [[ -n "$id" ]] || die "empty lane id"
  # portable id: letters, digits, underscore, hyphen
  [[ "$id" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "invalid lane id '$id' (use [A-Za-z][A-Za-z0-9_-]*)"
  case "$id" in
    wt-*) die "lane id '$id' must not start with wt- (lane bases are never wt-*)" ;;
  esac
}

parse_lane_line() {
  # Fields: id|queue|scope|intent[|runner_reserved]
  local raw="$1"
  local id queue scope intent runner_r rest
  # Do not eval. Split on | with read.
  IFS='|' read -r id queue scope intent rest <<<"$raw" || true
  # rest may contain runner and further ignored forwards-compatible fields
  runner_r="${rest%%|*}"

  id=$(printf '%s' "$id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  queue=$(printf '%s' "$queue" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  scope=$(printf '%s' "$scope" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  intent=$(printf '%s' "$intent" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  runner_r=$(printf '%s' "$runner_r" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  validate_lane_id "$id"
  [[ -n "$queue" ]] || die "lane $id: empty issue queue"
  [[ -n "$scope" ]] || die "lane $id: empty exclusive scope"
  [[ -n "$intent" ]] || die "lane $id: empty intent"

  local qitem first=1 qclean="" seen="" queue_work
  # bash 3.2: portable comma-split without mapfile / read -a
  queue_work=$(printf '%s' "$queue" | tr ',' ' ')
  # shellcheck disable=SC2086
  for qitem in $queue_work; do
    qitem=$(printf '%s' "$qitem" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$qitem" ]] || continue
    validate_issue_id "$qitem"
    case ",$seen," in
      *",$qitem,"*) die "lane $id: duplicate issue #$qitem in queue" ;;
    esac
    seen="${seen},${qitem}"
    if [[ $first -eq 1 ]]; then
      qclean="$qitem"
      first=0
    else
      qclean="$qclean,$qitem"
    fi
  done
  [[ -n "$qclean" ]] || die "lane $id: empty issue queue after parse"

  # duplicate lane id?
  local existing
  if [[ ${#LANE_IDS[@]} -gt 0 ]]; then
    for existing in "${LANE_IDS[@]}"; do
      [[ "$existing" == "$id" ]] && die "duplicate lane id: $id"
    done
  fi

  LANE_IDS+=("$id")
  LANE_QUEUES+=("$qclean")
  LANE_SCOPES+=("$scope")
  LANE_INTENTS+=("$intent")
  LANE_RUNNERS+=("$runner_r")
}

load_profile() {
  local path="$1"
  [[ -n "$path" ]] || usage_err "profile required: set FLEET_PROFILE or pass --profile PATH"
  is_absolute_path "$path" || die "profile path must be absolute (got: $path)"
  assert_safe_abs_path "profile path" "$path"
  [[ -f "$path" ]] || die "profile not found: $path"
  [[ -r "$path" ]] || die "profile not readable: $path"

  PROFILE_PATH="$path"
  PROFILE_NAME=""
  PROFILE_VERSION=""
  BASE_REPO=""
  EXPECTED_SLUG=""
  local prof_gibson="" prof_fleet="" prof_log="" prof_runner="" prof_budget="" prof_deadline=""
  LANE_IDS=()
  LANE_QUEUES=()
  LANE_SCOPES=()
  LANE_INTENTS=()
  LANE_RUNNERS=()

  local line lineno=0 key val
  # Read without sourcing. Strip CR for Windows-edited profiles.
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    # comments and blanks
    case "$line" in
      ''|\#*) continue ;;
    esac
    # must be key=value (value may contain =)
    case "$line" in
      *=*) ;;
      *) die "profile line $lineno: expected key=value (got: $line)" ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # trim only leading space on value (intent/scopes may need internal spaces)
    val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//')
    # trailing space trim for non-intent scalar keys; for lane keep as-is after field split
    case "$key" in
      version|name|repo|slug|gibson|fleet_dir|log_dir|runner|error_budget|deadline_seconds)
        val=$(printf '%s' "$val" | sed 's/[[:space:]]*$//')
        ;;
    esac

    case "$key" in
      version)
        PROFILE_VERSION="$val"
        ;;
      name)
        PROFILE_NAME="$val"
        ;;
      repo)
        BASE_REPO="$val"
        ;;
      slug)
        EXPECTED_SLUG="$val"
        ;;
      gibson)
        prof_gibson="$val"
        ;;
      fleet_dir)
        prof_fleet="$val"
        ;;
      log_dir)
        prof_log="$val"
        ;;
      runner)
        prof_runner="$val"
        ;;
      error_budget)
        prof_budget="$val"
        ;;
      deadline_seconds)
        prof_deadline="$val"
        ;;
      lane)
        parse_lane_line "$val"
        ;;
      *)
        die "profile line $lineno: unknown field '$key' (v1 allows version,name,repo,slug,gibson,fleet_dir,log_dir,runner,error_budget,deadline_seconds,lane)"
        ;;
    esac
  done < "$path"

  [[ -n "$PROFILE_VERSION" ]] || die "profile missing version="
  [[ "$PROFILE_VERSION" == "1" ]] || die "unsupported profile version '$PROFILE_VERSION' (this driver implements v1 only)"
  [[ -n "$PROFILE_NAME" ]] || die "profile missing name="
  [[ "$PROFILE_NAME" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] || die "invalid profile name '$PROFILE_NAME'"
  [[ -n "$BASE_REPO" ]] || die "profile missing repo="
  [[ -n "$EXPECTED_SLUG" ]] || die "profile missing slug="
  [[ "$EXPECTED_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid slug '$EXPECTED_SLUG' (want owner/repo)"

  assert_safe_abs_path "repo" "$BASE_REPO"
  [[ -d "$BASE_REPO" ]] || die "repo path is not a directory: $BASE_REPO"
  # resolve to physical path for stable identity printing
  BASE_REPO=$(CDPATH='' cd "$BASE_REPO" && pwd -P)

  # gibson: env GIBSON (if pre-set and non-empty) wins only when profile omits it;
  # profile gibson= is authoritative when present.
  if [[ -n "$prof_gibson" ]]; then
    assert_safe_abs_path "gibson" "$prof_gibson"
    GIBSON=$(CDPATH='' cd "$prof_gibson" && pwd -P)
  elif [[ -n "${GIBSON}" ]]; then
    assert_safe_abs_path "GIBSON" "$GIBSON"
    GIBSON=$(CDPATH='' cd "$GIBSON" && pwd -P)
  else
    GIBSON="$DEFAULT_GIBSON"
  fi

  if [[ -n "$prof_fleet" ]]; then
    assert_safe_abs_path "fleet_dir" "$prof_fleet"
    FLEET_DIR="$prof_fleet"
  elif [[ -n "${FLEET_DIR}" ]]; then
    assert_safe_abs_path "FLEET_DIR" "$FLEET_DIR"
  else
    FLEET_DIR="${HOME}/Code/fleet"
  fi
  assert_safe_abs_path "fleet_dir" "$FLEET_DIR"

  if [[ -n "$prof_log" ]]; then
    assert_safe_abs_path "log_dir" "$prof_log"
    LOG_DIR="$prof_log"
  elif [[ -n "${LOG_DIR}" ]]; then
    assert_safe_abs_path "LOG_DIR" "$LOG_DIR"
  else
    LOG_DIR="${HOME}/.claude/fleet/logs"
  fi
  assert_safe_abs_path "log_dir" "$LOG_DIR"

  if [[ -n "$prof_runner" ]]; then
    RUNNER="$prof_runner"
  fi
  if [[ -n "$prof_budget" ]]; then
    ERROR_BUDGET="$prof_budget"
  fi
  if [[ -n "$prof_deadline" ]]; then
    DEADLINE_SECONDS="$prof_deadline"
  fi

  [[ "$ERROR_BUDGET" =~ ^[1-9][0-9]*$ ]] || die "error_budget must be a positive integer (got: $ERROR_BUDGET)"
  [[ "$DEADLINE_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "deadline_seconds must be a positive integer (got: $DEADLINE_SECONDS)"
  [[ -n "$RUNNER" ]] || die "runner is empty"

  [[ ${#LANE_IDS[@]} -ge 1 ]] || die "profile has no lane= records"

  # duplicate issue across lanes (hard collision on claim)
  local i j qi qj qi_list qj_list
  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    qi_list=$(printf '%s' "${LANE_QUEUES[$i]}" | tr ',' ' ')
    j=$((i + 1))
    while [[ $j -lt ${#LANE_IDS[@]} ]]; do
      qj_list=$(printf '%s' "${LANE_QUEUES[$j]}" | tr ',' ' ')
      # shellcheck disable=SC2086
      for qi in $qi_list; do
        # shellcheck disable=SC2086
        for qj in $qj_list; do
          [[ "$qi" == "$qj" ]] && die "issue #$qi appears in both lane ${LANE_IDS[$i]} and lane ${LANE_IDS[$j]}"
        done
      done
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  check_inter_lane_scope_overlap

  if [[ -z "$LOOP_SH" ]]; then
    LOOP_SH="$GIBSON/scripts/loop.sh"
  fi
}

# --- lane paths -------------------------------------------------------------

# NOT "wt-*". Gibson's release hat deletes per-issue worktrees after merge;
# a lane base named wt-* is indistinguishable and can be deleted mid-flight.
lane_dir()   { echo "$FLEET_DIR/lane-$1"; }
lane_log()   { echo "$LOG_DIR/$1.log"; }
lane_state() { echo "$(lane_dir "$1")/gibson/loop-state.md"; }
lane_pidfile() { echo "$LOG_DIR/$1.pid"; }

# Prefer pidfiles over pgrep -f: scanning the process table matches huge
# agent CLI argvs (and can hang or false-positive). Pidfile is written at
# launch and cleared when the process is gone.
#
# A live PID alone is not enough — OS PID reuse can put an unrelated process
# on the same number. Require the command line to still look like this lane's
# loop (--repo <lane-dir> + loop driver). Fail closed (treat as not ours) when
# the command line is unreadable or does not match.
lane_pid_alive() {
  local id="$1" pf pid d cmdline loop_base
  pf=$(lane_pidfile "$id")
  d=$(lane_dir "$id")
  [[ -f "$pf" ]] || return 1
  pid=$(tr -d '[:space:]' < "$pf" 2>/dev/null || true)
  [[ -n "$pid" && "$pid" =~ ^[1-9][0-9]*$ ]] || { rm -f "$pf"; return 1; }
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pf"
    return 1
  fi
  # macOS/BSD and Linux: command= or args= (no headers with -o name= form)
  cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
  if [[ -z "$cmdline" ]]; then
    cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
  fi
  if [[ -z "$cmdline" ]]; then
    # Cannot prove identity — refuse to treat as this lane.
    rm -f "$pf"
    return 1
  fi
  loop_base=$(basename "${LOOP_SH:-loop.sh}")
  # Must reference both the loop driver and this lane's worktree path.
  case "$cmdline" in
    *"$d"*) ;;
    *) rm -f "$pf"; return 1 ;;
  esac
  case "$cmdline" in
    *loop.sh*|*"$loop_base"*|*"$LOOP_SH"*) ;;
    *) rm -f "$pf"; return 1 ;;
  esac
  printf '%s\n' "$pid"
  return 0
}

# --- preflight (fail closed before any runner launch) -----------------------

GATED_LABELS="needs-mark decision blocked tier-c gibson-halt"

label_is_gated() {
  local lab="$1" g
  for g in $GATED_LABELS; do
    [[ "$lab" == "$g" ]] && return 0
  done
  return 1
}

# Parse labels from gh issue view --json labels output without requiring jq.
# Accepts either compact JSON or pretty-printed. Falls back to jq when present.
json_label_names() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '(.labels // []) | .[] | .name' 2>/dev/null || true
    return 0
  fi
  # minimal: pull "name":"..." occurrences inside labels array — best-effort
  printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

json_field() {
  local json="$1" field="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null || true
    return 0
  fi
  printf '%s' "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

check_issue_preflight() {
  local issue="$1" lane="$2"
  local out state labels lab

  if ! out=$("$GH_BIN" issue view "$issue" --repo "$EXPECTED_SLUG" --json state,labels 2>&1); then
    die "lane $lane: issue #$issue missing or unreadable via gh (repo $EXPECTED_SLUG): $out"
  fi

  state=$(json_field "$out" "state")
  # normalize
  state=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')
  [[ "$state" == "OPEN" ]] || die "lane $lane: issue #$issue is not open (state=$state)"

  labels=$(json_label_names "$out")
  while IFS= read -r lab || [[ -n "$lab" ]]; do
    [[ -n "$lab" ]] || continue
    if label_is_gated "$lab"; then
      die "lane $lane: issue #$issue carries gated label '$lab' (needs-mark|decision|blocked|tier-c|gibson-halt)"
    fi
    if [[ "$lab" == "agent-claimed" ]]; then
      die "lane $lane: issue #$issue already agent-claimed (claims conflict — release or reaper first)"
    fi
  done <<<"$labels"
}

check_pr_conflicts() {
  # Fail closed if an open PR head branch looks like it already owns this issue.
  local issue="$1" lane="$2"
  local out branch branches
  if ! out=$("$GH_BIN" pr list --repo "$EXPECTED_SLUG" --state open --json number,headRefName --limit 100 2>&1); then
    die "lane $lane: cannot list open PRs for claims/PR conflict check: $out"
  fi
  branches=""
  if command -v jq >/dev/null 2>&1; then
    branches=$(printf '%s' "$out" | jq -r '.[].headRefName' 2>/dev/null || true)
  else
    branches=$(printf '%s' "$out" | tr ',' '\n' | sed -n 's/.*"headRefName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  fi
  while IFS= read -r branch || [[ -n "$branch" ]]; do
    [[ -n "$branch" ]] || continue
    case "$branch" in
      feat/"$issue"-*|fix/"$issue"-*|feat/"$issue"|fix/"$issue")
        die "lane $lane: open PR branch '$branch' conflicts with issue #$issue"
        ;;
    esac
  done <<<"$branches"
}

assert_three_role_separation() {
  # Never allow the implementation runner to grade or release its own work.
  local r rev rel
  r=$(printf '%s' "$RUNNER" | tr '[:upper:]' '[:lower:]')
  rev=$(printf '%s' "${REVIEWER_CMD:-}" | tr '[:upper:]' '[:lower:]')
  rel=$(printf '%s' "${RELEASE_CMD:-}" | tr '[:upper:]' '[:lower:]')
  [[ -n "${REVIEWER_CMD:-}" ]] || die "REVIEWER_CMD is empty — cross-vendor review required (Law 5)"
  [[ -n "${RELEASE_CMD:-}" ]] || die "RELEASE_CMD is empty — third-identity release required (three-role split)"
  # If REVIEWER_CMD is just the same binary as RUNNER with no other vendor, refuse.
  case "$rev" in
    "$r"| "$r"\ *|"$r"-*)
      # allow if reviewer clearly different tool (codex/claude/hermes) even when runner substring appears in flags
      case "$rev" in
        *codex*|*claude*|*hermes*|*second-opinion*) ;;
        *) die "REVIEWER_CMD must not be the implementation runner grading its own work (RUNNER=$RUNNER REVIEWER_CMD=$REVIEWER_CMD)" ;;
      esac
      ;;
  esac
  case "$rel" in
    "$r"| "$r"\ *|"$r"-*)
      case "$rel" in
        *codex*|*claude*|*hermes*)
          # runner is grok and release is claude — ok; if release is same family as runner without third party:
          if [[ "$r" == "claude" ]] && [[ "$rel" == *claude* ]]; then
            die "RELEASE_CMD must be a third identity distinct from the builder (RUNNER=$RUNNER)"
          fi
          if [[ "$r" == "codex" ]] && [[ "$rel" == *codex* ]] && [[ "$rel" != *claude* ]]; then
            die "RELEASE_CMD must be a third identity distinct from the builder (RUNNER=$RUNNER)"
          fi
          if [[ "$r" == "grok" ]] && [[ "$rel" == *grok* ]] && [[ "$rel" != *claude* ]] && [[ "$rel" != *codex* ]]; then
            die "RELEASE_CMD must be a third identity distinct from the builder (RUNNER=$RUNNER)"
          fi
          ;;
        *) die "RELEASE_CMD must not collapse into the implementation runner (RUNNER=$RUNNER RELEASE_CMD=$RELEASE_CMD)" ;;
      esac
      ;;
  esac
}

preflight_for_start() {
  local i issue q

  [[ -f "$LOOP_SH" ]] || die "missing loop driver: $LOOP_SH"
  [[ -x "$LOOP_SH" || -f "$LOOP_SH" ]] || die "loop driver not usable: $LOOP_SH"
  command -v "$RUNNER" >/dev/null 2>&1 || die "runner '$RUNNER' not found on PATH"
  command -v "$GH_BIN" >/dev/null 2>&1 || die "gh binary '$GH_BIN' not found"

  assert_three_role_separation

  git -C "$BASE_REPO" rev-parse --git-dir >/dev/null 2>&1 || die "target is not a git repository: $BASE_REPO"

  local origin norm
  origin=$(git -C "$BASE_REPO" remote get-url origin 2>/dev/null || true)
  [[ -n "$origin" ]] || die "target has no origin remote"
  norm=$(origin_slug_from_url "$origin")
  [[ "$norm" == "$EXPECTED_SLUG" ]] || die "origin slug '$norm' does not match profile slug '$EXPECTED_SLUG' (origin=$origin)"

  local dirty
  dirty=$(git -C "$BASE_REPO" status --porcelain 2>/dev/null || true)
  [[ -z "$dirty" ]] || die "canonical checkout is dirty — refuse to create lane worktrees from a dirty tree"

  # scopes already checked at load; re-check here so --start always enforces
  check_inter_lane_scope_overlap

  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    q=$(printf '%s' "${LANE_QUEUES[$i]}" | tr ',' ' ')
    # shellcheck disable=SC2086
    for issue in $q; do
      check_issue_preflight "$issue" "${LANE_IDS[$i]}"
      check_pr_conflicts "$issue" "${LANE_IDS[$i]}"
    done
    i=$((i + 1))
  done

  info "preflight OK ($(( ${#LANE_IDS[@]} )) lane(s))"
}

# --- commands ---------------------------------------------------------------

do_halt() {
  local n=0 i id d
  print_identity
  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    id="${LANE_IDS[$i]}"
    d=$(lane_dir "$id")
    if [[ -d "$d" ]]; then
      mkdir -p "$d/gibson"
      touch "$d/gibson/HALT"
      n=$((n + 1))
    fi
    i=$((i + 1))
  done
  info "HALT written to $n lane(s) — they stop after the current hat"
}

do_status() {
  print_identity
  printf '%-12s %-14s %-6s %-8s %-11s %s\n' LANE QUEUE PID HAT HEALTH LAST
  local dead=0 i id queue d pid hat last health
  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    id="${LANE_IDS[$i]}"
    queue="${LANE_QUEUES[$i]}"
    d=$(lane_dir "$id")
    pid=$(lane_pid_alive "$id" || true)
    hat=$(awk -F': ' '$1=="hat"{print $2; exit}' "$(lane_state "$id")" 2>/dev/null || true)
    last=$(tail -1 "$(lane_log "$id")" 2>/dev/null | cut -c1-50 || true)

    if [[ ! -d "$d" ]]; then
      health="BASE-GONE"; dead=1
    elif [[ -n "$pid" ]]; then
      health="running"
    elif [[ -f "$d/gibson/HALT" ]]; then
      health="halted"
    else
      health="DEAD"; dead=1
    fi

    printf '%-12s %-14s %-6s %-8s %-11s %s\n' \
      "$id" "$queue" "${pid:-—}" "${hat:-—}" "$health" "${last:-—}"
    i=$((i + 1))
  done
  if [[ $dead -eq 1 ]]; then
    echo
    echo "One or more lanes are down. '$0 --profile $PROFILE_PATH --start' is idempotent —"
    echo "it recreates a missing base, leaves healthy lanes alone, and relaunches only what died."
  fi
}

seed_lane_state() {
  local id="$1" queue="$2" scope="$3" intent="$4" d issue
  d=$(lane_dir "$id")
  issue="${queue%%,*}"
  mkdir -p "$d/gibson"
  rm -f "$d/gibson/HALT"

  cat > "$d/.fleet-lane" <<EOF
This directory is a long-lived FLEET LANE BASE (lane: $id).
It is the loop driver's --repo. Deleting it kills the lane.
It is NOT the per-issue worktree that Gibson's release hat cleans up.
Do not run "git worktree remove" or rm -rf against this path.
EOF

  cat > "$(lane_state "$id")" <<EOF
# Gibson loop state
updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
issue: $issue
pr:
hat: builder
next_hat: builder
round: 0
parked: false
next_action: builder — claim issue #$issue and ship the first reviewable slice
notes: >
  FLEET LANE "$id" — parallel lane, worktree $d.
  Profile: $PROFILE_NAME ($PROFILE_PATH)
  Target: $BASE_REPO ($EXPECTED_SLUG)
  STAY IN THIS LANE. Your exclusive file scope is: $scope
  Other lanes are editing other paths in this same repo at the same time. Do not
  edit, rename, or reformat any file outside your scope — not even to fix an
  unrelated lint error. If your issue seems to need a file outside your scope,
  note it in the PR body and leave the file alone.
  Intent: $intent
  NEVER REMOVE THIS DIRECTORY ($d). It is your long-lived LANE BASE — the
  driver's --repo — not a disposable per-issue worktree. Gibson's release hat
  cleans up the worktree it created for an issue; that is NOT this path. If you
  delete this, your driver dies mid-flight and the lane stops for the night.
  Marker file: .fleet-lane sits at the root here. If you are about to run
  "git worktree remove" or rm -rf on a path containing .fleet-lane, do not.
  Create per-issue worktrees somewhere else and remove only those.
  YOUR ISSUE QUEUE, in order: $queue
  When the current issue is fully shipped, take the NEXT id from that queue and
  start it. Do not triage or invent your own next issue — every id outside your
  queue belongs to another lane, and picking one causes a collision. When the
  queue is empty, set parked: true and stop.
  Merge authority: follow the stage rule in $BASE_REPO/AGENTS.md, which is the
  single source of truth. Read it fresh each iteration — do not assume.
  Never merge anything touching secrets, env vars, schema, or labeled needs-mark.
EOF
  [[ -f "$d/gibson/journal.md" ]] || echo "# Gibson loop journal (lane $id)" > "$d/gibson/journal.md"
}

do_start() {
  print_identity
  # Complete preflight BEFORE any worktree mutation or runner launch.
  preflight_for_start

  mkdir -p "$FLEET_DIR" "$LOG_DIR"
  if [[ "$FLEET_SKIP_FETCH" == "1" ]]; then
    info "skip git fetch (FLEET_SKIP_FETCH=1)"
  else
    # Bound network so a wedged remote cannot hang fleet start forever.
    # Offline sensors set FLEET_SKIP_FETCH=1. Fail closed on failure/timeout —
    # do not launch lanes against a checkout that could not refresh origin.
    # Portable bound (macOS has no `timeout`): git http.lowSpeed* aborts a
    # stalled transfer; GIT_TERMINAL_PROMPT=0 blocks credential prompts.
    if ! GIT_TERMINAL_PROMPT=0 git -C "$BASE_REPO" \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 \
        -c transfer.fsckObjects=false \
        fetch origin --quiet 2>/dev/null; then
      die "git fetch origin failed or timed out (lowSpeedTime=15s) — refuse to launch; set FLEET_SKIP_FETCH=1 only for offline sensors"
    fi
  fi

  local i id queue scope intent d issue
  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    id="${LANE_IDS[$i]}"
    queue="${LANE_QUEUES[$i]}"
    scope="${LANE_SCOPES[$i]}"
    intent="${LANE_INTENTS[$i]}"
    issue="${queue%%,*}"
    d=$(lane_dir "$id")

    if [[ ! -d "$d" ]]; then
      info "worktree for lane $id (issue #$issue)"
      # Detached at origin/main (or origin/master): builder creates issue branch.
      # If a prior base was deleted out of band, prune the stale registration
      # so `worktree add` does not die with "missing but already registered".
      git -C "$BASE_REPO" worktree prune --expire now >/dev/null 2>&1 || true
      local ref=""
      if git -C "$BASE_REPO" rev-parse --verify --quiet origin/main >/dev/null; then
        ref="origin/main"
      elif git -C "$BASE_REPO" rev-parse --verify --quiet origin/master >/dev/null; then
        ref="origin/master"
      else
        die "cannot resolve origin/main or origin/master in $BASE_REPO"
      fi
      if ! git -C "$BASE_REPO" worktree add --detach "$d" "$ref" --quiet; then
        git -C "$BASE_REPO" worktree remove --force "$d" >/dev/null 2>&1 || true
        git -C "$BASE_REPO" worktree prune --expire now >/dev/null 2>&1 || true
        git -C "$BASE_REPO" worktree add --detach "$d" "$ref" --quiet \
          || die "cannot create lane worktree at $d from $ref"
      fi
    else
      info "reusing worktree $d"
    fi

    seed_lane_state "$id" "$queue" "$scope" "$intent"

    if pid=$(lane_pid_alive "$id"); then
      info "lane $id already running (pid $pid) — skipping launch"
      i=$((i + 1))
      continue
    fi

    info "launch lane $id → issue #$issue"
    # Export three-role cmds so loop.sh hats can shell out.
    if [[ "$FLEET_SYNC_LAUNCH" == "1" ]]; then
      # Deterministic offline path: no background jobs (sensors / CI).
      # Record a synthetic "ran" marker so status can see a completed sync launch
      # without leaving a live pid (loop already exited).
      env \
        REVIEWER_CMD="$REVIEWER_CMD" \
        RELEASE_CMD="$RELEASE_CMD" \
        "$LOOP_SH" \
        --runner "$RUNNER" \
        --repo "$d" \
        --repo-slug "$EXPECTED_SLUG" \
        --gibson "$GIBSON" \
        --error-budget "$ERROR_BUDGET" \
        >> "$(lane_log "$id")" 2>&1 || info "lane $id: loop exited non-zero (see $(lane_log "$id"))"
      rm -f "$(lane_pidfile "$id")"
    else
      nohup env \
        REVIEWER_CMD="$REVIEWER_CMD" \
        RELEASE_CMD="$RELEASE_CMD" \
        "$LOOP_SH" \
        --runner "$RUNNER" \
        --repo "$d" \
        --repo-slug "$EXPECTED_SLUG" \
        --gibson "$GIBSON" \
        --error-budget "$ERROR_BUDGET" \
        >> "$(lane_log "$id")" 2>&1 &
      echo $! > "$(lane_pidfile "$id")"
      # Stagger: avoid N runners racing the same git object store on boot.
      "$SLEEP_CMD" 3 2>/dev/null || true
    fi
    i=$((i + 1))
  done

  # Deadline watchdog: stop the fleet cleanly even if nobody is watching.
  if [[ "$FLEET_NO_WATCHDOG" == "1" ]]; then
    info "watchdog skipped (FLEET_NO_WATCHDOG=1)"
  else
    nohup bash -c "$SLEEP_CMD $DEADLINE_SECONDS; \"$0\" --profile \"$PROFILE_PATH\" --halt" \
      >> "$LOG_DIR/watchdog.log" 2>&1 &
    info "watchdog armed: HALT in $((DEADLINE_SECONDS / 3600))h (${DEADLINE_SECONDS}s)"
  fi
  info "fleet up. status: $0 --profile $PROFILE_PATH --status"
}

# --- argv -------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE_PATH="${2:-}"
      [[ -n "$PROFILE_PATH" ]] || usage_err "--profile requires a path"
      shift 2
      ;;
    --start)  CMD="--start"; shift ;;
    --halt)   CMD="--halt"; shift ;;
    --status) CMD="--status"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_err "unknown argument: $1" ;;
  esac
done

# FLEET_PROFILE env if --profile not given
if [[ -z "$PROFILE_PATH" && -n "${FLEET_PROFILE:-}" ]]; then
  PROFILE_PATH="$FLEET_PROFILE"
fi

[[ -n "$PROFILE_PATH" ]] || usage_err "profile required: set FLEET_PROFILE or pass --profile PATH"

load_profile "$PROFILE_PATH"

case "$CMD" in
  --start)  do_start ;;
  --halt)   do_halt ;;
  --status) do_status ;;
  *) usage_err "internal: bad cmd $CMD" ;;
esac
