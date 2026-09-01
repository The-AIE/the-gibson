#!/usr/bin/env bash
# claim-provenance.test.sh — process sensors for the report-only reservation reader (#273)
set -uo pipefail

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
READER="$SCRIPT_DIR/../claim-provenance.mjs"
PASS=0
FAIL=0
POSITIVE=0
ADVERSARIAL=0
ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }
pos() { POSITIVE=$((POSITIVE + 1)); ok "$1"; }
adv() { ADVERSARIAL=$((ADVERSARIAL + 1)); ok "$1"; }
adv_fail() { ADVERSARIAL=$((ADVERSARIAL + 1)); bad "$1"; }

echo "pure · node --test scripts/claim-provenance.test.mjs"
if ! command -v node >/dev/null 2>&1; then
  bad "node not installed"
elif node --test "$REPO_ROOT/scripts/claim-provenance.test.mjs"; then
  ok "node --test scripts/claim-provenance.test.mjs"
else
  bad "node --test scripts/claim-provenance.test.mjs"
fi

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-claim-provenance.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  number=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json|--repo|--jq|-q) shift 2 ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then number="$1"; fi
        shift
        ;;
    esac
  done
  body_file="${GH_PR_BODY:-/dev/null}"
  head="${GH_PR_HEAD:-}"
  branch="${GH_PR_BRANCH:-feat/42-demo}"
  cross="${GH_PR_CROSS:-false}"
  if [[ "${GH_PR_DRIFT:-0}" == 1 || "${GH_PR_DRIFT_BASE_OID:-0}" == 1 || "${GH_PR_DRIFT_STATE:-0}" == 1 ]]; then
    n=$(cat "${GH_PR_BODY}.views" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "${GH_PR_BODY}.views"
    if [[ "$n" -ge 2 ]]; then
      if [[ "${GH_PR_DRIFT:-0}" == 1 ]]; then
        head="${GH_PR_HEAD_DRIFT:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
      fi
      if [[ "${GH_PR_DRIFT_BASE_OID:-0}" == 1 ]]; then
        export GH_PR_BASE_OID="${GH_PR_BASE_OID_DRIFT:-ffffffffffffffffffffffffffffffffffffffff}"
      fi
      if [[ "${GH_PR_DRIFT_STATE:-0}" == 1 ]]; then
        export GH_PR_STATE="${GH_PR_STATE_DRIFT:-CLOSED}"
      fi
    fi
  fi
  [[ "${GH_PR_FAIL:-0}" == 1 ]] && exit 1
  node -e '
    const fs = require("fs");
    const numberArg = process.argv[1];
    const bodyPath = process.argv[2];
    const head = process.argv[3];
    const branch = process.argv[4];
    const cross = process.argv[5] === "true";
    const truncated = process.env.GH_PR_TRUNCATED === "1";
    const body = fs.existsSync(bodyPath) ? fs.readFileSync(bodyPath, "utf8") : "";
    const repo = process.env.GH_PR_JSON_REPO || process.env.GH_PR_REPO || "acme/app";
    const jsonNumber = process.env.GH_PR_JSON_NUMBER || numberArg;
    const baseRef = process.env.GH_PR_BASE_REF || "main";
    const baseOid = process.env.GH_PR_BASE_OID || "";
    const state = process.env.GH_PR_STATE || "OPEN";
    const url = process.env.GH_PR_URL || ("https://github.com/" + repo + "/pull/" + jsonNumber);
    process.stdout.write(JSON.stringify({
      number: Number(jsonNumber),
      url,
      body: truncated ? body.slice(0, 20) : body,
      headRefOid: head,
      headRefName: branch,
      isCrossRepository: cross,
      baseRefName: baseRef,
      baseRefOid: baseOid,
      state
    }));
  ' "$number" "$body_file" "$head" "$branch" "$cross"
  exit 0
fi
if [[ "$1" == "api" && "$2" != "graphql" ]]; then
  sha="${2##*/}"
  if [[ "${GH_COMMIT_SHA_MISMATCH:-0}" == 1 ]]; then
    printf '{"sha":"%s","author":{"login":"x"},"committer":{"login":"x"},"commit":{}}\n' \
      "ffffffffffffffffffffffffffffffffffffffff"
    exit 0
  fi
  if [[ "${GH_NO_LOGIN:-0}" == 1 ]]; then
    printf '{"sha":"%s","author":null,"committer":null,"commit":{}}\n' "$sha"
  elif [[ "${GH_TRUNCATED_COMMIT:-0}" == 1 ]]; then
    printf '{"sha":"%s","truncated":true,"author":{"login":"x"},"committer":{"login":"x"}}\n' "$sha"
  else
    login="${GIT_AUTHOR_NAME:-gibson-sensor}"
    printf '{"sha":"%s","author":{"login":"%s"},"committer":{"login":"%s"},"commit":{}}\n' \
      "$sha" "$login" "$login"
  fi
  exit 0
fi
echo "fake gh (claim-provenance): unmodelled invocation 'gh $*' — refusing" >&2
exit 64
GH
chmod +x "$BIN/gh"
REAL_GH=$(command -v gh 2>/dev/null || true)
export PATH="$BIN:$PATH"

echo "usage · --help and unknown flags"
out=$(node "$READER" --help); rc=$?
check "help exits 0" "$rc" "0"
contains "help names report-only" "$out" "report-only"
out=$(node "$READER" --evidence /tmp/x.json --repo acme/app --pr 1 --expected-head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --claim-id issue-1-x --issue 1 --branch feat/1-x 2>&1); rc=$?
check "caller-supplied evidence is refused" "$rc" "2"
contains "names the authority rule" "$out" "never takes caller-supplied JSON"
out=$(node "$READER" --fixture 2>&1); rc=$?
check "fixture flag is refused" "$rc" "2"
out=$(node "$READER" --unknown 2>&1); rc=$?
check "unknown flag exits 2" "$rc" "2"

new_repo() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root"
  git init -q --bare "$root/origin"
  git clone -q "$root/origin" "$root/canon" 2>/dev/null
  git -C "$root/canon" config "url.$root/origin.insteadOf" https://github.com/acme/app.git
  git -C "$root/canon" remote set-url origin https://github.com/acme/app.git
  (
    cd "$root/canon" || exit 1
    printf 'init\n' > README
    git add -A && git commit -qm init && git branch -M main && git push -q -u origin main
  ) >/dev/null 2>&1
}

write_v2_body() {
  local file="$1" claim_id="$2" issue="$3" base="$4" res="$5" branch="$6"
  {
    printf '%s\n' "## Active work" ""
    printf '%s\n' "- Claim schema: gibson.claim/v2"
    printf '%s\n' "- Active-work claim: ${claim_id}"
    printf '%s\n' "- Isolation: dedicated worktree"
    printf '%s\n' "- Issue: #${issue}"
    printf '%s\n' "- Claim scope: scripts/claim.sh"
    printf '%s\n' "- Session: tester@box"
    printf '%s\n' "- Original branch point: ${base}"
    printf '%s\n' "- Reservation commit: ${res}"
  } > "$file"
}

make_reservation() {
  local root="$1" issue="$2" slug="$3"
  local claim_id="issue-${issue}-${slug}"
  local branch="feat/${issue}-${slug}"
  local base res msg
  git -C "$root/canon" worktree add "$root/wt" -b "$branch" origin/main >/dev/null 2>&1
  base=$(git -C "$root/wt" rev-parse HEAD)
  msg=$(printf '%s\n' \
    "chore: reserve issue #${issue} for ${claim_id}" \
    "" \
    "Gibson-Reservation: v1" \
    "Gibson-Claim-ID: ${claim_id}" \
    "Gibson-Issue: #${issue}" \
    "Gibson-Branch: ${branch}")
  git -C "$root/wt" commit --allow-empty -s -q -m "$msg"
  res=$(git -C "$root/wt" rev-parse HEAD)
  git -C "$root/wt" push -q -u origin "$branch"
  write_v2_body "$root/body" "$claim_id" "$issue" "$base" "$res" "$branch"
  printf '%s %s %s\n' "$base" "$res" "$branch"
}

run_reader() {
  local repo_path="$1" pr="$2" head="$3" claim_id="$4" issue="$5" branch="$6"
  shift 6
  node "$READER" \
    --repo acme/app \
    --pr "$pr" \
    --expected-head "$head" \
    --claim-id "$claim_id" \
    --issue "$issue" \
    --branch "$branch" \
    --repo-path "$repo_path" \
    --base main \
    "$@"
}

echo "positive · reservation-only"
new_repo "$ROOT/p1"
read -r _BASE RES BRANCH <<EOF
$(make_reservation "$ROOT/p1" 42 demo)
EOF
export GH_PR_BODY="$ROOT/p1/body"
export GH_PR_HEAD="$RES"
export GH_PR_BRANCH="$BRANCH"
export GH_PR_REPO="acme/app"
export GH_PR_BASE_OID="$_BASE"
out=$(run_reader "$ROOT/p1/wt" 99 "$RES" issue-42-demo 42 "$BRANCH" 2>/dev/null); rc=$?
check "reservation-only reader exits 0" "$rc" "0"
if echo "$out" | grep -q '"verified":true' && echo "$out" | grep -q "$RES"; then
  pos "reservation-only verifies the empty commit"
else
  bad "reservation-only did not verify: $out"
fi
contains "schema id" "$out" "gibson.claim-provenance/v1"
contains "report-only authority" "$out" '"authority":"report-only"'
lacks "no READY key" "$out" '"READY"'
lacks "no APPROVE key" "$out" '"APPROVE"'

echo "positive · reservation plus one implementation commit"
(
  cd "$ROOT/p1/wt" || exit 1
  printf 'impl\n' > impl.txt
  git add impl.txt
  git commit -qs -m "feat(#42): implement"
) >/dev/null 2>&1
IMPL1=$(git -C "$ROOT/p1/wt" rev-parse HEAD)
git -C "$ROOT/p1/wt" push -q origin "$BRANCH"
export GH_PR_HEAD="$IMPL1"
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL1" issue-42-demo 42 "$BRANCH" 2>/dev/null); rc=$?
check "one-impl reader exits 0" "$rc" "0"
if echo "$out" | grep -q "$RES" && echo "$out" | grep -q "$IMPL1" && echo "$out" | grep -q '"verified":true'; then
  pos "one implementation commit stays ordinary beside the reservation"
else
  bad "one-impl classification failed: $out"
fi

echo "positive · reservation plus two same-vendor commits"
(
  cd "$ROOT/p1/wt" || exit 1
  printf 'fix\n' >> impl.txt
  git add impl.txt
  git commit -qs -m "fix(#42): review fix"
) >/dev/null 2>&1
IMPL2=$(git -C "$ROOT/p1/wt" rev-parse HEAD)
git -C "$ROOT/p1/wt" push -q origin "$BRANCH"
export GH_PR_HEAD="$IMPL2"
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" 2>/dev/null); rc=$?
check "two-impl reader exits 0" "$rc" "0"
if echo "$out" | grep -q "$IMPL1" && echo "$out" | grep -q "$IMPL2" && echo "$out" | grep -q '"verified":true'; then
  pos "two same-vendor implementation/fix commits stay ordinary"
else
  bad "two-impl classification failed: $out"
fi

echo "adversarial · duplicate marker"
cp "$ROOT/p1/body" "$ROOT/p1/body.dup"
printf '%s\n' "- Active-work claim: issue-42-demo" >> "$ROOT/p1/body.dup"
export GH_PR_BODY="$ROOT/p1/body.dup"
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'duplicate_marker'; then
  adv "duplicate marker refuses verification"
else
  adv_fail "duplicate marker still verified (rc=$rc): $out"
fi
export GH_PR_BODY="$ROOT/p1/body"

echo "adversarial · fork PR"
export GH_PR_CROSS=true
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'fork_pr'; then
  adv "fork PR refuses verification"
else
  adv_fail "fork PR still verified (rc=$rc): $out"
fi
unset GH_PR_CROSS

echo "adversarial · truncated body"
export GH_PR_TRUNCATED=1
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
if [[ "$rc" -ne 0 ]]; then
  adv "truncated API body refuses verification"
else
  adv_fail "truncated body still verified: $out"
fi
unset GH_PR_TRUNCATED

echo "adversarial · unstable head"
export GH_PR_DRIFT=1
export GH_PR_HEAD_DRIFT="$IMPL1"
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'unstable_head|head_mismatch'; then
  adv "head drift refuses verification"
else
  adv_fail "head drift still verified (rc=$rc): $out"
fi
unset GH_PR_DRIFT GH_PR_HEAD_DRIFT
export GH_PR_HEAD="$IMPL2"

echo "adversarial · missing login"
export GH_NO_LOGIN=1
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'login_ambiguity'; then
  adv "missing GitHub login refuses verification"
else
  adv_fail "missing login still verified (rc=$rc): $out"
fi
unset GH_NO_LOGIN

echo "adversarial · truncated commit payload"
export GH_TRUNCATED_COMMIT=1
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'truncated_api|unreadable_object'; then
  adv "truncated commit payload refuses verification"
else
  adv_fail "truncated commit still verified (rc=$rc): $out"
fi
unset GH_TRUNCATED_COMMIT

echo "adversarial · --require-verified-reservation on historical-style body"
new_repo "$ROOT/hist"
git -C "$ROOT/hist/canon" worktree add "$ROOT/hist/wt" -b feat/256-old origin/main >/dev/null 2>&1
git -C "$ROOT/hist/wt" commit --allow-empty -s -q -m "chore: reserve issue #256 for issue-256-old"
OLD=$(git -C "$ROOT/hist/wt" rev-parse HEAD)
git -C "$ROOT/hist/wt" push -q -u origin feat/256-old
printf '%s\n' "## Active work" "- Active-work claim: issue-256-old" "- Issue: #256" "- Claim scope: x" > "$ROOT/hist/body"
export GH_PR_BODY="$ROOT/hist/body"
export GH_PR_HEAD="$OLD"
export GH_PR_BRANCH="feat/256-old"
GH_PR_BASE_OID=$(git -C "$ROOT/hist/wt" rev-parse HEAD^)
export GH_PR_BASE_OID
out=$(run_reader "$ROOT/hist/wt" 272 "$OLD" issue-256-old 256 feat/256-old --require-verified-reservation "$OLD" 2>/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q '"reservation":null'; then
  adv "v1-less historical body is not a verified reservation"
else
  adv_fail "v1-less body verified (rc=$rc): $out"
fi

echo "exact-diff · forged body original cannot expand the live introduced range"
new_repo "$ROOT/forge"
git -C "$ROOT/forge/canon" worktree add "$ROOT/forge/wt" -b feat/42-forge origin/main >/dev/null 2>&1
ANCESTOR=$(git -C "$ROOT/forge/wt" rev-parse HEAD)
(
  cd "$ROOT/forge/wt" || exit 1
  printf 'already-on-main\n' > extra.txt
  git add extra.txt
  git commit -qs -m "extra already on main"
) >/dev/null 2>&1
EXTRA=$(git -C "$ROOT/forge/wt" rev-parse HEAD)
msg=$(printf '%s\n' \
  "chore: reserve issue #42 for issue-42-demo" \
  "" \
  "Gibson-Reservation: v1" \
  "Gibson-Claim-ID: issue-42-demo" \
  "Gibson-Issue: #42" \
  "Gibson-Branch: feat/42-forge")
git -C "$ROOT/forge/wt" commit --allow-empty -s -q -m "$msg"
FORGE_RES=$(git -C "$ROOT/forge/wt" rev-parse HEAD)
git -C "$ROOT/forge/wt" push -q origin feat/42-forge
# Live GitHub base is EXTRA (already on main). Body forges original=ANCESTOR,
# which would pull EXTRA into the introduced set if the body chose the range.
write_v2_body "$ROOT/forge/body" issue-42-demo 42 "$ANCESTOR" "$FORGE_RES" feat/42-forge
export GH_PR_BODY="$ROOT/forge/body"
export GH_PR_HEAD="$FORGE_RES"
export GH_PR_BRANCH="feat/42-forge"
export GH_PR_BASE_OID="$EXTRA"
out=$(run_reader "$ROOT/forge/wt" 99 "$FORGE_RES" issue-42-demo 42 feat/42-forge 2>/dev/null); rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | node -e '
  let s=""; process.stdin.on("data", d => s += d); process.stdin.on("end", () => {
    let j;
    try { j = JSON.parse(s); } catch { process.exit(2); }
    const extra = process.argv[1];
    const impl = (j.implementation || []).map((c) => c.sha);
    const bag = new Set([...(j.reasons || []), ...((j.unverified || []).flatMap((u) => u.reasons || []))]);
    const ok = j.reservation === null && bag.has("wrong_parent") && !impl.includes(extra);
    process.exit(ok ? 0 : 1);
  });
' "$EXTRA"; then
  adv "forged body original cannot expand the live introduced range"
else
  adv_fail "forged original did not fail closed with wrong_parent (rc=$rc): $out"
fi

echo "exact-diff · missing original parent with coinciding trees is unreadable"
new_repo "$ROOT/shallow"
read -r SHALLOW_BASE SHALLOW_RES SHALLOW_BRANCH <<EOF
$(make_reservation "$ROOT/shallow" 42 shallow)
EOF
MISSING_ORIG="0000000000000000000000000000000000000001"
write_v2_body "$ROOT/shallow/body" issue-42-shallow 42 "$MISSING_ORIG" "$SHALLOW_RES" "$SHALLOW_BRANCH"
export GH_PR_BODY="$ROOT/shallow/body"
export GH_PR_HEAD="$SHALLOW_RES"
export GH_PR_BRANCH="$SHALLOW_BRANCH"
export GH_PR_BASE_OID="$SHALLOW_BASE"
out=$(run_reader "$ROOT/shallow/wt" 99 "$SHALLOW_RES" issue-42-shallow 42 "$SHALLOW_BRANCH" 2>/dev/null); rc=$?
if echo "$out" | grep -q '"verified":true'; then
  adv_fail "missing original parent still verified (rc=$rc): $out"
elif echo "$out" | grep -q 'unreadable_object'; then
  adv "missing original parent with coinciding trees reports unreadable_object"
else
  adv_fail "missing original parent did not report unreadable_object (rc=$rc): $out"
fi

echo "exact-diff · writer predicate refuses stable CLOSED; report-only may read it"
export GH_PR_BODY="$ROOT/p1/body"
export GH_PR_HEAD="$IMPL2"
export GH_PR_BRANCH="$BRANCH"
export GH_PR_BASE_OID="$_BASE"
export GH_PR_STATE=CLOSED
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q '"reservation":null'; then
  adv "writer predicate refuses a stable CLOSED snapshot"
else
  adv_fail "writer predicate accepted stable CLOSED (rc=$rc): $out"
fi
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" 2>/dev/null); rc=$?
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"verified":true'; then
  adv "report-only may inspect a stable CLOSED snapshot"
else
  adv_fail "report-only refused stable CLOSED (rc=$rc): $out"
fi
unset GH_PR_STATE

echo "exact-diff · reservation already on the live base is not verified"
new_repo "$ROOT/onbase"
git -C "$ROOT/onbase/canon" worktree add "$ROOT/onbase/wt" -b feat/42-onbase origin/main >/dev/null 2>&1
ONBASE_PARENT=$(git -C "$ROOT/onbase/wt" rev-parse HEAD)
msg=$(printf '%s\n' \
  "chore: reserve issue #42 for issue-42-demo" \
  "" \
  "Gibson-Reservation: v1" \
  "Gibson-Claim-ID: issue-42-demo" \
  "Gibson-Issue: #42" \
  "Gibson-Branch: feat/42-onbase")
git -C "$ROOT/onbase/wt" commit --allow-empty -s -q -m "$msg"
ONBASE_RES=$(git -C "$ROOT/onbase/wt" rev-parse HEAD)
git -C "$ROOT/onbase/wt" push -q origin feat/42-onbase
write_v2_body "$ROOT/onbase/body" issue-42-demo 42 "$ONBASE_PARENT" "$ONBASE_RES" feat/42-onbase
export GH_PR_BODY="$ROOT/onbase/body"
export GH_PR_HEAD="$ONBASE_RES"
export GH_PR_BRANCH="feat/42-onbase"
export GH_PR_BASE_OID="$ONBASE_RES"
out=$(run_reader "$ROOT/onbase/wt" 99 "$ONBASE_RES" issue-42-demo 42 feat/42-onbase --require-verified-reservation "$ONBASE_RES" 2>/dev/null); rc=$?
if echo "$out" | grep -q '"verified":true'; then
  adv_fail "reservation already on live base still verified: $out"
elif [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'reservation_not_in_history|rebased_reservation'; then
  adv "reservation already on the live base is not verified"
else
  adv_fail "reservation already on live base was not fail-closed (rc=$rc): $out"
fi

echo "exact-diff · mismatched live PR number is rejected"
export GH_PR_BODY="$ROOT/p1/body"
export GH_PR_HEAD="$IMPL2"
export GH_PR_BRANCH="$BRANCH"
export GH_PR_BASE_OID="$_BASE"
export GH_PR_JSON_NUMBER=100
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
unset GH_PR_JSON_NUMBER
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'binding_mismatch'; then
  adv "mismatched live PR number is rejected"
else
  adv_fail "mismatched PR number still verified (rc=$rc): $out"
fi

echo "exact-diff · mismatched live head branch is rejected"
export GH_PR_BRANCH="feat/copied-other"
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
export GH_PR_BRANCH="$BRANCH"
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'binding_mismatch'; then
  adv "mismatched live head branch is rejected"
else
  adv_fail "mismatched head branch still verified (rc=$rc): $out"
fi

echo "exact-diff · mismatched live base ref is rejected"
export GH_PR_BASE_REF=develop
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
unset GH_PR_BASE_REF
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'binding_mismatch'; then
  adv "mismatched live base ref is rejected"
else
  adv_fail "mismatched base ref still verified (rc=$rc): $out"
fi

echo "exact-diff · mismatched live base repository is rejected"
export GH_PR_JSON_REPO="other/fork"
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
unset GH_PR_JSON_REPO
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'binding_mismatch|fork_pr'; then
  adv "mismatched live base repository is rejected"
else
  adv_fail "mismatched base repository still verified (rc=$rc): $out"
fi

echo "exact-diff · production PR URL identity"
url_adv() {
  local name="$1" url="$2"
  export GH_PR_URL="$url"
  out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
  unset GH_PR_URL
  if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'binding_mismatch|unreadable_object'; then
    adv "$name"
  else
    adv_fail "$name still verified (rc=$rc): $out"
  fi
}
url_adv "mismatched URL/JSON PR numbers" "https://github.com/acme/app/pull/100"
url_adv "PR URL .evil suffix" "https://github.com/acme/app/pull/99.evil"
url_adv "PR URL extra path" "https://github.com/acme/app/pull/99/files"
url_adv "PR URL query" "https://github.com/acme/app/pull/99?foo=1"
url_adv "PR URL fragment" "https://github.com/acme/app/pull/99#discussion"
url_adv "nonpositive PR URL number" "https://github.com/acme/app/pull/0"
url_adv "lookalike GitHub host" "https://github.com.evil/acme/app/pull/99"
export GH_PR_URL="https://github.com/acme/app/pull/99"
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" 2>/dev/null); rc=$?
unset GH_PR_URL
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q '"verified":true'; then
  pos "happy exact PR URL remains green without baseRepository"
else
  bad "happy exact PR URL did not verify (rc=$rc): $out"
fi

echo "exact-diff · drifting live base OID is rejected"
rm -f "$ROOT/p1/body.views"
export GH_PR_DRIFT_BASE_OID=1
export GH_PR_BASE_OID_DRIFT="ffffffffffffffffffffffffffffffffffffffff"
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
unset GH_PR_DRIFT_BASE_OID GH_PR_BASE_OID_DRIFT
export GH_PR_BASE_OID="$_BASE"
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'unstable_identity|binding_mismatch|unreadable_object'; then
  adv "drifting live base OID is rejected"
else
  adv_fail "drifting base OID still verified (rc=$rc): $out"
fi

echo "exact-diff · drifting live state is rejected"
rm -f "$ROOT/p1/body.views"
export GH_PR_DRIFT_STATE=1
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
unset GH_PR_DRIFT_STATE
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'unstable_identity|binding_mismatch'; then
  adv "drifting live state is rejected"
else
  adv_fail "drifting state still verified (rc=$rc): $out"
fi

echo "exact-diff · copied reservation on another PR is rejected by live binding"
export GH_PR_JSON_NUMBER=100
export GH_PR_BRANCH="feat/7-other"
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 feat/42-demo --require-verified-reservation "$RES" 2>/dev/null); rc=$?
unset GH_PR_JSON_NUMBER
export GH_PR_BRANCH="$BRANCH"
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'binding_mismatch'; then
  adv "copied reservation on another PR is rejected by live PR/base/branch binding"
else
  adv_fail "copied reservation still verified via trailers only (rc=$rc): $out"
fi

echo "exact-diff · merge second-parent-side commit is ordinary provenance"
new_repo "$ROOT/merge"
read -r MERGE_BASE MERGE_RES MERGE_BRANCH <<EOF
$(make_reservation "$ROOT/merge" 42 merge)
EOF
git -C "$ROOT/merge/wt" checkout -q -b side "$MERGE_BASE"
(
  cd "$ROOT/merge/wt" || exit 1
  printf 'side-work\n' > side.txt
  git add side.txt
  GIT_AUTHOR_NAME="Mark Hinkle" GIT_AUTHOR_EMAIL="mrhinkle@peripety.com" \
    GIT_COMMITTER_NAME="Mark Hinkle" GIT_COMMITTER_EMAIL="mrhinkle@peripety.com" \
    git commit -q -m "feat(#42): merge-side work"
) >/dev/null 2>&1
SIDE=$(git -C "$ROOT/merge/wt" rev-parse HEAD)
git -C "$ROOT/merge/wt" checkout -q "$MERGE_BRANCH"
git -C "$ROOT/merge/wt" merge --no-ff -q -m "merge side" side >/dev/null 2>&1
MERGE_HEAD=$(git -C "$ROOT/merge/wt" rev-parse HEAD)
git -C "$ROOT/merge/wt" push -q origin "$MERGE_BRANCH"
write_v2_body "$ROOT/merge/body" issue-42-merge 42 "$MERGE_BASE" "$MERGE_RES" "$MERGE_BRANCH"
export GH_PR_BODY="$ROOT/merge/body"
export GH_PR_HEAD="$MERGE_HEAD"
export GH_PR_BRANCH="$MERGE_BRANCH"
export GH_PR_BASE_OID="$MERGE_BASE"
out=$(run_reader "$ROOT/merge/wt" 99 "$MERGE_HEAD" issue-42-merge 42 "$MERGE_BRANCH" 2>/dev/null); rc=$?
if echo "$out" | grep -qF "$SIDE" && echo "$out" | grep -q "Mark Hinkle" && echo "$out" | grep -q '"verified":true'; then
  adv "merge second-parent-side commit is ordinary provenance with raw identity"
else
  adv_fail "merge-side commit missing or reservation unverified (rc=$rc): $out"
fi

echo "exact-diff · globally gated fork candidate has nonempty reasons"
export GH_PR_BODY="$ROOT/p1/body"
export GH_PR_HEAD="$IMPL2"
export GH_PR_BRANCH="$BRANCH"
export GH_PR_BASE_OID="$_BASE"
export GH_PR_CROSS=true
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" 2>/dev/null); rc=$?
unset GH_PR_CROSS
if echo "$out" | grep -q 'fork_pr' && echo "$out" | node -e '
  let s=""; process.stdin.on("data", d => s += d); process.stdin.on("end", () => {
    const j = JSON.parse(s);
    const u = (j.unverified || [])[0];
    process.exit(u && Array.isArray(u.reasons) && u.reasons.length > 0 ? 0 : 1);
  });
'; then
  adv "globally gated candidate always has a nonempty reason list"
else
  adv_fail "globally gated candidate lacked reasons: $out"
fi

echo "exact-diff · commit REST sha mismatch is rejected"
export GH_COMMIT_SHA_MISMATCH=1
out=$(run_reader "$ROOT/p1/wt" 99 "$IMPL2" issue-42-demo 42 "$BRANCH" --require-verified-reservation "$RES" 2>/dev/null); rc=$?
unset GH_COMMIT_SHA_MISMATCH
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE 'binding_mismatch|unreadable_object'; then
  adv "commit REST sha mismatch is rejected"
else
  adv_fail "mismatched commit REST sha still verified (rc=$rc): $out"
fi

echo "live historical controls (report-only; skip if gh/network unavailable)"
LIVE_REPO="The-AIE/the-gibson"
LIVE_PATH="$SCRIPT_DIR/../.."
historical_receipt_ok() {
  local rc="$1" json="$2" pr="$3" head="$4"
  [[ "$rc" -eq 0 ]] || return 1
  printf '%s\n' "$json" | node -e '
    let s=""; process.stdin.on("data", d => s += d); process.stdin.on("end", () => {
      let j;
      try { j = JSON.parse(s); } catch { process.exit(1); }
      const pr = Number(process.argv[1]);
      const head = process.argv[2];
      const reasons = Array.isArray(j.reasons) ? j.reasons : [];
      const ok =
        j.schema === "gibson.claim-provenance/v1" &&
        j.authority === "report-only" &&
        j.pr === pr &&
        j.head === head &&
        j.stable === true &&
        j.reservation === null &&
        (reasons.includes("missing_v2_schema") || reasons.includes("missing_marker"));
      process.exit(ok ? 0 : 1);
    });
  ' "$pr" "$head"
}
record_historical_negative() {
  local rc="$1" json="$2" pr="$3" head="$4"
  if historical_receipt_ok "$rc" "$json" "$pr" "$head"; then
    POSITIVE=$((POSITIVE + 1))
    return 0
  fi
  return 1
}
if [[ -n "$REAL_GH" && -x "$REAL_GH" ]] && \
  "$REAL_GH" pr view 272 --repo "$LIVE_REPO" --json number >/dev/null 2>&1; then
  live_one() {
    local pr="$1" head="$2" claim="$3" issue="$4" branch="$5"
    PATH="$(dirname "$REAL_GH"):/usr/bin:/bin" node "$READER" \
      --repo "$LIVE_REPO" --pr "$pr" --expected-head "$head" \
      --claim-id "$claim" --issue "$issue" --branch "$branch" \
      --repo-path "$LIVE_PATH" --base main 2>/dev/null
  }
  live_out=$(live_one 267 d9989c10967393a5b1c8ce50afa9424a8274e582 issue-260-portable-suite-timeout 260 feat/260-portable-suite-timeout); live_rc=$?
  if record_historical_negative "$live_rc" "$live_out" 267 d9989c10967393a5b1c8ce50afa9424a8274e582; then
    ok "live PR #267 report-only: zero verified reservations"
  else
    bad "live PR #267 unexpectedly verified or unreadable (rc=$live_rc): $live_out"
  fi
  live_out=$(live_one 272 675984f77d54b2a46843d8076298473f66b87efc issue-256-sensor-health-current-main 256 feat/256-sensor-health-current-main); live_rc=$?
  if record_historical_negative "$live_rc" "$live_out" 272 675984f77d54b2a46843d8076298473f66b87efc; then
    ok "live PR #272 report-only: zero verified reservations"
  else
    bad "live PR #272 unexpectedly verified or unreadable (rc=$live_rc): $live_out"
  fi
  live_out=$(live_one 270 313127a2e8c53da6890d0ab400c42813a8d14591 issue-260-portable-suite-timeout-bot 260 feat/260-portable-suite-timeout-bot); live_rc=$?
  if record_historical_negative "$live_rc" "$live_out" 270 313127a2e8c53da6890d0ab400c42813a8d14591; then
    ok "live PR #270 report-only: zero verified reservations"
  else
    bad "live PR #270 unexpectedly verified or unreadable (rc=$live_rc): $live_out"
  fi
  live_out=$(live_one 283 f779354d4a9798cbdab1ef10cfa0ad6fa9f54270 issue-271-release-claim-dry-run-target-grok 271 feat/271-release-claim-dry-run-target-grok); live_rc=$?
  if record_historical_negative "$live_rc" "$live_out" 283 f779354d4a9798cbdab1ef10cfa0ad6fa9f54270; then
    ok "live PR #283 report-only: zero verified reservations"
  else
    bad "live PR #283 unexpectedly verified or unreadable (rc=$live_rc): $live_out"
  fi
  printf '%s\n' "$live_out" > "$ROOT/live-283.receipt"
  echo "  live-receipt wrote $ROOT/live-283.receipt"
else
  echo "  note — live GitHub historical controls skipped (gh pr view unavailable)"
fi

echo "exact-diff · fake-live failure cannot increment the historical positive tally"
FAKE_LIVE_JSON='{"schema":"gibson.claim-provenance/v1","authority":"report-only","pr":267,"head":"d9989c10967393a5b1c8ce50afa9424a8274e582","stable":true,"reservation":null,"reasons":["unreadable_object"]}'
HIST_POS_BEFORE=$POSITIVE
if record_historical_negative 1 "$FAKE_LIVE_JSON" 267 d9989c10967393a5b1c8ce50afa9424a8274e582; then
  adv_fail "exit-1 live receipt incremented the historical positive tally"
elif [[ "$POSITIVE" -eq "$HIST_POS_BEFORE" ]]; then
  adv "fake-live failure cannot increment the historical positive tally"
else
  adv_fail "positive tally changed on an exit-1 historical receipt"
fi

echo
echo "positive=$POSITIVE adversarial=$ADVERSARIAL"
echo "claim-provenance.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
