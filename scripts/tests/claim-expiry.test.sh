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
REAL_NODE=$(command -v node)

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
    joined="$*"
    shift 2
    jqexpr=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --jq) jqexpr="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    src="${GH_PAGES:?}"
    # Optional: the first expiry query that runs only after two list queries
    # (the old "read expiry once after settle" shape) replays GH_PAGES_LATE.
    # Expiry reads interleaved with the settle reads keep GH_PAGES.
    if [[ "$joined" == *claimExpiry* ]]; then
      n=0
      [[ -f "${GH_ROOT:?}/expiry-n" ]] && n=$(cat "$GH_ROOT/expiry-n")
      n=$((n + 1))
      printf '%s' "$n" > "$GH_ROOT/expiry-n"
      lists=0
      [[ -f "$GH_ROOT/list-n" ]] && lists=$(cat "$GH_ROOT/list-n")
      if [[ -n "${GH_EXPIRY_ROTATE:-}" ]]; then
        src="$GH_EXPIRY_ROTATE"
      elif [[ -n "${GH_PAGES_LATE:-}" && "$lists" -ge 2 && "$n" -eq 1 ]]; then
        src="$GH_PAGES_LATE"
      fi
    else
      n=0
      [[ -f "${GH_ROOT:?}/list-n" ]] && n=$(cat "$GH_ROOT/list-n")
      n=$((n + 1))
      printf '%s' "$n" > "$GH_ROOT/list-n"
    fi
    if [[ "$joined" == *claimExpiry* && -n "${GH_EXPIRY_ROTATE:-}" ]]; then
      # JSON array of pages. Expiry read n (1-based) selects index (n-1) mod length.
      len=$(jq 'length' "$src") || exit 1
      idx=$(( (n - 1) % len ))
      nodes=$(jq -c ".[$idx]" "$src") || exit 1
    else
      nodes=$(jq -c '.[0]' "$src") || exit 1
    fi
    page=$(printf '{"data":{"repository":{"pullRequests":{"nodes":%s,"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' "$nodes")
    printf '%s' "$page" | jq -r "$jqexpr"
    exit $?
    ;;
  "repo view")
    # The repository gh resolves depends on the checkout it runs in.
    if [[ -f "$PWD/.fake-gh-repo" ]]; then cat "$PWD/.fake-gh-repo"; else echo "acme/app"; fi
    exit 0
    ;;
  "pr view")
    cat "${GH_ROOT:?}/body-$3" 2>/dev/null || exit 1
    exit 0
    ;;
  "pr edit")
    n="$3"
    # A test can refuse the body write for one PR number. The body file is
    # left as it was, which is what a failed gh pr edit does.
    if [[ -n "${GH_FAIL_BODY_FOR:-}" && "$n" == "$GH_FAIL_BODY_FOR" ]]; then
      exit 1
    fi
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --body-file) cp "$2" "${GH_ROOT:?}/body-$n"; shift 2 ;;
        *) shift ;;
      esac
    done
    # Optional: the first body write publishes a different inventory, so a
    # post-write overlap recheck can see a rival the pre-write check missed.
    if [[ -n "${GH_PAGES_ON_EDIT:-}" ]]; then
      cp "$GH_PAGES_ON_EDIT" "${GH_PAGES:?}"
    fi
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
  local n="$1" id="$2" scope="$3" exp="$4" last="$5" issue body suites
  issue=${id#issue-}; issue=${issue%%-*}
  body="- Claim schema: gibson.claim/v2\n- Active-work claim: ${id}\n- Issue: #${issue}\n- Claim scope: ${scope}\n- Claimed: 2026-10-01T00:00:00Z"
  [[ -z "$exp" ]] || body="${body}\n- Claim-expires: ${exp}"
  # committedDate is ancient on purpose. A reader that treats commit metadata
  # as the push clock fails "a push renews" below, because the check-suite
  # time is the only clock that moves.
  if [[ -z "$last" ]]; then
    suites='"checkSuites":{"nodes":[]}'
  else
    suites=$(printf '"checkSuites":{"nodes":[{"createdAt":"%s"}]}' "$last")
  fi
  printf '{"number":%s,"body":"%s","headRefName":"feat/%s","url":"https://github.com/acme/app/pull/%s","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-02T00:00:00Z","isCrossRepository":false,"commits":{"nodes":[{"commit":{"committedDate":"2020-01-01T00:00:00Z",%s}}]}}' \
    "$n" "$body" "${id#issue-}" "$n" "$suites"
}
# Same node plus extra raw body lines ($6, '\n'-separated, JSON-escaped already).
claim_node_extra() {
  claim_node "$1" "$2" "$3" "$4" "$5" | sed 's|- Claimed: 2026-10-01T00:00:00Z|- Claimed: 2026-10-01T00:00:00Z\\n'"$6"'|'
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
check "missing head push time is unknown" "$(state_of "$out" 18)" "unknown"

echo "pr-claims expiry · committedDate is not a push"
recent_commit=$(iso_at -100)
forged=$(claim_node 23 issue-29-forged 'lib/**' "$EXPIRED" "$OLD_PUSH" | sed "s/2020-01-01T00:00:00Z/${recent_commit}/")
stage "$forged"
out=$("$PC" expiry acme/app 2>&1)
check "a recent committedDate with an old check suite stays stale" "$(state_of "$out" 23)" "stale"
two=$(claim_node 24 issue-29-two 'lib/**' "$EXPIRED" "$OLD_PUSH" | sed "s/{\"createdAt\":\"${OLD_PUSH}\"}/{\"createdAt\":\"${OLD_PUSH}\"},{\"createdAt\":\"${RECENT_PUSH}\"}/")
stage "$two"
out=$("$PC" expiry acme/app 2>&1)
check "the newest of two check suites renews; the older one does not keep it stale" "$(state_of "$out" 24)" "fresh"
# The recent stamp sits only on the tail alias. A reader that ignores
# checkSuitesTail and keeps the old suite in checkSuites reports stale.
tailed=$(claim_node 25 issue-29-tail 'lib/**' "$EXPIRED" "$OLD_PUSH" | sed "s/\"checkSuites\":/\"checkSuitesTail\":{\"nodes\":[{\"createdAt\":\"${RECENT_PUSH}\"}]},\"checkSuites\":/")
stage "$tailed"
out=$("$PC" expiry acme/app 2>&1)
check "a newer suite on the other end of the connection still renews" "$(state_of "$out" 25)" "fresh"

echo "pr-claims expiry · displacement is terminal"
DISP='- Displaced by: issue-31-mine (PR #99)'
stage "$(claim_node_extra 61 issue-60-gone 'lib/**' "$EXPIRED" "$OLD_PUSH" "$DISP"),$(claim_node 99 issue-31-mine 'docs/z/**' "$FRESH" "$RECENT_PUSH")"
out=$("$PC" expiry acme/app 2>&1)
check "expired + Displaced by is displaced" "$(state_of "$out" 61)" "displaced"
contains "the displacer is named" "$out" "displaced by issue-31-mine (PR #99)"
stage "$(claim_node_extra 62 issue-60-gone 'lib/**' "$FRESH" "$RECENT_PUSH" "$DISP"),$(claim_node 99 issue-31-mine 'docs/z/**' "$FRESH" "$RECENT_PUSH")"
out=$("$PC" expiry acme/app 2>&1)
check "a fresh date and a recent push do not revive a displaced claim" "$(state_of "$out" 62)" "displaced"
stage "$(claim_node_extra 63 issue-60-gone 'lib/**' "$EXPIRED" "$OLD_PUSH" '- Displaced by: someone maybe')"
out=$("$PC" expiry acme/app 2>&1)
check "an unreadable Displaced by record is unknown (blocks)" "$(state_of "$out" 63)" "unknown"

echo "pr-claims expiry · a successor keeps the predecessor displaced after the intermediate closes"
# A was displaced by B. C later displaced B and was recorded beside B.
# B has closed (absent). A's own clock is fresh. C being live is what holds A.
# '\\n' is the two-character JSON escape. A single '\n' is a real newline
# inside the sed replacement and the staged node stops parsing.
BOTH='- Displaced by: issue-40-mid (PR #40)\\n- Displaced by: issue-50-new (PR #50)'
stage "$(claim_node_extra 32 issue-30-old 'lib/**' "$FRESH" "$RECENT_PUSH" "$BOTH"),$(claim_node 50 issue-50-new 'lib/**' "$FRESH" "$RECENT_PUSH")"
out=$("$PC" expiry acme/app 2>&1)
check "intermediate closed, successor live: still displaced" "$(state_of "$out" 32)" "displaced"
contains "the live successor is named" "$out" "displaced by issue-50-new (PR #50)"
# C rolled back (absent) and B is still open: the original line still holds A.
stage "$(claim_node_extra 32 issue-30-old 'lib/**' "$FRESH" "$RECENT_PUSH" "$BOTH"),$(claim_node 40 issue-40-mid 'lib/**' "$FRESH" "$RECENT_PUSH")"
out=$("$PC" expiry acme/app 2>&1)
check "successor rolled back, intermediate live: still displaced" "$(state_of "$out" 32)" "displaced"

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

echo "scope-overlap · a displaced claim stays non-blocking, even with a fresh date and a push"
stage "$(claim_node_extra 37 issue-30-held 'components/nav/**' "$FRESH" "$RECENT_PUSH" "$DISP"),$(claim_node 99 issue-31-mine 'docs/z/**' "$FRESH" "$RECENT_PUSH")"
out=$(run_so --json --scope 'components/nav/Item.tsx' --claim-id issue-31-mine --issue 31); rc=$?
check "displaced claim does not block" "$rc" "0"
check "it is not displaced a second time" "$(jq -r '.displaced | length' <<<"$out")" "0"
check "a live displacer is not retargeted" "$(jq -r '.displacedPredecessors | length' <<<"$out")" "0"
echo "scope-overlap · an unreadable displacement record blocks (fail closed)"
stage "$(claim_node_extra 38 issue-30-held 'components/nav/**' "$EXPIRED" "$OLD_PUSH" '- Displaced by: ???')"
out=$(run_so --scope 'components/nav/Item.tsx' --claim-id issue-31-mine --issue 31); rc=$?
[[ "$rc" -ne 0 ]] && ok "unreadable Displaced by blocks" || bad "unreadable displacement record revived/displaced a claim (rc=$rc): $out"

echo "scope-overlap · displacing a stale intermediate also names its predecessor"
PRED='- Displaced by: issue-40-mid (PR #40)'
pred_a=$(claim_node_extra 32 issue-30-old 'lib/**' "$FRESH" "$RECENT_PUSH" "$PRED")
mid_b=$(claim_node 40 issue-40-mid 'lib/**' "$EXPIRED" "$OLD_PUSH")
unrel=$(claim_node_extra 33 issue-33-other 'docs/**' "$FRESH" "$RECENT_PUSH" "$PRED")
stage "${pred_a},${mid_b},${unrel}"
out=$(run_so --scope 'lib/util/**' --claim-id issue-50-new --issue 50); rc=$?
check "the stale intermediate does not block" "$rc" "0"
contains "the intermediate is the direct displacement" "$out" "scope-overlap: displaced-claim issue-40-mid 40 "
contains "the predecessor is named for the new claim" "$out" "scope-overlap: displaced-predecessor issue-30-old 32 "
lacks "an unrelated scope is not a predecessor" "$out" "issue-33-other"
out=$(run_so --json --scope 'lib/util/**' --claim-id issue-50-new --issue 50); rc=$?
check "json mode passes the chain" "$rc" "0"
check "json names one predecessor" "$(jq -r '.displacedPredecessors | length' <<<"$out")" "1"
check "json predecessor is the overlapping claim" "$(jq -r '.displacedPredecessors[0].claimId' <<<"$out")" "issue-30-old"
check "json predecessor PR" "$(jq -r '.displacedPredecessors[0].prNumber' <<<"$out")" "32"

echo "scope-overlap · the predecessor chain is transitive"
# A displaced by B, B displaced by D, D now stale. C overlapping D must name B and A.
chain_a=$(claim_node_extra 32 issue-30-old 'lib/**' "$EXPIRED" "$OLD_PUSH" '- Displaced by: issue-40-mid (PR #40)')
chain_b=$(claim_node_extra 40 issue-40-mid 'lib/**' "$EXPIRED" "$OLD_PUSH" '- Displaced by: issue-41-late (PR #41)')
chain_d=$(claim_node 41 issue-41-late 'lib/**' "$EXPIRED" "$OLD_PUSH")
stage "${chain_a},${chain_b},${chain_d}"
out=$(run_so --json --scope 'lib/**' --claim-id issue-50-new --issue 50); rc=$?
check "transitive chain admits" "$rc" "0"
check "only the stale tail is a direct displacement" "$(jq -r '.displaced | length' <<<"$out")" "1"
check "the stale tail is D" "$(jq -r '.displaced[0].claimId' <<<"$out")" "issue-41-late"
check "both earlier claims are predecessors" "$(jq -r '.displacedPredecessors | length' <<<"$out")" "2"
check "predecessors are ordered by PR number" "$(jq -r '[.displacedPredecessors[].claimId] | join(",")' <<<"$out")" "issue-30-old,issue-40-mid"

echo "scope-overlap admission · expiry is part of the settled snapshot, not a later read"
rm -f "$ROOT/expiry-n" "$ROOT/list-n"
fresh_page="$(claim_node 100 issue-100-new 'docs/only/**' "$FRESH" "$RECENT_PUSH"),$(claim_node 90 issue-90-rival 'lib/**' "$EXPIRED" "$RECENT_PUSH")"
stale_page="$(claim_node 100 issue-100-new 'docs/only/**' "$FRESH" "$RECENT_PUSH"),$(claim_node 90 issue-90-rival 'lib/**' "$EXPIRED" "$OLD_PUSH")"
stage "$fresh_page"
printf '[[%s]]' "$stale_page" > "$ROOT/pages-late.json"
export GH_PAGES_LATE="$ROOT/pages-late.json"
out=$(GIBSON_CLAIM_ADMIT_DELAY=1 GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=4 \
  run_so --scope 'lib/**' --claim-id issue-100-new --issue 100 --admit-pr 100); rc=$?
[[ "$rc" -ne 0 ]] && ok "a rival that is fresh in the settled expiry snapshot still blocks" ||
  bad "admission displaced a rival from a post-settle stale read (rc=$rc): $out"
contains "the refusal names the rival" "$out" "issue-90-rival"
lacks "the post-settle page was not what decided" "$out" "displaced expired claim issue-90-rival"
unset GH_PAGES_LATE
rm -f "$ROOT/expiry-n" "$ROOT/list-n"

# Two expiry pages that differ only in an unrelated claim's push clock must
# still settle. A page pair whose state flips must not.
write_rotate() { # $1 ours-json $2 pageA-rival $3 pageB-rival $4 dest
  node -e 'const fs=require("fs"); const a=JSON.parse(process.argv[1]); const b=JSON.parse(process.argv[2]); const c=JSON.parse(process.argv[3]); fs.writeFileSync(process.argv[4], JSON.stringify([[a,b],[a,c]]));' \
    "$1" "$2" "$3" "$4"
}
echo "scope-overlap admission · an unrelated push clock does not reset quiescence"
rm -f "$ROOT/expiry-n" "$ROOT/list-n"
ours=$(claim_node 110 issue-110-settle 'docs/only/**' "$FRESH" "$RECENT_PUSH")
rival_a=$(claim_node 111 issue-111-other 'lib/**' "$FRESH" "$RECENT_PUSH")
rival_b=$(claim_node 111 issue-111-other 'lib/**' "$FRESH" "$(iso_at -3600)")
stage "${ours},${rival_a}"
write_rotate "$ours" "$rival_a" "$rival_b" "$ROOT/expiry-rotate.json"
out=$(GH_EXPIRY_ROTATE="$ROOT/expiry-rotate.json" \
  GIBSON_CLAIM_ADMIT_DELAY=1 GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=3 \
  run_so --scope 'docs/only/**' --claim-id issue-110-settle --issue 110 --admit-pr 110); rc=$?
check "admission settles while an unrelated claim's push clock moves" "$rc" "0"
contains "the union was quiescent" "$out" "quiescent"

echo "scope-overlap admission · a stale-to-fresh flip still breaks quiescence"
rm -f "$ROOT/expiry-n" "$ROOT/list-n"
ours=$(claim_node 112 issue-112-settle 'docs/only/**' "$FRESH" "$RECENT_PUSH")
rival_stale=$(claim_node 113 issue-113-flip 'lib/**' "$EXPIRED" "$OLD_PUSH")
rival_fresh=$(claim_node 113 issue-113-flip 'lib/**' "$EXPIRED" "$RECENT_PUSH")
stage "${ours},${rival_stale}"
write_rotate "$ours" "$rival_stale" "$rival_fresh" "$ROOT/expiry-rotate.json"
out=$(GH_EXPIRY_ROTATE="$ROOT/expiry-rotate.json" \
  GIBSON_CLAIM_ADMIT_DELAY=1 GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=3 \
  run_so --scope 'lib/**' --claim-id issue-112-settle --issue 112 --admit-pr 112); rc=$?
[[ "$rc" -ne 0 ]] && ok "a rival flipping stale to fresh refuses admission" ||
  bad "admission settled across a state change (rc=$rc): $out"
lacks "a flipping rival was not displaced" "$out" "displaced expired claim issue-113-flip"
unset GH_EXPIRY_ROTATE
rm -f "$ROOT/expiry-n" "$ROOT/list-n" "$ROOT/expiry-rotate.json"

# --- claim.sh --renew -------------------------------------------------------
echo "claim.sh --renew moves the date"
stage "$(claim_node 41 issue-40-renewme 'lib/**' "$EXPIRED" "$OLD_PUSH")"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-40-renewme\n- Issue: #40\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}\n\nbody text" > "$ROOT/body-41"
out=$(GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 40 2>&1); rc=$?
check "renew exits 0" "$rc" "0"
new=$(sed -n 's/^- Claim-expires: //p' "$ROOT/body-41")
[[ "$new" > "$(iso_at $((7 * DAY - 300)))" ]] && ok "Claim-expires moved to about now + 7 days ($new)" ||
  bad "Claim-expires did not move out 7 days (got '$new')"
contains "the rest of the body is untouched" "$(cat "$ROOT/body-41")" "body text"
check "exactly one Claim-expires line remains" "$(grep -c '^- Claim-expires: ' "$ROOT/body-41")" "1"
out=$(GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 99 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "renewing an issue with no live claim refuses" || bad "renew of an unclaimed issue passed: $out"
out=$(bash "$CLAIM" --renew abc 2>&1); rc=$?
check "non-numeric issue is a usage error" "$rc" "2"

echo "claim.sh --renew refuses a displaced claim"
stage "$(claim_node_extra 43 issue-42-gone 'lib/**' "$EXPIRED" "$OLD_PUSH" "$DISP"),$(claim_node 99 issue-31-mine 'docs/z/**' "$FRESH" "$RECENT_PUSH")"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-42-gone\n- Issue: #42\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}\n- Displaced by: issue-31-mine (PR #99)" > "$ROOT/body-43"
before=$(cat "$ROOT/body-43")
out=$(GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 42 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "renew after displacement refuses" || bad "renew revived a displaced claim: $out"
contains "the refusal names the displacer" "$out" "issue-31-mine (PR #99)"
check "the body is untouched" "$(cat "$ROOT/body-43")" "$before"
# The expiry verdict comes from the GraphQL fixture, not from body-43.
# Staging the garbage line only in the body file leaves the valid displacer
# in GH_PAGES, and renew refuses as "already displaced" before it ever sees
# the unreadable record.
stage "$(claim_node_extra 43 issue-42-gone 'lib/**' "$EXPIRED" "$OLD_PUSH" '- Displaced by: garbage')"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-42-gone\n- Issue: #42\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}\n- Displaced by: garbage" > "$ROOT/body-43"
out=$(GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 42 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an unreadable Displaced by record refuses the renew" || bad "renew passed on an unreadable displacement record: $out"
contains "the refusal names the unreadable record" "$out" "cannot read"
lacks "it did not refuse as an already-readable displacement" "$out" "was displaced and cannot be renewed"

echo "claim.sh --renew is an admission: it refuses when it would overlap a live claim"
stage "$(claim_node 44 issue-43-mine 'lib/**' "$EXPIRED" "$OLD_PUSH"),$(claim_node 45 issue-44-rival 'lib/util/**' "$FRESH" "$RECENT_PUSH")"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-43-mine\n- Issue: #43\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}" > "$ROOT/body-44"
before=$(cat "$ROOT/body-44")
out=$(GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 43 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "renew that overlaps a live claim refuses" || bad "renew admitted an overlap: $out"
contains "the overlap is named" "$out" "issue-44-rival"
check "the date did not move" "$(cat "$ROOT/body-44")" "$before"

echo "claim.sh --renew refuses when the overlapping rival is itself stale"
stage "$(claim_node 46 issue-45-mine 'lib/**' "$EXPIRED" "$OLD_PUSH"),$(claim_node 47 issue-46-stale 'lib/util/**' "$EXPIRED" "$OLD_PUSH")"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-45-mine\n- Issue: #45\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}\n\nbody text" > "$ROOT/body-46"
before=$(cat "$ROOT/body-46")
: > "$GH_LOG"
out=$(GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 45 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "renew that would overlap a stale claim refuses" || bad "renew displaced or admitted a stale rival: $out"
contains "the refusal says renew does not displace" "$out" "renew does not displace"
check "the renewing body is untouched" "$(cat "$ROOT/body-46")" "$before"
lacks "the stale rival is not stamped" "$(cat "$GH_LOG")" "pr edit 47"

echo "claim.sh --renew re-reads the body and edits only Claim-expires"
stage "$(claim_node 48 issue-47-reread 'lib/**' "$EXPIRED" "$OLD_PUSH")"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-47-reread\n- Issue: #47\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}\n\nbody text" > "$ROOT/body-48"
cat > "$ROOT/bin/node" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *scope-overlap.mjs* && -n "\${GH_INJECT_BODY_LINE:-}" ]]; then
  printf '%s\n' "\$GH_INJECT_BODY_LINE" >> "\${GH_INJECT_BODY_FILE:?}"
fi
exec ${REAL_NODE} "\$@"
EOF
chmod +x "$ROOT/bin/node"
out=$(GH_INJECT_BODY_LINE="CONCURRENT NOTE" GH_INJECT_BODY_FILE="$ROOT/body-48" \
  GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 47 2>&1); rc=$?
check "renew survives a concurrent body line" "$rc" "0"
contains "the concurrent line is kept" "$(cat "$ROOT/body-48")" "CONCURRENT NOTE"
contains "the original prose is kept" "$(cat "$ROOT/body-48")" "body text"
new=$(sed -n 's/^- Claim-expires: //p' "$ROOT/body-48")
[[ "$new" > "$(iso_at $((7 * DAY - 300)))" ]] && ok "only Claim-expires moved ($new)" ||
  bad "Claim-expires did not move (got '$new')"
out=$(GH_INJECT_BODY_LINE="- Displaced by: issue-31-mine (PR #99)" GH_INJECT_BODY_FILE="$ROOT/body-48" \
  GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 47 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a Displaced by line that lands during the check refuses the renew" ||
  bad "renew erased or ignored a Displaced by line: $out"
contains "the Displaced by line is still there" "$(cat "$ROOT/body-48")" "- Displaced by: issue-31-mine (PR #99)"
check "Claim-expires was not rewritten over that line" "$(sed -n 's/^- Claim-expires: //p' "$ROOT/body-48")" "$new"
rm -f "$ROOT/bin/node"
unset GH_INJECT_BODY_LINE GH_INJECT_BODY_FILE

echo "claim.sh --renew restores the body when a rival appears during the write"
stage "$(claim_node 49 issue-48-race 'lib/**' "$EXPIRED" "$OLD_PUSH")"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-48-race\n- Issue: #48\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}\n\nbody text" > "$ROOT/body-49"
before=$(cat "$ROOT/body-49")
rival_page="$(claim_node 49 issue-48-race 'lib/**' "$EXPIRED" "$OLD_PUSH"),$(claim_node 50 issue-49-rival 'lib/util/**' "$FRESH" "$RECENT_PUSH")"
printf '[[%s]]' "$rival_page" > "$ROOT/pages-on-edit.json"
out=$(GH_PAGES_ON_EDIT="$ROOT/pages-on-edit.json" \
  GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 48 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a rival that appears during the write refuses the renew" ||
  bad "renew kept a date move over a concurrent rival: $out"
contains "the refusal says the previous body was restored" "$out" "restored the previous body"
contains "the rival is named" "$out" "issue-49-rival"
check "Claim-expires was restored" "$(cat "$ROOT/body-49")" "$before"
contains "the original prose survived the restore" "$(cat "$ROOT/body-49")" "body text"

echo "a Displaced-by whose displacer is not a live claim is ignored"
stage "$(claim_node_extra 71 issue-70-stranded 'lib/**' "$EXPIRED" "$OLD_PUSH" "$DISP")"
out=$("$PC" expiry acme/app 2>&1)
check "dead displacer: the claim is judged by its own expiry (stale)" "$(state_of "$out" 71)" "stale"
stage "$(claim_node_extra 72 issue-70-stranded 'lib/**' "$FRESH" "$RECENT_PUSH" "$DISP")"
out=$("$PC" expiry acme/app 2>&1)
check "dead displacer: a fresh claim stays fresh" "$(state_of "$out" 72)" "fresh"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-70-stranded\n- Issue: #70\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}\n- Displaced by: issue-31-mine (PR #99)" > "$ROOT/body-73"
stage "$(claim_node_extra 73 issue-70-stranded 'lib/**' "$EXPIRED" "$OLD_PUSH" "$DISP")"
out=$(GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 70 2>&1); rc=$?
check "renew of a claim whose displacer is dead works" "$rc" "0"
new=$(sed -n 's/^- Claim-expires: //p' "$ROOT/body-73")
[[ "$new" > "$(iso_at $((7 * DAY - 300)))" ]] && ok "and moves the date" || bad "date did not move (got '$new')"

echo "claim.sh --renew refuses a predecessor line even when nothing else overlaps"
stage "$(claim_node 51 issue-50-pred 'docs/only/**' "$EXPIRED" "$OLD_PUSH")"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-50-pred\n- Issue: #50\n- Claim scope: docs/only/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}\n\nbody text" > "$ROOT/body-51"
before=$(cat "$ROOT/body-51")
cat > "$ROOT/bin/node" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *scope-overlap.mjs* ]]; then
  out=\$(${REAL_NODE} "\$@")
  rc=\$?
  printf '%s\\n' "\$out"
  if [[ \$rc -eq 0 ]]; then
    printf '%s\\n' "scope-overlap: displaced-predecessor issue-30-old 32 ${EXPIRED}"
  fi
  exit \$rc
fi
exec ${REAL_NODE} "\$@"
EOF
chmod +x "$ROOT/bin/node"
out=$(GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 50 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a predecessor line refuses the renew" || bad "renew ignored a predecessor line: $out"
contains "renew does not displace a predecessor" "$out" "renew does not displace"
check "the predecessor renew left the body alone" "$(cat "$ROOT/body-51")" "$before"
rm -f "$ROOT/bin/node"

echo "record_displacement succeeds only when the new line reads back"
sed -n '/^record_displacement() {/,/^}$/p' "$CLAIM" > "$ROOT/record-displacement.fn.sh"
# shellcheck disable=SC1091
source "$ROOT/record-displacement.fn.sh"
# Used by the sourced record_displacement function. Exported so shellcheck
# can see the handoff; the function reads it in this same shell.
export REPO=acme/app
printf 'existing\n' > "$ROOT/body-77"
record_displacement 77 "- Displaced claim: issue-30-old (PR #32, expired ${EXPIRED})"
rc=$?
check "a readable-back note succeeds" "$rc" "0"
contains "the note is in the body" "$(cat "$ROOT/body-77")" "- Displaced claim: issue-30-old (PR #32, expired ${EXPIRED})"
export GH_FAIL_BODY_FOR=78
printf 'existing\n' > "$ROOT/body-78"
before78=$(cat "$ROOT/body-78")
record_displacement 78 "- Displaced claim: issue-30-old (PR #32, expired ${EXPIRED})"
rc=$?
[[ "$rc" -ne 0 ]] && ok "a failed body write does not report the note recorded" ||
  bad "record_displacement returned 0 when gh pr edit failed (rc=$rc)"
check "the failed write left the body untouched" "$(cat "$ROOT/body-78")" "$before78"
unset REPO GH_FAIL_BODY_FOR

echo "claim.sh stamps the terminal Displaced-by record LAST (after every gate that can roll the claim back)"
prov_line=$(grep -n 'info "reservation: \$RESERVATION_SHA"' "$CLAIM" | head -1 | cut -d: -f1)
stamp_line=$(grep -n '"- Displaced by: \${CLAIM_ID}' "$CLAIM" | head -1 | cut -d: -f1)
done_line=$(grep -n '^CLAIM_COMPLETE=1' "$CLAIM" | head -1 | cut -d: -f1)
if [[ -n "$prov_line" && -n "$stamp_line" && -n "$done_line" && "$stamp_line" -gt "$prov_line" && "$stamp_line" -lt "$done_line" ]]; then
  ok "the stamp sits after provenance verification and before CLAIM_COMPLETE"
else
  bad "the stamp is not the last step (provenance=$prov_line stamp=$stamp_line complete=$done_line)"
fi
stamp_block=$(sed -n "${prov_line},${stamp_line}p" "$CLAIM")
contains "the stamp re-reads expiry and compares before it writes" "$stamp_block" "was stale in the admission snapshot"
reread_line=$(grep -n 'was stale in the admission snapshot' "$CLAIM" | head -1 | cut -d: -f1)
if [[ -n "$reread_line" && "$reread_line" -lt "$stamp_line" ]]; then
  ok "a claim that is no longer stale is refused before Displaced by is written"
else
  bad "the stale re-read is not before the stamp (reread=$reread_line stamp=$stamp_line)"
fi
note_line=$(grep -n 'both PR bodies must name it' "$CLAIM" | head -1 | cut -d: -f1)
if [[ -n "$note_line" && "$note_line" -gt "$stamp_line" && "$note_line" -lt "$done_line" ]]; then
  ok "a missing note on this PR dies before CLAIM_COMPLETE"
else
  bad "the new-PR displacement note is not a failing step before success (note=$note_line stamp=$stamp_line complete=$done_line)"
fi
lacks "the new-PR note is not a warning" "$(sed -n '/record_displacement "\$PR_NUMBER"/,/^CLAIM_COMPLETE=1/p' "$CLAIM")" "WARNING: could not record the displacement"
contains "predecessor rows are stamped" "$(sed -n '/^while IFS= read -r _dl; do$/,/^done <<EOF$/p' "$CLAIM")" "displaced-predecessor"

echo "claim.sh --renew passes a literal glob scope to the sensor (no pathname expansion)"
mkdir -p "$ROOT/repo/canon/lib"
echo x > "$ROOT/repo/canon/lib/a.js"
stage "$(claim_node 81 issue-80-glob 'lib/**' "$EXPIRED" "$OLD_PUSH"),$(claim_node 82 issue-81-rival 'lib/util/**' "$FRESH" "$RECENT_PUSH")"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-80-glob\n- Issue: #80\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}" > "$ROOT/body-81"
before=$(cat "$ROOT/body-81")
out=$(GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 80 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "lib/** is compared literally and collides with lib/util/**" || bad "glob expansion hid the overlap and the renew passed: $out"
contains "the collision is named" "$out" "issue-81-rival"
check "the date did not move" "$(cat "$ROOT/body-81")" "$before"
rm -rf "$ROOT/repo/canon/lib"

echo "claim.sh --renew acts on the CANONICAL checkout's repository, not the cwd's"
mkdir -p "$ROOT/other"
echo "other/repo" > "$ROOT/other/.fake-gh-repo"
stage "$(claim_node 91 issue-90-wrongrepo 'lib/**' "$EXPIRED" "$OLD_PUSH")"
printf '%b\n' "- Claim schema: gibson.claim/v2\n- Active-work claim: issue-90-wrongrepo\n- Issue: #90\n- Claim scope: lib/**\n- Claimed: 2026-10-01T00:00:00Z\n- Claim-expires: ${EXPIRED}" > "$ROOT/body-91"
: > "$GH_LOG"
out=$(cd "$ROOT/other" && GIBSON_CANONICAL="$ROOT/repo/canon" bash "$CLAIM" --renew 90 2>&1); rc=$?
check "renew from another cwd succeeds against the canonical repository" "$rc" "0"
lacks "no gh call targeted the cwd's repository" "$(cat "$GH_LOG")" "other/repo"
contains "every gh call named the canonical repository" "$(cat "$GH_LOG")" "--repo acme/app"
out=$(cd "$ROOT/other" && GIBSON_CANONICAL="$ROOT/nonexistent" bash "$CLAIM" --renew 90 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an unreachable canonical checkout fails closed" || bad "renew proceeded without a canonical checkout: $out"

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
stage "$(claim_node 51 issue-50-dead 'lib/**' "$EXPIRED" "$OLD_PUSH"),$(claim_node 52 issue-51-unreadable 'src/**' 'garbage' "$OLD_PUSH"),$(claim_node 53 issue-52-live 'app/**' "$FRESH" "$RECENT_PUSH"),$(claim_node_extra 54 issue-53-displaced 'x/**' "$FRESH" "$RECENT_PUSH" "$DISP"),$(claim_node 99 issue-31-mine 'docs/z/**' "$FRESH" "$RECENT_PUSH")"

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
contains "a displaced claim is labelled too" "$log" "pr edit 54 --repo acme/app --add-label claim-expired"
lacks "the unreadable-expiry claim is not labelled" "$log" "pr edit 52"
lacks "the live claim is not labelled" "$log" "pr edit 53"
lacks "no PR is closed" "$log" "pr close"
lacks "no issue is closed" "$log" "issue close"
lacks "no PR is merged" "$log" "pr merge"
contains "every open PR claim is still protected" "$out" "PR #51 claim issue-50-dead is protected"

echo
echo "claim-expiry.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
