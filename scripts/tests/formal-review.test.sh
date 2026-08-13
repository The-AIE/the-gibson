#!/usr/bin/env bash
# formal-review.test.sh — dedicated reviewer identity sensors (#67)
set -uo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FR="$SCRIPT_DIR/../formal-review.sh"
PASS=0; FAIL=0
ok(){ echo "  ok   — $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL — $1"; FAIL=$((FAIL+1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-formal.XXXXXX")
trap 'rm -rf -- "${ROOT:?}"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# Fake gh that records invocations and refuses if GH_TOKEN looks like builder
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_LOG:-/dev/null}"
if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
  echo "gibson-reviewer-bot"
  exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "review" ]]; then
  echo "REVIEW_OK $*"
  exit 0
fi
exit 0
GH
chmod +x "$BIN/gh"
export PATH="$BIN:/usr/bin:/bin"
export GH_LOG="$ROOT/gh.log"
: > "$GH_LOG"

echo "help / missing token"
out=$("$FR" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'L-015' && ok "help" || bad "help"
unset GH_REVIEWER_TOKEN GIBSON_REVIEWER_TOKEN GH_TOKEN
out=$("$FR" --pr 1 --repo a/b --event approve 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -qi 'GH_REVIEWER_TOKEN' && ok "missing token exits 2" \
  || bad "missing token (rc=$rc): $out"

echo "dry-run with token"
export GH_REVIEWER_TOKEN="reviewer-secret-token"
out=$("$FR" --pr 9 --repo acme/app --event approve --dry-run 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'dry-run' && ok "dry-run" || bad "dry-run (rc=$rc): $out"
# dry-run must not call gh pr review
if grep -q 'pr review' "$GH_LOG" 2>/dev/null; then bad "dry-run called gh pr review"; else ok "dry-run no API post"; fi

echo "approve posts under reviewer token"
: > "$GH_LOG"
out=$("$FR" --pr 9 --repo acme/app --event approve --body "LGTM" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "approve exit 0" || bad "approve (rc=$rc): $out"
grep -q 'pr review 9' "$GH_LOG" && ok "gh pr review invoked" || bad "log: $(cat "$GH_LOG")"
grep -q -- '--approve' "$GH_LOG" && ok "approve flag" || bad "flags: $(cat "$GH_LOG")"
echo "$out" | grep -q 'gibson-reviewer-bot' && ok "identity in log" || bad "who: $out"

echo "request-changes"
: > "$GH_LOG"
out=$("$FR" --pr 3 --repo acme/app --event request-changes --body "fix" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && grep -q -- '--request-changes' "$GH_LOG" && ok "request-changes" \
  || bad "rc (rc=$rc log=$(cat "$GH_LOG"))"

echo "static: second-opinion formal hook"
if grep -q 'GIBSON_FORMAL_REVIEW' "$SCRIPT_DIR/../second-opinion.sh" \
  && grep -q 'formal-review.sh' "$SCRIPT_DIR/../second-opinion.sh"; then
  ok "second-opinion formal hook present"
else
  bad "second-opinion missing formal hook"
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
