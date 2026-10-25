#!/usr/bin/env bash
# claim-stale-copy.test.sh — claim.sh refuses to run a copy that differs from origin/main (#556)
#
# SCOPE OF THE PROOF
#   The check is enforced only when claim.sh runs from inside the canonical
#   repository (the self-hosted case where #507/#508 happened). A copy run from
#   another checkout has no published blob to compare with and is reported with
#   a NOTICE, never refused, because cross-repository use is legitimate.
#
# WHY
#   A stale claim.sh writes a reservation commit that later gates reject, and
#   the harness then forces close-and-reclaim (19 of 61 unmerged closures in
#   the 2026-10-25 audit). The check compares the running copy's blob with
#   origin/main's and refuses before any network mutation.
#
# HOW
#   Every case runs claim.sh against a throwaway bare "origin" in mktemp with a
#   fake `gh` on PATH, so GitHub is never touched. The fake `gh repo view` is
#   the sentinel: reaching it proves the check let the run through, because it
#   is the first gh call after the check.
#
# MUTATION PROOF (run in this file, last section)
#   A copy of claim.sh with the block between the `stale-copy check begin/end`
#   markers deleted lets a modified copy reach the sentinel. If a future edit
#   removes the check, that control stays green and the "modified copy refuses"
#   case goes red, which is the failure this test exists to produce.
#
# USAGE
#   scripts/tests/claim-stale-copy.test.sh
set -uo pipefail
export GIBSON_AGENT_VENDOR="${GIBSON_AGENT_VENDOR:-claude}"
export GIT_AUTHOR_NAME=gibson-sensor GIT_AUTHOR_EMAIL=sensor@gibson.invalid
export GIT_COMMITTER_NAME=gibson-sensor GIT_COMMITTER_EMAIL=sensor@gibson.invalid
unset GIBSON_CLAIM_ALLOW_STALE

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

for t in git node; do command -v "$t" >/dev/null || { echo "claim-stale-copy.test.sh: $t required"; exit 1; }; done

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-stale-copy.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
SENTINEL="SENTINEL-reached-gh-repo-view"

BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<GH
#!/usr/bin/env bash
if [[ "\$1" == "repo" && "\$2" == "view" ]]; then echo "$SENTINEL" >&2; exit 1; fi
echo "fake gh: unexpected call: \$*" >&2; exit 1
GH
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# fixture NAME — bare origin + clone holding this repo's scripts/ and .githooks/ on main
fixture() {
  local name="$1" bare="$ROOT/$1.git" wc="$ROOT/$1"
  git init -q --bare -b main "$bare"
  git clone -q "$bare" "$wc" 2>/dev/null
  git -C "$wc" checkout -q -b main 2>/dev/null || true
  mkdir -p "$wc/scripts" "$wc/.githooks"
  cp -R "$REPO_ROOT/scripts/." "$wc/scripts/"
  rm -rf "$wc/scripts/tests"
  cp -R "$REPO_ROOT/.githooks/." "$wc/.githooks/" 2>/dev/null || true
  git -C "$wc" add -A && git -C "$wc" commit -q -m "fixture: scripts" && git -C "$wc" push -q -u origin main 2>/dev/null
}

# run_claim WC — runs claim.sh from WC as the canonical checkout; sets OUT, RC
run_claim() {
  OUT=$(cd "$1" && GIBSON_CANONICAL="$1" bash scripts/claim.sh 1 stale-probe some/file.txt 2>&1)
  RC=$?
}

echo "# identical copy passes the check and reaches the first gh call"
fixture same
run_claim "$ROOT/same"
if [[ $RC -ne 0 && "$OUT" == *"$SENTINEL"* && "$OUT" != *"stale copy"* ]]; then ok "identical copy passes (sentinel reached, no stale refusal)"; else bad "identical copy rc=$RC out=$OUT"; fi

echo "# a modified copy refuses, names both blobs and the fix, before any gh call"
fixture modified
printf '\n# local edit that origin/main does not have\n' >> "$ROOT/modified/scripts/claim.sh"
run_claim "$ROOT/modified"
if [[ $RC -ne 0 && "$OUT" == *"stale copy of claim.sh"* && "$OUT" != *"$SENTINEL"* ]]; then ok "modified copy refuses before gh"; else bad "modified copy rc=$RC out=$OUT"; fi
here=$(git hash-object "$ROOT/modified/scripts/claim.sh"); there=$(git -C "$ROOT/modified" rev-parse "origin/main:scripts/claim.sh")
if [[ "$OUT" == *"${here:0:12}"* && "$OUT" == *"${there:0:12}"* ]]; then ok "refusal names the running and origin blobs"; else bad "blob hashes missing: $OUT"; fi
if [[ "$OUT" == *"up-to-date checkout"* && "$OUT" == *"#556"* ]]; then ok "refusal names the fix and the issue"; else bad "fix text missing: $OUT"; fi

echo "# the committed-but-unpushed case is also stale: origin/main is the authority, not local main"
git -C "$ROOT/modified" commit -q -am "local-only change to claim.sh"
run_claim "$ROOT/modified"
if [[ $RC -ne 0 && "$OUT" == *"stale copy of claim.sh"* ]]; then ok "a copy committed locally but absent from origin/main still refuses"; else bad "local commit rc=$RC out=$OUT"; fi

echo "# GIBSON_CLAIM_ALLOW_STALE=1 lets a modified copy through with a loud warning"
OUT=$(cd "$ROOT/modified" && GIBSON_CANONICAL="$ROOT/modified" GIBSON_CLAIM_ALLOW_STALE=1 bash scripts/claim.sh 1 stale-probe some/file.txt 2>&1); RC=$?
if [[ "$OUT" == *"WARNING"* && "$OUT" == *"STALE copy"* && "$OUT" == *"$SENTINEL"* ]]; then ok "override warns and continues to the sentinel"; else bad "override rc=$RC out=$OUT"; fi
echo "# only the exact value 1 is an override"
for v in true yes 0 ""; do
  OUT=$(cd "$ROOT/modified" && GIBSON_CANONICAL="$ROOT/modified" GIBSON_CLAIM_ALLOW_STALE="$v" bash scripts/claim.sh 1 stale-probe some/file.txt 2>&1); RC=$?
  if [[ $RC -ne 0 && "$OUT" == *"stale copy of claim.sh"* ]]; then ok "GIBSON_CLAIM_ALLOW_STALE='$v' does not override"; else bad "value '$v' overrode: $OUT"; fi
done

echo "# origin/main without scripts/claim.sh is unreadable: refuse, never pass"
fixture noscript
git -C "$ROOT/noscript" rm -q scripts/claim.sh && git -C "$ROOT/noscript" commit -q -m "drop claim.sh on main" && git -C "$ROOT/noscript" push -q origin main 2>/dev/null
cp "$REPO_ROOT/scripts/claim.sh" "$ROOT/noscript/scripts/claim.sh"
run_claim "$ROOT/noscript"
if [[ $RC -ne 0 && "$OUT" == *"cannot read scripts/claim.sh at origin/main"* && "$OUT" != *"$SENTINEL"* ]]; then ok "unreadable origin blob refuses (fail closed)"; else bad "noscript rc=$RC out=$OUT"; fi
echo "# the override does not bypass an unreadable origin"
OUT=$(cd "$ROOT/noscript" && GIBSON_CANONICAL="$ROOT/noscript" GIBSON_CLAIM_ALLOW_STALE=1 bash scripts/claim.sh 1 stale-probe some/file.txt 2>&1); RC=$?
if [[ $RC -ne 0 && "$OUT" != *"$SENTINEL"* ]]; then ok "override cannot pass an unreadable origin"; else bad "override passed unreadable origin: $OUT"; fi

echo "# a copy running from outside the canonical repository is reported, not refused (cross-repo use)"
fixture external
OUT=$(cd "$ROOT/external" && GIBSON_CANONICAL="$ROOT/external" bash "$REPO_ROOT/scripts/claim.sh" 1 stale-probe some/file.txt 2>&1); RC=$?
if [[ "$OUT" == *"NOTICE"* && "$OUT" == *"outside the canonical repository"* && "$OUT" == *"$SENTINEL"* && "$OUT" != *"stale copy"* ]]; then ok "external copy prints a notice and continues"; else bad "external rc=$RC out=$OUT"; fi
mkdir -p "$ROOT/nowhere" && cp -R "$REPO_ROOT/scripts/." "$ROOT/nowhere/scripts/" && rm -rf "$ROOT/nowhere/scripts/tests"
OUT=$(cd "$ROOT/external" && GIBSON_CANONICAL="$ROOT/external" bash "$ROOT/nowhere/scripts/claim.sh" 1 stale-probe some/file.txt 2>&1); RC=$?
if [[ "$OUT" == *"NOTICE"* && "$OUT" == *"$SENTINEL"* && "$OUT" != *"stale copy"* ]]; then ok "a copy outside any repository prints the notice and continues"; else bad "nowhere rc=$RC out=$OUT"; fi

echo "# the check runs after the fetch: an unreachable origin is refused by the fetch guard, not reported as stale"
fixture gone
rm -rf "$ROOT/gone.git"
run_claim "$ROOT/gone"
if [[ $RC -ne 0 && "$OUT" == *"#106"* && "$OUT" != *"stale copy"* ]]; then ok "unreachable origin fails on the #106 fetch guard first"; else bad "gone rc=$RC out=$OUT"; fi

echo "# mutation control: with the check deleted, a modified copy reaches gh (so the modified-copy case above can fail)"
fixture mutant
awk '/stale-copy check begin/{skip=1} !skip{print} /stale-copy check end/{skip=0}' "$ROOT/mutant/scripts/claim.sh" > "$ROOT/mutant/claim.mutant" && mv "$ROOT/mutant/claim.mutant" "$ROOT/mutant/scripts/claim.sh"
if grep -q 'stale-copy check' "$ROOT/mutant/scripts/claim.sh"; then bad "mutant still contains the check"; else ok "mutant has the check removed"; fi
run_claim "$ROOT/mutant"
if [[ "$OUT" == *"$SENTINEL"* && "$OUT" != *"stale copy"* ]]; then ok "control: without the check, a modified copy is not refused"; else bad "control did not behave: rc=$RC out=$OUT"; fi

echo
echo "claim-stale-copy.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
