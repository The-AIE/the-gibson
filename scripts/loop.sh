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
  - Stop with gibson/HALT or the gibson-halt label.
  - Error budget (default 5 consecutive failures) stops the loop to avoid burn.

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

EXAMPLES
  ./scripts/loop.sh --runner grok --repo ~/Code/acme-app
  ./scripts/loop.sh --runner grok --repo ~/Code/acme-app --once --print-prompt
  ./scripts/loop.sh --runner claude --repo ~/Code/acme-app --hat reviewer --once
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
next_action: triage highest-priority unblocked unclaimed issue
notes: initialized by loop.sh
EOF
fi
[[ -f "$JOURNAL" ]] || echo "# Gibson loop journal" > "$JOURNAL"

halted() {
  if [[ -f "$HALT_FILE" ]]; then return 0; fi
  if command -v gh >/dev/null 2>&1; then
    # label on default repo if any issue carries gibson-halt is heavy; check file + env
    if [[ "${GIBSON_HALT:-}" == "1" ]]; then return 0; fi
  fi
  return 1
}

read_field() {
  local key="$1"
  awk -F': ' -v k="$key" '$1==k {sub(/^[^:]+: /,""); print; exit}' "$STATE_FILE"
}

render_prompt() {
  local hat="$1"
  local state
  state=$(cat "$STATE_FILE")
  # portable-ish substitution without perl
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
      # passed as a positional/value string instead of a file path.
      # --permission-mode bypassPermissions: without it, grok has no TTY to
      # request tool-call approval in headless mode, so it silently narrates
      # instead of acting — every iteration exits in seconds with no real work.
      grok --prompt-file "$prompt_file" --permission-mode bypassPermissions
      ;;
    claude)
      command -v claude >/dev/null || die "claude CLI not found"
      claude -p --output-format text --permission-mode acceptEdits "$(cat "$prompt_file")"
      ;;
    codex)
      command -v codex >/dev/null || die "codex CLI not found"
      codex exec --full-auto "$(cat "$prompt_file")"
      ;;
    hermes)
      # Hermes may be messaging-first; if CLI exists use it, else require HERMES_CMD
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

while true; do
  if halted; then
    info "kill switch set — stopping cleanly"
    exit 0
  fi

  hat="${FORCE_HAT:-$(read_field next_hat)}"
  [[ -n "$hat" ]] || hat="builder"
  FORCE_HAT="" # only first iteration

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
      if [[ $failures -ge $BUDGET ]]; then
        die "error budget exhausted — likely harness bug, not retry fodder (docs/11)"
      fi
    else
      failures=0
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
