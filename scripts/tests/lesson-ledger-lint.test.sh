#!/usr/bin/env bash
# lesson-ledger-lint.test.sh — mutation witnesses for the Law 9 ledger lint (#306)
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
SENSOR="$SCRIPT_DIR/../lesson-ledger-lint.mjs"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "lesson-ledger-lint.test.sh: node required" >&2; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-lesson-ledger-lint.XXXXXX") || {
  echo "lesson-ledger-lint.test.sh: mktemp -d failed" >&2
  exit 1
}
trap 'rm -rf -- "${ROOT:?}"' EXIT

# Build identifiers without writing a contiguous L-NNN token into this file
# (this suite lives under scripts/tests/ and is itself citation-scanned).
lid() { printf 'L-%03d' "$1"; }

make_tree() {
  local dest="$1"
  mkdir -p "$dest/memory" \
    "$dest/scripts/tests" \
    "$dest/docs" \
    "$dest/ci" \
    "$dest/playbooks" \
    "$dest/config" \
    "$dest/.github" \
    "$dest/adapters" \
    "$dest/templates"
}

# One well-formed lesson. $1=id-number $2=status
entry() {
  local n="$1" status="$2"
  printf '%s\n' "## $(lid "$n") · 2026-09-04 · fixture-lesson-${n}"
  printf '%s\n' "**What happened:** fixture"
  printf '%s\n' "**Root cause:** fixture"
  printf '%s\n' "**Harness fix:** fixture"
  printf '%s\n' "**Status:** ${status}"
  printf '%s\n' "**Tags:** #fixture"
  printf '%s\n' ""
}

run_lint() {
  local tree="$1"
  shift
  out=$(node "$SENSOR" --root "$tree" "$@" 2>&1)
  rc=$?
}

echo "# help / unknown flag"
out=$(node "$SENSOR" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'Law 9' && ok "help" \
  || bad "help (rc=$rc): $out"
out=$(node "$SENSOR" --definitely-not-a-flag 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -q 'unknown flag' && ok "unknown flag exit 2" \
  || bad "unknown flag (rc=$rc): $out"
out=$(node "$SENSOR" --root 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -q 'requires a value' && ok "--root missing value exit 2" \
  || bad "--root missing value (rc=$rc): $out"

echo "# missing ledger fails closed"
MISSING="$ROOT/no-ledger"
make_tree "$MISSING"
run_lint "$MISSING" --offline
[[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'ledger not found' && ok "missing ledger exits nonzero" \
  || bad "missing ledger (rc=$rc): $out"

echo "# AC1 cited identifier absent"
AC1_BAD="$ROOT/ac1-bad"
make_tree "$AC1_BAD"
{
  printf '%s\n' '---'
  printf '%s\n' '# Fleet Lessons'
  printf '%s\n' ''
  entry 1 "fixed"
} > "$AC1_BAD/memory/LESSONS.md"
printf 'See %s in the harness.\n' "$(lid 99)" > "$AC1_BAD/docs/cite.md"
run_lint "$AC1_BAD" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q "$(lid 99)" \
    && echo "$out" | grep -q 'docs/cite.md:1'; then
  ok "AC1 mutation: missing cited id names file:line and id"
else
  bad "AC1 mutation (rc=$rc): $out"
fi

echo "# AC1 clean fixture"
AC1_OK="$ROOT/ac1-ok"
make_tree "$AC1_OK"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fixed"
} > "$AC1_OK/memory/LESSONS.md"
printf 'See %s in the harness.\n' "$(lid 1)" > "$AC1_OK/docs/cite.md"
run_lint "$AC1_OK" --offline
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'OK' && ok "AC1 clean: cited id present" \
  || bad "AC1 clean (rc=$rc): $out"

echo "# AC2 closed issue"
AC2="$ROOT/ac2"
make_tree "$AC2"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #7)"
} > "$AC2/memory/LESSONS.md"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$@" >> "${GH_LOG:?}"
if [[ "${GH_MODE:-}" == "fail" ]]; then
  echo "simulated gh failure" >&2
  exit 1
fi
if [[ "${GH_MODE:-}" == "badjson" ]]; then
  echo "{"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  path="$2"
  case "$path" in
    repos/*/issues/7)
      echo "${GH_STATE:-closed}"
      exit 0
      ;;
  esac
  echo "fake gh: unmodelled api $path" >&2
  exit 64
fi
echo "fake gh: unmodelled: $*" >&2
exit 64
GH
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
export GH_LOG="$ROOT/gh.log"
: > "$GH_LOG"

GH_STATE=closed run_lint "$AC2" --repo acme/app
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q "$(lid 1)" \
    && echo "$out" | grep -q 'issue #7' && echo "$out" | grep -q 'closed'; then
  ok "AC2 mutation: closed pending issue exits 1"
else
  bad "AC2 mutation closed (rc=$rc): $out"
fi

: > "$GH_LOG"
GH_STATE=open run_lint "$AC2" --repo acme/app
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'OK' && ok "AC2 clean: open pending issue" \
  || bad "AC2 clean open (rc=$rc): $out"

: > "$GH_LOG"
GH_MODE=fail run_lint "$AC2" --repo acme/app
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'gh api failed' && ok "AC2 gh error fails closed" \
  || bad "AC2 gh error (rc=$rc): $out"

: > "$GH_LOG"
GH_MODE=badjson run_lint "$AC2" --repo acme/app
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi 'unusable state\|gh api failed' \
  && ok "AC2 unusable gh payload fails closed" \
  || bad "AC2 badjson (rc=$rc): $out"

echo "# AC2 --offline skips only the closed-issue check"
: > "$GH_LOG"
unset GH_STATE
GH_MODE=fail run_lint "$AC2" --repo acme/app --offline
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'OK' \
    && echo "$out" | grep -qF -- '--offline: skipping closed-issue check' \
    && [[ ! -s "$GH_LOG" ]]; then
  ok "AC2 --offline skips check, says so, does not call gh"
else
  bad "AC2 --offline (rc=$rc log=$(cat "$GH_LOG") out=$out)"
fi

echo "# AC3 test-pinned but not fixed"
AC3_BAD="$ROOT/ac3-bad"
make_tree "$AC3_BAD"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_BAD/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "# pins $(lid 1) as a regression"
  printf '%s\n' "echo \"$(lid 1) · planted pin\""
} > "$AC3_BAD/scripts/tests/planted.test.sh"
run_lint "$AC3_BAD" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q "$(lid 1)" \
    && echo "$out" | grep -q 'scripts/tests/planted.test.sh' \
    && echo "$out" | grep -q 'pins it'; then
  ok "AC3 mutation: unfixed lesson pinned by test"
else
  bad "AC3 mutation (rc=$rc): $out"
fi

echo "# AC3 clean: pinned lesson is fixed"
AC3_OK="$ROOT/ac3-ok"
make_tree "$AC3_OK"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fixed (pinned by scripts/tests/planted.test.sh)"
} > "$AC3_OK/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "# pins $(lid 1) as a regression"
  printf '%s\n' "echo \"$(lid 1) · planted pin\""
} > "$AC3_OK/scripts/tests/planted.test.sh"
run_lint "$AC3_OK" --offline
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'OK' && ok "AC3 clean: pinned lesson is fixed" \
  || bad "AC3 clean (rc=$rc): $out"

echo "# AC4 not strictly increasing / duplicate / missing fields"
AC4_ORDER="$ROOT/ac4-order"
make_tree "$AC4_ORDER"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 3 "fixed"
  entry 2 "fixed"
} > "$AC4_ORDER/memory/LESSONS.md"
run_lint "$AC4_ORDER" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q 'not strictly increasing' \
    && echo "$out" | grep -q "$(lid 3)" && echo "$out" | grep -q "$(lid 2)"; then
  ok "AC4 mutation: non-monotonic IDs"
else
  bad "AC4 order (rc=$rc): $out"
fi

AC4_DUP="$ROOT/ac4-dup"
make_tree "$AC4_DUP"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fixed"
  entry 1 "fixed"
} > "$AC4_DUP/memory/LESSONS.md"
run_lint "$AC4_DUP" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q "duplicate lesson ID $(lid 1)"; then
  ok "AC4 mutation: duplicate ID"
else
  bad "AC4 dup (rc=$rc): $out"
fi

AC4_STATUS="$ROOT/ac4-status"
make_tree "$AC4_STATUS"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  printf '%s\n' "## $(lid 1) · 2026-09-04 · no-status"
  printf '%s\n' "**What happened:** fixture"
  printf '%s\n' "**Root cause:** fixture"
  printf '%s\n' "**Harness fix:** fixture"
  printf '%s\n' "**Tags:** #fixture"
} > "$AC4_STATUS/memory/LESSONS.md"
run_lint "$AC4_STATUS" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q "$(lid 1)" \
    && echo "$out" | grep -q 'missing \*\*Status:\*\*'; then
  ok "AC4 mutation: missing Status"
else
  bad "AC4 status (rc=$rc): $out"
fi

AC4_TAGS="$ROOT/ac4-tags"
make_tree "$AC4_TAGS"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  printf '%s\n' "## $(lid 1) · 2026-09-04 · no-tags"
  printf '%s\n' "**What happened:** fixture"
  printf '%s\n' "**Root cause:** fixture"
  printf '%s\n' "**Harness fix:** fixture"
  printf '%s\n' "**Status:** fixed"
} > "$AC4_TAGS/memory/LESSONS.md"
run_lint "$AC4_TAGS" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q "$(lid 1)" \
    && echo "$out" | grep -q 'missing \*\*Tags:\*\*'; then
  ok "AC4 mutation: missing Tags"
else
  bad "AC4 tags (rc=$rc): $out"
fi

AC4_OK="$ROOT/ac4-ok"
make_tree "$AC4_OK"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fixed"
  entry 2 "fixed"
  entry 5 "fixed"
} > "$AC4_OK/memory/LESSONS.md"
run_lint "$AC4_OK" --offline
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'OK' && ok "AC4 clean: increasing IDs with fields" \
  || bad "AC4 clean (rc=$rc): $out"

echo "# live tree (AC6)"
run_lint "$REPO_ROOT" --offline
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'OK'; then
  ok "live tree passes with --offline"
else
  bad "live tree (rc=$rc): $out"
fi

echo
echo "lesson-ledger-lint.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
