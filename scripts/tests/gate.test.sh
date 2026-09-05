#!/usr/bin/env bash
# gate.test.sh — adversarial sensors for test-integrity (issue #70)
#
# WHY
#   The green gate used to treat "deleted the failing test" the same as
#   "fixed the failing test." Models optimizing for green discover that
#   immediately. These cases pin the unattended-merge safety control:
#   count drops and skip inflation hard-fail with exact deltas; only an
#   exact visible waiver may authorize a reduction; hidden/near/wrong-delta
#   waivers fail closed; metric garbage never becomes zero; baseline
#   regeneration is an explicit journaled act; a local/gitignored baseline
#   cannot authorize a PR. Phase-2 wires the protected CI template in
#   ci/gibson-gate.yml (four-job isolate: resolve/base/head/final) with offline
#   adversarial sensors that pin the contract without claiming live activation.
#
# USAGE
#   scripts/tests/gate.test.sh
#   scripts/tests/gate.test.sh --self-contract
#
# Ordinary no-argument path: lightweight generated gate.json metrics only.
# It is discovered by run-all.sh and MUST remain non-recursive (never invoke
# --self-contract or the production run-all suite).
# Opt-in --self-contract: disjoint exact-SHA production baseline fixture.
set -uo pipefail

# Hermetic git identity (#101): suites that commit must not read ambient global
# user.name/email. Pass with HOME pointed at an empty directory.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"


SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TI="$SCRIPT_DIR/../test-integrity.mjs"
GATE="$SCRIPT_DIR/../gate.sh"
BASELINE_SH="$SCRIPT_DIR/../gate-baseline.sh"
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "gate.test.sh: node is required"; exit 1; }
command -v git  >/dev/null || { echo "gate.test.sh: git is required"; exit 1; }

# --- opt-in --self-contract path (exact-SHA production baseline; disjoint) ---
# Resolves SOURCE_SHA from the committed candidate under review, checks out
# that exact SHA in a clean detached fixture, and runs the one full
# production gate-baseline. Unknown flags fail. This function is never
# called from the ordinary no-argument path below.
SELF_CONTRACT_FIXTURE=""
SELF_CONTRACT_KIND=""
cleanup_self_contract() {
  if [[ -z "${SELF_CONTRACT_FIXTURE:-}" ]]; then
    return 0
  fi
  if [[ "${SELF_CONTRACT_KIND:-}" == worktree ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$SELF_CONTRACT_FIXTURE" >/dev/null 2>&1 \
      || rm -rf "$SELF_CONTRACT_FIXTURE"
  else
    rm -rf "$SELF_CONTRACT_FIXTURE"
  fi
  SELF_CONTRACT_FIXTURE=""
}

run_self_contract() {
  local SOURCE_SHA fixture_sha base_out elapsed t0 rc out recorded_sha recorded_test
  local fixture_helper fixture_root fixture_helper_dir resolved_helper
  SOURCE_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD) || {
    bad "self-contract: git rev-parse HEAD failed"
    return 1
  }
  case "$SOURCE_SHA" in
    *[!0-9a-f]*) bad "self-contract: HEAD SHA is not hex: $SOURCE_SHA"; return 1 ;;
  esac
  if [[ ${#SOURCE_SHA} -ne 40 && ${#SOURCE_SHA} -ne 64 ]]; then
    bad "self-contract: HEAD SHA length ${#SOURCE_SHA} is not 40 or 64"
    return 1
  fi
  echo "self-contract: SOURCE_SHA=$SOURCE_SHA"

  SELF_CONTRACT_FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/gibson-self-contract.XXXXXX") || {
    bad "self-contract: mktemp failed"
    return 1
  }
  rmdir "$SELF_CONTRACT_FIXTURE" || true
  SELF_CONTRACT_KIND=""
  if git -C "$REPO_ROOT" worktree add --detach "$SELF_CONTRACT_FIXTURE" "$SOURCE_SHA" >/dev/null 2>&1; then
    SELF_CONTRACT_KIND=worktree
  else
    mkdir -p "$SELF_CONTRACT_FIXTURE"
    if git clone --local --quiet "$REPO_ROOT" "$SELF_CONTRACT_FIXTURE" >/dev/null 2>&1 \
      && git -C "$SELF_CONTRACT_FIXTURE" checkout --detach --quiet "$SOURCE_SHA" >/dev/null 2>&1; then
      SELF_CONTRACT_KIND=clone
    else
      bad "self-contract: could not create detached fixture at $SOURCE_SHA"
      rm -rf "$SELF_CONTRACT_FIXTURE"
      SELF_CONTRACT_FIXTURE=""
      return 1
    fi
  fi
  trap cleanup_self_contract EXIT

  fixture_sha=$(git -C "$SELF_CONTRACT_FIXTURE" rev-parse HEAD) || {
    bad "self-contract: fixture rev-parse failed"
    return 1
  }
  if [[ "$fixture_sha" == "$SOURCE_SHA" ]]; then
    ok "self-contract: fixture HEAD equals SOURCE_SHA"
  else
    bad "self-contract: fixture HEAD $fixture_sha != SOURCE_SHA $SOURCE_SHA"
    return 1
  fi
  if [[ -n "$(git -C "$SELF_CONTRACT_FIXTURE" status --porcelain)" ]]; then
    bad "self-contract: fixture is not clean (untracked/dirty files present)"
    return 1
  else
    ok "self-contract: fixture working tree is clean"
  fi

  # Isolated baseline; ignore developer env overrides and preexisting files.
  unset GIBSON_GENERATE GIBSON_TYPECHECK GIBSON_LINT GIBSON_TEST GIBSON_BUILD
  unset GIBSON_TEST_INTEGRITY_TEXT
  base_out="$SELF_CONTRACT_FIXTURE/.gibson-self-contract-baseline.json"
  if [[ -e "$base_out" ]]; then
    bad "self-contract: isolated baseline path already exists"
    return 1
  fi

  # Exact-SHA authority: invoke the fixture-owned helper, never the mutable
  # source-tree BASELINE_SH. An uncommitted edit of the source helper must not
  # be able to forge evidence attributed to SOURCE_SHA. Any helper path must
  # resolve inside the fixture (regular file; no symlink escape).
  fixture_helper="$SELF_CONTRACT_FIXTURE/scripts/gate-baseline.sh"
  if [[ -L "$fixture_helper" ]]; then
    bad "self-contract: fixture helper is a symlink (must be the exact candidate file)"
    return 1
  fi
  if [[ ! -f "$fixture_helper" ]]; then
    bad "self-contract: fixture helper missing at $fixture_helper"
    return 1
  fi
  fixture_root=$(CDPATH='' cd -- "$SELF_CONTRACT_FIXTURE" && pwd) || {
    bad "self-contract: could not resolve fixture root"
    return 1
  }
  fixture_helper_dir=$(CDPATH='' cd -- "$(dirname -- "$fixture_helper")" && pwd) || {
    bad "self-contract: could not resolve fixture helper directory"
    return 1
  }
  resolved_helper="${fixture_helper_dir}/$(basename -- "$fixture_helper")"
  case "$resolved_helper" in
    "$fixture_root"/*) ;;
    *)
      bad "self-contract: helper path escaped fixture: $resolved_helper"
      return 1
      ;;
  esac

  echo "self-contract: running one full production gate-baseline (no focused substitute)"
  t0=$SECONDS
  out=$(cd "$SELF_CONTRACT_FIXTURE" && bash "$SELF_CONTRACT_FIXTURE/scripts/gate-baseline.sh" --out "$base_out" 2>&1)
  rc=$?
  elapsed=$((SECONDS - t0))
  echo "self-contract: gate-baseline wall ${elapsed}s"
  printf '%s\n' "$out" | grep -E 'wall:| ok | FAIL |run-all:' | tail -n 40 | sed 's/^/         /'

  if [[ "$rc" -ne 0 ]]; then
    bad "self-contract: gate-baseline.sh exited $rc"
    printf '%s\n' "$out" | tail -n 30 | sed 's/^/         /'
    return 1
  fi
  if [[ ! -f "$base_out" ]]; then
    bad "self-contract: baseline file missing at $base_out"
    return 1
  fi
  ok "self-contract: gate-baseline.sh exited 0"

  recorded_sha=$(node -e '
    const fs=require("fs");
    const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    if(!j.test_metrics || typeof j.test_metrics.total!=="number") process.exit(2);
    process.stdout.write(String(j.git_sha||""));
  ' "$base_out") || {
    bad "self-contract: baseline is not parseable / lacks test_metrics"
    return 1
  }
  if [[ "$recorded_sha" == "$SOURCE_SHA" ]]; then
    ok "self-contract: recorded git_sha equals SOURCE_SHA"
  else
    bad "self-contract: recorded git_sha $recorded_sha != SOURCE_SHA $SOURCE_SHA"
    return 1
  fi
  recorded_test=$(node -e '
    const fs=require("fs");
    const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    process.stdout.write(String((j.commands&&j.commands.test)||""));
  ' "$base_out")
  if [[ "$recorded_test" == "bash scripts/tests/run-all.sh --no-quarantine" ]]; then
    ok "self-contract: baseline recorded the canonical --no-quarantine test command"
  else
    bad "self-contract: baseline test command was '$recorded_test'"
    return 1
  fi
}

SELF_CONTRACT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-contract)
      SELF_CONTRACT=1
      shift
      ;;
    -h|--help)
      echo "Usage: scripts/tests/gate.test.sh [--self-contract]"
      exit 0
      ;;
    *)
      echo "gate.test.sh: unknown flag: $1" >&2
      echo "Usage: scripts/tests/gate.test.sh [--self-contract]" >&2
      exit 2
      ;;
  esac
done

if [[ "$SELF_CONTRACT" -eq 1 ]]; then
  run_self_contract
  echo
  echo "gate.test.sh: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]]
  exit $?
fi

# --- ordinary no-argument path (non-recursive; disjoint from --self-contract) ---

# Lightweight static pin of the --self-contract authority boundary. Does not
# run the full exact-SHA suite (that path is opt-in and may not run while
# this worktree is uncommitted).
{
  _gt="$SCRIPT_DIR/gate.test.sh"
  if grep -Fq 'bash "$SELF_CONTRACT_FIXTURE/scripts/gate-baseline.sh"' "$_gt"; then
    ok "self-contract source invokes \$SELF_CONTRACT_FIXTURE/scripts/gate-baseline.sh"
  else
    bad "self-contract source missing fixture-owned gate-baseline.sh invocation"
  fi
  if awk '
    /^run_self_contract\(\)/ { p=1 }
    p && /bash[[:space:]]+"\$BASELINE_SH"/ { hit=1 }
    p && /^SELF_CONTRACT=/ { p=0 }
    END { exit hit ? 0 : 1 }
  ' "$_gt"; then
    bad "self-contract source still invokes mutable \$BASELINE_SH (forges SOURCE_SHA)"
  else
    ok "self-contract source does not invoke mutable \$BASELINE_SH"
  fi
  if grep -Fq 'helper path escaped fixture' "$_gt" \
    && grep -Fq '"$fixture_root"/*' "$_gt"; then
    ok "self-contract source requires helper path to resolve inside the fixture"
  else
    bad "self-contract source missing in-fixture helper path bound"
  fi
  unset _gt
}

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-gate-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

write_metrics() { # file total skipped todo
  cat > "$1" <<EOF
{"total": $2, "skipped": $3, "todo": $4}
EOF
}

compare() { # base head waiver_text [trusted]
  local base="$1" head="$2" waiver="${3:-}" trusted="${4:-baseline}"
  node "$TI" compare --base "$base" --head "$head" \
    --waiver-text "$waiver" --trusted-source "$trusted" 2>&1
}

# ---------------------------------------------------------------------------
echo "unknown flags fail closed (ordinary path stays non-recursive)"
# ---------------------------------------------------------------------------
unk_out=$(bash "$SCRIPT_DIR/gate.test.sh" --not-a-real-flag 2>&1); unk_rc=$?
if [[ "$unk_rc" -eq 2 ]] && printf '%s\n' "$unk_out" | grep 'unknown flag: --not-a-real-flag' >/dev/null; then
  ok "unknown flag exits 2 without running fixtures"
else
  bad "unknown flag (rc=$unk_rc): $unk_out"
fi

# ---------------------------------------------------------------------------
echo "deletion without waiver hard-fails with exact total delta"
# ---------------------------------------------------------------------------
write_metrics "$ROOT/b1.json" 10 0 0
write_metrics "$ROOT/h1.json" 7 0 0
out=$(compare "$ROOT/b1.json" "$ROOT/h1.json" ""); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep 'test-integrity' >/dev/null \
  && echo "$out" | grep -E 'dropped by 3|removed 3' >/dev/null \
  && echo "$out" | grep '10' >/dev/null && echo "$out" | grep '7' >/dev/null; then
  ok "deletion/no waiver fails with test-integrity and delta 3 (10→7)"
else
  bad "deletion/no waiver (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "new skip/todo without waiver hard-fails with exact skip delta"
# ---------------------------------------------------------------------------
write_metrics "$ROOT/b2.json" 10 0 0
write_metrics "$ROOT/h2.json" 10 2 1
out=$(compare "$ROOT/b2.json" "$ROOT/h2.json" ""); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep 'test-integrity' >/dev/null \
  && echo "$out" | grep -E 'skip/todo rose by 3|skip \+3' >/dev/null; then
  ok "new skip/todo/no waiver fails with exact skip delta 3"
else
  bad "new skip/no waiver (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "exact visible delta-consistent waiver passes and is surfaced"
# ---------------------------------------------------------------------------
write_metrics "$ROOT/b3.json" 10 1 0
write_metrics "$ROOT/h3.json" 8 2 0
waiver=$'## Notes\nTest-integrity: removed 2 for obsolete fixtures after #70\nTest-integrity: skip +1 for flaky external API pending #71\n'
out=$(compare "$ROOT/b3.json" "$ROOT/h3.json" "$waiver"); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep 'WAIVER accepted' >/dev/null \
  && echo "$out" | grep 'removed 2' >/dev/null && echo "$out" | grep 'skip +1' >/dev/null \
  && echo "$out" | grep 'obsolete fixtures' >/dev/null; then
  ok "exact visible delta-consistent waiver passes and surfaces reason"
else
  bad "exact waiver (rc=$rc): $out"
fi

# Combined single-line form
waiver2='Test-integrity: removed 2, skip +1 for both intentional under #70'
out=$(compare "$ROOT/b3.json" "$ROOT/h3.json" "$waiver2"); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'WAIVER accepted' >/dev/null \
  && ok "combined waiver line accepted" \
  || bad "combined waiver (rc=$rc): $out"

# Leading markdown list dash
waiver3='- Test-integrity: removed 2 for obsolete fixtures after #70
- Test-integrity: skip +1 for flaky external API'
out=$(compare "$ROOT/b3.json" "$ROOT/h3.json" "$waiver3"); rc=$?
[[ "$rc" -eq 0 ]] && ok "markdown-list waiver form accepted" \
  || bad "markdown-list waiver (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "hidden / near-match / wrong-delta waivers fail closed"
# ---------------------------------------------------------------------------
# Hidden in HTML comment
hidden=$'Looks fine\n<!--\nTest-integrity: removed 3 for secretly gone\n-->\n'
write_metrics "$ROOT/b4.json" 10 0 0
write_metrics "$ROOT/h4.json" 7 0 0
out=$(compare "$ROOT/b4.json" "$ROOT/h4.json" "$hidden"); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep 'dropped by 3' >/dev/null \
  && ! echo "$out" | grep 'WAIVER accepted' >/dev/null; then
  ok "HTML-comment waiver cannot authorize a deletion"
else
  bad "hidden HTML waiver (rc=$rc): $out"
fi

# Near-match labels / spellings
for near in \
  'test-integrity: removed 3 for almost' \
  'Test integrity: removed 3 for almost' \
  'Test-Integrity: removed 3 for almost' \
  'Test-integrity: remove 3 for almost' \
  'Test-integrity: removed 3 obsolete tests' \
  'Test-integrity: intentional #70' \
  'Test-integrity: removed three for almost'
do
  out=$(compare "$ROOT/b4.json" "$ROOT/h4.json" "$near"); rc=$?
  if [[ "$rc" -ne 0 ]]; then
    ok "near-match fails closed: ${near:0:40}…"
  else
    bad "near-match wrongly accepted: $near"
  fi
done

# Wrong delta
out=$(compare "$ROOT/b4.json" "$ROOT/h4.json" \
  'Test-integrity: removed 2 for undercount'); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -i 'wrong delta' >/dev/null; then
  ok "wrong-delta waiver fails closed"
else
  bad "wrong-delta waiver (rc=$rc): $out"
fi

# Wrong skip delta
write_metrics "$ROOT/b4s.json" 10 0 0
write_metrics "$ROOT/h4s.json" 10 4 0
out=$(compare "$ROOT/b4s.json" "$ROOT/h4s.json" \
  'Test-integrity: skip +2 for undercount'); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -i 'wrong delta' >/dev/null; then
  ok "wrong skip-delta waiver fails closed"
else
  bad "wrong skip-delta (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "malformed metrics fail closed (never silently become zero)"
# ---------------------------------------------------------------------------
for badjson in \
  '{"total":"nope","skipped":0,"todo":0}' \
  '{"total":-1,"skipped":0,"todo":0}' \
  '{"total":1.5,"skipped":0,"todo":0}' \
  '{"total":null,"skipped":0,"todo":0}' \
  '{"skipped":0,"todo":0}' \
  '{"total":5,"skipped":-2,"todo":0}' \
  '{"total":2,"skipped":5,"todo":0}'
do
  printf '%s\n' "$badjson" > "$ROOT/bad.json"
  write_metrics "$ROOT/ok.json" 5 0 0
  out=$(compare "$ROOT/ok.json" "$ROOT/bad.json" 2>&1); rc=$?
  if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'unparseable|must be|exceeds|test-integrity' >/dev/null; then
    ok "malformed metrics rejected: ${badjson:0:40}…"
  else
    bad "malformed metrics accepted: $badjson → $out"
  fi
done

# Unparseable runner output
printf 'all good, trust me\n' > "$ROOT/garbage.txt"
out=$(node "$TI" parse --input "$ROOT/garbage.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -i 'could not parse' >/dev/null; then
  ok "unparseable runner output fails closed"
else
  bad "unparseable runner output (rc=$rc): $out"
fi

# Explicit metrics contract
printf 'GIBSON_TEST_METRICS total=12 skipped=1 todo=2\n' > "$ROOT/explicit.txt"
out=$(node "$TI" parse --input "$ROOT/explicit.txt" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 12' >/dev/null \
  && echo "$out" | grep '"skipped": 1' >/dev/null && echo "$out" | grep '"todo": 2' >/dev/null; then
  ok "GIBSON_TEST_METRICS kv contract parses"
else
  bad "explicit kv parse (rc=$rc): $out"
fi

printf 'GIBSON_TEST_METRICS {"total":9,"skipped":0,"todo":1}\n' > "$ROOT/explicitj.txt"
out=$(node "$TI" parse --input "$ROOT/explicitj.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 9' >/dev/null \
  && ok "GIBSON_TEST_METRICS JSON contract parses" \
  || bad "explicit json parse (rc=$rc): $out"

# Vitest / jest / node:test shapes
printf 'Tests  8 passed | 2 skipped (10)\n' > "$ROOT/vitest.txt"
out=$(node "$TI" parse --input "$ROOT/vitest.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null && echo "$out" | grep '"skipped": 2' >/dev/null \
  && ok "vitest summary parses" || bad "vitest parse (rc=$rc): $out"

printf 'Tests:       1 skipped, 9 passed, 10 total\n' > "$ROOT/jest.txt"
out=$(node "$TI" parse --input "$ROOT/jest.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "jest summary parses" || bad "jest parse (rc=$rc): $out"

printf '# tests 10\n# pass 8\n# skip 1\n# todo 1\n# fail 0\n' > "$ROOT/node.txt"
out=$(node "$TI" parse --input "$ROOT/node.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"todo": 1' >/dev/null \
  && ok "node:test counters parse" || bad "node:test parse (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "added tests / reduced skips pass without waiver"
# ---------------------------------------------------------------------------
write_metrics "$ROOT/b5.json" 10 3 0
write_metrics "$ROOT/h5.json" 14 1 0
out=$(compare "$ROOT/b5.json" "$ROOT/h5.json" ""); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -iE 'rose by 4|PASS' >/dev/null; then
  ok "added tests and reduced skips pass without waiver"
else
  bad "improvement path (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "regeneration without flag/reason fails; auditable regeneration works"
# ---------------------------------------------------------------------------
# Build a tiny fake target repo that gate-baseline can run against.
FAKE="$ROOT/fake-repo"
mkdir -p "$FAKE/.agents"
GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"
$GIT init -q "$FAKE"
git -C "$FAKE" symbolic-ref HEAD refs/heads/main
# Gate config: only the test step, a deterministic metrics-emitting command
cat > "$FAKE/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
echo base > "$FAKE/README"
$GIT -C "$FAKE" add -A
$GIT -C "$FAKE" commit -q -m "base"

# First baseline — no regenerate needed
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -qE '"total":[[:space:]]*10' "$FAKE/.gibson-baseline.json"; then
  ok "initial baseline records test_metrics.total=10"
else
  bad "initial baseline (rc=$rc): $out"
fi

# Shrink suite without --regenerate / --reason → refuse
cat > "$FAKE/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=7 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'regenerat|--reason|test-integrity' >/dev/null; then
  ok "baseline reduction without --regenerate/--reason fails closed"
else
  bad "silent baseline shrink (rc=$rc): $out"
fi

# Still has old total
grep -qE '"total":[[:space:]]*10' "$FAKE/.gibson-baseline.json" \
  && ok "refused regenerate left prior baseline intact" \
  || bad "baseline was overwritten despite refusal"

# --regenerate without --reason
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" \
  --regenerate 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -i 'reason' >/dev/null; then
  ok "regenerate without --reason fails closed"
else
  bad "regenerate without reason (rc=$rc): $out"
fi

# --regenerate with empty reason
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" \
  --regenerate --reason '' 2>&1); rc=$?
if [[ "$rc" -ne 0 ]]; then
  ok "regenerate with empty reason fails closed"
else
  bad "empty reason accepted (rc=$rc): $out"
fi

# Legitimate journaled regenerate
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" \
  --regenerate --reason 'removed obsolete suite after #70' 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -qE '"total":[[:space:]]*7' "$FAKE/.gibson-baseline.json"; then
  ok "regenerate with reason rewrites baseline metrics"
else
  bad "journaled regenerate (rc=$rc): $out"
fi

JOURNAL="$FAKE/.gibson/test-integrity-journal.jsonl"
if [[ -f "$JOURNAL" ]] \
  && grep -q 'removed obsolete suite after #70' "$JOURNAL" \
  && grep -qE '"total":[[:space:]]*10' "$JOURNAL" \
  && grep -qE '"total":[[:space:]]*7' "$JOURNAL"; then
  ok "append-only journal records timestamp/reason/old/new metrics"
else
  bad "journal missing or incomplete: $(cat "$JOURNAL" 2>/dev/null || echo none)"
fi

# Second regenerate appends (does not rewrite)
cat > "$FAKE/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=6 skipped=1 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$FAKE" && bash "$BASELINE_SH" --out "$FAKE/.gibson-baseline.json" \
  --regenerate --reason 'one more obsolete under #70' 2>&1); rc=$?
lines=$(wc -l < "$JOURNAL" | tr -d ' ')
if [[ "$rc" -eq 0 && "$lines" -ge 2 ]]; then
  ok "journal is append-only across regenerations (lines=$lines)"
else
  bad "journal append (rc=$rc lines=$lines): $out"
fi

# ---------------------------------------------------------------------------
echo "gate.sh hard-fails on integrity; surfaces waiver; preserves failure baseline"
# ---------------------------------------------------------------------------
# Fresh fake repo for gate.sh
GDIR="$ROOT/gate-run"
mkdir -p "$GDIR/.agents"
$GIT init -q "$GDIR"
git -C "$GDIR" symbolic-ref HEAD refs/heads/main
cat > "$GDIR/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=5 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
echo x > "$GDIR/README"
$GIT -C "$GDIR" add -A
$GIT -C "$GDIR" commit -q -m "g"

# Baseline at 5 tests
(cd "$GDIR" && bash "$BASELINE_SH" --out "$GDIR/.gibson-baseline.json") >/dev/null 2>&1

# Shrink tests → gate must fail with test-integrity
cat > "$GDIR/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=3 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$GDIR" && bash "$GATE" --baseline "$GDIR/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep 'test-integrity' >/dev/null \
  && echo "$out" | grep -E 'dropped by 2|removed 2' >/dev/null; then
  ok "gate.sh fails on deletion with test-integrity diagnosis"
else
  bad "gate.sh deletion (rc=$rc): $out"
fi

# With correct waiver via env (inert PR body)
out=$(cd "$GDIR" && GIBSON_TEST_INTEGRITY_TEXT='Test-integrity: removed 2 for obsolete under #70' \
  bash "$GATE" --baseline "$GDIR/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep 'WAIVER accepted' >/dev/null \
  && echo "$out" | grep 'obsolete under #70' >/dev/null; then
  ok "gate.sh accepts exact waiver and surfaces it for the reviewer"
else
  bad "gate.sh waiver (rc=$rc): $out"
fi

# New skips
cat > "$GDIR/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=5 skipped=2 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$GDIR" && bash "$GATE" --baseline "$GDIR/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep 'test-integrity' >/dev/null \
  && echo "$out" | grep -E 'skip/todo rose by 2|skip \+2' >/dev/null; then
  ok "gate.sh fails on new skips with exact delta"
else
  bad "gate.sh new skips (rc=$rc): $out"
fi

# Restore original lightweight metrics → gate.sh green. This mutation/restore
# fixture is disjoint from --self-contract: it never invokes the production
# run-all suite or the exact-SHA baseline path.
cat > "$GDIR/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=5 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$GDIR" && bash "$GATE" --baseline "$GDIR/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep 'GREEN' >/dev/null; then
  ok "gate.sh returns green after restore of original metrics"
else
  bad "gate.sh restore green (rc=$rc): $out"
fi

# Trusted-source labeling: CI path never treats a local baseline as self-authorizing
write_metrics "$ROOT/ci-base.json" 10 0 0
write_metrics "$ROOT/ci-head.json" 9 0 0
out=$(compare "$ROOT/ci-base.json" "$ROOT/ci-head.json" "" "merge-base"); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep 'merge-base' >/dev/null; then
  ok "compare surfaces trusted-source=merge-base (CI anchor, not local baseline)"
else
  bad "trusted-source labeling (rc=$rc): $out"
fi

# PR text is inert: a payload that would be dangerous if eval'd must stay data
payload='Test-integrity: removed 1 for $(touch '"$ROOT"'/pwned) and `touch '"$ROOT"'/pwned2`'
write_metrics "$ROOT/ev-b.json" 10 0 0
write_metrics "$ROOT/ev-h.json" 9 0 0
out=$(compare "$ROOT/ev-b.json" "$ROOT/ev-h.json" "$payload"); rc=$?
if [[ "$rc" -eq 0 && ! -e "$ROOT/pwned" && ! -e "$ROOT/pwned2" ]]; then
  ok "waiver text is inert data (no shell eval of PR body)"
else
  bad "waiver text may have been evaluated (rc=$rc pwned=$(ls "$ROOT"/pwned* 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
echo "existing green-gate failure comparison is preserved"
# ---------------------------------------------------------------------------
# typecheck newly red must still fail the gate (integrity must not weaken it)
cat > "$GDIR/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "false",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=5 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$GDIR" && bash "$GATE" --baseline "$GDIR/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'typecheck|newly failing|FAIL' >/dev/null; then
  ok "gate.sh still hard-fails on new typecheck failures"
else
  bad "failure baseline weakened (rc=$rc): $out"
fi

# ===========================================================================
# Tier-B review blockers (adversarial sensors — issue #70 repair)
# ===========================================================================

# ---------------------------------------------------------------------------
echo "blocker 1: explicit GIBSON_TEST_METRICS cannot spoof past a real runner summary"
# ---------------------------------------------------------------------------
# Honest vitest summary (7 tests) + fake explicit metrics (10). A head that
# prints both must NOT self-authorize total=10 against a base of 10.
printf 'Tests  7 passed (7)\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/spoof.txt"
out=$(node "$TI" parse --input "$ROOT/spoof.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted' >/dev/null; then
  ok "conflicting explicit+runner metrics fail closed (no self-authorization)"
else
  bad "spoofed explicit metrics accepted or wrong error (rc=$rc): $out"
fi

# Same attack path through compare: if parse ever yielded 10, compare would pass
write_metrics "$ROOT/spoof-base.json" 10 0 0
# Force the only safe outcome: parse must reject, so we also pin that a
# head metrics file of 7 fails integrity vs base 10 without waiver.
write_metrics "$ROOT/spoof-head-honest.json" 7 0 0
out=$(compare "$ROOT/spoof-base.json" "$ROOT/spoof-head-honest.json" ""); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -E 'dropped by 3|removed 3' >/dev/null; then
  ok "honest head total=7 vs base=10 still hard-fails (delta 3)"
else
  bad "honest head compare (rc=$rc): $out"
fi

# Explicit alone (no runner summary) remains the vendor-blind contract
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' > "$ROOT/explicit-only.txt"
out=$(node "$TI" parse --input "$ROOT/explicit-only.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "explicit-only GIBSON_TEST_METRICS still parses" \
  || bad "explicit-only broken (rc=$rc): $out"

# Agreeing sources are fine
printf 'Tests  10 passed (10)\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/agree.txt"
out=$(node "$TI" parse --input "$ROOT/agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "agreeing explicit+runner sources accepted" \
  || bad "agreeing sources (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "blocker 1b: every explicit GIBSON_TEST_METRICS line is collected (no first-match)"
# ---------------------------------------------------------------------------
# Attack: fake total=10 first, then honest total=7. First-match parsers would
# accept 10 and green-wash a deleted suite. Must fail closed on conflict.
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nGIBSON_TEST_METRICS total=7 skipped=0 todo=0\n' \
  > "$ROOT/multi-kv-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/multi-kv-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted' >/dev/null; then
  ok "conflicting multi-explicit KV lines fail closed (not first-match total=10)"
else
  bad "multi-kv first-match bypass (rc=$rc): $out"
fi

# Same attack with JSON after KV
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nGIBSON_TEST_METRICS {"total":7,"skipped":0,"todo":0}\n' \
  > "$ROOT/multi-kv-json-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/multi-kv-json-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted' >/dev/null; then
  ok "conflicting explicit KV then JSON fail closed"
else
  bad "kv+json first-match bypass (rc=$rc): $out"
fi

# Honest first, fake second (order must not matter)
printf 'GIBSON_TEST_METRICS total=7 skipped=0 todo=0\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/multi-kv-conflict-rev.txt"
out=$(node "$TI" parse --input "$ROOT/multi-kv-conflict-rev.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted' >/dev/null; then
  ok "conflicting multi-explicit lines fail regardless of order"
else
  bad "multi-kv reverse-order bypass (rc=$rc): $out"
fi

# Identical multi-explicit lines still agree and parse
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/multi-kv-agree.txt"
out=$(node "$TI" parse --input "$ROOT/multi-kv-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "identical multi-explicit KV lines accepted" \
  || bad "identical multi-explicit broken (rc=$rc): $out"

# Identical KV + JSON
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nGIBSON_TEST_METRICS {"total":10,"skipped":0,"todo":0}\n' \
  > "$ROOT/multi-kv-json-agree.txt"
out=$(node "$TI" parse --input "$ROOT/multi-kv-json-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "identical explicit KV+JSON lines accepted" \
  || bad "identical kv+json broken (rc=$rc): $out"

# Three-way: two fake explicits + honest runner must still conflict
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nTests  7 passed (7)\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/multi-explicit-runner.txt"
out=$(node "$TI" parse --input "$ROOT/multi-explicit-runner.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted' >/dev/null; then
  ok "duplicate fake explicit + honest runner fails closed"
else
  bad "multi-explicit+runner spoof (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker 1c: every native runner summary is collected (no first/last-only)"
# ---------------------------------------------------------------------------
# Untrusted output can print conflicting repeated summaries. First-match or
# last-match parsers hide a real drop even under a future trusted grader.

# Jest: fake 10 then honest 7 (first-match would accept 10)
printf 'Tests: 10 passed, 10 total\nTests: 7 passed, 7 total\n' \
  > "$ROOT/jest-multi-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/jest-multi-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted|native' >/dev/null; then
  ok "conflicting repeated Jest summaries fail closed (not first-match total=10)"
else
  bad "jest multi first-match bypass (rc=$rc): $out"
fi

# node:test: # tests 10 then # tests 7 (with pass/skip counters per block)
printf '# tests 10\n# pass 10\n# skip 0\n# todo 0\n# tests 7\n# pass 7\n# skip 0\n# todo 0\n' \
  > "$ROOT/node-multi-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/node-multi-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted|native' >/dev/null; then
  ok "conflicting repeated node:test counters fail closed (not first-match total=10)"
else
  bad "node:test multi first-match bypass (rc=$rc): $out"
fi

# node:test same total but different skip in second block — must not mix counters
printf '# tests 10\n# skip 0\n# todo 0\n# tests 10\n# skip 5\n# todo 0\n' \
  > "$ROOT/node-multi-skip-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/node-multi-skip-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted|native' >/dev/null; then
  ok "node:test repeated blocks with conflicting skip fail closed (no mixed counters)"
else
  bad "node:test mixed-skip fabrication (rc=$rc): $out"
fi

# TAP plans: 1..10 then 1..7
printf '1..10\nok 1 - a\nok 2 - b\n1..7\nok 1 - c\n' \
  > "$ROOT/tap-multi-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/tap-multi-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted|native' >/dev/null; then
  ok "conflicting repeated TAP plans fail closed (not first-match 1..10)"
else
  bad "tap multi first-match bypass (rc=$rc): $out"
fi

# Vitest: honest 7 then fake-last 10 (last-match would accept 10)
printf 'Tests  7 passed (7)\nTests  10 passed (10)\n' \
  > "$ROOT/vitest-multi-honest-first.txt"
out=$(node "$TI" parse --input "$ROOT/vitest-multi-honest-first.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted|native' >/dev/null; then
  ok "conflicting Vitest summaries fail closed (not last-match total=10)"
else
  bad "vitest last-match bypass (rc=$rc): $out"
fi

# Vitest reverse: fake 10 then honest 7 (must still fail; order irrelevant)
printf 'Tests  10 passed (10)\nTests  7 passed (7)\n' \
  > "$ROOT/vitest-multi-honest-last.txt"
out=$(node "$TI" parse --input "$ROOT/vitest-multi-honest-last.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple sources|untrusted|native' >/dev/null; then
  ok "conflicting Vitest summaries fail regardless of order"
else
  bad "vitest reverse-order bypass (rc=$rc): $out"
fi

# Identical repeated native summaries still agree
printf 'Tests: 10 passed, 10 total\nTests: 10 passed, 10 total\n' \
  > "$ROOT/jest-multi-agree.txt"
out=$(node "$TI" parse --input "$ROOT/jest-multi-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "identical repeated Jest summaries accepted" \
  || bad "identical jest multi broken (rc=$rc): $out"

printf '# tests 10\n# skip 0\n# tests 10\n# skip 0\n' \
  > "$ROOT/node-multi-agree.txt"
out=$(node "$TI" parse --input "$ROOT/node-multi-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "identical repeated node:test counters accepted" \
  || bad "identical node multi broken (rc=$rc): $out"

printf '1..10\nok 1\n1..10\nok 2\n' \
  > "$ROOT/tap-multi-agree.txt"
out=$(node "$TI" parse --input "$ROOT/tap-multi-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "identical repeated TAP plans accepted" \
  || bad "identical tap multi broken (rc=$rc): $out"

printf 'Tests  10 passed (10)\nTests  10 passed (10)\n' \
  > "$ROOT/vitest-multi-agree.txt"
out=$(node "$TI" parse --input "$ROOT/vitest-multi-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "identical repeated Vitest summaries accepted" \
  || bad "identical vitest multi broken (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "blocker 1d: node:test collects every # skip/# todo in a tests region"
# ---------------------------------------------------------------------------
# First-match # skip 0 then # skip 2 would parse skipped=0 and green-wash.
# Collect every counter in the region; identical may agree; disagreement fails.

# Order A: # skip 0 then # skip 2 (first-match would accept 0)
printf '# tests 10\n# pass 8\n# skip 0\n# skip 2\n# todo 0\n' \
  > "$ROOT/node-skip-order-a.txt"
out=$(node "$TI" parse --input "$ROOT/node-skip-order-a.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple|untrusted|skip' >/dev/null; then
  ok "node:test # skip 0 then # skip 2 fails closed (not first-match skip=0)"
else
  bad "node skip order-a first-match bypass (rc=$rc): $out"
fi

# Order B: # skip 2 then # skip 0 (first-match would accept 2; still must fail)
printf '# tests 10\n# pass 8\n# skip 2\n# skip 0\n# todo 0\n' \
  > "$ROOT/node-skip-order-b.txt"
out=$(node "$TI" parse --input "$ROOT/node-skip-order-b.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple|untrusted|skip' >/dev/null; then
  ok "node:test # skip 2 then # skip 0 fails closed (not first-match skip=2)"
else
  bad "node skip order-b first-match bypass (rc=$rc): $out"
fi

# Identical repeated # skip inside one region may agree
printf '# tests 10\n# pass 8\n# skip 2\n# skip 2\n# todo 0\n' \
  > "$ROOT/node-skip-identical.txt"
out=$(node "$TI" parse --input "$ROOT/node-skip-identical.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"skipped": 2' >/dev/null && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "node:test identical repeated # skip 2 accepted" \
  || bad "node identical skip broken (rc=$rc): $out"

# Order A todo: # todo 0 then # todo 2
printf '# tests 10\n# pass 8\n# skip 0\n# todo 0\n# todo 2\n' \
  > "$ROOT/node-todo-order-a.txt"
out=$(node "$TI" parse --input "$ROOT/node-todo-order-a.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple|untrusted|todo' >/dev/null; then
  ok "node:test # todo 0 then # todo 2 fails closed (not first-match todo=0)"
else
  bad "node todo order-a first-match bypass (rc=$rc): $out"
fi

# Order B todo: # todo 2 then # todo 0
printf '# tests 10\n# pass 8\n# skip 0\n# todo 2\n# todo 0\n' \
  > "$ROOT/node-todo-order-b.txt"
out=$(node "$TI" parse --input "$ROOT/node-todo-order-b.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple|untrusted|todo' >/dev/null; then
  ok "node:test # todo 2 then # todo 0 fails closed (not first-match todo=2)"
else
  bad "node todo order-b first-match bypass (rc=$rc): $out"
fi

# Identical repeated # todo inside one region may agree
printf '# tests 10\n# pass 8\n# skip 0\n# todo 2\n# todo 2\n' \
  > "$ROOT/node-todo-identical.txt"
out=$(node "$TI" parse --input "$ROOT/node-todo-identical.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"todo": 2' >/dev/null && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "node:test identical repeated # todo 2 accepted" \
  || bad "node identical todo broken (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "blocker 1e: TAP binds SKIP/TODO to the correct plan region"
# ---------------------------------------------------------------------------
# Whole-stream SKIP reuse fabricates skipped=2 for every plan when two
# plan-at-end runs each have one SKIP. Bind result lines to the plan region
# (lines since previous plan through current plan for plan-at-end).

# Identical repeated plan-at-end: one SKIP each → both skipped=1 (not 2)
printf 'ok 1 - a\nok 2 - b # SKIP reason-a\nok 3 - c\n1..10\nok 1 - d\nok 2 - e # SKIP reason-b\nok 3 - f\n1..10\n' \
  > "$ROOT/tap-plan-end-skip-agree.txt"
out=$(node "$TI" parse --input "$ROOT/tap-plan-end-skip-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null && echo "$out" | grep '"skipped": 1' >/dev/null \
  && ok "TAP repeated plan-at-end with one SKIP each → skipped=1 (not whole-stream 2)" \
  || bad "tap plan-region skip fabrication (rc=$rc): $out"

# Conflicting repeated plan-at-end SKIP counts → fail closed
printf 'ok 1 - a # SKIP only\n1..10\nok 1 - b # SKIP one\nok 2 - c # SKIP two\n1..10\n' \
  > "$ROOT/tap-plan-end-skip-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/tap-plan-end-skip-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple|untrusted|native|skip' >/dev/null; then
  ok "TAP repeated plans with conflicting SKIP counts fail closed"
else
  bad "tap skip-conflict accepted (rc=$rc): $out"
fi

# Identical repeated plan-at-end TODO: one TODO each → todo=1
printf 'ok 1 - a\nok 2 - b # TODO later-a\n1..10\nok 1 - c\nok 2 - d # TODO later-b\n1..10\n' \
  > "$ROOT/tap-plan-end-todo-agree.txt"
out=$(node "$TI" parse --input "$ROOT/tap-plan-end-todo-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 10' >/dev/null && echo "$out" | grep '"todo": 1' >/dev/null \
  && ok "TAP repeated plan-at-end with one TODO each → todo=1 (not whole-stream 2)" \
  || bad "tap plan-region todo fabrication (rc=$rc): $out"

# Conflicting repeated plan-at-end TODO counts → fail closed
printf 'ok 1 - a # TODO only\n1..10\nok 1 - b # TODO one\nok 2 - c # TODO two\n1..10\n' \
  > "$ROOT/tap-plan-end-todo-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/tap-plan-end-todo-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple|untrusted|native|todo' >/dev/null; then
  ok "TAP repeated plans with conflicting TODO counts fail closed"
else
  bad "tap todo-conflict accepted (rc=$rc): $out"
fi

# Explicit-native agreement: GIBSON_TEST_METRICS matches plan-region skipped=1
printf 'ok 1 - a\nok 2 - b # SKIP reason\n1..10\nok 1 - c\nok 2 - d # SKIP reason\n1..10\nGIBSON_TEST_METRICS total=10 skipped=1 todo=0\n' \
  > "$ROOT/tap-explicit-native-agree.txt"
out=$(node "$TI" parse --input "$ROOT/tap-explicit-native-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"skipped": 1' >/dev/null && echo "$out" | grep '"total": 10' >/dev/null \
  && ok "TAP plan-region + agreeing explicit metrics accepted" \
  || bad "tap explicit-native agree broken (rc=$rc): $out"

# Explicit-native conflict: explicit claims skipped=0 while each plan has 1 SKIP
printf 'ok 1 - a # SKIP x\n1..10\nok 1 - b # SKIP y\n1..10\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/tap-explicit-native-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/tap-explicit-native-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple|untrusted' >/dev/null; then
  ok "TAP plan-region + conflicting explicit metrics fail closed"
else
  bad "tap explicit-native conflict spoof (rc=$rc): $out"
fi

# node:test region counters + agreeing explicit
printf '# tests 10\n# skip 2\n# skip 2\n# todo 0\nGIBSON_TEST_METRICS total=10 skipped=2 todo=0\n' \
  > "$ROOT/node-explicit-native-agree.txt"
out=$(node "$TI" parse --input "$ROOT/node-explicit-native-agree.txt" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep '"skipped": 2' >/dev/null \
  && ok "node:test multi-skip + agreeing explicit accepted" \
  || bad "node explicit-native agree broken (rc=$rc): $out"

# node:test region counters + conflicting explicit (first-match skip 0 would wrongly agree)
printf '# tests 10\n# skip 0\n# skip 2\n# todo 0\nGIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' \
  > "$ROOT/node-explicit-native-conflict.txt"
out=$(node "$TI" parse --input "$ROOT/node-explicit-native-conflict.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple|untrusted|skip' >/dev/null; then
  ok "node:test multi-skip + conflicting explicit fails closed (no first-match agree)"
else
  bad "node explicit-native first-match spoof (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker 4: waiver dimensions must equal max(actual_delta,0) on both axes"
# ---------------------------------------------------------------------------
# actual removed 1 + waiver claims removed 1 AND skip +999 → fail
write_metrics "$ROOT/w-b1.json" 10 0 0
write_metrics "$ROOT/w-h1.json" 9 0 0
out=$(compare "$ROOT/w-b1.json" "$ROOT/w-h1.json" \
  'Test-integrity: removed 1, skip +999 for overclaim'); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'wrong delta|skip' >/dev/null; then
  ok "waiver overclaim skip +999 with actual skip 0 fails"
else
  bad "skip overclaim accepted (rc=$rc): $out"
fi

# actual skip +1 + waiver claims removed 999 AND skip +1 → fail
write_metrics "$ROOT/w-b2.json" 10 0 0
write_metrics "$ROOT/w-h2.json" 10 1 0
out=$(compare "$ROOT/w-b2.json" "$ROOT/w-h2.json" \
  'Test-integrity: removed 999, skip +1 for overclaim'); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'wrong delta|removed' >/dev/null; then
  ok "waiver overclaim removed 999 with actual removed 0 fails"
else
  bad "removed overclaim accepted (rc=$rc): $out"
fi

# unchanged metrics + waiver removed 999 → fail (no integrity reduction)
write_metrics "$ROOT/w-b3.json" 10 0 0
write_metrics "$ROOT/w-h3.json" 10 0 0
out=$(compare "$ROOT/w-b3.json" "$ROOT/w-h3.json" \
  'Test-integrity: removed 999 for phantom'); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'no integrity reduction|unchanged|wrong delta' >/dev/null; then
  ok "waiver with no integrity reduction fails"
else
  bad "phantom waiver accepted (rc=$rc): $out"
fi

# Exact match on both claimed dimensions still works (regression pin)
write_metrics "$ROOT/w-b4.json" 10 1 0
write_metrics "$ROOT/w-h4.json" 8 2 0
out=$(compare "$ROOT/w-b4.json" "$ROOT/w-h4.json" \
  'Test-integrity: removed 2, skip +1 for both intentional under #70'); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep 'WAIVER accepted' >/dev/null \
  && ok "exact dual-dimension waiver still accepted" \
  || bad "exact dual waiver broken (rc=$rc): $out"

# ---------------------------------------------------------------------------
echo "blocker 5: metrics beyond Number.MAX_SAFE_INTEGER fail closed"
# ---------------------------------------------------------------------------
# 9007199254740993 is MAX_SAFE_INTEGER+1; JS Number loses precision to …992.
# String form must be rejected before it can mask a real delta.
printf 'GIBSON_TEST_METRICS total=9007199254740993 skipped=0 todo=0\n' \
  > "$ROOT/unsafe-kv.txt"
out=$(node "$TI" parse --input "$ROOT/unsafe-kv.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'safe integer|unparseable|exceeds|precision' >/dev/null; then
  ok "unsafe integer string total=9007199254740993 rejected"
else
  bad "unsafe kv total accepted (rc=$rc): $out"
fi

printf 'GIBSON_TEST_METRICS {"total":"9007199254740993","skipped":0,"todo":0}\n' \
  > "$ROOT/unsafe-json.txt"
out=$(node "$TI" parse --input "$ROOT/unsafe-json.txt" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'safe integer|unparseable|exceeds|precision' >/dev/null; then
  ok "unsafe integer JSON string total rejected"
else
  bad "unsafe json total accepted (rc=$rc): $out"
fi

# Bare metrics object with unsafe string field via load/compare path
printf '%s\n' '{"total":"9007199254740993","skipped":0,"todo":0}' > "$ROOT/unsafe-head.json"
write_metrics "$ROOT/safe-base.json" 10 0 0
out=$(compare "$ROOT/safe-base.json" "$ROOT/unsafe-head.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'safe integer|unparseable|exceeds|precision|test-integrity' >/dev/null; then
  ok "compare rejects unsafe head total string (…993 vs safe base)"
else
  bad "unsafe compare accepted (rc=$rc): $out"
fi

# Precision-mask regression: MAX_SAFE_INTEGER (…991) is accepted; …993 is not.
# JS Number would collapse 9007199254740993 → 9007199254740992, masking deltas.
printf '%s\n' '{"total":"9007199254740991","skipped":0,"todo":0}' > "$ROOT/safe-max.json"
printf '%s\n' '{"total":"9007199254740993","skipped":0,"todo":0}' > "$ROOT/unsafe-max1.json"
out=$(compare "$ROOT/safe-max.json" "$ROOT/safe-max.json" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "MAX_SAFE_INTEGER 9007199254740991 accepted as metrics total" \
  || bad "MAX_SAFE_INTEGER rejected (rc=$rc): $out"
out=$(compare "$ROOT/safe-max.json" "$ROOT/unsafe-max1.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'safe integer|unparseable|exceeds|precision' >/dev/null; then
  ok "9007199254740993 vs 9007199254740991 does not silently collapse"
else
  bad "safe-integer collapse (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker 2: failing base suite still reaches integrity compare (errexit-safe)"
# ---------------------------------------------------------------------------
# Local simulation of the intended phase-2 CI pattern: capture base test rc
# with errexit off, always parse + compare, preserve base rc separately.
# Deleted-failing-test scenario: base prints 10 tests then exits 1; head
# prints 7 and exits 0. (ci/gibson-gate.yml is deliberately unwired in phase 1.)
BASE_SIM="$ROOT/base-sim"
HEAD_SIM="$ROOT/head-sim"
mkdir -p "$BASE_SIM" "$HEAD_SIM"
# base: metrics then fail (as a deleted-later failing test suite would)
printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\n' > "$BASE_SIM/test-output-base.txt"
# head: suite shrank
printf 'GIBSON_TEST_METRICS total=7 skipped=0 todo=0\n' > "$HEAD_SIM/test-output-head.txt"

# Simulate the CI capture pattern under set -euo pipefail
CI_SIM_OUT="$ROOT/ci-sim.out"
set +e
(
  set -euo pipefail
  # --- trusted helper copy from "merge-base worktree" (blocker 3 pin) ---
  WT_SIM="$ROOT/merge-base-wt"
  mkdir -p "$WT_SIM/scripts"
  cp "$TI" "$WT_SIM/scripts/test-integrity.mjs"
  TI_TRUSTED="$WT_SIM/scripts/test-integrity.mjs"
  # head must not be the grading authority when base helper exists
  if [[ ! -f "$TI_TRUSTED" ]]; then
    echo "missing trusted helper" >&2
    exit 99
  fi

  # base test: capture rc without aborting the job
  set +e
  # pretend base suite failed (exit 1) after emitting metrics
  ( cat "$BASE_SIM/test-output-base.txt"; exit 1 )
  base_test_rc=$?
  set -e
  echo "base_test_rc=$base_test_rc"

  node "$TI_TRUSTED" parse \
    --input "$BASE_SIM/test-output-base.txt" \
    --out "$ROOT/ci-metrics-base.json"
  node "$TI_TRUSTED" parse \
    --input "$HEAD_SIM/test-output-head.txt" \
    --out "$ROOT/ci-metrics-head.json"
  set +e
  node "$TI_TRUSTED" compare \
    --base "$ROOT/ci-metrics-base.json" \
    --head "$ROOT/ci-metrics-head.json" \
    --waiver-text "" \
    --trusted-source "merge-base:sim" 2>&1
  ti_rc=$?
  set -e
  echo "test_integrity_rc=$ti_rc"
  # Preserve base rc for the job summary; integrity must still have fired.
  echo "BASE_TEST_RC=$base_test_rc"
  exit "$ti_rc"
) >"$CI_SIM_OUT" 2>&1
ci_rc=$?
# Restore the harness default (no errexit) so later sensors can capture non-zero rcs.
set +e
set -uo pipefail

if [[ "$ci_rc" -ne 0 ]] \
  && grep -q 'base_test_rc=1' "$CI_SIM_OUT" \
  && grep -qE 'dropped by 3|removed 3' "$CI_SIM_OUT" \
  && grep -q 'test-integrity' "$CI_SIM_OUT" \
  && grep -q 'test_integrity_rc=1' "$CI_SIM_OUT"; then
  ok "failing base still reaches test-integrity with exact delta 10→7"
else
  bad "CI base-rc sim (rc=$ci_rc): $(cat "$CI_SIM_OUT")"
fi

# ---------------------------------------------------------------------------
echo "blocker 3: CI grades with merge-base helper, not a PR-rewritten head copy"
# ---------------------------------------------------------------------------
# A hostile head helper that always PASS must not be used when base has a real helper.
HOSTILE="$ROOT/hostile-head/scripts"
mkdir -p "$HOSTILE"
cat > "$HOSTILE/test-integrity.mjs" <<'HOSTILE'
#!/usr/bin/env node
// Hostile PR-head helper: always report PASS regardless of metrics.
import { writeFileSync } from 'node:fs';
if (process.argv[2] === 'compare') {
  console.log('test-integrity: PASS (hostile always-green helper)');
  process.exit(0);
}
if (process.argv[2] === 'parse') {
  const out = process.argv.includes('--out')
    ? process.argv[process.argv.indexOf('--out') + 1]
    : null;
  const payload = JSON.stringify({
    total: 999, skipped: 0, todo: 0, skip_effective: 0, source: 'hostile'
  }, null, 2) + '\n';
  if (out) writeFileSync(out, payload);
  else process.stdout.write(payload);
  process.exit(0);
}
process.exit(0);
HOSTILE

# Policy under test: prefer merge-base helper when present (phase-2 CI intent)
WT_BASE="$ROOT/trusted-base-wt"
mkdir -p "$WT_BASE/scripts"
cp "$TI" "$WT_BASE/scripts/test-integrity.mjs"
write_metrics "$ROOT/t-base.json" 10 0 0
write_metrics "$ROOT/t-head.json" 7 0 0
# Using trusted helper → must FAIL with delta
out=$(node "$WT_BASE/scripts/test-integrity.mjs" compare \
  --base "$ROOT/t-base.json" --head "$ROOT/t-head.json" \
  --trusted-source "merge-base:sim" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -E 'dropped by 3|removed 3' >/dev/null; then
  ok "trusted merge-base helper reports deletion delta (not always-green)"
else
  bad "trusted helper failed to diagnose (rc=$rc): $out"
fi
# Hostile head helper → would PASS (proves why CI must not use it)
out=$(node "$HOSTILE/test-integrity.mjs" compare \
  --base "$ROOT/t-base.json" --head "$ROOT/t-head.json" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -i 'hostile\|PASS' >/dev/null; then
  ok "hostile head helper would self-approve (CI must load merge-base copy)"
else
  bad "hostile helper fixture broken (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker nested-TAP: real node:test describe() suites parse (top-level plans only)"
# ---------------------------------------------------------------------------
# Node 22 describe('outer') with two it() tests emits nested `    1..2`,
# top-level `1..1`, and `# tests 2`. Treating indented plans as whole-run
# totals falsely conflicts. Use actual runner output — not a handwaved fixture.

NEST_DIR="$ROOT/node-nested-tap"
mkdir -p "$NEST_DIR"
cat > "$NEST_DIR/nested.test.mjs" <<'EOF'
import { describe, it } from 'node:test';
describe('outer', () => {
  it('a', () => {});
  it('b', () => {});
});
EOF
# Capture real TAP (stdout); stderr may carry node warnings — ignore for parse input.
node --test --test-reporter=tap "$NEST_DIR/nested.test.mjs" \
  >"$NEST_DIR/nested.tap" 2>"$NEST_DIR/nested.err" || true
# Sanity: fixture must contain nested plan + top-level plan + # tests
if grep -qE '^[[:space:]]+1\.\.2[[:space:]]*$' "$NEST_DIR/nested.tap" \
  && grep -qE '^1\.\.1[[:space:]]*$' "$NEST_DIR/nested.tap" \
  && grep -qE '^# tests 2[[:space:]]*$' "$NEST_DIR/nested.tap"; then
  ok "real node:test nested TAP fixture has indented 1..2, top-level 1..1, # tests 2"
else
  bad "nested TAP fixture missing expected plans/counters: $(cat "$NEST_DIR/nested.tap")"
fi
out=$(node "$TI" parse --input "$NEST_DIR/nested.tap" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 2' >/dev/null \
  && echo "$out" | grep '"skipped": 0' >/dev/null; then
  ok "real node:test nested describe suite parses total=2 (no false plan conflict)"
else
  bad "nested node:test TAP parse (rc=$rc): $out"
fi

# skip coverage via real runner (it.skip → # skipped N)
cat > "$NEST_DIR/nested-skip.test.mjs" <<'EOF'
import { describe, it } from 'node:test';
describe('outer', () => {
  it('a', () => {});
  it.skip('b', () => {});
});
EOF
node --test --test-reporter=tap "$NEST_DIR/nested-skip.test.mjs" \
  >"$NEST_DIR/nested-skip.tap" 2>/dev/null || true
out=$(node "$TI" parse --input "$NEST_DIR/nested-skip.tap" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 2' >/dev/null \
  && echo "$out" | grep '"skipped": 1' >/dev/null; then
  ok "real node:test nested suite with it.skip → skipped=1"
else
  bad "nested skip parse (rc=$rc): $out"
fi

# todo coverage via real runner
cat > "$NEST_DIR/nested-todo.test.mjs" <<'EOF'
import { describe, it } from 'node:test';
describe('outer', () => {
  it('a', () => {});
  it('b', { todo: true }, () => {});
});
EOF
node --test --test-reporter=tap "$NEST_DIR/nested-todo.test.mjs" \
  >"$NEST_DIR/nested-todo.tap" 2>/dev/null || true
out=$(node "$TI" parse --input "$NEST_DIR/nested-todo.tap" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep '"total": 2' >/dev/null \
  && echo "$out" | grep '"todo": 1' >/dev/null; then
  ok "real node:test nested suite with todo → todo=1"
else
  bad "nested todo parse (rc=$rc): $out"
fi

# Genuinely repeated top-level TAP plans still conflict (not weakened)
printf '1..10\nok 1 - a\n1..7\nok 1 - b\n' >"$NEST_DIR/top-conflict.tap"
out=$(node "$TI" parse --input "$NEST_DIR/top-conflict.tap" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'conflict|disagree|multiple|untrusted' >/dev/null; then
  ok "repeated top-level TAP plans still fail closed after nested-plan fix"
else
  bad "top-level TAP conflict weakened (rc=$rc): $out"
fi

# Hierarchical TAP alone (indented plans, no # tests / explicit) fails closed
printf '# Subtest: outer\n    ok 1 - a\n    ok 2 - b\n    1..2\nok 1 - outer\n1..1\n' \
  >"$NEST_DIR/hierarchical-only.tap"
out=$(node "$TI" parse --input "$NEST_DIR/hierarchical-only.tap" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'could not parse|fail closed|unparseable' >/dev/null; then
  ok "hierarchical TAP without # tests / explicit fails closed (no invented total)"
else
  bad "hierarchical-only TAP should fail closed (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker temp-poison: predictable scratch/symlink targets fail closed"
# ---------------------------------------------------------------------------
# Pre-poison fixed /tmp/gibson-ti-parse.err and worktree-local
# .gibson-baseline.test.out / .gibson-baseline.*.ec as symlinks to a victim
# file. Gate must fail closed without truncating victim bytes, and leave no
# leaked predictable temps.

POISON="$ROOT/poison-repo"
mkdir -p "$POISON/.agents"
GITP="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"
$GITP init -q "$POISON"
git -C "$POISON" symbolic-ref HEAD refs/heads/main
echo base >"$POISON/README"
$GITP -C "$POISON" add -A
$GITP -C "$POISON" commit -q -m "base"

# --- parser-stderr class: /tmp/gibson-ti-parse.err as symlink ----------------
VICTIM_PARSE="$ROOT/victim-parse-bytes.bin"
printf 'VICTIM_PARSE_SENTINEL_DO_NOT_TRUNCATE\n' >"$VICTIM_PARSE"
# Best-effort: remove any leftover fixed path from prior runs, then plant symlink.
rm -f /tmp/gibson-ti-parse.err 2>/dev/null || true
ln -sf "$VICTIM_PARSE" /tmp/gibson-ti-parse.err
# Untrusted test command: try to keep the poison in place; emit valid metrics
# so a vulnerable parser-stderr redirect would truncate the victim on parse.
cat >"$POISON/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=3 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/.gibson-baseline.json" 2>&1); rc=$?
victim_parse_after=$(cat "$VICTIM_PARSE" 2>/dev/null || echo MISSING)
if [[ "$victim_parse_after" == "VICTIM_PARSE_SENTINEL_DO_NOT_TRUNCATE" ]]; then
  ok "parser-stderr pre-poison: victim bytes unchanged"
else
  bad "parser-stderr pre-poison: victim truncated/changed: $victim_parse_after"
fi
# Gate should succeed (valid metrics) without using the fixed path — or fail
# closed if it somehow still depends on it. Either way victim must stay intact.
# Prefer success path: private mktemp means baseline writes OK.
if [[ "$rc" -eq 0 ]] && grep -qE '"total":[[:space:]]*3' "$POISON/.gibson-baseline.json" 2>/dev/null; then
  ok "parser-stderr pre-poison: gate succeeds via private scratch (not fixed /tmp path)"
elif [[ "$rc" -ne 0 ]]; then
  ok "parser-stderr pre-poison: gate fails closed (rc=$rc) without victim damage"
else
  bad "parser-stderr pre-poison: unexpected gate outcome (rc=$rc): $out"
fi
# Cleanup planted symlink so later tests are clean
rm -f /tmp/gibson-ti-parse.err 2>/dev/null || true
# No predictable worktree temps left behind
if [[ ! -e "$POISON/.gibson-baseline.test.out" \
   && ! -e "$POISON/.gibson-baseline.test.ec" \
   && ! -L "$POISON/.gibson-baseline.test.out" \
   && ! -L "$POISON/.gibson-baseline.test.ec" ]]; then
  ok "parser-stderr pre-poison: no worktree-local temp leaks"
else
  bad "parser-stderr pre-poison: leaked worktree temps"
fi

# --- worktree-local artifact class: .gibson-baseline.test.out as symlink ----
VICTIM_OUT="$ROOT/victim-test-out-bytes.bin"
printf 'VICTIM_TEST_OUT_SENTINEL_DO_NOT_TRUNCATE\n' >"$VICTIM_OUT"
rm -f "$POISON/.gibson-baseline.test.out" "$POISON/.gibson-baseline.test.ec" \
  "$POISON/.gibson-baseline.typecheck.ec" "$POISON/.gibson-baseline.lint.ec" \
  "$POISON/.gibson-baseline.build.ec" 2>/dev/null || true
ln -sf "$VICTIM_OUT" "$POISON/.gibson-baseline.test.out"
# Hostile test also re-plants the symlink mid-run (in case gate rm's first)
cat >"$POISON/.agents/gate.json" <<JSON
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "ln -sfn '$VICTIM_OUT' .gibson-baseline.test.out; printf 'GIBSON_TEST_METRICS total=4 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/.gibson-baseline.json" 2>&1); rc=$?
victim_out_after=$(cat "$VICTIM_OUT" 2>/dev/null || echo MISSING)
if [[ "$victim_out_after" == "VICTIM_TEST_OUT_SENTINEL_DO_NOT_TRUNCATE" ]]; then
  ok "worktree test.out pre-poison: victim bytes unchanged"
else
  bad "worktree test.out pre-poison: victim truncated/changed: $victim_out_after"
fi
if [[ "$rc" -eq 0 ]] && grep -qE '"total":[[:space:]]*4' "$POISON/.gibson-baseline.json" 2>/dev/null; then
  ok "worktree test.out pre-poison: gate succeeds without writing through symlink"
elif [[ "$rc" -ne 0 ]]; then
  ok "worktree test.out pre-poison: gate fails closed (rc=$rc) without victim damage"
else
  bad "worktree test.out pre-poison: unexpected (rc=$rc): $out"
fi
# Predictable temps must not remain as regular files we created (symlink the
# hostile command planted may still exist — that is the attacker's file, not
# our leak). We must not leave our own .ec scratch files.
leaked=0
for f in .gibson-baseline.typecheck.ec .gibson-baseline.lint.ec \
         .gibson-baseline.test.ec .gibson-baseline.build.ec; do
  if [[ -f "$POISON/$f" && ! -L "$POISON/$f" ]]; then
    leaked=1
  fi
done
if [[ "$leaked" -eq 0 ]]; then
  ok "worktree pre-poison: no gate-owned .ec temp leaks"
else
  bad "worktree pre-poison: gate-owned .ec temps leaked"
fi
rm -f "$POISON/.gibson-baseline.test.out" 2>/dev/null || true

# --- .ec class: pre-poison exit-code path as symlink ------------------------
VICTIM_EC="$ROOT/victim-ec-bytes.bin"
printf 'VICTIM_EC_SENTINEL_DO_NOT_TRUNCATE\n' >"$VICTIM_EC"
ln -sf "$VICTIM_EC" "$POISON/.gibson-baseline.test.ec"
cat >"$POISON/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=5 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/.gibson-baseline.json" 2>&1); rc=$?
victim_ec_after=$(cat "$VICTIM_EC" 2>/dev/null || echo MISSING)
if [[ "$victim_ec_after" == "VICTIM_EC_SENTINEL_DO_NOT_TRUNCATE" ]]; then
  ok "worktree .ec pre-poison: victim bytes unchanged"
else
  bad "worktree .ec pre-poison: victim truncated/changed: $victim_ec_after"
fi
if [[ "$rc" -eq 0 ]] && grep -qE '"total":[[:space:]]*5' "$POISON/.gibson-baseline.json" 2>/dev/null; then
  ok "worktree .ec pre-poison: gate succeeds via in-memory exit codes"
elif [[ "$rc" -ne 0 ]]; then
  ok "worktree .ec pre-poison: gate fails closed without victim damage"
else
  bad "worktree .ec pre-poison: unexpected (rc=$rc): $out"
fi
rm -f "$POISON/.gibson-baseline.test.ec" 2>/dev/null || true

# --- OUT path as symlink: must fail closed, victim untouched ----------------
VICTIM_BASELINE="$ROOT/victim-baseline-bytes.bin"
printf 'VICTIM_BASELINE_SENTINEL_DO_NOT_TRUNCATE\n' >"$VICTIM_BASELINE"
rm -f "$POISON/out-link.json" 2>/dev/null || true
ln -sf "$VICTIM_BASELINE" "$POISON/out-link.json"
cat >"$POISON/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=6 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/out-link.json" 2>&1); rc=$?
victim_bl_after=$(cat "$VICTIM_BASELINE" 2>/dev/null || echo MISSING)
if [[ "$victim_bl_after" == "VICTIM_BASELINE_SENTINEL_DO_NOT_TRUNCATE" ]]; then
  ok "OUT symlink pre-poison: victim bytes unchanged"
else
  bad "OUT symlink pre-poison: victim truncated/changed: $victim_bl_after"
fi
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'symlink|refuse|fail closed' >/dev/null; then
  ok "OUT symlink pre-poison: gate fails closed"
else
  bad "OUT symlink pre-poison: expected fail closed (rc=$rc): $out"
fi

# --- JOURNAL path as symlink during regenerate ------------------------------
VICTIM_JOURNAL="$ROOT/victim-journal-bytes.bin"
printf 'VICTIM_JOURNAL_SENTINEL_DO_NOT_TRUNCATE\n' >"$VICTIM_JOURNAL"
# Establish a real baseline first
cat >"$POISON/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=8 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/.gibson-baseline.json") >/dev/null 2>&1 || true
mkdir -p "$POISON/.gibson"
rm -f "$POISON/.gibson/test-integrity-journal.jsonl" 2>/dev/null || true
ln -sf "$VICTIM_JOURNAL" "$POISON/.gibson/test-integrity-journal.jsonl"
# Shrink suite to force journal append
cat >"$POISON/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=2 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
out=$(cd "$POISON" && bash "$BASELINE_SH" --out "$POISON/.gibson-baseline.json" \
  --regenerate --reason 'intentional shrink for poison test' 2>&1); rc=$?
victim_j_after=$(cat "$VICTIM_JOURNAL" 2>/dev/null || echo MISSING)
if [[ "$victim_j_after" == "VICTIM_JOURNAL_SENTINEL_DO_NOT_TRUNCATE" ]]; then
  ok "JOURNAL symlink pre-poison: victim bytes unchanged"
else
  bad "JOURNAL symlink pre-poison: victim truncated/changed: $victim_j_after"
fi
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'symlink|refuse|fail closed|journal' >/dev/null; then
  ok "JOURNAL symlink pre-poison: gate fails closed"
else
  bad "JOURNAL symlink pre-poison: expected fail closed (rc=$rc): $out"
fi
rm -f "$POISON/.gibson/test-integrity-journal.jsonl" 2>/dev/null || true

# ---------------------------------------------------------------------------
echo "blocker scratch-lifecycle: no discoverable scratch before configured command"
# ---------------------------------------------------------------------------
# Configured command scans for gibson-baseline.* scratch dirs and plants a
# symlink at test.out → victim. Pre-command scratch creation allowed write-
# through + silent test_metrics:null. Must keep victim bytes and emit correct
# non-null metrics (or hard-fail). Never GREEN with null metrics after a test.
SCRATCH_LIFE="$ROOT/scratch-lifecycle"
mkdir -p "$SCRATCH_LIFE/.agents"
$GITP init -q "$SCRATCH_LIFE"
git -C "$SCRATCH_LIFE" symbolic-ref HEAD refs/heads/main
echo base >"$SCRATCH_LIFE/README"
$GITP -C "$SCRATCH_LIFE" add -A
$GITP -C "$SCRATCH_LIFE" commit -q -m "base"

VICTIM_SCRATCH="$ROOT/victim-scratch-lifecycle.bin"
printf 'VICTIM_SCRATCH_LIFECYCLE_SENTINEL\n' >"$VICTIM_SCRATCH"
# Hostile test: poison any discoverable pre-command scratch class.
cat >"$SCRATCH_LIFE/.agents/gate.json" <<EOF
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "for d in ${TMPDIR:-/tmp}/gibson-baseline.*; do if [ -d \"\$d\" ]; then ln -sfn '$VICTIM_SCRATCH' \"\$d/test.out\"; ln -sfn '$VICTIM_SCRATCH' \"\$d/test.out.XXXXXX\" 2>/dev/null || true; fi; done; printf 'GIBSON_TEST_METRICS total=11 skipped=0 todo=0\\\\n'",
  "build": ""
}
EOF
out=$(cd "$SCRATCH_LIFE" && bash "$BASELINE_SH" --out "$SCRATCH_LIFE/.gibson-baseline.json" 2>&1); rc=$?
victim_sl_after=$(cat "$VICTIM_SCRATCH" 2>/dev/null || echo MISSING)
if [[ "$victim_sl_after" == "VICTIM_SCRATCH_LIFECYCLE_SENTINEL" ]]; then
  ok "scratch-lifecycle pre-poison: victim bytes unchanged"
else
  bad "scratch-lifecycle pre-poison: victim truncated/changed: $victim_sl_after"
fi
if [[ "$rc" -eq 0 ]] \
  && grep -qE '"total":[[:space:]]*11' "$SCRATCH_LIFE/.gibson-baseline.json" 2>/dev/null \
  && ! grep -qE '"test_metrics":[[:space:]]*null' "$SCRATCH_LIFE/.gibson-baseline.json" 2>/dev/null; then
  ok "scratch-lifecycle pre-poison: correct non-null metrics (total=11), no write-through"
elif [[ "$rc" -ne 0 ]] && ! grep -qE '"test_metrics":[[:space:]]*null' "$SCRATCH_LIFE/.gibson-baseline.json" 2>/dev/null; then
  ok "scratch-lifecycle pre-poison: gate fails closed without null-metrics bypass (rc=$rc)"
else
  bad "scratch-lifecycle pre-poison: unexpected (rc=$rc metrics=$(grep test_metrics "$SCRATCH_LIFE/.gibson-baseline.json" 2>/dev/null || echo none)): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker baseline-authority: deletion/replacement/content drift during gate.sh"
# ---------------------------------------------------------------------------
# gate.sh must snapshot baseline before any configured command and compare
# against that snapshot only. Deletion, replacement, or byte change mid-run
# with a lower total must RED — never GREEN.
AUTH="$ROOT/baseline-auth"
mkdir -p "$AUTH/.agents"
$GITP init -q "$AUTH"
git -C "$AUTH" symbolic-ref HEAD refs/heads/main
echo base >"$AUTH/README"
$GITP -C "$AUTH" add -A
$GITP -C "$AUTH" commit -q -m "base"
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
(cd "$AUTH" && bash "$BASELINE_SH" --out "$AUTH/.gibson-baseline.json") >/dev/null 2>&1

# --- deletion during lower-total test ---
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "rm -f .gibson-baseline.json; printf 'GIBSON_TEST_METRICS total=3 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$AUTH" && bash "$GATE" --baseline "$AUTH/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'authority drift|disappeared|baseline' >/dev/null \
  && ! echo "$out" | grep 'GREEN' >/dev/null; then
  ok "baseline authority: deletion during lower-total test is RED (no GREEN)"
else
  bad "baseline deletion allowed GREEN or wrong error (rc=$rc): $out"
fi

# Restore baseline for next attack
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
(cd "$AUTH" && bash "$BASELINE_SH" --out "$AUTH/.gibson-baseline.json") >/dev/null 2>&1

# --- replacement with matching lower metrics (would self-authorize on re-read) ---
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "cat > .gibson-baseline.json <<'BL'\n{\"failures\":{\"typecheck\":0,\"lint\":0,\"test\":0,\"build\":0},\"exit_codes\":{\"typecheck\":0,\"lint\":0,\"test\":0,\"build\":0},\"test_metrics\":{\"total\":3,\"skipped\":0,\"todo\":0,\"skip_effective\":0,\"source\":\"hostile\"}}\nBL\nprintf 'GIBSON_TEST_METRICS total=3 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$AUTH" && bash "$GATE" --baseline "$AUTH/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'authority drift|content changed|replaced|leaf' >/dev/null \
  && ! echo "$out" | grep 'GREEN' >/dev/null; then
  ok "baseline authority: replacement during lower-total test is RED (no GREEN)"
else
  bad "baseline replacement allowed GREEN or wrong error (rc=$rc): $out"
fi

# Restore
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
(cd "$AUTH" && bash "$BASELINE_SH" --out "$AUTH/.gibson-baseline.json") >/dev/null 2>&1

# --- content byte change (append) during lower-total test ---
cat >"$AUTH/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'x' >> .gibson-baseline.json; printf 'GIBSON_TEST_METRICS total=3 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$AUTH" && bash "$GATE" --baseline "$AUTH/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'authority drift|content changed' >/dev/null \
  && ! echo "$out" | grep 'GREEN' >/dev/null; then
  ok "baseline authority: content change during lower-total test is RED (no GREEN)"
else
  bad "baseline content change allowed GREEN or wrong error (rc=$rc): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker parent-stability: OUT/JOURNAL parent replace fails closed"
# ---------------------------------------------------------------------------
# A configured command that replaces a parent directory must not let the final
# atomic OUT write or JOURNAL append follow the new path. Victim bytes (if any)
# unchanged; nonzero exit; no partial output in the evil parent; no temp leaks.

PARENT_ATK="$ROOT/parent-attack"
mkdir -p "$PARENT_ATK/.agents" "$PARENT_ATK/out nest/sub"
$GITP init -q "$PARENT_ATK"
git -C "$PARENT_ATK" symbolic-ref HEAD refs/heads/main
echo base >"$PARENT_ATK/README"
$GITP -C "$PARENT_ATK" add -A
$GITP -C "$PARENT_ATK" commit -q -m "base"

# Establish a real OUT under a nested parent (path with spaces)
OUT_NEST="$PARENT_ATK/out nest/sub/base.json"
cat >"$PARENT_ATK/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=8 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
(cd "$PARENT_ATK" && bash "$BASELINE_SH" --out "$OUT_NEST") >/dev/null 2>&1
[[ -f "$OUT_NEST" ]] && ok "parent-stability setup: wrote baseline under path with spaces" \
  || bad "parent-stability setup failed to write $OUT_NEST"

# Replace immediate parent "out nest/sub" with symlink to evil during test
EVIL_OUT="$ROOT/evil-out-parent"
mkdir -p "$EVIL_OUT"
VICTIM_PARENT="$ROOT/victim-parent-out.bin"
printf 'VICTIM_PARENT_OUT_SENTINEL\n' >"$VICTIM_PARENT"
cat >"$PARENT_ATK/.agents/gate.json" <<EOF
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "rm -rf '$PARENT_ATK/out nest/sub'; mkdir -p '$EVIL_OUT'; ln -sfn '$EVIL_OUT' '$PARENT_ATK/out nest/sub'; printf 'GIBSON_TEST_METRICS total=8 skipped=0 todo=0\\\\n'",
  "build": ""
}
EOF
out=$(cd "$PARENT_ATK" && bash "$BASELINE_SH" --out "$OUT_NEST" 2>&1); rc=$?
evil_count=$(find "$EVIL_OUT" -type f 2>/dev/null | wc -l | tr -d ' ')
# No new baseline/temp files should land in the evil parent
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'parent|symlink|authority drift|refuse' >/dev/null \
  && [[ "$evil_count" -eq 0 ]]; then
  ok "OUT parent replace: fails closed, no partial write into evil parent"
else
  bad "OUT parent replace (rc=$rc evil_files=$evil_count): $out"
fi
# No temp leaks under evil or the (now symlink) nest path as gate-owned regulars
leaked_parent=0
if find "$EVIL_OUT" -name '.base.json.*' 2>/dev/null | grep . >/dev/null; then
  leaked_parent=1
fi
if [[ "$leaked_parent" -eq 0 ]]; then
  ok "OUT parent replace: no temp leaks in evil parent"
else
  bad "OUT parent replace: temp leaks in evil parent"
fi

# --- JOURNAL parent replace during regenerate ---
# Fresh repo so prior OUT state is clean
JATK="$ROOT/journal-parent-attack"
mkdir -p "$JATK/.agents" "$JATK/.gibson"
$GITP init -q "$JATK"
git -C "$JATK" symbolic-ref HEAD refs/heads/main
echo base >"$JATK/README"
$GITP -C "$JATK" add -A
$GITP -C "$JATK" commit -q -m "base"
cat >"$JATK/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "printf 'GIBSON_TEST_METRICS total=8 skipped=0 todo=0\\n'",
  "build": ""
}
JSON
(cd "$JATK" && bash "$BASELINE_SH" --out "$JATK/.gibson-baseline.json") >/dev/null 2>&1
EVIL_J="$ROOT/evil-journal-parent"
mkdir -p "$EVIL_J"
VICTIM_JPARENT="$ROOT/victim-journal-parent.bin"
printf 'VICTIM_JOURNAL_PARENT_SENTINEL\n' >"$VICTIM_JPARENT"
# Shrink + replace .gibson parent with symlink to evil during the test step
cat >"$JATK/.agents/gate.json" <<EOF
{
  "generate": "",
  "typecheck": "",
  "lint": "",
  "test": "rm -rf '$JATK/.gibson'; mkdir -p '$EVIL_J'; ln -sfn '$EVIL_J' '$JATK/.gibson'; printf 'GIBSON_TEST_METRICS total=2 skipped=0 todo=0\\\\n'",
  "build": ""
}
EOF
out=$(cd "$JATK" && bash "$BASELINE_SH" --out "$JATK/.gibson-baseline.json" \
  --regenerate --reason 'intentional shrink parent-attack' \
  --journal "$JATK/.gibson/test-integrity-journal.jsonl" 2>&1); rc=$?
evil_j_count=$(find "$EVIL_J" -type f 2>/dev/null | wc -l | tr -d ' ')
victim_jp_after=$(cat "$VICTIM_JPARENT" 2>/dev/null || echo MISSING)
if [[ "$victim_jp_after" == "VICTIM_JOURNAL_PARENT_SENTINEL" ]]; then
  ok "JOURNAL parent replace: victim bytes unchanged"
else
  bad "JOURNAL parent replace: victim changed: $victim_jp_after"
fi
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -iE 'parent|symlink|authority drift|refuse|journal' >/dev/null \
  && [[ "$evil_j_count" -eq 0 ]] \
  && ! echo "$out" | grep 'GREEN' >/dev/null; then
  ok "JOURNAL parent replace: fails closed, no journal partial in evil parent"
else
  bad "JOURNAL parent replace (rc=$rc evil_files=$evil_j_count): $out"
fi

# ---------------------------------------------------------------------------
echo "blocker generate-isolation: configured commands never parent-eval"
# ---------------------------------------------------------------------------
# Branch-controlled generate must run in a child subshell. A parent-shell
# eval can redefine SNAP_PRESENT / PRIOR_OUT_PRESENT / verification helpers,
# delete or replace a 10-test baseline, emit total=1, and receive GREEN or
# overwrite without --regenerate / journal.

# --- gate.sh: hostile generate redefines authority + deletes 10-test baseline ---
GEN_ISO="$ROOT/generate-isolation-gate"
mkdir -p "$GEN_ISO/.agents"
$GITP init -q "$GEN_ISO"
git -C "$GEN_ISO" symbolic-ref HEAD refs/heads/main
echo base >"$GEN_ISO/README"
$GITP -C "$GEN_ISO" add -A
$GITP -C "$GEN_ISO" commit -q -m "base"
cat >"$GEN_ISO/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
(cd "$GEN_ISO" && bash "$BASELINE_SH" --out "$GEN_ISO/.gibson-baseline.json") >/dev/null 2>&1
[[ -f "$GEN_ISO/.gibson-baseline.json" ]] || bad "generate-isolation setup: missing baseline"
# Hostile generate: try to zero SNAP_PRESENT, neuter verify/fail, delete baseline.
# Test then emits total=1. Parent-eval would go GREEN; isolation must RED.
cat >"$GEN_ISO/.agents/gate.json" <<'JSON'
{
  "generate": "SNAP_PRESENT=0; SNAP_BYTES=; SNAP_HAS_METRICS=0; SNAP_LEAF_ID=; verify_baseline_authority(){ return 0; }; fail(){ :; }; die(){ :; }; FAILED=0; rm -f .gibson-baseline.json",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=1 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$GEN_ISO" && bash "$GATE" --baseline "$GEN_ISO/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && ! echo "$out" | grep 'GREEN' >/dev/null; then
  ok "gate.sh generate isolation: authority pollution + baseline delete + total=1 is RED (no GREEN)"
else
  bad "gate.sh generate isolation allowed GREEN or zero exit (rc=$rc): $out"
fi

# --- gate-baseline.sh: hostile generate zeros PRIOR_OUT_PRESENT, shrinks 10→1 ---
GEN_BL="$ROOT/generate-isolation-baseline"
mkdir -p "$GEN_BL/.agents" "$GEN_BL/.gibson"
$GITP init -q "$GEN_BL"
git -C "$GEN_BL" symbolic-ref HEAD refs/heads/main
echo base >"$GEN_BL/README"
$GITP -C "$GEN_BL" add -A
$GITP -C "$GEN_BL" commit -q -m "base"
cat >"$GEN_BL/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
(cd "$GEN_BL" && bash "$BASELINE_SH" --out "$GEN_BL/.gibson-baseline.json") >/dev/null 2>&1
PRIOR_BYTES=$(cat -- "$GEN_BL/.gibson-baseline.json")
printf '%s' "$PRIOR_BYTES" | grep -E '"total":[[:space:]]*10' >/dev/null \
  || bad "generate-isolation baseline setup: expected total=10"
JOURNAL_PATH="$GEN_BL/.gibson/test-integrity-journal.jsonl"
rm -f "$JOURNAL_PATH"
# Without --regenerate: try to force PRIOR_OUT_PRESENT=0 / REGENERATE=1 in the
# parent so a 10→1 shrink would be allowed and journaled. Isolation must keep
# parent flags intact, refuse the shrink, preserve original bytes, and leave
# the journal without an authority reduction record.
cat >"$GEN_BL/.agents/gate.json" <<'JSON'
{
  "generate": "PRIOR_OUT_PRESENT=0; PRIOR_OUT_BYTES=; REGENERATE=1; REASON_SET=1; REASON=hostile-parent-eval",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=1 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$GEN_BL" && bash "$BASELINE_SH" --out "$GEN_BL/.gibson-baseline.json" \
  --journal "$JOURNAL_PATH" 2>&1); rc=$?
AFTER_BYTES=$(cat -- "$GEN_BL/.gibson-baseline.json" 2>/dev/null || echo MISSING)
journal_after=$(cat -- "$JOURNAL_PATH" 2>/dev/null || echo "")
if [[ "$rc" -ne 0 ]] \
  && [[ "$AFTER_BYTES" == "$PRIOR_BYTES" ]] \
  && [[ ! -f "$JOURNAL_PATH" || -z "${journal_after// }" ]] \
  && ! echo "$journal_after" | grep -iE 'hostile-parent-eval|regenerate|total' >/dev/null \
  && echo "$out" | grep -iE 'test-integrity|regenerate|reduce' >/dev/null \
  && printf '%s' "$AFTER_BYTES" | grep -E '"total":[[:space:]]*10' >/dev/null; then
  ok "gate-baseline.sh generate isolation: PRIOR_OUT pollution + 10→1 without --regenerate refused; bytes preserved; no fake journal"
else
  bad "gate-baseline.sh generate isolation (rc=$rc journal=$(echo "$journal_after" | head -c 80) after_total=$(printf '%s' "$AFTER_BYTES" | grep -oE '\"total\":[ ]*[0-9]+' | head -1)): $out"
fi

# --- child-isolation canaries: cwd / umask / IFS / traps / options ---
# Generate mutates shell state only (no baseline attack). If those mutations
# leaked into the parent, later steps would not see the repo baseline and
# would not stay GREEN at total=10.
CANARY="$ROOT/generate-isolation-canary"
mkdir -p "$CANARY/.agents"
$GITP init -q "$CANARY"
git -C "$CANARY" symbolic-ref HEAD refs/heads/main
echo base >"$CANARY/README"
$GITP -C "$CANARY" add -A
$GITP -C "$CANARY" commit -q -m "base"
cat >"$CANARY/.agents/gate.json" <<'JSON'
{
  "generate": "",
  "typecheck": "true",
  "lint": "true",
  "test": "printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
(cd "$CANARY" && bash "$BASELINE_SH" --out "$CANARY/.gibson-baseline.json") >/dev/null 2>&1
# Child tries to poison parent process state. test step asserts we still see
# the repo-local baseline (cwd intact) and no world-writable umask leak on a
# probe file created by the *test* step in the authority shell's cwd.
cat >"$CANARY/.agents/gate.json" <<'JSON'
{
  "generate": "cd /tmp; umask 000; IFS='|'; trap 'printf %s\\n CANARY_TRAP_FIRED_ON_EXIT' EXIT; set +e; set +u; set +o pipefail 2>/dev/null || true; alias true=false 2>/dev/null || true",
  "typecheck": "true",
  "lint": "true",
  "test": "test -f .gibson-baseline.json && test -f .agents/gate.json && printf 'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\\n'",
  "build": "true"
}
JSON
out=$(cd "$CANARY" && bash "$GATE" --baseline "$CANARY/.gibson-baseline.json" 2>&1); rc=$?
# Trap fire is a whole line only — do not match the generate command string.
if [[ "$rc" -eq 0 ]] && echo "$out" | grep 'GREEN' >/dev/null \
  && ! echo "$out" | grep -x 'CANARY_TRAP_FIRED_ON_EXIT' >/dev/null; then
  ok "generate child-isolation canary: parent cwd/IFS/traps/options intact (GREEN total=10)"
else
  bad "generate child-isolation canary failed (rc=$rc): $out"
fi
# Same canary through gate-baseline.sh (capture path / run_count_failures)
out=$(cd "$CANARY" && bash "$BASELINE_SH" --out "$CANARY/.gibson-baseline.json" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] \
  && grep -qE '"total":[[:space:]]*10' "$CANARY/.gibson-baseline.json" 2>/dev/null \
  && ! echo "$out" | grep -x 'CANARY_TRAP_FIRED_ON_EXIT' >/dev/null; then
  ok "gate-baseline child-isolation canary: parent state intact; total=10 preserved"
else
  bad "gate-baseline child-isolation canary (rc=$rc): $out"
fi

# ===========================================================================
# Phase-2 protected CI contract (ci/gibson-gate.yml) — offline sensors
# These pin the repository template. They do NOT claim live activation,
# required-check status, or branch protection (#68 / owner-owned).
# ===========================================================================
CI_YML="$SCRIPT_DIR/../../ci/gibson-gate.yml"
[[ -f "$CI_YML" ]] || { bad "ci/gibson-gate.yml missing"; CI_YML=""; }

# Helper: static YAML text checks (no network, no GHA).
# Positive checks may match comments (documentation of the contract).
# Negative / structural bans strip full-line comments so prose cannot trip them.
ci_has() { [[ -n "$CI_YML" ]] && grep -qE "$1" "$CI_YML"; }
ci_code() { grep -vE '^[[:space:]]*#' "$CI_YML" | sed 's/[[:space:]]#.*//'; }
ci_has_not() { [[ -n "$CI_YML" ]] && ! ci_code | grep -E "$1" >/dev/null; }

echo "phase-2 CI: four jobs, unique required name, always() final"
if ci_has 'test-integrity-resolve:' \
  && ci_has 'test-integrity-base:' \
  && ci_has 'test-integrity-head:' \
  && ci_has '^  test-integrity:' \
  && ci_has 'name: test-integrity' \
  && ci_has 'if: \$\{\{ always\(\) \}\}'; then
  ok "four test-integrity jobs present; final uniquely named test-integrity; always()"
else
  bad "missing four-job architecture or always() final (see ci/gibson-gate.yml)"
fi

# Final depends on all three priors
if ci_has 'needs:' \
  && grep -A6 '^  test-integrity:' "$CI_YML" | grep 'test-integrity-resolve' >/dev/null \
  && grep -A6 '^  test-integrity:' "$CI_YML" | grep 'test-integrity-base' >/dev/null \
  && grep -A6 '^  test-integrity:' "$CI_YML" | grep 'test-integrity-head' >/dev/null; then
  ok "final test-integrity needs resolve + base + head"
else
  bad "final job does not depend on all three prior jobs"
fi

echo "phase-2 CI: pull_request only; no privileged triggers / path filters"
if ci_has '^on:' \
  && ci_has 'pull_request:' \
  && ci_has_not 'pull_request_target' \
  && ci_has_not 'workflow_run:' \
  && ci_has_not 'workflow_dispatch:' \
  && ci_has_not '^  push:' \
  && ci_has_not 'paths:' \
  && ci_has_not 'paths-ignore:'; then
  ok "only pull_request trigger; no privileged trigger or path filter"
else
  bad "trigger surface not restricted to bare pull_request"
fi

echo "phase-2 CI: least permissions, no secrets/cache/env/OIDC/self-hosted/continue-on-error"
if ci_has '^permissions: \{\}' \
  && ci_has 'contents: read' \
  && ci_has 'pull-requests: read' \
  && ci_has_not 'secrets\.' \
  && ci_has_not 'cache:' \
  && ci_has_not 'environment:' \
  && ci_has_not 'id-token:' \
  && ci_has_not 'self-hosted' \
  && ci_has_not 'continue-on-error:' \
  && ci_has_not 'permissions:\s*write' \
  && ci_has_not 'contents:\s*write' \
  && ci_has_not 'pull-requests:\s*write'; then
  ok "least permissions; no secrets/cache/environment/OIDC/self-hosted/continue-on-error"
else
  bad "permissions or banned workflow features present"
fi

# Job-level permission grant: final has pull-requests: read; capture jobs contents only
if grep -A20 'test-integrity-resolve:' "$CI_YML" | grep 'contents: read' >/dev/null \
  && grep -A30 'test-integrity-base:' "$CI_YML" | grep 'contents: read' >/dev/null \
  && grep -A30 'test-integrity-head:' "$CI_YML" | grep 'contents: read' >/dev/null \
  && grep -A25 '^  test-integrity:' "$CI_YML" | grep 'pull-requests: read' >/dev/null; then
  ok "resolve/capture contents:read; final contents+pull-requests:read"
else
  bad "job-level permission grants incorrect"
fi

echo "phase-2 CI: persist-credentials false; immutable action SHAs"
if ci_has 'persist-credentials: false' \
  && ! grep -qE 'uses:[[:space:]]*[^@]+@(v[0-9]|main|master|latest)' "$CI_YML" \
  && ! grep -qE 'uses:[[:space:]]*actions/checkout@v' "$CI_YML" \
  && ! grep -qE 'uses:[[:space:]]*actions/setup-node@v' "$CI_YML" \
  && ! grep -qE 'uses:[[:space:]]*actions/upload-artifact@v' "$CI_YML" \
  && ! grep -qE 'uses:[[:space:]]*actions/download-artifact@v' "$CI_YML"; then
  # Every uses: line must pin a 40-char hex SHA
  bad_pin=0
  while IFS= read -r line; do
    case "$line" in
      *uses:*)
        sha=$(printf '%s\n' "$line" | sed -n 's/.*@\([0-9a-fA-F]*\).*/\1/p')
        if ! printf '%s' "$sha" | grep -E '^[0-9a-fA-F]{40}$' >/dev/null; then
          bad_pin=1
          bad "action not pinned to full SHA: $line"
        fi
        ;;
    esac
  done < "$CI_YML"
  if [[ "$bad_pin" -eq 0 ]]; then
    ok "persist-credentials false; all actions pinned to full immutable SHAs"
  fi
else
  bad "persist-credentials or version-tag actions present"
fi

echo "phase-2 CI: separate base/head jobs; fork head repo + exact SHA; no gate.json"
if ci_has 'test-integrity-base:' \
  && ci_has 'test-integrity-head:' \
  && ci_has 'head\.repo\.full_name' \
  && ci_has 'head\.sha' \
  && ci_has 'base\.sha' \
  && ci_has 'merge_base' \
  && ci_has_not '\.agents/gate\.json' \
  && ci_has 'TEST_COMMAND' \
  && ci_has '__GIBSON_TEST_COMMAND__'; then
  ok "separate base/head jobs; fork head.repo + exact SHAs; no PR-head gate.json"
else
  bad "base/head isolation or fork/SHA wiring missing"
fi

echo "phase-2 CI: inert waiver file; trusted-source merge-base; 8 MiB; grader from merge-base"
if ci_has 'waiver-file' \
  && ci_has 'pr-body\.txt' \
  && ci_has 'trusted-source' \
  && ci_has 'merge-base:' \
  && ci_has '8388608' \
  && ci_has 'sparse-checkout' \
  && ci_has 'scripts/test-integrity\.mjs' \
  && ci_has_not 'waiver-text:.*\$\{\{' \
  && ci_has_not '(^|[^a-zA-Z_-])eval[[:space:]]' \
  && ci_has_not '(^|[^a-zA-Z_-])source[[:space:]]+[^s]'; then
  ok "inert --waiver-file; merge-base trusted-source; 8 MiB; sparse helper; no eval"
else
  bad "final comparison contract incomplete"
fi

# No fixed-path RUNNER_TEMP trusted symlink race (phase-1 class) — grader is
# copied from merge-base checkout after sparse checkout, not a pre-poisoned path.
if ci_has_not 'test-integrity\.trusted' \
  && ci_has 'ti-grader'; then
  ok "no fixed-path test-integrity.trusted symlink target; grader isolated under ti-grader"
else
  bad "fixed-path trusted helper race class still present"
fi

echo "phase-2 CI: missing trusted helper yields explicit update/rebase failure"
if grep -q 'update or rebase' "$CI_YML" \
  && grep -q 'scripts/test-integrity.mjs missing' "$CI_YML" \
  && grep -qE '100644\|100755|100644 or 100755' "$CI_YML" \
  && grep -q 'symlink' "$CI_YML"; then
  ok "resolve fails closed with update/rebase message; blob mode 100644/100755 only"
else
  bad "missing helper / blob-mode fail-closed messaging incomplete"
fi

echo "phase-2 CI: merge-base --all requires exactly one best base (no first-of-many)"
# Contract pin: resolve must use --all and fail closed on multi-base/criss-cross.
# Reject single-result-only resolution (git merge-base without --all as the
# authority selector). Ancestor checks may still use merge-base --is-ancestor.
# ls-tree may still use head -n 1 for a single path entry — that is unrelated.
if grep -q 'git merge-base --all' "$CI_YML" \
  && grep -q 'ambiguous/criss-cross' "$CI_YML" \
  && grep -q 'exactly one' "$CI_YML" \
  && grep -q 'mb_count' "$CI_YML" \
  && grep -q 'Never sort/select/pick the first of many' "$CI_YML" \
  && ! grep -qE 'git merge-base "\$BASE_SHA" "\$HEAD_SHA"' "$CI_YML" \
  && ! grep -qE 'merge-base --all[^|]*\|[[:space:]]*head' "$CI_YML"; then
  ok "merge-base --all uniqueness; criss-cross diagnostic; no single-result pick"
else
  bad "merge-base uniqueness fail-closed contract incomplete in ci/gibson-gate.yml"
fi

echo "phase-2 CI: github-hosted only; ephemeral runners"
if ci_has 'runs-on: ubuntu-latest' \
  && ci_has_not 'self-hosted' \
  && ci_has_not 'runs-on:.*\['; then
  ok "GitHub-hosted ubuntu-latest only (no self-hosted matrix)"
else
  bad "runner configuration not github-hosted ephemeral only"
fi

# ---------------------------------------------------------------------------
# Offline simulation of final-job artifact validation + integrity compare
# ---------------------------------------------------------------------------
echo "phase-2 offline: failing base total 10 vs passing head total 7 still compares and fails"
MAX_BYTES=8388608
ART="$ROOT/ti-art"
mkdir -p "$ART/base" "$ART/head" "$ART/grader"
cp "$TI" "$ART/grader/test-integrity.mjs"
chmod 0555 "$ART/grader/test-integrity.mjs"

# Shared offline validator mirroring ci/gibson-gate.yml final job (hostile inputs).
# Usage: ti_validate_capture DIR EXPECT_ROLE EXPECT_SHA LABEL RUN_ID RUN_ATTEMPT
ti_validate_capture() {
  _dir="$1"; _role="$2"; _sha="$3"; _label="$4"; _rid="$5"; _att="$6"
  _meta="$_dir/metadata.json"
  _out="$_dir/test-output.txt"
  _ec="$_dir/exit-code.txt"
  for _f in "$_meta" "$_out" "$_ec"; do
    [[ -e "$_f" ]] || { echo "missing $(basename "$_f")"; return 1; }
    [[ ! -L "$_f" ]] || { echo "symlink $(basename "$_f")"; return 1; }
    [[ -f "$_f" ]] || { echo "not-file $(basename "$_f")"; return 1; }
    _sz=$(wc -c < "$_f" | tr -d ' ')
    [[ "$_sz" -le "$MAX_BYTES" ]] || { echo "oversized $(basename "$_f")"; return 1; }
  done
  node -e '
    const fs = require("fs");
    const [path, er, es, rid, att, label] = process.argv.slice(1);
    let data;
    try { data = JSON.parse(fs.readFileSync(path, "utf8")); }
    catch (e) { console.error("malformed metadata"); process.exit(1); }
    if (!data || typeof data !== "object") process.exit(1);
    if (data.role !== er) { console.error("wrong role"); process.exit(1); }
    if (String(data.source_sha).toLowerCase() !== String(es).toLowerCase()) {
      console.error("wrong sha"); process.exit(1);
    }
    if (String(data.run_id) !== String(rid)) { console.error("wrong run_id"); process.exit(1); }
    if (String(data.run_attempt) !== String(att)) { console.error("wrong run_attempt"); process.exit(1); }
  ' "$_meta" "$_role" "$_sha" "$_rid" "$_att" "$_label" || return 1
  _ec_val=$(tr -d ' \t\r' < "$_ec")
  [[ -n "$_ec_val" ]] || { echo "empty exit-code"; return 1; }
  return 0
}

write_capture() { # dir role sha rid att total exit_code
  _d="$1"; mkdir -p "$_d"
  cat > "$_d/metadata.json" <<EOF
{"role": "$2", "source_sha": "$3", "run_id": "$4", "run_attempt": "$5"}
EOF
  printf 'GIBSON_TEST_METRICS total=%s skipped=0 todo=0\n' "$6" > "$_d/test-output.txt"
  printf '%s\n' "$7" > "$_d/exit-code.txt"
}

MB_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RID="99"; ATT="1"

# Failing base (exit 1, total 10) vs passing head (exit 0, total 7)
write_capture "$ART/base" base "$MB_SHA" "$RID" "$ATT" 10 1
write_capture "$ART/head" head "$HD_SHA" "$RID" "$ATT" 7 0

ti_validate_capture "$ART/base" base "$MB_SHA" base "$RID" "$ATT" \
  && ti_validate_capture "$ART/head" head "$HD_SHA" head "$RID" "$ATT" \
  && ok "artifact metadata role/SHA/run validation accepts well-formed base+head" \
  || bad "well-formed capture validation failed"

node "$ART/grader/test-integrity.mjs" parse \
  --input "$ART/base/test-output.txt" --out "$ART/base-m.json"
node "$ART/grader/test-integrity.mjs" parse \
  --input "$ART/head/test-output.txt" --out "$ART/head-m.json"
out=$(node "$ART/grader/test-integrity.mjs" compare \
  --base "$ART/base-m.json" --head "$ART/head-m.json" \
  --waiver-text "" \
  --trusted-source "merge-base:${MB_SHA}" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -E 'dropped by 3|removed 3' >/dev/null \
  && echo "$out" | grep '10' >/dev/null && echo "$out" | grep '7' >/dev/null \
  && echo "$out" | grep "merge-base:${MB_SHA}" >/dev/null; then
  ok "failing base total 10 vs passing head total 7 still compares and fails 10→7"
else
  bad "failing-base compare (rc=$rc): $out"
fi

echo "phase-2 offline: hostile head replaces helper; trusted base helper still fails"
HOSTILE2="$ROOT/hostile2/scripts"
mkdir -p "$HOSTILE2"
cat > "$HOSTILE2/test-integrity.mjs" <<'HOSTILE'
#!/usr/bin/env node
if (process.argv[2] === 'compare') {
  console.log('test-integrity: PASS (hostile always-green helper)');
  process.exit(0);
}
process.exit(0);
HOSTILE
# Final job uses grader copy from merge-base, never head tree.
out=$(node "$ART/grader/test-integrity.mjs" compare \
  --base "$ART/base-m.json" --head "$ART/head-m.json" \
  --trusted-source "merge-base:${MB_SHA}" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -E 'dropped by 3|removed 3' >/dev/null; then
  ok "hostile head always-green helper ignored; trusted base helper still fails"
else
  bad "trusted grader did not fail deletion (rc=$rc): $out"
fi
# Prove the hostile helper would self-approve if used
out=$(node "$HOSTILE2/test-integrity.mjs" compare \
  --base "$ART/base-m.json" --head "$ART/head-m.json" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "hostile helper would self-approve (why final never runs head code)" \
  || bad "hostile helper fixture broken"

echo "phase-2 offline: head deletes helper; base helper still grades"
# Simulate: head tree has no helper; final job still has grader from merge-base.
rm -f "$HOSTILE2/test-integrity.mjs"
out=$(node "$ART/grader/test-integrity.mjs" compare \
  --base "$ART/base-m.json" --head "$ART/head-m.json" \
  --trusted-source "merge-base:${MB_SHA}" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -E 'dropped by 3|removed 3' >/dev/null \
  && ok "head deletes helper; base/merge-base helper still grades" \
  || bad "grader without head helper (rc=$rc): $out"

echo "phase-2 offline: exact visible waiver passes; hidden/malformed/wrong/phantom fail"
waiver_ok='Test-integrity: removed 3 for obsolete suite under #70'
out=$(node "$ART/grader/test-integrity.mjs" compare \
  --base "$ART/base-m.json" --head "$ART/head-m.json" \
  --waiver-file <(printf '%s\n' "$waiver_ok") \
  --trusted-source "merge-base:${MB_SHA}" 2>&1); rc=$?
# bash 3.2 may not support process substitution with --waiver-file on all platforms;
# write a real file instead.
printf '%s\n' "$waiver_ok" > "$ART/waiver-ok.txt"
out=$(node "$ART/grader/test-integrity.mjs" compare \
  --base "$ART/base-m.json" --head "$ART/head-m.json" \
  --waiver-file "$ART/waiver-ok.txt" \
  --trusted-source "merge-base:${MB_SHA}" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep 'WAIVER accepted' >/dev/null \
  && echo "$out" | grep 'removed 3' >/dev/null && echo "$out" | grep 'obsolete suite' >/dev/null; then
  ok "exact visible waiver passes and is surfaced (inert --waiver-file)"
else
  bad "exact waiver via file (rc=$rc): $out"
fi

printf '%s\n' '<!-- Test-integrity: removed 3 for secretly -->' > "$ART/waiver-hidden.txt"
out=$(node "$ART/grader/test-integrity.mjs" compare \
  --base "$ART/base-m.json" --head "$ART/head-m.json" \
  --waiver-file "$ART/waiver-hidden.txt" \
  --trusted-source "merge-base:${MB_SHA}" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ! echo "$out" | grep 'WAIVER accepted' >/dev/null \
  && ok "hidden HTML waiver via --waiver-file fails closed" \
  || bad "hidden waiver accepted (rc=$rc): $out"

printf '%s\n' 'Test-integrity: removed 2 for undercount' > "$ART/waiver-wrong.txt"
out=$(node "$ART/grader/test-integrity.mjs" compare \
  --base "$ART/base-m.json" --head "$ART/head-m.json" \
  --waiver-file "$ART/waiver-wrong.txt" \
  --trusted-source "merge-base:${MB_SHA}" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -i 'wrong delta' >/dev/null \
  && ok "wrong-delta waiver via --waiver-file fails closed" \
  || bad "wrong-delta waiver (rc=$rc): $out"

# Phantom waiver on non-shrinking suite
write_metrics "$ART/same-b.json" 10 0 0
write_metrics "$ART/same-h.json" 10 0 0
printf '%s\n' 'Test-integrity: removed 3 for phantom' > "$ART/waiver-phantom.txt"
out=$(node "$ART/grader/test-integrity.mjs" compare \
  --base "$ART/same-b.json" --head "$ART/same-h.json" \
  --waiver-file "$ART/waiver-phantom.txt" \
  --trusted-source "merge-base:${MB_SHA}" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "phantom waiver (no integrity reduction) fails closed" \
  || bad "phantom waiver accepted (rc=$rc): $out"

printf '%s\n' 'test-integrity: removed 3 for near' > "$ART/waiver-malformed.txt"
out=$(node "$ART/grader/test-integrity.mjs" compare \
  --base "$ART/base-m.json" --head "$ART/head-m.json" \
  --waiver-file "$ART/waiver-malformed.txt" \
  --trusted-source "merge-base:${MB_SHA}" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "malformed waiver label via --waiver-file fails closed" \
  || bad "malformed waiver accepted (rc=$rc): $out"

echo "phase-2 offline: missing/empty/duplicate/wrong-SHA/wrong-role/symlink/malformed/oversized artifacts fail"
# missing
rm -rf "$ART/bad"; mkdir -p "$ART/bad"
if ! ti_validate_capture "$ART/bad" base "$MB_SHA" bad "$RID" "$ATT" 2>/dev/null; then
  ok "missing artifact files fail validation"
else
  bad "missing artifact wrongly accepted"
fi

# empty exit-code
write_capture "$ART/empty" base "$MB_SHA" "$RID" "$ATT" 10 1
: > "$ART/empty/exit-code.txt"
if ! ti_validate_capture "$ART/empty" base "$MB_SHA" empty "$RID" "$ATT" 2>/dev/null; then
  ok "empty exit-code.txt fails validation"
else
  bad "empty exit-code accepted"
fi

# wrong SHA
write_capture "$ART/wsha" base "$MB_SHA" "$RID" "$ATT" 10 0
# overwrite metadata with wrong sha
printf '%s\n' '{"role":"base","source_sha":"cccccccccccccccccccccccccccccccccccccccc","run_id":"99","run_attempt":"1"}' \
  > "$ART/wsha/metadata.json"
if ! ti_validate_capture "$ART/wsha" base "$MB_SHA" wsha "$RID" "$ATT" 2>/dev/null; then
  ok "wrong source_sha fails validation"
else
  bad "wrong SHA accepted"
fi

# wrong role
write_capture "$ART/wrole" head "$MB_SHA" "$RID" "$ATT" 10 0
if ! ti_validate_capture "$ART/wrole" base "$MB_SHA" wrole "$RID" "$ATT" 2>/dev/null; then
  ok "wrong role fails validation"
else
  bad "wrong role accepted"
fi

# duplicate / swapped roles: head artifact claiming role=base
write_capture "$ART/dup" base "$HD_SHA" "$RID" "$ATT" 7 0
if ! ti_validate_capture "$ART/dup" head "$HD_SHA" dup "$RID" "$ATT" 2>/dev/null; then
  ok "duplicate/wrong-role head-as-base fails validation"
else
  bad "duplicate role accepted"
fi

# malformed metadata
write_capture "$ART/mal" base "$MB_SHA" "$RID" "$ATT" 10 0
printf '%s\n' 'not-json{' > "$ART/mal/metadata.json"
if ! ti_validate_capture "$ART/mal" base "$MB_SHA" mal "$RID" "$ATT" 2>/dev/null; then
  ok "malformed metadata.json fails validation"
else
  bad "malformed metadata accepted"
fi

# symlink file refused
write_capture "$ART/sym" base "$MB_SHA" "$RID" "$ATT" 10 0
rm -f "$ART/sym/test-output.txt"
ln -s /etc/passwd "$ART/sym/test-output.txt"
if ! ti_validate_capture "$ART/sym" base "$MB_SHA" sym "$RID" "$ATT" 2>/dev/null; then
  ok "symlink artifact file refused"
else
  bad "symlink artifact accepted"
fi

# oversized > 8 MiB
write_capture "$ART/big" base "$MB_SHA" "$RID" "$ATT" 10 0
# Create a file just over 8 MiB (portable: dd)
dd if=/dev/zero of="$ART/big/test-output.txt" bs=1024 count=8193 2>/dev/null \
  || dd if=/dev/zero of="$ART/big/test-output.txt" bs=8193 count=1024 2>/dev/null
if ! ti_validate_capture "$ART/big" base "$MB_SHA" big "$RID" "$ATT" 2>/dev/null; then
  ok "oversized >8 MiB artifact fails validation"
else
  bad "oversized artifact accepted"
fi

echo "phase-2 offline: resolve/capture failure still runs final job and fails"
# Simulate always() final: if any prior result != success → exit 1.
sim_final() {
  _resolve="$1"; _base="$2"; _head="$3"
  if [[ "$_resolve" != "success" || "$_base" != "success" || "$_head" != "success" ]]; then
    echo "test-integrity: prior job failure (fail closed)."
    echo "  resolve=${_resolve} base=${_base} head=${_head}"
    return 1
  fi
  return 0
}
sim_final failure success success; rc=$?
[[ "$rc" -ne 0 ]] && ok "resolve failure → final fails closed (always() path)" \
  || bad "resolve failure did not fail final"
sim_final success failure success; rc=$?
[[ "$rc" -ne 0 ]] && ok "base capture failure → final fails closed" \
  || bad "base failure did not fail final"
sim_final success success failure; rc=$?
[[ "$rc" -ne 0 ]] && ok "head capture/upload failure → final fails closed" \
  || bad "head failure did not fail final"
sim_final success success success; rc=$?
[[ "$rc" -eq 0 ]] && ok "all priors success → final proceeds to compare" \
  || bad "success path blocked"

echo "phase-2 offline: criss-cross two best merge bases fail closed; unique base succeeds"
# Canonical resolver snippet matching ci/gibson-gate.yml (merge-base --all uniqueness).
# Must exercise real git graphs — a string-only "--all" assertion is insufficient.
is_full_sha() {
  case "$1" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) return 0 ;;
    *) return 1 ;;
  esac
}
# resolve_unique_merge_base BASE_SHA HEAD_SHA — prints sole full SHA or fails closed.
# Mirrors the post-fetch uniqueness block in ci/gibson-gate.yml test-integrity-resolve.
resolve_unique_merge_base() {
  _base="$1"
  _head="$2"
  _mb_raw=""
  if ! _mb_raw=$(git merge-base --all "$_base" "$_head" 2>/dev/null); then
    echo "test-integrity: resolve failed — uncomputable merge-base (git merge-base --all failed; ancestry incomplete)" >&2
    echo "test-integrity: update or rebase this PR onto a base that contains scripts/test-integrity.mjs as a regular blob (mode 100644 or 100755) at the merge-base, with unambiguous ancestry." >&2
    return 1
  fi
  if [ -z "$_mb_raw" ]; then
    echo "test-integrity: resolve failed — zero best merge bases from git merge-base --all" >&2
    echo "test-integrity: update or rebase this PR onto a base that contains scripts/test-integrity.mjs as a regular blob (mode 100644 or 100755) at the merge-base, with unambiguous ancestry." >&2
    return 1
  fi
  _mb_count=0
  _merge_base=""
  _mb_seen=" "
  # Same temp-file iteration as ci/gibson-gate.yml (no first-of-many, no pipeline subshell).
  _mb_list=$(mktemp)
  printf '%s\n' "$_mb_raw" > "$_mb_list"
  while IFS= read -r _mb_line || [ -n "$_mb_line" ]; do
    if [ -z "$_mb_line" ]; then
      rm -f "$_mb_list"
      echo "test-integrity: resolve failed — malformed merge-base --all output (empty line)" >&2
      return 1
    fi
    if ! is_full_sha "$_mb_line"; then
      rm -f "$_mb_list"
      echo "test-integrity: resolve failed — merge-base is not a full SHA" >&2
      return 1
    fi
    case "$_mb_seen" in
      *" $_mb_line "*)
        rm -f "$_mb_list"
        echo "test-integrity: resolve failed — duplicate merge-base lines from git merge-base --all" >&2
        return 1
        ;;
    esac
    _mb_seen="${_mb_seen}${_mb_line} "
    _mb_count=$((_mb_count + 1))
    _merge_base="$_mb_line"
  done < "$_mb_list"
  rm -f "$_mb_list"
  if [ "$_mb_count" -eq 0 ]; then
    echo "test-integrity: resolve failed — zero best merge bases from git merge-base --all" >&2
    return 1
  fi
  if [ "$_mb_count" -ne 1 ]; then
    echo "test-integrity: resolve failed — ambiguous/criss-cross history: git merge-base --all returned ${_mb_count} best merge bases (need exactly one trusted base). Update or rebase this PR onto a history with a single unambiguous merge-base before grading." >&2
    echo "test-integrity: update or rebase this PR onto a base that contains scripts/test-integrity.mjs as a regular blob (mode 100644 or 100755) at the merge-base, with unambiguous ancestry." >&2
    return 1
  fi
  if ! is_full_sha "$_merge_base"; then
    echo "test-integrity: resolve failed — merge-base is not a full SHA" >&2
    return 1
  fi
  # Ancestor checks (same as CI after uniqueness).
  git merge-base --is-ancestor "$_merge_base" "$_base" \
    || { echo "test-integrity: resolve failed — merge-base is not an ancestor of base.sha" >&2; return 1; }
  git merge-base --is-ancestor "$_merge_base" "$_head" \
    || { echo "test-integrity: resolve failed — merge-base is not an ancestor of head.sha" >&2; return 1; }
  printf '%s\n' "$_merge_base"
  return 0
}

# Build a deterministic criss-cross graph with two best merge bases and different
# trusted helper contents at each base (proves arbitrary first-line pick is unsafe).
CX="$ROOT/criss-cross"
rm -rf "$CX"
mkdir -p "$CX"
(
  cd "$CX"
  git init -q
  git config user.email "gate-test@example.com"
  git config user.name "gate-test"
  git config commit.gpgsign false
  # Root O
  mkdir -p scripts
  printf '%s\n' 'root-helper' > scripts/test-integrity.mjs
  git add scripts/test-integrity.mjs
  git commit -qm O
  O=$(git rev-parse HEAD)
  # left: O - A (helper content "trusted-A")
  git checkout -q -b left
  printf '%s\n' 'trusted-A-helper-content-aaaaaaaa' > scripts/test-integrity.mjs
  git add scripts/test-integrity.mjs
  git commit -qm A
  # right: O - B (helper content "trusted-B" — different from A)
  git checkout -q -b right "$O"
  printf '%s\n' 'trusted-B-helper-content-bbbbbbbb' > scripts/test-integrity.mjs
  git add scripts/test-integrity.mjs
  git commit -qm B
  B=$(git rev-parse HEAD)
  # Mr = merge left into right (parents B, A)
  git merge -q -m Mr left -X ours
  # Ml = on left, merge B (not Mr) — parents A, B → classic criss-cross
  git checkout -q left
  git merge -q -m Ml "$B" -X ours
)
# Resolve branch tips
CX_LEFT=$(git -C "$CX" rev-parse left)
CX_RIGHT=$(git -C "$CX" rev-parse right)
# Prove the graph really has two best merge bases (fixture integrity)
CX_ALL=$(git -C "$CX" merge-base --all "$CX_LEFT" "$CX_RIGHT")
CX_ALL_N=$(printf '%s\n' "$CX_ALL" | grep -c . || true)
CX_SINGLE=$(git -C "$CX" merge-base "$CX_LEFT" "$CX_RIGHT")
if [ "$CX_ALL_N" -eq 2 ] && [ -n "$CX_SINGLE" ]; then
  ok "criss-cross fixture: merge-base --all returns 2; single merge-base returns one arbitrary"
else
  bad "criss-cross fixture broken (all_n=$CX_ALL_N single=$CX_SINGLE all=$CX_ALL)"
fi
# Different trusted helper contents at the two best bases
CX_B1=$(printf '%s\n' "$CX_ALL" | sed -n '1p')
CX_B2=$(printf '%s\n' "$CX_ALL" | sed -n '2p')
CX_H1=$(git -C "$CX" show "${CX_B1}:scripts/test-integrity.mjs" 2>/dev/null || true)
CX_H2=$(git -C "$CX" show "${CX_B2}:scripts/test-integrity.mjs" 2>/dev/null || true)
if [ -n "$CX_H1" ] && [ -n "$CX_H2" ] && [ "$CX_H1" != "$CX_H2" ]; then
  ok "criss-cross fixture: two best bases carry different trusted helper contents"
else
  bad "criss-cross helpers not divergent (h1=$CX_H1 h2=$CX_H2)"
fi
# Resolver must fail closed — never accept arbitrary single merge-base authority
(
  cd "$CX"
  out=$(resolve_unique_merge_base "$CX_LEFT" "$CX_RIGHT" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] \
    && echo "$out" | grep 'ambiguous/criss-cross' >/dev/null \
    && echo "$out" | grep 'exactly one' >/dev/null \
    && echo "$out" | grep -E 'returned 2|2 best' >/dev/null \
    && ! echo "$out" | grep -E '^[0-9a-fA-F]{40}$' >/dev/null; then
    ok "criss-cross: resolve_unique_merge_base fails closed (no arbitrary grader authority)"
  else
    bad "criss-cross should fail closed (rc=$rc): $out"
  fi
)
# Prove single-result git merge-base would have picked one base (unsafe path we refuse)
if is_full_sha "$CX_SINGLE" \
  && { [ "$CX_SINGLE" = "$CX_B1" ] || [ "$CX_SINGLE" = "$CX_B2" ]; }; then
  ok "single git merge-base would pick one of two bases (why --all uniqueness is required)"
else
  bad "unexpected single merge-base $CX_SINGLE vs $CX_B1 / $CX_B2"
fi

# Unique merge-base path still succeeds (linear history)
UX="$ROOT/unique-mb"
rm -rf "$UX"
mkdir -p "$UX"
(
  cd "$UX"
  git init -q
  git config user.email "gate-test@example.com"
  git config user.name "gate-test"
  git config commit.gpgsign false
  mkdir -p scripts
  printf '%s\n' 'unique-helper' > scripts/test-integrity.mjs
  git add scripts/test-integrity.mjs
  git commit -qm root
  echo mid > mid.txt && git add mid.txt && git commit -qm mid
  git branch base-tip
  echo head > head.txt && git add head.txt && git commit -qm head
)
UX_BASE=$(git -C "$UX" rev-parse base-tip)
UX_HEAD=$(git -C "$UX" rev-parse HEAD)
UX_EXPECT=$(git -C "$UX" merge-base --all "$UX_BASE" "$UX_HEAD")
(
  cd "$UX"
  out=$(resolve_unique_merge_base "$UX_BASE" "$UX_HEAD" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$UX_EXPECT" ] && is_full_sha "$out"; then
    ok "unique merge-base: resolve_unique_merge_base succeeds with sole full SHA"
  else
    bad "unique merge-base should succeed (rc=$rc out=$out expect=$UX_EXPECT)"
  fi
)
# Malformed / zero / duplicate lines fail closed (unit of the snippet)
(
  cd "$UX"
  # Zero: unrelated histories
  git checkout -q --orphan other-root
  git config commit.gpgsign false
  echo other > other.txt && git add other.txt && git commit -qm other
  OTHER=$(git rev-parse HEAD)
  git checkout -q master 2>/dev/null || git checkout -q main 2>/dev/null || git checkout -q -
  out=$(resolve_unique_merge_base "$UX_HEAD" "$OTHER" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "unrelated histories: merge-base --all fails closed"
  else
    bad "unrelated histories should fail (out=$out)"
  fi
)

echo "phase-2 offline: missing trusted helper at merge-base → update/rebase failure"
# Resolve simulation: ls-tree empty → fail with explicit message
sim_resolve_helper() {
  _entry="$1"
  if [[ -z "$_entry" ]]; then
    echo "test-integrity: resolve failed — scripts/test-integrity.mjs missing at merge-base"
    echo "test-integrity: update or rebase this PR onto a base that contains scripts/test-integrity.mjs as a regular blob (mode 100644 or 100755) at the merge-base, with unambiguous ancestry."
    return 1
  fi
  _mode=$(printf '%s\n' "$_entry" | awk '{print $1}')
  _type=$(printf '%s\n' "$_entry" | awk '{print $2}')
  [[ "$_type" = "blob" ]] || { echo "not blob"; return 1; }
  case "$_mode" in
    100644|100755) return 0 ;;
    120000) echo "symlink refused"; return 1 ;;
    160000) echo "gitlink refused"; return 1 ;;
    *) echo "bad mode"; return 1 ;;
  esac
}
out=$(sim_resolve_helper "" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep 'update or rebase' >/dev/null \
  && echo "$out" | grep 'missing' >/dev/null \
  && ok "missing trusted helper yields explicit update/rebase failure" \
  || bad "missing helper message (rc=$rc): $out"
out=$(sim_resolve_helper "120000 blob deadbeef\tscripts/test-integrity.mjs" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "symlink mode 120000 helper refused at resolve" \
  || bad "symlink helper accepted"
out=$(sim_resolve_helper "160000 blob deadbeef\tscripts/test-integrity.mjs" 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "gitlink mode 160000 helper refused at resolve" \
  || bad "gitlink helper accepted"
out=$(sim_resolve_helper "100644 blob deadbeef\tscripts/test-integrity.mjs" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "regular blob mode 100644 helper accepted at resolve" \
  || bad "regular blob refused"
out=$(sim_resolve_helper "100755 blob deadbeef\tscripts/test-integrity.mjs" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "regular blob mode 100755 helper accepted at resolve" \
  || bad "executable blob refused"

echo "phase-2 offline: base/head use separate job/workspace definitions"
# Distinct job keys and distinct artifact names in the template
if grep -c 'test-integrity-base-' "$CI_YML" | grep '[1-9]' >/dev/null \
  && grep -c 'test-integrity-head-' "$CI_YML" | grep '[1-9]' >/dev/null \
  && ! grep -A2 'test-integrity-base:' "$CI_YML" | grep 'test-integrity-head' >/dev/null \
  && grep -q 'ti-artifact' "$CI_YML"; then
  ok "base/head separate job keys, artifact names, and workspace paths"
else
  bad "base/head workspace isolation not defined in template"
fi

echo "phase-2 offline: fork head repository wiring present"
if grep -q 'head\.repo\.full_name' "$CI_YML" \
  && grep -q 'head_repo' "$CI_YML" \
  && grep -q 'repository: \${{ needs.test-integrity-resolve.outputs.head_repo }}' "$CI_YML" \
  && grep -q 'ref: \${{ needs.test-integrity-resolve.outputs.head_sha }}' "$CI_YML"; then
  ok "fork head repository + exact head SHA checkout wiring"
else
  bad "fork head repository wiring missing"
fi

# Phase-2 replaces the phase-1 "must remain unwired" assertion with the exact
# new contract above (four jobs, always(), trusted merge-base grader, etc.).
# Pin that the old phase-1 ok() message is gone and the new contract is required.
# Construct the banned phase-1 string in pieces so this sensor does not match itself.
_p1_ban="ci/gibson-gate.yml unwired"
_p1_ban="${_p1_ban} for test-integrity (phase-1 bootstrap"
if ! grep -qF "$_p1_ban" "$SCRIPT_DIR/gate.test.sh" \
  && grep -q 'phase-2 protected CI contract' "$SCRIPT_DIR/gate.test.sh" \
  && grep -q 'test-integrity-resolve' "$CI_YML" \
  && grep -qF 'if: ${{ always() }}' "$CI_YML"; then
  ok "phase-1 bootstrap pin replaced with exact phase-2 contract (not merely removed)"
else
  bad "phase-1 bootstrap pin still present or phase-2 contract absent"
fi
unset _p1_ban

# ---------------------------------------------------------------------------
# #99 / L-050 — path_dev_ino must distinguish two files on the same filesystem.
# BSD-first `stat -f` on GNU coreutils means --file-system; free-blocks+fsid
# can make every file on a mount look identical. Production sites must probe
# GNU (-c) first, BSD (-f) second.
# ---------------------------------------------------------------------------
echo "#99 path_dev_ino: GNU-first ordering + two files on one fs get distinct ids"

# Static contract: every production site probes -c before -f on the same line
# (or with only || between them, -c first).
for site in \
  "$SCRIPT_DIR/../gate.sh" \
  "$SCRIPT_DIR/../gate-baseline.sh" \
  "$SCRIPT_DIR/../loop.sh" \
  "$SCRIPT_DIR/../claim-reaper.sh"
do
  base=$(basename "$site")
  # Collect lines that call stat for identity/mtime. Each must have -c before -f.
  bad_order=0
  while IFS= read -r line; do
    # Strip leading whitespace for comment detection
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      \#*|'') continue ;;
      *stat*)
        cpos=$(printf '%s' "$trimmed" | awk '{p=index($0,"stat -c"); if(p==0)p=-1; print p}')
        fpos=$(printf '%s' "$trimmed" | awk '{p=index($0,"stat -f"); if(p==0)p=-1; print p}')
        if [[ "$fpos" -gt 0 ]]; then
          if [[ "$cpos" -le 0 || "$cpos" -gt "$fpos" ]]; then
            bad_order=1
            bad "#99 $base probes stat -f before stat -c: $trimmed"
          fi
        fi
        ;;
    esac
  done < "$site"
  if [[ "$bad_order" -eq 0 ]]; then
    ok "#99 $base: no BSD-first stat -f identity/mtime probe"
  fi
done

# Runtime: load path_dev_ino from gate-baseline (definition only) and assert
# two distinct regular files on the same mount get different dev:ino.
_id_dir=$(mktemp -d "${TMPDIR:-/tmp}/gibson-devino.XXXXXX")
_id_a="$_id_dir/a"
_id_b="$_id_dir/b"
printf 'a\n' > "$_id_a"
printf 'b\n' > "$_id_b"

# Source only the function body by evaluating the fixed portable form that
# production uses (mirrors gate-baseline.sh path_dev_ino).
path_dev_ino() {
  local p="$1" dev ino
  dev=$(stat -c %d -- "$p" 2>/dev/null || stat -f %d -- "$p" 2>/dev/null) || return 1
  ino=$(stat -c %i -- "$p" 2>/dev/null || stat -f %i -- "$p" 2>/dev/null) || return 1
  [[ -n "$dev" && -n "$ino" ]] || return 1
  printf '%s:%s' "$dev" "$ino"
}

ida=$(path_dev_ino "$_id_a") || ida=""
idb=$(path_dev_ino "$_id_b") || idb=""
if [[ -n "$ida" && -n "$idb" && "$ida" != "$idb" ]]; then
  ok "#99 path_dev_ino distinguishes two files on same fs ($ida vs $idb)"
else
  bad "#99 path_dev_ino failed to distinguish files (a=$ida b=$idb)"
fi

# Negative canary: BSD-first free-blocks/fsid pattern must NOT be what we ship.
# (Document the landmine so a regression reintroducing it fails this suite.)
path_dev_ino_bsd_first() {
  local p="$1" dev ino
  dev=$(stat -f %d -- "$p" 2>/dev/null) || dev=$(stat -c %d -- "$p" 2>/dev/null) || return 1
  ino=$(stat -f %i -- "$p" 2>/dev/null) || ino=$(stat -c %i -- "$p" 2>/dev/null) || return 1
  [[ -n "$dev" && -n "$ino" ]] || return 1
  printf '%s:%s' "$dev" "$ino"
}
# On this host the broken form may still distinguish via accidental exit codes;
# the hard requirement is that production sources match GNU-first (checked
# above) and the live helper distinguishes (checked above). Pin that the
# production gate-baseline definition is byte-equal to the GNU-first body we
# just exercised, by grepping the canonical line form.
if grep -qF 'dev=$(stat -c %d -- "$p" 2>/dev/null || stat -f %d -- "$p" 2>/dev/null)' \
     "$SCRIPT_DIR/../gate-baseline.sh" \
  && grep -qF 'ino=$(stat -c %i -- "$p" 2>/dev/null || stat -f %i -- "$p" 2>/dev/null)' \
     "$SCRIPT_DIR/../gate-baseline.sh" \
  && grep -qF 'dev=$(stat -c %d -- "$p" 2>/dev/null || stat -f %d -- "$p" 2>/dev/null)' \
     "$SCRIPT_DIR/../gate.sh" \
  && grep -qF 'ino=$(stat -c %i -- "$f" 2>/dev/null || stat -f %i -- "$f" 2>/dev/null)' \
     "$SCRIPT_DIR/../loop.sh" \
  && grep -qF 'mt=$(stat -c %Y -- "$f" 2>/dev/null || stat -f %m -- "$f" 2>/dev/null)' \
     "$SCRIPT_DIR/../claim-reaper.sh"; then
  ok "#99 production path_dev_ino / mtime lines are exact GNU-first form"
else
  bad "#99 production sites drifted from exact GNU-first form"
fi
rm -rf "$_id_dir"
unset -f path_dev_ino path_dev_ino_bsd_first

# ---------------------------------------------------------------------------
echo
echo "gate.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
