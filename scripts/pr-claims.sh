#!/usr/bin/env bash
# pr-claims.sh — read the GitHub-native active-work claim source
set -euo pipefail

usage() {
  cat <<'EOF'
pr-claims.sh — inspect active-work claims in pull requests

USAGE
  pr-claims.sh list <owner/repo>
  pr-claims.sh list-open-numbers <owner/repo>
  pr-claims.sh find <owner/repo> <claim-id>
  pr-claims.sh find-open-pr <owner/repo> <claim-id> <pull-request-number>
  pr-claims.sh find-terminal <owner/repo> <claim-id>
  pr-claims.sh find-terminal-pr <owner/repo> <claim-id> <pull-request-number>
  pr-claims.sh close <owner/repo> <pull-request-number>

`list`/`find` cover live (open) claims. The list output is tab-separated:
  number, claim id, scope, head branch, URL, created_at, updated_at,
  is_cross_repository

`is_cross_repository` (#153 review round 5, P1) is the LIVE inventory's
repository identity, carried for the same reason `find-terminal` has always
carried it: `release-claim.sh` closes an open PR on the strength of this row,
and `gh pr close` is irreversible. A fork PR can legitimately carry a
well-formed claim marker and a head branch name identical to the one the claim
id derives, so marker + branch alone cannot prove the PR belongs to this
repository. The column is `true` or `false` and nothing else — GraphQL's
`isCrossRepository` is validated as a real boolean before it is stringified, so
a null/missing/renamed field poisons the whole command instead of being read as
"same repository".

`find-open-pr <claim-id> <number>` is the BOUND open-claim evidence read
(#153 review freeze/revalidate P1). `list` inventories who holds what but does
not carry `headRefOid`; closing an open PR without freezing that exact head
SHA lets a concurrent push advance the branch between inventory and close, so
post-close terminal cleanup can delete worktree/branches against the *new*
SHA. `find-open-pr` answers "is OPEN PR #<number> exact evidence for this
claim id right now?" with a fully validated row:

  number, claim id, scope, issue, head branch, head SHA, URL, state (OPEN),
  is_cross_repository, base repository (from the PR's own URL), created_at,
  updated_at

It selects on exact claim marker AND exact PR number AND OPEN state, then
requires the same shape contract as `list` plus a real 40-hex head SHA and
base-repository identity re-derived from the PR URL. A missing, closed,
mismatched, cross-repo-unproven, or unreadable PR yields no row (or nonzero
exit) rather than a partial answer. Callers freeze the head SHA from this
row, re-read immediately before `gh pr close`, and refuse if any identity
moved.

`list-open-numbers` answers a DIFFERENT question from `list`, and the
difference is the whole point (#153 review round 4). `list` is the claim
inventory: it only sees a PR once that PR carries a well-formed claim marker.
So "this claim id is absent from `list`" is satisfied both by a PR that
genuinely closed AND by a PR that is still wide open with its marker deleted
or rewritten. A caller that just closed a PR and wants to prove it is no
longer holding the issue cannot tell those apart from `list` alone.
`list-open-numbers` prints the number of EVERY open pull request in the
repository, one per line, regardless of body content, so that caller can bind
its proof to the exact PR number as well as the exact claim id. It validates
that every number is numeric and refuses the whole command otherwise; a
gh/jq/pagination failure exits nonzero exactly as `list` does.

`find-terminal` searches every PR state and returns only claims whose PR has
reached a terminal state (MERGED or CLOSED) — used by release-claim.sh to
release a PR-body claim after its PR is done, when no main-ledger row exists
(#153). Its output is tab-separated:
  number, claim id, scope, issue, head branch, head SHA, URL, state,
  is_cross_repository, merge commit SHA (empty when CLOSED unmerged),
  base repository (owner/name, parsed from the PR's own URL — never trusted
  from the query argument alone), created_at, updated_at

Exact head SHA and merge-commit SHA let a caller prove a worktree/branch is
safe to delete (its HEAD is that exact commit, or provably contained in the
merge) without trusting "the PR looks done". base repository is re-derived
from GitHub's own URL for the row, not assumed from the --repo argument, so a
caller can detect a mismatch instead of blindly trusting its own query.

VALIDATION (#153 blocker 6)
  pr-claims.sh is the single authoritative GitHub reader — it validates, it
  does not just pass text through. For every PR it considers, `list` and
  `find-terminal` require: exactly one claim marker, exactly one nonempty
  scope marker, exactly one well-formed issue marker whose number is
  consistent with the claim id, a safe nonempty head branch, a numeric PR
  number, a canonical PR URL whose repository matches the queried repo and
  whose pull-number matches the row, a boolean `isCrossRepository`, and (for
  find-terminal) a real head SHA plus a merge-commit SHA that agrees with the
  PR's own state (present only when MERGED). A PR with no claim marker at all
  is unclaimed and silently
  ignored — this validation only applies once a PR claims to be a claim.
  Duplicate markers, missing/empty fields, malformed claim/issue ids, a
  truncated body, a URL/number mismatch, or a gh/jq failure make the whole
  command exit nonzero. Downstream callers still keep their own defensive row
  checks — this is belt and suspenders, not a reason to drop them.

  Which PRs get considered differs by command, and deliberately so:

  `list` is an *inventory*: it must see every live claim, so it validates
  every open PR that carries a claim marker. A malformed open claim there is
  a real, current defect and poisoning the inventory is the correct
  fail-closed answer — a caller must not act on a live-claim view it cannot
  fully read.

  `find-terminal <claim-id>` is a *lookup* for one exact id across every PR
  the repository has ever had, so it is candidate-first: jq first selects
  only PRs whose body carries a claim marker whose id is exactly the
  requested one, and *then* validates those candidates in full. Otherwise any
  unrelated historical PR whose body predates the current marker format —
  #114 in mrhinkle/the-gibson has an Active-work claim line but no Claim
  scope line — permanently poisons every future release for every other
  claim, which is a fail-closed answer to a question nobody asked.

  Candidate-first narrows *which* PRs are inspected; it never softens the
  checks on the ones that match. A candidate with duplicate or malformed
  markers, a mismatched URL/number, or evidence that disagrees with the PR's
  own state still fails the whole command, as does a gh/jq/pagination
  failure. More than one PR carrying the exact same claim marker is
  ambiguous evidence and is refused rather than resolved by guessing.

  `find-terminal-pr <claim-id> <number>` answers the *bound* question a
  caller that already knows which PR it is releasing should ask: "is PR
  #<number> terminal evidence for exactly this claim id?". It selects on the
  exact claim marker AND the exact PR number, then applies every check
  find-terminal applies, unchanged. It exists because a claim id may legally
  be reused after its first PR reached a terminal state (a released claim id
  is free again), which makes the *global* id lookup permanently ambiguous
  from the second generation onward while the caller's own question —
  "release the claim on the PR I just closed" — stays perfectly unambiguous.
  Binding to the known number is therefore the fix; weakening find-terminal's
  ambiguity refusal is not. A number that is OPEN, missing, carries some
  other claim id, or fails any evidence check yields no row (or a nonzero
  exit) exactly as find-terminal would.

LEGACY TERMINAL-CLAIM SCHEMA (#153 follow-up, find-terminal only)
  Real claims merged before the machine markers existed carry the claim
  marker and nothing else machine-readable — mrhinkle/the-gibson#143 is the
  motivating case. Refusing them forever would mean a claim that genuinely
  shipped can never be released, so find-terminal accepts a SECOND, strictly
  defined body schema. It parses that body's own evidence; it never invents,
  defaults, or infers scope or issue data.

  A candidate qualifies as legacy only when BOTH current-format markers are
  ENTIRELY absent. A body carrying one of the two is a current-format claim
  missing a required field and still fails closed — legacy is not a fallback
  for a malformed current claim.

  A legacy candidate must then satisfy, exactly:
    - exactly one `- Active-work claim: <id>` line (as always);
    - exactly one line of the form `Closes #<n>.` — this is the issue
      binding, and the claim id must be consistent with `<n>` under the same
      rule the current format uses. Zero closing lines (a marker-only body)
      or more than one are both refused;
    - exactly one `## Cumulative scope` heading. The section runs to the next
      Markdown heading or end of body, and every non-blank line in it must be
      a single backticked path bullet: `` - `some/path` ``. Prose, a bare
      bullet, a nested list, an empty section, an unsafe or absolute or
      `..`-bearing or directory-suffixed path, or a repeated path all fail.
      The parsed paths, space-joined, ARE the claim scope — the same shape
      `- Claim scope:` carries — so scope stays real evidence read off the
      PR body rather than a placeholder.
  Everything else — head branch, head SHA, URL/repository/number agreement,
  timestamps, state vs merge-commit consistency, duplicate/ambiguity
  refusal, pagination — is identical to the current-format path.

  `list` is deliberately NOT given this schema. An open claim is current
  work, is written by today's claim.sh, and must carry today's markers.

PAGINATION (#153 follow-up)
  `list` and `find-terminal` walk every page of the repository's pull
  requests via GraphQL cursor pagination (`gh api graphql --paginate`), not a
  fixed --limit. A repository with more open PRs (or more total PRs) than any
  single-page cap still gets a complete, authoritative view — no claim is
  silently dropped because it landed on a later page.
EOF
}

[[ $# -ge 2 ]] || { usage >&2; exit 2; }
COMMAND="$1"
REPO="$2"
shift 2

command -v gh >/dev/null 2>&1 || {
  echo "pr-claims.sh: ERROR: gh (GitHub CLI) required" >&2
  exit 2
}

# Validated once, up front: the value is interpolated directly into a jq
# program string below (gh's --jq has no --arg-style injection point), so it
# must be proven free of quote/backslash/newline characters first. The
# regex's single required "/" also guarantees the owner/name split below is
# unambiguous.
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "pr-claims.sh: ERROR: repo must be owner/name, got '$REPO'" >&2
  exit 2
}
REPO_OWNER="${REPO%%/*}"
REPO_NAME="${REPO#*/}"

list_claims() {
  gh api graphql --paginate \
    -f query='
      query($owner: String!, $name: String!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequests(first: 100, after: $endCursor, states: [OPEN]) {
            nodes {
              number
              body
              headRefName
              url
              createdAt
              updatedAt
              isCrossRepository
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }' \
    -f owner="$REPO_OWNER" -f name="$REPO_NAME" \
    --jq '
      .data.repository.pullRequests.nodes[]
      | (.body // "") as $body
      | ($body | split("\n") | map(select(startswith("- Active-work claim: ")))) as $claimLines
      | if ($claimLines | length) == 0 then empty else
        (if ($claimLines | length) > 1 then
           error("duplicate Active-work claim marker(s) in PR #\(.number) body (\($claimLines|length) found)")
         else . end)
        | ($claimLines[0] | sub("^- Active-work claim: "; "")) as $claim
        | (if ($claim == "") then error("PR #\(.number): empty Active-work claim id") else . end)
        | ($body | split("\n") | map(select(startswith("- Claim scope: ")))) as $scopeLines
        | (if ($scopeLines | length) != 1 then
             error("PR #\(.number): expected exactly one Claim scope marker, found \($scopeLines|length)")
           else ($scopeLines[0] | sub("^- Claim scope: "; "")) end) as $scope
        | (if ($scope == "") then error("PR #\(.number): Claim scope marker is empty") else . end)
        | ($body | split("\n") | map(select(startswith("- Issue: #")))) as $issueLines
        | (if ($issueLines | length) != 1 then
             error("PR #\(.number): expected exactly one Issue marker, found \($issueLines|length)")
           else ($issueLines[0] | sub("^- Issue: #"; "")) end) as $issueNum
        | (if ($issueNum | test("^[0-9]+$") | not) then
             error("PR #\(.number): malformed Issue marker '"'"'\($issueNum)'"'"'")
           else . end)
        | (if ($claim | test("^issue-([A-Za-z][A-Za-z0-9]*-)?" + $issueNum + "-[A-Za-z0-9-]+$") | not) then
             error("PR #\(.number): claim id '"'"'\($claim)'"'"' is inconsistent with Issue marker #\($issueNum)")
           else . end)
        | (if ((.headRefName // "") == "") or ((.headRefName | test("^[A-Za-z0-9._/-]+$")) | not) then
             error("PR #\(.number): unsafe/empty head branch '"'"'\(.headRefName // "")'"'"'")
           else . end)
        | (if (.number | type) != "number" then
             error("PR #\(.number // "?"): PR number is not numeric")
           else . end)
        | ((try (.url | capture("^https://github\\.com/(?<repo>[^/]+/[^/]+)/pull/(?<num>[0-9]+)$")) catch null)) as $urlCap
        | (if ($urlCap == null) then
             error("PR #\(.number): cannot parse canonical PR URL \(.url)")
           else . end)
        | (if ($urlCap.repo != "'"$REPO"'") then
             error("PR #\(.number): PR URL repository (\($urlCap.repo)) does not match queried repository ('"$REPO"')")
           else . end)
        | (if (($urlCap.num | tonumber) != .number) then
             error("PR #\(.number): PR URL pull-number (\($urlCap.num)) does not match PR number")
           else . end)
        | (if ((.createdAt // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") | not) then
             error("PR #\(.number): created timestamp is not ISO-8601 UTC '"'"'\(.createdAt // "")'"'"'")
           else . end)
        | (if ((.updatedAt // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") | not) then
             error("PR #\(.number): updated timestamp is not ISO-8601 UTC '"'"'\(.updatedAt // "")'"'"'")
           else . end)
        # Repository identity, checked as a TYPE not a truthiness (#153 review
        # round 5, P1). `.isCrossRepository // false` would read a null (field
        # removed, schema drift, a partial error payload) as "same repository"
        # — the one answer that licenses closing the PR. Only a real boolean is
        # evidence; anything else poisons the command.
        | (if (.isCrossRepository | type) != "boolean" then
             error("PR #\(.number): isCrossRepository is missing or not a boolean '"'"'\(.isCrossRepository // "null")'"'"' — cannot prove repository identity")
           else . end)
        | [
            (.number | tostring),
            $claim,
            $scope,
            .headRefName,
            .url,
            .createdAt,
            .updatedAt,
            (.isCrossRepository | tostring)
          ]
        | @tsv
      end'
}

# Every OPEN pull-request number in the repository, body-agnostic (#153 review
# round 4, P1). This deliberately does NOT filter on a claim marker: its job is
# to answer "is PR #N still open?" for a caller that has just closed #N, and a
# marker-filtered view answers "no" for an open PR whose marker was removed or
# rewritten — the exact hostile case this closes. The GraphQL operation is
# NAMED (openPrNumbers) so the query is distinguishable from list_claims' own
# `states: [OPEN]` query by anything inspecting the request.
list_open_pr_numbers() {
  gh api graphql --paginate \
    -f query='
      query openPrNumbers($owner: String!, $name: String!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequests(first: 100, after: $endCursor, states: [OPEN]) {
            nodes {
              number
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }' \
    -f owner="$REPO_OWNER" -f name="$REPO_NAME" \
    --jq '
      .data.repository.pullRequests.nodes[]
      | (if (.number | type) != "number" then
           error("open pull-request number is not numeric")
         else . end)
      | (.number | tostring)'
}

# Bound OPEN PR claim evidence for exact claim id $1 and exact PR number $2.
# Both args must already have passed shape checks (literal claim id + bare
# decimal number): they are interpolated into the jq program (gh's --jq has
# no --arg). Candidate-first on exact claim marker + exact number + OPEN
# state; every field below is then validated in full. Emits one fully
# validated TSV row or empty success; gh/jq/pagination/validation failure
# exits nonzero via the caller's capture.
list_open_claim_evidence() {
  local want="$1" num="$2"
  gh api graphql --paginate \
    -f query='
      query openPrClaimEvidence($owner: String!, $name: String!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequests(first: 100, after: $endCursor, states: [OPEN]) {
            nodes {
              number
              body
              headRefName
              headRefOid
              url
              createdAt
              updatedAt
              state
              isCrossRepository
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }' \
    -f owner="$REPO_OWNER" -f name="$REPO_NAME" \
    --jq '
      .data.repository.pullRequests.nodes[]
      | select(.state == "OPEN")
      | select(.number == '"$num"')
      | (.body // "") as $body
      | ($body | split("\n") | map(select(startswith("- Active-work claim: ")))) as $claimLines
      | ($claimLines | map(sub("^- Active-work claim: "; ""))) as $claimIds
      | if ($claimIds | index("'"$want"'")) == null then empty else
        (if ($claimLines | length) > 1 then
           error("duplicate Active-work claim marker(s) in PR #\(.number) body (\($claimLines|length) found)")
         else . end)
        | ($claimLines[0] | sub("^- Active-work claim: "; "")) as $claim
        | (if ($claim == "") then error("PR #\(.number): empty Active-work claim id") else . end)
        | ($body | split("\n") | map(select(startswith("- Claim scope: ")))) as $scopeLines
        | (if ($scopeLines | length) != 1 then
             error("PR #\(.number): expected exactly one Claim scope marker, found \($scopeLines|length)")
           else ($scopeLines[0] | sub("^- Claim scope: "; "")) end) as $scope
        | (if ($scope == "") then error("PR #\(.number): Claim scope marker is empty") else . end)
        | ($body | split("\n") | map(select(startswith("- Issue: #")))) as $issueLines
        | (if ($issueLines | length) != 1 then
             error("PR #\(.number): expected exactly one Issue marker, found \($issueLines|length)")
           else ($issueLines[0] | sub("^- Issue: #"; "")) end) as $issueNum
        | (if ($issueNum | test("^[0-9]+$") | not) then
             error("PR #\(.number): malformed Issue marker '"'"'\($issueNum)'"'"'")
           else . end)
        | (if ($claim | test("^issue-([A-Za-z][A-Za-z0-9]*-)?" + $issueNum + "-[A-Za-z0-9-]+$") | not) then
             error("PR #\(.number): claim id '"'"'\($claim)'"'"' is inconsistent with Issue marker #\($issueNum)")
           else . end)
        | (if ((.headRefName // "") == "") or ((.headRefName | test("^[A-Za-z0-9._/-]+$")) | not) then
             error("PR #\(.number): unsafe/empty head branch '"'"'\(.headRefName // "")'"'"'")
           else . end)
        | (if (.number | type) != "number" then
             error("PR #\(.number // "?"): PR number is not numeric")
           else . end)
        | (if ((.headRefOid // "") | test("^[0-9a-f]{40}$") | not) then
             error("PR #\(.number): head SHA (headRefOid) is missing or not 40-hex '"'"'\(.headRefOid // "")'"'"'")
           else . end)
        | ((try (.url | capture("^https://github\\.com/(?<repo>[^/]+/[^/]+)/pull/(?<num>[0-9]+)$")) catch null)) as $urlCap
        | (if ($urlCap == null) then
             error("PR #\(.number): cannot parse canonical PR URL \(.url)")
           else . end)
        | (if ($urlCap.repo != "'"$REPO"'") then
             error("PR #\(.number): PR URL repository (\($urlCap.repo)) does not match queried repository ('"$REPO"')")
           else . end)
        | (if (($urlCap.num | tonumber) != .number) then
             error("PR #\(.number): PR URL pull-number (\($urlCap.num)) does not match PR number")
           else . end)
        | (if ((.createdAt // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") | not) then
             error("PR #\(.number): created timestamp is not ISO-8601 UTC '"'"'\(.createdAt // "")'"'"'")
           else . end)
        | (if ((.updatedAt // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") | not) then
             error("PR #\(.number): updated timestamp is not ISO-8601 UTC '"'"'\(.updatedAt // "")'"'"'")
           else . end)
        | (if (.isCrossRepository | type) != "boolean" then
             error("PR #\(.number): isCrossRepository is missing or not a boolean '"'"'\(.isCrossRepository // "null")'"'"' — cannot prove repository identity")
           else . end)
        | (if (.state != "OPEN") then
             error("PR #\(.number): expected OPEN state for bound open evidence, got \(.state)")
           else . end)
        | [
            (.number | tostring),
            $claim,
            $scope,
            $issueNum,
            .headRefName,
            .headRefOid,
            .url,
            .state,
            (.isCrossRepository | tostring),
            $urlCap.repo,
            .createdAt,
            .updatedAt
          ]
        | @tsv
      end'
}

# Terminal (non-OPEN) PRs whose body carries a claim marker whose id is
# EXACTLY $1, fully validated. $1 must already have passed the literal-id
# shape check in the find-terminal case below: it is interpolated straight
# into the jq program (gh's --jq takes no --arg) and compared with jq's `==`
# via index(), so it is an exact string match, never a pattern.
#
# $2 (optional) narrows to the single PR with that exact number — the bound
# find-terminal-pr lookup. It must already have passed the ^[0-9]+$ shape
# check below, since it too is interpolated into the jq program. Narrowing
# changes only WHICH PRs are inspected; every validation below still applies
# in full to the one that matches.
list_terminal_candidates() {
  local want="$1" num="${2:-}"
  local num_filter=""
  if [[ -n "$num" ]]; then
    num_filter="| select(.number == $num)"
  fi
  gh api graphql --paginate \
    -f query='
      query($owner: String!, $name: String!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequests(first: 100, after: $endCursor) {
            nodes {
              number
              body
              headRefName
              headRefOid
              url
              createdAt
              updatedAt
              state
              isCrossRepository
              mergeCommit { oid }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }' \
    -f owner="$REPO_OWNER" -f name="$REPO_NAME" \
    --jq '
      .data.repository.pullRequests.nodes[]
      | select(.state != "OPEN")
      '"$num_filter"'
      | (.body // "") as $body
      | ($body | split("\n") | map(select(startswith("- Active-work claim: ")))) as $claimLines
      | ($claimLines | map(sub("^- Active-work claim: "; ""))) as $claimIds
      # CANDIDATE-FIRST (#153): only PRs carrying this exact claim id are
      # inspected at all. An unrelated historical PR whose body uses a
      # pre-#153 marker format is not this claim s evidence and must not
      # decide whether this claim can be released. Once a PR IS a candidate,
      # every check below applies in full — including the duplicate-marker
      # check, which still fires when the exact id appears twice.
      | if ($claimIds | index("'"$want"'")) == null then empty else
        (if ($claimLines | length) > 1 then
           error("duplicate Active-work claim marker(s) in PR #\(.number) body (\($claimLines|length) found)")
         else . end)
        | ($claimLines[0] | sub("^- Active-work claim: "; "")) as $claim
        | (if ($claim == "") then error("PR #\(.number): empty Active-work claim id") else . end)
        | ($body | split("\n")) as $lines
        | ($lines | map(select(startswith("- Claim scope: ")))) as $scopeLines
        | ($lines | map(select(startswith("- Issue: #")))) as $issueLines
        # LEGACY TERMINAL-CLAIM SCHEMA (#153 follow-up): a candidate merged
        # before the machine markers existed carries NEITHER "- Claim scope:"
        # nor "- Issue: #". It is admitted only when BOTH are entirely absent
        # — a body carrying one of the two is a current-format claim missing a
        # required field and still fails closed. The issue and the scope are
        # then PARSED from the evidence the body actually contains (exactly
        # one "Closes #<n>." line, exactly one "## Cumulative scope" section
        # of backticked path bullets); nothing is invented or defaulted.
        | (($scopeLines | length) == 0 and ($issueLines | length) == 0) as $legacy
        | (if $legacy then
             ([$lines[] | select(test("^Closes #[0-9]+\\.?[ \t]*$"))]) as $closes
             | (if ($closes | length) != 1 then
                  error("PR #\(.number): legacy terminal claim needs exactly one Closes #<n>. issue binding, found \($closes|length)")
                else ($closes[0] | capture("^Closes #(?<n>[0-9]+)").n) end)
           else
             (if ($issueLines | length) != 1 then
                error("PR #\(.number): expected exactly one Issue marker, found \($issueLines|length)")
              else ($issueLines[0] | sub("^- Issue: #"; "")) end)
           end) as $issueNum
        | (if ($issueNum | test("^[0-9]+$") | not) then
             error("PR #\(.number): malformed Issue marker '"'"'\($issueNum)'"'"'")
           else . end)
        | (if $legacy then
             ([$lines | to_entries[] | select(.value | test("^##[ \t]+Cumulative scope[ \t]*$")) | .key]) as $hdr
             | (if ($hdr | length) != 1 then
                  error("PR #\(.number): legacy terminal claim needs exactly one ## Cumulative scope section, found \($hdr|length)")
                else . end)
             | ($lines[($hdr[0] + 1):]) as $rest
             | ($rest | map(test("^#+[ \t]")) | index(true)) as $stop
             | (if $stop == null then $rest else $rest[0:$stop] end) as $section
             | ($section | map(select(test("^[ \t]*$") | not))) as $bullets
             | (if ($bullets | length) == 0 then
                  error("PR #\(.number): legacy ## Cumulative scope section is empty — no scope evidence to release on")
                else . end)
             # The trailing "// null" is load-bearing: capture/match emit an
             # EMPTY STREAM on no-match rather than raising, so without it an
             # unparseable line would vanish from this comprehension and a
             # body of prose plus one good bullet would release on that bullet
             # alone. "// null" turns no-match into an explicit null, which
             # the any(. == null) check below refuses.
             | ([$bullets[] | ((try (capture("^- `(?<p>[^`]+)`[ \t]*$").p) catch null) // null)]) as $paths
             | (if ($paths | any(. == null)) then
                  error("PR #\(.number): legacy ## Cumulative scope carries a line that is not a single backticked path bullet — refuse to invent scope")
                elif ($paths | any(test("^[A-Za-z0-9._][A-Za-z0-9._/-]*$") | not)) then
                  error("PR #\(.number): legacy ## Cumulative scope carries an unsafe path bullet")
                elif ($paths | any(test("(^|/)\\.\\.(/|$)"))) then
                  error("PR #\(.number): legacy ## Cumulative scope carries a parent-directory path bullet")
                elif ($paths | any(endswith("/"))) then
                  error("PR #\(.number): legacy ## Cumulative scope carries a directory-suffixed path bullet")
                elif (($paths | unique | length) != ($paths | length)) then
                  error("PR #\(.number): legacy ## Cumulative scope repeats a path bullet — ambiguous scope evidence")
                else ($paths | join(" ")) end)
           else
             (if ($scopeLines | length) != 1 then
                error("PR #\(.number): expected exactly one Claim scope marker, found \($scopeLines|length)")
              else ($scopeLines[0] | sub("^- Claim scope: "; "")) end)
           end) as $scope
        | (if ($scope == "") then error("PR #\(.number): Claim scope marker is empty") else . end)
        | (if ($claim | test("^issue-([A-Za-z][A-Za-z0-9]*-)?" + $issueNum + "-[A-Za-z0-9-]+$") | not) then
             error("PR #\(.number): claim id '"'"'\($claim)'"'"' is inconsistent with Issue marker #\($issueNum)")
           else . end)
        | (if ((.headRefName // "") == "") or ((.headRefName | test("^[A-Za-z0-9._/-]+$")) | not) then
             error("PR #\(.number): unsafe/empty head branch '"'"'\(.headRefName // "")'"'"'")
           else . end)
        | (if (.number | type) != "number" then
             error("PR #\(.number // "?"): PR number is not numeric")
           else . end)
        | (if ((.headRefOid // "") | test("^[0-9a-f]{40}$") | not) then
             error("PR #\(.number): head SHA (headRefOid) is missing or not 40-hex '"'"'\(.headRefOid // "")'"'"'")
           else . end)
        | ((try (.url | capture("^https://github\\.com/(?<repo>[^/]+/[^/]+)/pull/(?<num>[0-9]+)$")) catch null)) as $urlCap
        | (if ($urlCap == null) then
             error("PR #\(.number): cannot parse canonical PR URL \(.url)")
           else . end)
        | (if ($urlCap.repo != "'"$REPO"'") then
             error("PR #\(.number): PR URL repository (\($urlCap.repo)) does not match queried repository ('"$REPO"')")
           else . end)
        | (if (($urlCap.num | tonumber) != .number) then
             error("PR #\(.number): PR URL pull-number (\($urlCap.num)) does not match PR number")
           else . end)
        | (if ((.createdAt // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") | not) then
             error("PR #\(.number): created timestamp is not ISO-8601 UTC '"'"'\(.createdAt // "")'"'"'")
           else . end)
        | (if ((.updatedAt // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") | not) then
             error("PR #\(.number): updated timestamp is not ISO-8601 UTC '"'"'\(.updatedAt // "")'"'"'")
           else . end)
        | (if (.isCrossRepository | type) != "boolean" then
             error("PR #\(.number): isCrossRepository is missing or not a boolean '"'"'\(.isCrossRepository // "null")'"'"' — cannot prove repository identity")
           else . end)
        | (if (.state == "MERGED") and (((.mergeCommit.oid // "") | test("^[0-9a-f]{40}$")) | not) then
             error("PR #\(.number): MERGED but missing/malformed merge-commit SHA")
           elif (.state == "CLOSED") and ((.mergeCommit.oid // "") != "") then
             error("PR #\(.number): CLOSED but carries a merge-commit SHA (state/evidence mismatch)")
           else . end)
        | [
            (.number | tostring),
            $claim,
            $scope,
            $issueNum,
            .headRefName,
            .headRefOid,
            .url,
            .state,
            (.isCrossRepository | tostring),
            (.mergeCommit.oid // ""),
            $urlCap.repo,
            .createdAt,
            .updatedAt
          ]
        | @tsv
      end'
}

case "$COMMAND" in
  list)
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    # Buffered, never streamed: `gh api graphql --paginate` emits page 1
    # before it ever discovers that page 2 failed, so streaming would hand a
    # caller a partial inventory on stdout alongside a nonzero exit. A
    # truncated inventory is exactly as dangerous as an unreadable one — emit
    # all pages or none.
    rows=$(list_claims) || exit 1
    [[ -z "$rows" ]] || printf '%s\n' "$rows"
    ;;
  list-open-numbers)
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    # Buffered for the same reason `list` is: a partial page-1 answer on
    # stdout alongside a nonzero exit is a truncated inventory, and a caller
    # proving "PR #N is no longer open" from a truncated inventory proves
    # nothing. Emit all pages or none.
    numbers=$(list_open_pr_numbers) || exit 1
    if [[ -n "$numbers" ]]; then
      # Re-validate the shape here too: jq already refused a non-numeric
      # node, but this command's whole value to release-claim.sh is that a
      # line it prints IS an open PR number. Anything else poisons it.
      while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        [[ "$n" =~ ^[0-9]+$ ]] || {
          echo "pr-claims.sh: ERROR: open pull-request inventory for $REPO returned a non-numeric row '$n' — refuse" >&2
          exit 1
        }
      done <<EOF
$numbers
EOF
      printf '%s\n' "$numbers"
    fi
    ;;
  find)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    claim_id="$1"
    rows=$(list_claims) || exit 1
    printf '%s\n' "$rows" | awk -F '\t' -v want="$claim_id" '$2 == want { print; found=1 } END { exit !found }'
    ;;
  find-open-pr)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    claim_id="$1"
    pr_number="$2"
    # Both values are interpolated into the jq program (gh's --jq has no
    # --arg). Prove bare-decimal PR number and literal exact claim id first.
    [[ "$pr_number" =~ ^[0-9]+$ ]] || {
      echo "pr-claims.sh: ERROR: find-open-pr needs a numeric pull-request number, got '$pr_number'" >&2
      exit 2
    }
    [[ "$claim_id" =~ ^issue-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || {
      echo "pr-claims.sh: ERROR: find-open-pr needs a literal exact claim id (issue-<...>), got '$claim_id'" >&2
      exit 2
    }
    # Buffered all-or-none: partial pagination is unreadable evidence.
    open_rows=$(list_open_claim_evidence "$claim_id" "$pr_number") || exit 1
    open_count=$(printf '%s' "$open_rows" | grep -c . || true)
    if [[ "$open_count" -gt 1 ]]; then
      echo "pr-claims.sh: ERROR: $open_count open evidence rows came back for the single PR #$pr_number on $REPO — impossible evidence; refuse" >&2
      exit 1
    fi
    if [[ "$open_count" -eq 1 ]]; then
      emitted_id=$(cut -f2 <<<"$open_rows")
      [[ "$emitted_id" == "$claim_id" ]] || {
        echo "pr-claims.sh: ERROR: open evidence row carries claim id '$emitted_id', not the requested '$claim_id' — refuse" >&2
        exit 1
      }
      emitted_num=$(cut -f1 <<<"$open_rows")
      [[ "$emitted_num" == "$pr_number" ]] || {
        echo "pr-claims.sh: ERROR: bound open lookup asked for PR #$pr_number but the row is PR #${emitted_num:-?} — refuse" >&2
        exit 1
      }
      emitted_state=$(cut -f8 <<<"$open_rows")
      [[ "$emitted_state" == "OPEN" ]] || {
        echo "pr-claims.sh: ERROR: bound open lookup for PR #$pr_number returned state '${emitted_state:-?}', want OPEN — refuse" >&2
        exit 1
      }
      emitted_sha=$(cut -f6 <<<"$open_rows")
      [[ "$emitted_sha" =~ ^[0-9a-f]{40}$ ]] || {
        echo "pr-claims.sh: ERROR: bound open evidence for PR #$pr_number has a malformed/missing head SHA '${emitted_sha:-?}' — refuse" >&2
        exit 1
      }
      printf '%s\n' "$open_rows"
    fi
    ;;
  find-terminal|find-terminal-pr)
    if [[ "$COMMAND" == "find-terminal" ]]; then
      [[ $# -eq 1 ]] || { usage >&2; exit 2; }
      claim_id="$1"
      pr_number=""
    else
      [[ $# -eq 2 ]] || { usage >&2; exit 2; }
      claim_id="$1"
      pr_number="$2"
      # Interpolated into the jq program below (gh's --jq takes no --arg),
      # exactly like the claim id — prove it is a bare decimal first.
      [[ "$pr_number" =~ ^[0-9]+$ ]] || {
        echo "pr-claims.sh: ERROR: find-terminal-pr needs a numeric pull-request number, got '$pr_number'" >&2
        exit 2
      }
    fi
    # find-terminal takes a *literal exact* claim id, never a pattern: the
    # value is interpolated into the jq program (gh's --jq has no --arg) and
    # drives candidate selection there. Prove it is free of quotes,
    # backslashes, newlines, and regex/glob metacharacters before it can
    # reach jq at all.
    [[ "$claim_id" =~ ^issue-[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || {
      echo "pr-claims.sh: ERROR: $COMMAND needs a literal exact claim id (issue-<...>), got '$claim_id'" >&2
      exit 2
    }
    terminal_rows=$(list_terminal_candidates "$claim_id" "$pr_number") || exit 1
    # grep -c (not wc -l): command substitution stripped the trailing newline,
    # so wc -l would undercount a single-row result to 0.
    terminal_count=$(printf '%s' "$terminal_rows" | grep -c . || true)
    if [[ "$terminal_count" -gt 1 ]]; then
      if [[ -n "$pr_number" ]]; then
        echo "pr-claims.sh: ERROR: $terminal_count terminal rows came back for the single PR #$pr_number on $REPO — impossible evidence; refuse" >&2
      else
        echo "pr-claims.sh: ERROR: ambiguous terminal PR-body evidence for claim id '$claim_id' on $REPO — $terminal_count terminal PRs carry that exact claim marker; resolve by hand (or ask about one exact PR with 'find-terminal-pr $REPO $claim_id <number>')" >&2
      fi
      exit 1
    fi
    if [[ "$terminal_count" -eq 1 ]]; then
      # Defensive: jq already required an exact marker match to make this PR a
      # candidate, so a row whose claim column is anything else means the
      # candidate filter and the emitted row disagree. Refuse rather than hand
      # a caller evidence for some other claim.
      emitted_id=$(cut -f2 <<<"$terminal_rows")
      [[ "$emitted_id" == "$claim_id" ]] || {
        echo "pr-claims.sh: ERROR: terminal candidate row carries claim id '$emitted_id', not the requested '$claim_id' — refuse" >&2
        exit 1
      }
      if [[ -n "$pr_number" ]]; then
        emitted_num=$(cut -f1 <<<"$terminal_rows")
        [[ "$emitted_num" == "$pr_number" ]] || {
          echo "pr-claims.sh: ERROR: bound terminal lookup asked for PR #$pr_number but the row is PR #${emitted_num:-?} — refuse" >&2
          exit 1
        }
      fi
      printf '%s\n' "$terminal_rows"
    fi
    ;;
  close)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    gh pr close "$1" --repo "$REPO"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
