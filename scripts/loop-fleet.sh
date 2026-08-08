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
#   FLEET_SKIP_FETCH=1   — skip network fetch; resolve default branch from local origin/*
#   FLEET_FETCH_TIMEOUT  — wall-clock seconds for git fetch AND ls-remote (default 30)
FLEET_SYNC_LAUNCH="${FLEET_SYNC_LAUNCH:-0}"
FLEET_NO_WATCHDOG="${FLEET_NO_WATCHDOG:-0}"
FLEET_SKIP_FETCH="${FLEET_SKIP_FETCH:-0}"
FLEET_FETCH_TIMEOUT="${FLEET_FETCH_TIMEOUT:-30}"

# Fleet WIP doctrine: 1–3 concurrent lanes (docs/25, DECISIONS: ≤ 3 lanes).
FLEET_MAX_LANES=3

# Absolute path to this driver (watchdog argv must not depend on $0 cwd).
DRIVER_SELF="$SCRIPT_DIR/$(basename "$0")"

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
  info "fleet_dir=$FLEET_DIR"
  info "log_dir=$LOG_DIR"
}

# Portable fingerprint for default fleet/log namespaces.
# Pure bash (no python/perl/jq/cksum/awk) so minimal-PATH fail-closed paths
# still resolve defaults. Same profile name with different path, physical repo,
# or slug must not share worktrees, logs, pidfiles, or watchdogs.
profile_default_ns() {
  local data h=5381 i=0 n ord
  # Identity lines — order and labels are part of the contract.
  data="profile_path=${PROFILE_PATH}"$'\n'"repo=${BASE_REPO}"$'\n'"slug=${EXPECTED_SLUG}"$'\n'"name=${PROFILE_NAME}"
  n=${#data}
  while [[ $i -lt $n ]]; do
    # bash 3.2: single-byte ordinal via printf '%d' "'char"
    ord=$(printf '%d' "'${data:$i:1}")
    # djb2 mod a large prime → stable decimal token
    h=$(( (h * 33 + ord) % 1000000007 ))
    i=$((i + 1))
  done
  printf '%s\n' "$h"
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
  # Tokenize with pathname expansion disabled so declared tokens like docs/**
  # stay literal even when matching paths exist in the invocation cwd.
  # Subshell isolates set -f so glob state is restored on every exit path.
  local list_a="$1" list_b="$2"
  (
    set -f
    # shellcheck disable=SC2086
    for ta in $list_a; do
      # shellcheck disable=SC2086
      for tb in $list_b; do
        if scope_tokens_overlap "$ta" "$tb"; then
          printf '%s ↔ %s\n' "$ta" "$tb"
          exit 0
        fi
      done
    done
    exit 1
  )
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
  # Exactly 4 or 5 pipe-separated fields. A sixth field fails closed.
  local raw="$1"
  local id queue scope intent runner_r rest
  # Do not eval. Split on | with read.
  IFS='|' read -r id queue scope intent rest <<<"$raw" || true
  # rest is the optional 5th field only — any further | is a sixth+ field.
  if [[ "$rest" == *"|"* ]]; then
    die "lane line has more than 5 fields (v1 allows id|queue|scope|intent[|runner_reserved]): $raw"
  fi
  runner_r="$rest"

  id=$(printf '%s' "$id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  queue=$(printf '%s' "$queue" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  scope=$(printf '%s' "$scope" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  intent=$(printf '%s' "$intent" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  runner_r=$(printf '%s' "$runner_r" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  validate_lane_id "$id"
  [[ -n "$queue" ]] || die "lane $id: empty issue queue"
  [[ -n "$scope" ]] || die "lane $id: empty exclusive scope"
  [[ -n "$intent" ]] || die "lane $id: empty intent"

  # Optional 5th field: reserved for #141 routing. Accept as inert declarative
  # data only — no shell syntax / control characters (never eval'd / sourced).
  if [[ -n "$runner_r" ]]; then
    case "$runner_r" in
      *[\`\$\;\|\&\<\>\(\)\{\}\[\]\'\"\\]*|*$'\n'*|*$'\r'*|*$'\t'*)
        die "lane $id: reserved runner field must be safe inert data (no shell syntax/control chars): $runner_r"
        ;;
    esac
    # Printable-ish token only (letters, digits, common path/name punctuation).
    if [[ ! "$runner_r" =~ ^[A-Za-z0-9._/@+=:,-]+$ ]]; then
      die "lane $id: reserved runner field has disallowed characters: $runner_r"
    fi
  fi

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

  # Normalize profile path to a physical absolute path for stable identity.
  local prof_dir prof_base
  prof_dir=$(CDPATH='' cd "$(dirname "$path")" && pwd -P)
  prof_base=$(basename "$path")
  PROFILE_PATH="${prof_dir}/${prof_base}"
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
  local seen_scalar_keys=""
  # Read without sourcing. Strip CR for Windows-edited profiles.
  # Always read via the original path argument (same inode as PROFILE_PATH).
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
      version|name|repo|slug|gibson|fleet_dir|log_dir|runner|error_budget|deadline_seconds)
        # Scalars must appear at most once — last-wins is ambiguous and fails closed.
        case ",${seen_scalar_keys}," in
          *",$key,"*) die "profile line $lineno: duplicate scalar key '$key' (each scalar may appear only once)" ;;
        esac
        seen_scalar_keys="${seen_scalar_keys:+$seen_scalar_keys,}$key"
        case "$key" in
          version) PROFILE_VERSION="$val" ;;
          name) PROFILE_NAME="$val" ;;
          repo) BASE_REPO="$val" ;;
          slug) EXPECTED_SLUG="$val" ;;
          gibson) prof_gibson="$val" ;;
          fleet_dir) prof_fleet="$val" ;;
          log_dir) prof_log="$val" ;;
          runner) prof_runner="$val" ;;
          error_budget) prof_budget="$val" ;;
          deadline_seconds) prof_deadline="$val" ;;
        esac
        ;;
      lane)
        # Repeated lane= records are required (1–3); uniqueness is enforced per id/issue.
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

  # fleet/log defaults are namespaced by profile name AND a portable fingerprint
  # of profile path + physical repo + slug so same-name different targets cannot
  # collide on lane worktrees, pidfiles, logs, or the watchdog.
  # Explicit profile fleet_dir=/log_dir= and env FLEET_DIR/LOG_DIR still win.
  local default_ns
  default_ns=$(profile_default_ns)
  if [[ -n "$prof_fleet" ]]; then
    assert_safe_abs_path "fleet_dir" "$prof_fleet"
    FLEET_DIR="$prof_fleet"
  elif [[ -n "${FLEET_DIR}" ]]; then
    assert_safe_abs_path "FLEET_DIR" "$FLEET_DIR"
  else
    FLEET_DIR="${HOME}/Code/fleet/${PROFILE_NAME}-${default_ns}"
  fi
  assert_safe_abs_path "fleet_dir" "$FLEET_DIR"

  if [[ -n "$prof_log" ]]; then
    assert_safe_abs_path "log_dir" "$prof_log"
    LOG_DIR="$prof_log"
  elif [[ -n "${LOG_DIR}" ]]; then
    assert_safe_abs_path "LOG_DIR" "$LOG_DIR"
  else
    LOG_DIR="${HOME}/.claude/fleet/logs/${PROFILE_NAME}-${default_ns}"
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
  # Fleet WIP doctrine: 1–3 lanes only. Four or more fails closed before launch.
  if [[ ${#LANE_IDS[@]} -gt $FLEET_MAX_LANES ]]; then
    die "profile has ${#LANE_IDS[@]} lanes; fleet WIP doctrine allows 1-${FLEET_MAX_LANES} lanes only (zero launches)"
  fi

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
watchdog_pidfile() { echo "$LOG_DIR/watchdog.pid"; }
fleet_identity_file() { echo "$FLEET_DIR/.fleet-identity"; }
log_identity_file()   { echo "$LOG_DIR/.fleet-identity"; }
lane_identity_file()  { echo "$(lane_dir "$1")/.fleet-identity"; }

# Machine-readable identity for fail-closed reuse of fleet/log/lane state.
# Human-readable .fleet-lane remains separate (warning text only).
write_identity_file() {
  local path="$1" lane="${2:-}"
  mkdir -p "$(dirname "$path")"
  {
    printf 'name=%s\n' "$PROFILE_NAME"
    printf 'profile_path=%s\n' "$PROFILE_PATH"
    printf 'repo=%s\n' "$BASE_REPO"
    printf 'slug=%s\n' "$EXPECTED_SLUG"
    if [[ -n "$lane" ]]; then
      printf 'lane=%s\n' "$lane"
    fi
  } > "$path"
}

# Validate a persisted identity marker against the currently loaded profile.
# expect_lane: empty for fleet/log markers; lane id for per-lane markers.
validate_identity_file() {
  local path="$1" context="$2" expect_lane="${3:-}"
  local got_name="" got_path="" got_repo="" got_slug="" got_lane="" line key val

  [[ -f "$path" ]] || die "$context: missing identity marker at $path — refuse to reuse state"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    case "$line" in
      ''|\#*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      name) got_name="$val" ;;
      profile_path) got_path="$val" ;;
      repo) got_repo="$val" ;;
      slug) got_slug="$val" ;;
      lane) got_lane="$val" ;;
    esac
  done < "$path"

  [[ "$got_name" == "$PROFILE_NAME" ]] \
    || die "$context: identity name mismatch (marker='$got_name' profile='$PROFILE_NAME') at $path"
  [[ "$got_path" == "$PROFILE_PATH" ]] \
    || die "$context: identity profile_path mismatch (marker='$got_path' profile='$PROFILE_PATH') at $path"
  [[ "$got_repo" == "$BASE_REPO" ]] \
    || die "$context: identity repo mismatch (marker='$got_repo' profile='$BASE_REPO') at $path"
  [[ "$got_slug" == "$EXPECTED_SLUG" ]] \
    || die "$context: identity slug mismatch (marker='$got_slug' profile='$EXPECTED_SLUG') at $path"
  if [[ -n "$expect_lane" ]]; then
    [[ "$got_lane" == "$expect_lane" ]] \
      || die "$context: identity lane mismatch (marker='$got_lane' expected='$expect_lane') at $path"
  fi
}

fleet_dir_has_lanes() {
  local d
  [[ -d "$FLEET_DIR" ]] || return 1
  for d in "$FLEET_DIR"/lane-*; do
    [[ -e "$d" ]] && return 0
  done
  return 1
}

log_dir_has_state() {
  local f
  [[ -d "$LOG_DIR" ]] || return 1
  for f in "$LOG_DIR"/*.pid "$LOG_DIR"/*.log "$LOG_DIR"/watchdog.pid; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

# Fail closed when reusing existing fleet/log state that is missing or foreign.
assert_profile_identity_for_reuse() {
  local fleet_id_path log_id_path
  fleet_id_path=$(fleet_identity_file)
  log_id_path=$(log_identity_file)

  if [[ -f "$fleet_id_path" ]]; then
    validate_identity_file "$fleet_id_path" "fleet_dir"
  elif fleet_dir_has_lanes; then
    die "fleet_dir $FLEET_DIR has lane-* state without .fleet-identity marker — refuse to reuse"
  fi

  if [[ -f "$log_id_path" ]]; then
    validate_identity_file "$log_id_path" "log_dir"
  elif log_dir_has_state; then
    die "log_dir $LOG_DIR has pid/log state without .fleet-identity marker — refuse to reuse"
  fi
}

# Create fleet/log dirs and persist identity markers (start path only).
ensure_profile_runtime_dirs() {
  mkdir -p "$FLEET_DIR" "$LOG_DIR"
  assert_profile_identity_for_reuse
  # Write markers when absent (first use of this namespace).
  [[ -f "$(fleet_identity_file)" ]] || write_identity_file "$(fleet_identity_file)"
  [[ -f "$(log_identity_file)" ]] || write_identity_file "$(log_identity_file)"
}

assert_lane_identity() {
  local id="$1" d path
  d=$(lane_dir "$id")
  path=$(lane_identity_file "$id")
  [[ -d "$d" ]] || return 0
  if [[ -f "$path" ]]; then
    validate_identity_file "$path" "lane $id" "$id"
  else
    # Legacy / foreign lane base without a marker — fail closed on reuse.
    die "lane $id: worktree $d has no .fleet-identity marker — refuse to reuse"
  fi
}

write_lane_identity() {
  local id="$1"
  write_identity_file "$(lane_identity_file "$id")" "$id"
}

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

# Watchdog identity: live PID + command line still references this driver and
# this profile path. Unrelated reused PIDs are not treated as our watchdog.
watchdog_pid_alive() {
  local pf pid cmdline driver_base
  pf=$(watchdog_pidfile)
  [[ -f "$pf" ]] || return 1
  pid=$(tr -d '[:space:]' < "$pf" 2>/dev/null || true)
  [[ -n "$pid" && "$pid" =~ ^[1-9][0-9]*$ ]] || { rm -f "$pf"; return 1; }
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pf"
    return 1
  fi
  cmdline=$(ps -p "$pid" -o command= 2>/dev/null || true)
  if [[ -z "$cmdline" ]]; then
    cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
  fi
  if [[ -z "$cmdline" ]]; then
    rm -f "$pf"
    return 1
  fi
  driver_base=$(basename "$DRIVER_SELF")
  case "$cmdline" in
    *"$DRIVER_SELF"*|*"$driver_base"*) ;;
    *) rm -f "$pf"; return 1 ;;
  esac
  case "$cmdline" in
    *"$PROFILE_PATH"*) ;;
    *) rm -f "$pf"; return 1 ;;
  esac
  printf '%s\n' "$pid"
  return 0
}

# Arm deadline watchdog once per profile/log directory. Healthy re-start keeps
# the original PID and deadline; only a stale/unrelated pidfile is replaced.
ensure_watchdog() {
  local wd_pid wd_pf
  if [[ "$FLEET_NO_WATCHDOG" == "1" ]]; then
    info "watchdog skipped (FLEET_NO_WATCHDOG=1)"
    return 0
  fi
  if wd_pid=$(watchdog_pid_alive); then
    info "watchdog already running (pid $wd_pid) — leaving deadline untouched"
    return 0
  fi
  wd_pf=$(watchdog_pidfile)
  # Fixed shell source + positional argv only — never interpolate profile path
  # or sleep command into executable shell source (injection surface).
  # Pidfile is cleaned when the sleep completes (before --halt) where practical.
  nohup bash -c '
    sleep_bin=$1
    secs=$2
    driver=$3
    profile=$4
    pidfile=$5
    "$sleep_bin" "$secs"
    rm -f "$pidfile"
    exec "$driver" --profile "$profile" --halt
  ' bash "$SLEEP_CMD" "$DEADLINE_SECONDS" "$DRIVER_SELF" "$PROFILE_PATH" "$wd_pf" \
    >> "$LOG_DIR/watchdog.log" 2>&1 &
  echo $! > "$wd_pf"
  info "watchdog armed: HALT in $((DEADLINE_SECONDS / 3600))h (${DEADLINE_SECONDS}s) pid $!"
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

# Read a column-zero loop-state field with the same grammar as
# scripts/loop.sh read_field / scripts/validate-loop-state.sh:
# after the first colon, exactly one optional ASCII space is stripped.
# Accepts both `issue: 123` and `issue:123`. Empty value is success with empty stdout.
lane_state_field() {
  local id="$1" key="$2" sf val
  sf=$(lane_state "$id")
  [[ -f "$sf" ]] || return 1
  # shellcheck disable=SC2016
  val=$(awk -v k="$key" '
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
      line = $0
      key = line
      sub(/:.*$/, "", key)
      if (key != k) next
      v = line
      sub(/^[^:]*:/, "", v)
      if (v ~ /^ /) v = substr(v, 2)
      print v
      exit
    }
  ' "$sf" 2>/dev/null || true)
  printf '%s\n' "$val"
  return 0
}

# Read the current issue id from a lane's loop-state (empty if unreadable).
lane_state_issue() {
  local id="$1" val
  val=$(lane_state_field "$id" "issue") || return 1
  # Issue ids are digits only; strip incidental CR/space that writers should not emit.
  val=$(printf '%s' "$val" | tr -d '[:space:]')
  [[ -n "$val" ]] || return 1
  printf '%s\n' "$val"
  return 0
}

lane_state_pr() {
  local id="$1" val
  val=$(lane_state_field "$id" "pr") || return 1
  val=$(printf '%s' "$val" | tr -d '[:space:]')
  printf '%s\n' "$val"
  return 0
}

lane_state_handoff() {
  local id="$1" val
  val=$(lane_state_field "$id" "handoff") || return 1
  # Branch names: trim only trailing CR; keep internal characters.
  val=$(printf '%s' "$val" | tr -d '\r')
  # Strip a single trailing newline already removed by command sub; trim ends.
  val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf '%s\n' "$val"
  return 0
}

# True when positive issue id appears in a comma-separated lane queue.
issue_in_queue() {
  local issue="$1" queue="$2" qitem queue_work
  queue_work=$(printf '%s' "$queue" | tr ',' ' ')
  # shellcheck disable=SC2086
  for qitem in $queue_work; do
    qitem=$(printf '%s' "$qitem" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ "$qitem" == "$issue" ]] && return 0
  done
  return 1
}

# True when a head branch name looks like it owns the given issue number.
# Intentionally supports feat/<issue>[-slug] and fix/<issue>[-slug] only.
branch_matches_issue() {
  local branch="$1" issue="$2"
  case "$branch" in
    feat/"$issue"-*|fix/"$issue"-*|feat/"$issue"|fix/"$issue") return 0 ;;
  esac
  return 1
}

# Bound for open-PR listing. Hitting this count is treated as truncation risk
# (more pages may exist) and fails closed so conflicts cannot hide past the page.
OPEN_PR_LIST_LIMIT=1000

# Expected claim id for a bound branch: issue-<issue>-<slug> when branch is
# feat|fix/<issue>-<slug>. Branches without a non-empty slug fail closed.
claim_id_for_branch() {
  local branch="$1" issue="$2" rest slug
  case "$branch" in
    feat/"$issue"-*) rest=${branch#feat/"$issue"-} ;;
    fix/"$issue"-*)  rest=${branch#fix/"$issue"-} ;;
    *) return 1 ;;
  esac
  [[ -n "$rest" ]] || return 1
  # Slug: same conservative charset as claim.sh branch/claim ids.
  [[ "$rest" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  # No extra path segments.
  case "$rest" in
    */*) return 1 ;;
  esac
  slug="$rest"
  printf 'issue-%s-%s\n' "$issue" "$slug"
  return 0
}

# Conservative validation for PR head refs received through formatter output.
# Every fleet-owned branch fits this subset; unusual or malformed refs fail
# closed rather than entering ownership matching as attacker-controlled text.
is_valid_pr_head_ref() {
  local head="$1"
  [[ "$head" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
  case "$head" in
    /*|*/|*..*|*.lock|*//*) return 1 ;;
  esac
  return 0
}

# Validate machine-readable active-work claim lines in a PR body for own resumption.
# Requires exactly one column-zero line:
#   - Active-work claim: <exact-claim-id>
# The remainder after the colon must be surrounding-whitespace + exactly the
# expected claim id (no trailing notes/explanatory text).
assert_pr_active_work_claim() {
  local issue="$1" lane="$2" pr_num="$3" head="$4" body="$5"
  local expected line token count=0 got_id

  expected=$(claim_id_for_branch "$head" "$issue") \
    || die "lane $lane: state-bound PR #$pr_num head '$head' is not feat|fix/${issue}-<slug> — cannot bind active-work claim"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    case "$line" in
      '- Active-work claim:'*)
        count=$((count + 1))
        token=${line#- Active-work claim:}
        # Surrounding whitespace only — any trailing text is a mismatch.
        token=$(printf '%s' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        got_id="$token"
        ;;
    esac
  done <<<"$body"

  if [[ $count -eq 0 ]]; then
    die "lane $lane: state-bound PR #$pr_num body has no '- Active-work claim: …' line for issue #$issue — refuse to resume"
  fi
  if [[ $count -gt 1 ]]; then
    die "lane $lane: state-bound PR #$pr_num body has $count '- Active-work claim:' lines (exactly one required) — refuse to resume"
  fi
  if [[ -z "$got_id" ]]; then
    die "lane $lane: state-bound PR #$pr_num active-work claim line is empty/malformed — refuse to resume"
  fi
  if [[ ! "$got_id" =~ ^issue-[1-9][0-9]*-[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    die "lane $lane: state-bound PR #$pr_num active-work claim '$got_id' is malformed (want issue-<issue>-<slug>) — refuse to resume"
  fi
  case "$got_id" in
    issue-"$issue"-*) ;;
    *)
      die "lane $lane: state-bound PR #$pr_num active-work claim '$got_id' is for a foreign issue (want issue-$issue-*) — refuse to resume"
      ;;
  esac
  if [[ "$got_id" != "$expected" ]]; then
    die "lane $lane: state-bound PR #$pr_num active-work claim '$got_id' does not match head '$head' (expected '$expected') — refuse foreign slug"
  fi
}

# Validate unique "number<TAB>headRefName" rows from gh's built-in formatter.
# Fails closed on bad shape, empty fields, duplicates, or truncation risk.
_finalize_pr_meta_lines() {
  local raw="$1"
  local line num head
  local seen_nums="" seen_heads=""
  local out_lines="" count=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    # Exactly one TAB: number, head. Extra tabs (or none) fail closed.
    case "$line" in
      *$'\t'*$'\t'*)
        die "open PR list row has extra TAB fields (want number\\thead only): $line"
        ;;
      *$'\t'*) ;;
      *)
        die "open PR list row missing TAB (want number\\thead): $line"
        ;;
    esac
    num=${line%%$'\t'*}
    head=${line#*$'\t'}
    [[ "$num" =~ ^[1-9][0-9]*$ ]] || die "open PR list has invalid number '$num'"
    is_valid_pr_head_ref "$head" \
      || die "open PR list has empty/invalid headRefName for #$num (got: '$head')"
    case ",$seen_nums," in
      *",$num,"*) die "open PR list has duplicate PR number #$num — refuse ambiguous inventory" ;;
    esac
    case ",$seen_heads," in
      *",$head,"*) die "open PR list has duplicate/conflicting headRefName '$head' — refuse ambiguous inventory" ;;
    esac
    seen_nums="${seen_nums:+$seen_nums,}$num"
    seen_heads="${seen_heads:+$seen_heads,}$head"
    count=$((count + 1))
    if [[ -n "$out_lines" ]]; then
      out_lines="${out_lines}"$'\n'"${num}"$'\t'"${head}"
    else
      out_lines="${num}"$'\t'"${head}"
    fi
  done <<<"$raw"

  if [[ $count -ge $OPEN_PR_LIST_LIMIT ]]; then
    die "open PR list returned $count entries (limit $OPEN_PR_LIST_LIMIT) — truncation risk; refuse to hide conflicts"
  fi
  if [[ -n "$out_lines" ]]; then
    printf '%s\n' "$out_lines"
  fi
}

# List open PRs as "number<TAB>headRefName" lines (metadata only — never bodies).
# Uses gh's built-in --json + --template formatter (no external jq/python/perl).
# Fail closed on: gh error, malformed formatter output, missing/invalid fields,
# duplicate/conflicting records, truncation risk. Empty output is zero-pair success.
list_open_pr_pairs() {
  local out

  # gh --template is built into the CLI (Go templates); it does not require the
  # external jq binary. Only number + headRefName are fetched — never body.
  if ! out=$("$GH_BIN" pr list --repo "$EXPECTED_SLUG" --state open \
      --json number,headRefName --limit "$OPEN_PR_LIST_LIMIT" \
      --template '{{range .}}{{printf "%v\t%s\n" .number .headRefName}}{{end}}' 2>&1); then
    die "cannot list open PRs for claims/PR conflict check: $out"
  fi

  _finalize_pr_meta_lines "$out"
}

# Fetch a single candidate PR body, then immediately re-verify its
# number/head/OPEN state before trusting that body. Closes list/view/body races
# and metadata mismatches.
# Prints the raw PR body on success.
fetch_bound_pr_body() {
  local pr_num="$1" expect_head="$2" lane="$3" issue="$4"
  local meta body got_num got_head got_state rest

  [[ "$pr_num" =~ ^[1-9][0-9]*$ ]] \
    || die "lane $lane: bound PR number '$pr_num' is not a positive integer"
  [[ -n "$expect_head" ]] \
    || die "lane $lane: bound PR #$pr_num has empty expected head"

  # Fetch only the state-bound candidate body. It remains untrusted until the
  # metadata call immediately below confirms that the same PR is still open on
  # the expected head.
  if ! body=$("$GH_BIN" pr view "$pr_num" --repo "$EXPECTED_SLUG" \
      --json body --jq '.body // ""' 2>&1); then
    die "lane $lane: cannot fetch body of state-bound PR #$pr_num for issue #$issue: $body"
  fi

  # Immediate metadata re-verify via gh built-in formatter (no external jq).
  if ! meta=$("$GH_BIN" pr view "$pr_num" --repo "$EXPECTED_SLUG" \
      --json number,headRefName,state \
      --template '{{.number}}{{"\t"}}{{.headRefName}}{{"\t"}}{{.state}}{{"\n"}}' 2>&1); then
    die "lane $lane: cannot view state-bound PR #$pr_num for issue #$issue (re-verify failed): $meta"
  fi
  meta=${meta%$'\n'}
  meta=${meta%$'\r'}
  # Exactly number TAB head TAB state.
  case "$meta" in
    *$'\t'*$'\t'*$'\t'*)
      die "lane $lane: PR #$pr_num re-verify metadata has extra TAB fields: $meta"
      ;;
    *$'\t'*$'\t'*) ;;
    *)
      die "lane $lane: PR #$pr_num re-verify metadata is malformed (want number\\thead\\tstate): $meta"
      ;;
  esac
  got_num=${meta%%$'\t'*}
  rest=${meta#*$'\t'}
  got_head=${rest%%$'\t'*}
  got_state=${rest#*$'\t'}
  got_state=$(printf '%s' "$got_state" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')

  [[ "$got_num" =~ ^[1-9][0-9]*$ ]] \
    || die "lane $lane: PR #$pr_num re-verify returned invalid number '$got_num'"
  [[ "$got_num" == "$pr_num" ]] \
    || die "lane $lane: PR re-verify number mismatch (list/bound #$pr_num view #$got_num) — refuse list/view race"
  [[ -n "$got_head" ]] \
    || die "lane $lane: PR #$pr_num re-verify returned empty headRefName"
  [[ "$got_head" == "$expect_head" ]] \
    || die "lane $lane: PR #$pr_num re-verify head mismatch (list/bound '$expect_head' view '$got_head') — refuse list/view race"
  [[ "$got_state" == "OPEN" ]] \
    || die "lane $lane: state-bound PR #$pr_num is not OPEN on re-verify (state=$got_state) — refuse closed-state race"
  printf '%s' "$body"
}

# mode:
#   strict — unstarted / future work: OPEN, no gated, no agent-claimed
#   own    — lane's recorded current issue: OPEN, no gated; agent-claimed OK
#            (ownership of claim/PR is enforced separately via state binding)
#   prior  — queue items before recorded issue: CLOSED is OK (state advanced);
#            OPEN fails closed (no skip/park policy is recorded yet)
check_issue_preflight() {
  local issue="$1" lane="$2" mode="${3:-strict}"
  local out state labels lab

  if ! out=$("$GH_BIN" issue view "$issue" --repo "$EXPECTED_SLUG" --json state,labels 2>&1); then
    die "lane $lane: issue #$issue missing or unreadable via gh (repo $EXPECTED_SLUG): $out"
  fi

  state=$(json_field "$out" "state")
  # normalize
  state=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')

  if [[ "$mode" == "prior" ]]; then
    if [[ "$state" == "CLOSED" ]]; then
      # Closed prior queue item after the lane advanced past it — not a conflict.
      return 0
    fi
    # No explicit skip/park policy exists yet — fail closed on every OPEN prior.
    die "lane $lane: prior queue item #$issue is still OPEN (state=$state) — refuse to advance past unfinished work (no skip/park policy recorded)"
  fi

  [[ "$state" == "OPEN" ]] || die "lane $lane: issue #$issue is not open (state=$state)"

  labels=$(json_label_names "$out")
  while IFS= read -r lab || [[ -n "$lab" ]]; do
    [[ -n "$lab" ]] || continue
    if label_is_gated "$lab"; then
      die "lane $lane: issue #$issue carries gated label '$lab' (needs-mark|decision|blocked|tier-c|gibson-halt)"
    fi
    if [[ "$lab" == "agent-claimed" ]]; then
      if [[ "$mode" == "own" ]]; then
        # Resumable lane may carry agent-claimed only when state-bound (checked next).
        continue
      fi
      die "lane $lane: issue #$issue already agent-claimed (claims conflict — release or reaper first)"
    fi
  done <<<"$labels"
}

check_pr_conflicts() {
  # Fail closed if an open PR head branch looks like it already owns this issue.
  local issue="$1" lane="$2"
  local pairs num head
  pairs=$(list_open_pr_pairs) || return 1
  while IFS="$(printf '\t')" read -r num head || [[ -n "${num:-}" ]]; do
    [[ -n "${num:-}" ]] || continue
    if branch_matches_issue "$head" "$issue"; then
      die "lane $lane: open PR #$num branch '$head' conflicts with issue #$issue"
    fi
  done <<<"$pairs"
}

# Bind dead-lane "own" resumption to recorded pr: and/or handoff: state.
# Matches candidate open PR number/head from metadata list, fetches only that
# single PR body, then immediately re-verifies number/head/OPEN before reading
# the body for the machine-readable active-work claim. A claimed issue with no matching
# state-bound PR (or claim) fails closed.
check_own_resumption() {
  local issue="$1" lane="$2"
  local out labels lab claimed=0
  local bound_pr bound_handoff pairs num head body_raw
  local matched=0 issue_pr_seen=0
  local match_num="" match_head=""

  if ! out=$("$GH_BIN" issue view "$issue" --repo "$EXPECTED_SLUG" --json state,labels 2>&1); then
    die "lane $lane: issue #$issue missing or unreadable via gh (repo $EXPECTED_SLUG): $out"
  fi
  labels=$(json_label_names "$out")
  while IFS= read -r lab || [[ -n "$lab" ]]; do
    [[ -n "$lab" ]] || continue
    [[ "$lab" == "agent-claimed" ]] && claimed=1
  done <<<"$labels"

  bound_pr=$(lane_state_pr "$lane" 2>/dev/null || true)
  bound_handoff=$(lane_state_handoff "$lane" 2>/dev/null || true)
  bound_pr=$(printf '%s' "${bound_pr:-}" | tr -d '[:space:]')
  bound_handoff=$(printf '%s' "${bound_handoff:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [[ $claimed -eq 1 ]]; then
    if [[ -z "$bound_pr" && -z "$bound_handoff" ]]; then
      die "lane $lane: issue #$issue is agent-claimed but loop-state has no pr: or handoff: binding — refuse to resume unbound/foreign claim"
    fi
    if [[ -n "$bound_pr" && ! "$bound_pr" =~ ^[1-9][0-9]*$ ]]; then
      die "lane $lane: loop-state pr: field is not a positive PR number (got: '$bound_pr')"
    fi
  fi

  pairs=$(list_open_pr_pairs) || return 1
  while IFS="$(printf '\t')" read -r num head || [[ -n "${num:-}" ]]; do
    [[ -n "${num:-}" ]] || continue
    if ! branch_matches_issue "$head" "$issue"; then
      continue
    fi
    issue_pr_seen=1
    # State-bound match: PR number and/or handoff branch.
    if [[ -n "$bound_pr" && "$num" == "$bound_pr" ]]; then
      if [[ -n "$bound_handoff" && "$head" != "$bound_handoff" ]]; then
        die "lane $lane: state-bound pr:#$bound_pr head '$head' does not match handoff:'$bound_handoff' for issue #$issue"
      fi
      matched=1
      match_num="$num"
      match_head="$head"
      continue
    fi
    if [[ -z "$bound_pr" && -n "$bound_handoff" && "$head" == "$bound_handoff" ]]; then
      matched=1
      match_num="$num"
      match_head="$head"
      continue
    fi
    # Open PR for this issue that is not the lane's recorded ownership.
    die "lane $lane: open PR #$num branch '$head' for issue #$issue is not bound to loop-state pr:'${bound_pr:-}' handoff:'${bound_handoff:-}' — refuse foreign/mismatched ownership"
  done <<<"$pairs"

  if [[ $claimed -eq 1 ]]; then
    if [[ -n "$bound_pr" && $matched -eq 0 ]]; then
      die "lane $lane: state-bound pr:#$bound_pr not found open with a matching head for issue #$issue — refuse to resume"
    fi
    if [[ -z "$bound_pr" && -n "$bound_handoff" && $matched -eq 0 ]]; then
      die "lane $lane: state-bound handoff:'$bound_handoff' has no matching open PR head for issue #$issue — refuse to resume"
    fi
  elif [[ $issue_pr_seen -eq 1 && $matched -eq 0 ]]; then
    # Unclaimed recorded issue but someone already has an open PR — conflict.
    die "lane $lane: open PR exists for issue #$issue without a matching state-bound pr:/handoff: — refuse to resume"
  fi

  # State-bound own resumption: fetch only the single candidate body, re-verify
  # its metadata immediately, then require exactly one machine-readable claim.
  if [[ $matched -eq 1 ]]; then
    body_raw=$(fetch_bound_pr_body "$match_num" "$match_head" "$lane" "$issue") \
      || return 1
    assert_pr_active_work_claim "$issue" "$lane" "$match_num" "$match_head" "$body_raw"
  fi
}

# Validate recorded issue belongs to the configured queue (shared by healthy + dead paths).
assert_recorded_issue_in_queue() {
  local lane="$1" queue="$2" current
  current=$(lane_state_issue "$lane" || true)
  if [[ -z "$current" || ! "$current" =~ ^[1-9][0-9]*$ ]]; then
    die "lane $lane: ambiguous loop-state issue field (got: '${current:-}') — fail closed"
  fi
  if ! issue_in_queue "$current" "$queue"; then
    die "lane $lane: recorded issue #$current is not in configured queue ($queue) — foreign ownership, refuse to resume"
  fi
  printf '%s\n' "$current"
}

# Lane-state-aware queue preflight for one lane. Per-lane identity is validated
# BEFORE any pidfile read/mutation (lane_pid_alive may delete stale pidfiles).
# Healthy lanes require a valid loop-state and a positive recorded issue that
# is in the configured queue. Dead resumable lanes may own claim/PR for the
# recorded issue only when state-bound pr:/handoff: + active-work claim match.
preflight_lane_queue() {
  local lane="$1" queue="$2"
  local issue current seen_current=0 queue_work pid d

  d=$(lane_dir "$lane")

  # Identity first whenever a lane base exists — including before pid checks
  # that may remove a stale/reused pidfile (non-mutating on foreign markers).
  if [[ -d "$d" ]]; then
    assert_lane_identity "$lane"
  fi

  if pid=$(lane_pid_alive "$lane"); then
    # Healthy PID is never an excuse to skip state/queue proof.
    if ! lane_state_is_valid "$lane"; then
      die "lane $lane: healthy pid $pid but loop-state is missing/invalid (positive issue: required) — fail closed"
    fi
    current=$(assert_recorded_issue_in_queue "$lane" "$queue") || return 1
    info "lane $lane already running (pid $pid issue #$current) — skip queue conflict preflight (identity+queue validated)"
    return 0
  fi

  current=""
  if lane_state_is_valid "$lane"; then
    current=$(assert_recorded_issue_in_queue "$lane" "$queue") || return 1
  fi

  queue_work=$(printf '%s' "$queue" | tr ',' ' ')
  if [[ -z "$current" ]]; then
    # Unstarted: every queue item is strict future work.
    # shellcheck disable=SC2086
    for issue in $queue_work; do
      issue=$(printf '%s' "$issue" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -n "$issue" ]] || continue
      check_issue_preflight "$issue" "$lane" "strict"
      check_pr_conflicts "$issue" "$lane"
    done
    return 0
  fi

  # Dead resumable: prior / current / future treated differently.
  # shellcheck disable=SC2086
  for issue in $queue_work; do
    issue=$(printf '%s' "$issue" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$issue" ]] || continue
    if [[ "$issue" == "$current" ]]; then
      seen_current=1
      # Own recorded issue may be agent-claimed only with matching state-bound PR.
      check_issue_preflight "$issue" "$lane" "own"
      check_own_resumption "$issue" "$lane"
      continue
    fi
    if [[ $seen_current -eq 0 ]]; then
      # Prior to recorded issue — CLOSED only (OPEN fails closed above).
      check_issue_preflight "$issue" "$lane" "prior"
    else
      # Future queue work — still strict.
      check_issue_preflight "$issue" "$lane" "strict"
      check_pr_conflicts "$issue" "$lane"
    fi
  done
}

# True if a command string cannot be safely whitespace-tokenized (fail closed).
# Quotes, expansions, and shell metacharacters make first-token identity unreliable
# and must not become a distinct fake provider.
cmd_has_unsafe_syntax() {
  local raw="$1"
  case "$raw" in
    *[\`\$\;\|\&\<\>\(\)\{\}\[\]\'\"\\]*|*$'\n'*|*$'\r'*|*$'\t'*) return 0 ;;
  esac
  return 1
}

# Resolve the real executable token of a role command (no eval / no shell parse).
# - Fail closed on quotes/metacharacters (ambiguous tokenization).
# - Safely unwrap only well-defined `env` forms: bare flags (-i/-0/-v), -u NAME,
#   -P DIR, and NAME=VALUE assignments. Reject -S and unknown options.
# - Trailing args (including misleading vendor words) are ignored after the utility.
# Returns the utility path/name on stdout, or empty + status 1 on failure.
cmd_executable_token() {
  local raw="$1" tok base ename
  raw=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -n "$raw" ]] || { printf '\n'; return 1; }
  if cmd_has_unsafe_syntax "$raw"; then
    printf '\n'
    return 1
  fi

  # Whitespace tokenize with noglob — never eval/source the string.
  # shellcheck disable=SC2086
  set -f
  set -- $raw
  set +f
  [[ $# -ge 1 ]] || { printf '\n'; return 1; }

  base=$(basename "$1")
  if [[ "$base" == "env" ]]; then
    shift
    while [[ $# -gt 0 ]]; do
      tok="$1"
      case "$tok" in
        --) shift; break ;;
        -i|-0|-v) shift; continue ;;
        -u|-P)
          [[ $# -ge 2 ]] || { printf '\n'; return 1; }
          # NAME / DIR must themselves be free of metacharacters (already true of tokens).
          shift 2
          continue
          ;;
        -S*|-s*)
          # env -S embeds shell-like strings — refuse.
          printf '\n'
          return 1
          ;;
        -*)
          # Unknown / combined env options — fail closed (require a simple wrapper).
          printf '\n'
          return 1
          ;;
        *=*)
          # NAME=VALUE — require a legal env name; value is one whitespace token only.
          ename="${tok%%=*}"
          [[ "$ename" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf '\n'; return 1; }
          shift
          continue
          ;;
        *)
          break
          ;;
      esac
    done
    [[ $# -ge 1 ]] || { printf '\n'; return 1; }
  fi

  printf '%s\n' "$1"
}

# Map an executable basename to a provider family id (grok|codex|claude|hermes|other).
# Trailing arguments never participate — "grok … codex …" is still provider "grok".
provider_family_from_basename() {
  local base
  base=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$base" in
    '') printf '\n'; return 1 ;;
    grok|grok-*) printf 'grok\n' ;;
    codex|codex-*) printf 'codex\n' ;;
    claude|claude-*) printf 'claude\n' ;;
    hermes|hermes-*) printf 'hermes\n' ;;
    *) printf '%s\n' "$base" ;;
  esac
}

# Resolve the provider identity of a role command from its real executable only
# (after safe env unwrap). Discovers PATH hits and one-level symlinks when present
# so aliases/paths cannot mask the same provider under a different spelling.
cmd_provider_id() {
  local raw="$1" first base resolved target dir
  first=$(cmd_executable_token "$raw") || true
  [[ -n "$first" ]] || { printf '\n'; return 1; }

  base=$(basename "$first")

  if [[ "$first" == */* ]]; then
    # Absolute or relative path form.
    if [[ -L "$first" ]]; then
      target=$(readlink "$first" 2>/dev/null || true)
      if [[ -n "$target" ]]; then
        if [[ "$target" != /* ]]; then
          dir=$(dirname "$first")
          target="$dir/$target"
        fi
        base=$(basename "$target")
      fi
    elif [[ -e "$first" ]]; then
      dir=$(dirname "$first")
      if [[ -d "$dir" ]]; then
        resolved=$(CDPATH='' cd "$dir" 2>/dev/null && pwd -P)/$(basename "$first")
        base=$(basename "$resolved")
      fi
    fi
  else
    # Bare name — resolve via PATH when discoverable.
    if resolved=$(command -v "$first" 2>/dev/null); then
      if [[ -L "$resolved" ]]; then
        target=$(readlink "$resolved" 2>/dev/null || true)
        if [[ -n "$target" ]]; then
          if [[ "$target" != /* ]]; then
            dir=$(dirname "$resolved")
            target="$dir/$target"
          fi
          base=$(basename "$target")
        else
          base=$(basename "$resolved")
        fi
      else
        base=$(basename "$resolved")
      fi
    fi
  fi

  provider_family_from_basename "$base"
}

assert_three_role_separation() {
  # Never allow the implementation runner to grade or release its own work.
  # Compare normalized first-executable provider identities only — never substring
  # match on the full command (a Grok argv containing the word "codex" is still Grok).
  local r_id rev_id rel_id
  [[ -n "${RUNNER:-}" ]] || die "RUNNER is empty — builder identity required"
  [[ -n "${REVIEWER_CMD:-}" ]] || die "REVIEWER_CMD is empty — cross-vendor review required (Law 5)"
  [[ -n "${RELEASE_CMD:-}" ]] || die "RELEASE_CMD is empty — third-identity release required (three-role split)"

  r_id=$(cmd_provider_id "$RUNNER") || true
  rev_id=$(cmd_provider_id "$REVIEWER_CMD") || true
  rel_id=$(cmd_provider_id "$RELEASE_CMD") || true
  [[ -n "$r_id" ]] || die "cannot resolve builder provider identity from RUNNER='$RUNNER'"
  [[ -n "$rev_id" ]] || die "cannot resolve reviewer provider identity from REVIEWER_CMD='$REVIEWER_CMD'"
  [[ -n "$rel_id" ]] || die "cannot resolve release provider identity from RELEASE_CMD='$RELEASE_CMD'"

  if [[ "$r_id" == "$rev_id" ]]; then
    die "REVIEWER_CMD must not be the same provider as the builder (provider=$r_id RUNNER=$RUNNER REVIEWER_CMD=$REVIEWER_CMD)"
  fi
  if [[ "$r_id" == "$rel_id" ]]; then
    die "RELEASE_CMD must be a third identity distinct from the builder (provider=$r_id RUNNER=$RUNNER RELEASE_CMD=$RELEASE_CMD)"
  fi
  if [[ "$rev_id" == "$rel_id" ]]; then
    die "RELEASE_CMD must be a third identity distinct from the reviewer (provider=$rev_id REVIEWER_CMD=$REVIEWER_CMD RELEASE_CMD=$RELEASE_CMD)"
  fi
}

preflight_for_start() {
  local i

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

  # Preserve git status exit code: a failed probe is not "clean".
  local dirty dirty_rc=0 dirty_diag
  dirty=$(git -C "$BASE_REPO" status --porcelain 2>&1) || dirty_rc=$?
  if [[ $dirty_rc -ne 0 ]]; then
    dirty_diag=$(printf '%s' "$dirty" | tr '\n' ' ' | cut -c1-400)
    die "cannot determine checkout cleanliness (git status --porcelain exit $dirty_rc): ${dirty_diag:-<no output>} — refuse to launch"
  fi
  [[ -z "$dirty" ]] || die "canonical checkout is dirty — refuse to create lane worktrees from a dirty tree"

  # scopes already checked at load; re-check here so --start always enforces
  check_inter_lane_scope_overlap

  # Per-lane queue preflight is state-aware: healthy identity first, then
  # resumable own claim/PR, then strict unstarted/future work.
  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    preflight_lane_queue "${LANE_IDS[$i]}" "${LANE_QUEUES[$i]}"
    i=$((i + 1))
  done

  info "preflight OK ($(( ${#LANE_IDS[@]} )) lane(s))"
}

# --- commands ---------------------------------------------------------------

do_halt() {
  local n=0 i id d
  print_identity
  # Refuse to write HALT into a foreign fleet/log namespace.
  assert_profile_identity_for_reuse
  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    id="${LANE_IDS[$i]}"
    d=$(lane_dir "$id")
    if [[ -d "$d" ]]; then
      assert_lane_identity "$id"
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
  # Refuse to report status for a foreign fleet/log namespace.
  assert_profile_identity_for_reuse
  printf '%-12s %-14s %-6s %-8s %-11s %s\n' LANE QUEUE PID HAT HEALTH LAST
  local dead=0 i id queue d pid hat last health
  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    id="${LANE_IDS[$i]}"
    queue="${LANE_QUEUES[$i]}"
    d=$(lane_dir "$id")
    # Validate each existing lane marker before any pid/state/log read or
    # pidfile mutation (lane_pid_alive may delete stale pidfiles).
    if [[ -d "$d" ]]; then
      assert_lane_identity "$id"
    fi
    pid=$(lane_pid_alive "$id" || true)
    # Shared space/no-space field grammar (lane_state_field / loop.sh read_field).
    hat=$(lane_state_field "$id" "hat" 2>/dev/null || true)
    hat=$(printf '%s' "${hat:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
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

# True when lane base has a usable loop-state (issue: field present).
lane_state_is_valid() {
  local id="$1" sf
  sf=$(lane_state "$id")
  [[ -f "$sf" ]] || return 1
  grep -qE '^issue:[[:space:]]*[1-9][0-9]*' "$sf" 2>/dev/null
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
  write_lane_identity "$id"

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

# Ensure sentinel + journal + identity exist without rewriting issue/pr/hat/round.
ensure_lane_markers() {
  local id="$1" d path
  d=$(lane_dir "$id")
  mkdir -p "$d/gibson"
  if [[ ! -f "$d/.fleet-lane" ]]; then
    cat > "$d/.fleet-lane" <<EOF
This directory is a long-lived FLEET LANE BASE (lane: $id).
It is the loop driver's --repo. Deleting it kills the lane.
It is NOT the per-issue worktree that Gibson's release hat cleans up.
Do not run "git worktree remove" or rm -rf against this path.
EOF
  fi
  path=$(lane_identity_file "$id")
  if [[ -f "$path" ]]; then
    validate_identity_file "$path" "lane $id" "$id"
  else
    # First ensure after upgrade: write only when no foreign content conflict.
    # Fail closed if a loop-state already exists without a marker (reuse risk).
    if [[ -f "$(lane_state "$id")" ]]; then
      die "lane $id: existing loop-state without .fleet-identity marker — refuse to reuse"
    fi
    write_lane_identity "$id"
  fi
  [[ -f "$d/gibson/journal.md" ]] || echo "# Gibson loop journal (lane $id)" > "$d/gibson/journal.md"
}

# Run a command as its own process group leader, with a wall-clock bound.
# Works on stock macOS (no GNU timeout). Captures only the launched PID/group;
# on expiry TERM then KILL that group only — never pkill/killall/pattern kill.
# Returns 0 on success, 124 on wall-clock timeout, else the child's exit status.
run_with_wall_timeout() {
  local limit="$1"
  shift
  local pid watcher rc=0 status_file timed_out=0
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "fleet: bad wall timeout: $limit" >&2; return 1; }

  # Fail closed BEFORE launch if we cannot establish a process group.
  # A bare-child fallback cannot guarantee descendant cleanup on expiry.
  if ! command -v perl >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    echo "fleet: wall-timeout requires perl or python3 to establish a process group (no bare-child fallback)" >&2
    return 1
  fi

  status_file=$(mktemp "${TMPDIR:-/tmp}/fleet-wall.XXXXXX") || return 1

  # Become process-group leader so we can terminate only this tree.
  if command -v perl >/dev/null 2>&1; then
    perl -e 'setpgrp(0,0); exec { $ARGV[0] } @ARGV or exit 127' "$@" &
    pid=$!
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" &
    pid=$!
  else
    # Unreachable: guarded above. Keep as hard fail-closed, never bare child.
    echo "fleet: wall-timeout process-group mechanism vanished before launch" >&2
    rm -f "$status_file"
    return 1
  fi

  (
    elapsed=0
    while [[ $elapsed -lt $limit ]]; do
      if ! kill -0 "$pid" 2>/dev/null; then
        exit 0
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    # Still alive after wall clock — terminate only this process group.
    if kill -0 "$pid" 2>/dev/null; then
      printf 'timeout\n' > "$status_file"
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
  ) &
  watcher=$!

  wait "$pid" 2>/dev/null
  rc=$?

  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true

  if [[ -f "$status_file" ]] && grep -q '^timeout$' "$status_file" 2>/dev/null; then
    timed_out=1
  fi
  rm -f "$status_file"

  # Reap any residual of the group (best-effort; no pattern kill).
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi

  if [[ $timed_out -eq 1 ]]; then
    return 124
  fi
  return "$rc"
}

fetch_origin_bounded() {
  # Wall-clock bound + lowSpeed guard. Fail closed; leave no hung child.
  local limit="${FLEET_FETCH_TIMEOUT:-30}" rc
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "FLEET_FETCH_TIMEOUT must be a positive integer (got: $limit)"
  info "git fetch origin (wall timeout ${limit}s)"
  set +e
  run_with_wall_timeout "$limit" \
    env GIT_TERMINAL_PROMPT=0 \
    git -C "$BASE_REPO" \
      -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 \
      -c transfer.fsckObjects=false \
      fetch origin --quiet
  rc=$?
  set -e
  if [[ $rc -eq 124 ]]; then
    die "git fetch origin exceeded wall-clock timeout (${limit}s) — refuse to launch; set FLEET_SKIP_FETCH=1 only for offline sensors"
  fi
  if [[ $rc -ne 0 ]]; then
    die "git fetch origin failed (exit $rc) — refuse to launch; set FLEET_SKIP_FETCH=1 only for offline sensors"
  fi
}

# Bounded git ls-remote --symref origin HEAD. Same wall-clock process-group
# primitive as fetch; stdout captured via file redirect (no shell interpolation
# of remote output into command strings). Fail closed on timeout / non-zero.
# Prints the raw ls-remote payload on stdout.
ls_remote_symref_bounded() {
  local limit="${FLEET_FETCH_TIMEOUT:-30}" rc out_file
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "FLEET_FETCH_TIMEOUT must be a positive integer (got: $limit)"
  out_file=$(mktemp "${TMPDIR:-/tmp}/fleet-lsremote.XXXXXX") || die "cannot create temp file for ls-remote capture"
  info "git ls-remote --symref origin HEAD (wall timeout ${limit}s)"
  set +e
  # Redirect captures only the child tree's stdout; argv is fixed (no interpolation).
  run_with_wall_timeout "$limit" \
    env GIT_TERMINAL_PROMPT=0 \
    git -C "$BASE_REPO" ls-remote --symref origin HEAD >"$out_file"
  rc=$?
  set -e
  if [[ $rc -eq 124 ]]; then
    rm -f "$out_file"
    die "git ls-remote --symref origin HEAD exceeded wall-clock timeout (${limit}s) — refuse to launch; set FLEET_SKIP_FETCH=1 only for offline sensors"
  fi
  if [[ $rc -ne 0 ]]; then
    rm -f "$out_file"
    die "git ls-remote --symref origin HEAD failed (exit $rc) — refuse to launch; set FLEET_SKIP_FETCH=1 only for offline sensors"
  fi
  # Emit payload; caller parses. Never eval/source this content.
  cat "$out_file"
  rm -f "$out_file"
}

# Resolve remote default branch name + exact tip SHA.
# Live: single bounded git ls-remote --symref origin HEAD (authoritative).
# Both the symbolic ref name AND the HEAD OID must come from that one payload —
# no second network call and no local main/master guess.
# Offline (FLEET_SKIP_FETCH=1): local refs/remotes/origin/HEAD only.
# Prints: "<name> <sha>"
resolve_remote_default_pin() {
  local name="" sha="" symref

  if [[ "$FLEET_SKIP_FETCH" == "1" ]]; then
    # Offline fixtures must set refs/remotes/origin/HEAD (local remote / stub).
    if name=$(git -C "$BASE_REPO" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null); then
      name=${name#refs/remotes/origin/}
    fi
    if [[ -z "$name" ]]; then
      # Some fixtures point origin/HEAD at a commit directly
      if sha=$(git -C "$BASE_REPO" rev-parse --verify --quiet refs/remotes/origin/HEAD 2>/dev/null); then
        die "origin/HEAD is detached at $sha without a branch name — set symbolic refs/remotes/origin/HEAD (offline fixture)"
      fi
      die "cannot resolve remote default branch offline: refs/remotes/origin/HEAD missing in $BASE_REPO (fixtures must set it; do not guess main/master)"
    fi
    sha=$(git -C "$BASE_REPO" rev-parse --verify --quiet "refs/remotes/origin/$name" 2>/dev/null || true)
    [[ -n "$sha" ]] || die "offline origin/$name has no tip object in $BASE_REPO"
    printf '%s %s\n' "$name" "$sha"
    return 0
  fi

  symref=$(ls_remote_symref_bounded) \
    || die "cannot resolve remote default branch: bounded ls-remote failed for $BASE_REPO"
  [[ -n "$symref" ]] || die "git ls-remote --symref origin HEAD returned empty payload — refuse to guess main/master"

  name=$(printf '%s\n' "$symref" |
    awk '$1 == "ref:" && $3 == "HEAD" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
  [[ -n "$name" ]] || die "origin advertises no symbolic HEAD in ls-remote payload — refusing to guess main/master"

  # HEAD OID must come from the same single payload (line: <oid> HEAD). No
  # second ls-remote and no local origin/* fallback on the live path.
  sha=$(printf '%s\n' "$symref" | awk '$2 == "HEAD" && $1 != "ref:" { print $1; exit }')
  [[ -n "$sha" ]] || die "ls-remote --symref payload missing HEAD OID for branch '$name' — refuse to launch"
  [[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || die "ls-remote HEAD OID malformed: $sha"

  # Verify object is present locally (fetch should have brought it in).
  git -C "$BASE_REPO" cat-file -e "$sha^{commit}" 2>/dev/null \
    || die "remote default tip $sha ($name) not present locally after fetch"

  printf '%s %s\n' "$name" "$sha"
}

do_start() {
  print_identity
  # Persist/validate fleet+log identity before preflight reads lane state.
  # preflight_lane_queue asserts per-lane markers when reusing bases.
  ensure_profile_runtime_dirs
  # Complete preflight BEFORE any worktree mutation or runner launch.
  preflight_for_start

  if [[ "$FLEET_SKIP_FETCH" == "1" ]]; then
    info "skip git fetch (FLEET_SKIP_FETCH=1)"
  else
    fetch_origin_bounded
  fi

  local pin_line default_name default_sha
  pin_line=$(resolve_remote_default_pin) \
    || die "failed to resolve remote default branch pin"
  default_name=${pin_line%% *}
  default_sha=${pin_line#* }
  [[ -n "$default_name" && -n "$default_sha" && "$default_name" != "$default_sha" ]] \
    || die "invalid remote default pin: $pin_line"
  info "lane base pin: origin/$default_name @ $default_sha"

  local i id queue scope intent d issue pid
  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    id="${LANE_IDS[$i]}"
    queue="${LANE_QUEUES[$i]}"
    scope="${LANE_SCOPES[$i]}"
    intent="${LANE_INTENTS[$i]}"
    issue="${queue%%,*}"
    d=$(lane_dir "$id")

    # Identity before any pid/mutation path that can reuse a lane base.
    if [[ -d "$d" ]]; then
      assert_lane_identity "$id"
    fi
    # Identity-validated healthy lane keeps HALT + state intact (no relaunch).
    if pid=$(lane_pid_alive "$id"); then
      # Markers + queue membership already validated in preflight (non-mutating).
      info "lane $id already running (pid $pid) — leaving state/HALT untouched, skip launch"
      i=$((i + 1))
      continue
    fi

    if [[ ! -d "$d" ]]; then
      info "worktree for lane $id (issue #$issue) from origin/$default_name @ $default_sha"
      # If a prior base was deleted out of band, prune the stale registration
      # so `worktree add` does not die with "missing but already registered".
      git -C "$BASE_REPO" worktree prune --expire now >/dev/null 2>&1 || true
      # Pin to the exact fetched remote-default tip — never guess main/master.
      if ! git -C "$BASE_REPO" worktree add --detach "$d" "$default_sha" --quiet; then
        git -C "$BASE_REPO" worktree remove --force "$d" >/dev/null 2>&1 || true
        git -C "$BASE_REPO" worktree prune --expire now >/dev/null 2>&1 || true
        git -C "$BASE_REPO" worktree add --detach "$d" "$default_sha" --quiet \
          || die "cannot create lane worktree at $d from $default_sha (origin/$default_name)"
      fi
      seed_lane_state "$id" "$queue" "$scope" "$intent"
    else
      info "reusing worktree $d"
      # Identity already asserted in preflight when the dir existed.
      if lane_state_is_valid "$id"; then
        # Dead (or never-launched-this-session) lane with valid state: preserve
        # issue/pr/hat/round. Clear HALT so a deliberate relaunch can proceed.
        ensure_lane_markers "$id"
        if [[ -f "$d/gibson/HALT" ]]; then
          rm -f "$d/gibson/HALT"
          info "lane $id: cleared HALT for relaunch; preserved loop-state"
        else
          info "lane $id: preserving existing loop-state"
        fi
      else
        # Truly missing / unusable state — initialize (rewrite identity too).
        seed_lane_state "$id" "$queue" "$scope" "$intent"
      fi
    fi

    info "launch lane $id → issue #$issue"
    # Export three-role cmds so loop.sh hats can shell out.
    if [[ "$FLEET_SYNC_LAUNCH" == "1" ]]; then
      # Deterministic offline path: no background jobs (sensors / CI).
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

  # Deadline watchdog: one identity-validated process per profile/log dir.
  # Healthy repeated --start keeps the original PID and deadline.
  ensure_watchdog
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
