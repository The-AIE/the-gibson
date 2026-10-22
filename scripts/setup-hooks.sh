#!/usr/bin/env bash
# setup-hooks.sh — point this clone's core.hooksPath at .githooks (issue #204),
# and optionally declare this worktree's agent vendor (--vendor) so the hooks
# stamp and check an Agent-Vendor trailer on every commit made here.
# Safe to re-run; no-ops outside a git working tree (e.g. some install paths).
# Makes a missing Signed-off-by (or, on a declared lane, a missing Agent-Vendor)
# impossible locally, not merely detectable in CI.
set -euo pipefail

usage() {
  cat <<'EOF2'
setup-hooks.sh — install repo-managed git hooks so a missing Signed-off-by
is added (or refused) at commit time, not first noticed in CI; with --vendor,
also declare which agent vendor commits in THIS worktree

WHAT IT DOES
  Makes `.githooks/*` executable and sets `git config core.hooksPath .githooks`
  for this clone. Safe to re-run. No-ops (exit 0) outside a git work tree.

  --vendor NAME additionally writes `gibson.agentVendor NAME` as WORKTREE-scoped
  config (`git config --worktree`; enables extensions.worktreeConfig once if it
  is off). From then on prepare-commit-msg appends `Agent-Vendor: NAME` to every
  commit made in this worktree and commit-msg refuses one without it, with a
  different vendor, or authored under an address GitHub cannot map to a login.
  claim.sh does the same for the lanes it creates; use --vendor for a lane made
  by hand (`git worktree add`). NAME is one of claude, codex, grok, devin — the
  vendors review-evidence resolves from the trailer.

WHY
  CI is the last place to learn a commit is unsigned. prepare-commit-msg
  appends Signed-off-by from the committer identity when it is missing;
  commit-msg refuses the commit if it is still missing. Likewise review time
  was the last place to learn a lane commit named no vendor: three lane PRs
  were closed on 2026-10-21 with identity-unresolved (the-gibson#503, #504,
  #506) because the reservation carried the trailer and the real work did not.

RISKS
  - Replaces any previous core.hooksPath for this clone
    (undo: `git config --unset core.hooksPath`).
  - Existing clones do not pick this up until this script is run once.
  - --vendor touches only this worktree's config (undo:
    `git config --worktree --unset gibson.agentVendor`). Enabling
    extensions.worktreeConfig is refused, not forced, when core.worktree is set
    or core.bare is true in the shared config (git documents those as needing a
    manual move first).

USAGE
  scripts/setup-hooks.sh [--vendor NAME]
  scripts/setup-hooks.sh --help

EXAMPLES
  ./scripts/setup-hooks.sh
  ./scripts/setup-hooks.sh --vendor claude     # in a hand-made lane worktree

EXIT
  0 done (or no-op outside a work tree)   2 usage / unknown vendor
  1 a git config write failed or could not be read back
EOF2
}

# Same list as .githooks/{prepare-commit-msg,commit-msg} and scripts/claim.sh
# (AUTHOR_COMMIT_VENDORS in scripts/pr-review-evidence.mjs); setup-hooks.test.sh
# fails when they drift.
AGENT_VENDORS="claude codex grok devin"

VENDOR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --vendor)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "setup-hooks.sh: --vendor needs a value (one of: ${AGENT_VENDORS})" >&2
        exit 2
      fi
      VENDOR="$2"
      shift 2
      ;;
    --vendor=*)
      VENDOR="${1#--vendor=}"
      shift
      ;;
    *)
      echo "setup-hooks.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$VENDOR" ]]; then
  VENDOR="$(printf '%s' "$VENDOR" | tr '[:upper:]' '[:lower:]')"
  known=0
  for v in $AGENT_VENDORS; do
    [[ "$VENDOR" == "$v" ]] && known=1
  done
  if [[ "$known" -ne 1 ]]; then
    echo "setup-hooks.sh: unknown agent vendor '${VENDOR}': use one of ${AGENT_VENDORS}" >&2
    exit 2
  fi
fi

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

if [[ -n "$VENDOR" ]]; then
  ext=$(git config --get extensions.worktreeConfig 2>/dev/null || true)
  if [[ "$ext" != "true" ]]; then
    if git config --get core.worktree >/dev/null 2>&1; then
      echo "setup-hooks: ERROR: extensions.worktreeConfig is off and core.worktree is set — move core.worktree to the main worktree's config.worktree first (git-config(1), extensions.worktreeConfig)" >&2
      exit 1
    fi
    if [[ "$(git config --get core.bare 2>/dev/null || true)" == "true" ]]; then
      echo "setup-hooks: ERROR: extensions.worktreeConfig is off and core.bare is true — refusing to enable the extension on a bare-marked repository" >&2
      exit 1
    fi
    git config extensions.worktreeConfig true || {
      echo "setup-hooks: ERROR: cannot enable extensions.worktreeConfig" >&2
      exit 1
    }
  fi
  git config --worktree gibson.agentVendor "$VENDOR" || {
    echo "setup-hooks: ERROR: cannot write gibson.agentVendor=$VENDOR for this worktree" >&2
    exit 1
  }
  got=$(git config --worktree --get gibson.agentVendor 2>/dev/null || true)
  if [[ "$got" != "$VENDOR" ]]; then
    echo "setup-hooks: ERROR: wrote gibson.agentVendor=$VENDOR but read back '${got:-<unset>}'" >&2
    exit 1
  fi
  echo "setup-hooks: this worktree commits as vendor '$VENDOR' (gibson.agentVendor, worktree-scoped)"
fi
