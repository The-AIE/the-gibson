#!/usr/bin/env bash
# architecture-fitness-self-fixture:v1
# architecture-fitness.test.sh — sensors for scripts/architecture-fitness.sh (#184)
#
# Temporary fixture repositories only. Deterministic. No network.
# Parent-shell PASS/FAIL accounting — no false-green subshell counters.
#
# USAGE
#   scripts/tests/architecture-fitness.test.sh
set -uo pipefail
# #467: claim.sh refuses an unvendored reservation; tests claim as claude.
export GIBSON_AGENT_VENDOR="${GIBSON_AGENT_VENDOR:-claude}"

# Hermetic git identity (#101)
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export LC_ALL=C
export LANG=C

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COLLECTOR="$SCRIPT_DIR/../architecture-fitness.sh"
PASS=0
FAIL=0

ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() {
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    bad "$1 (want '$3', got '$2')"
  fi
}
contains() {
  if printf '%s' "$2" | grep -F -- "$3" >/dev/null; then
    ok "$1"
  else
    bad "$1 (missing '$3')"
  fi
}
lacks() {
  if printf '%s' "$2" | grep -F -- "$3" >/dev/null; then
    bad "$1 (unexpected '$3')"
  else
    ok "$1"
  fi
}

command -v node >/dev/null || { echo "architecture-fitness.test.sh: node is required"; exit 1; }
command -v git  >/dev/null || { echo "architecture-fitness.test.sh: git is required"; exit 1; }
[[ -x "$COLLECTOR" || -f "$COLLECTOR" ]] || { echo "architecture-fitness.test.sh: collector missing"; exit 1; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-archfit.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

GIT="git -c user.email=sensor@gibson.invalid -c user.name=gibson-sensor -c commit.gpgsign=false"

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# Minimal control-plane fixture with known classifications and tags.
seed_fixture() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "$repo/scripts/lib" "$repo/scripts/tests" "$repo/docs" "$repo/config" \
           "$repo/.github/workflows" "$repo/dist" "$repo/ci"
  $GIT init -q "$repo"
  git -C "$repo" symbolic-ref HEAD refs/heads/main

  # production drivers (explicit map)
  cat > "$repo/scripts/claim.sh" <<'EOF'
#!/usr/bin/env bash
# claim driver
. "$SCRIPT_DIR/lib/claim-guards.sh"
if [[ "$1" == "x" ]]; then
  die "no"
  exit 1
fi
case "$1" in
  a) ALLOW ;;
  *) REFUSE ;;
esac
# G1 appears here for duplicate-id diagnostics
echo "gate G1"
EOF

  cat > "$repo/scripts/lib/claim-guards.sh" <<'EOF'
#!/usr/bin/env bash
# guards
true
EOF

  cat > "$repo/scripts/release-claim.sh" <<'EOF'
#!/usr/bin/env bash
. "$RELEASE_LIB_DIR/claim-guards.sh"
if true; then exit 0; fi
EOF

  cat > "$repo/scripts/claim-reaper.sh" <<'EOF'
#!/usr/bin/env bash
# reaper
if true; then return 0; fi
EOF

  cat > "$repo/scripts/loop-fleet.sh" <<'EOF'
#!/usr/bin/env bash
# fleet
while false; do break; done
EOF

  cat > "$repo/scripts/loop.sh" <<'EOF'
#!/usr/bin/env bash
# loop + handoff
source "$GIBSON/scripts/silent-noop.sh"
source "$SCRIPT_DIR/silent-noop.sh"
# dynamic include — must be unknown, never guessed
source "$DYNAMIC_LIB/thing.sh"
# statically spelled, but absent — must be unknown rather than an invented edge
source "$SCRIPT_DIR/does-not-exist.sh"
if true; then source "$SCRIPT_DIR/lib/compound.sh"; fi
if true; then exit 0; fi

usage() {
  cat <<'USAGE'
source "$SCRIPT_DIR/not-executable-doc-example.sh"
USAGE
}
EOF

  cat > "$repo/scripts/lib/compound.sh" <<'EOF'
#!/usr/bin/env bash
true
EOF

  cat > "$repo/scripts/silent-noop.sh" <<'EOF'
#!/usr/bin/env bash
true
EOF

  cat > "$repo/scripts/gate.sh" <<'EOF'
#!/usr/bin/env bash
# gate Law 4
if true; then exit 0; fi
EOF

  cat > "$repo/scripts/gate-baseline.sh" <<'EOF'
#!/usr/bin/env bash
if true; then exit 0; fi
EOF

  cat > "$repo/scripts/release-preflight.sh" <<'EOF'
#!/usr/bin/env bash
# stale-head checks live here in production; fixture marker only
if true; then exit 0; fi
EOF

  # tests (classified separately) with mutation-category tags
  cat > "$repo/scripts/tests/demo.test.sh" <<'EOF'
#!/usr/bin/env bash
ok "mutation-category:review_bypass receipt"
ok "mutation-category:stale_head_acceptance receipt"
ok "mutation-category:halt_bypass receipt"
ok "mutation-category:corrupt_state_progress receipt"
ok "mutation-category:claim_ambiguity receipt"
ok "mutation-category:false_delivery_success receipt"
ok "mutation-category:incomplete_cleanup receipt"
ok "mutation receipt: review bypass sensor would fail"
echo "stale-head APPROVE is BLOCKED"
echo "Law 5 and G12 and tier-c"
EOF

  # documentation
  cat > "$repo/docs/readme.md" <<'EOF'
# Doc
Human gate G1 is listed here for duplicate diagnostics.
Law 1 applies.
EOF
  cat > "$repo/docs/mutation-words-are-not-evidence.md" <<'EOF'
# Prose is not a mutation receipt
mutation-category:review_bypass
mutation-category:stale_head_acceptance
mutation-category:halt_bypass
mutation-category:corrupt_state_progress
mutation-category:claim_ambiguity
mutation-category:false_delivery_success
mutation-category:incomplete_cleanup
EOF
  cat > "$repo/README.md" <<'EOF'
# Fixture
EOF

  # Exactly one self-fixture marker. Kept out of demo.test.sh so its assertions count.
  printf '%s\n' '# architecture-fitness-self-fixture:v1' > "$repo/scripts/tests/architecture-fitness.test.sh"

  # config / workflows
  cat > "$repo/config/app.json" <<'EOF'
{"ok": true}
EOF
  cat > "$repo/.github/workflows/ci.yml" <<'EOF'
name: ci
on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF
  cat > "$repo/ci/gate.yml" <<'EOF'
name: gate
EOF

  # generated
  cat > "$repo/dist/bundle.min.js" <<'EOF'
console.log(1);
EOF

  # other
  cat > "$repo/notes.txt" <<'EOF'
plain
EOF

  $GIT -C "$repo" add -A
  $GIT -C "$repo" commit -q -m "fixture base"
}

# Baseline JSON from a report (schema rewrite for baseline artifact shape).
write_baseline_from_report() {
  local report_json="$1" out="$2"
  node - "$report_json" "$out" <<'NODE'
const fs = require("fs");
const rep = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const base = {
  schema: "gibson.architecture-fitness-baseline.v1",
  disposition: "report-only-baseline",
  notes: rep.notes,
  source: {
    commit: rep.source.commit,
    tree: rep.source.tree,
    mode: "commit",
    exact: true,
    dirty: false,
    ref: rep.source.commit,
  },
  collector: rep.collector,
  classification: rep.classification,
  safety_critical_drivers: rep.safety_critical_drivers,
  shell_dependencies: rep.shell_dependencies,
  policy_identifiers: rep.policy_identifiers,
  mutation_receipts: rep.mutation_receipts,
};
fs.writeFileSync(process.argv[3], JSON.stringify(base, null, 2) + "\n");
NODE
}

run_collector() {
  # run_collector <repo> <args...>  → sets OUT, RC  (parent shell)
  local repo="$1"
  shift
  OUT=$("$COLLECTOR" --repo "$repo" "$@" 2>"$ROOT/err.txt")
  RC=$?
}

# ---------------------------------------------------------------------------
echo "=== help / usage ==="
out=$("$COLLECTOR" --help 2>&1) || true
contains "help mentions report-only" "$out" "report-only"
contains "help mentions offline contract" "$out" "No network"
rc=0
"$COLLECTOR" --format xml 2>"$ROOT/u.err" || rc=$?
check "bad --format exits 2" "$rc" "2"

# ---------------------------------------------------------------------------
echo
echo "=== fixture seed ==="
FIX="$ROOT/fix"
seed_fixture "$FIX"
MAIN_SHA=$(git -C "$FIX" rev-parse HEAD)
MAIN_TREE=$(git -C "$FIX" rev-parse 'HEAD^{tree}')
ok "fixture committed at $MAIN_SHA"

# ---------------------------------------------------------------------------
echo
echo "=== byte stability (frozen fixture, twice) ==="
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --format json
check "first scan exit 0" "$RC" "0"
printf '%s' "$OUT" > "$ROOT/a.json"
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --format json
check "second scan exit 0" "$RC" "0"
printf '%s' "$OUT" > "$ROOT/b.json"
if cmp -s "$ROOT/a.json" "$ROOT/b.json"; then
  ok "byte-stable JSON across two runs"
else
  bad "JSON not byte-stable"
fi

# Schema + source binding
node - "$ROOT/a.json" "$MAIN_SHA" "$MAIN_TREE" <<'NODE' && ok "schema + exact source commit/tree" || bad "schema/source binding"
const fs = require("fs");
const r = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const sha = process.argv[3];
const tree = process.argv[4];
if (r.schema !== "gibson.architecture-fitness-report.v1") throw new Error("schema");
if (r.disposition !== "report-only") throw new Error("disposition");
if (r.source.commit !== sha) throw new Error("commit " + r.source.commit);
if (r.source.tree !== tree) throw new Error("tree");
if (r.source.exact !== true) throw new Error("exact");
if (!r.collector.version || !r.collector.digest) throw new Error("collector");
if (!/^[a-f0-9]{64}$/.test(r.collector.digest)) throw new Error("digest");
NODE

# ---------------------------------------------------------------------------
echo
echo "=== large report stream completeness (>64 KiB) ==="
node - "$FIX/scripts/large-output.sh" <<'NODE'
const fs = require("fs");
const out = ["#!/usr/bin/env bash"];
for (let i = 0; i < 1800; i += 1) out.push('source "$DYNAMIC_' + i + '/thing.sh"');
fs.writeFileSync(process.argv[2], out.join("\n") + "\n");
NODE
$GIT -C "$FIX" add -A
$GIT -C "$FIX" commit -q -m "large report fixture"
LARGE_SHA=$(git -C "$FIX" rev-parse HEAD)
large_pipe_rc=0
"$COLLECTOR" --repo "$FIX" --ref "$LARGE_SHA" --no-baseline --format json |
  node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{if(Buffer.byteLength(s)<=65536)throw new Error("fixture output too small");JSON.parse(s)})' \
  || large_pipe_rc=$?
check "large piped JSON is complete" "$large_pipe_rc" "0"
large_file_rc=0
"$COLLECTOR" --repo "$FIX" --ref "$LARGE_SHA" --no-baseline --format json > "$ROOT/large-report.json" \
  || large_file_rc=$?
if [[ "$large_file_rc" -eq 0 ]] && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$ROOT/large-report.json"; then
  ok "large redirected JSON is complete"
else
  bad "large redirected JSON is truncated or invalid"
fi
seed_fixture "$FIX"
MAIN_SHA=$(git -C "$FIX" rev-parse HEAD)
MAIN_TREE=$(git -C "$FIX" rev-parse 'HEAD^{tree}')

# ---------------------------------------------------------------------------
echo
echo "=== dirty current-tree exact refusal ==="
echo dirty >> "$FIX/README.md"
run_collector "$FIX" --worktree --no-baseline --format json
check "dirty worktree exact refuse exit 3" "$RC" "3"
contains "dirty refusal message" "$(cat "$ROOT/err.txt")" "dirty worktree"
# clean up dirty state
$GIT -C "$FIX" checkout -q -- README.md
run_collector "$FIX" --worktree --no-baseline --format json
check "clean worktree exit 0" "$RC" "0"
contains "worktree is honestly non-exact" "$OUT" '"exact": false'

# ---------------------------------------------------------------------------
echo
echo "=== unresolved ref fails closed ==="
run_collector "$FIX" --ref "refs/heads/does-not-exist-ever" --no-baseline --format json
check "unresolved ref exit 3" "$RC" "3"
contains "unresolved message" "$(cat "$ROOT/err.txt")" "unresolved ref"

# ---------------------------------------------------------------------------
echo
echo "=== category classification (prod/tests/docs/config/generated/other) ==="
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --format json
printf '%s' "$OUT" > "$ROOT/class.json"
node - "$ROOT/class.json" <<'NODE' && ok "classification separates categories" || bad "classification wrong"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const c = r.classification;
function need(cat, minFiles) {
  if (!c[cat] || c[cat].files < minFiles) {
    throw new Error(cat + " files=" + (c[cat] && c[cat].files));
  }
}
need("production", 1);
need("tests", 1);
need("documentation", 1);
need("config_workflows", 1);
need("generated", 1);
need("other", 1);
// generated must not be rolled into production
if (c.generated.files < 1) throw new Error("generated empty");
if (c.tests.files < 1) throw new Error("tests empty");
// demo.test.sh is tests; claim.sh is production
NODE

# ---------------------------------------------------------------------------
echo
echo "=== safety-critical drivers + proxy labeling ==="
node - "$ROOT/class.json" <<'NODE' && ok "drivers present with proxy label" || bad "drivers/proxies"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const ids = r.safety_critical_drivers.map((d) => d.id).sort().join(",");
const want = [
  "claim","claim-reaper","gate","gate-baseline","loop-fleet",
  "loop-handoff","release-claim","release-preflight"
].sort().join(",");
if (ids !== want) throw new Error("ids " + ids);
for (const d of r.safety_critical_drivers) {
  if (!String(d.proxy_label).includes("not semantic complexity")) {
    throw new Error("proxy label missing on " + d.id);
  }
  if (typeof d.branch_proxy_count !== "number") throw new Error("branch proxy");
  if (typeof d.decision_proxy_count !== "number") throw new Error("decision proxy");
}
const claim = r.safety_critical_drivers.find((d) => d.id === "claim");
if (!claim.present || claim.lines < 5) throw new Error("claim lines");
if (claim.branch_proxy_count < 1) throw new Error("claim branch proxy");
NODE

# ---------------------------------------------------------------------------
echo
echo "=== dynamic dependency unknown (never guessed) ==="
node - "$ROOT/class.json" <<'NODE' && ok "dynamic include is unknown; static edges present" || bad "deps"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const edges = r.shell_dependencies.edges;
const unknowns = r.shell_dependencies.unknowns;
if (!unknowns.some((u) => /DYNAMIC_LIB/.test(u.raw) || u.reason.includes("dynamic"))) {
  throw new Error("missing dynamic unknown: " + JSON.stringify(unknowns));
}
// Must not invent an edge to DYNAMIC_LIB
if (edges.some((e) => /DYNAMIC/.test(e.to))) throw new Error("guessed dynamic edge");
if (edges.some((e) => /does-not-exist/.test(e.to))) throw new Error("invented missing edge");
if (!unknowns.some((u) => u.reason === "missing_static_target")) {
  throw new Error("missing static target not explicit unknown");
}
if (
  edges.some((e) => /not-executable-doc-example/.test(e.to)) ||
  unknowns.some((u) => /not-executable-doc-example/.test(u.raw))
) {
  throw new Error("heredoc documentation treated as executable include");
}
// Static edge claim.sh -> scripts/lib/claim-guards.sh
if (!edges.some((e) => e.from === "scripts/claim.sh" && e.to === "scripts/lib/claim-guards.sh")) {
  throw new Error("missing static edge: " + JSON.stringify(edges));
}
if (!edges.some((e) => e.from === "scripts/loop.sh" && e.to === "scripts/lib/compound.sh")) {
  throw new Error("missing compound-command edge: " + JSON.stringify(edges));
}
if (!String(r.shell_dependencies.note).includes("never guessed")) {
  throw new Error("deps note");
}
NODE

# ---------------------------------------------------------------------------
echo
echo "=== duplicate policy identifiers (diagnostic only) ==="
node - "$ROOT/class.json" <<'NODE' && ok "G1 duplicate across files reported" || bad "duplicates"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (!String(r.policy_identifiers.note).includes("#164")) throw new Error("note #164");
const g1 = r.policy_identifiers.duplicates.find((d) => d.id === "G1");
if (!g1 || g1.file_count < 2) throw new Error("G1 not duplicated: " + JSON.stringify(r.policy_identifiers.duplicates));
NODE

# ---------------------------------------------------------------------------
echo
echo "=== mutation categories present + missing ==="
node - "$ROOT/class.json" <<'NODE' && ok "all seven categories present in fixture" || bad "mutation present"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const cats = r.mutation_receipts.categories;
if (cats.length !== 7) throw new Error("want 7 categories, got " + cats.length);
for (const c of cats) {
  if (c.status !== "present") throw new Error(c.id + " status " + c.status);
  if (!c.locations || c.locations.length < 1) throw new Error(c.id + " no locations");
}
if (!String(r.mutation_receipts.note).includes("insufficient proof")) {
  throw new Error("mutation note");
}
NODE

# Strip mutation evidence from tests. Matching prose remains deliberately, so
# this also proves that documentation cannot create a false-positive receipt.
mkdir -p "$FIX/scripts/tests"
cat > "$FIX/scripts/tests/demo.test.sh" <<'EOF'
#!/usr/bin/env bash
# no mutation tags
echo "ordinary test"
EOF
# The collector's own fixture vocabulary must not improve its score.
{
  printf '%s\n' '# architecture-fitness-self-fixture:v1'
  cat <<'EOF'
#!/usr/bin/env bash
# mutation-category:review_bypass
# mutation-category:stale_head_acceptance
# mutation-category:halt_bypass
# mutation-category:corrupt_state_progress
# mutation-category:claim_ambiguity
# mutation-category:false_delivery_success
# mutation-category:incomplete_cleanup
EOF
} > "$FIX/scripts/tests/architecture-fitness.test.sh"
# production comments/paths that would otherwise keep categories present
cat > "$FIX/scripts/release-preflight.sh" <<'EOF'
#!/usr/bin/env bash
if true; then exit 0; fi
EOF
cat > "$FIX/scripts/loop.sh" <<'EOF'
#!/usr/bin/env bash
# loop without diagnostic markers
if true; then exit 0; fi
EOF
$GIT -C "$FIX" add -A
$GIT -C "$FIX" commit -q -m "strip mutation tags"
STRIP_SHA=$(git -C "$FIX" rev-parse HEAD)
run_collector "$FIX" --ref "$STRIP_SHA" --no-baseline --format json
printf '%s' "$OUT" > "$ROOT/missing-mut.json"
node - "$ROOT/missing-mut.json" <<'NODE' && ok "missing mutation categories reported" || bad "mutation missing"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const missing = r.mutation_receipts.categories.filter((c) => c.status === "missing");
if (missing.length < 7) {
  throw new Error(
    "expected all missing, got " +
      r.mutation_receipts.categories.map((m) => m.id + ":" + m.status).join(",")
  );
}
NODE

# A heuristic phrase in a test is a lead, not proof of a receipt.
cat > "$FIX/scripts/tests/demo.test.sh" <<'EOF'
#!/usr/bin/env bash
echo "review bypass"
EOF
$GIT -C "$FIX" add -A
$GIT -C "$FIX" commit -q -m "heuristic-only mutation phrase"
HEURISTIC_SHA=$(git -C "$FIX" rev-parse HEAD)
run_collector "$FIX" --ref "$HEURISTIC_SHA" --no-baseline --format json
printf '%s' "$OUT" > "$ROOT/heuristic-mut.json"
node - "$ROOT/heuristic-mut.json" <<'NODE' && ok "heuristic-only test match is unknown" || bad "mutation heuristic status"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const review = r.mutation_receipts.categories.find((c) => c.id === "review_bypass");
if (!review || review.status !== "unknown") throw new Error(JSON.stringify(review));
if (review.evidence !== "heuristic_test_match_only") throw new Error("evidence");
for (const c of r.mutation_receipts.categories.filter((c) => c.id !== "review_bypass")) {
  if (c.status !== "missing") throw new Error(c.id + ":" + c.status);
}
NODE
# restore tags for later cases
seed_fixture "$FIX"
MAIN_SHA=$(git -C "$FIX" rev-parse HEAD)
MAIN_TREE=$(git -C "$FIX" rev-parse 'HEAD^{tree}')

# ---------------------------------------------------------------------------
echo
echo "=== report-only regression stays exit 0 ==="
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --format json
printf '%s' "$OUT" > "$ROOT/cur.json"
write_baseline_from_report "$ROOT/cur.json" "$ROOT/base-low.json"
# Artificially lower baseline driver lines so current looks like a regression.
node - "$ROOT/base-low.json" <<'NODE'
const fs = require("fs");
const p = process.argv[2];
const b = JSON.parse(fs.readFileSync(p, "utf8"));
for (const d of b.safety_critical_drivers) {
  d.lines = 0;
  d.branch_proxy_count = 0;
  d.decision_proxy_count = 0;
}
for (const k of Object.keys(b.classification)) {
  b.classification[k].files = 0;
  b.classification[k].lines = 0;
}
fs.writeFileSync(p, JSON.stringify(b, null, 2) + "\n");
NODE
run_collector "$FIX" --ref "$MAIN_SHA" --baseline "$ROOT/base-low.json" --format json
check "report-only regression exit 0" "$RC" "0"
printf '%s' "$OUT" > "$ROOT/reg.json"
node - "$ROOT/reg.json" <<'NODE' && ok "comparison reports increases" || bad "comparison increases"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (r.baseline.path !== "<external-baseline>") throw new Error("external path disclosure");
if (!r.comparison || r.comparison.mode !== "report-only") throw new Error("mode");
if (r.comparison.summary.increases < 1) {
  throw new Error("expected increases, got " + JSON.stringify(r.comparison.summary));
}
if (!String(r.comparison.exit_policy).includes("exit 0")) throw new Error("exit policy");
NODE

# ---------------------------------------------------------------------------
echo
echo "=== malformed baseline / incomplete evidence exit nonzero ==="
echo '{not json' > "$ROOT/bad-base.json"
run_collector "$FIX" --ref "$MAIN_SHA" --baseline "$ROOT/bad-base.json" --format json
check "malformed baseline exit 3" "$RC" "3"
contains "malformed baseline message" "$(cat "$ROOT/err.txt")" "malformed baseline"

# incomplete: missing mutation categories
node - "$ROOT/cur.json" "$ROOT/incomplete.json" <<'NODE'
const fs = require("fs");
const rep = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const base = {
  schema: "gibson.architecture-fitness-baseline.v1",
  source: { commit: rep.source.commit, tree: rep.source.tree },
  classification: rep.classification,
  safety_critical_drivers: rep.safety_critical_drivers,
  mutation_receipts: { categories: [] },
};
fs.writeFileSync(process.argv[3], JSON.stringify(base) + "\n");
NODE
run_collector "$FIX" --ref "$MAIN_SHA" --baseline "$ROOT/incomplete.json" --format json
check "incomplete baseline evidence exit 3" "$RC" "3"
contains "incomplete evidence message" "$(cat "$ROOT/err.txt")" "incomplete baseline evidence"

# wrong schema
echo '{"schema":"nope","source":{"commit":"x","tree":"y"},"classification":{}}' > "$ROOT/wrong-schema.json"
run_collector "$FIX" --ref "$MAIN_SHA" --baseline "$ROOT/wrong-schema.json" --format json
check "wrong schema exit 3" "$RC" "3"

# structurally present but impossible metrics must not be trusted
cp "$ROOT/base-low.json" "$ROOT/impossible-base.json"
node - "$ROOT/impossible-base.json" <<'NODE'
const fs = require("fs");
const p = process.argv[2];
const b = JSON.parse(fs.readFileSync(p, "utf8"));
b.classification.production.lines = -1;
fs.writeFileSync(p, JSON.stringify(b) + "\n");
NODE
run_collector "$FIX" --ref "$MAIN_SHA" --baseline "$ROOT/impossible-base.json" --format json
check "impossible baseline metric exits 3" "$RC" "3"
contains "impossible metric is incomplete evidence" "$(cat "$ROOT/err.txt")" "incomplete baseline evidence"

# Cross-field and nested evidence contradictions fail closed.
for variant in source_flags source_oid driver mutation dependency policy; do
  cp "$ROOT/base-low.json" "$ROOT/contradictory-$variant.json"
  node - "$ROOT/contradictory-$variant.json" "$variant" <<'NODE'
const fs = require("fs");
const p = process.argv[2];
const variant = process.argv[3];
const b = JSON.parse(fs.readFileSync(p, "utf8"));
if (variant === "source_flags") {
  b.source.mode = "worktree"; b.source.exact = false; b.source.dirty = true;
} else if (variant === "source_oid") {
  b.source.commit = "0000000000000000000000000000000000000000";
  b.source.tree = "1111111111111111111111111111111111111111";
} else if (variant === "driver") {
  b.safety_critical_drivers[0].present = false;
  b.safety_critical_drivers[0].lines = 9;
} else if (variant === "mutation") {
  const m = b.mutation_receipts.categories[0];
  m.status = "present"; m.evidence = "none"; m.match_count = 1; m.locations = [];
} else if (variant === "dependency") {
  b.shell_dependencies.edges = [{from:"/absolute",to:null}];
} else if (variant === "policy") {
  b.policy_identifiers.duplicates = [null];
}
fs.writeFileSync(p, JSON.stringify(b) + "\n");
NODE
  run_collector "$FIX" --ref "$MAIN_SHA" --baseline "$ROOT/contradictory-$variant.json" --format json
  check "contradictory baseline $variant exits 3" "$RC" "3"
done

# The managed default is only authoritative when its bytes match the artifact
# committed at HEAD and its collector digest matches the running collector.
mkdir -p "$FIX/config"
cp "$ROOT/base-low.json" "$FIX/config/architecture-fitness-baseline.v1.json"
$GIT -C "$FIX" add config/architecture-fitness-baseline.v1.json
$GIT -C "$FIX" commit -q -m "add managed architecture baseline"
MANAGED_SHA=$(git -C "$FIX" rev-parse HEAD)
run_collector "$FIX" --ref "$MANAGED_SHA" --format json
check "committed managed baseline exits 0" "$RC" "0"
contains "managed baseline is labeled" "$OUT" '"input": "committed_default"'
printf '\n' >> "$FIX/config/architecture-fitness-baseline.v1.json"
run_collector "$FIX" --ref "$MANAGED_SHA" --format json
check "modified managed baseline exits 3" "$RC" "3"
contains "modified managed baseline fails closed" "$(cat "$ROOT/err.txt")" "must match the committed HEAD artifact"
$GIT -C "$FIX" checkout -q -- config/architecture-fitness-baseline.v1.json
node - "$FIX/config/architecture-fitness-baseline.v1.json" <<'NODE'
const fs = require("fs");
const p = process.argv[2];
const b = JSON.parse(fs.readFileSync(p, "utf8"));
b.collector.digest = "0".repeat(64);
fs.writeFileSync(p, JSON.stringify(b) + "\n");
NODE
$GIT -C "$FIX" add config/architecture-fitness-baseline.v1.json
$GIT -C "$FIX" commit -q -m "commit stale collector baseline"
STALE_COLLECTOR_SHA=$(git -C "$FIX" rev-parse HEAD)
run_collector "$FIX" --ref "$STALE_COLLECTOR_SHA" --format json
check "stale managed collector digest exits 3" "$RC" "3"
contains "stale managed collector fails closed" "$(cat "$ROOT/err.txt")" "collector digest must match"
run_collector "$FIX" --ref "$STALE_COLLECTOR_SHA" --baseline config/architecture-fitness-baseline.v1.json --format json
check "explicit historical baseline remains available" "$RC" "0"
contains "explicit baseline is labeled" "$OUT" '"input": "explicit_file"'
rm -f "$FIX/config/architecture-fitness-baseline.v1.json"
$GIT -C "$FIX" add -A
$GIT -C "$FIX" commit -q -m "remove managed baseline fixture"
MAIN_SHA=$(git -C "$FIX" rev-parse HEAD)
MAIN_TREE=$(git -C "$FIX" rev-parse 'HEAD^{tree}')

# Baseline reads do not follow a symlink leaf.
ln -s "$ROOT/base-low.json" "$ROOT/base-link.json"
run_collector "$FIX" --ref "$MAIN_SHA" --baseline "$ROOT/base-link.json" --format json
check "symlink baseline read exits 3" "$RC" "3"

# ---------------------------------------------------------------------------
echo
echo "=== no absolute temp/user paths in output ==="
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --format json
printf '%s' "$OUT" > "$ROOT/paths.json"
# Fail if common absolute path shapes appear
if printf '%s' "$OUT" | grep -E '/Users/|/home/|/private/var/folders/|/var/folders/|/tmp/|"'"$ROOT"'"' >/dev/null; then
  bad "absolute temp/user path leaked into output"
else
  ok "no absolute temp/user paths in JSON"
fi
# human mode also clean
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --format human
if printf '%s' "$OUT" | grep -E '/Users/|/home/|/private/var/folders/|/var/folders/|/tmp/' >/dev/null; then
  bad "absolute path leaked into human output"
else
  ok "no absolute paths in human output"
fi
contains "human mentions report-only" "$OUT" "report-only"
contains "human mentions proxies not complexity" "$OUT" "not semantic complexity"

# ---------------------------------------------------------------------------
echo
echo "=== emit-baseline records source + separate collector provenance ==="
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --emit-baseline "$ROOT/emitted-base.json" --format json
check "emit-baseline exit 0" "$RC" "0"
node - "$ROOT/emitted-base.json" "$MAIN_SHA" "$MAIN_TREE" <<'NODE' && ok "emitted baseline provenance truthful" || bad "emit baseline"
const b = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (b.schema !== "gibson.architecture-fitness-baseline.v1") throw new Error("schema");
if (b.source.commit !== process.argv[3]) throw new Error("commit");
if (b.source.tree !== process.argv[4]) throw new Error("tree");
if (!b.collector || !b.collector.digest) throw new Error("collector");
const note = JSON.stringify(b.notes) + JSON.stringify(b.collector);
if (!/may not have existed|did not necessarily exist|provenance/i.test(note)) {
  throw new Error("missing provenance note");
}
NODE

run_collector "$FIX" --worktree --no-baseline --emit-baseline "$ROOT/worktree-base.json" --format json
check "worktree baseline capture is refused" "$RC" "3"

# Relative emission is anchored to --repo, not the caller's working directory.
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --emit-baseline "config/relative-base.json" --format json
check "relative emit-baseline exit 0" "$RC" "0"
if [[ -f "$FIX/config/relative-base.json" ]]; then
  ok "relative emit-baseline anchored to repo"
else
  bad "relative emit-baseline wrote outside repo"
fi

# A symlink target is refused and the linked file is not changed.
echo sentinel > "$ROOT/baseline-victim.json"
ln -s "$ROOT/baseline-victim.json" "$ROOT/emitted-link.json"
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --emit-baseline "$ROOT/emitted-link.json" --format json
check "symlink emit-baseline exits 3" "$RC" "3"
check "symlink victim remains unchanged" "$(cat "$ROOT/baseline-victim.json")" "sentinel"

# ---------------------------------------------------------------------------
echo
echo "=== mutation/adversarial: neutralizing dynamic-unknown detection ==="
# Behavioral tooth: if we rewrote the collector to treat dynamic as static, a
# guessed edge would appear. We assert the live collector never invents that edge
# even when the raw text looks path-like after partial expansion.
cat > "$FIX/scripts/loop.sh" <<'EOF'
#!/usr/bin/env bash
# still dynamic
source "$(echo /tmp)/evil.sh"
source $UNSET_VAR/also-evil.sh
if true; then exit 0; fi
EOF
$GIT -C "$FIX" add -A
$GIT -C "$FIX" commit -q -m "more dynamic includes"
DYN_SHA=$(git -C "$FIX" rev-parse HEAD)
run_collector "$FIX" --ref "$DYN_SHA" --no-baseline --format json
printf '%s' "$OUT" > "$ROOT/dyn.json"
node - "$ROOT/dyn.json" <<'NODE' && ok "command-sub and unset-var includes stay unknown" || bad "dynamic adversarial"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const edges = r.shell_dependencies.edges;
const unknowns = r.shell_dependencies.unknowns;
if (edges.some((e) => /evil/.test(e.to))) throw new Error("guessed evil edge");
if (unknowns.length < 2) throw new Error("want >=2 unknowns, got " + unknowns.length);
for (const u of unknowns.filter((u) => /evil/.test(u.raw))) {
  if (u.reason !== "dynamic_or_unresolved_include") throw new Error("wrong reason " + JSON.stringify(u));
}
NODE

# Execute a neutralized dynamic-detector mutant and prove the oracle kills it.
MUTANT="$ROOT/architecture-fitness-dynamic-mutant.sh"
sed 's/if (isDynamic(raw)) {/if (false) {/' "$COLLECTOR" > "$MUTANT"
chmod +x "$MUTANT"
MUTANT_OUT=$("$MUTANT" --repo "$FIX" --ref "$DYN_SHA" --no-baseline --format json)
if printf '%s' "$MUTANT_OUT" | node -e '
let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{
  const r=JSON.parse(s); const evil=r.shell_dependencies.unknowns.filter(u=>/evil/.test(u.raw));
  if(evil.length<2 || evil.some(u=>u.reason!=="dynamic_or_unresolved_include")) process.exit(1);
})'; then
  bad "dynamic-detector mutant survived the oracle"
else
  ok "dynamic-detector mutant is killed"
fi

# ---------------------------------------------------------------------------
echo
echo "=== category misclassification sensor (generated vs production) ==="
# If dist/ were counted as production, generated.files would be 0 and production inflated.
seed_fixture "$FIX"
MAIN_SHA=$(git -C "$FIX" rev-parse HEAD)
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --format json
printf '%s' "$OUT" > "$ROOT/misclass.json"
node - "$ROOT/misclass.json" <<'NODE' && ok "dist/bundle.min.js is generated not production" || bad "misclassification"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (r.classification.generated.files < 1) throw new Error("generated files");
// production should include scripts but the single generated file must not vanish into other
const total =
  r.classification.generated.files +
  r.classification.tests.files +
  r.classification.documentation.files +
  r.classification.config_workflows.files +
  r.classification.production.files +
  r.classification.other.files;
// tracked count coherence: sum categories equals path inventory size from source
if (total < 10) throw new Error("too few classified files " + total);
NODE

# ---------------------------------------------------------------------------
echo
echo "=== human mode + JSON schema disposition explicit ==="
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --format human
contains "human disposition report-only" "$OUT" "disposition: report-only"
contains "human #164 note" "$OUT" "#164"

# ---------------------------------------------------------------------------
# #198 — marker exclusion, path refusal, sanitized emit failures, counted mutants
# ---------------------------------------------------------------------------
copy_collector_once() {
  local dest="$1" old="$2" new="$3"
  node - "$COLLECTOR" "$dest" "$old" "$new" <<'NODE'
const fs = require("fs");
const [src, dest, oldS, newS] = process.argv.slice(2);
const text = fs.readFileSync(src, "utf8");
let n = 0;
let i = 0;
while ((i = text.indexOf(oldS, i)) !== -1) { n += 1; i += oldS.length; }
if (n !== 1) {
  process.stderr.write("replacement matched " + n + "\n");
  process.exit(2);
}
fs.writeFileSync(dest, text.replace(oldS, newS));
fs.chmodSync(dest, 0o755);
NODE
}

run_bin() {
  local bin="$1" repo="$2"
  shift 2
  OUT=$("$bin" --repo "$repo" "$@" 2>"$ROOT/err.txt")
  RC=$?
}

assert_sanitized() {
  local label="$1" line="$2" target="$3" parent="$4" expect_clean="$5"
  check "$label exit 3" "$RC" "3"
  local err staged_left left
  err=$(cat "$ROOT/err.txt")
  check "$label stderr" "$err" "architecture-fitness.sh: $line"
  check "$label stdout empty" "$OUT" ""
  if printf '%s' "$err" | grep -E '/|Error:|^[[:space:]]*at ' >/dev/null; then
    bad "$label stderr leaked a path or stack"
  else
    ok "$label stderr has no path or stack"
  fi
  check "$label target unchanged" "$(cat "$target")" "SENTINEL-OUTPUT"
  staged_left=$(find "$parent" -name '*.staged' -print)
  check "$label staged file removed" "$staged_left" ""
  if [[ "$expect_clean" == "clean" ]]; then
    left=$(find "$parent" -name '.architecture-fitness-*' -print)
    check "$label temporary files removed" "$left" ""
  else
    left=$(find "$parent" -name '.architecture-fitness-*' -print)
    if [[ -n "$left" ]]; then
      ok "$label leaves the temporary directory when removal fails"
    else
      bad "$label removed the temporary directory despite a cleanup failure"
    fi
  fi
}

prepare_emit() {
  local parent="$1"
  rm -rf "$parent"
  mkdir -p "$parent"
  printf '%s\n' 'SENTINEL-OUTPUT' > "$parent/baseline.json"
}

inject_throw='(function () { const err = new Error("injected"); err.code = "EACCES"; throw err; })()'

echo
echo "=== #198 self-fixture marker ==="
MARK="$ROOT/marker-repo"
rm -rf "$MARK"
mkdir -p "$MARK/scripts/tests"
$GIT init -q "$MARK"
git -C "$MARK" symbolic-ref HEAD refs/heads/main
printf '%s\n' '#!/usr/bin/env bash' 'if true; then exit 0; fi' > "$MARK/scripts/claim.sh"
{
  printf '%s\n' '# architecture-fitness-self-fixture:v1'
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'ok "mutation-category:review_bypass receipt"'
} > "$MARK/scripts/tests/renamed-self.test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'ok "mutation-category:halt_bypass receipt"' > "$MARK/scripts/tests/live.test.sh"
$GIT -C "$MARK" add -A
$GIT -C "$MARK" commit -q -m "renamed self fixture"
MARK_SHA=$(git -C "$MARK" rev-parse HEAD)
run_collector "$MARK" --ref "$MARK_SHA" --no-baseline --format json
check "renamed marked fixture scans" "$RC" "0"
printf '%s' "$OUT" > "$ROOT/renamed.json"
node - "$ROOT/renamed.json" <<'NODE' && ok "renamed marker excludes; unmarked assertion counts" || bad "self-fixture exclusion"
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const review = r.mutation_receipts.categories.find((c) => c.id === "review_bypass");
const halt = r.mutation_receipts.categories.find((c) => c.id === "halt_bypass");
if (!review || review.status !== "missing") throw new Error("review " + JSON.stringify(review));
if (!halt || halt.status !== "present") throw new Error("halt " + JSON.stringify(halt));
if (!halt.locations.some((l) => l.indexOf("scripts/tests/live.test.sh:") === 0)) {
  throw new Error("halt locations " + JSON.stringify(halt.locations));
}
if (review.locations.some((l) => l.indexOf("renamed-self") !== -1)) throw new Error("renamed counted");
NODE

if copy_collector_once "$ROOT/predicate-mutant.sh" 'isSelfFixtureFile(f)' 'false'; then
  ok "predicate replacement matched once"
else
  bad "predicate replacement was not unique"
fi
run_bin "$ROOT/predicate-mutant.sh" "$MARK" --ref "$MARK_SHA" --no-baseline --format json
printf '%s' "$OUT" > "$ROOT/predicate-mutant.json"
if [[ "$RC" -eq 0 ]] && node - "$ROOT/predicate-mutant.json" <<'NODE'
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const review = r.mutation_receipts.categories.find((c) => c.id === "review_bypass");
if (!review || review.status !== "present") process.exit(1);
if (!review.locations.some((l) => l.indexOf("scripts/tests/renamed-self.test.sh:") === 0)) process.exit(1);
NODE
then
  ok "deleting the self-fixture predicate is killed"
else
  bad "self-fixture predicate mutant survived"
fi

DUP="$ROOT/dup-repo"
rm -rf "$DUP"
mkdir -p "$DUP/scripts/tests"
$GIT init -q "$DUP"
git -C "$DUP" symbolic-ref HEAD refs/heads/main
printf '%s\n' 'plain' > "$DUP/README.md"
printf '%s\n' '# architecture-fitness-self-fixture:v1' > "$DUP/scripts/tests/a.test.sh"
printf '%s\n' '# architecture-fitness-self-fixture:v1' > "$DUP/scripts/tests/b.test.sh"
$GIT -C "$DUP" add -A
$GIT -C "$DUP" commit -q -m "duplicate markers"
DUP_SHA=$(git -C "$DUP" rev-parse HEAD)
run_collector "$DUP" --ref "$DUP_SHA" --no-baseline --format json
check "duplicate markers exit 3" "$RC" "3"
contains "duplicate marker message" "$(cat "$ROOT/err.txt")" "duplicate architecture-fitness self-fixture markers"
check "duplicate markers write no stdout" "$OUT" ""

ZERO="$ROOT/zero-repo"
rm -rf "$ZERO"
mkdir -p "$ZERO"
$GIT init -q "$ZERO"
git -C "$ZERO" symbolic-ref HEAD refs/heads/main
printf '%s\n' 'plain' > "$ZERO/README.md"
$GIT -C "$ZERO" add -A
$GIT -C "$ZERO" commit -q -m "no marker"
ZERO_SHA=$(git -C "$ZERO" rev-parse HEAD)
run_collector "$ZERO" --ref "$ZERO_SHA" --no-baseline --format json
check "missing marker exits 3" "$RC" "3"
contains "missing marker message" "$(cat "$ROOT/err.txt")" "exactly one architecture-fitness self-fixture marker"

run_collector "$ZERO" --worktree --no-baseline --format json
check "worktree missing marker exits 3" "$RC" "3"
contains "worktree missing marker message" "$(cat "$ROOT/err.txt")" "exactly one architecture-fitness self-fixture marker"

echo
echo "=== #198 legacy self-fixture pair is exact ==="
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
common=$(git -C "$REPO_ROOT" rev-parse --git-common-dir)
case "$common" in
  /*) ;;
  *) common="$REPO_ROOT/$common" ;;
esac
VIEW="$ROOT/legacy-view"
rm -rf "$VIEW"
mkdir -p "$VIEW"
$GIT init -q "$VIEW"
mkdir -p "$VIEW/.git/objects/info"
printf '%s\n' "$common/objects" > "$VIEW/.git/objects/info/alternates"
LEGACY_COMMIT=01bafdeecadb28ecee7415cd1b2ef57c58b7c4bc
LEGACY_TREE=41fcceeb0d8e8d6d46d426e595e1190cad8d2599
run_collector "$VIEW" --ref "$LEGACY_COMMIT" --no-baseline --format json
check "legacy pair with zero markers exits 0" "$RC" "0"
SAME_COMMIT=$($GIT -C "$VIEW" commit-tree "$LEGACY_TREE" -m "same tree different commit")
run_collector "$VIEW" --ref "$SAME_COMMIT" --no-baseline --format json
check "same tree different commit exits 3" "$RC" "3"
contains "same tree is not the legacy pair" "$(cat "$ROOT/err.txt")" "exactly one architecture-fitness self-fixture marker"
if copy_collector_once "$ROOT/tree-only-mutant.sh" \
  'return commit === LEGACY_SELF_FIXTURE_COMMIT && tree === LEGACY_SELF_FIXTURE_TREE;' \
  'return tree === LEGACY_SELF_FIXTURE_TREE;'; then
  ok "legacy-pair replacement matched once"
else
  bad "legacy-pair replacement was not unique"
fi
run_bin "$ROOT/tree-only-mutant.sh" "$VIEW" --ref "$SAME_COMMIT" --no-baseline --format json
check "tree-only exception mutant is killed" "$RC" "0"

DESC="$ROOT/desc-view"
rm -rf "$DESC"
mkdir -p "$DESC"
$GIT init -q "$DESC"
mkdir -p "$DESC/.git/objects/info"
printf '%s\n' "$common/objects" > "$DESC/.git/objects/info/alternates"
$GIT -C "$DESC" checkout -q --detach 96ac60c89e1c1ae2a90f460dbfadaf54724b0d3f
$GIT -C "$DESC" rm -q -- scripts/architecture-fitness.sh
$GIT -C "$DESC" commit -q -m "delete architecture-fitness collector"
DESC_SHA=$(git -C "$DESC" rev-parse HEAD)
run_collector "$DESC" --ref "$DESC_SHA" --no-baseline --format json
check "descendant that deletes the collector exits 3" "$RC" "3"
contains "descendant is not the legacy pair" "$(cat "$ROOT/err.txt")" "exactly one architecture-fitness self-fixture marker"
lacks "descendant stderr is not the legacy-zero message" "$(cat "$ROOT/err.txt")" "legacy architecture-fitness source must contain zero"

echo
echo "=== #198 literal backslash git paths ==="
BS="$ROOT/backslash-repo"
rm -rf "$BS"
mkdir -p "$BS/scripts/a" "$BS/scripts/tests"
$GIT init -q "$BS"
git -C "$BS" symbolic-ref HEAD refs/heads/main
printf '%s\n' '#!/usr/bin/env bash' 'source "$SCRIPT_DIR/slash-only.sh"' > "$BS/scripts/a/b.sh"
printf '%s\n' '#!/usr/bin/env bash' 'source "$SCRIPT_DIR/backslash-only.sh"' > "$BS/scripts/a\\b.sh"
printf '%s\n' '#!/usr/bin/env bash' 'if true; then exit 0; fi' > "$BS/scripts/claim.sh"
printf '%s\n' '# architecture-fitness-self-fixture:v1' > "$BS/scripts/tests/architecture-fitness.test.sh"
$GIT -C "$BS" add -A
$GIT -C "$BS" commit -q -m "backslash sibling"
BS_SHA=$(git -C "$BS" rev-parse HEAD)
run_collector "$BS" --ref "$BS_SHA" --no-baseline --format json
check "commit-mode backslash exits 3" "$RC" "3"
contains "commit-mode backslash message" "$(cat "$ROOT/err.txt")" "literal backslash rejected"
check "commit-mode backslash writes no stdout" "$OUT" ""
lacks "commit-mode does not emit slash sibling" "$OUT" "slash-only.sh"
lacks "commit-mode does not emit backslash target" "$OUT" "backslash-only.sh"
run_collector "$BS" --worktree --no-baseline --format json
check "worktree-mode backslash exits 3" "$RC" "3"
contains "worktree-mode backslash message" "$(cat "$ROOT/err.txt")" "literal backslash rejected"
check "worktree-mode backslash writes no stdout" "$OUT" ""
if copy_collector_once "$ROOT/backslash-mutant.sh" 'p.includes("\\")' 'p.includes("NEVER-BACKSLASH")'; then
  ok "backslash replacement matched once"
else
  bad "backslash replacement was not unique"
fi
run_bin "$ROOT/backslash-mutant.sh" "$BS" --ref "$BS_SHA" --no-baseline --format json
printf '%s' "$OUT" > "$ROOT/backslash-mutant.json"
if [[ "$RC" -eq 0 ]] && node - "$ROOT/backslash-mutant.json" <<'NODE'
const r = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const unknowns = r.shell_dependencies.unknowns;
const slash = unknowns.filter((u) => u.raw === "$SCRIPT_DIR/slash-only.sh" && u.from === "scripts/a/b.sh");
const back = unknowns.filter((u) => u.raw === "$SCRIPT_DIR/backslash-only.sh" && u.from === "scripts/a\\b.sh");
if (slash.length !== 1 || back.length !== 1) {
  process.stderr.write("slash=" + slash.length + " back=" + back.length + "\n");
  process.exit(1);
}
NODE
then
  ok "deleting the backslash rejection admits both names without substitution"
else
  bad "backslash mutant did not prove distinct reads"
fi

echo
echo "=== #198 hand-built unsafe git tree ==="
UNSAFE="$ROOT/unsafe-repo"
rm -rf "$UNSAFE"
mkdir -p "$UNSAFE"
$GIT init -q "$UNSAFE"
UNSAFE_COMMIT=$(node - "$UNSAFE" <<'NODE'
const { execFileSync } = require("child_process");
const repo = process.argv[2];
const gitBase = ["-c", "user.email=sensor@gibson.invalid", "-c", "user.name=gibson-sensor", "-c", "commit.gpgsign=false", "-C", repo];
function git(args, opts) {
  return execFileSync("git", gitBase.concat(args), Object.assign({ encoding: "utf8" }, opts || {}));
}
function blob(text) {
  return git(["hash-object", "-w", "--stdin"], { input: text }).trim();
}
function tree(entries) {
  const parts = [];
  const sorted = entries.slice().sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (const e of sorted) {
    parts.push(Buffer.from(e.mode + " " + e.name + "\0", "utf8"));
    parts.push(Buffer.from(e.sha, "hex"));
  }
  return git(["hash-object", "--literally", "-t", "tree", "-w", "--stdin"], { input: Buffer.concat(parts) }).trim();
}
const secret = blob("SENTINEL-DOTDOT\n");
const claim = blob("#!/usr/bin/env bash\nif true; then exit 0; fi\n");
const marker = blob("# architecture-fitness-self-fixture:v1\n");
const tests = tree([{ mode: "100644", name: "architecture-fitness.test.sh", sha: marker }]);
const scriptsWithTests = tree([
  { mode: "100644", name: "claim.sh", sha: claim },
  { mode: "100644", name: "..", sha: secret },
  { mode: "40000", name: "tests", sha: tests },
]);
const root = tree([{ mode: "40000", name: "scripts", sha: scriptsWithTests }]);
process.stdout.write(git(["commit-tree", root, "-m", "hostile dotdot"]).trim());
NODE
)
run_collector "$UNSAFE" --ref "$UNSAFE_COMMIT" --no-baseline --format json
check "unsafe tree exits 3" "$RC" "3"
contains "unsafe tree message" "$(cat "$ROOT/err.txt")" "unsafe path in tree: rejected"
check "unsafe tree writes no stdout" "$OUT" ""
lacks "unsafe tree does not emit sentinel" "$OUT" "SENTINEL-DOTDOT"
if copy_collector_once "$ROOT/unsafe-mutant.sh" \
  'p.split("/").some((c) => c === ".." || c === "")' \
  'p.split("/").some((c) => false)'; then
  ok "unsafe-tree replacement matched once"
else
  bad "unsafe-tree replacement was not unique"
fi
run_bin "$ROOT/unsafe-mutant.sh" "$UNSAFE" --ref "$UNSAFE_COMMIT" --no-baseline --format json
check "deleting the unsafe-tree rejection is killed" "$RC" "0"
lacks "unsafe mutant stderr is not the path rejection" "$(cat "$ROOT/err.txt")" "unsafe path in tree: rejected"

echo
echo "=== #198 absolute-path canary matrix ==="
for prefix in /tmp /var/folders /private/var/folders /Users /home; do
  CAN="$ROOT/canary-$(printf '%s' "$prefix" | tr '/' '-')"
  rm -rf "$CAN"
  mkdir -p "$CAN/scripts/tests"
  $GIT init -q "$CAN"
  git -C "$CAN" symbolic-ref HEAD refs/heads/main
  printf '%s\n' '#!/usr/bin/env bash' "source ${prefix}/archfit-canary" 'if true; then exit 0; fi' > "$CAN/scripts/claim.sh"
  printf '%s\n' '# architecture-fitness-self-fixture:v1' > "$CAN/scripts/tests/architecture-fitness.test.sh"
  $GIT -C "$CAN" add -A
  $GIT -C "$CAN" commit -q -m "canary $prefix"
  CAN_SHA=$(git -C "$CAN" rev-parse HEAD)
  run_collector "$CAN" --ref "$CAN_SHA" --no-baseline --format json
  check "canary $prefix exits 3" "$RC" "3"
  contains "canary $prefix message" "$(cat "$ROOT/err.txt")" "absolute user/temp paths"
  check "canary $prefix writes no stdout" "$OUT" ""
  lacks "canary $prefix not in stdout" "$OUT" "${prefix}/archfit-canary"
done
if copy_collector_once "$ROOT/leak-mutant.sh" \
  '/\/Users\/|\/home\/|\/private\/var\/folders\/|\/var\/folders\/|\/tmp\//i.test(json)' \
  'false'; then
  ok "absolute-path replacement matched once"
else
  bad "absolute-path replacement was not unique"
fi
run_bin "$ROOT/leak-mutant.sh" "$ROOT/canary--tmp" --ref "$(git -C "$ROOT/canary--tmp" rev-parse HEAD)" --no-baseline --format json
check "deleting the absolute-path rejection is killed" "$RC" "0"
contains "leak mutant emits the /tmp canary" "$OUT" "/tmp/archfit-canary"

echo
echo "=== #198 sanitized baseline emit failures ==="
seed_fixture "$FIX"
EMIT_SHA=$(git -C "$FIX" rev-parse HEAD)
EMIT_PARENT="$ROOT/emit-parent"
prepare_emit "$EMIT_PARENT"
run_collector "$FIX" --ref "$EMIT_SHA" --no-baseline --emit-baseline "$EMIT_PARENT/baseline.json" --format json
check "sanitized emit still writes" "$RC" "0"
node - "$EMIT_PARENT/baseline.json" <<'NODE' && ok "successful emit writes collector 1.0.1" || bad "successful emit baseline"
const b = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (b.collector.version !== "1.0.1") throw new Error(String(b.collector && b.collector.version));
if (!/^[0-9a-f]{64}$/.test(b.collector.digest || "")) throw new Error("digest");
NODE

# Confirm the sentinel is gone and no temp remains.
if [[ "$(cat "$EMIT_PARENT/baseline.json")" != "SENTINEL-OUTPUT" ]]; then
  ok "successful emit replaces the previous output"
else
  bad "successful emit left the sentinel in place"
fi
success_left=$(find "$EMIT_PARENT" -name '.architecture-fitness-*' -print)
check "successful emit removes temporary files" "$success_left" ""

inject_case() {
  local name="$1" old="$2" new="$3" line="$4" clean="$5"
  local parent="$ROOT/emit-$name"
  local mutant="$ROOT/emit-mutant-$name.sh"
  prepare_emit "$parent"
  if copy_collector_once "$mutant" "$old" "$new"; then
    ok "$name replacement matched once"
  else
    bad "$name replacement was not unique"
    return
  fi
  run_bin "$mutant" "$FIX" --ref "$EMIT_SHA" --no-baseline --emit-baseline "$parent/baseline.json" --format json
  assert_sanitized "$name" "$line" "$parent/baseline.json" "$parent" "$clean"
}

inject_case parent-lstat \
  'fs.lstatSync(requestedParent)' \
  "$inject_throw" \
  "unsafe baseline output path: cannot stat parent" \
  clean
inject_case parent-realpath \
  'fs.realpathSync(requestedParent)' \
  "$inject_throw" \
  "unsafe baseline output path: cannot resolve parent" \
  clean
inject_case leaf-lstat \
  'fs.lstatSync(outPath)' \
  "$inject_throw" \
  "unsafe baseline output path: cannot stat output" \
  clean
inject_case mkdtemp \
  'fs.mkdtempSync(path.join(realParent, ".architecture-fitness-"))' \
  "$inject_throw" \
  "cannot create baseline temporary directory" \
  clean
inject_case temp-write \
  'fs.writeFileSync(tmp, stableStringify(baselineDoc), {' \
  "$inject_throw(); fs.writeFileSync(tmp, stableStringify(baselineDoc), {" \
  "cannot write baseline temporary file" \
  clean
inject_case atomic-rename \
  'fs.renameSync(staged, outPath)' \
  "$inject_throw" \
  "cannot rename baseline into place" \
  clean
inject_case cleanup \
  'fs.rmdirSync(tempDir)' \
  "$inject_throw" \
  "cannot remove baseline temporary directory" \
  dirty

LONG_PARENT="$ROOT/emit-long"
prepare_emit "$LONG_PARENT"
LONG_LEAF=$(node -e 'process.stdout.write("x".repeat(300) + ".json")')
run_collector "$FIX" --ref "$EMIT_SHA" --no-baseline --emit-baseline "$LONG_PARENT/$LONG_LEAF" --format json
check "non-ENOENT leaf lstat exits 3" "$RC" "3"
check "non-ENOENT leaf stderr" "$(cat "$ROOT/err.txt")" "architecture-fitness.sh: unsafe baseline output path: cannot stat output"
check "non-ENOENT leaf stdout empty" "$OUT" ""
check "non-ENOENT leaf leaves the sibling sentinel" "$(cat "$LONG_PARENT/baseline.json")" "SENTINEL-OUTPUT"
if printf '%s' "$(cat "$ROOT/err.txt")" | grep -E '/|Error:|^[[:space:]]*at ' >/dev/null; then
  bad "non-ENOENT leaf stderr leaked a path or stack"
else
  ok "non-ENOENT leaf stderr has no path or stack"
fi
long_left=$(find "$LONG_PARENT" -name '.architecture-fitness-*' -print)
check "non-ENOENT leaf creates no temporary directory" "$long_left" ""

# ---------------------------------------------------------------------------
echo
echo "architecture-fitness.test.sh: $PASS passed, $FAIL failed"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
