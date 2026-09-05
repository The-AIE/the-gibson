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
    --audit     read-only (DEFAULT). ZERO filesystem and GitHub mutations.
                Findings and plan go to stdout only unless --report PATH.
    --dry-run   print the exact safe apply plan. ZERO mutations. Even with
                --report PATH, nothing is written (plan/report body on stdout).
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
    branch remapping. Static workflow YAML, inert DCO files, or config strings
    are NEVER treated as live enforcement of DCO / test-integrity / canaries.

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
                   [--report PATH]         # ONLY explicit local write (audit/apply)
                   [--no-report]           # compat; default already writes no file
                   [--help]

EXIT
  0  READY — every check PASS, no owner-required / unknown
  1  DRIFT — safe drift and/or owner-required / unknown remain
  2  usage or config validation error (incl. incoherent delivery model)
  3  tool / API schema / apply / report failure

EXAMPLES
  ./scripts/git-configure.sh --repo acme/app
  ./scripts/git-configure.sh --dry-run --path ~/Code/acme-app --repo acme/app
  ./scripts/git-configure.sh --apply --path ~/Code/acme-app --repo acme/app
  ./scripts/git-configure.sh --audit --report /tmp/git-config-report.md

REPORT
  Default audit writes NO report file (stdout only). The only audit filesystem
  write is an explicit --report PATH. Written atomically (same-dir temp +
  rename) after validating every path component (no symlink ancestors, no ..,
  no FIFO/device/directory destinations). --dry-run never writes the report
  even when --report is supplied. --no-report remains for compatibility.
  Never contains secrets. Report paths are runtime artifacts — do not commit.

CONFIG
  Optional .gibson-delivery.json (see templates/target-repo/gibson-delivery.json
  and docs/23). Supported fields only: repo, model, defaultBranch,
  productionBranch, requiredContexts, productionEnvironment, reviewerLogin.
  No secrets. Malformed, unsupported model, or incoherent model/branch
  pairing (e.g. main-is-prod with productionBranch != defaultBranch) → exit 2.

OBSERVED-RUN ATTESTATIONS (credential-free; never invent from YAML)
  GIBSON_VERCEL_PRODUCTION_BRANCH=<exact live Production Branch string>
  GIBSON_TEST_INTEGRITY_OBSERVED_RUN=https://github.com/<owner>/<repo>/actions/runs/<id>
  GIBSON_DCO_OBSERVED_RUN= same exact URL shape for this repo only
  URL must match REPO exactly (no other host/path/query). Before PASS the
  script re-fetches the run via gh and requires completed/success plus the
  exact configured check name (DCO / test-integrity) on that head SHA.
  observed-run:<token> and arbitrary strings NEVER PASS.
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
# No implicit report path: default audit writes zero files.
REPORT_PARENT_PHYS=""

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

# Line-order guard: helpers below invoke gh/jq only from main(), which
# calls need_cmd first. --help / -h / --version skip so usage and version
# work without the tools. Operational paths still hit the guards in main().
case " $* " in
  *" --help "*|*" -h "*|*" --version "*) ;;
  *)
    need_cmd gh
    need_cmd jq
    ;;
esac

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
        shift 2
        ;;
      --no-report)
        # Compat: default already writes no file; this clears any --report.
        NO_REPORT=1
        REPORT_PATH=""
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
    validate_model_coherence
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
      CHANGEME*|REPLACE_*|REPLACE-*|\<*\>)
        die_usage "reviewerLogin placeholder must be replaced: $(sq "$REVIEWER_LOGIN")"
        ;;
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

  # Model / branch coherence (docs/23). Incoherent config must not READY.
  validate_model_coherence
}

# main-is-prod: productionBranch must equal defaultBranch (single live write path).
# release-branch: distinct nonempty productionBranch; both branches are audited.
# tag-pin: productionBranch must equal defaultBranch (tags cut from protected
# default; must not skip the live production write path via a phantom branch).
validate_model_coherence() {
  case "$MODEL" in
    main-is-prod)
      if [[ "$PRODUCTION_BRANCH" != "$DEFAULT_BRANCH" ]]; then
        die_usage "incoherent model main-is-prod: productionBranch ($(sq "$PRODUCTION_BRANCH")) must equal defaultBranch ($(sq "$DEFAULT_BRANCH"))"
      fi
      ;;
    release-branch)
      if [[ -z "$PRODUCTION_BRANCH" ]]; then
        die_usage "incoherent model release-branch: productionBranch must be nonempty and distinct from defaultBranch"
      fi
      if [[ "$PRODUCTION_BRANCH" == "$DEFAULT_BRANCH" ]]; then
        die_usage "incoherent model release-branch: productionBranch ($(sq "$PRODUCTION_BRANCH")) must differ from defaultBranch"
      fi
      ;;
    tag-pin)
      if [[ "$PRODUCTION_BRANCH" != "$DEFAULT_BRANCH" ]]; then
        die_usage "incoherent model tag-pin: productionBranch ($(sq "$PRODUCTION_BRANCH")) must equal defaultBranch ($(sq "$DEFAULT_BRANCH")) — tag-pin may not skip the live production write path"
      fi
      ;;
    *)
      die_usage "unsupported model $(sq "$MODEL")"
      ;;
  esac
}

# Exact Actions run URL for THIS repo only (DCO / test-integrity).
# Accepts solely: https://github.com/${REPO}/actions/runs/<positive-id>
# No query/fragment, no other host/path, no observed-run:<token> synthetic.
# Prints run id on stdout; return 0 on shape match, 1 otherwise.
parse_actions_run_url() {
  local v="$1"
  local prefix id
  [[ -n "$v" && -n "$REPO" ]] || return 1
  case "$v" in
    *[[:space:]]*|*[[:cntrl:]]*) return 1 ;;
  esac
  prefix="https://github.com/${REPO}/actions/runs/"
  case "$v" in
    "$prefix"*)
      id="${v#"$prefix"}"
      # positive integer only — no trailing slash, query, or path
      if printf '%s' "$id" | grep -E '^[1-9][0-9]{0,18}$' >/dev/null; then
        printf '%s' "$id"
        return 0
      fi
      ;;
  esac
  return 1
}

# Live-validate an Actions run + exact check-run name for REPO.
# $1=run_id  $2=exact check/context name (e.g. DCO, test-integrity)
# Return: 0=PASS-worthy evidence, 1=invalid/incomplete evidence (UNKNOWN),
#         2=API/schema failure (ERROR). Never prints secrets.
verify_live_actions_check() {
  local run_id="$1"
  local want_name="$2"
  local body head_sha full_name status conclusion rid n cr mstatus mconc

  [[ -n "$run_id" && -n "$want_name" && -n "$REPO" ]] || return 2

  if ! body=$(gh_api "repos/${REPO}/actions/runs/${run_id}" 2>/dev/null); then
    return 2
  fi
  if ! printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
    return 2
  fi

  rid=$(printf '%s' "$body" | jq -r '.id | tostring' 2>/dev/null || echo "")
  status=$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || echo "")
  conclusion=$(printf '%s' "$body" | jq -r '.conclusion // empty' 2>/dev/null || echo "")
  head_sha=$(printf '%s' "$body" | jq -r '.head_sha // empty' 2>/dev/null || echo "")
  full_name=$(printf '%s' "$body" | jq -r '.repository.full_name // empty' 2>/dev/null || echo "")

  # Numeric id must match requested run; repository.full_name exact REPO
  if [[ "$rid" != "$run_id" ]]; then
    return 1
  fi
  if [[ "$full_name" != "$REPO" ]]; then
    return 1
  fi
  if [[ "$status" != "completed" ]]; then
    return 1
  fi
  if [[ "$conclusion" != "success" ]]; then
    return 1
  fi
  # 40-lowercase-hex head_sha only
  if ! printf '%s' "$head_sha" | grep -E '^[0-9a-f]{40}$' >/dev/null; then
    return 1
  fi

  # Deterministic check-runs for this exact head (GitHub commits API)
  if ! cr=$(gh_api "repos/${REPO}/commits/${head_sha}/check-runs" 2>/dev/null); then
    return 2
  fi
  if ! printf '%s' "$cr" | jq -e 'type == "object" and (.check_runs | type == "array")' >/dev/null 2>&1; then
    return 2
  fi

  n=$(printf '%s' "$cr" | jq --arg n "$want_name" \
    '[.check_runs[] | select(.name == $n)] | length' 2>/dev/null || echo "0")
  if [[ "$n" == "0" ]]; then
    return 1
  fi
  if [[ "$n" != "1" ]]; then
    # duplicate / ambiguous exact-name checks
    return 1
  fi

  mstatus=$(printf '%s' "$cr" | jq -r --arg n "$want_name" \
    '[.check_runs[] | select(.name == $n)][0].status // empty' 2>/dev/null || echo "")
  mconc=$(printf '%s' "$cr" | jq -r --arg n "$want_name" \
    '[.check_runs[] | select(.name == $n)][0].conclusion // empty' 2>/dev/null || echo "")
  if [[ "$mstatus" != "completed" || "$mconc" != "success" ]]; then
    return 1
  fi
  return 0
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
# Atomic report write (ancestor-safe; never follows planted symlinks)
# ---------------------------------------------------------------------------
report_dest_ok() {
  local dest="$1"
  if [[ -L "$dest" ]]; then
    return 1
  fi
  # Refuse FIFO, device, directory, socket — only missing or regular file.
  if [[ -e "$dest" ]]; then
    if [[ ! -f "$dest" ]]; then
      return 1
    fi
    # -f is true for regular files; also refuse if somehow a dir slipped through
    if [[ -d "$dest" ]]; then
      return 1
    fi
  fi
  return 0
}

# True if path string contains a .. component (not merely substring of a name).
path_has_dotdot_component() {
  local p="$1"
  case "$p" in
    '..'|../*|*/..|*/../*) return 0 ;;
  esac
  # Component-wise
  local rest comp
  rest="$p"
  while [[ -n "$rest" ]]; do
    case "$rest" in
      /*) rest="${rest#/}" ;;
    esac
    comp="${rest%%/*}"
    if [[ "$rest" == *"/"* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
    [[ "$comp" == ".." ]] && return 0
  done
  return 1
}

# Make path absolute without resolving symlinks (preserve planted-link detection).
report_abs_path() {
  local p="$1"
  case "$p" in
    /*) printf '%s' "$p" ;;
    *) printf '%s/%s' "$(pwd)" "$p" ;;
  esac
}

# Physical directory of an existing path (no symlink leaf). Empty on failure.
physical_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    return 1
  fi
  # cd -P resolves symlink ancestors; refuse if leaf itself is a symlink dir we
  # cannot enter safely.
  if [[ -L "$d" ]]; then
    return 1
  fi
  (CDPATH='' cd -P -- "$d" 2>/dev/null && pwd -P)
}

# Rewrite only fixed OS root aliases for macOS portability:
#   /tmp → /private/tmp   and   /var → /private/var
# Never follows any other symlink (planted bridge/leaf links are refused).
canonicalize_trusted_root_alias() {
  local p="$1"
  local link

  case "$p" in
    /tmp|/tmp/*)
      if [[ -L /tmp ]]; then
        link=$(readlink /tmp 2>/dev/null || true)
        case "$link" in
          private/tmp|/private/tmp)
            if [[ "$p" == "/tmp" ]]; then
              printf '%s' "/private/tmp"
            else
              printf '%s' "/private/tmp${p#/tmp}"
            fi
            return 0
            ;;
        esac
      fi
      ;;
    /var|/var/*)
      if [[ -L /var ]]; then
        link=$(readlink /var 2>/dev/null || true)
        case "$link" in
          private/var|/private/var)
            if [[ "$p" == "/var" ]]; then
              printf '%s' "/private/var"
            else
              printf '%s' "/private/var${p#/var}"
            fi
            return 0
            ;;
        esac
      fi
      ;;
  esac
  printf '%s' "$p"
}

# Validate ancestors; create missing dirs component-by-component with rechecks.
# After trusted root-alias rewrite, every subsequent component is lstat'd and
# any symlink is rejected (never followed). Final parent must be a real dir;
# paths under LOCAL_PATH must stay physically inside the checkout.
prepare_report_dir() {
  local target_dir="$1"
  local cur="" rest comp next local_phys dir_phys abs_local phys logical_in

  if path_has_dotdot_component "$target_dir"; then
    die_tool "report path rejects .. components: $target_dir"
  fi
  case "$target_dir" in
    /*) ;;
    *) die_tool "internal: report dir not absolute: $target_dir" ;;
  esac

  if [[ "$target_dir" == "/" ]]; then
    die_tool "refuse report directory /"
  fi

  # Remember whether the pre-rewrite absolute path is under LOCAL_PATH
  # (containment still applies to in-checkout reports).
  abs_local=$(report_abs_path "$LOCAL_PATH")
  logical_in=0
  case "$target_dir" in
    "$abs_local"|"$abs_local"/*) logical_in=1 ;;
  esac

  target_dir=$(canonicalize_trusted_root_alias "$target_dir")
  if path_has_dotdot_component "$target_dir"; then
    die_tool "report path rejects .. components after alias rewrite: $target_dir"
  fi
  case "$target_dir" in
    /*) ;;
    *) die_tool "internal: report dir not absolute after alias rewrite: $target_dir" ;;
  esac
  if [[ "$target_dir" == "/" ]]; then
    die_tool "refuse report directory /"
  fi

  rest="${target_dir#/}"
  cur=""
  while [[ -n "$rest" ]]; do
    comp="${rest%%/*}"
    if [[ "$rest" == *"/"* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
    [[ -z "$comp" ]] && continue
    if [[ "$comp" == "." || "$comp" == ".." ]]; then
      die_tool "report path component illegal: $comp"
    fi
    next="${cur}/${comp}"

    # Reject every non-trusted ancestor symlink (aliases already rewritten).
    if [[ -L "$next" ]]; then
      die_tool "report ancestor is a symlink (refuse; never follow planted links): $next"
    fi

    if [[ -e "$next" ]]; then
      if [[ ! -d "$next" ]]; then
        die_tool "report ancestor is not a directory: $next"
      fi
      cur="$next"
    else
      if ! mkdir -- "$next" 2>/dev/null; then
        die_tool "cannot create report directory component: $next"
      fi
      if [[ -L "$next" || ! -d "$next" ]]; then
        die_tool "report directory component unsafe after create: $next"
      fi
      cur="$next"
    fi
  done

  # Final parent must be a real (non-symlink) directory we can write.
  if [[ -L "$cur" || ! -d "$cur" ]]; then
    die_tool "report parent is not a real directory: $cur"
  fi
  if [[ ! -w "$cur" ]]; then
    die_tool "report directory is not writable: $cur"
  fi

  # Containment: in-checkout report paths must stay inside physical checkout.
  if [[ "$logical_in" -eq 1 ]]; then
    local_phys=$(physical_dir "$abs_local" || true)
    dir_phys=$(physical_dir "$cur" || true)
    if [[ -z "$local_phys" || -z "$dir_phys" ]]; then
      die_tool "cannot physically resolve report path under checkout: $target_dir"
    fi
    case "$dir_phys" in
      "$local_phys"|"$local_phys"/*) ;;
      *)
        die_tool "report path escapes checkout via symlink (refuse): logical=$target_dir physical=$dir_phys"
        ;;
    esac
  fi

  # Export physical parent for atomic write (same-dir temp + rename).
  REPORT_PARENT_PHYS="$cur"
  if phys=$(physical_dir "$cur" 2>/dev/null); then
    REPORT_PARENT_PHYS="$phys"
  fi
}

atomic_write_report() {
  local dest="$1"
  local content="$2"
  local dir base tmp abs parent

  if [[ -z "$dest" ]]; then
    die_tool "empty report path"
  fi
  if path_has_dotdot_component "$dest"; then
    die_tool "report path rejects .. components: $dest"
  fi

  abs=$(report_abs_path "$dest")
  dir=$(dirname -- "$abs")
  base=$(basename -- "$abs")

  if [[ -z "$base" || "$base" == "." || "$base" == ".." || "$base" == "/" ]]; then
    die_tool "invalid report basename: $dest"
  fi

  REPORT_PARENT_PHYS=""
  prepare_report_dir "$dir"
  parent="${REPORT_PARENT_PHYS:-$dir}"

  # Final parent recheck (TOCTOU / component swap): real dir, not symlink
  if [[ -L "$parent" || ! -d "$parent" ]]; then
    die_tool "report parent is not a real directory: $parent"
  fi
  # Destination leaf on the logical path — also check physical sibling path
  local phys_dest="${parent}/${base}"
  if ! report_dest_ok "$phys_dest"; then
    die_tool "report path is not a safe regular-file destination: $phys_dest"
  fi
  if [[ -e "$abs" ]] && ! report_dest_ok "$abs"; then
    die_tool "report path is not a safe regular-file destination: $abs"
  fi

  tmp=$(mktemp "${parent}/.${base}.XXXXXX") || die_tool "mktemp failed for report: $phys_dest"
  if [[ -L "$tmp" || ! -f "$tmp" ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    die_tool "report temp is not a regular file: $tmp"
  fi
  if ! printf '%s' "$content" >"$tmp"; then
    rm -f -- "$tmp"
    die_tool "failed writing report temp: $tmp"
  fi
  if [[ -L "$parent" || ! -d "$parent" ]]; then
    rm -f -- "$tmp"
    die_tool "report parent became unsafe before rename: $parent"
  fi
  if ! report_dest_ok "$phys_dest"; then
    rm -f -- "$tmp"
    die_tool "report destination became unsafe before rename: $phys_dest"
  fi
  if [[ -e "$phys_dest" && ! -f "$phys_dest" ]]; then
    rm -f -- "$tmp"
    die_tool "report destination is not a regular file: $phys_dest"
  fi
  if ! mv -f -- "$tmp" "$phys_dest"; then
    rm -f -- "$tmp"
    die_tool "atomic rename failed for report: $phys_dest"
  fi
  if [[ -L "$phys_dest" || ! -f "$phys_dest" ]]; then
    die_tool "report path is not a regular file after write: $phys_dest"
  fi
  # If logical abs differs from phys_dest but is not a symlink escape, best-effort
  # note: writers always land on physical path; containment already enforced.
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
# Repo endpoint: object with nonempty owner.login + default_branch strings and
# actual boolean merge/delete fields. Scalar/null/string-bool → ERROR (exit 3).
validate_repo_schema() {
  local body="$1"
  printf '%s' "$body" | jq -e '
    type == "object"
    and (.owner | type == "object")
    and (.owner.login | type == "string" and length > 0)
    and (.default_branch | type == "string" and length > 0)
    and (.allow_squash_merge | type == "boolean")
    and (.allow_merge_commit | type == "boolean")
    and (.allow_rebase_merge | type == "boolean")
    and (.delete_branch_on_merge | type == "boolean")
  ' >/dev/null
}

# Labels: documented array (or paginated array pages). Every item object with
# nonempty name string. Scalar/null/object/wrong items → fail closed.
normalize_labels_pages() {
  # stdin → stdout single JSON array; nonzero if schema fails
  jq -se '
    if length == 0 then
      error("labels: empty response")
    elif all(.[]; type == "array") then
      add
      | if type != "array" then error("labels: pages did not concatenate to array")
        elif any(.[]; type != "object") then error("labels: item is not an object")
        elif any(.[]; (.name | type != "string") or (.name | length < 1)) then
          error("labels: item.name must be a nonempty string")
        else . end
    else
      error("labels: response must be JSON array page(s), not scalar/object/null")
    end
  '
}

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
  if ! validate_repo_schema "$body"; then
    record ERROR "repo" \
      "repos/${REPO} schema invalid — need object with owner.login string, default_branch string, and boolean allow_squash_merge/allow_merge_commit/allow_rebase_merge/delete_branch_on_merge"
    return 1
  fi

  LIVE_DEFAULT_BRANCH=$(printf '%s' "$body" | jq -r '.default_branch')
  LIVE_OWNER_LOGIN=$(printf '%s' "$body" | jq -r '.owner.login')
  # Exact booleans only (schema-enforced) — tostring yields "true"/"false"
  LIVE_SQUASH=$(printf '%s' "$body" | jq -r '.allow_squash_merge | tostring')
  LIVE_MERGE_COMMIT=$(printf '%s' "$body" | jq -r '.allow_merge_commit | tostring')
  LIVE_REBASE=$(printf '%s' "$body" | jq -r '.allow_rebase_merge | tostring')
  LIVE_DELETE_BRANCH=$(printf '%s' "$body" | jq -r '.delete_branch_on_merge | tostring')

  if [[ -n "$LIVE_DEFAULT_BRANCH" && "$DEFAULT_BRANCH" != "$LIVE_DEFAULT_BRANCH" ]]; then
    record OWNER_REQUIRED "default-branch" \
      "configured defaultBranch=$(sq "$DEFAULT_BRANCH") but live default_branch=$(sq "$LIVE_DEFAULT_BRANCH") — owner must align config or repo"
  else
    record PASS "default-branch" "default_branch=$(sq "$LIVE_DEFAULT_BRANCH")"
  fi
  return 0
}

# Label names cache (newline-separated). Populated by fetch_labels.
# IMPORTANT: never capture fetch_labels in $(...) — record() must run in the
# main shell so ERROR tallies/exit codes cannot be swallowed by a subshell.
LABELS_CACHE=""

fetch_labels() {
  # Sets LABELS_CACHE to label names, one per line. Fail closed on schema.
  LABELS_CACHE=""
  local body arr names
  if ! body=$(gh api --paginate "repos/${REPO}/labels" 2>/dev/null); then
    record ERROR "labels" "failed to list labels for ${REPO}"
    return 1
  fi
  # Redirect jq schema diagnostics — surfaced via record ERROR, not stderr noise.
  if ! arr=$(printf '%s' "$body" | normalize_labels_pages 2>/dev/null); then
    record ERROR "labels" \
      "labels API schema invalid — need array page(s) of objects with nonempty string name (scalar/null/object/wrong items rejected)"
    return 1
  fi
  if ! names=$(printf '%s' "$arr" | jq -r '.[].name'); then
    record ERROR "labels" "failed to extract label names after schema validation"
    return 1
  fi
  LABELS_CACHE="$names"
  return 0
}

audit_labels() {
  local missing name
  if ! fetch_labels; then
    return 1
  fi
  missing=""
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! printf '%s\n' "$LABELS_CACHE" | grep -Fx -- "$name" >/dev/null; then
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
  local name color desc body
  if ! fetch_labels; then
    HAD_APPLY_FAILURE=1
    return 1
  fi
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if printf '%s\n' "$LABELS_CACHE" | grep -Fx -- "$name" >/dev/null; then
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
  if ! fetch_labels; then
    HAD_APPLY_FAILURE=1
    return 1
  fi
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! printf '%s\n' "$LABELS_CACHE" | grep -Fx -- "$name" >/dev/null; then
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
  # Re-fetch and strictly validate live merge booleans immediately before mutation.
  local body s m r d
  if ! body=$(gh api "repos/${REPO}" 2>/dev/null); then
    record ERROR "merge" "pre-apply re-fetch of repo settings failed"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  if ! validate_repo_schema "$body"; then
    record ERROR "merge" "pre-apply re-fetch schema invalid (exact boolean merge fields required)"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  s=$(printf '%s' "$body" | jq -r '.allow_squash_merge | tostring')
  m=$(printf '%s' "$body" | jq -r '.allow_merge_commit | tostring')
  r=$(printf '%s' "$body" | jq -r '.allow_rebase_merge | tostring')
  d=$(printf '%s' "$body" | jq -r '.delete_branch_on_merge | tostring')
  LIVE_SQUASH="$s"
  LIVE_MERGE_COMMIT="$m"
  LIVE_REBASE="$r"
  LIVE_DELETE_BRANCH="$d"

  # Already converged → zero PATCH/POST/PUT/DELETE; preserve live state bytes.
  if [[ "$s" == "true" && "$m" == "false" && "$r" == "false" && "$d" == "true" ]]; then
    echo "  apply: merge settings already-converged (zero mutation)"
    record PASS "merge" "already-converged (live merge booleans match desired; zero mutation)"
    return 0
  fi

  # Diff-derived PATCH: only fields that still drift from desired values.
  local -a patch_args=()
  [[ "$s" != "true" ]] && patch_args+=(-F "allow_squash_merge=true")
  [[ "$m" != "false" ]] && patch_args+=(-F "allow_merge_commit=false")
  [[ "$r" != "false" ]] && patch_args+=(-F "allow_rebase_merge=false")
  [[ "$d" != "true" ]] && patch_args+=(-F "delete_branch_on_merge=true")

  if [[ ${#patch_args[@]} -eq 0 ]]; then
    echo "  apply: merge settings already-converged (zero mutation)"
    record PASS "merge" "already-converged (live merge booleans match desired; zero mutation)"
    return 0
  fi

  if ! gh_api --method PATCH "repos/${REPO}" "${patch_args[@]}" \
    >/dev/null 2>&1; then
    echo "  apply: merge settings PATCH failed"
    record ERROR "merge" "PATCH repos/${REPO} merge settings failed"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  # Exact readback/postcondition with the same schema as fetch_repo_meta
  if ! body=$(gh api "repos/${REPO}" 2>/dev/null); then
    echo "  apply: merge settings post-apply readback failed"
    record ERROR "merge" "post-apply readback of repo settings failed"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  if ! validate_repo_schema "$body"; then
    echo "  apply: merge settings post-apply readback schema invalid"
    record ERROR "merge" "post-apply readback schema invalid (exact boolean merge fields required)"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  s=$(printf '%s' "$body" | jq -r '.allow_squash_merge | tostring')
  m=$(printf '%s' "$body" | jq -r '.allow_merge_commit | tostring')
  r=$(printf '%s' "$body" | jq -r '.allow_rebase_merge | tostring')
  d=$(printf '%s' "$body" | jq -r '.delete_branch_on_merge | tostring')
  if [[ "$s" != "true" || "$m" != "false" || "$r" != "false" || "$d" != "true" ]]; then
    echo "  apply: merge settings post-apply postcondition failed: squash=${s} merge_commit=${m} rebase=${r} delete_branch=${d}"
    record ERROR "merge" "post-apply postcondition failed: squash=${s} merge_commit=${m} rebase=${r} delete_branch=${d}"
    HAD_APPLY_FAILURE=1
    return 1
  fi
  LIVE_SQUASH="$s"
  LIVE_MERGE_COMMIT="$m"
  LIVE_REBASE="$r"
  LIVE_DELETE_BRANCH="$d"
  echo "  apply: merge settings applied and verified"
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
    if printf '%s' "$err" | grep -i 'Not Found\|404\|Branch not protected' >/dev/null; then
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

  # Fail closed on types: malformed schema is ERROR, never PASS/OWNER_REQUIRED.
  if ! printf '%s' "$body" | jq -e '
    type == "object"
    and (
      (.enforce_admins | type == "boolean")
      or ((.enforce_admins | type == "object") and (.enforce_admins.enabled | type == "boolean"))
    )
    and (.required_status_checks | type == "object")
    and (.required_status_checks.strict | type == "boolean")
    and (.required_status_checks.contexts | type == "array")
    and all(.required_status_checks.contexts[]; type == "string")
    and (.required_pull_request_reviews | type == "object")
    and (.required_pull_request_reviews.required_approving_review_count | type == "number")
    and (
      (.allow_force_pushes | type == "boolean")
      or ((.allow_force_pushes | type == "object") and (.allow_force_pushes.enabled | type == "boolean"))
      or (.allow_force_pushes == null)
    )
    and (
      (.allow_deletions | type == "boolean")
      or ((.allow_deletions | type == "object") and (.allow_deletions.enabled | type == "boolean"))
      or (.allow_deletions == null)
    )
  ' >/dev/null; then
    record ERROR "protection.${role}" \
      "protection schema invalid for $(sq "$branch") — malformed types cannot contribute PASS/READY"
    return 1
  fi

  local enforce strict reviews force delete contexts_json
  enforce=$(printf '%s' "$body" | jq -r 'if .enforce_admins|type=="object" then .enforce_admins.enabled|tostring else .enforce_admins|tostring end')
  strict=$(printf '%s' "$body" | jq -r '.required_status_checks.strict|tostring')
  reviews=$(printf '%s' "$body" | jq -r '.required_pull_request_reviews.required_approving_review_count|floor|tostring')
  force=$(printf '%s' "$body" | jq -r 'if .allow_force_pushes == null then "false" elif .allow_force_pushes|type=="object" then .allow_force_pushes.enabled|tostring else .allow_force_pushes|tostring end')
  delete=$(printf '%s' "$body" | jq -r 'if .allow_deletions == null then "false" elif .allow_deletions|type=="object" then .allow_deletions.enabled|tostring else .allow_deletions|tostring end')
  contexts_json=$(printf '%s' "$body" | jq -c '.required_status_checks.contexts')

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
  local ctx
  while IFS= read -r ctx; do
    [[ -z "$ctx" ]] && continue
    if ! printf '%s' "$contexts_json" | jq -e --arg c "$ctx" 'index($c) != null' >/dev/null; then
      problems="${problems}missing context $(sq "$ctx"); "
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
  # Report-only. PASS requires exact required_reviewers rule with ≥1 valid
  # reviewer AND can_admins_bypass exactly false. Wait-timer-only / bypassable
  # / missing → OWNER_REQUIRED. Malformed types → ERROR (never PASS/READY).
  if [[ -z "$PROD_ENV" ]]; then
    record PASS "environment" "productionEnvironment null/skipped by config"
    return 0
  fi
  local body errfile
  errfile=$(mktemp)
  if ! body=$(gh api "repos/${REPO}/environments/$(printf '%s' "$PROD_ENV" | sed 's/ /%20/g')" 2>"$errfile"); then
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
  if ! printf '%s' "$body" | jq -e '
    type == "object"
    and (.protection_rules | type == "array")
    and (.can_admins_bypass | type == "boolean")
  ' >/dev/null; then
    record ERROR "environment" \
      "environment schema invalid — need object with protection_rules array and boolean can_admins_bypass (malformed cannot PASS/READY)"
    return 1
  fi

  # Validate each rule shape enough to refuse junk types contributing to PASS.
  if ! printf '%s' "$body" | jq -e '
    all(.protection_rules[]; type == "object" and (.type | type == "string"))
  ' >/dev/null; then
    record ERROR "environment" \
      "environment protection_rules items must be objects with string type"
    return 1
  fi

  local bypass has_rr rr_ok
  bypass=$(printf '%s' "$body" | jq -r '.can_admins_bypass | tostring')
  # required_reviewers with at least one valid reviewer (login string or id number)
  has_rr=$(printf '%s' "$body" | jq -r '
    [.protection_rules[] | select(.type == "required_reviewers")] | length | tostring
  ')
  rr_ok=$(printf '%s' "$body" | jq -r '
    [
      .protection_rules[]
      | select(.type == "required_reviewers")
      | select(
          (.reviewers | type == "array")
          and (.reviewers | length > 0)
          and all(.reviewers[];
            type == "object"
            and (
              ((.login | type == "string") and (.login | length > 0))
              or (.id | type == "number")
            )
          )
        )
    ] | length | tostring
  ')

  if [[ "$has_rr" == "0" ]]; then
    record OWNER_REQUIRED "environment" \
      "environment $(sq "$PROD_ENV") lacks required_reviewers protection rule (wait-timer-only or empty rules are not enough) — Mark-owned; not applied here"
    plan_line "OWNER: scripts/delivery-control/apply-production-env.sh --repo $(sq "$REPO") --apply"
    return 0
  fi
  if [[ "$rr_ok" == "0" ]]; then
    record OWNER_REQUIRED "environment" \
      "environment $(sq "$PROD_ENV") required_reviewers rule has no valid reviewer entries — owner must add ≥1 reviewer"
    plan_line "OWNER: scripts/delivery-control/apply-production-env.sh --repo $(sq "$REPO") --apply"
    return 0
  fi
  if [[ "$bypass" != "false" ]]; then
    record OWNER_REQUIRED "environment" \
      "environment $(sq "$PROD_ENV") can_admins_bypass=$(sq "$bypass") (want false) — admin bypass is not PASS"
    plan_line "OWNER: scripts/delivery-control/apply-production-env.sh --repo $(sq "$REPO") --apply"
    return 0
  fi
  record PASS "environment" \
    "environment $(sq "$PROD_ENV") has required_reviewers (≥1 valid) and can_admins_bypass=false"
  return 0
}

audit_dco() {
  # Report-only. Static workflow names/text are static presence only — never
  # live enforcement. PASS only after live Actions run + exact DCO check-run
  # validation via gh (read-only). Never call or install the DCO app.
  local static=0
  if [[ -d "${LOCAL_PATH}/.github/workflows" ]]; then
    if grep -Rqi -- 'dco\|signed-off-by\|probot/dco' "${LOCAL_PATH}/.github/workflows" 2>/dev/null; then
      static=1
    fi
  fi

  local observed="${GIBSON_DCO_OBSERVED_RUN:-}"
  local run_id="" vr=0

  if [[ -n "$observed" ]]; then
    if ! run_id=$(parse_actions_run_url "$observed"); then
      record UNKNOWN "dco" \
        "GIBSON_DCO_OBSERVED_RUN set but does not match strict observed-run contract (exact https://github.com/${REPO}/actions/runs/<id> only; observed-run: tokens and other hosts/paths/queries rejected) — arbitrary nonempty strings are insufficient"
      plan_line "OWNER: export GIBSON_DCO_OBSERVED_RUN=https://github.com/${REPO}/actions/runs/<id> after a real completed DCO check"
      return 0
    fi
    vr=0
    verify_live_actions_check "$run_id" "DCO" || vr=$?
    if [[ "$vr" -eq 0 ]]; then
      record PASS "dco" \
        "live Actions run ${run_id} completed/success with exact check DCO on head_sha (static workflow text alone never clears this; app install remains Mark-owned; never applied)"
      return 0
    fi
    if [[ "$vr" -eq 2 ]]; then
      record ERROR "dco" \
        "failed to fetch/validate Actions run ${run_id} or its check-runs via gh (API/schema error) — never PASS on synthetic/static evidence"
      return 0
    fi
    record UNKNOWN "dco" \
      "GIBSON_DCO_OBSERVED_RUN points at run ${run_id} but live evidence is not PASS-worthy (wrong repo/id/SHA/status/conclusion, missing/duplicate/unsuccessful exact check name DCO, or malformed payload) — never READY on synthetic attestation"
    plan_line "OWNER: re-export GIBSON_DCO_OBSERVED_RUN after a completed successful Actions run where exact check DCO is completed/success"
    return 0
  fi

  if [[ "$static" -eq 1 ]]; then
    record OWNER_REQUIRED "dco" \
      "static DCO-related workflow text present only — static names/echo steps are never live enforcement; OWNER_REQUIRED until observed exact-run evidence (never applied by this script)"
    plan_line "OWNER: install DCO app or required DCO check; export GIBSON_DCO_OBSERVED_RUN=https://github.com/${REPO}/actions/runs/<id> after a real run"
  else
    record OWNER_REQUIRED "dco" \
      "no observed DCO run attestation and no static DCO workflow text — owner installs DCO app/check if org requires sign-off (not applied by this script)"
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
    if printf '%s\n' "$installed_names" | grep -Fi -- "$ctx" >/dev/null; then
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
  # Only a live-validated Actions run + exact check name may PASS.
  if printf '%s\n' "$REQUIRED_CONTEXTS_NL" | grep -Fx -- "test-integrity" >/dev/null \
    || printf '%s\n' "$installed_names" | grep -Fi -- "test-integrity" >/dev/null; then
    local ti_obs="${GIBSON_TEST_INTEGRITY_OBSERVED_RUN:-}"
    local ti_id="" ti_vr=0
    if [[ -n "$ti_obs" ]]; then
      if ! ti_id=$(parse_actions_run_url "$ti_obs"); then
        record UNKNOWN "test-integrity-canary" \
          "GIBSON_TEST_INTEGRITY_OBSERVED_RUN present but fails strict observed-run contract (exact https://github.com/${REPO}/actions/runs/<id> only; observed-run: tokens and other hosts/paths/queries rejected) — arbitrary nonempty strings are insufficient; static YAML never PASS"
        plan_line "OWNER: re-export GIBSON_TEST_INTEGRITY_OBSERVED_RUN=https://github.com/${REPO}/actions/runs/<id> after canaries; require exact check name test-integrity"
      else
        ti_vr=0
        verify_live_actions_check "$ti_id" "test-integrity" || ti_vr=$?
        if [[ "$ti_vr" -eq 0 ]]; then
          record PASS "test-integrity-canary" \
            "live Actions run ${ti_id} completed/success with exact check test-integrity — static YAML alone never clears this gate"
        elif [[ "$ti_vr" -eq 2 ]]; then
          record ERROR "test-integrity-canary" \
            "failed to fetch/validate Actions run ${ti_id} or its check-runs via gh (API/schema error) — never canary PASS from YAML or synthetic attestation"
        else
          record UNKNOWN "test-integrity-canary" \
            "GIBSON_TEST_INTEGRITY_OBSERVED_RUN points at run ${ti_id} but live evidence is not PASS-worthy (wrong repo/id/SHA/status/conclusion, missing/duplicate/unsuccessful exact check name test-integrity, or malformed payload) — static YAML never PASS"
          plan_line "OWNER: re-export GIBSON_TEST_INTEGRITY_OBSERVED_RUN after a completed successful run where exact check test-integrity is completed/success"
        fi
      fi
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

  # Validate local path early — refuse symlink checkout roots (report escape / purity).
  if [[ -L "$LOCAL_PATH" ]]; then
    die_usage "local --path must not be a symlink (refuse checkout root link): $LOCAL_PATH"
  fi
  if [[ ! -d "$LOCAL_PATH" ]]; then
    die_usage "local --path is not a directory: $LOCAL_PATH"
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

  # No implicit report path. Default audit/default invocation write ZERO files.
  # --report PATH is the only request for a local report write (not in dry-run).
  if [[ "$NO_REPORT" -eq 1 ]]; then
    REPORT_PATH=""
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

  # Report write: only explicit --report PATH, never in --dry-run, never default.
  if [[ -n "$REPORT_PATH" ]]; then
    if [[ "$MODE" == "dry-run" ]]; then
      echo ""
      echo "## Report (dry-run — not written; stdout/plan only; target bytes preserved)"
      echo "  (skipped write of $(sq "$REPORT_PATH"))"
    else
      echo ""
      echo "Writing report: ${REPORT_PATH}"
      local report_body
      report_body=$(build_report_body)
      atomic_write_report "$REPORT_PATH" "$report_body"
      echo "  report written."
    fi
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
