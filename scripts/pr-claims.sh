#!/usr/bin/env bash
# pr-claims.sh — read the GitHub-native active-work claim source
set -euo pipefail

usage() {
  cat <<'EOF'
pr-claims.sh — inspect active-work claims in open pull requests

USAGE
  pr-claims.sh list <owner/repo>
  pr-claims.sh find <owner/repo> <claim-id>
  pr-claims.sh close <owner/repo> <pull-request-number>

The list output is tab-separated:
  number, claim id, scope, head branch, URL, created_at, updated_at
EOF
}

[[ $# -ge 2 ]] || { usage >&2; exit 2; }
COMMAND="$1"
REPO="$2"
shift 2

command -v gh >/dev/null 2>&1 || {
  echo "pr-claims.sh: ERROR: gh (GitHub CLI) required" >&2
  exit 2
}

list_claims() {
  gh pr list --repo "$REPO" --state open --limit 100 \
    --json number,body,headRefName,url,createdAt,updatedAt \
    --jq '
      .[]
      | (.body // "") as $body
      | ($body | split("\n") | map(select(startswith("- Active-work claim: "))) | .[0] // "") as $claim
      | select($claim != "")
      | ($body | split("\n") | map(select(startswith("- Claim scope: "))) | .[0] // "") as $scope
      | [
          (.number | tostring),
          ($claim | sub("^- Active-work claim: "; "")),
          ($scope | sub("^- Claim scope: "; "")),
          .headRefName,
          .url,
          .createdAt,
          .updatedAt
        ]
      | @tsv'
}

case "$COMMAND" in
  list)
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    list_claims
    ;;
  find)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    claim_id="$1"
    list_claims | awk -F '\t' -v want="$claim_id" '$2 == want { print; found=1 } END { exit !found }'
    ;;
  close)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    gh pr close "$1" --repo "$REPO"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
