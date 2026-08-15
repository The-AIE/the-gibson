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
if echo "$help_out" | grep -q 'WHAT IT DOES' && echo "$help_out" | grep -q 'RISKS'; then
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
if grep -c -iE '^Signed-off-by:[[:space:]]+' "$msg" | grep -qx 1; then
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

echo
echo "setup-hooks.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
