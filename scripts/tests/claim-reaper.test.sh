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

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
REAPER="$SCRIPT_DIR/../claim-reaper.sh"
RC="$SCRIPT_DIR/../release-claim.sh"
PASS=0
FAIL=0

ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
contains() { if echo "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
lacks() { if echo "$2" | grep -qF -- "$3"; then bad "$1 (unexpected '$3')"; else ok "$1"; fi; }

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
      if printf '%s' "$body" | grep -qE '/Users/|/home/|/private/|/tmp/gibson'; then
        echo "FAKE-GH: absolute path leaked into comment" >&2
        exit 1
      fi
      exit 0
    fi
    if [[ "${1:-}" == "edit" ]]; then
      log "EDIT $*"
      if printf '%s' "$*" | grep -q -- '--remove-label'; then
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
  shift
  local state="$STATE_BASE/$(basename "$(dirname "$canon")")"
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
if [[ "$(stat -f %m "$HBDIR/issue-24-heartbeat" 2>/dev/null || stat -c %Y "$HBDIR/issue-24-heartbeat")" -gt "$STALE_NOW" ]]; then
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
out2=$(GIBSON_CLAIMS_NOW_EPOCH="$STALE_NOW" run_reaper "$ROOT/apply/canon" --claim-id issue-40-dead --apply 2>&1)
rc2=$?
check "repeat apply exits 0" "$rc2" "0"
# claim already gone → completed already_absent or skip
comment_lines=$(grep -c 'gibson-claim-reaper:issue-40-dead' "$GH_COMMENTS_FILE" || true)
# marker appears once in body; file may have one body line
[[ "$comment_lines" -le 1 ]] && ok "comment not spammed on retry" || bad "comment duplicated ($comment_lines)"

# ---------------------------------------------------------------------------
echo "#73 · --prune-worktrees removes only exact registered target worktree"
new_repo "$ROOT/prune"
# release-claim removes the *default* path ../wt-<id-without-issue-prefix>, not an
# arbitrary registered path. Place canaries on those exact default paths.
WT_P="$ROOT/prune/wt-50-prune"
WT_S="$ROOT/prune/wt-50-sib"
mkdir -p "$WT_P" "$WT_S"
echo target > "$WT_P/marker"
echo sibling > "$WT_S/marker"
(
  cd "$ROOT/prune/canon" || exit 1
  git checkout -q main
  mkdir -p docs/claims
  export GIT_AUTHOR_DATE="@${CLAIM_EPOCH}"
  export GIT_COMMITTER_DATE="@${CLAIM_EPOCH}"
  # No worktree: field — claim timestamp only; missing branch tips → pure stale.
  cat > docs/claims/issue-50-prune.md <<EOF
claim: issue-50-prune
issue: 50
claimed: $CLAIMED_ISO
scope: a
session: t
branch: feat/50-prune
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
  git branch -f feat/50-prune HEAD
  git branch -f feat/50-sib HEAD
) >/dev/null 2>&1
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
[[ ! -f "$WT_P/marker" ]] && ok "prune removed target worktree" || bad "target worktree still present after prune"
[[ -f "$WT_S/marker" ]] && ok "sibling worktree preserved" || bad "sibling worktree was removed"
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
echo "#73 · legacy + per-file duplicate claim ids dedupe safely"
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
# Should list claim once as REAP
reap_lines=$(echo "$out" | grep -c 'REAP   issue-70-both' || true)
check "deduped to one REAP line" "$reap_lines" "1"

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
echo "#73 · never closes an issue (no gh issue close)"
if grep -n 'issue close\|--close\|state.*closed' "$REAPER" | grep -v 'never close' | grep -q .; then
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
echo
echo "claim-reaper.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
