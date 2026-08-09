#!/usr/bin/env bash
# claim.test.sh — sensors for the claim contract (L-023 / L-024 / L-028 / L-009)
#
# WHAT IT DOES
#   Builds throwaway git repos and a fake `gh`, then asserts what claim.sh must
#   refuse and what it must allow. No network, no GitHub.
#
# WHY
#   Every rule here exists because it was broken in production: a duplicate build
#   on an already-claimed issue (L-028), a ledger conflict blocking an unrelated
#   green PR (L-023), and a claim that moved the caller's checkout out from under
#   them (L-009).
#
# USAGE
#   scripts/tests/claim.test.sh
set -uo pipefail

# Hermetic git identity (#101): suites that commit must not read ambient global
# user.name/email. Pass with HOME pointed at an empty directory.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"


SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
CLAIM="$SCRIPT_DIR/../claim.sh"
PASS=0
FAIL=0
ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-claim-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Fake gh: records label edits, reports whatever labels the fixture set.
BIN="$ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") cat "${GH_LABELS_FILE:-/dev/null}" 2>/dev/null || echo "" ;;
  "issue edit") echo "$*" >> "${GH_LOG:-/dev/null}" ;;
  "api graphql")
    # pr-claims.sh's paginated GraphQL read. `list` restricts the query to
    # `states: [OPEN]` and wants 7 fields; `find-terminal` walks every state
    # and wants 13, including the exact head SHA that release-claim.sh's
    # cleanup proof is anchored to. Closed PRs move to GH_PR_FILE.closed, so
    # this fixture models the real lifecycle: a released claim leaves the
    # open listing and becomes terminal evidence in the same breath.
    want_open=0
    for a in "$@"; do
      case "$a" in *"states: [OPEN]"*) want_open=1 ;; esac
    done
    if [[ "$want_open" -eq 1 ]]; then
      while IFS='|' read -r number claim scope branch url created updated; do
        [[ -n "$claim" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$number" "$claim" "$scope" "$branch" "$url" "$created" "$updated"
      done < "${GH_PR_FILE:-/dev/null}"
    else
      while IFS='|' read -r number claim scope branch url created updated; do
        [[ -n "$claim" ]] || continue
        rest="${claim#issue-}"
        issue="${rest%%-*}"
        headsha=$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
        # CLOSED, so the merge-commit column is empty by contract.
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$number" "$claim" "$scope" "$issue" "$branch" "$headsha" "$url" \
          "CLOSED" "false" "" "acme/app" "$created" "$updated"
      done < "${GH_PR_FILE}.closed" 2>/dev/null
    fi
    ;;
  "pr create")
    [[ "${GH_FAIL_PR_CREATE:-0}" == 1 ]] && exit 1
    body_file=""
    branch=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --body-file) body_file="$2"; shift 2 ;;
        --head) branch="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    number="${GH_PR_NEXT:-1}"
    export GH_PR_NEXT=$((number + 1))
    claim=$(sed -n 's/^- Active-work claim: //p' "$body_file")
    scope=$(sed -n 's/^- Claim scope: //p' "$body_file")
    printf '%s|%s|%s|%s|https://github.com/acme/app/pull/%s|2026-08-04T00:00:00Z|2026-08-04T00:00:00Z\n' \
      "$number" "$claim" "$scope" "$branch" "$number" >> "${GH_PR_FILE:-/dev/null}"
    cat "$body_file" > "${GH_PR_FILE}.body"
    echo "https://github.com/acme/app/pull/$number"
    ;;
  "pr close")
    number="$3"
    tmp="${GH_PR_FILE}.tmp"
    : > "$tmp"
    while IFS='|' read -r pr_number rest; do
      if [[ "$pr_number" == "$number" ]]; then
        # Closing does not delete the PR — it becomes terminal evidence.
        printf '%s|%s\n' "$pr_number" "$rest" >> "${GH_PR_FILE}.closed"
      else
        printf '%s|%s\n' "$pr_number" "$rest" >> "$tmp"
      fi
    done < "${GH_PR_FILE:-/dev/null}"
    mv "$tmp" "$GH_PR_FILE"
    ;;
esac
exit 0
GH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export GIBSON_SESSION="tester@box"

new_repo() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root"
  export GH_PR_FILE="$root/prs"
  : > "$GH_PR_FILE"
  : > "${GH_PR_FILE}.closed"   # terminal (closed) PR evidence for this fixture
  export GH_PR_NEXT=1
  git init -q --bare "$root/origin"
  git clone -q "$root/origin" "$root/canon" 2>/dev/null
  (
    cd "$root/canon" || exit 1
    mkdir -p docs/claims
    printf '| when | claim-id | scope | who |\n|---|---|---|---|\n' > docs/active-work.md
    git add -A && git commit -qm init && git branch -M main && git push -q -u origin main
  ) >/dev/null 2>&1
}

add_claim() { # repo-root claim-id scope
  (
    cd "$1/canon" || exit 1
    git checkout -q main
    mkdir -p docs/claims
    printf 'claim: %s\nissue: x\nclaimed: 2026-08-01T00:00:00Z\nscope: %s\nsession: other\n' "$2" "$3" \
      > "docs/claims/$2.md"
    git add -A && git commit -qm "claim $2" && git push -q origin main
  ) >/dev/null 2>&1
}

echo "L-023 · a claim is one file, so two lanes never conflict on the ledger"
new_repo "$ROOT/a"
out=$(cd "$ROOT/a/canon" && "$CLAIM" 42 password-reset 'app/api/auth/**' 2>&1); rc=$?
check "claim succeeds" "$rc" "0"
files=$(cd "$ROOT/a/canon" && git fetch -q origin && git ls-tree --name-only origin/main docs/claims/)
lacks "does not write a ledger claim file under docs/claims" "$files" "issue-42"
contains "creates a PR-body claim" "$(cat "$GH_PR_FILE")" "issue-42-password-reset"
body=$(cat "$GH_PR_FILE")
contains "records the scope"   "$body" "app/api/auth/**"
contains "records the session" "$(cat "${GH_PR_FILE}.body")" "- Session: tester@box"
table=$(cd "$ROOT/a/canon" && git show origin/main:docs/active-work.md)
lacks "does not append to the shared table" "$table" "issue-42"
head_before=$(cd "$ROOT/a/canon" && git rev-parse origin/main)
git -C "$ROOT/a/canon" fetch -q origin
head_after=$(cd "$ROOT/a/canon" && git rev-parse origin/main)
check "claim never mutates default branch" "$head_after" "$head_before"

echo "release then reclaim removes the PR claim's worktree and branch"
out=$(cd "$ROOT/a/canon" && "$SCRIPT_DIR/../release-claim.sh" 42 --repo acme/app 2>&1)
rc=$?
check "PR-body release succeeds" "$rc" "0"
test ! -e "$ROOT/a/wt-42-password-reset" &&
  ok "release removes the PR claim worktree" ||
  bad "release removes the PR claim worktree"
test ! -e "$ROOT/a/canon/.git/refs/heads/feat/42-password-reset" &&
  ok "release removes the local PR claim branch" ||
  bad "release removes the local PR claim branch"
out=$(cd "$ROOT/a/canon" && "$CLAIM" 42 password-reset 'app/api/auth/**' 2>&1)
rc=$?
check "same claim can be reclaimed after release" "$rc" "0"

echo "claim failure is atomic and retryable"
new_repo "$ROOT/cleanup"
export GH_FAIL_PR_CREATE=1
out=$(cd "$ROOT/cleanup/canon" && "$CLAIM" 43 cleanup 'lib/cleanup.ts' 2>&1); rc=$?
check "draft PR failure exits nonzero" "$rc" "1"
test ! -e "$ROOT/cleanup/wt-43-cleanup" &&
  ok "failed claim removes its worktree" ||
  bad "failed claim removes its worktree"
test ! -e "$ROOT/cleanup/canon/.git/refs/heads/feat/43-cleanup" &&
  ok "failed claim removes its local branch" ||
  bad "failed claim removes its local branch"
unset GH_FAIL_PR_CREATE
out=$(cd "$ROOT/cleanup/canon" && "$CLAIM" 43 cleanup 'lib/cleanup.ts' 2>&1); rc=$?
check "retry after failed claim succeeds" "$rc" "0"

echo "L-028 · a second claim on a claimed issue is refused unless it is deliberate"
new_repo "$ROOT/b"
add_claim "$ROOT/b" issue-77-server-side 'server/**'
out=$(cd "$ROOT/b/canon" && "$CLAIM" 77 client-side 'app/**' 2>&1); rc=$?
check    "refuses"          "$rc" "1"
contains "names the holder" "$out" "issue-77-server-side"
contains "points at --slice" "$out" "--slice"
claims=$(cat "$GH_PR_FILE")
lacks "no duplicate claim was written" "$claims" "issue-77-client-side"

echo "L-024 · --slice allows a deliberate second lane with separate scope"
out=$(cd "$ROOT/b/canon" && "$CLAIM" 77 client-side 'app/**' --slice 2>&1); rc=$?
check    "allowed"            "$rc" "0"
contains "says it is a slice" "$out" "slice claim"
claims=$(cat "$GH_PR_FILE")
contains "both slices live" "$claims" "issue-77-client-side"
test -f "$ROOT/b/canon/docs/claims/issue-77-server-side.md" &&
  ok "sibling untouched" ||
  bad "sibling untouched"

echo "scope overlap is refused whichever side is broader"
new_repo "$ROOT/c"
add_claim "$ROOT/c" issue-90-nav 'components/nav/**'
out=$(cd "$ROOT/c/canon" && "$CLAIM" 91 nav-tweak 'components/nav/Item.tsx' 2>&1); rc=$?
check    "narrow claim inside a live broad claim is refused" "$rc" "1"
contains "names the conflicting claim" "$out" "issue-90-nav"
out=$(cd "$ROOT/c/canon" && "$CLAIM" 92 nav-rewrite 'components/**' 2>&1); rc=$?
check "broad claim over a live narrow claim is refused" "$rc" "1"
out=$(cd "$ROOT/c/canon" && "$CLAIM" 93 billing 'app/billing/**' 2>&1); rc=$?
check "unrelated scope is allowed" "$rc" "0"

echo "cross-issue PR-body claim overlap is refused end-to-end (#153)"
out=$(cd "$ROOT/c/canon" && "$CLAIM" 94 payments-core 'lib/payments/**' 2>&1); rc=$?
check "PR-body claim for issue 94 succeeds" "$rc" "0"
out=$(cd "$ROOT/c/canon" && "$CLAIM" 95 payments-retry 'lib/payments/retry.ts' 2>&1); rc=$?
check    "different issue overlapping a live PR-body claim is refused" "$rc" "1"
contains "names the conflicting PR-body claim" "$out" "issue-94-payments-core"
out=$(cd "$ROOT/c/canon" && "$CLAIM" 96 shipping 'lib/shipping/**' 2>&1); rc=$?
check "different issue with disjoint scope coexists with the live PR-body claim" "$rc" "0"

echo "legacy rows still count as live claims"
new_repo "$ROOT/e"
(
  cd "$ROOT/e/canon" || exit 1
  printf '| 2026-08-01 | issue-60-legacy | lib/pay/** | session:old |\n' >> docs/active-work.md
  git add -A && git commit -qm legacy && git push -q origin main
) >/dev/null 2>&1
out=$(cd "$ROOT/e/canon" && "$CLAIM" 60 second-go 'lib/other' 2>&1); rc=$?
check "same issue via a legacy row is refused" "$rc" "1"
out=$(cd "$ROOT/e/canon" && "$CLAIM" 61 pay-fix 'lib/pay/Checkout.ts' 2>&1); rc=$?
check "legacy scope overlap is refused" "$rc" "1"

echo "L-009 · the caller's checkout is never moved"
new_repo "$ROOT/f"
(cd "$ROOT/f/canon" && git checkout -q -b long-lived && echo dirty > wip.txt) >/dev/null 2>&1
(cd "$ROOT/f/canon" && "$CLAIM" 12 thing 'lib/thing.ts') >/dev/null 2>&1
branch=$(cd "$ROOT/f/canon" && git rev-parse --abbrev-ref HEAD)
check "still on its branch" "$branch" "long-lived"
check "uncommitted work untouched" "$(cd "$ROOT/f/canon" && git status --porcelain)" "?? wip.txt"
contains "claim still has a PR body" "$(cat "$GH_PR_FILE")" "issue-12-thing"

echo "claims-status.sh renders the lanes"
export GH_PR_FILE="$ROOT/b/prs"
status=$(cd "$ROOT/b/canon" && "$SCRIPT_DIR/../claims-status.sh" --issue 77)
contains "shows slice one" "$status" "issue-77-server-side"
contains "shows slice two" "$status" "issue-77-client-side"
# Date-only legacy row is 2026-08-01 → midnight UTC. Pin NOW to exactly 24h later
# so STALE does not depend on the wall calendar or a second-boundary race (#62).
# Epochs are fixed UTC constants (not derived via date(1)) so the sensor stays
# portable across BSD and GNU hosts.
#   2026-08-01T00:00:00Z = 1785542400
#   2026-08-02T00:00:00Z = 1785628800  (exactly +24h)
status=$(cd "$ROOT/e/canon" && GIBSON_CLAIMS_NOW_EPOCH=1785628800 "$SCRIPT_DIR/../claims-status.sh")
contains "includes legacy rows" "$status" "issue-60-legacy"
contains "flags a stale claim"  "$status" "STALE"

echo "legacy date-only claim timestamps are midnight UTC at the 24h boundary (#62)"
# Same fixture date (2026-08-01). One second before 24h must not be STALE; at
# exactly 24h it must be. Both use the injectable clock — never the wall clock.
# Assert STALE(24h) — not bare STALE — so a fixture-date edit that drifts the
# age fails loudly instead of still matching an arbitrary stale marker.
status=$(cd "$ROOT/e/canon" && GIBSON_CLAIMS_NOW_EPOCH=1785628799 "$SCRIPT_DIR/../claims-status.sh")
contains "includes the legacy claim one second under 24h" "$status" "issue-60-legacy"
lacks   "not STALE one second under 24h"                 "$status" "STALE"
status=$(cd "$ROOT/e/canon" && GIBSON_CLAIMS_NOW_EPOCH=1785628800 "$SCRIPT_DIR/../claims-status.sh")
contains "STALE at exactly 24h from date-only midnight UTC" "$status" "STALE(24h)"
contains "STALE marks the legacy claim id"                  "$status" "issue-60-legacy"

echo "digit-only GIBSON_CLAIMS_NOW_EPOCH with leading zeros is decimal (#62)"
# 0086400 as base-10 is 86400 (exactly 24h). As octal it is invalid (digit 8)
# and aborts bash arithmetic before claims print. A claim at Unix epoch 0 with
# this NOW must report STALE(24h) and exit 0.
new_repo "$ROOT/g"
(
  cd "$ROOT/g/canon" || exit 1
  printf 'claim: issue-62-epoch-pad\nissue: 62\nclaimed: 1970-01-01T00:00:00Z\nscope: lib/**\nsession: pad-test\n' \
    > docs/claims/issue-62-epoch-pad.md
  git add -A && git commit -qm pad && git push -q origin main
) >/dev/null 2>&1
status=$(cd "$ROOT/g/canon" && GIBSON_CLAIMS_NOW_EPOCH=0086400 "$SCRIPT_DIR/../claims-status.sh" 2>&1); rc=$?
check    "leading-zero decimal epoch does not abort" "$rc" "0"
contains "leading-zero epoch is base-10 STALE(24h)"  "$status" "STALE(24h)"
contains "leading-zero epoch still lists the claim"  "$status" "issue-62-epoch-pad"

echo "set-empty GIBSON_CLAIMS_NOW_EPOCH fails closed (#62)"
# Explicit empty must not be treated as unset (wall-clock fallback). Repo has a
# live claim so a silent success would either list it or falsely say none live.
status=$(cd "$ROOT/g/canon" && GIBSON_CLAIMS_NOW_EPOCH='' "$SCRIPT_DIR/../claims-status.sh" 2>&1); rc=$?
check    "set-empty epoch exits 2"                       "$rc" "2"
contains "set-empty epoch validation error"              "$status" "GIBSON_CLAIMS_NOW_EPOCH must be decimal Unix epoch seconds"
lacks    "set-empty never pretends no live claims"       "$status" "no live claims"
lacks    "set-empty never succeeds with a live table"    "$status" "live claims"

echo "oversized GIBSON_CLAIMS_NOW_EPOCH fails closed (#62)"
# 20-digit string wraps under bash $((10#...)) into a nonsense age and would
# still exit 0. Bound check must reject before any claim rows are read/emitted.
status=$(cd "$ROOT/g/canon" && GIBSON_CLAIMS_NOW_EPOCH=99999999999999999999 "$SCRIPT_DIR/../claims-status.sh" 2>&1); rc=$?
check    "oversized epoch exits 2"                       "$rc" "2"
contains "oversized epoch validation error"              "$status" "GIBSON_CLAIMS_NOW_EPOCH must be decimal Unix epoch seconds"
lacks    "oversized never pretends no live claims"       "$status" "no live claims"
lacks    "oversized never succeeds with a live table"    "$status" "live claims"

echo
echo "claim.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
