#!/usr/bin/env bash
# route-inventory.test.sh — smoke sensors for AuthZ route matrix scaffold (#192)
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SENSOR="$SCRIPT_DIR/../route-inventory.mjs"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "route-inventory.test.sh: node required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-route-inventory.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# --- help ---
out=$(node "$SENSOR" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'WHAT IT DOES' && ok "help exits 0 with WHAT/WHY" \
  || bad "help (rc=$rc): $out"

# --- unknown flag fails closed (typo must not scan cwd) ---
out=$(node "$SENSOR" --definitely-not-a-flag 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -q 'unknown flag: --definitely-not-a-flag' \
  && ok "unknown flag exits 2 with exact message" \
  || bad "unknown flag (rc=$rc): $out"

# --- typo'd --root must not fall through to cwd ---
out=$(node "$SENSOR" --rot "$ROOT" 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -q 'unknown flag: --rot' \
  && ok "--rot typo is unknown flag (not silent cwd scan)" \
  || bad "--rot (rc=$rc): $out"

# --- missing value ---
out=$(node "$SENSOR" --root 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -q 'requires a value' \
  && ok "--root without value exits 2" \
  || bad "--root missing value (rc=$rc): $out"

# --- no app/ under root ---
mkdir -p "$ROOT/empty"
out=$(node "$SENSOR" --root "$ROOT/empty" 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -qi 'no app' \
  && ok "missing app/ exits 2" \
  || bad "missing app (rc=$rc): $out"

# --- discovers App Router pages ---
mkdir -p "$ROOT/app/dashboard" "$ROOT/app/api/health"
touch "$ROOT/app/page.tsx"
touch "$ROOT/app/dashboard/page.tsx"
touch "$ROOT/app/api/health/route.ts"

out=$(node "$SENSOR" --root "$ROOT" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"path"' && ok "emits JSON with path fields" \
  || bad "JSON emit (rc=$rc): $out"
echo "$out" | grep -q '"/"' && ok "includes root page" || bad "missing root: $out"
echo "$out" | grep -q '/dashboard' && ok "includes /dashboard" || bad "missing dashboard: $out"
echo "$out" | grep -q '/api/health' && ok "includes /api/health handler" || bad "missing api: $out"
echo "$out" | grep -q '"roles"' && ok "includes roles array" || bad "no roles: $out"

# --- --out writes file ---
out=$(node "$SENSOR" --root "$ROOT" --out "$ROOT/matrix.json" 2>&1); rc=$?
[[ "$rc" -eq 0 && -f "$ROOT/matrix.json" ]] && ok "--out writes matrix.json" \
  || bad "--out (rc=$rc): $out"
grep -q 'generated_at' "$ROOT/matrix.json" && ok "matrix has generated_at" \
  || bad "matrix shape: $(head -5 "$ROOT/matrix.json")"

# --- --roles overrides defaults ---
out=$(node "$SENSOR" --root "$ROOT" --roles admin,guest 2>/dev/null); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"guest"' && ok "--roles accepted" \
  || bad "--roles (rc=$rc): $out"

# --- unexpected positional must not scan cwd or write --out (#202) ---
pos_out="$ROOT/should-not-exist.json"
out=$(node "$SENSOR" /tmp/example --out "$pos_out" 2>"$ROOT/pos.err"); rc=$?
stderr=$(cat "$ROOT/pos.err")
[[ "$rc" -eq 2 ]] && echo "$stderr" | grep -q 'unexpected argument' \
  && [[ -z "$out" ]] && [[ ! -f "$pos_out" ]] \
  && ok "bare positional exits 2 with unexpected argument and writes no file" \
  || bad "bare positional (rc=$rc stdout=$(printf %s "$out" | wc -c) file=$([[ -f $pos_out ]] && echo yes || echo no)): $stderr"

# --- positional after -- is rejected the same way ---
dash_out="$ROOT/should-not-exist-dash.json"
node "$SENSOR" -- --root "$ROOT" --out "$dash_out" 2>"$ROOT/dash.err" >/dev/null; rc=$?
stderr=$(cat "$ROOT/dash.err")
[[ "$rc" -eq 2 ]] && echo "$stderr" | grep -q 'unexpected argument' \
  && [[ ! -f "$dash_out" ]] \
  && ok "argument after -- exits 2 with unexpected argument and writes no file" \
  || bad "after -- (rc=$rc file=$([[ -f $dash_out ]] && echo yes || echo no)): $stderr"

# --- trailing positional after documented flags ---
trail_out="$ROOT/should-not-exist-trail.json"
node "$SENSOR" --root "$ROOT" --out "$trail_out" /tmp/example 2>"$ROOT/trail.err" >/dev/null; rc=$?
stderr=$(cat "$ROOT/trail.err")
[[ "$rc" -eq 2 ]] && echo "$stderr" | grep -q 'unexpected argument' \
  && [[ ! -f "$trail_out" ]] \
  && ok "trailing positional exits 2 and does not write --out" \
  || bad "trailing positional (rc=$rc file=$([[ -f $trail_out ]] && echo yes || echo no)): $stderr"

echo
echo "route-inventory.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
