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
  --reviewers LIST  comma-separated vendors, optional :model suffix
                    (e.g. claude:opus, grok, codex). Default: codex,claude
  --author NAME     runner that wrote the diff; excluded unless --solo-platform
  --solo-platform   single-vendor mode (#69): same platform may review when a
                    different model is requested (vendor:model) or when the only
                    available CLI is the author — fresh-context plan mode still
                    applies. Compensating control for Tier B: two independent
                    passes (caller enforces).
  --base REF        diff base (default: main; loop.sh passes the target repo's
                    resolved default branch). Must resolve to a commit — an
                    unresolvable base is an error, not a working-tree diff.
  --branch REF      diff head (default: HEAD); same rule
  --gate-status S   what the local gate said, passed through to the reviewer
  --out PATH        write the combined report here (default: gibson/second-opinion.md)

EXAMPLES
  ./scripts/second-opinion.sh --repo ../wt-42-password-reset --author grok
  ./scripts/second-opinion.sh --repo . --reviewers claude --base main --branch HEAD
EOF
}

REPO=""
REVIEWERS="codex,claude"
PR_NUMBER=""
REPO_SLUG=""
AUTHOR=""
BASE="main"
BRANCH="HEAD"
GATE_STATUS=""
OUT=""
TASK=""
TASK_FILE=""
SOLO_PLATFORM=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) REPO="$2"; shift 2 ;;
    --reviewers) REVIEWERS="$2"; shift 2 ;;
    --pr) PR_NUMBER="$2"; shift 2 ;;
    --github-repo) REPO_SLUG="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --gate-status) GATE_STATUS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;;
    --task-file) TASK_FILE="$2"; shift 2 ;;
    --solo-platform) SOLO_PLATFORM=1; shift ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "second-opinion.sh: ERROR: $*" >&2; exit 1; }
info() { echo "second-opinion.sh: $*" >&2; }

[[ -n "$REPO" ]] || { usage; exit 2; }
[[ -d "$REPO" ]] || die "repo not a directory: $REPO"
[[ -n "$TASK_FILE" ]] && TASK=$(cat "$TASK_FILE")

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GIBSON="${GIBSON:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLAYBOOK="$GIBSON/playbooks/reviewer.md"
[[ -f "$PLAYBOOK" ]] || die "missing $PLAYBOOK"

OUT="${OUT:-$REPO/gibson/second-opinion.md}"
mkdir -p "$(dirname "$OUT")"

# Both endpoints must resolve to real commits in THIS repo. The old fallback
# (`git diff BASE` when `BASE...BRANCH` failed) silently swapped the requested
# review for a diff of the working tree against BASE — a different diff, usually
# a much smaller one, reported as though the branch had been reviewed. A caller
# that names refs which do not resolve gets an error, never a substitute.
for ref in "$BASE" "$BRANCH"; do
  git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || \
    die "ref '$ref' does not resolve to a commit in $REPO — refusing to review a different diff (no working-tree fallback)"
done

# stderr kept out of $DIFF: a warning must never end up inside the diff the
# reviewer is shown. `A...B` can still fail after both refs resolve — unrelated
# histories have no merge base — and that is a hard error too.
DIFF_ERR=$(mktemp)
if ! DIFF=$(git -C "$REPO" diff "$BASE...$BRANCH" 2>"$DIFF_ERR"); then
  reason=$(tail -n 3 "$DIFF_ERR")
  rm -f "$DIFF_ERR"
  die "git diff $BASE...$BRANCH failed in $REPO: ${reason:-no detail}"
fi
rm -f "$DIFF_ERR"
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

1. VERDICT: APPROVE | REQUEST_CHANGES
   (canonical tokens from AGENTS.md; aliases approve / changes-requested are
   accepted at this adapter boundary and mapped to the same GitHub events)
2. Defects, most important first, each with file:line and the failure it causes.
   Cover the three lenses (docs/06): security, correctness, ops.
3. Minimal, concrete instructions the implementer should follow.

Say "checked, absent" for defect classes you hunted and did not find — silence is
not safety (docs/20 rule 3). Do not invent nits; if the diff is sound, say so.
EOF
} > "$PROMPT_FILE"

# Split "vendor:model" → vendor + optional model. vendor alone keeps model empty.
split_reviewer() { # sets _rv_vendor _rv_model from $1
  local spec="$1"
  if [[ "$spec" == *:* ]]; then
    _rv_vendor="${spec%%:*}"
    _rv_model="${spec#*:}"
  else
    _rv_vendor="$spec"
    _rv_model=""
  fi
}

run_reviewer() { # run_reviewer <vendor:model|vendor> <prompt-file>
  split_reviewer "$1"
  local vendor="$_rv_vendor" model="$_rv_model"
  case "$vendor" in
    codex)
      command -v codex >/dev/null || { info "codex CLI not found — skipping"; return 1; }
      if [[ -n "$model" ]]; then
        codex exec --sandbox read-only --cd "$REPO" -m "$model" - < "$2"
      else
        codex exec --sandbox read-only --cd "$REPO" - < "$2"
      fi
      ;;
    claude)
      command -v claude >/dev/null || { info "claude CLI not found — skipping"; return 1; }
      # stdin, not a positional arg: the rendered playbook starts with YAML
      # frontmatter ("---"), which claude's parser reads as an unknown option
      if [[ -n "$model" ]]; then
        (cd "$REPO" && claude -p --model "$model" --output-format text --permission-mode plan < "$2")
      else
        (cd "$REPO" && claude -p --output-format text --permission-mode plan < "$2")
      fi
      ;;
    grok)
      command -v grok >/dev/null || { info "grok CLI not found — skipping"; return 1; }
      if [[ -n "$model" ]]; then
        grok --prompt-file "$2" --cwd "$REPO" --permission-mode plan --model "$model"
      else
        grok --prompt-file "$2" --cwd "$REPO" --permission-mode plan
      fi
      ;;
    *) info "unknown reviewer: $vendor — skipping"; return 1 ;;
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
  split_reviewer "$name"
  vendor="$_rv_vendor"
  model="$_rv_model"
  # Law 5: never same vendor unless solo-platform with an explicit different model
  # (fresh-context plan mode) — issue #69 degraded mode.
  if [[ -n "$AUTHOR" && "$vendor" == "$AUTHOR" ]]; then
    if [[ "$SOLO_PLATFORM" -eq 1 && -n "$model" ]]; then
      info "solo-platform: allowing same-vendor review $name (different model, fresh context)"
    elif [[ "$SOLO_PLATFORM" -eq 1 && -z "$model" ]]; then
      # Auto-pick a review model tag so the receipt shows a distinct model lane.
      case "$vendor" in
        claude) name="claude:sonnet"; info "solo-platform: rewriting reviewer to $name (fresh-context alt model)" ;;
        grok)   name="grok:review";  info "solo-platform: rewriting reviewer to $name (fresh-context alt model)" ;;
        codex)  name="codex:review"; info "solo-platform: rewriting reviewer to $name (fresh-context alt model)" ;;
        *) info "solo-platform: same-vendor $vendor with no model suffix — still dispatching plan-mode fresh context"; ;;
      esac
    else
      info "skipping $name — it wrote this diff (AGENTS.md Law 5)"
      continue
    fi
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
[[ "$reviewed" -gt 0 ]] || die "no reviewer ran — install a second vendor's CLI, pass --reviewers, or use --solo-platform with a vendor:model reviewer (#69)"
info "wrote $OUT"

# Optional formal GitHub review (#67). When GIBSON_FORMAL_REVIEW=1 and a
# reviewer token is configured, map the first VERDICT line to a formal review
# under the dedicated identity. Builder GH_TOKEN is never used.
if [[ "${GIBSON_FORMAL_REVIEW:-0}" == "1" && -n "${PR_NUMBER:-}" && -n "${REPO_SLUG:-${GITHUB_REPOSITORY:-}}" ]]; then
  _fr_event=""
  # Canonical AGENTS.md tokens are APPROVE / REQUEST_CHANGES. approve and
  # changes-requested are explicit aliases at this adapter boundary. PASS is
  # not a PR-review approval synonym.
  if grep -qiE 'VERDICT:[[:space:]]*approve([^A-Za-z]|$)' "$OUT" 2>/dev/null; then
    _fr_event=approve
  elif grep -qiE 'VERDICT:[[:space:]]*(REQUEST_CHANGES|changes-requested|request.changes)' "$OUT" 2>/dev/null; then
    _fr_event=request-changes
  fi
  if [[ -n "$_fr_event" && -f "$SCRIPT_DIR/formal-review.sh" ]]; then
    _fr_repo="${REPO_SLUG:-$GITHUB_REPOSITORY}"
    "$SCRIPT_DIR/formal-review.sh" --pr "$PR_NUMBER" --repo "$_fr_repo"       --event "$_fr_event" --body-file "$OUT" ||       info "formal-review.sh failed — second-opinion.md still written (Law 8)"
  fi
fi

