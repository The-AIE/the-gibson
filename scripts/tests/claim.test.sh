#!/usr/bin/env bash
# claim.test.sh — sensors for the claim contract (L-023 / L-024 / L-028 / L-009)
#
# WHAT IT DOES
#   Builds throwaway git repos and a fake `gh`, then asserts what claim.sh must
#   refuse and what it must allow. No network, no GitHub.
#
# WHY
#   Every rule here exists because it was broken in production: a duplicate build
#   on an already-claimed issue (L-028), a ledger conflict blocking an unrelated
#   green PR (L-023), and a claim that moved the caller's checkout out from under
#   them (L-009).
#
# USAGE
#   scripts/tests/claim.test.sh
set -uo pipefail

# Hermetic git identity (#101): suites that commit must not read ambient global
# user.name/email. Pass with HOME pointed at an empty directory.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"


SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
CLAIM="$SCRIPT_DIR/../claim.sh"
PASS=0
FAIL=0
ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-claim-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Fake gh: records label edits, reports whatever labels the fixture set.
BIN="$ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") cat "${GH_LABELS_FILE:-/dev/null}" 2>/dev/null || echo "" ;;
  "issue edit") echo "$*" >> "${GH_LOG:-/dev/null}" ;;
  "api graphql")
    # pr-claims.sh's paginated GraphQL read. `list` restricts the query to
    # `states: [OPEN]` and wants 7 fields; `find-terminal` walks every state
    # and wants 13, including the exact head SHA that release-claim.sh's
    # cleanup proof is anchored to. Closed PRs move to GH_PR_FILE.closed, so
    # this fixture models the real lifecycle: a released claim leaves the
    # open listing and becomes terminal evidence in the same breath.
    #
    # `list-open-numbers` is a third query (#153 review round 4): every open PR
    # number, body-agnostic. It is matched FIRST because its query also
    # carries `states: [OPEN]`. GH_PR_ORPHANS models a PR that exists on the
    # server but is not (yet) in the published claim listing.
    want_numbers=0
    for a in "$@"; do
      case "$a" in *"openPrNumbers"*) want_numbers=1 ;; esac
    done
    if [[ "$want_numbers" -eq 1 ]]; then
      cut -d'|' -f1 "${GH_PR_FILE:-/dev/null}" 2>/dev/null | grep -E '^[0-9]+$' || true
      [[ -z "${GH_PR_ORPHANS:-}" ]] ||
        cut -d'|' -f1 "$GH_PR_ORPHANS" 2>/dev/null | grep -E '^[0-9]+$' || true
      exit 0
    fi
    want_open=0
    for a in "$@"; do
      case "$a" in *"states: [OPEN]"*) want_open=1 ;; esac
    done
    if [[ "$want_open" -eq 1 ]]; then
      while IFS='|' read -r number claim scope branch url created updated cross; do
        [[ -n "$claim" ]] || continue
        # Column 8 is the PR's repository identity (#153 review round 5). The
        # fixture store keeps it in the record so a test can stage a FORK row
        # by writing `true`; anything the store leaves blank is this
        # repository's own PR, which is what claim.sh creates.
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$number" "$claim" "$scope" "$branch" "$url" "$created" "$updated" \
          "${cross:-false}"
      done < "${GH_PR_FILE:-/dev/null}"
    else
      # find-terminal-pr narrows the real query with `select(.number == N)`.
      # This fake hands back TSV instead of running jq, so it has to honour
      # that narrowing itself — otherwise a reused claim id (two terminal
      # generations) would look ambiguous here no matter what was asked.
      want_num=""
      for a in "$@"; do
        case "$a" in
          *"select(.number == "*)
            want_num=$(printf '%s' "$a" | sed -n 's/.*select(\.number == \([0-9][0-9]*\)).*/\1/p' | head -1)
            ;;
        esac
      done
      while IFS='|' read -r number claim scope branch url created updated cross; do
        [[ -n "$claim" ]] || continue
        [[ -z "$want_num" || "$number" == "$want_num" ]] || continue
        rest="${claim#issue-}"
        issue="${rest%%-*}"
        headsha=$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
        # CLOSED, so the merge-commit column is empty by contract.
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$number" "$claim" "$scope" "$issue" "$branch" "$headsha" "$url" \
          "CLOSED" "${cross:-false}" "" "acme/app" "$created" "$updated"
      done < "${GH_PR_FILE}.closed" 2>/dev/null
    fi
    ;;
  "pr create")
    [[ "${GH_FAIL_PR_CREATE:-0}" == 1 ]] && exit 1
    body_file=""
    branch=""
    if [[ "${GH_PR_CREATE_ORPHAN:-0}" == 1 ]]; then
      # The eventually-consistent failure this models (#153 review round 4):
      # GitHub CREATES the pull request and then the response — or the network
      # carrying it — dies. The client sees a nonzero exit and no PR number,
      # while the PR is real, open, and holding the claim. The live listing is
      # eventually consistent, so it does not show the row yet either: the row
      # goes to GH_PR_ORPHANS (visible to the body-agnostic open-PR inventory,
      # which is what a real server would report) and NOT to GH_PR_FILE.
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --body-file) body_file="$2"; shift 2 ;;
          --head) branch="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      counter="${GH_PR_FILE}.next"
      number=$(cat "$counter" 2>/dev/null || echo "${GH_PR_NEXT:-1}")
      echo $((number + 1)) > "$counter"
      claim=$(sed -n 's/^- Active-work claim: //p' "$body_file")
      scope=$(sed -n 's/^- Claim scope: //p' "$body_file")
      printf '%s|%s|%s|%s|https://github.com/acme/app/pull/%s|2026-08-04T00:00:00Z|2026-08-04T00:00:00Z\n' \
        "$number" "$claim" "$scope" "$branch" "$number" >> "${GH_PR_ORPHANS:-/dev/null}"
      exit 1
    fi
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --body-file) body_file="$2"; shift 2 ;;
        --head) branch="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # The counter has to live in a FILE: each claim.sh run is a new process
    # tree, so an exported variable resets to 1 every time and two generations
    # of a reused claim id would both be "PR #1" — which is not a thing GitHub
    # can produce, and would hide the very ambiguity this fixture is about.
    counter="${GH_PR_FILE}.next"
    number=$(cat "$counter" 2>/dev/null || echo "${GH_PR_NEXT:-1}")
    echo $((number + 1)) > "$counter"
    claim=$(sed -n 's/^- Active-work claim: //p' "$body_file")
    scope=$(sed -n 's/^- Claim scope: //p' "$body_file")
    # 8th field: the PR's repository identity, so a fixture can stage a FORK
    # row for this lane's own claim id (#153 review round 5).
    printf '%s|%s|%s|%s|https://github.com/acme/app/pull/%s|2026-08-04T00:00:00Z|2026-08-04T00:00:00Z|%s\n' \
      "$number" "$claim" "$scope" "$branch" "$number" "${GH_PR_CROSS:-false}" \
      >> "${GH_PR_FILE:-/dev/null}"
    cat "$body_file" > "${GH_PR_FILE}.body"
    echo "https://github.com/acme/app/pull/$number"
    ;;
  "pr close")
    number="$3"
    tmp="${GH_PR_FILE}.tmp"
    : > "$tmp"
    while IFS='|' read -r pr_number rest; do
      if [[ "$pr_number" == "$number" ]]; then
        # Closing does not delete the PR — it becomes terminal evidence.
        printf '%s|%s\n' "$pr_number" "$rest" >> "${GH_PR_FILE}.closed"
      else
        printf '%s|%s\n' "$pr_number" "$rest" >> "$tmp"
      fi
    done < "${GH_PR_FILE:-/dev/null}"
    mv "$tmp" "$GH_PR_FILE"
    ;;
  *)
    # Loud and bounded (#153 review round 5). Never fall through to a silent
    # success, and never read stdin — an unmodelled query is a fixture gap.
    echo "fake gh (claim fixture): unmodelled invocation 'gh $*' — refusing rather than answering a query this fixture does not model" >&2
    exit 64
    ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

# HOSTILE `sleep` sentinel (#153 review rounds 4 + 6, P1/P3).
#
# The publication barrier used to space its reads with `execFileSync("sleep")`
# — an executable resolved through PATH, which meant anyone able to prepend a
# directory to PATH could collapse the barrier to back-to-back samples taken
# in the same instant. That is not a test seam; it is an execution path chosen
# by the environment. Production now blocks on an internal wait with no name
# to interpose on.
#
# So this `sleep` is no longer a helpful shim. It is a TRIPWIRE that records
# every PATH-resolved invocation for the whole suite lifetime. Assertions at
# the end require it to stay empty — and they must NOT erase earlier hits
# first (round 6). Concurrency fixtures pause via absolute /bin/sleep so their
# ready-file rendezvous does not pollute this receipt. Every later fixture
# prepends its own bin to $PATH, which still contains this one.
export SLEEP_SENTINEL="$ROOT/sleep-sentinel"
rm -f "$SLEEP_SENTINEL"
cat > "$BIN/sleep" <<'SLEEP'
#!/usr/bin/env bash
echo "sleep $*" >> "${SLEEP_SENTINEL:-/dev/null}"
exit 0
SLEEP
chmod +x "$BIN/sleep"
export PATH="$BIN:$PATH"
export GIBSON_SESSION="tester@box"

# --- the patched TEST-COPY toolchain (#153 review round 4, P1) --------------
# Production's read spacing cannot be accelerated from outside any more — by
# design. But these are BROAD fixtures: dozens of claim runs whose subject is
# the claim contract, not the timing, and paying the real barrier in each of
# them would add minutes to the suite while proving nothing the focused
# barrier sensors (scope-overlap.test.sh, and the real-production run below)
# do not already prove.
#
# So the broad fixtures run an explicitly patched COPY of the whole toolchain.
# claim.sh resolves scope-overlap.mjs, pr-claims.sh and lib/claim-guards.sh
# from its OWN directory, so the copy has to be a complete one; the only edit
# is a single surgical substitution that removes the blocking call from
# spaceReads and nothing else. Everything the barrier REQUIRES — consecutive
# matching reads that all contain this lane's own claim, the floor, the
# safe-integer bounds — is the production code path.
#
# The substitution is VERIFIED, so if production stops looking like this the
# suite fails loudly here instead of quietly testing something else.
PRODUCTION_CLAIM="$CLAIM"
FASTDIR="$ROOT/scripts-fast"
mkdir -p "$FASTDIR/lib"
cp "$SCRIPT_DIR/../claim.sh"            "$FASTDIR/claim.sh"
cp "$SCRIPT_DIR/../pr-claims.sh"        "$FASTDIR/pr-claims.sh"
cp "$SCRIPT_DIR/../lib/claim-guards.sh" "$FASTDIR/lib/claim-guards.sh"
# The marked region is the wait AND the monotonic measurement that verifies
# it (#153 review round 5) — both have to go, because spaceReads now refuses
# unless the measured elapsed time reaches the configured delay, so removing
# only the blocking call would make every fast fixture fail the barrier rather
# than skip it.
awk '
  /GIBSON_BARRIER_WAIT_BEGIN/ { print "  return ms;  /* TEST COPY: blocking removed */"; skip = 1; next }
  /GIBSON_BARRIER_WAIT_END/   { skip = 0; next }
  !skip                       { print }
' "$SCRIPT_DIR/../scope-overlap.mjs" > "$FASTDIR/scope-overlap.mjs"
chmod +x "$FASTDIR/claim.sh" "$FASTDIR/pr-claims.sh"
if grep -q 'TEST COPY: blocking removed' "$FASTDIR/scope-overlap.mjs" &&
   ! grep -q 'Atomics\.wait(cell' "$FASTDIR/scope-overlap.mjs" &&
   ! grep -q 'hrtime\.bigint(' "$FASTDIR/scope-overlap.mjs" &&
   node --check "$FASTDIR/scope-overlap.mjs" 2>/dev/null; then
  ok "the test copy patched out exactly the blocking wait (production shape unchanged)"
else
  bad "could not patch the test copy — production spaceReads no longer matches the expected shape; refusing to pretend these fixtures exercise the barrier"
fi
CLAIM="$FASTDIR/claim.sh"

new_repo() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root"
  export GH_PR_FILE="$root/prs"
  : > "$GH_PR_FILE"
  : > "${GH_PR_FILE}.closed"   # terminal (closed) PR evidence for this fixture
  echo 1 > "${GH_PR_FILE}.next"  # monotonic PR numbers, persisted across runs
  export GH_PR_NEXT=1
  git init -q --bare "$root/origin"
  git clone -q "$root/origin" "$root/canon" 2>/dev/null
  # Real GitHub repository identity on origin (the fake gh reports acme/app),
  # rewritten to the throwaway bare repo for transport. release-claim.sh
  # requires the checkout's own origin to BE the repository whose PR-body
  # evidence drives cleanup (#153 review P1), so the fixture has to carry the
  # identity a real clone carries instead of a bare local path.
  git -C "$root/canon" config "url.$root/origin.insteadOf" https://github.com/acme/app.git
  git -C "$root/canon" remote set-url origin https://github.com/acme/app.git
  (
    cd "$root/canon" || exit 1
    mkdir -p docs/claims
    printf '| when | claim-id | scope | who |\n|---|---|---|---|\n' > docs/active-work.md
    git add -A && git commit -qm init && git branch -M main && git push -q -u origin main
  ) >/dev/null 2>&1
}

add_claim() { # repo-root claim-id scope
  (
    cd "$1/canon" || exit 1
    git checkout -q main
    mkdir -p docs/claims
    printf 'claim: %s\nissue: x\nclaimed: 2026-08-01T00:00:00Z\nscope: %s\nsession: other\n' "$2" "$3" \
      > "docs/claims/$2.md"
    git add -A && git commit -qm "claim $2" && git push -q origin main
  ) >/dev/null 2>&1
}

echo "L-023 · a claim is one file, so two lanes never conflict on the ledger"
new_repo "$ROOT/a"
out=$(cd "$ROOT/a/canon" && "$CLAIM" 42 password-reset 'app/api/auth/**' 2>&1); rc=$?
check "claim succeeds" "$rc" "0"
files=$(cd "$ROOT/a/canon" && git fetch -q origin && git ls-tree --name-only origin/main docs/claims/)
lacks "does not write a ledger claim file under docs/claims" "$files" "issue-42"
contains "creates a PR-body claim" "$(cat "$GH_PR_FILE")" "issue-42-password-reset"
body=$(cat "$GH_PR_FILE")
contains "records the scope"   "$body" "app/api/auth/**"
contains "records the session" "$(cat "${GH_PR_FILE}.body")" "- Session: tester@box"
table=$(cd "$ROOT/a/canon" && git show origin/main:docs/active-work.md)
lacks "does not append to the shared table" "$table" "issue-42"
head_before=$(cd "$ROOT/a/canon" && git rev-parse origin/main)
git -C "$ROOT/a/canon" fetch -q origin
head_after=$(cd "$ROOT/a/canon" && git rev-parse origin/main)
check "claim never mutates default branch" "$head_after" "$head_before"

echo "release then reclaim removes the PR claim's worktree and branch"
out=$(cd "$ROOT/a/canon" && "$SCRIPT_DIR/../release-claim.sh" 42 --repo acme/app 2>&1)
rc=$?
check "PR-body release succeeds" "$rc" "0"
test ! -e "$ROOT/a/wt-42-password-reset" &&
  ok "release removes the PR claim worktree" ||
  bad "release removes the PR claim worktree"
test ! -e "$ROOT/a/canon/.git/refs/heads/feat/42-password-reset" &&
  ok "release removes the local PR claim branch" ||
  bad "release removes the local PR claim branch"
out=$(cd "$ROOT/a/canon" && "$CLAIM" 42 password-reset 'app/api/auth/**' 2>&1)
rc=$?
check "same claim can be reclaimed after release" "$rc" "0"

echo "#153 · a reclaimed claim id survives a SECOND full release (two generations)"
# The contradiction this closes: reuse of a released claim id was permitted at
# claim time, but the second generation could never be released — two terminal
# PRs then carry the same id, and the id-only terminal lookup is ambiguous by
# design (and must stay that way). The fix binds close/release to the PR
# number the release path already knows.
gen2_pr=$(cut -d'|' -f1 "$GH_PR_FILE" | tail -1)
[[ "$gen2_pr" =~ ^[0-9]+$ ]] && ok "generation 2 opened its own PR (#$gen2_pr)" \
  || bad "generation 2 PR number unreadable: '$gen2_pr'"
[[ -d "$ROOT/a/wt-42-password-reset" ]] &&
  ok "generation 2 re-created the worktree" || bad "generation 2 worktree missing"
# Both generations now exist as evidence: generation 1 is already terminal.
gen_closed=$(grep -c 'issue-42-password-reset' "${GH_PR_FILE}.closed" || true)
check "generation 1 is terminal evidence for the same claim id" "$gen_closed" "1"
out=$(cd "$ROOT/a/canon" && "$SCRIPT_DIR/../release-claim.sh" 42 --repo acme/app 2>&1)
rc=$?
check    "second-generation release exits 0"     "$rc" "0"
contains "second-generation release closed its own PR" "$out" "closing PR #$gen2_pr"
lacks    "second-generation release never reports ambiguity" "$out" "ambiguous"
test ! -e "$ROOT/a/wt-42-password-reset" &&
  ok "second-generation release removed the worktree" ||
  bad "second-generation release left the worktree"
test -z "$(git -C "$ROOT/a/canon" branch --list 'feat/42-password-reset')" &&
  ok "second-generation release removed the local branch" ||
  bad "second-generation release left the local branch"
test -z "$(git -C "$ROOT/a/canon" ls-remote --heads origin 'feat/42-password-reset')" &&
  ok "second-generation release removed the remote branch" ||
  bad "second-generation release left the remote branch"
gen_closed=$(grep -c 'issue-42-password-reset' "${GH_PR_FILE}.closed" || true)
check "both generations are terminal now" "$gen_closed" "2"
# And the global id lookup is STILL ambiguous — the bound lookup is what made
# the release possible, not a weakened ambiguity check.
out=$("$SCRIPT_DIR/../pr-claims.sh" find-terminal acme/app issue-42-password-reset 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "id-only terminal lookup remains ambiguous across generations" \
  || bad "id-only terminal lookup stopped refusing two generations (rc=$rc): $out"
contains "ambiguity error points at the bound lookup" "$out" "find-terminal-pr"
# A third claim on the freed id can still be made and released the same way.
out=$(cd "$ROOT/a/canon" && "$CLAIM" 42 password-reset 'app/api/auth/**' 2>&1); rc=$?
check "generation 3 can claim the id again" "$rc" "0"
out=$(cd "$ROOT/a/canon" && "$SCRIPT_DIR/../release-claim.sh" 42 --repo acme/app 2>&1); rc=$?
check "generation 3 releases cleanly too" "$rc" "0"

# --- #153 review round 4, P1: a nonzero `gh pr create` is AMBIGUOUS ---------
# This fixture used to assert the opposite — that a failed create removed the
# worktree and the branch and stayed retryable. That is only safe if a nonzero
# exit proved GitHub created nothing, and it does not: the exit status is the
# CLIENT's view of the call. GitHub can create the PR and then lose the
# response, and the eventually consistent PR list can be empty for a while
# afterwards. Destroying the branch on that evidence destroys the work behind
# an open claim PR. From the instant `pr create` is invoked, everything is
# retained until the claim PR is positively bound and positively closed.
echo "#153 round 4 · a failed gh pr create RETAINS everything (a nonzero exit is not proof no PR exists)"
new_repo "$ROOT/cleanup"
export GH_LOG="$ROOT/cleanup/gh.log"
: > "$GH_LOG"
export GH_FAIL_PR_CREATE=1
out=$(cd "$ROOT/cleanup/canon" && "$CLAIM" 43 cleanup 'lib/cleanup.ts' 2>&1); rc=$?
unset GH_FAIL_PR_CREATE
check    "draft PR failure exits nonzero"        "$rc" "1"
contains "reports INCOMPLETE"                    "$out" "INCOMPLETE"
contains "names the PR that may exist"           "$out" "a possible draft claim PR for issue-43-cleanup"
contains "says why the exit status proves nothing" "$out" "not proof GitHub created nothing"
contains "tells the operator to close it by hand" "$out" "Find and close it by hand"
test -d "$ROOT/cleanup/wt-43-cleanup" &&
  ok "failed create KEEPS its worktree" ||
  bad "failed create destroyed its worktree"
test -n "$(git -C "$ROOT/cleanup/canon" branch --list 'feat/43-cleanup')" &&
  ok "failed create KEEPS its local branch" ||
  bad "failed create destroyed its local branch"
test -n "$(git -C "$ROOT/cleanup/canon" ls-remote --heads origin 'feat/43-cleanup')" &&
  ok "failed create KEEPS its remote branch" ||
  bad "failed create destroyed its remote branch"
lacks "agent-claimed is not removed" "$(cat "$GH_LOG" 2>/dev/null)" "--remove-label"

echo "#153 round 4 · the STAGED case: the server created the PR, the client saw an error, the listing is empty"
# The strongest form of the same failure, and the one the exit-status shortcut
# got fatally wrong: the PR really exists and really holds the claim.
new_repo "$ROOT/orphan"
export GH_LOG="$ROOT/orphan/gh.log"
: > "$GH_LOG"
export GH_PR_ORPHANS="$ROOT/orphan/orphan-prs"
: > "$GH_PR_ORPHANS"
export GH_PR_CREATE_ORPHAN=1
out=$(cd "$ROOT/orphan/canon" && "$CLAIM" 45 orphaned 'lib/orphan.ts' 2>&1); rc=$?
unset GH_PR_CREATE_ORPHAN
[[ "$rc" -ne 0 ]] && ok "an unpublished-but-real PR exits nonzero" \
  || bad "an unpublished-but-real PR exited 0: $out"
contains "reports INCOMPLETE"          "$out" "INCOMPLETE"
contains "names the PR that may exist" "$out" "a possible draft claim PR for issue-45-orphaned"
lacks    "never claims a clean rollback" "$out" "rollback: removed"
# The PR really is there on the "server", carrying this lane's claim.
contains "the fixture really created a server-side PR" "$(cat "$GH_PR_ORPHANS")" "issue-45-orphaned"
# …and nothing behind it was destroyed.
test -d "$ROOT/orphan/wt-45-orphaned" &&
  ok "unpublished PR: worktree retained" || bad "unpublished PR: worktree destroyed behind an open claim"
test -n "$(git -C "$ROOT/orphan/canon" branch --list 'feat/45-orphaned')" &&
  ok "unpublished PR: local branch retained" || bad "unpublished PR: local branch destroyed behind an open claim"
test -n "$(git -C "$ROOT/orphan/canon" ls-remote --heads origin 'feat/45-orphaned')" &&
  ok "unpublished PR: remote branch retained" || bad "unpublished PR: remote branch destroyed behind an open claim"
lacks "unpublished PR: agent-claimed retained" "$(cat "$GH_LOG" 2>/dev/null)" "--remove-label"
unset GH_PR_ORPHANS GH_LOG

echo "a claim that cannot push still cleans up after itself and stays retryable"
# The rollback anchor is pinned to the claim commit BEFORE the push, so a push
# that fails does not look like a branch that advanced behind this lane's back.
# Pinned after the push instead, this rollback would refuse its own worktree and
# the retry below would hit "worktree path already exists" forever.
new_repo "$ROOT/pushfail"
chmod -R a-w "$ROOT/pushfail/origin"
out=$(cd "$ROOT/pushfail/canon" && "$CLAIM" 44 pushfail 'lib/pushfail.ts' 2>&1); rc=$?
chmod -R u+w "$ROOT/pushfail/origin"
check    "an unpushable claim exits nonzero" "$rc" "1"
contains "names the failed push"             "$out" "claim branch push failed"
lacks    "a retryable failure is not INCOMPLETE" "$out" "INCOMPLETE"
test ! -e "$ROOT/pushfail/wt-44-pushfail" \
  && ok "the unpushed claim removed its own worktree" || bad "the unpushed claim left its worktree"
test -z "$(git -C "$ROOT/pushfail/canon" branch --list 'feat/44-pushfail')" \
  && ok "the unpushed claim removed its own local branch" || bad "the unpushed claim left its local branch"
out=$(cd "$ROOT/pushfail/canon" && "$CLAIM" 44 pushfail 'lib/pushfail.ts' 2>&1); rc=$?
check "retry after an unpushable claim succeeds" "$rc" "0"

echo "L-028 · a second claim on a claimed issue is refused unless it is deliberate"
new_repo "$ROOT/b"
add_claim "$ROOT/b" issue-77-server-side 'server/**'
out=$(cd "$ROOT/b/canon" && "$CLAIM" 77 client-side 'app/**' 2>&1); rc=$?
check    "refuses"          "$rc" "1"
contains "names the holder" "$out" "issue-77-server-side"
contains "points at --slice" "$out" "--slice"
claims=$(cat "$GH_PR_FILE")
lacks "no duplicate claim was written" "$claims" "issue-77-client-side"

echo "L-024 · --slice allows a deliberate second lane with separate scope"
out=$(cd "$ROOT/b/canon" && "$CLAIM" 77 client-side 'app/**' --slice 2>&1); rc=$?
check    "allowed"            "$rc" "0"
contains "says it is a slice" "$out" "slice claim"
claims=$(cat "$GH_PR_FILE")
contains "both slices live" "$claims" "issue-77-client-side"
test -f "$ROOT/b/canon/docs/claims/issue-77-server-side.md" &&
  ok "sibling untouched" ||
  bad "sibling untouched"

echo "scope overlap is refused whichever side is broader"
new_repo "$ROOT/c"
add_claim "$ROOT/c" issue-90-nav 'components/nav/**'
out=$(cd "$ROOT/c/canon" && "$CLAIM" 91 nav-tweak 'components/nav/Item.tsx' 2>&1); rc=$?
check    "narrow claim inside a live broad claim is refused" "$rc" "1"
contains "names the conflicting claim" "$out" "issue-90-nav"
out=$(cd "$ROOT/c/canon" && "$CLAIM" 92 nav-rewrite 'components/**' 2>&1); rc=$?
check "broad claim over a live narrow claim is refused" "$rc" "1"
out=$(cd "$ROOT/c/canon" && "$CLAIM" 93 billing 'app/billing/**' 2>&1); rc=$?
check "unrelated scope is allowed" "$rc" "0"

echo "cross-issue PR-body claim overlap is refused end-to-end (#153)"
out=$(cd "$ROOT/c/canon" && "$CLAIM" 94 payments-core 'lib/payments/**' 2>&1); rc=$?
check "PR-body claim for issue 94 succeeds" "$rc" "0"
out=$(cd "$ROOT/c/canon" && "$CLAIM" 95 payments-retry 'lib/payments/retry.ts' 2>&1); rc=$?
check    "different issue overlapping a live PR-body claim is refused" "$rc" "1"
contains "names the conflicting PR-body claim" "$out" "issue-94-payments-core"
out=$(cd "$ROOT/c/canon" && "$CLAIM" 96 shipping 'lib/shipping/**' 2>&1); rc=$?
check "different issue with disjoint scope coexists with the live PR-body claim" "$rc" "0"

echo "legacy rows still count as live claims"
new_repo "$ROOT/e"
(
  cd "$ROOT/e/canon" || exit 1
  printf '| 2026-08-01 | issue-60-legacy | lib/pay/** | session:old |\n' >> docs/active-work.md
  git add -A && git commit -qm legacy && git push -q origin main
) >/dev/null 2>&1
out=$(cd "$ROOT/e/canon" && "$CLAIM" 60 second-go 'lib/other' 2>&1); rc=$?
check "same issue via a legacy row is refused" "$rc" "1"
out=$(cd "$ROOT/e/canon" && "$CLAIM" 61 pay-fix 'lib/pay/Checkout.ts' 2>&1); rc=$?
check "legacy scope overlap is refused" "$rc" "1"

echo "L-009 · the caller's checkout is never moved"
new_repo "$ROOT/f"
(cd "$ROOT/f/canon" && git checkout -q -b long-lived && echo dirty > wip.txt) >/dev/null 2>&1
(cd "$ROOT/f/canon" && "$CLAIM" 12 thing 'lib/thing.ts') >/dev/null 2>&1
branch=$(cd "$ROOT/f/canon" && git rev-parse --abbrev-ref HEAD)
check "still on its branch" "$branch" "long-lived"
check "uncommitted work untouched" "$(cd "$ROOT/f/canon" && git status --porcelain)" "?? wip.txt"
contains "claim still has a PR body" "$(cat "$GH_PR_FILE")" "issue-12-thing"

echo "claims-status.sh renders the lanes"
export GH_PR_FILE="$ROOT/b/prs"
status=$(cd "$ROOT/b/canon" && "$SCRIPT_DIR/../claims-status.sh" --issue 77)
contains "shows slice one" "$status" "issue-77-server-side"
contains "shows slice two" "$status" "issue-77-client-side"
# Date-only legacy row is 2026-08-01 → midnight UTC. Pin NOW to exactly 24h later
# so STALE does not depend on the wall calendar or a second-boundary race (#62).
# Epochs are fixed UTC constants (not derived via date(1)) so the sensor stays
# portable across BSD and GNU hosts.
#   2026-08-01T00:00:00Z = 1785542400
#   2026-08-02T00:00:00Z = 1785628800  (exactly +24h)
status=$(cd "$ROOT/e/canon" && GIBSON_CLAIMS_NOW_EPOCH=1785628800 "$SCRIPT_DIR/../claims-status.sh")
contains "includes legacy rows" "$status" "issue-60-legacy"
contains "flags a stale claim"  "$status" "STALE"

echo "legacy date-only claim timestamps are midnight UTC at the 24h boundary (#62)"
# Same fixture date (2026-08-01). One second before 24h must not be STALE; at
# exactly 24h it must be. Both use the injectable clock — never the wall clock.
# Assert STALE(24h) — not bare STALE — so a fixture-date edit that drifts the
# age fails loudly instead of still matching an arbitrary stale marker.
status=$(cd "$ROOT/e/canon" && GIBSON_CLAIMS_NOW_EPOCH=1785628799 "$SCRIPT_DIR/../claims-status.sh")
contains "includes the legacy claim one second under 24h" "$status" "issue-60-legacy"
lacks   "not STALE one second under 24h"                 "$status" "STALE"
status=$(cd "$ROOT/e/canon" && GIBSON_CLAIMS_NOW_EPOCH=1785628800 "$SCRIPT_DIR/../claims-status.sh")
contains "STALE at exactly 24h from date-only midnight UTC" "$status" "STALE(24h)"
contains "STALE marks the legacy claim id"                  "$status" "issue-60-legacy"

echo "digit-only GIBSON_CLAIMS_NOW_EPOCH with leading zeros is decimal (#62)"
# 0086400 as base-10 is 86400 (exactly 24h). As octal it is invalid (digit 8)
# and aborts bash arithmetic before claims print. A claim at Unix epoch 0 with
# this NOW must report STALE(24h) and exit 0.
new_repo "$ROOT/g"
(
  cd "$ROOT/g/canon" || exit 1
  printf 'claim: issue-62-epoch-pad\nissue: 62\nclaimed: 1970-01-01T00:00:00Z\nscope: lib/**\nsession: pad-test\n' \
    > docs/claims/issue-62-epoch-pad.md
  git add -A && git commit -qm pad && git push -q origin main
) >/dev/null 2>&1
status=$(cd "$ROOT/g/canon" && GIBSON_CLAIMS_NOW_EPOCH=0086400 "$SCRIPT_DIR/../claims-status.sh" 2>&1); rc=$?
check    "leading-zero decimal epoch does not abort" "$rc" "0"
contains "leading-zero epoch is base-10 STALE(24h)"  "$status" "STALE(24h)"
contains "leading-zero epoch still lists the claim"  "$status" "issue-62-epoch-pad"

echo "set-empty GIBSON_CLAIMS_NOW_EPOCH fails closed (#62)"
# Explicit empty must not be treated as unset (wall-clock fallback). Repo has a
# live claim so a silent success would either list it or falsely say none live.
status=$(cd "$ROOT/g/canon" && GIBSON_CLAIMS_NOW_EPOCH='' "$SCRIPT_DIR/../claims-status.sh" 2>&1); rc=$?
check    "set-empty epoch exits 2"                       "$rc" "2"
contains "set-empty epoch validation error"              "$status" "GIBSON_CLAIMS_NOW_EPOCH must be decimal Unix epoch seconds"
lacks    "set-empty never pretends no live claims"       "$status" "no live claims"
lacks    "set-empty never succeeds with a live table"    "$status" "live claims"

echo "oversized GIBSON_CLAIMS_NOW_EPOCH fails closed (#62)"
# 20-digit string wraps under bash $((10#...)) into a nonsense age and would
# still exit 0. Bound check must reject before any claim rows are read/emitted.
status=$(cd "$ROOT/g/canon" && GIBSON_CLAIMS_NOW_EPOCH=99999999999999999999 "$SCRIPT_DIR/../claims-status.sh" 2>&1); rc=$?
check    "oversized epoch exits 2"                       "$rc" "2"
contains "oversized epoch validation error"              "$status" "GIBSON_CLAIMS_NOW_EPOCH must be decimal Unix epoch seconds"
lacks    "oversized never pretends no live claims"       "$status" "no live claims"
lacks    "oversized never succeeds with a live table"    "$status" "live claims"

# ---------------------------------------------------------------------------
echo "#153 · two GENUINELY concurrent lanes with overlapping scope: exactly one survives"
# Not a sequential simulation: two claim.sh processes run at the same time,
# against one shared fake GitHub, and are held at a rendezvous inside `gh pr
# create` until BOTH have finished their pre-create inventory read. That is
# the exact TOCTOU window — at the moment each lane checked for overlap,
# neither claim existed — so before the post-create admission pass both lanes
# would have survived with overlapping scope on different issues.
#
# The fake assigns PR numbers and appends the row in one critical section, so
# the lower-numbered row is always visible to the higher-numbered lane. The
# winner is therefore decided by evidence both lanes can read, not by timing.
RACE_DIR="$ROOT/race"
mkdir -p "$RACE_DIR/bin"
export RACE_DIR
export RACE_REPO="acme/race"
echo 1 > "$RACE_DIR/next"
: > "$RACE_DIR/prs"
: > "$RACE_DIR/prs.closed"

# Written once, used by every concurrency fixture below (#153 review P1 0B
# reuses the exact fake the cross-issue race is already proven against, so a
# same-issue race cannot pass for some accidental difference in its harness).
write_race_gh() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<'RACEGH'
#!/usr/bin/env bash
# Shared, lock-protected fake GitHub for the concurrency fixture.
#
# Pause without resolving the bare name `sleep` through PATH (#153 review
# round 6, P3). The suite plants a hostile PATH `sleep` as a tripwire for
# production barrier bypass; harness polling must not pollute that receipt.
# Ready-files remain the real rendezvous proof — this only yields the spin.
race_pause() {
  if [[ -x /bin/sleep ]]; then
    /bin/sleep 0.05
  elif [[ -x /usr/bin/sleep ]]; then
    /usr/bin/sleep 0.05
  fi
}
lock() {
  local i=0
  while ! mkdir "$RACE_DIR/lock" 2>/dev/null; do
    i=$((i + 1))
    [[ "$i" -gt 600 ]] && { echo "fake gh: lock timeout" >&2; exit 1; }
    race_pause
  done
}
unlock() { rmdir "$RACE_DIR/lock" 2>/dev/null || true; }
RACE_REPO="${RACE_REPO:-acme/race}"
case "$1 $2" in
  "repo view") echo "$RACE_REPO" ;;
  "issue view") cat "$RACE_DIR/labels-$3" 2>/dev/null || echo "" ;;
  "issue edit")
    issue="$3"
    if echo "$*" | grep -q -- '--add-label'; then
      echo "agent-claimed" > "$RACE_DIR/labels-$issue"
    elif echo "$*" | grep -q -- '--remove-label'; then
      : > "$RACE_DIR/labels-$issue"
    fi
    ;;
  "api graphql")
    # `list-open-numbers` is named openPrNumbers and its query also carries
    # `states: [OPEN]`, so match it first.
    want_numbers=0
    for a in "$@"; do
      case "$a" in *"openPrNumbers"*) want_numbers=1 ;; esac
    done
    want_open=0
    for a in "$@"; do
      case "$a" in *"states: [OPEN]"*) want_open=1 ;; esac
    done
    lock
    if [[ "$want_numbers" -eq 1 ]]; then
      cut -d'|' -f1 "$RACE_DIR/prs" 2>/dev/null | grep -E '^[0-9]+$' || true
    elif [[ "$want_open" -eq 1 ]]; then
      while IFS='|' read -r number claim scope branch url created updated; do
        [[ -n "$claim" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tfalse\n' \
          "$number" "$claim" "$scope" "$branch" "$url" "$created" "$updated"
      done < "$RACE_DIR/prs"
    fi
    unlock
    ;;
  "pr create")
    body_file=""; branch=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --body-file) body_file="$2"; shift 2 ;;
        --head) branch="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    claim=$(sed -n 's/^- Active-work claim: //p' "$body_file")
    scope=$(sed -n 's/^- Claim scope: //p' "$body_file")
    # Rendezvous: hold every lane here until they have all arrived, so each
    # one's pre-create overlap read provably happened before any PR existed.
    : > "$RACE_DIR/ready-$claim"
    waited=0
    while [[ "$(find "$RACE_DIR" -maxdepth 1 -name 'ready-*' | wc -l | tr -d ' ')" -lt "${RACE_LANES:-2}" ]]; do
      waited=$((waited + 1))
      [[ "$waited" -gt 400 ]] && break    # bounded: never hang the suite
      race_pause
    done
    # Number assignment and publication in ONE critical section: whoever gets
    # the lower number is already visible when the higher-numbered lane looks.
    lock
    number=$(cat "$RACE_DIR/next" 2>/dev/null || echo 1)
    echo $((number + 1)) > "$RACE_DIR/next"
    printf '%s|%s|%s|%s|https://github.com/%s/pull/%s|2026-08-09T00:00:00Z|2026-08-09T00:00:00Z\n' \
      "$number" "$claim" "$scope" "$branch" "$RACE_REPO" "$number" >> "$RACE_DIR/prs"
    unlock
    echo "https://github.com/$RACE_REPO/pull/$number"
    ;;
  "pr close")
    number="$3"
    lock
    : > "$RACE_DIR/prs.tmp"
    while IFS='|' read -r pr rest; do
      [[ -n "$pr" ]] || continue
      if [[ "$pr" == "$number" ]]; then
        printf '%s|%s\n' "$pr" "$rest" >> "$RACE_DIR/prs.closed"
      else
        printf '%s|%s\n' "$pr" "$rest" >> "$RACE_DIR/prs.tmp"
      fi
    done < "$RACE_DIR/prs"
    mv "$RACE_DIR/prs.tmp" "$RACE_DIR/prs"
    unlock
    ;;
  *)
    # Loud and bounded (#153 review round 5). An unmodelled gh subcommand is a
    # gap in this fixture, not a success — and never a stdin-reading fallthrough.
    echo "fake gh (race fixture): unmodelled invocation 'gh $*' — refusing rather than answering a query this fixture does not model" >&2
    exit 64
    ;;
esac
exit 0
RACEGH
  chmod +x "$dest"
}

# One bare origin, N independent lane checkouts — the real fleet shape (one
# working directory per agent), and it keeps the race at the claim layer
# instead of at git's own index locks.
setup_race_repo() { # dir repo lane…
  local dir="$1" repo="$2"
  shift 2
  local lane
  mkdir -p "$dir/bin"
  echo 1 > "$dir/next"
  : > "$dir/prs"
  : > "$dir/prs.closed"
  git init -q --bare "$dir/origin"
  # Ubuntu/`git init --bare` defaults HEAD to refs/heads/master when
  # init.defaultBranch is unset. Pin it to main BEFORE the seed push so a
  # second clone actually checks main out (and so this fixture matches a real
  # GitHub repository, whose default branch is main). Without this, Linux CI
  # got "remote HEAD refers to nonexistent ref, unable to checkout", no local
  # main, and both concurrent lanes died on `git fetch origin master` (#153).
  git --git-dir="$dir/origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin" "$dir/seed" 2>/dev/null
  (
    cd "$dir/seed" || exit 1
    mkdir -p docs/claims
    printf '| when | claim-id | scope | who |\n|---|---|---|---|\n' > docs/active-work.md
    git add -A && git commit -qm init && git branch -M main && git push -q -u origin main
  ) >/dev/null 2>&1
  # Re-assert after the push: some git versions leave bare HEAD alone when the
  # first branch is pushed under a different name than the previous HEAD.
  git --git-dir="$dir/origin" symbolic-ref HEAD refs/heads/main
  for lane in "$@"; do
    mkdir -p "$dir/lane$lane"
    # -b main: never depend on remote HEAD resolution for the lane checkout.
    git clone -q -b main "$dir/origin" "$dir/lane$lane/canon" 2>/dev/null
    git -C "$dir/lane$lane/canon" config "url.$dir/origin.insteadOf" "https://github.com/$repo.git"
    git -C "$dir/lane$lane/canon" remote set-url origin "https://github.com/$repo.git"
  done
  write_race_gh "$dir/bin/gh"
}

# Dump every concurrent lane's captured stdout/stderr when the fixture fails
# its structural assertions. CI on Ubuntu previously reported "0 winners /
# never reached the rendezvous" with no receipt of WHY; the next failure must
# carry the claim.sh output that produced it (#153 Linux diagnosis).
dump_race_lane_outputs() { # dir label
  local dir="$1" label="$2" f
  echo "  --- $label: captured lane outputs (printed because the fixture failed) ---"
  for f in "$dir"/outA "$dir"/outB; do
    if [[ -f "$f" ]]; then
      echo "  --- $(basename "$f") ---"
      sed 's/^/  | /' "$f"
    else
      echo "  --- $(basename "$f") missing ---"
    fi
  done
  echo "  --- end $label lane outputs ---"
}

setup_race_repo "$RACE_DIR" "$RACE_REPO" A B

RACE_OLD_PATH="$PATH"
export PATH="$RACE_DIR/bin:$PATH"
# Different ISSUES, overlapping SCOPE — the cross-issue case the pre-create
# duplicate-issue refusal cannot catch.
(cd "$RACE_DIR/laneA/canon" && GIBSON_CANONICAL="$RACE_DIR/laneA/canon" \
  "$CLAIM" 501 alpha 'lib/shared/**' >"$RACE_DIR/outA" 2>&1) &
race_pid_a=$!
(cd "$RACE_DIR/laneB/canon" && GIBSON_CANONICAL="$RACE_DIR/laneB/canon" \
  "$CLAIM" 502 beta 'lib/shared/util.ts' >"$RACE_DIR/outB" 2>&1) &
race_pid_b=$!
wait "$race_pid_a"; rc_a=$?
wait "$race_pid_b"; rc_b=$?
export PATH="$RACE_OLD_PATH"

winners=0
[[ "$rc_a" -eq 0 ]] && winners=$((winners + 1))
[[ "$rc_b" -eq 0 ]] && winners=$((winners + 1))
check "exactly one concurrent lane succeeds" "$winners" "1"
[[ "$rc_a" -ne 0 || "$rc_b" -ne 0 ]] && ok "the losing lane exits nonzero" \
  || bad "no lane refused (rcA=$rc_a rcB=$rc_b)"
# Both really did race: each lane's pre-create read saw no claim at all.
if [[ -f "$RACE_DIR/ready-issue-501-alpha" && -f "$RACE_DIR/ready-issue-502-beta" ]]; then
  ok "both lanes reached PR creation (the TOCTOU window was really open)"
else
  bad "the lanes did not both reach the rendezvous"
  dump_race_lane_outputs "$RACE_DIR" "cross-issue race (rcA=$rc_a rcB=$rc_b)"
fi
# Also dump when the winner count is wrong — that is the other way this
# fixture fails closed without explaining itself on CI.
if [[ "$winners" -ne 1 ]]; then
  dump_race_lane_outputs "$RACE_DIR" "cross-issue race winners=$winners (rcA=$rc_a rcB=$rc_b)"
fi

live_rows=$(grep -c . "$RACE_DIR/prs" || true)
check "exactly one live PR-body claim survives" "$live_rows" "1"
survivor_num=$(cut -d'|' -f1 "$RACE_DIR/prs" | head -1)
survivor_id=$(cut -d'|' -f2 "$RACE_DIR/prs" | head -1)
check "the survivor is the lower PR number" "$survivor_num" "1"

if [[ "$rc_a" -eq 0 ]]; then
  win_lane=A; win_id=issue-501-alpha; win_br=feat/501-alpha; win_issue=501
  lose_lane=B; lose_id=issue-502-beta; lose_br=feat/502-beta; lose_issue=502
else
  win_lane=B; win_id=issue-502-beta; win_br=feat/502-beta; win_issue=502
  lose_lane=A; lose_id=issue-501-alpha; lose_br=feat/501-alpha; lose_issue=501
fi
check "the surviving claim belongs to the winning lane" "$survivor_id" "$win_id"
contains "the loser says why it stood down" "$(cat "$RACE_DIR/out$lose_lane")" "admission refused"
contains "the loser names the winning claim" "$(cat "$RACE_DIR/out$lose_lane")" "$win_id"

# The loser cleaned up ONLY its own artifacts…
test -z "$(find "$RACE_DIR/lane$lose_lane" -maxdepth 1 -name 'wt-*' 2>/dev/null)" \
  && ok "the loser removed its own worktree" || bad "the loser left its worktree behind"
test -z "$(git -C "$RACE_DIR/lane$lose_lane/canon" branch --list "$lose_br")" \
  && ok "the loser removed its own local branch" || bad "the loser left its local branch"
test -z "$(git -C "$RACE_DIR/lane$lose_lane/canon" ls-remote --heads origin "$lose_br")" \
  && ok "the loser removed its own remote branch" || bad "the loser left its remote branch"
lacks "the loser released its own label" "$(cat "$RACE_DIR/labels-$lose_issue" 2>/dev/null || echo '')" "agent-claimed"
grep -qF "$lose_id" "$RACE_DIR/prs.closed" \
  && ok "the loser closed its own PR" || bad "the loser left its PR open"

# …and never touched the winner's.
test -n "$(find "$RACE_DIR/lane$win_lane" -maxdepth 1 -name 'wt-*' 2>/dev/null)" \
  && ok "the winner's worktree is intact" || bad "the winner's worktree was destroyed"
test -n "$(git -C "$RACE_DIR/lane$win_lane/canon" branch --list "$win_br")" \
  && ok "the winner's local branch is intact" || bad "the winner's local branch was deleted"
test -n "$(git -C "$RACE_DIR/lane$win_lane/canon" ls-remote --heads origin "$win_br")" \
  && ok "the winner's remote branch is intact" || bad "the winner's remote branch was deleted"
contains "the winner still holds agent-claimed" "$(cat "$RACE_DIR/labels-$win_issue" 2>/dev/null || echo '')" "agent-claimed"
lacks "the winner never reports a refusal" "$(cat "$RACE_DIR/out$win_lane")" "admission refused"
contains "the winner records its verified admission" "$(cat "$RACE_DIR/out$win_lane")" "admission: PR #$survivor_num holds $win_id"

echo "#153 · an inventory that cannot see this lane's own claim refuses it (fail closed)"
# The admission pass is only meaningful against an inventory fresh enough to
# contain the claim being admitted. If it is not there, the read proves
# nothing about who else holds the scope — roll back rather than assume.
new_repo "$ROOT/admitblind"
BLIND_BIN="$ROOT/admitblind/bin"
mkdir -p "$BLIND_BIN"
cat > "$BLIND_BIN/gh" <<'BLINDGH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") cat "${GH_LABELS_FILE:-/dev/null}" 2>/dev/null || echo "" ;;
  "issue edit") echo "$*" >> "${GH_LOG:-/dev/null}" ;;
  # The open inventory never shows the PR this fixture just created.
  # list-open-numbers (openPrNumbers) is body-agnostic and also empty here:
  # this fixture never published a PR that claim.sh can re-find by number.
  "api graphql")
    for a in "$@"; do
      case "$a" in
        *"openPrNumbers"*|*"states: [OPEN]"*) exit 0 ;;
      esac
    done
    echo "fake gh (admitblind): unmodelled graphql query 'gh $*' — refusing" >&2
    exit 64
    ;;
  "pr create")
    echo "https://github.com/acme/app/pull/4242"
    ;;
  "pr close") echo "closed $3" >> "${GH_CLOSE_LOG:-/dev/null}" ;;
  *)
    echo "fake gh (admitblind): unmodelled invocation 'gh $*' — refusing" >&2
    exit 64
    ;;
esac
exit 0
BLINDGH
chmod +x "$BLIND_BIN/gh"
export GH_CLOSE_LOG="$ROOT/admitblind/close.log"
: > "$GH_CLOSE_LOG"
out=$(cd "$ROOT/admitblind/canon" && PATH="$BLIND_BIN:$PATH" GIBSON_CLAIM_ADMIT_ATTEMPTS=2 \
  "$CLAIM" 77 blind 'lib/blind/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an inventory blind to this claim refuses it" || bad "blind inventory admitted the claim (rc=$rc): $out"
contains "names the unprovable registration" "$out" "could not obtain a stable live-claim inventory"
test ! -e "$ROOT/admitblind/wt-77-blind" \
  && ok "blind admission rolled back its worktree" || bad "blind admission left its worktree"
test -z "$(git -C "$ROOT/admitblind/canon" branch --list 'feat/77-blind')" \
  && ok "blind admission rolled back its local branch" || bad "blind admission left its local branch"
test -z "$(git -C "$ROOT/admitblind/canon" ls-remote --heads origin 'feat/77-blind')" \
  && ok "blind admission rolled back its remote branch" || bad "blind admission left its remote branch"
contains "blind admission closed its own PR" "$(cat "$GH_CLOSE_LOG")" "closed 4242"
unset GH_CLOSE_LOG

# ---------------------------------------------------------------------------
# #153 review P1 0A — the publication barrier
# ---------------------------------------------------------------------------
# Seeing your OWN claim in the inventory does not prove you can see everyone
# else's. GitHub's PR listing is eventually consistent, so a rival created
# moments earlier can still be missing from the page served to this lane after
# its own row has appeared. A fake that publishes everything instantly cannot
# express that at all, so this one is sequenced: the rival becomes visible
# only some reads AFTER this lane's own claim is already there.
lag_fixture() { # dir self-pr rival-row
  local dir="$1" self_pr="$2" rival_row="$3"
  new_repo "$ROOT/$dir"
  export LAG_STATE="$ROOT/$dir/state"
  mkdir -p "$LAG_STATE"
  : > "$LAG_STATE/labels"
  : > "$LAG_STATE/label.log"
  : > "$LAG_STATE/close.log"
  rm -f "$LAG_STATE/self" "$LAG_STATE/reads"
  printf '%s\n' "$rival_row" > "$LAG_STATE/rival"
  export LAG_SELF_PR="$self_pr"
  mkdir -p "$ROOT/$dir/bin"
  cat > "$ROOT/$dir/bin/gh" <<'LAGGH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") cat "$LAG_STATE/labels" 2>/dev/null || echo "" ;;
  "issue edit")
    echo "$*" >> "$LAG_STATE/label.log"
    if echo "$*" | grep -q -- '--add-label'; then
      echo "agent-claimed" > "$LAG_STATE/labels"
    elif echo "$*" | grep -q -- '--remove-label'; then
      : > "$LAG_STATE/labels"
    fi
    ;;
  "api graphql")
    # `list-open-numbers` (operation openPrNumbers) also carries
    # `states: [OPEN]`, so match it first. It is body-agnostic: this lane's own
    # PR stays in it until `pr close` actually removes it.
    want_numbers=0
    for a in "$@"; do case "$a" in *"openPrNumbers"*) want_numbers=1 ;; esac; done
    if [[ "$want_numbers" -eq 1 ]]; then
      if [[ -n "${LAG_STILL_OPEN_AFTER_CLOSE:-}" ]]; then
        # A LYING close: gh reported success, the PR never left the open set.
        printf '%s\n' "$LAG_SELF_PR"
        exit 0
      fi
      [[ "${LAG_OPEN_NUMBERS_EXIT:-0}" -eq 0 ]] || {
        echo "gh: API rate limit exceeded" >&2
        exit 1
      }
      [[ -f "$LAG_STATE/closed" ]] || printf '%s\n' "$LAG_SELF_PR"
      [[ -f "$LAG_STATE/rival" ]] && cut -f1 "$LAG_STATE/rival"
      exit 0
    fi
    want_open=0
    for a in "$@"; do case "$a" in *"states: [OPEN]"*) want_open=1 ;; esac; done
    [[ "$want_open" -eq 1 ]] || exit 0
    # Post-close read failures are modelled FIRST: the rollback's proof that
    # the claim stopped being live is itself a read, and it has to be possible
    # for that read to fail.
    if [[ -n "${LAG_BAD_AFTER_CLOSE:-}" && -f "$LAG_STATE/closed" ]]; then
      case "${LAG_BAD_AFTER_CLOSE}" in
        unreadable) echo "gh: API rate limit exceeded" >&2; exit 1 ;;
        malformed)  printf 'not-a-row\twith-two-fields\n' ; exit 0 ;;
      esac
    fi
    # Before this lane publishes, the inventory is genuinely empty — the same
    # window the real cross-issue race opens.
    [[ -f "$LAG_STATE/self" ]] || exit 0
    n=$(cat "$LAG_STATE/reads" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$LAG_STATE/reads"
    if [[ -n "${LAG_CHURN:-}" ]]; then
      # Never settles: every read returns a different inventory.
      cat "$LAG_STATE/self"
      printf '%s\tissue-%s-churn\tlib/churn-%s/**\tfeat/%s-churn\thttps://github.com/acme/app/pull/%s\t2026-08-09T00:00:00Z\t2026-08-09T00:00:00Z\tfalse\n' \
        "$((900 + n))" "$((800 + n))" "$n" "$((800 + n))" "$((900 + n))"
      exit 0
    fi
    cat "$LAG_STATE/self"
    [[ "$n" -ge "${LAG_RIVAL_AFTER:-3}" ]] && cat "$LAG_STATE/rival"
    exit 0
    ;;
  "pr create")
    body_file=""; branch=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --body-file) body_file="$2"; shift 2 ;;
        --head) branch="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    claim=$(sed -n 's/^- Active-work claim: //p' "$body_file")
    scope=$(sed -n 's/^- Claim scope: //p' "$body_file")
    printf '%s\t%s\t%s\t%s\thttps://github.com/acme/app/pull/%s\t2026-08-09T00:00:00Z\t2026-08-09T00:00:00Z\t%s\n' \
      "$LAG_SELF_PR" "$claim" "$scope" "$branch" "$LAG_SELF_PR" \
      "${LAG_SELF_CROSS:-false}" > "$LAG_STATE/self"
    echo "https://github.com/acme/app/pull/$LAG_SELF_PR"
    ;;
  "pr close")
    echo "closed $3" >> "$LAG_STATE/close.log"
    : > "$LAG_STATE/closed"
    # A closed PR stops being a live claim. Modelling that is what lets the
    # rollback's post-close proof ("is this still live?") mean anything.
    if [[ -n "${LAG_CLOSE_REWRITES:-}" ]]; then
      # The marker was REWRITTEN rather than removed: the claim inventory is
      # readable and well formed, it simply no longer mentions this lane's
      # claim id OR its PR number. Every marker-derived check therefore says
      # "the claim is gone" while the PR itself may be untouched.
      printf '4242\tissue-777-rewritten\tlib/elsewhere/**\tfeat/777-rewritten\thttps://github.com/acme/app/pull/4242\t2026-08-09T00:00:00Z\t2026-08-09T00:00:00Z\tfalse\n' \
        > "$LAG_STATE/self"
    else
      rm -f "$LAG_STATE/self"
    fi
    ;;
  *)
    echo "fake gh (lag fixture): unmodelled invocation 'gh $*' — refusing rather than answering a query this fixture does not model" >&2
    exit 64
    ;;
esac
exit 0
LAGGH
  chmod +x "$ROOT/$dir/bin/gh"
}

# PR #89 is a rival claim on a DIFFERENT issue with OVERLAPPING scope, and it
# holds the lower number, so the deterministic tie-break says this lane loses —
# if it ever manages to see it.
LAG_RIVAL_ROW=$'89\tissue-88-rival\tlib/lag/**\tfeat/88-rival\thttps://github.com/acme/app/pull/89\t2026-08-09T00:00:00Z\t2026-08-09T00:00:00Z\tfalse'

echo "#153 · a rival visible only AFTER this lane's own claim is still caught"
lag_fixture lagcatch 90 "$LAG_RIVAL_ROW"
out=$(cd "$ROOT/lagcatch/canon" && PATH="$ROOT/lagcatch/bin:$PATH" \
  LAG_RIVAL_AFTER=3 GIBSON_CLAIM_ADMIT_STABLE_READS=3 GIBSON_CLAIM_ADMIT_ATTEMPTS=8 \
  "$CLAIM" 87 lagged 'lib/lag/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a late-publishing rival still refuses this lane" \
  || bad "the lane admitted itself against a rival it had not yet seen (rc=$rc): $out"
contains "names the rival it eventually saw" "$out" "issue-88-rival"
contains "reports the inventory settled first" "$out" "inventory quiescent"
test ! -e "$ROOT/lagcatch/wt-87-lagged" \
  && ok "late-rival refusal rolled back its worktree" || bad "late-rival refusal left its worktree"
test -z "$(git -C "$ROOT/lagcatch/canon" branch --list 'feat/87-lagged')" \
  && ok "late-rival refusal rolled back its local branch" || bad "late-rival refusal left its local branch"
test -z "$(git -C "$ROOT/lagcatch/canon" ls-remote --heads origin 'feat/87-lagged')" \
  && ok "late-rival refusal rolled back its remote branch" || bad "late-rival refusal left its remote branch"
lacks "late-rival refusal released its own label" "$(cat "$ROOT/lagcatch/state/labels")" "agent-claimed"

echo "#153 · production refuses to let a caller switch that barrier off"
# The old control turned the barrier down with GIBSON_CLAIM_ADMIT_STABLE_READS=1
# — which is exactly why the environment must not be able to do that. It is
# gone from production: below-floor values are a usage error, not a setting.
lag_fixture lagfloor 90 "$LAG_RIVAL_ROW"
for floor_env in GIBSON_CLAIM_ADMIT_STABLE_READS=1 GIBSON_CLAIM_ADMIT_DELAY=0 GIBSON_CLAIM_ADMIT_ATTEMPTS=1; do
  out=$(cd "$ROOT/lagfloor/canon" && PATH="$ROOT/lagfloor/bin:$PATH" \
    env "$floor_env" LAG_RIVAL_AFTER=3 "$CLAIM" 87 floored 'lib/lag/**' 2>&1); rc=$?
  if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qF "below the production minimum"; then
    ok "$floor_env is refused, not honoured"
  else
    bad "$floor_env was accepted (rc=$rc): $out"
  fi
done
test ! -e "$ROOT/lagfloor/wt-87-floored" \
  && ok "a below-floor barrier leaves no worktree behind" || bad "below-floor run left a worktree"

echo "#153 · that refusal is the barrier's doing, not the fixture's"
# The mechanism control, run against a TEST COPY of the scripts whose barrier
# floor is patched down to a single sample. Production is untouched: this is a
# separate tree under $ROOT, not a runtime switch. If the publication barrier
# is ever removed from the real sensor, this pair stops disagreeing and the
# late-rival sensor above stops meaning anything.
CTL_DIR="$ROOT/ctl-scripts"
mkdir -p "$CTL_DIR/lib"
cp "$SCRIPT_DIR/../claim.sh" "$SCRIPT_DIR/../pr-claims.sh" "$SCRIPT_DIR/../scope-overlap.mjs" "$CTL_DIR/"
cp "$SCRIPT_DIR/../lib/claim-guards.sh" "$CTL_DIR/lib/"
chmod +x "$CTL_DIR/claim.sh" "$CTL_DIR/pr-claims.sh"
# Patch ONLY the floor literals in the copy, and prove the patch landed.
perl -0pi -e 's/const ADMIT_FLOOR = \{\n  attempts: 2,\n  stableReads: 2,\n  delaySeconds: 1,\n\};/const ADMIT_FLOOR = {\n  attempts: 1,\n  stableReads: 1,\n  delaySeconds: 0,\n};/' "$CTL_DIR/scope-overlap.mjs"
if grep -q 'stableReads: 1,' "$CTL_DIR/scope-overlap.mjs"; then
  ok "the control copy really has its barrier floor patched down"
else
  bad "the control copy was not patched — the mechanism control proves nothing"
fi
lacks "production still carries the real floor" "$(grep -A3 'const ADMIT_FLOOR' "$SCRIPT_DIR/../scope-overlap.mjs")" "stableReads: 1,"
lag_fixture lagctl 90 "$LAG_RIVAL_ROW"
out=$(cd "$ROOT/lagctl/canon" && PATH="$ROOT/lagctl/bin:$PATH" \
  LAG_RIVAL_AFTER=3 GIBSON_CLAIM_ADMIT_STABLE_READS=1 GIBSON_CLAIM_ADMIT_DELAY=0 \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=8 "$CTL_DIR/claim.sh" 87 lagged 'lib/lag/**' 2>&1); rc=$?
check "one-sample admission accepts the same lane (barrier floor removed)" "$rc" "0"
lacks "one-sample admission never saw the rival" "$out" "issue-88-rival"

echo "#153 · an inventory that never settles refuses rather than guesses"
lag_fixture lagchurn 90 "$LAG_RIVAL_ROW"
out=$(cd "$ROOT/lagchurn/canon" && PATH="$ROOT/lagchurn/bin:$PATH" \
  LAG_CHURN=1 GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=4 \
  "$CLAIM" 87 churned 'lib/churned/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a never-quiescent inventory refuses the claim" \
  || bad "an unsettled inventory admitted the claim (rc=$rc): $out"
contains "says the inventory never settled" "$out" "could not obtain a stable live-claim inventory"
test ! -e "$ROOT/lagchurn/wt-87-churned" \
  && ok "unsettled refusal rolled back its worktree" || bad "unsettled refusal left its worktree"
test -z "$(git -C "$ROOT/lagchurn/canon" ls-remote --heads origin 'feat/87-churned')" \
  && ok "unsettled refusal rolled back its remote branch" || bad "unsettled refusal left its remote branch"

# ---------------------------------------------------------------------------
# #153 review P1 0B — same-issue exclusivity survives publication
# ---------------------------------------------------------------------------
echo "#153 · two GENUINELY concurrent lanes on the SAME issue, disjoint scope, no --slice"
# Both lanes pass the pre-create duplicate-issue check (neither is published
# yet) and both pass a scope-only re-check, because their scopes really are
# disjoint. Only a same-issue re-check against the post-publication inventory
# can stop the second build of one issue (L-028).
SAME_DIR="$ROOT/samerace"
RACE_DIR="$SAME_DIR"; export RACE_DIR
RACE_REPO="acme/samerace"; export RACE_REPO
setup_race_repo "$SAME_DIR" "$RACE_REPO" A B
SAME_OLD_PATH="$PATH"
export PATH="$SAME_DIR/bin:$PATH"
(cd "$SAME_DIR/laneA/canon" && GIBSON_CANONICAL="$SAME_DIR/laneA/canon" \
  "$CLAIM" 601 alpha 'lib/alpha/**' >"$SAME_DIR/outA" 2>&1) &
same_pid_a=$!
(cd "$SAME_DIR/laneB/canon" && GIBSON_CANONICAL="$SAME_DIR/laneB/canon" \
  "$CLAIM" 601 beta 'lib/beta/**' >"$SAME_DIR/outB" 2>&1) &
same_pid_b=$!
wait "$same_pid_a"; same_rc_a=$?
wait "$same_pid_b"; same_rc_b=$?
export PATH="$SAME_OLD_PATH"

same_winners=0
[[ "$same_rc_a" -eq 0 ]] && same_winners=$((same_winners + 1))
[[ "$same_rc_b" -eq 0 ]] && same_winners=$((same_winners + 1))
check "exactly one same-issue lane succeeds" "$same_winners" "1"
if [[ -f "$SAME_DIR/ready-issue-601-alpha" && -f "$SAME_DIR/ready-issue-601-beta" ]]; then
  ok "both same-issue lanes reached PR creation (the window was really open)"
else
  bad "the same-issue lanes did not both reach the rendezvous"
  dump_race_lane_outputs "$SAME_DIR" "same-issue race (rcA=$same_rc_a rcB=$same_rc_b)"
fi
if [[ "$same_winners" -ne 1 ]]; then
  dump_race_lane_outputs "$SAME_DIR" "same-issue race winners=$same_winners (rcA=$same_rc_a rcB=$same_rc_b)"
fi
check "exactly one live claim on the issue survives" "$(grep -c . "$SAME_DIR/prs" || true)" "1"
same_survivor_id=$(cut -d'|' -f2 "$SAME_DIR/prs" | head -1)
if [[ "$same_rc_a" -eq 0 ]]; then
  same_win=A; same_win_id=issue-601-alpha; same_win_br=feat/601-alpha
  same_lose=B; same_lose_id=issue-601-beta; same_lose_br=feat/601-beta
else
  same_win=B; same_win_id=issue-601-beta; same_win_br=feat/601-beta
  same_lose=A; same_lose_id=issue-601-alpha; same_lose_br=feat/601-alpha
fi
check "the surviving claim belongs to the winning lane" "$same_survivor_id" "$same_win_id"
lacks "the losing claim id is not live anywhere" "$(cat "$SAME_DIR/prs")" "$same_lose_id"
contains "the loser names same-issue exclusivity" "$(cat "$SAME_DIR/out$same_lose")" "issue #601 is already held"
contains "the loser points at --slice"            "$(cat "$SAME_DIR/out$same_lose")" "--slice"
test -z "$(find "$SAME_DIR/lane$same_lose" -maxdepth 1 -name 'wt-*' 2>/dev/null)" \
  && ok "the same-issue loser removed its own worktree" || bad "the same-issue loser left its worktree"
test -z "$(git -C "$SAME_DIR/lane$same_lose/canon" ls-remote --heads origin "$same_lose_br")" \
  && ok "the same-issue loser removed its own remote branch" || bad "the same-issue loser left its remote branch"
test -n "$(find "$SAME_DIR/lane$same_win" -maxdepth 1 -name 'wt-*' 2>/dev/null)" \
  && ok "the same-issue winner's worktree is intact" || bad "the same-issue winner's worktree was destroyed"
test -n "$(git -C "$SAME_DIR/lane$same_win/canon" ls-remote --heads origin "$same_win_br")" \
  && ok "the same-issue winner's remote branch is intact" || bad "the same-issue winner's remote branch was deleted"
# 0C, proven concurrently: agent-claimed is issue-wide, so the loser must not
# strip it off the winner just because it also added it.
contains "the loser left agent-claimed for the surviving sibling" \
  "$(cat "$SAME_DIR/labels-601" 2>/dev/null || echo '')" "agent-claimed"
contains "the loser says it left the label for a sibling" \
  "$(cat "$SAME_DIR/out$same_lose")" "surviving sibling claim(s)"

echo "#153 · the same race WITH --slice lets both disjoint lanes live"
SLICE_DIR="$ROOT/slicerace"
RACE_DIR="$SLICE_DIR"; export RACE_DIR
RACE_REPO="acme/slicerace"; export RACE_REPO
setup_race_repo "$SLICE_DIR" "$RACE_REPO" A B
SLICE_OLD_PATH="$PATH"
export PATH="$SLICE_DIR/bin:$PATH"
(cd "$SLICE_DIR/laneA/canon" && GIBSON_CANONICAL="$SLICE_DIR/laneA/canon" \
  "$CLAIM" 602 alpha 'lib/alpha/**' --slice >"$SLICE_DIR/outA" 2>&1) &
slice_pid_a=$!
(cd "$SLICE_DIR/laneB/canon" && GIBSON_CANONICAL="$SLICE_DIR/laneB/canon" \
  "$CLAIM" 602 beta 'lib/beta/**' --slice >"$SLICE_DIR/outB" 2>&1) &
slice_pid_b=$!
wait "$slice_pid_a"; slice_rc_a=$?
wait "$slice_pid_b"; slice_rc_b=$?
export PATH="$SLICE_OLD_PATH"
check "slice lane A survives" "$slice_rc_a" "0"
check "slice lane B survives" "$slice_rc_b" "0"
check "both slice claims are live" "$(grep -c . "$SLICE_DIR/prs" || true)" "2"
contains "the issue keeps agent-claimed" "$(cat "$SLICE_DIR/labels-602" 2>/dev/null || echo '')" "agent-claimed"

echo "#153 · --slice does NOT license overlapping scope, concurrently or not"
OVER_DIR="$ROOT/sliceover"
RACE_DIR="$OVER_DIR"; export RACE_DIR
RACE_REPO="acme/sliceover"; export RACE_REPO
setup_race_repo "$OVER_DIR" "$RACE_REPO" A B
OVER_OLD_PATH="$PATH"
export PATH="$OVER_DIR/bin:$PATH"
(cd "$OVER_DIR/laneA/canon" && GIBSON_CANONICAL="$OVER_DIR/laneA/canon" \
  "$CLAIM" 603 alpha 'lib/pay/**' --slice >"$OVER_DIR/outA" 2>&1) &
over_pid_a=$!
(cd "$OVER_DIR/laneB/canon" && GIBSON_CANONICAL="$OVER_DIR/laneB/canon" \
  "$CLAIM" 603 beta 'lib/pay/api.ts' --slice >"$OVER_DIR/outB" 2>&1) &
over_pid_b=$!
wait "$over_pid_a"; over_rc_a=$?
wait "$over_pid_b"; over_rc_b=$?
export PATH="$OVER_OLD_PATH"
over_winners=0
[[ "$over_rc_a" -eq 0 ]] && over_winners=$((over_winners + 1))
[[ "$over_rc_b" -eq 0 ]] && over_winners=$((over_winners + 1))
check "exactly one overlapping slice lane survives" "$over_winners" "1"
check "exactly one overlapping slice claim is live" "$(grep -c . "$OVER_DIR/prs" || true)" "1"
# And sequentially, a --slice with overlapping scope never gets in at all.
new_repo "$ROOT/sliceseq"
out=$(cd "$ROOT/sliceseq/canon" && "$CLAIM" 604 first 'lib/pay/**' 2>&1); rc=$?
check "the first slice claim lands" "$rc" "0"
out=$(cd "$ROOT/sliceseq/canon" && "$CLAIM" 604 second 'lib/pay/api.ts' --slice 2>&1); rc=$?
check    "a later --slice over the same files is refused" "$rc" "1"
contains "names the sibling it overlaps"                  "$out" "issue-604-first"

# ---------------------------------------------------------------------------
# #153 review P1 0C — label ownership and fail-closed reads
# ---------------------------------------------------------------------------
echo "#153 · an unreadable label state refuses BEFORE any mutation"
new_repo "$ROOT/labelfail"
mkdir -p "$ROOT/labelfail/bin"
cat > "$ROOT/labelfail/bin/gh" <<'LBLGH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") echo "gh: could not read labels (503)" >&2; exit 1 ;;
  "issue edit") echo "$*" >> "${GH_LOG:-/dev/null}" ;;
  "api graphql")
    # Empty answers for both list and list-open-numbers; never fall through.
    exit 0
    ;;
  "pr create") echo "https://github.com/acme/app/pull/5150" ;;
  "pr close") echo "closed $3" >> "${GH_CLOSE_LOG:-/dev/null}" ;;
  *)
    echo "fake gh (labelfail): unmodelled invocation 'gh $*' — refusing" >&2
    exit 64
    ;;
esac
exit 0
LBLGH
chmod +x "$ROOT/labelfail/bin/gh"
export GH_LOG="$ROOT/labelfail/label.log"
: > "$GH_LOG"
out=$(cd "$ROOT/labelfail/canon" && PATH="$ROOT/labelfail/bin:$PATH" \
  "$CLAIM" 78 unreadable 'lib/unreadable/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an unreadable label read refuses the claim" \
  || bad "an unreadable label read was treated as 'no labels' (rc=$rc): $out"
contains "says the label state was never read" "$out" "unread label state"
check "no label was edited on an unread state" "$(grep -c . "$GH_LOG" || true)" "0"
test ! -e "$ROOT/labelfail/wt-78-unreadable" \
  && ok "unreadable label state created no worktree" || bad "unreadable label state created a worktree"
unset GH_LOG

# --- #153 review round 3, P1: the create/rollback boundary -----------------
# Nothing may be destroyed until this lane's own claim PR is positively bound,
# positively closed, and FRESHLY proven no longer live. Each case below breaks
# exactly one of those three and asserts the same thing: everything survives,
# including the issue-wide label, and the run says why.
echo "#153 · a post-close reread that FAILS retains every artifact"
lag_fixture labelunread 91 "$LAG_RIVAL_ROW"
out=$(cd "$ROOT/labelunread/canon" && PATH="$ROOT/labelunread/bin:$PATH" \
  LAG_RIVAL_AFTER=1 LAG_BAD_AFTER_CLOSE=unreadable \
  GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=6 \
  "$CLAIM" 87 unreadinv 'lib/lag/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "the refused lane still exits nonzero" || bad "refused lane exited 0: $out"
contains "reports an incomplete rollback" "$out" "INCOMPLETE"
contains "names the unprovable close"     "$out" "could not be re-read to prove the claim is gone"
contains "keeps the worktree"             "$out" "labelunread/wt-87-unreadinv (kept:"
contains "keeps both branch refs"         "$out" "local and remote branch feat/87-unreadinv (kept:"
contains "keeps the issue-wide label"     "$out" "agent-claimed on #87 (kept:"
test -d "$ROOT/labelunread/wt-87-unreadinv" \
  && ok "the worktree really survives an unprovable close" || bad "the worktree was destroyed"
test -n "$(git -C "$ROOT/labelunread/canon" branch --list 'feat/87-unreadinv')" \
  && ok "the local branch really survives" || bad "the local branch was deleted"
test -n "$(git -C "$ROOT/labelunread/canon" ls-remote --heads origin 'feat/87-unreadinv')" \
  && ok "the remote branch really survives" || bad "the remote branch was deleted"
contains "the label really is still there" "$(cat "$ROOT/labelunread/state/labels")" "agent-claimed"
lacks "no label edit was even attempted" "$(grep -c -- '--remove-label' "$ROOT/labelunread/state/label.log" || echo 0)" "1"

echo "#153 · a post-close reread that returns MALFORMED rows retains every artifact"
lag_fixture labelbad 92 "$LAG_RIVAL_ROW"
out=$(cd "$ROOT/labelbad/canon" && PATH="$ROOT/labelbad/bin:$PATH" \
  LAG_RIVAL_AFTER=1 LAG_BAD_AFTER_CLOSE=malformed \
  GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=6 \
  "$CLAIM" 87 badinv 'lib/lag/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "the malformed-inventory lane exits nonzero" || bad "malformed inventory exited 0: $out"
contains "reports an incomplete rollback"  "$out" "INCOMPLETE"
contains "names the malformed evidence"    "$out" "malformed/truncated row"
test -d "$ROOT/labelbad/wt-87-badinv" \
  && ok "a malformed post-close read keeps the worktree" || bad "malformed read destroyed the worktree"
contains "the label survives the malformed read" "$(cat "$ROOT/labelbad/state/labels")" "agent-claimed"

echo "#153 · a FAILED gh pr close retains every artifact and names the live claim"
lag_fixture closefail 94 "$LAG_RIVAL_ROW"
# One surgical change to the fake: `pr close` reports failure. The PR therefore
# may still be open, so the claim may still be LIVE.
perl -0pi -e 's/  "pr close"\)\n/  "pr close")\n    if [[ -n "\${LAG_CLOSE_FAILS:-}" ]]; then echo "gh: could not close pull request (403)" >&2; exit 1; fi\n/' \
  "$ROOT/closefail/bin/gh"
out=$(cd "$ROOT/closefail/canon" && PATH="$ROOT/closefail/bin:$PATH" \
  LAG_RIVAL_AFTER=1 LAG_CLOSE_FAILS=1 \
  GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=6 \
  "$CLAIM" 87 closefail 'lib/lag/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a failed close exits nonzero" || bad "failed close exited 0: $out"
contains "reports an incomplete rollback" "$out" "INCOMPLETE"
contains "names the failed close"         "$out" "gh pr close failed"
contains "says the claim may still be live" "$out" "may still be LIVE"
test -d "$ROOT/closefail/wt-87-closefail" \
  && ok "a failed close keeps the worktree" || bad "a failed close destroyed the worktree"
test -n "$(git -C "$ROOT/closefail/canon" branch --list 'feat/87-closefail')" \
  && ok "a failed close keeps the local branch" || bad "a failed close deleted the local branch"
test -n "$(git -C "$ROOT/closefail/canon" ls-remote --heads origin 'feat/87-closefail')" \
  && ok "a failed close keeps the remote branch" || bad "a failed close deleted the remote branch"
contains "a failed close keeps agent-claimed" "$(cat "$ROOT/closefail/state/labels")" "agent-claimed"
lacks "a failed close never removes the issue-wide label" \
  "$(cat "$ROOT/closefail/state/label.log")" "--remove-label"

echo "#153 · close reports SUCCESS but the claim is still live: retain everything"
lag_fixture closelies 95 "$LAG_RIVAL_ROW"
# The fake accepts the close and reports success, but the claim never leaves the
# live inventory. A close that says it worked is not proof that it did.
perl -0pi -e 's/    rm -f "\$LAG_STATE\/self"\n/    [[ -n "\${LAG_CLOSE_LIES:-}" ]] || rm -f "\$LAG_STATE\/self"\n/' \
  "$ROOT/closelies/bin/gh"
out=$(cd "$ROOT/closelies/canon" && PATH="$ROOT/closelies/bin:$PATH" \
  LAG_RIVAL_AFTER=1 LAG_CLOSE_LIES=1 \
  GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=6 \
  "$CLAIM" 87 closelies 'lib/lag/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a lying close exits nonzero" || bad "lying close exited 0: $out"
contains "reports an incomplete rollback" "$out" "INCOMPLETE"
contains "names the still-live claim"     "$out" "STILL a live claim after gh pr close reported success"
test -d "$ROOT/closelies/wt-87-closelies" \
  && ok "a lying close keeps the worktree" || bad "a lying close destroyed the worktree"
test -n "$(git -C "$ROOT/closelies/canon" ls-remote --heads origin 'feat/87-closelies')" \
  && ok "a lying close keeps the remote branch" || bad "a lying close deleted the remote branch"
contains "a lying close keeps agent-claimed" "$(cat "$ROOT/closelies/state/labels")" "agent-claimed"

# ---------------------------------------------------------------------------
# #153 review round 5, P1 — rollback proves the close with the PR NUMBER
# ---------------------------------------------------------------------------
# `pr-claims.sh list` only lists a PR while that PR carries a well-formed claim
# marker, so "this lane's claim row is gone" is satisfied by a real close AND
# by a still-open PR whose marker was deleted or rewritten. rollback_pr used to
# accept that and go straight on to destroy the worktree, both branch refs and
# the issue-wide label behind a pull request that may still hold the issue.
# Every fixture below keeps the REAL artifacts claim.sh created (nothing is
# pre-deleted) and proves not one of them is touched.
echo "#153 round 5 · close succeeds, marker REMOVED, PR still open: retain everything"
lag_fixture numremoved 95 "$LAG_RIVAL_ROW"
out=$(cd "$ROOT/numremoved/canon" && PATH="$ROOT/numremoved/bin:$PATH" \
  LAG_RIVAL_AFTER=1 LAG_STILL_OPEN_AFTER_CLOSE=1 \
  GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=6 \
  "$CLAIM" 87 numremoved 'lib/lag/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a removed marker on a still-open PR exits nonzero" \
  || bad "removed marker exited 0: $out"
contains "reports an incomplete rollback"      "$out" "INCOMPLETE"
contains "names the PR that is still open"     "$out" "PR #95 (kept: it is STILL OPEN in acme/app"
contains "names the removed/rewritten marker"  "$out" "a removed or rewritten marker is not a closed PR"
test -d "$ROOT/numremoved/wt-87-numremoved" \
  && ok "removed marker keeps the worktree" || bad "removed marker destroyed the worktree"
test -n "$(git -C "$ROOT/numremoved/canon" branch --list 'feat/87-numremoved')" \
  && ok "removed marker keeps the local branch" || bad "removed marker deleted the local branch"
test -n "$(git -C "$ROOT/numremoved/canon" ls-remote --heads origin 'feat/87-numremoved')" \
  && ok "removed marker keeps the remote branch" || bad "removed marker deleted the remote branch"
contains "removed marker keeps agent-claimed" "$(cat "$ROOT/numremoved/state/labels")" "agent-claimed"
lacks "removed marker never edits the issue-wide label away" \
  "$(cat "$ROOT/numremoved/state/label.log")" "--remove-label"

echo "#153 round 5 · close succeeds, marker REWRITTEN to another claim, PR still open"
lag_fixture numrewritten 96 "$LAG_RIVAL_ROW"
out=$(cd "$ROOT/numrewritten/canon" && PATH="$ROOT/numrewritten/bin:$PATH" \
  LAG_RIVAL_AFTER=1 LAG_STILL_OPEN_AFTER_CLOSE=1 LAG_CLOSE_REWRITES=1 \
  GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=6 \
  "$CLAIM" 87 numrewritten 'lib/lag/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a rewritten marker on a still-open PR exits nonzero" \
  || bad "rewritten marker exited 0: $out"
contains "reports an incomplete rollback"  "$out" "INCOMPLETE"
contains "names the PR that is still open" "$out" "PR #96 (kept: it is STILL OPEN in acme/app"
test -d "$ROOT/numrewritten/wt-87-numrewritten" \
  && ok "rewritten marker keeps the worktree" || bad "rewritten marker destroyed the worktree"
test -n "$(git -C "$ROOT/numrewritten/canon" branch --list 'feat/87-numrewritten')" \
  && ok "rewritten marker keeps the local branch" || bad "rewritten marker deleted the local branch"
test -n "$(git -C "$ROOT/numrewritten/canon" ls-remote --heads origin 'feat/87-numrewritten')" \
  && ok "rewritten marker keeps the remote branch" || bad "rewritten marker deleted the remote branch"
contains "rewritten marker keeps agent-claimed" "$(cat "$ROOT/numrewritten/state/labels")" "agent-claimed"
lacks "rewritten marker never edits the issue-wide label away" \
  "$(cat "$ROOT/numrewritten/state/label.log")" "--remove-label"

echo "#153 round 5 · an UNREADABLE open-PR inventory is not proof the close worked"
lag_fixture numunread 97 "$LAG_RIVAL_ROW"
out=$(cd "$ROOT/numunread/canon" && PATH="$ROOT/numunread/bin:$PATH" \
  LAG_RIVAL_AFTER=1 LAG_OPEN_NUMBERS_EXIT=1 \
  GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=6 \
  "$CLAIM" 87 numunread 'lib/lag/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an unreadable open-PR inventory exits nonzero" \
  || bad "unreadable open-PR inventory exited 0: $out"
contains "reports an incomplete rollback" "$out" "INCOMPLETE"
contains "names the unreadable inventory" "$out" "open pull-request inventory for acme/app is unreadable"
test -d "$ROOT/numunread/wt-87-numunread" \
  && ok "an unreadable open-PR inventory keeps the worktree" \
  || bad "unreadable open-PR inventory destroyed the worktree"
test -n "$(git -C "$ROOT/numunread/canon" ls-remote --heads origin 'feat/87-numunread')" \
  && ok "an unreadable open-PR inventory keeps the remote branch" \
  || bad "unreadable open-PR inventory deleted the remote branch"
contains "an unreadable open-PR inventory keeps agent-claimed" \
  "$(cat "$ROOT/numunread/state/labels")" "agent-claimed"

echo "#153 round 5 · a FORK row carrying this lane's claim is never closed"
# This lane pushed feat/87-forkrow into acme/app itself, so its own claim PR is
# same-repository by construction. A row that says isCrossRepository=true is
# not this lane's PR however well its marker and branch name match — and
# `gh pr close` is irreversible.
lag_fixture forkrow 98 "$LAG_RIVAL_ROW"
out=$(cd "$ROOT/forkrow/canon" && PATH="$ROOT/forkrow/bin:$PATH" \
  LAG_RIVAL_AFTER=1 LAG_SELF_CROSS=true \
  GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=6 \
  "$CLAIM" 87 forkrow 'lib/lag/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a fork row for this lane's claim exits nonzero" \
  || bad "fork row exited 0: $out"
contains "admission refuses the foreign-repository row" "$out" "cross-repository (fork) pull request"
contains "rollback refuses to close it"                 "$out" "not provably a same-repository pull request"
check "the fork row's PR was never closed" "$(grep -c . "$ROOT/forkrow/state/close.log" || true)" "0"
test -d "$ROOT/forkrow/wt-87-forkrow" \
  && ok "a fork row keeps the worktree" || bad "fork row destroyed the worktree"
test -n "$(git -C "$ROOT/forkrow/canon" ls-remote --heads origin 'feat/87-forkrow')" \
  && ok "a fork row keeps the remote branch" || bad "fork row deleted the remote branch"
contains "a fork row keeps agent-claimed" "$(cat "$ROOT/forkrow/state/labels")" "agent-claimed"

echo "#153 · a successful create whose output is UNPARSEABLE never destroys anything"
# gh exits 0 and prints something this cannot parse into a PR number, and the
# PR is not (yet) visible in the live inventory. The claim may exist and be
# unpublished, so absence from an eventually consistent view proves nothing.
new_repo "$ROOT/prgarbage"
mkdir -p "$ROOT/prgarbage/bin"
cat > "$ROOT/prgarbage/bin/gh" <<'PGGH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") cat "${GH_LABELS_FILE:-/dev/null}" 2>/dev/null || echo "" ;;
  "issue edit") echo "$*" >> "${GH_LOG:-/dev/null}" ;;
  # The PR is created but is not published to the open inventory yet.
  # Empty for list and list-open-numbers alike; never read stdin.
  "api graphql") exit 0 ;;
  "pr create") echo "Warning: 1 uncommitted change"; echo "Creating draft pull request for feat/x into main in acme/app" ;;
  "pr close") echo "closed $3" >> "${GH_CLOSE_LOG:-/dev/null}" ;;
  *)
    echo "fake gh (prgarbage): unmodelled invocation 'gh $*' — refusing" >&2
    exit 64
    ;;
esac
exit 0
PGGH
chmod +x "$ROOT/prgarbage/bin/gh"
export GH_LOG="$ROOT/prgarbage/label.log"
export GH_CLOSE_LOG="$ROOT/prgarbage/close.log"
: > "$GH_LOG"; : > "$GH_CLOSE_LOG"
out=$(cd "$ROOT/prgarbage/canon" && PATH="$ROOT/prgarbage/bin:$PATH" \
  "$CLAIM" 96 garbled 'lib/garbled/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an unparseable create exits nonzero" || bad "unparseable create exited 0: $out"
contains "reports an incomplete rollback" "$out" "INCOMPLETE"
contains "names the unparseable output"   "$out" "could not be parsed into a PR number"
contains "says the PR may exist"          "$out" "may exist and be unpublished"
test -d "$ROOT/prgarbage/wt-96-garbled" \
  && ok "an unparseable create keeps the worktree" || bad "unparseable create destroyed the worktree"
test -n "$(git -C "$ROOT/prgarbage/canon" branch --list 'feat/96-garbled')" \
  && ok "an unparseable create keeps the local branch" || bad "unparseable create deleted the local branch"
test -n "$(git -C "$ROOT/prgarbage/canon" ls-remote --heads origin 'feat/96-garbled')" \
  && ok "an unparseable create keeps the remote branch" || bad "unparseable create deleted the remote branch"
lacks "an unparseable create never removes the issue-wide label" "$(cat "$GH_LOG")" "--remove-label"
check "an unparseable create closes nothing blindly" "$(grep -c . "$GH_CLOSE_LOG" || true)" "0"
unset GH_LOG GH_CLOSE_LOG

echo "#153 · a successful create whose output is unparseable but whose PR IS visible is bound and closed"
# Same failure, better evidence: the inventory shows the PR, so rollback can
# bind it by exact claim id AND head branch, close it, and prove it gone —
# and only then is it allowed to clean up.
new_repo "$ROOT/prfound"
mkdir -p "$ROOT/prfound/bin"
cat > "$ROOT/prfound/bin/gh" <<'PFGH'
#!/usr/bin/env bash
STATE="${PF_STATE:?}"
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") cat "$STATE/labels" 2>/dev/null || echo "" ;;
  "issue edit")
    echo "$*" >> "$STATE/label.log"
    if echo "$*" | grep -q -- '--add-label'; then echo "agent-claimed" > "$STATE/labels"
    elif echo "$*" | grep -q -- '--remove-label'; then : > "$STATE/labels"; fi
    ;;
  "api graphql")
    # `list-open-numbers` (operation openPrNumbers) also carries
    # `states: [OPEN]`, so match it first. It is body-agnostic and derived
    # from the same store, so a PR that `pr close` removed is gone from it too.
    want_numbers=0
    for a in "$@"; do case "$a" in *"openPrNumbers"*) want_numbers=1 ;; esac; done
    if [[ "$want_numbers" -eq 1 ]]; then
      cut -f1 "$STATE/open" 2>/dev/null | grep -E '^[0-9]+$' || true
      exit 0
    fi
    want_open=0
    for a in "$@"; do case "$a" in *"states: [OPEN]"*) want_open=1 ;; esac; done
    [[ "$want_open" -eq 1 ]] || exit 0
    cat "$STATE/open" 2>/dev/null
    exit 0
    ;;
  "pr create")
    branch=""
    while [[ $# -gt 0 ]]; do case "$1" in --head) branch="$2"; shift 2 ;; *) shift ;; esac; done
    printf '4242\tissue-97-found\tlib/found/**\t%s\thttps://github.com/acme/app/pull/4242\t2026-08-09T00:00:00Z\t2026-08-09T00:00:00Z\tfalse\n' \
      "$branch" > "$STATE/open"
    echo "the pull request was created, somewhere"
    ;;
  "pr close")
    echo "closed $3" >> "$STATE/close.log"
    : > "$STATE/open"
    ;;
  *)
    echo "fake gh (prfound): unmodelled invocation 'gh $*' — refusing" >&2
    exit 64
    ;;
esac
exit 0
PFGH
chmod +x "$ROOT/prfound/bin/gh"
export PF_STATE="$ROOT/prfound/state"
mkdir -p "$PF_STATE"; : > "$PF_STATE/labels"; : > "$PF_STATE/label.log"; : > "$PF_STATE/close.log"; : > "$PF_STATE/open"
out=$(cd "$ROOT/prfound/canon" && PATH="$ROOT/prfound/bin:$PATH" \
  "$CLAIM" 97 found 'lib/found/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an unparseable-but-visible create still exits nonzero" || bad "exited 0: $out"
contains "binds and closes the discovered PR" "$out" "closed this lane's own PR #4242"
contains "the fake really saw the close" "$(cat "$PF_STATE/close.log")" "closed 4242"
lacks "a proven close is not an incomplete rollback" "$out" "INCOMPLETE"
test ! -e "$ROOT/prfound/wt-97-found" \
  && ok "only a proven-closed PR licenses worktree removal" || bad "the worktree survived a proven close"
test -z "$(git -C "$ROOT/prfound/canon" ls-remote --heads origin 'feat/97-found')" \
  && ok "only a proven-closed PR licenses branch removal" || bad "the remote branch survived a proven close"
lacks "and the issue-wide label is released" "$(cat "$PF_STATE/labels")" "agent-claimed"
unset PF_STATE

echo "#153 · rollback refuses to close a PR that is not provably this lane's"
new_repo "$ROOT/prforeign"
mkdir -p "$ROOT/prforeign/bin"
cat > "$ROOT/prforeign/bin/gh" <<'XFGH'
#!/usr/bin/env bash
STATE="${XF_STATE:?}"
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") cat "$STATE/labels" 2>/dev/null || echo "" ;;
  "issue edit")
    echo "$*" >> "$STATE/label.log"
    if echo "$*" | grep -q -- '--add-label'; then echo "agent-claimed" > "$STATE/labels"
    elif echo "$*" | grep -q -- '--remove-label'; then : > "$STATE/labels"; fi
    ;;
  "api graphql")
    # `list-open-numbers` (operation openPrNumbers) also carries
    # `states: [OPEN]`, so match it first. It is body-agnostic and derived
    # from the same store, so a PR that `pr close` removed is gone from it too.
    want_numbers=0
    for a in "$@"; do case "$a" in *"openPrNumbers"*) want_numbers=1 ;; esac; done
    if [[ "$want_numbers" -eq 1 ]]; then
      cut -f1 "$STATE/open" 2>/dev/null | grep -E '^[0-9]+$' || true
      exit 0
    fi
    want_open=0
    for a in "$@"; do case "$a" in *"states: [OPEN]"*) want_open=1 ;; esac; done
    [[ "$want_open" -eq 1 ]] || exit 0
    cat "$STATE/open" 2>/dev/null
    exit 0
    ;;
  "pr create")
    # Someone else's PR happens to hold the number this lane is told it got.
    printf '5150\tissue-98-someone-else\tlib/other/**\tfeat/98-someone-else\thttps://github.com/acme/app/pull/5150\t2026-08-09T00:00:00Z\t2026-08-09T00:00:00Z\tfalse\n' \
      > "$STATE/open"
    echo "https://github.com/acme/app/pull/5150"
    ;;
  "pr close") echo "closed $3" >> "$STATE/close.log" ;;
  *)
    echo "fake gh (prforeign): unmodelled invocation 'gh $*' — refusing" >&2
    exit 64
    ;;
esac
exit 0
XFGH
chmod +x "$ROOT/prforeign/bin/gh"
export XF_STATE="$ROOT/prforeign/state"
mkdir -p "$XF_STATE"; : > "$XF_STATE/labels"; : > "$XF_STATE/label.log"; : > "$XF_STATE/close.log"; : > "$XF_STATE/open"
out=$(cd "$ROOT/prforeign/canon" && PATH="$ROOT/prforeign/bin:$PATH" \
  "$CLAIM" 99 mine 'lib/mine/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a foreign PR on this lane's number exits nonzero" || bad "exited 0: $out"
contains "reports an incomplete rollback" "$out" "INCOMPLETE"
contains "refuses to close it"            "$out" "not provably this lane's"
check "and never called gh pr close" "$(grep -c . "$XF_STATE/close.log" || true)" "0"
test -d "$ROOT/prforeign/wt-99-mine" \
  && ok "a foreign-PR match keeps the worktree" || bad "a foreign-PR match destroyed the worktree"
contains "a foreign-PR match keeps agent-claimed" "$(cat "$XF_STATE/labels")" "agent-claimed"
unset XF_STATE

echo "#153 · rollback reports an already-absent label instead of failing on it"
lag_fixture labelgone 93 "$LAG_RIVAL_ROW"
# The label edit is accepted but never actually lands (the issue is edited by
# someone else in the same breath); rollback must notice and say so, not treat
# a missing label as an error or as work still to do.
: > "$ROOT/labelgone/state/labels"
cat > "$ROOT/labelgone/bin/gh.wrap" <<'WRAPGH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue edit")
    # Swallow the add: the label never appears.
    echo "$*" >> "$LAG_STATE/label.log"
    exit 0
    ;;
esac
exec "$LAG_REAL_GH" "$@"
WRAPGH
chmod +x "$ROOT/labelgone/bin/gh.wrap"
mv "$ROOT/labelgone/bin/gh" "$ROOT/labelgone/bin/gh.real"
mv "$ROOT/labelgone/bin/gh.wrap" "$ROOT/labelgone/bin/gh"
export LAG_REAL_GH="$ROOT/labelgone/bin/gh.real"
out=$(cd "$ROOT/labelgone/canon" && PATH="$ROOT/labelgone/bin:$PATH" \
  LAG_RIVAL_AFTER=1 GIBSON_CLAIM_ADMIT_STABLE_READS=2 GIBSON_CLAIM_ADMIT_ATTEMPTS=6 \
  "$CLAIM" 87 labelgone 'lib/lag/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "the refused lane exits nonzero with no label to remove" || bad "exited 0: $out"
contains "says the label was already absent" "$out" "already absent"
lacks "an absent label is not an incomplete rollback" "$out" "INCOMPLETE"
unset LAG_REAL_GH

# ---------------------------------------------------------------------------
# #153 review P1 0D — rollback never destroys work it cannot prove is its own
# ---------------------------------------------------------------------------
# Every case below runs against the blind-inventory fake, so the lane is
# guaranteed to reach rollback, and the fixture mutates the worktree or a
# branch in exactly the window rollback leaves open — between closing this
# lane's own claim PR and proving the worktree/branches safe to remove.
#
# The mutation is baked into the FAKE gh's `pr close` arm, generated per case.
# It used to be an executable named by GIBSON_CLAIM_TEST_ROLLBACK_HOOK that
# production ran; an environment variable naming a command IS an execution
# path, however it is documented, so that hook is gone (#153 review round 3,
# P1). A fake dependency doing deterministic things when the script calls it
# needs no cooperation from the script at all.
rollback_fixture() { # dir issue slug side-effect-body
  local dir="$1" rb_issue="$2" rb_slug="$3" side="$4"
  new_repo "$ROOT/$dir"
  mkdir -p "$ROOT/$dir/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'CANON=%q\n' "$ROOT/$dir/canon"
    printf 'WT=%q\n' "$ROOT/$dir/wt-${rb_issue}-${rb_slug}"
    printf 'BR=%q\n' "feat/${rb_issue}-${rb_slug}"
    cat <<'RBGH'
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") cat "${GH_LABELS_FILE:-/dev/null}" 2>/dev/null || echo "" ;;
  "issue edit") echo "$*" >> "${GH_LOG:-/dev/null}" ;;
  "api graphql") : ;;
  "pr create") echo "https://github.com/acme/app/pull/7777" ;;
  "pr close")
    echo "closed $3" >> "${GH_CLOSE_LOG:-/dev/null}"
RBGH
    printf '%s\n' "$side"
    cat <<'RBGH2'
    ;;
esac
exit 0
RBGH2
  } > "$ROOT/$dir/bin/gh"
  chmod +x "$ROOT/$dir/bin/gh"
}

run_rollback_case() { # dir issue slug
  (cd "$ROOT/$1/canon" && PATH="$ROOT/$1/bin:$PATH" \
    GIBSON_CLAIM_ADMIT_ATTEMPTS=2 \
    "$CLAIM" "$2" "$3" "lib/$3/**" 2>&1)
}

echo "#153 · rollback refuses to destroy a worktree that went dirty"
rollback_fixture rbdirty 81 dirty 'echo "uncommitted" > "$WT/NOTES.md"'
out=$(run_rollback_case rbdirty 81 dirty); rc=$?
[[ "$rc" -ne 0 ]] && ok "dirty-worktree rollback exits nonzero" || bad "dirty rollback exited 0: $out"
contains "reports an incomplete rollback"    "$out" "INCOMPLETE"
contains "names the uncommitted work"        "$out" "uncommitted or untracked work"
test -e "$ROOT/rbdirty/wt-81-dirty/NOTES.md" \
  && ok "the dirty worktree and its file survive" || bad "the dirty worktree was destroyed"
test -n "$(git -C "$ROOT/rbdirty/canon" branch --list 'feat/81-dirty')" \
  && ok "a kept worktree keeps its local branch" || bad "the local branch was deleted under a kept worktree"
test -n "$(git -C "$ROOT/rbdirty/canon" ls-remote --heads origin 'feat/81-dirty')" \
  && ok "a kept worktree keeps its remote branch" || bad "the remote branch was deleted under a kept worktree"
contains "names the branches it kept" "$out" "the worktree could not be proven safe to remove"

echo "#153 · rollback refuses to delete a local branch that advanced"
rollback_fixture rbladv 82 localadv '
git -C "$CANON" worktree remove "$WT" >/dev/null 2>&1
git -C "$CANON" update-ref "refs/heads/$BR" "$(git -C "$CANON" rev-parse origin/main)"
'
out=$(run_rollback_case rbladv 82 localadv); rc=$?
[[ "$rc" -ne 0 ]] && ok "advanced-local rollback exits nonzero" || bad "advanced-local rollback exited 0: $out"
contains "reports an incomplete rollback"        "$out" "INCOMPLETE"
contains "names the advanced local branch"       "$out" "local branch feat/82-localadv"
test -n "$(git -C "$ROOT/rbladv/canon" branch --list 'feat/82-localadv')" \
  && ok "the advanced local branch survives" || bad "the advanced local branch was deleted"
contains "the remote branch was left alone too"  "$out" "the local branch delete was refused first"
test -n "$(git -C "$ROOT/rbladv/canon" ls-remote --heads origin 'feat/82-localadv')" \
  && ok "the remote branch survives an advanced local branch" || bad "publish-deleted over surviving local work"

echo "#153 · rollback refuses to delete a remote branch that advanced"
rollback_fixture rbradv 83 remoteadv '
git -C "$CANON" push -q -f origin "$(git -C "$CANON" rev-parse origin/main):refs/heads/$BR"
'
out=$(run_rollback_case rbradv 83 remoteadv); rc=$?
[[ "$rc" -ne 0 ]] && ok "advanced-remote rollback exits nonzero" || bad "advanced-remote rollback exited 0: $out"
contains "reports an incomplete rollback"   "$out" "INCOMPLETE"
contains "names the advanced remote branch" "$out" "remote branch feat/83-remoteadv"
test -n "$(git -C "$ROOT/rbradv/canon" ls-remote --heads origin 'feat/83-remoteadv')" \
  && ok "the advanced remote branch survives" || bad "the advanced remote branch was deleted"

echo "#153 · rollback refuses a worktree that is no longer on this lane's branch"
rollback_fixture rbswitch 84 switched 'git -C "$WT" checkout -q -b someone-elses-work'
out=$(run_rollback_case rbswitch 84 switched); rc=$?
[[ "$rc" -ne 0 ]] && ok "re-branched-worktree rollback exits nonzero" || bad "re-branched rollback exited 0: $out"
contains "reports an incomplete rollback" "$out" "INCOMPLETE"
contains "says git no longer vouches for it" "$out" "no longer a registered worktree on branch"
test -d "$ROOT/rbswitch/wt-84-switched" \
  && ok "the re-branched worktree survives" || bad "the re-branched worktree was destroyed"
test -n "$(git -C "$ROOT/rbswitch/canon" branch --list 'feat/84-switched')" \
  && ok "the re-branched worktree keeps its branch" || bad "the branch was deleted under a re-branched worktree"

echo "#153 · rollback names a remote it cannot even verify, rather than assuming"
rollback_fixture rbunreach 85 unreachable 'git -C "$CANON" remote set-url origin "$CANON/../no-such-origin"'
out=$(run_rollback_case rbunreach 85 unreachable); rc=$?
[[ "$rc" -ne 0 ]] && ok "unverifiable-remote rollback exits nonzero" || bad "unverifiable-remote rollback exited 0: $out"
contains "reports an incomplete rollback"    "$out" "INCOMPLETE"
contains "names the remote it could not verify" "$out" "cannot verify it before deletion"

echo "#153 · a clean rollback still reports no leftovers"
rollback_fixture rbclean 86 cleanroll ':'
out=$(run_rollback_case rbclean 86 cleanroll); rc=$?
[[ "$rc" -ne 0 ]] && ok "a clean rollback still exits nonzero" || bad "clean rollback exited 0: $out"
lacks "a clean rollback is not INCOMPLETE" "$out" "INCOMPLETE"
test ! -e "$ROOT/rbclean/wt-86-cleanroll" \
  && ok "a clean rollback removes its own worktree" || bad "clean rollback left its worktree"
test -z "$(git -C "$ROOT/rbclean/canon" branch --list 'feat/86-cleanroll')" \
  && ok "a clean rollback deletes its own local branch" || bad "clean rollback left its local branch"
test -z "$(git -C "$ROOT/rbclean/canon" ls-remote --heads origin 'feat/86-cleanroll')" \
  && ok "a clean rollback deletes its own remote branch" || bad "clean rollback left its remote branch"

# ---------------------------------------------------------------------------
# #153 review round 3, P1 — production runs no inherited test-hook command
# ---------------------------------------------------------------------------
echo "#153 · production never executes a command named by an inherited variable"
# The removed hooks, set to an executable sentinel. If any production code path
# still runs one, the sentinel leaves a marker. This is the regression sensor
# for the hooks themselves, not for what they used to simulate — the behaviour
# they simulated is covered above by the fake-gh fixtures.
SENTINEL_DIR="$ROOT/sentinel"
mkdir -p "$SENTINEL_DIR"
cat > "$SENTINEL_DIR/run" <<SENT
#!/usr/bin/env bash
echo "EXECUTED \$0 \$*" >> "$SENTINEL_DIR/fired"
exit 0
SENT
chmod +x "$SENTINEL_DIR/run"
: > "$SENTINEL_DIR/fired"
rollback_fixture hooksentinel 79 sentinel ':'
out=$(cd "$ROOT/hooksentinel/canon" && PATH="$ROOT/hooksentinel/bin:$PATH" \
  GIBSON_CLAIM_TEST_ROLLBACK_HOOK="$SENTINEL_DIR/run" \
  RELEASE_CLAIM_TEST_DIRTY_HOOK="$SENTINEL_DIR/run" \
  RELEASE_CLAIM_TEST_LOCAL_ADVANCE_HOOK="$SENTINEL_DIR/run" \
  RELEASE_CLAIM_TEST_REMOTE_ADVANCE_HOOK="$SENTINEL_DIR/run" \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=2 "$CLAIM" 79 sentinel 'lib/sentinel/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "the sentinel run still reached rollback" || bad "sentinel run exited 0: $out"
check "no removed hook was executed by claim.sh" "$(grep -c . "$SENTINEL_DIR/fired" || true)" "0"
for v in GIBSON_CLAIM_TEST_ROLLBACK_HOOK RELEASE_CLAIM_TEST_DIRTY_HOOK \
         RELEASE_CLAIM_TEST_LOCAL_ADVANCE_HOOK RELEASE_CLAIM_TEST_REMOTE_ADVANCE_HOOK; do
  if grep -q "$v" "$SCRIPT_DIR/../claim.sh" "$SCRIPT_DIR/../release-claim.sh"; then
    bad "$v is still referenced in production code"
  else
    ok "$v is gone from production code"
  fi
done
# And the general shape: no production claim/release script may execute a
# command taken from an environment variable.
for prod in "$SCRIPT_DIR/../claim.sh" "$SCRIPT_DIR/../release-claim.sh" "$SCRIPT_DIR/../pr-claims.sh"; do
  if grep -nE '^[[:space:]]*"\$\{?[A-Z_]*(HOOK|CMD|EXEC)[A-Z_]*' "$prod" >/dev/null; then
    bad "$(basename "$prod") executes a command named by an environment variable"
  else
    ok "$(basename "$prod") executes no environment-named command"
  fi
done

# ---------------------------------------------------------------------------
# #153 review round 3, P1 — no node, and no unreadable read, means NO mutation
# ---------------------------------------------------------------------------
echo "#153 · a host without node refuses BEFORE any mutation"
new_repo "$ROOT/nonode"
mkdir -p "$ROOT/nonode/bin"
cat > "$ROOT/nonode/bin/gh" <<'NNGH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") echo "" ;;
  "issue edit") echo "$*" >> "${GH_LOG:-/dev/null}" ;;
  "api graphql") exit 0 ;;
  "pr create") echo "$*" >> "${GH_LOG:-/dev/null}"; echo "https://github.com/acme/app/pull/1234" ;;
  "pr close") echo "$*" >> "${GH_LOG:-/dev/null}" ;;
  *)
    echo "fake gh (nonode): unmodelled invocation 'gh $*' — refusing" >&2
    exit 64
    ;;
esac
exit 0
NNGH
chmod +x "$ROOT/nonode/bin/gh"
export GH_LOG="$ROOT/nonode/gh.log"
: > "$GH_LOG"
# A PATH with git and the fake gh, and deliberately without node.
NONODE_PATH="$ROOT/nonode/bin:$(dirname "$(command -v git)"):/usr/bin:/bin"
if PATH="$NONODE_PATH" command -v node >/dev/null 2>&1; then
  echo "  note — node is reachable from the restricted PATH on this host; using a static contract check instead"
  if grep -q 'node required — scope-overlap.mjs is the authoritative' "$CLAIM" &&
     grep -q 'command -v node >/dev/null ||' "$CLAIM"; then
    ok "claim.sh requires node before any mutation (source contract)"
  else
    bad "claim.sh no longer requires node before mutating"
  fi
else
  out=$(cd "$ROOT/nonode/canon" && PATH="$NONODE_PATH" "$CLAIM" 71 nonode 'lib/nonode/**' 2>&1); rc=$?
  [[ "$rc" -ne 0 ]] && ok "a host without node refuses the claim" || bad "claimed without node (rc=$rc): $out"
  contains "says why node is required" "$out" "node required"
  check "no gh mutation was attempted at all" "$(grep -c . "$GH_LOG" || true)" "0"
  test ! -e "$ROOT/nonode/wt-71-nonode" \
    && ok "no node means no worktree" || bad "a nodeless run created a worktree"
  test -z "$(git -C "$ROOT/nonode/canon" branch --list 'feat/71-nonode')" \
    && ok "no node means no branch" || bad "a nodeless run created a branch"
fi
# The fallback that used to run instead of node is gone from the source: an
# admission decision must not have a weaker second implementation.
lacks "no stem-grep overlap fallback survives" "$(cat "$CLAIM")" "legacy_scope_overlap"
lacks "no swallowed pr-claims read survives"   "$(cat "$CLAIM")" 'pr-claims.sh" list "$REPO" 2>/dev/null'
unset GH_LOG

echo "#153 · an unreadable claim inventory refuses BEFORE any mutation"
new_repo "$ROOT/readfail"
mkdir -p "$ROOT/readfail/bin"
cat > "$ROOT/readfail/bin/gh" <<'RFGH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") echo "" ;;
  "api graphql") echo "gh: API rate limit exceeded" >&2; exit 1 ;;
  *) echo "$*" >> "${GH_LOG:-/dev/null}" ;;
esac
exit 0
RFGH
chmod +x "$ROOT/readfail/bin/gh"
export GH_LOG="$ROOT/readfail/gh.log"
: > "$GH_LOG"
out=$(cd "$ROOT/readfail/canon" && PATH="$ROOT/readfail/bin:$PATH" \
  "$CLAIM" 72 readfail 'lib/readfail/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an unreadable inventory refuses the claim" || bad "claimed on an unread inventory (rc=$rc): $out"
contains "says the inventory was never read" "$out" "unreadable"
contains "never treats unreadable as empty"  "$out" "a view that was never read"
check "no gh mutation was attempted at all" "$(grep -c . "$GH_LOG" || true)" "0"
test ! -e "$ROOT/readfail/wt-72-readfail" \
  && ok "an unreadable inventory creates no worktree" || bad "an unreadable inventory created a worktree"
test -z "$(git -C "$ROOT/readfail/canon" branch --list 'feat/72-readfail')" \
  && ok "an unreadable inventory creates no branch" || bad "an unreadable inventory created a branch"
test -z "$(git -C "$ROOT/readfail/canon" ls-remote --heads origin 'feat/72-readfail')" \
  && ok "an unreadable inventory pushes nothing" || bad "an unreadable inventory pushed a branch"
unset GH_LOG

echo "#153 · a MALFORMED claim inventory row refuses BEFORE any mutation"
new_repo "$ROOT/rowfail"
mkdir -p "$ROOT/rowfail/bin"
cat > "$ROOT/rowfail/bin/gh" <<'RWGH'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "issue view") echo "" ;;
  "api graphql") printf 'truncated\trow\n' ;;
  *) echo "$*" >> "${GH_LOG:-/dev/null}" ;;
esac
exit 0
RWGH
chmod +x "$ROOT/rowfail/bin/gh"
export GH_LOG="$ROOT/rowfail/gh.log"
: > "$GH_LOG"
out=$(cd "$ROOT/rowfail/canon" && PATH="$ROOT/rowfail/bin:$PATH" \
  "$CLAIM" 73 rowfail 'lib/rowfail/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a malformed inventory row refuses the claim" || bad "claimed on a malformed inventory (rc=$rc): $out"
contains "names the malformed row" "$out" "malformed/truncated row"
check "no gh mutation was attempted at all" "$(grep -c . "$GH_LOG" || true)" "0"
test ! -e "$ROOT/rowfail/wt-73-rowfail" \
  && ok "a malformed inventory creates no worktree" || bad "a malformed inventory created a worktree"
unset GH_LOG

# ---------------------------------------------------------------------------
# #153 review round 4, P1 — an unreadable ledger refuses BEFORE any mutation
# ---------------------------------------------------------------------------
# scope-overlap.mjs is read-only, so "fail closed" only means anything if the
# CALLER has not mutated yet when it refuses. claim.sh runs the overlap check
# before the label, the branch, the PR and the worktree exist, and this pins
# that end to end: the ledger read that fails here is one only the sensor
# takes (claim.sh never reads a claim file's body), so the refusal is
# provably the sensor's, and nothing was created by the time it happened.
echo "#153 round 4 · a live claim with unreadable scope refuses the claim before anything is created"
# The unsafe result this reverses: a live claim file with no `scope:` line
# used to become a claim with an EMPTY scope, which collides with nothing, so
# the overlap check said OK and claim.sh went on to add the label, push a
# branch, open a PR and create a worktree against a lane whose files it could
# not see. Now the missing metadata poisons the decision — and because the
# overlap check runs before the first mutation, refusing there means nothing
# was created at all.
new_repo "$ROOT/ledgerfail"
export GH_LOG="$ROOT/ledgerfail/gh.log"
: > "$GH_LOG"
(
  cd "$ROOT/ledgerfail/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  # A real live claim — but its scope is unreadable.
  printf 'claim: issue-95-other-lane\nissue: 95\nclaimed: 2026-08-01T00:00:00Z\nsession: other@fleet\n' \
    > docs/claims/issue-95-other-lane.md
  git add -A && git commit -qm "claim with unreadable scope" && git push -q origin main
) >/dev/null 2>&1
out=$(cd "$ROOT/ledgerfail/canon" && "$CLAIM" 96 blocked 'lib/blocked/**' 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "a live claim with no readable scope refuses the claim" \
  || bad "claimed past a live claim whose scope could not be read (rc=$rc): $out"
contains "names the ledger as the reason" "$out" "scope overlap (or ledger unreadable)"
contains "the sensor named the unreadable claim" "$out" "issue-95-other-lane"
contains "and said the metadata poisons it"      "$out" "must poison the decision"
check "no gh mutation was attempted"      "$(grep -c . "$GH_LOG" || true)" "0"
test ! -e "$ROOT/ledgerfail/wt-96-blocked" \
  && ok "an unreadable scope creates no worktree" || bad "an unreadable scope created a worktree"
test -z "$(git -C "$ROOT/ledgerfail/canon" branch --list 'feat/96-blocked')" \
  && ok "an unreadable scope creates no local branch" || bad "an unreadable scope created a local branch"
test -z "$(git -C "$ROOT/ledgerfail/canon" ls-remote --heads origin 'feat/96-blocked')" \
  && ok "an unreadable scope pushes no remote branch" || bad "an unreadable scope pushed a remote branch"
check "an unreadable scope opens no PR" "$(grep -c 'issue-96-blocked' "$GH_PR_FILE" || true)" "0"
unset GH_LOG

# ---------------------------------------------------------------------------
# #153 review round 4, P1 — the REAL toolchain, the REAL barrier
# ---------------------------------------------------------------------------
# Everything above ran the patched test copy, so exactly one sensor here runs
# the shipped claim.sh end to end and pays the real minimum wait. Its job is to
# prove that the acceleration the other fixtures enjoy is a property of the
# COPY and not of production — and that production's spacing cannot be taken
# away by the hostile `sleep` that has been sitting first on $PATH since the
# top of this file.
echo "#153 round 4 · the shipped claim.sh pays the real barrier and never executes a PATH sleep"
new_repo "$ROOT/prodbar"
export GH_LOG="$ROOT/prodbar/gh.log"
: > "$GH_LOG"
# Do NOT erase the suite-lifetime sentinel here (#153 review round 6, P3).
# Earlier fixtures must remain attributable; wiping before the only assertions
# made the tripwire untruthful. Snapshot the suite receipt, then assert this
# production run adds nothing, then assert the whole suite receipt is empty.
sleep_hits_before=0
if [[ -f "$SLEEP_SENTINEL" ]]; then
  sleep_hits_before=$(wc -l < "$SLEEP_SENTINEL" | tr -d ' ')
fi
prodbar_start=$(date +%s)
out=$(cd "$ROOT/prodbar/canon" && \
  GIBSON_CLAIM_ADMIT_DELAY=1 GIBSON_CLAIM_ADMIT_STABLE_READS=2 \
  GIBSON_CLAIM_ADMIT_ATTEMPTS=6 \
  "$PRODUCTION_CLAIM" 91 real-barrier 'lib/real-barrier/**' 2>&1); rc=$?
prodbar_elapsed=$(( $(date +%s) - prodbar_start ))
check "the shipped claim.sh completes a claim" "$rc" "0"
[[ "$prodbar_elapsed" -ge 1 ]] &&
  ok "a 2-read/1s barrier cost at least 1s of real time (${prodbar_elapsed}s)" ||
  bad "the shipped barrier finished in ${prodbar_elapsed}s — the wait did not happen"
sleep_hits_after=0
if [[ -f "$SLEEP_SENTINEL" ]]; then
  sleep_hits_after=$(wc -l < "$SLEEP_SENTINEL" | tr -d ' ')
fi
if [[ "$sleep_hits_after" -ne "$sleep_hits_before" ]]; then
  bad "the shipped claim.sh executed the hostile PATH sleep $((sleep_hits_after - sleep_hits_before)) time(s) during the production barrier — the barrier is externally controllable"
else
  ok "the shipped claim.sh executed the hostile PATH sleep ZERO times during the production barrier"
fi
unset GH_LOG

echo "#153 round 4 · nothing in this whole suite ever executed the hostile PATH sleep"
# Suite-lifetime evidence: the tripwire has been first on $PATH since the top
# of this file. If any fixture — production or patched copy — reached for a
# `sleep` executable, it is still recorded here (we never erase earlier hits).
if [[ -s "$SLEEP_SENTINEL" ]]; then
  bad "a PATH sleep was executed during the suite: $(tr '\n' ' ' < "$SLEEP_SENTINEL")"
else
  ok "the hostile PATH sleep was never executed by anything under test"
fi

echo "#153 round 4 · no production script names an executable through the environment (static)"
# The rollback hook this repo removed (GIBSON_CLAIM_TEST_ROLLBACK_HOOK) and the
# PATH `sleep` were the same mistake in two shapes: production choosing what to
# execute from something a caller controls. Neither may come back.
for prod in "$SCRIPT_DIR/../claim.sh" "$SCRIPT_DIR/../release-claim.sh" \
            "$SCRIPT_DIR/../pr-claims.sh" "$SCRIPT_DIR/../lib/claim-guards.sh" \
            "$SCRIPT_DIR/../scope-overlap.mjs"; do
  name=$(basename "$prod")
  if grep -nE '_TEST_[A-Z_]*HOOK|_HOOK\b' "$prod" | grep -vE '^\s*[0-9]+:\s*#|removed|no production hook|there is deliberately' >/dev/null; then
    bad "$name references a test hook variable"
  else
    ok "$name carries no test-hook execution path"
  fi
done

# ===========================================================================
# #153 review round 6, P1 — worktree uses the proven remote base, not a stale
# cached origin/main (or the inverse)
# ===========================================================================
echo "#153 round 6 · remote with only master + stale origin/main uses origin/master OID"
# The live remote selects BASE=master. Independently preferring a cached
# origin/main at a DIFFERENT OID is the bug. Assert ancestry by OID, not
# command text.
new_repo "$ROOT/basemaster"
(
  cd "$ROOT/basemaster/canon" || exit 1
  # Convert the remote to master-only.
  git checkout -q -b master
  git push -q -u origin master
  git push -q origin --delete main 2>/dev/null || true
  git -C "$ROOT/basemaster/origin" update-ref -d refs/heads/main 2>/dev/null || true
  git -C "$ROOT/basemaster/origin" symbolic-ref HEAD refs/heads/master
  # Plant a STALE origin/main at a different OID that must never become the
  # branch point.
  git checkout -q --orphan stale-main-tree
  git rm -rf --quiet . >/dev/null 2>&1 || true
  printf 'stale-main decoy\n' > STALE_MAIN
  git add STALE_MAIN
  git commit -qm "stale origin/main decoy"
  STALE_MAIN_OID=$(git rev-parse HEAD)
  git update-ref refs/remotes/origin/main "$STALE_MAIN_OID"
  git checkout -q master
  echo "$STALE_MAIN_OID" > "$ROOT/basemaster/stale-main.oid"
) >/dev/null 2>&1
MASTER_OID=$(git -C "$ROOT/basemaster/canon" rev-parse origin/master)
STALE_MAIN_OID=$(cat "$ROOT/basemaster/stale-main.oid")
[[ "$MASTER_OID" != "$STALE_MAIN_OID" ]] || bad "fixture bug: master and stale main share an OID"
# Confirm the remote really has only master.
if git -C "$ROOT/basemaster/canon" ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  bad "fixture bug: origin still has main"
else
  ok "fixture: remote has no main (only master)"
fi
out=$(cd "$ROOT/basemaster/canon" && "$CLAIM" 901 only-master 'lib/only-master/**' 2>&1); rc=$?
check "claim on master-only remote succeeds" "$rc" "0"
# Branch parent must be the proven master OID, not the stale main.
BRANCH_PARENT=$(git -C "$ROOT/basemaster/canon" rev-parse "feat/901-only-master^" 2>/dev/null || true)
check "worktree ancestry is origin/master OID" "$BRANCH_PARENT" "$MASTER_OID"
[[ "$BRANCH_PARENT" != "$STALE_MAIN_OID" ]] &&
  ok "worktree ancestry is NOT the stale origin/main OID" ||
  bad "worktree branched from stale origin/main ($BRANCH_PARENT)"
# PR --base must match the selected base (captured from the claim body / branch).
contains "PR body names the claim" "$(cat "$GH_PR_FILE")" "issue-901-only-master"

echo "#153 round 6 · remote with only main + stale origin/master uses origin/main OID"
new_repo "$ROOT/basemain"
(
  cd "$ROOT/basemain/canon" || exit 1
  MAIN_OID=$(git rev-parse origin/main)
  # Plant a STALE origin/master at a different OID.
  git checkout -q --orphan stale-master-tree
  git rm -rf --quiet . >/dev/null 2>&1 || true
  printf 'stale-master decoy\n' > STALE_MASTER
  git add STALE_MASTER
  git commit -qm "stale origin/master decoy"
  STALE_MASTER_OID=$(git rev-parse HEAD)
  git update-ref refs/remotes/origin/master "$STALE_MASTER_OID"
  git checkout -q main
  echo "$MAIN_OID" > "$ROOT/basemain/main.oid"
  echo "$STALE_MASTER_OID" > "$ROOT/basemain/stale-master.oid"
) >/dev/null 2>&1
MAIN_OID=$(cat "$ROOT/basemain/main.oid")
STALE_MASTER_OID=$(cat "$ROOT/basemain/stale-master.oid")
[[ "$MAIN_OID" != "$STALE_MASTER_OID" ]] || bad "fixture bug: main and stale master share an OID"
# Remote still has main (and must prefer it over any local master cache).
git -C "$ROOT/basemain/canon" ls-remote --exit-code --heads origin main >/dev/null 2>&1 &&
  ok "fixture: remote has main" || bad "fixture bug: remote has no main"
out=$(cd "$ROOT/basemain/canon" && "$CLAIM" 902 only-main 'lib/only-main/**' 2>&1); rc=$?
check "claim on main-preferring remote succeeds" "$rc" "0"
BRANCH_PARENT=$(git -C "$ROOT/basemain/canon" rev-parse "feat/902-only-main^" 2>/dev/null || true)
check "worktree ancestry is origin/main OID" "$BRANCH_PARENT" "$MAIN_OID"
[[ "$BRANCH_PARENT" != "$STALE_MASTER_OID" ]] &&
  ok "worktree ancestry is NOT the stale origin/master OID" ||
  bad "worktree branched from stale origin/master ($BRANCH_PARENT)"

# ===========================================================================
# #153 review round 6, P2 — claims-status.sh fails closed on reader failure
# ===========================================================================
echo "#153 round 6 · claims-status fails closed when pr-claims.sh list fails"
new_repo "$ROOT/statusfail"
mkdir -p "$ROOT/statusfail/bin"
# Shadow pr-claims.sh with a failing reader next to claims-status via PATH? No —
# claims-status invokes $SCRIPT_DIR/pr-claims.sh by absolute path. Stage a
# temporary wrapper by pointing SCRIPT via a copy of claims-status that calls
# our failing reader — simpler: put a non-executable placeholder is hard.
# Instead, use a gh that makes pr-claims.sh's graphql fail.
cat > "$ROOT/statusfail/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  api)
    echo "simulated auth failure: HTTP 401" >&2
    exit 1
    ;;
  *)
    echo "fake gh: unmodelled: gh $*" >&2
    exit 64
    ;;
esac
FAKE
chmod +x "$ROOT/statusfail/bin/gh"
status=$(cd "$ROOT/statusfail/canon" && PATH="$ROOT/statusfail/bin:$PATH" \
  "$SCRIPT_DIR/../claims-status.sh" 2>&1); rc=$?
check    "claims-status exits 1 on reader failure" "$rc" "1"
contains "names the unreadable inventory"          "$status" "unreadable"
lacks    "never announces no live claims on failure" "$status" "no live claims"

echo "#153 round 6 · claims-status reports genuine empty inventory successfully"
new_repo "$ROOT/statusempty"
# Empty PR inventory (suite fake gh empty graphql) + empty ledger.
(
  cd "$ROOT/statusempty/canon" || exit 1
  rm -rf docs/claims docs/active-work.md
  git add -A && git commit -qm "empty" && git push -q origin main
) >/dev/null 2>&1
mkdir -p "$ROOT/statusempty/bin"
# Recognise inventory GraphQL only; unknown routes fail closed.
cat > "$ROOT/statusempty/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  api)
    if [[ "$2" != "graphql" ]]; then
      echo "fake gh: expected graphql, got: gh $*" >&2
      exit 64
    fi
    case "$*" in
      *pullRequests*|*openPrNumbers*) exit 0 ;;
      *)
        echo "fake gh: unmodelled GraphQL: gh $*" >&2
        exit 64
        ;;
    esac
    ;;
  *)
    echo "fake gh: unmodelled: gh $*" >&2
    exit 64
    ;;
esac
FAKE
chmod +x "$ROOT/statusempty/bin/gh"
status=$(cd "$ROOT/statusempty/canon" && PATH="$ROOT/statusempty/bin:$PATH" \
  "$SCRIPT_DIR/../claims-status.sh" 2>&1); rc=$?
check    "genuine empty inventory exits 0" "$rc" "0"
contains "announces no live claims only after a successful read" "$status" "no live claims"

echo
echo "claim.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
