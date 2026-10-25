#!/usr/bin/env bash
# drain-ratchet.test.sh — fixtures + mutation teeth for scripts/drain-ratchet.mjs (#559)
#
# WHY
#   The ratchet is only trustworthy if a steady series stays quiet, two low
#   windows breach, the floor suppresses a quiet week, suspects come from the
#   process-change log, one recovery issue is opened/updated/closed (never two),
#   report-only never writes, and bad data fails closed. Each rule is also
#   broken on purpose in a copy of the sensor; the suite must go red.
#
# USAGE
#   scripts/tests/drain-ratchet.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
REAL_SENSOR="$REPO_ROOT/scripts/drain-ratchet.mjs"
CFG="$REPO_ROOT/config/drain-ratchet.v1.json"
NOW="2026-10-25T00:00:00Z"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "drain-ratchet.test.sh: node required"; exit 1; }
[[ -f "$REAL_SENSOR" ]] || { echo "drain-ratchet.test.sh: missing $REAL_SENSOR"; exit 1; }
[[ -f "$CFG" ]] || { echo "drain-ratchet.test.sh: missing $CFG"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-drain-ratchet.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Fixture generator: every scenario is a deterministic series of PRs and issues
# ending at NOW. t(d) is d days (and 12h) before NOW so items never sit on a
# window boundary.
cat >"$ROOT/gen.mjs" <<'EOF'
import { mkdirSync, writeFileSync } from "node:fs";
const [scenario, dir] = process.argv.slice(2);
const NOW = Date.parse("2026-10-25T00:00:00Z");
const D = 86_400_000;
const t = (d) => new Date(NOW - d * D - 12 * 3_600_000).toISOString();
const after = (iso, h) => new Date(Date.parse(iso) + h * 3_600_000).toISOString();
const pulls = [];
const issues = [];
let n = 100;
const pr = ({ d, merge = true, files = ["README.md"], author = "dev", hours = 2 }) => {
  const created = t(d);
  const end = after(created, hours);
  pulls.push({
    number: ++n, title: `change ${n}`, state: merge ? "closed" : "open", draft: false,
    created_at: created, closed_at: merge ? end : null, merged_at: merge ? end : null,
    user: { login: author }, html_url: `https://example.test/pull/${n}`, files,
  });
};
const issue = ({ d, close = true, title = `issue ${n + 1}`, labels = [], author = "dev", body = "" }) => {
  const created = t(d);
  issues.push({
    number: ++n, title, state: close ? "closed" : "open", created_at: created,
    closed_at: close ? after(created, 2) : null, user: { login: author },
    labels: labels.map((name) => ({ name })), html_url: `https://example.test/issues/${n}`, body,
  });
};
const days = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => from + i);

const steady = (from, to) => days(from, to).forEach((d) => { pr({ d }); issue({ d }); });
const stalled = (from, to) => days(from, to).forEach((d) => { pr({ d, merge: false }); issue({ d, close: false }); });

if (scenario === "steady") {
  steady(0, 55);
  pr({ d: 12, merge: false });
} else if (scenario === "freeze") {
  steady(28, 55);
  stalled(0, 27);
  issue({ d: 26, close: false, title: "FREEZE 2026-09-29: halt feature work", author: "alice" });
  pr({ d: 20, files: [".github/workflows/ci.yml"], author: "bob" });
  pr({ d: 21, files: ["docs/notes.md"], author: "dave" });
  pr({ d: 40, files: ["scripts/gate.sh"], author: "carol" });
} else if (scenario === "one-low") {
  steady(0, 13);
  stalled(14, 27);
  steady(28, 55);
} else if (scenario === "quiet") {
  steady(28, 55);
  for (let d = 0; d < 28; d += 3) issue({ d, close: false });
} else if (scenario === "recovered") {
  steady(0, 55);
  issue({
    d: 3, close: false, title: "Drain ratchet breach: 2026-10-20", author: "gibson-bot",
    body: "<!-- drain-ratchet -->\n- Breach first seen: 2026-10-20\n- Recovery deadline: 2026-10-27\n",
  });
} else if (scenario === "existing") {
  steady(28, 55);
  stalled(0, 27);
  issue({ d: 26, close: false, title: "FREEZE 2026-09-29: halt feature work", author: "alice" });
  issue({
    d: 2, close: false, title: "Drain ratchet breach: 2026-10-23", author: "gibson-bot",
    body: "<!-- drain-ratchet -->\n- Breach first seen: 2026-10-23\n- Recovery deadline: 2026-10-30\n",
  });
} else {
  throw new Error(`unknown scenario ${scenario}`);
}
mkdirSync(dir, { recursive: true });
writeFileSync(`${dir}/pulls.json`, JSON.stringify(pulls));
writeFileSync(`${dir}/issues.json`, JSON.stringify(issues));
EOF

for s in steady freeze one-low quiet recovered existing; do
  node "$ROOT/gen.mjs" "$s" "$ROOT/fx-$s" || { echo "drain-ratchet.test.sh: fixture $s failed"; exit 1; }
done

node -e '
const fs = require("fs");
const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
c.mode = "enforce";
fs.writeFileSync(process.argv[2], JSON.stringify(c));
c.mode = "bogus";
fs.writeFileSync(process.argv[3], JSON.stringify(c));
' "$CFG" "$ROOT/enforce.json" "$ROOT/bogus.json"

jget() { # jget FILE JS-EXPRESSION-OF-r
  node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(new Function("r", "return " + process.argv[2])(r)));' "$1" "$2"
}
expect() { # expect LABEL FILE EXPR WANT
  local got
  got=$(jget "$2" "$3")
  if [[ "$got" == "$4" ]]; then ok "$1"; else bad "$1 (got '$got', want '$4')"; fi
}

# run_sensor FIXTURE-NAME OUT-PREFIX [extra args...] — uses $S and $CONFIG
run_sensor() {
  local fx="$1" out="$2"
  shift 2
  node "$S" --fixture "$ROOT/fx-$fx" --now "$NOW" --config "$CONFIG" \
    --json-out "$ROOT/$out.json" "$@" >"$ROOT/$out.md" 2>"$ROOT/$out.err"
}

suite() {
  CONFIG="$CFG"

  echo "# CLI contract"
  help_out=$(node "$S" --help 2>/dev/null)
  help_rc=$?
  if [[ "$help_rc" -eq 0 ]] && [[ "$help_out" == *"WHAT IT DOES"* ]] && [[ "$help_out" == *"RISKS"* ]] \
     && [[ "$help_out" == *"EXIT"* ]]; then
    ok "--help exits 0 with Ask-Contract fields"
  else
    bad "--help (rc=$help_rc)"
  fi
  node "$S" >/dev/null 2>&1
  if [[ $? -eq 2 ]]; then ok "no source flag exits 2"; else bad "no source flag should exit 2"; fi
  node "$S" --fixture "$ROOT/fx-steady" --now "$NOW" --nope >/dev/null 2>&1
  if [[ $? -eq 2 ]]; then ok "unknown flag exits 2"; else bad "unknown flag should exit 2"; fi
  node "$REAL_SENSOR" --fixture "$ROOT/fx-steady" --now "$NOW" --config "$CFG" >/dev/null 2>&1
  real_rc=$?
  if [[ "$real_rc" -eq 0 ]]; then ok "shipped config validates"; else bad "shipped config rejected"; fi
  expect "shipped mode is report-only" "$CFG" "r.mode" "report-only"
  expect "shipped config carries margin, window count and floor" "$CFG" "[r.marginPct, r.consecutiveWindows, r.floorOpened].every(Number.isFinite)" "true"

  echo "# steady series: no breach"
  run_sensor steady steady
  expect "steady: exit 0" "$ROOT/steady.json" "r.schema" "gibson.drain-ratchet-report/v1"
  expect "steady: no breach" "$ROOT/steady.json" "r.breach" "false"
  expect "steady: both windows ok" "$ROOT/steady.json" "r.windows.map(w => w.status).join()" "ok,ok"
  expect "steady: drain rate is 28 drained over 29 opened" "$ROOT/steady.json" "r.windows[0].rate + '/' + r.windows[0].opened" "0.966/29"
  expect "steady: median open-to-merge is 2h" "$ROOT/steady.json" "r.windows[0].openToMergeHours.median" "2"
  expect "steady: one open PR older than 7 days" "$ROOT/steady.json" "r.openPrAge.count" "1"
  expect "steady: no recovery plan" "$ROOT/steady.json" "r.recovery" "null"

  echo "# freeze: breach after two consecutive low windows"
  run_sensor freeze freeze
  expect "freeze: breach" "$ROOT/freeze.json" "r.breach" "true"
  expect "freeze: both windows below" "$ROOT/freeze.json" "r.windows.map(w => w.status).join()" "below,below"
  expect "freeze: stalled PRs show as old open PRs" "$ROOT/freeze.json" "r.openPrAge.count >= 14" "true"

  echo "# one low window is not a breach"
  run_sensor one-low one-low
  expect "one low window: no breach" "$ROOT/one-low.json" "r.breach" "false"
  expect "one low window: statuses" "$ROOT/one-low.json" "r.windows.map(w => w.status).join()" "ok,below"

  echo "# floor suppresses a quiet-week breach"
  run_sensor quiet quiet
  expect "quiet: no breach" "$ROOT/quiet.json" "r.breach" "false"
  expect "quiet: floor named" "$ROOT/quiet.json" "r.windows.map(w => w.status).join()" "suppressed-floor,suppressed-floor"
  expect "quiet: would have breached without the floor" "$ROOT/quiet.json" "r.wouldBreachWithoutFloor" "true"

  echo "# suspects come from the process-change log"
  expect "suspects: freeze issue and workflow PR named" "$ROOT/freeze.json" "r.suspects.map(s => s.type + s.kinds.join('+')).sort().join()" "prworkflow,stopstop"
  expect "suspects: docs-only PR is not a process change" "$ROOT/freeze.json" "r.processChanges.some(c => c.author === 'dave')" "false"
  expect "suspects: change merged before the drop window is not a suspect" "$ROOT/freeze.json" "r.suspects.some(s => s.author === 'carol')" "false"
  expect "suspects: ... but is logged as a process change" "$ROOT/freeze.json" "r.processChanges.some(c => c.author === 'carol')" "true"
  expect "recovery owner is the author of the most recent suspect" "$ROOT/freeze.json" "r.recovery.owner" "bob"
  expect "recovery deadline is 7 days out" "$ROOT/freeze.json" "r.recovery.deadline" "2026-11-01"
  expect "default action lifts the open freeze" "$ROOT/freeze.json" "/^Lift stop #\\d+ and run a drain day/.test(r.recovery.defaultAction)" "true"

  echo "# report-only never opens an issue"
  run_sensor freeze ro --open-issue --actions-out "$ROOT/ro-actions.json"
  expect "report-only: breach still reported" "$ROOT/ro.json" "r.breach" "true"
  expect "report-only: create is planned" "$ROOT/ro.json" "r.plannedActions.map(a => a.op).join()" "create"
  expect "report-only: nothing applied" "$ROOT/ro.json" "r.applied.length" "0"
  if [[ ! -e "$ROOT/ro-actions.json" ]]; then ok "report-only: no actions file written"; else bad "report-only wrote an actions file"; fi
  if grep -F "report-only: nothing opened" "$ROOT/ro.md" >/dev/null; then ok "report-only: summary says so"; else bad "report-only summary"; fi

  echo "# enforce: exactly one issue"
  CONFIG="$ROOT/enforce.json"
  run_sensor freeze en1 --open-issue --actions-out "$ROOT/en1-actions.json"
  expect "enforce: first breach creates one issue" "$ROOT/en1-actions.json" "r.map(a => a.op).join()" "create"
  expect "enforce: title is dated" "$ROOT/en1-actions.json" "r[0].title" "Drain ratchet breach: 2026-10-25"
  expect "enforce: body carries owner, deadline, action" "$ROOT/en1-actions.json" "['@bob', 'Recovery deadline: 2026-11-01', 'Default action', 'FREEZE 2026-09-29'].every(x => r[0].body.includes(x))" "true"
  run_sensor existing en2 --open-issue --actions-out "$ROOT/en2-actions.json"
  expect "idempotent: an open issue is updated, never duplicated" "$ROOT/en2-actions.json" "r.map(a => a.op).join()" "update"
  expect "idempotent: the deadline set on first sight is kept" "$ROOT/en2-actions.json" "r[0].body.includes('Recovery deadline: 2026-10-30') && r[0].body.includes('Breach first seen: 2026-10-23')" "true"
  expect "idempotent: the ratchet's own issue is not counted as backlog" "$ROOT/en2.json" "r.windows[0].issuesOpened" "$(jget "$ROOT/freeze.json" "r.windows[0].issuesOpened")"
  run_sensor recovered en3 --open-issue --actions-out "$ROOT/en3-actions.json"
  expect "recovery: breach cleared closes the open issue" "$ROOT/en3-actions.json" "r.map(a => a.op).join()" "close"
  expect "recovery: no breach" "$ROOT/en3.json" "r.breach" "false"
  run_sensor steady en4 --open-issue --actions-out "$ROOT/en4-actions.json"
  expect "no breach and nothing open: no action" "$ROOT/en4-actions.json" "r.length" "0"
  CONFIG="$CFG"

  echo "# live path (stubbed gh): report-only never writes, enforce writes once"
  cat >"$ROOT/fake-gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$ROOT/gh-calls.log"
case "\$*" in
  *--method*) echo '{"number":999}' ;;
  *"/pulls?"*) cat "$ROOT/fx-freeze/pulls.json" ;;
  *"/files"*) echo '[]' ;;
  *"issues?state=all"*) cat "$ROOT/fx-freeze/issues.json" ;;
  *) echo '[]' ;;
esac
EOF
  chmod +x "$ROOT/fake-gh"
  : >"$ROOT/gh-calls.log"
  DRAIN_RATCHET_GH="$ROOT/fake-gh" node "$S" --repo o/r --now "$NOW" --config "$CFG" --open-issue \
    --json-out "$ROOT/live-ro.json" >/dev/null 2>"$ROOT/live-ro.err"
  expect "live report-only: breach found through gh" "$ROOT/live-ro.json" "r.breach" "true"
  if ! grep -F -- "--method" "$ROOT/gh-calls.log" >/dev/null; then ok "live report-only: zero writes"; else bad "live report-only wrote to GitHub"; fi
  : >"$ROOT/gh-calls.log"
  DRAIN_RATCHET_GH="$ROOT/fake-gh" node "$S" --repo o/r --now "$NOW" --config "$ROOT/enforce.json" --open-issue \
    --json-out "$ROOT/live-en.json" >/dev/null 2>"$ROOT/live-en.err"
  writes=$(grep -c -F -- "--method POST repos/o/r/issues" "$ROOT/gh-calls.log")
  if [[ "$writes" -eq 1 ]]; then ok "live enforce: exactly one issue POST"; else bad "live enforce posted $writes issues"; fi

  echo "# malformed input fails closed"
  for case_name in badjson missing-field no-issues bad-date unmerged-files; do
    rm -rf "${ROOT:?}/fx-$case_name"
    cp -R "$ROOT/fx-freeze" "$ROOT/fx-$case_name"
  done
  echo '{not json' >"$ROOT/fx-badjson/pulls.json"
  node -e 'const f = process.argv[1]; const fs = require("fs"); const p = JSON.parse(fs.readFileSync(f)); delete p[0].created_at; fs.writeFileSync(f, JSON.stringify(p));' "$ROOT/fx-missing-field/pulls.json"
  rm "$ROOT/fx-no-issues/issues.json"
  node -e 'const f = process.argv[1]; const fs = require("fs"); const p = JSON.parse(fs.readFileSync(f)); p[0].created_at = "yesterday"; fs.writeFileSync(f, JSON.stringify(p));' "$ROOT/fx-bad-date/pulls.json"
  node -e 'const f = process.argv[1]; const fs = require("fs"); const p = JSON.parse(fs.readFileSync(f)); delete p.find((x) => x.merged_at).files; fs.writeFileSync(f, JSON.stringify(p));' "$ROOT/fx-unmerged-files/pulls.json"
  check_fail() { # check_fail NAME FIXTURE WANT-IN-STDERR
    node "$S" --fixture "$ROOT/fx-$2" --now "$NOW" --config "$CFG" --json-out "$ROOT/mal-$2.json" >"$ROOT/mal-$2.out" 2>"$ROOT/mal-$2.err"
    rc=$?
    if [[ "$rc" -eq 1 ]] && grep -F "INCOMPLETE" "$ROOT/mal-$2.err" >/dev/null \
       && grep -F -- "$3" "$ROOT/mal-$2.err" >/dev/null \
       && [[ ! -e "$ROOT/mal-$2.json" ]] && ! grep -F "No breach" "$ROOT/mal-$2.out" >/dev/null; then
      ok "$1 fails closed with a clear error"
    else
      bad "$1 (rc=$rc, stderr: $(head -c 200 "$ROOT/mal-$2.err"))"
    fi
  }
  check_fail "invalid JSON" badjson "not valid JSON"
  check_fail "missing created_at" missing-field "created_at"
  check_fail "missing issues.json" no-issues "issues.json missing"
  check_fail "non-ISO timestamp" bad-date "not an ISO timestamp"
  check_fail "merged PR without files" unmerged-files "files missing"
  node "$S" --fixture "$ROOT/fx-steady" --now "$NOW" --config "$ROOT/bogus.json" >/dev/null 2>"$ROOT/mal-cfg.err"
  rc=$?
  if [[ "$rc" -eq 1 ]] && grep -F "config.mode" "$ROOT/mal-cfg.err" >/dev/null; then ok "bad config.mode fails closed"; else bad "bad config.mode (rc=$rc)"; fi
  DRAIN_RATCHET_GH=/bin/false node "$S" --repo o/r --now "$NOW" --config "$CFG" >/dev/null 2>"$ROOT/mal-gh.err"
  rc=$?
  if [[ "$rc" -eq 1 ]] && grep -F "INCOMPLETE" "$ROOT/mal-gh.err" >/dev/null; then ok "gh failure fails closed"; else bad "gh failure (rc=$rc)"; fi
}

S="${DRAIN_RATCHET_SENSOR_UNDER_TEST:-$REAL_SENSOR}"
suite
echo ""
echo "drain-ratchet.test.sh: $PASS passed, $FAIL failed"
if [[ -n "${DRAIN_RATCHET_SENSOR_UNDER_TEST:-}" ]]; then
  [[ "$FAIL" -eq 0 ]]
  exit
fi
REAL_FAIL=$FAIL

# --- mutation teeth ----------------------------------------------------------
# Each mutant breaks one rule in a copy of the sensor. The suite must fail on it.
echo "# mutation teeth"
MUTANTS=""
mutate() { # mutate NAME OLD NEW
  local dir="$ROOT/mut-$1"
  mkdir -p "$dir/scripts/lib" "$dir/config"
  cp "$REAL_SENSOR" "$dir/scripts/drain-ratchet.mjs"
  cp "$REPO_ROOT/scripts/lib/args.mjs" "$dir/scripts/lib/args.mjs"
  cp "$CFG" "$dir/config/"
  OLD="$2" NEW="$3" node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const s = fs.readFileSync(f, "utf8");
    if (!s.includes(process.env.OLD)) { console.error("mutation target not found"); process.exit(3); }
    fs.writeFileSync(f, s.replace(process.env.OLD, process.env.NEW));
  ' "$dir/scripts/drain-ratchet.mjs" || return 1
  # Mutants run concurrently (each runs the whole suite) to stay inside the pre-push time budget.
  DRAIN_RATCHET_SENSOR_UNDER_TEST="$dir/scripts/drain-ratchet.mjs" bash "${BASH_SOURCE[0]}" >"$dir/out.txt" 2>&1 &
  MUTANTS="$MUTANTS $1"
}
mutate one-window 'const breach = windows.every((w) => w.status === "below");' 'const breach = windows.some((w) => w.status === "below");'
mutate no-floor 'else if (!floorOk) status = "suppressed-floor";' 'else if (false) status = "suppressed-floor";'
mutate suspect-window 'Date.parse(c.date) >= Date.parse(dropStart)' 'Date.parse(c.date) >= 0'
mutate always-create 'if (existing.length === 0) {' 'if (true) {'
mutate no-auto-close 'for (const x of existing) ops.push({ op: "close", number: x.number, comment: `Breach cleared' 'for (const x of []) ops.push({ op: "close", number: x.number, comment: `Breach cleared'
mutate report-only-writes 'if (opt.openIssue && config.mode === "enforce") {' 'if (opt.openIssue) {'
mutate swallow-bad-date 'if (typeof v !== "string" || Number.isNaN(Date.parse(v))) {' 'if (false) {'
wait
for m in $MUTANTS; do
  mfail=$(tail -1 "$ROOT/mut-$m/out.txt" | sed -n 's/.*, \([0-9][0-9]*\) failed$/\1/p')
  if [[ "$mfail" =~ ^[0-9]+$ ]] && [[ "$mfail" -gt 0 ]]; then
    ok "mutant $m is caught ($mfail failures)"
  else
    bad "mutant $m survived (failures: '$mfail')"
  fi
done

echo ""
echo "drain-ratchet.test.sh: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 && "$REAL_FAIL" -eq 0 ]]; then
  exit 0
fi
exit 1
