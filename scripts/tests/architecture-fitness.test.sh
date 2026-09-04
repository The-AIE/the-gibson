#!/usr/bin/env bash
# architecture-fitness.test.sh — sensors for scripts/architecture-fitness.sh (#184)
#
# Temporary fixture repositories only. Deterministic. No network.
# Parent-shell PASS/FAIL accounting — no false-green subshell counters.
#
# USAGE
#   scripts/tests/architecture-fitness.test.sh
set -uo pipefail

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
cat > "$FIX/scripts/tests/architecture-fitness.test.sh" <<'EOF'
#!/usr/bin/env bash
# mutation-category:review_bypass
# mutation-category:stale_head_acceptance
# mutation-category:halt_bypass
# mutation-category:corrupt_state_progress
# mutation-category:claim_ambiguity
# mutation-category:false_delivery_success
# mutation-category:incomplete_cleanup
EOF
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
if printf '%s' "$OUT" | grep -E '/Users/|/home/|/private/var/folders/|/tmp/gibson-|"'"$ROOT"'"' >/dev/null; then
  bad "absolute temp/user path leaked into output"
else
  ok "no absolute temp/user paths in JSON"
fi
# human mode also clean
run_collector "$FIX" --ref "$MAIN_SHA" --no-baseline --format human
if printf '%s' "$OUT" | grep -E '/Users/|/home/|/private/var/folders/|/tmp/gibson-' >/dev/null; then
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
echo
echo "architecture-fitness.test.sh: $PASS passed, $FAIL failed"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
exit 0
