#!/usr/bin/env bash
# ux-surface.test.sh — sensors for the UX path filter
#
# WHY
#   The whole point of the filter is that a skip must be earned. A false
#   "surface=none" silently disables the UX and DAST gates for that PR, which is
#   a worse outcome than the six wasted minutes it was written to save (L-034 vs
#   L-012). These cases pin both directions.
#
# USAGE
#   scripts/tests/ux-surface.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
UXS="$SCRIPT_DIR/../ux-surface.sh"
PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

# want: none | ui
expect() {
  local want="$1"; shift
  local desc="$1"; shift
  local out rc
  out=$(printf '%s\n' "$@" | "$UXS" --files - 2>/dev/null)
  rc=$?
  local got=none
  [[ "$rc" -eq 1 ]] && got=ui
  if [[ "$got" == "$want" ]] && echo "$out" | grep -q "surface=$want"; then
    ok "$desc"
  else
    bad "$desc (want $want, got $got / $out)"
  fi
}

echo "pure library / infrastructure changes may skip"
expect none "MCP tool + its test (the L-034 case)" apps/mcp/lib/suggest-improvement.ts apps/mcp/lib/suggest-improvement.test.ts
expect none "docs only" README.md docs/07-uiux-evaluation.md
expect none "CI and scripts" .github/workflows/gate.yml scripts/gate.sh
expect none "server-side data access" server/db/queries.ts prisma/schema.prisma

echo "anything a user can see must run the gate"
expect ui "app router page" src/app/pricing/page.tsx
expect ui "a component" components/Nav.tsx
expect ui "featured talk widget (demo for #60)" components/FeaturedTalkWidget.tsx
expect ui "a stylesheet" src/styles/globals.css
expect ui "a static asset" public/og.png
expect ui "tailwind config" tailwind.config.ts
expect ui "e2e flow contract" tests/e2e/flows/checkout.spec.ts
expect ui "one UI file hidden among library files" apps/mcp/lib/a.ts lib/b.ts components/Banner.tsx

echo "empty diff"
expect none "no files at all" ""

echo "repo config overrides the built-in guesses"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-uxs-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/.gibson"
cat > "$ROOT/.gibson/ux-surface.conf" <<'CONF'
# this repo keeps everything user-facing under storefront/
^storefront/
!^storefront/lib/telemetry/
CONF
cd "$ROOT" || exit 1
out=$(printf 'storefront/pages/index.tsx\n' | "$UXS" --files -); rc=$?
[[ "$rc" -eq 1 ]] && ok "config pattern matches" || bad "config pattern matches ($out)"
out=$(printf 'src/app/page.tsx\n' | "$UXS" --files -); rc=$?
[[ "$rc" -eq 0 ]] && ok "config replaces the defaults" || bad "config replaces the defaults ($out)"
out=$(printf 'storefront/lib/telemetry/beacon.ts\n' | "$UXS" --files -); rc=$?
[[ "$rc" -eq 0 ]] && ok "! exception wins over its own prefix" || bad "! exception wins ($out)"
cd - >/dev/null || exit 1

echo
echo "ux-surface.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
