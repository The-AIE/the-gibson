#!/usr/bin/env bash
# enforce.sh — Gibson gate/claim/release invocable inside a Goose session (#35)
#
# Pure bash. Does NOT require the goose binary. Exit codes match the underlying
# scripts/claim.sh, scripts/gate.sh, scripts/release-claim.sh semantics.
set -euo pipefail

usage() {
  cat <<'HELP'
enforce.sh — fail-closed claim / gate / release helpers for Goose sessions

WHAT IT DOES
  Thin Gibson-branded wrappers around claim.sh, gate-baseline.sh, gate.sh, and
  release-claim.sh so a Goose (or any) session cannot skip Laws 2, 4, and 10.
  Same exit codes as the shell path. No Goose runtime dependency.

WHY
  Issue #35: Ten Laws are runtime-agnostic; enforcement must not dilute just
  because the agent loop is Goose's.

COMMANDS
  enforce.sh require-claim --repo PATH --issue N [--claim-id ID]
      Fail (exit 1) if the worktree is not covered by a live claim for the issue.
  enforce.sh require-worktree --repo PATH --canonical PATH
      Fail if PATH is the canonical checkout (Law 3).
  enforce.sh baseline [--] [gate-baseline args...]
      Record branch-point baseline (Law 4). Forwards to gate-baseline.sh.
  enforce.sh gate [--] [gate.sh args...]
      Run the green gate. Exit non-zero on new failures (Law 4).
  enforce.sh pre-commit --repo PATH --issue N [--claim-id ID] [--canonical PATH]
      require-claim + require-worktree (if --canonical) + gate. Fail-closed.
  enforce.sh release --issue N [release-claim args...]
      Post-merge cleanup (Law 10). Forwards to release-claim.sh.
  enforce.sh pre-edit --repo PATH --issue N [--claim-id ID] [--canonical PATH]
      require-claim + require-worktree. Call before any mutation.
  enforce.sh --help

ENV
  GIBSON_ROOT   Absolute path to the Gibson clone (default: two levels above this
                script). Must contain scripts/claim.sh etc.

EXIT
  0 success; 1 policy/gate failure; 2 usage error.
  Matches gate.sh / release-claim.sh when those scripts run underneath.
HELP
}

die() { echo "enforce.sh: ERROR: $*" >&2; exit 1; }
usage_err() { echo "enforce.sh: $*" >&2; usage >&2; exit 2; }

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
DEFAULT_GIBSON=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
GIBSON_ROOT="${GIBSON_ROOT:-$DEFAULT_GIBSON}"

CLAIM_SH="$GIBSON_ROOT/scripts/claim.sh"
GATE_SH="$GIBSON_ROOT/scripts/gate.sh"
BASELINE_SH="$GIBSON_ROOT/scripts/gate-baseline.sh"
RELEASE_SH="$GIBSON_ROOT/scripts/release-claim.sh"

need_scripts() {
  [[ -x "$CLAIM_SH" ]] || die "missing $CLAIM_SH (set GIBSON_ROOT)"
  [[ -x "$GATE_SH" ]] || die "missing $GATE_SH"
  [[ -x "$BASELINE_SH" ]] || die "missing $BASELINE_SH"
  [[ -x "$RELEASE_SH" ]] || die "missing $RELEASE_SH"
}

claim_ids_for_issue() {
  local repo="$1" issue="$2"
  local claims_dir="$repo/docs/claims"
  local f base
  if [[ -d "$claims_dir" ]]; then
    shopt -s nullglob
    for f in "$claims_dir"/issue-"$issue"-*.md "$claims_dir"/issue-"$issue".md; do
      [[ -f "$f" ]] || continue
      base=$(basename "$f" .md)
      printf '%s\n' "$base"
    done
    shopt -u nullglob
  fi
  if [[ -f "$repo/docs/active-work.md" ]]; then
    awk -F'|' -v n="$issue" '
      /^\|/ {
        cid=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",cid);
        if (cid ~ ("^issue-" n "(-|$)")) print cid
      }
    ' "$repo/docs/active-work.md" 2>/dev/null || true
  fi
}

cmd_require_claim() {
  local repo="" issue="" claim_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --claim-id) claim_id="${2:-}"; shift 2 ;;
      *) usage_err "require-claim: unknown arg $1" ;;
    esac
  done
  [[ -n "$repo" && -d "$repo" ]] || usage_err "require-claim needs --repo PATH"
  [[ -n "$issue" && "$issue" =~ ^[0-9]+$ ]] || usage_err "require-claim needs --issue N"

  local ids found=0
  ids=$(claim_ids_for_issue "$repo" "$issue" | sort -u)
  if [[ -n "$claim_id" ]]; then
    if printf '%s\n' "$ids" | grep -qxF -- "$claim_id"; then
      found=1
    fi
  else
    [[ -n "$ids" ]] && found=1
  fi

  if [[ "$found" -ne 1 ]]; then
    echo "enforce.sh: BLOCKED — no live claim for issue #$issue in $repo (Law 2)" >&2
    echo "enforce.sh: run: $CLAIM_SH $issue <slug> <scope...> then work only in the worktree" >&2
    return 1
  fi
  echo "enforce.sh: claim ok for issue #$issue${claim_id:+ ($claim_id)}"
  return 0
}

cmd_require_worktree() {
  local repo="" canonical=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --canonical) canonical="${2:-}"; shift 2 ;;
      *) usage_err "require-worktree: unknown arg $1" ;;
    esac
  done
  [[ -n "$repo" && -d "$repo" ]] || usage_err "require-worktree needs --repo PATH"
  [[ -n "$canonical" && -d "$canonical" ]] || usage_err "require-worktree needs --canonical PATH"

  local r c
  r=$(cd "$repo" && pwd -P)
  c=$(cd "$canonical" && pwd -P)
  if [[ "$r" == "$c" ]]; then
    echo "enforce.sh: BLOCKED — refusing to mutate the canonical checkout (Law 3)" >&2
    echo "enforce.sh: repo=$r is the same path as canonical=$c" >&2
    return 1
  fi
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "enforce.sh: BLOCKED — $repo is not a git directory" >&2
    return 1
  fi
  echo "enforce.sh: worktree isolation ok ($r != $c)"
  return 0
}

cmd_baseline() {
  need_scripts
  if [[ "${1:-}" == "--" ]]; then shift; fi
  "$BASELINE_SH" "$@"
}

cmd_gate() {
  need_scripts
  if [[ "${1:-}" == "--" ]]; then shift; fi
  "$GATE_SH" "$@"
}

cmd_pre_edit() {
  local repo="" issue="" claim_id="" canonical=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --claim-id) claim_id="${2:-}"; shift 2 ;;
      --canonical) canonical="${2:-}"; shift 2 ;;
      *) usage_err "pre-edit: unknown arg $1" ;;
    esac
  done
  local args=(--repo "$repo" --issue "$issue")
  [[ -n "$claim_id" ]] && args+=(--claim-id "$claim_id")
  cmd_require_claim "${args[@]}"
  if [[ -n "$canonical" ]]; then
    cmd_require_worktree --repo "$repo" --canonical "$canonical"
  fi
}

cmd_pre_commit() {
  local repo="" issue="" claim_id="" canonical=""
  local gate_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --claim-id) claim_id="${2:-}"; shift 2 ;;
      --canonical) canonical="${2:-}"; shift 2 ;;
      --) shift; gate_args=("$@"); break ;;
      *) usage_err "pre-commit: unknown arg $1" ;;
    esac
  done
  local args=(--repo "$repo" --issue "$issue")
  [[ -n "$claim_id" ]] && args+=(--claim-id "$claim_id")
  cmd_require_claim "${args[@]}"
  if [[ -n "$canonical" ]]; then
    cmd_require_worktree --repo "$repo" --canonical "$canonical"
  fi
  need_scripts
  (
    cd "$repo" || exit 1
    if [[ ${#gate_args[@]} -gt 0 ]]; then
      "$GATE_SH" "${gate_args[@]}"
    else
      "$GATE_SH"
    fi
  )
}

cmd_release() {
  need_scripts
  local issue=""
  if [[ $# -lt 1 ]]; then usage_err "release needs <issue>"; fi
  issue="$1"; shift
  "$RELEASE_SH" "$issue" "$@"
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || usage_err "missing command"
  shift || true
  case "$cmd" in
    -h|--help|help) usage; exit 0 ;;
    require-claim) cmd_require_claim "$@" ;;
    require-worktree) cmd_require_worktree "$@" ;;
    baseline) cmd_baseline "$@" ;;
    gate) cmd_gate "$@" ;;
    pre-edit) cmd_pre_edit "$@" ;;
    pre-commit) cmd_pre_commit "$@" ;;
    release) cmd_release "$@" ;;
    *) usage_err "unknown command: $cmd" ;;
  esac
}

main "$@"
