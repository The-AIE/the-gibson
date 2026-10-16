#!/usr/bin/env bash
# session-budget.test.sh — finite session allowance for loop.sh (issue #409).
#
# Throwaway repos and a fake hermes runner only. No live GitHub, curl, or model CLI.
# Budget stops are asserted through scripts/loop.sh and scripts/loop-fleet.sh.
# The allowance file is local state the same user can rewrite; these cases do
# not claim it is a security boundary. Wall checks are whole minutes at
# iteration boundaries, so a stop may overshoot. prs_merged stays "not measured"
# unless a ledger line says merged plus a positive pr. Official cost-ledger.sh
# rows carry no cost_usd and no session_id, so they do not add dollars.
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

unset GIBSON_MAX_ITERATIONS GIBSON_MAX_WALL_MIN GIBSON_MAX_COST_USD \
  GIBSON_LANE_ID GIBSON_SESSION_ID GIBSON_SESSION_ITERATION GIBSON_HALT \
  GIBSON_COST_LEDGER GIBSON_COST_TELEMETRY_REQUIRED GIBSON_COST_TOKENS \
  GIBSON_COST_ACUS GIBSON_COST_FLAT_RATE GIBSON_COST_JOIN_KEY \
  FLEET_WALL_TIMEOUT_TEST_PARENT_FALLBACK FLEET_WALL_TIMEOUT_TEST_PUBLISH \
  FLEET_PROFILE FLEET_DIR LOG_DIR || true

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GIBSON=$(cd "$SCRIPT_DIR/../.." && pwd)
LOOP="$GIBSON/scripts/loop.sh"
FLEET="$GIBSON/scripts/loop-fleet.sh"
LIB="$GIBSON/scripts/lib/session-budget.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v python3 >/dev/null || { echo "session-budget.test.sh: python3 is required"; exit 1; }
command -v git >/dev/null || { echo "session-budget.test.sh: git is required"; exit 1; }
command -v node >/dev/null || { echo "session-budget.test.sh: node is required"; exit 1; }
[[ -f "$LOOP" && -f "$FLEET" && -f "$LIB" ]] || { echo "session-budget.test.sh: missing loop/fleet/lib"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-session-budget.XXXXXX")
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"
CALLS="$ROOT/calls"
REPO="$ROOT/repo"
RUNNER="$CALLS/fake-runner.sh"
mkdir -p "$BIN" "$CALLS"

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl stub: live network forbidden" >&2
exit 55
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh stub: live network forbidden" >&2
exit 1
STUB
chmod +x "$BIN/curl" "$BIN/gh"
PATH="$BIN:$PATH"
export PATH
export DEVIN_API_BASE="http://127.0.0.1:9"
export GH_HOST="github.com"
unset DEVIN_API_KEY DEVIN_WEBHOOK_URL || true

GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

ALLOW="$REPO/gibson/session-budget.json"
JOURNAL="$REPO/gibson/journal.md"
LATCH="$REPO/gibson/session-budget-latch"
RC=0
USE_LEDGER=""
USE_LANE=""
unset USE_MAX_ITER_ENV USE_EMPTY_WALL || true

clear_hooks() {
  USE_LEDGER=""
  USE_LANE=""
  unset USE_MAX_ITER_ENV USE_EMPTY_WALL || true
}

setup_repo() {
  rm -rf "$REPO"
  mkdir -p "$REPO" "$CALLS"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  echo base > "$REPO/README.md"
  $GIT -C "$REPO" add README.md
  $GIT -C "$REPO" commit -q -m "base"
  git -C "$REPO" remote add origin https://github.com/acme/app.git
  mkdir -p "$REPO/gibson"
  cat > "$REPO/gibson/loop-state.md" <<'EOF'
# Gibson loop state
updated: 2026-01-01T00:00:00Z
issue:
pr:
hat: builder
next_hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: triage highest-priority unblocked unclaimed issue
notes: fixture
EOF
  : > "$CALLS/runner.count"
  echo progress > "$CALLS/mode"
  rm -f "$CALLS/seen-consumed" "$CALLS/done" "$CALLS/termed"
}

cat > "$RUNNER" <<RUN
#!/usr/bin/env bash
set -euo pipefail
echo call >> "$CALLS/runner.count"
n=\$(wc -l < "$CALLS/runner.count" | tr -d '[:space:]')
if [[ "\$n" -gt 4 ]]; then
  mkdir -p "$REPO/gibson"
  echo safety > "$REPO/gibson/HALT"
fi
mode=\$(cat "$CALLS/mode" 2>/dev/null || echo progress)
if [[ -f "$ALLOW" ]]; then
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("consumed_starts",""))' "$ALLOW" > "$CALLS/seen-consumed" || true
fi
sid="\${GIBSON_SESSION_ID:-}"
iter="\${GIBSON_SESSION_ITERATION:-}"
ledger="${USE_LEDGER_BAKED:-}"
write_cost() {
  local kind="\$1" amount="\$2" with_iter="\$3"
  [[ -n "\$ledger" ]] || return 0
  python3 - "\$ledger" "\$sid" "\$iter" "\$kind" "\$amount" "\$with_iter" <<'PY'
import json, sys
path, sid, iteration, kind, amount, with_iter = sys.argv[1:]
ev = {"schema": "gibson.cost.v1", "session_id": sid}
if kind == "flat":
    ev["flat_rate"] = True
    ev["tokens"] = 12
    ev["iteration"] = int(iteration)
elif kind == "cost":
    ev["cost_usd"] = amount
    if with_iter == "yes":
        ev["iteration"] = int(iteration)
elif kind == "cost-no-iter":
    ev["cost_usd"] = amount
else:
    sys.exit(0)
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(ev, separators=(",", ":")) + "\n")
PY
}
case "\$mode" in
  cost-20) write_cost cost 20 yes ;;
  cost-150) write_cost cost 1.50 yes ;;
  cost-zero) write_cost cost 0 yes ;;
  flat) write_cost flat 0 yes ;;
  fractional)
    if [[ "\$iter" == "1" ]]; then write_cost cost 0.10 yes
    elif [[ "\$iter" == "2" ]]; then write_cost cost 0.20 yes
    fi
    ;;
  partial-one)
    if [[ "\$iter" == "1" ]]; then write_cost cost 0.5 yes; fi
    ;;
  partial-over) write_cost cost-no-iter 2.5 no ;;
  sleep-term)
    trap 'echo TERM > "$CALLS/termed"' TERM
    sleep 0.2
    echo done > "$CALLS/done"
    ;;
  pause)
    printf '%s\n' "\$\$" > "$CALLS/runner.pid"
    : > "$CALLS/runner.ready"
    i=0
    while [[ ! -f "$CALLS/runner.release" && "\$i" -lt 200 ]]; do
      sleep 0.1
      i=\$((i + 1))
    done
    ;;
  wall-rewrite)
    python3 - "$ALLOW" <<'PY'
import json, sys
from datetime import datetime, timezone, timedelta
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["started_at"] = (datetime.now(timezone.utc) - timedelta(seconds=120)).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n")
PY
    echo done > "$CALLS/done"
    ;;
esac
now=\$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
cat > "$REPO/gibson/loop-state.md" <<EOF
# Gibson loop state
updated: \$now
issue: 409
pr:
hat: builder
next_hat: test-engineer
round: 1
parked: false
handoff:
handoff_sha:
next_action: run the session budget sensor
notes: progress-\$n
EOF
if [[ "\$mode" == "fail" ]]; then
  exit 1
fi
exit 0
RUN
chmod +x "$RUNNER"

# The runner script bakes USE_LEDGER at generation time. Regenerate the ledger
# path before each run by rewriting one assignment. The rest of the script is stable.
bake_ledger() {
  local led="${1:-}"
  python3 - "$RUNNER" "$led" <<'PY'
import sys
path, led = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines(True)
out = []
for line in lines:
    if line.startswith("ledger="):
        out.append("ledger=%s\n" % (repr(led)))
    else:
        out.append(line)
open(path, "w", encoding="utf-8").writelines(out)
PY
}

run_loop() {
  local log="$1"
  shift
  bake_ledger "$USE_LEDGER"
  (
    unset GIBSON_MAX_ITERATIONS GIBSON_MAX_WALL_MIN GIBSON_MAX_COST_USD
    unset GIBSON_LANE_ID GIBSON_SESSION_ID GIBSON_SESSION_ITERATION GIBSON_HALT
    unset GIBSON_COST_LEDGER GIBSON_COST_TELEMETRY_REQUIRED GIBSON_COST_TOKENS
    unset GIBSON_COST_ACUS GIBSON_COST_FLAT_RATE GIBSON_COST_JOIN_KEY
    unset FLEET_WALL_TIMEOUT_TEST_PARENT_FALLBACK FLEET_WALL_TIMEOUT_TEST_PUBLISH
    if [[ -n "$USE_LEDGER" ]]; then
      export GIBSON_COST_LEDGER="$USE_LEDGER"
    fi
    if [[ -n "$USE_LANE" ]]; then
      export GIBSON_LANE_ID="$USE_LANE"
    fi
    if [[ -n "${USE_MAX_ITER_ENV+x}" ]]; then
      export GIBSON_MAX_ITERATIONS="$USE_MAX_ITER_ENV"
    fi
    if [[ -n "${USE_EMPTY_WALL+x}" ]]; then
      GIBSON_MAX_WALL_MIN=""
      export GIBSON_MAX_WALL_MIN
    fi
    export HERMES_CMD="$RUNNER"
    "$LOOP" --runner hermes --repo "$REPO" --repo-slug acme/app --gibson "$GIBSON" \
      --error-budget 5 --stale-budget 5 "$@" >"$log.out" 2>"$log"
  )
  RC=$?
}

runner_count() {
  if [[ ! -f "$CALLS/runner.count" ]]; then
    printf '0\n'
    return 0
  fi
  wc -l < "$CALLS/runner.count" | tr -d '[:space:]'
}

count_in() {
  local file="$1" pat="$2" n
  if [[ ! -f "$file" ]]; then
    printf '0\n'
    return 0
  fi
  n=$(grep -c -F "$pat" "$file" || true)
  printf '%s\n' "${n:-0}"
}

allow_field() {
  python3 - "$ALLOW" "$1" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
val = doc[sys.argv[2]]
if isinstance(val, bool):
    sys.stdout.write("true" if val else "false")
else:
    sys.stdout.write(str(val))
PY
}

patch_allow() {
  python3 - "$ALLOW" "$@" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
for kv in sys.argv[2:]:
    key, val = kv.split("=", 1)
    if key in ("consumed_starts", "completed_iterations", "max_iterations", "max_wall_min", "runner_pid"):
        doc[key] = int(val)
    elif key == "unbounded":
        doc[key] = (val == "true")
    else:
        doc[key] = val
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

backdate_minutes() {
  python3 - "$ALLOW" "$1" <<'PY'
import json, sys
from datetime import datetime, timezone, timedelta
path, minutes = sys.argv[1], int(sys.argv[2])
doc = json.load(open(path, encoding="utf-8"))
doc["started_at"] = (datetime.now(timezone.utc) - timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

write_seed_allowance() {
  python3 - "$ALLOW" "$@" <<'PY'
import json, sys
path = sys.argv[1]
doc = {
    "schema": "gibson.session-budget.allowance.v1",
    "session_id": "sb-20261015T120000Z-abcdef12",
    "lane_id": "solo",
    "repo": "acme/app",
    "started_at": "2026-10-15T12:00:00Z",
    "max_iterations": 50,
    "max_wall_min": 480,
    "max_cost_usd": "20",
    "unbounded": False,
    "consumed_starts": 0,
    "completed_iterations": 0,
}
for kv in sys.argv[2:]:
    key, val = kv.split("=", 1)
    if key in ("consumed_starts", "completed_iterations", "max_iterations", "max_wall_min", "runner_pid"):
        doc[key] = int(val)
    elif key == "unbounded":
        doc[key] = (val == "true")
    else:
        doc[key] = val
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

# Operator reset through the sourced gate. The engine must journal and delete
# under its own lock. rc is the gate's status.
reset_gate() {
  local out="$1"
  (
    export STATE_DIR="$REPO/gibson"
    export JOURNAL="$JOURNAL"
    export EXPECTED_REPO_SLUG="acme/app"
    export GIBSON_LANE_ID="solo"
    export SB_LIMIT_ITERATIONS=50
    export SB_LIMIT_WALL_MIN=480
    export SB_LIMIT_COST_USD=20
    export SB_UNBOUNDED=0
    export SB_RESET=1
    unset GIBSON_COST_LEDGER || true
    unset SB_LOOP_PID || true
    # shellcheck disable=SC1090
    source "$LIB"
    info() { printf '%s\n' "$*" >&2; }
    sb_startup_gate
  ) >"$out.out" 2>"$out"
}

check_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    ok "$name"
  else
    bad "$name (got '$got' want '$want')"
  fi
}

check_rc() {
  local name="$1" want="$2"
  check_eq "$name" "$RC" "$want"
}

check_has() {
  local name="$1" file="$2" pat="$3"
  if [[ -f "$file" ]] && grep -F -q -- "$pat" "$file"; then
    ok "$name"
  else
    bad "$name (missing '$pat')"
  fi
}

check_lacks() {
  local name="$1" file="$2" pat="$3"
  if [[ -f "$file" ]] && grep -F -q -- "$pat" "$file"; then
    bad "$name (unexpected '$pat')"
  else
    ok "$name"
  fi
}

echo "syntax"
bash -n "$LOOP" && ok "bash -n loop.sh" || bad "bash -n loop.sh"
bash -n "$FLEET" && ok "bash -n loop-fleet.sh" || bad "bash -n loop-fleet.sh"
bash -n "$LIB" && ok "bash -n session-budget.sh" || bad "bash -n session-budget.sh"

echo "help and docs"
"$LOOP" --help >"$ROOT/help.out" 2>"$ROOT/help.err" || true
check_has "--help names --max-wall-min" "$ROOT/help.out" "--max-wall-min"
check_has "--help names --max-cost-usd" "$ROOT/help.out" "--max-cost-usd"
check_has "--help names --unbounded" "$ROOT/help.out" "--unbounded"
check_has "--help names --reset-session-budget" "$ROOT/help.out" "--reset-session-budget"
check_has "--help names the iteration default" "$ROOT/help.out" "default: 50"
check_has "--help names the wall default" "$ROOT/help.out" "default: 480"
check_has "--help names the cost default" "$ROOT/help.out" "default: 20"
check_has "--help names GIBSON_MAX_ITERATIONS" "$ROOT/help.out" "GIBSON_MAX_ITERATIONS"
check_has "--help says not measured" "$ROOT/help.out" "not measured"
check_has "--help says the check is not a runner kill" "$ROOT/help.out" "never by killing the runner"
check_has "docs/11 names the three defaults" "$GIBSON/docs/11-solo-loop.md" "50 iterations"
check_has "docs/11 names the opt-out" "$GIBSON/docs/11-solo-loop.md" "--unbounded"
check_has "docs/11 says not measured" "$GIBSON/docs/11-solo-loop.md" "cost: not measured"

echo "finite defaults are stored on a real run"
clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/default-once.err" --once
check_rc "no-flag --once exits 0" 0
check_eq "no-flag --once runs one runner" "$(runner_count)" 1
check_eq "stored max_iterations is 50" "$(allow_field max_iterations)" 50
check_eq "stored max_wall_min is 480" "$(allow_field max_wall_min)" 480
check_eq "stored max_cost_usd is 20" "$(allow_field max_cost_usd)" 20
check_eq "stored unbounded is false" "$(allow_field unbounded)" false
check_eq "stored lane is solo" "$(allow_field lane_id)" solo
check_eq "one start is consumed before the runner returns" "$(cat "$CALLS/seen-consumed")" 1
check_eq "no-flag --once does not budget-stop" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 0
SID=$(allow_field session_id)

echo "default iteration cap stops at the boundary and the latch stays quiet"
patch_allow consumed_starts=49 completed_iterations=49
: > "$CALLS/runner.count"
run_loop "$ROOT/default-50.err"
check_rc "50th start exits 0" 0
check_eq "50th start invokes the runner" "$(runner_count)" 1
check_has "50th start diagnosis is iterations" "$ROOT/default-50.err" "budget: iterations"
check_has "50th start keeps the legacy message" "$ROOT/default-50.err" "max iterations 50 reached"
check_eq "one iteration receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
check_has "receipt schema is on the journal line" "$JOURNAL" '"schema":"gibson.session-budget.v1"'
cp "$JOURNAL" "$ROOT/real-receipt.journal"
: > "$CALLS/runner.count"
run_loop "$ROOT/default-50-again.err"
check_rc "latched relaunch exits 0" 0
check_eq "latched relaunch does not start a runner" "$(runner_count)" 0
check_eq "latched relaunch does not append a second receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
check_eq "session id is unchanged across the latch" "$(allow_field session_id)" "$SID"

echo "default wall cap stops before the next runner"
clear_hooks
setup_repo
run_loop "$ROOT/wall-seed.err" --once
backdate_minutes 500
: > "$CALLS/runner.count"
run_loop "$ROOT/wall-default.err" --once
check_rc "default wall stop exits 0" 0
check_eq "default wall stop does not start a runner" "$(runner_count)" 0
check_has "default wall diagnosis" "$JOURNAL" "diagnosis: budget: wall"
over=$(awk -F': ' '/^wall_overshoot_seconds: /{v=$2} END{print v+0}' "$JOURNAL")
if [[ "$over" -ge 60 ]]; then
  ok "default wall stop records overshoot ($over s)"
else
  bad "default wall overshoot want >= 60 got '$over'"
fi

echo "default cost cap stops on measured cost_usd"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-default.jsonl"
: > "$USE_LEDGER"
echo cost-20 > "$CALLS/mode"
run_loop "$ROOT/cost-default.err" --once
check_rc "default cost stop exits 0" 0
check_eq "default cost stop ran the in-flight runner" "$(runner_count)" 1
check_has "default cost diagnosis" "$JOURNAL" "diagnosis: budget: cost"
# Replaced "default cost receipt is complete". One cost_usd event is not
# positive evidence that the session spend is complete (owner amendment
# 2026-10-04). The #74 ledger has no session-closed marker.
check_has "default cost receipt stays partial" "$JOURNAL" "cost_status: partial"
check_lacks "default cost receipt is not complete" "$JOURNAL" "cost_status: complete"
check_has "default cost receipt names the dollars" "$JOURNAL" '"cost_usd":"20"'
check_has "default cost receipt says the measurement is incomplete" "$JOURNAL" "not every iteration measured"
if grep -qx 'cost: partial 20' "$JOURNAL"; then
  ok "default cost receipt keeps the partial amount"
else
  bad "default cost receipt did not say cost: partial 20"
fi

echo "per-budget values and flag-over-env"
clear_hooks
setup_repo
USE_MAX_ITER_ENV=4
run_loop "$ROOT/iter-2.err" --max-iterations 2
check_rc "max-iterations 2 exits 0" 0
check_eq "max-iterations 2 runs two runners" "$(runner_count)" 2
check_has "max-iterations 2 legacy message" "$ROOT/iter-2.err" "max iterations 2 reached"
check_has "max-iterations 2 diagnosis" "$JOURNAL" "diagnosis: budget: iterations"
unset USE_MAX_ITER_ENV || true

clear_hooks
setup_repo
run_loop "$ROOT/wall-1-seed.err" --once --max-wall-min 1
backdate_minutes 2
: > "$CALLS/runner.count"
run_loop "$ROOT/wall-1.err" --once --max-wall-min 1
check_rc "max-wall-min 1 relaunch exits 0" 0
check_eq "max-wall-min 1 does not start the next runner" "$(runner_count)" 0
check_has "max-wall-min 1 diagnosis" "$JOURNAL" "diagnosis: budget: wall"

clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-150.jsonl"
: > "$USE_LEDGER"
echo cost-150 > "$CALLS/mode"
run_loop "$ROOT/cost-150.err" --once --max-cost-usd 1
check_rc "max-cost-usd 1 exits 0" 0
check_eq "max-cost-usd 1 ran one runner" "$(runner_count)" 1
check_has "max-cost-usd 1 diagnosis" "$JOURNAL" "diagnosis: budget: cost"
check_has "fractional measured total is exact" "$JOURNAL" '"cost_usd":"1.5"'

echo "unmeasured cost is not zero and does not stop the session"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-flat.jsonl"
: > "$USE_LEDGER"
echo flat > "$CALLS/mode"
run_loop "$ROOT/flat.err" --max-iterations 2 --max-cost-usd 1
check_rc "unmeasured cost still exits 0 on iterations" 0
check_eq "unmeasured cost runs both iterations" "$(runner_count)" 2
check_has "unmeasured stop is iterations" "$JOURNAL" "diagnosis: budget: iterations"
if grep -qx 'cost: not measured' "$JOURNAL"; then
  ok "receipt says cost: not measured"
else
  bad "receipt missing exact cost: not measured line"
fi
check_has "unmeasured cost_status" "$JOURNAL" "cost_status: not_measured"
check_lacks "unmeasured is not stored as cost: 0" "$JOURNAL" "cost_status: complete"

echo "fractional sum stays exact and partial under the cap"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-frac.jsonl"
: > "$USE_LEDGER"
echo fractional > "$CALLS/mode"
run_loop "$ROOT/frac.err" --max-iterations 2 --max-cost-usd 1
check_rc "fractional sum exits 0" 0
check_eq "fractional sum runs both iterations" "$(runner_count)" 2
check_has "fractional stop is iterations" "$JOURNAL" "diagnosis: budget: iterations"
if grep -qx 'cost: partial 0.3' "$JOURNAL"; then
  ok "0.10+0.20 prints as cost: partial 0.3"
else
  bad "fractional total was not cost: partial 0.3"
fi
check_has "fractional cost_status stays partial" "$JOURNAL" "cost_status: partial"
check_lacks "fractional coverage is not complete" "$JOURNAL" "cost_status: complete"
check_has "fractional json strips the trailing zero" "$JOURNAL" '"cost_usd":"0.3"'

echo "partial cost stays partial, and partial over the cap stops"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-partial.jsonl"
: > "$USE_LEDGER"
echo partial-one > "$CALLS/mode"
run_loop "$ROOT/partial.err" --max-iterations 2 --max-cost-usd 20
check_rc "partial under cap exits 0" 0
check_eq "partial under cap runs both iterations" "$(runner_count)" 2
check_has "partial under cap stops on iterations" "$JOURNAL" "diagnosis: budget: iterations"
check_has "partial status" "$JOURNAL" "cost_status: partial"
check_has "partial says not every iteration measured" "$JOURNAL" "not every iteration measured"
if grep -qx 'cost: partial 0.5' "$JOURNAL"; then
  ok "partial wording names the measured subset"
else
  bad "missing exact cost: partial 0.5 line"
fi

clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-partial-over.jsonl"
: > "$USE_LEDGER"
echo partial-over > "$CALLS/mode"
run_loop "$ROOT/partial-over.err" --max-iterations 5 --max-cost-usd 1
check_rc "partial over cap exits 0" 0
check_eq "partial over cap does not start a second runner" "$(runner_count)" 1
check_has "partial over cap stops on cost" "$JOURNAL" "diagnosis: budget: cost"
if grep -qx 'cost: partial 2.5' "$JOURNAL"; then
  ok "partial over cap keeps the partial wording"
else
  bad "partial over cap dropped the partial wording"
fi

echo "other sessions and an explicit zero"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-other.jsonl"
python3 - "$USE_LEDGER" <<'PY'
import json, sys
ev = {"schema": "gibson.cost.v1", "session_id": "sb-20260101T000000Z-deadbeef", "cost_usd": "100", "iteration": 1}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(ev) + "\n")
PY
echo progress > "$CALLS/mode"
run_loop "$ROOT/other.err" --max-iterations 2 --max-cost-usd 1
check_rc "foreign session dollars do not fail the loop" 0
check_eq "foreign session dollars do not skip a runner" "$(runner_count)" 2
check_has "foreign dollars leave this session unmeasured" "$JOURNAL" "cost_status: not_measured"
check_has "foreign dollars stop on iterations" "$JOURNAL" "diagnosis: budget: iterations"

clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-zero.jsonl"
: > "$USE_LEDGER"
echo cost-zero > "$CALLS/mode"
run_loop "$ROOT/zero.err" --max-iterations 1
check_rc "explicit zero cost exits 0" 0
check_has "explicit zero is measured" "$JOURNAL" "cost_status: partial"
check_lacks "explicit zero is not complete session spend" "$JOURNAL" "cost_status: complete"
if grep -qx 'cost: partial 0' "$JOURNAL"; then
  ok "explicit zero prints cost: partial 0"
else
  bad "explicit zero did not print cost: partial 0"
fi
check_lacks "explicit zero is not not-measured" "$JOURNAL" "cost: not measured"
check_has "explicit zero still stops on iterations" "$JOURNAL" "diagnosis: budget: iterations"

echo "bad cost_usd fails closed"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-bad.jsonl"
: > "$USE_LEDGER"
echo progress > "$CALLS/mode"
run_loop "$ROOT/bad-seed.err" --once --max-iterations 5
check_rc "seed before bad cost exits 0" 0
SID=$(allow_field session_id)
python3 - "$USE_LEDGER" "$SID" <<'PY'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
ev = {"schema": "gibson.cost.v1", "session_id": sid, "cost_usd": 1.5, "iteration": 1}
open(path, "a", encoding="utf-8").write(json.dumps(ev) + "\n")
PY
: > "$CALLS/runner.count"
run_loop "$ROOT/bad-cost.err" --once --max-iterations 5
check_rc "numeric cost_usd exits 1" 1
check_eq "numeric cost_usd does not start a runner" "$(runner_count)" 0
check_has "numeric cost_usd names the type" "$ROOT/bad-cost.err" "cost_usd must be a decimal string"
check_lacks "numeric cost_usd is not a clean once" "$ROOT/bad-cost.err" "--once done"

echo "cross-lane and limit mismatch refuse without a fresh allowance"
clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/lane-seed.err" --once
SID=$(allow_field session_id)
: > "$CALLS/runner.count"
USE_LANE=other
run_loop "$ROOT/lane-other.err" --once
check_rc "other lane exits 1" 1
check_eq "other lane does not start a runner" "$(runner_count)" 0
check_eq "other lane does not replace the session" "$(allow_field session_id)" "$SID"
check_has "other lane says it does not cross-charge" "$ROOT/lane-other.err" "Resumed identities do not cross-charge"
check_has "other lane journals the refusal" "$JOURNAL" "session-budget-refused"
USE_LANE=""
: > "$CALLS/runner.count"
run_loop "$ROOT/limit-mismatch.err" --once --max-iterations 3
check_rc "changed limits exit 1" 1
check_eq "changed limits do not start a runner" "$(runner_count)" 0
check_has "changed limits name the persisted allowance" "$ROOT/limit-mismatch.err" "differ from the persisted"
check_eq "changed limits keep the session" "$(allow_field session_id)" "$SID"

echo "invalid values use the stale-budget rule; 0 and --unbounded opt out"
clear_hooks
setup_repo
for raw in 01 -1 foo 1.5 2147483648; do
  run_loop "$ROOT/bad-iter.err" --max-iterations "$raw" --once
  check_rc "reject --max-iterations $raw" 1
  check_has "reject message for $raw" "$ROOT/bad-iter.err" "positive safe decimal integer"
  check_has "reject message offers 0 for $raw" "$ROOT/bad-iter.err" "0 to opt out"
  if [[ -e "$ALLOW" ]]; then
    bad "invalid --max-iterations $raw created an allowance"
  else
    ok "invalid --max-iterations $raw created no allowance"
  fi
done
USE_EMPTY_WALL=1
run_loop "$ROOT/bad-empty.err" --once
check_rc "empty GIBSON_MAX_WALL_MIN exits 1" 1
check_has "empty wall env is rejected" "$ROOT/bad-empty.err" "invalid --max-wall-min"
unset USE_EMPTY_WALL || true
if [[ -e "$ALLOW" ]]; then
  bad "empty wall env created an allowance"
else
  ok "empty wall env created no allowance"
fi

clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/opt-1.err" --once --max-iterations 0
run_loop "$ROOT/opt-2.err" --once --max-iterations 0
run_loop "$ROOT/opt-3.err" --once --max-iterations 0
check_rc "iteration opt-out third once exits 0" 0
check_eq "iteration opt-out runs three times" "$(runner_count)" 3
check_eq "iteration opt-out keeps one session's consumed starts" "$(allow_field consumed_starts)" 3
check_has "iteration opt-out is journaled" "$JOURNAL" "dimensions: iterations"
check_eq "iteration opt-out does not budget-stop" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 0

clear_hooks
setup_repo
run_loop "$ROOT/unb-1.err" --once --unbounded
run_loop "$ROOT/unb-2.err" --once --unbounded
run_loop "$ROOT/unb-3.err" --once --unbounded
check_rc "unbounded third once exits 0" 0
check_eq "unbounded runs three times" "$(runner_count)" 3
check_eq "unbounded consumed starts are 3" "$(allow_field consumed_starts)" 3
check_eq "unbounded flag is stored" "$(allow_field unbounded)" true
check_has "unbounded opt-out journals all" "$JOURNAL" "dimensions: all"
SID=$(allow_field session_id)
run_loop "$ROOT/unb-conflict.err" --unbounded --max-iterations 1 --once
check_rc "unbounded plus a cap exits 1" 1
check_has "unbounded conflict names the flags" "$ROOT/unb-conflict.err" "cannot be combined"
check_eq "unbounded conflict does not replace the session" "$(allow_field session_id)" "$SID"

echo "simultaneous exhaustion prefers iterations, then wall, then cost"
clear_hooks
setup_repo
write_seed_allowance max_iterations=1 max_wall_min=1 max_cost_usd=1 consumed_starts=1 completed_iterations=1 started_at=2020-01-01T00:00:00Z
USE_LEDGER="$ROOT/cost-all.jsonl"
python3 - "$USE_LEDGER" <<'PY'
import json, sys
ev = {"schema": "gibson.cost.v1", "session_id": "sb-20261015T120000Z-abcdef12", "cost_usd": "5", "iteration": 1}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(ev) + "\n")
PY
run_loop "$ROOT/precedence.err" --once --max-iterations 1 --max-wall-min 1 --max-cost-usd 1
check_rc "simultaneous stop exits 0" 0
check_eq "simultaneous stop does not start a runner" "$(runner_count)" 0
check_has "simultaneous diagnosis is iterations" "$JOURNAL" "diagnosis: budget: iterations"
check_lacks "simultaneous diagnosis is not wall" "$JOURNAL" "diagnosis: budget: wall"
check_lacks "simultaneous diagnosis is not cost" "$JOURNAL" "diagnosis: budget: cost"

echo "halt and error-budget win before a budget receipt"
clear_hooks
setup_repo
write_seed_allowance max_iterations=1 consumed_starts=1 completed_iterations=0
echo halt > "$REPO/gibson/HALT"
run_loop "$ROOT/halt.err" --once --max-iterations 1
check_rc "halt exits 0" 0
check_eq "halt does not start a runner" "$(runner_count)" 0
check_has "halt keeps its own message" "$ROOT/halt.err" "kill switch set — stopping cleanly"
check_eq "halt writes no budget receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 0
check_eq "halt leaves the interrupted completion at 0" "$(allow_field completed_iterations)" 0

clear_hooks
setup_repo
echo fail > "$CALLS/mode"
run_loop "$ROOT/errbud.err" --max-iterations 1 --error-budget 1
check_rc "error budget exits 1" 1
check_eq "error budget ran the runner" "$(runner_count)" 1
check_has "error budget keeps its own message" "$ROOT/errbud.err" "error budget exhausted"
check_eq "error budget writes no budget receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 0
check_eq "error budget still consumed the start" "$(allow_field consumed_starts)" 1

echo "an interrupted reservation stays consumed"
clear_hooks
setup_repo
write_seed_allowance max_iterations=1 consumed_starts=1 completed_iterations=0
run_loop "$ROOT/interrupted.err" --once --max-iterations 1
check_rc "interrupted reservation exits 0" 0
check_eq "interrupted reservation does not start a runner" "$(runner_count)" 0
check_eq "interrupted completion stays 0" "$(allow_field completed_iterations)" 0
check_has "interrupted reservation stops on iterations" "$JOURNAL" "diagnosis: budget: iterations"

echo "the runner is not killed for the session budget"
clear_hooks
setup_repo
echo sleep-term > "$CALLS/mode"
run_loop "$ROOT/nokill.err" --max-iterations 1
check_rc "in-runner iteration cap exits 0" 0
check_eq "in-runner iteration cap ran once" "$(runner_count)" 1
[[ -f "$CALLS/done" ]] && ok "runner finished and wrote done" || bad "runner did not finish"
[[ -e "$CALLS/termed" ]] && bad "runner received TERM" || ok "runner did not receive TERM"
check_has "in-runner cap still stops after return" "$JOURNAL" "diagnosis: budget: iterations"

clear_hooks
setup_repo
echo wall-rewrite > "$CALLS/mode"
run_loop "$ROOT/wall-in.err" --max-wall-min 1 --max-iterations 5
check_rc "in-runner wall cap exits 0" 0
check_eq "in-runner wall cap ran once" "$(runner_count)" 1
[[ -f "$CALLS/done" ]] && ok "wall-cap runner finished" || bad "wall-cap runner did not finish"
check_has "in-runner wall diagnosis" "$JOURNAL" "diagnosis: budget: wall"
over=$(awk -F': ' '/^wall_overshoot_seconds: /{v=$2} END{print v+0}' "$JOURNAL")
if [[ "$over" -ge 30 ]]; then
  ok "in-runner wall stop overshoots ($over s)"
else
  bad "in-runner wall overshoot want >= 30 got '$over'"
fi

echo "reset, dry-run, and an unreadable ledger"
clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/reset-seed.err" --max-iterations 1
SID=$(allow_field session_id)
check_eq "pre-reset receipt exists" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
run_loop "$ROOT/reset.err" --reset-session-budget --once --max-iterations 1
check_rc "reset run exits 0" 0
check_eq "reset run starts the runner" "$(runner_count)" 2
check_has "reset is journaled" "$JOURNAL" "session-budget-reset"
if [[ "$(allow_field session_id)" != "$SID" ]]; then
  ok "reset creates a new session id"
else
  bad "reset kept session $SID"
fi

clear_hooks
setup_repo
run_loop "$ROOT/dry.err" --dry-run --once
check_rc "dry-run exits 0" 0
check_eq "dry-run does not start a runner" "$(runner_count)" 0
[[ -e "$ALLOW" ]] && bad "dry-run created an allowance" || ok "dry-run creates no allowance"
run_loop "$ROOT/print.err" --print-prompt --once
check_rc "print-prompt exits 0" 0
[[ -e "$ALLOW" ]] && bad "print-prompt created an allowance" || ok "print-prompt creates no allowance"
run_loop "$ROOT/reset-dry.err" --reset-session-budget --dry-run --once
check_rc "reset plus dry-run exits 1" 1
check_has "reset plus dry-run is refused" "$ROOT/reset-dry.err" "cannot be combined with --dry-run"

clear_hooks
setup_repo
USE_LEDGER="$ROOT/ledger-link.jsonl"
echo '{}' > "$ROOT/ledger-target.jsonl"
ln -s "$ROOT/ledger-target.jsonl" "$USE_LEDGER"
echo progress > "$CALLS/mode"
run_loop "$ROOT/unread-1.err" --once --max-iterations 2
check_rc "symlink ledger exits 1" 1
check_eq "symlink ledger does not start a runner" "$(runner_count)" 0
check_has "symlink ledger diagnosis" "$JOURNAL" "diagnosis: budget: cost-ledger-unreadable"
[[ -e "$ALLOW" ]] && bad "symlink ledger granted an allowance" || ok "symlink ledger grants no allowance"
[[ -f "$LATCH" ]] && ok "symlink ledger writes a latch" || bad "symlink ledger wrote no latch"
check_has "unreadable latch records kind" "$LATCH" "kind=unreadable"
check_has "unreadable latch records the reason" "$LATCH" "reason=cost-ledger-unreadable"
check_has "unreadable latch is journaled" "$LATCH" "journaled=1"
run_loop "$ROOT/unread-2.err" --once --max-iterations 2
check_rc "second unreadable launch exits 1" 1
check_eq "second unreadable launch adds no diagnosis" "$(count_in "$JOURNAL" 'diagnosis: budget: cost-ledger-unreadable')" 1
[[ -e "$ALLOW" ]] && bad "second unreadable launch granted an allowance" || ok "second unreadable launch grants no allowance"
rm -f "$USE_LEDGER"
: > "$USE_LEDGER"
: > "$CALLS/runner.count"
run_loop "$ROOT/unread-3.err" --once --max-iterations 2
check_rc "readable ledger after the latch exits 0" 0
check_eq "readable ledger after the latch starts a runner" "$(runner_count)" 1
[[ -f "$ALLOW" ]] && ok "recovery creates a fresh allowance" || bad "recovery created no allowance"

echo "fleet rollup"
clear_hooks
FLEET_REPO="$ROOT/fleet-repo"
mkdir -p "$FLEET_REPO"
$GIT init -q "$FLEET_REPO"
git -C "$FLEET_REPO" symbolic-ref HEAD refs/heads/main
echo app > "$FLEET_REPO/README.md"
$GIT -C "$FLEET_REPO" add README.md
$GIT -C "$FLEET_REPO" commit -q -m "base"
git -C "$FLEET_REPO" remote add origin https://github.com/acme/app.git
FLEET_DIR_P="$ROOT/fleet"
LOG_DIR_P="$ROOT/fleet-logs"
mkdir -p "$FLEET_DIR_P" "$LOG_DIR_P" "$ROOT/profiles"
PROF="$ROOT/profiles/sbtest.profile"
REPO_CANON=$(CDPATH='' cd "$FLEET_REPO" && pwd -P)
GIBSON_CANON=$(CDPATH='' cd "$GIBSON" && pwd -P)
cat > "$PROF" <<EOF
version=1
name=sbtest
repo=$REPO_CANON
slug=acme/app
gibson=$GIBSON_CANON
fleet_dir=$FLEET_DIR_P
log_dir=$LOG_DIR_P
runner=hermes
lane=docs|409|docs/**|session budget
EOF
PROF_CANON=$(CDPATH='' cd "$(dirname "$PROF")" && pwd -P)/$(basename "$PROF")
(
  unset FLEET_PROFILE FLEET_DIR LOG_DIR GIBSON_LANE_ID
  "$FLEET" --profile "$PROF" --status >"$ROOT/fleet-none.out" 2>"$ROOT/fleet-none.err"
) && fleet_rc=0 || fleet_rc=$?
check_eq "status with no journal exits 0" "$fleet_rc" 0
check_has "missing journal is receipt=none" "$ROOT/fleet-none.out" "session-budget lane=docs receipt=none"

mkdir -p "$FLEET_DIR_P/lane-docs/gibson"
cat > "$FLEET_DIR_P/.fleet-identity" <<EOF
name=sbtest
profile_path=$PROF_CANON
repo=$REPO_CANON
slug=acme/app
EOF
cp "$FLEET_DIR_P/.fleet-identity" "$LOG_DIR_P/.fleet-identity"
cat > "$FLEET_DIR_P/lane-docs/.fleet-identity" <<EOF
name=sbtest
profile_path=$PROF_CANON
repo=$REPO_CANON
slug=acme/app
lane=docs
EOF
cp "$ROOT/real-receipt.journal" "$FLEET_DIR_P/lane-docs/gibson/journal.md"
(
  unset FLEET_PROFILE FLEET_DIR LOG_DIR GIBSON_LANE_ID
  "$FLEET" --profile "$PROF" --status >"$ROOT/fleet-real.out" 2>"$ROOT/fleet-real.err"
) && fleet_rc=0 || fleet_rc=$?
check_eq "status with a real receipt exits 0" "$fleet_rc" 0
check_has "rollup names the lane" "$ROOT/fleet-real.out" "session-budget lane=docs"
check_has "rollup keeps the receipt lane" "$ROOT/fleet-real.out" "receipt_lane=solo"
check_has "rollup names the diagnosis" "$ROOT/fleet-real.out" "diagnosis=budget: iterations"
check_has "rollup names not-measured or a cost status" "$ROOT/fleet-real.out" "cost_status="

ln -sfn "$ROOT/real-receipt.journal" "$FLEET_DIR_P/lane-docs/gibson/journal.md"
(
  unset FLEET_PROFILE FLEET_DIR LOG_DIR GIBSON_LANE_ID
  "$FLEET" --profile "$PROF" --status >"$ROOT/fleet-link.out" 2>"$ROOT/fleet-link.err"
) && fleet_rc=0 || fleet_rc=$?
check_eq "symlink journal status exits 0" "$fleet_rc" 0
check_has "symlink journal is unreadable" "$ROOT/fleet-link.out" "session-budget lane=docs receipt=unreadable"

printf '%s\n' 'not-json "schema":"gibson.session-budget.v1"' > "$FLEET_DIR_P/lane-docs/gibson/journal.md"
(
  unset FLEET_PROFILE FLEET_DIR LOG_DIR GIBSON_LANE_ID
  "$FLEET" --profile "$PROF" --status >"$ROOT/fleet-bad.out" 2>"$ROOT/fleet-bad.err"
) && fleet_rc=0 || fleet_rc=$?
check_eq "bad receipt status exits 0" "$fleet_rc" 0
check_has "bad receipt is unreadable" "$ROOT/fleet-bad.out" "session-budget lane=docs receipt=unreadable"

rm -f "$FLEET_DIR_P/lane-docs/gibson/journal.md"
# shellcheck disable=SC1090,SC1091
source "$LIB"
direct=$(sb_format_rollup "$FLEET_DIR_P/lane-docs/gibson/journal.md" docs)
check_eq "direct rollup of a missing journal is none" "$direct" "session-budget lane=docs receipt=none"

mkdir -p "$FLEET_DIR_P/lane-docs/gibson/journal.md"
(
  unset FLEET_PROFILE FLEET_DIR LOG_DIR GIBSON_LANE_ID
  "$FLEET" --profile "$PROF" --status >"$ROOT/fleet-dir.out" 2>"$ROOT/fleet-dir.err"
) && fleet_rc=0 || fleet_rc=$?
check_eq "directory journal status exits 0" "$fleet_rc" 0
check_has "directory journal status is unreadable" "$ROOT/fleet-dir.out" "session-budget lane=docs receipt=unreadable"
check_lacks "directory journal status is not missing" "$ROOT/fleet-dir.out" "session-budget lane=docs receipt=none"
direct=$(sb_format_rollup "$FLEET_DIR_P/lane-docs/gibson/journal.md" docs)
rmdir "$FLEET_DIR_P/lane-docs/gibson/journal.md"
check_eq "direct rollup of a directory journal is unreadable" "$direct" "session-budget lane=docs receipt=unreadable"

echo "one USD event over one completed iteration stays partial"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-one-event.jsonl"
: > "$USE_LEDGER"
echo cost-150 > "$CALLS/mode"
run_loop "$ROOT/one-event.err" --max-iterations 1 --max-cost-usd 20
check_rc "one USD event exits 0" 0
check_eq "one USD event ran the iteration" "$(runner_count)" 1
check_has "one USD event stops on iterations" "$JOURNAL" "diagnosis: budget: iterations"
check_has "one USD event is partial" "$JOURNAL" "cost_status: partial"
check_lacks "one USD event is not complete" "$JOURNAL" "cost_status: complete"
check_has "one USD event sums the row" "$JOURNAL" '"cost_usd":"1.5"'
check_has "one USD event says not every iteration measured" "$JOURNAL" "not every iteration measured"
if grep -qx 'cost: partial 1.5' "$JOURNAL"; then
  ok "one USD event prints cost: partial 1.5"
else
  bad "one USD event did not print cost: partial 1.5"
fi

echo "two iterations with one USD row stay partial"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-two-one.jsonl"
: > "$USE_LEDGER"
echo partial-one > "$CALLS/mode"
run_loop "$ROOT/two-one.err" --max-iterations 2 --max-cost-usd 20
check_rc "two iterations one USD row exits 0" 0
check_eq "two iterations one USD row runs both" "$(runner_count)" 2
check_has "two iterations one USD row is partial" "$JOURNAL" "cost_status: partial"
check_lacks "two iterations one USD row is not complete" "$JOURNAL" "cost_status: complete"
if grep -qx 'cost: partial 0.5' "$JOURNAL"; then
  ok "two iterations one USD row prints cost: partial 0.5"
else
  bad "two iterations one USD row did not print cost: partial 0.5"
fi
check_has "two iterations one USD row says not every iteration measured" "$JOURNAL" "not every iteration measured"

echo "no cost events stay not measured"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-empty.jsonl"
: > "$USE_LEDGER"
echo progress > "$CALLS/mode"
run_loop "$ROOT/no-events.err" --max-iterations 1 --max-cost-usd 1
check_rc "no cost events exits 0" 0
check_eq "no cost events runs the iteration" "$(runner_count)" 1
check_has "no cost events stop on iterations" "$JOURNAL" "diagnosis: budget: iterations"
check_has "no cost events are not measured" "$JOURNAL" "cost_status: not_measured"
if grep -qx 'cost: not measured' "$JOURNAL"; then
  ok "no cost events say cost: not measured"
else
  bad "no cost events missing exact cost: not measured line"
fi
check_lacks "no cost events are not partial" "$JOURNAL" "cost_status: partial"
check_lacks "no cost events are not complete" "$JOURNAL" "cost_status: complete"
check_lacks "no cost events do not invent a dollar amount" "$JOURNAL" '"cost_usd":"'

# Direct engine calls. loop.sh is not involved, so a pause or crash hook can
# sit inside the locked stop transaction. Extra arguments are KEY=VALUE
# exports visible to that one call.
engine_boundary() {
  local log="$1"
  shift
  (
    export STATE_DIR="$REPO/gibson"
    export JOURNAL="$JOURNAL"
    export EXPECTED_REPO_SLUG="acme/app"
    export GIBSON_LANE_ID="solo"
    export SB_LIMIT_ITERATIONS=1
    export SB_LIMIT_WALL_MIN=480
    export SB_LIMIT_COST_USD=20
    export SB_UNBOUNDED=0
    unset GIBSON_COST_LEDGER || true
    unset SB_CRASH_AFTER_LATCH SB_HOLD_FILE SB_RELEASE_FILE || true
    local kv key val
    for kv in "$@"; do
      key=${kv%%=*}
      val=${kv#*=}
      export "$key=$val"
    done
    # shellcheck disable=SC1090
    source "$LIB"
    info() { printf '%s\n' "$*" >&2; }
    sb_boundary_check
  ) >"$log.out" 2>"$log"
}

echo "two concurrent boundary checks publish one receipt"
clear_hooks
setup_repo
mkdir -p "$REPO/gibson"
write_seed_allowance max_iterations=1 max_wall_min=480 max_cost_usd=20 consumed_starts=1 completed_iterations=1
rm -f "$ROOT/hold" "$ROOT/release"
engine_boundary "$ROOT/conc-a" "SB_HOLD_FILE=$ROOT/hold" "SB_RELEASE_FILE=$ROOT/release" &
conc_a=$!
if [[ -f "$ROOT/hold" ]] || python3 - "$ROOT/hold" <<'PY'
import sys, time
path = sys.argv[1]
deadline = time.time() + 5
while time.time() < deadline:
    try:
        open(path, "r", encoding="utf-8").read()
        sys.exit(0)
    except OSError:
        time.sleep(0.05)
sys.exit(1)
PY
then
  ok "first boundary paused inside the stop lock"
else
  bad "first boundary did not pause inside the stop lock"
fi
engine_boundary "$ROOT/conc-b" &
conc_b=$!
# Stay inside A's lock long enough for B to block on it, then release A.
sleep 0.5
: > "$ROOT/release"
wait "$conc_a"
conc_a_rc=$?
wait "$conc_b"
conc_b_rc=$?
check_eq "concurrent boundary A stops" "$conc_a_rc" 2
check_eq "concurrent boundary B stops" "$conc_b_rc" 2
check_eq "concurrent boundaries publish one receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
check_eq "concurrent boundaries publish one receipt id" "$(count_in "$JOURNAL" '"receipt_id":')" 1

echo "a crash after the latch publishes one receipt on the next launch"
clear_hooks
setup_repo
mkdir -p "$REPO/gibson"
write_seed_allowance max_iterations=1 max_wall_min=480 max_cost_usd=20 consumed_starts=1 completed_iterations=0
engine_boundary "$ROOT/crash-1" SB_CRASH_AFTER_LATCH=1
crash_rc=$?
check_eq "crash after the latch returns nonzero" "$crash_rc" 1
[[ -f "$LATCH" ]] && ok "crash leaves the latch" || bad "crash removed the latch"
check_eq "crash writes no receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 0
# The in-flight runner finishes after the stop snapshot was latched.
patch_allow completed_iterations=1
engine_boundary "$ROOT/crash-2"
crash_recover_rc=$?
check_eq "next launch after the crash stops" "$crash_recover_rc" 2
check_eq "next launch publishes one receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
check_has "recovered receipt records the in-flight stop" "$JOURNAL" "in_flight: 1"
check_has "recovered receipt keeps the stop-time count" "$JOURNAL" "iterations_completed: 0"
check_has "recovered receipt does not adopt the later completion" "$JOURNAL" "starts_consumed: 1"
engine_boundary "$ROOT/crash-3"
crash_again_rc=$?
check_eq "third launch still stops" "$crash_again_rc" 2
check_eq "third launch does not append another receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1

echo "a stop with a runner in flight records it"
clear_hooks
setup_repo
mkdir -p "$REPO/gibson"
write_seed_allowance max_iterations=1 max_wall_min=480 max_cost_usd=20 consumed_starts=1 completed_iterations=0
engine_boundary "$ROOT/inflight"
inflight_rc=$?
check_eq "in-flight stop returns stop" "$inflight_rc" 2
check_eq "in-flight stop publishes one receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
check_has "in-flight stop says in_flight: 1" "$JOURNAL" "in_flight: 1"
check_has "in-flight stop records iterations_completed 0" "$JOURNAL" "iterations_completed: 0"
check_has "in-flight json records the flag" "$JOURNAL" '"in_flight":1'
check_lacks "in-flight stop does not claim a finished iteration" "$JOURNAL" "iterations_completed: 1"

echo "a torn receipt id is not a published receipt"
clear_hooks
setup_repo
mkdir -p "$REPO/gibson"
write_seed_allowance max_iterations=1 max_wall_min=480 max_cost_usd=20 consumed_starts=1 completed_iterations=1
engine_boundary "$ROOT/torn-1" SB_CRASH_AFTER_LATCH=1
torn_rc=$?
check_eq "torn setup crashes before the receipt" "$torn_rc" 1
check_eq "torn setup writes no schema line" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 0
torn_id=$(sed -n 's/^receipt_id=//p' "$LATCH" | head -n 1)
[[ -n "$torn_id" ]] && ok "torn setup left a receipt id on the latch" || bad "torn setup left no receipt id"
# A crash can leave the receipt id on disk without the rest of the receipt.
printf '%s\n' "partial {\"receipt_id\":\"${torn_id}\"" >> "$JOURNAL"
engine_boundary "$ROOT/torn-2"
torn_recover_rc=$?
check_eq "torn fragment still returns stop" "$torn_recover_rc" 2
check_eq "torn recovery writes one schema line" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
check_eq "torn recovery writes one end marker" "$(count_in "$JOURNAL" "receipt_end: ${torn_id}")" 1
if python3 - "$JOURNAL" >/dev/null 2>&1 <<'PY'
import json, sys
last = ""
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if '"schema":"gibson.session-budget.v1"' in line:
        last = line.strip()
json.loads(last)
if not last:
    raise SystemExit(1)
PY
then
  ok "torn recovery leaves a parseable receipt"
else
  bad "torn recovery left an unreadable receipt"
fi
engine_boundary "$ROOT/torn-3"
torn_again_rc=$?
check_eq "torn receipt stays stopped" "$torn_again_rc" 2
check_eq "torn recovery does not append another end marker" "$(count_in "$JOURNAL" "receipt_end: ${torn_id}")" 1

echo "a latched stop refuses a different lane and a different repo"
clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/latch-lane-seed.err" --max-iterations 1
check_rc "latched lane seed exits 0" 0
check_eq "latched lane seed publishes one receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
: > "$CALLS/runner.count"
USE_LANE=other
run_loop "$ROOT/latch-lane-other.err" --once
check_rc "latched other lane exits 1" 1
check_eq "latched other lane does not start a runner" "$(runner_count)" 0
check_has "latched other lane does not cross-charge" "$ROOT/latch-lane-other.err" "Resumed identities do not cross-charge"
check_has "latched other lane journals the refusal" "$JOURNAL" "session-budget-refused"
check_eq "latched other lane does not append a receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
[[ -f "$LATCH" ]] && ok "latched other lane leaves the latch" || bad "latched other lane removed the latch"
USE_LANE=""
: > "$CALLS/runner.count"
run_loop "$ROOT/latch-lane-home.err" --once --max-iterations 1
check_rc "owning lane after refusal still stops" 0
check_eq "owning lane after refusal does not start a runner" "$(runner_count)" 0
check_eq "owning lane after refusal does not append a receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
clear_hooks
setup_repo
mkdir -p "$REPO/gibson"
write_seed_allowance max_iterations=1 max_wall_min=480 max_cost_usd=20 consumed_starts=1 completed_iterations=1
engine_boundary "$ROOT/latch-repo-seed"
latch_repo_rc=$?
check_eq "latched repo seed stops" "$latch_repo_rc" 2
check_eq "latched repo seed publishes one receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
engine_boundary "$ROOT/latch-repo-other" EXPECTED_REPO_SLUG=other/repo
latch_repo_other_rc=$?
check_eq "latched other repo exits 1" "$latch_repo_other_rc" 1
check_has "latched other repo does not cross-charge" "$ROOT/latch-repo-other" "Resumed identities do not cross-charge"
check_eq "latched other repo does not append a receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1
[[ -f "$LATCH" ]] && ok "latched other repo leaves the latch" || bad "latched other repo removed the latch"

echo "a merged flag without an integer pr is not a measured zero"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/prs-bare.jsonl"
: > "$USE_LEDGER"
echo progress > "$CALLS/mode"
run_loop "$ROOT/prs-bare-seed.err" --once --max-iterations 2
check_rc "bare merged seed exits 0" 0
SID=$(allow_field session_id)
python3 - "$USE_LEDGER" "$SID" <<'PY'
import json, sys
path, sid = sys.argv[1:]
ev = {"schema": "gibson.cost.v1", "session_id": sid, "merged": False}
open(path, "a", encoding="utf-8").write(json.dumps(ev) + "\n")
PY
run_loop "$ROOT/prs-bare.err" --max-iterations 2
check_rc "bare merged stop exits 0" 0
check_has "bare merged stays not measured" "$JOURNAL" "prs_merged: not measured"
check_lacks "bare merged is not a counted zero" "$JOURNAL" "prs_merged: 0"

echo "boolean merged plus an integer pr is counted"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/prs-counted.jsonl"
: > "$USE_LEDGER"
echo progress > "$CALLS/mode"
run_loop "$ROOT/prs-count-seed.err" --once --max-iterations 2
check_rc "counted pr seed exits 0" 0
SID=$(allow_field session_id)
python3 - "$USE_LEDGER" "$SID" <<'PY'
import json, sys
path, sid = sys.argv[1:]
ev = {"schema": "gibson.cost.v1", "session_id": sid, "merged": True, "pr": 7}
open(path, "a", encoding="utf-8").write(json.dumps(ev) + "\n")
PY
run_loop "$ROOT/prs-count.err" --max-iterations 2
check_rc "counted pr stop exits 0" 0
check_has "integer pr is counted" "$JOURNAL" "prs_merged: 1"
check_lacks "integer pr is not left unmeasured" "$JOURNAL" "prs_merged: not measured"

echo "fine-grained and large cost_usd strings are summed"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-fine.jsonl"
: > "$USE_LEDGER"
echo progress > "$CALLS/mode"
run_loop "$ROOT/cost-fine-seed.err" --once --max-iterations 2
check_rc "fine cost seed exits 0" 0
SID=$(allow_field session_id)
python3 - "$USE_LEDGER" "$SID" <<'PY'
import json, sys
path, sid = sys.argv[1:]
ev = {"schema": "gibson.cost.v1", "session_id": sid, "cost_usd": "0.0000001", "iteration": 1}
open(path, "a", encoding="utf-8").write(json.dumps(ev) + "\n")
PY
run_loop "$ROOT/cost-fine.err" --max-iterations 2
check_rc "fine cost stop exits 0" 0
check_has "fine cost is partial" "$JOURNAL" "cost_status: partial"
if grep -qx 'cost: partial 0.0000001' "$JOURNAL"; then
  ok "fine cost prints cost: partial 0.0000001"
else
  bad "fine cost did not print cost: partial 0.0000001"
fi
check_lacks "fine cost is not rejected as malformed" "$ROOT/cost-fine.err" "not an exact non-negative decimal"

clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-large.jsonl"
: > "$USE_LEDGER"
echo progress > "$CALLS/mode"
run_loop "$ROOT/cost-large-seed.err" --once --max-iterations 5 --max-cost-usd 20
check_rc "large cost seed exits 0" 0
check_eq "large cost seed ran one runner" "$(runner_count)" 1
SID=$(allow_field session_id)
python3 - "$USE_LEDGER" "$SID" <<'PY'
import json, sys
path, sid = sys.argv[1:]
ev = {"schema": "gibson.cost.v1", "session_id": sid, "cost_usd": "10000000000", "iteration": 1}
open(path, "a", encoding="utf-8").write(json.dumps(ev) + "\n")
PY
: > "$CALLS/runner.count"
run_loop "$ROOT/cost-large.err" --max-iterations 5 --max-cost-usd 20
check_rc "large cost stop exits 0" 0
check_eq "large cost does not start another runner" "$(runner_count)" 0
check_has "large cost stops on cost" "$JOURNAL" "diagnosis: budget: cost"
if grep -qx 'cost: partial 10000000000' "$JOURNAL"; then
  ok "large cost prints the full dollar string"
else
  bad "large cost did not print cost: partial 10000000000"
fi

clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-exp.jsonl"
: > "$USE_LEDGER"
echo progress > "$CALLS/mode"
run_loop "$ROOT/cost-exp-seed.err" --once --max-iterations 2
SID=$(allow_field session_id)
python3 - "$USE_LEDGER" "$SID" <<'PY'
import json, sys
path, sid = sys.argv[1:]
ev = {"schema": "gibson.cost.v1", "session_id": sid, "cost_usd": "1e-7", "iteration": 1}
open(path, "a", encoding="utf-8").write(json.dumps(ev) + "\n")
PY
: > "$CALLS/runner.count"
run_loop "$ROOT/cost-exp.err" --max-iterations 2
check_rc "exponent cost_usd exits 1" 1
check_eq "exponent cost_usd does not start a runner" "$(runner_count)" 0
check_has "exponent cost_usd is not an exact decimal" "$ROOT/cost-exp.err" "not an exact non-negative decimal"

echo "a symlink journal is not followed"
clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/jlink-seed.err" --once
check_rc "symlink journal seed exits 0" 0
mv "$JOURNAL" "$ROOT/journal-real.md"
printf 'SECRET\n' > "$ROOT/journal-target.md"
ln -s "$ROOT/journal-target.md" "$JOURNAL"
USE_LANE=other
run_loop "$ROOT/jlink-other.err" --once
check_rc "symlink journal refusal exits 1" 1
check_lacks "symlink journal target has no refusal" "$ROOT/journal-target.md" "session-budget-refused"
check_has "symlink journal names the link" "$ROOT/jlink-other.err" "journal is a symlink"
if [[ "$(cat "$ROOT/journal-target.md")" == "SECRET" ]]; then
  ok "symlink journal target is unchanged"
else
  bad "symlink journal target was written"
fi
USE_LANE=""

echo "another session's malformed cost_usd does not fail this session"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-foreign-bad.jsonl"
: > "$USE_LEDGER"
echo progress > "$CALLS/mode"
python3 - "$USE_LEDGER" <<'PY'
import json, sys
ev = {"schema": "gibson.cost.v1", "session_id": "sb-20261015T120000Z-ffffeeee", "cost_usd": 1.5}
open(sys.argv[1], "a", encoding="utf-8").write(json.dumps(ev) + "\n")
PY
run_loop "$ROOT/foreign-bad.err" --max-iterations 1 --max-cost-usd 1
check_rc "foreign malformed cost exits 0" 0
check_eq "foreign malformed cost runs the iteration" "$(runner_count)" 1
check_has "foreign malformed cost stays not measured" "$JOURNAL" "cost_status: not_measured"
check_lacks "foreign malformed cost is not a ledger fatal" "$ROOT/foreign-bad.err" "cost_usd must be a decimal string"
check_lacks "foreign malformed cost does not latch unreadable" "$JOURNAL" "diagnosis: budget: cost-ledger-unreadable"

echo "a dangling cost-ledger symlink fails closed"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-dangling.jsonl"
ln -s "$ROOT/cost-missing.jsonl" "$USE_LEDGER"
echo progress > "$CALLS/mode"
run_loop "$ROOT/dangling.err" --once --max-iterations 2
check_rc "dangling ledger exits 1" 1
check_eq "dangling ledger does not start a runner" "$(runner_count)" 0
check_has "dangling ledger diagnosis" "$JOURNAL" "diagnosis: budget: cost-ledger-unreadable"
[[ -e "$ALLOW" ]] && bad "dangling ledger granted an allowance" || ok "dangling ledger grants no allowance"
[[ -f "$LATCH" ]] && ok "dangling ledger writes a latch" || bad "dangling ledger wrote no latch"

echo "an unbounded opt-out is refused when the journal cannot record it"
clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/optout-prep.err" --once
check_rc "opt-out prep exits 0" 0
rm -f "$ALLOW" "$LATCH"
mv "$JOURNAL" "$ROOT/journal-real-optout.md"
printf 'SECRET\n' > "$ROOT/optout-target.md"
ln -s "$ROOT/optout-target.md" "$JOURNAL"
: > "$CALLS/runner.count"
run_loop "$ROOT/optout-link.err" --once --unbounded
check_rc "unbounded symlink journal exits 1" 1
check_eq "unbounded symlink journal does not start a runner" "$(runner_count)" 0
check_lacks "unbounded symlink journal target has no opt-out" "$ROOT/optout-target.md" "session-budget-opt-out"
check_has "unbounded symlink journal names the link" "$ROOT/optout-link.err" "journal is a symlink"
if [[ "$(cat "$ROOT/optout-target.md")" == "SECRET" ]]; then
  ok "unbounded symlink journal target is unchanged"
else
  bad "unbounded symlink journal target was written"
fi
[[ -e "$ALLOW" ]] && bad "unbounded symlink journal left an allowance" || ok "unbounded symlink journal leaves no allowance"

echo "a reset is refused when the journal cannot record it"
clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/reset-link-seed.err" --once
check_rc "reset symlink seed exits 0" 0
SID=$(allow_field session_id)
mv "$JOURNAL" "$ROOT/journal-real-reset.md"
printf 'SECRET\n' > "$ROOT/reset-target.md"
ln -s "$ROOT/reset-target.md" "$JOURNAL"
: > "$CALLS/runner.count"
run_loop "$ROOT/reset-link.err" --once --reset-session-budget
check_rc "reset symlink journal exits 1" 1
check_eq "reset symlink journal does not start a runner" "$(runner_count)" 0
check_lacks "reset symlink journal target has no reset" "$ROOT/reset-target.md" "session-budget-reset"
check_has "reset symlink journal names the link" "$ROOT/reset-link.err" "journal is a symlink"
if [[ "$(cat "$ROOT/reset-target.md")" == "SECRET" ]]; then
  ok "reset symlink journal target is unchanged"
else
  bad "reset symlink journal target was written"
fi
if [[ -f "$ALLOW" && "$(allow_field session_id)" == "$SID" ]]; then
  ok "reset symlink journal keeps the allowance"
else
  bad "reset symlink journal replaced the allowance"
fi

echo "a reset does not delete the allowance when the latch is not a regular file"
clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/reset-latch-link-seed.err" --once
check_rc "reset latch symlink seed exits 0" 0
SID=$(allow_field session_id)
ln -s "$ROOT/no-such-latch" "$LATCH"
: > "$CALLS/runner.count"
run_loop "$ROOT/reset-latch-link.err" --once --reset-session-budget
check_rc "reset latch symlink exits 1" 1
check_eq "reset latch symlink does not start a runner" "$(runner_count)" 0
if [[ -f "$ALLOW" && "$(allow_field session_id)" == "$SID" ]]; then
  ok "reset latch symlink keeps the allowance"
else
  bad "reset latch symlink deleted the allowance"
fi
[[ -L "$LATCH" ]] && ok "reset latch symlink leaves the latch link" || bad "reset latch symlink removed the latch link"

clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/reset-latch-dir-seed.err" --once
check_rc "reset latch directory seed exits 0" 0
SID=$(allow_field session_id)
mkdir -p "$LATCH"
: > "$CALLS/runner.count"
run_loop "$ROOT/reset-latch-dir.err" --once --reset-session-budget
check_rc "reset latch directory exits 1" 1
check_eq "reset latch directory does not start a runner" "$(runner_count)" 0
if [[ -f "$ALLOW" && "$(allow_field session_id)" == "$SID" ]]; then
  ok "reset latch directory keeps the allowance"
else
  bad "reset latch directory deleted the allowance"
fi
[[ -d "$LATCH" ]] && ok "reset latch directory leaves the directory" || bad "reset latch directory removed the directory"

echo "a reset does not delete the allowance when the journal is not writable"
clear_hooks
setup_repo
echo progress > "$CALLS/mode"
run_loop "$ROOT/reset-ro-seed.err" --once
check_rc "read-only journal seed exits 0" 0
SID=$(allow_field session_id)
chmod 0444 "$JOURNAL"
: > "$CALLS/runner.count"
run_loop "$ROOT/reset-ro.err" --once --reset-session-budget
if grep -F -q "session-budget-reset" "$JOURNAL"; then
  ok "read-only journal reset wrote the line before removing state"
  [[ ! -e "$ALLOW" ]] && ok "read-only journal reset removed the allowance after the line" || bad "read-only journal reset wrote the line and left the allowance"
else
  if [[ -f "$ALLOW" && "$(allow_field session_id)" == "$SID" ]]; then
    ok "read-only journal reset kept the allowance"
  else
    bad "read-only journal reset deleted the allowance without a journal line"
  fi
  ok "read-only journal reset did not need a second allowance check"
fi
check_eq "read-only journal reset does not start a runner" "$(runner_count)" 0
chmod u+w "$JOURNAL" 2>/dev/null || true

echo "a dangling latch is not a missing latch"
clear_hooks
setup_repo
echo progress > "$CALLS/mode"
ln -s "$ROOT/no-such-latch" "$LATCH"
: > "$CALLS/runner.count"
run_loop "$ROOT/dangling-latch.err" --once
check_rc "dangling latch exits 1" 1
check_eq "dangling latch does not start a runner" "$(runner_count)" 0
[[ -e "$ALLOW" ]] && bad "dangling latch created an allowance" || ok "dangling latch creates no allowance"
[[ -L "$LATCH" ]] && ok "dangling latch leaves the link" || bad "dangling latch removed the link"
check_has "dangling latch names the latch" "$ROOT/dangling-latch.err" "latch is not a regular file"

echo "another lane does not clear an unreadable latch"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/unread-other-ledger.jsonl"
echo '{}' > "$ROOT/unread-other-target.jsonl"
ln -s "$ROOT/unread-other-target.jsonl" "$USE_LEDGER"
echo progress > "$CALLS/mode"
run_loop "$ROOT/unread-other-1.err" --once --max-iterations 2
check_rc "unreadable latch seed exits 1" 1
check_has "unreadable latch seed records the lane" "$LATCH" "lane_id=solo"
check_has "unreadable latch seed records the repo" "$LATCH" "repo=acme/app"
rm -f "$USE_LEDGER"
: > "$USE_LEDGER"
USE_LANE=other
: > "$CALLS/runner.count"
run_loop "$ROOT/unread-other-2.err" --once --max-iterations 2
check_rc "other lane unreadable latch exits 1" 1
check_eq "other lane unreadable latch does not start a runner" "$(runner_count)" 0
check_has "other lane unreadable latch does not cross-charge" "$ROOT/unread-other-2.err" "Resumed identities do not cross-charge"
[[ -f "$LATCH" ]] && ok "other lane leaves the unreadable latch" || bad "other lane cleared the unreadable latch"
check_has "other lane leaves kind=unreadable" "$LATCH" "kind=unreadable"
[[ -e "$ALLOW" ]] && bad "other lane created an allowance" || ok "other lane creates no allowance"
USE_LANE=""

echo "a concurrent journal append survives the receipt write"
clear_hooks
setup_repo
mkdir -p "$REPO/gibson"
printf 'BEFORE\n' > "$JOURNAL"
write_seed_allowance max_iterations=1 max_wall_min=480 max_cost_usd=20 consumed_starts=1 completed_iterations=1
rm -f "$ROOT/jhold" "$ROOT/jrelease"
engine_boundary "$ROOT/jrace" "SB_JOURNAL_HOLD_FILE=$ROOT/jhold" "SB_JOURNAL_RELEASE_FILE=$ROOT/jrelease" &
jrace_pid=$!
if [[ -f "$ROOT/jhold" ]] || python3 - "$ROOT/jhold" <<'PY'
import sys, time
path = sys.argv[1]
deadline = time.time() + 5
while time.time() < deadline:
    try:
        open(path, "r", encoding="utf-8").read()
        sys.exit(0)
    except OSError:
        time.sleep(0.05)
sys.exit(1)
PY
then
  ok "receipt write paused after reading the journal"
else
  bad "receipt write did not pause"
fi
printf 'CONCURRENT\n' >> "$JOURNAL"
: > "$ROOT/jrelease"
wait "$jrace_pid"
jrace_rc=$?
check_eq "concurrent journal append still stops" "$jrace_rc" 2
check_has "concurrent journal append keeps the earlier line" "$JOURNAL" "BEFORE"
check_has "concurrent journal append keeps the raced line" "$JOURNAL" "CONCURRENT"
check_eq "concurrent journal append publishes one receipt" "$(count_in "$JOURNAL" 'gibson.session-budget.v1')" 1

echo "an interrupted start with no loop pid still resets"
clear_hooks
setup_repo
mkdir -p "$REPO/gibson"
printf '# Gibson loop journal\n' > "$JOURNAL"
write_seed_allowance consumed_starts=1 completed_iterations=0
SID=$(allow_field session_id)
reset_gate "$ROOT/reset-interrupted.err"
reset_interrupted_rc=$?
check_eq "interrupted start reset exits 0" "$reset_interrupted_rc" 0
check_has "interrupted start reset is journaled" "$JOURNAL" "session-budget-reset"
if [[ -e "$ALLOW" || -L "$ALLOW" ]]; then
  bad "interrupted start reset left the allowance"
else
  ok "interrupted start reset deletes the allowance"
fi
echo progress > "$CALLS/mode"
run_loop "$ROOT/reset-interrupted-next.err" --once --max-iterations 2
check_eq "interrupted start reset then runs one runner" "$(runner_count)" 1
if [[ -f "$ALLOW" && "$(allow_field session_id)" != "$SID" ]]; then
  ok "interrupted start reset creates a fresh session"
else
  bad "interrupted start reset did not create a fresh session"
fi

echo "a dead loop pid still resets"
clear_hooks
setup_repo
mkdir -p "$REPO/gibson"
printf '# Gibson loop journal\n' > "$JOURNAL"
sleep 30 &
dead_pid=$!
kill -9 "$dead_pid" 2>/dev/null || true
wait "$dead_pid" 2>/dev/null || true
if kill -0 "$dead_pid" 2>/dev/null; then
  bad "dead pid fixture is still alive"
else
  ok "dead pid fixture is not alive"
fi
write_seed_allowance consumed_starts=1 completed_iterations=0 runner_pid="$dead_pid"
reset_gate "$ROOT/reset-dead.err"
reset_dead_rc=$?
check_eq "dead pid reset exits 0" "$reset_dead_rc" 0
check_has "dead pid reset is journaled" "$JOURNAL" "session-budget-reset"
if [[ -e "$ALLOW" || -L "$ALLOW" ]]; then
  bad "dead pid reset left the allowance"
else
  ok "dead pid reset deletes the allowance"
fi

echo "a live recorded loop pid refuses reset"
clear_hooks
setup_repo
mkdir -p "$REPO/gibson"
printf '# Gibson loop journal\n' > "$JOURNAL"
sleep 60 &
live_pid=$!
write_seed_allowance consumed_starts=1 completed_iterations=0 runner_pid="$live_pid"
SID=$(allow_field session_id)
reset_gate "$ROOT/reset-live.err"
reset_live_rc=$?
check_eq "live pid reset exits 1" "$reset_live_rc" 1
check_has "live pid reset names the refusal" "$ROOT/reset-live.err" "reset refused while a start is in flight"
check_lacks "live pid reset writes no reset line" "$JOURNAL" "session-budget-reset"
if [[ -f "$ALLOW" && "$(allow_field session_id)" == "$SID" ]]; then
  ok "live pid reset keeps the allowance"
else
  bad "live pid reset deleted the allowance"
fi
check_eq "live pid reset keeps the consumed start" "$(allow_field consumed_starts)" 1
kill -9 "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

echo "a running loop records its pid and reset refuses"
clear_hooks
setup_repo
rm -f "$CALLS/runner.ready" "$CALLS/runner.release" "$CALLS/runner.pid"
echo pause > "$CALLS/mode"
run_loop "$ROOT/pause.err" --once --max-iterations 2 &
pause_pid=$!
if [[ -f "$CALLS/runner.ready" ]] || python3 - "$CALLS/runner.ready" <<'PY'
import sys, time
path = sys.argv[1]
deadline = time.time() + 10
while time.time() < deadline:
    try:
        open(path, "r", encoding="utf-8").read()
        sys.exit(0)
    except OSError:
        time.sleep(0.05)
sys.exit(1)
PY
then
  ok "paused runner reached the reserved start"
else
  bad "paused runner did not start"
fi
stored_pid=$(python3 - "$ALLOW" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    sys.stdout.write("")
    raise SystemExit(0)
pid = doc.get("runner_pid")
if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
    sys.stdout.write("")
else:
    sys.stdout.write(str(pid))
PY
)
runner_self=$(cat "$CALLS/runner.pid" 2>/dev/null || true)
if [[ -n "$stored_pid" ]] && kill -0 "$stored_pid" 2>/dev/null; then
  ok "reserved pid is alive while the runner is in flight"
else
  bad "reserved pid is not alive while the runner is in flight (got '${stored_pid}')"
fi
ps -p "$stored_pid" -ww -o args= > "$ROOT/pause.ps" 2>/dev/null || true
check_has "reserved pid is loop.sh" "$ROOT/pause.ps" "loop.sh"
if [[ -n "$stored_pid" && -n "$runner_self" && "$stored_pid" != "$runner_self" ]]; then
  ok "reserved pid is not the runner process"
else
  bad "reserved pid is the runner or empty (stored '${stored_pid}' runner '${runner_self}')"
fi
SID=$(allow_field session_id)
reset_gate "$ROOT/reset-running.err"
reset_running_rc=$?
check_eq "reset during a live loop exits 1" "$reset_running_rc" 1
check_has "reset during a live loop names the refusal" "$ROOT/reset-running.err" "reset refused while a start is in flight"
if [[ -f "$ALLOW" && "$(allow_field session_id)" == "$SID" ]]; then
  ok "reset during a live loop keeps the allowance"
else
  bad "reset during a live loop deleted the allowance"
fi
: > "$CALLS/runner.release"
wait "$pause_pid" || true
pause_rc=$?
check_eq "live loop finishes after the refused reset" "$pause_rc" 0
check_eq "live loop completed the reserved start" "$(allow_field completed_iterations)" 1
if python3 - "$ALLOW" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if "runner_pid" not in doc else 1)
PY
then
  ok "completed start clears the loop pid"
else
  bad "completed start left the loop pid"
fi

echo "session-budget.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
