#!/usr/bin/env bash
# loop.sh — solo-loop driver (docs/11)
set -euo pipefail

usage() {
  cat <<'EOF'
loop.sh — drive the solo SDLC loop (one hat, fresh context, file state)

WHAT IT DOES
  For a target repo: check kill switch, read/update gibson/loop-state.md,
  render playbooks/loop-step.md with {{hat}} and {{loop_state}}, invoke the
  chosen runner headless, enforce error budget, append journal, optional MC
  heartbeat.

WHY
  Context resets beat compaction (docs/11). The driver is a disciplined Ralph
  loop with gates — persistence without self-grading.

RISKS
  - Unattended runs spend tokens / subscription quota (Grok flat-rate preferred).
  - Can open PRs and push when the runner has write permission.
  - Stop with the gibson/HALT file or GIBSON_HALT=1 env (checked unconditionally).
    When gh is available and origin's host matches GH_HOST (default github.com;
    set GH_HOST for GitHub Enterprise), the driver also honors two remote kill
    paths on a bounded cadence (every iteration with --once; every
    GIBSON_REMOTE_HALT_INTERVAL iterations in a hot loop, default 3): an open
    issue with the gibson-halt label, or a .gibson-halt sentinel on the remote
    default branch. Either journals the halt once (persistent latch under
    gibson/halt-latch so launchd KeepAlive relaunches do not spam the journal),
    leaves loop-state untouched, and suppresses supervisor handoffs. A
    previously confirmed remote halt stays fail-closed across API outages until
    a successful recheck positively clears both remote paths. First-ever API
    failure (no latch yet) still fails open to local checks. Non-GitHub/
    unparseable origins never query gh against unrelated same-slug repos.
  - Error budget (default 5 consecutive failures) stops the loop to avoid burn.
  - --escalate-after dispatches other vendors: more tokens, other providers see
    the diff. Its verdicts go to gibson/second-opinion.md, which is the stall
    artifact the next hat reads; the routine review before every supervisor
    handoff is a separate file, gibson/pre-handoff-review.md, so neither
    overwrites the other. --supervisor devin sends finished branches to a cloud
    session that can open PRs and (if configured) merge (docs/22). When a
    supervisor is configured, a distinct-vendor second opinion of the exact
    handed-off SHA is required before handoff, and the gate fails closed: no
    review, no handoff. The branch stays queued in loop-state instead (Law 5).
  - Reviews and handoffs diff against the target repo's own default branch. When
    an origin is configured, both the branch name and its exact tip come from the
    remote (stale local refs are not trusted); a local-only repo falls back to a
    verified local main/master. The review is pinned to that base SHA as well as
    to the head SHA, so a base that advances invalidates the receipt. A repo whose
    base cannot be resolved or confirmed blocks the handoff rather than guessing.
    Likewise a supervisor handoff requires the BRANCH to exist on the remote:
    a repo with no origin, and a branch that was never pushed, are both blocked
    before the review is spent — the supervisor opens the PR from the remote
    branch, so a local-only ref is nothing it can act on.
  - The review receipt is an operational control, not a security boundary. It is
    a plain file under <repo>/gibson/, so anything running as the same user —
    including the agents the gate constrains — can write it. Isolating it from
    them is a separate hardening concern (docs/22).

USAGE
  loop.sh --runner <grok|hermes|claude|codex> --repo <path> [options]
  loop.sh --help

OPTIONS
  --runner NAME       runtime CLI (required)
  --repo PATH         target repository path (required)
  --gibson PATH       Gibson clone (default: parent of this script)
  --once              single iteration then exit
  --print-prompt      render prompt only (no runner)
  --max-iterations N  cap iterations (default: unlimited until halt)
  --error-budget N    consecutive failures before stop (default: 5)
  --hat HAT           force starting hat (default: from loop-state or builder)
  --dry-run           show actions without invoking runner
  --escalate-after N  after N consecutive failures, get a cross-vendor second
                      opinion before the error budget runs out (default: off)
  --reviewers LIST    vendors for that second opinion (default: codex,claude)
  --supervisor NAME   'devin' hands finished branches to the cloud supervisor
                      whenever loop-state carries a `handoff:` field (docs/22).
                      Each handoff is gated on a fresh distinct-vendor review of
                      the exact SHA being handed off; a failed review blocks it.

ENV
  GIBSON_HALT=1                 local kill switch (always honored)
  GIBSON_REMOTE_HALT_INTERVAL   re-check remote label/sentinel every N iterations
                                (default: 1 with --once, 3 for hot loops). A halt
                                is still detected within N iterations. The loop
                                process caches live results across its own
                                iteration-top / pre-handoff checks; the child
                                devin-supervisor.sh deliberately rechecks live
                                (may spend another pair of gh calls) and exits 75
                                on kill-switch refusal so the driver journals a
                                halt, not a supervisor rejection.
  GH_HOST                       GitHub host for remote halt (default github.com).
                                Only origins on this host enable gh remote-halt
                                queries (set for GitHub Enterprise).

EXAMPLES
  ./scripts/loop.sh --runner grok --repo ~/Code/acme-app
  ./scripts/loop.sh --runner grok --repo ~/Code/acme-app --once --print-prompt
  ./scripts/loop.sh --runner claude --repo ~/Code/acme-app --hat reviewer --once
  ./scripts/loop.sh --runner grok --repo ~/Code/acme-app \
      --escalate-after 2 --reviewers codex,claude --supervisor devin
EOF
}

RUNNER=""
REPO=""
GIBSON=""
ONCE=0
PRINT=0
MAX=-1
BUDGET=5
FORCE_HAT=""
DRY=0
ESCALATE_AFTER=0
REVIEWERS="codex,claude"
SUPERVISOR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --runner) RUNNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --gibson) GIBSON="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --print-prompt) PRINT=1; shift ;;
    --max-iterations) MAX="$2"; shift 2 ;;
    --error-budget) BUDGET="$2"; shift 2 ;;
    --hat) FORCE_HAT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --escalate-after) ESCALATE_AFTER="$2"; shift 2 ;;
    --reviewers) REVIEWERS="$2"; shift 2 ;;
    --supervisor) SUPERVISOR="$2"; shift 2 ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "loop.sh: ERROR: $*" >&2; exit 1; }
info() { echo "loop.sh: $*" >&2; }

[[ -n "$RUNNER" ]] || { usage; exit 2; }
[[ -n "$REPO" ]] || { usage; exit 2; }
[[ -d "$REPO" ]] || die "repo not a directory: $REPO"

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
GIBSON="${GIBSON:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLAYBOOK="$GIBSON/playbooks/loop-step.md"
[[ -f "$PLAYBOOK" ]] || die "missing $PLAYBOOK"

STATE_DIR="$REPO/gibson"
STATE_FILE="$STATE_DIR/loop-state.md"
JOURNAL="$STATE_DIR/journal.md"
HALT_FILE="$STATE_DIR/HALT"
# Persistent runtime latch (issue #71 KeepAlive / relaunch safety). Not a tracked
# Gibson source file — lives only under the target repo's gibson/ state dir.
# Records source + reason so (a) journal halt sections are not duplicated on
# every launchd relaunch while the stop is still active, and (b) a confirmed
# remote halt remains fail-closed when a later GitHub recheck is degraded.
HALT_LATCH_FILE="$STATE_DIR/halt-latch"
# Two review artifacts, two meanings, two paths — they are not interchangeable.
#
#   gibson/second-opinion.md    the ESCALATION/stall artifact. Written by escalate()
#                               after N consecutive runner failures, and the file
#                               playbooks/loop-step.md tells the next hat to read
#                               before its build hat.
#   gibson/pre-handoff-review.md
#                               the ROUTINE mandatory pre-handoff review. Written by
#                               ensure_cross_vendor_review before every supervisor
#                               handoff, and the file handed to the supervisor.
#
# They shared one path, so a routine handoff review silently overwrote the stall
# review the next hat had been sent to read: the agent opened the file expecting
# "here is why your loop kept failing" and got a review of a green branch instead.
# Both are second opinions; only one of them is the escalation.
REVIEW_ARTIFACT="$STATE_DIR/second-opinion.md"
PRE_HANDOFF_REVIEW="$STATE_DIR/pre-handoff-review.md"
# Written only by a successful pre-handoff review, and it names both endpoints of
# the diff that was reviewed — base branch/base SHA and head branch/head SHA — see
# ensure_cross_vendor_review. The receipt attests to $PRE_HANDOFF_REVIEW, and its
# filename says so: it has nothing to do with the escalation artifact above.
REVIEW_RECEIPT="$STATE_DIR/pre-handoff-review.receipt"

# Iteration counter (also drives remote-halt cadence). Starts at 0 so the first
# loop top and the pre-state startup check share the same "iteration 0" slot.
iter=0
failures=0

# Remote halt cadence (issue #71). --once always re-checks every iteration;
# hot loops default to every 3 so a phone label still lands within a few steps
# without burning a pair of API calls on every single hat. Override with
# GIBSON_REMOTE_HALT_INTERVAL. The in-process cache is shared by iteration-top
# and supervisor_handoff's pre-check; the child process still does its own
# fresh live recheck (see kill-switch exit 75 below).
if [[ -n "${GIBSON_REMOTE_HALT_INTERVAL:-}" ]]; then
  REMOTE_HALT_INTERVAL="$GIBSON_REMOTE_HALT_INTERVAL"
elif [[ "$ONCE" -eq 1 ]]; then
  REMOTE_HALT_INTERVAL=1
else
  REMOTE_HALT_INTERVAL=3
fi
# Accept digits only; non-numeric and non-positive values would disable the
# remote stop, so clamp to at least 1. Normalize as base-10 before any
# arithmetic/comparison: Bash treats leading-zero strings as octal, so a
# value like 08 passes the digit check but then dies with "value too great
# for base" at [[ -lt ]] / $((...)) and the cache never hits (polls every
# iteration). 10# forces decimal so 08 → 8 and 09 → 9.
if ! [[ "$REMOTE_HALT_INTERVAL" =~ ^[0-9]+$ ]]; then
  REMOTE_HALT_INTERVAL=1
else
  REMOTE_HALT_INTERVAL=$((10#$REMOTE_HALT_INTERVAL))
  if [[ "$REMOTE_HALT_INTERVAL" -lt 1 ]]; then
    REMOTE_HALT_INTERVAL=1
  fi
fi

# Kill switch (issue #55 local paths + issue #71 remote paths).
#
# Local (always, no network):
#   - gibson/HALT file
#   - GIBSON_HALT=1
#
# Remote (read-only, cached for REMOTE_HALT_INTERVAL iterations within this
# process — checked at iteration top and reused by the pre-handoff gate so the
# loop itself does not double-poll in the same cadence window):
#   - open issue carrying the gibson-halt label
#   - .gibson-halt sentinel committed on the remote default branch
# Only when origin's host matches GH_HOST (default github.com). GitLab/
# Bitbucket/other hosts and unparseable origins never query gh (would hit an
# unrelated same-named github.com repo); they fail open with an explicit
# disabled warning once per live check.
#
# Network/API failure:
#   - First-ever (no remote latch yet): fails OPEN to the local checks so a
#     GitHub outage does not brick every project, with a "degraded" warning.
#   - After a confirmed remote halt has been latched under gibson/halt-latch:
#     fails CLOSED until a successful recheck positively clears both remote
#     paths on the SAME host+slug that was latched. launchd KeepAlive must
#     not resume work just because the recheck hit rate limiting, and changing
#     origin to a clear repo must not clear a latch from another source.
#
# Journaling is once-per-activation via the same latch: relaunches while the
# stop is still active do not append duplicate "## … · halt" sections. The
# read/decide/journal/latch transition is cross-process locked so concurrent
# launches wait and observe the first latch (or fail closed) rather than race.
#
# A remote halt leaves loop-state untouched (no default state created, no
# rewrite of an existing one). Supervisor handoffs are suppressed. The child
# devin-supervisor.sh deliberately rechecks live (by-hand safety; may spend
# another pair of gh calls) and exits 75 on kill-switch refusal so a mid-
# cadence halt is journaled as a halt, not "supervisor rejected".

# Conservative GitHub owner / repo segment validation before any gh/API path
# interpolation. Rejects exact "." / ".." and anything outside a narrow character
# set (including percent-encoding) so a hostile remote.origin.url cannot walk
# relative path segments into repos/${slug}/contents/... endpoints.
# Valid leading-dot repo names (notably owner/.github) are allowed; only the
# exact dot segments are banned for repos.
origin_segment_ok() {
  local kind="$1" seg="$2"
  case "$seg" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  if [[ "$kind" == "owner" ]]; then
    # Owners/orgs: alnum + hyphen only; no leading/trailing hyphen; no dots.
    case "$seg" in
      *.*|*_*|-*|*-) return 1 ;;
    esac
    [[ "$seg" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ || "$seg" =~ ^[A-Za-z0-9]$ ]]
    return $?
  fi
  # Repos: alnum + . _ - including leading-dot names like .github.
  # Exact "." / ".." already rejected above.
  [[ "$seg" =~ ^[A-Za-z0-9._-]+$ ]]
  return $?
}

# Parse host + owner/repo from a git remote URL. Supports:
#   https://github.com/owner/repo.git
#   https://github.com/owner/repo.git/   (trailing slash before/after .git)
#   git@github.com:owner/repo.git
#   ssh://git@github.com/owner/repo.git
# Uses remote.origin.url (not get-url) so url.*.insteadOf rewrites used in tests
# and some operators' SSH helpers do not hide the logical GitHub slug.
# Sets ORIGIN_PARSE_HOST and ORIGIN_PARSE_SLUG (empty when unparseable).
# Does not gate on GH_HOST — callers that talk to gh must compare the host.
origin_parse_url() {
  local url="$1" rest host owner name
  ORIGIN_PARSE_HOST=""
  ORIGIN_PARSE_SLUG=""
  [[ -n "$url" ]] || return 0
  # Trailing slashes first, then .git, then any slash left after stripping .git
  # so …/repo.git/ becomes …/repo (not …/repo.git as a bogus two-segment slug).
  while [[ "$url" == */ ]]; do
    url="${url%/}"
  done
  url="${url%.git}"
  while [[ "$url" == */ ]]; do
    url="${url%/}"
  done
  case "$url" in
    git@*:*)
      # scp-like: git@host:owner/repo
      rest="${url#git@}"
      host="${rest%%:*}"
      rest="${rest#*:}"
      ;;
    ssh://*|https://*|http://*|git://*)
      # scheme://[userinfo@]host[:port]/owner/repo
      rest="${url#*://}"
      if [[ "$rest" == *@* ]]; then
        rest="${rest#*@}"
      fi
      host="${rest%%/*}"
      rest="${rest#*/}"
      # Drop optional :port from host
      host="${host%%:*}"
      ;;
    *)
      return 0
      ;;
  esac
  # Exactly two path segments (owner/repo). Reject schemes that survived, ports,
  # deeper paths, or relative/dot segments — a bad slug would silently blind
  # both remote checks or walk relative path segments into API paths.
  case "$rest" in
    ''|*/*/*|*:*|*[[:space:]]*|/*) return 0 ;;
    */*)
      owner="${rest%%/*}"
      name="${rest#*/}"
      origin_segment_ok owner "$owner" || return 0
      origin_segment_ok repo "$name" || return 0
      ORIGIN_PARSE_HOST="$host"
      ORIGIN_PARSE_SLUG="${owner}/${name}"
      ;;
  esac
}

# owner/repo only (any host). Empty when unparseable. Cosmetic callers may use
# this; remote-halt callers must also validate the host against GH_HOST.
origin_slug_from_url() {
  origin_parse_url "$1"
  [[ -n "$ORIGIN_PARSE_SLUG" ]] && printf '%s\n' "$ORIGIN_PARSE_SLUG"
  return 0
}

origin_slug() {
  local url
  url=$(git -C "$REPO" config --get remote.origin.url 2>/dev/null) || true
  origin_slug_from_url "$url"
}

# Resolve the slug for remote-halt gh queries only when origin host matches
# GH_HOST (default github.com). Sets ORIGIN_HALT_SLUG or ORIGIN_HALT_SKIP_REASON
# (and leaves slug empty). Used by remote_halted_live so warnings fire once per
# live check, not from pure helpers.
origin_remote_halt_slug() {
  local url expected got
  ORIGIN_HALT_SLUG=""
  ORIGIN_HALT_SKIP_REASON=""
  url=$(git -C "$REPO" config --get remote.origin.url 2>/dev/null) || true
  if [[ -z "$url" ]]; then
    ORIGIN_HALT_SKIP_REASON="no origin remote URL configured"
    return 1
  fi
  origin_parse_url "$url"
  if [[ -z "$ORIGIN_PARSE_SLUG" || -z "$ORIGIN_PARSE_HOST" ]]; then
    ORIGIN_HALT_SKIP_REASON="origin URL unparseable as host/owner/repo (got url=${url})"
    return 1
  fi
  expected=$(printf '%s' "${GH_HOST:-github.com}" | tr '[:upper:]' '[:lower:]')
  got=$(printf '%s' "$ORIGIN_PARSE_HOST" | tr '[:upper:]' '[:lower:]')
  if [[ "$got" != "$expected" ]]; then
    ORIGIN_HALT_SKIP_REASON="origin host '${ORIGIN_PARSE_HOST}' does not match GH_HOST (${GH_HOST:-github.com}); remote stop is GitHub-only"
    return 1
  fi
  ORIGIN_HALT_SLUG="$ORIGIN_PARSE_SLUG"
  return 0
}

# Default branch name as origin currently advertises via symbolic HEAD.
# Empty / non-zero when origin is missing or unreachable — callers treat that
# as "remote check degraded", not as a halt.
remote_default_branch() {
  local symref name
  if ! symref=$(git -C "$REPO" ls-remote --symref origin HEAD 2>/dev/null); then
    return 1
  fi
  name=$(printf '%s\n' "$symref" |
    awk '$1 == "ref:" && $3 == "HEAD" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
}

# Cache: empty = never checked; "halted" / "clear"; checked_at is the iter of
# the last live poll. In-process only: supervisor_handoff reuses it so the loop
# does not double-poll, but the child process always rechecks live.
_REMOTE_HALT_CACHE=""
_REMOTE_HALT_CHECKED_AT=-999999
HALT_REASON=""
# Which latch side was observed this call (local|remote) and whether a fresh
# journal section is needed (1) or this activation was already journaled (0).
HALT_LATCH_SIDE=""
HALT_SHOULD_JOURNAL=1
# Live poll outcome when remote_halted_live returns nonzero:
#   clear | degraded | disabled  (empty until a live poll runs)
REMOTE_HALT_STATUS=""
REMOTE_HALT_KIND=""

# --- Persistent halt latch (gibson/halt-latch) --------------------------------
# local_kind=file|env, remote_kind=label|sentinel|confirmed
# remote_host + remote_slug bind a remote latch to the exact origin that
# confirmed it — only that host+slug may positively clear; a changed/missing
# source stays fail-closed and never queries a different repo.
# journaled flags suppress KeepAlive relaunch spam; remote kind keeps
# fail-closed across degraded rechecks until a positive same-source clear.
#
# Cross-process lock serializes read/decide/journal/latch so concurrent launches
# cannot double-journal or race past a halt.
#
# Ownership is published indivisibly: complete pid+owner token is written to a
# process-unique temp file, then the lock path is acquired with `ln temp lock`
# (atomic hard-link publish on the same filesystem). Observers never see a lock
# file without complete ownership data. Release removes the lock only when it
# still carries this process's exact owner token, so a late EXIT from a former
# owner cannot delete a successor's lock.

HALT_LOCK_FILE="$STATE_DIR/halt-lock"
HALT_LOCK_HELD=0
HALT_LOCK_OWNER=""
HALT_LOCK_TMP=""

# Read a key=value field from the lock file. Returns 1 if missing/unreadable.
halt_lock_field() {
  local key="$1" file="${2:-$HALT_LOCK_FILE}" line
  [[ -f "$file" ]] || return 1
  line=$(grep -E "^${key}=" "$file" 2>/dev/null | head -n 1) || true
  [[ -n "$line" ]] || return 1
  printf '%s' "${line#*=}"
}

# Drop the lock only if we still own it (exact owner token match). Always
# scrubs this process's temp scratch. Safe to call when not held.
halt_lock_release() {
  local cur_owner
  if [[ -n "${HALT_LOCK_TMP:-}" ]]; then
    rm -f "$HALT_LOCK_TMP" 2>/dev/null || true
    HALT_LOCK_TMP=""
  fi
  if [[ "${HALT_LOCK_HELD:-0}" -ne 1 ]]; then
    return 0
  fi
  HALT_LOCK_HELD=0
  if [[ -n "${HALT_LOCK_OWNER:-}" && -f "$HALT_LOCK_FILE" ]]; then
    cur_owner=$(halt_lock_field owner) || cur_owner=""
    if [[ "$cur_owner" == "$HALT_LOCK_OWNER" ]]; then
      rm -f "$HALT_LOCK_FILE"
    fi
  fi
  HALT_LOCK_OWNER=""
}

# Reclaim a dead or malformed lock without racing a live successor.
# Removes only when the on-disk content still matches what we classified as
# stale (token match for dead owners; full snapshot match for malformed).
halt_lock_try_reclaim_stale() {
  local owner pid snap cur_owner
  # Legacy directory form from older builds: reclaim empty/dead dirs so an
  # upgraded process is not permanently blocked by a leftover halt-lock/.
  if [[ -d "$HALT_LOCK_FILE" ]]; then
    if [[ -f "${HALT_LOCK_FILE}/pid" ]]; then
      pid=$(cat "${HALT_LOCK_FILE}/pid" 2>/dev/null || true)
      if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        rm -f "${HALT_LOCK_FILE}/pid" 2>/dev/null || true
        rmdir "$HALT_LOCK_FILE" 2>/dev/null || true
      fi
    else
      rmdir "$HALT_LOCK_FILE" 2>/dev/null || true
    fi
    return 0
  fi
  [[ -f "$HALT_LOCK_FILE" ]] || return 0

  owner=$(halt_lock_field owner) || owner=""
  pid=$(halt_lock_field pid) || pid=""

  if [[ -z "$owner" || -z "$pid" ]] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    # Malformed / incomplete: delete only if content is unchanged (no successor).
    snap=$(cat "$HALT_LOCK_FILE" 2>/dev/null || true)
    if [[ "$(cat "$HALT_LOCK_FILE" 2>/dev/null || true)" == "$snap" ]]; then
      owner=$(halt_lock_field owner) || owner=""
      pid=$(halt_lock_field pid) || pid=""
      if [[ -z "$owner" || -z "$pid" ]] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        rm -f "$HALT_LOCK_FILE"
      fi
    fi
    return 0
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    # Dead owner — remove only if the same owner token is still published.
    cur_owner=$(halt_lock_field owner) || cur_owner=""
    if [[ "$cur_owner" == "$owner" ]]; then
      rm -f "$HALT_LOCK_FILE"
    fi
  fi
}

# Acquire exclusive halt transition lock. Wait for peers (ordinary launchd is
# uncontended and returns immediately). Steal only when the owner is dead or
# the lock is malformed. Returns 1 after a bounded wait so a stuck lock fails
# closed (no work).
halt_lock_acquire() {
  local tries=0 max_tries=400 tmp owner_token
  mkdir -p "$STATE_DIR" || return 1
  while [[ $tries -lt $max_tries ]]; do
    tmp=$(mktemp "${STATE_DIR}/.halt-lock.XXXXXX") || return 1
    HALT_LOCK_TMP="$tmp"
    # Unique per attempt: pid + mktemp basename (portable on Bash 3.2 / macOS).
    owner_token="$$.${tmp##*/}"
    # Write complete ownership BEFORE publication — never publish an empty lock.
    if ! {
      printf 'pid=%s\n' "$$"
      printf 'owner=%s\n' "$owner_token"
    } > "$tmp"; then
      rm -f "$tmp"
      HALT_LOCK_TMP=""
      return 1
    fi
    # Atomic acquire: hard-link the complete temp onto the lock path. If the
    # link succeeds, every observer sees full pid+owner data; if it fails, the
    # lock already exists with someone else's complete record.
    if ln "$tmp" "$HALT_LOCK_FILE" 2>/dev/null; then
      rm -f "$tmp"
      HALT_LOCK_TMP=""
      HALT_LOCK_OWNER="$owner_token"
      HALT_LOCK_HELD=1
      return 0
    fi
    rm -f "$tmp"
    HALT_LOCK_TMP=""
    halt_lock_try_reclaim_stale
    # ~50ms; fall back to 1s if fractional sleep is unavailable.
    sleep 0.05 2>/dev/null || sleep 1
    tries=$((tries + 1))
  done
  return 1
}

# Ensure lock is dropped on abnormal exit while held (token-checked release).
if [[ -z "${_GIBSON_HALT_LOCK_TRAP:-}" ]]; then
  _GIBSON_HALT_LOCK_TRAP=1
  trap 'halt_lock_release' EXIT
fi

halt_latch_field() {
  local key="$1" line
  [[ -f "$HALT_LATCH_FILE" ]] || return 0
  line=$(grep -E "^${key}=" "$HALT_LATCH_FILE" 2>/dev/null | head -n 1) || true
  [[ -n "$line" ]] || return 0
  printf '%s' "${line#*=}"
}

halt_latch_load() {
  LATCH_LOCAL_KIND=$(halt_latch_field local_kind)
  LATCH_LOCAL_REASON=$(halt_latch_field local_reason)
  LATCH_LOCAL_JOURNALED=$(halt_latch_field local_journaled)
  LATCH_REMOTE_KIND=$(halt_latch_field remote_kind)
  LATCH_REMOTE_REASON=$(halt_latch_field remote_reason)
  LATCH_REMOTE_JOURNALED=$(halt_latch_field remote_journaled)
  LATCH_REMOTE_HOST=$(halt_latch_field remote_host)
  LATCH_REMOTE_SLUG=$(halt_latch_field remote_slug)
  LATCH_LOCAL_KIND=${LATCH_LOCAL_KIND:-}
  LATCH_LOCAL_REASON=${LATCH_LOCAL_REASON:-}
  LATCH_LOCAL_JOURNALED=${LATCH_LOCAL_JOURNALED:-0}
  LATCH_REMOTE_KIND=${LATCH_REMOTE_KIND:-}
  LATCH_REMOTE_REASON=${LATCH_REMOTE_REASON:-}
  LATCH_REMOTE_JOURNALED=${LATCH_REMOTE_JOURNALED:-0}
  LATCH_REMOTE_HOST=${LATCH_REMOTE_HOST:-}
  LATCH_REMOTE_SLUG=${LATCH_REMOTE_SLUG:-}
}

halt_latch_save() {
  mkdir -p "$STATE_DIR"
  if [[ -z "${LATCH_LOCAL_KIND:-}" && -z "${LATCH_REMOTE_KIND:-}" ]]; then
    rm -f "$HALT_LATCH_FILE"
    return 0
  fi
  local tmp
  tmp=$(mktemp "${STATE_DIR}/halt-latch.XXXXXX")
  {
    printf 'local_kind=%s\n' "${LATCH_LOCAL_KIND:-}"
    printf 'local_reason=%s\n' "${LATCH_LOCAL_REASON:-}"
    printf 'local_journaled=%s\n' "${LATCH_LOCAL_JOURNALED:-0}"
    printf 'remote_kind=%s\n' "${LATCH_REMOTE_KIND:-}"
    printf 'remote_reason=%s\n' "${LATCH_REMOTE_REASON:-}"
    printf 'remote_journaled=%s\n' "${LATCH_REMOTE_JOURNALED:-0}"
    printf 'remote_host=%s\n' "${LATCH_REMOTE_HOST:-}"
    printf 'remote_slug=%s\n' "${LATCH_REMOTE_SLUG:-}"
    printf 'updated_at=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } > "$tmp"
  mv -f "$tmp" "$HALT_LATCH_FILE"
}

# True when the current remote-halt origin (GH_HOST-validated host + slug)
# exactly matches the host+slug stored on the remote latch. Missing latch
# fields, unparseable/mismatched origins, or host changes all return false.
remote_latch_source_matches() {
  local cur_host cur_slug lat_host lat_slug
  if [[ -z "${LATCH_REMOTE_HOST:-}" || -z "${LATCH_REMOTE_SLUG:-}" ]]; then
    return 1
  fi
  if ! origin_remote_halt_slug; then
    return 1
  fi
  cur_host=$(printf '%s' "${ORIGIN_PARSE_HOST:-}" | tr '[:upper:]' '[:lower:]')
  cur_slug="${ORIGIN_HALT_SLUG:-}"
  lat_host=$(printf '%s' "$LATCH_REMOTE_HOST" | tr '[:upper:]' '[:lower:]')
  lat_slug="$LATCH_REMOTE_SLUG"
  [[ -n "$cur_host" && -n "$cur_slug" && "$cur_host" == "$lat_host" && "$cur_slug" == "$lat_slug" ]]
}

# Fail-closed reason when a remote latch exists but current origin cannot
# prove it is the same host+slug (changed, missing, unparseable, incomplete).
remote_latch_source_mismatch_reason() {
  local latched_src current_src
  latched_src="${LATCH_REMOTE_HOST:-unknown}/${LATCH_REMOTE_SLUG:-unknown}"
  if origin_remote_halt_slug 2>/dev/null; then
    current_src="${ORIGIN_PARSE_HOST:-?}/${ORIGIN_HALT_SLUG:-?}"
  else
    current_src="missing/unparseable/non-matching (${ORIGIN_HALT_SKIP_REASON:-no detail})"
  fi
  printf '%s' "remote halt: previously confirmed remote kill switch still latched for ${latched_src}, but current origin is ${current_src} — stopping without querying a different repo. Restore origin to ${latched_src} and clear the remote stop successfully, or after operator verification explicitly remove gibson/halt-latch."
}

# Observe a still-active local stop. Sets HALT_REASON / HALT_SHOULD_JOURNAL /
# HALT_LATCH_SIDE. Clears the local latch only when the stop is gone (callers
# invoke halt_latch_clear_local when neither file nor env is active).
halt_latch_observe_local() {
  local kind="$1" reason="$2"
  halt_latch_load
  HALT_REASON="$reason"
  HALT_LATCH_SIDE="local"
  if [[ "$LATCH_LOCAL_KIND" == "$kind" && "$LATCH_LOCAL_JOURNALED" == "1" ]]; then
    HALT_SHOULD_JOURNAL=0
  else
    HALT_SHOULD_JOURNAL=1
    LATCH_LOCAL_KIND="$kind"
    LATCH_LOCAL_REASON="$reason"
    LATCH_LOCAL_JOURNALED=0
    halt_latch_save
  fi
}

halt_latch_clear_local() {
  halt_latch_load
  if [[ -z "$LATCH_LOCAL_KIND" ]]; then
    return 0
  fi
  LATCH_LOCAL_KIND=""
  LATCH_LOCAL_REASON=""
  LATCH_LOCAL_JOURNALED=0
  halt_latch_save
}

# Observe a remote stop on the given host+slug (required). Only that source
# may later positively clear this latch.
halt_latch_observe_remote() {
  local kind="$1" reason="$2" host="${3:-}" slug="${4:-}"
  local lh ls nh
  halt_latch_load
  HALT_REASON="$reason"
  HALT_LATCH_SIDE="remote"
  if [[ -n "$LATCH_REMOTE_KIND" && "$LATCH_REMOTE_JOURNALED" == "1" \
        && -n "$LATCH_REMOTE_HOST" && -n "$LATCH_REMOTE_SLUG" \
        && -n "$host" && -n "$slug" ]]; then
    lh=$(printf '%s' "$LATCH_REMOTE_HOST" | tr '[:upper:]' '[:lower:]')
    ls="$LATCH_REMOTE_SLUG"
    nh=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    if [[ "$lh" == "$nh" && "$ls" == "$slug" ]]; then
      # Still-active same-source remote stop already journaled.
      HALT_SHOULD_JOURNAL=0
      # Refresh kind/reason when we have a fresher live observation.
      if [[ -n "$kind" && "$kind" != "confirmed" ]]; then
        LATCH_REMOTE_KIND="$kind"
        LATCH_REMOTE_REASON="$reason"
        halt_latch_save
      fi
      return 0
    fi
  fi
  HALT_SHOULD_JOURNAL=1
  LATCH_REMOTE_KIND="${kind:-confirmed}"
  LATCH_REMOTE_REASON="$reason"
  LATCH_REMOTE_JOURNALED=0
  LATCH_REMOTE_HOST="$host"
  LATCH_REMOTE_SLUG="$slug"
  halt_latch_save
}

halt_latch_clear_remote() {
  halt_latch_load
  if [[ -z "$LATCH_REMOTE_KIND" ]]; then
    return 0
  fi
  LATCH_REMOTE_KIND=""
  LATCH_REMOTE_REASON=""
  LATCH_REMOTE_JOURNALED=0
  LATCH_REMOTE_HOST=""
  LATCH_REMOTE_SLUG=""
  halt_latch_save
}

# After a journal section is written, mark the observed side journaled so
# KeepAlive relaunches skip the duplicate.
halt_latch_mark_journaled() {
  halt_latch_load
  case "${HALT_LATCH_SIDE:-}" in
    local)
      LATCH_LOCAL_JOURNALED=1
      halt_latch_save
      ;;
    remote)
      LATCH_REMOTE_JOURNALED=1
      halt_latch_save
      ;;
    *)
      # Exit-75 / generic path: mark whichever sides are present and unjournaled.
      local changed=0
      if [[ -n "$LATCH_LOCAL_KIND" && "$LATCH_LOCAL_JOURNALED" != "1" ]]; then
        LATCH_LOCAL_JOURNALED=1
        changed=1
      fi
      if [[ -n "$LATCH_REMOTE_KIND" && "$LATCH_REMOTE_JOURNALED" != "1" ]]; then
        LATCH_REMOTE_JOURNALED=1
        changed=1
      fi
      if [[ "$changed" -eq 1 ]]; then
        halt_latch_save
      fi
      ;;
  esac
}

# Live remote poll (no cache). Sets HALT_REASON + REMOTE_HALT_KIND on a positive
# hit (return 0). On non-hit sets REMOTE_HALT_STATUS to clear|degraded|disabled
# and returns 1. Callers combine this with the persistent remote latch.
remote_halted_live() {
  REMOTE_HALT_STATUS=""
  REMOTE_HALT_KIND=""
  if ! command -v gh >/dev/null 2>&1; then
    REMOTE_HALT_STATUS="degraded"
    return 1
  fi
  local slug out ec def_branch label_degraded=0
  if ! origin_remote_halt_slug; then
    # Once per live check (this function), not per helper call — unparseable or
    # non-GH_HOST origins must not silently disable the phone stop.
    info "remote halt check disabled: ${ORIGIN_HALT_SKIP_REASON} — continuing with local HALT/GIBSON_HALT only (zero gh remote-halt queries)"
    REMOTE_HALT_STATUS="disabled"
    return 1
  fi
  slug="$ORIGIN_HALT_SLUG"

  # 1) gibson-halt label on any open issue (live poll; removal lets a fresh
  #    launch run because this is re-checked on cadence, not process-start-only).
  set +e
  out=$(gh issue list --repo "$slug" \
    --label gibson-halt --state open --limit 1 \
    --json number -q '.[0].number' 2>&1)
  ec=$?
  set -e
  if [[ $ec -ne 0 ]]; then
    # Missing/forbidden/wrong repo usually lands here. Preserve this degraded
    # evidence; do not let a later sentinel 404 present a trustworthy "clear".
    label_degraded=1
    info "remote halt check degraded: gibson-halt label query failed (gh exit $ec) — continuing with local HALT/GIBSON_HALT only; fix gh auth/network to restore the remote stop"
  elif printf '%s' "$out" | grep -q '[0-9]'; then
    REMOTE_HALT_KIND="label"
    HALT_REASON="remote halt: gibson-halt label on an open issue — stopping (remove the label to allow a fresh launch, or write gibson/HALT to make permanent)"
    info "$HALT_REASON"
    REMOTE_HALT_STATUS="halted"
    return 0
  fi

  # 2) .gibson-halt sentinel on the remote default branch (phone-friendly:
  #    commit the empty file to main from any device with GitHub access).
  # Pass the ref as an encoded request parameter — never interpolate into ?ref=
  # (branch names may contain #, &, ?, etc. which would be treated as URL syntax
  # and check the wrong ref or a truncated one).
  if ! def_branch=$(remote_default_branch); then
    info "remote halt check degraded: could not resolve origin default branch — continuing with local HALT/GIBSON_HALT only"
    REMOTE_HALT_STATUS="degraded"
    return 1
  fi
  set +e
  out=$(gh api --method GET "repos/${slug}/contents/.gibson-halt" \
    -f "ref=${def_branch}" 2>&1)
  ec=$?
  set -e
  if [[ $ec -eq 0 ]]; then
    REMOTE_HALT_KIND="sentinel"
    HALT_REASON="remote halt: .gibson-halt sentinel on origin/${def_branch} — stopping (delete the file from the default branch to allow a fresh launch)"
    info "$HALT_REASON"
    REMOTE_HALT_STATUS="halted"
    return 0
  fi
  # 404 Not Found = no sentinel only when the repo was already proven reachable
  # by a successful label query. If the label query was degraded, a 404 is not
  # trustworthy clear (private/wrong/missing repo often 404s too).
  if printf '%s' "$out" | grep -Eqi 'Not Found|"status"[[:space:]]*:[[:space:]]*"?404'; then
    if [[ "$label_degraded" -eq 1 ]]; then
      REMOTE_HALT_STATUS="degraded"
      return 1
    fi
    REMOTE_HALT_STATUS="clear"
    return 1
  fi
  info "remote halt check degraded: .gibson-halt sentinel query failed (gh exit $ec) — continuing with local HALT/GIBSON_HALT only; fix gh auth/network to restore the remote stop"
  REMOTE_HALT_STATUS="degraded"
  return 1
}

# True when a remote halt path is active. Honors REMOTE_HALT_INTERVAL cache and
# the persistent remote latch (fail-closed after a prior confirmation; source-
# bound so only the same host+slug may positively clear).
remote_halted() {
  local age
  if [[ -n "$_REMOTE_HALT_CACHE" ]]; then
    age=$((iter - _REMOTE_HALT_CHECKED_AT))
    if [[ "$age" -ge 0 && "$age" -lt "$REMOTE_HALT_INTERVAL" ]]; then
      if [[ "$_REMOTE_HALT_CACHE" == "halted" ]]; then
        if [[ -z "$HALT_REASON" ]]; then
          halt_latch_load
          if [[ -n "$LATCH_REMOTE_REASON" ]]; then
            HALT_REASON="$LATCH_REMOTE_REASON"
          else
            HALT_REASON="remote halt: cached remote kill switch still active — stopping"
          fi
        fi
        HALT_LATCH_SIDE="remote"
        halt_latch_load
        if [[ -n "$LATCH_REMOTE_KIND" && "$LATCH_REMOTE_JOURNALED" == "1" ]]; then
          HALT_SHOULD_JOURNAL=0
        else
          HALT_SHOULD_JOURNAL=1
        fi
        return 0
      fi
      return 1
    fi
  fi
  _REMOTE_HALT_CHECKED_AT=$iter

  # Source-bound gate: if a remote latch exists for a different/missing origin,
  # stay fail-closed and never query or clear against the new repo.
  halt_latch_load
  if [[ -n "$LATCH_REMOTE_KIND" ]]; then
    if ! remote_latch_source_matches; then
      HALT_REASON=$(remote_latch_source_mismatch_reason)
      info "$HALT_REASON"
      HALT_LATCH_SIDE="remote"
      if [[ "$LATCH_REMOTE_JOURNALED" == "1" ]]; then
        HALT_SHOULD_JOURNAL=0
      else
        HALT_SHOULD_JOURNAL=1
      fi
      _REMOTE_HALT_CACHE="halted"
      return 0
    fi
  fi

  if remote_halted_live; then
    _REMOTE_HALT_CACHE="halted"
    halt_latch_observe_remote "${REMOTE_HALT_KIND:-confirmed}" "$HALT_REASON" \
      "${ORIGIN_PARSE_HOST:-}" "${ORIGIN_HALT_SLUG:-}"
    return 0
  fi
  case "${REMOTE_HALT_STATUS:-}" in
    clear)
      # Positive clear of both remote paths on the SAME host+slug — drop the
      # remote latch so a fresh launch is allowed. First-ever clear with no
      # latch is a no-op. (Mismatched sources never reach here: gated above.)
      halt_latch_clear_remote
      _REMOTE_HALT_CACHE="clear"
      return 1
      ;;
    degraded|disabled)
      # Fail-closed only when a prior confirmation latched the remote stop on
      # this same source. First-ever API failure (no latch) stays fail-open.
      halt_latch_load
      if [[ -n "$LATCH_REMOTE_KIND" ]]; then
        HALT_REASON="${LATCH_REMOTE_REASON:-remote halt: previously confirmed remote kill switch still latched — stopping (GitHub recheck degraded; restore the original source and clear it successfully, or after operator verification remove gibson/halt-latch)}"
        info "remote halt latch held closed after degraded/disabled recheck (source=${LATCH_REMOTE_KIND} host=${LATCH_REMOTE_HOST:-?} slug=${LATCH_REMOTE_SLUG:-?})"
        HALT_LATCH_SIDE="remote"
        if [[ "$LATCH_REMOTE_JOURNALED" == "1" ]]; then
          HALT_SHOULD_JOURNAL=0
        else
          HALT_SHOULD_JOURNAL=1
        fi
        _REMOTE_HALT_CACHE="halted"
        return 0
      fi
      _REMOTE_HALT_CACHE="clear"
      return 1
      ;;
    *)
      _REMOTE_HALT_CACHE="clear"
      return 1
      ;;
  esac
}

halted() {
  HALT_REASON=""
  HALT_LATCH_SIDE=""
  HALT_SHOULD_JOURNAL=1
  if [[ -f "$HALT_FILE" ]]; then
    halt_latch_observe_local "file" "kill switch: gibson/HALT is present — stopping"
    return 0
  fi
  if [[ "${GIBSON_HALT:-}" == "1" ]]; then
    halt_latch_observe_local "env" "kill switch: GIBSON_HALT=1 — stopping"
    return 0
  fi
  # Neither local stop is active — drop any stale local latch so a fresh launch
  # after removing HALT / unsetting GIBSON_HALT is not held by journal dedup.
  halt_latch_clear_local
  if remote_halted; then
    # HALT_REASON / HALT_SHOULD_JOURNAL already set by remote_halted / latch.
    if [[ -z "$HALT_REASON" && "$_REMOTE_HALT_CACHE" == "halted" ]]; then
      HALT_REASON="remote halt: cached remote kill switch still active — stopping"
    fi
    return 0
  fi
  return 1
}

# Journal a halt without creating or rewriting loop-state (issue #71).
# May create gibson/ and journal.md only — never loop-state.md.
# Callers that already know a duplicate is unwanted check HALT_SHOULD_JOURNAL
# (stop_if_halted does); this helper always appends when invoked.
journal_halt() {
  mkdir -p "$STATE_DIR"
  if [[ ! -f "$JOURNAL" ]]; then
    echo "# Gibson loop journal" > "$JOURNAL"
  fi
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · halt"
    echo "${HALT_REASON:-kill switch active — stopping}"
    echo "loop-state left untouched; supervisor handoffs suppressed."
  } >> "$JOURNAL"
  halt_latch_mark_journaled
}

# Exit cleanly on any active kill switch. Call before state init and at every
# iteration top so a remote halt never materializes a default loop-state.
# Journal at most once per latch activation (KeepAlive-safe). Serialized with
# a cross-process lock so concurrent launches wait and observe the first latch
# (or fail closed) rather than racing duplicate journal sections or work.
stop_if_halted() {
  if ! halt_lock_acquire; then
    info "kill switch transition lock unavailable — stopping fail-closed (concurrent launch still owning the lock, or stuck lock; no work started)"
    exit 0
  fi
  if halted; then
    if [[ "${HALT_SHOULD_JOURNAL:-1}" -eq 1 ]]; then
      journal_halt
    fi
    halt_lock_release
    info "kill switch set — stopping cleanly"
    exit 0
  fi
  halt_lock_release
}

# Ensure loop-state exists (and has handoff fields) only AFTER a clean kill-
# switch check. A remote halt on a cold start must not create or rewrite this.
ensure_loop_state() {
  mkdir -p "$STATE_DIR"
  if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$STATE_FILE" <<EOF
# Gibson loop state
updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
issue:
pr:
hat: builder
next_hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: triage highest-priority unblocked unclaimed issue
notes: initialized by loop.sh
EOF
  fi
  grep -q '^handoff:' "$STATE_FILE" || printf 'handoff:\n' >> "$STATE_FILE"
  grep -q '^handoff_sha:' "$STATE_FILE" || printf 'handoff_sha:\n' >> "$STATE_FILE"
  if [[ ! -f "$JOURNAL" ]]; then
    echo "# Gibson loop journal" > "$JOURNAL"
  fi
}

# Why a blocked handoff writes to the journal and not only to stderr.
#
# playbooks/loop-step.md tells the NEXT agent — a fresh context, minutes or hours
# later, with none of this run's terminal — that when a handoff stays queued the
# reason is in gibson/journal.md and the fix is theirs. A refusal that only
# reaches stderr breaks that contract: the branch sits queued forever with no
# recorded reason, which is exactly the silent-agent failure Law 8 names.
#
# BLOCK_CONTEXT names the branch the entry is about; BLOCK_JOURNAL is the switch
# for callers that already write their own entry (escalate), so one failed
# attempt never produces two overlapping records.
BLOCK_CONTEXT=""
BLOCK_JOURNAL=1

# journal_block/block are called from resolve_base_pin and resolve_handoff_sha,
# which the caller runs inside a command substitution. An append to $JOURNAL is a
# filesystem write and survives that subshell; a shell variable set there would
# not, which is why the reason is recorded here at the point of refusal rather
# than reconstructed by the caller. Each refusal path calls block() exactly once
# and the callers above them deliberately only info(), so a single failed attempt
# leaves a single entry.
journal_block() {
  [[ "$BLOCK_JOURNAL" -eq 1 ]] || return 0
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · handoff blocked${BLOCK_CONTEXT:+ · branch=$BLOCK_CONTEXT}"
    echo "$*"
    echo "handoff/handoff_sha remain queued in loop-state; clear the reason above and the next iteration retries (Law 5, Law 8)."
  } >> "$JOURNAL"
}

block() { info "$*"; journal_block "$*"; }

read_field() {
  local key="$1"
  # FS set so field 1 is the key
  awk -v k="$key" -F': ' '{ if ($1 == k) { sub(/^[^:]+: /,""); print; exit } }' "$STATE_FILE"
}

render_prompt() {
  local hat="$1"
  local state
  state=$(cat "$STATE_FILE")
  node -e '
    const fs=require("fs");
    const pb=fs.readFileSync(process.argv[1],"utf8");
    const hat=process.argv[2];
    const state=fs.readFileSync(process.argv[3],"utf8");
    const gibson=process.argv[4];
    const repo=process.argv[5];
    let out=pb.split("{{hat}}").join(hat)
      .split("{{loop_state}}").join(state)
      .split("{{gibson_path}}").join(gibson)
      .split("{{repo_path}}").join(repo);
    process.stdout.write(out);
  ' "$PLAYBOOK" "$hat" "$STATE_FILE" "$GIBSON" "$REPO"
}

invoke_runner() {
  local prompt_file="$1"
  case "$RUNNER" in
    grok)
      command -v grok >/dev/null || die "grok CLI not found"
      # --prompt-file, not -p "$(cat ...)": rendered playbooks start with YAML
      # frontmatter ("---"), which grok's arg parser mis-reads as a flag when
      # passed as a positional/value string instead of a file path (L-007).
      # --permission-mode bypassPermissions: without it, grok has no TTY to
      # request tool-call approval in headless mode, so it silently narrates
      # instead of acting — every iteration exits in seconds with no real work
      # (L-008).
      # --cwd: bypassPermissions plus an inherited cwd would point the runner at
      # whatever directory the operator launched from — often the canonical
      # Gibson checkout, which AGENTS.md Law 3 says nothing may mutate.
      grok --prompt-file "$prompt_file" --cwd "$REPO" --permission-mode bypassPermissions
      ;;
    claude)
      command -v claude >/dev/null || die "claude CLI not found"
      # stdin, for the same frontmatter reason as grok's --prompt-file above:
      # as a positional arg the leading "---" is parsed as an unknown option
      (cd "$REPO" && claude -p --output-format text --permission-mode acceptEdits) < "$prompt_file"
      ;;
    codex)
      command -v codex >/dev/null || die "codex CLI not found"
      codex exec --full-auto --cd "$REPO" - < "$prompt_file"
      ;;
    hermes)
      if [[ -n "${HERMES_CMD:-}" ]]; then
        eval "$HERMES_CMD" < "$prompt_file"
      elif command -v hermes >/dev/null; then
        hermes run --prompt-file "$prompt_file"
      else
        die "hermes runner not found; set HERMES_CMD"
      fi
      ;;
    *) die "unknown runner: $RUNNER" ;;
  esac
}

# The base every review and every handoff must diff against, resolved as BOTH a
# branch name and an exact commit SHA. The supervisor needs the name (it opens a
# PR into a branch); the reviewer needs the SHA, for the same reason the head side
# is pinned to one: a base ref is a moving target.
#
# Not every repo's trunk is called `main`, and the local answer is not necessarily
# the current one. `refs/remotes/origin/HEAD` is a cached guess that survives a
# default-branch rename, and `refs/heads/main` can be many commits behind
# `origin/main` — a review diffed against either compares something other than
# what the supervisor will open, while the receipt records only the branch *name*
# and so looks reusable. When an origin is configured, the name and the tip
# therefore both come from the remote, and every failure to observe it fails
# closed. Only a genuinely local-only repo (no origin at all) falls back to a
# verified local main/master.
#
# Prints "<name> <sha>"; returns 1 when nothing can be pinned, and the caller must
# then refuse to review or hand off.
resolve_base_pin() {
  local name="" sha="" symref ls_out
  if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    if ! symref=$(git -C "$REPO" ls-remote --symref origin HEAD 2>/dev/null); then
      block "base unresolvable: git ls-remote --symref origin HEAD failed in $REPO — cannot confirm the current default branch, and a stale local ref reviews the wrong diff. Check the remote is reachable and credentials are valid, then re-queue."
      return 1
    fi
    name=$(printf '%s\n' "$symref" |
      awk '$1 == "ref:" && $3 == "HEAD" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
    if [[ -z "$name" ]]; then
      block "base unresolvable: origin advertises no symbolic HEAD for $REPO — refusing to guess the base branch. Set the remote's default branch (gh repo edit --default-branch NAME, or git remote set-head origin -a upstream-side), then re-queue."
      return 1
    fi
    if ! ls_out=$(git -C "$REPO" ls-remote origin "refs/heads/$name" 2>/dev/null); then
      block "base unconfirmable: git ls-remote origin refs/heads/$name failed — cannot confirm the current base tip, and reviewing against a stale local copy of $name reviews a diff nobody will merge. Restore access to origin, then re-queue."
      return 1
    fi
    sha=$(printf '%s\n' "$ls_out" | awk 'NR==1 {print $1}')
    if [[ -z "$sha" ]]; then
      block "base missing on the remote: origin advertises HEAD -> $name but has no refs/heads/$name — refusing to review against a base that does not exist. Push $name or repoint the remote's default branch, then re-queue."
      return 1
    fi
  else
    for name in main master; do
      sha=$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$name" || true)
      if [[ -n "$sha" ]]; then break; fi
      name=""
    done
    if [[ -z "$name" || -z "$sha" ]]; then
      block "base unresolvable: no base branch for $REPO (no origin configured, and no local main/master to fall back to). Create the trunk branch or add a remote whose HEAD names it, then re-queue."
      return 1
    fi
  fi
  # Same rule as the head side: a reviewer cannot diff a commit this clone cannot
  # read. The advertised base tip may have been pushed after this clone last
  # fetched, so fetch the branch (then the exact SHA) and refuse if the object is
  # still missing rather than record a review of something unreadable.
  if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
    info "base commit $sha ($name) is not in the local object database — fetching refs/heads/$name from origin"
    git -C "$REPO" fetch --quiet origin "refs/heads/$name" >/dev/null 2>&1 ||
      info "fetch of base refs/heads/$name failed — trying the exact SHA"
    if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
      git -C "$REPO" fetch --quiet origin "$sha" >/dev/null 2>&1 || true
    fi
    if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
      block "base object unfetchable: commit $sha ($name) is still missing from this clone after fetching refs/heads/$name and the exact SHA — refusing to review against a base nobody here can read. Check whether the tip was pruned or rewritten on the remote, then re-queue."
      return 1
    fi
    info "fetched base $sha into the local object database"
  fi
  printf '%s %s\n' "$name" "$sha"
}

escalate() {
  local out="$REVIEW_ARTIFACT"
  info "escalating after $failures consecutive failures — reviewers: $REVIEWERS"
  # The receipt is dropped even though escalation no longer touches the pre-handoff
  # artifact: reaching escalation means the loop has failed $failures times in a
  # row, and a review taken before that stall is not evidence about the branch as it
  # stands now. Dropping a receipt only ever costs one more review; keeping a stale
  # one costs a handoff nobody checked. Fail closed.
  rm -f "$REVIEW_RECEIPT"
  local base="" base_sha="" pin note
  # Same exact base as the pre-handoff review: a failure-triage review of the
  # wrong diff is as misleading as a pre-handoff one.
  #
  # No handoff is queued here, and this function writes its own journal entry a
  # few lines down, so resolve_base_pin's refusal stays on stderr: two records of
  # one skipped escalation would be noise, not signal.
  BLOCK_JOURNAL=0
  if pin=$(resolve_base_pin); then
    base=${pin%% *}
    base_sha=${pin##* }
  fi
  BLOCK_JOURNAL=1
  if [[ -z "$base_sha" ]]; then
    info "escalation review skipped — no base branch resolved, and a guessed base reviews the wrong diff"
    note="Escalation review skipped: the target repo's base branch could not be resolved (Law 8)."
  elif "$SCRIPT_DIR/second-opinion.sh" \
      --repo "$REPO" --reviewers "$REVIEWERS" --author "$RUNNER" --base "$base_sha" \
      --gate-status "red: $failures consecutive runner failures" --out "$out" >/dev/null 2>&1; then
    info "second opinion written to $out (base $base @ $base_sha)"
    note="Second opinion against \`$base\` @ \`$base_sha\` written to gibson/second-opinion.md — next hat must read it."
  else
    info "second opinion failed (non-fatal) — continuing"
    note="No reviewer completed — see gibson/second-opinion.md for the raw attempts (Law 8)."
  fi
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · escalation · reviewers=$REVIEWERS"
    echo "$note"
  } >> "$JOURNAL"
}

# Resolve the SHA the supervisor will actually see, and refuse to hand off a tip
# nobody reviewed. devin-supervisor.sh compares --sha against `ls-remote origin`
# and dies on a mismatch, so the driver resolves the same way: a loop-state pin
# that disagrees with the remote tip is a blocked handoff here, not a die() three
# scripts later (issue #55). Prints the SHA on stdout; returns 1 when there is
# none to pin.
resolve_handoff_sha() {
  local branch="$1" pinned remote="" ls_out sha
  pinned=$(read_field handoff_sha)
  # No origin at all is fatal here, not a fall-through to local refs. This
  # function is reached only from supervisor_handoff, i.e. only when the work is
  # destined for the Devin supervisor — and the supervisor opens the PR from the
  # REMOTE branch, so a repo with no remote has nothing it can be handed. The
  # real devin-supervisor.sh already refuses a --sha handoff without an origin;
  # resolving a local SHA here would only mean spending a distinct-vendor review
  # first and hitting that same refusal afterwards. Fail before the review, not
  # after it.
  if ! git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    block "no origin configured in $REPO — the supervisor can only open a PR from a remote branch, so an origin-less repo has no handoff to make. Add a remote and push $branch, then re-queue the handoff."
    return 1
  fi
  # Explicit, not errexit-suppressed: an unreachable origin means we cannot tell
  # whether the tip moved, and handing off a tip we cannot confirm is exactly
  # what the pin exists to prevent.
  if ls_out=$(git -C "$REPO" ls-remote origin "refs/heads/$branch" 2>/dev/null); then
    remote=$(printf '%s\n' "$ls_out" | awk 'NR==1 {print $1}')
  else
    block "origin unreachable: git ls-remote origin refs/heads/$branch failed — cannot confirm the remote tip, and handing off a tip we cannot confirm is exactly what the pin exists to prevent. Restore access to origin, then re-queue the handoff."
    return 1
  fi
  # Reachable origin, no such branch: the branch exists only in this checkout.
  # Falling back to refs/heads/$branch here reviews a tip the supervisor cannot
  # see — it opens a PR from the REMOTE branch, so it would review and merge
  # something other than what was reviewed here, or nothing at all. An
  # unpublished branch is a blocked handoff, not a local-ref handoff.
  if [[ -z "$remote" ]]; then
    block "branch not on the remote: origin has no refs/heads/$branch — it was never pushed, and the supervisor can only open a PR from the remote branch. Run 'git -C $REPO push origin $branch', then re-queue the handoff."
    return 1
  fi
  if [[ -n "$pinned" && "$pinned" != "$remote" ]]; then
    block "pin mismatch: loop-state pins $branch @ $pinned but the remote tip is $remote — refusing to hand off an unreviewed tip (issue #55). Either push the pinned commit or set handoff_sha to $remote after re-reviewing that tip, then re-queue."
    return 1
  fi
  # Never empty: $remote is non-empty by the time we get here, because every
  # other path above returned 1. There is deliberately no local-ref fallback —
  # a SHA only this clone can see is not a SHA the supervisor can act on.
  sha="${pinned:-$remote}"
  # The SHA may have come from `ls-remote` (or from a loop-state pin written by
  # an agent working in a different worktree), so the object is not necessarily
  # in THIS clone. A reviewer cannot diff a commit it cannot read, and writing a
  # receipt for an absent object records a review that never happened — fetch the
  # exact branch, then refuse if the commit is still missing (issue #55).
  if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
    info "commit $sha is not in the local object database — fetching refs/heads/$branch from origin"
    git -C "$REPO" fetch --quiet origin "refs/heads/$branch" >/dev/null 2>&1 ||
      info "fetch of refs/heads/$branch failed — trying the exact SHA"
    if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
      git -C "$REPO" fetch --quiet origin "$sha" >/dev/null 2>&1 || true
    fi
    if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
      block "head object unfetchable: commit $sha is still missing from this clone after fetching refs/heads/$branch and the exact SHA — refusing to record a review of an object nobody here can read. Check whether the tip was pruned or rewritten on the remote, then re-queue."
      return 1
    fi
    info "fetched $sha into the local object database"
  fi
  printf '%s\n' "$sha"
}

# A receipt is written only when second-opinion.sh exited 0, and it names BOTH
# endpoints of the diff that was reviewed. That is what makes a stale
# gibson/pre-handoff-review.md useless as a pass: the artifact alone proves nothing
# about which tip, which vendor, or whether the reviewer even finished (issue
# #55). Binding the base SHA as well as the head SHA closes the matching hole on
# the base side — the same head reviewed against a base branch that has since
# advanced is a different diff, so its receipt must not be reused.
#
# Scope of the guarantee: this is an operational control over what the driver
# will do, not a tamper-proof one. The receipt is a same-user file in the target
# repo, so a runner with write access there could forge one; keeping it out of
# their reach is a separate hardening concern and is not solved here.
review_receipt_ok() {
  local sha="$1" branch="$2" base="$3" base_sha="$4"
  [[ -f "$REVIEW_RECEIPT" ]] || return 1
  # The receipt attests to the PRE-HANDOFF artifact, so that is the file whose
  # existence it is checked against. Checking the escalation artifact here would
  # let an unrelated stall review stand in for the review the receipt names, and
  # would fail a perfectly good receipt in any repo that has never escalated.
  [[ -s "$PRE_HANDOFF_REVIEW" ]] || return 1
  grep -qxF "status: ok" "$REVIEW_RECEIPT" || return 1
  grep -qxF "sha: $sha" "$REVIEW_RECEIPT" || return 1
  grep -qxF "branch: $branch" "$REVIEW_RECEIPT" || return 1
  grep -qxF "base: $base" "$REVIEW_RECEIPT" || return 1
  grep -qxF "base_sha: $base_sha" "$REVIEW_RECEIPT" || return 1
  grep -qxF "author: $RUNNER" "$REVIEW_RECEIPT" || return 1
  grep -qxF "reviewers: $REVIEWERS" "$REVIEW_RECEIPT" || return 1
  return 0
}

# Law 5 gate: never grade your own homework. Returns 0 only when a reviewer from
# a different vendor completed successfully against exactly $base_sha...$sha.
# Every other outcome — no distinct vendor configured, reviewer CLI missing,
# reviewer non-zero, empty diff — returns 1, and the caller must not hand off.
ensure_cross_vendor_review() {
  local branch="$1" sha="$2" base="$3" base_sha="$4"
  # Never $REVIEW_ARTIFACT: this review runs on every handoff, and writing it there
  # would overwrite the escalation review the next hat was told to read.
  local out="$PRE_HANDOFF_REVIEW"

  if review_receipt_ok "$sha" "$branch" "$base" "$base_sha"; then
    info "distinct-vendor review already recorded for $branch @ $sha against $base @ $base_sha — reusing it"
    return 0
  fi

  if [[ -z "$REVIEWERS" ]]; then
    block "no reviewers configured: --reviewers is empty, so there is no distinct-vendor reviewer to run and nobody may approve $branch @ $sha (Law 5). Re-run the loop with --reviewers naming a vendor other than $RUNNER."
    return 1
  fi
  local distinct=0 name
  local names=()
  IFS=',' read -ra names <<< "$REVIEWERS"
  for name in "${names[@]}"; do
    name=$(echo "$name" | tr -d '[:space:]')
    if [[ -n "$name" && "$name" != "$RUNNER" ]]; then
      distinct=1
    fi
  done
  if [[ "$distinct" -eq 0 ]]; then
    block "no distinct vendor: --reviewers '$REVIEWERS' contains no vendor other than the runner ($RUNNER), and nobody grades their own homework (Law 5). Add a different vendor to --reviewers, then re-queue the handoff of $branch @ $sha."
    return 1
  fi

  # Remove first: a review that fails halfway must never leave a passing receipt.
  rm -f "$REVIEW_RECEIPT"
  info "running the mandatory distinct-vendor review of $branch @ $sha against $base @ $base_sha before handoff (Law 5)"
  # --base is the exact base SHA, not the branch name: the reviewer must see the
  # same two endpoints the receipt records.
  if "$SCRIPT_DIR/second-opinion.sh" \
      --repo "$REPO" --reviewers "$REVIEWERS" --author "$RUNNER" \
      --base "$base_sha" --branch "$sha" \
      --gate-status "pre-handoff mandatory review of $branch @ $sha against $base @ $base_sha" \
      --out "$out" >/dev/null; then
    printf 'sha: %s\nbranch: %s\nbase: %s\nbase_sha: %s\nauthor: %s\nreviewers: %s\nreviewed: %s\nstatus: ok\n' \
      "$sha" "$branch" "$base" "$base_sha" "$RUNNER" "$REVIEWERS" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      > "$REVIEW_RECEIPT"
    info "distinct-vendor review of $sha against $base @ $base_sha completed — receipt at $REVIEW_RECEIPT"
    return 0
  fi
  rm -f "$REVIEW_RECEIPT"
  # The reviewer-failure entry that already existed, now emitted through the same
  # helper as every other refusal so the journal reads in one format.
  block "pre-handoff review failed: the distinct-vendor review of $branch @ $sha against $base @ $base_sha did not complete (reviewers=$REVIEWERS, author=$RUNNER). Read gibson/pre-handoff-review.md for the raw attempts, fix what the reviewer choked on, then re-queue."
  return 1
}

# File-handoff protocol: pin and pass the head SHA so a later push cannot
# invalidate the review without the supervisor noticing (issue #55). The gate is
# closed — every early return here leaves handoff/handoff_sha queued in
# loop-state and never reaches devin-supervisor.sh.
supervisor_handoff() {
  [[ "$SUPERVISOR" == "devin" ]] || return 0
  local branch
  branch=$(read_field handoff)
  [[ -n "$branch" ]] || return 0
  # Local kill switch + in-process remote cache (age 0 within an iteration, so
  # this mainly catches gibson/HALT / GIBSON_HALT that appeared after iteration
  # top). A mid-cadence remote label/sentinel is caught by the child's fresh
  # live recheck (exit 75 below), not by this cache hit.
  if halted; then
    info "kill switch active — suppressing supervisor handoff of $branch (handoff stays queued)"
    return 0
  fi
  # Names the branch in every journal entry written below this point, including
  # the ones written from inside resolve_base_pin/resolve_handoff_sha's command
  # substitutions — a reader with three queued branches needs to know which one
  # each reason belongs to.
  BLOCK_CONTEXT="$branch"

  # Resolved before anything is spent: a review against a guessed or stale base is
  # a review of the wrong diff, so a base that cannot be resolved AND confirmed
  # blocks the handoff instead of quietly falling back to `main`.
  local base base_sha pin
  if ! pin=$(resolve_base_pin); then
    info "handoff of $branch blocked: the target repo's base branch could not be resolved or confirmed — branch stays queued in loop-state"
    return 0
  fi
  base=${pin%% *}
  base_sha=${pin##* }

  local sha
  if ! sha=$(resolve_handoff_sha "$branch"); then
    info "handoff of $branch blocked: no reviewable SHA — branch stays queued in loop-state"
    return 0
  fi
  info "pinning handoff to $branch @ $sha (base $base @ $base_sha)"

  if ! ensure_cross_vendor_review "$branch" "$sha" "$base" "$base_sha"; then
    info "handoff of $branch @ $sha blocked: no completed distinct-vendor review — branch stays queued in loop-state"
    return 0
  fi

  local task issue next
  issue=$(read_field issue)
  next=$(read_field next_action)
  task=""
  [[ -z "$issue" ]] || task="Issue: $issue."
  [[ -z "$next" ]] || task="${task:+$task }Next action: $next"
  [[ -n "$task" ]] || task="See the branch diff; loop-state carried no task description."
  # The pre-handoff review, not the escalation artifact: the supervisor must be
  # shown the review of the exact diff it is being handed, which is the one the
  # receipt above binds.
  local review="$PRE_HANDOFF_REVIEW"
  # The supervisor gets the human branch NAMES — it opens a PR from one branch
  # into another, not from one commit into another — AND both exact SHAs, so the
  # diffstat it is shown is built from the same two endpoints the reviewer saw.
  # Passing only the names would let a stale local ref describe a different diff
  # than the one that was reviewed. Both objects were fetched and verified by
  # resolve_base_pin/resolve_handoff_sha above, so the exact-SHA diff is readable.
  info "handing $branch @$sha to the Devin supervisor (base $base @ $base_sha)"
  # Capture rc: 75 is kill-switch refusal (remote/local) from the child's own
  # fresh live recheck — journal a halt, leave handoff queued, never say
  # "supervisor rejected". Any other nonzero is a real rejection/error path.
  local sup_rc=0
  set +e
  "$SCRIPT_DIR/devin-supervisor.sh" handoff --repo "$REPO" --branch "$branch" \
      --base "$base" --base-sha "$base_sha" --sha "$sha" \
      --task "$task" --gate-status "green locally" \
      --review-file "$review"
  sup_rc=$?
  set -e
  if [[ "$sup_rc" -eq 0 ]]; then
    node -e '
      const fs = require("fs");
      const file = process.argv[1];
      let text = fs.readFileSync(file, "utf8");
      text = text.replace(/^handoff:.*$/m, "handoff:");
      text = text.replace(/^handoff_sha:.*$/m, "handoff_sha:");
      fs.writeFileSync(file, text);
    ' "$STATE_FILE"
  elif [[ "$sup_rc" -eq 75 ]]; then
    HALT_REASON="kill switch: supervisor refused handoff after a fresh remote/local check — handoff left queued (remove gibson-halt label / .gibson-halt / gibson/HALT / GIBSON_HALT to allow a fresh launch)"
    # Child already wrote the appropriate latch side (local file present, or
    # remote confirmation). Mark journaled after this section; only treat the
    # in-process remote cache as halted when a remote latch actually exists so
    # a pure local refuse does not poison later cache-hit messaging.
    HALT_LATCH_SIDE=""
    journal_halt
    halt_latch_load
    if [[ -n "$LATCH_REMOTE_KIND" ]]; then
      _REMOTE_HALT_CACHE="halted"
      _REMOTE_HALT_CHECKED_AT=$iter
    fi
    info "kill switch active — supervisor refused handoff of $branch (handoff stays queued; not a supervisor rejection)"
  else
    block "supervisor rejected the handoff: devin-supervisor.sh exited $sup_rc for $branch @ $sha into $base @ $base_sha. Re-run that command by hand to see its refusal (it prints the reason to stderr) — a moved remote tip, a missing DEVIN_API_KEY, and an unreachable Devin API all land here."
  fi
}

heartbeat() {
  if [[ -n "${MC_HEARTBEAT_URL:-}" ]]; then
    curl -sS -X POST "$MC_HEARTBEAT_URL" \
      -H 'content-type: application/json' \
      -d "{\"source\":\"loop.sh\",\"repo\":\"$REPO\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
      >/dev/null 2>&1 || info "heartbeat failed (non-fatal)"
  fi
}

# Kill switch before any loop-state init or supervisor ensure: a remote halt on
# a cold start must journal and exit without creating a default loop-state, and
# must not wake the cloud supervisor (issue #71).
stop_if_halted
ensure_loop_state

if [[ "$SUPERVISOR" == "devin" && "$DRY" -eq 0 && "$PRINT" -eq 0 ]]; then
  "$SCRIPT_DIR/devin-supervisor.sh" ensure --repo "$REPO" || \
    info "supervisor unavailable at startup (non-fatal) — handoffs will retry"
fi

while true; do
  stop_if_halted

  hat="${FORCE_HAT:-$(read_field next_hat)}"
  [[ -n "$hat" ]] || hat="builder"
  FORCE_HAT=""

  info "iteration hat=$hat repo=$REPO"

  PROMPT_FILE=$(mktemp)
  render_prompt "$hat" > "$PROMPT_FILE"

  if [[ "$PRINT" -eq 1 ]]; then
    cat "$PROMPT_FILE"
    rm -f "$PROMPT_FILE"
    exit 0
  fi

  if [[ "$DRY" -eq 1 ]]; then
    info "dry-run: would invoke $RUNNER with rendered loop-step ($hat)"
    rm -f "$PROMPT_FILE"
  else
    set +e
    invoke_runner "$PROMPT_FILE"
    ec=$?
    set -e
    rm -f "$PROMPT_FILE"
    if [[ $ec -ne 0 ]]; then
      failures=$((failures + 1))
      info "runner exit $ec (consecutive failures=$failures/$BUDGET)"
      if [[ "$ESCALATE_AFTER" -gt 0 && $failures -eq "$ESCALATE_AFTER" ]]; then
        escalate
      fi
      if [[ $failures -ge $BUDGET ]]; then
        die "error budget exhausted — likely harness bug, not retry fodder (docs/11)"
      fi
    else
      failures=0
      supervisor_handoff
    fi
  fi

  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · hat=$hat · runner=$RUNNER"
    echo "Driver completed iteration; agent should have updated loop-state."
  } >> "$JOURNAL"

  heartbeat
  iter=$((iter + 1))

  if [[ "$ONCE" -eq 1 ]]; then
    info " --once done"
    exit 0
  fi
  if [[ "$MAX" -ge 0 && "$iter" -ge "$MAX" ]]; then
    info "max iterations $MAX reached"
    exit 0
  fi
done
