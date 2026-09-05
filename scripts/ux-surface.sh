#!/usr/bin/env bash
# ux-surface.sh — does this change touch a user-visible surface? (docs/07)
set -uo pipefail

usage() {
  cat <<'EOF'
ux-surface.sh — classify a diff as UI-affecting or not

WHAT IT DOES
  Reads a list of changed paths and prints one of:

    surface=ui    something a user can see changed → the UX gate must RUN
    surface=none  pure library / config / docs      → the UX gate may SKIP

  Also prints `reason=` (the path that decided it) and, on stderr, the full
  matched list. Patterns come from `.gibson/ux-surface.conf` when the target
  repo has one, so a repo can teach the harness its own layout.

WHY
  There are two different reasons a UX job produces no result, and treating
  them the same is what makes the gate meaningless:

    - Nothing user-visible changed. Skipping is correct and should be instant
      (L-034: a pure-MCP-library PR sat for six minutes waiting on a preview
      it would never use, then skipped, and blocked the release checklist).
    - Something user-visible changed but the preview never resolved. That is a
      MISSING RESULT, not a pass (L-012: ux-eval, posture, and ZAP silently
      skip=1'd on two Tier-B PRs, so a hard-fail promotion shipped without the
      hard-fail path ever executing — L-011).

  This script only answers the first question, so CI can stop conflating them.

USAGE
  ux-surface.sh --pr <n> [--repo owner/name]   # ask GitHub for the file list
  ux-surface.sh --diff <base>                  # git diff --name-only <base>...HEAD
  ux-surface.sh --files <path> [<path>…]       # explicit list (or - for stdin)
  ux-surface.sh --help

CONFIG (optional, in the target repo)
  .gibson/ux-surface.conf — one extended-regex per line, `#` comments ignored.
  A line starting with `!` marks a NON-surface exception checked first:

    ^apps/web/                 # everything in the web app is user-visible
    !^apps/web/lib/telemetry/  # …except this, which renders nothing

EXIT
  0  surface=none  (safe to skip the UX gate)
  1  surface=ui    (the UX gate must run and must produce a result)
  2  usage error

  The exit code is inverted from the usual "0 = the interesting case" because
  CI reads it as "may I skip?".
EOF
}

[[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; [[ "${1:-}" == -h || "${1:-}" == --help ]] && exit 0; exit 2; }

MODE=""
PR=""
REPO=""
BASE=""
FILES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) MODE="pr"; PR="${2:-}"; shift ;;
    --repo) REPO="${2:-}"; shift ;;
    --diff) MODE="diff"; BASE="${2:-}"; shift ;;
    --files) MODE="files"; shift; while [[ $# -gt 0 && "$1" != --* ]]; do FILES+=("$1"); shift; done; continue ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

die() { echo "ux-surface.sh: ERROR: $*" >&2; exit 2; }

case "$MODE" in
  pr)
    [[ "$PR" =~ ^[0-9]+$ ]] || die "--pr needs a number"
    command -v gh >/dev/null || die "gh required for --pr"
    if [[ -n "$REPO" ]]; then
      CHANGED=$(gh pr diff "$PR" --repo "$REPO" --name-only 2>/dev/null) || die "could not read PR $PR"
    else
      CHANGED=$(gh pr diff "$PR" --name-only 2>/dev/null) || die "could not read PR $PR"
    fi
    ;;
  diff)
    [[ -n "$BASE" ]] || die "--diff needs a base ref"
    CHANGED=$(git diff --name-only "$BASE"...HEAD 2>/dev/null) || die "could not diff against $BASE"
    ;;
  files)
    if [[ "${FILES[0]:-}" == "-" ]]; then
      CHANGED=$(cat)
    else
      CHANGED=$(printf '%s\n' ${FILES[@]+"${FILES[@]}"})
    fi
    ;;
  *) die "pick one of --pr / --diff / --files" ;;
esac

CHANGED=$(echo "$CHANGED" | sed '/^[[:space:]]*$/d')
if [[ -z "$CHANGED" ]]; then
  echo "surface=none"
  echo "reason=no files changed"
  exit 0
fi

# Defaults describe a conventional Next.js/Vite repo. A target repo with a
# different layout adds .gibson/ux-surface.conf rather than patching this.
SURFACE_PATTERNS=(
  '(^|/)(app|pages|src/app|src/pages)/'
  '(^|/)(components|ui|widgets|layouts|views)/'
  '(^|/)(marketing|www|web|site|storefront)/'
  '(^|/)(public|static|assets)/'
  '\.(css|scss|sass|less|svelte|vue|astro|mdx)$'
  '(^|/)tests/e2e/'
  '(^|/)(tailwind|postcss|next|vite|astro)\.config\.[jtm]s$'
  '(^|/)(theme|tokens|design-system)/'
)
NON_SURFACE_PATTERNS=()

CONF=".gibson/ux-surface.conf"
if [[ -f "$CONF" ]]; then
  # A config replaces the defaults: a repo that bothers to write one knows its
  # own layout better than the guesses above do.
  SURFACE_PATTERNS=()
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    if [[ "${line:0:1}" == "!" ]]; then
      NON_SURFACE_PATTERNS+=("${line:1}")
    else
      SURFACE_PATTERNS+=("$line")
    fi
  done < "$CONF"
  [[ ${#SURFACE_PATTERNS[@]} -gt 0 ]] || die "$CONF has no surface patterns (only exceptions)"
fi

MATCHED=""
FIRST=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  skip=0
  for np in ${NON_SURFACE_PATTERNS[@]+"${NON_SURFACE_PATTERNS[@]}"}; do
    if echo "$f" | grep -E "$np" >/dev/null; then skip=1; break; fi
  done
  [[ "$skip" -eq 1 ]] && continue
  for sp in "${SURFACE_PATTERNS[@]}"; do
    if echo "$f" | grep -E "$sp" >/dev/null; then
      MATCHED="$MATCHED$f"$'\n'
      [[ -z "$FIRST" ]] && FIRST="$f"
      break
    fi
  done
done <<< "$CHANGED"

if [[ -n "$FIRST" ]]; then
  echo "surface=ui"
  echo "reason=$FIRST"
  echo "user-visible paths in this change:" >&2
  echo "$MATCHED" | sed '/^$/d;s/^/  /' >&2
  exit 1
fi

echo "surface=none"
echo "reason=no user-visible paths in $(echo "$CHANGED" | wc -l | tr -d ' ') changed file(s)"
exit 0
