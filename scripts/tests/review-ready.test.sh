#!/usr/bin/env bash
# review-ready.test.sh — the review-ready workflow (#562)
#
# WHY
#   .github/workflows/review-ready.yml is inline YAML, so nothing exercised it. This test
#   (a) PARSES the workflow files (never greps them, so a comment or an unrelated string
#   cannot satisfy an assertion) to pin the structure that keeps the signal safe, and
#   (b) runs the emit step's script against a stub `gh` on PATH that serves JSON fixtures
#   and records every write. It pins docs/32-review-ready-event.md: one commit status plus
#   one repository_dispatch per ready head; nothing for drafts, forks, failed or foreign
#   runs, a moved head, or a gate that is not green; nothing twice for a head; a failure to
#   emit is explained in the job summary; the payload has exactly the documented fields.
#
#   The structural half is the security half: a `pull_request` workflow runs the file from
#   the PR, so gibson-self-gate.yml must never hold statuses/contents write; the emitter
#   runs from the default branch (workflow_run / pull_request_target) and never checks out.
#   The test never touches GitHub.
#
# USAGE
#   scripts/tests/review-ready.test.sh
#   REVIEW_READY_WORKFLOW=copy.yml REVIEW_READY_SELF_GATE=copy2.yml scripts/tests/review-ready.test.sh   # mutation proofs
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
WF="${REVIEW_READY_WORKFLOW:-$REPO_ROOT/.github/workflows/review-ready.yml}"
SELF="${REVIEW_READY_SELF_GATE:-$REPO_ROOT/.github/workflows/gibson-self-gate.yml}"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null || { echo "review-ready.test.sh: jq required"; exit 1; }
command -v python3 >/dev/null || { echo "review-ready.test.sh: python3 required"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "review-ready.test.sh: PyYAML required"; exit 1; }
[[ -f "$WF" ]] || { echo "review-ready.test.sh: workflow not found: $WF"; exit 1; }
[[ -f "$SELF" ]] || { echo "review-ready.test.sh: workflow not found: $SELF"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-review-ready.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Parse both workflows into facts (JSON) and extract the emit step's script.
STEP="$ROOT/emit-step.sh"
FACTS="$ROOT/facts.json"
python3 - "$WF" "$SELF" "$STEP" > "$FACTS" <<'PY'
import json, sys
import yaml

wf_path, self_path, step_path = sys.argv[1:4]

def load(p):
    with open(p, encoding="utf-8") as f:
        return yaml.safe_load(f)

def triggers(d):
    on = d.get("on", d.get(True))  # PyYAML reads a bare `on:` key as boolean True
    if isinstance(on, dict):
        return on
    return {k: None for k in (on if isinstance(on, list) else [on])}

def perms_found(d):
    found = []
    if "permissions" in d:
        found.append(d["permissions"])
    for job in (d.get("jobs") or {}).values():
        if "permissions" in job:
            found.append(job["permissions"])
    return found

def writes(perms):
    out = []
    for p in perms:
        if p == "write-all":
            out.append("write-all")
        elif isinstance(p, dict):
            out += [k for k, v in p.items() if v == "write"]
    return sorted(set(out))

def steps_of(d):
    for job in (d.get("jobs") or {}).values():
        for st in job.get("steps") or []:
            yield st

wf, sg = load(wf_path), load(self_path)
tr = triggers(wf)
jobs = wf.get("jobs") or {}
job = jobs.get("review-ready") or {}
emit = [s for s in job.get("steps") or [] if s.get("name") == "Emit review-ready"]
if len(emit) == 1:
    with open(step_path, "w", encoding="utf-8") as f:
        f.write(emit[0].get("run", ""))
facts = {
    "name": wf.get("name"),
    "triggers": sorted(tr),
    "wr_workflows": (tr.get("workflow_run") or {}).get("workflows"),
    "wr_types": (tr.get("workflow_run") or {}).get("types"),
    "prt_types": (tr.get("pull_request_target") or {}).get("types"),
    "top_permissions": wf.get("permissions"),
    "jobs": sorted(jobs),
    "job_permissions": job.get("permissions"),
    "job_has_if": "if" in job,
    "step_if": " ".join(str(emit[0].get("if", "")).split()) if len(emit) == 1 else None,
    "emit_steps": len(emit),
    "emit_continue_on_error": emit[0].get("continue-on-error") if len(emit) == 1 else None,
    "continue_on_error_steps": sorted(s.get("name", "?") for s in steps_of(wf) if "continue-on-error" in s),
    "continue_on_error_jobs": sorted(n for n, j in jobs.items() if "continue-on-error" in j),
    "uses": sorted(str(s["uses"]) for s in steps_of(wf) if "uses" in s),
    "self_name": sg.get("name"),
    "self_triggers": sorted(triggers(sg)),
    "self_jobs": sorted((sg.get("jobs") or {})),
    "self_job_names": sorted({(j.get("name") or n) for n, j in (sg.get("jobs") or {}).items()}),
    "self_writes": writes(perms_found(sg)),
    "self_pr_types": (triggers(sg).get("pull_request") or {}).get("types"),
}
print(json.dumps(facts))
PY
[[ $? -eq 0 && -s "$FACTS" ]] || { bad "could not parse the workflows"; echo "review-ready.test.sh: $PASS passed, $FAIL failed"; exit 1; }
fact() { jq -c "$1" "$FACTS"; }
expect() { # expect JQ-EXPR WANT MESSAGE
  local got; got=$(fact "$1")
  if [[ "$got" == "$2" ]]; then ok "$3"; else bad "$3 (got $got, want $2)"; fi
}

echo "# structure: the emitter runs from the default branch, the self-gate holds no write scopes"
expect '.triggers' '["pull_request_target","workflow_run"]' "triggers are exactly workflow_run and pull_request_target (never pull_request)"
expect '.wr_types' '["completed"]' "workflow_run fires on completed only"
expect '.prt_types' '["ready_for_review"]' "pull_request_target fires on ready_for_review only"
want_name=$(jq -r '.self_name' "$FACTS")
expect '.wr_workflows' "[\"$want_name\"]" "workflow_run names the self-gate workflow by its real name ($want_name)"
expect '.top_permissions' '{}' "workflow-level permissions are empty"
expect '.job_permissions' '{"actions":"read","contents":"write","pull-requests":"read","statuses":"write"}' "job permissions are exactly actions: read, pull-requests: read, statuses: write, contents: write"
expect '.jobs' '["review-ready"]' "one job"
expect '.uses' '[]' "the emitter has no uses: at all (no checkout, no third-party action holding write scopes)"
expect '.emit_steps' '1' "exactly one Emit review-ready step"
expect '.emit_continue_on_error' 'true' "continue-on-error: true on the emit step"
expect '.continue_on_error_steps' '["Emit review-ready"]' "continue-on-error appears on no other step"
expect '.continue_on_error_jobs' '[]' "continue-on-error appears on no job"
want_if="(github.event_name == 'workflow_run' && github.event.workflow_run.event == 'pull_request' && github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.head_repository.full_name == github.repository) || (github.event_name == 'pull_request_target' && github.event.pull_request.draft == false && github.event.pull_request.head.repo.full_name == github.repository)"
got_if=$(jq -r '.step_if' "$FACTS")
if [[ "$got_if" == "$want_if" ]]; then ok "step-level if: pull_request runs only, success only, same-repo heads only, never a draft"; else bad "step if: is: $got_if"; fi
expect '.job_has_if' 'false' "the job has no if: (a skipped job concludes skipped, which sensor-health grades unhealthy; a skipped step leaves the run success)"
expect '.self_writes' '[]' "gibson-self-gate.yml grants no write permission anywhere (a PR rewrites that file)"
expect '(.self_jobs | index("review-ready"))' 'null' "gibson-self-gate.yml has no review-ready job"
expect '(.self_job_names | index("emit review-ready"))' 'null' "gibson-self-gate.yml has no emit review-ready job"
expect '.self_pr_types' 'null' "gibson-self-gate.yml pull_request trigger keeps the default types (no ready_for_review rerun)"
expect '(.self_triggers | index("pull_request") != null)' 'true' "gibson-self-gate.yml still runs on pull_request"

echo "# extract the emit step's run script"
if [[ -s "$STEP" ]] && [[ "$(cat "$STEP")" == *"repos/\${REPO}/dispatches"* ]]; then
  ok "extracted the emit step script ($(wc -l < "$STEP" | tr -d ' ') lines)"
else
  bad "could not extract the emit step from $WF"
  echo "review-ready.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi
if [[ "$(cat "$STEP")" != *"\${{"* ]]; then ok "the script has no \${{ }} expressions (github context goes through env)"; else bad "the script interpolates github context"; fi

# The stub: `gh api PATH [--paginate] [--jq EXPR] [--input -] [-f k=v ...]`.
#   GET  repos/R/actions/runs?...      -> $GH_FIXTURE/runs-list.json
#   GET  repos/R/actions/runs/ID       -> $GH_FIXTURE/run.json
#   GET  repos/R/actions/runs/ID/jobs  -> $GH_FIXTURE/jobs.json
#   GET  repos/R/pulls/N               -> $GH_FIXTURE/pull.json
#   GET  repos/R/commits/SHA/statuses  -> $GH_FIXTURE/statuses.json
#   POST repos/R/statuses/SHA          -> appends "path k=v ..." to $GH_LOG/status.log
#   POST repos/R/dispatches            -> appends the stdin body to $GH_LOG/dispatch.log
#   FAIL_STATUSES_READ / FAIL_STATUS_POST / FAIL_DISPATCH make the matching call exit 1.
# --jq expressions run through the real jq (gh's --jq is jq -r), so the workflow's filters are under test.
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
  repos/*/actions/runs\?*) serve runs-list.json ;;
  repos/*/actions/runs/*/jobs) serve jobs.json ;;
  repos/*/actions/runs/*) serve run.json ;;
  repos/*/pulls/*) serve pull.json ;;
  repos/*/commits/*/statuses)
    [ -z "${FAIL_STATUSES_READ:-}" ] || { echo "stub gh: statuses read failed" >&2; exit 1; }
    serve statuses.json ;;
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
MOVED=3333333333333333333333333333333333333333
SG_PATH=.github/workflows/gibson-self-gate.yml
SENSORS_AT=2026-10-25T16:00:00Z

# Fixtures describing a good world; each test overrides one thing.
write_run()   { jq -n --arg path "$1" --arg ev "$2" --arg c "$3" --arg h "$4" --arg r "$5" \
  '{id:9001, path:$path, event:$ev, conclusion:$c, head_sha:$h, head_repository:{full_name:$r}, pull_requests:[{number:77}]}' > "$ROOT/fixture/run.json"; }
write_pull()  { jq -n --arg st "$1" --argjson dr "$2" --arg h "$3" --arg r "$4" --arg base "$BASE" \
  '{state:$st, draft:$dr, head:{sha:$h, repo:{full_name:$r}}, base:{sha:$base}, created_at:"2026-10-25T15:20:00Z"}' > "$ROOT/fixture/pull.json"; }
write_jobs()  { jq -n --arg s "$1" --arg c "$2" --arg t "$SENSORS_AT" \
  '{jobs:[{name:"claim-isolation",conclusion:$c,completed_at:"2026-10-25T15:55:00Z"},{name:"pr-size",conclusion:"success",completed_at:"2026-10-25T15:56:00Z"},{name:"sensors",conclusion:$s,completed_at:$t}]}' > "$ROOT/fixture/jobs.json"; }
reset_world() {
  write_run "$SG_PATH" pull_request success "$HEAD" example/repo
  write_pull open false "$HEAD" example/repo
  write_jobs success success
  echo '[]' > "$ROOT/fixture/statuses.json"
  jq -n --arg p "$SG_PATH" '{workflow_runs:[{id:9001,path:$p,conclusion:"success",run_started_at:"2026-10-25T15:30:00Z",pull_requests:[{number:77}]},{id:9000,path:$p,conclusion:"failure",run_started_at:"2026-10-25T15:40:00Z",pull_requests:[{number:77}]},{id:8001,path:$p,conclusion:"success",run_started_at:"2026-10-25T15:55:00Z",pull_requests:[{number:12}]},{id:8000,path:".github/workflows/other.yml",conclusion:"success",run_started_at:"2026-10-25T15:50:00Z",pull_requests:[{number:77}]}]}' > "$ROOT/fixture/runs-list.json"
}
reset_world

# run_step [VAR=value ...] — defaults describe a workflow_run for a ready head; arguments override.
# Sets OUT, RC, SUMMARY, STATUS_LOG, DISPATCH_LOG.
run_step() {
  rm -f "$ROOT/log/"* "$ROOT/summary.md"; : > "$ROOT/summary.md"
  OUT=$(env PATH="$ROOT/stub-bin:$PATH" GH_FIXTURE="$ROOT/fixture" GH_LOG="$ROOT/log" \
        EVENT_NAME=workflow_run REPO=example/repo GH_TOKEN=test \
        RUN_EVENT=pull_request RUN_CONCLUSION=success RUN_HEAD_REPO=example/repo RUN_ID=9001 RUN_PR_NUMBER=77 \
        PRT_DRAFT= PRT_HEAD_REPO= PRT_PR_NUMBER= HEAD_SHA="$HEAD" \
        GITHUB_STEP_SUMMARY="$ROOT/summary.md" "$@" bash "$STEP" 2>&1)
  RC=$?
  SUMMARY=$(cat "$ROOT/summary.md")
  STATUS_LOG=""; DISPATCH_LOG=""
  [[ -f "$ROOT/log/status.log" ]] && STATUS_LOG=$(cat "$ROOT/log/status.log")
  [[ -f "$ROOT/log/dispatch.log" ]] && DISPATCH_LOG=$(cat "$ROOT/log/dispatch.log")
}
# silent REASON-FRAGMENT MESSAGE — the last run wrote nothing, exited 0, and said why in the summary
silent() {
  if [[ $RC -eq 0 && -z "$STATUS_LOG" && -z "$DISPATCH_LOG" && "$SUMMARY" == *"$1"* ]]; then ok "$2"; else bad "$2 (rc=$RC status='$STATUS_LOG' dispatch='$DISPATCH_LOG' summary='$SUMMARY')"; fi
}
count_lines() { if [[ -z "$1" ]]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

echo "# a good workflow_run: one status, one dispatch, measurement printed"
run_step
if [[ $RC -eq 0 && "$(count_lines "$STATUS_LOG")" == 1 && "$(printf '%s' "$DISPATCH_LOG" | jq -s length)" == 1 ]]; then
  ok "emits exactly one status and one dispatch (rc=0)"
else bad "good run: rc=$RC statuses=$(count_lines "$STATUS_LOG") out=$OUT summary=$SUMMARY"; fi
want_status="repos/example/repo/statuses/$HEAD state=success context=review-ready description=claim-isolation and sensors green; ready for independent review"
if [[ "$STATUS_LOG" == "$want_status" ]]; then ok "status is review-ready=success at the exact head with the documented description"; else bad "status line: $STATUS_LOG"; fi
if [[ "$SUMMARY" == *"sensors_green_at: $SENSORS_AT"* && "$SUMMARY" == *"ready_emitted_at: 20"* && "$SUMMARY" == *"pr_opened_at: 2026-10-25T15:20:00Z"* && "$SUMMARY" == *"sensors green to ready emitted: "* ]]; then
  ok "summary prints sensors_green_at, ready_emitted_at, the PR open time and the wait in seconds"
else bad "summary: $SUMMARY"; fi

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
    ok "values: type review-ready, repo, numeric pr, head SHA, base SHA read from the PR, tier-unknown true, UTC ts"
  else bad "payload values: $DISPATCH_LOG"; fi
else bad "dispatch body is not JSON: $DISPATCH_LOG"; fi

echo "# workflow_run skips: nothing is written, the reason is in the summary"
run_step EVENT_NAME=push;               silent "event is push" "an event other than workflow_run / pull_request_target"
run_step RUN_EVENT=push;                silent "not pull_request" "the self-gate run was a push run (main), not a pull_request"
run_step RUN_CONCLUSION=failure;        silent "concluded failure" "the self-gate run failed"
run_step RUN_HEAD_REPO=someone/fork;    silent "fork" "the run's head is a fork"
run_step RUN_PR_NUMBER=;                silent "no pull request" "the run has no associated pull request"
run_step HEAD_SHA=;                     silent "no head SHA" "no head SHA in the event"

echo "# workflow_run skips decided by the API, not the payload"
write_run "$SG_PATH" push success "$HEAD" example/repo;               run_step; silent "event is push" "API says the run event is push (payload lied)"
write_run "$SG_PATH" pull_request failure "$HEAD" example/repo;       run_step; silent "concluded failure" "API says the run failed (payload lied)"
write_run "$SG_PATH" pull_request success "$HEAD" example/repo
jq '.pull_requests = [{number:12}]' "$ROOT/fixture/run.json" > "$ROOT/r.tmp" && mv "$ROOT/r.tmp" "$ROOT/fixture/run.json"
run_step; silent "does not belong to pull request 77" "the run belongs to a different PR that shares the commit: skips"
jq '.pull_requests = []' "$ROOT/fixture/run.json" > "$ROOT/r.tmp" && mv "$ROOT/r.tmp" "$ROOT/fixture/run.json"
run_step; silent "does not belong to pull request 77" "the run lists no pull request: skips"
write_run "$SG_PATH" pull_request success "$MOVED" example/repo;      run_step; silent "not $HEAD" "API says the run is for another head"
write_run "$SG_PATH" pull_request success "$HEAD" someone/fork;       run_step; silent "head is in someone/fork" "API says the run's head is a fork"
write_run ".github/workflows/evil.yml@refs/pull/9/merge" pull_request success "$HEAD" example/repo
run_step; silent "evil.yml" "a run of a different workflow file that merely shares the name is refused"
write_run "$SG_PATH@refs/pull/9/merge" pull_request success "$HEAD" example/repo
run_step; if [[ $RC -eq 0 && -n "$STATUS_LOG" ]]; then ok "the real self-gate path with a @ref suffix is accepted"; else bad "@ref-suffixed self-gate path refused: $SUMMARY"; fi
reset_world
write_jobs failure success;  run_step; silent "sensors job" "sensors not green: skips"
write_jobs success failure;  run_step; silent "claim-isolation job" "claim-isolation not green: skips"
write_jobs skipped success;  run_step; silent "sensors job" "sensors skipped: skips"
write_jobs success success
jq '.jobs |= map(select(.name != "claim-isolation"))' "$ROOT/fixture/jobs.json" > "$ROOT/j.tmp" && mv "$ROOT/j.tmp" "$ROOT/fixture/jobs.json"
run_step; silent "claim-isolation job" "claim-isolation job absent: skips"
reset_world
write_pull open true "$HEAD" example/repo;       run_step; silent "draft" "the PR is a draft: skips"
write_pull open false "$MOVED" example/repo;     run_step; silent "stale" "the PR moved to a newer head: the old run cannot signal"
write_pull closed false "$HEAD" example/repo;    run_step; silent "closed" "the PR is closed: skips"
write_pull open false "$HEAD" someone/fork;      run_step; silent "head is in someone/fork" "the PR head is a fork: skips"
reset_world

echo "# pull_request_target (a draft marked ready)"
PRT=(EVENT_NAME=pull_request_target RUN_EVENT= RUN_CONCLUSION= RUN_HEAD_REPO= RUN_ID= RUN_PR_NUMBER= PRT_DRAFT=false PRT_HEAD_REPO=example/repo PRT_PR_NUMBER=77)
run_step "${PRT[@]}"
if [[ $RC -eq 0 && "$STATUS_LOG" == "$want_status" && "$(printf '%s' "$DISPATCH_LOG" | jq -s length)" == 1 ]]; then ok "finds the latest successful self-gate run for the head and emits once"; else bad "pull_request_target good: rc=$RC out=$OUT summary=$SUMMARY"; fi
if [[ "$SUMMARY" == *"trigger pull_request_target"* && "$SUMMARY" == *"self-gate run 9001"* ]]; then ok "summary names the trigger and the run it found"; else bad "summary: $SUMMARY"; fi
run_step "${PRT[@]}" PRT_PR_NUMBER=12; silent "does not belong to pull request 12" "pull_request_target picks only a run that belongs to this PR (run 8001 is PR 12's and is newest, but run 9001 is PR 77's)"
run_step "${PRT[@]}" PRT_PR_NUMBER=abc; silent "not numeric" "a non-numeric PR number is refused before it reaches a jq filter"
run_step "${PRT[@]}" PRT_DRAFT=true;                 silent "draft" "pull_request_target on a draft: skips"
run_step "${PRT[@]}" PRT_HEAD_REPO=someone/fork;     silent "fork" "pull_request_target on a fork: skips"
echo '{"workflow_runs":[{"id":8000,"path":".github/workflows/other.yml","conclusion":"success","run_started_at":"2026-10-25T15:50:00Z"}]}' > "$ROOT/fixture/runs-list.json"
run_step "${PRT[@]}"; silent "no successful self-gate run" "no self-gate run at the head yet: skips (the workflow_run event signals later)"
reset_world

echo "# idempotent per head"
echo '[{"id":5,"context":"review-ready","state":"success"}]' > "$ROOT/fixture/statuses.json"
run_step; silent "already exists" "a review-ready success already at the head: no second status, no second dispatch"
echo '[{"id":6,"context":"review-ready","state":"pending"},{"id":7,"context":"other","state":"success"}]' > "$ROOT/fixture/statuses.json"
run_step
if [[ $RC -eq 0 && -n "$STATUS_LOG" && -n "$DISPATCH_LOG" ]]; then ok "only a review-ready SUCCESS suppresses (pending or another context does not)"; else bad "non-matching statuses: rc=$RC s=$STATUS_LOG"; fi
reset_world

echo "# a failure to emit is explained and never silent"
run_step FAIL_STATUSES_READ=1
if [[ $RC -ne 0 && -z "$STATUS_LOG" && -z "$DISPATCH_LOG" && "$SUMMARY" == *"could not read existing statuses"* ]]; then ok "cannot check idempotency: emits nothing, says why (the step is continue-on-error)"; else bad "read-fail rc=$RC sum=$SUMMARY"; fi
run_step FAIL_STATUS_POST=1
if [[ $RC -ne 0 && -z "$DISPATCH_LOG" && "$SUMMARY" == *"could not post the review-ready status"* ]]; then ok "status post fails: no dispatch, reason in the summary"; else bad "status-fail rc=$RC d=$DISPATCH_LOG sum=$SUMMARY"; fi
run_step FAIL_DISPATCH=1
if [[ $RC -ne 0 && -n "$STATUS_LOG" && "$SUMMARY" == *"repository_dispatch failed"* ]]; then ok "dispatch fails after the status: status stands, reason in the summary"; else bad "dispatch-fail rc=$RC s=$STATUS_LOG sum=$SUMMARY"; fi
rm -f "$ROOT/fixture/run.json"
run_step
if [[ $RC -ne 0 && -z "$STATUS_LOG" && "$SUMMARY" == *"could not read run"* ]]; then ok "run unreadable: emits nothing (a missing signal, never a false green), says why"; else bad "run-unreadable rc=$RC s=$STATUS_LOG sum=$SUMMARY"; fi
reset_world
rm -f "$ROOT/fixture/pull.json"
run_step
if [[ $RC -ne 0 && -z "$STATUS_LOG" && "$SUMMARY" == *"could not read pull request"* ]]; then ok "PR unreadable: emits nothing, says why"; else bad "pull-unreadable rc=$RC s=$STATUS_LOG sum=$SUMMARY"; fi
reset_world

echo
echo "review-ready.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
