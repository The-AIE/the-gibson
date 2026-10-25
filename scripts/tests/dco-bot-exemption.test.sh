#!/usr/bin/env bash
# dco-bot-exemption.test.sh — the DCO step in gibson-self-gate.yml (#554)
#
# WHY
#   The DCO step is inline YAML, so nothing exercised it. This test extracts its
#   `run:` script and executes it against throwaway repositories, which locks both
#   the rule (every commit in a PR carries Signed-off-by) and its one exemption:
#   a pull request AUTHORED by dependabot[bot], whose commits cannot carry a
#   sign-off. The exemption keys on the PR author login (set by GitHub, not
#   forgeable by a contributor), never on commit author metadata (anyone can set
#   any author name), and it names exactly one bot.
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

# run_step DIR PR_AUTHOR [EVENT] — prints output, sets RC
run_step() {
  local dir="$1" author="$2" event="${3:-pull_request}" base head
  base=$(git -C "$dir" rev-parse HEAD~"${NCOMMITS:-1}")
  head=$(git -C "$dir" rev-parse HEAD)
  OUT=$(cd "$dir" && EVENT_NAME="$event" BASE_SHA="$base" HEAD_SHA="$head" PR_AUTHOR="$author" \
        GITHUB_STEP_SUMMARY="$ROOT/summary.md" bash "$STEP" 2>&1)
  RC=$?
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
run_step "$R" "dependabot[bot]"
if [[ $RC -eq 0 && "$OUT" == *"dependabot[bot]"* ]]; then ok "dependabot[bot]-authored PR passes and says why"; else bad "bot PR rc=$RC out=$OUT"; fi

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
NCOMMITS=2 run_step "$R" "a-human"
bad_sha=$(git -C "$R" rev-parse HEAD)
if [[ $RC -ne 0 && "$OUT" == *"$bad_sha"* ]]; then ok "the unsigned commit is named in the failure"; else bad "mixed rc=$RC out=$OUT"; fi

echo
echo "dco-bot-exemption.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
