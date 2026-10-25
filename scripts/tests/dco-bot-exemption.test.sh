#!/usr/bin/env bash
# dco-bot-exemption.test.sh — the DCO step in gibson-self-gate.yml (#554)
#
# WHY
#   The DCO step is inline YAML, so nothing exercised it. This test extracts its
#   `run:` script and executes it against throwaway repositories, which locks both
#   the rule (every commit in a PR carries Signed-off-by) and its one exemption:
#   inside a pull request AUTHORED by dependabot[bot], a commit is exempt only if
#   GitHub's API records author dependabot[bot], committer web-flow (GitHub) and a
#   verified signature. The exemption is per commit, never per PR (a human can push
#   onto a Dependabot PR), and `verified` alone is not enough (a human can forge the
#   Dependabot author email and sign with their own key); it never trusts local
#   commit metadata; exactly one bot is named. The API is stubbed with a fake `gh`
#   on PATH that serves JSON fixtures and applies the REAL --jq expression through
#   jq, so the filter in the workflow is under test. The test never touches GitHub.
#
# USAGE
#   scripts/tests/dco-bot-exemption.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
WF="$REPO_ROOT/.github/workflows/gibson-self-gate.yml"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v git >/dev/null || { echo "dco-bot-exemption.test.sh: git required"; exit 1; }
[[ -f "$WF" ]] || { echo "dco-bot-exemption.test.sh: workflow not found: $WF"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-dco-bot.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

echo "# extract the DCO step's run script from the workflow"
STEP="$ROOT/dco-step.sh"
awk '
  /^      - name: DCO trailer check[[:space:]]*$/ { instep = 1; next }
  instep && /^        run: \|[[:space:]]*$/       { inrun = 1; next }
  instep && inrun {
    if ($0 ~ /^      - / || $0 ~ /^[^ ]/) exit
    sub(/^          /, "")
    print
  }
' "$WF" > "$STEP"
if [[ -s "$STEP" ]] && grep -q 'Signed-off-by' "$STEP" && grep -q 'rev-list' "$STEP"; then
  ok "extracted the DCO step script ($(wc -l < "$STEP" | tr -d ' ') lines)"
else
  bad "could not extract the DCO step from $WF"
  echo "dco-bot-exemption.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi

# new_repo DIR — a repo with one unsigned base commit (the base is outside the range on purpose)
new_repo() {
  mkdir -p "$1" && git -C "$1" init -q -b main
  git -C "$1" config user.email human@example.com && git -C "$1" config user.name "A Human"
  echo base > "$1/f" && git -C "$1" add f && git -C "$1" commit -q -m "base (unsigned on purpose)"
}

# add_commit DIR MESSAGE [AUTHOR_NAME AUTHOR_EMAIL]
add_commit() {
  local dir="$1" msg="$2"
  echo "$msg" >> "$dir/f" && git -C "$dir" add f
  if [[ $# -ge 4 ]]; then
    GIT_AUTHOR_NAME="$3" GIT_AUTHOR_EMAIL="$4" git -C "$dir" commit -q -m "$msg"
  else
    git -C "$dir" commit -q -m "$msg"
  fi
}

# run_step DIR PR_AUTHOR [EVENT] [NCOMMITS] — prints output, sets RC. The range is
# HEAD~NCOMMITS..HEAD; if the base does not resolve the test setup is wrong, which would
# make every negative assertion pass vacuously, so that is a hard failure, not a pass.
run_step() {
  local dir="$1" author="$2" event="${3:-pull_request}" n="${4:-1}" base head
  if ! base=$(git -C "$dir" rev-parse "HEAD~${n}" 2>/dev/null); then
    bad "test setup: HEAD~${n} does not resolve in $dir (a vacuous run); fix the fixture"
    OUT="setup error"; RC=99; return
  fi
  head=$(git -C "$dir" rev-parse HEAD)
  OUT=$(cd "$dir" && PATH="$ROOT/stub-bin:$PATH" GH_FIXTURE="$ROOT/fixture" EVENT_NAME="$event" BASE_SHA="$base" HEAD_SHA="$head" \
        PR_AUTHOR="$author" REPO="example/repo" GH_TOKEN="test" GITHUB_STEP_SUMMARY="$ROOT/summary.md" bash "$STEP" 2>&1)
  RC=$?
}

# The stub: `gh api repos/<repo>/commits/<sha> [--jq EXPR]` serves the JSON fixture for <sha>
# and applies EXPR with the real jq (gh's --jq is jq -r); a missing fixture is an API error.
command -v jq >/dev/null || { echo "dco-bot-exemption.test.sh: jq required"; exit 1; }
mkdir -p "$ROOT/stub-bin" "$ROOT/fixture"
cat > "$ROOT/stub-bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || { echo "stub gh: unexpected args: $*" >&2; exit 2; }
sha=${2##*/}; shift 2
expr=""
while [ $# -gt 0 ]; do
  case "$1" in --jq) expr="$2"; shift 2 ;; *) shift ;; esac
done
[ -f "$GH_FIXTURE/$sha" ] || { echo "stub gh: no fixture for $sha" >&2; exit 1; }
if [ -n "$expr" ]; then jq -r "$expr" "$GH_FIXTURE/$sha"; else cat "$GH_FIXTURE/$sha"; fi
STUB
chmod +x "$ROOT/stub-bin/gh"
# record SHA [AUTHOR] [COMMITTER] [VERIFIED] — what the API would say about a commit; the defaults
# are the shape of a genuine Dependabot commit (author dependabot[bot], committer web-flow, verified)
record() {
  jq -n --arg a "${2-dependabot[bot]}" --arg c "${3-web-flow}" --argjson v "${4-true}" \
    '{author:{login:$a}, committer:{login:$c}, commit:{verification:{verified:$v, reason:(if $v then "valid" else "unsigned" end)}}}' \
    > "$ROOT/fixture/$1"
}

echo "# the rule: a human's unsigned commit fails"
R="$ROOT/unsigned"; new_repo "$R"; add_commit "$R" "feature without a sign-off"
run_step "$R" "a-human"
[[ $RC -ne 0 ]] && ok "unsigned commit from a human PR fails (rc=$RC)" || bad "unsigned human commit passed: $OUT"

echo "# the rule: a signed commit passes"
R="$ROOT/signed"; new_repo "$R"
echo x >> "$R/f"; git -C "$R" add f; git -C "$R" commit -q -s -m "feature with a sign-off"
run_step "$R" "a-human"
[[ $RC -eq 0 ]] && ok "signed commit passes" || bad "signed commit failed (rc=$RC): $OUT"

echo "# the exemption: a PR authored by dependabot[bot] passes with a visible notice"
R="$ROOT/bot"; new_repo "$R"
add_commit "$R" "chore(deps): bump an action" "dependabot[bot]" "49699333+dependabot[bot]@users.noreply.github.com"
record "$(git -C "$R" rev-parse HEAD)"
run_step "$R" "dependabot[bot]"
if [[ $RC -eq 0 && "$OUT" == *"DCO exempt"* && "$OUT" == *"1 exempt"* ]]; then ok "GitHub-signed dependabot[bot] commit on a dependabot[bot] PR passes, says why, and counts the exemption"; else bad "bot PR rc=$RC out=$OUT"; fi

echo "# the exemption is per commit: a human's unsigned commit pushed onto a Dependabot PR still fails"
add_commit "$R" "human tweak without sign-off"
human_sha=$(git -C "$R" rev-parse HEAD); record "$human_sha" "a-human" "a-human" false
run_step "$R" "dependabot[bot]" pull_request 2
if [[ $RC -ne 0 && "$OUT" == *"$human_sha"* ]]; then ok "unsigned human commit on a dependabot[bot] PR fails and is named"; else bad "human-on-bot-PR rc=$RC out=$OUT"; fi
echo x >> "$R/f"; git -C "$R" add f; git -C "$R" commit -q -s -m "human tweak with sign-off"
# range: bot commit + unsigned human + signed human — still fails on the unsigned one
run_step "$R" "dependabot[bot]" pull_request 3
[[ $RC -ne 0 ]] && ok "a later signed commit does not launder the unsigned one" || bad "laundered rc=$RC out=$OUT"

echo "# the API record decides, not local metadata (author, committer AND signature must all match)"
R="$ROOT/apisays"; new_repo "$R"
add_commit "$R" "looks like the bot" "dependabot[bot]" "49699333+dependabot[bot]@users.noreply.github.com"
s=$(git -C "$R" rev-parse HEAD)
record "$s" "dependabot[bot]" "web-flow" false; run_step "$R" "dependabot[bot]"
[[ $RC -ne 0 && "$OUT" == *"$s"* ]] && ok "bot author + web-flow committer but NOT verified: fails" || bad "unverified passed rc=$RC: $OUT"
record "$s" "a-human" "web-flow" true;          run_step "$R" "dependabot[bot]"
[[ $RC -ne 0 && "$OUT" == *"$s"* ]] && ok "author is not dependabot[bot]: fails" || bad "non-bot author passed rc=$RC: $OUT"
record "$s" "dependabot[bot]" "a-human" true;   run_step "$R" "dependabot[bot]"
[[ $RC -ne 0 && "$OUT" == *"$s"* ]] && ok "forged Dependabot author, verified with the HUMAN's own key (committer is the human): fails (the Codex/Grok finding)" || bad "forged-author human-signed commit passed rc=$RC: $OUT"
record "$s" "dependabot[bot]" "dependabot[bot]" true; run_step "$R" "dependabot[bot]"
[[ $RC -ne 0 && "$OUT" == *"$s"* ]] && ok "committer is not web-flow (even if it claims to be the bot): fails" || bad "non-web-flow committer passed rc=$RC: $OUT"
rm -f "$ROOT/fixture/$s";                       run_step "$R" "dependabot[bot]"
[[ $RC -ne 0 && "$OUT" == *"$s"* ]] && ok "API unreachable: fails closed" || bad "api error passed rc=$RC: $OUT"
record "$s";                                    run_step "$R" "dependabot[bot]"
[[ $RC -eq 0 ]] && ok "control: the same commit passes once the API record is bot + web-flow + verified" || bad "control failed rc=$RC out=$OUT"

echo "# spoof: commits that CLAIM a dependabot author, in a human's PR, still fail"
R="$ROOT/spoof"; new_repo "$R"
add_commit "$R" "pretend to be the bot" "dependabot[bot]" "49699333+dependabot[bot]@users.noreply.github.com"
run_step "$R" "a-human"
[[ $RC -ne 0 ]] && ok "forged commit-author metadata does not earn the exemption (rc=$RC)" || bad "spoofed author passed: $OUT"

echo "# look-alike PR authors still fail"
R="$ROOT/lookalike"; new_repo "$R"; add_commit "$R" "unsigned"
for who in "dependabot-evil[bot]" "Dependabot" "dependabot" "xdependabot[bot]" "dependabot[bot]x" "dependabot[bot] " "" "renovate[bot]"; do
  run_step "$R" "$who"
  [[ $RC -ne 0 ]] && ok "PR author '$who' gets no exemption" || bad "PR author '$who' passed the DCO step: $OUT"
done

echo "# a push event still skips visibly (unchanged behavior)"
run_step "$R" "a-human" "push"
[[ $RC -eq 0 && "$OUT" == *"skipped"* ]] && ok "push event skips with a notice" || bad "push event rc=$RC out=$OUT"

echo "# a multi-commit human PR with one unsigned commit fails and names it"
R="$ROOT/mixed"; new_repo "$R"
echo a >> "$R/f"; git -C "$R" add f; git -C "$R" commit -q -s -m "signed one"
add_commit "$R" "unsigned one"
run_step "$R" "a-human" pull_request 2
bad_sha=$(git -C "$R" rev-parse HEAD)
if [[ $RC -ne 0 && "$OUT" == *"$bad_sha"* ]]; then ok "the unsigned commit is named in the failure"; else bad "mixed rc=$RC out=$OUT"; fi

echo
echo "dco-bot-exemption.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
