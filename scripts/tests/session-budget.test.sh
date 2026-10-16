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
    if key in ("consumed_starts", "completed_iterations", "max_iterations", "max_wall_min"):
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
    if key in ("consumed_starts", "completed_iterations", "max_iterations", "max_wall_min"):
        doc[key] = int(val)
    elif key == "unbounded":
        doc[key] = (val == "true")
    else:
        doc[key] = val
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n")
PY
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
check_has "default cost receipt is complete" "$JOURNAL" "cost_status: complete"
check_has "default cost receipt names the dollars" "$JOURNAL" '"cost_usd":"20"'

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

echo "fractional sum stays partial-free under the cap"
clear_hooks
setup_repo
USE_LEDGER="$ROOT/cost-frac.jsonl"
: > "$USE_LEDGER"
echo fractional > "$CALLS/mode"
run_loop "$ROOT/frac.err" --max-iterations 2 --max-cost-usd 1
check_rc "fractional sum exits 0" 0
check_eq "fractional sum runs both iterations" "$(runner_count)" 2
check_has "fractional stop is iterations" "$JOURNAL" "diagnosis: budget: iterations"
if grep -qx 'cost: 0.3' "$JOURNAL"; then
  ok "0.10+0.20 prints as cost: 0.3"
else
  bad "fractional total was not cost: 0.3"
fi
check_has "fractional cost_status is complete" "$JOURNAL" "cost_status: complete"
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
check_has "explicit zero is measured" "$JOURNAL" "cost_status: complete"
if grep -qx 'cost: 0' "$JOURNAL"; then
  ok "explicit zero prints cost: 0"
else
  bad "explicit zero did not print cost: 0"
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
direct=$(sb_format_rollup "$FLEET_DIR_P/lane-docs/gibson/journal.md" docs)
rmdir "$FLEET_DIR_P/lane-docs/gibson/journal.md"
check_eq "direct rollup of a directory journal is unreadable" "$direct" "session-budget lane=docs receipt=unreadable"

echo "session-budget.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
