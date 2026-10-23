#!/usr/bin/env bash
# install.sh — link the tracked lane pre-push layer (this directory) into ~/.claude/fleet, the path
# lane-sync.sh, the lane hooks and every fleet tool already use.
#
# Why symlinks (2026-10-23): for eight days the copy under ~/.claude/fleet was the ONLY copy, so a
# fix made there (L-098, the empty-locale defect) could be recorded but not reviewed or versioned.
# With the checkout as the source of truth a merged change is live on the next pull, and --check
# says when the two have drifted. Nothing here edits a live file: a live file that differs from the
# tracked one is REFUSED, never overwritten; move it aside yourself after reading the diff.
#
# A symlink into a checkout tracks WHATEVER BRANCH IS CHECKED OUT there. Install from a checkout
# on main and re-run --check after switching branches. A dangling hook link is fail-closed at lane
# setup (install-lane-hooks.sh tests -x on hooks/pre-push and lane-sync.sh refuses the lane), but
# git itself silently runs no hook that is missing at push time, so never leave hooks/pre-push
# dangling under a lane that is mid-flight.
#
# Usage: fleet/install.sh [--check] [--target DIR]
#   (no flag)  create or replace the links (missing, dangling, or an identical plain file); exit 1
#              and change nothing for a path that differs (drift) or links somewhere else
#   --check    report each path as ok | missing | dangling | not-a-link | drift | wrong-target;
#              change nothing; exit 1 unless every path is ok
#   --target   install under DIR instead of $HOME/.claude/fleet (the tests use a temp dir)
# Exit: 0 every path ok, 1 at least one path refused or not ok, 64 usage
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="pre-push-gate.sh hooks/pre-push install-lane-hooks.sh prepush-review.sh gibson-isolated-gate.sh test/prepush.test.sh"
MODE="link"; TARGET="$HOME/.claude/fleet"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --target) TARGET="${2:?install.sh: --target needs a directory}"; shift 2 ;;
    -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument: $1 (usage: install.sh [--check] [--target DIR])" >&2; exit 64 ;;
  esac
done
case "$TARGET" in /*) ;; *) TARGET="$PWD/$TARGET" ;; esac

state() { # state <relative path> -> ok | missing | dangling | wrong-target | not-a-link | drift
  local src="$HERE/$1" dst="$TARGET/$1"
  if [ -L "$dst" ]; then
    [ -e "$dst" ] || { echo dangling; return; }
    [ "$(readlink "$dst")" = "$src" ] && echo ok || echo wrong-target
  elif [ -e "$dst" ]; then
    cmp -s "$src" "$dst" && echo not-a-link || echo drift
  else
    echo missing
  fi
}

branch="$(git -C "$HERE" branch --show-current 2>/dev/null || true)"
[ "$MODE" = check ] || [ "$branch" = main ] || [ -z "$branch" ] || echo "install.sh: note — linking a checkout on branch '$branch', not main; the links will track that branch"
bad=0
for f in $FILES; do
  src="$HERE/$f"; dst="$TARGET/$f"
  [ -f "$src" ] || { echo "install.sh: FAILED — tracked file missing: $src" >&2; bad=1; continue; }
  st="$(state "$f")"
  if [ "$MODE" = check ]; then
    printf '%-12s %s\n' "$st" "$dst"; [ "$st" = ok ] || bad=1; continue
  fi
  case "$st" in
    ok) echo "ok           $dst" ;;
    missing|dangling|not-a-link)
      mkdir -p "$(dirname "$dst")" && ln -sfn "$src" "$dst" && [ "$(state "$f")" = ok ] \
        && echo "linked       $dst -> $src" \
        || { echo "install.sh: FAILED — could not link $dst -> $src" >&2; bad=1; } ;;
    drift)
      echo "install.sh: REFUSED drift — $dst is a plain file that differs from $src; read \`diff $dst $src\`, move it aside, re-run. Nothing changed." >&2; bad=1 ;;
    wrong-target)
      echo "install.sh: REFUSED wrong-target — $dst links to $(readlink "$dst"), not $src; remove that link yourself if it is stale. Nothing changed." >&2; bad=1 ;;
  esac
done
exit $bad
