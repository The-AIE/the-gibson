#!/usr/bin/env bash
# Configure GitHub Production environment reviewers (docs/23). Default dry-run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
apply-production-env.sh — required reviewers on GitHub Production environment

WHAT IT DOES
  PUT environment protection: required reviewer + protected-branches policy.

WHY
  Docs/20: Production environment should not be an open gate for admins alone.

RISKS
  - Replaces environment protection rules for that environment name.
  - Does not change Vercel Production Branch (verify separately).
  - Does not rotate secrets.

USAGE
  apply-production-env.sh --repo owner/name [--reviewer login] [--apply]
  apply-production-env.sh --help
EOF
}

APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --reviewer) REVIEWER_LOGIN="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

load_config "${CONFIG_PATH:-}"
[[ -n "${REPO}" ]] || die "--repo required"
[[ -n "${PROD_ENV}" ]] || die "productionEnvironment disabled in config (null)"

REVIEWER_ID="$(gh api "users/${REVIEWER_LOGIN}" --jq .id)"
[[ -n "${REVIEWER_ID}" ]] || die "could not resolve @${REVIEWER_LOGIN}"

PAYLOAD="$(jq -n --argjson rid "${REVIEWER_ID}" '{
  wait_timer: 0,
  prevent_self_review: false,
  reviewers: [ { type: "User", id: $rid } ],
  deployment_branch_policy: {
    protected_branches: true,
    custom_branch_policies: false
  }
}')"

echo "Environment: ${PROD_ENV} on ${REPO}"
echo "Reviewer: @${REVIEWER_LOGIN} (${REVIEWER_ID})"
echo "${PAYLOAD}" | jq .

if [[ "${APPLY}" -ne 1 ]]; then
  echo ""
  echo "Dry-run only. Re-run with --apply to write."
  exit 0
fi

confirm_apply "GitHub environment ${PROD_ENV} required reviewers"

gh api --method PUT "repos/${REPO}/environments/${PROD_ENV}" --input - <<<"${PAYLOAD}" \
  | jq '{name, protection_rules: [.protection_rules[]?.type], deployment_branch_policy}'

echo "Done. Vercel Production Branch is unchanged (verify in dashboard)."
echo "Secret rotation was NOT performed (G4)."
