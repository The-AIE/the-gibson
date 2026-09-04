#!/usr/bin/env bash
# sensor-reachability.test.sh — mutation witnesses for #307
#
# WHY
#   A sensor nobody calls is documentation. These checks prove the classifier
#   lists every top-level scripts/*.{sh,mjs}, that an orphan over the baseline
#   is red, that --update-baseline refuses to raise, that a synthetic
#   nothing-calls-me.sh turns the check red, and that the self-gate DCO step
#   fails unsigned commits in a fixture repo and passes signed ones. A signed
#   branch with an unsigned synthetic merge on top stays green (PR head, not
#   HEAD). A body-line Signed-off-by that is not a git trailer is red.
#
# USAGE
#   scripts/tests/sensor-reachability.test.sh
set -uo pipefail

# Hermetic git identity (L-052): pin, do not inherit CI's GIT_COMMITTER_*.
export GIT_AUTHOR_NAME=gibson-sensor
export GIT_AUTHOR_EMAIL=sensor@gibson.invalid
export GIT_COMMITTER_NAME=gibson-sensor
export GIT_COMMITTER_EMAIL=sensor@gibson.invalid
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export LC_ALL=C
export LANG=C

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
SENSOR="$REPO_ROOT/scripts/sensor-reachability.mjs"
WF="$REPO_ROOT/.github/workflows/gibson-self-gate.yml"
BASELINE="$REPO_ROOT/config/sensor-reachability-baseline.v1.json"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "sensor-reachability.test.sh: node required"; exit 1; }
command -v git >/dev/null || { echo "sensor-reachability.test.sh: git required"; exit 1; }
[[ -f "$SENSOR" ]] || { echo "sensor-reachability.test.sh: missing $SENSOR"; exit 1; }
[[ -f "$WF" ]] || { echo "sensor-reachability.test.sh: missing $WF"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-sensor-reach.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

GIT="git -c user.email=sensor@gibson.invalid -c user.name=gibson-sensor -c commit.gpgsign=false"

write_baseline() {
  local path="$1" max="$2"
  shift 2
  node -e '
    const max = Number(process.argv[1]);
    const orphans = process.argv.slice(2);
    const out = {
      schema: "gibson.sensor-reachability-baseline.v1",
      orphanMax: max,
      orphans,
    };
    process.stdout.write(JSON.stringify(out, null, 2) + "\n");
  ' "$max" "$@" > "$path"
}

# Minimal fixture: two scripts, one caller.
seed_fixture() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo/scripts/tests" "$repo/.github/workflows" "$repo/ci" \
           "$repo/playbooks" "$repo/config"
  printf '%s\n' '#!/bin/bash' 'echo called' > "$repo/scripts/called.sh"
  printf '%s\n' '#!/bin/bash' 'echo orphan' > "$repo/scripts/orphan.sh"
  printf '%s\n' '#!/bin/bash' 'bash scripts/called.sh' > "$repo/scripts/tests/run-all.sh"
  write_baseline "$repo/config/sensor-reachability-baseline.v1.json" 1 orphan.sh
}

run_sensor() {
  # run_sensor <repo> [extra args...]  -> sets OUT RC
  local repo="$1"
  shift
  OUT=$(node "$SENSOR" --root "$repo" "$@" 2>"$ROOT/err")
  RC=$?
  ERR=$(cat "$ROOT/err")
}

echo "# --help is Ask-Contract shaped"
help_out=$(node "$SENSOR" --help 2>"$ROOT/help.err"); help_rc=$?
if [[ "$help_rc" -eq 0 ]]; then ok "--help exits 0"; else bad "--help exited $help_rc"; fi
if printf '%s\n' "$help_out" | grep -q 'WHAT IT DOES' && printf '%s\n' "$help_out" | grep -q 'RISKS'; then
  ok "--help names WHAT IT DOES and RISKS"
else
  bad "--help missing Ask-Contract fields"
fi
if [[ ! -s "$ROOT/help.err" ]]; then ok "--help is quiet on stderr"; else bad "--help wrote stderr"; fi

echo "# unknown flag exits 2"
unk_out=$(node "$SENSOR" --definitely-not-a-flag 2>"$ROOT/unk.err"); unk_rc=$?
if [[ "$unk_rc" -eq 2 ]] && grep -q 'unknown flag: --definitely-not-a-flag' "$ROOT/unk.err"; then
  ok "unknown flag exits 2 with unknown flag: on stderr"
else
  bad "unknown flag (rc=$unk_rc out=$unk_out err=$(cat "$ROOT/unk.err"))"
fi

echo "# AC1: lists every top-level scripts/*.sh and *.mjs; classifies; file:line"
FX="$ROOT/fx1"
seed_fixture "$FX"
printf '%s\n' 'export default 1' > "$FX/scripts/also.mjs"
write_baseline "$FX/config/sensor-reachability-baseline.v1.json" 2 orphan.sh also.mjs
run_sensor "$FX"
if [[ "$RC" -eq 0 ]]; then ok "clean fixture exits 0"; else bad "clean fixture rc=$RC err=$ERR out=$OUT"; fi
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/called.sh\tscripts/tests/run-all.sh:' \
  && ok "called.sh is REACHABLE with invoking file:line" \
  || bad "called.sh not REACHABLE with file:line: $OUT"
printf '%s\n' "$OUT" | grep -q $'ORPHAN\tscripts/orphan.sh' \
  && ok "orphan.sh is ORPHAN" \
  || bad "orphan.sh not ORPHAN: $OUT"
printf '%s\n' "$OUT" | grep -q $'ORPHAN\tscripts/also.mjs' \
  && ok "also.mjs is ORPHAN" \
  || bad "also.mjs not ORPHAN: $OUT"
# Inventory is top-level only: a file under scripts/lib is not listed.
mkdir -p "$FX/scripts/lib"
printf '%s\n' '#!/bin/bash' 'echo lib' > "$FX/scripts/lib/hidden.sh"
run_sensor "$FX"
printf '%s\n' "$OUT" | grep -q 'scripts/lib/hidden.sh' \
  && bad "scripts/lib/ was inventoried" \
  || ok "scripts/lib/ is excluded from inventory"
printf '%s\n' "$OUT" | grep -q 'scripts/tests/run-all.sh' \
  && printf '%s\n' "$OUT" | grep -qE '^(REACHABLE|ORPHAN)[[:space:]]+scripts/tests/' \
  && bad "scripts/tests/ was inventoried as a sensor" \
  || ok "scripts/tests/ is excluded from inventory"

echo "# comments and non-fence prose are not callers"
printf '%s\n' '#!/bin/bash' 'echo decoy' > "$FX/scripts/comment-only.sh"
printf '%s\n' '#!/bin/bash' 'echo decoy' > "$FX/scripts/prose-only.sh"
mkdir -p "$FX/.github/workflows"
cat > "$FX/.github/workflows/x.yml" <<'YML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      # node scripts/comment-only.sh
      - run: echo hi
YML
cat > "$FX/playbooks/builder.md" <<'MD'
See `scripts/prose-only.sh` in prose.

```javascript
node scripts/prose-only.sh
```
MD
write_baseline "$FX/config/sensor-reachability-baseline.v1.json" 4 \
  orphan.sh also.mjs comment-only.sh prose-only.sh
run_sensor "$FX"
printf '%s\n' "$OUT" | grep -q $'ORPHAN\tscripts/comment-only.sh' \
  && ok "YAML comment is not a caller" \
  || bad "comment-only.sh not ORPHAN: $OUT"
printf '%s\n' "$OUT" | grep -q $'ORPHAN\tscripts/prose-only.sh' \
  && ok "playbook prose / non-bash fence is not a caller" \
  || bad "prose-only.sh not ORPHAN: $OUT"

echo "# playbook bash fence IS a caller"
printf '%s\n' 'export default 1' > "$FX/scripts/fence-called.mjs"
cat > "$FX/playbooks/builder.md" <<'MD'
```bash
node scripts/fence-called.mjs --help
```
MD
write_baseline "$FX/config/sensor-reachability-baseline.v1.json" 4 \
  orphan.sh also.mjs comment-only.sh prose-only.sh
run_sensor "$FX"
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/fence-called.mjs\tplaybooks/builder.md:' \
  && ok "fenced bash block is a caller with file:line" \
  || bad "fence-called.mjs not REACHABLE: $OUT"

echo "# loop.sh / ci/*.yml / workflows are callers"
printf '%s\n' '#!/bin/bash' 'echo loop' > "$FX/scripts/loop-called.sh"
printf '%s\n' '#!/bin/bash' 'echo ci' > "$FX/scripts/ci-called.sh"
printf '%s\n' '#!/bin/bash' 'echo wf' > "$FX/scripts/wf-called.sh"
printf '%s\n' '#!/bin/bash' "source \"\$GIBSON/scripts/loop-called.sh\"" > "$FX/scripts/loop.sh"
# loop.sh is both a caller and an inventory item; name it from run-all so it
# is not itself an extra orphan in this fixture.
printf '%s\n' 'bash scripts/loop.sh' >> "$FX/scripts/tests/run-all.sh"
cat > "$FX/ci/gate.yml" <<'YML'
jobs:
  j:
    steps:
      - run: bash scripts/ci-called.sh
YML
cat > "$FX/.github/workflows/x.yml" <<'YML'
jobs:
  j:
    steps:
      - run: bash scripts/wf-called.sh
YML
write_baseline "$FX/config/sensor-reachability-baseline.v1.json" 4 \
  orphan.sh also.mjs comment-only.sh prose-only.sh
run_sensor "$FX"
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/loop-called.sh\tscripts/loop.sh:' \
  && ok "loop.sh is a caller" || bad "loop-called.sh: $OUT"
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/ci-called.sh\tci/gate.yml:' \
  && ok "ci/*.yml is a caller" || bad "ci-called.sh: $OUT"
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/wf-called.sh\t.github/workflows/x.yml:' \
  && ok "workflow yml is a caller" || bad "wf-called.sh: $OUT"

echo "# AC2: orphan count over baseline exits 1; --update-baseline refuses to raise"
seed_fixture "$FX"
printf '%s\n' '#!/bin/bash' 'echo extra' > "$FX/scripts/nothing-calls-me.sh"
write_baseline "$FX/config/sensor-reachability-baseline.v1.json" 1 orphan.sh
run_sensor "$FX"
if [[ "$RC" -eq 1 ]] && printf '%s\n' "$ERR" | grep -q 'exceeds baseline'; then
  ok "AC4/AC2: synthetic nothing-calls-me.sh exceeds baseline (exit 1)"
else
  bad "synthetic orphan did not fail (rc=$RC err=$ERR out=$OUT)"
fi
printf '%s\n' "$OUT" | grep -q $'ORPHAN\tscripts/nothing-calls-me.sh' \
  && ok "AC4: nothing-calls-me.sh classified ORPHAN" \
  || bad "nothing-calls-me.sh not ORPHAN: $OUT"

run_sensor "$FX" --update-baseline
if [[ "$RC" -eq 1 ]] && printf '%s\n' "$ERR" | grep -qi 'may only lower'; then
  ok "AC2: --update-baseline refuses to raise and says so"
else
  bad "update-baseline raise (rc=$RC err=$ERR)"
fi
# Baseline file must be unchanged (still 1).
if grep -Eq '"orphanMax":[[:space:]]*1(,|[[:space:]]|$)' \
  "$FX/config/sensor-reachability-baseline.v1.json"; then
  ok "refused raise left orphanMax=1"
else
  bad "refused raise changed baseline: $(cat "$FX/config/sensor-reachability-baseline.v1.json")"
fi

echo "# --update-baseline lowers when current < baseline"
seed_fixture "$FX"
write_baseline "$FX/config/sensor-reachability-baseline.v1.json" 5 orphan.sh extra.sh
run_sensor "$FX" --update-baseline
if [[ "$RC" -eq 0 ]] && printf '%s\n' "$OUT" | grep -q 'baseline lowered 5 -> 1'; then
  ok "--update-baseline lowers 5 -> 1"
else
  bad "lower failed (rc=$RC out=$OUT err=$ERR)"
fi
if grep -Eq '"orphanMax":[[:space:]]*1(,|[[:space:]]|$)' \
  "$FX/config/sensor-reachability-baseline.v1.json"; then
  ok "written orphanMax=1"
else
  bad "written baseline: $(cat "$FX/config/sensor-reachability-baseline.v1.json")"
fi

echo "# fail closed: missing / malformed baseline"
seed_fixture "$FX"
rm -f "$FX/config/sensor-reachability-baseline.v1.json"
run_sensor "$FX"
if [[ "$RC" -eq 1 ]] && printf '%s\n' "$ERR" | grep -qi 'missing baseline'; then
  ok "missing baseline exits 1"
else
  bad "missing baseline (rc=$RC err=$ERR)"
fi
printf '%s\n' '{not json' > "$FX/config/sensor-reachability-baseline.v1.json"
run_sensor "$FX"
if [[ "$RC" -eq 1 ]] && printf '%s\n' "$ERR" | grep -qi 'malformed'; then
  ok "malformed baseline exits 1"
else
  bad "malformed baseline (rc=$RC err=$ERR)"
fi
printf '%s\n' '{"schema":"gibson.sensor-reachability-baseline.v1","orphanMax":"6","orphans":[]}' \
  > "$FX/config/sensor-reachability-baseline.v1.json"
run_sensor "$FX"
if [[ "$RC" -ne 0 ]]; then ok "non-integer orphanMax is not green"; else bad "string orphanMax passed"; fi

echo "# missing scripts/ is an error, not a green empty scan"
mkdir -p "$ROOT/noscripts/config"
write_baseline "$ROOT/noscripts/config/sensor-reachability-baseline.v1.json" 0
run_sensor "$ROOT/noscripts"
if [[ "$RC" -eq 1 ]] && printf '%s\n' "$ERR" | grep -qi 'scripts/'; then
  ok "missing scripts/ exits 1"
else
  bad "missing scripts/ (rc=$RC err=$ERR)"
fi

echo "# AC3: live tree names the three Law sensors as ORPHAN"
live_out=$(node "$SENSOR" --root "$REPO_ROOT" 2>"$ROOT/live.err"); live_rc=$?
if printf '%s\n' "$live_out" | grep -q $'ORPHAN\tscripts/contract-met.mjs' \
   && printf '%s\n' "$live_out" | grep -q $'ORPHAN\tscripts/truthful-status.mjs' \
   && printf '%s\n' "$live_out" | grep -q $'ORPHAN\tscripts/contract-read-check.mjs'; then
  ok "AC3: contract-met, truthful-status, contract-read-check are ORPHAN"
else
  bad "AC3 Law sensors not ORPHAN (rc=$live_rc): $live_out err=$(cat "$ROOT/live.err")"
fi
if printf '%s\n' "$live_out" | grep -q $'REACHABLE\tscripts/sensor-reachability.mjs'; then
  ok "this sensor is REACHABLE (self-gate wires it)"
else
  bad "sensor-reachability.mjs is not REACHABLE from the self-gate: $live_out"
fi
if [[ -f "$BASELINE" ]]; then
  node -e '
    const b = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const need = ["contract-met.mjs", "truthful-status.mjs", "contract-read-check.mjs"];
    const missing = need.filter((n) => !b.orphans.includes(n));
    if (missing.length) { console.error("missing " + missing.join(",")); process.exit(1); }
  ' "$BASELINE" && ok "AC3: baseline names the three Law sensors" \
    || bad "baseline does not name the three Law sensors"
else
  bad "missing committed baseline $BASELINE"
fi

echo "# AC4: self-gate sensors job runs the reachability check"
if awk '
  /^[[:space:]]*sensors:/ { in_sensors=1 }
  in_sensors && /^[[:space:]]*[A-Za-z0-9_-]+:/ && !/sensors:/ && !/^[[:space:]]+sensors:/ {
    # next job-level key at same indent as sensors: ends the job
  }
  in_sensors { print }
' "$WF" | grep -qE '^[[:space:]]*run:[[:space:]]+node[[:space:]]+scripts/sensor-reachability\.mjs[[:space:]]*$'; then
  ok "sensors job has run: node scripts/sensor-reachability.mjs"
else
  # Narrower: the step exists in this workflow and is not under claim-isolation only.
  if grep -nE '^[[:space:]]*run:[[:space:]]+node[[:space:]]+scripts/sensor-reachability\.mjs[[:space:]]*$' "$WF" \
     | grep -q . \
     && awk '
          /^  sensors:/ { s=1 }
          /^  [A-Za-z0-9_-]+:/ && !/^  sensors:/ { s=0 }
          s && /^[[:space:]]*run:[[:space:]]+node[[:space:]]+scripts\/sensor-reachability\.mjs[[:space:]]*$/ { found=1 }
          END { exit found ? 0 : 1 }
        ' "$WF"; then
    ok "sensors job has run: node scripts/sensor-reachability.mjs"
  else
    bad "sensors job does not run node scripts/sensor-reachability.mjs"
  fi
fi
if grep -nE 'sensor-reachability\.mjs.*\|\|[[:space:]]*true' "$WF" >/dev/null 2>&1; then
  bad "reachability step swallows failure with || true"
else
  ok "reachability step is not wrapped in || true"
fi

echo "# AC5: DCO step present; unsigned fixture red; signed green; push skip visible"

extract_dco_run() {
  awk '
    function leading(s,    n) {
      n = 0
      while (substr(s, n+1, 1) == " ") n++
      return n
    }
    $0 ~ /^[[:space:]]*- name: DCO trailer check[[:space:]]*$/ { hit=1; next }
    hit && $0 ~ /^[[:space:]]*- name:/ { exit }
    hit && match($0, /^[[:space:]]+run:[[:space:]]*[|]/) { inrun=1; rind=leading($0); next }
    inrun {
      if (length($0) && leading($0) <= rind && $0 ~ /^[[:space:]]*(- |[A-Za-z0-9_]+:)/) exit
      prefix = rind + 2
      if (leading($0) >= prefix) print substr($0, prefix + 1)
      else print $0
    }
  ' "$WF"
}

DCO_SCRIPT="$ROOT/dco-step.sh"
extract_dco_run > "$DCO_SCRIPT"
if grep -q 'git rev-list' "$DCO_SCRIPT" \
   && grep -q 'interpret-trailers --parse' "$DCO_SCRIPT" \
   && grep -q 'HEAD_SHA' "$DCO_SCRIPT" \
   && grep -qE 'BASE_SHA\}?\.\.\$\{HEAD_SHA' "$DCO_SCRIPT"; then
  ok "extracted DCO step walks git rev-list BASE_SHA..HEAD_SHA and parses trailers"
else
  bad "extracted DCO step missing required commands: $(head -40 "$DCO_SCRIPT")"
fi
if grep -qE '\.\.HEAD(["[:space:]]|$)' "$DCO_SCRIPT"; then
  bad "DCO step still walks ..HEAD (unsigned synthetic merge ref on pull_request)"
else
  ok "DCO step does not walk HEAD as the range end"
fi

awk '
  /^  sensors:/ { s=1 }
  /^  [A-Za-z0-9_-]+:/ && !/^  sensors:/ { s=0 }
  s && /name: DCO trailer check/ { found=1 }
  END { exit found ? 0 : 1 }
' "$WF" && ok "DCO step lives in the sensors job" || bad "DCO step not in sensors job"

# Untrusted interpolation: EVENT_NAME / BASE_SHA / HEAD_SHA come from env:, not run:.
dco_env=$(awk '
  $0 ~ /^[[:space:]]*- name: DCO trailer check[[:space:]]*$/ { hit=1; next }
  hit && $0 ~ /^[[:space:]]*- name:/ { exit }
  hit { print }
' "$WF")
if printf '%s\n' "$dco_env" | grep -q 'EVENT_NAME:'; then
  ok "DCO step passes github.event_name via env:"
else
  bad "DCO step missing EVENT_NAME env"
fi
if printf '%s\n' "$dco_env" | grep -q 'HEAD_SHA: \${{ github.event.pull_request.head.sha }}'; then
  ok "DCO step passes pull_request.head.sha via HEAD_SHA env"
else
  bad "DCO step missing HEAD_SHA env from pull_request.head.sha"
fi

setup_dco_repo() { # setup_dco_repo <signed|unsigned>
  local mode="$1"
  local repo="$ROOT/dco-repo"
  rm -rf "$repo"
  mkdir -p "$repo"
  $GIT init -q "$repo"
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  echo base > "$repo/README.md"
  $GIT -C "$repo" add README.md
  $GIT -C "$repo" commit -q -m "base"
  $GIT -C "$repo" checkout -q -b feat/dco
  echo work >> "$repo/README.md"
  if [[ "$mode" == "signed" ]]; then
    $GIT -C "$repo" commit -q -s -am "work"
  else
    $GIT -C "$repo" commit -q -am "work"
  fi
  echo "$repo"
}

run_dco() { # run_dco <repo> <event> [head_sha] -> sets DCO_OUT DCO_RC
  local repo="$1" event="$2"
  local head_sha="${3-}"
  local summary="$ROOT/dco-summary.md"
  : > "$summary"
  local base
  base=$(git -C "$repo" rev-parse --verify refs/heads/main)
  if [[ -z "$head_sha" ]]; then
    head_sha=$(git -C "$repo" rev-parse --verify HEAD)
  fi
  DCO_OUT=$(
    cd "$repo" || exit 99
    EVENT_NAME="$event" BASE_SHA="$base" HEAD_SHA="$head_sha" \
      GITHUB_STEP_SUMMARY="$summary" \
      bash "$DCO_SCRIPT" 2>&1
  )
  DCO_RC=$?
  DCO_SUMMARY=$(cat "$summary")
}

REPO_U=$(setup_dco_repo unsigned)
run_dco "$REPO_U" pull_request
unsigned_sha=$(git -C "$REPO_U" rev-parse --verify HEAD)
if [[ "$DCO_RC" -ne 0 ]] && printf '%s\n' "$DCO_OUT" | grep -q "$unsigned_sha"; then
  ok "AC5: unsigned commit in fixture repo is red and prints the SHA"
else
  bad "unsigned DCO (rc=$DCO_RC out=$DCO_OUT want sha=$unsigned_sha)"
fi

REPO_S=$(setup_dco_repo signed)
run_dco "$REPO_S" pull_request
if [[ "$DCO_RC" -eq 0 ]]; then
  ok "AC5: signed commit in fixture repo is green"
else
  bad "signed DCO (rc=$DCO_RC out=$DCO_OUT)"
fi

# Base stays unsigned; only the range is checked.
run_dco "$REPO_S" pull_request
if [[ "$DCO_RC" -eq 0 ]]; then
  ok "unsigned base commit outside merge-base..HEAD is ignored"
else
  bad "unsigned base poisoned the range (rc=$DCO_RC out=$DCO_OUT)"
fi

run_dco "$REPO_S" push
if [[ "$DCO_RC" -eq 0 ]] \
   && printf '%s\n' "$DCO_OUT" | grep -q '::notice::DCO trailer check skipped' \
   && printf '%s\n' "$DCO_SUMMARY" | grep -qi 'skipped'; then
  ok "AC5: push is a visible skip (notice + step summary), not silent"
else
  bad "push skip (rc=$DCO_RC out=$DCO_OUT summary=$DCO_SUMMARY)"
fi

echo "# finding 1: signed PR + unsigned synthetic merge at HEAD is green via HEAD_SHA"
REPO_M="$ROOT/dco-synth-merge"
rm -rf "$REPO_M"
mkdir -p "$REPO_M"
$GIT init -q "$REPO_M"
git -C "$REPO_M" symbolic-ref HEAD refs/heads/main
echo base > "$REPO_M/README.md"
$GIT -C "$REPO_M" add README.md
$GIT -C "$REPO_M" commit -q -m "base"
$GIT -C "$REPO_M" checkout -q -b feat/dco
echo work >> "$REPO_M/README.md"
$GIT -C "$REPO_M" commit -q -s -am "work"
DCO_PR_HEAD=$(git -C "$REPO_M" rev-parse --verify HEAD)
# Detach at main so the merge does not move refs/heads/main (GitHub's
# refs/pull/N/merge is not the base branch). Merge without -s → unsigned.
$GIT -C "$REPO_M" checkout -q --detach main
$GIT -C "$REPO_M" merge -q --no-ff -m "Merge feat/dco" feat/dco
DCO_MERGE=$(git -C "$REPO_M" rev-parse --verify HEAD)
# Fixture validity: the synthetic merge itself is unsigned.
run_dco "$REPO_M" pull_request "$DCO_MERGE"
if [[ "$DCO_RC" -ne 0 ]] && printf '%s\n' "$DCO_OUT" | grep -q "$DCO_MERGE"; then
  ok "unsigned synthetic merge is red when it is the range head"
else
  bad "synthetic merge was not unsigned (rc=$DCO_RC out=$DCO_OUT merge=$DCO_MERGE)"
fi
# Production shape: HEAD is the unsigned merge; HEAD_SHA is the signed PR tip.
run_dco "$REPO_M" pull_request "$DCO_PR_HEAD"
if [[ "$DCO_RC" -eq 0 ]]; then
  ok "finding 1: signed branch + unsigned synthetic merge at HEAD is green via HEAD_SHA"
else
  bad "synthetic merge poisoned PR range (rc=$DCO_RC out=$DCO_OUT head=$DCO_PR_HEAD merge=$DCO_MERGE)"
fi

echo "# finding 2: Signed-off-by in the body is not a trailer"
REPO_B="$ROOT/dco-body-bait"
rm -rf "$REPO_B"
mkdir -p "$REPO_B"
$GIT init -q "$REPO_B"
git -C "$REPO_B" symbolic-ref HEAD refs/heads/main
echo base > "$REPO_B/README.md"
$GIT -C "$REPO_B" add README.md
$GIT -C "$REPO_B" commit -q -m "base"
$GIT -C "$REPO_B" checkout -q -b feat/dco
echo work >> "$REPO_B/README.md"
$GIT -C "$REPO_B" add README.md
cat > "$ROOT/dco-bait-msg" <<'EOF'
work

Discusses placement.

Signed-off-by: gibson-sensor <sensor@gibson.invalid>

This paragraph after the blank line means Git does not treat the
Signed-off-by line as a trailer.
EOF
$GIT -C "$REPO_B" commit -q -F "$ROOT/dco-bait-msg"
bait_sha=$(git -C "$REPO_B" rev-parse --verify HEAD)
bait_body=$(git -C "$REPO_B" log -1 --format=%B "$bait_sha")
if ! printf '%s\n' "$bait_body" | grep -q '^Signed-off-by:'; then
  bad "body-bait fixture lost the Signed-off-by body line"
elif printf '%s\n' "$bait_body" | git interpret-trailers --parse | grep -q '^Signed-off-by:'; then
  bad "body-bait fixture was parsed as a real trailer (not a body-grep witness)"
else
  ok "body-bait fixture: body grep would pass; interpret-trailers has no Signed-off-by"
fi
run_dco "$REPO_B" pull_request
if [[ "$DCO_RC" -ne 0 ]] && printf '%s\n' "$DCO_OUT" | grep -q "$bait_sha"; then
  ok "finding 2: body-line Signed-off-by that is not a trailer is red"
else
  bad "body-bait DCO (rc=$DCO_RC out=$DCO_OUT want sha=$bait_sha)"
fi

echo "# live baseline is a non-negative integer ratchet"
if node -e '
  const b = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  if (b.schema !== "gibson.sensor-reachability-baseline.v1") process.exit(2);
  if (!Number.isInteger(b.orphanMax) || b.orphanMax < 0) process.exit(3);
' "$BASELINE"; then
  ok "committed baseline schema and orphanMax are well-formed"
else
  bad "committed baseline is malformed"
fi

if [[ "$live_rc" -eq 0 ]]; then
  ok "live tree orphan count is within the committed baseline"
else
  bad "live tree exceeds baseline (rc=$live_rc err=$(cat "$ROOT/live.err") out=$live_out)"
fi


echo "# Codex #317 round 2: assignment value, sibling-tree prefix, quoted/if/here-string forms, symlinks"
FX="$ROOT/fx-r2"
seed_fixture "$FX"
for s in assigned sibling quoted ifcond herestr; do printf '%s\n' '#!/bin/bash' 'echo x' > "$FX/scripts/$s.sh"; done
ln -s orphan.sh "$FX/scripts/linked.sh"
ln -s does-not-exist.sh "$FX/scripts/dangling.sh"
cat > "$FX/.github/workflows/r2.yml" <<'YML'
name: r2
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: TARGET=scripts/assigned.sh echo done
      - run: bash fixtures/scripts/sibling.sh
      - run: "bash" scripts/quoted.sh
      - run: if scripts/ifcond.sh; then echo ok; fi
      - run: bash <<< 'scripts/herestr.sh'
YML
write_baseline "$FX/config/sensor-reachability-baseline.v1.json" 9 orphan.sh
run_sensor "$FX"
printf '%s\n' "$OUT" | grep -q $'ORPHAN\tscripts/assigned.sh' && ok "r2-1: VAR=scripts/x.sh value is not an invocation" || bad "r2-1: assignment value counted: $(printf '%s\n' "$OUT" | grep assigned)"
printf '%s\n' "$OUT" | grep -q $'ORPHAN\tscripts/sibling.sh' && ok "r2-2: fixtures/scripts/x.sh does not reach scripts/x.sh" || bad "r2-2: sibling tree matched: $(printf '%s\n' "$OUT" | grep sibling)"
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/quoted.sh' && ok "r2-3a: \"bash\" scripts/x.sh invokes" || bad "r2-3a quoted interpreter missed"
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/ifcond.sh' && ok "r2-3b: if scripts/x.sh; then invokes" || bad "r2-3b if-condition missed"
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/herestr.sh' && ok "r2-3c: bash <<< 'scripts/x.sh' invokes" || bad "r2-3c here-string missed"
printf '%s\n' "$OUT" | grep -q $'ORPHAN\tscripts/linked.sh' && ok "r2-4: symlinked script is inventoried (ORPHAN when uncalled)" || bad "r2-4 symlink escaped: $(printf '%s\n' "$OUT" | grep -c linked)"
printf '%s\n' "$OUT" | grep -q $'ORPHAN\tscripts/dangling.sh' && ok "r2-4: dangling symlink is inventoried as an orphan" || bad "r2-4 dangling symlink escaped"

echo

echo "# Codex #317 findings 3-5: invocation position, ./ boundary, committed-baseline ratchet"
FX="$ROOT/fx-inv"
seed_fixture "$FX"
printf '%s\n' '#!/bin/bash' 'echo x' > "$FX/scripts/echoed.sh"
printf '%s\n' '#!/bin/bash' 'echo x' > "$FX/scripts/envval.sh"
printf '%s\n' '#!/bin/bash' 'echo x' > "$FX/scripts/heredoc.sh"
printf '%s\n' '#!/bin/bash' 'echo x' > "$FX/scripts/dotslash.sh"
printf '%s\n' '#!/bin/bash' 'echo x' > "$FX/scripts/flagged.sh"
printf '%s\n' '#!/bin/bash' 'echo x' > "$FX/scripts/piped.sh"
cat > "$FX/.github/workflows/w.yml" <<'YML'
name: w
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo scripts/echoed.sh
      - run: cat scripts/echoed.sh
        env:
          TARGET: scripts/envval.sh
      - run: |
          cat <<'DOC'
          scripts/heredoc.sh
          DOC
      - run: bash ./scripts/dotslash.sh
      - run: FOO=1 bash -x scripts/flagged.sh --arg scripts/echoed.sh
      - run: true | node scripts/piped.sh
YML
write_baseline "$FX/config/sensor-reachability-baseline.v1.json" 9 orphan.sh
run_sensor "$FX"
for s in echoed envval heredoc; do
  printf '%s\n' "$OUT" | grep -q $'ORPHAN\tscripts/'"$s"'.sh' \
    && ok "finding 3: scripts/$s.sh named but not executed is ORPHAN" \
    || bad "finding 3: scripts/$s.sh counted reachable: $(printf '%s\n' "$OUT" | grep "$s")"
done
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/dotslash.sh' \
  && ok "finding 4: bash ./scripts/dotslash.sh is REACHABLE" \
  || bad "finding 4: ./ prefix missed: $(printf '%s\n' "$OUT" | grep dotslash)"
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/flagged.sh' \
  && ok "interpreter with flags and env prefix invokes (FOO=1 bash -x scripts/flagged.sh)" \
  || bad "flagged invocation missed: $(printf '%s\n' "$OUT" | grep flagged)"
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/piped.sh' \
  && ok "after a pipe, node scripts/piped.sh invokes" \
  || bad "piped invocation missed: $(printf '%s\n' "$OUT" | grep piped)"
printf '%s\n' "$OUT" | grep -q $'REACHABLE\tscripts/called.sh' \
  && ok "control: bash scripts/called.sh still REACHABLE" || bad "control regressed"

FX="$ROOT/fx-ratchet"
seed_fixture "$FX"
( cd "$FX" && $GIT init -q && $GIT add -A && $GIT commit -q -m base && $GIT update-ref refs/remotes/origin/main HEAD ) || bad "ratchet fixture git setup"
printf '%s\n' '#!/bin/bash' 'echo x' > "$FX/scripts/new-orphan.sh"
write_baseline "$FX/config/sensor-reachability-baseline.v1.json" 2 orphan.sh new-orphan.sh
run_sensor "$FX"
if [[ "$RC" -eq 1 ]] && printf '%s\n' "$ERR" | grep -q 'HIGHER than the committed'; then
  ok "finding 5: hand-raised orphanMax (1→2) with a new orphan is RED against origin/main"
else
  bad "finding 5: hand-raise passed (rc=$RC err=$ERR)"
fi
write_baseline "$FX/config/sensor-reachability-baseline.v1.json" 1 orphan.sh
run_sensor "$FX"
[[ "$RC" -eq 1 ]] && ok "finding 5 control: new orphan over the committed max is still red (count)" || bad "count ratchet regressed (rc=$RC)"
rm -f "$FX/scripts/new-orphan.sh"; run_sensor "$FX"
[[ "$RC" -eq 0 ]] && ok "finding 5 control: at the committed baseline → green" || bad "clean tree red (rc=$RC err=$ERR)"
run_sensor "$FX" --ratchet-ref refs/does/not/exist
[[ "$RC" -eq 0 ]] && printf '%s\n' "$ERR" | grep -q 'no committed baseline' && ok "unresolvable ratchet ref → note, working-tree check only" || bad "unresolvable ref handling (rc=$RC err=$ERR)"

echo "sensor-reachability.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
