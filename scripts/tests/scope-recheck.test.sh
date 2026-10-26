#!/usr/bin/env bash
# scope-recheck.test.sh — sensors for scripts/scope-recheck.mjs and its prepush wiring (#568)
#
# WHAT IT DOES
#   Plants each collision in a throwaway git repo with a stub `gh` that serves
#   JSON/TSV fixtures (never GitHub): a change outside the PR's Claim scope, a
#   change inside a lower-numbered live claim, a docs/NN- number used twice
#   across main and an open PR, and a workflow with no sensor-health policy.
#   Each must go red, name the offending files in structured --json output, and
#   go green after the claim is amended or the other PR merges. A mutation
#   section proves the sensors can fail by neutering each rule in a copy.
#
# WHY
#   A claim's scope is admitted once, before the work; growth after that was
#   only found at merge time (#568, #565/#566 on 2026-10-25).
#
# USAGE
#   scripts/tests/scope-recheck.test.sh
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

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-scope-recheck.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# gh stub: serves $FIX/{prview.json,claims.tsv,prlist.json}; a missing prview.json is
# gh's "no pull requests found" failure. Anything else is a failed read.
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")  [[ -f "$FIX/prview.json" ]] && { cat "$FIX/prview.json"; exit 0; }
              echo 'no pull requests found for branch "x"' >&2; exit 1 ;;
  "pr list")  cat "$FIX/prlist.json"; exit 0 ;;
  "api graphql") cat "$FIX/claims.tsv"; exit 0 ;;
esac
echo "gh stub: unexpected call: $*" >&2
exit 1
GH
chmod +x "$ROOT/bin/gh"

# make_repo NAME — repo with the scripts under test, a docs/ tree and a workflow registry; prints dir.
make_repo() {
  local d="$ROOT/$1"
  mkdir -p "$d/scripts" "$d/config" "$d/docs" "$d/.github/workflows" "$d/fix"
  cp "$REPO_ROOT/scripts/scope-recheck.mjs" "$REPO_ROOT/scripts/pr-claims.sh" \
     "$REPO_ROOT/scripts/sensor-health-lib.mjs" "$d/scripts/"
  cp "$REPO_ROOT/config/sensor-health-observation.v1.json" "$d/config/"
  cp "$REPO_ROOT"/.github/workflows/*.yml "$d/.github/workflows/"
  printf '# one\n' > "$d/docs/30-one.md"
  printf '# idx\n' > "$d/docs/00-INDEX.md"
  printf '# glossary\n' > "$d/docs/00-glossary.md"
  git -C "$d" init -q -b main && printf 'fix/\n' >> "$d/.git/info/exclude" && git -C "$d" add -A && git -C "$d" commit -q -m base
  git -C "$d" remote add origin https://github.com/acme/app.git
  git -C "$d" checkout -q -b feat/work
  echo "$d"
}

# claim_row NUMBER ISSUE SLUG SCOPE — one pr-claims.sh list row.
claim_row() {
  printf '%s\tissue-%s-%s\t%s\tfeat/%s-%s\thttps://github.com/acme/app/pull/%s\t2026-10-25T00:00:00Z\t2026-10-25T00:00:00Z\tfalse\n' \
    "$1" "$2" "$3" "$4" "$2" "$3" "$1"
}

# check DIR MODE [args] <<<changed — sets OUT (the --json document), RC.
check() {
  local d="$1"; shift
  OUT=$(cd "$d" && FIX="$d/fix" PATH="$ROOT/bin:$PATH" node scripts/scope-recheck.mjs "$@" --json 2>"$d/err"); RC=$?
}
# jq-free structure probe: jget 'expr over j' runs against the parsed OUT document.
jget() { printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{let j;try{j=JSON.parse(s)}catch{console.log("<not-json>");return}console.log(eval(process.argv[1]))})' "$1"; }

# --- 1. scope: outside the claim -> red, amended -> green ------------------------
d=$(make_repo outside)
echo '{"number":570}' > "$d/fix/prview.json"
claim_row 570 568 mine 'scripts/a.sh scripts/lib/**' > "$d/fix/claims.tsv"
echo '[]' > "$d/fix/prlist.json"
check "$d" scope <<<$'scripts/a.sh\nscripts/lib/x.sh\nconfig/sensor-health-observation.v1.json'
[[ "$RC" -eq 1 && "$(jget 'j.findings.length')" == 1 && "$(jget 'j.findings[0].kind')" == outside-scope \
   && "$(jget 'JSON.stringify(j.findings[0].files)')" == '["config/sensor-health-observation.v1.json"]' ]] \
  && ok "change outside the claim scope: exit 1, only the out-of-scope file named" || bad "outside rc=$RC out=$OUT"
claim_row 570 568 mine 'scripts/a.sh scripts/lib/** config/sensor-health-observation.v1.json' > "$d/fix/claims.tsv"
check "$d" scope <<<$'scripts/a.sh\nscripts/lib/x.sh\nconfig/sensor-health-observation.v1.json'
[[ "$RC" -eq 0 && "$(jget 'j.ok')" == true ]] && ok "claim amended to include the file: green" || bad "amended rc=$RC out=$OUT"

# --- 2. scope: file in a live LOWER-numbered claim -> red; merged/higher -> green -
d=$(make_repo lower)
echo '{"number":570}' > "$d/fix/prview.json"
echo '[]' > "$d/fix/prlist.json"
{ claim_row 565 559 drain 'config/sensor-health-observation.v1.json scripts/sensor-health.test.mjs'
  claim_row 570 568 mine 'scripts/a.sh config/sensor-health-observation.v1.json'; } > "$d/fix/claims.tsv"
check "$d" scope <<<$'scripts/a.sh\nconfig/sensor-health-observation.v1.json'
[[ "$RC" -eq 1 && "$(jget 'j.findings.length')" == 1 && "$(jget 'j.findings[0].kind')" == lower-numbered-claim \
   && "$(jget 'j.findings[0].pr')" == 565 && "$(jget 'JSON.stringify(j.findings[0].files)')" == '["config/sensor-health-observation.v1.json"]' ]] \
  && ok "file in the scope of live PR #565 (lower): exit 1 naming #565 and the file" || bad "lower rc=$RC out=$OUT"
claim_row 570 568 mine 'scripts/a.sh config/sensor-health-observation.v1.json' > "$d/fix/claims.tsv"
check "$d" scope <<<$'scripts/a.sh\nconfig/sensor-health-observation.v1.json'
[[ "$RC" -eq 0 ]] && ok "lower-numbered claim merged (gone from the live list): green" || bad "merged rc=$RC out=$OUT"
{ claim_row 575 559 later 'config/sensor-health-observation.v1.json'
  claim_row 570 568 mine 'scripts/a.sh config/sensor-health-observation.v1.json'; } > "$d/fix/claims.tsv"
check "$d" scope <<<$'scripts/a.sh\nconfig/sensor-health-observation.v1.json'
[[ "$RC" -eq 0 ]] && ok "overlap with a HIGHER-numbered claim does not stop us (it yields)" || bad "higher rc=$RC out=$OUT"

# --- 3. scope: containment, not overlap ----------------------------------------
d=$(make_repo contain)
echo '{"number":570}' > "$d/fix/prview.json"; echo '[]' > "$d/fix/prlist.json"
claim_row 570 568 mine 'scripts/*' > "$d/fix/claims.tsv"
check "$d" scope <<<$'scripts/a.sh\nscripts/lib/deep.sh'
[[ "$RC" -eq 1 && "$(jget 'JSON.stringify(j.findings[0].files)')" == '["scripts/lib/deep.sh"]' ]] \
  && ok "'dir/*' covers one level only; a deeper file is outside" || bad "contain rc=$RC out=$OUT"
claim_row 570 568 mine 'scripts' > "$d/fix/claims.tsv"
check "$d" scope <<<$'scripts/lib/deep.sh\nscriptsX/y.sh'
[[ "$RC" -eq 1 && "$(jget 'JSON.stringify(j.findings[0].files)')" == '["scriptsX/y.sh"]' ]] \
  && ok "bare directory token is a path-boundary prefix (scriptsX is outside)" || bad "boundary rc=$RC out=$OUT"

# --- 4. scope: no PR yet -> skipped (4); unreadable evidence -> NOT RUN (2) -----
d=$(make_repo nopr)
: > "$d/fix/claims.tsv"; echo '[]' > "$d/fix/prlist.json"
check "$d" scope <<<$'scripts/a.sh'
RAW=$(cd "$d" && FIX="$d/fix" PATH="$ROOT/bin:$PATH" node scripts/scope-recheck.mjs scope <<<'a' 2>&1); rrc=$?
[[ "$rrc" -eq 4 && "${RAW%%$'\n'*}" == "no pull request for this branch yet;"* ]] && ok "branch with no PR yet: exit 4 with the reason on line 1" || bad "nopr rc=$rrc raw=$RAW"
echo '{"number":570}' > "$d/fix/prview.json"
check "$d" scope <<<$'scripts/a.sh'
[[ "$RC" -eq 2 ]] && ok "PR with no live claim row: exit 2 (cannot compare), never a pass" || bad "noclaim rc=$RC"
printf 'garbage\n' > "$d/fix/claims.tsv"
check "$d" scope <<<$'scripts/a.sh'
[[ "$RC" -eq 2 ]] && ok "malformed claim row: exit 2" || bad "malformed rc=$RC"

# --- 5. docs numbers -----------------------------------------------------------
d=$(make_repo docs)
echo '[]' > "$d/fix/prlist.json"
check "$d" docs-numbers --base HEAD <<<$'docs/31-mine.md'
[[ "$RC" -eq 0 ]] && ok "main's own docs/00- pair is one party; a fresh docs/31- is green" || bad "docs clean rc=$RC out=$OUT"
echo '[{"number":565,"files":[{"path":"docs/31-drain-ratchet.md"},{"path":"docs/00-INDEX.md"}]}]' > "$d/fix/prlist.json"
check "$d" docs-numbers --base HEAD <<<$'docs/31-mine.md'
[[ "$RC" -eq 1 && "$(jget 'j.findings.length')" == 1 && "$(jget 'j.findings[0].kind')" == docs-number-reused && "$(jget 'j.findings[0].number')" == 31 \
   && "$(jget 'JSON.stringify(j.findings[0].parties)')" == '{"PR #565":["docs/31-drain-ratchet.md"],"this branch":["docs/31-mine.md"]}' ]] \
  && ok "docs/31- in an open PR and on this branch: exit 1 naming both parties" || bad "docs dup rc=$RC out=$OUT"
echo '[{"number":565,"files":[{"path":"docs/31-a.md"}]},{"number":566,"files":[{"path":"docs/31-b.md"}]}]' > "$d/fix/prlist.json"
check "$d" docs-numbers --base HEAD <<<$'README.md'
[[ "$RC" -eq 1 && "$(jget 'Object.keys(j.findings[0].parties).sort().join("|")')" == 'PR #565|PR #566' ]] \
  && ok "docs/31- in two OTHER open PRs: exit 1 (the planted cross-PR duplicate)" || bad "docs two-pr rc=$RC out=$OUT"
check "$d" docs-numbers --mine --base HEAD <<<$'docs/32-mine.md'
[[ "$RC" -eq 0 && "$(jget 'j.ok')" == true ]] && ok "--mine: two OTHER PRs colliding on docs/31- does not block this branch" || bad "docs mine-other rc=$RC out=$OUT"
check "$d" docs-numbers --mine --base HEAD <<<$'docs/31-mine.md'
[[ "$RC" -eq 1 && "$(jget 'j.findings[0].number')" == 31 ]] && ok "--mine: a branch adding docs/31- into that collision still fails" || bad "docs mine-in rc=$RC out=$OUT"
echo '[{"number":565,"files":[{"path":"docs/30-one.md"}]}]' > "$d/fix/prlist.json"
check "$d" docs-numbers --base HEAD <<<$'docs/32-mine.md'
[[ "$RC" -eq 0 ]] && ok "a PR that merely edits an existing docs file is not a new claim on its number" || bad "docs edit rc=$RC out=$OUT"
echo '[{"number":565,"files":[{"path":"docs/31-a.md"}]}]' > "$d/fix/prlist.json"
check "$d" docs-numbers --base HEAD <<<$'docs/31-a.md'
[[ "$RC" -eq 0 ]] && ok "this branch's pushed file listed under its own PR is not a duplicate of itself" || bad "docs self rc=$RC out=$OUT"
printf 'docs/31-a.md\n' | (cd "$d" && FIX="$d/fix" PATH="$ROOT/bin:$PATH" node scripts/scope-recheck.mjs docs-numbers --base HEAD --pr 565 >/dev/null 2>&1); [[ $? -eq 0 ]] \
  && ok "--pr excludes the current PR from the other-PR list" || bad "docs --pr"
echo 'nope' > "$d/fix/prlist.json"
check "$d" docs-numbers --base HEAD <<<$'x'
[[ "$RC" -eq 2 ]] && ok "malformed gh output: exit 2" || bad "docs malformed rc=$RC"

# --- 6. workflows registered ---------------------------------------------------
d=$(make_repo wf)
check "$d" workflows </dev/null
[[ "$RC" -eq 0 ]] && ok "every checked-in workflow registered: green" || bad "wf clean rc=$RC out=$OUT"
printf 'name: new\non: push\njobs: {}\n' > "$d/.github/workflows/new-thing.yml"
check "$d" workflows </dev/null
[[ "$RC" -eq 1 && "$(jget 'JSON.stringify(j.findings.map(f=>f.path))')" == '[".github/workflows/new-thing.yml"]' \
   && "$(jget 'j.findings[0].kind')" == unregistered-workflow ]] \
  && ok "workflow with no policy: exit 1 naming the file" || bad "wf unregistered rc=$RC out=$OUT"
node -e '
const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));
j.policies.push({path:".github/workflows/new-thing.yml",mode:"freshness",events:["push"],windowDays:2});
fs.writeFileSync(p,JSON.stringify(j,null,2));' "$d/config/sensor-health-observation.v1.json"
check "$d" workflows </dev/null
[[ "$RC" -eq 0 ]] && ok "registering the workflow turns it green" || bad "wf registered rc=$RC out=$OUT"

# --- 7. prepush wiring ---------------------------------------------------------
# The real prepush.sh in a fixture whose gh stub serves a claim: the probes must
# run and a planted out-of-scope change must make prepush exit 1 with the probe named.
d=$(make_repo wired)
mkdir -p "$d/scripts/lib" "$d/playbooks/recipes"
cp "$REPO_ROOT/scripts/prepush.sh" "$d/scripts/"
cp "$REPO_ROOT/scripts/lib/convention-probes.sh" "$REPO_ROOT/scripts/lib/wall-timeout.sh" "$REPO_ROOT/scripts/lib/agent-vendor.sh" "$d/scripts/lib/"
cp "$REPO_ROOT/config/review-evidence.v1.json" "$d/config/"
printf 'if (process.argv.length > 2) { console.error("unknown flag: " + process.argv[2]); process.exit(2); }\nprocess.exit(0);\n' > "$d/scripts/sensor-reachability.mjs"
printf '# builder\n' > "$d/playbooks/builder.md"
printf '# playbook: playbooks/builder.md\n# playbook-sha256: %s\n' "$(shasum -a 256 "$d/playbooks/builder.md" | awk '{print $1}')" > "$d/playbooks/recipes/builder.yaml"
git -C "$d" add -A && git -C "$d" commit -q -m fixtures
printf 'x\n' > "$d/stray.txt"
echo '{"number":570}' > "$d/fix/prview.json"; echo '[]' > "$d/fix/prlist.json"
claim_row 570 568 mine 'scripts/a.sh' > "$d/fix/claims.tsv"
wired() { OUT=$(cd "$d" && FIX="$d/fix" AGENT_VENDOR_EVALUATOR="$REPO_ROOT/scripts/pr-review-evidence.mjs" PATH="$ROOT/bin:$PATH" bash scripts/prepush.sh --base HEAD --no-tests 2>&1); RC=$?; }
wired
[[ "$RC" -eq 1 && "$OUT" == *"FAIL     claim-scope"* && "$(printf '%s\n' "$OUT" | tail -n 1)" == *"FAILED"*"claim-scope"* ]] \
  && ok "prepush: a file outside the claim scope fails the claim-scope probe" || bad "wired red rc=$RC out=$OUT"
claim_row 570 568 mine 'scripts/a.sh stray.txt' > "$d/fix/claims.tsv"
wired
claim_line=$(printf '%s\n' "$OUT" | awk '$1=="PASS" && $2=="claim-scope"')
[[ "$RC" -eq 0 && -n "$claim_line" ]] && ok "prepush: amending the claim turns claim-scope green and prepush clear" || bad "wired green rc=$RC out=$OUT"
printf 'name: x\non: push\njobs: {}\n' > "$d/.github/workflows/unreg.yml"
wired
[[ "$RC" -eq 1 && "$(printf '%s\n' "$OUT" | tail -n 1)" == *"workflows-registered"* ]] \
  && ok "prepush: an unregistered workflow fails workflows-registered locally, not only in CI" || bad "wired wf rc=$RC out=$OUT"
rm -f "$d/.github/workflows/unreg.yml"
rm -f "$d/fix/prview.json"
wired
[[ "$RC" -eq 0 && "$OUT" == *"SKIPPED  claim-scope"* ]] && ok "prepush: before the claim PR exists claim-scope is SKIPPED, not failed" || bad "wired skip rc=$RC out=$OUT"

# --- 8. mutation proof: each rule neutered in a copy must make its case pass wrongly
# mutate NAME SED-EXPR FILE-REL — copy the scripts, apply the edit, return the dir.
mutate() {
  local d; d=$(make_repo "mut-$1")
  sed -i.bak "$2" "$d/scripts/scope-recheck.mjs" && rm -f "$d/scripts/scope-recheck.mjs.bak"
  cmp -s "$d/scripts/scope-recheck.mjs" "$REPO_ROOT/scripts/scope-recheck.mjs" && { echo "$1: mutation did not change the file" >&2; return 1; }
  echo "$d"
}
d=$(mutate noscope 's/const outside = files.filter(.*/const outside = [];/') || bad "mutation noscope did not apply"
echo '{"number":570}' > "$d/fix/prview.json"; echo '[]' > "$d/fix/prlist.json"
claim_row 570 568 mine 'scripts/a.sh' > "$d/fix/claims.tsv"
check "$d" scope <<<$'scripts/a.sh\nstray.txt'
[[ "$RC" -eq 0 ]] && ok "mutation (scope comparison removed): planted out-of-scope change goes undetected, so the case above is a real sensor" || bad "mutation noscope still red rc=$RC"
d=$(mutate nolower 's/if (other.number >= pr) continue;/continue;/') || bad "mutation nolower did not apply"
echo '{"number":570}' > "$d/fix/prview.json"; echo '[]' > "$d/fix/prlist.json"
{ claim_row 565 559 drain 'stray.txt'; claim_row 570 568 mine 'stray.txt'; } > "$d/fix/claims.tsv"
check "$d" scope <<<$'stray.txt'
[[ "$RC" -eq 0 ]] && ok "mutation (lower-claim loop removed): planted overlap goes undetected" || bad "mutation nolower still red rc=$RC"
d=$(mutate nodocs 's/parties.size > 1/parties.size > 99/') || bad "mutation nodocs did not apply"
echo '[{"number":565,"files":[{"path":"docs/31-a.md"}]}]' > "$d/fix/prlist.json"
check "$d" docs-numbers --base HEAD <<<$'docs/31-b.md'
[[ "$RC" -eq 0 ]] && ok "mutation (duplicate threshold raised): planted docs/31- duplicate goes undetected" || bad "mutation nodocs still red rc=$RC"
d=$(mutate nowf 's/const bad = rows.filter((r) => r.joinError);/const bad = [];/') || bad "mutation nowf did not apply"
printf 'name: new\non: push\njobs: {}\n' > "$d/.github/workflows/new-thing.yml"
check "$d" workflows </dev/null
[[ "$RC" -eq 0 ]] && ok "mutation (join errors ignored): unregistered workflow goes undetected" || bad "mutation nowf still red rc=$RC"

# --- usage ---------------------------------------------------------------------
h=$(node "$REPO_ROOT/scripts/scope-recheck.mjs" --help 2>&1); hrc=$?
[[ "$hrc" -eq 0 && "$h" == *"WHAT IT DOES"* && "$h" == *"RISKS"* ]] && ok "--help exits 0 and names WHAT IT DOES and RISKS" || bad "help rc=$hrc"
node "$REPO_ROOT/scripts/scope-recheck.mjs" --nope >/dev/null 2>&1 </dev/null; [[ $? -eq 2 ]] && ok "unknown flag exits 2" || bad "unknown flag"

echo "scope-recheck.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
