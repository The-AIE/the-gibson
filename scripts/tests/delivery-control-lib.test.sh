#!/usr/bin/env bash
# delivery-control-lib.test.sh — mapfile-rewrite equivalence (#192 Fix 4)
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/../delivery-control/lib.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null || { echo "delivery-control-lib.test.sh: jq required"; exit 1; }
command -v gh >/dev/null || { echo "delivery-control-lib.test.sh: gh required to source lib.sh"; exit 1; }
command -v git >/dev/null || { echo "delivery-control-lib.test.sh: git required to source lib.sh"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-dclib.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Isolate defaults; lib.sh need_cmd's tools at source and sets -euo.
# shellcheck source=../delivery-control/lib.sh
. "$LIB"

echo "# requiredContexts:[\"\"] matches origin/main mapfile -t"
printf '%s\n' '{"requiredContexts":[""]}' > "$ROOT/empty-elem.json"
REQUIRED_CONTEXTS=("sentinel")
load_config "$ROOT/empty-elem.json"
got=$(json_contexts)
# origin/main: mapfile -t of jq -r '.requiredContexts[]' on [""] → one empty
# element → printf '%s\n' "" | jq -R . | jq -s . → [""]
want=$(printf '%s\n' "" | jq -R . | jq -s .)
if [[ "${#REQUIRED_CONTEXTS[@]}" -eq 1 && -z "${REQUIRED_CONTEXTS[0]}" && "$got" == "$want" ]]; then
  ok "requiredContexts:[\"\"] keeps one empty element; json_contexts is [\"\"]"
else
  bad "empty-elem (n=${#REQUIRED_CONTEXTS[@]} got=$got want=$want first='${REQUIRED_CONTEXTS[0]-unset}')"
fi

echo "# empty-array expansion is set -u safe"
REQUIRED_CONTEXTS=()
if : ${REQUIRED_CONTEXTS[@]+"${REQUIRED_CONTEXTS[@]}"}; then
  out=$(json_contexts)
  [[ "$out" == "[]" ]] && ok "empty REQUIRED_CONTEXTS expands safely under set -u → []" \
    || bad "empty expand produced $out"
else
  bad "empty REQUIRED_CONTEXTS exploded under set -u"
fi

echo "# [\"a\",\"\",\"b\"] preserves the empty middle (mapfile equivalence)"
printf '%s\n' '{"requiredContexts":["a","","b"]}' > "$ROOT/mid.json"
load_config "$ROOT/mid.json"
got=$(json_contexts)
want=$(printf '%s\n' "a" "" "b" | jq -R . | jq -s .)
if [[ "${#REQUIRED_CONTEXTS[@]}" -eq 3 && -z "${REQUIRED_CONTEXTS[1]}" && "$got" == "$want" ]]; then
  ok "requiredContexts:[\"a\",\"\",\"b\"] preserves empty middle"
else
  bad "middle-empty (n=${#REQUIRED_CONTEXTS[@]} got=$got want=$want)"
fi

echo
echo "delivery-control-lib.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
