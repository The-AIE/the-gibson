#!/usr/bin/env bash
# review-findings-lint.test.sh — sensors for the reviewer finding contract (#401)
#
# Fixtures cover: well-formed review, blocker missing trigger, missing class,
# unknown class, unknown kind, rule-candidate without trigger, verdict not last,
# and the pre-existing kind (#758): accepted with trigger and base evidence,
# rejected without either. A malformed `requires` list in the vocabulary is a
# config error (exit 2) whatever the review contains.
# Two mutation tests work on a copy of the linter: one removes the rule that a
# blocking kind needs a trigger, one removes the `requires` rule. Each requires
# its fixture to stop failing.
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

cat > "$ROOT/pre-existing.md" <<'EOF'
### Findings
- `a.ts:10` — bare catch swallows the error; present before this diff
  kind: pre-existing
  class: ignored-error-return
  trigger: fetch rejects => the error is swallowed and the caller sees success
  base: a.ts:10 at the base commit has the same bare catch; the diff does not touch it

VERDICT: APPROVE
EOF

cat > "$ROOT/pre-existing-no-base.md" <<'EOF'
### Findings
- `a.ts:10` — bare catch swallows the error; present before this diff
  kind: pre-existing
  class: ignored-error-return
  trigger: fetch rejects => the error is swallowed and the caller sees success

VERDICT: APPROVE
EOF

cat > "$ROOT/pre-existing-no-trigger.md" <<'EOF'
### Findings
- `a.ts:10` — bare catch swallows the error; present before this diff
  kind: pre-existing
  class: ignored-error-return
  base: a.ts:10 at the base commit has the same bare catch; the diff does not touch it

VERDICT: APPROVE
EOF

cat > "$ROOT/pre-existing-empty-base.md" <<'EOF'
### Findings
- `a.ts:10` — bare catch swallows the error; present before this diff
  kind: pre-existing
  class: ignored-error-return
  trigger: fetch rejects => the error is swallowed and the caller sees success
  base:

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
expect "missing kind is reported" "$ROOT/no-trigger-default-kind.md" 1 "finding without kind"
expect "missing kind is still treated as blocking (no trigger reported)" "$ROOT/no-trigger-default-kind.md" 1 "blocking finding without trigger"
expect "finding without class fails" "$ROOT/no-class.md" 1 "finding without class"
expect "unknown class fails" "$ROOT/unknown-class.md" 1 "unknown class 'vibes'"
expect "unknown kind fails" "$ROOT/unknown-kind.md" 1 "unknown kind 'showstopper'"
expect "rule-candidate needs no trigger" "$ROOT/rule-candidate.md" 0 "clean"
expect "pre-existing with trigger and base evidence passes" "$ROOT/pre-existing.md" 0 "clean"
expect "pre-existing without base evidence fails" "$ROOT/pre-existing-no-base.md" 1 "pre-existing finding without base evidence"
expect "pre-existing with an empty base line fails" "$ROOT/pre-existing-empty-base.md" 1 "pre-existing finding without base evidence"
expect "pre-existing without trigger fails" "$ROOT/pre-existing-no-trigger.md" 1 "pre-existing finding without trigger"
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

# Vocabulary errors are config errors: exit 2, reported once, and reported even
# when the review holds no finding of the malformed kind.
vocab_with() { # vocab_with <out-file> <js statement changing v>
  node -e 'const fs=require("fs");const v=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));eval(process.argv[3]);fs.writeFileSync(process.argv[2],JSON.stringify(v));' "$CLASSES" "$1" "$2"
}
expect_vocab_error() { # expect_vocab_error <name> <classes-file> <fixture> <expected-substring>
  local name="$1" classes="$2" file="$3" want_text="$4" out rc n
  out=$(node "$SENSOR" --classes "$classes" --file "$file" 2>&1); rc=$?
  n=$(grep -c -F -- "$want_text" <<<"$out")
  if [[ "$rc" -ne 2 ]]; then bad "$name: rc=$rc want 2: $out"
  elif [[ "$n" -ne 1 ]]; then bad "$name: want '$want_text' once, got $n: $out"
  else ok "$name"; fi
}
cat > "$ROOT/two-pre-existing.md" <<'EOF'
### Findings
- `a.ts:10` — bare catch swallows the error; present before this diff
  kind: pre-existing
  class: ignored-error-return
  trigger: fetch rejects => the error is swallowed and the caller sees success
  base: a.ts:10 at the base commit has the same bare catch; no changed line reaches it
- `b.ts:20` — handle is never closed; present before this diff
  kind: pre-existing
  class: unclosed-resource
  trigger: open succeeds and parse throws => the handle leaks
  base: b.ts:20 at the base commit is identical; no changed line reaches it

VERDICT: APPROVE
EOF
vocab_with "$ROOT/requires-not-array.json" 'v.kinds["pre-existing"].requires="trigger"'
vocab_with "$ROOT/requires-unknown-field.json" 'v.kinds["pre-existing"].requires=["trigger","severity"]'
expect "two well-formed pre-existing findings pass with the shipped vocabulary" "$ROOT/two-pre-existing.md" 0 "clean"
expect_vocab_error "requires that is not a list exits 2 with no finding of that kind" "$ROOT/requires-not-array.json" "$ROOT/none.md" "kind 'pre-existing' has an invalid requires list"
expect_vocab_error "requires that is not a list is reported once for two findings" "$ROOT/requires-not-array.json" "$ROOT/two-pre-existing.md" "kind 'pre-existing' has an invalid requires list"
expect_vocab_error "requires naming an unknown field exits 2 with no finding of that kind" "$ROOT/requires-unknown-field.json" "$ROOT/none.md" "kind 'pre-existing' requires unknown field 'severity'"
expect_vocab_error "requires naming an unknown field is reported once for two findings" "$ROOT/requires-unknown-field.json" "$ROOT/two-pre-existing.md" "kind 'pre-existing' requires unknown field 'severity'"

# The shipped vocabulary keeps pre-existing non-blocking with both required
# fields. The accepting fixture above cannot show this: it carries a trigger.
pre=$(node -e 'const k=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).kinds["pre-existing"];console.log(JSON.stringify([k.blocking,k.requires]))' "$CLASSES" 2>&1)
[[ "$pre" == '[false,["trigger","base"]]' ]] && ok "shipped pre-existing kind is non-blocking and requires trigger and base" \
  || bad "shipped pre-existing kind: $pre"

# A kind that is blocking and also lists trigger in requires reports a missing
# trigger once, not twice.
vocab_with "$ROOT/blocker-requires-trigger.json" 'v.kinds.blocker.requires=["trigger"]'
out=$(node "$SENSOR" --classes "$ROOT/blocker-requires-trigger.json" --file "$ROOT/no-trigger.md" 2>&1); rc=$?
n=$(grep -c "without trigger" <<<"$out")
[[ "$rc" -eq 1 && "$n" -eq 1 ]] && ok "blocking kind that also requires trigger reports the missing trigger once" \
  || bad "duplicate trigger report (rc=$rc, count=$n): $out"

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
sed 's/def?.blocking ? \["trigger"\] : \[\]/[]/' "$SENSOR" > "$MUT/scripts/review-findings-lint.mjs"
if cmp -s "$SENSOR" "$MUT/scripts/review-findings-lint.mjs"; then
  bad "mutation did not apply (trigger check line changed?)"
else
  out=$(SENSOR_UNDER_TEST="$MUT/scripts/review-findings-lint.mjs" node "$MUT/scripts/review-findings-lint.mjs" --file "$ROOT/no-trigger.md" 2>&1); rc=$?
  [[ "$rc" -eq 0 && "$out" == *"clean"* ]] && ok "mutation (trigger check removed) is caught by the no-trigger fixture" \
    || bad "mutant did not report clean (rc=$rc): $out"
fi

# Mutation: with the `requires` rule removed, the pre-existing fixture with no
# base evidence must stop failing.
sed 's/Array.isArray(def?.requires) ? def.requires : \[\]/[]/' "$SENSOR" > "$MUT/scripts/review-findings-lint.mjs"
if cmp -s "$SENSOR" "$MUT/scripts/review-findings-lint.mjs"; then
  bad "requires mutation did not apply (requires loop line changed?)"
else
  out=$(node "$MUT/scripts/review-findings-lint.mjs" --file "$ROOT/pre-existing-no-base.md" 2>&1); rc=$?
  [[ "$rc" -eq 0 && "$out" == *"clean"* ]] && ok "mutation (requires rule removed) is caught by the no-base fixture" \
    || bad "requires mutant did not report clean (rc=$rc): $out"
fi

echo
echo "review-findings-lint.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
