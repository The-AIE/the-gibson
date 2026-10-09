#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS="$ROOT/env/versions.env"
[[ -f "$VERSIONS" ]] || { echo "copy env/versions.env.example to env/versions.env and pin revisions" >&2; exit 2; }
# shellcheck disable=SC1090
source "$VERSIONS"

command -v python3 >/dev/null || { echo "python3 missing" >&2; exit 2; }
command -v git >/dev/null || { echo "git missing" >&2; exit 2; }
command -v nvidia-smi >/dev/null || { echo "NVIDIA GPU/driver unavailable" >&2; exit 2; }

python3 -m venv "$ROOT/.venv"
# shellcheck disable=SC1091
source "$ROOT/.venv/bin/activate"
python -m pip install --upgrade pip

if [[ "$VLLM_VERSION" == "UNPINNED" ]]; then
  echo "VLLM_VERSION must be pinned before bootstrap" >&2
  exit 3
fi
python -m pip install "vllm==$VLLM_VERSION" openai huggingface_hub

echo "Base model: $MINI_GIBSON_BASE_MODEL@$MINI_GIBSON_BASE_REVISION"
echo "Brev base environment prepared. Run env/verify-env.sh next."
