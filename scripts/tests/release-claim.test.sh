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

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
RC="$SCRIPT_DIR/../release-claim.sh"
PASS=0
FAIL=0

ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

# A canonical checkout parked on a dirty long-lived branch — the L-009 shape.
new_repo() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root"
  git init -q --bare "$root/origin"
  git clone -q "$root/origin" "$root/canon" 2>/dev/null
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

echo
echo "release-claim.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
