#!/bin/bash
# AB-219 raw-arm replay driver (Mini side). Usage: run-task.sh <code> <base_sha>
set -uo pipefail
CODE="$1"; BASE="$2"; R="$HOME/ab219/runs/$CODE"
echo "=== [$CODE] extract + census ==="
rm -rf "$R"; mkdir -p "$R"
tar -xzf "$HOME/ab219/trees/$CODE.tgz" -C "$R" || { echo "[$CODE] EXTRACT_FAIL"; exit 1; }
cd "$R"
git cat-file --batch-all-objects --batch-check='%(objectname)' | sort > "$R/.all"
git rev-list --objects HEAD | awk '{print $1}' | sort -u > "$R/.reach"
[ -s "$R/.all" ] && [ -s "$R/.reach" ] || { echo "[$CODE] CENSUS_EMPTY"; exit 1; }
diff "$R/.all" "$R/.reach" >/dev/null || { echo "[$CODE] CENSUS_FAIL"; exit 1; }
[ "$(git rev-list --count --all)" = "1" ] || { echo "[$CODE] MULTI_COMMIT"; exit 1; }
[ -z "$(git remote)" ] || { echo "[$CODE] REMOTE_PRESENT"; exit 1; }
[ "$(git rev-parse HEAD)" = "$BASE" ] || { echo "[$CODE] WRONG_BASE"; exit 1; }
echo "[$CODE] CENSUS_PASS objects=$(wc -l < "$R/.all")"

echo "=== [$CODE] provision (coordinator, network on; excluded from metrics) ==="
docker run --rm -v "$R":/work -w /work ab219-runner:2 \
  bash -lc "npm ci --no-audit --no-fund >/work/.provision.log 2>&1 && npx prisma generate >>/work/.provision.log 2>&1" \
  || { echo "[$CODE] PROVISION_FAIL"; tail -15 "$R/.provision.log"; exit 1; }
echo "[$CODE] PROVISION_OK"

echo "=== [$CODE] replay (isolated) ==="
date -u +%Y-%m-%dT%H:%M:%SZ > "$R.start"
docker run --rm \
  -v "$R":/work \
  -v "$HOME/ab219/briefs/$CODE.txt":/brief.txt:ro \
  -v "$HOME/ab219/auth.json":/home/agent/.grok/auth.json:ro \
  -w /work ab219-runner:2 \
  grok --always-approve --cwd /work --model grok-4.5 \
       --output-format streaming-messages-json --prompt-file /brief.txt \
  > "$R.ndjson" 2> "$R.err" < /dev/null
RC=$?
date -u +%Y-%m-%dT%H:%M:%SZ > "$R.end"
echo "[$CODE] AGENT_RC=$RC lines=$(wc -l < "$R.ndjson")"

echo "=== [$CODE] export artifact (binary-capable) ==="
# git diff OMITS untracked files: newly created source files silently vanish
# from the patch. Use the shared corrected exporter (stage-then-diff --cached).
"$HOME/ab219/export-patch.sh" "$R" "$HOME/ab219/patches/$CODE.patch"
cd "$R"
echo "[$CODE] PATCH_BYTES=$(wc -c < "$HOME/ab219/patches/$CODE.patch") NEW_FILES=$(grep -c "^new file mode" "$HOME/ab219/patches/$CODE.patch" || true)"
git diff --stat FETCH_HEAD | tail -8
echo "[$CODE] DONE"
