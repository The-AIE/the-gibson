#!/usr/bin/env bash
# private-home.test.sh — operator-record write-back destination (#530)
#   * default (GIBSON_PRIVATE_HOME unset): behavior unchanged, writes into the repo tree
#   * override: the same writers land in the private checkout, nothing in the repo tree
#   * a bad override fails closed instead of falling back to the public tree
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
LIB="$REPO_ROOT/scripts/lib/private-home.sh"
STAMP="$REPO_ROOT/scripts/recipe-stamp.sh"
RECIPE="$REPO_ROOT/playbooks/recipes/builder.yaml"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-private-home.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# A fake gibson tree: recipe-stamp resolves its root from its own location.
fake_tree() { # $1 dir
  mkdir -p "$1/memory" "$1/scripts/lib" "$1/playbooks/recipes"
  cp "$STAMP" "$1/scripts/recipe-stamp.sh"; chmod +x "$1/scripts/recipe-stamp.sh"
  cp "$LIB" "$1/scripts/lib/private-home.sh"
  cp "$RECIPE" "$1/playbooks/recipes/builder.yaml"
}
stamp() { # $1 tree ; env passes through
  "$1/scripts/recipe-stamp.sh" --role builder --recipe "$1/playbooks/recipes/builder.yaml" --issue 530 --repo "$1/wt" 2>&1
}

echo "# resolver: unset returns the default root unchanged"
out=$(env -u GIBSON_PRIVATE_HOME bash -c ". '$LIB'; gibson_private_home /some/default"); rc=$?
[[ $rc -eq 0 && "$out" == "/some/default" ]] && ok "unset -> default root" || bad "unset rc=$rc out=$out"

echo "# resolver: set + valid returns the override"
mkdir -p "$ROOT/priv"
out=$(GIBSON_PRIVATE_HOME="$ROOT/priv" bash -c ". '$LIB'; gibson_private_home /some/default"); rc=$?
[[ $rc -eq 0 && "$out" == "$ROOT/priv" ]] && ok "set -> override" || bad "set rc=$rc out=$out"

echo "# resolver: relative or missing override fails closed (exit 2, no fallback)"
out=$(GIBSON_PRIVATE_HOME="relative/dir" bash -c ". '$LIB'; gibson_private_home /some/default" 2>&1); rc=$?
[[ $rc -eq 2 && "$out" != *"/some/default"* ]] && ok "relative path rejected" || bad "relative rc=$rc out=$out"
out=$(GIBSON_PRIVATE_HOME="$ROOT/does-not-exist" bash -c ". '$LIB'; gibson_private_home /some/default" 2>&1); rc=$?
[[ $rc -eq 2 && "$out" != *"/some/default"* ]] && ok "missing directory rejected" || bad "missing rc=$rc out=$out"

echo "# default: recipe-stamp writes into the tree's own memory/"
T1="$ROOT/t1"; fake_tree "$T1"
out=$(env -u GIBSON_PRIVATE_HOME bash -c "$(declare -f stamp); stamp '$T1'"); rc=$?
if [[ $rc -eq 0 ]] && grep -q 'builder' "$T1/memory/recipe-runs.md" 2>/dev/null; then ok "default writes <tree>/memory/recipe-runs.md"; else bad "default stamp rc=$rc: $out"; fi

echo "# override: same writer lands in the private checkout, tree untouched"
T2="$ROOT/t2"; fake_tree "$T2"; mkdir -p "$ROOT/priv2/memory"
out=$(GIBSON_PRIVATE_HOME="$ROOT/priv2" bash -c "$(declare -f stamp); stamp '$T2'"); rc=$?
if [[ $rc -eq 0 ]] && grep -q 'builder' "$ROOT/priv2/memory/recipe-runs.md" 2>/dev/null; then ok "override writes <private>/memory/recipe-runs.md"; else bad "override stamp rc=$rc: $out"; fi
if [[ ! -s "$T2/memory/recipe-runs.md" ]]; then ok "override leaves the public tree's ledger empty"; else bad "override still wrote into the tree"; fi

echo "# override pointing nowhere refuses, never writes to the tree"
T3="$ROOT/t3"; fake_tree "$T3"
out=$(GIBSON_PRIVATE_HOME="$ROOT/nope" bash -c "$(declare -f stamp); stamp '$T3'"); rc=$?
if [[ $rc -eq 2 && ! -s "$T3/memory/recipe-runs.md" ]]; then ok "bad override exits 2 and writes nothing"; else bad "bad override rc=$rc"; fi

echo "# override without memory/ refuses with a clear message"
mkdir -p "$ROOT/priv4"
T4="$ROOT/t4"; fake_tree "$T4"
out=$(GIBSON_PRIVATE_HOME="$ROOT/priv4" bash -c "$(declare -f stamp); stamp '$T4'"); rc=$?
if [[ $rc -eq 1 && "$out" == *"memory/ missing under $ROOT/priv4"* ]]; then ok "missing memory/ in private home reported"; else bad "no-memory rc=$rc out=$out"; fi

echo
echo "private-home.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
