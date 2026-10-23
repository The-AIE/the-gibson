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
[[ "$out" == *"stamped builder/builder.yaml → memory/recipe-runs.md" ]] && ok "default closing line is unchanged (relative memory/recipe-runs.md)" || bad "default closing line changed: $out"

echo "# override: same writer lands in the private checkout, tree untouched"
T2="$ROOT/t2"; fake_tree "$T2"; mkdir -p "$ROOT/priv2/memory"
out=$(GIBSON_PRIVATE_HOME="$ROOT/priv2" bash -c "$(declare -f stamp); stamp '$T2'"); rc=$?
if [[ $rc -eq 0 ]] && grep -q 'builder' "$ROOT/priv2/memory/recipe-runs.md" 2>/dev/null; then ok "override writes <private>/memory/recipe-runs.md"; else bad "override stamp rc=$rc: $out"; fi
[[ "$out" == *"→ $ROOT/priv2/memory/recipe-runs.md" ]] && ok "override closing line names the private ledger it wrote" || bad "override closing line is stale: $out"
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

echo "# dogfood-prep points evidence at the resolved directory (and is unchanged by default)"
git init -q "$ROOT/app"; git -C "$ROOT/app" remote add origin "https://github.com/acme/app.git"; mkdir -p "$ROOT/app/docs"
PREP="$REPO_ROOT/scripts/dogfood-prep.sh"
out=$(env -u GIBSON_PRIVATE_HOME "$PREP" --repo "$ROOT/app" --repo-slug acme/app --check-only 2>&1)
[[ "$out" == *"→ memory/dogfood/YYYY-MM-DD-journal.md"* ]] && ok "default evidence hint is unchanged (relative memory/dogfood)" || bad "default hint changed: $out"
mkdir -p "$ROOT/priv5/memory/dogfood"
out=$(GIBSON_PRIVATE_HOME="$ROOT/priv5" "$PREP" --repo "$ROOT/app" --repo-slug acme/app --check-only 2>&1)
[[ "$out" == *"→ $ROOT/priv5/memory/dogfood/YYYY-MM-DD-journal.md"* && "$out" != *"→ memory/dogfood/"* ]] && ok "override evidence hint names the private directory" || bad "override hint still public-relative: $out"
mkdir -p "$ROOT/priv6/memory"   # no dogfood/ yet
out=$(GIBSON_PRIVATE_HOME="$ROOT/priv6" "$PREP" --repo "$ROOT/app" --repo-slug acme/app --check-only 2>&1)
[[ "$out" == *"missing $ROOT/priv6/memory/dogfood"* ]] && ok "missing-directory warning names the private path" || bad "missing-dir warning stale: $out"

echo "# the recipe suite is hermetic: an exported GIBSON_PRIVATE_HOME is never written by it"
mkdir -p "$ROOT/priv7/memory"
GIBSON_PRIVATE_HOME="$ROOT/priv7" bash "$SCRIPT_DIR/goose-recipes.test.sh" >/dev/null 2>&1
if [[ ! -e "$ROOT/priv7/memory/recipe-runs.md" ]]; then ok "goose-recipes.test.sh did not touch the operator's private ledger"; else bad "goose-recipes.test.sh wrote into GIBSON_PRIVATE_HOME"; fi

echo
echo "private-home.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
