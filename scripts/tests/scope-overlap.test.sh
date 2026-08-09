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
# Fake `sleep`: the publication barrier spaces its reads with the PATH command
# `sleep`, so shimming that command is how a sensor accelerates the WAIT
# without touching what the barrier REQUIRES. The floor on consecutive
# matching reads is untouched here and is asserted separately below. This is a
# command shim, not a production hook: an ordinary inherited environment does
# not carry a fake `sleep`, and nothing in scope-overlap.mjs reads a variable
# that names an executable.
cat > "$ROOT/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
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

echo
echo "scope-overlap.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
