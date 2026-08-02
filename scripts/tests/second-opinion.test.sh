#!/usr/bin/env bash
# second-opinion.test.sh — sensors for the diff second-opinion.sh actually reviews
#
# WHY
#   The reviewer used to compute its diff as
#       git diff "$BASE...$BRANCH" || git diff "$BASE"
#   so a base or branch that did not resolve fell through to a diff of the
#   WORKING TREE against the base. The reviewer then reported on a completely
#   different (usually much smaller) change, and the caller — loop.sh, whose
#   receipt names a SHA — recorded it as a review of that SHA. A gate that
#   reviews the wrong diff is worse than no gate, because it produces evidence.
#
#   These cases pin the contract: named refs are reviewed or the script dies
#   loudly, and nothing silently substitutes the working tree.
#
# USAGE
#   scripts/tests/second-opinion.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
GIBSON=$(cd "$SCRIPT_DIR/../.." && pwd)
SECOND_OPINION="$GIBSON/scripts/second-opinion.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v git >/dev/null || { echo "second-opinion.test.sh: git is required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-second-opinion.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"
CALLS="$ROOT/calls"
REPO="$ROOT/repo"
OUT="$ROOT/out/second-opinion.md"
BRANCH="feat/1-widget"
COMMITTED_MARKER="COMMITTED-ON-THE-BRANCH"
WORKTREE_MARKER="UNCOMMITTED-IN-THE-WORKING-TREE"

mkdir -p "$BIN" "$CALLS"

# Stub reviewer: records the prompt it was handed and approves. second-opinion.sh
# feeds `codex` the rendered prompt on stdin.
cat > "$BIN/codex" <<STUB
#!/usr/bin/env bash
cat > "$CALLS/prompt.txt"
echo call >> "$CALLS/codex.count"
echo "VERDICT: approve"
STUB
chmod +x "$BIN/codex"
PATH="$BIN:$PATH"
export PATH

GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

setup_repo() {
  rm -rf "$REPO" "$ROOT/out"
  mkdir -p "$REPO"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  echo base > "$REPO/README.md"
  $GIT -C "$REPO" add README.md
  $GIT -C "$REPO" commit -q -m "base"
  $GIT -C "$REPO" checkout -q -b "$BRANCH"
  echo "$COMMITTED_MARKER" >> "$REPO/README.md"
  $GIT -C "$REPO" commit -q -am "work"
  $GIT -C "$REPO" checkout -q main
  # An uncommitted edit on main: this is what the old fallback would have
  # reviewed whenever the requested pair of refs failed to resolve.
  echo "$WORKTREE_MARKER" >> "$REPO/README.md"
  : > "$CALLS/codex.count"
  rm -f "$CALLS/prompt.txt"
}

reviewer_ran() { [[ -s "$CALLS/codex.count" ]]; }

run_so() { # run_so <base> <branch>
  "$SECOND_OPINION" --repo "$REPO" --reviewers codex --author grok \
    --base "$1" --branch "$2" --out "$OUT" >"$ROOT/stdout.txt" 2>"$ROOT/stderr.txt"
}

echo "a resolvable base...branch pair is reviewed as committed history"
setup_repo
if run_so main "$BRANCH"; then ok "the review completed"
else bad "a valid base...branch pair failed: $(tail -n 3 "$ROOT/stderr.txt")"; fi
if reviewer_ran; then ok "the reviewer was dispatched"
else bad "the reviewer was never dispatched"; fi
if grep -qF "$COMMITTED_MARKER" "$CALLS/prompt.txt" 2>/dev/null; then
  ok "the reviewer saw the branch's committed change"
else
  bad "the reviewer never saw the committed change"
fi
if grep -qF "$WORKTREE_MARKER" "$CALLS/prompt.txt" 2>/dev/null; then
  bad "the reviewer was shown uncommitted working-tree changes"
else
  ok "uncommitted working-tree changes stayed out of the review"
fi

echo "an unresolvable branch fails loudly instead of reviewing the working tree"
setup_repo
if run_so main 0123456789abcdef0123456789abcdef01234567; then
  bad "an unresolvable branch must not exit 0"
else
  ok "an unresolvable branch is a hard error"
fi
if reviewer_ran; then
  bad "a reviewer was spent on a diff nobody asked for"
else
  ok "no reviewer was dispatched for the unresolvable branch"
fi
if grep -q "does not resolve to a commit" "$ROOT/stderr.txt"; then
  ok "the failure names the unresolvable ref"
else
  bad "the failure did not explain which ref could not be resolved"
fi
if [[ -s "$OUT" ]]; then
  bad "a report was written for a review that never happened"
else
  ok "no report artifact was left behind"
fi

echo "an unresolvable base fails loudly too"
setup_repo
if run_so no-such-base "$BRANCH"; then
  bad "an unresolvable base must not exit 0"
else
  ok "an unresolvable base is a hard error"
fi
if reviewer_ran; then bad "a reviewer was spent on an unresolvable base"
else ok "no reviewer was dispatched for the unresolvable base"; fi

echo "an empty diff between two real refs is still refused"
setup_repo
if run_so main main; then
  bad "reviewing a ref against itself must not exit 0"
else
  ok "an empty diff is refused rather than sent to a reviewer"
fi
if reviewer_ran; then bad "a reviewer was spent on an empty diff"
else ok "no reviewer was dispatched for an empty diff"; fi

echo
echo "second-opinion.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
