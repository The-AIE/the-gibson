#!/usr/bin/env bash
# formal-review.sh — post a GitHub formal PR review as the dedicated reviewer
# identity (L-015 / L-021 / issue #67 / issue #290)
set -euo pipefail

usage() {
  cat <<'HELP'
formal-review.sh — post a GitHub PR review under the dedicated reviewer identity (#67/#290)

WHAT IT DOES
  Creates a formal GitHub pull-request review (APPROVE / REQUEST_CHANGES / COMMENT)
  using GH_REVIEWER_TOKEN (or GIBSON_REVIEWER_TOKEN), never the builder's token.
  The review is bound to an exact 40-lowercase-hex commit_id (--commit). When the
  reviewer token is unset, exits 2 with setup instructions — does not silently
  fall back to the builder identity (that is the L-015 bug). Missing or invalid
  --commit is refused before any mutation.

WHY
  Solo-loop builder and reviewer shared one GitHub account, so gh pr review
  --approve was rejected and branch protection needed admin merges (L-021).
  Posting without commit_id could attach the decision to a later head (#290).

RISKS
  - Posts a real review on the PR (undo: dismiss review in GitHub UI).
  - Never uses GH_TOKEN / default gh auth for the review API call.
  - Tier C still requires a human (docs/14 G12) — this script does not merge.

USAGE
  formal-review.sh --pr N --repo owner/name --event approve|request-changes|comment \
                   --commit 40-lowercase-hex [--body TEXT | --body-file PATH] [--dry-run]
  formal-review.sh --help

ENV
  GH_REVIEWER_TOKEN or GIBSON_REVIEWER_TOKEN  required PAT/App token for the
                                              reviewer bot/account (not builder)

EXIT
  0  review posted (or dry-run success)
  1  API / validation failure
  2  usage or missing reviewer token
HELP
}

die() { echo "formal-review.sh: ERROR: $*" >&2; exit 1; }
die_usage() { echo "formal-review.sh: $*" >&2; exit 2; }
info() { echo "formal-review.sh: $*" >&2; }

PR="" REPO="" EVENT="" BODY="" BODY_FILE="" COMMIT="" DRY=0
_FR_BODY_TMP=""

cleanup_fr() {
  if [[ -n "${_FR_BODY_TMP:-}" ]]; then
    rm -f "$_FR_BODY_TMP"
  fi
}
trap cleanup_fr EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --event) EVENT="${2:-}"; shift 2 ;;
    --body) BODY="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$PR" && "$PR" =~ ^[0-9]+$ ]] || die_usage "--pr N required"
[[ -n "$REPO" && "$REPO" == */* ]] || die_usage "--repo owner/name required"
[[ -n "$EVENT" ]] || die_usage "--event approve|request-changes|comment required"
[[ -n "$COMMIT" ]] || die_usage "--commit <40-lowercase-hex> required"

case "$EVENT" in
  approve|APPROVE) EVENT=APPROVE ;;
  request-changes|REQUEST_CHANGES|changes-requested) EVENT=REQUEST_CHANGES ;;
  comment|COMMENT) EVENT=COMMENT ;;
  *) die_usage "--event must be approve|request-changes|comment" ;;
esac

# Refuse missing/invalid commit IDs before any mutation (no gh, no review).
if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  die "invalid --commit (need exactly 40 lowercase hex chars); refusing before mutation"
fi

if [[ -n "$BODY_FILE" ]]; then
  [[ -f "$BODY_FILE" ]] || die "body file missing: $BODY_FILE"
  BODY=$(cat "$BODY_FILE")
fi
[[ -n "$BODY" ]] || BODY="Gibson formal review ($EVENT) via formal-review.sh (#67)."

TOKEN="${GH_REVIEWER_TOKEN:-${GIBSON_REVIEWER_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  die_usage "GH_REVIEWER_TOKEN (or GIBSON_REVIEWER_TOKEN) is not set.
  Create a machine user or GitHub App with pull-requests: write on the target
  repo, store the token as GH_REVIEWER_TOKEN in the reviewer shell only — never
  reuse the builder's GH_TOKEN (L-015). See docs/13-adoption.md § dedicated reviewer."
fi

# Refuse to use the ambient GH_TOKEN by unsetting it for the child process.
if [[ "$DRY" -eq 1 ]]; then
  info "dry-run: would post $EVENT on $REPO#$PR commit $COMMIT as reviewer identity (token set, not printed)"
  info "body bytes: ${#BODY}"
  exit 0
fi

command -v gh >/dev/null || die "gh required"

# Explicit token only — clear GH_TOKEN so gh cannot fall back to builder auth.
export GH_TOKEN="$TOKEN"
unset GITHUB_TOKEN 2>/dev/null || true

# Prove identity is not empty (does not print the token).
WHO=$(gh api user -q .login 2>/dev/null || true)
[[ -n "$WHO" ]] || die "reviewer token cannot resolve gh api user"

_FR_BODY_TMP=$(mktemp)
printf '%s' "$BODY" > "$_FR_BODY_TMP"

info "posting $EVENT as @$WHO on $REPO#$PR commit $COMMIT"
# commit_id and event are raw strings (-f). body must use -F/--field so that
# @file is read; -f/--raw-field would send the literal "@path" token.
if ! gh api --method POST "repos/${REPO}/pulls/${PR}/reviews" \
    -f commit_id="$COMMIT" \
    -f event="$EVENT" \
    -F "body=@${_FR_BODY_TMP}" >/dev/null; then
  die "failed to create review on $REPO#$PR commit $COMMIT"
fi

info "OK — formal $EVENT from @$WHO on $REPO#$PR commit $COMMIT"
