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
MATRIX_EXPECT=26
POST_MUTANTS_KILLED=0
POST_MUTANTS_SURVIVED=0
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
if [[ "$rc" -eq 2 ]] && echo "$out" | grep -- '--commit' >/dev/null && [[ "$(formal_count)" -eq 0 ]]; then
  ok "no-commit: missing --commit refuses before mutation"
else
  bad "no-commit missing-commit rc=$rc count=$(formal_count) out=$out"
fi

# 25. empty-reviewer-selection (post-review AC)
begin_matrix "empty-reviewer-selection"

file_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

copy_so_tree() {
  mkdir -p "$1/scripts" "$1/playbooks"
  cp "$GIBSON/playbooks/reviewer.md" "$1/playbooks/reviewer.md"
  cp "$FORMAL_REVIEW" "$1/scripts/formal-review.sh"
  cp "$SECOND_OPINION" "$1/scripts/second-opinion.sh"
  chmod +x "$1/scripts/second-opinion.sh" "$1/scripts/formal-review.sh"
}

reviewer_call_total() {
  local n=0 t
  for t in codex claude grok; do
    if [[ -s "$CALLS/$t.count" ]]; then
      n=$((n + $(wc -l < "$CALLS/$t.count" | tr -d ' ')))
    fi
  done
  printf '%s' "$n"
}

EMPTY_SEL_ERR='second-opinion.sh: ERROR: --reviewers must select at least one nonempty reviewer'
PYTHON3=$(command -v python3 || true)
if [[ -z "$PYTHON3" ]]; then
  bad "empty-reviewer-selection: python3 required for the independent process-group watchdog"
fi

EMPTY_HARNESS="$ROOT/empty-sel-harness"
mkdir -p "$EMPTY_HARNESS"
# Exact stderr fixture: the required error line plus exactly one LF.
EMPTY_SEL_ERR_FILE="$EMPTY_HARNESS/expected.stderr"
printf '%s\n' "$EMPTY_SEL_ERR" > "$EMPTY_SEL_ERR_FILE"
cat > "$EMPTY_HARNESS/watchdog.py" <<'PY'
#!/usr/bin/env python3
"""Independent 5s process-group watchdog. Exit 124 if the deadline fires."""
import os
import signal
import subprocess
import sys
import time

def reap(proc, pgid):
    try:
        os.killpg(pgid, signal.SIGTERM)
    except OSError:
        pass
    time.sleep(0.2)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except OSError:
        pass
    deadline = time.time() + 2
    while time.time() < deadline:
        try:
            pid, _st = os.waitpid(-pgid, os.WNOHANG)
        except OSError:
            break
        if pid == 0:
            time.sleep(0.05)
            continue
    try:
        proc.wait()
    except Exception:
        pass

def main():
    if len(sys.argv) < 3:
        sys.stderr.write("watchdog.py: usage: watchdog.py SECONDS CMD...\n")
        sys.exit(2)
    limit = float(sys.argv[1])
    cmd = sys.argv[2:]
    proc = subprocess.Popen(cmd, preexec_fn=os.setpgrp, close_fds=False)
    pgid = proc.pid
    deadline = time.time() + limit
    while True:
        rc = proc.poll()
        if rc is not None:
            try:
                os.waitpid(proc.pid, os.WNOHANG)
            except OSError:
                pass
            sys.exit(rc)
        if time.time() >= deadline:
            reap(proc, pgid)
            sys.exit(124)
        time.sleep(0.05)

if __name__ == "__main__":
    main()
PY
chmod +x "$EMPTY_HARNESS/watchdog.py"

cat > "$EMPTY_HARNESS/caller-shim.sh" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${GIBSON_290_SHIM_INNER:-0}" != 1 ]]; then
  export GIBSON_290_SHIM_INNER=1
  exec "$PYTHON3" "$EMPTY_HARNESS/watchdog.py" 5 "\$0" "\$@"
fi
PRODUCTION_SECOND_OPINION="\${PRODUCTION_SECOND_OPINION:?}"
REVIEWERS_VALUE="\$1"
SO_REPO="\${SO_REPO:?}"
SO_OUT="\${SO_OUT:?}"
SO_BRANCH="\${SO_BRANCH:?}"
SO_STATUS="\${SO_STATUS:?}"
SO_INVOKE="\${SO_INVOKE:?}"
printf '%s\n' "call" >> "\$SO_INVOKE"
if "\$PRODUCTION_SECOND_OPINION" --repo "\$SO_REPO" --reviewers "\$REVIEWERS_VALUE" \
    --author grok --base main --branch "\$SO_BRANCH" --out "\$SO_OUT" \
    --pr 9 --github-repo acme/app; then
  printf '%s\n' "status: ok" > "\$SO_STATUS"
  exit 0
else
  rc=\$?
  exit "\$rc"
fi
SHIM
chmod +x "$EMPTY_HARNESS/caller-shim.sh"

empty_sel_value() {
  case "$1" in
    1) printf '%s' "" ;;
    2) printf '%s' "   " ;;
    3) printf '%s' $'\t' ;;
    4) printf '%s' "," ;;
    5) printf '%s' $' ,\t,, ' ;;
    *) return 1 ;;
  esac
}

run_empty_sel_shim() {
  local val="$1"
  : > "$SO_INVOKE"
  rm -f "$SO_STATUS"
  GIBSON_FORMAL_REVIEW=1 GH_REVIEWER_TOKEN=test-reviewer-token \
    PRODUCTION_SECOND_OPINION="$PRODUCTION_SECOND_OPINION" \
    SO_REPO="$SO_REPO" SO_OUT="$SO_OUT" SO_BRANCH="$SO_BRANCH" \
    SO_STATUS="$SO_STATUS" SO_INVOKE="$SO_INVOKE" \
    "$EMPTY_HARNESS/caller-shim.sh" "$val" \
    >"$SO_STDOUT" 2>"$SO_STDERR"
  return $?
}

ES_CASES=0
ES_SHIM_INVOCATIONS=0
ES_BOUNDED=0
ES_EXIT1=0
ES_STDOUT_EMPTY=0
ES_STDERR_EXACT=0
ES_REVIEWER_CALLS=0
ES_FORMAL_CALLS=0
ES_GH_CALLS=0
ES_STATUS_OK=0
ES_MUTANTS_KILLED=0
ES_GREEN_OK=1

for i in 1 2 3 4 5; do
  ES_CASES=$((ES_CASES + 1))
  reset_formal
  setup_repo
  write_stub codex $'VERDICT: APPROVE\n' "" 0
  write_stub claude $'VERDICT: APPROVE\n' "" 0
  case_dir="$ROOT/empty-sel/$i"
  mkdir -p "$case_dir"
  SO_OUT="$case_dir/second-opinion.md"
  SO_LOG="${SO_OUT%.md}.log"
  SO_REPO="$REPO"
  SO_BRANCH="$BRANCH"
  SO_STATUS="$case_dir/status"
  SO_INVOKE="$case_dir/invoke.log"
  SO_STDOUT="$case_dir/stdout"
  SO_STDERR="$case_dir/stderr"
  canary_md="CANARY-MD-$i-BYTES"
  canary_log="CANARY-LOG-$i-BYTES"
  canary_md_file="$case_dir/expected-canary.md"
  canary_log_file="$case_dir/expected-canary.log"
  printf '%s' "$canary_md" > "$canary_md_file"
  printf '%s' "$canary_log" > "$canary_log_file"
  if [[ "$i" -le 2 ]]; then
    rm -f "$SO_OUT" "$SO_LOG"
    want_absent=1
  else
    cp "$canary_md_file" "$SO_OUT"
    cp "$canary_log_file" "$SO_LOG"
    want_absent=0
  fi
  val=$(empty_sel_value "$i")
  PRODUCTION_SECOND_OPINION="$SECOND_OPINION"
  : > "$GH_LOG"
  run_empty_sel_shim "$val"
  rc=$?
  inv=$(wc -l < "$SO_INVOKE" 2>/dev/null | tr -d ' ')
  [[ -z "$inv" ]] && inv=0
  ES_SHIM_INVOCATIONS=$((ES_SHIM_INVOCATIONS + inv))
  if [[ "$rc" -eq 124 ]]; then
    bad "empty-sel case $i: watchdog fired (not an accepted exit 1)"
    ES_GREEN_OK=0
  else
    ES_BOUNDED=$((ES_BOUNDED + 1))
  fi
  if [[ "$rc" -eq 1 ]]; then
    ES_EXIT1=$((ES_EXIT1 + 1))
  else
    bad "empty-sel case $i: rc=$rc (want 1)"
    ES_GREEN_OK=0
  fi
  if [[ ! -s "$SO_STDOUT" ]]; then
    ES_STDOUT_EMPTY=$((ES_STDOUT_EMPTY + 1))
  else
    bad "empty-sel case $i: stdout not empty"
    ES_GREEN_OK=0
  fi
  if cmp -s "$SO_STDERR" "$EMPTY_SEL_ERR_FILE"; then
    ES_STDERR_EXACT=$((ES_STDERR_EXACT + 1))
  else
    bad "empty-sel case $i: stderr not exact vs one-line+LF fixture"
    ES_GREEN_OK=0
  fi
  ES_REVIEWER_CALLS=$((ES_REVIEWER_CALLS + $(reviewer_call_total)))
  ES_FORMAL_CALLS=$((ES_FORMAL_CALLS + $(formal_count)))
  gh_n=$(wc -l < "$GH_LOG" 2>/dev/null | tr -d ' ')
  [[ -z "$gh_n" ]] && gh_n=0
  if [[ "$gh_n" -ne 0 ]]; then
    bad "empty-sel case $i: GH_LOG lines=$gh_n (want 0)"
    ES_GREEN_OK=0
  fi
  ES_GH_CALLS=$((ES_GH_CALLS + gh_n))
  if [[ -f "$SO_STATUS" ]] && grep -qx 'status: ok' "$SO_STATUS"; then
    ES_STATUS_OK=$((ES_STATUS_OK + 1))
    bad "empty-sel case $i: wrote status: ok on a failing production run"
    ES_GREEN_OK=0
  fi
  if [[ "$want_absent" -eq 1 ]]; then
    if [[ -e "$SO_OUT" || -e "$SO_LOG" ]]; then
      bad "empty-sel case $i: created report/sidecar that should stay absent"
      ES_GREEN_OK=0
    fi
  else
    if cmp -s "$SO_OUT" "$canary_md_file" && cmp -s "$SO_LOG" "$canary_log_file"; then
      :
    else
      bad "empty-sel case $i: pre-existing canary not preserved byte-for-byte"
      ES_GREEN_OK=0
    fi
  fi
done

if [[ "$ES_REVIEWER_CALLS" -ne 0 ]]; then
  bad "empty-sel: reviewer_calls=$ES_REVIEWER_CALLS (want 0)"
  ES_GREEN_OK=0
fi
if [[ "$ES_FORMAL_CALLS" -ne 0 ]]; then
  bad "empty-sel: formal_calls=$ES_FORMAL_CALLS (want 0)"
  ES_GREEN_OK=0
fi
if [[ "$ES_GH_CALLS" -ne 0 ]]; then
  bad "empty-sel: github_calls=$ES_GH_CALLS (want 0)"
  ES_GREEN_OK=0
fi

# Omitting --reviewers retains the codex,claude default (not one of the 5 shim cases).
reset_formal
setup_repo
write_stub codex $'VERDICT: APPROVE\n' "" 0
write_stub claude $'VERDICT: APPROVE\n' "" 0
GIBSON_FORMAL_REVIEW=1 GH_REVIEWER_TOKEN=test-reviewer-token \
  "$SECOND_OPINION" --repo "$REPO" --author grok \
  --base main --branch "$BRANCH" --out "$OUT" \
  --pr 9 --github-repo acme/app \
  >"$ROOT/stdout-default-reviewers.txt" 2>"$ROOT/stderr-default-reviewers.txt"
def_rc=$?
if grep -q 'must select at least one nonempty reviewer' "$ROOT/stderr-default-reviewers.txt"; then
  bad "omitting --reviewers hit the empty-selection refusal"
  ES_GREEN_OK=0
elif [[ "$def_rc" -eq 0 && -s "$CALLS/codex.count" && -s "$CALLS/claude.count" ]]; then
  ok "omitting --reviewers retains the codex,claude default"
else
  bad "omitting --reviewers did not dispatch both default reviewers rc=$def_rc"
  ES_GREEN_OK=0
fi

extract_empty_guard_block() {
  awk '
    /# --- #290 nonempty-reviewer-selection begin ---/ {keep=1}
    keep {print}
    /# --- #290 nonempty-reviewer-selection end ---/ {keep=0}
  ' "$1"
}

count_empty_guard_markers() {
  local n
  n=$(grep -c '# --- #290 nonempty-reviewer-selection begin ---' "$1" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

PROD_HASH_BEFORE=$(file_sha256 "$SECOND_OPINION")
guard_n=$(count_empty_guard_markers "$SECOND_OPINION")
if [[ "$guard_n" -eq 1 ]]; then
  ok "empty-sel: production nonempty-token block found exactly once"
else
  bad "empty-sel: production guard markers=$guard_n (want 1)"
  ES_GREEN_OK=0
fi

# Mutant EMPTY_REVIEWER_GUARD_REMOVED
REMOVED_GIB="$ROOT/mut-empty-removed"
copy_so_tree "$REMOVED_GIB"
REMOVED_SO="$REMOVED_GIB/scripts/second-opinion.sh"
hash_at_copy=$(file_sha256 "$SECOND_OPINION")
state=keep
: > "$REMOVED_SO"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == *"# --- #290 nonempty-reviewer-selection begin ---"* ]]; then
    state=skip
    continue
  fi
  if [[ "$line" == *"# --- #290 nonempty-reviewer-selection end ---"* ]]; then
    state=keep
    continue
  fi
  if [[ "$state" == keep ]]; then
    printf '%s\n' "$line" >> "$REMOVED_SO"
  fi
done < "$SECOND_OPINION"
chmod +x "$REMOVED_SO"
removed_markers=$(count_empty_guard_markers "$REMOVED_SO")
if [[ "$removed_markers" -eq 0 ]]; then
  ok "EMPTY_REVIEWER_GUARD_REMOVED: deleted the delimited block once"
else
  bad "EMPTY_REVIEWER_GUARD_REMOVED: markers remain ($removed_markers)"
fi
PROD_HASH_AFTER_REMOVED=$(file_sha256 "$SECOND_OPINION")
if [[ "$PROD_HASH_BEFORE" == "$PROD_HASH_AFTER_REMOVED" && "$hash_at_copy" == "$PROD_HASH_BEFORE" ]]; then
  ok "EMPTY_REVIEWER_GUARD_REMOVED: unmodified production hash unchanged"
else
  bad "EMPTY_REVIEWER_GUARD_REMOVED: production hash drifted"
fi

reset_formal
setup_repo
write_stub codex $'VERDICT: APPROVE\n' "" 0
write_stub claude $'VERDICT: APPROVE\n' "" 0
case_dir="$ROOT/empty-sel/removed"
mkdir -p "$case_dir"
SO_OUT="$case_dir/second-opinion.md"
SO_LOG="${SO_OUT%.md}.log"
SO_REPO="$REPO"
SO_BRANCH="$BRANCH"
SO_STATUS="$case_dir/status"
SO_INVOKE="$case_dir/invoke.log"
SO_STDOUT="$case_dir/stdout"
SO_STDERR="$case_dir/stderr"
canary_md="CANARY-REMOVED-MD"
canary_log="CANARY-REMOVED-LOG"
printf '%s' "$canary_md" > "$case_dir/expected-canary.md"
printf '%s' "$canary_log" > "$case_dir/expected-canary.log"
cp "$case_dir/expected-canary.md" "$SO_OUT"
cp "$case_dir/expected-canary.log" "$SO_LOG"
PRODUCTION_SECOND_OPINION="$REMOVED_SO"
run_empty_sel_shim ""
rm_rc=$?
rm_stdout_empty=0
[[ ! -s "$SO_STDOUT" ]] && rm_stdout_empty=1
rm_stderr_exact=0
cmp -s "$SO_STDERR" "$EMPTY_SEL_ERR_FILE" && rm_stderr_exact=1
rm_canary_ok=0
cmp -s "$SO_OUT" "$case_dir/expected-canary.md" && cmp -s "$SO_LOG" "$case_dir/expected-canary.log" && rm_canary_ok=1
rm_status_ok=0
[[ -f "$SO_STATUS" ]] && grep -qx 'status: ok' "$SO_STATUS" && rm_status_ok=1
# Kill on output/artifact/timing, not a status: ok count (mutant also fails).
if [[ "$rm_rc" -eq 124 ]]; then
  bad "EMPTY_REVIEWER_GUARD_REMOVED: watchdog fired"
elif [[ "$rm_stdout_empty" -eq 1 && "$rm_canary_ok" -eq 1 && "$rm_stderr_exact" -eq 1 ]]; then
  bad "EMPTY_REVIEWER_GUARD_REMOVED: survived output/artifact/stderr witnesses (vacuous)"
  POST_MUTANTS_SURVIVED=$((POST_MUTANTS_SURVIVED + 1))
else
  POST_MUTANTS_KILLED=$((POST_MUTANTS_KILLED + 1))
  ES_MUTANTS_KILLED=$((ES_MUTANTS_KILLED + 1))
  echo "RED-BEFORE-GREEN EMPTY_REVIEWER_GUARD_REMOVED: rc=$rm_rc stdout_empty=$rm_stdout_empty canary_ok=$rm_canary_ok status_ok=$rm_status_ok stderr_exact=$rm_stderr_exact"
  ok "EMPTY_REVIEWER_GUARD_REMOVED killed by output/artifact/timing (not status: ok count)"
fi

# Mutant EMPTY_REVIEWER_GUARD_MOVED_LATE
LATE_GIB="$ROOT/mut-empty-late"
copy_so_tree "$LATE_GIB"
LATE_SO="$LATE_GIB/scripts/second-opinion.sh"
hash_at_late_copy=$(file_sha256 "$SECOND_OPINION")
BLOCK_FILE="$ROOT/empty-guard-block.txt"
extract_empty_guard_block "$SECOND_OPINION" > "$BLOCK_FILE"
if [[ ! -s "$BLOCK_FILE" ]]; then
  bad "EMPTY_REVIEWER_GUARD_MOVED_LATE: failed to extract the delimited block"
fi
state=keep
: > "$LATE_SO"
inserted=0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == *"# --- #290 nonempty-reviewer-selection begin ---"* ]]; then
    state=skip
    continue
  fi
  if [[ "$line" == *"# --- #290 nonempty-reviewer-selection end ---"* ]]; then
    state=keep
    continue
  fi
  if [[ "$state" != keep ]]; then
    continue
  fi
  printf '%s\n' "$line" >> "$LATE_SO"
  if [[ "$line" == 'cat "$OUT"' && "$inserted" -eq 0 ]]; then
    cat "$BLOCK_FILE" >> "$LATE_SO"
    inserted=1
  fi
done < "$SECOND_OPINION"
chmod +x "$LATE_SO"
late_markers=$(count_empty_guard_markers "$LATE_SO")
late_after_cat=0
awk '
  $0 == "cat \"$OUT\"" {saw=1}
  saw && /# --- #290 nonempty-reviewer-selection begin ---/ {found=1}
  END {exit found?0:1}
' "$LATE_SO" && late_after_cat=1
if [[ "$late_markers" -eq 1 && "$inserted" -eq 1 && "$late_after_cat" -eq 1 ]]; then
  ok "EMPTY_REVIEWER_GUARD_MOVED_LATE: block moved once to immediately after cat \"\$OUT\""
else
  bad "EMPTY_REVIEWER_GUARD_MOVED_LATE: splice miss markers=$late_markers inserted=$inserted after_cat=$late_after_cat"
fi
PROD_HASH_AFTER_LATE=$(file_sha256 "$SECOND_OPINION")
if [[ "$PROD_HASH_BEFORE" == "$PROD_HASH_AFTER_LATE" && "$hash_at_late_copy" == "$PROD_HASH_BEFORE" ]]; then
  ok "EMPTY_REVIEWER_GUARD_MOVED_LATE: unmodified production hash unchanged"
else
  bad "EMPTY_REVIEWER_GUARD_MOVED_LATE: production hash drifted"
fi

reset_formal
setup_repo
write_stub codex $'VERDICT: APPROVE\n' "" 0
write_stub claude $'VERDICT: APPROVE\n' "" 0
case_dir="$ROOT/empty-sel/late"
mkdir -p "$case_dir"
SO_OUT="$case_dir/second-opinion.md"
SO_LOG="${SO_OUT%.md}.log"
SO_REPO="$REPO"
SO_BRANCH="$BRANCH"
SO_STATUS="$case_dir/status"
SO_INVOKE="$case_dir/invoke.log"
SO_STDOUT="$case_dir/stdout"
SO_STDERR="$case_dir/stderr"
canary_md="CANARY-LATE-MD"
canary_log="CANARY-LATE-LOG"
printf '%s' "$canary_md" > "$case_dir/expected-canary.md"
printf '%s' "$canary_log" > "$case_dir/expected-canary.log"
cp "$case_dir/expected-canary.md" "$SO_OUT"
cp "$case_dir/expected-canary.log" "$SO_LOG"
PRODUCTION_SECOND_OPINION="$LATE_SO"
run_empty_sel_shim ""
late_rc=$?
late_stdout_empty=0
[[ ! -s "$SO_STDOUT" ]] && late_stdout_empty=1
late_stderr_exact=0
cmp -s "$SO_STDERR" "$EMPTY_SEL_ERR_FILE" && late_stderr_exact=1
late_canary_ok=0
cmp -s "$SO_OUT" "$case_dir/expected-canary.md" && cmp -s "$SO_LOG" "$case_dir/expected-canary.log" && late_canary_ok=1
late_status_ok=0
[[ -f "$SO_STATUS" ]] && grep -qx 'status: ok' "$SO_STATUS" && late_status_ok=1
if [[ "$late_rc" -eq 124 ]]; then
  bad "EMPTY_REVIEWER_GUARD_MOVED_LATE: watchdog fired"
  POST_MUTANTS_SURVIVED=$((POST_MUTANTS_SURVIVED + 1))
elif [[ "$late_stdout_empty" -eq 1 && "$late_canary_ok" -eq 1 ]]; then
  bad "EMPTY_REVIEWER_GUARD_MOVED_LATE: survived late stdout/report/canary witnesses"
  POST_MUTANTS_SURVIVED=$((POST_MUTANTS_SURVIVED + 1))
else
  POST_MUTANTS_KILLED=$((POST_MUTANTS_KILLED + 1))
  ES_MUTANTS_KILLED=$((ES_MUTANTS_KILLED + 1))
  echo "RED-BEFORE-GREEN EMPTY_REVIEWER_GUARD_MOVED_LATE: rc=$late_rc stdout_empty=$late_stdout_empty canary_ok=$late_canary_ok status_ok=$late_status_ok stderr_exact=$late_stderr_exact"
  ok "EMPTY_REVIEWER_GUARD_MOVED_LATE killed by late stdout/report/canary effects"
fi

if [[ "$ES_CASES" -eq 5 && "$ES_SHIM_INVOCATIONS" -eq 5 && "$ES_BOUNDED" -eq 5 \
  && "$ES_EXIT1" -eq 5 && "$ES_STDOUT_EMPTY" -eq 5 && "$ES_STDERR_EXACT" -eq 5 \
  && "$ES_REVIEWER_CALLS" -eq 0 && "$ES_FORMAL_CALLS" -eq 0 && "$ES_GH_CALLS" -eq 0 \
  && "$ES_STATUS_OK" -eq 0 \
  && "$ES_MUTANTS_KILLED" -eq 2 && "$ES_GREEN_OK" -eq 1 ]]; then
  echo "empty-reviewer-selection cases=5 shim_invocations=5 bounded=5 exit=1 stdout=empty stderr=exact reviewer_calls=0 formal_calls=0 status_ok=0 mutants=2/2"
  ok "empty-reviewer-selection receipt"
else
  bad "empty-reviewer-selection counters cases=$ES_CASES shim=$ES_SHIM_INVOCATIONS bounded=$ES_BOUNDED exit1=$ES_EXIT1 stdout=$ES_STDOUT_EMPTY stderr=$ES_STDERR_EXACT reviewer=$ES_REVIEWER_CALLS formal=$ES_FORMAL_CALLS github=$ES_GH_CALLS status_ok=$ES_STATUS_OK mutants=$ES_MUTANTS_KILLED/2 green=$ES_GREEN_OK"
fi

# 26. frozen-base-head-toctou (post-review AC)
begin_matrix "frozen-base-head-toctou"

TOCTOU_SENTINEL="TOCTOU-ORIGINAL-SENTINEL-B0-H1"
HEAD_SENTINEL="TOCTOU-MOVED-HEAD-SENTINEL-H2"
TOCTOU_SEAM='git -C "$REPO" diff "$BASE_SHA...$REVIEWED_SHA"'
TOCTOU_SEAM_BASE='git -C "$REPO" diff "$BASE...$REVIEWED_SHA"'
TOCTOU_SEAM_HEAD='git -C "$REPO" diff "$BASE_SHA...$BRANCH"'

setup_toctou_repo() {
  rm -rf "$REPO" "$ROOT/out"
  mkdir -p "$REPO"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  echo base > "$REPO/README.md"
  $GIT -C "$REPO" add README.md
  $GIT -C "$REPO" commit -q -m "B0"
  B0=$(git -C "$REPO" rev-parse HEAD | tr 'A-F' 'a-f')
  $GIT -C "$REPO" checkout -q -b "$BRANCH"
  echo "$TOCTOU_SENTINEL" >> "$REPO/README.md"
  $GIT -C "$REPO" commit -q -am "H1"
  H1=$(git -C "$REPO" rev-parse HEAD | tr 'A-F' 'a-f')
  $GIT -C "$REPO" checkout -q main
  : > "$CALLS/codex.count"
  rm -f "$CALLS/prompt.txt" "$CALLS/codex.prompt"
}

install_toctou_git() {
  local mode="$1"
  export GIBSON_290_REAL_GIT="$REAL_GIT"
  export GIBSON_290_TOCTOU_REPO="$REPO"
  export GIBSON_290_TOCTOU_MODE="$mode"
  export GIBSON_290_TOCTOU_BASE="main"
  export GIBSON_290_TOCTOU_BRANCH="$BRANCH"
  export GIBSON_290_TOCTOU_B0="$B0"
  export GIBSON_290_TOCTOU_H1="$H1"
  export GIBSON_290_TOCTOU_HEAD_SENTINEL="$HEAD_SENTINEL"
  export GIBSON_290_TOCTOU_DIR="$ROOT/toctou-$mode"
  mkdir -p "$GIBSON_290_TOCTOU_DIR"
  : > "$GIBSON_290_TOCTOU_DIR/resolve.log"
  rm -f "$GIBSON_290_TOCTOU_DIR/moved.marker" \
    "$GIBSON_290_TOCTOU_DIR/move-refused.marker" \
    "$GIBSON_290_TOCTOU_DIR/diff.args" \
    "$GIBSON_290_TOCTOU_DIR/h2.sha" \
    "$GIBSON_290_TOCTOU_DIR/mb_frozen" \
    "$GIBSON_290_TOCTOU_DIR/mb_moved" \
    "$GIBSON_290_TOCTOU_DIR/expected.resolve"
  # BIN/git is normally a symlink to the real git; writing through it would
  # clobber the real binary (macOS "Operation not permitted").
  rm -f "$BIN/git"
  cat > "$BIN/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
REAL="${GIBSON_290_REAL_GIT:?}"
DIR="${GIBSON_290_TOCTOU_DIR:?}"
REPO_T="${GIBSON_290_TOCTOU_REPO:?}"
is_rev_parse=0
is_verify=0
is_quiet=0
is_diff=0
operand=""
for a in "$@"; do
  case "$a" in
    rev-parse) is_rev_parse=1 ;;
    --verify) is_verify=1 ;;
    --quiet) is_quiet=1 ;;
    diff) is_diff=1 ;;
  esac
  operand="$a"
done
if [[ "$is_rev_parse" -eq 1 && "$is_verify" -eq 1 && "$is_quiet" -eq 1 ]]; then
  printf '%s\n' "$operand" >> "$DIR/resolve.log"
  exec "$REAL" "$@"
fi
if [[ "$is_diff" -eq 1 ]]; then
  printf '%s\n' "$*" >> "$DIR/diff.args"
  if [[ ! -f "$DIR/moved.marker" && ! -f "$DIR/move-refused.marker" ]]; then
    BASE_N="${GIBSON_290_TOCTOU_BASE:?}"
    BR_N="${GIBSON_290_TOCTOU_BRANCH:?}"
    printf '%s\n' "${BASE_N}^{commit}" "${BR_N}^{commit}" > "$DIR/expected.resolve"
    if cmp -s "$DIR/resolve.log" "$DIR/expected.resolve"; then
      : > "$DIR/moved.marker"
      PATH="/usr/bin:/bin:/usr/local/bin"
      B0="${GIBSON_290_TOCTOU_B0:?}"
      H1="${GIBSON_290_TOCTOU_H1:?}"
      "$REAL" -C "$REPO_T" merge-base "$B0" "$H1" > "$DIR/mb_frozen"
      if [[ "${GIBSON_290_TOCTOU_MODE:?}" == "base-move" ]]; then
        "$REAL" -C "$REPO_T" update-ref "refs/heads/${BASE_N}" "$H1"
        "$REAL" -C "$REPO_T" merge-base "$BASE_N" "$H1" > "$DIR/mb_moved"
      else
        "$REAL" -C "$REPO_T" checkout -q "$BR_N"
        printf '%s\n' "${GIBSON_290_TOCTOU_HEAD_SENTINEL:?}" >> "$REPO_T/README.md"
        "$REAL" -C "$REPO_T" add README.md
        "$REAL" -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false \
          -C "$REPO_T" commit -q -am "moved-head"
        "$REAL" -C "$REPO_T" rev-parse HEAD | tr 'A-F' 'a-f' > "$DIR/h2.sha"
        "$REAL" -C "$REPO_T" checkout -q "$BASE_N"
      fi
    else
      : > "$DIR/move-refused.marker"
    fi
  fi
  exec "$REAL" "$@"
fi
exec "$REAL" "$@"
GIT
  chmod +x "$BIN/git"
}

toctou_write_expected_resolve() {
  printf '%s\n' "main^{commit}" "${BRANCH}^{commit}" > "$1"
}

toctou_resolve_log_exact() {
  local dir="${GIBSON_290_TOCTOU_DIR:?}"
  local expected="$dir/expected.resolve"
  toctou_write_expected_resolve "$expected"
  cmp -s "$dir/resolve.log" "$expected"
}

restore_git() {
  ln -sf "$REAL_GIT" "$BIN/git"
}

replace_diff_seam_once() {
  local file="$1" old="$2" new="$3"
  "$PYTHON3" - "$file" "$old" "$new" <<'PY'
import pathlib, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(path).read_text()
n = text.count(old)
if n != 1:
    sys.stderr.write("seam count %d for %r\n" % (n, old))
    sys.exit(2)
pathlib.Path(path).write_text(text.replace(old, new, 1))
PY
}

run_toctou_so() {
  local so_path="$1"
  reset_formal
  write_stub codex $'VERDICT: APPROVE\n' "" 0
  GIBSON_FORMAL_REVIEW=1 GH_REVIEWER_TOKEN=test-reviewer-token \
    "$so_path" --repo "$REPO" --reviewers codex --author grok \
    --base main --branch "$BRANCH" --out "$OUT" \
    --pr 9 --github-repo acme/app \
    >"$ROOT/toctou.stdout" 2>"$ROOT/toctou.stderr"
}

TOCTOU_BASE_MOVES=0
TOCTOU_HEAD_MOVES=0
TOCTOU_MB_CHANGED=0
TOCTOU_FROZEN_PAIR=fail
TOCTOU_BASE_MUTANT=fail
TOCTOU_HEAD_MUTANT=fail
TOCTOU_MUTANTS_KILLED=0

# Green base-move: B0 -> H1, freeze, move main to H1, frozen pair still shows sentinel.
setup_toctou_repo
install_toctou_git base-move
run_toctou_so "$SECOND_OPINION"
base_rc=$?
prompt="$CALLS/codex.prompt"
if [[ ! -s "$prompt" ]]; then
  prompt="$CALLS/prompt.txt"
fi
mb_frozen=$(tr -d '\n' < "$GIBSON_290_TOCTOU_DIR/mb_frozen" 2>/dev/null || true)
mb_moved=$(tr -d '\n' < "$GIBSON_290_TOCTOU_DIR/mb_moved" 2>/dev/null || true)
mb_frozen=$(printf '%s' "$mb_frozen" | tr 'A-F' 'a-f')
mb_moved=$(printf '%s' "$mb_moved" | tr 'A-F' 'a-f')
name_diff=$("$REAL_GIT" -C "$REPO" diff "main...$H1" || true)
if [[ -f "$GIBSON_290_TOCTOU_DIR/moved.marker" ]]; then
  TOCTOU_BASE_MOVES=1
  ok "toctou: requested base name moved after both freezes"
else
  bad "toctou: base name was not moved after freeze"
fi
if [[ "$mb_frozen" == "$B0" && "$mb_moved" == "$H1" && "$B0" != "$H1" ]]; then
  TOCTOU_MB_CHANGED=1
  ok "toctou: merge-base changed B0 -> H1 after moving the base name"
else
  bad "toctou: merge-base frozen=$mb_frozen moved=$mb_moved (want B0=$B0 H1=$H1)"
fi
if [[ -z "$name_diff" ]]; then
  ok "toctou: re-resolving the moved base name yields an empty diff"
else
  bad "toctou: name re-resolution was not empty"
fi
if [[ "$base_rc" -eq 0 ]] && grep -qF "$TOCTOU_SENTINEL" "$prompt" 2>/dev/null \
  && grep -q "Reviewed commit: \`$H1\`" "$OUT" \
  && grep -q "Frozen base: \`$B0\`" "$OUT" \
  && grep -qF "Diff: \`$B0...$H1\`" "$OUT" \
  && grep -q "Reviewed commit: \`$H1\`" "$prompt" \
  && grep -q "Frozen base: \`$B0\`" "$prompt" \
  && grep -qF "Diff: \`$B0...$H1\`" "$prompt" \
  && grep -q "Requested base (label only): \`main\`" "$prompt" \
  && ! grep -qF "$HEAD_SENTINEL" "$prompt" 2>/dev/null \
  && toctou_resolve_log_exact; then
  TOCTOU_FROZEN_PAIR=pass
  ok "toctou: frozen pair B0/H1 is the reviewer/report authority; sentinel survived the base move"
else
  bad "toctou: frozen-pair/sentinel miss rc=$base_rc resolve=$(tr '\n' '|' < "$GIBSON_290_TOCTOU_DIR/resolve.log" 2>/dev/null) report=$(grep -E 'Reviewed commit|Frozen base|Diff:' "$OUT" 2>/dev/null)"
fi
if grep -q "commit_id=$H1" "$GH_LOG" 2>/dev/null || [[ "$(formal_commit)" == "$H1" ]]; then
  ok "toctou: formal-review --commit remains REVIEWED_SHA (H1)"
else
  bad "toctou: formal commit=$(formal_commit) want $H1"
fi
restore_git

# Independent moved-head case.
setup_toctou_repo
install_toctou_git head-move
run_toctou_so "$SECOND_OPINION"
head_rc=$?
prompt="$CALLS/codex.prompt"
if [[ ! -s "$prompt" ]]; then
  prompt="$CALLS/prompt.txt"
fi
H2=$(tr -d '\n' < "$GIBSON_290_TOCTOU_DIR/h2.sha" 2>/dev/null || true)
if [[ -f "$GIBSON_290_TOCTOU_DIR/moved.marker" && -n "$H2" && "$H2" != "$H1" ]]; then
  TOCTOU_HEAD_MOVES=1
  ok "toctou: reviewed name advanced to H2 after both freezes"
else
  bad "toctou: head was not moved (H2='$H2')"
fi
if [[ "$head_rc" -eq 0 ]] && grep -qF "$TOCTOU_SENTINEL" "$prompt" 2>/dev/null \
  && ! grep -qF "$HEAD_SENTINEL" "$prompt" 2>/dev/null \
  && grep -q "Reviewed commit: \`$H1\`" "$OUT" \
  && grep -q "Frozen base: \`$B0\`" "$OUT" \
  && grep -qF "Diff: \`$B0...$H1\`" "$prompt" \
  && toctou_resolve_log_exact; then
  ok "toctou: frozen SHA-only diff retained the original sentinel and excluded the moved-head sentinel"
  if [[ "$TOCTOU_FROZEN_PAIR" != pass ]]; then
    TOCTOU_FROZEN_PAIR=pass
  fi
else
  bad "toctou: moved-head leaked into frozen review rc=$head_rc H2=$H2 resolve=$(tr '\n' '|' < "$GIBSON_290_TOCTOU_DIR/resolve.log" 2>/dev/null)"
  TOCTOU_FROZEN_PAIR=fail
fi
restore_git

# Mutant BASE_NAME_RERESOLVED
PROD_HASH_T0=$(file_sha256 "$SECOND_OPINION")
seam_n=$(grep -cF "$TOCTOU_SEAM" "$SECOND_OPINION" || true)
if [[ "$seam_n" -eq 1 ]]; then
  ok "toctou: production SHA-only diff seam found exactly once"
else
  bad "toctou: production diff seam count=$seam_n (want 1)"
fi
BASE_MUT_GIB="$ROOT/mut-base-name"
copy_so_tree "$BASE_MUT_GIB"
BASE_MUT_SO="$BASE_MUT_GIB/scripts/second-opinion.sh"
if replace_diff_seam_once "$BASE_MUT_SO" "$TOCTOU_SEAM" "$TOCTOU_SEAM_BASE"; then
  ok "BASE_NAME_RERESOLVED: replaced the single SHA-only base operand"
else
  bad "BASE_NAME_RERESOLVED: failed to find/replace the unique seam"
fi
new_n=$(grep -cF "$TOCTOU_SEAM_BASE" "$BASE_MUT_SO" || true)
old_n=$(grep -cF "$TOCTOU_SEAM" "$BASE_MUT_SO" || true)
if [[ "$new_n" -eq 1 && "$old_n" -eq 0 ]]; then
  ok "BASE_NAME_RERESOLVED: mutated seam present exactly once; original gone"
else
  bad "BASE_NAME_RERESOLVED: seam counts new=$new_n old=$old_n"
fi
PROD_HASH_T1=$(file_sha256 "$SECOND_OPINION")
if [[ "$PROD_HASH_T0" == "$PROD_HASH_T1" ]]; then
  ok "BASE_NAME_RERESOLVED: unmodified production hash unchanged"
else
  bad "BASE_NAME_RERESOLVED: production hash drifted"
fi
setup_toctou_repo
install_toctou_git base-move
run_toctou_so "$BASE_MUT_SO"
bm_rc=$?
prompt="$CALLS/codex.prompt"
if [[ ! -s "$prompt" ]]; then
  prompt="$CALLS/prompt.txt"
fi
diff_args=$(cat "$GIBSON_290_TOCTOU_DIR/diff.args" 2>/dev/null || true)
executed_name_diff=0
if [[ -f "$GIBSON_290_TOCTOU_DIR/diff.args" ]]; then
  executed_name_diff=$(grep -cF "main...$H1" "$GIBSON_290_TOCTOU_DIR/diff.args" || true)
fi
[[ "$executed_name_diff" =~ ^[0-9]+$ ]] || executed_name_diff=0
saw_sentinel=0
grep -qF "$TOCTOU_SENTINEL" "$prompt" 2>/dev/null && saw_sentinel=1
empty_moved_base=0
grep -qF "empty diff for $B0...$H1" "$ROOT/toctou.stderr" 2>/dev/null && empty_moved_base=1
bm_reviewer_calls=$(reviewer_call_total)
bm_formal_calls=$(formal_count)
if [[ "$executed_name_diff" -eq 1 && "$bm_rc" -eq 1 && "$empty_moved_base" -eq 1 \
  && "$bm_reviewer_calls" -eq 0 && "$bm_formal_calls" -eq 0 && "$saw_sentinel" -eq 0 ]] \
  && toctou_resolve_log_exact; then
  TOCTOU_BASE_MUTANT=empty
  TOCTOU_MUTANTS_KILLED=$((TOCTOU_MUTANTS_KILLED + 1))
  POST_MUTANTS_KILLED=$((POST_MUTANTS_KILLED + 1))
  echo "RED-BEFORE-GREEN BASE_NAME_RERESOLVED: rc=$bm_rc executed_name_diff=$executed_name_diff empty_moved_base_diff=$empty_moved_base reviewer_calls=$bm_reviewer_calls formal_calls=$bm_formal_calls sentinel_in_reviewer_input=$saw_sentinel diff_args=$(printf '%s' "$diff_args" | tr '\n' ' ')"
  ok "BASE_NAME_RERESOLVED killed: moved-base name operand produced an empty review"
else
  POST_MUTANTS_SURVIVED=$((POST_MUTANTS_SURVIVED + 1))
  bad "BASE_NAME_RERESOLVED survived executed_name_diff=$executed_name_diff empty_moved_base_diff=$empty_moved_base reviewer_calls=$bm_reviewer_calls formal_calls=$bm_formal_calls sentinel=$saw_sentinel rc=$bm_rc args=$diff_args resolve=$(tr '\n' '|' < "$GIBSON_290_TOCTOU_DIR/resolve.log" 2>/dev/null)"
fi
restore_git

# Mutant HEAD_NAME_RERESOLVED
PROD_HASH_T2=$(file_sha256 "$SECOND_OPINION")
HEAD_MUT_GIB="$ROOT/mut-head-name"
copy_so_tree "$HEAD_MUT_GIB"
HEAD_MUT_SO="$HEAD_MUT_GIB/scripts/second-opinion.sh"
if replace_diff_seam_once "$HEAD_MUT_SO" "$TOCTOU_SEAM" "$TOCTOU_SEAM_HEAD"; then
  ok "HEAD_NAME_RERESOLVED: replaced the single SHA-only head operand"
else
  bad "HEAD_NAME_RERESOLVED: failed to find/replace the unique seam"
fi
new_n=$(grep -cF "$TOCTOU_SEAM_HEAD" "$HEAD_MUT_SO" || true)
old_n=$(grep -cF "$TOCTOU_SEAM" "$HEAD_MUT_SO" || true)
if [[ "$new_n" -eq 1 && "$old_n" -eq 0 ]]; then
  ok "HEAD_NAME_RERESOLVED: mutated seam present exactly once; original gone"
else
  bad "HEAD_NAME_RERESOLVED: seam counts new=$new_n old=$old_n"
fi
PROD_HASH_T3=$(file_sha256 "$SECOND_OPINION")
if [[ "$PROD_HASH_T2" == "$PROD_HASH_T3" && "$PROD_HASH_T0" == "$PROD_HASH_T3" ]]; then
  ok "HEAD_NAME_RERESOLVED: unmodified production hash unchanged"
else
  bad "HEAD_NAME_RERESOLVED: production hash drifted"
fi
setup_toctou_repo
install_toctou_git head-move
run_toctou_so "$HEAD_MUT_SO"
hm_rc=$?
prompt="$CALLS/codex.prompt"
if [[ ! -s "$prompt" ]]; then
  prompt="$CALLS/prompt.txt"
fi
diff_args=$(cat "$GIBSON_290_TOCTOU_DIR/diff.args" 2>/dev/null || true)
executed_head_name=0
if [[ -f "$GIBSON_290_TOCTOU_DIR/diff.args" ]]; then
  executed_head_name=$(grep -cF "$BRANCH" "$GIBSON_290_TOCTOU_DIR/diff.args" || true)
fi
[[ "$executed_head_name" =~ ^[0-9]+$ ]] || executed_head_name=0
saw_moved=0
grep -qF "$HEAD_SENTINEL" "$prompt" 2>/dev/null && saw_moved=1
hm_reviewer_calls=$(reviewer_call_total)
if [[ "$executed_head_name" -eq 1 && "$saw_moved" -eq 1 && "$hm_rc" -eq 0 && "$hm_reviewer_calls" -eq 1 ]] \
  && toctou_resolve_log_exact; then
  TOCTOU_HEAD_MUTANT=different
  TOCTOU_MUTANTS_KILLED=$((TOCTOU_MUTANTS_KILLED + 1))
  POST_MUTANTS_KILLED=$((POST_MUTANTS_KILLED + 1))
  echo "RED-BEFORE-GREEN HEAD_NAME_RERESOLVED: rc=$hm_rc executed_head_name=$executed_head_name reviewer_calls=$hm_reviewer_calls moved_head_sentinel_in_reviewer_input=$saw_moved"
  ok "HEAD_NAME_RERESOLVED killed: re-resolved head exposed the moved-head sentinel"
else
  POST_MUTANTS_SURVIVED=$((POST_MUTANTS_SURVIVED + 1))
  bad "HEAD_NAME_RERESOLVED survived executed=$executed_head_name moved=$saw_moved reviewer_calls=$hm_reviewer_calls rc=$hm_rc args=$diff_args resolve=$(tr '\n' '|' < "$GIBSON_290_TOCTOU_DIR/resolve.log" 2>/dev/null)"
fi
restore_git

if [[ "$TOCTOU_BASE_MOVES" -eq 1 && "$TOCTOU_HEAD_MOVES" -eq 1 \
  && "$TOCTOU_MB_CHANGED" -eq 1 && "$TOCTOU_FROZEN_PAIR" == pass \
  && "$TOCTOU_BASE_MUTANT" == empty && "$TOCTOU_HEAD_MUTANT" == different \
  && "$TOCTOU_MUTANTS_KILLED" -eq 2 ]]; then
  echo "frozen-base-head-toctou base_moves=1 head_moves=1 base_merge_base_changed=1 frozen_pair=pass base_name_mutant=empty head_name_mutant=different mutants=2/2"
  ok "frozen-base-head-toctou receipt"
else
  bad "frozen-base-head-toctou counters base=$TOCTOU_BASE_MOVES head=$TOCTOU_HEAD_MOVES mb=$TOCTOU_MB_CHANGED pair=$TOCTOU_FROZEN_PAIR base_mut=$TOCTOU_BASE_MUTANT head_mut=$TOCTOU_HEAD_MUTANT killed=$TOCTOU_MUTANTS_KILLED"
fi

if [[ "$POST_MUTANTS_KILLED" -eq 4 && "$POST_MUTANTS_SURVIVED" -eq 0 ]]; then
  echo "post-review-mutants total=4 killed=4 survived=0"
  ok "post-review-mutants receipt"
else
  bad "post-review-mutants killed=$POST_MUTANTS_KILLED survived=$POST_MUTANTS_SURVIVED (want 4/0)"
fi

if [[ "$MATRIX" -eq "$MATRIX_EXPECT" ]]; then
  ok "matrix count is $MATRIX_EXPECT (non-vacuous fixtures all ran)"
else
  bad "matrix count $MATRIX != expected $MATRIX_EXPECT"
fi

echo
echo "second-opinion.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
