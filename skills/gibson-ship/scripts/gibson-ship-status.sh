#!/usr/bin/env bash
# gibson-ship status: what the gates see for one PR in any wired repo. Read-only.
# Usage: gibson-ship-status.sh <pr-number> [owner/repo]   (repo defaults to the current checkout's)
set -uo pipefail
PR="${1:-}"; REPO="${2:-$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')}"   # origin, not gh repo view (fork checkouts answer with upstream)
[ -n "$PR" ] && [ -n "$REPO" ] || { echo "usage: $0 <pr-number> [owner/repo]"; exit 2; }
J=$(gh pr view "$PR" -R "$REPO" --json state,headRefOid,baseRefName,labels,mergeable,mergeStateStatus,isDraft,mergedAt,mergeCommit) || exit 1
HEAD=$(echo "$J" | jq -r .headRefOid); BASE=$(echo "$J" | jq -r .baseRefName)
echo "$REPO #$PR  state=$(echo "$J" | jq -r .state) draft=$(echo "$J" | jq -r .isDraft) head=${HEAD:0:12} base=$BASE"
echo "labels: $(echo "$J" | jq -r '[.labels[].name] | join(", ")')"
echo "mergeable=$(echo "$J" | jq -r .mergeable) mergeState=$(echo "$J" | jq -r .mergeStateStatus) merged=$(echo "$J" | jq -r '.mergedAt // "-"') mergeCommit=$(echo "$J" | jq -r '.mergeCommit.oid // "-" | .[0:12]')"
BEHIND=$(gh api "repos/$REPO/compare/$BASE...$HEAD" --jq .behind_by 2>/dev/null); case "$BEHIND" in ''|*[!0-9]*) BEHIND="? (no common ancestor or compare failed)";; esac; echo "behind $BASE by: $BEHIND (captains need 0)"
# Required contexts: installed config in the checkout if we are in that repo, else branch protection.
CTX=""; SRC=""
if [ -f .agents/gibson-delivery.json ] && [ "$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')" = "$REPO" ]; then CTX=$(jq -r '(.requiredContexts // [])[]' .agents/gibson-delivery.json | tr '\n' ' '); SRC=".agents/gibson-delivery.json"; fi
if [ -z "$CTX" ]; then if PROT=$(gh api "repos/$REPO/branches/$BASE/protection" --jq '(.required_status_checks.contexts // [])[]' 2>/dev/null); then CTX=$(echo "$PROT" | tr '\n' ' '); SRC="branch protection on $BASE"; else SRC="none: $BASE has no branch protection (GitHub 404)"; fi; fi
echo; echo "Required contexts at head (${SRC:-none found}): ${CTX:-none}"
CR=$(gh api "repos/$REPO/commits/$HEAD/check-runs?per_page=100" --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion // "-")"')
ST=$(gh api "repos/$REPO/commits/$HEAD/status" --jq '.statuses[] | "\(.context)\t\(.state)\t\(.description // "")"')
for c in $CTX; do
  l=$(echo "$CR" | awk -F'\t' -v c="$c" '$1==c' | tail -1); [ -z "$l" ] && l=$(echo "$ST" | awk -F'\t' -v c="$c" '$1==c{printf "%s\t%s\t%s", $1, $2, substr($3,1,160)}')
  [ -n "$l" ] && echo "  $l" || echo "  $c	(not reported yet)"
done
echo "$ST" | awk -F'\t' '$1 ~ /^Neon schema rehearsal/ {printf "  %s\t%s\n", $1, $2}' | head -3
echo; echo "Review-evidence blocks on comments (newest first; who may clear this repo is in its trust file):"
gh api "repos/$REPO/issues/$PR/comments?per_page=100" --jq '[.[] | select(.body | test("review-evidence:v1|owner-review-attestation:v1|owner-attested-review:v1"))] | reverse | .[:4][] | "  \(.created_at) \(.user.login) app=\(.performed_via_github_app.slug // "-") head=\(.body | capture("head-sha:\\s*(?<h>[0-9a-f]{40})")? .h // "?" | .[0:12]) result=\(.body | capture("result:\\s*(?<r>pass|fail)")? .r // "-")"' 2>/dev/null
gh api "repos/$REPO/pulls/$PR/reviews" --jq '.[-3:][] | "  review \(.submitted_at) \(.user.login) \(.state) at \(.commit_id[0:12])"' 2>/dev/null
[ -f config/review-evidence.v1.json ] && echo "  trust file: config/review-evidence.v1.json (reviewers: $(jq -r '[.identities[] | select(.roles | index("reviewer")) | .login] | join(", ")' config/review-evidence.v1.json))"
[ -f .github/review-evidence-trust.json ] && echo "  trust file: .github/review-evidence-trust.json (comment providers: $(jq -r '[.trustedCommentProviders[].actor] | join(", ")' .github/review-evidence-trust.json))"
echo; echo "Mac Mini independent reviewer:"
ssh -o ConnectTimeout=6 mac-mini 'D="$HOME/Library/Application Support/Neuro/independent-review"; if python3 -c "import json,sys; p=json.load(open(\"$D/policy.json\")); sys.exit(0 if any(r[\"name\"]==\"'"$REPO"'\" for r in p[\"repositories\"]) else 1)"; then grep "\"number\": '"$PR"'," "$D/state/journal.jsonl" | tail -5 | cut -c1-220 | sed "s/^/  /"; launchctl print gui/$(id -u)/com.peripety.neuro-independent-review 2>/dev/null | grep -m1 -E "state = " | sed "s/^/  job /"; else echo "  policy.json does not list '"$REPO"'; the Mini App will not review it (controller change needed, not policy)"; fi' 2>/dev/null || echo "  (mac-mini unreachable)"
