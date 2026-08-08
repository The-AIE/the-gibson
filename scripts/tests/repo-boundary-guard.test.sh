#!/usr/bin/env bash
set -uo pipefail

# Hermetic git identity (#101): suites that commit must not read ambient global
# user.name/email. Pass with HOME pointed at an empty directory.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/../repo-boundary-guard.sh"
PASS=0
FAIL=0
SKIP=0
ok() { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP — $1"; SKIP=$((SKIP + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/.agents"
git -C "$ROOT" init -q -b main
git -C "$ROOT" config user.email test@gibson.invalid
git -C "$ROOT" config user.name gibson-test
printf 'base\n' > "$ROOT/README.md"
git -C "$ROOT" add README.md
git -C "$ROOT" commit -qm base
git -C "$ROOT" remote add origin https://github.com/acme/app.git

# Physical form of the fixture root (macOS: /var → /private/var).
ROOT_PHYS=$(CDPATH='' cd -- "$ROOT" && pwd -P)

run_guard_in() {
  local cwd="$1" target="$2"
  shift 2
  (cd "$cwd" &&
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$target" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" "$@")
}

run_guard() {
  run_guard_in "$ROOT" "$ROOT" "$@"
}

# --- control-plane staging: diagnostic, exit 86, index rollback -------------
# On macOS this also exercises logical mktemp (/var/...) vs git's physical
# show-toplevel (/private/var/...) — the #146 first-rejection class.
printf 'forbidden\n' > "$ROOT/.agents/gate.json"
run_guard add .agents/gate.json >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane" "$ROOT/err"; then
  ok "control-plane add rejected with diagnostic (exit $rc)"
else
  bad "control-plane add diagnostic/exit (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
staged=$(git -C "$ROOT" diff --cached --name-only)
if [[ -z "$staged" ]]; then
  ok "control-plane staging rolled back after rejected add"
else
  bad "control-plane staging rolled back (still staged: $staged)"
fi
rm -f "$ROOT/.agents/gate.json"
git -C "$ROOT" reset -q 2>/dev/null || true

# --- selective rollback: legitimate staged work survives protected add ------
# Stage a legitimate README change first, then attempt to add one or more
# protected control-plane files. Protected paths must be unstaged; README must
# remain staged byte-for-byte (same index blob).
printf 'legit change for selective rollback\n' > "$ROOT/README.md"
run_guard add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "legitimate README add before selective-rollback probe (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
  legit_blob=""
else
  legit_blob=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
  if [[ -n "$legit_blob" ]]; then
    ok "legitimate README staged before protected add (blob $legit_blob)"
  else
    bad "legitimate README staged before protected add (no index blob)"
  fi
fi
printf 'forbidden-a\n' > "$ROOT/.agents/gate.json"
printf 'forbidden-b\n' > "$ROOT/.gibson-gate.json"
run_guard add .agents/gate.json .gibson-gate.json >/dev/null 2>"$ROOT/err"
rc=$?
err_txt=$(tr '\n' ' ' <"$ROOT/err")
if [[ "$rc" -eq 86 ]] &&
   grep -q "control-plane file '.agents/gate.json'" "$ROOT/err" &&
   grep -q "control-plane file '.gibson-gate.json'" "$ROOT/err"; then
  ok "multi protected add rejected with per-path diagnostics (exit $rc)"
else
  bad "multi protected add diagnostic/exit (rc=$rc err=$err_txt)"
fi
# Protected paths must not remain staged.
still_protected=$(git -C "$ROOT" diff --cached --name-only | grep -E '^(\.agents/gate\.json|\.gibson-gate\.json)$' || true)
if [[ -z "$still_protected" ]]; then
  ok "protected paths unstaged after selective rollback"
else
  bad "protected paths unstaged (still staged: $still_protected)"
fi
# Legitimate path remains staged byte-for-byte.
after_blob=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
staged_names=$(git -C "$ROOT" diff --cached --name-only)
if [[ -n "$legit_blob" && "$after_blob" == "$legit_blob" && "$staged_names" == "README.md" ]]; then
  ok "legitimate README remains staged byte-for-byte after selective rollback"
else
  bad "legitimate README survives selective rollback (blob before=$legit_blob after=$after_blob staged=$(echo "$staged_names" | tr '\n' ' '))"
fi
# Cleanup selective-rollback fixture state.
rm -f "$ROOT/.agents/gate.json" "$ROOT/.gibson-gate.json"
git -C "$ROOT" reset -q 2>/dev/null || true
git -C "$ROOT" checkout -q -- README.md 2>/dev/null || true

# --- selective rollback from a repository subdirectory ----------------------
# scan_staged_control_plane returns root-relative paths; reset must run against
# the repo root (or top pathspecs). Reproduce: cwd=subdir, stage legit + multiple
# protected paths, exit 86, unstage all offenders, preserve legitimate blob.
printf 'subdir legit selective rollback\n' > "$ROOT/README.md"
run_guard add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "legitimate README add before subdir selective-rollback (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
  sub_legit_blob=""
else
  sub_legit_blob=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
  if [[ -n "$sub_legit_blob" ]]; then
    ok "legitimate README staged before subdir protected add (blob $sub_legit_blob)"
  else
    bad "legitimate README staged before subdir protected add (no index blob)"
  fi
fi
mkdir -p "$ROOT/work/sub"
printf 'forbidden-sub-a\n' > "$ROOT/.agents/gate.json"
printf 'forbidden-sub-b\n' > "$ROOT/.gibson-gate.json"
run_guard_in "$ROOT/work/sub" "$ROOT" add ../../.agents/gate.json ../../.gibson-gate.json \
  >/dev/null 2>"$ROOT/err"
rc=$?
err_txt=$(tr '\n' ' ' <"$ROOT/err")
if [[ "$rc" -eq 86 ]] &&
   grep -q "control-plane file '.agents/gate.json'" "$ROOT/err" &&
   grep -q "control-plane file '.gibson-gate.json'" "$ROOT/err"; then
  ok "subdir multi protected add rejected with per-path diagnostics (exit $rc)"
else
  bad "subdir multi protected add diagnostic/exit (rc=$rc err=$err_txt)"
fi
still_protected=$(git -C "$ROOT" diff --cached --name-only | grep -E '^(\.agents/gate\.json|\.gibson-gate\.json)$' || true)
if [[ -z "$still_protected" ]]; then
  ok "subdir: protected paths unstaged after selective rollback"
else
  bad "subdir: protected paths unstaged (still staged: $still_protected)"
fi
after_blob=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
staged_names=$(git -C "$ROOT" diff --cached --name-only)
if [[ -n "$sub_legit_blob" && "$after_blob" == "$sub_legit_blob" && "$staged_names" == "README.md" ]]; then
  ok "subdir: legitimate README remains staged byte-for-byte after selective rollback"
else
  bad "subdir: legitimate README survives selective rollback (blob before=$sub_legit_blob after=$after_blob staged=$(echo "$staged_names" | tr '\n' ' '))"
fi
rm -f "$ROOT/.agents/gate.json" "$ROOT/.gibson-gate.json"
git -C "$ROOT" reset -q 2>/dev/null || true
git -C "$ROOT" checkout -q -- README.md 2>/dev/null || true

# --- portable logical-vs-physical alias (symlink to same repo) --------------
# Alias lives under its own mktemp dir (outside ROOT); re-register trap so both
# fixtures are cleaned. (Do not put the alias under ROOT — that is not required.)
ALIAS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard-alias.XXXXXX")
trap 'rm -rf "$ROOT" "$ALIAS_DIR"' EXIT
ln -s "$ROOT_PHYS" "$ALIAS_DIR/same-repo"
printf 'forbidden\n' > "$ROOT/.agents/gate.json"
# Target is the symlink path; cwd is the physical checkout — same repo.
run_guard_in "$ROOT_PHYS" "$ALIAS_DIR/same-repo" add .agents/gate.json \
  >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane" "$ROOT/err"; then
  ok "symlink target alias reaches control-plane check (exit $rc)"
else
  bad "symlink target alias control-plane (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
staged=$(git -C "$ROOT" diff --cached --name-only)
if [[ -z "$staged" ]]; then
  ok "symlink-alias path still rolls back staging"
else
  bad "symlink-alias staging rollback (still staged: $staged)"
fi
rm -f "$ROOT/.agents/gate.json"
git -C "$ROOT" reset -q 2>/dev/null || true

# --- macOS /var vs /private/var (exactly 2 assertion lines on every platform) -
# Deterministic tally: always emit two ok/bad/SKIP lines so suite summary shape
# is stable across Darwin vs CI Linux. Unexercised platform cases are SKIP (not
# PASS). On this Mac, when mktemp yields /var/... and pwd -P yields
# /private/var/..., run the real proof.
_macos_var_skip() {
  skip "macOS /var alias: control-plane via logical target ($1)"
  skip "macOS /var alias: staging rollback ($1)"
}
if [[ "$(uname -s)" != "Darwin" ]]; then
  _macos_var_skip "not Darwin"
elif [[ ! -L /var ]]; then
  _macos_var_skip "/var not a symlink"
else
  var_target=$(readlink /var 2>/dev/null || true)
  if [[ "$var_target" != "private/var" && "$var_target" != "/private/var" ]]; then
    _macos_var_skip "/var not → private/var"
  else
    case "$ROOT" in
      /var/*)
        if [[ "$ROOT" != "$ROOT_PHYS" ]]; then
          # Real #146 reproduction: logical TARGET vs physical cwd/git root.
          printf 'forbidden\n' > "$ROOT/.agents/gate.json"
          run_guard_in "$ROOT_PHYS" "$ROOT" add .agents/gate.json \
            >/dev/null 2>"$ROOT/err"
          rc=$?
          if [[ "$rc" -eq 86 ]] && grep -q "control-plane" "$ROOT/err"; then
            ok "macOS /var alias: control-plane via logical target (exit $rc)"
          else
            bad "macOS /var alias: control-plane via logical target (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
          fi
          staged=$(git -C "$ROOT" diff --cached --name-only)
          if [[ -z "$staged" ]]; then
            ok "macOS /var alias: staging rollback"
          else
            bad "macOS /var alias: staging rollback (still staged: $staged)"
          fi
          rm -f "$ROOT/.agents/gate.json"
          git -C "$ROOT" reset -q 2>/dev/null || true
        else
          _macos_var_skip "mktemp already physical"
        fi
        ;;
      *)
        _macos_var_skip "fixture not under /var"
        ;;
    esac
  fi
fi

# --- different repo must still fail closed ----------------------------------
OTHER=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard-other.XXXXXX")
trap 'rm -rf "$ROOT" "$ALIAS_DIR" "$OTHER"' EXIT
git -C "$OTHER" init -q -b main
git -C "$OTHER" config user.email test@gibson.invalid
git -C "$OTHER" config user.name gibson-test
printf 'other\n' > "$OTHER/README.md"
git -C "$OTHER" add README.md
git -C "$OTHER" commit -qm other
run_guard_in "$OTHER" "$ROOT" status >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "outside target repo" "$ROOT/err"; then
  # Diagnostic must show raw configured target and its resolved physical root.
  if grep -Fq "expected '$ROOT'" "$ROOT/err" &&
     grep -Fq "(resolved '$ROOT_PHYS')" "$ROOT/err"; then
    ok "different repo root rejected with raw+resolved diagnostic (exit $rc)"
  else
    bad "different repo root diagnostic forms (err=$(tr '\n' ' ' <"$ROOT/err"))"
  fi
else
  bad "different repo root (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

# Symlink that points at a *different* repository must not count as the target.
ln -s "$OTHER" "$ALIAS_DIR/other-repo"
run_guard_in "$ROOT" "$ALIAS_DIR/other-repo" status >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]]; then
  # Either target resolution fails (not same root) or outside-target compare.
  if grep -Eq "could not be resolved|outside target repo" "$ROOT/err"; then
    ok "symlink to different repo rejected (exit $rc)"
  else
    bad "symlink to different repo message (err=$(tr '\n' ' ' <"$ROOT/err"))"
  fi
else
  bad "symlink to different repo rejected (rc=$rc)"
fi

# Missing / unreadable configured target fails closed.
run_guard_in "$ROOT" "$ROOT/does-not-exist-$$" status >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "could not be resolved" "$ROOT/err"; then
  ok "missing target path rejected (exit $rc)"
else
  bad "missing target path (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

# Nested subdirectory of the target must fail closed: configured target must
# *be* the repository root (intentional; matches loop.sh's production caller
# which sets GIBSON_TARGET_REPO to TARGET_REPO_REALPATH = pwd -P of REPO root).
mkdir -p "$ROOT/nested-sub"
run_guard_in "$ROOT" "$ROOT/nested-sub" status >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "could not be resolved" "$ROOT/err"; then
  ok "nested target path fails closed (exit $rc)"
else
  bad "nested target path (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

# --- wrong-origin push: reason + exit code ----------------------------------
git -C "$ROOT" remote set-url origin https://github.com/the-gibson/harness.git
run_guard push origin main >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "expected 'acme/app'" "$ROOT/err"; then
  ok "wrong-origin push rejected with slug diagnostic (exit $rc)"
else
  bad "wrong-origin push (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
# Restore expected origin for later push sensors.
git -C "$ROOT" remote set-url origin https://github.com/acme/app.git

# --- staged protected deletion (D) and type-change (T) ----------------------
# Seed a tracked control-plane file via real git (harness-owned pre-state).
printf 'seed-gate\n' > "$ROOT/.agents/gate.json"
git -C "$ROOT" add .agents/gate.json
git -C "$ROOT" commit -qm 'seed control-plane gate'
# Deletion: stage with real git rm, then guarded commit must reject (no filter).
git -C "$ROOT" rm -q .agents/gate.json
staged_before=$(git -C "$ROOT" diff --cached --name-only)
run_guard commit -m 'delete protected' >/dev/null 2>"$ROOT/err"
rc=$?
staged_after=$(git -C "$ROOT" diff --cached --name-only)
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "staged protected deletion rejected on commit (exit $rc)"
else
  bad "staged protected deletion commit (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
if [[ "$staged_after" == "$staged_before" && "$staged_after" == ".agents/gate.json" ]]; then
  ok "staged protected deletion leaves index unchanged after rejected commit"
else
  bad "staged protected deletion index (before=$staged_before after=$staged_after)"
fi
git -C "$ROOT" reset -q 2>/dev/null || true
git -C "$ROOT" checkout -q HEAD -- .agents/gate.json 2>/dev/null || true

# Type change: replace regular file with symlink, guarded add must reject (T).
rm -f "$ROOT/.agents/gate.json"
ln -s ../README.md "$ROOT/.agents/gate.json"
run_guard add .agents/gate.json >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "protected regular-to-symlink type-change add rejected (exit $rc)"
else
  bad "protected type-change add (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
staged=$(git -C "$ROOT" diff --cached --name-only)
if [[ -z "$staged" ]]; then
  ok "protected type-change staging rolled back"
else
  bad "protected type-change staging rolled back (still staged: $staged)"
fi
rm -f "$ROOT/.agents/gate.json"
git -C "$ROOT" checkout -q HEAD -- .agents/gate.json 2>/dev/null || true
git -C "$ROOT" reset -q 2>/dev/null || true

# --- commit -a/-am and pathspec bypasses fail closed ------------------------
# Tracked protected file with unstaged modification; ordinary commit of
# unrelated staged work must still succeed; -am and pathspec forms must not.
printf 'seed-gate-v2\n' > "$ROOT/.agents/gate.json"
git -C "$ROOT" add .agents/gate.json
git -C "$ROOT" commit -qm 'refresh control-plane seed'
printf 'dirty protected worktree\n' > "$ROOT/.agents/gate.json"
printf 'safe ordinary commit body\n' > "$ROOT/README.md"
run_guard add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "stage README for ordinary commit sensor (rc=$rc)"
else
  run_guard commit -m 'ordinary safe commit' >/dev/null 2>"$ROOT/err"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "ordinary commit with dirty unstaged protected path succeeds"
  else
    bad "ordinary commit should succeed (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
  fi
fi
# Re-dirty protected path (commit above did not touch it).
printf 'dirty protected for -am\n' > "$ROOT/.agents/gate.json"
run_guard commit -am 'bypass via -am' >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "commit -am with dirty protected path rejected (exit $rc)"
else
  bad "commit -am bypass (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
# Explicit pathspec form.
printf 'dirty protected for pathspec\n' > "$ROOT/.agents/gate.json"
run_guard commit -m 'bypass via pathspec' -- .agents/gate.json >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "commit pathspec with dirty protected path rejected (exit $rc)"
else
  bad "commit pathspec bypass (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
# Bare pathspec without -- (git commit -m msg PATH).
printf 'dirty protected for bare pathspec\n' > "$ROOT/.agents/gate.json"
run_guard commit -m 'bypass bare pathspec' .agents/gate.json >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "commit bare pathspec with dirty protected path rejected (exit $rc)"
else
  bad "commit bare pathspec bypass (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
git -C "$ROOT" checkout -q HEAD -- .agents/gate.json README.md 2>/dev/null || true
git -C "$ROOT" reset -q 2>/dev/null || true

# --- direct commit/push with real-git staged protected path -----------------
# Stage protected via real git (not the guard); guarded commit and push both
# exit 86, emit control-plane diagnostic, and leave the index unchanged.
printf 'staged-for-commit-push\n' > "$ROOT/.agents/gate.json"
git -C "$ROOT" add .agents/gate.json
staged_before=$(git -C "$ROOT" rev-parse :.agents/gate.json 2>/dev/null || true)
index_names_before=$(git -C "$ROOT" diff --cached --name-only)
run_guard commit -m 'blocked protected commit' >/dev/null 2>"$ROOT/err"
rc=$?
staged_after=$(git -C "$ROOT" rev-parse :.agents/gate.json 2>/dev/null || true)
index_names_after=$(git -C "$ROOT" diff --cached --name-only)
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "guarded commit rejects real-git staged protected path (exit $rc)"
else
  bad "guarded commit staged protected (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
if [[ -n "$staged_before" && "$staged_after" == "$staged_before" && "$index_names_after" == "$index_names_before" ]]; then
  ok "guarded commit leaves protected index blob unchanged"
else
  bad "guarded commit index unchanged (blob before=$staged_before after=$staged_after names before=$index_names_before after=$index_names_after)"
fi
run_guard push origin main >/dev/null 2>"$ROOT/err"
rc=$?
staged_after_push=$(git -C "$ROOT" rev-parse :.agents/gate.json 2>/dev/null || true)
index_names_after_push=$(git -C "$ROOT" diff --cached --name-only)
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "guarded push rejects real-git staged protected path (exit $rc)"
else
  bad "guarded push staged protected (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
if [[ -n "$staged_before" && "$staged_after_push" == "$staged_before" && "$index_names_after_push" == "$index_names_before" ]]; then
  ok "guarded push leaves protected index blob unchanged"
else
  bad "guarded push index unchanged (blob before=$staged_before after=$staged_after_push)"
fi
git -C "$ROOT" reset -q 2>/dev/null || true
git -C "$ROOT" checkout -q HEAD -- .agents/gate.json 2>/dev/null || true

# --- unmatched pathspec: real nonzero status propagates (set -e) ------------
# CodeRabbit claimed failed real `git add` is discarded. Under set -e the failed
# add aborts before the scan; sensor proves no false success.
run_guard add "no-such-path-$$-unmatched" >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 && "$rc" -ne 86 ]]; then
  ok "unmatched pathspec propagates real git nonzero status (exit $rc)"
else
  bad "unmatched pathspec must not succeed or look like control-plane 86 (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
# Index must not have been mutated by the failed add.
staged=$(git -C "$ROOT" diff --cached --name-only)
if [[ -z "$staged" ]]; then
  ok "unmatched pathspec leaves index empty"
else
  bad "unmatched pathspec left staged: $staged"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "$PASS passed, $FAIL failed, $SKIP skipped"
  exit 0
fi
echo "$PASS passed, $FAIL failed, $SKIP skipped"
exit 1
