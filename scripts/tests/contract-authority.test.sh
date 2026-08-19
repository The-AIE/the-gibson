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

# Minimal dispatch-prompt stubs so closed-list measurement + set equality pass.
for role in planner decomposer builder test-engineer reviewer ux-evaluator security release historian; do
  write_dispatch_stub "$SANDBOX/playbooks/${role}.md" "$role"
done
for job in adopt delivery-control deploy-audit dogfood-overnight loop-step token-efficiency; do
  write_dispatch_stub "$SANDBOX/playbooks/${job}.md" "$job"
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
# restore honest builder playbook
{
  printf '%s\n' '---'
  printf '%s\n' 'role: builder'
  printf '%s\n' 'gates:'
  printf '%s\n' '  - example'
  printf '%s\n' 'forbidden:'
  printf '%s\n' '  - example'
  printf '%s\n' '---'
  printf '%s\n' '# builder'
  printf '%s\n' '> **Authority:** Conditionally mandatory dispatch prompt when this role/job is active. Binding commit/PR/merge rules live only in [`AGENTS.md`](../AGENTS.md). Frontmatter `gates:` / `forbidden:` / role outputs are routing mirrors of that contract and must not introduce obligations absent from AGENTS.md.'
} > "$SANDBOX/playbooks/builder.md"

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
write_dispatch_stub "$SANDBOX/playbooks/token-efficiency.md" token-efficiency

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

echo
echo "contract-authority.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
