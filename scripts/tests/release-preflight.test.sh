#!/usr/bin/env bash
# release-preflight.test.sh — sensors for the pre-merge verdict
#
# WHAT IT DOES
#   Runs release-preflight.sh against canned pull requests by putting a fake
#   `gh` on PATH that replays a JSON fixture. No network, no GitHub.
#
# WHY
#   L-013 / L-015 / L-021 / L-033 are judgement calls the release hat got wrong
#   repeatedly. Encoding them in a script only helps if the script's judgement
#   itself is pinned.
#
# USAGE
#   scripts/tests/release-preflight.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PREFLIGHT="$SCRIPT_DIR/../release-preflight.sh"
PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-preflight-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh: `repo view` names a repo, `pr view` replays $GH_FIXTURE.
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "pr view") cat "$GH_FIXTURE" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

# $1 name, then overrides as jq assignments applied to the green baseline.
fixture() {
  local name="$1"; shift
  local f="$ROOT/$name.json"
  jq "$@" > "$f" <<'BASE'
{
  "number": 1, "title": "feat: thing", "isDraft": false, "mergeable": "MERGEABLE",
  "author": {"login": "builder-bot"}, "reviewDecision": "APPROVED",
  "labels": [{"name": "tier-b"}], "closingIssuesReferences": [{"number": 28}],
  "statusCheckRollup": [
    {"__typename": "CheckRun", "name": "gate", "conclusion": "SUCCESS", "steps": [{"name": "lint"}]}
  ],
  "reviews": [], "comments": []
}
BASE
  echo "$f"
}

run() { GH_FIXTURE="$1" "$PREFLIGHT" 1 --repo acme/app ${2:-} 2>&1; }

echo "baseline · a green, approved, tier-B PR is READY"
f=$(fixture green '.')
out=$(run "$f"); rc=$?
check "exit 0" "$rc" "0"
contains "verdict" "$out" "READY"

echo "L-013 · a partial ship that still closes its issue is BLOCKED"
out=$(run "$f" --partial); rc=$?
check "exit 1" "$rc" "1"
contains "names the issue GitHub will close" "$out" "close #28"
contains "explains the linker" "$out" "does not stop the linker"
f_open=$(fixture nonclosing '.closingIssuesReferences = []')
out=$(run "$f_open" --partial); rc=$?
check "partial that closes nothing is READY" "$rc" "0"

echo "L-015 · same-author VERDICT: APPROVE is not a formal review"
f_same=$(fixture same_author '.reviewDecision = "" |
  .comments = [{"author": {"login": "builder-bot"}, "body": "six lenses clear\n\nVERDICT: APPROVE"}]')
out=$(run "$f_same"); rc=$?
check "exit 4 (ADMIN-CANDIDATE)" "$rc" "4"
contains "explains self-approval block" "$out" "GitHub blocks self-approval"
contains "prefers a cross-vendor identity" "$out" "REVIEWER_CMD"
contains "prints the checklist" "$out" "security CLEAR"

f_other=$(fixture other_reviewer '.reviewDecision = "" |
  .comments = [{"author": {"login": "reviewer-bot"}, "body": "VERDICT: APPROVE"}]')
out=$(run "$f_other"); rc=$?
check "independent VERDICT: APPROVE is READY" "$rc" "0"

f_reject=$(fixture rejected '.reviewDecision = "" |
  .comments = [{"author": {"login": "reviewer-bot"}, "body": "VERDICT: REQUEST_CHANGES"}]')
out=$(run "$f_reject"); rc=$?
check "REQUEST_CHANGES blocks" "$rc" "1"

f_none=$(fixture unreviewed '.reviewDecision = ""')
out=$(run "$f_none"); rc=$?
check "no review at all blocks (fail closed)" "$rc" "1"
contains "cites Law 5" "$out" "Law 5"

echo "L-033 · infra red is not product red"
f_infra=$(fixture infra '.statusCheckRollup = [
  {"__typename": "CheckRun", "name": "gate", "conclusion": "STARTUP_FAILURE", "steps": []},
  {"__typename": "CheckRun", "name": "security", "conclusion": "FAILURE", "steps": []}]')
out=$(run "$f_infra"); rc=$?
check "exit 4 (ADMIN-CANDIDATE)" "$rc" "4"
contains "names the infra signature" "$out" "startup_failure / no steps / no runner"
contains "forbids claiming green" "$out" "Never report it as remote green"

f_product=$(fixture product '.statusCheckRollup = [
  {"__typename": "CheckRun", "name": "gate", "conclusion": "FAILURE", "steps": [{"name": "test"}]}]')
out=$(run "$f_product"); rc=$?
check "a step that actually failed blocks" "$rc" "1"
contains "says fix the code" "$out" "fix the code"

f_pending=$(fixture pending '.statusCheckRollup = [
  {"__typename": "CheckRun", "name": "gate", "conclusion": null, "steps": []}]')
out=$(run "$f_pending"); rc=$?
check "pending checks block" "$rc" "1"

echo "Law 7 / posture · no admin path for Tier C or post-launch"
f_tierc=$(fixture tierc '.labels = [{"name": "tier-c"}] |
  .statusCheckRollup = [{"__typename": "CheckRun", "name": "gate", "conclusion": "STARTUP_FAILURE", "steps": []}]')
out=$(run "$f_tierc"); rc=$?
check "tier-c downgrades ADMIN-CANDIDATE to BLOCKED" "$rc" "1"
contains "cites the human gate" "$out" "human merge gate"

out=$(run "$f_infra" --launched); rc=$?
check "--launched removes the admin path" "$rc" "1"
contains "says escalate" "$out" "escalate to the owner"

echo "hygiene · drafts and conflicts block"
f_draft=$(fixture draft '.isDraft = true | .mergeable = "CONFLICTING"')
out=$(run "$f_draft"); rc=$?
check "exit 1" "$rc" "1"
contains "draft" "$out" "PR is a draft"
contains "conflict" "$out" "conflicts with the base"

echo "--json · machine-readable for a driver"
out=$(GH_FIXTURE="$f_infra" "$PREFLIGHT" 1 --repo acme/app --json 2>&1)
check "verdict field" "$(echo "$out" | jq -r .verdict)" "ADMIN-CANDIDATE"
check "blockers empty" "$(echo "$out" | jq -r '.blockers | length')" "0"
check "admin_reasons populated" "$(echo "$out" | jq -r '.admin_reasons | length')" "1"

echo
echo "release-preflight.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
