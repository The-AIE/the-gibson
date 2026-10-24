#!/usr/bin/env bash
# install-lane-hooks.sh — point ONE worktree at the fleet hooks dir, without touching the
# main checkout or sibling lanes. Uses git's per-worktree config (extensions.worktreeConfig),
# so Mark's own checkout keeps whatever hooks it has. Idempotent. Called by lane-sync.sh.
# NEVER run this on the main checkout: with worktreeConfig enabled, `git worktree add` COPIES the
# main worktree's per-worktree config into every worktree created afterwards (verified git 2.50.1,
# 2026-10-15), and the main checkout itself would start refusing pushes to main. Lanes only.
# Usage: install-lane-hooks.sh <worktree>
# Env: FLEET_HOOKS_DIR  hooks dir to point the worktree at (default: the hooks/ beside this script)
set -uo pipefail
# The hooks dir defaults to the one beside THIS script (~/.claude/fleet/hooks via the symlinks, or a
# the-gibson checkout's fleet/hooks), resolved before any cd so a relative $0 still works.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="${1:?usage: install-lane-hooks.sh <worktree>}"
cd "$WT" 2>/dev/null || { echo "install-lane-hooks: no worktree at $WT" >&2; exit 64; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "install-lane-hooks: not a git worktree" >&2; exit 64; }
if [ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ]; then
  echo "install-lane-hooks: REFUSED — $WT is the main checkout, not a linked worktree (lanes only)" >&2; exit 65
fi
HOOKS="${FLEET_HOOKS_DIR:-$HERE/hooks}"
[ -x "$HOOKS/pre-push" ] || { echo "install-lane-hooks: FAILED — $HOOKS/pre-push missing or not executable" >&2; exit 66; }
git config extensions.worktreeConfig true || { echo "install-lane-hooks: FAILED — cannot enable extensions.worktreeConfig" >&2; exit 66; }
git config --worktree core.hooksPath "$HOOKS" || { echo "install-lane-hooks: FAILED — cannot write worktree core.hooksPath" >&2; exit 66; }
# Read it back the way git will resolve it; a write that does not read back is a failure.
[ "$(git config --get core.hooksPath 2>/dev/null)" = "$HOOKS" ] \
  || { echo "install-lane-hooks: FAILED — core.hooksPath does not read back as $HOOKS" >&2; exit 66; }
echo "install-lane-hooks: $(basename "$WT") hooksPath=$HOOKS (worktree-scoped)"
