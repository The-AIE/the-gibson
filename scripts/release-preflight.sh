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
       Reads closingIssuesReferences (what GitHub will actually do), not prose.
    2. Review. Reviews and comments form one normalized timestamped stream
       (newest wins, source type does not reorder). Formal review states
       (APPROVED / CHANGES_REQUESTED) are modeled as events when usable and
       always precede body VERDICT text on the same review; DISMISSED reviews
       never authorize via body text. reviewDecision is only a fail-closed
       fallback when no usable event exists and no malformed formal evidence
       was discarded. A newer VERDICT: REQUEST_CHANGES blocks even if an older
       formal approval remains. Timestamps must be a complete ISO-8601 instant
       with a real civil calendar (strict round-trip; impossible dates like
       9999-02-31 never normalize into the stream); authorless APPROVE never
       clears the gate; equal-time conflicts prefer REQUEST_CHANGES. A
       SHA-bound verdict must match the current PR head — absent/null head
       fails closed.
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
  --partial    this PR ships a slice: it MUST NOT close its issue (L-013)
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
  --json number,title,author,isDraft,mergeable,reviewDecision,labels,closingIssuesReferences,statusCheckRollup,reviews,comments,headRefOid 2>/dev/null) ||
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

# --- 1. close keywords (L-013) -------------------------------------------
if [[ "$PARTIAL" -eq 1 && -n "$CLOSES" ]]; then
  BLOCKERS+=("L-013: --partial, but GitHub will close $CLOSES on merge. Prose like \"does not fully resolve #N\" does not stop the linker — remove the keyword from the squash subject/body and unlink it in the Development sidebar, then re-run.")
elif [[ "$PARTIAL" -eq 0 && -z "$CLOSES" ]]; then
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
# fail-closed fallback when no usable event exists AND no malformed formal
# evidence was discarded.
#
# Usability gates (fail closed):
#   - timestamps must be a complete accepted ISO-8601 instant (not a prefix)
#     with a real civil calendar (strict round-trip; jq fromdateiso8601 must
#     never normalize Feb 31 / Apr 31 into a later day that sorts as "newest")
#   - formal state (APPROVED / CHANGES_REQUESTED) precedes body VERDICT text
#   - DISMISSED reviews never authorize via body VERDICT: APPROVE
#   - authorless APPROVE never counts as independent
#   - equal timestamps: REQUEST_CHANGES wins over APPROVE (source order ignored)
#   - SHA-bound events must match the current PR head; missing head fails closed
#   - malformed formal APPROVED/CHANGES_REQUESTED evidence blocks before any
#     reviewDecision aggregate fallback (no drop-then-recover path)

# Complete accepted GitHub-style instant: YYYY-MM-DDTHH:MM:SS[.frac](Z|±HH:MM)
# Rejects prefix-only junk like "9999-99-99Tbogus" and missing-timezone forms.
# Single-backslash fractional group: jq/Oniguruma sees (\.[0-9]+)? — a double
# bash escape would require a literal backslash before the digits and reject
# real fractional instants (over-rejection).
ISO_AT_RE='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$'

# Shared jq helpers: shape match + strict civil-calendar round-trip.
# fromdateiso8601 normalizes impossible dates (9999-02-31 → 9999-03-03); that
# must never enter the stream. Validate by stripping frac, taking the wall
# clock (drop Z/offset), parsing wall+Z, and requiring todateiso8601 to equal
# wall+Z. Offset forms are accepted when the wall is real and the offset
# matches ISO_AT_RE — do not require fromdateiso8601 on ±HH:MM (jq often
# rejects valid offsets and would over-reject GitHub-shaped stamps).
# shellcheck disable=SC2016
JQ_ISO_DEFS='
  def strict_iso_instant:
    (. | sub("\\.\\d+"; "")) as $s |
    ($s | sub("Z$"; "") | sub("[+-][0-9]{2}:[0-9]{2}$"; "")) as $wall |
    (try (($wall + "Z") | fromdateiso8601 | todateiso8601) catch null) == ($wall + "Z");
  def complete_at:
    (. != null) and ((. | type) == "string") and (. | test($re)) and strict_iso_instant;
'

# Malformed formal reviews that would be relevant (APPROVED / CHANGES_REQUESTED)
# but cannot enter the stream — must block before reviewDecision fallback.
MALFORMED_FORMAL=$(echo "$PR_JSON" | jq -r --arg re "$ISO_AT_RE" "$JQ_ISO_DEFS"'
  [
    .reviews[]? |
    select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") |
    select(
      (.submittedAt | complete_at | not) or
      (.state == "APPROVED" and (((.author // {}) | .login // "") == ""))
    ) |
    [
      (.state // "?"),
      (((.author // {}) | .login // "") | if . == "" then "(authorless)" else . end),
      (.submittedAt // "null" | tostring)
    ] | join(" ")
  ] | if length == 0 then empty else join("; ") end')

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
  # Ascending time; on ties, REQUEST_CHANGES (1) after APPROVE (0) so last wins.
  | sort_by([.at, (if is_request_changes then 1 else 0 end)])
  | last // empty
  | if . then
      [.login, .verdict, .source, .at, .sha] | @tsv
    else
      empty
    end')

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

if [[ -n "$MALFORMED_FORMAL" ]]; then
  # Drop-then-recover via reviewDecision=APPROVED is a false-green. Malformed
  # relevant formal evidence is a hard blocker before any aggregate fallback.
  BLOCKERS+=("malformed formal review evidence cannot be used and blocks before reviewDecision fallback: $MALFORMED_FORMAL")
fi

if [[ -n "$VERDICT_TEXT" ]]; then
  # Usable chronological event is the gate — reviewDecision does not short-circuit.
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
elif [[ -z "$MALFORMED_FORMAL" ]]; then
  # No usable timestamped event and no malformed formal discarded: reviewDecision
  # is a fail-closed fallback only. Never use it to recover after dropping
  # malformed formal APPROVED/CHANGES_REQUESTED evidence.
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
  # Malformed formal already recorded as a blocker; do not also claim "no review".
  :
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
