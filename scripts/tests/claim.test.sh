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
contains "wrote docs/claims/issue-42-password-reset.md" "$files" "issue-42-password-reset.md"
body=$(cd "$ROOT/a/canon" && git show origin/main:docs/claims/issue-42-password-reset.md)
contains "records the scope"   "$body" "scope: app/api/auth/**"
contains "records the session" "$body" "session: tester@box"
table=$(cd "$ROOT/a/canon" && git show origin/main:docs/active-work.md)
lacks "does not append to the shared table" "$table" "issue-42"
touched=$(cd "$ROOT/a/canon" && git show --stat --oneline origin/main | tail -n +2)
lacks "the claim commit touches nothing else" "$touched" "active-work.md"

echo "L-028 · a second claim on a claimed issue is refused unless it is deliberate"
new_repo "$ROOT/b"
add_claim "$ROOT/b" issue-77-server-side 'server/**'
out=$(cd "$ROOT/b/canon" && "$CLAIM" 77 client-side 'app/**' 2>&1); rc=$?
check    "refuses"          "$rc" "1"
contains "names the holder" "$out" "issue-77-server-side"
contains "points at --slice" "$out" "--slice"
files=$(cd "$ROOT/b/canon" && git fetch -q origin && git ls-tree --name-only origin/main docs/claims/)
lacks "no claim was written" "$files" "issue-77-client-side"

echo "L-024 · --slice allows a deliberate second lane with separate scope"
out=$(cd "$ROOT/b/canon" && "$CLAIM" 77 client-side 'app/**' --slice 2>&1); rc=$?
check    "allowed"            "$rc" "0"
contains "says it is a slice" "$out" "slice claim"
files=$(cd "$ROOT/b/canon" && git fetch -q origin && git ls-tree --name-only origin/main docs/claims/)
contains "both slices live" "$files" "issue-77-client-side.md"
contains "sibling untouched" "$files" "issue-77-server-side.md"

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
files=$(cd "$ROOT/f/canon" && git fetch -q origin && git ls-tree --name-only origin/main docs/claims/)
contains "claim still landed on main" "$files" "issue-12-thing.md"

echo "claims-status.sh renders the lanes"
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
