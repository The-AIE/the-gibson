#!/usr/bin/env bash
# delivery-control audit — read-only write-path health (docs/23).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
audit.sh — delivery-control audit (read-only)

WHAT IT DOES
  Reports branch protection on default + production branches, GitHub Production
  environment rules, and (when run inside a git checkout) commits ahead of prod.

WHY
  Docs/20: sense unprotected production write paths at adoption and monthly drift.
  ConferenceOS lesson: release branch can be Production while unprotected.

RISKS
  - Read-only GitHub API (needs repo metadata access).
  - Does NOT rotate secrets (G4). Never prints secret values.

USAGE
  audit.sh --repo owner/name [--config path/to/.gibson-delivery.json]
  audit.sh --help

EXAMPLES
  ./scripts/delivery-control/audit.sh --repo mrhinkle/conference-os
  cd ~/Code/acme-app && ../../the-gibson/scripts/delivery-control/audit.sh --repo acme/acme-app
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

load_config "${CONFIG_PATH:-}"
[[ -n "${REPO}" ]] || die "--repo owner/name required (or set in .gibson-delivery.json)"

echo "=============================================="
echo " Delivery control audit — ${REPO}"
echo " model=${MODEL} default=${DEFAULT_BRANCH} prod=${PRODUCTION_BRANCH}"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=============================================="
echo ""

if git rev-parse --git-dir >/dev/null 2>&1; then
  git fetch origin --tags --quiet 2>/dev/null || git fetch origin --tags 2>/dev/null || true
  if git rev-parse "origin/${PRODUCTION_BRANCH}" >/dev/null 2>&1 && git rev-parse "origin/${DEFAULT_BRANCH}" >/dev/null 2>&1; then
    AHEAD="$(git rev-list --count "origin/${PRODUCTION_BRANCH}..origin/${DEFAULT_BRANCH}" 2>/dev/null || echo "?")"
    echo "## Branch tips (this checkout)"
    echo "  origin/${PRODUCTION_BRANCH}: $(git rev-parse --short "origin/${PRODUCTION_BRANCH}" 2>/dev/null || echo missing)"
    echo "  origin/${DEFAULT_BRANCH}:    $(git rev-parse --short "origin/${DEFAULT_BRANCH}" 2>/dev/null || echo missing)"
    echo "  ${DEFAULT_BRANCH} ahead of ${PRODUCTION_BRANCH}: ${AHEAD} commit(s)"
    echo ""
    echo "## Commits on ${DEFAULT_BRANCH} not on ${PRODUCTION_BRANCH} (top 15)"
    git log "origin/${PRODUCTION_BRANCH}..origin/${DEFAULT_BRANCH}" --oneline 2>/dev/null | head -15 || echo "  (none)"
    echo ""
  fi
fi

audit_branch() {
  local branch="$1"
  echo "## Branch protection: ${branch}"
  local body
  if ! body="$(gh api "repos/${REPO}/branches/${branch}/protection" 2>/dev/null)"; then
    echo "  STATUS: NOT PROTECTED"
    echo ""
    return 1
  fi
  local enforce strict reviews force delete contexts
  enforce="$(echo "${body}" | jq -r '.enforce_admins.enabled // false')"
  strict="$(echo "${body}" | jq -r '.required_status_checks.strict // false')"
  reviews="$(echo "${body}" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')"
  force="$(echo "${body}" | jq -r '.allow_force_pushes.enabled // false')"
  delete="$(echo "${body}" | jq -r '.allow_deletions.enabled // false')"
  contexts="$(echo "${body}" | jq -r '.required_status_checks.contexts // [] | join(", ")')"
  echo "  enforce_admins:     ${enforce}"
  echo "  required reviews:   ${reviews}"
  echo "  status strict:      ${strict}"
  echo "  allow_force_pushes: ${force}"
  echo "  allow_deletions:    ${delete}"
  echo "  required contexts:  ${contexts:-"(none)"}"
  local ok=0
  [[ "${enforce}" == "true" ]] || { echo "  FAIL: enforce_admins should be true"; ok=1; }
  [[ "${reviews}" -ge 1 ]] 2>/dev/null || { echo "  FAIL: need ≥1 required approving review"; ok=1; }
  [[ "${strict}" == "true" ]] || { echo "  FAIL: required_status_checks.strict should be true"; ok=1; }
  [[ "${force}" == "false" ]] || { echo "  FAIL: force pushes must be disabled"; ok=1; }
  [[ "${delete}" == "false" ]] || { echo "  FAIL: branch deletion must be disabled"; ok=1; }
  local missing=()
  for ctx in "${REQUIRED_CONTEXTS[@]}"; do
    if ! echo "${body}" | jq -e --arg c "${ctx}" '.required_status_checks.contexts // [] | index($c) != null' >/dev/null 2>&1; then
      missing+=("${ctx}")
    fi
  done
  if ((${#missing[@]} > 0)); then
    echo "  WARN: configured requiredContexts not all present: ${missing[*]}"
    echo "        (update .gibson-delivery.json if CI names differ)"
  fi
  if [[ "${ok}" -eq 0 ]]; then
    echo "  STATUS: OK"
  else
    echo "  STATUS: DRIFT — run apply-branch-protection.sh --apply"
  fi
  echo ""
  return "${ok}"
}

default_ok=0
prod_ok=0
audit_branch "${DEFAULT_BRANCH}" || default_ok=1
if [[ "${MODEL}" == "release-branch" || "${MODEL}" == "tag-pin" ]]; then
  if [[ "${PRODUCTION_BRANCH}" != "${DEFAULT_BRANCH}" ]]; then
    audit_branch "${PRODUCTION_BRANCH}" || prod_ok=1
  fi
fi

if [[ -n "${PROD_ENV}" ]]; then
  echo "## GitHub environment: ${PROD_ENV}"
  env_body="$(gh api "repos/${REPO}/environments/${PROD_ENV}" 2>/dev/null || true)"
  if [[ -z "${env_body}" ]]; then
    echo "  STATUS: missing or inaccessible"
  else
    bypass="$(echo "${env_body}" | jq -r '.can_admins_bypass // true')"
    rules="$(echo "${env_body}" | jq -r '.protection_rules | length')"
    echo "  can_admins_bypass: ${bypass}"
    echo "  protection_rules:  ${rules}"
    if [[ "${rules}" -eq 0 ]]; then
      echo "  STATUS: DRIFT — run apply-production-env.sh --apply"
    else
      echo "  STATUS: rules present"
    fi
  fi
  echo ""
fi

echo "## Hard blocks (agents)"
echo "  NEVER rotate NEON_API_KEY or long-lived secrets (G4 — owner only)."
echo "  NEVER force-push shared branches (G3)."
echo ""

echo "## Summary"
if [[ "${default_ok}" -eq 0 && "${prod_ok}" -eq 0 ]]; then
  echo "  Branch protection: PASS"
  exit 0
else
  echo "  Branch protection: NEEDS HARDEN"
  echo "  See docs/23-delivery-control.md"
  exit 1
fi
