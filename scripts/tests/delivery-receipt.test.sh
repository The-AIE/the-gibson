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
CASES=$(node "$SCRIPT_DIR/delivery-receipt-cases.mjs") || {
  echo "delivery-receipt.test.sh: could not materialize cases"
  exit 1
}
[ -d "$CASES" ] || { echo "delivery-receipt.test.sh: case dir missing"; exit 1; }

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

echo "# usage exits 2 with no network"
node "$EVAL" --definitely-not-a-flag >/dev/null 2>"$ROOT/flag.err"
[ $? -eq 2 ] && grep -q 'unknown flag:' "$ROOT/flag.err" && ok "unknown flag exits 2" || bad "unknown flag contract"
node "$EVAL" project >/dev/null 2>"$ROOT/usage.err"
[ $? -eq 2 ] && ok "project without --bundle exits 2" || bad "project usage"
node "$EVAL" nosuch >/dev/null 2>"$ROOT/cmd.err"
[ $? -eq 2 ] && ok "unknown command exits 2" || bad "unknown command"
node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/no.json" --ledger "$ROOT/missing-ledger.jsonl" >/dev/null 2>"$ROOT/led.err"
rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/no.json" ] && grep -qx 'not available in this build; see #160 follow-up' "$ROOT/led.err"; then
  ok "bad ledger exits 2 before a bundle is written"
else
  bad "bad ledger rc=$rc $(cat "$ROOT/led.err")"
fi
: >"$ROOT/exists.json"
node "$EVAL" collect --repo example/example --pr 1 --out "$ROOT/exists.json" >/dev/null 2>"$ROOT/ex.err"
[ $? -eq 2 ] && [ ! -s "$ROOT/exists.json" ] && grep -qx 'not available in this build; see #160 follow-up' "$ROOT/ex.err" && ok "collect refuses an existing --out before network" || bad "collect overwrite"

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
expect_mut_project "unknown-vendor" "MUTATION_ANCHOR_UNKNOWN_VENDOR" "unvendored-owner.json"
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
