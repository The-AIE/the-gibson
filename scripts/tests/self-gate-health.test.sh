#!/usr/bin/env bash
# self-gate-health.test.sh — false-red / feedback-time budget sensor (scripts/self-gate-health.mjs).
set -uo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT" || exit 1
PASS=0
FAIL=0
ok() { echo "  ok — $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $*"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/self-gate-health.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
SENSOR="scripts/self-gate-health.mjs"
CFG="config/self-gate-health.v1.json"

[[ -f "$SENSOR" ]] && ok "sensor present" || bad "missing $SENSOR"
[[ -f "$CFG" ]] && ok "config present" || bad "missing $CFG"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$CFG" >/dev/null 2>&1 \
  && ok "config is valid JSON" || bad "config is not valid JSON"

# --- fixture builder: gen N runs of (event, branch, conclusion, wall seconds)
gen_runs() {
  # args: repeated "event:branch:conclusion:wall"
  node -e '
    const specs = process.argv.slice(1);
    const runs = [];
    let id = 1000;
    for (const s of specs) {
      const [event, branch, conclusion, wall] = s.split(":");
      const start = new Date(Date.UTC(2026, 8, 1, 0, 0, 0) + id * 60000);
      const end = new Date(start.getTime() + Number(wall) * 1000);
      runs.push({
        id: id++,
        event,
        head_branch: branch,
        status: conclusion === "in_progress" ? "in_progress" : "completed",
        conclusion: conclusion === "in_progress" ? null : conclusion,
        run_started_at: start.toISOString(),
        created_at: start.toISOString(),
        updated_at: end.toISOString(),
      });
    }
    process.stdout.write(JSON.stringify({ workflow_runs: runs }));
  ' "$@"
}

rep() { # rep N spec
  local n="$1" spec="$2" i=0
  while [[ "$i" -lt "$n" ]]; do printf '%s\n' "$spec"; i=$((i + 1)); done
}

write_cfg() { # write_cfg path mainRed prRed prCancel wall minRuns
  cat >"$1" <<EOF
{ "workflowFile": "gibson-self-gate.yml", "windowRuns": 60, "minRuns": $6,
  "budgets": { "mainRedRate": $2, "prRedRate": $3, "prCancelledRate": $4, "medianGreenWallSeconds": $5 } }
EOF
}

run_sensor() { # run_sensor runs cfg -> sets OUT RC
  OUT=$(node "$SENSOR" --runs "$1" --config "$2" 2>&1)
  RC=$?
}

# 1. all green, fast -> OK
# shellcheck disable=SC2046
gen_runs $(rep 12 push:main:success:300) $(rep 12 pull_request:feat:success:300) >"$TMP/green.json"
write_cfg "$TMP/cfg.json" 0.05 0.30 0.25 900 10
run_sensor "$TMP/green.json" "$TMP/cfg.json"
[[ "$RC" -eq 0 ]] && ok "all-green window exits 0" || bad "all-green window rc=$RC: $OUT"
echo "$OUT" | grep "self-gate-health: OK" >/dev/null && ok "OK verdict line" || bad "missing OK verdict: $OUT"

# 2. main red rate over budget -> RED, named
# shellcheck disable=SC2046
gen_runs $(rep 10 push:main:success:300) $(rep 2 push:main:failure:300) $(rep 12 pull_request:feat:success:300) >"$TMP/mainred.json"
run_sensor "$TMP/mainred.json" "$TMP/cfg.json"
[[ "$RC" -eq 1 ]] && ok "main red 2/12 > 5% exits 1" || bad "main red rc=$RC: $OUT"
echo "$OUT" | grep "E_MAINREDRATE" >/dev/null && ok "names mainRedRate finding" || bad "no mainRedRate finding: $OUT"
echo "$OUT" | grep "ratchet loosening" >/dev/null && ok "loosening needs sign-off wording" || bad "missing sign-off wording"

# 3. PR cancellations over budget -> RED; timed_out counts as red
# shellcheck disable=SC2046
gen_runs $(rep 12 push:main:success:300) $(rep 6 pull_request:feat:success:300) $(rep 4 pull_request:feat:cancelled:30) $(rep 2 pull_request:feat:timed_out:1800) >"$TMP/prcancel.json"
run_sensor "$TMP/prcancel.json" "$TMP/cfg.json"
[[ "$RC" -eq 1 ]] && ok "pr cancelled 4/12 > 25% exits 1" || bad "pr cancel rc=$RC: $OUT"
echo "$OUT" | grep "E_PRCANCELLEDRATE" >/dev/null && ok "names prCancelledRate finding" || bad "no prCancelledRate finding: $OUT"
echo "$OUT" | grep "2/12 red" >/dev/null && ok "timed_out counted as red" || bad "timed_out not counted as red: $OUT"

# 4. slow green median over budget -> RED
# shellcheck disable=SC2046
gen_runs $(rep 12 push:main:success:1000) $(rep 12 pull_request:feat:success:1000) >"$TMP/slow.json"
run_sensor "$TMP/slow.json" "$TMP/cfg.json"
[[ "$RC" -eq 1 ]] && ok "median wall 1000s > 900s exits 1" || bad "slow rc=$RC: $OUT"
echo "$OUT" | grep "E_MEDIANGREENWALLSECONDS" >/dev/null && ok "names medianGreenWallSeconds finding" || bad "no wall finding: $OUT"

# 5. insufficient samples -> budget not applied, exit 0, and says so
# shellcheck disable=SC2046
gen_runs $(rep 3 push:main:failure:300) $(rep 12 pull_request:feat:success:300) >"$TMP/thin.json"
run_sensor "$TMP/thin.json" "$TMP/cfg.json"
[[ "$RC" -eq 0 ]] && ok "3 main runs < minRuns 10: budget not applied" || bad "thin rc=$RC: $OUT"
echo "$OUT" | grep "mainRedRate: 3 sample(s) < minRuns" >/dev/null && ok "insufficient-data note printed" || bad "no insufficient note: $OUT"

# 6. in-progress and non-main pushes are ignored; window cap respected
# shellcheck disable=SC2046
gen_runs $(rep 5 push:main:in_progress:0) $(rep 12 push:feature-x:failure:300) $(rep 12 push:main:success:300) $(rep 12 pull_request:feat:success:300) >"$TMP/mixed.json"
run_sensor "$TMP/mixed.json" "$TMP/cfg.json"
[[ "$RC" -eq 0 ]] && ok "in-progress and non-main push runs ignored" || bad "mixed rc=$RC: $OUT"
echo "$OUT" | grep "main: 0/12 red" >/dev/null && ok "main counts only main pushes" || bad "main count wrong: $OUT"

# 6b. order-independent: 70 old main reds listed FIRST, 60 newest green after;
#     the window must be the newest 60 by start time, not the first 60 lines.
# shellcheck disable=SC2046
gen_runs $(rep 70 push:main:failure:300) $(rep 30 push:main:success:300) $(rep 30 pull_request:feat:success:300) >"$TMP/shuffled.json"
run_sensor "$TMP/shuffled.json" "$TMP/cfg.json"
[[ "$RC" -eq 0 ]] && ok "window is newest-first by start time regardless of input order" || bad "shuffled rc=$RC: $OUT"
echo "$OUT" | grep "main: 0/30 red" >/dev/null && ok "old reds outside the window are not measured" || bad "stale window: $OUT"

# 7. malformed input / bad config / unknown flag -> exit 2
echo '{"nope":1}' >"$TMP/bad.json"
run_sensor "$TMP/bad.json" "$TMP/cfg.json"
[[ "$RC" -eq 2 ]] && ok "malformed runs exits 2" || bad "malformed rc=$RC: $OUT"
echo '{ "workflowFile": "x", "windowRuns": 60, "minRuns": 10, "budgets": { "mainRedRate": 2 } }' >"$TMP/badcfg.json"
run_sensor "$TMP/green.json" "$TMP/badcfg.json"
[[ "$RC" -eq 2 ]] && ok "out-of-range budget exits 2" || bad "badcfg rc=$RC: $OUT"
OUT=$(node "$SENSOR" --bogus 2>&1); RC=$?
[[ "$RC" -eq 2 ]] && ok "unknown flag exits 2" || bad "unknown flag rc=$RC"
OUT=$(node "$SENSOR" --runs "$TMP/green.json" --config "$TMP/cfg.json" --format json 2>&1); RC=$?
[[ "$RC" -eq 0 ]] && echo "$OUT" | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); if(j.ok!==true||j.metrics.main.runs!==12) process.exit(1)' \
  && ok "--format json is parseable with metrics" || bad "json format rc=$RC: $OUT"

# 8. shipped config is a ratchet the repo's own history can satisfy structurally
run_sensor "$TMP/green.json" "$CFG"
[[ "$RC" -eq 0 ]] && ok "shipped config accepts an all-green window" || bad "shipped config rc=$RC: $OUT"

# 9. wired into the daily workflow, fail-closed
WF=".github/workflows/sensor-health.yml"
grep -qE '^[[:space:]]*run:[[:space:]]+node[[:space:]]+scripts/self-gate-health\.mjs[[:space:]]*$' "$WF" \
  && ok "sensor-health.yml runs self-gate-health.mjs" || bad "$WF does not run self-gate-health.mjs"
grep -nE 'self-gate-health\.mjs.*\|\|[[:space:]]*true' "$WF" >/dev/null 2>&1 \
  && bad "self-gate-health step swallows failure" || ok "self-gate-health step not wrapped in || true"

echo "self-gate-health.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
