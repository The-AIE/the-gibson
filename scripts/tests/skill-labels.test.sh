#!/usr/bin/env bash
# skill-labels.test.sh — every shipped skill carries a valid key, category and tags
# (ci/validate_skill_labels.py against ci/skill-ontology.json, namespace "gibson").
set -uo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT" || exit 1
PASS=0
FAIL=0
ok() { echo "  ok — $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $*"; FAIL=$((FAIL + 1)); }

validate() {
  python3 ci/validate_skill_labels.py --root "$1" --namespace gibson \
    --ontology ci/skill-ontology.json --glob 'skills/*' --glob '.agents/skills/*'
}

if out=$(validate "$REPO_ROOT" 2>&1); then
  ok "all skills labeled: $(printf '%s\n' "$out" | tail -1)"
else
  bad "skill labels invalid: $out"
fi

# Mutation witness: a planted bad skill must fail the validator.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/skill-labels.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/skills/planted"
printf -- '---\nname: planted\nkey: gibson.planted\ncategory: Nope\ntags: [not-a-tag]\n---\nbody\n' > "$TMP/skills/planted/SKILL.md"
if validate "$TMP" >/dev/null 2>&1; then
  bad "planted unknown category/tag passed the validator"
else
  ok "planted unknown category/tag is rejected"
fi

echo "skill-labels.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
