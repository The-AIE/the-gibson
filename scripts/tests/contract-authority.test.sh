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
case "$agents_bytes" in
  ''|*[!0-9]*)
    bad "AGENTS.md byte count is not a non-empty integer: ${agents_bytes:-<empty>}"
    ;;
  *)
    if [[ "$agents_bytes" -le 20480 ]]; then
      ok "AGENTS.md $agents_bytes bytes <= 20480 budget"
    else
      bad "AGENTS.md $agents_bytes bytes exceeds 20480 budget"
    fi
    ;;
esac

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
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -Eq 'E_DISPATCH_SET|E_CONFIG' && echo "$out" | grep -q 'token-efficiency'; then
  echo "  planted omitted-closed-list failure line:"
  echo "$out" | grep -E 'E_DISPATCH_SET|E_CONFIG' | sed 's/^/    /'
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
if (!t.includes("may skip playbooks/builder.md")) {
  throw new Error("default-builder mutation did not apply");
}
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

echo "# blocker-family repairs (closed-list / polarity / discovery / config / contradiction / measure)"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Alternate G-number list forms that the legacy **G1**…**G16** detector misses.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n",
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n- G17 — Extra unpublished stop.\n"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GATE_UNEXPECTED'; then
  ok "mutation: unbolded - G17 — fails with E_GATE_UNEXPECTED"
else
  bad "mutation unbolded G17 (rc=$rc): $out"
fi
prove_legacy_green_structured_red "unbolded G17" "E_GATE_UNEXPECTED" "gates"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n",
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n- **G17:** Extra unpublished stop.\n"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GATE_UNEXPECTED'; then
  ok "mutation: colon form - **G17:** fails with E_GATE_UNEXPECTED"
else
  bad "mutation colon G17 (rc=$rc): $out"
fi
prove_legacy_green_structured_red "colon G17" "E_GATE_UNEXPECTED" "gates"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n",
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n17. **G17** — Extra unpublished stop.\n"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GATE_UNEXPECTED'; then
  ok "mutation: numbered 17. **G17** — fails with E_GATE_UNEXPECTED"
else
  bad "mutation numbered G17 (rc=$rc): $out"
fi
prove_legacy_green_structured_red "numbered G17" "E_GATE_UNEXPECTED" "gates"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n",
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n- G1 — Alternate duplicate of G1.\n"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GATE_DUPLICATE'; then
  ok "mutation: alternate-form G1 duplicate fails with E_GATE_DUPLICATE"
else
  bad "mutation alternate G1 duplicate (rc=$rc): $out"
fi
prove_legacy_green_structured_red "alternate G1 duplicate" "E_GATE_DUPLICATE" "gates"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Benign narrative G17 in the Human gates section must remain allowed.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n",
  "- **G16** ⛔ — Evidence of prompt-injection steering an agent.\n\nNarrative mention of unpublished G17 research does not add a stop.\n"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "benign: narrative G17 mention in Human gates section remains green"
else
  bad "benign narrative G17 (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "- **G1** — Schema-destructive change, non-additive migration, or manual write against a production database.\n- **G2** — Deleting user data, emptying buckets, removing deployments/envs/domains.\n",
  "- **G2** — Deleting user data, emptying buckets, removing deployments/envs/domains.\n- **G1** — Schema-destructive change, non-additive migration, or manual write against a production database.\n"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GATE_ORDER'; then
  ok "mutation: G1/G2 order swap fails with E_GATE_ORDER"
else
  bad "mutation gate order (rc=$rc): $out"
fi
prove_legacy_green_structured_red "gate order" "E_GATE_ORDER" "gates"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "Ten stages (`PLAN`, `DECOMPOSE`, `BUILD`, `TEST`, `REVIEW`, `UX-EVAL`,\n`SECURITY`, `MERGE`, `DEPLOY+VERIFY`, `RETRO`).",
  "Ten stages (`RETRO`, `DECOMPOSE`, `BUILD`, `TEST`, `REVIEW`, `UX-EVAL`,\n`SECURITY`, `MERGE`, `DEPLOY+VERIFY`, `PLAN`)."
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_STAGE_ORDER'; then
  ok "mutation: stage order swap fails with E_STAGE_ORDER"
else
  bad "mutation stage order (rc=$rc): $out"
fi
prove_legacy_green_structured_red "stage order" "E_STAGE_ORDER" "stages"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
if (!t.includes("| historian |")) throw new Error("missing historian row");
t=t.replace(/(\| historian \|[^\n]*\n)/, "$1| intern | notes | nothing |\n");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_ROLE_TABLE_ADDITION'; then
  ok "mutation: extra role-table row fails with E_ROLE_TABLE_ADDITION"
else
  bad "mutation role table addition (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Postfix weakeners on the full local clause (not prefix-only).
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "then **explicit human apply** only when convenient");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "mutation: postfix only-when-convenient fails with E_BINDING_WEAKENING"
else
  bad "mutation postfix convenient (rc=$rc): $out"
fi
prove_legacy_green_structured_red "postfix convenient" "E_BINDING_WEAKENING" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "then **explicit human apply** when practical");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "mutation: postfix when-practical fails with E_BINDING_WEAKENING"
else
  bad "mutation postfix practical (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "then **explicit human apply** unless convenient");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "mutation: postfix unless-convenient fails with E_BINDING_WEAKENING"
else
  bad "mutation postfix unless (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "then **explicit human apply**, which is optional");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "mutation: postfix which-is-optional fails with E_BINDING_WEAKENING"
else
  bad "mutation postfix which-optional (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "Fan-out + adversarial review + **G12** human merge gate; serialize when stateful",
  "Optional review; G12 when convenient"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_TIER_WEAKENING'; then
  ok "mutation: Tier C treatment weakening fails with E_TIER_WEAKENING"
else
  bad "mutation tier C treatment (rc=$rc): $out"
fi
prove_legacy_green_structured_red "tier C treatment" "E_TIER_WEAKENING" "tiers"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Benign control: "not just the smell" must not trip polarity.
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'not just' "$SANDBOX/AGENTS.md"; then
  ok "benign: not-just clause in review lenses remains green"
else
  bad "benign not-just (rc=$rc): $out"
fi

echo "# authority contradiction fixtures that mention AGENTS.md"
cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-principle-wins-mentions-agents.md" \
  "$SANDBOX/docs/planted-principle-wins.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'principle-wins-over-agents'; then
  ok "fixture: When AGENTS.md and a principle conflict, the principle wins fails"
else
  bad "fixture principle-wins-mentions-agents (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-principle-wins.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-outranks-agents.md" \
  "$SANDBOX/docs/planted-outranks.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'outranks-agents'; then
  ok "fixture: this document outranks AGENTS.md fails"
else
  bad "fixture outranks-agents (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-outranks.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-supersedes-agents.md" \
  "$SANDBOX/docs/planted-supersedes.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'supersedes-agents'; then
  ok "fixture: this file supersedes AGENTS.md fails"
else
  bad "fixture supersedes-agents (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-supersedes.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-benign-historical.md" \
  "$SANDBOX/docs/planted-historical.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "benign: retracted historical supersedes mention remains green"
else
  bad "benign historical (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-historical.md"

echo "# closed configuration invariants"
node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
c.byteBudget["AGENTS.md"] = 0;
c.byteBudget.mandatoryChain = 0;
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/mandatory-read-chain.v1.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BUDGET'; then
  ok "mutation: zero byte budgets fail with E_BUDGET"
else
  bad "mutation zero budget (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/mandatory-read-chain.v1.json" \
  "$SANDBOX/config/policy/mandatory-read-chain.v1.json"

node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
c.docsNonNormativeGlobs = [];
c.playbookGlobs = [];
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/mandatory-read-chain.v1.json"
# Same-PR empty globs must not disable docs coverage: plant a contradiction too.
cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-outranks-agents.md" \
  "$SANDBOX/docs/planted-outranks.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GLOB' && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION'; then
  ok "mutation: emptied globs fail E_GLOB and still scan planted contradiction"
else
  bad "mutation empty globs (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-outranks.md"
cp "$REPO_ROOT/config/policy/mandatory-read-chain.v1.json" \
  "$SANDBOX/config/policy/mandatory-read-chain.v1.json"

node -e '
const fs=require("fs");
const p=process.argv[1];
const c=JSON.parse(fs.readFileSync(p,"utf8"));
c.docsNonNormativeGlobs = ["tmp/**/*.md"];
c.conditionalDispatchPrompts.localOverrideTemplate = "tmp/{role}.md";
c.playbookDispatchMarker = "";
fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");
' "$SANDBOX/config/policy/mandatory-read-chain.v1.json"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_GLOB' && echo "$out" | grep -q 'E_CONFIG'; then
  ok "mutation: redirected globs/template/empty marker fail closed"
else
  bad "mutation redirected config (rc=$rc): $out"
fi
cp "$REPO_ROOT/config/policy/mandatory-read-chain.v1.json" \
  "$SANDBOX/config/policy/mandatory-read-chain.v1.json"

echo "# recursive discovery race (actual sensor + directory swap)"
DISCOVER_OUT=$(
  SANDBOX="$SANDBOX" REPO_ROOT="$REPO_ROOT" TOOL="$TOOL" \
  node --input-type=module -e '
import { mkdirSync, renameSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const sandbox = process.env.SANDBOX;
const repo = process.env.REPO_ROOT;
const { setDiscoverAfterOpenHook, main } = await import(pathToFileURL(join(repo, "scripts/contract-authority.mjs")).href);
const { legacyPathWalkMdFiles } = await import(pathToFileURL(join(repo, "scripts/lib/authority-discover.mjs")).href);

const planted = readFileSync(join(repo, "config/policy/fixtures/authority-contradictions/docs-outranks-agents.md"), "utf8");
writeFileSync(join(sandbox, "docs", "planted-swap.md"), planted);

const hold = join(sandbox, "docs-orig-hold");
const repl = join(sandbox, "docs-empty-repl");
mkdirSync(repl, { recursive: true });
writeFileSync(join(repl, "innocent.md"), "# innocent\n\n> **Authority:** Non-normative. Binding rules live in AGENTS.md.\n");

setDiscoverAfterOpenHook(({ relDir, absPath }) => {
  if (relDir !== "docs") {
    return;
  }
  renameSync(absPath, hold);
  renameSync(repl, absPath);
});
const result = main(["--repo-root", sandbox, "--format", "text"]);
setDiscoverAfterOpenHook(null);

const liveDocs = join(sandbox, "docs");
const legacyAcc = [];
legacyPathWalkMdFiles(sandbox, "docs", legacyAcc);
const legacyMissedPlanted = !legacyAcc.includes("docs/planted-swap.md");
const codes = (result.findings || []).map((f) => f.code);
const pathFail = result.exitCode !== 0 && codes.includes("E_PATH");

try { rmSync(liveDocs, { recursive: true, force: true }); } catch { /* ignore */ }
try { renameSync(hold, liveDocs); } catch { /* ignore */ }
try { rmSync(join(sandbox, "docs-empty-repl"), { recursive: true, force: true }); } catch { /* ignore */ }
try { rmSync(join(sandbox, "docs", "planted-swap.md")); } catch { /* ignore */ }

if (legacyMissedPlanted && pathFail) {
  console.log("DISCOVER_SWAP_FAIL_CLOSED codes=" + codes.join(","));
  process.exit(0);
}
console.log("DISCOVER_UNEXPECTED legacyMissed=" + legacyMissedPlanted + " exit=" + result.exitCode + " codes=" + JSON.stringify(codes));
process.exit(1);
'
) || true
if echo "$DISCOVER_OUT" | grep -q "DISCOVER_SWAP_FAIL_CLOSED"; then
  echo "  planted discovery-swap failure line:"
  echo "$DISCOVER_OUT" | sed 's/^/    /'
  ok "mutation: discovery directory swap cannot return green (E_PATH)"
else
  bad "mutation discovery swap: $DISCOVER_OUT"
fi
# Restore a clean docs tree after the swap test.
mkdir -p "$SANDBOX/docs"
{
  printf '%s\n' '# stub'
  printf '%s\n' '> **Authority:** Non-normative. Binding rules live in AGENTS.md.'
} > "$SANDBOX/docs/14-human-gates.md"

echo "# measure mode still accounts and fails closed"
out=$(node "$TOOL" --repo-root "$SANDBOX" --measure 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'fixed mandatory chain' && echo "$out" | grep -q 'conditional dispatch prompts'; then
  ok "measure: valid tree emits measurement fields and exits 0"
else
  bad "measure valid tree (rc=$rc): $out"
fi

mkdir -p "$SANDBOX/local/playbooks/builder.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" --measure 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PATH' && echo "$out" | grep -q 'local/playbooks/builder.md'; then
  ok "measure: unsafe existing local override fails closed"
else
  bad "measure unsafe override (rc=$rc): $out"
fi
rm -rf "$SANDBOX/local"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-outranks-agents.md" \
  "$SANDBOX/docs/planted-measure.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" --measure 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION'; then
  ok "measure: contradictory marked input fails closed"
else
  bad "measure contradictory input (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-measure.md"

echo "# missing-path classification (EACCES / EISDIR stay E_PATH)"
rm -f "$SANDBOX/README.md"
mkdir -p "$SANDBOX/README.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PATH' && echo "$out" | grep -q 'README.md' && ! echo "$out" | grep -q 'E_MISSING'; then
  ok "mutation: README.md as directory is E_PATH not E_MISSING"
else
  bad "mutation README directory (rc=$rc): $out"
fi
rm -rf "$SANDBOX/README.md"
cp "$REPO_ROOT/README.md" "$SANDBOX/README.md"

chmod 000 "$SANDBOX/docs/14-human-gates.md" 2>/dev/null || true
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
chmod 644 "$SANDBOX/docs/14-human-gates.md" 2>/dev/null || true
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_PATH' && echo "$out" | grep -q 'docs/14-human-gates.md'; then
  ok "mutation: unreadable docs file is E_PATH not E_MISSING"
else
  bad "mutation EACCES docs (rc=$rc): $out"
fi

echo "# modal / multi-occurrence polarity probes"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"
for pair in \
  "then **explicit human apply**|then **explicit human apply** may be skipped|may-be-skipped" \
  "then **explicit human apply**|then **explicit human apply** should occur|should-occur" \
  "then **explicit human apply**|then **explicit human apply** is recommended|is-recommended"
do
  src=${pair%%|*}
  rest=${pair#*|}
  dest=${rest%%|*}
  name=${rest##*|}
  node -e '
const fs=require("fs");
const p=process.argv[1];
const src=process.argv[2];
const dest=process.argv[3];
let t=fs.readFileSync(p,"utf8");
if (!t.includes(src)) throw new Error("missing " + src);
t=t.replace(src, dest);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md" "$src" "$dest"
  out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
  if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
    ok "probe: $name fails with E_BINDING_WEAKENING"
  else
    bad "probe $name (rc=$rc): $out"
  fi
  prove_legacy_green_structured_red "$name" "E_BINDING_WEAKENING" "delivery"
  cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"
done

# not-just must not truncate a later weakener, and must not invert as negation.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "not just **explicit human apply**, but **explicit human apply** may be skipped"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING' && ! echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "probe: not-just then may-be-skipped is weakening, not false negation"
else
  bad "probe not-just remainder (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Canonical decoy occurrence must not mask a later weakened occurrence.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**.",
  "then **explicit human apply**. Later, **explicit human apply** may be skipped."
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "probe: decoy canonical occurrence cannot mask a later weakener"
else
  bad "probe decoy occurrence (rc=$rc): $out"
fi
prove_legacy_green_structured_red "decoy occurrence" "E_BINDING_WEAKENING" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Benign: never-skip prohibition is not inverted by skip-shape detection.
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'You may not skip a gate' "$SANDBOX/AGENTS.md"; then
  ok "benign: may-not-skip prohibition remains green"
else
  bad "benign may-not-skip (rc=$rc): $out"
fi

echo "# polarity grammatical-target table (two families)"
POLARITY_TABLE=$(
  SEM="$REPO_ROOT/scripts/lib/contract-semantics.mjs" \
  node --input-type=module -e '
import { pathToFileURL } from "node:url";
const { diffBindingPhrase } = await import(pathToFileURL(process.env.SEM).href);
function codes(family, phrase, text) {
  return diffBindingPhrase(family, phrase, text).map((f) => f.code);
}
const rows = [];
function add(family, phrase, text, expect, name) {
  rows.push({ family, phrase, text, expect, name });
}
for (const [family, phrase] of [
  ["delivery-control", "explicit human apply"],
  ["six-lens-review", "file:line"],
]) {
  add(family, phrase, `you may not skip ${phrase}`, [], `${family} verb-before may-not-skip`);
  add(family, phrase, `never bypass ${phrase}`, [], `${family} verb-before never-bypass`);
  add(family, phrase, `do not waive ${phrase}`, [], `${family} verb-before do-not-waive`);
  add(family, phrase, `without skipping ${phrase}`, [], `${family} verb-before without-skipping`);
  add(family, phrase, `${phrase} must not be skipped`, [], `${family} phrase-before must-not-be-skipped`);
  add(family, phrase, `${phrase} may not be waived`, [], `${family} phrase-before may-not-be-waived`);
  add(family, phrase, `${phrase} cannot be bypassed`, [], `${family} phrase-before cannot-be-bypassed`);
  add(family, phrase, `you may not skip ${phrase}, but ${phrase} is not required`, ["E_BINDING_NEGATION"], `${family} strengthen-then-not-required`);
  add(family, phrase, `never bypass ${phrase}; however, ${phrase} may be skipped`, ["E_BINDING_WEAKENING"], `${family} strengthen-then-may-be-skipped`);
  add(family, phrase, `without skipping ${phrase}, agents may waive it`, ["E_BINDING_WEAKENING"], `${family} strengthen-then-waive-it`);
  add(family, phrase, `do not waive ${phrase}, unless it is convenient to do so`, ["E_BINDING_WEAKENING"], `${family} strengthen-then-unless-convenient`);
  add(family, phrase, `${phrase} must not be skipped but is optional`, ["E_BINDING_WEAKENING"], `${family} strengthen-then-optional`);
  add(family, phrase, `you may not skip ${phrase}, but it is no longer mandatory`, ["E_BINDING_NEGATION"], `${family} strengthen-then-no-longer-mandatory`);
  add(family, phrase, `never bypass ${phrase}, but it need not happen`, ["E_BINDING_NEGATION"], `${family} strengthen-then-need-not-happen`);
  add(family, phrase, `${phrase} is not required`, ["E_BINDING_NEGATION"], `${family} is-not-required`);
  add(family, phrase, `${phrase} is no longer mandatory`, ["E_BINDING_NEGATION"], `${family} is-no-longer-mandatory`);
  add(family, phrase, `${phrase} need not happen`, ["E_BINDING_NEGATION"], `${family} need-not-happen`);
  add(family, phrase, `${phrase} is not enforced`, ["E_BINDING_NEGATION"], `${family} is-not-enforced`);
  add(family, phrase, `do not require ${phrase}`, ["E_BINDING_NEGATION"], `${family} do-not-require`);
  add(family, phrase, `${phrase} may be skipped`, ["E_BINDING_WEAKENING"], `${family} may-be-skipped`);
  add(family, phrase, `${phrase} should occur`, ["E_BINDING_WEAKENING"], `${family} should-occur`);
  add(family, phrase, `${phrase} is recommended`, ["E_BINDING_WEAKENING"], `${family} is-recommended`);
  add(family, phrase, `not just ${phrase}, but ${phrase} may be skipped`, ["E_BINDING_WEAKENING"], `${family} not-just-then-skipped`);
  add(family, phrase, `Use ${phrase}. Later, ${phrase} may be skipped.`, ["E_BINDING_WEAKENING"], `${family} decoy-then-skipped`);
  add(family, phrase, `${phrase} is not optional`, [], `${family} is-not-optional`);
  add(family, phrase, `${phrase} is mandatory, not optional`, [], `${family} mandatory-not-optional`);
  add(family, phrase, `${phrase} must not be skipped, and is not optional`, [], `${family} must-not-skip-and-not-optional`);
  add(family, phrase, `${phrase} is not merely recommended; it is mandatory`, [], `${family} not-merely-recommended`);
  add(family, phrase, `${phrase} is not advisory`, ["E_BINDING_NEGATION"], `${family} is-not-advisory`);
  add(family, phrase, `${phrase} is not non-binding`, [], `${family} is-not-non-binding`);
  add(family, phrase, `${phrase} is mandatory rather than recommended`, [], `${family} mandatory-rather-than-recommended`);
  add(family, phrase, `${phrase} is never required`, ["E_BINDING_NEGATION"], `${family} is-never-required`);
  add(family, phrase, `${phrase} isn\u0027t required`, ["E_BINDING_NEGATION"], `${family} isnt-required`);
  add(family, phrase, `${phrase} isn\u0027t mandatory`, ["E_BINDING_NEGATION"], `${family} isnt-mandatory`);
  add(family, phrase, `${phrase} isn\u0027t enforced`, ["E_BINDING_NEGATION"], `${family} isnt-enforced`);
  add(family, phrase, `${phrase} doesn\u0027t need to happen`, ["E_BINDING_NEGATION"], `${family} doesnt-need-to-happen`);
  add(family, phrase, `${phrase} never needs to happen`, ["E_BINDING_NEGATION"], `${family} never-needs-to-happen`);
  add(family, phrase, `${phrase} needn\u0027t happen`, ["E_BINDING_NEGATION"], `${family} neednt-happen`);
  add(family, phrase, `${phrase} is never mandatory`, ["E_BINDING_NEGATION"], `${family} is-never-mandatory`);
  add(family, phrase, `${phrase} is never enforced`, ["E_BINDING_NEGATION"], `${family} is-never-enforced`);
  add(family, phrase, `never bypass ${phrase}, but ${phrase} isn\u0027t required`, ["E_BINDING_NEGATION"], `${family} strengthen-then-isnt-required`);
  add(family, phrase, `${phrase} must not be skipped, and isn\u0027t required`, ["E_BINDING_NEGATION"], `${family} must-not-skip-then-isnt-required`);
  add(family, phrase, `${phrase} must not be skipped and isn\u0027t required`, ["E_BINDING_NEGATION"], `${family} must-not-skip-and-isnt-required`);
  add(family, phrase, `${phrase} may not be waived yet isn\u0027t required`, ["E_BINDING_NEGATION"], `${family} may-not-waive-yet-isnt-required`);
  add(family, phrase, `${phrase} is never actually required`, ["E_BINDING_NEGATION"], `${family} is-never-actually-required`);
  add(family, phrase, `${phrase} isn\u0027t really mandatory`, ["E_BINDING_NEGATION"], `${family} isnt-really-mandatory`);
  add(family, phrase, `${phrase} isn\u0027t consistently enforced`, ["E_BINDING_NEGATION"], `${family} isnt-consistently-enforced`);
  add(family, phrase, `${phrase} is not recommended`, ["E_BINDING_NEGATION"], `${family} is-not-recommended`);
  add(family, phrase, `${phrase} is not binding`, ["E_BINDING_NEGATION"], `${family} is-not-binding`);
  add(family, phrase, `${phrase} is non-optional`, [], `${family} is-non-optional`);
  add(family, phrase, `${phrase} is not just recommended; it is mandatory`, [], `${family} not-just-recommended-mandatory`);
  add(family, phrase, `${phrase} is mandatory and cannot be skipped`, [], `${family} mandatory-and-cannot-be-skipped`);
  add(family, phrase, `${phrase} is always required`, [], `${family} is-always-required`);
  add(family, phrase, `${phrase} is required, not merely recommended`, [], `${family} required-not-merely-recommended`);
  add(family, phrase, `${phrase} is mandatory and may not be waived`, [], `${family} mandatory-and-may-not-be-waived`);
  add(family, phrase, `${phrase} is required and should never be skipped`, [], `${family} required-and-should-never-be-skipped`);
  add(family, phrase, `${phrase} is not required and cannot be skipped`, ["E_BINDING_NEGATION"], `${family} not-required-and-cannot-be-skipped`);
  add(family, phrase, `${phrase} is optional and must not be skipped`, ["E_BINDING_WEAKENING"], `${family} optional-and-must-not-be-skipped`);
  add(family, phrase, `${phrase} is recommended and may not be waived`, ["E_BINDING_WEAKENING"], `${family} recommended-and-may-not-be-waived`);
  add(family, phrase, `${phrase} isn\u0027t mandatory and should never be skipped`, ["E_BINDING_NEGATION"], `${family} isnt-mandatory-and-should-never-be-skipped`);
  add(family, phrase, `${phrase} may be skipped and must not be waived`, ["E_BINDING_WEAKENING"], `${family} may-be-skipped-and-must-not-be-waived`);
  add(family, phrase, `${phrase} is not optional and is mandatory`, [], `${family} not-optional-and-is-mandatory`);
  add(family, phrase, `${phrase} is not optional and cannot be skipped`, [], `${family} not-optional-and-cannot-be-skipped`);
  add(family, phrase, `${phrase} is not merely recommended and must not be waived`, [], `${family} not-merely-recommended-and-must-not-be-waived`);
  add(family, phrase, `${phrase} is always required and should never be skipped`, [], `${family} always-required-and-should-never-be-skipped`);
  add(family, phrase, `${phrase} is not operationally required`, ["E_BINDING_NEGATION"], `${family} is-not-operationally-required`);
  add(family, phrase, `${phrase} is not materially mandatory`, ["E_BINDING_NEGATION"], `${family} is-not-materially-mandatory`);
  add(family, phrase, `${phrase} is no longer categorically enforced`, ["E_BINDING_NEGATION"], `${family} is-no-longer-categorically-enforced`);
  add(family, phrase, `Unit tests cannot be skipped, ${phrase} is optional`, ["E_BINDING_WEAKENING"], `${family} unrelated-strengthen-then-optional`);
  add(family, phrase, `Unit tests cannot be skipped, ${phrase} is mandatory`, [], `${family} unrelated-strengthen-then-mandatory`);
  add(family, phrase, `${phrase} is optional, Unit tests cannot be skipped`, ["E_BINDING_WEAKENING"], `${family} optional-comma-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is optional \u2014 Unit tests cannot be skipped`, ["E_BINDING_WEAKENING"], `${family} optional-emdash-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is optional or Unit tests cannot be skipped`, ["E_BINDING_WEAKENING"], `${family} optional-or-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is mandatory, Unit tests cannot be skipped`, [], `${family} mandatory-comma-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is not technically required`, ["E_BINDING_NEGATION"], `${family} is-not-technically-required`);
  add(family, phrase, `${phrase} is not formally mandatory`, ["E_BINDING_NEGATION"], `${family} is-not-formally-mandatory`);
  add(family, phrase, `${phrase} is not necessarily required`, ["E_BINDING_NEGATION"], `${family} is-not-necessarily-required`);
  add(family, phrase, `${phrase} is not always required`, ["E_BINDING_NEGATION"], `${family} is-not-always-required`);
  add(family, phrase, `${phrase} is optional / Unit tests cannot be skipped`, ["E_BINDING_WEAKENING"], `${family} optional-slash-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is optional: Unit tests cannot be skipped`, ["E_BINDING_WEAKENING"], `${family} optional-colon-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is optional -- Unit tests cannot be skipped`, ["E_BINDING_WEAKENING"], `${family} optional-dash-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is optional (Unit tests cannot be skipped)`, ["E_BINDING_WEAKENING"], `${family} optional-paren-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is optional while Unit tests cannot be skipped`, ["E_BINDING_WEAKENING"], `${family} optional-while-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is optional plus Unit tests cannot be skipped`, ["E_BINDING_WEAKENING"], `${family} optional-plus-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is mandatory / Unit tests cannot be skipped`, [], `${family} mandatory-slash-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is mandatory: Unit tests cannot be skipped`, [], `${family} mandatory-colon-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is mandatory (Unit tests cannot be skipped)`, [], `${family} mandatory-paren-unrelated-cannot-skip`);
  add(family, phrase, `${phrase} is not in any way required`, ["E_BINDING_NEGATION"], `${family} is-not-in-any-way-required`);
  add(family, phrase, `${phrase} is not, technically, required`, ["E_BINDING_NEGATION"], `${family} is-not-comma-technically-required`);
  add(family, phrase, `${phrase} is not (technically) required`, ["E_BINDING_NEGATION"], `${family} is-not-paren-technically-required`);
  add(family, phrase, `${phrase} is technically not required`, ["E_BINDING_NEGATION"], `${family} is-technically-not-required`);
  add(family, phrase, `${phrase} cannot be required`, ["E_BINDING_NEGATION"], `${family} cannot-be-required`);
  add(family, phrase, `${phrase} does not have to happen`, ["E_BINDING_NEGATION"], `${family} does-not-have-to-happen`);
  add(family, phrase, `${phrase} cannot be skipped`, [], `${family} cannot-be-skipped`);
}
const failed = [];
for (const row of rows) {
  const got = codes(row.family, row.phrase, row.text);
  if (JSON.stringify(got) !== JSON.stringify(row.expect)) {
    failed.push(row.name + " got " + JSON.stringify(got) + " want " + JSON.stringify(row.expect));
  } else {
    console.log("POLARITY_OK " + row.name);
  }
}
if (failed.length) {
  console.log("POLARITY_FAIL " + failed.join(" | "));
  process.exit(1);
}
process.exit(0);
'
)
if [[ $? -eq 0 ]]; then
  echo "$POLARITY_TABLE" | grep -c 'POLARITY_OK' | awk '{print "    "$1" polarity table rows"}'
  ok "table-driven polarity across delivery-control and six-lens-review"
else
  bad "polarity table: $POLARITY_TABLE"
fi

echo "# Tier C treatment polarity table"
TIER_TABLE=$(
  SEM="$REPO_ROOT/scripts/lib/contract-semantics.mjs" \
  node --input-type=module -e '
import { pathToFileURL } from "node:url";
const { diffTierTreatments } = await import(pathToFileURL(process.env.SEM).href);
const canonical = "Fan-out + adversarial review + **G12** human merge gate; serialize when stateful";
const rows = [
  { name: "canonical-treatment", treatment: canonical, expect: [] },
  { name: "human-merge-is-not-required", treatment: "Fan-out + adversarial review + **G12** human merge is not required; serialize when stateful", expect: ["E_TIER_WEAKENING"] },
  { name: "human-merge-is-not-operationally-required", treatment: "Fan-out + adversarial review + **G12** human merge is not operationally required; serialize when stateful", expect: ["E_TIER_WEAKENING"] },
  { name: "human-merge-is-not-technically-required", treatment: "Fan-out + adversarial review + **G12** human merge is not technically required; serialize when stateful", expect: ["E_TIER_WEAKENING"] },
  { name: "human-merge-is-not-always-required", treatment: "Fan-out + adversarial review + **G12** human merge is not always required; serialize when stateful", expect: ["E_TIER_WEAKENING"] },
  { name: "human-merge-is-not-in-any-way-required", treatment: "Fan-out + adversarial review + **G12** human merge is not in any way required; serialize when stateful", expect: ["E_TIER_WEAKENING"] },
  { name: "human-merge-is-technically-not-required", treatment: "Fan-out + adversarial review + **G12** human merge is technically not required; serialize when stateful", expect: ["E_TIER_WEAKENING"] },
  { name: "human-merge-cannot-be-required", treatment: "Fan-out + adversarial review + **G12** human merge cannot be required; serialize when stateful", expect: ["E_TIER_WEAKENING"] },
  { name: "human-merge-does-not-have-to-happen", treatment: "Fan-out + adversarial review + **G12** human merge does not have to happen; serialize when stateful", expect: ["E_TIER_WEAKENING"] },
  { name: "human-merge-cannot-be-skipped", treatment: "Fan-out + adversarial review + **G12** human merge cannot be skipped; serialize when stateful", expect: [] },
  { name: "missing-fan-out", treatment: "Optional review; G12 when convenient", expect: ["E_TIER_WEAKENING"] },
];
const failed = [];
for (const row of rows) {
  const got = diffTierTreatments([{ id: "C", definition: "Money", treatment: row.treatment }]).map((f) => f.code);
  if (JSON.stringify(got) !== JSON.stringify(row.expect)) {
    failed.push(row.name + " got " + JSON.stringify(got) + " want " + JSON.stringify(row.expect));
  } else {
    console.log("TIER_OK " + row.name);
  }
}
if (failed.length) {
  console.log("TIER_FAIL " + failed.join(" | "));
  process.exit(1);
}
process.exit(0);
'
)
if [[ $? -eq 0 ]]; then
  echo "$TIER_TABLE" | grep -c 'TIER_OK' | awk '{print "    "$1" tier-C table rows"}'
  ok "table-driven Tier C treatment polarity"
else
  bad "tier C table: $TIER_TABLE"
fi

# Sensor-path receipts for both families (verb-before strengthening vs after-phrase negation).
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "you may not skip **explicit human apply**");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "sensor: may-not-skip explicit human apply stays green"
else
  bad "sensor may-not-skip apply (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "**explicit human apply** must not be skipped");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "sensor: explicit human apply must-not-be-skipped stays green"
else
  bad "sensor must-not-be-skipped apply (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "**explicit human apply** is not required");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: explicit human apply is-not-required fails with E_BINDING_NEGATION"
else
  bad "sensor is-not-required apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply is-not-required" "E_BINDING_NEGATION" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "never bypass **file:line**");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "sensor: never-bypass file:line stays green"
else
  bad "sensor never-bypass file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "**file:line** is no longer mandatory");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: file:line is-no-longer-mandatory fails with E_BINDING_NEGATION"
else
  bad "sensor file:line no-longer-mandatory (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Strengthening clause must not mask a later independent negation/weakener.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "you may not skip **explicit human apply**, but **explicit human apply** is not required"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: may-not-skip then is-not-required fails with E_BINDING_NEGATION"
else
  bad "sensor strengthen-then-not-required apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply strengthen-then-not-required" "E_BINDING_NEGATION" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "never bypass **explicit human apply**; however, **explicit human apply** may be skipped"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "sensor: never-bypass then may-be-skipped fails with E_BINDING_WEAKENING"
else
  bad "sensor strengthen-then-may-be-skipped apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply strengthen-then-skipped" "E_BINDING_WEAKENING" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "findings cite **file:line**",
  "you may not skip **file:line**, but it is no longer mandatory"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: may-not-skip file:line then no-longer-mandatory fails with E_BINDING_NEGATION"
else
  bad "sensor strengthen-then-no-longer-mandatory file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "findings cite **file:line**",
  "**file:line** must not be skipped but is optional"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "sensor: must-not-be-skipped file:line then optional fails with E_BINDING_WEAKENING"
else
  bad "sensor strengthen-then-optional file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Negated-softener strengthening stays green; obligation contractions / never stay red.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "**explicit human apply** is not optional");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "sensor: explicit human apply is-not-optional stays green"
else
  bad "sensor is-not-optional apply (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "**file:line** is not merely recommended; it is mandatory");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "sensor: file:line not-merely-recommended stays green"
else
  bad "sensor not-merely-recommended file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "**explicit human apply** isn\u0027t required");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: explicit human apply isnt-required fails with E_BINDING_NEGATION"
else
  bad "sensor isnt-required apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply isnt-required" "E_BINDING_NEGATION" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "**file:line** is never required");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: file:line is-never-required fails with E_BINDING_NEGATION"
else
  bad "sensor is-never-required file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "**explicit human apply** never needs to happen");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: explicit human apply never-needs-to-happen fails with E_BINDING_NEGATION"
else
  bad "sensor never-needs-to-happen apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply never-needs-to-happen" "E_BINDING_NEGATION" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "**file:line** isn\u0027t mandatory");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: file:line isnt-mandatory fails with E_BINDING_NEGATION"
else
  bad "sensor isnt-mandatory file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Conjunction / adverb / bare-not-recommended / strengthening receipts.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "**explicit human apply** must not be skipped and isn\u0027t required"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: must-not-skip and isnt-required fails with E_BINDING_NEGATION"
else
  bad "sensor must-not-skip-and-isnt-required apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply must-not-skip-and-isnt-required" "E_BINDING_NEGATION" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "**file:line** is never actually required");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: file:line is-never-actually-required fails with E_BINDING_NEGATION"
else
  bad "sensor is-never-actually-required file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "**explicit human apply** is not recommended");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION' && ! echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "sensor: explicit human apply is-not-recommended fails with E_BINDING_NEGATION"
else
  bad "sensor is-not-recommended apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply is-not-recommended" "E_BINDING_NEGATION" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "**file:line** is non-optional");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "sensor: file:line is-non-optional stays green"
else
  bad "sensor is-non-optional file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "**explicit human apply** is mandatory and cannot be skipped");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "sensor: explicit human apply mandatory-and-cannot-be-skipped stays green"
else
  bad "sensor mandatory-and-cannot-be-skipped apply (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "**file:line** is not just recommended; it is mandatory");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "sensor: file:line not-just-recommended-mandatory stays green"
else
  bad "sensor not-just-recommended-mandatory file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Reverse-order coordinating-and: LHS negation/weakening must not be
# masked by a later strengthening removal predicate.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "**explicit human apply** is not required and cannot be skipped"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: not-required and cannot-be-skipped fails with E_BINDING_NEGATION"
else
  bad "sensor not-required-and-cannot-be-skipped apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply not-required-and-cannot-be-skipped" "E_BINDING_NEGATION" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "findings cite **file:line**",
  "**file:line** isn\u0027t mandatory and should never be skipped"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: isnt-mandatory and should-never-be-skipped fails with E_BINDING_NEGATION"
else
  bad "sensor isnt-mandatory-and-should-never-be-skipped file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "**explicit human apply** is optional and must not be skipped"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "sensor: optional and must-not-be-skipped fails with E_BINDING_WEAKENING"
else
  bad "sensor optional-and-must-not-be-skipped apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply optional-and-must-not-be-skipped" "E_BINDING_WEAKENING" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "findings cite **file:line**",
  "**file:line** may be skipped and must not be waived"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "sensor: may-be-skipped and must-not-be-waived fails with E_BINDING_WEAKENING"
else
  bad "sensor may-be-skipped-and-must-not-be-waived file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Adverbial obligation hedges, unrelated-clause strengthening, Tier C.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "**explicit human apply** is not operationally required");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: explicit human apply is-not-operationally-required fails with E_BINDING_NEGATION"
else
  bad "sensor is-not-operationally-required apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply is-not-operationally-required" "E_BINDING_NEGATION" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "**file:line** is not materially mandatory");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: file:line is-not-materially-mandatory fails with E_BINDING_NEGATION"
else
  bad "sensor is-not-materially-mandatory file:line (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "**explicit human apply** is no longer categorically enforced");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: explicit human apply is-no-longer-categorically-enforced fails with E_BINDING_NEGATION"
else
  bad "sensor is-no-longer-categorically-enforced apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply is-no-longer-categorically-enforced" "E_BINDING_NEGATION" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "Unit tests cannot be skipped, **explicit human apply** is optional"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "sensor: unrelated cannot-be-skipped then optional fails with E_BINDING_WEAKENING"
else
  bad "sensor unrelated-strengthen-then-optional apply (rc=$rc): $out"
fi
prove_legacy_green_structured_red "apply unrelated-strengthen-then-optional" "E_BINDING_WEAKENING" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "Fan-out + adversarial review + **G12** human merge gate; serialize when stateful",
  "Fan-out + adversarial review + **G12** human merge is not required; serialize when stateful"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_TIER_WEAKENING'; then
  ok "sensor: Tier C human merge is-not-required fails with E_TIER_WEAKENING"
else
  bad "sensor tier-C human-merge-is-not-required (rc=$rc): $out"
fi
prove_legacy_green_structured_red "tier C human-merge-is-not-required" "E_TIER_WEAKENING" "tiers"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "Fan-out + adversarial review + **G12** human merge gate; serialize when stateful",
  "Fan-out + adversarial review + **G12** human merge is not operationally required; serialize when stateful"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_TIER_WEAKENING'; then
  ok "sensor: Tier C human merge is-not-operationally-required fails with E_TIER_WEAKENING"
else
  bad "sensor tier-C human-merge-is-not-operationally-required (rc=$rc): $out"
fi
prove_legacy_green_structured_red "tier C human-merge-is-not-operationally-required" "E_TIER_WEAKENING" "tiers"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Unrelated strengthening after a weakener (comma / em-dash / or).
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "**explicit human apply** is optional, Unit tests cannot be skipped"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
weak_n=$(printf '%s\n' "$out" | grep -c 'E_BINDING_WEAKENING' || true)
if [[ "$rc" -ne 0 ]] && [[ "$weak_n" -eq 1 ]] && ! echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: optional comma unrelated cannot-be-skipped fails with E_BINDING_WEAKENING"
else
  bad "sensor optional-comma-unrelated-cannot-skip apply (rc=$rc n=$weak_n): $out"
fi
prove_legacy_green_structured_red "apply optional-comma-unrelated-cannot-skip" "E_BINDING_WEAKENING" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "findings cite **file:line**",
  "**file:line** is optional, Unit tests cannot be skipped"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
weak_n=$(printf '%s\n' "$out" | grep -c 'E_BINDING_WEAKENING' || true)
if [[ "$rc" -ne 0 ]] && [[ "$weak_n" -eq 1 ]] && ! echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: file:line optional comma unrelated cannot-be-skipped fails with E_BINDING_WEAKENING"
else
  bad "sensor optional-comma-unrelated-cannot-skip file:line (rc=$rc n=$weak_n): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "**explicit human apply** is optional \u2014 Unit tests cannot be skipped"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
weak_n=$(printf '%s\n' "$out" | grep -c 'E_BINDING_WEAKENING' || true)
if [[ "$rc" -ne 0 ]] && [[ "$weak_n" -eq 1 ]] && ! echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: optional em-dash unrelated cannot-be-skipped fails with E_BINDING_WEAKENING"
else
  bad "sensor optional-emdash-unrelated-cannot-skip apply (rc=$rc n=$weak_n): $out"
fi
prove_legacy_green_structured_red "apply optional-emdash-unrelated-cannot-skip" "E_BINDING_WEAKENING" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "**explicit human apply** is optional or Unit tests cannot be skipped"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
weak_n=$(printf '%s\n' "$out" | grep -c 'E_BINDING_WEAKENING' || true)
if [[ "$rc" -ne 0 ]] && [[ "$weak_n" -eq 1 ]] && ! echo "$out" | grep -q 'E_BINDING_NEGATION'; then
  ok "sensor: optional or unrelated cannot-be-skipped fails with E_BINDING_WEAKENING"
else
  bad "sensor optional-or-unrelated-cannot-skip apply (rc=$rc n=$weak_n): $out"
fi
prove_legacy_green_structured_red "apply optional-or-unrelated-cannot-skip" "E_BINDING_WEAKENING" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "then **explicit human apply**",
  "**explicit human apply** is mandatory, Unit tests cannot be skipped"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "sensor: mandatory comma unrelated cannot-be-skipped stays green"
else
  bad "sensor mandatory-comma-unrelated-cannot-skip apply (rc=$rc): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# Generalized adverb/adverbial slot between negator and obligation predicate.
node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("then **explicit human apply**", "**explicit human apply** is not technically required");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
neg_n=$(printf '%s\n' "$out" | grep -c 'E_BINDING_NEGATION' || true)
if [[ "$rc" -ne 0 ]] && [[ "$neg_n" -eq 1 ]] && ! echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "sensor: explicit human apply is-not-technically-required fails with E_BINDING_NEGATION"
else
  bad "sensor is-not-technically-required apply (rc=$rc n=$neg_n): $out"
fi
prove_legacy_green_structured_red "apply is-not-technically-required" "E_BINDING_NEGATION" "delivery"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace("findings cite **file:line**", "**file:line** is not always required");
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
neg_n=$(printf '%s\n' "$out" | grep -c 'E_BINDING_NEGATION' || true)
if [[ "$rc" -ne 0 ]] && [[ "$neg_n" -eq 1 ]] && ! echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
  ok "sensor: file:line is-not-always-required fails with E_BINDING_NEGATION"
else
  bad "sensor is-not-always-required file:line (rc=$rc n=$neg_n): $out"
fi
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "Fan-out + adversarial review + **G12** human merge gate; serialize when stateful",
  "Fan-out + adversarial review + **G12** human merge is not technically required; serialize when stateful"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
tier_n=$(printf '%s\n' "$out" | grep -c 'E_TIER_WEAKENING' || true)
if [[ "$rc" -ne 0 ]] && [[ "$tier_n" -eq 1 ]]; then
  ok "sensor: Tier C human merge is-not-technically-required fails with E_TIER_WEAKENING"
else
  bad "sensor tier-C human-merge-is-not-technically-required (rc=$rc n=$tier_n): $out"
fi
prove_legacy_green_structured_red "tier C human-merge-is-not-technically-required" "E_TIER_WEAKENING" "tiers"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

node -e '
const fs=require("fs");
const p=process.argv[1];
let t=fs.readFileSync(p,"utf8");
t=t.replace(
  "Fan-out + adversarial review + **G12** human merge gate; serialize when stateful",
  "Fan-out + adversarial review + **G12** human merge is not always required; serialize when stateful"
);
fs.writeFileSync(p,t);
' "$SANDBOX/AGENTS.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
tier_n=$(printf '%s\n' "$out" | grep -c 'E_TIER_WEAKENING' || true)
if [[ "$rc" -ne 0 ]] && [[ "$tier_n" -eq 1 ]]; then
  ok "sensor: Tier C human merge is-not-always-required fails with E_TIER_WEAKENING"
else
  bad "sensor tier-C human-merge-is-not-always-required (rc=$rc n=$tier_n): $out"
fi
prove_legacy_green_structured_red "tier C human-merge-is-not-always-required" "E_TIER_WEAKENING" "tiers"
cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"

# New-subject separators, post-negator punctuation, pre-negator adverb, Tier-C.
assert_sensor_exact_code() {
  local desc="$1"
  local search="$2"
  local repl="$3"
  local code="$4"
  local legacy_name="${5:-}"
  local legacy_fam="${6:-}"
  cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"
  node -e '
const fs=require("fs");
const p=process.argv[1];
const s=process.argv[2];
const r=process.argv[3];
let t=fs.readFileSync(p,"utf8");
if (!t.includes(s)) { console.error("NEEDLE_MISSING "+s); process.exit(2); }
fs.writeFileSync(p, t.replace(s, r));
' "$SANDBOX/AGENTS.md" "$search" "$repl" || { bad "sensor $desc (needle missing)"; return; }
  out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
  n=$(printf '%s\n' "$out" | grep -c "$code" || true)
  if [[ "$rc" -ne 0 ]] && [[ "$n" -eq 1 ]]; then
    if [[ "$code" == "E_BINDING_WEAKENING" ]] && echo "$out" | grep -q 'E_BINDING_NEGATION'; then
      bad "sensor $desc (also E_BINDING_NEGATION): $out"
    elif [[ "$code" == "E_BINDING_NEGATION" ]] && echo "$out" | grep -q 'E_BINDING_WEAKENING'; then
      bad "sensor $desc (also E_BINDING_WEAKENING): $out"
    else
      ok "sensor: $desc fails with $code"
    fi
  else
    bad "sensor $desc (rc=$rc n=$n): $out"
  fi
  if [[ -n "$legacy_name" ]]; then
    prove_legacy_green_structured_red "$legacy_name" "$code" "$legacy_fam"
  fi
  cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"
}

assert_sensor_green() {
  local desc="$1"
  local search="$2"
  local repl="$3"
  cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"
  node -e '
const fs=require("fs");
const p=process.argv[1];
const s=process.argv[2];
const r=process.argv[3];
let t=fs.readFileSync(p,"utf8");
if (!t.includes(s)) { console.error("NEEDLE_MISSING "+s); process.exit(2); }
fs.writeFileSync(p, t.replace(s, r));
' "$SANDBOX/AGENTS.md" "$search" "$repl" || { bad "sensor $desc (needle missing)"; return; }
  out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok "sensor: $desc stays green"
  else
    bad "sensor $desc (rc=$rc): $out"
  fi
  cp "$SANDBOX/AGENTS.md.bak" "$SANDBOX/AGENTS.md"
}

APPLY_NEEDLE='then **explicit human apply**'
LINE_NEEDLE='findings cite **file:line**'
TIER_NEEDLE='Fan-out + adversarial review + **G12** human merge gate; serialize when stateful'

assert_sensor_exact_code \
  "optional slash unrelated cannot-be-skipped" \
  "$APPLY_NEEDLE" \
  "**explicit human apply** is optional / Unit tests cannot be skipped" \
  "E_BINDING_WEAKENING" \
  "apply optional-slash-unrelated-cannot-skip" "delivery"
assert_sensor_exact_code \
  "file:line optional colon unrelated cannot-be-skipped" \
  "$LINE_NEEDLE" \
  "**file:line** is optional: Unit tests cannot be skipped" \
  "E_BINDING_WEAKENING"
assert_sensor_exact_code \
  "optional ascii-dash unrelated cannot-be-skipped" \
  "$APPLY_NEEDLE" \
  "**explicit human apply** is optional -- Unit tests cannot be skipped" \
  "E_BINDING_WEAKENING" \
  "apply optional-dash-unrelated-cannot-skip" "delivery"
assert_sensor_exact_code \
  "optional paren unrelated cannot-be-skipped" \
  "$APPLY_NEEDLE" \
  "**explicit human apply** is optional (Unit tests cannot be skipped)" \
  "E_BINDING_WEAKENING" \
  "apply optional-paren-unrelated-cannot-skip" "delivery"
assert_sensor_exact_code \
  "file:line optional while unrelated cannot-be-skipped" \
  "$LINE_NEEDLE" \
  "**file:line** is optional while Unit tests cannot be skipped" \
  "E_BINDING_WEAKENING"
assert_sensor_exact_code \
  "optional plus unrelated cannot-be-skipped" \
  "$APPLY_NEEDLE" \
  "**explicit human apply** is optional plus Unit tests cannot be skipped" \
  "E_BINDING_WEAKENING" \
  "apply optional-plus-unrelated-cannot-skip" "delivery"

assert_sensor_green \
  "mandatory slash unrelated cannot-be-skipped" \
  "$APPLY_NEEDLE" \
  "**explicit human apply** is mandatory / Unit tests cannot be skipped"
assert_sensor_green \
  "mandatory colon unrelated cannot-be-skipped" \
  "$APPLY_NEEDLE" \
  "**explicit human apply** is mandatory: Unit tests cannot be skipped"
assert_sensor_green \
  "mandatory paren unrelated cannot-be-skipped" \
  "$APPLY_NEEDLE" \
  "**explicit human apply** is mandatory (Unit tests cannot be skipped)"

assert_sensor_exact_code \
  "explicit human apply is-not-comma-technically-required" \
  "$APPLY_NEEDLE" \
  "**explicit human apply** is not, technically, required" \
  "E_BINDING_NEGATION" \
  "apply is-not-comma-technically-required" "delivery"
assert_sensor_exact_code \
  "file:line is-not-paren-technically-required" \
  "$LINE_NEEDLE" \
  "**file:line** is not (technically) required" \
  "E_BINDING_NEGATION"
assert_sensor_exact_code \
  "explicit human apply is-technically-not-required" \
  "$APPLY_NEEDLE" \
  "**explicit human apply** is technically not required" \
  "E_BINDING_NEGATION" \
  "apply is-technically-not-required" "delivery"
assert_sensor_exact_code \
  "file:line is-not-in-any-way-required" \
  "$LINE_NEEDLE" \
  "**file:line** is not in any way required" \
  "E_BINDING_NEGATION"

assert_sensor_exact_code \
  "Tier C human merge is-not-in-any-way-required" \
  "$TIER_NEEDLE" \
  "Fan-out + adversarial review + **G12** human merge is not in any way required; serialize when stateful" \
  "E_TIER_WEAKENING" \
  "tier C human-merge-is-not-in-any-way-required" "tiers"
assert_sensor_exact_code \
  "Tier C human merge is-technically-not-required" \
  "$TIER_NEEDLE" \
  "Fan-out + adversarial review + **G12** human merge is technically not required; serialize when stateful" \
  "E_TIER_WEAKENING" \
  "tier C human-merge-is-technically-not-required" "tiers"
assert_sensor_exact_code \
  "Tier C human merge cannot-be-required" \
  "$TIER_NEEDLE" \
  "Fan-out + adversarial review + **G12** human merge cannot be required; serialize when stateful" \
  "E_TIER_WEAKENING" \
  "tier C human-merge-cannot-be-required" "tiers"
assert_sensor_exact_code \
  "Tier C human merge does-not-have-to-happen" \
  "$TIER_NEEDLE" \
  "Fan-out + adversarial review + **G12** human merge does not have to happen; serialize when stateful" \
  "E_TIER_WEAKENING" \
  "tier C human-merge-does-not-have-to-happen" "tiers"
assert_sensor_green \
  "Tier C human merge cannot-be-skipped" \
  "$TIER_NEEDLE" \
  "Fan-out + adversarial review + **G12** human merge cannot be skipped; serialize when stateful"

echo "# first-match contradiction masking"
cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-historical-then-active-supersedes.md" \
  "$SANDBOX/docs/planted-hist-then-active.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'supersedes-agents'; then
  ok "fixture: historical-then-active supersedes is not masked"
else
  bad "fixture historical-then-active (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-hist-then-active.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-active-then-historical-supersedes.md" \
  "$SANDBOX/docs/planted-active-then-hist.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'supersedes-agents'; then
  ok "fixture: active-then-historical supersedes still fails"
else
  bad "fixture active-then-historical (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-active-then-hist.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-benign-historical-only.md" \
  "$SANDBOX/docs/planted-hist-only.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "benign: historical-only supersedes mention remains green"
else
  bad "benign historical-only (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-hist-only.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-benign-historical.md" \
  "$SANDBOX/docs/planted-hist-retracted.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "benign: second retracted-historical control remains green"
else
  bad "benign historical retracted (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-hist-retracted.md"

echo "# contradiction position / deferral receipts"
cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-supersedes-before-marker.md" \
  "$SANDBOX/docs/planted-supersedes-before.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'supersedes-agents'; then
  ok "fixture: live supersedes before non-normative marker fails"
else
  bad "fixture supersedes-before-marker (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-supersedes-before.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-same-paragraph-authoritative.md" \
  "$SANDBOX/docs/planted-same-para-auth.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'self-authoritative'; then
  ok "fixture: same-paragraph Follow-AGENTS plus source-of-truth fails"
else
  bad "fixture same-paragraph-authoritative (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-same-para-auth.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-closed-list-follow-agents.md" \
  "$SANDBOX/docs/planted-closed-follow.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'closed-list'; then
  ok "fixture: Follow AGENTS.md plus this-list-is-closed fails"
else
  bad "fixture closed-list-follow-agents (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-closed-follow.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-historical-retracted-before-marker.md" \
  "$SANDBOX/docs/planted-hist-before.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "benign: retracted historical supersedes before marker remains green"
else
  bad "benign historical-before-marker (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-hist-before.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-historical-retracted-after-marker.md" \
  "$SANDBOX/docs/planted-hist-after.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "benign: retracted historical supersedes after marker remains green"
else
  bad "benign historical-after-marker (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-hist-after.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-same-paragraph-historical-then-active-supersedes.md" \
  "$SANDBOX/docs/planted-same-para-hist-then-active.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'supersedes-agents'; then
  ok "fixture: same-paragraph historical-then-active supersedes is not masked"
else
  bad "fixture same-paragraph-historical-then-active (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-same-para-hist-then-active.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-same-paragraph-active-then-historical-supersedes.md" \
  "$SANDBOX/docs/planted-same-para-active-then-hist.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'supersedes-agents'; then
  ok "fixture: same-paragraph active-then-historical supersedes still fails"
else
  bad "fixture same-paragraph-active-then-historical (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-same-para-active-then-hist.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-historical-dash-then-active-supersedes.md" \
  "$SANDBOX/docs/planted-hist-dash-active.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'supersedes-agents'; then
  ok "fixture: historical-then-emdash-active supersedes is not masked"
else
  bad "fixture historical-dash-then-active (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-hist-dash-active.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-historical-and-then-active-supersedes.md" \
  "$SANDBOX/docs/planted-hist-and-active.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'E_AUTHORITY_CONTRADICTION' && echo "$out" | grep -q 'supersedes-agents'; then
  ok "fixture: historical-then-and-active supersedes is not masked"
else
  bad "fixture historical-and-then-active (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-hist-and-active.md"

cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-benign-negated-supersedes.md" \
  "$SANDBOX/docs/planted-benign-negated.md"
out=$(node "$TOOL" --repo-root "$SANDBOX" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "benign: negated supersedes/outranks strengthening remains green"
else
  bad "benign negated supersedes (rc=$rc): $out"
fi
rm -f "$SANDBOX/docs/planted-benign-negated.md"

echo "# match/clause-local historical retraction table"
RETRACT_TABLE=$(
  SEM="$REPO_ROOT/scripts/lib/contract-semantics.mjs" \
  node --input-type=module -e '
import { pathToFileURL } from "node:url";
const { findDocsAuthorityClaims } = await import(pathToFileURL(process.env.SEM).href);
const banner = "> **Authority:** Non-normative. Binding rules live only in AGENTS.md.\n\n";
const rows = [
  {
    name: "retracted-only",
    text: banner + "Historically this file supersedes AGENTS.md; that claim is retired. Follow AGENTS.md.\n",
    expect: [],
  },
  {
    name: "historical-not-retired",
    text: banner + "Historically this file supersedes AGENTS.md; that claim is not retired.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "historical-never-retired",
    text: banner + "Historically this file supersedes AGENTS.md; that claim was never retired.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "historical-do-not-treat-as-retired",
    text: banner + "Historically this file supersedes AGENTS.md; do not treat that claim as retired.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "historical-no-longer-true",
    text: banner + "Historically this file supersedes AGENTS.md; that claim is no longer true.\n",
    expect: [],
  },
  {
    name: "same-paragraph-later-active",
    text: banner + "Historically this file supersedes AGENTS.md; that claim is retired. Follow AGENTS.md. This file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "same-paragraph-earlier-active",
    text: banner + "This file supersedes AGENTS.md. Historically this file supersedes AGENTS.md; that claim is retired. Follow AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "same-sentence-later-active",
    text: banner + "Historically this file supersedes AGENTS.md; that claim is retired, but this file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "same-sentence-earlier-active",
    text: banner + "This file supersedes AGENTS.md, but historically that claim is retired.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "dash-then-active",
    text: banner + "Historically this file supersedes AGENTS.md; that claim is retired — this file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "en-dash-then-active",
    text: banner + "Historically this file supersedes AGENTS.md; that claim is retired \u2013 this file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "ascii-dash-then-active",
    text: banner + "Historically this file supersedes AGENTS.md; that claim is retired -- this file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "and-then-active",
    text: banner + "Historically this file supersedes AGENTS.md, and that claim is retired, and this file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "and-without-comma-then-active",
    text: banner + "Historically this file supersedes AGENTS.md and that claim is retired and this file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "no-document-supersedes",
    text: banner + "No document supersedes AGENTS.md.\n",
    expect: [],
  },
  {
    name: "nothing-outranks",
    text: banner + "Nothing outranks AGENTS.md.\n",
    expect: [],
  },
  {
    name: "never-supersedes",
    text: banner + "This file never supersedes AGENTS.md.\n",
    expect: [],
  },
  {
    name: "never-outranks",
    text: banner + "This file never outranks AGENTS.md.\n",
    expect: [],
  },
  {
    name: "never-bounded-modifier-supersedes",
    text: banner + "This file never under any circumstances supersedes AGENTS.md.\n",
    expect: [],
  },
  {
    name: "never-comma-wrapped-modifier-supersedes",
    text: banner + "This file never, under any circumstances, supersedes AGENTS.md.\n",
    expect: [],
  },
  {
    name: "no-document-long-subject-supersedes",
    text: banner + "No document in this entire repository ever supersedes AGENTS.md.\n",
    expect: [],
  },
  {
    name: "nothing-long-subject-outranks",
    text: banner + "Nothing in this entire repository ever outranks AGENTS.md.\n",
    expect: [],
  },
  {
    name: "negation-does-not-mask-later-active",
    text: banner + "No document supersedes AGENTS.md. This file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "never-then-but-active",
    text: banner + "This file never supersedes AGENTS.md, but this file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "unrelated-negation-before-active",
    text: banner + "No earlier claim was accepted, but this file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "not-only-supersedes",
    text: banner + "This file not only supersedes AGENTS.md; it also outranks it.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "not-merely-supersedes",
    text: banner + "This file not merely supersedes AGENTS.md; it outranks AGENTS.md.\n",
    expect: ["outranks-agents", "supersedes-agents"],
  },
  {
    name: "no-doubt-supersedes",
    text: banner + "There is no doubt this file supersedes AGENTS.md.\n",
    expect: ["supersedes-agents"],
  },
  {
    name: "no-longer-supersedes",
    text: banner + "This file no longer supersedes AGENTS.md.\n",
    expect: [],
  },
  {
    name: "nobody-supersedes",
    text: banner + "Nobody supersedes AGENTS.md.\n",
    expect: [],
  },
];
const failed = [];
for (const row of rows) {
  const got = [...new Set(findDocsAuthorityClaims(row.text).map((h) => h.id))];
  if (JSON.stringify(got) !== JSON.stringify(row.expect)) {
    failed.push(row.name + " got " + JSON.stringify(got) + " want " + JSON.stringify(row.expect));
  } else {
    console.log("RETRACT_OK " + row.name);
  }
}
if (failed.length) {
  console.log("RETRACT_FAIL " + failed.join(" | "));
  process.exit(1);
}
process.exit(0);
'
)
if [[ $? -eq 0 ]]; then
  echo "$RETRACT_TABLE" | grep -c 'RETRACT_OK' | awk '{print "    "$1" retraction table rows"}'
  ok "table-driven match/clause-local historical retraction"
else
  bad "retraction table: $RETRACT_TABLE"
fi

echo "# table-driven closed-config mutations"
CFG_MUT_OUT=$(
  SANDBOX="$SANDBOX" REPO_ROOT="$REPO_ROOT" \
  node --input-type=module -e '
import { readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const sandbox = process.env.SANDBOX;
const repo = process.env.REPO_ROOT;
const { main } = await import(pathToFileURL(join(repo, "scripts/contract-authority.mjs")).href);
const cfgPath = join(sandbox, "config/policy/mandatory-read-chain.v1.json");
const orig = readFileSync(join(repo, "config/policy/mandatory-read-chain.v1.json"), "utf8");
const mutations = [
  { name: "schemaVersion", code: "E_CONFIG", patch: (c) => { c.schemaVersion = "0.0.0"; } },
  { name: "authority", code: "E_CONFIG", patch: (c) => { c.authority = "docs are authority"; } },
  { name: "machineCanonical.humanGates", code: "E_CONFIG", patch: (c) => { c.machineCanonical.humanGates = "docs/14-human-gates.md"; } },
  { name: "sessionStartNotBudgeted", code: "E_CONFIG", patch: (c) => { c.sessionStartNotBudgeted = []; } },
  { name: "disclosurePhrases", code: "E_CONFIG", patch: (c) => { c.conditionalDispatchPrompts.disclosurePhrases = []; } },
  { name: "requiredBindingFamilies.patterns", code: "E_CONFIG", patch: (c) => { c.requiredBindingFamilies[1].patterns = []; } },
  { name: "defaultRole.whenUnnamed", code: "E_CONFIG", patch: (c) => { c.defaultRole.whenUnnamed = false; } },
  { name: "forbiddenContractPatterns", code: "E_CONFIG", patch: (c) => { c.forbiddenContractPatterns = []; } },
  { name: "forbiddenRepoClaims", code: "E_CONFIG", patch: (c) => { c.forbiddenRepoClaims = []; } },
  { name: "tokenProxy.id", code: "E_CONFIG", patch: (c) => { c.tokenProxy.id = "tokens-are-vibes"; } },
  { name: "preChangeAt.commit", code: "E_CONFIG", patch: (c) => { c.preChangeAt.commit = "deadbeef"; } },
  { name: "policyManifestMirrorPath", code: "E_CONFIG", patch: (c) => { c.policyManifestMirrorPath = "docs/14-human-gates.md"; } },
];
const failed = [];
for (const mut of mutations) {
  writeFileSync(cfgPath, orig);
  const c = JSON.parse(orig);
  mut.patch(c);
  writeFileSync(cfgPath, JSON.stringify(c, null, 2) + "\n");
  const result = main(["--repo-root", sandbox, "--format", "text"]);
  const codes = (result.findings || []).map((f) => f.code);
  if (result.exitCode === 0 || !codes.includes(mut.code)) {
    failed.push(mut.name + " exit=" + result.exitCode + " codes=" + codes.join(","));
  } else {
    console.log("CFG_MUT_OK " + mut.name + " " + mut.code);
  }
}
writeFileSync(cfgPath, orig);
const control = main(["--repo-root", sandbox, "--format", "text"]);
if (control.exitCode !== 0) {
  failed.push("valid-config control exit=" + control.exitCode + " " + JSON.stringify(control.findings));
} else {
  console.log("CFG_MUT_OK valid-config");
}
if (failed.length) {
  console.log("CFG_MUT_FAIL " + failed.join(" | "));
  process.exit(1);
}
process.exit(0);
'
)
cfg_rc=$?
if [[ "$cfg_rc" -eq 0 ]]; then
  echo "$CFG_MUT_OUT" | sed 's/^/    /'
  ok "table-driven config mutations fail closed with valid-config control"
else
  bad "table-driven config mutations: $CFG_MUT_OUT"
fi
cp "$REPO_ROOT/config/policy/mandatory-read-chain.v1.json" \
  "$SANDBOX/config/policy/mandatory-read-chain.v1.json"

echo "# table-driven rule-migration audit mutations"
AUDIT_MUT_OUT=$(
  SANDBOX="$SANDBOX" REPO_ROOT="$REPO_ROOT" \
  node --input-type=module -e '
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const sandbox = process.env.SANDBOX;
const repo = process.env.REPO_ROOT;
const { main } = await import(pathToFileURL(join(repo, "scripts/contract-authority.mjs")).href);
const auditPath = join(sandbox, "config/policy/rule-migration-audit.v1.json");
const orig = readFileSync(join(repo, "config/policy/rule-migration-audit.v1.json"), "utf8");
const extraFam = {
  id: "made-up-family",
  label: "not in the closed set",
  home: "nowhere",
  machine: [],
};
const mutations = [
  { name: "missing-families-array", code: "E_AUDIT", patch: (a) => { delete a.families; } },
  { name: "families-not-array", code: "E_AUDIT", patch: (a) => { a.families = "nope"; } },
  { name: "family-not-object", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0] = "nope"; } },
  { name: "missing-id", code: "E_AUDIT_FAMILY", patch: (a) => { delete a.families[0].id; } },
  { name: "empty-id", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0].id = ""; } },
  { name: "missing-label", code: "E_AUDIT_FAMILY", patch: (a) => { delete a.families[0].label; } },
  { name: "missing-home", code: "E_AUDIT_FAMILY", patch: (a) => { delete a.families[0].home; } },
  { name: "missing-machine", code: "E_AUDIT_FAMILY", patch: (a) => { delete a.families[0].machine; } },
  { name: "machine-not-array", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0].machine = "scripts/gate.sh"; } },
  { name: "duplicate-id", code: "E_AUDIT_FAMILY_DUPLICATE", patch: (a) => { a.families.push({ ...a.families[0] }); } },
  { name: "extra-family", code: "E_AUDIT_FAMILY_ADDITION", patch: (a) => { a.families.push(extraFam); } },
  { name: "drop-family", code: "E_AUDIT_FAMILY_OMISSION", patch: (a) => { a.families.splice(0, 1); } },
  { name: "malformed-audit-object", code: "E_AUDIT", patch: () => null },
  { name: "audit-json-null", code: "E_AUDIT", raw: "null\n" },
  { name: "audit-json-false", code: "E_AUDIT", raw: "false\n" },
  { name: "audit-json-zero", code: "E_AUDIT", raw: "0\n" },
  { name: "audit-json-empty-string", code: "E_AUDIT", raw: "\"\"\n" },
  { name: "root-authority-docs-14", code: "E_AUDIT", patch: (a) => { a.authority = "docs/14-human-gates.md"; } },
  { name: "root-issue-999", code: "E_AUDIT", patch: (a) => { a.issue = 999; } },
  { name: "root-schemaVersion-false", code: "E_AUDIT", patch: (a) => { a.schemaVersion = false; } },
  { name: "root-combined-drift", code: "E_AUDIT", patch: (a) => { a.authority = "docs/14-human-gates.md"; a.issue = 999; a.schemaVersion = false; } },
  { name: "every-home-readme", code: "E_AUDIT_FAMILY", patch: (a) => { for (const f of a.families) f.home = "README.md: nowhere"; } },
  { name: "every-machine-empty", code: "E_AUDIT_FAMILY", patch: (a) => { for (const f of a.families) f.machine = []; } },
  { name: "every-home-and-machine", code: "E_AUDIT_FAMILY", patch: (a) => { for (const f of a.families) { f.home = "README.md: nowhere"; f.machine = []; } } },
  { name: "label-drift", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0].label = "drifted label"; } },
  { name: "home-drift", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0].home = "README.md: nowhere"; } },
  { name: "machine-reordered", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0].machine = a.families[0].machine.slice().reverse(); } },
  { name: "machine-null-entry", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0].machine = [null]; } },
  { name: "machine-false-entry", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0].machine = [false]; } },
  { name: "machine-zero-entry", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0].machine = [0]; } },
  { name: "machine-object-entry", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0].machine = [{}]; } },
  { name: "unknown-root-key", code: "E_AUDIT", patch: (a) => { a.canonicalDoctrine = true; } },
  { name: "unknown-family-key", code: "E_AUDIT_FAMILY", patch: (a) => { a.families[0].extra = "nope"; } },
  { name: "note-may-vary", expectGreen: true, patch: (a) => { a.note = "varied descriptive note"; } },
];
const failed = [];
for (const mut of mutations) {
  if (Object.prototype.hasOwnProperty.call(mut, "raw")) {
    writeFileSync(auditPath, mut.raw);
  } else {
    const parsed = JSON.parse(orig);
    const patched = mut.patch(parsed);
    const body = patched === null ? "[]\n" : JSON.stringify(parsed, null, 2) + "\n";
    writeFileSync(auditPath, body);
  }
  const result = main(["--repo-root", sandbox, "--format", "text"]);
  const codes = (result.findings || []).map((f) => f.code);
  if (mut.expectGreen) {
    if (result.exitCode !== 0) {
      failed.push(mut.name + " expected green exit=" + result.exitCode + " codes=" + codes.join(","));
    } else {
      console.log("AUDIT_MUT_OK " + mut.name + " green");
    }
  } else if (result.exitCode === 0 || !codes.includes(mut.code)) {
    failed.push(mut.name + " exit=" + result.exitCode + " codes=" + codes.join(","));
  } else {
    console.log("AUDIT_MUT_OK " + mut.name + " " + mut.code);
  }
}
writeFileSync(auditPath, orig);
const control = main(["--repo-root", sandbox, "--format", "text"]);
if (control.exitCode !== 0) {
  failed.push("valid-audit control exit=" + control.exitCode + " " + JSON.stringify(control.findings));
} else {
  console.log("AUDIT_MUT_OK valid-audit");
}
if (failed.length) {
  console.log("AUDIT_MUT_FAIL " + failed.join(" | "));
  process.exit(1);
}
process.exit(0);
'
)
audit_rc=$?
if [[ "$audit_rc" -eq 0 ]]; then
  echo "$AUDIT_MUT_OUT" | sed 's/^/    /'
  ok "table-driven rule-migration audit mutations fail closed with valid-audit control"
else
  bad "table-driven rule-migration audit mutations: $AUDIT_MUT_OUT"
fi
cp "$REPO_ROOT/config/policy/rule-migration-audit.v1.json" \
  "$SANDBOX/config/policy/rule-migration-audit.v1.json"

echo "# pre-opendir replace/restore cannot omit a committed docs file"
GIT_SANDBOX="$ROOT/git-sandbox"
rm -rf "$GIT_SANDBOX"
mkdir -p "$GIT_SANDBOX"
# Reuse the already-valid sandbox tree as a committed git repo.
cp -R "$SANDBOX/." "$GIT_SANDBOX/"
cp "$REPO_ROOT/config/policy/fixtures/authority-contradictions/docs-outranks-agents.md" \
  "$GIT_SANDBOX/docs/committed-contradiction.md"
(
  CDPATH='' cd "$GIT_SANDBOX" || exit 1
  git init -q
  git add -A
  git -c user.name=gibson -c user.email=sensor@gibson.invalid commit -q -m "seed"
)
PRE_OPENDIR_OUT=$(
  GIT_SANDBOX="$GIT_SANDBOX" REPO_ROOT="$REPO_ROOT" \
  node --input-type=module -e '
import { mkdirSync, renameSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const sandbox = process.env.GIT_SANDBOX;
const repo = process.env.REPO_ROOT;
const {
  setDiscoverBeforeOpendirHook,
  setDiscoverAfterOpenHook,
  main,
} = await import(pathToFileURL(join(repo, "scripts/contract-authority.mjs")).href);
const { listCommittedMdFiles } = await import(pathToFileURL(join(repo, "scripts/lib/authority-discover.mjs")).href);

const committed = listCommittedMdFiles(sandbox, "docs") || [];
if (!committed.includes("docs/committed-contradiction.md")) {
  console.log("PRE_OPENDIR_NO_GIT_NAME");
  process.exit(1);
}

const hold = join(sandbox, "docs-hold");
const repl = join(sandbox, "docs-repl");
mkdirSync(repl, { recursive: true });
writeFileSync(join(repl, "innocent.md"), "# innocent\n\n> **Authority:** Non-normative. Binding rules live in AGENTS.md.\n");

setDiscoverBeforeOpendirHook(({ relDir, absPath }) => {
  if (relDir !== "docs") return;
  renameSync(absPath, hold);
  renameSync(repl, absPath);
});
setDiscoverAfterOpenHook(({ relDir, absPath }) => {
  if (relDir !== "docs") return;
  try { renameSync(absPath, repl); } catch { /* ignore */ }
  try { renameSync(hold, absPath); } catch { /* ignore */ }
});
const result = main(["--repo-root", sandbox, "--format", "text"]);
setDiscoverBeforeOpendirHook(null);
setDiscoverAfterOpenHook(null);
const codes = (result.findings || []).map((f) => f.code);
const msgs = (result.findings || []).map((f) => f.message).join("\n");
const omittedGreen = result.exitCode === 0;
const sawCommitted =
  /committed-contradiction/.test(msgs) ||
  codes.includes("E_AUTHORITY_CONTRADICTION") ||
  codes.includes("E_PATH");
if (!omittedGreen && sawCommitted) {
  console.log("PRE_OPENDIR_FAIL_CLOSED codes=" + codes.join(","));
  process.exit(0);
}
console.log("PRE_OPENDIR_UNEXPECTED exit=" + result.exitCode + " codes=" + JSON.stringify(codes));
process.exit(1);
'
) || true
if echo "$PRE_OPENDIR_OUT" | grep -q "PRE_OPENDIR_FAIL_CLOSED"; then
  echo "$PRE_OPENDIR_OUT" | sed 's/^/    /'
  ok "mutation: pre-opendir replace/restore cannot omit committed docs file"
else
  bad "mutation pre-opendir restore: $PRE_OPENDIR_OUT"
fi

echo
echo "contract-authority.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
