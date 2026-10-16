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

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PREFLIGHT="$SCRIPT_DIR/../release-preflight.sh"
PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -F -- "$3" >/dev/null; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -F -- "$3" >/dev/null; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-preflight-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"
# Inherited fixture env must not leak into a case that expects production.
unset GIBSON_REVIEW_EVIDENCE_FIXTURE || true
cat > "$ROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh: `repo view` names a repo, `pr view` replays $GH_FIXTURE.
# `api .../commits/<sha>/check-runs` and `.../status` project that fixture's
# rollup onto the requested SHA, unless GH_CHECK_HEAD forces a different
# snapshot SHA (the preflight must then refuse).
set -u
cmd="${1:-}"
sub="${2:-}"
case "$cmd" in
  repo)
    [[ "$sub" == "view" ]] && echo "acme/app" || exit 1
    ;;
  pr)
    [[ "$sub" == "view" ]] && cat "$GH_FIXTURE" || exit 1
    ;;
  api)
    path=""
    for a in "$@"; do
      case "$a" in
        repos/*) path="${a%%\?*}" ;;
      esac
    done
    if [[ -n "${GH_API_LOG:-}" ]]; then
      printf '%s\n' "$path" >> "$GH_API_LOG"
    fi
    sha=""
    kind=""
    case "$path" in
      */commits/*/*)
        rest="${path#*/commits/}"
        sha="${rest%%/*}"
        tail="${rest#*/}"
        case "$tail" in
          check-runs) kind=runs ;;
          status) kind=status ;;
        esac
        ;;
    esac
    if [[ -z "$kind" || ! "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
      exit 1
    fi
    emit="$sha"
    if [[ -n "${GH_CHECK_HEAD:-}" ]]; then
      emit="$GH_CHECK_HEAD"
    fi
    if [[ "$kind" == "runs" ]]; then
      jq -n --arg sha "$emit" --slurpfile pr "$GH_FIXTURE" '
        [ $pr[0].statusCheckRollup[]?
          | select(.__typename != "StatusContext")
          | select((.context == null) or (.state == null) or .__typename == "CheckRun")
          | {
              name: (.name // .context // "check"),
              head_sha: $sha,
              conclusion: (if has("conclusion") then .conclusion else null end)
            }
        ] as $runs
        | {total_count: ($runs | length), check_runs: $runs}
      '
    else
      jq -n --arg sha "$emit" --slurpfile pr "$GH_FIXTURE" '
        [ $pr[0].statusCheckRollup[]?
          | select(.__typename == "StatusContext"
              or ((.context != null) and (.state != null) and .__typename != "CheckRun"))
          | {
              context: (.context // .name // "status"),
              state: (if has("state") then .state else null end)
            }
        ] as $statuses
        | {sha: $sha, total_count: ($statuses | length), statuses: $statuses}
      '
    fi
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
REAL_NODE=$(command -v node)

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

REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
EVIDENCE_CFG="$REPO_ROOT/config/review-evidence.v1.json"
HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PREV_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
GROK_BOT='aie-agent-lanes-grok[bot]'
DEVIN_BOT='devin-ai-integration[bot]'

# pr-review-evidence --fixture dir. $1 dest, $2 kind: e3-head | e3-stale | same-vendor
write_evidence_fixture() {
  local dest="$1" kind="$2"
  mkdir -p "$dest"
  python3 - "$dest" "$kind" "$HEAD_SHA" "$PREV_SHA" "$GROK_BOT" "$DEVIN_BOT" <<'PY'
import json, os, sys
dest, kind, head, prev, grok, devin = sys.argv[1:7]
review_sha = prev if kind == "e3-stale" else head
reviewer = grok if kind == "same-vendor" else devin
commit = {
    "sha": head,
    "author": {"login": grok},
    "committer": {"login": grok},
    "commit": {
        "verification": {"verified": True, "reason": "fixture"},
        "author": {"email": "x@example.invalid"},
        "committer": {"email": "x@example.invalid"},
    },
}
review = {
    "id": 1,
    "user": {"login": reviewer, "type": "Bot"},
    "state": "APPROVED",
    "commit_id": review_sha,
    "submitted_at": "2026-09-04T10:00:00Z",
    "performed_via_github_app": None,
}
pull = {"number": 1, "state": "open", "commits": 1, "head": {"sha": head}, "user": {"login": "builder-bot"}}
def dump(name, obj):
    with open(os.path.join(dest, name), "w", encoding="utf-8") as f:
        json.dump(obj, f)
dump("pull.json", pull)
dump("commits.json", [commit])
dump("reviews.json", [review])
dump("comments.json", [])
PY
}

# Tier C evidence fixtures travel only by --test-fixture plus the harness
# marker. Stdout is the command substitution (not a TTY). CI and protected-ref
# vars are cleared so a parent shell cannot look like a protected-branch run.
run_tierc() {
  local pr_json="$1" ev_dir="${2:-}"
  if [[ -n "$ev_dir" ]]; then
    env -u GIBSON_REVIEW_EVIDENCE_FIXTURE -u GH_CHECK_HEAD -u GH_API_LOG \
      GIBSON_TEST_MODE=1 CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
      GH_FIXTURE="$pr_json" \
      "$PREFLIGHT" 1 --repo acme/app --test-fixture "$ev_dir" 2>&1
  else
    env -u GIBSON_REVIEW_EVIDENCE_FIXTURE -u GH_CHECK_HEAD -u GH_API_LOG \
      GIBSON_TEST_MODE=1 CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
      GH_FIXTURE="$pr_json" \
      "$PREFLIGHT" 1 --repo acme/app 2>&1
  fi
}

# Copy production script + evaluator into $1. A symlink breaks the evaluator's
# `import.meta.url === argv[1]` main-guard (Node sees the link path), so the
# copy is a byte-identical file; --fixture still swaps only transport.
stage_mut() {
  local dest="$1"
  mkdir -p "$dest"
  cp "$PREFLIGHT" "$dest/release-preflight.sh"
  cp "$SCRIPT_DIR/../pr-review-evidence.mjs" "$dest/pr-review-evidence.mjs"
  echo "$dest/release-preflight.sh"
}

run_mut() {
  local script="$1" pr_json="$2" ev_dir="${3:-}"
  if [[ -n "$ev_dir" ]]; then
    env -u GIBSON_REVIEW_EVIDENCE_FIXTURE -u GH_CHECK_HEAD -u GH_API_LOG \
      GIBSON_REVIEW_EVIDENCE_CONFIG="$EVIDENCE_CFG" \
      GIBSON_TEST_MODE=1 CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
      GH_FIXTURE="$pr_json" \
      bash "$script" 1 --repo acme/app --test-fixture "$ev_dir" 2>&1
  else
    env -u GIBSON_REVIEW_EVIDENCE_FIXTURE -u GH_CHECK_HEAD -u GH_API_LOG \
      GIBSON_REVIEW_EVIDENCE_CONFIG="$EVIDENCE_CFG" \
      GIBSON_TEST_MODE=1 CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
      GH_FIXTURE="$pr_json" \
      bash "$script" 1 --repo acme/app 2>&1
  fi
}

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "must not report READY when newer REQUEST_CHANGES exists"; else ok "does not report READY under stale formal approval"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "must not report READY when only valid event is REQUEST_CHANGES"; else ok "does not report READY under bogus-ts APPROVE"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "incomplete timestamp must not yield READY"; else ok "incomplete-ts sole APPROVE is not READY"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "must not report READY when only valid event is REQUEST_CHANGES"; else ok "does not report READY under imposs-date APPROVE"; fi
if echo "$out" | grep -F "bogus-calendar" >/dev/null; then bad "impossible-date APPROVE must not be selected as the winning event"; else ok "impossible-date author is not the winning event"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "impossible calendar formal must not yield READY"; else ok "impossible-date sole formal is not READY"; fi

# Apr 31 / non-leap Feb 29 are also impossible (not merely "odd").
f_apr31=$(fixture apr31 '.reviewDecision = "" |
  .comments = [{
    "author": {"login": "apr31"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-04-31T12:00:00Z"
  }]')
out=$(run "$f_apr31"); rc=$?
check "April 31 is not a valid calendar date" "$rc" "1"
if echo "$out" | grep -F "READY" >/dev/null; then bad "Apr 31 APPROVE must not be READY"; else ok "Apr 31 APPROVE is not READY"; fi

f_nonleap=$(fixture nonleap '.reviewDecision = "" |
  .comments = [{
    "author": {"login": "nonleap"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2023-02-29T12:00:00Z"
  }]')
out=$(run "$f_nonleap"); rc=$?
check "non-leap Feb 29 is not a valid calendar date" "$rc" "1"
if echo "$out" | grep -F "READY" >/dev/null; then bad "2023-02-29 APPROVE must not be READY"; else ok "non-leap Feb 29 is not READY"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "imposs+offset must not be READY"; else ok "imposs+offset is not READY"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "offset text-sort must not yield READY"; else ok "offset chrono is not READY"; fi
if echo "$out" | grep -F "older-offset-approver" >/dev/null; then bad "older offset APPROVE must not win"; else ok "older offset APPROVE is not the winning event"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "equal-instant offset tie must not be READY"; else ok "equal-instant offset tie is not READY"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "fraction spelling tie must not be READY"; else ok "fraction spelling tie is not READY"; fi

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
if echo "$out" | grep -F "early-ns9-blocker" >/dev/null; then bad "earlier 9-digit RC must not win"; else ok "earlier 9-digit RC is not the winning event"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "10+ frac formal pair must not READY"; else ok "10+ frac formal pair is not READY"; fi
# Must not select either event as a usable chronological winner via truncate-tie.
if echo "$out" | grep -E 'VERDICT: (APPROVE|REQUEST_CHANGES).*(old-rc-10frac|new-appr-10frac)' >/dev/null; then
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
if echo "$out" | grep -F "READY" >/dev/null; then bad "10+ frac sole formal must not READY via aggregate"; else ok "10+ frac sole formal not recovered via reviewDecision"; fi

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
if echo "$out" | grep -F "overprecise-approver" >/dev/null; then bad "10+ frac APPROVE must not be selected"; else ok "10+ frac APPROVE is not the winning event"; fi
if echo "$out" | grep -F "READY" >/dev/null; then bad "must not READY when only valid event is REQUEST_CHANGES"; else ok "does not READY under 10+ frac APPROVE"; fi

# Comment-only 10+ frac APPROVE (no formal): drop from stream, fail closed.
f_comment_frac10=$(fixture comment_frac10 '.reviewDecision = "" |
  .comments = [{
    "author": {"login": "comment-10frac"},
    "body": "VERDICT: APPROVE",
    "createdAt": "2026-08-02T12:00:00.1234567890Z"
  }]')
out=$(run "$f_comment_frac10"); rc=$?
check "sole comment APPROVE with 10+ fractional digits is BLOCKED" "$rc" "1"
if echo "$out" | grep -F "READY" >/dev/null; then bad "comment 10+ frac must not READY"; else ok "comment 10+ frac is not READY"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then
  bad "must not READY by selecting older formal APPROVED after dropping malformed later RC"
else
  ok "does not READY under older formal + later malformed RC"
fi
# Must not treat the older formal alone as a clear independent approval path.
if echo "$out" | grep -F "independent identity" >/dev/null; then
  bad "older formal APPROVE must not be selected as gate-clearing when later RC is malformed"
else
  ok "older formal APPROVE is not selected as gate-clearing under later malformed RC"
fi
if echo "$out" | grep -F "formal-approver" >/dev/null; then
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
if echo "$out" | grep -F "READY" >/dev/null; then
  bad "must not READY via reviewDecision aggregate after dropping malformed APPROVE comment"
else
  ok "does not READY via reviewDecision after malformed APPROVE comment"
fi
if echo "$out" | grep -F "formal GitHub approval present" >/dev/null; then
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
if echo "$out" | grep -F "READY" >/dev/null; then
  bad "authorless APPROVE comment must not READY via reviewDecision aggregate"
else
  ok "authorless APPROVE comment not recovered via reviewDecision"
fi
if echo "$out" | grep -F "formal GitHub approval present" >/dev/null; then
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
if echo "$out" | grep -F "malformed" >/dev/null; then
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
if echo "$out" | grep -E 'READY|independent identity' >/dev/null; then
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
if echo "$out" | grep -F "READY" >/dev/null; then bad "DISMISSED+APPROVE body must not be READY"; else ok "DISMISSED does not authorize via body APPROVE"; fi
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
if echo "$out" | grep -F "READY" >/dev/null; then bad "null head must not READY via formal or reviewDecision"; else ok "null head is not READY"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "null-time formal must not READY via aggregate"; else ok "null-time formal not recovered via reviewDecision"; fi

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
if echo "$out" | grep -F "READY" >/dev/null; then bad "authorless formal must not READY via aggregate"; else ok "authorless formal not recovered via reviewDecision"; fi

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
out=$(run_tierc "$f_tierc"); rc=$?
check "tier-c downgrades ADMIN-CANDIDATE to BLOCKED" "$rc" "1"
contains "names the G12 floor" "$out" "Tier C floor (G12, D-015) not met"
lacks "does not cite the retired human merge gate" "$out" "human merge gate"
contains "no admin path remains" "$out" "no admin path"

out=$(run "$f_infra" --launched); rc=$?
check "--launched removes the admin path" "$rc" "1"
contains "says escalate" "$out" "escalate to the owner"

echo "D-015 G12 floor · Tier C mergeable only on E3 at exact head + green checks"
write_evidence_fixture "$ROOT/ev-e3" e3-head
write_evidence_fixture "$ROOT/ev-stale" e3-stale
write_evidence_fixture "$ROOT/ev-same" same-vendor

f_tierc_green=$(fixture tierc_green '.labels = [{"name": "tier-c"}]')
out=$(run_tierc "$f_tierc_green" "$ROOT/ev-e3"); rc=$?
check "Tier C + E3 at head + checks green is READY" "$rc" "0"
contains "green floor verdict READY" "$out" "READY"
lacks "green floor has no G12 blocker" "$out" "Tier C floor (G12, D-015) not met"

# Mutation: restore the retired unconditional human-gate blocker → green case BLOCKED.
mut_green=$(stage_mut "$ROOT/mut-green")
python3 - "$mut_green" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '''  if [[ ${#_floor_parts[@]} -gt 0 ]]; then
    _floor_msg=""
    for _p in "${_floor_parts[@]}"; do
      if [[ -z "$_floor_msg" ]]; then
        _floor_msg="$_p"
      else
        _floor_msg="$_floor_msg; $_p"
      fi
    done
    BLOCKERS+=("Tier C floor (G12, D-015) not met: $_floor_msg")
  fi'''
new = old + '\n  BLOCKERS+=("Tier C is a human merge gate (Law 7) — no admin path, whatever the CI is doing")'
if old not in s:
    raise SystemExit("mutation anchor missing: floor_parts block")
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
out=$(run_mut "$mut_green" "$f_tierc_green" "$ROOT/ev-e3"); rc=$?
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -F "human merge gate" >/dev/null; then
  ok "mutation green: injecting retired human-gate blocker BLOCKS a floor-passing head"
else
  bad "mutation green did not block (rc=$rc): $out"
fi

f_tierc_stale=$(fixture tierc_stale '.labels = [{"name": "tier-c"}]')
out=$(run_tierc "$f_tierc_stale" "$ROOT/ev-stale"); rc=$?
check "E3 at an older head is BLOCKED" "$rc" "1"
contains "stale E3 names the floor" "$out" "Tier C floor (G12, D-015) not met"
contains "stale E3 names unbound head" "$out" "E3 not bound to this head"

mut_stale=$(stage_mut "$ROOT/mut-stale")
python3 - "$mut_stale" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
# Force the evaluator result to look like E3-at-head pass, keeping headSha
# so this mutation still proves the reason check (a missing headSha is its own blocker).
needle = '    _ev_out=$("${_ev_args[@]}" 2>/dev/null) || true'
repl = '''    _ev_out=$("${_ev_args[@]}" 2>/dev/null) || true
    _ev_out=$(printf '%s' "$_ev_out" | jq -c '.state = "success" | .reason = "pass"')
'''
if needle not in s:
    raise SystemExit("mutation anchor missing: evaluator capture")
open(p, "w", encoding="utf-8").write(s.replace(needle, repl, 1))
PY
out=$(run_mut "$mut_stale" "$f_tierc_stale" "$ROOT/ev-stale"); rc=$?
if echo "$out" | grep -F "E3 not bound to this head" >/dev/null; then
  bad "mutation stale: forcing pass still reported unbound head: $out"
elif [[ "$rc" -eq 0 ]] && echo "$out" | grep -F "READY" >/dev/null; then
  ok "mutation stale: ignoring evaluator reason lets an older-head E3 READY"
else
  bad "mutation stale unexpected (rc=$rc): $out"
fi

f_tierc_same=$(fixture tierc_same '.labels = [{"name": "tier-c"}]')
out=$(run_tierc "$f_tierc_same" "$ROOT/ev-same"); rc=$?
check "same-vendor review is BLOCKED" "$rc" "1"
contains "same-vendor names the floor" "$out" "Tier C floor (G12, D-015) not met"
contains "same-vendor names the part" "$out" "same-vendor review"

mut_same=$(stage_mut "$ROOT/mut-same")
python3 - "$mut_same" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
needle = '    elif [[ "$_ev_reason" == "same-vendor-reviewer" ]]; then\n      _floor_parts+=("same-vendor review")'
repl = '    elif [[ "$_ev_reason" == "same-vendor-reviewer" ]]; then\n      :'
if needle not in s:
    raise SystemExit("mutation anchor missing: same-vendor clause")
open(p, "w", encoding="utf-8").write(s.replace(needle, repl, 1))
PY
out=$(run_mut "$mut_same" "$f_tierc_same" "$ROOT/ev-same"); rc=$?
if echo "$out" | grep -F "same-vendor review" >/dev/null; then
  bad "mutation same-vendor: clause still fired: $out"
elif [[ "$rc" -eq 0 ]] && echo "$out" | grep -F "READY" >/dev/null; then
  ok "mutation same-vendor: dropping the same-vendor floor clause lets it READY"
else
  bad "mutation same-vendor unexpected (rc=$rc): $out"
fi

f_tierc_red=$(fixture tierc_red '.labels = [{"name": "tier-c"}] |
  .statusCheckRollup = [{"__typename": "CheckRun", "name": "gate", "conclusion": "FAILURE", "steps": [{"name": "test"}]}]')
out=$(run_tierc "$f_tierc_red" "$ROOT/ev-e3"); rc=$?
check "checks red is BLOCKED" "$rc" "1"
contains "red checks name the floor" "$out" "Tier C floor (G12, D-015) not met"
contains "red checks name the part" "$out" "required checks not green"

mut_red=$(stage_mut "$ROOT/mut-red")
python3 - "$mut_red" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
needle = '''    if [[ "$CHECK_GREEN" -ne 1 ]]; then
      _floor_parts+=("required checks not green")
    fi'''
repl = '''    if [[ "$CHECK_GREEN" -ne 1 ]]; then
      :
    fi'''
if needle not in s:
    raise SystemExit("mutation anchor missing: checks-green floor clause")
open(p, "w", encoding="utf-8").write(s.replace(needle, repl, 1))
PY
out=$(run_mut "$mut_red" "$f_tierc_red" "$ROOT/ev-e3"); rc=$?
if echo "$out" | grep -F "required checks not green" >/dev/null; then
  bad "mutation checks-red: floor still named required checks: $out"
elif echo "$out" | grep -F "fix the code" >/dev/null && [[ "$rc" -eq 1 ]]; then
  ok "mutation checks-red: dropping the floor checks clause loses that part (product-red still blocks)"
else
  bad "mutation checks-red unexpected (rc=$rc): $out"
fi

f_tierc_unread=$(fixture tierc_unread '.labels = [{"name": "tier-c"}]')
out=$(run_tierc "$f_tierc_unread"); rc=$?
check "evidence unreadable is BLOCKED" "$rc" "1"
contains "unreadable names the floor" "$out" "Tier C floor (G12, D-015) not met"
contains "unreadable names the part" "$out" "evidence unreadable"

mut_unread=$(stage_mut "$ROOT/mut-unread")
python3 - "$mut_unread" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
n1 = '    if [[ -z "$_ev_state" || -z "$_ev_reason" ]]; then\n      _floor_parts+=("evidence unreadable")'
r1 = '    if [[ -z "$_ev_state" || -z "$_ev_reason" ]]; then\n      :'
n2 = '    elif [[ "$_ev_reason" == "api-error" || "$_ev_reason" == "config-error" ]]; then\n      _floor_parts+=("evidence unreadable")'
r2 = '    elif [[ "$_ev_reason" == "api-error" || "$_ev_reason" == "config-error" ]]; then\n      :'
if n1 not in s or n2 not in s:
    raise SystemExit("mutation anchor missing: unreadable clauses")
s = s.replace(n1, r1, 1).replace(n2, r2, 1)
open(p, "w", encoding="utf-8").write(s)
PY
out=$(run_mut "$mut_unread" "$f_tierc_unread"); rc=$?
if echo "$out" | grep -F "evidence unreadable" >/dev/null; then
  bad "mutation unreadable: clause still fired: $out"
elif [[ "$rc" -eq 0 ]] && echo "$out" | grep -F "READY" >/dev/null; then
  ok "mutation unreadable: dropping fail-closed unreadable lets missing evidence READY"
else
  bad "mutation unreadable unexpected (rc=$rc): $out"
fi

echo "D-015 · Tier C required checks are an allow-list of success, bound to HEAD"
OTHER_SHA="cccccccccccccccccccccccccccccccccccccccc"
f_tierc_neutral=$(fixture tierc_neutral '.labels = [{"name": "tier-c"}] |
  .statusCheckRollup = [{"__typename": "CheckRun", "name": "gate", "conclusion": "NEUTRAL", "steps": [{"name": "s"}]}]')
for tok in NEUTRAL SKIPPED STALE ACTION_REQUIRED UNKNOWN_TOKEN; do
  f_tok=$(fixture "tierc_tok_${tok}" --arg t "$tok" '
    .labels = [{"name": "tier-c"}]
    | .statusCheckRollup = [{"__typename": "CheckRun", "name": "gate", "conclusion": $t, "steps": [{"name": "s"}]}]')
  out=$(run_tierc "$f_tok" "$ROOT/ev-e3"); rc=$?
  check "token $tok is not met" "$rc" "1"
  contains "token $tok names the floor" "$out" "Tier C floor (G12, D-015) not met"
  contains "token $tok names checks" "$out" "required checks not green"
  lacks "token $tok is not READY" "$out" "— READY"
done

f_miss=$(fixture tierc_missing '.labels = [{"name": "tier-c"}] |
  .statusCheckRollup = [{"__typename": "CheckRun", "name": "gate", "conclusion": null, "steps": []}]')
out=$(run_tierc "$f_miss" "$ROOT/ev-e3"); rc=$?
check "missing conclusion is not met" "$rc" "1"
contains "missing conclusion names checks" "$out" "required checks not green"
lacks "missing conclusion is not READY" "$out" "— READY"

f_status_ok=$(fixture tierc_status_ok '.labels = [{"name": "tier-c"}] |
  .statusCheckRollup = [{"__typename": "StatusContext", "context": "ci/status", "state": "success"}]')
out=$(run_tierc "$f_status_ok" "$ROOT/ev-e3"); rc=$?
check "status state success is met" "$rc" "0"
contains "status success verdict" "$out" "READY"

f_status_bad=$(fixture tierc_status_bad '.labels = [{"name": "tier-c"}] |
  .statusCheckRollup = [{"__typename": "StatusContext", "context": "ci/status", "state": "EXPECTED"}]')
out=$(run_tierc "$f_status_bad" "$ROOT/ev-e3"); rc=$?
check "unknown status state is not met" "$rc" "1"
contains "unknown status names checks" "$out" "required checks not green"
lacks "unknown status is not READY" "$out" "— READY"

f_mix=$(fixture tierc_mix '.labels = [{"name": "tier-c"}] |
  .statusCheckRollup = [
    {"__typename": "CheckRun", "name": "gate", "conclusion": "SUCCESS", "steps": [{"name": "s"}]},
    {"__typename": "CheckRun", "name": "lint", "conclusion": "NEUTRAL", "steps": [{"name": "s"}]}
  ]')
out=$(run_tierc "$f_mix" "$ROOT/ev-e3"); rc=$?
check "one non-success context blocks the whole set" "$rc" "1"
contains "mixed set names checks" "$out" "required checks not green"

mut_allow=$(stage_mut "$ROOT/mut-allow")
python3 - "$mut_allow" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
needle = 'def met: tok == "success";'
repl = 'def met: true;'
if needle not in s:
    raise SystemExit("mutation anchor missing: success allow-list")
open(p, "w", encoding="utf-8").write(s.replace(needle, repl, 1))
PY
out=$(run_mut "$mut_allow" "$f_tierc_neutral" "$ROOT/ev-e3"); rc=$?
if echo "$out" | grep -F "required checks not green" >/dev/null; then
  bad "mutation allow-list: NEUTRAL still failed the floor: $out"
elif [[ "$rc" -eq 0 ]] && echo "$out" | grep -F "READY" >/dev/null; then
  ok "mutation allow-list: treating every token as success lets NEUTRAL READY"
else
  bad "mutation allow-list unexpected (rc=$rc): $out"
fi

echo "D-015 · fixture transport is test-harness only"
out=$(env -u GIBSON_TEST_MODE \
  GIBSON_REVIEW_EVIDENCE_FIXTURE="$ROOT/ev-e3" \
  CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  "$PREFLIGHT" 1 --repo acme/app 2>&1); rc=$?
check "env fixture without --test-fixture is blocked" "$rc" "1"
contains "env fixture names the production blocker" "$out" "test fixture transport present in a production run"
lacks "env fixture is not READY" "$out" "— READY"

mut_fix=$(stage_mut "$ROOT/mut-fix")
python3 - "$mut_fix" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
n1 = '''if [[ -n "${GIBSON_REVIEW_EVIDENCE_FIXTURE:-}" && "$TEST_FIXTURE_OK" -ne 1 ]]; then
  BLOCKERS+=("test fixture transport present in a production run")
fi'''
r1 = ''
n2 = '''    if [[ "$TEST_FIXTURE_OK" -eq 1 ]]; then
      _ev_args+=(--fixture "$TEST_FIXTURE_DIR")
    fi'''
r2 = '''    if [[ -n "${GIBSON_REVIEW_EVIDENCE_FIXTURE:-}" ]]; then
      _ev_args+=(--fixture "$GIBSON_REVIEW_EVIDENCE_FIXTURE")
    fi'''
if n1 not in s or n2 not in s:
    raise SystemExit("mutation anchor missing: fixture transport")
open(p, "w", encoding="utf-8").write(s.replace(n1, r1, 1).replace(n2, r2, 1))
PY
out=$(env -u GIBSON_TEST_MODE \
  GIBSON_REVIEW_EVIDENCE_CONFIG="$EVIDENCE_CFG" \
  GIBSON_REVIEW_EVIDENCE_FIXTURE="$ROOT/ev-e3" \
  CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  bash "$mut_fix" 1 --repo acme/app 2>&1); rc=$?
if echo "$out" | grep -F "test fixture transport present in a production run" >/dev/null; then
  bad "mutation fixture: production blocker still fired: $out"
elif [[ "$rc" -eq 0 ]] && echo "$out" | grep -F "READY" >/dev/null; then
  ok "mutation fixture: honoring the env var lets fabricated evidence READY"
else
  bad "mutation fixture unexpected (rc=$rc): $out"
fi

out=$(env -u GIBSON_TEST_MODE -u GIBSON_REVIEW_EVIDENCE_FIXTURE \
  CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  "$PREFLIGHT" 1 --repo acme/app --test-fixture "$ROOT/ev-e3" 2>&1); rc=$?
check "--test-fixture without the harness marker is refused" "$rc" "2"
contains "flag without marker names the harness" "$out" "refusing --test-fixture outside the test harness"

out=$(env -u GIBSON_REVIEW_EVIDENCE_FIXTURE \
  GIBSON_TEST_MODE=1 CI=true GITHUB_REF=refs/heads/main GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  "$PREFLIGHT" 1 --repo acme/app --test-fixture "$ROOT/ev-e3" 2>&1); rc=$?
check "protected-branch CI refuses --test-fixture" "$rc" "2"
contains "protected-branch refusal names the harness" "$out" "refusing --test-fixture outside the test harness"

out=$(env -u GIBSON_REVIEW_EVIDENCE_FIXTURE \
  GIBSON_TEST_MODE=1 CI=true GITHUB_REF=refs/pull/481/merge GITHUB_REF_PROTECTED=true \
  GH_FIXTURE="$f_tierc_green" \
  "$PREFLIGHT" 1 --repo acme/app --test-fixture "$ROOT/ev-e3" 2>&1); rc=$?
check "GITHUB_REF_PROTECTED refuses --test-fixture" "$rc" "2"

out=$(env -u GIBSON_REVIEW_EVIDENCE_FIXTURE \
  GIBSON_TEST_MODE=1 CI=true GITHUB_REF=refs/pull/481/merge GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  "$PREFLIGHT" 1 --repo acme/app --test-fixture "$ROOT/ev-e3" 2>&1); rc=$?
check "pull-request CI may use the harness fixture" "$rc" "0"
contains "pull-request CI harness is READY" "$out" "READY"

out=$(env GIBSON_REVIEW_EVIDENCE_FIXTURE="$ROOT/ev-e3" \
  GIBSON_TEST_MODE=1 CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  "$PREFLIGHT" 1 --repo acme/app --test-fixture "$ROOT/ev-stale" 2>&1); rc=$?
check "harness uses --test-fixture, not the env var" "$rc" "1"
contains "stale flag still names unbound head" "$out" "E3 not bound to this head"
lacks "harness does not emit the production blocker" "$out" "test fixture transport present in a production run"

python3 - "$PREFLIGHT" "$f_tierc_green" "$ROOT/ev-e3" "$ROOT/pty" <<'PY'
import os, pty, select, subprocess, sys, time
preflight, fixture, evdir, out_path = sys.argv[1:5]
master, slave = pty.openpty()
env = os.environ.copy()
env["GIBSON_TEST_MODE"] = "1"
env["GH_FIXTURE"] = fixture
env.pop("GIBSON_REVIEW_EVIDENCE_FIXTURE", None)
env["CI"] = ""
env["GITHUB_REF"] = ""
env["GITHUB_REF_PROTECTED"] = ""
proc = subprocess.Popen(
    [preflight, "1", "--repo", "acme/app", "--test-fixture", evdir],
    stdin=subprocess.DEVNULL,
    stdout=slave,
    stderr=subprocess.STDOUT,
    env=env,
    close_fds=True,
)
os.close(slave)
buf = b""
deadline = time.time() + 20
while time.time() < deadline:
    ready, _, _ = select.select([master], [], [], 0.2)
    if ready:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
    elif proc.poll() is not None:
        break
try:
    rc = proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    rc = 99
os.close(master)
open(out_path, "wb").write(buf)
open(out_path + ".rc", "w", encoding="utf-8").write(str(rc))
PY
pty_rc=$(cat "$ROOT/pty.rc")
pty_text=$(cat "$ROOT/pty")
check "TTY refuses --test-fixture" "$pty_rc" "2"
contains "TTY refusal names the harness" "$pty_text" "refusing --test-fixture outside the test harness"

echo "D-015 · evaluator headSha and check snapshot are bound to HEAD_OID"
: > "$ROOT/gh-api.log"
out=$(env -u GIBSON_REVIEW_EVIDENCE_FIXTURE \
  GIBSON_TEST_MODE=1 CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  GH_CHECK_HEAD="$OTHER_SHA" \
  GH_API_LOG="$ROOT/gh-api.log" \
  "$PREFLIGHT" 1 --repo acme/app --test-fixture "$ROOT/ev-e3" 2>&1); rc=$?
check "checks for a different SHA are blocked" "$rc" "1"
contains "wrong check SHA names the binding" "$out" "required checks not bound to this head"
lacks "wrong check SHA is not a conclusion failure" "$out" "required checks not green"
lacks "wrong check SHA is not READY" "$out" "— READY"
if grep -F "commits/${HEAD_SHA}/check-runs" "$ROOT/gh-api.log" >/dev/null \
  && grep -F "commits/${HEAD_SHA}/status" "$ROOT/gh-api.log" >/dev/null; then
  ok "checks were requested for HEAD_OID"
else
  bad "checks were not requested for HEAD_OID: $(cat "$ROOT/gh-api.log")"
fi

mut_bound=$(stage_mut "$ROOT/mut-bound")
python3 - "$mut_bound" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
needle = '''    if [[ "$CHECK_BOUND" -ne 1 ]]; then
      _floor_parts+=("required checks not bound to this head")
    fi'''
repl = '''    if [[ "$CHECK_BOUND" -ne 1 ]]; then
      :
    fi'''
if needle not in s:
    raise SystemExit("mutation anchor missing: check SHA binding")
open(p, "w", encoding="utf-8").write(s.replace(needle, repl, 1))
PY
out=$(env -u GIBSON_REVIEW_EVIDENCE_FIXTURE \
  GIBSON_REVIEW_EVIDENCE_CONFIG="$EVIDENCE_CFG" \
  GIBSON_TEST_MODE=1 CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  GH_CHECK_HEAD="$OTHER_SHA" \
  bash "$mut_bound" 1 --repo acme/app --test-fixture "$ROOT/ev-e3" 2>&1); rc=$?
if echo "$out" | grep -F "required checks not bound to this head" >/dev/null; then
  bad "mutation check-SHA: binding still fired: $out"
elif [[ "$rc" -eq 0 ]] && echo "$out" | grep -F "READY" >/dev/null; then
  ok "mutation check-SHA: ignoring payload SHA lets another head's checks READY"
else
  bad "mutation check-SHA unexpected (rc=$rc): $out"
fi

install_fake_node() {
  printf '%s\n' "$1" > "$ROOT/fake-eval.json"
  python3 - "$ROOT/bin/node" "$ROOT/fake-eval.json" "$REAL_NODE" <<'PY'
import sys
path, payload, real = sys.argv[1:4]
script = """#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *pr-review-evidence.mjs*)
      cat "$PAYLOAD"
      exit 0
      ;;
  esac
done
exec "$REAL_NODE" "$@"
"""
script = script.replace("$PAYLOAD", payload).replace("$REAL_NODE", real)
open(path, "w", encoding="utf-8").write(script)
PY
  chmod +x "$ROOT/bin/node"
}

install_fake_node "{\"headSha\":\"${PREV_SHA}\",\"state\":\"success\",\"reason\":\"pass\"}"
out=$(env -u GIBSON_REVIEW_EVIDENCE_FIXTURE \
  GIBSON_TEST_MODE=1 CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  "$PREFLIGHT" 1 --repo acme/app 2>&1); rc=$?
check "evaluator headSha mismatch is blocked" "$rc" "1"
contains "head mismatch names the binding" "$out" "evaluator headSha does not match this head"
lacks "head mismatch is not READY" "$out" "— READY"

install_fake_node '{"state":"success","reason":"pass"}'
out=$(env -u GIBSON_REVIEW_EVIDENCE_FIXTURE \
  GIBSON_TEST_MODE=1 CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  "$PREFLIGHT" 1 --repo acme/app 2>&1); rc=$?
check "missing evaluator headSha is blocked" "$rc" "1"
contains "missing headSha names the binding" "$out" "evaluator headSha does not match this head"

mut_head=$(stage_mut "$ROOT/mut-head")
python3 - "$mut_head" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
needle = '''    if [[ "$_ev_head" != "$HEAD_OID" ]]; then
      _floor_parts+=("evaluator headSha does not match this head")
    fi'''
repl = '''    if [[ "$_ev_head" != "$HEAD_OID" ]]; then
      :
    fi'''
if needle not in s:
    raise SystemExit("mutation anchor missing: evaluator headSha")
open(p, "w", encoding="utf-8").write(s.replace(needle, repl, 1))
PY
install_fake_node "{\"headSha\":\"${PREV_SHA}\",\"state\":\"success\",\"reason\":\"pass\"}"
out=$(env -u GIBSON_REVIEW_EVIDENCE_FIXTURE \
  GIBSON_REVIEW_EVIDENCE_CONFIG="$EVIDENCE_CFG" \
  GIBSON_TEST_MODE=1 CI= GITHUB_REF= GITHUB_REF_PROTECTED= \
  GH_FIXTURE="$f_tierc_green" \
  bash "$mut_head" 1 --repo acme/app 2>&1); rc=$?
if echo "$out" | grep -F "evaluator headSha does not match this head" >/dev/null; then
  bad "mutation headSha: binding still fired: $out"
elif [[ "$rc" -eq 0 ]] && echo "$out" | grep -F "READY" >/dev/null; then
  ok "mutation headSha: ignoring returned headSha lets a different head READY"
else
  bad "mutation headSha unexpected (rc=$rc): $out"
fi
rm -f "$ROOT/bin/node"

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
