#!/usr/bin/env bash
# pr-review-evidence.test.sh — Law 5 on the interactive path (#308).
# Every case asserts the REASON TOKEN, not just pass/fail (spec review: a
# boolean cannot prove the diagnostic). Fixtures load through the SAME code
# path as production (--fixture swaps only the transport), and the shipped
# config/review-evidence.v1.json is used unless a case is about config faults.
# The workflow's shell steps are extracted and EXECUTED with gh stubbed.
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
mkdir -p "$ROOT/bin"

HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PREV=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
GROK='aie-agent-lanes-grok[bot]'; MINI='aie-agent-lanes-mini[bot]'; DEVIN='devin-ai-integration[bot]'; CR='coderabbitai[bot]'; OWNER=mrhinkle

# ---- fixture builders --------------------------------------------------------
fx_pull() { printf '{"number":1,"commits":%s,"head":{"sha":"%s"},"user":{"login":"%s"}}' "$2" "$HEAD" "$OWNER" > "$1/pull.json"; }
fx_new() { d="$ROOT/$1"; mkdir -p "$d"; fx_pull "$d" 0; echo '[]' > "$d/reviews.json"; echo '[]' > "$d/comments.json"; echo '[]' > "$d/commits.json"; echo "$d"; }
# commits: each arg "authorLogin[|committerLogin[|verified]]" ("-" = null login; "web-flow" allowed;
# verified defaults to true = GitHub-signed, the only case a login is trusted without attestation)
fx_commits() { d=$1; shift; { printf '['; sep=""; i=0; for spec in "$@"; do IFS='|' read -r a c v <<< "$spec"; [ -z "$c" ] && c=$a; [ -z "$v" ] && v=true; i=$((i+1))
  al='null'; [ "$a" != "-" ] && al="{\"login\":\"$a\"}"; cl='null'; [ "$c" != "-" ] && cl="{\"login\":\"$c\"}"
  printf '%s{"sha":"c%039d","author":%s,"committer":%s,"commit":{"verification":{"verified":%s,"reason":"fixture"},"author":{"email":"x@example.invalid"},"committer":{"email":"x@example.invalid"}}}' "$sep" "$i" "$al" "$cl" "$v"; sep=","; done; printf ']'; } > "$d/commits.json"; fx_pull "$d" "$#"; }
# reviews: each arg "login|type|STATE|commit|id|ts"
fx_reviews() { d=$1; shift; { printf '['; sep=""; for spec in "$@"; do IFS='|' read -r l t s c id ts <<< "$spec"
  printf '%s{"id":%s,"user":{"login":"%s","type":"%s"},"state":"%s","commit_id":"%s","submitted_at":"%s","performed_via_github_app":null}' "$sep" "$id" "$l" "$t" "$s" "$c" "$ts"; sep=","; done; printf ']'; } > "$d/reviews.json"; }
# comments: each arg "login|assoc|appSlug|appId|id|ts|body[|editor]"  (appSlug "-" = performed_via_github_app null; editor = login of last editor)
fx_comments() { d=$1; shift; { printf '['; sep=""; for spec in "$@"; do IFS='|' read -r l assoc slug appid id ts body editor <<< "$spec"
  app='null'; [ "$slug" != "-" ] && app="{\"slug\":\"$slug\",\"id\":$appid}"; ed=''; [ -n "${editor:-}" ] && ed=",\"editor\":\"$editor\""
  printf '%s{"id":%s,"user":{"login":"%s","type":"Bot"},"author_association":"%s","performed_via_github_app":%s,"created_at":"%s","body":"%s"%s}' "$sep" "$id" "$l" "$assoc" "$app" "$ts" "$body" "$ed"; sep=","; done; printf ']'; } > "$d/comments.json"; }
fx_timeline() { printf '[{"event":"base_ref_changed","created_at":"%s"}]' "$2" > "$1/timeline.json"; }
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
node "$EVAL" --repo x/y --sweep --pr 1 >/dev/null 2>&1; [ $? -eq 2 ] && ok "--sweep rejects --pr" || bad "--sweep with --pr did not exit 2"

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
d=$(fx_new n1); fx_commits "$d" "$GROK"; fx_reviews "$d" "some-human|User|APPROVED|$HEAD|1|2026-09-04T10:00:00Z" "$DEVIN|User|APPROVED|$HEAD|2|2026-09-04T10:00:00Z"
expect "(n1) human APPROVE, and a listed login with user.type User" "$d" no-receipt-at-head pending 0
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
expect "(s) GitHub-signed web-flow committer is ignored" "$d" pass success 0
d=$(fx_new t); fx_commits "$d" "$GROK|-"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(t) committer with no resolvable login" "$d" identity-unresolved failure 1
d=$(fx_new u); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; printf '{"number":1,"commits":1,"head":{"sha":"%s"},"user":{"login":"x"}}' "$PREV" > "$d/pull.json"
expect "(u) PR head moved since the event" "$d" head-moved failure 1
d=$(fx_new v); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" human)"
expect "(v) owner attests 'human' (wrote it himself) + devin APPROVE" "$d" pass success 0

echo "# Codex round 1 — five false-success paths, each closed"
d=$(fx_new w1); fx_commits "$d" "$GROK|$GROK|false"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(w1) UNVERIFIED grok-login commit, no attestation (email is forgeable)" "$d" identity-unresolved failure 1
d=$(fx_new w2); fx_commits "$d" "$GROK|$GROK|false"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" grok)"
expect "(w2) unverified grok commit + owner attests grok + devin APPROVE" "$d" pass success 0
d=$(fx_new w3); fx_commits "$d" "$GROK|$GROK|false"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" devin)"
expect "(w3) forged grok login on a devin commit: attestation names devin → same-vendor" "$d" same-vendor-reviewer failure 1
d=$(fx_new w4); fx_commits "$d" "$DEVIN|web-flow|false"; fx_reviews "$d" "$GROK|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "(w4) forged web-flow committer (unverified) is not ignored" "$d" identity-unresolved failure 1
d=$(fx_new w6); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; printf '[{"number":1,"state":"open","head":{"sha":"%s"}},{"number":2,"state":"open","head":{"sha":"%s"}}]' "$HEAD" "$HEAD" > "$d/pulls-for-head.json"
expect "(w6) head shared by two open PRs" "$d" ambiguous-head failure 1
d=$(fx_new w7); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; printf '[{"number":2,"state":"open","head":{"sha":"%s"}},{"number":1,"state":"closed","head":{"sha":"%s"}}]' "$HEAD" "$HEAD" > "$d/pulls-for-head.json"
expect "(w7) head belongs to a different open PR" "$d" ambiguous-head failure 1
d=$(fx_new w8); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_pull "$d" 3
expect "(w8) PR declares more commits than the API returned (250 cap)" "$d" api-error failure 1
d=$(fx_new w9); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|CHANGES_REQUESTED|$HEAD|9|2026-09-04T10:00:00Z"; fx_comments "$d" "$DEVIN|NONE|devin-ai-integration|811515|99999|2026-09-04T10:00:00Z|$(receipt "$HEAD" pass)"
expect "(w9) same-second pass comment vs CHANGES_REQUESTED review: fail dominates" "$d" changes-requested failure 1

echo "# Codex round 2 — four more paths, each closed"
d=$(fx_new x1); fx_commits "$d" "$GROK|$GROK|false" "$DEVIN|$DEVIN|false"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" grok)"
expect "(x1) mixed UNSIGNED grok+devin, attestation grok, devin APPROVE: attestation unions, never launders" "$d" same-vendor-reviewer failure 1
d=$(fx_new x2); fx_commits "$d" "$GROK|$GROK|false" "$DEVIN|$DEVIN|false"; fx_reviews "$d" "$CR|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" 'grok, devin')"
expect "(x2) attestation lists both vendors; a third vendor (coderabbit) reviews" "$d" pass success 0
d=$(fx_new x3); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" 'claude,bogus')"
expect "(x3) attestation list with an unknown vendor is ignored whole" "$d" identity-unresolved failure 1
d=$(fx_new x4); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; printf '[{"number":1,"state":"open","head":{"sha":"%s"}},{"number":2,"state":"open","head":{"sha":"%s"}}]' "$HEAD" "$PREV" > "$d/pulls-for-head.json"
expect "(x4) a stacked PR merely CONTAINING this head is not a sibling" "$d" pass success 0
d=$(fx_new x5); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; printf '[{"number":1,"state":"open","head":{"sha":"%s"}},{"number":2,"state":"closed","head":{"sha":"%s"}}]' "$HEAD" "$HEAD" > "$d/pulls-for-head.json"
expect "(x5) sibling with the same head has closed → unambiguous again" "$d" pass success 0

echo "# Codex round 4 — comment mutation, dismissal resurrection, base retarget"
d=$(fx_new y1); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" claude)|$GROK"
expect "(y1) owner attestation EDITED by another writer is ignored" "$d" identity-unresolved failure 1
d=$(fx_new y2); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_comments "$d" "$OWNER|MEMBER|-|0|5|2026-09-04T09:00:00Z|$(attest "$HEAD" claude)|$OWNER"
expect "(y2) owner attestation edited by the owner still counts" "$d" pass success 0
d=$(fx_new y3); fx_commits "$d" "$GROK"; fx_comments "$d" "$DEVIN|NONE|devin-ai-integration|811515|7|2026-09-04T12:00:00Z|$(receipt "$HEAD" pass)|$OWNER"
expect "(y3) app receipt edited by a human is ignored" "$d" no-receipt-at-head pending 0
d=$(fx_new y4); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z" "$DEVIN|Bot|CHANGES_REQUESTED|$HEAD|2|2026-09-04T11:00:00Z" "$DEVIN|Bot|DISMISSED|$HEAD|3|2026-09-04T12:00:00Z"
expect "(y4) APPROVE, CHANGES_REQUESTED, then a dismissal: nothing resurrects the approve" "$d" no-receipt-at-head pending 0
d=$(fx_new y5); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"; fx_timeline "$d" "2026-09-04T11:00:00Z"
expect "(y5) base retargeted AFTER the approve → stale-base" "$d" stale-base pending 0
d=$(fx_new y6); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T12:00:00Z"; fx_timeline "$d" "2026-09-04T11:00:00Z"
expect "(y6) approve AFTER the retarget → pass" "$d" pass success 0

echo "# Codex round 5 — edit/delete tombstones, equal-second retarget, attestation order, nullable editor"
d=$(fx_new z1); fx_commits "$d" "$GROK"; fx_comments "$d" "$DEVIN|NONE|devin-ai-integration|811515|7|2026-09-04T12:00:00Z|$(receipt "$HEAD" pass)"; printf '[{"event":"comment_deleted","created_at":"2026-09-04T13:00:00Z"}]' > "$d/timeline.json"
expect "(z1) a comment deleted AFTER the newest pass voids it (a deleted fail is invisible to REST)" "$d" evidence-deleted pending 0
d=$(fx_new z2); fx_commits "$d" "$GROK"; fx_comments "$d" "$DEVIN|NONE|devin-ai-integration|811515|7|2026-09-04T12:00:00Z|$(receipt "$HEAD" pass)"; printf '[{"event":"comment_deleted","created_at":"2026-09-04T11:00:00Z"}]' > "$d/timeline.json"
expect "(z2) a comment deleted BEFORE the pass does not void it" "$d" pass success 0
d=$(fx_new z3); fx_commits "$d" "$GROK"; fx_comments "$d" "$DEVIN|NONE|devin-ai-integration|811515|7|2026-09-04T12:00:00Z|$(receipt "$HEAD" pass)|$DEVIN"
expect "(z3) an App receipt edited even by its own login is void" "$d" no-receipt-at-head pending 0
d=$(fx_new z4); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T11:00:00Z"; fx_timeline "$d" "2026-09-04T11:00:00Z"
expect "(z4) retarget in the SAME second as the approve → stale-base" "$d" stale-base pending 0
d=$(fx_new z5); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T12:00:00Z"
printf '[{"id":5,"user":{"login":"%s","type":"User"},"author_association":"MEMBER","performed_via_github_app":null,"created_at":"2026-09-04T09:00:00Z","updated_at":"2026-09-04T13:00:00Z","body":"%s"},{"id":6,"user":{"login":"%s","type":"User"},"author_association":"MEMBER","performed_via_github_app":null,"created_at":"2026-09-04T10:00:00Z","updated_at":"2026-09-04T10:00:00Z","body":"%s"}]' "$OWNER" "$(attest "$HEAD" claude)" "$OWNER" "$(attest "$HEAD" devin)" > "$d/comments.json"
expect "(z5) older attestation (claude) edited later does not outrank the newer one (devin) → same-vendor" "$d" same-vendor-reviewer failure 1
d=$(fx_new z6); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T12:00:00Z"
printf '[{"id":5,"user":{"login":"%s","type":"User"},"author_association":"MEMBER","performed_via_github_app":null,"created_at":"2026-09-04T09:00:00Z","edited":true,"body":"%s"}]' "$OWNER" "$(attest "$HEAD" claude)" > "$d/comments.json"
expect "(z6) attestation edited with NO recorded editor → unknown provenance, ignored" "$d" identity-unresolved failure 1

echo "# Codex round 6 — tombstones not absences, same-second dismissal, trigger trust boundary, pending before checkout, publish freshness"
d=$(fx_new q1); fx_commits "$d" "$GROK"; fx_comments "$d" "$DEVIN|NONE|devin-ai-integration|811515|7|2026-09-04T12:00:00Z|$(receipt "$HEAD" pass)" "$DEVIN|NONE|devin-ai-integration|811515|8|2026-09-04T13:00:00Z|$(receipt "$HEAD" fail)|$OWNER"
expect "(q1) newer FAIL receipt edited by a writer is a tombstone: older pass does not resurrect" "$d" no-receipt-at-head pending 0
d=$(fx_new q2); fx_commits "$d" "$OWNER"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T12:00:00Z"
printf '[{"id":5,"user":{"login":"%s","type":"User"},"author_association":"MEMBER","performed_via_github_app":null,"created_at":"2026-09-04T09:00:00Z","body":"%s"},{"id":6,"user":{"login":"%s","type":"User"},"author_association":"MEMBER","performed_via_github_app":null,"created_at":"2026-09-04T10:00:00Z","editor":"%s","body":"%s"}]' "$OWNER" "$(attest "$HEAD" claude)" "$OWNER" "$GROK" "$(attest "$HEAD" devin)" > "$d/comments.json"
expect "(q2) newest attestation (devin) tampered by another writer: older (claude) does NOT fall through" "$d" identity-unresolved failure 1
d=$(fx_new q3); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|10|2026-09-04T10:00:00Z" "$DEVIN|Bot|CHANGES_REQUESTED|$HEAD|11|2026-09-04T10:00:00Z" "$DEVIN|Bot|DISMISSED|$HEAD|12|2026-09-04T10:00:00Z"
expect "(q3) same-second approve, changes-requested, dismissal: higher review id wins → no evidence" "$d" no-receipt-at-head pending 0
d=$(fx_new q4); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|CHANGES_REQUESTED|$HEAD|10|2026-09-04T10:00:00Z" "$DEVIN|Bot|APPROVED|$HEAD|11|2026-09-04T10:00:00Z"
expect "(q4) same-second changes-requested then approve (higher id): pass" "$d" pass success 0

echo "# AC3 — config and API faults never yield success"
d=$(fx_new f1); fx_commits "$d" "$GROK"; fx_reviews "$d" "$DEVIN|Bot|APPROVED|$HEAD|1|2026-09-04T10:00:00Z"
expect "missing config" "$d" config-error failure 1 "$ROOT/does-not-exist.json"
printf '{not json' > "$ROOT/bad.json";            expect "invalid JSON" "$d" config-error failure 1 "$ROOT/bad.json"
node -e 'const c=require(process.argv[1]);c.extra=1;process.stdout.write(JSON.stringify(c))' "$CFG" > "$ROOT/unk.json"; expect "unknown top-level key" "$d" config-error failure 1 "$ROOT/unk.json"
node -e 'const c=require(process.argv[1]);c.identities[2].vendor="unknown";process.stdout.write(JSON.stringify(c))' "$CFG" > "$ROOT/unkv.json"; expect "listed reviewer set to vendor unknown → ineligible" "$d" same-vendor-reviewer failure 1 "$ROOT/unkv.json"
node -e 'const c=require(process.argv[1]);c.identities[2].bogus=1;process.stdout.write(JSON.stringify(c))' "$CFG" > "$ROOT/unki.json"; expect "unknown identity key" "$d" config-error failure 1 "$ROOT/unki.json"
node -e 'const c=require(process.argv[1]);c.identities.push({...c.identities[2]});process.stdout.write(JSON.stringify(c))' "$CFG" > "$ROOT/dup.json"; expect "duplicate login" "$d" config-error failure 1 "$ROOT/dup.json"
rm -f "$d/commits.json";                           expect "missing fixture input (transport error)" "$d" api-error failure 1
printf '#!/bin/sh\necho "stub: boom" >&2; exit 22\n' > "$ROOT/bin/gh"; chmod +x "$ROOT/bin/gh"
OUT=$(PATH="$ROOT/bin:$PATH" node "$EVAL" --repo x/y --pr 1 --expected-head "$HEAD" 2>/dev/null); RC=$?
printf '%s' "$OUT" | grep -q '"reason":"api-error"' && [ "$RC" -eq 1 ] && ok "gh api non-zero → api-error/failure" || bad "gh failure not api-error: rc=$RC $OUT"
printf '#!/bin/sh\necho "<html>not json"\n' > "$ROOT/bin/gh"; chmod +x "$ROOT/bin/gh"
OUT=$(PATH="$ROOT/bin:$PATH" node "$EVAL" --repo x/y --pr 1 --expected-head "$HEAD" 2>/dev/null); RC=$?
printf '%s' "$OUT" | grep -q '"reason":"api-error"' && [ "$RC" -eq 1 ] && ok "gh api non-JSON → api-error/failure" || bad "gh non-JSON not api-error: rc=$RC $OUT"
OUT=$(PATH="$ROOT/bin:$PATH" node "$EVAL" --repo x/y --sweep 2>/dev/null); RC=$?
printf '%s' "$OUT" | grep -q '"reason":"api-error"' && [ "$RC" -eq 1 ] && ok "--sweep: open-PR listing failure → api-error line, exit 1" || bad "sweep listing failure: rc=$RC $OUT"

echo "# AC1 — workflow: sweep design (static + executed steps with gh stubbed)"
[ -f "$WF" ] && ok "workflow file present" || bad "workflow missing"
grep -q '^permissions: {}' "$WF" && ok "workflow-level permissions: {}" || bad "no workflow-level permissions: {}"
grep -q 'gibson:approved-pr-target 308' "$WF" && ok "pull_request_target waiver present" || bad "pull_request_target waiver missing"
grep -q 'gibson:stateful-ci' "$WF" && grep -q 'group: pr-review-evidence-serialized' "$WF" && grep -q 'cancel-in-progress: false' "$WF" && ok "runs serialized repo-wide, never cancelled (stateful-ci)" || bad "concurrency is not a single non-cancelling queue"
grep -q 'cancel-in-progress: true' "$WF" && bad "cancel-in-progress: true present" || ok "no cancel-in-progress: true"
grep -qE 'types: \[.*closed.*\]' "$WF" && ok "closed is a trigger (sibling recovers via the next sweep)" || bad "closed missing from pull_request_target types"
grep -q -- '--sweep' "$WF" && ok "workflow runs the sweep" || bad "workflow does not run --sweep"
pend=$(grep -n 'name: Stamp pending on every open PR head' "$WF" | cut -d: -f1); swp=$(grep -n 'name: Evaluate every open PR' "$WF" | cut -d: -f1); pub=$(grep -n 'name: Publish every head' "$WF" | cut -d: -f1)
[ -n "$pend" ] && [ -n "$swp" ] && [ "$pend" -lt "$swp" ] && ok "pending is stamped BEFORE the sweep" || bad "pending step not before sweep"
[ -n "$pub" ] && [ "$swp" -lt "$pub" ] && ok "publish step after sweep" || bad "publish step order"
sed -n "${pub},$((pub+2))p" "$WF" | grep -q 'if: always()' && ok "publish step itself runs on always()" || bad "publish step lacks always()"
for step in "$pend" "$swp"; do sed -n "${step},$((step+8))p" "$WF" | grep -q 'continue-on-error: true' || bad "step at $step not continue-on-error"; done
sed -n "${pend},${swp}p" "$WF" | grep -q '::notice::' && sed -n "${swp},${pub}p" "$WF" | grep -q '::notice::' && ok "both continue-on-error steps announce (3.5)" || bad "a continue-on-error step is silent"
n_uses=$(grep -cE '^[[:space:]]*(- )?uses:' "$WF"); [ "$n_uses" -ge 2 ] && ! grep -E '^[[:space:]]*(- )?uses:' "$WF" | grep -vqE '@[0-9a-f]{40} # v' && ok "all $n_uses actions SHA-pinned" || bad "unpinned action or none found"
grep -qE 'git (log|fetch|checkout).*(head|HEAD)' "$WF" && bad "workflow touches PR git objects" || ok "no git log / PR checkout in workflow"
grep -qE -- '--jq[[:space:]]+--arg' "$WF" && bad "gh api --jq given jq flags" || ok "no jq flags passed through gh api --jq"

extract() { awk -v s="$1" 'NR>=s && /run: \|/{f=1;next} f && /^      - (name:|uses:|if:)/{exit} f{sub(/^          /,""); print}' "$WF"; }
extract "$pend" > "$ROOT/pending.sh"; extract "$pub" > "$ROOT/publish.sh"
WD="$ROOT/wd"; mkdir -p "$WD"
# gh stub: list open PRs from $GH_LIST (or fail if GH_LIST_FAIL), answer pulls/N with $GH_FP
# (the publish-time freshness fingerprint), capture POSTs as "sha state" lines.
cat > "$ROOT/bin/gh" <<'GHSTUB'
#!/bin/sh
case "$*" in
  *"--method POST"*) sha=""; st=""; for a in "$@"; do case "$a" in repos/*/statuses/*) sha=${a##*/};; state=*) st=${a#state=};; esac; done; echo "$sha $st" >> "$GH_LOG" ;;
  *"pulls?state=open"*) [ "${GH_LIST_FAIL:-}" = "1" ] && exit 22; printf '%s\n' "$GH_LIST" ;;
  *"/pulls/"*) printf '%s' "${GH_FP:-unavailable}" ;;
  *) echo "stub: unexpected gh $*" >&2; exit 9 ;;
esac
GHSTUB
chmod +x "$ROOT/bin/gh"
FP='2026-09-04T12:00:00Z|h|b|3|0|2'
H2=cccccccccccccccccccccccccccccccccccccccc
envrun() { ( cd "$WD" && GH_LOG="$ROOT/gh.log" GITHUB_STEP_SUMMARY="$ROOT/summary" GH_REPO=x/y STATUS_CONTEXT=review-evidence TARGET_URL=http://t PATH="$ROOT/bin:$PATH" "$@" ); }
: > "$ROOT/gh.log"; : > "$ROOT/summary"
GH_LIST="$(printf '1 %s\n2 %s\n' "$HEAD" "$H2")" envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD bash "$ROOT/pending.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c ' pending$' "$ROOT/gh.log")" -eq 1 ] && grep -q "^$HEAD pending" "$ROOT/gh.log" && [ "$(wc -l < "$WD/heads.txt" | tr -d ' ')" -eq 2 ] && ok "pending step: stamps pending ONLY on the event head (2 heads listed, 1 stamped — churn cap)" || bad "pending step: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
: > "$ROOT/gh.log"; : > "$ROOT/summary"
GH_LIST_FAIL=1 envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD bash "$ROOT/pending.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q "^1 $HEAD" "$WD/heads.txt" && grep -q 'listing failed' "$ROOT/summary" && ok "pending step: listing fails → nonzero, event head recorded for fail-closed publish" || bad "pending step listing failure: rc=$rc heads=$(cat "$WD/heads.txt")"
# publish: results present
printf '1 %s\n2 %s\n' "$HEAD" "$H2" > "$WD/heads.txt"
printf '{"number":1,"headSha":"%s","state":"success","reason":"pass","description":"pass: devin","fingerprint":"%s"}\n{"number":2,"headSha":"%s","state":"failure","reason":"same-vendor-reviewer","description":"same-vendor-reviewer: grok"}\n' "$HEAD" "$FP" "$H2" > "$WD/results.jsonl"
: > "$ROOT/gh.log"; : > "$ROOT/summary"
GH_FP="$FP" envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q "^$HEAD success" "$ROOT/gh.log" && grep -q "^$H2 failure" "$ROOT/gh.log" && ok "publish: every sweep line published; job green when the EVENT's PR is not failing" || bad "publish normal: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
: > "$ROOT/gh.log"; GH_FP="$FP" envrun env EVENT_PR_NUMBER=2 EVENT_HEAD_SHA=$H2 CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q "^$H2 failure" "$ROOT/gh.log" && ok "publish: job red when the EVENT's PR failed closed" || bad "publish event-fail: rc=$rc"
: > "$ROOT/gh.log"; GH_FP="$FP" envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=true bash "$ROOT/publish.sh" >/dev/null 2>&1
[ "$(grep -c ' pending$' "$ROOT/gh.log")" -eq 2 ] && ok "publish: cancelled → every head pending (supersession is not a verdict)" || bad "publish cancelled: $(tr '\n' ' ' < "$ROOT/gh.log")"
# publish: sweep produced nothing
rm -f "$WD/results.jsonl"; : > "$ROOT/gh.log"; : > "$ROOT/summary"
envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ "$(grep -c ' failure$' "$ROOT/gh.log")" -eq 2 ] && ok "publish: sweep never ran → failure on EVERY stamped head, never a stale success" || bad "publish no-results: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
printf '{"number":null,"headSha":"","state":"failure","reason":"api-error","detail":"listing"}\n' > "$WD/results.jsonl"; : > "$ROOT/gh.log"; : > "$ROOT/summary"
envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ "$(grep -c ' failure$' "$ROOT/gh.log")" -eq 2 ] && ok "publish: sweep listing fault → failure on every stamped head" || bad "publish listing-fault: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
: > "$WD/heads.txt"; rm -f "$WD/results.jsonl"; : > "$ROOT/gh.log"; : > "$ROOT/summary"
envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'NOT PUBLISHED' "$ROOT/summary" && ok "publish: nothing known at all → nonzero + loud summary line" || bad "publish nothing-known was silent (rc=$rc)"
# Codex round 5: event head always joins the stamped set; unstamped-but-unverdicted heads fail closed; job has no if:.
H3=dddddddddddddddddddddddddddddddddddddddd
: > "$ROOT/gh.log"; : > "$ROOT/summary"
GH_LIST="$(printf '1 %s\n' "$HEAD")" envrun env EVENT_PR_NUMBER=3 EVENT_HEAD_SHA=$H3 bash "$ROOT/pending.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q "^3 $H3" "$WD/heads.txt" && grep -q "^$H3 pending" "$ROOT/gh.log" && ok "pending step: event head not in the listing is still stamped and recorded" || bad "event head not added: rc=$rc heads=$(tr '\n' ' ' < "$WD/heads.txt")"
printf '1 %s\n3 %s\n' "$HEAD" "$H3" > "$WD/heads.txt"; printf '{"number":1,"headSha":"%s","state":"success","reason":"pass","description":"pass: devin","fingerprint":"%s"}\n' "$HEAD" "$FP" > "$WD/results.jsonl"; : > "$ROOT/gh.log"; : > "$ROOT/summary"
GH_FP="$FP" envrun env EVENT_PR_NUMBER=3 EVENT_HEAD_SHA=$H3 CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q "^$H3 failure" "$ROOT/gh.log" && grep -q "^$HEAD success" "$ROOT/gh.log" && ok "publish: a stamped head with no sweep verdict is published failure (never left pending/stale)" || bad "unverdicted head: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
awk '/^jobs:/{f=1} f && /^    if:/{print}' "$WF" | grep -q . && bad "job-level if: present (a skipped run still replaces the queued one)" || ok "no job-level if: — every event runs the sweep"
# Codex round 6: trigger trust boundary, pending before any checkout, publish freshness re-check.
awk '/^on:/{f=1} /^permissions:/{f=0} f' "$WF" | grep -qE '^\s*pull_request_review' && bad "pull_request_review trigger present (runs the workflow file from the PR merge commit)" || ok "no pull_request-class trigger: workflow file always read from the default branch"
awk '/^on:/{f=1} /^permissions:/{f=0} f' "$WF" | grep -q 'schedule:' && ok "schedule sweep present (reviews are picked up without a review-event trigger)" || bad "no schedule trigger"
first_step=$(awk '/^    steps:/{f=1;next} f && /^      - /{print; exit}' "$WF"); printf '%s' "$first_step" | grep -q 'Stamp pending' && ok "pending stamp is the FIRST step (before checkout/setup-node)" || bad "first step is not the pending stamp: $first_step"
# publish freshness: gh stub answers pulls/N with $GH_FP
cat > "$ROOT/bin/gh" <<'GHSTUB'
#!/bin/sh
case "$*" in
  *"--method POST"*) sha=""; st=""; for a in "$@"; do case "$a" in repos/*/statuses/*) sha=${a##*/};; state=*) st=${a#state=};; esac; done; echo "$sha $st" >> "$GH_LOG" ;;
  *"pulls?state=open"*) printf '%s\n' "$GH_LIST" ;;
  *"/pulls/"*) printf '%s' "${GH_FP:-unavailable}" ;;
  *) echo "stub: unexpected gh $*" >&2; exit 9 ;;
esac
GHSTUB
chmod +x "$ROOT/bin/gh"
FP='2026-09-04T12:00:00Z|h|b|3|0|2'
printf '1 %s\n' "$HEAD" > "$WD/heads.txt"; printf '{"number":1,"headSha":"%s","state":"success","reason":"pass","description":"pass: devin","fingerprint":"%s"}\n' "$HEAD" "$FP" > "$WD/results.jsonl"
: > "$ROOT/gh.log"; GH_FP="$FP" envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q "^$HEAD success" "$ROOT/gh.log" && ok "publish: fingerprint unchanged → success written" || bad "publish fresh: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
: > "$ROOT/gh.log"; GH_FP='2026-09-04T12:05:00Z|h|b|4|0|2' envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
grep -q "^$HEAD pending" "$ROOT/gh.log" && ! grep -q "^$HEAD success" "$ROOT/gh.log" && ok "publish: state moved since evaluation → pending, never the stale success" || bad "publish stale: log=$(tr '\n' ' ' < "$ROOT/gh.log")"
: > "$ROOT/gh.log"; GH_FP='unavailable' envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1
grep -q "^$HEAD pending" "$ROOT/gh.log" && ok "publish: fingerprint re-read fails → pending (fail closed)" || bad "publish fp-unavailable: log=$(tr '\n' ' ' < "$ROOT/gh.log")"
printf '{"number":1,"headSha":"%s","state":"success","reason":"pass","description":"pass","fingerprint":""}\n' "$HEAD" > "$WD/results.jsonl"; : > "$ROOT/gh.log"; GH_FP="$FP" envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1
grep -q "^$HEAD pending" "$ROOT/gh.log" && ok "publish: success line without a fingerprint → pending" || bad "publish no-fp: log=$(tr '\n' ' ' < "$ROOT/gh.log")"
# Codex round 7: status-churn cap. No workflow_dispatch; hourly schedule; scheduled runs stamp no pending
# and write only on change; every status POST is checked and a failure makes the job red.
awk '/^on:/{f=1} /^permissions:/{f=0} f' "$WF" | grep -q 'workflow_dispatch' && bad "workflow_dispatch present (runs any branch's copy of this file with the status token)" || ok "no workflow_dispatch trigger"
awk '/^on:/{f=1} /^permissions:/{f=0} f' "$WF" | grep -qE 'cron: "[0-9]+ \* \* \* \*"' && ok "schedule is hourly, not every few minutes (1,000-status cap per SHA)" || bad "schedule cron is not hourly: $(grep -n cron "$WF")"
# gh stub v3: also answers commits/SHA/status with $GH_CUR ("state|desc") and fails POSTs when GH_POST_FAIL=1
cat > "$ROOT/bin/gh" <<'GHSTUB'
#!/bin/sh
case "$*" in
  *"--method POST"*) [ "${GH_POST_FAIL:-}" = "1" ] && { echo "HTTP 422: too many statuses" >&2; exit 22; }; sha=""; st=""; for a in "$@"; do case "$a" in repos/*/statuses/*) sha=${a##*/};; state=*) st=${a#state=};; esac; done; echo "$sha $st" >> "$GH_LOG" ;;
  *"pulls?state=open"*) [ "${GH_LIST_FAIL:-}" = "1" ] && exit 22; printf '%s\n' "$GH_LIST" ;;
  *"/commits/"*"/status"*) printf '%s\n' "${GH_CUR:-}" ;;
  *"/pulls/"*) printf '%s' "${GH_FP:-unavailable}" ;;
  *) echo "stub: unexpected gh $*" >&2; exit 9 ;;
esac
GHSTUB
chmod +x "$ROOT/bin/gh"
: > "$ROOT/gh.log"; : > "$ROOT/summary"
GH_LIST="$(printf '1 %s\n2 %s\n' "$HEAD" "$H2")" envrun env IS_SCHEDULE=true EVENT_PR_NUMBER='' EVENT_HEAD_SHA='' bash "$ROOT/pending.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$ROOT/gh.log" ] && [ "$(wc -l < "$WD/heads.txt" | tr -d ' ')" -eq 2 ] && ok "schedule: pending step lists heads but stamps NOTHING" || bad "schedule pending: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
printf '1 %s\n' "$HEAD" > "$WD/heads.txt"; printf '{"number":1,"headSha":"%s","state":"success","reason":"pass","description":"pass: devin","fingerprint":"%s"}\n' "$HEAD" "$FP" > "$WD/results.jsonl"
: > "$ROOT/gh.log"; GH_FP="$FP" GH_CUR="success|pass: devin" envrun env IS_SCHEDULE=true EVENT_PR_NUMBER='' CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$ROOT/gh.log" ] && ok "schedule: unchanged verdict → NO status write (churn cap)" || bad "schedule unchanged wrote: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
: > "$ROOT/gh.log"; GH_FP="$FP" GH_CUR="pending|UNREVIEWED: no receipt at head" envrun env IS_SCHEDULE=true EVENT_PR_NUMBER='' CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q "^$HEAD success" "$ROOT/gh.log" && ok "schedule: changed verdict → written" || bad "schedule changed not written: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
: > "$ROOT/gh.log"; GH_FP="$FP" GH_CUR="success|pass: devin" envrun env IS_SCHEDULE=false EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q "^$HEAD success" "$ROOT/gh.log" && ok "event run: always writes (pending was stamped first)" || bad "event run skipped a write: rc=$rc"
: > "$ROOT/gh.log"; : > "$ROOT/summary"; GH_FP="$FP" GH_POST_FAIL=1 envrun env IS_SCHEDULE=false EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'status write FAILED' "$ROOT/summary" && ok "publish: a failed status POST is an error and the job is red (never 'published')" || bad "failed POST ignored: rc=$rc summary=$(tr '\n' ' ' < "$ROOT/summary")"
: > "$ROOT/gh.log"; : > "$ROOT/summary"; GH_LIST="$(printf '1 %s\n' "$HEAD")" GH_POST_FAIL=1 envrun env IS_SCHEDULE=false EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD bash "$ROOT/pending.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'pending stamp FAILED' "$ROOT/summary" && ok "pending step: a failed stamp is an error, not a silent skip" || bad "failed pending stamp ignored: rc=$rc"
# Codex round 8: event runs write non-event heads only on change; a failed pending step makes the job red.
printf '1 %s\n2 %s\n' "$HEAD" "$H2" > "$WD/heads.txt"
printf '{"number":1,"headSha":"%s","state":"success","reason":"pass","description":"pass: devin","fingerprint":"%s"}\n{"number":2,"headSha":"%s","state":"success","reason":"pass","description":"pass: devin","fingerprint":"%s"}\n' "$HEAD" "$FP" "$H2" "$FP" > "$WD/results.jsonl"
: > "$ROOT/gh.log"; GH_FP="$FP" GH_CUR="success|pass: devin" envrun env IS_SCHEDULE=false EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q "^$HEAD success" "$ROOT/gh.log" && ! grep -q "^$H2 " "$ROOT/gh.log" && ok "event run: the event head is written; an unchanged NON-event head is not (no amplification)" || bad "event-run amplification: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
: > "$ROOT/gh.log"; : > "$ROOT/summary"; GH_FP="$FP" GH_CUR="" envrun env IS_SCHEDULE=false EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD HEADS_OUTCOME=failure CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'pending stamp step FAILED' "$ROOT/summary" && ok "publish: a failed pending step (continue-on-error) still makes the job red" || bad "HEADS_OUTCOME failure ignored: rc=$rc"
printf 'garbage not json\n' > "$WD/results.jsonl"; printf '1 %s\n' "$HEAD" > "$WD/heads.txt"; : > "$ROOT/gh.log"
envrun env EVENT_PR_NUMBER=1 EVENT_HEAD_SHA=$HEAD CANCELLED=false bash "$ROOT/publish.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ "$(grep -c ' failure$' "$ROOT/gh.log")" -ge 1 ] && ok "publish: unparseable sweep output → failure, never success" || bad "publish garbage: rc=$rc log=$(tr '\n' ' ' < "$ROOT/gh.log")"
if command -v actionlint >/dev/null 2>&1; then
  out=$(actionlint "$WF" 2>&1); [ $? -eq 0 ] && ok "actionlint clean" || bad "actionlint: $out"
else
  echo "  skip — actionlint not installed (ci-conventions covers it in CI)"
fi

echo
echo "pr-review-evidence.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
