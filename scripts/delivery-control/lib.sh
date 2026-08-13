#!/usr/bin/env bash
# Shared helpers for delivery-control scripts (docs/23).
# Not standalone: sources ../lib/common.sh (sibling). Copy both.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

# Shared need_cmd (#192). Sourced before the source-time need_cmd calls below
# so missing tools still fail at source exactly as before.
# shellcheck source=../lib/common.sh
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

need_cmd gh
need_cmd jq
need_cmd git

# Defaults (override via --repo, --config, or env)
REPO="${GIBSON_REPO:-}"
CONFIG_PATH="${GIBSON_DELIVERY_CONFIG:-}"
DEFAULT_BRANCH="main"
PRODUCTION_BRANCH="release"
MODEL="release-branch"
PROD_ENV="Production"
REVIEWER_LOGIN="${GIBSON_REVIEWER:-mrhinkle}"

# shellcheck disable=SC2034
DEFAULT_CONTEXTS=(
  "quality"
  "DCO"
  "secrets"
  "dependencies"
  "build-e2e-required"
  "review-evidence"
)

REQUIRED_CONTEXTS=("${DEFAULT_CONTEXTS[@]}")

load_config() {
  local path="${1:-}"
  if [[ -z "${path}" && -n "${CONFIG_PATH}" ]]; then
    path="${CONFIG_PATH}"
  fi
  if [[ -z "${path}" && -f ".gibson-delivery.json" ]]; then
    path=".gibson-delivery.json"
  fi
  [[ -n "${path}" && -f "${path}" ]] || return 0

  local cfg
  cfg="$(cat "${path}")"
  REPO="$(echo "${cfg}" | jq -r --arg d "${REPO}" '.repo // $d')"
  MODEL="$(echo "${cfg}" | jq -r --arg d "${MODEL}" '.model // $d')"
  DEFAULT_BRANCH="$(echo "${cfg}" | jq -r --arg d "${DEFAULT_BRANCH}" '.defaultBranch // $d')"
  PRODUCTION_BRANCH="$(echo "${cfg}" | jq -r --arg d "${PRODUCTION_BRANCH}" '.productionBranch // $d')"
  PROD_ENV="$(echo "${cfg}" | jq -r --arg d "${PROD_ENV}" '.productionEnvironment // $d')"
  REVIEWER_LOGIN="$(echo "${cfg}" | jq -r --arg d "${REVIEWER_LOGIN}" '.reviewerLogin // $d')"
  if echo "${cfg}" | jq -e '.requiredContexts | type == "array" and length > 0' >/dev/null 2>&1; then
    # Bash 3.2 — no mapfile (git-configure.sh:126 / loop-fleet.sh:504).
    # Append every line, including empty strings: mapfile -t preserved those
    # (`requiredContexts:[""]`). Guard later expansions with the 3.2-safe
    # ${arr[@]+"${arr[@]}"} idiom so an empty result does not explode under set -u.
    REQUIRED_CONTEXTS=()
    while IFS= read -r _ctx; do
      REQUIRED_CONTEXTS+=("${_ctx}")
    done < <(echo "${cfg}" | jq -r '.requiredContexts[]')
  fi
  if [[ "${PROD_ENV}" == "null" ]]; then
    PROD_ENV=""
  fi
}

confirm_apply() {
  local label="${1:-this change}"
  if [[ "${GIBSON_ASSUME_YES:-}" == "1" ]]; then
    return 0
  fi
  echo ""
  echo "About to APPLY: ${label}"
  echo "Repo: ${REPO}"
  read -r -p "Type 'apply' to continue: " answer
  [[ "${answer}" == "apply" ]] || die "aborted (typed '${answer:-}')"
}

json_contexts() {
  # printf '%s\n' with zero args still emits one newline; skip it when empty.
  if [[ ${#REQUIRED_CONTEXTS[@]} -eq 0 ]]; then
    printf '%s\n' '[]'
    return
  fi
  printf '%s\n' ${REQUIRED_CONTEXTS[@]+"${REQUIRED_CONTEXTS[@]}"} | jq -R . | jq -s .
}

protection_payload() {
  local contexts
  contexts="$(json_contexts)"
  jq -n \
    --argjson contexts "${contexts}" \
    '{
      required_status_checks: {
        strict: true,
        contexts: $contexts
      },
      enforce_admins: true,
      required_pull_request_reviews: {
        dismiss_stale_reviews: true,
        require_code_owner_reviews: false,
        required_approving_review_count: 1,
        require_last_push_approval: true
      },
      restrictions: null,
      allow_force_pushes: false,
      allow_deletions: false,
      block_creations: false,
      required_conversation_resolution: true,
      required_linear_history: false,
      allow_fork_syncing: false
    }'
}

parse_common_args() {
  # Sets REPO, CONFIG_PATH, APPLY from remaining args pattern used by callers
  :
}
