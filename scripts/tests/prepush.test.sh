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
  mkdir -p "$d/playbooks/recipes"
  printf '# builder\n' > "$d/playbooks/builder.md"
  printf '# playbook: playbooks/builder.md\n# playbook-sha256: %s\n' "$(shasum -a 256 "$d/playbooks/builder.md" | awk '{print $1}')" > "$d/playbooks/recipes/builder.yaml"
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

d=$(make_repo recipedrift)
printf '# builder changed after the pin\n' > "$d/playbooks/builder.md"
run_prepush "$d"
[[ "$RC" -eq 1 && "$(last_line)" == *"FAILED recipe-hash"* ]] && ok "recipe pin drift: exit 1, name is last line" || bad "recipedrift rc=$RC: $OUT"

d=$(make_repo recipenone)
rm -f "$d/playbooks/recipes/builder.yaml"
run_prepush "$d"
[[ "$RC" -eq 1 && "$OUT" == *"NOT RUN  recipe-hash"* ]] && ok "no recipes found: NOT RUN, never a pass" || bad "recipenone rc=$RC: $OUT"

d=$(make_repo recipegone)
rm -f "$d/playbooks/builder.md"
run_prepush "$d"
[[ "$RC" -eq 1 && "$(last_line)" == *"FAILED recipe-hash"* ]] && ok "recipe whose playbook is missing is reported, not skipped" || bad "recipegone rc=$RC: $OUT"
d=$(make_repo recipenopin)
printf '# playbook: playbooks/builder.md\n' > "$d/playbooks/recipes/builder.yaml"
run_prepush "$d"
[[ "$RC" -eq 1 && "$(last_line)" == *"FAILED recipe-hash"* ]] && ok "recipe whose pin was removed is reported, not skipped" || bad "recipenopin rc=$RC: $OUT"

# --- invalid --base is a usage error, not a silent all-clear ----------------
d=$(make_repo badbase)
OUT=$(cd "$d" && bash scripts/prepush.sh --base does-not-exist 2>&1); RC=$?
[[ "$RC" -eq 2 && "$OUT" == *"--base ref not found"* ]] && ok "unknown --base ref exits 2" || bad "badbase rc=$RC: $OUT"

# --- a probe that finds nothing to probe is not a pass ----------------------
empty="$ROOT/empty"; mkdir -p "$empty/scripts"
out=$(cd "$empty" && . "$REPO_ROOT/scripts/lib/convention-probes.sh" && cp_mjs_unknown_flag); rc=$?
[[ "$rc" -eq 2 ]] && ok "unknown-flag probe with no scripts/*.mjs returns 2 (cannot run), not 0" || bad "empty mjs probe rc=$rc: $out"

# --- touched-test mapping ---------------------------------------------------
d=$(make_repo touched)
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/foo.sh"
printf '#!/usr/bin/env bash\necho nope\nexit 1\n' > "$d/scripts/tests/foo.test.sh"
run_prepush "$d"
[[ "$RC" -eq 1 && "$(last_line)" == *"FAILED test:foo.test.sh"* ]] && ok "changed scripts/foo.sh runs scripts/tests/foo.test.sh" || bad "touched rc=$RC: $OUT"
run_prepush "$d" --no-tests
[[ "$RC" -eq 0 && "$OUT" == *"SKIPPED  touched-tests"* && "$(last_line)" == *"touched tests SKIPPED"* && "$(last_line)" != *"all clear"* ]] \
  && ok "--no-tests skips the mapped suite and says so (never a plain 'all clear')" || bad "--no-tests rc=$RC: $OUT"

# --- more touched suites than the cap, and a spent budget, are NOT RUN ------
d=$(make_repo manytests)
for i in 1 2 3 4 5 6 7; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/t$i.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/tests/t$i.test.sh"
done
run_prepush "$d"
[[ "$RC" -eq 1 && "$OUT" == *"NOT RUN  test:t7.test.sh (over the 6-suite cap"* ]] && ok "seventh touched suite is NOT RUN, never a silent all-clear" || bad "manytests rc=$RC: $OUT"
d=$(make_repo budget)
for i in 1 2 3; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/b$i.sh"
  printf '#!/usr/bin/env bash\nsleep 3\nexit 0\n' > "$d/scripts/tests/b$i.test.sh"
done
OUT=$(cd "$d" && PREPUSH_BUDGET=2 PREPUSH_TEST_TIMEOUT=10 bash scripts/prepush.sh --base HEAD 2>&1); RC=$?
[[ "$RC" -eq 1 && "$OUT" == *"over the 2s budget"* ]] && ok "suites past the time budget are NOT RUN" || bad "budget rc=$RC: $OUT"

# --- a slow touched test is NOT RUN (timed out), never a pass ---------------
d=$(make_repo slowtest)
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/scripts/slow.sh"
printf '#!/usr/bin/env bash\nsleep 30\nexit 0\n' > "$d/scripts/tests/slow.test.sh"
OUT=$(cd "$d" && PREPUSH_TEST_TIMEOUT=2 bash scripts/prepush.sh --base HEAD 2>&1); RC=$?
[[ "$RC" -eq 1 && "$OUT" == *"NOT RUN  test:slow.test.sh (timed out"* ]] && ok "touched suite over its cap: NOT RUN (timed out), exit 1" || bad "slowtest rc=$RC: $OUT"

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
RUNALL="$REPO_ROOT/scripts/tests/run-all.sh"
GOOSE="$REPO_ROOT/scripts/tests/goose-recipes.test.sh"
# probe name -> "gate file|needle". Every probe prepush.sh runs must appear here,
# and the needle must still be in that gate file.
probe_gate() {
  case "$1" in
    sensor-reachability) echo "$RUNALL|scripts/sensor-reachability.mjs" ;;
    mjs-unknown-flag)    echo "$RUNALL|cp_mjs_unknown_flag" ;;
    bash-n)              echo "$RUNALL|cp_bash_n" ;;
    recipe-hash)         echo "$GOOSE|cp_recipe_hash_drift" ;;
    *) return 1 ;;
  esac
}
# discover_probes FILE — names of the non-test run_probe calls in prepush.sh.
discover_probes() { grep -E '^[[:space:]]*run_probe [a-z][a-z-]* ' "$1" | awk '{print $2}'; }
drift_check() {
  local prepush="$1" runall_override="${2:-}" name spec gfile needle bad="" n=0
  for name in $(discover_probes "$prepush"); do
    n=$((n + 1))
    spec=$(probe_gate "$name") || { bad="$bad unmapped-probe:$name"; continue; }
    gfile="${spec%%|*}"; needle="${spec#*|}"
    [[ -n "$runall_override" && "$gfile" == "$RUNALL" ]] && gfile="$runall_override"
    gate_exercises "$gfile" "$needle" || bad="$bad $name"
  done
  [[ "$n" -ge 4 ]] || bad="$bad discovered-only-$n-probes"
  [[ -z "$bad" ]] || { echo "not exercised by the gate:$bad"; return 1; }
}
if out=$(drift_check "$REPO_ROOT/scripts/prepush.sh"); then ok "every probe prepush.sh runs (discovered, not listed) is exercised by the gate"; else bad "drift: $out"; fi

# A probe added to prepush.sh with no gate mapping must fail the drift check.
{ cat "$REPO_ROOT/scripts/prepush.sh"; printf 'run_probe new-check true\n'; } > "$ROOT/prepush.mutant"
if drift_check "$ROOT/prepush.mutant" >/dev/null; then
  bad "mutation (new unmapped probe added to prepush.sh) was NOT caught"
else
  ok "mutation (new unmapped probe added to prepush.sh) is caught by discovery"
fi

# The gate must actually load the lib it calls: run-all.sh resolves SCRIPT_DIR to
# scripts/tests, so the source line must reach ../lib and that file must exist.
src_line=$(grep -F 'convention-probes.sh"' "$RUNALL" | grep -F '. "$SCRIPT_DIR/' | head -1)
if [[ "$src_line" == *'$SCRIPT_DIR/../lib/convention-probes.sh'* && -f "$SCRIPT_DIR/../lib/convention-probes.sh" && "$src_line" == *'exit 1'* ]]; then
  ok "run-all.sh sources scripts/lib/convention-probes.sh by a path that exists and fails closed"
else
  bad "run-all.sh does not source the probe lib correctly: $src_line"
fi

# Execute the gate's own blocks. The grep checks above prove references; these
# run the real run-all.sh text (extracted by marker) against throwaway input.
gate_block() { awk -v s="$2" -v e="$3" 'index($0,s)==1{on=1} on&&index($0,e)==1{exit} on{print}' "$1"; }
bash_n_block=$(gate_block "$RUNALL" 'echo "== bash -n"' 'echo "== bash 3.2')
mjs_block=$(gate_block "$RUNALL" 'echo "== mjs unknown-flag"' 'echo "== sensor-reachability"')
sr_block=$(gate_block "$RUNALL" 'echo "== sensor-reachability"' '# --- 3. injection scan')
if [[ -z "$bash_n_block" || -z "$mjs_block" || -z "$sr_block" ]]; then
  bad "could not extract the run-all.sh bash -n / mjs blocks (markers moved?)"
else
  gd="$ROOT/gateblocks"; mkdir -p "$gd/scripts"
  printf 'if then fi (\n' > "$gd/broken.sh"; printf 'echo ok\n' > "$gd/fine.sh"
  printf 'process.exit(0);\n' > "$gd/scripts/ignores.mjs"
  # shellcheck disable=SC2034  # SH_FILES is read by the eval'd run-all.sh block
  got=$(cd "$gd" && RED='' GRN='' OFF='' FAILED='' SH_FILES=$'broken.sh\nfine.sh' && . "$REPO_ROOT/scripts/lib/convention-probes.sh" && eval "$bash_n_block" >/dev/null 2>&1; echo "FAILED=[$FAILED]")
  [[ "$got" == *"bash-n"* ]] && ok "executed run-all.sh bash -n block: a broken script in SH_FILES fails the gate" || bad "bash -n block did not fail on a broken script: $got"
  # shellcheck disable=SC2034  # SH_FILES is read by the eval'd run-all.sh block
  got=$(cd "$gd" && RED='' GRN='' OFF='' FAILED='' SH_FILES='fine.sh' && . "$REPO_ROOT/scripts/lib/convention-probes.sh" && eval "$bash_n_block" >/dev/null 2>&1; echo "FAILED=[$FAILED]")
  [[ "$got" != *"bash-n"* ]] && ok "executed run-all.sh bash -n block: a clean list passes" || bad "bash -n block failed on a clean list: $got"
  # shellcheck disable=SC2034  # colours are read by the eval'd run-all.sh block
  got=$(cd "$gd" && RED='' GRN='' OFF='' FAILED='' && . "$REPO_ROOT/scripts/lib/convention-probes.sh" && eval "$mjs_block" >/dev/null 2>&1; echo "FAILED=[$FAILED]")
  [[ "$got" == *"mjs-unknown-flag"* ]] && ok "executed run-all.sh mjs block: a script ignoring unknown flags fails the gate" || bad "mjs block did not fail: $got"
  reach_stub "$gd" 1; rm -f "$gd/scripts/ignores.mjs"
  # shellcheck disable=SC2034  # colours are read by the eval'd run-all.sh block
  got=$(cd "$gd" && RED='' GRN='' OFF='' FAILED='' && eval "$sr_block" >/dev/null 2>&1; echo "FAILED=[$FAILED]")
  [[ "$got" == *"sensor-reachability"* ]] && ok "executed run-all.sh sensor-reachability block: a failing sensor fails the gate" || bad "sensor-reachability block did not fail: $got"
  reach_stub "$gd" 0
  # shellcheck disable=SC2034  # colours are read by the eval'd run-all.sh block
  got=$(cd "$gd" && RED='' GRN='' OFF='' FAILED='' && eval "$sr_block" >/dev/null 2>&1; echo "FAILED=[$FAILED]")
  [[ "$got" != *"sensor-reachability"* ]] && ok "executed run-all.sh sensor-reachability block: a passing sensor passes" || bad "sensor-reachability block failed a passing sensor: $got"
fi

# Execute the recipe-hash gate path: goose-recipes.test.sh run in a throwaway
# repo whose builder playbook drifted from its pin must report the drift. Other assertions in that suite may fail on
# hosts without pyyaml; only the drift line is judged.
gr="$ROOT/goose-fixture"; mkdir -p "$gr/scripts/tests" "$gr/scripts/lib"
cp "$GOOSE" "$gr/scripts/tests/"; cp "$REPO_ROOT/scripts/lib/convention-probes.sh" "$gr/scripts/lib/"
cp -R "$REPO_ROOT/playbooks" "$gr/playbooks"
printf '\n<!-- drifted -->\n' >> "$gr/playbooks/builder.md"
drift_out=$(cd "$gr" && bash scripts/tests/goose-recipes.test.sh 2>&1)
if [[ "$drift_out" == *"FAIL — builder.yaml playbook-sha256 drift"* ]]; then
  ok "executed goose-recipes.test.sh hash path: reports drift when the playbook changes (the clean match is asserted by that suite itself)"
else
  bad "goose-recipes.test.sh hash path did not report drift: $(printf '%s' "$drift_out" | grep -i 'builder.yaml playbook-sha256' | head -2)"
fi

# Mutation: drop a probe from a copy of run-all.sh; the drift check must fail.
sed 's/cp_mjs_unknown_flag/cp_removed/g' "$RUNALL" > "$ROOT/run-all.mutant"
if drift_check "$REPO_ROOT/scripts/prepush.sh" "$ROOT/run-all.mutant" >/dev/null; then
  bad "mutation (probe removed from run-all.sh) was NOT caught by the drift check"
else
  ok "mutation (probe removed from run-all.sh) is caught by the drift check"
fi

echo
echo "prepush.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
