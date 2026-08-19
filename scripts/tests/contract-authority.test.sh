#!/usr/bin/env bash
# contract-authority.test.sh — #208 authority boundary + read-chain budget
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
TOOL="$SCRIPT_DIR/../contract-authority.mjs"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

command -v node >/dev/null || { echo "contract-authority.test.sh: node required"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-contract-authority.XXXXXX") || {
  echo "contract-authority.test.sh: mktemp -d failed" >&2
  exit 1
}
trap 'rm -rf -- "${ROOT:?}"' EXIT

echo "# help / unknown flag"
out=$(node "$TOOL" --help 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'authority boundary' && ok "help" || bad "help (rc=$rc)"
out=$(node "$TOOL" --definitely-not-a-flag 2>&1); rc=$?
[[ "$rc" -eq 2 ]] && echo "$out" | grep -q 'unknown flag' && ok "unknown flag exit 2" \
  || bad "unknown flag (rc=$rc): $out"

echo "# live tree"
out=$(node "$TOOL" --repo-root "$REPO_ROOT" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'OK'; then
  ok "live tree check passes"
else
  bad "live tree check (rc=$rc): $out"
fi

echo "$out" | grep -q 'mandatory chain' && ok "live tree prints chain bytes" \
  || bad "live tree missing chain bytes"

echo "$out" | grep -q 'utf8-bytes-div-4' && ok "live tree names token proxy" \
  || bad "live tree missing token proxy"

echo "$out" | grep -q 'pre-change implied chain' && ok "live tree reports pre-change bytes" \
  || bad "live tree missing pre-change: $out"

json=$(node "$TOOL" --repo-root "$REPO_ROOT" --format json 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$json" | grep -q '"ok": true'; then
  ok "live json report ok"
else
  bad "live json (rc=$rc)"
fi

# Current chain must be AGENTS.md only and under budget.
agents_bytes=$(node -e 'const fs=require("fs"); process.stdout.write(String(Buffer.byteLength(fs.readFileSync(process.argv[1]))))' "$REPO_ROOT/AGENTS.md")
if [[ "$agents_bytes" -le 20480 ]]; then
  ok "AGENTS.md $agents_bytes bytes <= 20480 budget"
else
  bad "AGENTS.md $agents_bytes bytes exceeds 20480 budget"
fi

echo "# measure-only"
out=$(node "$TOOL" --repo-root "$REPO_ROOT" --measure 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'mandatory chain' && ok "measure-only exit 0" \
  || bad "measure-only (rc=$rc): $out"

echo "# sandbox mutations"
SANDBOX="$ROOT/sandbox"
mkdir -p "$SANDBOX/config/policy/candidates" "$SANDBOX/docs" "$SANDBOX/playbooks" "$SANDBOX/scripts"
cp "$REPO_ROOT/AGENTS.md" "$SANDBOX/AGENTS.md"
cp "$REPO_ROOT/config/policy/mandatory-read-chain.v1.json" "$SANDBOX/config/policy/mandatory-read-chain.v1.json"
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"
# Bannered stubs so globs pass.
{
  printf '%s\n' '# stub'
  printf '%s\n' '> **Authority:** Non-normative. Binding rules live in AGENTS.md.'
} > "$SANDBOX/docs/14-human-gates.md"
{
  printf '%s\n' '# stub playbook'
  printf '%s\n' '> **Authority:** Non-normative. Binding rules live in AGENTS.md.'
} > "$SANDBOX/playbooks/delivery-control.md"

out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "clean sandbox passes" || bad "clean sandbox (rc=$rc): $out"

# Strip G7
cp "$SANDBOX/AGENTS.md" "$SANDBOX/AGENTS.md.bak"
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(/\*\*G7\*\*[^\n]*/g, "**GX** — removed");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GATE'; then
  echo "  planted G7-removal failure line:"
  echo "$out" | grep 'E_GATE' | sed 's/^/    /'
  ok "mutation: removing G7 fails"
else
  bad "mutation G7 (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Drift G1 summary
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("Schema-destructive change, non-additive migration, or manual write against a production database.", "something else entirely");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GATE_DRIFT'; then
  echo "  planted G1-summary-drift failure line:"
  echo "$out" | grep 'E_GATE_DRIFT' | sed 's/^/    /'
  ok "mutation: G1 summary drift fails"
else
  bad "mutation G1 drift (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Remove authority statement
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(/sole mandatory human-readable/g, "one of several");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY'; then
  echo "  planted authority-removal failure line:"
  echo "$out" | grep 'E_AUTHORITY' | sed 's/^/    /'
  ok "mutation: removing authority phrase fails"
else
  bad "mutation authority (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Restore old implied-binding pointer
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("## On-demand (non-normative)", "Complete list with rationale in `docs/14-human-gates.md`\n\n## On-demand (non-normative)");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_IMPLIED_BINDING'; then
  echo "  planted implied-binding failure line:"
  echo "$out" | grep 'E_IMPLIED_BINDING' | sed 's/^/    /'
  ok "mutation: implied-binding docs/14 pointer fails"
else
  bad "mutation implied-binding (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Oversized AGENTS.md
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t+"x".repeat(30000);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BUDGET'; then
  echo "  planted oversized-AGENTS.md failure line:"
  echo "$out" | grep 'E_BUDGET' | sed 's/^/    /'
  ok "mutation: oversized AGENTS.md fails budget"
else
  bad "mutation budget (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Widen mandatory set in JSON
node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
c.mandatoryFiles=["AGENTS.md","docs/05-concurrency.md"];
c.allowedMandatoryFiles=["AGENTS.md","docs/05-concurrency.md"];
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/mandatory-read-chain.v1.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_MANDATORY_SET'; then
  echo "  planted widened-mandatory-set failure line:"
  echo "$out" | grep 'E_MANDATORY_SET' | sed 's/^/    /'
  ok "mutation: widening mandatory set fails"
else
  bad "mutation mandatory set (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/mandatory-read-chain.v1.json" \
  "$SANDBOX/config/policy/mandatory-read-chain.v1.json"

# Missing banner
printf '%s\n' '# unmarked doctrine' > "$SANDBOX/docs/05-concurrency.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BANNER'; then
  echo "  planted missing-banner failure line:"
  echo "$out" | grep 'E_BANNER' | sed 's/^/    /'
  ok "mutation: missing non-normative banner fails"
else
  bad "mutation banner (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/05-concurrency.md"

echo
echo "contract-authority.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
