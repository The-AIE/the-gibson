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
# network: read the staged JSON array of *pages* from $GH_PAGES — each page
# shaped like a real GraphQL response
# (`{"data":{"repository":{"pullRequests":{"nodes":[...],"pageInfo":{...}}}}}`)
# — and, for each page in order, run the *actual* jq binary with the exact
# expression pr-claims.sh passed. This mirrors --paginate's real contract:
# --jq is applied per page, output is concatenated across pages, and a jq
# failure on any page (duplicate/malformed marker, URL mismatch, ...) aborts
# the whole command instead of silently moving on to the next page.
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  shift 2
  jqexpr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jq) jqexpr="$2"; shift 2 ;;
      -f|-F) shift 2 ;;
      --paginate) shift ;;
      *) shift ;;
    esac
  done
  pages_file="${GH_PAGES:?GH_PAGES not set}"
  # An unreadable/unparseable page set is an API failure, not "zero pages" —
  # a fake that swallowed it would let a fail-open bug pass this suite.
  if ! page_count=$(jq 'length' "$pages_file" 2>&1); then
    echo "fake gh: cannot read staged pages: $page_count" >&2
    exit 1
  fi
  i=0
  while [[ "$i" -lt "$page_count" ]]; do
    page=$(jq -c ".[$i]" "$pages_file")
    if ! out=$(printf '%s' "$page" | jq -r "$jqexpr" 2>&1); then
      echo "$out" >&2
      exit 1
    fi
    [[ -n "$out" ]] && printf '%s\n' "$out"
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

# Wraps a JSON array of PR nodes into one GraphQL response page.
page_of() {
  printf '{"data":{"repository":{"pullRequests":{"nodes":%s,"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' "$1"
}

# Single-page stage (most tests): $1 is a JSON array of PR nodes.
stage() { printf '[%s]' "$(page_of "$1")" > "$ROOT/pages.json"; }

# Multipage stage: each argument is a JSON array of PR nodes for that page,
# in page order — proves matching/validation spans page boundaries.
stage_pages() {
  local out="[" first=1 nodes
  for nodes in "$@"; do
    [[ $first -eq 1 ]] && first=0 || out+=","
    out+="$(page_of "$nodes")"
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

echo "find-terminal · a non-literal claim id is refused before any gh call"
out=$("$PC" find-terminal acme/app 'issue-139-.*' 2>&1); rc=$?
check    "regex-looking claim id exits 2" "$rc" "2"
contains "names the literal-id contract" "$out" "literal exact claim id"
out=$("$PC" find-terminal acme/app '' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "empty claim id refused" || bad "empty claim id accepted (rc=$rc): $out"

echo
echo "pr-claims.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
