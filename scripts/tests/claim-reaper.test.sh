#!/usr/bin/env bash
# claim-reaper.test.sh — sensors for the claim-reaper contract (issue #73)
#
# WHAT IT DOES
#   Builds throwaway git repos and a fake `gh`, then asserts dry-run planning,
#   fail-closed safety, apply idempotency, open-PR protection, sibling/label
#   survival, worktree prune/keep, and Bash 3.2 / path-with-spaces behaviour.
#   No network, no real GitHub.
#
# USAGE
#   scripts/tests/claim-reaper.test.sh
set -uo pipefail

# Hermetic git identity (#101): suites that commit must not read ambient global
# user.name/email. Pass with HOME pointed at an empty directory.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"


SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REAPER="$SCRIPT_DIR/../claim-reaper.sh"
RC="$SCRIPT_DIR/../release-claim.sh"
STREAM_CAPTURE="$SCRIPT_DIR/../lib/stream-capture.sh"
PASS=0
FAIL=0

ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -F -- "$3" >/dev/null; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -F -- "$3" >/dev/null; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

# Install a sibling reaper copy with the real production stream-capture helper
# at the path production resolves ($dest_dir/lib/stream-capture.sh). Without
# the helper, claim-reaper fails closed rather than inventing an empty inventory.
# Also ships lib/common.sh (need_cmd; #192) — production sources it at startup.
install_sibling_reaper() {
  local dest_dir="$1"
  mkdir -p "$dest_dir/lib"
  cp "$REAPER" "$dest_dir/claim-reaper.sh"
  chmod +x "$dest_dir/claim-reaper.sh"
  cp "$STREAM_CAPTURE" "$dest_dir/lib/stream-capture.sh"
  cp "$SCRIPT_DIR/../lib/common.sh" "$dest_dir/lib/common.sh"
}

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-reaper-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Fixed clock: claimed 2026-08-01T00:00:00Z = 1785542400
# Default stale threshold 14400s → boundary at 1785556800
# STALE_NOW = claim + 14401 = 1785556801 (strictly stale)
# FRESH_NOW = claim + 100 = 1785542500 (not stale)
CLAIM_EPOCH=1785542400
STALE_NOW=$((CLAIM_EPOCH + 14401))
FRESH_NOW=$((CLAIM_EPOCH + 100))
CLAIMED_ISO="2026-08-01T00:00:00Z"

BIN="$ROOT/bin"
mkdir -p "$BIN"
STATE_BASE="$ROOT/state"
mkdir -p "$STATE_BASE"

# Fake gh: configurable open-PR count, labels, comments log.
install_fake_gh() {
  cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
# Controlled fake for claim-reaper + release-claim.
log() { printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"; }

case "$1" in
  repo)
    echo "${GH_REPO:-acme/app}"
    exit 0
    ;;
  pr)
    # gh pr list --repo R --head H --state open --json number --jq length
    if [[ "${GH_PR_FAIL:-0}" == "1" ]]; then
      exit 1
    fi
    echo "${GH_PR_COUNT:-0}"
    exit 0
    ;;
  api)
    # comments list: repos/o/r/issues/N/comments
    if [[ "${GH_API_FAIL:-0}" == "1" ]]; then
      exit 1
    fi
    if [[ "${2:-}" == "graphql" ]]; then
      # pr-claims.sh's paginated PR-body claim read. release-claim.sh's
      # post-mutation sibling check is fail-closed since #153's review — an
      # unreadable inventory must not authorize removing agent-claimed — so
      # this has to answer like a real gh: a successful, empty inventory
      # (these fixtures have no live PR-body claims). GH_GRAPHQL_FAIL=1 makes
      # it fail on purpose.
      [[ "${GH_GRAPHQL_FAIL:-0}" == "1" ]] && exit 1
      exit 0
    fi
    if [[ "${2:-}" == repos/* ]]; then
      # print bodies already posted
      if [[ -f "${GH_COMMENTS_FILE:-}" ]]; then
        cat "${GH_COMMENTS_FILE}"
      fi
      exit 0
    fi
    exit 1
    ;;
  issue)
    shift
    if [[ "${1:-}" == "comment" ]]; then
      if [[ "${GH_COMMENT_FAIL:-0}" == "1" ]]; then
        log "COMMENT_FAIL $*"
        echo "FAKE-GH: comment post failed" >&2
        exit 1
      fi
      log "COMMENT $*"
      # capture body after --body
      body=""
      prev=""
      for a in "$@"; do
        if [[ "$prev" == "--body" ]]; then body="$a"; fi
        prev="$a"
      done
      printf '%s\n' "$body" >> "${GH_COMMENTS_FILE:-/dev/null}"
      # refuse absolute worktree-looking paths in comment
      if printf '%s' "$body" | grep -E '/Users/|/home/|/private/|/tmp/gibson' >/dev/null; then
        echo "FAKE-GH: absolute path leaked into comment" >&2
        exit 1
      fi
      exit 0
    fi
    if [[ "${1:-}" == "edit" ]]; then
      log "EDIT $*"
      if printf '%s' "$*" | grep -- '--remove-label' >/dev/null; then
        : > "${GH_STATE:-/tmp/gh-reaper-state}"
      fi
      exit 0
    fi
    if [[ "${1:-}" == "view" ]]; then
      if [[ -f "${GH_STATE:-/tmp/gh-reaper-state}" ]]; then
        echo ""
      else
        echo "${GH_LABELS:-agent-claimed,tier-b}"
      fi
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
GH
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
}

install_fake_gh

new_repo() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root"
  git init -q --bare "$root/origin"
  git clone -q "$root/origin" "$root/canon" 2>/dev/null
  (
    cd "$root/canon" || exit 1
    mkdir -p docs/claims
    printf '| when | claim-id | scope | who |\n|---|---|---|---|\n' > docs/active-work.md
    git add -A && git commit -qm init && git branch -M main && git push -q -u origin main
  ) >/dev/null 2>&1
}

# Write a per-file claim on origin/main. Optional worktree path as $5.
# Args: repo-root claim-id issue claimed-iso [worktree]
add_claim_file() {
  local root="$1" id="$2" issue="$3" claimed="$4" wt="${5:-}"
  (
    cd "$root/canon" || exit 1
    git checkout -q main
    mkdir -p docs/claims
    {
      printf 'claim: %s\n' "$id"
      printf 'issue: %s\n' "$issue"
      printf 'claimed: %s\n' "$claimed"
      printf 'scope: src/%s\n' "$id"
      printf 'session: test@box\n'
      printf 'branch: feat/%s\n' "${id#issue-}"
      if [[ -n "$wt" ]]; then
        printf 'worktree: %s\n' "$wt"
      fi
    } > "docs/claims/${id}.md"
    git add -A && git commit -qm "claim $id" && git push -q origin main
  ) >/dev/null 2>&1
}

run_reaper() {
  # Usage: run_reaper <canon-dir> [reaper args...]
  # Export GIBSON_CLAIMS_NOW_EPOCH (and other env) in the caller; do not pass
  # KEY=val through this helper — env would treat later flags as the command.
  local canon="$1"
  local state
  shift
  state="$STATE_BASE/$(basename "$(dirname "$canon")")"
  mkdir -p "$state"
  GIBSON_CANONICAL="$canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$REAPER" --repo acme/app "$@"
}

# ---------------------------------------------------------------------------
echo "#73 · stale dry-run emits plan with zero mutations"
new_repo "$ROOT/dry"
add_claim_file "$ROOT/dry" issue-15-stale-lane 15 "$CLAIMED_ISO"
# sibling recent enough that only 15 is stale when we filter — add second claim same age
add_claim_file "$ROOT/dry" issue-16-also-stale 16 "$CLAIMED_ISO"
origin_before=$(git -C "$ROOT/dry/canon" rev-parse origin/main)
export GH_PR_COUNT=0 GH_LOG="$ROOT/dry/gh.log" GH_COMMENTS_FILE="$ROOT/dry/comments"
rm -f "$GH_LOG" "$GH_COMMENTS_FILE" "${GH_STATE:-}"
: > "$GH_COMMENTS_FILE"
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/dry/canon" 2>&1)
rc=$?
check "stale dry-run exits 0" "$rc" "0"
contains "plans REAP for stale claim" "$out" "REAP   issue-15-stale-lane"
contains "says dry-run" "$out" "DRY RUN"
contains "zero mutations wording" "$out" "zero mutations"
origin_after=$(git -C "$ROOT/dry/canon" rev-parse origin/main)
check "dry-run did not push ledger" "$origin_after" "$origin_before"
[[ ! -s "$GH_LOG" ]] && ok "dry-run did not call gh mutate" || bad "dry-run wrote gh log"
files=$(git -C "$ROOT/dry/canon" ls-tree --name-only origin/main docs/claims/)
contains "claim still live after dry-run" "$files" "issue-15-stale-lane.md"

# ---------------------------------------------------------------------------
echo "#73 · open PR always protects"
new_repo "$ROOT/opr"
add_claim_file "$ROOT/opr" issue-20-has-pr 20 "$CLAIMED_ISO"
export GH_PR_COUNT=1 GH_LOG="$ROOT/opr/gh.log" GH_COMMENTS_FILE="$ROOT/opr/comments"
: > "$GH_COMMENTS_FILE"
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/opr/canon" 2>&1)
rc=$?
check "open-PR dry-run exits 0" "$rc" "0"
contains "KEEP due to open_pr" "$out" "open_pr"
contains "KEEP line for claim" "$out" "KEEP   issue-20-has-pr"
lacks    "does not REAP protected claim" "$out" "REAP   issue-20-has-pr"

# ---------------------------------------------------------------------------
echo "#73 · recent claim timestamp prevents reaping"
new_repo "$ROOT/recent"
add_claim_file "$ROOT/recent" issue-21-fresh 21 "$CLAIMED_ISO"
export GH_PR_COUNT=0
out=$(GIBSON_CLAIMS_NOW_EPOCH="$FRESH_NOW" run_reaper "$ROOT/recent/canon" 2>&1)
contains "KEEP recent_activity" "$out" "recent_activity"
lacks    "no REAP when fresh" "$out" "REAP   issue-21-fresh"

# ---------------------------------------------------------------------------
echo "#73 · recent local branch tip prevents reaping"
new_repo "$ROOT/btip"
add_claim_file "$ROOT/btip" issue-22-branchtip 22 "$CLAIMED_ISO"
(
  cd "$ROOT/btip/canon" || exit 1
  # Branch tip "now" relative to STALE_NOW — create commit with fixed date near STALE_NOW
  git checkout -q -b feat/22-branchtip
  echo tip > tip.txt
  # Commit date = STALE_NOW - 60 (still within 14400 of STALE_NOW)
  export GIT_AUTHOR_DATE="@$((STALE_NOW - 60))"
  export GIT_COMMITTER_DATE="@$((STALE_NOW - 60))"
  git add tip.txt && git commit -qm "recent tip"
  git checkout -q main
) >/dev/null 2>&1
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/btip/canon" 2>&1)
contains "KEEP from branch tip" "$out" "recent_activity"
lacks    "no REAP with recent tip" "$out" "REAP   issue-22-branchtip"

# ---------------------------------------------------------------------------
echo "#73 · remote branch tip prevents reaping"
new_repo "$ROOT/rtip"
add_claim_file "$ROOT/rtip" issue-23-remotetip 23 "$CLAIMED_ISO"
(
  cd "$ROOT/rtip/canon" || exit 1
  git checkout -q -b feat/23-remotetip
  echo rtip > rtip.txt
  export GIT_AUTHOR_DATE="@$((STALE_NOW - 30))"
  export GIT_COMMITTER_DATE="@$((STALE_NOW - 30))"
  git add rtip.txt && git commit -qm "remote tip"
  git push -q origin feat/23-remotetip
  git checkout -q main
  git branch -D feat/23-remotetip
) >/dev/null 2>&1
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/rtip/canon" 2>&1)
contains "KEEP from remote tip" "$out" "recent_activity"
lacks    "no REAP with remote tip" "$out" "REAP   issue-23-remotetip"

# ---------------------------------------------------------------------------
echo "#73 · heartbeat file prevents reaping"
new_repo "$ROOT/hb"
add_claim_file "$ROOT/hb" issue-24-heartbeat 24 "$CLAIMED_ISO"
HBDIR="$ROOT/hb/heartbeats"
mkdir -p "$HBDIR"
printf '%s\n' "$((STALE_NOW - 10))" > "$HBDIR/issue-24-heartbeat"
# Pin mtime into the injected clock's past so wall-clock file creation cannot
# look like future evidence under GIBSON_CLAIMS_NOW_EPOCH=STALE_NOW.
touch -t 202608010400 "$HBDIR/issue-24-heartbeat" 2>/dev/null || true
# Also rewrite content-only: if touch failed, set mtime via reference file.
# GNU first: `stat -f` on Linux means *filesystem* status and succeeds, printing
# a multi-line block that `-gt` then evaluates as arithmetic (#93, L-050).
mtime=$(stat -c %Y "$HBDIR/issue-24-heartbeat" 2>/dev/null ||
        stat -f %m "$HBDIR/issue-24-heartbeat" 2>/dev/null || echo 0)
if [[ "$mtime" -gt "$STALE_NOW" ]]; then
  # Fall back: use content epoch only by matching mtime to content via a dated file
  printf '%s\n' "$((STALE_NOW - 10))" > "$HBDIR/issue-24-heartbeat"
  # macOS touch -t YYYYMMDDhhmm
  touch -t 202608010359 "$HBDIR/issue-24-heartbeat" 2>/dev/null || true
fi
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/hb/canon" --heartbeat-dir "$HBDIR" 2>&1)
contains "KEEP from heartbeat" "$out" "recent_activity"
lacks    "no REAP with heartbeat" "$out" "REAP   issue-24-heartbeat"

# ---------------------------------------------------------------------------
echo "#73 · tracked-file mtime in registered worktree prevents reaping"
new_repo "$ROOT/wtmt"
WT="$ROOT/wtmt/wt-25-mtime"
# Registered worktree; branch name deliberately missing so only mtime evidence keeps it.
(
  cd "$ROOT/wtmt/canon" || exit 1
  git worktree add -b feat/25-mtime-internal "$WT" main >/dev/null 2>&1
  cd "$WT" || exit 1
  echo tracked > "file with spaces.txt"
  # Old committer date so branch tip of this worktree's real branch is not consulted
  # (claim points at a missing branch name).
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  git add "file with spaces.txt" && git commit -qm "tracked"
  cd "$ROOT/wtmt/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  cat > docs/claims/issue-25-mtime.md <<EOF
claim: issue-25-mtime
issue: 25
claimed: $CLAIMED_ISO
scope: src/x
session: t
branch: feat/25-mtime-missing
worktree: $WT
EOF
  git add -A && git commit -qm "claim with missing branch name" && git push -q origin main
) >/dev/null 2>&1
# Wall-clock mtime ≈ real now; use real now as the reaper clock so mtime is recent, not future.
WALL_NOW=$(date -u +%s)
touch "$WT/file with spaces.txt" 2>/dev/null || true
out=$(GIBSON_CLAIMS_NOW_EPOCH="$WALL_NOW" run_reaper "$ROOT/wtmt/canon" --claim-id issue-25-mtime 2>&1)
contains "KEEP from worktree mtime or activity" "$out" "KEEP   issue-25-mtime"
lacks    "no REAP with mtime evidence" "$out" "REAP   issue-25-mtime"

# ---------------------------------------------------------------------------
echo "#73 · fail closed: malformed timestamp, unregistered worktree, symlink, PR fail"
new_repo "$ROOT/fc"
(
  cd "$ROOT/fc/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  cat > docs/claims/issue-30-badts.md <<'EOF'
claim: issue-30-badts
issue: 30
claimed: NOT-A-DATE
scope: x
session: t
branch: feat/30-badts
EOF
  cat > docs/claims/issue-31-unreg.md <<EOF
claim: issue-31-unreg
issue: 31
claimed: $CLAIMED_ISO
scope: x
session: t
branch: feat/31-unreg
worktree: $ROOT/fc/does-not-exist-wt
EOF
  # symlink worktree path
  ln -s "$ROOT/fc/canon" "$ROOT/fc/symlink-wt"
  cat > docs/claims/issue-32-symlink.md <<EOF
claim: issue-32-symlink
issue: 32
claimed: $CLAIMED_ISO
scope: x
session: t
branch: feat/32-symlink
worktree: $ROOT/fc/symlink-wt
EOF
  cat > docs/claims/issue-33-prfail.md <<EOF
claim: issue-33-prfail
issue: 33
claimed: $CLAIMED_ISO
scope: x
session: t
branch: feat/33-prfail
EOF
  git add -A && git commit -qm "fail-closed fixtures" && git push -q origin main
) >/dev/null 2>&1

out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/fc/canon" --claim-id issue-30-badts 2>&1)
contains "REFUSE malformed timestamp" "$out" "malformed_timestamp"

out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/fc/canon" --claim-id issue-31-unreg 2>&1)
contains "REFUSE unregistered/missing worktree" "$out" "worktree_"

out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/fc/canon" --claim-id issue-32-symlink 2>&1)
contains "REFUSE symlink worktree" "$out" "worktree_is_symlink"

export GH_PR_FAIL=1
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/fc/canon" --claim-id issue-33-prfail 2>&1)
contains "REFUSE pr query failed" "$out" "pr_query_failed"
export GH_PR_FAIL=0

# future clock
new_repo "$ROOT/future"
add_claim_file "$ROOT/future" issue-34-future 34 "2099-01-01T00:00:00Z"
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/future/canon" 2>&1)
contains "REFUSE future clock" "$out" "future_clock_evidence"

# heartbeat symlink
new_repo "$ROOT/hbsym"
add_claim_file "$ROOT/hbsym" issue-35-hbsym 35 "$CLAIMED_ISO"
HB2="$ROOT/hbsym/hb"
mkdir -p "$HB2"
ln -s /etc/hosts "$HB2/issue-35-hbsym"
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/hbsym/canon" --heartbeat-dir "$HB2" 2>&1)
contains "REFUSE heartbeat symlink" "$out" "heartbeat_symlink"

# ---------------------------------------------------------------------------
echo "#73 · apply releases exactly one claim, journals, comments once, keeps branch/worktree"
new_repo "$ROOT/apply"
# Do NOT create feature-branch tips with wall-clock dates: under an injected past
# NOW those tips look like future-clock evidence and fail closed (correctly).
(
  cd "$ROOT/apply/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  # Backdate the claim commit so even if a branch points here it is not "future".
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  cat > docs/claims/issue-40-dead.md <<EOF
claim: issue-40-dead
issue: 40
claimed: $CLAIMED_ISO
scope: src/dead
session: t
branch: feat/40-dead
EOF
  cat > docs/claims/issue-40-sibling.md <<EOF
claim: issue-40-sibling
issue: 40
claimed: $CLAIMED_ISO
scope: src/sib
session: t
branch: feat/40-sibling
EOF
  cat > docs/claims/issue-41-other.md <<EOF
claim: issue-41-other
issue: 41
claimed: $CLAIMED_ISO
scope: src/o
session: t
branch: feat/41-other
EOF
  : > docs/active-work.md
  git add -A && git commit -qm "apply fixtures" && git push -q origin main
  # Local branches exist for --keep-branch verification but tips are CLAIM_EPOCH-dated.
  git branch -f feat/40-dead HEAD
  git branch -f feat/40-sibling HEAD
) >/dev/null 2>&1
mkdir -p "$ROOT/apply/wt-40-dead"
echo preserve > "$ROOT/apply/wt-40-dead/marker"

export GH_PR_COUNT=0
export GH_LOG="$ROOT/apply/gh.log"
export GH_COMMENTS_FILE="$ROOT/apply/comments"
export GH_STATE="$ROOT/apply/gh-state"
rm -f "$GH_LOG" "$GH_STATE"
: > "$GH_COMMENTS_FILE"

# Only reap the dead slice (sibling also stale would be reaped too — filter)
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/apply/canon" --claim-id issue-40-dead --apply 2>&1)
rc=$?
check "apply exits 0" "$rc" "0"
contains "released claim" "$out" "OK released issue-40-dead"
files=$(git -C "$ROOT/apply/canon" fetch -q origin && git -C "$ROOT/apply/canon" ls-tree --name-only origin/main docs/claims/)
lacks    "dead claim file gone" "$files" "issue-40-dead.md"
contains "sibling claim survives" "$files" "issue-40-sibling.md"
contains "unrelated claim survives" "$files" "issue-41-other.md"
[[ -f "$ROOT/apply/wt-40-dead/marker" ]] && ok "worktree preserved by default" || bad "worktree removed by default"
br=$(git -C "$ROOT/apply/canon" branch --list 'feat/40-dead')
[[ -n "$br" ]] && ok "branch preserved by default" || bad "branch deleted by default"
# journal
state_dir="$STATE_BASE/apply"
[[ -f "$state_dir/journal.md" ]] && ok "journal written" || bad "journal missing"
contains "journal COMPLETED" "$(cat "$state_dir/journal.md")" "COMPLETED op=reap:issue-40-dead"
# comment once with marker, no absolute path
comments=$(cat "$GH_COMMENTS_FILE")
contains "comment has marker" "$comments" "<!-- gibson-claim-reaper:issue-40-dead -->"
contains "comment names branch" "$comments" "feat/40-dead"
lacks    "comment has no /Users path" "$comments" "/Users/"
# sibling → agent-claimed must remain (release-claim keeps label when residual)
# Our fake removes label only on remove-label; residual path should not call it.
if grep -q -- '--remove-label' "$GH_LOG" 2>/dev/null; then
  bad "should not remove-label while sibling remains"
else
  ok "agent-claimed preserved with sibling residual"
fi

# ---------------------------------------------------------------------------
echo "#73 · repeated apply is idempotent and comment-deduplicated"
out_repeat=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/apply/canon" --claim-id issue-40-dead --apply 2>&1)
rc2=$?
check "repeat apply exits 0" "$rc2" "0"
if echo "$out_repeat" | grep -iE 'absent|idempotent|nothing to reap|already' >/dev/null; then
  ok "repeat apply mentions absent or skip"
else
  bad "repeat apply mentions absent or skip (got: $(echo "$out_repeat" | tail -3 | tr '\n' ' '))"
fi
# claim already gone → completed already_absent or skip
comment_lines=$(grep -c 'gibson-claim-reaper:issue-40-dead' "$GH_COMMENTS_FILE" || true)
# marker appears once in body; file may have one body line
if [[ "$comment_lines" -le 1 ]]; then
  ok "comment not spammed on retry"
else
  bad "comment duplicated ($comment_lines)"
fi

# ---------------------------------------------------------------------------
echo "#73 · --prune-worktrees removes only exact registered target worktree"
new_repo "$ROOT/prune"
# Registered non-default path is the only allowed prune target. Unregistered
# default-path sibling and a decoy directory must survive (no default-path
# derivation, no rm -rf of unregistered paths).
WT_REG="$ROOT/prune/registered-nondefault-50"
WT_DEFAULT="$ROOT/prune/wt-50-prune"
WT_SIBLING="$ROOT/prune/wt-50-sib"
mkdir -p "$WT_DEFAULT" "$WT_SIBLING"
echo default-decoy > "$WT_DEFAULT/marker"
echo sibling > "$WT_SIBLING/marker"
(
  cd "$ROOT/prune/canon" || exit 1
  git checkout -q main
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  mkdir -p docs/claims
  # Commit claim first (backdated) so branch tips stay in the injected past.
  cat > docs/claims/issue-50-prune.md <<EOF
claim: issue-50-prune
issue: 50
claimed: $CLAIMED_ISO
scope: a
session: t
branch: feat/50-prune
worktree: $WT_REG
EOF
  cat > docs/claims/issue-50-sib.md <<EOF
claim: issue-50-sib
issue: 50
claimed: $CLAIMED_ISO
scope: b
session: t
branch: feat/50-sib
EOF
  : > docs/active-work.md
  git add -A && git commit -qm "prune fixtures" && git push -q origin main
  # Registered worktree at non-default path on expected branch (tip = claim epoch).
  # Keep the worktree clean: non-force `git worktree remove` refuses dirty trees.
  git worktree add -b feat/50-prune "$WT_REG" HEAD >/dev/null 2>&1
  git branch -f feat/50-sib HEAD
) >/dev/null 2>&1
# Force every file mtime to CLAIM_EPOCH so worktree evidence is stale under STALE_NOW
# (wall-clock mtimes would KEEP the claim as recent_activity).
if command -v python3 >/dev/null 2>&1; then
  find "$WT_REG" -type f -print0 2>/dev/null | xargs -0 python3 -c '
import os,sys
ep=int(sys.argv[1])
for p in sys.argv[2:]:
  try: os.utime(p,(ep,ep))
  except OSError: pass
' "$CLAIM_EPOCH" 2>/dev/null || true
else
  ts=$(date -r "$CLAIM_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d "@$CLAIM_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || echo 202608010000.00)
  find "$WT_REG" -type f -exec touch -t "$ts" {} \; 2>/dev/null || true
fi
export GH_PR_COUNT=0
export GH_LOG="$ROOT/prune/gh.log"
export GH_COMMENTS_FILE="$ROOT/prune/comments"
export GH_STATE="$ROOT/prune/gh-state"
rm -f "$GH_LOG" "$GH_STATE"
: > "$GH_COMMENTS_FILE"

out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/prune/canon" --claim-id issue-50-prune --apply --prune-worktrees 2>&1)
rc=$?
check "prune apply exits 0" "$rc" "0"
contains "released pruned claim" "$out" "OK released issue-50-prune"
# Exact registered target removed; unregistered default + sibling survive.
if [[ -d "$WT_REG" ]]; then
  bad "registered prune target still present"
else
  ok "prune removed only exact registered target"
fi
if [[ -f "$WT_DEFAULT/marker" ]]; then
  ok "unregistered default-path directory survived"
else
  bad "unregistered default-path directory was deleted"
fi
if [[ -f "$WT_SIBLING/marker" ]]; then
  ok "sibling/unrelated directory survived"
else
  bad "sibling directory was removed"
fi
files=$(git -C "$ROOT/prune/canon" fetch -q origin && git -C "$ROOT/prune/canon" ls-tree --name-only origin/main docs/claims/)
lacks    "pruned claim row gone" "$files" "issue-50-prune.md"
contains "sibling claim row kept" "$files" "issue-50-sib.md"

# ---------------------------------------------------------------------------
echo "#73 · concurrent applies serialize (lock)"
new_repo "$ROOT/lock"
# Past-dated claim commit only; no wall-clock feature-branch tip.
(
  cd "$ROOT/lock/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  cat > docs/claims/issue-60-lock.md <<EOF
claim: issue-60-lock
issue: 60
claimed: $CLAIMED_ISO
scope: x
session: t
branch: feat/60-lock
EOF
  git add -A && git commit -qm lock && git push -q origin main
) >/dev/null 2>&1
export GH_PR_COUNT=0
export GH_COMMENTS_FILE="$ROOT/lock/comments"
: > "$GH_COMMENTS_FILE"
export GH_LOG="$ROOT/lock/gh.log"
export GH_STATE="$ROOT/lock/gh-state"
rm -f "$GH_STATE"
LOCKDIR="$STATE_BASE/locktest/lock"
mkdir -p "$STATE_BASE/locktest"
# Hold lock as if another reaper is running
mkdir -p "$LOCKDIR"
echo "1" > "$LOCKDIR/pid"   # pid 1 usually exists (or launchd) — on macOS init exists
# Use a live pid
echo "$$" > "$LOCKDIR/pid"
out=$(
  env \
    GIBSON_CANONICAL="$ROOT/lock/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_BASE/locktest" \
    GIBSON_REAPER_JOURNAL="$STATE_BASE/locktest/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$LOCKDIR" \
    GIBSON_REAPER_RELEASE_CMD="$RC" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-60-lock --apply 2>&1
)
rc=$?
check "locked apply exits 1" "$rc" "1"
contains "names lock contention" "$out" "lock"
rm -rf "$LOCKDIR"

# ---------------------------------------------------------------------------
echo "#73/#153 · legacy + per-file same id is REFUSE (not silently deduped)"
new_repo "$ROOT/dedupe"
(
  cd "$ROOT/dedupe/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  cat > docs/claims/issue-70-both.md <<EOF
claim: issue-70-both
issue: 70
claimed: $CLAIMED_ISO
scope: x
session: t
branch: feat/70-both
EOF
  cat > docs/active-work.md <<EOF
| when | claim-id | scope | who |
|---|---|---|---|
| $CLAIMED_ISO | issue-70-both | x | legacy |
EOF
  git add -A && git commit -qm "dup forms" && git push -q origin main
) >/dev/null 2>&1
export GH_PR_COUNT=0
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/dedupe/canon" 2>&1)
# Mixed file+legacy for the same id is ambiguous: REFUSE, never silent REAP.
reap_lines=$(echo "$out" | grep -c 'REAP   issue-70-both' || true)
reap_lines=${reap_lines:-0}
check "mixed same-id zero REAP lines" "$reap_lines" "0"
contains "mixed same-id REFUSE in plan" "$out" "REFUSE"
contains "mixed same-id names mixed reason" "$out" "mixed_ledger_representations"

# ---------------------------------------------------------------------------
echo "#73 · path with spaces in worktree tracked files (Bash 3.2)"
new_repo "$ROOT/spaces"
SPWT="$ROOT/spaces/wt-80-spaces dir"
(
  cd "$ROOT/spaces/canon" || exit 1
  git worktree add -b "feat/80-spaces" "$SPWT" main >/dev/null 2>&1
  cd "$SPWT" || exit 1
  mkdir -p "sub dir"
  echo x > "sub dir/a file.txt"
  git add "sub dir/a file.txt" && git commit -qm "space paths"
  git checkout -q main 2>/dev/null || true
  cd "$ROOT/spaces/canon" || exit 1
  git checkout -q main
  cat > docs/claims/issue-80-spaces.md <<EOF
claim: issue-80-spaces
issue: 80
claimed: $CLAIMED_ISO
scope: x
session: t
branch: feat/80-spaces-missing
worktree: $SPWT
EOF
  git add -A && git commit -qm "spaces claim" && git push -q origin main
) >/dev/null 2>&1
WALL_NOW=$(date -u +%s)
out=$(GIBSON_CLAIMS_NOW_EPOCH="$WALL_NOW" run_reaper "$ROOT/spaces/canon" --claim-id issue-80-spaces 2>&1)
rc=$?
check "spaces path dry-run exits 0" "$rc" "0"
# Recent mtime on spaced file → KEEP
contains "handles spaced worktree path" "$out" "issue-80-spaces"
lacks    "does not hard-fail on spaces" "$out" "tracked_path_unsafe"

# ---------------------------------------------------------------------------
echo "#73 · default stale-seconds is exactly 14400"
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/dry/canon" --help 2>&1 || true)
# probe via dry-run plan header
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/dry/canon" 2>&1)
contains "default threshold 14400 in plan" "$out" "stale_seconds=14400"
# Exact boundary: age == 14400 is NOT reaped (only age > threshold)
BOUNDARY_NOW=$((CLAIM_EPOCH + 14400))
new_repo "$ROOT/bound"
(
  cd "$ROOT/bound/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  cat > docs/claims/issue-90-boundary.md <<EOF
claim: issue-90-boundary
issue: 90
claimed: $CLAIMED_ISO
scope: x
session: t
branch: feat/90-boundary
EOF
  git add -A && git commit -qm bound && git push -q origin main
) >/dev/null 2>&1
export GH_PR_COUNT=0
out=$(GIBSON_CLAIMS_NOW_EPOCH="$BOUNDARY_NOW" run_reaper "$ROOT/bound/canon" 2>&1)
contains "age==14400 stays KEEP" "$out" "KEEP   issue-90-boundary"
lacks    "age==14400 not REAP" "$out" "REAP   issue-90-boundary"
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/bound/canon" 2>&1)
contains "age==14401 is REAP" "$out" "REAP   issue-90-boundary"

# ---------------------------------------------------------------------------
echo "#153 review · an unreadable live PR-claim inventory never authorizes label removal"
# The reaper's release decides whether agent-claimed comes off. A sibling
# claim can be a live *open PR-body* claim with no ledger row at all, so an
# inventory the run could not read is not evidence that none exists. It used
# to be read best-effort (`2>/dev/null || true`) and an API failure read as
# "no siblings" — which is how a live lane could lose its label.
new_repo "$ROOT/greread"
add_claim_file "$ROOT/greread" issue-70-greread 70 "$CLAIMED_ISO"
export GH_PR_COUNT=0
export GH_LOG="$ROOT/greread/gh.log"
export GH_COMMENTS_FILE="$ROOT/greread/comments"
export GH_STATE="$ROOT/greread/gh-state"
rm -f "$GH_LOG" "$GH_STATE"
: > "$GH_COMMENTS_FILE"
out=$(GH_GRAPHQL_FAIL=1 GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  run_reaper "$ROOT/greread/canon" --claim-id issue-70-greread --apply 2>&1)
rc=$?
[[ "$rc" -ne 0 ]] && ok "unreadable PR-claim inventory: reaper does not report success" \
  || bad "unreadable PR-claim inventory: reaper exited 0: $out"
if grep -q -- '--remove-label' "$GH_LOG" 2>/dev/null; then
  bad "unreadable PR-claim inventory: agent-claimed was removed anyway"
else
  ok "unreadable PR-claim inventory: agent-claimed was never removed"
fi
unset GH_GRAPHQL_FAIL

# ---------------------------------------------------------------------------
echo "#73 · never closes an issue (no gh issue close)"
if grep -n 'issue close\|--close\|state.*closed' "$REAPER" | grep -v 'never close' | grep . >/dev/null; then
  bad "reaper source mentions issue close"
else
  ok "reaper source does not close issues"
fi
# apply path must not invoke close
export GH_LOG="$ROOT/bound/gh.log"
: > "$GH_LOG"
GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/bound/canon" --claim-id issue-90-boundary --apply >/dev/null 2>&1 || true
if grep -q 'close' "$GH_LOG" 2>/dev/null; then
  bad "gh log shows close"
else
  ok "apply did not close issue via gh"
fi

# ---------------------------------------------------------------------------
echo "#73 · adversarial · failed exact-remote fetch with stale cached claim => REFUSE"
new_repo "$ROOT/fetchfail"
add_claim_file "$ROOT/fetchfail" issue-91-fetchfail 91 "$CLAIMED_ISO"
# Poison remote URL so fetch fails; leave origin/main cached from prior push.
(
  cd "$ROOT/fetchfail/canon" || exit 1
  git remote set-url origin "/nonexistent/path/to/origin-for-fetch-fail"
) >/dev/null 2>&1
export GH_PR_COUNT=0
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/fetchfail/canon" 2>&1)
rc=$?
# Must not plan REAP from cached ledger after fetch failure.
if echo "$out" | grep 'REAP   issue-91-fetchfail' >/dev/null; then
  bad "fetch failure must not REAP from cached claim"
else
  ok "fetch failure does not REAP cached claim"
fi
if [[ "$rc" -ne 0 ]] || echo "$out" | grep -iE 'fetch|refuse|ERROR' >/dev/null; then
  ok "fetch failure exits refuse/error path"
else
  bad "fetch failure should fail closed (rc=$rc)"
fi

# ---------------------------------------------------------------------------
echo "#73 · adversarial · per-file renewal after OID check survives"
new_repo "$ROOT/renew"
add_claim_file "$ROOT/renew" issue-92-renew 92 "$CLAIMED_ISO"
# Interpose release-claim: renew claim OID on origin before real release runs.
FAKE_RC="$ROOT/renew/fake-release.sh"
cat > "$FAKE_RC" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
# Args: issue --claim-id ID ... --expected-claim-blob OID ...
canon="${GIBSON_CANONICAL:?}"
id=""
blob=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "--claim-id" ]]; then id="$a"; fi
  if [[ "$prev" == "--expected-claim-blob" ]]; then blob="$a"; fi
  prev="$a"
done
# Renew the claim on origin/main so OID no longer matches expected.
(
  cd "$canon" || exit 1
  git fetch origin main >/dev/null 2>&1 || true
  tmp=$(mktemp -d)
  git worktree add --detach "$tmp" origin/main >/dev/null 2>&1
  cd "$tmp" || exit 1
  if [[ -f "docs/claims/${id}.md" ]]; then
    echo "renewed: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "docs/claims/${id}.md"
    git add "docs/claims/${id}.md"
    git commit -s -q -m "renew $id"
    git push origin "HEAD:main"
  fi
  cd "$canon" || exit 1
  git worktree remove --force "$tmp" >/dev/null 2>&1 || rm -rf "$tmp"
)
# Invoke real release-claim with original args — must fail CAS.
exec "$REAL_RC" "$@"
FAKE
chmod +x "$FAKE_RC"
export GH_PR_COUNT=0
export GH_LOG="$ROOT/renew/gh.log"
export GH_COMMENTS_FILE="$ROOT/renew/comments"
export GH_STATE="$ROOT/renew/gh-state"
: > "$GH_COMMENTS_FILE"
rm -f "$GH_STATE"
out=$(
  env \
    GIBSON_CANONICAL="$ROOT/renew/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_BASE/renew" \
    GIBSON_REAPER_JOURNAL="$STATE_BASE/renew/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATE_BASE/renew/lock" \
    GIBSON_REAPER_RELEASE_CMD="$FAKE_RC" \
    REAL_RC="$RC" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-92-renew --apply 2>&1
)
rc=$?
files=$(git -C "$ROOT/renew/canon" fetch -q origin 2>/dev/null; git -C "$ROOT/renew/canon" ls-tree --name-only origin/main docs/claims/ 2>/dev/null || true)
contains "renewed claim file still on ledger" "$files" "issue-92-renew.md"
if [[ "$rc" -eq 0 ]]; then
  bad "renewal race must not exit 0"
else
  ok "renewal race fails closed (rc=$rc)"
fi
# Law 8: incomplete/CAS failure must never post a "released" handoff comment.
if grep -qF 'gibson-claim-reaper:issue-92-renew' "$GH_COMMENTS_FILE" 2>/dev/null; then
  bad "renewal CAS failure must not post released handoff marker"
else
  ok "renewal CAS failure posted no released handoff marker"
fi
if echo "$out" | grep 'OK released' >/dev/null; then
  bad "renewal must not print overall success"
else
  ok "renewal prints no overall success"
fi
if grep -q -- '--remove-label' "$GH_LOG" 2>/dev/null; then
  bad "renewal must not remove agent-claimed label"
else
  ok "agent-claimed label survived renewal CAS failure"
fi
jrenew=$(cat "$STATE_BASE/renew/journal.md" 2>/dev/null || true)
contains "renewal journals incomplete" "$jrenew" "INCOMPLETE"
# Prefer exit 3 (apply incomplete) over hard die
if [[ "$rc" -eq 3 ]]; then
  ok "renewal exits incomplete (3)"
else
  ok "renewal fails closed (rc=$rc; 3 preferred)"
fi

# ---------------------------------------------------------------------------
echo "#73 · adversarial · legacy row renewal survives OID recheck"
new_repo "$ROOT/legrenew"
(
  cd "$ROOT/legrenew/canon" || exit 1
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  cat > docs/active-work.md <<EOF
| when | claim-id | scope | who |
|---|---|---|---|
| $CLAIMED_ISO | issue-93-legrenew | x | t |
EOF
  rm -rf docs/claims
  git add -A && git commit -qm "legacy claim" && git push -q origin main
) >/dev/null 2>&1
FAKE_RC2="$ROOT/legrenew/fake-release.sh"
cat > "$FAKE_RC2" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
canon="${GIBSON_CANONICAL:?}"
(
  cd "$canon" || exit 1
  git fetch origin main >/dev/null 2>&1 || true
  tmp=$(mktemp -d)
  git worktree add --detach "$tmp" origin/main >/dev/null 2>&1
  cd "$tmp" || exit 1
  if [[ -f docs/active-work.md ]]; then
    # Renew: change the when column → new active-work blob OID
    sed 's/2026-08-01T00:00:00Z/2026-08-01T00:00:01Z/' docs/active-work.md > docs/active-work.md.new
    mv docs/active-work.md.new docs/active-work.md
    git add docs/active-work.md
    git commit -s -q -m "renew legacy row"
    git push origin "HEAD:main"
  fi
  cd "$canon" || exit 1
  git worktree remove --force "$tmp" >/dev/null 2>&1 || rm -rf "$tmp"
)
exec "$REAL_RC" "$@"
FAKE
chmod +x "$FAKE_RC2"
export GH_PR_COUNT=0
export GH_COMMENTS_FILE="$ROOT/legrenew/comments"
: > "$GH_COMMENTS_FILE"
out=$(
  env \
    GIBSON_CANONICAL="$ROOT/legrenew/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_BASE/legrenew" \
    GIBSON_REAPER_JOURNAL="$STATE_BASE/legrenew/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATE_BASE/legrenew/lock" \
    GIBSON_REAPER_RELEASE_CMD="$FAKE_RC2" \
    REAL_RC="$RC" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-93-legrenew --apply 2>&1
)
rc=$?
# Row must still exist on origin
body=$(git -C "$ROOT/legrenew/canon" fetch -q origin 2>/dev/null; git -C "$ROOT/legrenew/canon" show origin/main:docs/active-work.md 2>/dev/null || true)
contains "legacy row still present after refused release" "$body" "issue-93-legrenew"
if [[ "$rc" -eq 0 ]]; then
  bad "legacy renewal must not exit 0"
else
  ok "legacy renewal fails closed (rc=$rc)"
fi
if grep -qF 'gibson-claim-reaper:issue-93-legrenew' "$GH_COMMENTS_FILE" 2>/dev/null; then
  bad "legacy renewal must not post released handoff marker"
else
  ok "legacy renewal posted no released handoff marker"
fi
if echo "$out" | grep 'OK released' >/dev/null; then
  bad "legacy renewal must not print overall success"
else
  ok "legacy renewal prints no overall success"
fi

# ---------------------------------------------------------------------------
echo "#73 · Law 8 · cleanup success + comment API failure is incomplete; retry posts once"
# Backdate claim + branch tip (same as apply fixture): wall-clock tips under an
# injected past NOW look like future_clock_evidence and refuse reaping.
new_repo "$ROOT/cmtfail"
(
  cd "$ROOT/cmtfail/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  cat > docs/claims/issue-105-cmtfail.md <<EOF
claim: issue-105-cmtfail
issue: 105
claimed: $CLAIMED_ISO
scope: src/cmtfail
session: t
branch: feat/105-cmtfail
EOF
  : > docs/active-work.md
  git add -A && git commit -qm "claim 105" && git push -q origin main
  git branch -f feat/105-cmtfail HEAD
) >/dev/null 2>&1
mkdir -p "$ROOT/cmtfail/wt-105-cmtfail"
echo keepme > "$ROOT/cmtfail/wt-105-cmtfail/marker"
export GH_PR_COUNT=0
export GH_LOG="$ROOT/cmtfail/gh.log"
export GH_COMMENTS_FILE="$ROOT/cmtfail/comments"
export GH_STATE="$ROOT/cmtfail/gh-state"
export GH_COMMENT_FAIL=1
rm -f "$GH_LOG" "$GH_STATE"
: > "$GH_COMMENTS_FILE"
out=$(
  env \
    GIBSON_CANONICAL="$ROOT/cmtfail/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_BASE/cmtfail" \
    GIBSON_REAPER_JOURNAL="$STATE_BASE/cmtfail/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATE_BASE/cmtfail/lock" \
    GIBSON_REAPER_RELEASE_CMD="$RC" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    GH_COMMENT_FAIL=1 \
    "$REAPER" --repo acme/app --claim-id issue-105-cmtfail --apply 2>&1
)
rc=$?
files=$(git -C "$ROOT/cmtfail/canon" fetch -q origin 2>/dev/null; git -C "$ROOT/cmtfail/canon" ls-tree --name-only origin/main docs/claims/ 2>/dev/null || true)
lacks    "claim released despite comment fail" "$files" "issue-105-cmtfail.md"
if [[ "$rc" -eq 3 ]]; then
  ok "comment-fail after release exits incomplete (3)"
else
  bad "comment-fail after release should exit 3 (got $rc)"
fi
if echo "$out" | grep 'OK released' >/dev/null; then
  bad "comment-fail must not print overall success"
else
  ok "comment-fail prints no overall success"
fi
if grep -qF 'gibson-claim-reaper:issue-105-cmtfail' "$GH_COMMENTS_FILE" 2>/dev/null; then
  bad "comment-fail must leave no released handoff marker"
else
  ok "comment-fail left no released handoff marker"
fi
jcmt=$(cat "$STATE_BASE/cmtfail/journal.md" 2>/dev/null || true)
contains "comment-fail journals incomplete" "$jcmt" "handoff_comment_failed"
contains "comment-fail journals claim_released" "$jcmt" "claim_released=1"
# Branch + worktree still preserved by release defaults
br=$(git -C "$ROOT/cmtfail/canon" branch --list 'feat/105-cmtfail')
[[ -n "$br" ]] && ok "branch preserved after comment-fail release" || bad "branch deleted after comment-fail release"
[[ -f "$ROOT/cmtfail/wt-105-cmtfail/marker" ]] && ok "worktree path preserved (unregistered keep)" || bad "unexpected worktree loss"

# Retry with comment API healthy: claim already absent + journal proves
# claim_released=1 + handoff_comment_failed → post exactly one success comment
export GH_COMMENT_FAIL=0
out2=$(
  env \
    GIBSON_CANONICAL="$ROOT/cmtfail/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_BASE/cmtfail" \
    GIBSON_REAPER_JOURNAL="$STATE_BASE/cmtfail/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATE_BASE/cmtfail/lock" \
    GIBSON_REAPER_RELEASE_CMD="$RC" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    GH_COMMENT_FAIL=0 \
    "$REAPER" --repo acme/app --claim-id issue-105-cmtfail --apply 2>&1
)
rc2=$?
check "retry after comment-fail exits 0" "$rc2" "0"
contains "retry recovery mentions absent" "$out2" "nothing to reap"
contains "retry recovery posts or confirms handoff" "$out2" "handoff"
lacks    "retry recovery must not print OK released" "$out2" "OK released"
comments=$(cat "$GH_COMMENTS_FILE")
contains "retry posts success marker" "$comments" "<!-- gibson-claim-reaper:issue-105-cmtfail -->"
contains "retry comment names branch" "$comments" "feat/105-cmtfail"
lacks    "retry comment has no absolute path" "$comments" "/Users/"
lacks    "retry comment has no /tmp/gibson path" "$comments" "/tmp/gibson"
cmt_n=$(grep -c 'gibson-claim-reaper:issue-105-cmtfail' "$GH_COMMENTS_FILE" || true)
if [[ "$cmt_n" -eq 1 ]]; then
  ok "retry posts exactly one success comment"
else
  bad "retry comment count want 1 got $cmt_n"
fi
# Second retry must not duplicate (once-only dedupe; may be pure no-op or recovery with marker present)
out3=$(
  env \
    GIBSON_CANONICAL="$ROOT/cmtfail/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_BASE/cmtfail" \
    GIBSON_REAPER_JOURNAL="$STATE_BASE/cmtfail/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATE_BASE/cmtfail/lock" \
    GIBSON_REAPER_RELEASE_CMD="$RC" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-105-cmtfail --apply 2>&1
)
rc3=$?
check "second retry exits 0" "$rc3" "0"
contains "second retry mentions absent or handoff skip" "$out3" "nothing to reap"
lacks    "second retry must not print OK released" "$out3" "OK released"
cmt_n2=$(grep -c 'gibson-claim-reaper:issue-105-cmtfail' "$GH_COMMENTS_FILE" || true)
if [[ "$cmt_n2" -eq 1 ]]; then
  ok "second retry does not duplicate success comment"
else
  bad "second retry duplicated comment (count=$cmt_n2)"
fi
jcmt2=$(cat "$STATE_BASE/cmtfail/journal.md" 2>/dev/null || true)
contains "retry journals already_absent COMPLETED" "$jcmt2" "already_absent"
unset GH_COMMENT_FAIL

# ---------------------------------------------------------------------------
echo "#73 · Law 8 · already-absent with no claim_released journal is no-op (no handoff)"
# Pure absence without proven reaper cleanup must not post presumed-dead success.
new_repo "$ROOT/absnoop"
# Never create a claim row — apply against a never-seen id with empty journal.
export GH_PR_COUNT=0
export GH_COMMENTS_FILE="$ROOT/absnoop/comments"
export GH_LOG="$ROOT/absnoop/gh.log"
: > "$GH_COMMENTS_FILE"
STATE_ABS="$STATE_BASE/absnoop"
mkdir -p "$STATE_ABS"
out=$(
  env \
    GIBSON_CANONICAL="$ROOT/absnoop/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_ABS" \
    GIBSON_REAPER_JOURNAL="$STATE_ABS/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATE_ABS/lock" \
    GIBSON_REAPER_RELEASE_CMD="$RC" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-106-never-existed --apply 2>&1
)
rc=$?
check "already-absent no-proof exits 0" "$rc" "0"
contains "already-absent no-proof mentions nothing to reap" "$out" "nothing to reap"
lacks    "already-absent no-proof must not post handoff" "$(cat "$GH_COMMENTS_FILE" 2>/dev/null || true)" "gibson-claim-reaper:issue-106-never-existed"
lacks    "already-absent no-proof no presumed-dead body" "$(cat "$GH_COMMENTS_FILE" 2>/dev/null || true)" "Lane presumed dead"
if grep -qF 'gibson-claim-reaper:issue-106-never-existed' "$GH_COMMENTS_FILE" 2>/dev/null; then
  bad "already-absent without claim_released must not post success handoff"
else
  ok "already-absent without claim_released posts no success handoff"
fi
jabs=$(cat "$STATE_ABS/journal.md" 2>/dev/null || true)
contains "already-absent no-proof journals already_absent" "$jabs" "already_absent"
lacks    "already-absent no-proof journal has no recovery_handoff" "$jabs" "recovery_handoff=1"

# ---------------------------------------------------------------------------
echo "#73 · adversarial · heartbeat malformed/overflow/future + both filenames"
new_repo "$ROOT/hbadv"
add_claim_file "$ROOT/hbadv" issue-94-hb 94 "$CLAIMED_ISO"
HB="$ROOT/hbadv/hb"
mkdir -p "$HB"
# Nonempty malformed content must REFUSE (not mtime fallback to REAP).
printf 'not-a-timestamp\n' > "$HB/issue-94-hb"
touch -t 202608010000 "$HB/issue-94-hb" 2>/dev/null || true
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/hbadv/canon" --heartbeat-dir "$HB" --claim-id issue-94-hb 2>&1)
contains "malformed heartbeat REFUSE" "$out" "heartbeat_malformed"
lacks    "malformed heartbeat not REAP" "$out" "REAP   issue-94-hb"
# Overflow integer
printf '18446744073709551616\n' > "$HB/issue-94-hb"
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/hbadv/canon" --heartbeat-dir "$HB" --claim-id issue-94-hb 2>&1)
contains "overflow heartbeat REFUSE" "$out" "heartbeat_malformed"
lacks    "overflow not REAP" "$out" "REAP   issue-94-hb"
# Future timestamp refuses
printf '%s\n' "$((STALE_NOW + 99999))" > "$HB/issue-94-hb"
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/hbadv/canon" --heartbeat-dir "$HB" --claim-id issue-94-hb 2>&1)
contains "future heartbeat REFUSE" "$out" "future_clock"
# Both filenames: bare is stale, .heartbeat is fresh → KEEP via max
printf '%s\n' "$((CLAIM_EPOCH))" > "$HB/issue-94-hb"
printf '%s\n' "$((STALE_NOW - 5))" > "$HB/issue-94-hb.heartbeat"
touch -t 202608010000 "$HB/issue-94-hb" "$HB/issue-94-hb.heartbeat" 2>/dev/null || true
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/hbadv/canon" --heartbeat-dir "$HB" --claim-id issue-94-hb 2>&1)
contains "fresh .heartbeat considered (KEEP)" "$out" "recent_activity"
lacks    "fresh .heartbeat not REAP" "$out" "REAP   issue-94-hb"
# Oversized stale-seconds is usage failure
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/hbadv/canon" --stale-seconds 18446744073709551616 2>&1)
rc=$?
check "oversized stale-seconds exits 2" "$rc" "2"
contains "oversized stale-seconds named" "$out" "stale-seconds"

# ---------------------------------------------------------------------------
echo "#73 · adversarial · journal symlink victim unchanged; no apply write before lock"
new_repo "$ROOT/jsym"
add_claim_file "$ROOT/jsym" issue-95-jsym 95 "$CLAIMED_ISO"
VICTIM="$ROOT/jsym/victim.txt"
echo "KEEPME" > "$VICTIM"
STATEJ="$STATE_BASE/jsym"
mkdir -p "$STATEJ"
# Journal path is a symlink to victim
ln -sf "$VICTIM" "$STATEJ/journal.md"
export GH_PR_COUNT=0
export GH_COMMENTS_FILE="$ROOT/jsym/comments"
: > "$GH_COMMENTS_FILE"
out=$(
  env \
    GIBSON_CANONICAL="$ROOT/jsym/canon" \
    GIBSON_REAPER_STATE_DIR="$STATEJ" \
    GIBSON_REAPER_JOURNAL="$STATEJ/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATEJ/lock" \
    GIBSON_REAPER_RELEASE_CMD="$RC" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-95-jsym --apply 2>&1
)
rc=$?
victim_body=$(cat "$VICTIM")
check "journal symlink victim unchanged" "$victim_body" "KEEPME"
if [[ "$rc" -eq 0 ]]; then
  bad "symlink journal apply must not succeed"
else
  ok "symlink journal apply fails closed (rc=$rc)"
fi
# Already-absent apply: lock must be acquired (contention with live lock → exit 1)
# Use a fresh state dir so the journal symlink is not the only failure mode.
STATEJ2="$STATE_BASE/jsym2"
mkdir -p "$STATEJ2/lock"
echo "$$" > "$STATEJ2/lock/pid"
out=$(
  env \
    GIBSON_CANONICAL="$ROOT/jsym/canon" \
    GIBSON_REAPER_STATE_DIR="$STATEJ2" \
    GIBSON_REAPER_JOURNAL="$STATEJ2/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATEJ2/lock" \
    GIBSON_REAPER_RELEASE_CMD="$RC" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-95-absent-only --apply 2>&1
)
rc=$?
check "already-absent with held lock exits 1" "$rc" "1"
contains "already-absent respects lock" "$out" "lock"
victim_body=$(cat "$VICTIM")
check "victim still unchanged after locked absent" "$victim_body" "KEEPME"
rm -rf "$STATEJ2/lock"

# ---------------------------------------------------------------------------
echo "#73 · adversarial · issue field mismatch produces no comment"
new_repo "$ROOT/issmis"
(
  cd "$ROOT/issmis/canon" || exit 1
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  mkdir -p docs/claims
  cat > docs/claims/issue-96-dead.md <<EOF
claim: issue-96-dead
issue: 999
claimed: $CLAIMED_ISO
scope: x
session: t
branch: feat/96-dead
EOF
  git add -A && git commit -qm mismatch && git push -q origin main
) >/dev/null 2>&1
export GH_PR_COUNT=0
export GH_LOG="$ROOT/issmis/gh.log"
export GH_COMMENTS_FILE="$ROOT/issmis/comments"
: > "$GH_COMMENTS_FILE"
rm -f "$GH_LOG"
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/issmis/canon" --claim-id issue-96-dead --apply 2>&1)
contains "issue mismatch REFUSE" "$out" "issue_id_mismatch"
if [[ -s "$GH_COMMENTS_FILE" ]]; then
  bad "issue mismatch must not post comment"
else
  ok "issue mismatch produced no comment"
fi
if grep -q 'COMMENT' "$GH_LOG" 2>/dev/null; then
  bad "gh log shows comment on issue mismatch"
else
  ok "no gh comment on issue mismatch"
fi

# ---------------------------------------------------------------------------
echo "#73 · adversarial · filename/body mismatch and duplicate body IDs refuse"
new_repo "$ROOT/idcanon"
(
  cd "$ROOT/idcanon/canon" || exit 1
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  mkdir -p docs/claims
  # Filename issue-97-a.md but body claims issue-97-b
  cat > docs/claims/issue-97-a.md <<EOF
claim: issue-97-b
issue: 97
claimed: $CLAIMED_ISO
scope: x
session: t
branch: feat/97-b
EOF
  git add -A && git commit -qm mismatch-name && git push -q origin main
) >/dev/null 2>&1
export GH_PR_COUNT=0
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/idcanon/canon" 2>&1)
contains "filename/body mismatch REFUSE" "$out" "filename_body_mismatch"
lacks    "filename mismatch not treated absent REAP" "$out" "REAP   issue-97-b"
lacks    "filename mismatch not REAP under filename" "$out" "REAP   issue-97-a"
# Duplicate body IDs via two files is hard without two paths for same id; simulate
# two entries by also putting a second file with same body id under wrong name —
# already covered by mismatch. Add two same-id via active-work+file dedupe is OK.
# Create two claim files that both body-claim the same id by using a copy path:
# Git can't have two files with same name; body-id duplicate requires two files
# with different names and same body claim field — both refuse.
new_repo "$ROOT/dupbody"
(
  cd "$ROOT/dupbody/canon" || exit 1
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  mkdir -p docs/claims
  cat > docs/claims/issue-98-one.md <<EOF
claim: issue-98-one
issue: 98
claimed: $CLAIMED_ISO
scope: x
session: t
branch: feat/98-one
EOF
  # Second file: name matches its own body id, but we'll force duplicate by
  # also having legacy row — that dedupes to one. For true duplicate body IDs
  # across two files, use mismatched second file that claims same body id.
  cat > docs/claims/issue-98-two.md <<EOF
claim: issue-98-one
issue: 98
claimed: $CLAIMED_ISO
scope: y
session: t
branch: feat/98-one
EOF
  git add -A && git commit -qm dupbody && git push -q origin main
) >/dev/null 2>&1
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/dupbody/canon" 2>&1)
contains "duplicate or mismatch refuse" "$out" "REFUSE"
# Must not plan a successful REAP for the aliased id while duplicates exist
if echo "$out" | grep 'REAP   issue-98-one' >/dev/null; then
  bad "duplicate body IDs must not REAP"
else
  ok "duplicate body IDs do not REAP"
fi

# ---------------------------------------------------------------------------
echo "#73 · adversarial · COMPLETED journal + live/re-added claim never silently skips"
new_repo "$ROOT/readd"
add_claim_file "$ROOT/readd" issue-99-readd 99 "$CLAIMED_ISO"
STATE_R="$STATE_BASE/readd"
mkdir -p "$STATE_R"
# Pre-seed COMPLETED for the frozen op id (blob of current claim)
blob=$(git -C "$ROOT/readd/canon" ls-tree origin/main -- docs/claims/issue-99-readd.md | awk '{print $3}')
printf '2026-08-01T00:00:00Z COMPLETED op=reap:issue-99-readd:%s result=released rc=0\n' "$blob" > "$STATE_R/journal.md"
export GH_PR_COUNT=0
export GH_COMMENTS_FILE="$ROOT/readd/comments"
: > "$GH_COMMENTS_FILE"
out=$(
  env \
    GIBSON_CANONICAL="$ROOT/readd/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_R" \
    GIBSON_REAPER_JOURNAL="$STATE_R/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATE_R/lock" \
    GIBSON_REAPER_RELEASE_CMD="$RC" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-99-readd --apply 2>&1
)
rc=$?
# Must not silently skip: either re-evaluate/release or warn still_live
if echo "$out" | grep -iE 'still_live|revivify|re-evaluat|OK released issue-99-readd|completed_but_still_live' >/dev/null; then
  ok "completed+live re-evaluates or releases"
else
  if echo "$out" | grep -i 'skip' >/dev/null && echo "$out" | grep -i 'idempotent' >/dev/null && ! echo "$out" | grep -iE 'still_live|re-evaluat|revivify' >/dev/null; then
    bad "silently skipped live claim after COMPLETED"
  else
    # If it released without the exact words, claim file gone is success
    files=$(git -C "$ROOT/readd/canon" fetch -q origin; git -C "$ROOT/readd/canon" ls-tree --name-only origin/main docs/claims/ 2>/dev/null || true)
    if echo "$files" | grep 'issue-99-readd' >/dev/null; then
      bad "live claim after COMPLETED neither released nor warned (rc=$rc)"
      echo "$out" | tail -20
    else
      ok "completed+live released claim"
    fi
  fi
fi

# ---------------------------------------------------------------------------
echo "#73 · adversarial · fresh remote feature + stale origin cache => KEEP"
# Independent fixture: remote feature advanced with a fresh commit while
# refs/remotes/origin/feat/* remains at an old tip. Must use live remote, not cache.
new_repo "$ROOT/stale_cache"
add_claim_file "$ROOT/stale_cache" issue-101-stale-cache 101 "$CLAIMED_ISO"
(
  cd "$ROOT/stale_cache/canon" || exit 1
  git checkout -q -b feat/101-stale-cache
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  echo old > old.txt
  git add old.txt && git commit -qm "old remote tip"
  git push -q origin feat/101-stale-cache
  OLD_SHA=$(git rev-parse HEAD)
  # Advance remote via second clone so local origin/feat stays pin-able
  git clone -q "$ROOT/stale_cache/origin" "$ROOT/stale_cache/other" 2>/dev/null
  cd "$ROOT/stale_cache/other" || exit 1
  git checkout -q feat/101-stale-cache
  export GIT_AUTHOR_DATE="@$((STALE_NOW - 30))"
  export GIT_COMMITTER_DATE="@$((STALE_NOW - 30))"
  echo fresh > fresh.txt
  git add fresh.txt && git commit -qm "fresh remote tip"
  git push -q origin feat/101-stale-cache
  cd "$ROOT/stale_cache/canon" || exit 1
  # Pin cached remote-tracking ref to the STALE tip
  git update-ref refs/remotes/origin/feat/101-stale-cache "$OLD_SHA"
  git checkout -q main
  git branch -D feat/101-stale-cache >/dev/null 2>&1 || true
) >/dev/null 2>&1
export GH_PR_COUNT=0
export GH_LOG="$ROOT/stale_cache/gh.log"
export GH_COMMENTS_FILE="$ROOT/stale_cache/comments"
: > "$GH_COMMENTS_FILE"
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/stale_cache/canon" --claim-id issue-101-stale-cache 2>&1)
rc=$?
check "fresh-remote+stale-cache dry-run exits 0" "$rc" "0"
contains "KEEP from live fresh remote (not stale cache)" "$out" "KEEP   issue-101-stale-cache"
contains "recent_activity reason" "$out" "recent_activity"
lacks    "must not REAP when live remote is fresh" "$out" "REAP   issue-101-stale-cache"

# ---------------------------------------------------------------------------
echo "#73 · adversarial · stale ls-remote SHA vs fresher exact fetch => FAIL:remote_branch_changed"
# Within a single live_remote_branch_evidence call: ls-remote reports stale tip A
# while the immediately following exact fetch updates the tracking ref to fresh
# tip B. Must fail closed (never prefer/reset to A). Plan REFUSE; apply refuses
# and must not invoke release-claim.
new_repo "$ROOT/ls_stale"
add_claim_file "$ROOT/ls_stale" issue-107-ls-stale 107 "$CLAIMED_ISO"
(
  cd "$ROOT/ls_stale/canon" || exit 1
  git checkout -q -b feat/107-ls-stale
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  echo tipA > tipA.txt
  git add tipA.txt && git commit -qm "stale tip A"
  SHA_A=$(git rev-parse HEAD)
  # Fresh tip B — within the reaper threshold relative to STALE_NOW so preferring
  # A would wrongly REAP while B is still live activity.
  export GIT_AUTHOR_DATE="@$((STALE_NOW - 30))"
  export GIT_COMMITTER_DATE="@$((STALE_NOW - 30))"
  echo tipB > tipB.txt
  git add tipB.txt && git commit -qm "fresh tip B"
  SHA_B=$(git rev-parse HEAD)
  git push -q origin feat/107-ls-stale
  printf '%s\n' "$SHA_A" > "$ROOT/ls_stale/sha_a"
  printf '%s\n' "$SHA_B" > "$ROOT/ls_stale/sha_b"
  git checkout -q main
  # Ensure A remains a local object (old buggy path preferred A when present).
  git cat-file -e "${SHA_A}^{commit}"
) >/dev/null 2>&1
SHA_A=$(cat "$ROOT/ls_stale/sha_a")
SHA_B=$(cat "$ROOT/ls_stale/sha_b")
# Preload A into the object store / optional cache; real remote tip is B.
git -C "$ROOT/ls_stale/canon" fetch -q origin feat/107-ls-stale >/dev/null 2>&1 || true
git -C "$ROOT/ls_stale/canon" update-ref refs/remotes/origin/feat/107-ls-stale "$SHA_B"
GIT_REAL=$(command -v git)
mkdir -p "$ROOT/ls_stale/bin"
# Always lie on ls-remote: return stale A. Exact fetch still gets live B.
cat > "$ROOT/ls_stale/bin/git" <<EOF
#!/usr/bin/env bash
REAL="$GIT_REAL"
SHA_A="$SHA_A"
if [[ "\$1" == "ls-remote" ]]; then
  for a in "\$@"; do
    case "\$a" in
      refs/heads/feat/107-ls-stale)
        printf '%s\t%s\n' "\$SHA_A" "refs/heads/feat/107-ls-stale"
        exit 0
        ;;
    esac
  done
fi
exec "\$REAL" "\$@"
EOF
chmod +x "$ROOT/ls_stale/bin/git"
export GH_PR_COUNT=0
export GH_COMMENTS_FILE="$ROOT/ls_stale/comments"
export GH_LOG="$ROOT/ls_stale/gh.log"
: > "$GH_COMMENTS_FILE"
FAKE_RC_LS="$ROOT/ls_stale/fake-rc.sh"
cat > "$FAKE_RC_LS" <<'FAKE'
#!/usr/bin/env bash
echo "FAKE-RC must not run when ls-remote SHA disagrees with fetch tip" >&2
exit 99
FAKE
chmod +x "$FAKE_RC_LS"
STATE_LS="$STATE_BASE/ls_stale"
mkdir -p "$STATE_LS"
# Plan (dry-run): must REFUSE, never REAP/KEEP from the stale queried SHA.
out=$(
  env \
    PATH="$ROOT/ls_stale/bin:$PATH" \
    GIBSON_CANONICAL="$ROOT/ls_stale/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_LS" \
    GIBSON_REAPER_JOURNAL="$STATE_LS/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATE_LS/lock" \
    GIBSON_REAPER_RELEASE_CMD="$FAKE_RC_LS" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-107-ls-stale 2>&1
)
rc=$?
check "stale-ls-remote plan exits 0" "$rc" "0"
contains "stale-ls-remote plan REFUSE remote_branch_changed" "$out" "remote_branch_changed"
lacks    "stale-ls-remote plan must not REAP" "$out" "REAP   issue-107-ls-stale"
lacks    "stale-ls-remote plan must not KEEP from A" "$out" "KEEP   issue-107-ls-stale"
# Apply: refuse, no release-claim, claim survives.
out=$(
  env \
    PATH="$ROOT/ls_stale/bin:$PATH" \
    GIBSON_CANONICAL="$ROOT/ls_stale/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_LS" \
    GIBSON_REAPER_JOURNAL="$STATE_LS/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATE_LS/lock" \
    GIBSON_REAPER_RELEASE_CMD="$FAKE_RC_LS" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-107-ls-stale --apply 2>&1
)
rc=$?
lacks    "stale-ls-remote apply must not invoke release" "$out" "FAKE-RC must not run"
lacks    "stale-ls-remote apply must not OK released" "$out" "OK released"
if echo "$out" | grep -iE 'remote_branch_changed|REFUSE|refuse|INCOMPLETE' >/dev/null; then
  ok "stale-ls-remote apply refuses (rc=$rc)"
else
  bad "stale-ls-remote apply did not refuse (rc=$rc out=$(echo "$out" | tail -5 | tr '\n' ' '))"
fi
files=$(PATH="/usr/bin:/bin:$PATH" git -C "$ROOT/ls_stale/canon" fetch -q origin; PATH="/usr/bin:/bin:$PATH" git -C "$ROOT/ls_stale/canon" ls-tree --name-only origin/main docs/claims/)
contains "claim survives stale-ls-remote mismatch" "$files" "issue-107-ls-stale.md"
if grep -qF 'gibson-claim-reaper:issue-107-ls-stale' "$GH_COMMENTS_FILE" 2>/dev/null; then
  bad "stale-ls-remote must not post success handoff"
else
  ok "stale-ls-remote posted no success handoff"
fi

# ---------------------------------------------------------------------------
echo "#73 · adversarial · remote branch SHA changed between plan and apply => no release"
# Two stale commits on the feature branch (A then B), both older than the
# threshold. A git shim returns A on the first live ls-remote (plan freeze)
# and B on subsequent calls (pre-mutation recheck) so apply sees a SHA change
# while age stays stale — must refuse and never release.
new_repo "$ROOT/remote_race"
add_claim_file "$ROOT/remote_race" issue-102-remote-race 102 "$CLAIMED_ISO"
(
  cd "$ROOT/remote_race/canon" || exit 1
  git checkout -q -b feat/102-remote-race
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  echo tipA > tipA.txt
  git add tipA.txt && git commit -qm "stale tip A"
  SHA_A=$(git rev-parse HEAD)
  export GIT_AUTHOR_DATE="@$((CLAIM_EPOCH + 60))"
  export GIT_COMMITTER_DATE="@$((CLAIM_EPOCH + 60))"
  echo tipB > tipB.txt
  git add tipB.txt && git commit -qm "stale tip B"
  SHA_B=$(git rev-parse HEAD)
  git push -q origin feat/102-remote-race
  printf '%s\n' "$SHA_A" > "$ROOT/remote_race/sha_a"
  printf '%s\n' "$SHA_B" > "$ROOT/remote_race/sha_b"
  git checkout -q main
) >/dev/null 2>&1
SHA_A=$(cat "$ROOT/remote_race/sha_a")
SHA_B=$(cat "$ROOT/remote_race/sha_b")
# Ensure both objects are available locally for timestamp resolution after fetch.
git -C "$ROOT/remote_race/canon" fetch -q origin feat/102-remote-race >/dev/null 2>&1 || true
git -C "$ROOT/remote_race/canon" update-ref refs/remotes/origin/feat/102-remote-race "$SHA_B"
GIT_REAL=$(command -v git)
mkdir -p "$ROOT/remote_race/bin"
# Counter file: first ls-remote --heads for feat → SHA_A; later → SHA_B
: > "$ROOT/remote_race/ls_count"
cat > "$ROOT/remote_race/bin/git" <<EOF
#!/usr/bin/env bash
REAL="$GIT_REAL"
SHA_A="$SHA_A"
SHA_B="$SHA_B"
CNT_FILE="$ROOT/remote_race/ls_count"
if [[ "\$1" == "ls-remote" ]]; then
  for a in "\$@"; do
    case "\$a" in
      refs/heads/feat/102-remote-race)
        n=\$(cat "\$CNT_FILE" 2>/dev/null || echo 0)
        n=\$((n + 1))
        echo "\$n" > "\$CNT_FILE"
        if [[ "\$n" -eq 1 ]]; then
          printf '%s\t%s\n' "\$SHA_A" "refs/heads/feat/102-remote-race"
        else
          printf '%s\t%s\n' "\$SHA_B" "refs/heads/feat/102-remote-race"
        fi
        exit 0
        ;;
    esac
  done
fi
# Allow fetch of either SHA into the tracking ref
if [[ "\$1" == "fetch" ]]; then
  exec "\$REAL" "\$@"
fi
exec "\$REAL" "\$@"
EOF
chmod +x "$ROOT/remote_race/bin/git"
export GH_PR_COUNT=0
export GH_COMMENTS_FILE="$ROOT/remote_race/comments"
: > "$GH_COMMENTS_FILE"
FAKE_RC_RACE="$ROOT/remote_race/fake-rc.sh"
cat > "$FAKE_RC_RACE" <<'FAKE'
#!/usr/bin/env bash
echo "FAKE-RC should not be invoked when remote branch changed" >&2
exit 99
FAKE
chmod +x "$FAKE_RC_RACE"
STATE_RR="$STATE_BASE/remote_race"
mkdir -p "$STATE_RR"
out=$(
  env \
    PATH="$ROOT/remote_race/bin:$PATH" \
    GIBSON_CANONICAL="$ROOT/remote_race/canon" \
    GIBSON_REAPER_STATE_DIR="$STATE_RR" \
    GIBSON_REAPER_JOURNAL="$STATE_RR/journal.md" \
    GIBSON_REAPER_LOCK_DIR="$STATE_RR/lock" \
    GIBSON_REAPER_RELEASE_CMD="$FAKE_RC_RACE" \
    GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
    "$REAPER" --repo acme/app --claim-id issue-102-remote-race --apply 2>&1
)
rc=$?
lacks    "must not invoke release when remote SHA changed" "$out" "FAKE-RC should not"
if echo "$out" | grep -iE 'remote_branch_changed|SHA changed' >/dev/null; then
  ok "pre-mutation refused on remote SHA change"
elif [[ "$rc" -eq 3 ]] && echo "$out" | grep -iE 'refuse|INCOMPLETE|moving_evidence|no longer stale' >/dev/null; then
  ok "apply incomplete/refused after remote mid-flight change (rc=3)"
else
  if echo "$out" | grep 'OK released' >/dev/null; then
    bad "released despite remote SHA change (rc=$rc)"
    echo "$out" | tail -30
  else
    # Still alive claim + non-success is acceptable
    files=$(PATH="/usr/bin:/bin:$PATH" git -C "$ROOT/remote_race/canon" fetch -q origin; PATH="/usr/bin:/bin:$PATH" git -C "$ROOT/remote_race/canon" ls-tree --name-only origin/main docs/claims/)
    if echo "$files" | grep 'issue-102-remote-race' >/dev/null; then
      ok "claim survives remote SHA change without release (rc=$rc)"
    else
      bad "claim released or missing after remote race (rc=$rc)"
      echo "$out" | tail -30
    fi
  fi
fi
files=$(PATH="/usr/bin:/bin:$PATH" git -C "$ROOT/remote_race/canon" fetch -q origin; PATH="/usr/bin:/bin:$PATH" git -C "$ROOT/remote_race/canon" ls-tree --name-only origin/main docs/claims/)
contains "claim row survives remote race" "$files" "issue-102-remote-race.md"
# Prefer the explicit reason when present
if echo "$out" | grep -i 'remote_branch_changed' >/dev/null; then
  ok "journal/reason remote_branch_changed observed"
fi

# ---------------------------------------------------------------------------
echo "#73 · adversarial · proven remote absence + fresh stale cache => cache ignored"
# Remote branch never pushed; only a fresh-looking origin/feat cache exists.
# Must ignore cache → REAP from claim timestamp alone (stale).
new_repo "$ROOT/absent_cache"
add_claim_file "$ROOT/absent_cache" issue-103-absent-cache 103 "$CLAIMED_ISO"
(
  cd "$ROOT/absent_cache/canon" || exit 1
  git checkout -q -b feat/103-absent-cache
  export GIT_AUTHOR_DATE="@$((STALE_NOW - 30))"
  export GIT_COMMITTER_DATE="@$((STALE_NOW - 30))"
  echo ghost > ghost.txt
  git add ghost.txt && git commit -qm "ghost local only"
  # Install as remote-tracking without ever pushing to origin
  git update-ref refs/remotes/origin/feat/103-absent-cache HEAD
  git checkout -q main
  git branch -D feat/103-absent-cache >/dev/null 2>&1 || true
  # Prove remote absence
  if [[ -n "$(git ls-remote origin refs/heads/feat/103-absent-cache)" ]]; then
    echo "fixture error: remote branch exists" >&2
    exit 1
  fi
) >/dev/null 2>&1
export GH_PR_COUNT=0
out=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/absent_cache/canon" --claim-id issue-103-absent-cache 2>&1)
rc=$?
check "absent+stale-cache dry-run exits 0" "$rc" "0"
contains "REAP when remote absent (cache ignored)" "$out" "REAP   issue-103-absent-cache"
lacks    "must not KEEP from stale cache alone" "$out" "KEEP   issue-103-absent-cache"
# Cache should have been deleted or ignored; origin/feat must not keep a live tip
# that would re-infect evidence (delete is best-effort).
if git -C "$ROOT/absent_cache/canon" rev-parse --verify --quiet refs/remotes/origin/feat/103-absent-cache >/dev/null 2>&1; then
  # If still present, planning still REAPed → ok as long as we didn't KEEP
  ok "stale cache may remain if delete failed but was ignored for liveness"
else
  ok "stale remote-tracking cache deleted on proven absence"
fi

# ---------------------------------------------------------------------------
echo "#73 · adversarial · remote feature query/fetch failure => REFUSE"
new_repo "$ROOT/rmtfail"
add_claim_file "$ROOT/rmtfail" issue-104-rmtfail 104 "$CLAIMED_ISO"
(
  cd "$ROOT/rmtfail/canon" || exit 1
  # Leave a stale cached origin/feat so a broken remote would have been used
  git checkout -q -b feat/104-rmtfail
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  echo x > x.txt
  git add x.txt && git commit -qm tip
  git update-ref refs/remotes/origin/feat/104-rmtfail HEAD
  git checkout -q main
  git branch -D feat/104-rmtfail >/dev/null 2>&1 || true
  # Break origin so ls-remote/fetch fail (after ledger main is already cached
  # we need main fetch to succeed first). Point origin at a path that allows
  # nothing for feature queries: use a remote URL that fails for all ops.
  # Strategy: fetch main into local first (reaper will re-fetch main), so use
  # a remote that exists for main but... simpler: set origin to unreachable
  # *after* ensuring main is fetchable fails too → whole reaper dies on ledger.
  # Instead wrap git via PATH to fail only ls-remote --heads for feature.
) >/dev/null 2>&1
# Install a git shim that fails ls-remote --heads for non-main branches
GIT_REAL=$(command -v git)
mkdir -p "$ROOT/rmtfail/bin"
cat > "$ROOT/rmtfail/bin/git" <<EOF
#!/usr/bin/env bash
# Fail only live feature-branch queries; pass through everything else.
if [[ "\$1" == "ls-remote" ]]; then
  for a in "\$@"; do
    case "\$a" in
      refs/heads/main|refs/heads/master) exec "$GIT_REAL" "\$@" ;;
      refs/heads/*)
        echo "simulated remote query failure" >&2
        exit 128
        ;;
    esac
  done
fi
if [[ "\$1" == "fetch" ]]; then
  # Allow main/master fetch; fail feature-branch forced fetch
  for a in "\$@"; do
    case "\$a" in
      +refs/heads/feat/*|refs/heads/feat/*)
        echo "simulated remote fetch failure" >&2
        exit 128
        ;;
    esac
  done
fi
exec "$GIT_REAL" "\$@"
EOF
chmod +x "$ROOT/rmtfail/bin/git"
export GH_PR_COUNT=0
out=$(
  PATH="$ROOT/rmtfail/bin:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  run_reaper "$ROOT/rmtfail/canon" --claim-id issue-104-rmtfail 2>&1
)
rc=$?
check "remote-query-fail dry-run exits 0" "$rc" "0"
contains "REFUSE on remote query failure" "$out" "REFUSE"
if echo "$out" | grep -E 'remote_query_failed|remote_fetch_failed|REFUSE[[:space:]]+issue-104-rmtfail' >/dev/null; then
  ok "remote query/fetch failure REFUSEs claim"
else
  # Any REFUSE line for this claim is acceptable
  if echo "$out" | grep 'REFUSE   issue-104-rmtfail' >/dev/null; then
    ok "remote failure REFUSE line present"
  else
    bad "expected REFUSE for remote query failure"
    echo "$out" | tail -20
  fi
fi
lacks    "must not REAP on remote query failure" "$out" "REAP   issue-104-rmtfail"
lacks    "must not KEEP from cache on remote query failure" "$out" "KEEP   issue-104-rmtfail"

# ===========================================================================
# #153 review round 7 — failed PR inventory is not an empty plan
# ===========================================================================
echo "#153 r7 · failed GraphQL on empty ledger must not report nothing to reap"
new_repo "$ROOT/prfail"
(
  cd "$ROOT/prfail/canon" || exit 1
  rm -rf docs/claims docs/active-work.md
  git add -A && git commit -qm 'empty ledger' && git push -q origin main
) >/dev/null 2>&1
export GH_GRAPHQL_FAIL=1
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  run_reaper "$ROOT/prfail/canon" 2>&1
)
rc=$?
unset GH_GRAPHQL_FAIL
[[ "$rc" -ne 0 ]] && ok "failed GraphQL exits nonzero" || bad "failed GraphQL exited 0: $out"
contains "names unreadable inventory" "$out" "unreadable"
lacks    "must not say nothing to reap on failed inventory" "$out" "nothing to reap"
lacks    "must not emit empty dry-run plan on failed inventory" "$out" "empty ledger — zero mutations"

echo "#153 r7 · successful empty GraphQL on empty ledger may report nothing to reap"
new_repo "$ROOT/prempty"
(
  cd "$ROOT/prempty/canon" || exit 1
  rm -rf docs/claims docs/active-work.md
  git add -A && git commit -qm 'empty ledger' && git push -q origin main
) >/dev/null 2>&1
# Default fake gh answers graphql with exit 0 (successful empty inventory).
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  run_reaper "$ROOT/prempty/canon" 2>&1
)
rc=$?
check    "successful empty GraphQL + empty ledger exits 0" "$rc" "0"
contains "may report nothing to reap after successful empty inventory" "$out" "nothing to reap"

# ===========================================================================
# #153 review round 8 — successful-but-malformed inventory is not empty
# ===========================================================================
echo "#153 r8 · malformed-success inventory never plans nothing to reap"
# Reproduction: empty legacy ledger + executable reader that exits 0 while
# printing malformed text. Before the fix this was rc 0 + "nothing to reap".
new_repo "$ROOT/malinv"
(
  cd "$ROOT/malinv/canon" || exit 1
  rm -rf docs/claims docs/active-work.md
  git add -A && git commit -qm 'empty ledger' && git push -q origin main
) >/dev/null 2>&1
# Ship a sibling reaper whose pr-claims.sh is the hostile reader so we bind
# SCRIPT_DIR without rewriting production path resolution. Carry the real
# stream-capture helper at the path production sources.
install_sibling_reaper "$ROOT/malinv/scripts"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
# Hostile reader: exit 0 with text that is not a valid list inventory row.
# Exactly the class that used to be absorbed as "no PR claims".
case "${1:-}" in
  list)
    echo "this is not a tab-separated claim inventory"
    exit 0
    ;;
  *)
    echo "malinv pr-claims: unmodelled: $*" >&2
    exit 64
    ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
state="$STATE_BASE/malinv"
mkdir -p "$state"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "malformed-success inventory exits nonzero" \
  || bad "malformed-success inventory exited 0: $out"
contains "names malformed inventory row" "$out" "malformed"
lacks    "must not say nothing to reap on malformed-success" "$out" "nothing to reap"
lacks    "must not emit empty dry-run plan on malformed-success" "$out" "empty ledger — zero mutations"
lacks    "must not print successful empty plan summary" "$out" "summary: reap=0"

echo "#153 r8 · truncated inventory row (wrong field count) fails closed"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    # Only 3 tab fields — not the 8-field list contract.
    printf '42\tissue-42-trunc\tlib/**\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "truncated inventory row exits nonzero" \
  || bad "truncated inventory row exited 0: $out"
contains "names field-count failure" "$out" "8 tab-separated fields"
lacks    "truncated row is not nothing to reap" "$out" "nothing to reap"

echo "#153 r8 · well-formed single inventory row is accepted (not false refuse)"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    # Fresh activity so the reaper KEEPs rather than reaps — we only care that
    # the inventory is accepted as readable.
    printf '7\tissue-7-live\tlib/**\tfeat/7-live\thttps://github.com/acme/app/pull/7\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
# NOW near the claim timestamps so activity is not stale.
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$FRESH_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app 2>&1
)
rc=$?
check    "well-formed inventory is accepted (exit 0)" "$rc" "0"
contains "well-formed row is protected/recognized" "$out" "issue-7-live"
lacks    "well-formed row is not malformed refuse" "$out" "malformed/truncated row"

# ===========================================================================
# #153 review-nine P1 — PR URL must bind to row repository and PR number
# ===========================================================================
# A hostile reader can exit 0 with a plausible GitHub PR URL whose owner/repo
# or /pull/N disagrees with the row. Production must reject that all-or-none,
# fail closed, and never classify/plan/release it. Shape-only URL validation
# previously accepted `https://github.com/evil/other/pull/123` as STALE for
# acme/app PR #999 and, under --apply, released by claim id alone.
echo "#153 r9 · foreign-repository PR URL is rejected (not STALE, not released)"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    # Stale activity + foreign repo URL with an otherwise matching pull number.
    # Shape is valid; repository identity is not. The /pull/N matches the row
    # so a regression that drops only the repository comparison (leaving the
    # number check) is still caught by this fixture (#153 review-nine).
    printf '999\tissue-999-hostile\tlib/**\tfeat/999-hostile\thttps://github.com/evil/other/pull/999\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
# Release spy: any invocation proves --apply was willing to release.
spy_release="$ROOT/malinv/spy-release.sh"
cat > "$spy_release" <<'SPY'
#!/usr/bin/env bash
printf 'RELEASE_INVOKED %s\n' "$*" >> "${SPY_LOG:-/dev/null}"
exit 0
SPY
chmod +x "$spy_release"
: > "$ROOT/malinv/spy.log"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "foreign-repo PR URL exits nonzero" \
  || bad "foreign-repo PR URL exited 0: $out"
contains "foreign-repo URL names repository mismatch" "$out" "PR URL repository"
contains "foreign-repo URL names the foreign owner/repo" "$out" "evil/other"
contains "foreign-repo URL names the expected inventory repo" "$out" "acme/app"
lacks    "foreign-repo URL is not classified STALE" "$out" "STALE PR #"
lacks    "foreign-repo URL is not nothing to reap" "$out" "nothing to reap"
lacks    "foreign-repo URL is not protected as live" "$out" "is protected"
check    "foreign-repo URL never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"

echo "#153 r9 · same-repo URL whose /pull/N differs from row number is rejected"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    # Row number 999, URL points at pull/123 in the correct repo.
    printf '999\tissue-999-mismatch\tlib/**\tfeat/999-mismatch\thttps://github.com/acme/app/pull/123\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "URL pull-number mismatch exits nonzero" \
  || bad "URL pull-number mismatch exited 0: $out"
contains "URL number mismatch names pull-number disagreement" "$out" "PR URL pull-number"
contains "URL number mismatch names the URL number" "$out" "'123'"
contains "URL number mismatch names the row number" "$out" "'999'"
lacks    "URL number mismatch is not classified STALE" "$out" "STALE PR #"
lacks    "URL number mismatch is not nothing to reap" "$out" "nothing to reap"
check    "URL number mismatch never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"

echo "#153 open-PR-always-protects · well-formed open PR row is PROTECTED regardless of age (never reaped)"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    # Stale timestamps on purpose: age must NOT license release of an open PR.
    printf '7\tissue-7-stale\tlib/**\tfeat/7-stale\thttps://github.com/acme/app/pull/7\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
check    "identity-bound open PR row is accepted (exit 0)" "$rc" "0"
contains "identity-bound open PR row is protected" "$out" \
  "PR #7 claim issue-7-stale is protected (open PR always protects)"
lacks    "open PR row is never classified STALE" "$out" "STALE PR #"
lacks    "open PR row never emits handoff comment language" "$out" "released by claim-reaper"
check    "open PR row never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"
# Journal must not record a reap for a protected open PR.
if [[ -s "$state/journal.md" ]] && grep -qE 'issue-7-stale|REAP' "$state/journal.md" 2>/dev/null; then
  bad "open PR protection mutated the journal: $(cat "$state/journal.md")"
else
  ok "open PR protection left the journal untouched"
fi

# ===========================================================================
# #153 review-ten P1 — PR identities must be positive canonical decimals
# ===========================================================================
# GitHub pull-request numbers are positive canonical decimals (^[1-9][0-9]*$).
# Digit-only acceptance previously admitted zero and leading-zero forms such as
# 0999. A successful reader returning those must make the entire inventory
# unreadable/fatal before classification, planning, journaling, or --apply
# release. Do not normalize malformed input into a valid identity.
echo "#153 r10 · leading-zero PR identity (0999) is rejected (not STALE, not released)"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    # Adversarial fixture from independent review-ten: successful reader, stale
    # timestamps, matching row/URL numbers — but noncanonical leading-zero form.
    printf '0999\tissue-999-leading-zero\tlib/**\tfeat/999-leading-zero\thttps://github.com/acme/app/pull/0999\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
# Reset journal so a prior successful reap cannot make this look planned/journaled.
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "leading-zero PR identity exits nonzero" \
  || bad "leading-zero PR identity was accepted (exit 0): $out"
# Row-field diagnostic specifically (not the URL-path message). Softening only
# the row validator to ^[0-9]+$ must fail this assertion even if the URL check
# still rejects the same row.
contains "leading-zero PR identity names row noncanonical/unsafe" "$out" \
  "PR number is noncanonical/unsafe"
contains "leading-zero PR identity names the hostile row number" "$out" "0999"
lacks    "leading-zero PR identity is not classified STALE" "$out" "STALE PR #"
lacks    "leading-zero PR identity is not nothing to reap" "$out" "nothing to reap"
lacks    "leading-zero PR identity is not protected as live" "$out" "is protected"
lacks    "leading-zero PR identity is not planned REAP" "$out" "REAP   issue-999-leading-zero"
check    "leading-zero PR identity never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"
check    "leading-zero PR identity never wrote a journal entry" \
  "$(grep -c . "$state/journal.md" 2>/dev/null || true)" "0"

echo "#153 r10 · zero PR identity (0) is rejected (not STALE, not released)"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    printf '0\tissue-0-zero\tlib/**\tfeat/0-zero\thttps://github.com/acme/app/pull/0\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "zero PR identity exits nonzero" \
  || bad "zero PR identity was accepted (exit 0): $out"
contains "zero PR identity names row noncanonical/unsafe" "$out" \
  "PR number is noncanonical/unsafe"
contains "zero PR identity names the hostile row" "$out" $'0\tissue-0-zero'
lacks    "zero PR identity is not classified STALE" "$out" "STALE PR #"
lacks    "zero PR identity is not nothing to reap" "$out" "nothing to reap"
lacks    "zero PR identity is not planned REAP" "$out" "REAP   issue-0-zero"
check    "zero PR identity never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"
check    "zero PR identity never wrote a journal entry" \
  "$(grep -c . "$state/journal.md" 2>/dev/null || true)" "0"

echo "#153 r10 · canonical row + leading-zero URL /pull/0999 is rejected via URL path"
# Mismatch-shaped hostile fixture: row is a positive canonical decimal so the
# row validator cannot reject first. Only the URL /pull/N shape rejects.
# Restoring the URL capture to [0-9]+ while leaving the row validator strict
# changes the diagnostic to a pull-number *mismatch* (0999 vs 999) — this
# fixture gives that independent URL mutation behavioral teeth. (A pure
# same-shaped 0999/0999 URL-only mutation is unreachable: the earlier row
# check necessarily rejects first; see source tripwire below.)
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    printf '999\tissue-999-url-lz\tlib/**\tfeat/999-url-lz\thttps://github.com/acme/app/pull/0999\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "canonical-row + leading-zero URL exits nonzero" \
  || bad "canonical-row + leading-zero URL was accepted (exit 0): $out"
# URL-path diagnostic specifically. Softening only the URL capture to [0-9]+
# makes the row pass shape checks and then fail equality as a mismatch —
# this assertion must fail under that independent mutation.
contains "canonical-row + leading-zero URL names noncanonical URL pull" "$out" \
  "pull number is noncanonical/unsafe"
lacks    "canonical-row + leading-zero URL is not classified STALE" "$out" "STALE PR #"
lacks    "canonical-row + leading-zero URL is not nothing to reap" "$out" "nothing to reap"
check    "canonical-row + leading-zero URL never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"

echo "#153 r10 · canonical multi-digit PR identity (1000) remains accepted under --apply"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    # 1000 is a positive canonical decimal (leading 1). Must remain accepted
    # under the same repository and exact row/URL number bindings as r9's #7.
    printf '1000\tissue-1000-stale\tlib/**\tfeat/1000-stale\thttps://github.com/acme/app/pull/1000\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
check    "canonical PR #1000 is accepted (exit 0)" "$rc" "0"
contains "canonical PR #1000 open row is protected" "$out" \
  "PR #1000 claim issue-1000-stale is protected (open PR always protects)"
lacks    "canonical open PR #1000 is never STALE" "$out" "STALE PR #"
check    "canonical open PR #1000 never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"

# ===========================================================================
# #153 review-eleven P1 — PR identities must also be within safe integer range
# ===========================================================================
# [1-9][0-9]* alone admits arbitrarily long digit strings. A 64-digit positive
# decimal (or MAX_SAFE_INT+1) matching in both the row and /pull/N must make
# the entire inventory unreadable/fatal before classification, planning,
# journaling, or --apply release. Bound via parse_canonical_positive_int over
# the existing parse_nonneg_int / MAX_SAFE_INT machinery — no host arithmetic
# on hostile input.
#
# Mutation reachability notes (exact equality + dual independent validators):
# 1. Row-only safe-range bypass on an exact-match overflow fixture: the URL
#    safe-range check still rejects, so STALE/release cannot fire. Behavioral
#    teeth come from the *row* diagnostic ("PR number is noncanonical/unsafe")
#    which disappears under that mutation, plus the source tripwire that the
#    inventory path still calls parse_canonical_positive_int on the row field.
# 2. URL-only safe-range bypass: exact-match overflow is unreachable for a
#    URL-specific diagnostic (row rejects first). The mismatch-shaped fixture
#    (safe row + overflow URL) gives that mutation behavioral teeth: production
#    names "pull number is noncanonical/unsafe"; bypassing only the URL range
#    check degrades to a generic pull-number mismatch.
# 3. Both safe-range checks bypassed (shape-only [1-9][0-9]*): the exact-match
#    64-digit fixture becomes STALE and invokes the release spy — suite fails.
echo "#153 r11 · 64-digit overflow PR identity (exact row/URL match) is rejected"
# 64-digit positive decimal — length > MAX_SAFE_INT (19 digits), so out of
# safe range even though it matches ^[1-9][0-9]*$.
OVERFLOW64="1234567890123456789012345678901234567890123456789012345678901234"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<READER
#!/usr/bin/env bash
case "\${1:-}" in
  list)
    printf '%s\tissue-64-overflow\tlib/**\tfeat/64-overflow\thttps://github.com/acme/app/pull/%s\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n' \\
      '$OVERFLOW64' '$OVERFLOW64'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "64-digit overflow PR identity exits nonzero" \
  || bad "64-digit overflow PR identity was accepted (exit 0): $out"
# Row-field diagnostic specifically. Softening only the row safe-range check
# (keeping shape) makes the URL range check reject instead — this assertion
# fails under that independent mutation even though STALE still cannot fire.
contains "64-digit overflow names row noncanonical/unsafe" "$out" \
  "PR number is noncanonical/unsafe"
contains "64-digit overflow names the hostile row number" "$out" "$OVERFLOW64"
contains "64-digit overflow names safe-range contract" "$out" "safe range"
lacks    "64-digit overflow is not classified STALE" "$out" "STALE PR #"
lacks    "64-digit overflow is not nothing to reap" "$out" "nothing to reap"
lacks    "64-digit overflow is not protected as live" "$out" "is protected"
lacks    "64-digit overflow is not planned REAP" "$out" "REAP   issue-64-overflow"
check    "64-digit overflow never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"
check    "64-digit overflow never wrote a journal entry" \
  "$(grep -c . "$state/journal.md" 2>/dev/null || true)" "0"

echo "#153 r11 · just-over-boundary PR identity (MAX_SAFE_INT+1 exact match) is rejected"
# MAX_SAFE_INT is 9223372036854775807; +1 is still 19 digits and matches
# ^[1-9][0-9]*$ but fails the lexical safe-range compare. No shell arithmetic
# on this value anywhere in the fixture or production path.
# Claim id is a valid issue-bound identity (issue-8-over-bound) so this fixture
# rejects solely on the PR-number safe-range contract — not a malformed claim id.
OVER_BOUND="9223372036854775808"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<READER
#!/usr/bin/env bash
case "\${1:-}" in
  list)
    printf '%s\tissue-8-over-bound\tlib/**\tfeat/8-over-bound\thttps://github.com/acme/app/pull/%s\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n' \\
      '$OVER_BOUND' '$OVER_BOUND'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "just-over-boundary PR identity exits nonzero" \
  || bad "just-over-boundary PR identity was accepted (exit 0): $out"
contains "just-over-boundary names row noncanonical/unsafe" "$out" \
  "PR number is noncanonical/unsafe"
contains "just-over-boundary names the hostile row number" "$out" "$OVER_BOUND"
contains "just-over-boundary names safe-range contract" "$out" "safe range"
lacks    "just-over-boundary is not classified STALE" "$out" "STALE PR #"
lacks    "just-over-boundary is not nothing to reap" "$out" "nothing to reap"
check    "just-over-boundary never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"
check    "just-over-boundary never wrote a journal entry" \
  "$(grep -c . "$state/journal.md" 2>/dev/null || true)" "0"

echo "#153 r11 · safe row + overflow URL is rejected via independent URL path"
# Mismatch-shaped hostile fixture for URL safe-range mutation teeth: row is
# boundary-safe so the row validator cannot reject first. Only the independent
# URL /pull/N safe-range parse rejects. Restoring URL validation to shape-only
# ([1-9][0-9]* without safe range) while leaving the row validator strict
# changes the diagnostic to a pull-number *mismatch* — this fixture gives that
# independent URL mutation behavioral teeth. (A pure same-shaped overflow/overflow
# URL-only mutation is unreachable: the earlier row check necessarily rejects
# first; see source tripwire below.)
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    printf '7\tissue-7-url-overflow\tlib/**\tfeat/7-url-overflow\thttps://github.com/acme/app/pull/9223372036854775808\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "safe-row + overflow URL exits nonzero" \
  || bad "safe-row + overflow URL was accepted (exit 0): $out"
# URL-path diagnostic specifically (not a generic row/URL number mismatch).
contains "safe-row + overflow URL names noncanonical/unsafe URL pull" "$out" \
  "pull number is noncanonical/unsafe"
contains "safe-row + overflow URL names safe-range contract" "$out" "safe range"
lacks    "safe-row + overflow URL is not a mere number mismatch" "$out" \
  "does not match row PR number"
lacks    "safe-row + overflow URL is not classified STALE" "$out" "STALE PR #"
lacks    "safe-row + overflow URL is not nothing to reap" "$out" "nothing to reap"
check    "safe-row + overflow URL never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"

echo "#153 r11 · boundary-safe PR identity (MAX_SAFE_INT) remains accepted and protected"
# MAX_SAFE_INT itself must remain accepted as inventory identity. Represented
# only as a string literal — no shell arithmetic on the PR number. Open PR
# rows are protected (never reaped) regardless of age.
MAX_SAFE="9223372036854775807"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<READER
#!/usr/bin/env bash
case "\${1:-}" in
  list)
    printf '%s\tissue-%s-stale\tlib/**\tfeat/max-safe-stale\thttps://github.com/acme/app/pull/%s\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n' \\
      '$MAX_SAFE' '$MAX_SAFE' '$MAX_SAFE'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
check    "boundary-safe MAX_SAFE_INT PR is accepted (exit 0)" "$rc" "0"
contains "boundary-safe MAX_SAFE_INT open PR is protected" "$out" \
  "PR #${MAX_SAFE} claim issue-${MAX_SAFE}-stale is protected (open PR always protects)"
lacks    "boundary-safe open PR is never STALE" "$out" "STALE PR #"
check    "boundary-safe open PR never invoked release under --apply" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"

# Source-contract tripwires: dual independent shape + safe-range requirements.
# Same-shaped 0999/0999 or overflow/overflow URL-only mutations are unreachable
# for STALE/release assertions (row check fires first); the mismatch-shaped
# fixtures above cover URL mutation behaviorally. These greps keep the dual
# source invariant explicit for both shape and safe-range layers.
if grep -qF '/pull/([1-9][0-9]*)$' "$REAPER"; then
  ok "source contract: URL pull capture requires positive canonical decimal"
else
  bad "source contract: URL pull capture no longer requires ([1-9][0-9]*) (check $REAPER)"
fi
if grep -qF '^[1-9][0-9]*$' "$REAPER"; then
  ok "source contract: row PR number requires positive canonical decimal"
else
  bad "source contract: row PR number no longer requires ^[1-9][0-9]*$"
fi
if grep -q 'parse_canonical_positive_int' "$REAPER"; then
  ok "source contract: parse_canonical_positive_int helper is present"
else
  bad "source contract: parse_canonical_positive_int helper missing (check $REAPER)"
fi
# Both the row field and the captured URL component must call the helper
# independently (two call sites in the inventory validator, not only the def).
_call_sites=$(grep -c 'parse_canonical_positive_int "' "$REAPER" || true)
if [[ "$_call_sites" -ge 2 ]]; then
  ok "source contract: parse_canonical_positive_int called ≥2 times (row + URL)"
else
  bad "source contract: parse_canonical_positive_int call sites = ${_call_sites} (want ≥2 for row+URL)"
fi
unset _call_sites

# ===========================================================================
# #153 open-PR-always-protects P1 — sensors + mutation receipt
# ===========================================================================
echo "#153 open-PR-always-protects · old open PR yields protected, zero release-spy, zero journal, zero handoff"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    # Very old updatedAt relative to STALE_NOW — age alone used to license REAP.
    printf '55\tissue-55-parked\tlib/**\tfeat/55-parked\thttps://github.com/acme/app/pull/55\t2020-01-01T00:00:00Z\t2020-01-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
check    "old open PR protect exits 0" "$rc" "0"
contains "old open PR names protected contract" "$out" "open PR always protects"
contains "old open PR names the claim" "$out" "issue-55-parked"
lacks    "old open PR is never STALE" "$out" "STALE PR #"
check    "old open PR zero release-spy calls" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"
if [[ -s "$state/journal.md" ]] && grep -qE 'issue-55-parked|REAP|COMPLETED' "$state/journal.md" 2>/dev/null; then
  bad "old open PR protection mutated journal: $(cat "$state/journal.md")"
else
  ok "old open PR protection: zero journal mutation"
fi
lacks    "old open PR zero handoff comment" "$out" "claim-reaper released"

echo "#153 open-PR-always-protects · mutation: restoring age-based STALE dispatch makes the sensor fail"
# Mutate the sibling reaper copy only — never the real tree. Replace the
# always-protect tail with the pre-fix age-based STALE + release path.
_reaper_copy="$ROOT/malinv/scripts/claim-reaper.sh"
cp "$REAPER" "$_reaper_copy"
_mut_tmp="$_reaper_copy.mut"
# Marker lines that bookend the always-protect body (unique in production).
_start_pat='# Open PR-body claim: always protect. Never call release-claim.sh.'
_end_pat='info "PR #$pr_number claim $pr_id is protected (open PR always protects)"'
{
  # Emit everything before the protect body.
  awk -v start="$_start_pat" '
    index($0, start) { exit }
    { print }
  ' "$_reaper_copy"
  # Defect restored: age-based STALE dispatch (exact pre-fix behaviour).
  # Reads timestamps from the already-validated row (production no longer
  # binds them because open PRs never age out).
  cat <<'DEFECT'
    # MUTATED DEFECT: age-based STALE dispatch for open PR rows
    pr_created=$(cut -f6 <<<"$_pr_line")
    pr_updated=$(cut -f7 <<<"$_pr_line")
    stamp="$pr_updated"
    [[ -n "$stamp" ]] || stamp="$pr_created"
    epoch=$(date -u -d "$stamp" +%s 2>/dev/null ||
      date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$stamp" +%s 2>/dev/null || echo "")
    if [[ -z "$epoch" || ! "$epoch" =~ ^[0-9]+$ ]]; then
      warn "refusing PR #$pr_number claim '$pr_id' with unreadable activity timestamp"
      continue
    fi
    age=$((NOW - epoch))
    if [[ "$age" -lt "$STALE_SECONDS" ]]; then
      info "PR #$pr_number claim $pr_id is protected (activity ${age}s ago)"
      continue
    fi
    info "STALE PR #$pr_number claim $pr_id (activity ${age}s ago)"
    if [[ "$APPLY" -eq 1 ]]; then
      pr_issue=""
      if [[ "$pr_id" =~ ^issue-([0-9]+)- ]]; then pr_issue="${BASH_REMATCH[1]}"; fi
      if [[ -n "$pr_issue" ]]; then
        "$RELEASE_CMD" "$pr_issue" --claim-id "$pr_id" --repo "$PR_REPO" \
          --keep-branch --keep-worktree
      fi
    fi
    continue
DEFECT
  # Emit everything after the protect info line.
  awk -v end="$_end_pat" '
    seen { print; next }
    index($0, end) { seen=1; next }
  ' "$_reaper_copy"
} > "$_mut_tmp"
mv "$_mut_tmp" "$_reaper_copy"
chmod +x "$_reaper_copy"
: > "$ROOT/malinv/spy.log"
: > "$state/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
# With the defect restored, the old open row must be classified STALE and
# release-spy must fire — proving the committed sensor would go red.
if echo "$out" | grep -F 'STALE PR #55 claim issue-55-parked' >/dev/null && \
   [[ "$(grep -c RELEASE_INVOKED "$ROOT/malinv/spy.log" 2>/dev/null || echo 0)" -ge 1 ]]; then
  ok "mutation receipt: restoring age-based STALE reaps the open PR (sensor would fail)"
else
  bad "mutation receipt: defect restore did not re-enable STALE reaping: out=$out spy=$(cat "$ROOT/malinv/spy.log" 2>/dev/null)"
fi
# Restore production protect behaviour in the copy and re-green.
install_sibling_reaper "$ROOT/malinv/scripts"
: > "$ROOT/malinv/spy.log"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
contains "re-green: open PR protected again" "$out" "open PR always protects"
check    "re-green: zero release-spy" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"
unset _reaper_copy _mut_tmp _start_pat _end_pat

echo "#153 open-PR-always-protects · namespaced open PR id is protected (not malformed)"
cat > "$ROOT/malinv/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    printf '66\tissue-template-66-ns\tlib/**\tfeat/template-66-ns\thttps://github.com/acme/app/pull/66\t2020-01-01T00:00:00Z\t2020-01-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/malinv/scripts/pr-claims.sh"
: > "$ROOT/malinv/spy.log"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/malinv/canon" \
  GIBSON_REAPER_STATE_DIR="$state" \
  GIBSON_REAPER_JOURNAL="$state/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_release" \
  SPY_LOG="$ROOT/malinv/spy.log" \
    "$ROOT/malinv/scripts/claim-reaper.sh" --repo acme/app --apply 2>&1
)
rc=$?
check    "namespaced open PR exits 0" "$rc" "0"
contains "namespaced open PR is protected" "$out" \
  "PR #66 claim issue-template-66-ns is protected (open PR always protects)"
lacks    "namespaced open PR is not refused as malformed" "$out" "refusing malformed PR claim id"
check    "namespaced open PR zero release-spy" \
  "$(grep -c . "$ROOT/malinv/spy.log" 2>/dev/null || true)" "0"

# ===========================================================================
# #153 exact-head P1 — pre-dispatch fresh inventory revalidation
# ===========================================================================
echo "#153 exact-head · same-ID open PR appearing after planning blocks release"
# Force a valid same-ID open PR to appear AFTER startup inventory/planning
# and after the branch-specific open_pr_status check, but BEFORE release
# dispatch. Assert release spy never called and no journal success/handoff.
new_repo "$ROOT/appear"
add_claim_file "$ROOT/appear" issue-850-appear 850 "$CLAIMED_ISO"
install_sibling_reaper "$ROOT/appear/scripts"
# pr-claims list: empty on first call (planning), same-ID open row on later calls
# (pre-dispatch revalidation).
cat > "$ROOT/appear/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
CNT_FILE="${APPEAR_CNT:-/tmp/appear.count}"
case "${1:-}" in
  list)
    n=0
    [[ -f "$CNT_FILE" ]] && n=$(cat "$CNT_FILE" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$CNT_FILE"
    if [[ "$n" -le 1 ]]; then
      # Startup inventory: empty — ledger claim will plan as REAP.
      exit 0
    fi
    # Pre-dispatch revalidation: same-ID open PR appears.
    printf '850\tissue-850-appear\tlib/**\tfeat/850-appear\thttps://github.com/acme/app/pull/850\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/appear/scripts/pr-claims.sh"
spy_appear="$ROOT/appear/spy-release.sh"
cat > "$spy_appear" <<'SPY'
#!/usr/bin/env bash
printf 'RELEASE_INVOKED %s\n' "$*" >> "${SPY_LOG:-/dev/null}"
exit 0
SPY
chmod +x "$spy_appear"
: > "$ROOT/appear/spy.log"
: > "$ROOT/appear/appear.count"
state_ap="$STATE_BASE/appear"
mkdir -p "$state_ap"
: > "$state_ap/journal.md"
export GH_PR_COUNT=0
out=$(
  PATH="$BIN:$PATH" \
  APPEAR_CNT="$ROOT/appear/appear.count" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/appear/canon" \
  GIBSON_REAPER_STATE_DIR="$state_ap" \
  GIBSON_REAPER_JOURNAL="$state_ap/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_ap/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_appear" \
  SPY_LOG="$ROOT/appear/spy.log" \
    "$ROOT/appear/scripts/claim-reaper.sh" --repo acme/app --claim-id issue-850-appear --apply 2>&1
)
rc=$?
# Incomplete (exit 3) or nonzero is fine; success (0) with release is not.
[[ "$rc" -ne 0 ]] && ok "appear-after-plan refuses/incomplete (rc=$rc)" \
  || {
    # rc=0 only OK if release spy never fired and claim still live
    if [[ "$(grep -c RELEASE_INVOKED "$ROOT/appear/spy.log" 2>/dev/null || echo 0)" -eq 0 ]]; then
      ok "appear-after-plan rc=0 with zero release (protected)"
    else
      bad "appear-after-plan rc=0 but release spy fired"
    fi
  }
contains "appear-after-plan names fresh protect" "$out" "fresh open-PR inventory protects"
_spy_n=$(grep -c RELEASE_INVOKED "$ROOT/appear/spy.log" 2>/dev/null || true)
_spy_n=${_spy_n:-0}
check "appear-after-plan zero release-spy" "$_spy_n" "0"
if [[ -s "$state_ap/journal.md" ]] && grep -qE 'COMPLETED|claim_released=1' "$state_ap/journal.md" 2>/dev/null; then
  bad "appear-after-plan journal has success/handoff: $(cat "$state_ap/journal.md")"
else
  ok "appear-after-plan: no journal success/handoff"
fi
files=$(git -C "$ROOT/appear/canon" fetch -q origin; git -C "$ROOT/appear/canon" ls-tree --name-only origin/main docs/claims/)
contains "appear-after-plan ledger preserved" "$files" "issue-850-appear.md"
lacks "appear-after-plan no handoff comment" "$out" "claim-reaper released"

echo "#153 exact-head · mutation: removing pre-dispatch revalidation reaps appeared PR"
# Mutate sibling reaper: make fresh_open_pr_inventory_protect always succeed.
_reaper_ap="$ROOT/appear/scripts/claim-reaper.sh"
install_sibling_reaper "$ROOT/appear/scripts"
# Insert an early return 0 at the top of the protect function body.
perl -i -pe 's/^(fresh_open_pr_inventory_protect\(\) \{)/$1\n  return 0 # MUTATED always-allow/' "$_reaper_ap"
if grep -q 'MUTATED always-allow' "$_reaper_ap"; then
  ok "appear mutation: pre-dispatch revalidation neutralized"
else
  bad "appear mutation: failed to neutralize pre-dispatch revalidation"
fi
: > "$ROOT/appear/spy.log"
: > "$ROOT/appear/appear.count"
: > "$state_ap/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  APPEAR_CNT="$ROOT/appear/appear.count" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/appear/canon" \
  GIBSON_REAPER_STATE_DIR="$state_ap" \
  GIBSON_REAPER_JOURNAL="$state_ap/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_ap/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_appear" \
  SPY_LOG="$ROOT/appear/spy.log" \
    "$_reaper_ap" --repo acme/app --claim-id issue-850-appear --apply 2>&1
)
_spy_n=$(grep -c RELEASE_INVOKED "$ROOT/appear/spy.log" 2>/dev/null || true)
_spy_n=${_spy_n:-0}
if [[ "$_spy_n" -ge 1 ]]; then
  ok "mutation receipt: removing fresh revalidation dispatches release (sensor would fail)"
else
  bad "mutation receipt: neutralizing revalidation did not re-enable release: out=$out spy=$(cat "$ROOT/appear/spy.log" 2>/dev/null)"
fi
# Restore production reaper copy for hygiene.
install_sibling_reaper "$ROOT/appear/scripts"

echo "#153 exact-head · mixed file+legacy same id is REFUSE (not deduped)"
new_repo "$ROOT/mixrep"
(
  cd "$ROOT/mixrep/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  printf 'claim: issue-860-mix\nissue: 860\nclaimed: %s\nscope: src/x\nsession: a\nbranch: feat/860-mix\n' \
    "$CLAIMED_ISO" > docs/claims/issue-860-mix.md
  cat > docs/active-work.md <<TABLE
| when | claim-id | scope | who |
|---|---|---|---|
| 2026-08-01 | issue-860-mix | src/x | session:a |
TABLE
  git add -A && git commit -qm "mixed reps" && git push -q origin main
) >/dev/null 2>&1
export GH_PR_COUNT=0
out=$(
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  run_reaper "$ROOT/mixrep/canon" --claim-id issue-860-mix 2>&1
)
rc=$?
check "mixed reps dry-run exits 0" "$rc" "0"
contains "mixed reps REFUSE in plan" "$out" "REFUSE"
contains "mixed reps names reason" "$out" "mixed_ledger_representations"
lacks "mixed reps never REAP" "$out" "REAP   issue-860-mix"
# Apply must not call release.
spy_mix="$ROOT/mixrep/spy.sh"
cat > "$spy_mix" <<'SPY'
#!/usr/bin/env bash
printf 'RELEASE_INVOKED\n' >> "${SPY_LOG:-/dev/null}"
exit 0
SPY
chmod +x "$spy_mix"
: > "$ROOT/mixrep/spy.log"
state_mx="$STATE_BASE/mixrep"
mkdir -p "$state_mx"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/mixrep/canon" \
  GIBSON_REAPER_STATE_DIR="$state_mx" \
  GIBSON_REAPER_JOURNAL="$state_mx/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_mx/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_mix" \
  SPY_LOG="$ROOT/mixrep/spy.log" \
    "$REAPER" --repo acme/app --claim-id issue-860-mix --apply 2>&1
)
check "mixed reps apply zero release-spy" \
  "$(grep -c . "$ROOT/mixrep/spy.log" 2>/dev/null || true)" "0"
files=$(git -C "$ROOT/mixrep/canon" fetch -q origin; git -C "$ROOT/mixrep/canon" ls-tree --name-only origin/main docs/claims/)
contains "mixed reps file preserved" "$files" "issue-860-mix.md"
table=$(git -C "$ROOT/mixrep/canon" show origin/main:docs/active-work.md)
contains "mixed reps legacy preserved" "$table" "issue-860-mix"

echo "#153 exact-head · mutation: neutralizing mixed_ledger_representations guard"
# Mutate reaper copy: skip the mixed-representation refuse block entirely so
# both file+legacy rows remain plannable (pre-fix silent survival of dual
# rows → REAP of the file representation). Prove the mutation applied, then
# require REAP (sensor would go red).
install_sibling_reaper "$ROOT/mixmutr"
# Sibling empty pr-claims so SCRIPT_DIR resolution succeeds (no live open PRs).
cat > "$ROOT/mixmutr/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in list|list-open-numbers) exit 0 ;; *) exit 64 ;; esac
READER
chmod +x "$ROOT/mixmutr/pr-claims.sh"
# Gate the mixed block on `false &&` so it never runs.
perl -i -pe 's/if \[\[ -s "\$\{MIX_IDS_TMP\}\.file" && -s "\$\{MIX_IDS_TMP\}\.leg" \]\]; then/if false \&\& [[ -s "\${MIX_IDS_TMP}.file" \&\& -s "\${MIX_IDS_TMP}.leg" ]]; then # MUTATED skip mixed refuse/' \
  "$ROOT/mixmutr/claim-reaper.sh"
if grep -q 'MUTATED skip mixed refuse' "$ROOT/mixmutr/claim-reaper.sh"; then
  ok "mixed mutation: mixed refuse block gated off"
else
  bad "mixed mutation: failed to gate off mixed refuse block"
fi
out2=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/mixrep/canon" \
  GIBSON_REAPER_STATE_DIR="$STATE_BASE/mixmutr2" \
  GIBSON_REAPER_JOURNAL="$STATE_BASE/mixmutr2/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$STATE_BASE/mixmutr2/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_mix" \
    "$ROOT/mixmutr/claim-reaper.sh" --repo acme/app --claim-id issue-860-mix 2>&1
)
if echo "$out2" | grep 'mixed_ledger_representations' >/dev/null; then
  bad "mutation receipt: mixed REFUSE still present after skip: $out2"
elif echo "$out2" | grep 'REAP   issue-860-mix' >/dev/null; then
  ok "mutation receipt: skipping mixed guard plans REAP (sensor would fail)"
else
  bad "mutation receipt: skipping mixed guard did not re-enable REAP: $out2"
fi

# ===========================================================================
# #153 exact-head P2 — never declare empty ledger from local HEAD
# ===========================================================================
echo "#153 exact-head · local HEAD empty while origin/main has stale claim"
new_repo "$ROOT/lochead"
add_claim_file "$ROOT/lochead" issue-870-remote-only 870 "$CLAIMED_ISO"
(
  cd "$ROOT/lochead/canon" || exit 1
  # Detach to a feature commit that has NO docs/claims or active-work —
  # local HEAD looks empty, but origin/main still holds the claim.
  git checkout -q --orphan empty-feature
  git rm -rf --cached . >/dev/null 2>&1 || true
  rm -rf docs
  echo "feature only" > feature.txt
  git add feature.txt
  git commit -qm "feature without claims tree"
  # Stay on empty-feature so HEAD lacks docs/claims.
) >/dev/null 2>&1
export GH_PR_COUNT=0
out=$(
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  run_reaper "$ROOT/lochead/canon" --claim-id issue-870-remote-only 2>&1
)
rc=$?
check "local-empty-HEAD dry-run exits 0" "$rc" "0"
contains "local-empty-HEAD inventories remote claim" "$out" "issue-870-remote-only"
lacks "local-empty-HEAD never nothing-to-reap from HEAD" "$out" "nothing to reap"
# Must REAP or at least plan the remote claim, not exit early as empty.
if echo "$out" | grep -E 'REAP   issue-870-remote-only|KEEP   issue-870-remote-only|REFUSE   issue-870-remote-only' >/dev/null; then
  ok "local-empty-HEAD plans the remote claim (not empty from HEAD)"
else
  bad "local-empty-HEAD did not inventory remote claim: $out"
fi

echo "#153 exact-head · fetch failure is nonzero with zero mutation"
new_repo "$ROOT/fetchz"
add_claim_file "$ROOT/fetchz" issue-880-fetchz 880 "$CLAIMED_ISO"
GIT_REAL=$(command -v git)
mkdir -p "$ROOT/fetchz/bin"
cat > "$ROOT/fetchz/bin/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "fetch" ]]; then
  echo "simulated fetch failure" >&2
  exit 128
fi
exec "$GIT_REAL" "\$@"
EOF
chmod +x "$ROOT/fetchz/bin/git"
out=$(
  PATH="$ROOT/fetchz/bin:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/fetchz/canon" \
    "$REAPER" --repo acme/app --claim-id issue-880-fetchz --apply 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "fetch failure exits nonzero" || bad "fetch failure exited 0: $out"
contains "fetch failure names refuse" "$out" "cannot fetch"
files=$(PATH="/usr/bin:/bin:$PATH" git -C "$ROOT/fetchz/canon" fetch -q origin 2>/dev/null
  PATH="/usr/bin:/bin:$PATH" git -C "$ROOT/fetchz/canon" ls-tree --name-only origin/main docs/claims/)
contains "fetch failure ledger preserved" "$files" "issue-880-fetchz.md"

# ===========================================================================
# #153 CodeRabbit exact-head repair — stderr, origin fallback, comm fail-closed
# ===========================================================================
echo "#153 CodeRabbit · benign successful stderr does not poison inventory stdout"
# pr-claims.sh list exits 0 with a well-formed row on stdout and a warning on
# stderr. Merging 2>&1 would make the inventory look malformed; separate
# capture (shared stream-capture helper) must keep the row valid and protect
# the open claim. Do not weaken this sensor.
new_repo "$ROOT/benign"
install_sibling_reaper "$ROOT/benign/scripts"
cat > "$ROOT/benign/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    echo "gh: notice: GraphQL deprecation warning (benign)" >&2
    printf '7\tissue-7-live\tlib/**\tfeat/7-live\thttps://github.com/acme/app/pull/7\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/benign/scripts/pr-claims.sh"
state_bn="$STATE_BASE/benign"
mkdir -p "$state_bn"
: > "$state_bn/journal.md"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$FRESH_NOW" \
  GIBSON_CANONICAL="$ROOT/benign/canon" \
  GIBSON_REAPER_STATE_DIR="$state_bn" \
  GIBSON_REAPER_JOURNAL="$state_bn/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_bn/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$ROOT/benign/scripts/claim-reaper.sh" --repo acme/app 2>&1
)
rc=$?
check "benign stderr inventory exits 0" "$rc" "0"
contains "benign stderr row is protected" "$out" "issue-7-live"
lacks "benign stderr is not malformed refuse" "$out" "malformed/truncated row"
lacks "benign stderr is not unreadable refuse" "$out" "unreadable"

echo "#153 CodeRabbit · origin-fallback PR_REPO reaches fresh pre-dispatch protect"
# When `gh repo view` fails, identity still resolves from exactly one GitHub
# origin URL. That same identity must drive startup inventory, pre-dispatch
# protect, and release-claim --repo (never drop origin into "repo unresolved").
new_repo "$ROOT/origfb"
add_claim_file "$ROOT/origfb" issue-890-origfb 890 "$CLAIMED_ISO"
# Bind a GitHub identity on origin while still using the local bare for transport.
git -C "$ROOT/origfb/canon" config "url.$ROOT/origfb/origin.insteadOf" https://github.com/acme/app.git
git -C "$ROOT/origfb/canon" remote set-url origin https://github.com/acme/app.git
mkdir -p "$ROOT/origfb/bin"
install_sibling_reaper "$ROOT/origfb/scripts"
# pr-claims: empty on first call (plan REAP); same-id open PR on later calls.
# Also log the repo argument so we prove origin-fallback identity was used.
: > "$ROOT/origfb/list-repos.log"
cat > "$ROOT/origfb/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
CNT_FILE="${ORIGFB_CNT:-/tmp/origfb.count}"
LOG_FILE="${ORIGFB_LOG:-/tmp/origfb.repos}"
case "${1:-}" in
  list)
    printf '%s\n' "${2:-}" >> "$LOG_FILE"
    n=0
    [[ -f "$CNT_FILE" ]] && n=$(cat "$CNT_FILE" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$CNT_FILE"
    if [[ "$n" -le 1 ]]; then
      exit 0
    fi
    printf '890\tissue-890-origfb\tlib/**\tfeat/890-origfb\thttps://github.com/acme/app/pull/890\t2026-08-01T00:00:00Z\t2026-08-01T00:00:00Z\tfalse\n'
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/origfb/scripts/pr-claims.sh"
# gh: repo view fails; pr list still succeeds with 0 open (branch-specific check).
cat > "$ROOT/origfb/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  repo)
    echo "simulated gh repo view failure" >&2
    exit 1
    ;;
  pr)
    echo "0"
    exit 0
    ;;
  api)
    if [[ "${2:-}" == "graphql" ]]; then
      exit 0
    fi
    exit 1
    ;;
  issue)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
GH
chmod +x "$ROOT/origfb/bin/gh"
spy_of="$ROOT/origfb/spy-release.sh"
cat > "$spy_of" <<'SPY'
#!/usr/bin/env bash
printf 'RELEASE_INVOKED %s\n' "$*" >> "${SPY_LOG:-/dev/null}"
exit 0
SPY
chmod +x "$spy_of"
: > "$ROOT/origfb/spy.log"
: > "$ROOT/origfb/origfb.count"
: > "$ROOT/origfb/list-repos.log"
state_of="$STATE_BASE/origfb"
mkdir -p "$state_of"
: > "$state_of/journal.md"
out=$(
  PATH="$ROOT/origfb/bin:$BIN:$PATH" \
  ORIGFB_CNT="$ROOT/origfb/origfb.count" \
  ORIGFB_LOG="$ROOT/origfb/list-repos.log" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/origfb/canon" \
  GIBSON_REAPER_STATE_DIR="$state_of" \
  GIBSON_REAPER_JOURNAL="$state_of/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_of/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_of" \
  SPY_LOG="$ROOT/origfb/spy.log" \
    "$ROOT/origfb/scripts/claim-reaper.sh" --claim-id issue-890-origfb --apply 2>&1
)
rc=$?
# Exact protected claim/reason — not the generic "fresh open-PR inventory protects"
# prefix that also covers "repo unresolved".
contains "origin-fallback exact claim protect" "$out" \
  "carries exact claim id 'issue-890-origfb'"
[[ "$rc" -ne 0 ]] && ok "origin-fallback incomplete/nonzero (rc=$rc)" \
  || bad "origin-fallback exited 0 after protect: $out"
if grep -qxF 'acme/app' "$ROOT/origfb/list-repos.log"; then
  ok "origin-fallback list was called with acme/app"
else
  bad "origin-fallback list never saw acme/app: $(cat "$ROOT/origfb/list-repos.log")"
fi
# Must not have been called with an empty repo identity.
if grep -qxF '' "$ROOT/origfb/list-repos.log"; then
  bad "origin-fallback list was called with empty repo identity"
else
  ok "origin-fallback list never saw empty repo identity"
fi
_spy_n=$(grep -c RELEASE_INVOKED "$ROOT/origfb/spy.log" 2>/dev/null || true)
_spy_n=${_spy_n:-0}
check "origin-fallback zero release-spy" "$_spy_n" "0"
files=$(git -C "$ROOT/origfb/canon" fetch -q origin 2>/dev/null
  git -C "$ROOT/origfb/canon" ls-tree --name-only origin/main docs/claims/)
contains "origin-fallback ledger preserved" "$files" "issue-890-origfb.md"

echo "#153 follow-up · ambiguous multi-valued origin leaves identity unresolved"
# `git config --get remote.origin.url` returns the LAST value when several
# exist. Two different GitHub origins + failing gh must leave identity
# unresolved: no release dispatch, claim/ledger preserved.
new_repo "$ROOT/ambig"
add_claim_file "$ROOT/ambig" issue-891-ambig 891 "$CLAIMED_ISO"
# Keep transport hermetic via insteadOf for BOTH GitHub URLs, but configure two
# distinct remote.origin.url values so identity is ambiguous (--get-all).
git -C "$ROOT/ambig/canon" config "url.$ROOT/ambig/origin.insteadOf" https://github.com/acme/app.git
git -C "$ROOT/ambig/canon" config --add "url.$ROOT/ambig/origin.insteadOf" https://github.com/other/app.git
git -C "$ROOT/ambig/canon" remote set-url origin https://github.com/acme/app.git
git -C "$ROOT/ambig/canon" config --add remote.origin.url https://github.com/other/app.git
# Prove two origin values exist (fixture integrity).
_ambig_n=$(git -C "$ROOT/ambig/canon" config --get-all remote.origin.url 2>/dev/null | grep -c . || true)
[[ "$_ambig_n" -eq 2 ]] && ok "ambiguous-origin fixture has two origin URLs" \
  || bad "ambiguous-origin fixture origin count=$_ambig_n"
mkdir -p "$ROOT/ambig/bin"
install_sibling_reaper "$ROOT/ambig/scripts"
: > "$ROOT/ambig/list-repos.log"
cat > "$ROOT/ambig/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
LOG_FILE="${AMBIG_LOG:-/tmp/ambig.repos}"
case "${1:-}" in
  list)
    printf '%s\n' "${2:-}" >> "$LOG_FILE"
    # Empty inventory so a wrongly-resolved identity would still plan REAP
    # of the ledger claim — dispatch must still be blocked.
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
chmod +x "$ROOT/ambig/scripts/pr-claims.sh"
cat > "$ROOT/ambig/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  repo)
    echo "simulated gh repo view failure" >&2
    exit 1
    ;;
  pr)
    echo "0"
    exit 0
    ;;
  api)
    if [[ "${2:-}" == "graphql" ]]; then
      exit 0
    fi
    exit 1
    ;;
  issue)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
GH
chmod +x "$ROOT/ambig/bin/gh"
spy_am="$ROOT/ambig/spy-release.sh"
cat > "$spy_am" <<'SPY'
#!/usr/bin/env bash
printf 'RELEASE_INVOKED %s\n' "$*" >> "${SPY_LOG:-/dev/null}"
exit 0
SPY
chmod +x "$spy_am"
: > "$ROOT/ambig/spy.log"
state_am="$STATE_BASE/ambig"
mkdir -p "$state_am"
: > "$state_am/journal.md"
out=$(
  PATH="$ROOT/ambig/bin:$BIN:$PATH" \
  AMBIG_LOG="$ROOT/ambig/list-repos.log" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/ambig/canon" \
  GIBSON_REAPER_STATE_DIR="$state_am" \
  GIBSON_REAPER_JOURNAL="$state_am/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_am/lock" \
  GIBSON_REAPER_RELEASE_CMD="$spy_am" \
  SPY_LOG="$ROOT/ambig/spy.log" \
    "$ROOT/ambig/scripts/claim-reaper.sh" --claim-id issue-891-ambig --apply 2>&1
)
rc=$?
# Must not invent a single owner/name from multi-valued origin.
if grep -Eqx 'acme/app|other/app' "$ROOT/ambig/list-repos.log" 2>/dev/null; then
  bad "ambiguous-origin invented a repo identity for inventory: $(cat "$ROOT/ambig/list-repos.log")"
else
  ok "ambiguous-origin never called inventory with a resolved identity"
fi
_spy_n=$(grep -c RELEASE_INVOKED "$ROOT/ambig/spy.log" 2>/dev/null || true)
_spy_n=${_spy_n:-0}
check "ambiguous-origin zero release-spy" "$_spy_n" "0"
contains "ambiguous-origin plans explicit repository refusal" "$out" \
  "repo_unresolved_for_pr_check"
[[ "$rc" -ne 0 ]] && ok "ambiguous-origin incomplete/nonzero (rc=$rc)" \
  || {
    # rc=0 only OK if release never fired and ledger still live
    if [[ "$_spy_n" -eq 0 ]]; then
      ok "ambiguous-origin rc=0 with zero release (identity unresolved)"
    else
      bad "ambiguous-origin rc=0 but release spy fired"
    fi
  }
files=$(git -C "$ROOT/ambig/canon" fetch -q origin 2>/dev/null
  git -C "$ROOT/ambig/canon" ls-tree --name-only origin/main docs/claims/)
contains "ambiguous-origin ledger preserved" "$files" "issue-891-ambig.md"
if [[ -s "$state_am/journal.md" ]] && grep -qE 'COMPLETED|claim_released=1' "$state_am/journal.md" 2>/dev/null; then
  bad "ambiguous-origin journal has success/handoff: $(cat "$state_am/journal.md")"
else
  ok "ambiguous-origin: no journal success/handoff"
fi

echo "#153 follow-up · stream-capture helper required (fail closed when missing)"
# Production sources scripts/lib/stream-capture.sh. A sibling copy without the
# helper must refuse rather than hand-roll empty inventory authority.
new_repo "$ROOT/nocap"
add_claim_file "$ROOT/nocap" issue-892-nocap 892 "$CLAIMED_ISO"
mkdir -p "$ROOT/nocap/scripts/lib"
cp "$REAPER" "$ROOT/nocap/scripts/claim-reaper.sh"
chmod +x "$ROOT/nocap/scripts/claim-reaper.sh"
# common.sh is required at startup (#192); omit only stream-capture so the
# fail-closed path under test is still the inventory helper, not need_cmd.
cp "$SCRIPT_DIR/../lib/common.sh" "$ROOT/nocap/scripts/lib/common.sh"
# Intentionally omit lib/stream-capture.sh.
cat > "$ROOT/nocap/scripts/pr-claims.sh" <<'READER'
#!/usr/bin/env bash
case "${1:-}" in list) exit 0 ;; *) exit 64 ;; esac
READER
chmod +x "$ROOT/nocap/scripts/pr-claims.sh"
state_nc="$STATE_BASE/nocap"
mkdir -p "$state_nc"
out=$(
  PATH="$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/nocap/canon" \
  GIBSON_REAPER_STATE_DIR="$state_nc" \
  GIBSON_REAPER_JOURNAL="$state_nc/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_nc/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$ROOT/nocap/scripts/claim-reaper.sh" --repo acme/app --claim-id issue-892-nocap 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "missing stream-capture exits nonzero" \
  || bad "missing stream-capture exited 0: $out"
contains "missing stream-capture names helper" "$out" "stream-capture"
lacks "missing stream-capture never nothing-to-reap" "$out" "nothing to reap"
lacks "missing stream-capture never empty plan" "$out" "summary: reap="
# Static proof production uses the shared helper (not a hand-rolled mktemp path).
if grep -q 'lib/stream-capture.sh' "$REAPER" && \
   grep -q '_rc_capture_streams' "$REAPER" && \
   ! grep -qE 'gibson-reaper-pr-err|gibson-reaper-fresh-err' "$REAPER"; then
  ok "reaper production uses shared stream-capture helper"
else
  bad "reaper production does not bind shared stream-capture helper"
fi

echo "#153 CodeRabbit · comm failure refuse (fail closed, no stale mix output)"
# Mixed file+legacy same id must run comm -12. A failing comm must die rather
# than plan REAP from a missing/stale .both file.
new_repo "$ROOT/commfail"
(
  cd "$ROOT/commfail/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  cat > docs/claims/issue-900-comm.md <<EOF
claim: issue-900-comm
issue: 900
claimed: $CLAIMED_ISO
scope: src/issue-900-comm
session: test@box
branch: feat/900-comm
EOF
  printf '| when | claim-id | scope | who |\n|---|---|---|---|\n' > docs/active-work.md
  printf '| %s | issue-900-comm | src/issue-900-comm | test@box |\n' "$CLAIMED_ISO" >> docs/active-work.md
  git add -A && git commit -qm "mixed reps for comm fail" && git push -q origin main
) >/dev/null 2>&1
mkdir -p "$ROOT/commfail/bin"
COMM_REAL=$(command -v comm)
cat > "$ROOT/commfail/bin/comm" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-12" ]]; then
  echo "simulated comm failure" >&2
  exit 1
fi
exec "$COMM_REAL" "\$@"
EOF
chmod +x "$ROOT/commfail/bin/comm"
out=$(
  PATH="$ROOT/commfail/bin:$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/commfail/canon" \
  GIBSON_REAPER_STATE_DIR="$STATE_BASE/commfail" \
  GIBSON_REAPER_JOURNAL="$STATE_BASE/commfail/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$STATE_BASE/commfail/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$REAPER" --repo acme/app --claim-id issue-900-comm 2>&1
)
rc=$?
[[ "$rc" -ne 0 ]] && ok "comm failure exits nonzero" || bad "comm failure exited 0: $out"
contains "comm failure names refuse" "$out" "comm failed"
lacks "comm failure never REAP" "$out" "REAP   issue-900-comm"
lacks "comm failure not silent nothing-to-reap" "$out" "nothing to reap"

echo "#153 CodeRabbit · docs contract: repository binding, head evidence, mixed refuse, label safety, eight-field TSV"
# Semantic documentation contracts only — not general spelling preferences.
README="$SCRIPT_DIR/../README.md"
if grep -qF 'is_cross_repository — eight fields' "$README" && \
   grep -qF 'is_cross_repository` is eighth after' "$README"; then
  ok "scripts/README.md documents eight-field list TSV"
else
  bad "scripts/README.md missing eight-field list TSV contract"
fi
if grep -qF 'the branch its claim id derives from' "$README"; then
  ok "scripts/README.md head-branch binding includes 'from'"
else
  bad "scripts/README.md head-branch binding missing 'from'"
fi
PLAYBOOK="$SCRIPT_DIR/../../playbooks/release.md"
if grep -qF 'the branch this claim id derives from' "$PLAYBOOK"; then
  ok "playbooks/release.md head-branch binding includes 'from'"
else
  bad "playbooks/release.md head-branch binding missing 'from'"
fi
TROUBLE="$SCRIPT_DIR/../../docs/troubleshooting/claim-conflicts.md"
if grep -qF 'exact released PR number and exact' "$TROUBLE" && \
   grep -qF 'Mixed PR-body + legacy-ledger' "$TROUBLE" && \
   grep -qF 'Manual `agent-claimed` label removal' "$TROUBLE" && \
   grep -qF 'PR-backed claims stay refused' "$TROUBLE"; then
  ok "claim-conflicts.md carries repository/mixed/label/PR refuse contracts"
else
  bad "claim-conflicts.md missing repository/mixed/label/PR refuse contracts"
fi

# ===========================================================================
# #180 · already-absent recovery handoff reuses resolved repository identity
# ===========================================================================
# The early --claim-id already-absent path must consume PR_REPO (resolved with
# --repo / gh / unambiguous origin fallback at startup), not a second gh-only
# resolve_repo pass. Fixtures below seed journal proof
# (claim_released=1 + handoff_comment_failed) with an absent claim and never
# mutate ledger/label/branch/worktree — only the authorized success handoff.

# Shared gh mock for #180: repo view fails; issue comments + comment list work.
# Logs every --repo value seen on issue comment so identity is assertable.
_install_abs180_gh() {
  local dest="$1" comments_file="$2" repo_log="$3"
  mkdir -p "$dest"
  cat > "$dest/gh" <<GH
#!/usr/bin/env bash
case "\$1" in
  repo)
    echo "simulated gh repo view failure" >&2
    exit 1
    ;;
  api)
    if [[ "\${2:-}" == "graphql" ]]; then
      exit 0
    fi
    if [[ "\${2:-}" == repos/* ]]; then
      if [[ -f "${comments_file}" ]]; then
        cat "${comments_file}"
      fi
      exit 0
    fi
    exit 1
    ;;
  issue)
    shift
    if [[ "\${1:-}" == "comment" ]]; then
      # Capture --repo for identity proof.
      prev=""
      for a in "\$@"; do
        if [[ "\$prev" == "--repo" ]]; then
          printf '%s\n' "\$a" >> "${repo_log}"
        fi
        prev="\$a"
      done
      body=""
      prev=""
      for a in "\$@"; do
        if [[ "\$prev" == "--body" ]]; then body="\$a"; fi
        prev="\$a"
      done
      printf '%s\n' "\$body" >> "${comments_file}"
      exit 0
    fi
    exit 1
    ;;
  pr)
    echo "0"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
GH
  chmod +x "$dest/gh"
}

_install_abs180_empty_pr_claims() {
  local dest_dir="$1" log_file="${2:-}"
  mkdir -p "$dest_dir"
  cat > "$dest_dir/pr-claims.sh" <<READER
#!/usr/bin/env bash
case "\${1:-}" in
  list)
    if [[ -n "${log_file}" ]]; then
      printf '%s\n' "\${2:-}" >> "${log_file}"
    fi
    exit 0
    ;;
  *) exit 64 ;;
esac
READER
  chmod +x "$dest_dir/pr-claims.sh"
}

echo "#180 · one-origin fallback completes already-absent recovery handoff"
# gh repo view fails; exactly one GitHub origin supplies PR_REPO. Journal
# proves prior claim_released=1 + handoff_comment_failed. Recovery must post
# the success handoff to that same identity (acme/app) and COMPLETE.
new_repo "$ROOT/abs180one"
# No claim file — already absent. Bind one GitHub origin for identity.
git -C "$ROOT/abs180one/canon" config "url.$ROOT/abs180one/origin.insteadOf" https://github.com/acme/app.git
git -C "$ROOT/abs180one/canon" remote set-url origin https://github.com/acme/app.git
install_sibling_reaper "$ROOT/abs180one/scripts"
: > "$ROOT/abs180one/list-repos.log"
_install_abs180_empty_pr_claims "$ROOT/abs180one/scripts" "$ROOT/abs180one/list-repos.log"
: > "$ROOT/abs180one/comments"
: > "$ROOT/abs180one/comment-repos.log"
mkdir -p "$ROOT/abs180one/bin"
_install_abs180_gh "$ROOT/abs180one/bin" "$ROOT/abs180one/comments" "$ROOT/abs180one/comment-repos.log"
state_a1="$STATE_BASE/abs180one"
mkdir -p "$state_a1"
# Seed Law-8 recovery proof only (no live claim, no release mutation this run).
printf '2026-08-01T00:00:00Z INCOMPLETE op=reap:issue-180-absone:stale reason=handoff_comment_failed claim_released=1\n' \
  > "$state_a1/journal.md"
out=$(
  PATH="$ROOT/abs180one/bin:$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/abs180one/canon" \
  GIBSON_REAPER_STATE_DIR="$state_a1" \
  GIBSON_REAPER_JOURNAL="$state_a1/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_a1/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$ROOT/abs180one/scripts/claim-reaper.sh" --claim-id issue-180-absone --apply 2>&1
)
rc=$?
check "one-origin recovery exits 0" "$rc" "0"
contains "one-origin recovery mentions absent" "$out" "nothing to reap"
contains "one-origin recovery posts handoff" "$out" "handoff"
if grep -qF '<!-- gibson-claim-reaper:issue-180-absone -->' "$ROOT/abs180one/comments" 2>/dev/null; then
  ok "one-origin recovery posted success marker"
else
  bad "one-origin recovery missing success marker: $(cat "$ROOT/abs180one/comments" 2>/dev/null)"
fi
if grep -qxF 'acme/app' "$ROOT/abs180one/comment-repos.log" 2>/dev/null; then
  ok "one-origin recovery commented on acme/app"
else
  bad "one-origin recovery comment --repo log: $(cat "$ROOT/abs180one/comment-repos.log" 2>/dev/null)"
fi
if grep -qxF 'acme/app' "$ROOT/abs180one/list-repos.log" 2>/dev/null; then
  ok "one-origin recovery inventory used acme/app (startup identity)"
else
  bad "one-origin recovery inventory log: $(cat "$ROOT/abs180one/list-repos.log" 2>/dev/null)"
fi
j1=$(cat "$state_a1/journal.md" 2>/dev/null || true)
contains "one-origin recovery journals already_absent COMPLETED" "$j1" "already_absent"
contains "one-origin recovery journals recovery_handoff=1" "$j1" "recovery_handoff=1"
# No claim/ledger mutation possible (claim was never present); assert empty claims tree.
files=$(git -C "$ROOT/abs180one/canon" fetch -q origin 2>/dev/null
  git -C "$ROOT/abs180one/canon" ls-tree --name-only origin/main docs/claims/ 2>/dev/null || true)
lacks "one-origin recovery never invents a claim file" "$files" "issue-180-absone.md"

echo "#180 · ambiguous multi-origin refuses already-absent recovery handoff"
# Two distinct GitHub origins + failing gh → identity unresolved. Recovery
# proof present but must not invent a repo or post a handoff.
new_repo "$ROOT/abs180amb"
git -C "$ROOT/abs180amb/canon" config "url.$ROOT/abs180amb/origin.insteadOf" https://github.com/acme/app.git
git -C "$ROOT/abs180amb/canon" config --add "url.$ROOT/abs180amb/origin.insteadOf" https://github.com/other/app.git
git -C "$ROOT/abs180amb/canon" remote set-url origin https://github.com/acme/app.git
git -C "$ROOT/abs180amb/canon" config --add remote.origin.url https://github.com/other/app.git
_ambig_n=$(git -C "$ROOT/abs180amb/canon" config --get-all remote.origin.url 2>/dev/null | grep -c . || true)
[[ "$_ambig_n" -eq 2 ]] && ok "ambiguous-absent fixture has two origin URLs" \
  || bad "ambiguous-absent fixture origin count=$_ambig_n"
install_sibling_reaper "$ROOT/abs180amb/scripts"
: > "$ROOT/abs180amb/list-repos.log"
_install_abs180_empty_pr_claims "$ROOT/abs180amb/scripts" "$ROOT/abs180amb/list-repos.log"
: > "$ROOT/abs180amb/comments"
: > "$ROOT/abs180amb/comment-repos.log"
mkdir -p "$ROOT/abs180amb/bin"
_install_abs180_gh "$ROOT/abs180amb/bin" "$ROOT/abs180amb/comments" "$ROOT/abs180amb/comment-repos.log"
state_aa="$STATE_BASE/abs180amb"
mkdir -p "$state_aa"
printf '2026-08-01T00:00:00Z INCOMPLETE op=reap:issue-180-absamb:stale reason=handoff_comment_failed claim_released=1\n' \
  > "$state_aa/journal.md"
out=$(
  PATH="$ROOT/abs180amb/bin:$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/abs180amb/canon" \
  GIBSON_REAPER_STATE_DIR="$state_aa" \
  GIBSON_REAPER_JOURNAL="$state_aa/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_aa/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$ROOT/abs180amb/scripts/claim-reaper.sh" --claim-id issue-180-absamb --apply 2>&1
)
rc=$?
check "ambiguous-absent recovery exits incomplete (3)" "$rc" "3"
if grep -Eqx 'acme/app|other/app' "$ROOT/abs180amb/list-repos.log" 2>/dev/null; then
  bad "ambiguous-absent invented inventory identity: $(cat "$ROOT/abs180amb/list-repos.log")"
else
  ok "ambiguous-absent never resolved inventory identity"
fi
if [[ -s "$ROOT/abs180amb/comments" ]] || grep -qF 'gibson-claim-reaper:issue-180-absamb' "$ROOT/abs180amb/comments" 2>/dev/null; then
  bad "ambiguous-absent must not post handoff: $(cat "$ROOT/abs180amb/comments")"
else
  ok "ambiguous-absent posted no handoff comment"
fi
if [[ -s "$ROOT/abs180amb/comment-repos.log" ]]; then
  bad "ambiguous-absent issue comment saw a --repo: $(cat "$ROOT/abs180amb/comment-repos.log")"
else
  ok "ambiguous-absent never selected a comment --repo"
fi
ja=$(cat "$state_aa/journal.md" 2>/dev/null || true)
contains "ambiguous-absent journals handoff_comment_failed" "$ja" "handoff_comment_failed"
lacks "ambiguous-absent no recovery_handoff success" "$ja" "recovery_handoff=1"
lacks "ambiguous-absent no COMPLETED already_absent success" "$ja" "result=already_absent"

echo "#180 · unresolved identity refuses already-absent recovery handoff"
# Non-GitHub single origin + failing gh → PR_REPO empty. Same recovery proof
# must fail closed with no handoff post.
new_repo "$ROOT/abs180unr"
# Default new_repo origin is a local bare path (non-GitHub) — leave it.
install_sibling_reaper "$ROOT/abs180unr/scripts"
: > "$ROOT/abs180unr/list-repos.log"
_install_abs180_empty_pr_claims "$ROOT/abs180unr/scripts" "$ROOT/abs180unr/list-repos.log"
: > "$ROOT/abs180unr/comments"
: > "$ROOT/abs180unr/comment-repos.log"
mkdir -p "$ROOT/abs180unr/bin"
_install_abs180_gh "$ROOT/abs180unr/bin" "$ROOT/abs180unr/comments" "$ROOT/abs180unr/comment-repos.log"
state_au="$STATE_BASE/abs180unr"
mkdir -p "$state_au"
printf '2026-08-01T00:00:00Z INCOMPLETE op=reap:issue-180-absunr:stale reason=handoff_comment_failed claim_released=1\n' \
  > "$state_au/journal.md"
out=$(
  PATH="$ROOT/abs180unr/bin:$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/abs180unr/canon" \
  GIBSON_REAPER_STATE_DIR="$state_au" \
  GIBSON_REAPER_JOURNAL="$state_au/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_au/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$ROOT/abs180unr/scripts/claim-reaper.sh" --claim-id issue-180-absunr --apply 2>&1
)
rc=$?
check "unresolved-absent recovery exits incomplete (3)" "$rc" "3"
if grep -Eqx 'acme/app|other/app' "$ROOT/abs180unr/list-repos.log" 2>/dev/null; then
  bad "unresolved-absent invented inventory identity: $(cat "$ROOT/abs180unr/list-repos.log")"
else
  ok "unresolved-absent never resolved inventory identity"
fi
if grep -qF 'gibson-claim-reaper:issue-180-absunr' "$ROOT/abs180unr/comments" 2>/dev/null; then
  bad "unresolved-absent must not post handoff: $(cat "$ROOT/abs180unr/comments")"
else
  ok "unresolved-absent posted no handoff comment"
fi
if [[ -s "$ROOT/abs180unr/comment-repos.log" ]]; then
  bad "unresolved-absent issue comment saw a --repo: $(cat "$ROOT/abs180unr/comment-repos.log")"
else
  ok "unresolved-absent never selected a comment --repo"
fi
ju=$(cat "$state_au/journal.md" 2>/dev/null || true)
contains "unresolved-absent journals handoff_comment_failed" "$ju" "handoff_comment_failed"
lacks "unresolved-absent no recovery_handoff success" "$ju" "recovery_handoff=1"
contains "unresolved-absent incomplete mentions handoff" "$out" "handoff"

echo "#180 · mutation: restoring gh-only resolve_repo makes one-origin recovery fail"
# Mutant derived from production (not a handwritten substitute). Anchor on the
# PR_REPO assignment; restore `_abs_repo=$(resolve_repo …)`. One-origin fixture
# must then fail (sensor would go red without the #180 fix).
_reaper_mut="$ROOT/abs180mut/scripts/claim-reaper.sh"
new_repo "$ROOT/abs180mut"
git -C "$ROOT/abs180mut/canon" config "url.$ROOT/abs180mut/origin.insteadOf" https://github.com/acme/app.git
git -C "$ROOT/abs180mut/canon" remote set-url origin https://github.com/acme/app.git
install_sibling_reaper "$ROOT/abs180mut/scripts"
: > "$ROOT/abs180mut/list-repos.log"
_install_abs180_empty_pr_claims "$ROOT/abs180mut/scripts" "$ROOT/abs180mut/list-repos.log"
: > "$ROOT/abs180mut/comments"
: > "$ROOT/abs180mut/comment-repos.log"
mkdir -p "$ROOT/abs180mut/bin"
_install_abs180_gh "$ROOT/abs180mut/bin" "$ROOT/abs180mut/comments" "$ROOT/abs180mut/comment-repos.log"
# Anchor / mutation-miss guard: production must still assign _abs_repo from PR_REPO
# under the already-absent recovery proof branch (comments sit between the if and
# the assignment, so use a wide before-context).
if grep -qF '_abs_repo="${PR_REPO:-}"' "$_reaper_mut" && \
   grep -B12 -F '_abs_repo="${PR_REPO:-}"' "$_reaper_mut" | grep -F 'journal_has_claim_released_handoff_failed' >/dev/null; then
  ok "mutation anchor: already-absent recovery binds _abs_repo to PR_REPO"
else
  bad "mutation-miss: production missing _abs_repo=\"\${PR_REPO:-}\" under recovery proof"
fi
# Surgical restore of the pre-#180 gh-only lookup (copy only).
# Escape \$( so Perl does not expand the real-GID special variable $( .
perl -i -pe 's/^(\s*)_abs_repo="\$\{PR_REPO:-\}"/$1_abs_repo=\$(resolve_repo 2>\/dev\/null || true)  # MUTATED gh-only/' "$_reaper_mut"
if grep -q 'MUTATED gh-only' "$_reaper_mut" && \
   grep -qF '_abs_repo=$(resolve_repo 2>/dev/null || true)' "$_reaper_mut" && \
   ! grep -qF '_abs_repo="${PR_REPO:-}"' "$_reaper_mut"; then
  ok "mutation applied: restored gh-only resolve_repo on recovery path"
else
  bad "mutation-miss: failed to restore gh-only resolve_repo: $(grep -n '_abs_repo' "$_reaper_mut" || true)"
fi
state_am="$STATE_BASE/abs180mut"
mkdir -p "$state_am"
printf '2026-08-01T00:00:00Z INCOMPLETE op=reap:issue-180-absmut:stale reason=handoff_comment_failed claim_released=1\n' \
  > "$state_am/journal.md"
out=$(
  PATH="$ROOT/abs180mut/bin:$BIN:$PATH" \
  GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" \
  GIBSON_CANONICAL="$ROOT/abs180mut/canon" \
  GIBSON_REAPER_STATE_DIR="$state_am" \
  GIBSON_REAPER_JOURNAL="$state_am/journal.md" \
  GIBSON_REAPER_LOCK_DIR="$state_am/lock" \
  GIBSON_REAPER_RELEASE_CMD="$RC" \
    "$_reaper_mut" --claim-id issue-180-absmut --apply 2>&1
)
rc=$?
# With gh-only lookup restored, origin identity is dropped → incomplete, no comment.
if [[ "$rc" -eq 3 ]] && \
   ! grep -qF 'gibson-claim-reaper:issue-180-absmut' "$ROOT/abs180mut/comments" 2>/dev/null && \
   ! grep -qF 'recovery_handoff=1' "$state_am/journal.md" 2>/dev/null; then
  ok "mutation receipt: gh-only lookup makes one-origin recovery fail (sensor would fail)"
else
  bad "mutation receipt: expected incomplete/no-handoff under gh-only mutant: rc=$rc out=$out comments=$(cat "$ROOT/abs180mut/comments" 2>/dev/null) journal=$(cat "$state_am/journal.md")"
fi
# Hygiene: restore production sibling (no further use of mutant).
install_sibling_reaper "$ROOT/abs180mut/scripts"

# ---------------------------------------------------------------------------
echo
echo "claim-reaper.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
