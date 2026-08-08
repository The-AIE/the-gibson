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
ok() { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

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

# --- portable logical-vs-physical alias (symlink to same repo) --------------
ALIAS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gibson-repo-guard-alias.XXXXXX")
# Keep alias under ROOT so trap cleans the primary fixture; also remove ALIAS_DIR.
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

# --- macOS /var vs /private/var when the host exposes that alias ------------
if [[ "$(uname -s)" == "Darwin" ]] && [[ -L /var ]]; then
  var_target=$(readlink /var 2>/dev/null || true)
  if [[ "$var_target" == "private/var" || "$var_target" == "/private/var" ]]; then
    case "$ROOT" in
      /var/*)
        # Logical TARGET (mktemp) vs physical cwd/git root — #146 reproduction.
        if [[ "$ROOT" != "$ROOT_PHYS" ]]; then
          printf 'forbidden\n' > "$ROOT/.agents/gate.json"
          run_guard_in "$ROOT_PHYS" "$ROOT" add .agents/gate.json \
            >/dev/null 2>"$ROOT/err"
          rc=$?
          if [[ "$rc" -eq 86 ]] && grep -q "control-plane" "$ROOT/err"; then
            ok "macOS /var vs /private/var alias reaches control-plane (exit $rc)"
          else
            bad "macOS /var vs /private/var (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
          fi
          staged=$(git -C "$ROOT" diff --cached --name-only)
          [[ -z "$staged" ]] &&
            ok "macOS /var alias staging rolled back" ||
            bad "macOS /var alias staging rollback (still staged: $staged)"
          rm -f "$ROOT/.agents/gate.json"
          git -C "$ROOT" reset -q 2>/dev/null || true
        else
          ok "macOS /var alias sensor skipped (mktemp already physical)"
        fi
        ;;
      *)
        ok "macOS /var alias sensor skipped (fixture not under /var)"
        ;;
    esac
  else
    ok "macOS /var alias sensor skipped (/var not → private/var)"
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
  ok "different repo root rejected (exit $rc)"
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

# --- wrong-origin push: reason + exit code ----------------------------------
git -C "$ROOT" remote set-url origin https://github.com/the-gibson/harness.git
run_guard push origin main >/dev/null 2>"$ROOT/err"
rc=$?
if [[ "$rc" -eq 86 ]] && grep -q "expected 'acme/app'" "$ROOT/err"; then
  ok "wrong-origin push rejected with slug diagnostic (exit $rc)"
else
  bad "wrong-origin push (rc=$rc err=$(tr '\n' ' ' <"$ROOT/err"))"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "$PASS passed, $FAIL failed"
  exit 0
fi
echo "$PASS passed, $FAIL failed"
exit 1
