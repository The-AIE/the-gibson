#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$ROOT/env/versions.env"

[[ "$MINI_GIBSON_BASE_REVISION" != "UNPINNED" ]] || { echo "base revision is unpinned" >&2; exit 3; }

exec vllm serve "$MINI_GIBSON_BASE_MODEL" \
  --revision "$MINI_GIBSON_BASE_REVISION" \
  --host "${VLLM_HOST:-127.0.0.1}" \
  --port "${VLLM_PORT:-8000}" \
  --served-model-name nemotron-base
