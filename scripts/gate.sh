#!/usr/bin/env bash
# gate.sh — green gate vs. baseline (docs/06)
set -euo pipefail

usage() {
  cat <<'EOF'
gate.sh — run the green gate; fail on NEW failures vs. baseline

WHAT IT DOES
  Runs generate → typecheck → lint → test → build using the same command
  resolution as gate-baseline.sh, compares failure counts / exit codes to
  .gibson-baseline.json, and exits non-zero if any step is newly red or
  has more failures than baseline.

WHY
  The green gate is absolute (Law 4). CI re-runs the same idea vendor-blind;
  this script is the local courtesy that keeps iteration honest.

RISKS
  - Long runtime on large test suites.
  - Without a baseline file, any non-zero exit fails the gate (strict mode).
  - Does not modify source; may create caches/build artifacts.

USAGE
  gate.sh [--baseline FILE] [--no-baseline-ok]
  gate.sh --help

  --baseline FILE     path to baseline JSON (default: .gibson-baseline.json)
  --no-baseline-ok    if baseline missing, only require all steps exit 0

EXAMPLES
  gate-baseline.sh
  # ... edit ...
  gate.sh && git commit -s -m "feat: ..."
EOF
}

BASELINE=".gibson-baseline.json"
NO_BASELINE_OK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --baseline) BASELINE="${2:?}"; shift 2 ;;
    --no-baseline-ok) NO_BASELINE_OK=1; shift ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "gate.sh: ERROR: $*" >&2; exit 1; }
info() { echo "gate.sh: $*" >&2; }
fail() { echo "gate.sh: FAIL: $*" >&2; FAILED=1; }
FAILED=0

SKIP_SENTINEL='__gate_step_not_applicable__'

resolve_cmd() {
  local step="$1"
  local env_var="$2"
  local npm_script="$3"
  local val="${!env_var:-}"
  if [[ -n "$val" ]]; then echo "$val"; return; fi
  # .agents/gate.json is the vendor-neutral contract (docs/13): the target repo
  # publishes its gate, no harness named. .gibson-gate.json stays supported for
  # repos adopted before the split.
  local cfg
  for cfg in .agents/gate.json .gibson-gate.json; do
    if [[ -f "$cfg" ]] && command -v node >/dev/null; then
      local from_json
      # A present-but-empty key means "this step does not apply here" and must
      # stop the chain — otherwise it would fall through to package.json or the
      # defaults and run something the repo explicitly opted out of.
      from_json=$(node -e "try{const j=require('./$cfg');const g=j.gate||j;if(Object.prototype.hasOwnProperty.call(g,'$step')){const v=String(g['$step']??'').trim();process.stdout.write(v===''?'$SKIP_SENTINEL':v)}}catch(e){}" 2>/dev/null || true)
      if [[ "$from_json" == "$SKIP_SENTINEL" ]]; then echo ""; return; fi
      if [[ -n "$from_json" ]]; then echo "$from_json"; return; fi
    fi
  done
  if [[ -f "$BASELINE" ]] && command -v node >/dev/null; then
    local from_b
    from_b=$(node -e "try{const j=require('./$BASELINE');if(j.commands&&j.commands['$step'])process.stdout.write(j.commands['$step'])}catch(e){}" 2>/dev/null || true)
    if [[ -n "$from_b" ]]; then echo "$from_b"; return; fi
  fi
  if [[ -f package.json ]] && command -v node >/dev/null; then
    if node -e "const p=require('./package.json');process.exit(p.scripts&&p.scripts['$npm_script']?0:1)" 2>/dev/null; then
      echo "npm run $npm_script"; return
    fi
  fi
  case "$step" in
    generate) echo "" ;;
    typecheck) echo "npx tsc --noEmit" ;;
    lint) echo "npm run lint" ;;
    test) echo "npm test -- --run" ;;
    build) echo "npm run build" ;;
  esac
}

baseline_failures() {
  local step="$1"
  if [[ ! -f "$BASELINE" ]]; then echo 0; return; fi
  node -e "try{const j=require('./$BASELINE');process.stdout.write(String((j.failures&&j.failures['$step'])||0))}catch(e){process.stdout.write('0')}"
}

baseline_ec() {
  local step="$1"
  if [[ ! -f "$BASELINE" ]]; then echo 0; return; fi
  node -e "try{const j=require('./$BASELINE');process.stdout.write(String((j.exit_codes&&j.exit_codes['$step'])||0))}catch(e){process.stdout.write('0')}"
}

if [[ ! -f "$BASELINE" && "$NO_BASELINE_OK" -eq 0 ]]; then
  info "no $BASELINE — strict mode: all steps must exit 0 (run gate-baseline.sh first)"
fi

GEN=$(resolve_cmd generate GIBSON_GENERATE generate)
if [[ -n "$GEN" ]]; then
  info "generate: $GEN"
  eval "$GEN" || die "generate failed"
fi

run_step() {
  local step="$1"
  local cmd="$2"
  [[ -z "$cmd" ]] && return 0
  info "$step: $cmd"
  set +e
  out=$(eval "$cmd" 2>&1)
  ec=$?
  set -e
  fc=0
  if [[ $ec -ne 0 ]]; then
    fc=$(echo "$out" | grep -ciE 'error TS|error:|FAIL|failed|✖|×' || true)
    [[ "$fc" -eq 0 ]] && fc=1
  fi
  b_fc=$(baseline_failures "$step")
  b_ec=$(baseline_ec "$step")

  if [[ ! -f "$BASELINE" ]]; then
    if [[ $ec -ne 0 ]]; then
      echo "$out" | tail -n 40
      fail "$step exit $ec (no baseline)"
    else
      info "$step OK"
    fi
    return
  fi

  # New failure: was green (ec0), now red
  if [[ "$b_ec" -eq 0 && $ec -ne 0 ]]; then
    echo "$out" | tail -n 40
    fail "$step newly failing (baseline was green)"
    return
  fi
  # More failures than baseline
  if [[ "$fc" -gt "$b_fc" ]]; then
    echo "$out" | tail -n 40
    fail "$step failures $fc > baseline $b_fc"
    return
  fi
  # Still red but not worse — allowed (pre-existing)
  if [[ $ec -ne 0 ]]; then
    info "$step still red but within baseline (fc=$fc <= $b_fc)"
  else
    info "$step OK"
  fi
}

run_step typecheck "$(resolve_cmd typecheck GIBSON_TYPECHECK typecheck)"
run_step lint "$(resolve_cmd lint GIBSON_LINT lint)"
run_step test "$(resolve_cmd test GIBSON_TEST test)"
run_step build "$(resolve_cmd build GIBSON_BUILD build)"

if [[ "$FAILED" -ne 0 ]]; then
  die "green gate failed — fix new failures before commit"
fi
info "GREEN — zero new failures vs. baseline"
exit 0
