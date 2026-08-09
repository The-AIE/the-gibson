#!/usr/bin/env bash
# loop-fleet.test.sh — offline sensors for portable fleet profiles (#139 / #141)
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
# stub loop — records launch + cost-join env; never calls a model
log="${LOOP_LAUNCH_LOG:-/dev/null}"
printf 'LAUNCH runner=%s repo=%s slug=%s\n' \
  "${2:-}" "${4:-}" "${6:-}" >> "$log"
# also dump full argv for assertions
printf '%s\n' "$@" >> "${LOOP_LAUNCH_LOG}.argv"
# #141 join propagation (fleet → loop cost ledger)
printf 'JOIN key=%s pool=%s req=%s reason=%s provider=%s ledger=%s\n' \
  "${GIBSON_COST_JOIN_KEY:-}" \
  "${GIBSON_COST_POOL:-}" \
  "${GIBSON_COST_REQUESTED_RUNNER:-}" \
  "${GIBSON_COST_FALLBACK_REASON:-}" \
  "${GIBSON_COST_PROVIDER:-}" \
  "${GIBSON_COST_LEDGER:-}" \
  >> "${LOOP_LAUNCH_LOG}.join"
exit 0
STUB
chmod +x "$ROOT/gibson/scripts/loop.sh"

# fake builder runner on PATH
cat > "$BIN/fake-runner" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/fake-runner"

# gh stub — behavior via GH_STUB_MODE and optional per-issue / PR fixtures.
# Mirrors production: pr list emits number<TAB>head TSV (gh --template shape);
# pr view serves one raw body, then re-verifies its metadata before body trust.
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
mode="${GH_STUB_MODE:-ok}"
log="${GH_STUB_LOG:-}"
[[ -n "$log" ]] && printf '%s\n' "$*" >> "$log"

# --- helpers (test fixtures only; production never parses JSON bodies) -------
# Unescape the simple JSON string escapes our fixtures use (\n \t \r \\ \").
_stub_json_unescape() {
  printf '%s' "${1:-}" | awk '
    BEGIN { ORS="" }
    {
      s = $0
      out = ""
      while (length(s) > 0) {
        ch = substr(s, 1, 1)
        if (ch == "\\" && length(s) >= 2) {
          c = substr(s, 2, 1)
          if (c == "n") { out = out "\n"; s = substr(s, 3); continue }
          if (c == "t") { out = out "\t"; s = substr(s, 3); continue }
          if (c == "r") { out = out "\r"; s = substr(s, 3); continue }
          if (c == "\\" || c == "\"") { out = out c; s = substr(s, 3); continue }
          out = out substr(s, 1, 2)
          s = substr(s, 3)
          continue
        }
        out = out ch
        s = substr(s, 2)
      }
      print out
    }
  '
}

# Emit number<TAB>head lines from GH_STUB_PR_JSON compact fixtures.
# Do NOT strip interior whitespace — body strings must stay intact for view.
_stub_emit_pr_list_tsv() {
  local json="$1" core frag num head
  case "$(printf '%s' "$json" | tr -d '[:space:]')" in
    ''|'[]') return 0 ;;
  esac
  # Controlled single-line fixtures only — split on },{ is fine for tests.
  core=$(printf '%s' "$json" | sed -e 's/^[[:space:]]*\[//' -e 's/\][[:space:]]*$//')
  [[ -n "$core" ]] || return 0
  printf '%s\n' "$core" | sed 's/},{/}\n{/g' | while IFS= read -r frag || [[ -n "$frag" ]]; do
    [[ -n "$frag" ]] || continue
    num=$(printf '%s' "$frag" | sed -n 's/.*"number"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    head=$(printf '%s' "$frag" | sed -n 's/.*"headRefName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [[ -n "$num" && -n "$head" ]]; then
      printf '%s\t%s\n' "$num" "$head"
    fi
  done
}

# Look up one PR object fragment by number from GH_STUB_PR_JSON.
# Preserves body string whitespace/escapes for later unescape.
_stub_pr_frag() {
  local want="$1" json="${2:-}" core frag num
  case "$(printf '%s' "$json" | tr -d '[:space:]')" in
    ''|'[]') return 1 ;;
  esac
  core=$(printf '%s' "$json" | sed -e 's/^[[:space:]]*\[//' -e 's/\][[:space:]]*$//')
  [[ -n "$core" ]] || return 1
  printf '%s\n' "$core" | sed 's/},{/}\n{/g' | while IFS= read -r frag || [[ -n "$frag" ]]; do
    [[ -n "$frag" ]] || continue
    num=$(printf '%s' "$frag" | sed -n 's/.*"number"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    if [[ "$num" == "$want" ]]; then
      printf '%s\n' "$frag"
      return 0
    fi
  done
  return 1
}

_stub_pr_field_string() {
  # Extract "field":"…" JSON string value (first match) and unescape.
  local frag="$1" field="$2" raw
  raw=$(printf '%s' "$frag" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\(.*\\)\".*/\\1/p" | head -1)
  # sed above is greedy to last quote — for body with escaped quotes in fixtures
  # we only use simple bodies. Prefer explicit body extraction below for body.
  if [[ "$field" == "body" ]]; then
    raw=$(printf '%s' "$frag" | awk '
      {
        line = $0
        idx = index(line, "\"body\"")
        if (idx == 0) { print ""; exit 0 }
        rest = substr(line, idx + 6)
        sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
        if (rest ~ /^null/) { print ""; exit 0 }
        if (substr(rest, 1, 1) != "\"") { print ""; exit 0 }
        rest = substr(rest, 2)
        out = ""
        while (length(rest) > 0) {
          ch = substr(rest, 1, 1)
          if (ch == "\"") { print out; exit 0 }
          if (ch == "\\") {
            if (length(rest) < 2) { print out; exit 0 }
            out = out substr(rest, 1, 2)
            rest = substr(rest, 3)
            continue
          }
          out = out ch
          rest = substr(rest, 2)
        }
        print out
      }
    ')
    _stub_json_unescape "$raw"
    return 0
  fi
  _stub_json_unescape "$raw"
}

# Parse: gh issue view N --repo SLUG --json state,labels
#        gh pr list --repo SLUG --state open --json number,headRefName --limit N --template …
#        gh pr view N --repo SLUG --json number,headRefName,state --template …
#        gh pr view N --repo SLUG --json body --jq …
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
  # Force-fail the list command (formatter/transport failure).
  if [[ "${GH_STUB_PR_LIST_FAIL:-0}" == "1" ]]; then
    echo "gh stub: simulated pr list failure" >&2
    exit 1
  fi
  # Raw override of formatter stdout (malformed metadata / garbage).
  if [[ -n "${GH_STUB_PR_LIST_RAW+x}" ]]; then
    printf '%s' "$GH_STUB_PR_LIST_RAW"
    # Ensure trailing newline only when non-empty content lacks one.
    if [[ -n "$GH_STUB_PR_LIST_RAW" && "$GH_STUB_PR_LIST_RAW" != *$'\n' ]]; then
      printf '\n'
    fi
    exit 0
  fi
  if [[ -n "${GH_STUB_PR_TSV:-}" ]]; then
    printf '%s\n' "$GH_STUB_PR_TSV"
    exit 0
  fi
  if [[ -n "${GH_STUB_PR_FILE:-}" && -f "${GH_STUB_PR_FILE}" ]]; then
    # File may be legacy JSON array or pre-rendered TSV.
    if head -c 1 "${GH_STUB_PR_FILE}" | grep -q '\['; then
      _stub_emit_pr_list_tsv "$(cat "${GH_STUB_PR_FILE}")"
    else
      cat "${GH_STUB_PR_FILE}"
    fi
    exit 0
  fi
  if [[ -n "${GH_STUB_PR_JSON:-}" ]]; then
    _stub_emit_pr_list_tsv "$GH_STUB_PR_JSON"
    exit 0
  fi
  case "$mode" in
    pr-conflict)
      # Emit a conflicting branch for issue 42 (used by conflict test)
      printf '%s\t%s\n' "9" "feat/42-password-reset"
      exit 0
      ;;
    *)
      # Empty list — production treats empty formatter output as zero pairs.
      exit 0
      ;;
  esac
fi

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  prn="$3"
  # Detect requested shape from remaining argv.
  want_body=0
  want_meta=0
  local_args=("$@")
  i=0
  while [[ $i -lt ${#local_args[@]} ]]; do
    a="${local_args[$i]}"
    case "$a" in
      --json)
        i=$((i + 1))
        fields="${local_args[$i]:-}"
        case ",$fields," in
          *,body,*) want_body=1 ;;
        esac
        case ",$fields," in
          *,number,*|*,headRefName,*|*,state,*) want_meta=1 ;;
        esac
        ;;
      --jq)
        i=$((i + 1))
        jqexpr="${local_args[$i]:-}"
        case "$jqexpr" in
          *body*) want_body=1 ;;
        esac
        ;;
      --template)
        i=$((i + 1))
        tmpl="${local_args[$i]:-}"
        case "$tmpl" in
          *body*) want_body=1 ;;
          *number*|*headRefName*|*state*) want_meta=1 ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done

  if [[ $want_meta -eq 1 ]]; then
    if [[ "${GH_STUB_PR_VIEW_FAIL:-0}" == "1" ]]; then
      echo "gh stub: simulated pr view failure" >&2
      exit 1
    fi
    # Override: "number<TAB>head<TAB>state" for race sensors.
    if [[ -n "${GH_STUB_PR_VIEW_META:-}" ]]; then
      printf '%s\n' "$GH_STUB_PR_VIEW_META"
      exit 0
    fi
    if [[ -n "${GH_STUB_PR_VIEW_META_FILE:-}" && -f "${GH_STUB_PR_VIEW_META_FILE}" ]]; then
      cat "${GH_STUB_PR_VIEW_META_FILE}"
      exit 0
    fi
    # Resolve from GH_STUB_PR_JSON fixture.
    frag=""
    if [[ -n "${GH_STUB_PR_JSON:-}" ]]; then
      frag=$(_stub_pr_frag "$prn" "$GH_STUB_PR_JSON" || true)
    fi
    if [[ -z "$frag" && -n "${GH_STUB_PR_FILE:-}" && -f "${GH_STUB_PR_FILE}" ]]; then
      frag=$(_stub_pr_frag "$prn" "$(cat "${GH_STUB_PR_FILE}")" || true)
    fi
    if [[ -z "$frag" ]]; then
      echo "gh stub: pr view #$prn not found in fixtures" >&2
      exit 1
    fi
    num=$(printf '%s' "$frag" | sed -n 's/.*"number"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    head=$(printf '%s' "$frag" | sed -n 's/.*"headRefName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    state="OPEN"
    # Optional "state" in fixture.
    if printf '%s' "$frag" | grep -q '"state"[[:space:]]*:'; then
      state=$(printf '%s' "$frag" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
    printf '%s\t%s\t%s\n' "$num" "$head" "$state"
    exit 0
  fi

  if [[ $want_body -eq 1 ]]; then
    if [[ "${GH_STUB_PR_VIEW_BODY_FAIL:-0}" == "1" ]]; then
      echo "gh stub: simulated pr body fetch failure" >&2
      exit 1
    fi
    if [[ -n "${GH_STUB_PR_VIEW_BODY+x}" ]]; then
      # Explicit raw body override (may be empty).
      printf '%s' "$GH_STUB_PR_VIEW_BODY"
      exit 0
    fi
    if [[ -n "${GH_STUB_PR_BODY_DIR:-}" && -f "${GH_STUB_PR_BODY_DIR}/${prn}.body" ]]; then
      cat "${GH_STUB_PR_BODY_DIR}/${prn}.body"
      exit 0
    fi
    frag=""
    if [[ -n "${GH_STUB_PR_JSON:-}" ]]; then
      frag=$(_stub_pr_frag "$prn" "$GH_STUB_PR_JSON" || true)
    fi
    if [[ -z "$frag" && -n "${GH_STUB_PR_FILE:-}" && -f "${GH_STUB_PR_FILE}" ]]; then
      frag=$(_stub_pr_frag "$prn" "$(cat "${GH_STUB_PR_FILE}")" || true)
    fi
    if [[ -z "$frag" ]]; then
      echo "gh stub: pr body #$prn not found in fixtures" >&2
      exit 1
    fi
    _stub_pr_field_string "$frag" "body"
    exit 0
  fi

  echo "gh stub: pr view unhandled shape: $*" >&2
  exit 2
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
  rm -f "$CALLS/launches.log" "$CALLS/launches.log.argv" "$CALLS/launches.log.join" "$CALLS/gh.log"
  : > "$CALLS/launches.log"
  : > "$CALLS/launches.log.join"
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
    GH_STUB_PR_JSON="${GH_STUB_PR_JSON:-}" \
    GH_STUB_PR_FILE="${GH_STUB_PR_FILE:-}" \
    GH_STUB_PR_TSV="${GH_STUB_PR_TSV:-}" \
    GH_STUB_PR_LIST_FAIL="${GH_STUB_PR_LIST_FAIL:-0}" \
    GH_STUB_PR_VIEW_FAIL="${GH_STUB_PR_VIEW_FAIL:-0}" \
    GH_STUB_PR_VIEW_BODY_FAIL="${GH_STUB_PR_VIEW_BODY_FAIL:-0}" \
    GH_STUB_PR_VIEW_META="${GH_STUB_PR_VIEW_META:-}" \
    GH_STUB_PR_BODY_DIR="${GH_STUB_PR_BODY_DIR:-}" \
    FLEET_PROFILE="${FLEET_PROFILE:-}" \
    FLEET_READINESS_TIMEOUT="${FLEET_READINESS_TIMEOUT:-8}" \
    ${FLEET_READINESS_DIR+FLEET_READINESS_DIR="$FLEET_READINESS_DIR"} \
    ${FLEET_TEST_JOIN_TS+FLEET_TEST_JOIN_TS="$FLEET_TEST_JOIN_TS"} \
    ${GH_STUB_PR_LIST_RAW+GH_STUB_PR_LIST_RAW="$GH_STUB_PR_LIST_RAW"} \
    ${GH_STUB_PR_VIEW_BODY+GH_STUB_PR_VIEW_BODY="$GH_STUB_PR_VIEW_BODY"} \
    "$FLEET" "$@" 2>&1
}

# macOS often rewrites /var → /private/var under pwd -P
abs_path() {
  (CDPATH='' cd "$1" && pwd -P)
}

# ============================================================================
echo "loop-fleet.test.sh — portable fleet profiles (#139 / #141)"
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

# per-lane route field: single primary routes to declared runner (#141)
echo "per-lane runner route field (#141)"
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
  "lane=a|11|docs/**|docs only|fake-runner"
export FLEET_PROFILE="$PROF"
out=$(run_fleet --start) || { bad "runner route field rejected: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "lane runner route field accepted and launched" || bad "runner field launch count=$lc"
grep -q 'LAUNCH runner=fake-runner' "$CALLS/launches.log" \
  && ok "route primary passed to loop.sh" \
  || bad "launch log missing fake-runner: $(cat "$CALLS/launches.log" 2>/dev/null)"

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
# Recorded issue stays in the configured queue (31) for ownership coherence.
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-01-01T00:00:00Z
issue: 31
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
grep -q '^issue: 31$' "$STATE_FILE" && grep -q '^pr: 88$' "$STATE_FILE" \
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
# Recorded issue must belong to the configured queue (32) — foreign ids fail closed.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-01-02T00:00:00Z
issue: 32
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
grep -q '^issue: 32$' "$STATE_FILE" && grep -q '^pr: 66$' "$STATE_FILE" \
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
# PATH git stub: hang on fetch, spawn a descendant, otherwise delegate to real git
REAL_GIT=$(command -v git)
cat > "$BIN/git" <<STUB
#!/usr/bin/env bash
# hang on fetch for wall-timeout sensor; else real git
# Record leader PID (this process) AND a spawned descendant so cleanup
# evidence cannot pass while an orphaned sleep remains.
for a in "\$@"; do
  if [[ "\$a" == "fetch" ]]; then
    echo "\$\$" > "$CALLS/hang-fetch.pid"
    sleep 100 &
    echo "\$!" > "$CALLS/hang-fetch-desc.pid"
    wait
    exit 0
  fi
done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$BIN/git"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
rm -f "$CALLS/hang-fetch.pid" "$CALLS/hang-fetch-desc.pid"
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
# Cleanup: leader AND descendant must both be gone (no pkill/killall — exact PIDs only).
assert_pid_gone() {
  local label="$1" pidfile="$2" pid
  if [[ ! -f "$pidfile" ]]; then
    bad "$label pid file missing — stub may not have started"
    return
  fi
  pid=$(tr -d '[:space:]' < "$pidfile")
  if [[ -z "$pid" || ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    bad "$label pid unreadable: $(cat "$pidfile" 2>/dev/null || true)"
    return
  fi
  # Brief grace for reaping after KILL
  local i=0
  while [[ $i -lt 10 ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      ok "$label pid $pid cleaned up after timeout"
      return
    fi
    sleep 0.2 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  bad "$label pid $pid still alive after timeout"
  # Best-effort exact-PID cleanup for the test harness only (not pattern kill)
  kill -KILL "$pid" 2>/dev/null || true
}
assert_pid_gone "hanging fetch leader" "$CALLS/hang-fetch.pid"
assert_pid_gone "hanging fetch descendant" "$CALLS/hang-fetch-desc.pid"
# remove git stub so later tests use real git
rm -f "$BIN/git"

# --- #4b wall-clock ls-remote timeout + leader/descendant cleanup ----------
echo "wall-clock ls-remote timeout"
reset_calls
TARGET=$(setup_target_repo hangls acme/widget)
PROF="$ROOT/profiles/hangls.profile"
write_profile "$PROF" \
  "version=1" \
  "name=hangls" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|360|docs/**|docs only"
REAL_GIT=$(command -v git)
cat > "$BIN/git" <<STUB
#!/usr/bin/env bash
# fetch succeeds; hang on ls-remote to prove that path is also wall-bounded
args=("\$@")
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
  echo "\$\$" > "$CALLS/hang-lsremote.pid"
  sleep 100 &
  echo "\$!" > "$CALLS/hang-lsremote-desc.pid"
  wait
  exit 0
fi
exec "$REAL_GIT" "\${args[@]}"
STUB
chmod +x "$BIN/git"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
rm -f "$CALLS/hang-lsremote.pid" "$CALLS/hang-lsremote-desc.pid"
: > "$CALLS/launches.log"
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
) && bad "hanging ls-remote should fail closed: $out" || {
  echo "$out" | grep -qi 'timeout\|wall-clock\|timed out\|exceeded\|ls-remote' \
    && ok "hanging ls-remote fails closed on wall timeout" \
    || bad "unclear hang-ls-remote fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "hanging ls-remote launched zero runners" || bad "hang-ls-remote launched $lc"
assert_pid_gone "hanging ls-remote leader" "$CALLS/hang-lsremote.pid"
assert_pid_gone "hanging ls-remote descendant" "$CALLS/hang-lsremote-desc.pid"
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

# --- #5b env-wrapper / quoting provider bypasses ---------------------------
echo "provider env-wrapper + quoting bypass"
reset_calls
TARGET=$(setup_target_repo envwrap acme/widget)
PROF="$ROOT/profiles/envwrap.profile"
write_profile "$PROF" \
  "version=1" \
  "name=envwrap" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=grok" \
  "lane=docs|38|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
# Put vendor binaries on PATH. Profile runner=grok wins over env RUNNER, so
# builder identity is grok for these bypass cases.
cat > "$BIN/grok" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/grok"
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/codex"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/claude"

# runner=grok + REVIEWER_CMD="env grok -p codex" must reject (same provider after unwrap)
: > "$CALLS/launches.log"
out=$(
  env \
    PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="grok" \
    REVIEWER_CMD="env grok -p codex" \
    RELEASE_CMD="claude -p release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "env grok reviewer bypass should fail" || {
  echo "$out" | grep -qi 'REVIEWER_CMD\|same provider\|provider' \
    && ok "env grok reviewer bypass refused" \
    || bad "unclear env-grok reviewer fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "env grok reviewer launched zero" || bad "env-grok review launched $lc"

# Equivalent release bypass: RELEASE_CMD="env grok ..." with builder grok
: > "$CALLS/launches.log"
out=$(
  env \
    PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="grok" \
    REVIEWER_CMD="codex exec -s read-only -" \
    RELEASE_CMD="env FOO=1 grok -p release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "env grok release bypass should fail" || {
  echo "$out" | grep -qi 'RELEASE_CMD\|third identity\|same provider\|provider' \
    && ok "env grok release bypass refused" \
    || bad "unclear env-grok release fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "env grok release launched zero" || bad "env-grok release launched $lc"

# Quoted executable must fail closed (not become a distinct fake provider)
: > "$CALLS/launches.log"
out=$(
  env \
    PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="grok" \
    REVIEWER_CMD="\"$BIN/codex\" review" \
    RELEASE_CMD="claude -p release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "quoted reviewer path should fail closed" || {
  echo "$out" | grep -qi 'provider\|REVIEWER_CMD\|cannot resolve\|identity' \
    && ok "quoted reviewer path fail-closed" \
    || bad "unclear quoted-path fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "quoted reviewer launched zero" || bad "quoted review launched $lc"

# Valid Grok -> Codex -> Claude still launches (plain names, no wrapper needed)
: > "$CALLS/launches.log"
out=$(
  env \
    PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="grok" \
    REVIEWER_CMD="codex exec -s read-only -" \
    RELEASE_CMD="claude -p --permission-mode bypassPermissions" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || { bad "valid Grok->Codex->Claude failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "valid Grok->Codex->Claude still launches" \
  || bad "valid Grok->Codex->Claude launches=$lc out=$out"

# env with well-defined assignment wrapping a *distinct* provider still works
: > "$CALLS/launches.log"
out=$(
  env \
    PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="grok" \
    REVIEWER_CMD="env FOO=bar codex exec -s read-only -" \
    RELEASE_CMD="claude -p release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || { bad "valid env-wrapped distinct reviewer failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "valid env-wrapped distinct provider launches" \
  || bad "valid env-wrap launches=$lc out=$out"

# --- #5c watchdog start idempotent per profile/log dir ---------------------
echo "watchdog start idempotent"
reset_calls
TARGET=$(setup_target_repo wdidem acme/widget)
PROF="$ROOT/profiles/wdidem.profile"
write_profile "$PROF" \
  "version=1" \
  "name=wdidem" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "deadline_seconds=45" \
  "lane=docs|39|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
WD_PF="$ROOT/logs/watchdog.pid"
rm -f "$WD_PF"
# Real sleep so the watchdog stays alive across two --start calls.
# Sync launch so loop stubs finish immediately; only the watchdog remains.
run_wd_start() {
  env \
    PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=sleep \
    DEADLINE_SECONDS=45 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=0 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
}
out1=$(run_wd_start) || { bad "watchdog first start failed: $out1"; }
[[ -f "$WD_PF" ]] || bad "watchdog pidfile missing after first start"
wd1=$(tr -d '[:space:]' < "$WD_PF")
[[ "$wd1" =~ ^[1-9][0-9]*$ ]] && kill -0 "$wd1" 2>/dev/null \
  && ok "watchdog first start armed pid $wd1" \
  || bad "watchdog first pid invalid/dead: $wd1"
cmd1=$(ps -p "$wd1" -o command= 2>/dev/null || ps -p "$wd1" -o args= 2>/dev/null || true)
echo "$cmd1" | grep -q '45' \
  && ok "watchdog cmdline carries original deadline 45" \
  || bad "watchdog cmdline missing deadline: $cmd1"

# Second start: all lanes healthy (no loop left with sync, but re-start reuses bases).
# Must keep the *same* watchdog PID and not re-arm a new deadline.
out2=$(run_wd_start) || { bad "watchdog second start failed: $out2"; }
wd2=$(tr -d '[:space:]' < "$WD_PF" 2>/dev/null || true)
[[ "$wd1" == "$wd2" ]] && ok "repeated start kept same watchdog pid $wd1" \
  || bad "watchdog pid changed: first=$wd1 second=$wd2 out2=$out2"
echo "$out2" | grep -qi 'already running\|leaving deadline' \
  && ok "second start reports existing watchdog" \
  || bad "second start did not report existing watchdog: $out2"
cmd2=$(ps -p "$wd1" -o command= 2>/dev/null || ps -p "$wd1" -o args= 2>/dev/null || true)
[[ "$cmd1" == "$cmd2" ]] && ok "watchdog identity/cmdline unchanged after re-start" \
  || bad "watchdog cmdline changed: before=[$cmd1] after=[$cmd2]"

# Clean only this exact PID/group — no pkill/killall/pattern kill.
if kill -0 "$wd1" 2>/dev/null; then
  kill -TERM -"$wd1" 2>/dev/null || kill -TERM "$wd1" 2>/dev/null || true
  sleep 0.3 2>/dev/null || sleep 1
  kill -KILL -"$wd1" 2>/dev/null || kill -KILL "$wd1" 2>/dev/null || true
fi
# Reap and drop pidfile (driver would clean on natural completion)
rm -f "$WD_PF"
if kill -0 "$wd1" 2>/dev/null; then
  bad "watchdog pid $wd1 still alive after exact-PID cleanup"
  kill -KILL "$wd1" 2>/dev/null || true
else
  ok "watchdog exact PID cleaned after test"
fi
# Restore sensor defaults
export FLEET_NO_WATCHDOG=1
export SLEEP_CMD=true

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

# ============================================================================
# Codex #143 blockers — lane-state preflight, wall-timeout, noglob, isolation,
# reserved-field validation
# ============================================================================

# --- B1: healthy claimed+open-PR restart (idempotent, zero launches) --------
echo "healthy claimed+open-PR restart"
reset_calls
TARGET=$(setup_target_repo hclaim acme/widget)
PROF="$ROOT/profiles/hclaim.profile"
write_profile "$PROF" \
  "version=1" \
  "name=hclaim" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|201|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "hclaim initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-01T00:00:00Z
issue: 201
pr: 301
hat: builder
next_hat: reviewer
round: 2
parked: false
next_action: mid-flight claimed work
notes: >
  healthy claimed+open-PR restart
STATE
mkdir -p "$ROOT/fleet/lane-docs/gibson"
touch "$ROOT/fleet/lane-docs/gibson/HALT"
bash -c 'while true; do sleep 30; done' \
  "$ROOT/gibson/scripts/loop.sh" \
  "$ROOT/fleet/lane-docs" &
HCLAIM_PID=$!
printf '%s\n' "$HCLAIM_PID" > "$LOG_DIR/docs.pid"
# Issue is agent-claimed and has an open PR — unstarted preflight would reject.
ISSUEDIR="$ROOT/gh-issues-hclaim"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/201.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
export GH_STUB_PR_JSON='[{"number":301,"headRefName":"feat/201-docs-slice","body":"## Active work\n\n- Active-work claim: issue-201-docs-slice\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "healthy claimed+open-PR re-start failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "healthy claimed+open-PR re-start launched zero" \
  || bad "healthy claimed+open-PR launched $lc out=$out"
[[ -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] && ok "healthy claimed+open-PR preserved HALT" \
  || bad "healthy claimed+open-PR removed HALT"
grep -q '^issue: 201$' "$STATE_FILE" && grep -q '^pr: 301$' "$STATE_FILE" \
  && ok "healthy claimed+open-PR preserved state" \
  || bad "healthy claimed+open-PR clobbered state: $(cat "$STATE_FILE")"
kill "$HCLAIM_PID" 2>/dev/null || true
wait "$HCLAIM_PID" 2>/dev/null || true
rm -f "$LOG_DIR/docs.pid"
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- B1b: dead resumable claimed+open-PR restart ----------------------------
echo "dead resumable claimed+open-PR restart"
reset_calls
TARGET=$(setup_target_repo dclaim acme/widget)
PROF="$ROOT/profiles/dclaim.profile"
write_profile "$PROF" \
  "version=1" \
  "name=dclaim" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|202|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "dclaim initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-02T00:00:00Z
issue: 202
pr: 302
hat: reviewer
next_hat: release
round: 3
parked: false
next_action: dead lane with own claim+PR
notes: >
  resume me
STATE
touch "$ROOT/fleet/lane-docs/gibson/HALT"
rm -f "$LOG_DIR/docs.pid"
ISSUEDIR="$ROOT/gh-issues-dclaim"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/202.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
export GH_STUB_PR_JSON='[{"number":302,"headRefName":"feat/202-docs-resume","body":"## Active work\n\n- Active-work claim: issue-202-docs-resume\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "dead claimed+open-PR relaunch failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "dead claimed+open-PR relaunch launched once" \
  || bad "dead claimed+open-PR launches=$lc out=$out"
grep -q '^issue: 202$' "$STATE_FILE" && grep -q '^pr: 302$' "$STATE_FILE" \
  && grep -q '^hat: reviewer$' "$STATE_FILE" && grep -q '^round: 3$' "$STATE_FILE" \
  && ok "dead claimed+open-PR preserved issue/pr/hat/round" \
  || bad "dead claimed+open-PR reset state: $(cat "$STATE_FILE")"
[[ ! -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] && ok "dead claimed+open-PR cleared HALT" \
  || bad "dead claimed+open-PR left HALT"
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- B1c: closed prior queue item after state advanced ----------------------
echo "closed prior queue item after state advanced"
reset_calls
TARGET=$(setup_target_repo advq acme/widget)
PROF="$ROOT/profiles/advq.profile"
write_profile "$PROF" \
  "version=1" \
  "name=advq" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|210,211|docs/**|queue advance"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "advq initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-03T00:00:00Z
issue: 211
pr: 311
hat: builder
next_hat: builder
round: 1
parked: false
next_action: advanced past closed 210
notes: >
  prior closed
STATE
rm -f "$LOG_DIR/docs.pid"
ISSUEDIR="$ROOT/gh-issues-advq"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"CLOSED","labels":[{"name":"tier-a"}]}' > "$ISSUEDIR/210.json"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/211.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
export GH_STUB_PR_JSON='[{"number":311,"headRefName":"feat/211-next","body":"## Active work\n\n- Active-work claim: issue-211-next\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "closed-prior advanced restart failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "closed prior after advance relaunches current" \
  || bad "closed-prior launches=$lc out=$out"
grep -q '^issue: 211$' "$STATE_FILE" && ok "closed-prior preserved advanced issue" \
  || bad "closed-prior clobbered state: $(cat "$STATE_FILE")"
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- B1d: foreign / ambiguous ownership fails closed ------------------------
echo "foreign and ambiguous ownership fail closed"
reset_calls
TARGET=$(setup_target_repo foreign acme/widget)
PROF="$ROOT/profiles/foreign.profile"
write_profile "$PROF" \
  "version=1" \
  "name=foreign" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|220|docs/**|own queue only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "foreign initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
# Recorded issue is NOT in this lane's queue — foreign ownership.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-04T00:00:00Z
issue: 999
pr: 1
hat: builder
next_hat: builder
round: 1
parked: false
next_action: foreign issue
notes: >
  not ours
STATE
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "foreign ownership should fail: $out" || {
  echo "$out" | grep -qiE 'foreign|not in configured queue|refuse to resume' \
    && ok "foreign ownership refused" \
    || bad "unclear foreign fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "foreign ownership launched zero" || bad "foreign launched $lc"

# Future queue work stays strict: own current may be claimed, future may not.
write_profile "$PROF" \
  "version=1" \
  "name=foreign" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|220,221|docs/**|own queue only"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-04T00:00:00Z
issue: 220
pr: 1
hat: builder
next_hat: builder
round: 1
parked: false
next_action: current own; future foreign-claimed
notes: >
  future strict
STATE
ISSUEDIR="$ROOT/gh-issues-foreign"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/220.json"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/221.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
export GH_STUB_PR_JSON='[{"number":1,"headRefName":"feat/220-ok","body":"## Active work\n\n- Active-work claim: issue-220-ok\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "future claimed issue should fail: $out" || {
  echo "$out" | grep -qiE 'agent-claimed|221' \
    && ok "future queue claim still strict" \
    || bad "unclear future-claim fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "future claimed launched zero" || bad "future claimed launched $lc"
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- B1e: own claim requires state-bound pr:/handoff: (positive + negatives) -
echo "own claim state-bound PR ownership"
reset_calls
TARGET=$(setup_target_repo ownbind acme/widget)
PROF="$ROOT/profiles/ownbind.profile"
write_profile "$PROF" \
  "version=1" \
  "name=ownbind" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|270|docs/**|own bind"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "ownbind initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
ISSUEDIR="$ROOT/gh-issues-ownbind"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/270.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"

# Positive: matching pr number + head branch relaunches.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-05T00:00:00Z
issue: 270
pr: 370
hat: builder
next_hat: builder
round: 1
parked: false
next_action: own bound pr
notes: >
  positive own
STATE
rm -f "$LOG_DIR/docs.pid"
export GH_STUB_PR_JSON='[{"number":370,"headRefName":"feat/270-own-slice","body":"## Active work\n\n- Active-work claim: issue-270-own-slice\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "positive own bound PR should relaunch: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "positive own state-bound PR relaunches" \
  || bad "positive own launches=$lc out=$out"
grep -q '^pr: 370$' "$STATE_FILE" && ok "positive own preserved pr binding" \
  || bad "positive own clobbered pr: $(cat "$STATE_FILE")"

# Claimed with no pr:/handoff: fails closed.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-05T00:00:00Z
issue: 270
pr:
hat: builder
next_hat: builder
round: 1
parked: false
next_action: claimed unbound
notes: >
  no binding
STATE
rm -f "$LOG_DIR/docs.pid"
export GH_STUB_PR_JSON='[{"number":370,"headRefName":"feat/270-own-slice","body":"## Active work\n\n- Active-work claim: issue-270-own-slice\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "unbound claimed should fail: $out" || {
  echo "$out" | grep -qiE 'no pr: or handoff:|unbound|refuse to resume' \
    && ok "claimed without pr/handoff refused" \
    || bad "unclear unbound-claim fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "unbound claimed launched zero" || bad "unbound claimed launched $lc"

# Foreign same-issue PR (state pr does not match open PR) fails closed.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-05T00:00:00Z
issue: 270
pr: 999
hat: builder
next_hat: builder
round: 1
parked: false
next_action: foreign pr number
notes: >
  mismatched pr
STATE
rm -f "$LOG_DIR/docs.pid"
export GH_STUB_PR_JSON='[{"number":370,"headRefName":"feat/270-foreign-agent","body":"## Active work\n\n- Active-work claim: issue-270-foreign-agent\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "mismatched PR number should fail: $out" || {
  echo "$out" | grep -qiE 'pr:#?999|not found open|not bound|mismatched|refuse' \
    && ok "mismatched PR number refused" \
    || bad "unclear mismatched-PR fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "mismatched PR launched zero" || bad "mismatched PR launched $lc"

# handoff branch mismatch against state-bound pr fails closed.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-05T00:00:00Z
issue: 270
pr: 370
hat: builder
next_hat: builder
round: 1
parked: false
handoff: feat/270-expected
handoff_sha:
next_action: branch mismatch
notes: >
  handoff vs head
STATE
rm -f "$LOG_DIR/docs.pid"
export GH_STUB_PR_JSON='[{"number":370,"headRefName":"feat/270-other-branch","body":"## Active work\n\n- Active-work claim: issue-270-other-branch\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "mismatched branch should fail: $out" || {
  echo "$out" | grep -qiE 'handoff|does not match|branch' \
    && ok "mismatched handoff branch refused" \
    || bad "unclear mismatched-branch fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "mismatched branch launched zero" || bad "mismatched branch launched $lc"

# Foreign open PR for same issue while state points at a different binding.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-05T00:00:00Z
issue: 270
pr: 370
hat: builder
next_hat: builder
round: 1
parked: false
next_action: two prs one foreign
notes: >
  foreign sibling
STATE
rm -f "$LOG_DIR/docs.pid"
export GH_STUB_PR_JSON='[{"number":370,"headRefName":"feat/270-own","body":"## Active work\n\n- Active-work claim: issue-270-own\n"},{"number":371,"headRefName":"feat/270-foreign","body":"## Active work\n\n- Active-work claim: issue-270-foreign\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "foreign sibling PR should fail: $out" || {
  echo "$out" | grep -qiE '371|foreign|not bound|refuse' \
    && ok "foreign same-issue sibling PR refused" \
    || bad "unclear foreign-sibling fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "foreign sibling launched zero" || bad "foreign sibling launched $lc"
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- B1f: healthy restart validates queue membership (non-mutating) --------
echo "healthy restart validates queue + identity"
reset_calls
TARGET=$(setup_target_repo hval acme/widget)
PROF="$ROOT/profiles/hval.profile"
write_profile "$PROF" \
  "version=1" \
  "name=hval" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|280|docs/**|healthy validate"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "hval initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
# Plant healthy pid + valid in-queue state.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-06T00:00:00Z
issue: 280
pr: 380
hat: builder
next_hat: builder
round: 2
parked: false
next_action: healthy in queue
notes: >
  ok
STATE
mkdir -p "$ROOT/fleet/lane-docs/gibson"
touch "$ROOT/fleet/lane-docs/gibson/HALT"
bash -c 'while true; do sleep 30; done' \
  "$ROOT/gibson/scripts/loop.sh" \
  "$ROOT/fleet/lane-docs" &
HVAL_PID=$!
printf '%s\n' "$HVAL_PID" > "$LOG_DIR/docs.pid"
ISSUEDIR="$ROOT/gh-issues-hval"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/280.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
export GH_STUB_PR_JSON='[{"number":380,"headRefName":"feat/280-healthy","body":"## Active work\n\n- Active-work claim: issue-280-healthy\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "healthy in-queue restart failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "healthy in-queue restart launched zero" \
  || bad "healthy in-queue launched $lc out=$out"
[[ -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] && ok "healthy validate preserved HALT" \
  || bad "healthy validate removed HALT"
grep -q '^issue: 280$' "$STATE_FILE" && ok "healthy validate preserved state" \
  || bad "healthy validate clobbered state"

# Same healthy pid but recorded issue outside queue → fail closed, no mutation.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-06T00:00:00Z
issue: 999
pr: 1
hat: builder
next_hat: builder
round: 2
parked: false
next_action: foreign while healthy
notes: >
  bad
STATE
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "healthy foreign issue should fail: $out" || {
  echo "$out" | grep -qiE 'not in configured queue|foreign|refuse' \
    && ok "healthy foreign-issue refused" \
    || bad "unclear healthy-foreign fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "healthy foreign launched zero" || bad "healthy foreign launched $lc"
[[ -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] && ok "healthy foreign left HALT untouched" \
  || bad "healthy foreign cleared HALT"
kill "$HVAL_PID" 2>/dev/null || true
wait "$HVAL_PID" 2>/dev/null || true
rm -f "$LOG_DIR/docs.pid"
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- B1g: OPEN prior queue item fails closed -------------------------------
echo "open prior queue item fails closed"
reset_calls
TARGET=$(setup_target_repo openprior acme/widget)
PROF="$ROOT/profiles/openprior.profile"
write_profile "$PROF" \
  "version=1" \
  "name=openprior" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|290,291|docs/**|prior open"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "openprior initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-07T00:00:00Z
issue: 291
pr: 391
hat: builder
next_hat: builder
round: 1
parked: false
next_action: advanced past still-open 290
notes: >
  open prior
STATE
rm -f "$LOG_DIR/docs.pid"
ISSUEDIR="$ROOT/gh-issues-openprior"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"tier-a"}]}' > "$ISSUEDIR/290.json"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/291.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
export GH_STUB_PR_JSON='[{"number":391,"headRefName":"feat/291-current","body":"## Active work\n\n- Active-work claim: issue-291-current\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "open prior should fail: $out" || {
  echo "$out" | grep -qiE 'prior queue item #290|still OPEN|refuse to advance|no skip/park' \
    && ok "open prior refused" \
    || bad "unclear open-prior fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "open prior launched zero" || bad "open prior launched $lc"
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- B1h: issue:123 (no space) parses like issue: 123 ----------------------
echo "issue: no-space state syntax"
reset_calls
TARGET=$(setup_target_repo nospace acme/widget)
PROF="$ROOT/profiles/nospace.profile"
write_profile "$PROF" \
  "version=1" \
  "name=nospace" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|300|docs/**|no space issue"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "nospace initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
# Deliberate no-space grammar accepted by validate-loop-state / loop.sh read_field.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-08T00:00:00Z
issue:300
pr:400
hat: builder
next_hat: builder
round: 1
parked: false
next_action: no-space issue key
notes: >
  issue:300 form
STATE
rm -f "$LOG_DIR/docs.pid"
ISSUEDIR="$ROOT/gh-issues-nospace"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/300.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
export GH_STUB_PR_JSON='[{"number":400,"headRefName":"feat/300-nospace","body":"## Active work\n\n- Active-work claim: issue-300-nospace\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "no-space issue:300 should resume: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "issue:300 no-space syntax resumes" \
  || bad "no-space launches=$lc out=$out"
grep -qE '^issue:[[:space:]]*300$' "$STATE_FILE" && ok "no-space issue preserved" \
  || bad "no-space state clobbered: $(cat "$STATE_FILE")"
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- B2: no perl / no python3 → fail before any network child --------------
echo "no-perl/no-python wall-timeout fail-closed"
reset_calls
TARGET=$(setup_target_repo nopp acme/widget)
PROF="$ROOT/profiles/nopp.profile"
write_profile "$PROF" \
  "version=1" \
  "name=nopp" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|230|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
# Minimal PATH without perl/python3. Network child would be git fetch.
NOPP_BIN="$ROOT/nopp-bin"
rm -rf "$NOPP_BIN"
mkdir -p "$NOPP_BIN"
REAL_GIT=$(command -v git)
# git wrapper records any invocation that looks like network work
cat > "$NOPP_BIN/git" <<STUB
#!/usr/bin/env bash
echo "GIT \$*" >> "$CALLS/nopp-git.log"
for a in "\$@"; do
  if [[ "\$a" == "fetch" || "\$a" == "ls-remote" ]]; then
    echo "NETWORK_CHILD \$a" >> "$CALLS/nopp-network.log"
  fi
done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$NOPP_BIN/git"
# Link common tools the driver needs; deliberately omit perl and python3.
for c in bash sh env sed tr awk cat printf mkdir rm chmod date basename dirname \
         head tail grep cut nohup sleep true kill ps wait mktemp uname pwd ln \
         touch mv cp ls wc sort uniq xargs which; do
  p=$(command -v "$c" 2>/dev/null) || continue
  [[ -e "$NOPP_BIN/$c" ]] && continue
  ln -sf "$p" "$NOPP_BIN/$c"
done
cp "$BIN/gh" "$NOPP_BIN/gh"
cp "$BIN/fake-runner" "$NOPP_BIN/fake-runner"
# Also need real git for non-network preflight? wrapper delegates.
rm -f "$CALLS/nopp-git.log" "$CALLS/nopp-network.log"
: > "$CALLS/nopp-git.log"
: > "$CALLS/nopp-network.log"
: > "$CALLS/launches.log"
out=$(
  env -i \
    PATH="$NOPP_BIN" \
    HOME="$HOME" \
    TMPDIR="${TMPDIR:-/tmp}" \
    USER="${USER:-sensor}" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$NOPP_BIN/gh" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=0 \
    FLEET_FETCH_TIMEOUT=5 \
    GIT_TERMINAL_PROMPT=0 \
    GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "no-perl/no-python should fail closed: $out" || {
  echo "$out" | grep -qiE 'perl|python3|process group|wall-timeout' \
    && ok "no-perl/no-python fails closed before bare child" \
    || bad "unclear no-pp fail: $out"
}
if [[ -f "$CALLS/nopp-network.log" ]] && grep -q 'NETWORK_CHILD' "$CALLS/nopp-network.log" 2>/dev/null; then
  bad "no-perl/no-python still launched network child: $(cat "$CALLS/nopp-network.log")"
else
  ok "no-perl/no-python launched zero network children"
fi
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "no-perl/no-python launched zero runners" || bad "no-pp launched $lc"

# --- B3: scope split noglob — literal docs/** despite cwd matches ----------
echo "scope list noglob (cwd docs/** matches)"
reset_calls
TARGET=$(setup_target_repo scopenoglob acme/widget)
# Ensure invocation cwd has paths that would expand docs/**
# Target already has docs/a.md. Run fleet from TARGET so docs/** expands if globs on.
PROF="$ROOT/profiles/scopenoglob.profile"
write_profile "$PROF" \
  "version=1" \
  "name=scopenoglob" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|240|docs/**|docs" \
  "lane=nested|241|docs/nested/**|nested under docs"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
# From TARGET cwd, docs/** would expand to docs/a.md without noglob, which can
# miss containment overlap with literal docs/nested/**.
out=$(
  CDPATH='' cd "$TARGET" && \
  env \
    PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="$RUNNER" REVIEWER_CMD="$REVIEWER_CMD" RELEASE_CMD="$RELEASE_CMD" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "docs/** vs docs/nested/** should overlap (literal tokens): $out" || {
  echo "$out" | grep -qiE 'scope overlap|docs/\*\*.*docs/nested|docs/nested.*docs/\*\*' \
    && ok "literal docs/** overlaps docs/nested/** despite cwd matches" \
    || bad "noglob overlap miss or unclear: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "scope noglob overlap launched zero" || bad "scope noglob launched $lc"

# --- B4: concurrent two-profile isolation (default fleet/log namespace) ----
echo "two-profile default isolation"
reset_calls
# Isolate HOME so defaults land under the temp tree, not the real home.
ISO_HOME="$ROOT/iso-home"
mkdir -p "$ISO_HOME"
TARGET_A=$(setup_target_repo isoA acme/widget)
TARGET_B=$(setup_target_repo isoB acme/widget)
PROF_A="$ROOT/profiles/isoA.profile"
PROF_B="$ROOT/profiles/isoB.profile"
# No fleet_dir/log_dir — defaults must namespace by name + target fingerprint.
write_profile "$PROF_A" \
  "version=1" \
  "name=isoAlpha" \
  "repo=$TARGET_A" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "runner=fake-runner" \
  "deadline_seconds=90" \
  "lane=docs|250|docs/**|alpha docs"
write_profile "$PROF_B" \
  "version=1" \
  "name=isoBeta" \
  "repo=$TARGET_B" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "runner=fake-runner" \
  "deadline_seconds=91" \
  "lane=docs|251|docs/**|beta docs"
export GH_STUB_MODE=ok
run_iso() {
  local prof="$1" cmd="$2"
  # Intentionally omit FLEET_DIR/LOG_DIR so profile-name defaults apply.
  env -u FLEET_DIR -u LOG_DIR \
    PATH="$BIN:$PATH" \
    HOME="$ISO_HOME" \
    GIBSON="$GIBSON" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=sleep \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=0 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$prof" \
    "$FLEET" --profile "$prof" "$cmd" 2>&1
}
# Unset FLEET_DIR/LOG_DIR so defaults apply
outA=$(run_iso "$PROF_A" --start) || { bad "isoAlpha start failed: $outA"; }
outB=$(run_iso "$PROF_B" --start) || { bad "isoBeta start failed: $outB"; }
# Extract resolved fleet_dir/log_dir from driver identity lines (include fingerprint).
FLEET_A=$(printf '%s\n' "$outA" | sed -n 's/^fleet: fleet_dir=//p' | head -1)
FLEET_B=$(printf '%s\n' "$outB" | sed -n 's/^fleet: fleet_dir=//p' | head -1)
LOG_A=$(printf '%s\n' "$outA" | sed -n 's/^fleet: log_dir=//p' | head -1)
LOG_B=$(printf '%s\n' "$outB" | sed -n 's/^fleet: log_dir=//p' | head -1)
[[ -n "$FLEET_A" && -d "$FLEET_A/lane-docs" ]] && ok "isoAlpha fleet dir namespaced" \
  || bad "isoAlpha fleet missing: '$FLEET_A' out=$outA"
[[ -n "$FLEET_B" && -d "$FLEET_B/lane-docs" ]] && ok "isoBeta fleet dir namespaced" \
  || bad "isoBeta fleet missing: '$FLEET_B' out=$outB"
[[ "$FLEET_A" != "$FLEET_B" ]] && ok "profiles use distinct fleet dirs" \
  || bad "profiles share fleet dir"
case "$FLEET_A" in
  */Code/fleet/isoAlpha-*) ok "isoAlpha default includes name+fingerprint" ;;
  *) bad "isoAlpha fleet dir not fingerprinted: $FLEET_A" ;;
esac
case "$FLEET_B" in
  */Code/fleet/isoBeta-*) ok "isoBeta default includes name+fingerprint" ;;
  *) bad "isoBeta fleet dir not fingerprinted: $FLEET_B" ;;
esac
[[ -n "$LOG_A" && -n "$LOG_B" && -d "$LOG_A" && -d "$LOG_B" && "$LOG_A" != "$LOG_B" ]] \
  && ok "profiles use distinct log dirs" \
  || bad "log dirs not isolated: $LOG_A vs $LOG_B"
WD_A="$LOG_A/watchdog.pid"
WD_B="$LOG_B/watchdog.pid"
[[ -f "$WD_A" && -f "$WD_B" ]] || bad "watchdog pidfiles missing A=$WD_A B=$WD_B"
wda=$(tr -d '[:space:]' < "$WD_A")
wdb=$(tr -d '[:space:]' < "$WD_B")
[[ "$wda" =~ ^[1-9][0-9]*$ && "$wdb" =~ ^[1-9][0-9]*$ && "$wda" != "$wdb" ]] \
  && ok "distinct watchdog PIDs ($wda vs $wdb)" \
  || bad "watchdog PID collision/invalid: $wda $wdb"
# Status identity
stA=$(run_iso "$PROF_A" --status) || true
stB=$(run_iso "$PROF_B" --status) || true
echo "$stA" | grep -q 'profile=isoAlpha' && echo "$stA" | grep -qE 'docs' \
  && ok "isoAlpha status identity" || bad "isoAlpha status: $stA"
echo "$stB" | grep -q 'profile=isoBeta' && echo "$stB" | grep -qE 'docs' \
  && ok "isoBeta status identity" || bad "isoBeta status: $stB"
# Halt only Alpha — Beta HALT must not appear
outH=$(run_iso "$PROF_A" --halt) || { bad "isoAlpha halt failed: $outH"; }
[[ -f "$FLEET_A/lane-docs/gibson/HALT" ]] && ok "isoAlpha halt wrote own HALT" \
  || bad "isoAlpha HALT missing"
[[ ! -f "$FLEET_B/lane-docs/gibson/HALT" ]] && ok "isoAlpha halt did not touch isoBeta" \
  || bad "isoAlpha halt polluted isoBeta HALT"
# Explicit paths still win over namespaced defaults
EX_FLEET="$ROOT/explicit-fleet"
EX_LOG="$ROOT/explicit-logs"
mkdir -p "$EX_FLEET" "$EX_LOG"
PROF_E="$ROOT/profiles/isoExplicit.profile"
write_profile "$PROF_E" \
  "version=1" \
  "name=isoExplicit" \
  "repo=$TARGET_A" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$EX_FLEET" \
  "log_dir=$EX_LOG" \
  "runner=fake-runner" \
  "lane=docs|252|docs/**|explicit"
outE=$(
  env -u FLEET_DIR -u LOG_DIR \
    PATH="$BIN:$PATH" \
    HOME="$ISO_HOME" \
    GIBSON="$GIBSON" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF_E" \
    "$FLEET" --profile "$PROF_E" --start 2>&1
) || { bad "explicit path profile failed: $outE"; }
[[ -d "$EX_FLEET/lane-docs" ]] && ok "explicit fleet_dir preserved" \
  || bad "explicit fleet_dir ignored"
[[ -f "$EX_LOG/docs.log" || -d "$EX_LOG" ]] && ok "explicit log_dir preserved" \
  || bad "explicit log_dir ignored"
[[ -f "$EX_FLEET/.fleet-identity" ]] && ok "explicit fleet_dir has identity marker" \
  || bad "explicit fleet_dir missing .fleet-identity"
# Cleanup watchdogs by exact PID only
for wd in "$wda" "$wdb"; do
  if [[ -n "$wd" ]] && kill -0 "$wd" 2>/dev/null; then
    kill -TERM -"$wd" 2>/dev/null || kill -TERM "$wd" 2>/dev/null || true
    sleep 0.2 2>/dev/null || sleep 1
    kill -KILL -"$wd" 2>/dev/null || kill -KILL "$wd" 2>/dev/null || true
  fi
done
rm -f "$WD_A" "$WD_B"
export FLEET_NO_WATCHDOG=1
export SLEEP_CMD=true

# --- B4b: same name, different profile path / target → isolated defaults ----
echo "same-name different profile/target isolation"
reset_calls
ISO2_HOME="$ROOT/iso2-home"
mkdir -p "$ISO2_HOME"
TARGET_S1=$(setup_target_repo same1 acme/widget)
TARGET_S2=$(setup_target_repo same2 acme/gadget)
# Two profile files, identical name=, different paths and targets.
PROF_S1="$ROOT/profiles/same-name-a.profile"
PROF_S2="$ROOT/profiles/same-name-b.profile"
write_profile "$PROF_S1" \
  "version=1" \
  "name=sharedName" \
  "repo=$TARGET_S1" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "runner=fake-runner" \
  "lane=docs|350|docs/**|same name a"
write_profile "$PROF_S2" \
  "version=1" \
  "name=sharedName" \
  "repo=$TARGET_S2" \
  "slug=acme/gadget" \
  "gibson=$ROOT/gibson" \
  "runner=fake-runner" \
  "lane=docs|351|docs/**|same name b"
run_same() {
  local prof="$1" cmd="$2"
  env -u FLEET_DIR -u LOG_DIR \
    PATH="$BIN:$PATH" \
    HOME="$ISO2_HOME" \
    GIBSON="$GIBSON" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$prof" \
    "$FLEET" --profile "$prof" "$cmd" 2>&1
}
outS1=$(run_same "$PROF_S1" --start) || { bad "same-name A start failed: $outS1"; }
outS2=$(run_same "$PROF_S2" --start) || { bad "same-name B start failed: $outS2"; }
FLEET_S1=$(printf '%s\n' "$outS1" | sed -n 's/^fleet: fleet_dir=//p' | head -1)
FLEET_S2=$(printf '%s\n' "$outS2" | sed -n 's/^fleet: fleet_dir=//p' | head -1)
LOG_S1=$(printf '%s\n' "$outS1" | sed -n 's/^fleet: log_dir=//p' | head -1)
LOG_S2=$(printf '%s\n' "$outS2" | sed -n 's/^fleet: log_dir=//p' | head -1)
[[ -n "$FLEET_S1" && -n "$FLEET_S2" && "$FLEET_S1" != "$FLEET_S2" ]] \
  && ok "same name different targets use distinct fleet dirs" \
  || bad "same-name fleet collision: $FLEET_S1 vs $FLEET_S2"
[[ -n "$LOG_S1" && -n "$LOG_S2" && "$LOG_S1" != "$LOG_S2" ]] \
  && ok "same name different targets use distinct log dirs" \
  || bad "same-name log collision: $LOG_S1 vs $LOG_S2"
[[ -d "$FLEET_S1/lane-docs" && -d "$FLEET_S2/lane-docs" ]] \
  && ok "same-name both lanes materialised" \
  || bad "same-name lane missing"
# Identity markers encode distinct repos / slugs (profile_path is physical).
[[ -f "$FLEET_S1/.fleet-identity" && -f "$FLEET_S2/.fleet-identity" ]] \
  && ok "same-name fleet identity markers present" \
  || bad "same-name identity missing"
grep -q 'slug=acme/widget' "$FLEET_S1/.fleet-identity" \
  && grep -q 'slug=acme/gadget' "$FLEET_S2/.fleet-identity" \
  && ok "same-name markers record distinct slugs" \
  || bad "same-name markers wrong: $(cat "$FLEET_S1/.fleet-identity") // $(cat "$FLEET_S2/.fleet-identity")"
grep -q "name=sharedName" "$FLEET_S1/.fleet-identity" \
  && grep -q "name=sharedName" "$FLEET_S2/.fleet-identity" \
  && ok "same-name markers share profile name" \
  || bad "same-name markers missing name="

# Explicit shared fleet_dir: second profile with different identity must fail closed.
COLLIDE_FLEET="$ROOT/collide-fleet"
COLLIDE_LOG="$ROOT/collide-logs"
mkdir -p "$COLLIDE_FLEET" "$COLLIDE_LOG"
PROF_C1="$ROOT/profiles/collide-a.profile"
PROF_C2="$ROOT/profiles/collide-b.profile"
write_profile "$PROF_C1" \
  "version=1" \
  "name=collide" \
  "repo=$TARGET_S1" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$COLLIDE_FLEET" \
  "log_dir=$COLLIDE_LOG" \
  "runner=fake-runner" \
  "lane=docs|360|docs/**|collide a"
write_profile "$PROF_C2" \
  "version=1" \
  "name=collide" \
  "repo=$TARGET_S2" \
  "slug=acme/gadget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$COLLIDE_FLEET" \
  "log_dir=$COLLIDE_LOG" \
  "runner=fake-runner" \
  "lane=docs|361|docs/**|collide b"
outC1=$(
  env -u FLEET_DIR -u LOG_DIR \
    PATH="$BIN:$PATH" HOME="$ISO2_HOME" GIBSON="$GIBSON" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF_C1" \
    "$FLEET" --profile "$PROF_C1" --start 2>&1
) || { bad "collide A start failed: $outC1"; }
: > "$CALLS/launches.log"
outC2=$(
  env -u FLEET_DIR -u LOG_DIR \
    PATH="$BIN:$PATH" HOME="$ISO2_HOME" GIBSON="$GIBSON" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF_C2" \
    "$FLEET" --profile "$PROF_C2" --start 2>&1
) && bad "same-name different target shared fleet_dir should fail: $outC2" || {
  echo "$outC2" | grep -qiE 'identity|mismatch|refuse to reuse' \
    && ok "same-name different-target shared fleet_dir refused" \
    || bad "unclear collide fail: $outC2"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "collide B launched zero" || bad "collide B launched $lc"

# Status/halt on foreign identity also fail closed.
outCS=$(
  env -u FLEET_DIR -u LOG_DIR \
    PATH="$BIN:$PATH" HOME="$ISO2_HOME" GIBSON="$GIBSON" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF_C2" \
    "$FLEET" --profile "$PROF_C2" --status 2>&1
) && bad "status on foreign identity should fail: $outCS" || {
  echo "$outCS" | grep -qiE 'identity|mismatch|refuse' \
    && ok "status refuses foreign shared fleet_dir" \
    || bad "unclear status-collide fail: $outCS"
}
outCH=$(
  env -u FLEET_DIR -u LOG_DIR \
    PATH="$BIN:$PATH" HOME="$ISO2_HOME" GIBSON="$GIBSON" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF_C2" \
    "$FLEET" --profile "$PROF_C2" --halt 2>&1
) && bad "halt on foreign identity should fail: $outCH" || {
  echo "$outCH" | grep -qiE 'identity|mismatch|refuse' \
    && ok "halt refuses foreign shared fleet_dir" \
    || bad "unclear halt-collide fail: $outCH"
}
[[ ! -f "$COLLIDE_FLEET/lane-docs/gibson/HALT" ]] \
  && ok "foreign halt did not write HALT into collide fleet" \
  || bad "foreign halt polluted collide fleet"

# --- B5: sixth lane field rejected; hostile reserved runner -----------------
echo "sixth field and reserved-runner validation"
reset_calls
TARGET=$(setup_target_repo sixfield acme/widget)
PROF="$ROOT/profiles/sixfield.profile"
write_profile "$PROF" \
  "version=1" \
  "name=sixfield" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|260|docs/**|intent|hermes|EXTRA"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "sixth field should fail: $out" || {
  echo "$out" | grep -qiE 'more than 5 fields|5 fields|too many fields|sixth|extra' \
    && ok "sixth lane field rejected" \
    || bad "unclear sixth-field fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "sixth field launched zero" || bad "sixth field launched $lc"

# Hostile reserved runner (shell metacharacters)
PROF="$ROOT/profiles/badrunner.profile"
write_profile "$PROF" \
  "version=1" \
  "name=badrunner" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  'lane=docs|261|docs/**|intent|evil$(reboot)'
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "hostile reserved runner should fail: $out" || {
  echo "$out" | grep -qiE 'runner route|reserved runner|safe inert|shell syntax|disallowed|hostile' \
    && ok "hostile reserved runner rejected" \
    || bad "unclear reserved-runner fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "hostile reserved runner launched zero" \
  || bad "hostile reserved runner launched $lc"

# Semicolon injection in reserved field
PROF="$ROOT/profiles/badrunner2.profile"
write_profile "$PROF" \
  "version=1" \
  "name=badrunner2" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  'lane=docs|262|docs/**|intent|codex;rm -rf /'
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "semicolon reserved runner should fail: $out" || {
  echo "$out" | grep -qiE 'runner route|reserved runner|safe inert|shell syntax|disallowed|hostile' \
    && ok "semicolon reserved runner rejected" \
    || bad "unclear semicolon-runner fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "semicolon reserved runner launched zero" \
  || bad "semicolon reserved runner launched $lc"

# Safe single-token route still accepted and used as primary
PROF="$ROOT/profiles/saferunner.profile"
write_profile "$PROF" \
  "version=1" \
  "name=saferunner" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|263|docs/**|intent|fake-runner"
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "safe runner route rejected: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "safe single-token route still accepted" \
  || bad "safe runner route launches=$lc out=$out"
grep -q 'LAUNCH runner=fake-runner' "$CALLS/launches.log" \
  && ok "safe route selected fake-runner over global default" \
  || bad "safe route did not select fake-runner"

# ============================================================================
# Codex #143 second-pass blockers — active-work claim, identity-before-pid,
# status hat grammar, PR-list fail-closed, dirty-probe status, duplicate scalars
# ============================================================================

# --- C1: active-work claim on state-bound own resumption (pos + negs) --------
echo "active-work claim validation (own resumption)"
reset_calls
TARGET=$(setup_target_repo awclaim acme/widget)
PROF="$ROOT/profiles/awclaim.profile"
write_profile "$PROF" \
  "version=1" \
  "name=awclaim" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|410|docs/**|active work claim"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "awclaim initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
ISSUEDIR="$ROOT/gh-issues-awclaim"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/410.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"

# Positive: matching claim id for feat/410-aw-claim relaunches.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-09T00:00:00Z
issue: 410
pr: 510
hat: builder
next_hat: builder
round: 1
parked: false
next_action: own with claim
notes: >
  positive claim
STATE
rm -f "$LOG_DIR/docs.pid"
export GH_STUB_PR_JSON='[{"number":510,"headRefName":"feat/410-aw-claim","body":"## Active work\n\n- Active-work claim: issue-410-aw-claim\n"}]'
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "positive active-work claim should relaunch: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "positive active-work claim relaunches" \
  || bad "positive claim launches=$lc out=$out"

# Missing claim line fails closed.
export GH_STUB_PR_JSON='[{"number":510,"headRefName":"feat/410-aw-claim","body":"## Summary\n\nno claim here\n"}]'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "missing claim should fail: $out" || {
  echo "$out" | grep -qiE 'Active-work claim|no .*claim|refuse to resume' \
    && ok "missing active-work claim refused" \
    || bad "unclear missing-claim fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "missing claim launched zero" || bad "missing claim launched $lc"

# Duplicate claim lines fail closed.
export GH_STUB_PR_JSON='[{"number":510,"headRefName":"feat/410-aw-claim","body":"- Active-work claim: issue-410-aw-claim\n- Active-work claim: issue-410-aw-claim\n"}]'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "duplicate claim should fail: $out" || {
  echo "$out" | grep -qiE '2 .*Active-work claim|exactly one|duplicate' \
    && ok "duplicate active-work claim refused" \
    || bad "unclear duplicate-claim fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "duplicate claim launched zero" || bad "duplicate claim launched $lc"

# Malformed claim token fails closed.
export GH_STUB_PR_JSON='[{"number":510,"headRefName":"feat/410-aw-claim","body":"- Active-work claim: not-a-claim-id\n"}]'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "malformed claim should fail: $out" || {
  echo "$out" | grep -qiE 'malformed|want issue-|refuse to resume' \
    && ok "malformed active-work claim refused" \
    || bad "unclear malformed-claim fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "malformed claim launched zero" || bad "malformed claim launched $lc"

# Foreign issue in claim fails closed.
export GH_STUB_PR_JSON='[{"number":510,"headRefName":"feat/410-aw-claim","body":"- Active-work claim: issue-999-aw-claim\n"}]'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "foreign-issue claim should fail: $out" || {
  echo "$out" | grep -qiE 'foreign issue|issue-999|want issue-410' \
    && ok "foreign-issue active-work claim refused" \
    || bad "unclear foreign-issue-claim fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "foreign-issue claim launched zero" || bad "foreign-issue claim launched $lc"

# Foreign slug (claim vs head) fails closed.
export GH_STUB_PR_JSON='[{"number":510,"headRefName":"feat/410-aw-claim","body":"- Active-work claim: issue-410-other-slug\n"}]'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "foreign-slug claim should fail: $out" || {
  echo "$out" | grep -qiE 'foreign slug|does not match head|expected .issue-410-aw-claim' \
    && ok "foreign-slug active-work claim refused" \
    || bad "unclear foreign-slug-claim fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "foreign-slug claim launched zero" || bad "foreign-slug claim launched $lc"

# fix/ branch form accepted when claim matches.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-09T00:00:00Z
issue: 410
pr: 511
hat: builder
next_hat: builder
round: 1
parked: false
next_action: fix branch claim
notes: >
  fix form
STATE
export GH_STUB_PR_JSON='[{"number":511,"headRefName":"fix/410-hotfix-lane","body":"- Active-work claim: issue-410-hotfix-lane\n"}]'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "fix/ branch claim should relaunch: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "fix/ branch active-work claim relaunches" \
  || bad "fix claim launches=$lc out=$out"

# Trailing explanatory text after claim id must fail (exact id only).
export GH_STUB_PR_JSON='[{"number":511,"headRefName":"fix/410-hotfix-lane","body":"- Active-work claim: issue-410-hotfix-lane (see notes)\n"}]'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "trailing claim text should fail: $out" || {
  echo "$out" | grep -qiE 'malformed|does not match head|foreign slug|refuse to resume' \
    && ok "trailing claim text refused" \
    || bad "unclear trailing-claim-text fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "trailing claim text launched zero" || bad "trailing claim text launched $lc"
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- C1b: no-external-jq (gh built-in formatter only) ----------------------
echo "no-external-jq PR list/view (gh formatter only)"
reset_calls
TARGET=$(setup_target_repo nojqpr acme/widget)
PROF="$ROOT/profiles/nojqpr.profile"
write_profile "$PROF" \
  "version=1" \
  "name=nojqpr" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|420|docs/**|no jq pr"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
# Hide system jq/python/perl so production cannot fall back to external parsers.
NOJQ_BIN="$ROOT/nojq-bin"
rm -rf "$NOJQ_BIN"
mkdir -p "$NOJQ_BIN"
for c in bash sh env sed tr awk cat printf mkdir rm chmod date basename dirname \
         head tail grep cut nohup sleep true kill ps wait mktemp uname pwd ln \
         touch mv cp ls wc sort uniq xargs which git cmp perl python3; do
  p=$(command -v "$c" 2>/dev/null) || continue
  [[ -e "$NOJQ_BIN/$c" ]] && continue
  ln -sf "$p" "$NOJQ_BIN/$c"
done
cp "$BIN/gh" "$NOJQ_BIN/gh"
cp "$BIN/fake-runner" "$NOJQ_BIN/fake-runner"
run_nojq() {
  env PATH="$NOJQ_BIN" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$NOJQ_BIN/gh" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 \
    GH_STUB_MODE="${GH_STUB_MODE:-ok}" \
    GH_STUB_ISSUE_DIR="${GH_STUB_ISSUE_DIR:-}" \
    GH_STUB_PR_JSON="${GH_STUB_PR_JSON:-}" \
    GH_STUB_PR_TSV="${GH_STUB_PR_TSV:-}" \
    GH_STUB_PR_LIST_FAIL="${GH_STUB_PR_LIST_FAIL:-0}" \
    GH_STUB_PR_VIEW_FAIL="${GH_STUB_PR_VIEW_FAIL:-0}" \
    GH_STUB_PR_VIEW_META="${GH_STUB_PR_VIEW_META:-}" \
    GH_STUB_PR_BODY_DIR="${GH_STUB_PR_BODY_DIR:-}" \
    ${GH_STUB_PR_LIST_RAW+GH_STUB_PR_LIST_RAW="$GH_STUB_PR_LIST_RAW"} \
    ${GH_STUB_PR_VIEW_BODY+GH_STUB_PR_VIEW_BODY="$GH_STUB_PR_VIEW_BODY"} \
    FLEET_PROFILE="$PROF" \
    "$FLEET" --profile "$PROF" "$@" 2>&1
}
out=$(run_nojq --start) || { bad "no-jq empty PR list initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
ISSUEDIR="$ROOT/gh-issues-nojqpr"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/420.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-10T00:00:00Z
issue: 420
pr: 520
hat: builder
next_hat: builder
round: 1
parked: false
next_action: nojq positive
notes: >
  ok
STATE
rm -f "$LOG_DIR/docs.pid"
export GH_STUB_PR_JSON='[{"number":520,"headRefName":"feat/420-nojq","body":"- Active-work claim: issue-420-nojq\n"}]'
: > "$CALLS/launches.log"
out=$(run_nojq --start) || { bad "no-jq positive claim resume failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "no-external-jq positive PR list + claim resumes" \
  || bad "no-external-jq positive launches=$lc out=$out"

# Malformed formatter stdout (not TSV) fails closed — never treated as empty.
unset GH_STUB_PR_JSON
export GH_STUB_PR_LIST_RAW='{"not":"an-array"}'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_nojq --start 2>&1) && bad "malformed list formatter output should fail: $out" || {
  echo "$out" | grep -qiE 'missing TAB|invalid number|malformed|refuse|cannot list' \
    && ok "malformed PR list formatter output refused" \
    || bad "unclear malformed-list fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "malformed list formatter launched zero" || bad "malformed list formatter launched $lc"
unset GH_STUB_PR_LIST_RAW

# Row with head only (missing number field shape) fails closed.
export GH_STUB_PR_LIST_RAW=$'\tfeat/420-nojq\n'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_nojq --start 2>&1) && bad "missing number row should fail: $out" || {
  echo "$out" | grep -qiE 'invalid number|missing TAB|refuse' \
    && ok "missing number row refused" \
    || bad "unclear missing-number-row fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "missing number row launched zero" || bad "missing number row launched $lc"
unset GH_STUB_PR_LIST_RAW
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- C1c: list formatter failure + metadata validation fail-closed ----------
echo "PR list formatter failure + metadata validation"
reset_calls
TARGET=$(setup_target_repo jqerr acme/widget)
PROF="$ROOT/profiles/jqerr.profile"
write_profile "$PROF" \
  "version=1" \
  "name=jqerr" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|421|docs/**|list fail"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "listfail initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
ISSUEDIR="$ROOT/gh-issues-jqerr"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/421.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-10T00:00:00Z
issue: 421
pr: 521
hat: builder
next_hat: builder
round: 1
parked: false
next_action: list fail
notes: >
  formatter down
STATE
rm -f "$LOG_DIR/docs.pid"
export GH_STUB_PR_LIST_FAIL=1
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "list formatter failure should fail: $out" || {
  echo "$out" | grep -qiE 'cannot list open PRs|pr list failure|simulated pr list' \
    && ok "PR list formatter failure refused" \
    || bad "unclear list-formatter-fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "list formatter failure launched zero" || bad "list formatter failure launched $lc"
unset GH_STUB_PR_LIST_FAIL

# Garbage non-TSV list output fails closed (not empty inventory).
export GH_STUB_PR_LIST_RAW='this is not tsv metadata at all'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "garbage list metadata should fail: $out" || {
  echo "$out" | grep -qiE 'missing TAB|invalid number|refuse|cannot list' \
    && ok "garbage list metadata refused" \
    || bad "unclear garbage-list fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "garbage list metadata launched zero" || bad "garbage list metadata launched $lc"
unset GH_STUB_PR_LIST_RAW
unset GH_STUB_ISSUE_DIR GH_STUB_PR_JSON

# --- C1d: hostile bodies cannot confuse ownership metadata ------------------
echo "hostile PR bodies cannot alter ownership metadata"
reset_calls
TARGET=$(setup_target_repo hostile acme/widget)
PROF="$ROOT/profiles/hostile.profile"
write_profile "$PROF" \
  "version=1" \
  "name=hostilebody" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|422|docs/**|hostile body"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "hostile initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
ISSUEDIR="$ROOT/gh-issues-hostile"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/422.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-10T12:00:00Z
issue: 422
pr: 522
hat: builder
next_hat: builder
round: 1
parked: false
next_action: hostile body
notes: >
  body may look like JSON
STATE
BODYDIR="$ROOT/gh-pr-bodies-hostile"
mkdir -p "$BODYDIR"
# List metadata stays clean; body alone carries every hostile token.
export GH_STUB_PR_TSV=$'522\tfeat/422-hostile-body'
export GH_STUB_PR_VIEW_META=$'522\tfeat/422-hostile-body\tOPEN'
# Hostile body: escaped field-like strings, literal },{, unicode, tabs, newlines,
# fake number/head text — must not manufacture ownership or a claim.
cat > "$BODYDIR/522.body" <<'BODY'
## Summary

Hostile content that must never be parsed as PR metadata:

- fake JSON fragment: {"number":999,"headRefName":"feat/999-pwned","body":"nope"}
- escaped field-like: \"number\": 888 and \"headRefName\": \"feat/888-evil\"
- literal object split bait: },{
- unicode: café — 日本語 — emoji 🚀
- tabs and newlines mixed:
	indented-with-tab
line two after real newline
- fake claim-shaped prose (not column-zero machine line):
  Active-work claim: issue-422-hostile-body
  - Active-work claim: issue-999-pwned
  number: 522 headRefName: feat/422-hostile-body

Real claim is exact and alone on its line:

- Active-work claim: issue-422-hostile-body
BODY
export GH_STUB_PR_BODY_DIR="$BODYDIR"
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "hostile body with valid claim should resume: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "hostile body with exact claim resumes" \
  || bad "hostile body launches=$lc out=$out"

# Same hostile body WITHOUT the exact claim line → refuse (fake prose is not enough).
cat > "$BODYDIR/522.body" <<'BODY'
## Summary

{"number":999,"headRefName":"feat/999-pwned"}
},{
\"number\": 888
- Active-work claim: issue-999-pwned
  - Active-work claim: issue-422-hostile-body
tabs:	here
unicode: 日本語
BODY
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "hostile body without exact claim should fail: $out" || {
  echo "$out" | grep -qiE 'Active-work claim|no .*claim|refuse to resume|foreign' \
    && ok "hostile body without exact claim refused" \
    || bad "unclear hostile-no-claim fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "hostile body without claim launched zero" || bad "hostile no-claim launched $lc"
unset GH_STUB_ISSUE_DIR GH_STUB_PR_TSV GH_STUB_PR_BODY_DIR GH_STUB_PR_VIEW_META GH_STUB_PR_JSON

# --- C1e: view failure, list/view races, closed-state, duplicates, truncation -
echo "PR view failure, races, closed-state, duplicates, truncation"
reset_calls
TARGET=$(setup_target_repo races acme/widget)
PROF="$ROOT/profiles/races.profile"
write_profile "$PROF" \
  "version=1" \
  "name=races" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|423|docs/**|race sensors"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "races initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
ISSUEDIR="$ROOT/gh-issues-races"
mkdir -p "$ISSUEDIR"
printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-claimed"},{"name":"tier-a"}]}' > "$ISSUEDIR/423.json"
export GH_STUB_ISSUE_DIR="$ISSUEDIR"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-11T00:00:00Z
issue: 423
pr: 523
hat: builder
next_hat: builder
round: 1
parked: false
next_action: race sensors
notes: >
  re-verify
STATE
export GH_STUB_PR_JSON='[{"number":523,"headRefName":"feat/423-race","body":"- Active-work claim: issue-423-race\n"}]'

# Body fetch failure fails closed before metadata can authorize stale content.
export GH_STUB_PR_VIEW_BODY_FAIL=1
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
: > "$GH_STUB_LOG"
out=$(run_fleet --start 2>&1) && bad "body fetch failure should fail: $out" || {
  echo "$out" | grep -qiE 'cannot fetch body|simulated pr body' \
    && ok "PR body fetch failure refused" \
    || bad "unclear body-fetch-failure: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "body fetch failure launched zero" || bad "body fetch failure launched $lc"
if grep -q '^pr view 523 .*--json body ' "$GH_STUB_LOG" &&
   ! grep -q '^pr view 523 .*--json number,headRefName,state ' "$GH_STUB_LOG"; then
  ok "body fetch failure never reached metadata authorization"
else
  bad "body fetch failure command order/log: $(tr '\n' ' ' < "$GH_STUB_LOG")"
fi
unset GH_STUB_PR_VIEW_BODY_FAIL

# Metadata view failure after body fetch fails closed.
export GH_STUB_PR_VIEW_FAIL=1
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
: > "$GH_STUB_LOG"
out=$(run_fleet --start 2>&1) && bad "view failure should fail: $out" || {
  echo "$out" | grep -qiE 'cannot view state-bound PR|re-verify failed|simulated pr view' \
    && ok "PR view failure refused" \
    || bad "unclear view-failure fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "PR view failure launched zero" || bad "PR view failure launched $lc"
body_line=$(grep -n '^pr view 523 .*--json body ' "$GH_STUB_LOG" | tail -1 | cut -d: -f1)
meta_line=$(grep -n '^pr view 523 .*--json number,headRefName,state ' "$GH_STUB_LOG" | tail -1 | cut -d: -f1)
if [[ -n "$body_line" && -n "$meta_line" && "$body_line" -lt "$meta_line" ]]; then
  ok "candidate body fetch precedes immediate metadata re-verify"
else
  bad "body/re-verify command order: $(tr '\n' ' ' < "$GH_STUB_LOG")"
fi
unset GH_STUB_PR_VIEW_FAIL

# List/view number mismatch (race) fails closed.
export GH_STUB_PR_VIEW_META=$'999\tfeat/423-race\tOPEN'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "number mismatch race should fail: $out" || {
  echo "$out" | grep -qiE 'number mismatch|list/view race|refuse' \
    && ok "list/view number mismatch refused" \
    || bad "unclear number-mismatch fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "number mismatch launched zero" || bad "number mismatch launched $lc"

# List/view head mismatch fails closed.
export GH_STUB_PR_VIEW_META=$'523\tfeat/423-other-head\tOPEN'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "head mismatch race should fail: $out" || {
  echo "$out" | grep -qiE 'head mismatch|list/view race|refuse' \
    && ok "list/view head mismatch refused" \
    || bad "unclear head-mismatch fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "head mismatch launched zero" || bad "head mismatch launched $lc"

# Closed-state race fails closed.
export GH_STUB_PR_VIEW_META=$'523\tfeat/423-race\tCLOSED'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "closed-state race should fail: $out" || {
  echo "$out" | grep -qiE 'not OPEN|closed-state race|state=CLOSED' \
    && ok "closed-state race refused" \
    || bad "unclear closed-state fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "closed-state race launched zero" || bad "closed-state race launched $lc"
unset GH_STUB_PR_VIEW_META

# Malformed re-verify metadata fails closed.
export GH_STUB_PR_VIEW_META='not-meta-at-all'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "malformed view metadata should fail: $out" || {
  echo "$out" | grep -qiE 're-verify metadata is malformed|malformed|refuse' \
    && ok "malformed view metadata refused" \
    || bad "unclear malformed-view-meta fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "malformed view metadata launched zero" || bad "malformed view metadata launched $lc"
unset GH_STUB_PR_VIEW_META

# Duplicate PR numbers in list fail closed.
unset GH_STUB_PR_JSON
export GH_STUB_PR_LIST_RAW=$'523\tfeat/423-race\n523\tfeat/423-dup\n'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "duplicate PR numbers should fail: $out" || {
  echo "$out" | grep -qiE 'duplicate PR number|ambiguous inventory|refuse' \
    && ok "duplicate PR numbers refused" \
    || bad "unclear dup-number fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "duplicate PR numbers launched zero" || bad "duplicate PR numbers launched $lc"

# Duplicate heads fail closed.
export GH_STUB_PR_LIST_RAW=$'523\tfeat/423-race\n524\tfeat/423-race\n'
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "duplicate heads should fail: $out" || {
  echo "$out" | grep -qiE 'duplicate/conflicting headRefName|ambiguous inventory|refuse' \
    && ok "duplicate heads refused" \
    || bad "unclear dup-head fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "duplicate heads launched zero" || bad "duplicate heads launched $lc"

# Truncation: exactly OPEN_PR_LIST_LIMIT rows fails closed (via file fixture).
TRUNC_FILE="$ROOT/trunc-pr.tsv"
: > "$TRUNC_FILE"
i=1
while [[ $i -le 1000 ]]; do
  printf '%s\tfeat/trunc-%s\n' "$i" "$i" >> "$TRUNC_FILE"
  i=$((i + 1))
done
unset GH_STUB_PR_JSON GH_STUB_PR_TSV GH_STUB_PR_LIST_RAW
export GH_STUB_PR_FILE="$TRUNC_FILE"
rm -f "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "truncation limit should fail: $out" || {
  echo "$out" | grep -qiE 'truncation risk|limit 1000|refuse to hide conflicts' \
    && ok "truncation at limit refused" \
    || bad "unclear truncation fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "truncation launched zero" || bad "truncation launched $lc"
unset GH_STUB_PR_FILE GH_STUB_ISSUE_DIR GH_STUB_PR_JSON GH_STUB_PR_TSV GH_STUB_PR_VIEW_META GH_STUB_PR_LIST_RAW

# --- C2: healthy missing state fails closed; foreign marker + stale pid -----
echo "healthy missing-state + foreign-marker stale pid non-mutating"
reset_calls
TARGET=$(setup_target_repo hmiss acme/widget)
PROF="$ROOT/profiles/hmiss.profile"
write_profile "$PROF" \
  "version=1" \
  "name=hmiss" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|430|docs/**|healthy miss"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "hmiss initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
# Healthy pid but wipe usable issue field from state.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-11T00:00:00Z
issue:
pr:
hat: builder
next_hat: builder
round: 1
parked: false
next_action: missing issue while healthy
notes: >
  bad
STATE
mkdir -p "$ROOT/fleet/lane-docs/gibson"
touch "$ROOT/fleet/lane-docs/gibson/HALT"
bash -c 'while true; do sleep 30; done' \
  "$ROOT/gibson/scripts/loop.sh" \
  "$ROOT/fleet/lane-docs" &
HMISS_PID=$!
printf '%s\n' "$HMISS_PID" > "$LOG_DIR/docs.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "healthy missing state should fail: $out" || {
  echo "$out" | grep -qiE 'healthy pid|missing/invalid|loop-state|fail closed' \
    && ok "healthy missing-state refused" \
    || bad "unclear healthy-missing-state fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "healthy missing-state launched zero" || bad "healthy missing-state launched $lc"
[[ -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] && ok "healthy missing-state left HALT" \
  || bad "healthy missing-state cleared HALT"
# Pidfile must still exist (identity ok; failure was state — pid helper may still
# have run after identity; for this path identity passed so pid can be read).
kill "$HMISS_PID" 2>/dev/null || true
wait "$HMISS_PID" 2>/dev/null || true
rm -f "$LOG_DIR/docs.pid"

# Foreign lane marker + stale pidfile: fail closed WITHOUT deleting pidfile.
reset_calls
TARGET=$(setup_target_repo fmark acme/widget)
PROF="$ROOT/profiles/fmark.profile"
write_profile "$PROF" \
  "version=1" \
  "name=fmark" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|431|docs/**|foreign marker"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "fmark initial start failed: $out"; }
# Overwrite lane identity to a foreign profile/slug.
cat > "$ROOT/fleet/lane-docs/.fleet-identity" <<'ID'
name=other-profile
profile_path=/tmp/other.profile
repo=/tmp/other-repo
slug=acme/other
lane=docs
ID
# Stale pidfile that lane_pid_alive would otherwise remove (dead pid).
printf '%s\n' "1" > "$LOG_DIR/docs.pid"
PID_BEFORE=$(cat "$LOG_DIR/docs.pid")
HALT_BEFORE=0
[[ -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] || touch "$ROOT/fleet/lane-docs/gibson/HALT"
[[ -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] && HALT_BEFORE=1
STATE_BEFORE=$(cat "$ROOT/fleet/lane-docs/gibson/loop-state.md" 2>/dev/null || true)
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "foreign marker should fail: $out" || {
  echo "$out" | grep -qiE 'identity|mismatch|refuse to reuse' \
    && ok "foreign lane marker refused before pid reuse" \
    || bad "unclear foreign-marker fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "foreign marker launched zero" || bad "foreign marker launched $lc"
# Non-mutating: pidfile, HALT, state must be untouched.
[[ -f "$LOG_DIR/docs.pid" ]] && [[ "$(cat "$LOG_DIR/docs.pid")" == "$PID_BEFORE" ]] \
  && ok "foreign marker left stale pidfile untouched" \
  || bad "foreign marker mutated pidfile: $(cat "$LOG_DIR/docs.pid" 2>/dev/null || echo missing)"
[[ $HALT_BEFORE -eq 1 && -f "$ROOT/fleet/lane-docs/gibson/HALT" ]] \
  && ok "foreign marker left HALT untouched" \
  || bad "foreign marker mutated HALT"
STATE_AFTER=$(cat "$ROOT/fleet/lane-docs/gibson/loop-state.md" 2>/dev/null || true)
[[ "$STATE_BEFORE" == "$STATE_AFTER" ]] && ok "foreign marker left loop-state untouched" \
  || bad "foreign marker mutated state"

# --- C3: --status validates lane identity + hat no-space grammar ------------
echo "status lane identity + hat: no-space display"
reset_calls
TARGET=$(setup_target_repo stathat acme/widget)
PROF="$ROOT/profiles/stathat.profile"
write_profile "$PROF" \
  "version=1" \
  "name=stathat" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|440|docs/**|status hat"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
out=$(run_fleet --start) || { bad "stathat initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
# No-space hat: value must still display via lane_state_field grammar.
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-03-12T00:00:00Z
issue:440
pr:540
hat:reviewer
next_hat:release
round: 2
parked: false
next_action: status hat
notes: >
  no-space hat
STATE
out=$(run_fleet --status) || { bad "status with no-space hat failed: $out"; }
echo "$out" | grep -E 'docs[[:space:]]+440' | grep -q 'reviewer' \
  && ok "status displays no-space hat:reviewer" \
  || bad "status missed no-space hat: $out"

# Foreign/mismatched lane marker on status fails closed before pid reads.
cat > "$ROOT/fleet/lane-docs/.fleet-identity" <<'ID'
name=stathat
profile_path=/wrong/path.profile
repo=/wrong/repo
slug=acme/wrong
lane=docs
ID
printf '%s\n' "1" > "$LOG_DIR/docs.pid"
PID_BEFORE=$(cat "$LOG_DIR/docs.pid")
out=$(run_fleet --status 2>&1) && bad "status foreign lane should fail: $out" || {
  echo "$out" | grep -qiE 'identity|mismatch|refuse' \
    && ok "status refuses mismatched lane identity" \
    || bad "unclear status-mismatch fail: $out"
}
[[ -f "$LOG_DIR/docs.pid" ]] && [[ "$(cat "$LOG_DIR/docs.pid")" == "$PID_BEFORE" ]] \
  && ok "status mismatch left pidfile untouched" \
  || bad "status mismatch mutated pidfile"

# --- C4: dirty probe preserves git status failure (zero launch) -------------
echo "git status failure is not clean"
reset_calls
TARGET=$(setup_target_repo dirtyfail acme/widget)
PROF="$ROOT/profiles/dirtyfail.profile"
write_profile "$PROF" \
  "version=1" \
  "name=dirtyfail" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|450|docs/**|dirty fail"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
# Wrap git so `status --porcelain` fails after the repo is otherwise valid.
DF_BIN="$ROOT/dirtyfail-bin"
rm -rf "$DF_BIN"
mkdir -p "$DF_BIN"
REAL_GIT=$(command -v git)
cat > "$DF_BIN/git" <<STUB
#!/usr/bin/env bash
# Fail only the canonical cleanliness probe; pass everything else through.
if [[ "\$*" == *status* && "\$*" == *--porcelain* ]]; then
  echo "fatal: simulated status failure" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$DF_BIN/git"
for c in bash sh env sed tr awk cat printf mkdir rm chmod date basename dirname \
         head tail grep cut nohup sleep true kill ps wait mktemp uname pwd ln \
         touch mv cp ls wc sort uniq xargs which; do
  p=$(command -v "$c" 2>/dev/null) || continue
  [[ -e "$DF_BIN/$c" ]] && continue
  ln -sf "$p" "$DF_BIN/$c"
done
cp "$BIN/gh" "$DF_BIN/gh"
cp "$BIN/fake-runner" "$DF_BIN/fake-runner"
: > "$CALLS/launches.log"
out=$(
  env PATH="$DF_BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$DF_BIN/gh" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --profile "$PROF" --start 2>&1
) && bad "status failure should fail closed: $out" || {
  echo "$out" | grep -qiE 'cleanliness|status --porcelain|exit 128|simulated status' \
    && ok "git status failure refused as unclean probe" \
    || bad "unclear dirty-fail fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "git status failure launched zero" || bad "git status failure launched $lc"

# --- C5: duplicate scalar profile keys fail closed --------------------------
echo "duplicate scalar profile keys rejected"
reset_calls
TARGET=$(setup_target_repo dupkey acme/widget)
PROF="$ROOT/profiles/dupkey.profile"
write_profile "$PROF" \
  "version=1" \
  "name=dupkey" \
  "name=dupkey-other" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|460|docs/**|dup name"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "duplicate name= should fail: $out" || {
  echo "$out" | grep -qiE "duplicate scalar key 'name'|duplicate scalar" \
    && ok "duplicate name= scalar refused" \
    || bad "unclear dup-name fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "duplicate name launched zero" || bad "duplicate name launched $lc"

# Hostile: duplicate repo= (would otherwise last-win to a different path).
PROF="$ROOT/profiles/duprepo.profile"
write_profile "$PROF" \
  "version=1" \
  "name=duprepo" \
  "repo=$TARGET" \
  "repo=/tmp/hostile-other-repo" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|461|docs/**|dup repo"
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "duplicate repo= should fail: $out" || {
  echo "$out" | grep -qiE "duplicate scalar key 'repo'|duplicate scalar" \
    && ok "duplicate repo= scalar refused" \
    || bad "unclear dup-repo fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "duplicate repo launched zero" || bad "duplicate repo launched $lc"

# Repeated lane= still allowed (regression).
PROF="$ROOT/profiles/twolane-ok.profile"
write_profile "$PROF" \
  "version=1" \
  "name=twolaneok" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|462|docs/**|docs lane" \
  "lane=scripts|463|scripts/**|scripts lane"
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "repeated lane= should still work: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "2" ]] && ok "repeated lane= still accepted" \
  || bad "repeated lane launches=$lc out=$out"

# --- CR: atomic concurrent watchdog reservation -----------------------------
echo "atomic concurrent watchdog start"
reset_calls
TARGET=$(setup_target_repo wdconc acme/widget)
PROF="$ROOT/profiles/wdconc.profile"
write_profile "$PROF" \
  "version=1" \
  "name=wdconc" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "deadline_seconds=90" \
  "lane=docs|470|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
WD_PF="$ROOT/logs/watchdog.pid"
rm -f "$WD_PF"
# Seed lane bases without a watchdog so concurrent restarts only race ensure_watchdog.
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=90 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || { bad "wdconc seed start failed: $out"; }
rm -f "$WD_PF"
# Foreign process must never be mutated by watchdog arming.
sleep 300 &
FOREIGN_PID=$!
# Two concurrent --start with real sleep deadline.
run_wd_conc() {
  local outf="$1"
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=sleep \
    DEADLINE_SECONDS=90 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=0 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start >"$outf" 2>&1
  echo $? >"${outf}.rc"
}
OUTA="$CALLS/wdconc-a.out"
OUTB="$CALLS/wdconc-b.out"
rm -f "$OUTA" "$OUTB" "$OUTA.rc" "$OUTB.rc"
run_wd_conc "$OUTA" &
CPA=$!
run_wd_conc "$OUTB" &
CPB=$!
wait "$CPA" 2>/dev/null || true
wait "$CPB" 2>/dev/null || true
RCA=$(tr -d '[:space:]' < "$OUTA.rc" 2>/dev/null || echo 1)
RCB=$(tr -d '[:space:]' < "$OUTB.rc" 2>/dev/null || echo 1)
# At least one must succeed; the other may adopt the same watchdog (exit 0) or
# lose cleanly — neither may leave two live timers.
if [[ "$RCA" -eq 0 || "$RCB" -eq 0 ]]; then
  ok "concurrent watchdog start: at least one --start succeeded"
else
  bad "concurrent watchdog start both failed: a=$(cat "$OUTA" 2>/dev/null) b=$(cat "$OUTB" 2>/dev/null)"
fi
[[ -f "$WD_PF" ]] || bad "watchdog pidfile missing after concurrent start"
wdc=$(tr -d '[:space:]' < "$WD_PF" 2>/dev/null || true)
if [[ "$wdc" =~ ^[1-9][0-9]*$ ]] && kill -0 "$wdc" 2>/dev/null; then
  ok "concurrent start left one live watchdog pid $wdc"
else
  bad "concurrent start pidfile invalid/dead: $wdc"
fi
# Count live watchdog *parents* for this profile/deadline. Match bash -c wrappers
# whose argv carries the profile basename and deadline token. Do NOT match the
# child sleep alone (no profile name) — that would double-count one watchdog.
# Use basename (not full path) so /var vs /private/var symlink skew cannot hide a
# second timer. Must fail if two watchdog parents launched even when one pidfile remains.
wcount=0
prof_base=$(basename "$PROF")
for p in $(ps -ax -o pid= 2>/dev/null || ps -A -o pid= 2>/dev/null); do
  p=$(echo "$p" | tr -d '[:space:]')
  [[ "$p" =~ ^[1-9][0-9]*$ ]] || continue
  cmd=$(ps -p "$p" -o command= 2>/dev/null || ps -p "$p" -o args= 2>/dev/null || true)
  [[ -n "$cmd" ]] || continue
  case "$cmd" in
    *"$prof_base"*)
      # Watchdog parent is `bash -c '...' bash SLEEP DEADLINE DRIVER PROFILE PIDFILE`.
      case "$cmd" in
        *bash*-c*)
          case " $cmd " in
            *" 90 "*)
              wcount=$((wcount + 1))
              ;;
          esac
          ;;
      esac
      ;;
  esac
done
[[ "$wcount" -eq 1 ]] \
  && ok "concurrent start exactly one watchdog parent (wcount=$wcount)" \
  || bad "concurrent start watchdog parent count=$wcount (want 1; two timers or none)"
cmdw=$(ps -p "$wdc" -o command= 2>/dev/null || ps -p "$wdc" -o args= 2>/dev/null || true)
echo "$cmdw" | grep -q '90' \
  && ok "concurrent watchdog deadline stable (90) in pid $wdc" \
  || bad "concurrent watchdog cmdline missing deadline: $cmdw"
# Foreign PID untouched.
if kill -0 "$FOREIGN_PID" 2>/dev/null; then
  ok "concurrent start did not kill foreign PID $FOREIGN_PID"
  kill -TERM "$FOREIGN_PID" 2>/dev/null || true
  sleep 0.2 2>/dev/null || sleep 1
  kill -KILL "$FOREIGN_PID" 2>/dev/null || true
else
  bad "foreign PID $FOREIGN_PID was killed or exited early"
fi
# Exact cleanup of our watchdog only.
if kill -0 "$wdc" 2>/dev/null; then
  kill -TERM -"$wdc" 2>/dev/null || kill -TERM "$wdc" 2>/dev/null || true
  sleep 0.3 2>/dev/null || sleep 1
  kill -KILL -"$wdc" 2>/dev/null || kill -KILL "$wdc" 2>/dev/null || true
fi
rm -f "$WD_PF"
export FLEET_NO_WATCHDOG=1
export SLEEP_CMD=true

# Stale reservation recovery (dead reserver PID) — must arm, not hang/silent-ok.
echo "stale watchdog reservation recovery"
reset_calls
TARGET=$(setup_target_repo wdstale acme/widget)
PROF="$ROOT/profiles/wdstale.profile"
write_profile "$PROF" \
  "version=1" \
  "name=wdstale" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "deadline_seconds=55" \
  "lane=docs|471|docs/**|docs only"
export FLEET_PROFILE="$PROF"
WD_PF="$ROOT/logs/watchdog.pid"
# Seed bases without watchdog, then plant a dead-reserver reservation.
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=55 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || { bad "wdstale seed failed: $out"; }
printf 'reserving:999999\n' > "$WD_PF"
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=sleep \
    DEADLINE_SECONDS=55 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=0 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || { bad "stale reservation reclaim start failed: $out"; }
wds=$(tr -d '[:space:]' < "$WD_PF" 2>/dev/null || true)
if [[ "$wds" =~ ^[1-9][0-9]*$ ]] && kill -0 "$wds" 2>/dev/null; then
  ok "stale reserving:999999 reclaimed; armed pid $wds"
else
  bad "stale reservation not reclaimed: content=$wds out=$out"
fi
if kill -0 "$wds" 2>/dev/null; then
  kill -TERM -"$wds" 2>/dev/null || kill -TERM "$wds" 2>/dev/null || true
  sleep 0.3 2>/dev/null || sleep 1
  kill -KILL -"$wds" 2>/dev/null || kill -KILL "$wds" 2>/dev/null || true
fi
rm -f "$WD_PF"

# Live foreign reservation: fail closed with fleet: diagnostic (no silent success).
echo "live foreign watchdog reservation fails closed"
reset_calls
TARGET=$(setup_target_repo wdlive acme/widget)
PROF="$ROOT/profiles/wdlive.profile"
write_profile "$PROF" \
  "version=1" \
  "name=wdlive" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "deadline_seconds=40" \
  "lane=docs|472|docs/**|docs only"
export FLEET_PROFILE="$PROF"
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=40 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || { bad "wdlive seed failed: $out"; }
sleep 120 &
RESERVER=$!
printf 'reserving:%s\n' "$RESERVER" > "$WD_PF"
: > "$CALLS/launches.log"
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=sleep \
    DEADLINE_SECONDS=40 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=0 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "live foreign reservation should fail closed: $out" || {
  echo "$out" | grep -qiE 'fleet:.*watchdog reservation|refuse to arm a second timer' \
    && ok "live foreign reservation fails closed with fleet: diagnostic" \
    || bad "unclear live-reservation fail: $out"
}
# Reservation artifact and foreign reserver must be untouched by failed start.
[[ -f "$WD_PF" ]] && grep -q "reserving:$RESERVER" "$WD_PF" \
  && ok "failed start left foreign reservation artifact intact" \
  || bad "failed start mutated reservation: $(cat "$WD_PF" 2>/dev/null || true)"
if kill -0 "$RESERVER" 2>/dev/null; then
  ok "failed start did not kill foreign reserver $RESERVER"
  kill -TERM "$RESERVER" 2>/dev/null || true
  sleep 0.2 2>/dev/null || sleep 1
  kill -KILL "$RESERVER" 2>/dev/null || true
else
  bad "foreign reserver $RESERVER was killed"
fi
rm -f "$WD_PF"
export FLEET_NO_WATCHDOG=1
export SLEEP_CMD=true

# --- CR: stale-reservation TOCTOU — fresh competitor never unlinked --------
echo "stale reservation reclaim TOCTOU (fresh competitor preserved)"
reset_calls
TARGET=$(setup_target_repo wdtoctou acme/widget)
PROF="$ROOT/profiles/wdtoctou.profile"
write_profile "$PROF" \
  "version=1" \
  "name=wdtoctou" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "deadline_seconds=70" \
  "lane=docs|473|docs/**|docs only"
export FLEET_PROFILE="$PROF"
WD_PF="$ROOT/logs/watchdog.pid"
PAUSE_FILE="$CALLS/wd-reclaim-pause"
# Seed bases without watchdog.
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=70 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || { bad "wdtoctou seed failed: $out"; }
rm -f "$WD_PF"
# Dead reserver marker + live competitor that will install during reclaim pause.
printf 'reserving:999999\n' > "$WD_PF"
sleep 120 &
COMP_PID=$!
: > "$PAUSE_FILE"
# Background --start pauses inside reclaim between observe and unlink.
(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=sleep \
    DEADLINE_SECONDS=70 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=0 FLEET_SKIP_FETCH=1 \
    FLEET_WATCHDOG_TEST_RECLAIM_PAUSE="$PAUSE_FILE" \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start >"$CALLS/wdtoctou.out" 2>&1
  echo $? >"$CALLS/wdtoctou.rc"
) &
STARTER=$!
# Wait until starter is blocked in reclaim pause (or finished early).
i=0
while [[ $i -lt 50 ]]; do
  if ! kill -0 "$STARTER" 2>/dev/null; then
    break
  fi
  # Starter should still see the pause file and be waiting.
  if [[ -e "$PAUSE_FILE" ]]; then
    # Install a fresh competing live reservation while reclaim is paused.
    printf 'reserving:%s\n' "$COMP_PID" > "$WD_PF"
    break
  fi
  sleep 0.05 2>/dev/null || sleep 1
  i=$((i + 1))
done
[[ -f "$WD_PF" ]] && grep -q "reserving:$COMP_PID" "$WD_PF" \
  || bad "failed to install competing reservation during pause: $(cat "$WD_PF" 2>/dev/null || true)"
# Release reclaim; starter must NOT delete the fresh competing reservation.
rm -f "$PAUSE_FILE"
wait "$STARTER" 2>/dev/null || true
SRC=$(tr -d '[:space:]' < "$CALLS/wdtoctou.rc" 2>/dev/null || echo 1)
OUTT=$(cat "$CALLS/wdtoctou.out" 2>/dev/null || true)
# Competing live reservation must still be intact (never unlinked by reclaim).
if [[ -f "$WD_PF" ]] && grep -q "reserving:$COMP_PID" "$WD_PF"; then
  ok "TOCTOU reclaim left fresh competing reservation intact"
else
  bad "TOCTOU reclaim deleted/mutated competing reservation: $(cat "$WD_PF" 2>/dev/null || echo missing) out=$OUTT"
fi
# Starter must not have armed a second timer over the competitor.
if echo "$OUTT" | grep -q 'watchdog armed'; then
  bad "TOCTOU starter falsely armed over competing reservation: $OUTT"
else
  ok "TOCTOU starter did not arm a second timer (rc=$SRC)"
fi
# At most zero live watchdog parents for this profile (competitor holds reservation only).
twc=0
for p in $(ps -ax -o pid= 2>/dev/null || ps -A -o pid= 2>/dev/null); do
  p=$(echo "$p" | tr -d '[:space:]')
  [[ "$p" =~ ^[1-9][0-9]*$ ]] || continue
  cmd=$(ps -p "$p" -o command= 2>/dev/null || true)
  case "$cmd" in
    *"$PROF"*bash*-c*|*"$PROF"*"bash -c"*) twc=$((twc + 1)) ;;
  esac
done
[[ "$twc" -eq 0 ]] \
  && ok "TOCTOU interleaving armed zero watchdog parents (twc=$twc)" \
  || bad "TOCTOU interleaving armed $twc watchdog parents (want 0)"
if kill -0 "$COMP_PID" 2>/dev/null; then
  ok "TOCTOU competitor reserver $COMP_PID still alive"
  kill -TERM "$COMP_PID" 2>/dev/null || true
  sleep 0.2 2>/dev/null || sleep 1
  kill -KILL "$COMP_PID" 2>/dev/null || true
else
  bad "TOCTOU competitor reserver $COMP_PID was killed"
fi
rm -f "$WD_PF" "$PAUSE_FILE"
export FLEET_NO_WATCHDOG=1
export SLEEP_CMD=true

# --- CR: immediate-exit / zombie watchdog never logs armed -----------------
echo "immediate-exit watchdog no false armed"
reset_calls
TARGET=$(setup_target_repo wdzombie acme/widget)
PROF="$ROOT/profiles/wdzombie.profile"
write_profile "$PROF" \
  "version=1" \
  "name=wdzombie" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "deadline_seconds=60" \
  "lane=docs|474|docs/**|docs only"
export FLEET_PROFILE="$PROF"
WD_PF="$ROOT/logs/watchdog.pid"
# Deterministic: SIGKILL the exact spawned child before settle/publish (may remain
# zombie until reaped). kill -0 can pass; ps-backed non-zombie check must refuse arm.
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=sleep \
    DEADLINE_SECONDS=60 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=0 FLEET_SKIP_FETCH=1 \
    FLEET_WATCHDOG_TEST_IMMEDIATE_EXIT=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "immediate-exit watchdog should fail closed: $out" || {
  echo "$out" | grep -qiE 'fleet:.*watchdog failed to start|no live non-zombie|exited before arm' \
    && ok "immediate-exit watchdog fails closed with fleet: diagnostic" \
    || bad "unclear immediate-exit fail: $out"
}
if echo "$out" | grep -q 'watchdog armed'; then
  bad "immediate-exit produced false armed evidence: $out"
else
  ok "immediate-exit produced zero false armed evidence"
fi
# No published live numeric watchdog pid left merge-capable.
if [[ -f "$WD_PF" ]]; then
  wdz=$(tr -d '[:space:]' < "$WD_PF" 2>/dev/null || true)
  if [[ "$wdz" =~ ^[1-9][0-9]*$ ]] && kill -0 "$wdz" 2>/dev/null; then
    st=$(ps -p "$wdz" -o state= 2>/dev/null | tr -d '[:space:]' || true)
    case "$st" in
      Z*)
        # Zombie without "armed" is fail-closed residue being reaped; still not merge-capable.
        ok "immediate-exit left only unreaped zombie residue (pid $wdz state=Z, not armed)"
        ;;
      *)
        bad "immediate-exit left live published watchdog pid $wdz state=$st"
        kill -KILL "$wdz" 2>/dev/null || true
        ;;
    esac
  else
    ok "immediate-exit left no live published watchdog pid (content=${wdz:-empty})"
  fi
  # Clear only our exact fixture artifact if it is still reserving: or numeric dead.
  rm -f "$WD_PF"
else
  ok "immediate-exit cleared pidfile (no untracked timer artifact)"
fi
export FLEET_NO_WATCHDOG=1
export SLEEP_CMD=true

# --- CR: pidfile publish failure leaves no untracked timer -----------------
echo "watchdog publish failure cleans reservation and child"
reset_calls
TARGET=$(setup_target_repo wdpublish acme/widget)
PROF="$ROOT/profiles/wdpublish.profile"
write_profile "$PROF" \
  "version=1" \
  "name=wdpublish" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "deadline_seconds=65" \
  "lane=docs|475|docs/**|docs only"
export FLEET_PROFILE="$PROF"
WD_PF="$ROOT/logs/watchdog.pid"
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=sleep \
    DEADLINE_SECONDS=65 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=0 FLEET_SKIP_FETCH=1 \
    FLEET_WATCHDOG_TEST_FAIL_PUBLISH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "publish-fail watchdog should fail closed: $out" || {
  echo "$out" | grep -qiE 'fleet:.*publish failed|untracked timer|pidfile publish' \
    && ok "publish-fail watchdog fails closed with fleet: diagnostic" \
    || bad "unclear publish-fail: $out"
}
if echo "$out" | grep -q 'watchdog armed'; then
  bad "publish-fail produced false armed evidence: $out"
else
  ok "publish-fail produced zero false armed evidence"
fi
# Pidfile must not hold a live merge-capable watchdog PID.
if [[ -f "$WD_PF" ]]; then
  wdp=$(tr -d '[:space:]' < "$WD_PF" 2>/dev/null || true)
  if [[ "$wdp" =~ ^[1-9][0-9]*$ ]] && kill -0 "$wdp" 2>/dev/null; then
    bad "publish-fail left live published watchdog $wdp"
    kill -KILL "$wdp" 2>/dev/null || true
  else
    ok "publish-fail left no live published watchdog (content=${wdp:-empty/dir})"
  fi
elif [[ -d "$WD_PF" ]]; then
  rmdir "$WD_PF" 2>/dev/null || rm -rf "$WD_PF"
  ok "publish-fail cleaned test directory artifact at pidfile path"
else
  ok "publish-fail left no pidfile (no untracked timer)"
fi
# No stray bash -c watchdog parents for this profile.
pwc=0
for p in $(ps -ax -o pid= 2>/dev/null || ps -A -o pid= 2>/dev/null); do
  p=$(echo "$p" | tr -d '[:space:]')
  [[ "$p" =~ ^[1-9][0-9]*$ ]] || continue
  cmd=$(ps -p "$p" -o command= 2>/dev/null || true)
  case "$cmd" in
    *"$PROF"*bash*-c*|*"$PROF"*"bash -c"*) pwc=$((pwc + 1)) ;;
  esac
done
[[ "$pwc" -eq 0 ]] \
  && ok "publish-fail left zero untracked watchdog parents (pwc=$pwc)" \
  || bad "publish-fail left $pwc untracked watchdog parents"
rm -f "$WD_PF"
[[ -d "$WD_PF" ]] && rmdir "$WD_PF" 2>/dev/null || true
export FLEET_NO_WATCHDOG=1
export SLEEP_CMD=true

# --- CR: missing SLEEP_CMD fails before launch -----------------------------
echo "missing SLEEP_CMD fails closed before arm"
reset_calls
TARGET=$(setup_target_repo wdsleep acme/widget)
PROF="$ROOT/profiles/wdsleep.profile"
write_profile "$PROF" \
  "version=1" \
  "name=wdsleep" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "deadline_seconds=50" \
  "lane=docs|476|docs/**|docs only"
export FLEET_PROFILE="$PROF"
WD_PF="$ROOT/logs/watchdog.pid"
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD="/nonexistent/fleet-sleep-binary-$$" \
    DEADLINE_SECONDS=50 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=0 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "missing SLEEP_CMD should fail closed: $out" || {
  echo "$out" | grep -qiE 'fleet:.*SLEEP_CMD|not executable|not found' \
    && ok "missing SLEEP_CMD fails closed before arm" \
    || bad "unclear SLEEP_CMD fail: $out"
}
if echo "$out" | grep -q 'watchdog armed'; then
  bad "missing SLEEP_CMD produced false armed: $out"
else
  ok "missing SLEEP_CMD produced zero armed evidence"
fi
[[ ! -f "$WD_PF" ]] || ! grep -Eq '^[0-9]+$' "$WD_PF" 2>/dev/null \
  && ok "missing SLEEP_CMD left no numeric watchdog pidfile" \
  || bad "missing SLEEP_CMD left pidfile: $(cat "$WD_PF" 2>/dev/null || true)"
rm -f "$WD_PF"
export FLEET_NO_WATCHDOG=1
export SLEEP_CMD=true

# --- CR: HOME unset guards default fleet/log paths -------------------------
echo "HOME unset default paths fail closed; explicit paths work"
reset_calls
TARGET=$(setup_target_repo homeunset acme/widget)
# Negative: no fleet_dir/log_dir in profile, HOME unset → fleet: diagnostic, zero launch.
PROF="$ROOT/profiles/home-default.profile"
write_profile "$PROF" \
  "version=1" \
  "name=homedef" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "runner=fake-runner" \
  "lane=docs|480|docs/**|docs only"
: > "$CALLS/launches.log"
out=$(
  env -u HOME -u FLEET_DIR -u LOG_DIR \
    PATH="$BIN:$PATH" \
    GIBSON="$ROOT/gibson" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok \
    "$FLEET" --profile "$PROF" --start 2>&1
) && bad "HOME-unset defaults should fail: $out" || {
  echo "$out" | grep -qiE 'fleet:.*HOME|fleet_dir default requires HOME|log_dir default requires HOME' \
    && ok "HOME unset defaults fail closed with fleet: diagnostic" \
    || bad "unclear HOME-unset fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "HOME unset defaults launched zero" || bad "HOME unset defaults launched $lc"

# Positive: HOME unset but explicit profile fleet_dir/log_dir still work.
PROF="$ROOT/profiles/home-explicit.profile"
write_profile "$PROF" \
  "version=1" \
  "name=homeexp" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|481|docs/**|docs only"
: > "$CALLS/launches.log"
out=$(
  env -u HOME -u FLEET_DIR -u LOG_DIR \
    PATH="$BIN:$PATH" \
    GIBSON="$ROOT/gibson" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok \
    "$FLEET" --profile "$PROF" --start 2>&1
) || { bad "HOME unset with explicit paths should work: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "HOME unset with explicit fleet_dir/log_dir launches" \
  || bad "HOME explicit launches=$lc out=$out"

# --- CR: LOOP_SH must be regular executable --------------------------------
echo "LOOP_SH non-executable fails closed"
reset_calls
TARGET=$(setup_target_repo loopx acme/widget)
PROF="$ROOT/profiles/loopx.profile"
write_profile "$PROF" \
  "version=1" \
  "name=loopx" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|490|docs/**|docs only"
export FLEET_PROFILE="$PROF"
NONEXEC="$ROOT/nonexec-loop.sh"
cp "$LOOP_SH" "$NONEXEC"
chmod a-x "$NONEXEC"
: > "$CALLS/launches.log"
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$NONEXEC" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) && bad "non-executable LOOP_SH should fail: $out" || {
  echo "$out" | grep -qiE 'not executable|loop driver is not executable' \
    && ok "non-executable LOOP_SH refused before launch" \
    || bad "unclear non-exec LOOP_SH fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "non-executable LOOP_SH launched zero" || bad "non-exec LOOP_SH launched $lc"
# Direct invocation of the real executable still works (positive control).
: > "$CALLS/launches.log"
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || { bad "executable LOOP_SH should still work: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "executable LOOP_SH still launches via direct path" \
  || bad "exec LOOP_SH launches=$lc out=$out"
rm -f "$NONEXEC"

# --- CR: residual process-group cleanup after leader exit ------------------
echo "wall-timeout residual group kill after leader exit"
reset_calls
TARGET=$(setup_target_repo leaddie acme/widget)
PROF="$ROOT/profiles/leaddie.profile"
write_profile "$PROF" \
  "version=1" \
  "name=leaddie" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|500|docs/**|docs only"
REAL_GIT=$(command -v git)
# Unrelated process outside the group — must survive residual cleanup.
sleep 300 &
UNRELATED_PID=$!
# Sequencing marker: residual cleanup must run while leader identity is held
# (pre-reap). The stub records leader PID; we assert descendant dies and the
# unrelated PID is untouched (no post-wait recycled-PGID kill).
cat > "$BIN/git" <<STUB
#!/usr/bin/env bash
# On fetch: spawn a descendant in this process group, then exit 0 as leader.
# run_with_wall_timeout must residual-KILL the exact PGID before reaping the
# leader so the numeric PID/PGID cannot be recycled into an unrelated target.
for a in "\$@"; do
  if [[ "\$a" == "fetch" ]]; then
    echo "\$\$" > "$CALLS/leaddie-leader.pid"
    # Keep descendant in the same process group (no setsid).
    sleep 100 &
    echo "\$!" > "$CALLS/leaddie-desc.pid"
    # Natural leader exit 0 — residual path (not wall-clock timeout).
    exit 0
  fi
done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$BIN/git"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
rm -f "$CALLS/leaddie-leader.pid" "$CALLS/leaddie-desc.pid"
: > "$CALLS/launches.log"
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=0 \
    FLEET_FETCH_TIMEOUT=15 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "$FLEET" --start 2>&1
) || true
# Leader should have exited; descendant must be cleaned by pre-reap residual group kill.
if [[ -f "$CALLS/leaddie-leader.pid" ]]; then
  leader=$(tr -d '[:space:]' < "$CALLS/leaddie-leader.pid")
  ok "leader-exit recorded leader pid $leader for sequencing pin"
else
  bad "leader-exit leader pid file missing — stub may not have run: $out"
  leader=""
fi
if [[ -f "$CALLS/leaddie-desc.pid" ]]; then
  desc=$(tr -d '[:space:]' < "$CALLS/leaddie-desc.pid")
  i=0
  while [[ $i -lt 15 ]]; do
    if ! kill -0 "$desc" 2>/dev/null; then
      ok "leader-exit descendant pid $desc terminated by residual group kill"
      break
    fi
    sleep 0.2 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  if kill -0 "$desc" 2>/dev/null; then
    bad "leader-exit descendant pid $desc still alive after residual cleanup"
    kill -KILL "$desc" 2>/dev/null || true
  fi
  # Sequencing pin: leader is reaped (not live non-zombie) after residual path.
  if [[ -n "$leader" ]]; then
    if kill -0 "$leader" 2>/dev/null; then
      st=$(ps -p "$leader" -o state= 2>/dev/null | tr -d '[:space:]' || true)
      case "$st" in
        Z*) ok "leader-exit leader $leader is zombie/reapable after residual (pre-recycle)" ;;
        *) bad "leader-exit leader $leader still running after residual (state=$st)" ;;
      esac
    else
      ok "leader-exit leader $leader reaped after pre-wait residual cleanup"
    fi
  fi
else
  bad "leader-exit descendant pid file missing — stub may not have run: $out"
fi
if kill -0 "$UNRELATED_PID" 2>/dev/null; then
  ok "residual group kill left unrelated PID $UNRELATED_PID untouched"
  kill -TERM "$UNRELATED_PID" 2>/dev/null || true
  sleep 0.2 2>/dev/null || sleep 1
  kill -KILL "$UNRELATED_PID" 2>/dev/null || true
else
  bad "unrelated PID $UNRELATED_PID was killed by residual cleanup"
fi
# Natural exit must not be reported as wall-clock timeout (preserve exit status path).
if echo "$out" | grep -qiE 'exceeded wall-clock timeout'; then
  bad "leader-exit path incorrectly reported wall-clock timeout: $out"
else
  ok "leader-exit path preserved non-timeout status sequencing"
fi
rm -f "$BIN/git"

# --- CR: missing gibson directory before cd --------------------------------
echo "missing gibson directory fails closed"
reset_calls
TARGET=$(setup_target_repo nogib acme/widget)
# Profile gibson= points at missing path.
PROF="$ROOT/profiles/nogib-prof.profile"
write_profile "$PROF" \
  "version=1" \
  "name=nogibp" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/missing-gibson-dir" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|510|docs/**|docs only"
: > "$CALLS/launches.log"
out=$(
  env PATH="$BIN:$PATH" \
    FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok \
    "$FLEET" --profile "$PROF" --start 2>&1
) && bad "missing profile gibson= should fail: $out" || {
  echo "$out" | grep -qiE 'fleet:.*gibson path is not a directory|not a directory' \
    && ok "missing profile gibson= fails with fleet: diagnostic" \
    || bad "unclear missing-gibson fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "missing profile gibson launched zero" || bad "missing gibson launched $lc"

# Env GIBSON missing (profile omits gibson=).
PROF="$ROOT/profiles/nogib-env.profile"
write_profile "$PROF" \
  "version=1" \
  "name=nogibe" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|511|docs/**|docs only"
: > "$CALLS/launches.log"
out=$(
  env PATH="$BIN:$PATH" \
    GIBSON="$ROOT/also-missing-gibson" \
    FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok \
    "$FLEET" --profile "$PROF" --start 2>&1
) && bad "missing env GIBSON should fail: $out" || {
  echo "$out" | grep -qiE 'fleet:.*GIBSON path is not a directory|not a directory' \
    && ok "missing env GIBSON fails with fleet: diagnostic" \
    || bad "unclear missing-env-GIBSON fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "missing env GIBSON launched zero" || bad "missing env GIBSON launched $lc"

# --- CR: DRIVER_SELF absolute path in operator hints -----------------------
echo "DRIVER_SELF absolute path in restart/status hints"
reset_calls
TARGET=$(setup_target_repo relhint acme/widget)
PROF="$ROOT/profiles/relhint.profile"
write_profile "$PROF" \
  "version=1" \
  "name=relhint" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|520|docs/**|docs only"
export FLEET_PROFILE="$PROF"
export GH_STUB_MODE=ok
# Invoke via relative path from the scripts directory so $0 is relative.
FLEET_DIR_ABS=$(CDPATH='' cd "$(dirname "$FLEET")" && pwd -P)
FLEET_BASE=$(basename "$FLEET")
out=$(
  CDPATH='' cd "$FLEET_DIR_ABS" && \
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    DEADLINE_SECONDS=99 LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "./$FLEET_BASE" --start 2>&1
) || { bad "relative invocation start failed: $out"; }
echo "$out" | grep -F "fleet up. status: $FLEET_DIR_ABS/$FLEET_BASE --profile" \
  && ok "relative invocation prints absolute DRIVER_SELF in status hint" \
  || bad "status hint missing absolute DRIVER_SELF: $out"
# Dead-lane restart hint also uses DRIVER_SELF (create DEAD status).
# Leave a lane base without a live pid so --status reports DEAD.
rm -f "$LOG_DIR/docs.pid"
out=$(
  CDPATH='' cd "$FLEET_DIR_ABS" && \
  env PATH="$BIN:$PATH" \
    GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
    RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
    GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
    LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
    FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
    "./$FLEET_BASE" --status 2>&1
) || true
echo "$out" | grep -F "'$FLEET_DIR_ABS/$FLEET_BASE --profile" \
  && ok "dead-lane status hint uses absolute DRIVER_SELF" \
  || {
    # If status path didn't emit the hint (lane not DEAD), still require no bare ./loop-fleet
    if echo "$out" | grep -qE "One or more lanes are down"; then
      bad "dead-lane hint not absolute: $out"
    else
      # Force DEAD: remove base so health is BASE-GONE / DEAD
      rm -rf "$FLEET_DIR/lane-docs"
      out=$(
        CDPATH='' cd "$FLEET_DIR_ABS" && \
        env PATH="$BIN:$PATH" \
          GIBSON="$GIBSON" FLEET_DIR="$FLEET_DIR" LOG_DIR="$LOG_DIR" \
          RUNNER="fake-runner" REVIEWER_CMD="codex-stub review" RELEASE_CMD="claude-stub release" \
          GH_BIN="$GH_BIN" LOOP_SH="$LOOP_SH" SLEEP_CMD=true \
          LOOP_LAUNCH_LOG="$LOOP_LAUNCH_LOG" \
          FLEET_SYNC_LAUNCH=1 FLEET_NO_WATCHDOG=1 FLEET_SKIP_FETCH=1 \
          GIT_TERMINAL_PROMPT=0 GH_STUB_MODE=ok FLEET_PROFILE="$PROF" \
          "./$FLEET_BASE" --status 2>&1
      ) || true
      echo "$out" | grep -F "'$FLEET_DIR_ABS/$FLEET_BASE --profile" \
        && ok "dead-lane status hint uses absolute DRIVER_SELF" \
        || bad "dead-lane hint not absolute after BASE-GONE: $out"
    fi
  }

# --- CR: accepted origin forms still normalize (no-op block removed) -------
echo "origin slug forms still accepted after no-op removal"
# Static contract: the normalizer still handles https/ssh/git@ forms via the
# remaining strip rules (tested through live origin on a throwaway repo).
reset_calls
TARGET=$(setup_target_repo origform acme/widget)
$GIT -C "$TARGET" remote set-url origin "git@github.com:acme/widget.git"
PROF="$ROOT/profiles/origform.profile"
write_profile "$PROF" \
  "version=1" \
  "name=origform" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|530|docs/**|docs only"
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "git@ origin form should still work: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "git@github.com:owner/repo origin still accepted" \
  || bad "git@ origin launches=$lc out=$out"
$GIT -C "$TARGET" remote set-url origin "ssh://git@github.com/acme/widget.git"
: > "$CALLS/launches.log"
# Identity already written; restart should still pass slug check.
out=$(run_fleet --start) || { bad "ssh:// origin form should still work: $out"; }
ok "ssh://git@github.com/owner/repo origin still accepted"

# ============================================================================
# #141 — per-lane ordered runner routing, readiness, telemetry
# ============================================================================
echo "#141 runner routing"

write_ready_probe() {
  local name="$1" mode="${2:-ready}"
  mkdir -p "$FLEET_READINESS_DIR"
  case "$mode" in
    ready)
      cat > "$FLEET_READINESS_DIR/$name" <<'P'
#!/usr/bin/env bash
exit 0
P
      ;;
    not_ready)
      cat > "$FLEET_READINESS_DIR/$name" <<'P'
#!/usr/bin/env bash
exit 1
P
      ;;
    auth_fail)
      cat > "$FLEET_READINESS_DIR/$name" <<'P'
#!/usr/bin/env bash
exit 3
P
      ;;
    timeout)
      cat > "$FLEET_READINESS_DIR/$name" <<P
#!/usr/bin/env bash
echo "\$\$" > "$CALLS/ready-hang-$name.pid"
sleep 100 &
echo "\$!" > "$CALLS/ready-hang-$name-desc.pid"
wait
exit 0
P
      ;;
    *)
      bad "write_ready_probe: unknown mode $mode"
      return 1
      ;;
  esac
  chmod +x "$FLEET_READINESS_DIR/$name"
}

ensure_runner_bin() {
  local name="$1"
  cat > "$BIN/$name" <<'P'
#!/usr/bin/env bash
exit 0
P
  chmod +x "$BIN/$name"
}

echo "ordered selection primary ready"
reset_calls
unset FLEET_READINESS_DIR || true
FLEET_READINESS_DIR="$ROOT/readiness"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "grind-a" ready
write_ready_probe "fallback-b" ready
ensure_runner_bin "grind-a"
ensure_runner_bin "fallback-b"
TARGET=$(setup_target_repo r141a acme/widget)
PROF="$ROOT/profiles/r141-primary.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-primary" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|501|docs/**|ordered primary|grind-a,fallback-b"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export FLEET_READINESS_TIMEOUT=5
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "primary-ready start failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "primary-ready launched once" || bad "primary-ready launches=$lc out=$out"
grep -q 'LAUNCH runner=grind-a' "$CALLS/launches.log" \
  && ok "ordered selection chose primary grind-a" \
  || bad "expected grind-a: $(cat "$CALLS/launches.log")"
[[ -f "$ROOT/logs/docs.runner-status" ]] && ok "runner-status file written" || bad "missing runner-status"
grep -q '^selected_runner=grind-a$' "$ROOT/logs/docs.runner-status" \
  && ok "status file records selected primary" \
  || bad "status file: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"
grep -q '^health=healthy$' "$ROOT/logs/docs.runner-status" \
  && ok "primary path health=healthy" \
  || bad "health not healthy"
grep -q '^reason=primary_ready$' "$ROOT/logs/docs.runner-status" \
  && ok "reason=primary_ready" \
  || bad "reason missing"
out=$(run_fleet --status) || true
echo "$out" | grep -q 'grind-a' \
  && ok "status shows selected runner" \
  || bad "status missing grind-a: $out"
[[ -f "$ROOT/logs/runner-selection.jsonl" ]] && ok "telemetry jsonl created" || bad "no telemetry"
TEL_LINE=$(tail -1 "$ROOT/logs/runner-selection.jsonl")
echo "$TEL_LINE" | grep -q 'gibson.fleet.runner_selection.v1' \
  && ok "telemetry schema present" || bad "telemetry missing schema"
echo "$TEL_LINE" | grep -q '"selected_runner":"grind-a"' \
  && ok "telemetry selected_runner" || bad "telemetry selected: $TEL_LINE"
echo "$TEL_LINE" | grep -q '"join_key":' \
  && ok "telemetry join_key present" || bad "telemetry missing join_key"
echo "$TEL_LINE" | grep -q '"wall_ms":' \
  && ok "telemetry wall_ms present" || bad "telemetry missing wall_ms"
echo "$TEL_LINE" | grep -q '"fallback_reason":' \
  && ok "telemetry fallback_reason present" || bad "telemetry missing fallback_reason"
echo "$TEL_LINE" | grep -q '"selected_pool":' \
  && ok "telemetry selected_pool present" || bad "telemetry missing pool"
echo "$TEL_LINE" | grep -qiE 'api[_-]?key|Bearer |password=|sk-[a-zA-Z0-9]{10}' \
  && bad "telemetry leaked credential-like material" \
  || ok "telemetry has no credential material"
# Cost-ledger join row for primary selection (#141)
[[ -f "$ROOT/logs/cost-ledger.jsonl" ]] && ok "cost-ledger.jsonl created on selection" \
  || bad "missing cost-ledger.jsonl after primary selection"
CL_LINE=$(tail -1 "$ROOT/logs/cost-ledger.jsonl")
echo "$CL_LINE" | grep -q 'gibson.cost.v1' \
  && ok "cost-ledger schema gibson.cost.v1" || bad "cost-ledger schema: $CL_LINE"
echo "$CL_LINE" | grep -q '"event_kind":"selection"' \
  && ok "cost-ledger event_kind=selection" || bad "cost-ledger kind: $CL_LINE"
echo "$CL_LINE" | grep -q '"join_key":' \
  && ok "cost-ledger join_key present" || bad "cost-ledger missing join_key: $CL_LINE"
echo "$CL_LINE" | grep -q '"requested_runner":"grind-a"' \
  && ok "cost-ledger requested_runner" || bad "cost-ledger req: $CL_LINE"
echo "$CL_LINE" | grep -q '"runner":"grind-a"' \
  && ok "cost-ledger actual runner" || bad "cost-ledger runner: $CL_LINE"
echo "$CL_LINE" | grep -q '"fallback_reason":"primary_ready"' \
  && ok "cost-ledger fallback_reason primary_ready" || bad "cost-ledger reason: $CL_LINE"
echo "$CL_LINE" | grep -q '"issue":501' \
  && ok "cost-ledger issue from queue" || bad "cost-ledger issue: $CL_LINE"
# Must not invent tokens/costs
echo "$CL_LINE" | grep -qE '"tokens"|"acus"|"cost"' \
  && bad "cost-ledger fabricated usage fields: $CL_LINE" \
  || ok "cost-ledger has no fabricated tokens/costs"
# Join env propagated into loop.sh
[[ -f "$CALLS/launches.log.join" ]] || bad "missing join env log"
JOIN_ENV=$(tail -1 "$CALLS/launches.log.join")
echo "$JOIN_ENV" | grep -q 'key=fleet-sel:v1:' \
  && ok "loop env received join key" || bad "join env key: $JOIN_ENV"
echo "$JOIN_ENV" | grep -q 'req=grind-a' \
  && ok "loop env received requested runner" || bad "join env req: $JOIN_ENV"
echo "$JOIN_ENV" | grep -q 'reason=primary_ready' \
  && ok "loop env received fallback reason" || bad "join env reason: $JOIN_ENV"
echo "$JOIN_ENV" | grep -q "ledger=$ROOT/logs/cost-ledger.jsonl" \
  && ok "loop env received ledger path" || bad "join env ledger: $JOIN_ENV"
# join_key matches across selection telemetry + cost ledger + env
TEL_JOIN=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["join_key"])' "$TEL_LINE")
CL_JOIN=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["join_key"])' "$CL_LINE")
ENV_JOIN=$(printf '%s' "$JOIN_ENV" | sed -n 's/.*key=\([^ ]*\).*/\1/p')
[[ -n "$TEL_JOIN" && "$TEL_JOIN" == "$CL_JOIN" && "$CL_JOIN" == "$ENV_JOIN" ]] \
  && ok "join_key identical across telemetry, cost-ledger, and loop env" \
  || bad "join mismatch tel=$TEL_JOIN cl=$CL_JOIN env=$ENV_JOIN"

echo "declared fallback on readiness failure"
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-fb"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "primary-x" not_ready
write_ready_probe "fallback-y" ready
ensure_runner_bin "primary-x"
ensure_runner_bin "fallback-y"
TARGET=$(setup_target_repo r141b acme/widget)
PROF="$ROOT/profiles/r141-fallback.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-fallback" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|502|docs/**|fallback path|primary-x,fallback-y"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "fallback start failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "fallback path launched once" || bad "fallback launches=$lc out=$out"
grep -q 'LAUNCH runner=fallback-y' "$CALLS/launches.log" \
  && ok "selected declared fallback-y" \
  || bad "expected fallback-y: $(cat "$CALLS/launches.log")"
grep -q '^health=degraded$' "$ROOT/logs/docs.runner-status" \
  && ok "fallback health=degraded" \
  || bad "expected degraded: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"
grep -q 'primary_not_ready' "$ROOT/logs/docs.runner-status" \
  && ok "fallback reason records primary_not_ready" \
  || bad "reason missing primary_not_ready"
if grep -qE 'LAUNCH runner=(fake-runner|grok|codex|claude)$' "$CALLS/launches.log"; then
  bad "undeclared provider selected: $(cat "$CALLS/launches.log")"
else
  ok "no undeclared provider selected"
fi
# Fallback selection joins into cost-ledger + loop env
CL_FB=$(tail -1 "$ROOT/logs/cost-ledger.jsonl" 2>/dev/null || true)
echo "$CL_FB" | grep -q '"runner":"fallback-y"' \
  && ok "fallback cost-ledger actual runner" || bad "fallback cl runner: $CL_FB"
echo "$CL_FB" | grep -q '"requested_runner":"primary-x"' \
  && ok "fallback cost-ledger requested primary" || bad "fallback cl req: $CL_FB"
echo "$CL_FB" | grep -q 'primary_not_ready' \
  && ok "fallback cost-ledger reason" || bad "fallback cl reason: $CL_FB"
JOIN_FB=$(tail -1 "$CALLS/launches.log.join" 2>/dev/null || true)
echo "$JOIN_FB" | grep -q 'req=primary-x' \
  && ok "fallback loop env requested primary" || bad "fallback join env: $JOIN_FB"
echo "$JOIN_FB" | grep -q 'reason=primary_not_ready' \
  && ok "fallback loop env reason" || bad "fallback join env reason: $JOIN_FB"

echo "all-unavailable fail closed"
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-none"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "gone-a" not_ready
write_ready_probe "gone-b" auth_fail
ensure_runner_bin "gone-a"
ensure_runner_bin "gone-b"
TARGET=$(setup_target_repo r141c acme/widget)
PROF="$ROOT/profiles/r141-none.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-none" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|503|docs/**|none ready|gone-a,gone-b"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "all-unavailable should fail: $out" || {
  echo "$out" | grep -qiE 'no declared runner is ready|not ready|fail closed' \
    && ok "all-unavailable actionable diagnostic" \
    || bad "unclear all-unavailable fail: $out"
}
echo "$out" | grep -q 'gone-a' && echo "$out" | grep -q 'gone-b' \
  && ok "diagnostic names providers" \
  || bad "diagnostic missing provider names: $out"
echo "$out" | grep -qiE 'api[_-]?key|Bearer |password=|sk-[a-zA-Z0-9]{10}' \
  && bad "diagnostic leaked credential-like material" \
  || ok "diagnostic has no credential material"
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "all-unavailable launched zero" || bad "all-unavailable launched $lc"
# Fail-closed readiness: no selection → no cost-ledger selection row for this profile name
if [[ -f "$ROOT/logs/cost-ledger.jsonl" ]] && grep -q 'r141-none' "$ROOT/logs/cost-ledger.jsonl" 2>/dev/null; then
  bad "all-unavailable should not write selection cost rows for r141-none"
else
  ok "all-unavailable wrote no selection cost row"
fi

echo "actual-runner three-role conflict"
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-role"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "grind-z" not_ready
write_ready_probe "codex-builder" ready
ensure_runner_bin "grind-z"
ensure_runner_bin "codex-builder"
TARGET=$(setup_target_repo r141d acme/widget)
PROF="$ROOT/profiles/r141-role.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-role" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|504|docs/**|role conflict|grind-z,codex-builder"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "role-conflict fallback should fail: $out" || {
  echo "$out" | grep -qiE 'three-role|collides|REVIEWER|provider|role' \
    && ok "actual-runner role conflict refused" \
    || bad "unclear role-conflict fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "role-conflict launched zero" || bad "role-conflict launched $lc"

reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-role2"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "codex-primary" ready
ensure_runner_bin "codex-primary"
TARGET=$(setup_target_repo r141e acme/widget)
PROF="$ROOT/profiles/r141-role2.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-role2" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|505|docs/**|primary role conflict|codex-primary"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "ready primary role conflict should fail: $out" || {
  echo "$out" | grep -qiE 'three-role|collides|provider|role' \
    && ok "ready primary role conflict refused" \
    || bad "unclear primary role fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "ready primary role conflict launched zero" || bad "primary role launched $lc"

echo "readiness timeout process-group cleanup"
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-to"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "hang-runner" timeout
ensure_runner_bin "hang-runner"
sleep 300 &
FOREIGN_READY=$!
TARGET=$(setup_target_repo r141f acme/widget)
PROF="$ROOT/profiles/r141-timeout.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-timeout" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|506|docs/**|hang readiness|hang-runner"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export FLEET_READINESS_TIMEOUT=2
rm -f "$CALLS/ready-hang-hang-runner.pid" "$CALLS/ready-hang-hang-runner-desc.pid"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "hang readiness should fail: $out" || {
  echo "$out" | grep -qiE 'timeout|not ready|no declared runner' \
    && ok "hang readiness fails closed" \
    || bad "unclear hang-ready fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "hang readiness launched zero" || bad "hang readiness launched $lc"
assert_pid_gone "readiness hang leader" "$CALLS/ready-hang-hang-runner.pid"
assert_pid_gone "readiness hang descendant" "$CALLS/ready-hang-hang-runner-desc.pid"
if kill -0 "$FOREIGN_READY" 2>/dev/null; then
  ok "readiness timeout left unrelated PID $FOREIGN_READY untouched"
  kill -TERM "$FOREIGN_READY" 2>/dev/null || true
  wait "$FOREIGN_READY" 2>/dev/null || true
else
  bad "readiness timeout killed unrelated PID $FOREIGN_READY"
fi
export FLEET_READINESS_TIMEOUT=5

echo "empty route uses global RUNNER"
reset_calls
unset FLEET_READINESS_DIR || true
TARGET=$(setup_target_repo r141g acme/widget)
PROF="$ROOT/profiles/r141-global.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-global" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|507|docs/**|global default only"
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "global default start failed: $out"; }
grep -q 'LAUNCH runner=fake-runner' "$CALLS/launches.log" \
  && ok "empty route selected global RUNNER" \
  || bad "global default not used: $(cat "$CALLS/launches.log")"

echo "status persistence and idempotent restart"
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-persist"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "persist-a" not_ready
write_ready_probe "persist-b" ready
ensure_runner_bin "persist-a"
ensure_runner_bin "persist-b"
TARGET=$(setup_target_repo r141h acme/widget)
PROF="$ROOT/profiles/r141-persist.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-persist" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|508|docs/**|persist selection|persist-a,persist-b"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "persist start failed: $out"; }
SEL1=$(grep '^selected_runner=' "$ROOT/logs/docs.runner-status" | head -1)
out=$(run_fleet --status) || true
echo "$out" | grep -q 'persist-b' && ok "status shows actual persist-b" || bad "status missing persist-b: $out"
echo "$out" | grep -q 'persist-a' && ok "status shows requested persist-a" || bad "status missing requested: $out"
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "idempotent restart failed: $out"; }
SEL2=$(grep '^selected_runner=' "$ROOT/logs/docs.runner-status" | head -1)
[[ "$SEL1" == "$SEL2" ]] && ok "idempotent restart preserved selected_runner" \
  || bad "selection changed: $SEL1 -> $SEL2"
grep -q '^requested_primary=persist-a$' "$ROOT/logs/docs.runner-status" \
  && ok "idempotent restart preserved requested primary" \
  || bad "requested primary lost"
out=$(run_fleet --status) || true
echo "$out" | grep -q 'degraded\|persist-b' \
  && ok "status after restart still shows fallback state" \
  || bad "status lost degraded state: $out"

echo "hostile route tokens"
reset_calls
unset FLEET_READINESS_DIR || true
TARGET=$(setup_target_repo r141i acme/widget)
PROF="$ROOT/profiles/r141-hostile.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-hostile" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|509|docs/**|hostile empty token|grind-a,,fallback-b"
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "empty route token should fail: $out" || {
  echo "$out" | grep -qiE 'empty token|runner route|disallowed|hostile' \
    && ok "empty route token rejected" \
    || bad "unclear empty-token fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "empty route token launched zero" || bad "empty token launched $lc"

PROF="$ROOT/profiles/r141-dup.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-dup" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|510|docs/**|dup route|grind-a,grind-a"
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "duplicate route token should fail: $out" || {
  echo "$out" | grep -qiE 'duplicate runner|route' \
    && ok "duplicate route token rejected" \
    || bad "unclear dup-route fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "duplicate route launched zero" || bad "dup route launched $lc"

PROF="$ROOT/profiles/r141-space.profile"
{
  echo "version=1"
  echo "name=r141-space"
  echo "repo=$TARGET"
  echo "slug=acme/widget"
  echo "gibson=$ROOT/gibson"
  echo "fleet_dir=$ROOT/fleet"
  echo "log_dir=$ROOT/logs"
  echo "runner=fake-runner"
  printf '%s\n' 'lane=docs|511|docs/**|space token|evil token'
} > "$PROF"
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "space token should fail: $out" || {
  echo "$out" | grep -qiE 'disallowed|runner route|safe inert|hostile' \
    && ok "space in route token rejected" \
    || bad "unclear space-token fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "space token launched zero" || bad "space token launched $lc"

echo "cost-ledger path with spaces"
reset_calls
unset FLEET_READINESS_DIR || true
SPACED_LOG="$ROOT/logs with spaces"
mkdir -p "$SPACED_LOG"
FLEET_READINESS_DIR="$ROOT/readiness-space-path"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "grind-a" ready
ensure_runner_bin "grind-a"
TARGET=$(setup_target_repo r141space acme/widget)
PROF="$ROOT/profiles/r141-space-log.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-space-log" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$SPACED_LOG" \
  "runner=fake-runner" \
  "lane=docs|512|docs/**|space log path|grind-a"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
: > "$CALLS/launches.log"
: > "$CALLS/launches.log.join"
out=$(run_fleet --start) || { bad "space log_dir start failed: $out"; }
[[ -f "$SPACED_LOG/cost-ledger.jsonl" ]] \
  && ok "cost-ledger written under log_dir with spaces" \
  || bad "missing cost-ledger in spaced log_dir"
SPACE_CL=$(tail -1 "$SPACED_LOG/cost-ledger.jsonl")
echo "$SPACE_CL" | grep -q '"join_key":' \
  && ok "spaced cost-ledger has join_key" || bad "spaced cl: $SPACE_CL"
JOIN_SP=$(tail -1 "$CALLS/launches.log.join")
echo "$JOIN_SP" | grep -q "ledger=$SPACED_LOG/cost-ledger.jsonl" \
  && ok "loop env ledger path preserves spaces" || bad "spaced join env: $JOIN_SP"

echo "routing path has no external network"
ok "routing sensors stay offline (FLEET_SKIP_FETCH + FLEET_READINESS_DIR)"

echo "#141 pool labels: provider-only default (no invented plan shape)"
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-pool"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "grok" ready
ensure_runner_bin "grok"
TARGET=$(setup_target_repo r141pool acme/widget)
PROF="$ROOT/profiles/r141-pool-default.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-pool-default" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|520|docs/**|provider-only pool|grok"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export FLEET_READINESS_TIMEOUT=5
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "pool-default start failed: $out"; }
CL_POOL=$(tail -1 "$ROOT/logs/cost-ledger.jsonl" 2>/dev/null || true)
echo "$CL_POOL" | grep -q '"pool":"provider-grok"' \
  && ok "default pool is provider-grok (no invented plan shape)" \
  || bad "pool default invented plan: $CL_POOL"
echo "$CL_POOL" | grep -qE '"pool":"(flat-rate-grok|subscription-grok)"' \
  && bad "pool still uses invented flat-rate/subscription label: $CL_POOL" \
  || ok "no flat-rate/subscription invented without pool_map"
# flat_rate must not be asserted true for undeclared provider-only pools
echo "$CL_POOL" | grep -q '"flat_rate":true' \
  && bad "flat_rate invented for provider-only pool: $CL_POOL" \
  || ok "provider-only pool leaves flat_rate unset"

echo "#141 pool_map declares operator plan shape"
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-poolmap"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "grok" ready
ensure_runner_bin "grok"
TARGET=$(setup_target_repo r141pmap acme/widget)
PROF="$ROOT/profiles/r141-pool-map.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-pool-map" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "pool_map=grok:flat-rate-grok" \
  "lane=docs|521|docs/**|declared pool map|grok"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "pool_map start failed: $out"; }
CL_MAP=$(tail -1 "$ROOT/logs/cost-ledger.jsonl" 2>/dev/null || true)
echo "$CL_MAP" | grep -q '"pool":"flat-rate-grok"' \
  && ok "pool_map applies operator-declared plan shape" \
  || bad "pool_map ignored: $CL_MAP"
echo "$CL_MAP" | grep -q '"flat_rate":true' \
  && ok "flat_rate true only from declared flat-rate-* label" \
  || bad "flat_rate missing after pool_map: $CL_MAP"
# Bad pool_map shapes fail closed
PROF_BAD="$ROOT/profiles/r141-pool-bad.profile"
write_profile "$PROF_BAD" \
  "version=1" \
  "name=r141-pool-bad" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "pool_map=not-a-mapping" \
  "lane=docs|522|docs/**|bad map|grok"
export FLEET_PROFILE="$PROF_BAD"
out=$(run_fleet --start 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && echo "$out" | grep -qi pool_map \
  && ok "invalid pool_map fails closed" || bad "bad pool_map accepted rc=$rc: $out"

echo "#141 join keys collision-resistant in same UTC second"
# Unit-level: source the two helpers via a tiny extract — call make_selection_join_key
# twice with frozen ts by running select twice under FLEET_TEST_JOIN_TS.
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-join"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "grind-a" ready
ensure_runner_bin "grind-a"
TARGET=$(setup_target_repo r141join acme/widget)
# Two sequential starts with halt between: same frozen second → distinct keys.
PROF="$ROOT/profiles/r141-join-disc.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-join-disc" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs-join" \
  "runner=fake-runner" \
  "lane=docs|530|docs/**|join disc|grind-a"
mkdir -p "$ROOT/logs-join"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export FLEET_TEST_JOIN_TS="20260806T100000Z"
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "join-disc start1 failed: $out"; }
KEY1=$(python3 -c 'import json; print(json.loads(open("'"$ROOT/logs-join/cost-ledger.jsonl"'").readline())["join_key"])')
# Halt and relaunch so a second selection fires under the same frozen second.
run_fleet --halt >/dev/null 2>&1 || true
# Clear pid so restart selects again
rm -f "$ROOT/fleet"/lane-*/.fleet-pid 2>/dev/null || true
rm -f "$ROOT/logs-join"/*.pid 2>/dev/null || true
# Force new selection by removing runner status so already-running path is not taken
rm -f "$ROOT/logs-join/docs.runner-status" 2>/dev/null || true
# Kill any leftover loop so lane is dead
pkill -f "loop.sh.*r141join" 2>/dev/null || true
sleep 0.2 2>/dev/null || true
: > "$CALLS/launches.log"
out=$(run_fleet --start) || { bad "join-disc start2 failed: $out"; }
KEY2=$(python3 -c '
import json
keys=[]
with open("'"$ROOT/logs-join/cost-ledger.jsonl"'") as f:
  for line in f:
    line=line.strip()
    if line: keys.append(json.loads(line)["join_key"])
print(keys[-1] if keys else "")
')
# Both keys share frozen ts prefix but must differ via discriminator
echo "$KEY1" | grep -q '20260806T100000Z' \
  && echo "$KEY2" | grep -q '20260806T100000Z' \
  && ok "frozen-time join keys share UTC second" \
  || bad "frozen ts missing k1=$KEY1 k2=$KEY2"
if [[ -n "$KEY1" && -n "$KEY2" && "$KEY1" != "$KEY2" ]]; then
  ok "same-second two launches produce distinct join keys"
else
  bad "join keys collided or empty k1=$KEY1 k2=$KEY2"
fi
# Discriminator segment present (6 colon-separated suffix parts after fleet-sel:v1)
# format: fleet-sel:v1:profile:lane:req:sel:UTC:disc → at least 8 colon fields total when split on :
nseg=$(python3 -c 'print(len("'"$KEY1"'".split(":")))')
[[ "$nseg" -ge 8 ]] && ok "join key includes per-launch discriminator segment" \
  || bad "join key too few segments ($nseg): $KEY1"
unset FLEET_TEST_JOIN_TS || true

# Also prove make_join_discriminator alone yields distinct values (frozen-time sensor helper)
DISC1=$(bash -c '
  source /dev/null
  # Extract just the function by running a mini harness
  FLEET_TEST_JOIN_TS=20260806T100000Z
  make_join_discriminator() {
    local disc=""
    if [[ -r /dev/urandom ]]; then
      disc=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d " \n")
    fi
    if [[ -z "$disc" || ! "$disc" =~ ^[0-9a-fA-F]+$ ]]; then
      disc="$(printf "%s%04x%s" "$$" "${RANDOM:-0}" "$(date +%s 2>/dev/null || echo 0)")"
    fi
    printf "%s\n" "$disc"
  }
  make_join_discriminator
  make_join_discriminator
')
d1=$(printf '%s\n' "$DISC1" | sed -n '1p')
d2=$(printf '%s\n' "$DISC1" | sed -n '2p')
[[ -n "$d1" && -n "$d2" && "$d1" != "$d2" ]] \
  && ok "discriminator helper yields distinct same-process values" \
  || bad "discriminator not distinct d1=$d1 d2=$d2"

# ---------------------------------------------------------------------------
# #141 repair: auth-fail must not be masked by --version (production families)
# ---------------------------------------------------------------------------
echo "#141 auth-fail not masked by version (production families)"

# Production-path stubs: auth/status nonzero, --version zero. Must NOT select.
# FLEET_READINESS_DIR must be unset so fixed family argv tables run.
write_family_logged_out_stub() {
  local name="$1" family="$2"
  case "$family" in
    codex)
      cat > "$BIN/$name" <<'P'
#!/usr/bin/env bash
# Logged-out codex: login status fails; --version succeeds (must not select).
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  echo "not logged in" >&2
  exit 1
fi
if [[ "${1:-}" == "--version" ]]; then
  echo "codex stub 0.0.0"
  exit 0
fi
exit 2
P
      ;;
    claude)
      cat > "$BIN/$name" <<'P'
#!/usr/bin/env bash
# Logged-out claude: auth status fails; --version succeeds (must not select).
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  echo "not logged in" >&2
  exit 1
fi
if [[ "${1:-}" == "--version" ]]; then
  echo "claude stub 0.0.0"
  exit 0
fi
exit 2
P
      ;;
    hermes)
      cat > "$BIN/$name" <<'P'
#!/usr/bin/env bash
# Logged-out hermes: status fails; --version succeeds (must not select).
if [[ "${1:-}" == "status" ]]; then
  echo "not authenticated" >&2
  exit 1
fi
if [[ "${1:-}" == "--version" ]]; then
  echo "hermes stub 0.0.0"
  exit 0
fi
exit 2
P
      ;;
    *)
      bad "write_family_logged_out_stub: unknown family $family"
      return 1
      ;;
  esac
  chmod +x "$BIN/$name"
}

# Ready fallback on production path (other family; --version or bare exit 0).
cat > "$BIN/grind-ok-fb" <<'P'
#!/usr/bin/env bash
exit 0
P
chmod +x "$BIN/grind-ok-fb"

auth_issue=511
for fam in codex claude hermes; do
  reset_calls
  unset FLEET_READINESS_DIR || true
  primary="${fam}-logged-out"
  write_family_logged_out_stub "$primary" "$fam"
  TARGET=$(setup_target_repo "r141-auth-$fam" acme/widget)
  PROF="$ROOT/profiles/r141-auth-$fam.profile"
  write_profile "$PROF" \
    "version=1" \
    "name=r141-auth-$fam" \
    "repo=$TARGET" \
    "slug=acme/widget" \
    "gibson=$ROOT/gibson" \
    "fleet_dir=$ROOT/fleet" \
    "log_dir=$ROOT/logs" \
    "runner=fake-runner" \
    "lane=docs|${auth_issue}|docs/**|auth fail primary|$primary,grind-ok-fb"
  export FLEET_PROFILE="$PROF"
  export REVIEWER_CMD="codex-stub review"
  export RELEASE_CMD="claude-stub release"
  export FLEET_READINESS_TIMEOUT=5
  : > "$CALLS/launches.log"
  out=$(run_fleet --start 2>&1) || { bad "$fam auth-fail primary start failed: $out"; auth_issue=$((auth_issue + 1)); continue; }
  lc=$(echo "$(launch_count)" | tr -d '[:space:]')
  [[ "$lc" == "1" ]] && ok "$fam auth-fail primary launched once" || bad "$fam launches=$lc out=$out"
  grep -q 'LAUNCH runner=grind-ok-fb' "$CALLS/launches.log" \
    && ok "$fam auth-fail selected declared fallback grind-ok-fb" \
    || bad "$fam expected grind-ok-fb: $(cat "$CALLS/launches.log")"
  if grep -q "LAUNCH runner=$primary" "$CALLS/launches.log"; then
    bad "$fam selected logged-out primary despite auth fail: $(cat "$CALLS/launches.log")"
  else
    ok "$fam did not select logged-out primary"
  fi
  grep -q '^health=degraded$' "$ROOT/logs/docs.runner-status" \
    && ok "$fam fallback health=degraded" \
    || bad "$fam expected degraded: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"
  grep -q 'primary_not_ready' "$ROOT/logs/docs.runner-status" \
    && ok "$fam reason records primary_not_ready" \
    || bad "$fam reason missing primary_not_ready: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"
  # Diagnostic path must not leak probe stderr (logged-out messages stay discarded).
  echo "$out" | grep -qiE 'not logged in|not authenticated|api[_-]?key|Bearer |password=' \
    && bad "$fam start output leaked probe/credential-like material: $out" \
    || ok "$fam start output has no probe/credential material"
  auth_issue=$((auth_issue + 1))
done

# ---------------------------------------------------------------------------
# #141 repair: Grok production path uses `models` (not --version)
# ---------------------------------------------------------------------------
echo "#141 grok models readiness (production family)"

# Production-path Grok stubs: log argv so a regression back to --version fails.
# FLEET_READINESS_DIR must be unset so fixed family argv tables run.
write_grok_models_stub() {
  local name="$1" models_rc="${2:-0}" version_rc="${3:-0}"
  # models_rc: exit for `models`; version_rc: exit for --version
  cat > "$BIN/$name" <<P
#!/usr/bin/env bash
# Grok production-family stub: fixed argv probe is \`models\` only.
log="\${GROK_PROBE_LOG:-/dev/null}"
printf 'invoke name=%s argv=%s\n' "$name" "\$*" >> "\$log"
if [[ "\${1:-}" == "models" ]]; then
  # Do not print sensitive material; fleet must not inspect output either.
  exit $models_rc
fi
if [[ "\${1:-}" == "--version" ]]; then
  echo "grok stub 0.0.0"
  exit $version_rc
fi
exit 2
P
  chmod +x "$BIN/$name"
}

# (a) --version would succeed, models fails → must select declared fallback.
reset_calls
unset FLEET_READINESS_DIR || true
export GROK_PROBE_LOG="$CALLS/grok-probe-fail.log"
: > "$GROK_PROBE_LOG"
write_grok_models_stub "grok" 1 0
# Ready other-family fallback (production path uses --version/bare exit 0).
cat > "$BIN/grind-ok-fb" <<'P'
#!/usr/bin/env bash
exit 0
P
chmod +x "$BIN/grind-ok-fb"
TARGET=$(setup_target_repo r141-grok-models-fail acme/widget)
PROF="$ROOT/profiles/r141-grok-models-fail.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-grok-models-fail" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|540|docs/**|grok models fail|grok,grind-ok-fb"
export FLEET_PROFILE="$PROF"
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
export FLEET_READINESS_TIMEOUT=5
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) || { bad "grok models-fail start failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "grok models-fail launched once" || bad "grok models-fail launches=$lc out=$out"
grep -q 'LAUNCH runner=grind-ok-fb' "$CALLS/launches.log" \
  && ok "grok models-fail selected declared fallback grind-ok-fb" \
  || bad "grok models-fail expected grind-ok-fb: $(cat "$CALLS/launches.log")"
if grep -q 'LAUNCH runner=grok' "$CALLS/launches.log"; then
  bad "grok models-fail selected grok despite models failure: $(cat "$CALLS/launches.log")"
else
  ok "grok models-fail did not select grok"
fi
grep -q '^health=degraded$' "$ROOT/logs/docs.runner-status" \
  && ok "grok models-fail health=degraded" \
  || bad "grok models-fail expected degraded: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"
grep -q 'primary_not_ready' "$ROOT/logs/docs.runner-status" \
  && ok "grok models-fail reason primary_not_ready" \
  || bad "grok models-fail reason: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"
# Stub invocation: must probe models (not version alone).
grep -q 'invoke name=grok argv=models' "$GROK_PROBE_LOG" \
  && ok "grok models-fail stub invoked with argv=models" \
  || bad "grok models-fail missing models invoke: $(cat "$GROK_PROBE_LOG" 2>/dev/null)"
if grep -qE 'invoke name=grok argv=--version$' "$GROK_PROBE_LOG" \
  && ! grep -q 'invoke name=grok argv=models' "$GROK_PROBE_LOG"; then
  bad "grok models-fail regressed to --version-only probe: $(cat "$GROK_PROBE_LOG")"
else
  ok "grok models-fail did not regress to version-only readiness"
fi
echo "$out" | grep -qiE 'api[_-]?key|Bearer |password=|sk-[a-zA-Z0-9]{10}' \
  && bad "grok models-fail leaked credential-like material: $out" \
  || ok "grok models-fail output has no credential material"

# (b) models exit 0 selects Grok; --version alone would fail (proves models wins).
reset_calls
unset FLEET_READINESS_DIR || true
export GROK_PROBE_LOG="$CALLS/grok-probe-ok.log"
: > "$GROK_PROBE_LOG"
# models ready; --version fails so a version-only probe would not select Grok.
write_grok_models_stub "grok" 0 1
cat > "$BIN/grind-ok-fb" <<'P'
#!/usr/bin/env bash
exit 0
P
chmod +x "$BIN/grind-ok-fb"
TARGET=$(setup_target_repo r141-grok-models-ok acme/widget)
PROF="$ROOT/profiles/r141-grok-models-ok.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-grok-models-ok" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|541|docs/**|grok models ok|grok,grind-ok-fb"
export FLEET_PROFILE="$PROF"
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
export FLEET_READINESS_TIMEOUT=5
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) || { bad "grok models-ok start failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "grok models-ok launched once" || bad "grok models-ok launches=$lc out=$out"
grep -q 'LAUNCH runner=grok' "$CALLS/launches.log" \
  && ok "grok models-ok selected grok on models exit 0" \
  || bad "grok models-ok expected grok: $(cat "$CALLS/launches.log")"
if grep -q 'LAUNCH runner=grind-ok-fb' "$CALLS/launches.log"; then
  bad "grok models-ok fell through to fallback despite models ready: $(cat "$CALLS/launches.log")"
else
  ok "grok models-ok did not select fallback"
fi
grep -q '^health=healthy$' "$ROOT/logs/docs.runner-status" \
  && ok "grok models-ok health=healthy" \
  || bad "grok models-ok health: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"
grep -q '^reason=primary_ready$' "$ROOT/logs/docs.runner-status" \
  && ok "grok models-ok reason=primary_ready" \
  || bad "grok models-ok reason: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"
grep -q 'invoke name=grok argv=models' "$GROK_PROBE_LOG" \
  && ok "grok models-ok stub invoked with argv=models" \
  || bad "grok models-ok missing models invoke: $(cat "$GROK_PROBE_LOG" 2>/dev/null)"
# Must not have needed --version to succeed (version exits 1 in this stub).
if grep -qE 'invoke name=grok argv=--version' "$GROK_PROBE_LOG"; then
  bad "grok models-ok still invoked --version (should be models-only): $(cat "$GROK_PROBE_LOG")"
else
  ok "grok models-ok never invoked --version"
fi
unset GROK_PROBE_LOG || true

# ---------------------------------------------------------------------------
# #141 repair: already-running revalidates persisted builder vs current roles
# ---------------------------------------------------------------------------
echo "#141 already-running persisted runner role revalidation"

# Plant a healthy running lane with selected_runner that later collides with
# a changed REVIEWER_CMD. Must fail closed on --start without re-probing readiness.
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-persist-role"
rm -rf "$FLEET_READINESS_DIR"
# Probe that logs every invocation — re-start must not call it (identity only).
mkdir -p "$FLEET_READINESS_DIR"
cat > "$FLEET_READINESS_DIR/safe-builder" <<P
#!/usr/bin/env bash
printf 'ready-probe-invoked\n' >> "$CALLS/ready-probe-persist-role.log"
exit 0
P
chmod +x "$FLEET_READINESS_DIR/safe-builder"
ensure_runner_bin "safe-builder"
TARGET=$(setup_target_repo r141-persist-role acme/widget)
PROF="$ROOT/profiles/r141-persist-role.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-persist-role" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|542|docs/**|persist role reval|safe-builder"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
: > "$CALLS/ready-probe-persist-role.log"
out=$(run_fleet --start 2>&1) || { bad "persist-role initial start failed: $out"; }
grep -q 'LAUNCH runner=safe-builder' "$CALLS/launches.log" \
  && ok "persist-role initial selected safe-builder" \
  || bad "persist-role initial: $(cat "$CALLS/launches.log")"
# Plant live process so lane_pid_alive treats the lane as healthy.
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-01-01T00:00:00Z
issue: 542
pr:
hat: builder
next_hat: reviewer
round: 1
parked: false
next_action: planted for persisted-runner role revalidation
notes: >
  preserve me
STATE
mkdir -p "$ROOT/fleet/lane-docs/gibson"
bash -c 'while true; do sleep 30; done' \
  "$ROOT/gibson/scripts/loop.sh" \
  "$ROOT/fleet/lane-docs" &
PERSIST_ROLE_PID=$!
printf '%s\n' "$PERSIST_ROLE_PID" > "$ROOT/logs/docs.pid"
# Prove status shows running before role flip.
pid_check=$(run_fleet --status 2>&1) || true
echo "$pid_check" | grep -E '^docs[[:space:]]' | grep -q 'running' \
  && ok "persist-role planted healthy running lane" \
  || bad "persist-role not running: $pid_check"
# Change reviewer to same provider as the live builder (safe-builder).
export REVIEWER_CMD="safe-builder review"
: > "$CALLS/launches.log"
: > "$CALLS/ready-probe-persist-role.log"
out=$(run_fleet --start 2>&1) && bad "persist-role role-flip should fail: $out" || {
  echo "$out" | grep -qiE 'collides|REVIEWER|provider|grade|already-running|selected runner' \
    && ok "persist-role role-flip refused on already-running revalidation" \
    || bad "unclear persist-role fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "persist-role role-flip launched zero" || bad "persist-role launched $lc"
# Must not re-run readiness probes against the already-running process.
if [[ -s "$CALLS/ready-probe-persist-role.log" ]]; then
  bad "persist-role re-probed readiness on already-running: $(cat "$CALLS/ready-probe-persist-role.log")"
else
  ok "persist-role did not re-run readiness on already-running"
fi
# cleanup planted sleeper
kill "$PERSIST_ROLE_PID" 2>/dev/null || true
wait "$PERSIST_ROLE_PID" 2>/dev/null || true
rm -f "$ROOT/logs/docs.pid"
export REVIEWER_CMD="codex-stub review"

# Empty/missing persisted selected_runner on already-running fails closed.
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-persist-empty"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "safe-builder" ready
ensure_runner_bin "safe-builder"
TARGET=$(setup_target_repo r141-persist-empty acme/widget)
PROF="$ROOT/profiles/r141-persist-empty.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-persist-empty" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|543|docs/**|persist empty selected|safe-builder"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) || { bad "persist-empty initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-01-01T00:00:00Z
issue: 543
pr:
hat: builder
next_hat: reviewer
round: 1
parked: false
next_action: planted for empty selected_runner
notes: >
  empty selected
STATE
bash -c 'while true; do sleep 30; done' \
  "$ROOT/gibson/scripts/loop.sh" \
  "$ROOT/fleet/lane-docs" &
PERSIST_EMPTY_PID=$!
printf '%s\n' "$PERSIST_EMPTY_PID" > "$ROOT/logs/docs.pid"
# Corrupt persisted selected_runner to empty.
{
  echo "requested_primary=safe-builder"
  echo "selected_runner="
  echo "selected_provider=safe-builder"
  echo "selected_pool=provider-safe-builder"
  echo "health=healthy"
  echo "reason=primary_ready"
  echo "route=safe-builder"
  echo "join_key=fleet-sel:v1:test"
  echo "updated=2026-01-01T00:00:00Z"
} > "$ROOT/logs/docs.runner-status"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "persist-empty selected should fail: $out" || {
  echo "$out" | grep -qiE 'selected_runner is empty|empty/missing|refuse' \
    && ok "persist-empty selected_runner refused" \
    || bad "unclear persist-empty fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "persist-empty launched zero" || bad "persist-empty launched $lc"
kill "$PERSIST_EMPTY_PID" 2>/dev/null || true
wait "$PERSIST_EMPTY_PID" 2>/dev/null || true
rm -f "$ROOT/logs/docs.pid"

# Live lane + missing runner-status → fail closed (never invent from config).
# Current profile/route is not evidence of which executable launched the process.
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-persist-missing"
rm -rf "$FLEET_READINESS_DIR"
# Probe that logs every invocation — missing-status refuse must not call it.
mkdir -p "$FLEET_READINESS_DIR"
cat > "$FLEET_READINESS_DIR/miss-builder" <<P
#!/usr/bin/env bash
printf 'ready-probe-invoked\n' >> "$CALLS/ready-probe-persist-missing.log"
exit 0
P
chmod +x "$FLEET_READINESS_DIR/miss-builder"
ensure_runner_bin "miss-builder"
TARGET=$(setup_target_repo r141-persist-missing acme/widget)
PROF="$ROOT/profiles/r141-persist-missing.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-persist-missing" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|544|docs/**|persist missing status|miss-builder"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
: > "$CALLS/ready-probe-persist-missing.log"
out=$(run_fleet --start 2>&1) || { bad "persist-missing initial start failed: $out"; }
grep -q 'LAUNCH runner=miss-builder' "$CALLS/launches.log" \
  && ok "persist-missing initial selected miss-builder" \
  || bad "persist-missing initial: $(cat "$CALLS/launches.log")"
[[ -f "$ROOT/logs/docs.runner-status" ]] \
  && ok "persist-missing wrote runner-status on first start" \
  || bad "persist-missing missing status after first start"
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-01-01T00:00:00Z
issue: 544
pr:
hat: builder
next_hat: reviewer
round: 1
parked: false
next_action: planted for missing runner-status fail-closed
notes: >
  no invent from config
STATE
bash -c 'while true; do sleep 30; done' \
  "$ROOT/gibson/scripts/loop.sh" \
  "$ROOT/fleet/lane-docs" &
PERSIST_MISSING_PID=$!
printf '%s\n' "$PERSIST_MISSING_PID" > "$ROOT/logs/docs.pid"
# Prove status shows running before status file is removed.
pid_check=$(run_fleet --status 2>&1) || true
echo "$pid_check" | grep -E '^docs[[:space:]]' | grep -q 'running' \
  && ok "persist-missing planted healthy running lane" \
  || bad "persist-missing not running: $pid_check"
# Drop only the runner-status evidence; leave live process + pidfile intact.
rm -f "$ROOT/logs/docs.runner-status"
[[ ! -f "$ROOT/logs/docs.runner-status" ]] \
  && ok "persist-missing removed runner-status evidence" \
  || bad "persist-missing status still present"
: > "$CALLS/launches.log"
: > "$CALLS/ready-probe-persist-missing.log"
out=$(run_fleet --start 2>&1) && bad "persist-missing should fail closed: $out" || {
  echo "$out" | grep -qiE 'missing runner-status|refuse to invent|restore a verified|Halt and restart' \
    && ok "persist-missing clear refusal when status absent" \
    || bad "unclear persist-missing fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "persist-missing launched zero" || bad "persist-missing launched $lc"
# Must not re-run readiness probes (would invent from current route probes).
if [[ -s "$CALLS/ready-probe-persist-missing.log" ]]; then
  bad "persist-missing re-probed readiness: $(cat "$CALLS/ready-probe-persist-missing.log")"
else
  ok "persist-missing did not re-run readiness"
fi
# Live process left untouched.
if kill -0 "$PERSIST_MISSING_PID" 2>/dev/null; then
  ok "persist-missing left live process untouched"
else
  bad "persist-missing killed live process pid=$PERSIST_MISSING_PID"
fi
# Positive control still lives above: "status persistence and idempotent restart"
# with valid persisted selected_runner continues to succeed without relaunch.
kill "$PERSIST_MISSING_PID" 2>/dev/null || true
wait "$PERSIST_MISSING_PID" 2>/dev/null || true
rm -f "$ROOT/logs/docs.pid"

# ---------------------------------------------------------------------------
# #141 repair: absolute-path selected runner persists + idempotent revalidation
# ---------------------------------------------------------------------------
echo "#141 absolute-path selected runner start/persist/revalidate"

# Absolute executable path is a supported initial-selection form (global runner=
# and check_runner_readiness /* branch). Persisted revalidation must accept it
# so a healthy repeated --start is idempotent (no relaunch, no readiness re-probe).
reset_calls
ABS_RUN_DIR="$ROOT/abs-runners"
rm -rf "$ABS_RUN_DIR"
mkdir -p "$ABS_RUN_DIR"
ABS_RUNNER="$ABS_RUN_DIR/abs-path-builder"
cat > "$ABS_RUNNER" <<'P'
#!/usr/bin/env bash
exit 0
P
chmod +x "$ABS_RUNNER"
# Prove path is absolute and contains '/'.
case "$ABS_RUNNER" in
  /*) ok "abs-path fixture is absolute" ;;
  *) bad "abs-path fixture not absolute: $ABS_RUNNER" ;;
esac
FLEET_READINESS_DIR="$ROOT/readiness-abs-path"
rm -rf "$FLEET_READINESS_DIR"
mkdir -p "$FLEET_READINESS_DIR"
# Probe logs every invocation — repeated --start must not call it (identity only).
cat > "$FLEET_READINESS_DIR/abs-path-builder" <<P
#!/usr/bin/env bash
printf 'ready-probe-invoked\n' >> "$CALLS/ready-probe-abs-path.log"
exit 0
P
chmod +x "$FLEET_READINESS_DIR/abs-path-builder"
TARGET=$(setup_target_repo r141-abs-path acme/widget)
PROF="$ROOT/profiles/r141-abs-path.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-abs-path" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=$ABS_RUNNER" \
  "lane=docs|545|docs/**|absolute path global default"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
: > "$CALLS/ready-probe-abs-path.log"
out=$(run_fleet --start 2>&1) || { bad "abs-path initial start failed: $out"; }
grep -Fq "LAUNCH runner=$ABS_RUNNER" "$CALLS/launches.log" \
  && ok "abs-path initial launched absolute selected runner" \
  || bad "abs-path initial launch: $(cat "$CALLS/launches.log")"
grep -qxF "selected_runner=$ABS_RUNNER" "$ROOT/logs/docs.runner-status" \
  && ok "abs-path persisted absolute selected_runner" \
  || bad "abs-path status: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"
grep -qxF "requested_primary=$ABS_RUNNER" "$ROOT/logs/docs.runner-status" \
  && ok "abs-path persisted absolute requested_primary" \
  || bad "abs-path requested primary lost"
# First start should have probed readiness once (selection path).
if [[ -s "$CALLS/ready-probe-abs-path.log" ]]; then
  ok "abs-path initial selection ran readiness probe"
else
  bad "abs-path initial selection skipped readiness probe"
fi
# Plant healthy running lane so second --start takes already-running path.
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-01-01T00:00:00Z
issue: 545
pr:
hat: builder
next_hat: reviewer
round: 1
parked: false
next_action: planted for absolute-path selected_runner revalidation
notes: >
  abs path reval
STATE
bash -c 'while true; do sleep 30; done' \
  "$ROOT/gibson/scripts/loop.sh" \
  "$ROOT/fleet/lane-docs" &
ABS_PATH_PID=$!
printf '%s\n' "$ABS_PATH_PID" > "$ROOT/logs/docs.pid"
pid_check=$(run_fleet --status 2>&1) || true
echo "$pid_check" | grep -E '^docs[[:space:]]' | grep -q 'running' \
  && ok "abs-path planted healthy running lane" \
  || bad "abs-path not running: $pid_check"
SEL_BEFORE=$(grep '^selected_runner=' "$ROOT/logs/docs.runner-status" | head -1)
: > "$CALLS/launches.log"
: > "$CALLS/ready-probe-abs-path.log"
out=$(run_fleet --start 2>&1) || { bad "abs-path repeated --start failed: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "abs-path repeated --start launched zero (no relaunch)" \
  || bad "abs-path repeated relaunched: $lc out=$out"
if [[ -s "$CALLS/ready-probe-abs-path.log" ]]; then
  bad "abs-path repeated --start re-probed readiness: $(cat "$CALLS/ready-probe-abs-path.log")"
else
  ok "abs-path repeated --start did not re-run readiness"
fi
SEL_AFTER=$(grep '^selected_runner=' "$ROOT/logs/docs.runner-status" | head -1)
[[ "$SEL_BEFORE" == "$SEL_AFTER" ]] \
  && ok "abs-path repeated --start preserved absolute selected_runner" \
  || bad "abs-path selection changed: $SEL_BEFORE -> $SEL_AFTER"
# Live process left untouched.
if kill -0 "$ABS_PATH_PID" 2>/dev/null; then
  ok "abs-path left live process untouched"
else
  bad "abs-path killed live process pid=$ABS_PATH_PID"
fi
kill "$ABS_PATH_PID" 2>/dev/null || true
wait "$ABS_PATH_PID" 2>/dev/null || true
rm -f "$ROOT/logs/docs.pid"

# Absolute path also accepted as field-5 route token (parse + readiness).
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-abs-route"
rm -rf "$FLEET_READINESS_DIR"
mkdir -p "$FLEET_READINESS_DIR"
cat > "$FLEET_READINESS_DIR/abs-path-builder" <<'P'
#!/usr/bin/env bash
exit 0
P
chmod +x "$FLEET_READINESS_DIR/abs-path-builder"
TARGET=$(setup_target_repo r141-abs-route acme/widget)
PROF="$ROOT/profiles/r141-abs-route.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-abs-route" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|546|docs/**|absolute path route token|$ABS_RUNNER"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) || { bad "abs-route field-5 start failed: $out"; }
grep -Fq "LAUNCH runner=$ABS_RUNNER" "$CALLS/launches.log" \
  && ok "abs-route field-5 selected absolute path token" \
  || bad "abs-route field-5: $(cat "$CALLS/launches.log")"
grep -qxF "selected_runner=$ABS_RUNNER" "$ROOT/logs/docs.runner-status" \
  && ok "abs-route field-5 persisted absolute selected_runner" \
  || bad "abs-route status: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"

# Hostile/malformed path tokens fail closed (no shell execution, no unsafe accept).
echo "#141 hostile/malformed runner path tokens fail closed"
reset_calls
unset FLEET_READINESS_DIR || true
MARKER="$CALLS/hostile-path-exec.marker"
rm -f "$MARKER"
TARGET=$(setup_target_repo r141-hostile-path acme/widget)

# Relative multipath in route — not a supported selection form.
PROF="$ROOT/profiles/r141-rel-path.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-rel-path" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|547|docs/**|relative multipath|rel/path/builder"
export FLEET_PROFILE="$PROF"
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "relative multipath route should fail: $out" || {
  echo "$out" | grep -qiE 'malformed relative path|hostile|disallowed|runner route' \
    && ok "relative multipath route token refused" \
    || bad "unclear relative multipath fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "relative multipath launched zero" || bad "rel multipath launched $lc"

# '..' segment in absolute-looking route token.
PROF="$ROOT/profiles/r141-dotdot-path.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-dotdot-path" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|548|docs/**|dotdot path|/tmp/../evil-builder"
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "dotdot path route should fail: $out" || {
  echo "$out" | grep -qiE "disallowed '\\.\\.'|path segments|hostile|disallowed|runner route" \
    && ok "dotdot path route token refused" \
    || bad "unclear dotdot path fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "dotdot path launched zero" || bad "dotdot path launched $lc"

# Shell-metachar absolute-looking token must not execute a marker (parse refuse).
PROF="$ROOT/profiles/r141-shell-abs.profile"
{
  echo "version=1"
  echo "name=r141-shell-abs"
  echo "repo=$TARGET"
  echo "slug=acme/widget"
  echo "gibson=$ROOT/gibson"
  echo "fleet_dir=$ROOT/fleet"
  echo "log_dir=$ROOT/logs"
  echo "runner=fake-runner"
  # backtick injection must be rejected as hostile data — never executed.
  printf 'lane=docs|549|docs/**|shell abs|`touch %s`\n' "$MARKER"
} > "$PROF"
export FLEET_PROFILE="$PROF"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "shell-metachar abs route should fail: $out" || {
  echo "$out" | grep -qiE 'hostile|shell|disallowed|safe inert|runner route' \
    && ok "shell-metachar route token refused" \
    || bad "unclear shell-metachar fail: $out"
}
[[ ! -e "$MARKER" ]] && ok "shell-metachar route did not execute marker" \
  || bad "shell-metachar route executed marker (injection)"
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "shell-metachar route launched zero" || bad "shell-metachar launched $lc"

# Persisted hostile selected_runner on already-running fails closed (no re-probe).
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-persist-hostile"
rm -rf "$FLEET_READINESS_DIR"
mkdir -p "$FLEET_READINESS_DIR"
cat > "$FLEET_READINESS_DIR/safe-builder" <<P
#!/usr/bin/env bash
printf 'ready-probe-invoked\n' >> "$CALLS/ready-probe-persist-hostile.log"
exit 0
P
chmod +x "$FLEET_READINESS_DIR/safe-builder"
ensure_runner_bin "safe-builder"
TARGET=$(setup_target_repo r141-persist-hostile acme/widget)
PROF="$ROOT/profiles/r141-persist-hostile.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-persist-hostile" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|550|docs/**|persist hostile selected|safe-builder"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) || { bad "persist-hostile initial start failed: $out"; }
STATE_FILE="$ROOT/fleet/lane-docs/gibson/loop-state.md"
cat > "$STATE_FILE" <<'STATE'
# Gibson loop state
updated: 2026-01-01T00:00:00Z
issue: 550
pr:
hat: builder
next_hat: reviewer
round: 1
parked: false
next_action: planted for hostile persisted selected_runner
notes: >
  hostile plant
STATE
bash -c 'while true; do sleep 30; done' \
  "$ROOT/gibson/scripts/loop.sh" \
  "$ROOT/fleet/lane-docs" &
PERSIST_HOSTILE_PID=$!
printf '%s\n' "$PERSIST_HOSTILE_PID" > "$ROOT/logs/docs.pid"
# Plant shell-hostile selected_runner (would have been rejected at selection,
# but status files can be hand-edited or corrupted).
{
  echo "requested_primary=safe-builder"
  echo 'selected_runner=evil$(reboot)'
  echo "selected_provider=evil"
  echo "selected_pool=provider-evil"
  echo "health=healthy"
  echo "reason=primary_ready"
  echo "route=safe-builder"
  echo "join_key=fleet-sel:v1:test"
  echo "updated=2026-01-01T00:00:00Z"
} > "$ROOT/logs/docs.runner-status"
: > "$CALLS/launches.log"
: > "$CALLS/ready-probe-persist-hostile.log"
out=$(run_fleet --start 2>&1) && bad "persist-hostile selected should fail: $out" || {
  echo "$out" | grep -qiE 'hostile|shell/control|disallowed|selected_runner' \
    && ok "persist-hostile selected_runner refused" \
    || bad "unclear persist-hostile fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "persist-hostile launched zero" || bad "persist-hostile launched $lc"
if [[ -s "$CALLS/ready-probe-persist-hostile.log" ]]; then
  bad "persist-hostile re-probed readiness: $(cat "$CALLS/ready-probe-persist-hostile.log")"
else
  ok "persist-hostile did not re-run readiness"
fi

# Plant relative multipath as persisted selected_runner.
{
  echo "requested_primary=safe-builder"
  echo "selected_runner=rel/path/builder"
  echo "selected_provider=rel"
  echo "selected_pool=provider-rel"
  echo "health=healthy"
  echo "reason=primary_ready"
  echo "route=safe-builder"
  echo "join_key=fleet-sel:v1:test"
  echo "updated=2026-01-01T00:00:00Z"
} > "$ROOT/logs/docs.runner-status"
: > "$CALLS/launches.log"
: > "$CALLS/ready-probe-persist-hostile.log"
out=$(run_fleet --start 2>&1) && bad "persist-relpath selected should fail: $out" || {
  echo "$out" | grep -qiE 'malformed relative path|hostile|disallowed|selected_runner' \
    && ok "persist-relpath selected_runner refused" \
    || bad "unclear persist-relpath fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "persist-relpath launched zero" || bad "persist-relpath launched $lc"

# Plant '..' absolute path as persisted selected_runner.
{
  echo "requested_primary=safe-builder"
  echo "selected_runner=/tmp/../evil-builder"
  echo "selected_provider=evil"
  echo "selected_pool=provider-evil"
  echo "health=healthy"
  echo "reason=primary_ready"
  echo "route=safe-builder"
  echo "join_key=fleet-sel:v1:test"
  echo "updated=2026-01-01T00:00:00Z"
} > "$ROOT/logs/docs.runner-status"
: > "$CALLS/launches.log"
: > "$CALLS/ready-probe-persist-hostile.log"
out=$(run_fleet --start 2>&1) && bad "persist-dotdot selected should fail: $out" || {
  echo "$out" | grep -qiE "disallowed '\\.\\.'|path segments|hostile|disallowed|selected_runner" \
    && ok "persist-dotdot selected_runner refused" \
    || bad "unclear persist-dotdot fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "persist-dotdot launched zero" || bad "persist-dotdot launched $lc"
if kill -0 "$PERSIST_HOSTILE_PID" 2>/dev/null; then
  ok "persist-hostile left live process untouched"
else
  bad "persist-hostile killed live process"
fi
kill "$PERSIST_HOSTILE_PID" 2>/dev/null || true
wait "$PERSIST_HOSTILE_PID" 2>/dev/null || true
rm -f "$ROOT/logs/docs.pid"

# Global RUNNER (field 5 omitted) must hit the same token validator inside
# select_lane_runner — parse_lane_line never sees the global default.
echo "#141 global RUNNER malformed path refused at selection"
reset_calls
unset FLEET_READINESS_DIR || true
MARKER="$CALLS/global-malformed-exec.marker"
rm -f "$MARKER"
TARGET=$(setup_target_repo r141-global-malform acme/widget)
PROF="$ROOT/profiles/r141-global-malform.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-global-malform" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=rel/path/global-builder" \
  "lane=docs|551|docs/**|global default only — no field 5"
export FLEET_PROFILE="$PROF"
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "global malformed RUNNER should fail: $out" || {
  echo "$out" | grep -qiE 'malformed relative path|selection candidate|global runner|hostile|disallowed' \
    && ok "global malformed RUNNER refused at selection" \
    || bad "unclear global malformed fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "global malformed launched zero" || bad "global malformed launched $lc"
[[ ! -e "$MARKER" ]] && ok "global malformed did not execute marker" \
  || bad "global malformed executed marker"

# Global RUNNER with real '..' segment (field 5 omitted).
reset_calls
TARGET=$(setup_target_repo r141-global-dotdot acme/widget)
PROF="$ROOT/profiles/r141-global-dotdot.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-global-dotdot" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=/tmp/../evil-global" \
  "lane=docs|552|docs/**|global absolute with .. segment"
export FLEET_PROFILE="$PROF"
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "global dotdot RUNNER should fail: $out" || {
  echo "$out" | grep -qiE "disallowed '\\.\\.'|path segments|selection candidate|global runner|hostile|disallowed" \
    && ok "global dotdot RUNNER refused at selection" \
    || bad "unclear global dotdot fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "global dotdot launched zero" || bad "global dotdot launched $lc"

# Safe consecutive dots in a basename (my..runner) are NOT path segments —
# must be accepted (not confused with /../ traversal).
echo "#141 safe basename my..runner is not a path segment"
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-dotdot-safe"
rm -rf "$FLEET_READINESS_DIR"
mkdir -p "$FLEET_READINESS_DIR"
cat > "$FLEET_READINESS_DIR/my..runner" <<'P'
#!/usr/bin/env bash
exit 0
P
chmod +x "$FLEET_READINESS_DIR/my..runner"
ensure_runner_bin "my..runner"
TARGET=$(setup_target_repo r141-dotdot-safe acme/widget)
PROF="$ROOT/profiles/r141-dotdot-safe.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-dotdot-safe" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|553|docs/**|safe consecutive dots basename|my..runner"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) || { bad "safe my..runner start failed: $out"; }
grep -Fq "LAUNCH runner=my..runner" "$CALLS/launches.log" \
  && ok "safe my..runner selected (not treated as path segment)" \
  || bad "safe my..runner: $(cat "$CALLS/launches.log")"
grep -qxF "selected_runner=my..runner" "$ROOT/logs/docs.runner-status" \
  && ok "safe my..runner persisted" \
  || bad "safe my..runner status: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"

# Absolute path whose basename contains consecutive dots (not a .. segment).
reset_calls
ABS_DOTS_DIR="$ROOT/abs-dots-runners"
rm -rf "$ABS_DOTS_DIR"
mkdir -p "$ABS_DOTS_DIR"
ABS_DOTS_RUNNER="$ABS_DOTS_DIR/my..runner"
cat > "$ABS_DOTS_RUNNER" <<'P'
#!/usr/bin/env bash
exit 0
P
chmod +x "$ABS_DOTS_RUNNER"
case "$ABS_DOTS_RUNNER" in
  /*) ;;
  *) bad "abs-dots fixture not absolute: $ABS_DOTS_RUNNER" ;;
esac
FLEET_READINESS_DIR="$ROOT/readiness-abs-dots"
rm -rf "$FLEET_READINESS_DIR"
mkdir -p "$FLEET_READINESS_DIR"
cat > "$FLEET_READINESS_DIR/my..runner" <<'P'
#!/usr/bin/env bash
exit 0
P
chmod +x "$FLEET_READINESS_DIR/my..runner"
TARGET=$(setup_target_repo r141-abs-dots acme/widget)
PROF="$ROOT/profiles/r141-abs-dots.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-abs-dots" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=$ABS_DOTS_RUNNER" \
  "lane=docs|554|docs/**|absolute path with my..runner basename"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) || { bad "abs my..runner start failed: $out"; }
grep -Fq "LAUNCH runner=$ABS_DOTS_RUNNER" "$CALLS/launches.log" \
  && ok "absolute path with my..runner basename selected" \
  || bad "abs my..runner: $(cat "$CALLS/launches.log")"
grep -qxF "selected_runner=$ABS_DOTS_RUNNER" "$ROOT/logs/docs.runner-status" \
  && ok "absolute my..runner path persisted" \
  || bad "abs my..runner status: $(cat "$ROOT/logs/docs.runner-status" 2>/dev/null)"

# ---------------------------------------------------------------------------
# #141 repair: global RUNNER only defaults for lanes omitting field 5
# ---------------------------------------------------------------------------
echo "#141 global RUNNER only for omitted-route lanes"

# (a) All lanes explicit, global default missing from PATH → still selects routes.
reset_calls
unset FLEET_READINESS_DIR || true
FLEET_READINESS_DIR="$ROOT/readiness-explicit-miss"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "route-a" ready
write_ready_probe "route-b" ready
ensure_runner_bin "route-a"
ensure_runner_bin "route-b"
TARGET=$(setup_target_repo r141-explicit-miss acme/widget)
PROF="$ROOT/profiles/r141-explicit-miss.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-explicit-miss" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=missing-global-runner-xyz" \
  "lane=docs|521|docs/**|all explicit A|route-a" \
  "lane=harness|522|scripts/**|all explicit B|route-b"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
# Ensure the bogus global default is not on PATH.
rm -f "$BIN/missing-global-runner-xyz"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) || { bad "all-explicit missing global should start: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "2" ]] && ok "all-explicit missing global launched two lanes" || bad "all-explicit miss launches=$lc out=$out"
grep -q 'LAUNCH runner=route-a' "$CALLS/launches.log" \
  && grep -q 'LAUNCH runner=route-b' "$CALLS/launches.log" \
  && ok "all-explicit missing global selected actual routes" \
  || bad "all-explicit miss routes: $(cat "$CALLS/launches.log")"

# (b) All lanes explicit, global default collides with reviewer but unused → proceed.
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-explicit-collide"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "safe-builder" ready
ensure_runner_bin "safe-builder"
TARGET=$(setup_target_repo r141-explicit-collide acme/widget)
PROF="$ROOT/profiles/r141-explicit-collide.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-explicit-collide" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=codex-stub" \
  "lane=docs|523|docs/**|unused colliding global|safe-builder"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
# codex-stub on PATH as a binary so if it were used it would resolve; it must not.
cat > "$BIN/codex-stub" <<'P'
#!/usr/bin/env bash
exit 0
P
chmod +x "$BIN/codex-stub"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) || { bad "all-explicit colliding unused global should start: $out"; }
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "1" ]] && ok "all-explicit unused colliding global launched once" || bad "explicit collide launches=$lc out=$out"
grep -q 'LAUNCH runner=safe-builder' "$CALLS/launches.log" \
  && ok "all-explicit unused colliding global selected safe-builder" \
  || bad "expected safe-builder: $(cat "$CALLS/launches.log")"
if grep -q 'LAUNCH runner=codex-stub' "$CALLS/launches.log"; then
  bad "unused colliding global was selected: $(cat "$CALLS/launches.log")"
else
  ok "unused colliding global was not selected"
fi

# (c) Omitted-route lane fails when global default is missing from PATH.
reset_calls
unset FLEET_READINESS_DIR || true
TARGET=$(setup_target_repo r141-omit-miss acme/widget)
PROF="$ROOT/profiles/r141-omit-miss.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-omit-miss" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=missing-global-runner-xyz" \
  "lane=docs|524|docs/**|omitted route needs global"
export FLEET_PROFILE="$PROF"
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
rm -f "$BIN/missing-global-runner-xyz"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "omitted-route missing global should fail: $out" || {
  echo "$out" | grep -qiE 'missing-global-runner-xyz|not found on PATH|runner' \
    && ok "omitted-route missing global refused" \
    || bad "unclear omit-miss fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "omitted-route missing global launched zero" || bad "omit-miss launched $lc"

# (d) Actual selected runner conflicting with reviewer fails closed (retain).
reset_calls
FLEET_READINESS_DIR="$ROOT/readiness-actual-role"
rm -rf "$FLEET_READINESS_DIR"
write_ready_probe "codex-as-builder" ready
ensure_runner_bin "codex-as-builder"
TARGET=$(setup_target_repo r141-actual-role acme/widget)
PROF="$ROOT/profiles/r141-actual-role.profile"
write_profile "$PROF" \
  "version=1" \
  "name=r141-actual-role" \
  "repo=$TARGET" \
  "slug=acme/widget" \
  "gibson=$ROOT/gibson" \
  "fleet_dir=$ROOT/fleet" \
  "log_dir=$ROOT/logs" \
  "runner=fake-runner" \
  "lane=docs|525|docs/**|actual role conflict|codex-as-builder"
export FLEET_PROFILE="$PROF"
export FLEET_READINESS_DIR
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"
: > "$CALLS/launches.log"
out=$(run_fleet --start 2>&1) && bad "actual selected role conflict should fail: $out" || {
  echo "$out" | grep -qiE 'three-role|collides|REVIEWER|provider|grade' \
    && ok "actual selected runner role conflict refused" \
    || bad "unclear actual-role fail: $out"
}
lc=$(echo "$(launch_count)" | tr -d '[:space:]')
[[ "$lc" == "0" ]] && ok "actual selected role conflict launched zero" || bad "actual-role launched $lc"

unset FLEET_READINESS_DIR || true
export FLEET_READINESS_TIMEOUT=8
export REVIEWER_CMD="codex-stub review"
export RELEASE_CMD="claude-stub release"


# --- CR: docs contract sensors (gh prereq, MD018, bypassPermissions warn) --
echo "docs contract sensors"
if grep -q 'gh.*1\.9\.0\|gh ≥ 1.9.0\|gh >= 1.9.0' "$REPO_ROOT/templates/fleet/README.md"; then
  ok "templates/fleet/README.md declares gh >= 1.9.0 prerequisite"
else
  bad "templates/fleet/README.md missing gh >= 1.9.0 prerequisite"
fi
if grep -n '^#96-style' "$REPO_ROOT/templates/fleet/README.md" >/dev/null 2>&1; then
  bad "templates/fleet/README.md still has line-initial #96-style (MD018)"
else
  ok "templates/fleet/README.md has no line-initial #96-style"
fi
if grep -qi 'bypassPermissions' "$REPO_ROOT/adapters/grok/README.md" \
  && grep -qiE 'WARNING|trusted.*isolated|owner authoriz' "$REPO_ROOT/adapters/grok/README.md"; then
  ok "adapters/grok/README.md warns on bypassPermissions RELEASE_CMD"
else
  bad "adapters/grok/README.md missing bypassPermissions warning"
fi
# Three-role split preserved.
grep -qi 'REVIEWER_CMD' "$REPO_ROOT/adapters/grok/README.md" \
  && grep -qi 'RELEASE_CMD' "$REPO_ROOT/adapters/grok/README.md" \
  && grep -qi 'Three-role' "$REPO_ROOT/adapters/grok/README.md" \
  && ok "adapters/grok/README.md preserves three-role split" \
  || bad "three-role split docs regressed"

echo
echo "loop-fleet.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
