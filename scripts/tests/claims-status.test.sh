#!/usr/bin/env bash
# claims-status.test.sh — sensors for the claims-status fail-closed contract
#
# WHAT IT DOES
#   Throws throwaway repos at claims-status.sh and asserts:
#     - GitHub origin + missing/failing gh still requires PR inventory
#     - successful empty inventory may print "no live claims"
#     - genuine non-GitHub/local origin stays ledger-only
#     - failed ls-tree and unreadable claim/table blobs exit nonzero
#   No network.
#
# USAGE
#   scripts/tests/claims-status.test.sh
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
CS="$SCRIPT_DIR/../claims-status.sh"
PASS=0
FAIL=0
ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-claims-status-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Empty-inventory gh that requires the real pr-claims.sh pagination contract.
install_empty_gh() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<'GH'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  api)
    if [[ "$2" != "graphql" ]]; then
      echo "fake gh: expected 'api graphql …', got: gh $*" >&2
      exit 64
    fi
    _joined="$*"
    if [[ "$_joined" == *--paginate* && \
          "$_joined" == *'$endCursor'* && \
          "$_joined" == *'after: $endCursor'* && \
          "$_joined" == *'pageInfo { hasNextPage endCursor }'* ]]; then
      case "$_joined" in
        *pullRequests*|*openPrNumbers*) exit 0 ;;
      esac
    fi
    echo "fake gh: unmodelled GraphQL query shape: gh $*" >&2
    exit 64
    ;;
  *)
    echo "fake gh: unmodelled: gh $*" >&2
    exit 64
    ;;
esac
GH
  chmod +x "$dest"
}

new_github_repo() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root"
  git init -q --bare "$root/origin"
  git clone -q "$root/origin" "$root/canon" 2>/dev/null
  # GitHub identity on origin (transport rewritten to the bare path).
  git -C "$root/canon" config "url.$root/origin.insteadOf" https://github.com/acme/app.git
  git -C "$root/canon" remote set-url origin https://github.com/acme/app.git
  (
    cd "$root/canon" || exit 1
    mkdir -p docs/claims
    printf '| when | claim-id | scope | who |\n|---|---|---|---|\n' > docs/active-work.md
    git add -A && git commit -qm init && git branch -M main && git push -q -u origin main
  ) >/dev/null 2>&1
}

new_local_repo() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root"
  git init -q --bare "$root/origin"
  git clone -q "$root/origin" "$root/canon" 2>/dev/null
  # Bare local path origin — not a GitHub repository URL.
  (
    cd "$root/canon" || exit 1
    mkdir -p docs/claims
    printf '| when | claim-id | scope | who |\n|---|---|---|---|\n' > docs/active-work.md
    git add -A && git commit -qm init && git branch -M main && git push -q -u origin main
  ) >/dev/null 2>&1
}

echo "#153 r7 · GitHub origin + failing gh still requires PR inventory"
new_github_repo "$ROOT/ghfail"
mkdir -p "$ROOT/ghfail/bin"
cat > "$ROOT/ghfail/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "simulated gh failure" >&2
exit 1
GH
chmod +x "$ROOT/ghfail/bin/gh"
# Point SCRIPT_DIR's pr-claims at a reader that fails so inventory is unread.
# claims-status invokes $SCRIPT_DIR/pr-claims.sh by absolute path next to itself,
# so make gh fail inside the real pr-claims (graphql) — which is what a missing
# token looks like when origin already named the repo.
# Here: gh fails entirely, but origin is GitHub so REPO is derived; then
# pr-claims.sh list runs and its gh api graphql also fails via PATH.
out=$(cd "$ROOT/ghfail/canon" && PATH="$ROOT/ghfail/bin:$PATH" "$CS" 2>&1); rc=$?
check    "GitHub origin + failing gh exits 1" "$rc" "1"
contains "names unreadable inventory"         "$out" "unreadable"
lacks    "never announces no live claims"     "$out" "no live claims"

echo "#153 r7 · GitHub origin + gh unavailable still requires PR inventory"
new_github_repo "$ROOT/nogh"
mkdir -p "$ROOT/nogh/bin"
# gh is present on PATH but unusable (the common "not authenticated / missing
# binary" class). Origin still yields acme/app, so the PR inventory is
# required and must fail closed rather than report "no live claims".
cat > "$ROOT/nogh/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh: command failed (simulated unavailable)" >&2
exit 127
GH
chmod +x "$ROOT/nogh/bin/gh"
out=$(cd "$ROOT/nogh/canon" && PATH="$ROOT/nogh/bin:$PATH" "$CS" 2>&1); rc=$?
check    "GitHub origin + unavailable gh exits 1" "$rc" "1"
lacks    "never announces no live claims when gh unavailable" "$out" "no live claims"

echo "#153 r7 · explicit successful empty inventory announces no live claims"
new_github_repo "$ROOT/empty"
(
  cd "$ROOT/empty/canon" || exit 1
  rm -rf docs/claims docs/active-work.md
  git add -A && git commit -qm empty && git push -q origin main
) >/dev/null 2>&1
install_empty_gh "$ROOT/empty/bin/gh"
out=$(cd "$ROOT/empty/canon" && PATH="$ROOT/empty/bin:$PATH" "$CS" 2>&1); rc=$?
check    "successful empty inventory exits 0" "$rc" "0"
contains "announces no live claims after success" "$out" "no live claims"

echo "#153 r7 · genuine non-GitHub origin is ledger-only (no PR inventory required)"
new_local_repo "$ROOT/local"
(
  cd "$ROOT/local/canon" || exit 1
  rm -rf docs/claims docs/active-work.md
  git add -A && git commit -qm empty && git push -q origin main
) >/dev/null 2>&1
# No gh on PATH; origin is a bare path — ledger-only is correct.
mkdir -p "$ROOT/local/bin"
# Ensure gh is not accidentally usable for repo view success with a name.
cat > "$ROOT/local/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "fake gh should not be consulted for non-github origin inventory" >&2
exit 64
GH
chmod +x "$ROOT/local/bin/gh"
out=$(cd "$ROOT/local/canon" && PATH="$ROOT/local/bin:$PATH" "$CS" 2>&1); rc=$?
check    "non-GitHub origin ledger-only exits 0" "$rc" "0"
contains "announces no live claims on empty local ledger" "$out" "no live claims"

echo "#153 r7 · failed ls-tree of docs/claims fails closed"
new_local_repo "$ROOT/lstree"
mkdir -p "$ROOT/lstree/bin"
REAL_GIT=$(command -v git)
cat > "$ROOT/lstree/bin/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "ls-tree" ]]; then
  for a in "\$@"; do
    if [[ "\$a" == "docs/claims/" || "\$a" == "docs/claims" ]]; then
      echo "fatal: simulated ls-tree failure for docs/claims" >&2
      exit 128
    fi
  done
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$ROOT/lstree/bin/git"
out=$(cd "$ROOT/lstree/canon" && PATH="$ROOT/lstree/bin:$PATH" "$CS" --ref main 2>&1); rc=$?
check    "failed ls-tree exits 1" "$rc" "1"
contains "names ls-tree failure"  "$out" "cannot list docs/claims"

echo "#153 r7 · unreadable claim blob fails closed"
new_local_repo "$ROOT/blob"
(
  cd "$ROOT/blob/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  printf 'claim: issue-1-ghost\nissue: 1\nclaimed: 2026-08-01T00:00:00Z\nscope: lib/**\nsession: t\n' \
    > docs/claims/issue-1-ghost.md
  git add -A && git commit -qm ghost && git push -q origin main
  # Drop the blob object so git show REF:path fails.
  blob=$(git rev-parse "main:docs/claims/issue-1-ghost.md")
  obj=$(git rev-parse --git-path "objects/${blob:0:2}/${blob:2}")
  rm -f "$obj"
) >/dev/null 2>&1
out=$(cd "$ROOT/blob/canon" && "$CS" --ref main 2>&1); rc=$?
check    "unreadable claim blob exits 1" "$rc" "1"
contains "names unreadable claim blob"  "$out" "cannot read claim blob"

echo "#153 r7 · unreadable legacy table blob fails closed"
new_local_repo "$ROOT/table"
(
  cd "$ROOT/table/canon" || exit 1
  git checkout -q main
  printf '| when | claim-id | scope | who |\n|---|---|---|---|\n| 2026-08-01 | issue-2-legacy | lib/** | s |\n' \
    > docs/active-work.md
  git add -A && git commit -qm table && git push -q origin main
  blob=$(git rev-parse "main:docs/active-work.md")
  obj=$(git rev-parse --git-path "objects/${blob:0:2}/${blob:2}")
  rm -f "$obj"
) >/dev/null 2>&1
out=$(cd "$ROOT/table/canon" && "$CS" --ref main 2>&1); rc=$?
check    "unreadable legacy table exits 1" "$rc" "1"
contains "names unreadable table"         "$out" "cannot read legacy claim table"

echo
echo "claims-status.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
