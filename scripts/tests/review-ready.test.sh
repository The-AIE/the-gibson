#!/usr/bin/env bash
# review-ready.test.sh — the `review-ready` job in gibson-self-gate.yml (#562)
#
# WHY
#   The job is inline YAML, so nothing exercised it. This test extracts the emit
#   step's `run:` script and executes it against a stub `gh` on PATH that serves JSON
#   fixtures and records every write. It pins the contract in docs/31-review-ready-event.md:
#   one commit status + one repository_dispatch per ready head, nothing on drafts, forks
#   or non-pull_request events, nothing twice for the same head, a failure to emit is
#   explained in the job summary, and the payload has exactly the documented fields.
#   It also pins the YAML properties the script cannot show: continue-on-error on the
#   emit step only, the needs, the least-privilege permissions, the SHA-pinned actions.
#   The test never touches GitHub.
#
# USAGE
#   scripts/tests/review-ready.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
WF="$REPO_ROOT/.github/workflows/gibson-self-gate.yml"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null || { echo "review-ready.test.sh: jq required"; exit 1; }
[[ -f "$WF" ]] || { echo "review-ready.test.sh: workflow not found: $WF"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-review-ready.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# job_block — the review-ready job's lines (two-space-indented key to the next job or EOF)
job_block() {
  awk '
    /^  review-ready:[[:space:]]*$/ { injob = 1; print; next }
    injob && /^  [A-Za-z0-9_-]+:/   { exit }
    injob                           { print }
  ' "$WF"
}

echo "# extract the emit step's run script from the workflow"
STEP="$ROOT/emit-step.sh"
awk '
  /^  review-ready:[[:space:]]*$/                    { injob = 1; next }
  injob && /^  [A-Za-z0-9_-]+:/                       { exit }
  injob && /^      - name: Emit review-ready[[:space:]]*$/ { instep = 1; next }
  instep && /^        run: \|[[:space:]]*$/          { inrun = 1; next }
  instep && inrun {
    if ($0 ~ /^      - / || $0 ~ /^[^ ]/) exit
    sub(/^          /, "")
    print
  }
' "$WF" > "$STEP"
if [[ -s "$STEP" ]] && [[ "$(cat "$STEP")" == *"repos/\${REPO}/dispatches"* ]]; then
  ok "extracted the emit step script ($(wc -l < "$STEP" | tr -d ' ') lines)"
else
  bad "could not extract the emit step from $WF"
  echo "review-ready.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi

# The stub: `gh api PATH [--paginate] [--jq EXPR] [--input -] [-f k=v ...]`.
#   GET  repos/R/commits/SHA/statuses -> $GH_FIXTURE/statuses.json (jq applied like gh's --jq)
#   GET  repos/R/actions/runs/ID/jobs -> $GH_FIXTURE/jobs.json
#   POST repos/R/statuses/SHA         -> appends "k=v ..." to $GH_LOG/status.log
#   POST repos/R/dispatches           -> appends the stdin body to $GH_LOG/dispatch.log
#   FAIL_STATUSES_READ / FAIL_STATUS_POST / FAIL_DISPATCH make the matching call exit 1.
mkdir -p "$ROOT/stub-bin" "$ROOT/fixture" "$ROOT/log"
cat > "$ROOT/stub-bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || { echo "stub gh: unexpected args: $*" >&2; exit 2; }
path=$2; shift 2
expr=""; input=""; fields=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) expr="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    -f) fields="$fields $2"; shift 2 ;;
    *) shift ;;
  esac
done
serve() {
  [ -f "$GH_FIXTURE/$1" ] || { echo "stub gh: no fixture $1" >&2; exit 1; }
  if [ -n "$expr" ]; then jq -r "$expr" "$GH_FIXTURE/$1"; else cat "$GH_FIXTURE/$1"; fi
}
case "$path" in
  repos/*/commits/*/statuses)
    [ -z "${FAIL_STATUSES_READ:-}" ] || { echo "stub gh: statuses read failed" >&2; exit 1; }
    serve statuses.json ;;
  repos/*/actions/runs/*/jobs) serve jobs.json ;;
  repos/*/statuses/*)
    [ -z "${FAIL_STATUS_POST:-}" ] || { echo "stub gh: status post failed" >&2; exit 1; }
    echo "$path$fields" >> "$GH_LOG/status.log" ;;
  repos/*/dispatches)
    [ -z "${FAIL_DISPATCH:-}" ] || { echo "stub gh: dispatch failed" >&2; exit 1; }
    [ "$input" = "-" ] || { echo "stub gh: dispatch without --input -" >&2; exit 2; }
    cat >> "$GH_LOG/dispatch.log"; echo >> "$GH_LOG/dispatch.log" ;;
  *) echo "stub gh: unexpected path $path" >&2; exit 2 ;;
esac
STUB
chmod +x "$ROOT/stub-bin/gh"

HEAD=1111111111111111111111111111111111111111
BASE=2222222222222222222222222222222222222222
SENSORS_AT=2026-10-25T16:00:00Z
echo '[]' > "$ROOT/fixture/statuses.json"
jq -n --arg t "$SENSORS_AT" '{jobs:[{name:"claim-isolation",completed_at:"2026-10-25T15:55:00Z"},{name:"sensors",completed_at:$t}]}' > "$ROOT/fixture/jobs.json"

# run_step [VAR=value ...] — defaults describe a ready head; arguments override. Sets OUT, RC,
# and leaves the recorded writes in $ROOT/log and the summary in $ROOT/summary.md.
run_step() {
  rm -f "$ROOT/log/"* "$ROOT/summary.md"; : > "$ROOT/summary.md"
  OUT=$(env PATH="$ROOT/stub-bin:$PATH" GH_FIXTURE="$ROOT/fixture" GH_LOG="$ROOT/log" \
        EVENT_NAME=pull_request IS_DRAFT=false HEAD_REPO=example/repo REPO=example/repo PR_NUMBER=77 \
        BASE_SHA="$BASE" HEAD_SHA="$HEAD" PR_OPENED_AT=2026-10-25T15:20:00Z RUN_ID=9001 GH_TOKEN=test \
        GITHUB_STEP_SUMMARY="$ROOT/summary.md" "$@" bash "$STEP" 2>&1)
  RC=$?
  SUMMARY=$(cat "$ROOT/summary.md")
  STATUS_LOG=""; DISPATCH_LOG=""
  [[ -f "$ROOT/log/status.log" ]] && STATUS_LOG=$(cat "$ROOT/log/status.log")
  [[ -f "$ROOT/log/dispatch.log" ]] && DISPATCH_LOG=$(cat "$ROOT/log/dispatch.log")
}
count_lines() { if [[ -z "$1" ]]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

echo "# a ready head: one status, one dispatch, measurement printed"
run_step
if [[ $RC -eq 0 && "$(count_lines "$STATUS_LOG")" == 1 && "$(count_lines "$DISPATCH_LOG")" == 1 ]]; then
  ok "emits exactly one status and one dispatch (rc=0)"
else bad "ready head: rc=$RC statuses=$(count_lines "$STATUS_LOG") dispatches=$(count_lines "$DISPATCH_LOG") out=$OUT"; fi
want_status="repos/example/repo/statuses/$HEAD state=success context=review-ready description=claim-isolation and sensors green; ready for independent review"
if [[ "$STATUS_LOG" == "$want_status" ]]; then ok "status is review-ready=success at the exact head with the documented description"; else bad "status line: $STATUS_LOG"; fi
if [[ "$SUMMARY" == *"sensors_green_at: $SENSORS_AT"* && "$SUMMARY" == *"ready_emitted_at: 20"* && "$SUMMARY" == *"pr_opened_at: 2026-10-25T15:20:00Z"* ]]; then
  ok "summary prints sensors_green_at, ready_emitted_at and the PR open time"
else bad "summary: $SUMMARY"; fi
if [[ "$SUMMARY" == *"sensors green to ready emitted: "* ]]; then ok "summary prints the sensors-green-to-emit wait in seconds"; else bad "no wait line: $SUMMARY"; fi

echo "# the payload carries exactly the documented fields"
if [[ -n "$DISPATCH_LOG" ]] && printf '%s' "$DISPATCH_LOG" | jq -e . >/dev/null 2>&1; then
  keys=$(printf '%s' "$DISPATCH_LOG" | jq -r '.client_payload | keys_unsorted | sort | join(",")')
  if [[ "$keys" == "base_sha,head_sha,pr,repo,tier-unknown,ts" ]]; then ok "client_payload keys are exactly base_sha, head_sha, pr, repo, tier-unknown, ts"; else bad "payload keys: $keys"; fi
  top=$(printf '%s' "$DISPATCH_LOG" | jq -r 'keys | sort | join(",")')
  if [[ "$top" == "client_payload,event_type" ]]; then ok "top level is event_type + client_payload only"; else bad "top-level keys: $top"; fi
  if printf '%s' "$DISPATCH_LOG" | jq -e --arg h "$HEAD" --arg b "$BASE" \
      '.event_type == "review-ready" and .client_payload.repo == "example/repo" and .client_payload.pr == 77
       and .client_payload.head_sha == $h and .client_payload.base_sha == $b
       and .client_payload["tier-unknown"] == true
       and (.client_payload.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' >/dev/null; then
    ok "values: type review-ready, repo, numeric pr, head and base SHA, tier-unknown true, UTC ts"
  else bad "payload values: $DISPATCH_LOG"; fi
else bad "dispatch body is not JSON: $DISPATCH_LOG"; fi

echo "# skips: nothing is written"
run_step IS_DRAFT=true
if [[ $RC -eq 0 && -z "$STATUS_LOG" && -z "$DISPATCH_LOG" && "$SUMMARY" == *"draft"* ]]; then ok "draft pull request: skips visibly, writes nothing"; else bad "draft rc=$RC s=$STATUS_LOG d=$DISPATCH_LOG sum=$SUMMARY"; fi
run_step EVENT_NAME=push
if [[ $RC -eq 0 && -z "$STATUS_LOG" && -z "$DISPATCH_LOG" && "$SUMMARY" == *"not pull_request"* ]]; then ok "push event: skips, writes nothing"; else bad "push rc=$RC s=$STATUS_LOG d=$DISPATCH_LOG sum=$SUMMARY"; fi
run_step EVENT_NAME=pull_request_target
if [[ $RC -eq 0 && -z "$STATUS_LOG" && -z "$DISPATCH_LOG" ]]; then ok "pull_request_target is not pull_request: skips"; else bad "pull_request_target rc=$RC s=$STATUS_LOG"; fi
run_step HEAD_REPO=someone-else/repo
if [[ $RC -eq 0 && -z "$STATUS_LOG" && -z "$DISPATCH_LOG" && "$SUMMARY" == *"fork"* ]]; then ok "fork head: skips, writes nothing"; else bad "fork rc=$RC s=$STATUS_LOG d=$DISPATCH_LOG sum=$SUMMARY"; fi

echo "# idempotent per head"
echo "[{\"id\":5,\"context\":\"review-ready\",\"state\":\"success\"}]" > "$ROOT/fixture/statuses.json"
run_step
if [[ $RC -eq 0 && -z "$STATUS_LOG" && -z "$DISPATCH_LOG" && "$SUMMARY" == *"already exists"* ]]; then ok "a review-ready success already at the head: no second status, no second dispatch"; else bad "idempotent rc=$RC s=$STATUS_LOG d=$DISPATCH_LOG sum=$SUMMARY"; fi
echo '[{"id":6,"context":"review-ready","state":"pending"},{"id":7,"context":"other","state":"success"}]' > "$ROOT/fixture/statuses.json"
run_step
if [[ $RC -eq 0 && -n "$STATUS_LOG" && -n "$DISPATCH_LOG" ]]; then ok "only a review-ready SUCCESS suppresses (pending or another context does not)"; else bad "non-matching statuses rc=$RC s=$STATUS_LOG d=$DISPATCH_LOG"; fi
echo '[]' > "$ROOT/fixture/statuses.json"

echo "# a failure to emit is explained and never silent"
run_step FAIL_STATUSES_READ=1
if [[ $RC -ne 0 && -z "$STATUS_LOG" && -z "$DISPATCH_LOG" && "$SUMMARY" == *"could not read existing statuses"* ]]; then ok "cannot check idempotency: emits nothing, says why (step is continue-on-error)"; else bad "read-fail rc=$RC s=$STATUS_LOG sum=$SUMMARY"; fi
run_step FAIL_STATUS_POST=1
if [[ $RC -ne 0 && -z "$DISPATCH_LOG" && "$SUMMARY" == *"could not post the review-ready status"* ]]; then ok "status post fails: no dispatch, reason in the summary"; else bad "status-fail rc=$RC d=$DISPATCH_LOG sum=$SUMMARY"; fi
run_step FAIL_DISPATCH=1
if [[ $RC -ne 0 && -n "$STATUS_LOG" && "$SUMMARY" == *"repository_dispatch failed"* ]]; then ok "dispatch fails after the status: status stands, reason in the summary"; else bad "dispatch-fail rc=$RC s=$STATUS_LOG sum=$SUMMARY"; fi
rm -f "$ROOT/fixture/jobs.json"
run_step
if [[ $RC -eq 0 && -n "$STATUS_LOG" && -n "$DISPATCH_LOG" && "$SUMMARY" == *"sensors_green_at: unknown"* ]]; then ok "unreadable job timestamps degrade to 'unknown' and still emit"; else bad "no-jobs rc=$RC s=$STATUS_LOG d=$DISPATCH_LOG sum=$SUMMARY"; fi

echo "# the YAML properties the script cannot show"
BLOCK=$(job_block)
[[ -n "$BLOCK" ]] || bad "review-ready job not found in the workflow"
if [[ "$BLOCK" == *"needs: [claim-isolation, sensors]"* ]]; then ok "needs claim-isolation and sensors"; else bad "needs line missing"; fi
if [[ "$BLOCK" == *"github.event.pull_request.draft == false"* && "$BLOCK" == *"github.event_name == 'pull_request'"* && "$BLOCK" == *"head.repo.full_name == github.repository"* ]]; then ok "job-level if: pull_request, non-draft, same-repo head"; else bad "job if: guard incomplete"; fi
perms=$(awk '/^    permissions:/ {p=1; next} p && /^      [a-z-]+:/ {print $1 $2; next} p {exit}' <<< "$BLOCK" | sort | tr '\n' ' ')
if [[ "$perms" == "actions:read contents:write statuses:write " ]]; then ok "permissions are exactly actions: read, contents: write, statuses: write"; else bad "permissions: $perms"; fi
coe=$(grep -c 'continue-on-error: true' <<< "$BLOCK")
if [[ "$coe" == 1 ]]; then ok "continue-on-error appears once, on the emit step"; else bad "continue-on-error count: $coe"; fi
step_coe=$(awk '/^      - name: Emit review-ready/ {s=1; next} s && /continue-on-error: true/ {print "yes"; exit} s && /^        run:/ {exit}' <<< "$BLOCK")
if [[ "$step_coe" == yes ]]; then ok "that continue-on-error belongs to the Emit review-ready step"; else bad "continue-on-error is not on the emit step"; fi
if [[ "$BLOCK" != *"actions/checkout"* ]]; then ok "no checkout: the PR's code is never executed with write scopes"; else bad "job checks out the repo"; fi
uses_bad=$(awk '/^[[:space:]]*-?[[:space:]]*uses:/ && $0 !~ /@[0-9a-f]{40} # v/ {n++} END {print n + 0}' <<< "$BLOCK")
if [[ "$uses_bad" == 0 ]]; then ok "every action in the job is pinned by commit SHA with a version comment"; else bad "unpinned actions in the job"; fi
if grep -q 'ready_for_review' "$WF"; then ok "pull_request triggers include ready_for_review (a draft marked ready is emitted)"; else bad "ready_for_review trigger missing"; fi
if [[ "$(cat "$STEP")" != *"\${{"* ]]; then ok "run: script has no \${{ }} expressions (github context goes through env)"; else bad "run: script interpolates github context"; fi
gate_hits=$(grep -lE 'review-ready' "$REPO_ROOT"/config/*.json 2>/dev/null || true)
if [[ -z "$gate_hits" ]]; then ok "review-ready is not named in any config/*.json (signal, not gate)"; else bad "review-ready named in: $gate_hits"; fi

echo
echo "review-ready.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
