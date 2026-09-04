#!/usr/bin/env bash
# pr-review-evidence.test.sh — Law 5 on the interactive path (#308).
# Every case asserts the REASON TOKEN, not just pass/fail (spec review: a
# boolean cannot prove the diagnostic). Fixtures load through the SAME code
# path as production (--fixture swaps only the transport), and the shipped
# config/review-evidence.v1.json is used unless a case is about config faults.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
EVAL="$REPO_ROOT/scripts/pr-review-evidence.mjs"
CFG="$REPO_ROOT/config/review-evidence.v1.json"
WF="$REPO_ROOT/.github/workflows/pr-review-evidence.yml"

PASS=0; FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
command -v node >/dev/null || { echo "pr-review-evidence.test.sh: node required"; exit 1; }
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-revev.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PREV=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
GROK='aie-agent-lanes-grok[bot]'; MINI='aie-agent-lanes-mini[bot]'; DEVIN='devin-ai-integration[bot]'; CR='coderabbitai[bot]'; OWNER=mrhinkle

# ---- fixture builders --------------------------------------------------------
fx_new() { d="$ROOT/$1"; mkdir -p "$d"; printf '{"number":1,"head":{"sha":"%s"},"user":{"login":"%s"}}' "$HEAD" "$OWNER" > "$d/pull.json"; echo '[]' > "$d/reviews.json"; echo '[]' > "$d/comments.json"; echo '[]' > "$d/commits.json"; echo "$d"; }
# commits: each arg is "authorLogin" or "authorLogin|committerLogin" ("-" = null login, "web-flow" allowed)
fx_commits() { d=$1; shift; { printf '['; sep=""; i=0; for spec in "$@"; do a=${spec%%|*}; c=${spec#*|}; [ "$c" = "$spec" ] && c=$a; i=$((i+1))
  al='null'; [ "$a" != "-" ] && al="{\"login\":\"$a\"}"; cl='null'; [ "$c" != "-" ] && cl="{\"login\":\"$c\"}"
  printf '%s{"sha":"c%039d","author":%s,"committer":%s,"commit":{"author":{"email":"x@example.invalid"},"committer":{"email":"x@example.invalid"}}}' "$sep" "$i" "$al" "$cl"; sep=","; done; printf ']'; } > "$d/commits.json"; }
# reviews: each arg "login|type|STATE|commit|id|ts"
fx_reviews() { d=$1; shift; { printf '['; sep=""; for spec in "$@"; do IFS='|' read -r l t s c id ts <<< "$spec"
  printf '%s{"id":%s,"user":{"login":"%s","type":"%s"},"state":"%s","commit_id":"%s","submitted_at":"%s","performed_via_github_app":null}' "$sep" "$id" "$l" "$t" "$s" "$c" "$ts"; sep=","; done; printf ']'; } > "$d/reviews.json"; }
# comments: each arg "login|assoc|appSlug|appId|id|ts|body"  (appSlug "-" = performed_via_github_app null)
fx_comments() { d=$1; shift; { printf '['; sep=""; for spec in "$@"; do IFS='|' read -r l assoc slug appid id ts body <<< "$spec"
  app='null'; [ "$slug" != "-" ] && app="{\"slug\":\"$slug\",\"id\":$appid}"
  printf '%s{"id":%s,"user":{"login":"%s","type":"Bot"},"author_association":"%s","performed_via_github_app":%s,"created_at":"%s","body":"%s"}' "$sep" "$id" "$l" "$assoc" "$app" "$ts" "$body"; sep=","; done; printf ']'; } > "$d/comments.json"; }
receipt() { printf '<!-- review-evidence:v1\\nhead-sha: %s\\nresult: %s\\n-->' "$1" "$2"; }
attest()  { printf '<!-- owner-review-attestation:v1\\nhead-sha: %s\\nauthor-vendor: %s\\n-->' "$1" "$2"; }

# run DIR [cfg] -> sets OUT RC REASON STATE
run() { OUT=$(node "$EVAL" --repo x/y --pr 1 --expected-head "$HEAD" --fixture "$1" --config "${2:-$CFG}" 2>"$ROOT/err"); RC=$?
  REASON=$(printf '%s' "$OUT" | sed -nE 's/.*"reason":"([^"]+)".*/\1/p'); STATE=$(printf '%s' "$OUT" | sed -nE 's/.*"state":"([^"]+)".*/\1/p'); }
expect() { # expect NAME DIR reason state rc [cfg]
  run "$2" "${6:-}"; if [ "$REASON" = "$3" ] && [ "$STATE" = "$4" ] && [ "$RC" -eq "$5" ]; then ok "$1 → $3/$4/rc=$5"; else bad "$1: want $3/$4/rc=$5 got ${REASON:-?}/${STATE:-?}/rc=$RC: $OUT $(cat "$ROOT/err")"; fi; }

echo "# CLI contract (CONVENTIONS 2.1)"
node "$EVAL" --definitely-not-a-flag >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown flag exits 2" || bad "unknown flag did not exit 2"
node "$EVAL" --repo x/y --pr 1 >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing --expected-head exits 2" || bad "missing required flag did not exit 2"
node "$EVAL" --repo >/dev/null 2>&1; [ $? -eq 2 ] && ok "flag without value exits 2" || bad "flag without value did not exit 2"

echo "# AC2 — evaluator scenarios against the SHIPPED config"
d=$(fx_new a); fx_commits "$d" "$GROK"; fx_reviews "$d" "$GROK|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(a) grok commits + grok APPROVE" "$d" same-vendor-reviewer failure 1
d=$(fx_new b); fx_commits "$d" "$DEVIN"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(b) devin commits + devin APPROVE" "$d" same-vendor-reviewer failure 1
d=$(fx_new c); fx_commits "$d" "$GROK" "$DEVIN"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(c) mixed grok+devin commits + devin APPROVE" "$d" same-vendor-reviewer failure 1
d=$(fx_new d); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(d) grok commits + devin APPROVE" "$d" pass success 0
d=$(fx_new e); fx_commits "$d" "$GROK"
expect "(e) no reviews" "$d" no-receipt-at-head pending 0
d=$(fx_new f); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$PREV|1|2026-09-04T10:00:00Z"
expect "(f) APPROVE at previous head only" "$d" stale-head-only pending 0
d=$(fx_new g); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(g) owner commits, no attestation, devin APPROVE" "$d" identity-unresolved failure 1
d=$(fx_new h); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" claude)"
expect "(h) owner commits + attestation claude + devin APPROVE" "$d" pass success 0
d=$(fx_new h2); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" devin)"
expect "(h2) attestation names the reviewer's vendor → same-vendor" "$d" same-vendor-reviewer failure 1
d=$(fx_new i); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$PREV" claude)"
expect "(i) attestation at previous head" "$d" identity-unresolved failure 1
d=$(fx_new i2); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|NONE|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" claude)"
expect "(i2) attestation from a non-member association" "$d" identity-unresolved failure 1
d=$(fx_new i3); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$GROK|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" claude)"
expect "(i3) attestation from a non-owner login" "$d" identity-unresolved failure 1
d=$(fx_new j); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z" "$DEVIN|Bot|CHANGES_REQUESTED|$HEAD|2|2026-09-04T11:00:00Z"
expect "(j) devin APPROVE then CHANGES_REQUESTED" "$d" changes-requested failure 1
d=$(fx_new k); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|CHANGES_REQUESTED|$HEAD|1|2026-09-04T10:00:00Z" "$DEVIN|Bot|APPROVED|$HEAD|2|2026-09-04T11:00:00Z"
expect "(k) devin CHANGES_REQUESTED then APPROVE" "$d" pass success 0
d=$(fx_new l); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$CR|NONE|coderabbitai|347564|7|2026-09-04T12:00:00Z|$(receipt "$HEAD" fail)"
expect "(l) fail receipt beside another identity's APPROVE" "$d" changes-requested failure 1
d=$(fx_new m); fx_commits "$d" "$GROK"; fx_comments "$d" "$DEVIN|NONE|devin-ai-integration|811515|7|2026-09-04T12:00:00Z|$(receipt "$HEAD" pass)"
expect "(m) app receipt pass, no formal review" "$d" pass success 0
d=$(fx_new n1); fx_commits "$d" "$GROK"; fx_reviews "$d" "$OWNER|User|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(n1) human APPROVE only" "$d" no-receipt-at-head pending 0
d=$(fx_new n2); fx_commits "$d" "$GROK"; fx_reviews "$d" "some-other-app[bot]|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(n2) unlisted App APPROVE only" "$d" no-receipt-at-head pending 0
d=$(fx_new n3); fx_commits "$d" "$GROK"; fx_comments "$d" "$DEVIN|NONE|-|0|7|2026-09-04T12:00:00Z|$(receipt "$HEAD" pass)"
expect "(n3) receipt with performed_via_github_app null" "$d" no-receipt-at-head pending 0
d=$(fx_new n4); fx_commits "$d" "$GROK"; fx_comments "$d" "$DEVIN|NONE|devin-ai-integration|999|7|2026-09-04T12:00:00Z|$(receipt "$HEAD" pass)"
expect "(n4) receipt with wrong app id" "$d" no-receipt-at-head pending 0
d=$(fx_new o); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|DISMISSED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(o) DISMISSED only" "$d" no-receipt-at-head pending 0
d=$(fx_new p); fx_commits "$d" "$GROK"; fx_reviews "$d" "$MINI|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(p) vendor-unknown identity (mini) APPROVE is never eligible" "$d" same-vendor-reviewer failure 1
d=$(fx_new q); fx_commits "$d" "$MINI"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(q) vendor-unknown author" "$d" identity-unresolved failure 1
d=$(fx_new r); fx_commits "$d" "stranger"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(r) unlisted author login" "$d" identity-unresolved failure 1
d=$(fx_new s); fx_commits "$d" "$GROK|web-flow"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(s) web-flow committer is ignored" "$d" pass success 0
d=$(fx_new t); fx_commits "$d" "$GROK|-"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(t) committer with no resolvable login" "$d" identity-unresolved failure 1
d=$(fx_new u); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; printf '{"number":1,"head":{"sha":"%s"},"user":{"login":"x"}}' "$PREV" > "$d/pull.json"
expect "(u) PR head moved since the event" "$d" head-moved failure 1
d=$(fx_new v); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" human)"
expect "(v) owner attests 'human' (wrote it himself) + devin APPROVE" "$d" pass success 0

echo "# AC3 — config and API faults never yield success"
d=$(fx_new f1); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "missing config" "$d" config-error failure 1 "$ROOT/does-not-exist.json"
printf '{not json' > "$ROOT/bad.json";            expect "invalid JSON" "$d" config-error failure 1 "$ROOT/bad.json"
node -e 'const c=require(process.argv[1]);c.extra=1;process.stdout.write(JSON.stringify(c))' "$CFG" > "$ROOT/unk.json"; expect "unknown top-level key" "$d" config-error failure 1 "$ROOT/unk.json"
node -e 'const c=require(process.argv[1]);c.identities[2].vendor="unknown";process.stdout.write(JSON.stringify(c))' "$CFG" > "$ROOT/unkv.json"; expect "listed reviewer set to vendor unknown → ineligible" "$d" same-vendor-reviewer failure 1 "$ROOT/unkv.json"
node -e 'const c=require(process.argv[1]);c.identities[2].bogus=1;process.stdout.write(JSON.stringify(c))' "$CFG" > "$ROOT/unki.json"; expect "unknown identity key" "$d" config-error failure 1 "$ROOT/unki.json"
node -e 'const c=require(process.argv[1]);c.identities.push({...c.identities[2]});process.stdout.write(JSON.stringify(c))' "$CFG" > "$ROOT/dup.json"; expect "duplicate login" "$d" config-error failure 1 "$ROOT/dup.json"
rm -f "$d/commits.json";                           expect "missing fixture input (transport error)" "$d" api-error failure 1
# live transport error: a gh stub that fails
mkdir -p "$ROOT/bin"; printf '#!/bin/sh\necho "stub: boom" >&2; exit 22\n' > "$ROOT/bin/gh"; chmod +x "$ROOT/bin/gh"
OUT=$(PATH="$ROOT/bin:$PATH" node "$EVAL" --repo x/y --pr 1 --expected-head "$HEAD" 2>/dev/null); RC=$?
printf '%s' "$OUT" | grep -q '"reason":"api-error"' && [ "$RC" -eq 1 ] && ok "gh api non-zero → api-error/failure" || bad "gh failure not api-error: rc=$RC $OUT"
printf '#!/bin/sh\necho "<html>not json"\n' > "$ROOT/bin/gh"; chmod +x "$ROOT/bin/gh"
OUT=$(PATH="$ROOT/bin:$PATH" node "$EVAL" --repo x/y --pr 1 --expected-head "$HEAD" 2>/dev/null); RC=$?
printf '%s' "$OUT" | grep -q '"reason":"api-error"' && [ "$RC" -eq 1 ] && ok "gh api non-JSON → api-error/failure" || bad "gh non-JSON not api-error: rc=$RC $OUT"

echo "# AC1 — workflow publish sequence (static + executed publish step with gh stubbed)"
[ -f "$WF" ] && ok "workflow file present" || bad "workflow missing"
grep -q '^permissions: {}' "$WF" && ok "workflow-level permissions: {}" || bad "no workflow-level permissions: {}"
grep -q 'gibson:approved-pr-target 308' "$WF" && ok "pull_request_target waiver present" || bad "pull_request_target waiver missing"
grep -q 'cancel-in-progress: true' "$WF" && ok "concurrency cancel-in-progress" || bad "no cancel-in-progress"
pend=$(grep -n 'Invalidate prior exact-head status' "$WF" | head -1 | cut -d: -f1); evl=$(grep -n 'name: Evaluate current-head review evidence' "$WF" | cut -d: -f1); pub=$(grep -n 'name: Publish exact-head status' "$WF" | cut -d: -f1)
[ -n "$pend" ] && [ -n "$evl" ] && [ "$pend" -lt "$evl" ] && ok "pending is posted BEFORE evaluation" || bad "pending step not before evaluate"
[ -n "$pub" ] && [ "$evl" -lt "$pub" ] && ok "publish step after evaluate" || bad "publish step order"
sed -n "${pub},\$p" "$WF" | grep -q 'if: always()' && ok "publish step runs on always()" || bad "publish step lacks always()"
sed -n "${evl},${pub}p" "$WF" | grep -q 'continue-on-error: true' && sed -n "${evl},${pub}p" "$WF" | grep -q '::notice::' && ok "evaluate step: continue-on-error with visible notice (3.5)" || bad "evaluate step skip is silent"
grep -E '^[[:space:]]*(- )?uses:' "$WF" | grep -vqE '@[0-9a-f]{40} # v' && bad "unpinned action" || ok "all actions SHA-pinned"
grep -qE 'git (log|fetch|checkout).*(head|HEAD)' "$WF" && bad "workflow touches PR git objects" || ok "no git log / PR checkout in workflow"
# Execute the publish step's shell with gh stubbed to capture the POSTed state.
awk -v s="$pub" 'NR>=s && /run: \|/{f=1;next} f && /^      - name:/{exit} f{sub(/^          /,""); print}' "$WF" > "$ROOT/publish.sh"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in state=*) echo "$a" >> "$GH_LOG";; esac; done\n' > "$ROOT/bin/gh"; chmod +x "$ROOT/bin/gh"
pubrun() { : > "$ROOT/gh.log"; : > "$ROOT/summary"; GH_LOG="$ROOT/gh.log" GITHUB_STEP_SUMMARY="$ROOT/summary" GH_REPO=x/y STATUS_CONTEXT=review-evidence HEAD_SHA=$HEAD TARGET_URL=http://t CANCELLED=$1 STATE=$2 REASON=$3 DESCRIPTION=$4 PATH="$ROOT/bin:$PATH" bash "$ROOT/publish.sh" >/dev/null 2>&1; cat "$ROOT/gh.log"; }
[ "$(pubrun false success pass 'pass: devin')" = "state=success" ] && ok "publish: success → success" || bad "publish success"
[ "$(pubrun false pending no-receipt-at-head 'x')" = "state=pending" ] && ok "publish: pending → pending" || bad "publish pending"
[ "$(pubrun false failure same-vendor-reviewer 'x')" = "state=failure" ] && ok "publish: failure → failure" || bad "publish failure"
[ "$(pubrun false '' '' '')" = "state=failure" ] && ok "publish: evaluator crashed (no outputs) → failure, never stale success" || bad "publish crash did not fail"
[ "$(pubrun true success pass 'x')" = "state=pending" ] && ok "publish: cancelled → pending (supersession is not a verdict)" || bad "publish cancelled"
grep -q 'may not be merged' "$ROOT/summary" && ok "non-success writes the merge-block line to the step summary" || bad "summary line missing"
if command -v actionlint >/dev/null 2>&1; then
  out=$(actionlint "$WF" 2>&1); [ $? -eq 0 ] && ok "actionlint clean" || bad "actionlint: $out"
else
  echo "  skip — actionlint not installed (ci-conventions covers it in CI)"
fi

echo
echo "pr-review-evidence.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
