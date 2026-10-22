#!/usr/bin/env bash
# agent-vendor.sh — walk a commit range for commits review-evidence cannot
# resolve to a vendor (the-gibson#503/#504/#506, follow-up to #520/#523, #524).
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
# RULE (per commit in BASE..HEAD; the base commit itself is outside the range),
# mirroring resolveAuthors in scripts/pr-review-evidence.mjs for BOTH the author
# and the committer:
#   1. an email in the reserved `.invalid` domain (or bare `user@invalid`) is
#      `no-login` at GitHub: refused before anything else (#503/#504);
#   2. the email must PROVABLY map to a GitHub login: a noreply address
#      (`<id>+login@users.noreply.github.com`) carries its login; any other
#      address is proven only through GitHub's own commit search by email in
#      the repository (`gh api search/commits`, the mapping the evaluator sees).
#      Unprovable (no slug, no gh, no result) → `login-unresolved`, fail closed;
#   3. the login must be listed with role "author" in config/review-evidence.
#      v1.json AT THE TRUSTED BASE REF (never the lane's own copy), and when
#      that identity carries an authorCommits allowlist the commit's full SHA
#      must be in it (exact, no prefix);
#   4. a listed lane-bot login (aie-agent-lanes-*[bot]) or a `human` identity
#      resolves by identity alone; an `owner` identity (and, conservatively, any
#      other listed identity) resolves only through exactly one `Agent-Vendor:`
#      trailer naming claude|codex|grok|devin (#506).

# Same list as .githooks/{prepare-commit-msg,commit-msg}, scripts/claim.sh and
# scripts/setup-hooks.sh (AUTHOR_COMMIT_VENDORS in scripts/pr-review-evidence.mjs);
# setup-hooks.test.sh fails when they drift.
AGENT_VENDORS="claude codex grok devin"

agent_vendor_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# agent_vendor_known NAME — 0 when NAME (already lower-cased) is a vendor the
# evaluator resolves from the trailer.
agent_vendor_known() {
  local v
  for v in $AGENT_VENDORS; do
    [[ "$1" == "$v" ]] && return 0
  done
  return 1
}

# agent_vendor_repo_slug REPO — github.com owner/name of REPO's origin, or nothing.
agent_vendor_repo_slug() {
  local url rest host path
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)
  [[ -n "$url" ]] || return 0
  case "$url" in
    https://*|http://*|ssh://*|git://*) rest="${url#*://}"; rest="${rest#*@}" ;;
    *@*:*) rest="${url#*@}"; rest="${rest%%:*}/${rest#*:}" ;;
    *) return 0 ;;
  esac
  host=$(agent_vendor_lower "${rest%%/*}"); host="${host%%:*}"
  path="${rest#*/}"; path="${path%/}"; path="${path%.git}"
  case "$host" in github.com|www.github.com|ssh.github.com) ;; *) return 0 ;; esac
  [[ "$path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 0
  printf '%s\n' "$path"
}

# --- the evaluator's identity table, at the trusted base --------------------
# One line per author identity: "<login>\t<vendor>\t<sha,...>" (third field:
# the authorCommits allowlist, "-" when present but empty, "" unrestricted).
# Read with `git show <base>:config/review-evidence.v1.json` — never from the
# candidate's tree, which the lane can edit (Codex round four on #525). Cached
# per repo + base commit. Unreadable → AGENT_VENDOR_TABLE_OK=0: nothing exempt.
#
# Governed target repositories carry no identity table of their own: the
# evaluator's table lives in the Gibson harness. AGENT_VENDOR_TABLE_FALLBACK
# (loop.sh sets it to $GIBSON/config/review-evidence.v1.json) is read when the
# base has no table. It is the harness's own file in a different repository,
# which the candidate lane cannot edit — the same trust loop.sh already places in
# the harness code it executes. Unset → no fallback, nothing resolves.
AGENT_VENDOR_TABLE=""
AGENT_VENDOR_TABLE_FOR=""
AGENT_VENDOR_TABLE_OK=0
AGENT_VENDOR_TABLE_FALLBACK="${AGENT_VENDOR_TABLE_FALLBACK:-}"
agent_vendor_table_json() { # repo base_sha — the table's JSON on stdout, or 1
  if [[ -n "$2" ]] && git -C "$1" cat-file -e "${2}:config/review-evidence.v1.json" 2>/dev/null; then
    git -C "$1" show "${2}:config/review-evidence.v1.json" 2>/dev/null
    return $?
  fi
  if [[ -n "$AGENT_VENDOR_TABLE_FALLBACK" && -r "$AGENT_VENDOR_TABLE_FALLBACK" ]]; then
    cat "$AGENT_VENDOR_TABLE_FALLBACK"
    return $?
  fi
  return 1
}
agent_vendor_author_table() { # repo base — prints the table; 1 when unreadable
  local repo="$1" base="${2:-}" base_sha key
  base_sha=$(git -C "$repo" rev-parse --verify --quiet "${base}^{commit}" 2>/dev/null || true)
  key="$repo@$base_sha@$AGENT_VENDOR_TABLE_FALLBACK"
  if [[ "$AGENT_VENDOR_TABLE_FOR" != "$key" ]]; then
    AGENT_VENDOR_TABLE_FOR="$key"
    AGENT_VENDOR_TABLE=""
    AGENT_VENDOR_TABLE_OK=0
    if command -v node >/dev/null 2>&1; then
      if AGENT_VENDOR_TABLE=$(agent_vendor_table_json "$repo" "$base_sha" | node -e '
        let src = ""; process.stdin.on("data", (d) => { src += d; }); process.stdin.on("end", () => {
          const c = JSON.parse(src);
          if (!Array.isArray(c.identities)) process.exit(3);
          for (const i of c.identities) {
            if (typeof i.login !== "string" || !Array.isArray(i.roles) || !i.roles.includes("author")) continue;
            const allow = Array.isArray(i.authorCommits) ? i.authorCommits.filter((x) => typeof x === "string").map((x) => x.toLowerCase()) : [];
            if (Array.isArray(i.authorCommits) && allow.length === 0) allow.push("-");
            console.log(i.login.toLowerCase() + "\t" + String(i.vendor || "unknown").toLowerCase() + "\t" + allow.join(","));
          }
        });' 2>/dev/null) && [[ -n "$AGENT_VENDOR_TABLE" ]]; then
        AGENT_VENDOR_TABLE_OK=1
      else
        AGENT_VENDOR_TABLE=""
      fi
    fi
  fi
  [[ "$AGENT_VENDOR_TABLE_OK" -eq 1 ]] || return 1
  printf '%s\n' "$AGENT_VENDOR_TABLE"
}

# agent_vendor_identity REPO BASE LOGIN — prints "<vendor>\t<allowlist>" for a
# listed author login; 1 when not listed; 3 when the table is unreadable.
agent_vendor_identity() {
  local table entry
  table=$(agent_vendor_author_table "$1" "$2") || return 3
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "${entry%%	*}" == "$3" ]] || continue
    printf '%s\n' "${entry#*	}"
    return 0
  done <<EOF2
$table
EOF2
  return 1
}

# --- email → GitHub login ----------------------------------------------------
# agent_vendor_login_of_noreply EMAIL — the login a noreply address encodes
# (`<id>+login@users.noreply.github.com`, or `login@users.noreply.github.com`),
# lower-cased; nothing for any other address.
agent_vendor_login_of_noreply() {
  local e local_part
  e=$(agent_vendor_lower "$1")
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

# agent_vendor_login_for_email SLUG EMAIL — the GitHub login EMAIL maps to, as
# the evaluator will see it: the noreply form carries it; any other address is
# proven only by GitHub's commit search by email in SLUG (author-email:, then
# committer-email:), through `gh api`. Prints nothing when it cannot be proven
# (no slug, no gh, no hit, an API error such as a rate limit): the caller fails
# closed. Never guessed from the address itself (Codex round five on #525).
#
# Cache: a file, not a shell variable, because every caller runs this inside a
# command substitution (a subshell), where a variable write is lost and each
# commit would hit the search API twice — GitHub's secondary rate limit on
# search then returns an error body, which must never be read as a login.
AGENT_VENDOR_LOGIN_CACHE_FILE="${AGENT_VENDOR_LOGIN_CACHE_FILE:-$(mktemp "${TMPDIR:-/tmp}/agent-vendor-logins.XXXXXX" 2>/dev/null || echo /dev/null)}"
agent_vendor_login_for_email() {
  local slug="${1:-}" email login e key line side filter out rc
  email=$(agent_vendor_lower "$2")
  login=$(agent_vendor_login_of_noreply "$email")
  if [[ -n "$login" ]]; then printf '%s\n' "$login"; return 0; fi
  [[ -n "$slug" ]] || return 0
  key="$slug|$email"
  if [[ -r "$AGENT_VENDOR_LOGIN_CACHE_FILE" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if [[ "${line%%	*}" == "$key" ]]; then
        e="${line#*	}"
        [[ "$e" == "-" ]] || printf '%s\n' "$e"
        return 0
      fi
    done < "$AGENT_VENDOR_LOGIN_CACHE_FILE"
  fi
  login=""
  if command -v gh >/dev/null 2>&1; then
    for side in author committer; do
      filter=".items[0].${side}.login // empty"
      out=$(gh api -X GET search/commits -f "q=repo:${slug} ${side}-email:${email}" -f per_page=1 --jq "$filter" 2>/dev/null </dev/null); rc=$?
      [[ "$rc" -eq 0 ]] || { out=""; continue; }
      out=$(agent_vendor_lower "$(printf '%s' "$out" | head -1 | tr -d '[:space:]')")
      # Only a login-shaped answer counts; an error body or anything else is "unproven".
      if [[ "$out" =~ ^[a-z0-9][a-z0-9-]*(\[bot\])?$ ]]; then login="$out"; break; fi
    done
  fi
  # Cache only a proven login or a definite "no mapping" from a successful call;
  # an API failure is retried next time rather than remembered as absence.
  if [[ -n "$login" || "${rc:-1}" -eq 0 ]]; then
    printf '%s\t%s\n' "$key" "${login:--}" >> "$AGENT_VENDOR_LOGIN_CACHE_FILE" 2>/dev/null || true
  fi
  [[ -z "$login" ]] || printf '%s\n' "$login"
}

# --- per-commit verdict --------------------------------------------------------
# agent_vendor_commit_problem REPO SHA BASE [SLUG] — prints ONE reason
# review-evidence would give for this commit, or nothing when it resolves. BASE is
# the trusted ref whose identity table decides; SLUG (default: REPO's GitHub
# origin) is where email → login is proven. Always returns 0; an unreadable commit
# prints `unreadable`. Reasons: invalid-email:<addr>, login-unresolved:<addr>,
# identity-table-unreadable:<login>, unlisted-login:<login>,
# commit-not-allowed:<login>, vendor-unknown:<login>, no-trailer,
# multi-vendor:<a,b>, unknown-vendor:<v>.
agent_vendor_commit_problem() {
  local repo="$1" sha="$2" base="${3:-}" slug="${4:-}" ae ce body line v vendors="" n=0
  local full_sha email login ident id_vendor allow a needs_trailer=0 side_email
  ae=$(git -C "$repo" log -1 --format=%ae "$sha" 2>/dev/null) || { echo unreadable; return 0; }
  ce=$(git -C "$repo" log -1 --format=%ce "$sha" 2>/dev/null) || { echo unreadable; return 0; }
  full_sha=$(git -C "$repo" rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null || true)
  [[ -n "$slug" ]] || slug=$(agent_vendor_repo_slug "$repo")
  # 1. Both identities first: GitHub maps the reserved .invalid domain (and the
  #    bare user@invalid form) to no login, so the trailer is never read.
  for email in "$ae" "$ce"; do
    case "$(agent_vendor_lower "$email")" in
      *.invalid|*@invalid) echo "invalid-email:${email}"; return 0 ;;
    esac
  done
  # 2.–4. Each side must prove a login, the login must be a listed author
  #    identity (allowlist honoured), and the identity's vendor decides whether
  #    a trailer is needed — exactly as the evaluator walks author and committer.
  for side_email in "$ae" "$ce"; do
    login=$(agent_vendor_login_for_email "$slug" "$side_email")
    [[ -n "$login" ]] || { echo "login-unresolved:${side_email}"; return 0; }
    ident=$(agent_vendor_identity "$repo" "$base" "$login")
    case $? in
      3) echo "identity-table-unreadable:${login}"; return 0 ;;
      1) echo "unlisted-login:${login}"; return 0 ;;
    esac
    id_vendor="${ident%%	*}"
    allow="${ident#*	}"
    [[ "$ident" == *"	"* ]] || allow=""
    if [[ -n "$allow" ]]; then
      [[ "$full_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "commit-not-allowed:${login}"; return 0; }
      found=0
      while IFS= read -r a; do
        [[ -n "$a" && "$a" == "$full_sha" ]] && found=1
      done <<EOF2
$(printf '%s' "$allow" | tr ',' '\n')
EOF2
      [[ "$found" -eq 1 ]] || { echo "commit-not-allowed:${login}"; return 0; }
    fi
    case "$id_vendor" in
      unknown) echo "vendor-unknown:${login}"; return 0 ;;
      human) ;;
      *)
        if [[ "$login" == aie-agent-lanes-*\[bot\] ]] && agent_vendor_known "$id_vendor"; then
          : # listed lane bot: resolves to its vendor by identity alone
        else
          needs_trailer=1 # owner, and conservatively any other listed identity
        fi
        ;;
    esac
  done
  [[ "$needs_trailer" -eq 1 ]] || return 0
  body=$(git -C "$repo" log -1 --format=%B "$sha" 2>/dev/null) || { echo unreadable; return 0; }
  # Every Agent-Vendor line anywhere in the message, exactly as the evaluator
  # matches them (case-insensitive key and value). Here-string, not a pipe into
  # a quiet grep (L-077).
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    v="${line#*:}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v=$(agent_vendor_lower "$v")
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

# agent_vendor_unresolved_shas REPO BASE HEAD [TABLE_BASE [SLUG]] — prints
# `<sha> <reason>` one per line for every commit in BASE..HEAD review-evidence
# would not resolve. The identity table is read at TABLE_BASE (default BASE), the
# trusted base ref; logins are proven in SLUG (default: REPO's GitHub origin).
# Returns 0 when the range is readable (including an empty range, and including
# findings); 1 when the range cannot be walked. Same contract as
# dco_unsigned_shas in scripts/loop.sh, so the two walks sit side by side.
agent_vendor_unresolved_shas() {
  local repo="$1" base="$2" head="$3" table_base="${4:-$2}" slug="${5:-}" sha log_out why
  git -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || return 1
  git -C "$repo" rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1 || return 1
  log_out=$(git -C "$repo" log --format=%H "${base}..${head}" 2>/dev/null) || return 1
  [[ -n "$log_out" ]] || return 0
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    why=$(agent_vendor_commit_problem "$repo" "$sha" "$table_base" "$slug")
    [[ -n "$why" ]] || continue
    printf '%s %s\n' "$sha" "$why"
  done <<EOF2
$log_out
EOF2
  return 0
}

# agent_vendor_declared [DIR] — prints the vendor DIR's worktree declares, or
# nothing. Worktree scope ONLY, and only when extensions.worktreeConfig is true
# in the repository config (`--bool --local`: git booleans count, and only the
# repository config activates config.worktree): with the extension off,
# `git config --worktree` silently falls back to --local, so a shared-config
# value would read as a declaration for every worktree (#523 rounds five/six).
# Same gate as .githooks/commit-msg.
agent_vendor_declared() {
  local dir="${1:-.}" ext
  ext=$(git -C "$dir" config --bool --local --get extensions.worktreeConfig 2>/dev/null || true)
  [[ "$ext" == "true" ]] || return 0
  git -C "$dir" config --worktree --get gibson.agentVendor 2>/dev/null | tr '[:upper:]' '[:lower:]' || true
}

# agent_vendor_fix_hint — the one-line remedy every caller prints with a finding.
agent_vendor_fix_hint() {
  echo "declare the lane (scripts/setup-hooks.sh --vendor from-reservation, or --vendor <claude|codex|grok|devin>), then git commit --amend / git rebase so each commit carries one Agent-Vendor trailer under an email GitHub maps to a listed login"
}
