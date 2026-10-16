#!/usr/bin/env bash
# delivery-receipt.test.sh — #160 R1 report-only receipt.
# No network. Every claimed rule has a RED fixture. Mutations run on a temp
# copy of the verifier; the original file's sha256 must be unchanged at the end.
set -uo pipefail
export GIBSON_AGENT_VENDOR="${GIBSON_AGENT_VENDOR:-claude}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
EVAL="$REPO_ROOT/scripts/delivery-receipt.mjs"
FIX="$SCRIPT_DIR/fixtures/delivery-receipt"
SCHEMA="$REPO_ROOT/config/policy/schema/delivery-receipt-v1.schema.json"

PASS=0
FAIL=0
ok() { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
command -v node >/dev/null || { echo "delivery-receipt.test.sh: node required"; exit 1; }
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-delivery.XXXXXX")
trap 'rm -rf "$ROOT" ${CASES:+"$CASES"}' EXIT
CASES_JS="$SCRIPT_DIR/delivery-receipt-cases.mjs"
CASES=$(node "$CASES_JS") || {
  echo "delivery-receipt.test.sh: could not materialize cases"
  exit 1
}
[ -d "$CASES" ] || { echo "delivery-receipt.test.sh: case dir missing"; exit 1; }

# 0 = failed closed with case, op, and path. 1 = applied. 2 = failed some other way.
probe_mat() {
  local module="$1" name="$2" ops="$3" expect="$4"
  local err="$ROOT/$name.mat.err" out="$ROOT/$name.mat.out"
  node --input-type=module - "$module" "$FIX/delivered-tier-c.json" "$name" "$ops" >"$out" 2>"$err" <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const [modulePath, basePath, name, opsJson] = process.argv.slice(2);
const { materialize } = await import(pathToFileURL(modulePath).href);
const base = JSON.parse(readFileSync(basePath, "utf8"));
try {
  materialize(base, { [name]: JSON.parse(opsJson) });
} catch (err) {
  process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
}
JS
  if [ "$?" -eq 0 ]; then
    return 1
  fi
  if grep -F -q -- "$expect" "$err"; then
    return 0
  fi
  return 2
}

run_closed_table() {
  local module="$1" want="$2"
  local name op path ops expect rc
  while IFS='|' read -r name op path ops; do
    [ -n "${name:-}" ] || continue
    expect="$name: $op $path"
    probe_mat "$module" "$name" "$ops" "$expect"
    rc=$?
    if [ "$want" = "closed" ]; then
      if [ "$rc" -eq 0 ]; then
        ok "$name fails materialization"
      else
        bad "$name: materialization did not fail closed (rc=$rc) $(cat "$ROOT/$name.mat.err" 2>/dev/null)"
      fi
    elif [ "$rc" -eq 1 ]; then
      ok "mutation $name self-test went red"
    else
      bad "mutation $name stayed green (rc=$rc)"
    fi
  done <<'EOF'
bad-remove-index|remove|/inputs/reviews/99|[{"op":"remove","path":"/inputs/reviews/99"}]
bad-replace-key|replace|/inputs/reviews/missing|[{"op":"replace","path":"/inputs/reviews/missing","value":1}]
bad-intermediate|replace|/inputs/missing-parent/child|[{"op":"replace","path":"/inputs/missing-parent/child","value":1}]
bad-unknown-op|move|/inputs/reviews/0|[{"op":"move","path":"/inputs/reviews/0","from":"/inputs/pull"}]
EOF
}

echo "# patch materializer fails closed"
node -e '
  const fs = require("fs");
  const overlays = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const dir = process.argv[2];
  const names = Object.keys(overlays).filter((k) => !k.startsWith("_"));
  if (names.length === 0) process.exit(1);
  for (const name of names) {
    const file = dir + "/" + name + ".json";
    if (!fs.existsSync(file)) {
      process.stderr.write("missing " + name + "\n");
      process.exit(1);
    }
    JSON.parse(fs.readFileSync(file, "utf8"));
  }
' "$FIX/overlays.json" "$CASES" \
  && ok "every committed overlay applies cleanly" \
  || bad "a committed overlay did not apply"
run_closed_table "$CASES_JS" closed

echo "# mutation: silent applyOps makes the closed self-tests red"
SILENT="$ROOT/silent-cases/delivery-receipt-cases.mjs"
mkdir -p "$ROOT/silent-cases"
sed "/MUTATION_ANCHOR_PATCH_CLOSED/d" "$CASES_JS" >"$SILENT"
if node --check "$SILENT"; then
  run_closed_table "$SILENT" open
else
  bad "silent applyOps mutant does not parse"
fi

ORIG_SHA=$(shasum -a 256 "$EVAL" | awk 'NR==1 { print $1 }')

fields() {
  node "$EVAL" project --bundle "$1" >"$ROOT/proj.json" 2>"$ROOT/proj.err"
  node -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const row = [
      j.disposition,
      (j.reasons || []).join(","),
      j.tier,
      String(j.g12.applies),
      String(j.g12.met),
      j.cost.status,
      j.review.verdict,
      j.review.independenceLevel,
      j.actors.builder.vendor,
      j.actors.reviewer.vendor,
      j.deployment.status,
      j.cleanup.status,
      j.lessons.status,
      j.policyManifestDigest,
      j.authority,
    ];
    process.stdout.write(row.join("\t"));
  ' "$ROOT/proj.json"
}

expect_row() {
  local name="$1" file="$2" want="$3"
  local got
  got=$(fields "$CASES/$file") || { bad "$name: project failed"; return; }
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name: want [$want] got [$got]"; fi
}

echo "# projection rules"
expect_row "tier C E3 delivered, cost and deploy unknown" delivered-tier-c.json \
  "delivered		C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "unknown cost and deploy still delivered" unknown-cost-deploy.json \
  "delivered		C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "stale reviewed head is not delivered" stale-reviewed-head.json \
  "incomplete	review-not-approve,head-mismatch,vendor-unknown,g12-not-met,not-e3	C	true	false	unknown	NONE	unknown	grok	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "same-vendor review is not E3" same-vendor.json \
  "incomplete	vendor-not-independent,g12-not-met,not-e3	C	true	false	unknown	APPROVE	E1	grok	grok	unknown	unknown	unknown	unknown	report-only"
expect_row "check name from a different app id does not match" app-id-mismatch.json \
  "incomplete	required-check-unmatched,g12-not-met	C	true	false	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "missing required check" missing-required-check.json \
  "incomplete	required-check-unmatched,g12-not-met	C	true	false	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "tier C with no review is not E3" tier-c-without-e3.json \
  "incomplete	review-not-approve,head-mismatch,vendor-unknown,g12-not-met,not-e3	C	true	false	unknown	NONE	E0	grok	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "forged Agent-Vendor on an unverified stranger commit" forged-trailer-unverified.json \
  "incomplete	review-not-approve,head-mismatch,vendor-unknown,g12-not-met,not-e3	C	true	false	unknown	NONE	unknown	unknown	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "forged trailer does not re-vendor a lane bot" forged-trailer-on-lane-bot.json \
  "incomplete	vendor-not-independent,g12-not-met,not-e3	C	true	false	unknown	APPROVE	E1	grok	grok	unknown	unknown	unknown	unknown	report-only"
expect_row "lane-bot login absent from identities" unlisted-lane-bot.json \
  "incomplete	review-not-approve,head-mismatch,vendor-unknown,g12-not-met,not-e3	C	true	false	unknown	NONE	unknown	unknown	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "unreadable required-check set is unknown" required-checks-unreadable.json \
  "incomplete	required-checks-unknown,g12-not-met	C	true	unknown	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "newer dismissal beats an older approval" dismissed-newer-review.json \
  "incomplete	review-not-approve,head-mismatch,vendor-unknown,g12-not-met,not-e3	C	true	false	unknown	NONE	E0	grok	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "newer approval beats an older dismissal" approve-after-dismiss.json \
  "delivered		C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "edited review-evidence comment is not a receipt" edited-review-comment.json \
  "incomplete	review-not-approve,head-mismatch,vendor-unknown,g12-not-met,not-e3	C	true	false	unknown	NONE	E0	grok	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "base retarget after review" base-retarget.json \
  "incomplete	review-not-approve,head-mismatch,vendor-unknown,g12-not-met,not-e3	C	true	false	unknown	NONE	unknown	grok	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "head shared by two open pull requests" shared-head.json \
  "parked	open	C	true	false	unknown	NONE	unknown	grok	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "two ambiguous cost rows are unknown and do not block delivered" ambiguous-cost.json \
  "delivered		C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "one ledger row joins and does not invent usd" joined-cost.json \
  "delivered		C	true	true	joined	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "non-default base is never delivered" non-default-base.json \
  "incomplete	non-default-base	C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "pagination not exhausted" pagination-not-exhausted.json \
  "incomplete	pagination-not-exhausted	C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "omitted pulls-for-head source with an empty listing is not delivered" omitted-pulls-for-head.json \
  "incomplete	review-not-approve,head-mismatch,vendor-unknown,g12-not-met,pagination-not-exhausted,not-e3	C	true	false	unknown	NONE	unknown	grok	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "fabricated single source is not delivered" fabricated-single-source.json \
  "incomplete	review-not-approve,head-mismatch,vendor-unknown,g12-not-met,pagination-not-exhausted,not-e3	C	true	false	unknown	NONE	unknown	grok	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "duplicate source is not delivered" duplicate-source.json \
  "incomplete	pagination-not-exhausted	C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "unvendored owner is unknown even with an independent reviewer" unvendored-owner.json \
  "incomplete	vendor-unknown	C	true	true	unknown	APPROVE	E3	unknown	independent	unknown	unknown	unknown	unknown	report-only"
expect_row "missing tier label assumes Tier C and can still deliver" tier-unknown-missing.json \
  "delivered		unknown	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "multiple tier labels assume Tier C" tier-unknown-multiple.json \
  "delivered		unknown	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "unknown tier still requires E3" tier-unknown-same-vendor.json \
  "incomplete	vendor-not-independent,g12-not-met,not-e3	unknown	true	false	unknown	APPROVE	E1	grok	grok	unknown	unknown	unknown	unknown	report-only"
expect_row "closed unmerged is failed" closed-unmerged.json \
  "failed	closed-unmerged	C	true	false	unknown	NONE	unknown	grok	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "open pull request with a pass is parked" open-parked.json \
  "parked	open	C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "open pull request with a failed check is blocked" open-blocked-check.json \
  "blocked	required-check-failed	C	true	false	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "open pull request with changes requested is blocked" open-blocked-review.json \
  "blocked	review-fail	C	true	false	unknown	CHANGES_REQUESTED	unknown	grok	unknown	unknown	unknown	unknown	unknown	report-only"
expect_row "tier A delivered and G12 does not apply" tier-a-delivered.json \
  "delivered		A	false	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "required check with no app slug" check-no-app-slug.json \
  "incomplete	required-check-no-app-slug,g12-not-met	C	true	false	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "unknown comment editors" comment-editors-unknown.json \
  "incomplete	comment-editors-unknown	C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "merged flag on an open pull request is contradictory" contradictory-state.json \
  "incomplete	contradictory	C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "two matching check runs are ambiguous" duplicate-check-run.json \
  "incomplete	required-check-unmatched,g12-not-met	C	true	false	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "required check that is not success" check-not-success.json \
  "incomplete	required-check-not-success,g12-not-met	C	true	false	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "attested codex review of a grok head is E3" attested-codex.json \
  "delivered		C	true	true	unknown	APPROVE	E3	grok	codex	unknown	unknown	unknown	unknown	report-only"
expect_row "attested review naming the author vendor is not eligible" attested-own-vendor.json \
  "incomplete	vendor-not-independent,g12-not-met,not-e3	C	true	false	unknown	APPROVE	E1	codex	codex	unknown	unknown	unknown	unknown	report-only"
expect_row "requirement satisfied by a commit status" status-satisfies.json \
  "delivered		C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "status from a different app is unmatched when app id is required" status-wrong-creator.json \
  "incomplete	required-check-unmatched,g12-not-met	C	true	false	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "unreadable combined status is unknown and not matched" status-endpoint-unknown.json \
  "incomplete	required-checks-unknown,g12-not-met	C	true	unknown	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "merged success at merge survives a later failure" merged-status-then-failure.json \
  "delivered		C	true	true	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "merged success only after merged_at is unmatched" merged-status-only-after.json \
  "incomplete	required-check-unmatched,g12-not-met	C	true	false	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "merged pull request with no merged_at is unknown" merged-at-missing.json \
  "incomplete	required-checks-unknown,g12-not-met	C	true	unknown	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"
expect_row "open pull request uses the latest status, not history" open-latest-not-history.json \
  "blocked	required-check-failed	C	true	false	unknown	APPROVE	E3	grok	devin	unknown	unknown	unknown	unknown	report-only"

node -e '
  const { execFileSync } = require("child_process");
  const evalPath = process.argv[1];
  const merged = process.argv[2];
  const base = process.argv[3];
  const project = (file) => JSON.parse(execFileSync(process.execPath, [evalPath, "project", "--bundle", file], { encoding: "utf8" }));
  const j = project(merged);
  const note = (j.postMerge || [])[0];
  if (j.disposition !== "delivered") process.exit(2);
  if (!note || note.name !== "review-evidence" || note.kind !== "status" || note.conclusion !== "failure" || note.at !== "2026-10-01T00:07:00Z") process.exit(3);
  const plain = project(base);
  if (!Array.isArray(plain.postMerge) || plain.postMerge.length !== 0) process.exit(4);
' "$EVAL" "$CASES/merged-status-then-failure.json" "$CASES/delivered-tier-c.json" \
  && ok "post-merge failure is a note and not the verdict" \
  || bad "postMerge note missing or it changed disposition"

node -e '
  const fs = require("fs");
  const { execFileSync } = require("child_process");
  const bundle = process.argv[1];
  const evalPath = process.argv[2];
  const out = execFileSync(process.execPath, [evalPath, "project", "--bundle", bundle], { encoding: "utf8" });
  const j = JSON.parse(out);
  const gate = (j.gates || []).find((g) => g.name === "review-evidence");
  if (!gate || gate.kind !== "status" || gate.appId !== 1 || gate.appSlug !== null) process.exit(1);
  if (j.disposition !== "delivered") process.exit(2);
' "$CASES/status-satisfies.json" "$EVAL" \
  && ok "status match keeps kind status and does not invent an app slug" \
  || bad "status match gate shape"

node "$EVAL" project --bundle "$CASES/joined-cost.json" >"$ROOT/joined.json"
node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const bad = !j.cost.rows || j.cost.rows.some((r) => r.usd !== null || r.tokensIn !== null || r.tokensOut !== null);
  if (j.cost.status !== "joined" || j.cost.usdTotal !== null || bad) process.exit(1);
' "$ROOT/joined.json" && ok "joined cost leaves usd null" || bad "joined cost invented a sum"

echo "# byte stability and verify"
node "$EVAL" project --bundle "$CASES/delivered-tier-c.json" >"$ROOT/a.json"
node "$EVAL" project --bundle "$CASES/delivered-tier-c.json" >"$ROOT/b.json"
cmp -s "$ROOT/a.json" "$ROOT/b.json" && ok "project is byte-stable" || bad "project is not byte-stable"
node "$EVAL" verify --receipt "$ROOT/a.json" --bundle "$CASES/delivered-tier-c.json" >"$ROOT/ver.out"
[ $? -eq 0 ] && ok "verify with bundle passes a projection" || bad "verify with bundle failed: $(cat "$ROOT/ver.out")"
node "$EVAL" verify --receipt "$ROOT/a.json" >"$ROOT/ver2.out"
[ $? -eq 0 ] && ok "verify without bundle passes a projection" || bad "verify without bundle failed: $(cat "$ROOT/ver2.out")"
grep -q '^ok delivered$' "$ROOT/ver2.out" && ok "verify prints the disposition" || bad "verify did not print disposition"

node "$EVAL" verify --receipt "$FIX/receipt-noncanonical.json" >"$ROOT/nc.out"
[ $? -eq 0 ] && ok "non-canonical key order with the canonical digest passes" || bad "non-canonical receipt failed: $(cat "$ROOT/nc.out")"
node "$EVAL" verify --receipt "$FIX/receipt-bad-digest.json" >"$ROOT/bd.out"
rc=$?
if [ "$rc" -eq 1 ] && grep -qx 'contradictory' "$ROOT/bd.out"; then ok "wrong digest fails closed"; else bad "wrong digest rc=$rc: $(cat "$ROOT/bd.out")"; fi

node --input-type=module <<EOF
import { readFileSync, writeFileSync } from "node:fs";
import { projectBundle, verifyReceipt, digestHex } from "${EVAL}";
const bundle = JSON.parse(readFileSync("${CASES}/delivered-tier-c.json", "utf8"));
const receipt = projectBundle(bundle);
const mutated = JSON.parse(JSON.stringify(bundle));
mutated.inputs.checkRuns[0].conclusion = "failure";
receipt.bundleDigest = digestHex(mutated, false);
receipt.digest = digestHex(receipt, true);
const result = verifyReceipt(receipt, mutated);
if (result.ok || !result.reasons.includes("contradictory")) {
  console.log("FAIL " + JSON.stringify(result));
  process.exit(1);
}
writeFileSync("${ROOT}/mutated-bundle.json", JSON.stringify(mutated));
writeFileSync("${ROOT}/redigested.json", JSON.stringify(receipt));
EOF
[ $? -eq 0 ] && ok "bundle mutated then receipt re-digested is contradictory" || bad "re-digested mutated bundle was accepted"

echo "# digest vectors"
for vec in vector-key-order vector-omit-digest vector-escape; do
  node --input-type=module <<EOF
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { canonicalJson, digestHex } from "${EVAL}";
const v = JSON.parse(readFileSync("${FIX}/${vec}.json", "utf8"));
const got = canonicalJson(v.input, v.omitDigest);
const dig = digestHex(v.input, v.omitDigest);
const indep = createHash("sha256").update(v.canonical, "utf8").digest("hex");
if (got !== v.canonical || dig !== v.digest || indep !== v.digest) {
  console.error(got, dig, indep);
  process.exit(1);
}
EOF
  [ $? -eq 0 ] && ok "digest vector $vec" || bad "digest vector $vec"
done

echo "# redaction and schema"
node --input-type=module <<EOF
import { readFileSync, writeFileSync } from "node:fs";
import { markerOnly, projectBundle } from "${EVAL}";
const leaked = "SECRET token and /Users/example/path";
const sha = "a".repeat(40);
const inside = (marker, fields) => "<!-- " + marker + "\n" + fields + "\n" + leaked + "\n-->";
const evidence = inside("review-evidence:v1", "head-sha: " + sha + "\nresult: pass");
const attestation = inside("owner-review-attestation:v1", "head-sha: " + sha + "\nauthor-vendor: grok");
const external = inside("owner-attested-review:v1", "head-sha: " + sha + "\nreviewer-vendor: codex\nresult: pass");
const dirty = markerOnly([leaked, evidence, attestation, external].join("\n"));
const clean = markerOnly("<!-- review-evidence:v1\nhead-sha: " + sha + "\nresult: pass\n-->");
const valued = markerOnly("<!-- review-evidence:v1\nhead-sha: " + sha + " " + leaked + "\nresult: pass\n-->");
if (dirty !== "" || valued !== "") process.exit(1);
if (!clean.startsWith("<!-- review-evidence:v1") || !clean.includes("result: pass") || clean.includes("SECRET") || clean.includes("/Users/")) process.exit(1);
const secretOnly = "<!-- review-evidence:v1\nhead-sha: " + sha + "\nresult: pass\nSECRET-INSIDE-MARKER\n-->";
const bundle = JSON.parse(readFileSync("${CASES}/delivered-tier-c.json", "utf8"));
bundle.inputs.comments = [{
  id: 9,
  user: { login: "someone", type: "User" },
  author_association: "NONE",
  performed_via_github_app: null,
  created_at: "2026-10-01T00:00:00Z",
  body: secretOnly,
}];
writeFileSync("${ROOT}/leak-marker.json", JSON.stringify(bundle));
let markerThrew = false;
try { projectBundle(bundle); } catch (e) { markerThrew = String(e.message || "").includes("redaction:marker"); }
if (!markerThrew) process.exit(1);
const pathBundle = JSON.parse(readFileSync("${CASES}/delivered-tier-c.json", "utf8"));
pathBundle.inputs.commits[0].commit.message = "Agent-Vendor: grok\n/Users/example/path";
writeFileSync("${ROOT}/leak-path.json", JSON.stringify(pathBundle));
let pathThrew = false;
try { projectBundle(pathBundle); } catch (e) { pathThrew = String(e.message || "").includes("redaction:absolute-path"); }
if (!pathThrew) process.exit(1);
EOF
[ $? -eq 0 ] && ok "marker redaction drops text that is not a marker field" || bad "marker redaction kept secret text"

node "$EVAL" project --bundle "$ROOT/leak-marker.json" >"$ROOT/leak-project.out" 2>"$ROOT/leak-project.err"
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'redaction:marker' "$ROOT/leak-project.out"; then
  ok "project refuses a secret inside an existing marker"
else
  bad "project accepted a marker secret rc=$rc $(cat "$ROOT/leak-project.out")"
fi
node "$EVAL" verify --receipt "$ROOT/a.json" --bundle "$ROOT/leak-marker.json" >"$ROOT/leak-verify.out" 2>"$ROOT/leak-verify.err"
rc=$?
if [ "$rc" -eq 1 ] && grep -qx 'contradictory' "$ROOT/leak-verify.out"; then
  ok "verify refuses a bundle whose marker is not redacted"
else
  bad "verify accepted a marker secret rc=$rc $(cat "$ROOT/leak-verify.out")"
fi
node "$EVAL" project --bundle "$ROOT/leak-path.json" >"$ROOT/leak-path.out" 2>"$ROOT/leak-path.err"
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'redaction:absolute-path' "$ROOT/leak-path.out"; then
  ok "project refuses a host path in an existing bundle"
else
  bad "project accepted a host path rc=$rc $(cat "$ROOT/leak-path.out")"
fi
node "$EVAL" verify --receipt "$ROOT/a.json" --bundle "$ROOT/leak-path.json" >"$ROOT/leak-path-verify.out" 2>"$ROOT/leak-path-verify.err"
rc=$?
if [ "$rc" -eq 1 ] && grep -qx 'contradictory' "$ROOT/leak-path-verify.out"; then
  ok "verify refuses a host path in an existing bundle"
else
  bad "verify accepted a host path rc=$rc $(cat "$ROOT/leak-path-verify.out")"
fi

if grep -R -E -n '/Users/|/home/|/private/var/|html_url|SECRET' "$FIX" >/dev/null; then
  bad "fixture text contains a forbidden leak"
else
  ok "fixtures contain no host path, html_url, or SECRET marker"
fi

node --input-type=module <<EOF
import { readFileSync } from "node:fs";
const schema = JSON.parse(readFileSync("${SCHEMA}", "utf8"));
if (schema.\$id !== "gibson.delivery.v1") process.exit(1);
const walk = (node, path) => {
  if (!node || typeof node !== "object") return;
  if (node.type === "object" && node.additionalProperties !== false) {
    console.error("open object at " + path);
    process.exit(1);
  }
  for (const [k, v] of Object.entries(node)) {
    if (v && typeof v === "object") walk(v, path + "." + k);
  }
};
walk(schema, "\$");
const need = ["subject", "actors", "review", "gates", "tier", "g12", "policyManifestDigest", "cost", "deployment", "cleanup", "lessons", "disposition", "digest", "bundleDigest"];
for (const k of need) if (!schema.required.includes(k)) process.exit(1);
if (schema.properties.policyManifestDigest.const !== "unknown") process.exit(1);
if (schema.properties.deployment.\$ref !== "#/\$defs/unknownStatus") process.exit(1);
EOF
[ $? -eq 0 ] && ok "schema is closed and id is gibson.delivery.v1" || bad "schema shape"

CFG="$REPO_ROOT/config/review-evidence.v1.json"
FX_JS="$SCRIPT_DIR/delivery-receipt-collect-fixtures.mjs"
mkdir -p "$ROOT/empty-fx"
printf '%s\n' '{}' >"$ROOT/empty-fx/map.json"

collect_env() {
  GIBSON_DELIVERY_GH_FIXTURE="$1" GIBSON_DELIVERY_GH_LOG="$2" node "$EVAL" collect \
    --repo example/example --pr 1 --out "$3" --config "$CFG" ${4:-}
}

echo "# usage exits 2 with no network"
node "$EVAL" --definitely-not-a-flag >/dev/null 2>"$ROOT/flag.err"
[ $? -eq 2 ] && grep -q 'unknown flag:' "$ROOT/flag.err" && ok "unknown flag exits 2" || bad "unknown flag contract"
node "$EVAL" project >/dev/null 2>"$ROOT/usage.err"
[ $? -eq 2 ] && ok "project without --bundle exits 2" || bad "project usage"
node "$EVAL" nosuch >/dev/null 2>"$ROOT/cmd.err"
[ $? -eq 2 ] && ok "unknown command exits 2" || bad "unknown command"

GHLOG="$ROOT/ledger.gh.log"
node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/no.json" --ledger "$ROOT/missing-ledger.jsonl" \
  --config "$CFG" >/dev/null 2>"$ROOT/led.err"
rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/no.json" ] && grep -q -- '--ledger is unreadable' "$ROOT/led.err"; then
  ok "bad ledger exits 2 before a bundle is written"
else
  bad "bad ledger rc=$rc $(cat "$ROOT/led.err")"
fi
# The ledger refusal must happen before ghSpawn. Re-run with a call log.
GIBSON_DELIVERY_GH_FIXTURE="$ROOT/empty-fx" GIBSON_DELIVERY_GH_LOG="$GHLOG" \
  node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/no2.json" --ledger "$ROOT/missing-ledger.jsonl" \
  --config "$CFG" >/dev/null 2>"$ROOT/led2.err"
if [ ! -e "$GHLOG" ] && [ ! -e "$ROOT/no2.json" ]; then
  ok "unreadable --ledger makes zero gh calls"
else
  bad "unreadable ledger still called gh ($(wc -l <"$GHLOG" 2>/dev/null || echo missing))"
fi

: >"$ROOT/exists.json"
GHLOG="$ROOT/out.gh.log"
GIBSON_DELIVERY_GH_FIXTURE="$ROOT/empty-fx" GIBSON_DELIVERY_GH_LOG="$GHLOG" \
  node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/exists.json" --config "$CFG" >/dev/null 2>"$ROOT/ex.err"
if [ $? -eq 2 ] && [ ! -s "$ROOT/exists.json" ] && grep -q -- '--out already exists' "$ROOT/ex.err" && [ ! -e "$GHLOG" ]; then
  ok "collect refuses an existing --out before network"
else
  bad "collect overwrite rc/log $(cat "$ROOT/ex.err") log=$(cat "$GHLOG" 2>/dev/null)"
fi

echo "# collect offline (injected gh fixture; zero live network)"
node -e '
  const sha1="d".repeat(40), sha2="e".repeat(40);
  const c=(sha,msg)=>({sha,author:{login:"aie-agent-lanes-grok[bot]"},committer:{login:"aie-agent-lanes-grok[bot]"},commit:{message:msg,verification:{verified:true}}});
  process.stdout.write(JSON.stringify({"repos/example/example/pulls/1/commits?per_page=100":{ok:true,body:[[c(sha1,"feat: page-one\n\nAgent-Vendor: grok\n")],[c(sha2,"feat: page-two\n\nAgent-Vendor: grok\n")]]}}));
' >"$ROOT/page.override.json"
node "$FX_JS" "$ROOT/fx-page" "$(cat "$ROOT/page.override.json")"
GHLOG="$ROOT/page.gh.log"
GIBSON_DELIVERY_GH_FIXTURE="$ROOT/fx-page" GIBSON_DELIVERY_GH_LOG="$GHLOG" \
  node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/page.json" --config "$CFG" >/dev/null 2>"$ROOT/page.err"
rc=$?
if [ "$rc" -eq 0 ] && [ -s "$ROOT/page.json" ]; then
  node -e '
    const fs=require("fs");
    const b=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const commits=b.sources.find(s=>String(s.endpoint).endsWith("/commits"));
    if (!commits || commits.pages!==2 || commits.exhausted!==true) process.exit(2);
    if (!Array.isArray(b.inputs.commits) || b.inputs.commits.length!==2) process.exit(3);
    const req=b.inputs.requiredChecks;
    if (req.status!=="known" || req.entries.length!==2) process.exit(4);
    if (!req.entries.every(e=>e.appId===15368)) process.exit(5);
    if (JSON.stringify(b).includes("SECRET")) process.exit(6);
  ' "$ROOT/page.json" \
    && ok "collect paginates commits across two pages" \
    || bad "collect pagination shape $(node -e 'const b=require(process.argv[1]); console.log(JSON.stringify({pages:b.sources,n:(b.inputs.commits||[]).length,req:b.inputs.requiredChecks}) )' "$ROOT/page.json" 2>/dev/null)"
else
  bad "collect pagination rc=$rc $(cat "$ROOT/page.err")"
fi
[ -s "$GHLOG" ] && ok "pagination collect recorded gh calls" || bad "pagination collect made no gh calls"

node "$FX_JS" "$ROOT/fx-unknown" "$(node -e 'process.stdout.write(JSON.stringify({"repos/example/example/branches/main/protection/required_status_checks":{ok:false,stderr:"gh: HTTP 404 Not Found"}}))')"
GHLOG="$ROOT/unk.gh.log"
GIBSON_DELIVERY_GH_FIXTURE="$ROOT/fx-unknown" GIBSON_DELIVERY_GH_LOG="$GHLOG" \
  node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/unknown.json" --config "$CFG" >/dev/null 2>"$ROOT/unk.err"
if [ $? -eq 0 ]; then
  node -e '
    const b=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if (b.inputs.requiredChecks.status!=="unknown") process.exit(2);
    if ((b.inputs.requiredChecks.entries||[]).length!==0) process.exit(3);
    const prot=b.sources.find(s=>String(s.endpoint).includes("protection/required_status_checks"));
    if (!prot || prot.exhausted===true) process.exit(4);
  ' "$ROOT/unknown.json" \
    && ok "unreadable required-check endpoint is unknown" \
    || bad "unknown-endpoint bundle shape"
else
  bad "unknown-endpoint collect rc $(cat "$ROOT/unk.err")"
fi

node -e '
  const head="a".repeat(40);
  const body="<!-- review-evidence:v1\nhead-sha: "+head+"\nresult: pass\nSECRET sk-live-not-a-real-key\n-->";
  const comment={id:11,user:{login:"devin-ai-integration[bot]",type:"Bot"},author_association:"NONE",performed_via_github_app:{slug:"devin-ai-integration",id:811515},created_at:"2026-10-13T00:00:00Z",body};
  process.stdout.write(JSON.stringify({"repos/example/example/issues/1/comments?per_page=100":{ok:true,body:[[comment]]}}));
' >"$ROOT/secret.override.json"
node "$FX_JS" "$ROOT/fx-secret" "$(cat "$ROOT/secret.override.json")"
GIBSON_DELIVERY_GH_FIXTURE="$ROOT/fx-secret" \
  node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/secret.json" --config "$CFG" >/dev/null 2>"$ROOT/secret.err"
if [ $? -eq 0 ]; then
  if grep -F "SECRET" "$ROOT/secret.json" >/dev/null || grep -F "sk-live-not-a-real-key" "$ROOT/secret.json" >/dev/null; then
    bad "collect retained a secret inside a marker"
  else
    node -e '
      const b=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      const body=(b.inputs.comments[0]&&b.inputs.comments[0].body)||"";
      if (body.includes("SECRET") || body.includes("sk-live")) process.exit(2);
      if (body && !body.includes("review-evidence:v1") && body.length!==0) process.exit(3);
    ' "$ROOT/secret.json" \
      && ok "secret inside a marker is dropped at collection" \
      || bad "secret drop left unexpected comment body"
  fi
else
  bad "secret collect rc=$(cat "$ROOT/secret.err")"
fi

node "$FX_JS" "$ROOT/fx-host" "$(node -e '
  const sha="d".repeat(40);
  const c={sha,author:{login:"aie-agent-lanes-grok[bot]"},committer:{login:"aie-agent-lanes-grok[bot]"},commit:{message:"fix path /Users/example/secret\\n\\nAgent-Vendor: grok\\n",verification:{verified:true}}};
  process.stdout.write(JSON.stringify({"repos/example/example/pulls/1/commits?per_page=100":{ok:true,body:[[c]]}}));
')"
GIBSON_DELIVERY_GH_FIXTURE="$ROOT/fx-host" \
  node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/host.json" --config "$CFG" >/dev/null 2>"$ROOT/host.err"
if [ $? -eq 2 ] && [ ! -e "$ROOT/host.json" ] && grep -q 'redaction:absolute-path' "$ROOT/host.err"; then
  ok "host path in a commit message is rejected"
else
  bad "host path collect rc/out $(cat "$ROOT/host.err") exists=$( [ -e "$ROOT/host.json" ] && echo yes || echo no )"
fi

node "$FX_JS" "$ROOT/fx-status-down" "$(node -e 'const h="a".repeat(40); process.stdout.write(JSON.stringify({["repos/example/example/commits/"+h+"/status?per_page=100"]:{ok:false,stderr:"gh: HTTP 502"}}))')"
GIBSON_DELIVERY_GH_FIXTURE="$ROOT/fx-status-down" \
  node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/status-down.json" --config "$CFG" >/dev/null 2>"$ROOT/status-down.err"
if [ $? -eq 0 ]; then
  node -e '
    const b=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if (b.inputs.combinedStatus!=="unknown") process.exit(2);
    if (b.inputs.requiredChecks.status!=="unknown") process.exit(3);
    if ((b.inputs.requiredChecks.entries||[]).length!==0) process.exit(4);
    const src=b.sources.find(s=>String(s.endpoint).endsWith("/status"));
    if (!src || src.exhausted!==false) process.exit(5);
  ' "$ROOT/status-down.json" \
    && ok "unreadable combined-status endpoint is unknown and not exhausted" \
    || bad "status-endpoint bundle shape"
  node "$EVAL" project --bundle "$ROOT/status-down.json" >"$ROOT/status-down.proj" 2>"$ROOT/status-down.proj.err"
  node -e '
    const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if (j.disposition==="delivered") process.exit(2);
    if (!(j.reasons||[]).includes("required-checks-unknown")) process.exit(3);
  ' "$ROOT/status-down.proj" \
    && ok "unreadable combined status is not matched" \
    || bad "status-endpoint project matched a requirement"
else
  bad "status-endpoint collect rc $(cat "$ROOT/status-down.err")"
fi

node "$FX_JS" "$ROOT/fx-status-latest" "$(node -e '
  const h="a".repeat(40);
  const historical=[
    {context:"review-evidence",state:"failure",creator:{login:"github-actions[bot]",id:41898282},updated_at:"2026-10-13T09:30:13Z"},
    {context:"review-evidence",state:"pending",creator:{login:"github-actions[bot]",id:41898282},updated_at:"2026-10-13T09:22:00Z"}
  ];
  const combined=[{state:"success",total_count:1,sha:h,statuses:[{context:"review-evidence",state:"success",avatar_url:"https://avatars.githubusercontent.com/in/15368?v=4",updated_at:"2026-10-13T09:22:00Z"}]}];
  const key=(p)=>"repos/example/example/commits/"+h+p;
  process.stdout.write(JSON.stringify({
    [key("/statuses?per_page=100")]:{ok:true,body:[historical]},
    [key("/status?per_page=100")]:{ok:true,body:combined}
  }));
')"
GIBSON_DELIVERY_GH_FIXTURE="$ROOT/fx-status-latest" \
  node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/status-latest.json" --config "$CFG" >/dev/null 2>"$ROOT/status-latest.err"
if [ $? -eq 0 ]; then
  node -e '
    const b=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const rows=(b.inputs.checkRuns||[]).filter(r=>r.name==="review-evidence");
    if (rows.length!==1) process.exit(2);
    const row=rows[0];
    if (row.kind!=="status" || row.conclusion!=="success" || row.appId!==15368) process.exit(3);
    if (row.appSlug!==null) process.exit(4);
    if (b.inputs.combinedStatus!=="known") process.exit(5);
    if (!Array.isArray(b.inputs.statusHistory) || b.inputs.statusHistory.length!==2) process.exit(7);
    const hist=b.sources.find(s=>String(s.endpoint).endsWith("/statuses"));
    const comb=b.sources.find(s=>String(s.endpoint).endsWith("/status"));
    if (!hist || hist.exhausted!==true || !comb || comb.exhausted!==true) process.exit(6);
  ' "$ROOT/status-latest.json" \
    && ok "combined status is the match row; historical stamps are not folded in" \
    || bad "combined status shape $(node -e 'const b=require(process.argv[1]); console.log(JSON.stringify(b.inputs.checkRuns))' "$ROOT/status-latest.json")"
else
  bad "combined status collect rc $(cat "$ROOT/status-latest.err")"
fi

echo "# live PR 154 bundle is frozen and projects twice"
LIVE="$FIX/pr-154.bundle.json"
if [ ! -f "$LIVE" ]; then
  bad "pr-154.bundle.json is missing"
else
  if grep -E -n '/Users/|/home/|/private/var/' "$LIVE" >/dev/null; then
    bad "pr 154 bundle contains a host path"
  else
    ok "pr 154 bundle has no host path"
  fi
  node "$EVAL" project --bundle "$LIVE" >"$ROOT/live1.json"
  rc1=$?
  node "$EVAL" project --bundle "$LIVE" >"$ROOT/live2.json"
  rc2=$?
  if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && cmp -s "$ROOT/live1.json" "$ROOT/live2.json"; then
    ok "pr 154 projects byte-stable"
  else
    bad "pr 154 project rc=$rc1/$rc2"
  fi
  node "$EVAL" verify --receipt "$ROOT/live1.json" --bundle "$LIVE" >/dev/null
  [ $? -eq 0 ] && ok "pr 154 receipt verifies against its bundle" || bad "pr 154 verify failed"
  node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (j.schema !== "gibson.delivery-bundle.v1") process.exit(1);
    if (j.repository !== "The-AIE/the-gibson" || j.pr !== 154) process.exit(1);
    const text = JSON.stringify(j.inputs);
    if (/"body":\s*"[^"]{80,}/.test(text)) process.exit(2);
  ' "$LIVE" && ok "pr 154 bundle is allowlisted" || bad "pr 154 bundle shape or body leak"
fi

echo "# mutations (temp copy; original sha256 must hold)"
mutant_for() {
  local anchor="$1" dest="$2"
  mkdir -p "$dest"
  ln -s "$REPO_ROOT/scripts/pr-review-evidence.mjs" "$dest/pr-review-evidence.mjs"
  sed "/${anchor}/d" "$EVAL" >"$dest/delivery-receipt.mjs"
  node --check "$dest/delivery-receipt.mjs"
}

project_disp() {
  node "$1" project --bundle "$2" >"$ROOT/pdisp.out" 2>"$ROOT/pdisp.err"
  node -e 'const fs=require("fs"); const s=fs.readFileSync(process.argv[1],"utf8"); process.stdout.write(JSON.parse(s).disposition)' "$ROOT/pdisp.out"
}

expect_mut_project() {
  local name="$1" anchor="$2" fixture="$3"
  local dest orig mut
  dest="$ROOT/mut-$name"
  if ! mutant_for "$anchor" "$dest"; then bad "$name mutant does not parse"; return; fi
  orig=$(project_disp "$EVAL" "$CASES/$fixture")
  mut=$(project_disp "$dest/delivery-receipt.mjs" "$CASES/$fixture")
  if [ "$orig" != "delivered" ] && [ "$mut" = "delivered" ] && [ "$orig" != "$mut" ]; then
    ok "mutation $name: $orig -> $mut"
    echo "    receipt $name: original disposition $orig, mutant disposition $mut"
  else
    bad "mutation $name: original $orig mutant $mut"
  fi
}

expect_mut_project "app-id" "MUTATION_ANCHOR_APP_ID" "app-id-mismatch.json"
expect_mut_project "status-app" "MUTATION_ANCHOR_STATUS_APP" "status-wrong-creator.json"
expect_mut_project "status-unknown" "MUTATION_ANCHOR_STATUS_UNKNOWN" "status-endpoint-unknown.json"
expect_mut_project "as-of-merge" "MUTATION_ANCHOR_AS_OF_MERGE" "merged-status-only-after.json"
expect_mut_project "merged-at" "MUTATION_ANCHOR_MERGED_AT" "merged-at-missing.json"

expect_mut_open() {
  local dest orig mut
  dest="$ROOT/mut-open-latest"
  if ! mutant_for "MUTATION_ANCHOR_OPEN_LATEST" "$dest"; then bad "open-latest mutant does not parse"; return; fi
  orig=$(project_disp "$EVAL" "$CASES/open-latest-not-history.json")
  mut=$(project_disp "$dest/delivery-receipt.mjs" "$CASES/open-latest-not-history.json")
  if [ "$orig" = "blocked" ] && [ "$mut" = "parked" ]; then
    ok "mutation open-latest: blocked -> parked"
    echo "    receipt open-latest: original disposition $orig, mutant disposition $mut"
  else
    bad "mutation open-latest: original $orig mutant $mut"
  fi
}
expect_mut_open
expect_mut_project "unknown-vendor" "MUTATION_ANCHOR_UNKNOWN_VENDOR" "unvendored-owner.json"

expect_mut_vendor() {
  local dest orig mut
  dest="$ROOT/mut-attested-vendor"
  if ! mutant_for "MUTATION_ANCHOR_ATTESTED_VENDOR" "$dest"; then bad "attested-vendor mutant does not parse"; return; fi
  orig=$(node "$EVAL" project --bundle "$CASES/attested-codex.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const j=JSON.parse(s);process.stdout.write(j.disposition+" "+j.actors.reviewer.vendor)})')
  mut=$(node "$dest/delivery-receipt.mjs" project --bundle "$CASES/attested-codex.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const j=JSON.parse(s);process.stdout.write(j.disposition+" "+j.actors.reviewer.vendor)})')
  if [ "$orig" = "delivered codex" ] && [ "$mut" = "incomplete unknown" ]; then
    ok "mutation attested-vendor: delivered codex -> incomplete unknown"
    echo "    receipt attested-vendor: original $orig, mutant $mut"
  else
    bad "mutation attested-vendor: original [$orig] mutant [$mut]"
  fi
}
expect_mut_vendor
expect_mut_project "pagination" "MUTATION_ANCHOR_PAGINATION" "pagination-not-exhausted.json"
expect_mut_project "non-default-base" "MUTATION_ANCHOR_NON_DEFAULT_BASE" "non-default-base.json"
expect_mut_project "source-inventory" "MUTATION_ANCHOR_SOURCE_INVENTORY" "omitted-pulls-for-head.json"

expect_mut_marker() {
  local dest="$ROOT/mut-marker"
  if ! mutant_for "MUTATION_ANCHOR_MARKER_REDACT" "$dest"; then bad "marker mutant does not parse"; return; fi
  node --input-type=module <<EOF
import { markerOnly } from "${EVAL}";
import { markerOnly as poisoned } from "${dest}/delivery-receipt.mjs";
const sha = "a".repeat(40);
const dirty = "<!-- review-evidence:v1\nhead-sha: " + sha + "\nresult: pass\nSECRET /Users/example/path\n-->";
const orig = markerOnly(dirty);
const mut = poisoned(dirty);
if (orig.includes("SECRET") || orig.includes("/Users/")) process.exit(2);
if (!mut.includes("SECRET") || !mut.includes("/Users/example/path")) process.exit(3);
EOF
  if [ $? -eq 0 ]; then
    ok "mutation marker-redact: secret inside a marker is retained when the fix is removed"
    echo "    receipt marker-redact: original markerOnly dropped the secret, mutant kept it"
  else
    bad "mutation marker-redact did not turn the inside-marker secret red"
  fi
}
expect_mut_marker

expect_mut_leak() {
  local dest="$ROOT/mut-bundle-leak"
  if ! mutant_for "MUTATION_ANCHOR_BUNDLE_LEAK" "$dest"; then bad "bundle-leak mutant does not parse"; return; fi
  node "$EVAL" project --bundle "$ROOT/leak-marker.json" >"$ROOT/leak.orig" 2>"$ROOT/leak.orig.err"
  local o=$?
  node "$dest/delivery-receipt.mjs" project --bundle "$ROOT/leak-marker.json" >"$ROOT/leak.mut" 2>"$ROOT/leak.mut.err"
  local m=$?
  local disp=""
  if [ "$m" -eq 0 ]; then
    disp=$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).disposition)' "$ROOT/leak.mut")
  fi
  if [ "$o" -eq 1 ] && grep -q 'redaction:marker' "$ROOT/leak.orig" && [ "$m" -eq 0 ] && [ "$disp" = "delivered" ]; then
    ok "mutation bundle-leak: project $o -> $m"
    echo "    receipt bundle-leak: original project exit $o, mutant project exit $m disposition $disp"
  else
    bad "mutation bundle-leak: orig $o mut $m disp=$disp orig=$(cat "$ROOT/leak.orig") mut=$(cat "$ROOT/leak.mut")"
  fi
}
expect_mut_leak

node --input-type=module <<EOF
import { readFileSync, writeFileSync } from "node:fs";
import { projectBundle, digestHex } from "${EVAL}";
const r = projectBundle(JSON.parse(readFileSync("${CASES}/tier-a-delivered.json", "utf8")));
r.digest = "0".repeat(64);
writeFileSync("${ROOT}/bad-digest-receipt.json", JSON.stringify(r));
r.digest = digestHex({ ...r, digest: undefined }, true);
const hand = projectBundle(JSON.parse(readFileSync("${CASES}/tier-a-delivered.json", "utf8")));
hand.review.reviewedHeadSha = "9".repeat(40);
hand.g12 = { applies: false, met: false, reasons: ["tier-not-c", "level-e3", "head-unbound", "checks-success"] };
hand.digest = digestHex(hand, true);
writeFileSync("${ROOT}/head-mismatch-receipt.json", JSON.stringify(hand));
EOF

verify_run() {
  node "$1" verify --receipt "$2" >"$ROOT/v.out" 2>"$ROOT/verr"
  echo $?
}

expect_mut_verify() {
  local name="$1" anchor="$2" receipt="$3"
  local dest o m
  dest="$ROOT/mutv-$name"
  if ! mutant_for "$anchor" "$dest"; then bad "$name mutant does not parse"; return; fi
  o=$(verify_run "$EVAL" "$receipt")
  cp "$ROOT/v.out" "$ROOT/v.orig"
  m=$(verify_run "$dest/delivery-receipt.mjs" "$receipt")
  # A temp copy that never becomes main exits 0 with empty stdout. Require the
  # original to name the contradiction and the mutant to print an ok line.
  if [ "$o" -eq 1 ] && grep -q contradictory "$ROOT/v.orig" && [ "$m" -eq 0 ] && grep -q '^ok ' "$ROOT/v.out"; then
    ok "mutation $name: verify $o -> $m"
    echo "    receipt $name: original verify exit $o, mutant verify exit $m"
  else
    bad "mutation $name: original exit $o mutant exit $m orig=$(cat "$ROOT/v.orig") mut=$(cat "$ROOT/v.out")"
  fi
}

expect_mut_verify "digest" "MUTATION_ANCHOR_DIGEST" "$ROOT/bad-digest-receipt.json"
expect_mut_verify "head-equality" "MUTATION_ANCHOR_HEAD_EQUALITY" "$ROOT/head-mismatch-receipt.json"

expect_mut_zero_gh() {
  local name="$1" anchor="$2" extra="$3"
  local dest origlog mutlog
  dest="$ROOT/mut-$name"
  origlog="$ROOT/mut-$name.orig.log"
  mutlog="$ROOT/mut-$name.mut.log"
  rm -f "$origlog" "$mutlog"
  if ! mutant_for "$anchor" "$dest"; then bad "$name mutant does not parse"; return; fi
  : >"$ROOT/mut-$name.exists.json"
  GIBSON_DELIVERY_GH_FIXTURE="$ROOT/empty-fx" GIBSON_DELIVERY_GH_LOG="$origlog" \
    node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/mut-$name.exists.json" --config "$CFG" $extra >/dev/null 2>"$ROOT/mut-$name.orig.err"
  : >"$ROOT/mut-$name.exists2.json"
  GIBSON_DELIVERY_GH_FIXTURE="$ROOT/empty-fx" GIBSON_DELIVERY_GH_LOG="$mutlog" \
    node "$dest/delivery-receipt.mjs" collect --repo example/example --pr 1 --out "$ROOT/mut-$name.exists2.json" --config "$CFG" $extra >/dev/null 2>"$ROOT/mut-$name.mut.err"
  if [ ! -e "$origlog" ] && [ -s "$mutlog" ]; then
    ok "mutation $name: original 0 gh calls, mutant $(wc -l <"$mutlog" | tr -d ' ') calls"
    echo "    receipt $name: original gh calls 0, mutant gh calls $(wc -l <"$mutlog" | tr -d ' ')"
  else
    bad "mutation $name: orig-log=$( [ -e "$origlog" ] && wc -l <"$origlog" || echo 0 ) mut-log=$( [ -e "$mutlog" ] && wc -l <"$mutlog" || echo 0 )"
  fi
}

expect_mut_zero_gh "out-before-gh" "MUTATION_ANCHOR_OUT_BEFORE_GH" ""
# Ledger mutation: --out must not exist so the out-check does not fire first.
expect_mut_ledger() {
  local dest origlog mutlog
  dest="$ROOT/mut-ledger-before-gh"
  origlog="$ROOT/mut-ledger.orig.log"
  mutlog="$ROOT/mut-ledger.mut.log"
  rm -f "$origlog" "$mutlog"
  if ! mutant_for "MUTATION_ANCHOR_LEDGER_BEFORE_GH" "$dest"; then bad "ledger-before-gh mutant does not parse"; return; fi
  GIBSON_DELIVERY_GH_FIXTURE="$ROOT/empty-fx" GIBSON_DELIVERY_GH_LOG="$origlog" \
    node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/mut-led.orig.json" --ledger "$ROOT/missing-ledger.jsonl" --config "$CFG" >/dev/null 2>"$ROOT/mut-led.orig.err"
  GIBSON_DELIVERY_GH_FIXTURE="$ROOT/empty-fx" GIBSON_DELIVERY_GH_LOG="$mutlog" \
    node "$dest/delivery-receipt.mjs" collect --repo example/example --pr 1 --out "$ROOT/mut-led.mut.json" --ledger "$ROOT/missing-ledger.jsonl" --config "$CFG" >/dev/null 2>"$ROOT/mut-led.mut.err"
  if [ ! -e "$origlog" ] && [ -s "$mutlog" ]; then
    ok "mutation ledger-before-gh: original 0 gh calls, mutant $(wc -l <"$mutlog" | tr -d ' ') calls"
    echo "    receipt ledger-before-gh: original gh calls 0, mutant gh calls $(wc -l <"$mutlog" | tr -d ' ')"
  else
    bad "mutation ledger-before-gh: orig-log=$( [ -e "$origlog" ] && wc -l <"$origlog" || echo 0 ) mut-log=$( [ -e "$mutlog" ] && wc -l <"$mutlog" || echo 0 )"
  fi
}
expect_mut_ledger

# The digest mutant must still reject a bundle that was mutated and re-digested.
dest="$ROOT/mut-digest-still"
mutant_for "MUTATION_ANCHOR_DIGEST" "$dest" || bad "digest mutant does not parse"
node "$dest/delivery-receipt.mjs" verify --receipt "$ROOT/redigested.json" --bundle "$ROOT/mutated-bundle.json" >"$ROOT/still.out"
rc=$?
if [ "$rc" -eq 1 ] && grep -q contradictory "$ROOT/still.out"; then
  ok "digest mutant still rejects a re-digested mutated bundle"
else
  bad "digest mutant accepted a stale re-digested receipt rc=$rc"
fi

NOW_SHA=$(shasum -a 256 "$EVAL" | awk 'NR==1 { print $1 }')
if [ "$NOW_SHA" = "$ORIG_SHA" ]; then
  ok "verifier sha256 unchanged after mutations ($NOW_SHA)"
else
  bad "verifier sha256 changed"
fi

echo
echo "delivery-receipt.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
