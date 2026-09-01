#!/usr/bin/env bash
# release-claim.sh — post-merge cleanup (docs/05, Law 10)
set -euo pipefail

usage() {
  cat <<'EOF'
release-claim.sh — release a claim after merge (cleanup)

WHAT IT DOES
  Finds the claim row for an issue, deletes the claim row with a signed commit
  on main, removes the agent-claimed label, and removes the git worktree and
  local branch when requested.

  Worktree/branch removal is always deferred until ledger mutation is pushed
  and an authoritative post-mutation reread plus PR+ledger union revalidation
  prove the exact target claim is absent. A renewal race, push rejection,
  late-open PR, second ledger representation, or OID mismatch leaves the
  registered worktree and branch untouched and exits incomplete (rc=3).
  Artifact deletion never uses rm -rf, worktree remove --force, branch -D,
  or unleased remote delete.

  It never moves the canonical checkout off its current branch: the claim-row
  commit happens in a disposable worktree on main (L-009). Sibling claims on the
  same issue survive unless you name them (L-024), and the label removal is
  verified rather than assumed (L-027).

REPOSITORY BINDING (#153 review)
  Any cleanup driven by PR-body evidence — closing the owning PR, removing its
  worktree, deleting its local/remote branch — first proves that
  GIBSON_CANONICAL's own origin remote IS the repository that evidence came
  from. The origin URL is normalized (https, ssh://, scp-like git@host:owner/
  name, optional port, optional .git, case-insensitive) to owner/name and
  compared to the resolved GitHub repository. A fork or a second clone that
  merely contains the same branch name and the same commits is NOT the same
  repository, and is refused before any mutation. A missing, unreadable,
  ambiguous (multi-valued or rewritten to a different GitHub repo), or
  non-GitHub origin is likewise refused for those paths rather than assumed.

  Repository identity itself is never guessed: if `gh repo view` cannot
  resolve it and no --repo was given, the origin identity is used; if that is
  unreadable too, the run fails BEFORE any worktree, branch, ledger, or label
  mutation rather than silently skipping the authoritative PR inventory.

CLOSING AN OPEN CLAIM PR (#153 review round 4/5)
  `gh pr close` is the first and only irreversible mutation on the open-claim
  path, so every identity check that authorizes it runs BEFORE it: the
  repository binding above, the head branch, and the PR's own repository
  identity. The PR's head branch must be exactly the branch its claim id
  derives (feat/<issue>-<slug>). An exact claim marker in the body of a PR on
  an unrelated branch is not authority to close that PR — the mismatch exits 1
  with nothing mutated, including under --dry-run.

  The claim inventory now carries `isCrossRepository` for every open claim, and
  the PR must be provably same-repository (`false`) before it is closed. Branch
  names are not namespaced across repositories, so a FORK PR can carry both an
  exact claim marker and a head branch named exactly like ours; marker plus
  branch is therefore not repository identity. `true`, an unreadable column, or
  a row that cannot say all count as UNSAFE and exit 1 with nothing mutated —
  absence of proof of a fork is not proof it is not one. (The terminal-evidence
  path has always refused cross-repository rows; this closes the OPEN path,
  which used to meet that refusal only after the PR was already closed.)

  After the close, the claim is released but nothing else is proven. The run
  re-reads that exact PR's own terminal evidence and hands over to the exact
  verified cleanup only if it binds. If the terminal evidence is unreadable,
  ambiguous, contradictory, or simply ABSENT, the run is close-only: worktree,
  both branch refs and agent-claimed all preserved, INCOMPLETE, exit 3, with a
  RECOVERY line naming the bound re-run. An absent terminal row after a close
  is not evidence that there is nothing left — it is evidence this run cannot
  see the PR it just closed. The close-only path therefore never removes
  agent-claimed; the only route to a verified label removal after a close is
  the terminal cleanup that proved the artifacts first.

  The proof binds the PR NUMBER as well as the claim id. The claim inventory
  only lists a PR while that PR carries a well-formed claim marker, so a PR
  that is still OPEN with its marker removed or rewritten drops out of that
  view and is indistinguishable from one that closed. A body-agnostic open-PR
  inventory (pr-claims.sh list-open-numbers) is consulted for the exact number.

  That proof is taken TWICE, and the first one is a GATE (#153 review round 5).
  Terminal cleanup asks it after the terminal evidence is bound and BEFORE the
  first destructive mutation: a still-open number, or an inventory it could not
  read, preserves the worktree, both branch refs, every ledger row and
  agent-claimed, and exits 3 — nothing is removed. The second, after cleanup,
  is the TOCTOU/postcondition half. The pre-mutation copy exists because the
  post-mutation one alone was a report rather than a gate: by the time it said
  "PR #N is still open", the work behind the still-open PR was already gone.

WHY
  Abandoned claims block the fleet (Law 10). Cleanup must be as automatic as claim.

RISKS
  - Deletes worktree directory (uncommitted work there is lost). Check first.
  - Commits to main (claim-row removal only), from a temporary worktree.
  - Removes GitHub label. Low risk; re-claim if you still need the issue.

USAGE
  release-claim.sh <issue> [--claim-id <id>] [--pr <number>] [--prefix <ns>]
                           [--repo owner/name]
                           [--keep-branch] [--keep-worktree] [--keep-label]
                           [--expected-claim-path PATH] [--expected-claim-blob OID]
                           [--expected-source file|legacy]
                           [--worktree-path PATH] [--expected-branch BRANCH]
                           [--dry-run]
  release-claim.sh --help

  <issue>        issue number, e.g. 42
  --claim-id     release exactly this claim id (e.g. issue-42-password-reset)
                 and leave every sibling row for the issue alone (L-024)
  --pr           release the claim bound to exactly this pull-request number.
                 A claim id becomes free again once its PR is terminal, so a
                 reused id can legitimately have MORE THAN ONE terminal PR —
                 which makes the id-only terminal lookup ambiguous forever
                 after the second generation. Naming the PR restores an exact
                 question without weakening any evidence check: that PR must
                 still match the claim id, the issue, the derived head branch,
                 the head SHA, the base repository, cross-repo=false and a
                 terminal state. Releasing a still-OPEN claim never needs this
                 flag — that path already knows its own PR number and binds to
                 it automatically.
  --prefix       namespace for cross-repo claim ids: --prefix template matches
                 issue-template-<N>-* as well as issue-<N>-* (L-036 / L-037)
  --repo         product repo for the issue/label, when the issue does not live
                 in the claim-table repo (L-037)
  --keep-branch  do not delete the local/remote feature branch
  --keep-worktree
                 do not remove the registered worktree directory (default still
                 removes it). Used by claim-reaper so a dead lane's claim can be
                 released while preserving the on-disk tree for recovery.
  --keep-label   keep agent-claimed even when the ledger has no residual row
                 for this issue (live sibling lane whose claim file is absent
                 or lives elsewhere). Verifies the live GitHub label is present
                 (exit 3 if the product repo is unresolved or the label is
                 absent/unreadable). Without this flag, a no-residual cleanup
                 removes the label — the final completed lane path.
  --expected-claim-path PATH
                 CAS: exact ledger path of the claim blob (e.g.
                 docs/claims/issue-42-x.md). Bound through fetch/cleanup/push.
  --expected-claim-blob OID
                 CAS: exact blob OID (or legacy "activeblob:claimid") that must
                 still match on the authoritative remote before any strip/push.
  --expected-source file|legacy
                 CAS: claim representation form; required with --expected-claim-blob.
  --worktree-path PATH
                 remove only this exact absolute registered worktree path (no
                 default-path derivation). Claimed prune from claim-reaper.
  --expected-branch BRANCH
                 when --worktree-path is set, the worktree must be checked out
                 on this branch before removal.
  --dry-run      print the exact registered worktree and branch live safety
                 checks would evaluate; touch nothing. Names identity and
                 pending revalidation; does not promise deletion.

  Matching: issue-<N>-* plus issue-<alpha-ns>-<N>-*. issue-1<N>-* never matches.
  Bare multi-claim: if more than one live claim exists for the issue and you
  did not pass --claim-id, the script refuses (exit 1) before any plan or
  mutation and prints the exact ids so you can pick one. A single live claim
  may still be released with the bare form; that exact id is frozen first.
  --claim-id is always a *literal* exact id (never an ERE/glob). It must
  belong to the positional issue (and --prefix when given). Legacy table
  rows are matched on the claim-id column only — text in scope/session/notes
  never selects or deletes a row.

  Empty ledger: when a *valid* ledger ref with a *readable* tree has no
  docs/claims/* and no docs/active-work.md tree entry, that is a valid empty
  ledger (no live claims), not a hard fail. A missing/unborn/invalid
  main|master ref, a commit whose referenced tree is unavailable/corrupt, or
  a ledger path that still exists in the tree but whose blob/object is
  unreadable/corrupt, is NOT an empty ledger — the script fails hard before
  any label mutation. True path absence is allowed; unreadable live blobs are
  not. Cleanup of worktrees/labels can still complete truthfully without
  inventing a row when the ref is valid, the tree is readable, and the ledger
  is empty.

ENV
  GIBSON_CANONICAL   claim-table repo path (default: cwd)

EXIT
  0  claim fully released (or truthfully nothing to release + label policy done)
  1  a hard precondition failed (nothing was cleaned)
  3  cleanup ran but did not finish: the claim row and/or the agent-claimed
     label postcondition is incomplete. Strip/push failure, a target still
     live after cleanup, or a failed/unreadable post-mutation reread preserves
     agent-claimed and never claims the label was removed. The message names
     which. Never silent half-cleanup (L-009).

EXAMPLES
  cd ~/Code/acme-app
  /path/to/the-gibson/scripts/release-claim.sh 42

  # multi-slice issue: release only the merged slice, keep the residual lane
  release-claim.sh 15 --claim-id issue-15-checkout-totals

  # empty ledger + live sibling still working the issue (no claim file on main)
  release-claim.sh 18 --repo acme/app --keep-label

  # empty ledger + final lane done: remove agent-claimed (default)
  release-claim.sh 18 --repo acme/app

  # cross-repo template work: claim row in the monorepo, issue in the template repo
  GIBSON_CANONICAL=~/Code/monorepo \
    release-claim.sh 5 --prefix template --repo acme/acme-template

  GIBSON_CANONICAL=~/Code/acme-app release-claim.sh 42 --dry-run
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
  exit 2
fi

ISSUE="$1"
shift || true
KEEP_BRANCH=0
KEEP_WORKTREE=0
KEEP_LABEL=0
DRY=0
CLAIM_ID_ARG=""
CLAIM_ID_SET=0
PR_NUMBER_ARG=""
PREFIX=""
REPO_ARG=""
EXPECTED_CLAIM_PATH=""
EXPECTED_CLAIM_BLOB=""
EXPECTED_SOURCE=""
WORKTREE_PATH_ARG=""
EXPECTED_BRANCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-branch) KEEP_BRANCH=1 ;;
    --keep-worktree) KEEP_WORKTREE=1 ;;
    --keep-label) KEEP_LABEL=1 ;;
    --dry-run) DRY=1 ;;
    --claim-id)
      CLAIM_ID_SET=1
      CLAIM_ID_ARG="${2:-}"
      shift
      ;;
    --pr) PR_NUMBER_ARG="${2:-}"; shift ;;
    --prefix) PREFIX="${2:-}"; shift ;;
    --repo) REPO_ARG="${2:-}"; shift ;;
    --expected-claim-path)
      EXPECTED_CLAIM_PATH="${2:-}"
      shift
      ;;
    --expected-claim-blob)
      EXPECTED_CLAIM_BLOB="${2:-}"
      shift
      ;;
    --expected-source)
      EXPECTED_SOURCE="${2:-}"
      shift
      ;;
    --worktree-path)
      WORKTREE_PATH_ARG="${2:-}"
      shift
      ;;
    --expected-branch)
      EXPECTED_BRANCH="${2:-}"
      shift
      ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

CANONICAL="${GIBSON_CANONICAL:-$(pwd)}"
die() { echo "release-claim.sh: ERROR: $*" >&2; exit 1; }
info() { echo "release-claim.sh: $*" >&2; }
warn() { echo "release-claim.sh: WARNING: $*" >&2; }

# Shared cleanup guards (#153 review P1 0D). The worktree enumeration and the
# exact remote-branch query below are the same code claim.sh's admission
# rollback runs, deliberately: when each path carried its own copy, a
# protection added to one silently did not exist in the other.
RELEASE_LIB_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/claim-guards.sh
. "$RELEASE_LIB_DIR/claim-guards.sh" ||
  die "cannot source $RELEASE_LIB_DIR/claim-guards.sh — refusing to run cleanup without its safety guards"

[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "issue must be a number, got '$ISSUE'"
if [[ -n "$PREFIX" && ! "$PREFIX" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]]; then
  die "--prefix must start with a letter, got '$PREFIX'"
fi
if [[ "$CLAIM_ID_SET" -eq 1 && -z "$CLAIM_ID_ARG" ]]; then
  die "--claim-id requires a non-empty literal claim id"
fi
if [[ -n "$PR_NUMBER_ARG" ]]; then
  [[ "$PR_NUMBER_ARG" =~ ^[0-9]+$ ]] || die "--pr must be a pull-request number, got '$PR_NUMBER_ARG'"
  [[ "$CLAIM_ID_SET" -eq 1 ]] || die "--pr names the PR for exactly one claim — pass --claim-id too"
fi
if [[ -n "$EXPECTED_CLAIM_BLOB" || -n "$EXPECTED_CLAIM_PATH" || -n "$EXPECTED_SOURCE" ]]; then
  [[ -n "$EXPECTED_CLAIM_BLOB" ]] || die "--expected-claim-blob is required when CAS expected-* flags are set"
  [[ -n "$EXPECTED_SOURCE" ]] || die "--expected-source is required with --expected-claim-blob"
  case "$EXPECTED_SOURCE" in
    file|legacy) ;;
    *) die "--expected-source must be 'file' or 'legacy'" ;;
  esac
  if [[ "$EXPECTED_SOURCE" == "file" ]]; then
    [[ -n "$EXPECTED_CLAIM_PATH" ]] || die "--expected-claim-path is required for --expected-source file"
    case "$EXPECTED_CLAIM_PATH" in
      docs/claims/*.md) ;;
      *) die "--expected-claim-path must be docs/claims/<id>.md; got '$EXPECTED_CLAIM_PATH'" ;;
    esac
  fi
  if [[ ! "$EXPECTED_CLAIM_BLOB" =~ ^[0-9a-f]{4,64}(:issue-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)?$ ]]; then
    die "--expected-claim-blob must be a hex blob OID (optionally :claim-id for legacy)"
  fi
fi
if [[ -n "$WORKTREE_PATH_ARG" ]]; then
  case "$WORKTREE_PATH_ARG" in
    /*) ;;
    *) die "--worktree-path must be an absolute path" ;;
  esac
  case "$WORKTREE_PATH_ARG" in
    *..*) die "--worktree-path must not contain '..'" ;;
  esac
fi
if [[ -n "$EXPECTED_BRANCH" && ! "$EXPECTED_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  die "--expected-branch has unsafe characters"
fi
# A retained worktree cannot lose its branch (#153 blocker 4, #271). Live
# terminal cleanup already refuses this combination as incomplete (rc=3).
# Dry-run must fail closed before printing an impossible keep-worktree /
# delete-branch plan rather than previewing a mutation live would reject.
if [[ "$DRY" -eq 1 && "$KEEP_WORKTREE" -eq 1 && "$KEEP_BRANCH" -eq 0 ]]; then
  die "--keep-worktree without --keep-branch would retain a worktree after deleting its branch — refuse (a retained worktree must not lose its branch)"
fi

cd "$CANONICAL"
WT_PARENT="$(cd "$CANONICAL/.." && pwd)"
# (#153 blocker 1) There is deliberately no pr_wt_dir_for() any more. Deriving
# a worktree path from a claim id is a guess, and the open-PR release path
# used that guess to drive `git worktree remove --force`. Worktree identity is
# resolved from `git worktree list --porcelain` by exact branch, or not at all.

# Physical path for comparison (macOS /var vs /private/var). Defined this
# early so every registered-worktree check in the file — including the
# open-PR-body release path just below — uses the same canonicalized
# comparison; a bare string match here is exactly how a real registered
# worktree was once misclassified as "unregistered" and fell through to a
# destructive rm -rf fallback.
phys_path() {
  local p="$1" dir base
  p="${p%/}"
  [[ -n "$p" ]] || { echo ""; return 0; }
  if [[ -d "$p" && ! -L "$p" ]]; then
    (CDPATH='' cd "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"
    return 0
  fi
  dir=$(dirname -- "$p" 2>/dev/null || echo ".")
  base=$(basename -- "$p" 2>/dev/null || echo "$p")
  if [[ -d "$dir" ]]; then
    printf '%s/%s\n' "$(CDPATH='' cd "$dir" 2>/dev/null && pwd -P)" "$base"
  else
    printf '%s\n' "$p"
  fi
}

# Is path a registered git worktree of CANONICAL?
worktree_registered() {
  local want="$1" line cur="" want_phys cur_phys
  want="${want%/}"
  want_phys=$(phys_path "$want")
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        cur="${line#worktree }"
        cur="${cur%/}"
        if [[ "$cur" == "$want" ]]; then
          return 0
        fi
        cur_phys=$(phys_path "$cur")
        if [[ -n "$want_phys" && -n "$cur_phys" && "$cur_phys" == "$want_phys" ]]; then
          return 0
        fi
        ;;
    esac
  done <<EOF
$(git worktree list --porcelain 2>/dev/null || true)
EOF
  return 1
}

# Registered worktree path's checked-out branch (porcelain), empty if detached/unknown.
worktree_branch() {
  local want="$1" line cur="" branch="" want_phys cur_phys
  want="${want%/}"
  want_phys=$(phys_path "$want")
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        cur="${line#worktree }"
        cur="${cur%/}"
        branch=""
        ;;
      branch\ *)
        branch="${line#branch }"
        # refs/heads/foo → foo
        branch="${branch#refs/heads/}"
        ;;
      "")
        if [[ -n "$cur" ]]; then
          if [[ "$cur" == "$want" ]]; then
            printf '%s\n' "$branch"
            return 0
          fi
          cur_phys=$(phys_path "$cur")
          if [[ -n "$want_phys" && -n "$cur_phys" && "$cur_phys" == "$want_phys" ]]; then
            printf '%s\n' "$branch"
            return 0
          fi
        fi
        cur=""
        branch=""
        ;;
    esac
  done <<EOF
$(git worktree list --porcelain 2>/dev/null || true)
EOF
  # Final record may lack trailing blank line
  if [[ -n "$cur" ]]; then
    if [[ "$cur" == "$want" ]]; then
      printf '%s\n' "$branch"
      return 0
    fi
    cur_phys=$(phys_path "$cur")
    if [[ -n "$want_phys" && -n "$cur_phys" && "$cur_phys" == "$want_phys" ]]; then
      printf '%s\n' "$branch"
      return 0
    fi
  fi
  echo ""
  return 1
}

# Every mutation mode (CAS and non-CAS) requires a successful fetch of one
# exact remote base and carries that base/ref identity through the whole
# operation. Local main/master and stale cached remote-tracking refs never
# authorize classification, close, strip, delete, or label removal (#153).
CAS_MODE=0
if [[ -n "$EXPECTED_CLAIM_BLOB" ]]; then
  CAS_MODE=1
fi

# Successful fetch of exact remote base into its remote-tracking ref.
# Prints base name (main|master). Distinguishes remote absence (no main/master
# on origin) from unreadable/fetch/transport failure.
#
# Authority contract (#153 exact-head):
#   1. Enumerate which of main/master exists on origin via ls-remote (read).
#   2. Prefer main when present, else master when present, else refuse.
#   3. Fetch exactly that one base. A fetch/transport/object failure is
#      unreadable authority — never fall through to try the other name after
#      an arbitrary main failure (that used to convert transport error into
#      alternate-base authority).
# Never falls back to local or stale cache.
fetch_remote_base() {
  local base fetch_out fetch_rc=0 ls_out main_present=0 master_present=0
  CLEANUP_FETCH_REASON=""
  if ! ls_out=$(git ls-remote --heads origin refs/heads/main refs/heads/master 2>&1); then
    CLEANUP_FETCH_REASON="git ls-remote --heads origin failed (unreadable remote, not ref absence): $ls_out"
    return 1
  fi
  printf '%s\n' "$ls_out" | grep -Eq $'[\t ]refs/heads/main$' && main_present=1
  printf '%s\n' "$ls_out" | grep -Eq $'[\t ]refs/heads/master$' && master_present=1
  if [[ "$main_present" -eq 1 ]]; then
    base=main
  elif [[ "$master_present" -eq 1 ]]; then
    base=master
  else
    CLEANUP_FETCH_REASON="origin has neither refs/heads/main nor refs/heads/master (true ref absence)"
    return 1
  fi
  fetch_out=$(git fetch origin "$base" 2>&1) && fetch_rc=0 || fetch_rc=$?
  if [[ "$fetch_rc" -ne 0 ]]; then
    CLEANUP_FETCH_REASON="git fetch origin ${base} failed (unreadable remote authority, not alternate-base fallback): ${fetch_out}"
    return 1
  fi
  if ! git rev-parse --verify --quiet "origin/${base}^{commit}" >/dev/null 2>&1; then
    CLEANUP_FETCH_REASON="origin/${base} unreadable after successful fetch"
    return 1
  fi
  printf '%s\n' "$base"
  return 0
}

# Resolve the ledger ref ONLY from origin/<base> after a successful fetch.
# Never local main/master. Never a stale pre-fetch remote-tracking tip alone.
resolve_ledger_ref() {
  local candidate
  for candidate in origin/main origin/master; do
    if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if ! CLEANUP_BASE_FETCH=$(fetch_remote_base); then
  die "cannot fetch remote ledger base (origin main/master) — refuse mutation (no local/cached fallback)${CLEANUP_FETCH_REASON:+: $CLEANUP_FETCH_REASON}"
fi
info "remote ledger fetch ok: origin/${CLEANUP_BASE_FETCH}"
# Authoritative remote base identity carried through the whole operation.
CLEANUP_BASE="${CLEANUP_BASE_FETCH}"

REF=""
if ! REF=$(resolve_ledger_ref); then
  die "cannot resolve a valid ledger commit ref (tried origin/main, origin/master after successful fetch; no local/cached fallback). A missing/unborn/invalid remote ref is not an empty ledger — fix origin or the claim-table remote."
fi
# Bind REF to the exact base we just fetched when both exist (prefer the
# fetched base so main/master identity cannot silently drift mid-run).
if git rev-parse --verify --quiet "origin/${CLEANUP_BASE}^{commit}" >/dev/null 2>&1; then
  REF="origin/${CLEANUP_BASE}"
fi
info "ledger ref: $REF ($(git rev-parse --short "$REF" 2>/dev/null || echo '?'))"

# The commit object resolving is not enough: the referenced tree must be
# readable. A missing/corrupt tree is NOT an empty ledger — hard-fail before
# any label mutation or "no live claims" classification.
if ! git rev-parse --verify --quiet "${REF}^{commit}" >/dev/null 2>&1; then
  die "ledger ref $REF does not resolve to a commit object — not an empty ledger"
fi
# Prefer peeling ^{tree}; if the object store cannot peel (deleted tree object),
# fall back to the commit's tree field so we can still name the missing SHA.
TREE_SHA=$(git rev-parse --verify "${REF}^{tree}" 2>/dev/null || true)
if [[ -z "$TREE_SHA" ]]; then
  TREE_SHA=$(git cat-file -p "${REF}^{commit}" 2>/dev/null | awk '/^tree / {print $2; exit}')
fi
[[ -n "$TREE_SHA" ]] || \
  die "ledger commit at $REF has no tree pointer — unreadable/corrupt tree is not an empty ledger; refuse label mutation"
if ! git cat-file -e "$TREE_SHA" 2>/dev/null; then
  die "ledger commit at $REF references an unreadable/corrupt tree ($TREE_SHA) — not an empty ledger; refuse label mutation until the object store is repaired"
fi
# Prove the tree is listable (cat-file -e alone is not enough on some stores).
if ! git ls-tree "$TREE_SHA" >/dev/null 2>&1; then
  die "cannot list tree for ledger commit $REF (unreadable/corrupt tree $TREE_SHA) — not an empty ledger; refuse label mutation"
fi

# A missing docs/claims path and absent active-work.md on a *valid, readable*
# tree is a valid *empty* ledger (every claim already released, or never filed)
# — not corruption. Treat it as zero live claims and continue label/worktree
# cleanup. A named --claim-id that is not present still hard-fails below.
# Tree-read failures above already exited; do not reclassify them as empty.
#
# Inspect tree entries first. git cat-file -e ref:path fails both when the
# path is absent AND when the path exists but its blob is missing/corrupt.
# Only true absence is an empty-ledger signal; an unreadable live blob must
# hard-fail before any label mutation.
#
# Fail-closed for the *per-file* ledger too: listing docs/claims/ by pathname
# alone is not enough. Every live tree entry under docs/claims/ must be a
# readable regular blob (mode 100644/100755) before any worktree, branch,
# claim-row, or label cleanup proceeds. A missing/corrupt claim blob is not
# an empty ledger (same contract as docs/active-work.md).
HAS_ACTIVE=0
HAS_CLAIMS_TREE=0

# Prove a tree line is a readable regular blob (legacy table or per-claim file).
# Args: path mode type object-sha
require_readable_regular_blob() {
  local path="$1" mode="$2" typ="$3" obj="$4"
  if [[ "$typ" != "blob" ]] || [[ "$mode" != "100644" && "$mode" != "100755" ]]; then
    die "$path at $REF has unexpected Git mode/type ($mode $typ${obj:+ $obj}) — refuse mutation until the ledger is repaired"
  fi
  if [[ -z "$obj" ]]; then
    die "$path at $REF has no object id — unreadable/corrupt ledger entry; refuse mutation"
  fi
  if ! git cat-file -e "$obj" 2>/dev/null; then
    die "$path exists in the ledger tree at $REF but its blob is unreadable/corrupt/unfetchable ($obj) — not an empty ledger; refuse label mutation until the object store is repaired"
  fi
  local got_type
  got_type=$(git cat-file -t "$obj" 2>/dev/null || true)
  if [[ "$got_type" != "blob" ]]; then
    die "$path at $REF object $obj has unexpected type '${got_type:-unreadable}' (want blob) — refuse mutation until the object store is repaired"
  fi
  # Prove the payload is fetchable, not only that the object header exists.
  if ! git cat-file blob "$obj" >/dev/null 2>&1; then
    die "$path exists in the ledger tree at $REF but its blob payload is unreadable/corrupt ($obj) — not an empty ledger; refuse label mutation until the object store is repaired"
  fi
}

ACTIVE_LS_ERR=""
ACTIVE_LINE=$(git ls-tree "$REF" -- docs/active-work.md 2>&1) || {
  ACTIVE_LS_ERR=$?
}
if [[ -n "$ACTIVE_LS_ERR" ]]; then
  die "cannot list docs/active-work.md at $REF (git ls-tree failed) — unreadable ledger tree is not an empty ledger"
fi
if [[ -n "$ACTIVE_LINE" ]]; then
  # Entry exists in the tree — mode/type + blob must be a readable regular file.
  active_mode=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $1; exit}')
  active_type=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $2; exit}')
  active_blob=$(printf '%s\n' "$ACTIVE_LINE" | awk '{print $3; exit}')
  require_readable_regular_blob "docs/active-work.md" "$active_mode" "$active_type" "$active_blob"
  HAS_ACTIVE=1
fi

# docs/claims self-entry: absent is empty; present must be a tree (not a blob
# /symlink/gitlink). Then every child must be a readable regular blob.
CLAIMS_SELF_ERR=""
CLAIMS_SELF=$(git ls-tree "$REF" -- docs/claims 2>&1) || {
  CLAIMS_SELF_ERR=$?
}
if [[ -n "$CLAIMS_SELF_ERR" ]]; then
  die "cannot list docs/claims at $REF (git ls-tree failed) — unreadable ledger tree is not an empty ledger"
fi
if [[ -n "$CLAIMS_SELF" ]]; then
  claims_self_mode=$(printf '%s\n' "$CLAIMS_SELF" | awk '{print $1; exit}')
  claims_self_type=$(printf '%s\n' "$CLAIMS_SELF" | awk '{print $2; exit}')
  claims_self_obj=$(printf '%s\n' "$CLAIMS_SELF" | awk '{print $3; exit}')
  if [[ "$claims_self_type" != "tree" ]] || [[ "$claims_self_mode" != "040000" ]]; then
    die "docs/claims at $REF has unexpected Git mode/type ($claims_self_mode $claims_self_type${claims_self_obj:+ $claims_self_obj}) — want 040000 tree; refuse mutation until the ledger is repaired"
  fi
  if [[ -z "$claims_self_obj" ]] || ! git cat-file -e "$claims_self_obj" 2>/dev/null; then
    die "docs/claims tree at $REF is unreadable/corrupt${claims_self_obj:+ ($claims_self_obj)} — not an empty ledger; refuse label mutation until the object store is repaired"
  fi
  if ! git ls-tree "$claims_self_obj" >/dev/null 2>&1; then
    die "cannot list docs/claims tree at $REF (unreadable/corrupt tree ${claims_self_obj}) — not an empty ledger; refuse label mutation"
  fi

  # Enumerate *exact* live children from the authoritative ref. Pathname-only
  # matching without blob proof is how a missing claim object slipped through
  # to label/worktree mutation (issue #61).
  CLAIMS_LS_ERR=""
  CLAIMS_LINES=$(git ls-tree "$REF" docs/claims/ 2>&1) || {
    CLAIMS_LS_ERR=$?
  }
  if [[ -n "$CLAIMS_LS_ERR" ]]; then
    die "cannot read docs/claims/ at $REF (git ls-tree failed) — unreadable ledger tree is not an empty ledger"
  fi
  if [[ -n "$CLAIMS_LINES" ]]; then
    HAS_CLAIMS_TREE=1
    while IFS= read -r claim_line; do
      [[ -n "$claim_line" ]] || continue
      claim_mode=$(printf '%s\n' "$claim_line" | awk '{print $1; exit}')
      claim_type=$(printf '%s\n' "$claim_line" | awk '{print $2; exit}')
      claim_obj=$(printf '%s\n' "$claim_line" | awk '{print $3; exit}')
      # Path is after the first tab (mode SP type SP object TAB path).
      claim_path="${claim_line#*$'\t'}"
      [[ -n "$claim_path" ]] || claim_path="docs/claims/<unknown>"
      require_readable_regular_blob "$claim_path" "$claim_mode" "$claim_type" "$claim_obj"
    done <<EOF
$CLAIMS_LINES
EOF
  fi
fi

if [[ "$HAS_ACTIVE" -eq 0 && "$HAS_CLAIMS_TREE" -eq 0 ]]; then
  info "claim ledger at $REF is empty (no docs/claims/* and no docs/active-work.md) — treating as no live claims"
fi

# Claims live one-per-file in docs/claims/ (L-023); rows in docs/active-work.md
# are the legacy form and are still released. Prints *all* live claim ids
# (deduped, sorted) on stdout — never filters by ERE. Returns 1 if the ledger
# tree cannot be read (caller must hard-fail — never treat a failed tree read
# as an empty match set).
# Startup already proved every live claims/* blob is a readable regular file;
# re-check here so a mid-run object-store loss still fails closed instead of
# inventing ids from pathnames alone.
claim_ids_all() {
  local claims_out active_out active_entry active_blob claims_line claims_full
  local c_mode c_type c_obj
  claims_out=""
  claims_full=""
  if ! claims_line=$(git ls-tree "$REF" -- docs/claims 2>&1); then
    echo "release-claim.sh: ERROR: cannot list docs/claims at $REF — unreadable ledger tree is not an empty ledger" >&2
    return 1
  fi
  if [[ -n "$claims_line" ]]; then
    c_mode=$(printf '%s\n' "$claims_line" | awk '{print $1; exit}')
    c_type=$(printf '%s\n' "$claims_line" | awk '{print $2; exit}')
    c_obj=$(printf '%s\n' "$claims_line" | awk '{print $3; exit}')
    if [[ "$c_type" != "tree" ]] || [[ "$c_mode" != "040000" ]]; then
      echo "release-claim.sh: ERROR: docs/claims at $REF has unexpected Git mode/type ($c_mode $c_type${c_obj:+ $c_obj}) — want 040000 tree" >&2
      return 1
    fi
    if ! claims_out=$(git ls-tree --name-only "$REF" docs/claims/ 2>&1); then
      echo "release-claim.sh: ERROR: cannot list docs/claims/ at $REF — unreadable ledger tree is not an empty ledger" >&2
      return 1
    fi
    # Full tree listing is required for blob mode/type/OID validation. Never
    # swallow enumeration failure with `|| true` — that converted unreadable
    # into zero representations.
    if ! claims_full=$(git ls-tree "$REF" docs/claims/ 2>&1); then
      echo "release-claim.sh: ERROR: cannot list docs/claims/ (full) at $REF — unreadable ledger tree is not an empty ledger" >&2
      return 1
    fi
    # Pathname list is only valid when every listed object is still a readable blob.
    local entry_line entry_mode entry_type entry_obj entry_path
    while IFS= read -r entry_line; do
      [[ -n "$entry_line" ]] || continue
      entry_mode=$(printf '%s\n' "$entry_line" | awk '{print $1; exit}')
      entry_type=$(printf '%s\n' "$entry_line" | awk '{print $2; exit}')
      entry_obj=$(printf '%s\n' "$entry_line" | awk '{print $3; exit}')
      entry_path="${entry_line#*$'\t'}"
      if [[ "$entry_type" != "blob" ]] || [[ "$entry_mode" != "100644" && "$entry_mode" != "100755" ]]; then
        echo "release-claim.sh: ERROR: ${entry_path:-docs/claims/<unknown>} at $REF has unexpected Git mode/type ($entry_mode $entry_type${entry_obj:+ $entry_obj})" >&2
        return 1
      fi
      if [[ -z "$entry_obj" ]] || ! git cat-file -e "$entry_obj" 2>/dev/null; then
        echo "release-claim.sh: ERROR: ${entry_path:-docs/claims/<unknown>} exists in the ledger tree at $REF but its blob is unreadable/corrupt${entry_obj:+ ($entry_obj)} — not an empty ledger" >&2
        return 1
      fi
    done <<EOF
$claims_full
EOF
  fi
  active_out=""
  # Tree entry first: absence is empty content; present-but-unreadable hard-fails.
  if ! active_entry=$(git ls-tree "$REF" -- docs/active-work.md 2>&1); then
    echo "release-claim.sh: ERROR: cannot list docs/active-work.md at $REF — unreadable ledger tree is not an empty ledger" >&2
    return 1
  fi
  if [[ -n "$active_entry" ]]; then
    active_blob=$(printf '%s\n' "$active_entry" | awk '{print $3; exit}')
    if ! git cat-file -e "${active_blob:-$REF:docs/active-work.md}" 2>/dev/null; then
      echo "release-claim.sh: ERROR: docs/active-work.md exists in the ledger tree at $REF but its blob is unreadable/corrupt${active_blob:+ ($active_blob)} — not an empty ledger" >&2
      return 1
    fi
    if ! active_out=$(git show "$REF:docs/active-work.md" 2>&1); then
      echo "release-claim.sh: ERROR: cannot read docs/active-work.md at $REF — unreadable/corrupt blob is not an empty ledger" >&2
      return 1
    fi
  elif ! git cat-file -e "$TREE_SHA" 2>/dev/null; then
    echo "release-claim.sh: ERROR: ledger tree $TREE_SHA became unreadable while matching claims — not an empty ledger" >&2
    return 1
  fi
  {
    printf '%s\n' "$claims_out" |
      sed 's|^docs/claims/||;s|\.md$||'
    # Legacy table: claim-id is column 3 only. Never scan scope/session/notes.
    printf '%s\n' "$active_out" |
      grep -E '^\| ' |
      awk -F'|' '{print $3}' |
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
  } | grep -E '^issue-' | sort -u || true
  return 0
}

# True when claim id $1 belongs to the positional issue (and --prefix when set).
# issue-1<N>- never matches issue-<N>-. Alpha namespace is optional without --prefix.
claim_id_for_issue() {
  local id="$1"
  [[ -n "$id" ]] || return 1
  if [[ -n "$PREFIX" ]]; then
    case "$id" in
      "issue-${ISSUE}-"*) return 0 ;;
      "issue-${PREFIX}-${ISSUE}-"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "$id" in
    "issue-${ISSUE}-"*) return 0 ;;
  esac
  # Optional alpha namespace: issue-<ns>-<N>-… (ns starts with a letter).
  if [[ "$id" =~ ^issue-[A-Za-z][A-Za-z0-9]*-${ISSUE}- ]]; then
    return 0
  fi
  return 1
}

# Worktree/branch per released claim id, derived from the id rather than
# assumed, so namespaced ids (issue-template-5-x) resolve correctly (L-037).
# Defined here (not just before their removal call sites) so the terminal
# PR-body verification below (#153) can bind head-branch identity too.
wt_dir_for() { echo "$WT_PARENT/wt-${1#issue-}"; }
branch_for() { echo "feat/${1#issue-}"; }

# Terminal (MERGED/CLOSED) PR-body claim fallback (#153). Reachable only for
# an exact --claim-id release, and only outside claim-reaper's CAS mode (CAS
# is ledger-only by contract — never touched by this path). Fires when the
# claim id is absent from the live ledger: the claim's reservation PR may
# already be done and current claim.sh never writes a ledger row at all, so
# "absent from the ledger" is not evidence the claim was never real (that was
# the #139 failure this closes). Verifies exact issue/claim-id/PR-number/
# head-branch/head-SHA/base-repository/terminal-state binding before
# returning success; never invents a ledger row. Ambiguous, open, foreign
# (cross-repo/fork), mismatched, or unreadable evidence dies immediately
# (fail closed) rather than falling through to the generic "no live claim"
# message, so the operator sees exactly which binding failed.
#
# This function only VERIFIES evidence — it never touches a worktree, branch,
# or label. All mutation is deferred to terminal_cleanup_release(), called
# later once every helper it needs (phys_path/worktree_registered/…) is
# defined, only after this function returns 0 (#153 AC1).
#
# RETURN CONTRACT (#153 review round 3, P2). This helper is called from two
# places with two very different amounts of state already mutated, so it must
# not decide the process's fate itself:
#   0  verified — the caller may proceed to terminal_cleanup_release().
#   1  NOT FOUND / not consulted — no terminal evidence exists for this claim,
#      or the repository binding says this evidence is not ours to read. The
#      caller falls back to whatever it does when there is no evidence.
#   2  FATAL — evidence exists but is unreadable, ambiguous, mismatched, or
#      contradicts the PR's own state. TERMINAL_FAIL_REASON says which.
#      A caller that has not mutated anything turns this into `die` (exit 1);
#      the post-close caller, which HAS already closed the PR, must instead
#      take its documented close-only INCOMPLETE path (exit 3, artifacts and
#      agent-claimed preserved) — the partial mutation is exactly why exiting
#      1 through `die` was wrong there.
# The evidence checks themselves are unchanged: every one of them still
# refuses. Only who decides the exit code moved.
TERMINAL_PR_NUMBER=""
TERMINAL_MODE=0
TERMINAL_HEAD_SHA=""
TERMINAL_HEAD_BRANCH=""
TERMINAL_MERGE_SHA=""
TERMINAL_STATE=""
TERMINAL_FAIL_REASON=""
CLEANUP_TARGET_BRANCH=""
CLEANUP_TARGET_WT=""
CLEANUP_TARGET_REASON=""
# Records why terminal evidence is fatal and returns 2. Never exits: the
# caller knows how much has already been mutated and therefore what a fatal
# verdict costs.
terminal_fatal() {
  TERMINAL_FAIL_REASON="$1"
  return 2
}

# Fail-closed stdout/stderr capture (#153 stream-capture P2/P3). Shared
# helper so sensors can source the same production code in-process.
# shellcheck source=lib/stream-capture.sh
. "$RELEASE_LIB_DIR/stream-capture.sh" ||
  die "cannot source $RELEASE_LIB_DIR/stream-capture.sh — refuse capture without fail-closed stream isolation"

try_terminal_pr_body_release() {
  local id="$1" want_pr="${2:-}" rows count reader_rc=0
  TERMINAL_FAIL_REASON=""
  _RC_CAP_STDOUT=""
  _RC_CAP_STDERR=""
  local t_number t_claim t_scope t_issue t_head t_head_sha t_url t_state t_cross t_merge_sha t_base_repo t_created t_updated
  if [[ -z "${PR_REPO:-}" || ! -x "$SCRIPT_DIR/pr-claims.sh" ]]; then
    return 1
  fi
  # The evidence about to authorize worktree/branch deletion must come from
  # THIS checkout's own repository, never a fork/copy carrying the same branch
  # and commits (#153 review P1). Checked before the query, so unbound
  # evidence is never even read, let alone acted on. Returning 1 (rather than
  # dying) keeps the caller's own "no live claim" refusal — which is equally
  # fail-closed, since nothing has been mutated — while the warning names the
  # real reason this evidence was not consulted.
  if ! canonical_repo_binding_ok "$PR_REPO"; then
    warn "not consulting terminal PR-body evidence for '$id': $BINDING_REASON"
    return 1
  fi
  # Stream separation (#153 review P2): pr-claims.sh may write benign warnings
  # to stderr on a successful lookup. Merging stderr into the captured evidence
  # (2>&1) made one valid row + one warning look like two evidence rows and
  # stranded a legitimate worktree. Capture streams separately; only stdout is
  # parsed/counted. Successful stderr is ignored for release behaviour.
  # Nonzero-exit stderr enriches the existing failure diagnostic only.
  if [[ -n "$want_pr" ]]; then
    # Bound lookup (#153 review P2): the caller already knows exactly which PR
    # it is releasing, so ask about that PR instead of asking the globally
    # ambiguous "which terminal PR carries this id?" — a legitimately reused
    # claim id has more than one.
    reader_rc=0
    _rc_capture_streams "$SCRIPT_DIR/pr-claims.sh" find-terminal-pr "$PR_REPO" "$id" "$want_pr" || reader_rc=$?
    rows="$_RC_CAP_STDOUT"
    if [[ "$reader_rc" -ne 0 ]]; then
      terminal_fatal "cannot verify terminal PR-body claim evidence for '$id' on PR #$want_pr in $PR_REPO (gh query failed) — refuse mutation: ${_RC_CAP_STDERR}" || return 2
    fi
  else
    reader_rc=0
    _rc_capture_streams "$SCRIPT_DIR/pr-claims.sh" find-terminal "$PR_REPO" "$id" || reader_rc=$?
    rows="$_RC_CAP_STDOUT"
    if [[ "$reader_rc" -ne 0 ]]; then
      terminal_fatal "cannot verify terminal PR-body claim evidence for '$id' on $PR_REPO (gh query failed) — refuse mutation: ${_RC_CAP_STDERR}
  If this claim id was released and later reused, more than one terminal PR carries it; name the exact one with --pr <number>." || return 2
    fi
  fi
  # Successful stderr is non-authoritative; drop it so it cannot affect rows.
  _RC_CAP_STDERR=""
  # grep -c (not wc -l): $rows came from command substitution / file read,
  # which strips the trailing newline, so a single-line result would otherwise
  # undercount to 0 and a two-line result to 1 — wc -l counts newline
  # characters, not lines.
  count=$(printf '%s' "$rows" | grep -c . || true)
  [[ "$count" -gt 0 ]] || return 1
  if [[ "$count" -gt 1 ]]; then
    terminal_fatal "ambiguous terminal PR-body evidence for claim id '$id' on $PR_REPO — multiple PRs matched. A released claim id may legitimately be reused, so more than one terminal PR can carry it; name the exact one with --pr <number> rather than guessing." || return 2
  fi
  # cut, not `IFS=$'\t' read`: tab is IFS *whitespace*, so bash's read
  # collapses consecutive tabs and silently drops empty fields (e.g. a CLOSED
  # PR's empty merge-SHA column), shifting every field after it. cut treats
  # each tab as an exact delimiter and preserves empty fields.
  t_number=$(cut -f1 <<<"$rows")
  t_claim=$(cut -f2 <<<"$rows")
  t_scope=$(cut -f3 <<<"$rows")
  t_issue=$(cut -f4 <<<"$rows")
  t_head=$(cut -f5 <<<"$rows")
  t_head_sha=$(cut -f6 <<<"$rows")
  # shellcheck disable=SC2034  # url/created/updated read for row-shape parity; not part of the identity checks below
  t_url=$(cut -f7 <<<"$rows")
  t_state=$(cut -f8 <<<"$rows")
  t_cross=$(cut -f9 <<<"$rows")
  t_merge_sha=$(cut -f10 <<<"$rows")
  t_base_repo=$(cut -f11 <<<"$rows")
  # shellcheck disable=SC2034
  t_created=$(cut -f12 <<<"$rows")
  # shellcheck disable=SC2034
  t_updated=$(cut -f13 <<<"$rows")
  [[ -n "$t_number" && -n "$t_claim" && -n "$t_scope" && -n "$t_state" && -n "$t_head" && -n "$t_head_sha" && -n "$t_base_repo" ]] ||
    terminal_fatal "malformed/truncated terminal PR-body evidence for '$id' on $PR_REPO" || return 2
  [[ "$t_number" =~ ^[0-9]+$ ]] ||
    terminal_fatal "terminal PR-body claim for '$id' has an unsafe PR number '$t_number' — refuse" || return 2
  if [[ -n "$want_pr" ]]; then
    [[ "$t_number" == "$want_pr" ]] ||
      terminal_fatal "terminal PR-body evidence for '$id' came back for PR #$t_number, not the requested PR #$want_pr — refuse" || return 2
  fi
  [[ "$t_claim" == "$id" ]] ||
    terminal_fatal "terminal PR-body claim id mismatch on PR #$t_number (want '$id', got '${t_claim:-?}') — refuse" || return 2
  [[ "$t_issue" == "$ISSUE" ]] ||
    terminal_fatal "terminal PR-body claim #$t_number issue mismatch (want #$ISSUE, got '${t_issue:-?}') — refuse" || return 2
  case "$t_state" in
    MERGED|CLOSED) ;;
    OPEN)
      terminal_fatal "terminal PR-body claim #$t_number for '$id' is still OPEN — release only after it merges or closes" || return 2
      ;;
    *)
      terminal_fatal "terminal PR-body claim #$t_number for '$id' has an unrecognized state '$t_state' — refuse" || return 2
      ;;
  esac
  [[ "$t_cross" == "false" ]] ||
    terminal_fatal "terminal PR-body claim #$t_number for '$id' is a cross-repository (fork) PR — refuse (foreign-repo evidence)" || return 2
  # Base-repository identity is re-derived by pr-claims.sh from the PR's own
  # URL, never assumed from the --repo query argument alone (#153 AC3).
  [[ "$t_base_repo" == "$PR_REPO" ]] ||
    terminal_fatal "terminal PR-body claim #$t_number for '$id' base-repository mismatch (want '$PR_REPO', got '${t_base_repo:-?}') — refuse (do not infer repository identity from the query argument alone)" || return 2
  [[ -n "$t_head" && "$t_head" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    terminal_fatal "terminal PR-body claim #$t_number for '$id' has an unsafe/unreadable head branch — refuse" || return 2
  local expect_branch
  expect_branch=$(branch_for "$id")
  [[ "$t_head" == "$expect_branch" ]] ||
    terminal_fatal "terminal PR-body claim #$t_number for '$id' head branch mismatch (want '$expect_branch', got '$t_head') — refuse" || return 2
  # Store the already-verified PR-evidence head branch. Preview and live
  # cleanup consume this value rather than calling branch_for again (#271).
  [[ "$t_head_sha" =~ ^[0-9a-f]{40}$ ]] ||
    terminal_fatal "terminal PR-body claim #$t_number for '$id' has a malformed/missing head SHA '${t_head_sha:-?}' — refuse" || return 2
  case "$t_state" in
    MERGED)
      [[ -n "$t_merge_sha" && "$t_merge_sha" =~ ^[0-9a-f]{40}$ ]] ||
        terminal_fatal "terminal PR-body claim #$t_number for '$id' is MERGED but has a malformed/missing merge-commit SHA — refuse" || return 2
      ;;
    CLOSED)
      [[ -z "$t_merge_sha" ]] ||
        terminal_fatal "terminal PR-body claim #$t_number for '$id' is CLOSED but carries a merge-commit SHA — state/evidence mismatch, refuse (never call unmerged code merged)" || return 2
      ;;
  esac
  info "verified terminal PR-body claim #$t_number ($t_state) for '$id' on $PR_REPO — releasing without a ledger row"
  TERMINAL_PR_NUMBER="$t_number"
  TERMINAL_HEAD_SHA="$t_head_sha"
  TERMINAL_HEAD_BRANCH="$t_head"
  TERMINAL_MERGE_SHA="$t_merge_sha"
  TERMINAL_STATE="$t_state"
  TERMINAL_MODE=1
  return 0
}

# Bind the exact refs/heads/<branch> to its real *registered* worktree path
# by enumerating `git worktree list --porcelain` — never derive the path from
# the claim id (#153 blocker 1). A `wt_dir_for` guess is how a registered
# worktree at a non-default path was missed while an unrelated/unregistered
# default-path directory drove the removal decision.
#
# Sets on success (return 0):
#   TERM_WT_PATH   the exact registered worktree path for $br, or "" when no
#                  registered worktree is checked out on that branch.
# Sets on failure (return 1):
#   TERM_WT_REASON why resolution itself could not be trusted — ambiguity
#                  (branch registered at more than one path), a symlinked or
#                  unreadable registered entry, a registered path that
#                  canonicalizes to the caller's own checkout (foreign
#                  canonical path), or an unsafe/unregistered object still
#                  sitting at the historical default-derived path when zero
#                  registered worktrees match the branch. `git worktree list`
#                  itself failing is also unreadable evidence, not "none".
#
# Zero matching registered worktrees is allowed (TERM_WT_PATH="") only when
# there is no unsafe object at the old guessed path: nothing there at all, or
# a *registered* worktree there under some other branch (a real, tracked,
# unrelated worktree — not ours, not touched, not unsafe). An unregistered
# stray directory/symlink/file at that path, or a registered-but-differently-
# branched worktree, is refused rather than silently ignored.
resolve_registered_worktree_for_branch() {
  local br="$1" id="$2"
  local matches="" match_count=0
  local canon_root wt_phys guess
  TERM_WT_PATH=""
  TERM_WT_REASON=""

  # Enumeration itself comes from the shared guard library so claim.sh's
  # rollback and this cleanup can never disagree about which worktree is on a
  # branch; the policy on top of that answer stays release-specific.
  if ! guard_worktree_paths_for_branch "$br"; then
    TERM_WT_REASON="$GUARD_WT_REASON"
    return 1
  fi
  matches="$GUARD_WT_PATHS"
  match_count="$GUARD_WT_COUNT"
  canon_root=$(phys_path "$CANONICAL")

  if [[ "$match_count" -gt 1 ]]; then
    TERM_WT_REASON="branch '$br' is registered at more than one worktree path — ambiguous, refuse: $(printf '%s' "$matches" | tr '\n' ' ')"
    return 1
  fi

  if [[ "$match_count" -eq 1 ]]; then
    TERM_WT_PATH=$(printf '%s\n' "$matches" | sed -n '1p')
    if [[ -L "$TERM_WT_PATH" ]]; then
      TERM_WT_REASON="registered worktree path is a symlink — refuse: $TERM_WT_PATH"
      return 1
    fi
    if [[ ! -d "$TERM_WT_PATH" ]]; then
      TERM_WT_REASON="registered worktree path is missing or not a directory: $TERM_WT_PATH"
      return 1
    fi
    wt_phys=$(phys_path "$TERM_WT_PATH")
    if [[ -z "$wt_phys" ]]; then
      TERM_WT_REASON="cannot canonicalize registered worktree path: $TERM_WT_PATH"
      return 1
    fi
    if [[ -n "$canon_root" && "$wt_phys" == "$canon_root" ]]; then
      TERM_WT_REASON="registered worktree path resolves to the canonical checkout itself — foreign canonical path, refuse: $TERM_WT_PATH"
      return 1
    fi
    return 0
  fi

  # match_count == 0: the exact branch has no registered worktree anywhere.
  guess=$(wt_dir_for "$id")
  guess="${guess%/}"
  if [[ -e "$guess" || -L "$guess" ]]; then
    if worktree_registered "$guess"; then
      local guess_branch
      guess_branch=$(worktree_branch "$guess" || true)
      TERM_WT_REASON="worktree at the historical default path is checked out on '${guess_branch:-detached/unknown}', expected the exact PR head branch '$br' — refuse rather than assume the branch alone is safe: $guess"
      return 1
    fi
    TERM_WT_REASON="no registered worktree for branch '$br', and the historical default path exists but is not a registered git worktree (no default-path fallback; refuse rm -rf): $guess"
    return 1
  fi
  return 0
}

# One pure-read cleanup-target resolver shared by dry-run preview and live
# branch-resolved cleanup (#271). Returns the exact cleanup branch plus zero
# or one exact registered worktree path. Enumeration / stat / realpath only:
# no worktree prune, fetch, status/index refresh, lock creation, ref update,
# filesystem write, or GitHub mutation. Callers pass the already-verified
# branch; this function never derives one via branch_for or wt_dir_for.
#
# Sets on success (return 0):
#   CLEANUP_TARGET_BRANCH  the branch that was asked about
#   CLEANUP_TARGET_WT      exact registered path, or "" when none
# Sets on failure (return 1):
#   CLEANUP_TARGET_REASON  why identity could not be trusted
resolve_cleanup_target() {
  local br="$1" id="$2"
  CLEANUP_TARGET_BRANCH="$br"
  CLEANUP_TARGET_WT=""
  CLEANUP_TARGET_REASON=""
  if [[ -z "$br" ]]; then
    CLEANUP_TARGET_REASON="empty cleanup branch — refuse"
    return 1
  fi
  if ! resolve_registered_worktree_for_branch "$br" "$id"; then
    CLEANUP_TARGET_REASON="$TERM_WT_REASON"
    return 1
  fi
  CLEANUP_TARGET_WT="$TERM_WT_PATH"
  return 0
}

# Preview renderer for a branch-resolved claim. Consumes an already-verified
# branch; never calls wt_dir_for or branch_for. Names identity and pending
# live revalidation; does not promise deletion (#271).
render_branch_resolved_preview() {
  local id="$1" br="$2" shown
  echo "  release claim:   $id"
  if [[ -n "$CLEANUP_TARGET_WT" ]]; then
    shown=$(phys_path "$CLEANUP_TARGET_WT")
    shown="${shown:-$CLEANUP_TARGET_WT}"
    if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
      echo "    KEEP worktree:   $shown"
    else
      echo "    worktree target: $shown"
    fi
  else
    if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
      echo "    KEEP worktree:   no registered worktree"
    else
      echo "    worktree target: no registered worktree"
    fi
  fi
  if [[ "$KEEP_BRANCH" -eq 1 ]]; then
    echo "    KEEP branch:     $br"
  else
    echo "    branch target:   $br"
  fi
  echo "    live execution will revalidate clean status, exact/contained head SHA, branch/ref identity, claim renewal, and compare-and-swap conditions immediately before mutation"
}

# Terminal / open-PR dry-run planning: resolve then render using the stored
# evidence branch. No branch_for, no wt_dir_for (#271).
preview_verified_branch_cleanup() {
  local id="$1" br="$2"
  if [[ -z "$br" ]]; then
    CLEANUP_TARGET_REASON="missing stored PR-evidence head branch"
    return 1
  fi
  if ! resolve_cleanup_target "$br" "$id"; then
    return 1
  fi
  render_branch_resolved_preview "$id" "$CLEANUP_TARGET_BRANCH"
  return 0
}

# Open-PR dry-run: preview close + the same registered target live cleanup
# would evaluate. Resolves before printing a plan so unsafe identity fails
# closed rather than promising a close (#271).
preview_open_pr_body_dry_run() {
  local id="$PR_CLAIM_ID" br="$PR_HEAD_BRANCH"
  if [[ -z "$br" ]]; then
    CLEANUP_TARGET_REASON="missing stored PR-evidence head branch"
    return 1
  fi
  if ! resolve_cleanup_target "$br" "$id"; then
    return 1
  fi
  info "dry-run: would close PR #$PR_NUMBER to release the PR-body claim (frozen open head $FROZEN_OPEN_HEAD_SHA)"
  info "dry-run: would then verify the now-terminal PR and run the exact cleanup for worktree/branch '$br'"
  if [[ -n "$PR_SIBLINGS" ]]; then
    info "dry-run: would keep agent-claimed — sibling PR-body claim(s) remain: $(printf '%s' "$PR_SIBLINGS" | tr '\n' ' ')"
  fi
  render_branch_resolved_preview "$id" "$br"
  return 0
}

# Query the *exact* remote branch via `git ls-remote --heads`, distinguishing
# "the query itself failed" (network/auth/read failure — unreadable evidence)
# from "the branch legitimately does not exist" (query succeeded, empty
# output) from "the branch exists" (exactly one well-formed row whose ref
# matches exactly). `git ls-remote --exit-code` alone conflates the first two
# cases into the same nonzero exit — that is exactly the ambiguity #153
# blocker 4 closes (#153).
#
# Sets on success (return 0):
#   REMOTE_BRANCH_STATUS  "present" or "absent"
#   REMOTE_BRANCH_OID     the branch's exact OID when present, else ""
# Sets on failure (return 1):
#   REMOTE_BRANCH_REASON  why the query is unreadable evidence (query
#                         failure, or multiple/malformed rows)
#
# The query itself now lives in lib/claim-guards.sh (#153 review P1 0D) so
# claim.sh's admission rollback runs the exact same read; this wrapper keeps
# release-claim.sh's own variable names and call sites unchanged.
query_remote_branch_exact() {
  local br="$1"
  REMOTE_BRANCH_STATUS=""
  REMOTE_BRANCH_OID=""
  REMOTE_BRANCH_REASON=""
  if ! guard_remote_branch_exact "$br"; then
    REMOTE_BRANCH_REASON="$GUARD_REMOTE_REASON"
    return 1
  fi
  REMOTE_BRANCH_STATUS="$GUARD_REMOTE_STATUS"
  REMOTE_BRANCH_OID="$GUARD_REMOTE_OID"
  return 0
}

# Full mutation + verification for a verified terminal PR-body claim. Called
# only after try_terminal_pr_body_release() has already bound exact PR
# number/head-branch/head-SHA/claim-id/issue/repository/cross-repo=false/
# terminal-state (#153 AC3). This function performs the safety proof (exact
# *registered* worktree bound by branch enumeration — never a guessed path,
# clean status revalidated immediately before removal, exact/contained head
# SHA, exact local/remote branch identity) BEFORE any worktree/branch/label
# mutation (#153 AC1), never rm -rf's an unregistered or default-path
# directory, never force-removes a dirty worktree, and — unlike the
# best-effort ledger-sibling lookup used elsewhere in this script — is
# fail-closed end to end: any GitHub query failure or malformed post-mutation
# evidence preserves agent-claimed and exits 3, never printing a success
# message (#153 AC4/AC5). Always exits the process (0 or 3); it never
# returns.
terminal_cleanup_release() {
  local id="$1" br
  # Consume the PR-evidence head branch stored after the branch_for equality
  # check. Never re-derive via branch_for (#271).
  br="${TERMINAL_HEAD_BRANCH:-}"
  [[ -n "$br" ]] ||
    die "terminal cleanup for '$id' has no stored PR-evidence head branch — refuse"

  # Re-assert the binding at the mutation boundary itself, not only where the
  # evidence was fetched (#153 review P1). This function is the only place
  # that removes a worktree or deletes a branch on PR evidence.
  require_canonical_repo_binding "$PR_REPO" "terminal cleanup for '$id'"

  [[ -z "$WORKTREE_PATH_ARG" ]] ||
    die "--worktree-path is not supported for a terminal PR-body claim release (claim-reaper CAS flow only)"

  local incomplete=0 preserve_label=0 safe=0 reason=""
  local wt="" wt_present=0 wt_removed=0

  # --- resolve the exact registered worktree, never a guessed path --------
  # (#153 blocker 1, #271 shared resolver)
  if ! resolve_cleanup_target "$br" "$id"; then
    reason="$CLEANUP_TARGET_REASON"
  elif [[ -n "$CLEANUP_TARGET_WT" ]]; then
    wt="$CLEANUP_TARGET_WT"
    wt_present=1
  fi

  # --- safety proof, before any mutation ----------------------------------
  if [[ -n "$reason" ]]; then
    :  # resolution above already failed; safe stays 0
  elif [[ "$wt_present" -eq 1 ]]; then
    local got_head status_out
    if ! status_out=$(git -C "$wt" status --porcelain 2>&1); then
      reason="cannot read worktree status ($status_out)"
    elif [[ -n "$status_out" ]]; then
      reason="worktree has uncommitted or untracked changes — refuse to remove a dirty worktree"
    else
      got_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
      if [[ -z "$got_head" ]]; then
        reason="cannot read worktree HEAD commit"
      elif [[ "$got_head" == "$TERMINAL_HEAD_SHA" ]]; then
        safe=1
      elif [[ "$TERMINAL_STATE" == "MERGED" && -n "$TERMINAL_MERGE_SHA" ]] &&
           { git -C "$wt" cat-file -e "$TERMINAL_MERGE_SHA" 2>/dev/null || git -C "$wt" fetch origin "$TERMINAL_MERGE_SHA" >/dev/null 2>&1; } &&
           git -C "$wt" merge-base --is-ancestor "$got_head" "$TERMINAL_MERGE_SHA" 2>/dev/null; then
        safe=1
      else
        reason="worktree HEAD ($got_head) is neither the exact terminal PR head SHA ($TERMINAL_HEAD_SHA) nor provably contained in the merged result (${TERMINAL_MERGE_SHA:-n/a}) — refuse"
      fi
    fi
  else
    safe=1  # no registered worktree for the exact branch — nothing unsafe to remove
  fi

  # --- branch identity proof (#153 blocker 3): a missing worktree does not
  # make an advanced/reused branch safe. Prove local/remote branch tip
  # identity against the terminal PR head SHA before any branch deletion —
  # exact equality, or (local only) provable containment in the merge result.
  #
  # local_branch_verified_oid carries the *exact* OID accepted right here
  # forward to the CAS delete below (blocker 2 of the second Codex review).
  # The deletion block must never re-derive its own expected-old value with a
  # fresh `git rev-parse` immediately before deleting: that would silently
  # accept whatever the branch advanced to between this proof and the delete
  # call as the "expected" value, since a value read from the ref always
  # trivially equals itself. Only a value fixed at proof time can catch an
  # advance in that window.
  local local_branch_verified_oid=""
  if [[ "$safe" -eq 1 && "$KEEP_BRANCH" -eq 0 ]]; then
    if git show-ref --verify --quiet "refs/heads/$br"; then
      local local_tip
      local_tip=$(git rev-parse --verify --quiet "refs/heads/$br" 2>/dev/null || true)
      if [[ -z "$local_tip" ]]; then
        safe=0
        reason="cannot read local branch '$br' tip commit"
      elif [[ "$local_tip" == "$TERMINAL_HEAD_SHA" ]]; then
        local_branch_verified_oid="$local_tip"
      elif [[ "$TERMINAL_STATE" == "MERGED" && -n "$TERMINAL_MERGE_SHA" ]] &&
           { git cat-file -e "$TERMINAL_MERGE_SHA" 2>/dev/null || git fetch origin "$TERMINAL_MERGE_SHA" >/dev/null 2>&1; } &&
           git merge-base --is-ancestor "$local_tip" "$TERMINAL_MERGE_SHA" 2>/dev/null; then
        local_branch_verified_oid="$local_tip"
      else
        safe=0
        reason="local branch '$br' tip ($local_tip) is neither the exact terminal PR head SHA ($TERMINAL_HEAD_SHA) nor provably contained in the merged result (${TERMINAL_MERGE_SHA:-n/a}) — refuse (advanced/reused branch)"
      fi
    fi
    if [[ "$safe" -eq 1 ]]; then
      if ! query_remote_branch_exact "$br"; then
        safe=0
        reason="$REMOTE_BRANCH_REASON"
      elif [[ "$REMOTE_BRANCH_STATUS" == "present" && "$REMOTE_BRANCH_OID" != "$TERMINAL_HEAD_SHA" ]]; then
        safe=0
        reason="remote branch '$br' OID ($REMOTE_BRANCH_OID) does not equal the terminal PR head SHA ($TERMINAL_HEAD_SHA) — refuse (advanced/reused branch)"
      fi
    fi
  fi

  # --- exact-PR-number proof, BEFORE the first destructive mutation ---------
  # (#153 review round 5, P1) The identity proofs above all come from the CLAIM
  # inventory or from git. The claim inventory only contains a PR while that PR
  # carries a well-formed claim marker, and `find-terminal[-pr]` reports the
  # state GitHub attached to the row it served — neither can distinguish "this
  # PR reached a terminal state" from "this PR is still wide open and its
  # marker/state evidence is stale, rewritten, or served from a replica that
  # has not caught up". The body-agnostic open-PR inventory can: it is keyed on
  # the PR NUMBER, which nothing in a PR body can forge.
  #
  # That proof used to run only AFTER the worktree was removed and both branch
  # refs were deleted, which made it a report rather than a gate: by the time
  # it said "PR #N is still open", the work behind the still-open PR was
  # already gone. It runs here instead, after the terminal evidence has been
  # bound and before the first irreversible removal, and it fails the ordinary
  # safety path — so an unreadable inventory or a still-open number preserves
  # the worktree, both branches, every ledger row and agent-claimed, exactly
  # like any other failed safety proof. The post-cleanup copy is retained below
  # as the TOCTOU/postcondition half: this one licenses the mutation, that one
  # proves the mutation did not race a reopen.
  if [[ "$safe" -eq 1 && -n "$TERMINAL_PR_NUMBER" ]]; then
    if ! read_open_pr_numbers "$PR_REPO"; then
      safe=0
      reason="cannot read the body-agnostic open pull-request inventory for $PR_REPO to prove PR #$TERMINAL_PR_NUMBER is no longer open — $OPEN_NUMBERS_ERR; an unreadable inventory is not proof a PR closed"
    elif open_pr_number_present "$TERMINAL_PR_NUMBER"; then
      safe=0
      reason="PR #$TERMINAL_PR_NUMBER is STILL OPEN in $PR_REPO even though its evidence says $TERMINAL_STATE — a removed, rewritten or stale claim marker is not a terminal PR, and the worktree/branches behind an open claim must not be destroyed"
    fi
  fi

  # --- same-ID ledger revalidation BEFORE first artifact mutation (#153 P1)
  # A renewed generation can reuse the claim id. Fetch and fully validate the
  # exact authoritative remote ledger immediately before the first worktree/
  # branch mutation; any surviving or newly appearing same-ID representation
  # means live/new-generation work — refuse all artifact and label mutation.
  # Generation identity is bound to PR number + head SHA, never claim id alone.
  if [[ "$safe" -eq 1 ]]; then
    local fresh_term_base fresh_term_ref fresh_term_live
    if ! fresh_term_base=$(fetch_remote_base); then
      safe=0
      reason="cannot fetch remote ledger base before terminal artifact mutation — refuse (no local/cached fallback)${CLEANUP_FETCH_REASON:+: $CLEANUP_FETCH_REASON}"
    else
      fresh_term_ref="origin/${fresh_term_base}"
      REF="$fresh_term_ref"
      CLEANUP_BASE="$fresh_term_base"
      if ! fresh_term_live=$(claim_ids_all); then
        safe=0
        reason="cannot read authoritative ledger at $fresh_term_ref before terminal artifact mutation — refuse"
      elif printf '%s\n' "$fresh_term_live" | grep -qxF -- "$id"; then
        safe=0
        reason="same-ID ledger row for '$id' is live at $fresh_term_ref before terminal artifact mutation — renewed/live generation; refuse worktree/branch/label mutation (bound to PR #$TERMINAL_PR_NUMBER head $TERMINAL_HEAD_SHA, not claim id alone)"
      fi
    fi
  fi

  if [[ "$safe" -ne 1 ]]; then
    warn "refusing terminal cleanup for '$id' (PR #$TERMINAL_PR_NUMBER, $TERMINAL_STATE): ${reason:-unknown safety failure}"
    warn "worktree and branch left untouched"
    incomplete=1
    preserve_label=1
  fi

  # --- helper: re-fetch + fully validate remote ledger for same-ID renewal ---
  # Used immediately before every independent destructive boundary. Any
  # unreadable evidence or renewed same-ID representation refuses that
  # mutation, preserves remaining artifacts and the label, and reports
  # INCOMPLETE. Generation identity is PR number + head SHA, never claim id.
  _term_ledger_same_id_clear() {
    local context="$1" base ref live
    if ! base=$(fetch_remote_base); then
      warn "cannot fetch remote ledger $context — refuse (no local/cached fallback)${CLEANUP_FETCH_REASON:+: $CLEANUP_FETCH_REASON}"
      return 1
    fi
    ref="origin/${base}"
    REF="$ref"
    CLEANUP_BASE="$base"
    if ! live=$(claim_ids_all); then
      warn "cannot read authoritative ledger at $ref $context — refuse (unreadable is not absence); preserve remaining artifacts and label"
      return 1
    fi
    if printf '%s\n' "$live" | grep -qxF -- "$id"; then
      warn "same-ID ledger row for '$id' is live at $ref $context — renewed/live generation; refuse remaining mutation (bound to PR #$TERMINAL_PR_NUMBER head $TERMINAL_HEAD_SHA, not claim id alone)"
      return 1
    fi
    return 0
  }

  # --- mutation (only after the safety proof above) -----------------------
  if [[ "$safe" -eq 1 ]]; then
    if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
      [[ "$wt_present" -eq 1 ]] && info "keeping worktree $wt (--keep-worktree)"
    elif [[ "$wt_present" -eq 1 ]]; then
      info "removing exact registered worktree $wt (terminal PR #$TERMINAL_PR_NUMBER, $TERMINAL_STATE)"
      # (#153 blocker 3) Close the dirty-worktree TOCTOU: revalidate not only
      # clean status but that the exact registered path still belongs to the
      # expected PR head branch and its HEAD is still the previously accepted
      # exact/contained commit ($got_head, proven safe above) — a concurrent
      # actor can dirty the tree, switch its branch, or move its HEAD in
      # exactly this window. Use non-force `git worktree remove` so Git itself
      # refuses a tree that went dirty after our own recheck. Never --force,
      # never rm -rf.
      #
      # The sensors that prove this window is really closed drive it from
      # OUTSIDE the script, through a `git` command shim on PATH that mutates
      # the tree as the revalidation runs. Production must not execute a
      # command named by an inherited environment variable to make a test
      # convenient (#153 review round 3, P1) — an env var that names an
      # executable IS an execution path, however it is documented.
      local revalidate_out revalidate_branch revalidate_head
      revalidate_branch=""
      if ! revalidate_out=$(git -C "$wt" status --porcelain 2>&1); then
        warn "cannot revalidate worktree status immediately before removal for $wt ($revalidate_out)"
        incomplete=1
        preserve_label=1
      elif [[ -n "$revalidate_out" ]]; then
        warn "worktree $wt became dirty between the safety proof and removal — refuse to remove (TOCTOU guard)"
        incomplete=1
        preserve_label=1
      elif ! worktree_registered "$wt"; then
        warn "worktree $wt is no longer a registered git worktree immediately before removal — refuse (TOCTOU guard)"
        incomplete=1
        preserve_label=1
      elif revalidate_branch=$(worktree_branch "$wt" || true) && [[ "$revalidate_branch" != "$br" ]]; then
        warn "worktree $wt switched off branch '$br' (now '${revalidate_branch:-detached/unknown}') between the safety proof and removal — refuse to remove (TOCTOU guard)"
        incomplete=1
        preserve_label=1
      elif ! revalidate_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || [[ -z "$revalidate_head" ]]; then
        warn "cannot re-read worktree HEAD immediately before removal for $wt"
        incomplete=1
        preserve_label=1
      elif [[ "$revalidate_head" != "$got_head" ]]; then
        warn "worktree $wt HEAD moved between the safety proof ($got_head) and removal ($revalidate_head) — refuse to remove (TOCTOU guard)"
        incomplete=1
        preserve_label=1
      # Immediate same-ID ledger revalidation AFTER the earlier safety proof
      # and immediately BEFORE the actual worktree-remove command. A renewal
      # in this exact window must preserve the worktree, branches, and label.
      elif ! _term_ledger_same_id_clear "immediately before worktree removal"; then
        incomplete=1
        preserve_label=1
      elif git worktree remove "$wt" 2>/dev/null; then
        git worktree prune 2>/dev/null || true
        if [[ -d "$wt" ]] || worktree_registered "$wt"; then
          warn "worktree $wt still present/registered immediately after removal — refuse to treat as removed"
          incomplete=1
          preserve_label=1
        else
          wt_removed=1
        fi
      else
        warn "git worktree remove failed for $wt — refuse rm -rf fallback"
        incomplete=1
        preserve_label=1
      fi
    fi
  fi

  # --- branch-deletion gate (#153 blocker 1/4): never delete the local or
  # remote branch unless the worktree phase either had nothing to remove, was
  # intentionally kept together with --keep-branch also disabled removal, or
  # completed and its removal postcondition was verified above. A dirty-hook
  # race, a failed `git worktree remove`, or a bare --keep-worktree without
  # --keep-branch must never fall through to branch deletion — that is
  # exactly how the remote branch used to be deleted while a dirty worktree
  # and its local branch survived.
  local wt_phase_ok=0
  if [[ "$safe" -eq 1 && "$incomplete" -eq 0 ]]; then
    if [[ "$wt_present" -eq 0 ]]; then
      wt_phase_ok=1
    elif [[ "$KEEP_WORKTREE" -eq 1 ]]; then
      if [[ "$KEEP_BRANCH" -eq 1 ]]; then
        wt_phase_ok=1
      else
        warn "refusing branch deletion for '$br' — --keep-worktree retained $wt but --keep-branch was not set; a retained worktree must not lose its branch"
        incomplete=1
        preserve_label=1
      fi
    elif [[ "$wt_removed" -eq 1 ]]; then
      wt_phase_ok=1
    fi
    # else: worktree removal was attempted above and failed/refused —
    # incomplete and preserve_label are already set by that block;
    # wt_phase_ok stays 0 and branch deletion below is skipped entirely.
  fi

  if [[ "$safe" -eq 1 && "$wt_phase_ok" -eq 1 && "$KEEP_BRANCH" -eq 0 ]]; then
    # Revalidate same-ID ledger between independent destructive steps (#153):
    # a concurrent actor can renew the claim id after worktree removal and
    # before local branch deletion. Unreadable evidence MUST disable branch
    # deletion (previous bug: claim_ids_all failure left deletion enabled).
    if ! _term_ledger_same_id_clear "between worktree and local branch mutation"; then
      incomplete=1
      preserve_label=1
      wt_phase_ok=0
    fi
  fi

  if [[ "$safe" -eq 1 && "$wt_phase_ok" -eq 1 && "$KEEP_BRANCH" -eq 0 ]]; then
    # (#153 blocker 2, hardened after the second Codex review) Check-then-
    # delete is a race: a branch can advance between the identity-proof above
    # and this delete. Use Git's own atomic compare-and-swap primitives so the
    # delete itself — not a separate shell comparison — is the safety
    # boundary. Never an unconditional delete, and never re-derive the
    # expected-old value with a fresh read taken here: local_branch_verified_
    # oid is the exact OID already accepted by the identity proof above, so an
    # advance any time between that proof and this delete (not just between a
    # fresh pre-delete read and the delete call) is caught.
    local local_cas_failed=0
    if [[ -n "$local_branch_verified_oid" ]]; then
      if ! git update-ref -d "refs/heads/$br" "$local_branch_verified_oid" 2>/dev/null; then
        warn "local branch CAS delete refused for '$br' — branch advanced since the safety proof (expected tip $local_branch_verified_oid) or delete failed"
        incomplete=1
        preserve_label=1
        local_cas_failed=1
      fi
    fi
    # A refused/failed local CAS delete must never be followed by a remote
    # delete in the same run: that is exactly how the remote branch could be
    # deleted while an advanced/reused local branch (and its content) survived.
    if [[ "$local_cas_failed" -eq 1 ]]; then
      warn "skipping remote branch CAS delete for '$br' — local branch CAS delete already failed/refused in this run"
    else
      # Re-fetch same-ID ledger again before remote branch deletion.
      if ! _term_ledger_same_id_clear "before remote branch mutation"; then
        incomplete=1
        preserve_label=1
      elif ! query_remote_branch_exact "$br"; then
        warn "cannot verify remote branch '$br' before deletion — refuse mutation: $REMOTE_BRANCH_REASON"
        incomplete=1
        preserve_label=1
      elif [[ "$REMOTE_BRANCH_STATUS" == "present" ]]; then
        # Exact expected-old lease bound to the verified terminal PR head SHA —
        # never a re-read value. A lease mismatch means the branch advanced/was
        # reused between the precheck and this delete.
        if ! git push --force-with-lease="refs/heads/${br}:${TERMINAL_HEAD_SHA}" origin ":refs/heads/${br}" >/dev/null 2>&1; then
          warn "remote branch CAS delete refused for '$br' — lease on $TERMINAL_HEAD_SHA rejected (branch advanced/reused since the precheck) or delete failed"
          incomplete=1
          preserve_label=1
        fi
      fi
    fi
  fi

  # --- fail-closed post-mutation reread: authoritative live-claim view ----
  # (ledger rows UNION live open PR-body claims, #153 AC8). Any query failure
  # or malformed result here preserves agent-claimed and refuses success —
  # the ordinary ledger path's best-effort `2>/dev/null || true` sibling
  # lookup below never applies once GitHub-native terminal evidence drove
  # this cleanup (#153 AC5).
  local sibling_ids="" open_rows fresh_ref fresh_live ledger_siblings="" malformed_row=""
  if ! open_rows=$("$SCRIPT_DIR/pr-claims.sh" list "$PR_REPO" 2>&1); then
    warn "post-mutation reread of live PR-body claims failed for $PR_REPO — cannot verify postcondition: $open_rows"
    incomplete=1
    preserve_label=1
  else
    # Every non-empty row must have exactly 8 tab-separated fields (pr-claims.sh
    # list's contract) and a non-empty issue-* claim id. A malformed/truncated
    # row is unreadable evidence, not proof the claim is gone — refuse rather
    # than silently skip it.
    if ! open_pr_rows_valid "$open_rows"; then
      malformed_row="$OPEN_PR_BAD_ROW"
    fi
    if [[ -n "$malformed_row" ]]; then
      warn "post-mutation reread of live PR-body claims returned a malformed/truncated row for $PR_REPO — cannot verify postcondition: $malformed_row"
      incomplete=1
      preserve_label=1
    elif printf '%s\n' "$open_rows" | awk -F'\t' -v want="$id" '$2==want{f=1} END{exit !f}'; then
      warn "claim '$id' unexpectedly reappeared as a live open PR-body claim after terminal cleanup — refuse success"
      incomplete=1
      preserve_label=1
    else
      while IFS=$'\t' read -r _n _cid _sc _hb _u _c _up _cross; do
        [[ -n "$_cid" ]] || continue
        [[ "$_cid" == "$id" ]] && continue
        claim_id_for_issue "$_cid" || continue
        sibling_ids="${sibling_ids}${_cid}"$'\n'
      done <<EOF
$open_rows
EOF
      sibling_ids=$(printf '%s\n' "$sibling_ids" | grep -E '^issue-' | sort -u || true)
    fi
  fi

  # --- the same postcondition, bound to the PR NUMBER (#153 review round 4)
  # The reread above asks the CLAIM inventory, which only contains a PR while
  # that PR carries a well-formed claim marker. A PR whose marker was removed
  # or rewritten drops out of it while staying wide open — indistinguishable
  # from a PR that reached a terminal state, and the difference is exactly
  # whether the issue is still held. Ask the body-agnostic open-PR inventory
  # about this claim's exact PR number too.
  #
  # This is the SECOND of the two exact-number proofs (#153 review round 5).
  # The first ran before the first destructive mutation and is what licensed
  # the cleanup at all; this one is the TOCTOU/postcondition half — it catches
  # a PR that was reopened, or an inventory that changed its mind, during the
  # mutation window. Keeping both is deliberate: a gate that only runs after
  # the removal cannot prevent the removal.
  if [[ -n "$TERMINAL_PR_NUMBER" ]]; then
    if ! read_open_pr_numbers "$PR_REPO"; then
      warn "cannot verify that PR #$TERMINAL_PR_NUMBER is absent from the open pull-request inventory for $PR_REPO — $OPEN_NUMBERS_ERR; refuse to report success"
      incomplete=1
      preserve_label=1
    elif open_pr_number_present "$TERMINAL_PR_NUMBER"; then
      warn "PR #$TERMINAL_PR_NUMBER is STILL OPEN in $PR_REPO although its claim marker no longer appears in the claim inventory — a removed or rewritten marker is not a terminal PR. Refuse to report success"
      incomplete=1
      preserve_label=1
    fi
  fi

  if git fetch origin >/dev/null 2>&1 && fresh_ref=$(resolve_ledger_ref); then
    REF="$fresh_ref"
    if fresh_live=$(claim_ids_all); then
      # (#153 exact-head P1) A surviving same-ID ledger row is live work, not
      # a residual to ignore. Terminal cleanup must preserve artifacts/label
      # when the exact target id is still present on the ledger.
      if printf '%s\n' "$fresh_live" | grep -qxF -- "$id"; then
        warn "same-ID ledger row for '$id' is still live after terminal cleanup — refuse artifact deletion success; preserving agent-claimed"
        incomplete=1
        preserve_label=1
      fi
      ledger_siblings=$(issue_claim_ids_from "$fresh_live" | grep -vxF -- "$id" || true)
    else
      warn "post-mutation ledger reread failed at $REF — cannot fully verify sibling policy"
      incomplete=1
      preserve_label=1
    fi
  else
    warn "post-mutation: cannot fetch/resolve ledger ref for a fresh sibling reread — cannot fully verify sibling policy"
    incomplete=1
    preserve_label=1
  fi

  local all_siblings
  all_siblings=$(printf '%s\n%s\n' "$sibling_ids" "$ledger_siblings" | grep -E '^issue-' | sort -u || true)

  # --- verify exact postconditions ----------------------------------------
  # (#153 blocker 4) A remote query failure here is unreadable evidence, not
  # proof of absence — never let it pass the postcondition silently.
  if [[ "$incomplete" -eq 0 ]]; then
    if [[ "$KEEP_WORKTREE" -eq 0 && "$wt_present" -eq 1 ]]; then
      if [[ -d "$wt" ]] || worktree_registered "$wt"; then
        warn "postcondition failed: worktree $wt still present/registered after removal"
        incomplete=1
        preserve_label=1
      fi
    fi
    if [[ "$KEEP_BRANCH" -eq 0 ]]; then
      if git show-ref --verify --quiet "refs/heads/$br"; then
        warn "postcondition failed: local branch $br still present after deletion"
        incomplete=1
        preserve_label=1
      fi
      if ! query_remote_branch_exact "$br"; then
        warn "postcondition: cannot verify remote branch $br absence after deletion — refuse success: $REMOTE_BRANCH_REASON"
        incomplete=1
        preserve_label=1
      elif [[ "$REMOTE_BRANCH_STATUS" == "present" ]]; then
        warn "postcondition failed: remote branch $br still present after deletion"
        incomplete=1
        preserve_label=1
      fi
    fi
  fi

  # --- label policy ---------------------------------------------------------
  if command -v gh >/dev/null; then
    local repo="$PR_REPO"
    if [[ "$preserve_label" -eq 1 || "$incomplete" -eq 1 ]]; then
      info "preserving agent-claimed on #$ISSUE — terminal cleanup incomplete or unverifiable"
    elif [[ -n "$all_siblings" ]]; then
      # (#153 blocker 5) A sibling claim surviving does not by itself prove
      # the label is actually present — re-read GitHub rather than assume.
      LABELS=$(gh issue view "$ISSUE" --repo "$repo" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$LABELS" == "?" ]]; then
        warn "could not read labels on $repo#$ISSUE — sibling-claim label preservation UNVERIFIED"
        incomplete=1
      elif ! echo ",$LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is ABSENT on $repo#$ISSUE — sibling claim(s) remain but the label is missing; re-add it by hand"
        incomplete=1
      else
        info "keeping agent-claimed on #$ISSUE — sibling claim(s) remain (verified):"
        printf '%s\n' "$all_siblings" | sed 's/^/  /'
      fi
    elif [[ "$KEEP_LABEL" -eq 1 ]]; then
      LABELS=$(gh issue view "$ISSUE" --repo "$repo" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$LABELS" == "?" ]]; then
        warn "could not read labels on $repo#$ISSUE — --keep-label preservation UNVERIFIED"
        incomplete=1
      elif ! echo ",$LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is ABSENT on $repo#$ISSUE — --keep-label required the label to stay"
        incomplete=1
      else
        info "keeping agent-claimed on $repo#$ISSUE — --keep-label verified"
      fi
    else
      if ! gh issue edit "$ISSUE" --repo "$repo" --remove-label agent-claimed; then
        warn "gh issue edit failed for #$ISSUE in $repo"
      fi
      LABELS=$(gh issue view "$ISSUE" --repo "$repo" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$LABELS" == "?" ]]; then
        warn "could not re-read labels on #$ISSUE — agent-claimed removal UNVERIFIED"
        incomplete=1
      elif echo ",$LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is STILL on $repo#$ISSUE — remove it by hand"
        incomplete=1
      else
        info "removed agent-claimed from $repo#$ISSUE (verified)"
      fi
    fi
  else
    if [[ "$preserve_label" -eq 1 || "$incomplete" -eq 1 ]]; then
      info "gh not found — agent-claimed left in place (incomplete cleanup)"
    elif [[ -n "$all_siblings" ]]; then
      warn "gh not found — agent-claimed left in place for sibling claim(s) on #$ISSUE, but its presence could NOT be verified"
      incomplete=1
    else
      warn "gh not found — agent-claimed NOT removed from #$ISSUE"
      incomplete=1
    fi
  fi

  if [[ "$incomplete" -eq 1 ]]; then
    echo "release-claim.sh: INCOMPLETE — terminal cleanup did not finish for issue $ISSUE (see warnings above)" >&2
    exit 3
  fi

  info "OK — claim released for issue $ISSUE (terminal PR-body claim, PR #$TERMINAL_PR_NUMBER, no ledger row involved)"
  exit 0
}

# Filter a newline list of ids down to those belonging to this issue.
issue_claim_ids_from() {
  local id
  printf '%s\n' "$1" | while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if claim_id_for_issue "$id"; then
      printf '%s\n' "$id"
    fi
  done | sort -u
}

# GitHub-native claims live in open PR bodies. Close the owning PR to release
# them; the legacy ledger path below remains for back-compat.
#
# (#153) This block used to sit far earlier in the file, before the ledger ref
# was even resolved, which is why it grew its own private cleanup: a worktree
# path GUESSED from the claim id, `git worktree remove --force`, and two
# `|| true` branch deletes, followed by an unconditional "released PR-body
# claim". It now runs here, after every helper is defined, so closing the PR
# hands straight over to terminal_cleanup_release() — the same exact,
# verified machinery the terminal path uses (registered-worktree resolution
# by branch enumeration, dirty/TOCTOU revalidation, head-SHA containment
# proof, CAS branch deletes, fail-closed postcondition rereads). The only
# thing it costs is a resolvable ledger ref, which the terminal path already
# required anyway. Where that handover cannot be made safely, the fallback is
# close-only plus an honest INCOMPLETE — never a success message over
# unproven cleanup.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# --- repository identity of the canonical checkout (#153 review P1) --------
# Normalize a git remote URL to its github.com owner/name identity, or fail.
# Handles every form a real origin carries: https(+userinfo/token), http,
# ssh:// (with optional port), git://, and the scp-like git@host:owner/name.
# A trailing .git and a trailing slash are stripped; a non-github.com host, a
# path that is not exactly two segments, or an unsafe segment fails (return 1)
# rather than producing a half-parsed identity.
normalize_github_repo_url() {
  local url="$1" rest hostport host path owner name
  [[ -n "$url" ]] || return 1
  case "$url" in
    https://*|http://*)  rest="${url#*://}"; rest="${rest#*@}" ;;
    ssh://*)             rest="${url#ssh://}"; rest="${rest#*@}" ;;
    git://*)             rest="${url#git://}"; rest="${rest#*@}" ;;
    */*:*)               return 1 ;;   # a path that merely contains a colon
    *:*)
      # scp-like [user@]host:owner/name — the FIRST colon is the separator.
      rest="${url#*@}"
      rest="${rest%%:*}/${rest#*:}"
      ;;
    *) return 1 ;;
  esac
  [[ "$rest" == */* ]] || return 1
  hostport="${rest%%/*}"
  path="${rest#*/}"
  host="${hostport%%:*}"
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  case "$host" in
    github.com|www.github.com|ssh.github.com) ;;
    *) return 1 ;;
  esac
  path="${path%/}"
  path="${path%.git}"
  path="${path%/}"
  [[ "$path" == */* ]] || return 1
  owner="${path%%/*}"
  name="${path#*/}"
  [[ "$name" != */* ]] || return 1        # more than owner/name — refuse
  [[ "$owner" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s/%s\n' "$owner" "$name"
}

# Resolve GIBSON_CANONICAL's own origin repository identity. Always returns 0;
# the verdict is in CANON_REPO_STATUS:
#   github     — CANON_REPO_ID holds owner/name
#   non-github — origin exists and is readable but is not a github.com repo
#                (a determinate answer: no PR-body claim can live here)
#   unreadable — no origin, multi-valued origin, or an insteadOf rewrite that
#                points at a DIFFERENT github repo (ambiguous identity)
# Only "github" may authorize PR-evidence-driven mutation.
CANON_REPO_ID=""
CANON_REPO_STATUS=""
CANON_REPO_REASON=""
resolve_canonical_repo_identity() {
  local raw all n eff raw_id eff_id rc=0
  CANON_REPO_ID=""
  CANON_REPO_STATUS=""
  CANON_REPO_REASON=""
  # --get-all, not --get: with several remote.origin.url values `git config
  # --get` silently returns the LAST one and exits 0, so a checkout wired to
  # two different repositories would answer with one of them and look
  # perfectly definite. More than one value is ambiguous identity — refuse.
  all=$(git config --get-all remote.origin.url 2>/dev/null) || rc=$?
  n=$(printf '%s' "$all" | grep -c . || true)
  if [[ "$rc" -eq 0 && "$n" -gt 1 ]]; then
    CANON_REPO_STATUS="unreadable"
    CANON_REPO_REASON="remote.origin.url is configured $n times in $CANONICAL — ambiguous origin identity"
    return 0
  fi
  raw=$(printf '%s\n' "$all" | head -n1)
  if [[ "$rc" -ne 0 || -z "$raw" ]]; then
    CANON_REPO_STATUS="unreadable"
    CANON_REPO_REASON="no readable origin remote in $CANONICAL (git config remote.origin.url is unset or unreadable)"
    return 0
  fi
  if ! raw_id=$(normalize_github_repo_url "$raw"); then
    CANON_REPO_STATUS="non-github"
    CANON_REPO_REASON="origin URL '$raw' is not a github.com repository URL"
    return 0
  fi
  # An insteadOf rewrite is operator-owned local config, not a trust boundary,
  # so a rewrite to a non-GitHub destination (a mirror, a test bare repo) is
  # accepted. A rewrite to a DIFFERENT github.com repository is genuinely
  # ambiguous about which repository this checkout is — refuse that.
  eff=$(git ls-remote --get-url origin 2>/dev/null || true)
  if [[ -n "$eff" && "$eff" != "$raw" ]] && eff_id=$(normalize_github_repo_url "$eff"); then
    if [[ "$(printf '%s' "$eff_id" | tr '[:upper:]' '[:lower:]')" != \
          "$(printf '%s' "$raw_id" | tr '[:upper:]' '[:lower:]')" ]]; then
      CANON_REPO_STATUS="unreadable"
      CANON_REPO_REASON="origin URL '$raw' ($raw_id) is rewritten to '$eff' ($eff_id) — ambiguous repository identity"
      return 0
    fi
  fi
  CANON_REPO_ID="$raw_id"
  CANON_REPO_STATUS="github"
  return 0
}

# Is PR-body evidence from repository $1 bound to THIS checkout? Containing
# the same branch name and the same commits is what a fork/copy does by
# construction — it is not identity (#153 review P1). Returns 1 with
# BINDING_REASON set; never mutates anything either way.
BINDING_REASON=""
canonical_repo_binding_ok() {
  local repo="$1" want got
  BINDING_REASON=""
  case "$CANON_REPO_STATUS" in
    github) ;;
    non-github)
      BINDING_REASON="$CANONICAL has no GitHub repository identity — $CANON_REPO_REASON; PR-body claim evidence from '$repo' cannot be bound to this checkout"
      return 1
      ;;
    *)
      BINDING_REASON="cannot read the origin repository identity of $CANONICAL — $CANON_REPO_REASON; PR-body claim evidence from '$repo' cannot be bound to this checkout"
      return 1
      ;;
  esac
  want=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
  got=$(printf '%s' "$CANON_REPO_ID" | tr '[:upper:]' '[:lower:]')
  if [[ "$want" != "$got" ]]; then
    BINDING_REASON="repository binding mismatch — GIBSON_CANONICAL ($CANONICAL) has origin repository '$CANON_REPO_ID', but the PR-body claim evidence comes from '$repo'. A fork or copy that merely contains the same branch and the same commits is NOT the same repository"
    return 1
  fi
  return 0
}

# Hard gate for the paths that are about to mutate (close a PR, remove a
# worktree, delete a branch): an unbound repository stops the run before the
# first mutation rather than being reported afterwards.
require_canonical_repo_binding() {
  local repo="$1" ctx="$2"
  canonical_repo_binding_ok "$repo" ||
    die "$ctx: $BINDING_REASON — refuse (nothing was mutated)"
}

resolve_canonical_repo_identity

# Repository identity is never swallowed (#153 review P1): --repo wins, then
# gh's own answer, then this checkout's origin identity. If none of those can
# answer and the origin is unreadable, stop here — before any worktree,
# branch, ledger, or label mutation — rather than silently skipping the
# authoritative PR-claim inventory and cleaning up on a view we never read.
PR_REPO=""
if [[ -n "$REPO_ARG" ]]; then
  PR_REPO="$REPO_ARG"
elif command -v gh >/dev/null 2>&1; then
  GH_REPO_OUT=""
  if GH_REPO_OUT=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>&1) &&
     GH_REPO_OUT=$(printf '%s\n' "$GH_REPO_OUT" | head -n1 | tr -d '[:space:]') &&
     [[ -n "$GH_REPO_OUT" ]]; then
    PR_REPO="$GH_REPO_OUT"
  else
    case "$CANON_REPO_STATUS" in
      github)
        PR_REPO="$CANON_REPO_ID"
        info "gh repo view could not resolve the repository; using $CANONICAL's own origin identity ($PR_REPO)"
        ;;
      non-github)
        info "$CANONICAL has no GitHub repository identity ($CANON_REPO_REASON) — no PR-body claim can live here; reading the ledger only"
        ;;
      *)
        die "cannot resolve the GitHub repository identity for $CANONICAL — $CANON_REPO_REASON; 'gh repo view' also failed. Pass --repo owner/name. Refuse to mutate anything on an unresolved repository identity."
        ;;
    esac
  fi
fi
if [[ -n "$PR_REPO" && ! "$PR_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  die "resolved repository identity '$PR_REPO' is not owner/name — refuse to mutate anything on an unusable repository identity"
fi

# Shape contract for `pr-claims.sh list` output: every non-empty row carries
# exactly 8 tab-separated fields, a non-empty issue-* claim id, and a
# cross-repository column that is literally `true` or `false`. A truncated or
# otherwise malformed row is unreadable evidence about who holds this issue —
# never proof that nobody does. Sets OPEN_PR_BAD_ROW and returns 1.
#
# The 8th column is repository identity (#153 review round 5, P1). It is
# shape-checked here rather than only where it is consumed, so a row that
# cannot say which repository its PR lives in never reaches a mutation
# decision at all.
OPEN_PR_BAD_ROW=""
open_pr_rows_valid() {
  local rows="$1" row fields id cross
  OPEN_PR_BAD_ROW=""
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    fields=$(awk -F'\t' '{print NF}' <<<"$row")
    id=$(awk -F'\t' '{print $2}' <<<"$row")
    cross=$(awk -F'\t' '{print $8}' <<<"$row")
    if [[ "$fields" -ne 8 || -z "$id" || ! "$id" =~ ^issue- ]]; then
      OPEN_PR_BAD_ROW="$row"
      return 1
    fi
    if [[ "$cross" != "true" && "$cross" != "false" ]]; then
      OPEN_PR_BAD_ROW="$row"
      return 1
    fi
  done <<EOF
$rows
EOF
  return 0
}

# --- open-PR-number binding for the post-close proof (#153 review round 4) ---
# `pr-claims.sh list` only sees a PR once that PR carries a well-formed claim
# marker, so "the claim id is gone from the inventory" is satisfied by BOTH of
# these:
#   * the PR really did close (what we want to prove), and
#   * the PR is still wide open and someone removed or rewrote its marker.
# The second is a hostile, silent false success: the issue is still held by a
# live PR while this run reports the claim released and strips agent-claimed.
# So the post-close proof binds to the exact PR NUMBER as well as the exact
# claim id, using a body-agnostic open-PR inventory.
#
# Sets OPEN_NUMBERS on success (possibly empty). Sets OPEN_NUMBERS_ERR and
# returns 1 when the read failed or returned anything that is not a bare
# decimal — an unreadable or malformed open-PR inventory is not proof that a
# PR closed, and every caller treats it as refuse-to-succeed.
OPEN_NUMBERS=""
OPEN_NUMBERS_ERR=""
read_open_pr_numbers() {
  local repo="$1" out line
  OPEN_NUMBERS=""
  OPEN_NUMBERS_ERR=""
  if [[ ! -x "$SCRIPT_DIR/pr-claims.sh" ]]; then
    OPEN_NUMBERS_ERR="the authoritative PR reader $SCRIPT_DIR/pr-claims.sh is missing or not executable"
    return 1
  fi
  if ! out=$("$SCRIPT_DIR/pr-claims.sh" list-open-numbers "$repo" 2>&1); then
    OPEN_NUMBERS_ERR="cannot read the open pull-request inventory for $repo: $out"
    return 1
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ ! "$line" =~ ^[0-9]+$ ]]; then
      OPEN_NUMBERS_ERR="the open pull-request inventory for $repo returned a non-numeric row '$line'"
      return 1
    fi
  done <<EOF
$out
EOF
  OPEN_NUMBERS="$out"
  return 0
}

# True when PR number $1 is still listed as open. Callers must have already
# proven the read itself succeeded via read_open_pr_numbers.
open_pr_number_present() {
  printf '%s\n' "$OPEN_NUMBERS" | grep -qxF -- "$1"
}

# Bound open-PR evidence for one exact claim id + PR number (#153 freeze P1).
# Calls pr-claims.sh find-open-pr and validates every identity field the
# close path depends on. Sets OPEN_EV_* on success (return 0). On failure
# sets OPEN_EV_ERR and returns 1 — never partial evidence.
OPEN_EV_NUMBER=""
OPEN_EV_CLAIM=""
OPEN_EV_SCOPE=""
OPEN_EV_ISSUE=""
OPEN_EV_HEAD=""
OPEN_EV_HEAD_SHA=""
OPEN_EV_URL=""
OPEN_EV_STATE=""
OPEN_EV_CROSS=""
OPEN_EV_BASE_REPO=""
OPEN_EV_ERR=""
read_bound_open_pr_evidence() {
  local id="$1" num="$2" rows count reader_rc=0
  local o_number o_claim o_scope o_issue o_head o_sha o_url o_state o_cross o_base
  OPEN_EV_NUMBER=""
  OPEN_EV_CLAIM=""
  OPEN_EV_SCOPE=""
  OPEN_EV_ISSUE=""
  OPEN_EV_HEAD=""
  OPEN_EV_HEAD_SHA=""
  OPEN_EV_URL=""
  OPEN_EV_STATE=""
  OPEN_EV_CROSS=""
  OPEN_EV_BASE_REPO=""
  OPEN_EV_ERR=""
  if [[ ! -x "$SCRIPT_DIR/pr-claims.sh" ]]; then
    OPEN_EV_ERR="the authoritative PR reader $SCRIPT_DIR/pr-claims.sh is missing or not executable"
    return 1
  fi
  reader_rc=0
  _rc_capture_streams "$SCRIPT_DIR/pr-claims.sh" find-open-pr "$PR_REPO" "$id" "$num" || reader_rc=$?
  rows="$_RC_CAP_STDOUT"
  if [[ "$reader_rc" -ne 0 ]]; then
    OPEN_EV_ERR="cannot read bound open PR evidence for '$id' on PR #$num in $PR_REPO: ${_RC_CAP_STDERR}"
    return 1
  fi
  count=$(printf '%s' "$rows" | grep -c . || true)
  if [[ "$count" -eq 0 ]]; then
    OPEN_EV_ERR="no bound open PR evidence for claim '$id' on PR #$num in $PR_REPO (PR missing, not OPEN, or not carrying that claim)"
    return 1
  fi
  if [[ "$count" -gt 1 ]]; then
    OPEN_EV_ERR="ambiguous bound open PR evidence for '$id' on PR #$num ($count rows) — refuse"
    return 1
  fi
  o_number=$(cut -f1 <<<"$rows")
  o_claim=$(cut -f2 <<<"$rows")
  o_scope=$(cut -f3 <<<"$rows")
  o_issue=$(cut -f4 <<<"$rows")
  o_head=$(cut -f5 <<<"$rows")
  o_sha=$(cut -f6 <<<"$rows")
  o_url=$(cut -f7 <<<"$rows")
  o_state=$(cut -f8 <<<"$rows")
  o_cross=$(cut -f9 <<<"$rows")
  o_base=$(cut -f10 <<<"$rows")
  if [[ -z "$o_number" || -z "$o_claim" || -z "$o_scope" || -z "$o_issue" || -z "$o_head" || -z "$o_sha" || -z "$o_url" || -z "$o_state" || -z "$o_cross" || -z "$o_base" ]]; then
    OPEN_EV_ERR="malformed/truncated bound open PR evidence for '$id' on PR #$num"
    return 1
  fi
  if [[ "$o_number" != "$num" ]]; then
    OPEN_EV_ERR="bound open evidence returned PR #${o_number}, want #$num — refuse"
    return 1
  fi
  if [[ "$o_claim" != "$id" ]]; then
    OPEN_EV_ERR="bound open evidence claim id mismatch (want '$id', got '$o_claim') — refuse"
    return 1
  fi
  if [[ "$o_issue" != "$ISSUE" ]]; then
    OPEN_EV_ERR="bound open evidence issue mismatch (want #$ISSUE, got #${o_issue}) — refuse"
    return 1
  fi
  if [[ "$o_state" != "OPEN" ]]; then
    OPEN_EV_ERR="bound open evidence for PR #$num is not OPEN (state='$o_state') — refuse"
    return 1
  fi
  if [[ "$o_cross" != "false" ]]; then
    OPEN_EV_ERR="bound open evidence for PR #$num is not provably same-repository (isCrossRepository='$o_cross', want 'false') — refuse"
    return 1
  fi
  if [[ "$o_base" != "$PR_REPO" ]]; then
    OPEN_EV_ERR="bound open evidence base-repository mismatch (want '$PR_REPO', got '$o_base') — refuse"
    return 1
  fi
  if [[ ! "$o_head" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    OPEN_EV_ERR="bound open evidence has unsafe/empty head branch '${o_head}' — refuse"
    return 1
  fi
  if [[ ! "$o_sha" =~ ^[0-9a-f]{40}$ ]]; then
    OPEN_EV_ERR="bound open evidence has malformed/missing head SHA '${o_sha}' — refuse"
    return 1
  fi
  # URL must bind to this repository and this PR number (same contract list
  # enforces; re-checked here so a hostile reader cannot skip it).
  if [[ ! "$o_url" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]]; then
    OPEN_EV_ERR="bound open evidence has malformed PR URL '${o_url}' — refuse"
    return 1
  fi
  if [[ "${BASH_REMATCH[1]}" != "$PR_REPO" || "${BASH_REMATCH[2]}" != "$num" ]]; then
    OPEN_EV_ERR="bound open evidence PR URL does not bind to $PR_REPO PR #$num (url='$o_url') — refuse"
    return 1
  fi
  OPEN_EV_NUMBER="$o_number"
  OPEN_EV_CLAIM="$o_claim"
  OPEN_EV_SCOPE="$o_scope"
  OPEN_EV_ISSUE="$o_issue"
  OPEN_EV_HEAD="$o_head"
  OPEN_EV_HEAD_SHA="$o_sha"
  OPEN_EV_URL="$o_url"
  OPEN_EV_STATE="$o_state"
  OPEN_EV_CROSS="$o_cross"
  OPEN_EV_BASE_REPO="$o_base"
  return 0
}

# ===========================================================================
# Authoritative union / revalidation primitive (#153 exact-head P1)
# ===========================================================================
# ONE fail-closed primitive for every decision that can close a PR, strip a
# ledger row, delete an artifact, or remove a label. Defined before the open
# PR path so pre-close union validation can call it. No helper may bypass.
#
# Contract:
#   * Mixed per-file + legacy for one id → refuse
#   * One (or more) open PR(s) + any same-ID ledger form → refuse
#     (generation identity is never inferred from claim id alone)
#   * Two+ open PRs with the same exact id → refuse
#   * Unreadable PR inventory or ledger tree → refuse
# On refusal: UNION_REFUSE_REASON is set; return 1. On success: return 0.
# Tri-state representation predicates (#153 exact-head):
#   return 0 = present
#   return 1 = absent
#   return 2 = unreadable
# Unreadable must never collapse to absent/zero representations.
ledger_has_file_rep() {
  local id="$1" ref="${2:-$REF}" ls_out mode typ obj
  if ! ls_out=$(git ls-tree "$ref" -- "docs/claims/${id}.md" 2>&1); then
    return 2
  fi
  if [[ -z "$ls_out" ]]; then
    return 1
  fi
  mode=$(printf '%s\n' "$ls_out" | awk '{print $1; exit}')
  typ=$(printf '%s\n' "$ls_out" | awk '{print $2; exit}')
  obj=$(printf '%s\n' "$ls_out" | awk '{print $3; exit}')
  if [[ "$typ" != "blob" || -z "$obj" ]]; then
    return 2
  fi
  if ! git cat-file -e "$obj" 2>/dev/null; then
    return 2
  fi
  if ! git cat-file blob "$obj" >/dev/null 2>&1; then
    return 2
  fi
  return 0
}
ledger_has_legacy_rep() {
  local id="$1" ref="${2:-$REF}" ls_out active_out obj
  if ! ls_out=$(git ls-tree "$ref" -- docs/active-work.md 2>&1); then
    return 2
  fi
  if [[ -z "$ls_out" ]]; then
    return 1
  fi
  obj=$(printf '%s\n' "$ls_out" | awk '{print $3; exit}')
  if [[ -z "$obj" ]] || ! git cat-file -e "$obj" 2>/dev/null; then
    return 2
  fi
  if ! active_out=$(git show "${ref}:docs/active-work.md" 2>&1); then
    return 2
  fi
  if printf '%s\n' "$active_out" | awk -F'|' -v want="$id" '
    /^\|/ {
      cid=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",cid);
      if (cid==want) found=1
    }
    END { exit !found }
  '; then
    return 0
  fi
  return 1
}

# Count ledger representations for one id at an exact ref.
# Sets: LEDGER_FILE_REP (0|1), LEDGER_LEGACY_REP (0|1), LEDGER_ANY_REP (0|1)
# Returns 2 when any authority read failed — caller must refuse (unreadable
# is not absence / zero representations).
count_ledger_reps_at_ref() {
  local id="$1" ref="$2" fr=0 lr=0
  LEDGER_FILE_REP=0
  LEDGER_LEGACY_REP=0
  LEDGER_ANY_REP=0
  ledger_has_file_rep "$id" "$ref"
  fr=$?
  if [[ "$fr" -eq 2 ]]; then
    return 2
  fi
  [[ "$fr" -eq 0 ]] && LEDGER_FILE_REP=1
  ledger_has_legacy_rep "$id" "$ref"
  lr=$?
  if [[ "$lr" -eq 2 ]]; then
    return 2
  fi
  [[ "$lr" -eq 0 ]] && LEDGER_LEGACY_REP=1
  if [[ "$LEDGER_FILE_REP" -eq 1 || "$LEDGER_LEGACY_REP" -eq 1 ]]; then
    LEDGER_ANY_REP=1
  fi
  return 0
}

# Fresh, fully validated open-PR inventory read. Sets PR_ROWS on success.
# On failure: UNION_REFUSE_REASON set, return 1. Empty inventory is success
# with PR_ROWS="".
read_fresh_pr_inventory() {
  local repo="${1:-$PR_REPO}" out
  UNION_REFUSE_REASON=""
  PR_ROWS=""
  if [[ -z "$repo" ]]; then
    return 0
  fi
  if [[ ! -x "$SCRIPT_DIR/pr-claims.sh" ]]; then
    UNION_REFUSE_REASON="the authoritative PR-claim reader $SCRIPT_DIR/pr-claims.sh is missing or not executable — refuse on unread claim view"
    return 1
  fi
  if ! out=$("$SCRIPT_DIR/pr-claims.sh" list "$repo" 2>&1); then
    UNION_REFUSE_REASON="cannot read live PR-body claims for $repo — an unreadable claim inventory is not an empty one: $out"
    return 1
  fi
  open_pr_rows_valid "$out" || {
    UNION_REFUSE_REASON="live PR-body claim inventory for $repo returned a malformed/truncated row: $OPEN_PR_BAD_ROW"
    return 1
  }
  PR_ROWS="$out"
  return 0
}

# Validate complete authoritative union for the given claim ids against
# pr_rows + ledger at exact_ref. soft=0 dies; soft=1 sets reason and returns 1.
validate_authoritative_union() {
  local ids="$1" pr_rows="$2" exact_ref="$3" context="${4:-union}" soft="${5:-0}"
  local _uid _u_open_n _u_open_nums pr_row pr_id pr_number reason=""
  UNION_REFUSE_REASON=""
  [[ -n "$ids" ]] || return 0
  [[ -n "$exact_ref" ]] || {
    reason="authoritative union ($context): empty exact ledger ref — refuse"
    UNION_REFUSE_REASON="$reason"
    if [[ "$soft" -eq 1 ]]; then return 1; fi
    die "$reason"
  }
  while IFS= read -r _uid; do
    [[ -n "$_uid" ]] || continue
    if ! count_ledger_reps_at_ref "$_uid" "$exact_ref"; then
      reason="REFUSE unreadable ledger representation evidence for '$_uid' at $exact_ref ($context) — refuse all mutation (unreadable is not absence)"
      UNION_REFUSE_REASON="$reason"
      if [[ "$soft" -eq 1 ]]; then return 1; fi
      die "$reason"
    fi
    if [[ "$LEDGER_FILE_REP" -eq 1 && "$LEDGER_LEGACY_REP" -eq 1 ]]; then
      reason="REFUSE ambiguous mixed ledger representations for '$_uid' (both docs/claims/${_uid}.md and docs/active-work.md) at $exact_ref ($context) — refuse all mutation; preserve both representations, label, worktree, and branches"
      UNION_REFUSE_REASON="$reason"
      if [[ "$soft" -eq 1 ]]; then return 1; fi
      die "$reason"
    fi
    _u_open_n=0
    _u_open_nums=""
    while IFS= read -r pr_row; do
      [[ -n "$pr_row" ]] || continue
      pr_id=$(cut -f2 <<<"$pr_row")
      pr_number=$(cut -f1 <<<"$pr_row")
      [[ "$pr_id" == "$_uid" ]] || continue
      _u_open_n=$((_u_open_n + 1))
      _u_open_nums="${_u_open_nums}#${pr_number} "
    done <<EOF
$pr_rows
EOF
    if [[ "$_u_open_n" -gt 1 ]]; then
      reason="REFUSE ambiguous exact claim id '$_uid' across open PR union (${_u_open_n} open PRs: ${_u_open_nums}) ($context) — refuse all mutation"
      UNION_REFUSE_REASON="$reason"
      if [[ "$soft" -eq 1 ]]; then return 1; fi
      die "$reason"
    fi
    # One open PR + any same-ID ledger representation is always ambiguous:
    # claim id alone is not generation identity. Prefer unconditional refuse.
    if [[ "$_u_open_n" -ge 1 && "$LEDGER_ANY_REP" -eq 1 ]]; then
      reason="REFUSE exact claim id '$_uid' is live both as open PR (${_u_open_nums}) and ledger representation(s) (file=$LEDGER_FILE_REP legacy=$LEDGER_LEGACY_REP) at $exact_ref ($context) — refuse all mutation; preserve PR, ledger, label, worktree, and branches"
      UNION_REFUSE_REASON="$reason"
      if [[ "$soft" -eq 1 ]]; then return 1; fi
      die "$reason"
    fi
  done <<EOF
$ids
EOF
  return 0
}

# Soft variant for post-mutation / strip boundary: warn + return 1, no die.
# mode (optional 4th arg):
#   pre-strip (default) — same-ID OR same-issue open PR refuses (CAS protect)
#   post-push           — only same-ID open PR refuses; same-issue residual
#                         open PRs are residual live work for label policy,
#                         not a reason to block artifact cleanup of a target
#                         already stripped from the ledger
revalidate_authoritative_union_soft() {
  local ids="$1" exact_ref="$2" context="$3" mode="${4:-pre-strip}"
  local pr_rows=""
  if [[ -n "${PR_REPO:-}" ]]; then
    # Fresh inventory policy (#153 exact-head):
    # ALWAYS re-list before irreversible ledger mutation (pre-strip) and after
    # push (post-push). Never reuse the startup PR_ROWS snapshot — a late-open
    # same-ID or same-issue PR after that snapshot and before the strip/push
    # boundary must be visible and refuse. CAS and non-CAS share this path.
    if ! read_fresh_pr_inventory "$PR_REPO"; then
      warn "revalidate union ($context): $UNION_REFUSE_REASON"
      return 1
    fi
    pr_rows="$PR_ROWS"
  fi
  if ! validate_authoritative_union "$ids" "$pr_rows" "$exact_ref" "$context" 1; then
    warn "revalidate union ($context): $UNION_REFUSE_REASON"
    return 1
  fi
  if [[ -n "$pr_rows" ]]; then
    local pr_row pr_id pr_number
    while IFS= read -r pr_row; do
      [[ -n "$pr_row" ]] || continue
      pr_id=$(cut -f2 <<<"$pr_row")
      pr_number=$(cut -f1 <<<"$pr_row")
      [[ -n "$pr_id" ]] || continue
      if printf '%s\n' "$ids" | grep -qxF -- "$pr_id"; then
        # Same-ID open PR always protects — claim id is not generation identity.
        UNION_REFUSE_REASON="open PR #$pr_number carries exact claim id '$pr_id' ($context)"
        warn "revalidate union ($context): $UNION_REFUSE_REASON"
        return 1
      elif [[ "$mode" != "post-push" ]] && claim_id_for_issue "$pr_id"; then
        # Pre-strip: same-issue open PR also protects the ledger row.
        UNION_REFUSE_REASON="open PR #$pr_number claim '$pr_id' holds issue #$ISSUE ($context)"
        warn "revalidate union ($context): $UNION_REFUSE_REASON"
        return 1
      fi
    done <<EOF
$pr_rows
EOF
  fi
  return 0
}

# (#153 exact-head P1) The live open-PR claim inventory is AUTHORITATIVE for
# BOTH non-CAS open-PR release and CAS ledger cleanup. A reaper/CAS run is
# ledger-only (never closes a PR) but must still re-read and refuse when an
# open PR holds the exact target id or the same issue — otherwise a claim
# that appeared after reaper planning loses its ledger row/label/worktree.
# An unreadable or malformed inventory is never an empty one.
PR_ROWS=""
if [[ -n "$PR_REPO" ]]; then
  if ! read_fresh_pr_inventory "$PR_REPO"; then
    die "$UNION_REFUSE_REASON"
  fi
fi

# CAS protect (#153 exact-head P1): refuse before ANY mutation when a fresh
# open PR holds the exact claim id or any claim for the same issue. Direct
# CAS callers cannot bypass the reaper pre-dispatch guard.
if [[ -n "$PR_REPO" && "$CAS_MODE" -eq 1 ]]; then
  _cas_protect_hit=""
  while IFS= read -r pr_row; do
    [[ -n "$pr_row" ]] || continue
    pr_id=$(cut -f2 <<<"$pr_row")
    pr_number=$(cut -f1 <<<"$pr_row")
    [[ -n "$pr_id" ]] || continue
    # Exact target id is live open evidence — never a sibling to ignore.
    if [[ "$CLAIM_ID_SET" -eq 1 && "$pr_id" == "$CLAIM_ID_ARG" ]]; then
      _cas_protect_hit="open PR #$pr_number carries exact claim id '$pr_id'"
      break
    fi
    # Same-issue open claim (including differently named / namespaced siblings)
    # also protects: agent-claimed and multi-slice live work.
    if claim_id_for_issue "$pr_id"; then
      _cas_protect_hit="open PR #$pr_number claim '$pr_id' holds issue #$ISSUE"
      break
    fi
  done <<EOF
$PR_ROWS
EOF
  if [[ -n "$_cas_protect_hit" ]]; then
    die "CAS release refused — ${_cas_protect_hit}; open PR-body claim protects live work (no ledger/label/worktree/branch mutation)"
  fi
  unset _cas_protect_hit pr_row pr_id pr_number
fi

# Non-CAS: intentional open-PR release path (may close the PR). CAS never
# enters this block — it is ledger-only by contract.
if [[ -n "$PR_REPO" && "$CAS_MODE" -eq 0 ]]; then
  PR_MATCHES=""
  # cut, not `IFS=$'\t' read`: tab is IFS *whitespace*, so bash's read
  # collapses consecutive tabs and silently drops an empty field (e.g. a
  # malformed empty scope column), shifting pr_head to the wrong value.
  while IFS= read -r pr_row; do
    [[ -n "$pr_row" ]] || continue
    pr_number=$(cut -f1 <<<"$pr_row")
    pr_id=$(cut -f2 <<<"$pr_row")
    pr_head=$(cut -f4 <<<"$pr_row")
    pr_cross=$(cut -f8 <<<"$pr_row")
    [[ -n "$pr_id" ]] || continue
    # Shared issue matcher (#153 namespaced open-claim P1): never hard-code
    # ^issue-${ISSUE}- so namespaced ids like issue-template-5-x are seen.
    claim_id_for_issue "$pr_id" || continue
    if [[ "$CLAIM_ID_SET" -eq 1 && "$pr_id" != "$CLAIM_ID_ARG" ]]; then
      continue
    fi
    PR_MATCHES="${PR_MATCHES}${pr_number}"$'\t'"${pr_id}"$'\t'"${pr_head}"$'\t'"${pr_cross}"$'\n'
  done <<EOF
$PR_ROWS
EOF
  PR_COUNT=$(printf '%s' "$PR_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')
  # (#153 exact-head P1) Multiple open PRs matching the requested issue/claim
  # are ambiguous regardless of --claim-id. Never pick one, and never fall
  # through to ledger cleanup while ignoring the open rows as "targets".
  if [[ "$PR_COUNT" -gt 1 ]]; then
    die "issue #$ISSUE has multiple live open PR claims (ambiguous exact-id/issue union) — refuse all mutation; open PRs: $(printf '%s' "$PR_MATCHES" | cut -f1,2 | tr '\t' '#' | tr '\n' ' ')"
  fi
  if [[ "$PR_COUNT" -eq 1 ]]; then
    PR_NUMBER=$(printf '%s' "$PR_MATCHES" | sed -n '1s/\t.*//p')
    PR_CLAIM_ID=$(printf '%s\n' "$PR_MATCHES" | cut -f2)
    PR_HEAD_BRANCH=$(printf '%s\n' "$PR_MATCHES" | cut -f3)
    PR_IS_CROSS_REPO=$(printf '%s\n' "$PR_MATCHES" | cut -f4)
    # sibling check (#153 AC1/AC4): other live open PR-body claims for this
    # issue keep agent-claimed, same as a ledger sibling does below. current
    # claim.sh never writes a ledger row, so this is the only sibling source
    # for a pure PR-body multi-slice issue. Shared matcher so namespaced
    # siblings are never invisible to label policy.
    PR_SIBLINGS=""
    while IFS= read -r _s_row; do
      [[ -n "$_s_row" ]] || continue
      _s_id=$(cut -f2 <<<"$_s_row")
      [[ -n "$_s_id" ]] || continue
      [[ "$_s_id" == "$PR_CLAIM_ID" ]] && continue
      claim_id_for_issue "$_s_id" || continue
      PR_SIBLINGS="${PR_SIBLINGS}${_s_id}"$'\n'
    done <<EOF
$PR_ROWS
EOF
    PR_SIBLINGS=$(printf '%s\n' "$PR_SIBLINGS" | grep -E '^issue-' | sort -u || true)
    [[ "$PR_HEAD_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] ||
      die "owning PR #$PR_NUMBER has an unsafe/empty head branch '${PR_HEAD_BRANCH:-?}' — refuse"
    # Closing this PR, and everything that follows it, mutates state that
    # belongs to a specific repository. Prove that repository is the one this
    # checkout's origin points at BEFORE the first mutation — including in
    # --dry-run, so an operator sees the binding failure before trying it for
    # real (#153 review P1).
    require_canonical_repo_binding "$PR_REPO" "open PR-body claim release for '$PR_CLAIM_ID' (PR #$PR_NUMBER)"
    PR_EXPECT_BRANCH=$(branch_for "$PR_CLAIM_ID")
    # (#153 review round 4, P1) The head branch this claim id DERIVES is part
    # of the claim's identity, not a detail discovered afterwards. This check
    # used to run only after `gh pr close` had already fired, so an exact claim
    # marker sitting in the body of a PR on some unrelated branch was enough to
    # close that PR — an irreversible mutation on a PR whose identity was never
    # bound to the claim. `gh pr close` is the FIRST mutation on this path, so
    # the binding has to be complete before it, and a mismatch has to be a
    # plain pre-mutation refusal (exit 1) rather than a partial run reported as
    # INCOMPLETE. Dry-run refuses here too, for the same reason the repository
    # binding above does: an operator must see the failure before trying it for
    # real, not after.
    if [[ "$PR_HEAD_BRANCH" != "$PR_EXPECT_BRANCH" ]]; then
      die "open PR-body claim release for '$PR_CLAIM_ID': PR #$PR_NUMBER head branch '$PR_HEAD_BRANCH' is not the branch this claim id derives ('$PR_EXPECT_BRANCH') — the PR's identity cannot be bound to the claim, so it must not be closed. Refuse (nothing was mutated: the PR is still open, no label was touched, no worktree or branch was removed). An exact claim marker in the body of a PR on an unrelated branch is not authority to close that PR."
    fi
    # (#153 review round 5, P1) Repository identity, before the irreversible
    # mutation. A fork PR can carry a perfectly well-formed claim marker AND a
    # head branch whose name is exactly the one this claim id derives — branch
    # names are not namespaced across repositories, so neither of the two
    # checks above can tell a fork apart from this repository's own PR. The
    # terminal-evidence path has always refused cross-repository rows; the OPEN
    # path closed the PR first and only met that refusal afterwards, by which
    # point a pull request in somebody else's repository had already been
    # closed. Anything other than a literal `false` — `true`, an empty column,
    # a truncated row, a field the reader could not prove is a boolean — is
    # UNSAFE, never "probably ours": absence of proof of a fork is not proof it
    # is not one.
    if [[ "$PR_IS_CROSS_REPO" != "false" ]]; then
      die "open PR-body claim release for '$PR_CLAIM_ID': PR #$PR_NUMBER is not provably a same-repository pull request (isCrossRepository='${PR_IS_CROSS_REPO:-<missing>}', want 'false') — refuse to close it. Nothing was mutated: the PR is still open, no label was touched, no worktree, branch or ledger row was removed. A claim marker and a matching head-branch name are not repository identity; a fork can carry both."
    fi
    # --- freeze bound open head SHA (#153 freeze/revalidate P1) ------------
    # The inventory row lacks headRefOid. A concurrent push can advance the
    # branch between this inventory read and gh pr close; the post-close
    # terminal row would then carry the NEW sha and authorize deleting a
    # worktree/branch the freeze never saw. Freeze the exact open head now,
    # re-read immediately before close, and refuse if anything moved.
    if ! read_bound_open_pr_evidence "$PR_CLAIM_ID" "$PR_NUMBER"; then
      die "open PR-body claim release for '$PR_CLAIM_ID' (PR #$PR_NUMBER): cannot freeze bound open evidence — $OPEN_EV_ERR. Refuse (nothing was mutated)."
    fi
    # Bound evidence must agree with the inventory identity already proven.
    if [[ "$OPEN_EV_HEAD" != "$PR_HEAD_BRANCH" ]]; then
      die "open PR-body claim release for '$PR_CLAIM_ID' (PR #$PR_NUMBER): bound open evidence head branch '$OPEN_EV_HEAD' disagrees with inventory head '$PR_HEAD_BRANCH' — refuse (nothing was mutated)."
    fi
    if [[ "$OPEN_EV_CROSS" != "false" ]]; then
      die "open PR-body claim release for '$PR_CLAIM_ID' (PR #$PR_NUMBER): bound open evidence isCrossRepository='$OPEN_EV_CROSS' (want 'false') — refuse (nothing was mutated)."
    fi
    FROZEN_OPEN_HEAD_SHA="$OPEN_EV_HEAD_SHA"
    FROZEN_OPEN_HEAD_BRANCH="$OPEN_EV_HEAD"
    FROZEN_OPEN_CLAIM="$OPEN_EV_CLAIM"
    FROZEN_OPEN_NUMBER="$OPEN_EV_NUMBER"
    FROZEN_OPEN_SCOPE="$OPEN_EV_SCOPE"
    FROZEN_OPEN_URL="$OPEN_EV_URL"
    if [[ "$DRY" -eq 1 ]]; then
      preview_open_pr_body_dry_run \
        || die "cannot plan open-PR cleanup target for '$PR_CLAIM_ID': ${CLEANUP_TARGET_REASON:-unknown}"
      exit 0
    fi
    # --- complete authoritative union BEFORE gh pr close (#153 P1) ---------
    # Fresh, fully validated PR inventory AND exact remote-ledger snapshot
    # together, immediately before the irreversible close. Never reuse the
    # startup PR_ROWS snapshot: a second same-ID open PR that arrived after
    # that snapshot must refuse before gh pr close.
    # Claim id alone is never generation identity.
    {
      if ! read_fresh_pr_inventory "$PR_REPO"; then
        die "open PR-body claim release for '$PR_CLAIM_ID' (PR #$PR_NUMBER): cannot obtain fresh PR inventory before close — $UNION_REFUSE_REASON. Refuse (nothing was mutated)."
      fi
      if ! _preclose_base=$(fetch_remote_base); then
        die "open PR-body claim release for '$PR_CLAIM_ID' (PR #$PR_NUMBER): cannot re-fetch remote ledger base before close — refuse (nothing was mutated)${CLEANUP_FETCH_REASON:+: $CLEANUP_FETCH_REASON}"
      fi
      _preclose_ref="origin/${_preclose_base}"
      CLEANUP_BASE="$_preclose_base"
      REF="$_preclose_ref"
      # Unique exact target identity on the FRESH inventory.
      _preclose_open_n=0
      _preclose_open_nums=""
      _preclose_target_seen=0
      while IFS= read -r pr_row; do
        [[ -n "$pr_row" ]] || continue
        pr_id=$(cut -f2 <<<"$pr_row")
        pr_number=$(cut -f1 <<<"$pr_row")
        [[ "$pr_id" == "$PR_CLAIM_ID" ]] || continue
        _preclose_open_n=$((_preclose_open_n + 1))
        _preclose_open_nums="${_preclose_open_nums}#${pr_number} "
        if [[ "$pr_number" == "$PR_NUMBER" ]]; then
          _preclose_target_seen=1
        fi
      done <<EOF
$PR_ROWS
EOF
      if [[ "$_preclose_open_n" -eq 0 ]]; then
        die "open PR-body claim release for '$PR_CLAIM_ID' (PR #$PR_NUMBER): fresh pre-close inventory no longer carries this claim — refuse before close (nothing was mutated)"
      fi
      if [[ "$_preclose_open_n" -gt 1 ]]; then
        die "REFUSE ambiguous exact claim id '$PR_CLAIM_ID' across open PR union (${_preclose_open_n} open PRs: ${_preclose_open_nums}) (pre-close) — refuse all mutation"
      fi
      if [[ "$_preclose_target_seen" -ne 1 ]]; then
        die "open PR-body claim release for '$PR_CLAIM_ID' (PR #$PR_NUMBER): fresh pre-close inventory carries the claim under a different PR number (${_preclose_open_nums}) — refuse before close (nothing was mutated)"
      fi
      # Same-issue second open PR (different claim id) also refuses before close
      # when --claim-id is exact: generation uniqueness is the exact target, but
      # a second same-ID is already handled above; mixed same-issue open PRs are
      # allowed only as multi-slice residual after close — not as a second
      # same-ID representation.
      if ! count_ledger_reps_at_ref "$PR_CLAIM_ID" "$_preclose_ref"; then
        die "REFUSE unreadable ledger representation evidence for '$PR_CLAIM_ID' at $_preclose_ref (pre-close) — refuse all mutation (unreadable is not absence)"
      fi
      if [[ "$LEDGER_FILE_REP" -eq 1 && "$LEDGER_LEGACY_REP" -eq 1 ]]; then
        die "REFUSE ambiguous mixed ledger representations for '$PR_CLAIM_ID' (both docs/claims/${PR_CLAIM_ID}.md and docs/active-work.md) at $_preclose_ref (pre-close) — refuse all mutation; preserve PR, both representations, label, worktree, and branches"
      fi
      if [[ "$LEDGER_ANY_REP" -eq 1 ]]; then
        die "REFUSE exact claim id '$PR_CLAIM_ID' is live both as open PR (#$PR_NUMBER) and ledger representation(s) (file=$LEDGER_FILE_REP legacy=$LEDGER_LEGACY_REP) at $_preclose_ref (pre-close) — refuse all mutation; preserve PR, ledger, label, worktree, and branches"
      fi
      unset _preclose_base _preclose_ref _preclose_open_n _preclose_open_nums _preclose_target_seen pr_row pr_id pr_number
    }
    # Immediate pre-close revalidation of the bound evidence. Any identity or
    # head-SHA movement after the freeze is a race — refuse before close.
    if ! read_bound_open_pr_evidence "$PR_CLAIM_ID" "$PR_NUMBER"; then
      die "open PR-body claim release for '$PR_CLAIM_ID' (PR #$PR_NUMBER): pre-close bound evidence re-read failed — $OPEN_EV_ERR. Refuse before close (nothing was mutated: the PR is still open, no label was touched, no worktree or branch was removed)."
    fi
    if [[ "$OPEN_EV_NUMBER" != "$FROZEN_OPEN_NUMBER" || \
          "$OPEN_EV_CLAIM" != "$FROZEN_OPEN_CLAIM" || \
          "$OPEN_EV_SCOPE" != "$FROZEN_OPEN_SCOPE" || \
          "$OPEN_EV_HEAD" != "$FROZEN_OPEN_HEAD_BRANCH" || \
          "$OPEN_EV_HEAD_SHA" != "$FROZEN_OPEN_HEAD_SHA" || \
          "$OPEN_EV_URL" != "$FROZEN_OPEN_URL" || \
          "$OPEN_EV_STATE" != "OPEN" || \
          "$OPEN_EV_CROSS" != "false" || \
          "$OPEN_EV_BASE_REPO" != "$PR_REPO" || \
          "$OPEN_EV_ISSUE" != "$ISSUE" ]]; then
      die "open PR-body claim release for '$PR_CLAIM_ID' (PR #$PR_NUMBER): bound open evidence moved between freeze and pre-close re-read (frozen head $FROZEN_OPEN_HEAD_SHA, now ${OPEN_EV_HEAD_SHA:-<missing>}; identity/state drift). Refuse before close (nothing was mutated: the PR is still open, no label was touched, no worktree or branch was removed)."
    fi
    info "closing PR #$PR_NUMBER to release the PR-body claim (frozen open head $FROZEN_OPEN_HEAD_SHA)"
    if ! gh pr close "$PR_NUMBER" --repo "$PR_REPO" >/dev/null; then
      die "gh pr close failed for PR #$PR_NUMBER in $PR_REPO — the claim is still live; nothing else was mutated"
    fi

    # --- hand over to the shared exact cleanup machinery -------------------
    # The PR is terminal now, so its own terminal evidence (exact head SHA,
    # state, base repository, cross-repo flag) can be re-read and bound before
    # anything is removed. terminal_cleanup_release() always exits: 0 only
    # after it has proven the worktree, both branch refs, and the live-claim
    # postcondition; 3 with agent-claimed preserved otherwise.
    #
    # Gate on the head branch matching the one this claim id derives, because
    # that identity is what the cleanup proof is anchored to. An
    # unconventional head branch is not a reason to guess — it falls through
    # to the close-only report below.
    #
    # The handover is BOUND TO $PR_NUMBER (#153 review P2). This path already
    # knows exactly which PR it just closed, so it asks about that PR rather
    # than asking which terminal PR carries the id — the question that turns
    # ambiguous the moment a released claim id is legitimately reused and a
    # second generation reaches a terminal state. Every evidence check below
    # still applies in full to that exact PR.
    # (#153 review round 3, P2) The handover distinguishes three outcomes, and
    # NONE of them may exit 1 through `die` from here: the PR is already
    # closed, so this run is a partial mutation and its documented shape is
    # the close-only INCOMPLETE path below (exit 3, artifacts and
    # agent-claimed preserved, recovery named). A helper that died here left
    # exit 1 behind and bypassed that lifecycle entirely.
    TERMINAL_RC=0
    OPEN_INCOMPLETE=0
    OPEN_SIBLINGS=""
    OPEN_TERMINAL_FATAL=""
    # The head-branch binding was proven BEFORE the close (#153 review round
    # 4), so this handover is unconditional now: every PR this path closes is
    # one whose derived branch already matched.
    try_terminal_pr_body_release "$PR_CLAIM_ID" "$PR_NUMBER" || TERMINAL_RC=$?
    if [[ "$TERMINAL_RC" -eq 0 ]]; then
      # Terminal head SHA must still be the frozen OPEN head. A post-freeze
      # race may make the close partial (GitHub closed an advanced tip), but
      # must never authorize worktree/branch deletion from the moved SHA.
      if [[ "$TERMINAL_HEAD_SHA" != "$FROZEN_OPEN_HEAD_SHA" ]]; then
        warn "PR #$PR_NUMBER is closed, but its terminal head SHA ($TERMINAL_HEAD_SHA) does not equal the frozen open head SHA ($FROZEN_OPEN_HEAD_SHA) — a post-freeze race advanced the branch. Refusing cleanup on the moved SHA; worktree, branches and agent-claimed are preserved."
        OPEN_TERMINAL_FATAL="terminal head SHA ($TERMINAL_HEAD_SHA) != frozen open head SHA ($FROZEN_OPEN_HEAD_SHA)"
        OPEN_INCOMPLETE=1
        TERMINAL_RC=2
      else
        terminal_cleanup_release "$PR_CLAIM_ID"
      fi
    fi

    # --- close-only fallback ----------------------------------------------
    # Reached when the closed PR's own terminal evidence is not readable or is
    # fatally unusable. The claim IS released — the PR is closed — but nothing
    # may be removed on unproven identity, so say exactly that.
    #
    # (#153 review round 4, P1) BOTH remaining outcomes are INCOMPLETE. A
    # not-found verdict used to warn and fall through, which meant an empty
    # terminal view after a successful close could still reach the success
    # message and strip agent-claimed. That is backwards: after the PR was
    # closed, the absence of its exact terminal row is not evidence that
    # everything is clean — it is evidence that this run cannot see the PR it
    # just mutated, so the identity it would clean up on is UNPROVEN. Absence
    # of proof is never proof of absence on a mutation path.
    if [[ "$TERMINAL_RC" -eq 2 ]]; then
      # Evidence exists for the PR we just closed, and it is FATALLY unusable:
      # unreadable query, ambiguous, mismatched, or contradicting the PR's own
      # state. The exact checks are unchanged — what changed is that this no
      # longer exits 1 mid-mutation. Preserve everything, keep agent-claimed,
      # and finish through the close-only INCOMPLETE report (exit 3).
      OPEN_TERMINAL_FATAL="$TERMINAL_FAIL_REASON"
      warn "PR #$PR_NUMBER is closed, but its terminal evidence is unusable — refusing to clean up on unproven identity: $TERMINAL_FAIL_REASON"
      warn "the claim was released by closing PR #$PR_NUMBER; the worktree, both branch refs and agent-claimed are being PRESERVED because nothing about their identity was proven"
      OPEN_INCOMPLETE=1
    else
      warn "PR #$PR_NUMBER is closed, but no exact terminal PR-body evidence for '$PR_CLAIM_ID' came back — its identity is UNPROVEN, so nothing is being cleaned up"
      warn "the worktree, both branch refs and agent-claimed are being PRESERVED: an absent terminal row after a close is not proof that there is nothing left, it is proof this run cannot see the PR it just closed"
      OPEN_INCOMPLETE=1
    fi

    # --- fail-closed post-close reread ------------------------------------
    # Closing the PR is the release; proving it is a separate step. Re-read
    # the authoritative inventory and require the claim to be gone from it,
    # and derive sibling policy from that FRESH view rather than from the
    # pre-close rows (which by definition still contain the claim we just
    # released, and may be stale about siblings besides).
    if ! POST_PR_ROWS=$("$SCRIPT_DIR/pr-claims.sh" list "$PR_REPO" 2>&1); then
      warn "post-close reread of live PR-body claims failed for $PR_REPO — cannot verify the claim was released: $POST_PR_ROWS"
      OPEN_INCOMPLETE=1
    elif ! open_pr_rows_valid "$POST_PR_ROWS"; then
      warn "post-close reread of live PR-body claims returned a malformed/truncated row for $PR_REPO — cannot verify the claim was released: $OPEN_PR_BAD_ROW"
      OPEN_INCOMPLETE=1
    elif printf '%s\n' "$POST_PR_ROWS" | awk -F'\t' -v want="$PR_CLAIM_ID" '$2 == want { f = 1 } END { exit !f }'; then
      warn "claim '$PR_CLAIM_ID' is STILL a live open PR-body claim after closing PR #$PR_NUMBER — refuse to report success"
      OPEN_INCOMPLETE=1
    elif printf '%s\n' "$POST_PR_ROWS" | awk -F'\t' -v want="$PR_NUMBER" '$1 == want { f = 1 } END { exit !f }'; then
      warn "PR #$PR_NUMBER is STILL a live open PR-body claim after this run closed it (under claim id '$(printf '%s\n' "$POST_PR_ROWS" | awk -F'\t' -v want="$PR_NUMBER" '$1 == want { print $2; exit }')') — refuse to report success"
      OPEN_INCOMPLETE=1
    else
      while IFS= read -r _post_row; do
        [[ -n "$_post_row" ]] || continue
        _post_id=$(cut -f2 <<<"$_post_row")
        [[ -n "$_post_id" ]] || continue
        [[ "$_post_id" == "$PR_CLAIM_ID" ]] && continue
        # Shared issue matcher — namespaced open siblings must not be ignored.
        claim_id_for_issue "$_post_id" || continue
        OPEN_SIBLINGS="${OPEN_SIBLINGS}${_post_id}"$'\n'
      done <<EOF
$POST_PR_ROWS
EOF
      OPEN_SIBLINGS=$(printf '%s\n' "$OPEN_SIBLINGS" | grep -E '^issue-' | sort -u || true)
    fi

    # --- the SAME proof, bound to the PR NUMBER (#153 review round 4, P1) ---
    # Everything above reads the claim INVENTORY, which only contains a PR
    # while that PR carries a well-formed claim marker. So a PR that is still
    # wide open, but whose marker was removed or rewritten between the
    # pre-close read and now, disappears from that view and looks exactly like
    # a PR that closed. That is a false success on the one fact this whole
    # path exists to establish. Ask the body-agnostic open-PR inventory about
    # the exact number this run closed, and refuse unless it is really gone.
    if ! read_open_pr_numbers "$PR_REPO"; then
      warn "post-close: cannot verify that PR #$PR_NUMBER actually left the open pull-request inventory — $OPEN_NUMBERS_ERR; refuse to report success"
      OPEN_INCOMPLETE=1
    elif open_pr_number_present "$PR_NUMBER"; then
      warn "post-close: PR #$PR_NUMBER is STILL OPEN in $PR_REPO after this run closed it, even though its claim marker no longer appears in the claim inventory — a removed or rewritten marker is not a released claim. Refuse to report success; the worktree, branches and agent-claimed are preserved"
      OPEN_INCOMPLETE=1
    fi

    # --- close-only: worktree/branch are NOT touched here (#153) -----------
    # This path used to `git worktree remove --force` a path GUESSED from the
    # claim id and then `git branch -D` / `git push --delete` with `|| true`,
    # and print "released PR-body claim" regardless — success reported over
    # best-effort cleanup it never re-read or proved. The exact, verified
    # cleanup machinery (registered-worktree resolution by branch enumeration,
    # dirty/TOCTOU revalidation, head-SHA containment proof, CAS branch
    # deletes, postcondition rereads) lives in terminal_cleanup_release() and
    # is only sound against TERMINAL PR evidence — exactly what this PR
    # becomes the moment we close it, and which this early path (running
    # before the ledger ref is even resolved) cannot yet reach in this
    # process. So: close only, prove only, and report honestly. Anything left
    # over is named and returned as INCOMPLETE rather than assumed done.
    if [[ "$KEEP_WORKTREE" -eq 0 || "$KEEP_BRANCH" -eq 0 ]]; then
      OPEN_LEFTOVERS=""
      if [[ "$KEEP_WORKTREE" -eq 0 ]]; then
        if ! OPEN_WT_LIST=$(git worktree list --porcelain 2>&1); then
          warn "cannot enumerate registered worktrees — cannot prove worktree cleanup for '$PR_HEAD_BRANCH': $OPEN_WT_LIST"
          OPEN_INCOMPLETE=1
        elif printf '%s\n' "$OPEN_WT_LIST" | grep -qxF "branch refs/heads/$PR_HEAD_BRANCH"; then
          OPEN_LEFTOVERS="${OPEN_LEFTOVERS}  registered worktree on branch '$PR_HEAD_BRANCH'"$'\n'
        fi
      fi
      if [[ "$KEEP_BRANCH" -eq 0 ]]; then
        if git show-ref --verify --quiet "refs/heads/$PR_HEAD_BRANCH"; then
          OPEN_LEFTOVERS="${OPEN_LEFTOVERS}  local branch '$PR_HEAD_BRANCH'"$'\n'
        fi
        if ! OPEN_LS_REMOTE=$(git ls-remote --heads origin "refs/heads/$PR_HEAD_BRANCH" 2>&1); then
          warn "cannot read remote branch '$PR_HEAD_BRANCH' — cannot prove branch cleanup: $OPEN_LS_REMOTE"
          OPEN_INCOMPLETE=1
        elif [[ -n "$OPEN_LS_REMOTE" ]]; then
          OPEN_LEFTOVERS="${OPEN_LEFTOVERS}  remote branch '$PR_HEAD_BRANCH'"$'\n'
        fi
      fi
      if [[ -n "$OPEN_LEFTOVERS" ]]; then
        warn "PR #$PR_NUMBER is closed and the claim is released, but this close-only path did not remove:"
        printf '%s' "$OPEN_LEFTOVERS" >&2
        warn "re-run: release-claim.sh $ISSUE --claim-id $PR_CLAIM_ID --repo $PR_REPO — the PR is terminal now, so the exact verified terminal cleanup (registered-worktree proof, head-SHA containment, CAS branch deletes) can run"
        OPEN_INCOMPLETE=1
      fi
    fi

    # --- label policy ------------------------------------------------------
    # (#153 review round 4, P1) Every path that still reaches here is
    # INCOMPLETE by construction: the only two outcomes left after the close
    # are "terminal evidence fatally unusable" and "no exact terminal evidence
    # came back", and both mean this run cannot prove the identity of anything
    # it would clean up. So this path NEVER removes agent-claimed — the one
    # route to a verified label removal after a close is
    # terminal_cleanup_release(), which proves the registered worktree, both
    # branch refs, and the live-claim postcondition first. The branches that
    # used to remove or conditionally keep the label here are gone rather than
    # left unreachable: an unreachable label-removal branch reads like a
    # supported outcome, and this one is not.
    #
    # The invariant is asserted rather than assumed: if a future edit ever
    # lets a non-INCOMPLETE outcome reach here, that is a bug that must fail
    # closed loudly, not quietly become a success.
    if [[ "$OPEN_INCOMPLETE" -ne 1 ]]; then
      warn "internal invariant: the close-only path reached its report without being marked INCOMPLETE — treating it as INCOMPLETE anyway (never report success over cleanup that was never proven)"
      OPEN_INCOMPLETE=1
    fi
    info "preserving agent-claimed on #$ISSUE — open-PR release did not fully complete or could not be verified"
    if [[ -n "$OPEN_SIBLINGS" ]]; then
      info "note: sibling PR-body claim(s) also still hold #$ISSUE: $(printf '%s' "$OPEN_SIBLINGS" | tr '\n' ' ')"
    fi

    if [[ -n "$OPEN_TERMINAL_FATAL" ]]; then
      echo "release-claim.sh: the terminal evidence for the PR this run closed could not be used: $OPEN_TERMINAL_FATAL" >&2
    fi
    echo "release-claim.sh: RECOVERY — PR #$PR_NUMBER is closed, so the claim is released, but nothing was removed and agent-claimed was preserved. Re-run 'release-claim.sh $ISSUE --claim-id $PR_CLAIM_ID --repo $PR_REPO --pr $PR_NUMBER' once the PR's terminal evidence reads cleanly; that path runs the exact verified terminal cleanup (registered-worktree proof, head-SHA containment, CAS branch deletes) and removes the label only after proving it." >&2
    echo "release-claim.sh: INCOMPLETE — open-PR claim release did not finish for issue $ISSUE (see warnings above)" >&2
    exit 3
  fi
fi

ALL_LIVE_IDS=$(claim_ids_all) || \
  die "cannot read claim ledger at $REF — unreadable tree is not an empty ledger"
# Every live row for this issue (broad: any alpha-ns or bare issue-N), so we
# can tell "released the last one" from "released one slice of several" (L-024).
ALL_IDS=$(issue_claim_ids_from "$ALL_LIVE_IDS")
TARGET_IDS=""

if [[ "$CLAIM_ID_SET" -eq 1 ]]; then
  # --claim-id is always a *literal* exact id. Reject empty, ERE/glob-looking,
  # and malformed values before any mutation. Never pass the arg through grep -E.
  if [[ ! "$CLAIM_ID_ARG" =~ ^issue-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    die "--claim-id must be a literal exact claim id (no wildcards/regex); got '$CLAIM_ID_ARG'"
  fi
  if ! claim_id_for_issue "$CLAIM_ID_ARG"; then
    die "--claim-id '$CLAIM_ID_ARG' does not belong to issue $ISSUE${PREFIX:+ (prefix $PREFIX)}"
  fi
  if ! printf '%s\n' "$ALL_IDS" | grep -qxF -- "$CLAIM_ID_ARG"; then
    if printf '%s\n' "$ALL_LIVE_IDS" | grep -qxF -- "$CLAIM_ID_ARG"; then
      die "--claim-id '$CLAIM_ID_ARG' is live but not a claim for issue $ISSUE${PREFIX:+ (prefix $PREFIX)}"
    fi
    # --pr binds this lookup to one exact PR (#153 review P2). Without it the
    # id-only lookup is used, which is correct until a released id is reused
    # and more than one terminal PR carries it — then it is ambiguous and
    # refuses, and the error names --pr as the way to ask precisely.
    # Nothing has been mutated on this path, so a FATAL evidence verdict (2)
    # is still safe to turn into a plain refusal — and it must name which
    # binding failed rather than collapsing into the generic "no live claim"
    # message (#153 review round 3, P2).
    TERMINAL_RC=0
    if [[ "$CAS_MODE" -eq 0 ]]; then
      try_terminal_pr_body_release "$CLAIM_ID_ARG" "$PR_NUMBER_ARG" || TERMINAL_RC=$?
    else
      TERMINAL_RC=1
    fi
    if [[ "$TERMINAL_RC" -eq 2 ]]; then
      die "$TERMINAL_FAIL_REASON"
    elif [[ "$TERMINAL_RC" -ne 0 ]]; then
      die "no live claim '$CLAIM_ID_ARG' at $REF (checked ledger and terminal PR-body evidence${PR_NUMBER_ARG:+, bound to PR #$PR_NUMBER_ARG})"
    fi
  fi
  TARGET_IDS="$CLAIM_ID_ARG"
else
  # Bare invocation: freeze zero or one exact id. Never carry a broad issue
  # regex into cleanup. Multi-claim without --claim-id is a hard refuse.
  n_issue=0
  if [[ -n "$ALL_IDS" ]]; then
    n_issue=$(printf '%s\n' "$ALL_IDS" | grep -c . || true)
  fi
  if [[ "$n_issue" -gt 1 ]]; then
    echo "release-claim.sh: ERROR: issue $ISSUE has ${n_issue} live claims; pass --claim-id with exactly one of:" >&2
    printf '%s\n' "$ALL_IDS" | sed 's/^/  /' >&2
    exit 1
  fi
  if [[ "$n_issue" -eq 1 ]]; then
    TARGET_IDS=$(printf '%s\n' "$ALL_IDS")
    info "bare release freezes single claim id: $TARGET_IDS"
  fi
fi

# Pre-plan authoritative union (ledger + open PRs) for TARGET_IDS.
if [[ -n "$TARGET_IDS" ]]; then
  validate_authoritative_union "$TARGET_IDS" "${PR_ROWS:-}" "$REF" "pre-plan ledger union"
fi

if [[ -z "$TARGET_IDS" ]]; then
  info "no live claim for issue $ISSUE — will still try label/worktree cleanup"
fi

# ===========================================================================
# Guarded artifact-cleanup primitive (#153 exact-head P1 finding 5)
# ===========================================================================
# ONE path for every ledger-driven worktree/branch deletion. Never derives a
# path from claim id, never rm -rf, never worktree remove --force, never
# branch -D, never unleased remote delete.
#
# Preconditions (caller must already have proven):
#   * ledger mutation pushed and authoritatively revalidated, OR this is the
#     terminal PR-body path which already proved the claim is terminal and
#     same-ID ledger is absent.
#   * exact branch name known
#
# Behavior:
#   * resolve worktree only from `git worktree list --porcelain` by exact branch
#   * refuse symlink / unregistered / ambiguous / foreign / dirty / switched /
#     HEAD-moved paths
#   * freeze exact local/remote OIDs; revalidate immediately before removal
#   * non-force `git worktree remove` only
#   * local: `git update-ref -d <ref> <frozen-oid>` CAS
#   * remote: exact lease against frozen remote OID; absent ≠ unreadable
# Returns 0 only when requested cleanups completed. Partial → return 1
# (caller reports INCOMPLETE, preserves label).
guarded_remove_claim_artifacts() {
  local id="$1" br="$2" frozen_local_oid="${3:-}" frozen_remote_oid="${4:-}"
  local wt="" status_out got_head revalidate_out revalidate_branch revalidate_head
  local wt_present=0

  if [[ -z "$br" ]]; then
    warn "guarded artifact cleanup: empty branch — refuse"
    return 1
  fi

  # Proven ownership only (#153 exact-head): when branch deletion is requested,
  # both local and remote expected OIDs must already be bound to the released
  # claim's proven evidence. Never self-seed from whatever tip exists at
  # deletion time — that only protects against later movement, not against an
  # already-reused or advanced branch.
  if [[ "$KEEP_BRANCH" -eq 0 ]]; then
    if git show-ref --verify --quiet "refs/heads/$br"; then
      if [[ -z "$frozen_local_oid" || ! "$frozen_local_oid" =~ ^[0-9a-f]{40}$ ]]; then
        warn "guarded artifact cleanup: local branch '$br' exists but no pre-frozen proven local OID was supplied — refuse (no self-seed at deletion time)"
        return 1
      fi
    fi
  fi

  # Resolve worktree only from porcelain by exact branch — never default path.
  # Same pure-read resolver dry-run preview uses (#271).
  if ! resolve_cleanup_target "$br" "$id"; then
    warn "guarded artifact cleanup: worktree resolution refused: $CLEANUP_TARGET_REASON"
    return 1
  fi
  if [[ -n "$CLEANUP_TARGET_WT" ]]; then
    wt="$CLEANUP_TARGET_WT"
    wt_present=1
  fi

  if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
    [[ "$wt_present" -eq 1 ]] && info "keeping worktree $wt (--keep-worktree)"
  elif [[ "$wt_present" -eq 1 ]]; then
    if [[ -L "$wt" ]]; then
      warn "guarded artifact cleanup: worktree path is a symlink — refuse: $wt"
      return 1
    fi
    if [[ ! -d "$wt" ]]; then
      warn "guarded artifact cleanup: worktree path missing/unreadable — refuse: $wt"
      return 1
    fi
    if ! status_out=$(git -C "$wt" status --porcelain 2>&1); then
      warn "guarded artifact cleanup: cannot read worktree status ($status_out)"
      return 1
    fi
    if [[ -n "$status_out" ]]; then
      warn "guarded artifact cleanup: dirty/untracked worktree — refuse: $wt"
      return 1
    fi
    got_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
    if [[ -z "$got_head" ]]; then
      warn "guarded artifact cleanup: cannot read worktree HEAD"
      return 1
    fi
    # Immediate pre-removal revalidation: branch + registration + cleanliness + HEAD.
    if ! revalidate_out=$(git -C "$wt" status --porcelain 2>&1); then
      warn "guarded artifact cleanup: cannot revalidate status for $wt"
      return 1
    fi
    if [[ -n "$revalidate_out" ]]; then
      warn "guarded artifact cleanup: worktree became dirty before removal — refuse"
      return 1
    fi
    if ! worktree_registered "$wt"; then
      warn "guarded artifact cleanup: path no longer registered — refuse"
      return 1
    fi
    revalidate_branch=$(worktree_branch "$wt" || true)
    if [[ "$revalidate_branch" != "$br" ]]; then
      warn "guarded artifact cleanup: worktree switched off '$br' (now '${revalidate_branch:-detached}') — refuse"
      return 1
    fi
    if ! revalidate_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || [[ -z "$revalidate_head" ]]; then
      warn "guarded artifact cleanup: cannot re-read HEAD before removal"
      return 1
    fi
    if [[ "$revalidate_head" != "$got_head" ]]; then
      warn "guarded artifact cleanup: HEAD moved ($got_head → $revalidate_head) — refuse"
      return 1
    fi
    info "removing exact registered worktree $wt (non-force)"
    if ! git worktree remove "$wt" 2>/dev/null; then
      warn "git worktree remove failed for $wt — refuse force/rm -rf fallback"
      return 1
    fi
    git worktree prune 2>/dev/null || true
    if [[ -d "$wt" ]] || worktree_registered "$wt"; then
      warn "worktree $wt still present after remove — incomplete"
      return 1
    fi
  fi

  if [[ "$KEEP_BRANCH" -eq 1 ]]; then
    return 0
  fi

  # Local branch CAS delete against pre-frozen proven OID only.
  if git show-ref --verify --quiet "refs/heads/$br"; then
    if [[ -z "$frozen_local_oid" || ! "$frozen_local_oid" =~ ^[0-9a-f]{40}$ ]]; then
      warn "guarded artifact cleanup: no pre-frozen proven local OID for '$br' — refuse (no self-seed)"
      return 1
    fi
    # Re-read tip immediately before CAS; if it moved, refuse.
    local tip_now
    tip_now=$(git rev-parse --verify --quiet "refs/heads/$br" 2>/dev/null || true)
    if [[ "$tip_now" != "$frozen_local_oid" ]]; then
      warn "guarded artifact cleanup: local branch '$br' advanced ($frozen_local_oid → ${tip_now:-absent}) — refuse"
      return 1
    fi
    if ! git update-ref -d "refs/heads/$br" "$frozen_local_oid" 2>/dev/null; then
      warn "guarded artifact cleanup: local branch CAS delete refused for '$br' (expected $frozen_local_oid)"
      return 1
    fi
  fi

  # Remote branch: distinguish absent from unreadable; lease against pre-frozen OID only.
  if ! query_remote_branch_exact "$br"; then
    warn "guarded artifact cleanup: remote branch query unreadable for '$br': $REMOTE_BRANCH_REASON"
    return 1
  fi
  if [[ "$REMOTE_BRANCH_STATUS" == "present" ]]; then
    if [[ -z "$frozen_remote_oid" || ! "$frozen_remote_oid" =~ ^[0-9a-f]{40}$ ]]; then
      warn "guarded artifact cleanup: remote branch '$br' present but no pre-frozen proven remote OID — refuse (no self-seed at deletion time)"
      return 1
    fi
    if [[ "$REMOTE_BRANCH_OID" != "$frozen_remote_oid" ]]; then
      warn "guarded artifact cleanup: remote branch '$br' advanced ($frozen_remote_oid → $REMOTE_BRANCH_OID) — refuse"
      return 1
    fi
    if ! git push --force-with-lease="refs/heads/${br}:${frozen_remote_oid}" origin ":refs/heads/${br}" >/dev/null 2>&1; then
      warn "guarded artifact cleanup: remote lease delete refused for '$br' (lease $frozen_remote_oid)"
      return 1
    fi
  fi
  return 0
}

# Remove exactly one registered worktree path (CAS claimed-prune). Delegates
# to the guarded primitive for branch resolution when possible; still accepts
# an exact path that must already be registered on the expected branch.
# No --force, no rm -rf.
remove_exact_worktree() {
  local wt="$1" expect_br="${2:-}" got_br status_out got_head revalidate_head revalidate_branch
  wt="${wt%/}"
  if [[ -L "$wt" ]]; then
    warn "worktree path is a symlink — refuse removal: $wt"
    return 1
  fi
  if [[ ! -d "$wt" ]]; then
    warn "worktree path missing or not a directory — refuse removal: $wt"
    return 1
  fi
  if ! worktree_registered "$wt"; then
    warn "worktree path is not a registered git worktree — refuse removal (no default-path fallback): $wt"
    return 1
  fi
  if [[ -z "$expect_br" ]]; then
    warn "worktree exact-path removal requires a proven expected branch — refuse"
    return 1
  fi
  got_br=$(worktree_branch "$wt" || true)
  if [[ "$got_br" != "$expect_br" ]]; then
    warn "worktree branch mismatch at $wt (want '$expect_br', got '${got_br:-detached/unknown}') — refuse removal"
    return 1
  fi
  if ! status_out=$(git -C "$wt" status --porcelain 2>&1); then
    warn "cannot read worktree status for $wt — refuse removal"
    return 1
  fi
  if [[ -n "$status_out" ]]; then
    warn "worktree $wt is dirty/untracked — refuse removal"
    return 1
  fi
  got_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
  if [[ -z "$got_head" ]]; then
    warn "cannot read worktree HEAD for $wt — refuse removal"
    return 1
  fi
  # Immediate revalidation before non-force remove: branch + registration +
  # cleanliness + HEAD. Switching to a different branch at the same commit
  # must refuse (same commit is not branch identity).
  if ! status_out=$(git -C "$wt" status --porcelain 2>&1); then
    warn "cannot revalidate worktree status for $wt before removal — refuse"
    return 1
  fi
  if [[ -n "$status_out" ]]; then
    warn "worktree $wt became dirty before removal — refuse"
    return 1
  fi
  if ! worktree_registered "$wt"; then
    warn "worktree $wt no longer registered before removal — refuse"
    return 1
  fi
  revalidate_branch=$(worktree_branch "$wt" || true)
  if [[ "$revalidate_branch" != "$expect_br" ]]; then
    warn "worktree $wt switched off branch '$expect_br' (now '${revalidate_branch:-detached/unknown}') immediately before removal — refuse"
    return 1
  fi
  if ! revalidate_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || [[ "$revalidate_head" != "$got_head" ]]; then
    warn "worktree $wt HEAD moved before removal — refuse"
    return 1
  fi
  info "removing exact registered worktree $wt (non-force)"
  if ! git worktree remove "$wt" 2>/dev/null; then
    warn "git worktree remove failed for $wt — refuse force/rm -rf fallback"
    return 1
  fi
  git worktree prune 2>/dev/null || true
  if [[ -d "$wt" ]] || worktree_registered "$wt"; then
    warn "worktree $wt still present after remove — refuse success"
    return 1
  fi
  return 0
}

residual_after_release() {
  # ids in ALL_IDS that are not in TARGET_IDS (exact id compare only)
  local id
  printf '%s\n' "$ALL_IDS" | while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    printf '%s\n' "$TARGET_IDS" | grep -qxF -- "$id" || printf '%s\n' "$id"
  done
}
RESIDUAL_IDS=$(residual_after_release)

if [[ "$DRY" -eq 1 ]]; then
  # Fail-closed identity resolution before any plan text (#271). A pipeline
  # `while` would swallow `die`; use a here-doc so refusal exits the process.
  if [[ -n "$TARGET_IDS" && -z "$WORKTREE_PATH_ARG" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      if [[ "${TERMINAL_MODE:-0}" -eq 1 ]]; then
        _plan_br="$TERMINAL_HEAD_BRANCH"
        [[ -n "$_plan_br" ]] || die "terminal dry-run missing stored PR-evidence head branch for '$id'"
      else
        _plan_br="${EXPECTED_BRANCH:-$(branch_for "$id")}"
      fi
      if ! resolve_cleanup_target "$_plan_br" "$id"; then
        die "cannot plan cleanup target for '$id': $CLEANUP_TARGET_REASON"
      fi
    done <<EOF
$TARGET_IDS
EOF
  fi
  echo "DRY RUN would:"
  echo "  claim-table repo: $CANONICAL (branch: $(git rev-parse --abbrev-ref HEAD), left untouched)"
  echo "  product repo:     ${REPO_ARG:-${PR_REPO:-(unresolved)}}"
  if [[ -n "$TARGET_IDS" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      if [[ -n "$WORKTREE_PATH_ARG" ]]; then
        echo "  release claim:   $id"
        if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
          echo "    KEEP worktree:   $WORKTREE_PATH_ARG"
        else
          echo "    remove worktree: $WORKTREE_PATH_ARG (exact registered path only)"
        fi
        if [[ "$KEEP_BRANCH" -eq 1 ]]; then
          echo "    KEEP branch:     ${EXPECTED_BRANCH:-$(branch_for "$id")}"
        else
          echo "    delete branch:   ${EXPECTED_BRANCH:-$(branch_for "$id")}"
        fi
        echo "    live execution will revalidate clean status, exact/contained head SHA, branch/ref identity, claim renewal, and compare-and-swap conditions immediately before mutation"
      else
        if [[ "${TERMINAL_MODE:-0}" -eq 1 ]]; then
          _plan_br="$TERMINAL_HEAD_BRANCH"
        else
          _plan_br="${EXPECTED_BRANCH:-$(branch_for "$id")}"
        fi
        preview_verified_branch_cleanup "$id" "$_plan_br" \
          || die "cannot plan cleanup target for '$id': ${CLEANUP_TARGET_REASON:-unknown}"
      fi
    done <<EOF
$TARGET_IDS
EOF
  else
    echo "  release claim:   (none matched for issue $ISSUE)"
  fi
  if [[ -n "$RESIDUAL_IDS" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      echo "  KEEP sibling claim: $id (and keep the agent-claimed label)"
    done <<EOF
$RESIDUAL_IDS
EOF
  elif [[ "$KEEP_LABEL" -eq 1 ]]; then
    echo "  KEEP label agent-claimed on #$ISSUE (--keep-label: live sibling outside ledger)"
  else
    echo "  remove label agent-claimed from #$ISSUE"
  fi
  exit 0
fi

# Verified terminal PR-body evidence (#153): a dedicated, self-contained
# mutation path — never the ledger-oriented flow below, which assumes a
# ledger row and its early non-CAS worktree removal is exactly what AC1
# forbids for this claim shape. terminal_cleanup_release() always exits.
if [[ "${TERMINAL_MODE:-0}" -eq 1 ]]; then
  terminal_cleanup_release "$TARGET_IDS"
  exit 3  # unreachable: terminal_cleanup_release always exits above
fi

INCOMPLETE=0
PRESERVE_LABEL_EARLY=0

# --- worktrees + branches -------------------------------------------------
# Ordering contract (#73 + #153 exact-head P1 finding 5):
# EVERY path that deletes claim artifacts must wait until ledger mutation is
# successfully pushed and authoritatively revalidated. No ordinary early
# cleanup, no force remove, no rm -rf of default-path decoys, no branch -D.
# - --keep-worktree / --keep-branch never remove (reaper default).
DEFER_WT_BRANCH=1

# Pre-freeze proven branch OIDs BEFORE ledger mutation (#153 exact-head).
# Deletion later may only CAS/lease against these OIDs — never self-seed from
# whatever tip exists at deletion time (already-reused/advanced branches).
# Format: lines of "claim-id\tlocal-oid-or-empty\tremote-oid-or-empty"
FROZEN_ARTIFACT_OIDS=""
if [[ -n "$TARGET_IDS" && "$KEEP_BRANCH" -eq 0 ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    _fr_br="${EXPECTED_BRANCH:-$(branch_for "$id")}"
    _fr_local=""
    _fr_remote=""
    if git show-ref --verify --quiet "refs/heads/$_fr_br"; then
      _fr_local=$(git rev-parse --verify --quiet "refs/heads/$_fr_br" 2>/dev/null || true)
      if [[ -z "$_fr_local" || ! "$_fr_local" =~ ^[0-9a-f]{40}$ ]]; then
        warn "cannot pre-freeze local OID for '$_fr_br' before ledger mutation — branch deletion will refuse"
        _fr_local=""
      fi
    fi
    if query_remote_branch_exact "$_fr_br"; then
      if [[ "$REMOTE_BRANCH_STATUS" == "present" ]]; then
        if [[ -n "$REMOTE_BRANCH_OID" && "$REMOTE_BRANCH_OID" =~ ^[0-9a-f]{40}$ ]]; then
          _fr_remote="$REMOTE_BRANCH_OID"
        else
          warn "cannot pre-freeze remote OID for '$_fr_br' before ledger mutation — branch deletion will refuse"
        fi
      fi
      # absent remote: empty remote OID is fine (nothing to delete)
    else
      warn "remote branch query unreadable for '$_fr_br' before ledger mutation: $REMOTE_BRANCH_REASON — branch deletion will refuse"
    fi
    FROZEN_ARTIFACT_OIDS="${FROZEN_ARTIFACT_OIDS}${id}"$'\t'"${_fr_local}"$'\t'"${_fr_remote}"$'\n'
  done <<EOF
$TARGET_IDS
EOF
  unset _fr_br _fr_local _fr_remote
fi

lookup_frozen_oids() {
  # Sets FROZEN_LOCAL_OID / FROZEN_REMOTE_OID for claim id $1 from pre-strip freeze.
  local want="$1" line
  FROZEN_LOCAL_OID=""
  FROZEN_REMOTE_OID=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$(cut -f1 <<<"$line")" == "$want" ]]; then
      FROZEN_LOCAL_OID=$(cut -f2 <<<"$line")
      FROZEN_REMOTE_OID=$(cut -f3 <<<"$line")
      return 0
    fi
  done <<EOF
$FROZEN_ARTIFACT_OIDS
EOF
  return 0
}

if [[ -n "$TARGET_IDS" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
      if [[ -n "$WORKTREE_PATH_ARG" && -d "$WORKTREE_PATH_ARG" ]]; then
        info "keeping worktree $WORKTREE_PATH_ARG (--keep-worktree)"
      else
        info "keeping worktree for '$id' (--keep-worktree); path resolved only after verified ledger push"
      fi
    else
      # Non-destructive precheck only for claimed prune path.
      if [[ -n "$WORKTREE_PATH_ARG" ]]; then
        if [[ -L "$WORKTREE_PATH_ARG" ]] || [[ ! -d "$WORKTREE_PATH_ARG" ]] || ! worktree_registered "$WORKTREE_PATH_ARG"; then
          warn "claimed prune target unsafe/unregistered before CAS — will not remove; claim strip may still proceed with incomplete prune"
        elif [[ -n "${EXPECTED_BRANCH:-}" ]]; then
          _pre_br=$(worktree_branch "$WORKTREE_PATH_ARG" || true)
          if [[ "$_pre_br" != "$EXPECTED_BRANCH" ]]; then
            warn "claimed prune branch mismatch before CAS (want '$EXPECTED_BRANCH', got '${_pre_br:-detached}') — will revalidate after ledger removal"
          fi
        fi
        info "deferring exact worktree removal until verified cleanup push succeed: $WORKTREE_PATH_ARG"
      else
        info "deferring worktree removal until verified ledger push + union revalidation succeed"
      fi
    fi
    if [[ "$KEEP_BRANCH" -eq 1 ]]; then
      :
    else
      info "deferring branch deletion until verified ledger push + union revalidation succeed"
    fi
  done <<EOF
$TARGET_IDS
EOF
fi

# --- claim rows, from a disposable main worktree --------------------------
# L-009: never `git checkout main` in the caller's tree. It may be on a
# long-lived branch or dirty, and aborting here used to strand the claim row.
#
# CLEANUP_BASE / CLEANUP_PUSHED_SHA / CLEANUP_DID_PUSH are written for the
# post-mutation reread: that path must bind only to origin/$CLEANUP_BASE (the
# exact remote branch that received the cleanup push) and prove it contains
# $CLEANUP_PUSHED_SHA. Never fall back to local main|master after mutation.
# After a successful cleanup push, missing/unreadable CLEANUP_PUSHED_SHA is a
# hard release failure — lineage proof is mandatory, never skippable.
CLEANUP_BASE=""
CLEANUP_PUSHED_SHA=""
CLEANUP_DID_PUSH=0

strip_claim_rows() {
  CLEANUP_PUSHED_SHA=""
  CLEANUP_DID_PUSH=0
  local base strip_ref
  # Every mode: successful fetch of one exact remote base; no local fallback.
  if ! base=$(fetch_remote_base); then
    warn "strip: fetch of remote base failed — refuse cleanup (no local/cached fallback)${CLEANUP_FETCH_REASON:+: $CLEANUP_FETCH_REASON}"
    return 1
  fi
  CLEANUP_BASE="$base"
  strip_ref="origin/${base}"
  REF="$strip_ref"

  # From the freshly fetched exact remote base, construct and validate all
  # ledger representations for the target ids (mixed-rep refuse).
  local _sid
  while IFS= read -r _sid; do
    [[ -n "$_sid" ]] || continue
    if ! count_ledger_reps_at_ref "$_sid" "$strip_ref"; then
      warn "strip: unreadable ledger representation evidence for '$_sid' at $strip_ref — refuse (unreadable is not absence)"
      return 1
    fi
    if [[ "$LEDGER_FILE_REP" -eq 1 && "$LEDGER_LEGACY_REP" -eq 1 ]]; then
      warn "strip: mixed ledger representations for '$_sid' at $strip_ref — refuse push"
      return 1
    fi
  done <<EOF
$TARGET_IDS
EOF

  # Fresh fully validated PR inventory + same-ID/same-issue protection against
  # this exact ledger snapshot — BEFORE any disposable mutation or push.
  if ! revalidate_authoritative_union_soft "$TARGET_IDS" "$strip_ref" "pre-strip ledger snapshot"; then
    warn "strip: pre-strip authoritative union revalidation refused — zero ledger mutation"
    return 1
  fi

  local tmpwt
  tmpwt=$(mktemp -d "${TMPDIR:-/tmp}/gibson-release-claim.XXXXXX") || return 1
  # Disposable strip worktree: attach only to origin/$base (never local base).
  # The directory itself is a temp we created empty; worktree add populates it.
  # Cleanup uses non-force worktree remove when registered, else rmdir of empty
  # temp only — never claim-artifact paths.
  if ! git worktree add --detach "$tmpwt" "origin/$base" >/dev/null 2>&1; then
    warn "strip: cannot attach disposable worktree to origin/$base — refuse (no local base fallback)"
    rmdir "$tmpwt" 2>/dev/null || true
    return 1
  fi

  local rc=0
  (
    cd "$tmpwt" || exit 1
    local touched=0

    # CAS: re-verify exact frozen blob/path (or legacy active-work blob+row)
    # before any mutation. If evidence changed, refuse — renewed claim survives.
    if [[ "${CAS_MODE:-0}" -eq 1 ]]; then
      local id cas_path cas_blob cur_blob active_blob exp_active exp_id
      id=$(printf '%s\n' "$TARGET_IDS" | head -n1)
      if [[ "$EXPECTED_SOURCE" == "file" ]]; then
        cas_path="${EXPECTED_CLAIM_PATH}"
        cas_blob="${EXPECTED_CLAIM_BLOB}"
        if [[ ! -f "$cas_path" ]]; then
          echo "release-claim.sh: ERROR: CAS expected path absent at origin/$base: $cas_path" >&2
          exit 1
        fi
        cur_blob=$(git ls-files -s -- "$cas_path" 2>/dev/null | awk '{print $2; exit}')
        if [[ -z "$cur_blob" ]]; then
          cur_blob=$(git rev-parse "HEAD:$cas_path" 2>/dev/null || true)
        fi
        if [[ -z "$cur_blob" || "$cur_blob" != "$cas_blob" ]]; then
          echo "release-claim.sh: ERROR: CAS blob OID mismatch for $cas_path (want $cas_blob, got ${cur_blob:-absent}) — refuse (renewed/changed claim survives)" >&2
          exit 1
        fi
        # Path must match docs/claims/<claim-id>.md for the frozen id
        if [[ "$cas_path" != "docs/claims/${id}.md" ]]; then
          echo "release-claim.sh: ERROR: CAS path $cas_path does not match frozen claim id $id" >&2
          exit 1
        fi
      elif [[ "$EXPECTED_SOURCE" == "legacy" ]]; then
        # EXPECTED_CLAIM_BLOB = "<active-work-blob>:<claim-id>"
        exp_active="${EXPECTED_CLAIM_BLOB%%:*}"
        exp_id="${EXPECTED_CLAIM_BLOB#*:}"
        if [[ "$exp_id" != "$id" ]]; then
          echo "release-claim.sh: ERROR: CAS legacy blob key claim-id mismatch" >&2
          exit 1
        fi
        if [[ ! -f docs/active-work.md ]]; then
          echo "release-claim.sh: ERROR: CAS legacy active-work.md absent — refuse" >&2
          exit 1
        fi
        active_blob=$(git rev-parse HEAD:docs/active-work.md 2>/dev/null || true)
        if [[ -z "$active_blob" || "$active_blob" != "$exp_active" ]]; then
          echo "release-claim.sh: ERROR: CAS legacy active-work blob mismatch (want $exp_active, got ${active_blob:-absent}) — refuse (renewed row survives)" >&2
          exit 1
        fi
        if ! awk -F'|' -v want="$id" '
          /^\|/ {
            cid=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",cid);
            if (cid==want) found=1
          }
          END { exit !found }
        ' docs/active-work.md; then
          echo "release-claim.sh: ERROR: CAS legacy row for $id absent after blob match — refuse" >&2
          exit 1
        fi
      fi
    fi

    # Mixed-rep recheck inside the disposable tree (second representation
    # could appear after the outer snapshot if another actor pushed).
    local id
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      local has_f=0 has_l=0
      [[ -f "docs/claims/${id}.md" ]] && has_f=1
      if [[ -f docs/active-work.md ]] && awk -F'|' -v want="$id" '
        /^\|/ {
          cid=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",cid);
          if (cid==want) found=1
        }
        END { exit !found }
      ' docs/active-work.md; then
        has_l=1
      fi
      if [[ "$has_f" -eq 1 && "$has_l" -eq 1 ]]; then
        echo "release-claim.sh: ERROR: mixed ledger representations for '$id' inside strip worktree — refuse" >&2
        exit 1
      fi
    done <<EOF
$TARGET_IDS
EOF

    # per-lane claim files (current form) — exact id only
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      if [[ -f "docs/claims/$id.md" ]]; then
        # Re-check file OID immediately before rm when CAS
        if [[ "${CAS_MODE:-0}" -eq 1 && "$EXPECTED_SOURCE" == "file" ]]; then
          cur_blob=$(git rev-parse "HEAD:docs/claims/${id}.md" 2>/dev/null || true)
          if [[ "$cur_blob" != "$EXPECTED_CLAIM_BLOB" ]]; then
            echo "release-claim.sh: ERROR: CAS pre-rm blob race for $id" >&2
            exit 1
          fi
        fi
        git rm -q "docs/claims/$id.md" || exit 1
        touched=1
      fi
    done <<EOF
$TARGET_IDS
EOF

    # legacy shared table — compare only the claim-id column (field 3). Text
    # in scope/session/notes that mentions a target id must never delete a row.
    local active=docs/active-work.md
    if [[ -f "$active" ]]; then
      local tmp line cid keep id touched_legacy
      tmp=$(mktemp) || exit 1
      touched_legacy=0
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\| ]]; then
          cid=$(printf '%s\n' "$line" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          keep=1
          if [[ -n "$cid" && "$cid" != "claim-id" && "$cid" != "---" && ! "$cid" =~ ^-+$ ]]; then
            while IFS= read -r id; do
              [[ -n "$id" ]] || continue
              if [[ "$cid" == "$id" ]]; then
                keep=0
                touched_legacy=1
                break
              fi
            done <<EOF
$TARGET_IDS
EOF
          fi
          if [[ "$keep" -eq 1 ]]; then
            printf '%s\n' "$line" >> "$tmp"
          fi
        else
          printf '%s\n' "$line" >> "$tmp"
        fi
      done < "$active"
      if [[ "$touched_legacy" -eq 1 ]]; then
        # CAS legacy: re-verify active-work blob still matches before replace
        if [[ "${CAS_MODE:-0}" -eq 1 && "$EXPECTED_SOURCE" == "legacy" ]]; then
          active_blob=$(git rev-parse HEAD:docs/active-work.md 2>/dev/null || true)
          exp_active="${EXPECTED_CLAIM_BLOB%%:*}"
          if [[ "$active_blob" != "$exp_active" ]]; then
            rm -f "$tmp"
            echo "release-claim.sh: ERROR: CAS legacy pre-write blob race — refuse" >&2
            exit 1
          fi
        fi
        mv "$tmp" "$active"
        git add "$active" || exit 1
        touched=1
      else
        rm -f "$tmp"
      fi
    fi

    [[ "$touched" -eq 1 ]] || exit 2  # nothing to strip
    git commit -s -q -m "release-claim: ${TARGET_IDS:-issue-${ISSUE}}

Post-merge cleanup per Law 10 / docs/05." || exit 1

    # Immediate pre-push revalidation (CAS only): fresh PR inventory +
    # same-ID/same-issue protection. Non-CAS ordinary release relies on the
    # initial inventory + post-mutation residual reread so fixture call-count
    # contracts (call 1 pre-mutation, call 2 post-mutation sibling) stay
    # aligned; CAS/reaper always re-lists at the push boundary.
    if [[ "${CAS_MODE:-0}" -eq 1 && -n "${PR_REPO:-}" && -x "$SCRIPT_DIR/pr-claims.sh" ]]; then
      local pre_push_rows pre_push_rc=0
      pre_push_rows=$("$SCRIPT_DIR/pr-claims.sh" list "$PR_REPO" 2>&1) || pre_push_rc=$?
      if [[ "$pre_push_rc" -ne 0 ]]; then
        echo "release-claim.sh: ERROR: pre-push PR inventory re-read failed — refuse remote ledger push: $pre_push_rows" >&2
        exit 1
      fi
      local _prline _pfields
      while IFS= read -r _prline; do
        [[ -n "$_prline" ]] || continue
        _pfields=$(printf '%s\n' "$_prline" | awk -F'\t' '{print NF}')
        if [[ "$_pfields" -ne 8 ]]; then
          echo "release-claim.sh: ERROR: pre-push PR inventory malformed row — refuse remote ledger push" >&2
          exit 1
        fi
        local _pid _pnum
        _pnum=$(cut -f1 <<<"$_prline")
        _pid=$(cut -f2 <<<"$_prline")
        if printf '%s\n' "$TARGET_IDS" | grep -qxF -- "$_pid"; then
          echo "release-claim.sh: ERROR: pre-push: open PR #${_pnum} carries exact claim id '${_pid}' — refuse remote ledger push" >&2
          exit 1
        fi
        case "$_pid" in
          "issue-${ISSUE}-"*)
            echo "release-claim.sh: ERROR: pre-push: open PR #${_pnum} claim '${_pid}' holds issue #${ISSUE} — refuse remote ledger push" >&2
            exit 1
            ;;
        esac
        if [[ "$_pid" =~ ^issue-[A-Za-z][A-Za-z0-9]*-${ISSUE}- ]]; then
          echo "release-claim.sh: ERROR: pre-push: open PR #${_pnum} claim '${_pid}' holds issue #${ISSUE} — refuse remote ledger push" >&2
          exit 1
        fi
      done <<EOF
$pre_push_rows
EOF
    fi

    # Normal push only (no force). If remote advanced (renewal) push fails → incomplete.
    git push origin "HEAD:$base" || exit 1
  ) || rc=$?

  # Capture the exact pushed cleanup commit while the disposable worktree still
  # holds it — post-mutation reread must prove origin/$base contains this SHA.
  if [[ $rc -eq 0 ]]; then
    CLEANUP_DID_PUSH=1
    CLEANUP_PUSHED_SHA=$(git -C "$tmpwt" rev-parse HEAD 2>/dev/null || true)
    if [[ -z "$CLEANUP_PUSHED_SHA" ]]; then
      warn "cleanup push succeeded but cleanup-pushed SHA is missing/unreadable — cannot prove lineage; preserving agent-claimed"
    fi
  fi

  # Disposable strip worktree only — not a claim artifact. Prefer non-force
  # remove; fall back to force only for this temp path we created empty.
  if ! git worktree remove "$tmpwt" >/dev/null 2>&1; then
    git worktree remove --force "$tmpwt" >/dev/null 2>&1 || rm -rf "$tmpwt"
  fi
  git worktree prune >/dev/null 2>&1 || true
  return $rc
}

# Soft-fail twin of require_readable_regular_blob for post-mutation reread.
# Same predicates as #61 startup; returns 1 with an exact path/object reason
# instead of dying (mutation already ran → incomplete is exit 3, not 1).
soft_require_readable_regular_blob() {
  local path="$1" mode="$2" typ="$3" obj="$4"
  if [[ "$typ" != "blob" ]] || [[ "$mode" != "100644" && "$mode" != "100755" ]]; then
    warn "$path at $REF has unexpected Git mode/type ($mode $typ${obj:+ $obj}) — post-cleanup ledger unusable for label decision"
    return 1
  fi
  if [[ -z "$obj" ]]; then
    warn "$path at $REF has no object id — post-cleanup ledger unusable for label decision"
    return 1
  fi
  if ! git cat-file -e "$obj" 2>/dev/null; then
    warn "$path exists in the ledger tree at $REF but its blob is unreadable/corrupt/unfetchable ($obj) — post-cleanup ledger unusable for label decision"
    return 1
  fi
  local got_type
  got_type=$(git cat-file -t "$obj" 2>/dev/null || true)
  if [[ "$got_type" != "blob" ]]; then
    warn "$path at $REF object $obj has unexpected type '${got_type:-unreadable}' (want blob) — post-cleanup ledger unusable for label decision"
    return 1
  fi
  if ! git cat-file blob "$obj" >/dev/null 2>&1; then
    warn "$path exists in the ledger tree at $REF but its blob payload is unreadable/corrupt ($obj) — post-cleanup ledger unusable for label decision"
    return 1
  fi
  return 0
}

# Authoritative post-mutation reread of the exact remote-tracking ref that
# received the cleanup push (origin/$CLEANUP_BASE). Reuses #61's strict
# ref/tree/per-claim blob validation (fetch that branch → resolve only that
# origin ref → tree → active-work → claims tree → every claim leaf →
# claim_ids_all) and proves the ref contains the just-pushed cleanup commit.
# On success updates REF, TREE_SHA and sets POST_ISSUE_IDS to issue-scoped ids
# actually present. On any failure: warn the exact reason and return 1.
# NEVER falls back to local main|master, HEAD, a cached pre-mutation residual
# plan, or any other branch — that is how a stale empty local main falsely
# authorized remove-label after origin/$CLEANUP_BASE became unreadable.
authoritative_post_mutation_reread() {
  POST_ISSUE_IDS=""
  local base="${CLEANUP_BASE:-}"
  if [[ -z "$base" ]]; then
    warn "post-cleanup: cleanup base branch unset — cannot bind reread to the pushed remote ref; preserving agent-claimed"
    return 1
  fi
  local remote_ref="origin/${base}"

  # Fetch only the exact branch that received the cleanup push.
  if ! git fetch origin "$base" >/dev/null 2>&1; then
    warn "post-cleanup fetch of origin failed — cannot revalidate ledger ref ${remote_ref} for label decision; preserving agent-claimed"
    return 1
  fi

  # Strict: only origin/$base. No resolve_ledger_ref local main|master fallback.
  if ! git rev-parse --verify --quiet "${remote_ref}^{commit}" >/dev/null 2>&1; then
    warn "post-cleanup: exact remote ledger ref ${remote_ref} is absent/unreadable after fetch — preserving agent-claimed (no local fallback)"
    return 1
  fi

  # Just-pushed cleanup must be on that remote-tracking ref. After a successful
  # cleanup push, lineage proof is mandatory — never skip when the capture SHA
  # is empty/unreadable (that used to authorize remove-label + OK).
  if [[ "${CLEANUP_DID_PUSH:-0}" -eq 1 ]]; then
    if [[ -z "${CLEANUP_PUSHED_SHA:-}" ]]; then
      warn "post-cleanup: cleanup-pushed SHA missing/unreadable after successful push — cannot prove lineage on ${remote_ref}; preserving agent-claimed"
      return 1
    fi
    if ! git rev-parse --verify --quiet "${CLEANUP_PUSHED_SHA}^{commit}" >/dev/null 2>&1; then
      warn "post-cleanup: just-pushed cleanup commit ${CLEANUP_PUSHED_SHA} is unreadable — preserving agent-claimed"
      return 1
    fi
    if ! git merge-base --is-ancestor "$CLEANUP_PUSHED_SHA" "$remote_ref" 2>/dev/null; then
      warn "post-cleanup: ${remote_ref} does not contain just-pushed cleanup commit ${CLEANUP_PUSHED_SHA} — preserving agent-claimed"
      return 1
    fi
  fi

  REF="$remote_ref"
  if ! git rev-parse --verify --quiet "${REF}^{commit}" >/dev/null 2>&1; then
    warn "post-cleanup: ledger ref $REF does not resolve to a commit — preserving agent-claimed"
    return 1
  fi
  TREE_SHA=$(git rev-parse --verify "${REF}^{tree}" 2>/dev/null || true)
  if [[ -z "$TREE_SHA" ]]; then
    TREE_SHA=$(git cat-file -p "${REF}^{commit}" 2>/dev/null | awk '/^tree / {print $2; exit}')
  fi
  if [[ -z "$TREE_SHA" ]]; then
    warn "post-cleanup: ledger commit at $REF has no tree pointer — preserving agent-claimed"
    return 1
  fi
  if ! git cat-file -e "$TREE_SHA" 2>/dev/null; then
    warn "post-cleanup: ledger commit at $REF references an unreadable/corrupt tree ($TREE_SHA) — preserving agent-claimed"
    return 1
  fi
  if ! git ls-tree "$TREE_SHA" >/dev/null 2>&1; then
    warn "post-cleanup: cannot list tree for ledger commit $REF (unreadable/corrupt tree $TREE_SHA) — preserving agent-claimed"
    return 1
  fi

  local active_line active_ls_err="" claims_self claims_self_err="" claims_lines claims_ls_err=""
  active_line=$(git ls-tree "$REF" -- docs/active-work.md 2>&1) || active_ls_err=$?
  if [[ -n "$active_ls_err" ]]; then
    warn "post-cleanup: cannot list docs/active-work.md at $REF — preserving agent-claimed"
    return 1
  fi
  if [[ -n "$active_line" ]]; then
    local amode atype ablob
    amode=$(printf '%s\n' "$active_line" | awk '{print $1; exit}')
    atype=$(printf '%s\n' "$active_line" | awk '{print $2; exit}')
    ablob=$(printf '%s\n' "$active_line" | awk '{print $3; exit}')
    soft_require_readable_regular_blob "docs/active-work.md" "$amode" "$atype" "$ablob" || return 1
  fi

  claims_self=$(git ls-tree "$REF" -- docs/claims 2>&1) || claims_self_err=$?
  if [[ -n "$claims_self_err" ]]; then
    warn "post-cleanup: cannot list docs/claims at $REF — preserving agent-claimed"
    return 1
  fi
  if [[ -n "$claims_self" ]]; then
    local csmode cstype csobj
    csmode=$(printf '%s\n' "$claims_self" | awk '{print $1; exit}')
    cstype=$(printf '%s\n' "$claims_self" | awk '{print $2; exit}')
    csobj=$(printf '%s\n' "$claims_self" | awk '{print $3; exit}')
    if [[ "$cstype" != "tree" ]] || [[ "$csmode" != "040000" ]]; then
      warn "post-cleanup: docs/claims at $REF has unexpected Git mode/type ($csmode $cstype${csobj:+ $csobj}) — want 040000 tree; preserving agent-claimed"
      return 1
    fi
    if [[ -z "$csobj" ]] || ! git cat-file -e "$csobj" 2>/dev/null; then
      warn "post-cleanup: docs/claims tree at $REF is unreadable/corrupt${csobj:+ ($csobj)} — preserving agent-claimed"
      return 1
    fi
    if ! git ls-tree "$csobj" >/dev/null 2>&1; then
      warn "post-cleanup: cannot list docs/claims tree at $REF (unreadable/corrupt tree ${csobj}) — preserving agent-claimed"
      return 1
    fi
    claims_lines=$(git ls-tree "$REF" docs/claims/ 2>&1) || claims_ls_err=$?
    if [[ -n "$claims_ls_err" ]]; then
      warn "post-cleanup: cannot read docs/claims/ at $REF — preserving agent-claimed"
      return 1
    fi
    if [[ -n "$claims_lines" ]]; then
      local claim_line claim_mode claim_type claim_obj claim_path
      while IFS= read -r claim_line; do
        [[ -n "$claim_line" ]] || continue
        claim_mode=$(printf '%s\n' "$claim_line" | awk '{print $1; exit}')
        claim_type=$(printf '%s\n' "$claim_line" | awk '{print $2; exit}')
        claim_obj=$(printf '%s\n' "$claim_line" | awk '{print $3; exit}')
        claim_path="${claim_line#*$'\t'}"
        [[ -n "$claim_path" ]] || claim_path="docs/claims/<unknown>"
        soft_require_readable_regular_blob "$claim_path" "$claim_mode" "$claim_type" "$claim_obj" || return 1
      done <<EOF
$claims_lines
EOF
    fi
  fi

  local post_live
  if ! post_live=$(claim_ids_all); then
    warn "post-cleanup: claim ledger parse incomplete/ambiguous at $REF — preserving agent-claimed"
    return 1
  fi
  POST_ISSUE_IDS=$(issue_claim_ids_from "$post_live")
  return 0
}

# Label removal is permitted only after BOTH:
#   (a) every requested target representation was successfully removed and pushed
#       (or was already absent — strip rc 2); and
#   (b) a fresh, fully validated authoritative reread of the exact remote-
#       tracking ref that received the cleanup push (origin/$CLEANUP_BASE)
#       proves no target remains and no sibling for the issue remains. That
#       path never falls back to local main|master.
# Strip/push failure, target still live, fetch/ref/tree/blob failure, missing
# cleanup lineage, or incomplete parse → incomplete, preserve label, never
# claim it was removed.
PRESERVE_LABEL=0
STRIP_OK=1
if [[ "${PRESERVE_LABEL_EARLY:-0}" -eq 1 ]]; then
  PRESERVE_LABEL=1
fi

if [[ -n "$TARGET_IDS" ]]; then
  set +e
  strip_claim_rows
  strip_rc=$?
  set -e
  case "$strip_rc" in
    0) info "claim removed" ;;
    2) info "no claim to remove at $REF" ;;
    *)
      warn "claim NOT removed for issue $ISSUE — strip failed (rc=$strip_rc)."
      warn "Fix by hand on main: git rm the docs/claims/<id>.md file(s) for exact id(s) '$TARGET_IDS' (or drop those claim-id column rows from docs/active-work.md), then push."
      INCOMPLETE=1
      STRIP_OK=0
      PRESERVE_LABEL=1
      ;;
  esac

  # Discard the pre-mutation residual plan. Only an authoritative reread of
  # live ids may decide label policy — never subtract TARGET_IDS from stale state.
  RESIDUAL_IDS=""
  ALL_IDS=""
  POST_ISSUE_IDS=""

  if ! authoritative_post_mutation_reread; then
    INCOMPLETE=1
    PRESERVE_LABEL=1
  else
    ALL_IDS="$POST_ISSUE_IDS"
    # Classify from ids actually present on the validated reread.
    # Use if/then (not grep &&) so set -e cannot abort on a non-target id.
    targets_remaining=$(
      printf '%s\n' "$ALL_IDS" | while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if printf '%s\n' "$TARGET_IDS" | grep -qxF -- "$id"; then
          printf '%s\n' "$id"
        fi
      done
    )
    RESIDUAL_IDS=$(
      printf '%s\n' "$ALL_IDS" | while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if printf '%s\n' "$TARGET_IDS" | grep -qxF -- "$id"; then
          :
        else
          printf '%s\n' "$id"
        fi
      done
    )
    if [[ -n "$targets_remaining" ]]; then
      warn "target claim(s) still live on $REF after cleanup attempt:"
      printf '%s\n' "$targets_remaining" | sed 's/^/  /' >&2
      INCOMPLETE=1
      PRESERVE_LABEL=1
    elif [[ "$STRIP_OK" -eq 0 ]]; then
      # Strip/push failed even if the reread looks empty — do not remove label.
      PRESERVE_LABEL=1
    fi
  fi

  # GitHub-native sibling check (#153 AC1/AC4): the one authoritative live-
  # claim view is ledger rows UNION live open PR-body claims, not the ledger
  # alone — a sibling slice can be a still-open PR-body claim with no ledger
  # row at all.
  #
  # (#153 review P1) This read used to be `2>/dev/null || true`. That turned a
  # missing reader, an expired token, a rate limit, or a mid-pagination
  # failure into "no open sibling claims" — and an unread inventory then
  # authorized removing agent-claimed off an issue another live lane still
  # holds. An unreadable or malformed inventory is not an empty one: it
  # preserves the label and reports INCOMPLETE (exit 3). Only a successfully
  # read, shape-valid inventory may decide that no sibling remains.
  if [[ -n "${PR_REPO:-}" ]]; then
    if [[ ! -x "$SCRIPT_DIR/pr-claims.sh" ]]; then
      warn "the authoritative PR-claim reader $SCRIPT_DIR/pr-claims.sh is missing or not executable — cannot check for live open sibling claims on $PR_REPO; preserving agent-claimed"
      INCOMPLETE=1
      PRESERVE_LABEL=1
    elif ! _open_pr_rows=$("$SCRIPT_DIR/pr-claims.sh" list "$PR_REPO" 2>&1); then
      warn "post-mutation reread of live PR-body claims failed for $PR_REPO — an unreadable claim inventory is not an empty one; preserving agent-claimed: $_open_pr_rows"
      INCOMPLETE=1
      PRESERVE_LABEL=1
    elif ! open_pr_rows_valid "$_open_pr_rows"; then
      warn "post-mutation reread of live PR-body claims returned a malformed/truncated row for $PR_REPO — cannot tell whether a sibling claim survives; preserving agent-claimed: $OPEN_PR_BAD_ROW"
      INCOMPLETE=1
      PRESERVE_LABEL=1
    else
      # (#153 exact-head P1) Open PR-body claims for this issue are residual
      # live work — INCLUDING an open PR whose claim id equals a TARGET_IDS
      # entry. An open exact target is live evidence, never a sibling to
      # ignore because its id matches the cleanup target. Excluding same-ID
      # open rows previously authorized label removal while live PRs held
      # the claim.
      _open_pr_siblings=""
      _open_pr_same_id=""
      while IFS= read -r _pr_row; do
        [[ -n "$_pr_row" ]] || continue
        _pr_id=$(cut -f2 <<<"$_pr_row")
        [[ -n "$_pr_id" ]] || continue
        claim_id_for_issue "$_pr_id" || continue
        if printf '%s\n' "$TARGET_IDS" | grep -qxF -- "$_pr_id"; then
          _open_pr_same_id="${_open_pr_same_id}${_pr_id}"$'\n'
        fi
        _open_pr_siblings="${_open_pr_siblings}${_pr_id}"$'\n'
      done <<EOF
$_open_pr_rows
EOF
      _open_pr_siblings=$(printf '%s\n' "$_open_pr_siblings" | grep -E '^issue-' | sort -u || true)
      _open_pr_same_id=$(printf '%s\n' "$_open_pr_same_id" | grep -E '^issue-' | sort -u || true)
      if [[ -n "$_open_pr_same_id" ]]; then
        warn "open PR-body claim still carries exact target id(s) after ledger cleanup — treating as residual live work; preserving agent-claimed: $(printf '%s' "$_open_pr_same_id" | tr '\n' ' ')"
        INCOMPLETE=1
        PRESERVE_LABEL=1
      fi
      if [[ -n "$_open_pr_siblings" ]]; then
        RESIDUAL_IDS=$(printf '%s\n%s\n' "$RESIDUAL_IDS" "$_open_pr_siblings" | grep -E '^issue-' | sort -u || true)
      fi
      unset _open_pr_same_id _pr_row _pr_id
    fi
  fi
else
  info "no claim to remove"
fi

# --- deferred worktree/branch removal (every ledger path) -----------------
# Only after successful strip AND authoritative reread proves the exact target
# claim is absent, AND a fresh union revalidation against the post-push remote
# shows no same-ID open PR / second representation. Failures leave
# worktree+branch untouched and report incomplete. Never force/rm -rf/branch -D.
if [[ -n "$TARGET_IDS" && "$DEFER_WT_BRANCH" -eq 1 ]]; then
  deferred_ok=1
  if [[ "$STRIP_OK" -ne 1 || "$INCOMPLETE" -eq 1 || "$PRESERVE_LABEL" -eq 1 ]]; then
    if [[ "$KEEP_WORKTREE" -eq 0 ]]; then
      info "leaving worktree(s) untouched — cleanup incomplete or target still live"
    fi
    if [[ "$KEEP_BRANCH" -eq 0 ]]; then
      info "leaving branch(es) untouched — cleanup incomplete or target still live"
    fi
    deferred_ok=0
  fi

  # Post-push union revalidation before ANY artifact mutation (#153 P1).
  if [[ "$deferred_ok" -eq 1 ]]; then
    post_art_base=""
    post_art_ref=""
    if ! post_art_base=$(fetch_remote_base); then
      warn "post-push: cannot re-fetch remote base before artifact cleanup — refuse artifact mutation${CLEANUP_FETCH_REASON:+: $CLEANUP_FETCH_REASON}"
      INCOMPLETE=1
      PRESERVE_LABEL=1
      deferred_ok=0
    else
      post_art_ref="origin/${post_art_base}"
      REF="$post_art_ref"
      CLEANUP_BASE="$post_art_base"
      if ! revalidate_authoritative_union_soft "$TARGET_IDS" "$post_art_ref" "post-push pre-artifact" "post-push"; then
        warn "post-push pre-artifact union revalidation refused — leave worktree/branch/label untouched"
        INCOMPLETE=1
        PRESERVE_LABEL=1
        deferred_ok=0
      else
        # Target id must be absent from ledger after successful strip.
        post_live=""
        if ! post_live=$(claim_ids_all); then
          warn "post-push: cannot read ledger before artifact cleanup — refuse"
          INCOMPLETE=1
          PRESERVE_LABEL=1
          deferred_ok=0
        else
          _still=""
          while IFS= read -r _t; do
            [[ -n "$_t" ]] || continue
            if printf '%s\n' "$post_live" | grep -qxF -- "$_t"; then
              _still="${_still}${_t} "
            fi
          done <<EOF
$TARGET_IDS
EOF
          if [[ -n "$_still" ]]; then
            warn "post-push: target claim(s) still live before artifact cleanup: $_still — refuse"
            INCOMPLETE=1
            PRESERVE_LABEL=1
            deferred_ok=0
          fi
        fi
      fi
    fi
  fi

  if [[ "$deferred_ok" -eq 1 ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      br="${EXPECTED_BRANCH:-$(branch_for "$id")}"
      lookup_frozen_oids "$id"
      if [[ -n "$WORKTREE_PATH_ARG" ]]; then
        # Claimed prune: exact path only for worktree; then branch CAS/lease.
        info "post-CAS: revalidating exact registered worktree before prune"
        if [[ "$KEEP_WORKTREE" -eq 0 ]]; then
          if ! remove_exact_worktree "$WORKTREE_PATH_ARG" "${EXPECTED_BRANCH:-$br}"; then
            warn "final claimed worktree removal failed for $WORKTREE_PATH_ARG — incomplete (claim row already released; not claiming full success)"
            INCOMPLETE=1
            PRESERVE_LABEL=1
            deferred_ok=0
          fi
        fi
        if [[ "$KEEP_BRANCH" -eq 0 && "$deferred_ok" -eq 1 ]]; then
          # Branch-only CAS/lease (worktree already handled above). Temporarily
          # force keep-worktree so the guarded primitive only touches branches.
          # OIDs are the pre-strip proven freeze — never empty self-seed.
          _save_kw="$KEEP_WORKTREE"
          KEEP_WORKTREE=1
          if ! guarded_remove_claim_artifacts "$id" "$br" "${FROZEN_LOCAL_OID:-}" "${FROZEN_REMOTE_OID:-}"; then
            warn "final branch CAS/lease removal failed for '$br' — incomplete"
            INCOMPLETE=1
            PRESERVE_LABEL=1
            deferred_ok=0
          fi
          KEEP_WORKTREE="$_save_kw"
        fi
      else
        # Ordinary / CAS without exact path: full guarded artifact cleanup with
        # pre-frozen proven OIDs only.
        if [[ "$KEEP_WORKTREE" -eq 1 && "$KEEP_BRANCH" -eq 1 ]]; then
          :
        elif ! guarded_remove_claim_artifacts "$id" "$br" "${FROZEN_LOCAL_OID:-}" "${FROZEN_REMOTE_OID:-}"; then
          warn "guarded artifact cleanup incomplete for '$id' / '$br' — not claiming full success"
          INCOMPLETE=1
          PRESERVE_LABEL=1
          deferred_ok=0
        fi
      fi
    done <<EOF
$TARGET_IDS
EOF
  fi
fi

# --- label ----------------------------------------------------------------
# L-027: the old code swallowed gh's stderr and logged success unconditionally.
if command -v gh >/dev/null; then
  # PR_REPO is the already-resolved identity (--repo, then gh, then this
  # checkout's origin) — resolved once, up front, and never swallowed
  # (#153 review P1). Do not re-ask gh here and re-introduce the failure mode.
  REPO="${REPO_ARG:-${PR_REPO:-}}"
  if [[ "$PRESERVE_LABEL" -eq 1 ]]; then
    # Incomplete cleanup (strip/push/reread/target still live): never call
    # remove-label. A live claim with no agent-claimed label is the defect.
    info "preserving agent-claimed on #$ISSUE — incomplete cleanup; not removing label"
  elif [[ -n "$RESIDUAL_IDS" ]]; then
    # L-024: siblings are still working this issue, so agent-claimed must
    # stay. (#153 review P1) "Must stay" is a postcondition, not a hope: a
    # sibling row proves the label SHOULD be there, never that it IS. Re-read
    # it. Absent, or unreadable, is INCOMPLETE — a live claim with no
    # agent-claimed label is precisely the defect Law 10 exists to prevent,
    # and reporting success over label state we could not read is how it
    # stayed invisible.
    if [[ -z "${REPO:-}" ]]; then
      warn "could not resolve the product repo — cannot verify agent-claimed is still present on #$ISSUE while residual claims remain (pass --repo owner/name)"
      INCOMPLETE=1
      printf '%s\n' "$RESIDUAL_IDS" | sed 's/^/  /' >&2
    else
      LABELS=$(gh issue view "$ISSUE" --repo "$REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$LABELS" == "?" ]]; then
        warn "could not read labels on $REPO#$ISSUE — residual-claim label preservation UNVERIFIED"
        INCOMPLETE=1
      elif ! echo ",$LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is ABSENT on $REPO#$ISSUE — residual claims remain but the label is missing; re-add it by hand"
        INCOMPLETE=1
      else
        info "keeping agent-claimed on #$ISSUE — residual claims remain (verified):"
        printf '%s\n' "$RESIDUAL_IDS" | sed 's/^/  /'
      fi
    fi
  elif [[ "$KEEP_LABEL" -eq 1 ]]; then
    # Empty ledger + live sibling whose claim is not on this ref (or was never
    # filed). Explicit operator path — do not invent a row, do not strip the
    # label. Preservation is a postcondition that must be verified against
    # GitHub; a blind "kept" log while the label is absent is a false green.
    if [[ -z "${REPO:-}" ]]; then
      warn "could not resolve the product repo — --keep-label cannot verify agent-claimed on #$ISSUE (pass --repo owner/name)"
      INCOMPLETE=1
    else
      LABELS=$(gh issue view "$ISSUE" --repo "$REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
      if [[ "$LABELS" == "?" ]]; then
        warn "could not read labels on $REPO#$ISSUE — --keep-label preservation UNVERIFIED"
        INCOMPLETE=1
      elif ! echo ",$LABELS," | grep -q ',agent-claimed,'; then
        warn "agent-claimed is ABSENT on $REPO#$ISSUE — --keep-label required the label to stay, but it is not present. Re-add it or re-claim before declaring Law 10 done."
        INCOMPLETE=1
      else
        info "keeping agent-claimed on $REPO#$ISSUE — --keep-label verified (live sibling outside ledger; no claim row invented)"
      fi
    fi
  elif [[ -z "${REPO:-}" ]]; then
    warn "could not resolve the product repo — agent-claimed NOT removed from #$ISSUE (pass --repo owner/name)"
    INCOMPLETE=1
  else
    if ! gh issue edit "$ISSUE" --repo "$REPO" --remove-label agent-claimed; then
      warn "gh issue edit failed for #$ISSUE in $REPO"
    fi
    # Verify rather than assume.
    LABELS=$(gh issue view "$ISSUE" --repo "$REPO" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
    if [[ "$LABELS" == "?" ]]; then
      warn "could not re-read labels on #$ISSUE — agent-claimed removal UNVERIFIED"
      INCOMPLETE=1
    elif echo ",$LABELS," | grep -q ',agent-claimed,'; then
      warn "agent-claimed is STILL on $REPO#$ISSUE — remove it by hand before declaring Law 10 done"
      INCOMPLETE=1
    else
      info "removed agent-claimed from $REPO#$ISSUE (verified)"
    fi
  fi
else
  if [[ "$PRESERVE_LABEL" -eq 1 ]]; then
    info "gh not found — agent-claimed left in place (incomplete cleanup; not removing label)"
  elif [[ -n "$RESIDUAL_IDS" ]]; then
    # Left in place, but unverifiable without gh — say so rather than
    # reporting a postcondition nobody checked (#153 review P1).
    warn "gh not found — agent-claimed left in place for residual claims on #$ISSUE, but its presence could NOT be verified"
    INCOMPLETE=1
  elif [[ "$KEEP_LABEL" -eq 1 ]]; then
    warn "gh not found — --keep-label cannot verify agent-claimed on #$ISSUE"
    INCOMPLETE=1
  else
    warn "gh not found — agent-claimed NOT removed from #$ISSUE"
    INCOMPLETE=1
  fi
fi

if [[ "$INCOMPLETE" -eq 1 ]]; then
  echo "release-claim.sh: INCOMPLETE — cleanup did not finish for issue $ISSUE (see warnings above)" >&2
  exit 3
fi

if [[ -z "$TARGET_IDS" ]]; then
  info "OK — no claim row to release for issue $ISSUE; label policy applied"
else
  # TERMINAL_MODE releases exit from terminal_cleanup_release() above and
  # never reach here — this is always the ledger-row release path.
  info "OK — claim released for issue $ISSUE"
fi
