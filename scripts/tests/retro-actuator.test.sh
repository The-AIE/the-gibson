#!/usr/bin/env bash
# retro-actuator.test.sh — offline sensors for scripts/retro-actuator.mjs (#569).
# Network-free. Bash 3.2 compatible. A fake gh is the only gh on PATH.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
TOOL="$REPO_ROOT/scripts/retro-actuator.mjs"
FIX="$SCRIPT_DIR/fixtures/retro-actuator"
PASS=0
FAIL=0

SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_C=cccccccccccccccccccccccccccccccccccccccc
SHA_D=dddddddddddddddddddddddddddddddddddddddd
SHA_E=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
SHA_F=ffffffffffffffffffffffffffffffffffffffff
RAW88='Error: assert foo.ts:88 expected 1 run_id=987654321 sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa at 2026-10-25T12:00:00Z'
NOW0=2026-01-01T00:00:00Z
NOW1=2026-01-02T00:00:00Z
NOW7=2026-01-08T00:00:00Z
NOW14=2026-01-15T00:00:00Z
CANARY=canary-value-569
DEPLOY_OK='{"remediation_sha":"cccccccccccccccccccccccccccccccccccccccc","workers_evidence_ref":"workers-ran-sha-ref","recorded_at":"2026-01-01T00:00:03Z"}'
DEPLOY_UNKNOWN='{"remediation_sha":"cccccccccccccccccccccccccccccccccccccccc","workers_evidence_ref":"unknown","recorded_at":"2026-01-01T00:00:03Z"}'
DEPLOY_MISSING='{}'
EFFECTIVE_OK='{"detector_health":"healthy","exposure_start":"2026-01-01T00:00:00Z","exposure_end":"2026-01-01T01:00:00Z","minimum_sample":2,"sample_count":2,"measurement_ref":"measure-1"}'
EFFECTIVE_UNKNOWN='{"detector_health":"healthy","exposure_start":"2026-01-01T00:00:00Z","exposure_end":"2026-01-01T01:00:00Z","minimum_sample":2,"sample_count":2,"measurement_ref":"unknown"}'
EFFECTIVE_STALE='{"detector_health":"stale","exposure_start":"2026-01-01T00:00:00Z","exposure_end":"2026-01-01T01:00:00Z","minimum_sample":2,"sample_count":2,"measurement_ref":"measure-1"}'
EFFECTIVE_SAMPLE='{"detector_health":"healthy","exposure_start":"2026-01-01T00:00:00Z","exposure_end":"2026-01-01T01:00:00Z","minimum_sample":2,"sample_count":1,"measurement_ref":"measure-1"}'

ok() { printf '  ok   — %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL — %s\n' "$1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gibson-retro-actuator.XXXXXX")
# Bash 3.2 copies the EXIT trap into a background command and leaves
# BASH_SUBSHELL at 0 there. Killing that child before exec ran this trap
# and deleted TMP under the main shell. $$ is the main shell in both, so
# compare the command's own pid (the parent of a fresh sh) instead.
MAIN_PID=$(sh -c 'echo $PPID')
cleanup() {
  trap - EXIT
  self=$(sh -c 'echo $PPID')
  if [[ "$self" != "$MAIN_PID" ]]; then
    return 0
  fi
  if [[ -f "$TMP/holder.pid" ]]; then
    kill "$(cat "$TMP/holder.pid")" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
ERR_FILE="$TMP/err"
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/empty-root"
NODE_REAL=$(command -v node)
cat > "$BIN/node" << EOF
#!/bin/bash
exec "$NODE_REAL" "\$@"
EOF
chmod +x "$BIN/node"

cat > "$BIN/gh" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
printf '%s\n' 'TOKEN-LEAK' >&2
mode="${GH_MODE:-ok}"
case "$mode" in
  ok)
    printf '%s\n' 'https://github.com/The-AIE/the-gibson/issues/569'
    exit 0
    ;;
  fail)
    printf '%s\n' 'gh failed' >&2
    exit 1
    ;;
  badurl)
    printf '%s\n' 'not-a-url'
    exit 0
    ;;
  *)
    exit 98
    ;;
esac
EOF
chmod +x "$BIN/gh"

export PATH="$BIN:/usr/bin:/bin"
export GH_LOG="$TMP/gh.log"
export GH_MODE="ok"
export RETRO_CANARY="$CANARY"
: > "$GH_LOG"

for s in "$SHA_A" "$SHA_B" "$SHA_C" "$SHA_D" "$SHA_E" "$SHA_F"; do
  if [[ ! "$s" =~ ^[0-9a-f]{40}$ ]]; then
    bad "sha constant is not 40 hex"
  fi
done

run_tool() {
  LAST_RC=0
  if [[ $# -eq 0 ]]; then
    LAST_OUT=$(node "$TOOL" 2>"$ERR_FILE") || LAST_RC=$?
  else
    LAST_OUT=$(node "$TOOL" "$@" 2>"$ERR_FILE") || LAST_RC=$?
  fi
  LAST_ERR=$(cat "$ERR_FILE")
  printf '%s\n' "$LAST_OUT" > "$TMP/last.json"
}

report_eval() {
  REPORT_EXPR=$1 REPORT_FILE=$TMP/last.json node --input-type=module -e '
import { readFileSync } from "node:fs";
const expr = process.env.REPORT_EXPR;
let text;
try { text = readFileSync(process.env.REPORT_FILE, "utf8"); }
catch (error) { process.stderr.write("no report\n"); process.exit(1); }
let r;
try { r = JSON.parse(text); }
catch (error) { process.stderr.write("report is not json\n"); process.exit(1); }
let ok = false;
try { ok = Boolean(eval(expr)); }
catch (error) { process.stderr.write(String(error) + "\n"); process.exit(1); }
if (!ok) {
  process.stderr.write(JSON.stringify({
    evaluation: r.evaluation,
    detector: r.detector,
    mode: r.mode,
    trust: r.trust,
    new_keys_trusted: r.new_keys_trusted,
    unknown_reason: r.unknown_reason,
    pending_count: r.pending_count,
    gh_invocations: r.gh_invocations,
    incidents: r.incidents,
    issue_requests: r.issue_requests,
    rejected_transitions: r.rejected_transitions,
    escalations: r.escalations,
    drifted_keys: r.drifted_keys
  }) + "\n");
  process.exit(1);
}
'
}

state_eval() {
  STATE_FILE=$1 STATE_EXPR=$2 node --input-type=module -e '
import { readFileSync } from "node:fs";
const s = JSON.parse(readFileSync(process.env.STATE_FILE, "utf8"));
let ok = false;
try { ok = Boolean(eval(process.env.STATE_EXPR)); }
catch (error) { process.stderr.write(String(error) + "\n"); process.exit(1); }
if (!ok) {
  const brief = Object.values(s.incidents).map((i) => ({
    state: i.state,
    used: i.repair_attempts_used,
    budget: i.repair_budget,
    requeue: i.automatic_requeue,
    attempts: i.attempts.length,
    human: i.escalation && i.escalation.human,
    real: i.issue_requests.filter((req) => req.status === "planned" || req.status === "creating" || req.status === "created").length,
    schema: i.signature_schema_version
  }));
  process.stderr.write(JSON.stringify({
    pending: Object.keys(s.pending).length,
    seen: s.seen_event_ids.length,
    trust: s.trusted_signature_schema_version,
    incidents: brief
  }) + "\n");
  process.exit(1);
}
'
}

check() {
  local name="$1" want="$2" expr="$3"
  shift 3
  run_tool "$@"
  if [[ "$LAST_RC" -ne "$want" ]]; then
    bad "$name (rc=$LAST_RC want=$want err=$LAST_ERR)"
    return
  fi
  if [[ -z "$expr" ]]; then
    ok "$name"
    return
  fi
  if report_eval "$expr"; then
    ok "$name"
  else
    bad "$name (report)"
  fi
}

expect_state() {
  local name="$1" file="$2" expr="$3"
  if state_eval "$file" "$expr"; then
    ok "$name"
  else
    bad "$name (state)"
  fi
}

absent() {
  local name="$1" path="$2"
  if [[ -e "$path" ]]; then
    bad "$name"
  else
    ok "$name"
  fi
}

dry() {
  local state="$1" events="$2" now="$3"
  shift 3
  run_tool --events "$events" --state "$state" --now "$now" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human "$@"
}

write_ci() {
  local dest="$1" attempt="$2" sha="$3" at="$4" raw="$5" det="$6"
  CI_DEST=$dest CI_ATTEMPT=$attempt CI_SHA=$sha CI_AT=$at CI_RAW=$raw CI_DET=$det \
    node --input-type=module -e '
import { writeFileSync } from "node:fs";
writeFileSync(process.env.CI_DEST, JSON.stringify({
  kind: "ci-failure",
  repo: "The-AIE/the-gibson",
  attempt_id: process.env.CI_ATTEMPT,
  head_sha: process.env.CI_SHA,
  observed_at: process.env.CI_AT,
  raw_signature: process.env.CI_RAW,
  detector_version: process.env.CI_DET,
  detector_health: "healthy"
}) + "\n");
'
}

write_life() {
  local dest="$1" state="$2" to="$3" at="$4" evidence="$5"
  LIFE_DEST=$dest LIFE_STATE=$state LIFE_TO=$to LIFE_AT=$at LIFE_EVIDENCE=$evidence \
    node --input-type=module -e '
import { readFileSync, writeFileSync } from "node:fs";
const s = JSON.parse(readFileSync(process.env.LIFE_STATE, "utf8"));
const keys = Object.keys(s.incidents);
if (keys.length !== 1) {
  process.stderr.write("expected one incident, got " + keys.length + "\n");
  process.exit(2);
}
writeFileSync(process.env.LIFE_DEST, JSON.stringify({
  kind: "lifecycle",
  repo: "The-AIE/the-gibson",
  observed_at: process.env.LIFE_AT,
  detector_health: "healthy",
  detector_version: "det-1",
  incident_key: keys[0],
  to: process.env.LIFE_TO,
  evidence: JSON.parse(process.env.LIFE_EVIDENCE)
}) + "\n");
'
}

write_override() {
  local dest="$1" state="$2" actor="$3" at="$4"
  OV_DEST=$dest OV_STATE=$state OV_ACTOR=$actor OV_AT=$at \
    node --input-type=module -e '
import { readFileSync, writeFileSync } from "node:fs";
const s = JSON.parse(readFileSync(process.env.OV_STATE, "utf8"));
const keys = Object.keys(s.incidents);
if (keys.length !== 1) {
  process.stderr.write("expected one incident\n");
  process.exit(2);
}
writeFileSync(process.env.OV_DEST, JSON.stringify({
  kind: "budget-override",
  repo: "The-AIE/the-gibson",
  observed_at: process.env.OV_AT,
  detector_health: "healthy",
  detector_version: "det-1",
  incident_key: keys[0],
  actor: process.env.OV_ACTOR
}) + "\n");
'
}

write_drift_seed() {
  local dest="$1"
  SEED=$dest node --input-type=module -e '
import { writeFileSync } from "node:fs";
const raw = "Error: assert foo.ts:88 expected 1";
const key = JSON.stringify(["The-AIE/the-gibson", raw, 0]);
const sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const incident = {
  incident_key: key,
  repo: "The-AIE/the-gibson",
  normalized_signature: raw,
  signature_schema_version: 0,
  raw_signatures: [raw],
  detector_versions: ["det-1"],
  state: "detected",
  attempts: [{ attempt_id: "old", head_shas: [sha], event_ids: ["old-event"], observed_at: "2026-01-01T00:00:00Z" }],
  issue_requests: [],
  repair_attempts_used: 0,
  repair_budget: 2,
  budget_overrides: [],
  escalation: null,
  escalation_history: [],
  automatic_requeue: "allowed",
  revoked_claims: [],
  history: [{ from: null, to: "detected", at: "2026-01-01T00:00:00Z" }],
  evidence: {}
};
const state = {
  schema: "gibson.retro-actuator-state.v1",
  trusted_signature_schema_version: 0,
  trusted_detector_versions: ["det-1"],
  drift_gate: null,
  incidents: {},
  pending: {},
  seen_event_ids: []
};
state.incidents[key] = incident;
writeFileSync(process.env.SEED, JSON.stringify(state) + "\n");
'
}

walk_to_effective() {
  local state="$1" budget="$2" escalate="$3" day="$4"
  local n=1 to evidence at
  for to in triaged artifact-verified deployed effective; do
    at=$(printf '2026-01-%sT00:00:0%sZ' "$day" "$n")
    if [[ "$to" == "deployed" ]]; then
      evidence=$DEPLOY_OK
    elif [[ "$to" == "effective" ]]; then
      evidence=$EFFECTIVE_OK
    else
      evidence='{}'
    fi
    if ! write_life "$TMP/walk.jsonl" "$state" "$to" "$at" "$evidence"; then
      bad "walk write $to day $day"
      return 1
    fi
    if [[ -n "$escalate" ]]; then
      run_tool --events "$TMP/walk.jsonl" --state "$state" --now "$at" --root "$REPO_ROOT" --repair-budget "$budget" --escalate-to "$escalate"
    else
      run_tool --events "$TMP/walk.jsonl" --state "$state" --now "$at" --root "$REPO_ROOT" --repair-budget "$budget"
    fi
    if [[ "$LAST_RC" -ne 0 ]]; then
      bad "walk $to day $day (rc=$LAST_RC err=$LAST_ERR)"
      return 1
    fi
    n=$((n + 1))
  done
  ok "walked to effective on day $day"
}

printf '\n%s\n' "=== syntax, help, usage ==="
if node --check "$TOOL" && node --check "$REPO_ROOT/scripts/lib/retro-signature.mjs"; then
  ok "node --check both modules"
else
  bad "node --check both modules"
fi

run_tool --help
if [[ "$LAST_RC" -eq 0 && "$LAST_OUT" == *"WHAT I'M ASKING"* && "$LAST_OUT" == *"--apply"* ]]; then
  ok "help exits 0 and names --apply"
else
  bad "help exits 0 and names --apply (rc=$LAST_RC)"
fi

run_tool --definitely-not-a-flag </dev/null
if [[ "$LAST_RC" -eq 2 && -z "$LAST_OUT" && "$LAST_ERR" == *"unknown flag:"* ]]; then
  ok "unknown flag exits 2"
else
  bad "unknown flag exits 2 (rc=$LAST_RC err=$LAST_ERR)"
fi

run_tool --events "$FIX/one-attempt.jsonl" --state "$TMP/usage.json" --repair-budget 0
if [[ "$LAST_RC" -eq 2 && -z "$LAST_OUT" && "$LAST_ERR" == *"positive integer"* ]]; then
  ok "repair budget 0 exits 2"
else
  bad "repair budget 0 exits 2 (rc=$LAST_RC err=$LAST_ERR)"
fi

run_tool --events "$FIX/one-attempt.jsonl" --state "$TMP/usage.json" --now not-a-date
if [[ "$LAST_RC" -eq 2 && -z "$LAST_OUT" ]]; then
  ok "bad --now exits 2"
else
  bad "bad --now exits 2 (rc=$LAST_RC err=$LAST_ERR)"
fi
absent "usage wrote no state" "$TMP/usage.json"

printf '\n%s\n' "=== signature ==="
if SIG_LIB="$REPO_ROOT/scripts/lib/retro-signature.mjs" node --input-type=module -e '
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.SIG_LIB).href);
const raw = "Error: assert foo.ts:88 expected 1 run_id=987654321 sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa at 2026-10-25T12:00:00Z";
const other = "Error: assert foo.ts:99 expected 1 run_id=111 sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb at 2026-10-26T01:02:03Z";
const different = "Error: assert bar.ts:10 expected 2";
const want = "Error: assert foo.ts:<line> expected 1 <run> sha=<sha> at <ts>";
const got = mod.normalizeSignature(raw);
if (got !== want || mod.normalizeSignature(other) !== want || mod.normalizeSignature(different) === want) {
  process.stderr.write(got + "\n");
  process.exit(1);
}
if (!got.includes("foo.ts") || !got.includes("expected 1") || got.includes("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") || got.includes(":88")) {
  process.exit(1);
}
if (mod.SIGNATURE_SCHEMA_VERSION !== 1) process.exit(1);
const eid = JSON.parse(mod.eventId({
  repo: "The-AIE/the-gibson",
  attemptId: "a1",
  headSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  detectorVersion: "det-1",
  rawSignature: raw
}));
if (eid.length !== 5 || eid[1] !== "a1" || eid[2] !== "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") process.exit(1);
const key = JSON.parse(mod.incidentKey({
  repo: "The-AIE/the-gibson",
  normalizedSignature: got,
  signatureSchemaVersion: 1
}));
if (key.length !== 3 || key[2] !== 1 || String(key[1]).includes("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") || key.indexOf("a1") !== -1) {
  process.exit(1);
}
'; then
  ok "sha noise collapses"
else
  bad "sha noise collapses"
fi

printf '\n%s\n' "=== dedup ==="
ONE='r.mode==="dry-run" && r.evaluation==="complete" && r.detector==="healthy" && r.trust==="trusted" && r.new_keys_trusted===true && r.gh_invocations===0 && r.incidents.length===1 && r.incidents[0].distinct_attempts===2 && r.incidents[0].real_issue_requests===1 && r.incidents[0].state==="detected" && r.issue_requests.length===1 && r.issue_requests[0].action==="would-create" && /^Repair repeated failure [0-9a-f]{12}$/.test(r.issue_requests[0].title) && r.limits.some((line) => line.includes("does not check that workers run the remediation SHA")) && r.limits.some((line) => line.includes("not a healthy result")) && r.limits.some((line) => line.includes("no live event collector"))'
check "two noisy attempts are one incident" 0 "$ONE" \
  --events "$FIX/two-attempts.jsonl" --state "$TMP/two.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
if [[ -z "$LAST_ERR" ]]; then ok "healthy run is quiet on stderr"; else bad "healthy run is quiet on stderr"; fi
expect_state "state keeps both attempts and one planned issue" "$TMP/two.json" \
  'const i=Object.values(s.incidents)[0]; i.attempts.length===2 && i.issue_requests.length===1 && i.issue_requests[0].status==="planned" && i.issue_requests[0].body.includes("attempt_id=a1") && i.issue_requests[0].body.includes("does not merge pull requests") && i.issue_requests[0].body.includes("does not claim")'

check "replaying the file stays at one request" 0 \
  'r.issue_requests.length===0 && r.incidents.length===1 && r.incidents[0].real_issue_requests===1 && r.incidents[0].distinct_attempts===2' \
  --events "$FIX/two-attempts.jsonl" --state "$TMP/two.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

check "interleaved duplicate delivery is one incident" 0 "$ONE" \
  --events "$FIX/duplicate-delivery.jsonl" --state "$TMP/dup.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

check "stdin matches the file" 0 "$ONE" \
  --events - --state "$TMP/stdin.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human < "$FIX/two-attempts.jsonl"

check "one attempt stays pending" 0 \
  'r.incidents.length===0 && r.pending_count===1 && r.issue_requests.length===0 && r.evaluation==="complete"' \
  --events "$FIX/one-attempt.jsonl" --state "$TMP/one.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

check "same attempt with another sha is not distinct" 0 \
  'r.incidents.length===0 && r.pending_count===1' \
  --events "$FIX/same-attempt-retry.jsonl" --state "$TMP/retry.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "retry keeps one attempt and both shas" "$TMP/retry.json" \
  'const p=Object.values(s.pending)[0]; p.attempts.length===1 && p.attempts[0].head_shas.length===2'

check "same sha with two attempt ids is one incident" 0 \
  'r.incidents.length===1 && r.incidents[0].distinct_attempts===2 && r.issue_requests.length===1' \
  --events "$FIX/different-attempt-same-sha.jsonl" --state "$TMP/samesha.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_ci "$TMP/third.jsonl" a9 "$SHA_C" "2026-01-01T00:00:09Z" "$RAW88" det-1
check "a third attempt does not open a second issue" 0 \
  'r.issue_requests.length===0 && r.incidents[0].distinct_attempts===3 && r.incidents[0].real_issue_requests===1' \
  --events "$TMP/third.jsonl" --state "$TMP/two.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

printf '\n%s\n' "=== review cap ==="
check "review-cap breach opens one incident" 0 \
  'r.incidents.length===1 && r.incidents[0].real_issue_requests===1 && r.issue_requests[0].action==="would-create" && r.issue_requests[0].reason==="review-cap"' \
  --events "$FIX/review-cap-breach.jsonl" --state "$TMP/cap.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

check "review-cap at the cap opens nothing" 0 \
  'r.incidents.length===0 && r.pending_count===0 && r.issue_requests.length===0 && r.evaluation==="complete" && r.detector==="healthy"' \
  --events "$FIX/review-cap-exact.jsonl" --state "$TMP/cap-exact.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
if [[ -f "$TMP/cap-exact.json" ]]; then ok "exact cap still records state"; else bad "exact cap still records state"; fi

check "omitted tier uses the default cap" 0 \
  'r.incidents.length===1 && r.issue_requests.length===1' \
  --events "$FIX/review-cap-default-breach.jsonl" --state "$TMP/cap-default.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
check "omitted tier at the default cap opens nothing" 0 \
  'r.incidents.length===0 && r.issue_requests.length===0' \
  --events "$FIX/review-cap-default-exact.jsonl" --state "$TMP/cap-default-exact.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

check "unknown review tier is UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.detector==="UNKNOWN" && r.unknown_reason==="review cap cannot be resolved"' \
  --events "$FIX/review-cap-unknown-tier.jsonl" --state "$TMP/cap-z.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
absent "unknown tier wrote no state" "$TMP/cap-z.json"
if [[ "$LAST_ERR" == "retro-actuator: UNKNOWN: review cap cannot be resolved" ]]; then
  ok "unknown tier alerts on stderr"
else
  bad "unknown tier alerts on stderr ($LAST_ERR)"
fi

check "lowercase tier is not coerced" 3 \
  'r.evaluation==="UNKNOWN" && r.detector==="UNKNOWN"' \
  --events "$FIX/review-cap-lower-tier.jsonl" --state "$TMP/cap-b.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
absent "lowercase tier wrote no state" "$TMP/cap-b.json"

check "missing review rounds is UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason.includes("review_rounds")' \
  --events "$FIX/review-cap-missing-rounds.jsonl" --state "$TMP/cap-rounds.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
absent "missing rounds wrote no state" "$TMP/cap-rounds.json"

check "missing caps file is UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="review-round caps cannot be read"' \
  --events "$FIX/review-cap-breach.jsonl" --state "$TMP/cap-nocaps.json" --now "$NOW0" --root "$TMP/empty-root" --repair-budget 2 --escalate-to duty-human
absent "missing caps wrote no state" "$TMP/cap-nocaps.json"

check "a single attempt stays pending before the cap breach" 0 \
  'r.incidents.length===0 && r.pending_count===1 && r.issue_requests.length===0' \
  --events "$FIX/one-attempt.jsonl" --state "$TMP/pending-cap.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
check "review-cap keeps the pending attempt" 0 \
  'r.incidents.length===1 && r.incidents[0].distinct_attempts===2 && r.incidents[0].real_issue_requests===1 && r.pending_count===0' \
  --events "$FIX/review-cap-breach.jsonl" --state "$TMP/pending-cap.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

printf '\n%s\n' "=== detector ==="
check "stale detector is UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.detector==="UNKNOWN" && r.unknown_reason==="detector is not healthy" && r.trust==="untrusted"' \
  --events "$FIX/detector-stale.jsonl" --state "$TMP/stale.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
absent "stale detector wrote no state" "$TMP/stale.json"

check "failed detector is UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.detector==="UNKNOWN"' \
  --events "$FIX/detector-failed.jsonl" --state "$TMP/failed.json" --now "$NOW0" --root "$REPO_ROOT"
absent "failed detector wrote no state" "$TMP/failed.json"

check "omitted detector_health is UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.detector==="UNKNOWN" && r.unknown_reason.includes("detector_health")' \
  --events "$FIX/detector-omitted.jsonl" --state "$TMP/omit.json" --now "$NOW0" --root "$REPO_ROOT"
absent "omitted detector wrote no state" "$TMP/omit.json"

check "one stale line makes the batch UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.detector==="UNKNOWN"' \
  --events "$FIX/detector-mixed.jsonl" --state "$TMP/mixed.json" --now "$NOW0" --root "$REPO_ROOT"
absent "mixed detector wrote no state" "$TMP/mixed.json"

check "malformed events are UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason.includes("not JSON")' \
  --events "$FIX/malformed.jsonl" --state "$TMP/bad.json" --now "$NOW0" --root "$REPO_ROOT"
absent "malformed events wrote no state" "$TMP/bad.json"

check "empty events are UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.detector==="UNKNOWN" && r.unknown_reason==="detector is not healthy"' \
  --events "$FIX/empty.jsonl" --state "$TMP/empty.json" --now "$NOW0" --root "$REPO_ROOT"
absent "empty events wrote no state" "$TMP/empty.json"

check "missing events file is UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="events file not found"' \
  --events "$TMP/no-such-events.jsonl" --state "$TMP/missing-events.json" --now "$NOW0" --root "$REPO_ROOT"
absent "missing events wrote no state" "$TMP/missing-events.json"

node -e 'require("fs").writeFileSync(process.argv[1], "x".repeat(70000) + "\n")' "$TMP/big.jsonl"
check "oversize event line is UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason.includes("too long")' \
  --events "$TMP/big.jsonl" --state "$TMP/big-state.json" --now "$NOW0" --root "$REPO_ROOT"
absent "oversize line wrote no state" "$TMP/big-state.json"

printf '\n%s\n' "=== concurrent ==="
node "$TOOL" --events "$FIX/two-attempts.jsonl" --state "$TMP/conc.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human --lock-timeout-ms 5000 >"$TMP/c1.out" 2>"$TMP/c1.err" &
c1=$!
node "$TOOL" --events "$FIX/two-attempts.jsonl" --state "$TMP/conc.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human --lock-timeout-ms 5000 >"$TMP/c2.out" 2>"$TMP/c2.err" &
c2=$!
c1_rc=0
c2_rc=0
wait "$c1" || c1_rc=$?
wait "$c2" || c2_rc=$?
if [[ "$c1_rc" -eq 0 && "$c2_rc" -eq 0 ]] && A="$TMP/c1.out" B="$TMP/c2.out" S="$TMP/conc.json" node --input-type=module -e '
import { readFileSync } from "node:fs";
const load = (p) => JSON.parse(readFileSync(p, "utf8"));
const reports = [load(process.env.A), load(process.env.B)];
const n = reports.reduce((sum, r) => sum + r.issue_requests.filter((x) => x.action === "would-create").length, 0);
const incs = Object.values(load(process.env.S).incidents);
const real = incs.length === 1 ? incs[0].issue_requests.filter((req) => req.status === "planned" || req.status === "creating" || req.status === "created").length : -1;
if (n !== 1 || incs.length !== 1 || real !== 1 || incs[0].attempts.length !== 2) {
  process.stderr.write(JSON.stringify({ n, incidents: incs.length, real }) + "\n");
  process.exit(1);
}
'; then
  ok "concurrent duplicate delivery is one incident"
else
  bad "concurrent duplicate delivery is one incident (rc=$c1_rc/$c2_rc)"
fi

node "$TOOL" --events "$FIX/one-attempt.jsonl" --state "$TMP/inter.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human --lock-timeout-ms 5000 >"$TMP/i1.out" 2>"$TMP/i1.err" &
i1=$!
node "$TOOL" --events "$FIX/second-only.jsonl" --state "$TMP/inter.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human --lock-timeout-ms 5000 >"$TMP/i2.out" 2>"$TMP/i2.err" &
i2=$!
i1_rc=0
i2_rc=0
wait "$i1" || i1_rc=$?
wait "$i2" || i2_rc=$?
if [[ "$i1_rc" -eq 0 && "$i2_rc" -eq 0 ]] && A="$TMP/i1.out" B="$TMP/i2.out" S="$TMP/inter.json" node --input-type=module -e '
import { readFileSync } from "node:fs";
const load = (p) => JSON.parse(readFileSync(p, "utf8"));
const reports = [load(process.env.A), load(process.env.B)];
const n = reports.reduce((sum, r) => sum + r.issue_requests.filter((x) => x.action === "would-create").length, 0);
const incs = Object.values(load(process.env.S).incidents);
if (n !== 1 || incs.length !== 1 || incs[0].attempts.length !== 2) {
  process.stderr.write(JSON.stringify({ n, incidents: incs.length }) + "\n");
  process.exit(1);
}
'; then
  ok "interleaved attempts are one incident"
else
  bad "interleaved attempts are one incident (rc=$i1_rc/$i2_rc)"
fi

node "$TOOL" --events "$FIX/one-attempt.jsonl" --state "$TMP/conc-one.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human --lock-timeout-ms 5000 >"$TMP/o1.out" 2>"$TMP/o1.err" &
o1=$!
node "$TOOL" --events "$FIX/one-attempt.jsonl" --state "$TMP/conc-one.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human --lock-timeout-ms 5000 >"$TMP/o2.out" 2>"$TMP/o2.err" &
o2=$!
o1_rc=0
o2_rc=0
wait "$o1" || o1_rc=$?
wait "$o2" || o2_rc=$?
if [[ "$o1_rc" -eq 0 && "$o2_rc" -eq 0 ]] && state_eval "$TMP/conc-one.json" 'Object.keys(s.incidents).length===0 && Object.keys(s.pending).length===1'; then
  ok "concurrent single attempt opens no incident"
else
  bad "concurrent single attempt opens no incident (rc=$o1_rc/$o2_rc)"
fi

printf '\n%s\n' "=== lifecycle, flood, budget ==="
LIFE=$TMP/life.json
check "lifecycle seed" 0 'r.incidents.length===1 && r.incidents[0].state==="detected"' \
  --events "$FIX/two-attempts.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_life "$TMP/step.jsonl" "$LIFE" deployed "2026-01-01T00:10:00Z" "$DEPLOY_OK"
check "detected to deployed is illegal" 1 \
  'r.evaluation==="complete" && r.rejected_transitions.length===1 && r.rejected_transitions[0].reason==="illegal-transition" && r.incidents[0].state==="detected"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
check "illegal transition stays rejected on replay" 1 \
  'r.rejected_transitions.length===1 && r.rejected_transitions[0].reason==="illegal-transition" && r.incidents[0].state==="detected"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_life "$TMP/step.jsonl" "$LIFE" triaged "2026-01-01T00:10:01Z" '{}'
check "detected to triaged" 0 'r.incidents[0].state==="triaged" && r.rejected_transitions.length===0' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
check "successful transition replay is a no-op" 0 'r.incidents[0].state==="triaged" && r.rejected_transitions.length===0' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "triaged history is not duplicated" "$LIFE" \
  'const i=Object.values(s.incidents)[0]; i.state==="triaged" && i.history.length===2'

write_life "$TMP/step.jsonl" "$LIFE" artifact-verified "2026-01-01T00:10:02Z" '{}'
check "triaged to artifact-verified" 0 'r.incidents[0].state==="artifact-verified"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_life "$TMP/step.jsonl" "$LIFE" deployed "2026-01-01T00:10:03Z" "$DEPLOY_MISSING"
check "deployed without a sha is rejected" 1 \
  'r.rejected_transitions[0].reason==="missing-remediation-sha" && r.incidents[0].state==="artifact-verified"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_life "$TMP/step.jsonl" "$LIFE" deployed "2026-01-01T00:10:04Z" "$DEPLOY_UNKNOWN"
check "deployed evidence unknown is rejected" 1 \
  'r.rejected_transitions[0].reason==="workers-evidence-unknown" && r.incidents[0].state==="artifact-verified"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_life "$TMP/step.jsonl" "$LIFE" deployed "2026-01-01T00:10:05Z" "$DEPLOY_OK"
check "deployed with evidence is stored" 0 'r.incidents[0].state==="deployed"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "deployed evidence is the sha we passed" "$LIFE" \
  'const i=Object.values(s.incidents)[0]; i.evidence.deployed.remediation_sha==="cccccccccccccccccccccccccccccccccccccccc"'

write_life "$TMP/step.jsonl" "$LIFE" effective "2026-01-01T00:10:06Z" "$EFFECTIVE_UNKNOWN"
check "measurement_ref unknown is rejected" 1 \
  'r.rejected_transitions[0].reason==="measurement-unknown" && r.incidents[0].state==="deployed"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_life "$TMP/step.jsonl" "$LIFE" effective "2026-01-01T00:10:07Z" "$EFFECTIVE_STALE"
check "effective evidence with a stale detector is rejected" 1 \
  'r.rejected_transitions[0].reason==="detector-not-healthy" && r.incidents[0].state==="deployed"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_life "$TMP/step.jsonl" "$LIFE" effective "2026-01-01T00:10:08Z" "$EFFECTIVE_SAMPLE"
check "sample below the minimum is rejected" 1 \
  'r.rejected_transitions[0].reason==="sample-below-minimum" && r.incidents[0].state==="deployed"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_life "$TMP/step.jsonl" "$LIFE" effective "2026-01-01T00:10:09Z" "$EFFECTIVE_OK"
check "effective with evidence is stored" 0 'r.incidents[0].state==="effective" && r.evaluation==="complete"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_ci "$TMP/esc.jsonl" a3 "$SHA_C" "$NOW1" "$RAW88" det-1
check "flood suppresses inside the week" 0 \
  'r.evaluation==="complete" && r.issue_requests.length===1 && r.issue_requests[0].action==="suppressed-flood" && r.incidents[0].repair_attempts_used===1 && r.incidents[0].real_issue_requests===1 && r.incidents[0].state==="reopened"' \
  --events "$TMP/esc.jsonl" --state "$LIFE" --now "$NOW1" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "escape revokes the effective claim" "$LIFE" \
  'const i=Object.values(s.incidents)[0]; i.state==="reopened" && i.revoked_claims.some((c) => c.claim==="effective") && i.repair_attempts_used===1'

walk_to_effective "$LIFE" 2 duty-human 02
write_ci "$TMP/esc.jsonl" a4 "$SHA_D" "$NOW7" "$RAW88" det-1
check "a new issue is allowed on the seventh day" 0 \
  'r.issue_requests[0].action==="would-create" && r.incidents[0].repair_attempts_used===2 && r.incidents[0].real_issue_requests===2 && r.incidents[0].state==="reopened"' \
  --events "$TMP/esc.jsonl" --state "$LIFE" --now "$NOW7" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
walk_to_effective "$LIFE" 2 duty-human 08

write_ci "$TMP/esc.jsonl" a5 "$SHA_E" "$NOW14" "$RAW88" det-1
check "exhausted budget escalates to the named human" 0 \
  'r.evaluation==="complete" && r.issue_requests[0].action==="suppressed-budget" && r.incidents[0].automatic_requeue==="blocked" && r.incidents[0].escalation.human==="duty-human" && r.incidents[0].repair_attempts_used===2 && r.incidents[0].real_issue_requests===2' \
  --events "$TMP/esc.jsonl" --state "$LIFE" --now "$NOW14" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_ci "$TMP/esc.jsonl" a7 "$SHA_F" "$NOW14" "$RAW88" det-1
check "a later run keeps the named escalation" 0 \
  'r.evaluation==="complete" && r.incidents[0].escalation.human==="duty-human" && r.incidents[0].automatic_requeue==="blocked" && r.incidents[0].real_issue_requests===2' \
  --events "$TMP/esc.jsonl" --state "$LIFE" --now "$NOW14" --root "$REPO_ROOT" --repair-budget 2

write_override "$TMP/step.jsonl" "$LIFE" unknown "$NOW14"
check "unknown override actor is rejected" 1 \
  'r.evaluation==="complete" && r.rejected_transitions[0].reason==="unnamed-actor" && r.incidents[0].repair_attempts_used===2 && r.incidents[0].automatic_requeue==="blocked"' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW14" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
check "unknown override stays rejected on replay" 1 \
  'r.rejected_transitions[0].reason==="unnamed-actor" && r.incidents[0].repair_attempts_used===2' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW14" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

write_override "$TMP/step.jsonl" "$LIFE" duty-human "$NOW14"
check "named override resets the budget" 0 \
  'r.evaluation==="complete" && r.rejected_transitions.length===0 && r.incidents[0].repair_attempts_used===0 && r.incidents[0].automatic_requeue==="allowed" && r.incidents[0].escalation===null' \
  --events "$TMP/step.jsonl" --state "$LIFE" --now "$NOW14" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "override keeps the actor and timestamp" "$LIFE" \
  'const i=Object.values(s.incidents)[0]; i.budget_overrides.length===1 && i.budget_overrides[0].actor==="duty-human" && i.budget_overrides[0].at==="2026-01-15T00:00:00Z"'

write_ci "$TMP/esc.jsonl" a6 "$SHA_A" "$NOW14" "$RAW88" det-1
check "reset budget can open one more issue" 0 \
  'r.issue_requests[0].action==="would-create" && r.incidents[0].repair_attempts_used===1 && r.incidents[0].real_issue_requests===3' \
  --events "$TMP/esc.jsonl" --state "$LIFE" --now "$NOW14" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

B1=$TMP/budget1.json
check "budget 1 opens the single issue" 0 \
  'r.incidents[0].repair_attempts_used===1 && r.incidents[0].real_issue_requests===1' \
  --events "$FIX/two-attempts.jsonl" --state "$B1" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 1
walk_to_effective "$B1" 1 "" 03
write_ci "$TMP/esc.jsonl" a3 "$SHA_C" "$NOW7" "$RAW88" det-1
check "unnamed exhaustion is UNKNOWN and blocks requeue" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="escalation human is unknown" && r.issue_requests[0].action==="suppressed-budget" && r.incidents[0].escalation.human==="unknown" && r.incidents[0].automatic_requeue==="blocked" && r.incidents[0].real_issue_requests===1 && r.incidents[0].repair_attempts_used===1' \
  --events "$TMP/esc.jsonl" --state "$B1" --now "$NOW7" --root "$REPO_ROOT" --repair-budget 1
write_ci "$TMP/esc.jsonl" a4 "$SHA_D" "$NOW7" "$RAW88" det-1
check "unnamed exhaustion does not open a second issue" 3 \
  'r.incidents[0].real_issue_requests===1 && r.incidents[0].automatic_requeue==="blocked" && r.evaluation==="UNKNOWN"' \
  --events "$TMP/esc.jsonl" --state "$B1" --now "$NOW7" --root "$REPO_ROOT" --repair-budget 1

printf '\n%s\n' "=== drift and locks ==="
write_drift_seed "$TMP/drift.json"
check "schema drift is reported before new keys are trusted" 0 \
  'r.evaluation==="complete" && r.detector==="healthy" && r.trust==="drift-reported" && r.new_keys_trusted===false && r.gh_invocations===0 && r.drifted_keys.length===1 && r.incidents.length===1 && r.pending_count===0 && r.issue_requests.length===0' \
  --apply --events "$FIX/drift-new-signature.jsonl" --state "$TMP/drift.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "withheld events are not stored and old keys stay" "$TMP/drift.json" \
  'Object.keys(s.incidents).length===1 && s.seen_event_ids.length===0 && s.trusted_signature_schema_version===0 && s.drift_gate.signature_schema_version===1 && Object.values(s.incidents)[0].normalized_signature==="Error: assert foo.ts:88 expected 1" && Object.values(s.incidents)[0].signature_schema_version===0'

check "detector version drift withholds" 0 \
  'r.trust==="trusted" && r.incidents.length===1' \
  --events "$FIX/two-attempts.jsonl" --state "$TMP/det.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
check "a new detector version is not trusted immediately" 0 \
  'r.trust==="drift-reported" && r.new_keys_trusted===false && r.pending_count===0 && r.incidents.length===1 && r.drifted_keys.length===1' \
  --events "$FIX/det2-one.jsonl" --state "$TMP/det.json" --now "$NOW1" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
check "the same new detector version is trusted on the next run" 0 \
  'r.trust==="trusted" && r.new_keys_trusted===true && r.pending_count===1 && r.incidents.length===1' \
  --events "$FIX/det2-one.jsonl" --state "$TMP/det.json" --now "$NOW1" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
check "another new detector version withholds again" 0 \
  'r.trust==="drift-reported" && r.new_keys_trusted===false && r.pending_count===1 && r.incidents.length===1' \
  --events "$FIX/det3-one.jsonl" --state "$TMP/det.json" --now "2026-01-03T00:00:00Z" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human

printf '{\n' > "$TMP/corrupt.json"
corrupt_before=$(cksum "$TMP/corrupt.json")
check "corrupt state is refused" 1 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="state file is not JSON"' \
  --events "$FIX/one-attempt.jsonl" --state "$TMP/corrupt.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2
corrupt_after=$(cksum "$TMP/corrupt.json")
if [[ "$corrupt_before" == "$corrupt_after" ]]; then ok "corrupt state was not overwritten"; else bad "corrupt state was not overwritten"; fi

check "fresh state boot for the untrusted fixture" 0 'r.incidents.length===1' \
  --events "$FIX/two-attempts.jsonl" --state "$TMP/untrusted.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2
STATE_FILE=$TMP/untrusted.json node --input-type=module -e '
import { readFileSync, writeFileSync } from "node:fs";
const s = JSON.parse(readFileSync(process.env.STATE_FILE, "utf8"));
s.trusted_signature_schema_version = null;
writeFileSync(process.env.STATE_FILE, JSON.stringify(s) + "\n");
'
untrusted_before=$(cksum "$TMP/untrusted.json")
check "untrusted state with incidents is refused" 1 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="untrusted state already has incidents"' \
  --events "$FIX/one-attempt.jsonl" --state "$TMP/untrusted.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2
untrusted_after=$(cksum "$TMP/untrusted.json")
if [[ "$untrusted_before" == "$untrusted_after" ]]; then ok "untrusted state was not overwritten"; else bad "untrusted state was not overwritten"; fi

check "symlink source state" 0 'r.incidents.length===1' \
  --events "$FIX/two-attempts.jsonl" --state "$TMP/link-target.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2
ln -s "$TMP/link-target.json" "$TMP/via-link.json"
link_before=$(cksum "$TMP/link-target.json")
check "symlink state path is refused" 1 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="state path must be a regular file"' \
  --events "$FIX/two-attempts.jsonl" --state "$TMP/via-link.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2
link_after=$(cksum "$TMP/link-target.json")
if [[ -L "$TMP/via-link.json" && "$link_before" == "$link_after" ]]; then
  ok "symlink state was not replaced"
else
  bad "symlink state was not replaced"
fi

"$NODE_REAL" -e 'setInterval(function () {}, 1000000)' >/dev/null 2>&1 &
printf '%s\n' "$!" > "$TMP/holder.pid"
printf '%s' "$(cat "$TMP/holder.pid")" > "$TMP/held.json.lock"
check "a live lock is UNKNOWN" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="lock-timeout"' \
  --events "$FIX/one-attempt.jsonl" --state "$TMP/held.json" --now "$NOW0" --root "$REPO_ROOT" --lock-timeout-ms 200
absent "a live lock wrote no state" "$TMP/held.json"
if [[ "$(cat "$TMP/held.json.lock")" == "$(cat "$TMP/holder.pid")" ]]; then
  ok "a live lock was not stolen"
else
  bad "a live lock was not stolen"
fi
holder_pid=$(cat "$TMP/holder.pid")
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -f "$TMP/holder.pid"

# An already-exited pid. Starting a sleeper and killing it races the
# inherited EXIT trap on bash 3.2 and can remove TMP.
dead_pid=$("$NODE_REAL" -e 'process.stdout.write(String(process.pid))')
printf '%s' "$dead_pid" > "$TMP/stale.json.lock"
check "a dead lock is replaced" 0 'r.pending_count===1 && r.evaluation==="complete"' \
  --events "$FIX/one-attempt.jsonl" --state "$TMP/stale.json" --now "$NOW0" --root "$REPO_ROOT" --lock-timeout-ms 1000

check "omitted --state uses docs/retro-actuator-state.json under --root" 0 'r.pending_count===1' \
  --events "$FIX/one-attempt.jsonl" --root "$TMP/default-root" --now "$NOW0" --repair-budget 2
if [[ -f "$TMP/default-root/docs/retro-actuator-state.json" ]]; then
  ok "default state path is under the chosen root"
else
  bad "default state path is under the chosen root"
fi
absent "default state did not land in the repo" "$REPO_ROOT/docs/retro-actuator-state.json"

if [[ ! -s "$GH_LOG" ]]; then
  ok "dry-run and withheld apply did not call gh"
else
  bad "dry-run and withheld apply did not call gh"
fi

printf '\n%s\n' "=== apply ==="
check "the next run after reported drift applies and creates one issue" 0 \
  'r.mode==="apply" && r.trust==="trusted" && r.new_keys_trusted===true && r.gh_invocations===1 && r.incidents.length===2 && r.issue_requests.some((item) => item.action==="created")' \
  --apply --events "$FIX/drift-new-signature.jsonl" --state "$TMP/drift.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "old drift key is not rewritten" "$TMP/drift.json" \
  'const values=Object.values(s.incidents); values.length===2 && values.some((i) => i.signature_schema_version===0 && i.normalized_signature==="Error: assert foo.ts:88 expected 1") && values.some((i) => i.signature_schema_version===1 && i.attempts.length===2)'
if [[ "$LAST_ERR" != *"TOKEN-LEAK"* && "$LAST_OUT" != *"$CANARY"* ]]; then
  ok "apply report does not echo gh stderr or the canary"
else
  bad "apply report does not echo gh stderr or the canary"
fi
: > "$GH_LOG"

check "apply creates one issue" 0 \
  'r.mode==="apply" && r.gh_invocations===1 && r.issue_requests[0].action==="created" && r.incidents[0].real_issue_requests===1' \
  --apply --events "$FIX/two-attempts.jsonl" --state "$TMP/apply.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "created issue keeps the parsed url" "$TMP/apply.json" \
  'const i=Object.values(s.incidents)[0]; i.issue_requests[0].status==="created" && i.issue_requests[0].gh_url==="https://github.com/The-AIE/the-gibson/issues/569" && i.issue_requests[0].gh_number===569'
if [[ "$GH_LOG" != "" ]] && grep -q 'issue create' "$GH_LOG" && grep -q -- '--body-file' "$GH_LOG"; then
  ok "gh is called with a body file"
else
  bad "gh is called with a body file"
fi
if grep -F -q "$CANARY" "$GH_LOG" "$TMP/last.json" "$ERR_FILE" "$TMP/apply.json"; then
  bad "canary leaked into argv, report, stderr, or state"
else
  ok "canary stayed out of argv, report, stderr, and state"
fi
if grep -F -q 'TOKEN-LEAK' "$TMP/last.json" "$ERR_FILE" "$TMP/apply.json"; then
  bad "gh stderr was forwarded"
else
  ok "gh stderr was not forwarded"
fi
apply_lines=$(grep -c 'issue create' "$GH_LOG" || true)
check "a second apply does not call gh again" 0 \
  'r.gh_invocations===0 && r.issue_requests.length===0 && r.incidents[0].real_issue_requests===1' \
  --apply --events "$FIX/two-attempts.jsonl" --state "$TMP/apply.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
apply_after=$(grep -c 'issue create' "$GH_LOG" || true)
if [[ "$apply_lines" == "$apply_after" ]]; then ok "second apply left the gh log unchanged"; else bad "second apply left the gh log unchanged"; fi

GH_MODE=fail
: > "$GH_LOG"
check "gh failure is UNKNOWN and reverts to planned" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="gh issue create failed" && r.gh_invocations===1' \
  --apply --events "$FIX/two-attempts.jsonl" --state "$TMP/gh-fail.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "failed create stays planned" "$TMP/gh-fail.json" \
  'Object.values(s.incidents)[0].issue_requests[0].status==="planned"'
GH_MODE=ok
check "a reverted create can be retried" 0 \
  'r.evaluation==="complete" && r.gh_invocations===1 && r.issue_requests.length===0' \
  --apply --events "$FIX/two-attempts.jsonl" --state "$TMP/gh-fail.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "retried create is stored" "$TMP/gh-fail.json" \
  'Object.values(s.incidents)[0].issue_requests[0].status==="created"'

GH_MODE=badurl
: > "$GH_LOG"
check "gh success without an issue url stays unfinished" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="gh issue create returned no issue url" && r.gh_invocations===1' \
  --apply --events "$FIX/two-attempts.jsonl" --state "$TMP/bad-url.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
expect_state "unparsed url stays creating" "$TMP/bad-url.json" \
  'Object.values(s.incidents)[0].issue_requests[0].status==="creating"'
GH_MODE=ok
: > "$GH_LOG"
check "an unfinished create is not retried" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="a previous create did not finish" && r.gh_invocations===0' \
  --apply --events "$FIX/two-attempts.jsonl" --state "$TMP/bad-url.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
if [[ ! -s "$GH_LOG" ]]; then ok "unfinished create did not call gh"; else bad "unfinished create did not call gh"; fi

mv "$BIN/gh" "$BIN/gh.off"
ln -s "$(command -v cat)" "$BIN/cat"
saved_path=$PATH
PATH=$BIN
check "missing gh fails closed" 3 \
  'r.evaluation==="UNKNOWN" && r.unknown_reason==="gh issue create failed"' \
  --apply --events "$FIX/two-attempts.jsonl" --state "$TMP/no-gh.json" --now "$NOW0" --root "$REPO_ROOT" --repair-budget 2 --escalate-to duty-human
PATH=$saved_path
rm -f "$BIN/cat"
mv "$BIN/gh.off" "$BIN/gh"
expect_state "missing gh leaves the request planned" "$TMP/no-gh.json" \
  'Object.values(s.incidents)[0].issue_requests[0].status==="planned"'

printf '\n%s\n' "=== workflow ==="
WF="$REPO_ROOT/.github/workflows/retro-actuator.yml"
if grep -q 'node scripts/retro-actuator.mjs' "$WF" \
  && grep -q 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2' "$WF" \
  && grep -q 'permissions: {}' "$WF" \
  && grep -q 'contents: read' "$WF" \
  && grep -q 'RUNNER_TEMP' "$WF" \
  && grep -q 'workflow_dispatch' "$WF"; then
  ok "workflow invokes the actuator in dry-run"
else
  bad "workflow invokes the actuator in dry-run"
fi
run_apply=0
while IFS= read -r run_line; do
  case "$run_line" in
    *--apply*) run_apply=1 ;;
  esac
done << RUNS
$(grep -E '^[[:space:]]*run:' "$WF" || true)
RUNS
if [[ "$run_apply" -eq 1 ]] \
  || grep -E -q '^[[:space:]]*(pull_request|issues:)' "$WF" \
  || grep -q 'issues: write' "$WF" \
  || grep -q 'exit 0' "$WF"; then
  bad "workflow stays advisory"
else
  ok "workflow stays advisory"
fi
if grep -q 'pr merge' "$TOOL" || grep -q '\["merge"' "$TOOL"; then
  bad "actuator does not merge"
else
  ok "actuator does not merge"
fi

printf '\n%s\n' "=== summary ==="
printf 'retro-actuator.test.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
