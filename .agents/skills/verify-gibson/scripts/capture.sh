#!/usr/bin/env bash
# capture.sh — run a command and record command, stdout, stderr and exit code as evidence
set -uo pipefail

usage() {
  cat <<'HELPTEXT'
capture.sh — record a verification command and its result

WHAT IT DOES
  Runs the command after "--" and writes <label>.cmd, .out, .err and .rc under
  <git-common-dir>/gibson-verify-evidence/<run-id>/<feature>/ . The shared git
  directory survives `git worktree remove`, is never committed, and is not scanned.
  Prints the exit code and the evidence path, and exits with the command's exit code.
  Refuses (exit 2) rather than overwrite evidence that already exists for the same
  run-id, feature and label.

WHY
  A claim that a change works needs the command, its output and its exit code.

RISKS
  Runs whatever command you give it with your credentials. Evidence files may
  contain whatever the command prints; do not capture commands that print secrets.

USAGE
  capture.sh <feature-id> <label> -- <command> [args...]
  capture.sh --help

EXAMPLES
  capture.sh prepush all-clear -- scripts/prepush.sh
HELPTEXT
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[[ $# -ge 4 && "$3" == "--" ]] || { echo "unknown flag: expected <feature-id> <label> -- <command...>" >&2; exit 2; }

feature="$1"; label="$2"; shift 3
[[ "$feature" =~ ^[a-z0-9-]+$ && "$label" =~ ^[a-z0-9-]+$ ]] || { echo "unknown flag: feature and label must match [a-z0-9-]+" >&2; exit 2; }

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "capture.sh: not inside a git repo" >&2; exit 2; }
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "capture.sh: cannot resolve the shared git directory" >&2; exit 2; }
run_id="${VERIFY_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$run_id" != *..* ]] || { echo "unknown flag: VERIFY_RUN_ID must match [A-Za-z0-9._-]+ with no dot-dot" >&2; exit 2; }
dir="$common/gibson-verify-evidence/$run_id/$feature"
mkdir -p "$dir" || exit 2
# Evidence is never overwritten. mkdir is atomic, so the lock directory is the claim:
# of two concurrent captures with the same run-id/feature/label exactly one wins and
# the other exits 2 before it writes anything. The marker is never removed.
if [[ -e "$dir/$label.cmd" || -e "$dir/$label.out" || -e "$dir/$label.err" || -e "$dir/$label.rc" \
      || -L "$dir/$label.cmd" || -L "$dir/$label.out" || -L "$dir/$label.err" || -L "$dir/$label.rc" ]] \
   || ! mkdir "$dir/$label.lock" 2>/dev/null; then
  echo "capture.sh: evidence already exists for $feature/$label in run $run_id; use a new label or VERIFY_RUN_ID" >&2
  exit 2
fi

# Record the command shell-quoted, so the invocation can be replayed exactly.
write_fail() { echo "capture.sh: could not write evidence ($1) under $dir; the run is NOT recorded" >&2; exit 2; }
printf '%q ' "$@" > "$dir/$label.cmd" || write_fail cmd
printf '\n' >> "$dir/$label.cmd" || write_fail cmd
( cd "$root" && "$@" ) > "$dir/$label.out" 2> "$dir/$label.err"
rc=$?
printf '%s\n' "$rc" > "$dir/$label.rc" || write_fail rc
echo "capture: $feature/$label exit=$rc evidence=$dir"
exit "$rc"
