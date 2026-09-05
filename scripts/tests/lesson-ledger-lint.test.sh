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

ORIG_PATH="$PATH"
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
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'Law 9' >/dev/null && ok "help" \
  || bad "help (rc=$rc): $out"
out=$(node "$SENSOR" --definitely-not-a-flag 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep 'unknown flag' >/dev/null && ok "unknown flag exit 2" \
  || bad "unknown flag (rc=$rc): $out"
out=$(node "$SENSOR" --root 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep 'requires a value' >/dev/null && ok "--root missing value exit 2" \
  || bad "--root missing value (rc=$rc): $out"

echo "# missing ledger fails closed"
MISSING="$ROOT/no-ledger"
make_tree "$MISSING"
run_lint "$MISSING" --offline
[[ "$rc" -ne 0 ]] && echo "$out" | grep 'ledger not found' >/dev/null && ok "missing ledger exits nonzero" \
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
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 99)" >/dev/null \
    && echo "$out" | grep 'docs/cite.md:1' >/dev/null; then
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
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null && ok "AC1 clean: cited id present" \
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
if [[ "$1" == "repo" && "$2" == "view" ]]; then
  if [[ -f "$PWD/.gh-repo" ]]; then
    cat "$PWD/.gh-repo"
    exit 0
  fi
  echo "${GH_DECOY_REPO:-decoy/repo}"
  exit 0
fi
if [[ "$1" == "api" ]]; then
  path="$2"
  case "$path" in
    repos/acme/app/issues/7)
      echo "${GH_STATE:-closed}"
      exit 0
      ;;
    repos/*/issues/7)
      echo "open"
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
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'issue #7' >/dev/null && echo "$out" | grep 'closed' >/dev/null; then
  ok "AC2 mutation: closed pending issue exits 1"
else
  bad "AC2 mutation closed (rc=$rc): $out"
fi

: > "$GH_LOG"
GH_STATE=open run_lint "$AC2" --repo acme/app
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null && ok "AC2 clean: open pending issue" \
  || bad "AC2 clean open (rc=$rc): $out"

: > "$GH_LOG"
GH_MODE=fail run_lint "$AC2" --repo acme/app
[[ "$rc" -ne 0 ]] && echo "$out" | grep -i 'gh api failed' >/dev/null && ok "AC2 gh error fails closed" \
  || bad "AC2 gh error (rc=$rc): $out"

: > "$GH_LOG"
GH_MODE=badjson run_lint "$AC2" --repo acme/app
[[ "$rc" -ne 0 ]] && echo "$out" | grep -i 'unusable state\|gh api failed' >/dev/null \
  && ok "AC2 unusable gh payload fails closed" \
  || bad "AC2 badjson (rc=$rc): $out"

echo "# AC2 --offline skips only the closed-issue check"
: > "$GH_LOG"
unset GH_STATE
GH_MODE=fail run_lint "$AC2" --repo acme/app --offline
if [[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null \
    && echo "$out" | grep -F -- '--offline: skipping closed-issue check' >/dev/null \
    && [[ ! -s "$GH_LOG" ]]; then
  ok "AC2 --offline skips check, says so, does not call gh"
else
  bad "AC2 --offline (rc=$rc log=$(cat "$GH_LOG") out=$out)"
fi

echo "# AC2 --root, not --repo: gh repo view must run in the target tree"
printf '%s\n' 'acme/app' > "$AC2/.gh-repo"
: > "$GH_LOG"
unset GH_MODE GH_STATE
export GITHUB_REPOSITORY=decoy/repo
export GH_REPO=decoy/repo
export GH_DECOY_REPO=decoy/repo
GH_STATE=closed run_lint "$AC2"
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'issue #7' >/dev/null && echo "$out" | grep 'closed' >/dev/null; then
  ok "AC2 mutation: --root wins over caller cwd / GITHUB_REPOSITORY"
else
  bad "AC2 --root repo inference (rc=$rc): $out"
fi
unset GITHUB_REPOSITORY GH_REPO GH_DECOY_REPO GH_STATE

echo "# AC3 test name pins an unfixed lesson"
AC3_BAD="$ROOT/ac3-bad"
make_tree "$AC3_BAD"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_BAD/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "ok \"$(lid 1) releases dead lanes\""
} > "$AC3_BAD/scripts/tests/planted.test.sh"
run_lint "$AC3_BAD" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'scripts/tests/planted.test.sh' >/dev/null \
    && echo "$out" | grep 'pins it' >/dev/null; then
  ok "AC3 mutation: unfixed lesson pinned by test name"
else
  bad "AC3 mutation test-name (rc=$rc): $out"
fi

echo "# AC3 @test name pins an unfixed lesson"
AC3_AT="$ROOT/ac3-at"
make_tree "$AC3_AT"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_AT/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "@test \"$(lid 1) still holds\""
} > "$AC3_AT/scripts/tests/planted.test.sh"
run_lint "$AC3_AT" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'scripts/tests/planted.test.sh' >/dev/null \
    && echo "$out" | grep 'pins it' >/dev/null; then
  ok "AC3 mutation: unfixed lesson pinned by @test name"
else
  bad "AC3 mutation @test (rc=$rc): $out"
fi

echo "# AC3 unrelated body comment is not a pin"
AC3_COMMENT="$ROOT/ac3-comment"
make_tree "$AC3_COMMENT"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_COMMENT/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "echo \"unrelated setup\""
  printf '%s\n' "# historical note: $(lid 1) was filed in July"
  printf '%s\n' 'true'
} > "$AC3_COMMENT/scripts/tests/planted.test.sh"
run_lint "$AC3_COMMENT" --offline
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null \
  && ok "AC3 clean: unrelated comment does not pin" \
  || bad "AC3 unrelated comment (rc=$rc): $out"

echo "# AC3 header comment is not a pin"
AC3_HEADER="$ROOT/ac3-header"
make_tree "$AC3_HEADER"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_HEADER/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "# planted.test.sh — sensors for the $(lid 1) contract"
  printf '%s\n' '#'
  printf '%s\n' "#   These cases pin both directions ($(lid 1))."
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'echo "unrelated setup"'
  printf '%s\n' 'true'
} > "$AC3_HEADER/scripts/tests/planted.test.sh"
run_lint "$AC3_HEADER" --offline
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null \
  && ok "AC3 clean: header comment does not pin" \
  || bad "AC3 header comment (rc=$rc): $out"

echo "# AC3 quoted occurrence is not a pin"
AC3_QUOTED="$ROOT/ac3-quoted"
make_tree "$AC3_QUOTED"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_QUOTED/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "echo \"\$out\" | grep '$(lid 1)' >/dev/null && ok help"
} > "$AC3_QUOTED/scripts/tests/planted.test.sh"
run_lint "$AC3_QUOTED" --offline
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null \
  && ok "AC3 clean: quoted grep is not a pin" \
  || bad "AC3 quoted occurrence (rc=$rc): $out"

echo "# AC3 loose 'pin' word is not a pin"
AC3_LOOSE="$ROOT/ac3-loose-pin"
make_tree "$AC3_LOOSE"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_LOOSE/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "echo \"unrelated setup\""
  printf '%s\n' "# the $(lid 1) failure this sensor exists to catch. Pin the canonical key name."
} > "$AC3_LOOSE/scripts/tests/planted.test.sh"
run_lint "$AC3_LOOSE" --offline
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null \
  && ok "AC3 clean: loose pin word does not pin" \
  || bad "AC3 loose pin word (rc=$rc): $out"

echo "# AC3 pin-keyword comment still pins"
AC3_KW="$ROOT/ac3-kw"
make_tree "$AC3_KW"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_KW/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "echo \"unrelated setup\""
  printf '%s\n' "# pins $(lid 1) as a regression"
} > "$AC3_KW/scripts/tests/planted.test.sh"
run_lint "$AC3_KW" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep 'pins it' >/dev/null; then
  ok "AC3 mutation: # pins ID still pins"
else
  bad "AC3 pin-keyword (rc=$rc): $out"
fi

echo "# AC3 pin: ID still pins"
AC3_PINCOL="$ROOT/ac3-pin-colon"
make_tree "$AC3_PINCOL"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_PINCOL/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "echo \"unrelated setup\""
  printf '%s\n' "# pin: $(lid 1)"
} > "$AC3_PINCOL/scripts/tests/planted.test.sh"
run_lint "$AC3_PINCOL" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep 'pins it' >/dev/null; then
  ok "AC3 mutation: pin: ID still pins"
else
  bad "AC3 pin-colon (rc=$rc): $out"
fi

echo "# AC3 regression: ID still pins"
AC3_REG="$ROOT/ac3-regression"
make_tree "$AC3_REG"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_REG/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "echo \"unrelated setup\""
  printf '%s\n' "# regression: $(lid 1)"
} > "$AC3_REG/scripts/tests/planted.test.sh"
run_lint "$AC3_REG" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep 'pins it' >/dev/null; then
  ok "AC3 mutation: regression: ID still pins"
else
  bad "AC3 regression-colon (rc=$rc): $out"
fi

echo "# AC3 header with explicit # pins still pins"
AC3_HEADER_PIN="$ROOT/ac3-header-pin"
make_tree "$AC3_HEADER_PIN"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fix-pending (issue #1)"
} > "$AC3_HEADER_PIN/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "# pins $(lid 1)"
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'true'
} > "$AC3_HEADER_PIN/scripts/tests/planted.test.sh"
run_lint "$AC3_HEADER_PIN" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep 'pins it' >/dev/null; then
  ok "AC3 mutation: header # pins ID still pins"
else
  bad "AC3 header explicit pin (rc=$rc): $out"
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
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "ok \"$(lid 1) releases dead lanes\""
} > "$AC3_OK/scripts/tests/planted.test.sh"
run_lint "$AC3_OK" --offline
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null && ok "AC3 clean: pinned lesson is fixed" \
  || bad "AC3 clean (rc=$rc): $out"

echo "# AC3/AC6 claimed pinner that does not pin"
AC3_FALSE="$ROOT/ac3-false-pinner"
make_tree "$AC3_FALSE"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fixed (pinned by scripts/tests/planted.test.sh)"
} > "$AC3_FALSE/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'echo "no lesson token here"'
} > "$AC3_FALSE/scripts/tests/planted.test.sh"
run_lint "$AC3_FALSE" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'does not pin it' >/dev/null; then
  ok "AC6 mutation: claimed pinner without ID fails"
else
  bad "AC6 false pinner (rc=$rc): $out"
fi

echo "# AC6 claimed pinner that only has a header mention"
AC6_HEADER="$ROOT/ac6-header-pinner"
make_tree "$AC6_HEADER"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fixed (pinned by scripts/tests/planted.test.sh)"
} > "$AC6_HEADER/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "# planted.test.sh — sensors for $(lid 1)"
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'true'
} > "$AC6_HEADER/scripts/tests/planted.test.sh"
run_lint "$AC6_HEADER" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'does not pin it' >/dev/null; then
  ok "AC6 mutation: claimed pinner with only a header mention fails"
else
  bad "AC6 header pinner (rc=$rc): $out"
fi

echo "# AC6 claimed pinner that only has a quoted occurrence"
AC6_QUOTED="$ROOT/ac6-quoted-pinner"
make_tree "$AC6_QUOTED"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fixed (pinned by scripts/tests/planted.test.sh)"
} > "$AC6_QUOTED/memory/LESSONS.md"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "echo \"\$out\" | grep '$(lid 1)' >/dev/null && ok help"
} > "$AC6_QUOTED/scripts/tests/planted.test.sh"
run_lint "$AC6_QUOTED" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'does not pin it' >/dev/null; then
  ok "AC6 mutation: claimed pinner with only a quoted occurrence fails"
else
  bad "AC6 quoted pinner (rc=$rc): $out"
fi

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
if [[ "$rc" -eq 1 ]] && echo "$out" | grep 'not strictly increasing' >/dev/null \
    && echo "$out" | grep "$(lid 3)" >/dev/null && echo "$out" | grep "$(lid 2)" >/dev/null; then
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
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "duplicate lesson ID $(lid 1)" >/dev/null; then
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
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'missing \*\*Status:\*\*' >/dev/null; then
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
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'missing \*\*Tags:\*\*' >/dev/null; then
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
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null && ok "AC4 clean: increasing IDs with fields" \
  || bad "AC4 clean (rc=$rc): $out"

echo "# AC4 fenced example Status/Tags do not satisfy the real entry"
AC4_FENCE="$ROOT/ac4-fence"
make_tree "$AC4_FENCE"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  printf '%s\n' "## $(lid 1) · 2026-09-04 · fenced-fields"
  printf '%s\n' "**What happened:** example in a fence:"
  printf '%s\n' '```'
  printf '%s\n' "## $(lid 99) · 2026-01-01 · phantom"
  printf '%s\n' "**Status:** fixed"
  printf '%s\n' "**Tags:** #example"
  printf '%s\n' '```'
} > "$AC4_FENCE/memory/LESSONS.md"
run_lint "$AC4_FENCE" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'missing \*\*Status:\*\*' >/dev/null \
    && ! echo "$out" | grep "duplicate lesson ID $(lid 1)" >/dev/null; then
  ok "AC4 mutation: fenced Status/Tags/heading are not real fields"
else
  bad "AC4 fence fields (rc=$rc): $out"
fi

echo "# AC4 fenced duplicate heading is not a phantom entry"
AC4_FENCE_OK="$ROOT/ac4-fence-ok"
make_tree "$AC4_FENCE_OK"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fixed"
  printf '%s\n' '```'
  printf '%s\n' "## $(lid 1) · 2026-01-01 · phantom-duplicate"
  printf '%s\n' "**Status:** fixed"
  printf '%s\n' "**Tags:** #example"
  printf '%s\n' '```'
  entry 2 "fixed"
} > "$AC4_FENCE_OK/memory/LESSONS.md"
run_lint "$AC4_FENCE_OK" --offline
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null \
  && ok "AC4 clean: fenced heading is not a duplicate" \
  || bad "AC4 fence duplicate (rc=$rc): $out"

echo "# AC4 tilde-fenced example Status/Tags do not satisfy the real entry"
AC4_TILDE="$ROOT/ac4-tilde"
make_tree "$AC4_TILDE"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  printf '%s\n' "## $(lid 1) · 2026-09-04 · tilde-fenced-fields"
  printf '%s\n' "**What happened:** example in a tilde fence:"
  printf '%s\n' '~~~'
  printf '%s\n' "## $(lid 99) · 2026-01-01 · phantom"
  printf '%s\n' "**Status:** fixed"
  printf '%s\n' "**Tags:** #example"
  printf '%s\n' '~~~'
} > "$AC4_TILDE/memory/LESSONS.md"
run_lint "$AC4_TILDE" --offline
if [[ "$rc" -eq 1 ]] && echo "$out" | grep "$(lid 1)" >/dev/null \
    && echo "$out" | grep 'missing \*\*Status:\*\*' >/dev/null \
    && ! echo "$out" | grep "duplicate lesson ID $(lid 1)" >/dev/null; then
  ok "AC4 mutation: tilde-fenced Status/Tags/heading are not real fields"
else
  bad "AC4 tilde fence fields (rc=$rc): $out"
fi

echo "# AC4 tilde-fenced duplicate heading is not a phantom entry"
AC4_TILDE_OK="$ROOT/ac4-tilde-ok"
make_tree "$AC4_TILDE_OK"
{
  printf '%s\n' '---'
  printf '%s\n' ''
  entry 1 "fixed"
  printf '%s\n' '~~~markdown'
  printf '%s\n' "## $(lid 1) · 2026-01-01 · phantom-duplicate"
  printf '%s\n' "**Status:** fixed"
  printf '%s\n' "**Tags:** #example"
  printf '%s\n' '~~~'
  entry 2 "fixed"
} > "$AC4_TILDE_OK/memory/LESSONS.md"
run_lint "$AC4_TILDE_OK" --offline
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null \
  && ok "AC4 clean: tilde-fenced heading is not a duplicate" \
  || bad "AC4 tilde fence duplicate (rc=$rc): $out"

echo "# live tree (AC6)"
export PATH="$ORIG_PATH"
unset GH_LOG GH_MODE GH_STATE GH_DECOY_REPO GH_REPO
unset GITHUB_REPOSITORY || true
LEDGER="$REPO_ROOT/memory/LESSONS.md"
for n in 9 10 11; do
  if grep -q "^## $(lid "$n") " "$LEDGER"; then
    ok "live ledger has heading $(lid "$n")"
  else
    bad "live ledger missing heading $(lid "$n")"
  fi
done
prev=0
mono=1
while IFS= read -r num; do
  if [[ "$num" -le "$prev" ]]; then
    mono=0
    break
  fi
  prev=$num
done < <(grep -E '^## L-[0-9]{3} ' "$LEDGER" | sed -E 's/^## L-0*([0-9]+) .*/\1/')
[[ "$mono" -eq 1 && "$prev" -gt 0 ]] && ok "live ledger IDs strictly increasing" \
  || bad "live ledger IDs not strictly increasing"
run_lint "$REPO_ROOT"
if [[ "$rc" -eq 0 ]] && echo "$out" | grep 'OK' >/dev/null; then
  ok "live tree passes the lint"
else
  bad "live tree (rc=$rc): $out"
fi


echo "# Codex #316 round 4: mid-line HTML comment; trailing '# pins' on a code line"
R4="$ROOT/r4"; rm -rf "$R4"; mkdir -p "$R4/scripts/tests" "$R4/memory"
B1=$(lid 1); B2=$(lid 2)
{ printf '## %s · 2026-09-04 · midline-comment\nvisible prose <!--\n**Status:** fixed\n**Tags:** #fixture\n-->\n\n' "$B1"
  printf '## %s · 2026-09-04 · trailing-marker\n**What happened:** x\n**Status:** fix-pending (issue #1)\n**Tags:** #x\n' "$B2"; } > "$R4/memory/LESSONS.md"
printf '%s\n' '#!/bin/bash' "[[ \"\$a\" = \"\$b\" ]] # pins $B2" > "$R4/scripts/tests/t.test.sh"
run_lint "$R4" --offline
printf '%s\n' "$out" | grep -E "$B1 .*(missing|lacks|no) .*Status|$B1.*Status" >/dev/null && ok "r4-1: Status/Tags inside a mid-line HTML comment do not satisfy the entry" || bad "r4-1: mid-line comment satisfied the entry: $out"
printf '%s\n' "$out" | grep "$B2 is not fixed but scripts/tests/t.test.sh pins it" >/dev/null && ok "r4-2: a trailing '# pins' comment on a code line is an explicit marker" || bad "r4-2: trailing marker not recognised: $out"


echo "# Codex #316 round 5: quoted ID before a real trailing marker; title with the ID mid-string; two openers on one line"
R5="$ROOT/r5"; rm -rf "$R5"; mkdir -p "$R5/scripts/tests" "$R5/memory"
C1=$(lid 1); C2=$(lid 2); C3=$(lid 3)
{ printf '## %s · 2026-09-04 · quoted-then-marker\n**What happened:** x\n**Status:** fix-pending (issue #1)\n**Tags:** #x\n\n' "$C1"
  printf '## %s · 2026-09-04 · title-mid-id\n**What happened:** x\n**Status:** fix-pending (issue #1)\n**Tags:** #x\n\n' "$C2"
  printf '## %s · 2026-09-04 · two-openers\n<!-- closed --> prose <!--\n**Status:** fixed\n**Tags:** #x\n-->\n' "$C3"; } > "$R5/memory/LESSONS.md"
printf '%s\n' '#!/bin/bash' "grep -q '$C1' \"\$out\" # pins $C1" "ok \"claim cleanup regression $C2\"" > "$R5/scripts/tests/t.test.sh"
run_lint "$R5" --offline
printf '%s\n' "$out" | grep "$C1 is not fixed but scripts/tests/t.test.sh pins it" >/dev/null && ok "r5-1: a quoted ID earlier on the line does not veto a real trailing '# pins' marker" || bad "r5-1: trailing marker vetoed: $out"
printf '%s\n' "$out" | grep "$C2 is not fixed but scripts/tests/t.test.sh pins it" >/dev/null && ok "r5-2: ok \"… regression L-NNN\" (ID mid-title) is a test name" || bad "r5-2: mid-title ID not recognised: $out"
printf '%s\n' "$out" | grep -E "$C3.*(Status|Tags)" >/dev/null && ok "r5-3: <!-- closed --> prose <!-- … --> still hides the commented fields" || bad "r5-3: second opener ignored: $out"


echo "# Codex #316 round 6: title isolation — grep in a title, fixture lines carrying title-like text, assertion strings"
R6="$ROOT/r6"; rm -rf "$R6"; mkdir -p "$R6/scripts/tests" "$R6/memory"
D1=$(lid 1); D2=$(lid 2); D3=$(lid 3); D4=$(lid 4)
{ for n in 1 2 3 4; do printf '## %s · 2026-09-04 · t%s\n**What happened:** x\n**Status:** fix-pending (issue #1)\n**Tags:** #x\n\n' "$(lid $n)" "$n"; done; } > "$R6/memory/LESSONS.md"
printf '%s\n' '#!/bin/bash' "ok \"$D1 verifies grep handling\"" "printf '%s\\n' '@test \"$D2 works\"' > fixture" "test('unrelated', () => { expect(out).toBe('$D3'); })" "@test \"regression $D4\"" > "$R6/scripts/tests/t.test.sh"
run_lint "$R6" --offline
printf '%s\n' "$out" | grep "$D1 is not fixed but scripts/tests/t.test.sh pins it" >/dev/null && ok "r6-1: a title containing the word grep still pins" || bad "r6-1: grep veto: $out"
printf '%s\n' "$out" | grep "$D2 is not fixed" >/dev/null && bad "r6-2a: fixture line carrying '@test \"L-NNN\"' text counted as a pin: $out" || ok "r6-2a: a printf fixture line is not a title"
printf '%s\n' "$out" | grep "$D3 is not fixed" >/dev/null && bad "r6-2b: ID only in an assertion string counted as a pin: $out" || ok "r6-2b: an assertion string is not the title"
printf '%s\n' "$out" | grep "$D4 is not fixed but scripts/tests/t.test.sh pins it" >/dev/null && ok "r6-2c: @test \"regression L-NNN\" (ID mid-title) pins" || bad "r6-2c: mid-title @test missed: $out"

echo

echo "# Codex #316 round 3: quoted markers, zero-path claims, HTML comments"
R3="$ROOT/r3"; rm -rf "$R3"; mkdir -p "$R3/scripts/tests" "$R3/memory" "$R3/docs"
# IDs are built with lid() so this test file never carries a literal lesson ID the live lint could read as a citation.
A1=$(lid 1); A2=$(lid 2); A99=$(lid 99)
{ printf '## %s · 2026-09-04 · quoted-marker-is-not-a-pin\n**What happened:** x\n**Status:** fixed (pinned by scripts/tests/q.test.sh)\n**Tags:** #x\n\n' "$A1"
  printf '## %s · 2026-09-04 · claim-with-no-path\n**What happened:** x\n**Status:** fixed (pinned by q.test.sh)\n**Tags:** #x\n\n' "$A2"
  printf '<!-- template, not an entry:\n## %s · 2026-09-04 · commented-out\n**Status:** fixed\n**Tags:** #x\n-->\n' "$A99"; } > "$R3/memory/LESSONS.md"
printf '%s\n' '#!/bin/bash' "printf '%s\\n' '# pins $A1' > fixture" "echo \"$A1\" > needle" > "$R3/scripts/tests/q.test.sh"
printf 'see %s\n' "$A99" > "$R3/docs/cite.md"
run_lint "$R3" --offline
printf '%s\n' "$out" | grep "$A1 status claims pinned by scripts/tests/q.test.sh but" >/dev/null && ok "r3-2: a quoted '# pins' marker in fixture data is not a pin" || bad "r3-2: quoted marker accepted: $out"
printf '%s\n' "$out" | grep "$A2 status claims 'pinned by' but names no" >/dev/null && ok "r3-3: 'pinned by q.test.sh' (no scripts/tests path) is a finding, not a bypass" || bad "r3-3: zero-path claim bypassed: $out"
printf '%s\n' "$out" | grep "cited $A99 is absent" >/dev/null && ok "r3-4: an entry inside an HTML comment is not an entry (its citation is dangling)" || bad "r3-4: commented template parsed as entry: $out"
printf '%s\n' '#!/bin/bash' "# pins $A1" > "$R3/scripts/tests/q.test.sh"
run_lint "$R3" --offline
printf '%s\n' "$out" | grep "$A1 status claims" >/dev/null && bad "r3-2 control: a real comment-line marker was rejected: $out" || ok "r3-2 control: a real '# pins' comment line is a pin"

echo "lesson-ledger-lint.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
