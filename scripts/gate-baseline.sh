#!/usr/bin/env bash
# gate-baseline.sh — record branch-point failure counts (docs/06)
set -euo pipefail

usage() {
  cat <<'EOF'
gate-baseline.sh — snapshot green-gate failure counts at branch point

WHAT IT DOES
  Runs the target repo's generate/typecheck/lint/test/build commands (from
  .agents/gate.json, package.json scripts, or env overrides) and writes
  .gibson-baseline.json with failure counts / exit codes.

WHY
  The green gate is "zero NEW failures vs. branch point" (docs/06). Without a
  baseline, pre-existing red on main becomes either inherited guilt or an excuse.

RISKS
  - Runs full gate commands (can take minutes; may need network for some tests).
  - Writes .gibson-baseline.json (should be gitignored or worktree-local).
  - Does not modify product source.

USAGE
  gate-baseline.sh [--out FILE]
  gate-baseline.sh --help

ENV / config (first match wins per step)
  GIBSON_GENERATE, GIBSON_TYPECHECK, GIBSON_LINT, GIBSON_TEST, GIBSON_BUILD
  or .agents/gate.json (legacy: .gibson-gate.json):
    { "generate": "...", "typecheck": "...", "lint": "...", "test": "...", "build": "..." }
    (a top-level "gate" object is also read, so the file can carry other keys)

EXAMPLES
  cd ../wt-42-password-reset
  /path/to/the-gibson/scripts/gate-baseline.sh
  cat .gibson-baseline.json
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

OUT=".gibson-baseline.json"
if [[ "${1:-}" == "--out" ]]; then
  OUT="${2:?--out requires a path}"
fi

die() { echo "gate-baseline.sh: ERROR: $*" >&2; exit 1; }
info() { echo "gate-baseline.sh: $*" >&2; }

SKIP_SENTINEL='__gate_step_not_applicable__'

# Resolve command for a step
resolve_cmd() {
  local step="$1"
  local env_var="$2"
  local npm_script="$3"
  local val="${!env_var:-}"
  if [[ -n "$val" ]]; then
    echo "$val"
    return
  fi
  # .agents/gate.json first: the vendor-neutral contract the target repo
  # publishes (docs/13). .gibson-gate.json stays supported for older adoptions.
  local cfg
  for cfg in .agents/gate.json .gibson-gate.json; do
    if [[ -f "$cfg" ]] && command -v node >/dev/null; then
      local from_json
      # A present-but-empty key means "this step does not apply here" and must
      # stop the chain — otherwise it would fall through to package.json or the
      # defaults and run something the repo explicitly opted out of.
      from_json=$(node -e "try{const j=require('./$cfg');const g=j.gate||j;if(Object.prototype.hasOwnProperty.call(g,'$step')){const v=String(g['$step']??'').trim();process.stdout.write(v===''?'$SKIP_SENTINEL':v)}}catch(e){}" 2>/dev/null || true)
      if [[ "$from_json" == "$SKIP_SENTINEL" ]]; then
        echo ""
        return
      fi
      if [[ -n "$from_json" ]]; then
        echo "$from_json"
        return
      fi
    fi
  done
  if [[ -f package.json ]] && command -v node >/dev/null; then
    local has
    has=$(node -e "const p=require('./package.json');process.exit(p.scripts&&p.scripts['$npm_script']?0:1)" 2>/dev/null && echo yes || echo no)
    if [[ "$has" == "yes" ]]; then
      echo "npm run $npm_script"
      return
    fi
  fi
  # sensible defaults
  case "$step" in
    generate) echo "" ;; # optional
    typecheck) echo "npx tsc --noEmit" ;;
    lint) echo "npm run lint" ;;
    test) echo "npm test -- --run" ;;
    build) echo "npm run build" ;;
  esac
}

run_count_failures() {
  local step="$1"
  local cmd="$2"
  if [[ -z "$cmd" ]]; then
    echo 0
    return
  fi
  info "baseline $step: $cmd"
  set +e
  # shellcheck disable=SC2086
  out=$(eval "$cmd" 2>&1)
  ec=$?
  set -e
  # Count error-ish lines as a rough fingerprint; also store exit code
  # Prefer exit code as primary signal; failure_count is secondary detail
  if [[ $ec -ne 0 ]]; then
    # count lines with error/fail patterns
    fc=$(echo "$out" | grep -ciE 'error TS|error:|FAIL|failed|✖|×' || true)
    [[ "$fc" -eq 0 ]] && fc=1
    echo "$fc"
  else
    echo 0
  fi
  # stash exit in global via files
  echo "$ec" > ".gibson-baseline.$step.ec"
}

GEN=$(resolve_cmd generate GIBSON_GENERATE generate)
TC=$(resolve_cmd typecheck GIBSON_TYPECHECK typecheck)
LI=$(resolve_cmd lint GIBSON_LINT lint)
TE=$(resolve_cmd test GIBSON_TEST test)
BU=$(resolve_cmd build GIBSON_BUILD build)

# Optional generate first (prisma etc.)
if [[ -n "$GEN" ]]; then
  info "running generate: $GEN"
  set +e
  eval "$GEN" >/dev/null 2>&1
  set -e
fi

fc_tc=$(run_count_failures typecheck "$TC")
ec_tc=$(cat .gibson-baseline.typecheck.ec 2>/dev/null || echo 0)
fc_li=$(run_count_failures lint "$LI")
ec_li=$(cat .gibson-baseline.lint.ec 2>/dev/null || echo 0)
fc_te=$(run_count_failures test "$TE")
ec_te=$(cat .gibson-baseline.test.ec 2>/dev/null || echo 0)
fc_bu=$(run_count_failures build "$BU")
ec_bu=$(cat .gibson-baseline.build.ec 2>/dev/null || echo 0)

rm -f .gibson-baseline.typecheck.ec .gibson-baseline.lint.ec .gibson-baseline.test.ec .gibson-baseline.build.ec

UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SHA=$(git rev-parse HEAD 2>/dev/null || echo unknown)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)

# Write JSON without requiring jq
cat > "$OUT" <<EOF
{
  "recorded_at": "$UTC",
  "git_sha": "$SHA",
  "branch": "$BRANCH",
  "commands": {
    "generate": $(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$GEN"),
    "typecheck": $(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$TC"),
    "lint": $(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$LI"),
    "test": $(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$TE"),
    "build": $(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$BU")
  },
  "failures": {
    "typecheck": $fc_tc,
    "lint": $fc_li,
    "test": $fc_te,
    "build": $fc_bu
  },
  "exit_codes": {
    "typecheck": $ec_tc,
    "lint": $ec_li,
    "test": $ec_te,
    "build": $ec_bu
  }
}
EOF

info "wrote $OUT"
cat "$OUT"
