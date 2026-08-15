#!/usr/bin/env bash
# dco-handoff.test.sh — sensors for Signed-off-by refusal on handoff (issue #204)
#
# WHY
#   CI must not be the first thing that notices an unsigned commit. Supervisor
#   handoff (including --dry-run) and the loop handoff path refuse any commit
#   in the handed-off range that lacks a Signed-off-by trailer. The *base*
#   commit is outside that range and is left unsigned on purpose.
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
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/curl" "$BIN/gh"
PATH="$BIN:$PATH"
export PATH

GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

# base stays unsigned on purpose; work commits are signed or not per caller.
setup_repo() { # setup_repo <signed|unsigned>
  local mode="${1:-signed}"
  rm -rf "$REPO" "$REMOTE"
  mkdir -p "$REPO"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  echo base > "$REPO/README.md"
  $GIT -C "$REPO" add README.md
  $GIT -C "$REPO" commit -q -m "base"
  $GIT -C "$REPO" checkout -q -b "$BRANCH"
  echo work >> "$REPO/README.md"
  if [[ "$mode" == "signed" ]]; then
    $GIT -C "$REPO" commit -q -s -am "work"
  else
    $GIT -C "$REPO" commit -q -am "work"
  fi
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
if git -C "$REPO" log -1 --format=%B "$BASE" | grep -qiE '^Signed-off-by:[[:space:]]+'; then
  bad "fixture bug: base commit must stay unsigned"
else
  ok "fixture: base commit is unsigned (range-only check)"
fi
if git -C "$REPO" log -1 --format=%B "$SHA" | grep -qiE '^Signed-off-by:[[:space:]]+'; then
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
if git -C "$REPO" log -1 --format=%B "$BASE" | grep -qiE '^Signed-off-by:[[:space:]]+'; then
  bad "fixture bug: signed-range case must keep the base unsigned"
else
  ok "fixture: signed-range base is still unsigned"
fi
if git -C "$REPO" log -1 --format=%B "$SHA" | grep -qiE '^Signed-off-by:[[:space:]]+'; then
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

echo
echo "dco-handoff.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
