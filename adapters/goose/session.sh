#!/usr/bin/env bash
# session.sh — Gibson-branded Goose role session lifecycle (#33)
#
# Orchestrates claim checks, baseline, gate enforcement, and stamp.
# Does NOT require goose on PATH for the enforce path.
# Live `goose run` remains blocked until #28 authorizes it.
set -euo pipefail

usage() {
  cat <<'HELP'
session.sh — Gibson role session on the Goose engine path (lifecycle)

WHAT IT DOES
  Runs the operator/orchestrator sequence for one Gibson role session with
  fail-closed claim/gate discipline (Laws 2, 3, 4, 10). Gibson-branded:
  operators never need to type "goose" for enforcement.

  Modes:
    prepare            claim checks + baseline (before agent work)
    pre-commit         claim + gate (before any commit)
    validate-recipe    goose recipe validate if goose is installed (optional)
    stamp              recipe-stamp.sh audit row
    status             doctrine mount order + permission map path
    dry-run-lifecycle  offline transcript of blocked red-gate (for sensors)

WHY
  Issue #33: doctrine mounting + session lifecycle. Issue #35: enforcement
  invocable in-session with same exit codes as the shell path.

USAGE
  session.sh prepare --repo PATH --issue N [--canonical PATH] [--claim-id ID]
  session.sh pre-commit --repo PATH --issue N [--canonical PATH] [--claim-id ID]
  session.sh validate-recipe --role builder|reviewer|security|red-team
  session.sh stamp --role ROLE --issue N [--repo PATH] [--pr N]
  session.sh status
  session.sh dry-run-lifecycle
  session.sh --help

ENV
  GIBSON_ROOT   Gibson clone (default: repo root above adapters/goose)

EXIT
  0 success; 1 blocked/failed gate; 2 usage; 3 goose binary missing (validate only)
HELP
}

die() { echo "session.sh: ERROR: $*" >&2; exit 1; }
usage_err() { echo "session.sh: $*" >&2; usage >&2; exit 2; }

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
DEFAULT_GIBSON=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
GIBSON_ROOT="${GIBSON_ROOT:-$DEFAULT_GIBSON}"
ENFORCE="$SCRIPT_DIR/enforce.sh"
PERM_MAP="$SCRIPT_DIR/permission-map.yaml"
RECIPES="$GIBSON_ROOT/playbooks/recipes"
STAMP="$GIBSON_ROOT/scripts/recipe-stamp.sh"

[[ -x "$ENFORCE" ]] || die "missing $ENFORCE"

cmd_status() {
  cat <<EOF
session.sh: Gibson Goose adapter status
  gibson_root:     $GIBSON_ROOT
  enforce:         $ENFORCE
  permission_map:  $PERM_MAP
  recipes:         $RECIPES
  goose_on_path:   $(command -v goose >/dev/null 2>&1 && goose --version 2>/dev/null | head -1 || echo 'absent (NOT required for enforce)')
  live_goose_run:  blocked until #28

Doctrine mount order (explicit; never ambient-only):
  1. $GIBSON_ROOT/AGENTS.md
  2. $GIBSON_ROOT/local/AGENTS.local.md (if present)
  3. <target>/AGENTS.md (if present)
  4. role playbook — local/playbooks/<role>.md replaces core (never both)
  5. $GIBSON_ROOT/memory/LESSONS.md

Lifecycle:
  claim -> worktree -> gate-baseline -> [agent work] -> enforce pre-commit (gate) -> merge -> release-claim -> recipe-stamp
EOF
}

cmd_prepare() {
  local repo="" issue="" claim_id="" canonical=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --claim-id) claim_id="${2:-}"; shift 2 ;;
      --canonical) canonical="${2:-}"; shift 2 ;;
      *) usage_err "prepare: unknown arg $1" ;;
    esac
  done
  [[ -n "$repo" && -n "$issue" ]] || usage_err "prepare needs --repo and --issue"
  local args=(--repo "$repo" --issue "$issue")
  [[ -n "$claim_id" ]] && args+=(--claim-id "$claim_id")
  [[ -n "$canonical" ]] && args+=(--canonical "$canonical")
  "$ENFORCE" pre-edit "${args[@]}"
  (
    cd "$repo" || exit 1
    "$ENFORCE" baseline
  )
  echo "session.sh: prepare ok — safe to start agent work in $repo"
}

cmd_pre_commit() {
  local repo="" issue="" claim_id="" canonical=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --claim-id) claim_id="${2:-}"; shift 2 ;;
      --canonical) canonical="${2:-}"; shift 2 ;;
      *) usage_err "pre-commit: unknown arg $1" ;;
    esac
  done
  [[ -n "$repo" && -n "$issue" ]] || usage_err "pre-commit needs --repo and --issue"
  local args=(--repo "$repo" --issue "$issue")
  [[ -n "$claim_id" ]] && args+=(--claim-id "$claim_id")
  [[ -n "$canonical" ]] && args+=(--canonical "$canonical")
  "$ENFORCE" pre-commit "${args[@]}"
  echo "session.sh: pre-commit ok — gate green"
}

cmd_validate_recipe() {
  local role="builder"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) role="${2:-}"; shift 2 ;;
      *) usage_err "validate-recipe: unknown arg $1" ;;
    esac
  done
  local f="$RECIPES/${role}.yaml"
  [[ -f "$f" ]] || die "recipe not found: $f"
  if ! command -v goose >/dev/null 2>&1; then
    echo "session.sh: goose binary absent — recipe validate NOT RUN (offline sensors remain the gate)" >&2
    exit 3
  fi
  goose recipe validate "$f"
}

cmd_stamp() {
  local role="" issue="" repo="" pr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) role="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --pr) pr="${2:-}"; shift 2 ;;
      *) usage_err "stamp: unknown arg $1" ;;
    esac
  done
  [[ -n "$role" ]] || usage_err "stamp needs --role"
  local recipe="$RECIPES/${role}.yaml"
  [[ -f "$recipe" ]] || recipe="$RECIPES/builder.yaml"
  [[ -x "$STAMP" ]] || die "missing $STAMP"
  local args=(--role "$role" --recipe "$recipe")
  [[ -n "$issue" ]] && args+=(--issue "$issue")
  [[ -n "$repo" ]] && args+=(--repo "$repo")
  [[ -n "$pr" ]] && args+=(--pr "$pr")
  "$STAMP" "${args[@]}"
}

cmd_dry_run_lifecycle() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/gibson-session-dry.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$root'" RETURN

  mkdir -p "$root/canon/docs/claims"
  printf 'claim: issue-99-demo\nissue: 99\n' > "$root/canon/docs/claims/issue-99-demo.md"
  mkdir -p "$root/wt-empty/docs"
  echo "=== transcript: no claim -> pre-edit BLOCKED ==="
  if "$ENFORCE" pre-edit --repo "$root/wt-empty" --issue 99 --canonical "$root/canon" 2>"$root/err1"; then
    echo "FAIL: expected block" >&2
    return 1
  fi
  cat "$root/err1"
  grep -q 'BLOCKED' "$root/err1" || { echo "missing BLOCKED marker" >&2; return 1; }

  echo "=== transcript: claim present + distinct worktree -> pre-edit OK ==="
  mkdir -p "$root/wt-ok/docs/claims"
  cp "$root/canon/docs/claims/issue-99-demo.md" "$root/wt-ok/docs/claims/"
  git -C "$root/canon" init -q
  git -C "$root/wt-ok" init -q
  "$ENFORCE" pre-edit --repo "$root/wt-ok" --issue 99 --canonical "$root/canon"

  echo "=== transcript: canonical checkout mutation BLOCKED ==="
  if "$ENFORCE" require-worktree --repo "$root/canon" --canonical "$root/canon" 2>"$root/err2"; then
    echo "FAIL: expected canonical block" >&2
    return 1
  fi
  cat "$root/err2"
  grep -q 'BLOCKED' "$root/err2" || return 1

  echo "=== transcript: red-gate simulation (gate.sh fail-closed) ==="
  mkdir -p "$root/gibson/scripts" "$root/gibson/adapters/goose"
  cp "$ENFORCE" "$root/gibson/adapters/goose/enforce.sh"
  chmod +x "$root/gibson/adapters/goose/enforce.sh"
  for s in claim.sh gate-baseline.sh release-claim.sh; do
    printf '#!/bin/sh\nexit 0\n' > "$root/gibson/scripts/$s"
    chmod +x "$root/gibson/scripts/$s"
  done
  cat > "$root/gibson/scripts/gate.sh" <<'FAKE'
#!/usr/bin/env bash
echo "gate.sh: RED — simulated new test failures vs baseline" >&2
exit 1
FAKE
  chmod +x "$root/gibson/scripts/gate.sh"
  if GIBSON_ROOT="$root/gibson" "$root/gibson/adapters/goose/enforce.sh" \
      pre-commit --repo "$root/wt-ok" --issue 99 --canonical "$root/canon" \
      2>"$root/err3"; then
    echo "FAIL: expected red gate block" >&2
    return 1
  fi
  cat "$root/err3"
  grep -qE 'RED|BLOCKED|fail' "$root/err3" || true

  echo "session.sh: dry-run-lifecycle transcript complete (fail-closed proven offline)"
  return 0
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || usage_err "missing command"
  shift || true
  case "$cmd" in
    -h|--help|help) usage; exit 0 ;;
    prepare) cmd_prepare "$@" ;;
    pre-commit) cmd_pre_commit "$@" ;;
    validate-recipe) cmd_validate_recipe "$@" ;;
    stamp) cmd_stamp "$@" ;;
    status) cmd_status ;;
    dry-run-lifecycle) cmd_dry_run_lifecycle ;;
    *) usage_err "unknown command: $cmd" ;;
  esac
}

main "$@"
