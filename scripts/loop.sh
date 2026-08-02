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
    The gibson-halt label is a human signal; when gh is available the driver
    also treats an open issue carrying that label as a soft halt cue.
  - Error budget (default 5 consecutive failures) stops the loop to avoid burn.
  - --escalate-after dispatches other vendors: more tokens, other providers see
    the diff. --supervisor devin sends finished branches to a cloud session that
    can open PRs and (if configured) merge (docs/22). When a supervisor is
    configured, a distinct-vendor second opinion of the exact handed-off SHA is
    required before handoff, and the gate fails closed: no review, no handoff.
    The branch stays queued in loop-state instead (Law 5 gate).
  - Reviews and handoffs diff against the target repo's own default branch,
    resolved from origin/HEAD (then the remote's advertised HEAD, then
    main/master). A repo whose base cannot be resolved blocks the handoff rather
    than guessing `main`.

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

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
GIBSON="${GIBSON:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLAYBOOK="$GIBSON/playbooks/loop-step.md"
[[ -f "$PLAYBOOK" ]] || die "missing $PLAYBOOK"

STATE_DIR="$REPO/gibson"
STATE_FILE="$STATE_DIR/loop-state.md"
JOURNAL="$STATE_DIR/journal.md"
HALT_FILE="$STATE_DIR/HALT"
# Written only by a successful pre-handoff review, and it names the SHA that was
# reviewed — see ensure_cross_vendor_review.
REVIEW_RECEIPT="$STATE_DIR/second-opinion.receipt"

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
[[ -f "$JOURNAL" ]] || echo "# Gibson loop journal" > "$JOURNAL"

# Kill switch: HALT file is primary. GIBSON_HALT=1 is checked unconditionally
# (previously only when `gh` was present — issue #55). When gh is available we
# also treat any open issue carrying the gibson-halt label as a soft signal.
halted() {
  if [[ -f "$HALT_FILE" ]]; then return 0; fi
  if [[ "${GIBSON_HALT:-}" == "1" ]]; then return 0; fi
  if command -v gh >/dev/null 2>&1; then
    if gh issue list --repo "$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#(git@[^:]+:|https?://[^/]+/)##; s/\.git$//' || true)" \
         --label gibson-halt --state open --limit 1 --json number -q '.[0].number' 2>/dev/null | grep -q '[0-9]'; then
      info "gibson-halt label detected on an open issue — treating as soft halt (write gibson/HALT to make permanent)"
      return 0
    fi
  fi
  return 1
}

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

# The branch every review and every handoff must diff against. Not every repo's
# trunk is called `main`: second-opinion.sh and devin-supervisor.sh both default
# to it, so a `master`/`develop` repo used to be reviewed against a ref that does
# not exist — which meant an empty diff at best and a working-tree diff at worst.
# Resolution order is local metadata first (no network), then the remote's
# advertised HEAD, then the conventional trunk names. Nothing is guessed: when
# none of those answer, this returns 1 and the caller fails closed.
resolve_base_branch() {
  local ref name
  ref=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -n "$ref" ]]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    name=$(git -C "$REPO" ls-remote --symref origin HEAD 2>/dev/null |
      awk '$1 == "ref:" && $3 == "HEAD" { sub(/^refs\/heads\//, "", $2); print $2; exit }') || true
    if [[ -n "$name" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi
  for name in main master; do
    if git -C "$REPO" rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1 ||
       git -C "$REPO" rev-parse --verify --quiet "refs/remotes/origin/$name" >/dev/null 2>&1; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  info "could not resolve a base branch for $REPO (no origin/HEAD, no remote HEAD, no main/master)"
  return 1
}

# The base *name* is what the supervisor needs (it opens a PR into a branch), but
# it is not always a ref this checkout can diff: a worktree parked on a feature
# branch routinely has `origin/main` and no local `main`. Reviews therefore use
# whichever form resolves here, and a name that resolves to neither is refused
# rather than handed to a reviewer that would die on it.
review_base_ref() {
  local name="$1"
  if git -C "$REPO" rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1; then
    printf '%s\n' "$name"
  elif git -C "$REPO" rev-parse --verify --quiet "refs/remotes/origin/$name" >/dev/null 2>&1; then
    printf 'origin/%s\n' "$name"
  else
    info "base branch '$name' resolves to no commit in $REPO (neither refs/heads/$name nor refs/remotes/origin/$name)"
    return 1
  fi
}

escalate() {
  local out="$STATE_DIR/second-opinion.md"
  info "escalating after $failures consecutive failures — reviewers: $REVIEWERS"
  # This clobbers second-opinion.md with a failure-triage review, so the
  # pre-handoff receipt that pointed at the old contents is no longer valid.
  rm -f "$REVIEW_RECEIPT"
  local base="" base_ref="" note
  if base=$(resolve_base_branch); then
    base_ref=$(review_base_ref "$base") || base_ref=""
  fi
  if [[ -z "$base_ref" ]]; then
    info "escalation review skipped — no base branch resolved, and a guessed base reviews the wrong diff"
    note="Escalation review skipped: the target repo's base branch could not be resolved (Law 8)."
  elif "$SCRIPT_DIR/second-opinion.sh" \
      --repo "$REPO" --reviewers "$REVIEWERS" --author "$RUNNER" --base "$base_ref" \
      --gate-status "red: $failures consecutive runner failures" --out "$out" >/dev/null 2>&1; then
    info "second opinion written to $out (base $base_ref)"
    note="Second opinion against \`$base_ref\` written to gibson/second-opinion.md — next hat must read it."
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
  # Explicit, not errexit-suppressed: "no origin configured" and "origin is
  # configured but unreachable" are different answers. The first is a local-only
  # repo and falls through to local refs; the second means we cannot tell whether
  # the tip moved, and handing off a tip we cannot confirm is exactly what the
  # pin exists to prevent.
  if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    if ls_out=$(git -C "$REPO" ls-remote origin "refs/heads/$branch" 2>/dev/null); then
      remote=$(printf '%s\n' "$ls_out" | awk 'NR==1 {print $1}')
    else
      info "git ls-remote origin refs/heads/$branch failed — cannot confirm the remote tip, refusing to hand off an unconfirmable branch"
      return 1
    fi
  fi
  if [[ -n "$pinned" && -n "$remote" && "$pinned" != "$remote" ]]; then
    info "loop-state pins $branch @ $pinned but the remote tip is $remote — refusing to hand off an unreviewed tip (issue #55)"
    return 1
  fi
  sha="${pinned:-$remote}"
  if [[ -z "$sha" ]]; then
    sha=$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$branch" || true)
  fi
  if [[ -z "$sha" ]]; then
    sha=$(git -C "$REPO" rev-parse --verify --quiet "refs/remotes/origin/$branch" || true)
  fi
  if [[ -z "$sha" ]]; then
    info "could not resolve a SHA for handoff branch $branch — an unpinnable branch cannot be reviewed or handed off"
    return 1
  fi
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
      info "commit $sha is still unresolvable locally after fetching $branch — refusing to record a review of an object nobody here can read"
      return 1
    fi
    info "fetched $sha into the local object database"
  fi
  printf '%s\n' "$sha"
}

# A receipt is written only when second-opinion.sh exited 0, and it names the
# exact SHA that was reviewed. That is what makes a stale gibson/second-opinion.md
# useless as a pass: the artifact alone proves nothing about which tip, which
# vendor, or whether the reviewer even finished (issue #55).
review_receipt_ok() {
  local sha="$1" base="$2"
  [[ -f "$REVIEW_RECEIPT" ]] || return 1
  [[ -s "$STATE_DIR/second-opinion.md" ]] || return 1
  grep -qxF "status: ok" "$REVIEW_RECEIPT" || return 1
  grep -qxF "sha: $sha" "$REVIEW_RECEIPT" || return 1
  grep -qxF "base: $base" "$REVIEW_RECEIPT" || return 1
  grep -qxF "author: $RUNNER" "$REVIEW_RECEIPT" || return 1
  grep -qxF "reviewers: $REVIEWERS" "$REVIEW_RECEIPT" || return 1
  return 0
}

# Law 5 gate: never grade your own homework. Returns 0 only when a reviewer from
# a different vendor completed successfully against exactly $sha. Every other
# outcome — no distinct vendor configured, reviewer CLI missing, reviewer
# non-zero, empty diff — returns 1, and the caller must not hand off.
ensure_cross_vendor_review() {
  local branch="$1" sha="$2" base="$3"
  local out="$STATE_DIR/second-opinion.md"

  if review_receipt_ok "$sha" "$base"; then
    info "distinct-vendor review already recorded for $branch @ $sha against $base — reusing it"
    return 0
  fi

  if [[ -z "$REVIEWERS" ]]; then
    info "--reviewers is empty — no distinct-vendor reviewer to run (Law 5)"
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
    info "--reviewers '$REVIEWERS' contains no vendor other than the runner ($RUNNER) — nobody may review this (Law 5)"
    return 1
  fi

  # Remove first: a review that fails halfway must never leave a passing receipt.
  rm -f "$REVIEW_RECEIPT"
  info "running the mandatory distinct-vendor review of $branch @ $sha against $base before handoff (Law 5)"
  if "$SCRIPT_DIR/second-opinion.sh" \
      --repo "$REPO" --reviewers "$REVIEWERS" --author "$RUNNER" \
      --base "$base" --branch "$sha" \
      --gate-status "pre-handoff mandatory review of $branch @ $sha against $base" \
      --out "$out" >/dev/null; then
    printf 'sha: %s\nbranch: %s\nbase: %s\nauthor: %s\nreviewers: %s\nreviewed: %s\nstatus: ok\n' \
      "$sha" "$branch" "$base" "$RUNNER" "$REVIEWERS" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      > "$REVIEW_RECEIPT"
    info "distinct-vendor review of $sha against $base completed — receipt at $REVIEW_RECEIPT"
    return 0
  fi
  rm -f "$REVIEW_RECEIPT"
  info "distinct-vendor review of $branch @ $sha against $base FAILED — handoff blocked, branch stays queued (Law 5)"
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · pre-handoff review failed · reviewers=$REVIEWERS"
    echo "Cross-vendor review of $branch @ $sha against $base did not complete. Handoff BLOCKED;"
    echo "handoff/handoff_sha remain queued in loop-state (Law 5, Law 8)."
  } >> "$JOURNAL"
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

  # Resolved before anything is spent: a review against a guessed base is a
  # review of the wrong diff, so an unresolvable base blocks the handoff instead
  # of quietly falling back to `main`.
  local base base_ref
  if ! base=$(resolve_base_branch); then
    info "handoff of $branch blocked: the target repo's base branch could not be resolved — branch stays queued in loop-state"
    return 0
  fi
  if ! base_ref=$(review_base_ref "$base"); then
    info "handoff of $branch blocked: base branch '$base' cannot be diffed in this checkout — branch stays queued in loop-state"
    return 0
  fi

  local sha
  if ! sha=$(resolve_handoff_sha "$branch"); then
    info "handoff of $branch blocked: no reviewable SHA — branch stays queued in loop-state"
    return 0
  fi
  info "pinning handoff to $branch @ $sha (base $base, diffed as $base_ref)"

  if ! ensure_cross_vendor_review "$branch" "$sha" "$base_ref"; then
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
  local review="$STATE_DIR/second-opinion.md"
  info "handing $branch @$sha to the Devin supervisor (base $base)"
  if "$SCRIPT_DIR/devin-supervisor.sh" handoff --repo "$REPO" --branch "$branch" \
      --base "$base" --sha "$sha" --task "$task" --gate-status "green locally" \
      --review-file "$review"; then
    node -e '
      const fs = require("fs");
      const file = process.argv[1];
      let text = fs.readFileSync(file, "utf8");
      text = text.replace(/^handoff:.*$/m, "handoff:");
      text = text.replace(/^handoff_sha:.*$/m, "handoff_sha:");
      fs.writeFileSync(file, text);
    ' "$STATE_FILE"
  else
    info "supervisor handoff failed (non-fatal) — branch stays queued in loop-state"
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

failures=0
iter=0

if [[ "$SUPERVISOR" == "devin" && "$DRY" -eq 0 && "$PRINT" -eq 0 ]]; then
  "$SCRIPT_DIR/devin-supervisor.sh" ensure --repo "$REPO" || \
    info "supervisor unavailable at startup (non-fatal) — handoffs will retry"
fi

while true; do
  if halted; then
    info "kill switch set — stopping cleanly"
    exit 0
  fi

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
