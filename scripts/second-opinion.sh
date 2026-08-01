#!/usr/bin/env bash
# second-opinion.sh — cross-vendor read-only review of a diff (docs/20 rule 1)
set -euo pipefail

usage() {
  cat <<'EOF'
second-opinion.sh — dispatch a different vendor to review a diff, read-only

WHAT IT DOES
  Renders playbooks/reviewer.md plus the branch diff and the local gate status,
  then runs one or more reviewer CLIs in their read-only / plan mode. Refuses to
  let a runner review its own work. Writes each verdict to a file and prints the
  combined report.

WHY
  AGENTS.md Law 5: never grade your own homework. docs/20 rule 1: the model that
  wrote a change never reviews it — Grok implements, Codex or Claude reviews.
  Escalation is cheap here because reviewers only read; the expensive iteration
  stays on the flat-rate implementer (docs/15).

RISKS
  - The diff is sent to each reviewer's vendor backend. Never review a diff that
    contains secrets (docs/20 rule 6).
  - Read-only mode is enforced by CLI flags, not by the filesystem; run it from a
    worktree, not the canonical checkout (AGENTS.md Law 3).
  - A reviewer's approval is an opinion, not a gate. The green gate and the
    supervisor's review still apply.

USAGE
  second-opinion.sh --repo <path> [--reviewers codex,claude] [--author grok]
                    [--base main] [--branch HEAD] [--gate-status TEXT]
                    [--out PATH] [--task TEXT | --task-file PATH]

OPTIONS
  --reviewers LIST  comma-separated: codex, claude, grok (default: codex,claude)
  --author NAME     runner that wrote the diff; excluded from the reviewer list
  --base REF        diff base (default: main)
  --branch REF      diff head (default: HEAD)
  --gate-status S   what the local gate said, passed through to the reviewer
  --out PATH        write the combined report here (default: gibson/second-opinion.md)

EXAMPLES
  ./scripts/second-opinion.sh --repo ../wt-42-password-reset --author grok
  ./scripts/second-opinion.sh --repo . --reviewers claude --base main --branch HEAD
EOF
}

REPO=""
REVIEWERS="codex,claude"
AUTHOR=""
BASE="main"
BRANCH="HEAD"
GATE_STATUS=""
OUT=""
TASK=""
TASK_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) REPO="$2"; shift 2 ;;
    --reviewers) REVIEWERS="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --gate-status) GATE_STATUS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;;
    --task-file) TASK_FILE="$2"; shift 2 ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "second-opinion.sh: ERROR: $*" >&2; exit 1; }
info() { echo "second-opinion.sh: $*" >&2; }

[[ -n "$REPO" ]] || { usage; exit 2; }
[[ -d "$REPO" ]] || die "repo not a directory: $REPO"
[[ -n "$TASK_FILE" ]] && TASK=$(cat "$TASK_FILE")

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
GIBSON="${GIBSON:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLAYBOOK="$GIBSON/playbooks/reviewer.md"
[[ -f "$PLAYBOOK" ]] || die "missing $PLAYBOOK"

OUT="${OUT:-$REPO/gibson/second-opinion.md}"
mkdir -p "$(dirname "$OUT")"

DIFF=$(git -C "$REPO" diff "$BASE...$BRANCH" 2>/dev/null || git -C "$REPO" diff "$BASE" || true)
[[ -n "$DIFF" ]] || die "empty diff for $BASE...$BRANCH — nothing to review"

# 60k chars keeps the prompt inside every vendor's comfortable context window.
MAX_DIFF=60000
if [[ ${#DIFF} -gt $MAX_DIFF ]]; then
  info "diff is ${#DIFF} chars — truncating to $MAX_DIFF for review"
  DIFF="${DIFF:0:$MAX_DIFF}
...[diff truncated — review the branch directly for the remainder]..."
fi

PROMPT_FILE=$(mktemp)
{
  cat "$PLAYBOOK"
  cat <<EOF

---

# This review

You are reviewing someone else's work, read-only. Do not edit files, do not run
destructive commands, do not touch git or GitHub.

- Repository path: $REPO
- Diff: \`$BASE...$BRANCH\`
- Author runtime: ${AUTHOR:-unknown}
- Local green gate: ${GATE_STATUS:-unknown}
$([[ -n "$TASK" ]] && printf '\n## Task the diff is meant to solve\n%s\n' "$TASK")

## Diff

\`\`\`diff
$DIFF
\`\`\`

Answer in this shape:

1. VERDICT: approve | changes-requested
2. Defects, most important first, each with file:line and the failure it causes.
   Cover the three lenses (docs/06): security, correctness, ops.
3. Minimal, concrete instructions the implementer should follow.

Say "checked, absent" for defect classes you hunted and did not find — silence is
not safety (docs/20 rule 3). Do not invent nits; if the diff is sound, say so.
EOF
} > "$PROMPT_FILE"

run_reviewer() { # run_reviewer <name> <prompt-file>
  case "$1" in
    codex)
      command -v codex >/dev/null || { info "codex CLI not found — skipping"; return 1; }
      codex exec --sandbox read-only --cd "$REPO" - < "$2"
      ;;
    claude)
      command -v claude >/dev/null || { info "claude CLI not found — skipping"; return 1; }
      # stdin, not a positional arg: the rendered playbook starts with YAML
      # frontmatter ("---"), which claude's parser reads as an unknown option
      (cd "$REPO" && claude -p --output-format text --permission-mode plan < "$2")
      ;;
    grok)
      command -v grok >/dev/null || { info "grok CLI not found — skipping"; return 1; }
      grok --prompt-file "$2" --cwd "$REPO" --permission-mode plan
      ;;
    *) info "unknown reviewer: $1 — skipping"; return 1 ;;
  esac
}

# The CLIs stream the review on stdout and their own tracing on stderr. Merging
# the two interleaves log lines mid-sentence and buries the verdict, so the noise
# goes to a sidecar log the next hat can ignore. RUST_LOG trims it at the source.
LOG="${OUT%.md}.log"
export RUST_LOG="${RUST_LOG:-error}"

: > "$OUT"
: > "$LOG"
reviewed=0
IFS=',' read -ra NAMES <<< "$REVIEWERS"
for name in "${NAMES[@]}"; do
  name=$(echo "$name" | tr -d '[:space:]')
  [[ -n "$name" ]] || continue
  if [[ -n "$AUTHOR" && "$name" == "$AUTHOR" ]]; then
    info "skipping $name — it wrote this diff (AGENTS.md Law 5)"
    continue
  fi
  info "dispatching $name (read-only)"
  verdict_file=$(mktemp)
  err_file=$(mktemp)
  if run_reviewer "$name" "$PROMPT_FILE" > "$verdict_file" 2>"$err_file"; then
    reviewed=$((reviewed + 1))
    failed=0
  else
    info "$name returned non-zero — recording whatever it produced"
    failed=1
  fi
  { echo "----- $name -----"; cat "$err_file"; } >> "$LOG"
  {
    echo "## Second opinion — $name"
    echo ""
    cat "$verdict_file"
    # A failed reviewer usually says why on stderr (auth, quota) and nothing on
    # stdout — surface that here rather than leaving a silent empty section.
    if [[ "$failed" -eq 1 ]]; then
      echo ""
      echo "> $name failed. Last lines of stderr (full log: $LOG):"
      echo '```'
      tail -n 20 "$err_file"
      echo '```'
    fi
    echo ""
  } >> "$OUT"
  rm -f "$verdict_file" "$err_file"
done
rm -f "$PROMPT_FILE"

cat "$OUT"
[[ ! -s "$LOG" ]] || info "reviewer stderr in $LOG"
[[ "$reviewed" -gt 0 ]] || die "no reviewer ran — install a second vendor's CLI or pass --reviewers"
info "wrote $OUT"
