#!/usr/bin/env bash
# Create hotfix branch from production tag (docs/23).
set -euo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
hotfix-prep.sh — branch from a production tag for a minimal fix

USAGE
  hotfix-prep.sh --from-tag vX.Y.Z --next vX.Y.Z+1 --root /path/to/target
  hotfix-prep.sh --help
EOF
}

FROM_TAG=""
NEXT=""
ROOT="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --from-tag) FROM_TAG="${2:-}"; shift 2 ;;
    --next) NEXT="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "${FROM_TAG}" && -n "${NEXT}" ]] || die "--from-tag and --next required"
cd "${ROOT}"
git fetch origin --tags
git rev-parse --verify "${FROM_TAG}^{commit}" >/dev/null || die "unknown tag ${FROM_TAG}"
BRANCH="hotfix/${NEXT}"
git show-ref --verify --quiet "refs/heads/${BRANCH}" && die "branch ${BRANCH} exists"
git checkout -b "${BRANCH}" "${FROM_TAG}"
echo "Created ${BRANCH} from ${FROM_TAG}"
echo "Next: smallest fix → PR into production branch → tag ${NEXT} → forward-port.sh"
echo "Secret rotation is out of scope (G4)."
