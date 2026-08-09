#!/usr/bin/env bash
# pr-claims.test.sh — sensors for pr-claims.sh as the validating, authoritative
# GitHub-native claim reader (#153 blocker 6), including its multipage
# GraphQL pagination contract (#153 follow-up).
#
# WHAT IT DOES
#   Stands in a fake `gh` that intercepts `gh api graphql --paginate ...` and
#   replays a *sequence of pages* (staged via stage()/stage_pages()) through
#   the REAL jq filter pr-claims.sh passes as --jq — unlike the fake-gh
#   fixtures in claim.test.sh/scope-overlap.test.sh/release-claim.test.sh,
#   which mostly hand pr-claims.sh's *output* TSV straight through and never
#   exercise its own validation. This suite proves two things:
#     1. pr-claims.sh itself refuses duplicate/missing/malformed markers and
#        URL/number mismatches before any caller ever sees a row (same as
#        before), and
#     2. that validation, and matching, spans every page — a claim that only
#        appears on page 2 is still found, and malformed/duplicate evidence
#        on page 2 still fails the whole command (#153 blocker: list_claims/
#        list_terminal_claims used to make one `gh pr list --limit N` call,
#        silently truncating once a repo had more than N matching PRs).
#
# WHY
#   Every PR-body claim consumer (claim.sh, scope-overlap.mjs, release-
#   claim.sh) only defensively re-checks the *shape* of pr-claims.sh's output
#   row. None of them can detect two claim markers stuffed in one PR body, an
#   Issue marker that disagrees with the claim id, a PR whose own URL reports
#   a different repo/number than the row claims to be about, or a claim that
#   got dropped because it landed past a fixed page-size cap — those have to
#   be caught at the source.
#
# USAGE
#   scripts/tests/pr-claims.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
PC="$SCRIPT_DIR/../pr-claims.sh"
PASS=0
FAIL=0

ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qiF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -qiF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-prclaims-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/bin"
# Real `gh api graphql --paginate -f query=... --jq EXPR` behavior, minus the
# network — and, since #153's review, an ENFORCER of the pagination contract
# rather than a fake that quietly replays pages no matter what was asked.
#
# A fake that just concatenates staged pages passes identically whether or not
# production actually paginates, so the "claim on page 2 is still found" tests
# it fed proved nothing about --paginate, $endCursor, or after:. This one
# refuses the call unless the request carries every mechanism a real
# multi-page read needs:
#   - --paginate                       (else gh returns page 1 and stops)
#   - a declared $endCursor variable   (else there is nothing to advance)
#   - pullRequests(after: $endCursor)  (else every page IS page 1)
#   - pageInfo { hasNextPage endCursor } in the selection set
#     (else gh cannot tell there is a next page, or where it starts)
# Remove any one of those from pr-claims.sh and this suite goes red.
#
# It then drives the loop the way gh does: page N+1 is fetched with the
# endCursor page N returned, and the fake refuses if that chain is ever
# broken. $GH_PAGES stages an array of node-arrays (one per page); pageInfo is
# synthesized here, with realistic hasNextPage/endCursor values, so the
# staged data cannot lie about its own pagination. GH_PAGE_FAIL_AT=<0-based>
# makes that page fail like a real mid-pagination API error.
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  shift 2
  jqexpr=""
  query=""
  paginate=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jq) jqexpr="$2"; shift 2 ;;
      --paginate) paginate=1; shift ;;
      -f|-F)
        case "$2" in query=*) query="${2#query=}" ;; esac
        shift 2
        ;;
      *) shift ;;
    esac
  done
  contract_fail() { echo "fake gh: pagination contract violated: $1" >&2; exit 1; }
  [[ "$paginate" -eq 1 ]] || \
    contract_fail "no --paginate — gh would return only the first page and every later claim would be silently dropped"
  case "$query" in
    *'$endCursor'*) ;;
    *) contract_fail "query declares no \$endCursor variable — gh has nothing to advance the cursor with" ;;
  esac
  printf '%s' "$query" | grep -Eq 'after:[[:space:]]*\$endCursor' || \
    contract_fail "query never passes \$endCursor to pullRequests(after:) — every page would be page 1"
  printf '%s' "$query" | grep -Eq 'pageInfo[[:space:]]*\{[^}]*hasNextPage' || \
    contract_fail "query does not select pageInfo.hasNextPage — gh cannot tell whether another page exists"
  printf '%s' "$query" | grep -Eq 'pageInfo[[:space:]]*\{[^}]*endCursor' || \
    contract_fail "query does not select pageInfo.endCursor — gh has no cursor for the next page"
  pages_file="${GH_PAGES:?GH_PAGES not set}"
  # An unreadable/unparseable page set is an API failure, not "zero pages" —
  # a fake that swallowed it would let a fail-open bug pass this suite.
  if ! page_count=$(jq 'length' "$pages_file" 2>&1); then
    echo "fake gh: cannot read staged pages: $page_count" >&2
    exit 1
  fi
  i=0
  cursor=""
  while [[ "$i" -lt "$page_count" ]]; do
    expect=""
    [[ "$i" -gt 0 ]] && expect="cursor-$((i - 1))"
    [[ "$cursor" == "$expect" ]] || \
      contract_fail "cursor chain broken before page $((i + 1)) (carrying '${cursor:-<none>}', expected '${expect:-<none>}')"
    if [[ -n "${GH_PAGE_FAIL_AT:-}" && "$i" -eq "$GH_PAGE_FAIL_AT" ]]; then
      echo "fake gh: API error while fetching page $((i + 1)) (after: '${cursor:-<none>}')" >&2
      exit 1
    fi
    nodes=$(jq -c ".[$i]" "$pages_file")
    has_next=false
    end_cursor=null
    if [[ $((i + 1)) -lt "$page_count" ]]; then
      has_next=true
      end_cursor="\"cursor-$i\""
    fi
    page=$(printf '{"data":{"repository":{"pullRequests":{"nodes":%s,"pageInfo":{"hasNextPage":%s,"endCursor":%s}}}}}' \
      "$nodes" "$has_next" "$end_cursor")
    if ! out=$(printf '%s' "$page" | jq -r "$jqexpr" 2>&1); then
      echo "$out" >&2
      exit 1
    fi
    [[ -n "$out" ]] && printf '%s\n' "$out"
    [[ "$has_next" == true ]] || break
    cursor="cursor-$i"
    i=$((i + 1))
  done
  exit 0
fi
echo "fake gh: unhandled invocation: $*" >&2
exit 1
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

HEX40="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
HEX40B="111111111111111111111111111111111111111a"

# Single-page stage (most tests): $1 is a JSON array of PR nodes. The fake gh
# above synthesizes each page's pageInfo, so a fixture cannot accidentally
# stage a page that claims to be the last one when it is not.
stage() { printf '[%s]' "$1" > "$ROOT/pages.json"; }

# Multipage stage: each argument is a JSON array of PR nodes for that page,
# in page order — proves matching/validation spans page boundaries.
stage_pages() {
  local out="[" first=1 nodes
  for nodes in "$@"; do
    [[ $first -eq 1 ]] && first=0 || out+=","
    out+="$nodes"
  done
  printf '%s]' "$out" > "$ROOT/pages.json"
}

open_pr() {
  # number body headRefName url createdAt updatedAt. Defaults use ${N-x}, not
  # ${N:-x}: a caller that explicitly passes '' (to test a missing timestamp)
  # must get an empty field, not the default — ${N:-x} would silently
  # substitute the default for an empty string too and defeat that fixture.
  printf '{"number":%s,"body":"%s","headRefName":"%s","url":"%s","createdAt":"%s","updatedAt":"%s"}' \
    "$1" "$2" "$3" "$4" "${5-2026-08-01T00:00:00Z}" "${6-2026-08-02T00:00:00Z}"
}

term_pr() {
  # number state body headRefName headRefOid url isCross mergeOid createdAt updatedAt
  local merge_json="null"
  [[ -n "${8:-}" ]] && merge_json="{\"oid\":\"$8\"}"
  printf '{"number":%s,"state":"%s","body":"%s","headRefName":"%s","headRefOid":"%s","url":"%s","createdAt":"%s","updatedAt":"%s","isCrossRepository":%s,"mergeCommit":%s}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "${9-2026-08-01T00:00:00Z}" "${10-2026-08-02T00:00:00Z}" "${7:-false}" "$merge_json"
}

GH_PAGES="$ROOT/pages.json"
export GH_PAGES

echo "list · valid single claim round-trips"
stage "[$(open_pr 1 '- Active-work claim: issue-42-thing\n- Claim scope: lib/**\n- Issue: #42' 'feat/42-thing' 'https://github.com/acme/app/pull/1')]"
out=$("$PC" list acme/app 2>&1); rc=$?
check    "list valid exits 0"        "$rc" "0"
contains "list valid carries claim"  "$out" "issue-42-thing"
contains "list valid carries scope"  "$out" "lib/**"

echo "list · unclaimed PR (no marker) is silently ignored"
stage "[$(open_pr 2 'nothing to see here' 'feat/x' 'https://github.com/acme/app/pull/2')]"
out=$("$PC" list acme/app 2>&1); rc=$?
check "unclaimed PR list exits 0"  "$rc" "0"
check "unclaimed PR list is empty" "$out" ""

echo "list · duplicate Active-work claim marker inside one body fails closed"
stage "[$(open_pr 3 '- Active-work claim: issue-1-a\n- Active-work claim: issue-1-a\n- Claim scope: x\n- Issue: #1' 'feat/1-a' 'https://github.com/acme/app/pull/3')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "duplicate claim marker exits nonzero" || bad "duplicate claim marker exits 0 (rc=$rc): $out"
contains "names duplicate marker" "$out" "duplicate"

echo "list · duplicate Claim scope marker fails closed"
stage "[$(open_pr 4 '- Active-work claim: issue-2-a\n- Claim scope: x\n- Claim scope: y\n- Issue: #2' 'feat/2-a' 'https://github.com/acme/app/pull/4')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "duplicate scope marker exits nonzero" || bad "duplicate scope marker exits 0 (rc=$rc): $out"
contains "names scope marker count" "$out" "Claim scope marker"

echo "list · missing Claim scope marker fails closed"
stage "[$(open_pr 5 '- Active-work claim: issue-3-a\n- Issue: #3' 'feat/3-a' 'https://github.com/acme/app/pull/5')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing scope marker exits nonzero" || bad "missing scope marker exits 0 (rc=$rc): $out"

echo "list · duplicate Issue marker fails closed"
stage "[$(open_pr 6 '- Active-work claim: issue-4-a\n- Claim scope: x\n- Issue: #4\n- Issue: #4' 'feat/4-a' 'https://github.com/acme/app/pull/6')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "duplicate issue marker exits nonzero" || bad "duplicate issue marker exits 0 (rc=$rc): $out"

echo "list · missing Issue marker fails closed"
stage "[$(open_pr 7 '- Active-work claim: issue-5-a\n- Claim scope: x' 'feat/5-a' 'https://github.com/acme/app/pull/7')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing issue marker exits nonzero" || bad "missing issue marker exits 0 (rc=$rc): $out"

echo "list · malformed (non-numeric) Issue marker fails closed"
stage "[$(open_pr 8 '- Active-work claim: issue-6-a\n- Claim scope: x\n- Issue: #six' 'feat/6-a' 'https://github.com/acme/app/pull/8')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "malformed issue marker exits nonzero" || bad "malformed issue marker exits 0 (rc=$rc): $out"
contains "names malformed issue marker" "$out" "malformed Issue marker"

echo "list · claim id inconsistent with Issue marker fails closed"
stage "[$(open_pr 9 '- Active-work claim: issue-99-a\n- Claim scope: x\n- Issue: #7' 'feat/99-a' 'https://github.com/acme/app/pull/9')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "claim/issue inconsistency exits nonzero" || bad "claim/issue inconsistency exits 0 (rc=$rc): $out"
contains "names claim/issue inconsistency" "$out" "inconsistent with Issue marker"

echo "list · empty head branch fails closed"
stage "[$(open_pr 10 '- Active-work claim: issue-8-a\n- Claim scope: x\n- Issue: #8' '' 'https://github.com/acme/app/pull/10')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "empty head branch exits nonzero" || bad "empty head branch exits 0 (rc=$rc): $out"

echo "list · unsafe head branch fails closed"
stage "[$(open_pr 11 '- Active-work claim: issue-9-a\n- Claim scope: x\n- Issue: #9' 'feat 9 bad' 'https://github.com/acme/app/pull/11')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "unsafe head branch exits nonzero" || bad "unsafe head branch exits 0 (rc=$rc): $out"

echo "list · PR URL repository mismatch vs the queried repo fails closed"
stage "[$(open_pr 12 '- Active-work claim: issue-10-a\n- Claim scope: x\n- Issue: #10' 'feat/10-a' 'https://github.com/other-org/other-app/pull/12')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "URL repo mismatch exits nonzero" || bad "URL repo mismatch exits 0 (rc=$rc): $out"
contains "names URL repo mismatch" "$out" "does not match queried repository"

echo "list · PR URL pull-number mismatch vs the PR's own number fails closed"
stage "[$(open_pr 13 '- Active-work claim: issue-11-a\n- Claim scope: x\n- Issue: #11' 'feat/11-a' 'https://github.com/acme/app/pull/999')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "URL pull-number mismatch exits nonzero" || bad "URL pull-number mismatch exits 0 (rc=$rc): $out"
contains "names URL pull-number mismatch" "$out" "pull-number"

echo "list · missing created/updated timestamps fail closed"
stage "[$(open_pr 14 '- Active-work claim: issue-12-a\n- Claim scope: x\n- Issue: #12' 'feat/12-a' 'https://github.com/acme/app/pull/14' '' '')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing timestamps exit nonzero" || bad "missing timestamps exit 0 (rc=$rc): $out"

echo "list · one malformed PR poisons the whole call (fail closed, not skip-and-continue)"
stage "[$(open_pr 15 '- Active-work claim: issue-13-a\n- Claim scope: x\n- Issue: #13' 'feat/13-a' 'https://github.com/acme/app/pull/15'),$(open_pr 16 '- Active-work claim: issue-14-a\n- Active-work claim: issue-14-a\n- Claim scope: y\n- Issue: #14' 'feat/14-a' 'https://github.com/acme/app/pull/16')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "one bad PR fails the whole list call" || bad "one bad PR did not fail the call (rc=$rc): $out"

echo "list · malformed --repo shape is rejected before any gh call"
out=$("$PC" list 'not-a-repo' 2>&1); rc=$?
check    "malformed repo exits 2"    "$rc" "2"
contains "names owner/name shape"    "$out" "owner/name"

echo "find · exact claim id round-trips, others excluded"
stage "[$(open_pr 20 '- Active-work claim: issue-20-a\n- Claim scope: x\n- Issue: #20' 'feat/20-a' 'https://github.com/acme/app/pull/20'),$(open_pr 21 '- Active-work claim: issue-21-b\n- Claim scope: y\n- Issue: #21' 'feat/21-b' 'https://github.com/acme/app/pull/21')]"
out=$("$PC" find acme/app issue-20-a 2>&1); rc=$?
check    "find exact exits 0"     "$rc" "0"
contains "find carries the row"   "$out" "issue-20-a"
lacks    "find excludes others"   "$out" "issue-21-b"

echo "find-terminal · MERGED claim round-trips with head SHA + merge SHA"
stage "[$(term_pr 30 MERGED '- Active-work claim: issue-30-a\n- Claim scope: x\n- Issue: #30' 'feat/30-a' "$HEX40" 'https://github.com/acme/app/pull/30' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-30-a 2>&1); rc=$?
check    "find-terminal MERGED exits 0"   "$rc" "0"
contains "find-terminal reports state"    "$out" "MERGED"
contains "find-terminal reports head SHA" "$out" "$HEX40"

echo "find-terminal · OPEN PRs never reach terminal evidence"
stage "[$(term_pr 31 OPEN '- Active-work claim: issue-31-a\n- Claim scope: x\n- Issue: #31' 'feat/31-a' "$HEX40" 'https://github.com/acme/app/pull/31')]"
out=$("$PC" find-terminal acme/app issue-31-a 2>&1); rc=$?
check "OPEN PR yields no terminal row" "$out" ""

echo "find-terminal · MERGED without a merge-commit SHA fails closed"
stage "[$(term_pr 32 MERGED '- Active-work claim: issue-32-a\n- Claim scope: x\n- Issue: #32' 'feat/32-a' "$HEX40" 'https://github.com/acme/app/pull/32')]"
out=$("$PC" find-terminal acme/app issue-32-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "MERGED w/o merge SHA exits nonzero" || bad "MERGED w/o merge SHA exits 0 (rc=$rc): $out"
contains "names missing merge SHA" "$out" "merge-commit SHA"

echo "find-terminal · CLOSED carrying a merge-commit SHA fails closed (state/evidence mismatch)"
stage "[$(term_pr 33 CLOSED '- Active-work claim: issue-33-a\n- Claim scope: x\n- Issue: #33' 'feat/33-a' "$HEX40" 'https://github.com/acme/app/pull/33' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-33-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "CLOSED w/ merge SHA exits nonzero" || bad "CLOSED w/ merge SHA exits 0 (rc=$rc): $out"
contains "names state/evidence mismatch" "$out" "state/evidence mismatch"

echo "find-terminal · missing headRefOid fails closed"
stage "[$(term_pr 34 MERGED '- Active-work claim: issue-34-a\n- Claim scope: x\n- Issue: #34' 'feat/34-a' '' 'https://github.com/acme/app/pull/34' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-34-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing headRefOid exits nonzero" || bad "missing headRefOid exits 0 (rc=$rc): $out"

echo "find-terminal · URL pull-number mismatch fails closed"
stage "[$(term_pr 35 MERGED '- Active-work claim: issue-35-a\n- Claim scope: x\n- Issue: #35' 'feat/35-a' "$HEX40" 'https://github.com/acme/app/pull/9999' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-35-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "find-terminal URL number mismatch exits nonzero" || bad "find-terminal URL number mismatch exits 0 (rc=$rc): $out"
contains "names find-terminal URL mismatch" "$out" "pull-number"

echo "find-terminal · duplicate claim marker inside one body fails closed"
stage "[$(term_pr 36 MERGED '- Active-work claim: issue-36-a\n- Active-work claim: issue-36-a\n- Claim scope: x\n- Issue: #36' 'feat/36-a' "$HEX40" 'https://github.com/acme/app/pull/36' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-36-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "find-terminal duplicate marker exits nonzero" || bad "find-terminal duplicate marker exits 0 (rc=$rc): $out"

echo "list · empty Active-work claim id fails closed"
stage "[$(open_pr 40 '- Active-work claim: \n- Claim scope: x\n- Issue: #15' 'feat/15-a' 'https://github.com/acme/app/pull/40')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "empty claim id exits nonzero" || bad "empty claim id exits 0 (rc=$rc): $out"
contains "names empty claim id" "$out" "empty Active-work claim id"

echo "list · non-ISO-8601 created timestamp fails closed (real jq validates format, not just presence)"
stage "[$(open_pr 41 '- Active-work claim: issue-16-a\n- Claim scope: x\n- Issue: #16' 'feat/16-a' 'https://github.com/acme/app/pull/41' '2026-08-01 00:00:00' '2026-08-02T00:00:00Z')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "malformed created timestamp exits nonzero" || bad "malformed created timestamp exits 0 (rc=$rc): $out"
contains "names malformed created timestamp" "$out" "created timestamp is not ISO-8601 UTC"

echo "list · non-ISO-8601 updated timestamp fails closed"
stage "[$(open_pr 42 '- Active-work claim: issue-17-a\n- Claim scope: x\n- Issue: #17' 'feat/17-a' 'https://github.com/acme/app/pull/42' '2026-08-01T00:00:00Z' 'not-a-date')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "malformed updated timestamp exits nonzero" || bad "malformed updated timestamp exits 0 (rc=$rc): $out"
contains "names malformed updated timestamp" "$out" "updated timestamp is not ISO-8601 UTC"

echo "find-terminal · malformed (non-40-hex) headRefOid fails closed"
stage "[$(term_pr 37 MERGED '- Active-work claim: issue-37-a\n- Claim scope: x\n- Issue: #37' 'feat/37-a' 'not-a-real-sha' 'https://github.com/acme/app/pull/37' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-37-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "malformed headRefOid exits nonzero" || bad "malformed headRefOid exits 0 (rc=$rc): $out"
contains "names malformed headRefOid" "$out" "not 40-hex"

echo "find-terminal · PR URL repository mismatch vs the queried repo fails closed"
stage "[$(term_pr 38 MERGED '- Active-work claim: issue-38-a\n- Claim scope: x\n- Issue: #38' 'feat/38-a' "$HEX40" 'https://github.com/other-org/other-app/pull/38' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-38-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "find-terminal URL repo mismatch exits nonzero" || bad "find-terminal URL repo mismatch exits 0 (rc=$rc): $out"
contains "names find-terminal URL repo mismatch" "$out" "does not match queried repository"

echo "find-terminal · non-ISO-8601 created timestamp fails closed"
stage "[$(term_pr 39 MERGED '- Active-work claim: issue-39-a\n- Claim scope: x\n- Issue: #39' 'feat/39-a' "$HEX40" 'https://github.com/acme/app/pull/39' false "$HEX40B" '2026/08/01' '2026-08-02T00:00:00Z')]"
out=$("$PC" find-terminal acme/app issue-39-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "find-terminal malformed created timestamp exits nonzero" || bad "find-terminal malformed created timestamp exits 0 (rc=$rc): $out"
contains "names find-terminal malformed created timestamp" "$out" "created timestamp is not ISO-8601 UTC"

echo "find-terminal · non-ISO-8601 updated timestamp fails closed"
stage "[$(term_pr 43 MERGED '- Active-work claim: issue-40-a\n- Claim scope: x\n- Issue: #40' 'feat/40-a' "$HEX40" 'https://github.com/acme/app/pull/43' false "$HEX40B" '2026-08-01T00:00:00Z' '')]"
out=$("$PC" find-terminal acme/app issue-40-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "find-terminal empty updated timestamp exits nonzero" || bad "find-terminal empty updated timestamp exits 0 (rc=$rc): $out"
contains "names find-terminal empty updated timestamp" "$out" "updated timestamp is not ISO-8601 UTC"

echo "find-terminal · valid ISO-8601 timestamps with fractional seconds round-trip"
stage "[$(term_pr 44 MERGED '- Active-work claim: issue-41-a\n- Claim scope: x\n- Issue: #41' 'feat/41-a' "$HEX40" 'https://github.com/acme/app/pull/44' false "$HEX40B" '2026-08-01T00:00:00.123Z' '2026-08-02T00:00:00.456Z')]"
out=$("$PC" find-terminal acme/app issue-41-a 2>&1); rc=$?
check "fractional-second timestamps still valid" "$rc" "0"

echo "list · a matching claim that only appears on page 2 is still included (#153 pagination)"
stage_pages \
  "[$(open_pr 50 '- Active-work claim: issue-50-a\n- Claim scope: p1\n- Issue: #50' 'feat/50-a' 'https://github.com/acme/app/pull/50')]" \
  "[$(open_pr 51 '- Active-work claim: issue-51-a\n- Claim scope: p2\n- Issue: #51' 'feat/51-a' 'https://github.com/acme/app/pull/51')]"
out=$("$PC" list acme/app 2>&1); rc=$?
check    "page-2 claim: list exits 0"       "$rc" "0"
contains "page-2 claim: page 1 row present" "$out" "issue-50-a"
contains "page-2 claim: page 2 row present" "$out" "issue-51-a"
out=$("$PC" find acme/app issue-51-a 2>&1); rc=$?
check    "find locates page-2-only claim exits 0" "$rc" "0"
contains "find locates page-2-only claim"         "$out" "issue-51-a"

echo "list · duplicate marker evidence on page 2 fails the whole command, not just that page (#153 pagination)"
stage_pages \
  "[$(open_pr 52 '- Active-work claim: issue-52-a\n- Claim scope: p1\n- Issue: #52' 'feat/52-a' 'https://github.com/acme/app/pull/52')]" \
  "[$(open_pr 53 '- Active-work claim: issue-53-a\n- Active-work claim: issue-53-a\n- Claim scope: p2\n- Issue: #53' 'feat/53-a' 'https://github.com/acme/app/pull/53')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "page-2 duplicate marker fails the whole list call" || bad "page-2 duplicate marker exits 0 (rc=$rc): $out"
contains "names page-2 duplicate marker" "$out" "duplicate"

echo "find-terminal · a matching MERGED claim that only appears on page 2 is still included (#153 pagination)"
stage_pages \
  "[$(term_pr 60 CLOSED '- Active-work claim: issue-60-a\n- Claim scope: p1\n- Issue: #60' 'feat/60-a' "$HEX40" 'https://github.com/acme/app/pull/60')]" \
  "[$(term_pr 61 MERGED '- Active-work claim: issue-61-a\n- Claim scope: p2\n- Issue: #61' 'feat/61-a' "$HEX40" 'https://github.com/acme/app/pull/61' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-61-a 2>&1); rc=$?
check    "find-terminal page-2 claim exits 0"    "$rc" "0"
contains "find-terminal page-2 claim reports state"    "$out" "MERGED"
contains "find-terminal page-2 claim reports head SHA" "$out" "$HEX40"

echo "find-terminal · malformed evidence on page 2 fails the whole command (#153 pagination)"
stage_pages \
  "[$(term_pr 62 MERGED '- Active-work claim: issue-62-a\n- Claim scope: p1\n- Issue: #62' 'feat/62-a' "$HEX40" 'https://github.com/acme/app/pull/62' false "$HEX40B")]" \
  "[$(term_pr 63 MERGED '- Active-work claim: issue-63-a\n- Claim scope: p2\n- Issue: #63' 'feat/63-a' "$HEX40" 'https://github.com/acme/app/pull/63')]"
out=$("$PC" find-terminal acme/app issue-63-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "page-2 missing merge SHA fails the whole find-terminal call" || bad "page-2 missing merge SHA exits 0 (rc=$rc): $out"
contains "names page-2 missing merge SHA" "$out" "merge-commit SHA"

# --- find-terminal is candidate-first (#153) -------------------------------
# The live failure this closes: `find-terminal mrhinkle/the-gibson
# issue-139-fleet-profiles` exited nonzero because unrelated historical PR
# #114 carries an Active-work claim line with no Claim scope line. That PR is
# not issue-139's evidence, and a repository's own history must not be able to
# permanently block every future release. find-terminal therefore selects
# exact claim-marker candidates FIRST and validates only those — while every
# check still applies in full to a PR that does match.
LEGACY_BODY='- Active-work claim: issue-114-legacy-format\n(no Claim scope marker: pre-#153 body format)'

echo "find-terminal · unrelated malformed legacy PR BEFORE a valid exact candidate does not poison the lookup"
stage_pages \
  "[$(term_pr 114 MERGED "$LEGACY_BODY" 'feat/114-legacy' "$HEX40" 'https://github.com/acme/app/pull/114' false "$HEX40B")]" \
  "[$(term_pr 139 MERGED '- Active-work claim: issue-139-fleet-profiles\n- Claim scope: scripts/**\n- Issue: #139' 'feat/139-fleet-profiles' "$HEX40" 'https://github.com/acme/app/pull/139' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-139-fleet-profiles 2>&1); rc=$?
check    "legacy-PR-first: find-terminal exits 0"      "$rc" "0"
contains "legacy-PR-first: returns the exact claim"    "$out" "issue-139-fleet-profiles"
contains "legacy-PR-first: returns MERGED evidence"    "$out" "MERGED"
lacks    "legacy-PR-first: no legacy row leaks out"    "$out" "issue-114-legacy-format"

echo "find-terminal · unrelated malformed legacy PR LATER than a valid exact candidate does not poison the lookup"
stage_pages \
  "[$(term_pr 139 MERGED '- Active-work claim: issue-139-fleet-profiles\n- Claim scope: scripts/**\n- Issue: #139' 'feat/139-fleet-profiles' "$HEX40" 'https://github.com/acme/app/pull/139' false "$HEX40B")]" \
  "[$(term_pr 114 MERGED "$LEGACY_BODY" 'feat/114-legacy' "$HEX40" 'https://github.com/acme/app/pull/114' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-139-fleet-profiles 2>&1); rc=$?
check    "legacy-PR-later: find-terminal exits 0"   "$rc" "0"
contains "legacy-PR-later: returns the exact claim" "$out" "issue-139-fleet-profiles"

echo "find-terminal · a legacy malformed PR with no matching candidate is simply not this claim's evidence"
stage_pages \
  "[$(term_pr 114 MERGED "$LEGACY_BODY" 'feat/114-legacy' "$HEX40" 'https://github.com/acme/app/pull/114' false "$HEX40B")]" \
  "[$(term_pr 115 CLOSED '- Active-work claim: issue-115-other\n- Claim scope: docs/**\n- Issue: #115' 'feat/115-other' "$HEX40" 'https://github.com/acme/app/pull/115')]"
out=$("$PC" find-terminal acme/app issue-139-fleet-profiles 2>&1); rc=$?
check "no-candidate lookup exits 0"        "$rc" "0"
check "no-candidate lookup emits nothing"  "$out" ""

echo "find-terminal · a MATCHING candidate that is itself malformed still fails closed"
stage_pages \
  "[$(term_pr 114 MERGED "$LEGACY_BODY" 'feat/114-legacy' "$HEX40" 'https://github.com/acme/app/pull/114' false "$HEX40B")]" \
  "[$(term_pr 140 MERGED '- Active-work claim: issue-140-no-scope\n- Issue: #140' 'feat/140-no-scope' "$HEX40" 'https://github.com/acme/app/pull/140' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-140-no-scope 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "malformed exact candidate exits nonzero" || bad "malformed exact candidate exits 0 (rc=$rc): $out"
contains "names the missing scope marker on the candidate" "$out" "Claim scope marker"

echo "find-terminal · duplicate exact claim markers inside one candidate body fail closed"
stage_pages \
  "[$(term_pr 114 MERGED "$LEGACY_BODY" 'feat/114-legacy' "$HEX40" 'https://github.com/acme/app/pull/114' false "$HEX40B")]" \
  "[$(term_pr 141 MERGED '- Active-work claim: issue-141-dup\n- Active-work claim: issue-141-dup\n- Claim scope: x\n- Issue: #141' 'feat/141-dup' "$HEX40" 'https://github.com/acme/app/pull/141' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-141-dup 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "duplicate exact marker exits nonzero" || bad "duplicate exact marker exits 0 (rc=$rc): $out"
contains "names the duplicate marker" "$out" "duplicate"

echo "find-terminal · a second claim marker alongside the matching one still fails closed"
stage "[$(term_pr 142 MERGED '- Active-work claim: issue-142-a\n- Active-work claim: issue-999-smuggled\n- Claim scope: x\n- Issue: #142' 'feat/142-a' "$HEX40" 'https://github.com/acme/app/pull/142' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-142-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "mixed duplicate markers exit nonzero" || bad "mixed duplicate markers exit 0 (rc=$rc): $out"

echo "find-terminal · two DIFFERENT PRs carrying the same exact claim id are ambiguous (across pages) and fail closed"
stage_pages \
  "[$(term_pr 150 MERGED '- Active-work claim: issue-150-dupe-pr\n- Claim scope: x\n- Issue: #150' 'feat/150-dupe-pr' "$HEX40" 'https://github.com/acme/app/pull/150' false "$HEX40B")]" \
  "[$(term_pr 151 CLOSED '- Active-work claim: issue-150-dupe-pr\n- Claim scope: x\n- Issue: #150' 'feat/150-dupe-pr-again' "$HEX40" 'https://github.com/acme/app/pull/151')]"
out=$("$PC" find-terminal acme/app issue-150-dupe-pr 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "duplicate exact candidates exit nonzero" || bad "duplicate exact candidates exit 0 (rc=$rc): $out"
contains "names the ambiguity" "$out" "ambiguous"

# --- legacy terminal-claim schema (#153 follow-up) -------------------------
# The second live compatibility failure: the exact candidate for
# issue-139-fleet-profiles — mrhinkle/the-gibson#143 — is itself older than
# the machine markers. Its body has exactly one Active-work claim line, an
# exact `Closes #139.`, and a `## Cumulative scope` section of backticked
# path bullets, but no `- Claim scope:` and no `- Issue: #`. find-terminal
# must be able to release that real claim by PARSING the evidence the body
# actually carries — and must refuse everything weaker.

# PR-143-shaped: headings before and after the scope section, a backticked
# value on a non-scope line (`**Exact head:**`), and a prose bullet in the
# FOLLOWING section — all of which the parser must not mistake for scope.
LEGACY_143_BODY='## Summary\n\nCloses #139.\n\nMakes the multi-lane fleet driver portable across repositories.\n\n**Exact head:** `6729f92810258d1ab9a56def700113f8284b87ac`\n\n## Claim\n\n- Active-work claim: issue-139-fleet-profiles\n\n## Cumulative scope\n\n- `scripts/loop-fleet.sh`\n- `scripts/tests/loop-fleet.test.sh`\n- `templates/fleet/README.md`\n- `templates/fleet/profile.v1.example`\n\n## Safety contract\n\n- Profile is parsed as declarative data; it is never sourced or evaluated.\n'

echo "find-terminal · a PR-143-shaped LEGACY candidate on a later page is released on its own parsed evidence"
stage_pages \
  "[$(term_pr 114 MERGED "$LEGACY_BODY" 'feat/114-legacy' "$HEX40" 'https://github.com/acme/app/pull/114' false "$HEX40B")]" \
  "[$(term_pr 115 CLOSED '- Active-work claim: issue-115-other\n- Claim scope: docs/**\n- Issue: #115' 'feat/115-other' "$HEX40" 'https://github.com/acme/app/pull/115')]" \
  "[$(term_pr 143 MERGED "$LEGACY_143_BODY" 'feat/139-fleet-profiles' "$HEX40" 'https://github.com/acme/app/pull/143' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-139-fleet-profiles 2>&1); rc=$?
check "legacy-143: find-terminal exits 0" "$rc" "0"
check "legacy-143: emits exactly one row" "$(printf '%s' "$out" | grep -c .)" "1"
check "legacy-143: PR number column"      "$(cut -f1 <<<"$out")" "143"
check "legacy-143: claim id column"       "$(cut -f2 <<<"$out")" "issue-139-fleet-profiles"
# Scope is the REAL cumulative-scope bullets, space-joined — the same shape
# `- Claim scope:` carries. Nothing invented, nothing defaulted, and neither
# the `**Exact head:**` backticks nor the Safety-contract bullet leaks in.
check "legacy-143: scope is the parsed cumulative-scope bullets" \
  "$(cut -f3 <<<"$out")" \
  "scripts/loop-fleet.sh scripts/tests/loop-fleet.test.sh templates/fleet/README.md templates/fleet/profile.v1.example"
check "legacy-143: issue parsed from the Closes line" "$(cut -f4 <<<"$out")" "139"
check "legacy-143: head branch column"    "$(cut -f5 <<<"$out")" "feat/139-fleet-profiles"
check "legacy-143: head SHA column"       "$(cut -f6 <<<"$out")" "$HEX40"
check "legacy-143: state column"          "$(cut -f8 <<<"$out")" "MERGED"
check "legacy-143: merge SHA column"      "$(cut -f10 <<<"$out")" "$HEX40B"
lacks "legacy-143: no exact-head backtick value leaks into scope" "$(cut -f3 <<<"$out")" "6729f928"
lacks "legacy-143: no safety-contract prose leaks into scope"     "$(cut -f3 <<<"$out")" "declarative"

echo "find-terminal · a marker-only legacy body is NOT enough to release"
stage "[$(term_pr 160 MERGED '## Claim\n\n- Active-work claim: issue-160-marker-only\n\nThat is the whole body.' 'feat/160-marker-only' "$HEX40" 'https://github.com/acme/app/pull/160' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-160-marker-only 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "marker-only legacy body exits nonzero" || bad "marker-only legacy body exits 0 (rc=$rc): $out"
contains "names the missing closing binding" "$out" "Closes"

echo "find-terminal · a legacy body with no Cumulative scope section is refused"
stage "[$(term_pr 161 MERGED '## Summary\n\nCloses #161.\n\n- Active-work claim: issue-161-no-scope-section\n\nShipped it.' 'feat/161-no-scope-section' "$HEX40" 'https://github.com/acme/app/pull/161' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-161-no-scope-section 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "legacy body without a scope section exits nonzero" || bad "legacy body without a scope section exits 0 (rc=$rc): $out"
contains "names the missing scope section" "$out" "Cumulative scope"

echo "find-terminal · a legacy body with TWO Cumulative scope sections is ambiguous"
stage "[$(term_pr 162 MERGED 'Closes #162.\n\n- Active-work claim: issue-162-two-sections\n\n## Cumulative scope\n\n- `a.sh`\n\n## Cumulative scope\n\n- `b.sh`\n' 'feat/162-two-sections' "$HEX40" 'https://github.com/acme/app/pull/162' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-162-two-sections 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "two Cumulative scope sections exit nonzero" || bad "two Cumulative scope sections exit 0 (rc=$rc): $out"
contains "names the section count" "$out" "found 2"

echo "find-terminal · a legacy body with TWO Closes lines is ambiguous"
stage "[$(term_pr 163 MERGED 'Closes #163.\nCloses #999.\n\n- Active-work claim: issue-163-two-closes\n\n## Cumulative scope\n\n- `a.sh`\n' 'feat/163-two-closes' "$HEX40" 'https://github.com/acme/app/pull/163' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-163-two-closes 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "two Closes lines exit nonzero" || bad "two Closes lines exit 0 (rc=$rc): $out"
contains "names the closing-binding count" "$out" "found 2"

echo "find-terminal · a legacy Closes line that disagrees with the claim id is refused"
stage "[$(term_pr 164 MERGED 'Closes #777.\n\n- Active-work claim: issue-164-mismatch\n\n## Cumulative scope\n\n- `a.sh`\n' 'feat/164-mismatch' "$HEX40" 'https://github.com/acme/app/pull/164' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-164-mismatch 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "legacy issue/claim mismatch exits nonzero" || bad "legacy issue/claim mismatch exits 0 (rc=$rc): $out"
contains "names the inconsistency" "$out" "inconsistent"

echo "find-terminal · arbitrary prose inside the legacy scope section is refused (never invent scope)"
stage "[$(term_pr 165 MERGED 'Closes #165.\n\n- Active-work claim: issue-165-prose\n\n## Cumulative scope\n\nEverything under scripts, basically.\n' 'feat/165-prose' "$HEX40" 'https://github.com/acme/app/pull/165' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-165-prose 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "prose scope section exits nonzero" || bad "prose scope section exits 0 (rc=$rc): $out"
contains "refuses to invent scope" "$out" "refuse to invent scope"

echo "find-terminal · an un-backticked bullet in the legacy scope section is refused"
stage "[$(term_pr 166 MERGED 'Closes #166.\n\n- Active-work claim: issue-166-bare-bullet\n\n## Cumulative scope\n\n- `a.sh`\n- b.sh\n' 'feat/166-bare-bullet' "$HEX40" 'https://github.com/acme/app/pull/166' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-166-bare-bullet 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "bare (un-backticked) bullet exits nonzero" || bad "bare bullet exits 0 (rc=$rc): $out"

echo "find-terminal · an EMPTY legacy scope section is refused"
stage "[$(term_pr 167 MERGED 'Closes #167.\n\n- Active-work claim: issue-167-empty-scope\n\n## Cumulative scope\n\n## Verification\n\n- all green\n' 'feat/167-empty-scope' "$HEX40" 'https://github.com/acme/app/pull/167' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-167-empty-scope 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "empty legacy scope section exits nonzero" || bad "empty legacy scope section exits 0 (rc=$rc): $out"
contains "names the empty section" "$out" "empty"

echo "find-terminal · an absolute legacy scope path is refused"
stage "[$(term_pr 168 MERGED 'Closes #168.\n\n- Active-work claim: issue-168-absolute\n\n## Cumulative scope\n\n- `/etc/passwd`\n' 'feat/168-absolute' "$HEX40" 'https://github.com/acme/app/pull/168' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-168-absolute 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "absolute legacy scope path exits nonzero" || bad "absolute legacy scope path exits 0 (rc=$rc): $out"
contains "names the unsafe path" "$out" "unsafe path bullet"

echo "find-terminal · a parent-directory legacy scope path is refused"
stage "[$(term_pr 169 MERGED 'Closes #169.\n\n- Active-work claim: issue-169-parent\n\n## Cumulative scope\n\n- `../../etc/passwd`\n' 'feat/169-parent' "$HEX40" 'https://github.com/acme/app/pull/169' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-169-parent 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "parent-directory legacy scope path exits nonzero" || bad "parent-directory path exits 0 (rc=$rc): $out"
contains "names the parent-directory path" "$out" "parent-directory"

echo "find-terminal · a shell-metacharacter legacy scope path is refused"
stage "[$(term_pr 170 MERGED 'Closes #170.\n\n- Active-work claim: issue-170-meta\n\n## Cumulative scope\n\n- `a.sh; rm -rf /`\n' 'feat/170-meta' "$HEX40" 'https://github.com/acme/app/pull/170' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-170-meta 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "shell-metacharacter legacy scope path exits nonzero" || bad "metacharacter path exits 0 (rc=$rc): $out"

echo "find-terminal · a repeated legacy scope path is ambiguous evidence"
stage "[$(term_pr 171 MERGED 'Closes #171.\n\n- Active-work claim: issue-171-dupe-path\n\n## Cumulative scope\n\n- `a.sh`\n- `a.sh`\n' 'feat/171-dupe-path' "$HEX40" 'https://github.com/acme/app/pull/171' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-171-dupe-path 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "repeated legacy scope path exits nonzero" || bad "repeated scope path exits 0 (rc=$rc): $out"
contains "names the repeated path" "$out" "repeats a path bullet"

echo "find-terminal · duplicate claim markers still fail closed on a LEGACY-shaped body"
stage "[$(term_pr 172 MERGED 'Closes #172.\n\n- Active-work claim: issue-172-dup\n- Active-work claim: issue-172-dup\n\n## Cumulative scope\n\n- `a.sh`\n' 'feat/172-dup' "$HEX40" 'https://github.com/acme/app/pull/172' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-172-dup 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "duplicate markers on a legacy body exit nonzero" || bad "duplicate markers on a legacy body exit 0 (rc=$rc): $out"
contains "names the duplicate marker on the legacy body" "$out" "duplicate"

echo "find-terminal · two LEGACY PRs carrying the same exact claim id are still ambiguous"
stage_pages \
  "[$(term_pr 173 MERGED 'Closes #173.\n\n- Active-work claim: issue-173-two-legacy\n\n## Cumulative scope\n\n- `a.sh`\n' 'feat/173-two-legacy' "$HEX40" 'https://github.com/acme/app/pull/173' false "$HEX40B")]" \
  "[$(term_pr 174 CLOSED 'Closes #173.\n\n- Active-work claim: issue-173-two-legacy\n\n## Cumulative scope\n\n- `b.sh`\n' 'feat/173-two-legacy-again' "$HEX40" 'https://github.com/acme/app/pull/174')]"
out=$("$PC" find-terminal acme/app issue-173-two-legacy 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "two legacy candidates exit nonzero" || bad "two legacy candidates exit 0 (rc=$rc): $out"
contains "names the legacy ambiguity" "$out" "ambiguous"

# Legacy is admitted only when BOTH current markers are absent. A body with
# one of the two is a current-format claim missing a required field, and must
# fail on THAT — it must never fall back to parsing prose.
echo "find-terminal · a current-format candidate missing the Issue marker does NOT fall back to legacy"
stage "[$(term_pr 175 MERGED 'Closes #175.\n\n- Active-work claim: issue-175-half\n- Claim scope: scripts/**\n\n## Cumulative scope\n\n- `a.sh`\n' 'feat/175-half' "$HEX40" 'https://github.com/acme/app/pull/175' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-175-half 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "half-current candidate (no Issue marker) exits nonzero" || bad "half-current candidate exits 0 (rc=$rc): $out"
contains "names the missing Issue marker" "$out" "Issue marker"

echo "find-terminal · a current-format candidate missing the Claim scope marker does NOT fall back to legacy"
stage "[$(term_pr 176 MERGED 'Closes #176.\n\n- Active-work claim: issue-176-half2\n- Issue: #176\n\n## Cumulative scope\n\n- `a.sh`\n' 'feat/176-half2' "$HEX40" 'https://github.com/acme/app/pull/176' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-176-half2 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "half-current candidate (no scope marker) exits nonzero" || bad "half-current candidate exits 0 (rc=$rc): $out"
contains "names the missing Claim scope marker" "$out" "Claim scope marker"

# `list` is an inventory of LIVE work written by today's claim.sh. Legacy is a
# read-compatibility path for history, not a licence to open new claims
# without machine markers.
echo "list · does NOT accept the legacy schema (open claims must carry today's markers)"
stage "[$(open_pr 177 'Closes #177.\n\n- Active-work claim: issue-177-legacy-open\n\n## Cumulative scope\n\n- `a.sh`\n' 'feat/177-legacy-open' 'https://github.com/acme/app/pull/177')]"
out=$("$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "legacy body in list exits nonzero" || bad "legacy body accepted by list (rc=$rc): $out"
contains "list names the missing scope marker" "$out" "Claim scope marker"

echo "find-terminal · an API/pagination failure still fails the whole lookup (never 'no candidates')"
printf 'not json at all\n' > "$ROOT/broken-pages.json"
out=$(GH_PAGES="$ROOT/broken-pages.json" "$PC" find-terminal acme/app issue-139-fleet-profiles 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "unreadable page data exits nonzero" || bad "unreadable page data exits 0 (rc=$rc): $out"
check "unreadable page data emits no rows" "$(GH_PAGES="$ROOT/broken-pages.json" "$PC" find-terminal acme/app issue-139-fleet-profiles 2>/dev/null)" ""

# --- the pagination contract itself (#153 review P2) -----------------------
# The fake gh above refuses a request that is missing any mechanism a real
# multi-page read needs. These probes prove the enforcement is real — i.e.
# that the passing multipage tests above would go RED if pr-claims.sh dropped
# --paginate, the $endCursor variable, the after: argument, or pageInfo —
# rather than trusting a fake that replays pages unconditionally.
GOOD_QUERY='query($owner: String!, $name: String!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequests(first: 100, after: $endCursor) { nodes { number } pageInfo { hasNextPage endCursor } } } }'
stage "[$(open_pr 70 '- Active-work claim: issue-70-a\n- Claim scope: x\n- Issue: #70' 'feat/70-a' 'https://github.com/acme/app/pull/70')]"

echo "pagination contract · a request without --paginate is refused by the sensor"
out=$(gh api graphql -f query="$GOOD_QUERY" --jq '.' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing --paginate exits nonzero" || bad "missing --paginate accepted (rc=$rc): $out"
contains "names the missing --paginate" "$out" "no --paginate"

echo "pagination contract · a query with no \$endCursor variable is refused"
out=$(gh api graphql --paginate -f query='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { pullRequests(first: 100) { nodes { number } pageInfo { hasNextPage endCursor } } } }' --jq '.' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing \$endCursor exits nonzero" || bad "missing \$endCursor accepted (rc=$rc): $out"
contains "names the missing cursor variable" "$out" "endCursor variable"

echo "pagination contract · a query that never passes after: \$endCursor is refused"
out=$(gh api graphql --paginate -f query='query($owner: String!, $name: String!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequests(first: 100) { nodes { number } pageInfo { hasNextPage endCursor } } } }' --jq '.' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing after: cursor exits nonzero" || bad "missing after: cursor accepted (rc=$rc): $out"
contains "names the missing after: argument" "$out" "every page would be page 1"

echo "pagination contract · a query that omits pageInfo is refused"
out=$(gh api graphql --paginate -f query='query($owner: String!, $name: String!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequests(first: 100, after: $endCursor) { nodes { number } } } }' --jq '.' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing pageInfo exits nonzero" || bad "missing pageInfo accepted (rc=$rc): $out"
contains "names the missing pageInfo" "$out" "pageInfo.hasNextPage"

echo "pagination contract · the real reader satisfies it on both commands"
stage_pages \
  "[$(open_pr 71 '- Active-work claim: issue-71-a\n- Claim scope: p1\n- Issue: #71' 'feat/71-a' 'https://github.com/acme/app/pull/71')]" \
  "[$(open_pr 72 '- Active-work claim: issue-72-a\n- Claim scope: p2\n- Issue: #72' 'feat/72-a' 'https://github.com/acme/app/pull/72')]"
out=$("$PC" list acme/app 2>&1); rc=$?
check    "contract-enforcing list exits 0" "$rc" "0"
check    "contract-enforcing list returns both pages" "$(printf '%s' "$out" | grep -c .)" "2"
lacks    "list never trips the contract"   "$out" "pagination contract violated"

stage_pages \
  "[$(term_pr 73 CLOSED '- Active-work claim: issue-73-a\n- Claim scope: p1\n- Issue: #73' 'feat/73-a' "$HEX40" 'https://github.com/acme/app/pull/73')]" \
  "[$(term_pr 74 MERGED '- Active-work claim: issue-74-a\n- Claim scope: p2\n- Issue: #74' 'feat/74-a' "$HEX40" 'https://github.com/acme/app/pull/74' false "$HEX40B")]"
out=$("$PC" find-terminal acme/app issue-74-a 2>&1); rc=$?
check    "contract-enforcing find-terminal exits 0" "$rc" "0"
contains "contract-enforcing find-terminal spans pages" "$out" "issue-74-a"
lacks    "find-terminal never trips the contract"      "$out" "pagination contract violated"

echo "pagination · an API failure on a LATER page fails the whole command (list)"
stage_pages \
  "[$(open_pr 75 '- Active-work claim: issue-75-a\n- Claim scope: p1\n- Issue: #75' 'feat/75-a' 'https://github.com/acme/app/pull/75')]" \
  "[$(open_pr 76 '- Active-work claim: issue-76-a\n- Claim scope: p2\n- Issue: #76' 'feat/76-a' 'https://github.com/acme/app/pull/76')]" \
  "[$(open_pr 77 '- Active-work claim: issue-77-a\n- Claim scope: p3\n- Issue: #77' 'feat/77-a' 'https://github.com/acme/app/pull/77')]"
out=$(GH_PAGE_FAIL_AT=1 "$PC" list acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "page-2 API failure fails the whole list" || bad "page-2 API failure exits 0 (rc=$rc): $out"
contains "names the failing page" "$out" "page 2"
check "page-2 API failure emits no rows on stdout" \
  "$(GH_PAGE_FAIL_AT=1 "$PC" list acme/app 2>/dev/null)" ""

echo "pagination · an API failure on a LATER page fails the whole command (find-terminal)"
stage_pages \
  "[$(term_pr 78 MERGED '- Active-work claim: issue-78-a\n- Claim scope: p1\n- Issue: #78' 'feat/78-a' "$HEX40" 'https://github.com/acme/app/pull/78' false "$HEX40B")]" \
  "[$(term_pr 79 MERGED '- Active-work claim: issue-79-a\n- Claim scope: p2\n- Issue: #79' 'feat/79-a' "$HEX40" 'https://github.com/acme/app/pull/79' false "$HEX40B")]"
out=$(GH_PAGE_FAIL_AT=1 "$PC" find-terminal acme/app issue-79-a 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "page-2 API failure fails the whole find-terminal" || bad "page-2 API failure exits 0 (rc=$rc): $out"
check "page-2 API failure never yields a terminal row" \
  "$(GH_PAGE_FAIL_AT=1 "$PC" find-terminal acme/app issue-79-a 2>/dev/null)" ""

# --- find-terminal-pr: the bound lookup (#153 review P2) -------------------
# A released claim id is free to be reused, so a second generation makes the
# id-only lookup permanently ambiguous. The caller that already knows which PR
# it is releasing asks about that PR instead — with every check still applied.
REUSED_A="[$(term_pr 80 MERGED '- Active-work claim: issue-80-reused\n- Claim scope: gen1/**\n- Issue: #80' 'feat/80-reused' "$HEX40" 'https://github.com/acme/app/pull/80' false "$HEX40B")]"
REUSED_B="[$(term_pr 81 CLOSED '- Active-work claim: issue-80-reused\n- Claim scope: gen2/**\n- Issue: #80' 'feat/80-reused' "$HEX40B" 'https://github.com/acme/app/pull/81')]"

echo "find-terminal-pr · two generations of a reused id stay ambiguous for the id-only lookup"
stage_pages "$REUSED_A" "$REUSED_B"
out=$("$PC" find-terminal acme/app issue-80-reused 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "reused id: id-only lookup still refuses" || bad "reused id: id-only lookup exits 0 (rc=$rc): $out"
contains "reused id: names the ambiguity"   "$out" "ambiguous"
contains "reused id: points at find-terminal-pr" "$out" "find-terminal-pr"

echo "find-terminal-pr · the bound lookup answers for each generation exactly"
out=$("$PC" find-terminal-pr acme/app issue-80-reused 81 2>&1); rc=$?
check    "bound lookup exits 0"                 "$rc" "0"
check    "bound lookup emits exactly one row"   "$(printf '%s' "$out" | grep -c .)" "1"
check    "bound lookup returns the named PR"    "$(cut -f1 <<<"$out")" "81"
check    "bound lookup carries that PR's scope" "$(cut -f3 <<<"$out")" "gen2/**"
check    "bound lookup carries that PR's state" "$(cut -f8 <<<"$out")" "CLOSED"
out=$("$PC" find-terminal-pr acme/app issue-80-reused 80 2>&1); rc=$?
check    "bound lookup for generation 1 exits 0" "$rc" "0"
check    "bound lookup returns generation 1"     "$(cut -f1 <<<"$out")" "80"
check    "generation 1 keeps its own scope"      "$(cut -f3 <<<"$out")" "gen1/**"

echo "find-terminal-pr · a PR that does not carry the claim id yields nothing"
stage_pages "$REUSED_A" "$REUSED_B"
out=$("$PC" find-terminal-pr acme/app issue-80-reused 999 2>&1); rc=$?
check "bound lookup for an unknown PR exits 0"   "$rc" "0"
check "bound lookup for an unknown PR is empty"  "$out" ""
out=$("$PC" find-terminal-pr acme/app issue-30-a 80 2>&1); rc=$?
check "bound lookup with the wrong claim id exits 0" "$rc" "0"
check "bound lookup with the wrong claim id is empty" "$out" ""

echo "find-terminal-pr · an OPEN PR is not terminal evidence, even when named"
stage "[$(term_pr 82 OPEN '- Active-work claim: issue-82-open\n- Claim scope: x\n- Issue: #82' 'feat/82-open' "$HEX40" 'https://github.com/acme/app/pull/82')]"
out=$("$PC" find-terminal-pr acme/app issue-82-open 82 2>&1); rc=$?
check "bound lookup on an OPEN PR exits 0"  "$rc" "0"
check "bound lookup on an OPEN PR is empty" "$out" ""

echo "find-terminal-pr · the named PR still faces every evidence check"
stage "[$(term_pr 83 MERGED '- Active-work claim: issue-83-bad\n- Claim scope: x\n- Issue: #83' 'feat/83-bad' "$HEX40" 'https://github.com/acme/app/pull/83')]"
out=$("$PC" find-terminal-pr acme/app issue-83-bad 83 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "bound lookup still refuses a MERGED PR with no merge SHA" || bad "bound lookup accepted bad evidence (rc=$rc): $out"
contains "bound lookup names the missing merge SHA" "$out" "merge-commit SHA"
stage "[$(term_pr 84 MERGED '- Active-work claim: issue-84-dup\n- Active-work claim: issue-84-dup\n- Claim scope: x\n- Issue: #84' 'feat/84-dup' "$HEX40" 'https://github.com/acme/app/pull/84' false "$HEX40B")]"
out=$("$PC" find-terminal-pr acme/app issue-84-dup 84 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "bound lookup still refuses duplicate markers" || bad "bound lookup accepted duplicate markers (rc=$rc): $out"

echo "find-terminal-pr · a non-numeric PR number is refused before any gh call"
out=$("$PC" find-terminal-pr acme/app issue-80-reused 'not-a-number' 2>&1); rc=$?
check    "non-numeric PR number exits 2"      "$rc" "2"
contains "names the numeric requirement"      "$out" "numeric pull-request number"
out=$("$PC" find-terminal-pr acme/app 'issue-80-.*' 80 2>&1); rc=$?
check    "bound lookup rejects a regex claim id" "$rc" "2"

echo "find-terminal · a non-literal claim id is refused before any gh call"
out=$("$PC" find-terminal acme/app 'issue-139-.*' 2>&1); rc=$?
check    "regex-looking claim id exits 2" "$rc" "2"
contains "names the literal-id contract" "$out" "literal exact claim id"
out=$("$PC" find-terminal acme/app '' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "empty claim id refused" || bad "empty claim id accepted (rc=$rc): $out"

# ---------------------------------------------------------------------------
# #153 review round 4, P1 — list-open-numbers
# ---------------------------------------------------------------------------
# `list` is the CLAIM inventory: a PR only appears there while it carries a
# well-formed claim marker. That makes "the claim id is absent from list" an
# ambiguous answer for a caller that just closed a PR — it is satisfied both
# by a PR that closed and by a PR that is still wide open with its marker
# deleted or rewritten. list-open-numbers exists to remove that ambiguity:
# every open PR number, body-agnostic.
plain_pr() { printf '{"number":%s}' "$1"; }

echo "list-open-numbers · body-agnostic: PRs with NO claim marker are still listed"
stage "[$(plain_pr 11),$(plain_pr 12),$(plain_pr 13)]"
out=$("$PC" list-open-numbers acme/app 2>&1); rc=$?
check "list-open-numbers exits 0"            "$rc" "0"
check "lists every open PR number"           "$(printf '%s' "$out" | tr '\n' ' ')" "11 12 13"
# The contrast that makes it useful: `list` sees none of these.
out=$("$PC" list acme/app 2>&1); rc=$?
check "list exits 0 on the same input"       "$rc" "0"
check "list sees no claims in them at all"   "$out" ""

echo "list-open-numbers · a PR whose marker was REMOVED is still reported open"
# The hostile case: PR 21 carries a claim, PR 22 is the same PR after somebody
# stripped its marker. The claim inventory loses 22; the number inventory does
# not, which is exactly what lets release-claim.sh refuse a false success.
stage "[$(open_pr 21 '- Active-work claim: issue-21-held\n- Claim scope: lib/**\n- Issue: #21' 'feat/21-held' 'https://github.com/acme/app/pull/21'),$(plain_pr 22)]"
out=$("$PC" list acme/app 2>&1)
contains "list sees the marked claim"     "$out" "issue-21-held"
lacks    "list cannot see the stripped PR" "$out" "	22	"
out=$("$PC" list-open-numbers acme/app 2>&1); rc=$?
check "list-open-numbers exits 0"         "$rc" "0"
echo "$out" | grep -qx '22' &&
  ok "the stripped PR is still reported as open" ||
  bad "the stripped PR vanished from the open-number inventory: $out"
echo "$out" | grep -qx '21' &&
  ok "the marked PR is reported as open too" ||
  bad "the marked PR is missing from the open-number inventory: $out"

echo "list-open-numbers · spans every page (a PR on page 2 is not dropped)"
stage_pages "[$(plain_pr 31)]" "[$(plain_pr 32)]" "[$(plain_pr 33)]"
out=$("$PC" list-open-numbers acme/app 2>&1); rc=$?
check "multipage exits 0" "$rc" "0"
check "every page's numbers are present" "$(printf '%s' "$out" | tr '\n' ' ')" "31 32 33"

echo "list-open-numbers · a mid-pagination API failure fails the whole command"
# A truncated open-PR inventory is exactly as dangerous as an unreadable one:
# a caller would read the missing page as "that PR closed".
stage_pages "[$(plain_pr 41)]" "[$(plain_pr 42)]"
GH_PAGE_FAIL_AT=1 "$PC" list-open-numbers acme/app >"$ROOT/nums.out" 2>"$ROOT/nums.err"; rc=$?
[[ "$rc" -ne 0 ]] && ok "a failed page exits nonzero" || bad "a failed page exited 0"
check "no partial inventory reaches stdout" "$(cat "$ROOT/nums.out")" ""

echo "list-open-numbers · an unreadable page set fails closed"
GH_PAGES="$ROOT/does-not-exist.json" "$PC" list-open-numbers acme/app >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]] && ok "an unreadable page set exits nonzero" || bad "an unreadable page set exited 0"

echo "list-open-numbers · a non-numeric PR number poisons the command"
# jq refuses it at the source; the shell loop re-checks. Either way the whole
# command must fail — a row that is not a PR number makes the inventory
# unusable as proof.
stage '[{"number":"51"}]'
out=$("$PC" list-open-numbers acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a non-numeric PR number exits nonzero" || bad "a non-numeric PR number was accepted (rc=$rc): $out"
contains "names the numeric requirement" "$out" "not numeric"

echo "list-open-numbers · an empty repository is an empty (successful) answer"
stage ""
out=$("$PC" list-open-numbers acme/app 2>&1); rc=$?
check "no open PRs exits 0"    "$rc" "0"
check "no open PRs prints nothing" "$out" ""

echo "list-open-numbers · usage"
out=$("$PC" list-open-numbers 2>&1); rc=$?
check "missing repo exits 2" "$rc" "2"
out=$("$PC" list-open-numbers acme/app extra 2>&1); rc=$?
check "an extra argument exits 2" "$rc" "2"
out=$("$PC" list-open-numbers 'not a repo' 2>&1); rc=$?
check "a malformed repo exits 2" "$rc" "2"
contains "documented in --help" "$("$PC" list acme/app --help 2>&1; "$PC" 2>&1)" "list-open-numbers"

echo
echo "pr-claims.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
