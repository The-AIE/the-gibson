#!/usr/bin/env bash
# release-preflight.test.sh — sensors for the pre-merge verdict
#
# WHAT IT DOES
#   Runs release-preflight.sh against canned pull requests by putting a fake
#   `gh` on PATH that replays a JSON fixture. No network, no GitHub.
#
# WHY
#   L-013 / L-015 / L-021 / L-033 are judgement calls the release hat got wrong
#   repeatedly. Encoding them in a script only helps if the script's judgement
#   itself is pinned.
#
# USAGE
#   scripts/tests/release-preflight.test.sh
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
PREFLIGHT="$SCRIPT_DIR/../release-preflight.sh"
PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-preflight-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh: `repo view` names a repo, `pr view` replays $GH_FIXTURE.
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "pr view") cat "$GH_FIXTURE" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

# $1 name, then overrides as jq assignments applied to the green baseline.
fixture() {
  local name="$1"; shift
  local f="$ROOT/$name.json"
  jq "$@" > "$f" <<'BASE'
{
  "number": 1, "title": "feat: thing", "isDraft": false, "mergeable": "MERGEABLE",
  "body": "Closes #28",
  "author": {"login": "builder-bot"}, "reviewDecision": "APPROVED",
  "headRefOid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "labels": [{"name": "tier-b"}], "closingIssuesReferences": [{"number": 28}],
  "statusCheckRollup": [
    {"__typename": "CheckRun", "name": "gate", "conclusion": "SUCCESS", "steps": [{"name": "lint"}]}
  ],
  "reviews": [], "comments": []
}
BASE
  echo "$f"
}

run() { GH_FIXTURE="$1" "$PREFLIGHT" 1 --repo acme/app ${2:-} 2>&1; }

echo "baseline · a green, approved, tier-B PR is READY"
f=$(fixture green '.')
out=$(run "$f"); rc=$?
check "exit 0" "$rc" "0"
contains "verdict" "$out" "READY"

echo "L-013 · a partial ship that still closes its issue is BLOCKED"
out=$(run "$f" --partial); rc=$?
check "exit 1" "$rc" "1"
contains "names the issue GitHub will close" "$out" "close #28"
contains "remediation mentions retitle" "$out" "Retitle"
f_open=$(fixture nonclosing '.closingIssuesReferences = [] | .body = "Related: #28 — slice one" | .title = "feat: slice (related #28)"')
out=$(run "$f_open" --partial); rc=$?
check "partial that closes nothing is READY" "$rc" "0"

echo "L-013/L-025 · Related-only body + fix(#N) title auto-detected without --partial"
f_rel=$(fixture related_fix '.title = "fix(#28): slice one" | .body = "Related: #28\n\nShips the first slice only." | .closingIssuesReferences = [{"number": 28}]')
out=$(run "$f_rel"); rc=$?
check "Related-only + close refs exits 1 without --partial" "$rc" "1"
contains "names close target" "$out" "close #28"

echo "L-025 · Related-only + fix title, no closingIssuesReferences yet"
f_title=$(fixture related_title_only '.title = "fix(#28): slice one" | .body = "Related: #28" | .closingIssuesReferences = []')
out=$(run "$f_title"); rc=$?
check "title close keyword alone blocks partial" "$rc" "1"
contains "cites L-025" "$out" "L-025"
contains "mentions retitle" "$out" "retitle"

echo "L-013 · genuine Closes #N full ship passes untouched"
f_full=$(fixture full_close '.title = "fix(#28): done" | .body = "Closes #28" | .closingIssuesReferences = [{"number": 28}]')
out=$(run "$f_full"); rc=$?
check "full-close PR is READY" "$rc" "0"
contains "verdict READY" "$out" "READY"

echo "L-015 · same-author VERDICT: APPROVE is not a formal review"
f_same=$(fixture same_author '.reviewDecision = "" |
  .comments = [{"author": {"login": "builder-bot"}, "body": "six lenses clear\n\nVERDICT: APPROVE", "createdAt": "2026-08-02T15:00:00Z"}]')
out=$(run "$f_same"); rc=$?
check "exit 4 (ADMIN-CANDIDATE)" "$rc" "4"
contains "explains self-approval block" "$out" "GitHub blocks self-approval"
contains "prefers a cross-vendor identity" "$out" "REVIEWER_CMD"
contains "prints the checklist" "$out" "security CLEAR"

f_other=$(fixture other_reviewer '.reviewDecision = "" |
  .comments = [{"author": {"login": "reviewer-bot"}, "body": "VERDICT: APPROVE", "createdAt": "2026-08-02T15:00:00Z"}]')
out=$(run "$f_other"); rc=$?
check "independent VERDICT: APPROVE is READY" "$rc" "0"

f_reject=$(fixture rejected '.reviewDecision = "" |
  .comments = [{"author": {"login": "reviewer-bot"}, "body": "VERDICT: REQUEST_CHANGES", "createdAt": "2026-08-02T15:00:00Z"}]')
out=$(run "$f_reject"); rc=$?
check "REQUEST_CHANGES blocks" "$rc" "1"

f_none=$(fixture unreviewed '.reviewDecision = ""')
out=$(run "$f_none"); rc=$?
check "no review at all blocks (fail closed)" "$rc" "1"
contains "cites Law 5" "$out" "Law 5"

echo "#61 · chronological verdict stream — newest wins across reviews and comments"
# Exact PR #57 shape: older comment APPROVE, newer review REQUEST_CHANGES on
# the current head. Array order must not matter — timestamps do.
f_chrono=$(fixture chrono_block '.reviewDecision = "" | .headRefOid = "4ae5b9d12073e8acfd43371ca8af001af4044ea7" |
  .comments = [{
    "author": {"login": "devin-ai-integration"},
    "body": "six lenses clear\n\nVERDICT: APPROVE",
    "createdAt": "2026-08-02T15:06:00Z"
  }] |
  .reviews = [{
    "author": {"login": "codex-reviewer"},
    "body": "blocking findings remain\n\nVERDICT: REQUEST_CHANGES",
    "submittedAt": "2026-08-02T15:34:07Z",
    "commit": {"oid": "4ae5b9d12073e8acfd43371ca8af001af4044ea7"}
  }]')
out=$(run "$f_chrono"); rc=$?
check "older comment APPROVE + newer review REQUEST_CHANGES is BLOCKED" "$rc" "1"
contains "names REQUEST_CHANGES" "$out" "REQUEST_CHANGES"
contains "names the newer reviewer" "$out" "codex-reviewer"

# Inverse order in the JSON arrays: reviews first would have won under the old
# concatenate-then-last logic; with timestamps the older review APPROVE loses.
f_chrono_ready=$(fixture chrono_ready '.reviewDecision = "" | .headRefOid = "abc123head000000000000000000000000000001" |
  .reviews = [{
    "author": {"login": "old-reviewer"},
    "body": "VERDICT: REQUEST_CHANGES",
    "submittedAt": "2026-08-02T14:00:00Z",
    "commit": {"oid": "abc123head000000000000000000000000000001"}
  }] |
  .comments = [{
    "author": {"login": "reviewer-bot"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T16:00:00Z"
  }]')
out=$(run "$f_chrono_ready"); rc=$?
check "newer comment APPROVE after older review REQUEST_CHANGES is READY" "$rc" "0"

echo "#61 · formal APPROVED must not short-circuit a newer REQUEST_CHANGES"
# reviewDecision=APPROVED is the older formal signal; a newer comment
# VERDICT: REQUEST_CHANGES must still block (release-blocking false-green).
f_formal_stale=$(fixture formal_stale '.reviewDecision = "APPROVED" | .headRefOid = "cccccccccccccccccccccccccccccccccccccccc" |
  .reviews = [{
    "author": {"login": "old-approver"},
    "state": "APPROVED",
    "body": "looks good",
    "submittedAt": "2026-08-02T12:00:00Z",
    "commit": {"oid": "cccccccccccccccccccccccccccccccccccccccc"}
  }] |
  .comments = [{
    "author": {"login": "codex-reviewer"},
    "body": "new findings\n\nVERDICT: REQUEST_CHANGES",
    "createdAt": "2026-08-02T18:00:00Z"
  }]')
out=$(run "$f_formal_stale"); rc=$?
check "reviewDecision=APPROVED + newer comment REQUEST_CHANGES is BLOCKED" "$rc" "1"
contains "names REQUEST_CHANGES from stream" "$out" "REQUEST_CHANGES"
contains "names the newer commenter" "$out" "codex-reviewer"
# Must not claim READY just because formal approval exists.
if echo "$out" | grep -qF "READY"; then bad "must not report READY when newer REQUEST_CHANGES exists"; else ok "does not report READY under stale formal approval"; fi

echo "#61 · malformed/null timestamps and authorless events fail closed"
# Null-time APPROVE must never outrank a valid REQUEST_CHANGES.
f_null_time=$(fixture null_time '.reviewDecision = "" | .headRefOid = "dddddddddddddddddddddddddddddddddddddddd" |
  .reviews = [{
    "author": {"login": "bad-clock"},
    "body": "VERDICT: APPROVE",
    "submittedAt": null,
    "commit": {"oid": "dddddddddddddddddddddddddddddddddddddddd"}
  }] |
  .comments = [{
    "author": {"login": "good-reviewer"},
    "body": "VERDICT: REQUEST_CHANGES",
    "createdAt": "2026-08-02T17:00:00Z"
  }]')
out=$(run "$f_null_time"); rc=$?
check "null-time APPROVE does not outrank valid REQUEST_CHANGES" "$rc" "1"
contains "selects the valid REQUEST_CHANGES" "$out" "REQUEST_CHANGES"

# Empty/malformed timestamps dropped entirely; only formal fallback remains.
f_all_bad_time=$(fixture all_bad_time '.reviewDecision = "" |
  .reviews = [{
    "author": {"login": "ghost"},
    "body": "VERDICT: APPROVE",
    "submittedAt": "",
    "commit": {"oid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  }] |
  .comments = [{
    "author": {"login": "ghost2"},
    "body": "VERDICT: APPROVE",
    "createdAt": "not-a-timestamp"
  }]')
out=$(run "$f_all_bad_time"); rc=$?
check "only malformed timestamps with empty reviewDecision is BLOCKED" "$rc" "1"
contains "fail closed without usable event" "$out" "Law 5"

# Authorless APPROVE never counts as independent.
f_no_author=$(fixture no_author '.reviewDecision = "" |
  .comments = [{
    "author": null,
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T16:00:00Z"
  }]')
out=$(run "$f_no_author"); rc=$?
check "authorless APPROVE is BLOCKED (not independent)" "$rc" "1"
contains "fail closed without usable independent APPROVE" "$out" "Law 5"

# Equal timestamps: REQUEST_CHANGES wins regardless of source array order.
f_tie_rc=$(fixture tie_rc '.reviewDecision = "" | .headRefOid = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" |
  .comments = [{
    "author": {"login": "commenter"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T16:00:00Z"
  }] |
  .reviews = [{
    "author": {"login": "reviewer"},
    "body": "VERDICT: REQUEST_CHANGES",
    "submittedAt": "2026-08-02T16:00:00Z",
    "commit": {"oid": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}
  }]')
out=$(run "$f_tie_rc"); rc=$?
check "equal-time REQUEST_CHANGES beats APPROVE (review after comment in arrays)" "$rc" "1"
contains "tie prefers REQUEST_CHANGES" "$out" "REQUEST_CHANGES"

f_tie_rc2=$(fixture tie_rc2 '.reviewDecision = "" | .headRefOid = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" |
  .reviews = [{
    "author": {"login": "reviewer"},
    "body": "VERDICT: APPROVE",
    "submittedAt": "2026-08-02T16:00:00Z",
    "commit": {"oid": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}
  }] |
  .comments = [{
    "author": {"login": "commenter"},
    "body": "VERDICT: REQUEST_CHANGES",
    "createdAt": "2026-08-02T16:00:00Z"
  }]')
out=$(run "$f_tie_rc2"); rc=$?
check "equal-time REQUEST_CHANGES beats APPROVE (comment after review in arrays)" "$rc" "1"
contains "tie prefers REQUEST_CHANGES inverse order" "$out" "REQUEST_CHANGES"

echo "#61 · formal review state modeled as timestamped event; head binding holds"
# Formal state APPROVED with matching head and no body VERDICT is READY.
f_formal_event=$(fixture formal_event '.reviewDecision = "" | .headRefOid = "ffffffffffffffffffffffffffffffffffffffff" |
  .reviews = [{
    "author": {"login": "formal-bot"},
    "state": "APPROVED",
    "body": "lgtm",
    "submittedAt": "2026-08-02T16:00:00Z",
    "commit": {"oid": "ffffffffffffffffffffffffffffffffffffffff"}
  }]')
out=$(run "$f_formal_event"); rc=$?
check "formal state APPROVED on current head is READY" "$rc" "0"

echo "#61 P1 · timestamp validation requires a complete parseable ISO instant"
# Prefix-only validators accept "9999-99-99Tbogus" and can sort it above real
# evidence — a READY false-green. Require a full accepted timestamp.
f_bogus_ts=$(fixture bogus_ts '.reviewDecision = "" | .headRefOid = "1111111111111111111111111111111111111111" |
  .reviews = [{
    "author": {"login": "bogus-clock"},
    "state": "APPROVED",
    "body": "looks fine\n\nVERDICT: APPROVE",
    "submittedAt": "9999-99-99Tbogus",
    "commit": {"oid": "1111111111111111111111111111111111111111"}
  }] |
  .comments = [{
    "author": {"login": "good-reviewer"},
    "body": "still blocked\n\nVERDICT: REQUEST_CHANGES",
    "createdAt": "2026-08-02T17:00:00Z"
  }]')
out=$(run "$f_bogus_ts"); rc=$?
check "bogus prefix timestamp APPROVE does not outrank valid REQUEST_CHANGES" "$rc" "1"
contains "selects valid REQUEST_CHANGES over bogus-ts APPROVE" "$out" "REQUEST_CHANGES"
contains "names the valid reviewer" "$out" "good-reviewer"
if echo "$out" | grep -qF "READY"; then bad "must not report READY when only valid event is REQUEST_CHANGES"; else ok "does not report READY under bogus-ts APPROVE"; fi

# Sole event is a prefix-looking but incomplete timestamp: fail closed, not READY.
f_only_bogus=$(fixture only_bogus '.reviewDecision = "" | .headRefOid = "1111111111111111111111111111111111111111" |
  .reviews = [{
    "author": {"login": "bogus-clock"},
    "body": "VERDICT: APPROVE",
    "submittedAt": "9999-99-99Tbogus",
    "commit": {"oid": "1111111111111111111111111111111111111111"}
  }]')
out=$(run "$f_only_bogus"); rc=$?
check "sole incomplete timestamp APPROVE is BLOCKED (fail closed)" "$rc" "1"
if echo "$out" | grep -qF "READY"; then bad "incomplete timestamp must not yield READY"; else ok "incomplete-ts sole APPROVE is not READY"; fi

# Incomplete fractional / missing timezone forms are not accepted either.
f_incomplete_iso=$(fixture incomplete_iso '.reviewDecision = "" |
  .comments = [{
    "author": {"login": "half-clock"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T15:00:00"
  }]')
out=$(run "$f_incomplete_iso"); rc=$?
check "ISO prefix without timezone is not a complete accepted timestamp" "$rc" "1"

echo "#61 P1 · impossible calendar dates must not normalize under fromdateiso8601"
# jq fromdateiso8601 turns 9999-02-31 into 9999-03-03. A regex+parse gate then
# lets that "future" APPROVE sort above a real 2026 REQUEST_CHANGES → READY.
# Strict civil round-trip must treat impossible dates as malformed.
f_imposs_date=$(fixture imposs_date '.reviewDecision = "" | .headRefOid = "1111111111111111111111111111111111111111" |
  .comments = [
    {
      "author": {"login": "good-reviewer"},
      "body": "still blocked\n\nVERDICT: REQUEST_CHANGES",
      "createdAt": "2026-08-02T17:00:00Z"
    },
    {
      "author": {"login": "bogus-calendar"},
      "body": "looks fine\n\nVERDICT: APPROVE",
      "createdAt": "9999-02-31T17:00:00Z"
    }
  ]')
out=$(run "$f_imposs_date"); rc=$?
check "impossible calendar APPROVE does not outrank valid REQUEST_CHANGES" "$rc" "1"
contains "selects valid REQUEST_CHANGES over imposs-date APPROVE" "$out" "REQUEST_CHANGES"
contains "names the valid reviewer under imposs-date" "$out" "good-reviewer"
if echo "$out" | grep -qF "READY"; then bad "must not report READY when only valid event is REQUEST_CHANGES"; else ok "does not report READY under imposs-date APPROVE"; fi
if echo "$out" | grep -qF "bogus-calendar"; then bad "impossible-date APPROVE must not be selected as the winning event"; else ok "impossible-date author is not the winning event"; fi

# Sole impossible-date formal APPROVED: malformed formal, not READY via fallback.
f_only_imposs=$(fixture only_imposs '.reviewDecision = "APPROVED" | .headRefOid = "1111111111111111111111111111111111111111" |
  .reviews = [{
    "author": {"login": "bogus-calendar"},
    "state": "APPROVED",
    "body": "VERDICT: APPROVE",
    "submittedAt": "9999-02-31T17:00:00Z",
    "commit": {"oid": "1111111111111111111111111111111111111111"}
  }]')
out=$(run "$f_only_imposs"); rc=$?
check "sole impossible calendar formal APPROVED is BLOCKED" "$rc" "1"
if echo "$out" | grep -qF "READY"; then bad "impossible calendar formal must not yield READY"; else ok "impossible-date sole formal is not READY"; fi

# Apr 31 / non-leap Feb 29 are also impossible (not merely "odd").
f_apr31=$(fixture apr31 '.reviewDecision = "" |
  .comments = [{
    "author": {"login": "apr31"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-04-31T12:00:00Z"
  }]')
out=$(run "$f_apr31"); rc=$?
check "April 31 is not a valid calendar date" "$rc" "1"
if echo "$out" | grep -qF "READY"; then bad "Apr 31 APPROVE must not be READY"; else ok "Apr 31 APPROVE is not READY"; fi

f_nonleap=$(fixture nonleap '.reviewDecision = "" |
  .comments = [{
    "author": {"login": "nonleap"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2023-02-29T12:00:00Z"
  }]')
out=$(run "$f_nonleap"); rc=$?
check "non-leap Feb 29 is not a valid calendar date" "$rc" "1"
if echo "$out" | grep -qF "READY"; then bad "2023-02-29 APPROVE must not be READY"; else ok "non-leap Feb 29 is not READY"; fi

echo "#61 P1 · boundary-valid leap/date/offset instants must still be accepted"
# Round-trip validation must not over-reject real GitHub-shaped instants.
f_leap=$(fixture leap_day '.reviewDecision = "" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .comments = [{
    "author": {"login": "leap-reviewer"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2024-02-29T12:00:00Z"
  }]')
out=$(run "$f_leap"); rc=$?
check "leap day 2024-02-29T12:00:00Z APPROVE is READY" "$rc" "0"
contains "names leap-day reviewer" "$out" "leap-reviewer"

f_eom=$(fixture end_of_months '.reviewDecision = "" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .comments = [{
    "author": {"login": "eom-reviewer"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-01-31T23:59:59Z"
  }]')
out=$(run "$f_eom"); rc=$?
check "Jan 31 end-of-month Z instant is READY" "$rc" "0"

f_apr30=$(fixture apr30 '.reviewDecision = "" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .comments = [{
    "author": {"login": "apr30-reviewer"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-04-30T12:00:00Z"
  }]')
out=$(run "$f_apr30"); rc=$?
check "Apr 30 valid end-of-month is READY" "$rc" "0"

f_frac=$(fixture frac_z '.reviewDecision = "" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .comments = [{
    "author": {"login": "frac-reviewer"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T17:00:00.123Z"
  }]')
out=$(run "$f_frac"); rc=$?
check "fractional-second Z instant is READY" "$rc" "0"

# Offset forms are accepted complete ISO instants (wall calendar + offset).
# jq fromdateiso8601 often rejects ±HH:MM — must not over-reject on that alone.
f_off_plus=$(fixture off_plus '.reviewDecision = "" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .comments = [{
    "author": {"login": "offset-plus"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T12:00:00+05:30"
  }]')
out=$(run "$f_off_plus"); rc=$?
check "valid +05:30 offset APPROVE is READY" "$rc" "0"
contains "names +05:30 reviewer" "$out" "offset-plus"

f_off_minus=$(fixture off_minus '.reviewDecision = "" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .comments = [{
    "author": {"login": "offset-minus"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-02-28T23:59:59-05:00"
  }]')
out=$(run "$f_off_minus"); rc=$?
check "valid -05:00 offset APPROVE is READY" "$rc" "0"
contains "names -05:00 reviewer" "$out" "offset-minus"

f_off_zulu=$(fixture off_zulu '.reviewDecision = "" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .comments = [{
    "author": {"login": "offset-zulu"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T15:00:00+00:00"
  }]')
out=$(run "$f_off_zulu"); rc=$?
check "valid +00:00 offset APPROVE is READY" "$rc" "0"

# Impossible wall + otherwise-valid offset still blocks (no normalize-via-offset).
f_imposs_off=$(fixture imposs_off '.reviewDecision = "" |
  .comments = [{
    "author": {"login": "imposs-off"},
    "body": "VERDICT: APPROVE",
    "createdAt": "9999-02-31T17:00:00+00:00"
  }]')
out=$(run "$f_imposs_off"); rc=$?
check "impossible calendar with +00:00 offset is BLOCKED" "$rc" "1"
if echo "$out" | grep -qF "READY"; then bad "imposs+offset must not be READY"; else ok "imposs+offset is not READY"; fi

echo "#61 P1 · chronological sort normalizes offsets and fractional spellings"
# Raw .at text sort is a false-green: wall "17:00+05:30" sorts after "16:00Z"
# even though 17:00+05:30 is 11:30Z (older). Normalize to true UTC instants.
f_off_chrono=$(fixture off_chrono '.reviewDecision = "" | .headRefOid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" |
  .reviews = [{
    "author": {"login": "older-offset-approver"},
    "state": "APPROVED",
    "body": "lgtm",
    "submittedAt": "2026-08-02T17:00:00+05:30",
    "commit": {"oid": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
  }] |
  .comments = [{
    "author": {"login": "newer-zulu-blocker"},
    "body": "still blocked\n\nVERDICT: REQUEST_CHANGES",
    "createdAt": "2026-08-02T16:00:00Z"
  }]')
out=$(run "$f_off_chrono"); rc=$?
check "older +05:30 APPROVE must not beat newer Z REQUEST_CHANGES" "$rc" "1"
contains "names newer REQUEST_CHANGES under offset chrono" "$out" "REQUEST_CHANGES"
contains "names newer-zulu-blocker" "$out" "newer-zulu-blocker"
if echo "$out" | grep -qF "READY"; then bad "offset text-sort must not yield READY"; else ok "offset chrono is not READY"; fi
if echo "$out" | grep -qF "older-offset-approver"; then bad "older offset APPROVE must not win"; else ok "older offset APPROVE is not the winning event"; fi

# Equal true instants spelled with offset vs Z: REQUEST_CHANGES wins by tie precedence.
f_off_tie=$(fixture off_tie '.reviewDecision = "" | .headRefOid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" |
  .reviews = [{
    "author": {"login": "offset-tie-approver"},
    "state": "APPROVED",
    "body": "lgtm",
    "submittedAt": "2026-08-02T17:30:00+05:30",
    "commit": {"oid": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
  }] |
  .comments = [{
    "author": {"login": "zulu-tie-blocker"},
    "body": "VERDICT: REQUEST_CHANGES",
    "createdAt": "2026-08-02T12:00:00Z"
  }]')
out=$(run "$f_off_tie"); rc=$?
check "equal-instant +05:30 APPROVE vs Z REQUEST_CHANGES prefers REQUEST_CHANGES" "$rc" "1"
contains "offset equal-instant prefers REQUEST_CHANGES" "$out" "REQUEST_CHANGES"
contains "names zulu-tie-blocker" "$out" "zulu-tie-blocker"
if echo "$out" | grep -qF "READY"; then bad "equal-instant offset tie must not be READY"; else ok "equal-instant offset tie is not READY"; fi

# Equal true instants with/without trailing .000 fraction spelling.
f_frac_tie=$(fixture frac_tie '.reviewDecision = "" | .headRefOid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" |
  .reviews = [{
    "author": {"login": "frac-tie-approver"},
    "state": "APPROVED",
    "body": "lgtm",
    "submittedAt": "2026-08-02T12:00:00Z",
    "commit": {"oid": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
  }] |
  .comments = [{
    "author": {"login": "frac-tie-blocker"},
    "body": "VERDICT: REQUEST_CHANGES",
    "createdAt": "2026-08-02T12:00:00.000Z"
  }]')
out=$(run "$f_frac_tie"); rc=$?
check "equal-instant Z vs .000Z prefers REQUEST_CHANGES" "$rc" "1"
contains "fraction spelling equal-instant prefers REQUEST_CHANGES" "$out" "REQUEST_CHANGES"
contains "names frac-tie-blocker" "$out" "frac-tie-blocker"
if echo "$out" | grep -qF "READY"; then bad "fraction spelling tie must not be READY"; else ok "fraction spelling tie is not READY"; fi

# Distinct sub-second fractions must order chronologically (not collapse to ties).
f_frac_order=$(fixture frac_order '.reviewDecision = "" | .headRefOid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" |
  .comments = [
    {
      "author": {"login": "early-frac-blocker"},
      "body": "VERDICT: REQUEST_CHANGES",
      "createdAt": "2026-08-02T12:00:00.001Z"
    },
    {
      "author": {"login": "late-frac-approver"},
      "body": "VERDICT: APPROVE",
      "createdAt": "2026-08-02T12:00:00.002Z"
    }
  ]')
out=$(run "$f_frac_order"); rc=$?
check "later fractional APPROVE beats earlier fractional REQUEST_CHANGES" "$rc" "0"
contains "names late-frac-approver" "$out" "late-frac-approver"

echo "#61 P1 · fractional precision policy: 1–9 digits accepted, 10+ malformed"
# Full nanosecond (9 fractional digits) boundary must remain ordered: a later
# 9-digit APPROVE beats an earlier 9-digit REQUEST_CHANGES (no pad-collapse).
f_ns9_order=$(fixture ns9_order '.reviewDecision = "" | .headRefOid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" |
  .comments = [
    {
      "author": {"login": "early-ns9-blocker"},
      "body": "VERDICT: REQUEST_CHANGES",
      "createdAt": "2026-08-02T12:00:00.123456788Z"
    },
    {
      "author": {"login": "late-ns9-approver"},
      "body": "VERDICT: APPROVE",
      "createdAt": "2026-08-02T12:00:00.123456789Z"
    }
  ]')
out=$(run "$f_ns9_order"); rc=$?
check "later 9-digit fractional APPROVE beats earlier 9-digit REQUEST_CHANGES" "$rc" "0"
contains "names late-ns9-approver" "$out" "late-ns9-approver"
if echo "$out" | grep -qF "early-ns9-blocker"; then bad "earlier 9-digit RC must not win"; else ok "earlier 9-digit RC is not the winning event"; fi

# Exact collapse reproducer: older RC .1234567890Z vs newer APPROVE .1234567891Z.
# Accepting unlimited frac then truncating the chrono key to 9 digits made these
# equal, so REQUEST_CHANGES tie-precedence selected the older event. Policy is
# fail-closed: 10+ fractional digits are malformed and never enter the stream.
f_frac10_collapse=$(fixture frac10_collapse '.reviewDecision = "" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .reviews = [
    {
      "author": {"login": "old-rc-10frac"},
      "state": "CHANGES_REQUESTED",
      "body": "",
      "submittedAt": "2026-08-02T12:00:00.1234567890Z",
      "commit": {"oid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    },
    {
      "author": {"login": "new-appr-10frac"},
      "state": "APPROVED",
      "body": "lgtm",
      "submittedAt": "2026-08-02T12:00:00.1234567891Z",
      "commit": {"oid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    }
  ]')
out=$(run "$f_frac10_collapse"); rc=$?
check "10+ fractional digits formal pair is BLOCKED (malformed, not truncate-tie)" "$rc" "1"
contains "names 10+ frac as malformed formal" "$out" "malformed"
if echo "$out" | grep -qF "READY"; then bad "10+ frac formal pair must not READY"; else ok "10+ frac formal pair is not READY"; fi
# Must not select either event as a usable chronological winner via truncate-tie.
if echo "$out" | grep -qE 'VERDICT: (APPROVE|REQUEST_CHANGES).*(old-rc-10frac|new-appr-10frac)'; then
  bad "10+ frac stamps must not enter the sortable event stream"
else
  ok "10+ frac stamps never enter the sortable event stream"
fi

# Sole formal APPROVED with 10 fractional digits: malformed formal, not READY
# via reviewDecision aggregate fallback.
f_only_frac10=$(fixture only_frac10 '.reviewDecision = "APPROVED" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .reviews = [{
    "author": {"login": "overprecise-approver"},
    "state": "APPROVED",
    "body": "lgtm",
    "submittedAt": "2026-08-02T12:00:00.12345678901Z",
    "commit": {"oid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  }]')
out=$(run "$f_only_frac10"); rc=$?
check "sole 10+ fractional formal APPROVED is BLOCKED" "$rc" "1"
contains "names overprecise formal as malformed" "$out" "malformed"
if echo "$out" | grep -qF "READY"; then bad "10+ frac sole formal must not READY via aggregate"; else ok "10+ frac sole formal not recovered via reviewDecision"; fi

# Digits past the ninth never reorder the stream: a 10+ "later" APPROVE comment
# cannot outrank a valid earlier REQUEST_CHANGES (it never enters the stream).
f_frac10_vs_valid=$(fixture frac10_vs_valid '.reviewDecision = "" | .headRefOid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" |
  .comments = [
    {
      "author": {"login": "valid-rc"},
      "body": "VERDICT: REQUEST_CHANGES",
      "createdAt": "2026-08-02T12:00:00.123456789Z"
    },
    {
      "author": {"login": "overprecise-approver"},
      "body": "VERDICT: APPROVE",
      "createdAt": "2026-08-02T12:00:00.1234567891Z"
    }
  ]')
out=$(run "$f_frac10_vs_valid"); rc=$?
check "10+ frac APPROVE cannot outrank valid 9-digit REQUEST_CHANGES" "$rc" "1"
contains "selects valid RC over 10+ frac APPROVE" "$out" "REQUEST_CHANGES"
contains "names valid-rc reviewer" "$out" "valid-rc"
if echo "$out" | grep -qF "overprecise-approver"; then bad "10+ frac APPROVE must not be selected"; else ok "10+ frac APPROVE is not the winning event"; fi
if echo "$out" | grep -qF "READY"; then bad "must not READY when only valid event is REQUEST_CHANGES"; else ok "does not READY under 10+ frac APPROVE"; fi

# Comment-only 10+ frac APPROVE (no formal): drop from stream, fail closed.
f_comment_frac10=$(fixture comment_frac10 '.reviewDecision = "" |
  .comments = [{
    "author": {"login": "comment-10frac"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T12:00:00.1234567890Z"
  }]')
out=$(run "$f_comment_frac10"); rc=$?
check "sole comment APPROVE with 10+ fractional digits is BLOCKED" "$rc" "1"
if echo "$out" | grep -qF "READY"; then bad "comment 10+ frac must not READY"; else ok "comment 10+ frac is not READY"; fi

echo "#61 P1 · malformed verdict-bearing comments hard-block (no drop-then-recover)"
# Exact regression 1: valid formal APPROVED at .123456789Z, later comment
# VERDICT: REQUEST_CHANGES at .1234567891Z (10+ frac = malformed). Must BLOCK
# because later relevant evidence is malformed — never select the older approval.
f_later_malformed_rc=$(fixture later_malformed_rc '.reviewDecision = "APPROVED" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .reviews = [{
    "author": {"login": "formal-approver"},
    "state": "APPROVED",
    "body": "lgtm",
    "submittedAt": "2026-08-02T12:00:00.123456789Z",
    "commit": {"oid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  }] |
  .comments = [{
    "author": {"login": "later-blocker"},
    "body": "VERDICT: REQUEST_CHANGES",
    "createdAt": "2026-08-02T12:00:00.1234567891Z"
  }]')
out=$(run "$f_later_malformed_rc"); rc=$?
check "valid formal APPROVED + later malformed RC comment is BLOCKED" "$rc" "1"
contains "names later malformed RC as malformed evidence" "$out" "malformed"
contains "names later 10+ frac RC stamp in evidence" "$out" "1234567891"
contains "names REQUEST_CHANGES in malformed evidence" "$out" "VERDICT: REQUEST_CHANGES"
if echo "$out" | grep -qF "READY"; then
  bad "must not READY by selecting older formal APPROVED after dropping malformed later RC"
else
  ok "does not READY under older formal + later malformed RC"
fi
# Must not treat the older formal alone as a clear independent approval path.
if echo "$out" | grep -qF "independent identity"; then
  bad "older formal APPROVE must not be selected as gate-clearing when later RC is malformed"
else
  ok "older formal APPROVE is not selected as gate-clearing under later malformed RC"
fi
if echo "$out" | grep -qF "formal-approver"; then
  bad "older formal-approver must not appear as selected winning event under later malformed RC"
else
  ok "older formal-approver is not the selected winning event"
fi

# Exact regression 2: reviews=[], reviewDecision=APPROVED, sole comment
# VERDICT: APPROVE at .1234567890Z must BLOCK — never aggregate-fallback to READY.
f_sole_malformed_approve_agg=$(fixture sole_malformed_approve_agg '.reviewDecision = "APPROVED" | .reviews = [] |
  .comments = [{
    "author": {"login": "comment-approver"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T12:00:00.1234567890Z"
  }]')
out=$(run "$f_sole_malformed_approve_agg"); rc=$?
check "reviewDecision=APPROVED + sole malformed VERDICT: APPROVE comment is BLOCKED" "$rc" "1"
contains "names sole malformed comment as malformed evidence" "$out" "malformed"
contains "names 10+ frac APPROVE stamp in evidence" "$out" "1234567890"
if echo "$out" | grep -qF "READY"; then
  bad "must not READY via reviewDecision aggregate after dropping malformed APPROVE comment"
else
  ok "does not READY via reviewDecision after malformed APPROVE comment"
fi
if echo "$out" | grep -qF "formal GitHub approval present"; then
  bad "must not use reviewDecision aggregate when malformed verdict comment was discarded"
else
  ok "no reviewDecision aggregate recovery after malformed verdict comment"
fi

# Authorless approval comments fail closed (not drop-then-recover via aggregate).
f_authorless_comment_agg=$(fixture authorless_comment_agg '.reviewDecision = "APPROVED" | .reviews = [] |
  .comments = [{
    "author": null,
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T12:00:00.123456789Z"
  }]')
out=$(run "$f_authorless_comment_agg"); rc=$?
check "reviewDecision=APPROVED + authorless VERDICT: APPROVE comment is BLOCKED" "$rc" "1"
contains "names authorless comment as malformed evidence" "$out" "malformed"
contains "names authorless in malformed evidence" "$out" "(authorless)"
if echo "$out" | grep -qF "READY"; then
  bad "authorless APPROVE comment must not READY via reviewDecision aggregate"
else
  ok "authorless APPROVE comment not recovered via reviewDecision"
fi
if echo "$out" | grep -qF "formal GitHub approval present"; then
  bad "authorless APPROVE must not recover via reviewDecision aggregate"
else
  ok "no aggregate recovery after authorless APPROVE comment"
fi

# Ordinary comments without a recognized terminal VERDICT are never evidence.
f_ordinary_bad_ts=$(fixture ordinary_bad_ts '.reviewDecision = "APPROVED" | .reviews = [] |
  .comments = [{
    "author": {"login": "chatter"},
    "body": "looks fine to me, ship it",
    "createdAt": "not-a-timestamp"
  }]')
out=$(run "$f_ordinary_bad_ts"); rc=$?
check "ordinary non-verdict comment with bad timestamp does not block aggregate" "$rc" "0"
if echo "$out" | grep -qF "malformed"; then
  bad "ordinary comment must not be collected as malformed relevant evidence"
else
  ok "ordinary non-verdict comment is not malformed evidence"
fi
contains "uses reviewDecision fallback for ordinary noise" "$out" "reviewDecision fallback"

echo "#61 P1 · formal review state precedes contradictory body VERDICT text"
# CHANGES_REQUESTED with a body that ends VERDICT: APPROVE must still block.
f_formal_vs_body=$(fixture formal_vs_body '.reviewDecision = "CHANGES_REQUESTED" | .headRefOid = "2222222222222222222222222222222222222222" |
  .reviews = [{
    "author": {"login": "strict-reviewer"},
    "state": "CHANGES_REQUESTED",
    "body": "blocking findings remain; please re-request review\n\nVERDICT: APPROVE",
    "submittedAt": "2026-08-02T16:30:00Z",
    "commit": {"oid": "2222222222222222222222222222222222222222"}
  }]')
out=$(run "$f_formal_vs_body"); rc=$?
check "CHANGES_REQUESTED + body VERDICT: APPROVE is BLOCKED" "$rc" "1"
contains "names REQUEST_CHANGES despite body APPROVE" "$out" "REQUEST_CHANGES"
if echo "$out" | grep -qE 'READY|independent identity'; then
  bad "body APPROVE must not authorize over formal CHANGES_REQUESTED"
else
  ok "body APPROVE does not authorize over formal CHANGES_REQUESTED"
fi

# DISMISSED formal review retaining VERDICT: APPROVE must not authorize.
f_dismissed=$(fixture dismissed_approve '.reviewDecision = "" | .headRefOid = "3333333333333333333333333333333333333333" |
  .reviews = [{
    "author": {"login": "dismissed-bot"},
    "state": "DISMISSED",
    "body": "old approval left in body\n\nVERDICT: APPROVE",
    "submittedAt": "2026-08-02T16:00:00Z",
    "commit": {"oid": "3333333333333333333333333333333333333333"}
  }]')
out=$(run "$f_dismissed"); rc=$?
check "DISMISSED review with body VERDICT: APPROVE is BLOCKED" "$rc" "1"
if echo "$out" | grep -qF "READY"; then bad "DISMISSED+APPROVE body must not be READY"; else ok "DISMISSED does not authorize via body APPROVE"; fi
contains "fail closed without usable independent APPROVE" "$out" "Law 5"

echo "#61 P1 · SHA-bound + malformed formal fail closed before aggregate fallback"
# SHA-bound approval with null/absent current head must fail closed.
f_null_head=$(fixture null_head '.reviewDecision = "APPROVED" | .headRefOid = null |
  .reviews = [{
    "author": {"login": "formal-bot"},
    "state": "APPROVED",
    "body": "lgtm",
    "submittedAt": "2026-08-02T16:00:00Z",
    "commit": {"oid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  }]')
out=$(run "$f_null_head"); rc=$?
check "SHA-bound APPROVE with null headRefOid is BLOCKED" "$rc" "1"
contains "names missing/unverifiable head binding" "$out" "head"
if echo "$out" | grep -qF "READY"; then bad "null head must not READY via formal or reviewDecision"; else ok "null head is not READY"; fi

# Null-time formal APPROVED must not be dropped then recovered via reviewDecision.
f_null_time_formal=$(fixture null_time_formal '.reviewDecision = "APPROVED" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .reviews = [{
    "author": {"login": "ghost-clock"},
    "state": "APPROVED",
    "body": "lgtm",
    "submittedAt": null,
    "commit": {"oid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  }]')
out=$(run "$f_null_time_formal"); rc=$?
check "null-time formal APPROVED is BLOCKED (not recovered via reviewDecision)" "$rc" "1"
contains "names malformed formal evidence" "$out" "malformed"
if echo "$out" | grep -qF "READY"; then bad "null-time formal must not READY via aggregate"; else ok "null-time formal not recovered via reviewDecision"; fi

# Authorless formal APPROVED must not be dropped then recovered via reviewDecision.
f_authorless_formal=$(fixture authorless_formal '.reviewDecision = "APPROVED" | .headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .reviews = [{
    "author": null,
    "state": "APPROVED",
    "body": "lgtm",
    "submittedAt": "2026-08-02T16:00:00Z",
    "commit": {"oid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  }]')
out=$(run "$f_authorless_formal"); rc=$?
check "authorless formal APPROVED is BLOCKED (not recovered via reviewDecision)" "$rc" "1"
contains "names malformed/authorless formal" "$out" "malformed"
if echo "$out" | grep -qF "READY"; then bad "authorless formal must not READY via aggregate"; else ok "authorless formal not recovered via reviewDecision"; fi

echo "#61 · stale-head verdict fails closed when source binds a commit SHA"
f_stale=$(fixture stale_head '.reviewDecision = "" | .headRefOid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" |
  .reviews = [{
    "author": {"login": "reviewer-bot"},
    "body": "VERDICT: APPROVE",
    "submittedAt": "2026-08-02T16:00:00Z",
    "commit": {"oid": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  }]')
out=$(run "$f_stale"); rc=$?
check "stale-head APPROVE is BLOCKED" "$rc" "1"
contains "says fail closed / re-review" "$out" "stale head"
contains "names current head prefix" "$out" "bbbbbbb"

echo "L-033 · infra red is not product red"
f_infra=$(fixture infra '.statusCheckRollup = [
  {"__typename": "CheckRun", "name": "gate", "conclusion": "STARTUP_FAILURE", "steps": []},
  {"__typename": "CheckRun", "name": "security", "conclusion": "FAILURE", "steps": []}]')
out=$(run "$f_infra"); rc=$?
check "exit 4 (ADMIN-CANDIDATE)" "$rc" "4"
contains "names the infra signature" "$out" "startup_failure / no steps / no runner"
contains "forbids claiming green" "$out" "Never report it as remote green"

f_product=$(fixture product '.statusCheckRollup = [
  {"__typename": "CheckRun", "name": "gate", "conclusion": "FAILURE", "steps": [{"name": "test"}]}]')
out=$(run "$f_product"); rc=$?
check "a step that actually failed blocks" "$rc" "1"
contains "says fix the code" "$out" "fix the code"

f_pending=$(fixture pending '.statusCheckRollup = [
  {"__typename": "CheckRun", "name": "gate", "conclusion": null, "steps": []}]')
out=$(run "$f_pending"); rc=$?
check "pending checks block" "$rc" "1"

echo "Law 7 / posture · no admin path for Tier C or post-launch"
f_tierc=$(fixture tierc '.labels = [{"name": "tier-c"}] |
  .statusCheckRollup = [{"__typename": "CheckRun", "name": "gate", "conclusion": "STARTUP_FAILURE", "steps": []}]')
out=$(run "$f_tierc"); rc=$?
check "tier-c downgrades ADMIN-CANDIDATE to BLOCKED" "$rc" "1"
contains "cites the human gate" "$out" "human merge gate"

out=$(run "$f_infra" --launched); rc=$?
check "--launched removes the admin path" "$rc" "1"
contains "says escalate" "$out" "escalate to the owner"

echo "hygiene · drafts and conflicts block"
f_draft=$(fixture draft '.isDraft = true | .mergeable = "CONFLICTING"')
out=$(run "$f_draft"); rc=$?
check "exit 1" "$rc" "1"
contains "draft" "$out" "PR is a draft"
contains "conflict" "$out" "conflicts with the base"

echo "--json · machine-readable for a driver"
out=$(GH_FIXTURE="$f_infra" "$PREFLIGHT" 1 --repo acme/app --json 2>&1)
check "verdict field" "$(echo "$out" | jq -r .verdict)" "ADMIN-CANDIDATE"
check "blockers empty" "$(echo "$out" | jq -r '.blockers | length')" "0"
check "admin_reasons populated" "$(echo "$out" | jq -r '.admin_reasons | length')" "1"

echo
echo "release-preflight.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
