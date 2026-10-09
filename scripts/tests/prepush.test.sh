#!/usr/bin/env bash
# prepush.test.sh — sensors for scripts/prepush.sh (#465)
#
# Exercises prepush.sh against throwaway git repos: clear, each probe failing,
# a missing tool reported NOT RUN, touched-test mapping. Also asserts every
# probe prepush.sh runs is exercised by the gate (run-all.sh or the self-gate
# workflow), with a mutation proving the drift check can fail.
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-prepush.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# reach_stub DIR EXIT — a sensor-reachability stub that is itself well behaved
# (unknown flag => exit 2), so the unknown-flag probe does not flag the fixture.
reach_stub() {
  printf 'if (process.argv.length > 2) { console.error("unknown flag: " + process.argv[2]); process.exit(2); }\nprocess.exit(%s);\n' "$2" > "$1/scripts/sensor-reachability.mjs"
}

# make_repo NAME — a repo with prepush.sh, its libs, a passing reachability
# stub and one well-behaved mjs, committed on a base commit.
make_repo() {
  local d="$ROOT/$1"
  mkdir -p "$d/scripts/lib" "$d/scripts/tests"
  cp "$REPO_ROOT/scripts/prepush.sh" "$d/scripts/"
  cp "$REPO_ROOT/scripts/lib/convention-probes.sh" "$REPO_ROOT/scripts/lib/wall-timeout.sh" "$d/scripts/lib/"
  reach_stub "$d" 0
  cat > "$d/scripts/ok.mjs" <<'EOF'
const a = process.argv.slice(2);
if (a.some((x) => x.startsWith("--"))) { console.error(`unknown flag: ${a[0]}`); process.exit(2); }
EOF
  git -C "$d" init -q -b main && git -C "$d" add -A && git -C "$d" commit -q -m base
  echo "$d"
}

# run_prepush DIR [args...] — sets OUT, RC.
run_prepush() {
  local d="$1"; shift
  OUT=$(cd "$d" && bash scripts/prepush.sh --base HEAD "$@" 2>&1); RC=$?
}
last_line() { printf '%s\n' "$OUT" | tail -n 1; }

# --- help / usage -----------------------------------------------------------
help_out=$(bash "$REPO_ROOT/scripts/prepush.sh" --help 2>/dev/null); help_rc=$?
[[ "$help_rc" -eq 0 && "$help_out" == *"WHAT IT DOES"* && "$help_out" == *"RISKS"* ]] \
  && ok "--help exits 0 and names WHAT IT DOES and RISKS" || bad "--help shape (rc=$help_rc)"
bash "$REPO_ROOT/scripts/prepush.sh" --nope >/dev/null 2>"$ROOT/err"; rc=$?
[[ "$rc" -eq 2 ]] && grep -q "unknown flag:" "$ROOT/err" && ok "unknown flag exits 2" || bad "unknown flag rc=$rc"

# --- clear ------------------------------------------------------------------
d=$(make_repo clear)
run_prepush "$d"
[[ "$RC" -eq 0 && "$(last_line)" == prepush:\ all\ clear* ]] && ok "clean repo: exit 0 and 'all clear'" || bad "clean repo rc=$RC: $OUT"

# --- each probe failing -----------------------------------------------------
d=$(make_repo badflag)
printf 'process.exit(0);\n' > "$d/scripts/ignores-flags.mjs"
run_prepush "$d"
[[ "$RC" -eq 1 && "$(last_line)" == *"FAILED mjs-unknown-flag"* ]] && ok "mjs ignoring unknown flags: exit 1, name is last line" || bad "badflag rc=$RC: $OUT"

d=$(make_repo badreach)
reach_stub "$d" 1
run_prepush "$d"
[[ "$RC" -eq 1 && "$(last_line)" == *"FAILED sensor-reachability"* ]] && ok "failing reachability: exit 1, name is last line" || bad "badreach rc=$RC: $OUT"

d=$(make_repo badsyntax)
printf 'if then fi (\n' > "$d/scripts/broken.sh"
run_prepush "$d"
[[ "$RC" -eq 1 && "$(last_line)" == *"FAILED bash-n"* ]] && ok "unparseable changed shell script: exit 1" || bad "badsyntax rc=$RC: $OUT"

# --- touched-test mapping ---------------------------------------------------
d=$(make_repo touched)
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/foo.sh"
printf '#!/usr/bin/env bash\necho nope\nexit 1\n' > "$d/scripts/tests/foo.test.sh"
run_prepush "$d"
[[ "$RC" -eq 1 && "$(last_line)" == *"FAILED test:foo.test.sh"* ]] && ok "changed scripts/foo.sh runs scripts/tests/foo.test.sh" || bad "touched rc=$RC: $OUT"
run_prepush "$d" --no-tests
[[ "$RC" -eq 0 ]] && ok "--no-tests skips the mapped suite" || bad "--no-tests rc=$RC: $OUT"

# --- missing tool is NOT RUN, never a pass ----------------------------------
d=$(make_repo nonode)
mkdir -p "$ROOT/nonode-bin"
for t in bash git sed grep sort find mktemp head tail tr dirname basename rm cat wc perl python3 awk cmp date kill sleep ps; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$ROOT/nonode-bin/$t"
done
OUT=$(cd "$d" && PATH="$ROOT/nonode-bin" bash scripts/prepush.sh --base HEAD 2>&1); RC=$?
[[ "$RC" -eq 1 && "$OUT" == *"NOT RUN  sensor-reachability"* ]] && ok "no node: NOT RUN, exit 1 (never green)" || bad "nonode rc=$RC: $OUT"

# --- drift: every probe prepush.sh runs is exercised by the gate ------------
# gate_exercises FILE NEEDLE — the gate file must still contain the probe.
gate_exercises() { grep -qF "$2" "$1"; }
drift_check() {
  local runall="$1" selfgate="$2" miss=""
  for needle in cp_bash_n cp_mjs_unknown_flag; do
    gate_exercises "$runall" "$needle" || miss="$miss $needle"
  done
  gate_exercises "$selfgate" "scripts/sensor-reachability.mjs" || miss="$miss sensor-reachability"
  [[ -z "$miss" ]] || { echo "not exercised by the gate:$miss"; return 1; }
}
RUNALL="$REPO_ROOT/scripts/tests/run-all.sh"
SELFGATE="$REPO_ROOT/.github/workflows/gibson-self-gate.yml"
for needle in cp_bash_n cp_mjs_unknown_flag "scripts/sensor-reachability.mjs"; do
  grep -qF "$needle" "$REPO_ROOT/scripts/prepush.sh" "$REPO_ROOT/scripts/lib/convention-probes.sh" \
    || bad "drift list rot: '$needle' is no longer referenced by prepush.sh or its lib"
done
if out=$(drift_check "$RUNALL" "$SELFGATE"); then ok "every prepush probe is exercised by run-all.sh or the self-gate"; else bad "drift: $out"; fi

# Mutation: drop a probe from a copy of run-all.sh; the drift check must fail.
sed 's/cp_mjs_unknown_flag/cp_removed/g' "$RUNALL" > "$ROOT/run-all.mutant"
if drift_check "$ROOT/run-all.mutant" "$SELFGATE" >/dev/null; then
  bad "mutation (probe removed from run-all.sh) was NOT caught by the drift check"
else
  ok "mutation (probe removed from run-all.sh) is caught by the drift check"
fi

echo
echo "prepush.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
