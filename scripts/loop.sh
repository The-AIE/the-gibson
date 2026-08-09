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
  - Stale budget (default: same as --error-budget) stops the loop when a runner
    exits 0 without substantive loop-state progress (L-008 / issue #63). Only the
    column-zero updated: clock is ignored; clock-only rewrites are no-progress.
    No-progress increments the shared failure counter and the stale counter once
    each, journals a distinct no-progress diagnosis, and never resets, restores,
    or hands off. Stop at the earlier of error-budget or stale-budget exhaustion.
    state-corrupt and runner-failure take precedence and never run the no-progress
    sensor. Escalation (--escalate-after) fires on the shared failure counter for
    no-progress the same as for other failures.
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
  loop.sh --runner <grok|hermes|claude|codex> --repo <path> --repo-slug <owner/repo> [options]
  loop.sh --help

OPTIONS
  --runner NAME       runtime CLI (required)
  --repo PATH         target repository path (required)
  --repo-slug SLUG    expected canonical origin repository (required)
  --gibson PATH       Gibson clone (default: parent of this script)
  --once              single iteration then exit
  --print-prompt      render prompt only (no runner)
  --max-iterations N  cap iterations (default: unlimited until halt)
  --error-budget N    consecutive failures before stop (default: 5)
  --stale-budget N    consecutive no-progress (exit 0, no substantive
                      loop-state change) iterations before stop (default:
                      same as --error-budget). Clock-only updated: rewrites
                      are no-progress (L-008 / issue #63). N must be a
                      positive safe decimal integer.
  --hat HAT           force starting hat (default: from loop-state or builder)
  --dry-run           show actions without invoking runner
  --escalate-after N  after N consecutive failures, get a cross-vendor second
                      opinion before the error budget runs out (default: off)
  --reviewers LIST    vendors for second opinion (default: codex,claude).
                      With --solo-platform use vendor:model (e.g. grok:review).
  --solo-platform     single-vendor mode (#69): same platform supplies the
                      pre-handoff review via different model / fresh context.
                      No second CLI required. Tier C still human-gated.
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
EXPECTED_REPO_SLUG=""
GIBSON=""
ONCE=0
PRINT=0
MAX=-1
BUDGET=5
# Empty until after parse: omitted --stale-budget resolves exactly to --error-budget.
STALE_BUDGET=""
STALE_BUDGET_SET=0
FORCE_HAT=""
DRY=0
ESCALATE_AFTER=0
REVIEWERS="codex,claude"
REVIEWERS_SET=0
SOLO_PLATFORM=0
SUPERVISOR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --runner) RUNNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --repo-slug) EXPECTED_REPO_SLUG="$2"; shift 2 ;;
    --gibson) GIBSON="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --print-prompt) PRINT=1; shift ;;
    --max-iterations) MAX="$2"; shift 2 ;;
    --error-budget) BUDGET="$2"; shift 2 ;;
    --stale-budget) STALE_BUDGET="$2"; STALE_BUDGET_SET=1; shift 2 ;;
    --hat) FORCE_HAT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --escalate-after) ESCALATE_AFTER="$2"; shift 2 ;;
    --reviewers) REVIEWERS="$2"; REVIEWERS_SET=1; shift 2 ;;
    --solo-platform) SOLO_PLATFORM=1; shift ;;
    --supervisor) SUPERVISOR="$2"; shift 2 ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "loop.sh: ERROR: $*" >&2; exit 1; }
info() { echo "loop.sh: $*" >&2; }

# Positive safe decimal integer: no leading zeros, no injection, no overflow.
# Rejects 0, negative, empty, non-digits, leading-zero octal forms, and values
# too large for portable signed 32-bit arithmetic (bash 3.2-safe comparisons).
is_positive_safe_int() {
  local n="${1-}"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 1
  # 9 digits max keeps us under 2^31-1 (2147483647) without overflow surprises.
  [[ ${#n} -le 9 ]] || return 1
  # Bound check via pure string/length already; force base-10 for the numeric cap.
  n=$((10#$n))
  [[ "$n" -ge 1 && "$n" -le 2147483647 ]] || return 1
  return 0
}

[[ -n "$RUNNER" ]] || { usage; exit 2; }
[[ -n "$REPO" ]] || { usage; exit 2; }
[[ -n "$EXPECTED_REPO_SLUG" ]] || { usage; exit 2; }
[[ -d "$REPO" ]] || die "repo not a directory: $REPO"

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
GIBSON="${GIBSON:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLAYBOOK="$GIBSON/playbooks/loop-step.md"
[[ -f "$PLAYBOOK" ]] || die "missing $PLAYBOOK"

# --solo-platform (#69): when the operator has one vendor only, the mandatory
# pre-handoff review uses the same platform with an alternate model tag so
# Law 5 is satisfied by fresh-context + different model, not a second CLI.
if [[ "$SOLO_PLATFORM" -eq 1 ]]; then
  info "solo-platform mode: same-vendor review allowed (fresh context + alt model)"
  if [[ "$REVIEWERS_SET" -eq 0 ]]; then
    case "$RUNNER" in
      claude) REVIEWERS="claude:sonnet" ;;
      grok)   REVIEWERS="grok:review" ;;
      codex)  REVIEWERS="codex:review" ;;
      hermes) REVIEWERS="hermes:review" ;;
      *)      REVIEWERS="${RUNNER}:review" ;;
    esac
    info "solo-platform default reviewers=$REVIEWERS"
  fi
fi


# L-008 / issue #63: stateless progress sensor (silent_noop_progressed).
# shellcheck source=silent-noop.sh
# Prefer $GIBSON/scripts so a test copy of this driver under a fake scripts/
# dir still loads the real sensor (same pattern as validate-loop-state.sh).
# Fall back to SCRIPT_DIR when the driver is invoked from a normal checkout.
if [[ -f "$GIBSON/scripts/silent-noop.sh" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$GIBSON/scripts/silent-noop.sh"
elif [[ -f "$SCRIPT_DIR/silent-noop.sh" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$SCRIPT_DIR/silent-noop.sh"
else
  die "missing silent-noop.sh (looked in $GIBSON/scripts and $SCRIPT_DIR)"
fi
if ! declare -F silent_noop_progressed >/dev/null 2>&1; then
  die "silent-noop.sh did not define silent_noop_progressed"
fi

# Cost telemetry (#74 / L-003 / #141). Opt-in via GIBSON_COST_LEDGER path. Never
# invents zeros for missing token/ACU signals — append only what the driver
# measured. Optional fleet join fields (GIBSON_COST_JOIN_KEY / pool / provider /
# requested runner / fallback reason) associate iterations with loop-fleet
# selection rows. Defined at top level (not inside the silent-noop if/elif) so
# the normal $GIBSON/scripts path still registers the function.
cost_ledger_record_iteration() {
  local wall_ms="${1:-0}" hat="${2:-loop-step}"
  local ledger="${GIBSON_COST_LEDGER:-}"
  [[ -n "$ledger" ]] || return 0
  [[ -x "$SCRIPT_DIR/cost-ledger.sh" || -f "$SCRIPT_DIR/cost-ledger.sh" ]] || return 0
  local pool="${GIBSON_COST_POOL:-unknown}"
  # Bash 3.2 + set -u: build argv as a string of carefully-quoted optional
  # flags via positional rebuild — never expand empty arrays with "${arr[@]}".
  set -- \
    --ledger "$ledger" \
    --runner "${RUNNER:-unknown}" \
    --pool "$pool" \
    --hat "$hat" \
    --wall-ms "$wall_ms" \
    --event-kind iteration
  if [[ -n "${ISSUE:-}" ]]; then set -- "$@" --issue "$ISSUE"; fi
  if [[ -n "${PR_NUMBER:-}" ]]; then set -- "$@" --pr "$PR_NUMBER"; fi
  if [[ -n "${ITERATION:-}" ]]; then set -- "$@" --iteration "$ITERATION"; fi
  if [[ -n "${REPO_SLUG:-}" ]]; then set -- "$@" --repo "$REPO_SLUG"; fi
  if [[ -n "${GIBSON_COST_TOKENS:-}" ]]; then set -- "$@" --tokens "$GIBSON_COST_TOKENS"; fi
  if [[ -n "${GIBSON_COST_ACUS:-}" ]]; then set -- "$@" --acus "$GIBSON_COST_ACUS"; fi
  if [[ -n "${GIBSON_COST_FLAT_RATE:-}" ]]; then set -- "$@" --flat-rate "$GIBSON_COST_FLAT_RATE"; fi
  if [[ -n "${GIBSON_COST_JOIN_KEY:-}" ]]; then set -- "$@" --join-key "$GIBSON_COST_JOIN_KEY"; fi
  if [[ -n "${GIBSON_COST_REQUESTED_RUNNER:-}" ]]; then set -- "$@" --requested-runner "$GIBSON_COST_REQUESTED_RUNNER"; fi
  if [[ -n "${GIBSON_COST_PROVIDER:-}" ]]; then set -- "$@" --provider "$GIBSON_COST_PROVIDER"; fi
  if [[ -n "${GIBSON_COST_FALLBACK_REASON:-}" ]]; then set -- "$@" --fallback-reason "$GIBSON_COST_FALLBACK_REASON"; fi
  "$SCRIPT_DIR/cost-ledger.sh" append "$@" >/dev/null 2>&1 || true
}

# Resolve --stale-budget: omitted means exactly the (possibly custom) error-budget.
if [[ "$STALE_BUDGET_SET" -eq 0 ]]; then
  STALE_BUDGET="$BUDGET"
else
  if ! is_positive_safe_int "$STALE_BUDGET"; then
    die "invalid --stale-budget '${STALE_BUDGET}' (want a positive safe decimal integer, no leading zeros)"
  fi
  STALE_BUDGET=$((10#$STALE_BUDGET))
fi

STATE_DIR="$REPO/gibson"
STATE_FILE="$STATE_DIR/loop-state.md"
# Last validated pre-iteration snapshot (issue #75). Recovery restores exact
# bytes from this file; corrupt content must never overwrite it.
STATE_SNAPSHOT="$STATE_DIR/.loop-state.prev"
JOURNAL="$STATE_DIR/journal.md"
HALT_FILE="$STATE_DIR/HALT"
# Shared schema + strict-UTC primitive (issue #75). Looked up via $GIBSON so a
# test copy of this driver under a fake scripts/ dir still finds the real file.
VALIDATE_LOOP_STATE=""
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
# Consecutive no-progress iterations (issue #63). Reset only on substantive
# progress (valid state + exit 0 + silent_noop_progressed). Not touched by
# state-corrupt, runner-failure, pre-queued handoff, dry-run, or halt paths.
stale=0

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

TARGET_REPO_REALPATH=$(CDPATH='' cd "$REPO" && pwd -P)
ORIGIN_SLUG=$(origin_slug)
# Enforce only when origin is parseable. Unparseable/absent origin cannot be
# verified against --repo-slug; remote-halt already fail-opens with a warning,
# and a blank origin_slug must not brick local-only / host-alias fixtures (#92
# residual after #113).
if [[ -n "$ORIGIN_SLUG" && "$ORIGIN_SLUG" != "$EXPECTED_REPO_SLUG" ]]; then
  die "repository identity mismatch: --repo-slug '$EXPECTED_REPO_SLUG' does not match origin '$ORIGIN_SLUG'"
fi

GUARD_REAL_GIT=$(command -v git)
GUARD_BIN=""
GUARD_PATH=""
prepare_repo_boundary_guard() {
  GUARD_BIN=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard.XXXXXX")
  ln -s "$GIBSON/scripts/repo-boundary-guard.sh" "$GUARD_BIN/git"
  GUARD_PATH="$GUARD_BIN:${PATH}"
}

clear_repo_boundary_guard() {
  if [[ -n "$GUARD_BIN" ]]; then
    rm -rf "$GUARD_BIN"
    GUARD_BIN=""
    GUARD_PATH=""
  fi
}

guard_control_plane_clean() {
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      .agents/gate.json|.gibson-gate.json|.agents/gate.*|.agents/*sensor*.json|.agents/*sensor*.yaml|.agents/*sensor*.yml)
        info "repo-boundary guard: runner modified harness control-plane file '$path'"
        return 1
        ;;
    esac
  done < <(
    {
      git -C "$REPO" diff --name-only
      git -C "$REPO" diff --cached --name-only
      git -C "$REPO" ls-files --others --exclude-standard
    } | sort -u
  )
  return 0
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
#
# Stale reclaim is serialized through a kernel-held advisory lock on a stable
# regular gate file (never unlinked on acquire/release). macOS uses lockf(1)
# on an inherited open fd; Linux uses flock(1) on the same pattern. Kernel
# state vanishes on crash — no stale generation/ABA ownership pathname and no
# check-then-rm gate protocol. If neither backend is available, reclaim fails
# closed (see halt_lock_try_reclaim_stale / halt_lock_reclaim_gate_*).

HALT_LOCK_FILE="$STATE_DIR/halt-lock"
HALT_LOCK_HELD=0
HALT_LOCK_OWNER=""
HALT_LOCK_TMP=""
# Stable regular reclaim-gate file (kernel advisory lock target). Never unlinked
# during normal acquire/release; content is not ownership (empty is fine).
HALT_LOCK_RECLAIM_GATE="${STATE_DIR}/.halt-lock.reclaiming"
# Reclaim-gate open-file-description number. Bash 3.2 has no {fd} auto-
# allocation and a fixed high fd (e.g. 201) collides when already inherited:
# `exec 201>>gate` does not retarget an open descriptor. Leave empty until a
# free fd in the bounded high range is successfully opened and locked; release
# closes only that number. Never close, retarget, or mutate inherited fds.
HALT_LOCK_RECLAIM_FD=""
# Inclusive scan range for collision-free reclaim-gate fd allocation.
HALT_LOCK_RECLAIM_FD_MIN="${HALT_LOCK_RECLAIM_FD_MIN:-200}"
HALT_LOCK_RECLAIM_FD_MAX="${HALT_LOCK_RECLAIM_FD_MAX:-220}"
HALT_LOCK_RECLAIM_HELD=0
# Bounded seconds to wait for the kernel reclaim gate (fail closed after).
HALT_LOCK_RECLAIM_TIMEOUT="${HALT_LOCK_RECLAIM_TIMEOUT:-2}"

# Read a key=value field from the lock file. Returns 1 if missing/unreadable.
# No pipelines: a pipeline runs in a subshell that would inherit the EXIT trap
# and call halt_lock_release, unlinking a live lock held by this shell.
halt_lock_field() {
  local key="$1" file="${2:-$HALT_LOCK_FILE}" line
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "${key}="*)
        printf '%s' "${line#*=}"
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

# Inode of a path (GNU first, BSD fallback). Empty/fail => return 1.
# L-050 / #99: never probe `stat -f` first on a dual-meaning flag.
halt_lock_inode() {
  local f="$1" ino
  [[ -e "$f" ]] || return 1
  ino=$(stat -c %i -- "$f" 2>/dev/null || stat -f %i -- "$f" 2>/dev/null) || return 1
  [[ -n "$ino" ]] || return 1
  printf '%s' "$ino"
}

# True if numeric fd is already open for read or write in this shell.
# Bash 3.2 has no /dev/fd introspection helper for this; probe with a no-op
# redirection. Invalid candidates are treated as busy (fail closed).
halt_lock_fd_is_open() {
  local fd="$1"
  [[ "$fd" =~ ^[0-9]+$ ]] || return 0
  # Read-open probe (also true for many r/w descriptors on macOS Bash 3.2).
  if eval "true 2>/dev/null <&${fd}"; then
    return 0
  fi
  # Write-open probe (catches write-only descriptors the read probe misses).
  if eval "true 2>/dev/null >&${fd}"; then
    return 0
  fi
  return 1
}

# Print one unused high fd in [MIN,MAX], or fail closed when the range is full.
# Candidates are validated as pure digits before any eval. Does not open,
# close, or retarget any descriptor — selection only.
halt_lock_pick_reclaim_fd() {
  local min="${HALT_LOCK_RECLAIM_FD_MIN:-200}"
  local max="${HALT_LOCK_RECLAIM_FD_MAX:-220}"
  local fd
  [[ "$min" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] || return 1
  # Bound the scan so a corrupted env cannot walk the entire fd table.
  [[ "$min" -ge 10 && "$max" -ge "$min" && "$max" -le 250 ]] || return 1
  fd=$min
  while [[ $fd -le $max ]]; do
    if ! halt_lock_fd_is_open "$fd"; then
      printf '%s' "$fd"
      return 0
    fi
    fd=$((fd + 1))
  done
  return 1
}

# Select reclaim-gate backend: lockf (macOS/BSD) or flock (Linux util-linux).
# HALT_LOCK_RECLAIM_BACKEND may force a choice for tests; otherwise prefer the
# platform tool and fall back to whichever is on PATH. Prints the name or fails.
halt_lock_reclaim_backend() {
  local forced="${HALT_LOCK_RECLAIM_BACKEND:-}" os
  if [[ -n "$forced" ]]; then
    case "$forced" in
      lockf|flock)
        if command -v "$forced" >/dev/null 2>&1; then
          printf '%s' "$forced"
          return 0
        fi
        return 1
        ;;
      *)
        return 1
        ;;
    esac
  fi
  os=$(uname -s 2>/dev/null || true)
  case "$os" in
    Darwin|FreeBSD|OpenBSD|NetBSD|DragonFly)
      if command -v lockf >/dev/null 2>&1; then
        printf 'lockf'
        return 0
      fi
      if command -v flock >/dev/null 2>&1; then
        printf 'flock'
        return 0
      fi
      ;;
    Linux)
      if command -v flock >/dev/null 2>&1; then
        printf 'flock'
        return 0
      fi
      if command -v lockf >/dev/null 2>&1; then
        printf 'lockf'
        return 0
      fi
      ;;
    *)
      if command -v flock >/dev/null 2>&1; then
        printf 'flock'
        return 0
      fi
      if command -v lockf >/dev/null 2>&1; then
        printf 'lockf'
        return 0
      fi
      ;;
  esac
  return 1
}

# Drop the public halt lock only if we still own it (exact owner token match).
# Always scrubs this process's temp scratch and any held reclaim gate. Safe
# when not held.
halt_lock_release() {
  local cur_owner
  # Always drop reclaim gate first so EXIT never leaves a kernel lock open
  # while clearing public ownership state.
  halt_lock_reclaim_gate_release
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

# Recover a legacy directory-form reclaim gate (older builds: mkdir + pid
# write). Live numeric owners are left alone (return 1 — fail closed). Dead,
# malformed, or ownerless dirs are removed with directory-only ops (rm pid
# file + rmdir) so a delayed migrator can never delete a regular-file
# successor that a peer already published at the same path. Returns 0 when
# the path is no longer a directory (or never was).
halt_lock_scrub_legacy_reclaim_dir() {
  local gate="$1" gpid
  [[ -d "$gate" ]] || return 0
  gpid=$(cat "${gate}/pid" 2>/dev/null || true)
  if [[ -n "$gpid" && "$gpid" =~ ^[0-9]+$ ]] && kill -0 "$gpid" 2>/dev/null; then
    return 1
  fi
  # Directory-only: never `rm -rf "$gate"` (would remove a regular-file
  # successor if a peer migrated between our checks). Also scrub hidden
  # regular-file children (e.g. crash debris) before rmdir.
  halt_lock_scrub_dir_file_children "$gate"
  rmdir "$gate" 2>/dev/null || true
  [[ ! -d "$gate" ]]
}

# Remove only direct regular-file/symlink children of a directory, including
# hidden names (Bash default globs omit dotfiles). Never removes `.`/`..`,
# never recurses into nested directories, never follows a nested dir to delete
# its contents, and never `rm -rf`s the directory path itself (a regular-file
# successor at that path must survive delayed cleanup). Nested directories are
# left in place so a subsequent rmdir fails closed. Local shopt only — no
# global dotglob/nullglob leakage.
halt_lock_scrub_dir_file_children() {
  local dir="$1" f base
  local _dg_was_on=0 _ng_was_on=0
  [[ -d "$dir" ]] || return 0
  shopt -q dotglob && _dg_was_on=1
  shopt -q nullglob && _ng_was_on=1
  shopt -s dotglob nullglob
  for f in "$dir"/*; do
    base="${f##*/}"
    # Bash globs never yield . / .., but reject explicitly if they appear.
    if [[ "$base" == "." || "$base" == ".." ]]; then
      continue
    fi
    # Symlinks first: -f follows links; we only want the direct child entry.
    if [[ -L "$f" ]]; then
      rm -f "$f" 2>/dev/null || true
    elif [[ -f "$f" ]]; then
      rm -f "$f" 2>/dev/null || true
    fi
    # Nested directories intentionally untouched (fail closed for rmdir).
  done
  if [[ "$_dg_was_on" -eq 0 ]]; then
    shopt -u dotglob
  fi
  if [[ "$_ng_was_on" -eq 0 ]]; then
    shopt -u nullglob
  fi
}

# Acquire the exclusive reclaim gate via a kernel-held advisory lock on a
# stable regular file. The gate file is never unlinked on success or release;
# closing the open fd drops the lock (crash-safe, no ABA generation).
# Returns 0 with HALT_LOCK_RECLAIM_HELD=1; 1 if a peer holds it, a live legacy
# directory owner remains, no lockf/flock backend is available, no free fd in
# the bounded high range, or the bounded wait expires.
halt_lock_reclaim_gate_acquire() {
  local gate backend timeout fd
  gate="${HALT_LOCK_RECLAIM_GATE:-$STATE_DIR/.halt-lock.reclaiming}"
  timeout="${HALT_LOCK_RECLAIM_TIMEOUT:-2}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=2

  if [[ "${HALT_LOCK_RECLAIM_HELD:-0}" -eq 1 ]]; then
    return 0
  fi

  # Migrate legacy directory form before opening a regular gate file.
  if [[ -d "$gate" ]]; then
    if ! halt_lock_scrub_legacy_reclaim_dir "$gate"; then
      return 1
    fi
  fi
  if [[ -d "$gate" ]]; then
    return 1
  fi

  # Ensure a stable regular gate file. Never remove an existing path here —
  # once migrated, the regular file is permanent kernel-lock state.
  if [[ ! -f "$gate" ]]; then
    if [[ -e "$gate" ]]; then
      return 1
    fi
    # Create empty file; content is irrelevant (no ownership protocol).
    : >> "$gate" 2>/dev/null || return 1
  fi
  [[ -f "$gate" ]] || return 1

  if ! backend=$(halt_lock_reclaim_backend); then
    echo "warning: halt reclaim gate unavailable (need lockf on macOS or flock on Linux) — fail closed, no work" >&2
    return 1
  fi

  # Collision-free fd: scan a bounded high range for a descriptor that is
  # neither read-open nor write-open. Never retarget an inherited fd — on
  # Bash 3.2 `exec N>>file` leaves N pointing at its prior target when N is
  # already open. Store HALT_LOCK_RECLAIM_FD only after kernel lock success.
  if ! fd=$(halt_lock_pick_reclaim_fd); then
    echo "warning: halt reclaim gate: no free file descriptor in range — fail closed, no work" >&2
    return 1
  fi
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1

  # Open the stable gate on the selected free fd (append: no truncate race).
  eval "exec ${fd}>>\"\$gate\"" || return 1

  case "$backend" in
    lockf)
      # lockf -t N <fd>: acquire on this open file description; -s silent.
      if ! lockf -s -t "$timeout" "$fd"; then
        eval "exec ${fd}>&-" 2>/dev/null || true
        return 1
      fi
      ;;
    flock)
      # flock -w N <fd>: util-linux wait; exclusive by default.
      if ! flock -w "$timeout" "$fd"; then
        eval "exec ${fd}>&-" 2>/dev/null || true
        return 1
      fi
      ;;
    *)
      eval "exec ${fd}>&-" 2>/dev/null || true
      return 1
      ;;
  esac

  # Publish selected fd only after successful kernel acquisition.
  HALT_LOCK_RECLAIM_FD="$fd"
  HALT_LOCK_RECLAIM_HELD=1
  return 0
}

# Release the reclaim gate by closing the held fd. Kernel drops the advisory
# lock. The regular gate file is intentionally left in place (never unlinked).
# Closes only the fd we stored after a successful acquire — never an inherited
# descriptor we did not open for the gate.
halt_lock_reclaim_gate_release() {
  local fd="${HALT_LOCK_RECLAIM_FD:-}"
  if [[ "${HALT_LOCK_RECLAIM_HELD:-0}" -ne 1 ]]; then
    return 0
  fi
  HALT_LOCK_RECLAIM_HELD=0
  HALT_LOCK_RECLAIM_FD=""
  if [[ -n "$fd" && "$fd" =~ ^[0-9]+$ ]]; then
    eval "exec ${fd}>&-" 2>/dev/null || true
  fi
}

# Reclaim a dead or malformed lock without racing a live successor.
#
# Two hazards:
# 1) Check-then-rm on the public path without mutual exclusion: reclaimer A and
#    B both classify the same stale record; B unlinks it; a successor publishes
#    via ln; A's late rm steals the successor.
# 2) Unlink must target the exact inode we classified, not whatever name now
#    sits at the lock path.
#
# Protocol: hard-link pin the published inode → classify via the pin → take the
# kernel-held reclaim gate (lockf/flock on a stable fd) → unlink the public name
# only if it still refers to the pinned inode and that inode is still stale →
# drop gate (close fd) and pin. A second reclaimer either fails the pin (gone),
# fails the gate (peer reclaiming), or sees a different inode at the public
# path (successor already published). The reclaim gate itself is never removed
# by check-then-rm — only kernel lock state serializes reclaimers.
halt_lock_try_reclaim_stale() {
  local owner pid pin ino cur_ino stale=0 live_legacy=0

  # Legacy directory form from older builds: reclaim empty/dead dirs so an
  # upgraded process is not permanently blocked by a leftover halt-lock/.
  # Serialized under the same kernel gate as file reclaim. Also scrub regular
  # files left inside by a mistaken `ln temp dir` (ln links into directories),
  # including hidden crash debris (`.halt-lock.*`) that plain `*` globs omit.
  if [[ -d "$HALT_LOCK_FILE" ]]; then
    if ! halt_lock_reclaim_gate_acquire; then
      return 0
    fi
    if [[ -d "$HALT_LOCK_FILE" ]]; then
      live_legacy=0
      if [[ -f "${HALT_LOCK_FILE}/pid" ]]; then
        pid=$(cat "${HALT_LOCK_FILE}/pid" 2>/dev/null || true)
        if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
          live_legacy=1
        fi
      fi
      if [[ "$live_legacy" -eq 0 ]]; then
        # Direct regular-file/symlink children only (incl. hidden). Nested
        # directories are left alone so rmdir fails closed. Never rm -rf the
        # public path (would delete a regular-file successor).
        halt_lock_scrub_dir_file_children "$HALT_LOCK_FILE"
        rmdir "$HALT_LOCK_FILE" 2>/dev/null || true
      fi
    fi
    halt_lock_reclaim_gate_release
    return 0
  fi

  [[ -f "$HALT_LOCK_FILE" ]] || return 0

  # Pin the exact inode currently published as the lock.
  pin=$(mktemp "${STATE_DIR}/.halt-lock.reclaim.XXXXXX") || return 0
  rm -f "$pin"
  if ! ln "$HALT_LOCK_FILE" "$pin" 2>/dev/null; then
    return 0
  fi

  owner=$(halt_lock_field owner "$pin") || owner=""
  pid=$(halt_lock_field pid "$pin") || pid=""
  if [[ -z "$owner" || -z "$pid" ]] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    stale=1
  elif ! kill -0 "$pid" 2>/dev/null; then
    stale=1
  fi
  if [[ "$stale" -ne 1 ]]; then
    rm -f "$pin"
    return 0
  fi

  ino=$(halt_lock_inode "$pin") || { rm -f "$pin"; return 0; }

  if ! halt_lock_reclaim_gate_acquire; then
    rm -f "$pin"
    return 0
  fi

  # Unlink the public name only if it still names the inode we classified.
  # Safe under the exclusive kernel reclaim gate: no peer reclaimer runs, and a
  # successor cannot ln-publish while this inode still occupies the public name.
  cur_ino=$(halt_lock_inode "$HALT_LOCK_FILE" 2>/dev/null || true)
  if [[ -n "$cur_ino" && "$cur_ino" == "$ino" ]]; then
    # Re-confirm the pinned inode is still a stale record (content is fixed for
    # a given inode under our publish protocol; re-read is defensive).
    owner=$(halt_lock_field owner "$pin") || owner=""
    pid=$(halt_lock_field pid "$pin") || pid=""
    if [[ -z "$owner" || -z "$pid" ]] || ! [[ "$pid" =~ ^[0-9]+$ ]] \
      || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$HALT_LOCK_FILE"
    fi
  fi

  halt_lock_reclaim_gate_release
  rm -f "$pin"
}

# Acquire exclusive halt transition lock. Wait for peers (ordinary launchd is
# uncontended and returns immediately). Steal only when the owner is dead or
# the lock is malformed. Returns 1 after a bounded wait so a stuck lock fails
# closed (no work).
halt_lock_acquire() {
  local tries=0 max_tries=400 tmp owner_token tmp_ino pub_ino pub_owner
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
    # NOTE: `ln temp existing-dir` succeeds by linking *into* the directory —
    # that is not ownership of the public lock path. Reject directory results.
    # Ownership race: after ln into a legacy dir, a peer can rmdir + publish a
    # regular successor before our type checks; `-f public` alone must not
    # claim that successor. Require same inode as still-present temp + exact
    # owner token before setting HALT_LOCK_HELD.
    if ln "$tmp" "$HALT_LOCK_FILE" 2>/dev/null; then
      if [[ -d "$HALT_LOCK_FILE" ]]; then
        # Mistaken link-into-directory: remove only this attempt's debris/temp
        # and fall through to reclaim. Do not claim ownership.
        rm -f "${HALT_LOCK_FILE}/${tmp##*/}" 2>/dev/null || true
        rm -f "$tmp"
        HALT_LOCK_TMP=""
      elif [[ -f "$HALT_LOCK_FILE" ]]; then
        tmp_ino=$(halt_lock_inode "$tmp" 2>/dev/null || true)
        pub_ino=$(halt_lock_inode "$HALT_LOCK_FILE" 2>/dev/null || true)
        pub_owner=$(halt_lock_field owner "$HALT_LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$tmp_ino" && -n "$pub_ino" && "$tmp_ino" == "$pub_ino" \
          && -e "$tmp" && -n "$pub_owner" && "$pub_owner" == "$owner_token" ]]; then
          rm -f "$tmp"
          HALT_LOCK_TMP=""
          HALT_LOCK_OWNER="$owner_token"
          HALT_LOCK_HELD=1
          return 0
        fi
        # Public path is not this attempt's inode/token (peer successor or
        # lost temp). Remove only our known debris/temp; never unlink a
        # successor at the public path.
        if [[ -d "$HALT_LOCK_FILE" ]]; then
          rm -f "${HALT_LOCK_FILE}/${tmp##*/}" 2>/dev/null || true
        fi
        rm -f "$tmp"
        HALT_LOCK_TMP=""
      else
        rm -f "$tmp"
        HALT_LOCK_TMP=""
      fi
    else
      rm -f "$tmp"
      HALT_LOCK_TMP=""
    fi
    halt_lock_try_reclaim_stale
    # ~50ms; fall back to 1s if fractional sleep is unavailable.
    sleep 0.05 2>/dev/null || sleep 1
    tries=$((tries + 1))
  done
  return 1
}

# Ensure lock is dropped on abnormal exit while held (token-checked release).
# Only fire at the shell depth that installed the trap: pipeline/subshell
# helpers inherit HALT_LOCK_HELD and must not unlink the parent's live lock.
# halt_lock_release also closes any held reclaim-gate fd.
if [[ -z "${_GIBSON_HALT_LOCK_TRAP:-}" ]]; then
  _GIBSON_HALT_LOCK_TRAP=1
  _GIBSON_HALT_LOCK_TRAP_DEPTH=${BASH_SUBSHELL:-0}
  trap '[[ "${BASH_SUBSHELL:-0}" -eq "${_GIBSON_HALT_LOCK_TRAP_DEPTH:-0}" ]] && halt_lock_release' EXIT
fi

halt_latch_field() {
  local key="$1" line
  [[ -f "$HALT_LATCH_FILE" ]] || return 0
  # No pipelines — same EXIT-trap hazard as halt_lock_field (latch is read
  # while the halt transition lock is held).
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "${key}="*)
        printf '%s' "${line#*=}"
        return 0
        ;;
    esac
  done < "$HALT_LATCH_FILE"
  return 0
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

# Ensure loop-state exists only AFTER a clean kill-switch check. A remote halt
# on a cold start must not create or rewrite this (issue #71). Default content
# is the full ten-key contract (issue #75); missing keys on an existing file are
# NOT silently repaired — validate_loop_state fails closed instead.
# Never write through an existing non-file path (directory/symlink/device): leave
# it for pre-read validation + quarantine/restore (issue #75).
ensure_loop_state() {
  mkdir -p "$STATE_DIR"
  if [[ ! -e "$STATE_FILE" && ! -L "$STATE_FILE" ]]; then
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
  if [[ ! -e "$JOURNAL" && ! -L "$JOURNAL" ]]; then
    echo "# Gibson loop journal" > "$JOURNAL"
  fi
}

# --- loop-state validation / snapshot / recovery (issue #75) -----------------

validate_loop_state_bin() {
  if [[ -z "$VALIDATE_LOOP_STATE" ]]; then
    VALIDATE_LOOP_STATE="$GIBSON/scripts/validate-loop-state.sh"
  fi
  [[ -x "$VALIDATE_LOOP_STATE" || -f "$VALIDATE_LOOP_STATE" ]] \
    || die "missing validate-loop-state.sh at $VALIDATE_LOOP_STATE"
  printf '%s' "$VALIDATE_LOOP_STATE"
}

# Run the shared validator. Optional second arg is --min-updated bound.
# Prints diagnostics on stderr (via the validator); returns 0/1.
run_validate_loop_state() {
  local file="$1" min="${2:-}" bin
  bin=$(validate_loop_state_bin)
  if [[ -n "$min" ]]; then
    bash "$bin" "$file" --min-updated "$min"
  else
    bash "$bin" "$file"
  fi
}

# Strict UTC now — same grammar the validator accepts. python3 argv-safe.
# python3 is a hard runtime dependency for timestamp validation (issue #75).
require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required for loop-state timestamp validation (issue #75); install python3 or put it on PATH"
  fi
}

strict_utc_now() {
  require_python3
  python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

# Path shape helpers for snapshot/restore destinations (issue #75).
# Never follow symlinks; never treat a directory/device as a replaceable file.
# `mv -f temp dir` would nest the temp inside dir and return 0 — that is not success.
is_regular_nonsymlink_file() {
  # Exists as a regular file and is not a symlink ( -f follows links; -L first).
  [[ ! -L "$1" && -f "$1" ]]
}

dest_ok_for_atomic_file_replace() {
  # Missing is OK (create). Existing must be a regular non-symlink file.
  if [[ -L "$1" ]]; then return 1; fi
  if [[ -e "$1" ]]; then
    [[ -f "$1" ]] || return 1
  fi
  return 0
}

path_shape_label() {
  if [[ -L "$1" ]]; then
    printf '%s' "symlink"
  elif [[ -d "$1" ]]; then
    printf '%s' "directory"
  elif [[ -f "$1" ]]; then
    printf '%s' "file"
  elif [[ -e "$1" ]]; then
    printf '%s' "special"
  else
    printf '%s' "missing"
  fi
}

# Atomic same-filesystem snapshot of the validated pre-iteration state.
# Temp + rename so readers never see a partial .loop-state.prev.
# Refuses unsafe destinations (directory/symlink/device) before creating temps
# that could be nested into them. Claims success only when the exact destination
# path is a regular non-symlink file byte-identical to the source.
snapshot_loop_state() {
  local tmp shape
  mkdir -p "$STATE_DIR" || return 1
  if ! is_regular_nonsymlink_file "$STATE_FILE"; then
    info "snapshot refused: live loop-state is not a regular non-symlink file (shape=$(path_shape_label "$STATE_FILE"))"
    return 1
  fi
  if ! dest_ok_for_atomic_file_replace "$STATE_SNAPSHOT"; then
    shape=$(path_shape_label "$STATE_SNAPSHOT")
    info "snapshot refused: $STATE_SNAPSHOT is not a safe file destination (shape=$shape) — not nesting a temp inside it"
    return 1
  fi
  tmp=$(mktemp "${STATE_DIR}/.loop-state.prev.XXXXXX") || return 1
  if ! cp "$STATE_FILE" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$STATE_SNAPSHOT"; then
    rm -f "$tmp"
    return 1
  fi
  # Success only if the exact destination path is the intended regular file.
  if ! is_regular_nonsymlink_file "$STATE_SNAPSHOT"; then
    info "snapshot incomplete: destination is not a regular non-symlink file after move"
    return 1
  fi
  if ! cmp -s "$STATE_FILE" "$STATE_SNAPSHOT"; then
    info "snapshot incomplete: destination bytes differ from live loop-state"
    return 1
  fi
  return 0
}

# Restore STATE_FILE byte-for-byte from the last valid snapshot. Never writes
# through a partial file (temp + rename). Returns 0 only on exact restore.
# Unsafe live destinations (directory/symlink/device) are quarantined by rename
# in the same parent — never deleted — then the exact snapshot is installed.
# If quarantine or install cannot make the exact path a regular file matching
# the snapshot, fail closed (recovery-incomplete); never claim success.
restore_loop_state_from_snapshot() {
  local tmp shape quarantine
  if ! is_regular_nonsymlink_file "$STATE_SNAPSHOT"; then
    info "restore refused: snapshot is not a regular non-symlink file (shape=$(path_shape_label "$STATE_SNAPSHOT"))"
    return 1
  fi

  if [[ -L "$STATE_FILE" || ( -e "$STATE_FILE" && ! -f "$STATE_FILE" ) ]]; then
    shape=$(path_shape_label "$STATE_FILE")
    quarantine="${STATE_DIR}/loop-state.md.corrupt-quarantine.$(date -u +%Y%m%dT%H%M%SZ).$$"
    # Refuse to clobber an existing quarantine name; fail closed instead.
    if [[ -e "$quarantine" || -L "$quarantine" ]]; then
      info "recovery-incomplete: quarantine target already exists ($quarantine); leaving unsafe live path untouched (shape=$shape)"
      return 1
    fi
    if ! mv -f "$STATE_FILE" "$quarantine"; then
      info "recovery-incomplete: could not quarantine unsafe loop-state (shape=$shape); leaving it untouched — exact restore did not occur"
      return 1
    fi
    info "state-corrupt: quarantined unsafe loop-state ($shape) to $(basename "$quarantine") — contents preserved, not deleted"
  fi

  # Destination must now be missing or a regular non-symlink file.
  if ! dest_ok_for_atomic_file_replace "$STATE_FILE"; then
    info "recovery-incomplete: live loop-state destination still unsafe after quarantine (shape=$(path_shape_label "$STATE_FILE"))"
    return 1
  fi

  tmp=$(mktemp "${STATE_DIR}/.loop-state.restore.XXXXXX") || return 1
  if ! cp "$STATE_SNAPSHOT" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$STATE_FILE"; then
    rm -f "$tmp"
    info "recovery-incomplete: atomic restore move failed"
    return 1
  fi
  if ! is_regular_nonsymlink_file "$STATE_FILE"; then
    info "recovery-incomplete: live path is not a regular non-symlink file after restore"
    return 1
  fi
  if ! cmp -s "$STATE_SNAPSHOT" "$STATE_FILE"; then
    info "recovery-incomplete: restored bytes do not match snapshot"
    return 1
  fi
  return 0
}

# Journal a distinct state-corrupt section with validator diagnostics and a
# unified diff between snapshot (if any) and the corrupt state. Does not
# modify either file itself.
journal_state_corrupt() {
  local phase="$1"   # pre-read | post-run | snapshot | snapshot-missing
  local diag_file="$2"
  mkdir -p "$STATE_DIR"
  if [[ ! -f "$JOURNAL" ]]; then
    echo "# Gibson loop journal" > "$JOURNAL"
  fi
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · state-corrupt · phase=$phase"
    echo "diagnosis: loop-state failed schema/freshness validation (issue #75)."
    echo "runner was not started or handoff was suppressed; not counted as runner-failure."
    if [[ -f "$diag_file" ]]; then
      echo "validator diagnostics:"
      cat "$diag_file"
    fi
    if is_regular_nonsymlink_file "$STATE_SNAPSHOT" && is_regular_nonsymlink_file "$STATE_FILE"; then
      echo "unified diff (snapshot vs current state):"
      # diff returns 1 on differences — expected; never fail the journal write.
      diff -u "$STATE_SNAPSHOT" "$STATE_FILE" || true
    elif ! is_regular_nonsymlink_file "$STATE_SNAPSHOT"; then
      echo "snapshot: missing or unusable (fail closed; no guessed repair)."
    fi
  } >> "$JOURNAL"
}

# Handle a state-corrupt event: journal, attempt exact-byte restore when the
# snapshot itself still validates, count exactly one failure-budget unit.
# Never overwrites the snapshot with corrupt content. Never starts a runner
# or hands off. Returns after accounting; caller continues the loop or dies
# on budget.
handle_state_corrupt() {
  local phase="$1"
  local diag_file
  diag_file=$(mktemp "${TMPDIR:-/tmp}/gibson-state-corrupt.XXXXXX")
  # Re-run validator to capture diagnostics into the journal file (stderr).
  # Best-effort: ignore its exit (we already know it failed or snapshot is bad).
  case "$phase" in
    post-run:*)
      # phase encoded as post-run:<min-updated>
      local min="${phase#post-run:}"
      phase="post-run"
      run_validate_loop_state "$STATE_FILE" "$min" 2>"$diag_file" || true
      ;;
    *)
      run_validate_loop_state "$STATE_FILE" 2>"$diag_file" || true
      ;;
  esac

  journal_state_corrupt "$phase" "$diag_file"
  rm -f "$diag_file"

  # Restore only when the snapshot is a regular non-symlink file AND still
  # validates. A corrupt, missing, or unsafe-shape snapshot fails closed
  # without inventing default state. Restore itself refuses directory/symlink
  # destinations unless it can quarantine them first (exact path restored).
  if is_regular_nonsymlink_file "$STATE_SNAPSHOT"; then
    if run_validate_loop_state "$STATE_SNAPSHOT" 2>/dev/null; then
      if restore_loop_state_from_snapshot; then
        info "state-corrupt: restored loop-state byte-for-byte from snapshot"
      else
        info "state-corrupt: snapshot validated but restore failed (recovery-incomplete) — not claiming exact restore"
      fi
    else
      info "state-corrupt: snapshot present but unusable — fail closed, no restore"
      {
        echo ""
        echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · state-corrupt · phase=snapshot-unusable"
        echo "snapshot exists but failed validation; neither file was overwritten with guessed content."
      } >> "$JOURNAL"
    fi
  else
    info "state-corrupt: no usable snapshot (shape=$(path_shape_label "$STATE_SNAPSHOT")) — fail closed, loop-state left as-is"
  fi

  failures=$((failures + 1))
  info "state-corrupt (consecutive failures=$failures/$BUDGET)"
  if [[ "$ESCALATE_AFTER" -gt 0 && $failures -eq "$ESCALATE_AFTER" ]]; then
    escalate
  fi
  if [[ $failures -ge $BUDGET ]]; then
    die "error budget exhausted — state-corrupt recovery could not stabilize (docs/11, issue #75)"
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

# Read one column-zero key from loop-state using the SAME field grammar as
# scripts/validate-loop-state.sh (issue #75): after the first colon, strip at
# most one optional ASCII space; no further trim; empty values allowed.
# Accepts `key:value` and `key: value` identically. Tabs after `:` stay in the
# value. Does not invent defaults. Callers must only read after schema validate
# on real iterations (pre-read gate), so a missing key is an internal error path.
read_field() {
  local key="$1"
  # shellcheck disable=SC2016
  awk -v k="$key" '
    # Column-zero keys only — same pattern as validate-loop-state.sh
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
  ' "$STATE_FILE"
}

render_prompt() {
  local hat="$1"
  # State is read by path inside node (process.argv[3]); no shell-side cat.
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
  else
    # Optional reviewer args (e.g. --solo-platform). Bash 3.2 + set -u treats
    # "${empty[@]}" as unbound; ${arr[@]+"${arr[@]}"} expands to nothing when
    # empty and to the real elements when populated — no fabricated "" argv (#144).
    local esc_extra=()
    [[ "$SOLO_PLATFORM" -eq 1 ]] && esc_extra+=(--solo-platform)
    if "$SCRIPT_DIR/second-opinion.sh" \
        --repo "$REPO" --reviewers "$REVIEWERS" --author "$RUNNER" --base "$base_sha" \
        --gate-status "red: $failures consecutive runner failures" --out "$out" \
        ${esc_extra[@]+"${esc_extra[@]}"} >/dev/null 2>&1; then
      info "second opinion written to $out (base $base @ $base_sha)"
      note="Second opinion against \`$base\` @ \`$base_sha\` written to gibson/second-opinion.md — next hat must read it."
    else
      info "second opinion failed (non-fatal) — continuing"
      note="No reviewer completed — see gibson/second-opinion.md for the raw attempts (Law 8)."
    fi
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
    block "no reviewers configured: --reviewers is empty, so there is no reviewer to run and nobody may approve $branch @ $sha (Law 5). Re-run with --reviewers, or --solo-platform for single-vendor mode (#69)."
    return 1
  fi
  local distinct=0 name vendor
  local names=()
  IFS=',' read -ra names <<< "$REVIEWERS"
  for name in "${names[@]}"; do
    name=$(echo "$name" | tr -d '[:space:]')
    [[ -n "$name" ]] || continue
    if [[ "$name" == *:* ]]; then
      vendor="${name%%:*}"
    else
      vendor="$name"
    fi
    if [[ "$vendor" != "$RUNNER" ]]; then
      distinct=1
    elif [[ "$SOLO_PLATFORM" -eq 1 ]]; then
      # Same vendor + solo-platform counts as a present reviewer (fresh context /
      # alt model). Issue #69: no-deadlock rule for single-platform installs.
      distinct=1
    fi
  done
  if [[ "$distinct" -eq 0 ]]; then
    block "no distinct vendor: --reviewers '$REVIEWERS' contains no vendor other than the runner ($RUNNER), and nobody grades their own homework (Law 5). Add a different vendor to --reviewers, or re-run with --solo-platform (#69)."
    return 1
  fi

  # Remove first: a review that fails halfway must never leave a passing receipt.
  rm -f "$REVIEW_RECEIPT"
  info "running the mandatory distinct-vendor review of $branch @ $sha against $base @ $base_sha before handoff (Law 5)"
  # --base is the exact base SHA, not the branch name: the reviewer must see the
  # same two endpoints the receipt records.
  # Same Bash 3.2 + set -u empty-array rule as escalate() (#144).
  local so_extra=()
  [[ "$SOLO_PLATFORM" -eq 1 ]] && so_extra+=(--solo-platform)
  if "$SCRIPT_DIR/second-opinion.sh" \
      --repo "$REPO" --reviewers "$REVIEWERS" --author "$RUNNER" \
      --base "$base_sha" --branch "$sha" \
      --gate-status "pre-handoff mandatory review of $branch @ $sha against $base @ $base_sha" \
      --out "$out" ${so_extra[@]+"${so_extra[@]}"} >/dev/null; then
    printf 'sha: %s\nbranch: %s\nbase: %s\nbase_sha: %s\nauthor: %s\nreviewers: %s\nreviewed: %s\nstatus: ok\nsolo_platform: %s\n' \
      "$sha" "$branch" "$base" "$base_sha" "$RUNNER" "$REVIEWERS" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      "$SOLO_PLATFORM" > "$REVIEW_RECEIPT"
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

  # --dry-run / --print-prompt stay inert w.r.t. snapshot/recovery/journal
  # mutations introduced by #75 (no runner, no handoff, no .loop-state.prev).
  # Real iterations: validate BEFORE reading next_hat — never silently default
  # a missing/malformed next_hat to builder (issue #75).
  local_skip_runner=0
  if [[ "$PRINT" -eq 0 && "$DRY" -eq 0 ]]; then
    if ! run_validate_loop_state "$STATE_FILE" 2>/dev/null; then
      # Capture diagnostics for the journal (validator was quieted above).
      handle_state_corrupt "pre-read"
      local_skip_runner=1
    else
      # Pre-queued handoff retry (issue #71 + #75): when a supervisor is
      # configured and loop-state already carries a non-empty handoff field,
      # retry that handoff WITHOUT invoking a runner / snapshot / post-run
      # freshness path. A zero-work no-op must not be treated as successful
      # iteration progress (would reset failures and fake freshness). Schema
      # already passed above; do not reset the failure budget here.
      if [[ "$SUPERVISOR" == "devin" ]]; then
        _queued_handoff=$(read_field handoff)
        if [[ -n "$_queued_handoff" ]]; then
          info "pre-queued handoff: retrying supervisor handoff of $_queued_handoff without runner (issue #71/#75)"
          supervisor_handoff
          local_skip_runner=1
        fi
        unset _queued_handoff
      fi
    fi
  fi

  if [[ "$local_skip_runner" -eq 0 ]]; then
    if [[ -n "$FORCE_HAT" ]]; then
      hat="$FORCE_HAT"
    else
      hat=$(read_field next_hat)
      # After a successful schema validate, next_hat is a real hat. For dry-run
      # / print-prompt (no validate), refuse the old silent builder default when
      # the field is empty — fail closed with a clear error instead.
      if [[ -z "$hat" ]]; then
        if [[ "$PRINT" -eq 1 || "$DRY" -eq 1 ]]; then
          die "next_hat missing or empty in $STATE_FILE (refusing silent default to builder; issue #75)"
        fi
        die "next_hat empty after validation — internal error"
      fi
    fi
    FORCE_HAT=""

    info "iteration hat=$hat repo=$REPO"

    PROMPT_FILE=$(mktemp)
    render_prompt "$hat" > "$PROMPT_FILE"

    if [[ "$PRINT" -eq 1 ]]; then
      cat "$PROMPT_FILE"
      rm -f "$PROMPT_FILE"
      exit 0
    fi

    # Normal-completion journal only when the iteration did not land as
    # state-corrupt (snapshot failure or post-run schema/freshness fail).
    # Empty/malformed/stale updated after a real runner must never look like a
    # successful iteration in the journal (issue #75 fail-closed contract).
    journal_normal_completion=1
    if [[ "$DRY" -eq 1 ]]; then
      info "dry-run: would invoke $RUNNER with rendered loop-step ($hat)"
      rm -f "$PROMPT_FILE"
    else
      # Snapshot the validated pre-iteration state immediately before the real
      # runner. Snapshot failure is a single state-corrupt/recovery-control
      # failure — never a silent continuation into the runner.
      if ! snapshot_loop_state; then
        journal_normal_completion=0
        info "state-corrupt: failed to snapshot pre-iteration loop-state"
        diag_snap=$(mktemp "${TMPDIR:-/tmp}/gibson-snap-fail.XXXXXX")
        echo "snapshot failed: could not atomically copy $STATE_FILE to $STATE_SNAPSHOT" > "$diag_snap"
        journal_state_corrupt "snapshot" "$diag_snap"
        rm -f "$diag_snap" "$PROMPT_FILE"
        failures=$((failures + 1))
        info "state-corrupt (consecutive failures=$failures/$BUDGET)"
        if [[ "$ESCALATE_AFTER" -gt 0 && $failures -eq "$ESCALATE_AFTER" ]]; then
          escalate
        fi
        if [[ $failures -ge $BUDGET ]]; then
          die "error budget exhausted — state-corrupt recovery could not stabilize (docs/11, issue #75)"
        fi
      else
        iteration_start=$(strict_utc_now)
        prepare_repo_boundary_guard
        set +e
        PATH="$GUARD_PATH" \
          GIBSON_REAL_GIT="$GUARD_REAL_GIT" \
          GIBSON_TARGET_REPO="$TARGET_REPO_REALPATH" \
          GIBSON_EXPECTED_REPO_SLUG="$EXPECTED_REPO_SLUG" \
          invoke_runner "$PROMPT_FILE"
        ec=$?
        set -e
        clear_repo_boundary_guard
        rm -f "$PROMPT_FILE"

        # Cost meter (#74): record wall time after every real runner invocation.
        # Uses iteration_start (strict UTC) when wall ms are not pre-set.
        if [[ -n "${GIBSON_COST_LEDGER:-}" ]]; then
          _cl_wall="${ITERATION_WALL_MS:-0}"
          if [[ -z "${ITERATION_WALL_MS:-}" && -n "${iteration_start:-}" ]]; then
            _cl_now=$(date -u +%s 2>/dev/null || echo 0)
            # iteration_start is ISO-8601; best-effort epoch via date -d when available
            if _cl_start_epoch=$(date -u -d "$iteration_start" +%s 2>/dev/null); then
              _cl_wall=$(( (_cl_now - _cl_start_epoch) * 1000 ))
            elif _cl_start_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iteration_start" +%s 2>/dev/null); then
              _cl_wall=$(( (_cl_now - _cl_start_epoch) * 1000 ))
            fi
            # clamp negative (clock skew) to 0
            [[ "$_cl_wall" -lt 0 ]] && _cl_wall=0
          fi
          cost_ledger_record_iteration "${_cl_wall}" "${hat:-loop-step}"
        fi

        if ! guard_control_plane_clean; then
          journal_normal_completion=0
          die "repo-boundary guard rejected runner iteration: harness control-plane was created or modified"
        fi

        # Post-run validation (issue #75): after EVERY actual runner invocation,
        # state must pass schema AND updated >= iteration_start before any
        # success path. The one deliberate exception is an exit-0 runner that
        # leaves loop-state byte-for-byte unchanged: the pre-run state already
        # passed schema validation, and this is the distinct no-progress event
        # described by L-008, not schema corruption. Any changed state that is
        # stale or malformed remains state-corrupt.
        # Pre-queued handoff retries are routed before runner/snapshot above so
        # they never depend on faking progress through a no-op runner.
        post_diag=$(mktemp "${TMPDIR:-/tmp}/gibson-post-val.XXXXXX")
        post_min="$iteration_start"
        unchanged_zero=0
        if [[ "$ec" -eq 0 ]] &&
          is_regular_nonsymlink_file "$STATE_SNAPSHOT" &&
          is_regular_nonsymlink_file "$STATE_FILE" &&
          cmp -s "$STATE_SNAPSHOT" "$STATE_FILE"; then
          unchanged_zero=1
        fi
        if [[ "$unchanged_zero" -eq 0 ]] &&
          ! run_validate_loop_state "$STATE_FILE" "$post_min" 2>"$post_diag"; then
          journal_normal_completion=0
          # state-corrupt takes precedence over runner-failure even when ec != 0.
          # Count exactly once as state-corrupt; do not also count runner-failure.
          {
            echo ""
            echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · state-corrupt · phase=post-run"
            echo "diagnosis: post-run loop-state failed schema/freshness validation (issue #75)."
            echo "iteration_start: $iteration_start"
            echo "freshness: updated must be >= $post_min after every real runner invocation (byte-identical state included)."
            echo "runner_exit: $ec (not counted separately; state-corrupt takes precedence)"
            echo "validator diagnostics:"
            cat "$post_diag"
            if is_regular_nonsymlink_file "$STATE_SNAPSHOT" && is_regular_nonsymlink_file "$STATE_FILE"; then
              echo "unified diff (snapshot vs current state):"
              diff -u "$STATE_SNAPSHOT" "$STATE_FILE" || true
            elif ! is_regular_nonsymlink_file "$STATE_SNAPSHOT"; then
              echo "snapshot: missing or unusable (fail closed; no guessed repair)."
            fi
          } >> "$JOURNAL"
          rm -f "$post_diag"

          if is_regular_nonsymlink_file "$STATE_SNAPSHOT"; then
            if run_validate_loop_state "$STATE_SNAPSHOT" 2>/dev/null; then
              if restore_loop_state_from_snapshot; then
                info "state-corrupt: restored loop-state byte-for-byte from snapshot"
              else
                info "state-corrupt: snapshot validated but restore failed (recovery-incomplete) — not claiming exact restore"
              fi
            else
              info "state-corrupt: snapshot present but unusable — fail closed, no restore"
              {
                echo ""
                echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · state-corrupt · phase=snapshot-unusable"
                echo "snapshot exists but failed validation; neither file was overwritten with guessed content."
              } >> "$JOURNAL"
            fi
          else
            info "state-corrupt: no usable snapshot (shape=$(path_shape_label "$STATE_SNAPSHOT")) — fail closed, loop-state left as-is"
          fi

          failures=$((failures + 1))
          info "state-corrupt (consecutive failures=$failures/$BUDGET)"
          if [[ "$ESCALATE_AFTER" -gt 0 && $failures -eq "$ESCALATE_AFTER" ]]; then
            escalate
          fi
          if [[ $failures -ge $BUDGET ]]; then
            die "error budget exhausted — state-corrupt recovery could not stabilize (docs/11, issue #75)"
          fi
        else
          rm -f "$post_diag"
          # Valid post-run state (schema + freshness), or the explicit
          # byte-identical exit-0 no-progress case above. Precedence from here:
          #   nonzero exit → runner-failure only (no no-progress sensor)
          #   exit 0       → silent_noop_progressed(snapshot, live)
          #                  progressed → reset failures+stale, may hand off
          #                  no-progress → one shared failure + one stale unit,
          #                                distinct journal, no reset/restore/handoff
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
            # Reuse the exact pre-run snapshot from #75 so crashes/recovery never
            # compare against a stale baseline. Stateless sensor API — no coupling
            # to silent-noop private globals.
            if silent_noop_progressed "$STATE_SNAPSHOT" "$STATE_FILE"; then
              # Substantive progress (any non-updated field, including handoff_sha
              # or same-length edits). Reset both counters; handoff may proceed.
              failures=0
              stale=0
              supervisor_handoff
            else
              # No substantive change — including clock-only updated: rewrites.
              # Count exactly once as no-progress (shared failure + stale); do not
              # also classify as runner-failure or state-corrupt. Do not restore
              # (state is schema-valid and fresh) and do not hand off.
              journal_normal_completion=0
              failures=$((failures + 1))
              stale=$((stale + 1))
              {
                echo ""
                echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · no-progress"
                echo "diagnosis: runner exited 0 without substantive loop-state progress (L-008 / issue #63)."
                echo "only the column-zero updated: clock is ignored; clock-only rewrites are no-progress."
                echo "stale: $stale/$STALE_BUDGET"
                echo "consecutive failures: $failures/$BUDGET"
                echo "runner_exit: 0 (not a crash; not state-corrupt)"
                echo "snapshot: $STATE_SNAPSHOT"
                echo "live: $STATE_FILE"
              } >> "$JOURNAL"
              info "no-progress (stale=$stale/$STALE_BUDGET, consecutive failures=$failures/$BUDGET) — L-008"
              if [[ "$ESCALATE_AFTER" -gt 0 && $failures -eq "$ESCALATE_AFTER" ]]; then
                escalate
              fi
              # Stop at the earlier of error-budget or stale-budget exhaustion,
              # always with a distinct no-progress diagnosis when no-progress
              # caused the stop (escalate happens before stop).
              if [[ $stale -ge $STALE_BUDGET ]]; then
                die "no-progress: stale budget exhausted ($stale/$STALE_BUDGET) — runner exited 0 without advancing substantive loop-state (L-008 / issue #63)"
              fi
              if [[ $failures -ge $BUDGET ]]; then
                die "no-progress: error budget exhausted ($failures/$BUDGET) — runner exited 0 without advancing substantive loop-state (L-008 / issue #63)"
              fi
            fi
          fi
        fi
      fi
    fi

    if [[ "$journal_normal_completion" -eq 1 ]]; then
      {
        echo ""
        echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · hat=$hat · runner=$RUNNER"
        echo "Driver completed iteration; agent should have updated loop-state."
      } >> "$JOURNAL"
    fi
  fi

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
