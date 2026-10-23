#!/usr/bin/env bash
# Tests for the 2026-10-15 pre-push layer: install-lane-hooks.sh, hooks/pre-push, pre-push-gate.sh,
# prepush-review.sh (dry). No network, no gh, no codex, no claude.
# Run: bash ~/.claude/fleet/test/prepush.test.sh
set -uo pipefail
FLEET="$HOME/.claude/fleet"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
has()  { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "contains: $3" "$2";; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "must NOT contain: $3" "$2";; *) ok "$1";; esac; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
G() { git -c user.name=t -c user.email=t@t "$@"; }
# A fake lane-bot identity so the vendor check has something to match; real identities untouched.
mkdir -p "$TMP/ids"; printf 'BOT_NAME="test-bot[bot]"\nBOT_EMAIL="bot@test.invalid"\n' > "$TMP/ids/test.env"
export FLEET_IDENTITIES_DIR="$TMP/ids"
B() { git -c user.name="test-bot[bot]" -c user.email=bot@test.invalid "$@"; }   # commits as the bot

echo "== fixture: bare origin + lane clone =="
G init -q --bare "$TMP/origin.git"
G init -q -b main "$TMP/seed"; ( cd "$TMP/seed" && echo a > a && echo '{"scripts":{"lint":"true","test":"true"}}' > package.json && G add -A && G commit -qm seed && G remote add origin "$TMP/origin.git" && G push -q origin main )
G clone -q "$TMP/origin.git" "$TMP/main"
( cd "$TMP/main" && G worktree add -q "$TMP/lane" -b lane/1 && G worktree add -q "$TMP/lane2" -b lane/2 )
cd "$TMP/lane" || exit 1

echo "== install-lane-hooks.sh =="
"$FLEET/install-lane-hooks.sh" "$TMP/main" >/dev/null 2>&1; is "refuses the main checkout" 65 "$?"
out="$("$FLEET/install-lane-hooks.sh" "$TMP/lane" 2>&1)"; has "installs into a lane" "$out" "hooksPath="
is "lane has worktree-scoped hooksPath" "$FLEET/hooks" "$(git config --worktree core.hooksPath)"
is "main checkout untouched" "" "$(cd "$TMP/main" && git config --worktree core.hooksPath 2>/dev/null || true)"
is "sibling lane untouched" "" "$(cd "$TMP/lane2" && git config --worktree core.hooksPath 2>/dev/null || true)"
FLEET_HOOKS_DIR="$TMP/nohooks" "$FLEET/install-lane-hooks.sh" "$TMP/lane2" >/dev/null 2>&1; is "missing hook dir -> exit 66" 66 "$?"
chmod 500 "$TMP/main/.git/worktrees/lane2"; "$FLEET/install-lane-hooks.sh" "$TMP/lane2" >/dev/null 2>&1; rc=$?; chmod 700 "$TMP/main/.git/worktrees/lane2"
is "unwritable worktree config -> exit 66" 66 "$rc"

echo "== hooks/pre-push refuses protected targets =="
echo b > b && G add b && B commit -qm b
out="$(G push origin HEAD:main 2>&1 || true)"; has "main refused" "$out" "REFUSED"
is "main not pushed" "" "$(git ls-remote origin refs/heads/main | grep -c "$(git rev-parse HEAD)" | sed 's/0//')"
out="$(G push origin HEAD:release 2>&1 || true)"; has "release refused" "$out" "REFUSED"

echo "== hooks/pre-push runs the gate (generic package.json scripts) =="
echo '{"scripts":{"lint":"true","test":"false"}}' > package.json
out="$(G push origin HEAD:lane/1 2>&1 || true)"; has "red gate refuses push" "$out" "RED"
is "lane not pushed on red" "" "$(git ls-remote origin refs/heads/lane/1)"
G checkout -q -- package.json
out="$(G push origin HEAD:lane/1 2>&1 || true)"; has "green gate allows push" "$out" "green"
has "lane pushed on green" "$(git ls-remote origin refs/heads/lane/1)" "refs/heads/lane/1"
echo "== hooks/pre-push enforces the vendor marker =="
echo v > v && G add v && G commit -qm "unmarked"
out="$(G push origin HEAD:lane/1 2>&1 || true)"; has "unmarked owner-style commit refused" "$out" "no vendor marker"
G commit -q --amend -m "body-line-only

Agent-Vendor: grok
this paragraph continues, so the line above is body text, not a trailer"
out="$(G push origin HEAD:lane/1 2>&1 || true)"; has "Agent-Vendor as a body line is not a trailer" "$out" "no vendor marker"
G commit -q --amend -m "marked

Agent-Vendor: grok"
# base check runs on a commit that is AHEAD of the remote (git itself rejects a behind tip before any hook runs)
mainref="$(git rev-parse refs/remotes/origin/main)"; git update-ref -d refs/remotes/origin/main
out="$(G push origin HEAD:lane/1 2>&1 || true)"; has "unresolvable origin/main refuses" "$out" "cannot resolve"
git update-ref refs/remotes/origin/main "$mainref"
out="$(G push origin HEAD:lane/1 2>&1 || true)"; has "Agent-Vendor trailer accepted" "$out" "green"

echo "== hooks/pre-push refuses history rewrites =="
B commit -q --amend -m "b-rewritten"
out="$(G push --force origin HEAD:lane/1 2>&1 || true)"; has "force push refused" "$out" "rewritten"
G reset -q --hard "$(git ls-remote origin refs/heads/lane/1 | cut -f1)"

echo "== pre-push-gate.sh chatterbuilt branch fails closed =="
G remote set-url origin "$TMP/chatterbuilt-origin.git"; ln -s "$TMP/origin.git" "$TMP/chatterbuilt-origin.git"
mkdir -p apps/x && echo '{"scripts":{"build":"true"}}' > apps/x/package.json && G add apps && B commit -qm pkg
mainref="$(git rev-parse refs/remotes/origin/main)"; git update-ref -d refs/remotes/origin/main
G remote set-url origin "$TMP/nowhere-chatterbuilt.git"   # fetch fails too, so the ref cannot come back
"$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "unresolvable base -> exit 1" 1 "$?"
G remote set-url origin "$TMP/chatterbuilt-origin.git"; git update-ref refs/remotes/origin/main "$mainref"
out="$("$FLEET/pre-push-gate.sh" "$TMP/lane" 2>&1)"; rc=$?; is "touched pkg without checks -> exit 1" 1 "$rc"; has "names the package" "$out" "apps/x"
FLEET_GATE_FULL=1 "$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "FULL mode: build alone is not a check -> exit 1" 1 "$?"
echo '{"scripts":{"lint":"true"}}' > apps/x/package.json && G add apps && B commit -qm pkg2
"$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "touched pkg with lint -> exit 0" 0 "$?"
mainref="$(git rev-parse refs/remotes/origin/main)"; git update-ref refs/remotes/origin/main "$(git commit-tree "$(git mktree </dev/null)" -m orphan)"
G remote set-url origin "$TMP/nowhere-chatterbuilt.git"   # fetch must fail or it would restore the real ref
out="$("$FLEET/pre-push-gate.sh" "$TMP/lane" 2>&1)"; rc=$?; is "unrelated origin/main -> exit 1" 1 "$rc"; has "says no shared history" "$out" "share no history"
G remote set-url origin "$TMP/chatterbuilt-origin.git"; git update-ref refs/remotes/origin/main "$mainref"
G reset -q --hard HEAD~2; rm -rf apps; G remote set-url origin "$TMP/origin.git"

echo "== pre-push-gate.sh fails closed =="
G rm -q package.json
"$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "no manifest -> exit 1" 1 "$?"
echo '{"scripts":{"build":"true"}}' > package.json
"$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "no gate scripts -> exit 1" 1 "$?"
echo '{"scripts":{"lint":"true","test":"exit 3"}}' > package.json
out="$("$FLEET/pre-push-gate.sh" "$TMP/lane" 2>&1)"; rc=$?; is "failing test script -> exit 1" 1 "$rc"; has "names the red step" "$out" "test: RED"
G reset -q --hard HEAD
"$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "green scripts -> exit 0" 0 "$?"

echo "== pre-push-gate.sh exports a locale when the caller has none (2026-10-23 postgres FATAL) =="
# The gated command sees whatever locale the gate exports. Empty LANG/LC_ALL (the Cowork Bash tool
# shell) made postgres refuse to start in every conference-os *-postgres suite.
echo '{"scripts":{"lint":"true","test":"[ -n \"$LC_ALL\" ] && [ -n \"$LANG\" ]"}}' > package.json
env -u LC_ALL -u LANG -u LC_CTYPE "$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "unset locale -> gate command sees one (exit 0)" 0 "$?"
env LC_ALL= LANG= "$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "EMPTY locale (Cowork shell) -> gate command sees one (exit 0)" 0 "$?"
echo '{"scripts":{"lint":"true","test":"[ \"$LC_ALL\" = C.UTF-8 ] && [ \"$LANG\" = C.UTF-8 ]"}}' > package.json
env LC_ALL=C.UTF-8 LANG=C.UTF-8 "$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "caller's own locale is kept, not overwritten" 0 "$?"
echo '{"scripts":{"lint":"true","test":"[ \"$LC_ALL\" = en_US.UTF-8 ]"}}' > package.json
env -u LC_ALL -u LANG "$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "default is en_US.UTF-8" 0 "$?"
G checkout -q -- package.json

echo "== pre-push-gate.sh: .fleet-gate is repo-owned =="
printf 'true\n' > .fleet-gate
out="$("$FLEET/pre-push-gate.sh" "$TMP/lane" 2>&1)"; rc=$?; is "lane-only .fleet-gate -> exit 1" 1 "$rc"; has "says not on main" "$out" "not on origin/main"
rm .fleet-gate
( cd "$TMP/main" && printf '# repo gate\ntrue\n' > .fleet-gate && G add .fleet-gate && G commit -qm gate && G push -q origin main )
G fetch -q origin && G merge -q origin/main
out="$("$FLEET/pre-push-gate.sh" "$TMP/lane" 2>&1)"; rc=$?; is "identical .fleet-gate -> exit 0" 0 "$rc"; has "ran the gate file" "$out" ".fleet-gate: green"
printf 'false\n' > .fleet-gate
out="$("$FLEET/pre-push-gate.sh" "$TMP/lane" 2>&1)"; rc=$?; is "edited .fleet-gate -> exit 1" 1 "$rc"; has "says it differs" "$out" "differs from origin/main"
G checkout -q -- .fleet-gate; rm .fleet-gate
"$FLEET/pre-push-gate.sh" "$TMP/lane" >/dev/null 2>&1; is "deleted .fleet-gate -> exit 1" 1 "$?"
G checkout -q -- .fleet-gate

echo "== prepush-review.sh (dry) =="
export PREPUSH_REVIEW_DRY=1 PREPUSH_REVIEW_OUTDIR="$TMP/reviews"
mainref="$(git rev-parse refs/remotes/origin/main)"; git update-ref -d refs/remotes/origin/main; G remote set-url origin "$TMP/nowhere.git"
"$FLEET/prepush-review.sh" "$TMP/lane" grok >/dev/null 2>&1; is "unresolvable origin/main -> 2 (not a pass)" 2 "$?"
G remote set-url origin "$TMP/origin.git"; git update-ref refs/remotes/origin/main "$mainref"
"$FLEET/prepush-review.sh" "$TMP/lane" grok HEAD >/dev/null 2>&1; is "a base argument is refused (64)" 64 "$?"
PREPUSH_REVIEWER=Codex "$FLEET/prepush-review.sh" "$TMP/lane" codex >/dev/null 2>&1; is "case-insensitive same-vendor refused" 64 "$?"
PREPUSH_REVIEWER=codex "$FLEET/prepush-review.sh" "$TMP/lane" 'codex ' >/dev/null 2>&1; is "whitespace in vendor cannot evade (64)" 64 "$?"
"$FLEET/prepush-review.sh" "$TMP/lane" gemini >/dev/null 2>&1; is "unknown vendor refused (64)" 64 "$?"
out="$("$FLEET/prepush-review.sh" "$TMP/lane" grok 2>&1)"; has "grok coder -> codex reviewer" "$out" "reviewer=codex"
out="$("$FLEET/prepush-review.sh" "$TMP/lane" codex 2>&1)"; has "codex coder -> claude reviewer" "$out" "reviewer=claude"
PREPUSH_REVIEWER=claude "$FLEET/prepush-review.sh" "$TMP/lane" claude >/dev/null 2>&1; is "same-vendor reviewer refused" 64 "$?"
unset PREPUSH_REVIEW_DRY
# Codex path: the log echoes the prompt ("VERDICT: PASS or VERDICT: REQUEST_CHANGES"); only the printed verdict counts.
mkfc() { printf '#!/bin/sh\nprintf "%%s\\n" "echoed prompt: VERDICT: PASS or VERDICT: REQUEST_CHANGES" > "$3"\n%s\nexit %s\n' "$1" "$2" > "$TMP/fake-codex"; chmod +x "$TMP/fake-codex"; }
mkfc 'echo "VERDICT: REQUEST_CHANGES"' 0; PREPUSH_CODEX_REVIEW="$TMP/fake-codex" "$FLEET/prepush-review.sh" "$TMP/lane" grok >/dev/null 2>&1; is "codex REQUEST_CHANGES (log echoes PASS) -> 1" 1 "$?"
mkfc 'echo "VERDICT: PASS"' 0; PREPUSH_CODEX_REVIEW="$TMP/fake-codex" "$FLEET/prepush-review.sh" "$TMP/lane" grok >/dev/null 2>&1; is "codex PASS -> 0" 0 "$?"
mkfc 'true' 0; PREPUSH_CODEX_REVIEW="$TMP/fake-codex" "$FLEET/prepush-review.sh" "$TMP/lane" grok >/dev/null 2>&1; is "codex prints no verdict -> 2" 2 "$?"
mkfc 'echo "VERDICT: PASS"' 3; PREPUSH_CODEX_REVIEW="$TMP/fake-codex" "$FLEET/prepush-review.sh" "$TMP/lane" grok >/dev/null 2>&1; is "codex PASS text but rc 3 -> 2" 2 "$?"
printf '#!/bin/sh\necho "VERDICT: PASS"; exit 1\n' > "$TMP/fake-claude"; chmod +x "$TMP/fake-claude"
PREPUSH_CLAUDE_BIN="$TMP/fake-claude" "$FLEET/prepush-review.sh" "$TMP/lane" codex >/dev/null 2>&1; is "claude PASS text + nonzero exit -> 2 (not a pass)" 2 "$?"
printf '#!/bin/sh\necho "VERDICT: PASS"; exit 0\n' > "$TMP/fake-claude"
PREPUSH_CLAUDE_BIN="$TMP/fake-claude" "$FLEET/prepush-review.sh" "$TMP/lane" codex >/dev/null 2>&1; is "claude PASS + exit 0 -> 0" 0 "$?"
chmod 500 "$TMP/reviews"; PREPUSH_CLAUDE_BIN="$TMP/fake-claude" "$FLEET/prepush-review.sh" "$TMP/lane" codex >/dev/null 2>&1; rc=$?; chmod 700 "$TMP/reviews"
is "unwritable review dir -> 2 (not a pass)" 2 "$rc"
export PREPUSH_REVIEW_DRY=1
p="$(printf '%s' "$out" | sed -n 's/.*content=//p')"; has "diff captured" "$(cat "$p")" "diff --git a/b b/b"
( cd "$TMP/lane2" && out="$("$FLEET/prepush-review.sh" "$TMP/lane2" grok 2>&1)"; has "empty diff -> nothing to review" "$out" "nothing to review" )
unset PREPUSH_REVIEW_DRY PREPUSH_REVIEW_OUTDIR   # artifacts lived under $TMP; nothing in the shared store was touched

printf '\n%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
