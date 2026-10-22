#!/usr/bin/env bash
# gibson-ship preflight: what the target repo's gates read, checked locally before gh pr create / push.
# Usage: gibson-ship-preflight.sh <pr-body.md> [pr-number]    (run inside the PR's worktree)
# Reads the TARGET repo: .agents/gibson-delivery.json, scripts/check-active-work.mjs, branch protection via gh.
# Exit 0 = clean. Exit 1 = at least one "FAIL:". Exit 2 = usage.
set -uo pipefail
BODY="${1:-}"; PRNUM="${2:-${GIBSON_PR:-}}"
[ -f "$BODY" ] || { echo "usage: $0 <pr-body.md> [pr-number]"; exit 2; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "FAIL: not in a git worktree"; exit 1; }
cd "$ROOT"
fails=0; fail(){ echo "FAIL: $*"; fails=$((fails+1)); }; ok(){ echo "ok:   $*"; }; note(){ echo "note: $*"; }
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")
[ -n "$REPO" ] || fail "gh cannot resolve this checkout's repository"

# 0. Installed Gibson config → default branch and required contexts; fall back to branch protection.
CFG=".agents/gibson-delivery.json"; BASE=""; CTX=""; SRC=""
if [ -f "$CFG" ]; then
  BASE=$(jq -r '.defaultBranch // empty' "$CFG"); CTX=$(jq -r '(.requiredContexts // [])[]' "$CFG" | tr '\n' ' '); SRC="$CFG"
fi
[ -n "$BASE" ] || BASE=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)
if [ -z "$CTX" ] && [ -n "$REPO" ]; then
  CTX=$(gh api "repos/$REPO/branches/$BASE/protection" --jq '(.required_status_checks.contexts // [])[]' 2>/dev/null | tr '\n' ' '); [ -n "$CTX" ] && SRC="branch protection on $BASE"
fi
[ -n "$CTX" ] && ok "required contexts ($SRC): $CTX" || note "no required contexts found in $CFG or branch protection; review-evidence may still gate"
git fetch -q origin "$BASE" 2>/dev/null || fail "git fetch origin $BASE"

# 1. PR-body claim lines: the repo's own parser when it exports one, else the literal two lines claim.sh writes.
SLUG=""
if [ -f scripts/check-active-work.mjs ] && grep -q "export function parsePullRequestMetadata" scripts/check-active-work.mjs; then
  PARSE=$(node --input-type=module -e '
import { readFileSync } from "node:fs";
import { parsePullRequestMetadata } from "'"$ROOT"'/scripts/check-active-work.mjs";
const r = parsePullRequestMetadata(readFileSync(process.argv[1], "utf8"));
console.log(r.errors.length ? "ERR " + r.errors.join(" | ") : "OK " + r.claimSlug + " " + r.isolation);' "$BODY" 2>&1)
  case "$PARSE" in OK*) SLUG=$(echo "$PARSE" | awk '{print $2}'); ok "PR body (repo parser): claim=$SLUG isolation=$(echo "$PARSE" | cut -d" " -f3-)";; *) fail "PR body (repo parser): ${PARSE#ERR }";; esac
else
  C=$(grep -Ec '^\s*-\s+Active-work claim:\s*\S' "$BODY"); I=$(grep -Ec '^\s*-\s+Isolation:\s*(dedicated worktree|isolated hosted checkout)\s*$' "$BODY")
  SLUG=$(grep -E '^[[:space:]]*-[[:space:]]+Active-work claim:' "$BODY" | head -1 | sed -E 's/^[[:space:]]*-[[:space:]]+Active-work claim:[[:space:]]*//; s/[[:space:]]+$//')   # POSIX classes: BSD sed has no \s
  if [ "$C" -eq 1 ] && [ "$I" -eq 1 ] && echo "$SLUG" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then ok "PR body (literal lines): claim=$SLUG"; else fail "PR body needs exactly one '- Active-work claim: <kebab-slug>' and one '- Isolation: dedicated worktree|isolated hosted checkout' (found $C / $I, slug='$SLUG')"; SLUG=""; fi
fi
for ph in '<exact-claim-slug>' '<claim-slug>' 'Head SHA:\s*$'; do grep -Eq "$ph" "$BODY" && fail "PR body still has placeholder: $ph"; done

# 2. Claim slug unique across open PRs (excluding this PR).
if [ -n "$SLUG" ] && [ -n "$REPO" ]; then
  MINE="${PRNUM:-$(gh pr view --json number --jq .number 2>/dev/null || echo "")}"
  DUP=$(gh pr list -R "$REPO" --state open --limit 200 --json number,body --jq ".[] | select(.number != (${MINE:-0})) | select(.body | test(\"(?m)^\\\\s*-\\\\s+Active-work claim:\\\\s*${SLUG}\\\\s*$\")) | .number" 2>/dev/null)
  if [ -z "$DUP" ]; then ok "claim slug unique across open PRs in $REPO"
  elif [ -z "$MINE" ] && [ "$(echo "$DUP" | grep -c .)" -eq 1 ]; then note "claim slug '$SLUG' is on open PR #$(echo $DUP); fine if that is this PR (pass the PR number to confirm)"
  else fail "claim slug '$SLUG' also on open PR(s): $(echo $DUP)"; fi
fi

# 3. Commits in origin/<base>..HEAD: DCO + exactly one authoring vendor (trailer, or GitHub login when a PR number is known).
# Commit range = what the gates compare: the PR's recorded base sha when a PR number is known (so a merged or
# rewritten history still measures only the PR's own commits), else the merge-base with origin/<base>.
PRBASE=""; [ -n "$PRNUM" ] && [ -n "$REPO" ] && PRBASE=$(gh api "repos/$REPO/pulls/$PRNUM" --jq .base.sha 2>/dev/null)
if [ -n "$PRBASE" ] && git cat-file -e "$PRBASE^{commit}" 2>/dev/null; then MB=$(git merge-base "$PRBASE" HEAD 2>/dev/null || echo "$PRBASE"); else MB=$(git merge-base "origin/$BASE" HEAD 2>/dev/null || echo "origin/$BASE"); fi
RANGE="$MB..HEAD"
N=$(git rev-list --count "$RANGE" 2>/dev/null || echo 0); [ "$N" -gt 0 ] || fail "no commits in $RANGE"
LOGINS=""   # "sha author committer" per line, from GitHub when a PR number is known (macOS bash 3.2: no associative arrays)
if [ -n "$PRNUM" ] && [ -n "$REPO" ]; then
  LOGINS=$(gh api "repos/$REPO/pulls/$PRNUM/commits?per_page=250" --jq '.[] | "\(.sha) \(.author.login // "-") \(.committer.login // "-")"' 2>/dev/null)
fi
vendors=""
canon(){ case "$1" in xai|x.ai|grok) echo grok;; openai|codex|mini) echo codex;; anthropic|claude) echo claude;; *) echo "$1";; esac; }
while read -r sha; do
  msg=$(git log -1 --format=%B "$sha"); echo "$msg" | grep -Eq '^Signed-off-by: ' || fail "commit ${sha:0:8} has no Signed-off-by (DCO)"
  v=$(echo "$msg" | grep -Eio '^[ \t]*Agent-Vendor:[ \t]*[A-Za-z0-9._-]+' | head -1 | awk -F: '{gsub(/[ \t]/,"",$2); print tolower($2)}')
  if [ -z "$v" ]; then for l in $(echo "$LOGINS" | awk -v s="$sha" '$1==s{print $2, $3}'); do m=$(echo "$l" | grep -Eio '(^|[-_])(grok|codex|claude|mini)(\[bot\])?$' | grep -Eio 'grok|codex|claude|mini' | head -1); [ -n "$m" ] && v="$m"; done; fi
  [ -n "$v" ] || fail "commit ${sha:0:8} has no vendor hint (Agent-Vendor trailer or lane-bot login); the Mini controller skips the PR: missing-vendor-hint"
  [ -n "$v" ] && vendors="$vendors $(canon "$v")"
done < <(git rev-list "$RANGE")
UV=$(echo $vendors | tr ' ' '\n' | sort -u | grep -v '^$'); case $(echo "$UV" | grep -c .) in 0) ;; 1) ok "single authoring vendor: $UV ($N commits)";; *) fail "mixed authoring vendors: $(echo $UV) (Mini: mixed-authoring-vendors, admin merge only)";; esac

# 4. Schema: migration-safety block when prisma/migrations or schema.prisma changed.
if git diff --name-only "origin/$BASE...HEAD" 2>/dev/null | grep -Eq '(^|/)prisma/(migrations/|schema\.prisma$)'; then
  if grep -q 'Migration safety' "$BODY"; then ok "schema PR: migration-safety block present (production apply is delivery control, Mark's call)"; else fail "schema/migrations touched but body has no 'Migration safety' block (conference-os: docs/release-architecture/migration-safety-checklist.md)"; fi
else ok "no schema or migration changes"; fi

# 5. Head contains the base tip.
git merge-base --is-ancestor "origin/$BASE" HEAD 2>/dev/null && ok "head contains origin/$BASE tip $(git rev-parse --short origin/$BASE)" || fail "head is behind origin/$BASE; rebase once now (merge captains refuse heads behind base; a later rebase resets review)"

echo; [ "$fails" -eq 0 ] && { echo "PREFLIGHT CLEAN at $(git rev-parse --short HEAD) ($REPO)"; exit 0; } || { echo "PREFLIGHT: $fails miss(es) ($REPO)"; exit 1; }
