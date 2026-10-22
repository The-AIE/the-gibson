#!/usr/bin/env bash
# dco-handoff.test.sh — sensors for Signed-off-by refusal on handoff (issue #204)
# and for the Agent-Vendor walk beside it (follow-up to the-gibson#520/#523)
#
# WHY
#   CI must not be the first thing that notices an unsigned commit. Supervisor
#   handoff (including --dry-run) and the loop handoff path refuse any commit
#   in the handed-off range that lacks a Signed-off-by trailer. The *base*
#   commit is outside that range and is left unsigned on purpose.
#   Likewise review time must not be the first place to learn a lane commit
#   resolves to no vendor: the loop walks the same range for commits with no
#   Agent-Vendor trailer, more than one vendor, an unknown vendor, or a
#   `.invalid` author/committer email (lane-bot commits resolve by identity),
#   and scripts/prepush.sh reports the same rule through cp_agent_vendor_walk.
#
# USAGE
#   scripts/tests/dco-handoff.test.sh
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GIBSON=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
LOOP="$GIBSON/scripts/loop.sh"
SUPERVISOR="$GIBSON/scripts/devin-supervisor.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v git >/dev/null || { echo "dco-handoff.test.sh: git is required"; exit 1; }
command -v node >/dev/null || { echo "dco-handoff.test.sh: node is required"; exit 1; }
[[ -x "$LOOP" && -x "$SUPERVISOR" ]] || { echo "dco-handoff.test.sh: missing loop/supervisor"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-dco-handoff.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

CALLS="$ROOT/calls"
FAKE_SCRIPTS="$ROOT/fake/scripts"
BIN="$ROOT/bin"
REPO="$ROOT/repo"
REMOTE="$ROOT/remote.git"
BRANCH="feat/1-widget"
mkdir -p "$CALLS" "$FAKE_SCRIPTS" "$BIN"

unset DEVIN_API_KEY DEVIN_WEBHOOK_URL
export DEVIN_API_BASE="http://127.0.0.1:9"

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl stub: live network forbidden: $*" >&2
exit 55
STUB
# gh stub: the Agent-Vendor walk proves email → login through GitHub's commit
# search by email (`gh api search/commits`). The fixture maps lane@gibson.test
# to the owner login mrhinkle (listed in the identity table); every other
# address is unknown to GitHub (empty result). Everything else gh fails.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Logs every search so a sensor can prove "zero gh calls". Answers
# "<email>\t<login>" exactly as the walk's jq filter shapes the real response.
[[ -z "${GH_STUB_LOG:-}" ]] || printf '%s\n' "$*" >> "$GH_STUB_LOG"
case "$*" in
  *search/commits*)
    case "$*" in
      *"author-email:lane@gibson.test"*) printf 'lane@gibson.test\tmrhinkle\n' ;;
      *"committer-email:lane@gibson.test"*) printf 'lane@gibson.test\tmrhinkle\n' ;;
      *"author-email:team@cognition.test"*) printf 'team@cognition.test\tcognition-team\n' ;;
      *"committer-email:team@cognition.test"*) printf 'team@cognition.test\tcognition-team\n' ;;
      *) printf '\t\n' ;;
    esac
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$BIN/curl" "$BIN/gh"
PATH="$BIN:$PATH"
export PATH

GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

# The hermetic identity above is sensor@gibson.invalid on purpose: `.invalid`
# is the no-login class the Agent-Vendor walk refuses. Work that must be handed
# off is therefore committed as a resolvable-looking lane address with one
# trailer; a lane-bot address resolves by identity and needs no trailer.
LANE_EMAIL=lane@gibson.test
BOT_EMAIL='317307306+aie-agent-lanes-grok[bot]@users.noreply.github.com'
# Lane-bot SHAPE, but no such login in config/review-evidence.v1.json.
FAKE_BOT_EMAIL='1+aie-agent-lanes-fake[bot]@users.noreply.github.com'
# Listed with role author, but restricted to an authorCommits allowlist.
MINI_BOT_EMAIL='2+aie-agent-lanes-mini[bot]@users.noreply.github.com'
work_commit() { # email [git-commit args...] — signed, -a
  local email="$1"; shift
  GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_EMAIL="$email" $GIT -C "$REPO" commit -q -s -a "$@"
}

# base stays unsigned on purpose; work commits are shaped per caller:
#   signed         one Agent-Vendor trailer, lane email (hands off)
#   unsigned       no Signed-off-by (DCO refuses first)
#   unvendored     signed, lane email, no trailer           (#506 class)
#   invalid-email  signed, trailer, author/committer .invalid (#503/#504 class)
#   two-vendors    signed, two distinct Agent-Vendor trailers
#   unknown-vendor signed, Agent-Vendor: bogus
#   bot            signed, lane-bot email, no trailer       (resolves by login)
#   stranger       signed, trailer, author/committer an address GitHub maps to no login
#   cognition      signed, trailer, an address GitHub maps to cognition-team (listed, non-owner, non-bot)
#   bot-invalid-committer  lane-bot author, .invalid committer, no trailer
#   bare-invalid   signed, trailer, author/committer `codex@invalid` (bare form)
#   fake-bot       signed, lane-bot-shaped email the evaluator does not list, no trailer
#   mini-bot       signed, listed bot with an authorCommits allowlist, no trailer
setup_repo() { # setup_repo <mode>
  local mode="${1:-signed}"
  rm -rf "$REPO" "$REMOTE"
  mkdir -p "$REPO"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  echo base > "$REPO/README.md"
  # The evaluator's identity table: the lane-bot exemption is only for logins
  # listed there with role "author" (the walk reads it from the repo root).
  mkdir -p "$REPO/config"
  cp "$GIBSON/config/review-evidence.v1.json" "$REPO/config/"
  $GIT -C "$REPO" add README.md config
  $GIT -C "$REPO" commit -q -m "base"
  $GIT -C "$REPO" checkout -q -b "$BRANCH"
  echo work >> "$REPO/README.md"
  case "$mode" in
    signed)         work_commit "$LANE_EMAIL" -m "work" -m "Agent-Vendor: claude" ;;
    unsigned)       $GIT -C "$REPO" commit -q -am "work" ;;
    unvendored)     work_commit "$LANE_EMAIL" -m "work" ;;
    invalid-email)  work_commit sensor@gibson.invalid -m "work" -m "Agent-Vendor: claude" ;;
    two-vendors)    work_commit "$LANE_EMAIL" -m "work" -m "Agent-Vendor: claude" -m "Agent-Vendor: codex" ;;
    unknown-vendor) work_commit "$LANE_EMAIL" -m "work" -m "Agent-Vendor: bogus" ;;
    bot)            work_commit "$BOT_EMAIL" -m "work" ;;
    stranger)       work_commit stranger@gibson.test -m "work" -m "Agent-Vendor: claude" ;;
    cognition)      work_commit team@cognition.test -m "work" -m "Agent-Vendor: devin" ;;
    bare-invalid)   work_commit codex@invalid -m "work" -m "Agent-Vendor: codex" ;;
    fake-bot)       work_commit "$FAKE_BOT_EMAIL" -m "work" ;;
    mini-bot)       work_commit "$MINI_BOT_EMAIL" -m "work" ;;
    bot-invalid-committer)
      # Lane-bot author, .invalid committer, no trailer: review-evidence fails
      # committer:<sha>:no-login, so the walk must not take the bot fast path
      # before looking at both identities (Codex review of #525).
      GIT_AUTHOR_EMAIL="$BOT_EMAIL" GIT_COMMITTER_EMAIL=sensor@gibson.invalid $GIT -C "$REPO" commit -q -s -a -m "work" ;;
    *) echo "setup_repo: unknown mode $mode" >&2; exit 1 ;;
  esac
  $GIT -C "$REPO" checkout -q main
  $GIT init -q --bare "$REMOTE"
  git -C "$REPO" remote add origin "https://github.com/acme/widget.git"
  git -C "$REPO" config --local "url.${REMOTE}.insteadOf" "https://github.com/acme/widget.git"
  git -C "$REPO" push -q origin main "$BRANCH"
  git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
  : > "$CALLS/devin.cmds"
  : > "$CALLS/devin.args"
  : > "$CALLS/second-opinion.count"
}

head_sha() { git -C "$REPO" rev-parse --verify "refs/heads/$BRANCH"; }
base_sha() { git -C "$REPO" rev-parse --verify refs/heads/main; }

write_state() {
  mkdir -p "$REPO/gibson"
  cat > "$REPO/gibson/loop-state.md" <<EOF
# Gibson loop state
updated: 2026-08-02T00:00:00Z
issue: 1
pr:
hat: builder
next_hat: builder
round: 1
parked: false
handoff: ${1:-}
handoff_sha: ${2:-}
next_action: hand the finished branch to the supervisor
notes: fixture
EOF
}

cat > "$FAKE_SCRIPTS/second-opinion.sh" <<STUB
#!/usr/bin/env bash
echo call >> "$CALLS/second-opinion.count"
out=""
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--out" ]] && out="\$a"
  prev="\$a"
done
if [[ -n "\$out" ]]; then
  mkdir -p "\$(dirname "\$out")"
  echo "## Second opinion — stub reviewer" > "\$out"
fi
exit 0
STUB

cat > "$FAKE_SCRIPTS/devin-supervisor.sh" <<STUB
#!/usr/bin/env bash
echo "\$1" >> "$CALLS/devin.cmds"
printf '%s\n' "\$@" >> "$CALLS/devin.args"
exit 0
STUB

cp "$LOOP" "$FAKE_SCRIPTS/loop.sh"
chmod +x "$FAKE_SCRIPTS/second-opinion.sh" "$FAKE_SCRIPTS/devin-supervisor.sh" "$FAKE_SCRIPTS/loop.sh"

run_loop() {
  HERMES_CMD='cat >/dev/null' \
  "$FAKE_SCRIPTS/loop.sh" --runner hermes --repo "$REPO" --repo-slug acme/widget \
    --gibson "$GIBSON" --once --supervisor devin >/dev/null 2>"$1"
  return $?
}

handoff_invoked() { grep -qx handoff "$CALLS/devin.cmds"; }

echo "supervisor handoff --dry-run of unsigned work exits nonzero and names Signed-off-by"
setup_repo unsigned
SHA=$(head_sha)
BASE=$(base_sha)
# Prove the base itself is unsigned — a whole-history check would refuse this.
if git -C "$REPO" log -1 --format=%B "$BASE" | grep -iE '^Signed-off-by:[[:space:]]+' >/dev/null; then
  bad "fixture bug: base commit must stay unsigned"
else
  ok "fixture: base commit is unsigned (range-only check)"
fi
if git -C "$REPO" log -1 --format=%B "$SHA" | grep -iE '^Signed-off-by:[[:space:]]+' >/dev/null; then
  bad "fixture bug: work commit must be unsigned in this case"
else
  ok "fixture: work commit is unsigned"
fi
set +e
sup_out=$("$SUPERVISOR" handoff --repo "$REPO" --branch "$BRANCH" --base main \
  --base-sha "$BASE" --sha "$SHA" --task "unsigned sensor" --dry-run 2>"$ROOT/unsigned.err")
sup_rc=$?
set -e
if [[ "$sup_rc" -ne 0 ]]; then
  ok "unsigned range: supervisor --dry-run exits nonzero (rc=$sup_rc)"
else
  bad "unsigned range: supervisor --dry-run must refuse, not succeed"
fi
if grep -qi 'Signed-off-by' "$ROOT/unsigned.err" && grep -q "$SHA" "$ROOT/unsigned.err"; then
  ok "unsigned range: refusal names Signed-off-by and the unsigned SHA"
else
  bad "unsigned range: refusal unclear: $(cat "$ROOT/unsigned.err")"
fi
if [[ -z "${sup_out:-}" ]] || ! grep -q 'New candidate from the Gibson loop' <<<"${sup_out:-}"; then
  ok "unsigned range: no would-send / handoff message on stdout"
else
  bad "unsigned range: printed a would-send message despite unsigned work"
fi

echo "supervisor handoff --dry-run of a fully signed range does not refuse for DCO"
setup_repo signed
SHA=$(head_sha)
BASE=$(base_sha)
if git -C "$REPO" log -1 --format=%B "$BASE" | grep -iE '^Signed-off-by:[[:space:]]+' >/dev/null; then
  bad "fixture bug: signed-range case must keep the base unsigned"
else
  ok "fixture: signed-range base is still unsigned"
fi
if git -C "$REPO" log -1 --format=%B "$SHA" | grep -iE '^Signed-off-by:[[:space:]]+' >/dev/null; then
  ok "fixture: work commit is signed"
else
  bad "fixture bug: work commit is not signed"
fi
set +e
sup_out=$("$SUPERVISOR" handoff --repo "$REPO" --branch "$BRANCH" --base main \
  --base-sha "$BASE" --sha "$SHA" --task "signed sensor" --dry-run 2>"$ROOT/signed.err")
sup_rc=$?
set -e
if [[ "$sup_rc" -eq 0 ]]; then
  ok "signed range: supervisor --dry-run succeeds"
else
  bad "signed range: supervisor --dry-run failed (rc=$sup_rc stderr=$(cat "$ROOT/signed.err"))"
fi
if grep -qi 'Signed-off-by' "$ROOT/signed.err"; then
  bad "signed range: must not refuse for DCO (stderr=$(cat "$ROOT/signed.err"))"
else
  ok "signed range: no DCO refusal"
fi
if grep -q 'New candidate from the Gibson loop' <<<"$sup_out"; then
  ok "signed range: dry-run still renders the handoff message"
else
  bad "signed range: dry-run message missing"
fi

echo "empty range is fine (no commits to sign)"
setup_repo signed
# Hand the base commit to itself: <base>..<base> is empty.
BASE=$(base_sha)
set +e
"$SUPERVISOR" handoff --repo "$REPO" --branch main --base main \
  --base-sha "$BASE" --sha "$BASE" --task "empty range sensor" --dry-run \
  >/dev/null 2>"$ROOT/empty.err"
empty_rc=$?
set -e
if [[ "$empty_rc" -eq 0 ]]; then
  ok "empty range: supervisor --dry-run succeeds"
else
  bad "empty range must pass (rc=$empty_rc stderr=$(cat "$ROOT/empty.err"))"
fi

echo "loop handoff path refuses unsigned work before invoking the supervisor"
setup_repo unsigned
SHA=$(head_sha)
write_state "$BRANCH" "$SHA"
run_loop "$ROOT/loop-unsigned.err"
if handoff_invoked; then
  bad "loop must not invoke the supervisor for unsigned work"
else
  ok "loop does not invoke the supervisor for unsigned work"
fi
if [[ -s "$CALLS/second-opinion.count" ]]; then
  bad "loop must not spend a reviewer on unsigned work"
else
  ok "loop does not spend a reviewer on unsigned work"
fi
if grep -qi 'Signed-off-by' "$REPO/gibson/journal.md" &&
   grep -q "$SHA" "$REPO/gibson/journal.md"; then
  ok "loop journals the unsigned SHA and Signed-off-by"
else
  bad "loop journal missing DCO reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"
fi
if grep -qx "handoff: $BRANCH" "$REPO/gibson/loop-state.md"; then
  ok "unsigned loop handoff stays queued"
else
  bad "unsigned loop handoff was cleared from loop-state"
fi
if grep -qi 'Signed-off-by' "$ROOT/loop-unsigned.err"; then
  ok "loop stderr names Signed-off-by"
else
  bad "loop stderr silent on DCO: $(tr '\n' ' ' <"$ROOT/loop-unsigned.err")"
fi

echo "loop handoff path lets signed work through (unsigned base ignored)"
setup_repo signed
SHA=$(head_sha)
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-signed.err"
if handoff_invoked; then
  ok "loop hands off a signed range"
else
  bad "loop blocked a signed range (stderr=$(tr '\n' ' ' <"$ROOT/loop-signed.err") journal=$([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent))"
fi

# ---------------------------------------------------------------------------
# Agent-Vendor walk (follow-up to the-gibson#520/#523)
# ---------------------------------------------------------------------------
echo "Agent-Vendor walk: the loop refuses work review-evidence would not resolve, before reviewer or supervisor"
for mode in unvendored invalid-email two-vendors unknown-vendor; do
  setup_repo "$mode"
  SHA=$(head_sha)
  write_state "$BRANCH" "$SHA"
  run_loop "$ROOT/loop-$mode.err"
  if handoff_invoked; then bad "$mode: loop invoked the supervisor"
  else ok "$mode: loop does not invoke the supervisor"; fi
  if [[ -s "$CALLS/second-opinion.count" ]]; then bad "$mode: loop spent a reviewer"
  else ok "$mode: loop does not spend a reviewer"; fi
  if grep -q 'Agent-Vendor' "$REPO/gibson/journal.md" && grep -q "$SHA" "$REPO/gibson/journal.md" \
     && grep -q 'setup-hooks.sh --vendor from-reservation' "$REPO/gibson/journal.md" \
     && grep -q 'git commit --amend' "$REPO/gibson/journal.md"; then
    ok "$mode: journal names Agent-Vendor, the SHA and the fix (setup-hooks.sh --vendor, amend/rebase)"
  else
    bad "$mode: journal missing the Agent-Vendor reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"
  fi
  if grep -qi 'Signed-off-by trailer' "$REPO/gibson/journal.md"; then bad "$mode: refused for DCO, not for Agent-Vendor (fixture is signed)"
  else ok "$mode: the DCO walk passed; only the Agent-Vendor walk refused"; fi
  if grep -qx "handoff: $BRANCH" "$REPO/gibson/loop-state.md"; then ok "$mode: handoff stays queued"
  else bad "$mode: handoff was cleared from loop-state"; fi
done
# The reason the journal gives must be the evaluator's class, per mode.
setup_repo unvendored;     SHA=$(head_sha); write_state "$BRANCH" "$SHA"; run_loop "$ROOT/r1.err"
grep -q "$SHA no-trailer" "$REPO/gibson/journal.md" && ok "unvendored: reason is no-trailer" || bad "unvendored reason: $(cat "$REPO/gibson/journal.md")"
setup_repo invalid-email;  SHA=$(head_sha); write_state "$BRANCH" "$SHA"; run_loop "$ROOT/r2.err"
grep -q "$SHA invalid-email:sensor@gibson.invalid" "$REPO/gibson/journal.md" && ok "invalid-email: reason names the .invalid address" || bad "invalid-email reason: $(cat "$REPO/gibson/journal.md")"
setup_repo two-vendors;    SHA=$(head_sha); write_state "$BRANCH" "$SHA"; run_loop "$ROOT/r3.err"
grep -q "$SHA multi-vendor:claude,codex" "$REPO/gibson/journal.md" && ok "two-vendors: reason lists both" || bad "two-vendors reason: $(cat "$REPO/gibson/journal.md")"
setup_repo unknown-vendor; SHA=$(head_sha); write_state "$BRANCH" "$SHA"; run_loop "$ROOT/r4.err"
grep -q "$SHA unknown-vendor:bogus" "$REPO/gibson/journal.md" && ok "unknown-vendor: reason names bogus" || bad "unknown-vendor reason: $(cat "$REPO/gibson/journal.md")"

echo "Agent-Vendor walk: a lane-bot-shaped login the evaluator does not list is not exempt"
setup_repo fake-bot
SHA=$(head_sha)
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-fake-bot.err"
if handoff_invoked; then bad "fake-bot: loop handed off a commit from an unlisted aie-agent-lanes-fake[bot]"
else ok "fake-bot: loop does not invoke the supervisor"; fi
if grep -q "$SHA unlisted-login:aie-agent-lanes-fake\[bot\]" "$REPO/gibson/journal.md"; then ok "fake-bot: journal names the unlisted login"
else bad "fake-bot: journal reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"; fi

echo "Agent-Vendor walk: a listed bot with an authorCommits allowlist is exempt only for those exact SHAs"
setup_repo mini-bot
SHA=$(head_sha)
ALLOWED=$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const i=c.identities.find(x=>x.login==="aie-agent-lanes-mini[bot]");console.log((i.authorCommits||[])[0]||"")' "$REPO/config/review-evidence.v1.json")
if [[ "$ALLOWED" =~ ^[0-9a-f]{40}$ ]]; then ok "fixture: the identity table restricts aie-agent-lanes-mini[bot] to an allowlist (first: ${ALLOWED:0:7})"
else bad "fixture bug: no authorCommits allowlist for aie-agent-lanes-mini[bot] in the table"; fi
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-mini-bot.err"
if handoff_invoked; then bad "mini-bot: loop handed off a commit outside the identity's authorCommits allowlist"
else ok "mini-bot: non-allowlisted SHA is not exempt; loop does not invoke the supervisor"; fi
if grep -q "$SHA commit-not-allowed:aie-agent-lanes-mini\[bot\]" "$REPO/gibson/journal.md"; then ok "mini-bot: journal names commit-not-allowed and the login"
else bad "mini-bot: journal reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"; fi
# The allowlisted side, through the lib: the identity carries the allowlist,
# and the verdict for a SHA outside it is commit-not-allowed; a prefix is not a
# match (the walk compares the full 40-hex SHA). Return codes are data: errexit off.
set +e
. "$GIBSON/scripts/lib/agent-vendor.sh"
ident=$(agent_vendor_identity "$REPO" main "aie-agent-lanes-mini[bot]"); rc=$?
[[ "$rc" -eq 0 && "${ident%%	*}" == "codex" && "${ident#*	}" == *"$ALLOWED"* ]] && ok "identity table: aie-agent-lanes-mini[bot] → vendor codex with its allowlist (${ALLOWED:0:7}…)" || bad "identity mini rc=$rc '$ident'"
[[ "${ident#*	}" != *"${ALLOWED:0:12},"* || "${ident#*	}" == *"$ALLOWED"* ]] && ok "allowlist entries are full SHAs, matched exactly (no prefix)" || bad "allowlist shape '$ident'"
why=$(agent_vendor_commit_problem "$REPO" "$SHA" main)
[[ "$why" == "commit-not-allowed:aie-agent-lanes-mini[bot]" ]] && ok "mini-bot: a SHA outside the allowlist → commit-not-allowed" || bad "outside reason '$why'"
setup_repo bot
why=$(agent_vendor_commit_problem "$REPO" "$(head_sha)" main)
[[ -z "$why" ]] && ok "grok bot (no allowlist): any SHA resolves" || bad "unrestricted bot reason '$why'"
setup_repo mini-bot
SHA=$(head_sha)
# And through the walk: allowlist this commit's SHA in the table ON THE BASE
# (committed to main and pushed, which is what the loop reads) → the same
# commit now resolves and is handed off.
node -e 'const fs=require("fs");const p=process.argv[1];const c=JSON.parse(fs.readFileSync(p,"utf8"));const i=c.identities.find(x=>x.login==="aie-agent-lanes-mini[bot]");i.authorCommits=[process.argv[2]];fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n")' "$REPO/config/review-evidence.v1.json" "$SHA"
$GIT -C "$REPO" commit -q -am "allowlist the mini bot's commit on the base" && git -C "$REPO" push -q origin main
# shellcheck disable=SC2034  # resets the sourced lib's cache
AGENT_VENDOR_TABLE_FOR=""
why=$(agent_vendor_commit_problem "$REPO" "$SHA" main)
[[ -z "$why" ]] && ok "mini-bot: once the BASE table allowlists this SHA, the commit resolves" || bad "allowlisted commit reason '$why'"
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
rm -f "$REPO/gibson/journal.md"
run_loop "$ROOT/loop-mini-bot-ok.err"
if handoff_invoked; then ok "mini-bot: the allowlisted commit is handed off"
else bad "mini-bot: allowlisted commit blocked (journal=$([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent))"; fi

echo "Agent-Vendor walk: a lane cannot list its own bot — the table is read at the trusted base (Codex round four)"
setup_repo fake-bot
# The lane edits ITS OWN copy of the identity table to list the fake bot, and
# commits that edit on the branch, then commits as the fake bot without a trailer.
git -C "$REPO" checkout -q "$BRANCH"
node -e 'const fs=require("fs");const p=process.argv[1];const c=JSON.parse(fs.readFileSync(p,"utf8"));c.identities.push({login:"aie-agent-lanes-fake[bot]",appSlug:"aie-agent-lanes-fake",appId:1,vendor:"grok",roles:["author"]});fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n")' "$REPO/config/review-evidence.v1.json"
GIT_AUTHOR_EMAIL="$FAKE_BOT_EMAIL" GIT_COMMITTER_EMAIL="$FAKE_BOT_EMAIL" $GIT -C "$REPO" commit -q -s -am "lane lists its own bot"
echo more >> "$REPO/README.md"
work_commit "$FAKE_BOT_EMAIL" -m "trailerless work as the self-listed bot"
git -C "$REPO" checkout -q main
git -C "$REPO" push -q origin "$BRANCH"
SHA=$(head_sha)
if node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit(c.identities.some(x=>x.login==="aie-agent-lanes-fake[bot]")?0:1)' <(git -C "$REPO" show "$SHA:config/review-evidence.v1.json"); then ok "fixture: the branch's own table lists aie-agent-lanes-fake[bot]"
else bad "fixture bug: branch table does not list the fake bot"; fi
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
rm -f "$REPO/gibson/journal.md"
run_loop "$ROOT/loop-self-listed.err"
if handoff_invoked; then bad "self-listed bot: loop trusted the lane's own identity table"
else ok "self-listed bot: loop does not invoke the supervisor"; fi
if grep -q "unlisted-login:aie-agent-lanes-fake\[bot\]" "$REPO/gibson/journal.md"; then ok "self-listed bot: journal says unlisted-login (base table decides, not the lane's copy)"
else bad "self-listed bot: journal reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"; fi
why=$(agent_vendor_commit_problem "$REPO" "$SHA" main)
[[ "$why" == "unlisted-login:aie-agent-lanes-fake[bot]" ]] && ok "self-listed bot: lib reads the base table (unlisted-login)" || bad "self-listed lib reason '$why'"
why=$(agent_vendor_commit_problem "$REPO" "$SHA" "$SHA")
[[ -z "$why" ]] && ok "control: reading the table at the lane's own head WOULD exempt it (which is why the base is used)" || bad "control reason '$why'"

echo "Agent-Vendor walk: the bare user@invalid form is refused like .invalid (#523 round five)"
setup_repo bare-invalid
SHA=$(head_sha)
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-bare-invalid.err"
if handoff_invoked; then bad "bare-invalid: loop handed off a codex@invalid commit"
else ok "bare-invalid: loop does not invoke the supervisor"; fi
if grep -q "$SHA invalid-email:codex@invalid" "$REPO/gibson/journal.md"; then ok "bare-invalid: journal names codex@invalid"
else bad "bare-invalid: journal reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"; fi

echo "Agent-Vendor walk: a listed non-owner, non-bot identity is unverified-unattested offline, trailer or not (Codex round seven)"
setup_repo cognition
SHA=$(head_sha)
if node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const i=c.identities.find(x=>x.login==="cognition-team");process.exit(i&&i.roles.includes("author")&&i.vendor!=="owner"&&i.vendor!=="human"?0:1)' "$REPO/config/review-evidence.v1.json"; then ok "fixture: cognition-team is a listed author identity that is neither owner nor human nor a lane bot"
else bad "fixture bug: cognition-team shape changed in the identity table"; fi
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-cognition.err"
if handoff_invoked; then bad "cognition: loop handed off a commit the evaluator rejects as unverified-unattested"
else ok "cognition: loop does not invoke the supervisor despite Agent-Vendor: devin"; fi
if grep -q "$SHA unverified-unattested:cognition-team" "$REPO/gibson/journal.md"; then ok "cognition: journal names unverified-unattested and the login"
else bad "cognition: journal reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"; fi
git -C "$REPO" checkout -q "$BRANCH"
git -C "$REPO" config extensions.worktreeConfig true
git -C "$REPO" config --worktree gibson.agentVendor devin
. "$GIBSON/scripts/lib/convention-probes.sh"
out=$(cd "$REPO" && cp_agent_vendor_walk main); rc=$?
[[ "$rc" -eq 1 && "$out" == *"$SHA unverified-unattested:cognition-team"* ]] && ok "cognition: declared-lane pre-push probe FAILs the same commit" || bad "cognition probe rc=$rc: $out"
git -C "$REPO" config --worktree --unset gibson.agentVendor
git -C "$REPO" config --unset extensions.worktreeConfig
git -C "$REPO" checkout -q main

echo "Agent-Vendor walk: an email GitHub maps to no login is not resolvable, trailer or not (Codex round five)"
setup_repo stranger
SHA=$(head_sha)
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-stranger.err"
if handoff_invoked; then bad "stranger: loop handed off a commit whose author email proves no login"
else ok "stranger: loop does not invoke the supervisor"; fi
if grep -q "$SHA login-unresolved:stranger@gibson.test" "$REPO/gibson/journal.md"; then ok "stranger: journal names login-unresolved and the address"
else bad "stranger: journal reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"; fi
# Mixed: a proven author with an unprovable committer is still unresolved.
setup_repo signed
SIGNED_SHA=$(head_sha)
git -C "$REPO" checkout -q "$BRANCH"
GIT_AUTHOR_EMAIL="$LANE_EMAIL" GIT_COMMITTER_EMAIL=stranger@gibson.test $GIT -C "$REPO" commit -q --allow-empty -s -m "proven author, unknown committer" -m "Agent-Vendor: claude"
git -C "$REPO" checkout -q main
SHA=$(head_sha)
set +e
. "$GIBSON/scripts/lib/agent-vendor.sh"
why=$(agent_vendor_commit_problem "$REPO" "$SHA" main acme/widget)
[[ "$why" == "login-unresolved:stranger@gibson.test" ]] && ok "stranger committer: both sides must prove a login (committer named)" || bad "mixed committer reason '$why'"
# No slug to prove against (no GitHub origin) → nothing but a noreply address can resolve.
git -C "$REPO" remote rename origin upstream
why=$(agent_vendor_commit_problem "$REPO" "$SIGNED_SHA" main "")
git -C "$REPO" remote rename upstream origin
[[ "$why" == "login-unresolved:${LANE_EMAIL}" ]] && ok "no repository slug: a plain address cannot be proven (fail closed)" || bad "no-slug reason '$why'"
why=$(agent_vendor_commit_problem "$REPO" "$SIGNED_SHA" main acme/widget)
[[ -z "$why" ]] && ok "same commit with the slug: owner login proven + one trailer → resolves" || bad "proven reason '$why'"
[[ "$(agent_vendor_login_for_email acme/widget "$LANE_EMAIL")" == "mrhinkle" ]] && ok "login_for_email: GitHub commit search maps lane@gibson.test → mrhinkle (cached)" || bad "login_for_email lane"
[[ -z "$(agent_vendor_login_for_email acme/widget stranger@gibson.test)" ]] && ok "login_for_email: unknown address → nothing" || bad "login_for_email stranger"
[[ "$(agent_vendor_login_for_email "" "$BOT_EMAIL")" == "aie-agent-lanes-grok[bot]" ]] && ok "login_for_email: noreply form carries its login without a lookup" || bad "login_for_email noreply"
[[ "$(agent_vendor_repo_slug "$REPO")" == "acme/widget" ]] && ok "repo_slug: derived from the GitHub origin URL" || bad "repo_slug '$(agent_vendor_repo_slug "$REPO")'"
# Commit-controlled email text is never interpolated into the search query:
# an operator-bearing address is rejected before gh is called (Codex round six).
INJ_EMAIL='x@y.test OR author:mrhinkle lane@gibson.test'
export GH_STUB_LOG="$ROOT/gh-calls.log"; : > "$GH_STUB_LOG"
[[ -z "$(agent_vendor_login_for_email acme/widget "$INJ_EMAIL")" ]] && ok "login_for_email: an address with whitespace/operators proves nothing" || bad "injection resolved a login"
[[ ! -s "$GH_STUB_LOG" ]] && ok "login_for_email: the injected address never reached gh (zero calls)" || bad "gh was called with: $(cat "$GH_STUB_LOG")"
[[ -z "$(agent_vendor_login_for_email acme/widget 'a"b@gibson.test')" && -z "$(agent_vendor_login_for_email acme/widget 'lane@gibson.test author:mrhinkle')" ]] && ok "login_for_email: quotes and trailing qualifiers are rejected too" || bad "metacharacter address resolved"
[[ ! -s "$GH_STUB_LOG" ]] && ok "login_for_email: still zero gh calls" || bad "gh was called: $(cat "$GH_STUB_LOG")"
# The qualifier alone is not trusted: a hit whose returned commit carries a
# different email is not evidence (stub answers "<other>\tmrhinkle" for it).
cat > "$BIN/gh-liar" <<'LIAR'
#!/usr/bin/env bash
case "$*" in *search/commits*) printf 'someone-else@gibson.test\tmrhinkle\n'; exit 0 ;; esac
exit 1
LIAR
chmod +x "$BIN/gh-liar"
mkdir -p "$ROOT/liarbin" && cp "$BIN/gh-liar" "$ROOT/liarbin/gh"
[[ -z "$(PATH="$ROOT/liarbin:$PATH" AGENT_VENDOR_LOGIN_CACHE_FILE="$ROOT/liar-cache" agent_vendor_login_for_email acme/widget other@gibson.test)" ]] && ok "login_for_email: a search hit whose commit email differs from the query is not evidence" || bad "mismatched search hit was accepted"
git -C "$REPO" remote set-url origin https://gitlab.com/acme/widget.git
[[ -z "$(agent_vendor_repo_slug "$REPO")" ]] && ok "repo_slug: a GitLab origin yields no slug" || bad "gitlab slug '$(agent_vendor_repo_slug "$REPO")'"
git -C "$REPO" remote set-url origin https://github.com/acme/widget.git
[[ -z "$(GH_HOST=ghe.example.com agent_vendor_repo_slug "$REPO")" ]] && ok "repo_slug: github.com origin under GH_HOST=ghe.example.com yields no slug" || bad "GH_HOST mismatch slug"
git -C "$REPO" remote set-url origin https://ghe.example.com/acme/widget.git
[[ "$(GH_HOST=ghe.example.com agent_vendor_repo_slug "$REPO")" == "acme/widget" ]] && ok "repo_slug: an Enterprise origin matching GH_HOST yields its slug" || bad "GHE slug"
git -C "$REPO" remote set-url origin https://github.com/acme/widget.git
unset GH_STUB_LOG

echo "Agent-Vendor walk: a lane-bot author does not excuse a .invalid committer (mixed identity)"
setup_repo bot-invalid-committer
SHA=$(head_sha)
if [[ "$(git -C "$REPO" log -1 --format=%ae "$SHA")" == "$BOT_EMAIL" && "$(git -C "$REPO" log -1 --format=%ce "$SHA")" == "sensor@gibson.invalid" ]]; then ok "fixture: author is the lane bot, committer is .invalid"
else bad "fixture bug: identities $(git -C "$REPO" log -1 --format='%ae %ce' "$SHA")"; fi
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-bot-invalid.err"
if handoff_invoked; then bad "bot-invalid-committer: loop handed off a commit review-evidence rejects as committer no-login"
else ok "bot-invalid-committer: loop does not invoke the supervisor"; fi
if grep -q "$SHA invalid-email:sensor@gibson.invalid" "$REPO/gibson/journal.md"; then ok "bot-invalid-committer: journal names the .invalid committer"
else bad "bot-invalid-committer: journal reason: $([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent)"; fi

echo "Agent-Vendor walk: a lane-bot commit resolves by identity and is handed off without a trailer"
setup_repo bot
SHA=$(head_sha)
write_state "$BRANCH" "$SHA"
: > "$CALLS/devin.cmds"
run_loop "$ROOT/loop-bot.err"
if handoff_invoked; then ok "lane-bot authored range is handed off"
else bad "lane-bot range blocked (stderr=$(tr '\n' ' ' <"$ROOT/loop-bot.err") journal=$([[ -f $REPO/gibson/journal.md ]] && cat "$REPO/gibson/journal.md" || echo absent))"; fi

echo "Agent-Vendor walk: the same rule, as scripts/lib/agent-vendor.sh and prepush's cp_agent_vendor_walk"
# Probe return codes are data here, not failures: keep errexit off.
set +e
# shellcheck source=../lib/convention-probes.sh
. "$GIBSON/scripts/lib/convention-probes.sh"
# shellcheck source=../lib/agent-vendor.sh
. "$GIBSON/scripts/lib/agent-vendor.sh"
if [[ "$AGENT_VENDORS" == "claude codex grok devin" ]]; then ok "lib vendor list is the evaluator's four"
else bad "lib vendor list drifted: $AGENT_VENDORS"; fi
setup_repo unvendored
SHA=$(head_sha); BASE=$(base_sha)
out=$(agent_vendor_unresolved_shas "$REPO" "$BASE" "$SHA"); rc=$?
[[ "$rc" -eq 0 && "$out" == "$SHA no-trailer" ]] && ok "agent_vendor_unresolved_shas: readable range, one finding '<sha> no-trailer'" || bad "walk rc=$rc out='$out'"
out=$(agent_vendor_unresolved_shas "$REPO" "$BASE" "$BASE"); rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] && ok "agent_vendor_unresolved_shas: empty range is clean (the unsigned, .invalid base is outside it)" || bad "empty range rc=$rc out='$out'"
if agent_vendor_unresolved_shas "$REPO" "$BASE" deadbeef >/dev/null 2>&1; then bad "unreadable head must return 1"
else ok "agent_vendor_unresolved_shas: unreadable head returns 1 (caller fails closed)"; fi
setup_repo bot
why=$(agent_vendor_commit_problem "$REPO" "$(head_sha)" main)
[[ -z "$why" ]] && ok "listed lane-bot author+committer, no trailer → resolves (identity table at the base)" || bad "listed bot reason '$why'"
setup_repo fake-bot
why=$(agent_vendor_commit_problem "$REPO" "$(head_sha)" main)
[[ "$why" == "unlisted-login:aie-agent-lanes-fake[bot]" ]] && ok "lane-bot shape alone (aie-agent-lanes-fake[bot]) is not exempt: unlisted-login" || bad "fake bot reason '$why'"
[[ "$(agent_vendor_login_of_noreply "$BOT_EMAIL")" == "aie-agent-lanes-grok[bot]" ]] && ok "login parsed from <id>+login@users.noreply.github.com" || bad "login parse: $(agent_vendor_login_of_noreply "$BOT_EMAIL")"
ident=$(agent_vendor_identity "$REPO" main "aie-agent-lanes-grok[bot]"); rc=$?
[[ "$rc" -eq 0 && "${ident%%	*}" == "grok" ]] && ok "identity table: aie-agent-lanes-grok[bot] → vendor grok, unrestricted" || bad "identity grok rc=$rc '$ident'"
agent_vendor_identity "$REPO" main "aie-agent-lanes-fake[bot]" >/dev/null; rc=$?
[[ "$rc" -eq 1 ]] && ok "identity table: an unlisted login returns 1" || bad "identity fake rc=$rc"
setup_repo bot
# The working tree is never consulted: deleting the lane's copy changes nothing.
rm -f "$REPO/config/review-evidence.v1.json"
# shellcheck disable=SC2034  # resets the sourced lib's cache
AGENT_VENDOR_TABLE_FOR=""
why=$(agent_vendor_commit_problem "$REPO" "$(head_sha)" main)
[[ -z "$why" ]] && ok "identity table read at the base ref, not the working tree (deleted copy, still resolves)" || bad "working-tree deletion changed the verdict: '$why'"
git -C "$REPO" checkout -q -- config/review-evidence.v1.json
# A base with no table: nothing is exempt, and the reason says why.
git -C "$REPO" checkout -q -b notable main && git -C "$REPO" rm -q -r config && $GIT -C "$REPO" commit -q -m "no table" && git -C "$REPO" checkout -q main
why=$(agent_vendor_commit_problem "$REPO" "$(head_sha)" notable)
[[ "$why" == "identity-table-unreadable:aie-agent-lanes-grok[bot]" ]] && ok "no identity table at the base → identity-table-unreadable, fail closed" || bad "no-table reason was '$why'"
why=$(agent_vendor_commit_problem "$REPO" "$(head_sha)" refs/heads/does-not-exist)
[[ "$why" == "identity-table-unreadable:aie-agent-lanes-grok[bot]" ]] && ok "unresolvable base → identity-table-unreadable, fail closed" || bad "bad-base reason was '$why'"
# The table is projected only after the evaluator's own validateConfig accepted
# it whole (Codex round eight): a duplicate normalized login, or a malformed or
# duplicate authorCommits entry beside a matching SHA, rejects the entire table.
bad_table() { # branch node-mutation-expr — a base branch whose table is mutated
  git -C "$REPO" checkout -q -b "$1" main
  node -e 'const fs=require("fs");const p=process.argv[1];const c=JSON.parse(fs.readFileSync(p,"utf8"));const sha=process.argv[3];eval(process.argv[2]);fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n")' "$REPO/config/review-evidence.v1.json" "$2" "$3"
  $GIT -C "$REPO" commit -q -am "mutated table: $1" && git -C "$REPO" checkout -q main
}
setup_repo bot
BOT_SHA=$(head_sha)
bad_table dup-login 'c.identities.push({login:"MRHINKLE",appSlug:null,appId:null,vendor:"owner",roles:["author"]})' "$BOT_SHA"
why=$(agent_vendor_commit_problem "$REPO" "$BOT_SHA" dup-login)
[[ "$why" == "identity-table-invalid:aie-agent-lanes-grok[bot]" ]] && ok "duplicate case-normalized login in the base table → identity-table-invalid (nothing resolves)" || bad "dup-login reason '$why'"
setup_repo mini-bot
MINI_SHA=$(head_sha)
bad_table bad-allow 'const i=c.identities.find(x=>x.login==="aie-agent-lanes-mini[bot]");i.authorCommits=[sha,"not-a-sha"]' "$MINI_SHA"
why=$(agent_vendor_commit_problem "$REPO" "$MINI_SHA" bad-allow)
[[ "$why" == "identity-table-invalid:aie-agent-lanes-mini[bot]" ]] && ok "malformed authorCommits entry beside the matching SHA → identity-table-invalid" || bad "bad-allow reason '$why'"
bad_table dup-allow 'const i=c.identities.find(x=>x.login==="aie-agent-lanes-mini[bot]");i.authorCommits=[sha,sha]' "$MINI_SHA"
why=$(agent_vendor_commit_problem "$REPO" "$MINI_SHA" dup-allow)
[[ "$why" == "identity-table-invalid:aie-agent-lanes-mini[bot]" ]] && ok "duplicate authorCommits entry beside the matching SHA → identity-table-invalid" || bad "dup-allow reason '$why'"
bad_table good-allow 'const i=c.identities.find(x=>x.login==="aie-agent-lanes-mini[bot]");i.authorCommits=[sha]' "$MINI_SHA"
why=$(agent_vendor_commit_problem "$REPO" "$MINI_SHA" good-allow)
[[ -z "$why" ]] && ok "control: the same allowlist, valid, resolves the commit" || bad "good-allow reason '$why'"
# The same rejection on both callers: push the invalid table to the base the
# loop pins (origin main) and probe from the branch.
setup_repo bot
BOT_SHA=$(head_sha)
node -e 'const fs=require("fs");const p=process.argv[1];const c=JSON.parse(fs.readFileSync(p,"utf8"));c.identities.push({login:"MRHINKLE",appSlug:null,appId:null,vendor:"owner",roles:["author"]});fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n")' "$REPO/config/review-evidence.v1.json"
$GIT -C "$REPO" commit -q -am "invalid table on the base" && git -C "$REPO" push -q origin main
write_state "$BRANCH" "$BOT_SHA"
: > "$CALLS/devin.cmds"
rm -f "$REPO/gibson/journal.md"
run_loop "$ROOT/loop-invalid-table.err"
if handoff_invoked; then bad "invalid base table: loop handed off a commit the evaluator would reject with the whole config"
else ok "invalid base table: loop does not invoke the supervisor"; fi
grep -q "identity-table-invalid:aie-agent-lanes-grok\[bot\]" "$REPO/gibson/journal.md" && ok "invalid base table: journal says identity-table-invalid" || bad "invalid-table journal: $(cat "$REPO/gibson/journal.md" 2>/dev/null)"
git -C "$REPO" checkout -q "$BRANCH"
. "$GIBSON/scripts/lib/convention-probes.sh"
out=$(cd "$REPO" && cp_agent_vendor_walk main); rc=$?
[[ "$rc" -eq 3 && "$out" == *"identity-table-invalid:aie-agent-lanes-grok[bot]"* ]] && ok "invalid base table: pre-push probe reports identity-table-invalid (report-only here, undeclared)" || bad "invalid-table probe rc=$rc: $out"
git -C "$REPO" checkout -q main
# A governed target repository has no table of its own: the harness's copy is
# the fallback (loop.sh sets it), read only when the base has none.
why=$(AGENT_VENDOR_TABLE_FALLBACK="$GIBSON/config/review-evidence.v1.json" agent_vendor_commit_problem "$REPO" "$(head_sha)" notable)
[[ -z "$why" ]] && ok "no table at the base + harness fallback → resolves from the harness's table" || bad "fallback reason was '$why'"
why=$(AGENT_VENDOR_TABLE_FALLBACK="$ROOT/does-not-exist.json" agent_vendor_commit_problem "$REPO" "$(head_sha)" notable)
[[ "$why" == "identity-table-unreadable:aie-agent-lanes-grok[bot]" ]] && ok "an unreadable fallback is still fail closed" || bad "bad-fallback reason was '$why'"
# Probe: run from inside the lane branch, undeclared → 3 (report only), declared → 1, fixed → 0, bad base → 2.
setup_repo unvendored
SHA=$(head_sha)
git -C "$REPO" checkout -q "$BRANCH"
out=$(cd "$REPO" && cp_agent_vendor_walk main); rc=$?
[[ "$rc" -eq 3 && "$out" == *"$SHA no-trailer"* && "$out" == *"fix: "* && "$out" == *"report only"* ]] && ok "cp_agent_vendor_walk: undeclared checkout → 3 with SHA, reason, fix" || bad "probe undeclared rc=$rc: $out"
# A --local-only value is not a declaration (the hooks read worktree scope only,
# gated on extensions.worktreeConfig): still report-only.
git -C "$REPO" config gibson.agentVendor claude
out=$(cd "$REPO" && cp_agent_vendor_walk main); rc=$?
[[ "$rc" -eq 3 ]] && ok "cp_agent_vendor_walk: --local-only gibson.agentVendor is not a declaration → still 3" || bad "probe local-only rc=$rc: $out"
git -C "$REPO" config --unset gibson.agentVendor
git -C "$REPO" config extensions.worktreeConfig true
git -C "$REPO" config --worktree gibson.agentVendor claude
[[ "$(agent_vendor_declared "$REPO")" == "claude" ]] && ok "agent_vendor_declared: worktree scope + extension on → claude" || bad "agent_vendor_declared read '$(agent_vendor_declared "$REPO")'"
out=$(cd "$REPO" && cp_agent_vendor_walk main); rc=$?
[[ "$rc" -eq 1 && "$out" == *"$SHA no-trailer"* ]] && ok "cp_agent_vendor_walk: declared lane (worktree scope, extension on) → 1" || bad "probe declared rc=$rc: $out"
git -C "$REPO" config --worktree --unset gibson.agentVendor
git -C "$REPO" config --unset extensions.worktreeConfig
out=$(cd "$REPO" && cp_agent_vendor_walk refs/heads/nope); rc=$?
[[ "$rc" -eq 2 ]] && ok "cp_agent_vendor_walk: unresolvable base → 2 (cannot run), never a pass" || bad "probe bad base rc=$rc: $out"
setup_repo signed
git -C "$REPO" checkout -q "$BRANCH"
out=$(cd "$REPO" && cp_agent_vendor_walk main); rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] && ok "cp_agent_vendor_walk: one known trailer under a resolvable email → 0" || bad "probe clean rc=$rc: $out"
git -C "$REPO" checkout -q main

echo
echo "dco-handoff.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
