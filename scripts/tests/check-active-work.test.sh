#!/usr/bin/env bash
# check-active-work.test.sh — sensors for the claim-isolation gate (docs/05, issue #55)
#
# WHY
#   Two failure modes, both of which made the sensor useless in opposite
#   directions. It swallowed unresolved refs, so under the shipped shallow
#   checkout it printed "no changed files" and passed every PR. And when it did
#   see a diff it read the working tree, so a lane appending its own claim row —
#   the normal Law 2 operation — looked exactly like a lane stamping on someone
#   else's. These cases pin both directions: append is allowed, editing a
#   pre-existing live claim is not, and a diff the sensor cannot compute is an
#   error rather than a pass.
#
# USAGE
#   scripts/tests/check-active-work.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
SENSOR="$SCRIPT_DIR/../check-active-work.mjs"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "check-active-work.test.sh: node is required"; exit 1; }
command -v git  >/dev/null || { echo "check-active-work.test.sh: git is required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-claim-sensor.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"
REPO="$ROOT/repo"

BASE_TABLE='| UTC | claim | scope | session |
|---|---|---|---|
| 2026-08-01T10:00:00Z | issue-7-password-reset | app/api/auth/** | grok@fleet-2 |'

BASE_CLAIM='claim: issue-7-password-reset
issue: 7
claimed: 2026-08-01T10:00:00Z
scope: app/api/auth/**
session: grok@fleet-2
branch: feat/7-password-reset
worktree: /Code/wt-7-password-reset'

# A repo whose main carries one live claim in both ledger forms, and a lane
# branch checked out on top of it for the case to mutate.
setup_repo() {
  rm -rf "$REPO"
  mkdir -p "$REPO/docs/claims"
  $GIT init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  printf '%s\n' "$BASE_TABLE" > "$REPO/docs/active-work.md"
  printf '%s\n' "$BASE_CLAIM" > "$REPO/docs/claims/issue-7-password-reset.md"
  echo hello > "$REPO/README.md"
  $GIT -C "$REPO" add -A
  $GIT -C "$REPO" commit -q -m "base ledger"
  $GIT -C "$REPO" checkout -q -b lane
}

commit_lane() { $GIT -C "$REPO" add -A && $GIT -C "$REPO" commit -q -m "lane change"; }

# run_sensor <expect-rc> <head-ref> <base-ref> <description> [grep-for]
run_sensor() {
  local want="$1" head="$2" base="$3" desc="$4" needle="${5:-}"
  local out rc
  out=$(cd "$REPO" && GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF="$base" \
        GITHUB_HEAD_REF="$head" node "$SENSOR" 2>&1)
  rc=$?
  if [[ "$rc" -ne "$want" ]]; then
    bad "$desc (want rc=$want, got $rc: $out)"
    return
  fi
  if [[ -n "$needle" ]] && ! grep -qi -- "$needle" <<< "$out"; then
    bad "$desc (rc ok but message missing '$needle': $out)"
    return
  fi
  ok "$desc"
}

echo "the normal Law 2 operation is allowed"
setup_repo
printf '| 2026-08-02T09:00:00Z | issue-9-checkout | app/checkout/** | claude@fleet-1 |\n' \
  >> "$REPO/docs/active-work.md"
commit_lane
run_sensor 0 lane main "appending a new claim row passes" "allowed"

setup_repo
cat > "$REPO/docs/claims/issue-9-checkout.md" <<'CLAIM'
claim: issue-9-checkout
issue: 9
scope: app/checkout/**
session: claude@fleet-1
branch: lane
CLAIM
commit_lane
run_sensor 0 lane main "adding a new claim file passes" "new on this branch"

setup_repo
echo change > "$REPO/README.md"
commit_lane
run_sensor 0 lane main "a PR that touches no ledger file passes" "does not touch the claim ledger"

echo "editing someone else's live claim is refused"
setup_repo
sed 's|grok@fleet-2|claude@fleet-1|' "$REPO/docs/active-work.md" > "$REPO/docs/active-work.md.tmp"
mv "$REPO/docs/active-work.md.tmp" "$REPO/docs/active-work.md"
commit_lane
run_sensor 1 lane main "modifying a pre-existing legacy row fails" "modifies pre-existing claim row"

setup_repo
grep -v 'issue-7-password-reset' "$REPO/docs/active-work.md" > "$REPO/docs/active-work.md.tmp"
mv "$REPO/docs/active-work.md.tmp" "$REPO/docs/active-work.md"
commit_lane
run_sensor 1 lane main "removing a pre-existing legacy row fails" "removes pre-existing claim row"

setup_repo
printf '| 2026-08-02T09:00:00Z | issue-9-checkout | app/checkout/** | claude@fleet-1 |\n' \
  >> "$REPO/docs/active-work.md"
sed 's|grok@fleet-2|claude@fleet-1|' "$REPO/docs/active-work.md" > "$REPO/docs/active-work.md.tmp"
mv "$REPO/docs/active-work.md.tmp" "$REPO/docs/active-work.md"
commit_lane
run_sensor 1 lane main "appending alongside a rewritten row still fails" "modifies pre-existing claim row"

setup_repo
echo "scope: everything" >> "$REPO/docs/claims/issue-7-password-reset.md"
commit_lane
run_sensor 1 lane main "modifying another lane's claim file fails" "modifies live claim file"

setup_repo
rm "$REPO/docs/claims/issue-7-password-reset.md"
commit_lane
run_sensor 1 lane main "deleting another lane's claim file fails" "deletes live claim file"

echo "a rename cannot smuggle the deletion past the gate"
# Git's rename detection reports a rename as the DESTINATION path only. Without
# --no-renames the source deletion never appears in the changed-file list, so
# each of these three moves reads as "a brand new claim file — allowed (Law 2)"
# while a live claim quietly disappears from the ledger.
setup_repo
$GIT -C "$REPO" mv docs/claims/issue-7-password-reset.md docs/claims/issue-9-checkout.md
commit_lane
run_sensor 1 lane main "renaming another lane's claim to a different claim id fails" "deletes live claim file"

setup_repo
mkdir -p "$REPO/docs/archive"
$GIT -C "$REPO" mv docs/claims/issue-7-password-reset.md docs/archive/issue-7-password-reset.md
commit_lane
run_sensor 1 lane main "renaming another lane's claim out of docs/claims fails" "deletes live claim file"

# Same move, from the branch the claim itself names. The ownership exemption must
# not reach it: a rename is a deletion of the claim at its ledger path.
setup_repo
$GIT -C "$REPO" mv docs/claims/issue-7-password-reset.md docs/claims/issue-7-password-reset-v2.md
commit_lane
run_sensor 1 feat/7-password-reset main "even the owning branch cannot rename its own claim away" "deletes live claim file"

echo "the owning lane may renew its own claim but never delete it"
setup_repo
echo "notes: renewed" >> "$REPO/docs/claims/issue-7-password-reset.md"
commit_lane
run_sensor 0 feat/7-password-reset main "the branch named in the claim owns it" "owned by this PR's branch"

# Renewal is the point of the exemption — refreshing the timestamp so
# claims-status.sh stops calling the lane STALE must stay a green PR.
setup_repo
sed 's|^claimed: .*|claimed: 2026-08-02T11:00:00Z|' "$REPO/docs/claims/issue-7-password-reset.md" \
  > "$REPO/docs/claims/issue-7-password-reset.md.tmp"
mv "$REPO/docs/claims/issue-7-password-reset.md.tmp" "$REPO/docs/claims/issue-7-password-reset.md"
commit_lane
run_sensor 0 feat/7-password-reset main "the owning branch may renew its own claim timestamp" "owned by this PR's branch"

# The rule the ordering exists for: deletion is checked before ownership, so the
# lane that owns the claim still cannot release it through a PR. Doctrine puts
# release on main (scripts/release-claim.sh, docs/05); a PR-side delete would
# retire the claim on merge and hide it from overlap checks before then.
setup_repo
rm "$REPO/docs/claims/issue-7-password-reset.md"
commit_lane
run_sensor 1 feat/7-password-reset main "the owning branch cannot delete its own claim" "release-claim.sh"

echo "a claim file present in the tree but unreadable is an error, never a classification"
# The sensor used to read claim content with `git show`, allowFail: true, and map
# EVERY failure to null — the same value it uses for "this path is not in that
# commit". A blob it cannot read then silently becomes an absence: on the base
# side "new on this branch — allowed (Law 2)", on the head side a deletion
# pinned on a lane that deleted nothing. The fixture removes the loose object
# behind a path that is still listed in the commit's tree, which is what a
# pruned object, a partial clone, or a corrupt objects/ directory looks like from
# here — the tree entry is intact, the content is gone.
blob_object_path() { # blob_object_path <ref> <path>
  local oid
  oid=$(git -C "$REPO" rev-parse "$1:$2") || return 1
  printf '%s\n' "$REPO/.git/objects/${oid:0:2}/${oid:2}"
}

setup_repo
echo "notes: renewed" >> "$REPO/docs/claims/issue-7-password-reset.md"
commit_lane
BASE_BLOB=$(blob_object_path main docs/claims/issue-7-password-reset.md)
rm -f "$BASE_BLOB"
if [[ -n "$(git -C "$REPO" ls-tree main -- docs/claims/issue-7-password-reset.md)" ]] &&
   ! git -C "$REPO" show main:docs/claims/issue-7-password-reset.md >/dev/null 2>&1; then
  ok "fixture: the base still lists the claim path but its blob is unreadable"
else
  bad "fixture bug: the base blob is either still readable or gone from the tree"
fi
out=$(cd "$REPO" && GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main \
      GITHUB_HEAD_REF=lane node "$SENSOR" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]]; then
  bad "an unreadable base-side claim blob must not pass (rc=0: $out)"
elif grep -qi "new on this branch" <<< "$out"; then
  bad "an unreadable base-side claim blob was classified as a new file (rc=$rc: $out)"
elif grep -qi "git show" <<< "$out"; then
  ok "an unreadable base-side claim blob dies loudly naming the failed read"
else
  bad "the failure did not name the unreadable read (rc=$rc: $out)"
fi

# The head side of the same confusion: here the base copy reads fine and it is
# the branch's own blob that cannot be read. Absence on this side means deletion,
# so the pre-fix sensor accused the lane of deleting a live claim — non-zero for
# a reason that never happened, which sends the lane chasing a delete it did not
# make. Assert the read failure, not merely the exit code.
setup_repo
echo "notes: renewed" >> "$REPO/docs/claims/issue-7-password-reset.md"
commit_lane
HEAD_BLOB=$(blob_object_path lane docs/claims/issue-7-password-reset.md)
rm -f "$HEAD_BLOB"
if [[ -n "$(git -C "$REPO" ls-tree lane -- docs/claims/issue-7-password-reset.md)" ]] &&
   git -C "$REPO" show main:docs/claims/issue-7-password-reset.md >/dev/null 2>&1 &&
   ! git -C "$REPO" show lane:docs/claims/issue-7-password-reset.md >/dev/null 2>&1; then
  ok "fixture: the head lists the claim path, the base blob reads, the head blob does not"
else
  bad "fixture bug: the head-side unreadable-blob fixture is not in the expected state"
fi
out=$(cd "$REPO" && GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main \
      GITHUB_HEAD_REF=lane node "$SENSOR" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]]; then
  bad "an unreadable head-side claim blob must not pass (rc=0: $out)"
elif grep -qi "deletes live claim file" <<< "$out"; then
  bad "an unreadable head-side claim blob was reported as a deletion (rc=$rc: $out)"
elif grep -qi "git show" <<< "$out"; then
  ok "an unreadable head-side claim blob dies loudly instead of alleging a deletion"
else
  bad "the failure did not name the unreadable read (rc=$rc: $out)"
fi

echo "a diff the sensor cannot compute is an error, never a pass"
setup_repo
echo change > "$REPO/README.md"
commit_lane
run_sensor 1 lane nonexistent-base "an unresolvable base ref fails loudly" "cannot resolve the base ref"

# The regression this pins is the old success line, not the word "no changed
# files" — the refusal message quotes that phrase precisely to say it is NOT
# claiming it, so a broad grep would flag the correct behaviour. Match only the
# pre-fix pass claim; the case above already pins rc and the refusal message.
out=$(cd "$REPO" && GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=nonexistent-base \
      GITHUB_HEAD_REF=lane node "$SENSOR" 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]] || grep -qi -- "no changed files detected" <<< "$out"; then
  bad "an unresolvable base must not report 'no changed files' (rc=$rc: $out)"
else
  ok "an unresolvable base never claims the diff was empty"
fi

# The real CI failure mode: actions/checkout's default shallow fetch leaves the
# base branch entirely absent from the clone.
SHALLOW="$ROOT/shallow"
rm -rf "$SHALLOW"
if git clone -q --depth 1 --single-branch --branch lane "file://$REPO" "$SHALLOW" 2>/dev/null; then
  out=$(cd "$SHALLOW" && GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main \
        GITHUB_HEAD_REF=lane node "$SENSOR" 2>&1)
  rc=$?
  if [[ "$rc" -ne 0 ]] && grep -qi "cannot resolve the base ref" <<< "$out"; then
    ok "a shallow single-branch checkout fails loudly instead of passing"
  else
    bad "shallow checkout did not fail loudly (rc=$rc: $out)"
  fi
else
  bad "could not build the shallow clone fixture"
fi

echo "non-pull_request events are still skipped"
out=$(cd "$REPO" && GITHUB_EVENT_NAME=push node "$SENSOR" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -qi "skipping" <<< "$out"; then
  ok "a push event skips the sensor"
else
  bad "a push event did not skip (rc=$rc: $out)"
fi

echo
echo "check-active-work.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
