#!/usr/bin/env bash
# claim-expiry.test.sh — PR-body claim expiry (#557)
#
# WHAT IT DOES
#   Proves the expiry chain end to end without GitHub. A fake `gh` replays staged
#   PR nodes through the REAL jq filters inside pr-claims.sh, and answers the few
#   other gh calls (pr view / pr edit / label) from files, logging every call.
#     1. pr-claims.sh expiry: fresh / stale / unknown, a push renews, and `list`
#        keeps its 8-column contract.
#     2. scope-overlap.mjs: a fresh claim blocks; an expired one does not and the
#        displacement is recorded; a pushed-to one still blocks; an expiry that
#        cannot be read blocks (fail closed).
#     3. claim.sh --renew moves the date.
#     4. claim-reaper.sh labels an expired claim and NEVER closes anything, and
#        leaves unknown claims alone.
#
# WHY
#   The 2026-10-25 audit found claims that sat for weeks as zero-change draft PRs
#   and blocked everyone else's scope. The reaper protects every open PR by
#   design, so nothing ever expired. Expiry must free scope, and it must never
#   free a claim it could not read.
#
# USAGE
#   scripts/tests/claim-expiry.test.sh
set -uo pipefail
export GIBSON_AGENT_VENDOR="${GIBSON_AGENT_VENDOR:-claude}"
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS="$SCRIPT_DIR/.."
PC="$SCRIPTS/pr-claims.sh"
SENSOR="$SCRIPTS/scope-overlap.mjs"
CLAIM="$SCRIPTS/claim.sh"
REAPER="$SCRIPTS/claim-reaper.sh"
PASS=0
FAIL=0

ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
# Substring assertions written as case patterns, never `echo | grep -q`: a
# pipe into `grep -q` can SIGPIPE the writer under pipefail (L-077).
contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }
lacks()    { case "$2" in *"$3"*) bad "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

command_not_found_handle() {
  bad "the suite invoked an undefined command '$1' — a shell error may never coexist with a green tally"
  return 127
}

command -v node >/dev/null || { echo "claim-expiry.test.sh: node required"; exit 1; }
command -v jq   >/dev/null || { echo "claim-expiry.test.sh: jq required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-claim-expiry.XXXXXX")
trap 'rm -rf -- "${ROOT:?}"' EXIT
GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

# ISO-8601 UTC for now + N seconds (negative = past). GNU date first, BSD second.
iso_at() {
  local epoch=$(( $(date -u +%s) + $1 ))
  date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
    date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ"
}
DAY=86400

# --- fake gh ----------------------------------------------------------------
# graphql: replay $GH_PAGES (one page of nodes) through the REAL --jq filter.
# pr view N: print $ROOT/body-N.  pr edit N --body-file F: store F as body-N.
# Every call is appended to $GH_LOG so a test can assert what was NOT called.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "${GH_LOG:?}"
case "$1 $2" in
  "api graphql")
    shift 2
    jqexpr=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --jq) jqexpr="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    nodes=$(jq -c '.[0]' "${GH_PAGES:?}") || exit 1
    page=$(printf '{"data":{"repository":{"pullRequests":{"nodes":%s,"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' "$nodes")
    printf '%s' "$page" | jq -r "$jqexpr"
    exit $?
    ;;
  "repo view")
    echo "acme/app"
    exit 0
    ;;
  "pr view")
    cat "${GH_ROOT:?}/body-$3" 2>/dev/null || exit 1
    exit 0
    ;;
  "pr edit")
    n="$3"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --body-file) cp "$2" "${GH_ROOT:?}/body-$n"; shift 2 ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  "label create")
    exit 0
    ;;
esac
echo "fake gh: unhandled invocation: $*" >&2
exit 1
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
export GH_LOG="$ROOT/gh.log"
export GH_ROOT="$ROOT"
export GH_PAGES="$ROOT/pages.json"

# One staged PR node. $1 number, $2 claim id, $3 scope, $4 Claim-expires line
# value ('' = omit the line), $5 last commit date.
claim_node() {
  local n="$1" id="$2" scope="$3" exp="$4" last="$5" issue body
  issue=${id#issue-}; issue=${issue%%-*}
  body="- Claim schema: gibson.claim/v2\n- Active-work claim: ${id}\n- Issue: #${issue}\n- Claim scope: ${scope}\n- Claimed: 2026-10-01T00:00:00Z"
  [[ -z "$exp" ]] || body="${body}\n- Claim-expires: ${exp}"
  printf '{"number":%s,"body":"%s","headRefName":"feat/%s","url":"https://github.com/acme/app/pull/%s","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-02T00:00:00Z","isCrossRepository":false,"commits":{"nodes":[{"commit":{"committedDate":"%s"}}]}}' \
    "$n" "$body" "${id#issue-}" "$n" "$last"
}
stage() { printf '[[%s]]' "$1" > "$GH_PAGES"; }
state_of() { awk -F'\t' -v n="$2" '$1 == n { print $3 }' <<<"$1"; }

FRESH=$(iso_at $((3 * DAY)))
EXPIRED=$(iso_at $((-2 * DAY)))
OLD_PUSH=$(iso_at $((-10 * DAY)))
RECENT_PUSH=$(iso_at $((-1 * DAY)))

echo "pr-claims expiry · fresh claim"
: > "$GH_LOG"
stage "$(claim_node 11 issue-20-nav 'components/nav/**' "$FRESH" "$RECENT_PUSH")"
out=$("$PC" expiry acme/app 2>&1); rc=$?
check "expiry exits 0" "$rc" "0"
check "future Claim-expires is fresh" "$(state_of "$out" 11)" "fresh"

echo "pr-claims expiry · expired claim is stale"
stage "$(claim_node 12 issue-21-old 'lib/**' "$EXPIRED" "$OLD_PUSH")"
out=$("$PC" expiry acme/app 2>&1)
check "past Claim-expires with no recent push is stale" "$(state_of "$out" 12)" "stale"

echo "pr-claims expiry · a push renews the claim"
stage "$(claim_node 13 issue-22-pushed 'lib/**' "$EXPIRED" "$RECENT_PUSH")"
out=$("$PC" expiry acme/app 2>&1)
check "expired body date + push inside 7 days is fresh" "$(state_of "$out" 13)" "fresh"
eff=$(awk -F'\t' '$1 == 13 { print $6 }' <<<"$out")
if [[ "$eff" > "$(iso_at $((5 * DAY)))" ]]; then
  ok "effective expiry moved to last push + 7 days"
else
  bad "effective expiry did not move with the push (got '$eff')"
fi

echo "pr-claims expiry · unreadable expiry is never stale"
stage "$(claim_node 14 issue-23-missing 'lib/**' '' "$OLD_PUSH")"
out=$("$PC" expiry acme/app 2>&1)
check "missing Claim-expires is unknown" "$(state_of "$out" 14)" "unknown"
stage "$(claim_node 15 issue-24-garbage 'lib/**' 'next tuesday' "$OLD_PUSH")"
out=$("$PC" expiry acme/app 2>&1)
check "unparseable Claim-expires is unknown" "$(state_of "$out" 15)" "unknown"
stage "$(claim_node 16 issue-25-noncanon 'lib/**' '2026-10-01 12:00:00' "$OLD_PUSH")"
out=$("$PC" expiry acme/app 2>&1)
check "non-ISO Claim-expires is unknown" "$(state_of "$out" 16)" "unknown"
dup=$(claim_node 17 issue-26-dup 'lib/**' "$EXPIRED" "$OLD_PUSH" | sed 's|- Claim-expires: |- Claim-expires: '"$EXPIRED"'\\n- Claim-expires: |')
stage "$dup"
out=$("$PC" expiry acme/app 2>&1)
check "duplicate Claim-expires is unknown" "$(state_of "$out" 17)" "unknown"
stage "$(claim_node 18 issue-27-nodate 'lib/**' "$EXPIRED" '')"
out=$("$PC" expiry acme/app 2>&1)
check "missing head commit date is unknown" "$(state_of "$out" 18)" "unknown"

echo "pr-claims list · the 8-column contract is untouched"
stage "$(claim_node 19 issue-28-cols 'lib/**' "$FRESH" "$RECENT_PUSH")"
out=$("$PC" list acme/app 2>&1)
check "list row still has 8 fields" "$(awk -F'\t' 'NR==1 { print NF }' <<<"$out")" "8"

# --- scope-overlap.mjs ------------------------------------------------------
mkdir -p "$ROOT/repo"
$GIT init -q --bare "$ROOT/repo/origin"
git -C "$ROOT/repo/origin" symbolic-ref HEAD refs/heads/main
$GIT clone -q "$ROOT/repo/origin" "$ROOT/repo/canon" 2>/dev/null
(
  cd "$ROOT/repo/canon" || exit 1
  mkdir -p docs/claims
  echo base > README.md
  $GIT add -A
  $GIT commit -q -m base
  $GIT branch -M main
  $GIT push -q -u origin main
) >/dev/null 2>&1
run_so() { node "$SENSOR" --repo-path "$ROOT/repo/canon" --base main --repo acme/app "$@" 2>&1; }

echo "scope-overlap · a fresh claim blocks"
stage "$(claim_node 31 issue-30-held 'components/nav/**' "$FRESH" "$RECENT_PUSH")"
out=$(run_so --scope 'components/nav/Item.tsx' --claim-id issue-31-mine --issue 31); rc=$?
[[ "$rc" -ne 0 ]] && ok "fresh claim blocks overlapping scope" || bad "fresh claim did not block (rc=$rc): $out"
contains "the refusal names the holder" "$out" "issue-30-held"

echo "scope-overlap · an expired claim does not block, and the displacement is recorded"
stage "$(claim_node 32 issue-30-held 'components/nav/**' "$EXPIRED" "$OLD_PUSH")"
out=$(run_so --scope 'components/nav/Item.tsx' --claim-id issue-31-mine --issue 31); rc=$?
check "expired claim lets the new claim through" "$rc" "0"
contains "displacement is recorded in the output" "$out" "displaced expired claim issue-30-held (PR #32"
contains "machine line for claim.sh is emitted" "$out" "scope-overlap: displaced-claim issue-30-held 32 "
out=$(run_so --json --scope 'components/nav/Item.tsx' --claim-id issue-31-mine --issue 31); rc=$?
check "json mode also passes" "$rc" "0"
check "json displaced[0].claimId" "$(jq -r '.displaced[0].claimId' <<<"$out")" "issue-30-held"
check "json displaced[0].prNumber" "$(jq -r '.displaced[0].prNumber' <<<"$out")" "32"

echo "scope-overlap · an expired claim on unrelated files displaced nothing"
out=$(run_so --json --scope 'docs/other.md' --claim-id issue-33-mine --issue 33); rc=$?
check "unrelated scope passes" "$rc" "0"
check "no displacement recorded" "$(jq -r '.displaced | length' <<<"$out")" "0"

echo "scope-overlap · a push to the claim branch keeps the claim blocking"
stage "$(claim_node 34 issue-30-held 'components/nav/**' "$EXPIRED" "$RECENT_PUSH")"
out=$(run_so --scope 'components/nav/Item.tsx' --claim-id issue-31-mine --issue 31); rc=$?
[[ "$rc" -ne 0 ]] && ok "recently pushed claim still blocks" || bad "pushed claim was displaced (rc=$rc): $out"

echo "scope-overlap · an unreadable expiry blocks (fail closed)"
stage "$(claim_node 35 issue-30-held 'components/nav/**' 'soon-ish' "$OLD_PUSH")"
out=$(run_so --scope 'components/nav/Item.tsx' --claim-id issue-31-mine --issue 31); rc=$?
[[ "$rc" -ne 0 ]] && ok "unparseable expiry blocks" || bad "unparseable expiry displaced a claim (rc=$rc): $out"
stage "$(claim_node 36 issue-30-held 'components/nav/**' '' "$OLD_PUSH")"
out=$(run_so --scope 'components/nav/Item.tsx' --claim-id issue-31-mine --issue 31); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing expiry blocks" || bad "missing expiry displaced a claim (rc=$rc): $out"

# --- claim.sh --renew -------------------------------------------------------
echo "claim.sh --renew moves the date"
stage "$(claim_node 41 issue-40-renewme 'lib/**' "$EXPIRED" "$OLD_PUSH")"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-40-renewme\n- Issue: #40\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}\n\nbody text" > "$ROOT/body-41"
out=$(bash "$CLAIM" --renew 40 2>&1); rc=$?
check "renew exits 0" "$rc" "0"
new=$(sed -n 's/^- Claim-expires: //p' "$ROOT/body-41")
[[ "$new" > "$(iso_at $((7 * DAY - 300)))" ]] && ok "Claim-expires moved to about now + 7 days ($new)" ||
  bad "Claim-expires did not move out 7 days (got '$new')"
contains "the rest of the body is untouched" "$(cat "$ROOT/body-41")" "body text"
check "exactly one Claim-expires line remains" "$(grep -c '^- Claim-expires: ' "$ROOT/body-41")" "1"
out=$(bash "$CLAIM" --renew 99 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "renewing an issue with no live claim refuses" || bad "renew of an unclaimed issue passed: $out"
out=$(bash "$CLAIM" --renew abc 2>&1); rc=$?
check "non-numeric issue is a usage error" "$rc" "2"

# --- claim-reaper.sh --------------------------------------------------------
echo "claim-reaper labels an expired claim and closes nothing"
mkdir -p "$ROOT/reap"
$GIT init -q --bare "$ROOT/reap/origin"
git -C "$ROOT/reap/origin" symbolic-ref HEAD refs/heads/main
$GIT clone -q "$ROOT/reap/origin" "$ROOT/reap/canon" 2>/dev/null
(
  cd "$ROOT/reap/canon" || exit 1
  mkdir -p docs/claims
  echo base > README.md
  # A legacy ledger row with no open PR: its evidence-based reaping is not
  # part of #557 and must read exactly as before.
  cat > docs/claims/issue-7-legacy-dead.md <<'LEGACY'
claim: issue-7-legacy-dead
issue: 7
claimed: 2026-08-01T10:00:00Z
scope: src/legacy/**
session: grok@fleet
branch: feat/7-legacy-dead
worktree: /tmp/wt-7
LEGACY
  $GIT add -A
  $GIT commit -q -m base
  $GIT branch -M main
  $GIT push -q -u origin main
) >/dev/null 2>&1
stage "$(claim_node 51 issue-50-dead 'lib/**' "$EXPIRED" "$OLD_PUSH"),$(claim_node 52 issue-51-unreadable 'src/**' 'garbage' "$OLD_PUSH"),$(claim_node 53 issue-52-live 'app/**' "$FRESH" "$RECENT_PUSH")"

: > "$GH_LOG"
out=$(cd "$ROOT/reap/canon" && GIBSON_CANONICAL="$ROOT/reap/canon" bash "$REAPER" --repo acme/app 2>&1); rc=$?
check "dry run exits 0" "$rc" "0"
contains "dry run says it would label" "$out" "would label claim-expired"
lacks "dry run labels nothing" "$(cat "$GH_LOG")" "--add-label"
contains "legacy ledger row is still judged by its own evidence (unchanged: no worktree => REFUSE)" "$out" "REFUSE issue-7-legacy-dead  issue=#7  branch=feat/7-legacy-dead  (worktree_missing_or_unreadable)"

: > "$GH_LOG"
out=$(cd "$ROOT/reap/canon" && GIBSON_CANONICAL="$ROOT/reap/canon" bash "$REAPER" --repo acme/app --apply 2>&1); rc=$?
check "apply exits 0" "$rc" "0"
log=$(cat "$GH_LOG")
contains "apply labels the expired claim's PR" "$log" "pr edit 51 --repo acme/app --add-label claim-expired"
lacks "the unreadable-expiry claim is not labelled" "$log" "pr edit 52"
lacks "the live claim is not labelled" "$log" "pr edit 53"
lacks "no PR is closed" "$log" "pr close"
lacks "no issue is closed" "$log" "issue close"
lacks "no PR is merged" "$log" "pr merge"
contains "every open PR claim is still protected" "$out" "PR #51 claim issue-50-dead is protected"

echo
echo "claim-expiry.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
