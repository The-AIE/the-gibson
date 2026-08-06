#!/usr/bin/env bash
set -uo pipefail

# Hermetic git identity (#101): suites that commit must not read ambient global
# user.name/email. Pass with HOME pointed at an empty directory.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"


SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/../repo-boundary-guard.sh"
PASS=0
FAIL=0
ok() { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
REPO="$ROOT"
mkdir -p "$REPO/.agents"
git -C "$ROOT" init -q -b main
git -C "$ROOT" config user.email test@gibson.invalid
git -C "$ROOT" config user.name gibson-test
printf 'base\n' > "$ROOT/README.md"
git -C "$ROOT" add README.md
git -C "$ROOT" commit -qm base
git -C "$ROOT" remote add origin https://github.com/acme/app.git

run_guard() {
  (cd "$ROOT" &&
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" "$@")
}

printf 'forbidden\n' > "$ROOT/.agents/gate.json"
if run_guard add .agents/gate.json >/dev/null 2>"$ROOT/err"; then
  bad "control-plane commit was rejected"
else
  grep -q "control-plane" "$ROOT/err" && ok "control-plane commit was rejected" ||
    bad "control-plane rejection named the control plane"
fi
rm -f "$ROOT/.agents/gate.json"

git -C "$ROOT" remote set-url origin https://github.com/the-gibson/harness.git
if run_guard push origin main >/dev/null 2>"$ROOT/err"; then
  bad "wrong-origin push was rejected"
else
  ok "wrong-origin push was rejected"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "$PASS passed, $FAIL failed"
  exit 0
fi
echo "$PASS passed, $FAIL failed"
exit 1
