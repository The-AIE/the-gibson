#!/usr/bin/env bash
# loop.sh — solo-loop driver (docs/11)
set -euo pipefail

usage() {
  cat <<'EOF'
loop.sh — drive the solo SDLC loop (one hat, fresh context, file state)

WHAT IT DOES
  For a target repo: check kill switch, read/update gibson/loop-state.md,
  render playbooks/loop-step.md with {{hat}} and {{loop_state}}, invoke the
  chosen runner headless, enforce error budget, append journal, optional MC
  heartbeat.

WHY
  Context resets beat compaction (docs/11). The driver is a disciplined Ralph
  loop with gates — persistence without self-grading.

RISKS
  - Unattended runs spend tokens / subscription quota (Grok flat-rate preferred).
  - Can open PRs and push when the runner has write permission.
  - Stop with the gibson/HALT file or GIBSON_HALT=1 env (checked unconditionally).
    The gibson-halt label is a human signal; when gh is available the driver
    also treats an open issue carrying that label as a soft halt cue.
  - Error budget (default 5 consecutive failures) stops the loop to avoid burn.
  - --escalate-after dispatches other vendors: more tokens, other providers see
    the diff. --supervisor devin sends finished branches to a cloud session that
    can open PRs and (if configured) merge (docs/22). When a supervisor is
    configured, a distinct-vendor second opinion of the exact handed-off SHA is
    required before handoff, and the gate fails closed: no review, no handoff.
    The branch stays queued in loop-state instead (Law 5 gate).
  - Reviews and handoffs diff against the target repo's own default branch. When
    an origin is configured, both the branch name and its exact tip come from the
    remote (stale local refs are not trusted); a local-only repo falls back to a
    verified local main/master. The review is pinned to that base SHA as well as
    to the head SHA, so a base that advances invalidates the receipt. A repo whose
    base cannot be resolved or confirmed blocks the handoff rather than guessing.
    Likewise a supervisor handoff requires the BRANCH to exist on the remote:
    a repo with no origin, and a branch that was never pushed, are both blocked
    before the review is spent — the supervisor opens the PR from the remote
    branch, so a local-only ref is nothing it can act on.
  - The review receipt is an operational control, not a security boundary. It is
    a plain file under <repo>/gibson/, so anything running as the same user —
    including the agents the gate constrains — can write it. Isolating it from
    them is a separate hardening concern (docs/22).

USAGE
  loop.sh --runner <grok|hermes|claude|codex> --repo <path> [options]
  loop.sh --help

OPTIONS
  --runner NAME       runtime CLI (required)
  --repo PATH         target repository path (required)
  --gibson PATH       Gibson clone (default: parent of this script)
  --once              single iteration then exit
  --print-prompt      render prompt only (no runner)
  --max-iterations N  cap iterations (default: unlimited until halt)
  --error-budget N    consecutive failures before stop (default: 5)
  --hat HAT           force starting hat (default: from loop-state or builder)
  --dry-run           show actions without invoking runner
  --escalate-after N  after N consecutive failures, get a cross-vendor second
                      opinion before the error budget runs out (default: off)
  --reviewers LIST    vendors for that second opinion (default: codex,claude)
  --supervisor NAME   'devin' hands finished branches to the cloud supervisor
                      whenever loop-state carries a `handoff:` field (docs/22).
                      Each handoff is gated on a fresh distinct-vendor review of
                      the exact SHA being handed off; a failed review blocks it.

EXAMPLES
  ./scripts/loop.sh --runner grok --repo ~/Code/acme-app
  ./scripts/loop.sh --runner grok --repo ~/Code/acme-app --once --print-prompt
  ./scripts/loop.sh --runner claude --repo ~/Code/acme-app --hat reviewer --once
  ./scripts/loop.sh --runner grok --repo ~/Code/acme-app \
      --escalate-after 2 --reviewers codex,claude --supervisor devin
EOF
}

RUNNER=""
REPO=""
GIBSON=""
ONCE=0
PRINT=0
MAX=-1
BUDGET=5
FORCE_HAT=""
DRY=0
ESCALATE_AFTER=0
REVIEWERS="codex,claude"
SUPERVISOR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --runner) RUNNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --gibson) GIBSON="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --print-prompt) PRINT=1; shift ;;
    --max-iterations) MAX="$2"; shift 2 ;;
    --error-budget) BUDGET="$2"; shift 2 ;;
    --hat) FORCE_HAT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --escalate-after) ESCALATE_AFTER="$2"; shift 2 ;;
    --reviewers) REVIEWERS="$2"; shift 2 ;;
    --supervisor) SUPERVISOR="$2"; shift 2 ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "loop.sh: ERROR: $*" >&2; exit 1; }
info() { echo "loop.sh: $*" >&2; }

[[ -n "$RUNNER" ]] || { usage; exit 2; }
[[ -n "$REPO" ]] || { usage; exit 2; }
[[ -d "$REPO" ]] || die "repo not a directory: $REPO"

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
GIBSON="${GIBSON:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLAYBOOK="$GIBSON/playbooks/loop-step.md"
[[ -f "$PLAYBOOK" ]] || die "missing $PLAYBOOK"

STATE_DIR="$REPO/gibson"
STATE_FILE="$STATE_DIR/loop-state.md"
JOURNAL="$STATE_DIR/journal.md"
HALT_FILE="$STATE_DIR/HALT"
# Written only by a successful pre-handoff review, and it names both endpoints of
# the diff that was reviewed — base branch/base SHA and head branch/head SHA — see
# ensure_cross_vendor_review.
REVIEW_RECEIPT="$STATE_DIR/second-opinion.receipt"

mkdir -p "$STATE_DIR"
if [[ ! -f "$STATE_FILE" ]]; then
  cat > "$STATE_FILE" <<EOF
# Gibson loop state
updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
issue:
pr:
hat: builder
next_hat: builder
round: 0
parked: false
handoff:
handoff_sha:
next_action: triage highest-priority unblocked unclaimed issue
notes: initialized by loop.sh
EOF
fi
grep -q '^handoff:' "$STATE_FILE" || printf 'handoff:\n' >> "$STATE_FILE"
grep -q '^handoff_sha:' "$STATE_FILE" || printf 'handoff_sha:\n' >> "$STATE_FILE"
[[ -f "$JOURNAL" ]] || echo "# Gibson loop journal" > "$JOURNAL"

# Kill switch: HALT file is primary. GIBSON_HALT=1 is checked unconditionally
# (previously only when `gh` was present — issue #55). When gh is available we
# also treat any open issue carrying the gibson-halt label as a soft signal.
halted() {
  if [[ -f "$HALT_FILE" ]]; then return 0; fi
  if [[ "${GIBSON_HALT:-}" == "1" ]]; then return 0; fi
  if command -v gh >/dev/null 2>&1; then
    if gh issue list --repo "$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#(git@[^:]+:|https?://[^/]+/)##; s/\.git$//' || true)" \
         --label gibson-halt --state open --limit 1 --json number -q '.[0].number' 2>/dev/null | grep -q '[0-9]'; then
      info "gibson-halt label detected on an open issue — treating as soft halt (write gibson/HALT to make permanent)"
      return 0
    fi
  fi
  return 1
}

# Why a blocked handoff writes to the journal and not only to stderr.
#
# playbooks/loop-step.md tells the NEXT agent — a fresh context, minutes or hours
# later, with none of this run's terminal — that when a handoff stays queued the
# reason is in gibson/journal.md and the fix is theirs. A refusal that only
# reaches stderr breaks that contract: the branch sits queued forever with no
# recorded reason, which is exactly the silent-agent failure Law 8 names.
#
# BLOCK_CONTEXT names the branch the entry is about; BLOCK_JOURNAL is the switch
# for callers that already write their own entry (escalate), so one failed
# attempt never produces two overlapping records.
BLOCK_CONTEXT=""
BLOCK_JOURNAL=1

# journal_block/block are called from resolve_base_pin and resolve_handoff_sha,
# which the caller runs inside a command substitution. An append to $JOURNAL is a
# filesystem write and survives that subshell; a shell variable set there would
# not, which is why the reason is recorded here at the point of refusal rather
# than reconstructed by the caller. Each refusal path calls block() exactly once
# and the callers above them deliberately only info(), so a single failed attempt
# leaves a single entry.
journal_block() {
  [[ "$BLOCK_JOURNAL" -eq 1 ]] || return 0
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · handoff blocked${BLOCK_CONTEXT:+ · branch=$BLOCK_CONTEXT}"
    echo "$*"
    echo "handoff/handoff_sha remain queued in loop-state; clear the reason above and the next iteration retries (Law 5, Law 8)."
  } >> "$JOURNAL"
}

block() { info "$*"; journal_block "$*"; }

read_field() {
  local key="$1"
  # FS set so field 1 is the key
  awk -v k="$key" -F': ' '{ if ($1 == k) { sub(/^[^:]+: /,""); print; exit } }' "$STATE_FILE"
}

render_prompt() {
  local hat="$1"
  local state
  state=$(cat "$STATE_FILE")
  node -e '
    const fs=require("fs");
    const pb=fs.readFileSync(process.argv[1],"utf8");
    const hat=process.argv[2];
    const state=fs.readFileSync(process.argv[3],"utf8");
    const gibson=process.argv[4];
    const repo=process.argv[5];
    let out=pb.split("{{hat}}").join(hat)
      .split("{{loop_state}}").join(state)
      .split("{{gibson_path}}").join(gibson)
      .split("{{repo_path}}").join(repo);
    process.stdout.write(out);
  ' "$PLAYBOOK" "$hat" "$STATE_FILE" "$GIBSON" "$REPO"
}

invoke_runner() {
  local prompt_file="$1"
  case "$RUNNER" in
    grok)
      command -v grok >/dev/null || die "grok CLI not found"
      # --prompt-file, not -p "$(cat ...)": rendered playbooks start with YAML
      # frontmatter ("---"), which grok's arg parser mis-reads as a flag when
      # passed as a positional/value string instead of a file path (L-007).
      # --permission-mode bypassPermissions: without it, grok has no TTY to
      # request tool-call approval in headless mode, so it silently narrates
      # instead of acting — every iteration exits in seconds with no real work
      # (L-008).
      # --cwd: bypassPermissions plus an inherited cwd would point the runner at
      # whatever directory the operator launched from — often the canonical
      # Gibson checkout, which AGENTS.md Law 3 says nothing may mutate.
      grok --prompt-file "$prompt_file" --cwd "$REPO" --permission-mode bypassPermissions
      ;;
    claude)
      command -v claude >/dev/null || die "claude CLI not found"
      # stdin, for the same frontmatter reason as grok's --prompt-file above:
      # as a positional arg the leading "---" is parsed as an unknown option
      (cd "$REPO" && claude -p --output-format text --permission-mode acceptEdits) < "$prompt_file"
      ;;
    codex)
      command -v codex >/dev/null || die "codex CLI not found"
      codex exec --full-auto --cd "$REPO" - < "$prompt_file"
      ;;
    hermes)
      if [[ -n "${HERMES_CMD:-}" ]]; then
        eval "$HERMES_CMD" < "$prompt_file"
      elif command -v hermes >/dev/null; then
        hermes run --prompt-file "$prompt_file"
      else
        die "hermes runner not found; set HERMES_CMD"
      fi
      ;;
    *) die "unknown runner: $RUNNER" ;;
  esac
}

# The base every review and every handoff must diff against, resolved as BOTH a
# branch name and an exact commit SHA. The supervisor needs the name (it opens a
# PR into a branch); the reviewer needs the SHA, for the same reason the head side
# is pinned to one: a base ref is a moving target.
#
# Not every repo's trunk is called `main`, and the local answer is not necessarily
# the current one. `refs/remotes/origin/HEAD` is a cached guess that survives a
# default-branch rename, and `refs/heads/main` can be many commits behind
# `origin/main` — a review diffed against either compares something other than
# what the supervisor will open, while the receipt records only the branch *name*
# and so looks reusable. When an origin is configured, the name and the tip
# therefore both come from the remote, and every failure to observe it fails
# closed. Only a genuinely local-only repo (no origin at all) falls back to a
# verified local main/master.
#
# Prints "<name> <sha>"; returns 1 when nothing can be pinned, and the caller must
# then refuse to review or hand off.
resolve_base_pin() {
  local name="" sha="" symref ls_out
  if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    if ! symref=$(git -C "$REPO" ls-remote --symref origin HEAD 2>/dev/null); then
      block "base unresolvable: git ls-remote --symref origin HEAD failed in $REPO — cannot confirm the current default branch, and a stale local ref reviews the wrong diff. Check the remote is reachable and credentials are valid, then re-queue."
      return 1
    fi
    name=$(printf '%s\n' "$symref" |
      awk '$1 == "ref:" && $3 == "HEAD" { sub(/^refs\/heads\//, "", $2); print $2; exit }')
    if [[ -z "$name" ]]; then
      block "base unresolvable: origin advertises no symbolic HEAD for $REPO — refusing to guess the base branch. Set the remote's default branch (gh repo edit --default-branch NAME, or git remote set-head origin -a upstream-side), then re-queue."
      return 1
    fi
    if ! ls_out=$(git -C "$REPO" ls-remote origin "refs/heads/$name" 2>/dev/null); then
      block "base unconfirmable: git ls-remote origin refs/heads/$name failed — cannot confirm the current base tip, and reviewing against a stale local copy of $name reviews a diff nobody will merge. Restore access to origin, then re-queue."
      return 1
    fi
    sha=$(printf '%s\n' "$ls_out" | awk 'NR==1 {print $1}')
    if [[ -z "$sha" ]]; then
      block "base missing on the remote: origin advertises HEAD -> $name but has no refs/heads/$name — refusing to review against a base that does not exist. Push $name or repoint the remote's default branch, then re-queue."
      return 1
    fi
  else
    for name in main master; do
      sha=$(git -C "$REPO" rev-parse --verify --quiet "refs/heads/$name" || true)
      if [[ -n "$sha" ]]; then break; fi
      name=""
    done
    if [[ -z "$name" || -z "$sha" ]]; then
      block "base unresolvable: no base branch for $REPO (no origin configured, and no local main/master to fall back to). Create the trunk branch or add a remote whose HEAD names it, then re-queue."
      return 1
    fi
  fi
  # Same rule as the head side: a reviewer cannot diff a commit this clone cannot
  # read. The advertised base tip may have been pushed after this clone last
  # fetched, so fetch the branch (then the exact SHA) and refuse if the object is
  # still missing rather than record a review of something unreadable.
  if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
    info "base commit $sha ($name) is not in the local object database — fetching refs/heads/$name from origin"
    git -C "$REPO" fetch --quiet origin "refs/heads/$name" >/dev/null 2>&1 ||
      info "fetch of base refs/heads/$name failed — trying the exact SHA"
    if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
      git -C "$REPO" fetch --quiet origin "$sha" >/dev/null 2>&1 || true
    fi
    if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
      block "base object unfetchable: commit $sha ($name) is still missing from this clone after fetching refs/heads/$name and the exact SHA — refusing to review against a base nobody here can read. Check whether the tip was pruned or rewritten on the remote, then re-queue."
      return 1
    fi
    info "fetched base $sha into the local object database"
  fi
  printf '%s %s\n' "$name" "$sha"
}

escalate() {
  local out="$STATE_DIR/second-opinion.md"
  info "escalating after $failures consecutive failures — reviewers: $REVIEWERS"
  # This clobbers second-opinion.md with a failure-triage review, so the
  # pre-handoff receipt that pointed at the old contents is no longer valid.
  rm -f "$REVIEW_RECEIPT"
  local base="" base_sha="" pin note
  # Same exact base as the pre-handoff review: a failure-triage review of the
  # wrong diff is as misleading as a pre-handoff one.
  #
  # No handoff is queued here, and this function writes its own journal entry a
  # few lines down, so resolve_base_pin's refusal stays on stderr: two records of
  # one skipped escalation would be noise, not signal.
  BLOCK_JOURNAL=0
  if pin=$(resolve_base_pin); then
    base=${pin%% *}
    base_sha=${pin##* }
  fi
  BLOCK_JOURNAL=1
  if [[ -z "$base_sha" ]]; then
    info "escalation review skipped — no base branch resolved, and a guessed base reviews the wrong diff"
    note="Escalation review skipped: the target repo's base branch could not be resolved (Law 8)."
  elif "$SCRIPT_DIR/second-opinion.sh" \
      --repo "$REPO" --reviewers "$REVIEWERS" --author "$RUNNER" --base "$base_sha" \
      --gate-status "red: $failures consecutive runner failures" --out "$out" >/dev/null 2>&1; then
    info "second opinion written to $out (base $base @ $base_sha)"
    note="Second opinion against \`$base\` @ \`$base_sha\` written to gibson/second-opinion.md — next hat must read it."
  else
    info "second opinion failed (non-fatal) — continuing"
    note="No reviewer completed — see gibson/second-opinion.md for the raw attempts (Law 8)."
  fi
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · escalation · reviewers=$REVIEWERS"
    echo "$note"
  } >> "$JOURNAL"
}

# Resolve the SHA the supervisor will actually see, and refuse to hand off a tip
# nobody reviewed. devin-supervisor.sh compares --sha against `ls-remote origin`
# and dies on a mismatch, so the driver resolves the same way: a loop-state pin
# that disagrees with the remote tip is a blocked handoff here, not a die() three
# scripts later (issue #55). Prints the SHA on stdout; returns 1 when there is
# none to pin.
resolve_handoff_sha() {
  local branch="$1" pinned remote="" ls_out sha
  pinned=$(read_field handoff_sha)
  # No origin at all is fatal here, not a fall-through to local refs. This
  # function is reached only from supervisor_handoff, i.e. only when the work is
  # destined for the Devin supervisor — and the supervisor opens the PR from the
  # REMOTE branch, so a repo with no remote has nothing it can be handed. The
  # real devin-supervisor.sh already refuses a --sha handoff without an origin;
  # resolving a local SHA here would only mean spending a distinct-vendor review
  # first and hitting that same refusal afterwards. Fail before the review, not
  # after it.
  if ! git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    block "no origin configured in $REPO — the supervisor can only open a PR from a remote branch, so an origin-less repo has no handoff to make. Add a remote and push $branch, then re-queue the handoff."
    return 1
  fi
  # Explicit, not errexit-suppressed: an unreachable origin means we cannot tell
  # whether the tip moved, and handing off a tip we cannot confirm is exactly
  # what the pin exists to prevent.
  if ls_out=$(git -C "$REPO" ls-remote origin "refs/heads/$branch" 2>/dev/null); then
    remote=$(printf '%s\n' "$ls_out" | awk 'NR==1 {print $1}')
  else
    block "origin unreachable: git ls-remote origin refs/heads/$branch failed — cannot confirm the remote tip, and handing off a tip we cannot confirm is exactly what the pin exists to prevent. Restore access to origin, then re-queue the handoff."
    return 1
  fi
  # Reachable origin, no such branch: the branch exists only in this checkout.
  # Falling back to refs/heads/$branch here reviews a tip the supervisor cannot
  # see — it opens a PR from the REMOTE branch, so it would review and merge
  # something other than what was reviewed here, or nothing at all. An
  # unpublished branch is a blocked handoff, not a local-ref handoff.
  if [[ -z "$remote" ]]; then
    block "branch not on the remote: origin has no refs/heads/$branch — it was never pushed, and the supervisor can only open a PR from the remote branch. Run 'git -C $REPO push origin $branch', then re-queue the handoff."
    return 1
  fi
  if [[ -n "$pinned" && "$pinned" != "$remote" ]]; then
    block "pin mismatch: loop-state pins $branch @ $pinned but the remote tip is $remote — refusing to hand off an unreviewed tip (issue #55). Either push the pinned commit or set handoff_sha to $remote after re-reviewing that tip, then re-queue."
    return 1
  fi
  # Never empty: $remote is non-empty by the time we get here, because every
  # other path above returned 1. There is deliberately no local-ref fallback —
  # a SHA only this clone can see is not a SHA the supervisor can act on.
  sha="${pinned:-$remote}"
  # The SHA may have come from `ls-remote` (or from a loop-state pin written by
  # an agent working in a different worktree), so the object is not necessarily
  # in THIS clone. A reviewer cannot diff a commit it cannot read, and writing a
  # receipt for an absent object records a review that never happened — fetch the
  # exact branch, then refuse if the commit is still missing (issue #55).
  if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
    info "commit $sha is not in the local object database — fetching refs/heads/$branch from origin"
    git -C "$REPO" fetch --quiet origin "refs/heads/$branch" >/dev/null 2>&1 ||
      info "fetch of refs/heads/$branch failed — trying the exact SHA"
    if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
      git -C "$REPO" fetch --quiet origin "$sha" >/dev/null 2>&1 || true
    fi
    if ! git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null 2>&1; then
      block "head object unfetchable: commit $sha is still missing from this clone after fetching refs/heads/$branch and the exact SHA — refusing to record a review of an object nobody here can read. Check whether the tip was pruned or rewritten on the remote, then re-queue."
      return 1
    fi
    info "fetched $sha into the local object database"
  fi
  printf '%s\n' "$sha"
}

# A receipt is written only when second-opinion.sh exited 0, and it names BOTH
# endpoints of the diff that was reviewed. That is what makes a stale
# gibson/second-opinion.md useless as a pass: the artifact alone proves nothing
# about which tip, which vendor, or whether the reviewer even finished (issue
# #55). Binding the base SHA as well as the head SHA closes the matching hole on
# the base side — the same head reviewed against a base branch that has since
# advanced is a different diff, so its receipt must not be reused.
#
# Scope of the guarantee: this is an operational control over what the driver
# will do, not a tamper-proof one. The receipt is a same-user file in the target
# repo, so a runner with write access there could forge one; keeping it out of
# their reach is a separate hardening concern and is not solved here.
review_receipt_ok() {
  local sha="$1" branch="$2" base="$3" base_sha="$4"
  [[ -f "$REVIEW_RECEIPT" ]] || return 1
  [[ -s "$STATE_DIR/second-opinion.md" ]] || return 1
  grep -qxF "status: ok" "$REVIEW_RECEIPT" || return 1
  grep -qxF "sha: $sha" "$REVIEW_RECEIPT" || return 1
  grep -qxF "branch: $branch" "$REVIEW_RECEIPT" || return 1
  grep -qxF "base: $base" "$REVIEW_RECEIPT" || return 1
  grep -qxF "base_sha: $base_sha" "$REVIEW_RECEIPT" || return 1
  grep -qxF "author: $RUNNER" "$REVIEW_RECEIPT" || return 1
  grep -qxF "reviewers: $REVIEWERS" "$REVIEW_RECEIPT" || return 1
  return 0
}

# Law 5 gate: never grade your own homework. Returns 0 only when a reviewer from
# a different vendor completed successfully against exactly $base_sha...$sha.
# Every other outcome — no distinct vendor configured, reviewer CLI missing,
# reviewer non-zero, empty diff — returns 1, and the caller must not hand off.
ensure_cross_vendor_review() {
  local branch="$1" sha="$2" base="$3" base_sha="$4"
  local out="$STATE_DIR/second-opinion.md"

  if review_receipt_ok "$sha" "$branch" "$base" "$base_sha"; then
    info "distinct-vendor review already recorded for $branch @ $sha against $base @ $base_sha — reusing it"
    return 0
  fi

  if [[ -z "$REVIEWERS" ]]; then
    block "no reviewers configured: --reviewers is empty, so there is no distinct-vendor reviewer to run and nobody may approve $branch @ $sha (Law 5). Re-run the loop with --reviewers naming a vendor other than $RUNNER."
    return 1
  fi
  local distinct=0 name
  local names=()
  IFS=',' read -ra names <<< "$REVIEWERS"
  for name in "${names[@]}"; do
    name=$(echo "$name" | tr -d '[:space:]')
    if [[ -n "$name" && "$name" != "$RUNNER" ]]; then
      distinct=1
    fi
  done
  if [[ "$distinct" -eq 0 ]]; then
    block "no distinct vendor: --reviewers '$REVIEWERS' contains no vendor other than the runner ($RUNNER), and nobody grades their own homework (Law 5). Add a different vendor to --reviewers, then re-queue the handoff of $branch @ $sha."
    return 1
  fi

  # Remove first: a review that fails halfway must never leave a passing receipt.
  rm -f "$REVIEW_RECEIPT"
  info "running the mandatory distinct-vendor review of $branch @ $sha against $base @ $base_sha before handoff (Law 5)"
  # --base is the exact base SHA, not the branch name: the reviewer must see the
  # same two endpoints the receipt records.
  if "$SCRIPT_DIR/second-opinion.sh" \
      --repo "$REPO" --reviewers "$REVIEWERS" --author "$RUNNER" \
      --base "$base_sha" --branch "$sha" \
      --gate-status "pre-handoff mandatory review of $branch @ $sha against $base @ $base_sha" \
      --out "$out" >/dev/null; then
    printf 'sha: %s\nbranch: %s\nbase: %s\nbase_sha: %s\nauthor: %s\nreviewers: %s\nreviewed: %s\nstatus: ok\n' \
      "$sha" "$branch" "$base" "$base_sha" "$RUNNER" "$REVIEWERS" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      > "$REVIEW_RECEIPT"
    info "distinct-vendor review of $sha against $base @ $base_sha completed — receipt at $REVIEW_RECEIPT"
    return 0
  fi
  rm -f "$REVIEW_RECEIPT"
  # The reviewer-failure entry that already existed, now emitted through the same
  # helper as every other refusal so the journal reads in one format.
  block "pre-handoff review failed: the distinct-vendor review of $branch @ $sha against $base @ $base_sha did not complete (reviewers=$REVIEWERS, author=$RUNNER). Read gibson/second-opinion.md for the raw attempts, fix what the reviewer choked on, then re-queue."
  return 1
}

# File-handoff protocol: pin and pass the head SHA so a later push cannot
# invalidate the review without the supervisor noticing (issue #55). The gate is
# closed — every early return here leaves handoff/handoff_sha queued in
# loop-state and never reaches devin-supervisor.sh.
supervisor_handoff() {
  [[ "$SUPERVISOR" == "devin" ]] || return 0
  local branch
  branch=$(read_field handoff)
  [[ -n "$branch" ]] || return 0
  # Names the branch in every journal entry written below this point, including
  # the ones written from inside resolve_base_pin/resolve_handoff_sha's command
  # substitutions — a reader with three queued branches needs to know which one
  # each reason belongs to.
  BLOCK_CONTEXT="$branch"

  # Resolved before anything is spent: a review against a guessed or stale base is
  # a review of the wrong diff, so a base that cannot be resolved AND confirmed
  # blocks the handoff instead of quietly falling back to `main`.
  local base base_sha pin
  if ! pin=$(resolve_base_pin); then
    info "handoff of $branch blocked: the target repo's base branch could not be resolved or confirmed — branch stays queued in loop-state"
    return 0
  fi
  base=${pin%% *}
  base_sha=${pin##* }

  local sha
  if ! sha=$(resolve_handoff_sha "$branch"); then
    info "handoff of $branch blocked: no reviewable SHA — branch stays queued in loop-state"
    return 0
  fi
  info "pinning handoff to $branch @ $sha (base $base @ $base_sha)"

  if ! ensure_cross_vendor_review "$branch" "$sha" "$base" "$base_sha"; then
    info "handoff of $branch @ $sha blocked: no completed distinct-vendor review — branch stays queued in loop-state"
    return 0
  fi

  local task issue next
  issue=$(read_field issue)
  next=$(read_field next_action)
  task=""
  [[ -z "$issue" ]] || task="Issue: $issue."
  [[ -z "$next" ]] || task="${task:+$task }Next action: $next"
  [[ -n "$task" ]] || task="See the branch diff; loop-state carried no task description."
  local review="$STATE_DIR/second-opinion.md"
  # The supervisor gets the human branch NAMES — it opens a PR from one branch
  # into another, not from one commit into another — AND both exact SHAs, so the
  # diffstat it is shown is built from the same two endpoints the reviewer saw.
  # Passing only the names would let a stale local ref describe a different diff
  # than the one that was reviewed. Both objects were fetched and verified by
  # resolve_base_pin/resolve_handoff_sha above, so the exact-SHA diff is readable.
  info "handing $branch @$sha to the Devin supervisor (base $base @ $base_sha)"
  if "$SCRIPT_DIR/devin-supervisor.sh" handoff --repo "$REPO" --branch "$branch" \
      --base "$base" --base-sha "$base_sha" --sha "$sha" \
      --task "$task" --gate-status "green locally" \
      --review-file "$review"; then
    node -e '
      const fs = require("fs");
      const file = process.argv[1];
      let text = fs.readFileSync(file, "utf8");
      text = text.replace(/^handoff:.*$/m, "handoff:");
      text = text.replace(/^handoff_sha:.*$/m, "handoff_sha:");
      fs.writeFileSync(file, text);
    ' "$STATE_FILE"
  else
    block "supervisor rejected the handoff: devin-supervisor.sh exited non-zero for $branch @ $sha into $base @ $base_sha. Re-run that command by hand to see its refusal (it prints the reason to stderr) — a moved remote tip, a missing DEVIN_API_KEY, and an unreachable Devin API all land here."
  fi
}

heartbeat() {
  if [[ -n "${MC_HEARTBEAT_URL:-}" ]]; then
    curl -sS -X POST "$MC_HEARTBEAT_URL" \
      -H 'content-type: application/json' \
      -d "{\"source\":\"loop.sh\",\"repo\":\"$REPO\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
      >/dev/null 2>&1 || info "heartbeat failed (non-fatal)"
  fi
}

failures=0
iter=0

if [[ "$SUPERVISOR" == "devin" && "$DRY" -eq 0 && "$PRINT" -eq 0 ]]; then
  "$SCRIPT_DIR/devin-supervisor.sh" ensure --repo "$REPO" || \
    info "supervisor unavailable at startup (non-fatal) — handoffs will retry"
fi

while true; do
  if halted; then
    info "kill switch set — stopping cleanly"
    exit 0
  fi

  hat="${FORCE_HAT:-$(read_field next_hat)}"
  [[ -n "$hat" ]] || hat="builder"
  FORCE_HAT=""

  info "iteration hat=$hat repo=$REPO"

  PROMPT_FILE=$(mktemp)
  render_prompt "$hat" > "$PROMPT_FILE"

  if [[ "$PRINT" -eq 1 ]]; then
    cat "$PROMPT_FILE"
    rm -f "$PROMPT_FILE"
    exit 0
  fi

  if [[ "$DRY" -eq 1 ]]; then
    info "dry-run: would invoke $RUNNER with rendered loop-step ($hat)"
    rm -f "$PROMPT_FILE"
  else
    set +e
    invoke_runner "$PROMPT_FILE"
    ec=$?
    set -e
    rm -f "$PROMPT_FILE"
    if [[ $ec -ne 0 ]]; then
      failures=$((failures + 1))
      info "runner exit $ec (consecutive failures=$failures/$BUDGET)"
      if [[ "$ESCALATE_AFTER" -gt 0 && $failures -eq "$ESCALATE_AFTER" ]]; then
        escalate
      fi
      if [[ $failures -ge $BUDGET ]]; then
        die "error budget exhausted — likely harness bug, not retry fodder (docs/11)"
      fi
    else
      failures=0
      supervisor_handoff
    fi
  fi

  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · hat=$hat · runner=$RUNNER"
    echo "Driver completed iteration; agent should have updated loop-state."
  } >> "$JOURNAL"

  heartbeat
  iter=$((iter + 1))

  if [[ "$ONCE" -eq 1 ]]; then
    info " --once done"
    exit 0
  fi
  if [[ "$MAX" -ge 0 && "$iter" -ge "$MAX" ]]; then
    info "max iterations $MAX reached"
    exit 0
  fi
done
