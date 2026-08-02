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
status=$(cd "$ROOT/e/canon" && "$SCRIPT_DIR/../claims-status.sh")
contains "includes legacy rows" "$status" "issue-60-legacy"
contains "flags a stale claim"  "$status" "STALE"

echo
echo "claim.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
