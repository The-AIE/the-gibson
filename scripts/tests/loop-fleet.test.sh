#!/usr/bin/env bash
# loop-fleet.test.sh — offline sensors for portable fleet profiles (#139)
#
# Throwaway repos + stub gh/runner/loop only. No network, no live PRs, no models.
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
FLEET="$REPO_ROOT/scripts/loop-fleet.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-gibson-sensor}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-sensor@gibson.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-gibson-sensor}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-sensor@gibson.invalid}"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-loop-fleet-test.XXXXXX")
trap 'rm -rf -- "${ROOT:?}"' EXIT

BIN="$ROOT/bin"
CALLS="$ROOT/calls"
mkdir -p "$BIN" "$CALLS" "$ROOT/profiles" "$ROOT/fleet" "$ROOT/logs" "$ROOT/gibson/scripts"

GIT="git -c user.email=test@gibson.invalid -c user.name=gibson-test -c commit.gpgsign=false"

# --- stubs ------------------------------------------------------------------

# Launch counter: every loop.sh invocation records one line. Fail-closed
# preflight must leave this file empty / missing.
cat > "$ROOT/gibson/scripts/loop.sh" <<'STUB'
#!/usr/bin/env bash
# stub loop — records launch; never calls a model
log="${LOOP_LAUNCH_LOG:-/dev/null}"
printf 'LAUNCH runner=%s repo=%s slug=%s\n' \
  "${2:-}" "${4:-}" "${6:-}" >> "$log"
# also dump full argv for assertions
printf '%s\n' "$@" >> "${LOOP_LAUNCH_LOG}.argv"
exit 0
STUB
chmod +x "$ROOT/gibson/scripts/loop.sh"

# fake builder runner on PATH
cat > "$BIN/fake-runner" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/fake-runner"

# gh stub — behavior via GH_STUB_MODE and optional per-issue files
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
mode="${GH_STUB_MODE:-ok}"
log="${GH_STUB_LOG:-}"
[[ -n "$log" ]] && printf '%s\n' "$*" >> "$log"

# Parse: gh issue view N --repo SLUG --json state,labels
#        gh pr list --repo SLUG --state open --json number,headRefName --limit N
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  issue="$3"
  case "$mode" in
    missing)
      echo "could not find issue #$issue" >&2
      exit 1
      ;;
    closed)
      echo '{"state":"CLOSED","labels":[]}'
      exit 0
      ;;
    gated-needs-mark)
      echo '{"state":"OPEN","labels":[{"name":"needs-mark"},{"name":"enhancement"}]}'
      exit 0
      ;;
    gated-tier-c)
      echo '{"state":"OPEN","labels":[{"name":"tier-c"}]}'
      exit 0
      ;;
    gated-decision)
      echo '{"state":"OPEN","labels":[{"name":"decision"}]}'
      exit 0
      ;;
    gated-blocked)
      echo '{"state":"OPEN","labels":[{"name":"blocked"}]}'
      exit 0
      ;;
    gated-halt)
      echo '{"state":"OPEN","labels":[{"name":"gibson-halt"}]}'
      exit 0
      ;;
    claimed)
      echo '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}'
      exit 0
      ;;
    ok|pr-conflict)
      # per-issue override file: $GH_STUB_ISSUE_DIR/<n>.json
      if [[ -n "${GH_STUB_ISSUE_DIR:-}" && -f "${GH_STUB_ISSUE_DIR}/${issue}.json" ]]; then
        cat "${GH_STUB_ISSUE_DIR}/${issue}.json"
        exit 0
      fi
      echo '{"state":"OPEN","labels":[{"name":"tier-a"},{"name":"enhancement"}]}'
      exit 0
      ;;
    *)
      echo "gh stub: unknown mode $mode" >&2
      exit 2
      ;;
  esac
fi

if [[ "$1" == "pr" && "$2" == "list" ]]; then
  case "$mode" in
    pr-conflict)
      # Emit a conflicting branch for issue 42 (used by conflict test)
      echo '[{"number":9,"headRefName":"feat/42-password-reset"}]'
      exit 0
      ;;
    *)
      echo '[]'
      exit 0
      ;;
  esac
fi

echo "gh stub: unhandled: $*" >&2
exit 2
STUB
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"

# Common env for driver runs
export GIBSON="$ROOT/gibson"
export FLEET_DIR="$ROOT/fleet"
export LOG_DIR="$ROOT/logs"
export RUNNER="fake-runner"
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
export GH_BIN="$BIN/gh"
export LOOP_SH="$ROOT/gibson/scripts/loop.sh"
export SLEEP_CMD="true"
export DEADLINE_SECONDS=99
export LOOP_LAUNCH_LOG="$CALLS/launches.log"
export GH_STUB_LOG="$CALLS/gh.log"
# Deterministic: no background nohup / watchdog in sensors
export FLEET_SYNC_LAUNCH=1
export FLEET_NO_WATCHDOG=1
export FLEET_SKIP_FETCH=1
export GIT_TERMINAL_PROMPT=0

reset_calls() {
  rm -f "$CALLS/launches.log" "$CALLS/launches.log.argv" "$CALLS/gh.log"
  : > "$CALLS/launches.log"
  # Force-remove lane worktrees from any target that registered them
  if [[ -d "$ROOT/targets" ]]; then
    for t in "$ROOT/targets"/*; do
      [[ -d "$t/.git" || -f "$t/.git" ]] || continue
      # List worktrees and remove non-main ones by path under FLEET_DIR
      while IFS= read -r wt; do
        [[ -n "$wt" ]] || continue
        case "$wt" in
          "$FLEET_DIR"/*)
            $GIT -C "$t" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf -- "$wt"
            ;;
        esac
      done < <($GIT -C "$t" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
      $GIT -C "$t" worktree prune >/dev/null 2>&1 || true
    done
  fi
  rm -rf "${FLEET_DIR:?}" "${LOG_DIR:?}"
  mkdir -p "$FLEET_DIR" "$LOG_DIR"
}

launch_count() {
  if [[ ! -f "$CALLS/launches.log" ]]; then
    printf '0\n'
    return 0
  fi
  local n
  n=$(grep -c '^LAUNCH' "$CALLS/launches.log" 2>/dev/null || true)
  if [[ -z "$n" ]]; then n=0; fi
  printf '%s\n' "$n"
}

# --- fixtures ---------------------------------------------------------------

setup_target_repo() {
  local name="$1" slug="${2:-acme/widget}" def_branch="${3:-main}"
  local dir="$ROOT/targets/$name"
  # Drop prior worktrees registered against this canon (if any)
  if [[ -d "$dir/.git" ]]; then
    $GIT -C "$dir" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf -- "$dir"
  mkdir -p "$dir"
  $GIT init -q "$dir"
  $GIT -C "$dir" checkout -q -b "$def_branch"
  echo "app" > "$dir/README.md"
  mkdir -p "$dir/docs" "$dir/scripts" "$dir/apps/mcp/lib" "$dir/marketing/app"
  echo x > "$dir/docs/a.md"
  echo x > "$dir/scripts/a.sh"
  $GIT -C "$dir" add -A
  $GIT -C "$dir" commit -q -m "init"
  # GitHub-shaped origin for slug preflight only. Tests set FLEET_SKIP_FETCH=1
  # so the driver never contacts the network. origin/HEAD must be set so the
  # offline default-branch pin does not guess main/master.
  $GIT -C "$dir" remote add origin "https://github.com/${slug}.git"
  $GIT -C "$dir" update-ref "refs/remotes/origin/${def_branch}" HEAD
  $GIT -C "$dir" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/${def_branch}"
  printf '%s\n' "$dir"
}

write_profile() {
  local path="$1"
  shift
  # remaining args written as body
  printf '%s\n' "$@" > "$path"
}

run_fleet() {
  # usage: run_fleet [args...]
  # uses FLEET_PROFILE if set, or pass --profile
  env \
    GIBSON="$GIBSON" \
    FLEET_DIR="$FLEET_DIR" \
    LOG_DIR="$LOG_DIR" \
    RUNNER="$RUNNER" \
    REVIEWER_CMD="$REVIEWER_CMD" \
    RELEASE_CMD="$RELEASE_CMD" \
    GH_BIN="$GH_BIN" \
    LOOP_SH="$LOOP_SH" \
    SLEEP_CMD="$SLEEP_CMD" \
    DEADLINE_SECONDS="$DEADLINE_SECONDS" \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 \
    FLEET_NO_WATCHDOG=1 \
    FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 \
    GH_STUB_MODE="${GH_STUB_MODE:-ok}" \
    GH_STUB_LOG="$GH_STUB_LOG" \
    GH_STUB_ISSUE_DIR="${GH_STUB_ISSUE_DIR:-}" \
    FLEET_PROFILE="${FLEET_PROFILE:-}" \
    "$FLEET" "$@" 2>&1
}

# macOS often rewrites /var → /private/var under pwd -P
abs_path() {
  (CDPATH='' cd "$1" && pwd -P)
}

# ============================================================================
echo "loop-fleet.test.sh — portable fleet profiles (#139)"
echo

[[ -x "$FLEET" ]] || [[ -f "$FLEET" ]] && ok "loop-fleet.sh present" || bad "loop-fleet.sh missing"
bash -n "$FLEET" && ok "bash -n loop-fleet.sh" || bad "bash -n failed"
"$FLEET" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help failed"

# --- valid Gibson-shaped profile -------------------------------------------
echo "valid Gibson-shaped profile"
reset_calls
TARGET=$(setup_target_repo gibson mrhinkle/the-gibson)
PROF="$ROOT/profiles/gibson.profile"
write_profile "$PROF" \
  "version=1" \
  "name=gibson-dogfood" \
  "repo=$TARGET" \
  "slug=mrhinkle/the-gibson" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "error_budget=3" \
  "deadline_seconds=99" \
  "lane=docs|96,89|docs/** playbooks/**|Autonomy readiness + overnight dogfood (#96) and self-gate docs" \
  "lane=scripts|74|scripts/**|Harness scripts only — cost ledger residual"

export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
TARGET_ABS=$(abs_path "$TARGET")
out=$(run_fleet --status) || true
echo "$out" | grep -q 'profile=gibson-dogfood' && ok "status prints profile name" || bad "status missing profile: $out"
echo "$out" | grep -q "target_repo=$TARGET_ABS" && ok "status prints absolute target repo" || bad "status missing target: $out"
echo "$out" | grep -q 'expected_slug=mrhinkle/the-gibson' && ok "status prints expected slug" || bad "status missing slug: $out"

reset_calls
# recreate profile target after reset may have pruned worktrees; repo still exists
out=$(run_fleet --start) || { bad "valid gibson start failed: $out"; out=""; }
lc=$(launch_count | tr -d '[:space:]')
if [[ "$lc" == "2" ]]; then
  ok "valid gibson profile launched 2 lanes"
else
  bad "expected 2 launches, got '$lc' (out=$out) log=$(cat "$CALLS/launches.log" 2>/dev/null; cat "$ROOT/logs"/*.log 2>/dev/null | head -20)"
fi
# lane bases are lane-* not wt-*
if [[ -d "$ROOT/fleet/lane-docs" && -d "$ROOT/fleet/lane-scripts" ]]; then
  ok "lane bases named lane-* (not wt-*)"
else
  bad "missing lane bases under $ROOT/fleet: $(ls -la "$ROOT/fleet" 2>&1)"
fi
if [[ -f "$ROOT/fleet/lane-docs/.fleet-lane" ]]; then
  ok "lane base has .fleet-lane sentinel"
else
  bad "missing .fleet-lane sentinel"
fi
# three-role env exported into loop argv indirectly via parent env — launches happened
if grep -q 'fake-runner' "$CALLS/launches.log"; then
  ok "builder runner recorded on launch"
else
  bad "runner not in launch log"
fi

# idempotent status after start
out=$(run_fleet --status) || true
echo "$out" | grep -q 'docs' && ok "status lists docs lane" || bad "status missing docs lane"

# halt
out=$(run_fleet --halt) || { bad "halt failed: $out"; }
echo "$out" | grep -q 'profile=gibson-dogfood' && ok "halt prints profile identity" || bad "halt missing identity"
[[ -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] && ok "halt wrote gibson/HALT" || bad "HALT missing after --halt"

# --- Chatterbuilt-shaped scopes (fixture only — not live queues) -----------
echo "Chatterbuilt-shaped fixture (synthetic issues)"
reset_calls
TARGET=$(setup_target_repo chatter acme/chatterbuilt)
PROF="$ROOT/profiles/chatter.profile"
write_profile "$PROF" \
  "version=1" \
  "name=chatterbuilt-shaped" \
  "repo=$TARGET" \
  "slug=acme/chatterbuilt" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=mcpcore|1001,1002|apps/mcp/lib/** apps/mcp/app/**|MCP server lane (fixture)" \
  "lane=growth|1003|marketing/app/** marketing/components/**|Marketing surface (fixture)" \
  "lane=docs|1004|docs/**|Docs lane (fixture)"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "chatter-shaped start failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "3" ]] && ok "chatterbuilt-shaped fixture launched 3 lanes" || bad "expected 3 launches, got $lc"

# reserved runner field accepted, not used for routing
echo "forwards-compatible runner field (#141 reserved)"
reset_calls
TARGET=$(setup_target_repo rfield acme/widget)
PROF="$ROOT/profiles/runner-field.profile"
write_profile "$PROF" \
  "version=1" \
  "name=runner-field" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=a|11|docs/**|docs only|hermes"
export FLEET_PROFILE="$PROF"
out=$(run_fleet --start) || { bad "runner field rejected: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "lane runner field accepted (reserved, not routed)" || bad "runner field launch count=$lc"

# --- FLEET_PROFILE env + --profile flag ------------------------------------
echo "profile selector"
reset_calls
TARGET=$(setup_target_repo sel acme/widget)
PROF="$ROOT/profiles/sel.profile"
write_profile "$PROF" \
  "version=1" \
  "name=selector" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=only|7|docs/**|docs"
unset FLEET_PROFILE || true
out=$(run_fleet --profile "$PROF" --status) || true
echo "$out" | grep -q 'profile=selector' && ok "--profile PATH works" || bad "--profile failed: $out"

# relative profile path refused
out=$(run_fleet --profile "relative/path.profile" --status 2>&1) && bad "relative profile should fail" || {
  echo "$out" | grep -qi 'absolute' && ok "relative profile path refused" || bad "unclear relative fail: $out"
}

# missing profile
out=$(run_fleet --status 2>&1) && bad "missing profile should fail" || {
  echo "$out" | grep -qi 'profile' && ok "missing profile refused" || bad "unclear missing profile: $out"
}

# --- hostile / malformed profiles (zero launches) --------------------------
echo "hostile / malformed profiles"
zero_launch_case() {
  local label="$1"
  shift
  reset_calls
  local before after
  before=$(echo "$(launch_count)" | tr -d '[:space:]')
  out=$(run_fleet "$@" 2>&1) && {
    bad "$label: expected failure but succeeded: $out"
    return
  }
  after=$(echo "$(launch_count)" | tr -d '[:space:]')
  if [[ "$after" == "0" || "$after" == "$before" ]]; then
    ok "$label (fail-closed, zero launches)"
  else
    bad "$label: launched $after runners on failure path"
  fi
}

TARGET=$(setup_target_repo badbase acme/widget)

# unknown field
PROF="$ROOT/profiles/unknown.profile"
write_profile "$PROF" \
  "version=1" \
  "name=u" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "evil=1" \
  "lane=a|1|docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "unknown field" --start

# bad version
PROF="$ROOT/profiles/ver.profile"
write_profile "$PROF" \
  "version=99" \
  "name=v" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|1|docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "unsupported version" --start

# non-absolute repo
PROF="$ROOT/profiles/relrepo.profile"
write_profile "$PROF" \
  "version=1" \
  "name=rr" \
  "repo=relative/path" \
  "slug=acme/widget" \
  "lane=a|1|docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "non-absolute repo" --start

# path with ..
PROF="$ROOT/profiles/dotdot.profile"
write_profile "$PROF" \
  "version=1" \
  "name=dd" \
  "repo=$ROOT/targets/../targets/badbase" \
  "slug=acme/widget" \
  "lane=a|1|docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "repo path with .." --start

# empty queue
PROF="$ROOT/profiles/emptyq.profile"
write_profile "$PROF" \
  "version=1" \
  "name=eq" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a||docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "empty queue" --start

# empty scope
PROF="$ROOT/profiles/emptys.profile"
write_profile "$PROF" \
  "version=1" \
  "name=es" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|1||x"
export FLEET_PROFILE="$PROF"
zero_launch_case "empty scope" --start

# empty intent
PROF="$ROOT/profiles/emptyi.profile"
write_profile "$PROF" \
  "version=1" \
  "name=ei" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|1|docs/**|"
export FLEET_PROFILE="$PROF"
zero_launch_case "empty intent" --start

# invalid issue id
PROF="$ROOT/profiles/badiss.profile"
write_profile "$PROF" \
  "version=1" \
  "name=bi" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|0abc|docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "invalid issue id" --start

# duplicate lane ids
PROF="$ROOT/profiles/duplane.profile"
write_profile "$PROF" \
  "version=1" \
  "name=dl" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|1|docs/**|x" \
  "lane=a|2|scripts/**|y"
export FLEET_PROFILE="$PROF"
zero_launch_case "duplicate lane ids" --start

# duplicate issue across lanes
PROF="$ROOT/profiles/dupiss.profile"
write_profile "$PROF" \
  "version=1" \
  "name=di" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|5|docs/**|x" \
  "lane=b|5|scripts/**|y"
export FLEET_PROFILE="$PROF"
zero_launch_case "duplicate issue across lanes" --start

# scope overlap (path containment, not mere string equality)
PROF="$ROOT/profiles/overlap.profile"
write_profile "$PROF" \
  "version=1" \
  "name=ov" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|1|apps/mcp/**|x" \
  "lane=b|2|apps/mcp/lib/**|y"
export FLEET_PROFILE="$PROF"
zero_launch_case "scope overlap containment" --start

# exact-equal scopes
PROF="$ROOT/profiles/overlap2.profile"
write_profile "$PROF" \
  "version=1" \
  "name=ov2" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|1|docs/**|x" \
  "lane=b|2|docs/**|y"
export FLEET_PROFILE="$PROF"
zero_launch_case "scope overlap exact" --start

# wrong origin slug
PROF="$ROOT/profiles/wrongslug.profile"
write_profile "$PROF" \
  "version=1" \
  "name=ws" \
  "repo=$TARGET" \
  "slug=other/repo" \
  "lane=a|1|docs/**|x"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
zero_launch_case "wrong origin slug" --start

# dirty canonical checkout
DIRTY=$(setup_target_repo dirty acme/widget)
echo "uncommitted" > "$DIRTY/wip.txt"
PROF="$ROOT/profiles/dirty.profile"
write_profile "$PROF" \
  "version=1" \
  "name=dirty" \
  "repo=$DIRTY" \
  "slug=acme/widget" \
  "lane=a|1|docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "dirty checkout" --start

# missing issue
PROF="$ROOT/profiles/miss.profile"
write_profile "$PROF" \
  "version=1" \
  "name=miss" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|999|docs/**|x"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=missing
zero_launch_case "missing issue" --start

# closed issue
export GH_STUB_MODE=closed
PROF="$ROOT/profiles/closed.profile"
write_profile "$PROF" \
  "version=1" \
  "name=cl" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|3|docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "closed issue" --start

# gated labels
for mode in gated-needs-mark gated-tier-c gated-decision gated-blocked gated-halt; do
  export GH_STUB_MODE="$mode"
  PROF="$ROOT/profiles/${mode}.profile"
  write_profile "$PROF" \
    "version=1" \
    "name=$mode" \
    "repo=$TARGET" \
    "slug=acme/widget" \
    "lane=a|8|docs/**|x"
  export FLEET_PROFILE="$PROF"
  zero_launch_case "gated label ($mode)" --start
done

# claims conflict (agent-claimed)
export GH_STUB_MODE=claimed
PROF="$ROOT/profiles/claimed.profile"
write_profile "$PROF" \
  "version=1" \
  "name=claimed" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|12|docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "agent-claimed conflict" --start

# PR conflict
export GH_STUB_MODE=pr-conflict
PROF="$ROOT/profiles/prconf.profile"
write_profile "$PROF" \
  "version=1" \
  "name=prconf" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=a|42|docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "open PR conflict" --start

# wt-* lane id refused
export GH_STUB_MODE=ok
PROF="$ROOT/profiles/wtid.profile"
write_profile "$PROF" \
  "version=1" \
  "name=wtid" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "lane=wt-docs|1|docs/**|x"
export FLEET_PROFILE="$PROF"
zero_launch_case "wt-* lane id refused" --start

# --- template + docs present -----------------------------------------------
echo "templates and docs"
[[ -f "$REPO_ROOT/templates/fleet/profile.v1.example" ]] && ok "template profile.v1.example present" \
  || bad "missing templates/fleet/profile.v1.example"
[[ -f "$REPO_ROOT/templates/fleet/README.md" ]] && ok "templates/fleet/README.md present" \
  || bad "missing templates/fleet/README.md"
grep -q 'loop-fleet' "$REPO_ROOT/scripts/README.md" && ok "scripts/README.md documents loop-fleet" \
  || bad "scripts/README.md missing loop-fleet"
grep -q 'FLEET_PROFILE\|fleet profile\|loop-fleet' "$REPO_ROOT/playbooks/dogfood-overnight.md" \
  && ok "dogfood-overnight mentions fleet profiles" \
  || bad "dogfood-overnight missing fleet profile docs"
grep -q 'loop-fleet\|FLEET_PROFILE\|fleet profile' "$REPO_ROOT/adapters/grok/README.md" \
  && ok "adapters/grok README mentions fleet profiles" \
  || bad "adapters/grok README missing fleet profile docs"
# template must not embed live home paths or real Chatterbuilt queues
if grep -Eiq '/Users/|/home/mrhinkle|326,26,3|355,356,357' "$REPO_ROOT/templates/fleet/profile.v1.example" 2>/dev/null; then
  bad "template embeds private paths or live Chatterbuilt queues"
else
  ok "template free of private paths / live Chatterbuilt queues"
fi

# --- three-role: builder cannot be sole reviewer ----------------------------
echo "three-role separation"
reset_calls
TARGET=$(setup_target_repo roles acme/widget)
PROF="$ROOT/profiles/roles.profile"
write_profile "$PROF" \
  "version=1" \
  "name=roles" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=a|1|docs/**|x"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
# override REVIEWER_CMD to same runner family without cross-vendor marker
out=$(
  env \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" \
    REVIEWER_CMD="fake-runner -p review" \
    RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 \
    GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "same-runner reviewer should fail" || {
  echo "$out" | grep -qi 'REVIEWER_CMD\|grading\|own work' && ok "self-review refused" || bad "unclear self-review fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "self-review path launched zero runners" || bad "self-review launched $lc"

# --- FLEET_PROFILE via env only --------------------------------------------
echo "FLEET_PROFILE env"
reset_calls
TARGET=$(setup_target_repo envp acme/widget)
PROF="$ROOT/profiles/envp.profile"
write_profile "$PROF" \
  "version=1" \
  "name=envp" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=a|1|docs/**|x"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "FLEET_PROFILE env start failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "FLEET_PROFILE env selects profile" || bad "env profile launches=$lc"

# --- pidfile identity: live but unrelated PID must not count as the lane ----
echo "pidfile identity (no PID reuse false-positive)"
reset_calls
TARGET=$(setup_target_repo pidid acme/widget)
PROF="$ROOT/profiles/pidid.profile"
write_profile "$PROF" \
  "version=1" \
  "name=pidid" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|21|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
# First start creates the lane base (sync launch; no live pid left).
out=$(run_fleet --start) || { bad "pidid start failed: $out"; }
# Plant a pidfile pointing at a live but unrelated process (this shell).
# Status must NOT report "running" — kill -0 alone would false-positive.
printf '%s\n' "$$" > "$LOG_DIR/docs.pid"
out=$(run_fleet --status) || true
if echo "$out" | grep -E '^docs[[:space:]]' | grep -q 'running'; then
  bad "unrelated live PID treated as lane (status=$out)"
else
  ok "unrelated live PID not treated as lane"
fi
# --start must still relaunch (pidfile identity failed → not "already running").
# Keep the existing lane base; only clear the launch log and plant a bad pidfile.
: > "$CALLS/launches.log"
printf '%s\n' "$$" > "$LOG_DIR/docs.pid"
out=$(run_fleet --start) || { bad "pidid relaunch start failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
if [[ "$lc" == "1" ]]; then
  ok "stale/unrelated pidfile does not skip relaunch"
else
  bad "expected relaunch despite unrelated pidfile, got launches=$lc out=$out"
fi
# clean planted pidfile residue
rm -f "$LOG_DIR/docs.pid"

# --- #1 healthy repeated --start must not clobber HALT / live state --------
echo "healthy repeated --start preserves HALT + state"
reset_calls
TARGET=$(setup_target_repo hstart acme/widget)
PROF="$ROOT/profiles/hstart.profile"
write_profile "$PROF" \
  "version=1" \
  "name=hstart" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|31|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "hstart initial start failed: $out"; }
# Plant non-initial live state + deliberate HALT + a "healthy" pidfile whose
# command line matches this lane (sleep with lane path + loop.sh in argv).
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-01-01T00:00:00Z
issue: 77
pr: 88
hat: reviewer
next_hat: release
round: 4
parked: false
next_action: planted non-initial state for healthy restart sensor
notes: >
  preserve me
STATE
mkdir -p "$ROOT/fleet/lane-docs/gibson"
touch "$ROOT/fleet/lane-docs/gibson/HALT"
# Live process whose argv contains the lane dir and loop.sh so lane_pid_alive
# treats it as this lane (identity check, not mere kill -0).
# $0/$1 after -c appear in ps command= on macOS/Linux.
bash -c 'while true; do sleep 30; done' \
  "$ROOT/gibson/scripts/loop.sh" \
  "$ROOT/fleet/lane-docs" &
HEALTHY_PID=$!
printf '%s\n' "$HEALTHY_PID" > "$LOG_DIR/docs.pid"
# Prove identity match before re-start
if pid_check=$(
  env GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="$RUNNER" REVIEWER_CMD="$REVIEWER_CMD" RELEASE_CMD="$RELEASE_CMD" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" FLEET_PROFILE="$PROF" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    "$FLEET" --status 2>&1
); then
  :
fi
echo "$pid_check" | grep -E '^docs[[:space:]]' | grep -q 'running' \
  && ok "planted healthy lane reports running" \
  || bad "planted healthy lane not running: $pid_check"
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "healthy re-start failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "healthy re-start launched zero new runners" \
  || bad "healthy re-start launched $lc (expected 0)"
[[ -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] && ok "healthy re-start preserved HALT" \
  || bad "healthy re-start removed HALT"
grep -q '^issue: 77$' "$STATE_FILE" && grep -q '^pr: 88$' "$STATE_FILE" \
  && grep -q '^hat: reviewer$' "$STATE_FILE" && grep -q '^round: 4$' "$STATE_FILE" \
  && ok "healthy re-start preserved issue/pr/hat/round" \
  || bad "healthy re-start clobbered state: $(cat "$STATE_FILE")"
# cleanup planted sleeper
kill "$HEALTHY_PID" 2>/dev/null || true
wait "$HEALTHY_PID" 2>/dev/null || true
rm -f "$LOG_DIR/docs.pid"

# --- #1b dead-lane relaunch preserves valid state (does not re-seed) --------
echo "dead-lane relaunch preserves state"
reset_calls
TARGET=$(setup_target_repo dstart acme/widget)
PROF="$ROOT/profiles/dstart.profile"
write_profile "$PROF" \
  "version=1" \
  "name=dstart" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|32|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "dstart initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-01-02T00:00:00Z
issue: 55
pr: 66
hat: release
next_hat: builder
round: 9
parked: false
next_action: planted dead-lane state
notes: >
  preserve on relaunch
STATE
touch "$ROOT/fleet/lane-docs/gibson/HALT"
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "dead-lane relaunch failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "dead-lane relaunch launched once" \
  || bad "dead-lane relaunch launches=$lc"
grep -q '^issue: 55$' "$STATE_FILE" && grep -q '^pr: 66$' "$STATE_FILE" \
  && grep -q '^hat: release$' "$STATE_FILE" && grep -q '^round: 9$' "$STATE_FILE" \
  && ok "dead-lane relaunch preserved issue/pr/hat/round" \
  || bad "dead-lane relaunch reset state: $(cat "$STATE_FILE")"
[[ ! -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] && ok "dead-lane relaunch cleared HALT" \
  || bad "dead-lane relaunch left HALT in place"

# --- #2 watchdog must not inject via profile path / shell source ------------
echo "watchdog argv-only (hostile profile path)"
# Static proof: watchdog uses fixed bash -c body + positional params, not
# interpolated PROFILE_PATH / SLEEP_CMD into shell source.
if grep -n 'bash -c' "$FLEET" | grep -E '\$SLEEP_CMD|\$PROFILE_PATH|\$DEADLINE' >/dev/null 2>&1; then
  bad "watchdog still interpolates data into bash -c source"
else
  ok "watchdog bash -c has no interpolated SLEEP_CMD/PROFILE_PATH"
fi
# Runtime: hostile profile path with spaces/quotes/;/$ must not execute a marker.
reset_calls
TARGET=$(setup_target_repo inj acme/widget)
# Create hostile directory + profile name
HOSTILE_DIR="$ROOT/profiles/hostile name; echo INJECTED > $ROOT/injection-marker; \$HOME"
mkdir -p "$HOSTILE_DIR"
PROF="$HOSTILE_DIR/p\".profile"
write_profile "$PROF" \
  "version=1" \
  "name=inj" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "deadline_seconds=1" \
  "lane=docs|33|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
rm -f "$ROOT/injection-marker"
# Run with real (short) watchdog, sync launch, no skip of watchdog.
# SLEEP_CMD=true so watchdog body proceeds immediately to --halt.
out=$(
  env \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="$RUNNER" REVIEWER_CMD="$REVIEWER_CMD" RELEASE_CMD="$RELEASE_CMD" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=1 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=0 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 \
    GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || true
# Give watchdog a moment to fire halt
sleep 1
if [[ -f "$ROOT/injection-marker" ]]; then
  bad "hostile profile path executed marker command (injection)"
else
  ok "hostile profile path did not execute marker command"
fi
# restore sensor defaults
export FLEET_NO_WATCHDOG=1
export FLEET_SYNC_LAUNCH=1
export SLEEP_CMD=true

# --- #3 remote default branch: trunk + decoy origin/main -------------------
echo "remote default branch pin (trunk + decoy main)"
reset_calls
# Local bare remote so ls-remote works offline; GitHub-shaped URL kept for slug
# via a separate push URL is awkward — use FLEET_SKIP_FETCH + local origin/HEAD.
TARGET=$(setup_target_repo trunkpin acme/widget trunk)
# Create decoy origin/main at a *different* commit than trunk tip.
TRUNK_SHA=$($GIT -C "$TARGET" rev-parse HEAD)
echo "decoy" > "$TARGET/decoy.txt"
$GIT -C "$TARGET" add decoy.txt
$GIT -C "$TARGET" commit -q -m "decoy main commit"
DECOY_SHA=$($GIT -C "$TARGET" rev-parse HEAD)
# Move trunk tip back: create origin/trunk at original, origin/main at decoy
$GIT -C "$TARGET" update-ref refs/remotes/origin/trunk "$TRUNK_SHA"
$GIT -C "$TARGET" update-ref refs/remotes/origin/main "$DECOY_SHA"
$GIT -C "$TARGET" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
# Local branch still on decoy commit is fine (dirty? no, committed)
# Canonical must be clean — we're on decoy branch tip; that's fine.
PROF="$ROOT/profiles/trunkpin.profile"
write_profile "$PROF" \
  "version=1" \
  "name=trunkpin" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|34|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "trunkpin start failed: $out"; }
LANE_HEAD=$($GIT -C "$ROOT/fleet/lane-docs" rev-parse HEAD 2>/dev/null || echo missing)
if [[ "$LANE_HEAD" == "$TRUNK_SHA" ]]; then
  ok "lane base pinned to trunk tip (not decoy origin/main)"
else
  bad "lane base HEAD=$LANE_HEAD expected trunk=$TRUNK_SHA decoy=$DECOY_SHA out=$out"
fi
# Live path (FLEET_SKIP_FETCH=0): controlled git stub for fetch + ls-remote so
# we never hit the network, while proving the driver uses ls-remote --symref
# (not origin/main guessing) and pins the worktree to that tip.
reset_calls
LIVE=$(setup_target_repo trunklive acme/widget main)
# Plant trunk tip + decoy main as real commits in the object store.
echo "trunk-base" > "$LIVE/trunk-marker.txt"
$GIT -C "$LIVE" add trunk-marker.txt
$GIT -C "$LIVE" commit -q -m "trunk tip"
TRUNK_LIVE=$($GIT -C "$LIVE" rev-parse HEAD)
echo "decoy-main" > "$LIVE/decoy-marker.txt"
$GIT -C "$LIVE" add decoy-marker.txt
$GIT -C "$LIVE" commit -q -m "decoy main tip"
DECOY_LIVE=$($GIT -C "$LIVE" rev-parse HEAD)
# Local decoy: origin/main points at decoy; no origin/trunk tracking yet.
# Driver must learn trunk from ls-remote --symref, not from origin/main.
$GIT -C "$LIVE" update-ref refs/remotes/origin/main "$DECOY_LIVE"
$GIT -C "$LIVE" update-ref refs/remotes/origin/trunk "$TRUNK_LIVE"
# Mis-point local origin/HEAD at decoy main — live path must ignore it.
$GIT -C "$LIVE" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
# Canonical clean: reset index/worktree to decoy tip (already there).
REAL_GIT=$(command -v git)
cat > "$BIN/git" <<STUB
#!/usr/bin/env bash
# Controlled offline stub for live default-branch resolution.
# - fetch origin: no-op success (objects already local)
# - ls-remote --symref origin HEAD: advertise trunk (not main)
# - ls-remote origin refs/heads/trunk: trunk tip
# - everything else: real git
args=("\$@")
# Find subcommand after possible -C <path> and -c key=val
i=0
n=\$#
set -- "\${args[@]}"
while [[ \$i -lt \$n ]]; do
  a="\${args[\$i]}"
  case "\$a" in
    -C) i=\$((i+2)); continue ;;
    -c) i=\$((i+2)); continue ;;
    -*) i=\$((i+1)); continue ;;
    *) break ;;
  esac
done
cmd="\${args[\$i]:-}"
if [[ "\$cmd" == "fetch" ]]; then
  exit 0
fi
if [[ "\$cmd" == "ls-remote" ]]; then
  # Detect --symref origin HEAD
  has_symref=0
  has_head=0
  has_trunk_ref=0
  for a in "\${args[@]}"; do
    [[ "\$a" == "--symref" ]] && has_symref=1
    [[ "\$a" == "HEAD" ]] && has_head=1
    [[ "\$a" == "refs/heads/trunk" ]] && has_trunk_ref=1
  done
  if [[ \$has_symref -eq 1 && \$has_head -eq 1 ]]; then
    printf 'ref: refs/heads/trunk\tHEAD\n'
    printf '%s\tHEAD\n' "$TRUNK_LIVE"
    exit 0
  fi
  if [[ \$has_trunk_ref -eq 1 ]]; then
    printf '%s\trefs/heads/trunk\n' "$TRUNK_LIVE"
    exit 0
  fi
fi
exec "$REAL_GIT" "\${args[@]}"
STUB
chmod +x "$BIN/git"
PROF="$ROOT/profiles/trunklive.profile"
write_profile "$PROF" \
  "version=1" \
  "name=trunklive" \
  "repo=$LIVE" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|35|docs/**|docs only"
export FLEET_PROFILE="$PROF"
out=$(
  env \
    PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="$RUNNER" REVIEWER_CMD="$REVIEWER_CMD" RELEASE_CMD="$RELEASE_CMD" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=0 \
    FLEET_FETCH_TIMEOUT=15 \
    GIT_TERMINAL_PROMPT=0 \
    GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || { bad "trunklive start failed: $out"; out=""; }
LANE_HEAD=$(PATH="$BIN:$PATH" $GIT -C "$ROOT/fleet/lane-docs" rev-parse HEAD 2>/dev/null || echo missing)
# Use real git for rev-parse of lane (stub may confuse -C parsing if still on PATH)
LANE_HEAD=$("$REAL_GIT" -C "$ROOT/fleet/lane-docs" rev-parse HEAD 2>/dev/null || echo missing)
if [[ "$LANE_HEAD" == "$TRUNK_LIVE" ]]; then
  ok "live ls-remote pin uses trunk tip (decoy main ignored)"
else
  bad "live lane HEAD=$LANE_HEAD expected trunk=$TRUNK_LIVE decoy=$DECOY_LIVE out=$out"
fi
rm -f "$BIN/git"

# --- #4 wall-clock fetch timeout + child cleanup ---------------------------
echo "wall-clock fetch timeout"
reset_calls
TARGET=$(setup_target_repo hangfetch acme/widget)
PROF="$ROOT/profiles/hangfetch.profile"
write_profile "$PROF" \
  "version=1" \
  "name=hangfetch" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|36|docs/**|docs only"
# PATH git stub: hang on fetch, otherwise delegate to real git
REAL_GIT=$(command -v git)
cat > "$BIN/git" <<STUB
#!/usr/bin/env bash
# hang on fetch for wall-timeout sensor; else real git
for a in "\$@"; do
  if [[ "\$a" == "fetch" ]]; then
    # marker so we can detect the child; hang until killed
    echo "\$\$" > "$CALLS/hang-fetch.pid"
    while true; do sleep 30; done
    exit 0
  fi
done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$BIN/git"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
rm -f "$CALLS/hang-fetch.pid"
out=$(
  env \
    PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="$RUNNER" REVIEWER_CMD="$REVIEWER_CMD" RELEASE_CMD="$RELEASE_CMD" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=0 \
    FLEET_FETCH_TIMEOUT=2 \
    GIT_TERMINAL_PROMPT=0 \
    GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "hanging fetch should fail closed: $out" || {
  echo "$out" | grep -qi 'timeout\|wall-clock\|timed out\|exceeded' \
    && ok "hanging fetch fails closed on wall timeout" \
    || bad "unclear hang-fetch fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "hanging fetch launched zero runners" || bad "hang-fetch launched $lc"
# Child cleanup: hanging pid must not remain
if [[ -f "$CALLS/hang-fetch.pid" ]]; then
  hpid=$(tr -d '[:space:]' < "$CALLS/hang-fetch.pid")
  if [[ -n "$hpid" ]] && kill -0 "$hpid" 2>/dev/null; then
    bad "hanging fetch child pid $hpid still alive after timeout"
    kill -KILL "$hpid" 2>/dev/null || true
  else
    ok "hanging fetch child cleaned up after timeout"
  fi
else
  # process may have been killed before writing pid — still accept if zero launches
  ok "hanging fetch child cleaned up (no residual pid file / already reaped)"
fi
# remove git stub so later tests use real git
rm -f "$BIN/git"

# --- #5 provider identity: path / alias / misleading trailing args ----------
echo "provider identity normalization"
reset_calls
TARGET=$(setup_target_repo provid acme/widget)
PROF="$ROOT/profiles/provid.profile"
write_profile "$PROF" \
  "version=1" \
  "name=provid" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|37|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
# Absolute path same provider as runner (fake-runner)
out=$(
  env \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" \
    REVIEWER_CMD="$BIN/fake-runner review-me" \
    RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "absolute same-provider reviewer should fail" || {
  echo "$out" | grep -qi 'REVIEWER_CMD\|same provider\|provider' \
    && ok "absolute same-provider reviewer refused" \
    || bad "unclear abs same-provider fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "absolute same-provider path launched zero" || bad "abs path launched $lc"

# Relative path same provider for release
: > "$CALLS/launches.log"
# Create a relative-looking path via symlink name under BIN (on PATH as ./ style)
# Use absolute path to a claude-stub that collides with REVIEWER being codex-stub
# and RELEASE being path to same as runner — test release path identity.
out=$(
  env \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" \
    REVIEWER_CMD="codex-stub review" \
    RELEASE_CMD="$BIN/fake-runner do-release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "absolute same-provider release should fail" || {
  echo "$out" | grep -qi 'RELEASE_CMD\|third identity\|same provider\|provider' \
    && ok "absolute same-provider release refused" \
    || bad "unclear abs same-provider release fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "absolute same-provider release launched zero" || bad "abs release launched $lc"

# Misleading trailing arg: first token is fake-runner, word "codex-stub" in args
: > "$CALLS/launches.log"
out=$(
  env \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" \
    REVIEWER_CMD="fake-runner --as codex-stub review" \
    RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "misleading trailing codex arg should fail" || {
  echo "$out" | grep -qi 'REVIEWER_CMD\|same provider\|provider' \
    && ok "misleading trailing vendor word refused" \
    || bad "unclear misleading-arg fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "misleading trailing arg launched zero" || bad "misleading launched $lc"

# Relative path form: ./fake-runner as reviewer
: > "$CALLS/launches.log"
(
  CDPATH='' cd "$BIN" || exit 1
  out=$(
    env \
      PATH="$BIN:$PATH" \
      GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
      RUNNER="fake-runner" \
      REVIEWER_CMD="./fake-runner review" \
      RELEASE_CMD="claude-stub release" \
      GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
      DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
      FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
      GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
      "$FLEET" --start 2>&1
  ) && bad "relative same-provider reviewer should fail" || {
    echo "$out" | grep -qi 'REVIEWER_CMD\|same provider\|provider' \
      && ok "relative same-provider reviewer refused" \
      || bad "unclear relative same-provider fail: $out"
  }
)
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "relative same-provider launched zero" || bad "relative launched $lc"

# Valid Grok-shaped separation still works (fake-runner / codex-stub / claude-stub)
: > "$CALLS/launches.log"
out=$(
  env \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" \
    REVIEWER_CMD="codex-stub review" \
    RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || { bad "valid three-role separation failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "valid three-role separation still launches" \
  || bad "valid three-role launches=$lc out=$out"

# --- #6 WIP doctrine: four lanes fail preflight, zero launches -------------
echo "WIP max 3 lanes"
reset_calls
TARGET=$(setup_target_repo fourlane acme/widget)
PROF="$ROOT/profiles/fourlane.profile"
write_profile "$PROF" \
  "version=1" \
  "name=fourlane" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=a|1|docs/**|a" \
  "lane=b|2|scripts/**|b" \
  "lane=c|3|apps/mcp/lib/**|c" \
  "lane=d|4|marketing/app/**|d"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
zero_launch_case "four-lane profile exceeds WIP" --start
# message mentions WIP / 3 lanes
out=$(run_fleet --start 2>&1) && true
echo "$out" | grep -qiE 'WIP|1-3|3 lanes|allows 1' \
  && ok "four-lane error names WIP limit" \
  || bad "four-lane error unclear: $out"

# --- declarative parse: profile must never be sourced / eval'd --------------
echo "declarative profile load"
if grep -E 'source[[:space:]]+.*PROFILE|source[[:space:]]+"\$path"|eval[[:space:]]+.*profile|\.[[:space:]]+"\$path"|\.[[:space:]]+\$path' \
  "$FLEET" >/dev/null 2>&1; then
  bad "loop-fleet.sh appears to source/eval profile content"
else
  ok "profile load has no source/eval of profile path"
fi

echo
echo "loop-fleet.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
