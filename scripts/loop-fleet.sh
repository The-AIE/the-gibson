#!/usr/bin/env bash
# loop-fleet.sh — portable multi-lane Gibson fleet driver (issues #139 / #141)
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
#   - Per-lane runner routing (#141): optional 5th lane field is an ordered
#     declarative route (primary first, fallbacks after). Only declared runners
#     may be selected. Bounded readiness preflight before launch; fail over only
#     on classified readiness failure; three-role re-check against the *actual*
#     selected runner. Selection telemetry lives in the profile log namespace
#     (runner-selection.jsonl + gibson.cost.v1 join rows) and is propagated
#     into loop.sh via GIBSON_COST_* env for iteration association.
#
# PROFILE
#   FLEET_PROFILE=/absolute/path/to/profile
#   and/or --profile /absolute/path/to/profile
#   Format: templates/fleet/profile.v1.example + templates/fleet/README.md
#
# STOP IT
#   loop-fleet.sh --profile PATH --halt   # graceful: lanes finish current hat
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_GIBSON=$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd)

# Shared wall-clock helper (#269). Resolve through this file even when the
# driver is invoked via a symlink so lib/ stays repository-contained.
_wt_src="${BASH_SOURCE[0]}"
while [[ -L "$_wt_src" ]]; do
  _wt_dir=$(CDPATH='' cd -- "$(dirname -- "$_wt_src")" && pwd)
  _wt_link=$(readlink "$_wt_src")
  case "$_wt_link" in
    /*) _wt_src="$_wt_link" ;;
    *) _wt_src="$_wt_dir/$_wt_link" ;;
  esac
done
_wt_dir=$(CDPATH='' cd -- "$(dirname -- "$_wt_src")" && pwd)
WALL_TIMEOUT_LIB="$_wt_dir/lib/wall-timeout.sh"
unset _wt_src _wt_dir _wt_link
if [[ ! -f "$WALL_TIMEOUT_LIB" ]]; then
  echo "loop-fleet.sh: missing lib/wall-timeout.sh (looked in $WALL_TIMEOUT_LIB)" >&2
  exit 2
fi
# shellcheck disable=SC1090,SC1091
source "$WALL_TIMEOUT_LIB"
if ! declare -F run_with_wall_timeout >/dev/null 2>&1; then
  echo "loop-fleet.sh: lib/wall-timeout.sh did not define run_with_wall_timeout" >&2
  exit 2
fi

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
#   build (per-lane selected runner, default RUNNER only when field 5 omitted)
#   -> review (Codex/other) -> merge (Claude/third).
# Neither the builder nor the reviewer ever merges its own/co-vendor's work.
# Global RUNNER is not role-checked when every lane has an explicit route.
export REVIEWER_CMD="${REVIEWER_CMD:-codex exec -s read-only -}"
# RELEASE_CMD needs Bash + gh. Claude acceptEdits blocks Bash/gh (L-048).
export RELEASE_CMD="${RELEASE_CMD:-claude -p --output-format text --permission-mode bypassPermissions}"

# Lane parallel arrays (bash 3.2 — no associative arrays).
LANE_IDS=()
LANE_QUEUES=()
LANE_SCOPES=()
LANE_INTENTS=()
LANE_RUNNERS=()   # optional 5th field: ordered route "primary,fallback,..." (#141)
# Parallel selection results (filled by select_all_lane_runners before launch).
LANE_REQUESTED=()          # primary (first declared or global RUNNER)
LANE_SELECTED=()           # actual selected runner token
LANE_SELECT_HEALTH=()      # healthy | degraded
LANE_SELECT_REASON=()      # primary_ready | primary_not_ready:<class> | ...
LANE_SELECT_POOL=()        # pool label for telemetry
LANE_SELECT_JOIN=()        # stable join key for later outcome enrichment
# Optional operator-declared provider → pool labels (plan shape is not inferred
# from vendor identity). Parallel arrays; empty = provider-only defaults.
POOL_MAP_PROVIDERS=()
POOL_MAP_LABELS=()

# Test / ops hooks (PATH stubs preferred; these override when set).
GH_BIN="${GH_BIN:-gh}"
LOOP_SH="${LOOP_SH:-}"          # default: $GIBSON/scripts/loop.sh after load
SLEEP_CMD="${SLEEP_CMD:-sleep}" # tests can set to true / no-op
# Test hooks (unset in production):
#   FLEET_SYNC_LAUNCH=1  — run loop.sh in-foreground (no nohup); deterministic sensors
#   FLEET_NO_WATCHDOG=1  — skip deadline watchdog process
#   FLEET_SKIP_FETCH=1   — skip network fetch; resolve default branch from local origin/*
#   FLEET_FETCH_TIMEOUT  — wall-clock seconds for git fetch AND ls-remote (default 30)
#   FLEET_WATCHDOG_TEST_RECLAIM_PAUSE — if set to a path, reclaim writes
#     "<path>.entered" with "pause entered" then waits (bounded) while <path>
#     exists between observing stale content and the final re-read/unlink.
#     Sensors only: deterministic TOCTOU interleaving. Unset in production.
#   FLEET_WATCHDOG_TEST_FAIL_PUBLISH=1 — after a live child exists, force pidfile
#     publish to fail so sensors prove reservation+child cleanup. Unset in production.
#   FLEET_WATCHDOG_TEST_IMMEDIATE_EXIT=1 — after spawn, SIGKILL the child and leave
#     it unreaped so sensors prove zombie/immediate-exit never logs armed. Unset in production.
#   FLEET_WALL_TIMEOUT_TEST_PARENT_FALLBACK — if set to "date:<path>" or
#     "tick:<path>", wait (bounded) until <path> exists (sensor child writes it
#     after arming a TERM trap), then force only the matching parent-fallback
#     *precondition* (clock comparison or tick threshold) so the real date/tick
#     branch body runs (writes timeout + parent_forced). Does NOT write the
#     timeout flag, set parent_forced, or bypass the production branch body.
#     Sensors only. Unset in production.
FLEET_SYNC_LAUNCH="${FLEET_SYNC_LAUNCH:-0}"
FLEET_NO_WATCHDOG="${FLEET_NO_WATCHDOG:-0}"
FLEET_SKIP_FETCH="${FLEET_SKIP_FETCH:-0}"
FLEET_FETCH_TIMEOUT="${FLEET_FETCH_TIMEOUT:-30}"
# Runner readiness (#141): wall-clock seconds for each CLI auth/readiness probe.
FLEET_READINESS_TIMEOUT="${FLEET_READINESS_TIMEOUT:-8}"
# Test hook (unset in production): directory of per-token readiness probe
# executables named exactly as the route token basename. When set, production
# provider probes are skipped and only these probes run (bounded + process-group
# cleaned). Missing probe → not_found readiness failure.
FLEET_READINESS_DIR="${FLEET_READINESS_DIR:-}"

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
  portable (issue #139). Per-lane ordered runner routes + readiness are #141.

USAGE
  FLEET_PROFILE=/absolute/path/to/profile loop-fleet.sh [--start|--halt|--status]
  loop-fleet.sh --profile /absolute/path/to/profile [--start|--halt|--status]
  loop-fleet.sh --help

OPTIONS
  --profile PATH   absolute path to a fleet profile (or set FLEET_PROFILE)
  --start          preflight + create/reuse lane bases + launch (default)
  --halt           write gibson/HALT into every lane (graceful stop)
  --status         show profile identity and per-lane pid/hat/health/runner
  --help           this help

ENV (optional overrides after profile load)
  FLEET_PROFILE    absolute profile path
  GIBSON           Gibson clone (default: parent of scripts/, or profile gibson=)
  FLEET_DIR        directory for lane-* worktrees (must be absolute)
  LOG_DIR          per-lane logs (must be absolute)
  RUNNER           default builder when a lane omits the route field (default: grok)
  FLEET_READINESS_TIMEOUT  wall seconds per runner readiness probe (default: 8)
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

# Validate one runner token (basename or safe absolute executable path).
# Shared by parse_lane_line (route tokens), select_lane_runner (every selection
# candidate including global RUNNER when field 5 is omitted), and already-running
# revalidation so persisted selected_runner accepts the same shapes initial
# selection can pick. Fail closed on shell metacharacters/control chars,
# relative multipath, and real '..' path segments. Never eval/source/interpolate
# the token as shell.
assert_safe_runner_token() {
  local tok="$1" label="${2:-runner token}"
  [[ -n "$tok" ]] || die "$label is empty"
  # Hostile shell/control — note '/' is intentionally NOT listed: absolute
  # executable paths are a supported token form (see check_runner_readiness).
  # Comma is still hostile here: this validates a single token, not a route.
  case "$tok" in
    *[\`\$\;\|\&\<\>\(\)\{\}\[\]\'\"\\,]*|*$'\n'*|*$'\r'*|*$'\t'*)
      die "$label is hostile (shell/control chars): $tok"
      ;;
  esac
  if [[ ! "$tok" =~ ^[A-Za-z0-9._/@+=:-]+$ ]]; then
    die "$label has disallowed characters: $tok"
  fi
  # Path-shaped tokens must be absolute and free of real '..' segments
  # (same segment rules as assert_safe_abs_path). Relative multipath
  # (./x, foo/bar) is not a supported selection form. Safe basenames/paths
  # containing two consecutive dots that are not a segment (e.g. my..runner)
  # remain allowed.
  case "$tok" in
    */*)
      if [[ "$tok" != /* ]]; then
        die "$label is a malformed relative path: $tok"
      fi
      case "$tok" in
        *'/../'*|*/..|'/..'*)
          die "$label has disallowed '..' path segments: $tok"
          ;;
      esac
      ;;
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

# --- scope overlap (ported from scripts/scope-overlap.mjs pure kernel) ------
# Canonical fail-closed contract shared with scope-overlap.mjs (#153 / #181):
#   - ROOT ("**") overlaps every path (including another "**")
#   - empty, unsafe, or unstemmable tokens fail closed (overlap)
#   - exact / parent-child / boundary-aware stem containment overlap
#   - safe siblings stay disjoint
# A planner (JS) and this fleet driver must never disagree about concurrency.

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

# Return 0 when token matches the JS currentScopeTokenProblem → null grammar.
# Bash 3.2 portable: no mapfile, no associative arrays required.
scope_token_is_safe() {
  local token="$1" seg rest last literals=0
  # Pin C locale so [A-Za-z0-9_.-] is ASCII-only and independent of the caller
  # locale (JS SCOPE_LITERAL is code-point strict; collation must not widen it).
  local LC_ALL=C LANG=C
  [[ -n "$token" ]] || return 1
  # Deliberate root-wide scope — valid and classifiable.
  [[ "$token" == "**" ]] && return 0
  # Empty segments: leading/trailing slash or "//".
  case "$token" in
    /*|*/|*//*) return 1 ;;
  esac
  rest="$token"
  while [[ -n "$rest" ]]; do
    case "$rest" in
      */*)
        seg="${rest%%/*}"
        rest="${rest#*/}"
        last=0
        ;;
      *)
        seg="$rest"
        rest=""
        last=1
        ;;
    esac
    if [[ "$seg" == "*" || "$seg" == "**" ]]; then
      # Wildcard only as the final whole segment.
      [[ "$last" -eq 1 ]] || return 1
      continue
    fi
    # Plain literal segment ([A-Za-z0-9_.-]+, not . or ..). ASCII via LC_ALL=C.
    [[ "$seg" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    if [[ "$seg" == "." || "$seg" == ".." ]]; then
      return 1
    fi
    literals=$((literals + 1))
  done
  # Bare "*" / no literals: normalises to nothing → not safe.
  [[ "$literals" -ge 1 ]] || return 1
  return 0
}

scope_tokens_overlap() {
  # True (0) when two scope tokens collide under the shared concurrency
  # contract — NOT string-equality alone (L-001 / #106 / #181 class).
  # Exit 0 = overlap (must not run concurrently); 1 = disjoint (may).
  local a="$1" b="$2" sa sb
  # Empty tokens fail closed: never authorize concurrency.
  if [[ -z "$a" || -z "$b" ]]; then
    return 0
  fi
  # Unclassifiable / unsafe tokens fail closed (same as JS tokensOverlap).
  if ! scope_token_is_safe "$a" || ! scope_token_is_safe "$b"; then
    return 0
  fi
  # Root-wide ** overlaps every path (both orientations).
  if [[ "$a" == "**" || "$b" == "**" ]]; then
    return 0
  fi
  [[ "$a" == "$b" ]] && return 0
  sa=$(scope_stem "$a")
  sb=$(scope_stem "$b")
  # Empty stem fail closed (was return 1 — the #181 Bash drift bug).
  if [[ -z "$sa" || -z "$sb" ]]; then
    return 0
  fi
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

parse_pool_map_line() {
  # pool_map=provider:pool-label — operator-declared plan shape for telemetry.
  # Does not inspect billing, keys, or provider settings. Duplicate providers fail closed.
  local raw="$1" lineno="${2:-?}"
  local prov label
  raw=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -n "$raw" ]] || die "profile line $lineno: pool_map value is empty (want provider:pool-label)"
  case "$raw" in
    *:*) ;;
    *) die "profile line $lineno: pool_map must be provider:pool-label (got: $raw)" ;;
  esac
  prov=${raw%%:*}
  label=${raw#*:}
  prov=$(printf '%s' "$prov" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
  label=$(printf '%s' "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -n "$prov" && -n "$label" ]] || die "profile line $lineno: pool_map needs non-empty provider and label"
  [[ "$prov" =~ ^[a-z][a-z0-9_-]*$ ]] || die "profile line $lineno: invalid pool_map provider '$prov'"
  # Pool labels are telemetry identifiers only (no shell metacharacters).
  [[ "$label" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] || die "profile line $lineno: invalid pool_map label '$label'"
  local i
  i=0
  while [[ $i -lt ${#POOL_MAP_PROVIDERS[@]} ]]; do
    if [[ "${POOL_MAP_PROVIDERS[$i]}" == "$prov" ]]; then
      die "profile line $lineno: duplicate pool_map for provider '$prov'"
    fi
    i=$((i + 1))
  done
  POOL_MAP_PROVIDERS+=("$prov")
  POOL_MAP_LABELS+=("$label")
}

lookup_pool_map() {
  # Print declared pool label for provider family, or empty if undeclared.
  local fam="$1" i
  fam=$(printf '%s' "$fam" | tr '[:upper:]' '[:lower:]')
  i=0
  while [[ $i -lt ${#POOL_MAP_PROVIDERS[@]} ]]; do
    if [[ "${POOL_MAP_PROVIDERS[$i]}" == "$fam" ]]; then
      printf '%s\n' "${POOL_MAP_LABELS[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

parse_lane_line() {
  # Fields: id|queue|scope|intent[|ordered-route]
  # Exactly 4 or 5 pipe-separated fields. A sixth field fails closed (#139 contract).
  # 5th field (#141): ordered declarative route — primary first, comma-separated
  # fallbacks after. Empty 5th field → global RUNNER only. Never source/eval.
  local raw="$1"
  local id queue scope intent runner_r rest
  # Do not eval. Split on | with read.
  IFS='|' read -r id queue scope intent rest <<<"$raw" || true
  # rest is the optional 5th field only — any further | is a sixth+ field.
  if [[ "$rest" == *"|"* ]]; then
    die "lane line has more than 5 fields (v1 allows id|queue|scope|intent[|ordered-route]): $raw"
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

  # Every scope token must parse under the same grammar as scope-overlap.mjs
  # (#153 / #181). Invalid evidence must refuse the profile, never authorize
  # a concurrent lane on an unclassifiable stem. Subshell isolates set -f so the
  # caller's glob state is restored on every exit path (same idiom as
  # scopes_lists_overlap; Bash 3.2 portable).
  local _stok _bad_scope_tok
  if _bad_scope_tok=$(
    set -f
    # shellcheck disable=SC2086
    for _stok in $scope; do
      if ! scope_token_is_safe "$_stok"; then
        printf '%s\n' "$_stok"
        exit 0
      fi
    done
    exit 1
  ); then
    _bad_scope_tok=${_bad_scope_tok%$'\n'}
    die "lane $id: invalid claim-scope token '${_bad_scope_tok}' (canonical grammar: '**' or plain segments with optional trailing '*'/'**'; refuse rather than authorize concurrency on unclassifiable evidence — #181)"
  fi

  # Optional 5th field: ordered runner route. Hostile-data rules — no shell
  # syntax / control characters (never eval'd / sourced / interpolated).
  if [[ -n "$runner_r" ]]; then
    case "$runner_r" in
      *[\`\$\;\|\&\<\>\(\)\{\}\[\]\'\"\\]*|*$'\n'*|*$'\r'*|*$'\t'*)
        die "lane $id: runner route field must be safe inert data (no shell syntax/control chars): $runner_r"
        ;;
    esac
    # Letters, digits, common path/name punctuation, and commas as separators.
    if [[ ! "$runner_r" =~ ^[A-Za-z0-9._/@+=:,-]+$ ]]; then
      die "lane $id: runner route field has disallowed characters: $runner_r"
    fi
    # Reject empty tokens (leading/trailing/double commas) before word-split
    # collapse can hide them.
    case "$runner_r" in
      ,*|*,|*,,*)
        die "lane $id: empty token in runner route: $runner_r"
        ;;
    esac
    # Validate each comma-separated token (no empty entries, no duplicates).
    local route_work tok seen_toks="" first_tok=1 cleaned_route=""
    route_work=$(printf '%s' "$runner_r" | tr ',' ' ')
    # shellcheck disable=SC2086
    set -f
    # intentional noglob word-split of validated token list only
    for tok in $route_work; do
      set +f
      tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -n "$tok" ]] || die "lane $id: empty token in runner route: $runner_r"
      # Basename or safe absolute path — same shape as persisted revalidation.
      assert_safe_runner_token "$tok" "lane $id: runner route token"
      case ",$seen_toks," in
        *",$tok,"*) die "lane $id: duplicate runner in route: $tok" ;;
      esac
      seen_toks="${seen_toks},${tok}"
      if [[ $first_tok -eq 1 ]]; then
        cleaned_route="$tok"
        first_tok=0
      else
        cleaned_route="${cleaned_route},${tok}"
      fi
      set -f
    done
    set +f
    [[ -n "$cleaned_route" ]] || die "lane $id: empty runner route after parse"
    runner_r="$cleaned_route"
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
  LANE_REQUESTED=()
  LANE_SELECTED=()
  LANE_SELECT_HEALTH=()
  LANE_SELECT_REASON=()
  LANE_SELECT_POOL=()
  LANE_SELECT_JOIN=()
  POOL_MAP_PROVIDERS=()
  POOL_MAP_LABELS=()

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
      version|name|repo|slug|gibson|fleet_dir|log_dir|runner|error_budget|deadline_seconds|pool_map)
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
      pool_map)
        # Repeated optional mappings: provider:pool-label. Plan shape is operator
        # knowledge (docs/15) — never inferred from vendor identity alone (#141).
        parse_pool_map_line "$val" "$lineno"
        ;;
      lane)
        # Repeated lane= records are required (1–3); uniqueness is enforced per id/issue.
        parse_lane_line "$val"
        ;;
      *)
        die "profile line $lineno: unknown field '$key' (v1 allows version,name,repo,slug,gibson,fleet_dir,log_dir,runner,error_budget,deadline_seconds,pool_map,lane)"
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
  # profile gibson= is authoritative when present. Validate existence before cd
  # so a missing path yields a bounded fleet: diagnostic (not a bare set -e exit).
  if [[ -n "$prof_gibson" ]]; then
    assert_safe_abs_path "gibson" "$prof_gibson"
    [[ -d "$prof_gibson" ]] || die "gibson path is not a directory: $prof_gibson"
    GIBSON=$(CDPATH='' cd "$prof_gibson" && pwd -P)
  elif [[ -n "${GIBSON}" ]]; then
    assert_safe_abs_path "GIBSON" "$GIBSON"
    [[ -d "$GIBSON" ]] || die "GIBSON path is not a directory: $GIBSON"
    GIBSON=$(CDPATH='' cd "$GIBSON" && pwd -P)
  else
    [[ -d "$DEFAULT_GIBSON" ]] || die "default gibson path is not a directory: $DEFAULT_GIBSON"
    GIBSON="$DEFAULT_GIBSON"
  fi

  # fleet/log defaults are namespaced by profile name AND a portable fingerprint
  # of profile path + physical repo + slug so same-name different targets cannot
  # collide on lane worktrees, pidfiles, logs, or the watchdog.
  # Explicit profile fleet_dir=/log_dir= and env FLEET_DIR/LOG_DIR still win.
  # Defaults expand $HOME under set -u — guard so missing HOME fails closed with
  # a fleet: diagnostic (cron/launchd can omit HOME).
  local default_ns
  default_ns=$(profile_default_ns)
  if [[ -n "$prof_fleet" ]]; then
    assert_safe_abs_path "fleet_dir" "$prof_fleet"
    FLEET_DIR="$prof_fleet"
  elif [[ -n "${FLEET_DIR}" ]]; then
    assert_safe_abs_path "FLEET_DIR" "$FLEET_DIR"
  else
    [[ -n "${HOME:-}" ]] || die "fleet_dir default requires HOME; set fleet_dir= in the profile or FLEET_DIR"
    FLEET_DIR="${HOME}/Code/fleet/${PROFILE_NAME}-${default_ns}"
  fi
  assert_safe_abs_path "fleet_dir" "$FLEET_DIR"

  if [[ -n "$prof_log" ]]; then
    assert_safe_abs_path "log_dir" "$prof_log"
    LOG_DIR="$prof_log"
  elif [[ -n "${LOG_DIR}" ]]; then
    assert_safe_abs_path "LOG_DIR" "$LOG_DIR"
  else
    [[ -n "${HOME:-}" ]] || die "log_dir default requires HOME; set log_dir= in the profile or LOG_DIR"
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
  # Global RUNNER is only the default for lanes that omit field 5. Empty is
  # allowed when every lane declares an explicit ordered route.
  if any_lane_uses_global_runner; then
    [[ -n "$RUNNER" ]] || die "runner is empty — at least one lane omits the ordered-route field"
  fi

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

# True when PID is signalable and not a zombie. kill -0 alone is insufficient:
# a just-exited child remains kill -0-able until wait reaps it, but is not a
# live watchdog. Bash 3.2 / macOS: ps -o state= yields Z for zombies.
pid_is_live_non_zombie() {
  local pid="$1" st
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  st=$(ps -p "$pid" -o state= 2>/dev/null || true)
  if [[ -z "$st" ]]; then
    st=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  fi
  st=$(printf '%s' "$st" | tr -d '[:space:]')
  [[ -n "$st" ]] || return 1
  case "$st" in
    Z*) return 1 ;;
  esac
  return 0
}

# Best-effort compare-and-unlink for a stale exclusive reservation.
#
# Not a fully atomic portable lock. Deletes $pf only when the on-disk value
# still equals the exact observed stale content and is still stale on re-read.
# Between the final re-read and rm -f there remains a narrowed TOCTOU window:
# a competitor that installs a *different* value is preserved when re-read
# mismatches; a same-value overwrite in that final window can still be
# unlinked. Prefer noclobber create for exclusive arming; this reclaim only
# cleans dead-reserver / empty artifacts.
#
# Returns 0 if file is gone or was reclaimed; 1 if still present / not reclaimable.
watchdog_reclaim_stale_reservation() {
  local pf="$1" observed recheck reserver i pause="${FLEET_WATCHDOG_TEST_RECLAIM_PAUSE:-}"
  [[ -n "$pf" && -f "$pf" ]] || return 0
  observed=$(tr -d '[:space:]' < "$pf" 2>/dev/null || true)
  # Only empty or reserving:* markers are reclaim candidates.
  if [[ -n "$observed" && "$observed" != reserving:* ]]; then
    return 1
  fi
  if [[ "$observed" == reserving:* ]]; then
    reserver=${observed#reserving:}
    if [[ "$reserver" =~ ^[1-9][0-9]*$ ]] && kill -0 "$reserver" 2>/dev/null; then
      return 1
    fi
  fi
  # Sensors only: announce entry into the interleaving window, then wait while
  # the pause path exists so the sensor can install a live competitor.
  if [[ -n "$pause" ]]; then
    # Explicit marker the sensor waits for before installing a competitor.
    # Do not treat mere existence of $pause as "reclaim entered" — that races
    # before this function is called.
    printf 'pause entered\n' > "${pause}.entered" 2>/dev/null || true
    i=0
    while [[ -e "$pause" && $i -lt 100 ]]; do
      sleep 0.05 2>/dev/null || sleep 1
      i=$((i + 1))
    done
  fi
  # Re-read: abort if a competitor installed a different value.
  recheck=$(tr -d '[:space:]' < "$pf" 2>/dev/null || true)
  [[ "$recheck" == "$observed" ]] || return 1
  if [[ "$recheck" == reserving:* ]]; then
    reserver=${recheck#reserving:}
    if [[ "$reserver" =~ ^[1-9][0-9]*$ ]] && kill -0 "$reserver" 2>/dev/null; then
      return 1
    fi
  elif [[ -n "$recheck" ]]; then
    return 1
  fi
  # Final same-value confirm immediately before deletion (narrowed TOCTOU window;
  # not fully atomic — see function header).
  recheck=$(tr -d '[:space:]' < "$pf" 2>/dev/null || true)
  [[ "$recheck" == "$observed" ]] || return 1
  if [[ "$recheck" == reserving:* ]]; then
    reserver=${recheck#reserving:}
    if [[ "$reserver" =~ ^[1-9][0-9]*$ ]] && kill -0 "$reserver" 2>/dev/null; then
      return 1
    fi
  fi
  rm -f "$pf"
  return 0
}

# Drop only this process's exact reservation artifact (reserving:$$).
watchdog_clear_own_reservation() {
  local pf="$1" content
  content=$(tr -d '[:space:]' < "$pf" 2>/dev/null || true)
  if [[ "$content" == "reserving:$$" ]]; then
    rm -f "$pf"
  fi
}

# Terminate and reap only the exact child we spawned (never pattern kill).
watchdog_terminate_exact_child() {
  local pid="$1"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.05 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

# Watchdog identity: live non-zombie PID + command line still references this
# driver and this profile path. Unrelated reused PIDs are not our watchdog.
# Active exclusive reservations use content "reserving:<pid>" and must not be
# deleted while the reserver process is still alive (concurrent --start).
watchdog_pid_alive() {
  local pf pid cmdline driver_base reserver content
  pf=$(watchdog_pidfile)
  [[ -f "$pf" ]] || return 1
  content=$(tr -d '[:space:]' < "$pf" 2>/dev/null || true)
  # Exclusive start reservation — not a real watchdog; leave for the reserver.
  if [[ "$content" == reserving:* ]]; then
    reserver=${content#reserving:}
    if [[ "$reserver" =~ ^[1-9][0-9]*$ ]] && kill -0 "$reserver" 2>/dev/null; then
      return 1
    fi
    # Stale reservation (reserver dead) — reclaim only the exact observed value.
    watchdog_reclaim_stale_reservation "$pf" || true
    return 1
  fi
  pid="$content"
  [[ -n "$pid" && "$pid" =~ ^[1-9][0-9]*$ ]] || { rm -f "$pf"; return 1; }
  if ! pid_is_live_non_zombie "$pid"; then
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

# True when pidfile holds a live exclusive reservation from another process.
watchdog_reservation_active() {
  local pf content reserver
  pf=$(watchdog_pidfile)
  [[ -f "$pf" ]] || return 1
  content=$(tr -d '[:space:]' < "$pf" 2>/dev/null || true)
  [[ "$content" == reserving:* ]] || return 1
  reserver=${content#reserving:}
  [[ "$reserver" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$reserver" 2>/dev/null
}

# Arm deadline watchdog once per profile/log directory. Healthy re-start keeps
# the original PID and deadline. Concurrent --start uses an exclusive
# noclobber reservation so only one process arms a timer; losers re-check and
# either adopt the winner's watchdog or fail closed with a fleet: diagnostic.
ensure_watchdog() {
  local wd_pid wd_pf reserved=0 i content published settle live_hits
  if [[ "$FLEET_NO_WATCHDOG" == "1" ]]; then
    info "watchdog skipped (FLEET_NO_WATCHDOG=1)"
    return 0
  fi
  if wd_pid=$(watchdog_pid_alive); then
    info "watchdog already running (pid $wd_pid) — leaving deadline untouched"
    return 0
  fi
  wd_pf=$(watchdog_pidfile)
  mkdir -p "$LOG_DIR"

  # Fail closed on unusable SLEEP_CMD before taking a reservation or spawning.
  if [[ -z "${SLEEP_CMD:-}" ]]; then
    die "SLEEP_CMD is empty — refuse to arm watchdog"
  fi
  if [[ "$SLEEP_CMD" == */* ]]; then
    [[ -x "$SLEEP_CMD" ]] || die "SLEEP_CMD not executable: $SLEEP_CMD — refuse to arm watchdog"
  else
    command -v "$SLEEP_CMD" >/dev/null 2>&1 \
      || die "SLEEP_CMD not found on PATH: $SLEEP_CMD — refuse to arm watchdog"
  fi

  # Exclusive reservation (Bash 3.2 / macOS portable): noclobber create with
  # reserving:<self-pid>. Concurrent starters lose the race and must not arm
  # a second timer. Clean only this exact reservation on launch failure.
  if ( set -C; umask 077; printf 'reserving:%s\n' "$$" > "$wd_pf" ) 2>/dev/null; then
    reserved=1
  else
    # Lost the race or leftover file. Wait briefly for a concurrent arm, then
    # recover only a stale (dead-reserver) reservation via compare-and-unlink.
    i=0
    while [[ $i -lt 20 ]]; do
      if wd_pid=$(watchdog_pid_alive); then
        info "watchdog already running (pid $wd_pid) — leaving deadline untouched"
        return 0
      fi
      if watchdog_reservation_active; then
        sleep 0.1 2>/dev/null || sleep 1
        i=$((i + 1))
        continue
      fi
      # No live watchdog and no live reservation — reclaim only exact stale value.
      watchdog_reclaim_stale_reservation "$wd_pf" || true
      if ( set -C; umask 077; printf 'reserving:%s\n' "$$" > "$wd_pf" ) 2>/dev/null; then
        reserved=1
        break
      fi
      sleep 0.1 2>/dev/null || sleep 1
      i=$((i + 1))
    done
    if [[ $reserved -ne 1 ]]; then
      if wd_pid=$(watchdog_pid_alive); then
        info "watchdog already running (pid $wd_pid) — leaving deadline untouched"
        return 0
      fi
      die "watchdog reservation busy and no healthy watchdog at $wd_pf — refuse to arm a second timer (zero silent success)"
    fi
  fi

  # Hold exclusive reservation. Re-check health before launch (should be clear).
  if wd_pid=$(watchdog_pid_alive); then
    # Unexpected: a real pid appeared under our reserved file — keep it.
    info "watchdog already running (pid $wd_pid) — leaving deadline untouched"
    return 0
  fi

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
  wd_pid=$!

  # Sensors only: force immediate-exit/zombie of the exact child we spawned.
  # Leave unreaped so kill -0 may still pass while state=Z — production settle
  # must reject that before publishing or logging "armed".
  if [[ "${FLEET_WATCHDOG_TEST_IMMEDIATE_EXIT:-0}" == "1" ]]; then
    kill -KILL "$wd_pid" 2>/dev/null || true
  fi

  # Bounded post-launch settle + ps-backed live/non-zombie check. kill -0 alone
  # can pass for an already-exited/zombie child and would falsely publish "armed".
  # Require several consecutive live samples so exec-fail/zombie races can surface
  # before we publish the PID or log success.
  settle=0
  live_hits=0
  while [[ $settle -lt 20 ]]; do
    if pid_is_live_non_zombie "$wd_pid"; then
      live_hits=$((live_hits + 1))
      # ~5 × 50ms ≈ 250ms stable live window (or 5s if only integer sleep exists).
      if [[ $live_hits -ge 5 ]]; then
        break
      fi
    else
      live_hits=0
    fi
    sleep 0.05 2>/dev/null || sleep 1
    settle=$((settle + 1))
  done

  if ! pid_is_live_non_zombie "$wd_pid"; then
    watchdog_clear_own_reservation "$wd_pf"
    watchdog_terminate_exact_child "$wd_pid"
    die "watchdog failed to start (no live non-zombie process for reserved pidfile $wd_pf)"
  fi

  # Sensors only: force publish failure after a live child exists.
  if [[ "${FLEET_WATCHDOG_TEST_FAIL_PUBLISH:-0}" == "1" ]]; then
    watchdog_clear_own_reservation "$wd_pf"
    # Directory at pidfile path makes the subsequent write fail deterministically.
    mkdir -p "$wd_pf" 2>/dev/null || true
  fi

  # Publish real PID only after a live non-zombie process exists (still reserved).
  if ! printf '%s\n' "$wd_pid" > "$wd_pf" 2>/dev/null; then
    watchdog_clear_own_reservation "$wd_pf"
    # If test hook left a directory, remove only that exact artifact when empty-ish.
    if [[ -d "$wd_pf" ]]; then
      rmdir "$wd_pf" 2>/dev/null || true
    fi
    watchdog_terminate_exact_child "$wd_pid"
    die "watchdog pidfile publish failed at $wd_pf — refuse to leave an untracked timer"
  fi

  published=$(tr -d '[:space:]' < "$wd_pf" 2>/dev/null || true)
  if [[ "$published" != "$wd_pid" ]]; then
    # Do not unlink a foreign value; only kill the child we created.
    watchdog_terminate_exact_child "$wd_pid"
    die "watchdog pidfile publish mismatch at $wd_pf (got ${published:-empty}, want $wd_pid)"
  fi

  # Final identity check before operator-visible "armed" (no false success).
  if ! pid_is_live_non_zombie "$wd_pid"; then
    content=$(tr -d '[:space:]' < "$wd_pf" 2>/dev/null || true)
    if [[ "$content" == "$wd_pid" ]]; then
      rm -f "$wd_pf"
    fi
    watchdog_terminate_exact_child "$wd_pid"
    die "watchdog exited before arm complete (pid $wd_pid) — refuse false armed"
  fi

  info "watchdog armed: HALT in $((DEADLINE_SECONDS / 3600))h (${DEADLINE_SECONDS}s) pid $wd_pid"
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

# Bound for gh stderr diagnostics attached to fail-closed messages.
# Benign notices on stderr must never enter TSV/body/metadata authority.
GH_ERR_BOUND=2048
# Last gh_capture results (bash 3.2: no nameref; globals avoid eval of payload).
GH_CAPTURE_OUT=""
GH_CAPTURE_ERR=""

# Run a command with stdout and stderr captured separately.
# Sets GH_CAPTURE_OUT (full stdout) and GH_CAPTURE_ERR (stderr bounded to
# GH_ERR_BOUND). Returns the command exit status. Temp files are always removed.
# Usage: gh_capture cmd arg...
gh_capture() {
  local _outf _errf _rc=1
  GH_CAPTURE_OUT=""
  GH_CAPTURE_ERR=""
  _outf=$(mktemp "${TMPDIR:-/tmp}/fleet-gh-out.XXXXXX") || return 1
  _errf=$(mktemp "${TMPDIR:-/tmp}/fleet-gh-err.XXXXXX") || { rm -f "$_outf"; return 1; }
  # Disable errexit only for the child invocation. Do NOT re-enable set -e
  # before return: set -e is shell-global, and a non-zero return under set -e
  # would abort the caller before it can assign rc=$? and die with diagnostics
  # (silent fail-closed with only identity lines — #152). Callers own errexit
  # via their set +e / rc=$? / set -e frames.
  set +e
  "$@" >"$_outf" 2>"$_errf"
  _rc=$?
  GH_CAPTURE_OUT=$(cat "$_outf" 2>/dev/null || true)
  # Bound stderr diagnostics — never feed into parsers.
  GH_CAPTURE_ERR=$(head -c "$GH_ERR_BOUND" "$_errf" 2>/dev/null || true)
  rm -f "$_outf" "$_errf"
  return "$_rc"
}

# Fetch issue state + label names via gh built-in --template (no external jq/
# python/perl). Prints: first line = state, subsequent lines = one label name
# each. Fail closed on non-zero gh; benign stderr cannot contaminate authority.
fetch_issue_state_labels() {
  local issue="$1" lane="$2"
  local out err rc=0
  set +e
  gh_capture \
    "$GH_BIN" issue view "$issue" --repo "$EXPECTED_SLUG" \
      --json state,labels \
      --template '{{.state}}{{"\n"}}{{range .labels}}{{.name}}{{"\n"}}{{end}}'
  rc=$?
  out=$GH_CAPTURE_OUT
  err=$GH_CAPTURE_ERR
  set -e
  if [[ $rc -ne 0 ]]; then
    die "lane $lane: issue #$issue missing or unreadable via gh (repo $EXPECTED_SLUG): ${err:-exit $rc}"
  fi
  # Authority is stdout only — never merge stderr.
  printf '%s' "$out"
  # Ensure a trailing newline so line-oriented readers see the last label.
  case "$out" in
    *$'\n') ;;
    *) printf '\n' ;;
  esac
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
# Stdout is TSV authority; stderr is diagnostics only (never merged).
list_open_pr_pairs() {
  local out err rc=0

  # gh --template is built into the CLI (Go templates); it does not require the
  # external jq binary. Only number + headRefName are fetched — never body.
  set +e
  gh_capture \
    "$GH_BIN" pr list --repo "$EXPECTED_SLUG" --state open \
      --json number,headRefName --limit "$OPEN_PR_LIST_LIMIT" \
      --template '{{range .}}{{printf "%v\t%s\n" .number .headRefName}}{{end}}'
  rc=$?
  out=$GH_CAPTURE_OUT
  err=$GH_CAPTURE_ERR
  set -e
  if [[ $rc -ne 0 ]]; then
    die "cannot list open PRs for claims/PR conflict check: ${err:-exit $rc}"
  fi

  _finalize_pr_meta_lines "$out"
}

# Fetch a single candidate PR body, then immediately re-verify its
# number/head/OPEN state before trusting that body. Closes list/view/body races
# and metadata mismatches.
# Prints the raw PR body on success.
# Body authority is gh --jq stdout; re-verify uses --template stdout; stderr is
# diagnostics only on both calls (never merged into body/TSV).
fetch_bound_pr_body() {
  local pr_num="$1" expect_head="$2" lane="$3" issue="$4"
  local meta body got_num got_head got_state rest err rc=0

  [[ "$pr_num" =~ ^[1-9][0-9]*$ ]] \
    || die "lane $lane: bound PR number '$pr_num' is not a positive integer"
  [[ -n "$expect_head" ]] \
    || die "lane $lane: bound PR #$pr_num has empty expected head"

  # Fetch only the state-bound candidate body. It remains untrusted until the
  # metadata call immediately below confirms that the same PR is still open on
  # the expected head. gh --jq is built into the CLI (not external jq).
  set +e
  gh_capture \
    "$GH_BIN" pr view "$pr_num" --repo "$EXPECTED_SLUG" \
      --json body --jq '.body // ""'
  rc=$?
  body=$GH_CAPTURE_OUT
  err=$GH_CAPTURE_ERR
  set -e
  if [[ $rc -ne 0 ]]; then
    die "lane $lane: cannot fetch body of state-bound PR #$pr_num for issue #$issue: ${err:-exit $rc}"
  fi

  # Immediate metadata re-verify via gh built-in formatter (no external jq).
  set +e
  gh_capture \
    "$GH_BIN" pr view "$pr_num" --repo "$EXPECTED_SLUG" \
      --json number,headRefName,state \
      --template '{{.number}}{{"\t"}}{{.headRefName}}{{"\t"}}{{.state}}{{"\n"}}'
  rc=$?
  meta=$GH_CAPTURE_OUT
  err=$GH_CAPTURE_ERR
  set -e
  if [[ $rc -ne 0 ]]; then
    die "lane $lane: cannot view state-bound PR #$pr_num for issue #$issue (re-verify failed): ${err:-exit $rc}"
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
  local out state labels lab first=1

  # gh built-in --template: first line state, then one label name per line.
  # No hand-parsing of JSON; no external jq/python/perl.
  out=$(fetch_issue_state_labels "$issue" "$lane")
  state=""
  labels=""
  while IFS= read -r lab || [[ -n "$lab" ]]; do
    if [[ $first -eq 1 ]]; then
      state=$lab
      first=0
      continue
    fi
    [[ -n "$lab" ]] || continue
    if [[ -n "$labels" ]]; then
      labels="${labels}"$'\n'"${lab}"
    else
      labels="$lab"
    fi
  done <<<"$out"

  # normalize
  state=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
  [[ -n "$state" ]] || die "lane $lane: issue #$issue returned empty state via gh template"

  if [[ "$mode" == "prior" ]]; then
    if [[ "$state" == "CLOSED" ]]; then
      # Closed prior queue item after the lane advanced past it — not a conflict.
      return 0
    fi
    # No explicit skip/park policy exists yet — fail closed on every OPEN prior.
    die "lane $lane: prior queue item #$issue is still OPEN (state=$state) — refuse to advance past unfinished work (no skip/park policy recorded)"
  fi

  [[ "$state" == "OPEN" ]] || die "lane $lane: issue #$issue is not open (state=$state)"

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
  local out labels lab claimed=0 first=1
  local bound_pr bound_handoff pairs num head body_raw
  local matched=0 issue_pr_seen=0
  local match_num="" match_head=""

  # Labels via gh --template (skip state line); no JSON hand-parse.
  out=$(fetch_issue_state_labels "$issue" "$lane")
  labels=""
  while IFS= read -r lab || [[ -n "$lab" ]]; do
    if [[ $first -eq 1 ]]; then
      first=0
      continue
    fi
    [[ -n "$lab" ]] || continue
    [[ "$lab" == "agent-claimed" ]] && claimed=1
    if [[ -n "$labels" ]]; then
      labels="${labels}"$'\n'"${lab}"
    else
      labels="$lab"
    fi
  done <<<"$out"

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

# --- #141 runner routing: readiness, ordered selection, telemetry -----------

# Map provider family → pool label for selection telemetry only.
# Does NOT invent plan shape (flat-rate / subscription) from vendor identity —
# that contradicts token-efficiency doctrine (plan shape is operator/current-plan
# data). Default is truthful provider-only: "provider-<family>". Operators
# declare real pool economics via optional repeated pool_map=provider:label
# profile lines. Flat-rate-first preference is still expressed by route order
# (grind lanes list preferred runners first). No billing/keys/settings inspection.
pool_for_provider() {
  local fam mapped
  fam=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$fam" ]]; then
    printf 'unknown\n'
    return 0
  fi
  if mapped=$(lookup_pool_map "$fam" 2>/dev/null); then
    printf '%s\n' "$mapped"
    return 0
  fi
  printf 'provider-%s\n' "$fam"
}

# Portable per-launch discriminator (Bash 3.2). Same value is written to both
# selection telemetry and cost-ledger rows and exported to loop.sh so iteration
# rows share the join key. Distinct across two launches in the same UTC second.
make_join_discriminator() {
  local disc=""
  # Prefer 8 hex bytes from /dev/urandom (portable; no $RANDOM dependency alone).
  if [[ -r /dev/urandom ]]; then
    disc=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  fi
  if [[ -z "$disc" || ! "$disc" =~ ^[0-9a-fA-F]+$ ]]; then
    # Fallback: pid + bash RANDOM + epoch (still unique enough for offline sensors).
    disc="$(printf '%s%04x%s' "$$" "${RANDOM:-0}" "$(date +%s 2>/dev/null || echo 0)")"
  fi
  printf '%s\n' "$disc"
}

# Stable join key for selection + iteration rows.
# Format: fleet-sel:v1:<profile>:<lane>:<requested>:<selected>:<UTC>:<disc>
# FLEET_TEST_JOIN_TS (sensors only) freezes the UTC second so collision-resistance
# of the discriminator can be proven; unset in production.
make_selection_join_key() {
  local id="$1" requested="$2" selected="$3"
  local ts disc
  ts="${FLEET_TEST_JOIN_TS:-$(date -u +"%Y%m%dT%H%M%SZ")}"
  disc=$(make_join_discriminator)
  printf 'fleet-sel:v1:%s:%s:%s:%s:%s:%s\n' \
    "$PROFILE_NAME" "$id" "$requested" "$selected" "$ts" "$disc"
}

lane_runner_status_file() { echo "$LOG_DIR/$1.runner-status"; }
runner_selection_log() { echo "$LOG_DIR/runner-selection.jsonl"; }

# Write machine-readable per-lane selection status (status / restart durable).
write_lane_runner_status() {
  local id="$1" requested="$2" selected="$3" health="$4" reason="$5" pool="$6" join="$7" route="$8"
  local path
  path=$(lane_runner_status_file "$id")
  # LOG_DIR already identity-validated on start; refuse path traversal via id.
  [[ "$id" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "internal: bad lane id for runner status: $id"
  cat > "$path" <<EOF
requested_primary=$requested
selected_runner=$selected
selected_provider=$(cmd_provider_id "$selected" 2>/dev/null || printf '%s' "$selected")
selected_pool=$pool
health=$health
reason=$reason
route=$route
join_key=$join
updated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
}

# Read a key=value line from a runner-status file (no source/eval).
read_runner_status_field() {
  local file="$1" key="$2" line val
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "${key}="*)
        val="${line#${key}=}"
        printf '%s\n' "$val"
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

# Fleet-local cost ledger path (join target for selection + loop iterations).
# Prefer explicit GIBSON_COST_LEDGER; otherwise LOG_DIR/cost-ledger.jsonl.
fleet_cost_ledger_path() {
  if [[ -n "${GIBSON_COST_LEDGER:-}" ]]; then
    printf '%s\n' "$GIBSON_COST_LEDGER"
  else
    printf '%s\n' "$LOG_DIR/cost-ledger.jsonl"
  fi
}

# Resolve cost-ledger.sh without relying on the (often stubbed) test GIBSON tree.
# Accepts a regular file (-f) even when the executable bit is missing; callers
# must invoke via `bash` so a lost +x is not misclassified as a budget failure.
resolve_cost_ledger_sh() {
  if [[ -n "${COST_LEDGER_SH:-}" && -f "$COST_LEDGER_SH" && ! -d "$COST_LEDGER_SH" ]]; then
    printf '%s\n' "$COST_LEDGER_SH"
    return 0
  fi
  if [[ -f "$SCRIPT_DIR/cost-ledger.sh" && ! -d "$SCRIPT_DIR/cost-ledger.sh" ]]; then
    printf '%s\n' "$SCRIPT_DIR/cost-ledger.sh"
    return 0
  fi
  if [[ -n "${GIBSON:-}" && -f "$GIBSON/scripts/cost-ledger.sh" && ! -d "$GIBSON/scripts/cost-ledger.sh" ]]; then
    printf '%s\n' "$GIBSON/scripts/cost-ledger.sh"
    return 0
  fi
  return 1
}

# Append one runner-selection telemetry record into the profile log namespace.
# Schema is fleet-local (gibson.fleet.runner_selection.v1). Also appends a
# gibson.cost.v1 selection row (same join_key) so cost-ledger summarize can
# attribute merged outcomes without inventing token/cost numbers (#141).
# Requires python3 (preflight-enforced; same runtime contract as loop.sh).
# Args: id requested selected health reason pool join route wall_ms [issue]
write_runner_selection_telemetry() {
  local id="$1" requested="$2" selected="$3" health="$4" reason="$5" pool="$6" join="$7" route="$8" wall_ms="$9"
  local issue="${10:-}"
  local path ts provider ledger cl_sh flat_flag flat_val
  path=$(runner_selection_log)
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  provider=$(cmd_provider_id "$selected" 2>/dev/null || printf '%s' "$selected")
  # JSON via python3 for safe escaping; fields are already validated tokens.
  # python3 is required at preflight — do not fall back to a late hard die after
  # readiness already passed. Never include probe stdout, env, tokens, or creds.
  command -v python3 >/dev/null 2>&1 \
    || die "lane $id: python3 required for runner-selection telemetry (preflight should have refused)"
  RUN_SEL_PATH="$path" RUN_SEL_TS="$ts" RUN_SEL_LANE="$id" \
  RUN_SEL_REQ="$requested" RUN_SEL_SEL="$selected" RUN_SEL_PROV="$provider" \
  RUN_SEL_POOL="$pool" RUN_SEL_HEALTH="$health" RUN_SEL_REASON="$reason" \
  RUN_SEL_JOIN="$join" RUN_SEL_ROUTE="$route" RUN_SEL_WALL="$wall_ms" \
  RUN_SEL_PROFILE="$PROFILE_NAME" RUN_SEL_SLUG="$EXPECTED_SLUG" \
  python3 -c '
import json, os, sys
ev = {
  "schema": "gibson.fleet.runner_selection.v1",
  "ts": os.environ["RUN_SEL_TS"],
  "profile": os.environ["RUN_SEL_PROFILE"],
  "slug": os.environ["RUN_SEL_SLUG"],
  "lane": os.environ["RUN_SEL_LANE"],
  "requested_primary": os.environ["RUN_SEL_REQ"],
  "selected_runner": os.environ["RUN_SEL_SEL"],
  "selected_provider": os.environ["RUN_SEL_PROV"],
  "selected_pool": os.environ["RUN_SEL_POOL"],
  "health": os.environ["RUN_SEL_HEALTH"],
  "fallback_reason": os.environ["RUN_SEL_REASON"],
  "route": os.environ["RUN_SEL_ROUTE"],
  "wall_ms": int(os.environ["RUN_SEL_WALL"] or "0"),
  "join_key": os.environ["RUN_SEL_JOIN"],
}
path = os.environ["RUN_SEL_PATH"]
line = json.dumps(ev, separators=(",", ":"), sort_keys=True) + "\n"
with open(path, "a", encoding="utf-8") as f:
    f.write(line)
' || die "failed to write runner-selection telemetry for lane $id"

  # Mirror selection into gibson.cost.v1 (no fabricated tokens/costs).
  if cl_sh=$(resolve_cost_ledger_sh); then
    ledger=$(fleet_cost_ledger_path)
    # Bash 3.2 + set -u: never expand an empty array with "${arr[@]}".
    # flat_rate only when the *operator-declared* pool label encodes a known
    # plan shape prefix. provider-* / unknown never invent economics.
    # subscription-* is not asserted as flat_rate true (plan shape unknown).
    flat_flag=""
    flat_val=""
    case "$pool" in
      flat-rate*) flat_flag="--flat-rate"; flat_val="true" ;;
      metered*|frontier*) flat_flag="--flat-rate"; flat_val="false" ;;
    esac
    set -- \
      --ledger "$ledger" \
      --runner "$selected" \
      --pool "$pool" \
      --hat "runner-selection" \
      --wall-ms "${wall_ms:-0}" \
      --join-key "$join" \
      --requested-runner "$requested" \
      --provider "$provider" \
      --fallback-reason "$reason" \
      --event-kind selection \
      --repo "$EXPECTED_SLUG" \
      --now "$ts"
    if [[ -n "$issue" ]]; then set -- "$@" --issue "$issue"; fi
    if [[ -n "$flat_flag" ]]; then set -- "$@" "$flat_flag" "$flat_val"; fi
    # Invoke via bash so a lost executable bit is not a false budget failure.
    if ! bash "$cl_sh" append "$@" >/dev/null 2>&1; then
      # Selection telemetry is fleet-required when a cost ledger path is in use.
      die "lane $id: cost-ledger selection append failed (fleet-required telemetry; check ledger path writability — no secrets printed)"
    fi
  else
    info "lane $id: cost-ledger.sh not found — selection join row skipped"
  fi
}

# True when at least one lane omits the ordered-route field (field 5) and
# therefore depends on the global RUNNER default.
any_lane_uses_global_runner() {
  local i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    if [[ -z "${LANE_RUNNERS[$i]:-}" ]]; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Bounded, noninteractive, credential-safe readiness probe for one runner token.
# Prints a classification on stdout: ready | not_found | timeout | not_ready | auth_fail
# Exit 0 only when ready. Hung checks terminate only the exact captured process group.
# Probe stdout/stderr is never logged — only the classification.
#
# Auth policy: only a *positive* provider-specific authentication/usability
# result may select a runner. Auth/status probes never fall back to --version
# on nonzero exit (that would mark a logged-out but installed CLI as ready).
# Unsupported-command is never inferred from stderr text (output may contain
# sensitive material and is discarded). Families without a stable noninteractive
# auth probe use exactly one bounded minimal non-mutating usability probe
# (`--version`); never a bare interactive invocation. Every probe redirects
# stdin from /dev/null so a CLI that waits on stdin cannot hang the wall timer
# beyond the process-group timeout for interactive reasons alone.
# Grok: fixed argv `models` (bounded, non-mutating) — exit 0 only when the
# configured account/provider can accept work. Never inspect/log models output.
check_runner_readiness() {
  local token="$1"
  local limit="${FLEET_READINESS_TIMEOUT:-8}"
  local exe family outf rc probe base

  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "FLEET_READINESS_TIMEOUT must be a positive integer (got: $limit)"
  [[ -n "$token" ]] || { printf 'not_found\n'; return 1; }

  # Test hook: per-token probe executable in FLEET_READINESS_DIR (basename only).
  if [[ -n "${FLEET_READINESS_DIR:-}" ]]; then
    if ! command -v perl >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
      printf 'infra_no_pgrp\n'
      return 1
    fi
    base=$(basename "$token")
    # basename of validated token only — never path-join hostile segments.
    if [[ ! "$base" =~ ^[A-Za-z0-9._@+=:-]+$ ]]; then
      printf 'not_found\n'
      return 1
    fi
    probe="${FLEET_READINESS_DIR}/${base}"
    if [[ ! -x "$probe" || -d "$probe" ]]; then
      printf 'not_found\n'
      return 1
    fi
    outf=$(mktemp "${TMPDIR:-/tmp}/fleet-ready.XXXXXX") || { printf 'not_ready\n'; return 1; }
    set +e
    run_with_wall_timeout "$limit" "$probe" </dev/null >"$outf" 2>&1
    rc=$?
    set -e
    rm -f "$outf"
    if [[ $rc -eq 124 ]]; then
      printf 'timeout\n'
      return 1
    fi
    if [[ $rc -eq 0 ]]; then
      printf 'ready\n'
      return 0
    fi
    # Convention for test probes: exit 3 => auth_fail; else not_ready.
    if [[ $rc -eq 3 ]]; then
      printf 'auth_fail\n'
      return 1
    fi
    printf 'not_ready\n'
    return 1
  fi

  # Production path: resolve executable, run fixed family probe (no profile interpolation).
  # Hung-check cleanup requires process-group leadership (perl or python3).
  if ! command -v perl >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    printf 'infra_no_pgrp\n'
    return 1
  fi
  if [[ "$token" == /* ]]; then
    # Absolute path tokens only — never resolve relative/hostile paths.
    # Match real '..' segments (same rules as assert_safe_runner_token /
    # assert_safe_abs_path); do not reject safe names like my..runner.
    case "$token" in
      *'/../'*|*/..|'/..'*) printf 'not_found\n'; return 1 ;;
    esac
    if [[ ! -x "$token" || -d "$token" ]]; then
      printf 'not_found\n'
      return 1
    fi
    exe="$token"
  else
    if ! exe=$(command -v "$token" 2>/dev/null); then
      printf 'not_found\n'
      return 1
    fi
  fi

  family=$(provider_family_from_basename "$(basename "$exe")") || family="other"
  outf=$(mktemp "${TMPDIR:-/tmp}/fleet-ready.XXXXXX") || { printf 'not_ready\n'; return 1; }
  set +e
  # Fixed argv tables only — never eval, never interpolate profile strings into shell.
  # Never read probe stdout/stderr for classification (discarded after exit status).
  # Every probe: stdin from /dev/null (no interactive hang on inherited terminal).
  case "$family" in
    grok)
      # Bounded non-mutating auth/readiness: fixed argv `models` only.
      # Exit 0 = configured primary can accept work. Never --version (install-only).
      # Never inspect or log models stdout/stderr.
      run_with_wall_timeout "$limit" "$exe" models </dev/null >"$outf" 2>&1
      rc=$?
      ;;
    codex)
      # Positive login-status only. Nonzero (incl. logged-out) is auth_fail —
      # never mask with a successful --version.
      run_with_wall_timeout "$limit" "$exe" login status </dev/null >"$outf" 2>&1
      rc=$?
      ;;
    claude)
      # Positive auth-status only. Nonzero is auth_fail — no --version fallback.
      run_with_wall_timeout "$limit" "$exe" auth status </dev/null >"$outf" 2>&1
      rc=$?
      ;;
    hermes)
      # Positive status only. Nonzero is auth_fail — no --version fallback.
      run_with_wall_timeout "$limit" "$exe" status </dev/null >"$outf" 2>&1
      rc=$?
      ;;
    *)
      # Unknown family: exactly one bounded minimal non-mutating usability probe.
      # Exit 0 proves --version works; no auth claim. Never bare-invoke the CLI
      # (agent CLIs may start interactive sessions or real work with no args).
      run_with_wall_timeout "$limit" "$exe" --version </dev/null >"$outf" 2>&1
      rc=$?
      ;;
  esac
  set -e
  # Destroy probe output immediately — never log raw content (credentials risk).
  rm -f "$outf"

  if [[ $rc -eq 124 ]]; then
    printf 'timeout\n'
    return 1
  fi
  if [[ $rc -eq 0 ]]; then
    printf 'ready\n'
    return 0
  fi
  # Auth-family probes (incl. Grok models): any nonzero (non-timeout) is auth_fail.
  # Usability probes for unknown families: not_ready.
  case "$family" in
    grok|codex|claude|hermes)
      printf 'auth_fail\n'
      ;;
    *)
      printf 'not_ready\n'
      ;;
  esac
  return 1
}

# True when builder provider collides with reviewer or release identity.
builder_conflicts_three_role() {
  local builder="$1"
  local b_id rev_id rel_id
  b_id=$(cmd_provider_id "$builder") || return 0
  rev_id=$(cmd_provider_id "$REVIEWER_CMD") || return 0
  rel_id=$(cmd_provider_id "$RELEASE_CMD") || return 0
  [[ -n "$b_id" && -n "$rev_id" && -n "$rel_id" ]] || return 0
  if [[ "$b_id" == "$rev_id" || "$b_id" == "$rel_id" ]]; then
    return 0
  fi
  return 1
}

# Select runner for one lane from its declared ordered route.
# Fail over only on classified readiness failure. A ready runner that collides
# with reviewer/release is refused (cannot bypass three-role via fallback).
# Prints nothing; sets LANE_* selection arrays via caller index or writes status.
# On total failure: die with actionable diagnostic (provider names, no credentials).
select_lane_runner() {
  local idx="$1"
  local id route requested selected health reason pool join
  local tok class wall_start wall_end wall_ms tried=""
  local route_work

  id="${LANE_IDS[$idx]}"
  route="${LANE_RUNNERS[$idx]}"
  if [[ -z "$route" ]]; then
    route="$RUNNER"
  fi
  requested="${route%%,*}"
  [[ -n "$requested" ]] || die "lane $id: empty requested primary runner"

  wall_start=$(date +%s 2>/dev/null || echo 0)
  selected=""
  health="healthy"
  reason="primary_ready"
  # shellcheck disable=SC2086
  route_work=$(printf '%s' "$route" | tr ',' ' ')
  set -f
  for tok in $route_work; do
    set +f
    tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$tok" ]] || continue
    # Every selection candidate — including global RUNNER when field 5 is
    # omitted — must pass the same token shape rules as parse/persist paths.
    # Without this, a malformed global runner= can bypass parse_lane_line and
    # only fail (or misbehave) later in readiness.
    assert_safe_runner_token "$tok" "lane $id: selection candidate"
    class=$(check_runner_readiness "$tok") || true
    case "$class" in
      ready)
        # Three-role against the *actual* candidate. Ready + role conflict
        # fails closed immediately — failover is only for readiness failures,
        # and fallback cannot bypass the three-role rule by skipping past a
        # ready-but-illegal candidate.
        if builder_conflicts_three_role "$tok"; then
          die "lane $id: selected runner '$tok' collides with reviewer/release identity (provider=$(cmd_provider_id "$tok" 2>/dev/null || echo unresolved); REVIEWER_CMD=$REVIEWER_CMD RELEASE_CMD=$RELEASE_CMD). Builder cannot grade its own work. Fallback cannot bypass the three-role rule. route=$route tried=${tried:-none}"
        fi
        selected="$tok"
        if [[ "$tok" == "$requested" ]]; then
          health="healthy"
          reason="primary_ready"
        else
          health="degraded"
          reason="primary_not_ready:${tried:-unknown};selected_fallback"
        fi
        break
        ;;
      infra_no_pgrp)
        die "lane $id: runner readiness requires perl or python3 to establish a process group for wall-timeout (no bare-child fallback); route token=$tok"
        ;;
      timeout|not_found|not_ready|auth_fail)
        tried="${tried}${tried:+;}${tok}=${class}"
        set -f
        continue
        ;;
      *)
        tried="${tried}${tried:+;}${tok}=not_ready"
        set -f
        continue
        ;;
    esac
  done
  set +f

  wall_end=$(date +%s 2>/dev/null || echo 0)
  wall_ms=0
  if [[ "$wall_start" =~ ^[0-9]+$ && "$wall_end" =~ ^[0-9]+$ && "$wall_end" -ge "$wall_start" ]]; then
    wall_ms=$(( (wall_end - wall_start) * 1000 ))
  fi

  if [[ -z "$selected" ]]; then
    die "lane $id: no declared runner is ready (route=$route tried=${tried:-none}). Fail closed with zero new lane launches. Check CLI install/auth for named providers only — no credentials are printed."
  fi

  pool=$(pool_for_provider "$(cmd_provider_id "$selected" 2>/dev/null || echo other)")
  # Collision-resistant join key (UTC second + per-launch discriminator).
  join=$(make_selection_join_key "$id" "$requested" "$selected")

  LANE_REQUESTED[$idx]="$requested"
  LANE_SELECTED[$idx]="$selected"
  LANE_SELECT_HEALTH[$idx]="$health"
  LANE_SELECT_REASON[$idx]="$reason"
  LANE_SELECT_POOL[$idx]="$pool"
  LANE_SELECT_JOIN[$idx]="$join"

  # First queue issue is known at selection time; PR is not yet.
  local issue_hint=""
  issue_hint="${LANE_QUEUES[$idx]%%,*}"
  [[ "$issue_hint" =~ ^[0-9]+$ ]] || issue_hint=""

  write_lane_runner_status "$id" "$requested" "$selected" "$health" "$reason" "$pool" "$join" "$route"
  write_runner_selection_telemetry "$id" "$requested" "$selected" "$health" "$reason" "$pool" "$join" "$route" "$wall_ms" "$issue_hint"
  info "lane $id runner: requested=$requested actual=$selected health=$health reason=$reason pool=$pool"
}

# Validate a reloaded/persisted selected runner token (already-running path).
# Identity revalidation only — never re-run readiness against a live process.
# Nonempty + same safe token shapes as initial selection (basename or absolute
# path) + three-role vs *current* reviewer/releaser.
validate_persisted_selected_runner() {
  local id="$1" selected="$2" context="${3:-already-running}"
  [[ -n "$selected" && "$selected" != "?" ]] \
    || die "lane $id: $context selected_runner is empty/missing — refuse to keep a lane whose builder identity cannot be revalidated"
  # Must accept every token form initial selection can persist (incl. absolute
  # executable paths from global runner= or a route token). Fail closed on
  # shell metacharacters, control chars, relative multipath, and '..'.
  assert_safe_runner_token "$selected" "lane $id: $context selected_runner"
  # Changed REVIEWER_CMD / RELEASE_CMD must not let a live builder grade/release
  # its own work — re-check provider separation against current config.
  if builder_conflicts_three_role "$selected"; then
    die "lane $id: $context selected runner '$selected' collides with current reviewer/release identity (provider=$(cmd_provider_id "$selected" 2>/dev/null || echo unresolved); REVIEWER_CMD=$REVIEWER_CMD RELEASE_CMD=$RELEASE_CMD). Builder cannot grade its own work. Stop the lane or reconfigure roles before --start."
  fi
}

# Select runners for every lane before any new launch. Already-running healthy
# lanes keep their *persisted* status after identity revalidation (no readiness
# re-probe). Missing runner-status on a live lane fails closed — never invent
# selected_runner from the current profile/global route (that is not evidence of
# which executable launched the live process). Any selection or revalidation
# failure dies before launch; live processes are left untouched.
select_all_lane_runners() {
  local i id pid statusf selected_persisted req_persisted
  LANE_REQUESTED=()
  LANE_SELECTED=()
  LANE_SELECT_HEALTH=()
  LANE_SELECT_REASON=()
  LANE_SELECT_POOL=()
  LANE_SELECT_JOIN=()
  # Pre-size arrays for bash 3.2 index assignment.
  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    LANE_REQUESTED+=("")
    LANE_SELECTED+=("")
    LANE_SELECT_HEALTH+=("")
    LANE_SELECT_REASON+=("")
    LANE_SELECT_POOL+=("")
    LANE_SELECT_JOIN+=("")
    i=$((i + 1))
  done

  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    id="${LANE_IDS[$i]}"
    if [[ -d "$(lane_dir "$id")" ]]; then
      assert_lane_identity "$id" 2>/dev/null || true
    fi
    if pid=$(lane_pid_alive "$id" 2>/dev/null); then
      # Healthy lane: reload persisted selection for status continuity.
      # Identity revalidation only — do NOT re-run readiness probes.
      # Do NOT infer actual runner from current profile/route when status is
      # missing: a profile change could hide a builder/reviewer collision.
      statusf=$(lane_runner_status_file "$id")
      if [[ ! -f "$statusf" ]]; then
        die "lane $id: already running (pid $pid) but missing runner-status evidence at $statusf — refuse to invent selected_runner from current profile/route (that is not evidence of which executable launched the live process). Halt and restart the lane, or restore a verified $id.runner-status before --start."
      fi
      req_persisted=$(read_runner_status_field "$statusf" "requested_primary" || echo "?")
      selected_persisted=$(read_runner_status_field "$statusf" "selected_runner" || echo "")
      validate_persisted_selected_runner "$id" "$selected_persisted" "already-running persisted"
      LANE_REQUESTED[$i]="$req_persisted"
      LANE_SELECTED[$i]="$selected_persisted"
      LANE_SELECT_HEALTH[$i]=$(read_runner_status_field "$statusf" "health" || echo "healthy")
      LANE_SELECT_REASON[$i]=$(read_runner_status_field "$statusf" "reason" || echo "already_running")
      LANE_SELECT_POOL[$i]=$(read_runner_status_field "$statusf" "selected_pool" || echo "unknown")
      LANE_SELECT_JOIN[$i]=$(read_runner_status_field "$statusf" "join_key" || echo "")
      info "lane $id already running (pid $pid) — keep runner selection status after identity revalidation"
    else
      select_lane_runner "$i"
    fi
    i=$((i + 1))
  done
}

# Global three-role check for reviewer/release only. Builder identity is not
# validated against the unused global RUNNER — that check runs after readiness
# against each *actual* selected runner (select_lane_runner /
# builder_conflicts_three_role). Compare normalized first-executable provider
# identities only — never substring match on the full command.
assert_reviewer_release_separation() {
  local rev_id rel_id
  [[ -n "${REVIEWER_CMD:-}" ]] || die "REVIEWER_CMD is empty — cross-vendor review required (Law 5)"
  [[ -n "${RELEASE_CMD:-}" ]] || die "RELEASE_CMD is empty — third-identity release required (three-role split)"

  rev_id=$(cmd_provider_id "$REVIEWER_CMD") || true
  rel_id=$(cmd_provider_id "$RELEASE_CMD") || true
  [[ -n "$rev_id" ]] || die "cannot resolve reviewer provider identity from REVIEWER_CMD='$REVIEWER_CMD'"
  [[ -n "$rel_id" ]] || die "cannot resolve release provider identity from RELEASE_CMD='$RELEASE_CMD'"

  if [[ "$rev_id" == "$rel_id" ]]; then
    die "RELEASE_CMD must be a third identity distinct from the reviewer (provider=$rev_id REVIEWER_CMD=$REVIEWER_CMD RELEASE_CMD=$RELEASE_CMD)"
  fi
}

# Backward-compatible name: global reviewer/release only. Builder separation is
# enforced against actual selected runners after readiness selection.
assert_three_role_separation() {
  assert_reviewer_release_separation
}

preflight_for_start() {
  local i

  [[ -f "$LOOP_SH" ]] || die "missing loop driver: $LOOP_SH"
  # Direct invocation in do_start requires a regular executable file; -f alone
  # is not enough (a non-executable loop would pass preflight and fail at launch).
  [[ -x "$LOOP_SH" ]] || die "loop driver is not executable: $LOOP_SH"
  # Honest end-to-end contract: selection telemetry JSON serialization and
  # loop.sh timestamp validation both require python3. Refuse before readiness
  # so a missing interpreter cannot pass probes then die at telemetry write.
  # (Process-group wall-timeout may use perl *or* python3; python3 alone covers both.)
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required for fleet runner-selection telemetry and loop-state timestamps (same runtime contract as loop.sh); install python3 or put it on PATH"
  # Global RUNNER is only the default for lanes that omit field 5. When every
  # lane declares an explicit route, do not require the default executable and
  # do not role-check it (builder separation is against actual selected runners).
  if any_lane_uses_global_runner; then
    [[ -n "${RUNNER:-}" ]] || die "runner is empty — needed as default for lane(s) that omit the ordered-route field"
    # Same token shapes as select_lane_runner / persist revalidation — fail
    # closed before PATH/lookup so a malformed global default cannot bypass
    # parse_lane_line (field 5 omitted) and only fail as a vague not-found.
    assert_safe_runner_token "$RUNNER" "global runner (default for lanes omitting ordered route)"
    command -v "$RUNNER" >/dev/null 2>&1 || die "runner '$RUNNER' not found on PATH (used as default for lane(s) without an explicit route)"
  fi
  command -v "$GH_BIN" >/dev/null 2>&1 || die "gh binary '$GH_BIN' not found — install GitHub CLI (https://cli.github.com/) or set GH_BIN"

  assert_reviewer_release_separation

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
  printf '%-10s %-12s %-6s %-8s %-9s %-10s %-10s %-12s %s\n' \
    LANE QUEUE PID HAT HEALTH REQUESTED ACTUAL REASON LAST
  local dead=0 i id queue d pid hat last health
  local req act rreason rhealth statusf route_field
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
    last=$(tail -1 "$(lane_log "$id")" 2>/dev/null | cut -c1-40 || true)

    if [[ ! -d "$d" ]]; then
      health="BASE-GONE"; dead=1
    elif [[ -n "$pid" ]]; then
      health="running"
    elif [[ -f "$d/gibson/HALT" ]]; then
      health="halted"
    else
      health="DEAD"; dead=1
    fi

    # Runner selection status (persisted under log namespace).
    statusf=$(lane_runner_status_file "$id")
    route_field="${LANE_RUNNERS[$i]}"
    if [[ -z "$route_field" ]]; then
      req="$RUNNER"
    else
      req="${route_field%%,*}"
    fi
    act="—"
    rreason="—"
    rhealth="—"
    if [[ -f "$statusf" ]]; then
      req=$(read_runner_status_field "$statusf" "requested_primary" || echo "$req")
      act=$(read_runner_status_field "$statusf" "selected_runner" || echo "—")
      rreason=$(read_runner_status_field "$statusf" "reason" || echo "—")
      rhealth=$(read_runner_status_field "$statusf" "health" || echo "—")
    fi

    printf '%-10s %-12s %-6s %-8s %-9s %-10s %-10s %-12s %s\n' \
      "$id" "$queue" "${pid:-—}" "${hat:-—}" "$health" \
      "${req:-—}" "${act:-—}" "${rhealth:-—}/${rreason:-—}" "${last:-—}"
    i=$((i + 1))
  done
  if [[ $dead -eq 1 ]]; then
    echo
    echo "One or more lanes are down. '$DRIVER_SELF --profile $PROFILE_PATH --start' is idempotent —"
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

# Process-group wall-clock bound: run_with_wall_timeout lives in
# scripts/lib/wall-timeout.sh (sourced at startup). Callers that must not
# inherit stdin pass </dev/null at the call site; the helper forwards the
# already-redirected stdin with `<&0`.

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
  # #141: ordered readiness + selection for every lane before any new launch.
  # Fail closed here ⇒ zero new launches (running lanes left untouched).
  select_all_lane_runners

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

  local i id queue scope intent d issue pid lane_runner
  i=0
  while [[ $i -lt ${#LANE_IDS[@]} ]]; do
    id="${LANE_IDS[$i]}"
    queue="${LANE_QUEUES[$i]}"
    scope="${LANE_SCOPES[$i]}"
    intent="${LANE_INTENTS[$i]}"
    # select_all_lane_runners fills LANE_SELECTED for every lane or dies.
    # Never fall back to the global RUNNER here — that path was neither
    # readiness-probed nor three-role checked when every lane declares a route.
    lane_runner="${LANE_SELECTED[$i]:-}"
    [[ -n "$lane_runner" ]] \
      || die "lane $id: internal — no selected runner recorded before launch (refuse to fall back to the global default)"
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
    # Propagate selection join into loop.sh cost-ledger appends (#141).
    # Local ledger only; no secrets, no fabricated tokens/costs.
    local sel_join sel_pool sel_reason sel_req sel_provider sel_ledger
    sel_join="${LANE_SELECT_JOIN[$i]:-}"
    sel_pool="${LANE_SELECT_POOL[$i]:-unknown}"
    sel_reason="${LANE_SELECT_REASON[$i]:-}"
    sel_req="${LANE_REQUESTED[$i]:-}"
    sel_provider=$(cmd_provider_id "$lane_runner" 2>/dev/null || printf '%s' "$lane_runner")
    sel_ledger=$(fleet_cost_ledger_path)
    # Export three-role cmds so loop.sh hats can shell out.
    if [[ "$FLEET_SYNC_LAUNCH" == "1" ]]; then
      # Deterministic offline path: no background jobs (sensors / CI).
      # GIBSON_COST_TELEMETRY_REQUIRED=1: iteration append failure is degraded
      # (see loop.sh policy), not silent.
      env \
        REVIEWER_CMD="$REVIEWER_CMD" \
        RELEASE_CMD="$RELEASE_CMD" \
        GIBSON_COST_LEDGER="$sel_ledger" \
        GIBSON_COST_POOL="$sel_pool" \
        GIBSON_COST_JOIN_KEY="$sel_join" \
        GIBSON_COST_REQUESTED_RUNNER="$sel_req" \
        GIBSON_COST_FALLBACK_REASON="$sel_reason" \
        GIBSON_COST_PROVIDER="$sel_provider" \
        GIBSON_COST_TELEMETRY_REQUIRED=1 \
        "$LOOP_SH" \
        --runner "$lane_runner" \
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
        GIBSON_COST_LEDGER="$sel_ledger" \
        GIBSON_COST_POOL="$sel_pool" \
        GIBSON_COST_JOIN_KEY="$sel_join" \
        GIBSON_COST_REQUESTED_RUNNER="$sel_req" \
        GIBSON_COST_FALLBACK_REASON="$sel_reason" \
        GIBSON_COST_PROVIDER="$sel_provider" \
        GIBSON_COST_TELEMETRY_REQUIRED=1 \
        "$LOOP_SH" \
        --runner "$lane_runner" \
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
  info "fleet up. status: $DRIVER_SELF --profile $PROFILE_PATH --status"
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
