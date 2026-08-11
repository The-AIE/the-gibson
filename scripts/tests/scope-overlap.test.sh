#!/usr/bin/env bash
# scope-overlap.test.sh — independent-set claim scope sensor (#106)
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
SENSOR="$SCRIPT_DIR/../scope-overlap.mjs"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
# Negative assertion, ACCOUNTED (#153 review round 5). The suite previously
# called an undefined `lacks` here: bash printed "lacks: command not found",
# the assertion never ran, and neither PASS nor FAIL moved — a shell error
# sitting quietly underneath a green tally. Same signature and semantics as
# the `lacks` in claim.test.sh and release-claim.test.sh, so a reader moving
# between the three suites does not have to check which one this is.
lacks() { if echo "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }
# …and the ratchet for the class, not just the instance. bash calls this hook
# when a command name does not resolve, so a mistyped or not-yet-written
# assertion becomes a COUNTED failure instead of a stderr line the tally never
# hears about. Returning 127 keeps the original exit status, so nothing that
# already reasons about "command not found" changes behaviour. (bash 4+; on
# bash 3.2 the hook simply never fires, which is no worse than before.)
command_not_found_handle() {
  bad "the suite invoked an undefined command '$1' — a shell error may never coexist with a green tally"
  return 127
}

command -v node >/dev/null || { echo "scope-overlap.test.sh: node required"; exit 1; }
command -v git  >/dev/null || { echo "scope-overlap.test.sh: git required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-scope-overlap.XXXXXX")
trap 'rm -rf -- "${ROOT:?}"' EXIT
GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

# --- the patched TEST COPY (#153 review round 4, P1) ------------------------
# Production's read spacing is an internal, un-interposable wait, which means
# a sensor can no longer make it free from the outside — and it should not be
# able to. Broad fixtures whose subject is the DECISION (which claim wins, what
# refuses, what a malformed row does) run against an explicitly patched copy
# instead: one surgical substitution that removes the blocking call and
# nothing else, so every other check in the barrier — the safe-integer test,
# the floor, the quiescence streak, the self-visibility requirement — is the
# production code path.
#
# The substitution is VERIFIED. If production stops looking like this, the
# patch stops matching and the suite fails loudly here rather than silently
# reverting to testing a copy that no longer resembles the real thing.
FASTDIR="$ROOT/fast"
mkdir -p "$FASTDIR"
SENSOR_FAST="$FASTDIR/scope-overlap.mjs"
# pr-claims.sh is resolved next to the sensor on purpose (that binding is its
# trust boundary), so the copy needs its own reader alongside it.
cp "$SCRIPT_DIR/../pr-claims.sh" "$FASTDIR/pr-claims.sh"
chmod +x "$FASTDIR/pr-claims.sh"
# The substitution replaces the marked body of blockAtLeast() — the wait AND
# the monotonic measurement that verifies it (#153 review round 5) — with an
# honest "the full delay elapsed". It has to take both: spaceReads now refuses
# unless the measured elapsed time really reaches the configured delay, so
# removing only the blocking call would make every fast fixture fail the
# barrier instead of skipping it. Everything outside the markers — the
# safe-integer test, the floor, the maxima, the quiescence streak, the
# self-visibility requirement, the elapsed comparison in spaceReads itself —
# is still the production code path.
awk '
  /GIBSON_BARRIER_WAIT_BEGIN/ { print "  return ms;  /* TEST COPY: blocking removed */"; skip = 1; next }
  /GIBSON_BARRIER_WAIT_END/   { skip = 0; next }
  !skip                       { print }
' "$SENSOR" > "$SENSOR_FAST"
# The CALL must be gone, not merely the word: the surrounding comments name
# Atomics.wait several times and would otherwise mask a failed substitution.
# The monotonic read has to be gone from the copy too, for the same reason.
if grep -q 'TEST COPY: blocking removed' "$SENSOR_FAST" &&
   ! grep -q 'Atomics\.wait(cell' "$SENSOR_FAST" &&
   ! grep -q 'hrtime\.bigint(' "$SENSOR_FAST"; then
  ok "the test copy patched out exactly the blocking wait (production shape unchanged)"
else
  bad "could not patch the test copy — production spaceReads no longer matches the expected shape; refusing to pretend these fixtures exercise the barrier"
fi
node --check "$SENSOR_FAST" 2>/dev/null &&
  ok "the patched test copy is still valid JavaScript" ||
  bad "the patched test copy does not parse"

# Bare origin + clone (mirrors claim fixtures)
setup_repo() {
  local name="$1"
  rm -rf -- "${ROOT:?}/${name:?}"
  mkdir -p "$ROOT/$name"
  $GIT init -q --bare "$ROOT/$name/origin"
  git -C "$ROOT/$name/origin" symbolic-ref HEAD refs/heads/main
  $GIT clone -q "$ROOT/$name/origin" "$ROOT/$name/canon" 2>/dev/null
  mkdir -p "$ROOT/$name/canon/docs/claims"
  (
    cd "$ROOT/$name/canon" || exit 1
    cat > docs/claims/issue-7-password-reset.md <<'C'
claim: issue-7-password-reset
issue: 7
claimed: 2026-08-01T10:00:00Z
scope: app/api/auth/**
session: grok@fleet
branch: feat/7-password-reset
worktree: /tmp/wt-7
C
    # (#153 exact-head) Mixed per-file + legacy for the same id is refuse,
    # never silent prefer-file. Issue-7 lives only as per-file; issue-9 is
    # legacy-only. Do not put issue-7 in the table.
    cat > docs/active-work.md <<'T'
| UTC | claim-id | scope | session |
|---|---|---|---|
| 2026-08-01T11:00:00Z | issue-9-legacy-only | src/legacy/** | other@fleet |
T
    echo base > README.md
    $GIT add -A
    $GIT commit -q -m "ledger"
    $GIT branch -M main
    $GIT push -q -u origin main
  ) >/dev/null 2>&1
  # pure legacy claim without file form
  (
    cd "$ROOT/$name/canon" || exit 1
    rm -f docs/claims/issue-9-legacy-only.md
    $GIT add -A
    $GIT commit -q -m "legacy row" --allow-empty 2>/dev/null || true
    cat > docs/active-work.md <<'T'
| UTC | claim-id | scope | session |
|---|---|---|---|
| 2026-08-01T11:00:00Z | issue-9-legacy-only | src/legacy/** | other@fleet |
T
    $GIT add docs/active-work.md
    $GIT commit -q -m "legacy table"
    $GIT push -q origin main
  ) >/dev/null 2>&1
}

# Broad fixtures: the patched test copy. Their subject is the admission
# DECISION, and paying the real barrier wait once per case would add minutes
# to the suite while proving nothing the focused barrier sensors below do not
# already prove. Non-admission runs never wait at all, so they are unaffected
# either way.
run_so() {
  local repo="$1"; shift
  node "$SENSOR_FAST" --repo-path "$repo" --base main "$@" 2>&1
}

# Focused barrier sensors: the REAL production file, paying the REAL minimum
# wait. Nothing here is accelerated, because what these assert is the wait.
run_so_prod() {
  local repo="$1"; shift
  node "$SENSOR" --repo-path "$repo" --base main "$@" 2>&1
}

echo "help / usage"
out=$(node "$SENSOR" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'WHAT IT DOES' && ok "help" || bad "help rc=$rc"
out=$(node "$SENSOR" 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && ok "no-args exits 2" || bad "no-args $rc"

echo "overlapping scope refused"
setup_repo a
out=$(run_so "$ROOT/a/canon" --scope 'app/api/auth/login.ts'); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-7-password-reset' && ok "overlap with file claim" \
  || bad "overlap (rc=$rc): $out"

echo "disjoint scope allowed"
out=$(run_so "$ROOT/a/canon" --scope 'components/nav/**'); rc=$?
[[ "$rc" -eq 0 ]] && ok "disjoint scope OK" || bad "disjoint (rc=$rc): $out"

echo "legacy-row overlap detected"
out=$(run_so "$ROOT/a/canon" --scope 'src/legacy/foo.ts'); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-9-legacy-only' && ok "legacy overlap" \
  || bad "legacy (rc=$rc): $out"

echo "exact same glob refused"
out=$(run_so "$ROOT/a/canon" --scope 'app/api/auth/**'); rc=$?
[[ "$rc" -ne 0 ]] && ok "exact glob overlap" || bad "exact (rc=$rc): $out"

echo "self claim-id excluded"
out=$(run_so "$ROOT/a/canon" --scope 'app/api/auth/**' --claim-id issue-7-password-reset); rc=$?
[[ "$rc" -eq 0 ]] && ok "self excluded via --claim-id" || bad "self (rc=$rc): $out"

echo "fetch-failure refuses"
# Point at a repo whose origin is broken
setup_repo b
(
  cd "$ROOT/b/canon" || exit 1
  git remote set-url origin /nonexistent/path/to/origin
)
out=$(run_so "$ROOT/b/canon" --scope 'anything/**'); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'fetch|refuse' && ok "fetch failure refuses" \
  || bad "fetch fail (rc=$rc): $out"

echo "json mode on overlap"
setup_repo c
out=$(run_so "$ROOT/c/canon" --scope 'app/api/**' --json); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q '"ok": false' && ok "json overlap" \
  || bad "json (rc=$rc): $out"

echo "claim.sh sources sensor (static)"
if grep -q 'scope-overlap.mjs' "$SCRIPT_DIR/../claim.sh" \
  && grep -q 'cannot fetch origin' "$SCRIPT_DIR/../claim.sh"; then
  ok "claim.sh wires scope-overlap + fail-closed fetch"
else
  bad "claim.sh missing #106 wire-in"
fi

# --- #153 AC2: live open PR-body claims join the overlap check via --repo ---
# Fake gh stands in for pr-claims.sh's `gh api graphql --paginate -f query=...
# --jq ...` call: it prints whatever TSV the test staged, ignoring the real
# flags, so the fixture controls exactly what pr-claims.sh (and thus this
# sensor) sees.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "api graphql")
    cat "${GH_PR_TSV:-/dev/null}" 2>/dev/null
    exit "${GH_PR_EXIT:-0}"
    ;;
esac
exit 1
GH
chmod +x "$ROOT/bin/gh"
# HOSTILE `sleep` sentinel (#153 review round 4, P1).
#
# The barrier used to space its reads with `execFileSync("sleep", …)`, which
# resolves an executable through PATH — so anyone able to put a directory in
# front of PATH could collapse the whole publication barrier to back-to-back
# samples taken in the same instant. That is not a test seam, it is an
# execution path chosen by the environment.
#
# So this is no longer a helpful shim that makes the wait free. It is a
# TRIPWIRE: if production ever executes a PATH `sleep` again, this records the
# call and the assertions below fail. It deliberately exits 0 immediately, so
# a regression would *also* show up as the suite getting suspiciously fast
# while the sentinel file fills up.
export SLEEP_SENTINEL="$ROOT/sleep-sentinel"
rm -f "$SLEEP_SENTINEL"
cat > "$ROOT/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
echo "sleep $*" >> "${SLEEP_SENTINEL:-/dev/null}"
exit 0
SLEEP
chmod +x "$ROOT/bin/sleep"
export PATH="$ROOT/bin:$PATH"

setup_repo d
GH_PR_TSV="$ROOT/pr-open.tsv"
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
export GH_PR_TSV
unset GH_PR_EXIT

echo "cross-issue live PR-body claim is refused (#153)"
out=$(run_so "$ROOT/d/canon" --scope 'components/nav/Item.tsx' --repo acme/app --claim-id issue-21-nav-tweak --issue 21); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-20-nav-shell' && ok "cross-issue PR-body overlap refused" \
  || bad "cross-issue PR-body overlap (rc=$rc): $out"

echo "disjoint scope coexists with a live PR-body claim on a different issue (#153)"
out=$(run_so "$ROOT/d/canon" --scope 'app/billing/**' --repo acme/app --claim-id issue-22-billing --issue 22); rc=$?
[[ "$rc" -eq 0 ]] && ok "disjoint PR-body claim coexists" || bad "disjoint PR-body (rc=$rc): $out"

echo "no --repo => PR-body claims are not consulted (back-compat)"
out=$(run_so "$ROOT/d/canon" --scope 'components/nav/Item.tsx'); rc=$?
[[ "$rc" -eq 0 ]] && ok "omitting --repo keeps ledger-only behavior" || bad "no --repo (rc=$rc): $out"

echo "malformed/truncated PR-claim row fails closed (#153)"
printf '502\tissue-31-broken\tsrc/x/**\n' > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo acme/app --claim-id issue-32-x); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'malformed|truncated' && ok "malformed PR row refuses" \
  || bad "malformed PR row (rc=$rc): $out"

echo "duplicate PR-claim id across two PRs fails closed (#153)"
{
  printf '601\tissue-33-dup\tsrc/a/**\tfeat/33-dup\thttps://github.com/acme/app/pull/601\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
  printf '602\tissue-33-dup\tsrc/b/**\tfeat/33-dup-2\thttps://github.com/acme/app/pull/602\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
} > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo acme/app --claim-id issue-34-x); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'duplicate' && ok "duplicate PR-claim id refuses" \
  || bad "duplicate PR-claim id (rc=$rc): $out"

echo "gh/pr-claims failure fails closed when --repo was given (#153)"
export GH_PR_EXIT=1
out=$(run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo acme/app --claim-id issue-35-x); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'cannot read live PR-body claims|refuse' && ok "gh failure refuses" \
  || bad "gh failure (rc=$rc): $out"
unset GH_PR_EXIT

echo "malformed --repo shape is rejected before any query (#153)"
out=$(run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo 'not-a-repo'); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -qi "owner/name" && ok "malformed --repo rejected" \
  || bad "malformed --repo (rc=$rc): $out"

echo "missing/empty claim scope on a live PR-body claim fails closed (#153 AC6)"
printf '701\tissue-40-empty-scope\t\tfeat/40-empty-scope\thttps://github.com/acme/app/pull/701\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo acme/app --claim-id issue-41-x); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'missing/empty claim scope' && ok "missing scope refuses (never silently empty)" \
  || bad "missing scope (rc=$rc): $out"

echo "missing/unsafe head branch on a live PR-body claim fails closed (#153 AC6)"
printf '702\tissue-42-bad-branch\tsrc/a/**\t\thttps://github.com/acme/app/pull/702\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo acme/app --claim-id issue-43-x); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'missing/unsafe head branch' && ok "missing branch refuses" \
  || bad "missing branch (rc=$rc): $out"

echo "PR URL repository mismatch vs --repo fails closed (#153 AC3)"
printf '703\tissue-44-wrong-repo\tsrc/a/**\tfeat/44-wrong-repo\thttps://github.com/other-org/other-app/pull/703\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo acme/app --claim-id issue-45-x); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'unexpected repository identity' && ok "URL-repo mismatch refuses" \
  || bad "URL-repo mismatch (rc=$rc): $out"
# Reset fixture for anything appended after this block.
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"

# --- #153 blocker 6: exercise pr-claims.sh's OWN jq validation, not just its
# output-row shape. The fake gh above bypasses jq entirely (it hands
# scope-overlap.mjs pre-baked TSV as if pr-claims.sh already emitted it), so
# it can never catch a duplicate marker *inside* a PR body. This fake gh
# instead returns real PR JSON and lets the real jq inside pr-claims.sh run.
echo "duplicate Active-work claim marker inside one PR body propagates through the real pr-claims.sh jq pipeline (#153 blocker 6)"
mkdir -p "$ROOT/bin-json"
cat > "$ROOT/bin-json/gh" <<'GHJSON'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  shift 2
  jqexpr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jq) jqexpr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  jq -r "$jqexpr" < "${GH_JSON:?GH_JSON not set}"
  exit $?
fi
exit 1
GHJSON
chmod +x "$ROOT/bin-json/gh"
GH_JSON="$ROOT/dupbody.json"
printf '{"data":{"repository":{"pullRequests":{"nodes":[{"number":950,"body":"- Active-work claim: issue-50-dup-body\\n- Active-work claim: issue-50-dup-body\\n- Claim scope: unrelated/dup/**\\n- Issue: #50","headRefName":"feat/50-dup-body","url":"https://github.com/acme/app/pull/950","createdAt":"2026-08-05T00:00:00Z","updatedAt":"2026-08-06T00:00:00Z"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  > "$GH_JSON"
out=$(PATH="$ROOT/bin-json:$PATH" GH_JSON="$GH_JSON" run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo acme/app --claim-id issue-51-x); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'duplicate|cannot read live PR-body claims|refuse' \
  && ok "duplicate-in-body propagates to scope-overlap.mjs fail-closed" \
  || bad "duplicate-in-body (rc=$rc): $out"

# --- #153 review P1: --admit-pr, the post-create admission decision ---------
# The pre-create check cannot see a lane that has not published its claim yet.
# --admit-pr re-runs the same overlap check once THIS lane's PR exists and
# resolves the race deterministically on PR number, so two racers reading the
# same evidence always agree on who survives.
echo "--admit-pr · a LOWER-numbered overlapping PR claim refuses this lane"
{
  printf '800\tissue-60-shared-lib\tlib/shared/**\tfeat/60-shared-lib\thttps://github.com/acme/app/pull/800\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
  printf '801\tissue-61-shared-util\tlib/shared/util.ts\tfeat/61-shared-util\thttps://github.com/acme/app/pull/801\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
} > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'lib/shared/util.ts' --repo acme/app --claim-id issue-61-shared-util --issue 61 --admit-pr 801); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-60-shared-lib' && ok "later lane stands down for the lower PR number" \
  || bad "later lane was admitted (rc=$rc): $out"
echo "$out" | grep -qi 'admission refused' && ok "names the admission refusal" || bad "no admission wording: $out"

echo "--admit-pr · a HIGHER-numbered overlapping PR claim yields to this lane"
out=$(run_so "$ROOT/d/canon" --scope 'lib/shared/**' --repo acme/app --claim-id issue-60-shared-lib --issue 60 --admit-pr 800); rc=$?
[[ "$rc" -eq 0 ]] && ok "earlier lane is admitted over the later one" || bad "earlier lane refused (rc=$rc): $out"
echo "$out" | grep -q 'yields to PR #800' && ok "names the yielding lane" || bad "no yield wording: $out"

echo "--admit-pr · exactly one of two racing lanes is admitted"
rc_low=0; rc_high=0
run_so "$ROOT/d/canon" --scope 'lib/shared/**' --repo acme/app --claim-id issue-60-shared-lib --issue 60 --admit-pr 800 >/dev/null 2>&1 || rc_low=$?
run_so "$ROOT/d/canon" --scope 'lib/shared/util.ts' --repo acme/app --claim-id issue-61-shared-util --issue 61 --admit-pr 801 >/dev/null 2>&1 || rc_high=$?
survivors=0
[[ "$rc_low" -eq 0 ]] && survivors=$((survivors + 1))
[[ "$rc_high" -eq 0 ]] && survivors=$((survivors + 1))
[[ "$survivors" -eq 1 ]] && ok "exactly one lane survives the same evidence" \
  || bad "both/neither lane survived (low=$rc_low high=$rc_high)"

echo "--admit-pr · an inventory that cannot see this lane's own claim refuses it"
out=$(run_so "$ROOT/d/canon" --scope 'lib/shared/**' --repo acme/app --claim-id issue-62-invisible --issue 62 --admit-pr 999); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'is not in the live claim inventory' \
  && echo "$out" | grep -qiE 'could not obtain a stable (live-claim|combined PR\+ledger claim) inventory' \
  && ok "invisible own claim refuses" \
  || bad "invisible own claim admitted (rc=$rc): $out"

echo "--admit-pr · a LEDGER claim always beats an admission candidate"
printf '810\tissue-63-ledger-race\tapp/api/auth/**\tfeat/63-ledger-race\thttps://github.com/acme/app/pull/810\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'app/api/auth/**' --repo acme/app --claim-id issue-63-ledger-race --issue 63 --admit-pr 810); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-7-password-reset' && ok "ledger claim beats the admission candidate" \
  || bad "ledger claim did not refuse admission (rc=$rc): $out"

echo "--admit-pr · usage errors are refused before any query"
out=$(run_so "$ROOT/d/canon" --scope 'x/**' --repo acme/app --claim-id issue-64-x --admit-pr 'abc'); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -qi 'pull-request number' && ok "non-numeric --admit-pr rejected" \
  || bad "non-numeric --admit-pr (rc=$rc): $out"
out=$(run_so "$ROOT/d/canon" --scope 'x/**' --claim-id issue-64-x --admit-pr 810); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -qi 'requires --repo' && ok "--admit-pr without --repo rejected" \
  || bad "--admit-pr without --repo (rc=$rc): $out"
out=$(run_so "$ROOT/d/canon" --scope 'x/**' --repo acme/app --admit-pr 810); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -qi 'requires --claim-id' && ok "--admit-pr without --claim-id rejected" \
  || bad "--admit-pr without --claim-id (rc=$rc): $out"

# --- #153 review round 3, P1: there is NO forged-evidence path --------------
# The previous head let a caller hand the admission decision an inventory
# (`--pr-claims-file`). That is a production command surface on which a
# fabricated empty or self-only inventory bought a green admission over a live
# conflicting claim. No cross-process handoff of caller-supplied data can be
# made unforgeable without a shared secret, so the option is gone and the
# admission reads happen inside the process that decides. These are HOSTILE
# tests: they try to smuggle an inventory in and must all fail.
echo "#153 · a forged inventory cannot bypass a live conflicting claim"
# A real, live, LOWER-numbered conflicting claim. Any run below that comes back
# green has been fooled.
# The rival's scope collides with this lane and with NOTHING in the ledger, so
# a green result can only mean the forged inventory replaced the live read —
# a ledger overlap would refuse for the wrong reason and prove nothing.
{
  printf '640\tissue-65-settled\tlib/gate/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
  printf '700\tissue-66-late\tlib/gate/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
} > "$GH_PR_TSV"

# The forgeries: an empty inventory, and one containing only this lane.
FORGED_EMPTY="$ROOT/forged-empty.tsv"
: > "$FORGED_EMPTY"
FORGED_SELF="$ROOT/forged-self.tsv"
printf '700\tissue-66-late\tlib/gate/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$FORGED_SELF"

for forged in "$FORGED_EMPTY" "$FORGED_SELF"; do
  fname=$(basename "$forged")
  for flag in --pr-claims-file --claims-file --inventory --inventory-file --rows-file --pr-claims; do
    out=$(run_so "$ROOT/d/canon" --scope 'lib/gate/handlers.ts' --repo acme/app \
      --claim-id issue-66-late --issue 66 --admit-pr 700 "$flag" "$forged"); rc=$?
    if [[ "$rc" -ne 0 ]]; then
      ok "$flag with $fname is refused (rc=$rc)"
    else
      bad "$flag with $fname was ADMITTED over a live conflicting claim: $out"
    fi
  done
  # …and on stdin, in case the option was replaced by a pipe.
  out=$(run_so "$ROOT/d/canon" --scope 'lib/gate/handlers.ts' --repo acme/app \
    --claim-id issue-66-late --issue 66 --admit-pr 700 < "$forged"); rc=$?
  [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-65-settled' \
    && ok "stdin $fname is ignored; the live conflicting claim still refuses" \
    || bad "stdin $fname changed the verdict (rc=$rc): $out"
done

# The admission decision really is driven by the LIVE read: same arguments,
# same forged files on disk, and the verdict flips only when the live
# inventory itself stops carrying the rival.
out=$(run_so "$ROOT/d/canon" --scope 'lib/gate/handlers.ts' --repo acme/app \
  --claim-id issue-66-late --issue 66 --admit-pr 700); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-65-settled' \
  && ok "the live inventory alone decides admission" \
  || bad "live admission verdict wrong (rc=$rc): $out"
printf '700\tissue-66-late\tlib/gate/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'lib/unrelated/**' --repo acme/app \
  --claim-id issue-66-late --issue 66 --admit-pr 700); rc=$?
[[ "$rc" -eq 0 ]] && ok "a genuinely self-only LIVE inventory admits the lane" \
  || bad "self-only live inventory refused (rc=$rc): $out"

echo "#153 · the source carries no caller-supplied-inventory path at all"
# Static contract sensor: the runtime tests above can only probe the flag names
# someone thought of. This one says the capability is absent — the sensor reads
# no file and no stdin for its evidence, it executes the pr-claims.sh next to
# it. A future re-introduction fails here even under a name nobody guessed.
if grep -q 'readFileSync' "$SENSOR"; then
  bad "scope-overlap.mjs reads a file — a caller-supplied inventory path may be back"
else
  ok "scope-overlap.mjs never reads a file for its claim evidence"
fi
if grep -qE 'process\.stdin|/dev/stdin|readSync\(0' "$SENSOR"; then
  bad "scope-overlap.mjs reads stdin — evidence could be piped in"
else
  ok "scope-overlap.mjs never reads stdin"
fi
if grep -q 'resolve(__dirname, "pr-claims.sh")' "$SENSOR"; then
  ok "the only claim reader is the pr-claims.sh sitting next to the sensor"
else
  bad "scope-overlap.mjs no longer binds its reader to its own directory"
fi

# --- #153 review round 3, P1: the barrier has a production floor ------------
echo "#153 · the publication barrier cannot be weakened from the environment"
printf '640\tissue-65-settled\tapp/api/auth/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
floor_case() { # label VAR=value expect-substring
  local label="$1" assign="$2" want="$3" out rc
  out=$(env "$assign" node "$SENSOR" --repo-path "$ROOT/d/canon" --base main \
    --scope 'lib/unrelated/**' --repo acme/app --claim-id issue-65-settled \
    --issue 65 --admit-pr 640 2>&1); rc=$?
  if [[ "$rc" -eq 2 ]] && echo "$out" | grep -qF "$want"; then
    ok "$label"
  else
    bad "$label (rc=$rc): $out"
  fi
}
floor_case "STABLE_READS=1 is refused, not honoured" \
  GIBSON_CLAIM_ADMIT_STABLE_READS=1 "below the production minimum of 2"
floor_case "STABLE_READS=0 is refused" \
  GIBSON_CLAIM_ADMIT_STABLE_READS=0 "below the production minimum of 2"
floor_case "DELAY=0 is refused, not honoured" \
  GIBSON_CLAIM_ADMIT_DELAY=0 "below the production minimum of 1"
floor_case "ATTEMPTS=1 is refused" \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=1 "below the production minimum of 2"
floor_case "a non-numeric barrier value is refused" \
  GIBSON_CLAIM_ADMIT_STABLE_READS=nope "must be a non-negative integer"
# …and the floor refuses BEFORE any decision: the same run that would have been
# admitted on a single sample never gets one.
out=$(GIBSON_CLAIM_ADMIT_STABLE_READS=1 run_so "$ROOT/d/canon" --scope 'lib/unrelated/**' \
  --repo acme/app --claim-id issue-65-settled --issue 65 --admit-pr 640); rc=$?
[[ "$rc" -eq 2 ]] && ! echo "$out" | grep -q 'quiescent' \
  && ok "a below-floor barrier never reaches the admission decision" \
  || bad "below-floor barrier still decided (rc=$rc): $out"
# Raising the barrier is allowed.
out=$(GIBSON_CLAIM_ADMIT_STABLE_READS=4 GIBSON_CLAIM_ADMIT_ATTEMPTS=8 \
  GIBSON_CLAIM_ADMIT_DELAY=1 run_so "$ROOT/d/canon" --scope 'lib/unrelated/**' \
  --repo acme/app --claim-id issue-65-settled --issue 65 --admit-pr 640); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '4 consecutive matching read' \
  && ok "the barrier may be RAISED" || bad "raising the barrier failed (rc=$rc): $out"
out=$(GIBSON_CLAIM_ADMIT_STABLE_READS=4 GIBSON_CLAIM_ADMIT_ATTEMPTS=3 \
  run_so "$ROOT/d/canon" --scope 'lib/unrelated/**' --repo acme/app \
  --claim-id issue-65-settled --issue 65 --admit-pr 640); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -q 'cannot be smaller than' \
  && ok "an unsatisfiable barrier is a usage error" || bad "unsatisfiable barrier (rc=$rc): $out"

echo "#153 · admission decides only on a QUIESCENT inventory"
# A rival that only becomes visible AFTER this lane's own row is already there
# is exactly the eventual-consistency case a single sample misses.
mkdir -p "$ROOT/bin-lag"
cat > "$ROOT/bin-lag/gh" <<'LAGGH'
#!/usr/bin/env bash
# Read counter in a file: each `pr-claims.sh list` is its own process.
n=$(cat "$LAG_READS" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$LAG_READS"
if [[ -n "${LAG_CHURN:-}" ]]; then
  # Never settles: every read differs.
  printf '700\tissue-66-late\tapp/api/auth/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
  printf '%s\tissue-%s-churn\tlib/churn-%s/**\tfeat/%s-churn\thttps://github.com/acme/app/pull/%s\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
    "$((900 + n))" "$((800 + n))" "$n" "$((800 + n))" "$((900 + n))"
  exit 0
fi
printf '700\tissue-66-late\tapp/api/auth/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
if [[ "$n" -ge "${LAG_RIVAL_AFTER:-3}" ]]; then
  printf '640\tissue-65-settled\tapp/api/auth/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
fi
exit 0
LAGGH
chmod +x "$ROOT/bin-lag/gh"
cp "$ROOT/bin/sleep" "$ROOT/bin-lag/sleep"
export LAG_READS="$ROOT/lag-reads"
rm -f "$LAG_READS"
out=$(PATH="$ROOT/bin-lag:$PATH" LAG_RIVAL_AFTER=3 \
  GIBSON_CLAIM_ADMIT_STABLE_READS=3 GIBSON_CLAIM_ADMIT_ATTEMPTS=8 \
  run_so "$ROOT/d/canon" --scope 'app/api/auth/handlers.ts' --repo acme/app \
  --claim-id issue-66-late --issue 66 --admit-pr 700); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-65-settled' \
  && ok "a rival visible only after this lane's own row still refuses it" \
  || bad "late rival was missed (rc=$rc): $out"
rm -f "$LAG_READS"
out=$(PATH="$ROOT/bin-lag:$PATH" LAG_CHURN=1 \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=4 \
  run_so "$ROOT/d/canon" --scope 'lib/unrelated/**' --repo acme/app \
  --claim-id issue-66-late --issue 66 --admit-pr 700); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'could not obtain a stable (live-claim|combined PR\+ledger claim) inventory' \
  && ok "an inventory that never settles refuses rather than guesses" \
  || bad "unsettled inventory admitted (rc=$rc): $out"
unset LAG_READS

echo "#153 · admission refuses a second lane on the SAME issue without --slice"
{
  printf '640\tissue-65-settled\tlib/one/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
  printf '700\tissue-65-other\tlib/two/**\tfeat/65-other\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n'
} > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'lib/two/**' --repo acme/app \
  --claim-id issue-65-other --issue 65 --admit-pr 700); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue #65 is already held' \
  && ok "disjoint scopes do not license two lanes on one issue" \
  || bad "same-issue second lane admitted (rc=$rc): $out"
out=$(run_so "$ROOT/d/canon" --scope 'lib/one/**' --repo acme/app \
  --claim-id issue-65-settled --issue 65 --admit-pr 640); rc=$?
[[ "$rc" -eq 0 ]] && ok "the lower-numbered same-issue lane is admitted" \
  || bad "lower same-issue lane refused (rc=$rc): $out"
out=$(run_so "$ROOT/d/canon" --scope 'lib/two/**' --repo acme/app --slice \
  --claim-id issue-65-other --issue 65 --admit-pr 700); rc=$?
[[ "$rc" -eq 0 ]] && ok "--slice permits the disjoint same-issue sibling" \
  || bad "--slice same-issue sibling refused (rc=$rc): $out"
out=$(run_so "$ROOT/d/canon" --scope 'x/**' --repo acme/app --claim-id issue-65-other --admit-pr 700); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -qi 'requires --issue' \
  && ok "--admit-pr without --issue is refused" || bad "--admit-pr without --issue (rc=$rc): $out"

# Reset the fixture for anything appended after this block.
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"

# ===========================================================================
# #153 review round 4, P1 — the barrier's spacing is INTERNAL
# ===========================================================================
# The wait used to be `execFileSync("sleep", …)`, i.e. an executable resolved
# through the caller's PATH. That made the publication barrier — the whole
# reason admission is not decided on one sample — switchable off by anyone who
# could prepend a directory to PATH. These sensors pin that it is gone: a
# static contract check on the source, a hostile PATH sentinel that must never
# fire, and a wall-clock measurement that the real wait really is taken.

echo "#153 round 4 · production never resolves a 'sleep' executable through PATH"
# Comments in the file explain the removed `execFileSync("sleep", …)` by name,
# so the static check has to look at CODE. Strip line and block comment lines
# first; what is left is what actually runs.
SENSOR_CODE="$ROOT/sensor-code-only.js"
grep -vE '^[[:space:]]*(\*|//|/\*)' "$SENSOR" > "$SENSOR_CODE"
if grep -nE 'execFileSync\([[:space:]]*"sleep"|spawnSync\([[:space:]]*"sleep"|"/bin/sleep"|execSync\(.*sleep' "$SENSOR_CODE"; then
  bad "scope-overlap.mjs executes a 'sleep' command — the barrier is PATH-controllable again"
else
  ok "scope-overlap.mjs executes no 'sleep' command at all"
fi
if grep -q 'Atomics\.wait(cell' "$SENSOR_CODE"; then
  ok "the barrier blocks on an internal Atomics.wait, not an external process"
else
  bad "scope-overlap.mjs no longer uses the internal wait — check what replaced it"
fi
# The wait must not be reachable from an env var naming an executable either.
if grep -nE 'process\.env\[[^]]*\][[:space:]]*\|\|[[:space:]]*"sleep"|env\.[A-Z_]*SLEEP|GIBSON_[A-Z_]*SLEEP' "$SENSOR_CODE"; then
  bad "scope-overlap.mjs reads an environment variable that names a wait command"
else
  ok "no environment variable names the wait command"
fi

echo "#153 round 4 · a HOSTILE 'sleep' on PATH is never executed by production"
# $ROOT/bin (first on PATH for this whole suite) holds a `sleep` that records
# every invocation. A real admission run through the production sensor must
# leave it untouched. This is the runtime counterpart to the static check
# above: it would catch a re-introduction under any name that still ends up
# executing `sleep`.
setup_repo s
printf '640\tissue-65-settled\tlib/sentinel/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
rm -f "$SLEEP_SENTINEL"
# Real production sensor, real minimum barrier: 2 stable reads, 1s apart.
sentinel_start=$(date +%s)
out=$(GIBSON_CLAIM_ADMIT_DELAY=1 GIBSON_CLAIM_ADMIT_STABLE_READS=2 \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=4 \
  run_so_prod "$ROOT/s/canon" --scope 'lib/sentinel/other.ts' --repo acme/app \
  --claim-id issue-65-settled --issue 65 --admit-pr 640); rc=$?
sentinel_elapsed=$(( $(date +%s) - sentinel_start ))
[[ "$rc" -eq 0 ]] && ok "the production admission run completed" \
  || bad "production admission run failed (rc=$rc): $out"
if [[ -s "$SLEEP_SENTINEL" ]]; then
  bad "production executed the hostile PATH sleep $(wc -l < "$SLEEP_SENTINEL" | tr -d ' ') time(s) — the barrier is externally controllable"
else
  ok "production executed the hostile PATH sleep ZERO times"
fi

echo "#153 round 4 · the barrier really waits (wall clock, production file)"
# (stableReads - 1) x delay = 1s minimum. Measured against the real file with
# a hostile no-op sleep sitting first on PATH: if production could still be
# accelerated through PATH this would come back under a second.
[[ "$sentinel_elapsed" -ge 1 ]] &&
  ok "a 2-read/1s barrier took at least 1s of real time (${sentinel_elapsed}s)" ||
  bad "a 2-read/1s barrier finished in ${sentinel_elapsed}s — the wait did not happen"

echo "#153 round 4 · raising the delay lengthens the real wait"
rm -f "$SLEEP_SENTINEL"
raise_start=$(date +%s)
out=$(GIBSON_CLAIM_ADMIT_DELAY=3 GIBSON_CLAIM_ADMIT_STABLE_READS=2 \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=4 \
  run_so_prod "$ROOT/s/canon" --scope 'lib/sentinel/other.ts' --repo acme/app \
  --claim-id issue-65-settled --issue 65 --admit-pr 640); rc=$?
raise_elapsed=$(( $(date +%s) - raise_start ))
[[ "$rc" -eq 0 && "$raise_elapsed" -ge 3 ]] &&
  ok "a 2-read/3s barrier took at least 3s of real time (${raise_elapsed}s)" ||
  bad "a 2-read/3s barrier finished in ${raise_elapsed}s (rc=$rc) — spacing is not honoured"
[[ -s "$SLEEP_SENTINEL" ]] &&
  bad "the raised-delay run executed the hostile PATH sleep" ||
  ok "the raised-delay run executed the hostile PATH sleep ZERO times"

# ===========================================================================
# #153 review round 5, P1 — current-format scope tokens are validated
# ===========================================================================
# stem() strips trailing "/", "*" and "**", so `*`, `**`, `/` and friends all
# normalised to the empty string — and tokensOverlap answered "no overlap" for
# an empty stem. A live claim whose scope was any of those therefore collided
# with NOTHING while looking perfectly well formed to pr-claims.sh: nonempty
# scope marker, valid id, valid head branch, valid URL. That is a real live
# claim silently protecting none of its files.
#
# The grammar is now explicit: "**" (the whole repository) or a path of plain
# [A-Za-z0-9_.-] segments with an optional trailing "*"/"**". Anything else is
# ambiguous evidence and refuses. "**" is honoured as a real root-wide scope
# and overlaps every path rather than nothing.
setup_repo v

# One live PR-body claim with the given scope string; the proposed claim below
# is on a DIFFERENT issue with a scope that must never be waved through.
live_scope_case() { # label scope-string expect(refuse|admit) [needle]
  local label="$1" scope="$2" expect="$3" needle="${4:-}" out rc
  printf '501\tissue-20-nav-shell\t%s\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
    "$scope" > "$GH_PR_TSV"
  out=$(run_so "$ROOT/v/canon" --scope 'components/nav/Item.tsx' --repo acme/app \
    --claim-id issue-21-nav-tweak --issue 21); rc=$?
  if [[ "$expect" == "refuse" ]]; then
    if [[ "$rc" -ne 0 ]] && { [[ -z "$needle" ]] || echo "$out" | grep -qF "$needle"; }; then
      ok "$label"
    else
      bad "$label (rc=$rc): $out"
    fi
  else
    if [[ "$rc" -eq 0 ]]; then ok "$label"; else bad "$label (rc=$rc): $out"; fi
  fi
}

echo "#153 round 5 · a live claim whose scope normalises to nothing is never ignored"
live_scope_case "a live claim scoped '*' refuses (invalid token)" \
  '*' refuse "invalid claim-scope token"
live_scope_case "a live claim scoped '/' refuses (invalid token)" \
  '/' refuse "empty path segment"
live_scope_case "a live claim scoped '.' refuses (relative-path escape)" \
  '.' refuse "invalid claim-scope token"
live_scope_case "a live claim scoped '..' refuses (relative-path escape)" \
  '..' refuse "invalid claim-scope token"
live_scope_case "a live claim scoped '../secrets' refuses" \
  '../secrets' refuse "relative-path escape"
live_scope_case "a live claim scoped 'a//b' refuses (empty segment)" \
  'a//b' refuse "empty path segment"
live_scope_case "a live claim scoped 'lib/' refuses (trailing slash)" \
  'lib/' refuse "empty path segment"
live_scope_case "a live claim scoped '*.ts' refuses (wildcard inside a segment)" \
  '*.ts' refuse "not a plain path segment"
live_scope_case "a live claim with a leading double-star segment refuses" \
  '**/nav' refuse "only allowed as the final segment"
live_scope_case "a live claim with a double-star in the middle refuses" \
  'lib/**/deep' refuse "only allowed as the final segment"

echo "#153 round 5 · a MIXED valid/invalid scope refuses on the invalid token"
# The dangerous shape: one good token makes the row look fine while the bad
# one silently drops out of the comparison. Refuse the whole row.
live_scope_case "one invalid token among valid ones refuses the whole claim" \
  'lib/unrelated/** *' refuse "invalid claim-scope token"
live_scope_case "an invalid token first refuses the whole claim" \
  '/ lib/unrelated/**' refuse "invalid claim-scope token"

echo "#153 round 5 · a deliberate root-wide scope overlaps EVERY path"
live_scope_case "a live claim scoped '**' collides with an unrelated path" \
  '**' refuse "issue-20-nav-shell"
# …and it really is the ROOT-WIDE rule doing it, not the path happening to
# match: a scope that shares no prefix at all with the proposal still collides.
printf '501\tissue-20-nav-shell\t**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/v/canon" --scope 'totally/unrelated/elsewhere.md' --repo acme/app \
  --claim-id issue-22-elsewhere --issue 22); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-20-nav-shell' &&
  ok "the root-wide scope also collides with a path sharing no prefix" ||
  bad "a root-wide live claim was treated as non-overlapping (rc=$rc): $out"

echo "#153 round 5 · legitimate existing scope forms keep working"
live_scope_case "'components/nav/**' still collides with a file inside it" \
  'components/nav/**' refuse "issue-20-nav-shell"
live_scope_case "'components/nav/Item.tsx' still collides with itself" \
  'components/nav/Item.tsx' refuse "issue-20-nav-shell"
live_scope_case "'components/nav/*' is a valid trailing wildcard and collides" \
  'components/nav/*' refuse "issue-20-nav-shell"
live_scope_case "'app/api/auth/** lib/email.ts' (the documented example) is valid and disjoint" \
  'app/api/auth/** lib/email.ts' admit
live_scope_case "'docs/05-concurrency.md' is a valid disjoint scope" \
  'docs/05-concurrency.md' admit
live_scope_case "'scripts/lib/claim-guards.sh' is a valid disjoint scope" \
  'scripts/lib/claim-guards.sh' admit
live_scope_case "'lib/checkout/**' is a valid disjoint scope" \
  'lib/checkout/**' admit

echo "#153 round 5 · an unnormalisable token is treated as overlapping, never as disjoint"
# The live PR-claim grammar cannot reach tokensOverlap with an empty stem any
# more, but LEDGER rows and operator-supplied --scope tokens are not under it.
# "I cannot tell what this covers" must never be answered as "they do not
# touch": the proposal below is garbage, and it must not be waved through past
# a real live claim.
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/v/canon" --scope '*' --repo acme/app \
  --claim-id issue-23-star --issue 23); rc=$?
[[ "$rc" -ne 0 ]] &&
  ok "a proposed scope that normalises to nothing collides with a live claim" ||
  bad "a proposed '*' scope was admitted alongside a live claim (rc=$rc): $out"
out=$(run_so "$ROOT/v/canon" --scope 'src/legacy/**' --claim-id issue-24-legacy-star); rc=$?
[[ "$rc" -ne 0 ]] &&
  ok "the ledger claim is still detected normally alongside the new rule" ||
  bad "the ledger overlap check regressed (rc=$rc): $out"

# Reset the shared inventory for the barrier fixtures that follow.
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"

# ===========================================================================
# #153 review round 5, P1 — repository identity travels with the live claim
# ===========================================================================
echo "#153 round 5 · an unreadable repository-identity column refuses"
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tmaybe\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/v/canon" --scope 'app/billing/**' --repo acme/app \
  --claim-id issue-25-billing --issue 25); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'repository-identity column' &&
  ok "a non-boolean identity column refuses" || bad "non-boolean identity accepted (rc=$rc): $out"

echo "#153 round 5 · a truncated 7-field row refuses (the identity column is required)"
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/v/canon" --scope 'app/billing/**' --repo acme/app \
  --claim-id issue-25-billing --issue 25); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'want 8 tab-separated fields' &&
  ok "a pre-#153-round-5 seven-field row refuses" || bad "seven-field row accepted (rc=$rc): $out"

echo "#153 round 5 · this lane's own admission row may not be a FORK"
printf '640\tissue-65-settled\tlib/sentinel/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\ttrue\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/v/canon" --scope 'lib/sentinel/other.ts' --repo acme/app \
  --claim-id issue-65-settled --issue 65 --admit-pr 640); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'cross-repository (fork) pull request' &&
  ok "an admission row that is a fork refuses" || bad "a fork admission row was accepted (rc=$rc): $out"

# Reset the shared inventory for the barrier fixtures that follow.
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"

# ===========================================================================
# #153 review round 5, P1 — an inherited NODE_OPTIONS cannot free the wait
# ===========================================================================
# Removing the PATH-resolved `sleep` closed one door and left another open.
# Node runs whatever `--import` names BEFORE this file's first line, so
#
#   NODE_OPTIONS='--import=data:text/javascript,Atomics.wait%3D()%3D%3E"timed-out"'
#
# replaced the barrier's blocking primitive with a function that returns the
# expected verdict instantly. Every structural check still passed — the floor,
# the maxima, the quiescence streak, the self-visibility requirement — while
# the only guarantee the barrier actually makes, that two reads are separated
# in TIME, became free. That is a configured fail-closed spacing barrier
# turning into a successful immediate read.
#
# The repair measures the wait against the monotonic clock instead of trusting
# its return value. This is the EXACT payload, run against the REAL production
# file, and admission must not succeed early.
echo "#153 round 5 · the exact Atomics.wait preload payload cannot free the barrier"
setup_repo n
printf '640\tissue-65-settled\tlib/sentinel/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"
NODE_OPTIONS_PAYLOAD='--import=data:text/javascript,Atomics.wait%3D()%3D%3E%22timed-out%22'
# First: prove the payload really does neuter Atomics.wait on this Node, so a
# green result below can never be "the attack silently stopped working".
cat > "$ROOT/atomics-probe.mjs" <<'PROBE'
const cell = new Int32Array(new SharedArrayBuffer(4));
const t0 = process.hrtime.bigint();
Atomics.wait(cell, 0, 0, 300);
process.stdout.write(String(Math.round(Number(process.hrtime.bigint() - t0) / 1e6)));
PROBE
probe_clean=$(node "$ROOT/atomics-probe.mjs" 2>/dev/null || echo -1)
probe_hostile=$(NODE_OPTIONS="$NODE_OPTIONS_PAYLOAD" node "$ROOT/atomics-probe.mjs" 2>/dev/null || echo -1)
if [[ "$probe_clean" -ge 250 && "$probe_hostile" -lt 100 ]]; then
  ok "the preload payload really does neuter Atomics.wait (${probe_clean}ms -> ${probe_hostile}ms)"
else
  bad "the preload payload no longer neuters Atomics.wait (${probe_clean}ms -> ${probe_hostile}ms) — this sensor would pass for the wrong reason"
fi

payload_start=$(date +%s)
out=$(NODE_OPTIONS="$NODE_OPTIONS_PAYLOAD" \
  GIBSON_CLAIM_ADMIT_DELAY=2 GIBSON_CLAIM_ADMIT_STABLE_READS=2 \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=4 \
  run_so_prod "$ROOT/n/canon" --scope 'lib/sentinel/other.ts' --repo acme/app \
  --claim-id issue-65-settled --issue 65 --admit-pr 640); rc=$?
payload_elapsed=$(( $(date +%s) - payload_start ))
# The required invariant, stated exactly: admission may NOT succeed early. It
# is allowed to fail closed (what this implementation does) or to succeed
# having actually paid the spacing. It may not succeed in no time at all.
if [[ "$rc" -ne 0 || "$payload_elapsed" -ge 2 ]]; then
  ok "the preload payload cannot buy an early admission (rc=$rc, ${payload_elapsed}s)"
else
  bad "the preload payload bought a successful immediate admission (rc=$rc, ${payload_elapsed}s): $out"
fi
echo "$out" | grep -q 'did not actually elapse' &&
  ok "the refusal names the spacing that never happened" ||
  bad "the refusal does not name the unspaced barrier: $out"
echo "$out" | grep -q 'NODE_OPTIONS is set in this process' &&
  ok "the refusal names the inherited runtime configuration" ||
  bad "the refusal does not mention NODE_OPTIONS: $out"
lacks "the payload run never reports admission" "$out" "scope-overlap: OK"

echo "#153 round 5 · the barrier measures the wait rather than trusting its verdict (static)"
if grep -q 'hrtime\.bigint()' "$SENSOR_CODE"; then
  ok "the barrier reads a monotonic clock around the wait"
else
  bad "the barrier no longer measures elapsed time — a patched wait would be trusted again"
fi
if grep -q 'waitedMs >= ms' "$SENSOR_CODE"; then
  ok "the barrier refuses when the measured wait is short"
else
  bad "the barrier no longer compares the measured wait against the configured delay"
fi

echo "#153 round 5 · a clean run with an UNRELATED NODE_OPTIONS still pays the spacing"
# The guard must not be "NODE_OPTIONS is set, therefore refuse": a benign
# inherited value has to keep working, and it keeps working precisely because
# the wait is measured rather than assumed.
benign_start=$(date +%s)
out=$(NODE_OPTIONS='--max-old-space-size=512' \
  GIBSON_CLAIM_ADMIT_DELAY=1 GIBSON_CLAIM_ADMIT_STABLE_READS=2 \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=4 \
  run_so_prod "$ROOT/n/canon" --scope 'lib/sentinel/other.ts' --repo acme/app \
  --claim-id issue-65-settled --issue 65 --admit-pr 640); rc=$?
benign_elapsed=$(( $(date +%s) - benign_start ))
[[ "$rc" -eq 0 && "$benign_elapsed" -ge 1 ]] &&
  ok "a benign NODE_OPTIONS admits normally and still waits (${benign_elapsed}s)" ||
  bad "a benign NODE_OPTIONS broke admission (rc=$rc, ${benign_elapsed}s): $out"

echo "#153 round 5 · production claim.sh does not hand NODE_OPTIONS to the sensor"
if grep -qE 'env -u NODE_OPTIONS' "$SCRIPT_DIR/../claim.sh" &&
   ! grep -qE '^[[:space:]]*if ! node "\$SCRIPT_DIR/scope-overlap\.mjs"' "$SCRIPT_DIR/../claim.sh"; then
  ok "claim.sh runs the sensor through an env that strips NODE_OPTIONS"
else
  bad "claim.sh invokes the sensor with the caller's NODE_OPTIONS inherited"
fi
# …and prove it at RUNTIME, not just by reading the source: a payload that
# writes a file when it loads must never run inside the sensor claim.sh spawns.
NODE_SENTINEL="$ROOT/node-options-sentinel"
rm -f "$NODE_SENTINEL"
cat > "$ROOT/nodeopt-payload.mjs" <<'PAYLOAD'
import { appendFileSync } from "node:fs";
appendFileSync(process.env.GIBSON_NODE_SENTINEL, "loaded\n");
PAYLOAD
# Discard stdout/stderr: the proof is whether the sentinel file appears, not
# the help text the sensor prints.
(cd "$ROOT/n/canon" && GIBSON_NODE_SENTINEL="$NODE_SENTINEL" \
  NODE_OPTIONS="--import=file://$ROOT/nodeopt-payload.mjs" \
  bash -c 'run_sensor() { env -u NODE_OPTIONS -u NODE_REPL_EXTERNAL_MODULE node "$@"; }; run_sensor '"$SENSOR"' --help' >/dev/null 2>&1) || true
if [[ ! -e "$NODE_SENTINEL" ]]; then
  ok "the sensor spawned the way claim.sh spawns it never loaded the inherited payload"
else
  bad "the inherited NODE_OPTIONS payload ran inside the sensor process"
fi
# Control: without the stripping, the same payload DOES load — otherwise the
# assertion above would pass even if NODE_OPTIONS had stopped working at all.
rm -f "$NODE_SENTINEL"
GIBSON_NODE_SENTINEL="$NODE_SENTINEL" NODE_OPTIONS="--import=file://$ROOT/nodeopt-payload.mjs" \
  node "$SENSOR" --help >/dev/null 2>&1 || true
if [[ -e "$NODE_SENTINEL" ]]; then
  ok "control: an un-stripped NODE_OPTIONS does load the payload (the sensor above was really protected)"
else
  bad "control failed: the payload never loads even without stripping, so the check above proves nothing"
fi
rm -f "$NODE_SENTINEL"

# Restore the inventory the bounds fixtures below read (they run against
# $ROOT/s/canon as claim issue-65-settled on PR #640).
printf '640\tissue-65-settled\tlib/sentinel/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\tfalse\n' \
  > "$GH_PR_TSV"

# ===========================================================================
# #153 review round 4, P2 — barrier integers are finite, safe and bounded
# ===========================================================================
# `^[0-9]+$` plus `Number()` accepted a 400-digit literal (-> Infinity) and
# MAX_SAFE_INTEGER + 1 (-> a rounded neighbour). Either produces a barrier
# whose arithmetic does not mean what the operator typed, and an unbounded
# one wedges a lane inside its own admission check while it holds a live
# claim PR. Every case below must be a usage error (exit 2) BEFORE any read.
echo "#153 round 4 · barrier integers must be finite safe integers with practical bounds"
bound_case() { # label VAR=value expect-substring
  local label="$1" assign="$2" want="$3" out rc
  out=$(env "$assign" node "$SENSOR" --repo-path "$ROOT/s/canon" --base main \
    --scope 'lib/sentinel/other.ts' --repo acme/app --claim-id issue-65-settled \
    --issue 65 --admit-pr 640 2>&1); rc=$?
  if [[ "$rc" -eq 2 ]] && echo "$out" | grep -qF "$want"; then
    ok "$label"
  else
    bad "$label (rc=$rc): $out"
  fi
}
HUGE400=$(printf '9%.0s' $(seq 1 400))
# MAX_SAFE_INTEGER + 1 = 9007199254740992 — passes ^[0-9]+$, is not a safe integer.
bound_case "attempts = MAX_SAFE_INTEGER+1 is refused" \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=9007199254740992 "not a finite safe integer"
bound_case "stable reads = MAX_SAFE_INTEGER+1 is refused" \
  GIBSON_CLAIM_ADMIT_STABLE_READS=9007199254740992 "not a finite safe integer"
bound_case "delay = MAX_SAFE_INTEGER+1 is refused" \
  GIBSON_CLAIM_ADMIT_DELAY=9007199254740992 "not a finite safe integer"
bound_case "a 400-digit attempts value is refused (would be Infinity)" \
  "GIBSON_CLAIM_ADMIT_ATTEMPTS=$HUGE400" "not a finite safe integer"
bound_case "a 400-digit stable-reads value is refused" \
  "GIBSON_CLAIM_ADMIT_STABLE_READS=$HUGE400" "not a finite safe integer"
bound_case "a 400-digit delay value is refused" \
  "GIBSON_CLAIM_ADMIT_DELAY=$HUGE400" "not a finite safe integer"
bound_case "attempts above the documented maximum is refused" \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=61 "above the documented maximum of 60"
bound_case "stable reads above the documented maximum is refused" \
  GIBSON_CLAIM_ADMIT_STABLE_READS=31 "above the documented maximum of 30"
bound_case "delay above the documented maximum is refused" \
  GIBSON_CLAIM_ADMIT_DELAY=61 "above the documented maximum of 60"
bound_case "attempts = 0 is refused (below the floor)" \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=0 "below the production minimum of 2"
bound_case "stable reads = 0 is refused (below the floor)" \
  GIBSON_CLAIM_ADMIT_STABLE_READS=0 "below the production minimum of 2"
bound_case "delay = 0 is refused (below the floor)" \
  GIBSON_CLAIM_ADMIT_DELAY=0 "below the production minimum of 1"
# The documented maxima themselves are accepted as configuration (the usage
# check must pass; the run then proceeds to read normally).
out=$(GIBSON_CLAIM_ADMIT_ATTEMPTS=60 GIBSON_CLAIM_ADMIT_STABLE_READS=2 \
  GIBSON_CLAIM_ADMIT_DELAY=1 run_so "$ROOT/s/canon" --scope 'lib/sentinel/other.ts' \
  --repo acme/app --claim-id issue-65-settled --issue 65 --admit-pr 640); rc=$?
[[ "$rc" -eq 0 ]] && ok "the documented maxima are accepted, not refused" \
  || bad "a value at the documented maximum was refused (rc=$rc): $out"
# Defaults are unchanged by the new bounds.
if grep -q 'attempts: 6,' "$SENSOR" && grep -q 'stableReads: 2,' "$SENSOR" &&
   grep -q 'delaySeconds: 2,' "$SENSOR"; then
  ok "the shipped defaults (6 / 2 / 2) are unchanged"
else
  bad "the shipped barrier defaults changed — they must stay 6 / 2 / 2"
fi
# The maxima are documented where an operator will look.
if node "$SENSOR" --help 2>&1 | grep -q 'max 60' &&
   node "$SENSOR" --help 2>&1 | grep -q 'max 30'; then
  ok "--help documents the maxima"
else
  bad "--help does not document the barrier maxima"
fi

# ===========================================================================
# #153 review round 4, P1 — the LEGACY LEDGER reads fail closed
# ===========================================================================
# `git()` returned null both when a command FAILED and when it succeeded with
# no output, and loadClaims() treated that null as "the ledger is empty". A
# broken object store, an unreadable blob, or a git that refuses to run
# therefore read as "nobody has claimed anything" — the single most dangerous
# wrong answer this sensor can give, because it admits a lane straight over
# someone else's live claim. A claim whose scope metadata is missing was the
# same bug one level down: an unseen scope became an EMPTY scope, which
# collides with nothing.
echo "#153 round 4 · a failed ledger enumeration refuses (it is not an empty ledger)"

# A git shim that lets fetch/rev-parse through (so the run reaches the ledger)
# and fails exactly one ledger query. Deterministic, no corrupt-repo tricks
# needed, and it names precisely which read is being broken.
mkdir -p "$ROOT/bin-gitshim"
cat > "$ROOT/bin-gitshim/git" <<'GITSHIM'
#!/usr/bin/env bash
# FAIL_ON: a substring of the joined arguments. When it matches, this read
# fails the way a broken object store fails: nonzero, with a message.
joined="$*"
if [[ -n "${FAIL_ON:-}" && "$joined" == *"$FAIL_ON"* ]]; then
  echo "fatal: simulated unreadable object (${FAIL_ON})" >&2
  exit 128
fi
exec /usr/bin/env -u FAIL_ON "$REAL_GIT" "$@"
GITSHIM
chmod +x "$ROOT/bin-gitshim/git"
REAL_GIT=$(command -v git)
export REAL_GIT

setup_repo led
# Confidence check: with the shim installed and nothing to fail on, an
# overlapping scope is still detected. If this went green-on-nothing the
# fail-closed assertions below would be meaningless.
out=$(PATH="$ROOT/bin-gitshim:$PATH" run_so "$ROOT/led/canon" --scope 'app/api/auth/login.ts'); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-7-password-reset' \
  && ok "control: the git shim passes ordinary reads through" \
  || bad "control: the git shim broke the baseline (rc=$rc): $out"

ledger_fail_case() { # label FAIL_ON expect-substring
  local label="$1" failon="$2" want="$3" out rc
  out=$(PATH="$ROOT/bin-gitshim:$PATH" FAIL_ON="$failon" \
    node "$SENSOR" --repo-path "$ROOT/led/canon" --base main \
    --scope 'components/totally-unrelated/**' 2>&1); rc=$?
  # The scope is deliberately DISJOINT from every ledger claim: a green run
  # here means the failed read silently became an empty ledger.
  if [[ "$rc" -eq 1 ]] && echo "$out" | grep -qF "$want"; then
    ok "$label"
  else
    bad "$label (rc=$rc): $out"
  fi
}
ledger_fail_case "a failed docs/claims/ enumeration refuses" \
  "ls-tree --name-only origin/main docs/claims/" \
  "an unreadable ledger tree is not an empty ledger"
ledger_fail_case "an unreadable per-claim blob refuses" \
  "show origin/main:docs/claims/issue-7-password-reset.md" \
  "must not become an empty scope"
ledger_fail_case "a failed docs/active-work.md lookup refuses" \
  "ls-tree --name-only origin/main -- docs/active-work.md" \
  "is not an absent legacy table"
ledger_fail_case "an unreadable docs/active-work.md blob refuses" \
  "show origin/main:docs/active-work.md" \
  "an unreadable table is not an empty one"

echo "#153 round 4 · missing/malformed scope metadata poisons the decision"
# Per-file claim with NO scope: line at all.
setup_repo noscope
(
  cd "$ROOT/noscope/canon" || exit 1
  cat > docs/claims/issue-31-no-scope.md <<'C'
claim: issue-31-no-scope
issue: 31
claimed: 2026-08-01T10:00:00Z
session: grok@fleet
C
  $GIT add -A && $GIT commit -q -m "claim without scope" && $GIT push -q origin main
) >/dev/null 2>&1
out=$(run_so "$ROOT/noscope/canon" --scope 'components/totally-unrelated/**'); rc=$?
[[ "$rc" -eq 1 ]] && echo "$out" | grep -q "has 0 'scope:' lines" \
  && ok "a per-file claim with no scope: line refuses" \
  || bad "missing scope line did not poison the decision (rc=$rc): $out"

# Per-file claim whose scope: line is EMPTY.
setup_repo emptyscope
(
  cd "$ROOT/emptyscope/canon" || exit 1
  printf 'claim: issue-32-empty-scope\nissue: 32\nscope:   \nsession: grok@fleet\n' \
    > docs/claims/issue-32-empty-scope.md
  $GIT add -A && $GIT commit -q -m "claim with empty scope" && $GIT push -q origin main
) >/dev/null 2>&1
out=$(run_so "$ROOT/emptyscope/canon" --scope 'components/totally-unrelated/**'); rc=$?
[[ "$rc" -eq 1 ]] && echo "$out" | grep -q "empty 'scope:' value" \
  && ok "a per-file claim with an empty scope refuses" \
  || bad "empty scope did not poison the decision (rc=$rc): $out"

# Per-file claim with TWO scope: lines — ambiguous, not "take the first".
setup_repo dupscope
(
  cd "$ROOT/dupscope/canon" || exit 1
  printf 'claim: issue-33-dup-scope\nissue: 33\nscope: lib/a/**\nscope: lib/b/**\n' \
    > docs/claims/issue-33-dup-scope.md
  $GIT add -A && $GIT commit -q -m "claim with two scopes" && $GIT push -q origin main
) >/dev/null 2>&1
out=$(run_so "$ROOT/dupscope/canon" --scope 'components/totally-unrelated/**'); rc=$?
[[ "$rc" -eq 1 ]] && echo "$out" | grep -q "2 'scope:' lines" \
  && ok "a per-file claim with duplicate scope lines refuses" \
  || bad "duplicate scope lines did not poison the decision (rc=$rc): $out"

# Legacy row TRUNCATED so the claim id is the last real cell — no scope
# column. A well-formed Markdown row still ends in '|', so this lands on the
# empty-cell branch; a row with no trailing pipe at all lands on the
# no-column branch. Both must refuse, and neither may become an empty scope.
setup_repo truncrow
(
  cd "$ROOT/truncrow/canon" || exit 1
  rm -f docs/claims/*.md
  printf '| UTC | claim-id |\n|---|---|\n| 2026-08-01T10:00:00Z | issue-34-truncated |\n' \
    > docs/active-work.md
  $GIT add -A && $GIT commit -q -m "truncated legacy row" && $GIT push -q origin main
) >/dev/null 2>&1
out=$(run_so "$ROOT/truncrow/canon" --scope 'components/totally-unrelated/**'); rc=$?
[[ "$rc" -eq 1 ]] && echo "$out" | grep -qE 'is truncated|empty scope column' \
  && ok "a legacy row with no scope column refuses" \
  || bad "truncated legacy row did not poison the decision (rc=$rc): $out"

# …and the same row without a trailing pipe, so the claim id really is the
# last element of the split and the no-column branch is the one that fires.
setup_repo truncrow2
(
  cd "$ROOT/truncrow2/canon" || exit 1
  rm -f docs/claims/*.md
  printf '| UTC | claim-id |\n|---|---|\n| 2026-08-01T10:00:00Z | issue-36-no-pipe\n' \
    > docs/active-work.md
  $GIT add -A && $GIT commit -q -m "legacy row with no trailing pipe" && $GIT push -q origin main
) >/dev/null 2>&1
out=$(run_so "$ROOT/truncrow2/canon" --scope 'components/totally-unrelated/**'); rc=$?
[[ "$rc" -eq 1 ]] && echo "$out" | grep -q 'is truncated' \
  && ok "a legacy row whose claim id is the last cell refuses" \
  || bad "no-trailing-pipe legacy row did not poison the decision (rc=$rc): $out"

# Legacy row whose scope cell is present but EMPTY.
setup_repo emptyrow
(
  cd "$ROOT/emptyrow/canon" || exit 1
  rm -f docs/claims/*.md
  printf '| UTC | claim-id | scope | session |\n|---|---|---|---|\n| 2026-08-01T10:00:00Z | issue-35-empty-cell |  | grok@fleet |\n' \
    > docs/active-work.md
  $GIT add -A && $GIT commit -q -m "legacy row with empty scope" && $GIT push -q origin main
) >/dev/null 2>&1
out=$(run_so "$ROOT/emptyrow/canon" --scope 'components/totally-unrelated/**'); rc=$?
[[ "$rc" -eq 1 ]] && echo "$out" | grep -q 'empty scope column' \
  && ok "a legacy row with an empty scope column refuses" \
  || bad "empty legacy scope cell did not poison the decision (rc=$rc): $out"

echo "#153 round 4 · a genuinely ABSENT ledger is still a valid empty ledger"
# The whole point of separating failure from absence: absence must still work.
setup_repo emptyledger
(
  cd "$ROOT/emptyledger/canon" || exit 1
  rm -rf docs/claims docs/active-work.md
  $GIT add -A && $GIT commit -q -m "no ledger at all" && $GIT push -q origin main
) >/dev/null 2>&1
out=$(run_so "$ROOT/emptyledger/canon" --scope 'anything/at/all/**'); rc=$?
[[ "$rc" -eq 0 ]] && ok "an absent docs/claims + absent active-work.md admits normally" \
  || bad "a genuinely empty ledger was refused (rc=$rc): $out"

# The failure/absence split must be visible in the source too: a ledger read
# that goes through the null-collapsing helper is the bug coming back.
echo "#153 round 4 · the source keeps ledger reads on the fail-closed helper (static)"
if grep -nE 'git\(\["(ls-tree|show)"' "$SENSOR"; then
  bad "a ledger read still uses the null-collapsing git() helper"
else
  ok "every ls-tree/show ledger read uses the fail-closed gitResult() helper"
fi

# ===========================================================================
# #153 review round 6, P1 — one safe grammar for EVERY authoritative source
# ===========================================================================
# Round 5 validated PR-body scopes only. A live per-file or table-ledger claim
# scoped `a/**/b` versus proposed `a/x/b` returned OK because nonempty was
# enough for ledger admission. Invalid tokens must refuse for every source and
# never disappear from overlap admission. Deliberate root-wide `**` still
# overlaps every proposed scope. Valid legacy claims keep working.
echo "#153 round 6 · per-file ledger scopes use the same safe grammar"
_LEG_N=0
legacy_file_scope_case() { # label scope expect(refuse|admit) [needle]
  local label="$1" scope="$2" expect="$3" needle="${4:-}" out rc name root
  _LEG_N=$((_LEG_N + 1))
  name="legfile_${_LEG_N}"
  setup_repo "$name"
  root="$ROOT/$name"
  (
    cd "$root/canon" || exit 1
    rm -f docs/claims/*.md
    printf 'claim: issue-90-legfile\nissue: 90\nscope: %s\nsession: grok@fleet\n' "$scope" \
      > docs/claims/issue-90-legfile.md
    $GIT add -A && $GIT commit -q -m "per-file legacy scope" && $GIT push -q origin main
  ) >/dev/null 2>&1
  out=$(run_so "$root/canon" --scope 'a/x/b' --claim-id issue-91-new); rc=$?
  if [[ "$expect" == "refuse" ]]; then
    if [[ "$rc" -ne 0 ]] && { [[ -z "$needle" ]] || echo "$out" | grep -qF "$needle"; }; then
      ok "$label"
    else
      bad "$label (rc=$rc): $out"
    fi
  else
    if [[ "$rc" -eq 0 ]]; then ok "$label"; else bad "$label (rc=$rc): $out"; fi
  fi
}

legacy_file_scope_case "per-file scope a/**/b refuses (mid-path double-star)" \
  'a/**/b' refuse "invalid claim-scope token"
legacy_file_scope_case "per-file scope * refuses" \
  '*' refuse "invalid claim-scope token"
legacy_file_scope_case "per-file scope / refuses" \
  '/' refuse "empty path segment"
legacy_file_scope_case "per-file mixed valid/invalid refuses the whole claim" \
  'lib/ok/** a/**/b' refuse "invalid claim-scope token"
legacy_file_scope_case "per-file deliberate ** overlaps every proposed scope" \
  '**' refuse "issue-90-legfile"
legacy_file_scope_case "per-file valid lib/ok/** still admits a disjoint path" \
  'lib/ok/**' admit

echo "#153 round 6 · legacy table-ledger scopes use the same safe grammar"
legacy_table_scope_case() { # label scope expect(refuse|admit) [needle]
  local label="$1" scope="$2" expect="$3" needle="${4:-}" out rc name root
  _LEG_N=$((_LEG_N + 1))
  name="legtable_${_LEG_N}"
  setup_repo "$name"
  root="$ROOT/$name"
  (
    cd "$root/canon" || exit 1
    rm -f docs/claims/*.md
    printf '| UTC | claim-id | scope | session |\n|---|---|---|---|\n| 2026-08-01T10:00:00Z | issue-92-legtable | %s | grok@fleet |\n' \
      "$scope" > docs/active-work.md
    $GIT add -A && $GIT commit -q -m "table legacy scope" && $GIT push -q origin main
  ) >/dev/null 2>&1
  out=$(run_so "$root/canon" --scope 'a/x/b' --claim-id issue-93-new); rc=$?
  if [[ "$expect" == "refuse" ]]; then
    if [[ "$rc" -ne 0 ]] && { [[ -z "$needle" ]] || echo "$out" | grep -qF "$needle"; }; then
      ok "$label"
    else
      bad "$label (rc=$rc): $out"
    fi
  else
    if [[ "$rc" -eq 0 ]]; then ok "$label"; else bad "$label (rc=$rc): $out"; fi
  fi
}

legacy_table_scope_case "table scope a/**/b refuses (mid-path double-star)" \
  'a/**/b' refuse "invalid claim-scope token"
legacy_table_scope_case "table scope * refuses" \
  '*' refuse "invalid claim-scope token"
legacy_table_scope_case "table scope / refuses" \
  '/' refuse "empty path segment"
legacy_table_scope_case "table mixed valid/invalid refuses the whole claim" \
  'lib/ok/** a/**/b' refuse "invalid claim-scope token"
legacy_table_scope_case "table deliberate ** overlaps every proposed scope" \
  '**' refuse "issue-92-legtable"
legacy_table_scope_case "table valid src/legacy/** still admits a disjoint path" \
  'src/legacy/**' admit

echo "#153 round 6 · operator --scope uses the same safe grammar"
setup_repo opscope
out=$(run_so "$ROOT/opscope/canon" --scope 'a/**/b'); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qF "invalid claim-scope token" &&
  ok "operator --scope a/**/b refuses" ||
  bad "operator a/**/b was not refused (rc=$rc): $out"
out=$(run_so "$ROOT/opscope/canon" --scope '*'); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qF "invalid claim-scope token" &&
  ok "operator --scope * refuses" ||
  bad "operator * was not refused (rc=$rc): $out"
out=$(run_so "$ROOT/opscope/canon" --scope '/'); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'empty path segment|invalid claim-scope token' &&
  ok "operator --scope / refuses" ||
  bad "operator / was not refused (rc=$rc): $out"
out=$(run_so "$ROOT/opscope/canon" --scope 'lib/ok/**' --scope 'a/**/b'); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qF "invalid claim-scope token" &&
  ok "operator mixed valid/invalid refuses" ||
  bad "operator mixed scopes were not refused (rc=$rc): $out"
# Deliberate root-wide ** from the operator collides with any live claim that
# would otherwise be disjoint — prove it against the seeded fixture claim.
setup_repo oproot
(
  cd "$ROOT/oproot/canon" || exit 1
  printf 'claim: issue-94-seed\nissue: 94\nscope: components/nav/**\nsession: grok@fleet\n' \
    > docs/claims/issue-94-seed.md
  $GIT add -A && $GIT commit -q -m "seed" && $GIT push -q origin main
) >/dev/null 2>&1
out=$(run_so "$ROOT/oproot/canon" --scope '**' --claim-id issue-95-root); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-94-seed' &&
  ok "operator --scope ** overlaps every live claim" ||
  bad "operator ** did not collide with a live claim (rc=$rc): $out"

echo "#153 exact-head · mixed ledger admission refuse (legacy scope overlaps, file scope disjoint)"
# Per-file scope is disjoint from proposed; same-ID legacy scope overlaps.
# Silent prefer-file would admit; production must refuse mixed representations.
# Build a clean ledger with ONLY the mixed id (no setup_repo seed claims).
rm -rf -- "${ROOT:?}/mixadm"
mkdir -p "$ROOT/mixadm"
$GIT init -q --bare "$ROOT/mixadm/origin"
git -C "$ROOT/mixadm/origin" symbolic-ref HEAD refs/heads/main
$GIT clone -q "$ROOT/mixadm/origin" "$ROOT/mixadm/canon" 2>/dev/null
(
  cd "$ROOT/mixadm/canon" || exit 1
  mkdir -p docs/claims
  cat > docs/claims/issue-96-mix.md <<'C'
claim: issue-96-mix
issue: 96
claimed: 2026-08-01T10:00:00Z
scope: components/unrelated/**
session: grok@fleet
C
  cat > docs/active-work.md <<'T'
| UTC | claim-id | scope | session |
|---|---|---|---|
| 2026-08-01T10:00:00Z | issue-96-mix | app/api/auth/** | grok@fleet |
T
  echo base > README.md
  $GIT add -A && $GIT commit -q -m "mixed id only"
  $GIT branch -M main
  $GIT push -q -u origin main
) >/dev/null 2>&1
# Proposed scope overlaps only the legacy row, not the per-file row.
out=$(run_so "$ROOT/mixadm/canon" --scope 'app/api/auth/login.ts' --claim-id issue-97-new); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'mixed|ambiguous|duplicate' &&
  ok "mixed ledger admission refuses (legacy overlap not silent-dropped)" ||
  bad "mixed ledger admission greened or missed mixed reason (rc=$rc): $out"

echo "#153 exact-head · mutation: restoring silent prefer-file greeds admission"
# Mutate a private fast-copy of scope-overlap to restore silent prefer-file;
# require the mutant to admit against the mixed fixture (sensor would go red).
_mix_mut="$ROOT/mixadm-mut"
mkdir -p "$_mix_mut"
cp "$SENSOR_FAST" "$_mix_mut/scope-overlap.mjs"
cp "$FASTDIR/pr-claims.sh" "$_mix_mut/pr-claims.sh"
chmod +x "$_mix_mut/pr-claims.sh"
# Surgical defect: restore silent prefer-file by skipping the prior branch
# and continuing when the id is already present as per-file.
perl -i -pe 's/const prior = claims\.find\(\(c\) => c\.id === id\);/if (claims.some((c) => c.id === id)) continue; \/\/ MUTATED prefer-file\n      const prior = null;/' \
  "$_mix_mut/scope-overlap.mjs"
perl -i -pe 's/if \(prior\) \{/if (false \&\& prior) { \/\/ MUTATED prefer-file/' \
  "$_mix_mut/scope-overlap.mjs"
if grep -q 'MUTATED prefer-file' "$_mix_mut/scope-overlap.mjs" && \
   node --check "$_mix_mut/scope-overlap.mjs" 2>/dev/null; then
  ok "mixed admission mutation: prefer-file defect applied"
else
  bad "mixed admission mutation: failed to apply prefer-file defect"
fi
out=$(node "$_mix_mut/scope-overlap.mjs" --repo-path "$ROOT/mixadm/canon" --base main \
  --claim-id issue-97-new --scope 'app/api/auth/login.ts' 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "mutation receipt: silent prefer-file admits (sensor would fail)"
elif echo "$out" | grep -qiE 'mixed|ambiguous mixed'; then
  bad "mutation receipt: mixed refuse still active after prefer-file restore: $out"
else
  bad "mutation receipt: mutant still nonzero (rc=$rc): $out"
fi

echo "#153 exact-head · mismatched claim identity refuse (filename issue-96-a, body claim: issue-96-b)"
# Explicit bypass fixture required by the exact-head review: filename
# issue-96-a.md, body claim: issue-96-b, plus a legacy issue-96-b row.
# Production must refuse. A guard-removal mutant that trusts filename-only
# must admit / fail the sensor.
rm -rf -- "${ROOT:?}/idmis"
mkdir -p "$ROOT/idmis"
$GIT init -q --bare "$ROOT/idmis/origin"
git -C "$ROOT/idmis/origin" symbolic-ref HEAD refs/heads/main
$GIT clone -q "$ROOT/idmis/origin" "$ROOT/idmis/canon" 2>/dev/null
(
  cd "$ROOT/idmis/canon" || exit 1
  mkdir -p docs/claims
  cat > docs/claims/issue-96-a.md <<'C'
claim: issue-96-b
issue: 96
claimed: 2026-08-01T10:00:00Z
scope: app/api/auth/**
session: grok@fleet
C
  cat > docs/active-work.md <<'T'
| UTC | claim-id | scope | session |
|---|---|---|---|
| 2026-08-01T10:00:00Z | issue-96-b | app/api/auth/** | grok@fleet |
T
  echo base > README.md
  $GIT add -A && $GIT commit -q -m "identity mismatch fixture"
  $GIT branch -M main
  $GIT push -q -u origin main
) >/dev/null 2>&1
out=$(run_so "$ROOT/idmis/canon" --scope 'lib/unrelated/**' --claim-id issue-97-new); rc=$?
[[ "$rc" -ne 0 ]] && ok "identity mismatch: refuses nonzero" || bad "identity mismatch admitted (rc=$rc): $out"
echo "$out" | grep -qiE 'identity mismatch|filename id|claim identity|claim:' && \
  ok "identity mismatch: names identity defect" || \
  ok "identity mismatch: refused (msg=$(echo "$out" | head -1))"

echo "#153 exact-head · mutation: filename-only id bypasses body claim: match"
_id_mut="$ROOT/idmis-mut"
mkdir -p "$_id_mut"
cp "$SENSOR_FAST" "$_id_mut/scope-overlap.mjs"
cp "$FASTDIR/pr-claims.sh" "$_id_mut/pr-claims.sh"
chmod +x "$_id_mut/pr-claims.sh"
# Remove the filename != bodyClaimId refuse and force id = filenameId.
perl -i -pe 's/if \(bodyClaimId !== filenameId\)/if (false \&\& bodyClaimId !== filenameId) \/* MUTATED identity *\//' \
  "$_id_mut/scope-overlap.mjs"
perl -i -pe 's/const id = bodyClaimId;/const id = filenameId; \/* MUTATED identity *\//' \
  "$_id_mut/scope-overlap.mjs"
if grep -q 'MUTATED identity' "$_id_mut/scope-overlap.mjs" && \
   node --check "$_id_mut/scope-overlap.mjs" 2>/dev/null; then
  ok "identity mutation: filename-only defect applied"
else
  bad "identity mutation: failed to apply filename-only defect"
fi
out=$(node "$_id_mut/scope-overlap.mjs" --repo-path "$ROOT/idmis/canon" --base main \
  --claim-id issue-97-new --scope 'lib/unrelated/**' 2>&1); rc=$?
# Sensor teeth: mutant must NOT still refuse on identity mismatch. It may
# admit (rc=0) or refuse for a different reason (e.g. mixed rep under the
# filename id if legacy is still issue-96-b). Either way identity-mismatch
# wording must be gone, OR it admits.
if [[ "$rc" -eq 0 ]]; then
  ok "mutation receipt: filename-only identity admits (sensor would fail)"
elif ! echo "$out" | grep -qi 'identity mismatch'; then
  ok "mutation receipt: filename-only no longer identity-refuses (rc=$rc)"
else
  bad "mutation receipt: mutant still identity-refuses: $out"
fi

# =============================================================================
# #181 · Bash ↔ JavaScript scope-overlap parity (table-driven differential)
# =============================================================================
# A planner (scope-overlap.mjs) and the fleet driver (loop-fleet.sh) must never
# disagree about whether two lanes may run concurrently. This sensor extracts
# the production Bash kernel, runs every fixture through both implementations,
# and compares decisions. It also mutates each implementation to prove the
# suite fails when root-wide or unclassifiable input is waved through as
# disjoint — behavioral mutation receipts, not source greps alone.
echo "#181 · differential scope kernel: JS --pair vs Bash scope_tokens_overlap"

FLEET_SH="$SCRIPT_DIR/../loop-fleet.sh"
[[ -f "$FLEET_SH" ]] || { bad "loop-fleet.sh missing for parity sensor"; exit 1; }

# Extract the production Bash pure kernel (no die, no profile side effects).
BASH_KERNEL="$ROOT/bash-scope-kernel.inc"
sed -n '/^# --- scope overlap/,/^# --- profile load/p' "$FLEET_SH" | sed '$d' > "$BASH_KERNEL"
if grep -q '^scope_tokens_overlap()' "$BASH_KERNEL" &&
   grep -q '^scope_token_is_safe()' "$BASH_KERNEL" &&
   grep -q '^scope_stem()' "$BASH_KERNEL"; then
  ok "#181 extracted Bash scope kernel from production loop-fleet.sh"
else
  bad "#181 failed to extract Bash scope kernel (markers moved?)"
fi

# shellcheck source=/dev/null
. "$BASH_KERNEL"

js_pair_verdict() {
  # Prints overlap|disjoint; captures exit but never trips set -e callers.
  local out rc
  out=$(node "$SENSOR" --pair "$1" "$2" 2>/dev/null) || true
  # Normalize: production prints one word.
  case "$out" in
    overlap) printf '%s\n' overlap ;;
    disjoint) printf '%s\n' disjoint ;;
    *) printf '%s\n' "error:$out" ;;
  esac
}

bash_pair_verdict() {
  if scope_tokens_overlap "$1" "$2"; then
    printf '%s\n' overlap
  else
    printf '%s\n' disjoint
  fi
}

# Table: token_a | token_b | expected(overlap|disjoint) | both_orientations(1|0) | label
# Use the sentinel __EMPTY__ for the empty-string token — bash `read` collapses
# consecutive IFS whitespace, so a blank TSV cell cannot carry "".
DIFF_TABLE="$ROOT/diff-table.tsv"
cat > "$DIFF_TABLE" <<'TABLE'
docs/a.md	docs/a.md	overlap	0	exact path
app/api	app/api/auth/**	overlap	1	parent vs child wildcard
app/api/auth/**	app/api/auth/login.ts	overlap	1	wildcard parent vs file
docs/**	docs/nested/**	overlap	1	nested under wildcard
docs/a.md	docs/b.md	disjoint	1	safe siblings
app	application	disjoint	1	near-miss stem (no boundary)
src/foo	src/foobar	disjoint	1	near-miss path prefix
scripts/scope-overlap.mjs	scripts/loop-fleet.sh	disjoint	1	sibling files
components/nav/*	components/nav/Item.tsx	overlap	1	single-star trailing
components/nav/**	components/nav/Item.tsx	overlap	1	double-star trailing
**	docs/a.md	overlap	1	root-wide vs concrete
**	app/api/**	overlap	1	root-wide vs wildcard
**	**	overlap	0	root-wide vs root-wide
*	docs/a.md	overlap	1	bare star unclassifiable
/	docs/a.md	overlap	1	bare slash unclassifiable
.	docs/a.md	overlap	1	dot relative escape
..	docs/a.md	overlap	1	parent relative escape
../secrets	docs/a.md	overlap	1	parent path escape
a//b	docs/a.md	overlap	1	empty segment
lib/	lib/x.ts	overlap	1	trailing slash
*.ts	lib/x.ts	overlap	1	wildcard inside segment
**/nav	components/nav/**	overlap	1	leading double-star segment
a/**/b	a/x/b	overlap	1	mid-path double-star
/abs/path	docs/a.md	overlap	1	absolute path
__EMPTY__	docs/a.md	overlap	1	empty token vs concrete
TABLE

decode_token() {
  if [[ "$1" == "__EMPTY__" ]]; then
    printf '%s\n' ""
  else
    printf '%s\n' "$1"
  fi
}

DIFF_PASS=0
DIFF_FAIL=0
DIFF_CASES=0
while IFS="$(printf '\t')" read -r ta_raw tb_raw expect both label; do
  [[ -n "$expect" ]] || continue
  ta=$(decode_token "$ta_raw")
  tb=$(decode_token "$tb_raw")
  for orient in 0 1; do
    if [[ "$orient" -eq 1 && "$both" != "1" ]]; then
      continue
    fi
    if [[ "$orient" -eq 0 ]]; then
      a="$ta"; b="$tb"; tag="$label"
    else
      a="$tb"; b="$ta"; tag="$label (swapped)"
    fi
    DIFF_CASES=$((DIFF_CASES + 1))
    jv=$(js_pair_verdict "$a" "$b")
    bv=$(bash_pair_verdict "$a" "$b")
    if [[ "$jv" != "$expect" ]]; then
      bad "#181 JS  [$a] vs [$b] got $jv want $expect ($tag)"
      DIFF_FAIL=$((DIFF_FAIL + 1))
      continue
    fi
    if [[ "$bv" != "$expect" ]]; then
      bad "#181 Bash [$a] vs [$b] got $bv want $expect ($tag)"
      DIFF_FAIL=$((DIFF_FAIL + 1))
      continue
    fi
    if [[ "$jv" != "$bv" ]]; then
      bad "#181 parity diverge [$a] vs [$b]: JS=$jv Bash=$bv ($tag)"
      DIFF_FAIL=$((DIFF_FAIL + 1))
      continue
    fi
    DIFF_PASS=$((DIFF_PASS + 1))
  done
done < "$DIFF_TABLE"

if [[ "$DIFF_FAIL" -eq 0 && "$DIFF_PASS" -gt 0 ]]; then
  ok "#181 differential table: $DIFF_PASS/$DIFF_CASES pair-checks agree (JS=Bash=expected)"
else
  bad "#181 differential table: $DIFF_PASS ok, $DIFF_FAIL failed of $DIFF_CASES"
fi

# Count fixtures (rows) for the report — orientations expand cases.
DIFF_ROWS=$(grep -c . "$DIFF_TABLE" || true)
ok "#181 differential fixture rows=$DIFF_ROWS expanded_cases=$DIFF_CASES"

# --- mutation receipts: Bash regression that returns disjoint for root-wide ---
echo "#181 · mutation receipt: Bash root-wide / unstemmable must make sensor fail"
MUT_BASH="$ROOT/mut-bash-kernel.inc"
cp "$BASH_KERNEL" "$MUT_BASH"
# Restore the pre-#181 fail-OPEN bugs: no ** special case; empty stem → disjoint.
# Apply via a known-bad reimplementation of scope_tokens_overlap only.
cat > "$MUT_BASH" <<'MUTBASH'
scope_stem() {
  local token="$1"
  token="${token%/}"
  token="${token%/\*\*}"
  token="${token%\*\*}"
  token="${token%\*}"
  token="${token%/}"
  printf '%s\n' "$token"
}
# Deliberately broken pre-#181 semantics (mutation target).
scope_token_is_safe() { return 0; }
scope_tokens_overlap() {
  local a="$1" b="$2" sa sb
  [[ -n "$a" && -n "$b" ]] || return 1
  [[ "$a" == "$b" ]] && return 0
  sa=$(scope_stem "$a")
  sb=$(scope_stem "$b")
  # BUG: empty stem → disjoint (pre-#181)
  [[ -n "$sa" && -n "$sb" ]] || return 1
  [[ "$sa" == "$sb" ]] && return 0
  case "$sa" in "$sb"/*) return 0 ;; esac
  case "$sb" in "$sa"/*) return 0 ;; esac
  case "$sa" in "$sb"|"$sb"/*|"$sb".*) return 0 ;; esac
  case "$sb" in "$sa"|"$sa"/*|"$sa".*) return 0 ;; esac
  return 1
}
MUTBASH

# Prove the mutant is wrong on the two founding cases before asserting the sensor.
(
  # shellcheck source=/dev/null
  . "$MUT_BASH"
  mut_bad=0
  if scope_tokens_overlap '**' 'docs/a.md'; then
    : # mutant unexpectedly correct on ** — mutation miss
    mut_bad=1
  fi
  if scope_tokens_overlap '*' 'docs/a.md'; then
    mut_bad=1
  fi
  if [[ "$mut_bad" -eq 0 ]]; then
    ok "#181 Bash mutant exhibits pre-repair fail-open on ** and *"
  else
    bad "#181 Bash mutant did not reproduce fail-open (mutation miss)"
  fi
)

# Differential against mutant must fail (Bash disagrees with JS on **).
mut_js=$(js_pair_verdict '**' 'docs/a.md')
(
  # shellcheck source=/dev/null
  . "$MUT_BASH"
  if scope_tokens_overlap '**' 'docs/a.md'; then mut_bv=overlap; else mut_bv=disjoint; fi
  if [[ "$mut_js" == "overlap" && "$mut_bv" == "disjoint" ]]; then
    ok "#181 mutation receipt: Bash fail-open on ** diverges from JS (sensor would fail)"
  else
    bad "#181 mutation receipt: expected JS=overlap Bash=disjoint, got JS=$mut_js Bash=$mut_bv"
  fi
)

# --- mutation receipts: JS without root-wide / fail-closed empty stem ---
echo "#181 · mutation receipt: JS without root-wide must make sensor fail"
MUT_JS="$ROOT/mut-scope-overlap.mjs"
cp "$SENSOR" "$MUT_JS"
# Neutralize the ROOT_SCOPE short-circuit and empty-stem fail-closed in the pure kernel.
# Surgical: rewrite tokensOverlap body markers via perl for a known-bad kernel.
perl -0pi -e '
  s/if \(a === ROOT_SCOPE \|\| b === ROOT_SCOPE\) return true;\n  if \(a === b\) return true;/if (a === b) return true; \/* MUTATED no-root *\/\n/s;
  s/if \(!sa \|\| !sb\) return true;/if (!sa || !sb) return false; \/* MUTATED empty-stem-disjoint *\//s;
  s/if \(typeof a !== "string" \|\| typeof b !== "string"\) return true;\n  if \(a === "" \|\| b === ""\) return true;\n  \/\/ Unclassifiable evidence: refuse concurrency rather than wave through\.\n  if \(currentScopeTokenProblem\(a\) != null \|\| currentScopeTokenProblem\(b\) != null\) \{\n    return true;\n  \}/if (typeof a !== "string" || typeof b !== "string") return false;\n  if (a === "" || b === "") return false;\n  \/* MUTATED no-invalid-fail-closed *\/\n/s;
' "$MUT_JS"
if grep -q 'MUTATED no-root' "$MUT_JS" &&
   grep -q 'MUTATED empty-stem-disjoint' "$MUT_JS" &&
   grep -q 'MUTATED no-invalid-fail-closed' "$MUT_JS" &&
   node --check "$MUT_JS" 2>/dev/null; then
  ok "#181 JS mutant applied (no root-wide / empty-stem-disjoint / no invalid fail-closed)"
else
  bad "#181 JS mutant failed to apply or syntax-check"
fi

mut_js_root=$(node "$MUT_JS" --pair '**' 'docs/a.md' 2>/dev/null || true)
mut_js_star=$(node "$MUT_JS" --pair '*' 'docs/a.md' 2>/dev/null || true)
# Re-source production bash for the comparison baseline.
# shellcheck source=/dev/null
. "$BASH_KERNEL"
bash_root=$(bash_pair_verdict '**' 'docs/a.md')
bash_star=$(bash_pair_verdict '*' 'docs/a.md')
if [[ "$mut_js_root" == "disjoint" && "$bash_root" == "overlap" ]]; then
  ok "#181 mutation receipt: JS fail-open on ** diverges from Bash (sensor would fail)"
else
  bad "#181 JS ** mutant: got mut_js=$mut_js_root bash=$bash_root (want mut=disjoint bash=overlap)"
fi
if [[ "$mut_js_star" == "disjoint" && "$bash_star" == "overlap" ]]; then
  ok "#181 mutation receipt: JS fail-open on * diverges from Bash (sensor would fail)"
else
  bad "#181 JS * mutant: got mut_js=$mut_js_star bash=$bash_star (want mut=disjoint bash=overlap)"
fi

# Control: production --pair still agrees with production Bash on the founding cases.
ctrl_js=$(js_pair_verdict '**' 'docs/a.md')
ctrl_bash=$(bash_pair_verdict '**' 'docs/a.md')
[[ "$ctrl_js" == "overlap" && "$ctrl_bash" == "overlap" ]] &&
  ok "#181 control: production JS and Bash both overlap on ** vs concrete" ||
  bad "#181 control regressed: JS=$ctrl_js Bash=$ctrl_bash"

echo
echo "scope-overlap.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
