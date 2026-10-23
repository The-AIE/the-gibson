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

  --vendor from-reservation reads NAME from the lane's own reservation commit:
  the commit after the merge-base with origin/main (origin/master as the
  fallback) whose message carries `Gibson-Reservation: v1` AND whose
  `Gibson-Branch:` names the checked-out branch, taking its `Agent-Vendor:`
  value. A reservation for another branch in the same range (a lane stacked on
  a lane) is never used: a child does not inherit its parent's vendor. This is how a lane created by claim.sh BEFORE the
  worktree declaration existed gets declared without anyone retyping the
  vendor. It refuses (exit 1) when no reservation in that range names this
  branch, when more than one does, when HEAD is detached, when the reservation
  has no Agent-Vendor trailer, or when its trailers name more than one distinct
  vendor — nothing is guessed. `claims-status.sh`
  lists the registered lane worktrees that are still undeclared.

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
  scripts/setup-hooks.sh [--vendor NAME | --vendor from-reservation]
  scripts/setup-hooks.sh --help

EXAMPLES
  ./scripts/setup-hooks.sh
  ./scripts/setup-hooks.sh --vendor claude             # in a hand-made lane worktree
  ./scripts/setup-hooks.sh --vendor from-reservation   # in a claim.sh lane made before #523

EXIT
  0 done (or no-op outside a work tree)   2 usage / unknown vendor
  1 a git config write failed or could not be read back; or, with
    from-reservation, no reservation commit naming this branch (or more than
    one, or a detached HEAD), no Agent-Vendor trailer on it, or more than one
    distinct vendor named there
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
      if [[ -z "$VENDOR" ]]; then
        echo "setup-hooks.sh: --vendor= needs a value (one of: ${AGENT_VENDORS}); an empty vendor is not 'no vendor'" >&2
        exit 2
      fi
      shift
      ;;
    *)
      echo "setup-hooks.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

FROM_RESERVATION=0
if [[ -n "$VENDOR" ]]; then
  VENDOR="$(printf '%s' "$VENDOR" | tr '[:upper:]' '[:lower:]')"
  if [[ "$VENDOR" == "from-reservation" ]]; then
    # Resolved below, once we know we are inside a work tree with a base ref.
    FROM_RESERVATION=1
    VENDOR=""
  fi
fi
vendor_check() { # NAME — exit 2 unless NAME is a vendor the evaluator resolves
  local known=0 v
  for v in $AGENT_VENDORS; do
    [[ "$1" == "$v" ]] && known=1
  done
  if [[ "$known" -ne 1 ]]; then
    echo "setup-hooks.sh: unknown agent vendor '$1': use one of ${AGENT_VENDORS}" >&2
    exit 2
  fi
}
if [[ -n "$VENDOR" ]]; then
  vendor_check "$VENDOR"
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

# --vendor from-reservation: the lane's own reservation commit names the vendor.
# claim.sh writes `Agent-Vendor: <vendor>` in its own paragraph above the
# `Gibson-Reservation: v1` block, so the first commit after the merge-base with
# the base branch that carries that marker is the reservation; its trailer is
# the declaration. Refuse, never guess, when the range has no reservation, the
# reservation has no trailer, or its trailers disagree.
if [[ "$FROM_RESERVATION" -eq 1 ]]; then
  base_ref=""
  for cand in origin/main origin/master; do
    if git rev-parse --verify --quiet "${cand}^{commit}" >/dev/null 2>&1; then
      base_ref="$cand"
      break
    fi
  done
  if [[ -z "$base_ref" ]]; then
    echo "setup-hooks.sh: --vendor from-reservation: neither origin/main nor origin/master resolves here — fetch origin, or pass --vendor <name>" >&2
    exit 1
  fi
  head_sha=$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)
  if [[ -z "$head_sha" ]]; then
    echo "setup-hooks.sh: --vendor from-reservation: HEAD is unborn — nothing to read a reservation from; pass --vendor <name>" >&2
    exit 1
  fi
  merge_base=$(git merge-base "$head_sha" "$base_ref" 2>/dev/null || true)
  if [[ -z "$merge_base" ]]; then
    echo "setup-hooks.sh: --vendor from-reservation: no merge base between HEAD and ${base_ref} — pass --vendor <name>" >&2
    exit 1
  fi
  # The reservation is the one whose Gibson-Branch names THIS branch. A lane
  # stacked on another lane sees the parent's reservation in the same range,
  # and taking the first one would inherit the parent's vendor silently
  # (Codex review of #525); a branch with two reservations of its own is
  # ambiguous. Both refuse.
  cur_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [[ -z "$cur_branch" ]]; then
    echo "setup-hooks.sh: --vendor from-reservation: HEAD is detached, so no Gibson-Branch can match it — check out the lane branch, or pass --vendor <name>" >&2
    exit 1
  fi
  reservation=""
  reservation_count=0
  other_reservations=""
  range_shas=$(git rev-list --reverse "${merge_base}..${head_sha}" 2>/dev/null || true)
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    body=$(git log -1 --format=%B "$sha" 2>/dev/null || true)
    grep -E '^Gibson-Reservation: v1[[:blank:]]*$' <<<"$body" >/dev/null || continue
    res_branch=$(grep -E '^Gibson-Branch:[[:blank:]]*' <<<"$body" | head -1 | sed 's/^Gibson-Branch:[[:blank:]]*//; s/[[:blank:]]*$//')
    if [[ "$res_branch" == "$cur_branch" ]]; then
      reservation="$sha"
      reservation_count=$((reservation_count + 1))
    else
      other_reservations="${other_reservations:+$other_reservations, }${sha:0:7} (Gibson-Branch: ${res_branch:-<none>})"
    fi
  done <<EOF3
$range_shas
EOF3
  if [[ "$reservation_count" -gt 1 ]]; then
    echo "setup-hooks.sh: --vendor from-reservation: ${reservation_count} reservation commits in ${merge_base}..${head_sha} name Gibson-Branch: ${cur_branch} — ambiguous, refusing to guess; pass --vendor <name> explicitly" >&2
    exit 1
  fi
  if [[ -z "$reservation" ]]; then
    if [[ -n "$other_reservations" ]]; then
      echo "setup-hooks.sh: --vendor from-reservation: no reservation commit in ${merge_base}..${head_sha} names Gibson-Branch: ${cur_branch}; the range only has ${other_reservations}, which belong to another lane (a stacked lane does not inherit its parent's vendor) — pass --vendor <name> explicitly" >&2
    else
      echo "setup-hooks.sh: --vendor from-reservation: no commit in ${merge_base}..${head_sha} carries 'Gibson-Reservation: v1' — this lane has no claim.sh reservation to read; pass --vendor <name> explicitly" >&2
    fi
    exit 1
  fi
  reservation_vendors=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    v="${line#*:}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    case " $reservation_vendors " in
      *" $v "*) ;;
      *) reservation_vendors="${reservation_vendors:+$reservation_vendors }$v" ;;
    esac
  done <<EOF3
$(git log -1 --format=%B "$reservation" | grep -iE '^Agent-Vendor:[[:blank:]]*[A-Za-z0-9_-]+[[:blank:]]*$' || true)
EOF3
  if [[ -z "$reservation_vendors" ]]; then
    echo "setup-hooks.sh: --vendor from-reservation: reservation commit ${reservation} has no Agent-Vendor trailer (pre-#467 claim) — pass --vendor <name> explicitly" >&2
    exit 1
  fi
  case "$reservation_vendors" in
    *" "*)
      echo "setup-hooks.sh: --vendor from-reservation: reservation commit ${reservation} names more than one vendor (${reservation_vendors}) — refusing to guess; pass --vendor <name> explicitly" >&2
      exit 1
      ;;
  esac
  VENDOR="$reservation_vendors"
  vendor_check "$VENDOR"
  echo "setup-hooks: vendor '${VENDOR}' read from reservation commit ${reservation} (Gibson-Branch: ${cur_branch}; ${base_ref} merge-base ${merge_base})"
fi

# Ensure hooks stay executable after checkout on filesystems that drop +x.
chmod +x "${hooks_dir}"/* 2>/dev/null || true

git config core.hooksPath .githooks
echo "setup-hooks: core.hooksPath set to .githooks"

if [[ -n "$VENDOR" ]]; then
  ext=$(git config --bool --local --get extensions.worktreeConfig 2>/dev/null || true)
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
