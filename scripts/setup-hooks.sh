#!/usr/bin/env bash
# setup-hooks.sh — point this clone's core.hooksPath at .githooks (issue #204).
# Safe to re-run; no-ops outside a git working tree (e.g. some install paths).
# Makes a missing Signed-off-by trailer impossible locally, not merely
# detectable in CI.
set -euo pipefail

usage() {
  cat <<'EOF'
setup-hooks.sh — install repo-managed git hooks so a missing Signed-off-by
is added (or refused) at commit time, not first noticed in CI

WHAT IT DOES
  Makes `.githooks/*` executable and sets `git config core.hooksPath .githooks`
  for this clone. Safe to re-run. No-ops (exit 0) outside a git work tree.

WHY
  CI is the last place to learn a commit is unsigned. prepare-commit-msg
  appends Signed-off-by from the committer identity when it is missing;
  commit-msg refuses the commit if it is still missing.

RISKS
  - Replaces any previous core.hooksPath for this clone
    (undo: `git config --unset core.hooksPath`).
  - Existing clones do not pick this up until this script is run once.

USAGE
  scripts/setup-hooks.sh
  scripts/setup-hooks.sh --help

EXAMPLES
  ./scripts/setup-hooks.sh
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *)
    echo "setup-hooks.sh: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "setup-hooks: not inside a git work tree; skipping" >&2
  exit 0
fi

root="$(git rev-parse --show-toplevel)"
hooks_dir="${root}/.githooks"

if [[ ! -d "$hooks_dir" ]]; then
  echo "setup-hooks: ${hooks_dir} missing; skipping" >&2
  exit 0
fi

# Ensure hooks stay executable after checkout on filesystems that drop +x.
chmod +x "${hooks_dir}"/* 2>/dev/null || true

git config core.hooksPath .githooks
echo "setup-hooks: core.hooksPath set to .githooks"
