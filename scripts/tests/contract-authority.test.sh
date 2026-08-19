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

echo "$out" | grep -q 'fixed mandatory chain' && ok "live tree prints fixed chain bytes" \
  || bad "live tree missing fixed chain bytes"

echo "$out" | grep -q 'conditional dispatch prompts' && ok "live tree prints conditional dispatch-prompt load" \
  || bad "live tree missing conditional dispatch-prompt load: $out"

echo "$out" | grep -q 'worst-case fixed + largest conditional dispatch prompt' && ok "live tree prints worst-case range" \
  || bad "live tree missing worst-case: $out"

echo "$out" | grep -q 'playbooks/token-efficiency.md' && ok "live tree lists per-file dispatch-prompt bytes" \
  || bad "live tree missing per-file listing: $out"

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
echo "$json" | grep -q '"conditionalDispatchPrompts"' && ok "live json includes conditionalDispatchPrompts" \
  || bad "live json missing conditionalDispatchPrompts"
echo "$json" | grep -q '"conditionalRolePlaybooks"' && bad "live json still uses retired conditionalRolePlaybooks key" \
  || ok "live json does not use retired conditionalRolePlaybooks key"

marked_count=$(node -e '
const fs = require("fs");
const path = require("path");
const root = process.argv[1];
const marker = "**Authority:** Conditionally mandatory dispatch prompt";
function walk(dir, acc) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p, acc);
    else if (ent.isFile() && ent.name.endsWith(".md") && fs.readFileSync(p, "utf8").includes(marker)) acc.push(p);
  }
}
const acc = [];
walk(root, acc);
process.stdout.write(String(acc.length));
' "$REPO_ROOT/playbooks")
json_check=$(printf '%s' "$json" | MARKED_COUNT="$marked_count" node -e '
let s = "";
process.stdin.on("data", (d) => { s += d; });
process.stdin.on("end", () => {
  const j = JSON.parse(s);
  const d = j.conditionalDispatchPrompts;
  if (!d || !Array.isArray(d.files)) {
    console.error("missing conditionalDispatchPrompts.files");
    process.exit(1);
  }
  const marked = Number(process.env.MARKED_COUNT);
  if (d.count !== marked || d.files.length !== marked) {
    console.error("count " + d.count + " files " + d.files.length + " marked " + marked);
    process.exit(1);
  }
  const need = [
    "playbooks/adopt.md",
    "playbooks/delivery-control.md",
    "playbooks/deploy-audit.md",
    "playbooks/dogfood-overnight.md",
    "playbooks/loop-step.md",
    "playbooks/token-efficiency.md",
    "playbooks/builder.md",
  ];
  const paths = d.files.map((f) => f.path);
  for (const p of need) {
    if (!paths.includes(p)) {
      console.error("missing " + p);
      process.exit(1);
    }
  }
  if (d.files.some((f) => f.role === "delivery-control" || (f.kind === "role" && String(f.path).includes("token-efficiency")))) {
    console.error("job prompt labeled as role");
    process.exit(1);
  }
  const adopt = d.files.find((f) => f.path === "playbooks/adopt.md");
  const builder = d.files.find((f) => f.path === "playbooks/builder.md");
  if (!adopt || adopt.kind !== "job" || !builder || builder.kind !== "role") {
    console.error("kind mapping wrong");
    process.exit(1);
  }
  const maxB = Math.max(...d.files.map((f) => f.bytes));
  if (d.bytesMax !== maxB) {
    console.error("bytesMax " + d.bytesMax + " != " + maxB);
    process.exit(1);
  }
  const minB = Math.min(...d.files.map((f) => f.bytes));
  if (d.bytesMin !== minB) {
    console.error("bytesMin " + d.bytesMin + " != " + minB);
    process.exit(1);
  }
  const sum = d.files.reduce((n, f) => n + f.bytes, 0);
  if (d.bytesSum !== sum) {
    console.error("bytesSum " + d.bytesSum + " != " + sum);
    process.exit(1);
  }
  const worst = j.mandatoryChainBytes + maxB;
  if (d.worstCaseFixedPlusLargestDispatchPrompt !== worst) {
    console.error("worst-case " + d.worstCaseFixedPlusLargestDispatchPrompt + " != " + worst);
    process.exit(1);
  }
  process.exit(0);
});
' 2>&1); rc_json_check=$?
if [[ "$rc_json_check" -eq 0 ]]; then
  ok "live json dispatch-prompt set equals discovered marked playbooks ($marked_count files) with honest min/max/sum/worst-case"
else
  bad "live json dispatch-prompt set/measurement: $json_check"
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
[[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'fixed mandatory chain' && ok "measure-only exit 0" \
  || bad "measure-only (rc=$rc): $out"

echo "# sandbox mutations"
SANDBOX="$ROOT/sandbox"
mkdir -p "$SANDBOX/config/policy/candidates" "$SANDBOX/docs" "$SANDBOX/playbooks" "$SANDBOX/scripts"
cp "$REPO_ROOT/AGENTS.md" "$SANDBOX/AGENTS.md"
cp "$REPO_ROOT/config/policy/mandatory-read-chain.v1.json" "$SANDBOX/config/policy/mandatory-read-chain.v1.json"
cp "$REPO_ROOT/config/policy/rule-migration-audit.v1.json" "$SANDBOX/config/policy/rule-migration-audit.v1.json"
cp "$REPO_ROOT/config/policy/role-contracts.v1.json" "$SANDBOX/config/policy/role-contracts.v1.json"
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"
cp "$REPO_ROOT/README.md" "$SANDBOX/README.md"

write_dispatch_stub() {
  local dest="$1"
  local id="$2"
  {
    printf '%s\n' '---'
    printf '%s\n' "role: $id"
    printf '%s\n' 'gates:'
    printf '%s\n' '  - example'
    printf '%s\n' 'forbidden:'
    printf '%s\n' '  - example'
    printf '%s\n' '---'
    printf '%s\n' "# $id"
    printf '%s\n' '> **Authority:** Conditionally mandatory dispatch prompt when this role/job is active. Binding commit/PR/merge rules live only in [`AGENTS.md`](../AGENTS.md). Frontmatter `gates:` / `forbidden:` / role outputs are routing mirrors of that contract and must not introduce obligations absent from AGENTS.md.'
  } > "$dest"
}

# Real role and job playbooks so semantic parity against role-contracts.v1.json holds.
for role in planner decomposer builder test-engineer reviewer ux-evaluator security release historian; do
  cp "$REPO_ROOT/playbooks/${role}.md" "$SANDBOX/playbooks/${role}.md"
done
for job in adopt delivery-control deploy-audit dogfood-overnight loop-step token-efficiency; do
  cp "$REPO_ROOT/playbooks/${job}.md" "$SANDBOX/playbooks/${job}.md"
done

{
  printf '%s\n' '# stub'
  printf '%s\n' '> **Authority:** Non-normative. Binding rules live in AGENTS.md.'
} > "$SANDBOX/docs/14-human-gates.md"

out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
[[ "$rc" -eq 0 ]] && ok "clean sandbox passes" || bad "clean sandbox (rc=$rc): $out"

cp "$SANDBOX/AGENTS.md" "$SANDBOX/AGENTS.md.bak"

# Strip G7
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

# Drift G1 summary vs AGENTS-owned text (mirror detects candidate drift)
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("Schema-destructive change, non-additive migration, or manual write against a production database.", "something else entirely");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_MIRROR_DRIFT'; then
  echo "  planted G1-summary-drift failure line:"
  echo "$out" | grep 'E_MIRROR_DRIFT' | sed 's/^/    /'
  ok "mutation: G1 summary drift vs candidate mirror fails"
else
  bad "mutation G1 drift (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Remove authority statement
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(/sole always-mandatory human-readable/g, "one of several");
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

# Candidate pre-activation via AGENTS prose
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "The report-only policy-manifest candidate",
  "Enumerations of gates, roles, tiers, stages, and forbidden pairs are canonical in `config/policy/candidates/gibson-core-v1.candidate.json`. The report-only policy-manifest candidate"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -Eq 'E_CANDIDATE_PREACTIVATION|E_IMPLIED_BINDING'; then
  echo "  planted candidate-preactivation prose failure line:"
  echo "$out" | grep -E 'E_CANDIDATE_PREACTIVATION|E_IMPLIED_BINDING' | sed 's/^/    /'
  ok "mutation: candidate pre-activation prose fails"
else
  bad "mutation candidate prose (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Candidate activated=true
node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
c.activated=true;
c.authority="active";
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_CANDIDATE_PREACTIVATION'; then
  echo "  planted candidate-activated failure line:"
  echo "$out" | grep 'E_CANDIDATE_PREACTIVATION' | sed 's/^/    /'
  ok "mutation: activated candidate fails"
else
  bad "mutation activated candidate (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"

# Omit role-playbook disclosure
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(/Conditional session-start human-readable load[\s\S]*?measured separately[^\n]*\n\n/m, "");
t=t.replace(/playbooks\/<role>\.md/g, "ROLE_PLAYBOOK_PATH");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_ROLE_DISCLOSURE'; then
  echo "  planted omitted-role-disclosure failure line:"
  echo "$out" | grep 'E_ROLE_DISCLOSURE' | sed 's/^/    /'
  ok "mutation: omitted role-playbook disclosure fails"
else
  bad "mutation role disclosure (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Drop a binding-rule family (six lenses)
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(/## Review lenses \(binding\)[\s\S]*?(?=## Security layers)/, "");
t=t.replace(/six lenses/g, "review aspects");
t=t.replace(/file:line/g, "file references");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_FAMILY'; then
  echo "  planted dropped-binding-family failure line:"
  echo "$out" | grep 'E_BINDING_FAMILY' | sed 's/^/    /'
  ok "mutation: dropped six-lens binding family fails"
else
  bad "mutation binding family (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Drop delivery-control family
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(/## Delivery control \(binding\)[\s\S]*?(?=## The pipeline)/, "");
t=t.replace(/explicit human apply/g, "human confirmation");
t=t.replace(/dry-run/g, "preview-run");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_FAMILY'; then
  echo "  planted dropped-delivery-control failure line:"
  echo "$out" | grep 'E_BINDING_FAMILY' | sed 's/^/    /'
  ok "mutation: dropped delivery-control family fails"
else
  bad "mutation delivery-control family (rc=$rc): $out"
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

# Missing docs banner
printf '%s\n' '# unmarked doctrine' > "$SANDBOX/docs/05-concurrency.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BANNER'; then
  echo "  planted missing-banner failure line:"
  echo "$out" | grep 'E_BANNER' | sed 's/^/    /'
  ok "mutation: missing non-normative docs banner fails"
else
  bad "mutation banner (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/05-concurrency.md"

# Contradictory playbook: operative frontmatter + non-normative banner
{
  printf '%s\n' '---'
  printf '%s\n' 'role: builder'
  printf '%s\n' 'gates:'
  printf '%s\n' '  - claim before touch'
  printf '%s\n' 'forbidden:'
  printf '%s\n' '  - merging'
  printf '%s\n' '---'
  printf '%s\n' '# builder'
  printf '%s\n' '> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.'
} > "$SANDBOX/playbooks/builder.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION'; then
  echo "  planted frontmatter/banner contradiction failure line:"
  echo "$out" | grep 'E_AUTHORITY_CONTRADICTION' | sed 's/^/    /'
  ok "mutation: gates/forbidden + non-normative banner fails"
else
  bad "mutation authority contradiction (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/builder.md" "$SANDBOX/playbooks/builder.md"

# Newly marked dispatch prompt omitted from the closed list
write_dispatch_stub "$SANDBOX/playbooks/extra-job.md" extra-job
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_DISPATCH_SET' && echo "$out" | grep -q 'playbooks/extra-job.md'; then
  echo "  planted extra-dispatch-prompt failure line:"
  echo "$out" | grep 'E_DISPATCH_SET' | sed 's/^/    /'
  ok "mutation: newly marked dispatch prompt omitted from closed list fails"
else
  bad "mutation extra dispatch prompt (rc=$rc): $out"
fi
rm -f "$SANDBOX/playbooks/extra-job.md"

# Marked job omitted from the closed list (production false-green shape)
node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
c.conditionalDispatchPrompts.jobPrompts = c.conditionalDispatchPrompts.jobPrompts.filter(
  (x) => x !== "playbooks/token-efficiency.md"
);
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/mandatory-read-chain.v1.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_DISPATCH_SET' && echo "$out" | grep -q 'playbooks/token-efficiency.md'; then
  echo "  planted omitted-closed-list failure line:"
  echo "$out" | grep 'E_DISPATCH_SET' | sed 's/^/    /'
  ok "mutation: marked dispatch prompt omitted from jobPrompts fails"
else
  bad "mutation omitted jobPrompts entry (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/mandatory-read-chain.v1.json" \
  "$SANDBOX/config/policy/mandatory-read-chain.v1.json"

# Closed-list entry whose file is not marked dispatch
{
  printf '%s\n' '# token-efficiency'
  printf '%s\n' '> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.'
} > "$SANDBOX/playbooks/token-efficiency.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_DISPATCH_SET' && echo "$out" | grep -q 'playbooks/token-efficiency.md'; then
  echo "  planted unmarked-manifest-dispatch-prompt failure line:"
  echo "$out" | grep 'E_DISPATCH_SET' | sed 's/^/    /'
  ok "mutation: closed-list dispatch prompt without dispatch marker fails"
else
  bad "mutation unmarked dispatch prompt (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/token-efficiency.md" "$SANDBOX/playbooks/token-efficiency.md"

# Misleading README claim
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
if (!t.includes("| **Doctrine** |")) throw new Error("no doctrine row");
t=t.replace(
  /\| \*\*Doctrine\*\* \|[^\n]*/,
  "| **Doctrine** | Rules, roles, gates, playbooks every agent follows | `AGENTS.md`, `docs/`, `playbooks/` |"
);
fs.writeFileSync(p,t);
' "$SANDBOX/README.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_REPO_CLAIM'; then
  echo "  planted README authority-claim failure line:"
  echo "$out" | grep 'E_REPO_CLAIM' | sed 's/^/    /'
  ok "mutation: README docs/playbooks authority claim fails"
else
  bad "mutation README claim (rc=$rc): $out"
fi
cp "$REPO_ROOT/README.md" "$SANDBOX/README.md"

# --- semantic weakening / negation (retain keywords, invert obligation) ---
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
if (!t.includes("  - merging\n")) throw new Error("missing merging forbidden item");
t=t.replace("  - merging\n", "  - never skip merging\n");
fs.writeFileSync(p,t);
' "$SANDBOX/playbooks/builder.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_ROLE_NEGATION'; then
  echo "  planted role-negation failure line:"
  echo "$out" | grep 'E_ROLE_NEGATION' | sed 's/^/    /'
  ok "mutation: retaining keywords while negating a role prohibition fails"
else
  bad "mutation role negation (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/builder.md" "$SANDBOX/playbooks/builder.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("  - merging\n", "  - merging is optional\n");
fs.writeFileSync(p,t);
' "$SANDBOX/playbooks/builder.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_ROLE_WEAKENING'; then
  echo "  planted role-weakening failure line:"
  echo "$out" | grep 'E_ROLE_WEAKENING' | sed 's/^/    /'
  ok "mutation: retaining keywords while weakening a role prohibition fails"
else
  bad "mutation role weakening (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/builder.md" "$SANDBOX/playbooks/builder.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("  - merging\n", "");
t=t.replace("gates:\n", "gates:\n  - merging\n");
fs.writeFileSync(p,t);
' "$SANDBOX/playbooks/builder.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_ROLE_CROSS_BUCKET'; then
  echo "  planted role-moved failure line:"
  echo "$out" | grep 'E_ROLE_CROSS_BUCKET' | sed 's/^/    /'
  ok "mutation: moving a prohibition into gates while keeping the keyword fails"
else
  bad "mutation role move (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/builder.md" "$SANDBOX/playbooks/builder.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("  - merging\n", "  - merging\n  - merging\n");
t=t.replace("  - reviewing own work\n", "");
fs.writeFileSync(p,t);
' "$SANDBOX/playbooks/builder.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -Eq 'E_ROLE_DUPLICATE|E_ROLE_OMISSION'; then
  echo "  planted role-duplicate failure line:"
  echo "$out" | grep -E 'E_ROLE_' | sed 's/^/    /'
  ok "mutation: duplicating one prohibition while dropping another fails"
else
  bad "mutation role duplicate (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/builder.md" "$SANDBOX/playbooks/builder.md"

# --- live docs/README/candidate contradiction fixtures ---
cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-14-closed-list.md" \
  "$SANDBOX/docs/14-human-gates.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'closed-list'; then
  echo "  planted live-docs-14 contradiction failure line:"
  echo "$out" | grep 'E_AUTHORITY_CONTRADICTION' | sed 's/^/    /'
  ok "fixture: live docs/14 non-normative banner + closed operative list fails"
else
  bad "fixture docs/14 contradiction (rc=$rc): $out"
fi
{
  printf '%s\n' '# stub'
  printf '%s\n' '> **Authority:** Non-normative. Binding rules live in AGENTS.md.'
} > "$SANDBOX/docs/14-human-gates.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/readme-docs-as-authority.md" \
  "$SANDBOX/README.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_REPO_CLAIM'; then
  echo "  planted live-README contradiction failure line:"
  echo "$out" | grep 'E_REPO_CLAIM' | sed 's/^/    /'
  ok "fixture: live README docs/03 contracts + docs/14 stop-authority rows fail"
else
  bad "fixture README contradiction (rc=$rc): $out"
fi
cp "$REPO_ROOT/README.md" "$SANDBOX/README.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
for (const s of c.provenance.sources) {
  if (String(s.path).startsWith("docs/")) s.role = "canonical-doctrine";
}
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PROVENANCE_ROLE'; then
  echo "  planted candidate-canonical-doctrine failure line:"
  echo "$out" | grep 'E_PROVENANCE_ROLE' | sed 's/^/    /'
  ok "fixture: live candidate canonical-doctrine provenance on docs/ fails"
else
  bad "fixture candidate canonical-doctrine (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"

# --- default builder cannot skip playbooks/builder.md ---
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  /If no role is named, the resolved role is `builder`[\s\S]*?including default assignment\./,
  "If no role is named, the resolved role is `builder`. Default builder may skip playbooks/builder.md."
);
t=t.replace(
  /If no role is named, the resolved role is `builder` and `playbooks\/builder\.md` is that load \(including default\nassignment\)\./,
  "If no role is named, the resolved role is `builder`. Default builder may skip playbooks/builder.md."
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_DEFAULT_BUILDER'; then
  echo "  planted default-builder-skip failure line:"
  echo "$out" | grep 'E_DEFAULT_BUILDER' | sed 's/^/    /'
  ok "mutation: default builder skipping playbooks/builder.md fails"
else
  bad "mutation default-builder skip (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

rm -f "$SANDBOX/playbooks/builder.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -Eq 'E_DEFAULT_BUILDER|E_DISPATCH_PROMPT_MISSING' && echo "$out" | grep -q 'playbooks/builder.md'; then
  echo "  planted missing-default-builder-playbook failure line:"
  echo "$out" | grep -E 'E_DEFAULT_BUILDER|E_DISPATCH_PROMPT_MISSING' | sed 's/^/    /'
  ok "mutation: unnamed/default builder with playbooks/builder.md missing fails"
else
  bad "mutation missing default builder playbook (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/builder.md" "$SANDBOX/playbooks/builder.md"

SEM="$REPO_ROOT/scripts/lib/contract-semantics.mjs"

prove_legacy_green_structured_red() {
  local name="$1"
  local expected_code="$2"
  local family="$3"
  local report
  report=$(
    SEM="$SEM" AGENTS="$SANDBOX/AGENTS.md" CAND="$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json" \
    FAMILY="$family" EXPECTED_CODE="$expected_code" \
    node --input-type=module -e '
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { legacyPresenceOnly, structuredAgentsEnumerationFindings } = await import(pathToFileURL(process.env.SEM).href);
const text = readFileSync(process.env.AGENTS, "utf8");
const cand = JSON.parse(readFileSync(process.env.CAND, "utf8"));
const legacy = legacyPresenceOnly(text);
const structured = structuredAgentsEnumerationFindings(text, cand);
const family = process.env.FAMILY;
const code = process.env.EXPECTED_CODE;
let legacyGreen = false;
if (family === "gates") legacyGreen = legacy.missingGates.length === 0;
else if (family === "layers") legacyGreen = legacy.missingLayers.length === 0;
else if (family === "delivery") legacyGreen = legacy.hasDeliveryTokens === true;
else if (family === "selfmod") legacyGreen = legacy.hasSelfModTokens === true;
else if (family === "stages") legacyGreen = legacy.missingStages.length === 0;
else if (family === "tiers") legacyGreen = legacy.missingTiers.length === 0;
else if (family === "pairs") legacyGreen = legacy.missingPairs.length === 0;
const red = structured.some((f) => f.code === code);
console.log(JSON.stringify({ legacyGreen, red, codes: structured.map((f) => f.code) }));
process.exit(legacyGreen && red ? 0 : 1);
'
  )
  local prc=$?
  if [[ "$prc" -eq 0 ]]; then
    echo "  legacy-green/structured-red: $report"
    ok "legacy green / structured red ($name → $expected_code)"
  else
    bad "legacy green / structured red ($name → $expected_code): $report"
  fi
}

echo "# closed-list / Tier-C semantic mutations"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
if (!t.includes("- **G16**")) throw new Error("missing G16");
t=t.replace("- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n",
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n- **G17** — Extra unpublished stop.\n");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GATE_UNEXPECTED'; then
  echo "  planted G17-addition failure line:"
  echo "$out" | grep 'E_GATE_UNEXPECTED' | sed 's/^/    /'
  ok "mutation: adding G17 fails with E_GATE_UNEXPECTED"
else
  bad "mutation G17 (rc=$rc): $out"
fi
prove_legacy_green_structured_red "G17 addition" "E_GATE_UNEXPECTED" "gates"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("- **G1** — Schema-destructive change, non-additive migration, or manual write against a production database.\n",
  "- **G1** — Schema-destructive change, non-additive migration, or manual write against a production database.\n- **G1** — Schema-destructive change, non-additive migration, or manual write against a production database.\n");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GATE_DUPLICATE'; then
  echo "  planted duplicate-G1 failure line:"
  echo "$out" | grep 'E_GATE_DUPLICATE' | sed 's/^/    /'
  ok "mutation: duplicate G1 fails with E_GATE_DUPLICATE"
else
  bad "mutation duplicate G1 (rc=$rc): $out"
fi
prove_legacy_green_structured_red "duplicate G1" "E_GATE_DUPLICATE" "gates"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "- **G1** — Schema-destructive change, non-additive migration, or manual write against a production database.",
  "- **G1** — Not a schema-destructive change, non-additive migration, or manual write against a production database."
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GATE_NEGATION'; then
  echo "  planted G1-negation failure line:"
  echo "$out" | grep 'E_GATE_NEGATION' | sed 's/^/    /'
  ok "mutation: G1 summary negation fails with E_GATE_NEGATION"
else
  bad "mutation G1 negation (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("`historian`", "`archivist`");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_ROLE_ENUM_RENAME'; then
  echo "  planted role-rename failure line:"
  echo "$out" | grep 'E_ROLE_ENUM_RENAME' | sed 's/^/    /'
  ok "mutation: standalone role rename fails with E_ROLE_ENUM_RENAME"
else
  bad "mutation role rename (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "Ten stages (`PLAN`, `DECOMPOSE`, `BUILD`, `TEST`, `REVIEW`, `UX-EVAL`,\n`SECURITY`, `MERGE`, `DEPLOY+VERIFY`, `RETRO`).",
  "Ten stages (`PLAN`, `DECOMPOSE`, `BUILD`, `TEST`, `REVIEW`, `UX-EVAL`,\n`SECURITY`, `MERGE`, `DEPLOY+VERIFY`, `RETRO`, `ELEVEN`)."
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_STAGE_ADDITION'; then
  echo "  planted stage-addition failure line:"
  echo "$out" | grep 'E_STAGE_ADDITION' | sed 's/^/    /'
  ok "mutation: stage addition fails with E_STAGE_ADDITION"
else
  bad "mutation stage addition (rc=$rc): $out"
fi
prove_legacy_green_structured_red "stage addition" "E_STAGE_ADDITION" "stages"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "Ten stages (`PLAN`, `DECOMPOSE`, `BUILD`, `TEST`, `REVIEW`, `UX-EVAL`,\n`SECURITY`, `MERGE`, `DEPLOY+VERIFY`, `RETRO`).",
  "Ten stages (`PLAN`, `DECOMPOSE`, `BUILD`, `TEST`, `REVIEW`, `UX-EVAL`,\n`SECURITY`, `MERGE`, `DEPLOY+VERIFY`)."
);
t=t.replace("→ retro", "→ RETRO");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_STAGE_OMISSION'; then
  echo "  planted stage-omission failure line:"
  echo "$out" | grep 'E_STAGE_OMISSION' | sed 's/^/    /'
  ok "mutation: stage omission fails with E_STAGE_OMISSION"
else
  bad "mutation stage omission (rc=$rc): $out"
fi
prove_legacy_green_structured_red "stage omission" "E_STAGE_OMISSION" "stages"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("`builder` ≠\n`reviewer`; `builder` ≠ `ux-evaluator`; `reviewer` ≠ `ux-evaluator`.",
  "`builder` ≠ `ux-evaluator`; `reviewer` ≠ `ux-evaluator`.");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PAIR_OMISSION'; then
  echo "  planted pair-removal failure line:"
  echo "$out" | grep 'E_PAIR_OMISSION' | sed 's/^/    /'
  ok "mutation: forbidden-pair removal fails with E_PAIR_OMISSION"
else
  bad "mutation pair removal (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("`reviewer` ≠ `ux-evaluator`.",
  "`reviewer` ≠ `ux-evaluator`; `planner` ≠ `historian`.");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PAIR_ADDITION'; then
  echo "  planted pair-addition failure line:"
  echo "$out" | grep 'E_PAIR_ADDITION' | sed 's/^/    /'
  ok "mutation: forbidden-pair addition fails with E_PAIR_ADDITION"
else
  bad "mutation pair addition (rc=$rc): $out"
fi
prove_legacy_green_structured_red "pair addition" "E_PAIR_ADDITION" "pairs"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("(symmetric)", "(asymmetric)");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PAIR_ASYMMETRY'; then
  echo "  planted pair-asymmetry failure line:"
  echo "$out" | grep 'E_PAIR_ASYMMETRY' | sed 's/^/    /'
  ok "mutation: forbidden-pair asymmetry fails with E_PAIR_ASYMMETRY"
else
  bad "mutation pair asymmetry (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Duplicate rule: duplicate a Ten-stages token inside the closed list.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("`PLAN`, `DECOMPOSE`", "`PLAN`, `PLAN`, `DECOMPOSE`");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_STAGE_DUPLICATE'; then
  echo "  planted duplicate-rule failure line:"
  echo "$out" | grep 'E_STAGE_DUPLICATE' | sed 's/^/    /'
  ok "mutation: duplicate stage rule fails with E_STAGE_DUPLICATE"
else
  bad "mutation duplicate rule (rc=$rc): $out"
fi
prove_legacy_green_structured_red "duplicate stage" "E_STAGE_DUPLICATE" "stages"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Binding-family negation/weakening (presence-only remains green).
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("hard-fail blocks merge/release", "never hard-fail blocks merge/release");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  echo "  planted eight-layer negation failure line:"
  echo "$out" | grep 'E_BINDING_NEGATION' | sed 's/^/    /'
  ok "mutation: eight-security-layers negation fails with E_BINDING_NEGATION"
else
  bad "mutation eight-layer negation (rc=$rc): $out"
fi
prove_legacy_green_structured_red "eight-layer negation" "E_BINDING_NEGATION" "layers"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "then optional **explicit human apply**");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  echo "  planted delivery-control weakening failure line:"
  echo "$out" | grep 'E_BINDING_WEAKENING' | sed 's/^/    /'
  ok "mutation: delivery-control weakening fails with E_BINDING_WEAKENING"
else
  bad "mutation delivery weakening (rc=$rc): $out"
fi
prove_legacy_green_structured_red "delivery weakening" "E_BINDING_WEAKENING" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("are\nthemselves Tier C", "are not\nthemselves Tier C");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  echo "  planted self-mod negation failure line:"
  echo "$out" | grep 'E_BINDING_NEGATION' | sed 's/^/    /'
  ok "mutation: self-modification negation fails with E_BINDING_NEGATION"
else
  bad "mutation self-mod negation (rc=$rc): $out"
fi
prove_legacy_green_structured_red "self-mod negation" "E_BINDING_NEGATION" "selfmod"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("(**adversarial cases required**)", "(not **adversarial cases required**)");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  echo "  planted adversarial-tests negation failure line:"
  echo "$out" | grep 'E_BINDING_NEGATION' | sed 's/^/    /'
  ok "mutation: tier-c-adversarial-tests negation fails with E_BINDING_NEGATION"
else
  bad "mutation adversarial negation (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("**destructive production testing**", "not **destructive production testing**");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  echo "  planted destructive-prod negation failure line:"
  echo "$out" | grep 'E_BINDING_NEGATION' | sed 's/^/    /'
  ok "mutation: no-destructive-prod-testing negation fails with E_BINDING_NEGATION"
else
  bad "mutation destructive-prod negation (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "findings never cite **file:line**");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  echo "  planted six-lens negation failure line:"
  echo "$out" | grep 'E_BINDING_NEGATION' | sed 's/^/    /'
  ok "mutation: six-lens-review negation fails with E_BINDING_NEGATION"
else
  bad "mutation six-lens negation (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

echo "# live contradiction fixtures (docs/01, DOC-BACKLOG, recipes, candidate)"
mkdir -p "$SANDBOX/docs" "$SANDBOX/playbooks/recipes"
cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-01-principle-wins.md" \
  "$SANDBOX/docs/01-principles.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'principle-wins-over-agents'; then
  echo "  planted docs-01 contradiction failure line:"
  echo "$out" | grep 'E_AUTHORITY_CONTRADICTION' | sed 's/^/    /'
  ok "fixture: live docs/01 principle-wins shape fails"
else
  bad "fixture docs/01 contradiction (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/01-principles.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-backlog-as-spec.md" \
  "$SANDBOX/docs/DOC-BACKLOG.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -Eq 'docs-01-19-are-the-spec|do-not-contradict-docs-01-19'; then
  echo "  planted DOC-BACKLOG contradiction failure line:"
  echo "$out" | grep 'E_AUTHORITY_CONTRADICTION' | sed 's/^/    /'
  ok "fixture: live DOC-BACKLOG docs-01-19-are-the-spec shape fails"
else
  bad "fixture DOC-BACKLOG contradiction (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/DOC-BACKLOG.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/recipes-playbooks-source-of-truth.md" \
  "$SANDBOX/playbooks/recipes/README.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'playbooks-source-of-truth'; then
  echo "  planted recipes README contradiction failure line:"
  echo "$out" | grep 'E_AUTHORITY_CONTRADICTION' | sed 's/^/    /'
  ok "fixture: live playbooks/recipes README source-of-truth shape fails"
else
  bad "fixture recipes README contradiction (rc=$rc): $out"
fi
rm -f "$SANDBOX/playbooks/recipes/README.md"

# Consume the previously unused candidate-canonical-doctrine fixture.
node -e '
const fs=require("fs");
const live=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const fix=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
live.provenance = fix.provenance;
fs.writeFileSync(process.argv[1], JSON.stringify(live,null,2)+"\n");
' "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$REPO_ROOT/config/policy/fixtures/authority-contradictions/candidate-canonical-doctrine.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PROVENANCE_ROLE'; then
  echo "  planted unused-candidate-fixture failure line:"
  echo "$out" | grep 'E_PROVENANCE_ROLE' | sed 's/^/    /'
  ok "fixture: candidate-canonical-doctrine.json provenance shape fails"
else
  bad "fixture unused candidate-canonical-doctrine (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"

echo "# provenance path-role mutations"
node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
c.provenance.sources = c.provenance.sources.filter((s) => s.path !== "AGENTS.md");
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PROVENANCE_ROLE' && echo "$out" | grep -q 'exactly one provenance source'; then
  ok "mutation: missing AGENTS.md provenance source fails"
else
  bad "mutation missing AGENTS provenance (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"

node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
const agents = c.provenance.sources.find((s) => s.path === "AGENTS.md");
c.provenance.sources.push({ ...agents, id: "src.agents-contract-dup" });
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PROVENANCE_ROLE' && echo "$out" | grep -q 'duplicate AGENTS.md'; then
  ok "mutation: duplicate AGENTS.md provenance source fails"
else
  bad "mutation duplicate AGENTS provenance (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"

node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
for (const s of c.provenance.sources) if (s.path === "AGENTS.md") s.role = "supporting";
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PROVENANCE_ROLE' && echo "$out" | grep -q 'human-readable-contract'; then
  ok "mutation: AGENTS.md relabeled supporting fails"
else
  bad "mutation AGENTS relabeled supporting (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"

node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
for (const s of c.provenance.sources) if (s.path === "docs/14-human-gates.md") s.role = "human-readable-contract";
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PROVENANCE_ROLE' && echo "$out" | grep -q 'docs/14-human-gates.md'; then
  ok "mutation: non-AGENTS relabeled human-readable-contract fails"
else
  bad "mutation non-AGENTS human-readable-contract (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"

node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
for (const s of c.provenance.sources) {
  if (s.path === "docs/18-fork-and-upstream.md") s.role = "compatibility-doctrine";
  if (s.path === "docs/03-roles.md") s.role = "supporting";
}
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PROVENANCE_ROLE' && echo "$out" | grep -q 'explanatory-history'; then
  ok "mutation: docs relabeled compatibility/supporting fails"
else
  bad "mutation docs relabeled (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"

node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
const agents = c.provenance.sources.find((s) => s.path === "AGENTS.md");
const docs = c.provenance.sources.find((s) => s.path === "docs/14-human-gates.md");
const tmp = agents.role; agents.role = docs.role; docs.role = tmp;
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PROVENANCE_ROLE'; then
  ok "mutation: provenance path-role swap fails"
else
  bad "mutation path-role swap (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/candidates/gibson-core-v1.candidate.json" \
  "$SANDBOX/config/policy/candidates/gibson-core-v1.candidate.json"

echo "# local override + job contracts"
mkdir -p "$SANDBOX/local/playbooks"
cp "$SANDBOX/playbooks/builder.md" "$SANDBOX/local/playbooks/builder.md"
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("  - merging\n", "  - merging is optional\n");
fs.writeFileSync(p,t);
' "$SANDBOX/local/playbooks/builder.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_ROLE_WEAKENING'; then
  echo "  planted local-override weakening failure line:"
  echo "$out" | grep 'E_ROLE_WEAKENING' | sed 's/^/    /'
  ok "mutation: weakened local builder override fails closed"
else
  bad "mutation local builder override (rc=$rc): $out"
fi

# Oversized local override accounting: report the override bytes, not the smaller core.
node -e '
const fs=require("fs");
const core=fs.readFileSync(process.argv[1],"utf8");
fs.writeFileSync(process.argv[2], core + "x".repeat(20000) + "\n");
' "$SANDBOX/playbooks/builder.md" "$SANDBOX/local/playbooks/builder.md"
json=$(node "$TOOL" --repo-root "$SANDBOX" --format json 2>&1); rc=$?
acct=$(printf '%s' "$json" | node -e '
let s=""; process.stdin.on("data", d => s+=d); process.stdin.on("end", () => {
  const j = JSON.parse(s);
  const files = (j.conditionalDispatchPrompts && j.conditionalDispatchPrompts.files) || [];
  const eff = files.find((f) => f.role === "builder");
  if (!eff) { console.error("no builder record"); process.exit(1); }
  if (eff.path !== "local/playbooks/builder.md") { console.error("effective path " + eff.path); process.exit(1); }
  if (eff.effective !== "local-override") { console.error("effective " + eff.effective); process.exit(1); }
  if (!(eff.bytes > 15000)) { console.error("bytes " + eff.bytes); process.exit(1); }
  if (j.conditionalDispatchPrompts.bytesMax !== eff.bytes && j.conditionalDispatchPrompts.bytesMax < eff.bytes) {
    console.error("bytesMax ignored override"); process.exit(1);
  }
  const core = files.find((f) => f.path === "playbooks/builder.md" && f.effective !== "local-override");
  if (core) { console.error("core playbook still reported as effective load"); process.exit(1); }
  process.exit(0);
});
'); acct_rc=$?
if [[ "$acct_rc" -eq 0 ]]; then
  ok "local override oversized accounting uses override bytes as effective load"
else
  bad "local override accounting: $acct"
fi
rm -rf "$SANDBOX/local"

# Symlink entry under playbooks/ must E_PATH (never follow or silently skip).
ln -s "$SANDBOX/playbooks/builder.md" "$SANDBOX/playbooks/planted-symlink.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PATH' && echo "$out" | grep -q 'playbooks/planted-symlink.md' && echo "$out" | grep -qi 'symlink'; then
  echo "  planted playbooks symlink failure line:"
  echo "$out" | grep 'E_PATH' | sed 's/^/    /'
  ok "mutation: playbooks symlink entry fails with E_PATH"
else
  bad "mutation playbooks symlink entry (rc=$rc): $out"
fi
rm -f "$SANDBOX/playbooks/planted-symlink.md"

# Existing local override that is a directory (non-regular) must E_PATH, not fall back.
mkdir -p "$SANDBOX/local/playbooks/builder.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PATH' && echo "$out" | grep -q 'local/playbooks/builder.md'; then
  echo "  planted local-override directory failure line:"
  echo "$out" | grep 'E_PATH' | sed 's/^/    /'
  ok "mutation: local override directory fails with E_PATH"
else
  bad "mutation local override directory (rc=$rc): $out"
fi
rm -rf "$SANDBOX/local"

# Genuinely absent local override still uses the core playbook and passes.
json=$(node "$TOOL" --repo-root "$SANDBOX" --format json 2>&1); rc=$?
absent=$(printf '%s' "$json" | node -e '
let s=""; process.stdin.on("data", d => s+=d); process.stdin.on("end", () => {
  const j = JSON.parse(s);
  if (j.ok !== true) { console.error("not ok findings=" + JSON.stringify(j.findings || [])); process.exit(1); }
  const files = (j.conditionalDispatchPrompts && j.conditionalDispatchPrompts.files) || [];
  const builder = files.find((f) => f.role === "builder");
  if (!builder) { console.error("no builder"); process.exit(1); }
  if (builder.path !== "playbooks/builder.md") { console.error("path " + builder.path); process.exit(1); }
  if (builder.effective !== "core") { console.error("effective " + builder.effective); process.exit(1); }
  process.exit(0);
});
'); absent_rc=$?
if [[ "$rc" -eq 0 && "$absent_rc" -eq 0 ]]; then
  ok "genuinely absent local override uses core playbook and passes"
else
  bad "absent local override (rc=$rc absent_rc=$absent_rc): $absent $json"
fi

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("  - transplanting CI without calibration\n", "");
fs.writeFileSync(p,t);
' "$SANDBOX/playbooks/adopt.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_JOB_OMISSION'; then
  echo "  planted job-omission failure line:"
  echo "$out" | grep 'E_JOB_OMISSION' | sed 's/^/    /'
  ok "mutation: job obligation omission fails with E_JOB_OMISSION"
else
  bad "mutation job omission (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/adopt.md" "$SANDBOX/playbooks/adopt.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("  - transplanting CI without calibration\n", "  - never skip transplanting CI without calibration\n");
fs.writeFileSync(p,t);
' "$SANDBOX/playbooks/adopt.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_JOB_NEGATION'; then
  ok "mutation: job obligation negation fails with E_JOB_NEGATION"
else
  bad "mutation job negation (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/adopt.md" "$SANDBOX/playbooks/adopt.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("  - transplanting CI without calibration\n", "  - transplanting CI without calibration is optional\n");
fs.writeFileSync(p,t);
' "$SANDBOX/playbooks/adopt.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_JOB_WEAKENING'; then
  ok "mutation: job obligation weakening fails with E_JOB_WEAKENING"
else
  bad "mutation job weakening (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/adopt.md" "$SANDBOX/playbooks/adopt.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("forbidden:\n", "forbidden:\n  - extra unpublished job obligation\n");
fs.writeFileSync(p,t);
' "$SANDBOX/playbooks/adopt.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_JOB_ADDITION'; then
  ok "mutation: job obligation addition fails with E_JOB_ADDITION"
else
  bad "mutation job addition (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/adopt.md" "$SANDBOX/playbooks/adopt.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("  - transplanting CI without calibration\n", "  - transplanting CI without calibration\n  - transplanting CI without calibration\n");
fs.writeFileSync(p,t);
' "$SANDBOX/playbooks/adopt.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_JOB_DUPLICATE'; then
  ok "mutation: job obligation duplicate fails with E_JOB_DUPLICATE"
else
  bad "mutation job duplicate (rc=$rc): $out"
fi
cp "$REPO_ROOT/playbooks/adopt.md" "$SANDBOX/playbooks/adopt.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
delete c.jobs.adopt;
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/role-contracts.v1.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_JOB_CONTRACTS' && echo "$out" | grep -q 'adopt'; then
  ok "mutation: missing job contract fails with E_JOB_CONTRACTS"
else
  bad "mutation missing job contract (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/role-contracts.v1.json" "$SANDBOX/config/policy/role-contracts.v1.json"

echo "# authority path containment"
OUTSIDE="$ROOT/outside-secret"
mkdir -p "$OUTSIDE"
printf 'LEAKED\n' > "$OUTSIDE/leaked.txt"
rm -f "$SANDBOX/AGENTS.md"
ln -s "$OUTSIDE/leaked.txt" "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -Eqi 'E_PATH|realpath escapes|symlink|escape'; then
  echo "  planted symlink-escape failure line:"
  echo "$out" | grep -E 'E_PATH|E_MISSING' | sed 's/^/    /'
  ok "authority sensor: AGENTS.md symlink escape fails closed"
else
  bad "authority sensor symlink escape (rc=$rc): $out"
fi
rm -f "$SANDBOX/AGENTS.md"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Authority sensor must reuse policy-manifest fd-bound reads (no weaker local primitive).
if grep -q 'from "./policy-manifest.mjs"' "$TOOL" && grep -q 'readContainedFile' "$TOOL" && \
   ! grep -q 'function resolveUnderRoot' "$TOOL"; then
  ok "authority sensor imports policy-manifest readContainedFile (no local resolveUnderRoot)"
else
  bad "authority sensor does not reuse policy-manifest safe-read"
fi

# Deterministic path-swap on the shared primitive the authority sensor uses for AGENTS.md.
SWAP_OUT=$(
  SANDBOX="$SANDBOX" OUTSIDE="$OUTSIDE" PM="$REPO_ROOT/scripts/policy-manifest.mjs" \
  node --input-type=module -e '
import { symlinkSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const {
  readContainedFile,
  coerceRootIdentity,
  setSafeReadAfterOpenHook,
} = await import(pathToFileURL(process.env.PM).href);
const sandbox = process.env.SANDBOX;
const outside = process.env.OUTSIDE;
const rootId = coerceRootIdentity(sandbox);
function swapHook({ relPath, absPath }) {
  if (relPath === "AGENTS.md" || /AGENTS\.md$/.test(absPath)) {
    try { unlinkSync(absPath); } catch { /* ignore */ }
    symlinkSync(join(outside, "leaked.txt"), absPath);
    return;
  }
  setSafeReadAfterOpenHook(swapHook);
}
setSafeReadAfterOpenHook(swapHook);
let threw = false;
let msg = "";
try {
  readContainedFile(rootId, "AGENTS.md", "utf8");
} catch (e) {
  threw = true;
  msg = e && e.message ? e.message : String(e);
}
setSafeReadAfterOpenHook(null);
if (threw && /realpath escapes|symlink|identity changed|swap or race|cannot read/i.test(msg) && !/LEAKED/.test(msg)) {
  console.log("SWAP_FAIL_CLOSED");
  process.exit(0);
}
console.log("SWAP_UNEXPECTED threw=" + threw + " msg=" + msg);
process.exit(1);
'
) || true
if echo "$SWAP_OUT" | grep -q "SWAP_FAIL_CLOSED"; then
  ok "authority sensor: deterministic AGENTS.md path-swap fails closed"
else
  bad "authority sensor path-swap: $SWAP_OUT"
fi
rm -f "$SANDBOX/AGENTS.md"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Legitimate in-root names still accepted by the shared safe-read primitive.
mkdir -p "$SANDBOX/docs/..hidden"
printf 'ok\n' > "$SANDBOX/docs/a..b.md"
printf 'ok\n' > "$SANDBOX/docs/..hidden/x.md"
{
  printf '%s\n' '# hidden'
  printf '%s\n' '> **Authority:** Non-normative. Binding rules live in AGENTS.md.'
} > "$SANDBOX/docs/a..b.md"
{
  printf '%s\n' '# hidden'
  printf '%s\n' '> **Authority:** Non-normative. Binding rules live in AGENTS.md.'
} > "$SANDBOX/docs/..hidden/x.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "authority sensor accepts in-root a..b and ..hidden names"
else
  bad "authority sensor rejected legitimate a..b / ..hidden (rc=$rc): $out"
fi

echo
echo "contract-authority.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
