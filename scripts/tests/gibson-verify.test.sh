#!/usr/bin/env bash
# gibson-verify.test.sh — witnesses for scripts/gibson-verify.mjs (#447)
#
# WHY
#   gibson-verify is the lever an agent runs before it claims done. Each case
#   below pins one way a done-claim used to slip through without proof:
#     - verdict lint must classify exactly like second-opinion.sh
#       parse_isolated_verdict. The bash functions are extracted from
#       second-opinion.sh at test time and run on the same fixtures, so the
#       mirror cannot drift silently (fixtures come from second-opinion.test.sh).
#     - check fails a no-op diff (L-008), a dirty tree, a red gate, and a gate
#       that exits 0 while its log says NOT RUN (Law 8).
#     - report says claim-only without a receipt at HEAD, and treats Mission
#       Control's {ok:true,demo:true} "event dropped" answer as not delivered.
#     - unknown flags exit 2; doctor never prints env values.
#
# USAGE
#   scripts/tests/gibson-verify.test.sh
set -uo pipefail

export GIT_AUTHOR_NAME=gibson-sensor
export GIT_AUTHOR_EMAIL=sensor@gibson.invalid
export GIT_COMMITTER_NAME=gibson-sensor
export GIT_COMMITTER_EMAIL=sensor@gibson.invalid
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export LC_ALL=C
export LANG=C
unset MC_URL MC_TOKEN || true

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
GV="$REPO_ROOT/scripts/gibson-verify.mjs"
SECOND_OPINION="$REPO_ROOT/scripts/second-opinion.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "gibson-verify.test.sh: node required"; exit 1; }
command -v git >/dev/null || { echo "gibson-verify.test.sh: git required"; exit 1; }
[[ -f "$GV" ]] || { echo "gibson-verify.test.sh: missing $GV"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-verify.XXXXXX")
SERVER_PID=""
cleanup() { [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT

# Run gibson-verify; sets RC, OUT, ERR.
gv() { OUT=$(node "$GV" "$@" 2>"$ROOT/err"); RC=$?; ERR=$(cat "$ROOT/err"); }
# Read a dotted path from the JSON in $OUT.
jget() { printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let v=JSON.parse(s);for(const k of process.argv[1].split("."))v=v==null?v:v[k];console.log(typeof v==="object"?JSON.stringify(v):String(v))})' "$1"; }

echo "# usage contract"
gv --definitely-not-a-flag
[[ "$RC" -eq 2 ]] && printf '%s\n' "$ERR" | grep 'unknown flag: --definitely-not-a-flag' >/dev/null && ok "global unknown flag exits 2" || bad "global unknown flag (rc=$RC err=$ERR)"
gv check --definitely-not-a-flag
[[ "$RC" -eq 2 ]] && ok "subcommand unknown flag exits 2" || bad "check unknown flag (rc=$RC)"
gv verdict lint --definitely-not-a-flag
[[ "$RC" -eq 2 ]] && ok "verdict lint unknown flag exits 2" || bad "verdict lint unknown flag (rc=$RC)"
gv frobnicate
[[ "$RC" -eq 2 ]] && ok "unknown subcommand exits 2" || bad "unknown subcommand (rc=$RC)"
gv report --dry-run
[[ "$RC" -eq 2 ]] && ok "report without --agent exits 2" || bad "report without --agent (rc=$RC)"
gv --help
[[ "$RC" -eq 0 ]] && printf '%s\n' "$OUT" | grep 'WHAT IT DOES' >/dev/null && printf '%s\n' "$OUT" | grep 'RISKS' >/dev/null && ok "--help exits 0 and names WHAT IT DOES and RISKS" || bad "--help (rc=$RC)"

echo "# verdict lint mirrors second-opinion.sh parse_isolated_verdict"
SO_FUNCS="$ROOT/so-funcs.sh"
: > "$SO_FUNCS"
for fn in trim_ws strip_list_marker exact_verdict_event verdict_shaped_line parse_isolated_verdict; do
  sed -n "/^${fn}() {/,/^}/p" "$SECOND_OPINION" >> "$SO_FUNCS"
done
if [[ "$(grep -c '^[a-z_]*() {' "$SO_FUNCS")" -eq 5 ]]; then
  ok "extracted the 5 verdict functions from second-opinion.sh"
else
  bad "could not extract verdict functions from second-opinion.sh (renamed?)"
fi
# shellcheck source=/dev/null
. "$SO_FUNCS"

N=0
verdict_case() {
  local expect="$1" label="$2" body="$3" f want_rc
  N=$((N + 1))
  f="$ROOT/verdict-$N.txt"
  printf '%b' "$body" > "$f"
  _slot_state=""
  parse_isolated_verdict "$f"
  gv verdict lint "$f"
  want_rc=1
  [[ "$expect" == "approve" || "$expect" == "request-changes" ]] && want_rc=0
  if [[ "$_slot_state" == "$expect" && "$(jget state)" == "$expect" && "$RC" -eq "$want_rc" ]]; then
    ok "verdict: $label → $expect (bash and node agree)"
  else
    bad "verdict: $label expected $expect; bash=$_slot_state node=$(jget state) rc=$RC"
  fi
}
verdict_case approve "VERDICT: APPROVE" 'VERDICT: APPROVE\nlooks good\n'
verdict_case approve "alias VERDICT: approve" 'VERDICT: approve\n'
verdict_case request-changes "list-marker changes-requested" '1. VERDICT: changes-requested\n'
verdict_case request-changes "REQUEST_CHANGES" 'VERDICT: REQUEST_CHANGES\nfix it\n'
verdict_case no-verdict "VERDICT: PASS" 'VERDICT: PASS\n'
verdict_case invalid "extra standalone PASS after approve" 'VERDICT: APPROVE\n\nVERDICT: PASS\n'
verdict_case approve "prose mention of PASS is not a verdict line" 'VERDICT: APPROVE\n\nI mentioned VERDICT: PASS in passing.\n'
verdict_case no-verdict "prose-only approve" 'I would write VERDICT: APPROVE if the tests existed.\n'
verdict_case no-verdict "blockquote" '> VERDICT: APPROVE\n'
verdict_case no-verdict "heading" '## VERDICT: APPROVE\n'
verdict_case invalid "fenced example after prose" 'Example format:\n```\nVERDICT: APPROVE\n```\n'
verdict_case duplicate "duplicate approve" 'VERDICT: APPROVE\n\nnotes\n\nVERDICT: APPROVE\n'
verdict_case contradictory "approve then request changes" 'VERDICT: APPROVE\n\nVERDICT: REQUEST_CHANGES\n'
verdict_case empty "empty file" ''
verdict_case empty "whitespace only" '\n   \n\t\n'
verdict_case approve "CRLF line endings" 'VERDICT: APPROVE\r\nok\r\n'
verdict_case request-changes "no trailing newline" 'VERDICT: REQUEST_CHANGES'
verdict_case approve "leading blank lines and padding" '\n   VERDICT: APPROVE   \n'
verdict_case no-verdict "tab instead of space" 'VERDICT:\tAPPROVE\n'
gv verdict lint "$ROOT/does-not-exist.txt"
[[ "$RC" -eq 1 && "$(jget state)" == "empty" ]] && ok "verdict: missing file → empty, exit 1" || bad "missing file (rc=$RC out=$OUT)"

echo "# check / prove"
FX="$ROOT/fx"
mkdir -p "$FX/bin"
cat > "$FX/bin/pass.sh" <<'SH'
#!/usr/bin/env bash
echo "all 3 passed"
SH
cat > "$FX/bin/fail.sh" <<'SH'
#!/usr/bin/env bash
echo "1 failed, 2 passed"
exit 1
SH
cat > "$FX/bin/lie.sh" <<'SH'
#!/usr/bin/env bash
echo "NOT RUN: integration suite"
exit 0
SH
chmod +x "$FX/bin/"*.sh
GATES="$ROOT/gates"
mv "$FX/bin" "$GATES"
git -C "$FX" init -q -b main
echo one > "$FX/a.txt"
git -C "$FX" add a.txt && git -C "$FX" commit -q -m init
git -C "$FX" update-ref refs/remotes/origin/main HEAD

gv check --repo "$FX" --gate "$GATES/pass.sh"
[[ "$RC" -eq 1 && "$(jget verified)" == "false" ]] && printf '%s' "$OUT" | grep 'L-008' >/dev/null && ok "check: no diff vs base is a no-op, not success (L-008)" || bad "noop check (rc=$RC)"
printf '%s' "$OUT" | grep 'skipped: an earlier step failed' >/dev/null && ok "check: skipped steps are recorded as not ok" || bad "skipped steps missing"

echo two > "$FX/a.txt"
git -C "$FX" commit -q -am change
gv check --repo "$FX" --gate "$GATES/pass.sh"
[[ "$RC" -eq 0 && "$(jget verified)" == "true" ]] && ok "check: diff + green gate + truthful log → verified" || bad "green check (rc=$RC out=$OUT err=$ERR)"
gv check --repo "$FX" --gate "$GATES/pass.sh"
[[ "$RC" -eq 0 ]] && ok "check: its own receipts/logs do not dirty the tree" || bad "receipt dir counted as dirt (rc=$RC)"

echo dirty > "$FX/a.txt"
gv check --repo "$FX" --gate "$GATES/pass.sh"
[[ "$RC" -eq 1 ]] && printf '%s' "$OUT" | grep 'uncommitted changes' >/dev/null && ok "check: dirty tree fails (receipt must name an exact head)" || bad "dirty tree (rc=$RC)"
git -C "$FX" checkout -q -- a.txt

gv check --repo "$FX" --gate "$GATES/fail.sh"
[[ "$RC" -eq 1 && "$(jget verified)" == "false" ]] && ok "check: red gate fails" || bad "red gate (rc=$RC)"
gv check --repo "$FX" --gate "$GATES/lie.sh"
[[ "$RC" -eq 1 ]] && printf '%s' "$OUT" | grep 'NOT RUN' >/dev/null && ok "check: gate exit 0 with NOT RUN in its log fails (Law 8)" || bad "lying gate (rc=$RC out=$OUT)"
gv check --repo "$FX" --gate "$GATES/missing.sh"
[[ "$RC" -eq 1 ]] && ok "check: missing gate fails closed" || bad "missing gate (rc=$RC)"

gv prove --repo "$FX" --gate "$GATES/pass.sh"
HEAD_SHA=$(git -C "$FX" rev-parse HEAD)
RECEIPT="$FX/.gibson-receipts/$HEAD_SHA.json"
if [[ "$RC" -eq 0 && -f "$RECEIPT" ]] && grep '"schema": "gibson.verify-receipt.v1"' "$RECEIPT" >/dev/null && grep "\"head\": \"$HEAD_SHA\"" "$RECEIPT" >/dev/null; then
  ok "prove: writes .gibson-receipts/<HEAD>.json bound to the head SHA"
else
  bad "prove (rc=$RC receipt=$RECEIPT)"
fi

echo "# report"
gv report --repo "$FX" --agent carmack --dry-run --pr 7
[[ "$RC" -eq 0 && "$(jget status)" == "verified" && "$(jget payload.kind)" == "milestone" && "$(jget payload.agent_id)" == "carmack" ]] && ok "report: receipt at HEAD → verified milestone" || bad "verified report (rc=$RC out=$OUT)"
echo three > "$FX/a.txt"
git -C "$FX" commit -q -am later
gv report --repo "$FX" --agent carmack --dry-run
[[ "$RC" -eq 1 && "$(jget status)" == "claim-only" ]] && ok "report: no receipt for the new HEAD → claim-only" || bad "claim-only report (rc=$RC out=$OUT)"
gv report --repo "$FX" --agent carmack --dry-run --receipt "$RECEIPT"
[[ "$RC" -eq 1 && "$(jget status)" == "claim-only" ]] && printf '%s' "$OUT" | grep 'stale receipt' >/dev/null && ok "report: a receipt for an older head is stale → claim-only" || bad "stale receipt (rc=$RC out=$OUT)"
gv report --repo "$FX" --agent carmack
[[ "$RC" -eq 1 ]] && printf '%s' "$ERR" | grep 'MC_URL and MC_TOKEN' >/dev/null && ok "report: live POST without MC_URL/MC_TOKEN fails closed" || bad "missing env (rc=$RC err=$ERR)"

# A stub Mission Control: first answer is the no-database demo drop, second is real.
PORT_FILE="$ROOT/port"
node -e '
  const http = require("http"); let n = 0;
  const s = http.createServer((req, res) => { let b = ""; req.on("data", d => b += d).on("end", () => {
    const ok = req.headers.authorization === "Bearer t0k" && JSON.parse(b).kind === "milestone";
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify(!ok ? { error: "bad" } : n++ === 0 ? { ok: true, demo: true } : { ok: true }));
  }); });
  s.listen(0, "127.0.0.1", () => require("fs").writeFileSync(process.argv[1], String(s.address().port)));
' "$PORT_FILE" &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$PORT_FILE" ]] && break; sleep 0.2; done
if [[ -s "$PORT_FILE" ]]; then
  MC_URL="http://127.0.0.1:$(cat "$PORT_FILE")" MC_TOKEN=t0k gv report --repo "$FX" --agent carmack
  [[ "$RC" -eq 1 && "$(jget delivered)" == "false" ]] && ok "report: {ok:true,demo:true} (event dropped) is not delivered" || bad "demo drop (rc=$RC out=$OUT)"
  MC_URL="http://127.0.0.1:$(cat "$PORT_FILE")/" MC_TOKEN=t0k gv report --repo "$FX" --agent carmack
  [[ "$(jget delivered)" == "true" && "$RC" -eq 1 && "$(jget status)" == "claim-only" ]] && ok "report: delivered claim-only still exits 1" || bad "delivered claim-only (rc=$RC out=$OUT)"
else
  bad "stub Mission Control did not start"
fi

echo "# doctor"
STUB="$ROOT/stub-path"
mkdir -p "$STUB"
for tool in node git bash; do ln -s "$(command -v "$tool")" "$STUB/$tool"; done
OUT=$(PATH="$STUB" MC_TOKEN=sekrit-value-123 node "$GV" doctor --repo "$FX" 2>"$ROOT/err"); RC=$?
[[ "$RC" -eq 1 && "$(jget ok)" == "false" ]] && printf '%s' "$OUT" | grep '"tool:gh"' >/dev/null && ok "doctor: missing required tools (gh, jq) fail" || bad "doctor missing tools (rc=$RC)"
printf '%s' "$OUT" | grep 'sekrit-value-123' >/dev/null && bad "doctor printed an env value" || ok "doctor: env values are never printed"

echo "gibson-verify.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
