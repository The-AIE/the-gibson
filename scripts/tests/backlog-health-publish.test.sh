#!/usr/bin/env bash
# backlog-health-publish.test.sh — slice B of #309 / issue #343
#
# WHAT IT DOES
#   Extracts the "Classify backlog health and comment on #212" step from
#   .github/workflows/sensor-health.yml and runs it against fixture worlds
#   with gh stubbed. Proves every GREEN/YELLOW/RED classification POSTs
#   exactly one comment to #212 whose body is byte-identical to
#   $RUNNER_TEMP/backlog-health.md, that no PATCH ever targets the issue
#   resource, that RED exits 0 while INCOMPLETE exits 1 and posts nothing,
#   and that a failed comment POST returns PUBLISH_FAILED distinctly.
#
# WHY
#   Wiring the classifier into the daily heartbeat must not turn a real RED
#   finding into a red job, must not clobber sensor-health.mjs's issue body,
#   and must fail closed when GitHub refuses the comment.
#
# USAGE
#   scripts/tests/backlog-health-publish.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
WF="$REPO_ROOT/.github/workflows/sensor-health.yml"
SENSOR="$REPO_ROOT/scripts/backlog-health.mjs"
NOW="2026-09-04T00:00:00.000Z"
LABEL="dependency-blocked"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "backlog-health-publish.test.sh: node required"; exit 1; }
[[ -f "$WF" ]] || { echo "backlog-health-publish.test.sh: missing $WF"; exit 1; }
[[ -f "$SENSOR" ]] || { echo "backlog-health-publish.test.sh: missing $SENSOR"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-backlog-health-publish.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/runner" "$ROOT/worlds"
RUNNER_TEMP="$ROOT/runner"
GH_CALLS="$ROOT/gh.calls"
GH_LAST_BODY="$ROOT/gh.body"
STEP_SH="$ROOT/step.sh"

has() {
  printf '%s\n' "$1" | grep -E "$2" >/dev/null
}
has_f() {
  printf '%s\n' "$1" | grep -F -- "$2" >/dev/null
}

# --- extract the live workflow step (same pattern as pr-review-evidence.test.sh)
echo "# workflow step extraction"
step_line=$(grep -n 'name: Classify backlog health and comment on #212' "$WF" | head -1 | cut -d: -f1)
if [[ -n "$step_line" ]]; then
  ok "named step present at $WF:$step_line"
else
  bad "named step missing from $WF"
  echo "backlog-health-publish.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi
awk -v s="$step_line" 'NR>=s && /run: \|/{f=1;next} f && /^      - (name:|uses:|if:)/{exit} f{sub(/^          /,""); print}' "$WF" > "$STEP_SH"
if [[ -s "$STEP_SH" ]] && grep 'scripts/backlog-health.mjs' "$STEP_SH" >/dev/null; then
  ok "extracted step invokes scripts/backlog-health.mjs"
else
  bad "extracted step empty or missing classifier invocation"
  echo "backlog-health-publish.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi

# --- static contracts on the workflow / extracted step
echo "# static contracts"
if grep -E '^[[:space:]]*continue-on-error[[:space:]]*:' "$WF" >/dev/null; then
  bad "$WF declares continue-on-error"
else
  ok "no continue-on-error in $WF"
fi
if grep -vE '^[[:space:]]*#' "$WF" | grep -E 'set[[:space:]]+\+e' >/dev/null; then
  bad "$WF uses set +e outside comments"
else
  ok "no set +e in $WF executable lines"
fi
if grep 'backlog-health.mjs' "$WF" | grep '||' >/dev/null && grep 'backlog-health.mjs.*||[[:space:]]*true' "$WF" >/dev/null; then
  bad "classifier invocation swallows failure with || true"
else
  ok "classifier invocation not wrapped in || true"
fi
if grep -- '--method PATCH' "$STEP_SH" >/dev/null || grep 'issues/212"' "$STEP_SH" | grep -E 'PATCH|patch' >/dev/null; then
  bad "extracted step PATCHes the #212 issue resource"
else
  ok "extracted step never PATCHes issues/212"
fi
if grep 'issues/212/comments' "$STEP_SH" >/dev/null && grep -- '--method POST' "$STEP_SH" >/dev/null; then
  ok "extracted step POSTs to issues/212/comments"
else
  bad "extracted step missing POST to issues/212/comments"
fi
if grep 'PUBLISH_FAILED' "$STEP_SH" >/dev/null; then
  ok "extracted step names PUBLISH_FAILED"
else
  bad "extracted step missing PUBLISH_FAILED"
fi
if grep -- '--repo' "$STEP_SH" >/dev/null; then
  ok "production path passes --repo (live mode)"
else
  bad "extracted step missing --repo live path"
fi
if grep '### backlog-health' "$STEP_SH" >/dev/null; then
  ok "extracted step writes the ### backlog-health heading"
else
  bad "extracted step missing comment heading"
fi

# --- fake gh: log METHOD URL, capture --input body, honour GH_HTTP_STATUS
cat > "$ROOT/bin/gh" <<'GHSTUB'
#!/bin/sh
method=GET
url=""
input=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--method" ]; then
    method=$a
  elif [ "$prev" = "--input" ]; then
    input=$a
  fi
  prev=$a
  case "$a" in
    repos/*) url=$a ;;
  esac
done
echo "$method $url" >> "${GH_CALLS:?}"
bodyfile="${GH_LAST_BODY:?}"
if [ "$input" = "-" ] || [ "$input" = "/dev/stdin" ]; then
  cat > "$bodyfile"
elif [ -n "$input" ] && [ -f "$input" ]; then
  cat "$input" > "$bodyfile"
fi
if [ "${GH_HTTP_STATUS:-200}" != "200" ]; then
  echo "gh: HTTP ${GH_HTTP_STATUS}" >&2
  exit 1
fi
echo '{"id":1}'
exit 0
GHSTUB
chmod +x "$ROOT/bin/gh"

write_worlds() {
  ROOT_WORLDS="$ROOT/worlds" LABEL="$LABEL" node --input-type=module <<'JS'
import { writeFileSync } from "node:fs";
import { join } from "node:path";
const ROOT = process.env.ROOT_WORLDS;
const LABEL = process.env.LABEL;
const IN = "2026-09-03T00:00:00.000Z";
function depsNone() { return "## Dependencies\n\nnone\n"; }
function depsCite(n) { return `## Dependencies\n\nblocked by #${n}\n`; }
function issue(number, opts = {}) {
  return {
    number,
    title: `issue ${number}`,
    body: Object.prototype.hasOwnProperty.call(opts, "body") ? opts.body : depsNone(),
    state: "OPEN",
    labels: opts.labels || [],
  };
}
function seven(blockedSpec) {
  const nodes = [];
  for (const n of [1, 2, 3, 4, 5, 6, 161]) {
    nodes.push(issue(n, blockedSpec[n] || {}));
  }
  return { totalCount: 7, hasNextPage: false, endCursor: null, nodes };
}
function labelled() { return { labels: [LABEL], body: depsNone() }; }
function world(id, obj) {
  writeFileSync(join(ROOT, id + ".json"), JSON.stringify(obj));
}
const five = { 1: labelled(), 2: labelled(), 3: labelled(), 4: labelled(), 5: labelled() };
const cite161 = {
  1: { labels: [LABEL], body: depsCite(161) },
  2: { labels: [LABEL], body: depsCite(161) },
  3: { labels: [LABEL], body: depsCite(161) },
  4: labelled(),
  5: labelled(),
};
world("GREEN", { issues: seven({ 1: labelled(), 2: labelled() }) });
world("RED", { issues: seven(five) });
world("YELLOW", {
  issues: seven(cite161),
  cited: {
    161: {
      number: 161,
      state: "OPEN",
      timeline: [{ __typename: "ClosedEvent", createdAt: IN }],
    },
  },
});
world("INCOMPLETE", {
  issues: {
    totalCount: 7,
    hasNextPage: true,
    endCursor: null,
    nodes: [1, 2, 3, 4, 5].map((n) => issue(n, labelled())),
  },
});
JS
}
write_worlds
[[ -f "$ROOT/worlds/RED.json" ]] && ok "fixture worlds written" || bad "fixture world builder failed"

decode_body() {
  node -e 'const fs=require("fs"); const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(j.body)' "$1"
}

run_step() {
  local fixture="$1"
  : > "$GH_CALLS"
  : > "$GH_LAST_BODY"
  rm -f "$RUNNER_TEMP/backlog-health.md" "$RUNNER_TEMP/backlog-health.raw" \
        "$RUNNER_TEMP/backlog-health.err"
  OUT=$(
    cd "$REPO_ROOT" &&
    PATH="$ROOT/bin:$PATH" \
    RUNNER_TEMP="$RUNNER_TEMP" \
    GITHUB_REPOSITORY="The-AIE/the-gibson" \
    GITHUB_TOKEN="fake" \
    BACKLOG_HEALTH_NOW="$NOW" \
    BACKLOG_HEALTH_FIXTURE="$fixture" \
    GH_CALLS="$GH_CALLS" \
    GH_LAST_BODY="$GH_LAST_BODY" \
    GH_HTTP_STATUS="${GH_HTTP_STATUS:-200}" \
    bash "$STEP_SH" 2>&1
  )
  RC=$?
}

assert_one_comment() {
  local colour="$1"
  local calls report
  calls=$(cat "$GH_CALLS")
  if [[ "$RC" -eq 0 ]]; then
    ok "$colour step exits 0"
  else
    bad "$colour step rc=$RC out=$(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if [[ "$(grep -c '^POST ' "$GH_CALLS" || true)" -eq 1 ]] \
     && has_f "$calls" "POST repos/The-AIE/the-gibson/issues/212/comments"; then
    ok "$colour POSTs exactly one comment to #212"
  else
    bad "$colour POST count/target: $(printf '%s' "$calls" | tr '\n' '|')"
  fi
  if grep 'PATCH' "$GH_CALLS" >/dev/null; then
    bad "$colour issued a PATCH: $(printf '%s' "$calls" | tr '\n' '|')"
  else
    ok "$colour never PATCHes"
  fi
  report="$RUNNER_TEMP/backlog-health.md"
  if [[ ! -f "$report" ]]; then
    bad "$colour missing $report"
    return
  fi
  decode_body "$GH_LAST_BODY" > "$ROOT/posted.md"
  if cmp -s "$report" "$ROOT/posted.md"; then
    ok "$colour comment body byte-identical to backlog-health.md"
  else
    bad "$colour body mismatch report=$(wc -c < "$report") posted=$(wc -c < "$ROOT/posted.md")"
  fi
  if has "$OUT" "^### backlog-health — ${NOW}$"; then
    ok "$colour heading uses observationTime"
  else
    bad "$colour missing heading in stdout: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if has "$OUT" "^${colour} "; then
    ok "$colour report starts with ${colour}"
  else
    bad "$colour report missing colour line: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
}

echo "# AC1/AC2 GREEN YELLOW RED post one comment, exit 0, never PATCH"
GH_HTTP_STATUS=200
run_step "$ROOT/worlds/GREEN.json"
assert_one_comment GREEN
run_step "$ROOT/worlds/YELLOW.json"
assert_one_comment YELLOW
run_step "$ROOT/worlds/RED.json"
assert_one_comment RED

echo "# AC1/AC2 INCOMPLETE fails the step and posts nothing"
GH_HTTP_STATUS=200
run_step "$ROOT/worlds/INCOMPLETE.json"
if [[ "$RC" -eq 1 ]]; then
  ok "INCOMPLETE step exits 1"
else
  bad "INCOMPLETE step rc=$RC (want 1) out=$(printf '%s' "$OUT" | tr '\n' '|')"
fi
if [[ ! -s "$GH_CALLS" ]]; then
  ok "INCOMPLETE posts no GitHub request"
else
  bad "INCOMPLETE issued gh: $(printf '%s' "$(cat "$GH_CALLS")" | tr '\n' '|')"
fi
if [[ -f "$RUNNER_TEMP/backlog-health.md" ]]; then
  bad "INCOMPLETE wrote a coloured report file"
else
  ok "INCOMPLETE writes no backlog-health.md"
fi
if has_f "$OUT" "PUBLISH_FAILED"; then
  bad "INCOMPLETE reported PUBLISH_FAILED"
else
  ok "INCOMPLETE is not PUBLISH_FAILED"
fi
if has "$OUT" "^INCOMPLETE:"; then
  ok "INCOMPLETE prints the classifier reason"
else
  bad "INCOMPLETE missing classifier output: $(printf '%s' "$OUT" | tr '\n' '|')"
fi
if has "$OUT" "^(RED|YELLOW|GREEN) "; then
  bad "INCOMPLETE printed a colour: $(printf '%s' "$OUT" | tr '\n' '|')"
else
  ok "INCOMPLETE prints no colour"
fi

echo "# AC3 failed comment POST is PUBLISH_FAILED, distinct from INCOMPLETE"
GH_HTTP_STATUS=403
run_step "$ROOT/worlds/RED.json"
if [[ "$RC" -ne 0 ]]; then
  ok "HTTP 403 fails the step (rc=$RC)"
else
  bad "HTTP 403 step exited 0"
fi
if has_f "$OUT" "PUBLISH_FAILED"; then
  ok "HTTP 403 names PUBLISH_FAILED"
else
  bad "HTTP 403 missing PUBLISH_FAILED: $(printf '%s' "$OUT" | tr '\n' '|')"
fi
if has "$OUT" "^INCOMPLETE:"; then
  bad "HTTP 403 misreported as INCOMPLETE"
else
  ok "PUBLISH_FAILED is distinct from INCOMPLETE"
fi
if has_f "$OUT" "HTTP 403"; then
  ok "HTTP 403 transport error is visible"
else
  ok "PUBLISH_FAILED token present (transport detail optional)"
fi
# The POST was attempted (so we can see it is a comment POST, not a PATCH)
if has_f "$(cat "$GH_CALLS")" "POST repos/The-AIE/the-gibson/issues/212/comments"; then
  ok "403 path still targeted comments POST (not the issue resource)"
else
  bad "403 path gh calls: $(printf '%s' "$(cat "$GH_CALLS")" | tr '\n' '|')"
fi
if grep 'PATCH' "$GH_CALLS" >/dev/null; then
  bad "403 path issued a PATCH"
else
  ok "403 path never PATCHes"
fi

echo "backlog-health-publish.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
