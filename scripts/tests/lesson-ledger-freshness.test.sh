#!/usr/bin/env bash
# lesson-ledger-freshness.test.sh — freshness, debt ratchet, annotate, mutations (#571)
#
# WHY
#   A ledger check that cannot run must not look healthy, and a wording
#   edit must not look like a new lesson. Each claimed branch is broken
#   on a copy, shown red, parsed, restored, and shown green.
#
# USAGE
#   scripts/tests/lesson-ledger-freshness.test.sh
set -uo pipefail

unset FORCE_COLOR
unset NO_COLOR
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
SENSOR="$REPO_ROOT/scripts/lesson-ledger-freshness.mjs"
FIX="$REPO_ROOT/scripts/tests/fixtures/lesson-ledger-freshness"
BASELINE="$REPO_ROOT/config/lesson-debt-baseline.json"
WORKFLOW="$REPO_ROOT/.github/workflows/lesson-ledger-freshness.yml"
DOC="$REPO_ROOT/docs/lesson-ledger-freshness.md"
NOW="2026-10-25T00:00:00.000Z"
SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "lesson-ledger-freshness.test.sh: node required"; exit 1; }
command -v git >/dev/null || { echo "lesson-ledger-freshness.test.sh: git required"; exit 1; }
command -v python3 >/dev/null || { echo "lesson-ledger-freshness.test.sh: python3 required"; exit 1; }
[[ -f "$SENSOR" ]] || { echo "lesson-ledger-freshness.test.sh: missing sensor"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-lesson-ledger-freshness.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

has() {
  printf '%s\n' "$1" | grep -E "$2" >/dev/null
}
has_f() {
  printf '%s\n' "$1" | grep -F -- "$2" >/dev/null
}

RUN_OUT=""
RUN_RC=0
run_sensor() {
  RUN_RC=0
  RUN_OUT=$(node "$SENSOR" "$@" 2>"$ROOT/last.err") || RUN_RC=$?
}

expect_rc() {
  local name="$1" want="$2"
  if [[ "$RUN_RC" -eq "$want" ]]; then
    ok "$name"
  else
    bad "$name rc=$RUN_RC want=$want"
  fi
}
expect_has() {
  local name="$1" needle="$2"
  if has_f "$RUN_OUT" "$needle"; then
    ok "$name"
  else
    bad "$name missing expected text"
  fi
}
expect_lacks() {
  local name="$1" needle="$2"
  if has_f "$RUN_OUT" "$needle"; then
    bad "$name unexpectedly matched"
  else
    ok "$name"
  fi
}

# mode flip: green token and red token exchange places.
# mode drop: green token disappears; red token is present before and after.
prove() {
  local label="$1" old="$2" new="$3" green="$4" red="$5" mode="$6"
  shift 6
  local dest="$ROOT/m-$label"
  local sensor out rc
  rm -rf "$dest"
  mkdir -p "$dest"
  ln -s "$REPO_ROOT/scripts/lib" "$dest/lib"
  cp "$SENSOR" "$dest/sensor.mjs"
  sensor="$dest/sensor.mjs"
  rc=0
  out=$(node "$sensor" "$@" 2>"$dest/start.err") || rc=$?
  if has_f "$out" "$green" && { [[ "$mode" == "drop" ]] || ! has_f "$out" "$red"; }; then
    ok "mutation $label starts holding"
  else
    bad "mutation $label did not start holding (rc=$rc)"
    printf '%s\n' "$out" | head -5
  fi
  if ! OLD_TEXT="$old" NEW_TEXT="$new" python3 -c '
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
old = os.environ["OLD_TEXT"]
new = os.environ["NEW_TEXT"]
text = p.read_text()
n = text.count(old)
if n != 1:
    sys.stderr.write("replace count %s\n" % n)
    raise SystemExit(1)
p.write_text(text.replace(old, new, 1))
' "$sensor" 2>"$dest/repl.err"; then
    bad "mutation $label replace failed"
    return
  fi
  if node --check "$sensor" 2>"$dest/check.err"; then
    ok "mutation $label still parses"
  else
    bad "mutation $label failed to parse"
  fi
  local broken_rc=0
  out=$(node "$sensor" "$@" 2>"$dest/broken.err") || broken_rc=$?
  if has_f "$out" "$red" && ! has_f "$out" "$green"; then
    ok "mutation $label breaks the property"
  else
    bad "mutation $label stayed green"
  fi
  cp "$SENSOR" "$sensor"
  if node --check "$sensor" 2>"$dest/restored-check.err"; then
    ok "mutation $label restore parses"
  else
    bad "mutation $label restore failed to parse"
  fi
  rc=0
  out=$(node "$sensor" "$@" 2>"$dest/restored.err") || rc=$?
  if has_f "$out" "$green"; then
    ok "mutation $label restore holds"
  else
    bad "mutation $label restore lost the property"
  fi
  echo "EVIDENCE $label mode=$mode broken_rc=$broken_rc"
}

write_activity() {
  local path="$1" when="$2"
  if [[ -z "$when" ]]; then
    printf '%s\n' '{"available":true,"merges":[]}' >"$path"
  else
    printf '{"available":true,"merges":[{"sha":"%s","committedAt":"%s"}]}\n' "$SHA_A" "$when" >"$path"
  fi
}

init_repo() {
  local repo="$1" branch="$2"
  git init -q -b "$branch" "$repo"
  git -C "$repo" config user.email fixture@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
}

commit_at() {
  local repo="$1" when="$2" msg="$3"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$repo" -c commit.gpgsign=false commit -q -m "$msg"
}

printf '%s\n' '{"schema":"gibson.lesson-debt-baseline.v1","windowDays":14,"proseOnlyCount":1,"statusMarker":"no sensor yet"}' >"$ROOT/base.json"
BASE="$ROOT/base.json"
printf '%s\n' '{"schema":"gibson.lesson-debt-baseline.v1","windowDays":14,"proseOnlyCount":5,"statusMarker":"no sensor yet"}' >"$ROOT/base-high.json"
printf '%s\n' '{"schema":"gibson.lesson-debt-baseline.v1","windowDays":14,"proseOnlyCount":1,"statusMarker":"no sensor yet"}' >"$ROOT/base-committed.json"
mkdir -p "$ROOT/debt-over"
cp "$FIX/inactivity/activity.json" "$ROOT/debt-over/activity.json"
cat >"$ROOT/debt-over/lessons.md" <<'EOF'
# Fixture ledger

## L-010 · 2026-09-01 · sample-one
**Status:** no sensor yet
**Tags:** #fixture

## L-011 · 2026-09-02 · sample-two
**Status:** no sensor yet
**Tags:** #fixture
EOF
cp "$ROOT/debt-over/lessons.md" "$ROOT/debt-over/prior-lessons.md"

echo "# CLI contract"
help_out=$(node "$SENSOR" --help 2>"$ROOT/help.err")
help_rc=$?
if [[ "$help_rc" -eq 0 ]] \
   && has_f "$help_out" "WHAT IT DOES" \
   && has_f "$help_out" "WHY" \
   && has_f "$help_out" "RISKS" \
   && has_f "$help_out" "USAGE" \
   && has_f "$help_out" "EXIT" \
   && ! has_f "$help_out" "untrusted, verify before acting"; then
  ok "--help exits 0 with contract fields"
else
  bad "--help contract (rc=$help_rc)"
fi
[[ ! -s "$ROOT/help.err" ]] && ok "--help quiet on stderr" || bad "--help wrote stderr"

unk_err=$(node "$SENSOR" --definitely-not-a-flag 2>&1 >/dev/null)
unk_rc=$?
if [[ "$unk_rc" -eq 2 ]] && has_f "$unk_err" "unknown flag: --definitely-not-a-flag"; then
  ok "unknown flag exits 2"
else
  bad "unknown flag rc=$unk_rc"
fi

noval_err=$(node "$SENSOR" --fixture 2>&1 >/dev/null)
noval_rc=$?
if [[ "$noval_rc" -eq 2 ]] && has_f "$noval_err" "lesson-ledger-freshness: --fixture requires a value"; then
  ok "missing flag value exits 2"
else
  bad "missing flag value rc=$noval_rc"
fi

run_sensor --fixture "$FIX/inactivity" --lessons "$FIX/inactivity/lessons.md" --now "$NOW" --baseline "$BASE"
expect_rc "fixture and lessons together is usage" 2

run_sensor --fixture "$FIX/inactivity" --baseline "$BASE"
expect_rc "fixture without now is usage" 2

run_sensor --window-days 0 --fixture "$FIX/inactivity" --now "$NOW" --baseline "$BASE"
expect_rc "window days must be a positive integer" 2

if node --check "$SENSOR"; then
  ok "sensor parses"
else
  bad "sensor failed to parse"
fi

echo "# freshness fixtures"
run_sensor --fixture "$FIX/merges-stale" --now "$NOW" --baseline "$BASE"
expect_rc "stale ledger exits 0" 0
expect_has "stale verdict red" "verdict: RED"
expect_has "stale freshness" "freshness: stale"
expect_has "stale reason" "reason: merges-without-intake"
expect_has "stale observation complete" "observation: complete"
expect_has "stale merge count" "mergesInWindow: 1"
expect_has "stale adds no heading" "newHeadings: 0"
expect_has "identical text is not cosmetic-only" "cosmeticOnly: no"
expect_has "stale warning" "::warning::lesson-ledger-freshness verdict RED"
expect_has "window start" "windowStart: 2026-10-11T00:00:00.000Z"
expect_lacks "stale is not healthy" "freshness: healthy"

run_sensor --fixture "$FIX/inactivity" --now "$NOW" --baseline "$BASE"
expect_rc "inactivity exits 0" 0
expect_has "inactivity verdict green" "verdict: GREEN"
expect_has "inactivity freshness" "freshness: healthy"
expect_has "inactivity reason" "reason: inactivity"
expect_has "inactivity merge count" "mergesInWindow: 0"
expect_has "inactivity debt ok" "debtRatchet: ok"
expect_has "inactivity debt reason" "debtReason: ok"
expect_lacks "inactivity has no warning" "::warning::"

run_sensor --fixture "$FIX/missing-activity" --now "$NOW" --baseline "$BASE"
expect_rc "missing activity exits 1" 1
expect_has "missing activity verdict" "verdict: UNKNOWN"
expect_has "missing activity freshness" "freshness: unknown"
expect_has "missing activity keeps its reason" "reason: sensor-offline"
expect_has "missing activity is incomplete" "observation: incomplete"
expect_has "missing activity warning" "::warning::lesson-ledger-freshness cannot evaluate"
expect_lacks "missing activity is not healthy" "freshness: healthy"
expect_has "new heading does not rescue missing activity" "lesson: L-012 date=2026-10-20 ageDays=5 proseOnly=no"

run_sensor --fixture "$FIX/cosmetic-only" --now "$NOW" --baseline "$BASE"
expect_rc "cosmetic edit exits 0" 0
expect_has "cosmetic edit stays stale" "freshness: stale"
expect_has "cosmetic edit flag" "cosmeticOnly: yes"
expect_has "cosmetic edit adds no heading" "newHeadings: 0"
expect_has "cosmetic edit verdict red" "verdict: RED"

run_sensor --fixture "$FIX/date-rewrite" --now "$NOW" --baseline "$BASE"
expect_has "rewritten heading date stays stale" "freshness: stale"
expect_has "rewritten heading date adds no id" "newHeadings: 0"
expect_has "rewritten heading date is cosmetic" "cosmeticOnly: yes"

run_sensor --fixture "$FIX/fresh-intake" --now "$NOW" --baseline "$BASE"
expect_rc "new heading exits 0" 0
expect_has "new heading is healthy" "freshness: healthy"
expect_has "new heading reason" "reason: intake"
expect_has "new heading count" "newHeadings: 1"
expect_has "new heading verdict green" "verdict: GREEN"

run_sensor --fixture "$FIX/fenced-status" --now "$NOW" --baseline "$BASE"
expect_has "fenced ledger is healthy" "freshness: healthy"
expect_has "body marker is not debt" "debtCount: 0"
expect_has "debt below baseline may fall" "debtReason: below-baseline"
expect_lacks "fenced heading is not a lesson" "lesson: L-011"

run_sensor --fixture "$FIX/parser-shapes" --now "$NOW" --baseline "$BASE"
expect_has "parser shapes stay healthy" "freshness: healthy"
expect_has "month-only age is unknown" "lesson: L-002 date=2026-07 ageDays=unknown proseOnly=no"
expect_has "camelCase slug parses" "lesson: L-048 date=2026-08-03 ageDays=83 proseOnly=no"

run_sensor --fixture "$FIX/missing-ledger" --now "$NOW" --baseline "$BASE"
expect_rc "missing ledger exits 1" 1
expect_has "missing ledger freshness" "freshness: unknown"
expect_has "missing ledger reason" "reason: ledger-missing"
expect_lacks "missing ledger is not healthy" "freshness: healthy"

echo "# annotate"
run_sensor --annotate --fixture "$FIX/merges-stale" --now "$NOW" --baseline "$BASE"
expect_rc "annotate stale exits 0" 0
expect_has "annotate stale ledger line" "ledger: untrusted, verify before acting"
expect_has "annotate stale lesson line" "L-010 untrusted, verify before acting"
expect_has "annotate stale second lesson" "L-011 untrusted, verify before acting"
expect_lacks "annotate omits the warning" "::warning::"

run_sensor --annotate --fixture "$FIX/inactivity" --now "$NOW" --baseline "$BASE"
expect_has "annotate healthy freshness" "freshness: healthy"
expect_lacks "annotate healthy is trusted" "untrusted, verify before acting"

run_sensor --annotate --fixture "$FIX/missing-ledger" --now "$NOW" --baseline "$BASE"
expect_has "annotate unknown still names the ledger" "ledger: untrusted, verify before acting"
expect_lacks "annotate unknown has no lesson list" "L-010 untrusted"

run_sensor --fixture "$ROOT/debt-over" --now "$NOW" --baseline "$BASE"
expect_rc "debt rise exits 0" 0
expect_has "debt rise is over" "debtRatchet: over"
expect_has "debt rise reason" "debtReason: count-rose"
expect_has "debt rise count" "debtCount: 2"
expect_has "debt rise verdict red" "verdict: RED"
expect_has "debt rise freshness stays healthy" "freshness: healthy"
run_sensor --annotate --fixture "$ROOT/debt-over" --now "$NOW" --baseline "$BASE"
expect_lacks "annotate ignores a healthy debt rise" "untrusted, verify before acting"

echo "# window and activity edges"
write_activity "$ROOT/at-start.json" "2026-10-11T00:00:00.000Z"
write_activity "$ROOT/before-start.json" "2026-10-10T23:59:59.000Z"
write_activity "$ROOT/at-now.json" "2026-10-25T00:00:00.000Z"
write_activity "$ROOT/after-now.json" "2026-10-25T00:00:00.001Z"
printf '%s\n' "{\"available\":true,\"merges\":[{\"sha\":\"$SHA_A\",\"committedAt\":\"2026-10-20T12:00:00.000Z\"},{\"sha\":\"$SHA_B\",\"committedAt\":\"2026-10-26T00:00:00.000Z\"}]}" >"$ROOT/future-and-one.json"
printf '%s\n' '{"available":true,"merges":[{"sha":"GGGG","committedAt":"2026-10-20T12:00:00.000Z"}]}' >"$ROOT/bad-sha.json"
printf '%s\n' '{"available":"yes","merges":[]}' >"$ROOT/bad-available.json"
printf '%s\n' '{"available":true,"merges":[{"committedAt":"not-a-date"}]}' >"$ROOT/bad-date.json"

run_sensor --lessons "$FIX/merges-stale/lessons.md" --prior-lessons "$FIX/merges-stale/prior-lessons.md" --activity "$ROOT/at-start.json" --now "$NOW" --baseline "$BASE"
expect_has "commit at window start counts" "mergesInWindow: 1"
expect_has "commit at window start is stale" "freshness: stale"

run_sensor --lessons "$FIX/merges-stale/lessons.md" --prior-lessons "$FIX/merges-stale/prior-lessons.md" --activity "$ROOT/before-start.json" --now "$NOW" --baseline "$BASE"
expect_has "commit before the window does not count" "mergesInWindow: 0"
expect_has "commit before the window is healthy" "freshness: healthy"

run_sensor --lessons "$FIX/merges-stale/lessons.md" --prior-lessons "$FIX/merges-stale/prior-lessons.md" --activity "$ROOT/at-now.json" --now "$NOW" --baseline "$BASE"
expect_has "commit at now counts" "freshness: stale"

run_sensor --lessons "$FIX/merges-stale/lessons.md" --prior-lessons "$FIX/merges-stale/prior-lessons.md" --activity "$ROOT/after-now.json" --now "$NOW" --baseline "$BASE"
expect_has "commit after now is ignored" "mergesInWindow: 0"
expect_has "commit after now is healthy" "freshness: healthy"

run_sensor --lessons "$FIX/merges-stale/lessons.md" --prior-lessons "$FIX/merges-stale/prior-lessons.md" --activity "$ROOT/future-and-one.json" --now "$NOW" --baseline "$BASE"
expect_has "future commit is not a merge" "mergesInWindow: 1"

run_sensor --lessons "$FIX/merges-stale/lessons.md" --prior-lessons "$FIX/merges-stale/prior-lessons.md" --activity "$ROOT/bad-sha.json" --now "$NOW" --baseline "$BASE"
expect_rc "bad sha exits 1" 1
expect_has "bad sha is unknown" "freshness: unknown"
expect_has "bad sha reason" "reason: activity-unparseable"
expect_lacks "bad sha is not healthy" "freshness: healthy"

run_sensor --lessons "$FIX/inactivity/lessons.md" --prior-lessons "$FIX/inactivity/prior-lessons.md" --activity "$ROOT/bad-available.json" --now "$NOW" --baseline "$BASE"
expect_has "non-boolean activity is unknown" "reason: activity-unparseable"
expect_lacks "non-boolean activity is not healthy" "freshness: healthy"

run_sensor --lessons "$FIX/inactivity/lessons.md" --prior-lessons "$FIX/inactivity/prior-lessons.md" --activity "$ROOT/bad-date.json" --now "$NOW" --baseline "$BASE"
expect_has "unparseable activity date is unknown" "reason: activity-unparseable"

run_sensor --lessons "$FIX/merges-stale/lessons.md" --activity "$FIX/merges-stale/activity.json" --now "$NOW" --baseline "$BASE"
expect_has "merges without a prior ledger are unknown" "freshness: unknown"
expect_has "merges without a prior ledger reason" "reason: prior-ledger-missing"
expect_lacks "merges without a prior ledger are not stale" "freshness: stale"
expect_lacks "merges without a prior ledger are not healthy" "freshness: healthy"

run_sensor --lessons "$FIX/inactivity/lessons.md" --activity "$FIX/inactivity/activity.json" --now "$NOW" --baseline "$BASE"
expect_has "quiet window without a prior ledger is healthy" "freshness: healthy"
expect_has "quiet window without a prior ledger reason" "reason: inactivity"
expect_has "quiet window hides the heading delta" "newHeadings: unknown"

cat >"$ROOT/removed.md" <<'EOF'
# Fixture ledger

## L-010 · 2026-09-01 · sample-one
**Status:** fixed
**Tags:** #fixture
EOF
run_sensor --lessons "$ROOT/removed.md" --prior-lessons "$FIX/fresh-intake/lessons.md" --activity "$FIX/merges-stale/activity.json" --now "$NOW" --baseline "$BASE"
expect_has "a removed id is not intake" "freshness: stale"
expect_has "a removed id adds nothing" "newHeadings: 0"

cat >"$ROOT/dup.md" <<'EOF'
## L-010 · 2026-09-01 · sample-one
**Status:** fixed

## L-010 · 2026-09-02 · sample-one-again
**Status:** fixed
EOF
cp "$ROOT/dup.md" "$ROOT/dup-prior.md"
write_activity "$ROOT/empty-activity.json" ""
run_sensor --lessons "$ROOT/dup.md" --prior-lessons "$ROOT/dup-prior.md" --activity "$ROOT/empty-activity.json" --now "$NOW" --baseline "$BASE"
expect_has "duplicate id is unknown" "reason: duplicate-lesson-id"
expect_lacks "duplicate id is not healthy" "freshness: healthy"

cat >"$ROOT/bad-heading.md" <<'EOF'
## L-010 not a ledger heading
**Status:** fixed
EOF
run_sensor --lessons "$ROOT/bad-heading.md" --prior-lessons "$ROOT/bad-heading.md" --activity "$ROOT/empty-activity.json" --now "$NOW" --baseline "$BASE"
expect_has "malformed heading is unknown" "reason: malformed-heading"
expect_lacks "malformed heading is not healthy" "freshness: healthy"

cat >"$ROOT/case.md" <<'EOF'
## L-010 · 2026-09-01 · sample-one
**Status:** No sensor yet
**Tags:** #fixture
EOF
cp "$ROOT/case.md" "$ROOT/case-prior.md"
run_sensor --lessons "$ROOT/case.md" --prior-lessons "$ROOT/case-prior.md" --activity "$ROOT/empty-activity.json" --now "$NOW" --baseline "$BASE"
expect_has "marker match is case sensitive" "proseOnly=no"
expect_has "case difference is not debt" "debtCount: 0"

cat >"$ROOT/first-status.md" <<'EOF'
## L-010 · 2026-09-01 · sample-one
**Status:** fixed
**Status:** no sensor yet
EOF
cp "$ROOT/first-status.md" "$ROOT/first-status-prior.md"
run_sensor --lessons "$ROOT/first-status.md" --prior-lessons "$ROOT/first-status-prior.md" --activity "$ROOT/empty-activity.json" --now "$NOW" --baseline "$BASE"
expect_has "only the first status line counts" "proseOnly=no"

cat >"$ROOT/deep-fence.md" <<'EOF'
## L-010 · 2026-09-01 · sample-one
**Status:** fixed

    ```
## L-011 · 2026-09-02 · sample-two
**Status:** no sensor yet
    ```
EOF
cp "$ROOT/deep-fence.md" "$ROOT/deep-fence-prior.md"
run_sensor --lessons "$ROOT/deep-fence.md" --prior-lessons "$ROOT/deep-fence-prior.md" --activity "$ROOT/empty-activity.json" --now "$NOW" --baseline "$BASE"
expect_has "a four-space fence is not skipped" "lesson: L-011 date=2026-09-02 ageDays=53 proseOnly=yes"

cat >"$ROOT/shallow-fence.md" <<'EOF'
## L-010 · 2026-09-01 · sample-one
**Status:** fixed

   ```
## L-011 · 2026-09-02 · sample-two
**Status:** no sensor yet
   ```
EOF
cp "$ROOT/shallow-fence.md" "$ROOT/shallow-fence-prior.md"
run_sensor --lessons "$ROOT/shallow-fence.md" --prior-lessons "$ROOT/shallow-fence-prior.md" --activity "$ROOT/empty-activity.json" --now "$NOW" --baseline "$BASE"
expect_lacks "a three-space fence is skipped" "lesson: L-011"

echo "# ratchet"
run_sensor --fixture "$FIX/inactivity" --now "$NOW" --baseline "$BASE" --window-days 30 --committed-baseline "$ROOT/base-committed.json"
expect_has "a longer window is over" "debtRatchet: over"
expect_has "a longer window reason" "debtReason: window-loosened"
expect_has "a longer window stays fresh" "freshness: healthy"

run_sensor --fixture "$FIX/inactivity" --now "$NOW" --baseline "$BASE" --window-days 7 --committed-baseline "$ROOT/base-committed.json"
expect_has "a shorter window is allowed" "debtRatchet: ok"
expect_lacks "a shorter window is not loosened" "window-loosened"

run_sensor --fixture "$FIX/fenced-status" --now "$NOW" --baseline "$ROOT/base-high.json" --committed-baseline "$ROOT/base-committed.json"
expect_has "a higher baseline count is over" "debtReason: baseline-raised"
expect_has "a higher baseline verdict" "debtRatchet: over"
expect_has "live debt under the new count is still over" "debtCount: 0"

run_sensor --fixture "$FIX/inactivity" --now "$NOW" --baseline "$ROOT/no-such.json"
expect_rc "missing baseline exits 1" 1
expect_has "missing baseline reason" "reason: baseline-missing"
expect_lacks "missing baseline is not healthy" "freshness: healthy"

printf '%s\n' '{not json' >"$ROOT/bad.json"
run_sensor --fixture "$FIX/merges-stale" --now "$NOW" --baseline "$ROOT/bad.json"
expect_has "malformed baseline is unknown" "reason: baseline-malformed"
expect_lacks "malformed baseline is not healthy" "freshness: healthy"

run_sensor --fixture "$FIX/merges-stale" --now "$NOW" --baseline "$ROOT/no-such.json" --window-days 14
expect_rc "stale with an unevaluable debt exits 1" 1
expect_has "stale freshness still reported" "freshness: stale"
expect_has "unevaluable debt" "debtRatchet: unknown"
expect_has "unevaluable debt verdict" "verdict: UNKNOWN"

echo "# live git"
TWO="$FIX/merges-stale/lessons.md"
init_repo "$ROOT/quiet" main
mkdir -p "$ROOT/quiet/memory"
cp "$TWO" "$ROOT/quiet/memory/LESSONS.md"
commit_at "$ROOT/quiet" "2026-09-01T00:00:00Z" "prior ledger"
run_sensor --root "$ROOT/quiet" --now "$NOW" --baseline "$BASE"
expect_rc "quiet history exits 0" 0
expect_has "quiet history is healthy" "freshness: healthy"
expect_has "quiet history reason" "reason: inactivity"
expect_has "quiet history has no committed baseline" "committedBaseline: absent"
expect_lacks "absent baseline is not a failure" "debtRatchet: unknown"

init_repo "$ROOT/stale-git" main
mkdir -p "$ROOT/stale-git/memory"
cp "$TWO" "$ROOT/stale-git/memory/LESSONS.md"
commit_at "$ROOT/stale-git" "2026-09-01T00:00:00Z" "prior ledger"
printf '\nWording only.\n' >>"$ROOT/stale-git/memory/LESSONS.md"
commit_at "$ROOT/stale-git" "2026-10-20T12:00:00Z" "cosmetic"
run_sensor --root "$ROOT/stale-git" --now "$NOW" --baseline "$BASE"
expect_has "git cosmetic commit is stale" "freshness: stale"
expect_has "git cosmetic commit flag" "cosmeticOnly: yes"
expect_has "git cosmetic commit adds no id" "newHeadings: 0"

init_repo "$ROOT/intake-git" main
mkdir -p "$ROOT/intake-git/memory"
cp "$TWO" "$ROOT/intake-git/memory/LESSONS.md"
commit_at "$ROOT/intake-git" "2026-09-01T00:00:00Z" "prior ledger"
cat >>"$ROOT/intake-git/memory/LESSONS.md" <<'EOF'

## L-012 · 2026-10-20 · added-heading
**Status:** fixed
**Tags:** #fixture
EOF
commit_at "$ROOT/intake-git" "2026-10-20T12:00:00Z" "intake"
run_sensor --root "$ROOT/intake-git" --now "$NOW" --baseline "$BASE"
expect_has "git new id is healthy" "freshness: healthy"
expect_has "git new id reason" "reason: intake"

init_repo "$ROOT/young" main
mkdir -p "$ROOT/young/memory"
cp "$TWO" "$ROOT/young/memory/LESSONS.md"
commit_at "$ROOT/young" "2026-10-20T12:00:00Z" "only commit"
run_sensor --root "$ROOT/young" --now "$NOW" --baseline "$BASE"
expect_has "young repo inside the window is intake" "freshness: healthy"
expect_has "young repo reason" "reason: intake"
expect_lacks "young repo is not unknown" "freshness: unknown"

init_repo "$ROOT/empty-ledger" main
mkdir -p "$ROOT/empty-ledger/memory"
printf '%s\n' '# Ledger' 'No lessons yet.' >"$ROOT/empty-ledger/memory/LESSONS.md"
commit_at "$ROOT/empty-ledger" "2026-10-20T12:00:00Z" "empty ledger"
run_sensor --root "$ROOT/empty-ledger" --now "$NOW" --baseline "$BASE"
expect_has "empty ledger with a commit is stale" "freshness: stale"
expect_has "empty ledger adds no id" "newHeadings: 0"

init_repo "$ROOT/shallow-src" main
mkdir -p "$ROOT/shallow-src/memory"
cp "$TWO" "$ROOT/shallow-src/memory/LESSONS.md"
commit_at "$ROOT/shallow-src" "2026-10-20T12:00:00Z" "only commit"
git clone -q --depth 1 "file://${ROOT}/shallow-src" "$ROOT/shallow"
run_sensor --root "$ROOT/shallow" --now "$NOW" --baseline "$BASE"
expect_rc "shallow history exits 1" 1
expect_has "shallow history is unknown" "freshness: unknown"
expect_has "shallow history reason" "reason: shallow-history"
expect_lacks "shallow history is not healthy" "freshness: healthy"

init_repo "$ROOT/edge" main
mkdir -p "$ROOT/edge/memory"
cp "$TWO" "$ROOT/edge/memory/LESSONS.md"
commit_at "$ROOT/edge" "2026-09-01T00:00:00Z" "prior ledger"
printf '\nedge\n' >>"$ROOT/edge/memory/LESSONS.md"
commit_at "$ROOT/edge" "2026-10-11T00:00:00Z" "on the boundary"
run_sensor --root "$ROOT/edge" --now "$NOW" --baseline "$BASE"
expect_has "git commit on the window boundary counts" "mergesInWindow: 1"
expect_has "git commit on the window boundary is stale" "freshness: stale"

init_repo "$ROOT/before" main
mkdir -p "$ROOT/before/memory"
cp "$TWO" "$ROOT/before/memory/LESSONS.md"
commit_at "$ROOT/before" "2026-09-01T00:00:00Z" "prior ledger"
printf '\nbefore\n' >>"$ROOT/before/memory/LESSONS.md"
commit_at "$ROOT/before" "2026-10-10T23:59:59Z" "before the boundary"
run_sensor --root "$ROOT/before" --now "$NOW" --baseline "$BASE"
expect_has "git commit before the window does not count" "mergesInWindow: 0"
expect_has "git commit before the window is healthy" "freshness: healthy"

init_repo "$ROOT/side" side
mkdir -p "$ROOT/side/memory"
cp "$TWO" "$ROOT/side/memory/LESSONS.md"
commit_at "$ROOT/side" "2026-10-20T12:00:00Z" "side branch"
run_sensor --root "$ROOT/side" --now "$NOW" --baseline "$BASE"
expect_rc "missing main exits 1" 1
expect_has "missing main reason" "reason: activity-ref-missing"
expect_lacks "missing main is not healthy" "freshness: healthy"

mkdir -p "$ROOT/not-a-repo"
run_sensor --root "$ROOT/not-a-repo" --now "$NOW" --baseline "$BASE"
expect_has "a directory without git is unknown" "reason: activity-ref-missing"
expect_lacks "a directory without git is not healthy" "freshness: healthy"

init_repo "$ROOT/raised" main
mkdir -p "$ROOT/raised/memory" "$ROOT/raised/config"
cp "$FIX/fenced-status/lessons.md" "$ROOT/raised/memory/LESSONS.md"
cp "$ROOT/base-committed.json" "$ROOT/raised/config/lesson-debt-baseline.json"
commit_at "$ROOT/raised" "2026-09-01T00:00:00Z" "baseline"
cp "$ROOT/base-high.json" "$ROOT/outside-baseline.json"
run_sensor --root "$ROOT/raised" --now "$NOW" --baseline "$ROOT/outside-baseline.json"
expect_has "outside baseline is the working count" "debtReason: baseline-raised"
expect_has "outside baseline still reads the committed file" "committedBaseline: compared"

echo "# measured ledger"
measured=$(SENSOR_PATH="$SENSOR" LEDGER_PATH="$REPO_ROOT/memory/LESSONS.md" node --input-type=module -e '
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
const mod = await import(pathToFileURL(process.env.SENSOR_PATH).href);
const text = readFileSync(process.env.LEDGER_PATH, "utf8");
const parsed = mod.parseLedger(text, "no sensor yet");
if (!parsed.ok) {
  process.stderr.write(parsed.reason + "\n");
  process.exit(1);
}
const debt = parsed.lessons.filter((lesson) => lesson.proseOnly).length;
process.stdout.write(String(parsed.lessons.length) + " " + String(debt));
' 2>"$ROOT/measure.err")
measure_rc=$?
lesson_n=${measured%% *}
debt_n=${measured##* }
if [[ "$measure_rc" -eq 0 && "$lesson_n" -gt 0 && "$debt_n" -gt 0 ]]; then
  ok "live ledger parses"
else
  bad "live ledger parse rc=$measure_rc"
fi
if node -e '
const baseline = require(process.argv[1]);
const debt = Number(process.argv[2]);
if (baseline.schema !== "gibson.lesson-debt-baseline.v1") process.exit(2);
if (baseline.windowDays !== 14) process.exit(3);
if (baseline.statusMarker !== "no sensor yet") process.exit(4);
if (baseline.measuredOn !== "2026-10-25") process.exit(5);
if (baseline.proseOnlyCount !== debt) process.exit(6);
' "$BASELINE" "$debt_n"; then
  ok "baseline matches the measured prose-only count"
else
  bad "baseline does not match the measured count"
fi
write_activity "$ROOT/real-activity.json" ""
run_sensor --lessons "$REPO_ROOT/memory/LESSONS.md" --prior-lessons "$REPO_ROOT/memory/LESSONS.md" --activity "$ROOT/real-activity.json" --baseline "$BASELINE" --now "$NOW"
expect_rc "real ledger explicit run exits 0" 0
expect_has "real ledger is healthy when nothing landed" "freshness: healthy"
expect_has "real ledger verdict" "verdict: GREEN"
expect_has "real ledger debt matches the file" "debtCount: $debt_n"
expect_has "real ledger ratchet holds" "debtRatchet: ok"
expect_has "newest prose-only age" "lesson: L-096 date=2026-10-08 ageDays=17 proseOnly=yes"
expect_has "month-only lesson age" "lesson: L-002 date=2026-07 ageDays=unknown proseOnly=no"
expect_lacks "real ledger freshness is not unknown" "freshness: unknown"

echo "# source and workflow"
if grep -E 'spawn\(|[^.]fetch\(|https://api.github.com|shell: true' "$SENSOR" >/dev/null; then
  bad "sensor has a network or shell call"
else
  ok "sensor stays on local git arguments"
fi
if grep -F 'GITHUB_STEP_SUMMARY' "$SENSOR" >/dev/null; then
  bad "sensor writes the step summary itself"
else
  ok "stdout is the script result"
fi
if grep -F 'execFileSync' "$SENSOR" >/dev/null; then
  ok "sensor reads git without a shell"
else
  bad "sensor does not invoke git"
fi

if [[ -f "$WORKFLOW" ]] \
   && grep -F 'cron: "17 13 * * *"' "$WORKFLOW" >/dev/null \
   && grep -F 'workflow_dispatch:' "$WORKFLOW" >/dev/null \
   && grep -F 'contents: read' "$WORKFLOW" >/dev/null \
   && grep -F 'fetch-depth: 0' "$WORKFLOW" >/dev/null \
   && grep -F 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2' "$WORKFLOW" >/dev/null \
   && grep -F 'set -euo pipefail' "$WORKFLOW" >/dev/null \
   && grep -F 'node scripts/lesson-ledger-freshness.mjs --root .' "$WORKFLOW" >/dev/null \
   && grep -F 'cancel-in-progress: false' "$WORKFLOW" >/dev/null \
   && grep -F 'timeout-minutes: 10' "$WORKFLOW" >/dev/null; then
  ok "workflow is report-only and full-history"
else
  bad "workflow shape"
fi
if grep -E 'pull_request|continue-on-error|\|\| true|issues: write|contents: write' "$WORKFLOW" >/dev/null; then
  bad "workflow has a blocking or write setting"
else
  ok "workflow does not block merges"
fi
if grep -F 'does not block merges' "$DOC" >/dev/null \
   && grep -F 'untrusted, verify before acting' "$DOC" >/dev/null \
   && grep -F 'sensor-health-observation.v1.json' "$DOC" >/dev/null \
   && grep -F 'fetch-depth: 0' "$DOC" >/dev/null; then
  ok "doc states the limits"
else
  bad "doc is missing a limit"
fi

echo "# mutations"
prove activity \
  'return { freshness: "unknown", reason: activity && activity.reason ? activity.reason : "activity-unavailable", mergesInWindow: null, newHeadings: null, cosmeticOnly: null }; // MUTATION_ACTIVITY' \
  'return { freshness: "healthy", reason: activity && activity.reason ? activity.reason : "activity-unavailable", mergesInWindow: 0, newHeadings: 0, cosmeticOnly: false }; // MUTATION_ACTIVITY' \
  'freshness: unknown' 'freshness: healthy' flip \
  --fixture "$FIX/missing-activity" --now "$NOW" --baseline "$BASE"

prove cosmetic \
  'const intake = added.length > 0; // MUTATION_COSMETIC' \
  'const intake = added.length > 0 || bodyDiff; // MUTATION_COSMETIC' \
  'freshness: stale' 'freshness: healthy' flip \
  --fixture "$FIX/cosmetic-only" --now "$NOW" --baseline "$BASE"

prove date-rewrite \
  'const intake = added.length > 0; // MUTATION_COSMETIC' \
  'const intake = added.length > 0 || bodyDiff; // MUTATION_COSMETIC' \
  'freshness: stale' 'freshness: healthy' flip \
  --fixture "$FIX/date-rewrite" --now "$NOW" --baseline "$BASE"

prove stale \
  'freshness: "stale",
      reason: "merges-without-intake",' \
  'freshness: "healthy",
      reason: "merges-without-intake",' \
  'freshness: stale' 'freshness: healthy' flip \
  --fixture "$FIX/merges-stale" --now "$NOW" --baseline "$BASE"

prove quiet \
  'freshness: "healthy",
      reason: priorOk && added.length > 0 ? "intake-without-merges" : "inactivity",' \
  'freshness: "stale",
      reason: priorOk && added.length > 0 ? "intake-without-merges" : "inactivity",' \
  'freshness: healthy' 'freshness: stale' flip \
  --fixture "$FIX/inactivity" --now "$NOW" --baseline "$BASE"

prove debt \
  'if (debtCount > baseline.proseOnlyCount) reasons.push("count-rose"); // MUTATION_DEBT' \
  'if (false) reasons.push("count-rose"); // MUTATION_DEBT' \
  'debtRatchet: over' 'debtRatchet: ok' flip \
  --fixture "$ROOT/debt-over" --now "$NOW" --baseline "$BASE"

prove annotate \
  'const untrusted = report.freshness === "stale" || report.freshness === "unknown"; // MUTATION_ANNOTATE' \
  'const untrusted = false; // MUTATION_ANNOTATE' \
  'untrusted, verify before acting' 'freshness: stale' drop \
  --annotate --fixture "$FIX/merges-stale" --now "$NOW" --baseline "$BASE"

prove fence \
  'const markerMatch = /^(?: {0,3})(`{3,}|~{3,})(.*)$/.exec(line); // MUTATION_FENCE' \
  'const markerMatch = /^(?: {0,3})(NEVER_A_FENCE)(.*)$/.exec(line); // MUTATION_FENCE' \
  'debtCount: 0' 'lesson: L-011' flip \
  --fixture "$FIX/fenced-status" --now "$NOW" --baseline "$BASE"

prove ledger \
  'if (!input.current || !input.current.ok) {
    return freshnessUnknown(input.current && input.current.reason ? input.current.reason : "ledger-missing"); // MUTATION_LEDGER
  }' \
  'if (false) {
    return freshnessUnknown(input.current && input.current.reason ? input.current.reason : "ledger-missing"); // MUTATION_LEDGER
  }' \
  'freshness: unknown' 'freshness: healthy' flip \
  --fixture "$FIX/missing-ledger" --now "$NOW" --baseline "$BASE"

prove shallow \
  'if (shallow.stdout.trim() === "true") { // MUTATION_SHALLOW' \
  'if (shallow.stdout.trim() === "never") { // MUTATION_SHALLOW' \
  'reason: shallow-history' 'freshness: healthy' flip \
  --root "$ROOT/shallow" --now "$NOW" --baseline "$BASE"

prove window \
  'if (baseline.windowDays > committed.windowDays) reasons.push("window-loosened"); // MUTATION_WINDOW' \
  'if (baseline.windowDays < committed.windowDays) reasons.push("window-loosened"); // MUTATION_WINDOW' \
  'window-loosened' 'debtRatchet: ok' flip \
  --fixture "$FIX/inactivity" --now "$NOW" --baseline "$BASE" --window-days 30 --committed-baseline "$ROOT/base-committed.json"

prove baseline-raise \
  'if (baseline.proseOnlyCount > committed.proseOnlyCount) reasons.push("baseline-raised"); // MUTATION_BASELINE' \
  'if (baseline.proseOnlyCount < committed.proseOnlyCount) reasons.push("baseline-raised"); // MUTATION_BASELINE' \
  'baseline-raised' 'debtRatchet: ok' flip \
  --fixture "$FIX/fenced-status" --now "$NOW" --baseline "$ROOT/base-high.json" --committed-baseline "$ROOT/base-committed.json"

prove fall \
  'debtRatchet: "ok",
    debtReason: debtCount < baseline.proseOnlyCount ? "below-baseline" : "ok", // MUTATION_FALL' \
  'debtRatchet: "over",
    debtReason: debtCount < baseline.proseOnlyCount ? "below-baseline" : "ok", // MUTATION_FALL' \
  'debtRatchet: ok' 'debtRatchet: over' flip \
  --fixture "$FIX/fenced-status" --now "$NOW" --baseline "$BASE"

echo "lesson-ledger-freshness.test.sh: $PASS passed, $FAIL failed"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
