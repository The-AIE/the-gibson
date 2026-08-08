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

# --- commit_form_includes_worktree: deterministic parser sensors ------------
# Extract the classifier without executing the guard body (script runs on load).
# Pure function tests — no git, no hang risk for interactive forms.
eval "$(sed -n '/^commit_form_includes_worktree()/,/^}/p' "$GUARD")"
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
eval "$(sed -n '/^rollback_protected_staged()/,/^}/p' "$GUARD")"
rollback_protected_staged
still_star=$(git -C "$ROOT" diff --cached --name-only | grep -F "$STAR_NAME" || true)
still_bracket=$(git -C "$ROOT" diff --cached --name-only | grep -F "$BRACKET_NAME" || true)
if [[ -z "$still_star" && -n "$still_bracket" ]]; then
  ok "literal rollback unstages only star-named protected path"
else
  bad "literal rollback selectivity (star='$still_star' bracket='$still_bracket' staged=$(git -C "$ROOT" diff --cached --name-only | tr '\n' ' '))"
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

if [[ "$FAIL" -eq 0 ]]; then
  echo "$PASS passed, $FAIL failed, $SKIP skipped"
  exit 0
fi
echo "$PASS passed, $FAIL failed, $SKIP skipped"
exit 1
