#!/usr/bin/env bash
# review-findings-lint.test.sh — sensors for the reviewer finding contract (#401)
#
# Fixtures cover: well-formed review, blocker missing trigger, missing class,
# unknown class, unknown kind, rule-candidate without trigger, verdict not last.
# The mutation test removes the trigger check from a copy of the linter and
# requires the blocker-without-trigger fixture to stop failing.
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SENSOR="$SCRIPT_DIR/../review-findings-lint.mjs"
CLASSES="$SCRIPT_DIR/../../config/review-finding-classes.v1.json"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "review-findings-lint.test.sh: node required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-review-findings.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# expect <name> <fixture-file> <expected-rc> [expected-substring]
expect() {
  local name="$1" file="$2" want_rc="$3" want_text="${4:-}" out rc
  out=$(node "${SENSOR_UNDER_TEST:-$SENSOR}" --file "$file" 2>&1); rc=$?
  if [[ "$rc" -ne "$want_rc" ]]; then
    bad "$name: rc=$rc want $want_rc: $out"
  elif [[ -n "$want_text" && "$out" != *"$want_text"* ]]; then
    bad "$name: output missing '$want_text': $out"
  else
    ok "$name"
  fi
}

cat > "$ROOT/good.md" <<'EOF'
## Review

### Findings
- `a.ts:10` — drops the exit status of the child
  kind: blocker
  class: ignored-error-return
  trigger: child exits 1 => the script still reports success

VERDICT: REQUEST_CHANGES
EOF

cat > "$ROOT/no-trigger.md" <<'EOF'
### Findings
- `a.ts:10` — this could break
  kind: blocker
  class: logic

VERDICT: REQUEST_CHANGES
EOF

cat > "$ROOT/no-trigger-default-kind.md" <<'EOF'
### Findings
- `a.ts:10` — this could break
  class: logic

VERDICT: REQUEST_CHANGES
EOF

cat > "$ROOT/no-class.md" <<'EOF'
### Findings
- `a.ts:10` — nit
  kind: note

VERDICT: APPROVE
EOF

cat > "$ROOT/unknown-class.md" <<'EOF'
### Findings
- `a.ts:10` — nit
  kind: note
  class: vibes

VERDICT: APPROVE
EOF

cat > "$ROOT/unknown-kind.md" <<'EOF'
### Findings
- `a.ts:10` — nit
  kind: showstopper
  class: style
  trigger: x => y

VERDICT: APPROVE
EOF

cat > "$ROOT/rule-candidate.md" <<'EOF'
### Findings
- `a.ts:10` — no linter flags a bare catch here
  kind: rule-candidate
  class: ignored-error-return

VERDICT: APPROVE
EOF

cat > "$ROOT/none.md" <<'EOF'
### Findings
- none

VERDICT: APPROVE
EOF

cat > "$ROOT/verdict-not-last.md" <<'EOF'
### Findings
- none

VERDICT: APPROVE
trailing prose
EOF

cat > "$ROOT/no-verdict.md" <<'EOF'
### Findings
- none
EOF

expect "well-formed review passes" "$ROOT/good.md" 0 "clean"
expect "blocker without trigger fails" "$ROOT/no-trigger.md" 1 "blocking finding without trigger"
expect "kind defaults to blocker, so missing trigger fails" "$ROOT/no-trigger-default-kind.md" 1 "blocking finding without trigger"
expect "finding without class fails" "$ROOT/no-class.md" 1 "finding without class"
expect "unknown class fails" "$ROOT/unknown-class.md" 1 "unknown class 'vibes'"
expect "unknown kind fails" "$ROOT/unknown-kind.md" 1 "unknown kind 'showstopper'"
expect "rule-candidate needs no trigger" "$ROOT/rule-candidate.md" 0 "clean"
expect "'none' findings list passes" "$ROOT/none.md" 0 "clean"
expect "verdict not last fails" "$ROOT/verdict-not-last.md" 1 "not the final line"
expect "missing verdict fails" "$ROOT/no-verdict.md" 1 "missing VERDICT"

# Entry guard must survive symlinked invocation paths (macOS /var -> /private/var).
ln -s "$ROOT" "$ROOT/../gibson-rfl-link.$$" 2>/dev/null
LINK="$ROOT/../gibson-rfl-link.$$"
out=$(node "$SENSOR" --file "$LINK/no-trigger.md" 2>&1); rc=$?
rm -f "$LINK"
[[ "$rc" -eq 1 ]] && ok "linter runs when the fixture path is a symlink" || bad "symlinked path rc=$rc: $out"

# Unknown flags exit 2 without reading stdin (repo convention).
node "$SENSOR" --definitely-not-a-flag </dev/null >/dev/null 2>&1; rc=$?
[[ "$rc" -eq 2 ]] && ok "unknown flag exits 2" || bad "unknown flag rc=$rc want 2"

# Usage / config errors exit 2.
node "$SENSOR" --file "$ROOT/does-not-exist.md" >/dev/null 2>&1; rc=$?
[[ "$rc" -eq 2 ]] && ok "unreadable input exits 2" || bad "unreadable input rc=$rc want 2"

# The shipped vocabulary carries every seeded class (#401 contract).
seeded_missing=""
for c in ignored-error-return unclosed-resource style speculative-no-trigger logic concurrency security contract-coverage test-integrity other; do
  grep -q "\"$c\"" "$CLASSES" || seeded_missing="$seeded_missing $c"
done
[[ -z "$seeded_missing" ]] && ok "vocabulary seeds all required classes" || bad "vocabulary missing:$seeded_missing"

# Mutation: with the trigger check removed, the blocker-without-trigger fixture
# must stop failing. If it still fails, the sensor above proves nothing.
MUT="$ROOT/mutant"
mkdir -p "$MUT/scripts/lib" "$MUT/config"
cp "$CLASSES" "$MUT/config/"
cp "$SCRIPT_DIR/../lib/args.mjs" "$MUT/scripts/lib/"
sed 's/kinds\[kind\]?.blocking && !(it.fields.trigger || "").length/false/' "$SENSOR" > "$MUT/scripts/review-findings-lint.mjs"
if cmp -s "$SENSOR" "$MUT/scripts/review-findings-lint.mjs"; then
  bad "mutation did not apply (trigger check line changed?)"
else
  out=$(SENSOR_UNDER_TEST="$MUT/scripts/review-findings-lint.mjs" node "$MUT/scripts/review-findings-lint.mjs" --file "$ROOT/no-trigger.md" 2>&1); rc=$?
  [[ "$rc" -eq 0 && "$out" == *"clean"* ]] && ok "mutation (trigger check removed) is caught by the no-trigger fixture" \
    || bad "mutant did not report clean (rc=$rc): $out"
fi

echo
echo "review-findings-lint.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
