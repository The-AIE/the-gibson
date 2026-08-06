#!/usr/bin/env bash
# dogfood-prep.test.sh — offline sensors for #96 preflight
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
PREP="$REPO_ROOT/scripts/dogfood-prep.sh"
PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-dogfood-prep-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

[[ -x "$PREP" ]] && ok "dogfood-prep.sh executable" || bad "dogfood-prep.sh missing"

# Fake target with matching origin
git init -q "$ROOT/app"
git -C "$ROOT/app" remote add origin "https://github.com/acme/app.git"
mkdir -p "$ROOT/app/docs"

# --- mismatch slug fails ---
if out=$("$PREP" --repo "$ROOT/app" --repo-slug wrong/slug --check-only 2>&1); then
  bad "mismatched slug should fail"
else
  echo "$out" | grep -q "does not match" && ok "slug mismatch fails closed" || bad "unclear slug failure: $out"
fi

# --- match slug green (no runner) ---
if out=$("$PREP" --repo "$ROOT/app" --repo-slug acme/app --check-only 2>&1); then
  echo "$out" | grep -q 'GREEN' && ok "matching slug preflight GREEN" || bad "no GREEN: $out"
else
  bad "matching slug should pass check-only: $out"
fi

# --- HALT present fails ---
mkdir -p "$ROOT/app/gibson"
touch "$ROOT/app/gibson/HALT"
if out=$("$PREP" --repo "$ROOT/app" --repo-slug acme/app --check-only 2>&1); then
  bad "HALT present should fail"
else
  echo "$out" | grep -qi 'HALT' && ok "HALT present fails closed" || bad "no HALT mention"
fi
rm -f "$ROOT/app/gibson/HALT"

# --- --run without confirm refused ---
if out=$("$PREP" --repo "$ROOT/app" --repo-slug acme/app --runner grok --run 2>&1); then
  bad "--run without confirm should fail"
else
  echo "$out" | grep -q 'confirm YES' && ok "--run requires --confirm YES" || bad "no confirm message: $out"
fi

# --- unknown runner fails on --run ---
if out=$("$PREP" --repo "$ROOT/app" --repo-slug acme/app --runner notaclient --run --confirm YES 2>&1); then
  bad "unknown runner should fail"
else
  ok "unknown runner rejected"
fi

# --- goose runner rejected ---
if out=$("$PREP" --repo "$ROOT/app" --repo-slug acme/app --runner goose --check-only 2>&1); then
  bad "goose runner should fail closed while unwired"
else
  echo "$out" | grep -qi 'goose' && ok "goose runner parked/rejected" || bad "goose not mentioned"
fi

# --- playbook + evidence docs present ---
[[ -f "$REPO_ROOT/playbooks/dogfood-overnight.md" ]] && ok "dogfood-overnight playbook present" || bad "missing playbook"
[[ -f "$REPO_ROOT/memory/dogfood/README.md" ]] && ok "memory/dogfood README present" || bad "missing evidence README"

# --- help ---
"$PREP" --help >/dev/null && ok "dogfood-prep --help" || bad "help failed"
bash -n "$PREP" && ok "bash -n dogfood-prep.sh" || bad "bash -n failed"

echo
echo "dogfood-prep.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
