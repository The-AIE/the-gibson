#!/usr/bin/env bash
# gate.sh — green gate vs. baseline (docs/06) + test-integrity (issue #70)
set -euo pipefail

usage() {
  cat <<'EOF'
gate.sh — run the green gate; fail on NEW failures vs. baseline

WHAT IT DOES
  Runs generate → typecheck → lint → test → build using the same command
  resolution as gate-baseline.sh, compares failure counts / exit codes to
  .gibson-baseline.json, and exits non-zero if any step is newly red or
  has more failures than baseline.

  After the test step it also runs the test-integrity sensor (issue #70):
  a drop in test total or a rise in skip/todo vs the baseline hard-fails
  with a `test-integrity` diagnosis and the exact delta, unless a visible
  exact waiver is supplied via GIBSON_TEST_INTEGRITY_TEXT / --waiver-text /
  --waiver-file. PR/commit text is inert data — never evaluated as code.

WHY
  The green gate is absolute (Law 4). CI re-runs the same idea vendor-blind;
  this script is the local courtesy that keeps iteration honest. Test-
  integrity closes the "delete the failing test" bypass.

RISKS
  - Long runtime on large test suites.
  - Without a baseline file, any non-zero exit fails the gate (strict mode).
  - Local .gibson-baseline.json is worktree-local and gitignored — CI must
    anchor to the merge base / trusted base (see ci/gibson-gate.yml), never
    to a baseline the PR can rewrite.
  - Does not modify source; may create caches/build artifacts.

USAGE
  gate.sh [--baseline FILE] [--no-baseline-ok]
          [--waiver-text STR | --waiver-file FILE]
  gate.sh --help

  --baseline FILE     path to baseline JSON (default: .gibson-baseline.json)
  --no-baseline-ok    if baseline missing, only require all steps exit 0
  --waiver-text STR   inert waiver text (usually the PR body)
  --waiver-file FILE  read inert waiver text from FILE

ENV
  GIBSON_TEST_INTEGRITY_TEXT   inert waiver text (PR body / commit message).
                               Same as --waiver-text; flag wins if both set.

EXAMPLES
  gate-baseline.sh
  # ... edit ...
  gate.sh && git commit -s -m "feat: ..."

  GIBSON_TEST_INTEGRITY_TEXT='Test-integrity: removed 2 for obsolete fixtures' \
    gate.sh
EOF
}

BASELINE=".gibson-baseline.json"
NO_BASELINE_OK=0
WAIVER_TEXT="${GIBSON_TEST_INTEGRITY_TEXT:-}"
WAIVER_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --baseline) BASELINE="${2:?}"; shift 2 ;;
    --no-baseline-ok) NO_BASELINE_OK=1; shift ;;
    --waiver-text) WAIVER_TEXT="${2-}"; shift 2 ;;
    --waiver-file) WAIVER_FILE="${2:?}"; shift 2 ;;
    *) echo "unknown: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -n "$WAIVER_FILE" ]]; then
  WAIVER_TEXT=$(cat -- "$WAIVER_FILE")
fi

die() { echo "gate.sh: ERROR: $*" >&2; exit 1; }
info() { echo "gate.sh: $*" >&2; }
fail() { echo "gate.sh: FAIL: $*" >&2; FAILED=1; }
FAILED=0

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
TI="$SCRIPT_DIR/test-integrity.mjs"

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
    from_b=$(node -e "const fs=require('fs');try{const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));if(j.commands&&j.commands[process.argv[2]])process.stdout.write(j.commands[process.argv[2]])}catch(e){}" "$BASELINE" "$step" 2>/dev/null || true)
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
  # Path via argv — BASELINE may be absolute; never shell-interpolate into require()
  node -e "const fs=require('fs');try{const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(String((j.failures&&j.failures[process.argv[2]])||0))}catch(e){process.stdout.write('0')}" "$BASELINE" "$step"
}

baseline_ec() {
  local step="$1"
  if [[ ! -f "$BASELINE" ]]; then echo 0; return; fi
  node -e "const fs=require('fs');try{const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(String((j.exit_codes&&j.exit_codes[process.argv[2]])||0))}catch(e){process.stdout.write('0')}" "$BASELINE" "$step"
}

if [[ ! -f "$BASELINE" && "$NO_BASELINE_OK" -eq 0 ]]; then
  info "no $BASELINE — strict mode: all steps must exit 0 (run gate-baseline.sh first)"
fi

GEN=$(resolve_cmd generate GIBSON_GENERATE generate)
if [[ -n "$GEN" ]]; then
  info "generate: $GEN"
  eval "$GEN" || die "generate failed"
fi

# Captured test runner output for the integrity sensor (issue #70)
TEST_STEP_OUT=""
TEST_STEP_RAN=0

run_step() {
  local step="$1"
  local cmd="$2"
  [[ -z "$cmd" ]] && return 0
  info "$step: $cmd"
  set +e
  out=$(eval "$cmd" 2>&1)
  ec=$?
  set -e
  if [[ "$step" == "test" ]]; then
    TEST_STEP_OUT=$out
    TEST_STEP_RAN=1
  fi
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

# --- test-integrity (issue #70) ----------------------------------------------
# Runs even when earlier steps failed so the diagnosis is complete, but only
# when we have both a baseline with test_metrics and a test step that ran.
if [[ "$TEST_STEP_RAN" -eq 1 && -f "$BASELINE" && -f "$TI" ]] && command -v node >/dev/null; then
  set +e
  node -e "const fs=require('fs');const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.exit(j.test_metrics&&j.test_metrics.total!==undefined&&j.test_metrics.total!==null?0:1)" "$BASELINE" 2>/dev/null
  has_rc=$?
  set -e
  if [[ $has_rc -ne 0 ]]; then
    fail "test-integrity: baseline $BASELINE lacks test_metrics — re-run gate-baseline.sh"
  else
    HEAD_METRICS=$(mktemp "${TMPDIR:-/tmp}/gibson-head-metrics.XXXXXX")
    WAIVER_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-waiver.XXXXXX")
    # Write runner output and waiver as files — never pass through eval/shell
    printf '%s\n' "$TEST_STEP_OUT" > "${HEAD_METRICS}.out"
    # Prefer parsing to a metrics JSON; fail closed if unparseable
    set +e
    node "$TI" parse --input "${HEAD_METRICS}.out" --out "$HEAD_METRICS" 2>"${HEAD_METRICS}.err"
    parse_rc=$?
    set -e
    if [[ $parse_rc -ne 0 ]]; then
      cat "${HEAD_METRICS}.err" >&2 || true
      fail "test-integrity: could not parse test metrics from runner output (fail closed)"
    else
      printf '%s' "$WAIVER_TEXT" > "$WAIVER_TMP"
      set +e
      ti_out=$(node "$TI" compare \
        --base "$BASELINE" \
        --head "$HEAD_METRICS" \
        --waiver-file "$WAIVER_TMP" \
        --trusted-source "local-baseline(${BASELINE})" 2>&1)
      ti_rc=$?
      set -e
      # Always surface the sensor output (includes WAIVER accepted lines for reviewers)
      echo "$ti_out" >&2
      if [[ $ti_rc -ne 0 ]]; then
        fail "test-integrity: suite reduced or skips inflated without an exact visible waiver"
      else
        info "test-integrity OK"
      fi
    fi
    rm -f "$HEAD_METRICS" "${HEAD_METRICS}.out" "${HEAD_METRICS}.err" "$WAIVER_TMP"
  fi
elif [[ "$TEST_STEP_RAN" -eq 1 && -f "$BASELINE" && ! -f "$TI" ]]; then
  fail "test-integrity: scripts/test-integrity.mjs missing — cannot verify suite size"
fi

if [[ "$FAILED" -ne 0 ]]; then
  die "green gate failed — fix new failures before commit"
fi
info "GREEN — zero new failures vs. baseline"
exit 0
