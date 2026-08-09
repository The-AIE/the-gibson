#!/usr/bin/env bash
# shellcheck disable=SC2034
# ^ Every GUARD_* variable below IS the return value: this file is sourced, and
#   its callers (claim.sh's rollback, release-claim.sh's terminal cleanup) read
#   them in their own scope. ShellCheck cannot see across the source boundary,
#   so each one looks written-but-never-read from inside this file alone.
#
# claim-guards.sh — shared fail-closed cleanup guards (#153 review P1 0D)
#
# Source this from any script that is about to delete a worktree or a branch on
# the strength of claim evidence. It answers the three questions that decide
# whether a destructive step is allowed to happen at all:
#
#   1. WHICH registered worktree is actually checked out on this branch?
#      (enumerated from `git worktree list --porcelain`, never derived from a
#      claim id or a path convention — a guessed path is how an unrelated
#      directory once drove an rm -rf)
#   2. WHERE does a path really live? (physical, symlink-resolved)
#   3. DOES the remote branch exist, and at exactly which OID?
#      (`git ls-remote` telling us "the query failed" must never be read as
#      "the branch is gone")
#
# WHY IT IS A LIBRARY
#   release-claim.sh's terminal cleanup grew these protections after a claim
#   release force-removed a dirty worktree and unconditionally deleted its
#   branches. claim.sh's admission rollback then re-created the same hazard in
#   miniature: during the post-create admission delay a lane's own worktree can
#   go dirty and its own branch can advance, and the rollback deleted both with
#   --force and `|| true`. The protections have to be the same code, or they
#   drift the moment one side is fixed.
#
# CONTRACT
#   Every function is read-only. Nothing here deletes, moves, or writes
#   anything — callers own the mutation and the policy; these only supply
#   trustworthy evidence, or refuse to supply any. "Unreadable" is always
#   distinguished from "absent": a failed query returns 1 with a reason, never
#   an empty result that a caller could mistake for proof of absence.
#
#   Functions run git in the CURRENT working directory, so a caller must cd
#   into the repository it means to inspect (both callers already do).
#
# USAGE
#   source "$SCRIPT_DIR/lib/claim-guards.sh"
#
#   guard_phys_path PATH
#     Echo PATH's physical (symlink-resolved) location; return 1 if it cannot
#     be resolved. Used to compare two paths for identity rather than spelling.
#
#   guard_worktree_paths_for_branch BRANCH
#     On success (0): GUARD_WT_PATHS holds one registered worktree path per
#     line (possibly none) and GUARD_WT_COUNT holds how many.
#     On failure (1): GUARD_WT_REASON says why the enumeration itself could
#     not be trusted. Zero matches is a SUCCESS with count 0 — the caller
#     decides what "no worktree on that branch" means for it.
#
#   guard_remote_branch_exact BRANCH
#     On success (0): GUARD_REMOTE_STATUS is "present" or "absent", and
#     GUARD_REMOTE_OID carries the exact 40-hex OID when present.
#     On failure (1): GUARD_REMOTE_REASON says why the answer is unreadable
#     evidence (query failure, or multiple/malformed rows). `git ls-remote
#     --exit-code` alone conflates "query failed" with "branch absent"; that
#     conflation is the bug this function exists to prevent.
#
# RISKS
#   - None on its own: it mutates nothing and contacts the network only for
#     `git ls-remote` against origin (a read).
#   - A caller that ignores a return of 1 and uses the (empty) variables anyway
#     converts fail-closed evidence into a silent green light. Check the return
#     value.

# Physical, symlink-resolved path. Empty output + nonzero return when the path
# cannot be resolved (missing, not a directory, unreadable).
guard_phys_path() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  (CDPATH='' cd -P -- "$p" 2>/dev/null && pwd -P) || return 1
}

# Registered worktrees checked out on refs/heads/<branch>, enumerated from
# git's own porcelain listing. Never guesses a path from a naming convention.
guard_worktree_paths_for_branch() {
  local br="${1:-}" porcelain line cur="" cur_branch=""
  GUARD_WT_PATHS=""
  GUARD_WT_COUNT=0
  GUARD_WT_REASON=""
  if [[ -z "$br" ]]; then
    GUARD_WT_REASON="guard_worktree_paths_for_branch requires a branch name"
    return 1
  fi
  if ! porcelain=$(git worktree list --porcelain 2>&1); then
    GUARD_WT_REASON="cannot enumerate registered worktrees (git worktree list --porcelain failed): $porcelain"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        cur="${line#worktree }"
        cur="${cur%/}"
        cur_branch=""
        ;;
      branch\ *)
        cur_branch="${line#branch }"
        cur_branch="${cur_branch#refs/heads/}"
        ;;
      "")
        if [[ -n "$cur" && "$cur_branch" == "$br" ]]; then
          GUARD_WT_PATHS="${GUARD_WT_PATHS}${cur}"$'\n'
          GUARD_WT_COUNT=$((GUARD_WT_COUNT + 1))
        fi
        cur=""
        cur_branch=""
        ;;
    esac
  done <<EOF
$porcelain
EOF
  # Porcelain records are blank-line separated; the last one has no trailing
  # blank line, so it is flushed here or it is silently dropped.
  if [[ -n "$cur" && "$cur_branch" == "$br" ]]; then
    GUARD_WT_PATHS="${GUARD_WT_PATHS}${cur}"$'\n'
    GUARD_WT_COUNT=$((GUARD_WT_COUNT + 1))
  fi
  return 0
}

# Exact remote branch identity. Distinguishes query failure (unreadable) from
# a legitimately absent branch from a present branch at an exact OID.
guard_remote_branch_exact() {
  local br="${1:-}" out line count oid ref
  GUARD_REMOTE_STATUS=""
  GUARD_REMOTE_OID=""
  GUARD_REMOTE_REASON=""
  if [[ -z "$br" ]]; then
    GUARD_REMOTE_REASON="guard_remote_branch_exact requires a branch name"
    return 1
  fi
  if ! out=$(git ls-remote --heads origin "refs/heads/$br" 2>&1); then
    GUARD_REMOTE_REASON="git ls-remote --heads origin failed for '$br': $out"
    return 1
  fi
  if [[ -z "$out" ]]; then
    GUARD_REMOTE_STATUS="absent"
    return 0
  fi
  count=$(printf '%s\n' "$out" | grep -c . || true)
  if [[ "$count" -ne 1 ]]; then
    GUARD_REMOTE_REASON="git ls-remote --heads origin returned multiple/malformed rows for '$br': $out"
    return 1
  fi
  line=$(printf '%s\n' "$out")
  oid=$(awk '{print $1}' <<<"$line")
  ref=$(awk '{print $2}' <<<"$line")
  if [[ ! "$oid" =~ ^[0-9a-f]{40}$ || "$ref" != "refs/heads/$br" ]]; then
    GUARD_REMOTE_REASON="git ls-remote --heads origin returned a malformed row for '$br': $line"
    return 1
  fi
  GUARD_REMOTE_STATUS="present"
  GUARD_REMOTE_OID="$oid"
  return 0
}

claim_guards_usage() {
  cat <<'EOF'
claim-guards.sh — shared fail-closed cleanup guards for claim/release paths

WHAT I'M ASKING
  Nothing directly. This file is a sourceable library, not a command. Scripts
  that are about to delete a worktree or a branch source it.

WHAT IT DOES
  Answers three questions before anything destructive happens: which worktree
  is really on this branch (asked of git, never guessed from a name), where a
  path really lives once symlinks are resolved, and whether the remote branch
  exists and at exactly which commit.

WHY IT SHOULD BE DONE
  The claim path and the release path both delete worktrees and branches. When
  each carried its own copy of these checks, a protection added to one silently
  did not exist in the other — that is how an admission rollback came to
  force-remove a worktree that had gone dirty and delete a branch that had
  moved on.

THE RISKS
  Low: it reads, it never writes. The one real hazard is a caller that ignores
  a nonzero return and uses the empty result anyway, which turns "I could not
  read this" into "there is nothing there". Every caller must check.

USAGE
  source "$SCRIPT_DIR/lib/claim-guards.sh"
  guard_phys_path PATH
  guard_worktree_paths_for_branch BRANCH   # GUARD_WT_PATHS/_COUNT/_REASON
  guard_remote_branch_exact BRANCH         # GUARD_REMOTE_STATUS/_OID/_REASON

EXIT (direct run only)
  0  --help
  2  anything else — this is a library; there is nothing to execute
EOF
}

# Sourced or executed? Decided by whether `return` is legal, not by comparing
# ${BASH_SOURCE[0]} to "$0" — a caller can make $0 be this very file while
# genuinely sourcing it (`bash -c 'source "$0"' path`), and that comparison
# would abort in the middle of a legitimate source. Same idiom, same reason, as
# silent-noop.sh. Sourcing stays silent; a direct run fails loudly.
if ! (return 0 2>/dev/null); then
  case "${1:-}" in
    -h|--help)
      claim_guards_usage
      exit 0
      ;;
    *)
      echo "claim-guards: ERROR: nothing to run — this file is a sourceable library, not a command." >&2
      echo "claim-guards: source it from a claim/release script, or run 'lib/claim-guards.sh --help'." >&2
      claim_guards_usage >&2
      exit 2
      ;;
  esac
fi
