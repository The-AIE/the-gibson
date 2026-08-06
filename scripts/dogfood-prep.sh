#!/usr/bin/env bash
# dogfood-prep.sh — preflight for unattended overnight dogfood on Gibson (#96)
set -euo pipefail

usage() {
  cat <<'HELP'
dogfood-prep.sh — prepare (or optionally launch) a Gibson dogfood loop

WHAT IT DOES
  Checks that this machine can run scripts/loop.sh against a target repo
  safely: kill switches, error/stale budgets, runner CLI, repo-slug match,
  self-gate presence, and a printed launch command. Does NOT start an
  unattended overnight run unless you pass --run with explicit confirm.

WHY
  Issue #96: the first real overnight dogfood should fail for product reasons,
  not missing flags, wrong origin, or no halt path.

USAGE
  dogfood-prep.sh --repo PATH --repo-slug owner/name --runner NAME [options]
  dogfood-prep.sh --help

OPTIONS
  --repo PATH          target repository (required)
  --repo-slug SLUG     expected origin owner/name (required)
  --runner NAME        grok|hermes|claude|codex (required for --run; optional for check)
  --gibson PATH        Gibson clone (default: parent of scripts/)
  --max-iterations N   default 20 for dogfood
  --error-budget N     default 5
  --stale-budget N     default same as error-budget
  --solo-platform      pass through for single-vendor mode (#69)
  --check-only         only preflight (default)
  --run                launch loop after green preflight
  --confirm YES        required with --run (must be the word YES)
  --allow-halt-present do not fail if gibson/HALT already exists

EXIT
  0 preflight green (and loop finished ok if --run)
  1 preflight or loop failure
  2 usage error
HELP
}

die() { echo "dogfood-prep.sh: FAIL — $*" >&2; exit 1; }
warn() { echo "dogfood-prep.sh: WARN — $*" >&2; }
ok() { echo "dogfood-prep.sh: ok   — $*"; }
usage_err() { echo "dogfood-prep.sh: $*" >&2; usage >&2; exit 2; }

REPO=""
SLUG=""
RUNNER=""
GIBSON=""
MAX=20
BUDGET=5
STALE=""
SOLO=0
CHECK_ONLY=1
CONFIRM=""
ALLOW_HALT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --repo-slug) SLUG="${2:-}"; shift 2 ;;
    --runner) RUNNER="${2:-}"; shift 2 ;;
    --gibson) GIBSON="${2:-}"; shift 2 ;;
    --max-iterations) MAX="${2:-}"; shift 2 ;;
    --error-budget) BUDGET="${2:-}"; shift 2 ;;
    --stale-budget) STALE="${2:-}"; shift 2 ;;
    --solo-platform) SOLO=1; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --run) CHECK_ONLY=0; shift ;;
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    --allow-halt-present) ALLOW_HALT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_err "unknown arg: $1" ;;
  esac
done

[[ -n "$REPO" ]] || usage_err "--repo is required"
[[ -n "$SLUG" ]] || usage_err "--repo-slug is required"
[[ -d "$REPO" ]] || die "repo not a directory: $REPO"

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
if [[ -z "$GIBSON" ]]; then
  GIBSON=$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd)
fi
[[ -d "$GIBSON" ]] || die "gibson path missing: $GIBSON"
LOOP="$GIBSON/scripts/loop.sh"
[[ -x "$LOOP" ]] || die "missing executable $LOOP"

FAILS=0
fail() { echo "dogfood-prep.sh: FAIL — $*" >&2; FAILS=$((FAILS + 1)); }

echo "dogfood-prep.sh: preflight"
echo "  gibson=$GIBSON"
echo "  repo=$REPO"
echo "  slug=$SLUG"

# --- core harness files ---
for f in \
  "$GIBSON/scripts/loop.sh" \
  "$GIBSON/scripts/claim.sh" \
  "$GIBSON/scripts/gate.sh" \
  "$GIBSON/scripts/silent-noop.sh" \
  "$GIBSON/scripts/tests/run-all.sh" \
  "$GIBSON/playbooks/loop-step.md" \
  "$GIBSON/AGENTS.md"
do
  if [[ -e "$f" ]]; then ok "present $(basename "$f")"
  else fail "missing $f"; fi
done

# --- target is a git repo with matching origin ---
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  fail "target is not a git repository"
else
  ok "target is a git repository"
fi

origin=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
if [[ -z "$origin" ]]; then
  fail "target has no origin remote (loop --repo-slug cannot bind)"
else
  ok "origin=$origin"
  # Normalize common URL shapes to owner/name
  norm="$origin"
  norm=${norm%.git}
  norm=${norm#git@github.com:}
  norm=${norm#https://github.com/}
  norm=${norm#http://github.com/}
  norm=${norm#ssh://git@github.com/}
  if [[ "$norm" == "$SLUG" ]]; then
    ok "repo-slug matches origin ($SLUG)"
  else
    fail "repo-slug '$SLUG' does not match origin path '$norm'"
  fi
fi

# --- kill switch paths exist / documented ---
STATE_DIR="$REPO/gibson"
mkdir -p "$STATE_DIR"
HALT="$STATE_DIR/HALT"
if [[ -e "$HALT" ]]; then
  if [[ "$ALLOW_HALT" -eq 1 ]]; then
    warn "gibson/HALT present (allowed by flag) — loop will not work until removed"
  else
    fail "gibson/HALT present — remove it or pass --allow-halt-present"
  fi
else
  ok "no gibson/HALT (local kill switch is clear)"
fi
# Prove we can create the kill switch
if touch "$STATE_DIR/.dogfood-prep-write-test" 2>/dev/null; then
  rm -f "$STATE_DIR/.dogfood-prep-write-test"
  ok "writable gibson/ state dir (halt file can be created)"
else
  fail "cannot write $STATE_DIR"
fi

# --- budgets numeric ---
for pair in "max-iterations:$MAX" "error-budget:$BUDGET"; do
  name=${pair%%:*}; val=${pair##*:}
  if [[ "$val" =~ ^[1-9][0-9]*$ ]]; then ok "$name=$val"
  else fail "invalid $name=$val"; fi
done
if [[ -n "$STALE" ]]; then
  if [[ "$STALE" =~ ^[1-9][0-9]*$ ]]; then ok "stale-budget=$STALE"
  else fail "invalid stale-budget=$STALE"; fi
fi

# --- runner ---
if [[ -n "$RUNNER" ]]; then
  case "$RUNNER" in
    grok|hermes|claude|codex) ok "runner name recognized: $RUNNER" ;;
    goose) fail "runner goose is not wired in loop.sh yet (parked #28/#33)" ;;
    *) fail "unknown runner: $RUNNER" ;;
  esac
  if command -v "$RUNNER" >/dev/null 2>&1; then
    ok "runner CLI on PATH: $(command -v "$RUNNER")"
  else
    warn "runner CLI '$RUNNER' not on PATH (required only when launching with --run --confirm YES)"
  fi
else
  if [[ "$CHECK_ONLY" -eq 0 ]]; then
    fail "--runner is required with --run"
  else
    warn "no --runner (check-only); add one before overnight launch"
  fi
fi

# --- print-prompt smoke (no model call) ---
if [[ -n "$RUNNER" ]]; then
  if out=$("$LOOP" --runner "$RUNNER" --repo "$REPO" --repo-slug "$SLUG" \
      --gibson "$GIBSON" --print-prompt --once 2>&1); then
    if echo "$out" | grep -qiE 'hat|loop|AGENTS|builder|Law'; then
      ok "loop --print-prompt rendered a non-empty prompt"
    else
      warn "print-prompt returned but content looks thin"
    fi
  else
    # print-prompt may fail if loop-state missing — still useful signal
    fail "loop --print-prompt failed: $(echo "$out" | tail -3 | tr '\n' ' ')"
  fi
fi

# --- self-gate presence (dogfood target is often Gibson itself) ---
if [[ -f "$REPO/scripts/tests/run-all.sh" ]]; then
  ok "target has scripts/tests/run-all.sh (self-gate available)"
else
  warn "target has no run-all.sh (ok for product targets; required for Gibson-on-Gibson dogfood)"
fi

# --- evidence template ---
EVIDENCE_DIR="$GIBSON/memory/dogfood"
if [[ -d "$EVIDENCE_DIR" ]]; then
  ok "evidence dir $EVIDENCE_DIR"
else
  warn "missing memory/dogfood — create before committing journal evidence"
fi

echo
if [[ "$FAILS" -gt 0 ]]; then
  echo "dogfood-prep.sh: RED — $FAILS check(s) failed"
  exit 1
fi

echo "dogfood-prep.sh: GREEN — preflight passed"
LAUNCH=("$LOOP" --runner "${RUNNER:-<runner>}" --repo "$REPO" --repo-slug "$SLUG" \
  --gibson "$GIBSON" --max-iterations "$MAX" --error-budget "$BUDGET")
[[ -n "$STALE" ]] && LAUNCH+=(--stale-budget "$STALE")
[[ "$SOLO" -eq 1 ]] && LAUNCH+=(--solo-platform)

echo
echo "Suggested overnight launch (review, then confirm):"
printf '  %q' "${LAUNCH[@]}"
echo
echo "  # local kill:  touch $HALT"
echo "  # or:          GIBSON_HALT=1"
echo "  # evidence:    copy $REPO/gibson/journal.md → memory/dogfood/YYYY-MM-DD-journal.md"
echo

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "dogfood-prep.sh: check-only complete (did not start loop)"
  exit 0
fi

if [[ "$CONFIRM" != "YES" ]]; then
  die "--run requires --confirm YES (refusing unattended launch without explicit confirm)"
fi
[[ -n "$RUNNER" ]] || die "--runner required for --run"
if ! command -v "$RUNNER" >/dev/null 2>&1; then
  die "runner CLI '$RUNNER' not on PATH"
fi

echo "dogfood-prep.sh: launching loop (confirm=YES)…"
exec "${LAUNCH[@]}"
