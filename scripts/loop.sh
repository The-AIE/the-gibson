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
    configured, a distinct-vendor second opinion is required before handoff
    (Law 5 gate).

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
                      whenever loop-state carries a `handoff:` field (docs/22)

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

escalate() {
  local out="$STATE_DIR/second-opinion.md"
  info "escalating after $failures consecutive failures — reviewers: $REVIEWERS"
  local note
  if "$SCRIPT_DIR/second-opinion.sh" \
      --repo "$REPO" --reviewers "$REVIEWERS" --author "$RUNNER" \
      --gate-status "red: $failures consecutive runner failures" --out "$out" >/dev/null 2>&1; then
    info "second opinion written to $out"
    note="Second opinion written to gibson/second-opinion.md — next hat must read it."
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

# Ensure a distinct-vendor second opinion exists before any supervisor handoff.
# Law 5: never grade your own homework. When --supervisor is set we gate the
# handoff on a prior cross-vendor review (issue #55).
ensure_cross_vendor_review() {
  local review="$STATE_DIR/second-opinion.md"
  if [[ -f "$review" ]] && grep -q . "$review" 2>/dev/null; then
    if grep -qi "author: *$RUNNER\|runner: *$RUNNER\|from: *$RUNNER" "$review" 2>/dev/null; then
      info "second-opinion.md appears to be from the same vendor ($RUNNER) — forcing fresh cross-vendor pass"
    else
      return 0
    fi
  fi
  info "no usable cross-vendor second opinion yet — running one before handoff (Law 5)"
  local out="$STATE_DIR/second-opinion.md"
  if "$SCRIPT_DIR/second-opinion.sh" \
      --repo "$REPO" --reviewers "$REVIEWERS" --author "$RUNNER" \
      --gate-status "pre-handoff mandatory review" --out "$out" >/dev/null 2>&1; then
    info "mandatory pre-handoff second opinion written to $out"
  else
    info "mandatory second opinion failed — handoff will still proceed but supervisor is warned"
    {
      echo ""
      echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · pre-handoff review failed · reviewers=$REVIEWERS"
      echo "Cross-vendor review did not complete; supervisor must treat this as unreviewed."
    } >> "$JOURNAL"
  fi
}

# File-handoff protocol: pin and pass the head SHA so a later push cannot
# invalidate the review without the supervisor noticing (issue #55).
supervisor_handoff() {
  [[ "$SUPERVISOR" == "devin" ]] || return 0
  local branch
  branch=$(read_field handoff)
  [[ -n "$branch" ]] || return 0

  ensure_cross_vendor_review

  local sha
  sha=$(read_field handoff_sha)
  if [[ -z "$sha" ]]; then
    sha=$(git -C "$REPO" rev-parse --verify "refs/heads/$branch" 2>/dev/null \
       || git -C "$REPO" rev-parse --verify "origin/$branch" 2>/dev/null \
       || true)
  fi
  if [[ -z "$sha" ]]; then
    info "could not resolve SHA for handoff branch $branch — supervisor will still receive branch name"
  else
    info "pinning handoff to $branch @ $sha"
  fi

  local task issue next
  issue=$(read_field issue)
  next=$(read_field next_action)
  task=""
  [[ -z "$issue" ]] || task="Issue: $issue."
  [[ -z "$next" ]] || task="${task:+$task }Next action: $next"
  [[ -n "$task" ]] || task="See the branch diff; loop-state carried no task description."
  # bash 3.2 (stock macOS) errors on an empty array under set -u, so branch instead
  local review="$STATE_DIR/second-opinion.md"
  [[ -f "$review" ]] || review="/dev/null"
  info "handing $branch${sha:+ @$sha} to the Devin supervisor"
  local handoff_args=(handoff --repo "$REPO" --branch "$branch" \
      --task "$task" --gate-status "green locally" --review-file "$review")
  [[ -n "$sha" ]] && handoff_args+=(--sha "$sha")
  if "$SCRIPT_DIR/devin-supervisor.sh" "${handoff_args[@]}"; then
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
