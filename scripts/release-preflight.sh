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
       re-runs identically and is usually concurrent across open PRs.
    4. Tier. tier-c never gets an admin path; that is a human gate.

  Read-only. It never merges, never comments, never edits.

WHY
  L-013 auto-closed multi-phase issues four times. L-015 / L-021 deadlocked the
  solo loop on reviews GitHub will not let it make. L-033 sent the release hat
  round the same infra-vs-product diagnosis on every red check. Each of those is
  cheap to check and expensive to get wrong, so a script checks them.

RISKS
  - Read-only: worst case is a wrong verdict, which the checklist it prints lets
    you audit. It does not authorize anything by itself; a human still merges
    Tier C, and ADMIN-CANDIDATE is a pre-launch operator decision, not a green light.

USAGE
  release-preflight.sh <pr> [--repo owner/name] [--partial] [--launched] [--json]
  release-preflight.sh --help

  <pr>         pull request number
  --repo       defaults to the current repo (gh)
  --partial    this PR ships a slice: it MUST NOT close its issue (L-013).
               Also auto-detected from Related-only body or a partial marker.
  --launched   post-launch posture: no admin path on any red, ever (L-033)
  --json       machine-readable verdict for a driver

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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_ARG="${2:-}"; shift ;;
    --partial) PARTIAL=1 ;;
    --launched) LAUNCHED=1 ;;
    --json) JSON=1 ;;
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

PR_JSON=$(gh pr view "$PR" --repo "$REPO" \
  --json number,title,body,author,isDraft,mergeable,reviewDecision,labels,closingIssuesReferences,statusCheckRollup,reviews,comments,headRefOid 2>/dev/null) ||
  die "could not read $REPO#$PR"

jqr() { echo "$PR_JSON" | jq -r "$1"; }
command -v jq >/dev/null || die "jq is required"

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
if printf '%s' "$TITLE" | grep -Eiq \
  '(^|[^A-Za-z])(fix|close|resolve|closes|fixes|resolves)[[:space:]]*\(?#[[:digit:]]+'; then
  title_has_close_kw=1
fi

auto_partial=0
if [[ "$PARTIAL" -eq 1 ]]; then
  auto_partial=1
elif printf '%s' "$BODY" | grep -Eiq \
  '(^|[[:space:][:punct:]])(\[partial\]|partial[[:space:]]+ship|partial:)'; then
  auto_partial=1
else
  # Related-only: Related #N present, no closing keyword for any issue.
  if printf '%s' "$BODY" | grep -Eiq \
    '(^|[[:space:]])related:[[:space:]]*#?[[:digit:]]+|(^|[[:space:]])related[[:space:]]+#[[:digit:]]+'; then
    if ! printf '%s' "$BODY" | grep -Eiq \
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
    elif (.body | test("(^|\n)VERDICT:\\s*(APPROVE|REQUEST_CHANGES)\\s*$"; "i")) then
      (.body | capture("(?<v>VERDICT:\\s*(APPROVE|REQUEST_CHANGES))\\s*$"; "im")).v
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
    elif (.body | test("(^|\n)VERDICT:\\s*(APPROVE|REQUEST_CHANGES)\\s*$"; "i")) then
      (.body | capture("(?<v>VERDICT:\\s*(APPROVE|REQUEST_CHANGES))\\s*$"; "im")).v
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
  | map(. as $e | ($e | event_verdict) as $v | select($v != null and $v != "") | $e + {verdict: $v})
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
  elif echo "$VERDICT_TEXT" | grep -qi 'REQUEST_CHANGES'; then
    BLOCKERS+=("reviewer posted VERDICT: REQUEST_CHANGES ($VERDICT_LOGIN via $VERDICT_SOURCE at ${VERDICT_AT:-unknown})")
  elif echo "$VERDICT_TEXT" | grep -qi 'APPROVE'; then
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
      ADMIN_REASONS+=("L-015/L-021: VERDICT: APPROVE came from the PR author ($AUTHOR); GitHub blocks self-approval, so no formal review can exist. Prefer a REVIEWER_CMD cross-vendor identity; admin merge is the fallback.")
    else
      NOTES+=("VERDICT: APPROVE from $VERDICT_LOGIN via $VERDICT_SOURCE at ${VERDICT_AT:-unknown} (independent identity)")
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

# --- 3. required checks, product red vs GHA infra (L-033) ----------------
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

if [[ ${#ADMIN_REASONS[@]} -gt 0 ]]; then
  if [[ "$TIER" == "tier-c" ]]; then
    BLOCKERS+=("Tier C is a human merge gate (Law 7) — no admin path, whatever the CI is doing")
    ADMIN_REASONS=()
  elif [[ "$LAUNCHED" -eq 1 ]]; then
    BLOCKERS+=("post-launch posture (--launched): no admin merge on any red — escalate to the owner")
    ADMIN_REASONS=()
  fi
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
