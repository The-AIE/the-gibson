#!/usr/bin/env bash
# gate-baseline.sh — record branch-point failure counts + test metrics (docs/06)
set -euo pipefail

usage() {
  cat <<'EOF'
gate-baseline.sh — snapshot green-gate failure counts at branch point

WHAT IT DOES
  Runs the target repo's generate/typecheck/lint/test/build commands (from
  .agents/gate.json, package.json scripts, or env overrides) and writes
  .gibson-baseline.json with failure counts / exit codes AND test-suite
  metrics (total / skipped / todo) for the test-integrity sensor (issue #70).

WHY
  The green gate is "zero NEW failures vs. branch point" (docs/06). Without a
  baseline, pre-existing red on main becomes either inherited guilt or an excuse.
  Test metrics close the bypass where deleting or .skip-ing tests goes green.

RISKS
  - Runs full gate commands (can take minutes; may need network for some tests).
  - Writes .gibson-baseline.json (gitignored / worktree-local — NOT a CI authority).
  - Intentional suite reductions require --regenerate --reason and append a
    journal line under .gibson/test-integrity-journal.jsonl.
  - Does not modify product source.

USAGE
  gate-baseline.sh [--out FILE] [--regenerate --reason TEXT] [--journal FILE]
  gate-baseline.sh --help

  --out FILE          baseline path (default: .gibson-baseline.json)
  --regenerate        allow writing a baseline whose test total drops or whose
                      skip/todo rises vs the existing file
  --reason TEXT       required with --regenerate when integrity metrics worsen;
                      nonempty human-readable reason (appended to the journal)
  --journal FILE      journal path (default: .gibson/test-integrity-journal.jsonl)

ENV / config (first match wins per step)
  GIBSON_GENERATE, GIBSON_TYPECHECK, GIBSON_LINT, GIBSON_TEST, GIBSON_BUILD
  or .agents/gate.json (legacy: .gibson-gate.json):
    { "generate": "...", "typecheck": "...", "lint": "...", "test": "...", "build": "..." }
    (a top-level "gate" object is also read, so the file can carry other keys)

EXAMPLES
  cd ../wt-42-password-reset
  /path/to/the-gibson/scripts/gate-baseline.sh
  cat .gibson-baseline.json

  # Legitimate suite reduction (journaled):
  gate-baseline.sh --regenerate --reason "removed obsolete flaky suite after #70"
EOF
}

OUT=".gibson-baseline.json"
REGENERATE=0
REASON=""
REASON_SET=0
JOURNAL=".gibson/test-integrity-journal.jsonl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) OUT="${2:?--out requires a path}"; shift 2 ;;
    --regenerate) REGENERATE=1; shift ;;
    --reason) REASON="${2-}"; REASON_SET=1; shift 2 ;;
    --journal) JOURNAL="${2:?--journal requires a path}"; shift 2 ;;
    *) echo "gate-baseline.sh: unknown: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "gate-baseline.sh: ERROR: $*" >&2; exit 1; }
info() { echo "gate-baseline.sh: $*" >&2; }

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
TI="$SCRIPT_DIR/test-integrity.mjs"
command -v node >/dev/null || die "node is required"

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
  # Stash full output for the test step (metrics parsing)
  if [[ "$step" == "test" ]]; then
    printf '%s\n' "$out" > ".gibson-baseline.test.out"
  fi
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

rm -f .gibson-baseline.test.out

fc_tc=$(run_count_failures typecheck "$TC")
ec_tc=$(cat .gibson-baseline.typecheck.ec 2>/dev/null || echo 0)
fc_li=$(run_count_failures lint "$LI")
ec_li=$(cat .gibson-baseline.lint.ec 2>/dev/null || echo 0)
fc_te=$(run_count_failures test "$TE")
ec_te=$(cat .gibson-baseline.test.ec 2>/dev/null || echo 0)
fc_bu=$(run_count_failures build "$BU")
ec_bu=$(cat .gibson-baseline.build.ec 2>/dev/null || echo 0)

# --- test metrics (issue #70) -------------------------------------------------
TEST_METRICS_JSON='null'
TEST_METRICS_PRESENT=0
if [[ -n "$TE" && -f .gibson-baseline.test.out ]]; then
  set +e
  parsed=$(node "$TI" parse --input .gibson-baseline.test.out 2>/tmp/gibson-ti-parse.err)
  parse_rc=$?
  set -e
  if [[ $parse_rc -ne 0 ]]; then
    # Fail closed: a test step that produces no parseable metrics cannot
    # establish a trustworthy baseline for the integrity sensor.
    cat /tmp/gibson-ti-parse.err >&2 || true
    rm -f .gibson-baseline.typecheck.ec .gibson-baseline.lint.ec \
      .gibson-baseline.test.ec .gibson-baseline.build.ec .gibson-baseline.test.out
    die "test step produced unparseable metrics (fail closed). Emit GIBSON_TEST_METRICS or a supported summary (docs/06)."
  fi
  TEST_METRICS_JSON=$parsed
  TEST_METRICS_PRESENT=1
fi

# Integrity-reduction guard: lowering total or raising skip/todo requires an
# explicit --regenerate --reason and a journal entry.
if [[ -f "$OUT" && "$TEST_METRICS_PRESENT" -eq 1 ]]; then
  OLD_METRICS_FILE=$(mktemp "${TMPDIR:-/tmp}/gibson-old-metrics.XXXXXX")
  NEW_METRICS_FILE=$(mktemp "${TMPDIR:-/tmp}/gibson-new-metrics.XXXXXX")
  printf '%s\n' "$TEST_METRICS_JSON" > "$NEW_METRICS_FILE"
  # Extract prior test_metrics if present; missing metrics counts as needing regenerate
  set +e
  node -e "
    const fs=require('fs');
    const b=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
    if(!b.test_metrics){process.exit(2)}
    fs.writeFileSync(process.argv[2], JSON.stringify(b.test_metrics));
  " "$OUT" "$OLD_METRICS_FILE"
  extract_rc=$?
  set -e

  needs=0
  if [[ $extract_rc -eq 2 ]]; then
    needs=1
    # Fabricate a high watermark so the journal has something to compare
    echo '{"total":0,"skipped":0,"todo":0}' > "$OLD_METRICS_FILE"
    # Re-read: if old had no metrics, overwriting with real metrics is an upgrade
    # only when we can confirm no reduction — without old numbers, require regenerate
    # when the operator is intentionally establishing integrity for the first time
    # on top of a legacy baseline. Improvement path: still allow without flag when
    # old metrics are absent? Fail closed per issue: establishing metrics on a
    # legacy baseline is fine without --regenerate (not a reduction).
    needs=0
  elif [[ $extract_rc -ne 0 ]]; then
    needs=1
    echo '{"total":0,"skipped":0,"todo":0}' > "$OLD_METRICS_FILE"
  else
    # Compare totals/skips: reduction requires --regenerate (same rule as
    # test-integrity.mjs needsRegenerateFlag — kept inline so we never shell
    # out through a fragile dynamic import path).
    set +e
    node -e '
      const fs = require("fs");
      function nn(v, f) {
        if (typeof v === "number" && Number.isInteger(v) && v >= 0) return v;
        if (typeof v === "string" && /^(0|[1-9]\d*)$/.test(v.trim())) return Number(v.trim());
        throw new Error("bad " + f);
      }
      const oldM = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const newM = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
      const ot = nn(oldM.total, "old.total");
      const nt = nn(newM.total, "new.total");
      const os = nn(oldM.skipped ?? 0, "old.skipped") + nn(oldM.todo ?? 0, "old.todo");
      const ns = nn(newM.skipped ?? 0, "new.skipped") + nn(newM.todo ?? 0, "new.todo");
      process.exit(nt < ot || ns > os ? 11 : 0);
    ' "$OLD_METRICS_FILE" "$NEW_METRICS_FILE"
    cmp_rc=$?
    set -e
    if [[ $cmp_rc -eq 11 ]]; then
      needs=1
    elif [[ $cmp_rc -ne 0 ]]; then
      rm -f "$OLD_METRICS_FILE" "$NEW_METRICS_FILE"
      die "could not compare prior baseline metrics"
    fi
  fi

  if [[ "$needs" -eq 1 ]]; then
    if [[ "$REGENERATE" -ne 1 ]]; then
      rm -f "$OLD_METRICS_FILE" "$NEW_METRICS_FILE"
      rm -f .gibson-baseline.typecheck.ec .gibson-baseline.lint.ec \
        .gibson-baseline.test.ec .gibson-baseline.build.ec .gibson-baseline.test.out
      die "test-integrity: new metrics reduce the suite (lower total or higher skip/todo) vs $OUT. Re-run with --regenerate --reason \"...\" to journal an intentional reduction."
    fi
    if [[ "$REASON_SET" -ne 1 ]] || [[ -z "${REASON// }" ]]; then
      rm -f "$OLD_METRICS_FILE" "$NEW_METRICS_FILE"
      rm -f .gibson-baseline.typecheck.ec .gibson-baseline.lint.ec \
        .gibson-baseline.test.ec .gibson-baseline.build.ec .gibson-baseline.test.out
      die "test-integrity: --regenerate requires a nonempty --reason"
    fi
    SHA=$(git rev-parse HEAD 2>/dev/null || echo unknown)
    set +e
    jout=$(node "$TI" journal-append \
      --journal "$JOURNAL" \
      --old "$OLD_METRICS_FILE" \
      --new "$NEW_METRICS_FILE" \
      --reason "$REASON" \
      --sha "$SHA" 2>&1)
    jrc=$?
    set -e
    if [[ $jrc -ne 0 ]]; then
      rm -f "$OLD_METRICS_FILE" "$NEW_METRICS_FILE"
      die "journal-append failed: $jout"
    fi
    info "test-integrity journal: $jout"
    info "appended journal entry → $JOURNAL"
  fi
  rm -f "$OLD_METRICS_FILE" "$NEW_METRICS_FILE"
elif [[ "$REGENERATE" -eq 1 ]]; then
  # Operator asked to regenerate but metrics did not worsen — still require reason
  # only when they insist on journaling; if no reduction, --regenerate is a no-op flag.
  if [[ "$REASON_SET" -eq 1 && -n "${REASON// }" && "$TEST_METRICS_PRESENT" -eq 1 && -f "$OUT" ]]; then
    info "--regenerate noted but metrics did not reduce integrity; no journal entry required"
  fi
fi

rm -f .gibson-baseline.typecheck.ec .gibson-baseline.lint.ec \
  .gibson-baseline.test.ec .gibson-baseline.build.ec .gibson-baseline.test.out

UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SHA=$(git rev-parse HEAD 2>/dev/null || echo unknown)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)

# Embed test_metrics JSON (or null) without requiring jq
if [[ "$TEST_METRICS_PRESENT" -eq 1 ]]; then
  METRICS_EMBED=$(node -e "const m=JSON.parse(process.argv[1]);process.stdout.write(JSON.stringify({total:m.total,skipped:m.skipped,todo:m.todo,skip_effective:m.skip_effective,source:m.source}))" "$TEST_METRICS_JSON")
else
  METRICS_EMBED="null"
fi

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
  },
  "test_metrics": $METRICS_EMBED
}
EOF

info "wrote $OUT"
cat "$OUT"
