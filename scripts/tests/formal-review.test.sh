#!/usr/bin/env bash
# formal-review.test.sh — dedicated reviewer identity sensors (#67 / #290)
set -uo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FR="$SCRIPT_DIR/../formal-review.sh"
SO="$SCRIPT_DIR/../second-opinion.sh"
PASS=0; FAIL=0
ok(){ echo "  ok   — $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL — $1"; FAIL=$((FAIL+1)); }

COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BAD_UPPER=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-formal.XXXXXX")
trap 'rm -rf -- "${ROOT:?}"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
CALLS="$ROOT/calls"; mkdir -p "$CALLS"

# Fake gh that records invocations and refuses if GH_TOKEN looks like builder.
# GitHub CLI: -F/--field key=@file reads the file; -f/--raw-field sends "@file"
# as a literal string. The seam must not load @file for the raw-field form.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_LOG:-/dev/null}"
prev=""
is_review=0
is_pr_review=0
commit_id=""
event=""
for a in "$@"; do
  if [[ "$prev" == "pr" && "$a" == "review" ]]; then
    is_pr_review=1
  fi
  if [[ "$prev" == "-F" || "$prev" == "--field" ]]; then
    case "$a" in
      commit_id=*) commit_id="${a#commit_id=}" ;;
      event=*) event="${a#event=}" ;;
      body=@*)
        _bf="${a#body=@}"
        if [[ -n "$_bf" && -f "$_bf" ]]; then
          cat "$_bf" > "${GH_BODY_LOG:-/dev/null}"
        else
          printf '%s' "@${_bf}" > "${GH_BODY_LOG:-/dev/null}"
        fi
        ;;
      body=*)
        printf '%s' "${a#body=}" > "${GH_BODY_LOG:-/dev/null}"
        ;;
    esac
  elif [[ "$prev" == "-f" || "$prev" == "--raw-field" ]]; then
    case "$a" in
      commit_id=*) commit_id="${a#commit_id=}" ;;
      event=*) event="${a#event=}" ;;
      body=*)
        printf '%s' "${a#body=}" > "${GH_BODY_LOG:-/dev/null}"
        ;;
    esac
  else
    case "$a" in
      */reviews) is_review=1 ;;
    esac
  fi
  prev="$a"
done
if [[ "$is_pr_review" -eq 1 ]]; then
  echo "OLD_PR_REVIEW $*" >> "${GH_PR_REVIEW_LOG:-/dev/null}"
  echo "REVIEW_OK $*"
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
  echo "gibson-reviewer-bot"
  exit 0
fi
if [[ "$is_review" -eq 1 ]]; then
  if [[ "${GH_FAIL_REVIEW:-0}" == "1" ]]; then
    echo "simulated adapter failure" >&2
    exit 1
  fi
  echo call >> "${GH_REVIEW_COUNT:-/dev/null}"
  printf '%s\n' "$commit_id" > "${GH_COMMIT_LOG:-/dev/null}"
  printf '%s\n' "$event" > "${GH_EVENT_LOG:-/dev/null}"
  echo "REVIEW_API_OK"
  exit 0
fi
exit 0
GH
chmod +x "$BIN/gh"
export PATH="$BIN:/usr/bin:/bin"
export GH_LOG="$ROOT/gh.log"
export GH_PR_REVIEW_LOG="$ROOT/pr-review.log"
export GH_REVIEW_COUNT="$ROOT/review.count"
export GH_COMMIT_LOG="$ROOT/commit.log"
export GH_EVENT_LOG="$ROOT/event.log"
export GH_BODY_LOG="$ROOT/body.log"
: > "$GH_LOG"
: > "$GH_PR_REVIEW_LOG"
: > "$GH_REVIEW_COUNT"

reset_logs() {
  : > "$GH_LOG"
  : > "$GH_PR_REVIEW_LOG"
  : > "$GH_REVIEW_COUNT"
  rm -f "$GH_COMMIT_LOG" "$GH_EVENT_LOG" "$GH_BODY_LOG"
  unset GH_FAIL_REVIEW || true
}

echo "help / missing token"
out=$("$FR" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'L-015' >/dev/null && echo "$out" | grep  -- '--commit' >/dev/null \
  && ok "help" || bad "help"
unset GH_REVIEWER_TOKEN GIBSON_REVIEWER_TOKEN GH_TOKEN
out=$("$FR" --pr 1 --repo a/b --event approve --commit "$COMMIT" 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -i 'GH_REVIEWER_TOKEN' >/dev/null && ok "missing token exits 2" \
  || bad "missing token (rc=$rc): $out"

echo "missing / invalid commit refused before mutation"
reset_logs
export GH_REVIEWER_TOKEN="reviewer-secret-token"
out=$("$FR" --pr 9 --repo acme/app --event approve --body LGTM 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep  -- '--commit' >/dev/null && ! grep -q reviews "$GH_LOG" \
  && ok "missing --commit exits 2 before gh" \
  || bad "missing commit (rc=$rc log=$(cat "$GH_LOG") out=$out)"
out=$("$FR" --pr 9 --repo acme/app --event approve --commit "$BAD_UPPER" --body LGTM 2>&1); rc=$?
[[ "$rc" -eq 1 ]] && echo "$out" | grep -i 'invalid --commit' >/dev/null && ! grep -q reviews "$GH_LOG" \
  && ok "uppercase SHA refused before mutation" \
  || bad "uppercase (rc=$rc log=$(cat "$GH_LOG") out=$out)"
out=$("$FR" --pr 9 --repo acme/app --event approve --commit deadbeef --body LGTM 2>&1); rc=$?
[[ "$rc" -eq 1 ]] && ! grep -q reviews "$GH_LOG" && ok "short SHA refused before mutation" \
  || bad "short sha (rc=$rc log=$(cat "$GH_LOG"))"
out=$("$FR" --pr 9 --repo acme/app --event approve --commit "${COMMIT}a" --body LGTM 2>&1); rc=$?
[[ "$rc" -eq 1 ]] && ! grep -q reviews "$GH_LOG" && ok "41-char SHA refused before mutation" \
  || bad "long sha (rc=$rc log=$(cat "$GH_LOG"))"

echo "dry-run with token"
reset_logs
export GH_REVIEWER_TOKEN="reviewer-secret-token"
out=$("$FR" --pr 9 --repo acme/app --event approve --commit "$COMMIT" --dry-run 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'dry-run' >/dev/null && echo "$out" | grep "$COMMIT" >/dev/null \
  && ok "dry-run" || bad "dry-run (rc=$rc): $out"
if grep -q 'reviews' "$GH_LOG" 2>/dev/null || grep 'pr review' "$GH_LOG" 2>/dev/null; then
  bad "dry-run called mutation API"
else
  ok "dry-run no API post"
fi

echo "approve posts under reviewer token with commit_id"
reset_logs
out=$("$FR" --pr 9 --repo acme/app --event approve --commit "$COMMIT" --body "LGTM" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "approve exit 0" || bad "approve (rc=$rc): $out"
grep -q '/reviews' "$GH_LOG" && ok "create-review API invoked" || bad "log: $(cat "$GH_LOG")"
grep -q "commit_id=$COMMIT" "$GH_LOG" && ok "exact commit_id on argv" || bad "flags: $(cat "$GH_LOG")"
[[ -s "$GH_EVENT_LOG" && "$(tr -d '\n' < "$GH_EVENT_LOG")" == "APPROVE" ]] \
  && ok "approve event field" || bad "event: $(cat "$GH_EVENT_LOG" 2>/dev/null)"
echo "$out" | grep 'gibson-reviewer-bot' >/dev/null && ok "identity in log" || bad "who: $out"
if grep -q 'pr review' "$GH_LOG" || [[ -s "$GH_PR_REVIEW_LOG" ]]; then
  bad "approve used gh pr review"
else
  ok "approve did not use gh pr review"
fi
echo "$out" | grep "$COMMIT" >/dev/null && ok "approve log names the commit" || bad "approve log missing commit"

echo "request-changes"
reset_logs
out=$("$FR" --pr 3 --repo acme/app --event request-changes --commit "$COMMIT" --body "fix" 2>&1); rc=$?
[[ "$rc" -eq 0 && "$(tr -d '\n' < "$GH_EVENT_LOG")" == "REQUEST_CHANGES" ]] \
  && grep -q "commit_id=$COMMIT" "$GH_LOG" && ok "request-changes" \
  || bad "rc (rc=$rc log=$(cat "$GH_LOG") event=$(cat "$GH_EVENT_LOG" 2>/dev/null))"

echo "comment event still requires commit_id"
reset_logs
out=$("$FR" --pr 3 --repo acme/app --event comment --commit "$COMMIT" --body "note" 2>&1); rc=$?
[[ "$rc" -eq 0 && "$(tr -d '\n' < "$GH_EVENT_LOG")" == "COMMENT" ]] \
  && ok "comment + commit_id" || bad "comment (rc=$rc event=$(cat "$GH_EVENT_LOG" 2>/dev/null))"

echo "body-file contents reach the API, not argv token"
reset_logs
printf '%s' "body-from-file $COMMIT" > "$ROOT/body.txt"
out=$("$FR" --pr 4 --repo acme/app --event approve --commit "$COMMIT" --body-file "$ROOT/body.txt" 2>&1); rc=$?
got=$(cat "$GH_BODY_LOG" 2>/dev/null || true)
if [[ "$rc" -eq 0 && "$got" == "body-from-file $COMMIT" ]]; then
  ok "body-file posted exact bytes"
else
  bad "body-file (rc=$rc body=$got)"
fi
if grep -q 'reviewer-secret-token' "$GH_LOG"; then
  bad "token leaked into gh argv"
else
  ok "token stayed out of gh argv"
fi

echo "raw-field @file is literal; typed-field @file loads exact bytes"
MARKER="EXACT_BODY_BYTES_290_${COMMIT}"
printf '%s' "$MARKER" > "$ROOT/payload.txt"
# Red: GitHub CLI -f/--raw-field must not read @file (literal "@path" token).
reset_logs
"$BIN/gh" api --method POST "repos/acme/app/pulls/9/reviews" \
  -f commit_id="$COMMIT" \
  -f event="APPROVE" \
  -f "body=@${ROOT}/payload.txt" >/dev/null
raw_body=$(cat "$GH_BODY_LOG" 2>/dev/null || true)
if [[ "$raw_body" == "$MARKER" ]]; then
  bad "red: raw-field loaded file bytes (fake-gh seam is vacuous)"
elif [[ "$raw_body" == "@${ROOT}/payload.txt" ]]; then
  ok "red: raw-field sent literal @path token"
else
  bad "red: raw-field body was '$raw_body'"
fi
# Red via a throwaway adapter copy forced onto -f/--raw-field for body.
reset_logs
awk '
  {
    if ($0 ~ /body=@/) {
      gsub(/-F "body=@/, "-f \"body=@")
      gsub(/-F body=@/, "-f body=@")
      gsub(/--field "body=@/, "--raw-field \"body=@")
      gsub(/--field body=@/, "--raw-field body=@")
    }
    print
  }
' "$FR" > "$ROOT/raw-field-fr.sh"
chmod +x "$ROOT/raw-field-fr.sh"
if grep -q -- '-F "body=@' "$ROOT/raw-field-fr.sh" || grep  -- '--field "body=@' "$ROOT/raw-field-fr.sh" >/dev/null; then
  bad "red: throwaway copy still uses typed-field for body (mutation vacuous)"
else
  ok "red: throwaway copy forced body onto raw-field"
fi
out=$("$ROOT/raw-field-fr.sh" --pr 4 --repo acme/app --event approve --commit "$COMMIT" --body-file "$ROOT/payload.txt" 2>&1); rc=$?
mut_body=$(cat "$GH_BODY_LOG" 2>/dev/null || true)
if [[ "$mut_body" == "$MARKER" ]]; then
  bad "red: mutated raw-field adapter still delivered file bytes (rc=$rc)"
elif [[ "$mut_body" == @* && "$rc" -eq 0 ]]; then
  ok "red: mutated raw-field adapter sent literal @path, not payload bytes"
else
  bad "red: mutated adapter rc=$rc body='$mut_body'"
fi
# Green: production typed-field must send the exact payload bytes.
reset_logs
out=$("$FR" --pr 4 --repo acme/app --event approve --commit "$COMMIT" --body-file "$ROOT/payload.txt" 2>&1); rc=$?
got=$(cat "$GH_BODY_LOG" 2>/dev/null || true)
if [[ "$rc" -eq 0 && "$got" == "$MARKER" ]]; then
  ok "green: typed-field sent exact body bytes"
else
  bad "green: rc=$rc body='$got' expected '$MARKER'"
fi
if [[ "$(tr -d '\n' < "$GH_COMMIT_LOG")" == "$COMMIT" && "$(tr -d '\n' < "$GH_EVENT_LOG")" == "APPROVE" ]]; then
  ok "green: commit_id and event still posted as raw fields"
else
  bad "green: commit=$(cat "$GH_COMMIT_LOG" 2>/dev/null) event=$(cat "$GH_EVENT_LOG" 2>/dev/null)"
fi

echo "adapter failure"
reset_logs
export GH_FAIL_REVIEW=1
out=$("$FR" --pr 9 --repo acme/app --event approve --commit "$COMMIT" --body LGTM 2>&1); rc=$?
unset GH_FAIL_REVIEW
[[ "$rc" -eq 1 ]] && echo "$out" | grep -i 'failed to create review' >/dev/null \
  && [[ ! -s "$GH_REVIEW_COUNT" || "$(wc -l < "$GH_REVIEW_COUNT" | tr -d ' ')" -eq 0 ]] \
  && ok "adapter failure exits 1 without a created event" \
  || bad "adapter failure (rc=$rc out=$out count=$(cat "$GH_REVIEW_COUNT"))"

echo "historical no-commit mutation: old gh pr review posts without commit_id"
reset_logs
cat > "$ROOT/old-formal-review.sh" <<'OLD'
#!/usr/bin/env bash
set -euo pipefail
export GH_TOKEN="${GH_REVIEWER_TOKEN:-}"
gh api user -q .login >/dev/null
gh pr review 9 --repo acme/app --approve --body LGTM
OLD
chmod +x "$ROOT/old-formal-review.sh"
out=$("$ROOT/old-formal-review.sh" 2>&1); rc=$?
if [[ "$rc" -eq 0 && -s "$GH_PR_REVIEW_LOG" ]] && ! grep -q commit_id "$GH_PR_REVIEW_LOG"; then
  ok "historical: old adapter posted gh pr review without commit_id"
else
  bad "historical old adapter (rc=$rc pr=$(cat "$GH_PR_REVIEW_LOG") out=$out)"
fi
reset_logs
out=$("$FR" --pr 9 --repo acme/app --event approve --commit "$COMMIT" --body LGTM 2>&1); rc=$?
if [[ "$rc" -eq 0 && ! -s "$GH_PR_REVIEW_LOG" && "$(tr -d '\n' < "$GH_COMMIT_LOG")" == "$COMMIT" ]]; then
  ok "historical: current adapter creates review with exact commit_id"
else
  bad "historical current (rc=$rc pr=$(cat "$GH_PR_REVIEW_LOG") commit=$(cat "$GH_COMMIT_LOG" 2>/dev/null))"
fi

echo "static: second-opinion formal hook"
if grep -q 'GIBSON_FORMAL_REVIEW' "$SO" \
  && grep -q 'formal-review.sh' "$SO" \
  && grep -q -- '--commit' "$SO"; then
  ok "second-opinion formal hook present with --commit"
else
  bad "second-opinion missing formal hook/--commit"
fi
if grep -qE 'grep -qiE .*\$OUT' "$SO"; then
  bad "second-opinion still greps combined report as authority"
else
  ok "second-opinion does not grep \$OUT for verdict authority"
fi

echo "docs mention dedicated reviewer"
if grep -q 'GH_REVIEWER_TOKEN' "$SCRIPT_DIR/../../docs/13-adoption.md"; then
  ok "adoption docs mention GH_REVIEWER_TOKEN"
else
  bad "docs missing"
fi

echo
echo "formal-review.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
