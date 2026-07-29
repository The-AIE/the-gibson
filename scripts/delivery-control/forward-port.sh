#!/usr/bin/env bash
# Forward-port a hotfix commit onto the default branch (docs/20).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
forward-port.sh — cherry-pick hotfix onto default branch and open PR

USAGE
  forward-port.sh --sha <hotfix-sha> --repo owner/name --root /path/to/target [--apply]
  forward-port.sh --help
EOF
}

APPLY=0
SHA=""
ROOT="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --sha) SHA="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

load_config "${CONFIG_PATH:-}"
[[ -n "${SHA}" ]] || die "--sha required"
[[ -n "${REPO}" ]] || die "--repo required"

cd "${ROOT}"
git fetch origin
FULL="$(git rev-parse --verify "${SHA}^{commit}")"
SHORT="$(git rev-parse --short "${FULL}")"
BRANCH="chore/forward-port-${SHORT}"

echo "Forward-port ${FULL} → ${DEFAULT_BRANCH} as ${BRANCH}"
if [[ "${APPLY}" -ne 1 ]]; then
  echo "Dry-run. Pass --apply to cherry-pick, push, and open PR."
  exit 0
fi

confirm_apply "cherry-pick ${SHORT} onto branch from origin/${DEFAULT_BRANCH}"
git checkout -b "${BRANCH}" "origin/${DEFAULT_BRANCH}"
git cherry-pick "${FULL}" || die "conflict — resolve manually on ${BRANCH}"
git push -u origin "${BRANCH}"
gh pr create --repo "${REPO}" --base "${DEFAULT_BRANCH}" --head "${BRANCH}" \
  --title "chore: forward-port hotfix ${SHORT}" \
  --body "Forward-port of production hotfix \`${FULL}\` so it is not lost on the next promote. See docs/20-delivery-control.md."
echo "PR opened."
