#!/usr/bin/env bash
set -euo pipefail

# This wrapper is installed only for the duration of a runner invocation.
# It blocks pushes and commits that cross the loop's repository boundary or
# modify harness-owned gate configuration.

REAL_GIT="${GIBSON_REAL_GIT:?}"
TARGET_REPO="${GIBSON_TARGET_REPO:?}"
EXPECTED_SLUG="${GIBSON_EXPECTED_REPO_SLUG:?}"

# Physical path of an existing directory (macOS /var vs /private/var, symlinks).
# Stock Bash 3.2 / macOS: no GNU realpath or readlink -f.
physical_dir() {
  local path="$1"
  [[ -n "$path" && -d "$path" ]] || return 1
  (CDPATH='' cd -- "$path" && pwd -P) 2>/dev/null || return 1
}

repo_root() {
  "$REAL_GIT" -C "$1" rev-parse --show-toplevel 2>/dev/null
}

# Resolve configured target to a physical git repository root. Fail closed if
# the path is missing/unreadable, not a git repo, or not the repo root itself.
resolve_target_root() {
  local phys git_root root
  phys=$(physical_dir "$TARGET_REPO") || return 1
  git_root=$(repo_root "$phys") || return 1
  [[ -n "$git_root" ]] || return 1
  root=$(physical_dir "$git_root") || return 1
  # Configured path must *be* the repository root (after physicalization), not
  # a nested directory inside some other checkout.
  [[ "$phys" == "$root" ]] || return 1
  printf '%s\n' "$root"
}

# Resolve the observed cwd to a physical git repository root.
resolve_current_root() {
  local git_root
  git_root=$(repo_root "$PWD") || return 1
  [[ -n "$git_root" ]] || return 1
  physical_dir "$git_root"
}

fail() {
  echo "gibson repo-boundary guard: $*" >&2
  exit 86
}

target_root="$(resolve_target_root || true)"
[[ -n "$target_root" ]] ||
  fail "configured target repo could not be resolved: '$TARGET_REPO'"

current_root="$(resolve_current_root || true)"
[[ -n "$current_root" && "$current_root" == "$target_root" ]] ||
  fail "git command ran outside target repo: expected '$TARGET_REPO' (resolved '${target_root:-unresolved}'), observed '${current_root:-unresolved}'"

protected_path() {
  case "$1" in
    .agents/gate.json|.gibson-gate.json|.agents/gate.*|.agents/*sensor*.json|.agents/*sensor*.yaml|.agents/*sensor*.yml)
      return 0
      ;;
  esac
  return 1
}

# Scan the index for staged harness control-plane paths.
# - Prints one diagnostic per offender on stderr.
# - Fills global array _protected_staged with every offender (NUL-safe via git -z).
# - Returns 0 if none, 1 if any. Does not exit (callers may selective-reset).
# - No --diff-filter: must match production guard_control_plane_clean (includes D, T).
# Bash 3.2: no namerefs; callers read _protected_staged after a failed return.
_protected_staged=()
scan_staged_control_plane() {
  _protected_staged=()
  local path
  # -z / read -d '': paths with spaces/newlines cannot split the list.
  while IFS= read -r -d '' path; do
    [[ -n "$path" ]] || continue
    if protected_path "$path"; then
      echo "gibson repo-boundary guard: runner cannot stage harness control-plane file '$path'" >&2
      _protected_staged+=("$path")
    fi
  done < <("$REAL_GIT" diff --cached --name-only -z)
  [[ ${#_protected_staged[@]} -eq 0 ]]
}

# Return non-zero if any control-plane path is staged (diagnostics already printed).
check_staged_control_plane() {
  scan_staged_control_plane
}

# True (0) when `git commit` argv can include working-tree content that is not
# already in the index: -a/--all (incl. combined short opts like -am),
# -i/--include, -o/--only, -p/--patch, --interactive, --pathspec-from-file
# (equals or separate-value), bare pathspecs, or pathspecs after `--`.
# Combined short forms fail closed if any of a/i/o/p appear (e.g. -ip, -po).
# --pathspec-file-nul only affects pathspec-file encoding; classifying
# --pathspec-from-file itself is enough so a pathspec-file commit cannot evade.
# Conservative: not a full git option parser; prefers fail-closed on ambiguity.
# $1 is the subcommand ("commit"); remaining args are commit options/operands.
commit_form_includes_worktree() {
  local arg skip_next=0 saw_dd=0 chars
  shift # drop "commit"
  for arg in "$@"; do
    if [[ "$skip_next" -eq 1 ]]; then
      skip_next=0
      continue
    fi
    if [[ "$saw_dd" -eq 1 ]]; then
      return 0
    fi
    case "$arg" in
      --) saw_dd=1 ;;
      -a|--all|--include|-i|--only|-o|-p|--patch|--interactive|--pathspec-from-file|--pathspec-from-file=*)
        return 0
        ;;
      -m|--message|-F|--file|-t|--template|--author|--date|--cleanup|--fix-trailer|-c|--reedit-message|-C|--reuse-message)
        skip_next=1
        ;;
      --message=*|--file=*|--template=*|--author=*|--date=*|--cleanup=*|--fix-trailer=*|--reedit-message=*|--reuse-message=*)
        ;;
      --*)
        ;;
      -*)
        # Combined short options (e.g. -am, -ip, -po). Long options already handled.
        # Fail closed if any worktree-including short flag letter is present.
        chars="${arg#-}"
        if [[ "$chars" == *[aiop]* ]]; then
          return 0
        fi
        # Attached-value short forms (-mMSG, -Ffile): not pathspecs.
        ;;
      *)
        # Bare non-option operand: pathspec form (e.g. git commit -m msg PATH).
        return 0
        ;;
    esac
  done
  return 1
}

# Print diagnostics and return 1 if any protected tracked path has unstaged
# working-tree changes (the set -a / pathspec commits can pull into a commit).
check_unstaged_protected_tracked() {
  local path found=0
  while IFS= read -r -d '' path; do
    [[ -n "$path" ]] || continue
    if protected_path "$path"; then
      echo "gibson repo-boundary guard: runner cannot commit harness control-plane file '$path' via -a/pathspec" >&2
      found=1
    fi
  done < <("$REAL_GIT" diff --name-only -z)
  [[ "$found" -eq 0 ]]
}

branch_from_push_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      refs/heads/*) printf '%s\n' "${arg#refs/heads/}"; return 0 ;;
      HEAD:*) printf '%s\n' "${arg#HEAD:}"; return 0 ;;
      *:refs/heads/*) printf '%s\n' "${arg#*:refs/heads/}"; return 0 ;;
    esac
  done
  "$REAL_GIT" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

check_push() {
  local remote="origin" arg remote_url remote_slug branch remote_tip local_tip
  local saw_remote=0
  for arg in "$@"; do
    case "$arg" in
      --|--all|--mirror|--delete|-d|-f|--force|--force-with-lease|-u|--set-upstream) continue ;;
      -*) continue ;;
      *)
        if [[ "$saw_remote" -eq 0 ]]; then
          remote="$arg"
          saw_remote=1
        fi
        ;;
    esac
  done
  remote_url=$("$REAL_GIT" config --get "remote.${remote}.url" 2>/dev/null || true)
  [[ -n "$remote_url" ]] || fail "push remote '$remote' has no configured URL"
  remote_slug=$(origin_slug_from_url "$remote_url")
  [[ "$remote_slug" == "$EXPECTED_SLUG" ]] ||
    fail "push remote '$remote' targets '${remote_slug:-unparseable}', expected '$EXPECTED_SLUG'"
  branch="$(branch_from_push_args "$@")"
  [[ -n "$branch" && "$branch" != -* && "$branch" != */*:* ]] ||
    fail "could not determine pushed branch for remote '$remote'"
  "$REAL_GIT" "$@" || return $?
  remote_tip=$("$REAL_GIT" ls-remote "$remote" "refs/heads/$branch" | awk 'NR == 1 { print $1 }')
  local_tip=$("$REAL_GIT" rev-parse "$branch" 2>/dev/null || "$REAL_GIT" rev-parse HEAD)
  [[ -n "$remote_tip" && "$remote_tip" == "$local_tip" ]] ||
    fail "pushed branch '$branch' does not point to local head on expected origin"
}

# Keep URL parsing local and strict; this intentionally accepts GitHub-style
# HTTPS/SSH URLs only, matching loop.sh's canonical repository identity.
origin_slug_from_url() {
  local url="$1" rest host owner name
  while [[ "$url" == */ ]]; do url="${url%/}"; done
  url="${url%.git}"
  case "$url" in
    git@*:*) rest="${url#git@}"; host="${rest%%:*}"; rest="${rest#*:}" ;;
    ssh://*|https://*|http://*|git://*)
      rest="${url#*://}"; rest="${rest#*@}"; host="${rest%%/*}"; rest="${rest#*/}"; host="${host%%:*}" ;;
    *) return 0 ;;
  esac
  case "$rest" in
    */*/*|*:*|*[[:space:]]*|/*) return 0 ;;
    */*) owner="${rest%%/*}"; name="${rest#*/}" ;;
    *) return 0 ;;
  esac
  [[ "$owner" =~ ^[A-Za-z0-9._-]+$ && "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  printf '%s/%s\n' "$owner" "$name"
}

case "${1-}" in
  add|commit)
    if [[ "$1" == "commit" ]]; then
      check_staged_control_plane || exit 86
      # -a/-am and pathspec commits can include unstaged tracked mods after the
      # index scan. Fail closed when those forms could pull in protected paths.
      if commit_form_includes_worktree "$@"; then
        check_unstaged_protected_tracked || exit 86
      fi
      "$REAL_GIT" "$@"
    else
      # Run the real add first, then reject protected paths. On rejection, roll
      # back *only* the offending pathspecs so legitimate prior staging survives.
      # Under set -e, a failed real add (e.g. unmatched pathspec) exits with the
      # real git status before the scan — no extra status plumbing required.
      "$REAL_GIT" "$@"
      if ! scan_staged_control_plane; then
        # Diagnostics already printed per offender. Selective reset — never the
        # whole index (Devin #146 review: full `git reset -q` unstaged unrelated work).
        # Paths from diff --cached are root-relative; reset must run at the repo
        # root so a protected add from a subdirectory still unstages offenders.
        "$REAL_GIT" -C "$current_root" reset -q -- "${_protected_staged[@]}"
        exit 86
      fi
    fi
    ;;
  push)
    check_staged_control_plane || exit 86
    check_push "${@:2}"
    ;;
  *)
    exec "$REAL_GIT" "$@"
    ;;
esac
