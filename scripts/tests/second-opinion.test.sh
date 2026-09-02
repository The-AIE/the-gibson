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
#   Issue #290 additionally pins mixed-verdict fail-closed formal posting:
#   authority comes from isolated verdict_file slots, never from grepping the
#   combined report; the reviewed SHA is frozen and passed as commit_id; raw
#   stderr never becomes public.
#
# USAGE
#   scripts/tests/second-opinion.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GIBSON=$(cd "$SCRIPT_DIR/../.." && pwd)
SECOND_OPINION="$GIBSON/scripts/second-opinion.sh"
FORMAL_REVIEW="$GIBSON/scripts/formal-review.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v git >/dev/null || { echo "second-opinion.test.sh: git is required"; exit 1; }

# A developer shell must not leak formal-review posting into these fixtures.
unset GIBSON_FORMAL_REVIEW GH_REVIEWER_TOKEN GIBSON_REVIEWER_TOKEN GITHUB_REPOSITORY || true

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-second-opinion.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"
CALLS="$ROOT/calls"
REPO="$ROOT/repo"
OUT="$ROOT/out/second-opinion.md"
BRANCH="feat/1-widget"
COMMITTED_MARKER="COMMITTED-ON-THE-BRANCH"
WORKTREE_MARKER="UNCOMMITTED-IN-THE-WORKING-TREE"
GH_LOG="$ROOT/gh.log"
STDERR_MARKER="STDERR_MARKER_DO_NOT_PUBLISH"

mkdir -p "$BIN" "$CALLS"
: > "$GH_LOG"

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

# --- #69 solo-platform: same-vendor alt-model may review ---
echo "#69 · solo-platform allows same-vendor:model review"
setup_repo
# stub claude as author-matching reviewer
cat > "$BIN/claude" <<STUB
#!/usr/bin/env bash
# record args + stdin
echo "\$@" > "$CALLS/claude.args"
cat > "$CALLS/claude.prompt"
echo call >> "$CALLS/claude.count"
echo "VERDICT: APPROVE"
STUB
chmod +x "$BIN/claude"
: > "$CALLS/claude.count"
# author=claude, reviewer=claude:sonnet with --solo-platform
if "$SECOND_OPINION" --repo "$REPO" --reviewers claude:sonnet --author claude \
    --solo-platform --base main --branch "$BRANCH" --out "$OUT" >/dev/null 2>"$ROOT/so69.err"; then
  if [[ -s "$CALLS/claude.count" ]]; then
    ok "solo-platform same-vendor:model dispatched"
  else
    bad "solo-platform did not dispatch claude"
  fi
  if grep -q 'solo-platform' "$ROOT/so69.err" || [[ -s "$OUT" ]]; then
    ok "solo-platform produced a report"
  else
    bad "solo-platform empty report"
  fi
else
  bad "solo-platform same-vendor review failed: $(cat "$ROOT/so69.err")"
fi

# without --solo-platform, same vendor is skipped → no reviewer ran → die
setup_repo
cat > "$BIN/claude" <<STUB
#!/usr/bin/env bash
echo call >> "$CALLS/claude.count"
echo "VERDICT: APPROVE"
STUB
chmod +x "$BIN/claude"
: > "$CALLS/claude.count"
if "$SECOND_OPINION" --repo "$REPO" --reviewers claude --author claude \
    --base main --branch "$BRANCH" --out "$OUT" >/dev/null 2>"$ROOT/so69b.err"; then
  bad "same-vendor without solo-platform should die"
else
  ok "same-vendor without solo-platform fails closed"
fi

# --- #290 mixed-verdict fail-closed formal review ---
echo "#290 · mixed verdicts, SHA freeze, stderr isolation"

MATRIX=0
MATRIX_EXPECT=24
begin_matrix() {
  MATRIX=$((MATRIX + 1))
  echo "#290 [$MATRIX] $1"
}

REAL_GIT=$(command -v git)
ln -sf "$REAL_GIT" "$BIN/git"
PATH="$BIN:/usr/bin:/bin"
export PATH
export GH_LOG

install_gh_stub() {
  cat > "$BIN/gh" <<GH
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
prev=""
is_review=0
is_pr_review=0
commit_id=""
event=""
for a in "\$@"; do
  if [[ "\$prev" == "pr" && "\$a" == "review" ]]; then
    is_pr_review=1
  fi
  if [[ "\$prev" == "-F" || "\$prev" == "--field" ]]; then
    case "\$a" in
      commit_id=*) commit_id="\${a#commit_id=}" ;;
      event=*) event="\${a#event=}" ;;
      body=@*)
        _bf="\${a#body=@}"
        if [[ -n "\$_bf" && -f "\$_bf" ]]; then
          cat "\$_bf" > "$CALLS/formal.body"
        else
          printf '%s' "@\${_bf}" > "$CALLS/formal.body"
        fi
        ;;
      body=*)
        printf '%s' "\${a#body=}" > "$CALLS/formal.body"
        ;;
    esac
  elif [[ "\$prev" == "-f" || "\$prev" == "--raw-field" ]]; then
    case "\$a" in
      commit_id=*) commit_id="\${a#commit_id=}" ;;
      event=*) event="\${a#event=}" ;;
      body=*)
        printf '%s' "\${a#body=}" > "$CALLS/formal.body"
        ;;
    esac
  else
    case "\$a" in
      */reviews) is_review=1 ;;
    esac
  fi
  prev="\$a"
done
if [[ "\$is_pr_review" -eq 1 ]]; then
  echo "OLD_PR_REVIEW \$*" >> "$CALLS/pr-review"
  echo "REVIEW_OK"
  exit 0
fi
if [[ "\${1:-}" == "api" && "\${2:-}" == "user" ]]; then
  echo "gibson-reviewer-bot"
  exit 0
fi
if [[ "\$is_review" -eq 1 ]]; then
  if [[ "\${GH_FAIL_REVIEW:-0}" == "1" ]]; then
    echo "simulated adapter failure" >&2
    exit 1
  fi
  echo call >> "$CALLS/formal.count"
  printf '%s\n' "\$commit_id" > "$CALLS/formal.commit"
  printf '%s\n' "\$event" > "$CALLS/formal.event"
  echo "REVIEW_API_OK"
  exit 0
fi
echo "unexpected gh invocation: \$*" >&2
exit 3
GH
  chmod +x "$BIN/gh"
}

write_stub() { # name stdout stderr rc
  local name="$1"
  printf '%s' "$2" > "$CALLS/$name.stdout"
  printf '%s' "$3" > "$CALLS/$name.stderr"
  printf '%s' "$4" > "$CALLS/$name.rc"
  cat > "$BIN/$name" <<STUB
#!/usr/bin/env bash
echo call >> "$CALLS/$name.count"
cat > "$CALLS/$name.prompt"
cat "$CALLS/$name.stdout"
cat "$CALLS/$name.stderr" >&2
exit \$(cat "$CALLS/$name.rc")
STUB
  chmod +x "$BIN/$name"
}

reset_formal() {
  : > "$GH_LOG"
  rm -f "$CALLS/formal.count" "$CALLS/formal.commit" "$CALLS/formal.event" \
    "$CALLS/formal.body" "$CALLS/pr-review" \
    "$CALLS/codex.count" "$CALLS/claude.count" "$CALLS/grok.count" \
    "$CALLS/codex.prompt" "$CALLS/claude.prompt"
  rm -f "$BIN/codex" "$BIN/claude" "$BIN/grok" "$BIN/notatool"
  unset GH_FAIL_REVIEW || true
}

formal_count() {
  if [[ -s "$CALLS/formal.count" ]]; then
    wc -l < "$CALLS/formal.count" | tr -d ' '
  else
    echo 0
  fi
}

formal_event() {
  if [[ -s "$CALLS/formal.event" ]]; then
    tr -d '\n' < "$CALLS/formal.event"
  fi
}

formal_commit() {
  if [[ -s "$CALLS/formal.commit" ]]; then
    tr -d '\n' < "$CALLS/formal.commit"
  fi
}

# Pre-#290 authority: grep the combined report, APPROVE before REQUEST_CHANGES.
old_event_from_report() {
  local report="$1"
  local event=""
  if grep -qiE 'VERDICT:[[:space:]]*approve([^A-Za-z]|$)' "$report" 2>/dev/null; then
    event=approve
  elif grep -qiE 'VERDICT:[[:space:]]*(REQUEST_CHANGES|changes-requested|request.changes)' "$report" 2>/dev/null; then
    event=request-changes
  fi
  printf '%s' "$event"
}

run_formal_so() { # reviewers
  GIBSON_FORMAL_REVIEW=1 GH_REVIEWER_TOKEN=test-reviewer-token \
    "$SECOND_OPINION" --repo "$REPO" --reviewers "$1" --author grok \
    --base main --branch "$BRANCH" --out "$OUT" \
    --pr 9 --github-repo acme/app \
    >"$ROOT/stdout.txt" 2>"$ROOT/stderr.txt"
}

expect_no_pr_review() {
  if [[ -e "$CALLS/pr-review" ]]; then
    bad "$1: used old gh pr review path"
  else
    ok "$1: did not use gh pr review"
  fi
}

install_gh_stub

# 1. all-approve
begin_matrix "all-approve"
reset_formal
setup_repo
SHA=$(git -C "$REPO" rev-parse "$BRANCH" | tr 'A-F' 'a-f')
write_stub codex $'VERDICT: APPROVE\nlooks good\n' "" 0
write_stub claude $'VERDICT: APPROVE\nalso good\n' "" 0
if run_formal_so "codex,claude"; then ok "all-approve: exit 0"
else bad "all-approve: failed: $(tail -n 5 "$ROOT/stderr.txt")"; fi
if [[ "$(formal_count)" -eq 1 && "$(formal_event)" == "APPROVE" ]]; then
  ok "all-approve: exactly one formal APPROVE"
else
  bad "all-approve: count=$(formal_count) event=$(formal_event)"
fi
if [[ "$(formal_commit)" == "$SHA" ]]; then
  ok "all-approve: commit_id is the frozen SHA"
else
  bad "all-approve: commit=$(formal_commit) expected $SHA"
fi
expect_no_pr_review "all-approve"

# 2. mixed: approve then request-changes
begin_matrix "mixed-approve-then-request-changes"
reset_formal
setup_repo
SHA=$(git -C "$REPO" rev-parse "$BRANCH" | tr 'A-F' 'a-f')
write_stub codex $'VERDICT: APPROVE\n' "" 0
write_stub claude $'VERDICT: REQUEST_CHANGES\nfix it\n' "" 0
run_formal_so "codex,claude"
rc=$?
old=$(old_event_from_report "$OUT")
if [[ "$rc" -eq 0 ]]; then ok "mixed A: report generation succeeded"
else bad "mixed A: rc=$rc $(tail -n 3 "$ROOT/stderr.txt")"; fi
if [[ "$old" == "approve" ]]; then
  ok "mixed A: historical approve-first oracle still sees APPROVE first"
else
  bad "mixed A: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 1 && "$(formal_event)" == "REQUEST_CHANGES" ]]; then
  ok "mixed A: one formal request-changes"
else
  bad "mixed A: count=$(formal_count) event=$(formal_event)"
fi
if grep -q 'slot:codex state:approve' "$ROOT/stderr.txt" \
  && grep -q 'slot:claude state:request-changes' "$ROOT/stderr.txt"; then
  ok "mixed A: isolated slot states named"
else
  bad "mixed A: slot states missing from diagnostics"
fi

# 3. mixed: request-changes then approve
begin_matrix "mixed-request-changes-then-approve"
reset_formal
setup_repo
write_stub claude $'VERDICT: REQUEST_CHANGES\n' "" 0
write_stub codex $'VERDICT: APPROVE\n' "" 0
run_formal_so "claude,codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "mixed B: old approve-first oracle still approves"
else
  bad "mixed B: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 1 && "$(formal_event)" == "REQUEST_CHANGES" ]]; then
  ok "mixed B: one formal request-changes regardless of order"
else
  bad "mixed B: count=$(formal_count) event=$(formal_event)"
fi

# 4. request-changes plus failure
begin_matrix "request-changes-plus-failure"
reset_formal
setup_repo
write_stub claude $'VERDICT: REQUEST_CHANGES\n' "" 0
write_stub codex $'nope\n' "$STDERR_MARKER\nquota\n" 42
run_formal_so "claude,codex"
if [[ "$(formal_count)" -eq 1 && "$(formal_event)" == "REQUEST_CHANGES" ]]; then
  ok "RC+failure: valid request-changes still posts once"
else
  bad "RC+failure: count=$(formal_count) event=$(formal_event)"
fi
if grep -q 'slot:codex state:nonzero-exit' "$ROOT/stderr.txt"; then
  ok "RC+failure: failure slot is nonzero-exit"
else
  bad "RC+failure: missing nonzero-exit state"
fi
if grep -qF "$STDERR_MARKER" "$OUT" "$ROOT/stdout.txt" "$CALLS/formal.body" 2>/dev/null; then
  bad "RC+failure: raw stderr leaked into public surfaces"
else
  ok "RC+failure: raw stderr stayed out of report/stdout/formal body"
fi

# 5. missing CLI slot
begin_matrix "missing-cli slot"
reset_formal
setup_repo
write_stub claude $'VERDICT: APPROVE\n' "" 0
# no codex binary in BIN; isolated PATH cannot find a real one
run_formal_so "codex,claude"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "missing-cli: old any-approve oracle would approve"
else
  bad "missing-cli: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]]; then
  ok "missing-cli: no formal call"
else
  bad "missing-cli: posted $(formal_event)"
fi
if grep -q 'slot:codex state:missing-cli' "$ROOT/stderr.txt" \
  && grep -q 'fail-closed: missing-cli' "$OUT"; then
  ok "missing-cli: named fail-closed slot"
else
  bad "missing-cli: state not named"
fi

# 6. unknown reviewer slot
begin_matrix "unknown-reviewer slot"
reset_formal
setup_repo
write_stub codex $'VERDICT: APPROVE\n' "" 0
run_formal_so "codex,notatool"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "unknown: old any-approve oracle would approve"
else
  bad "unknown: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]]; then
  ok "unknown: no formal call"
else
  bad "unknown: posted $(formal_event)"
fi
if grep -q 'slot:notatool state:unknown-reviewer' "$ROOT/stderr.txt"; then
  ok "unknown: named unknown-reviewer"
else
  bad "unknown: state not named"
fi

# 7. same-author slot
begin_matrix "same-author slot"
reset_formal
setup_repo
write_stub claude $'VERDICT: APPROVE\n' "" 0
write_stub codex $'VERDICT: APPROVE\n' "" 0
GIBSON_FORMAL_REVIEW=1 GH_REVIEWER_TOKEN=test-reviewer-token \
  "$SECOND_OPINION" --repo "$REPO" --reviewers "claude,codex" --author claude \
  --base main --branch "$BRANCH" --out "$OUT" \
  --pr 9 --github-repo acme/app \
  >"$ROOT/stdout.txt" 2>"$ROOT/stderr.txt"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "same-author: old any-approve oracle would approve"
else
  bad "same-author: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]]; then
  ok "same-author: no formal call"
else
  bad "same-author: posted $(formal_event)"
fi
if grep -q 'slot:claude state:same-author' "$ROOT/stderr.txt"; then
  ok "same-author: named same-author"
else
  bad "same-author: state not named"
fi
if [[ -s "$CALLS/claude.count" ]]; then
  bad "same-author: claude CLI was invoked"
else
  ok "same-author: author CLI was not dispatched"
fi

# 8. failed / nonzero slot (paired with approve — ignored-failure)
begin_matrix "failed/nonzero slot"
reset_formal
setup_repo
write_stub claude $'VERDICT: APPROVE\n' "" 0
write_stub codex $'VERDICT: APPROVE\n' "$STDERR_MARKER\nbang\n" 42
run_formal_so "claude,codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "failed-slot: old ignored-failure oracle would approve"
else
  bad "failed-slot: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]]; then
  ok "failed-slot: no formal call"
else
  bad "failed-slot: posted $(formal_event)"
fi
if grep -q 'slot:codex state:nonzero-exit' "$ROOT/stderr.txt"; then
  ok "failed-slot: named nonzero-exit"
else
  bad "failed-slot: state not named"
fi

# 9. no-verdict slot
begin_matrix "no-verdict slot"
reset_formal
setup_repo
write_stub codex $'looks fine, ship it\n' "" 0
write_stub claude $'VERDICT: APPROVE\n' "" 0
run_formal_so "codex,claude"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "no-verdict: old any-approve oracle would approve"
else
  bad "no-verdict: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]]; then
  ok "no-verdict: no formal call"
else
  bad "no-verdict: posted $(formal_event)"
fi
if grep -q 'slot:codex state:no-verdict' "$ROOT/stderr.txt"; then
  ok "no-verdict: named no-verdict"
else
  bad "no-verdict: state not named"
fi
reset_formal
setup_repo
write_stub codex "" "" 0
write_stub claude $'VERDICT: APPROVE\n' "" 0
run_formal_so "codex,claude"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" && "$(formal_count)" -eq 0 ]] \
  && grep -q 'slot:codex state:empty' "$ROOT/stderr.txt"; then
  ok "empty: named empty, no formal call (old any-approve would approve)"
else
  bad "empty: old=$old count=$(formal_count) $(grep slot: "$ROOT/stderr.txt")"
fi

# 10. exact aliases
begin_matrix "exact aliases"
reset_formal
setup_repo
SHA=$(git -C "$REPO" rev-parse "$BRANCH" | tr 'A-F' 'a-f')
write_stub codex $'VERDICT: approve\n' "" 0
run_formal_so "codex"
if [[ "$(formal_count)" -eq 1 && "$(formal_event)" == "APPROVE" && "$(formal_commit)" == "$SHA" ]]; then
  ok "alias: VERDICT: approve maps to APPROVE"
else
  bad "alias approve: count=$(formal_count) event=$(formal_event) commit=$(formal_commit)"
fi
reset_formal
setup_repo
write_stub claude $'1. VERDICT: changes-requested\n' "" 0
run_formal_so "claude"
if [[ "$(formal_count)" -eq 1 && "$(formal_event)" == "REQUEST_CHANGES" ]]; then
  ok "alias: list-marker VERDICT: changes-requested maps to REQUEST_CHANGES"
else
  bad "alias changes-requested: count=$(formal_count) event=$(formal_event)"
fi
# PASS is not an alias
reset_formal
setup_repo
write_stub codex $'VERDICT: PASS\n' "" 0
run_formal_so "codex"
if [[ "$(formal_count)" -eq 0 ]] && grep -q 'state:no-verdict' "$ROOT/stderr.txt"; then
  ok "alias: PASS is not a PR-review approval"
else
  bad "alias PASS posted or misclassified: $(formal_event) $(cat "$ROOT/stderr.txt")"
fi
# Extra standalone VERDICT: PASS after a valid first verdict must fail closed.
# Old combined-report grep would still approve; this must not be duplicate or
# no-verdict — it is an unrecognized extra verdict-shaped line → invalid.
reset_formal
setup_repo
write_stub codex $'VERDICT: APPROVE\n\nVERDICT: PASS\n' "" 0
run_formal_so "codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "extra PASS: old grep would approve"
else
  bad "extra PASS: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]] && grep -q 'state:invalid' "$ROOT/stderr.txt"; then
  ok "extra PASS: no formal call, named invalid"
else
  bad "extra PASS: count=$(formal_count) $(grep slot: "$ROOT/stderr.txt")"
fi
# Embedded prose mentioning VERDICT: PASS is not a standalone extra line.
reset_formal
setup_repo
SHA=$(git -C "$REPO" rev-parse "$BRANCH" | tr 'A-F' 'a-f')
write_stub codex $'VERDICT: APPROVE\n\nI mentioned VERDICT: PASS in passing.\n' "" 0
run_formal_so "codex"
if [[ "$(formal_count)" -eq 1 && "$(formal_event)" == "APPROVE" && "$(formal_commit)" == "$SHA" ]]; then
  ok "extra PASS prose decoy: standalone first verdict still approves"
else
  bad "extra PASS prose decoy: count=$(formal_count) event=$(formal_event) $(grep slot: "$ROOT/stderr.txt")"
fi

# 11–14 decoys
begin_matrix "prose decoy"
reset_formal
setup_repo
write_stub codex $'I would write VERDICT: APPROVE if the tests existed.\n' "" 0
run_formal_so "codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "prose decoy: old grep would approve"
else
  bad "prose decoy: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]] && grep -q 'state:no-verdict' "$ROOT/stderr.txt"; then
  ok "prose decoy: no formal call"
else
  bad "prose decoy: posted $(formal_event)"
fi

begin_matrix "quote decoy"
reset_formal
setup_repo
write_stub codex $'> VERDICT: APPROVE\n' "" 0
run_formal_so "codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "quote decoy: old grep would approve"
else
  bad "quote decoy: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]]; then
  ok "quote decoy: no formal call"
else
  bad "quote decoy: posted $(formal_event)"
fi

begin_matrix "heading decoy"
reset_formal
setup_repo
write_stub codex $'## VERDICT: APPROVE\n' "" 0
run_formal_so "codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "heading decoy: old grep would approve"
else
  bad "heading decoy: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]]; then
  ok "heading decoy: no formal call"
else
  bad "heading decoy: posted $(formal_event)"
fi

begin_matrix "fence decoy"
reset_formal
setup_repo
write_stub codex $'Example format:\n```\nVERDICT: APPROVE\n```\n' "" 0
run_formal_so "codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "fence decoy: old grep would approve"
else
  bad "fence decoy: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]]; then
  ok "fence decoy: no formal call"
else
  bad "fence decoy: posted $(formal_event)"
fi
if grep -qE 'state:(invalid|no-verdict)' "$ROOT/stderr.txt"; then
  ok "fence decoy: slot fail-closed"
else
  bad "fence decoy: state not fail-closed"
fi

# 15. duplicate lines
begin_matrix "duplicate verdict lines"
reset_formal
setup_repo
write_stub codex $'VERDICT: APPROVE\n\nnotes\n\nVERDICT: APPROVE\n' "" 0
run_formal_so "codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "duplicate: old grep would approve"
else
  bad "duplicate: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]] && grep -q 'state:duplicate' "$ROOT/stderr.txt"; then
  ok "duplicate: no formal call, named duplicate"
else
  bad "duplicate: count=$(formal_count) $(grep slot: "$ROOT/stderr.txt")"
fi

# 16. contradictory lines
begin_matrix "contradictory verdict lines"
reset_formal
setup_repo
write_stub codex $'VERDICT: APPROVE\n\nVERDICT: REQUEST_CHANGES\n' "" 0
run_formal_so "codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" ]]; then
  ok "contradictory: old approve-first oracle would approve"
else
  bad "contradictory: old oracle was '$old' (fixture is vacuous)"
fi
if [[ "$(formal_count)" -eq 0 ]] && grep -q 'state:contradictory' "$ROOT/stderr.txt"; then
  ok "contradictory: no formal call, named contradictory"
else
  bad "contradictory: count=$(formal_count) $(grep slot: "$ROOT/stderr.txt")"
fi

# 17. exact commit_id
begin_matrix "exact commit_id"
reset_formal
setup_repo
SHA=$(git -C "$REPO" rev-parse "$BRANCH" | tr 'A-F' 'a-f')
write_stub codex $'VERDICT: APPROVE\n' "" 0
run_formal_so "codex"
if grep -q "Reviewed commit: \`$SHA\`" "$OUT" \
  && grep -q "$SHA" "$CALLS/codex.prompt" \
  && [[ "$(formal_commit)" == "$SHA" ]] \
  && [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  ok "commit_id: frozen 40-hex SHA is in prompt, report, and API"
else
  bad "commit_id: sha=$SHA commit=$(formal_commit) report=$(grep 'Reviewed commit' "$OUT")"
fi
if grep -q "$WORKTREE_MARKER" "$CALLS/codex.prompt" 2>/dev/null; then
  bad "commit_id: working tree leaked into the review"
else
  ok "commit_id: frozen SHA is the branch commit, not the dirty tree"
fi

# 18. adapter failure
begin_matrix "adapter failure"
reset_formal
setup_repo
write_stub codex $'VERDICT: APPROVE\n' "" 0
export GH_FAIL_REVIEW=1
run_formal_so "codex"
rc=$?
unset GH_FAIL_REVIEW
if [[ "$rc" -eq 0 && -s "$OUT" ]]; then
  ok "adapter failure: report generation still succeeded"
else
  bad "adapter failure: rc=$rc out=$(wc -c < "$OUT" 2>/dev/null)"
fi
if grep -q 'no formal event was created' "$ROOT/stderr.txt"; then
  ok "adapter failure: recorded that no formal event was created"
else
  bad "adapter failure: missing no-event message"
fi
if [[ "$(formal_count)" -eq 0 ]]; then
  ok "adapter failure: no successful review create"
else
  bad "adapter failure: count=$(formal_count)"
fi

# 19. stderr non-publication
begin_matrix "stderr non-publication"
reset_formal
setup_repo
write_stub claude $'VERDICT: APPROVE\n' "" 0
write_stub codex $'' "$STDERR_MARKER\nauth exploded\n" 42
run_formal_so "claude,codex"
log="${OUT%.md}.log"
if grep -qF "$STDERR_MARKER" "$log" 2>/dev/null; then
  ok "stderr: marker retained only in sidecar log"
else
  bad "stderr: sidecar log missing marker"
fi
leaked=0
grep -qF "$STDERR_MARKER" "$OUT" 2>/dev/null && leaked=1
grep -qF "$STDERR_MARKER" "$ROOT/stdout.txt" 2>/dev/null && leaked=1
grep -qF "$STDERR_MARKER" "$ROOT/stderr.txt" 2>/dev/null && leaked=1
[[ -f "$CALLS/formal.body" ]] && grep -qF "$STDERR_MARKER" "$CALLS/formal.body" && leaked=1
if [[ "$leaked" -eq 0 ]]; then
  ok "stderr: marker absent from report, stdout, diagnostics, formal body"
else
  bad "stderr: marker leaked to a public surface"
fi
if grep -q 'fail-closed: nonzero-exit' "$OUT" && ! grep -q 'Last lines of stderr' "$OUT"; then
  ok "stderr: one sanitized diagnostic, no raw stderr dump"
else
  bad "stderr: diagnostic missing or raw dump present"
fi

# 20. exact call arguments
begin_matrix "exact call arguments"
reset_formal
setup_repo
SHA=$(git -C "$REPO" rev-parse "$BRANCH" | tr 'A-F' 'a-f')
write_stub claude $'VERDICT: REQUEST_CHANGES\n' "" 0
write_stub codex $'VERDICT: APPROVE\n' "" 0
run_formal_so "claude,codex"
if grep -q 'formal-review.sh' "$SECOND_OPINION" \
  && grep -q -- '--commit' "$SECOND_OPINION" \
  && grep -q 'REVIEWED_SHA' "$SECOND_OPINION" \
  && grep -q -- '--body-file' "$SECOND_OPINION"; then
  ok "argv: production hook passes --commit and --body-file"
else
  bad "argv: production hook missing --commit/--body-file"
fi
if grep -qE "grep -qiE .*approve.*OUT" "$SECOND_OPINION"; then
  bad "argv: combined report is still grepped as authority"
else
  ok "argv: combined report is not grepped as authority"
fi
if [[ "$(formal_event)" == "REQUEST_CHANGES" && "$(formal_commit)" == "$SHA" ]]; then
  ok "argv: API received event=REQUEST_CHANGES commit_id=$SHA"
else
  bad "argv: event=$(formal_event) commit=$(formal_commit)"
fi
if grep -q 'test-reviewer-token' "$GH_LOG" 2>/dev/null || grep -q 'GH_TOKEN=' "$GH_LOG" 2>/dev/null; then
  bad "argv: token appeared in gh argv log"
else
  ok "argv: reviewer token stayed out of gh argv"
fi
if grep -qF "$SHA" "$CALLS/formal.body" && ! grep -qF "$STDERR_MARKER" "$CALLS/formal.body" 2>/dev/null; then
  ok "argv: formal body is the sanitized report"
else
  bad "argv: formal body missing SHA or unexpected (body=$(head -c 80 "$CALLS/formal.body" 2>/dev/null))"
fi
# Red seam: -f/--raw-field must not load @file. Direct fake-gh call with the
# historical raw-field form; file bytes must not appear in the recorded body.
reset_formal
printf '%s' "SEAM_SHOULD_NOT_LOAD_${SHA}" > "$ROOT/seam-payload.txt"
"$BIN/gh" api --method POST "repos/acme/app/pulls/9/reviews" \
  -f commit_id="$SHA" \
  -f event="APPROVE" \
  -f "body=@${ROOT}/seam-payload.txt" >/dev/null
seam_body=$(cat "$CALLS/formal.body" 2>/dev/null || true)
if [[ "$seam_body" == "SEAM_SHOULD_NOT_LOAD_${SHA}" ]]; then
  bad "argv: fake-gh loaded @file for -f/--raw-field (seam vacuous)"
elif [[ "$seam_body" == "@${ROOT}/seam-payload.txt" ]]; then
  ok "argv: fake-gh treats raw-field @file as literal"
else
  bad "argv: raw-field body unexpected: $seam_body"
fi
# Confirm typed-field still loads bytes on this same fake.
"$BIN/gh" api --method POST "repos/acme/app/pulls/9/reviews" \
  -f commit_id="$SHA" \
  -f event="APPROVE" \
  -F "body=@${ROOT}/seam-payload.txt" >/dev/null
typed_body=$(cat "$CALLS/formal.body" 2>/dev/null || true)
if [[ "$typed_body" == "SEAM_SHOULD_NOT_LOAD_${SHA}" ]]; then
  ok "argv: fake-gh typed-field loads exact @file bytes"
else
  bad "argv: typed-field body unexpected: $typed_body"
fi

# 21. old approve-first (behavioral mutation of a throwaway copy)
begin_matrix "old approve-first behavior"
reset_formal
setup_repo
SHA=$(git -C "$REPO" rev-parse "$BRANCH" | tr 'A-F' 'a-f')
write_stub codex $'VERDICT: APPROVE\n' "" 0
write_stub claude $'VERDICT: REQUEST_CHANGES\n' "" 0
OLDGIB="$ROOT/oldgibson"
mkdir -p "$OLDGIB/scripts" "$OLDGIB/playbooks"
cp "$GIBSON/playbooks/reviewer.md" "$OLDGIB/playbooks/reviewer.md"
cp "$FORMAL_REVIEW" "$OLDGIB/scripts/formal-review.sh"
chmod +x "$OLDGIB/scripts/formal-review.sh"
: > "$OLDGIB/scripts/second-opinion.sh"
state=keep
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == *"# --- #290 slot-authority begin ---" ]]; then
    cat >> "$OLDGIB/scripts/second-opinion.sh" <<'OLD'
  # --- #290 slot-authority begin ---
  _fr_event=""
  if grep -qiE 'VERDICT:[[:space:]]*approve([^A-Za-z]|$)' "$OUT" 2>/dev/null; then
    _fr_event=approve
  elif grep -qiE 'VERDICT:[[:space:]]*(REQUEST_CHANGES|changes-requested|request.changes)' "$OUT" 2>/dev/null; then
    _fr_event=request-changes
  fi
  # --- #290 slot-authority end ---
OLD
    state=skip
    continue
  fi
  if [[ "$line" == *"# --- #290 slot-authority end ---" ]]; then
    state=keep
    continue
  fi
  if [[ "$state" == keep ]]; then
    printf '%s\n' "$line" >> "$OLDGIB/scripts/second-opinion.sh"
  fi
done < "$SECOND_OPINION"
chmod +x "$OLDGIB/scripts/second-opinion.sh"
if grep -q 'grep -qiE' "$OLDGIB/scripts/second-opinion.sh"; then
  ok "approve-first mutation: old grep authority reinserted"
else
  bad "approve-first mutation: splice failed (vacuous)"
fi
reset_formal
write_stub codex $'VERDICT: APPROVE\n' "" 0
write_stub claude $'VERDICT: REQUEST_CHANGES\n' "" 0
setup_repo
GIBSON_FORMAL_REVIEW=1 GH_REVIEWER_TOKEN=test-reviewer-token \
  "$OLDGIB/scripts/second-opinion.sh" --repo "$REPO" --reviewers "codex,claude" --author grok \
  --base main --branch "$BRANCH" --out "$OUT" \
  --pr 9 --github-repo acme/app \
  >"$ROOT/stdout-old.txt" 2>"$ROOT/stderr-old.txt"
if [[ "$(formal_event)" == "APPROVE" ]]; then
  ok "approve-first mutation: old copy posts APPROVE on mixed verdicts"
else
  bad "approve-first mutation: old copy event=$(formal_event) (expected APPROVE)"
fi
# Green path on the real script already covered by mixed A; require the
# production file still has the delimited authority block.
if grep -q '# --- #290 slot-authority begin ---' "$SECOND_OPINION" \
  && grep -q '# --- #290 slot-authority end ---' "$SECOND_OPINION"; then
  ok "approve-first: production authority block remains delimited"
else
  bad "approve-first: production markers missing"
fi

# 22. old any-approve
begin_matrix "old any-approve behavior"
reset_formal
setup_repo
write_stub claude $'VERDICT: APPROVE\n' "" 0
write_stub codex $'Not a verdict, just prose.\n' "" 0
run_formal_so "claude,codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" && "$(formal_count)" -eq 0 ]]; then
  ok "any-approve: old grep would approve; new makes no formal call"
else
  bad "any-approve: old=$old count=$(formal_count)"
fi

# 23. old ignored-failure
begin_matrix "old ignored-failure behavior"
reset_formal
setup_repo
write_stub claude $'VERDICT: APPROVE\n' "" 0
write_stub codex $'VERDICT: APPROVE\n' "$STDERR_MARKER\n" 42
run_formal_so "claude,codex"
old=$(old_event_from_report "$OUT")
if [[ "$old" == "approve" && "$(formal_count)" -eq 0 ]]; then
  ok "ignored-failure: old grep would approve; new makes no formal call"
else
  bad "ignored-failure: old=$old count=$(formal_count)"
fi

# 24. old no-commit
begin_matrix "old no-commit behavior"
if grep -E '^[[:space:]]*gh pr review' "$FORMAL_REVIEW"; then
  bad "no-commit: formal-review.sh still invokes gh pr review"
else
  ok "no-commit: gh pr review invocation path is gone"
fi
if grep -q 'commit_id' "$FORMAL_REVIEW" && grep -q -- '--commit' "$FORMAL_REVIEW"; then
  ok "no-commit: adapter requires --commit and sends commit_id"
else
  bad "no-commit: adapter missing commit_id/--commit"
fi
if grep -q -- '--commit "$REVIEWED_SHA"' "$SECOND_OPINION" \
  || grep -q -- '--commit "$REVIEWED_SHA"' "$SECOND_OPINION"; then
  ok "no-commit: second-opinion passes frozen SHA"
else
  # allow split across lines
  if awk 'BEGIN{s=0} /formal-review.sh/{s=1} s && /--commit/{found=1} END{exit found?0:1}' "$SECOND_OPINION"; then
    ok "no-commit: second-opinion passes --commit to the adapter"
  else
    bad "no-commit: second-opinion does not pass --commit"
  fi
fi
# Behavioral: omitting --commit must not create a review.
reset_formal
out=$("$FORMAL_REVIEW" --pr 9 --repo acme/app --event approve --body LGTM 2>&1)
rc=$?
if [[ "$rc" -eq 2 ]] && echo "$out" | grep -q -- '--commit' && [[ "$(formal_count)" -eq 0 ]]; then
  ok "no-commit: missing --commit refuses before mutation"
else
  bad "no-commit missing-commit rc=$rc count=$(formal_count) out=$out"
fi

if [[ "$MATRIX" -eq "$MATRIX_EXPECT" ]]; then
  ok "matrix count is $MATRIX_EXPECT (non-vacuous fixtures all ran)"
else
  bad "matrix count $MATRIX != expected $MATRIX_EXPECT"
fi

echo
echo "second-opinion.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
