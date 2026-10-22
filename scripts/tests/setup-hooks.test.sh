#!/usr/bin/env bash
# setup-hooks.test.sh — sensors for .githooks + scripts/setup-hooks.sh (issue #204)
#
# WHY
#   A missing Signed-off-by must be added or refused at commit time, not first
#   noticed in CI. These cases drive the real hooks and setup-hooks.sh against
#   throwaway repos. No network, no gh.
#
# USAGE
#   scripts/tests/setup-hooks.test.sh
set -uo pipefail

# Hermetic git identity (#101). Overwrite, do not inherit: gibson-self-gate
# exports GIT_COMMITTER_NAME=gibson-ci, and ${GIT_COMMITTER_NAME:-gibson-sensor}
# would keep that. The hook correctly signs as the env committer, so the
# "names the committer" assertion below would look for the wrong person.
export GIT_AUTHOR_NAME=gibson-sensor
export GIT_AUTHOR_EMAIL=sensor@gibson.invalid
export GIT_COMMITTER_NAME=gibson-sensor
export GIT_COMMITTER_EMAIL=sensor@gibson.invalid

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GIBSON=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
SETUP="$GIBSON/scripts/setup-hooks.sh"
PREPARE="$GIBSON/.githooks/prepare-commit-msg"
COMMIT_MSG="$GIBSON/.githooks/commit-msg"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v git >/dev/null || { echo "setup-hooks.test.sh: git is required"; exit 1; }
[[ -x "$SETUP" && -x "$PREPARE" && -x "$COMMIT_MSG" ]] || {
  echo "setup-hooks.test.sh: hooks or setup-hooks.sh missing/not executable"
  exit 1
}

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-setup-hooks.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

GIT="git -c user.email=sensor@gibson.invalid -c user.name=gibson-sensor -c commit.gpgsign=false"

echo "setup-hooks.sh --help is Ask-Contract shaped"
help_out=$("$SETUP" --help 2>"$ROOT/help.err")
help_rc=$?
if [[ "$help_rc" -eq 0 ]]; then ok "setup-hooks.sh --help exits 0"
else bad "setup-hooks.sh --help exited $help_rc"; fi
if echo "$help_out" | grep 'WHAT IT DOES' >/dev/null && echo "$help_out" | grep 'RISKS' >/dev/null; then
  ok "setup-hooks.sh --help names WHAT IT DOES and RISKS"
else
  bad "setup-hooks.sh --help missing Ask-Contract fields"
fi
if [[ ! -s "$ROOT/help.err" ]]; then ok "setup-hooks.sh --help is quiet on stderr"
else bad "setup-hooks.sh --help wrote stderr"; fi

echo "setup-hooks.sh unknown flag exits 2"
if "$SETUP" --definitely-not-a-flag >/dev/null 2>"$ROOT/unk.err"; then
  bad "unknown flag must not succeed"
else
  unk_rc=$?
  if [[ "$unk_rc" -eq 2 ]]; then ok "unknown flag exits 2"
  else bad "unknown flag exited $unk_rc (want 2)"; fi
fi

echo "setup-hooks.sh no-ops outside a git work tree"
mkdir -p "$ROOT/not-a-repo"
if (cd "$ROOT/not-a-repo" && "$SETUP") >"$ROOT/skip.out" 2>"$ROOT/skip.err"; then
  ok "outside a work tree exits 0"
else
  bad "outside a work tree must exit 0 (got $?)"
fi
if grep -q 'not inside a git work tree' "$ROOT/skip.err"; then
  ok "outside a work tree names the skip"
else
  bad "outside a work tree was silent: $(cat "$ROOT/skip.err")"
fi

echo "setup-hooks.sh sets core.hooksPath and is safe to re-run"
REPO="$ROOT/repo"
mkdir -p "$REPO"
$GIT init -q "$REPO"
# Persist the hermetic identity in the throwaway repo too — `git init -c`
# does not write user.name/email, and the hook falls back to git var / config.
git -C "$REPO" config user.name gibson-sensor
git -C "$REPO" config user.email sensor@gibson.invalid
# Copy hooks so the temp repo has a .githooks dir (setup-hooks looks at toplevel).
mkdir -p "$REPO/.githooks"
cp "$PREPARE" "$COMMIT_MSG" "$REPO/.githooks/"
chmod 644 "$REPO/.githooks/prepare-commit-msg" "$REPO/.githooks/commit-msg"
if (cd "$REPO" && "$SETUP") >"$ROOT/setup.out" 2>"$ROOT/setup.err"; then
  ok "setup-hooks.sh succeeds inside a work tree"
else
  bad "setup-hooks.sh failed inside a work tree: $(cat "$ROOT/setup.err")"
fi
hooks_path=$(git -C "$REPO" config --get core.hooksPath || true)
if [[ "$hooks_path" == ".githooks" ]]; then
  ok "core.hooksPath is .githooks"
else
  bad "core.hooksPath was '${hooks_path:-<unset>}'"
fi
if [[ -x "$REPO/.githooks/prepare-commit-msg" && -x "$REPO/.githooks/commit-msg" ]]; then
  ok "setup-hooks.sh restored the executable bit on hooks"
else
  bad "hooks are not executable after setup-hooks.sh"
fi
if (cd "$REPO" && "$SETUP") >/dev/null 2>&1; then
  ok "setup-hooks.sh is safe to re-run"
else
  bad "second setup-hooks.sh run failed"
fi

echo "prepare-commit-msg adds a missing Signed-off-by trailer"
# Drive the hook as git would: cwd is the repo so `git var` / interpret-trailers work.
msg="$ROOT/msg-add"
printf 'subject\n\nbody\n' > "$msg"
if (cd "$REPO" && "$PREPARE" "$msg"); then
  ok "prepare-commit-msg exits 0 when adding a trailer"
else
  bad "prepare-commit-msg failed while adding a trailer"
fi
if grep -qiE '^Signed-off-by:[[:space:]]+' "$msg"; then
  ok "prepare-commit-msg appended Signed-off-by"
else
  bad "prepare-commit-msg did not add a trailer: $(cat "$msg")"
fi
if grep -q 'gibson-sensor' "$msg" && grep -q 'sensor@gibson.invalid' "$msg"; then
  ok "added trailer uses the committer identity"
else
  bad "added trailer did not name the committer: $(cat "$msg")"
fi

echo "prepare-commit-msg leaves an already-present trailer alone"
msg="$ROOT/msg-keep"
printf 'subject\n\nSigned-off-by: Existing Author <exist@example.test>\n' > "$msg"
before=$(cat "$msg")
if (cd "$REPO" && "$PREPARE" "$msg"); then
  ok "prepare-commit-msg exits 0 when a trailer is already present"
else
  bad "prepare-commit-msg failed on an already-signed message"
fi
after=$(cat "$msg")
if [[ "$before" == "$after" ]]; then
  ok "already-present trailer is byte-identical"
else
  bad "already-present trailer was rewritten: $after"
fi
if grep -c -iE '^Signed-off-by:[[:space:]]+' "$msg" | grep -x 1 >/dev/null; then
  ok "already-present trailer was not duplicated"
else
  bad "trailer count changed: $(cat "$msg")"
fi

echo "commit-msg rejects a still-missing trailer"
msg="$ROOT/msg-reject"
printf 'subject\n\nno trailer here\n' > "$msg"
set +e
(cd "$REPO" && "$COMMIT_MSG" "$msg") >"$ROOT/reject.out" 2>"$ROOT/reject.err"
rej_rc=$?
set -e
if [[ "$rej_rc" -ne 0 ]]; then
  ok "commit-msg exits nonzero without Signed-off-by"
else
  bad "commit-msg accepted a message with no trailer"
fi
if grep -q 'Signed-off-by' "$ROOT/reject.err" &&
   grep -q 'git commit -s' "$ROOT/reject.err" &&
   grep -q 'setup-hooks.sh' "$ROOT/reject.err"; then
  ok "commit-msg tells the operator to run git commit -s or setup-hooks.sh"
else
  bad "commit-msg refusal was unclear: $(cat "$ROOT/reject.err")"
fi

echo "commit-msg accepts a message that already has the trailer"
msg="$ROOT/msg-ok"
printf 'subject\n\nSigned-off-by: Existing Author <exist@example.test>\n' > "$msg"
if (cd "$REPO" && "$COMMIT_MSG" "$msg"); then
  ok "commit-msg accepts a present trailer"
else
  bad "commit-msg rejected a signed message"
fi

echo "case-insensitive Signed-off-by is treated as present"
msg="$ROOT/msg-case"
printf 'subject\n\nsigned-off-by: Case Fold <case@example.test>\n' > "$msg"
if (cd "$REPO" && "$PREPARE" "$msg") && [[ "$(cat "$msg")" == "$(printf 'subject\n\nsigned-off-by: Case Fold <case@example.test>\n')" ]]; then
  ok "prepare-commit-msg leaves a case-folded trailer alone"
else
  bad "prepare-commit-msg rewrote a case-folded trailer: $(cat "$msg")"
fi
if (cd "$REPO" && "$COMMIT_MSG" "$msg"); then
  ok "commit-msg accepts a case-folded trailer"
else
  bad "commit-msg rejected a case-folded trailer"
fi

# ---------------------------------------------------------------------------
# Agent-Vendor on a declared lane (the-gibson closures of 2026-10-21)
# ---------------------------------------------------------------------------
# The hermetic identity above is sensor@gibson.invalid on purpose: `.invalid`
# is exactly what commit-msg refuses on a declared lane (no-login, #503/#504).
# Lane cases that must COMMIT therefore use a resolvable-looking address.
LANE_EMAIL=lane@gibson.test
GIT_LANE="git -c user.email=$LANE_EMAIL -c user.name=gibson-sensor -c commit.gpgsign=false"
lane_env() { GIT_AUTHOR_EMAIL=$LANE_EMAIL GIT_COMMITTER_EMAIL=$LANE_EMAIL "$@"; }

echo "the four Agent-Vendor lists agree with pr-review-evidence.mjs"
mjs_list=$(grep -o 'AUTHOR_COMMIT_VENDORS = new Set(\[[^]]*\])' "$GIBSON/scripts/pr-review-evidence.mjs" \
  | tr -d '"' | sed 's/.*\[//; s/\].*//' | tr ',' '\n' | tr -d ' ' | sort | tr '\n' ' ')
list_of() { grep -m1 '^AGENT_VENDORS=' "$1" | sed 's/^AGENT_VENDORS="//; s/"$//' | tr ' ' '\n' | sort | tr '\n' ' '; }
claim_list=$(grep -m1 -E '^[[:space:]]+claude\|codex\|grok\|devin\) ;;' "$GIBSON/scripts/claim.sh" \
  | sed 's/^[[:space:]]*//; s/) ;;.*//' | tr '|' '\n' | sort | tr '\n' ' ')
if [[ -n "$mjs_list" ]]; then ok "pr-review-evidence.mjs still exports AUTHOR_COMMIT_VENDORS ($mjs_list)"
else bad "could not read AUTHOR_COMMIT_VENDORS from pr-review-evidence.mjs"; fi
for f in "$PREPARE" "$COMMIT_MSG" "$SETUP" "$GIBSON/scripts/lib/agent-vendor.sh"; do
  if [[ "$(list_of "$f")" == "$mjs_list" ]]; then ok "$(basename "$f") vendor list matches the evaluator"
  else bad "$(basename "$f") vendor list '$(list_of "$f")' != evaluator '$mjs_list'"; fi
done
if [[ "$claim_list" == "$mjs_list" ]]; then ok "claim.sh vendor list matches the evaluator"
else bad "claim.sh vendor list '$claim_list' != evaluator '$mjs_list'"; fi

echo "no declared vendor: hooks leave an ordinary checkout alone"
msg="$ROOT/msg-nolane"
printf 'subject\n\nbody\n' > "$msg"
if (cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$PREPARE" "$msg") && ! grep -qi '^Agent-Vendor:' "$msg"; then
  ok "prepare-commit-msg adds no Agent-Vendor when nothing declares a vendor"
else
  bad "prepare-commit-msg touched an undeclared checkout: $(cat "$msg")"
fi
if (cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$msg"); then
  ok "commit-msg does not require Agent-Vendor when nothing declares a vendor"
else
  bad "commit-msg required Agent-Vendor on an undeclared checkout"
fi
printf 'subject\n\nAgent-Vendor: bogus\nSigned-off-by: A <a@example.test>\n' > "$ROOT/msg-bogus"
if (cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$ROOT/msg-bogus") 2>"$ROOT/bogus.err"; then
  bad "commit-msg accepted Agent-Vendor: bogus"
else
  if grep -q "unknown vendor 'bogus'" "$ROOT/bogus.err"; then ok "commit-msg refuses an unknown vendor even on an undeclared checkout"
  else bad "commit-msg refusal of a bogus vendor was unclear: $(cat "$ROOT/bogus.err")"; fi
fi

printf 'subject\n\nAgent-Vendor: claude extra\nSigned-off-by: A <a@example.test>\n' > "$ROOT/msg-malformed"
if (cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$ROOT/msg-malformed") 2>"$ROOT/malformed.err"; then
  bad "commit-msg accepted 'Agent-Vendor: claude extra' on an undeclared checkout"
else
  if grep -q 'malformed Agent-Vendor line' "$ROOT/malformed.err"; then ok "a malformed Agent-Vendor line is refused even on an undeclared checkout (Codex #523 finding 1)"
  else bad "malformed-line refusal unclear: $(cat "$ROOT/malformed.err")"; fi
fi
printf 'subject\n\nAgent-Vendor:\013claude\nSigned-off-by: A <a@example.test>\n' > "$ROOT/msg-vtab"
if (cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$ROOT/msg-vtab") 2>/dev/null; then
  bad "commit-msg accepted 'Agent-Vendor:<VT>claude', which the evaluator's [ \\t] matcher would not resolve"
else
  ok "a vertical-tab separator is refused: only space/tab count, as in pr-review-evidence.mjs (Codex round 2)"
fi
printf 'subject\n\nAgent-Vendor:\nSigned-off-by: A <a@example.test>\n' > "$ROOT/msg-empty"
if (cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$ROOT/msg-empty") 2>/dev/null; then
  bad "commit-msg accepted an empty Agent-Vendor line"
else
  ok "an empty Agent-Vendor line is refused"
fi

echo "setup-hooks.sh --vendor declares the worktree and validates the name"
if (cd "$REPO" && "$SETUP" --vendor bogus) >/dev/null 2>"$ROOT/vbogus.err"; then
  bad "--vendor bogus must not succeed"
else
  vb_rc=$?
  if [[ "$vb_rc" -eq 2 ]] && grep -q 'unknown agent vendor' "$ROOT/vbogus.err"; then ok "--vendor bogus exits 2 and names the valid set"
  else bad "--vendor bogus exited $vb_rc: $(cat "$ROOT/vbogus.err")"; fi
fi
set +e
(cd "$REPO" && "$SETUP" --vendor) >/dev/null 2>"$ROOT/vnone.err"
vnone_rc=$?
set -e
if [[ "$vnone_rc" -eq 2 ]]; then ok "--vendor without a value exits 2"; else bad "--vendor without a value exited $vnone_rc"; fi
set +e
(cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$SETUP" --vendor=) >/dev/null 2>"$ROOT/veq.err"
veq_rc=$?
set -e
if [[ "$veq_rc" -eq 2 ]] && grep -q 'empty vendor' "$ROOT/veq.err"; then ok "--vendor= (empty value) exits 2 instead of silently declaring nothing (Codex round 3)"
else bad "--vendor= exited $veq_rc: $(cat "$ROOT/veq.err")"; fi
if ! git -C "$REPO" config --worktree --get gibson.agentVendor >/dev/null 2>&1; then ok "--vendor= left no declaration behind"
else bad "--vendor= declared '$(git -C "$REPO" config --worktree --get gibson.agentVendor)'"; fi
if (cd "$REPO" && "$SETUP" --vendor Claude) >"$ROOT/vok.out" 2>"$ROOT/vok.err"; then
  ok "--vendor Claude succeeds"
else
  bad "--vendor Claude failed: $(cat "$ROOT/vok.err")"
fi
declared=$(git -C "$REPO" config --worktree --get gibson.agentVendor 2>/dev/null || true)
if [[ "$declared" == "claude" ]]; then ok "declaration is worktree-scoped and lower-cased (gibson.agentVendor=claude)"
else bad "gibson.agentVendor was '${declared:-<unset>}' (want claude, worktree scope)"; fi
if ! git -C "$REPO" config --local --get gibson.agentVendor >/dev/null 2>&1; then
  ok "nothing was written to the shared (--local) config"
else
  bad "gibson.agentVendor leaked into the shared config"
fi
if grep -q "commits as vendor 'claude'" "$ROOT/vok.out"; then ok "--vendor reports the declaration"
else bad "--vendor was silent about the declaration: $(cat "$ROOT/vok.out")"; fi

echo "prepare-commit-msg adds the lane's Agent-Vendor (and still signs off)"
msg="$ROOT/msg-lane-add"
printf 'subject\n\nbody\n' > "$msg"
if (cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$PREPARE" "$msg"); then
  ok "prepare-commit-msg exits 0 on a declared lane"
else
  bad "prepare-commit-msg failed on a declared lane"
fi
if grep -qx 'Agent-Vendor: claude' "$msg"; then ok "appended Agent-Vendor: claude"
else bad "no Agent-Vendor appended: $(cat "$msg")"; fi
if grep -qiE '^Signed-off-by:[[:space:]]+' "$msg"; then ok "Signed-off-by still added alongside"
else bad "Signed-off-by missing on a lane commit: $(cat "$msg")"; fi
if (cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$PREPARE" "$msg") && [[ "$(grep -ci '^Agent-Vendor:' "$msg")" == "1" ]]; then
  ok "a second run does not duplicate the trailer"
else
  bad "trailer duplicated on re-run: $(cat "$msg")"
fi

echo "prepare-commit-msg leaves claim.sh's reservation shape alone (trailer in its own paragraph)"
msg="$ROOT/msg-reserve"
printf 'chore: reserve issue #1 for issue-1-x\n\nAgent-Vendor: claude\n\nGibson-Reservation: v1\nGibson-Claim-ID: issue-1-x\nGibson-Issue: #1\nGibson-Branch: feat/1-x\nSigned-off-by: gibson-sensor <%s>\n' "$LANE_EMAIL" > "$msg"
before=$(cat "$msg")
(cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$PREPARE" "$msg")
if [[ "$(cat "$msg")" == "$before" ]]; then ok "reservation message is byte-identical (no second Agent-Vendor in the Gibson block)"
else bad "reservation message was rewritten: $(cat "$msg")"; fi
if (cd "$REPO" && lane_env env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$msg"); then ok "commit-msg accepts the reservation shape"
else bad "commit-msg rejected claim.sh's reservation shape"; fi

echo "commit-msg refuses what review-evidence would refuse later, on the declared lane"
printf 'subject\n\nSigned-off-by: A <a@example.test>\n' > "$ROOT/msg-missing"
if (cd "$REPO" && lane_env env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$ROOT/msg-missing") 2>"$ROOT/missing.err"; then
  bad "commit-msg accepted a lane commit with no Agent-Vendor"
else
  if grep -q 'no Agent-Vendor trailer' "$ROOT/missing.err" && grep -q 'setup-hooks.sh --vendor claude' "$ROOT/missing.err"; then
    ok "missing trailer: refused, names the fix (#506 class)"
  else bad "missing-trailer refusal unclear: $(cat "$ROOT/missing.err")"; fi
fi
printf 'subject\n\nAgent-Vendor: grok\nSigned-off-by: A <a@example.test>\n' > "$ROOT/msg-mismatch"
if (cd "$REPO" && lane_env env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$ROOT/msg-mismatch") 2>"$ROOT/mismatch.err"; then
  bad "commit-msg accepted a trailer that disagrees with the lane"
else
  if grep -q "says 'grok' but this lane is declared as 'claude'" "$ROOT/mismatch.err"; then ok "mismatched trailer: refused"
  else bad "mismatch refusal unclear: $(cat "$ROOT/mismatch.err")"; fi
fi
printf 'subject\n\nAgent-Vendor: claude\nAgent-Vendor: codex\nSigned-off-by: A <a@example.test>\n' > "$ROOT/msg-two"
if (cd "$REPO" && lane_env env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$ROOT/msg-two") 2>"$ROOT/two.err"; then
  bad "commit-msg accepted two vendors on one commit"
else
  if grep -q 'more than one vendor' "$ROOT/two.err"; then ok "two vendors on one commit: refused"
  else bad "two-vendor refusal unclear: $(cat "$ROOT/two.err")"; fi
fi
printf 'subject\n\nAgent-Vendor: claude\nSigned-off-by: A <a@example.test>\n' > "$ROOT/msg-good"
if (cd "$REPO" && GIBSON_AGENT_VENDOR=grok lane_env "$COMMIT_MSG" "$ROOT/msg-good") 2>"$ROOT/envmis.err"; then
  bad "commit-msg guessed between GIBSON_AGENT_VENDOR=grok and the lane's claude"
else
  if grep -q "GIBSON_AGENT_VENDOR='grok'" "$ROOT/envmis.err"; then ok "environment vendor disagreeing with the lane: refused, never guessed"
  else bad "env-mismatch refusal unclear: $(cat "$ROOT/envmis.err")"; fi
fi
printf 'subject\n\nbody\n' > "$ROOT/msg-envmis-prep"
if (cd "$REPO" && GIBSON_AGENT_VENDOR=grok "$PREPARE" "$ROOT/msg-envmis-prep") 2>/dev/null; then
  bad "prepare-commit-msg guessed between GIBSON_AGENT_VENDOR=grok and the lane's claude"
else
  ok "prepare-commit-msg refuses the same disagreement"
fi
# The hermetic default identity is sensor@gibson.invalid — exactly the #503/#504 class.
if (cd "$REPO" && env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$ROOT/msg-good") 2>"$ROOT/invalid.err"; then
  bad "commit-msg accepted a .invalid committer on a declared lane"
else
  if grep -q 'reserved .invalid domain' "$ROOT/invalid.err" && grep -q 'no-login' "$ROOT/invalid.err"; then
    ok ".invalid author/committer email: refused, names no-login (#503/#504 class)"
  else bad ".invalid refusal unclear: $(cat "$ROOT/invalid.err")"; fi
fi
if (cd "$REPO" && lane_env env -u GIBSON_AGENT_VENDOR "$COMMIT_MSG" "$ROOT/msg-good"); then
  ok "matching trailer + resolvable identity: accepted"
else
  bad "commit-msg rejected a correct lane commit"
fi

echo "end to end: a plain git commit on a declared lane carries the trailer; the main worktree does not"
E2E="$ROOT/e2e"
mkdir -p "$E2E"
$GIT init -q "$E2E"
git -C "$E2E" config user.name gibson-sensor
git -C "$E2E" config user.email "$LANE_EMAIL"
mkdir -p "$E2E/.githooks"
cp "$PREPARE" "$COMMIT_MSG" "$E2E/.githooks/"
(cd "$E2E" && "$SETUP") >/dev/null 2>&1
# The hooks must be IN the commit the lane checks out: core.hooksPath=.githooks
# is relative to each worktree, and git silently runs nothing when it is absent.
(cd "$E2E" && git add .githooks && lane_env $GIT_LANE commit -q -m init) >/dev/null 2>&1
git -C "$E2E" worktree add -q "$ROOT/e2e-lane" -b lane/1 HEAD 2>/dev/null
(cd "$ROOT/e2e-lane" && "$SETUP" --vendor codex) >/dev/null 2>&1
if (cd "$ROOT/e2e-lane" && lane_env env -u GIBSON_AGENT_VENDOR $GIT_LANE commit -q --allow-empty -m "lane work") 2>"$ROOT/e2e.err"; then
  ok "git commit on the declared lane succeeds"
else
  bad "git commit on the declared lane failed: $(cat "$ROOT/e2e.err")"
fi
lane_msg=$(git -C "$ROOT/e2e-lane" log -1 --format=%B)
if grep -qx 'Agent-Vendor: codex' <<<"$lane_msg"; then ok "lane commit carries Agent-Vendor: codex"
else bad "lane commit lacks the trailer: $lane_msg"; fi
if grep -qiE '^Signed-off-by:[[:space:]]+' <<<"$lane_msg"; then ok "lane commit is also signed off"
else bad "lane commit is unsigned: $lane_msg"; fi
if (cd "$ROOT/e2e-lane" && GIT_AUTHOR_EMAIL=codex@openai.invalid GIT_COMMITTER_EMAIL=codex@openai.invalid env -u GIBSON_AGENT_VENDOR $GIT_LANE commit -q --allow-empty -m "as codex@openai.invalid") 2>/dev/null; then
  bad "git commit as codex@openai.invalid was accepted on the lane"
else
  ok "git commit as codex@openai.invalid is refused on the lane (the #503/#504 commit would have stopped here)"
fi
if ! git -C "$E2E" config --get gibson.agentVendor >/dev/null 2>&1; then ok "main worktree is still undeclared"
else bad "lane declaration leaked into the main worktree: $(git -C "$E2E" config --get gibson.agentVendor)"; fi
(cd "$E2E" && lane_env env -u GIBSON_AGENT_VENDOR $GIT_LANE commit -q --allow-empty -m "main work") >/dev/null 2>&1
main_msg=$(git -C "$E2E" log -1 --format=%B)
if ! grep -qi '^Agent-Vendor:' <<<"$main_msg"; then ok "main worktree commit carries no Agent-Vendor (owner checkout unchanged)"
else bad "main worktree commit gained a trailer: $main_msg"; fi
if (cd "$E2E" && GIT_AUTHOR_EMAIL=sensor@gibson.invalid GIT_COMMITTER_EMAIL=sensor@gibson.invalid env -u GIBSON_AGENT_VENDOR $GIT_LANE commit -q --allow-empty -m "main .invalid") 2>/dev/null; then
  ok "main worktree still accepts any identity (the .invalid rule applies to declared lanes only)"
else
  bad "main worktree refused a commit on identity grounds"
fi

echo "setup-hooks.sh --vendor from-reservation declares a pre-#523 claim.sh lane from its own reservation commit"
FR="$ROOT/fr"
mkdir -p "$FR"
$GIT init -q "$FR"
git -C "$FR" config user.name gibson-sensor
git -C "$FR" config user.email "$LANE_EMAIL"
mkdir -p "$FR/.githooks"
cp "$PREPARE" "$COMMIT_MSG" "$FR/.githooks/"
(cd "$FR" && git add .githooks && lane_env $GIT_LANE commit -q -m init) >/dev/null 2>&1
$GIT init -q --bare "$ROOT/fr-origin.git"
git -C "$FR" remote add origin "$ROOT/fr-origin.git"
git -C "$FR" push -q origin HEAD:refs/heads/main 2>/dev/null
if git -C "$FR" rev-parse --verify --quiet 'origin/main^{commit}' >/dev/null; then ok "fixture: origin/main resolves"
else bad "fixture bug: origin/main missing"; fi
# The lane exactly as claim.sh left it before #523: reservation commit with the
# trailer in its own paragraph above the Gibson block, then hand-made work
# without any trailer, and no gibson.agentVendor anywhere. Hooks are not wired
# in this fixture until setup-hooks.sh runs, so the messages are what we write.
reserve_msg() { # branch vendor-lines...
  local branch="$1"; shift
  printf 'chore: reserve issue #9 for issue-9-x\n\n'
  local l; for l in "$@"; do printf '%s\n' "$l"; done
  printf '\nGibson-Reservation: v1\nGibson-Claim-ID: issue-9-x\nGibson-Issue: #9\nGibson-Branch: %s\n' "$branch"
}
git -C "$FR" worktree add -q "$ROOT/fr-lane" -b feat/9-x HEAD 2>/dev/null
(cd "$ROOT/fr-lane" && lane_env $GIT_LANE commit -q --allow-empty -s -m "$(reserve_msg feat/9-x 'Agent-Vendor: Grok')" \
  && lane_env $GIT_LANE commit -q --allow-empty -s -m "hand-made work, no trailer") >/dev/null 2>&1
RES_SHA=$(git -C "$ROOT/fr-lane" rev-parse HEAD~1)
if (cd "$ROOT/fr-lane" && "$SETUP" --vendor from-reservation) >"$ROOT/fr.out" 2>"$ROOT/fr.err"; then
  ok "--vendor from-reservation exits 0 on a lane with a reservation"
else
  bad "--vendor from-reservation failed: $(cat "$ROOT/fr.err")"
fi
if grep -q "vendor 'grok' read from reservation commit $RES_SHA (Gibson-Branch: feat/9-x" "$ROOT/fr.out"; then ok "names the vendor (lower-cased), the reservation SHA and the Gibson-Branch it matched"
else bad "from-reservation output unclear: $(cat "$ROOT/fr.out")"; fi
declared=$(git -C "$ROOT/fr-lane" config --worktree --get gibson.agentVendor 2>/dev/null || true)
if [[ "$declared" == "grok" ]]; then ok "lane is declared grok (worktree-scoped)"
else bad "lane declaration was '${declared:-<unset>}'"; fi
if ! git -C "$FR" config --get gibson.agentVendor >/dev/null 2>&1; then ok "main worktree stays undeclared"
else bad "declaration leaked into the main worktree"; fi
if (cd "$ROOT/fr-lane" && lane_env env -u GIBSON_AGENT_VENDOR $GIT_LANE commit -q --allow-empty -m "work after declaring") 2>"$ROOT/fr-after.err" \
   && grep -qx 'Agent-Vendor: grok' <<<"$(git -C "$ROOT/fr-lane" log -1 --format=%B)"; then
  ok "the next plain git commit on the lane carries Agent-Vendor: grok through the hooks"
else
  bad "commit after from-reservation lacks the trailer: $(cat "$ROOT/fr-after.err") $(git -C "$ROOT/fr-lane" log -1 --format=%B)"
fi
if (cd "$ROOT/fr-lane" && lane_env env -u GIBSON_AGENT_VENDOR $GIT_LANE commit -q --allow-empty -m "claude says" -m "Agent-Vendor: claude") 2>/dev/null; then
  bad "a cross-vendor trailer was accepted on the lane declared from its reservation"
else
  ok "a cross-vendor trailer is refused on the lane declared from its reservation"
fi

echo "--vendor from-reservation refuses loudly instead of guessing"
# Commits are made with --no-verify: the from-reservation run above wired
# core.hooksPath for the whole repository, and commit-msg would refuse the
# two-vendor and bogus-vendor messages — which is exactly the bypass this
# option and the loop's walk exist for.
fr_case() { # name branch exit-want needle msg-lines...
  local name="$1" branch="$2" want="$3" needle="$4"; shift 4
  git -C "$FR" worktree add -q "$ROOT/fr-$name" -b "$branch" HEAD 2>/dev/null
  local l
  for l in "$@"; do
    (cd "$ROOT/fr-$name" && lane_env $GIT_LANE commit -q --no-verify --allow-empty -s -m "$l") >/dev/null 2>&1
  done
  set +e
  (cd "$ROOT/fr-$name" && "$SETUP" --vendor from-reservation) >"$ROOT/fr-$name.out" 2>"$ROOT/fr-$name.err"
  local rc=$?
  set -e
  if [[ "$want" -eq 0 ]]; then
    if [[ "$rc" -eq 0 ]]; then ok "$name: exit 0"; else bad "$name: rc=$rc stderr=$(cat "$ROOT/fr-$name.err")"; fi
    return 0
  fi
  if [[ "$rc" -eq "$want" ]] && grep -q -- "$needle" "$ROOT/fr-$name.err"; then ok "$name: exit $want, names '$needle'"
  else bad "$name: rc=$rc (want $want) stderr=$(cat "$ROOT/fr-$name.err")"; fi
  if ! git -C "$ROOT/fr-$name" config --worktree --get gibson.agentVendor >/dev/null 2>&1; then ok "$name: nothing was declared"
  else bad "$name: declared '$(git -C "$ROOT/fr-$name" config --worktree --get gibson.agentVendor)' despite the refusal"; fi
}
fr_case no-reservation feat/10-plain 1 "no commit in" "plain work, never claimed"
fr_case no-trailer feat/11-old 1 "has no Agent-Vendor trailer" "$(reserve_msg feat/11-old)"
fr_case two-vendors feat/12-two 1 "more than one vendor (claude grok)" "$(reserve_msg feat/12-two 'Agent-Vendor: claude' 'Agent-Vendor: grok')"
fr_case unknown-vendor feat/13-bogus 2 "unknown agent vendor 'bogus'" "$(reserve_msg feat/13-bogus 'Agent-Vendor: bogus')"
# The reservation must name THIS branch (Codex review of #525). A lane stacked
# on another lane has the parent's reservation in its range and must not
# inherit the parent's vendor; its own reservation is matched wherever it sits.
fr_case stacked-child feat/14-child 1 "belong to another lane" "$(reserve_msg feat/14-parent 'Agent-Vendor: codex')"
if grep -q "Gibson-Branch: feat/14-parent" "$ROOT/fr-stacked-child.err"; then ok "stacked-child: refusal names the foreign reservation's branch"
else bad "stacked-child: refusal does not name the parent's reservation: $(cat "$ROOT/fr-stacked-child.err")"; fi
fr_case match-not-first feat/15-mine 0 "" "$(reserve_msg feat/15-parent 'Agent-Vendor: codex')" "$(reserve_msg feat/15-mine 'Agent-Vendor: grok')"
if [[ "$(git -C "$ROOT/fr-match-not-first" config --worktree --get gibson.agentVendor 2>/dev/null)" == "grok" ]]; then ok "match-not-first: the reservation naming this branch (grok) wins over an earlier parent reservation (codex)"
else bad "match-not-first: declared '$(git -C "$ROOT/fr-match-not-first" config --worktree --get gibson.agentVendor 2>/dev/null)' (want grok)"; fi
fr_case two-own feat/16-dup 1 "ambiguous" "$(reserve_msg feat/16-dup 'Agent-Vendor: grok')" "$(reserve_msg feat/16-dup 'Agent-Vendor: grok')"
git -C "$FR" worktree add -q --detach "$ROOT/fr-detached" HEAD 2>/dev/null
(cd "$ROOT/fr-detached" && lane_env $GIT_LANE commit -q --no-verify --allow-empty -s -m "$(reserve_msg feat/17-x 'Agent-Vendor: grok')") >/dev/null 2>&1
set +e
(cd "$ROOT/fr-detached" && "$SETUP" --vendor from-reservation) >/dev/null 2>"$ROOT/fr-detached.err"
det_rc=$?
set -e
if [[ "$det_rc" -eq 1 ]] && grep -q 'HEAD is detached' "$ROOT/fr-detached.err"; then ok "detached HEAD: exit 1, no Gibson-Branch can match"
else bad "detached rc=$det_rc: $(cat "$ROOT/fr-detached.err")"; fi
NOORIGIN="$ROOT/no-origin"
mkdir -p "$NOORIGIN" && $GIT init -q "$NOORIGIN" && mkdir -p "$NOORIGIN/.githooks" && cp "$PREPARE" "$COMMIT_MSG" "$NOORIGIN/.githooks/"
(cd "$NOORIGIN" && lane_env $GIT_LANE commit -q --allow-empty -m init) >/dev/null 2>&1
set +e
(cd "$NOORIGIN" && "$SETUP" --vendor from-reservation) >/dev/null 2>"$ROOT/no-origin.err"
no_rc=$?
set -e
if [[ "$no_rc" -eq 1 ]] && grep -q 'neither origin/main nor origin/master' "$ROOT/no-origin.err"; then ok "no origin/main: exit 1, says what to fetch or pass"
else bad "no-origin rc=$no_rc: $(cat "$ROOT/no-origin.err")"; fi
if grep -q 'from-reservation' <<<"$("$SETUP" --help)"; then ok "--help documents --vendor from-reservation"
else bad "--help does not mention from-reservation"; fi

echo
echo "setup-hooks.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
