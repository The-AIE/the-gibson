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

run_so() {
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
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'not visible' && ok "invisible own claim refuses" \
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

echo "--pr-claims-file · decides on the caller's settled inventory, not a fresh read"
# claim.sh's admission barrier waits for the live inventory to go quiet and then
# hands that exact sample here. A re-read would throw the barrier away, so this
# flag must genuinely drive the decision — and must validate the sample exactly
# as a live read is validated (#153 review P1 0A).
SETTLED="$ROOT/settled.tsv"
# The stub pr-claims.sh output the sensor would have read is DELIBERATELY empty,
# so a run that passes only proves the file was ignored.
: > "$GH_PR_TSV"
{
  # The rival holds the lower number, so it wins the tie-break; this lane's own
  # row is present too, exactly as the barrier requires before it will decide.
  printf '640\tissue-65-settled\tapp/api/auth/**\tfeat/65-settled\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
  printf '700\tissue-66-late\tapp/api/auth/handlers.ts\tfeat/66-late\thttps://github.com/acme/app/pull/700\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n'
} > "$SETTLED"
out=$(run_so "$ROOT/d/canon" --scope 'app/api/auth/**' --repo acme/app --claim-id issue-66-late \
  --issue 66 --admit-pr 700 --pr-claims-file "$SETTLED"); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'issue-65-settled' \
  && ok "a rival present only in the settled inventory still refuses" \
  || bad "the settled inventory was ignored (rc=$rc): $out"

printf '640\tissue-67-self\tapp/api/auth/**\tfeat/67-self\thttps://github.com/acme/app/pull/640\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
  > "$SETTLED"
out=$(run_so "$ROOT/d/canon" --scope 'lib/unrelated/**' --repo acme/app --claim-id issue-67-self \
  --issue 67 --admit-pr 640 --pr-claims-file "$SETTLED"); rc=$?
[[ "$rc" -eq 0 ]] && ok "a settled inventory containing only this lane admits it" \
  || bad "settled self-only inventory refused (rc=$rc): $out"

out=$(run_so "$ROOT/d/canon" --scope 'x/**' --repo acme/app --claim-id issue-68-x \
  --issue 68 --admit-pr 641 --pr-claims-file "$ROOT/no-such-inventory.tsv"); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'cannot read the pre-read' \
  && ok "an unreadable settled inventory refuses (fail closed)" \
  || bad "unreadable settled inventory did not refuse (rc=$rc): $out"

printf 'garbage-row-with-two-fields\tonly\n' > "$SETTLED"
out=$(run_so "$ROOT/d/canon" --scope 'x/**' --repo acme/app --claim-id issue-69-x \
  --issue 69 --admit-pr 642 --pr-claims-file "$SETTLED"); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'malformed/truncated' \
  && ok "a malformed row in the settled inventory still refuses" \
  || bad "malformed settled row accepted (rc=$rc): $out"

out=$(run_so "$ROOT/d/canon" --scope 'x/**' --claim-id issue-70-x --pr-claims-file "$SETTLED"); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -qi 'requires --repo' \
  && ok "--pr-claims-file without --repo rejected" \
  || bad "--pr-claims-file without --repo (rc=$rc): $out"

# Reset the fixture for anything appended after this block.
printf '501\tissue-20-nav-shell\tcomponents/nav/**\tfeat/20-nav-shell\thttps://github.com/acme/app/pull/501\t2026-08-05T00:00:00Z\t2026-08-05T00:00:00Z\n' \
  > "$GH_PR_TSV"

echo
echo "scope-overlap.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
