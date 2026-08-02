#!/usr/bin/env bash
# Apply branch protection (docs/23 harden). Default dry-run; --apply writes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
apply-branch-protection.sh — harden default + production branch protection

WHAT IT DOES
  Puts enforce_admins, ≥1 review, strict status checks, no force-push on the
  default branch and (model release-branch) the production branch.

WHY
  Docs/20: admins must not bypass gates; production write path must be locked.

RISKS
  - Misnamed requiredContexts can block all merges until fixed.
  - Requires repo admin. Dry-run first.

USAGE
  apply-branch-protection.sh --repo owner/name [--config path] [--apply]
  apply-branch-protection.sh --help

EXAMPLES
  ./scripts/delivery-control/apply-branch-protection.sh --repo acme/app
  ./scripts/delivery-control/apply-branch-protection.sh --repo acme/app --apply
EOF
}

APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

load_config "${CONFIG_PATH:-}"
[[ -n "${REPO}" ]] || die "--repo required"

PAYLOAD="$(protection_payload)"
echo "Target: ${REPO}"
echo "Branches: ${DEFAULT_BRANCH}"
if [[ "${MODEL}" == "release-branch" && "${PRODUCTION_BRANCH}" != "${DEFAULT_BRANCH}" ]]; then
  echo "          ${PRODUCTION_BRANCH}"
fi
echo "${PAYLOAD}" | jq .

if [[ "${APPLY}" -ne 1 ]]; then
  echo ""
  echo "Dry-run only. Re-run with --apply to write."
  exit 0
fi

confirm_apply "branch protection on ${DEFAULT_BRANCH} (+ ${PRODUCTION_BRANCH} if model B)"

apply_one() {
  local branch="$1"
  echo "Putting protection on ${branch}..."
  if ! echo "${PAYLOAD}" | gh api --method PUT \
    "repos/${REPO}/branches/${branch}/protection" --input - \
    >/tmp/gibson-protect-"${branch//\//_}".json 2>/tmp/gibson-protect.err; then
    echo "  full payload failed; retrying without require_last_push_approval..."
    jq 'del(.required_pull_request_reviews.require_last_push_approval)' <<<"${PAYLOAD}" \
      | gh api --method PUT "repos/${REPO}/branches/${branch}/protection" --input - \
      >/tmp/gibson-protect-"${branch//\//_}".json
  fi
  echo "  OK: ${branch}"
}

apply_one "${DEFAULT_BRANCH}"
if [[ "${MODEL}" == "release-branch" && "${PRODUCTION_BRANCH}" != "${DEFAULT_BRANCH}" ]]; then
  apply_one "${PRODUCTION_BRANCH}"
fi

echo ""
echo "Done. Re-run audit.sh. Secret rotation was NOT performed (G4)."
