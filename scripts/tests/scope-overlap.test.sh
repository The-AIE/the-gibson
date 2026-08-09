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
sed 's|const verdict = Atomics\.wait(cell, 0, 0, ms);|const verdict = "timed-out"; void cell; void ms;  /* TEST COPY: blocking removed */|' \
  "$SENSOR" > "$SENSOR_FAST"
# The CALL must be gone, not merely the word: the surrounding comments name
# Atomics.wait several times and would otherwise mask a failed substitution.
if grep -q 'TEST COPY: blocking removed' "$SENSOR_FAST" &&
   ! grep -q 'Atomics\.wait(cell' "$SENSOR_FAST"; then
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
    cat > docs/active-work.md <<'T'
| UTC | claim-id | scope | session |
|---|---|---|---|
| 2026-08-01T10:00:00Z | issue-7-password-reset | app/api/auth/** | grok@fleet |
| 2026-08-01T11:00:00Z | issue-9-legacy-only | src/legacy/** | other@fleet |
T
    # file form for 7; legacy-only for 9 (no claims file — table only after we
    # remove duplicate: keep both; sensor dedupes by id preferring file)
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
    # ensure table has issue-9 (already does) and push
    $GIT add -A
    $GIT commit -q -m "legacy row" --allow-empty 2>/dev/null || true
    # re-write table only — issue-9 is legacy-only
    cat > docs/active-work.md <<'T'
| UTC | claim-id | scope | session |
|---|---|---|---|
| 2026-08-01T10:00:00Z | issue-7-password-reset | app/api/auth/** | grok@fleet |
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
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
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
  printf '601\tissue-33-dup\tsrc/a/**\tfeat/33-dup\thttps://github.com/acme/app/pull/601\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
  printf '602\tissue-33-dup\tsrc/b/**\tfeat/33-dup-2\thttps://github.com/acme/app/pull/602\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
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
printf '701\tissue-40-empty-scope\t\tfeat/40-empty-scope\thttps://github.com/acme/app/pull/701\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo acme/app --claim-id issue-41-x); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'missing/empty claim scope' && ok "missing scope refuses (never silently empty)" \
  || bad "missing scope (rc=$rc): $out"

echo "missing/unsafe head branch on a live PR-body claim fails closed (#153 AC6)"
printf '702\tissue-42-bad-branch\tsrc/a/**\t\thttps://github.com/acme/app/pull/702\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo acme/app --claim-id issue-43-x); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'missing/unsafe head branch' && ok "missing branch refuses" \
  || bad "missing branch (rc=$rc): $out"

echo "PR URL repository mismatch vs --repo fails closed (#153 AC3)"
printf '703\tissue-44-wrong-repo\tsrc/a/**\tfeat/44-wrong-repo\thttps://github.com/other-org/other-app/pull/703\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
  > "$GH_PR_TSV"
out=$(run_so "$ROOT/d/canon" --scope 'unrelated/**' --repo acme/app --claim-id issue-45-x); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'unexpected repository identity' && ok "URL-repo mismatch refuses" \
  || bad "URL-repo mismatch (rc=$rc): $out"
# Reset fixture for anything appended after this block.
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
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
  printf '800\tissue-60-shared-lib\tlib/shared/**\tfeat/60-shared-lib\thttps://github.com/acme/app/pull/800\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
  printf '801\tissue-61-shared-util\tlib/shared/util.ts\tfeat/61-shared-util\thttps://github.com/acme/app/pull/801\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
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
  && echo "$out" | grep -qi 'could not obtain a stable live-claim inventory' \
  && ok "invisible own claim refuses" \
  || bad "invisible own claim admitted (rc=$rc): $out"

echo "--admit-pr · a LEDGER claim always beats an admission candidate"
printf '810\tissue-63-ledger-race\tapp/api/auth/**\tfeat/63-ledger-race\thttps://github.com/acme/app/pull/810\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
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
  printf '640\tissue-65-settled\tlib/gate/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
  printf '700\tissue-66-late\tlib/gate/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
} > "$GH_PR_TSV"

# The forgeries: an empty inventory, and one containing only this lane.
FORGED_EMPTY="$ROOT/forged-empty.tsv"
: > "$FORGED_EMPTY"
FORGED_SELF="$ROOT/forged-self.tsv"
printf '700\tissue-66-late\tlib/gate/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
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
printf '700\tissue-66-late\tlib/gate/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
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
printf '640\tissue-65-settled\tapp/api/auth/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
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
  printf '700\tissue-66-late\tapp/api/auth/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
  printf '%s\tissue-%s-churn\tlib/churn-%s/**\tfeat/%s-churn\thttps://github.com/acme/app/pull/%s\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
    "$((900 + n))" "$((800 + n))" "$n" "$((800 + n))" "$((900 + n))"
  exit 0
fi
printf '700\tissue-66-late\tapp/api/auth/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
if [[ "$n" -ge "${LAG_RIVAL_AFTER:-3}" ]]; then
  printf '640\tissue-65-settled\tapp/api/auth/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
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
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'could not obtain a stable live-claim inventory' \
  && ok "an inventory that never settles refuses rather than guesses" \
  || bad "unsettled inventory admitted (rc=$rc): $out"
unset LAG_READS

echo "#153 · admission refuses a second lane on the SAME issue without --slice"
{
  printf '640\tissue-65-settled\tlib/one/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
  printf '700\tissue-65-other\tlib/two/**\tfeat/65-other\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
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
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
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
printf '640\tissue-65-settled\tlib/sentinel/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
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

echo
echo "scope-overlap.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
