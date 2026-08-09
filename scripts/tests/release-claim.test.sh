#!/usr/bin/env bash
# release-claim.test.sh — sensors for the release-claim contract
#
# WHAT IT DOES
#   Builds throwaway git repos in a temp dir and asserts the behaviour the
#   lessons demand. No network, no gh, no GitHub.
#
# WHY
#   L-009 / L-024 / L-027 / L-037 were all "the script quietly did the wrong
#   thing". A guide line does not catch a regression; this does.
#
# USAGE
#   scripts/tests/release-claim.test.sh
set -uo pipefail

# Hermetic git identity (#101): suites that commit must not read ambient global
# user.name/email. Pass with HOME pointed at an empty directory.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"


SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
RC="$SCRIPT_DIR/../release-claim.sh"
PASS=0
FAIL=0

ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }
# A typo'd assertion must never be a silent no-op (#153 review round 5): bash
# calls this hook when a command name does not resolve, so an undefined helper
# is a COUNTED failure instead of a stderr line under a green tally. Returning
# 127 preserves the original exit status. (bash 4+; a no-op on bash 3.2.)
command_not_found_handle() {
  bad "the suite invoked an undefined command '$1' — a shell error may never coexist with a green tally"
  return 127
}

# --- a fake `gh` may never read stdin (#153 review round 5) -----------------
# The `list-open-numbers` branch of the terminal fixture's fake gh used to end
# in `cut … | grep -vxF -f … || cat >/dev/null`. `A | B || C` is `(A | B) || C`
# and grep exits 1 when it selects nothing — the ORDINARY case, since most
# fixtures stage an empty open inventory — so the fallback `cat` ran with the
# fake's inherited stdin and blocked forever. The suite did not fail; it hung,
# which is strictly worse, because a hang produces no receipt at all.
#
# This probe is the sensor for that class. It runs the fake with a stdin that
# is open and will never deliver a byte, and requires it to finish anyway.
# Bounded by construction: it kills the probe and FAILS rather than inheriting
# the very hang it is testing for.
assert_gh_never_reads_stdin() { # fake-path label
  local fake="$1" label="$2" fifo pid waited=0
  fifo="$ROOT/gh-stdin-probe.$$"
  rm -f "$fifo"
  mkfifo "$fifo" 2>/dev/null || { bad "$label: could not create the stdin probe fifo"; return; }
  # Opened read-write from this shell so the reader never sees EOF and the
  # open() itself never blocks.
  exec 9<>"$fifo"
  "$fake" api graphql -f query='query openPrNumbers($owner: String!, $name: String!)' \
    >/dev/null 2>&1 <&9 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    waited=$((waited + 1))
    if [[ "$waited" -gt 100 ]]; then   # ~5s
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      exec 9>&-
      rm -f "$fifo"
      bad "$label: the fake gh blocked on stdin answering list-open-numbers (it must never read stdin)"
      return
    fi
    sleep 0.05
  done
  wait "$pid" 2>/dev/null
  exec 9>&-
  rm -f "$fifo"
  ok "$label: answers list-open-numbers without ever reading stdin"
}

# One 8-field `pr-claims.sh list` row: number, claim, scope, head branch, url,
# created, updated, is_cross_repository (#153 review round 5). $5 overrides the
# identity column so a fixture can stage a fork PR.
#
# Defined HERE, with the other helpers, rather than beside the fixtures that
# happen to use it most. It was previously declared two thirds of the way down
# the file, below three round-5 fixtures that already called it: those calls
# resolved to nothing, their `> "$GH_PR_OPEN_TSV"` redirections still truncated
# the file, and the fixtures then ran against an EMPTY open inventory — which
# is a different scenario from the one they are named for, and which they
# quietly failed. Helpers go above every caller.
open_row() {
  printf '%s\t%s\t%s\t%s\thttps://github.com/acme/app/pull/%s\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\t%s\n' \
    "$1" "$2" "$3" "$4" "$1" "${5:-false}"
}

# --- harness-owned `git` command shim (#153 review round 3, P1) -------------
# The TOCTOU sensors below need a mutation to land inside a specific window
# INSIDE release-claim.sh — between its safety proof and the mutation that
# proof authorises. That used to be done with RELEASE_CLAIM_TEST_*_HOOK
# variables that production read and EXECUTED. An environment variable naming
# an executable is an execution path however it is documented, so those are
# gone; the window is driven from outside instead.
#
# write_git_shim installs a `git` earlier on PATH than the real one. It
# forwards every invocation to the real git, and exactly once — immediately
# BEFORE the git call the sensor targets — runs a deterministic mutation baked
# into the generated shim. release-claim.sh cooperates in no way and cannot
# tell the difference.
#
# Triggers:
#   status2    the SECOND `git -C <path> status --porcelain`, i.e. the
#              pre-removal revalidation (the first is the safety proof)
#   updateref  `git update-ref -d refs/heads/…`, the local CAS delete
#   pushlease  `git push --force-with-lease=… origin :refs/heads/…`
# The mutation body may use $WT (the -C path of the triggering call), $BR,
# $CANON, $ORIGIN and $REAL_GIT.
REAL_GIT=$(command -v git)
write_git_shim() { # dir trigger branch body
  local dir="$1" trigger="$2" branch="$3" body="$4"
  mkdir -p "$ROOT/$dir/shim"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'REAL_GIT=%q\n' "$REAL_GIT"
    printf 'STATE=%q\n' "$ROOT/$dir/shim/state"
    printf 'TRIGGER=%q\n' "$trigger"
    printf 'BR=%q\n' "$branch"
    printf 'CANON=%q\n' "$ROOT/$dir/canon"
    printf 'ORIGIN=%q\n' "$ROOT/$dir/origin"
    cat <<'SHIM'
args=("$@")
CPATH=""
i=0
while [[ "$i" -lt "${#args[@]}" ]]; do
  if [[ "${args[$i]}" == "-C" ]]; then CPATH="${args[$((i + 1))]}"; fi
  i=$((i + 1))
done
joined="$*"
matched=0
case "$TRIGGER" in
  status2)
    if [[ "$joined" == *"status --porcelain"* && -n "$CPATH" ]]; then
      n=$(cat "$STATE.n" 2>/dev/null || echo 0)
      n=$((n + 1)); echo "$n" > "$STATE.n"
      [[ "$n" -eq 2 ]] && matched=1
    fi
    ;;
  updateref) [[ "$joined" == *"update-ref -d refs/heads/"* ]] && matched=1 ;;
  pushlease) [[ "$joined" == *"--force-with-lease="* ]] && matched=1 ;;
esac
if [[ "$matched" -eq 1 && ! -e "$STATE.fired" ]]; then
  : > "$STATE.fired"
  WT="$CPATH"
SHIM
    printf '%s\n' "$body"
    cat <<'SHIM2'
fi
exec "$REAL_GIT" "$@"
SHIM2
  } > "$ROOT/$dir/shim/git"
  chmod +x "$ROOT/$dir/shim/git"
}

# A canonical checkout parked on a dirty long-lived branch — the L-009 shape.
#
# $2 (optional) gives the checkout a real GitHub repository identity
# (owner/name), which release-claim.sh now requires before it will act on any
# PR-body claim evidence (#153 review P1: a fork/copy carrying the same branch
# and commits is not the same repository). The origin URL becomes the real
# GitHub URL, and a url.<local>.insteadOf rewrite sends fetch/push at the
# throwaway bare repo — so the fixture stays hermetic while the *recorded*
# origin identity is exactly what a real clone carries. $3 selects the URL
# form (https, the default, or ssh) so both are covered by real runs.
# Without $2 the origin stays a bare local path: a determinate "this checkout
# is not a GitHub repository", which is the ledger-only shape most of the
# suite exercises.
new_repo() {
  local root="$1" gh_repo="${2:-}" url_form="${3:-https}" url=""
  rm -rf "$root"
  mkdir -p "$root"
  git init -q --bare "$root/origin"
  git clone -q "$root/origin" "$root/canon" 2>/dev/null
  if [[ -n "$gh_repo" ]]; then
    case "$url_form" in
      ssh) url="git@github.com:${gh_repo}.git" ;;
      *)   url="https://github.com/${gh_repo}.git" ;;
    esac
    git -C "$root/canon" config "url.$root/origin.insteadOf" "$url"
    git -C "$root/canon" remote set-url origin "$url"
  fi
  mkdir -p "$root/canon/docs"
  cat > "$root/canon/docs/active-work.md" <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-checkout-totals | src/checkout | session:a |
| 2026-08-01 | issue-15-demo-stale-plan | src/demo | session:b |
| 2026-08-01 | issue-115-unrelated | src/x | session:c |
| 2026-08-01 | issue-template-5-palette-tokens | tokens | session:d |
| 2026-08-01 | issue-5-monorepo-thing | src/y | session:e |
TABLE
  (
    cd "$root/canon" || exit 1
    git add -A
    git commit -qm "init"
    git branch -M main
    git push -q -u origin main
    # Bare origins default HEAD to master; point it at main so later clones
    # actually check out a tree (renewal-race CAS depends on a second clone
    # that can edit docs/claims/* — #94).
    git -C "$root/origin" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git checkout -q -b long-lived-feature
    echo dirty > uncommitted.txt
  ) >/dev/null 2>&1
}

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-rc-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Suite-wide hermetic `gh`. Individual fixtures overwrite $ROOT/bin/gh with
# their own richer fake; this default guarantees that a test running before
# (or between) those fixtures can never reach the network. Everything is
# unresolvable — exactly what a real gh does in these throwaway repos, whose
# origin is a local bare path — except pr-claims.sh's paginated GraphQL read,
# which succeeds with an empty inventory. That distinction matters since
# #153: release-claim.sh now treats an unreadable live-claim inventory as a
# hard refusal, so "no fake gh at all" is no longer a silent no-op.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  api) exit 0 ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

echo "L-037 · namespaced and numeric claim ids match safely"
new_repo "$ROOT/a"
# Bare multi-claim on issue 15 refuses (two live issue-15 rows). Scoped match
# still sees issue-15 and never issue-115.
out=$(cd "$ROOT/a/canon" && "$RC" 15 --claim-id issue-15-checkout-totals --dry-run 2>&1)
rc=$?
check "scoped dry-run exits 0" "$rc" "0"
contains "issue-15-* matches" "$out" "issue-15-checkout-totals"
lacks    "issue-115-* does not match issue 15" "$out" "issue-115-unrelated"
out=$(cd "$ROOT/a/canon" && "$RC" 5 --prefix template --claim-id issue-template-5-palette-tokens --repo acme/tmpl --dry-run 2>&1)
contains "--prefix finds the namespaced id" "$out" "issue-template-5-palette-tokens"
contains "--repo names the product repo" "$out" "acme/tmpl"
contains "monorepo sibling kept under prefix release" "$out" "KEEP sibling claim: issue-5-monorepo-thing"
lacks    "does not release monorepo under template claim-id" "$out" "release claim:   issue-5-monorepo-thing"

echo "L-024 · --claim-id releases one slice and keeps the siblings"
out=$(cd "$ROOT/a/canon" && "$RC" 15 --claim-id issue-15-checkout-totals --dry-run 2>&1)
contains "releases the named slice" "$out" "release claim:   issue-15-checkout-totals"
contains "keeps the sibling row"    "$out" "KEEP sibling claim: issue-15-demo-stale-plan"
contains "keeps the label"          "$out" "keep the agent-claimed label"

echo "L-009 · runs from a dirty non-main checkout without moving it"
new_repo "$ROOT/b"
(cd "$ROOT/b/canon" && "$RC" 15 --claim-id issue-15-checkout-totals) >/dev/null 2>&1
branch=$(cd "$ROOT/b/canon" && git rev-parse --abbrev-ref HEAD)
check "canonical checkout still on its branch" "$branch" "long-lived-feature"
dirty=$(cd "$ROOT/b/canon" && git status --porcelain)
check "uncommitted work untouched" "$dirty" "?? uncommitted.txt"
table=$(cd "$ROOT/b/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
lacks    "merged slice stripped on origin/main" "$table" "issue-15-checkout-totals"
contains "sibling slice survives on origin/main" "$table" "issue-15-demo-stale-plan"
contains "unrelated issue survives"              "$table" "issue-115-unrelated"

echo "L-023 · per-lane claim files release the same way rows did"
new_repo "$ROOT/d"
(
  cd "$ROOT/d/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  for id in issue-15-checkout-totals issue-15-demo-stale-plan issue-115-unrelated; do
    printf 'claim: %s\nissue: 15\nclaimed: 2026-08-01T00:00:00Z\nscope: src/%s\nsession: a\n' "$id" "$id" \
      > "docs/claims/$id.md"
  done
  : > docs/active-work.md   # no legacy rows at all: files are the only ledger
  git add -A && git commit -qm "claims as files" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
out=$(cd "$ROOT/d/canon" && "$RC" 15 --claim-id issue-15-checkout-totals --dry-run 2>&1)
contains "finds a claim with no table at all" "$out" "issue-15-checkout-totals"
contains "sees the sibling file"              "$out" "KEEP sibling claim: issue-15-demo-stale-plan"
(cd "$ROOT/d/canon" && "$RC" 15 --claim-id issue-15-checkout-totals) >/dev/null 2>&1
files=$(cd "$ROOT/d/canon" && git fetch -q origin && git ls-tree --name-only origin/main docs/claims/)
lacks    "released claim file deleted" "$files" "issue-15-checkout-totals"
contains "sibling claim file survives" "$files" "issue-15-demo-stale-plan"
contains "other issue untouched"       "$files" "issue-115-unrelated"

echo "L-027 · unfinished cleanup exits 3 instead of claiming success"
new_repo "$ROOT/c"
# Final single-claim lane: residual empty → label must be removed. Bare multi
# refuse (#65) means we leave only one issue-15 row, then bare-release it.
# No GitHub remote → removal cannot be verified → exit 3.
(
  cd "$ROOT/c/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-checkout-totals | src/checkout | session:a |
| 2026-08-01 | issue-115-unrelated | src/x | session:c |
TABLE
  git add -A && git commit -qm "single issue-15 claim" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
out=$(cd "$ROOT/c/canon" && "$RC" 15 2>&1)
rc=$?
check "exit code" "$rc" "3"
contains "says what is unfinished" "$out" "agent-claimed NOT removed"
lacks    "does not claim success"  "$out" "OK — claim released"

echo "#61 · valid empty ledger is empty, not corrupt"
new_repo "$ROOT/empty"
(
  cd "$ROOT/empty/canon" || exit 1
  git checkout -q main
  # No docs/claims/* and no active-work.md on origin/main — valid empty ledger.
  git rm -q docs/active-work.md
  git commit -qm "empty ledger" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1

out=$(cd "$ROOT/empty/canon" && "$RC" 18 --keep-label --dry-run 2>&1)
rc=$?
check "empty ledger + --keep-label dry-run exits 0" "$rc" "0"
contains "does not invent a claim row" "$out" "none matched"
contains "keeps the label for the live sibling" "$out" "KEEP label agent-claimed"
lacks    "does not hard-fail as missing ledger" "$out" "cannot resolve a valid ledger"

# --keep-label happy path: fake gh reports agent-claimed present → verified 0.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh for --keep-label verification.
# release-claim: gh issue view N --repo R --json labels -q '[.labels[].name] | join(",")'
# Also handles repo view for default product-repo resolution.
case "$1" in
  repo)
    echo "acme/app"
    exit 0
    ;;
  # No live open PR-body claims here: an empty but successfully read
  # GraphQL inventory (#153).
  api) exit 0 ;;
  issue)
    shift
    # find -q EXPR if present
    q=""
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "-q" ]]; then q="$a"; fi
      prev="$a"
    done
    if [[ "$1" == "view" && -n "$q" ]]; then
      case "${GH_LABELS:-agent-claimed,tier-b}" in
        "?") exit 1 ;;  # unreadable
        *) echo "${GH_LABELS:-agent-claimed,tier-b}" ;;
      esac
      exit 0
    fi
    if [[ "$1" == "edit" ]]; then
      exit 0
    fi
    exit 1
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

out=$(cd "$ROOT/empty/canon" && GH_LABELS="agent-claimed,tier-b" "$RC" 18 --keep-label --repo acme/app 2>&1)
rc=$?
check "empty ledger + --keep-label verified present completes" "$rc" "0"
contains "keeps label without inventing a row" "$out" "--keep-label"
contains "verified preservation" "$out" "verified"
contains "truthful no-claim OK" "$out" "no claim row to release"
lacks    "does not claim a row was released" "$out" "OK — claim released for issue 18"

echo "#61 · --keep-label fails closed when label missing or unreadable"
out=$(cd "$ROOT/empty/canon" && GH_LABELS="tier-b" "$RC" 18 --keep-label --repo acme/app 2>&1)
rc=$?
check "keep-label with ABSENT agent-claimed exits 3" "$rc" "3"
contains "names ABSENT label" "$out" "ABSENT"
lacks    "does not claim success when label missing" "$out" "OK —"

out=$(cd "$ROOT/empty/canon" && GH_LABELS="?" "$RC" 18 --keep-label --repo acme/app 2>&1)
rc=$?
check "keep-label with unreadable labels exits 3" "$rc" "3"
contains "names UNVERIFIED preservation" "$out" "UNVERIFIED"

# No --repo and gh repo view fails → cannot resolve product repo.
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$ROOT/bin/gh"
out=$(cd "$ROOT/empty/canon" && "$RC" 18 --keep-label 2>&1)
rc=$?
check "keep-label without resolvable repo exits 3" "$rc" "3"
contains "cannot verify without product repo" "$out" "cannot verify"

# Restore a working gh for subsequent tests that may need it.
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    shift
    q=""; prev=""
    for a in "$@"; do
      if [[ "$prev" == "-q" ]]; then q="$a"; fi
      prev="$a"
    done
    if [[ "$1" == "view" && -n "$q" ]]; then
      echo "${GH_LABELS:-}"
      exit 0
    fi
    if [[ "$1" == "edit" ]]; then exit 0; fi
    exit 1
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"

# Final completed lane on an empty ledger: must remove agent-claimed. With gh
# that returns empty labels after a no-op edit, removal verifies and exits 0.
# Without a working remove+verify path, exit 3 (L-027 still holds).
out=$(cd "$ROOT/empty/canon" && GH_LABELS="" "$RC" 18 --repo acme/app 2>&1)
rc=$?
check "empty ledger final lane removes label when verified gone" "$rc" "0"
contains "removed label verified" "$out" "removed agent-claimed"

# Unverifiable final lane: gh issue view fails after edit.
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then exit 0; fi
    exit 1
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
out=$(cd "$ROOT/empty/canon" && "$RC" 18 --repo acme/app 2>&1)
rc=$?
check "empty ledger final lane exits 3 when label removal UNVERIFIED" "$rc" "3"
contains "names unfinished label work" "$out" "UNVERIFIED"
lacks    "does not claim success on incomplete label removal" "$out" "OK —"

echo "#61 · unborn/invalid ledger ref is not an empty ledger"
# Bare repo with no commits: no origin/main, no main commit → hard fail.
mkdir -p "$ROOT/unborn"
git init -q "$ROOT/unborn/canon"
# Ensure no main/master commit exists (unborn HEAD).
out=$(cd "$ROOT/unborn/canon" && "$RC" 18 --keep-label --dry-run 2>&1)
rc=$?
check "unborn main hard-fails (not empty ledger)" "$rc" "1"
contains "names cannot resolve ledger ref" "$out" "cannot resolve a valid ledger commit ref"
lacks    "does not treat unborn as empty ledger" "$out" "treating as no live claims"

# Invalid ref: a repo whose HEAD points at a non-commit (corrupt) is not an empty ledger.
# Simpler portable case: strip every main/master ref so resolve_ledger_ref finds none.
new_repo "$ROOT/badref"
(
  cd "$ROOT/badref/canon" || exit 1
  git checkout -q long-lived-feature
  # Drop local main and all remote-tracking main/master refs. Also remove the
  # bare origin's main so a later fetch cannot resurrect it.
  git branch -D main >/dev/null 2>&1 || true
  git branch -D master >/dev/null 2>&1 || true
  git update-ref -d refs/remotes/origin/main 2>/dev/null || true
  git update-ref -d refs/remotes/origin/master 2>/dev/null || true
  # Prevent fetch from re-adding origin/main during the script.
  git remote remove origin 2>/dev/null || true
  # Also ensure no local main/master commit ref remains under any name we try.
  for r in refs/heads/main refs/heads/master refs/remotes/origin/main refs/remotes/origin/master; do
    git update-ref -d "$r" 2>/dev/null || true
  done
) >/dev/null 2>&1
out=$(cd "$ROOT/badref/canon" && "$RC" 18 --keep-label 2>&1)
rc=$?
check "deleted main/master hard-fails" "$rc" "1"
contains "hard-fail message on missing ref" "$out" "cannot resolve a valid ledger commit ref"

echo "#61 P1 · unreadable/corrupt ledger tree is not an empty ledger"
# A valid commit object whose referenced tree is missing/corrupt must hard-fail
# before any label mutation. Suppressing ls-tree failure and treating it as
# "no claims" is a false-green empty-ledger path.
new_repo "$ROOT/badtree"
(
  cd "$ROOT/badtree/canon" || exit 1
  git checkout -q main
  # Record tree SHA for origin/main, then delete the tree object from both the
  # working clone and the bare origin so cat-file/ls-tree fail closed.
  tree=$(git rev-parse "origin/main^{tree}")
  commit=$(git rev-parse "origin/main^{commit}")
  # Ensure resolve_ledger_ref still finds a *commit* (object remains).
  git cat-file -t "$commit" >/dev/null
  rm_obj() {
    local sha="$1" repo="$2"
    local dir="$repo/objects/${sha:0:2}"
    local file="$dir/${sha:2}"
    rm -f "$file"
  }
  rm_obj "$tree" "$ROOT/badtree/canon/.git"
  rm_obj "$tree" "$ROOT/badtree/origin"
  # Also drop any alternates / packed copy if present.
  git -C "$ROOT/badtree/canon" prune --expire=now >/dev/null 2>&1 || true
  git -C "$ROOT/badtree/origin" prune --expire=now >/dev/null 2>&1 || true
  # Confirm the false-green shape: commit resolves, tree does not.
  git rev-parse --verify "origin/main^{commit}" >/dev/null
  if git cat-file -e "origin/main^{tree}" 2>/dev/null; then
    # Some git layouts keep the tree elsewhere; force-delete again via cat-file path.
    tree2=$(git rev-parse "origin/main^{tree}")
    rm_obj "$tree2" "$ROOT/badtree/canon/.git"
    rm_obj "$tree2" "$ROOT/badtree/origin"
  fi
  git checkout -q long-lived-feature
) >/dev/null 2>&1

# Fake gh that would "succeed" label mutation if we incorrectly continue.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      echo "MUTATED" >&2
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

out=$(cd "$ROOT/badtree/canon" && "$RC" 18 --repo acme/app 2>&1)
rc=$?
check "corrupt tree hard-fails (exit 1)" "$rc" "1"
contains "names unreadable/corrupt tree" "$out" "unreadable/corrupt tree"
lacks    "does not treat corrupt tree as empty ledger" "$out" "treating as no live claims"
lacks    "does not mutate labels before tree hard-fail" "$out" "MUTATED"
lacks    "does not claim OK on corrupt tree" "$out" "OK —"

# Dry-run must also refuse — no "would remove label" on unreadable ledger.
out=$(cd "$ROOT/badtree/canon" && "$RC" 18 --keep-label --dry-run 2>&1)
rc=$?
check "corrupt tree dry-run hard-fails" "$rc" "1"
contains "dry-run names corrupt tree too" "$out" "unreadable/corrupt tree"
lacks    "dry-run does not invent empty-ledger plan" "$out" "none matched"

echo "#61 P1 · tree entry with missing live blob is not an empty ledger"
# Readable root/docs trees + a path that still exists in the tree, but whose
# blob object is gone: cat-file -e ref:path fails. Treating that as path
# absence declares an empty ledger, mutates the label, and returns 0 — a
# false green. Inspect the tree entry first; unreadable/corrupt blob hard-fails
# before any label mutation. True path absence remains a valid empty ledger.
new_repo "$ROOT/missingblob"
(
  cd "$ROOT/missingblob/canon" || exit 1
  git checkout -q main
  # Confirm the tree still has the entry after we delete only the blob object.
  blob=$(git rev-parse "origin/main:docs/active-work.md")
  tree=$(git rev-parse "origin/main^{tree}")
  docs_tree=$(git rev-parse "origin/main:docs")
  rm_obj() {
    local sha="$1" repo="$2"
    local dir="$repo/objects/${sha:0:2}"
    local file="$dir/${sha:2}"
    rm -f "$file"
  }
  rm_obj "$blob" "$ROOT/missingblob/canon/.git"
  rm_obj "$blob" "$ROOT/missingblob/origin"
  git -C "$ROOT/missingblob/canon" prune --expire=now >/dev/null 2>&1 || true
  git -C "$ROOT/missingblob/origin" prune --expire=now >/dev/null 2>&1 || true
  # Shape: root tree + docs tree readable, path entry present, blob gone.
  git cat-file -e "$tree"
  git cat-file -e "$docs_tree"
  git ls-tree "origin/main" -- docs/active-work.md | grep -q 'active-work.md'
  if git cat-file -e "origin/main:docs/active-work.md" 2>/dev/null; then
    echo "setup failed: blob still readable" >&2
    exit 1
  fi
  git checkout -q long-lived-feature
) >/dev/null 2>&1

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      echo "MUTATED" >&2
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

out=$(cd "$ROOT/missingblob/canon" && "$RC" 18 --repo acme/app 2>&1)
rc=$?
check "missing live blob hard-fails (exit 1)" "$rc" "1"
contains "names unreadable/corrupt blob (not empty)" "$out" "unreadable/corrupt"
lacks    "does not treat missing blob as empty ledger" "$out" "treating as no live claims"
lacks    "does not mutate labels before blob hard-fail" "$out" "MUTATED"
lacks    "does not claim OK on missing blob" "$out" "OK —"

out=$(cd "$ROOT/missingblob/canon" && "$RC" 18 --keep-label --dry-run 2>&1)
rc=$?
check "missing live blob dry-run hard-fails" "$rc" "1"
contains "dry-run names unreadable blob too" "$out" "unreadable/corrupt"
lacks    "dry-run does not invent empty-ledger plan on missing blob" "$out" "none matched"
lacks    "dry-run does not plan label keep on corrupt blob" "$out" "KEEP label"

# True absence of the path (no tree entry) remains a valid empty ledger — do
# not over-reject after the blob hard-fail was added.
new_repo "$ROOT/absentpath"
(
  cd "$ROOT/absentpath/canon" || exit 1
  git checkout -q main
  git rm -q docs/active-work.md
  git commit -qm "no active-work path" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
out=$(cd "$ROOT/absentpath/canon" && "$RC" 18 --keep-label --dry-run 2>&1)
rc=$?
check "true missing path still valid empty ledger (exit 0)" "$rc" "0"
contains "true absence still treated as empty" "$out" "treating as no live claims"
lacks    "true absence is not hard-failed as corrupt blob" "$out" "unreadable/corrupt"

echo "#61 P1 · missing per-claim leaf blob fails closed before any mutation"
# Exact independent-review fixture: readable root/docs/claims trees + listed
# tree entry docs/claims/issue-18-live-slice.md + that leaf blob removed from
# both the working clone and bare origin. Pathname-only matching must NOT
# proceed to gh label edit, worktree removal, branch deletion, or ledger
# commit/push. Output must never claim label removal.
new_repo "$ROOT/missingclaimblob"
(
  cd "$ROOT/missingclaimblob/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  printf 'claim: issue-18-live-slice\nissue: 18\nclaimed: 2026-08-01T00:00:00Z\nscope: src/x\nsession: a\n' \
    > docs/claims/issue-18-live-slice.md
  : > docs/active-work.md
  git add -A && git commit -qm "per-file claim for issue 18" && git push -q origin main
  blob=$(git rev-parse "origin/main:docs/claims/issue-18-live-slice.md")
  root_tree=$(git rev-parse "origin/main^{tree}")
  docs_tree=$(git rev-parse "origin/main:docs")
  claims_tree=$(git rev-parse "origin/main:docs/claims")
  rm_obj() {
    local sha="$1" repo="$2"
    local dir="$repo/objects/${sha:0:2}"
    local file="$dir/${sha:2}"
    rm -f "$file"
  }
  # Delete *only* the claim leaf blob — keep every parent tree readable.
  rm_obj "$blob" "$ROOT/missingclaimblob/canon/.git"
  rm_obj "$blob" "$ROOT/missingclaimblob/origin"
  git -C "$ROOT/missingclaimblob/canon" prune --expire=now >/dev/null 2>&1 || true
  git -C "$ROOT/missingclaimblob/origin" prune --expire=now >/dev/null 2>&1 || true
  git cat-file -e "$root_tree"
  git cat-file -e "$docs_tree"
  git cat-file -e "$claims_tree"
  git ls-tree "origin/main" docs/claims/ | grep -q 'issue-18-live-slice.md'
  if git cat-file -e "origin/main:docs/claims/issue-18-live-slice.md" 2>/dev/null; then
    echo "setup failed: claim blob still readable" >&2
    exit 1
  fi
  # Mutation canaries: worktree + branch that would be cleaned if we continued.
  git branch -f "feat/18-live-slice" HEAD
  mkdir -p "$ROOT/missingclaimblob/wt-18-live-slice"
  echo canary > "$ROOT/missingclaimblob/wt-18-live-slice/marker"
  origin_main_before=$(git rev-parse origin/main)
  printf '%s\n' "$origin_main_before" > "$ROOT/missingclaimblob/origin-main.before"
  git checkout -q long-lived-feature
) >/dev/null 2>&1

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      exit 0
    fi
    # view: pretend agent-claimed is present so a buggy removal path "verifies".
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

out=$(cd "$ROOT/missingclaimblob/canon" && "$RC" 18 --repo acme/app 2>&1)
rc=$?
check "missing claim leaf blob hard-fails (exit 1)" "$rc" "1"
contains "names unreadable/corrupt claim blob" "$out" "unreadable/corrupt"
contains "names the claim path" "$out" "docs/claims/issue-18-live-slice.md"
lacks    "does not treat missing claim blob as empty ledger" "$out" "treating as no live claims"
lacks    "does not call fake-gh issue edit" "$out" "MUTATED-LABEL"
lacks    "does not claim label removed" "$out" "removed agent-claimed"
lacks    "does not claim OK" "$out" "OK —"
lacks    "does not claim incomplete half-cleanup" "$out" "INCOMPLETE"
# Worktree / branch / ledger must be untouched.
[[ -f "$ROOT/missingclaimblob/wt-18-live-slice/marker" ]] \
  && ok "worktree canary not removed" \
  || bad "worktree canary was removed"
br_still=$(git -C "$ROOT/missingclaimblob/canon" branch --list 'feat/18-live-slice')
[[ -n "$br_still" ]] && ok "feature branch not deleted" || bad "feature branch was deleted"
origin_before=$(cat "$ROOT/missingclaimblob/origin-main.before")
origin_after=$(git -C "$ROOT/missingclaimblob/canon" rev-parse origin/main)
check "ledger origin/main not pushed" "$origin_after" "$origin_before"

out=$(cd "$ROOT/missingclaimblob/canon" && "$RC" 18 --keep-label --dry-run 2>&1)
rc=$?
check "missing claim leaf blob dry-run hard-fails" "$rc" "1"
contains "dry-run names claim blob too" "$out" "unreadable/corrupt"
lacks    "dry-run does not plan label remove on missing claim blob" "$out" "remove label"
lacks    "dry-run does not invent empty-ledger plan on missing claim blob" "$out" "none matched"

echo "#61 P1 · unexpected docs/claims entry type/mode fails closed"
# Nested tree or symlink under docs/claims/ is not a claim file. Fail closed
# before mutation; do not treat as a readable claim id.
new_repo "$ROOT/badclaimmode"
(
  cd "$ROOT/badclaimmode/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims/nested
  printf 'claim: issue-18-ok\nissue: 18\n' > docs/claims/issue-18-ok.md
  printf 'nested\n' > docs/claims/nested/extra.md
  ln -s "issue-18-ok.md" docs/claims/issue-18-link.md
  : > docs/active-work.md
  git add -A && git commit -qm "claims with nested tree + symlink" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  pr)
    # No open or terminal PR-body claims in this fixture (#153).
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

out=$(cd "$ROOT/badclaimmode/canon" && "$RC" 18 --repo acme/app 2>&1)
rc=$?
check "unexpected claims entry mode/type hard-fails (exit 1)" "$rc" "1"
contains "names unexpected mode/type" "$out" "unexpected Git mode/type"
lacks    "does not mutate labels on bad claims mode" "$out" "MUTATED-LABEL"
lacks    "does not claim OK on bad claims mode" "$out" "OK —"

# docs/claims as a blob (not a tree) is also refuse.
new_repo "$ROOT/claimsasblob"
(
  cd "$ROOT/claimsasblob/canon" || exit 1
  git checkout -q main
  rm -rf docs/claims
  printf 'not a tree\n' > docs/claims
  : > docs/active-work.md
  git add -A && git commit -qm "claims path is a blob" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
out=$(cd "$ROOT/claimsasblob/canon" && "$RC" 18 --repo acme/app 2>&1)
rc=$?
check "docs/claims blob (not tree) hard-fails" "$rc" "1"
contains "claims path wants tree" "$out" "want 040000 tree"
lacks    "does not mutate labels when claims is blob" "$out" "MUTATED-LABEL"

echo "#65 · bare multi-claim refuse (legacy + per-file)"
# Two live issue-15 claims + bare invocation must exit 1 before any dry-run
# plan or mutation. Exact ids printed sorted; zero worktree/branch/ledger change.
new_repo "$ROOT/m65"
# Canaries that must not be touched on refuse.
mkdir -p "$ROOT/m65/wt-15-checkout-totals" "$ROOT/m65/wt-15-demo-stale-plan"
echo canary-a > "$ROOT/m65/wt-15-checkout-totals/marker"
echo canary-b > "$ROOT/m65/wt-15-demo-stale-plan/marker"
(
  cd "$ROOT/m65/canon" || exit 1
  git branch -f "feat/15-checkout-totals" HEAD
  git branch -f "feat/15-demo-stale-plan" HEAD
  printf '%s\n' "$(git rev-parse origin/main)" > "$ROOT/m65/origin-main.before"
) >/dev/null 2>&1

out=$(cd "$ROOT/m65/canon" && "$RC" 15 --dry-run 2>&1)
rc=$?
check "bare multi-claim dry-run exits 1" "$rc" "1"
contains "names multi-claim refuse" "$out" "has 2 live claims"
contains "lists checkout-totals" "$out" "issue-15-checkout-totals"
contains "lists demo-stale-plan" "$out" "issue-15-demo-stale-plan"
# Sorted order: checkout-totals before demo-stale-plan (strip indent for compare)
order=$(printf '%s\n' "$out" | grep -E '^[[:space:]]+issue-15-' | sed 's/^[[:space:]]*//' | tr '\n' '|')
contains "ids printed in sorted order" "$order" "issue-15-checkout-totals|issue-15-demo-stale-plan|"
lacks    "no dry-run plan on multi refuse" "$out" "DRY RUN would"
lacks    "no release plan on multi refuse" "$out" "release claim:"
lacks    "no label plan on multi refuse" "$out" "remove label"

out=$(cd "$ROOT/m65/canon" && "$RC" 15 2>&1)
rc=$?
check "bare multi-claim real invoke exits 1" "$rc" "1"
contains "real multi refuse names both ids" "$out" "issue-15-checkout-totals"
contains "real multi refuse names sibling" "$out" "issue-15-demo-stale-plan"
[[ -f "$ROOT/m65/wt-15-checkout-totals/marker" ]] \
  && ok "multi refuse left target worktree" \
  || bad "multi refuse removed target worktree"
[[ -f "$ROOT/m65/wt-15-demo-stale-plan/marker" ]] \
  && ok "multi refuse left sibling worktree" \
  || bad "multi refuse removed sibling worktree"
br_a=$(git -C "$ROOT/m65/canon" branch --list 'feat/15-checkout-totals')
br_b=$(git -C "$ROOT/m65/canon" branch --list 'feat/15-demo-stale-plan')
[[ -n "$br_a" ]] && ok "multi refuse left target branch" || bad "multi refuse deleted target branch"
[[ -n "$br_b" ]] && ok "multi refuse left sibling branch" || bad "multi refuse deleted sibling branch"
origin_before=$(cat "$ROOT/m65/origin-main.before")
origin_after=$(git -C "$ROOT/m65/canon" rev-parse origin/main)
check "multi refuse did not push ledger" "$origin_after" "$origin_before"

# Per-file ledger multi-claim refuse (no legacy rows).
new_repo "$ROOT/m65f"
(
  cd "$ROOT/m65f/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  for id in issue-15-checkout-totals issue-15-demo-stale-plan; do
    printf 'claim: %s\nissue: 15\nclaimed: 2026-08-01T00:00:00Z\nscope: src/%s\nsession: a\n' "$id" "$id" \
      > "docs/claims/$id.md"
  done
  : > docs/active-work.md
  git add -A && git commit -qm "two per-file claims" && git push -q origin main
  git checkout -q long-lived-feature
  printf '%s\n' "$(git rev-parse origin/main)" > "$ROOT/m65f/origin-main.before"
) >/dev/null 2>&1
out=$(cd "$ROOT/m65f/canon" && "$RC" 15 --dry-run 2>&1)
rc=$?
check "per-file bare multi-claim dry-run exits 1" "$rc" "1"
contains "per-file multi lists both" "$out" "issue-15-checkout-totals"
lacks    "per-file multi no dry-run plan" "$out" "DRY RUN would"
origin_after=$(git -C "$ROOT/m65f/canon" rev-parse origin/main)
check "per-file multi refuse no ledger push" "$origin_after" "$(cat "$ROOT/m65f/origin-main.before")"

echo "#65 · bare single-claim freezes exact id"
new_repo "$ROOT/s65"
(
  cd "$ROOT/s65/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
| 2026-08-01 | issue-115-unrelated | src/x | session:c |
TABLE
  git add -A && git commit -qm "single issue-15" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
out=$(cd "$ROOT/s65/canon" && "$RC" 15 --dry-run 2>&1)
rc=$?
check "bare single-claim dry-run exits 0" "$rc" "0"
contains "freezes the only id" "$out" "issue-15-only-lane"
contains "plans that one release" "$out" "release claim:   issue-15-only-lane"
lacks    "does not plan issue-115" "$out" "issue-115-unrelated"

# Per-file single bare green.
new_repo "$ROOT/s65f"
(
  cd "$ROOT/s65f/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  printf 'claim: issue-15-only-lane\nissue: 15\nclaimed: 2026-08-01T00:00:00Z\nscope: src/only\nsession: a\n' \
    > docs/claims/issue-15-only-lane.md
  : > docs/active-work.md
  git add -A && git commit -qm "one per-file claim" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
out=$(cd "$ROOT/s65f/canon" && "$RC" 15 --dry-run 2>&1)
rc=$?
check "per-file bare single dry-run exits 0" "$rc" "0"
contains "per-file freezes only id" "$out" "issue-15-only-lane"

echo "#65 · exact --claim-id literal; reject regex / wrong-issue"
new_repo "$ROOT/x65"
# Regex-looking id must fail before any plan/mutation (literal exact only).
out=$(cd "$ROOT/x65/canon" && "$RC" 15 --claim-id 'issue-15-.*' --dry-run 2>&1)
rc=$?
check "regex-looking claim-id exits 1" "$rc" "1"
contains "rejects non-literal claim-id" "$out" "literal exact claim id"
lacks    "regex claim-id no dry-run plan" "$out" "DRY RUN would"
lacks    "regex does not select both siblings" "$out" "release claim:   issue-15-checkout-totals"

out=$(cd "$ROOT/x65/canon" && "$RC" 15 --claim-id 'issue-15-*' --dry-run 2>&1)
rc=$?
check "glob-looking claim-id exits 1" "$rc" "1"
contains "rejects glob claim-id" "$out" "literal exact claim id"

# Wrong issue: issue-5 id with positional 15.
out=$(cd "$ROOT/x65/canon" && "$RC" 15 --claim-id issue-5-monorepo-thing --dry-run 2>&1)
rc=$?
check "wrong-issue claim-id exits 1" "$rc" "1"
contains "wrong-issue rejected" "$out" "does not belong to issue 15"
lacks    "wrong-issue no dry-run plan" "$out" "DRY RUN would"

out=$(cd "$ROOT/x65/canon" && "$RC" 15 --claim-id issue-5-monorepo-thing 2>&1)
rc=$?
check "wrong-issue real invoke exits 1" "$rc" "1"
table=$(cd "$ROOT/x65/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
contains "wrong-issue left all rows" "$table" "issue-5-monorepo-thing"
contains "wrong-issue left issue-15 rows" "$table" "issue-15-checkout-totals"

# Empty / absent claim-id.
out=$(cd "$ROOT/x65/canon" && "$RC" 15 --claim-id '' --dry-run 2>&1)
rc=$?
check "empty claim-id exits 1" "$rc" "1"
contains "empty claim-id named" "$out" "non-empty literal claim id"

out=$(cd "$ROOT/x65/canon" && "$RC" 15 --claim-id issue-15-does-not-exist --dry-run 2>&1)
rc=$?
check "absent claim-id exits 1" "$rc" "1"
contains "absent claim-id named" "$out" "no live claim"

echo "#65 · legacy row: scope text mentioning target id is inert"
new_repo "$ROOT/leg65"
(
  cd "$ROOT/leg65/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-checkout-totals | src/checkout | session:a |
| 2026-08-01 | issue-16-other | depends on issue-15-checkout-totals | session:x |
| 2026-08-01 | issue-15-demo-stale-plan | src/demo | session:b |
TABLE
  git add -A && git commit -qm "scope mentions target id" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
(cd "$ROOT/leg65/canon" && "$RC" 15 --claim-id issue-15-checkout-totals) >/dev/null 2>&1
table=$(cd "$ROOT/leg65/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
# Scope text of issue-16-other still mentions the released id; only the claim-id
# column row for the target must be gone (pipe-delimited first-column match).
lacks    "target claim-id column row gone" "$table" "| issue-15-checkout-totals |"
contains "unrelated row survives despite scope text" "$table" "issue-16-other"
contains "sibling claim-id column survives" "$table" "| issue-15-demo-stale-plan |"
contains "scope still mentions released id text" "$table" "depends on issue-15-checkout-totals"

echo "#65 · mixed legacy+per-file duplicate counts as one"
new_repo "$ROOT/dup65"
(
  cd "$ROOT/dup65/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  printf 'claim: issue-15-only-lane\nissue: 15\nclaimed: 2026-08-01T00:00:00Z\nscope: src/only\nsession: a\n' \
    > docs/claims/issue-15-only-lane.md
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
TABLE
  git add -A && git commit -qm "same id in both ledgers" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
# Bare must treat as single claim (not multi refuse).
out=$(cd "$ROOT/dup65/canon" && "$RC" 15 --dry-run 2>&1)
rc=$?
check "mixed duplicate bare dry-run exits 0" "$rc" "0"
contains "mixed counts as one id" "$out" "issue-15-only-lane"
lacks    "mixed not multi-refuse" "$out" "live claims"
# Real release removes both representations.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then exit 0; fi
    echo "${GH_LABELS:-}"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
out=$(cd "$ROOT/dup65/canon" && GH_LABELS="" "$RC" 15 --repo acme/app 2>&1)
rc=$?
check "mixed duplicate real release exits 0" "$rc" "0"
files=$(cd "$ROOT/dup65/canon" && git fetch -q origin && git ls-tree --name-only origin/main docs/claims/ 2>/dev/null || true)
lacks    "per-file representation removed" "$files" "issue-15-only-lane"
table=$(cd "$ROOT/dup65/canon" && git show origin/main:docs/active-work.md 2>/dev/null || true)
lacks    "legacy representation removed" "$table" "issue-15-only-lane"

echo "#65 · prefixes/namespaces and issue 15 vs 115 remain safe"
new_repo "$ROOT/ns65"
out=$(cd "$ROOT/ns65/canon" && "$RC" 15 --claim-id issue-15-checkout-totals --dry-run 2>&1)
lacks    "15 never selects 115" "$out" "issue-115-unrelated"
out=$(cd "$ROOT/ns65/canon" && "$RC" 115 --claim-id issue-115-unrelated --dry-run 2>&1)
rc=$?
check "issue 115 exact dry-run exits 0" "$rc" "0"
contains "115 releases its own id" "$out" "issue-115-unrelated"
lacks    "115 does not select 15" "$out" "issue-15-checkout-totals"
out=$(cd "$ROOT/ns65/canon" && "$RC" 5 --prefix template --claim-id issue-template-5-palette-tokens --dry-run 2>&1)
contains "namespaced template id" "$out" "issue-template-5-palette-tokens"

echo "#65 · sibling at mutation boundary keeps row and label"
# Start with one claim. On the bare origin, a post-receive hook injects a
# sibling claim *after* the cleanup push (plumbing, no worktree) so the
# script's post-strip re-read keeps agent-claimed.
new_repo "$ROOT/bound65"
(
  cd "$ROOT/bound65/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
TABLE
  git add -A && git commit -qm "single before race" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
# post-receive: append a sibling row via commit-tree/update-ref (portable on bare).
cat > "$ROOT/bound65/origin/hooks/post-receive" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
while read -r _old new ref; do
  case "$ref" in
    refs/heads/main|refs/heads/master) ;;
    *) continue ;;
  esac
  content=$(git cat-file -p "$new:docs/active-work.md" 2>/dev/null || true)
  [[ -n "$content" ]] || continue
  printf '%s\n' "$content" | grep -qF 'issue-15-sibling-racer' && continue
  newcontent=$(printf '%s\n' "$content" '| 2026-08-02 | issue-15-sibling-racer | src/race | session:z |')
  newblob=$(printf '%s\n' "$newcontent" | git hash-object -w --stdin)
  # Rebuild the root tree from $new, replacing docs/active-work.md.
  export GIT_INDEX_FILE
  GIT_INDEX_FILE=$(mktemp "${TMPDIR:-/tmp}/gibson-idx.XXXXXX")
  git read-tree "$new"
  git update-index --add --cacheinfo "100644,$newblob,docs/active-work.md"
  tree=$(git write-tree)
  commit=$(printf '%s\n' "race: sibling at mutation boundary" | git commit-tree "$tree" -p "$new")
  git update-ref "$ref" "$commit"
  rm -f "$GIT_INDEX_FILE"
  unset GIT_INDEX_FILE
done
HOOK
chmod +x "$ROOT/bound65/origin/hooks/post-receive"

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

out=$(cd "$ROOT/bound65/canon" && "$RC" 15 --repo acme/app 2>&1)
rc=$?
# Sibling re-read → keep label (no edit). Exit 0 complete.
check "mutation-boundary release exits 0" "$rc" "0"
contains "keeps label for boundary sibling" "$out" "residual claims remain"
contains "names the raced sibling" "$out" "issue-15-sibling-racer"
lacks    "does not remove label when sibling raced in" "$out" "MUTATED-LABEL"
lacks    "does not claim label removed" "$out" "removed agent-claimed"
table=$(cd "$ROOT/bound65/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
contains "raced sibling row survives" "$table" "issue-15-sibling-racer"
lacks    "original target still released" "$table" "| issue-15-only-lane |"

echo "#65 · scoped cleanup preserves sibling worktree/branch/label (legacy)"
new_repo "$ROOT/sc65"
mkdir -p "$ROOT/sc65/wt-15-checkout-totals" "$ROOT/sc65/wt-15-demo-stale-plan"
echo target > "$ROOT/sc65/wt-15-checkout-totals/marker"
echo sibling > "$ROOT/sc65/wt-15-demo-stale-plan/marker"
(
  cd "$ROOT/sc65/canon" || exit 1
  git branch -f "feat/15-checkout-totals" HEAD
  git branch -f "feat/15-demo-stale-plan" HEAD
) >/dev/null 2>&1
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
out=$(cd "$ROOT/sc65/canon" && "$RC" 15 --claim-id issue-15-checkout-totals --repo acme/app 2>&1)
rc=$?
check "scoped legacy release exits 0" "$rc" "0"
contains "keeps label for residual sibling" "$out" "residual claims remain"
lacks    "scoped does not strip label" "$out" "MUTATED-LABEL"
[[ ! -f "$ROOT/sc65/wt-15-checkout-totals/marker" ]] \
  && ok "target worktree removed" \
  || bad "target worktree still present"
[[ -f "$ROOT/sc65/wt-15-demo-stale-plan/marker" ]] \
  && ok "sibling worktree preserved" \
  || bad "sibling worktree was removed"
br_t=$(git -C "$ROOT/sc65/canon" branch --list 'feat/15-checkout-totals')
br_s=$(git -C "$ROOT/sc65/canon" branch --list 'feat/15-demo-stale-plan')
[[ -z "$br_t" ]] && ok "target branch deleted" || bad "target branch still present"
[[ -n "$br_s" ]] && ok "sibling branch preserved" || bad "sibling branch was deleted"
table=$(cd "$ROOT/sc65/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
lacks    "target row gone" "$table" "issue-15-checkout-totals"
contains "sibling row kept" "$table" "issue-15-demo-stale-plan"
contains "unrelated 115 kept" "$table" "issue-115-unrelated"

echo "#65 · push rejected: exit 3, target remains, no remove-label"
# Authoritative main push rejected → target claim still live. Residual plan
# must not authorize label removal (live-claim / no-label inconsistency).
new_repo "$ROOT/pushrej65"
(
  cd "$ROOT/pushrej65/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
TABLE
  git add -A && git commit -qm "single claim for push reject" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
cat > "$ROOT/pushrej65/origin/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
echo "push rejected by fixture" >&2
exit 1
HOOK
chmod +x "$ROOT/pushrej65/origin/hooks/pre-receive"
mkdir -p "$ROOT/bin"
GH_LOG="$ROOT/pushrej65/gh.log"
: > "$GH_LOG"
cat > "$ROOT/bin/gh" <<FAKE
#!/usr/bin/env bash
echo "CALL \$*" >> "$GH_LOG"
case "\$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "\$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
out=$(cd "$ROOT/pushrej65/canon" && "$RC" 15 --repo acme/app 2>&1)
rc=$?
check "push-rejected release exits 3" "$rc" "3"
contains "names strip failure" "$out" "claim NOT removed"
contains "names target still live" "$out" "still live"
contains "preserves label on incomplete" "$out" "preserving agent-claimed"
contains "incomplete banner" "$out" "INCOMPLETE"
lacks    "does not call remove-label (MUTATED)" "$out" "MUTATED-LABEL"
lacks    "does not claim label removed" "$out" "removed agent-claimed"
lacks    "does not claim OK on push reject" "$out" "OK —"
if grep -qF -- 'remove-label' "$GH_LOG" 2>/dev/null; then
  bad "fake-gh must not receive remove-label on push reject"
else
  ok "fake-gh contains no remove-label call"
fi
table=$(cd "$ROOT/pushrej65/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
contains "target claim remains on main" "$table" "issue-15-only-lane"

echo "#65 · post-push reread fetch failure: preserve label, exit 3"
# Push succeeds; a PATH git wrapper fails only the post-mutation `git fetch`
# (startup + strip fetch already ran). Must not fall back to the pre-mutation
# residual plan and remove the label.
new_repo "$ROOT/rereadref65"
(
  cd "$ROOT/rereadref65/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
TABLE
  git add -A && git commit -qm "single claim for fetch fail" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
REAL_GIT=$(command -v git)
FETCH_COUNT="$ROOT/rereadref65/fetch.count"
: > "$FETCH_COUNT"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/git" <<FAKE
#!/usr/bin/env bash
if [[ "\${1:-}" == "fetch" ]]; then
  n=\$(cat "$FETCH_COUNT" 2>/dev/null || echo 0)
  n=\$((n + 1))
  printf '%s\n' "\$n" > "$FETCH_COUNT"
  # 1=startup, 2=strip_claim_rows, 3=authoritative_post_mutation_reread
  if [[ "\$n" -ge 3 ]]; then
    echo "fetch failed by fixture" >&2
    exit 1
  fi
fi
exec "$REAL_GIT" "\$@"
FAKE
chmod +x "$ROOT/bin/git"
GH_LOG="$ROOT/rereadref65/gh.log"
: > "$GH_LOG"
cat > "$ROOT/bin/gh" <<FAKE
#!/usr/bin/env bash
echo "CALL \$*" >> "$GH_LOG"
case "\$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "\$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
out=$(cd "$ROOT/rereadref65/canon" && "$RC" 15 --repo acme/app 2>&1)
rc=$?
check "post-push fetch failure exits 3" "$rc" "3"
contains "names post-cleanup fetch failure" "$out" "post-cleanup fetch of origin failed"
contains "preserves label on reread fail" "$out" "preserving agent-claimed"
contains "incomplete on reread fail" "$out" "INCOMPLETE"
lacks    "no MUTATED-LABEL on reread fail" "$out" "MUTATED-LABEL"
lacks    "no removed claim on reread fail" "$out" "removed agent-claimed"
lacks    "no false OK on reread fail" "$out" "OK —"
if grep -qF -- 'remove-label' "$GH_LOG" 2>/dev/null; then
  bad "fake-gh must not receive remove-label on post-push fetch failure"
else
  ok "fake-gh no remove-label on fetch failure"
fi
# Drop the git wrapper so later cases use the real git.
rm -f "$ROOT/bin/git"

echo "#65 · post-push missing claim blob: preserve label, exit 3, path/object diag"
# After strip push, post-mutation fetch is wrapped: real fetch runs, then the
# local origin/main tip is rewritten to include docs/claims/issue-15-ghost.md
# whose blob object is immediately deleted from the client object store.
# Reread must fail closed with path/object diagnostic (not a false green).
new_repo "$ROOT/rereadblob65"
(
  cd "$ROOT/rereadblob65/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  printf 'claim: issue-15-only-lane\nissue: 15\nclaimed: 2026-08-01T00:00:00Z\nscope: src/only\nsession: a\n' \
    > docs/claims/issue-15-only-lane.md
  : > docs/active-work.md
  git add -A && git commit -qm "per-file single claim" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
REAL_GIT=$(command -v git)
FETCH_COUNT="$ROOT/rereadblob65/fetch.count"
: > "$FETCH_COUNT"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/git" <<FAKE
#!/usr/bin/env bash
if [[ "\${1:-}" == "fetch" ]]; then
  n=\$(cat "$FETCH_COUNT" 2>/dev/null || echo 0)
  n=\$((n + 1))
  printf '%s\n' "\$n" > "$FETCH_COUNT"
  # 1=startup, 2=strip, 3=post-mutation authoritative reread
  if [[ "\$n" -ge 3 ]]; then
    "$REAL_GIT" "\$@" || exit \$?
    # Rewrite origin/main tip with a claim leaf, then drop that blob object.
    blob=\$(printf 'ghost claim payload\\n' | "$REAL_GIT" hash-object -w --stdin) || exit 1
    export GIT_INDEX_FILE
    GIT_INDEX_FILE=\$(mktemp "\${TMPDIR:-/tmp}/gibson-idx.XXXXXX") || exit 1
    "$REAL_GIT" read-tree origin/main || exit 1
    "$REAL_GIT" rm -r --cached -q docs/claims 2>/dev/null || true
    "$REAL_GIT" update-index --add --cacheinfo "100644,\$blob,docs/claims/issue-15-ghost.md" || exit 1
    tree=\$("$REAL_GIT" write-tree) || exit 1
    parent=\$("$REAL_GIT" rev-parse origin/main) || exit 1
    commit=\$(printf '%s\\n' "fixture: missing claim blob" | "$REAL_GIT" commit-tree "\$tree" -p "\$parent") || exit 1
    "$REAL_GIT" update-ref refs/remotes/origin/main "\$commit" || exit 1
    rm -f "\$GIT_INDEX_FILE"
    unset GIT_INDEX_FILE
    obj=\$("$REAL_GIT" rev-parse --git-path "objects/\${blob:0:2}/\${blob:2}")
    rm -f "\$obj"
    exit 0
  fi
fi
exec "$REAL_GIT" "\$@"
FAKE
chmod +x "$ROOT/bin/git"
GH_LOG="$ROOT/rereadblob65/gh.log"
: > "$GH_LOG"
cat > "$ROOT/bin/gh" <<FAKE
#!/usr/bin/env bash
echo "CALL \$*" >> "$GH_LOG"
case "\$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "\$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
out=$(cd "$ROOT/rereadblob65/canon" && "$RC" 15 --repo acme/app 2>&1)
rc=$?
check "post-push missing claim blob exits 3" "$rc" "3"
contains "path/object diagnostic for claim blob" "$out" "docs/claims/issue-15-ghost.md"
contains "names unreadable/corrupt blob post-push" "$out" "unreadable/corrupt"
contains "preserves label on missing blob" "$out" "preserving agent-claimed"
contains "incomplete on missing blob" "$out" "INCOMPLETE"
lacks    "no MUTATED-LABEL on missing blob" "$out" "MUTATED-LABEL"
lacks    "no removed claim on missing blob" "$out" "removed agent-claimed"
lacks    "no false OK on missing blob" "$out" "OK —"
if grep -qF -- 'remove-label' "$GH_LOG" 2>/dev/null; then
  bad "fake-gh must not receive remove-label on post-push missing claim blob"
else
  ok "fake-gh no remove-label on missing claim blob"
fi
rm -f "$ROOT/bin/git"

echo "#65 · post-push wrong claims object shape: preserve label, exit 3"
# post-receive makes docs/claims a blob (not a tree) after a successful strip.
new_repo "$ROOT/rereadshape65"
(
  cd "$ROOT/rereadshape65/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
TABLE
  git add -A && git commit -qm "legacy single" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
cat > "$ROOT/rereadshape65/origin/hooks/post-receive" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
while read -r _old new ref; do
  case "$ref" in
    refs/heads/main|refs/heads/master) ;;
    *) continue ;;
  esac
  blob=$(printf 'claims path is a blob not a tree\n' | git hash-object -w --stdin)
  export GIT_INDEX_FILE
  GIT_INDEX_FILE=$(mktemp "${TMPDIR:-/tmp}/gibson-idx.XXXXXX")
  git read-tree "$new"
  git rm -r --cached -q docs/claims 2>/dev/null || true
  git update-index --add --cacheinfo "100644,$blob,docs/claims"
  tree=$(git write-tree)
  commit=$(printf '%s\n' "docs/claims is a blob" | git commit-tree "$tree" -p "$new")
  git update-ref "$ref" "$commit"
  rm -f "$GIT_INDEX_FILE"
  unset GIT_INDEX_FILE
done
HOOK
chmod +x "$ROOT/rereadshape65/origin/hooks/post-receive"
mkdir -p "$ROOT/bin"
GH_LOG="$ROOT/rereadshape65/gh.log"
: > "$GH_LOG"
cat > "$ROOT/bin/gh" <<FAKE
#!/usr/bin/env bash
echo "CALL \$*" >> "$GH_LOG"
case "\$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "\$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
out=$(cd "$ROOT/rereadshape65/canon" && "$RC" 15 --repo acme/app 2>&1)
rc=$?
check "post-push wrong claims shape exits 3" "$rc" "3"
contains "names unexpected claims mode/type" "$out" "docs/claims"
contains "names want tree" "$out" "040000 tree"
contains "preserves label on shape fail" "$out" "preserving agent-claimed"
lacks    "no MUTATED-LABEL on shape fail" "$out" "MUTATED-LABEL"
lacks    "no false OK on shape fail" "$out" "OK —"
if grep -qF -- 'remove-label' "$GH_LOG" 2>/dev/null; then
  bad "fake-gh must not receive remove-label on wrong object shape"
else
  ok "fake-gh no remove-label on wrong object shape"
fi

echo "#65 · post-push origin/main gone + stale local empty: exit 3, no remove-label"
# Remote starts with one claim. Local main is rewritten to a stale empty ledger
# (not pushed). Cleanup push to origin/main succeeds. Post-mutation fetch then
# makes origin/main unreadable. Reread must bind only to origin/main (the exact
# remote branch that received the push) and fail closed — never fall back to
# stale empty local main and authorize remove-label / OK.
new_repo "$ROOT/rereadlocal65"
(
  cd "$ROOT/rereadlocal65/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
TABLE
  git add -A && git commit -qm "single claim on remote main" && git push -q origin main
  # Stale empty local main (not pushed): would falsely look like "no residual"
  # if post-mutation reread fell back past missing origin/main.
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
TABLE
  git add -A && git commit -qm "stale empty local main"
  git checkout -q long-lived-feature
) >/dev/null 2>&1
REAL_GIT=$(command -v git)
FETCH_COUNT="$ROOT/rereadlocal65/fetch.count"
: > "$FETCH_COUNT"
PUSH_BASE_LOG="$ROOT/rereadlocal65/push-base.log"
: > "$PUSH_BASE_LOG"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/git" <<FAKE
#!/usr/bin/env bash
# Record the exact remote branch named in a successful cleanup push.
if [[ "\${1:-}" == "push" && "\${2:-}" == "origin" ]]; then
  for a in "\$@"; do
    case "\$a" in
      HEAD:main|HEAD:master)
        printf '%s\n' "\$a" >> "$PUSH_BASE_LOG"
        ;;
    esac
  done
fi
if [[ "\${1:-}" == "fetch" ]]; then
  n=\$(cat "$FETCH_COUNT" 2>/dev/null || echo 0)
  n=\$((n + 1))
  printf '%s\n' "\$n" > "$FETCH_COUNT"
  # 1=startup, 2=strip_claim_rows, 3=authoritative_post_mutation_reread
  if [[ "\$n" -ge 3 ]]; then
    "$REAL_GIT" "\$@" || exit \$?
    # Drop the exact remote-tracking ref that received the cleanup push.
    "$REAL_GIT" update-ref -d refs/remotes/origin/main 2>/dev/null || true
    "$REAL_GIT" update-ref -d refs/remotes/origin/master 2>/dev/null || true
    exit 0
  fi
fi
exec "$REAL_GIT" "\$@"
FAKE
chmod +x "$ROOT/bin/git"
GH_LOG="$ROOT/rereadlocal65/gh.log"
: > "$GH_LOG"
cat > "$ROOT/bin/gh" <<FAKE
#!/usr/bin/env bash
echo "CALL \$*" >> "$GH_LOG"
case "\$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "\$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
out=$(cd "$ROOT/rereadlocal65/canon" && "$RC" 15 --repo acme/app 2>&1)
rc=$?
check "post-push missing origin/main exits 3" "$rc" "3"
contains "names exact remote ref origin/main" "$out" "origin/main"
contains "names absent/unreadable remote ref" "$out" "absent/unreadable"
contains "names no local fallback" "$out" "no local fallback"
contains "preserves label when origin/main gone" "$out" "preserving agent-claimed"
contains "incomplete when origin/main gone" "$out" "INCOMPLETE"
lacks    "no MUTATED-LABEL when origin/main gone" "$out" "MUTATED-LABEL"
lacks    "no removed claim when origin/main gone" "$out" "removed agent-claimed"
lacks    "no false OK when origin/main gone" "$out" "OK —"
if grep -qF -- 'remove-label' "$GH_LOG" 2>/dev/null; then
  bad "fake-gh must not receive remove-label when origin/main gone after push"
else
  ok "fake-gh no remove-label when origin/main gone"
fi
# Pin: cleanup push targeted main (HEAD:main), so reread must require origin/main.
if grep -qxF -- 'HEAD:main' "$PUSH_BASE_LOG" 2>/dev/null; then
  ok "cleanup push pinned to remote branch main (HEAD:main)"
else
  bad "cleanup push must target HEAD:main (got: $(tr '\n' ' ' <"$PUSH_BASE_LOG" 2>/dev/null))"
fi
rm -f "$ROOT/bin/git"

echo "#65 · post-push cleanup-SHA capture failure: preserve label, exit 3, no OK"
# Cleanup push succeeds. Only the post-push capture
#   git -C "$tmpwt" rev-parse HEAD
# is forced to fail (empty CLEANUP_PUSHED_SHA). Earlier rev-parse and the push
# itself must still succeed. Reread must treat missing capture as hard incomplete:
# exit 3, preserve agent-claimed, never remove-label, never print OK.
new_repo "$ROOT/rereadcap65"
(
  cd "$ROOT/rereadcap65/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
TABLE
  git add -A && git commit -qm "single claim for capture fail" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
REAL_GIT=$(command -v git)
PUSH_OK="$ROOT/rereadcap65/push.ok"
: > "$PUSH_OK"
rm -f "$PUSH_OK"
CAPTURE_HIT="$ROOT/rereadcap65/capture.hit"
: > "$CAPTURE_HIT"
rm -f "$CAPTURE_HIT"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/git" <<FAKE
#!/usr/bin/env bash
# After a successful cleanup push to origin, fail only the post-push capture:
# git -C <disposable-worktree> rev-parse HEAD
# Do not break earlier rev-parse, commit, or the push itself.
if [[ "\${1:-}" == "push" && "\${2:-}" == "origin" ]]; then
  "$REAL_GIT" "\$@"
  rc=\$?
  if [[ \$rc -eq 0 ]]; then
    for a in "\$@"; do
      case "\$a" in
        HEAD:main|HEAD:master) : > "$PUSH_OK" ;;
      esac
    done
  fi
  exit \$rc
fi
if [[ -f "$PUSH_OK" && "\${1:-}" == "-C" && "\${3:-}" == "rev-parse" && "\${4:-}" == "HEAD" ]]; then
  # disposable strip worktree only (not arbitrary -C rev-parse)
  case "\${2:-}" in
    *gibson-release-claim*)
      : > "$CAPTURE_HIT"
      echo "cleanup SHA capture failed by fixture" >&2
      exit 1
      ;;
  esac
fi
exec "$REAL_GIT" "\$@"
FAKE
chmod +x "$ROOT/bin/git"
GH_LOG="$ROOT/rereadcap65/gh.log"
: > "$GH_LOG"
cat > "$ROOT/bin/gh" <<FAKE
#!/usr/bin/env bash
echo "CALL \$*" >> "$GH_LOG"
case "\$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "\$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
out=$(cd "$ROOT/rereadcap65/canon" && "$RC" 15 --repo acme/app 2>&1)
rc=$?
check "post-push cleanup-SHA capture failure exits 3" "$rc" "3"
contains "names missing/unreadable cleanup-pushed SHA" "$out" "cleanup-pushed SHA"
contains "names cannot prove lineage" "$out" "cannot prove lineage"
contains "preserves label on capture fail" "$out" "preserving agent-claimed"
contains "incomplete on capture fail" "$out" "INCOMPLETE"
lacks    "no MUTATED-LABEL on capture fail" "$out" "MUTATED-LABEL"
lacks    "no removed claim on capture fail" "$out" "removed agent-claimed"
lacks    "no false OK on capture fail" "$out" "OK —"
if [[ -f "$PUSH_OK" ]]; then
  ok "cleanup push still succeeded before capture failure"
else
  bad "fixture must allow cleanup push to succeed before capture fails"
fi
if [[ -f "$CAPTURE_HIT" ]]; then
  ok "fixture hit only the post-push cleanup-SHA capture"
else
  bad "fixture must force post-push git -C ... rev-parse HEAD to fail"
fi
if grep -qF -- 'remove-label' "$GH_LOG" 2>/dev/null; then
  bad "fake-gh must not receive remove-label on cleanup-SHA capture failure"
else
  ok "fake-gh no remove-label on cleanup-SHA capture failure"
fi
# Claim row should still be gone on origin (push succeeded) even though label stays.
table=$(cd "$ROOT/rereadcap65/canon" && "$REAL_GIT" fetch -q origin && "$REAL_GIT" show origin/main:docs/active-work.md)
lacks    "target still stripped after capture-fail push" "$table" "issue-15-only-lane"
rm -f "$ROOT/bin/git"

echo "#65 · successful final target removal still removes/verifies label"
new_repo "$ROOT/finalok65"
(
  cd "$ROOT/finalok65/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
TABLE
  git add -A && git commit -qm "final lane" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
mkdir -p "$ROOT/bin"
# After remove-label, view reports empty labels (verified gone).
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      echo "MUTATED-LABEL"
      # flip label state for subsequent view
      echo "" > "${GH_STATE:-/tmp/gh-state}"
      exit 0
    fi
    if [[ -f "${GH_STATE:-/tmp/gh-state}" ]]; then
      echo ""
    else
      echo "agent-claimed,tier-b"
    fi
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
export GH_STATE="$ROOT/finalok65/gh-state"
rm -f "$GH_STATE"
out=$(cd "$ROOT/finalok65/canon" && "$RC" 15 --repo acme/app 2>&1)
rc=$?
check "final successful removal exits 0" "$rc" "0"
contains "removed label verified" "$out" "removed agent-claimed"
contains "claims OK" "$out" "OK —"
lacks    "not incomplete on success" "$out" "INCOMPLETE"
table=$(cd "$ROOT/finalok65/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
lacks    "target gone on success" "$table" "issue-15-only-lane"

echo "#73 · --keep-worktree preserves target worktree; default still removes it"
# Narrow option for claim-reaper: release the claim row without deleting the
# on-disk worktree. Default behaviour (no flag) must still remove the worktree.
new_repo "$ROOT/kw73"
mkdir -p "$ROOT/kw73/wt-15-only-lane"
echo keep-me > "$ROOT/kw73/wt-15-only-lane/marker"
(
  cd "$ROOT/kw73/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
| 2026-08-01 | issue-115-unrelated | src/x | session:c |
TABLE
  git add -A && git commit -qm "single lane for keep-worktree" && git push -q origin main
  git branch -f "feat/15-only-lane" HEAD
  git checkout -q long-lived-feature
) >/dev/null 2>&1
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      # final lane: allow remove-label to succeed for completeness
      exit 0
    fi
    # After edit, labels empty; before edit, agent-claimed present.
    if [[ -f "${GH_STATE:-/tmp/gh-state-kw}" ]]; then
      echo ""
    else
      echo "agent-claimed,tier-b"
    fi
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

out=$(cd "$ROOT/kw73/canon" && "$RC" 15 --claim-id issue-15-only-lane --keep-worktree --keep-branch --dry-run 2>&1)
rc=$?
check "keep-worktree dry-run exits 0" "$rc" "0"
contains "dry-run keeps worktree" "$out" "KEEP worktree:"
contains "dry-run keeps branch" "$out" "KEEP branch:"
lacks    "dry-run does not plan remove worktree" "$out" "remove worktree:"
lacks    "dry-run does not plan delete branch" "$out" "delete branch:"

# Apply with --keep-worktree: claim row gone, worktree remains, branch kept.
export GH_STATE="$ROOT/kw73/gh-state"
rm -f "$GH_STATE"
# Make issue-view flip empty after remove so verified label removal can complete.
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      echo edited >> "${GH_LOG:-/dev/null}"
      : > "${GH_STATE:-/tmp/gh-state-kw}"
      exit 0
    fi
    if [[ -f "${GH_STATE:-/tmp/gh-state-kw}" ]]; then
      echo ""
    else
      echo "agent-claimed,tier-b"
    fi
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export GH_LOG="$ROOT/kw73/gh.log"
export GH_STATE="$ROOT/kw73/gh-state"
rm -f "$GH_STATE" "$GH_LOG"
out=$(cd "$ROOT/kw73/canon" && "$RC" 15 --claim-id issue-15-only-lane --keep-worktree --keep-branch --repo acme/app 2>&1)
rc=$?
check "keep-worktree apply exits 0" "$rc" "0"
contains "says keeping worktree" "$out" "keeping worktree"
[[ -f "$ROOT/kw73/wt-15-only-lane/marker" ]] \
  && ok "keep-worktree left target worktree on disk" \
  || bad "keep-worktree removed target worktree"
br_keep=$(git -C "$ROOT/kw73/canon" branch --list 'feat/15-only-lane')
[[ -n "$br_keep" ]] && ok "keep-branch left feature branch" || bad "keep-branch deleted feature branch"
table=$(cd "$ROOT/kw73/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
lacks    "keep-worktree still released claim row" "$table" "issue-15-only-lane"
contains "unrelated row survives keep-worktree" "$table" "issue-115-unrelated"

# Default (no --keep-worktree) still removes the worktree.
new_repo "$ROOT/kw73def"
mkdir -p "$ROOT/kw73def/wt-15-only-lane"
echo gone > "$ROOT/kw73def/wt-15-only-lane/marker"
(
  cd "$ROOT/kw73def/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-15-only-lane | src/only | session:a |
| 2026-08-01 | issue-115-unrelated | src/x | session:c |
TABLE
  git add -A && git commit -qm "default removes worktree" && git push -q origin main
  git branch -f "feat/15-only-lane" HEAD
  git checkout -q long-lived-feature
) >/dev/null 2>&1
export GH_STATE="$ROOT/kw73def/gh-state"
export GH_LOG="$ROOT/kw73def/gh.log"
rm -f "$GH_STATE" "$GH_LOG"
out=$(cd "$ROOT/kw73def/canon" && "$RC" 15 --claim-id issue-15-only-lane --keep-branch --repo acme/app 2>&1)
rc=$?
check "default (no keep-worktree) still exits 0" "$rc" "0"
[[ ! -f "$ROOT/kw73def/wt-15-only-lane/marker" ]] \
  && ok "default still removes target worktree" \
  || bad "default left target worktree (regression)"
br_def=$(git -C "$ROOT/kw73def/canon" branch --list 'feat/15-only-lane')
[[ -n "$br_def" ]] && ok "default+keep-branch left branch" || bad "default deleted branch despite --keep-branch"
table=$(cd "$ROOT/kw73def/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
lacks    "default still released claim row" "$table" "issue-15-only-lane"

# ---------------------------------------------------------------------------
echo "#73 · claimed prune: renewal race leaves worktree+branch+label intact (rc=3)"
# CAS frozen at old blob; remote claim renews before strip. Must not delete the
# exact registered worktree (ordering: CAS before destructive prune).
new_repo "$ROOT/renew_wt"
WT_REG="$ROOT/renew_wt/wt-registered-exact"
(
  cd "$ROOT/renew_wt/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  cat > docs/claims/issue-103-renew-wt.md <<EOF
claim: issue-103-renew-wt
issue: 103
claimed: 2026-08-01T00:00:00Z
scope: x
session: t
branch: feat/103-renew-wt
worktree: $WT_REG
EOF
  : > docs/active-work.md
  git add -A && git commit -qm "claim for renew-wt" && git push -q origin main
  git rev-parse HEAD:docs/claims/issue-103-renew-wt.md > "$ROOT/renew_wt/old_blob"
  git worktree add -b feat/103-renew-wt "$WT_REG" HEAD >/dev/null 2>&1
  echo survive > "$WT_REG/marker"
  # Renew claim on remote (new blob) while caller still holds old CAS key.
  # Clone with explicit -b main: a bare origin whose HEAD still points at the
  # nonexistent master ref leaves the clone with no working tree, so the renew
  # never lands and CAS never sees a mismatch (#94).
  git clone -q -b main "$ROOT/renew_wt/origin" "$ROOT/renew_wt/other" 2>/dev/null
  cd "$ROOT/renew_wt/other" || exit 1
  mkdir -p docs/claims
  cat > docs/claims/issue-103-renew-wt.md <<EOF
claim: issue-103-renew-wt
issue: 103
claimed: 2026-08-02T12:00:00Z
scope: x
session: t
branch: feat/103-renew-wt
worktree: $WT_REG
EOF
  git add -A && git commit -qm "renew claim" && git push -q origin main
  cd "$ROOT/renew_wt/canon" || exit 1
  git checkout -q long-lived-feature 2>/dev/null || git checkout -q -b long-lived-feature
) >/dev/null 2>&1
OLD_BLOB=$(cat "$ROOT/renew_wt/old_blob")
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      echo "LABEL-MUTATION-SHOULD-NOT-HAPPEN" >&2
      exit 0
    fi
    echo "agent-claimed,tier-b"
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
out=$(
  cd "$ROOT/renew_wt/canon" && GIBSON_CANONICAL="$ROOT/renew_wt/canon" "$RC" 103 \
    --claim-id issue-103-renew-wt \
    --expected-claim-blob "$OLD_BLOB" \
    --expected-source file \
    --expected-claim-path docs/claims/issue-103-renew-wt.md \
    --worktree-path "$WT_REG" \
    --expected-branch feat/103-renew-wt \
    --keep-branch \
    --repo acme/app 2>&1
)
rc=$?
check "renewal race exits 3 (incomplete)" "$rc" "3"
contains "CAS blob mismatch / refuse" "$out" "CAS blob OID mismatch"
contains "incomplete banner" "$out" "INCOMPLETE"
[[ -f "$WT_REG/marker" ]] \
  && ok "renewal race left registered worktree on disk" \
  || bad "renewal race deleted registered worktree (ordering bug)"
br=$(git -C "$ROOT/renew_wt/canon" branch --list 'feat/103-renew-wt')
[[ -n "$br" ]] && ok "renewal race left feature branch" || bad "renewal race deleted feature branch"
files=$(cd "$ROOT/renew_wt/canon" && git fetch -q origin && git ls-tree --name-only origin/main docs/claims/)
contains "renewed claim row still live" "$files" "issue-103-renew-wt.md"
# Label preserved (gh issue view still reports agent-claimed; no successful remove)
contains "preserves agent-claimed on incomplete" "$out" "preserving agent-claimed"
lacks    "must not claim full success" "$out" "OK — claim released"

# ---------------------------------------------------------------------------
echo "#73 · claimed prune: successful path removes worktree only after verified cleanup"
new_repo "$ROOT/prune_order"
WT_OK="$ROOT/prune_order/wt-exact-ok"
(
  cd "$ROOT/prune_order/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  cat > docs/claims/issue-104-prune-ok.md <<EOF
claim: issue-104-prune-ok
issue: 104
claimed: 2026-08-01T00:00:00Z
scope: x
session: t
branch: feat/104-prune-ok
worktree: $WT_OK
EOF
  : > docs/active-work.md
  git add -A && git commit -qm "claim prune ok" && git push -q origin main
  git rev-parse HEAD:docs/claims/issue-104-prune-ok.md > "$ROOT/prune_order/blob"
  git worktree add -b feat/104-prune-ok "$WT_OK" HEAD >/dev/null 2>&1
  echo remove-me > "$WT_OK/marker"
  git checkout -q long-lived-feature 2>/dev/null || git checkout -q -b long-lived-feature
) >/dev/null 2>&1
BLOB_OK=$(cat "$ROOT/prune_order/blob")
export GH_STATE="$ROOT/prune_order/gh-state"
rm -f "$GH_STATE"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      : > "${GH_STATE:-/tmp/gh-state-prune}"
      exit 0
    fi
    if [[ -f "${GH_STATE:-/tmp/gh-state-prune}" ]]; then
      echo ""
    else
      echo "agent-claimed,tier-b"
    fi
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
export GH_STATE="$ROOT/prune_order/gh-state"
out=$(
  cd "$ROOT/prune_order/canon" && GIBSON_CANONICAL="$ROOT/prune_order/canon" "$RC" 104 \
    --claim-id issue-104-prune-ok \
    --expected-claim-blob "$BLOB_OK" \
    --expected-source file \
    --expected-claim-path docs/claims/issue-104-prune-ok.md \
    --worktree-path "$WT_OK" \
    --expected-branch feat/104-prune-ok \
    --keep-branch \
    --repo acme/app 2>&1
)
rc=$?
check "successful claimed prune exits 0" "$rc" "0"
contains "defers removal until after CAS" "$out" "deferring exact worktree removal"
contains "post-CAS revalidate" "$out" "post-CAS: revalidating exact registered worktree"
contains "claims OK" "$out" "OK — claim released"
[[ ! -d "$WT_OK" ]] \
  && ok "successful claimed prune removed exact worktree after CAS" \
  || bad "successful claimed prune left worktree"
files=$(cd "$ROOT/prune_order/canon" && git fetch -q origin && git ls-tree --name-only origin/main docs/claims/ 2>/dev/null || true)
lacks    "claim gone after successful prune" "$files" "issue-104-prune-ok.md"
br=$(git -C "$ROOT/prune_order/canon" branch --list 'feat/104-prune-ok')
[[ -n "$br" ]] && ok "keep-branch preserved feature branch after prune" || bad "branch deleted despite --keep-branch"

# ---------------------------------------------------------------------------
echo "#73 · claimed prune: final worktree removal failure => incomplete (no false OK)"
new_repo "$ROOT/prune_fail"
WT_FAIL="$ROOT/prune_fail/wt-exact-fail"
(
  cd "$ROOT/prune_fail/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  cat > docs/claims/issue-105-prune-fail.md <<EOF
claim: issue-105-prune-fail
issue: 105
claimed: 2026-08-01T00:00:00Z
scope: x
session: t
branch: feat/105-prune-fail
worktree: $WT_FAIL
EOF
  : > docs/active-work.md
  git add -A && git commit -qm "claim prune fail" && git push -q origin main
  git rev-parse HEAD:docs/claims/issue-105-prune-fail.md > "$ROOT/prune_fail/blob"
  git worktree add -b feat/105-prune-fail "$WT_FAIL" HEAD >/dev/null 2>&1
  echo stuck > "$WT_FAIL/marker"
  git checkout -q long-lived-feature 2>/dev/null || git checkout -q -b long-lived-feature
) >/dev/null 2>&1
BLOB_FAIL=$(cat "$ROOT/prune_fail/blob")
# Shim git worktree remove to fail only for this exact path after strip.
GIT_REAL=$(command -v git)
mkdir -p "$ROOT/prune_fail/bin"
cat > "$ROOT/prune_fail/bin/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "worktree" && "\$2" == "remove" ]]; then
  for a in "\$@"; do
    if [[ "\$a" == "$WT_FAIL" || "\$a" == "${WT_FAIL}/" ]]; then
      echo "simulated worktree remove failure" >&2
      exit 1
    fi
  done
fi
exec "$GIT_REAL" "\$@"
EOF
chmod +x "$ROOT/prune_fail/bin/git"
export GH_STATE="$ROOT/prune_fail/gh-state"
rm -f "$GH_STATE"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  # No live open PR-body claims in this fixture: pr-claims.sh's paginated
  # GraphQL read returns an empty (but successfully read) inventory.
  api) exit 0 ;;
  issue)
    if [[ "$2" == "edit" ]]; then
      # Must not remove label on incomplete final prune
      echo "LABEL-REMOVED-BUG" >&2
      : > "${GH_STATE:-/tmp/gh-pf}"
      exit 0
    fi
    if [[ -f "${GH_STATE:-/tmp/gh-pf}" ]]; then
      echo ""
    else
      echo "agent-claimed,tier-b"
    fi
    exit 0
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/prune_fail/bin:$ROOT/bin:$PATH"
export GH_STATE="$ROOT/prune_fail/gh-state"
out=$(
  cd "$ROOT/prune_fail/canon" && GIBSON_CANONICAL="$ROOT/prune_fail/canon" "$RC" 105 \
    --claim-id issue-105-prune-fail \
    --expected-claim-blob "$BLOB_FAIL" \
    --expected-source file \
    --expected-claim-path docs/claims/issue-105-prune-fail.md \
    --worktree-path "$WT_FAIL" \
    --expected-branch feat/105-prune-fail \
    --keep-branch \
    --repo acme/app 2>&1
)
rc=$?
check "final removal failure exits 3" "$rc" "3"
contains "incomplete on final removal failure" "$out" "INCOMPLETE"
lacks    "must not claim full OK on final removal failure" "$out" "OK — claim released"
# Claim row may already be gone (strip succeeded) — incomplete is about worktree/label
contains "preserves label when final prune fails" "$out" "preserving agent-claimed"
# Worktree should still exist (remove failed)
[[ -d "$WT_FAIL" ]] \
  && ok "worktree still present after failed final remove" \
  || bad "worktree vanished despite simulated remove failure"

# Shared helper for #153 terminal-cleanup fixtures: build a fresh repo, a
# registered worktree at the exact path release-claim.sh derives from the
# claim id, and a pushed branch with one empty reservation commit — mirrors
# claim.sh's real shape. Echoes the worktree's real HEAD SHA so callers can
# feed GitHub's own reported head SHA back into the fake gh fixture, since
# terminal cleanup now proves worktree safety against real git state, not
# just against claimed metadata.
# Args: dir issue slug
term_fixture() {
  local dir="$1" issue="$2" slug="$3" url_form="${4:-https}"
  local id="issue-${issue}-${slug}" branch="feat/${issue}-${slug}"
  new_repo "$ROOT/$dir" acme/app "$url_form"
  git -C "$ROOT/$dir/canon" worktree add -q "$ROOT/$dir/wt-${issue}-${slug}" \
    -b "$branch" origin/main
  (
    cd "$ROOT/$dir/wt-${issue}-${slug}" || exit 1
    git commit --allow-empty -qs -m "chore: reserve issue #$issue for $id"
    git push -q -u origin "$branch"
  ) >/dev/null 2>&1
  git -C "$ROOT/$dir/wt-${issue}-${slug}" rev-parse HEAD
}

# A syntactically valid but not-necessarily-real 40-hex placeholder, used
# wherever a field must merely look like a SHA (merge-commit SHA when the
# exact head-SHA match already proves safety, so the merge SHA is never
# actually consulted).
HEX40="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

echo "#153 · exact-ID release of a terminal PR-body claim with no ledger row"
# Simulates the real #139 failure: current claim.sh never writes a ledger row
# at all, and by the time release runs the reservation PR has already merged
# (or closed) — it is no longer in pr-claims.sh's OPEN listing either.
TERM_HEAD_SHA=$(term_fixture term 200 payments-retry)

mkdir -p "$ROOT/term/bin"
cat > "$ROOT/term/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  api)
    # pr-claims.sh reads GitHub through `gh api graphql --paginate -f query=…
    # --jq …` (cursor pagination, #153 follow-up). This fake hands back the
    # TSV the fixture staged, as if pr-claims.sh's own jq had already emitted
    # it. Two distinct queries have to be told apart: `list` restricts to
    # `states: [OPEN]`, `find-terminal` walks every state.
    [[ "$2" == "graphql" ]] || exit 1
    # `list-open-numbers` is a THIRD query (#153 review round 4): every open PR
    # number, body-agnostic, so a caller can prove the PR it closed really
    # closed even when its claim marker was removed. It is checked first
    # because its query also carries `states: [OPEN]`.
    want_numbers=0
    for arg in "$@"; do
      case "$arg" in *"openPrNumbers"*) want_numbers=1 ;; esac
    done
    if [[ "$want_numbers" -eq 1 ]]; then
      # Default: derive the open numbers from whichever open-claim TSV this
      # read would have been served, so an ordinary fixture stays consistent
      # without having to stage a second file. GH_PR_OPEN_NUMBERS overrides it
      # outright — that is how a fixture models a PR that is still OPEN with
      # its claim marker removed, which is invisible to the claim inventory.
      if [[ -n "${GH_PR_OPEN_NUMBERS+x}" ]]; then
        [[ -z "${GH_PR_OPEN_NUMBERS:-}" ]] || printf '%s\n' "$GH_PR_OPEN_NUMBERS"
        exit "${GH_PR_OPEN_NUMBERS_EXIT:-0}"
      fi
      calls=1
      if [[ -n "${GH_OPEN_CALLS:-}" ]]; then
        calls=$(cat "$GH_OPEN_CALLS" 2>/dev/null || echo 0)
      fi
      open_src="${GH_PR_OPEN_TSV:-/dev/null}"
      if [[ "$calls" -ge 2 && -n "${GH_PR_OPEN_TSV2:-}" ]]; then
        open_src="$GH_PR_OPEN_TSV2"
      fi
      # A PR this fixture already CLOSED is no longer open — the whole point of
      # the body-agnostic inventory is that it is keyed on the number, so it
      # has to move when the number's state moves (#153 review round 5). A
      # fixture that wants a LYING close (gh reports success, the PR is still
      # open) states that explicitly with GH_PR_OPEN_NUMBERS above.
      #
      # Written as ONE awk pass, deliberately (#153 review round 5). This was
      # `cut … | grep -vxF -f … || cat >/dev/null`, which had two defects that
      # between them hung the whole suite:
      #   * `A | B || C` is `(A | B) || C`, and grep exits 1 when it selects no
      #     lines — the ordinary case here, since most fixtures stage an EMPTY
      #     open inventory. The fallback `cat` then ran with the fake's own
      #     inherited stdin and blocked forever. A fake gh may never read stdin.
      #   * `grep -f` on an empty pattern file is not portable: GNU grep treats
      #     it as "no patterns" (so -v passes everything through) while other
      #     greps have historically matched nothing at all.
      # awk reads only the files it is given, cannot block, and behaves the
      # same on GNU and BSD userlands.
      awk -F '\t' -v closed="${GH_PR_CLOSED_NUMBERS:-/dev/null}" '
        BEGIN { while ((getline n < closed) > 0) if (n != "") shut[n] = 1 }
        $1 != "" && !($1 in shut) { print $1 }
      ' "$open_src" 2>/dev/null
      exit "${GH_PR_OPEN_NUMBERS_EXIT:-0}"
    fi
    want_open=0
    for arg in "$@"; do
      case "$arg" in *"states: [OPEN]"*) want_open=1 ;; esac
    done
    if [[ "$want_open" -eq 1 ]]; then
      # Count OPEN-inventory reads so a fixture can make the post-mutation
      # reread differ from the authoritative pre-mutation read — which is
      # exactly what a real repository does when the mutation in between
      # actually changed something. Without this, a fixture that wants a
      # broken *reread* would also break the pre-mutation read and never
      # reach the code under test.
      calls=1
      if [[ -n "${GH_OPEN_CALLS:-}" ]]; then
        calls=$(( $(cat "$GH_OPEN_CALLS" 2>/dev/null || echo 0) + 1 ))
        echo "$calls" > "$GH_OPEN_CALLS"
      fi
      if [[ "$calls" -ge 2 && -n "${GH_PR_OPEN_TSV2:-}" ]]; then
        cat "$GH_PR_OPEN_TSV2" 2>/dev/null
        exit "${GH_PR_OPEN_EXIT2:-0}"
      fi
      cat "${GH_PR_OPEN_TSV:-/dev/null}" 2>/dev/null
      exit "${GH_PR_OPEN_EXIT:-${GH_PR_LIST_EXIT:-0}}"
    fi
    # find-terminal-pr narrows the real GraphQL query with
    # `select(.number == N)`. This fake replays staged TSV instead of running
    # jq, so it honours that narrowing itself — otherwise a reused claim id
    # with two terminal generations would look ambiguous no matter which PR
    # the caller actually asked about (#153 review P2).
    want_num=""
    for arg in "$@"; do
      case "$arg" in
        *"select(.number == "*)
          want_num=$(printf '%s' "$arg" | sed -n 's/.*select(\.number == \([0-9][0-9]*\)).*/\1/p' | head -1)
          ;;
      esac
    done
    if [[ -n "$want_num" ]]; then
      awk -F'\t' -v n="$want_num" '$1==n' "${GH_PR_ALL_TSV:-/dev/null}" 2>/dev/null
    else
      cat "${GH_PR_ALL_TSV:-/dev/null}" 2>/dev/null
    fi
    exit "${GH_PR_ALL_EXIT:-${GH_PR_LIST_EXIT:-0}}"
    ;;
  pr)
    shift
    if [[ "$1" == "close" ]]; then
      # Deliberately a DIFFERENT log from GH_LOG (which records label edits):
      # several assertions read GH_LOG to prove the label was never touched.
      echo "pr close $2" >> "${GH_PR_CLOSE_LOG:-/dev/null}"
      if [[ "${GH_PR_CLOSE_EXIT:-0}" -eq 0 && -n "${GH_PR_CLOSED_NUMBERS:-}" ]]; then
        echo "$2" >> "$GH_PR_CLOSED_NUMBERS"
      fi
      exit "${GH_PR_CLOSE_EXIT:-0}"
    fi
    exit 1
    ;;
  issue)
    shift
    if [[ "$1" == "edit" ]]; then
      echo edited >> "${GH_LOG:-/dev/null}"
      : > "${GH_STATE:-/tmp/gh-state-term}"
      exit 0
    fi
    if [[ -f "${GH_STATE:-/tmp/gh-state-term}" ]]; then
      echo ""
    else
      echo "${GH_LABELS:-agent-claimed,tier-b}"
    fi
    exit 0
    ;;
  # Loud and BOUNDED (#153 review round 5). An unmodelled gh subcommand is a
  # gap in this fixture, not a success: say so on stderr — which release-claim
  # folds into its own error text, so the receipt names the real cause — and
  # exit nonzero so the caller fails closed. Never `exit 0`, and never read
  # stdin.
  *)
    echo "fake gh (term fixture): unmodelled invocation 'gh $*' — refusing rather than answering a query this fixture does not model" >&2
    exit 64
    ;;
esac
FAKE
chmod +x "$ROOT/term/bin/gh"
export PATH="$ROOT/term/bin:$PATH"
export GH_PR_OPEN_TSV="$ROOT/term/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_PR_CLOSED_NUMBERS="$ROOT/term/closed-numbers"
: > "$GH_PR_CLOSED_NUMBERS"
export GH_PR_ALL_TSV="$ROOT/term/all.tsv"
export GH_STATE="$ROOT/term/gh-state"
export GH_LOG="$ROOT/term/gh.log"
export GH_LABELS="agent-claimed,tier-b"
unset GH_PR_LIST_EXIT GH_PR_ALL_EXIT GH_PR_OPEN_EXIT GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2 GH_PR_CLOSE_EXIT GH_PR_CLOSE_LOG GH_OPEN_CALLS
unset GH_PR_OPEN_NUMBERS GH_PR_OPEN_NUMBERS_EXIT
rm -f "$GH_STATE" "$GH_LOG"

# Probed in EXACTLY the configuration that used to hang the whole suite: an
# empty open inventory and an empty closed-numbers file, which is what made
# the body-agnostic filter select no lines at all.
assert_gh_never_reads_stdin "$ROOT/term/bin/gh" "terminal fixture"

# Row layout (13 tab-separated fields, matches pr-claims.sh find-terminal):
#   number claim scope issue head_branch head_sha url state is_cross
#   merge_sha base_repo created_at updated_at
valid_row() {
  printf '777\tissue-200-payments-retry\tlib/payments/**\t200\tfeat/200-payments-retry\t%s\thttps://github.com/acme/app/pull/777\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
    "$TERM_HEAD_SHA" "$HEX40"
}

echo "OPEN evidence fails closed (not yet terminal)"
printf '777\tissue-200-payments-retry\tlib/payments/**\t200\tfeat/200-payments-retry\t%s\thttps://github.com/acme/app/pull/777\tOPEN\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERM_HEAD_SHA" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "OPEN terminal evidence exits 1" "$rc" "1"
contains "names still OPEN"               "$out" "still OPEN"
[[ -d "$ROOT/term/wt-200-payments-retry" ]] && ok "OPEN case: worktree untouched" || bad "OPEN case removed worktree"

echo "ambiguous terminal evidence fails closed"
{ valid_row; printf '778\tissue-200-payments-retry\tlib/payments/**\t200\tfeat/200-payments-retry-2\t%s\thttps://github.com/acme/app/pull/778\tCLOSED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' "$TERM_HEAD_SHA"; } \
  > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "ambiguous terminal evidence exits 1" "$rc" "1"
contains "names ambiguous"                     "$out" "ambiguous"
[[ -d "$ROOT/term/wt-200-payments-retry" ]] && ok "ambiguous case: worktree untouched" || bad "ambiguous case removed worktree"

echo "cross-repository (fork) evidence fails closed (foreign-repo)"
printf '777\tissue-200-payments-retry\tlib/payments/**\t200\tfeat/200-payments-retry\t%s\thttps://github.com/acme/app/pull/777\tMERGED\ttrue\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERM_HEAD_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "cross-repository evidence exits 1" "$rc" "1"
contains "names foreign-repo evidence"       "$out" "foreign-repo"
[[ -d "$ROOT/term/wt-200-payments-retry" ]] && ok "foreign-repo case: worktree untouched" || bad "foreign-repo case removed worktree"

echo "head-branch mismatch fails closed"
printf '777\tissue-200-payments-retry\tlib/payments/**\t200\tfeat/200-some-other-branch\t%s\thttps://github.com/acme/app/pull/777\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERM_HEAD_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "head-branch mismatch exits 1" "$rc" "1"
contains "names branch mismatch"        "$out" "head branch mismatch"

echo "issue-number mismatch fails closed"
printf '777\tissue-200-payments-retry\tlib/payments/**\t201\tfeat/200-payments-retry\t%s\thttps://github.com/acme/app/pull/777\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERM_HEAD_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "issue mismatch exits 1" "$rc" "1"
contains "names issue mismatch"   "$out" "issue mismatch"

echo "base-repository mismatch fails closed (#153 AC3)"
printf '777\tissue-200-payments-retry\tlib/payments/**\t200\tfeat/200-payments-retry\t%s\thttps://github.com/acme/app/pull/777\tMERGED\tfalse\t%s\tother-org/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERM_HEAD_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "base-repository mismatch exits 1" "$rc" "1"
contains "names base-repository mismatch"   "$out" "base-repository mismatch"
[[ -d "$ROOT/term/wt-200-payments-retry" ]] && ok "base-repo mismatch case: worktree untouched" || bad "base-repo mismatch case removed worktree"

echo "malformed head SHA fails closed"
printf '777\tissue-200-payments-retry\tlib/payments/**\t200\tfeat/200-payments-retry\tnot-a-sha\thttps://github.com/acme/app/pull/777\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "malformed head SHA exits 1" "$rc" "1"
contains "names malformed head SHA"   "$out" "head SHA"

echo "MERGED with missing/malformed merge-commit SHA fails closed"
printf '777\tissue-200-payments-retry\tlib/payments/**\t200\tfeat/200-payments-retry\t%s\thttps://github.com/acme/app/pull/777\tMERGED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERM_HEAD_SHA" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "MERGED without merge SHA exits 1" "$rc" "1"
contains "names missing merge-commit SHA"   "$out" "merge-commit SHA"

echo "CLOSED carrying a merge-commit SHA fails closed (never call unmerged code merged)"
printf '777\tissue-200-payments-retry\tlib/payments/**\t200\tfeat/200-payments-retry\t%s\thttps://github.com/acme/app/pull/777\tCLOSED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERM_HEAD_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "CLOSED with merge SHA exits 1"  "$rc" "1"
contains "names state/evidence mismatch"  "$out" "never call unmerged code merged"

echo "missing claim scope fails closed"
printf '777\tissue-200-payments-retry\t\t200\tfeat/200-payments-retry\t%s\thttps://github.com/acme/app/pull/777\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERM_HEAD_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "missing scope exits 1"         "$rc" "1"
contains "names malformed/truncated evidence" "$out" "malformed/truncated"

echo "unsafe head branch fails closed"
printf '777\tissue-200-payments-retry\tlib/payments/**\t200\tfeat 200 bad branch\t%s\thttps://github.com/acme/app/pull/777\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERM_HEAD_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "unsafe head branch exits 1"    "$rc" "1"
contains "names unsafe head branch"      "$out" "unsafe/unreadable head branch"

echo "truncated row fails closed"
printf '777\tissue-200-payments-retry\n' > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "truncated row exits 1"         "$rc" "1"
contains "names malformed/truncated evidence (truncated row)" "$out" "malformed/truncated"

echo "gh query failure fails closed (cannot verify)"
valid_row > "$GH_PR_ALL_TSV"
# GH_PR_ALL_EXIT, not GH_PR_LIST_EXIT: only the terminal (all-states) query
# fails here. The open-inventory read still succeeds, so the run reaches the
# terminal-evidence verification this test is about. The open-inventory read
# failing is its own refusal, covered in the open-PR section below (#153).
export GH_PR_ALL_EXIT=1
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "gh query failure exits 1" "$rc" "1"
contains "names cannot verify"      "$out" "cannot verify"
unset GH_PR_ALL_EXIT

echo "verified exact-ID release after MERGED, no ledger row required"
valid_row > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/term/canon" && "$RC" 200 --claim-id issue-200-payments-retry --repo acme/app 2>&1); rc=$?
check    "terminal release exits 0"        "$rc" "0"
contains "reports the released claim"      "$out" "OK — claim released for issue 200"
contains "names the terminal PR"           "$out" "PR #777"
[[ ! -d "$ROOT/term/wt-200-payments-retry" ]] &&
  ok "terminal release removed the worktree" || bad "terminal release left the worktree"
br=$(git -C "$ROOT/term/canon" branch --list 'feat/200-payments-retry')
[[ -z "$br" ]] && ok "terminal release removed the local branch" || bad "terminal release left the local branch"
remote_br=$(git -C "$ROOT/term/canon" ls-remote --heads origin 'feat/200-payments-retry')
[[ -z "$remote_br" ]] && ok "terminal release removed the remote branch" || bad "terminal release left the remote branch"
table=$(cd "$ROOT/term/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
lacks    "no ledger row was ever invented for the terminal claim" "$table" "issue-200-payments-retry"
contains "no live claim label removal did not wipe the ledger" "$table" "issue-115-unrelated"
contains "verified label removal"          "$out" "removed agent-claimed"

# ===========================================================================
# #153 review round 5, P1 — the exact-PR-number proof is a GATE, not a report
# ===========================================================================
# The proof that PR #N really left the open set used to run only AFTER the
# worktree had been removed and both branch refs deleted. By the time it
# said "still open", the work behind the still-open PR was already gone.
# These fixtures keep the REAL worktree and branches term_fixture created —
# nothing is pre-deleted — and prove that a still-open number, or an
# inventory that could not be read, removes nothing at all.
echo "#153 round 5 · terminal evidence + a still-OPEN exact number destroys NOTHING"
GATE1_SHA=$(term_fixture numgate1 330 open-number-gate)
export GH_PR_ALL_TSV="$ROOT/numgate1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/numgate1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_PR_CLOSED_NUMBERS="$ROOT/numgate1/closed-numbers"
: > "$GH_PR_CLOSED_NUMBERS"
export GH_STATE="$ROOT/numgate1/gh-state"
export GH_LOG="$ROOT/numgate1/gh.log"
export GH_PR_CLOSE_LOG="$ROOT/numgate1/close.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
: > "$GH_PR_CLOSE_LOG"
unset GH_PR_LIST_EXIT GH_PR_ALL_EXIT GH_PR_OPEN_EXIT GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2 GH_PR_CLOSE_EXIT GH_OPEN_CALLS
# Terminal evidence that would otherwise authorize the full cleanup: MERGED,
# this repository, not a fork, exact head SHA, matching branch and issue.
printf '830\tissue-330-open-number-gate\tlib/x/**\t330\tfeat/330-open-number-gate\t%s\thttps://github.com/acme/app/pull/830\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$GATE1_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
# …and the body-agnostic inventory says #830 is still OPEN. Marker evidence
# and state evidence both come from the PR body/row; the NUMBER cannot be
# forged from a body, so this is the one that has to win.
export GH_PR_OPEN_NUMBERS="830"
out=$(cd "$ROOT/numgate1/canon" && "$RC" 330 --claim-id issue-330-open-number-gate --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_NUMBERS
check    "a still-open exact number exits 3"  "$rc" "3"
contains "names the still-open PR"            "$out" "PR #830 is STILL OPEN in acme/app"
contains "refuses before touching anything"   "$out" "worktree and branch left untouched"
contains "reports INCOMPLETE"                 "$out" "INCOMPLETE"
lacks    "never reports success"              "$out" "OK —"
[[ -d "$ROOT/numgate1/wt-330-open-number-gate" ]] &&
  ok "still-open number: the worktree survived" || bad "still-open number: the worktree was removed"
[[ -n "$(git -C "$ROOT/numgate1/canon" branch --list 'feat/330-open-number-gate')" ]] &&
  ok "still-open number: the local branch survived" || bad "still-open number: the local branch was deleted"
[[ -n "$(git -C "$ROOT/numgate1/canon" ls-remote --heads origin 'feat/330-open-number-gate')" ]] &&
  ok "still-open number: the remote branch survived" || bad "still-open number: the remote branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "still-open number: the label was never edited" || bad "still-open number: a label edit was attempted"
gate_table=$(cd "$ROOT/numgate1/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
contains "still-open number: the ledger is untouched" "$gate_table" "issue-115-unrelated"

echo "#153 round 5 · an UNREADABLE exact-number inventory destroys NOTHING either"
GATE2_SHA=$(term_fixture numgate2 331 unreadable-number-gate)
export GH_PR_ALL_TSV="$ROOT/numgate2/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/numgate2/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_PR_CLOSED_NUMBERS="$ROOT/numgate2/closed-numbers"
: > "$GH_PR_CLOSED_NUMBERS"
export GH_STATE="$ROOT/numgate2/gh-state"
export GH_LOG="$ROOT/numgate2/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '831\tissue-331-unreadable-number-gate\tlib/x/**\t331\tfeat/331-unreadable-number-gate\t%s\thttps://github.com/acme/app/pull/831\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$GATE2_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
export GH_PR_OPEN_NUMBERS=""
export GH_PR_OPEN_NUMBERS_EXIT=1
out=$(cd "$ROOT/numgate2/canon" && "$RC" 331 --claim-id issue-331-unreadable-number-gate --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_NUMBERS GH_PR_OPEN_NUMBERS_EXIT
check    "an unreadable exact-number inventory exits 3" "$rc" "3"
contains "names the unreadable inventory" "$out" "cannot read the body-agnostic open pull-request inventory"
contains "refuses before touching anything" "$out" "worktree and branch left untouched"
lacks    "never reports success"          "$out" "OK —"
[[ -d "$ROOT/numgate2/wt-331-unreadable-number-gate" ]] &&
  ok "unreadable numbers: the worktree survived" || bad "unreadable numbers: the worktree was removed"
[[ -n "$(git -C "$ROOT/numgate2/canon" branch --list 'feat/331-unreadable-number-gate')" ]] &&
  ok "unreadable numbers: the local branch survived" || bad "unreadable numbers: the local branch was deleted"
[[ -n "$(git -C "$ROOT/numgate2/canon" ls-remote --heads origin 'feat/331-unreadable-number-gate')" ]] &&
  ok "unreadable numbers: the remote branch survived" || bad "unreadable numbers: the remote branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "unreadable numbers: the label was never edited" || bad "unreadable numbers: a label edit was attempted"

echo "#153 round 5 · a LYING close on the OPEN path destroys NOTHING (artifacts live)"
# The whole open-claim lifecycle, with the real worktree and branches in place:
# release closes the PR, gh reports success, and the body-agnostic inventory
# says #832 never left the open set. Nothing may be removed.
GATE3_SHA=$(term_fixture numgate3 332 open-path-lying-close)
export GH_PR_ALL_TSV="$ROOT/numgate3/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/numgate3/open.tsv"
export GH_PR_CLOSED_NUMBERS="$ROOT/numgate3/closed-numbers"
: > "$GH_PR_CLOSED_NUMBERS"
export GH_STATE="$ROOT/numgate3/gh-state"
export GH_LOG="$ROOT/numgate3/gh.log"
export GH_PR_CLOSE_LOG="$ROOT/numgate3/close.log"
export GH_LABELS="agent-claimed,tier-b"
export GH_OPEN_CALLS="$ROOT/numgate3/open-calls"
: > "$GH_OPEN_CALLS"
rm -f "$GH_STATE" "$GH_LOG"
: > "$GH_PR_CLOSE_LOG"
unset GH_PR_LIST_EXIT GH_PR_ALL_EXIT GH_PR_OPEN_EXIT GH_PR_OPEN_EXIT2 GH_PR_CLOSE_EXIT
open_row 832 issue-332-open-path-lying-close 'lib/x/**' feat/332-open-path-lying-close > "$GH_PR_OPEN_TSV"
export GH_PR_OPEN_TSV2="$ROOT/numgate3/open2.tsv"
: > "$GH_PR_OPEN_TSV2"
printf '832\tissue-332-open-path-lying-close\tlib/x/**\t332\tfeat/332-open-path-lying-close\t%s\thttps://github.com/acme/app/pull/832\tCLOSED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$GATE3_SHA" > "$GH_PR_ALL_TSV"
export GH_PR_OPEN_NUMBERS="832"
out=$(cd "$ROOT/numgate3/canon" && "$RC" 332 --claim-id issue-332-open-path-lying-close --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_NUMBERS GH_PR_OPEN_TSV2
check    "a lying close on the open path exits 3" "$rc" "3"
contains "the PR was closed"               "$out" "closing PR #832"
contains "names the still-open PR"         "$out" "PR #832 is STILL OPEN in acme/app"
contains "reports INCOMPLETE"              "$out" "INCOMPLETE"
lacks    "never reports success"           "$out" "OK —"
[[ -d "$ROOT/numgate3/wt-332-open-path-lying-close" ]] &&
  ok "lying close: the worktree survived" || bad "lying close: the worktree was removed"
[[ -n "$(git -C "$ROOT/numgate3/canon" branch --list 'feat/332-open-path-lying-close')" ]] &&
  ok "lying close: the local branch survived" || bad "lying close: the local branch was deleted"
[[ -n "$(git -C "$ROOT/numgate3/canon" ls-remote --heads origin 'feat/332-open-path-lying-close')" ]] &&
  ok "lying close: the remote branch survived" || bad "lying close: the remote branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "lying close: the label was never edited" || bad "lying close: a label edit was attempted"

# ===========================================================================
# #153 review round 5, P1 — fork PRs are refused BEFORE `gh pr close`
# ===========================================================================
# A fork PR can carry an exact claim marker AND a head branch named exactly
# like the one the claim id derives — branch names are not namespaced across
# repositories. Marker + branch is therefore not repository identity, and
# `gh pr close` is irreversible.
echo "#153 round 5 · an open FORK claim PR is never closed"
# term_fixture stages the worktree and returns the head SHA; this fixture
# stages its own TSV rows (with a synthetic SHA) so the return value is unused.
term_fixture forkopen 340 fork-open-claim >/dev/null
export GH_PR_ALL_TSV="$ROOT/forkopen/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/forkopen/open.tsv"
export GH_PR_CLOSED_NUMBERS="$ROOT/forkopen/closed-numbers"
: > "$GH_PR_CLOSED_NUMBERS"
export GH_STATE="$ROOT/forkopen/gh-state"
export GH_LOG="$ROOT/forkopen/gh.log"
export GH_PR_CLOSE_LOG="$ROOT/forkopen/close.log"
export GH_LABELS="agent-claimed,tier-b"
export GH_OPEN_CALLS="$ROOT/forkopen/open-calls"
: > "$GH_OPEN_CALLS"
rm -f "$GH_STATE" "$GH_LOG"
: > "$GH_PR_CLOSE_LOG"
unset GH_PR_LIST_EXIT GH_PR_ALL_EXIT GH_PR_OPEN_EXIT GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2 GH_PR_CLOSE_EXIT
unset GH_PR_OPEN_NUMBERS GH_PR_OPEN_NUMBERS_EXIT
: > "$GH_PR_ALL_TSV"
# Everything about this row looks right except the one thing that matters.
open_row 840 issue-340-fork-open-claim 'lib/x/**' feat/340-fork-open-claim true > "$GH_PR_OPEN_TSV"
out=$(cd "$ROOT/forkopen/canon" && "$RC" 340 --claim-id issue-340-fork-open-claim --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an open fork claim PR exits nonzero" || bad "open fork claim PR exited 0: $out"
contains "names the unproven repository identity" "$out" "not provably a same-repository pull request"
check "the fork PR was never closed" "$(grep -c . "$ROOT/forkopen/close.log" 2>/dev/null || true)" "0"
[[ -d "$ROOT/forkopen/wt-340-fork-open-claim" ]] &&
  ok "fork PR: the worktree survived" || bad "fork PR: the worktree was removed"
[[ -n "$(git -C "$ROOT/forkopen/canon" ls-remote --heads origin 'feat/340-fork-open-claim')" ]] &&
  ok "fork PR: the remote branch survived" || bad "fork PR: the remote branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "fork PR: the label was never edited" || bad "fork PR: a label edit was attempted"
fork_table=$(cd "$ROOT/forkopen/canon" && git fetch -q origin && git show origin/main:docs/active-work.md)
contains "fork PR: the ledger is untouched" "$fork_table" "issue-115-unrelated"

echo "#153 round 5 · a fork claim PR is refused under --dry-run too"
out=$(cd "$ROOT/forkopen/canon" && "$RC" 340 --claim-id issue-340-fork-open-claim --repo acme/app --dry-run 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "dry-run refuses the fork claim PR" || bad "dry-run accepted the fork claim PR: $out"
lacks "dry-run plans no close for a fork PR" "$out" "would close PR"

echo "#153 round 5 · an UNREADABLE repository-identity column is unsafe, not same-repo"
open_row 841 issue-341-bad-identity 'lib/x/**' feat/341-bad-identity 'maybe' > "$GH_PR_OPEN_TSV"
out=$(cd "$ROOT/forkopen/canon" && "$RC" 341 --claim-id issue-341-bad-identity --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "an unreadable identity column exits nonzero" || bad "unreadable identity exited 0: $out"
contains "names the malformed inventory row" "$out" "malformed/truncated row"
check "no PR was closed on unreadable identity" "$(grep -c . "$ROOT/forkopen/close.log" 2>/dev/null || true)" "0"

echo "#153 · terminal cleanup git-level safety proof (never trust metadata alone)"

echo "dirty exact worktree refuses before deletion"
DIRTY_SHA=$(term_fixture dirty1 301 dirty-case)
echo scratch > "$ROOT/dirty1/wt-301-dirty-case/scratch.txt"
export GH_PR_ALL_TSV="$ROOT/dirty1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/dirty1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/dirty1/gh-state"
export GH_LOG="$ROOT/dirty1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '801\tissue-301-dirty-case\tlib/x/**\t301\tfeat/301-dirty-case\t%s\thttps://github.com/acme/app/pull/801\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$DIRTY_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/dirty1/canon" && "$RC" 301 --claim-id issue-301-dirty-case --repo acme/app 2>&1); rc=$?
check    "dirty worktree release exits 3"        "$rc" "3"
contains "names dirty worktree refusal"          "$out" "uncommitted or untracked changes"
lacks    "does not claim success on dirty refuse" "$out" "OK —"
[[ -f "$ROOT/dirty1/wt-301-dirty-case/scratch.txt" ]] &&
  ok "dirty worktree left untouched" || bad "dirty worktree was removed despite untracked changes"
br=$(git -C "$ROOT/dirty1/canon" branch --list 'feat/301-dirty-case')
[[ -n "$br" ]] && ok "dirty case: branch left untouched" || bad "dirty case: branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "dirty case: label was never touched" || bad "dirty case: label edit was attempted"

echo "unregistered default-path directory refuses and is preserved (no rm -rf)"
new_repo "$ROOT/unreg1" acme/app
mkdir -p "$ROOT/unreg1/wt-302-unreg-case"
echo marker > "$ROOT/unreg1/wt-302-unreg-case/marker.txt"
export GH_PR_ALL_TSV="$ROOT/unreg1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/unreg1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/unreg1/gh-state"
export GH_LOG="$ROOT/unreg1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '802\tissue-302-unreg-case\tlib/x/**\t302\tfeat/302-unreg-case\t%s\thttps://github.com/acme/app/pull/802\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$HEX40" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/unreg1/canon" && "$RC" 302 --claim-id issue-302-unreg-case --repo acme/app 2>&1); rc=$?
check    "unregistered dir release exits 3"          "$rc" "3"
contains "names unregistered/no-fallback refusal"    "$out" "not a registered git worktree"
lacks    "does not claim success on unregistered dir" "$out" "OK —"
[[ -f "$ROOT/unreg1/wt-302-unreg-case/marker.txt" ]] &&
  ok "unregistered directory preserved (no rm -rf)" || bad "unregistered directory was deleted"

echo "worktree checked out on wrong branch refuses"
WRONGBR_SHA=$(term_fixture wrongbr1 303 wrong-branch-case)
git -C "$ROOT/wrongbr1/wt-303-wrong-branch-case" checkout -qb some-other-local-branch
export GH_PR_ALL_TSV="$ROOT/wrongbr1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/wrongbr1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/wrongbr1/gh-state"
export GH_LOG="$ROOT/wrongbr1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '803\tissue-303-wrong-branch-case\tlib/x/**\t303\tfeat/303-wrong-branch-case\t%s\thttps://github.com/acme/app/pull/803\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$WRONGBR_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/wrongbr1/canon" && "$RC" 303 --claim-id issue-303-wrong-branch-case --repo acme/app 2>&1); rc=$?
check    "wrong-branch worktree exits 3"     "$rc" "3"
contains "names branch mismatch refusal"     "$out" "expected the exact PR head branch"
[[ -d "$ROOT/wrongbr1/wt-303-wrong-branch-case" ]] &&
  ok "wrong-branch worktree preserved" || bad "wrong-branch worktree was removed"

echo "head SHA mismatch refuses (worktree HEAD diverged from recorded evidence)"
SHAMISMATCH_ORIG_SHA=$(term_fixture shamismatch1 304 sha-mismatch-case)
git -C "$ROOT/shamismatch1/wt-304-sha-mismatch-case" commit --allow-empty -qs -m "local-only drift, never reported to GitHub"
export GH_PR_ALL_TSV="$ROOT/shamismatch1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/shamismatch1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/shamismatch1/gh-state"
export GH_LOG="$ROOT/shamismatch1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '804\tissue-304-sha-mismatch-case\tlib/x/**\t304\tfeat/304-sha-mismatch-case\t%s\thttps://github.com/acme/app/pull/804\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$SHAMISMATCH_ORIG_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/shamismatch1/canon" && "$RC" 304 --claim-id issue-304-sha-mismatch-case --repo acme/app 2>&1); rc=$?
check    "head SHA mismatch exits 3"        "$rc" "3"
contains "names SHA-mismatch refusal"       "$out" "nor provably contained in the merged result"
[[ -d "$ROOT/shamismatch1/wt-304-sha-mismatch-case" ]] &&
  ok "SHA-mismatch worktree preserved" || bad "SHA-mismatch worktree was removed"

echo "#153 · terminal cleanup mutation failures never claim success"

echo "remote branch deletion failure yields rc=3, no success claim"
REMFAIL_SHA=$(term_fixture remfail1 305 remote-fail-case)
cat > "$ROOT/remfail1/origin/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
zero="0000000000000000000000000000000000000000"
while read -r _old new ref; do
  if [[ "$new" == "$zero" && "$ref" == "refs/heads/feat/305-remote-fail-case" ]]; then
    echo "reject branch delete by fixture" >&2
    exit 1
  fi
done
exit 0
HOOK
chmod +x "$ROOT/remfail1/origin/hooks/pre-receive"
export GH_PR_ALL_TSV="$ROOT/remfail1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/remfail1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/remfail1/gh-state"
export GH_LOG="$ROOT/remfail1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '805\tissue-305-remote-fail-case\tlib/x/**\t305\tfeat/305-remote-fail-case\t%s\thttps://github.com/acme/app/pull/805\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$REMFAIL_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/remfail1/canon" && "$RC" 305 --claim-id issue-305-remote-fail-case --repo acme/app 2>&1); rc=$?
check    "remote branch delete failure exits 3"     "$rc" "3"
contains "names remote branch delete failure"        "$out" "remote branch CAS delete refused"
lacks    "does not claim success on remote delete failure" "$out" "OK —"
[[ ! -d "$ROOT/remfail1/wt-305-remote-fail-case" ]] &&
  ok "remote-delete-failure case: worktree still removed (independent step)" || bad "remote-delete-failure case: worktree survived"
remote_br=$(git -C "$ROOT/remfail1/canon" ls-remote --heads origin 'feat/305-remote-fail-case')
[[ -n "$remote_br" ]] && ok "remote branch survived the rejected delete" || bad "remote branch vanished despite rejected delete"

echo "local branch deletion failure yields rc=3"
LOCALFAIL_SHA=$(term_fixture localfail1 306 local-fail-case)
# A stale ref-lock file (as a concurrent git process would leave behind)
# makes `git branch -D` fail deterministically without needing a second
# worktree on the same branch — which would now correctly trip the
# ambiguous-registration guard (#153 blocker 1) before mutation is ever
# attempted, never reaching this specific failure mode.
LOCALFAIL_LOCK="$ROOT/localfail1/canon/.git/refs/heads/feat/306-local-fail-case.lock"
mkdir -p "$(dirname "$LOCALFAIL_LOCK")"
: > "$LOCALFAIL_LOCK"
export GH_PR_ALL_TSV="$ROOT/localfail1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/localfail1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/localfail1/gh-state"
export GH_LOG="$ROOT/localfail1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '806\tissue-306-local-fail-case\tlib/x/**\t306\tfeat/306-local-fail-case\t%s\thttps://github.com/acme/app/pull/806\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$LOCALFAIL_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/localfail1/canon" && "$RC" 306 --claim-id issue-306-local-fail-case --repo acme/app 2>&1); rc=$?
rm -f "$LOCALFAIL_LOCK"
check    "local branch delete failure exits 3"    "$rc" "3"
contains "names local branch delete failure"      "$out" "local branch CAS delete refused"
lacks    "does not claim success on local delete failure" "$out" "OK —"
br=$(git -C "$ROOT/localfail1/canon" branch --list 'feat/306-local-fail-case')
[[ -n "$br" ]] && ok "local branch survived the failed delete (ref lock held)" || bad "local branch vanished despite failed delete"

echo "two worktrees registered on the exact PR head branch is ambiguous, refuse (#153 blocker 1)"
AMBIG_SHA=$(term_fixture ambig1 309 ambiguous-branch-case)
git -C "$ROOT/ambig1/canon" worktree add -q --force "$ROOT/ambig1/wt-decoy-ambiguous" feat/309-ambiguous-branch-case
export GH_PR_ALL_TSV="$ROOT/ambig1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/ambig1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/ambig1/gh-state"
export GH_LOG="$ROOT/ambig1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '809\tissue-309-ambiguous-branch-case\tlib/x/**\t309\tfeat/309-ambiguous-branch-case\t%s\thttps://github.com/acme/app/pull/809\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$AMBIG_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/ambig1/canon" && "$RC" 309 --claim-id issue-309-ambiguous-branch-case --repo acme/app 2>&1); rc=$?
check    "ambiguous branch registration exits 3"             "$rc" "3"
contains "names ambiguous registration"                      "$out" "ambiguous"
lacks    "does not claim success on ambiguous registration"  "$out" "OK —"
[[ -d "$ROOT/ambig1/wt-309-ambiguous-branch-case" ]] &&
  ok "ambiguous case: original worktree untouched" || bad "ambiguous case: original worktree removed"
[[ -d "$ROOT/ambig1/wt-decoy-ambiguous" ]] &&
  ok "ambiguous case: decoy worktree untouched" || bad "ambiguous case: decoy worktree removed"
br=$(git -C "$ROOT/ambig1/canon" branch --list 'feat/309-ambiguous-branch-case')
[[ -n "$br" ]] && ok "ambiguous case: branch left untouched" || bad "ambiguous case: branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "ambiguous case: label was never touched" || bad "ambiguous case: label edit was attempted"

echo "#153 blocker 1: exact branch registered at a non-default path — operate on it, never a decoy default-path directory"
new_repo "$ROOT/nondef1" acme/app
git -C "$ROOT/nondef1/canon" worktree add -q "$ROOT/nondef1/actual-nondefault-location" \
  -b feat/310-nondefault-path origin/main
(
  cd "$ROOT/nondef1/actual-nondefault-location" || exit 1
  git commit --allow-empty -qs -m "chore: reserve issue #310 for issue-310-nondefault-path"
  git push -q -u origin feat/310-nondefault-path
) >/dev/null 2>&1
NONDEF_SHA=$(git -C "$ROOT/nondef1/actual-nondefault-location" rev-parse HEAD)
# Decoy at the historical default-derived path: unrelated content that must
# never be inspected or touched now that removal binds to the exact
# registered path via `git worktree list --porcelain`, never a guess.
mkdir -p "$ROOT/nondef1/wt-310-nondefault-path"
echo decoy-marker > "$ROOT/nondef1/wt-310-nondefault-path/decoy.txt"
export GH_PR_ALL_TSV="$ROOT/nondef1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/nondef1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/nondef1/gh-state"
export GH_LOG="$ROOT/nondef1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '810\tissue-310-nondefault-path\tlib/x/**\t310\tfeat/310-nondefault-path\t%s\thttps://github.com/acme/app/pull/810\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$NONDEF_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/nondef1/canon" && "$RC" 310 --claim-id issue-310-nondefault-path --repo acme/app 2>&1); rc=$?
check "non-default worktree path release exits 0" "$rc" "0"
[[ ! -d "$ROOT/nondef1/actual-nondefault-location" ]] &&
  ok "the actual registered non-default worktree was removed" || bad "the actual registered non-default worktree survived"
[[ -f "$ROOT/nondef1/wt-310-nondefault-path/decoy.txt" ]] &&
  ok "decoy default-path directory was never touched" || bad "decoy default-path directory was touched/removed"
br=$(git -C "$ROOT/nondef1/canon" branch --list 'feat/310-nondefault-path')
[[ -z "$br" ]] && ok "non-default-path branch removed" || bad "non-default-path branch survived"

echo "#153 blocker 2: TOCTOU — worktree dirtied between the safety check and removal refuses (rc=3)"
TOCTOU_SHA=$(term_fixture toctou1 311 toctou-case)
write_git_shim toctou1 status2 feat/311-toctou-case 'echo "raced-in-content" > "$WT/raced.txt"'
export GH_PR_ALL_TSV="$ROOT/toctou1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/toctou1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/toctou1/gh-state"
export GH_LOG="$ROOT/toctou1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '811\tissue-311-toctou-case\tlib/x/**\t311\tfeat/311-toctou-case\t%s\thttps://github.com/acme/app/pull/811\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TOCTOU_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/toctou1/canon" && PATH="$ROOT/toctou1/shim:$PATH" "$RC" 311 --claim-id issue-311-toctou-case --repo acme/app 2>&1); rc=$?
check    "TOCTOU dirty-between-check-and-removal exits 3" "$rc" "3"
contains "names the TOCTOU refusal"                       "$out" "became dirty between the safety proof and removal"
lacks    "does not claim success on TOCTOU race"          "$out" "OK —"
[[ -f "$ROOT/toctou1/wt-311-toctou-case/raced.txt" ]] &&
  ok "TOCTOU: worktree preserved with the raced-in file intact" || bad "TOCTOU: worktree was removed despite the race"
br=$(git -C "$ROOT/toctou1/canon" branch --list 'feat/311-toctou-case')
[[ -n "$br" ]] && ok "TOCTOU: branch left untouched" || bad "TOCTOU: branch was deleted"
# (second Codex review) a dirty-worktree race must never fall through to
# branch deletion — the local AND the remote branch both survive, not just
# the local one. This is exactly the shape that let the remote branch get
# deleted while a dirty worktree and its local branch survived.
toctou_remote_br=$(git -C "$ROOT/toctou1/canon" ls-remote --heads origin 'feat/311-toctou-case')
[[ -n "$toctou_remote_br" ]] && ok "TOCTOU: remote branch left untouched" || bad "TOCTOU: remote branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "TOCTOU: label was never touched" || bad "TOCTOU: label edit was attempted"

echo "#153 blocker 3: no worktree does not make an advanced/reused local branch safe"
ADVLOCAL_SHA=$(term_fixture advlocal1 312 advanced-local-case)
git -C "$ROOT/advlocal1/canon" worktree remove --force "$ROOT/advlocal1/wt-312-advanced-local-case"
git -C "$ROOT/advlocal1/canon" update-ref "refs/heads/feat/312-advanced-local-case" HEAD
export GH_PR_ALL_TSV="$ROOT/advlocal1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/advlocal1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/advlocal1/gh-state"
export GH_LOG="$ROOT/advlocal1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '812\tissue-312-advanced-local-case\tlib/x/**\t312\tfeat/312-advanced-local-case\t%s\thttps://github.com/acme/app/pull/812\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$ADVLOCAL_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/advlocal1/canon" && "$RC" 312 --claim-id issue-312-advanced-local-case --repo acme/app 2>&1); rc=$?
check    "advanced local branch (no worktree) exits 3" "$rc" "3"
contains "names advanced/reused local branch"           "$out" "advanced/reused branch"
lacks    "does not claim success"                        "$out" "OK —"
br=$(git -C "$ROOT/advlocal1/canon" branch --list 'feat/312-advanced-local-case')
[[ -n "$br" ]] && ok "advanced local branch preserved" || bad "advanced local branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "advanced local branch case: label was never touched" || bad "advanced local branch case: label edit was attempted"

echo "#153 blocker 3: no worktree, no local branch does not make an advanced/reused remote branch safe"
ADVREMOTE_SHA=$(term_fixture advremote1 313 advanced-remote-case)
git -C "$ROOT/advremote1/canon" worktree remove --force "$ROOT/advremote1/wt-313-advanced-remote-case"
git -C "$ROOT/advremote1/canon" branch -D feat/313-advanced-remote-case >/dev/null 2>&1
git clone -q "$ROOT/advremote1/origin" "$ROOT/advremote1/second-clone" >/dev/null 2>&1
(
  cd "$ROOT/advremote1/second-clone" || exit 1
  git checkout -q feat/313-advanced-remote-case
  git commit --allow-empty -qm "reused after reservation"
  git push -q origin feat/313-advanced-remote-case
) >/dev/null 2>&1
export GH_PR_ALL_TSV="$ROOT/advremote1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/advremote1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/advremote1/gh-state"
export GH_LOG="$ROOT/advremote1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '813\tissue-313-advanced-remote-case\tlib/x/**\t313\tfeat/313-advanced-remote-case\t%s\thttps://github.com/acme/app/pull/813\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$ADVREMOTE_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/advremote1/canon" && "$RC" 313 --claim-id issue-313-advanced-remote-case --repo acme/app 2>&1); rc=$?
check    "advanced remote branch (no worktree, no local branch) exits 3" "$rc" "3"
contains "names advanced/reused remote branch"                          "$out" "advanced/reused branch"
lacks    "does not claim success"                                        "$out" "OK —"
remote_br=$(git -C "$ROOT/advremote1/canon" ls-remote --heads origin 'feat/313-advanced-remote-case')
[[ -n "$remote_br" ]] && ok "advanced remote branch preserved" || bad "advanced remote branch was deleted"

echo "#153 blocker 4: remote branch query failure (pre-mutation) is unreadable evidence, never absence"
LSPRE_SHA=$(term_fixture lsrepre1 314 lsremote-prefail-case)
REAL_GIT=$(command -v git)
mkdir -p "$ROOT/lsrepre1/gitwrap"
cat > "$ROOT/lsrepre1/gitwrap/git" <<WRAP
#!/usr/bin/env bash
if [[ "\$1" == "ls-remote" && "\$*" == *"--heads origin refs/heads/feat/314-lsremote-prefail-case"* ]]; then
  echo "fatal: unable to access remote (simulated pre-mutation failure)" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
WRAP
chmod +x "$ROOT/lsrepre1/gitwrap/git"
export GH_PR_ALL_TSV="$ROOT/lsrepre1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/lsrepre1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/lsrepre1/gh-state"
export GH_LOG="$ROOT/lsrepre1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '814\tissue-314-lsremote-prefail-case\tlib/x/**\t314\tfeat/314-lsremote-prefail-case\t%s\thttps://github.com/acme/app/pull/814\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$LSPRE_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/lsrepre1/canon" && PATH="$ROOT/lsrepre1/gitwrap:$PATH" "$RC" 314 --claim-id issue-314-lsremote-prefail-case --repo acme/app 2>&1); rc=$?
check    "pre-mutation ls-remote query failure exits 3" "$rc" "3"
contains "names the query failure"                      "$out" "git ls-remote --heads origin failed"
lacks    "does not claim success on query failure"       "$out" "OK —"
[[ -d "$ROOT/lsrepre1/wt-314-lsremote-prefail-case" ]] &&
  ok "pre-mutation query failure: worktree untouched" || bad "pre-mutation query failure: worktree removed"
br=$(git -C "$ROOT/lsrepre1/canon" branch --list 'feat/314-lsremote-prefail-case')
[[ -n "$br" ]] && ok "pre-mutation query failure: local branch untouched" || bad "pre-mutation query failure: local branch deleted"
remote_br=$(git -C "$ROOT/lsrepre1/canon" ls-remote --heads origin 'feat/314-lsremote-prefail-case')
[[ -n "$remote_br" ]] && ok "pre-mutation query failure: remote branch untouched" || bad "pre-mutation query failure: remote branch deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "pre-mutation query failure: label was never touched" || bad "pre-mutation query failure: label edit was attempted"

echo "#153 blocker 4: remote branch query failure (post-mutation) refuses success even though mutation already succeeded"
LSPOST_SHA=$(term_fixture lsrepost1 315 lsremote-postfail-case)
mkdir -p "$ROOT/lsrepost1/gitwrap"
cat > "$ROOT/lsrepost1/gitwrap/git" <<WRAP
#!/usr/bin/env bash
if [[ "\$1" == "ls-remote" && "\$*" == *"--heads origin refs/heads/feat/315-lsremote-postfail-case"* ]]; then
  counter_file="$ROOT/lsrepost1/lsremote-count"
  count=0
  [[ -f "\$counter_file" ]] && count=\$(cat "\$counter_file")
  count=\$((count + 1))
  echo "\$count" > "\$counter_file"
  # First two calls (pre-mutation identity proof, mutation-time delete
  # decision) pass through to the real git so the worktree/branch actually
  # get removed; only the third call (postcondition) is simulated as an
  # unreadable query — proving a query failure AFTER a successful mutation
  # still refuses to claim success (#153 blocker 4).
  if [[ "\$count" -ge 3 ]]; then
    echo "fatal: unable to access remote (simulated post-mutation failure)" >&2
    exit 128
  fi
fi
exec "$REAL_GIT" "\$@"
WRAP
chmod +x "$ROOT/lsrepost1/gitwrap/git"
export GH_PR_ALL_TSV="$ROOT/lsrepost1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/lsrepost1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/lsrepost1/gh-state"
export GH_LOG="$ROOT/lsrepost1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '815\tissue-315-lsremote-postfail-case\tlib/x/**\t315\tfeat/315-lsremote-postfail-case\t%s\thttps://github.com/acme/app/pull/815\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$LSPOST_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/lsrepost1/canon" && PATH="$ROOT/lsrepost1/gitwrap:$PATH" "$RC" 315 --claim-id issue-315-lsremote-postfail-case --repo acme/app 2>&1); rc=$?
check    "post-mutation ls-remote query failure exits 3" "$rc" "3"
contains "names the postcondition query failure"         "$out" "cannot verify remote branch"
lacks    "does not claim success on postcondition query failure" "$out" "OK —"
[[ ! -d "$ROOT/lsrepost1/wt-315-lsremote-postfail-case" ]] &&
  ok "post-mutation query failure: worktree mutation still completed" || bad "post-mutation query failure: worktree mutation was skipped"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "post-mutation query failure: label was never removed" || bad "post-mutation query failure: label removal was attempted"

echo "second Codex review: local branch advances after the safety proof but before the CAS delete — refuse, never carry a fresh reread as the CAS expectation, never fall through to the remote delete"
LOCALADV_SHA=$(term_fixture localadv1 320 local-advance-race-case)
# Simulates a concurrent process advancing the local branch AFTER
# terminal_cleanup_release's identity proof already accepted its old tip, but
# BEFORE the CAS delete runs. By this point in the run the worktree for this
# branch has already been removed, so the ref is safe to move directly. If
# the CAS delete used a fresh `git rev-parse` read taken here (the original
# bug) it would trivially match itself and delete the advanced branch;
# carrying the proof-time OID forward must refuse instead.
write_git_shim localadv1 updateref feat/320-local-advance-race-case \
  '"$REAL_GIT" -C "$CANON" update-ref "refs/heads/$BR" "$("$REAL_GIT" -C "$CANON" rev-parse HEAD)"'
export GH_PR_ALL_TSV="$ROOT/localadv1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/localadv1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/localadv1/gh-state"
export GH_LOG="$ROOT/localadv1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '820\tissue-320-local-advance-race-case\tlib/x/**\t320\tfeat/320-local-advance-race-case\t%s\thttps://github.com/acme/app/pull/820\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$LOCALADV_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/localadv1/canon" && PATH="$ROOT/localadv1/shim:$PATH" "$RC" 320 --claim-id issue-320-local-advance-race-case --repo acme/app 2>&1); rc=$?
check    "local-advance race exits 3"                    "$rc" "3"
contains "names the local CAS refusal"                   "$out" "local branch CAS delete refused"
contains "names why the remote delete was skipped"       "$out" "skipping remote branch CAS delete"
lacks    "does not claim success on local-advance race"  "$out" "OK —"
[[ ! -d "$ROOT/localadv1/wt-320-local-advance-race-case" ]] &&
  ok "local-advance race: worktree removal (independent step) still completed" || bad "local-advance race: worktree removal was skipped"
br=$(git -C "$ROOT/localadv1/canon" branch --list 'feat/320-local-advance-race-case')
[[ -n "$br" ]] && ok "local-advance race: advanced local branch preserved" || bad "local-advance race: local branch was deleted despite the race"
remote_br=$(git -C "$ROOT/localadv1/canon" ls-remote --heads origin 'feat/320-local-advance-race-case')
[[ -n "$remote_br" ]] && ok "local-advance race: remote branch preserved (no delete after a local CAS refusal)" || bad "local-advance race: remote branch was deleted despite the local CAS refusal"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "local-advance race: label was never touched" || bad "local-advance race: label edit was attempted"

echo "second Codex review: remote branch advances after the safety proof but before the CAS delete — refuse, the lease stays bound to the verified terminal head SHA"
REMOTEADV_SHA=$(term_fixture remoteadv1 321 remote-advance-race-case)
write_git_shim remoteadv1 pushlease feat/321-remote-advance-race-case '
  clone_dir=$(mktemp -d)
  "$REAL_GIT" clone -q "$ORIGIN" "$clone_dir" >/dev/null 2>&1
  "$REAL_GIT" -C "$clone_dir" fetch -q origin "$BR" >/dev/null 2>&1
  "$REAL_GIT" -C "$clone_dir" checkout -q "$BR" >/dev/null 2>&1
  "$REAL_GIT" -C "$clone_dir" commit --allow-empty -qm "raced advance" >/dev/null 2>&1
  "$REAL_GIT" -C "$clone_dir" push -q origin "$BR" >/dev/null 2>&1
  rm -rf "$clone_dir"'
export GH_PR_ALL_TSV="$ROOT/remoteadv1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/remoteadv1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/remoteadv1/gh-state"
export GH_LOG="$ROOT/remoteadv1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '821\tissue-321-remote-advance-race-case\tlib/x/**\t321\tfeat/321-remote-advance-race-case\t%s\thttps://github.com/acme/app/pull/821\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$REMOTEADV_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/remoteadv1/canon" && PATH="$ROOT/remoteadv1/shim:$PATH" "$RC" 321 --claim-id issue-321-remote-advance-race-case --repo acme/app 2>&1); rc=$?
check    "remote-advance race exits 3"                    "$rc" "3"
contains "names the remote CAS refusal"                   "$out" "remote branch CAS delete refused"
lacks    "does not claim success on remote-advance race"  "$out" "OK —"
remote_br=$(git -C "$ROOT/remoteadv1/canon" ls-remote --heads origin 'feat/321-remote-advance-race-case')
[[ -n "$remote_br" ]] && ok "remote-advance race: advanced remote branch preserved" || bad "remote-advance race: remote branch was deleted despite the race"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "remote-advance race: label was never touched" || bad "remote-advance race: label edit was attempted"

echo "third Codex review: worktree cleanly switches to another branch between the safety proof and removal — refuse (rc=3), never a substitute for the dirty-file hook"
SWITCHRACE_SHA=$(term_fixture switchrace1 322 branch-switch-race-case)
# Simulates a concurrent process cleanly switching the registered worktree to
# an unrelated branch in the exact window between terminal_cleanup_release's
# safety proof (which already validated the worktree's original branch/HEAD)
# and the non-force `git worktree remove` call. The switch is clean — no
# uncommitted changes — so `git status --porcelain` alone stays silent; only
# the dedicated post-proof branch re-check catches it.
write_git_shim switchrace1 status2 feat/322-branch-switch-race-case \
  '"$REAL_GIT" -C "$WT" checkout -q -b decoy-branch-322'
export GH_PR_ALL_TSV="$ROOT/switchrace1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/switchrace1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/switchrace1/gh-state"
export GH_LOG="$ROOT/switchrace1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '822\tissue-322-branch-switch-race-case\tlib/x/**\t322\tfeat/322-branch-switch-race-case\t%s\thttps://github.com/acme/app/pull/822\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$SWITCHRACE_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/switchrace1/canon" && PATH="$ROOT/switchrace1/shim:$PATH" "$RC" 322 --claim-id issue-322-branch-switch-race-case --repo acme/app 2>&1); rc=$?
check    "branch-switch race exits 3"                  "$rc" "3"
contains "names the branch-switch TOCTOU refusal"       "$out" "switched off branch"
lacks    "does not claim success on branch-switch race" "$out" "OK —"
[[ -d "$ROOT/switchrace1/wt-322-branch-switch-race-case" ]] &&
  ok "branch-switch race: worktree preserved" || bad "branch-switch race: worktree was removed despite the race"
br=$(git -C "$ROOT/switchrace1/canon" branch --list 'feat/322-branch-switch-race-case')
[[ -n "$br" ]] && ok "branch-switch race: original local branch left untouched" || bad "branch-switch race: original local branch was deleted"
decoy_br=$(git -C "$ROOT/switchrace1/wt-322-branch-switch-race-case" rev-parse --abbrev-ref HEAD)
[[ "$decoy_br" == "decoy-branch-322" ]] &&
  ok "branch-switch race: worktree still checked out on the raced-in branch" || bad "branch-switch race: worktree branch was reverted/lost"
remote_br=$(git -C "$ROOT/switchrace1/canon" ls-remote --heads origin 'feat/322-branch-switch-race-case')
[[ -n "$remote_br" ]] && ok "branch-switch race: remote PR-head branch left untouched" || bad "branch-switch race: remote branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "branch-switch race: label was never touched" || bad "branch-switch race: label edit was attempted"

echo "#153 round 3 · production runs no command named by an inherited variable"
# The removed RELEASE_CLAIM_TEST_*_HOOK variables, pointed at an executable
# sentinel, over a run that reaches every window they used to fire in. If any
# production path still executes one, the sentinel leaves a marker.
SENT_DIR="$ROOT/sentinel"
mkdir -p "$SENT_DIR"
cat > "$SENT_DIR/run" <<SENT
#!/usr/bin/env bash
echo "EXECUTED \$0 \$*" >> "$SENT_DIR/fired"
exit 0
SENT
chmod +x "$SENT_DIR/run"
: > "$SENT_DIR/fired"
SENT_SHA=$(term_fixture sentinel1 324 hook-sentinel-case)
export GH_PR_ALL_TSV="$ROOT/sentinel1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/sentinel1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/sentinel1/gh-state"
export GH_LOG="$ROOT/sentinel1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '824\tissue-324-hook-sentinel-case\tlib/x/**\t324\tfeat/324-hook-sentinel-case\t%s\thttps://github.com/acme/app/pull/824\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$SENT_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/sentinel1/canon" && \
  RELEASE_CLAIM_TEST_DIRTY_HOOK="$SENT_DIR/run" \
  RELEASE_CLAIM_TEST_LOCAL_ADVANCE_HOOK="$SENT_DIR/run" \
  RELEASE_CLAIM_TEST_REMOTE_ADVANCE_HOOK="$SENT_DIR/run" \
  GIBSON_CLAIM_TEST_ROLLBACK_HOOK="$SENT_DIR/run" \
  "$RC" 324 --claim-id issue-324-hook-sentinel-case --repo acme/app 2>&1); rc=$?
check "the sentinel run reached full terminal cleanup" "$rc" "0"
check "no removed hook was executed" "$(grep -c . "$SENT_DIR/fired" || true)" "0"
for v in RELEASE_CLAIM_TEST_DIRTY_HOOK RELEASE_CLAIM_TEST_LOCAL_ADVANCE_HOOK \
         RELEASE_CLAIM_TEST_REMOTE_ADVANCE_HOOK GIBSON_CLAIM_TEST_ROLLBACK_HOOK; do
  if grep -q "$v" "$RC"; then
    bad "$v is still referenced in release-claim.sh"
  else
    ok "$v is gone from release-claim.sh"
  fi
done

echo "third Codex review: worktree gets a clean commit (HEAD move) on the same branch between the safety proof and removal — refuse (rc=3)"
HEADMOVE_SHA=$(term_fixture headmove1 323 head-move-race-case)
# Simulates a concurrent process landing a clean commit on the *same* branch
# in the window between the safety proof and removal. Status stays clean and
# the branch name is unchanged — only the HEAD re-check catches this, not the
# dirty-status check and not the branch-identity check.
write_git_shim headmove1 status2 feat/323-head-move-race-case \
  '"$REAL_GIT" -C "$WT" commit --allow-empty -qm "raced commit, still on the same branch"'
export GH_PR_ALL_TSV="$ROOT/headmove1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/headmove1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/headmove1/gh-state"
export GH_LOG="$ROOT/headmove1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '823\tissue-323-head-move-race-case\tlib/x/**\t323\tfeat/323-head-move-race-case\t%s\thttps://github.com/acme/app/pull/823\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$HEADMOVE_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/headmove1/canon" && PATH="$ROOT/headmove1/shim:$PATH" "$RC" 323 --claim-id issue-323-head-move-race-case --repo acme/app 2>&1); rc=$?
check    "head-move race exits 3"                   "$rc" "3"
contains "names the HEAD-move TOCTOU refusal"        "$out" "HEAD moved"
lacks    "does not claim success on head-move race"  "$out" "OK —"
[[ -d "$ROOT/headmove1/wt-323-head-move-race-case" ]] &&
  ok "head-move race: worktree preserved" || bad "head-move race: worktree was removed despite the race"
br=$(git -C "$ROOT/headmove1/canon" branch --list 'feat/323-head-move-race-case')
[[ -n "$br" ]] && ok "head-move race: local branch left untouched" || bad "head-move race: local branch was deleted"
raced_head=$(git -C "$ROOT/headmove1/wt-323-head-move-race-case" rev-parse HEAD)
[[ "$raced_head" != "$HEADMOVE_SHA" ]] &&
  ok "head-move race: worktree HEAD still reflects the raced-in commit" || bad "head-move race: raced commit was lost"
remote_br=$(git -C "$ROOT/headmove1/canon" ls-remote --heads origin 'feat/323-head-move-race-case')
[[ -n "$remote_br" ]] && ok "head-move race: remote PR-head branch left untouched" || bad "head-move race: remote branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "head-move race: label was never touched" || bad "head-move race: label edit was attempted"

echo "#153 blocker 4: --keep-worktree without --keep-branch must refuse branch deletion (rc=3) rather than leave a retained worktree without its branch"
KWNB_SHA=$(term_fixture kwnb1 324 keep-worktree-no-keep-branch-case)
export GH_PR_ALL_TSV="$ROOT/kwnb1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/kwnb1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/kwnb1/gh-state"
export GH_LOG="$ROOT/kwnb1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '824\tissue-324-keep-worktree-no-keep-branch-case\tlib/x/**\t324\tfeat/324-keep-worktree-no-keep-branch-case\t%s\thttps://github.com/acme/app/pull/824\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$KWNB_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/kwnb1/canon" && "$RC" 324 --claim-id issue-324-keep-worktree-no-keep-branch-case --repo acme/app --keep-worktree 2>&1); rc=$?
check    "--keep-worktree without --keep-branch exits 3"     "$rc" "3"
contains "names the retained-worktree-loses-branch refusal"  "$out" "a retained worktree must not lose its branch"
lacks    "does not claim success"                             "$out" "OK —"
[[ -d "$ROOT/kwnb1/wt-324-keep-worktree-no-keep-branch-case" ]] &&
  ok "--keep-worktree/no-keep-branch: worktree retained" || bad "--keep-worktree/no-keep-branch: worktree was removed"
br=$(git -C "$ROOT/kwnb1/canon" branch --list 'feat/324-keep-worktree-no-keep-branch-case')
[[ -n "$br" ]] && ok "--keep-worktree/no-keep-branch: local branch preserved" || bad "--keep-worktree/no-keep-branch: local branch was deleted"
remote_br=$(git -C "$ROOT/kwnb1/canon" ls-remote --heads origin 'feat/324-keep-worktree-no-keep-branch-case')
[[ -n "$remote_br" ]] && ok "--keep-worktree/no-keep-branch: remote PR-head branch preserved" || bad "--keep-worktree/no-keep-branch: remote branch was deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "--keep-worktree/no-keep-branch: label was never touched" || bad "--keep-worktree/no-keep-branch: label edit was attempted"

echo "#153 blocker 5: sibling claim remains but agent-claimed is actually absent — refuse success (rc=3)"
new_repo "$ROOT/termsibmissing" acme/app
git -C "$ROOT/termsibmissing/canon" worktree add -q "$ROOT/termsibmissing/wt-220-checkout-a" \
  -b feat/220-checkout-a origin/main
(
  cd "$ROOT/termsibmissing/wt-220-checkout-a" || exit 1
  git commit --allow-empty -qs -m "chore: reserve issue #220 for issue-220-checkout-a"
  git push -q -u origin feat/220-checkout-a
) >/dev/null 2>&1
TERMSIBMISS_SHA=$(git -C "$ROOT/termsibmissing/wt-220-checkout-a" rev-parse HEAD)
export PATH="$ROOT/term/bin:$PATH"
export GH_PR_OPEN_TSV="$ROOT/termsibmissing/open.tsv"
printf '901\tissue-220-checkout-b\tlib/checkout/b/**\tfeat/220-checkout-b\thttps://github.com/acme/app/pull/901\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\tfalse\n' \
  > "$GH_PR_OPEN_TSV"
export GH_PR_ALL_TSV="$ROOT/termsibmissing/all.tsv"
printf '902\tissue-220-checkout-a\tlib/checkout/a/**\t220\tfeat/220-checkout-a\t%s\thttps://github.com/acme/app/pull/902\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERMSIBMISS_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
export GH_STATE="$ROOT/termsibmissing/gh-state"
export GH_LOG="$ROOT/termsibmissing/gh.log"
export GH_LABELS="tier-b"
unset GH_PR_LIST_EXIT GH_PR_ALL_EXIT GH_PR_OPEN_EXIT GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2 GH_PR_CLOSE_EXIT GH_PR_CLOSE_LOG GH_OPEN_CALLS
unset GH_PR_OPEN_NUMBERS GH_PR_OPEN_NUMBERS_EXIT
rm -f "$GH_STATE" "$GH_LOG"
out=$(cd "$ROOT/termsibmissing/canon" && "$RC" 220 --claim-id issue-220-checkout-a --repo acme/app 2>&1); rc=$?
check    "sibling remains but label actually absent exits 3" "$rc" "3"
contains "names the missing label"                            "$out" "agent-claimed is ABSENT"
lacks    "does not falsely claim keeping the label"            "$out" "OK —"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "missing-label case: no edit attempted (removal is not what's wrong)" || bad "missing-label case: unexpected label edit attempted"
[[ ! -d "$ROOT/termsibmissing/wt-220-checkout-a" ]] &&
  ok "missing-label case: the claim's own worktree mutation still completed" || bad "missing-label case: worktree mutation was skipped"

echo "#153 · post-mutation reread is fail-closed (never best-effort for terminal evidence)"

echo "post-mutation open-claim reread failure yields rc=3, preserves label"
REREADFAIL_SHA=$(term_fixture rereadfail1 307 reread-fail-case)
export GH_PR_ALL_TSV="$ROOT/rereadfail1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/rereadfail1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/rereadfail1/gh-state"
export GH_LOG="$ROOT/rereadfail1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '807\tissue-307-reread-fail-case\tlib/x/**\t307\tfeat/307-reread-fail-case\t%s\thttps://github.com/acme/app/pull/807\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$REREADFAIL_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
# Only the SECOND open-inventory read fails. The first one is the fail-closed
# pre-mutation authoritative read the open-PR path now performs (#153); if it
# failed too, the run would refuse up front and never exercise the terminal
# post-mutation reread this test is about.
export GH_OPEN_CALLS="$ROOT/rereadfail1/open-calls"
: > "$GH_OPEN_CALLS"
export GH_PR_OPEN_TSV2="$ROOT/rereadfail1/open2.tsv"
: > "$GH_PR_OPEN_TSV2"
export GH_PR_OPEN_EXIT2=1
out=$(cd "$ROOT/rereadfail1/canon" && "$RC" 307 --claim-id issue-307-reread-fail-case --repo acme/app 2>&1); rc=$?
unset GH_OPEN_CALLS GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2
check    "post-mutation reread failure exits 3"   "$rc" "3"
contains "names reread failure"                   "$out" "post-mutation reread of live PR-body claims failed"
lacks    "does not claim success on reread failure" "$out" "OK —"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "reread-failure case: label was never removed" || bad "reread-failure case: label removal was attempted"
# The claim's own worktree/branch mutation already ran safely (it is the
# GitHub reread afterward that failed) — that is exactly why label policy
# must not trust an unreadable postcondition.
[[ ! -d "$ROOT/rereadfail1/wt-307-reread-fail-case" ]] &&
  ok "reread-failure case: worktree mutation still completed" || bad "reread-failure case: worktree mutation was skipped"

echo "post-mutation malformed open-claim row yields rc=3, preserves label"
MALFORMED_SHA=$(term_fixture malformedreread1 308 malformed-reread-case)
export GH_PR_ALL_TSV="$ROOT/malformedreread1/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/malformedreread1/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/malformedreread1/gh-state"
export GH_LOG="$ROOT/malformedreread1/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
printf '808\tissue-308-malformed-reread-case\tlib/x/**\t308\tfeat/308-malformed-reread-case\t%s\thttps://github.com/acme/app/pull/808\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$MALFORMED_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
# Malformed only on the post-mutation reread, for the same reason as above.
export GH_OPEN_CALLS="$ROOT/malformedreread1/open-calls"
: > "$GH_OPEN_CALLS"
export GH_PR_OPEN_TSV2="$ROOT/malformedreread1/open2.tsv"
printf 'not-enough-fields\n' > "$GH_PR_OPEN_TSV2"
out=$(cd "$ROOT/malformedreread1/canon" && "$RC" 308 --claim-id issue-308-malformed-reread-case --repo acme/app 2>&1); rc=$?
unset GH_OPEN_CALLS GH_PR_OPEN_TSV2
check    "malformed reread row exits 3"          "$rc" "3"
contains "names malformed reread row"            "$out" "malformed/truncated row"
lacks    "does not claim success on malformed reread" "$out" "OK —"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "malformed-reread case: label was never removed" || bad "malformed-reread case: label removal was attempted"

echo "#153 · multi-slice: releasing a terminal claim keeps a live open sibling"
new_repo "$ROOT/termsib" acme/app
git -C "$ROOT/termsib/canon" worktree add -q "$ROOT/termsib/wt-210-checkout-a" \
  -b feat/210-checkout-a origin/main
(
  cd "$ROOT/termsib/wt-210-checkout-a" || exit 1
  git commit --allow-empty -qs -m "chore: reserve issue #210 for issue-210-checkout-a"
  git push -q -u origin feat/210-checkout-a
) >/dev/null 2>&1
TERMSIB_SHA=$(git -C "$ROOT/termsib/wt-210-checkout-a" rev-parse HEAD)
export PATH="$ROOT/term/bin:$PATH"
export GH_PR_OPEN_TSV="$ROOT/termsib/open.tsv"
# The sibling PR-body claim (issue-210-checkout-b) exists only in this
# post-mutation OPEN listing — release-claim.sh never saw it during the
# identity check (which only queries --state all for the target id), so the
# label decision below can only be correct if terminal_cleanup_release()
# performs a fresh GitHub read after mutation rather than reusing any earlier
# snapshot (#153 AC4/AC8).
printf '900\tissue-210-checkout-b\tlib/checkout/b/**\tfeat/210-checkout-b\thttps://github.com/acme/app/pull/900\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\tfalse\n' \
  > "$GH_PR_OPEN_TSV"
export GH_PR_ALL_TSV="$ROOT/termsib/all.tsv"
printf '899\tissue-210-checkout-a\tlib/checkout/a/**\t210\tfeat/210-checkout-a\t%s\thttps://github.com/acme/app/pull/899\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERMSIB_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
export GH_STATE="$ROOT/termsib/gh-state"
export GH_LOG="$ROOT/termsib/gh.log"
export GH_LABELS="agent-claimed,tier-b"
unset GH_PR_LIST_EXIT GH_PR_ALL_EXIT GH_PR_OPEN_EXIT GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2 GH_PR_CLOSE_EXIT GH_PR_CLOSE_LOG GH_OPEN_CALLS
unset GH_PR_OPEN_NUMBERS GH_PR_OPEN_NUMBERS_EXIT
rm -f "$GH_STATE" "$GH_LOG"
out=$(cd "$ROOT/termsib/canon" && "$RC" 210 --claim-id issue-210-checkout-a --repo acme/app 2>&1); rc=$?
check    "releasing one terminal slice exits 0"     "$rc" "0"
contains "keeps agent-claimed for the live sibling" "$out" "issue-210-checkout-b"
lacks    "does not claim the label was removed"     "$out" "removed agent-claimed"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "sibling case: label was never removed" || bad "sibling case: label removal was attempted"
[[ ! -d "$ROOT/termsib/wt-210-checkout-a" ]] &&
  ok "released slice's worktree is gone" || bad "released slice's worktree survived"

echo "#153 blocker 6: URL pull-number mismatch inside a terminal PR body propagates through the real pr-claims.sh jq pipeline to release-claim.sh (fail closed)"
# The "term" fake gh above bypasses jq entirely (it hands release-claim.sh
# pre-baked TSV rows as if pr-claims.sh already emitted them), so it can
# never catch a PR whose own URL disagrees with its number. This fake gh
# instead returns real GraphQL PR JSON (branching on the query's
# `states: [OPEN]` restriction exactly like the real API would) and lets the
# real jq inside pr-claims.sh run.
URLNUM_SHA=$(term_fixture urlnum1 320 urlnum-case)
mkdir -p "$ROOT/urlnum1/bin-json"
cat > "$ROOT/urlnum1/bin-json/gh" <<'GHJSON'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/app"; exit 0 ;;
  api)
    [[ "$2" == "graphql" ]] || exit 1
    shift 2
    jqexpr=""
    want_open=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --jq) jqexpr="$2"; shift 2 ;;
        *) case "$1" in *"states: [OPEN]"*) want_open=1 ;; esac; shift ;;
      esac
    done
    if [[ "$want_open" -eq 1 ]]; then
      jq -r "$jqexpr" < "${GH_JSON_OPEN:?GH_JSON_OPEN not set}"
    else
      jq -r "$jqexpr" < "${GH_JSON_ALL:?GH_JSON_ALL not set}"
    fi
    exit $?
    ;;
  issue) exit 1 ;;
  *) exit 1 ;;
esac
GHJSON
chmod +x "$ROOT/urlnum1/bin-json/gh"
# Full GraphQL response envelopes: pr-claims.sh's --jq starts at
# .data.repository.pullRequests.nodes[].
export GH_JSON_OPEN="$ROOT/urlnum1/open.json"
printf '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' > "$GH_JSON_OPEN"
export GH_JSON_ALL="$ROOT/urlnum1/all.json"
printf '{"data":{"repository":{"pullRequests":{"nodes":[{"number":820,"state":"MERGED","body":"- Active-work claim: issue-320-urlnum-case\\n- Claim scope: lib/x/**\\n- Issue: #320","headRefName":"feat/320-urlnum-case","headRefOid":"%s","url":"https://github.com/acme/app/pull/9999","createdAt":"2026-08-05T00:00:00Z","updatedAt":"2026-08-06T00:00:00Z","isCrossRepository":false,"mergeCommit":{"oid":"%s"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}' \
  "$URLNUM_SHA" "$HEX40" > "$GH_JSON_ALL"
out=$(cd "$ROOT/urlnum1/canon" && PATH="$ROOT/urlnum1/bin-json:$PATH" GH_JSON_OPEN="$GH_JSON_OPEN" GH_JSON_ALL="$GH_JSON_ALL" "$RC" 320 --claim-id issue-320-urlnum-case --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "URL pull-number mismatch propagates and refuses (rc=$rc)" \
  || bad "URL pull-number mismatch did not refuse (rc=$rc): $out"
echo "$out" | grep -qiE 'pull-number|cannot verify terminal PR-body claim evidence' \
  && ok "names the propagated pr-claims.sh failure" \
  || bad "missing propagated failure detail: $out"
[[ -d "$ROOT/urlnum1/wt-320-urlnum-case" ]] &&
  ok "URL mismatch case: worktree untouched" || bad "URL mismatch case: worktree removed"

# =========================================================================
# #153 · the OPEN-PR release path: authoritative inventory + honest reporting
# =========================================================================
# Two defects this section pins down:
#
#  1. The path used to read the live claim inventory as
#     `$(pr-claims.sh list "$PR_REPO" 2>/dev/null || true)`. A missing
#     reader, an expired token, a rate limit, or a mid-pagination API failure
#     all became "no live PR claims" — and the run then went on to close PRs,
#     delete branches, strip the ledger, and remove agent-claimed on the
#     strength of a view it never actually read. Every one of those failures
#     must now refuse BEFORE any mutation.
#
#  2. It closed the PR, then best-effort removed a GUESSED worktree path and
#     `|| true`'d both branch deletes, and printed "released PR-body claim"
#     regardless. It is now close-only: it closes, re-reads to PROVE the
#     claim is gone, names anything it did not clean up, and returns
#     INCOMPLETE (3) rather than reporting success it cannot support.
#
# All of it is offline: the fake gh above serves the staged inventory, and
# GH_PR_OPEN_TSV2 lets the post-close read differ from the pre-close one.
echo "#153 · open-PR release: the live claim inventory is authoritative, not best-effort"

open_fixture() {
  # Build a repo with a registered worktree + local/remote branch for an open
  # PR-body claim, and point the fake gh's state files at it. Echoes nothing;
  # sets the GH_* fixture env for the caller.
  local dir="$1" issue="$2" slug="$3"
  new_repo "$ROOT/$dir" acme/app
  git -C "$ROOT/$dir/canon" worktree add -q "$ROOT/$dir/wt-${issue}-${slug}" \
    -b "feat/${issue}-${slug}" origin/main
  (
    cd "$ROOT/$dir/wt-${issue}-${slug}" || exit 1
    git commit --allow-empty -qs -m "chore: reserve issue #$issue for issue-${issue}-${slug}"
    git push -q -u origin "feat/${issue}-${slug}"
  ) >/dev/null 2>&1
  export GH_PR_OPEN_TSV="$ROOT/$dir/open.tsv"
  export GH_PR_ALL_TSV="$ROOT/$dir/all.tsv"
  : > "$GH_PR_ALL_TSV"
  export GH_STATE="$ROOT/$dir/gh-state"
  export GH_LOG="$ROOT/$dir/gh.log"
  export GH_PR_CLOSE_LOG="$ROOT/$dir/close.log"
  export GH_LABELS="agent-claimed,tier-b"
  export GH_OPEN_CALLS="$ROOT/$dir/open-calls"
  : > "$GH_OPEN_CALLS"
  export GH_PR_CLOSED_NUMBERS="$ROOT/$dir/closed-numbers"
  : > "$GH_PR_CLOSED_NUMBERS"
  rm -f "$GH_STATE" "$GH_LOG" "$GH_PR_CLOSE_LOG"
  unset GH_PR_LIST_EXIT GH_PR_ALL_EXIT GH_PR_OPEN_EXIT GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2 GH_PR_CLOSE_EXIT
  unset GH_PR_OPEN_NUMBERS GH_PR_OPEN_NUMBERS_EXIT
}

export PATH="$ROOT/term/bin:$PATH"

echo "an unreadable inventory (API/pagination failure) refuses before ANY mutation"
open_fixture openfail 400 inventory-fail
open_row 901 issue-400-inventory-fail 'lib/x/**' feat/400-inventory-fail > "$GH_PR_OPEN_TSV"
export GH_PR_OPEN_EXIT=1
out=$(cd "$ROOT/openfail/canon" && "$RC" 400 --claim-id issue-400-inventory-fail --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_EXIT
[[ "$rc" -ne 0 ]] && ok "unreadable inventory exits nonzero" || bad "unreadable inventory exits 0: $out"
contains "names the unreadable inventory" "$out" "unreadable claim inventory is not an empty one"
lacks    "does not claim success"         "$out" "OK —"
[[ -z "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "unreadable inventory: no PR was closed" || bad "unreadable inventory: a PR was closed anyway"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "unreadable inventory: no label edit" || bad "unreadable inventory: label was edited"
[[ -d "$ROOT/openfail/wt-400-inventory-fail" ]] &&
  ok "unreadable inventory: worktree untouched" || bad "unreadable inventory: worktree removed"
[[ -n "$(git -C "$ROOT/openfail/canon" branch --list 'feat/400-inventory-fail')" ]] &&
  ok "unreadable inventory: local branch untouched" || bad "unreadable inventory: local branch deleted"
[[ -n "$(git -C "$ROOT/openfail/canon" ls-remote --heads origin 'feat/400-inventory-fail')" ]] &&
  ok "unreadable inventory: remote branch untouched" || bad "unreadable inventory: remote branch deleted"
table=$(git -C "$ROOT/openfail/canon" show origin/main:docs/active-work.md)
contains "unreadable inventory: ledger untouched" "$table" "issue-15-checkout-totals"

echo "a malformed/truncated inventory row refuses before ANY mutation"
open_fixture openmalformed 401 malformed-row
printf 'not-enough-fields\n' > "$GH_PR_OPEN_TSV"
out=$(cd "$ROOT/openmalformed/canon" && "$RC" 401 --claim-id issue-401-malformed-row --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "malformed inventory exits nonzero" || bad "malformed inventory exits 0: $out"
contains "names the malformed row" "$out" "malformed/truncated row"
[[ -z "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "malformed inventory: no PR was closed" || bad "malformed inventory: a PR was closed anyway"
[[ -d "$ROOT/openmalformed/wt-401-malformed-row" ]] &&
  ok "malformed inventory: worktree untouched" || bad "malformed inventory: worktree removed"

echo "a missing/unexecutable pr-claims.sh reader refuses before ANY mutation"
open_fixture openreader 402 missing-reader
open_row 903 issue-402-missing-reader 'lib/x/**' feat/402-missing-reader > "$GH_PR_OPEN_TSV"
# Copy release-claim.sh somewhere WITHOUT its reader alongside it: SCRIPT_DIR
# is derived from the script's own location, so this is the real "the
# authoritative reader is not installed" shape, not a mocked one. The shared
# cleanup guard library DOES travel with it — this scenario is about the
# missing reader, and the separate scenario below covers a missing library.
mkdir -p "$ROOT/openreader/lonely/lib"
cp "$RC" "$ROOT/openreader/lonely/release-claim.sh"
cp "$SCRIPT_DIR/../lib/claim-guards.sh" "$ROOT/openreader/lonely/lib/claim-guards.sh"
chmod +x "$ROOT/openreader/lonely/release-claim.sh"
out=$(cd "$ROOT/openreader/canon" && "$ROOT/openreader/lonely/release-claim.sh" 402 --claim-id issue-402-missing-reader --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing reader exits nonzero" || bad "missing reader exits 0: $out"
contains "names the missing reader" "$out" "missing or not executable"
[[ -z "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "missing reader: no PR was closed" || bad "missing reader: a PR was closed anyway"
[[ -d "$ROOT/openreader/wt-402-missing-reader" ]] &&
  ok "missing reader: worktree untouched" || bad "missing reader: worktree removed"

echo "a missing shared cleanup-guard library refuses before ANY mutation (#153 review P1 0D)"
# The guards are what stand between this script and an rm -rf of a dirty
# worktree. A copy deployed without them must refuse to run at all, not fall
# back to the unguarded behaviour they replaced.
open_fixture openguards 404 missing-guards
open_row 905 issue-404-missing-guards 'lib/x/**' feat/404-missing-guards > "$GH_PR_OPEN_TSV"
mkdir -p "$ROOT/openguards/lonely"
cp "$RC" "$ROOT/openguards/lonely/release-claim.sh"
cp "$SCRIPT_DIR/../pr-claims.sh" "$ROOT/openguards/lonely/pr-claims.sh"
chmod +x "$ROOT/openguards/lonely/release-claim.sh" "$ROOT/openguards/lonely/pr-claims.sh"
out=$(cd "$ROOT/openguards/canon" && "$ROOT/openguards/lonely/release-claim.sh" 404 --claim-id issue-404-missing-guards --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "missing guard library exits nonzero" || bad "missing guard library exits 0: $out"
contains "names the missing guard library" "$out" "claim-guards.sh"
[[ -z "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "missing guard library: no PR was closed" || bad "missing guard library: a PR was closed anyway"
[[ -d "$ROOT/openguards/wt-404-missing-guards" ]] &&
  ok "missing guard library: worktree untouched" || bad "missing guard library: worktree removed"

echo "the happy path hands the closed PR to the SHARED exact cleanup machinery"
open_fixture openroute 411 routed
ROUTE_SHA=$(git -C "$ROOT/openroute/wt-411-routed" rev-parse HEAD)
open_row 914 issue-411-routed 'lib/x/**' feat/411-routed > "$GH_PR_OPEN_TSV"
export GH_PR_OPEN_TSV2="$ROOT/openroute/open2.tsv"
: > "$GH_PR_OPEN_TSV2"
# Once closed, the PR is terminal evidence: CLOSED, exact head SHA, no merge
# commit, this repository, not a fork.
printf '914\tissue-411-routed\tlib/x/**\t411\tfeat/411-routed\t%s\thttps://github.com/acme/app/pull/914\tCLOSED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$ROUTE_SHA" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/openroute/canon" && "$RC" 411 --claim-id issue-411-routed --repo acme/app 2>&1); rc=$?
check    "routed release exits 0"                "$rc" "0"
contains "closed the owning PR"                  "$out" "closing PR #914"
contains "used the shared terminal verification" "$out" "verified terminal PR-body claim #914"
contains "removed the EXACT registered worktree" "$out" "removing exact registered worktree"
contains "reports the release"                   "$out" "OK — claim released for issue 411"
[[ ! -d "$ROOT/openroute/wt-411-routed" ]] &&
  ok "routed release removed the worktree" || bad "routed release left the worktree"
[[ -z "$(git -C "$ROOT/openroute/canon" branch --list 'feat/411-routed')" ]] &&
  ok "routed release removed the local branch" || bad "routed release left the local branch"
[[ -z "$(git -C "$ROOT/openroute/canon" ls-remote --heads origin 'feat/411-routed')" ]] &&
  ok "routed release removed the remote branch" || bad "routed release left the remote branch"

# --- #153 review round 4, P1: the head-branch binding precedes the close ----
# This used to be checked only AFTER `gh pr close` had already fired, so an
# exact claim marker sitting in the body of a PR on an unrelated branch was
# enough to close that PR — an irreversible mutation on a pull request whose
# identity was never bound to the claim. The check now runs before the first
# mutation and the mismatch is a plain refusal, not a partial run.
echo "#153 round 4 · an exact marker on an UNRELATED head branch never reaches gh pr close"
open_fixture openodd 412 odd-branch
# PR head branch deliberately not feat/412-odd-branch: identity cannot be
# bound to the claim id, so the PR must not be closed at all.
open_row 915 issue-412-odd-branch 'lib/x/**' hotfix/unrelated-branch > "$GH_PR_OPEN_TSV"
export GH_PR_OPEN_TSV2="$ROOT/openodd/open2.tsv"
: > "$GH_PR_OPEN_TSV2"
out=$(cd "$ROOT/openodd/canon" && "$RC" 412 --claim-id issue-412-odd-branch --repo acme/app 2>&1); rc=$?
check    "unbindable head branch is a PRE-MUTATION refusal (exit 1)" "$rc" "1"
contains "names the unbindable head branch" "$out" "is not the branch this claim id derives"
contains "says nothing was mutated"         "$out" "nothing was mutated"
lacks    "never reports success"             "$out" "OK —"
lacks    "never reports a partial run"       "$out" "INCOMPLETE"
[[ -z "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "unbindable branch: the PR was NEVER closed" || bad "unbindable branch: gh pr close was called on an unbound PR"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "unbindable branch: label never edited" || bad "unbindable branch: label edit attempted"
[[ -d "$ROOT/openodd/wt-412-odd-branch" ]] &&
  ok "unbindable branch: worktree untouched" || bad "unbindable branch: worktree removed"
[[ -n "$(git -C "$ROOT/openodd/canon" branch --list 'feat/412-odd-branch')" ]] &&
  ok "unbindable branch: local branch untouched" || bad "unbindable branch: local branch deleted"
[[ -n "$(git -C "$ROOT/openodd/canon" ls-remote --heads origin 'feat/412-odd-branch')" ]] &&
  ok "unbindable branch: remote branch untouched" || bad "unbindable branch: remote branch deleted"

echo "#153 round 4 · --dry-run refuses the same mismatch, so an operator sees it before trying it for real"
# Reset the open-inventory read counter: the fake serves GH_PR_OPEN_TSV2 from
# the second read onward, and the run above already consumed the first one.
: > "$GH_OPEN_CALLS"
out=$(cd "$ROOT/openodd/canon" && "$RC" 412 --claim-id issue-412-odd-branch --repo acme/app --dry-run 2>&1); rc=$?
check    "dry-run mismatch exits 1"        "$rc" "1"
contains "dry-run names the mismatch"      "$out" "is not the branch this claim id derives"
lacks    "dry-run never offers to close it" "$out" "would close PR"
[[ -z "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "dry-run mismatch: still no close" || bad "dry-run mismatch: a PR was closed"

# --- #153 review round 3, P2: a post-close evidence failure is exit 3 -------
# try_terminal_pr_body_release used to `die` on unusable terminal evidence.
# Called from HERE the PR is already closed, so that exit-1 death was a
# partial mutation escaping the documented close-only lifecycle: no
# INCOMPLETE banner, no preserved-label report, no recovery instruction, and
# the wrong exit code for callers that distinguish "refused" (1) from
# "did part of the work" (3).
echo "#153 round 3 · terminal evidence UNREADABLE after a successful close: exit 3, artifacts + label preserved"
open_fixture openterm 413 terminal-unreadable
open_row 916 issue-413-terminal-unreadable 'lib/x/**' feat/413-terminal-unreadable > "$GH_PR_OPEN_TSV"
export GH_PR_OPEN_TSV2="$ROOT/openterm/open2.tsv"
: > "$GH_PR_OPEN_TSV2"          # post-close: the claim really did stop being live
export GH_PR_ALL_EXIT=1         # …but the closed PR's own terminal evidence will not read
out=$(cd "$ROOT/openterm/canon" && "$RC" 413 --claim-id issue-413-terminal-unreadable --repo acme/app 2>&1); rc=$?
unset GH_PR_ALL_EXIT
check    "post-close terminal read failure exits 3, not 1" "$rc" "3"
contains "the live read succeeded and the PR was closed"   "$out" "closing PR #916"
[[ -n "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "the close really happened" || bad "the PR was never closed"
contains "names the unusable terminal evidence" "$out" "terminal evidence is unusable"
contains "names the underlying read failure"    "$out" "gh query failed"
contains "reports INCOMPLETE"                   "$out" "INCOMPLETE"
contains "names the recovery action"            "$out" "RECOVERY"
contains "the recovery is the bound re-run"     "$out" "--pr 916"
contains "says the artifacts were preserved"    "$out" "are being PRESERVED"
contains "preserves the label"                  "$out" "preserving agent-claimed"
lacks    "never reports success"                "$out" "OK —"
[[ -d "$ROOT/openterm/wt-413-terminal-unreadable" ]] &&
  ok "unreadable terminal evidence: worktree preserved" || bad "unreadable terminal evidence: worktree removed"
[[ -n "$(git -C "$ROOT/openterm/canon" branch --list 'feat/413-terminal-unreadable')" ]] &&
  ok "unreadable terminal evidence: local branch preserved" || bad "unreadable terminal evidence: local branch deleted"
[[ -n "$(git -C "$ROOT/openterm/canon" ls-remote --heads origin 'feat/413-terminal-unreadable')" ]] &&
  ok "unreadable terminal evidence: remote branch preserved" || bad "unreadable terminal evidence: remote branch deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "unreadable terminal evidence: label never edited" || bad "unreadable terminal evidence: label edit attempted"

echo "#153 round 3 · terminal evidence that CONTRADICTS the close is equally exit 3, with the exact check unchanged"
open_fixture openterm2 414 terminal-contradicts
open_row 917 issue-414-terminal-contradicts 'lib/x/**' feat/414-terminal-contradicts > "$GH_PR_OPEN_TSV"
export GH_PR_OPEN_TSV2="$ROOT/openterm2/open2.tsv"
: > "$GH_PR_OPEN_TSV2"
TERMC_SHA=$(git -C "$ROOT/openterm2/wt-414-terminal-contradicts" rev-parse HEAD)
# The evidence says the PR is still OPEN. The exact state check is unchanged —
# it still refuses — it just no longer decides the process's exit code.
printf '917\tissue-414-terminal-contradicts\tlib/x/**\t414\tfeat/414-terminal-contradicts\t%s\thttps://github.com/acme/app/pull/917\tOPEN\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERMC_SHA" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/openterm2/canon" && "$RC" 414 --claim-id issue-414-terminal-contradicts --repo acme/app 2>&1); rc=$?
check    "contradictory terminal evidence exits 3" "$rc" "3"
contains "the exact state check still fires"       "$out" "is still OPEN"
contains "reports INCOMPLETE"                      "$out" "INCOMPLETE"
contains "names the recovery action"               "$out" "RECOVERY"
lacks    "never reports success"                   "$out" "OK —"
[[ -d "$ROOT/openterm2/wt-414-terminal-contradicts" ]] &&
  ok "contradictory evidence: worktree preserved" || bad "contradictory evidence: worktree removed"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "contradictory evidence: label never edited" || bad "contradictory evidence: label edit attempted"

echo "#153 round 3 · the SAME failure before any mutation is still a plain refusal (exit 1) that names the binding"
# Nothing has been closed on the --claim-id-with-no-ledger-row path, so a
# fatal evidence verdict there is safe to refuse outright — and must name
# which binding failed instead of collapsing into "no live claim".
TERMPRE_SHA=$(term_fixture termpre 415 terminal-premutation)
export GH_PR_ALL_TSV="$ROOT/termpre/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/termpre/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/termpre/gh-state"
export GH_LOG="$ROOT/termpre/gh.log"
export GH_PR_CLOSE_LOG="$ROOT/termpre/close.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG" "$GH_PR_CLOSE_LOG"
unset GH_PR_OPEN_TSV2 GH_OPEN_CALLS
printf '918\tissue-415-terminal-premutation\tlib/x/**\t415\tfeat/415-terminal-premutation\t%s\thttps://github.com/acme/app/pull/918\tOPEN\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$TERMPRE_SHA" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/termpre/canon" && "$RC" 415 --claim-id issue-415-terminal-premutation --repo acme/app --pr 918 2>&1); rc=$?
check    "pre-mutation fatal evidence exits 1" "$rc" "1"
contains "names the binding that failed"       "$out" "is still OPEN"
lacks    "does not hide behind the generic message" "$out" "no live claim"
[[ -z "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "pre-mutation refusal closed nothing" || bad "pre-mutation refusal closed a PR"
[[ -d "$ROOT/termpre/wt-415-terminal-premutation" ]] &&
  ok "pre-mutation refusal: worktree untouched" || bad "pre-mutation refusal: worktree removed"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "pre-mutation refusal: label never edited" || bad "pre-mutation refusal: label edit attempted"

echo "close-only: leftover worktree/branch are NAMED and returned INCOMPLETE, never reported as success"
open_fixture openleft 403 leftovers
open_row 904 issue-403-leftovers 'lib/x/**' feat/403-leftovers > "$GH_PR_OPEN_TSV"
export GH_PR_OPEN_TSV2="$ROOT/openleft/open2.tsv"
: > "$GH_PR_OPEN_TSV2"   # post-close: the claim is gone from the live view
out=$(cd "$ROOT/openleft/canon" && "$RC" 403 --claim-id issue-403-leftovers --repo acme/app 2>&1); rc=$?
check    "leftover cleanup exits 3 (INCOMPLETE)" "$rc" "3"
contains "closed the owning PR"                  "$out" "closing PR #904"
contains "names the leftover worktree"           "$out" "registered worktree on branch 'feat/403-leftovers'"
contains "names the leftover local branch"       "$out" "local branch 'feat/403-leftovers'"
contains "names the leftover remote branch"      "$out" "remote branch 'feat/403-leftovers'"
contains "tells the operator how to finish"      "$out" "--claim-id issue-403-leftovers"
contains "reports INCOMPLETE"                    "$out" "INCOMPLETE"
lacks    "never reports success"                 "$out" "OK —"
contains "preserves the label"                   "$out" "preserving agent-claimed"
[[ -n "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "leftover case: the PR really was closed" || bad "leftover case: PR was not closed"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "leftover case: label was never removed" || bad "leftover case: label removal was attempted"
# The old path force-removed a guessed worktree and '|| true'd both branch
# deletes. Close-only touches neither, so the exact verified terminal cleanup
# can still prove them safe on the follow-up run.
[[ -d "$ROOT/openleft/wt-403-leftovers" ]] &&
  ok "leftover case: worktree not force-removed" || bad "leftover case: worktree was force-removed"
[[ -n "$(git -C "$ROOT/openleft/canon" branch --list 'feat/403-leftovers')" ]] &&
  ok "leftover case: local branch not deleted" || bad "leftover case: local branch was deleted"
[[ -n "$(git -C "$ROOT/openleft/canon" ls-remote --heads origin 'feat/403-leftovers')" ]] &&
  ok "leftover case: remote branch not deleted" || bad "leftover case: remote branch was deleted"

# --- #153 review round 4, P1: no terminal evidence after a close is NOT ok --
# This fixture used to assert the opposite. With the artifacts already gone
# and an EMPTY terminal view, the run reported "OK — released PR-body claim"
# and removed agent-claimed — i.e. it treated "I cannot see the PR I just
# closed" as "there is nothing left to clean up". Those are different facts,
# and only one of them licenses stripping an issue-wide label. Absence of
# proof is not proof of absence on a mutation path.
echo "#153 round 4 · an EMPTY terminal view after a successful close is INCOMPLETE, never success"
open_fixture openclean 404 nothing-left
open_row 905 issue-404-nothing-left 'lib/x/**' feat/404-nothing-left > "$GH_PR_OPEN_TSV"
export GH_PR_OPEN_TSV2="$ROOT/openclean/open2.tsv"
: > "$GH_PR_OPEN_TSV2"
# Worktree and branches already gone (e.g. an earlier terminal cleanup) — so
# the ONLY thing standing between this run and a success message is whether it
# insists on proving the closed PR's identity.
git -C "$ROOT/openclean/canon" worktree remove --force "$ROOT/openclean/wt-404-nothing-left" >/dev/null 2>&1
git -C "$ROOT/openclean/canon" branch -D feat/404-nothing-left >/dev/null 2>&1
git -C "$ROOT/openclean/canon" push -q origin --delete feat/404-nothing-left >/dev/null 2>&1
: > "$GH_PR_ALL_TSV"   # no terminal row for the PR we just closed
out=$(cd "$ROOT/openclean/canon" && "$RC" 404 --claim-id issue-404-nothing-left --repo acme/app 2>&1); rc=$?
check    "absent terminal evidence exits 3"  "$rc" "3"
contains "the PR really was closed"          "$out" "closing PR #905"
contains "names the unproven identity"       "$out" "no exact terminal PR-body evidence"
contains "says the artifacts are preserved"  "$out" "are being PRESERVED"
contains "reports INCOMPLETE"                "$out" "INCOMPLETE"
contains "names the recovery action"         "$out" "RECOVERY"
contains "the recovery is the bound re-run"  "$out" "--pr 905"
contains "preserves the label"               "$out" "preserving agent-claimed"
lacks    "never reports success"             "$out" "OK —"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "absent terminal evidence: label never edited" || bad "absent terminal evidence: label edit attempted"

echo "#153 round 4 · the SUCCESS contract: VALID terminal evidence + genuinely absent artifacts completes and verifies the label"
open_fixture opencleanok 424 proven-clean
open_row 925 issue-424-proven-clean 'lib/x/**' feat/424-proven-clean > "$GH_PR_OPEN_TSV"
export GH_PR_OPEN_TSV2="$ROOT/opencleanok/open2.tsv"
: > "$GH_PR_OPEN_TSV2"
CLEANOK_SHA=$(git -C "$ROOT/opencleanok/wt-424-proven-clean" rev-parse HEAD)
git -C "$ROOT/opencleanok/canon" worktree remove --force "$ROOT/opencleanok/wt-424-proven-clean" >/dev/null 2>&1
git -C "$ROOT/opencleanok/canon" branch -D feat/424-proven-clean >/dev/null 2>&1
git -C "$ROOT/opencleanok/canon" push -q origin --delete feat/424-proven-clean >/dev/null 2>&1
# The closed PR's own terminal evidence: CLOSED, exact head SHA, no merge
# commit, this repository, not a fork. THIS is what authorizes success.
printf '925\tissue-424-proven-clean\tlib/x/**\t424\tfeat/424-proven-clean\t%s\thttps://github.com/acme/app/pull/925\tCLOSED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$CLEANOK_SHA" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/opencleanok/canon" && "$RC" 424 --claim-id issue-424-proven-clean --repo acme/app 2>&1); rc=$?
check    "proven-clean release exits 0"      "$rc" "0"
contains "the PR was closed"                 "$out" "closing PR #925"
contains "the terminal evidence was verified" "$out" "verified terminal PR-body claim #925"
contains "reports the release"               "$out" "OK — claim released for issue 424"
contains "verified label removal"            "$out" "removed agent-claimed from acme/app#424 (verified)"
lacks    "no INCOMPLETE banner"              "$out" "INCOMPLETE"

# --- #153 review round 4, P1: the post-close proof binds the PR NUMBER ------
# The claim inventory only lists a PR while that PR carries a well-formed
# claim marker. So "the claim id is gone" is satisfied BOTH by a PR that
# really closed and by a PR that is still wide open with its marker deleted or
# rewritten — and the second is a silent false success: the issue is still
# held by a live PR while the run reports the claim released and strips
# agent-claimed. Each fixture below is the proven-clean success path above
# with exactly one thing changed, so the ONLY reason it must not succeed is
# the PR-number binding.
echo "#153 round 4 · close reports success but the PR is STILL OPEN under a REWRITTEN marker"
open_fixture opennum1 425 marker-rewritten
open_row 926 issue-425-marker-rewritten 'lib/x/**' feat/425-marker-rewritten > "$GH_PR_OPEN_TSV"
NUM1_SHA=$(git -C "$ROOT/opennum1/wt-425-marker-rewritten" rev-parse HEAD)
git -C "$ROOT/opennum1/canon" worktree remove --force "$ROOT/opennum1/wt-425-marker-rewritten" >/dev/null 2>&1
git -C "$ROOT/opennum1/canon" branch -D feat/425-marker-rewritten >/dev/null 2>&1
git -C "$ROOT/opennum1/canon" push -q origin --delete feat/425-marker-rewritten >/dev/null 2>&1
printf '926\tissue-425-marker-rewritten\tlib/x/**\t425\tfeat/425-marker-rewritten\t%s\thttps://github.com/acme/app/pull/926\tCLOSED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$NUM1_SHA" > "$GH_PR_ALL_TSV"
# Post-close the claim id is gone from the inventory — but PR #926 is right
# there, still open, now carrying somebody else's claim id.
export GH_PR_OPEN_TSV2="$ROOT/opennum1/open2.tsv"
open_row 926 issue-888-rewritten-marker 'lib/z/**' feat/888-rewritten-marker > "$GH_PR_OPEN_TSV2"
# gh reported the close as a success and it was a LIE: #926 never left the
# open set. The fake's default open-number derivation removes a number once
# `gh pr close` succeeds on it, so a fixture modelling a lying close has to say
# so outright (#153 review round 5).
export GH_PR_OPEN_NUMBERS="926"
out=$(cd "$ROOT/opennum1/canon" && "$RC" 425 --claim-id issue-425-marker-rewritten --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_NUMBERS
check    "a rewritten marker on a still-open PR exits 3" "$rc" "3"
contains "names the PR that is still open"   "$out" "#926 is STILL OPEN"
contains "reports INCOMPLETE"                "$out" "INCOMPLETE"
lacks    "never reports success"             "$out" "OK —"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "rewritten marker: label never removed" || bad "rewritten marker: label removal was attempted"

echo "#153 round 4 · close reports success but the PR is STILL OPEN with its marker REMOVED (invisible to the claim inventory)"
open_fixture opennum2 426 marker-removed
open_row 927 issue-426-marker-removed 'lib/x/**' feat/426-marker-removed > "$GH_PR_OPEN_TSV"
NUM2_SHA=$(git -C "$ROOT/opennum2/wt-426-marker-removed" rev-parse HEAD)
git -C "$ROOT/opennum2/canon" worktree remove --force "$ROOT/opennum2/wt-426-marker-removed" >/dev/null 2>&1
git -C "$ROOT/opennum2/canon" branch -D feat/426-marker-removed >/dev/null 2>&1
git -C "$ROOT/opennum2/canon" push -q origin --delete feat/426-marker-removed >/dev/null 2>&1
printf '927\tissue-426-marker-removed\tlib/x/**\t426\tfeat/426-marker-removed\t%s\thttps://github.com/acme/app/pull/927\tCLOSED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$NUM2_SHA" > "$GH_PR_ALL_TSV"
export GH_PR_OPEN_TSV2="$ROOT/opennum2/open2.tsv"
: > "$GH_PR_OPEN_TSV2"          # the CLAIM inventory sees nothing at all…
export GH_PR_OPEN_NUMBERS="927" # …but the PR is still open. Only the
                                # body-agnostic inventory can see that.
out=$(cd "$ROOT/opennum2/canon" && "$RC" 426 --claim-id issue-426-marker-removed --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_NUMBERS
check    "a removed marker on a still-open PR exits 3" "$rc" "3"
contains "names the PR that is still open"   "$out" "#927 is STILL OPEN"
contains "names the removed/rewritten marker" "$out" "removed or rewritten marker is not a terminal PR"
contains "reports INCOMPLETE"                "$out" "INCOMPLETE"
lacks    "never reports success"             "$out" "OK —"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "removed marker: label never removed" || bad "removed marker: label removal was attempted"

echo "#153 round 4 · an UNREADABLE open-PR inventory is not proof the PR closed"
open_fixture opennum3 427 numbers-unreadable
open_row 928 issue-427-numbers-unreadable 'lib/x/**' feat/427-numbers-unreadable > "$GH_PR_OPEN_TSV"
NUM3_SHA=$(git -C "$ROOT/opennum3/wt-427-numbers-unreadable" rev-parse HEAD)
git -C "$ROOT/opennum3/canon" worktree remove --force "$ROOT/opennum3/wt-427-numbers-unreadable" >/dev/null 2>&1
git -C "$ROOT/opennum3/canon" branch -D feat/427-numbers-unreadable >/dev/null 2>&1
git -C "$ROOT/opennum3/canon" push -q origin --delete feat/427-numbers-unreadable >/dev/null 2>&1
printf '928\tissue-427-numbers-unreadable\tlib/x/**\t427\tfeat/427-numbers-unreadable\t%s\thttps://github.com/acme/app/pull/928\tCLOSED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$NUM3_SHA" > "$GH_PR_ALL_TSV"
export GH_PR_OPEN_TSV2="$ROOT/opennum3/open2.tsv"
: > "$GH_PR_OPEN_TSV2"
export GH_PR_OPEN_NUMBERS=""
export GH_PR_OPEN_NUMBERS_EXIT=1
out=$(cd "$ROOT/opennum3/canon" && "$RC" 427 --claim-id issue-427-numbers-unreadable --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_NUMBERS GH_PR_OPEN_NUMBERS_EXIT
check    "an unreadable open-PR inventory exits 3" "$rc" "3"
contains "names the unverifiable absence"    "$out" "cannot verify that PR #928 is absent from the open pull-request inventory"
contains "reports INCOMPLETE"                "$out" "INCOMPLETE"
lacks    "never reports success"             "$out" "OK —"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "unreadable open-PR inventory: label never removed" || bad "unreadable open-PR inventory: label removal was attempted"

echo "a claim still live on the post-close reread refuses success"
open_fixture openstill 405 still-live
open_row 906 issue-405-still-live 'lib/x/**' feat/405-still-live > "$GH_PR_OPEN_TSV"
git -C "$ROOT/openstill/canon" worktree remove --force "$ROOT/openstill/wt-405-still-live" >/dev/null 2>&1
git -C "$ROOT/openstill/canon" branch -D feat/405-still-live >/dev/null 2>&1
git -C "$ROOT/openstill/canon" push -q origin --delete feat/405-still-live >/dev/null 2>&1
# No GH_PR_OPEN_TSV2: the post-close read still reports the claim as live —
# gh said the close worked, GitHub says otherwise. Believe the reread.
out=$(cd "$ROOT/openstill/canon" && "$RC" 405 --claim-id issue-405-still-live --repo acme/app 2>&1); rc=$?
check    "still-live claim exits 3"       "$rc" "3"
contains "names the still-live claim"     "$out" "is STILL a live open PR-body claim"
lacks    "does not claim success"         "$out" "OK —"
contains "preserves the label"            "$out" "preserving agent-claimed"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "still-live case: label was never removed" || bad "still-live case: label removal was attempted"

echo "a failed post-close reread refuses success (never assumes the close worked)"
open_fixture openrrfail 406 reread-fail
open_row 907 issue-406-reread-fail 'lib/x/**' feat/406-reread-fail > "$GH_PR_OPEN_TSV"
git -C "$ROOT/openrrfail/canon" worktree remove --force "$ROOT/openrrfail/wt-406-reread-fail" >/dev/null 2>&1
git -C "$ROOT/openrrfail/canon" branch -D feat/406-reread-fail >/dev/null 2>&1
git -C "$ROOT/openrrfail/canon" push -q origin --delete feat/406-reread-fail >/dev/null 2>&1
export GH_PR_OPEN_TSV2="$ROOT/openrrfail/open2.tsv"
: > "$GH_PR_OPEN_TSV2"
export GH_PR_OPEN_EXIT2=1
out=$(cd "$ROOT/openrrfail/canon" && "$RC" 406 --claim-id issue-406-reread-fail --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_EXIT2
check    "post-close reread failure exits 3" "$rc" "3"
contains "names the reread failure"          "$out" "post-close reread of live PR-body claims failed"
lacks    "does not claim success"            "$out" "OK —"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "reread-failure case: label was never removed" || bad "reread-failure case: label removal was attempted"

echo "sibling policy is preserved and verified: a surviving live slice keeps agent-claimed"
open_fixture opensib 407 slice-a
open_row 908 issue-407-slice-a 'lib/a/**' feat/407-slice-a  > "$GH_PR_OPEN_TSV"
open_row 909 issue-407-slice-b 'lib/b/**' feat/407-slice-b >> "$GH_PR_OPEN_TSV"
SIB_SHA=$(git -C "$ROOT/opensib/wt-407-slice-a" rev-parse HEAD)
git -C "$ROOT/opensib/canon" worktree remove --force "$ROOT/opensib/wt-407-slice-a" >/dev/null 2>&1
git -C "$ROOT/opensib/canon" branch -D feat/407-slice-a >/dev/null 2>&1
git -C "$ROOT/opensib/canon" push -q origin --delete feat/407-slice-a >/dev/null 2>&1
# Post-close: slice-a is gone, slice-b is still working the same issue.
export GH_PR_OPEN_TSV2="$ROOT/opensib/open2.tsv"
open_row 909 issue-407-slice-b 'lib/b/**' feat/407-slice-b > "$GH_PR_OPEN_TSV2"
# Terminal evidence for the closed slice, so the run reaches the verified
# cleanup rather than the close-only INCOMPLETE path (#153 review round 4):
# sibling policy is a SUCCESS-path contract, and it has to be exercised on the
# path that can actually succeed.
printf '908\tissue-407-slice-a\tlib/a/**\t407\tfeat/407-slice-a\t%s\thttps://github.com/acme/app/pull/908\tCLOSED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$SIB_SHA" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/opensib/canon" && "$RC" 407 --claim-id issue-407-slice-a --repo acme/app 2>&1); rc=$?
check    "sibling-preserving release exits 0" "$rc" "0"
contains "keeps the label for the sibling"    "$out" "keeping agent-claimed on #407"
contains "names the surviving sibling"        "$out" "issue-407-slice-b"
contains "says the preservation was verified" "$out" "verified"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "sibling case: label was never removed" || bad "sibling case: label removal was attempted"

echo "multiple live slices without --claim-id still refuse"
open_fixture openambig 408 slice-a
open_row 910 issue-408-slice-a 'lib/a/**' feat/408-slice-a  > "$GH_PR_OPEN_TSV"
open_row 911 issue-408-slice-b 'lib/b/**' feat/408-slice-b >> "$GH_PR_OPEN_TSV"
out=$(cd "$ROOT/openambig/canon" && "$RC" 408 --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "multi-slice bare release refuses" || bad "multi-slice bare release exits 0: $out"
contains "names the ambiguity" "$out" "multiple live PR claims"
[[ -z "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "multi-slice case: no PR was closed" || bad "multi-slice case: a PR was closed anyway"

echo "dry-run closes nothing and says plainly that it will not clean up"
open_fixture opendry 409 dry-case
open_row 912 issue-409-dry-case 'lib/x/**' feat/409-dry-case > "$GH_PR_OPEN_TSV"
out=$(cd "$ROOT/opendry/canon" && "$RC" 409 --claim-id issue-409-dry-case --repo acme/app --dry-run 2>&1); rc=$?
check    "dry-run exits 0"                  "$rc" "0"
contains "dry-run names the close"          "$out" "would close PR #912"
contains "dry-run names the exact cleanup"  "$out" "run the exact cleanup"
[[ -z "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "dry-run closed nothing" || bad "dry-run closed a PR"
[[ -d "$ROOT/opendry/wt-409-dry-case" ]] &&
  ok "dry-run left the worktree" || bad "dry-run removed the worktree"

echo "a failed gh pr close refuses — the claim is still live and nothing else moved"
open_fixture openclosefail 410 close-fail
open_row 913 issue-410-close-fail 'lib/x/**' feat/410-close-fail > "$GH_PR_OPEN_TSV"
export GH_PR_CLOSE_EXIT=1
out=$(cd "$ROOT/openclosefail/canon" && "$RC" 410 --claim-id issue-410-close-fail --repo acme/app 2>&1); rc=$?
unset GH_PR_CLOSE_EXIT
[[ "$rc" -ne 0 ]] && ok "failed close exits nonzero" || bad "failed close exits 0: $out"
contains "names the failed close"  "$out" "gh pr close failed"
lacks    "does not claim success"  "$out" "OK —"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "failed close: label was never removed" || bad "failed close: label removal was attempted"
[[ -d "$ROOT/openclosefail/wt-410-close-fail" ]] &&
  ok "failed close: worktree untouched" || bad "failed close: worktree removed"

unset GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2 GH_OPEN_CALLS GH_PR_CLOSE_LOG GH_PR_CLOSE_EXIT

echo "#153 · full lifecycle fixture: reservation -> draft PR-body claim -> terminal PR -> exact-ID release -> verified cleanup"
CLAIM="$SCRIPT_DIR/../claim.sh"
new_repo "$ROOT/e2e" acme/e2e
mkdir -p "$ROOT/e2e/bin"
export GH_PR_FILE="$ROOT/e2e/prs"
: > "$GH_PR_FILE"
cat > "$ROOT/e2e/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo "acme/e2e" ;;
  "issue view") cat "${GH_LABELS_FILE:-/dev/null}" 2>/dev/null || echo "" ;;
  "issue edit")
    if echo "$*" | grep -q -- '--add-label'; then
      echo "agent-claimed" > "${GH_LABELS_FILE:-/dev/null}"
    elif echo "$*" | grep -q -- '--remove-label'; then
      : > "${GH_LABELS_FILE:-/dev/null}"
    fi
    ;;
  "api graphql")
    # pr-claims.sh's paginated GraphQL read. `list` restricts to
    # `states: [OPEN]`; `find-terminal` walks every state.
    # `list-open-numbers` (body-agnostic open PR numbers) also carries
    # `states: [OPEN]`, so it has to be matched FIRST by its named operation.
    for arg in "$@"; do
      case "$arg" in
        *"openPrNumbers"*)
          [[ "${GH_PR_MERGED:-0}" == 1 ]] && exit 0
          cut -d'|' -f1 "${GH_PR_FILE:-/dev/null}" 2>/dev/null | grep -E '^[0-9]+$' || true
          exit 0
          ;;
      esac
    done
    for arg in "$@"; do
      case "$arg" in
        *"states: [OPEN]"*)
          # Live-open inventory. While the reservation PR is open it MUST be
          # listed here: claim.sh's post-create admission pass refuses a claim
          # it cannot see in the authoritative inventory (#153 review P1).
          # GH_PR_MERGED=1 is step 3 — the PR reaching a terminal state and
          # dropping out of the open listing.
          [[ "${GH_PR_MERGED:-0}" == 1 ]] && exit 0
          while IFS='|' read -r number claim scope branch url created updated headsha; do
            [[ -n "$claim" ]] || continue
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tfalse\n' \
              "$number" "$claim" "$scope" "$branch" "$url" "$created" "$updated"
          done < "${GH_PR_FILE:-/dev/null}"
          exit 0
          ;;
      esac
    done
    # Reservation PR has already merged: absent from OPEN, present as MERGED,
    # with GitHub's own reported head SHA — the real tip of the pushed branch.
    while IFS='|' read -r number claim scope branch url created updated headsha; do
      [[ -n "$claim" ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$number" "$claim" "$scope" "200" "$branch" "$headsha" "$url" \
        "MERGED" "false" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "acme/e2e" "$created" "$updated"
    done < "${GH_PR_FILE:-/dev/null}"
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
    number="${GH_PR_NEXT:-1}"
    export GH_PR_NEXT=$((number + 1))
    claim=$(sed -n 's/^- Active-work claim: //p' "$body_file")
    scope=$(sed -n 's/^- Claim scope: //p' "$body_file")
    headsha=$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
    printf '%s|%s|%s|%s|https://github.com/acme/e2e/pull/%s|2026-08-09T00:00:00Z|2026-08-09T00:00:00Z|%s\n' \
      "$number" "$claim" "$scope" "$branch" "$number" "$headsha" >> "${GH_PR_FILE:-/dev/null}"
    echo "https://github.com/acme/e2e/pull/$number"
    ;;
  *)
    echo "fake gh (e2e fixture): unmodelled invocation 'gh $*' — refusing rather than answering a query this fixture does not model" >&2
    exit 64
    ;;
esac
exit 0
FAKE
chmod +x "$ROOT/e2e/bin/gh"
export PATH="$ROOT/e2e/bin:$PATH"
export GH_PR_NEXT=1
export GH_LABELS_FILE="$ROOT/e2e/labels"
: > "$GH_LABELS_FILE"

# Step 1+2: empty reservation commit + draft PR-body claim, via the real claim.sh.
out=$(cd "$ROOT/e2e/canon" && GIBSON_CANONICAL="$ROOT/e2e/canon" "$CLAIM" 200 checkout-fix 'lib/checkout/**' 2>&1); rc=$?
check    "e2e: claim.sh reserves the issue and opens the draft PR" "$rc" "0"
contains "e2e: claim label added"     "$(cat "$GH_LABELS_FILE")" "agent-claimed"
contains "e2e: draft PR carries the claim" "$(cat "$GH_PR_FILE")" "issue-200-checkout-fix"
[[ -d "$ROOT/e2e/wt-200-checkout-fix" ]] && ok "e2e: worktree created" || bad "e2e: worktree missing"

# Step 3: reservation PR reaches a terminal state (merged) — it drops out of
# the live-open inventory and becomes terminal evidence:
export GH_PR_MERGED=1
# nothing more to simulate here: the fake gh's --state all branch already reports MERGED for
# every row still in GH_PR_FILE (with the real pushed head SHA), and pr list
# --state open only lists PRs this fixture never puts there, matching a real
# merged/closed PR falling out of the open listing.

# Step 4: exact-ID release after the terminal PR, with no ledger row at all.
out=$(cd "$ROOT/e2e/canon" && "$RC" 200 --claim-id issue-200-checkout-fix --repo acme/e2e 2>&1); rc=$?
check    "e2e: exact-ID release exits 0"        "$rc" "0"
contains "e2e: release used the terminal claim" "$out" "verified terminal PR-body claim"

# Step 5: verified cleanup — exact worktree, exact local/remote branch, label.
[[ ! -d "$ROOT/e2e/wt-200-checkout-fix" ]] &&
  ok "e2e: worktree removed" || bad "e2e: worktree survived release"
br=$(git -C "$ROOT/e2e/canon" branch --list 'feat/200-checkout-fix')
[[ -z "$br" ]] && ok "e2e: local branch removed" || bad "e2e: local branch survived release"
remote_br=$(git -C "$ROOT/e2e/canon" ls-remote --heads origin 'feat/200-checkout-fix')
[[ -z "$remote_br" ]] && ok "e2e: remote branch removed" || bad "e2e: remote branch survived release"
lacks "e2e: label file no longer carries agent-claimed" "$(cat "$GH_LABELS_FILE")" "agent-claimed"

# ---------------------------------------------------------------------------
# #153 review P1 · repository binding: PR evidence must come from THIS
# checkout's own repository. A fork or second clone contains the same branch
# names and the same commits by construction — that is not identity, and it
# must never authorize deleting a worktree, a branch, or a label.
echo "#153 review · repository binding for PR-body evidence"
export PATH="$ROOT/term/bin:$PATH"

bind_fixture() { # dir issue slug [https|ssh]
  local dir="$1" issue="$2" slug="$3" form="${4:-https}"
  BIND_SHA=$(term_fixture "$dir" "$issue" "$slug" "$form")
  export GH_PR_ALL_TSV="$ROOT/$dir/all.tsv"
  export GH_PR_OPEN_TSV="$ROOT/$dir/open.tsv"
  : > "$GH_PR_OPEN_TSV"
  export GH_PR_CLOSED_NUMBERS="$ROOT/$dir/closed-numbers"
  : > "$GH_PR_CLOSED_NUMBERS"
  export GH_STATE="$ROOT/$dir/gh-state"
  export GH_LOG="$ROOT/$dir/gh.log"
  export GH_PR_CLOSE_LOG="$ROOT/$dir/close.log"
  export GH_LABELS="agent-claimed,tier-b"
  rm -f "$GH_STATE" "$GH_LOG" "$GH_PR_CLOSE_LOG"
  unset GH_PR_LIST_EXIT GH_PR_ALL_EXIT GH_PR_OPEN_EXIT GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2 GH_PR_CLOSE_EXIT GH_OPEN_CALLS
  unset GH_PR_OPEN_NUMBERS GH_PR_OPEN_NUMBERS_EXIT
  printf '600\tissue-%s-%s\tlib/x/**\t%s\tfeat/%s-%s\t%s\thttps://github.com/acme/app/pull/600\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
    "$issue" "$slug" "$issue" "$issue" "$slug" "$BIND_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
}

echo "origin-URL normalization covers every form a real clone carries"
# Table-driven, against the REAL function lifted out of release-claim.sh, so
# the parser that decides repository identity is tested directly rather than
# only through the two URL forms the fixtures happen to use.
sed -n '/^normalize_github_repo_url() {/,/^}/p' "$RC" > "$ROOT/normalize.inc"
# shellcheck disable=SC1090,SC1091
. "$ROOT/normalize.inc"
norm_case() { # url expected ("<refused>" for a URL with no GitHub identity)
  local got
  got=$(normalize_github_repo_url "$1" 2>/dev/null) || got="<refused>"
  check "normalize: $1" "$got" "$2"
}
norm_case "https://github.com/acme/app.git"           "acme/app"
norm_case "https://github.com/acme/app"               "acme/app"
norm_case "https://github.com/acme/app/"              "acme/app"
norm_case "https://GitHub.com/acme/app.git"           "acme/app"
norm_case "https://token@github.com/acme/app.git"     "acme/app"
norm_case "git@github.com:acme/app.git"               "acme/app"
norm_case "git@github.com:acme/app"                   "acme/app"
norm_case "ssh://git@github.com/acme/app.git"         "acme/app"
norm_case "ssh://git@github.com:22/acme/app.git"      "acme/app"
norm_case "ssh://git@ssh.github.com:443/acme/app.git" "acme/app"
norm_case "git://github.com/acme/app.git"             "acme/app"
# Anything that is not unambiguously one github.com repository is refused —
# a half-parsed identity would be worse than no identity at all.
norm_case "https://gitlab.com/acme/app.git"           "<refused>"
norm_case "git@gitlab.com:acme/app.git"               "<refused>"
norm_case "https://github.evil.com/acme/app.git"      "<refused>"
norm_case "https://github.com/acme"                   "<refused>"
norm_case "https://github.com/acme/app/extra"         "<refused>"
norm_case "/tmp/some/bare/origin"                     "<refused>"
norm_case ""                                          "<refused>"

echo "an SSH-form origin (git@github.com:owner/name.git) binds and releases"
bind_fixture bindssh 700 ssh-form ssh
out=$(cd "$ROOT/bindssh/canon" && "$RC" 700 --claim-id issue-700-ssh-form --repo acme/app 2>&1); rc=$?
check    "ssh-origin release exits 0"   "$rc" "0"
contains "ssh-origin release completed" "$out" "OK — claim released for issue 700"
[[ ! -d "$ROOT/bindssh/wt-700-ssh-form" ]] &&
  ok "ssh-origin release removed the worktree" || bad "ssh-origin release left the worktree"

echo "a MISMATCHED repository refuses the terminal path and mutates nothing"
bind_fixture bindmis 701 mismatch
# Same claim id, same branch, same commits — but the evidence is served for a
# different repository. That is exactly what a fork looks like.
sed 's|acme/app|other-org/app|g' "$GH_PR_ALL_TSV" > "$ROOT/bindmis/all-fork.tsv"
mv "$ROOT/bindmis/all-fork.tsv" "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/bindmis/canon" && "$RC" 701 --claim-id issue-701-mismatch --repo other-org/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "foreign-repository evidence exits nonzero" || bad "foreign-repository evidence exits 0: $out"
contains "names the binding mismatch"   "$out" "repository binding mismatch"
contains "names the fork reasoning"     "$out" "NOT the same repository"
lacks    "never reports success"        "$out" "OK —"
[[ -d "$ROOT/bindmis/wt-701-mismatch" ]] &&
  ok "binding mismatch: worktree untouched" || bad "binding mismatch: worktree removed"
[[ -n "$(git -C "$ROOT/bindmis/canon" branch --list 'feat/701-mismatch')" ]] &&
  ok "binding mismatch: local branch untouched" || bad "binding mismatch: local branch deleted"
[[ -n "$(git -C "$ROOT/bindmis/canon" ls-remote --heads origin 'feat/701-mismatch')" ]] &&
  ok "binding mismatch: remote branch untouched" || bad "binding mismatch: remote branch deleted"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "binding mismatch: label never edited" || bad "binding mismatch: label was edited"
table=$(git -C "$ROOT/bindmis/canon" show origin/main:docs/active-work.md)
contains "binding mismatch: ledger untouched" "$table" "issue-15-checkout-totals"

echo "a MISMATCHED repository refuses the open-PR path BEFORE closing anything"
bind_fixture bindopen 702 open-mismatch
open_row 601 issue-702-open-mismatch 'lib/x/**' feat/702-open-mismatch \
  | sed 's|github.com/acme/app|github.com/other-org/app|' > "$GH_PR_OPEN_TSV"
out=$(cd "$ROOT/bindopen/canon" && "$RC" 702 --claim-id issue-702-open-mismatch --repo other-org/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "open-path binding mismatch exits nonzero" || bad "open-path binding mismatch exits 0: $out"
contains "open path names the binding mismatch" "$out" "repository binding mismatch"
[[ -z "$(cat "$GH_PR_CLOSE_LOG" 2>/dev/null)" ]] &&
  ok "open-path binding mismatch: no PR was closed" || bad "open-path binding mismatch: a PR was closed"
[[ -d "$ROOT/bindopen/wt-702-open-mismatch" ]] &&
  ok "open-path binding mismatch: worktree untouched" || bad "open-path binding mismatch: worktree removed"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "open-path binding mismatch: label never edited" || bad "open-path binding mismatch: label was edited"

echo "even --dry-run reports the binding mismatch instead of planning a close"
bind_fixture binddry 703 dry-mismatch
open_row 602 issue-703-dry-mismatch 'lib/x/**' feat/703-dry-mismatch \
  | sed 's|github.com/acme/app|github.com/other-org/app|' > "$GH_PR_OPEN_TSV"
out=$(cd "$ROOT/binddry/canon" && "$RC" 703 --claim-id issue-703-dry-mismatch --repo other-org/app --dry-run 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "dry-run binding mismatch exits nonzero" || bad "dry-run binding mismatch exits 0: $out"
contains "dry-run names the binding mismatch" "$out" "repository binding mismatch"
lacks    "dry-run plans no close"             "$out" "would close PR"

echo "a checkout with NO origin remote cannot bind, and refuses"
bind_fixture bindnoorigin 704 no-origin
git -C "$ROOT/bindnoorigin/canon" remote remove origin
out=$(cd "$ROOT/bindnoorigin/canon" && "$RC" 704 --claim-id issue-704-no-origin --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "origin-less checkout exits nonzero" || bad "origin-less checkout exits 0: $out"
contains "names the unreadable origin identity" "$out" "no readable origin remote"
[[ -d "$ROOT/bindnoorigin/wt-704-no-origin" ]] &&
  ok "origin-less checkout: worktree untouched" || bad "origin-less checkout: worktree removed"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "origin-less checkout: label never edited" || bad "origin-less checkout: label was edited"

echo "an origin configured more than once is ambiguous identity, not the last value"
bind_fixture bindmulti 705 multi-origin
# `git config --get` would silently answer with the LAST value here and look
# perfectly definite. Two configured repositories is not an identity.
git -C "$ROOT/bindmulti/canon" config --add remote.origin.url https://github.com/acme/app-fork.git
out=$(cd "$ROOT/bindmulti/canon" && "$RC" 705 --claim-id issue-705-multi-origin --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "multi-valued origin exits nonzero" || bad "multi-valued origin exits 0: $out"
contains "names the ambiguous origin" "$out" "configured 2 times"
[[ -d "$ROOT/bindmulti/wt-705-multi-origin" ]] &&
  ok "multi-valued origin: worktree untouched" || bad "multi-valued origin: worktree removed"

echo "a non-GitHub origin never consults PR-body evidence at all"
BIND_LOCAL_SHA=$(term_fixture bindlocal 706 local-origin)
export GH_PR_ALL_TSV="$ROOT/bindlocal/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/bindlocal/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_LOG="$ROOT/bindlocal/gh.log"
rm -f "$GH_LOG"
printf '607\tissue-706-local-origin\tlib/x/**\t706\tfeat/706-local-origin\t%s\thttps://github.com/acme/app/pull/607\tMERGED\tfalse\t%s\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$BIND_LOCAL_SHA" "$HEX40" > "$GH_PR_ALL_TSV"
git -C "$ROOT/bindlocal/canon" remote set-url origin "$ROOT/bindlocal/origin"
out=$(cd "$ROOT/bindlocal/canon" && "$RC" 706 --claim-id issue-706-local-origin --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "non-GitHub origin exits nonzero" || bad "non-GitHub origin exits 0: $out"
contains "explains why the evidence was not consulted" "$out" "no GitHub repository identity"
[[ -d "$ROOT/bindlocal/wt-706-local-origin" ]] &&
  ok "non-GitHub origin: worktree untouched" || bad "non-GitHub origin: worktree removed"

# ---------------------------------------------------------------------------
# #153 review P1 · repository identity is never swallowed. `gh repo view`
# failing used to leave PR_REPO empty, which SKIPPED the authoritative PR
# inventory entirely and went on to strip the ledger and clean up anyway.
echo "#153 review · unresolvable repository identity fails before any mutation"
new_repo "$ROOT/unresolved"
(
  cd "$ROOT/unresolved/canon" || exit 1
  git checkout -q main
  cat > docs/active-work.md <<'TABLE'
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-800-unresolved | src/a | session:a |
| 2026-08-01 | issue-801-bystander | src/b | session:b |
TABLE
  git add -A && git commit -qm "nonempty legacy ledger" && git push -q origin main
  git checkout -q long-lived-feature
) >/dev/null 2>&1
git -C "$ROOT/unresolved/canon" worktree add -q "$ROOT/unresolved/wt-800-unresolved" \
  -b feat/800-unresolved origin/main
(
  cd "$ROOT/unresolved/wt-800-unresolved" || exit 1
  git commit --allow-empty -qs -m "work"
  git push -q -u origin feat/800-unresolved
) >/dev/null 2>&1
# gh is installed and answers other calls, but cannot say which repository
# this is; the origin remote is gone too, so nothing can resolve it.
mkdir -p "$ROOT/unresolved/bin"
cat > "$ROOT/unresolved/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  repo) exit 1 ;;
  api) exit 0 ;;
  issue) echo "edited" >> "${GH_LOG:-/dev/null}"; exit 0 ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/unresolved/bin/gh"
git -C "$ROOT/unresolved/canon" remote remove origin
export GH_LOG="$ROOT/unresolved/gh.log"
rm -f "$GH_LOG"
out=$(cd "$ROOT/unresolved/canon" && PATH="$ROOT/unresolved/bin:$PATH" \
  "$RC" 800 --claim-id issue-800-unresolved 2>&1); rc=$?
check    "unresolved identity exits 1"                "$rc" "1"
contains "names the unresolved repository identity"   "$out" "cannot resolve the GitHub repository identity"
contains "tells the operator to pass --repo"          "$out" "--repo owner/name"
lacks    "never reports success"                      "$out" "OK —"
[[ -d "$ROOT/unresolved/wt-800-unresolved" ]] &&
  ok "unresolved identity: worktree untouched" || bad "unresolved identity: worktree removed"
[[ -n "$(git -C "$ROOT/unresolved/canon" branch --list 'feat/800-unresolved')" ]] &&
  ok "unresolved identity: local branch untouched" || bad "unresolved identity: local branch deleted"
[[ -n "$(git -C "$ROOT/unresolved/canon" ls-remote --heads "$ROOT/unresolved/origin" 'feat/800-unresolved')" ]] &&
  ok "unresolved identity: remote branch untouched" || bad "unresolved identity: remote branch deleted"
table=$(git -C "$ROOT/unresolved/canon" show main:docs/active-work.md)
contains "unresolved identity: target ledger row untouched"    "$table" "issue-800-unresolved"
contains "unresolved identity: bystander ledger row untouched" "$table" "issue-801-bystander"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "unresolved identity: label never edited" || bad "unresolved identity: label was edited"
unset GH_LOG

# ---------------------------------------------------------------------------
# #153 review P1 · the post-mutation sibling reread on the LEDGER path was
# `2>/dev/null || true`. An unreadable inventory then read as "no open sibling
# claims", and agent-claimed came off an issue another live lane still held.
echo "#153 review · ledger-path sibling reread is fail-closed"
export PATH="$ROOT/term/bin:$PATH"

sib_fixture() { # dir issue target-id sibling-row?
  local dir="$1" issue="$2" target="$3"
  new_repo "$ROOT/$dir" acme/app
  (
    cd "$ROOT/$dir/canon" || exit 1
    git checkout -q main
    printf '| when | claim-id | scope | who |\n|---|---|---|---|\n| 2026-08-01 | %s | src/a | session:a |\n' "$target" \
      > docs/active-work.md
    git add -A && git commit -qm "single target row" && git push -q origin main
    git checkout -q long-lived-feature
  ) >/dev/null 2>&1
  export GH_PR_OPEN_TSV="$ROOT/$dir/open.tsv"
  export GH_PR_ALL_TSV="$ROOT/$dir/all.tsv"
  : > "$GH_PR_OPEN_TSV"
  : > "$GH_PR_ALL_TSV"
  export GH_PR_CLOSED_NUMBERS="$ROOT/$dir/closed-numbers"
  : > "$GH_PR_CLOSED_NUMBERS"
  export GH_STATE="$ROOT/$dir/gh-state"
  export GH_LOG="$ROOT/$dir/gh.log"
  export GH_LABELS="agent-claimed,tier-b"
  export GH_OPEN_CALLS="$ROOT/$dir/open-calls"
  : > "$GH_OPEN_CALLS"
  rm -f "$GH_STATE" "$GH_LOG"
  unset GH_PR_LIST_EXIT GH_PR_ALL_EXIT GH_PR_OPEN_EXIT GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2 GH_PR_CLOSE_EXIT
  unset GH_PR_OPEN_NUMBERS GH_PR_OPEN_NUMBERS_EXIT
}

echo "an unreadable sibling reread preserves agent-claimed and reports INCOMPLETE"
sib_fixture sibfail 810 issue-810-ledger-lane
# Call 1 (the authoritative pre-mutation inventory) succeeds and is empty;
# call 2 — the post-mutation sibling reread — fails, as a rate limit or an
# expired token would.
export GH_PR_OPEN_TSV2="$ROOT/sibfail/open2.tsv"
: > "$GH_PR_OPEN_TSV2"
export GH_PR_OPEN_EXIT2=1
out=$(cd "$ROOT/sibfail/canon" && "$RC" 810 --claim-id issue-810-ledger-lane --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_EXIT2 GH_PR_OPEN_TSV2
check    "unreadable sibling reread exits 3"     "$rc" "3"
contains "names the unreadable inventory"        "$out" "an unreadable claim inventory is not an empty one"
contains "preserves the label"                   "$out" "preserving agent-claimed"
lacks    "never claims the label was removed"    "$out" "removed agent-claimed"
lacks    "never reports success"                 "$out" "OK —"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "unreadable sibling reread: label never edited" || bad "unreadable sibling reread: label was edited"

echo "a malformed sibling reread row preserves agent-claimed and reports INCOMPLETE"
sib_fixture sibmal 811 issue-811-ledger-lane
export GH_PR_OPEN_TSV2="$ROOT/sibmal/open2.tsv"
printf 'not-enough-fields\n' > "$GH_PR_OPEN_TSV2"
out=$(cd "$ROOT/sibmal/canon" && "$RC" 811 --claim-id issue-811-ledger-lane --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_TSV2
check    "malformed sibling reread exits 3" "$rc" "3"
contains "names the malformed row"          "$out" "malformed/truncated row"
contains "preserves the label"              "$out" "preserving agent-claimed"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "malformed sibling reread: label never edited" || bad "malformed sibling reread: label was edited"

echo "a surviving sibling whose agent-claimed label is ABSENT is INCOMPLETE, not success"
sib_fixture siblabel 812 issue-812-ledger-lane
export GH_PR_OPEN_TSV2="$ROOT/siblabel/open2.tsv"
open_row 620 issue-812-open-slice 'lib/b/**' feat/812-open-slice > "$GH_PR_OPEN_TSV2"
export GH_LABELS="tier-b"   # agent-claimed is missing while a sibling is live
out=$(cd "$ROOT/siblabel/canon" && "$RC" 812 --claim-id issue-812-ledger-lane --repo acme/app 2>&1); rc=$?
export GH_LABELS="agent-claimed,tier-b"
check    "missing label with a live sibling exits 3" "$rc" "3"
contains "names the absent label"                    "$out" "agent-claimed is ABSENT"
lacks    "never reports success"                     "$out" "OK —"

echo "a surviving sibling with the label present is verified, not assumed"
sib_fixture sibok 813 issue-813-ledger-lane
export GH_PR_OPEN_TSV2="$ROOT/sibok/open2.tsv"
open_row 621 issue-813-open-slice 'lib/b/**' feat/813-open-slice > "$GH_PR_OPEN_TSV2"
out=$(cd "$ROOT/sibok/canon" && "$RC" 813 --claim-id issue-813-ledger-lane --repo acme/app 2>&1); rc=$?
unset GH_PR_OPEN_TSV2
check    "verified sibling preservation exits 0" "$rc" "0"
contains "says the preservation was verified"    "$out" "residual claims remain (verified)"
contains "names the surviving sibling"           "$out" "issue-813-open-slice"
lacks    "never removes the label"               "$out" "removed agent-claimed"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "verified sibling: label never edited" || bad "verified sibling: label was edited"
table=$(git -C "$ROOT/sibok/canon" fetch -q origin && git -C "$ROOT/sibok/canon" show origin/main:docs/active-work.md)
lacks    "target ledger row was still released" "$table" "issue-813-ledger-lane"

# ---------------------------------------------------------------------------
# #153 review P2 · a reused claim id has more than one terminal PR. The
# id-only lookup must stay ambiguous; --pr asks the exact question instead.
echo "#153 review · --pr binds a terminal release to one exact PR"
TWO_GEN_SHA=$(term_fixture twogen 820 reused-id)
export GH_PR_ALL_TSV="$ROOT/twogen/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/twogen/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/twogen/gh-state"
export GH_LOG="$ROOT/twogen/gh.log"
export GH_LABELS="agent-claimed,tier-b"
rm -f "$GH_STATE" "$GH_LOG"
unset GH_PR_OPEN_TSV2 GH_PR_OPEN_EXIT2 GH_OPEN_CALLS
{
  # Generation 1: an older, already-released PR carrying the same claim id.
  printf '630\tissue-820-reused-id\tlib/gen1/**\t820\tfeat/820-reused-id\t%s\thttps://github.com/acme/app/pull/630\tMERGED\tfalse\t%s\tacme/app\t2026-07-01T00:00:00Z\t2026-07-02T00:00:00Z\n' \
    "$HEX40" "$HEX40"
  # Generation 2: the one actually being released now, at the real head SHA.
  printf '631\tissue-820-reused-id\tlib/gen2/**\t820\tfeat/820-reused-id\t%s\thttps://github.com/acme/app/pull/631\tCLOSED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
    "$TWO_GEN_SHA"
} > "$GH_PR_ALL_TSV"

out=$(cd "$ROOT/twogen/canon" && "$RC" 820 --claim-id issue-820-reused-id --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "two generations without --pr still refuse" || bad "two generations exited 0: $out"
contains "names the ambiguity"        "$out" "ambiguous"
contains "points at --pr"             "$out" "--pr <number>"
[[ -d "$ROOT/twogen/wt-820-reused-id" ]] &&
  ok "ambiguous reuse: worktree untouched" || bad "ambiguous reuse: worktree removed"
[[ -z "$(cat "$GH_LOG" 2>/dev/null)" ]] &&
  ok "ambiguous reuse: label never edited" || bad "ambiguous reuse: label was edited"

out=$(cd "$ROOT/twogen/canon" && "$RC" 820 --claim-id issue-820-reused-id --pr 631 --repo acme/app 2>&1); rc=$?
check    "--pr resolves the reuse and releases" "$rc" "0"
contains "used the named PR"                    "$out" "verified terminal PR-body claim #631"
contains "reports the release"                  "$out" "OK — claim released for issue 820"
[[ ! -d "$ROOT/twogen/wt-820-reused-id" ]] &&
  ok "--pr release removed the worktree" || bad "--pr release left the worktree"
[[ -z "$(git -C "$ROOT/twogen/canon" branch --list 'feat/820-reused-id')" ]] &&
  ok "--pr release removed the local branch" || bad "--pr release left the local branch"

echo "--pr never weakens an evidence check"
# The named PR's head SHA deliberately does not match this worktree, so the
# fixture's real HEAD is not needed here.
term_fixture twogen2 821 wrong-pr >/dev/null
export GH_PR_ALL_TSV="$ROOT/twogen2/all.tsv"
export GH_PR_OPEN_TSV="$ROOT/twogen2/open.tsv"
: > "$GH_PR_OPEN_TSV"
export GH_STATE="$ROOT/twogen2/gh-state"
export GH_LOG="$ROOT/twogen2/gh.log"
rm -f "$GH_STATE" "$GH_LOG"
# The named PR carries the right claim id but the WRONG head SHA — pointing at
# a PR does not make its evidence match this worktree.
printf '640\tissue-821-wrong-pr\tlib/x/**\t821\tfeat/821-wrong-pr\t%s\thttps://github.com/acme/app/pull/640\tCLOSED\tfalse\t\tacme/app\t2026-08-05T00:00:00Z\t2026-08-06T00:00:00Z\n' \
  "$HEX40" > "$GH_PR_ALL_TSV"
out=$(cd "$ROOT/twogen2/canon" && "$RC" 821 --claim-id issue-821-wrong-pr --pr 640 --repo acme/app 2>&1); rc=$?
check    "--pr with mismatched head SHA exits 3" "$rc" "3"
contains "names the head-SHA refusal"            "$out" "nor provably contained in the merged result"
[[ -d "$ROOT/twogen2/wt-821-wrong-pr" ]] &&
  ok "--pr mismatch: worktree untouched" || bad "--pr mismatch: worktree removed"

out=$(cd "$ROOT/twogen2/canon" && "$RC" 821 --claim-id issue-821-wrong-pr --pr 999 --repo acme/app 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "--pr naming an unknown PR refuses" || bad "--pr with an unknown PR exited 0: $out"
contains "names the missing evidence" "$out" "no live claim"
out=$(cd "$ROOT/twogen2/canon" && "$RC" 821 --pr 640 --repo acme/app 2>&1); rc=$?
check    "--pr without --claim-id exits 1" "$rc" "1"
contains "names the --claim-id requirement" "$out" "pass --claim-id too"
out=$(cd "$ROOT/twogen2/canon" && "$RC" 821 --claim-id issue-821-wrong-pr --pr abc --repo acme/app 2>&1); rc=$?
check    "--pr with a non-numeric value exits 1" "$rc" "1"
contains "names the numeric requirement"         "$out" "must be a pull-request number"

echo
echo "release-claim.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
