#!/usr/bin/env bash
# agent-vendor.sh — walk a commit range for commits review-evidence cannot
# resolve to a vendor (the-gibson#503/#504/#506, follow-up to #520/#523).
#
# Sourced, never executed. One definition, shared by scripts/loop.sh (blocks the
# supervisor handoff), scripts/lib/convention-probes.sh (prepush.sh report) and
# the sensors, so the three cannot drift apart.
#
# WHY
#   The hooks from #523 stamp and check the Agent-Vendor trailer at commit time,
#   but only on a lane that declares its vendor. A lane created before #523 is
#   undeclared, and `git commit --no-verify` skips the hooks on any lane. Those
#   commits still reach review-evidence, which then reports identity-unresolved
#   at review time — the last place to learn it. This walk runs before the loop
#   spends a reviewer or hands a branch to the supervisor, and before the first
#   push, with the same decision rule the evaluator applies later.
#
# RULE (per commit in BASE..HEAD; the base commit itself is outside the range)
#   - author or committer email in the reserved `.invalid` domain (or the bare
#     `user@invalid` form): GitHub maps it to no login, the trailer is never
#     read (`no-login`, #503/#504); checked first, for every commit, lane-bot
#     authored or not;
#   - then, authored by a lane-bot login (`<id>+aie-agent-lanes-*[bot]@users.
#     noreply.github.com`): resolves by identity, no trailer needed;
#   - no `Agent-Vendor:` trailer anywhere in the message (`owner-unvendored`,
#     #506); more than one distinct vendor named; or a vendor outside
#     AUTHOR_COMMIT_VENDORS in scripts/pr-review-evidence.mjs.

# Same list as .githooks/{prepare-commit-msg,commit-msg}, scripts/claim.sh and
# scripts/setup-hooks.sh (AUTHOR_COMMIT_VENDORS in scripts/pr-review-evidence.mjs);
# setup-hooks.test.sh fails when they drift.
AGENT_VENDORS="claude codex grok devin"

# agent_vendor_known NAME — 0 when NAME (already lower-cased) is a vendor the
# evaluator resolves from the trailer.
agent_vendor_known() {
  local v
  for v in $AGENT_VENDORS; do
    [[ "$1" == "$v" ]] && return 0
  done
  return 1
}

# agent_vendor_lane_bot_email EMAIL — 0 when EMAIL is a lane-bot login's
# noreply address (the only identity review-evidence resolves without a trailer).
agent_vendor_lane_bot_email() {
  local e
  e=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$e" in
    *aie-agent-lanes-*\[bot\]@users.noreply.github.com) return 0 ;;
  esac
  return 1
}

# agent_vendor_commit_problem REPO SHA — prints ONE reason review-evidence would
# give for this commit, or nothing when it resolves. Always returns 0; a commit
# that cannot be read prints `unreadable`. Reasons: lane-bot (resolves, prints
# nothing), invalid-email:<addr>, no-trailer, multi-vendor:<a,b>, unknown-vendor:<v>.
agent_vendor_commit_problem() {
  local repo="$1" sha="$2" ae ce body line v vendors="" n=0
  ae=$(git -C "$repo" log -1 --format=%ae "$sha" 2>/dev/null) || { echo unreadable; return 0; }
  ce=$(git -C "$repo" log -1 --format=%ce "$sha" 2>/dev/null) || { echo unreadable; return 0; }
  # Both identities first, on every path: review-evidence resolves the author
  # AND the committer to a login, so a lane-bot author with a .invalid committer
  # still fails `committer:<sha>:no-login` (Codex review of #525).
  for v in "$ae" "$ce"; do
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
      *.invalid|*@invalid) echo "invalid-email:${v}"; return 0 ;;
    esac
  done
  if agent_vendor_lane_bot_email "$ae"; then
    return 0
  fi
  body=$(git -C "$repo" log -1 --format=%B "$sha" 2>/dev/null) || { echo unreadable; return 0; }
  # Every Agent-Vendor line anywhere in the message, exactly as the evaluator
  # matches them (case-insensitive key and value). Here-string, not a pipe into
  # a quiet grep (L-077).
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    v="${line#*:}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
    case " $vendors " in
      *" $v "*) ;;
      *) vendors="${vendors:+$vendors }$v"; n=$((n + 1)) ;;
    esac
  done <<EOF2
$(grep -iE '^Agent-Vendor:[[:blank:]]*[A-Za-z0-9_-]+[[:blank:]]*$' <<<"$body" || true)
EOF2
  if [[ "$n" -eq 0 ]]; then echo no-trailer; return 0; fi
  if [[ "$n" -gt 1 ]]; then echo "multi-vendor:$(printf '%s' "$vendors" | tr ' ' ',')"; return 0; fi
  if ! agent_vendor_known "$vendors"; then echo "unknown-vendor:${vendors}"; return 0; fi
  return 0
}

# agent_vendor_unresolved_shas REPO BASE HEAD — prints `<sha> <reason>` one per
# line for every commit in BASE..HEAD review-evidence would not resolve.
# Returns 0 when the range is readable (including an empty range, and including
# findings); 1 when the range cannot be walked. Same contract as
# dco_unsigned_shas in scripts/loop.sh, so the two walks sit side by side.
agent_vendor_unresolved_shas() {
  local repo="$1" base="$2" head="$3" sha log_out why
  git -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || return 1
  git -C "$repo" rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1 || return 1
  log_out=$(git -C "$repo" log --format=%H "${base}..${head}" 2>/dev/null) || return 1
  [[ -n "$log_out" ]] || return 0
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    why=$(agent_vendor_commit_problem "$repo" "$sha")
    [[ -n "$why" ]] || continue
    printf '%s %s\n' "$sha" "$why"
  done <<EOF2
$log_out
EOF2
  return 0
}

# agent_vendor_declared [DIR] — prints the vendor DIR's worktree declares, or
# nothing. Worktree scope ONLY, and only when extensions.worktreeConfig is true:
# with the extension off, `git config --worktree` silently falls back to --local,
# so a shared-config value would read as a declaration for every worktree of the
# repository (#523 round five). Same gate as .githooks/commit-msg; a reader that
# differs from the hooks declares lanes the hooks do not.
agent_vendor_declared() {
  local dir="${1:-.}" ext
  ext=$(git -C "$dir" config --get extensions.worktreeConfig 2>/dev/null || true)
  [[ "$ext" == "true" ]] || return 0
  git -C "$dir" config --worktree --get gibson.agentVendor 2>/dev/null | tr '[:upper:]' '[:lower:]' || true
}

# agent_vendor_fix_hint — the one-line remedy every caller prints with a finding.
agent_vendor_fix_hint() {
  echo "declare the lane (scripts/setup-hooks.sh --vendor from-reservation, or --vendor <claude|codex|grok|devin>), then git commit --amend / git rebase so each commit carries one Agent-Vendor trailer under an email GitHub maps to a login"
}
