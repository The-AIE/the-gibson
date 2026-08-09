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
      # find-terminal-pr narrows the real query with `select(.number == N)`.
      # This fake hands back TSV instead of running jq, so it has to honour
      # that narrowing itself — otherwise a reused claim id (two terminal
      # generations) would look ambiguous here no matter what was asked.
      want_num=""
      for a in "$@"; do
        case "$a" in
          *"select(.number == "*)
            want_num=$(printf '%s' "$a" | sed -n 's/.*select(\.number == \([0-9][0-9]*\)).*/\1/p' | head -1)
            ;;
        esac
      done
      while IFS='|' read -r number claim scope branch url created updated; do
        [[ -n "$claim" ]] || continue
        [[ -z "$want_num" || "$number" == "$want_num" ]] || continue
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
    # The counter has to live in a FILE: each claim.sh run is a new process
    # tree, so an exported variable resets to 1 every time and two generations
    # of a reused claim id would both be "PR #1" — which is not a thing GitHub
    # can produce, and would hide the very ambiguity this fixture is about.
    counter="${GH_PR_FILE}.next"
    number=$(cat "$counter" 2>/dev/null || echo "${GH_PR_NEXT:-1}")
    echo $((number + 1)) > "$counter"
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
  echo 1 > "${GH_PR_FILE}.next"  # monotonic PR numbers, persisted across runs
  export GH_PR_NEXT=1
  git init -q --bare "$root/origin"
  git clone -q "$root/origin" "$root/canon" 2>/dev/null
  # Real GitHub repository identity on origin (the fake gh reports acme/app),
  # rewritten to the throwaway bare repo for transport. release-claim.sh
  # requires the checkout's own origin to BE the repository whose PR-body
  # evidence drives cleanup (#153 review P1), so the fixture has to carry the
  # identity a real clone carries instead of a bare local path.
  git -C "$root/canon" config "url.$root/origin.insteadOf" https://github.com/acme/app.git
  git -C "$root/canon" remote set-url origin https://github.com/acme/app.git
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

echo "#153 · a reclaimed claim id survives a SECOND full release (two generations)"
# The contradiction this closes: reuse of a released claim id was permitted at
# claim time, but the second generation could never be released — two terminal
# PRs then carry the same id, and the id-only terminal lookup is ambiguous by
# design (and must stay that way). The fix binds close/release to the PR
# number the release path already knows.
gen2_pr=$(cut -d'|' -f1 "$GH_PR_FILE" | tail -1)
[[ "$gen2_pr" =~ ^[0-9]+$ ]] && ok "generation 2 opened its own PR (#$gen2_pr)" \
  || bad "generation 2 PR number unreadable: '$gen2_pr'"
[[ -d "$ROOT/a/wt-42-password-reset" ]] &&
  ok "generation 2 re-created the worktree" || bad "generation 2 worktree missing"
# Both generations now exist as evidence: generation 1 is already terminal.
gen_closed=$(grep -c 'issue-42-password-reset' "${GH_PR_FILE}.closed" || true)
check "generation 1 is terminal evidence for the same claim id" "$gen_closed" "1"
out=$(cd "$ROOT/a/canon" && "$SCRIPT_DIR/../release-claim.sh" 42 --repo acme/app 2>&1)
rc=$?
check    "second-generation release exits 0"     "$rc" "0"
contains "second-generation release closed its own PR" "$out" "closing PR #$gen2_pr"
lacks    "second-generation release never reports ambiguity" "$out" "ambiguous"
test ! -e "$ROOT/a/wt-42-password-reset" &&
  ok "second-generation release removed the worktree" ||
  bad "second-generation release left the worktree"
test -z "$(git -C "$ROOT/a/canon" branch --list 'feat/42-password-reset')" &&
  ok "second-generation release removed the local branch" ||
  bad "second-generation release left the local branch"
test -z "$(git -C "$ROOT/a/canon" ls-remote --heads origin 'feat/42-password-reset')" &&
  ok "second-generation release removed the remote branch" ||
  bad "second-generation release left the remote branch"
gen_closed=$(grep -c 'issue-42-password-reset' "${GH_PR_FILE}.closed" || true)
check "both generations are terminal now" "$gen_closed" "2"
# And the global id lookup is STILL ambiguous — the bound lookup is what made
# the release possible, not a weakened ambiguity check.
out=$("$SCRIPT_DIR/../pr-claims.sh" find-terminal acme/app issue-42-password-reset 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "id-only terminal lookup remains ambiguous across generations" \
  || bad "id-only terminal lookup stopped refusing two generations (rc=$rc): $out"
contains "ambiguity error points at the bound lookup" "$out" "find-terminal-pr"
# A third claim on the freed id can still be made and released the same way.
out=$(cd "$ROOT/a/canon" && "$CLAIM" 42 password-reset 'app/api/auth/**' 2>&1); rc=$?
check "generation 3 can claim the id again" "$rc" "0"
out=$(cd "$ROOT/a/canon" && "$SCRIPT_DIR/../release-claim.sh" 42 --repo acme/app 2>&1); rc=$?
check "generation 3 releases cleanly too" "$rc" "0"

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

# ---------------------------------------------------------------------------
echo "#153 · two GENUINELY concurrent lanes with overlapping scope: exactly one survives"
# Not a sequential simulation: two claim.sh processes run at the same time,
# against one shared fake GitHub, and are held at a rendezvous inside `gh pr
# create` until BOTH have finished their pre-create inventory read. That is
# the exact TOCTOU window — at the moment each lane checked for overlap,
# neither claim existed — so before the post-create admission pass both lanes
# would have survived with overlapping scope on different issues.
#
# The fake assigns PR numbers and appends the row in one critical section, so
# the lower-numbered row is always visible to the higher-numbered lane. The
# winner is therefore decided by evidence both lanes can read, not by timing.
RACE_DIR="$ROOT/race"
mkdir -p "$RACE_DIR/bin"
export RACE_DIR
echo 1 > "$RACE_DIR/next"
: > "$RACE_DIR/prs"
: > "$RACE_DIR/prs.closed"

cat > "$RACE_DIR/bin/gh" <<'RACEGH'
#!/usr/bin/env bash
# Shared, lock-protected fake GitHub for the concurrency fixture.
lock() {
  local i=0
  while ! mkdir "$RACE_DIR/lock" 2>/dev/null; do
    i=$((i + 1))
    [[ "$i" -gt 600 ]] && { echo "fake gh: lock timeout" >&2; exit 1; }
    sleep 0.05
  done
}
unlock() { rmdir "$RACE_DIR/lock" 2>/dev/null || true; }
case "$1 $2" in
  "repo view") echo "acme/race" ;;
  "issue view") cat "$RACE_DIR/labels-$3" 2>/dev/null || echo "" ;;
  "issue edit")
    issue="$3"
    if echo "$*" | grep -q -- '--add-label'; then
      echo "agent-claimed" > "$RACE_DIR/labels-$issue"
    elif echo "$*" | grep -q -- '--remove-label'; then
      : > "$RACE_DIR/labels-$issue"
    fi
    ;;
  "api graphql")
    want_open=0
    for a in "$@"; do
      case "$a" in *"states: [OPEN]"*) want_open=1 ;; esac
    done
    lock
    if [[ "$want_open" -eq 1 ]]; then
      while IFS='|' read -r number claim scope branch url created updated; do
        [[ -n "$claim" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$number" "$claim" "$scope" "$branch" "$url" "$created" "$updated"
      done < "$RACE_DIR/prs"
    fi
    unlock
    ;;
  "pr create")
    body_file=""; branch=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --body-file) body_file="$2"; shift 2 ;;
        --head) branch="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    claim=$(sed -n 's/^- Active-work claim: //p' "$body_file")
    scope=$(sed -n 's/^- Claim scope: //p' "$body_file")
    # Rendezvous: hold every lane here until they have all arrived, so each
    # one's pre-create overlap read provably happened before any PR existed.
    : > "$RACE_DIR/ready-$claim"
    waited=0
    while [[ "$(find "$RACE_DIR" -maxdepth 1 -name 'ready-*' | wc -l | tr -d ' ')" -lt "${RACE_LANES:-2}" ]]; do
      waited=$((waited + 1))
      [[ "$waited" -gt 400 ]] && break    # bounded: never hang the suite
      sleep 0.05
    done
    # Number assignment and publication in ONE critical section: whoever gets
    # the lower number is already visible when the higher-numbered lane looks.
    lock
    number=$(cat "$RACE_DIR/next" 2>/dev/null || echo 1)
    echo $((number + 1)) > "$RACE_DIR/next"
    printf '%s|%s|%s|%s|https://github.com/acme/race/pull/%s|2026-08-09T00:00:00Z|2026-08-09T00:00:00Z\n' \
      "$number" "$claim" "$scope" "$branch" "$number" >> "$RACE_DIR/prs"
    unlock
    echo "https://github.com/acme/race/pull/$number"
    ;;
  "pr close")
    number="$3"
    lock
    : > "$RACE_DIR/prs.tmp"
    while IFS='|' read -r pr rest; do
      [[ -n "$pr" ]] || continue
      if [[ "$pr" == "$number" ]]; then
        printf '%s|%s\n' "$pr" "$rest" >> "$RACE_DIR/prs.closed"
      else
        printf '%s|%s\n' "$pr" "$rest" >> "$RACE_DIR/prs.tmp"
      fi
    done < "$RACE_DIR/prs"
    mv "$RACE_DIR/prs.tmp" "$RACE_DIR/prs"
    unlock
    ;;
esac
exit 0
RACEGH
chmod +x "$RACE_DIR/bin/gh"

# One bare origin, two independent lane checkouts — the real fleet shape (one
# working directory per agent), and it keeps the race at the claim layer
# instead of at git's own index locks.
git init -q --bare "$RACE_DIR/origin"
git clone -q "$RACE_DIR/origin" "$RACE_DIR/seed" 2>/dev/null
(
  cd "$RACE_DIR/seed" || exit 1
  mkdir -p docs/claims
  printf '| when | claim-id | scope | who |\n|---|---|---|---|\n' > docs/active-work.md
  git add -A && git commit -qm init && git branch -M main && git push -q -u origin main
) >/dev/null 2>&1
for lane in A B; do
  mkdir -p "$RACE_DIR/lane$lane"
  git clone -q "$RACE_DIR/origin" "$RACE_DIR/lane$lane/canon" 2>/dev/null
  git -C "$RACE_DIR/lane$lane/canon" config "url.$RACE_DIR/origin.insteadOf" https://github.com/acme/race.git
  git -C "$RACE_DIR/lane$lane/canon" remote set-url origin https://github.com/acme/race.git
done

RACE_OLD_PATH="$PATH"
export PATH="$RACE_DIR/bin:$PATH"
# Different ISSUES, overlapping SCOPE — the cross-issue case the pre-create
# duplicate-issue refusal cannot catch.
(cd "$RACE_DIR/laneA/canon" && GIBSON_CANONICAL="$RACE_DIR/laneA/canon" \
  GIBSON_CLAIM_ADMIT_DELAY=0 "$CLAIM" 501 alpha 'lib/shared/**' >"$RACE_DIR/outA" 2>&1) &
race_pid_a=$!
(cd "$RACE_DIR/laneB/canon" && GIBSON_CANONICAL="$RACE_DIR/laneB/canon" \
  GIBSON_CLAIM_ADMIT_DELAY=0 "$CLAIM" 502 beta 'lib/shared/util.ts' >"$RACE_DIR/outB" 2>&1) &
race_pid_b=$!
wait "$race_pid_a"; rc_a=$?
wait "$race_pid_b"; rc_b=$?
export PATH="$RACE_OLD_PATH"

winners=0
[[ "$rc_a" -eq 0 ]] && winners=$((winners + 1))
[[ "$rc_b" -eq 0 ]] && winners=$((winners + 1))
check "exactly one concurrent lane succeeds" "$winners" "1"
[[ "$rc_a" -ne 0 || "$rc_b" -ne 0 ]] && ok "the losing lane exits nonzero" \
  || bad "no lane refused (rcA=$rc_a rcB=$rc_b)"
# Both really did race: each lane's pre-create read saw no claim at all.
[[ -f "$RACE_DIR/ready-issue-501-alpha" && -f "$RACE_DIR/ready-issue-502-beta" ]] \
  && ok "both lanes reached PR creation (the TOCTOU window was really open)" \
  || bad "the lanes did not both reach the rendezvous"

live_rows=$(grep -c . "$RACE_DIR/prs" || true)
check "exactly one live PR-body claim survives" "$live_rows" "1"
survivor_num=$(cut -d'|' -f1 "$RACE_DIR/prs" | head -1)
survivor_id=$(cut -d'|' -f2 "$RACE_DIR/prs" | head -1)
check "the survivor is the lower PR number" "$survivor_num" "1"

if [[ "$rc_a" -eq 0 ]]; then
  win_lane=A; win_id=issue-501-alpha; win_br=feat/501-alpha; win_issue=501
  lose_lane=B; lose_id=issue-502-beta; lose_br=feat/502-beta; lose_issue=502
else
  win_lane=B; win_id=issue-502-beta; win_br=feat/502-beta; win_issue=502
  lose_lane=A; lose_id=issue-501-alpha; lose_br=feat/501-alpha; lose_issue=501
fi
check "the surviving claim belongs to the winning lane" "$survivor_id" "$win_id"
contains "the loser says why it stood down" "$(cat "$RACE_DIR/out$lose_lane")" "admission refused"
contains "the loser names the winning claim" "$(cat "$RACE_DIR/out$lose_lane")" "$win_id"

# The loser cleaned up ONLY its own artifacts…
test -z "$(find "$RACE_DIR/lane$lose_lane" -maxdepth 1 -name 'wt-*' 2>/dev/null)" \
  && ok "the loser removed its own worktree" || bad "the loser left its worktree behind"
test -z "$(git -C "$RACE_DIR/lane$lose_lane/canon" branch --list "$lose_br")" \
  && ok "the loser removed its own local branch" || bad "the loser left its local branch"
test -z "$(git -C "$RACE_DIR/lane$lose_lane/canon" ls-remote --heads origin "$lose_br")" \
  && ok "the loser removed its own remote branch" || bad "the loser left its remote branch"
lacks "the loser released its own label" "$(cat "$RACE_DIR/labels-$lose_issue" 2>/dev/null || echo '')" "agent-claimed"
grep -qF "$lose_id" "$RACE_DIR/prs.closed" \
  && ok "the loser closed its own PR" || bad "the loser left its PR open"

# …and never touched the winner's.
test -n "$(find "$RACE_DIR/lane$win_lane" -maxdepth 1 -name 'wt-*' 2>/dev/null)" \
  && ok "the winner's worktree is intact" || bad "the winner's worktree was destroyed"
test -n "$(git -C "$RACE_DIR/lane$win_lane/canon" branch --list "$win_br")" \
  && ok "the winner's local branch is intact" || bad "the winner's local branch was deleted"
test -n "$(git -C "$RACE_DIR/lane$win_lane/canon" ls-remote --heads origin "$win_br")" \
  && ok "the winner's remote branch is intact" || bad "the winner's remote branch was deleted"
contains "the winner still holds agent-claimed" "$(cat "$RACE_DIR/labels-$win_issue" 2>/dev/null || echo '')" "agent-claimed"
lacks "the winner never reports a refusal" "$(cat "$RACE_DIR/out$win_lane")" "admission refused"
contains "the winner records its verified admission" "$(cat "$RACE_DIR/out$win_lane")" "admission: PR #$survivor_num holds $win_id"

echo "#153 · an inventory that cannot see this lane's own claim refuses it (fail closed)"
# The admission pass is only meaningful against an inventory fresh enough to
# contain the claim being admitted. If it is not there, the read proves
# nothing about who else holds the scope — roll back rather than assume.
new_repo "$ROOT/admitblind"
BLIND_BIN="$ROOT/admitblind/bin"
mkdir -p "$BLIND_BIN"
cat > "$BLIND_BIN/gh" <<'BLINDGH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") cat "${GH_LABELS_FILE:-/dev/null}" 2>/dev/null || echo "" ;;
  "issue edit") echo "$*" >> "${GH_LOG:-/dev/null}" ;;
  # The open inventory never shows the PR this fixture just created.
  "api graphql") : ;;
  "pr create")
    echo "https://github.com/acme/app/pull/4242"
    ;;
  "pr close") echo "closed $3" >> "${GH_CLOSE_LOG:-/dev/null}" ;;
esac
exit 0
BLINDGH
chmod +x "$BLIND_BIN/gh"
export GH_CLOSE_LOG="$ROOT/admitblind/close.log"
: > "$GH_CLOSE_LOG"
out=$(cd "$ROOT/admitblind/canon" && PATH="$BLIND_BIN:$PATH" GIBSON_CLAIM_ADMIT_ATTEMPTS=2 \
  GIBSON_CLAIM_ADMIT_DELAY=0 "$CLAIM" 77 blind 'lib/blind/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an inventory blind to this claim refuses it" || bad "blind inventory admitted the claim (rc=$rc): $out"
contains "names the unprovable registration" "$out" "not readable in the authoritative live-claim inventory"
test ! -e "$ROOT/admitblind/wt-77-blind" \
  && ok "blind admission rolled back its worktree" || bad "blind admission left its worktree"
test -z "$(git -C "$ROOT/admitblind/canon" branch --list 'feat/77-blind')" \
  && ok "blind admission rolled back its local branch" || bad "blind admission left its local branch"
test -z "$(git -C "$ROOT/admitblind/canon" ls-remote --heads origin 'feat/77-blind')" \
  && ok "blind admission rolled back its remote branch" || bad "blind admission left its remote branch"
contains "blind admission closed its own PR" "$(cat "$GH_CLOSE_LOG")" "closed 4242"
unset GH_CLOSE_LOG

echo
echo "claim.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
