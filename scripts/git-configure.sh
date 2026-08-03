#!/usr/bin/env bash
# git-configure.sh — audit + safe-apply Git/GitHub settings for Gibson adoption
# (issue #68 first slice). Portable Bash 3.2+. Docs: 13, 23; playbooks/adopt.md.
#
# Never grades its own work; never applies branch protection, environments,
# DCO apps, Vercel, secrets, auth, or production-branch wiring.
set -euo pipefail

VERSION="0.1.0-68-slice1"

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
# 0  every safe check PASS and no owner-required / unknown drift
# 1  drift or owner-required / unknown remains (successful audit)
# 2  usage / config validation error
# 3  GitHub / API / apply / report failure or failed post-apply verification

usage() {
  cat <<'EOF'
git-configure.sh — audit (and safely apply) Git/GitHub settings for Gibson

WHAT IT DOES
  Reads live repository settings via `gh` and compares them to the Gibson
  adoption contract (labels, merge methods, .gitignore for gibson/ runtime
  state, branch protection, required checks, reviewer identity, DCO evidence,
  GitHub Production environment, Vercel production-branch truth, and
  test-integrity canary posture).

  Modes:
    --audit     read-only report (DEFAULT). Zero mutations.
    --dry-run   print the exact safe apply plan. Zero mutations.
    --apply     mutate ONLY reversible adoption settings:
                  • required Gibson labels (create if missing)
                  • narrow .gitignore entry for gibson/ runtime state
                  • merge settings: squash on; merge-commit and rebase off
                  • delete-branch-on-merge on
                Then re-read each mutation and fail closed (exit 3) if the
                live postcondition is not exact.

  NEVER applied by this script (audit + owner remediation only):
    branch protection, required review/status contexts, GitHub Environment
    rules, DCO app/config, Vercel project settings, secrets, auth, production
    branch remapping. Static workflow YAML or config strings are NEVER
    treated as proof that test-integrity / canaries executed.

WHY
  Lessons L-004 (docs ≠ wiring), L-020/L-021 (merge + review reality), and
  issue #70 (test-integrity inert until live canaries + required check).
  Adoption must sense real settings, not aspirational prose.

RISKS
  - --apply changes repo merge methods and creates labels (reversible).
  - Misnamed requiredContexts in .gibson-delivery.json only affect the
    audit report; this script never writes protection rules.
  - Needs `gh` auth with repo metadata (and admin for --apply mutations).
  - Never prints or stores secrets.

USAGE
  git-configure.sh [--audit|--dry-run|--apply]
                   [--repo owner/name]
                   [--config path/to/.gibson-delivery.json]
                   [--path DIR]            # local checkout for .gitignore / workflows
                   [--report PATH]         # default: gibson/git-config-report.md
                   [--no-report]
                   [--help]

EXIT
  0  READY — every check PASS, no owner-required / unknown
  1  DRIFT — safe drift and/or owner-required / unknown remain
  2  usage or config validation error
  3  tool / API / apply / report failure

EXAMPLES
  ./scripts/git-configure.sh --repo acme/app
  ./scripts/git-configure.sh --dry-run --path ~/Code/acme-app --repo acme/app
  ./scripts/git-configure.sh --apply --path ~/Code/acme-app --repo acme/app
  ./scripts/git-configure.sh --audit --report /tmp/git-config-report.md

REPORT
  Written atomically (temp sibling + rename). Default path is
  gibson/git-config-report.md under --path (or cwd). That path is runtime
  state — do not commit it; --apply ensures gibson/ is gitignored. Use
  --no-report to skip the file entirely. Never contains secrets.

CONFIG
  Optional .gibson-delivery.json (see templates/target-repo/gibson-delivery.json
  and docs/23). Supported fields only: repo, model, defaultBranch,
  productionBranch, requiredContexts, productionEnvironment, reviewerLogin.
  No secrets. Malformed or unsupported model → exit 2.
EOF
}

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
MODE="audit"   # audit | dry-run | apply
REPO=""
CONFIG_PATH=""
LOCAL_PATH="."
REPORT_PATH=""
NO_REPORT=0
ASSUME_DEFAULT_REPORT=1

# From config / live
MODEL=""
DEFAULT_BRANCH=""
PRODUCTION_BRANCH=""
PROD_ENV=""
REVIEWER_LOGIN=""
# required contexts as newline-separated string (Bash 3.2 — no mapfile)
REQUIRED_CONTEXTS_NL=""

# Live repo metadata
LIVE_DEFAULT_BRANCH=""
LIVE_OWNER_LOGIN=""
LIVE_SQUASH=""
LIVE_MERGE_COMMIT=""
LIVE_REBASE=""
LIVE_DELETE_BRANCH=""

# Status tallies
COUNT_PASS=0
COUNT_SAFE_DRIFT=0
COUNT_OWNER=0
COUNT_UNKNOWN=0
COUNT_ERROR=0
HAD_APPLY_FAILURE=0
HAD_TOOL_FAILURE=0

# Findings: temp file of lines "STATUS|area|message"
FINDINGS_FILE=""
PLAN_FILE=""
MUTATION_LOG=""
# Record every gh mutating invocation for tests / dry-run verification
GH_MUTATION_LOG=""

die_usage() {
  echo "error: $*" >&2
  exit 2
}

die_tool() {
  echo "error: $*" >&2
  HAD_TOOL_FAILURE=1
  exit 3
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die_usage "missing required command: $1"
}

# Shell-quote a value for safe paste into remediation commands (never eval).
sq() {
  printf '%q' "$1"
}

# Append a finding. status: PASS|SAFE_DRIFT|OWNER_REQUIRED|UNKNOWN|ERROR
record() {
  local status="$1" area="$2" msg="$3"
  printf '%s|%s|%s\n' "$status" "$area" "$msg" >>"$FINDINGS_FILE"
  case "$status" in
    PASS) COUNT_PASS=$((COUNT_PASS + 1)) ;;
    SAFE_DRIFT) COUNT_SAFE_DRIFT=$((COUNT_SAFE_DRIFT + 1)) ;;
    OWNER_REQUIRED) COUNT_OWNER=$((COUNT_OWNER + 1)) ;;
    UNKNOWN) COUNT_UNKNOWN=$((COUNT_UNKNOWN + 1)) ;;
    ERROR) COUNT_ERROR=$((COUNT_ERROR + 1)); HAD_TOOL_FAILURE=1 ;;
  esac
}

plan_line() {
  printf '%s\n' "$1" >>"$PLAN_FILE"
}

# ---------------------------------------------------------------------------
# Arg parse
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --audit)
        MODE="audit"
        shift
        ;;
      --dry-run)
        MODE="dry-run"
        shift
        ;;
      --apply)
        MODE="apply"
        shift
        ;;
      --repo)
        [[ $# -ge 2 ]] || die_usage "--repo requires owner/name"
        REPO="$2"
        shift 2
        ;;
      --config)
        [[ $# -ge 2 ]] || die_usage "--config requires a path"
        CONFIG_PATH="$2"
        shift 2
        ;;
      --path)
        [[ $# -ge 2 ]] || die_usage "--path requires a directory"
        LOCAL_PATH="$2"
        shift 2
        ;;
      --report)
        [[ $# -ge 2 ]] || die_usage "--report requires a path"
        REPORT_PATH="$2"
        ASSUME_DEFAULT_REPORT=0
        shift 2
        ;;
      --no-report)
        NO_REPORT=1
        ASSUME_DEFAULT_REPORT=0
        shift
        ;;
      --version)
        echo "git-configure.sh ${VERSION}"
        exit 0
        ;;
      *)
        die_usage "unknown argument: $1"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Config load / validate
# ---------------------------------------------------------------------------
SUPPORTED_MODELS="main-is-prod release-branch tag-pin"

validate_repo_slug() {
  local r="$1"
  # owner/name — no spaces, no leading slash, exactly one slash, no path tricks
  case "$r" in
    ''|*/|/*|*//*|*[[:space:]]*|*..*)
      return 1
      ;;
  esac
  local slash_count
  slash_count=$(printf '%s' "$r" | awk -F/ '{print NF-1}')
  [[ "$slash_count" -eq 1 ]] || return 1
  local owner name
  owner="${r%%/*}"
  name="${r#*/}"
  [[ -n "$owner" && -n "$name" ]] || return 1
  case "$owner" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$name" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

validate_branch_name() {
  local b="$1"
  [[ -n "$b" ]] || return 1
  case "$b" in
    *[[:space:]]*|*..*|/*|*/|*\**|*\\*)
      return 1
      ;;
  esac
  return 0
}

validate_context_name() {
  local c="$1"
  [[ -n "$c" ]] || return 1
  case "$c" in
    *[[:cntrl:]]*)
      return 1
      ;;
  esac
  return 0
}

load_config() {
  local path="" cfg
  if [[ -n "$CONFIG_PATH" ]]; then
    path="$CONFIG_PATH"
    if [[ ! -e "$path" ]]; then
      die_usage "config not found: $path"
    fi
    if [[ -L "$path" ]]; then
      die_usage "config path is a symlink (refuse): $path"
    fi
    if [[ ! -f "$path" ]]; then
      die_usage "config is not a regular file: $path"
    fi
  elif [[ -f "${LOCAL_PATH}/.gibson-delivery.json" && ! -L "${LOCAL_PATH}/.gibson-delivery.json" ]]; then
    path="${LOCAL_PATH}/.gibson-delivery.json"
  fi

  # Defaults
  MODEL="main-is-prod"
  DEFAULT_BRANCH="main"
  PRODUCTION_BRANCH="main"
  PROD_ENV="Production"
  REVIEWER_LOGIN=""
  REQUIRED_CONTEXTS_NL="quality
DCO
secrets
dependencies
build-e2e-required
review-evidence
test-integrity"

  if [[ -z "$path" ]]; then
    return 0
  fi

  if ! cfg=$(cat -- "$path" 2>/dev/null); then
    die_usage "cannot read config: $path"
  fi

  if ! printf '%s' "$cfg" | jq -e . >/dev/null 2>&1; then
    die_usage "config is not valid JSON: $path"
  fi

  # Reject unknown top-level keys (no secrets, no surprise fields)
  local unknown
  unknown=$(printf '%s' "$cfg" | jq -r '
    def allowed: ["repo","model","defaultBranch","productionBranch",
      "requiredContexts","productionEnvironment","reviewerLogin"];
    [keys[] | select(. as $k | allowed | index($k) | not)] | .[]
  ' 2>/dev/null || true)
  if [[ -n "$unknown" ]]; then
    die_usage "config has unsupported field(s): $(printf '%s' "$unknown" | tr '\n' ' ')(path: $path)"
  fi

  local v
  v=$(printf '%s' "$cfg" | jq -r '.repo // empty')
  if [[ -n "$v" ]]; then
    if [[ -z "$REPO" ]]; then
      REPO="$v"
    fi
  fi

  v=$(printf '%s' "$cfg" | jq -r '.model // empty')
  if [[ -n "$v" ]]; then
    MODEL="$v"
  fi
  case " $SUPPORTED_MODELS " in
    *" $MODEL "*) ;;
    *) die_usage "unsupported model $(sq "$MODEL") — want one of: $SUPPORTED_MODELS" ;;
  esac

  v=$(printf '%s' "$cfg" | jq -r '.defaultBranch // empty')
  if [[ -n "$v" ]]; then
    DEFAULT_BRANCH="$v"
  fi
  validate_branch_name "$DEFAULT_BRANCH" || die_usage "invalid defaultBranch: $(sq "$DEFAULT_BRANCH")"

  v=$(printf '%s' "$cfg" | jq -r '.productionBranch // empty')
  if [[ -n "$v" ]]; then
    PRODUCTION_BRANCH="$v"
  fi
  validate_branch_name "$PRODUCTION_BRANCH" || die_usage "invalid productionBranch: $(sq "$PRODUCTION_BRANCH")"

  v=$(printf '%s' "$cfg" | jq -r '
    if has("productionEnvironment") then
      if .productionEnvironment == null then "__null__"
      else (.productionEnvironment | tostring)
      end
    else empty end')
  if [[ "$v" == "__null__" ]]; then
    PROD_ENV=""
  elif [[ -n "$v" ]]; then
    PROD_ENV="$v"
  fi

  v=$(printf '%s' "$cfg" | jq -r '.reviewerLogin // empty')
  if [[ -n "$v" ]]; then
    REVIEWER_LOGIN="$v"
  fi
  if [[ -n "$REVIEWER_LOGIN" ]]; then
    case "$REVIEWER_LOGIN" in
      *[[:space:]/\\]*|"") die_usage "invalid reviewerLogin: $(sq "$REVIEWER_LOGIN")" ;;
    esac
  fi

  if printf '%s' "$cfg" | jq -e 'has("requiredContexts")' >/dev/null 2>&1; then
    if ! printf '%s' "$cfg" | jq -e '.requiredContexts | type == "array"' >/dev/null 2>&1; then
      die_usage "requiredContexts must be a JSON array"
    fi
    REQUIRED_CONTEXTS_NL=$(printf '%s' "$cfg" | jq -r '.requiredContexts[]? // empty')
    # Validate each
    local ctx
    while IFS= read -r ctx; do
      [[ -z "$ctx" ]] && continue
      validate_context_name "$ctx" || die_usage "invalid requiredContexts entry: $(sq "$ctx")"
    done <<EOF
$REQUIRED_CONTEXTS_NL
EOF
  fi
}

# ---------------------------------------------------------------------------
# gh wrappers (fail closed; mutation log for tests)
# ---------------------------------------------------------------------------
gh_api() {
  # Usage: gh_api [gh api args...]
  # Mutating methods are logged when GH_MUTATION_LOG is set (tests).
  local method="GET" arg
  for arg in "$@"; do
    case "$arg" in
      --method)
        # next will be method — handled below by scanning
        :
        ;;
    esac
  done
  # Detect mutating methods from argv
  local prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--method" ]]; then
      method=$(printf '%s' "$arg" | tr '[:lower:]' '[:upper:]')
    fi
    prev="$arg"
  done
  case "$method" in
    POST|PUT|PATCH|DELETE)
      if [[ -n "${GH_MUTATION_LOG:-}" ]]; then
        printf 'MUTATE %s %s\n' "$method" "$*" >>"$GH_MUTATION_LOG"
      fi
      if [[ "$MODE" != "apply" ]]; then
        # Safety net: never mutate outside apply even if a caller bugs out
        echo "error: internal: refused mutating gh api outside --apply: $method $*" >&2
        return 3
      fi
      ;;
  esac
  gh api "$@"
}

# ---------------------------------------------------------------------------
# Atomic report write
# ---------------------------------------------------------------------------
report_dest_ok() {
  local dest="$1"
  if [[ -L "$dest" ]]; then
    return 1
  fi
  if [[ -e "$dest" && ! -f "$dest" ]]; then
    return 1
  fi
  return 0
}

atomic_write_report() {
  local dest="$1"
  local content="$2"
  local dir base tmp

  if [[ -z "$dest" ]]; then
    die_tool "empty report path"
  fi

  # Hostile path components
  case "$dest" in
    "") die_tool "empty report path" ;;
  esac

  dir=$(dirname -- "$dest")
  base=$(basename -- "$dest")

  if [[ -L "$dir" ]]; then
    die_tool "report parent is a symlink (refuse): $dir"
  fi
  if [[ ! -d "$dir" ]]; then
    if ! mkdir -p -- "$dir" 2>/dev/null; then
      die_tool "cannot create report directory: $dir"
    fi
  fi
  if [[ -L "$dir" || ! -d "$dir" ]]; then
    die_tool "report parent is not a real directory: $dir"
  fi
  if [[ ! -w "$dir" ]]; then
    die_tool "report directory is not writable: $dir"
  fi
  if ! report_dest_ok "$dest"; then
    die_tool "report path is not a safe regular-file destination: $dest"
  fi

  tmp=$(mktemp "${dir}/.${base}.XXXXXX") || die_tool "mktemp failed for report: $dest"
  if [[ -L "$tmp" || ! -f "$tmp" ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    die_tool "report temp is not a regular file: $tmp"
  fi
  if ! printf '%s' "$content" >"$tmp"; then
    rm -f -- "$tmp"
    die_tool "failed writing report temp: $tmp"
  fi
  # Re-check dest before rename (symlink swap race → refuse)
  if ! report_dest_ok "$dest"; then
    rm -f -- "$tmp"
    die_tool "report destination became unsafe before rename: $dest"
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    die_tool "atomic rename failed for report: $dest"
  fi
  if [[ -L "$dest" || ! -f "$dest" ]]; then
    die_tool "report path is not a regular file after write: $dest"
  fi
}

# ---------------------------------------------------------------------------
# Label set (adoption doctrine: docs/13 + playbooks/adopt.md + skills)
# ---------------------------------------------------------------------------
# Minimum required labels. Create both halt spellings so either docs path works.
REQUIRED_LABELS="tier-a
tier-b
tier-c
agent-claimed
blocked
gibson-halt
halt"

label_color() {
  case "$1" in
    tier-a) echo "0e8a16" ;;
    tier-b) echo "fbca04" ;;
    tier-c) echo "d93f0b" ;;
    agent-claimed) echo "5319e7" ;;
    blocked) echo "b60205" ;;
    gibson-halt|halt) echo "000000" ;;
    *) echo "ededed" ;;
  esac
}

label_desc() {
  case "$1" in
    tier-a) echo "Tier A — fully autonomous safe work" ;;
    tier-b) echo "Tier B — autonomous with review" ;;
    tier-c) echo "Tier C — human merge gate (money/auth/PII/security/prod data)" ;;
    agent-claimed) echo "An agent has claimed this issue" ;;
    blocked) echo "Blocked on human or external dependency" ;;
    gibson-halt) echo "Soft halt cue for the Gibson solo loop" ;;
    halt) echo "Halt cue (alias)" ;;
    *) echo "Gibson adoption label" ;;
  esac
}

# ---------------------------------------------------------------------------
# .gitignore helpers
# ---------------------------------------------------------------------------
gitignore_covers_gibson() {
  # stdin: .gitignore contents. Return 0 if gibson/ runtime state is covered.
  # Accept common equivalent forms; do not invent coverage from vague globs.
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip CR and trailing spaces
    line=${line%$'\r'}
    case "$line" in
      'gibson/'|'gibson'|'/gibson/'|'/gibson'|'gibson/**'|'/gibson/**')
        return 0
        ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# Live fetch helpers
# ---------------------------------------------------------------------------
fetch_repo_meta() {
  local body
  if ! body=$(gh api "repos/${REPO}" 2>/dev/null); then
    record ERROR "repo" "failed to read repos/${REPO} via gh api (auth, network, or repo missing)"
    return 1
  fi
  if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    record ERROR "repo" "repos/${REPO} returned non-JSON"
    return 1
  fi

  # Note: jq `//` treats false as missing — use tostring so false survives.
  LIVE_DEFAULT_BRANCH=$(printf '%s' "$body" | jq -r '.default_branch // empty')
  LIVE_OWNER_LOGIN=$(printf '%s' "$body" | jq -r '.owner.login // empty')
  LIVE_SQUASH=$(printf '%s' "$body" | jq -r '.allow_squash_merge | if . == null then "empty" else tostring end')
  LIVE_MERGE_COMMIT=$(printf '%s' "$body" | jq -r '.allow_merge_commit | if . == null then "empty" else tostring end')
  LIVE_REBASE=$(printf '%s' "$body" | jq -r '.allow_rebase_merge | if . == null then "empty" else tostring end')
  LIVE_DELETE_BRANCH=$(printf '%s' "$body" | jq -r '.delete_branch_on_merge | if . == null then "empty" else tostring end')

  if [[ -z "$LIVE_DEFAULT_BRANCH" || "$LIVE_DEFAULT_BRANCH" == "null" ]]; then
    record ERROR "repo" "default_branch missing/null in API response"
    return 1
  fi

  # Prefer live default branch when config left default
  if [[ -z "$DEFAULT_BRANCH" || "$DEFAULT_BRANCH" == "main" ]]; then
    # Keep config if explicit non-main; if config says main but live differs, note it
    :
  fi
  if [[ -n "$LIVE_DEFAULT_BRANCH" && "$DEFAULT_BRANCH" != "$LIVE_DEFAULT_BRANCH" ]]; then
    record OWNER_REQUIRED "default-branch" \
      "configured defaultBranch=$(sq "$DEFAULT_BRANCH") but live default_branch=$(sq "$LIVE_DEFAULT_BRANCH") — owner must align config or repo"
  else
    record PASS "default-branch" "default_branch=$(sq "$LIVE_DEFAULT_BRANCH")"
  fi
  return 0
}

fetch_labels() {
  # stdout: label names, one per line
  local body
  if ! body=$(gh api --paginate "repos/${REPO}/labels" 2>/dev/null); then
    record ERROR "labels" "failed to list labels for ${REPO}"
    return 1
  fi
  if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    record ERROR "labels" "labels API returned non-JSON"
    return 1
  fi
  printf '%s' "$body" | jq -r 'if type=="array" then .[].name else .name end' 2>/dev/null
}

audit_labels() {
  local existing missing name
  if ! existing=$(fetch_labels); then
    return 1
  fi
  missing=""
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! printf '%s\n' "$existing" | grep -Fxq -- "$name"; then
      missing="${missing}${name}"$'\n'
    fi
  done <<EOF
$REQUIRED_LABELS
EOF

  if [[ -z "$missing" ]]; then
    record PASS "labels" "all required labels present (tier-a/b/c, agent-claimed, blocked, gibson-halt, halt)"
    return 0
  fi

  local list
  list=$(printf '%s' "$missing" | sed '/^$/d' | tr '\n' ' ')
  record SAFE_DRIFT "labels" "missing labels: ${list}"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    plan_line "CREATE_LABEL $(sq "$name") color=$(label_color "$name")"
  done <<EOF
$missing
EOF
  return 0
}

apply_labels() {
  local existing name color desc body
  if ! existing=$(fetch_labels); then
    HAD_APPLY_FAILURE=1
    return 1
  fi
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if printf '%s\n' "$existing" | grep -Fxq -- "$name"; then
      continue
    fi
    color=$(label_color "$name")
    desc=$(label_desc "$name")
    echo "  apply: create label ${name}"
    if ! body=$(gh_api --method POST "repos/${REPO}/labels" \
      -f "name=${name}" -f "color=${color}" -f "description=${desc}" 2>/dev/null); then
      record ERROR "labels" "failed to create label $(sq "$name")"
      HAD_APPLY_FAILURE=1
      return 1
    fi
    # readback: re-list
  done <<EOF
$REQUIRED_LABELS
EOF

  # Postcondition: every required label exists
  if ! existing=$(fetch_labels); then
    HAD_APPLY_FAILURE=1
    return 1
  fi
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! printf '%s\n' "$existing" | grep -Fxq -- "$name"; then
      record ERROR "labels" "post-apply readback missing label $(sq "$name")"
      HAD_APPLY_FAILURE=1
      return 1
    fi
  done <<EOF
$REQUIRED_LABELS
EOF
  record PASS "labels" "labels applied and verified"
  return 0
}

audit_merge_settings() {
  if [[ "$LIVE_SQUASH" == "true" ]]; then
    record PASS "merge.squash" "allow_squash_merge=true"
  else
    record SAFE_DRIFT "merge.squash" "allow_squash_merge=${LIVE_SQUASH:-unknown} (want true)"
    plan_line "PATCH_REPO allow_squash_merge=true"
  fi
  if [[ "$LIVE_MERGE_COMMIT" == "false" ]]; then
    record PASS "merge.merge_commit" "allow_merge_commit=false"
  else
    record SAFE_DRIFT "merge.merge_commit" "allow_merge_commit=${LIVE_MERGE_COMMIT:-unknown} (want false)"
    plan_line "PATCH_REPO allow_merge_commit=false"
  fi
  if [[ "$LIVE_REBASE" == "false" ]]; then
    record PASS "merge.rebase" "allow_rebase_merge=false"
  else
    record SAFE_DRIFT "merge.rebase" "allow_rebase_merge=${LIVE_REBASE:-unknown} (want false)"
    plan_line "PATCH_REPO allow_rebase_merge=false"
  fi
  if [[ "$LIVE_DELETE_BRANCH" == "true" ]]; then
    record PASS "merge.delete_branch" "delete_branch_on_merge=true"
  else
    record SAFE_DRIFT "merge.delete_branch" "delete_branch_on_merge=${LIVE_DELETE_BRANCH:-unknown} (want true)"
    plan_line "PATCH_REPO delete_branch_on_merge=true"
  fi
  return 0
}

apply_merge_settings() {
  echo "  apply: repository merge settings (squash on; merge-commit/rebase off; delete-branch-on-merge on)"
  if ! gh_api --method PATCH "repos/${REPO}" \
    -F allow_squash_merge=true \
    -F allow_merge_commit=false \
    -F allow_rebase_merge=false \
    -F delete_branch_on_merge=true \
    >/dev/null 2>&1; then
    record ERROR "merge" "PATCH repos/${REPO} merge settings failed"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  # Read back exact postconditions
  local body
  if ! body=$(gh api "repos/${REPO}" 2>/dev/null); then
    record ERROR "merge" "post-apply readback of repo settings failed"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  local s m r d
  s=$(printf '%s' "$body" | jq -r '.allow_squash_merge | if . == null then "empty" else tostring end')
  m=$(printf '%s' "$body" | jq -r '.allow_merge_commit | if . == null then "empty" else tostring end')
  r=$(printf '%s' "$body" | jq -r '.allow_rebase_merge | if . == null then "empty" else tostring end')
  d=$(printf '%s' "$body" | jq -r '.delete_branch_on_merge | if . == null then "empty" else tostring end')
  if [[ "$s" != "true" || "$m" != "false" || "$r" != "false" || "$d" != "true" ]]; then
    record ERROR "merge" "post-apply postcondition failed: squash=${s} merge_commit=${m} rebase=${r} delete_branch=${d}"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  LIVE_SQUASH="$s"
  LIVE_MERGE_COMMIT="$m"
  LIVE_REBASE="$r"
  LIVE_DELETE_BRANCH="$d"
  record PASS "merge" "merge settings applied and verified"
  return 0
}

audit_gitignore() {
  local gi="${LOCAL_PATH}/.gitignore"
  if [[ ! -e "$gi" ]]; then
    record SAFE_DRIFT "gitignore" ".gitignore missing — will append canonical gibson/ entry on apply"
    plan_line "GITIGNORE_APPEND $(sq "$gi") entry=gibson/"
    return 0
  fi
  if [[ -L "$gi" ]]; then
    record OWNER_REQUIRED "gitignore" ".gitignore is a symlink (refuse to rewrite): $(sq "$gi")"
    return 0
  fi
  if [[ ! -f "$gi" ]]; then
    record OWNER_REQUIRED "gitignore" ".gitignore is not a regular file: $(sq "$gi")"
    return 0
  fi
  if gitignore_covers_gibson <"$gi"; then
    record PASS "gitignore" "gibson/ runtime state is covered"
  else
    record SAFE_DRIFT "gitignore" "no gibson/ ignore entry — apply will append a single line"
    plan_line "GITIGNORE_APPEND $(sq "$gi") entry=gibson/"
  fi
}

apply_gitignore() {
  local gi="${LOCAL_PATH}/.gitignore"
  if [[ -L "$gi" ]]; then
    record ERROR "gitignore" "refuse to mutate symlink .gitignore"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  if [[ -e "$gi" && ! -f "$gi" ]]; then
    record ERROR "gitignore" "refuse to mutate non-file .gitignore"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  if [[ -f "$gi" ]] && gitignore_covers_gibson <"$gi"; then
    record PASS "gitignore" "already covers gibson/ (idempotent)"
    return 0
  fi
  echo "  apply: append gibson/ to .gitignore"
  # Preserve all existing bytes; only append if needed. Ensure trailing newline
  # before the new entry when the file is non-empty and lacks one.
  if [[ -f "$gi" && -s "$gi" ]]; then
    local last
    last=$(tail -c 1 "$gi" | od -An -t x1 | tr -d ' \n')
    if [[ "$last" != "0a" ]]; then
      printf '\n' >>"$gi" || {
        record ERROR "gitignore" "failed to append newline before gibson/ entry"
        HAD_APPLY_FAILURE=1
        return 1
      }
    fi
  fi
  if [[ ! -e "$gi" ]]; then
    # create new file
    if ! printf '%s\n' 'gibson/' >"$gi"; then
      record ERROR "gitignore" "failed to create .gitignore"
      HAD_APPLY_FAILURE=1
      return 1
    fi
  else
    if ! printf '%s\n' 'gibson/' >>"$gi"; then
      record ERROR "gitignore" "failed to append gibson/ entry"
      HAD_APPLY_FAILURE=1
      return 1
    fi
  fi
  if ! gitignore_covers_gibson <"$gi"; then
    record ERROR "gitignore" "post-apply readback: gibson/ still not covered"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  record PASS "gitignore" "gibson/ entry present and verified"
  return 0
}

# ---------------------------------------------------------------------------
# Owner-required audits (never mutated by --apply)
# ---------------------------------------------------------------------------
audit_branch_protection() {
  local branch="$1"
  local role="$2"   # default | production
  local body errfile
  errfile=$(mktemp)
  if ! body=$(gh api "repos/${REPO}/branches/${branch}/protection" 2>"$errfile"); then
    local err
    err=$(cat "$errfile" 2>/dev/null || true)
    rm -f "$errfile"
    if printf '%s' "$err" | grep -qi 'Not Found\|404\|Branch not protected'; then
      record OWNER_REQUIRED "protection.${role}" \
        "branch $(sq "$branch") is NOT PROTECTED — owner must run delivery-control apply-branch-protection (docs/23); this script will not apply protection"
      plan_line "OWNER: scripts/delivery-control/apply-branch-protection.sh --repo $(sq "$REPO") --apply   # after dry-run + Mark approval"
      return 0
    fi
    record ERROR "protection.${role}" "API failure reading protection for $(sq "$branch"): ${err}"
    return 1
  fi
  rm -f "$errfile"
  if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    record ERROR "protection.${role}" "protection JSON malformed for $(sq "$branch")"
    return 1
  fi

  local enforce strict reviews force delete contexts_json
  enforce=$(printf '%s' "$body" | jq -r '.enforce_admins.enabled // .enforce_admins // false' 2>/dev/null || echo false)
  # enforce_admins can be bool or {enabled: bool}
  if [[ "$enforce" != "true" && "$enforce" != "false" ]]; then
    enforce=$(printf '%s' "$body" | jq -r 'if .enforce_admins|type=="object" then .enforce_admins.enabled elif .enforce_admins|type=="boolean" then .enforce_admins else false end')
  fi
  strict=$(printf '%s' "$body" | jq -r '.required_status_checks.strict // false')
  reviews=$(printf '%s' "$body" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')
  force=$(printf '%s' "$body" | jq -r 'if .allow_force_pushes|type=="object" then .allow_force_pushes.enabled elif .allow_force_pushes|type=="boolean" then .allow_force_pushes else false end')
  delete=$(printf '%s' "$body" | jq -r 'if .allow_deletions|type=="object" then .allow_deletions.enabled elif .allow_deletions|type=="boolean" then .allow_deletions else false end')
  contexts_json=$(printf '%s' "$body" | jq -c '.required_status_checks.contexts // []')

  local ok=1
  local problems=""
  if [[ "$enforce" != "true" ]]; then
    problems="${problems}enforce_admins!=true; "
    ok=0
  fi
  if ! [[ "$reviews" =~ ^[0-9]+$ ]] || [[ "$reviews" -lt 1 ]]; then
    problems="${problems}required_approving_review_count<1; "
    ok=0
  fi
  if [[ "$strict" != "true" ]]; then
    problems="${problems}required_status_checks.strict!=true; "
    ok=0
  fi
  if [[ "$force" != "false" ]]; then
    problems="${problems}allow_force_pushes enabled; "
    ok=0
  fi
  if [[ "$delete" != "false" ]]; then
    problems="${problems}allow_deletions enabled; "
    ok=0
  fi

  # Compare requiredContexts (config) to live protection contexts
  local ctx missing=0
  while IFS= read -r ctx; do
    [[ -z "$ctx" ]] && continue
    if ! printf '%s' "$contexts_json" | jq -e --arg c "$ctx" 'index($c) != null' >/dev/null 2>&1; then
      problems="${problems}missing context $(sq "$ctx"); "
      missing=1
      ok=0
    fi
  done <<EOF
$REQUIRED_CONTEXTS_NL
EOF

  if [[ "$ok" -eq 1 ]]; then
    record PASS "protection.${role}" "branch $(sq "$branch") protection healthy (enforce_admins, reviews, strict, no force/delete, contexts present)"
  else
    record OWNER_REQUIRED "protection.${role}" \
      "branch $(sq "$branch") protection drift: ${problems}owner must harden via delivery-control (this script never applies protection)"
    plan_line "OWNER: scripts/delivery-control/apply-branch-protection.sh --repo $(sq "$REPO") --apply  # Mark-owned"
  fi
}

audit_reviewer_identity() {
  if [[ -z "$REVIEWER_LOGIN" ]]; then
    record OWNER_REQUIRED "reviewer" \
      "reviewerLogin not set in .gibson-delivery.json — independent reviewer identity is Mark-owned (L-021); solo owner cannot satisfy required reviews"
    plan_line "OWNER: set reviewerLogin in .gibson-delivery.json to a login distinct from PR authors/owner, and ensure that identity can approve"
    return 0
  fi
  if [[ -n "$LIVE_OWNER_LOGIN" && "$REVIEWER_LOGIN" == "$LIVE_OWNER_LOGIN" ]]; then
    record OWNER_REQUIRED "reviewer" \
      "reviewerLogin $(sq "$REVIEWER_LOGIN") equals repo owner — same-actor reviews will not clear branch protection (L-021); need a distinct reviewer identity"
    plan_line "OWNER: provision a distinct GitHub identity or bot that can formal-approve (not $(sq "$LIVE_OWNER_LOGIN"))"
    return 0
  fi
  record PASS "reviewer" "reviewerLogin=$(sq "$REVIEWER_LOGIN") is distinct from owner=$(sq "$LIVE_OWNER_LOGIN")"
}

audit_environment() {
  if [[ -z "$PROD_ENV" ]]; then
    record PASS "environment" "productionEnvironment null/skipped by config"
    return 0
  fi
  local body errfile
  errfile=$(mktemp)
  if ! body=$(gh api "repos/${REPO}/environments/$(printf '%s' "$PROD_ENV" | sed 's/ /%20/g')" 2>"$errfile"); then
    local err
    err=$(cat "$errfile" 2>/dev/null || true)
    rm -f "$errfile"
    record OWNER_REQUIRED "environment" \
      "GitHub environment $(sq "$PROD_ENV") missing or inaccessible — owner must configure via delivery-control apply-production-env (never applied by this script)"
    plan_line "OWNER: scripts/delivery-control/apply-production-env.sh --repo $(sq "$REPO") --apply  # Mark-owned"
    return 0
  fi
  rm -f "$errfile"
  if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    record ERROR "environment" "environment JSON malformed"
    return 1
  fi
  local rules
  rules=$(printf '%s' "$body" | jq -r '.protection_rules | length // 0')
  if ! [[ "$rules" =~ ^[0-9]+$ ]] || [[ "$rules" -lt 1 ]]; then
    record OWNER_REQUIRED "environment" \
      "environment $(sq "$PROD_ENV") has no protection_rules — owner must add required reviewers (Mark-owned; not applied here)"
    plan_line "OWNER: scripts/delivery-control/apply-production-env.sh --repo $(sq "$REPO") --apply"
    return 0
  fi
  record PASS "environment" "environment $(sq "$PROD_ENV") has ${rules} protection rule(s)"
}

audit_dco() {
  # Report-only: look for local workflow evidence of DCO; never install apps.
  local found=0
  if [[ -d "${LOCAL_PATH}/.github/workflows" ]]; then
    if grep -Rqi -- 'dco\|signed-off-by\|probot/dco' "${LOCAL_PATH}/.github/workflows" 2>/dev/null; then
      found=1
    fi
  fi
  if [[ "$found" -eq 1 ]]; then
    # Local workflow evidence is enough for this slice's PASS; installing the
    # GitHub DCO app remains Mark-owned and is never performed here.
    record PASS "dco" \
      "local DCO-related workflow evidence present (app install/config remains Mark-owned; never applied by this script)"
  else
    record OWNER_REQUIRED "dco" \
      "no local DCO workflow evidence — if the org requires Signed-off-by, owner installs DCO app/check (not applied by this script)"
    plan_line "OWNER: install DCO app or required DCO check if org policy requires sign-off"
  fi
}

# Workflow / required context evidence (installed files only — not execution)
audit_workflow_context_evidence() {
  local wf_dir="${LOCAL_PATH}/.github/workflows"
  local ctx installed_names=""
  if [[ ! -d "$wf_dir" ]]; then
    record OWNER_REQUIRED "workflows" \
      "no .github/workflows directory under $(sq "$LOCAL_PATH") — install CI templates before requiring checks"
    return 0
  fi

  # Collect job/check name hints from YAML (best-effort static evidence only)
  installed_names=$(grep -RhoE -- 'name:[[:space:]]*[^#[:space:]].*' "$wf_dir" 2>/dev/null \
    | sed 's/^name:[[:space:]]*//' | sed 's/["'\'']//g' | sort -u || true)

  while IFS= read -r ctx; do
    [[ -z "$ctx" ]] && continue
    if printf '%s\n' "$installed_names" | grep -Fqi -- "$ctx"; then
      record PASS "workflow-static.${ctx}" \
        "static workflow/config mentions context $(sq "$ctx") (NOT execution evidence)"
    else
      # Missing static mention is owner-required install/calibration drift
      record OWNER_REQUIRED "workflow-static.${ctx}" \
        "no static workflow mention of required context $(sq "$ctx") under .github/workflows — install/calibrate CI (still not execution proof)"
    fi
  done <<EOF
$REQUIRED_CONTEXTS_NL
EOF

  # test-integrity canary: static evidence NEVER upgrades to executed PASS.
  # Only an explicit observed-run attestation (operator-supplied env, never
  # invented from YAML) may clear this to PASS.
  if printf '%s\n' "$REQUIRED_CONTEXTS_NL" | grep -Fxq -- "test-integrity" \
    || printf '%s\n' "$installed_names" | grep -Fqi -- "test-integrity"; then
    if [[ -n "${GIBSON_TEST_INTEGRITY_OBSERVED_RUN:-}" ]]; then
      record PASS "test-integrity-canary" \
        "operator-attested observed run $(sq "$GIBSON_TEST_INTEGRITY_OBSERVED_RUN") — static YAML alone never clears this gate"
    else
      record UNKNOWN "test-integrity-canary" \
        "test-integrity remains FAIL/UNKNOWN until a real observed CI run proves the four-job path executed and the required check blocked deletions — static workflow YAML is never canary PASS (issue #70/#68)"
      plan_line "OWNER: run live canaries (no-change pass; deletion/skip/hostile-helper/failing-base/missing-artifact fail; exact waiver pass) then require check name test-integrity"
    fi
  fi
}

audit_vercel() {
  # Credential-free: never call Vercel API, never mint tokens. Surface
  # contradiction/unavailability as owner-required — never silently green.
  #
  # Optional operator attestation (not a credential): when
  # GIBSON_VERCEL_PRODUCTION_BRANCH is set to the live console value, treat as
  # verified observation for this audit only.
  local attested="${GIBSON_VERCEL_PRODUCTION_BRANCH:-}"
  local agents="" claimed="" claim_branch=""

  if [[ -n "$attested" ]]; then
    if [[ "$attested" == "$PRODUCTION_BRANCH" ]]; then
      record PASS "vercel" \
        "operator-attested Vercel Production Branch=$(sq "$attested") matches config (no Vercel API; credential-free)"
      return 0
    fi
    record OWNER_REQUIRED "vercel" \
      "operator-attested Vercel Production Branch=$(sq "$attested") contradicts config productionBranch=$(sq "$PRODUCTION_BRANCH") (L-004) — not silently green"
    plan_line "OWNER: reconcile Vercel Production Branch $(sq "$attested") with .gibson-delivery.json productionBranch=$(sq "$PRODUCTION_BRANCH")"
    return 0
  fi

  if [[ -f "${LOCAL_PATH}/AGENTS.md" && ! -L "${LOCAL_PATH}/AGENTS.md" ]]; then
    agents=$(cat -- "${LOCAL_PATH}/AGENTS.md" 2>/dev/null || true)
    claimed=$(printf '%s\n' "$agents" | grep -iE 'Production [Bb]ranch|production branch' | head -5 || true)
  fi

  # shellcheck disable=SC2016 # intentional literal backticks in regex
  claim_branch=$(printf '%s\n' "$claimed" | grep -oE '`[^`]+`' | head -1 | tr -d '`' || true)
  if [[ -z "$claim_branch" ]]; then
    claim_branch=$(printf '%s\n' "$claimed" | grep -oiE 'production branch[^[:alnum:]]+[A-Za-z0-9._/-]+' \
      | awk '{print $NF}' | head -1 || true)
  fi
  if [[ -n "$claim_branch" && "$claim_branch" != "$PRODUCTION_BRANCH" ]]; then
    record OWNER_REQUIRED "vercel" \
      "AGENTS.md claims Production Branch $(sq "$claim_branch") but config productionBranch=$(sq "$PRODUCTION_BRANCH") — contradiction is owner-required (L-004); not silently green"
    plan_line "OWNER: reconcile Vercel Production Branch, AGENTS.md, and .gibson-delivery.json (truth = Vercel console)"
    return 0
  fi

  # No credentials and no operator attestation → unavailable, not green.
  record OWNER_REQUIRED "vercel" \
    "Vercel Production Branch unavailable in this credential-free slice — owner must verify Project → Settings → Git → Production Branch matches model $(sq "$MODEL") / productionBranch=$(sq "$PRODUCTION_BRANCH") (L-004); never agent-applied. Optional: export GIBSON_VERCEL_PRODUCTION_BRANCH=<live-value> after console check."
  plan_line "OWNER: verify Vercel Production Branch is $(sq "$PRODUCTION_BRANCH") for model $(sq "$MODEL") (console only; no credentials in this script)"
}

# ---------------------------------------------------------------------------
# Summarize / render
# ---------------------------------------------------------------------------
render_findings() {
  local line status area msg
  echo "## Findings"
  if [[ ! -s "$FINDINGS_FILE" ]]; then
    echo "  (none)"
    return
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    status=${line%%|*}
    rest=${line#*|}
    area=${rest%%|*}
    msg=${rest#*|}
    printf '  [%s] %s — %s\n' "$status" "$area" "$msg"
  done <"$FINDINGS_FILE"
}

render_plan() {
  echo "## Safe apply plan"
  if [[ ! -s "$PLAN_FILE" ]]; then
    echo "  (no safe mutations planned)"
  else
    # Only print SAFE plan lines (CREATE_LABEL, PATCH_REPO, GITIGNORE) here;
    # OWNER lines go to remediation section.
    local line
    while IFS= read -r line; do
      case "$line" in
        OWNER:*) continue ;;
        "") continue ;;
        *) printf '  %s\n' "$line" ;;
      esac
    done <"$PLAN_FILE"
  fi
  echo ""
  echo "## Owner-required remediation (never auto-applied)"
  local any=0
  while IFS= read -r line; do
    case "$line" in
      OWNER:*)
        printf '  %s\n' "$line"
        any=1
        ;;
    esac
  done <"$PLAN_FILE"
  if [[ "$any" -eq 0 ]]; then
    echo "  (none listed in plan — see OWNER_REQUIRED findings above)"
  fi
}

build_report_body() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)
  cat <<EOF
# Gibson git-configure report

- generated: ${ts}
- script: git-configure.sh ${VERSION}
- mode: ${MODE}
- repo: ${REPO}
- model: ${MODEL}
- defaultBranch (config): ${DEFAULT_BRANCH}
- productionBranch (config): ${PRODUCTION_BRANCH}
- live default_branch: ${LIVE_DEFAULT_BRANCH}
- path: ${LOCAL_PATH}
- counts: PASS=${COUNT_PASS} SAFE_DRIFT=${COUNT_SAFE_DRIFT} OWNER_REQUIRED=${COUNT_OWNER} UNKNOWN=${COUNT_UNKNOWN} ERROR=${COUNT_ERROR}

This report contains no secrets. Runtime artifact — do not commit.

EOF
  render_findings
  echo ""
  render_plan
  echo ""
  echo "## Verdict"
  if [[ "$HAD_APPLY_FAILURE" -eq 1 || "$HAD_TOOL_FAILURE" -eq 1 || "$COUNT_ERROR" -gt 0 ]]; then
    echo "ERROR — tool/API/apply/report failure (exit 3). Not READY."
  elif [[ "$COUNT_SAFE_DRIFT" -eq 0 && "$COUNT_OWNER" -eq 0 && "$COUNT_UNKNOWN" -eq 0 ]]; then
    echo "READY — every check PASS; no owner-required or unknown drift."
  else
    echo "DRIFT — safe drift and/or owner-required/unknown remain (exit 1). Not READY."
  fi
  echo ""
  echo "## Mark-owned live settings (never applied by this slice)"
  cat <<'EOF'
  - Branch protection + required status contexts (delivery-control apply-branch-protection)
  - Required reviewing identity distinct from PR authors/owner
  - GitHub Environment protection rules
  - DCO app / required DCO check
  - Vercel Production Branch and project secrets
  - test-integrity required-check activation and live canaries (#70/#68)
  - Secrets, auth, credentials of any kind
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  need_cmd gh
  need_cmd jq
  need_cmd mktemp
  need_cmd grep
  need_cmd sed

  # Validate local path early
  if [[ ! -d "$LOCAL_PATH" ]]; then
    die_usage "local --path is not a directory: $LOCAL_PATH"
  fi
  if [[ -L "$LOCAL_PATH" ]]; then
    # Allow symlink dir only if it resolves to a directory; still ok for checkout roots.
    :
  fi

  FINDINGS_FILE=$(mktemp)
  PLAN_FILE=$(mktemp)
  MUTATION_LOG=$(mktemp)
  GH_MUTATION_LOG="${GH_MUTATION_LOG:-}"  # tests may pre-set
  if [[ -z "$GH_MUTATION_LOG" && -n "${GIBSON_GH_MUTATION_LOG:-}" ]]; then
    GH_MUTATION_LOG="$GIBSON_GH_MUTATION_LOG"
  fi
  # shellcheck disable=SC2064
  trap 'rm -f -- "$FINDINGS_FILE" "$PLAN_FILE" "$MUTATION_LOG"' EXIT

  load_config

  if [[ -z "$REPO" ]]; then
    # Try gh repo view from LOCAL_PATH
    local detected
    if detected=$(cd "$LOCAL_PATH" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); then
      REPO="$detected"
    fi
  fi
  if [[ -z "$REPO" ]]; then
    die_usage "--repo owner/name required (or set in .gibson-delivery.json / gh repo view)"
  fi
  validate_repo_slug "$REPO" || die_usage "invalid --repo slug: $(sq "$REPO")"

  if [[ -z "$REPORT_PATH" && "$NO_REPORT" -eq 0 && "$ASSUME_DEFAULT_REPORT" -eq 1 ]]; then
    REPORT_PATH="${LOCAL_PATH}/gibson/git-config-report.md"
  fi

  # Auth probe (read-only)
  if ! gh auth status >/dev/null 2>&1; then
    # Some fake gh fixtures may not implement auth status — try a harmless api
    if ! gh api user >/dev/null 2>&1; then
      die_tool "gh is not authenticated (gh auth status / gh api user failed)"
    fi
  fi

  echo "=============================================="
  echo " Gibson git-configure — ${MODE}"
  echo " repo=${REPO} model=${MODEL}"
  echo " path=${LOCAL_PATH}"
  echo " $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  echo "=============================================="
  echo ""

  if ! fetch_repo_meta; then
    # hard failure path
    :
  fi

  # Only continue deep audits if we have meta (or still report what we can)
  if [[ "$COUNT_ERROR" -eq 0 ]]; then
    audit_labels || true
    audit_merge_settings || true
    audit_gitignore || true

    local prot_branch
    prot_branch="${LIVE_DEFAULT_BRANCH:-$DEFAULT_BRANCH}"
    audit_branch_protection "$prot_branch" "default" || true
    if [[ "$MODEL" == "release-branch" && "$PRODUCTION_BRANCH" != "$prot_branch" ]]; then
      audit_branch_protection "$PRODUCTION_BRANCH" "production" || true
    fi

    audit_reviewer_identity || true
    audit_environment || true
    audit_dco || true
    audit_workflow_context_evidence || true
    audit_vercel || true
  fi

  echo ""
  render_findings
  echo ""
  render_plan
  echo ""

  # Modes
  case "$MODE" in
    audit)
      echo "## Mode: audit (read-only — zero mutations performed)"
      ;;
    dry-run)
      echo "## Mode: dry-run (plan only — zero mutations performed)"
      if [[ -n "${GIBSON_GH_MUTATION_LOG:-}" && -f "${GIBSON_GH_MUTATION_LOG}" ]]; then
        :
      fi
      ;;
    apply)
      echo "## Mode: apply (safe mutations only)"
      if [[ "$COUNT_ERROR" -gt 0 ]]; then
        echo "  refusing apply because audit already hit ERROR"
        HAD_APPLY_FAILURE=1
      else
        # Apply safe items even when owner-required remains (partial readiness)
        apply_labels || true
        apply_gitignore || true
        apply_merge_settings || true

        if [[ "$HAD_APPLY_FAILURE" -eq 1 ]]; then
          echo "  APPLY INCOMPLETE — one or more mutations failed readback. Not READY."
        else
          echo "  safe mutations applied and verified."
          # Re-read live safe surface so exit/verdict reflect post-apply truth
          # (pre-apply SAFE_DRIFT findings are historical; live counters reset).
          if fetch_repo_meta; then
            COUNT_SAFE_DRIFT=0
            # Drop prior SAFE_DRIFT lines from findings (keep PASS/OWNER/UNKNOWN/ERROR)
            if [[ -f "$FINDINGS_FILE" ]]; then
              grep -v '^SAFE_DRIFT|' "$FINDINGS_FILE" >"${FINDINGS_FILE}.new" 2>/dev/null \
                || true
              mv "${FINDINGS_FILE}.new" "$FINDINGS_FILE"
            fi
            audit_labels || true
            audit_merge_settings || true
            audit_gitignore || true
          fi
        fi
      fi
      # Re-state that protection etc. were NOT applied
      echo "  NOTE: branch protection / environments / DCO / Vercel / secrets were NOT modified."
      ;;
  esac

  echo ""
  # Always print verdict to stdout
  echo "## Summary"
  echo "  PASS=${COUNT_PASS} SAFE_DRIFT=${COUNT_SAFE_DRIFT} OWNER_REQUIRED=${COUNT_OWNER} UNKNOWN=${COUNT_UNKNOWN} ERROR=${COUNT_ERROR}"
  if [[ "$HAD_APPLY_FAILURE" -eq 1 || "$COUNT_ERROR" -gt 0 ]]; then
    echo "  VERDICT: ERROR (not READY)"
  elif [[ "$COUNT_SAFE_DRIFT" -eq 0 && "$COUNT_OWNER" -eq 0 && "$COUNT_UNKNOWN" -eq 0 ]]; then
    echo "  VERDICT: READY"
  else
    echo "  VERDICT: DRIFT (not READY)"
  fi

  if [[ "$NO_REPORT" -eq 0 && -n "$REPORT_PATH" ]]; then
    echo ""
    echo "Writing report: ${REPORT_PATH}"
    local report_body
    report_body=$(build_report_body)
    atomic_write_report "$REPORT_PATH" "$report_body"
    echo "  report written."
  fi

  # Compute exit without relying on set -e + function return alone.
  if [[ "$HAD_APPLY_FAILURE" -eq 1 || "$HAD_TOOL_FAILURE" -eq 1 || "$COUNT_ERROR" -gt 0 ]]; then
    exit 3
  fi
  if [[ "$COUNT_SAFE_DRIFT" -gt 0 || "$COUNT_OWNER" -gt 0 || "$COUNT_UNKNOWN" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
