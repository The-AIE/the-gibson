#!/usr/bin/env bash
# Promote verified default-branch SHA to production branch + optional tag (model B).
set -euo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
promote.sh — FF production branch to a verified SHA and optionally tag

WHAT IT DOES
  Dry-run prints the git steps. --apply fast-forwards the production branch
  and can tag after you confirm Production is READY.

WHY
  Docs/20 model B: Production must advance deliberately, not by accident.

RISKS
  - Pushes to production branch → live deploy.
  - Requires clean FF (no force). Schema must stay additive.

USAGE
  promote.sh --repo owner/name --sha <sha> --tag vX.Y.Z --summary "..." [--root PATH] [--apply]
  promote.sh --help
EOF
}

APPLY=0
SHA=""
TAG=""
SUMMARY=""
ROOT="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --sha) SHA="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --summary) SUMMARY="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

load_config "${CONFIG_PATH:-}"
[[ -n "${REPO}" ]] || die "--repo required"
[[ -n "${SHA}" && -n "${TAG}" && -n "${SUMMARY}" ]] || die "--sha --tag --summary required"
[[ "${MODEL}" == "release-branch" ]] || die "promote is for model release-branch (config model=${MODEL})"

cd "${ROOT}"
git fetch origin --tags

FULL="$(git rev-parse --verify "${SHA}^{commit}")"
echo "Promote plan"
echo "  repo:    ${REPO}"
echo "  SHA:     ${FULL}"
echo "  tag:     ${TAG}"
echo "  summary: ${SUMMARY}"
echo "  prod:    ${PRODUCTION_BRANCH}"
echo ""
echo "Preconditions: freeze off, CI green, independent review, schema checklist if needed."

if [[ "${APPLY}" -ne 1 ]]; then
  cat <<EOF

Dry-run commands:
  git checkout ${PRODUCTION_BRANCH} && git pull --ff-only origin ${PRODUCTION_BRANCH}
  git merge --ff-only ${FULL}
  git push origin ${PRODUCTION_BRANCH}
  # wait READY + smoke
  git tag -a ${TAG} -m "${TAG} — ${SUMMARY}" ${FULL}
  git push origin ${TAG}
EOF
  exit 0
fi

confirm_apply "FF origin/${PRODUCTION_BRANCH} to ${FULL}"

git checkout "${PRODUCTION_BRANCH}"
git pull --ff-only "origin" "${PRODUCTION_BRANCH}"
git merge --ff-only "${FULL}"
git push origin "${PRODUCTION_BRANCH}"

echo "Pushed ${PRODUCTION_BRANCH}. Confirm Vercel Production READY for ${FULL}."
if [[ "${GIBSON_ASSUME_YES:-}" != "1" ]]; then
  read -r -p "Type 'tag' after READY + smoke: " answer
  [[ "${answer}" == "tag" ]] || die "stopped before tagging"
fi
git tag -a "${TAG}" -m "${TAG} — ${SUMMARY}" "${FULL}"
git push origin "${TAG}"
echo "Tagged ${TAG}. Secrets were not rotated (G4)."
