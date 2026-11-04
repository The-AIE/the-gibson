#!/usr/bin/env bash
set -uo pipefail

# Hermetic git identity (#101): suites that commit must not read ambient global
# user.name/email. Pass with HOME pointed at an empty directory.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
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

# --- commit_form_includes_worktree: deterministic parser sensors ------------
# Extract the classifier without executing the guard body (script runs on load).
# Pure function tests — no git, no hang risk for interactive forms.
# Repository-owned source only (not external input); assert the function is
# defined after eval so a renamed/empty extraction cannot false-green the
# _parser_expect_no sensors (undefined → nonzero → "does not include worktree").
eval "$(sed -n '/^commit_form_includes_worktree()/,/^}/p' "$GUARD")"
if ! declare -f commit_form_includes_worktree >/dev/null 2>&1; then
  bad "parser: could not extract commit_form_includes_worktree from $GUARD"
else
_parser_expect_yes() {
  local label="$1"
  shift
  if commit_form_includes_worktree "$@"; then
    ok "parser: $label includes worktree"
  else
    bad "parser: $label should include worktree"
  fi
}
_parser_expect_no() {
  local label="$1"
  shift
  if commit_form_includes_worktree "$@"; then
    bad "parser: $label should NOT include worktree"
  else
    ok "parser: $label does not include worktree"
  fi
}
_parser_expect_yes "-p" commit -p -m msg
_parser_expect_yes "--patch" commit --patch -m msg
_parser_expect_yes "--interactive" commit --interactive -m msg
_parser_expect_yes "combined -ip" commit -ip -m msg
_parser_expect_yes "combined -po" commit -po -m msg
_parser_expect_yes "combined -am (a)" commit -am msg
_parser_expect_yes "-a" commit -a -m msg
_parser_expect_yes "-i" commit -i -m msg
_parser_expect_yes "-o" commit -o -m msg
_parser_expect_yes "--pathspec-from-file=FILE" commit -m msg --pathspec-from-file=pathlist.txt
_parser_expect_yes "--pathspec-from-file FILE" commit -m msg --pathspec-from-file pathlist.txt
_parser_expect_yes "--pathspec-from-file + --pathspec-file-nul" \
  commit -m msg --pathspec-from-file=pathlist.txt --pathspec-file-nul
_parser_expect_no "ordinary -m only" commit -m msg
_parser_expect_no "--pathspec-file-nul alone" commit -m msg --pathspec-file-nul
# -s (signoff) has none of a/i/o/p; use separate -m so msg is not a bare pathspec
_parser_expect_no "signoff -s -m (no worktree flags)" commit -s -m msg
# Attached-value -mabc: payload contains a/i/o/p letters but is NOT a combined flag.
_parser_expect_no "attached -mabc (value not flags)" commit -mabc
_parser_expect_no "attached -m with a/i/o/p in payload" commit -mpatchmsg
# Real separate/equals value grammar (not worktree-including).
_parser_expect_no "--trailer separate" commit -m msg --trailer "Bug: 1"
_parser_expect_no "--trailer=equals" commit -m msg --trailer="Bug: 1"
_parser_expect_no "--fixup separate" commit --fixup HEAD
_parser_expect_no "--fixup=equals" commit --fixup=HEAD
_parser_expect_no "--squash separate" commit --squash HEAD
_parser_expect_no "--squash=equals" commit --squash=HEAD
# -sm msg: s boolean + m value in next argv (skip_next), not worktree.
_parser_expect_no "combined -sm with separate message" commit -sm msg
# Optional attached-value shorts: payload may contain a/i/o/p but is not flags.
_parser_expect_no "attached -Ssigning-key (value not flags)" commit -Ssigning-key -m msg
_parser_expect_no "attached -uno (value not flags)" commit -uno -m msg
_parser_expect_no "attached -Sa (S payload a not flag)" commit -Sa -m msg
# Actual worktree flags and combined forms still fail closed.
_parser_expect_yes "plain -a still worktree" commit -a -m msg
_parser_expect_yes "combined -am still worktree" commit -am msg
fi

# --- e2e: non-interactive pathspec-from-file protected worktree bypass ------
# Must not hang (no editor / patch UI). Dirty protected tracked path + equals
# form forces fail-closed before real git runs.
printf 'dirty protected for pathspec-from-file\n' > "$ROOT/.agents/gate.json"
printf '%s\n' '.agents/gate.json' > "$ROOT/pathlist.txt"
run_guard commit -m 'bypass via pathspec-from-file' \
  --pathspec-from-file=pathlist.txt >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "commit --pathspec-from-file with dirty protected path rejected (exit $rc)"
else
  bad "commit --pathspec-from-file bypass (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
# Separate-value form (non-interactive) + --pathspec-file-nul must also fail closed.
printf 'dirty protected for pathspec-from-file sep\n' > "$ROOT/.agents/gate.json"
run_guard commit -m 'bypass via pathspec-from-file sep' \
  --pathspec-from-file pathlist.txt --pathspec-file-nul \
  >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "commit --pathspec-from-file FILE --pathspec-file-nul rejected (exit $rc)"
else
  bad "commit --pathspec-from-file sep+nul bypass (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
# Non-interactive -p form: classifier + unstaged scan must exit 86 before git
# opens the patch selector (would hang waiting for TTY input).
printf 'dirty protected for -p\n' > "$ROOT/.agents/gate.json"
run_guard commit -p -m 'bypass via -p' >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "commit -p with dirty protected path rejected without hang (exit $rc)"
else
  bad "commit -p bypass (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
rm -f "$ROOT/pathlist.txt"
git -C "$ROOT" checkout -q HEAD -- .agents/gate.json 2>/dev/null || true
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

# --- unmatched pathspec: real nonzero status propagates --------------------
# Failed real `git add` must still surface the real status (not 86, not 0).
# After the control-flow repair, the scan always runs; with nothing protected
# staged the real nonzero status propagates.
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

# --- diff.relative=true: subdir staged + unstaged scans see root paths ------
# Repo config that hides out-of-subdir changes must not let protected paths
# evade detection. Sensors run the guard from a nested cwd.
git -C "$ROOT" config diff.relative true
mkdir -p "$ROOT/work/rel-sub"
printf 'forbidden-rel-staged\n' > "$ROOT/.agents/gate.json"
run_guard_in "$ROOT/work/rel-sub" "$ROOT" add ../../.agents/gate.json \
  >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "diff.relative=true subdir staged protected add rejected (exit $rc)"
else
  bad "diff.relative=true subdir staged (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
staged=$(git -C "$ROOT" diff --cached --name-only)
if [[ -z "$staged" ]]; then
  ok "diff.relative=true subdir staged protected rolled back"
else
  bad "diff.relative=true subdir staged rollback (still staged: $staged)"
fi
rm -f "$ROOT/.agents/gate.json"
git -C "$ROOT" reset -q 2>/dev/null || true
# Unstaged: tracked protected dirty outside cwd; worktree-including commit
# form must still fail closed with root-relative scan.
printf 'seed-rel\n' > "$ROOT/.agents/gate.json"
git -C "$ROOT" add .agents/gate.json
git -C "$ROOT" commit -qm 'seed for diff.relative unstaged'
printf 'dirty-rel-unstaged\n' > "$ROOT/.agents/gate.json"
printf 'rel-readme\n' > "$ROOT/README.md"
run_guard_in "$ROOT/work/rel-sub" "$ROOT" add ../../README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "diff.relative=true stage README before unstaged probe (rc=$rc)"
else
  run_guard_in "$ROOT/work/rel-sub" "$ROOT" commit -am 'rel unstaged probe' \
    >/dev/null 2>"$ROOT/err"
  rc=$?
  if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
    ok "diff.relative=true subdir unstaged protected -am rejected (exit $rc)"
  else
    bad "diff.relative=true subdir unstaged (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
  fi
fi
git -C "$ROOT" checkout -q HEAD -- .agents/gate.json README.md 2>/dev/null || true
git -C "$ROOT" reset -q 2>/dev/null || true
# Restore default relative config for later sensors.
git -C "$ROOT" config --unset diff.relative 2>/dev/null || true

# --- safe-control metadata: not rejected with dirty unstaged protected ------
# Deterministic non-TTY forms: attached -mabc, --trailer, --fixup.
# Dirty protected path must NOT cause exit 86 for ordinary metadata-only commits.
printf 'seed-safe-meta\n' > "$ROOT/.agents/gate.json"
git -C "$ROOT" add .agents/gate.json
git -C "$ROOT" commit -qm 'seed safe-meta control-plane'
printf 'dirty protected for safe-meta\n' > "$ROOT/.agents/gate.json"
printf 'safe-meta body\n' > "$ROOT/README.md"
run_guard add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "stage README for safe-meta sensors (rc=$rc)"
else
  # Attached message value containing a/i/o/p letters.
  run_guard commit -mabc >/dev/null 2>"$ROOT/err"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "safe-control commit -mabc with dirty protected succeeds"
  else
    bad "safe-control -mabc false positive (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
  fi
fi
# Re-stage README + dirty protected for trailer (prior commit consumed README).
printf 'dirty protected for trailer\n' > "$ROOT/.agents/gate.json"
printf 'trailer body\n' > "$ROOT/README.md"
run_guard add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "stage README for --trailer sensor (rc=$rc)"
else
  run_guard commit -m 'safe trailer commit' --trailer 'Reviewed-by: sensor <s@gibson.invalid>' \
    >/dev/null 2>"$ROOT/err"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "safe-control commit --trailer with dirty protected succeeds"
  else
    bad "safe-control --trailer false positive (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
  fi
fi
# --fixup HEAD: non-interactive; creates a fixup commit we immediately drop.
printf 'dirty protected for fixup\n' > "$ROOT/.agents/gate.json"
printf 'fixup body\n' > "$ROOT/README.md"
run_guard add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "stage README for --fixup sensor (rc=$rc)"
else
  pre_fixup=$(git -C "$ROOT" rev-parse HEAD)
  run_guard commit --fixup HEAD >/dev/null 2>"$ROOT/err"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "safe-control commit --fixup HEAD with dirty protected succeeds"
  else
    bad "safe-control --fixup false positive (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
  fi
  # Drop the fixup commit; keep tree clean for later sensors.
  git -C "$ROOT" reset -q --hard "$pre_fixup" 2>/dev/null || true
fi
# -uno: optional attached-value short; no external signing config required.
# Dirty protected path must NOT cause exit 86 (payload letters are not flags).
printf 'dirty protected for -uno\n' > "$ROOT/.agents/gate.json"
printf 'uno body\n' > "$ROOT/README.md"
run_guard add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "stage README for -uno safe-control sensor (rc=$rc)"
else
  run_guard commit -uno -m 'safe uno commit' >/dev/null 2>"$ROOT/err"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "safe-control commit -uno with dirty protected succeeds"
  else
    bad "safe-control -uno false positive (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
  fi
fi
git -C "$ROOT" checkout -q HEAD -- .agents/gate.json README.md 2>/dev/null || true
git -C "$ROOT" reset -q 2>/dev/null || true

# --- partial-nonzero add: always scan + selective rollback (fake git shim) ---
# Portable real-git partial add (stage some, fail) is not reliable across git
# versions (unmatched pathspec stages nothing). Sensor the control-flow with an
# owned shim that stages a protected path then returns nonzero; guard must still
# scan, roll back the protected entry, and exit 86 (not propagate the shim rc).
printf 'partial-shim-protected\n' > "$ROOT/.agents/gate.json"
printf 'partial-shim-legit\n' > "$ROOT/README.md"
run_guard add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "stage README before partial-nonzero shim (rc=$rc)"
  legit_blob_partial=""
else
  legit_blob_partial=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
fi
REAL_GIT_BIN=$(command -v git)
FAKE_GIT="$ROOT/fake-git-partial-add.sh"
cat > "$FAKE_GIT" <<EOF
#!/usr/bin/env bash
# Passthrough except add: stage protected via real git, then fail nonzero.
if [[ "\${1-}" == "add" ]]; then
  "$REAL_GIT_BIN" -C "$ROOT" add -- .agents/gate.json
  exit 1
fi
exec "$REAL_GIT_BIN" "\$@"
EOF
chmod +x "$FAKE_GIT"
# Invoke guard with shim as REAL_GIT; cwd/target still the fixture root.
(cd "$ROOT" &&
  GIBSON_REAL_GIT="$FAKE_GIT" \
  GIBSON_TARGET_REPO="$ROOT" \
  GIBSON_EXPECTED_REPO_SLUG="acme/app" \
  "$GUARD" add .agents/gate.json) >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "partial-nonzero add still scans and exits 86 (not shim rc)"
else
  bad "partial-nonzero add control-flow (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
still_protected=$(git -C "$ROOT" diff --cached --name-only | grep -E '^\.agents/gate\.json$' || true)
if [[ -z "$still_protected" ]]; then
  ok "partial-nonzero: protected path rolled back after failed add"
else
  bad "partial-nonzero: protected still staged: $still_protected"
fi
after_blob=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
staged_names=$(git -C "$ROOT" diff --cached --name-only)
if [[ -n "$legit_blob_partial" && "$after_blob" == "$legit_blob_partial" && "$staged_names" == "README.md" ]]; then
  ok "partial-nonzero: legitimate README remains staged after rollback"
else
  bad "partial-nonzero: README survival (blob before=$legit_blob_partial after=$after_blob staged=$(echo "$staged_names" | tr '\n' ' '))"
fi
rm -f "$FAKE_GIT" "$ROOT/.agents/gate.json"
git -C "$ROOT" reset -q 2>/dev/null || true
git -C "$ROOT" checkout -q -- README.md 2>/dev/null || true

# --- protected filename with glob chars: literal pathspec rollback ----------
# Protected names matching `.agents/gate.*` that contain pathspec magic:
#   .agents/gate.*.json  (literal asterisk)
#   .agents/gate.[x].json (brackets)
# Without :(literal), reset of '.agents/gate.*.json' also unstages the bracket
# name (* matches [x]). Helper must unstage only the listed offender.
STAR_NAME='.agents/gate.*.json'
BRACKET_NAME='.agents/gate.[x].json'
printf 'star-protected\n' > "$ROOT/.agents/gate."$'*''.json'
printf 'bracket-protected\n' > "$ROOT/.agents/gate.[x].json"
printf 'legit-star\n' > "$ROOT/README.md"
run_guard add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "stage README before wildcard-name add (rc=$rc)"
  star_legit_blob=""
else
  star_legit_blob=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
fi
# Stage both magic-named protected files with real git (literal pathspecs).
git -C "$ROOT" add -- ":(literal)$STAR_NAME" ":(literal)$BRACKET_NAME"
# Extract rollback helper; env matches guard runtime (REAL_GIT + current_root).
# Both are read inside the eval'd function body (shellcheck cannot see that).
# shellcheck disable=SC2034
REAL_GIT=$(command -v git)
# shellcheck disable=SC2034
current_root="$ROOT_PHYS"
_protected_staged=("$STAR_NAME")
# Repository-owned source only; assert the function is defined after eval so an
# empty extraction cannot leave prior suite state or skip the selectivity probe.
eval "$(sed -n '/^rollback_protected_staged()/,/^}/p' "$GUARD")"
if ! declare -f rollback_protected_staged >/dev/null 2>&1; then
  bad "literal rollback: could not extract rollback_protected_staged from $GUARD"
else
  rollback_protected_staged
  still_star=$(git -C "$ROOT" diff --cached --name-only | grep -F "$STAR_NAME" || true)
  still_bracket=$(git -C "$ROOT" diff --cached --name-only | grep -F "$BRACKET_NAME" || true)
  if [[ -z "$still_star" && -n "$still_bracket" ]]; then
    ok "literal rollback unstages only star-named protected path"
  else
    bad "literal rollback selectivity (star='$still_star' bracket='$still_bracket' staged=$(git -C "$ROOT" diff --cached --name-only | tr '\n' ' '))"
  fi
fi
# Full guarded add of star-named path alone: reject + unstage that path.
git -C "$ROOT" reset -q 2>/dev/null || true
run_guard add README.md >/dev/null 2>"$ROOT/err"
run_guard add -- ":(literal)$STAR_NAME" >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane" "$ROOT/err"; then
  ok "guarded add of star-named protected path rejected (exit $rc)"
else
  bad "star-named protected add (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
still_star=$(git -C "$ROOT" diff --cached --name-only | grep -F "$STAR_NAME" || true)
after_blob=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
if [[ -z "$still_star" && -n "$star_legit_blob" && "$after_blob" == "$star_legit_blob" ]]; then
  ok "star-named add: protected unstaged, README blob preserved"
else
  bad "star-named add rollback (star='$still_star' blob before=$star_legit_blob after=$after_blob)"
fi
rm -f "$ROOT/.agents/gate."$'*''.json' "$ROOT/.agents/gate.[x].json"
git -C "$ROOT" reset -q 2>/dev/null || true
git -C "$ROOT" checkout -q -- README.md 2>/dev/null || true

# --- enumeration failure fail-closed: staged + unstaged fake-git sensors ----
# Process substitution used to drop `git diff` status, so a failed enumeration
# looked like a clean index/worktree. Owned shims prove commit/push/add exit 86
# with a bounded diagnostic and never delegate the protected op (except add,
# which always runs real add first then fails closed on the post-add scan).
REAL_GIT_BIN=$(command -v git)
DELEGATE_LOG="$ROOT/fake-git-delegated.log"

# Helper: fail only the staged name-only enumeration the guard issues.
write_fake_git_staged_diff_fail() {
  local dest="$1"
  cat > "$dest" <<EOF
#!/usr/bin/env bash
# Fail staged path enumeration; log any delegated add/commit/push.
_is_staged_enum=0
_has_cached=0
_has_name_only=0
for _a in "\$@"; do
  case "\$_a" in
    --cached) _has_cached=1 ;;
    --name-only) _has_name_only=1 ;;
  esac
done
if [[ "\$_has_cached" -eq 1 && "\$_has_name_only" -eq 1 ]]; then
  echo "fake-git: staged enumeration forced failure" >&2
  exit 17
fi
case "\${1-}" in
  add|commit|push)
    printf '%s\n' "\$*" >> "$DELEGATE_LOG"
    ;;
esac
exec "$REAL_GIT_BIN" "\$@"
EOF
  chmod +x "$dest"
}

# Helper: fail only the unstaged name-only enumeration (no --cached).
write_fake_git_unstaged_diff_fail() {
  local dest="$1"
  cat > "$dest" <<EOF
#!/usr/bin/env bash
_has_cached=0
_has_name_only=0
for _a in "\$@"; do
  case "\$_a" in
    --cached) _has_cached=1 ;;
    --name-only) _has_name_only=1 ;;
  esac
done
if [[ "\$_has_cached" -eq 0 && "\$_has_name_only" -eq 1 ]]; then
  echo "fake-git: unstaged enumeration forced failure" >&2
  exit 19
fi
case "\${1-}" in
  add|commit|push)
    printf '%s\n' "\$*" >> "$DELEGATE_LOG"
    ;;
esac
exec "$REAL_GIT_BIN" "\$@"
EOF
  chmod +x "$dest"
}

run_guard_with_fake() {
  local fake="$1"
  shift
  rm -f "$DELEGATE_LOG"
  (cd "$ROOT" &&
    GIBSON_REAL_GIT="$fake" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" "$@")
}

# Staged enum fail → commit: exit 86, diagnostic, no real commit delegated.
FAKE_STAGED="$ROOT/fake-git-staged-diff-fail.sh"
write_fake_git_staged_diff_fail "$FAKE_STAGED"
run_guard_with_fake "$FAKE_STAGED" commit -m 'enum fail commit' \
  >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "failed to enumerate staged paths" "$ROOT/err"; then
  ok "staged enum failure: commit exits 86 with diagnostic"
else
  bad "staged enum failure commit (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
if [[ ! -f "$DELEGATE_LOG" ]] || ! grep -q '^commit' "$DELEGATE_LOG" 2>/dev/null; then
  ok "staged enum failure: commit not delegated to real git"
else
  bad "staged enum failure: commit was delegated ($(tr '\n' ' ' <"$DELEGATE_LOG"))"
fi

# Staged enum fail → push: exit 86, no real push.
run_guard_with_fake "$FAKE_STAGED" push origin main \
  >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "failed to enumerate staged paths" "$ROOT/err"; then
  ok "staged enum failure: push exits 86 with diagnostic"
else
  bad "staged enum failure push (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
if [[ ! -f "$DELEGATE_LOG" ]] || ! grep -q '^push' "$DELEGATE_LOG" 2>/dev/null; then
  ok "staged enum failure: push not delegated to real git"
else
  bad "staged enum failure: push was delegated ($(tr '\n' ' ' <"$DELEGATE_LOG"))"
fi

# Staged enum fail → add: real add may run first; post-add scan fails closed 86.
printf 'enum-fail-add-body\n' > "$ROOT/README.md"
run_guard_with_fake "$FAKE_STAGED" add README.md \
  >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "failed to enumerate staged paths" "$ROOT/err"; then
  ok "staged enum failure: add exits 86 with diagnostic (fail closed)"
else
  bad "staged enum failure add (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
# Cleanup any staged README from the pre-scan add.
git -C "$ROOT" reset -q 2>/dev/null || true
git -C "$ROOT" checkout -q -- README.md 2>/dev/null || true

# Unstaged enum fail → worktree-including commit form: exit 86, no real commit.
# Staged scan must succeed (passthrough); only unstaged name-only fails.
FAKE_UNSTAGED="$ROOT/fake-git-unstaged-diff-fail.sh"
write_fake_git_unstaged_diff_fail "$FAKE_UNSTAGED"
printf 'seed-unstaged-enum\n' > "$ROOT/.agents/gate.json"
git -C "$ROOT" add .agents/gate.json
git -C "$ROOT" commit -qm 'seed for unstaged enum fail'
printf 'dirty for unstaged enum fail\n' > "$ROOT/.agents/gate.json"
printf 'unstaged-enum-readme\n' > "$ROOT/README.md"
git -C "$ROOT" add README.md
run_guard_with_fake "$FAKE_UNSTAGED" commit -am 'enum fail -am' \
  >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "failed to enumerate unstaged paths" "$ROOT/err"; then
  ok "unstaged enum failure: commit -am exits 86 with diagnostic"
else
  bad "unstaged enum failure commit -am (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
if [[ ! -f "$DELEGATE_LOG" ]] || ! grep -q '^commit' "$DELEGATE_LOG" 2>/dev/null; then
  ok "unstaged enum failure: commit -am not delegated to real git"
else
  bad "unstaged enum failure: commit was delegated ($(tr '\n' ' ' <"$DELEGATE_LOG"))"
fi
rm -f "$FAKE_STAGED" "$FAKE_UNSTAGED" "$DELEGATE_LOG"
git -C "$ROOT" checkout -q HEAD -- .agents/gate.json README.md 2>/dev/null || true
git -C "$ROOT" reset -q 2>/dev/null || true

# --- unborn HEAD: real-git selective rollback of protected add --------------
# Repository with zero commits (unborn HEAD). Protected add must exit 86,
# unstage the offender (reset and/or index-only fallback), leave legitimate
# staged work, and not wipe working-tree content of the protected path.
UNBORN=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard-unborn.XXXXXX")
trap 'rm -rf "$ROOT" "$ALIAS_DIR" "$OTHER" "$UNBORN"' EXIT
git -C "$UNBORN" init -q -b main
git -C "$UNBORN" config user.email test@gibson.invalid
git -C "$UNBORN" config user.name gibson-test
mkdir -p "$UNBORN/.agents"
printf 'unborn-legit\n' > "$UNBORN/README.md"
printf 'unborn-forbidden\n' > "$UNBORN/.agents/gate.json"
# Stage legitimate path first (no prior HEAD/commit required for add).
run_guard_in "$UNBORN" "$UNBORN" add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "unborn HEAD: legitimate README add (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
  unborn_legit_blob=""
else
  unborn_legit_blob=$(git -C "$UNBORN" rev-parse :README.md 2>/dev/null || true)
  if [[ -n "$unborn_legit_blob" ]]; then
    ok "unborn HEAD: legitimate README staged before protected add"
  else
    bad "unborn HEAD: legitimate README staged before protected add (no index blob)"
  fi
fi
run_guard_in "$UNBORN" "$UNBORN" add .agents/gate.json >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane file '.agents/gate.json'" "$ROOT/err"; then
  ok "unborn HEAD: protected add rejected with diagnostic (exit $rc)"
else
  bad "unborn HEAD: protected add (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
still_protected=$(git -C "$UNBORN" diff --cached --name-only | grep -E '^\.agents/gate\.json$' || true)
if [[ -z "$still_protected" ]]; then
  ok "unborn HEAD: protected path unstaged after rollback"
else
  bad "unborn HEAD: protected still staged: $still_protected"
fi
after_blob=$(git -C "$UNBORN" rev-parse :README.md 2>/dev/null || true)
staged_names=$(git -C "$UNBORN" diff --cached --name-only)
if [[ -n "$unborn_legit_blob" && "$after_blob" == "$unborn_legit_blob" && "$staged_names" == "README.md" ]]; then
  ok "unborn HEAD: legitimate README remains staged byte-for-byte"
else
  bad "unborn HEAD: README survival (blob before=$unborn_legit_blob after=$after_blob staged=$(echo "$staged_names" | tr '\n' ' '))"
fi
# Working-tree content of the protected path must still exist (index-only ops).
if [[ -f "$UNBORN/.agents/gate.json" ]] && grep -q 'unborn-forbidden' "$UNBORN/.agents/gate.json"; then
  ok "unborn HEAD: protected working-tree content left intact"
else
  bad "unborn HEAD: protected working-tree content missing or altered"
fi

# --- fake-git: reset+fallback fail on first offender; later still attempted --
# Deterministic shim: first protected path's reset and rm --cached both fail;
# second path's reset succeeds via real git. Guarded add must still exit 86,
# attempt both offenders, leave the second unstaged, preserve legitimate README,
# and emit a bounded "could not unstage" diagnostic for the first path only.
printf 'rollback-fail-legit\n' > "$ROOT/README.md"
run_guard add README.md >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -ne 0 ]]; then
  bad "stage README before rollback-fail shim (rc=$rc)"
  rb_legit_blob=""
else
  rb_legit_blob=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
fi
printf 'rollback-fail-a\n' > "$ROOT/.agents/gate.json"
printf 'rollback-fail-b\n' > "$ROOT/.gibson-gate.json"
REAL_GIT_BIN=$(command -v git)
RB_ATTEMPT_LOG="$ROOT/fake-git-rollback-attempts.log"
FAKE_RB="$ROOT/fake-git-rollback-fail.sh"
rm -f "$RB_ATTEMPT_LOG"
cat > "$FAKE_RB" <<EOF
#!/usr/bin/env bash
# Passthrough except: on add stage both protected paths via real git; on
# reset/rm of .agents/gate.json force failure; log reset/rm attempts.
# Skip leading -C <dir> to find the subcommand (guard always uses -C).
_args=("\$@")
_sub=""
_i=0
while [[ "\$_i" -lt \${#_args[@]} ]]; do
  if [[ "\${_args[\$_i]}" == "-C" ]]; then
    _i=\$((_i + 2))
    continue
  fi
  _sub="\${_args[\$_i]}"
  break
done
if [[ "\$_sub" == "add" ]]; then
  "$REAL_GIT_BIN" -C "$ROOT" add -- .agents/gate.json .gibson-gate.json
  exit 0
fi
if [[ "\$_sub" == "reset" || "\$_sub" == "rm" ]]; then
  _target=""
  for _a in "\${_args[@]}"; do
    # Exact literal pathspecs from rollback_protected_staged.
    if [[ "\$_a" == ":(literal).agents/gate.json" || "\$_a" == ".agents/gate.json" ]]; then
      _target="gate.json"
    elif [[ "\$_a" == ":(literal).gibson-gate.json" || "\$_a" == ".gibson-gate.json" ]]; then
      _target="gibson-gate.json"
    fi
  done
  if [[ -n "\$_target" ]]; then
    printf '%s %s\n' "\$_sub" "\$_target" >> "$RB_ATTEMPT_LOG"
  fi
  if [[ "\$_target" == "gate.json" ]]; then
    # Force failure for the first offender (reset and fallback both fail).
    exit 128
  fi
  exec "$REAL_GIT_BIN" "\$@"
fi
exec "$REAL_GIT_BIN" "\$@"
EOF
chmod +x "$FAKE_RB"
(cd "$ROOT" &&
  GIBSON_REAL_GIT="$FAKE_RB" \
  GIBSON_TARGET_REPO="$ROOT" \
  GIBSON_EXPECTED_REPO_SLUG="acme/app" \
  "$GUARD" add .agents/gate.json .gibson-gate.json) >/dev/null 2>"$ROOT/err"
rc=$?
err_txt=$(tr '\n' ' ' <"$ROOT/err")
if [[ "$rc" -eq 86 ]] &&
   grep -q "control-plane file '.agents/gate.json'" "$ROOT/err" &&
   grep -q "control-plane file '.gibson-gate.json'" "$ROOT/err"; then
  ok "rollback-fail shim: guarded add exits 86 with per-path diagnostics"
else
  bad "rollback-fail shim: exit/diagnostics (rc=$rc err=$err_txt)"
fi
if grep -q "could not unstage '.agents/gate.json'" "$ROOT/err"; then
  ok "rollback-fail shim: bounded could-not-unstage diagnostic for first offender"
else
  bad "rollback-fail shim: missing could-not-unstage diagnostic (err=$err_txt)"
fi
# Attempt log: both reset (and fallback rm) for gate.json, plus later gibson path.
if grep -q '^reset gate.json$' "$RB_ATTEMPT_LOG" 2>/dev/null &&
   grep -q '^rm gate.json$' "$RB_ATTEMPT_LOG" 2>/dev/null &&
   grep -qE '^(reset|rm) gibson-gate.json$' "$RB_ATTEMPT_LOG" 2>/dev/null; then
  ok "rollback-fail shim: later offender attempted after first reset/fallback failure"
else
  bad "rollback-fail shim: attempt order (log=$(tr '\n' ' ' <"$RB_ATTEMPT_LOG" 2>/dev/null))"
fi
still_first=$(git -C "$ROOT" diff --cached --name-only | grep -E '^\.agents/gate\.json$' || true)
still_second=$(git -C "$ROOT" diff --cached --name-only | grep -E '^\.gibson-gate\.json$' || true)
if [[ -n "$still_first" && -z "$still_second" ]]; then
  ok "rollback-fail shim: first remains staged, second unstaged"
else
  bad "rollback-fail shim: staged state first='$still_first' second='$still_second' all=$(git -C "$ROOT" diff --cached --name-only | tr '\n' ' ')"
fi
after_blob=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
# README must remain staged; first protected may still be staged alongside it.
if [[ -n "$rb_legit_blob" && "$after_blob" == "$rb_legit_blob" ]] &&
   git -C "$ROOT" diff --cached --name-only | grep -x 'README.md' >/dev/null; then
  ok "rollback-fail shim: legitimate README remains staged byte-for-byte"
else
  bad "rollback-fail shim: README survival (blob before=$rb_legit_blob after=$after_blob staged=$(git -C "$ROOT" diff --cached --name-only | tr '\n' ' '))"
fi
# Working tree of both protected paths intact (no worktree wipe on failure path).
if [[ -f "$ROOT/.agents/gate.json" && -f "$ROOT/.gibson-gate.json" ]]; then
  ok "rollback-fail shim: protected working-tree files left intact"
else
  bad "rollback-fail shim: protected working-tree files missing"
fi
rm -f "$FAKE_RB" "$RB_ATTEMPT_LOG" "$ROOT/.agents/gate.json" "$ROOT/.gibson-gate.json"
git -C "$ROOT" reset -q 2>/dev/null || true
git -C "$ROOT" checkout -q -- README.md 2>/dev/null || true

# --- linked worktree of the target is inside the boundary (#620) ------------
# `git rev-parse --show-toplevel` in a linked worktree is that worktree, not
# the main checkout. Same --git-common-dir means the same repository. A
# worktree of a different repository stays outside. Control-plane staging
# still exits 86 after the boundary check passes.
WT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard-wt.XXXXXX")
OTHER_WT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard-other-wt.XXXXXX")
trap 'rm -rf "$ROOT" "$ALIAS_DIR" "$OTHER" "$UNBORN" "$WT" "$OTHER_WT"' EXIT
rmdir "$WT" "$OTHER_WT"
git -C "$ROOT" worktree add -q "$WT" -b guard-wt
git -C "$OTHER" worktree add -q "$OTHER_WT" -b guard-other-wt

run_guard_in "$WT" "$ROOT" status >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "linked worktree status is inside the target boundary (exit $rc)"
else
  bad "linked worktree status (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

mkdir -p "$WT/.agents"
printf 'forbidden-wt\n' > "$WT/.agents/gate.json"
run_guard_in "$WT" "$ROOT" add .agents/gate.json >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "control-plane" "$ROOT/err"; then
  ok "linked worktree control-plane add still rejected (exit $rc)"
else
  bad "linked worktree control-plane add (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
staged=$(git -C "$WT" diff --cached --name-only)
if [[ -z "$staged" ]]; then
  ok "linked worktree control-plane staging rolled back"
else
  bad "linked worktree control-plane staging rolled back (still staged: $staged)"
fi

run_guard_in "$OTHER_WT" "$ROOT" status >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "outside target repo" "$ROOT/err"; then
  ok "worktree of a different repo rejected (exit $rc)"
else
  bad "worktree of a different repo (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

# Ambient GIT_COMMON_DIR must not turn a foreign worktree into the target.
(
  cd "$OTHER_WT" &&
    GIT_COMMON_DIR="$ROOT_PHYS/.git" \
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" status
) >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "outside target repo" "$ROOT/err"; then
  ok "foreign worktree with spoofed GIT_COMMON_DIR rejected (exit $rc)"
else
  bad "foreign worktree with spoofed GIT_COMMON_DIR (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

# Foreign GIT_DIR must not retarget add/commit onto another repository.
# From a linked worktree of the target (inside the boundary) and from the
# main checkout, the override is refused with 86 before any mutating git.
# Clearing the variables alone would retarget the add onto this checkout
# (exit 0). The other repo's index and HEAD stay unchanged.
VICTIM=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard-victim.XXXXXX")
trap 'rm -rf "$ROOT" "$ALIAS_DIR" "$OTHER" "$UNBORN" "$WT" "$OTHER_WT" "$VICTIM"' EXIT
git -C "$VICTIM" init -q -b main
git -C "$VICTIM" config user.email test@gibson.invalid
git -C "$VICTIM" config user.name gibson-test
printf 'victim\n' > "$VICTIM/README.md"
git -C "$VICTIM" add README.md
git -C "$VICTIM" commit -qm victim-base
printf 'escaped\n' > "$WT/ESCAPED.txt"
victim_head=$(git -C "$VICTIM" rev-parse HEAD)
victim_index=$(git -C "$VICTIM" ls-files -s)
wt_head=$(git -C "$WT" rev-parse HEAD)
wt_index=$(git -C "$WT" ls-files -s)

wt_git_dir=$(git -C "$WT" rev-parse --absolute-git-dir)
(
  cd "$WT" &&
    GIT_DIR="$wt_git_dir" \
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" status
) >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "linked worktree with same-repo GIT_DIR still inside the boundary (exit $rc)"
else
  bad "linked worktree with same-repo GIT_DIR (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

(
  cd "$WT" &&
    GIT_DIR="$VICTIM/.git" \
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" add ESCAPED.txt
) >/dev/null 2>"$ROOT/err"
rc=$?
victim_head_after=$(git -C "$VICTIM" rev-parse HEAD)
victim_index_after=$(git -C "$VICTIM" ls-files -s)
wt_head_after=$(git -C "$WT" rev-parse HEAD)
wt_index_after=$(git -C "$WT" ls-files -s)
if [[ "$rc" -eq 86 && "$victim_head_after" == "$victim_head" && "$victim_index_after" == "$victim_index" && "$wt_head_after" == "$wt_head" && "$wt_index_after" == "$wt_index" ]] &&
   grep -q "GIT_DIR names a different repository" "$ROOT/err"; then
  ok "linked worktree with foreign GIT_DIR: add exits 86 and the other repo is unchanged"
else
  bad "linked worktree with foreign GIT_DIR add (rc=$rc victim_head $victim_head->$victim_head_after wt_head $wt_head->$wt_head_after err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

(
  cd "$WT" &&
    GIT_DIR="$VICTIM/.git" \
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" rev-parse HEAD
) >"$ROOT/out" 2>"$ROOT/err"
rc=$?
printed=$(tr -d '[:space:]' <"$ROOT/out")
victim_head_after=$(git -C "$VICTIM" rev-parse HEAD)
victim_index_after=$(git -C "$VICTIM" ls-files -s)
if [[ "$rc" -eq 86 && "$printed" != "$victim_head" && "$victim_head_after" == "$victim_head" && "$victim_index_after" == "$victim_index" ]] &&
   grep -q "GIT_DIR names a different repository" "$ROOT/err"; then
  ok "linked worktree with foreign GIT_DIR: rev-parse exits 86 and does not print the other HEAD"
else
  bad "linked worktree with foreign GIT_DIR rev-parse (rc=$rc printed=$printed err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

(
  cd "$WT" &&
    GIT_DIR="$VICTIM/.git" \
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" commit --allow-empty -m escaped
) >/dev/null 2>"$ROOT/err"
rc=$?
victim_head_after=$(git -C "$VICTIM" rev-parse HEAD)
victim_index_after=$(git -C "$VICTIM" ls-files -s)
wt_head_after=$(git -C "$WT" rev-parse HEAD)
if [[ "$rc" -eq 86 && "$victim_head_after" == "$victim_head" && "$victim_index_after" == "$victim_index" && "$wt_head_after" == "$wt_head" ]] &&
   grep -q "GIT_DIR names a different repository" "$ROOT/err"; then
  ok "linked worktree with foreign GIT_DIR: commit exits 86 and the other HEAD stays"
else
  bad "linked worktree with foreign GIT_DIR commit (rc=$rc victim_head $victim_head->$victim_head_after err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

root_head=$(git -C "$ROOT" rev-parse HEAD)
root_index=$(git -C "$ROOT" ls-files -s)
(
  cd "$ROOT" &&
    GIT_DIR="$VICTIM/.git" \
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" add README.md
) >/dev/null 2>"$ROOT/err"
rc=$?
victim_head_after=$(git -C "$VICTIM" rev-parse HEAD)
victim_index_after=$(git -C "$VICTIM" ls-files -s)
root_head_after=$(git -C "$ROOT" rev-parse HEAD)
root_index_after=$(git -C "$ROOT" ls-files -s)
if [[ "$rc" -eq 86 && "$victim_head_after" == "$victim_head" && "$victim_index_after" == "$victim_index" && "$root_head_after" == "$root_head" && "$root_index_after" == "$root_index" ]] &&
   grep -q "GIT_DIR names a different repository" "$ROOT/err"; then
  ok "main checkout with foreign GIT_DIR: add exits 86 and the other repo is unchanged"
else
  bad "main checkout with foreign GIT_DIR add (rc=$rc victim_head $victim_head->$victim_head_after err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

# --- leading global options must not skip add/commit guards (#627) ----------
# Dispatch used to read only $1. From inside the target, `git -C <other> add`
# staged into that repository, and `git -C <target> add .agents/gate.json`
# staged the control-plane file. Both returned 0. Commit with a leading -C
# likewise skipped the staged-file check. Every leading global option now
# exits 86 before real git. Subcommand-first commands stay allowed.

capture_guard_state() {
  G_ROOT_HEAD=$(git -C "$ROOT" rev-parse HEAD)
  G_ROOT_INDEX=$(git -C "$ROOT" ls-files -s)
  G_OTHER_HEAD=$(git -C "$OTHER" rev-parse HEAD)
  G_OTHER_INDEX=$(git -C "$OTHER" ls-files -s)
  G_WT_HEAD=$(git -C "$WT" rev-parse HEAD)
  G_WT_INDEX=$(git -C "$WT" ls-files -s)
}

restore_guard_state() {
  git -C "$ROOT" reset -q "$G_ROOT_HEAD" 2>/dev/null || true
  git -C "$OTHER" reset -q "$G_OTHER_HEAD" 2>/dev/null || true
  git -C "$WT" reset -q "$G_WT_HEAD" 2>/dev/null || true
  capture_guard_state
}

# label, cwd, then the guard arguments. Assert exit 86, empty stdout, and
# unchanged HEAD plus index in the target, the other repo, and the worktree.
reject_leading_global() {
  local label="$1" cwd="$2" rc rh ri oh oi wh wi
  shift 2
  run_guard_in "$cwd" "$ROOT" "$@" >"$ROOT/out" 2>"$ROOT/err"
  rc=$?
  rh=$(git -C "$ROOT" rev-parse HEAD)
  ri=$(git -C "$ROOT" ls-files -s)
  oh=$(git -C "$OTHER" rev-parse HEAD)
  oi=$(git -C "$OTHER" ls-files -s)
  wh=$(git -C "$WT" rev-parse HEAD)
  wi=$(git -C "$WT" ls-files -s)
  idx_note=""
  [[ "$ri" == "$G_ROOT_INDEX" ]] || idx_note="${idx_note} root-index"
  [[ "$oi" == "$G_OTHER_INDEX" ]] || idx_note="${idx_note} other-index"
  [[ "$wi" == "$G_WT_INDEX" ]] || idx_note="${idx_note} wt-index"
  if [[ -s "$ROOT/out" ]]; then
    REJECT_CLEAN=0
    bad "$label produced stdout ($(tr '\n' ' ' <"$ROOT/out"))"
    restore_guard_state
    return
  fi
  if [[ "$rc" -eq 86 && -z "$idx_note" && "$rh" == "$G_ROOT_HEAD" && "$oh" == "$G_OTHER_HEAD" && "$wh" == "$G_WT_HEAD" ]] &&
     grep -q "leading git global option" "$ROOT/err"; then
    REJECT_CLEAN=1
    ok "$label"
  else
    REJECT_CLEAN=0
    bad "$label (rc=$rc root $G_ROOT_HEAD->$rh other $G_OTHER_HEAD->$oh wt $G_WT_HEAD->$wh changed:${idx_note:-none} err=$(tr '\n' ' ' <"$ROOT/err") staged_other=$(git -C "$OTHER" diff --cached --name-only | tr '\n' ' ') staged_root=$(git -C "$ROOT" diff --cached --name-only | tr '\n' ' ') staged_wt=$(git -C "$WT" diff --cached --name-only | tr '\n' ' '))"
    restore_guard_state
  fi
}

# 0 when $2 is an exact cached name, 1 when the index was read and the name
# is absent, 2 when git diff failed. A piped quiet grep is L-077.
cached_exact_name_status() {
  local repo="$1" want="$2" name names
  names=$(git -C "$repo" diff --cached --name-only) || return 2
  while IFS= read -r name; do
    [[ "$name" == "$want" ]] && return 0
  done <<< "$names"
  return 1
}

# Legitimate operations whose first argument is the subcommand.
printf 'legit-after-global-option-fix\n' > "$ROOT/README.md"
run_guard add -- README.md >"$ROOT/out" 2>"$ROOT/err"
rc=$?
legit_blob=$(git -C "$ROOT" rev-parse :README.md 2>/dev/null || true)
cached_exact_name_status "$ROOT" "README.md"
name_rc=$?
if [[ "$rc" -eq 0 && -n "$legit_blob" && "$name_rc" -eq 0 ]]; then
  ok "subcommand-first add -- README.md still stages (exit $rc)"
else
  bad "subcommand-first add -- README.md (rc=$rc blob=$legit_blob err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
git -C "$ROOT" reset -q 2>/dev/null || true
git -C "$ROOT" checkout -q -- README.md 2>/dev/null || true

run_guard status --porcelain >"$ROOT/out" 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q "leading git global option" "$ROOT/err"; then
  ok "subcommand-first status --porcelain still exits 0"
else
  bad "subcommand-first status --porcelain (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

printf 'wt-legit-file\n' > "$WT/WT-LEGIT.txt"
run_guard_in "$WT" "$ROOT" add -- WT-LEGIT.txt >"$ROOT/out" 2>"$ROOT/err"
rc=$?
wt_legit_blob=$(git -C "$WT" rev-parse :WT-LEGIT.txt 2>/dev/null || true)
cached_exact_name_status "$WT" "WT-LEGIT.txt"
name_rc=$?
if [[ "$rc" -eq 0 && -n "$wt_legit_blob" && "$name_rc" -eq 0 ]]; then
  ok "linked worktree subcommand-first add still stages (exit $rc)"
else
  bad "linked worktree subcommand-first add (rc=$rc blob=$wt_legit_blob err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
git -C "$WT" reset -q 2>/dev/null || true
rm -f "$WT/WT-LEGIT.txt"

mkdir -p "$ROOT/.agents" "$WT/.agents"
printf 'bypass-gate\n' > "$ROOT/.agents/gate.json"
printf 'bypass-wt-gate\n' > "$WT/.agents/gate.json"
printf 'escaped-other\n' > "$OTHER/ESCAPED.txt"
ln -sfn "$OTHER" "$ROOT/other-link"
capture_guard_state
REJECT_CLEAN=0

reject_leading_global "foreign -C add does not stage into the other repo" "$ROOT" -C "$OTHER" add ESCAPED.txt
cached_exact_name_status "$OTHER" "ESCAPED.txt"
name_rc=$?
if [[ "$REJECT_CLEAN" -eq 1 && -f "$OTHER/ESCAPED.txt" && "$name_rc" -eq 1 ]]; then
  ok "foreign -C add left ESCAPED.txt untracked on disk"
else
  bad "foreign -C add filesystem/index (clean=$REJECT_CLEAN staged=$(git -C "$OTHER" diff --cached --name-only | tr '\n' ' '))"
fi

reject_leading_global "stuck -Cpath add does not stage into the other repo" "$ROOT" -C"$OTHER" add ESCAPED.txt
reject_leading_global "relative symlink -C add does not stage into the other repo" "$ROOT" -C other-link add ESCAPED.txt
reject_leading_global "--git-dir= add does not stage into the other repo" "$ROOT" --git-dir="$OTHER/.git" add ESCAPED.txt
reject_leading_global "--git-dir --work-tree add does not stage into the other repo" "$ROOT" --git-dir "$OTHER/.git" --work-tree "$OTHER" add ESCAPED.txt
reject_leading_global "-c then -C add does not stage into the other repo" "$ROOT" -c user.name=bypass -C "$OTHER" add ESCAPED.txt
reject_leading_global "-C then -c add does not stage into the other repo" "$ROOT" -C "$OTHER" -c user.name=bypass add ESCAPED.txt
reject_leading_global "-p then -C add does not stage into the other repo" "$ROOT" -p -C "$OTHER" add ESCAPED.txt
reject_leading_global "--bare before -C add does not stage into the other repo" "$ROOT" --bare -C "$OTHER" add ESCAPED.txt
reject_leading_global "linked worktree cwd with foreign -C add does not stage" "$WT" -C "$OTHER" add ESCAPED.txt

reject_leading_global "same-repo -C add does not stage .agents/gate.json" "$ROOT" -C "$ROOT" add .agents/gate.json
cached_exact_name_status "$ROOT" ".agents/gate.json"
name_rc=$?
if [[ "$REJECT_CLEAN" -eq 1 && -f "$ROOT/.agents/gate.json" && "$name_rc" -eq 1 ]]; then
  ok "same-repo -C add left .agents/gate.json unstaged on disk"
else
  bad "same-repo -C add filesystem/index (clean=$REJECT_CLEAN staged=$(git -C "$ROOT" diff --cached --name-only | tr '\n' ' '))"
fi
reject_leading_global "same-repo -C . add does not stage .agents/gate.json" "$ROOT" -C . add .agents/gate.json
reject_leading_global "same-repo subdirectory -C add does not stage .agents/gate.json" "$ROOT" -C "$ROOT/nested-sub" add ../.agents/gate.json
reject_leading_global "linked-worktree -C add does not stage .agents/gate.json" "$ROOT" -C "$WT" add .agents/gate.json
reject_leading_global "linked worktree cwd -C self add does not stage .agents/gate.json" "$WT" -C "$WT" add .agents/gate.json
reject_leading_global "leading -- before add does not stage .agents/gate.json" "$ROOT" -- add .agents/gate.json
reject_leading_global "--exec-path before status is refused" "$ROOT" --exec-path "$ROOT" status

# A tracked control-plane edit committed via `git -C <target> commit` used to
# skip check_staged_control_plane. Refuse it; HEAD and the index stay put.
if ! git -C "$ROOT" cat-file -e 'HEAD:.agents/gate.json' 2>/dev/null; then
  printf 'tracked-seed\n' > "$ROOT/.agents/gate.json"
  git -C "$ROOT" add .agents/gate.json
  git -C "$ROOT" commit -qm 'seed gate for global-option commit probe'
fi
printf 'dirty-for-dash-c-commit\n' > "$ROOT/.agents/gate.json"
git -C "$ROOT" add .agents/gate.json
capture_guard_state
seed_blob=$(git -C "$ROOT" rev-parse 'HEAD:.agents/gate.json')
reject_leading_global "same-repo -C commit does not move HEAD" "$ROOT" -C "$ROOT" commit -m 'bypass control plane'
head_blob=$(git -C "$ROOT" rev-parse 'HEAD:.agents/gate.json' 2>/dev/null || true)
if [[ "$REJECT_CLEAN" -eq 1 && "$head_blob" == "$seed_blob" && -f "$ROOT/.agents/gate.json" ]] &&
   grep -qx 'dirty-for-dash-c-commit' "$ROOT/.agents/gate.json"; then
  ok "same-repo -C commit left HEAD blob and the dirty worktree file"
else
  bad "same-repo -C commit filesystem (clean=$REJECT_CLEAN head_blob=$head_blob seed_blob=$seed_blob)"
fi
git -C "$ROOT" reset -q HEAD 2>/dev/null || true
git -C "$ROOT" checkout -q HEAD -- .agents/gate.json 2>/dev/null || true
rm -f "$OTHER/ESCAPED.txt" "$ROOT/other-link"

# --- storage overrides must not redirect index or object writes (#627) ------
# GIT_INDEX_FILE and GIT_OBJECT_DIRECTORY on the published guard wrote the
# victim from the target checkout, and from a linked worktree once that
# worktree was inside the boundary. GIT_ALTERNATE_OBJECT_DIRECTORIES did not
# by itself add a victim object in the release witness; it is still refused
# so lookup cannot follow another store. Own index and own object directory
# stay allowed. Refusal leaves both repositories' HEADs, the victim index,
# and the victim object files unchanged, and does not stage into this checkout.

if ! VICTIM_GITDIR=$(git -C "$VICTIM" rev-parse --absolute-git-dir); then
  bad "storage setup: victim git dir unreadable"
  VICTIM_GITDIR=""
fi
VICTIM_INDEX="$VICTIM_GITDIR/index"
if ! VICTIM_OBJECTS=$(git -C "$VICTIM" rev-parse --path-format=absolute --git-path objects); then
  bad "storage setup: victim objects unreadable"
  VICTIM_OBJECTS=""
fi
if ! ROOT_INDEX=$(git -C "$ROOT" rev-parse --path-format=absolute --git-path index); then
  bad "storage setup: root index path unreadable"
  ROOT_INDEX=""
fi
if ! ROOT_OBJECTS=$(git -C "$ROOT" rev-parse --path-format=absolute --git-path objects); then
  bad "storage setup: root objects path unreadable"
  ROOT_OBJECTS=""
fi
if ! WT_INDEX=$(git -C "$WT" rev-parse --path-format=absolute --git-path index); then
  bad "storage setup: worktree index path unreadable"
  WT_INDEX=""
fi
if ! WT_OBJECTS=$(git -C "$WT" rev-parse --path-format=absolute --git-path objects); then
  bad "storage setup: worktree objects path unreadable"
  WT_OBJECTS=""
fi
if [[ -n "$ROOT_OBJECTS" && "$WT_OBJECTS" == "$ROOT_OBJECTS" ]]; then
  ok "linked worktree shares the target object directory"
else
  bad "linked worktree object directory (root=$ROOT_OBJECTS wt=$WT_OBJECTS)"
fi

storage_digest() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  shasum -a 256 -- "$f"
}

storage_objects() {
  local objects="$1"
  [[ -d "$objects" ]] || return 1
  find "$objects" -type f ! -name '*.lock' -print | sort
}

storage_head() {
  git -C "$1" rev-parse HEAD
}

# 0 when stdout is empty, 1 when it has bytes, 2 when it cannot be read.
storage_stdout_empty() {
  [[ -f "$ROOT/out" ]] || return 2
  [[ ! -s "$ROOT/out" ]]
}

# Refuse one storage override. mode selects the environment. Arguments after
# mode are the guard command. Git failures while reading before/after state
# are failures, not "unchanged".
storage_refuse() {
  local label="$1" cwd="$2" mode="$3"
  shift 3
  local rc vh vi vo rh ri wh wi vh2 vi2 vo2 rh2 ri2 wh2 wi2 phrase
  if ! vh=$(storage_head "$VICTIM"); then
    bad "$label: victim HEAD unreadable before"
    return
  fi
  if ! rh=$(storage_head "$ROOT"); then
    bad "$label: target HEAD unreadable before"
    return
  fi
  if ! wh=$(storage_head "$WT"); then
    bad "$label: worktree HEAD unreadable before"
    return
  fi
  if ! vi=$(storage_digest "$VICTIM_INDEX"); then
    bad "$label: victim index unreadable before"
    return
  fi
  if ! ri=$(storage_digest "$ROOT_INDEX"); then
    bad "$label: target index unreadable before"
    return
  fi
  if ! wi=$(storage_digest "$WT_INDEX"); then
    bad "$label: worktree index unreadable before"
    return
  fi
  if ! vo=$(storage_objects "$VICTIM_OBJECTS"); then
    bad "$label: victim objects unreadable before"
    return
  fi
  (
    cd "$cwd" || exit 97
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
      GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    case "$mode" in
      foreign-index) GIT_INDEX_FILE="$VICTIM_INDEX" ;;
      foreign-objects) GIT_OBJECT_DIRECTORY="$VICTIM_OBJECTS" ;;
      foreign-alternates) GIT_ALTERNATE_OBJECT_DIRECTORIES="$VICTIM_OBJECTS" ;;
      foreign-all)
        GIT_INDEX_FILE="$VICTIM_INDEX"
        GIT_OBJECT_DIRECTORY="$VICTIM_OBJECTS"
        GIT_ALTERNATE_OBJECT_DIRECTORIES="$VICTIM_OBJECTS"
        ;;
      own-plus-foreign-alternates)
        if [[ "$cwd" == "$WT" ]]; then
          GIT_INDEX_FILE="$WT_INDEX"
          GIT_OBJECT_DIRECTORY="$WT_OBJECTS"
        else
          GIT_INDEX_FILE="$ROOT_INDEX"
          GIT_OBJECT_DIRECTORY="$ROOT_OBJECTS"
        fi
        GIT_ALTERNATE_OBJECT_DIRECTORIES="$VICTIM_OBJECTS"
        ;;
      quoted-alternates)
        GIT_ALTERNATE_OBJECT_DIRECTORIES=$(printf '"%s"' "$VICTIM_OBJECTS")
        ;;
      escaped-alternates)
        GIT_ALTERNATE_OBJECT_DIRECTORIES="${VICTIM_OBJECTS}\\extra"
        ;;
      cross-checkout-index) GIT_INDEX_FILE="$ROOT_INDEX" ;;
      foreign-dir-and-index)
        GIT_DIR="$VICTIM/.git"
        GIT_INDEX_FILE="$VICTIM_INDEX"
        ;;
      *)
        exit 98
        ;;
    esac
    # Only the overrides this case set are exported. An empty assignment would
    # be a set value and is a different guard input from an unset variable.
    [[ "${GIT_DIR+x}" == x ]] && export GIT_DIR
    [[ "${GIT_INDEX_FILE+x}" == x ]] && export GIT_INDEX_FILE
    [[ "${GIT_OBJECT_DIRECTORY+x}" == x ]] && export GIT_OBJECT_DIRECTORY
    [[ "${GIT_ALTERNATE_OBJECT_DIRECTORIES+x}" == x ]] && export GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIBSON_REAL_GIT="$(command -v git)" \
      GIBSON_TARGET_REPO="$ROOT" \
      GIBSON_EXPECTED_REPO_SLUG="acme/app" \
      "$GUARD" "$@"
  ) >"$ROOT/out" 2>"$ROOT/err"
  rc=$?
  phrase=""
  case "$mode" in
    foreign-index) phrase="GIT_INDEX_FILE names a different index" ;;
    foreign-objects) phrase="GIT_OBJECT_DIRECTORY names a different object store" ;;
    foreign-alternates|own-plus-foreign-alternates|quoted-alternates|escaped-alternates)
      phrase="GIT_ALTERNATE_OBJECT_DIRECTORIES names a different object store"
      ;;
    cross-checkout-index) phrase="GIT_INDEX_FILE names a different index" ;;
    foreign-dir-and-index) phrase="GIT_DIR names a different repository" ;;
  esac
  if ! vh2=$(storage_head "$VICTIM"); then
    bad "$label: victim HEAD unreadable after"
    return
  fi
  if ! rh2=$(storage_head "$ROOT"); then
    bad "$label: target HEAD unreadable after"
    return
  fi
  if ! wh2=$(storage_head "$WT"); then
    bad "$label: worktree HEAD unreadable after"
    return
  fi
  if ! vi2=$(storage_digest "$VICTIM_INDEX"); then
    bad "$label: victim index unreadable after"
    return
  fi
  if ! ri2=$(storage_digest "$ROOT_INDEX"); then
    bad "$label: target index unreadable after"
    return
  fi
  if ! wi2=$(storage_digest "$WT_INDEX"); then
    bad "$label: worktree index unreadable after"
    return
  fi
  if ! vo2=$(storage_objects "$VICTIM_OBJECTS"); then
    bad "$label: victim objects unreadable after"
    return
  fi
  storage_stdout_empty
  local empty_rc=$?
  if [[ "$rc" -eq 86 && "$empty_rc" -eq 0 && "$vh2" == "$vh" && "$rh2" == "$rh" && "$wh2" == "$wh" && "$vi2" == "$vi" && "$ri2" == "$ri" && "$wi2" == "$wi" && "$vo2" == "$vo" ]] &&
     grep -q "$phrase" "$ROOT/err"; then
    ok "$label"
  else
    bad "$label (rc=$rc stdout_empty=$empty_rc victim_head $vh->$vh2 root_head $rh->$rh2 wt_head $wh->$wh2 index_changed=$([[ "$vi2" == "$vi" && "$ri2" == "$ri" && "$wi2" == "$wi" ]] && echo no || echo yes) objects_changed=$([[ "$vo2" == "$vo" ]] && echo no || echo yes) err=$(tr '\n' ' ' <"$ROOT/err"))"
  fi
}

printf 'storage-escaped\n' > "$ROOT/STORAGE.txt"
printf 'storage-escaped-wt\n' > "$WT/STORAGE.txt"
storage_refuse "checkout foreign GIT_INDEX_FILE add" "$ROOT" foreign-index add STORAGE.txt
storage_refuse "checkout foreign GIT_OBJECT_DIRECTORY add" "$ROOT" foreign-objects add STORAGE.txt
storage_refuse "checkout foreign GIT_ALTERNATE_OBJECT_DIRECTORIES add" "$ROOT" foreign-alternates add STORAGE.txt
storage_refuse "checkout combined foreign storage add" "$ROOT" foreign-all add STORAGE.txt
storage_refuse "checkout own storage plus foreign alternates add" "$ROOT" own-plus-foreign-alternates add STORAGE.txt
storage_refuse "checkout quoted alternate add" "$ROOT" quoted-alternates add STORAGE.txt
storage_refuse "checkout escaped alternate add" "$ROOT" escaped-alternates add STORAGE.txt
storage_refuse "checkout foreign GIT_DIR still wins over foreign index" "$ROOT" foreign-dir-and-index add STORAGE.txt
storage_refuse "checkout foreign GIT_INDEX_FILE status" "$ROOT" foreign-index status --porcelain
storage_refuse "checkout foreign GIT_OBJECT_DIRECTORY rev-parse" "$ROOT" foreign-objects rev-parse HEAD
storage_refuse "linked worktree foreign GIT_INDEX_FILE add" "$WT" foreign-index add STORAGE.txt
storage_refuse "linked worktree foreign GIT_OBJECT_DIRECTORY add" "$WT" foreign-objects add STORAGE.txt
storage_refuse "linked worktree foreign GIT_ALTERNATE_OBJECT_DIRECTORIES add" "$WT" foreign-alternates add STORAGE.txt
storage_refuse "linked worktree combined foreign storage add" "$WT" foreign-all add STORAGE.txt
storage_refuse "linked worktree own storage plus foreign alternates add" "$WT" own-plus-foreign-alternates add STORAGE.txt
storage_refuse "linked worktree foreign GIT_INDEX_FILE status" "$WT" foreign-index status --porcelain
storage_refuse "linked worktree cross-checkout index add" "$WT" cross-checkout-index add STORAGE.txt
cached_exact_name_status "$VICTIM" "STORAGE.txt"
name_rc=$?
if [[ "$name_rc" -eq 1 ]]; then
  ok "victim index does not list STORAGE.txt after storage refusals"
elif [[ "$name_rc" -eq 2 ]]; then
  bad "victim diff --cached failed while checking STORAGE.txt absence"
else
  bad "victim index lists STORAGE.txt after storage refusals"
fi
cached_exact_name_status "$ROOT" "STORAGE.txt"
name_rc=$?
if [[ "$name_rc" -eq 1 ]]; then
  ok "target index does not list STORAGE.txt after storage refusals"
elif [[ "$name_rc" -eq 2 ]]; then
  bad "target diff --cached failed while checking STORAGE.txt absence"
else
  bad "target index lists STORAGE.txt after storage refusals"
fi
cached_exact_name_status "$WT" "STORAGE.txt"
name_rc=$?
if [[ "$name_rc" -eq 1 ]]; then
  ok "worktree index does not list STORAGE.txt after storage refusals"
elif [[ "$name_rc" -eq 2 ]]; then
  bad "worktree diff --cached failed while checking STORAGE.txt absence"
else
  bad "worktree index lists STORAGE.txt after storage refusals"
fi

# Own index, including the macOS /var logical alias of the same file, still
# stages in this checkout and does not touch the victim.
LOGICAL_ROOT_INDEX="$ROOT_INDEX"
case "$ROOT_INDEX" in
  /private/var/*) LOGICAL_ROOT_INDEX="/var/${ROOT_INDEX#/private/var/}" ;;
esac
victim_head_before=$(storage_head "$VICTIM") || victim_head_before=""
root_head_before=$(storage_head "$ROOT") || root_head_before=""
victim_index_before=$(storage_digest "$VICTIM_INDEX") || victim_index_before=""
(
  cd "$ROOT" &&
    GIT_INDEX_FILE="$LOGICAL_ROOT_INDEX" \
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" add -- STORAGE.txt
) >"$ROOT/out" 2>"$ROOT/err"
rc=$?
cached_exact_name_status "$ROOT" "STORAGE.txt"
name_rc=$?
victim_head_after=$(storage_head "$VICTIM") || victim_head_after="unreadable"
victim_index_after=$(storage_digest "$VICTIM_INDEX") || victim_index_after="unreadable"
root_head_after=$(storage_head "$ROOT") || root_head_after="unreadable"
if [[ "$rc" -eq 0 && "$name_rc" -eq 0 && -n "$victim_head_before" && "$victim_head_after" == "$victim_head_before" && "$victim_index_after" == "$victim_index_before" && "$root_head_after" == "$root_head_before" ]]; then
  ok "logical own GIT_INDEX_FILE still stages in the target (exit $rc)"
else
  bad "logical own GIT_INDEX_FILE (rc=$rc name_rc=$name_rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
git -C "$ROOT" reset -q -- STORAGE.txt 2>/dev/null || true

wt_head_before=$(storage_head "$WT") || wt_head_before=""
(
  cd "$WT" &&
    GIT_INDEX_FILE="$WT_INDEX" \
    GIT_OBJECT_DIRECTORY="$WT_OBJECTS" \
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" add -- STORAGE.txt
) >"$ROOT/out" 2>"$ROOT/err"
rc=$?
cached_exact_name_status "$WT" "STORAGE.txt"
name_rc=$?
wt_head_after=$(storage_head "$WT") || wt_head_after="unreadable"
victim_head_after=$(storage_head "$VICTIM") || victim_head_after="unreadable"
victim_index_after=$(storage_digest "$VICTIM_INDEX") || victim_index_after="unreadable"
if [[ "$rc" -eq 0 && "$name_rc" -eq 0 && -n "$wt_head_before" && "$wt_head_after" == "$wt_head_before" && "$victim_head_after" == "$victim_head_before" && "$victim_index_after" == "$victim_index_before" ]]; then
  ok "linked worktree own index and object directory still stage (exit $rc)"
else
  bad "linked worktree own storage (rc=$rc name_rc=$name_rc wt_head $wt_head_before->$wt_head_after err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
git -C "$WT" reset -q -- STORAGE.txt 2>/dev/null || true

# Default dispatch with an empty alternate list matches a repo that has no
# alternates file. Status must still run in this checkout.
(
  cd "$ROOT" &&
    GIT_ALTERNATE_OBJECT_DIRECTORIES="" \
    GIBSON_REAL_GIT="$(command -v git)" \
    GIBSON_TARGET_REPO="$ROOT" \
    GIBSON_EXPECTED_REPO_SLUG="acme/app" \
    "$GUARD" status --porcelain
) >"$ROOT/out" 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q "GIT_ALTERNATE_OBJECT_DIRECTORIES" "$ROOT/err"; then
  ok "empty alternate list still dispatches status (exit $rc)"
else
  bad "empty alternate list status (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

# Independently evaluated rollback must ignore a foreign index and object
# store: unstage the target path, leave the victim byte-for-byte.
printf 'storage-rollback-protected\n' > "$ROOT/.agents/gate.json"
if ! git -C "$ROOT" add -- .agents/gate.json; then
  bad "storage rollback: could not stage protected path with real git"
else
  cached_exact_name_status "$ROOT" ".agents/gate.json"
  name_rc=$?
  if [[ "$name_rc" -ne 0 ]]; then
    bad "storage rollback: protected path was not staged before helper (name_rc=$name_rc)"
  fi
fi
# shellcheck disable=SC2034
REAL_GIT=$(command -v git)
# shellcheck disable=SC2034
current_root="$ROOT_PHYS"
_protected_staged=(".agents/gate.json")
eval "$(sed -n '/^rollback_protected_staged()/,/^}/p' "$GUARD")"
victim_head_before=$(storage_head "$VICTIM") || victim_head_before=""
root_head_before=$(storage_head "$ROOT") || root_head_before=""
victim_index_before=$(storage_digest "$VICTIM_INDEX") || victim_index_before=""
victim_objects_before=$(storage_objects "$VICTIM_OBJECTS") || victim_objects_before=""
(
  GIT_INDEX_FILE="$VICTIM_INDEX" \
    GIT_OBJECT_DIRECTORY="$VICTIM_OBJECTS" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$VICTIM_OBJECTS" \
    rollback_protected_staged
)
cached_exact_name_status "$ROOT" ".agents/gate.json"
name_rc=$?
victim_head_after=$(storage_head "$VICTIM") || victim_head_after="unreadable"
root_head_after=$(storage_head "$ROOT") || root_head_after="unreadable"
victim_index_after=$(storage_digest "$VICTIM_INDEX") || victim_index_after="unreadable"
victim_objects_after=$(storage_objects "$VICTIM_OBJECTS") || victim_objects_after="unreadable"
cached_exact_name_status "$VICTIM" ".agents/gate.json"
victim_name_rc=$?
if [[ "$name_rc" -eq 1 && "$victim_name_rc" -eq 1 && -n "$victim_head_before" && "$victim_head_after" == "$victim_head_before" && "$root_head_after" == "$root_head_before" && "$victim_index_after" == "$victim_index_before" && "$victim_objects_after" == "$victim_objects_before" ]]; then
  ok "rollback helper ignores foreign storage overrides and unstages the target"
else
  bad "storage rollback helper (name_rc=$name_rc victim_name_rc=$victim_name_rc victim_head $victim_head_before->$victim_head_after root_head $root_head_before->$root_head_after)"
fi
git -C "$ROOT" checkout -q HEAD -- .agents/gate.json 2>/dev/null || true
rm -f "$ROOT/STORAGE.txt" "$WT/STORAGE.txt"

# --- allowed push reaches the remote ----------------------------------------
# Every push sensor above checks a refusal. This one checks that an allowed push
# actually lands: check_push receives the arguments after `push`, so it must
# hand `push` back to real git. Without it, `git push origin main` runs as
# `git origin main` and every allowed push fails. The configured URL matches
# the expected slug; insteadOf sends the transfer to a local bare repository.
PUSH_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard-push.XXXXXX")
PUSH_BARE=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard-bare.XXXXXX")
trap 'rm -rf "$ROOT" "$PUSH_ROOT" "$PUSH_BARE"' EXIT
git -C "$PUSH_BARE" init -q --bare
git -C "$PUSH_ROOT" init -q -b main
git -C "$PUSH_ROOT" config user.email test@gibson.invalid
git -C "$PUSH_ROOT" config user.name gibson-test
printf 'push base\n' > "$PUSH_ROOT/README.md"
git -C "$PUSH_ROOT" add README.md
git -C "$PUSH_ROOT" commit -qm 'push base'
git -C "$PUSH_ROOT" remote add origin https://github.com/acme/app.git
git -C "$PUSH_ROOT" config "url.$PUSH_BARE.insteadOf" https://github.com/acme/app.git
git -C "$PUSH_ROOT" switch -q -c feat/allowed-push
run_guard_in "$PUSH_ROOT" "$PUSH_ROOT" push -u origin feat/allowed-push >/dev/null 2>"$ROOT/err"
rc=$?
pushed_tip=$(git -C "$PUSH_BARE" rev-parse --verify -q refs/heads/feat/allowed-push 2>/dev/null || true)
local_tip=$(git -C "$PUSH_ROOT" rev-parse HEAD)
if [[ "$rc" -eq 0 && -n "$pushed_tip" && "$pushed_tip" == "$local_tip" ]]; then
  ok "allowed push reaches the expected remote (exit $rc)"
else
  bad "allowed push (rc=$rc pushed=${pushed_tip:-none} local=$local_tip err=$(tr '\n' ' ' <"$ROOT/err"))"
fi
upstream_ref=$(git -C "$PUSH_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
if [[ "$upstream_ref" == "origin/feat/allowed-push" ]]; then
  ok "allowed push keeps its flags (-u sets upstream)"
else
  bad "allowed push flags (upstream=${upstream_ref:-none})"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "$PASS passed, $FAIL failed, $SKIP skipped"
  exit 0
fi
echo "$PASS passed, $FAIL failed, $SKIP skipped"
exit 1
