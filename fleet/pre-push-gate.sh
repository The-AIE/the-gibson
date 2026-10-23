#!/usr/bin/env bash
# pre-push-gate.sh — run the repo's local gate in a lane worktree; exit non-zero if it is red.
#
# Why (2026-10-15, Mark): "the coder owns the green loop" (FLEET.md) makes a green LOCAL gate the
# precondition for the first push. The dispatch template already says so; this makes it a check
# rather than a sentence, because prose is advisory and gates are law. Installed as the lane's
# pre-push hook by install-lane-hooks.sh (called from lane-sync.sh). Tracked in The-AIE/the-gibson
# under fleet/; ~/.claude/fleet holds symlinks to it (fleet/install.sh, fleet/README.md).
#
# Resolution order (first match wins):
#   1. .fleet-gate at the worktree root — one shell command line, repo-owned override. "Repo-owned"
#      is enforced: it counts only if it is byte-identical to origin/main's copy. A .fleet-gate that is
#      new in the lane, edited, or deleted is a gate change, and the gate FAILS CLOSED.
#   2. known repos by origin URL: the-gibson, conference-os, chatterbuilt
#   3. generic: package.json scripts typecheck / lint / test, whichever exist
# FLEET_GATE_FULL=1 adds the slow parts (chatterbuilt: build; conference-os: e2e is NOT added —
# that is CI's job). There is deliberately no skip variable; `git push --no-verify` exists and is
# visible in the shell history, a silent env var is not.
#
# Usage: pre-push-gate.sh [worktree]      exit 0 green, 1 red, 64 usage
# Env: FLEET_LOG_DIR  where the gate log goes (default ~/.claude/fleet/logs; created if missing)
set -uo pipefail
# Sibling scripts resolve from where THIS file lives, not from the environment (see hooks/pre-push).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Locale: default one when the caller has none. The Cowork Bash tool shell exports LANG and LC_ALL
# EMPTY; under that, every conference-os *-postgres.test.ts suite died on 2026-10-23 with
# "FATAL: postmaster became multithreaded during startup / HINT: Set the LC_ALL environment
# variable to a valid locale" — six red suites that looked like product defects. A caller's own
# non-empty value is kept; only unset/empty is filled, before any gate command runs.
: "${LC_ALL:=en_US.UTF-8}"; export LC_ALL
: "${LANG:=en_US.UTF-8}"; export LANG
WT="${1:-$PWD}"
cd "$WT" 2>/dev/null || { echo "pre-push-gate: no such dir $WT" >&2; exit 64; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "pre-push-gate: not a git worktree" >&2; exit 64; }
cd "$ROOT" || exit 64
LOGDIR="${FLEET_LOG_DIR:-$HOME/.claude/fleet/logs}"
mkdir -p "$LOGDIR" 2>/dev/null || { echo "pre-push-gate: cannot create log dir $LOGDIR — FAILING CLOSED" >&2; exit 1; }
LOG="$LOGDIR/pre-push-gate-$(date +%Y%m%d-%H%M%S)-$$.log"
ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
MAIN="origin/main"   # scope boundary for touched-package detection: deliberately NOT overridable

run() { # run <label> <cmd...>
  local label="$1"; shift
  echo "pre-push-gate: $label: $*"
  # A pre-push hook inherits GIT_DIR. Product tests that spawn their own
  # repositories then run git against THIS repo and can flip core.bare.
  # Drop the hook's git environment for the gated command only. The
  # script's own git calls above still see it.
  if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX \
        -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY -u GIT_NAMESPACE \
        "$@" >>"$LOG" 2>&1; then echo "pre-push-gate: $label: green"; return 0; fi
  echo "pre-push-gate: $label: RED — last 40 lines of $LOG:" >&2
  tail -40 "$LOG" >&2
  return 1
}
has_script() { python3 - "$1" "$2" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
sys.exit(0 if sys.argv[2] in d.get("scripts",{}) else 1)
PY
}

git fetch -q origin main 2>/dev/null || echo "pre-push-gate: WARNING fetch of $MAIN failed; using the last known ref" >&2
if [ -f .fleet-gate ] || git cat-file -e "$MAIN:.fleet-gate" 2>/dev/null; then
  git rev-parse --verify -q "$MAIN^{commit}" >/dev/null \
    || { echo "pre-push-gate: $MAIN is unresolvable; cannot verify .fleet-gate is repo-owned — FAILING CLOSED" >&2; exit 1; }
  git cat-file -e "$MAIN:.fleet-gate" 2>/dev/null \
    || { echo "pre-push-gate: .fleet-gate exists in this lane but not on $MAIN — a gate file is repo-owned, FAILING CLOSED" >&2; exit 1; }
  if [ ! -f .fleet-gate ] || ! git diff --quiet "$MAIN" -- .fleet-gate; then
    echo "pre-push-gate: .fleet-gate differs from $MAIN (edited or deleted in this lane) — the gate is not the coder's to change, FAILING CLOSED" >&2; exit 1
  fi
  # POSIX class, not \s: the first non-blank non-comment line is the command; a comment must never be
  # what bash -c runs (it would exit 0 = false green). Codex read-only review 2026-10-23.
  CMD="$(grep -vE '^[[:space:]]*(#|$)' .fleet-gate | head -1)"
  [ -n "$CMD" ] || { echo "pre-push-gate: .fleet-gate is empty — FAILING CLOSED" >&2; exit 1; }
  run ".fleet-gate" bash -c "$CMD"; exit $?
fi

case "$ORIGIN" in
  *the-gibson*)
    # NEVER run the-gibson's suites inside a lane: they rewrite the shared .git (2026-10-15 incident).
    run "gibson gate (isolated clone)" "$HERE/gibson-isolated-gate.sh" "$ROOT"; exit $? ;;
  *conference-os*)
    # vitest capped at 3 workers (spinup rule): unconstrained vitest on a loaded Mac with sibling
    # lanes produces timeout failures in timing-sensitive suites that look exactly like defects.
    run "typecheck" npm run -s typecheck:ci && run "lint" npm run -s lint && run "test" npx vitest run --maxWorkers=3
    exit $? ;;
  *chatterbuilt*)
    # No root manifest; the gate is per gated package. Gate the packages this lane touched.
    git rev-parse --verify -q "$MAIN^{commit}" >/dev/null \
      || { echo "pre-push-gate: chatterbuilt: base $MAIN is unresolvable — cannot evaluate, FAILING CLOSED" >&2; exit 1; }
    git merge-base "$MAIN" HEAD >/dev/null 2>&1 \
      || { echo "pre-push-gate: chatterbuilt: $MAIN and HEAD share no history — cannot scope touched packages, FAILING CLOSED" >&2; exit 1; }
    COMMITTED="$(git diff --name-only "$MAIN"...HEAD)" || { echo "pre-push-gate: chatterbuilt: git diff vs $MAIN failed — FAILING CLOSED" >&2; exit 1; }
    UNCOMMITTED="$(git diff --name-only HEAD)" || { echo "pre-push-gate: chatterbuilt: git diff HEAD failed — FAILING CLOSED" >&2; exit 1; }
    PKGS="$(printf '%s\n%s\n' "$COMMITTED" "$UNCOMMITTED" | grep -oE '^(apps|packages)/[^/]+' | sort -u)"   # bash 3.2: no mapfile
    [ -n "$PKGS" ] || { echo "pre-push-gate: chatterbuilt: no gated package touched"; exit 0; }
    for p in $PKGS; do
      ran=0
      if [ -f "$p/package.json" ]; then
        for s in typecheck lint test $( [ -n "${FLEET_GATE_FULL:-}" ] && echo build ); do
          has_script "$p/package.json" "$s" || continue
          [ "$s" = build ] || ran=1          # build is extra under FLEET_GATE_FULL; it never counts as a check
          run "$p $s" npm --prefix "$p" run -s "$s" || exit 1
        done
      fi
      [ $ran -eq 1 ] || { echo "pre-push-gate: chatterbuilt: $p was touched but has no typecheck/lint/test script — cannot evaluate, FAILING CLOSED (add one, or a .fleet-gate)" >&2; exit 1; }
    done
    exit 0 ;;
esac

# generic
[ -f package.json ] || { echo "pre-push-gate: no gate known for this repo (no .fleet-gate, no package.json) — FAILING CLOSED" >&2; exit 1; }
ran=0
for s in typecheck lint test; do
  has_script package.json "$s" || continue
  ran=1; run "$s" npm run -s "$s" || exit 1
done
[ $ran -eq 1 ] || { echo "pre-push-gate: package.json has no typecheck/lint/test script — FAILING CLOSED; add .fleet-gate" >&2; exit 1; }
exit 0
