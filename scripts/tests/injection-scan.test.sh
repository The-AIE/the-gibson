#!/usr/bin/env bash
# injection-scan.test.sh — sensors for the invisible-character scan (red-team Phase 2)
#
# WHY
#   The scan exists because the attack is invisible to review. A scanner that
#   quietly misses a codepoint is worse than no scanner: it converts "nobody
#   checked" into "we checked and it was fine". These cases pin the codepoints
#   and the exit code.
#
# USAGE
#   scripts/tests/injection-scan.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
SCAN="$SCRIPT_DIR/../injection-scan.sh"
PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-scan-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

detects() { # name escape
  local f="$ROOT/case.md"
  printf 'harmless text%bmore text\n' "$2" > "$f"
  local out rc
  out=$("$SCAN" "$f" 2>&1); rc=$?
  if [[ "$rc" -eq 1 ]] && echo "$out" | grep -qF "$1"; then
    ok "detects $1"
  else
    bad "detects $1 (rc=$rc, out=$out)"
  fi
}

echo "the Pale Fire codepoints"
detects "U+200B" '\xe2\x80\x8b'
detects "U+200C" '\xe2\x80\x8c'
detects "U+200D" '\xe2\x80\x8d'
detects "U+2060" '\xe2\x81\xa0'
detects "U+FEFF" '\xef\xbb\xbf'
detects "U+202E" '\xe2\x80\xae'   # bidi override: renders text in reverse
detects "U+00AD" '\xc2\xad'
detects "U+3000" '\xe3\x80\x80'

echo "clean input stays quiet"
printf '# A normal skill\n\nRun `npm test` — em-dashes, accents (café), emoji 🚀 are all fine.\n' \
  > "$ROOT/clean.md"
out=$("$SCAN" "$ROOT/clean.md" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q clean; then
  ok "no false positive on ordinary prose"
else
  bad "no false positive on ordinary prose (rc=$rc, out=$out)"
fi

echo "scope"
SCOPE="$ROOT/scope"; mkdir -p "$SCOPE"
printf 'binary-ish\xe2\x80\x8b\n' > "$SCOPE/thing.png"
out=$("$SCAN" "$SCOPE" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "skips non-ingested file types by default" || bad "skips non-ingested file types ($out)"
out=$("$SCAN" --all "$SCOPE/thing.png" 2>&1); rc=$?
[[ "$rc" -eq 1 ]] && ok "--all scans anything asked of it" || bad "--all scans anything asked of it ($out)"

echo "reporting"
printf 'line one\nline two\xe2\x80\x8b\n' > "$ROOT/where.md"
out=$("$SCAN" "$ROOT/where.md" 2>&1)
echo "$out" | grep -q "where.md:2:" && ok "names the file and line" || bad "names the file and line ($out)"
echo "$out" | grep -q "ZERO WIDTH SPACE" && ok "names the codepoint" || bad "names the codepoint"

echo "the harness scans itself clean"
out=$(cd "$SCRIPT_DIR/../.." && "$SCAN" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "this repo is clean" || bad "this repo is NOT clean: $out"

echo
echo "injection-scan.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
