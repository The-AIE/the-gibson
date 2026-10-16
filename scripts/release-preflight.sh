#!/usr/bin/env bash
# release-preflight.sh — decide whether a PR may merge, and say why not (docs/02 stage 7)
set -uo pipefail

usage() {
  cat <<'EOF'
release-preflight.sh — pre-merge verdict for the release hat

WHAT IT DOES
  Reads one pull request and prints a verdict — READY, BLOCKED, or
  ADMIN-CANDIDATE — with the evidence behind it. It checks four things the
  release hat used to re-diagnose by hand on every PR:

    1. Close keywords. GitHub's linker does not parse negation, so a partial
       ship whose body says "does not fully resolve #28" still closes #28.
       Detects partial via --partial, a body partial marker, or Related-only
       body; hard-fails on closingIssuesReferences OR a fix/close/resolve(#N)
       title (L-013 / L-025).
    2. Review. Reviews and comments form one normalized timestamped stream
       (newest wins, source type does not reorder). Formal review states
       (APPROVED / CHANGES_REQUESTED) are modeled as events when usable and
       always precede body VERDICT text on the same review; DISMISSED reviews
       never authorize via body text. reviewDecision is only a fail-closed
       fallback when no usable event exists and no malformed relevant evidence
       was discarded. A newer VERDICT: REQUEST_CHANGES blocks even if an older
       formal approval remains. Timestamps must be a complete ISO-8601 instant
       with a real civil calendar (strict round-trip; impossible dates like
       9999-02-31 never normalize into the stream) and at most 1–9 fractional
       digits (nanoseconds; 10+ digits are malformed, never truncated);
       authorless APPROVE never clears the gate; equal-time conflicts prefer
       REQUEST_CHANGES. Any comment (or non-dismissed body-VERDICT review)
       with a recognized terminal VERDICT marker whose timestamp is missing,
       non-string, incomplete, invalid civil time, or >9-digit precision is
       malformed relevant evidence and hard-blocks before event selection or
       aggregate fallback — never drop-then-recover via an older valid approval
       or reviewDecision=APPROVED. Ordinary comments without a terminal VERDICT
       are not evidence. A SHA-bound verdict must match the current PR head —
       absent/null head fails closed.
    3. Required checks. Distinguishes a product red (a step failed) from GitHub
       Actions infrastructure (startup_failure / no steps / no runner), which
       re-runs identically and is usually concurrent across open PRs. That
       split is not the Tier C success gate.
    4. Tier. tier-c never gets an admin path. The G12 floor (D-015) is E3
       (cross-vendor, exact-head) plus every required context an explicit
       success at that head. The required list is read live from the base
       branch's classic protection and rulesets (union; app_id kept). An
       unreadable or empty list fails closed — a Tier C repo with no required
       checks is not mergeable by this floor. Each required context needs
       exactly one matching check-run (name, and app id when the requirement
       sets one) or commit status at this head whose token is success. A
       context that did not run is missing, named in the blocker. An unrelated
       success does not cover it. NEUTRAL, SKIPPED, STALE, ACTION_REQUIRED,
       and any unknown token are not met. The evaluator's returned headSha
       must equal this head, and the check snapshot is read for that SHA
       after the evaluator returns. The last step before READY re-reads the
       PR head; if it moved, the verdict is BLOCKED ("head moved during
       preflight"). Admin/force merge stays forbidden. Review-evidence
       fixtures are test-harness only (--test-fixture). An inherited
       GIBSON_REVIEW_EVIDENCE_FIXTURE on any other run is a blocker, never a
       silent ignore.

  Read-only. It never merges, never comments, never edits.

WHY
  L-013 auto-closed multi-phase issues four times. L-015 / L-021 deadlocked the
  solo loop on reviews GitHub will not let it make. L-033 sent the release hat
  round the same infra-vs-product diagnosis on every red check. Each of those is
  cheap to check and expensive to get wrong, so a script checks them.

RISKS
  - Read-only: worst case is a wrong verdict, which the checklist it prints lets
    you audit. It does not authorize anything by itself. Tier C merges only on
    the G12 floor (D-015: E3 at the exact head plus required checks).
    ADMIN-CANDIDATE is a pre-launch operator decision for Tier A/B, not a green
    light, and never applies to Tier C.

USAGE
  release-preflight.sh <pr> [--repo owner/name] [--partial] [--launched] [--json]
  release-preflight.sh --help

  <pr>         pull request number
  --repo       defaults to the current repo (gh)
  --partial    this PR ships a slice: it MUST NOT close its issue (L-013).
               Also auto-detected from Related-only body or a partial marker.
  --launched   post-launch posture: no admin path on any red, ever (L-033)
  --json       machine-readable verdict for a driver
  --test-fixture DIR
               Test harness only. Honored only together with GIBSON_TEST_MODE=1,
               a non-TTY stdout, and not a protected-branch CI run. Never read
               from the environment. Production drivers must not pass this.

EXIT
  0  READY — every gate passed
  1  BLOCKED — a gate failed; the reason is printed
  2  usage error
  4  ADMIN-CANDIDATE — blocked only by infrastructure or by the same-author
     review limit, pre-launch, Tier A/B. An operator may admin-merge after
     posting the printed checklist. Never automatic.

EXAMPLES
  release-preflight.sh 123
  release-preflight.sh 123 --partial          # slice of a multi-phase issue
  release-preflight.sh 123 --repo acme/app --json
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
  exit 2
fi

PR="$1"
shift || true
REPO_ARG=""
PARTIAL=0
LAUNCHED=0
JSON=0
TEST_FIXTURE_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_ARG="${2:-}"; shift ;;
    --partial) PARTIAL=1 ;;
    --launched) LAUNCHED=1 ;;
    --json) JSON=1 ;;
    --test-fixture)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "release-preflight.sh: ERROR: --test-fixture requires a directory" >&2
        exit 2
      fi
      TEST_FIXTURE_DIR="$2"
      shift
      ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

die() { echo "release-preflight.sh: ERROR: $*" >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || die "pr must be a number, got '$PR'"
command -v gh >/dev/null || die "gh is required"

REPO="$REPO_ARG"
if [[ -z "$REPO" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
fi
[[ -n "$REPO" ]] || die "could not resolve repo — pass --repo owner/name"

# Fixture transport is unreachable in production. --fixture is passed to the
# evidence evaluator only when every one of these holds:
#   1. --test-fixture DIR is on this process's argv (an env var cannot turn it on)
#   2. GIBSON_TEST_MODE=1, which scripts/tests sets and release drivers do not
#   3. stdout is not a TTY, so an operator at a terminal cannot load fixtures
#   4. this is not CI on a protected branch (CI=true and GITHUB_REF is
#      refs/heads/main, master, or release, or GITHUB_REF_PROTECTED=true)
# CI=true alone is not a refusal: the gate suite runs under CI on pull_request
# refs, and those are not protected-branch runs. Refusing every CI run would
# make the harness unable to prove this rule.
# GIBSON_REVIEW_EVIDENCE_FIXTURE is never a path. When it is set and the rule
# above is not met, the verdict is BLOCKED (fail closed), never a silent ignore.
TEST_FIXTURE_OK=0
_protected_ci=0
if [[ "${CI:-}" == "true" || "${CI:-}" == "1" ]]; then
  case "${GITHUB_REF:-}" in
    refs/heads/main|refs/heads/master|refs/heads/release) _protected_ci=1 ;;
  esac
  if [[ "${GITHUB_REF_PROTECTED:-}" == "true" ]]; then
    _protected_ci=1
  fi
fi
if [[ -n "$TEST_FIXTURE_DIR" && "${GIBSON_TEST_MODE:-}" == "1" && ! -t 1 && "$_protected_ci" -eq 0 ]]; then
  if [[ ! -d "$TEST_FIXTURE_DIR" ]]; then
    die "--test-fixture directory not found: $TEST_FIXTURE_DIR"
  fi
  TEST_FIXTURE_OK=1
elif [[ -n "$TEST_FIXTURE_DIR" && -z "${GIBSON_REVIEW_EVIDENCE_FIXTURE:-}" ]]; then
  die "refusing --test-fixture outside the test harness"
fi

PR_JSON=$(gh pr view "$PR" --repo "$REPO" \
  --json number,title,body,author,isDraft,mergeable,reviewDecision,labels,closingIssuesReferences,statusCheckRollup,reviews,comments,headRefOid,baseRefName 2>/dev/null) ||
  die "could not read $REPO#$PR"

command -v jq >/dev/null || die "jq is required"
jqr() { echo "$PR_JSON" | jq -r "$1"; }

AUTHOR=$(jqr '.author.login // ""')
DRAFT=$(jqr '.isDraft')
MERGEABLE=$(jqr '.mergeable // "UNKNOWN"')
REVIEW_DECISION=$(jqr '.reviewDecision // ""')
HEAD_OID=$(jqr '.headRefOid // ""')
TIER=$(jqr '[.labels[].name] | map(select(startswith("tier-"))) | first // ""')
CLOSES=$(jqr '[.closingIssuesReferences[].number] | map("#"+(.|tostring)) | join(", ")')

BLOCKERS=()
ADMIN_REASONS=()
NOTES=()

# Inherited fixture env is never transport. A non-test run that carries it
# fails closed instead of evaluating fabricated evidence or ignoring the var.
if [[ -n "${GIBSON_REVIEW_EVIDENCE_FIXTURE:-}" && "$TEST_FIXTURE_OK" -ne 1 ]]; then
  BLOCKERS+=("test fixture transport present in a production run")
fi

# --- 1. close keywords (L-013 / L-025) ------------------------------------
# Partial ships must not auto-close issues. Sources of "this is a partial":
#   - explicit --partial flag
#   - body marker: "partial ship", "[partial]", "partial:" (case-insensitive)
#   - Related-only body: has Related: #N (or Related #N) and no Closes/Fixes/Resolves
# Close evidence that hard-fails a partial:
#   - closingIssuesReferences non-empty (what GitHub will actually do)
#   - title matches Fix/Close/Resolve(#N) even when the Development sidebar
#     has not linked yet (L-025 — agents default to fix(#N): titles)
TITLE=$(jqr '.title // ""')
BODY=$(jqr '.body // ""')

title_has_close_kw=0
if printf '%s' "$TITLE" | grep -Ei >/dev/null \
  '(^|[^A-Za-z])(fix|close|resolve|closes|fixes|resolves)[[:space:]]*\(?#[[:digit:]]+'; then
  title_has_close_kw=1
fi

auto_partial=0
if [[ "$PARTIAL" -eq 1 ]]; then
  auto_partial=1
elif printf '%s' "$BODY" | grep -Ei >/dev/null \
  '(^|[[:space:][:punct:]])(\[partial\]|partial[[:space:]]+ship|partial:)'; then
  auto_partial=1
else
  # Related-only: Related #N present, no closing keyword for any issue.
  if printf '%s' "$BODY" | grep -Ei >/dev/null \
    '(^|[[:space:]])related:[[:space:]]*#?[[:digit:]]+|(^|[[:space:]])related[[:space:]]+#[[:digit:]]+'; then
    if ! printf '%s' "$BODY" | grep -Ei >/dev/null \
      '(^|[[:space:]])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*\(?#[[:digit:]]+'; then
      auto_partial=1
    fi
  fi
fi

if [[ "$auto_partial" -eq 1 ]]; then
  if [[ -n "$CLOSES" ]]; then
    BLOCKERS+=("L-013: partial ship, but GitHub will close $CLOSES on merge. Retitle to feat(scope): … (related #N), remove close keywords from the squash subject/body, and unlink the issue in the Development sidebar, then re-run.")
  elif [[ "$title_has_close_kw" -eq 1 ]]; then
    BLOCKERS+=("L-025: partial ship title still has a close keyword ($TITLE). GitHub's linker ignores negations — retitle to feat(scope): … (related #N) with no fix/close/resolve near #N, then re-run.")
  else
    NOTES+=("partial ship — will not close an issue on merge")
  fi
elif [[ -z "$CLOSES" ]]; then
  NOTES+=("no issue will be closed by this merge — intended only if the issue has further slices")
else
  NOTES+=("closes ${CLOSES:-(nothing)} on merge")
fi

# --- 2. review (L-015 / L-021) -------------------------------------------
# Reviews and comments are one normalized timestamped event stream. Newest
# usable event wins regardless of source type and regardless of
# reviewDecision (false-green: formal APPROVED short-circuited a newer
# VERDICT: REQUEST_CHANGES comment). Formal review states are modeled as
# events when they carry a usable timestamp; reviewDecision is only a
# fail-closed fallback when no usable event exists AND no malformed relevant
# evidence was discarded.
#
# Usability gates (fail closed):
#   - timestamps must be a complete accepted ISO-8601 instant (not a prefix)
#     with a real civil calendar (strict round-trip; jq fromdateiso8601 must
#     never normalize Feb 31 / Apr 31 into a later day that sorts as "newest")
#   - fractional seconds: 0 (none) or 1–9 digits only (nanosecond precision).
#     10+ fractional digits are malformed everywhere this contract applies —
#     never silently truncated into the chrono key (truncation collapsed
#     distinct instants and let REQUEST_CHANGES tie-precedence pick an older
#     event when only the 10th+ digit differed)
#   - formal state (APPROVED / CHANGES_REQUESTED) precedes body VERDICT text
#   - DISMISSED reviews never authorize via body VERDICT: APPROVE
#   - authorless APPROVE never counts as independent
#   - equal true instants: REQUEST_CHANGES wins over APPROVE (source order ignored)
#   - sort by chronological UTC instant, never raw .at text (offsets / .000
#     spellings must not reorder or miss equal-instant ties)
#   - SHA-bound events must match the current PR head; missing head fails closed
#   - malformed relevant evidence blocks before event selection recovery and
#     before any reviewDecision aggregate fallback (no drop-then-recover path):
#       * formal APPROVED/CHANGES_REQUESTED with unusable timestamp or
#         authorless APPROVED
#       * any comment (or non-dismissed body-VERDICT review) whose body has a
#         recognized terminal VERDICT: APPROVE|REQUEST_CHANGES marker but
#         whose timestamp is missing/non-string/incomplete/invalid/civil/
#         >9-digit, or whose APPROVE is authorless
#     Ordinary comments without a recognized terminal VERDICT are never
#     evidence or blockers.

# Complete accepted GitHub-style instant: YYYY-MM-DDTHH:MM:SS[.frac](Z|±HH:MM)
# Fractional policy (strict): optional frac is 1–9 digits only (nanoseconds).
# 10+ digits fail the shape match → complete_at false → never enter the stream;
# formal APPROVED/CHANGES_REQUESTED with 10+ digits is malformed formal.
# Rejects prefix-only junk like "9999-99-99Tbogus" and missing-timezone forms.
# Single-backslash fractional group: jq/Oniguruma sees (\.[0-9]{1,9})? — a
# double bash escape would require a literal backslash before the digits and
# reject real fractional instants (over-rejection).
ISO_AT_RE='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$'

# Shared jq helpers: shape match + strict civil-calendar round-trip + chrono key.
# fromdateiso8601 normalizes impossible dates (9999-02-31 → 9999-03-03); that
# must never enter the stream. Validate by stripping frac, taking the wall
# clock (drop Z/offset), parsing wall+Z, and requiring todateiso8601 to equal
# wall+Z. Offset forms are accepted when the wall is real and the offset
# matches ISO_AT_RE — do not require fromdateiso8601 on ±HH:MM (jq often
# rejects valid offsets and would over-reject GitHub-shaped stamps).
# Chronological sort key: wall epoch minus offset seconds, plus fractional
# padded to 9 digits so distinct accepted sub-seconds order and .000 collapses
# with none. Only 1–9 frac digits reach this key (see ISO_AT_RE); pad is
# not a silent truncate of 10+ (those never match complete_at).
# shellcheck disable=SC2016
JQ_ISO_DEFS='
  def strict_iso_instant:
    (. | sub("\\.\\d+"; "")) as $s |
    ($s | sub("Z$"; "") | sub("[+-][0-9]{2}:[0-9]{2}$"; "")) as $wall |
    (try (($wall + "Z") | fromdateiso8601 | todateiso8601) catch null) == ($wall + "Z");
  def complete_at:
    (. != null) and ((. | type) == "string") and (. | test($re)) and strict_iso_instant;
  def instant_sort_key:
    (capture("(?<wall>^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<frac>\\.[0-9]{1,9})?(?<tz>Z|[+-][0-9]{2}:[0-9]{2})$")) as $p |
    ($p.wall + "Z" | fromdateiso8601) as $wall_epoch |
    (
      if $p.tz == "Z" then 0
      else
        ($p.tz | capture("^(?<sign>[+-])(?<hh>[0-9]{2}):(?<mm>[0-9]{2})$")) as $o |
        (($o.hh | tonumber) * 3600 + ($o.mm | tonumber) * 60) *
          (if $o.sign == "+" then 1 else -1 end)
      end
    ) as $off |
    ($wall_epoch - $off) as $utc |
    (((($p.frac // ".") | ltrimstr(".")) + "000000000")[0:9] | tonumber) as $frac_ns |
    [$utc, $frac_ns];
'

# Malformed relevant evidence that would matter for the gate but cannot enter
# the stream — must hard-block before older-event recovery or reviewDecision
# aggregate fallback. Covers formal APPROVED/CHANGES_REQUESTED and any
# comment / non-dismissed body-VERDICT review with a recognized terminal
# VERDICT marker. Ordinary comments without a terminal VERDICT are ignored.
MALFORMED_EVIDENCE=$(echo "$PR_JSON" | jq -r --arg re "$ISO_AT_RE" "$JQ_ISO_DEFS"'
  def body_verdict:
    if .body == null then empty
    elif (.body | type) != "string" then empty
    elif (.body | test("(^|\n)VERDICT:\\s*(APPROVE|REQUEST_CHANGES)\\s*" +
      "$"; "i")) then
      (.body | capture("(?<v>VERDICT:\\s*(APPROVE|REQUEST_CHANGES))\\s*" +
      "$"; "im")).v
    else empty end;
  def login_of:
    (((.author // {}) | .login // "") // "");
  def is_approve_verdict:
    test("APPROVE"; "i") and (test("REQUEST_CHANGES"; "i") | not);
  # Format without author login: prior sensors assert discarded events are not
  # "selected" by requiring their login never appear in the verdict text.
  # Authorless is called out; otherwise kind + label + stamp identify the item.
  def fmt($kind; $lab_name; $who; $at):
    (if $who == "" then "\( $lab_name ) (authorless)" else $lab_name end) as $lab |
    [$kind, $lab, ($at // "null" | tostring)] | join(" ");
  [
    # Formal state that is relevant but unusable (bad time / authorless APPROVE).
    (.reviews[]? |
      select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") |
      select(
        (.submittedAt | complete_at | not) or
        (.state == "APPROVED" and (login_of == ""))
      ) |
      fmt("formal"; .state; login_of; .submittedAt)
    ),
    # Non-dismissed reviews whose only authorization path is a body VERDICT
    # line (COMMENTED / empty state / etc.) — same timestamp + authorless rules.
    (.reviews[]? |
      select(.state != "APPROVED" and .state != "CHANGES_REQUESTED" and .state != "DISMISSED") |
      (body_verdict // empty) as $v |
      select($v != null and $v != "") |
      select(
        (.submittedAt | complete_at | not) or
        (($v | is_approve_verdict) and (login_of == ""))
      ) |
      fmt("review-body"; $v; login_of; .submittedAt)
    ),
    # Comments with a recognized terminal VERDICT marker — fail closed on bad
    # timestamps and authorless APPROVE (never drop-then-recover).
    (.comments[]? |
      (body_verdict // empty) as $v |
      select($v != null and $v != "") |
      select(
        (.createdAt | complete_at | not) or
        (($v | is_approve_verdict) and (login_of == ""))
      ) |
      fmt("comment"; $v; login_of; .createdAt)
    )
  ] | if length == 0 then empty else join("; ") end') || die "jq failed extracting malformed review evidence (fail closed)"

VERDICT_EVENT=$(echo "$PR_JSON" | jq -r --arg re "$ISO_AT_RE" "$JQ_ISO_DEFS"'
  def body_verdict:
    if .body == null then empty
    elif (.body | type) != "string" then empty
    elif (.body | test("(^|\n)VERDICT:\\s*(APPROVE|REQUEST_CHANGES)\\s*" +
      "$"; "i")) then
      (.body | capture("(?<v>VERDICT:\\s*(APPROVE|REQUEST_CHANGES))\\s*" +
      "$"; "im")).v
    else empty end;
  def formal_verdict:
    if .state == "APPROVED" then "VERDICT: APPROVE"
    elif .state == "CHANGES_REQUESTED" then "VERDICT: REQUEST_CHANGES"
    else empty end;
  # Formal blocking/approval state always wins over body text on the same
  # review. DISMISSED (and other non-authorizing states) must not authorize
  # via a retained body VERDICT: APPROVE.
  def event_verdict:
    if .state == "APPROVED" or .state == "CHANGES_REQUESTED" then formal_verdict
    elif .state == "DISMISSED" then empty
    else body_verdict end;
  # Full accepted ISO instant + strict civil calendar. Prefix-only junk and
  # impossible dates (9999-02-31) must never sort above real evidence.
  def valid_at:
    (.at != null) and ((.at | type) == "string") and (.at | complete_at);
  def is_request_changes:
    (.verdict | test("REQUEST_CHANGES"; "i"));
  [
    (.reviews[]? | {
      source: "review",
      login: ((.author // {}) | .login // ""),
      at: (.submittedAt // null),
      sha: ((.commit // {}) | .oid // ""),
      body: .body,
      state: (.state // "")
    }),
    (.comments[]? | {
      source: "comment",
      login: ((.author // {}) | .login // ""),
      at: (.createdAt // null),
      sha: "",
      body: .body,
      state: ""
    })
  ]
  | map(
      . as $e
      | ($e | event_verdict) as $v
      | select($v != null and $v != "")
      | $e + { "verdict":
          $v
        }
    )
  | map(select(valid_at))
  # Authorless APPROVE is never independent and never clears the gate — drop it.
  # Authorless REQUEST_CHANGES still blocks (fail closed).
  | map(select(is_request_changes or ((.login != null) and (.login != ""))))
  # Ascending true UTC instant (offsets + fractions normalized). On equal
  # instants only, REQUEST_CHANGES (1) after APPROVE (0) so last wins.
  | sort_by((.at | instant_sort_key) + [if is_request_changes then 1 else 0 end])
  | last // empty
  | if . then
      [.login, .verdict, .source, .at, .sha] | @tsv
    else
      empty
    end') || die "jq failed extracting verdict event stream (fail closed)"

VERDICT_LOGIN=""
VERDICT_TEXT=""
VERDICT_SOURCE=""
VERDICT_AT=""
VERDICT_SHA=""
if [[ -n "$VERDICT_EVENT" ]]; then
  # TSV: login, verdict, source, at, sha (sha may be empty)
  VERDICT_LOGIN=$(printf '%s\n' "$VERDICT_EVENT" | cut -f1)
  VERDICT_TEXT=$(printf '%s\n' "$VERDICT_EVENT" | cut -f2)
  VERDICT_SOURCE=$(printf '%s\n' "$VERDICT_EVENT" | cut -f3)
  VERDICT_AT=$(printf '%s\n' "$VERDICT_EVENT" | cut -f4)
  VERDICT_SHA=$(printf '%s\n' "$VERDICT_EVENT" | cut -f5)
fi

SAME_AUTHOR_REVIEW=0
STALE_HEAD_VERDICT=0
MISSING_HEAD_BINDING=0
# SHA-bound evidence fails closed when current head is absent/null OR mismatches.
if [[ -n "$VERDICT_SHA" ]]; then
  if [[ -z "$HEAD_OID" ]]; then
    MISSING_HEAD_BINDING=1
  elif [[ "$VERDICT_SHA" != "$HEAD_OID" ]]; then
    STALE_HEAD_VERDICT=1
  fi
fi

if [[ -n "$MALFORMED_EVIDENCE" ]]; then
  # Drop-then-recover via an older valid approval or reviewDecision=APPROVED is
  # a false-green. Malformed relevant evidence is a hard blocker before any
  # aggregate recovery (and prevents READY even if a usable older event exists).
  BLOCKERS+=("malformed relevant review evidence cannot be used and hard-blocks (no drop-then-recover): $MALFORMED_EVIDENCE")
fi

if [[ -n "$VERDICT_TEXT" ]]; then
  # Usable chronological event is the gate — reviewDecision does not short-circuit.
  # Malformed relevant evidence (if any) already blocks above; a valid older
  # APPROVE must never alone produce READY when later relevant evidence was
  # discarded as malformed.
  if [[ "$MISSING_HEAD_BINDING" -eq 1 ]]; then
    BLOCKERS+=("newest VERDICT ($VERDICT_TEXT from $VERDICT_LOGIN via $VERDICT_SOURCE at $VERDICT_AT) is SHA-bound to ${VERDICT_SHA:0:7} but current head is absent/null — cannot verify binding (fail closed)")
  elif [[ "$STALE_HEAD_VERDICT" -eq 1 ]]; then
    BLOCKERS+=("newest VERDICT ($VERDICT_TEXT from $VERDICT_LOGIN via $VERDICT_SOURCE at $VERDICT_AT) is bound to stale head ${VERDICT_SHA:0:7}, not current head ${HEAD_OID:0:7} — re-review the tip (fail closed)")
  elif echo "$VERDICT_TEXT" | grep -i 'REQUEST_CHANGES' >/dev/null; then
    _msg="reviewer posted VERDICT: REQUEST_CHANGES ("
    _msg+="$VERDICT_LOGIN via $VERDICT_SOURCE at ${VERDICT_AT:-unknown})"
    BLOCKERS+=("$_msg")
  elif echo "$VERDICT_TEXT" | grep -i 'APPROVE' >/dev/null; then
    if [[ -z "$VERDICT_LOGIN" ]]; then
      # Defensive: authorless APPROVE is filtered above; still fail closed.
      BLOCKERS+=("VERDICT: APPROVE has no author — fail closed (cannot count as independent)")
    elif [[ -n "$MALFORMED_EVIDENCE" ]]; then
      # Never select an older/sibling valid APPROVE as gate-clearing when
      # relevant evidence was discarded as malformed (false-green path).
      :
    elif [[ -n "$AUTHOR" && "$VERDICT_LOGIN" == "$AUTHOR" ]]; then
      # L-015: GitHub refuses self-approval, so the comment is the only signal
      # the solo loop can produce. Real, but it is not an independent identity.
      SAME_AUTHOR_REVIEW=1
      _msg="L-015/L-021: VERDICT: APPROVE came from the PR author ("
      _msg+="$AUTHOR); GitHub blocks self-approval, so no formal review can exist. Prefer a REVIEWER_CMD cross-vendor identity; admin merge is the fallback."
      ADMIN_REASONS+=("$_msg")
    else
      _msg="VERDICT: APPROVE from "
      _msg+="$VERDICT_LOGIN via $VERDICT_SOURCE at ${VERDICT_AT:-unknown} (independent identity)"
      NOTES+=("$_msg")
    fi
  else
    BLOCKERS+=("no formal approval and no VERDICT: line — review is fail-closed (Law 5)")
  fi
elif [[ -z "$MALFORMED_EVIDENCE" ]]; then
  # No usable timestamped event and no malformed relevant evidence discarded:
  # reviewDecision is a fail-closed fallback only. Never use it to recover after
  # dropping malformed formal or verdict-bearing comment evidence.
  case "$REVIEW_DECISION" in
    APPROVED)
      NOTES+=("formal GitHub approval present (reviewDecision fallback; no usable timestamped event)")
      ;;
    CHANGES_REQUESTED)
      BLOCKERS+=("reviewDecision is CHANGES_REQUESTED")
      ;;
    *)
      BLOCKERS+=("no formal approval and no VERDICT: line — review is fail-closed (Law 5)")
      ;;
  esac
else
  # Malformed relevant evidence already recorded as a blocker. Do not recover
  # via reviewDecision=APPROVED. If reviewDecision is empty/other, still emit
  # the Law 5 no-review line so prior sensors that require it keep passing.
  case "$REVIEW_DECISION" in
    APPROVED|CHANGES_REQUESTED)
      # Aggregate already known; do not use it to authorize or double-count.
      ;;
    *)
      BLOCKERS+=("no formal approval and no VERDICT: line — review is fail-closed (Law 5)")
      ;;
  esac
fi

# Read check-runs and the combined commit status for HEAD_OID. Sets
# CHECK_BOUND (payload SHA is this head, page complete) and CHECK_GREEN
# (every check-run conclusion and every status state is the success token).
# The two answers are independent: a success token on the wrong SHA is bound=0
# green=1, so a head move cannot be laundered into "not green" or ignored.
# all(met) is true for an empty array. That is not "every required context
# ran": the live protection+ruleset list below is the authority, and an empty
# snapshot stays green=1 so a missing context is its own named blocker.
tier_c_read_checks() {
  local runs_json="" status_json="" parsed="" head=""
  head=$(printf '%s' "$HEAD_OID" | tr '[:upper:]' '[:lower:]')
  runs_json=$(gh api "repos/${REPO}/commits/${HEAD_OID}/check-runs?per_page=100" 2>/dev/null) || runs_json=""
  status_json=$(gh api "repos/${REPO}/commits/${HEAD_OID}/status" 2>/dev/null) || status_json=""
  CHECK_RUNS_JSON=${runs_json:-null}
  CHECK_STATUS_JSON=${status_json:-null}
  CHECK_BOUND=0
  CHECK_GREEN=0
  parsed=$(jq -nr --arg head "$head" --argjson runs "${runs_json:-null}" --argjson status "${status_json:-null}" '
    def tok: if type == "string" then ascii_downcase else "" end;
    def met: tok == "success";
    def bound:
      ((.status.sha | tok) == $head)
      and (.runs.total_count == (.runs.check_runs | length))
      and (.status.total_count == (.status.statuses | length))
      and ([.runs.check_runs[]? | ((.head_sha | tok) == $head)] | all);
    def green:
      ([.runs.check_runs[]?.conclusion] | all(met))
      and ([.status.statuses[]?.state] | all(met));
    {runs: $runs, status: $status}
    | if (.runs | type) != "object"
        or (.runs.check_runs | type) != "array"
        or (.runs.total_count | type) != "number"
        or (.status | type) != "object"
        or (.status.statuses | type) != "array"
        or (.status.sha | type) != "string"
        or (.status.total_count | type) != "number"
      then "0 0"
      else "\(if bound then 1 else 0 end) \(if green then 1 else 0 end)"
      end
  ' 2>/dev/null) || parsed=""
  case "$parsed" in
    "1 1") CHECK_BOUND=1; CHECK_GREEN=1 ;;
    "1 0") CHECK_BOUND=1; CHECK_GREEN=0 ;;
    "0 1") CHECK_BOUND=0; CHECK_GREEN=1 ;;
    *) CHECK_BOUND=0; CHECK_GREEN=0 ;;
  esac
}

# Live required-context list for the PR base. Union of classic branch
# protection (checks[].app_id, else contexts[]) and rulesets
# (required_status_checks[].integration_id kept as app_id). Either side
# unreadable, or a readable union that is empty, fails closed: a Tier C
# repo with no required checks is not mergeable by this floor.
# Sets REQUIRED_STATE to ok|empty|unreadable and REQUIRED_JSON to the union.
tier_c_load_required() {
  local base="" base_enc="" prot="" rules="" parsed="" state=""
  REQUIRED_STATE=unreadable
  REQUIRED_JSON='[]'
  base=$(jqr '.baseRefName // ""')
  if [[ ! "$base" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    return
  fi
  base_enc=${base//\//%2F}
  prot=$(gh api "repos/${REPO}/branches/${base_enc}/protection/required_status_checks" 2>/dev/null) || prot=""
  rules=$(gh api "repos/${REPO}/rules/branches/${base_enc}" 2>/dev/null) || rules=""
  if [[ -z "$prot" || -z "$rules" ]]; then
    return
  fi
  parsed=$(jq -nc --argjson prot "$prot" --argjson rules "$rules" '
    def norm_app:
      if . == null then null
      elif type == "number" then .
      elif type == "string" and test("^[0-9]+$") then tonumber
      else "__bad__" end;
    def as_req:
      ((.app_id // null) | norm_app) as $app
      | if (.context | type) != "string" or .context == "" or $app == "__bad__" then {bad: true}
        else {context: .context, app_id: $app, bad: false} end;
    def prot_list:
      if ($prot | type) != "object" then null
      elif (($prot | has("checks")) and (($prot.checks | type) != "array")) then null
      elif (($prot | has("contexts")) and (($prot.contexts | type) != "array")) then null
      elif ((($prot | has("checks")) | not) and (($prot | has("contexts")) | not)) then null
      else
        (
          (if ($prot | has("checks")) then [$prot.checks[] | as_req] else [] end)
          + (if ($prot | has("contexts")) then
              [ $prot.contexts[]
                | if type == "string" then {context: ., app_id: null} | as_req
                  else {bad: true} end ]
            else [] end)
        )
      end;
    def rules_list:
      if ($rules | type) != "array" then null
      else
        [ $rules[]
          | if (.type | type) != "string" then {bad: true}
            elif .type != "required_status_checks" then empty
            elif (.parameters | type) != "object"
              or ((.parameters | has("required_status_checks")) | not)
              or (.parameters.required_status_checks | type) != "array"
            then {bad: true}
            else
              .parameters.required_status_checks[]
              | {
                  context: .context,
                  app_id: (if has("integration_id") then .integration_id
                           elif has("app_id") then .app_id
                           else null end)
                }
              | as_req
            end
        ]
      end;
    if prot_list == null or rules_list == null then {state: "unreadable", checks: []}
    else
      (prot_list + rules_list) as $all
      | if any($all[]; .bad == true) then {state: "unreadable", checks: []}
        else
          [$all[] | select(.bad != true) | {context, app_id}]
          | unique_by([.context, (.app_id | tostring)])
          | if length == 0 then {state: "empty", checks: []}
            else {state: "ok", checks: .} end
        end
    end
  ' 2>/dev/null) || parsed=""
  state=$(printf '%s' "$parsed" | jq -r '.state // empty' 2>/dev/null) || state=""
  case "$state" in
    ok)
      REQUIRED_STATE=ok
      REQUIRED_JSON=$(printf '%s' "$parsed" | jq -c '.checks' 2>/dev/null) || REQUIRED_STATE=unreadable
      ;;
    empty) REQUIRED_STATE=empty ;;
    *) REQUIRED_STATE=unreadable ;;
  esac
}

# For each required {context, app_id}, count matching check-runs and statuses
# on the snapshot already read for HEAD_OID. app_id null matches a check-run
# of that name (any app) or a status of that context. A set app_id matches
# only a check-run whose app id equals it — a status cannot satisfy it, and
# a same-named run from another app does not count. Exactly one match is
# required; zero is missing, more than one is ambiguous. Success of that
# match is CHECK_GREEN (def met), not this count.
tier_c_match_required() {
  local report=""
  MATCH_REPORT='{"missing":[],"ambiguous":[]}'
  report=$(jq -nc --argjson req "$REQUIRED_JSON" --argjson runs "${CHECK_RUNS_JSON:-null}" --argjson status "${CHECK_STATUS_JSON:-null}" '
    def runs:
      if ($runs | type) == "object" and ($runs.check_runs | type) == "array" then $runs.check_runs
      else [] end;
    def stats:
      if ($status | type) == "object" and ($status.statuses | type) == "array" then $status.statuses
      else [] end;
    def shown:
      if .app_id == null then .context
      else "\(.context) (app_id \(.app_id))" end;
    def nmatches:
      . as $req
      | ([ runs[] | select(
            .name == $req.context
            and ($req.app_id == null or ((.app.id // .app_id) == $req.app_id))
          ) ] | length) as $rc
      | ([ stats[] | select(
            $req.app_id == null and .context == $req.context
          ) ] | length) as $sc
      | ($rc + $sc);
    if ($req | type) != "array" then error("required list")
    else
      [ $req[] | . as $r | {shown: ($r | shown), n: ($r | nmatches)} ]
      | {missing: [.[] | select(.n == 0) | .shown], ambiguous: [.[] | select(.n > 1) | .shown]}
    end
  ' 2>/dev/null) || report=""
  if [[ -z "$report" ]]; then
    REQUIRED_STATE=unreadable
    return
  fi
  MATCH_REPORT=$report
}

# --- 3. required checks, product red vs GHA infra (L-033) ----------------
# Deny-list below is the infra-vs-product split for every tier. It is not the
# Tier C gate: NEUTRAL, SKIPPED, STALE, and ACTION_REQUIRED are none of the
# failure tokens, so they must not count as green. Tier C allow-lists success
# on a SHA-bound re-read after the evaluator returns.
CHECK_SUMMARY=$(echo "$PR_JSON" | jq -r '
  [ .statusCheckRollup[]? | select(.__typename == "CheckRun" or .conclusion != null or .state != null) ]
  | map({name: (.name // .context // "check"),
         conclusion: ((.conclusion // .state // "") | ascii_upcase),
         steps: ((.steps? // []) | length)})')
FAILED=$(echo "$CHECK_SUMMARY" | jq -r '[.[] | select(.conclusion | test("FAIL|ERROR|TIMED_OUT|STARTUP_FAILURE|CANCELLED"))]')
PENDING=$(echo "$CHECK_SUMMARY" | jq -r '[.[] | select(.conclusion == "" or .conclusion == "PENDING" or .conclusion == "IN_PROGRESS" or .conclusion == "QUEUED")] | length')
FAILED_N=$(echo "$FAILED" | jq -r 'length')

if [[ "$PENDING" -gt 0 ]]; then
  BLOCKERS+=("$PENDING required check(s) still running — wait, do not merge into a pending gate")
fi

if [[ "$FAILED_N" -gt 0 ]]; then
  # Infra signature: startup_failure, or a "failure" with zero steps — nothing
  # ran, so there is no product signal in it (L-033).
  INFRA_N=$(echo "$FAILED" | jq -r '[.[] | select(.conclusion == "STARTUP_FAILURE" or .steps == 0)] | length')
  PRODUCT=$(echo "$FAILED" | jq -r '[.[] | select(.conclusion != "STARTUP_FAILURE" and .steps > 0) | .name] | join(", ")')
  if [[ -n "$PRODUCT" ]]; then
    BLOCKERS+=("product-red required check(s): $PRODUCT — a step actually failed; fix the code")
  fi
  if [[ "$INFRA_N" -gt 0 && -z "$PRODUCT" ]]; then
    INFRA_NAMES=$(echo "$FAILED" | jq -r '[.[] | select(.conclusion == "STARTUP_FAILURE" or .steps == 0) | .name] | join(", ")')
    ADMIN_REASONS+=("L-033: $INFRA_N required check(s) failed with the GitHub Actions infra signature (startup_failure / no steps / no runner): $INFRA_NAMES. Re-run once; if it repeats identically — especially concurrently on other open PRs — it is infra, not product. Never report it as remote green.")
  fi
fi

# --- 4. tier and posture --------------------------------------------------
if [[ "$DRAFT" == "true" ]]; then
  BLOCKERS+=("PR is a draft")
fi
if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
  BLOCKERS+=("branch conflicts with the base — re-sync origin/main first (multi-lane fleet)")
fi

# D-015 G12 floor: a Tier C head is mergeable only when (a) an E3 cross-vendor
# review verdict is bound to the exact head — the caller compares the
# evaluator's returned headSha to HEAD_OID, it does not trust the request —
# and (b) every context required by the base branch's protection and rulesets
# has exactly one matching success on a snapshot read for that same SHA after
# the evaluator returns. The required list is the live union (app_id kept).
# Unreadable or empty fails closed. A context that did not run is named.
# An unrelated success does not count. Evidence comes from
# scripts/pr-review-evidence.mjs — reuse, do not reimplement. Unreadable
# evidence, a missing or mismatched headSha, a check payload for another
# SHA, or any non-success token fails closed. Admin/force merge stays forbidden.
if [[ "$TIER" == "tier-c" ]]; then
  _floor_parts=()
  _ev_state=""
  _ev_reason=""
  _preflight_home=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  _review_js="${_preflight_home}/pr-review-evidence.mjs"
  # Node ESM main() compares import.meta.url (physical path) to argv[1]. A
  # mutation copy under /tmp (symlink to /private/tmp on macOS) would otherwise
  # load the file and exit 0 with empty stdout — fail-open as "unreadable"
  # only because we treat empty JSON as a blocker; resolve so the evaluator
  # actually runs.
  if [[ -e "$_review_js" ]]; then
    _review_js=$(CDPATH='' cd -- "$(dirname -- "$_review_js")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$_review_js")")
  fi
  _review_cfg="${_preflight_home}/../config/review-evidence.v1.json"
  if [[ ! "$HEAD_OID" =~ ^[0-9a-f]{40}$ ]]; then
    _floor_parts+=("evidence unreadable (head SHA missing or malformed)")
  elif [[ ! -f "$_review_js" ]]; then
    _floor_parts+=("evidence unreadable")
  elif ! command -v node >/dev/null; then
    _floor_parts+=("evidence unreadable")
  else
    _ev_args=(node "$_review_js" --repo "$REPO" --pr "$PR" --expected-head "$HEAD_OID")
    if [[ -n "${GIBSON_REVIEW_EVIDENCE_CONFIG:-}" && -f "${GIBSON_REVIEW_EVIDENCE_CONFIG}" ]]; then
      _ev_args+=(--config "$GIBSON_REVIEW_EVIDENCE_CONFIG")
    elif [[ -f "$_review_cfg" ]]; then
      _ev_args+=(--config "$_review_cfg")
    fi
    if [[ "$TEST_FIXTURE_OK" -eq 1 ]]; then
      _ev_args+=(--fixture "$TEST_FIXTURE_DIR")
    fi
    _ev_out=$("${_ev_args[@]}" 2>/dev/null) || true
    _ev_state=$(printf '%s' "$_ev_out" | jq -r '.state // empty' 2>/dev/null) || _ev_state=""
    _ev_reason=$(printf '%s' "$_ev_out" | jq -r '.reason // empty' 2>/dev/null) || _ev_reason=""
    _ev_head=$(printf '%s' "$_ev_out" | jq -r 'if (.headSha | type) == "string" then (.headSha | ascii_downcase) else "" end' 2>/dev/null) || _ev_head=""
    if [[ "$_ev_head" != "$HEAD_OID" ]]; then
      _floor_parts+=("evaluator headSha does not match this head")
    fi
    if [[ -z "$_ev_state" || -z "$_ev_reason" ]]; then
      _floor_parts+=("evidence unreadable")
    elif [[ "$_ev_state" == "success" && "$_ev_reason" == "pass" ]]; then
      :
    elif [[ "$_ev_reason" == "same-vendor-reviewer" ]]; then
      _floor_parts+=("same-vendor review")
    elif [[ "$_ev_reason" == "stale-head-only" || "$_ev_reason" == "stale-base" || "$_ev_reason" == "no-receipt-at-head" || "$_ev_reason" == "evidence-deleted" ]]; then
      _floor_parts+=("E3 not bound to this head ($_ev_reason)")
    elif [[ "$_ev_reason" == "api-error" || "$_ev_reason" == "config-error" ]]; then
      _floor_parts+=("evidence unreadable")
    else
      _floor_parts+=("E3 not bound to this head ($_ev_reason)")
    fi
  fi
  # After the evaluator returns: re-read checks for HEAD_OID. The earlier
  # pr-view rollup is not authority for this floor — a head move between the
  # two reads must block, and only an explicit success token is met.
  if [[ "$HEAD_OID" =~ ^[0-9a-f]{40}$ ]]; then
    tier_c_read_checks
    if [[ "$CHECK_BOUND" -ne 1 ]]; then
      _floor_parts+=("required checks not bound to this head")
    fi
    if [[ "$CHECK_GREEN" -ne 1 ]]; then
      _floor_parts+=("required checks not green")
    fi
    tier_c_load_required
    if [[ "$REQUIRED_STATE" == "unreadable" ]]; then
      _floor_parts+=("required check list unreadable")
    elif [[ "$REQUIRED_STATE" == "empty" ]]; then
      _floor_parts+=("required check list empty")
    else
      tier_c_match_required
      if [[ "$REQUIRED_STATE" == "unreadable" ]]; then
        _floor_parts+=("required check list unreadable")
      else
        while IFS= read -r ctx; do
          [[ -z "$ctx" ]] && continue
          _floor_parts+=("required context missing: $ctx")
        done < <(printf '%s' "$MATCH_REPORT" | jq -r '.missing[]?')
        while IFS= read -r ctx; do
          [[ -z "$ctx" ]] && continue
          _floor_parts+=("required context not exactly one: $ctx")
        done < <(printf '%s' "$MATCH_REPORT" | jq -r '.ambiguous[]?')
      fi
    fi
  fi
  if [[ ${#_floor_parts[@]} -gt 0 ]]; then
    _floor_msg=""
    for _p in "${_floor_parts[@]}"; do
      if [[ -z "$_floor_msg" ]]; then
        _floor_msg="$_p"
      else
        _floor_msg="$_floor_msg; $_p"
      fi
    done
    BLOCKERS+=("Tier C floor (G12, D-015) not met: $_floor_msg")
  fi
  if [[ ${#ADMIN_REASONS[@]} -gt 0 ]]; then
    BLOCKERS+=("Tier C has no admin path (D-015) — force/admin merge remains forbidden")
    ADMIN_REASONS=()
  fi
elif [[ ${#ADMIN_REASONS[@]} -gt 0 && "$LAUNCHED" -eq 1 ]]; then
  BLOCKERS+=("post-launch posture (--launched): no admin merge on any red — escalate to the owner")
  ADMIN_REASONS=()
fi

# --- verdict --------------------------------------------------------------
if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
  VERDICT=BLOCKED
  CODE=1
elif [[ ${#ADMIN_REASONS[@]} -gt 0 ]]; then
  VERDICT=ADMIN-CANDIDATE
  CODE=4
else
  VERDICT=READY
  CODE=0
fi

# Last step before READY. HEAD_OID was frozen at the first PR read; a push
# after the evaluator returns must not inherit that evidence.
if [[ "$VERDICT" == "READY" ]]; then
  _head_now=$(gh pr view "$PR" --repo "$REPO" --json headRefOid 2>/dev/null) || _head_now=""
  _head_now=$(printf '%s' "$_head_now" | jq -r 'if (.headRefOid | type) == "string" then (.headRefOid | ascii_downcase) else "" end' 2>/dev/null) || _head_now=""
  _head_was=$(printf '%s' "$HEAD_OID" | tr '[:upper:]' '[:lower:]')
  if [[ "$_head_now" != "$_head_was" ]]; then
    BLOCKERS+=("head moved during preflight")
    VERDICT=BLOCKED
    CODE=1
  fi
fi

if [[ "$JSON" -eq 1 ]]; then
  jq -n \
    --arg verdict "$VERDICT" --arg repo "$REPO" --argjson pr "$PR" \
    --arg tier "$TIER" --arg closes "$CLOSES" \
    --argjson same_author_review "$SAME_AUTHOR_REVIEW" \
    --argjson blockers "$(printf '%s\n' ${BLOCKERS[@]+"${BLOCKERS[@]}"} | jq -R . | jq -s 'map(select(. != ""))')" \
    --argjson admin_reasons "$(printf '%s\n' ${ADMIN_REASONS[@]+"${ADMIN_REASONS[@]}"} | jq -R . | jq -s 'map(select(. != ""))')" \
    '{verdict:$verdict, repo:$repo, pr:$pr, tier:$tier, closes:$closes,
      same_author_review:($same_author_review == 1),
      blockers:$blockers, admin_reasons:$admin_reasons}'
  exit "$CODE"
fi

echo "release-preflight $REPO#$PR — $VERDICT"
echo
for n in ${NOTES[@]+"${NOTES[@]}"}; do echo "  · $n"; done
if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
  echo
  echo "BLOCKED by:"
  for b in "${BLOCKERS[@]}"; do echo "  ✗ $b"; done
fi
if [[ ${#ADMIN_REASONS[@]} -gt 0 ]]; then
  echo
  echo "Not product-red, but not merge-authorized either:"
  for a in "${ADMIN_REASONS[@]}"; do echo "  ! $a"; done
  cat <<EOF

Pre-launch admin merge is permitted only if you can post ALL of this on the PR:
  [ ] local full gate green on the merge tip (name the commit)
  [ ] VERDICT: APPROVE recorded (or a formal review)
  [ ] security CLEAR
  [ ] tier is A or B (this PR: ${TIER:-unlabelled})
  [ ] the infra evidence above, quoted, not summarised
Name the skip. Never claim remote CI was green when it was not (L-033).
EOF
fi
exit "$CODE"
