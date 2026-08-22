#!/bin/bash
# AB-219 HARNESS arm (D-3 scripted treatment). Usage: harness-task.sh <code> <base_sha>
# spec gate -> implement -> ONE cross-vendor review -> ONE fix loop -> stop
set -uo pipefail
CODE="$1"; BASE="$2"; R="$HOME/ab219/runs/${CODE}-h"; A="$HOME/ab219"
B="$A/briefs/$CODE.txt"
echo "=== [$CODE-h] extract + census ==="
rm -rf "$R"; mkdir -p "$R"
tar -xzf "$A/trees/$CODE.tgz" -C "$R" || { echo "[$CODE-h] EXTRACT_FAIL"; exit 1; }
cd "$R"
git cat-file --batch-all-objects --batch-check='%(objectname)' | sort > "$R/.all"
git rev-list --objects HEAD | awk '{print $1}' | sort -u > "$R/.reach"
[ -s "$R/.all" ] && [ -s "$R/.reach" ] || { echo "[$CODE-h] CENSUS_EMPTY"; exit 1; }
diff "$R/.all" "$R/.reach" >/dev/null || { echo "[$CODE-h] CENSUS_FAIL"; exit 1; }
[ "$(git rev-list --count --all)" = "1" ] || { echo "[$CODE-h] MULTI_COMMIT"; exit 1; }
[ "$(git rev-parse HEAD)" = "$BASE" ] || { echo "[$CODE-h] WRONG_BASE"; exit 1; }
echo "[$CODE-h] CENSUS_PASS objects=$(wc -l < "$R/.all")"

docker run --rm -v "$R":/work -w /work ab219-runner:2 \
  bash -lc "npm ci --no-audit --no-fund >/work/.provision.log 2>&1 && npx prisma generate >>/work/.provision.log 2>&1" \
  || { echo "[$CODE-h] PROVISION_FAIL"; exit 1; }
echo "[$CODE-h] PROVISION_OK"

grokrun () { # $1=promptfile $2=outfile
  docker run --rm -v "$R":/work -v "$1":/prompt.txt:ro \
    -v "$A/auth.json":/home/agent/.grok/auth.json:ro -w /work ab219-runner:2 \
    grok --always-approve --cwd /work --model grok-4.5 \
         --output-format streaming-messages-json --prompt-file /prompt.txt \
    > "$2" 2>>"$R.err" < /dev/null
}

date -u +%Y-%m-%dT%H:%M:%SZ > "$R.start"

# --- Stage A: spec gate ---
{ cat "$B"; printf '\n\n---- STAGE: SPECIFICATION ONLY ----\n'
  printf 'Do NOT implement anything and do NOT edit any source file.\n'
  printf 'Produce a specification and an explicit acceptance checklist for the task above.\n'
  printf 'Write it to /work/.spec.md and stop.\n'; } > "$A/p-$CODE-spec.txt"
grokrun "$A/p-$CODE-spec.txt" "$R.spec.ndjson"
# ENFORCE spec-only STRUCTURALLY, not by instruction. The pilot showed the agent
# edits source during this stage even when told not to; a gate that depends on
# compliance is not a gate. Any tracked change is reverted; .spec.md is untracked
# and survives. Recorded, so treatment infidelity is measured rather than hidden.
cd "$R"
SPEC_DIRTY=$(git status --porcelain | grep -v '^?? ' | wc -l | tr -d ' ')
if [ "$SPEC_DIRTY" != "0" ]; then git checkout -- . ; fi
[ "$(git status --porcelain | grep -v '^?? ' | wc -l | tr -d ' ')" = "0" ] \
  || { echo "[$CODE-h] SPEC_REVERT_FAIL"; exit 1; }
echo "[$CODE-h] SPEC_OK bytes=$( [ -f "$R/.spec.md" ] && wc -c < "$R/.spec.md" || echo 0) reverted_files=$SPEC_DIRTY"

# --- Stage B: implement against the spec ---
{ cat "$B"; printf '\n\n---- STAGE: IMPLEMENT ----\n'
  printf 'A specification and acceptance checklist for this task is at /work/.spec.md. Read it first.\n'
  printf 'Implement the task so the checklist is satisfied.\n'; } > "$A/p-$CODE-impl.txt"
grokrun "$A/p-$CODE-impl.txt" "$R.impl.ndjson"
"$A/export-patch.sh" "$R" "$A/patches/${CODE}-h-round1.patch" >/dev/null
echo "[$CODE-h] IMPL_OK patch=$(wc -c < "$A/patches/${CODE}-h-round1.patch")"

# --- Stage C: ONE cross-vendor adversarial review (patch + brief ONLY) ---
RV="$A/review-$CODE"; rm -rf "$RV"; mkdir -p "$RV"
cp "$A/patches/${CODE}-h-round1.patch" "$RV/patch.txt"; cp "$B" "$RV/brief.txt"
# A patch that omits new files makes the reviewer emit false "module missing"
# findings. Record the count so completeness is visible per run.
echo "[$CODE-h] PATCH_NEW_FILES=$(grep -c '^new file mode' "$RV/patch.txt" || true)"
cat > "$RV/prompt.txt" <<'PR'
You are an adversarial code reviewer. REFUTE, do not agree. Be concrete and specific.
/review/brief.txt is the task. /review/patch.txt is a candidate implementation of it.
You have ONLY these two files. There is no repository and no history available to you.
Judge whether the patch correctly and completely implements the brief. Hunt for: unmet
acceptance criteria, correctness bugs, missing edge cases, missing or vacuous tests,
scope creep, and anything that would break at runtime.
Write a numbered list of concrete findings, each marked BLOCKING or MINOR. If the patch
is sound, say so plainly rather than inventing findings. End with FINDINGS_END.
PR
# Codex's internal bwrap sandbox cannot create user namespaces inside Docker, so
# every file read fails and the reviewer emits a bogus BLOCKING finding about its
# own environment. The CONTAINER is the sandbox here -- only 3 files are mounted,
# no repo, no history, no GitHub credential -- so bypassing the redundant inner
# sandbox is both necessary and safe. Verified by the pilot, which caught this.
docker run --rm -v "$RV":/review -v "$A/codex-auth.json":/home/rev/.codex/auth.json:ro \
  -w /review ab219-reviewer:1 \
  codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
    -C /review "$(cat "$RV/prompt.txt")" \
  > "$R.review.txt" 2>&1 < /dev/null
# FAIL CLOSED: a review that never read the inputs is not a review. Any run whose
# review output shows the sandbox failure, or claims it could not inspect the
# files, aborts rather than feeding environment noise into the fix loop as if it
# were a code finding.
if grep -qiE "bwrap|could not be inspected|cannot be judged from available evidence" "$R.review.txt"; then
  echo "[$CODE-h] REVIEW_INVALID — reviewer did not read the inputs"; exit 1
fi
grep -q "FINDINGS_END" "$R.review.txt" || { echo "[$CODE-h] REVIEW_TRUNCATED"; exit 1; }
echo "[$CODE-h] REVIEW_OK bytes=$(wc -c < "$R.review.txt")"

# --- Stage D: ONE fix loop ---
tail -c 12000 "$R.review.txt" > "$R/.findings.md"
{ cat "$B"; printf '\n\n---- STAGE: ADDRESS REVIEW ----\n'
  printf 'You already implemented this task. An independent adversarial reviewer produced\n'
  printf 'findings, saved at /work/.findings.md. Read them and address the ones that are\n'
  printf 'genuine defects. You may reject a finding you judge incorrect; say why.\n'
  printf 'This is the final round.\n'; } > "$A/p-$CODE-fix.txt"
grokrun "$A/p-$CODE-fix.txt" "$R.fix.ndjson"
date -u +%Y-%m-%dT%H:%M:%SZ > "$R.end"

"$A/export-patch.sh" "$R" "$A/patches/${CODE}-h.patch" >/dev/null
echo "[$CODE-h] FINAL_PATCH=$(wc -c < "$A/patches/${CODE}-h.patch")"
git diff --stat FETCH_HEAD | tail -6
echo "[$CODE-h] DONE"
