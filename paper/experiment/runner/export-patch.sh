#!/bin/bash
# Correct artifact export: git diff OMITS untracked files, so newly created
# source files silently vanish from the patch. Stage everything except the
# harness's own scratch files (node_modules is already gitignored), then diff
# --cached. Verified by the sepaloid/cardines/mediumize failures where the
# reviewer was handed code importing modules the patch did not contain.
set -euo pipefail
D="$1"; OUT="$2"
cd "$D"
git add -A -- . \
  ':(exclude).all' ':(exclude).reach' ':(exclude).remotes' \
  ':(exclude).provision.log' ':(exclude).spec.md' ':(exclude).findings.md'
git diff --binary --cached FETCH_HEAD > "$OUT"
git reset -q
NEW=$(grep -c '^new file mode' "$OUT" || true)
echo "exported $(wc -c < "$OUT") bytes, new_files=$NEW"
