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
#     noreply.github.com`) that config/review-evidence.v1.json AT THE TRUSTED
#     BASE REF (never the lane's own copy) lists with role "author" (and, when that identity has an authorCommits
#     allowlist, only for those exact SHAs): resolves by identity, no trailer
#     needed. The shape alone is not enough, and an unreadable config exempts
#     nothing;
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

# Lane-bot author logins the evaluator resolves without a trailer: the entries
# of config/review-evidence.v1.json with role "author" (the evaluator's own
# identity table), read from the TRUSTED BASE REF the walk is given — never from
# the candidate's working tree or branch, which the lane can edit to list a bot
# of its own (Codex round four on #525). Cached per repo + base commit.
# Unreadable (no such blob at the base, no node, bad JSON) → empty set and
# AGENT_VENDOR_TABLE_OK=0: fail closed, no exemption.
AGENT_VENDOR_AUTHOR_LOGINS=""
AGENT_VENDOR_AUTHOR_LOGINS_FOR=""
AGENT_VENDOR_TABLE_OK=0
agent_vendor_author_logins() { # repo base — prints "<login>\t<allowlist>" per author identity; 1 when unreadable
  local repo="$1" base="${2:-}" base_sha key
  base_sha=$(git -C "$repo" rev-parse --verify --quiet "${base}^{commit}" 2>/dev/null || true)
  key="$repo@$base_sha"
  if [[ "$AGENT_VENDOR_AUTHOR_LOGINS_FOR" != "$key" ]]; then
    AGENT_VENDOR_AUTHOR_LOGINS_FOR="$key"
    AGENT_VENDOR_AUTHOR_LOGINS=""
    AGENT_VENDOR_TABLE_OK=0
    if [[ -n "$base_sha" ]] && command -v node >/dev/null 2>&1; then
      # One line per author identity: "<login>\t<sha,sha,...>". The second
      # field is the identity's authorCommits allowlist ("-" when the list is
      # present but empty, "" when unrestricted); the evaluator rejects a listed
      # login's commit outside its allowlist as commit-not-allowed.
      if AGENT_VENDOR_AUTHOR_LOGINS=$(git -C "$repo" show "${base_sha}:config/review-evidence.v1.json" 2>/dev/null | node -e '
        let src = ""; process.stdin.on("data", (d) => { src += d; }); process.stdin.on("end", () => {
          const c = JSON.parse(src);
          if (!Array.isArray(c.identities)) process.exit(3);
          for (const i of c.identities) {
            if (typeof i.login !== "string" || !Array.isArray(i.roles) || !i.roles.includes("author")) continue;
            const allow = Array.isArray(i.authorCommits) ? i.authorCommits.filter((x) => typeof x === "string").map((x) => x.toLowerCase()) : [];
            if (Array.isArray(i.authorCommits) && allow.length === 0) allow.push("-");
            console.log(i.login.toLowerCase() + "\t" + allow.join(","));
          }
        });' 2>/dev/null) && [[ -n "$AGENT_VENDOR_AUTHOR_LOGINS" ]]; then
        AGENT_VENDOR_TABLE_OK=1
      else
        AGENT_VENDOR_AUTHOR_LOGINS=""
      fi
    fi
  fi
  [[ "$AGENT_VENDOR_TABLE_OK" -eq 1 ]] || return 1
  printf '%s\n' "$AGENT_VENDOR_AUTHOR_LOGINS"
}

# agent_vendor_login_of_noreply EMAIL — the GitHub login a noreply address
# encodes (`<id>+login@users.noreply.github.com`, or `login@users.noreply.
# github.com`), lower-cased; nothing for any other address.
agent_vendor_login_of_noreply() {
  local e local_part
  e=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$e" in
    *@users.noreply.github.com) ;;
    *) return 0 ;;
  esac
  local_part="${e%@users.noreply.github.com}"
  case "$local_part" in
    *+*) local_part="${local_part#*+}" ;;
  esac
  printf '%s\n' "$local_part"
}

# agent_vendor_lane_bot_email EMAIL [REPO BASE [SHA]] — 0 when EMAIL is a
# lane-bot login's noreply address that the evaluator resolves by identity: the
# login must have the evaluator's LANE_BOT_LOGIN shape (aie-agent-lanes-*[bot])
# AND be listed with role "author" in config/review-evidence.v1.json AT BASE in
# REPO AND, when that identity carries an authorCommits allowlist, SHA must be
# one of them (full 40-hex, exact). Returns 1 when not exempt, 2 when the login
# is listed but SHA is outside its allowlist (commit-not-allowed), 3 when the
# table at BASE is unreadable (nothing is exempt).
agent_vendor_lane_bot_email() {
  local login entry known allow sha a table
  login=$(agent_vendor_login_of_noreply "$1")
  [[ -n "$login" ]] || return 1
  case "$login" in
    aie-agent-lanes-*\[bot\]) ;;
    *) return 1 ;;
  esac
  [[ -n "${2:-}" && -n "${3:-}" ]] || return 3
  table=$(agent_vendor_author_logins "$2" "$3") || return 3
  sha=$(printf '%s' "${4:-}" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    known="${entry%%	*}"
    allow="${entry#*	}"
    [[ "$entry" == *"	"* ]] || allow=""
    [[ "$known" == "$login" ]] || continue
    [[ -n "$allow" ]] || return 0
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
    while IFS= read -r a; do
      [[ -n "$a" && "$a" == "$sha" ]] && return 0
    done <<EOF3
$(printf '%s' "$allow" | tr ',' '\n')
EOF3
    return 2
  done <<EOF2
$table
EOF2
  return 1
}

# agent_vendor_commit_problem REPO SHA [BASE] — prints ONE reason review-evidence
# would give for this commit, or nothing when it resolves. BASE is the trusted
# ref whose config/review-evidence.v1.json decides the lane-bot exemption. Always returns 0; a commit
# that cannot be read prints `unreadable`. Reasons: lane-bot (resolves, prints
# nothing), invalid-email:<addr>, unlisted-login:<login> (lane-bot shape not in
# the evaluator's identity table), commit-not-allowed:<login> (listed, but the
# SHA is outside its authorCommits allowlist), no-trailer, multi-vendor:<a,b>,
# unknown-vendor:<v>, identity-table-unreadable:<login> (lane-bot shape, but no
# readable identity table at BASE: nothing exempt).
agent_vendor_commit_problem() {
  local repo="$1" sha="$2" base="${3:-}" ae ce body line v vendors="" n=0 login full_sha bot_rc
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
  full_sha=$(git -C "$repo" rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null || true)
  agent_vendor_lane_bot_email "$ae" "$repo" "$base" "$full_sha"
  bot_rc=$?
  [[ "$bot_rc" -ne 0 ]] || return 0
  login=$(agent_vendor_login_of_noreply "$ae")
  case "$login" in
    aie-agent-lanes-*\[bot\])
      # 3: the table at BASE could not be read, nothing is exempt. 2: listed, but
      # this SHA is outside the identity's authorCommits allowlist (the
      # evaluator's commit-not-allowed). 1: unlisted, it resolves no login.
      case "$bot_rc" in
        3) echo "identity-table-unreadable:${login}" ;;
        2) echo "commit-not-allowed:${login}" ;;
        *) echo "unlisted-login:${login}" ;;
      esac
      return 0
      ;;
  esac
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

# agent_vendor_unresolved_shas REPO BASE HEAD [TABLE_BASE] — prints `<sha> <reason>`
# one per line for every commit in BASE..HEAD review-evidence would not resolve.
# The lane-bot identity table is read at TABLE_BASE (default BASE): the trusted
# base ref, never the candidate's own tree.
# Returns 0 when the range is readable (including an empty range, and including
# findings); 1 when the range cannot be walked. Same contract as
# dco_unsigned_shas in scripts/loop.sh, so the two walks sit side by side.
agent_vendor_unresolved_shas() {
  local repo="$1" base="$2" head="$3" table_base="${4:-$2}" sha log_out why
  git -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || return 1
  git -C "$repo" rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1 || return 1
  log_out=$(git -C "$repo" log --format=%H "${base}..${head}" 2>/dev/null) || return 1
  [[ -n "$log_out" ]] || return 0
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    why=$(agent_vendor_commit_problem "$repo" "$sha" "$table_base")
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
  # --bool --local: git booleans ("on", "yes", "1") count, and only the
  # repository config activates config.worktree (#523 round six).
  ext=$(git -C "$dir" config --bool --local --get extensions.worktreeConfig 2>/dev/null || true)
  [[ "$ext" == "true" ]] || return 0
  git -C "$dir" config --worktree --get gibson.agentVendor 2>/dev/null | tr '[:upper:]' '[:lower:]' || true
}

# agent_vendor_fix_hint — the one-line remedy every caller prints with a finding.
agent_vendor_fix_hint() {
  echo "declare the lane (scripts/setup-hooks.sh --vendor from-reservation, or --vendor <claude|codex|grok|devin>), then git commit --amend / git rebase so each commit carries one Agent-Vendor trailer under an email GitHub maps to a login"
}
