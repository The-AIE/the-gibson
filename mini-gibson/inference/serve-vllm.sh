#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$ROOT/env/versions.env"

[[ "$MINI_GIBSON_BASE_REVISION" != "UNPINNED" ]] || { echo "base revision is unpinned" >&2; exit 3; }

# The pinned vLLM is installed by env/setup-brev.sh inside $ROOT/.venv, so serve
# that binary, never whatever `vllm` happens to be on PATH (Grok review of #416).
VLLM_BIN="$ROOT/.venv/bin/vllm"
[[ -x "$VLLM_BIN" ]] || { echo "pinned vLLM not installed at $VLLM_BIN; run env/setup-brev.sh first" >&2; exit 4; }
exec "$VLLM_BIN" serve "$MINI_GIBSON_BASE_MODEL" \
  --revision "$MINI_GIBSON_BASE_REVISION" \
  --host "${VLLM_HOST:-127.0.0.1}" \
  --port "${VLLM_PORT:-8000}" \
  --served-model-name nemotron-base
