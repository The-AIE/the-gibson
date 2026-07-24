#!/usr/bin/env bash
# upstream-sync.sh — fork sync loop (docs/18)
set -euo pipefail

usage() {
  cat <<'EOF'
upstream-sync.sh — fetch upstream, branch, merge, report, open sync PR

WHAT IT DOES
  In a fork of The Gibson: fetches the upstream remote, creates
  chore/upstream-sync-<date>, merges upstream/main, prints an override-shadow
  report (local/ files whose core counterparts changed), and opens a PR with a
  plain-language summary from CHANGELOG.md. Flags Tier C if doc 14 / tiers /
  hard-fail thresholds changed.

WHY
  Forks stay current without hand-merging pain (docs/18). The fleet can run this
  weekly.

RISKS
  - Creates a branch and may open a GitHub PR (visible).
  - Merge can conflict if core was edited in-fork (discouraged).
  - Does not auto-merge the PR.

USAGE
  upstream-sync.sh [--upstream URL] [--remote NAME] [--no-pr] [--dry-run]
  upstream-sync.sh --help

EXAMPLES
  cd ~/Code/my-gibson-fork
  git remote add upstream https://github.com/mrhinkle/the-gibson.git  # once
  /path/to/scripts/upstream-sync.sh
  /path/to/scripts/upstream-sync.sh --no-pr --dry-run
EOF
}

UPSTREAM_URL="https://github.com/mrhinkle/the-gibson.git"
REMOTE="upstream"
NO_PR=0
DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --upstream) UPSTREAM_URL="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --no-pr) NO_PR=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "upstream-sync: ERROR: $*" >&2; exit 1; }
info() { echo "upstream-sync: $*" >&2; }

git rev-parse --is-inside-work-tree >/dev/null || die "run inside a git repo"

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  info "adding remote $REMOTE -> $UPSTREAM_URL"
  [[ "$DRY" -eq 1 ]] || git remote add "$REMOTE" "$UPSTREAM_URL"
fi

info "fetch $REMOTE"
[[ "$DRY" -eq 1 ]] || git fetch "$REMOTE" --tags

DATE=$(date -u +"%Y-%m-%d")
BRANCH="chore/upstream-sync-${DATE}"
BASE=$(git rev-parse --abbrev-ref HEAD)

# Commits to merge?
AHEAD=$(git rev-list --count HEAD.."${REMOTE}/main" 2>/dev/null || echo 0)
if [[ "$AHEAD" == "0" ]]; then
  info "already up to date with ${REMOTE}/main"
  exit 0
fi
info "$AHEAD commit(s) available from ${REMOTE}/main"

if [[ "$DRY" -eq 1 ]]; then
  info "dry-run: would branch $BRANCH, merge ${REMOTE}/main, open PR"
  git log --oneline HEAD.."${REMOTE}/main" | head -n 20
  exit 0
fi

git checkout -b "$BRANCH"
if ! git merge --no-ff "${REMOTE}/main" -m "chore: merge upstream/main ${DATE}

Sync per docs/18. Override-shadow report follows in PR body."; then
  die "merge conflict — resolve in this branch, then re-run PR creation manually"
fi

# Override-shadow report: local/ files that shadow core paths changed upstream
SHADOW_REPORT=$(mktemp)
echo "### Override-shadow report" > "$SHADOW_REPORT"
echo "" >> "$SHADOW_REPORT"
echo "Core files changed upstream that you may override via local/:" >> "$SHADOW_REPORT"
echo "" >> "$SHADOW_REPORT"
CHANGED=$(git log --name-only --pretty=format: HEAD~${AHEAD}..HEAD 2>/dev/null | sort -u || git diff --name-only "${BASE}"..HEAD)
TIER_C=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    docs/14-human-gates.md|docs/06-quality-gates.md|docs/08-security.md)
      TIER_C=1
      echo "- **$f** (Tier C — human gates / tiers / security thresholds may have changed)" >> "$SHADOW_REPORT"
      ;;
    AGENTS.md|docs/*|playbooks/*|scripts/*|ci/*)
      base=$(basename "$f")
      if [[ -e "local/$f" || -e "local/playbooks/$base" || -e "local/docs/$base" ]]; then
        echo "- \`$f\` — local override exists; **re-read** upstream changes" >> "$SHADOW_REPORT"
      else
        echo "- \`$f\` (no local override)" >> "$SHADOW_REPORT"
      fi
      ;;
  esac
done <<< "$CHANGED"

# CHANGELOG excerpt
CL_EXCERPT=""
if [[ -f CHANGELOG.md ]]; then
  CL_EXCERPT=$(awk 'BEGIN{p=0} /^## /{if(p){exit} p=1} p{print}' CHANGELOG.md | head -n 40)
fi

# Contribute-back preflight: grep for common private markers (fork identifiers)
info "pre-push privacy grep (fork identifiers)"
# Only warn; forks may legitimately contain local/ secrets paths ignored
if git grep -nE 'sk-[a-zA-Z0-9]{10,}|API_KEY=|BEGIN RSA PRIVATE' -- ':!memory/' ':!local/' 2>/dev/null | head -n 5; then
  info "WARNING: possible secrets in non-local paths — review before any contribute-back PR"
fi

BODY=$(mktemp)
cat > "$BODY" <<EOF
## Upstream sync — $DATE

**What I'm asking:** Merge this PR to update your fork with upstream The Gibson improvements.

**What it does:** Brings in new playbooks, scripts, docs, and lessons from upstream without touching your \`local/\` overlay.

**Why:** You get harness fixes and new gates without re-forking (docs/18).

**Risks:** Medium if you customized core files (discouraged). \`local/\` is untouched. Review the override-shadow report. If Tier C flagged, **owner approval required** before merge — your stopping rules may have changed.

### Upstream commits
\`\`\`
$(git log --oneline HEAD~${AHEAD}..HEAD | head -n 30)
\`\`\`

### CHANGELOG (latest)
\`\`\`
$CL_EXCERPT
\`\`\`

$(cat "$SHADOW_REPORT")

### Tier
$( if [[ "$TIER_C" -eq 1 ]]; then echo "**C** — human gate list / tiers / hard-fail thresholds may have changed (docs/18)."; else echo "A/B — routine harness update."; fi )
EOF

git push -u origin "$BRANCH"

if [[ "$NO_PR" -eq 0 ]] && command -v gh >/dev/null; then
  LABEL_ARGS=()
  if [[ "$TIER_C" -eq 1 ]]; then
    LABEL_ARGS+=(--label tier-c)
  fi
  gh pr create --title "chore: upstream sync $DATE" --body-file "$BODY" "${LABEL_ARGS[@]}" || info "PR create failed — body at $BODY"
else
  info "PR body written to $BODY (--no-pr or no gh)"
fi

info "OK — branch $BRANCH"
rm -f "$SHADOW_REPORT"
