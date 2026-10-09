#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS="$ROOT/env/versions.env"
[[ -f "$VERSIONS" ]] || { echo "FAIL versions.env missing" >&2; exit 2; }
# shellcheck disable=SC1090
source "$VERSIONS"

required=(MINI_GIBSON_BASE_MODEL MINI_GIBSON_BASE_REVISION MINI_GIBSON_DATASET_REVISION MEGATRON_BRIDGE_REVISION VLLM_VERSION TRAINING_CONTAINER_DIGEST GIBSON_BENCH_MANIFEST)
for name in "${required[@]}"; do
  value="${!name:-}"
  [[ -n "$value" && "$value" != "UNPINNED" ]] || { echo "FAIL $name is not pinned" >&2; exit 3; }
done

command -v nvidia-smi >/dev/null || { echo "FAIL nvidia-smi missing" >&2; exit 4; }
command -v python3 >/dev/null || { echo "FAIL python3 missing" >&2; exit 4; }

# Every check runs BEFORE the receipt token is printed, so a partial receipt
# can never be mistaken for a passing one (Grok review of #416, rounds 1-2).
git_sha="$(git -C "$ROOT/.." rev-parse HEAD 2>/dev/null)" || { echo "FAIL git rev-parse HEAD failed in $ROOT/.." >&2; exit 5; }
[[ -n "$git_sha" ]] || { echo "FAIL git rev-parse returned an empty sha" >&2; exit 5; }
gpu_info="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null)" || { echo "FAIL nvidia-smi query failed" >&2; exit 4; }
[[ -n "$gpu_info" ]] || { echo "FAIL nvidia-smi reported no GPU" >&2; exit 4; }
manifest="$ROOT/../$GIBSON_BENCH_MANIFEST"
[[ -f "$manifest" ]] || { echo "FAIL benchmark manifest missing: $GIBSON_BENCH_MANIFEST" >&2; exit 5; }
if command -v shasum >/dev/null; then
  benchmark_sha256="$(shasum -a 256 "$manifest" | awk '{print $1}')" || { echo "FAIL could not hash $GIBSON_BENCH_MANIFEST" >&2; exit 5; }
elif command -v sha256sum >/dev/null; then
  benchmark_sha256="$(sha256sum "$manifest" | awk '{print $1}')" || { echo "FAIL could not hash $GIBSON_BENCH_MANIFEST" >&2; exit 5; }
else
  echo "FAIL neither shasum nor sha256sum is available" >&2; exit 5
fi
[[ "$benchmark_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL manifest hash is not a sha256: '$benchmark_sha256'" >&2; exit 5; }

echo "MINI_GIBSON_REPRO_RECEIPT v1"
echo "git_sha=$git_sha"
echo "python=$(python3 --version 2>&1)"
echo "base_model=$MINI_GIBSON_BASE_MODEL"
echo "base_revision=$MINI_GIBSON_BASE_REVISION"
echo "dataset_revision=$MINI_GIBSON_DATASET_REVISION"
echo "megatron_bridge_revision=$MEGATRON_BRIDGE_REVISION"
echo "vllm_version=$VLLM_VERSION"
echo "training_container_digest=$TRAINING_CONTAINER_DIGEST"
echo "gpu_begin"
echo "$gpu_info"
echo "gpu_end"
echo "benchmark_sha256=$benchmark_sha256"
