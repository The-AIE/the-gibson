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
trap 'rm -rf "$ROOT"' EXIT
GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

# Bare origin + clone (mirrors claim fixtures)
setup_repo() {
  local name="$1"
  rm -rf "$ROOT/$name"
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

echo
echo "scope-overlap.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
