#!/usr/bin/env bash
# gate.sh — green gate vs. baseline (docs/06) + test-integrity (issue #70)
set -euo pipefail

# Shared diagnostic oracle (#375). gate-baseline freezes this source in shell
# memory BEFORE configured commands; it must never execute a live helper path
# after those commands can rewrite it. Source-only mode has no gate side effects.
DIAGNOSTIC_JS=$(cat <<'GIBSON_DIAGNOSTIC_JS'
const steps = ["typecheck", "lint", "test", "build"];
const [mode, step, arg, exit] = process.argv.slice(1);
function record(value) {
  if (!Array.isArray(value) || value.length !== 5 ||
      ![value[0], value[3], value[4]].every(v => typeof v === "string" && v.trim().length > 0) ||
      !((value[1] === null && value[2] === null) ||
        [value[1], value[2]].every(v => Number.isSafeInteger(v) && v > 0))) {
    throw new Error("malformed diagnostic identity");
  }
  return value;
}
function capture(text, ec) {
  const lines = text.split(/\r?\n/);
  if (ec === 0) {
    if (lines.some(line => /^\s*GIBSON_DIAGNOSTIC/.test(line))) {
      throw new Error("explicit diagnostic contradicts exit 0");
    }
    return [];
  }
  const records = [];
  for (const line of lines) {
    if (line.trim() === "") continue;
    if (line.startsWith("GIBSON_DIAGNOSTIC_V1 ")) {
      try { records.push(record(JSON.parse(line.slice(21)))); }
      catch { return null; }
    } else if (step === "test" &&
        /^GIBSON_TEST_METRICS total=(0|[1-9][0-9]*) skipped=(0|[1-9][0-9]*) todo=(0|[1-9][0-9]*)$/.test(line)) {
      // Independently parsed and ratcheted by test-integrity.mjs; never a diagnostic.
    } else {
      return null;
    }
  }
  return records.length > 0 ? records : null;
}
function validate(base) {
  if (!Object.hasOwn(base, "diagnostics")) return; // Legacy: strict all-green only.
  const d = base.diagnostics;
  if (!d || Array.isArray(d) || d.version !== 1 ||
      Object.keys(d).sort().join(",") !== [...steps, "version"].sort().join(",")) {
    throw new Error("unsupported or malformed diagnostic evidence version");
  }
  for (const name of steps) {
    const ec = base.exit_codes?.[name];
    if (!Number.isSafeInteger(ec) || ec < 0 || ec > 255 ||
        typeof base.commands?.[name] !== "string") {
      throw new Error("malformed diagnostic command/exit binding");
    }
    const ids = d[name];
    if (ids === null && ec !== 0) continue; // Explicitly opaque; cannot excuse red.
    if (!Array.isArray(ids) || (ec === 0 ? ids.length !== 0 : ids.length === 0)) {
      throw new Error("malformed diagnostic evidence for step");
    }
    ids.forEach(record);
  }
}
const chunks = [];
process.stdin.on("data", chunk => { chunks.push(chunk); });
process.stdin.on("end", () => {
  try {
    const bytes = Buffer.concat(chunks);
    // Fatal decoding preserves U+FFFD identities and never replaces malformed
    // bytes. Preserve BOMs too: unknown prefixes must remain unknown output.
    const input = new TextDecoder("utf-8", {fatal: true, ignoreBOM: true}).decode(bytes);
    if (mode === "capture-text") {
      if (bytes.includes(0)) throw new Error("NUL in captured text");
      // Retain the prior command-substitution trailing-LF behavior, without
      // placing unvalidated bytes in any Bash variable.
      process.stdout.write("GIBSON_CAPTURE_TEXT_V1\n" + input.replace(/\n+$/, ""));
      return;
    }
    if (mode === "validate") {
      validate(JSON.parse(input));
      return;
    }
    if (!steps.includes(step)) throw new Error("unknown diagnostic step");
    if (mode === "record") {
      process.stdout.write(JSON.stringify(capture(input, Number(arg))));
      return;
    }
    if (mode !== "compare") throw new Error("unknown diagnostic operation");
    const split = input.indexOf("\0");
    if (split < 0) throw new Error("missing diagnostic comparison input");
    const base = JSON.parse(input.slice(0, split));
    validate(base);
    if (!Object.hasOwn(base, "diagnostics")) {
      throw new Error("legacy baseline has no diagnostic identities; re-run gate-baseline.sh");
    }
    if (base.commands[step] !== arg || base.exit_codes[step] !== Number(exit)) {
      throw new Error("diagnostic command/exit binding changed");
    }
    const known = base.diagnostics[step];
    const candidate = capture(input.slice(split + 1), Number(exit));
    if (known === null || candidate === null) {
      throw new Error("opaque diagnostics cannot establish zero new failures; require exit 0 or structured records");
    }
    const remaining = new Map();
    for (const id of known) {
      const key = JSON.stringify(id);
      remaining.set(key, (remaining.get(key) || 0) + 1);
    }
    for (const id of candidate) {
      const key = JSON.stringify(id);
      const count = remaining.get(key) || 0;
      if (count === 0) throw new Error("new diagnostic identity or increased multiplicity");
      remaining.set(key, count - 1);
    }
  } catch (err) {
    if (mode === "capture-text") {
      process.stdout.write("GIBSON_CAPTURE_REFUSED_V1");
      return;
    }
    process.stderr.write("diagnostics: " + err.message + " (fail closed)\n");
    process.exitCode = 1;
  }
});
GIBSON_DIAGNOSTIC_JS
)
if [[ "${1:-}" == "--diagnostic-parser-source" ]]; then
  [[ $# -eq 1 ]] || { echo "diagnostic source mode takes no arguments" >&2; exit 2; }
  printf '%s\n' "$DIAGNOSTIC_JS"
  exit 0
fi
diagnostic_tool() { node -e "$DIAGNOSTIC_JS" "$@"; }

# Validate bytes before Bash command substitution can discard NULs. The final
# status footer comes from the trusted parent shell, not the captured payload.
# Parser failure after partial stdout must never become valid capture evidence.
capture_text() {
  local capture_status
  command -v node >/dev/null || return 125
  "$@" 2>&1 | node -e "$DIAGNOSTIC_JS" capture-text
  capture_status=("${PIPESTATUS[@]}")
  printf '\nGIBSON_CAPTURE_STATUS_V1:%s:%s' "${capture_status[0]}" "${capture_status[1]}"
}

decode_text_capture() {
  local capture_frame="$1" capture_dest="$2" capture_ec_dest="$3"
  local capture_footer capture_payload capture_producer capture_parser
  capture_footer=${capture_frame##*$'\n'}
  if [[ ! "$capture_footer" =~ ^GIBSON_CAPTURE_STATUS_V1:([0-9]+):([0-9]+)$ ]]; then
    return 1
  fi
  capture_producer=${BASH_REMATCH[1]}
  capture_parser=${BASH_REMATCH[2]}
  [[ "$capture_parser" -eq 0 ]] || return 1
  capture_payload=${capture_frame%$'\n'*}
  case "$capture_payload" in
    GIBSON_CAPTURE_TEXT_V1) capture_payload="" ;;
    GIBSON_CAPTURE_TEXT_V1$'\n'*) capture_payload=${capture_payload#GIBSON_CAPTURE_TEXT_V1$'\n'} ;;
    *) return 1 ;;
  esac
  printf -v "$capture_dest" '%s' "$capture_payload"
  printf -v "$capture_ec_dest" '%s' "$capture_producer"
}

usage() {
  cat <<'EOF'
gate.sh — run the green gate; fail on NEW failures vs. baseline

WHAT IT DOES
  Runs generate → typecheck → lint → test → build using the same command
  resolution as gate-baseline.sh. Failing steps must emit structured diagnostic
  identities whose multiset is a subset of the trusted baseline, with the same
  command and exit code. Counts are report-only; equal counts never excuse a
  new diagnostic. Unsupported/opaque failing output is RED.

DIAGNOSTIC FORMAT (v1)
  One complete record per line, with no other output on a failing step:
    GIBSON_DIAGNOSTIC_V1 ["src/file.ts",1,2,"TS1234","full diagnostic message"]
  The fixed tuple is [path,line,column,code,message]. Path/code/message must
  be nonempty strings; positions must both be positive integers or null/null.
  Include all significant detail in message. Record order is irrelevant;
  multiplicity matters. NUL or malformed UTF-8 output is rejected before shell
  capture. No ANSI stripping, path rewriting or message trimming.
  Test steps may also emit canonical GIBSON_TEST_METRICS total=N skipped=N
  todo=N on one line; the independent test-integrity ratchet still applies.
  Wrappers must describe actual diagnostics, not just failure summaries. Plain
  text, empty/summary-only failures, unknown versions and unclassified output
  cannot prove identity. Such runners must exit 0 to pass. Explicit diagnostic
  records paired with exit 0 are contradictory and rejected.

COMPATIBILITY
  New baselines carry diagnostics.version=1. Legacy baselines can still pass
  an all-green candidate (subject to test-integrity); they cannot excuse red.
  Re-record diagnostic evidence at the trusted branch point, never at a failing
  candidate merely to make it green. Malformed/unknown evidence fails closed.

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
  - Local .gibson-baseline.json is worktree-local and gitignored — it must
    never authorize a PR merge. Phase-2 CI (after this helper is on main)
    will re-derive metrics at the merge base with the base-owned helper;
    phase-1 ships local enforcement only.
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

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TI="$SCRIPT_DIR/test-integrity.mjs"

# Strict in-memory capture cap for configured command output.
MAX_CAPTURE_CHARS=$((8 * 1024 * 1024))

# ---------------------------------------------------------------------------
# Baseline authority snapshot (before any configured command)
# Compare diagnostic identities and test-integrity against this trusted snapshot
# only — never re-read the baseline path after untrusted commands return.
# Disappearance, replacement, parent drift, or byte change is RED.
# ---------------------------------------------------------------------------

path_dev_ino() {
  local p="$1" dev ino
  # GNU first: on Linux `stat -f` is --file-system (succeeds for the wrong
  # meaning / can collide on format-looking paths). L-050 / #99.
  dev=$(stat -c %d -- "$p" 2>/dev/null || stat -f %d -- "$p" 2>/dev/null) || return 1
  ino=$(stat -c %i -- "$p" 2>/dev/null || stat -f %i -- "$p" 2>/dev/null) || return 1
  [[ -n "$dev" && -n "$ino" ]] || return 1
  printf '%s:%s' "$dev" "$ino"
}

collect_parent_paths() {
  local target="$1"
  local cur next
  cur=$(dirname -- "$target")
  while true; do
    printf '%s\n' "$cur"
    if [[ "$cur" == "/" || "$cur" == "." ]]; then
      break
    fi
    next=$(dirname -- "$cur")
    if [[ "$next" == "$cur" ]]; then
      break
    fi
    cur=$next
  done
}

# Snapshot existing parents. Pre-existing dir *or* symlink parents are allowed
# (macOS /tmp and /var are symlinks). Record lstat identity + kind.
# Lines: "path<TAB>dev:ino<TAB>kind" (kind = dir|symlink).
snapshot_parent_chain() {
  local target="$1"
  local _snap="" p id kind
  local plist
  plist=$(collect_parent_paths "$target") || return 1
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ -L "$p" ]]; then
      id=$(path_dev_ino "$p") || return 1
      kind="symlink"
      _snap="${_snap}${p}"$'\t'"${id}"$'\t'"${kind}"$'\n'
    elif [[ -e "$p" ]]; then
      if [[ ! -d "$p" ]]; then
        echo "gate.sh: ERROR: baseline parent path is not a directory (refuse; fail closed): $p" >&2
        return 1
      fi
      id=$(path_dev_ino "$p") || return 1
      kind="dir"
      _snap="${_snap}${p}"$'\t'"${id}"$'\t'"${kind}"$'\n'
    fi
  done <<EOF
$plist
EOF
  printf -v "$2" '%s' "$_snap"
}

_parent_snap_has() {
  local snap="$1"
  local want="$2"
  local line p
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    p=${line%%$'\t'*}
    if [[ "$p" == "$want" ]]; then
      return 0
    fi
  done <<EOF
$snap
EOF
  return 1
}

verify_parent_chain() {
  local target="$1"
  local snap="$2"
  local p id kind cur plist line rest

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    p=${line%%$'\t'*}
    rest=${line#*$'\t'}
    id=${rest%%$'\t'*}
    kind=${rest#*$'\t'}
    if [[ "$kind" == "dir" ]]; then
      if [[ -L "$p" ]]; then
        fail "baseline authority drift: parent became a symlink: $p"
        return 1
      fi
      if [[ ! -d "$p" ]]; then
        fail "baseline authority drift: parent missing or not a directory: $p"
        return 1
      fi
    elif [[ "$kind" == "symlink" ]]; then
      if [[ ! -L "$p" ]]; then
        fail "baseline authority drift: symlink parent changed kind: $p"
        return 1
      fi
    else
      fail "baseline authority drift: corrupt parent snapshot for $p"
      return 1
    fi
    cur=$(path_dev_ino "$p") || {
      fail "baseline authority drift: cannot re-identity parent: $p"
      return 1
    }
    if [[ "$cur" != "$id" ]]; then
      fail "baseline authority drift: parent replaced: $p"
      return 1
    fi
  done <<EOF
$snap
EOF

  plist=$(collect_parent_paths "$target") || {
    fail "baseline authority drift: cannot re-walk parents"
    return 1
  }
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if _parent_snap_has "$snap" "$p"; then
      continue
    fi
    if [[ -L "$p" ]]; then
      fail "baseline authority drift: parent is a new symlink: $p"
      return 1
    fi
    if [[ -e "$p" && ! -d "$p" ]]; then
      fail "baseline authority drift: parent is not a directory: $p"
      return 1
    fi
  done <<EOF
$plist
EOF
  return 0
}

# Snapshot state filled before any configured command.
SNAP_PRESENT=0
SNAP_BYTES=""
SNAP_LEAF_ID=""
SNAP_PARENT=""
SNAP_FC_TYPECHECK=0
SNAP_FC_LINT=0
SNAP_FC_TEST=0
SNAP_FC_BUILD=0
SNAP_EC_TYPECHECK=0
SNAP_EC_LINT=0
SNAP_EC_TEST=0
SNAP_EC_BUILD=0
SNAP_HAS_METRICS=0

# Reject unsafe baseline path shapes; snapshot presence/identity/bytes/metrics.
if [[ -L "$BASELINE" ]]; then
  die "baseline path is a symlink (refuse; fail closed): $BASELINE"
fi
if [[ -e "$BASELINE" && ! -f "$BASELINE" ]]; then
  die "baseline path is not a regular file (refuse; fail closed): $BASELINE"
fi

if ! snapshot_parent_chain "$BASELINE" SNAP_PARENT; then
  die "unsafe baseline parent path (refuse; fail closed): $BASELINE"
fi

if [[ -f "$BASELINE" ]]; then
  SNAP_PRESENT=1
  SNAP_LEAF_ID=$(path_dev_ino "$BASELINE") \
    || die "cannot identity baseline leaf: $BASELINE"
  command -v node >/dev/null || die "node is required to parse the trusted baseline"
  SNAP_BYTES=$(capture_text cat -- "$BASELINE") \
    || die "cannot read baseline: $BASELINE"
  decode_text_capture "$SNAP_BYTES" SNAP_BYTES SNAP_READ_EC \
    || die "baseline capture contains NUL, invalid UTF-8, or a failed parser (fail closed)"
  [[ "$SNAP_READ_EC" -eq 0 ]] || die "cannot read baseline: $BASELINE"
  # Validate diagnostic evidence before any configured command (legacy is strict).
  printf '%s' "$SNAP_BYTES" | diagnostic_tool validate \
    || die "invalid baseline diagnostic evidence"
  # Extract failure/exit/metrics from the trusted bytes via stdin (no re-read path).
  eval "$(printf '%s' "$SNAP_BYTES" | node -e '
    let s = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (d) => { s += d; });
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        const f = j.failures || {};
        const e = j.exit_codes || {};
        const n = (v) => {
          const x = Number(v);
          return Number.isFinite(x) ? String(x | 0) : "0";
        };
        const has =
          j.test_metrics &&
          j.test_metrics.total !== undefined &&
          j.test_metrics.total !== null
            ? "1"
            : "0";
        process.stdout.write(
          "SNAP_FC_TYPECHECK=" + n(f.typecheck) + "\n" +
          "SNAP_FC_LINT=" + n(f.lint) + "\n" +
          "SNAP_FC_TEST=" + n(f.test) + "\n" +
          "SNAP_FC_BUILD=" + n(f.build) + "\n" +
          "SNAP_EC_TYPECHECK=" + n(e.typecheck) + "\n" +
          "SNAP_EC_LINT=" + n(e.lint) + "\n" +
          "SNAP_EC_TEST=" + n(e.test) + "\n" +
          "SNAP_EC_BUILD=" + n(e.build) + "\n" +
          "SNAP_HAS_METRICS=" + has + "\n"
        );
      } catch (err) {
        process.stdout.write("SNAP_PARSE_FAIL=1\n");
      }
    });
  ')" || die "failed to parse baseline snapshot"
  if [[ "${SNAP_PARSE_FAIL:-0}" == "1" ]]; then
    die "baseline JSON is unparseable (fail closed): $BASELINE"
  fi
else
  if [[ "$NO_BASELINE_OK" -eq 0 ]]; then
    info "no $BASELINE — strict mode: all steps must exit 0 (run gate-baseline.sh first)"
  fi
fi

# Re-check live baseline matches the pre-command snapshot (fail closed).
verify_baseline_authority() {
  local when="$1"
  local cur_id cur_bytes cur_read_ec

  if [[ "$SNAP_PRESENT" -eq 0 ]]; then
    # Bootstrap: baseline was absent. Appearance mid-run is not trusted and
    # is authority drift (RED). Preserve no-baseline strict exit semantics
    # only when the path stays absent.
    if [[ -e "$BASELINE" || -L "$BASELINE" ]]; then
      fail "baseline authority drift ($when): path appeared during gate run (not trusted)"
      return 1
    fi
    return 0
  fi

  if ! verify_parent_chain "$BASELINE" "$SNAP_PARENT"; then
    return 1
  fi
  if [[ -L "$BASELINE" ]]; then
    fail "baseline authority drift ($when): path is a symlink"
    return 1
  fi
  if [[ ! -f "$BASELINE" ]]; then
    fail "baseline authority drift ($when): authoritative baseline disappeared"
    return 1
  fi
  cur_id=$(path_dev_ino "$BASELINE") || {
    fail "baseline authority drift ($when): cannot re-identity leaf"
    return 1
  }
  if [[ "$cur_id" != "$SNAP_LEAF_ID" ]]; then
    fail "baseline authority drift ($when): baseline leaf replaced"
    return 1
  fi
  cur_bytes=$(capture_text cat -- "$BASELINE") || {
    fail "baseline authority drift ($when): cannot re-read baseline bytes"
    return 1
  }
  if ! decode_text_capture "$cur_bytes" cur_bytes cur_read_ec; then
    fail "baseline authority drift ($when): invalid text capture (NUL/UTF-8/parser)"
    return 1
  fi
  if [[ "$cur_read_ec" -ne 0 ]]; then
    fail "baseline authority drift ($when): cannot re-read baseline bytes"
    return 1
  fi
  if [[ "$cur_bytes" != "$SNAP_BYTES" ]]; then
    fail "baseline authority drift ($when): baseline content changed"
    return 1
  fi
  return 0
}

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
  # Prefer commands recorded in the trusted baseline snapshot (not a live re-read).
  if [[ "$SNAP_PRESENT" -eq 1 ]] && command -v node >/dev/null; then
    local from_b
    from_b=$(printf '%s' "$SNAP_BYTES" | node -e '
      let s="";process.stdin.setEncoding("utf8");
      process.stdin.on("data",d=>s+=d);
      process.stdin.on("end",()=>{
        try{
          const j=JSON.parse(s);
          const step=process.argv[1];
          if(j.commands&&j.commands[step]) process.stdout.write(String(j.commands[step]));
        }catch(e){}
      });
    ' "$step" 2>/dev/null || true)
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
  case "$step" in
    typecheck) echo "$SNAP_FC_TYPECHECK" ;;
    lint) echo "$SNAP_FC_LINT" ;;
    test) echo "$SNAP_FC_TEST" ;;
    build) echo "$SNAP_FC_BUILD" ;;
    *) echo 0 ;;
  esac
}

baseline_ec() {
  local step="$1"
  case "$step" in
    typecheck) echo "$SNAP_EC_TYPECHECK" ;;
    lint) echo "$SNAP_EC_LINT" ;;
    test) echo "$SNAP_EC_TEST" ;;
    build) echo "$SNAP_EC_BUILD" ;;
    *) echo 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Configured-command isolation (issue #70)
# Branch-controlled commands from .agents/gate.json / env MUST never run via
# parent-shell eval. A hostile generate could redefine SNAP_PRESENT /
# verify_baseline_authority, delete the baseline, emit total=1, and go GREEN.
# Every configured step runs in a throwaway child subshell: intended
# cwd/environment and exit status are preserved; child variables, functions,
# traps, options, aliases, cwd, umask, IFS, and FDs are not imported back.
# Filesystem side effects still happen (and authority re-checks catch them).
# ---------------------------------------------------------------------------
run_configured_child() {
  # Isolation boundary: eval only inside the subshell, never the parent.
  ( eval "$1" )
}

GEN=$(resolve_cmd generate GIBSON_GENERATE generate)
if [[ -n "$GEN" ]]; then
  info "generate: $GEN"
  set +e
  run_configured_child "$GEN"
  gen_rc=$?
  set -e
  verify_baseline_authority "after generate" || true
  if [[ $gen_rc -ne 0 ]]; then
    die "generate failed"
  fi
fi

# Captured test runner output for the integrity sensor (issue #70) — in-memory.
TEST_STEP_OUT=""
TEST_STEP_RAN=0

run_step() {
  local step="$1"
  local cmd="$2"
  local out ec fc b_fc b_ec diag_out capture_rc
  b_ec=$(baseline_ec "$step")
  if [[ -z "$cmd" ]]; then
    if [[ "$SNAP_PRESENT" -eq 1 && "$b_ec" -ne 0 ]]; then
      fail "$step failing baseline command disabled; diagnostic removal not proven"
    fi
    return 0
  fi
  info "$step: $cmd"
  set +e
  # Command substitution is already a subshell; still route through the
  # isolation helper so no branch-configured string is eval'd in parent.
  out=$(capture_text run_configured_child "$cmd")
  capture_rc=$?
  set -e
  if [[ "$capture_rc" -ne 0 ]] || ! decode_text_capture "$out" out ec; then
    fail "$step invalid text capture (NUL/UTF-8/parser; fail closed)"
    verify_baseline_authority "after $step (invalid capture)" || true
    return
  fi
  if [[ ${#out} -gt $MAX_CAPTURE_CHARS ]]; then
    fail "$step captured output exceeds size cap (${MAX_CAPTURE_CHARS} chars)"
    verify_baseline_authority "after $step (oversize)" || true
    return
  fi
  if [[ "$step" == "test" ]]; then
    TEST_STEP_OUT=$out
    TEST_STEP_RAN=1
  fi

  # Authority must still match the pre-command snapshot before any verdict.
  if ! verify_baseline_authority "after $step"; then
    return
  fi

  # Exit 0 plus an explicit failure record is contradictory, not a removal.
  if [[ $ec -eq 0 ]]; then
    if ! diag_out=$(printf '%s' "$out" | diagnostic_tool record "$step" "$ec" 2>&1); then
      fail "$step $diag_out"
      return
    fi
  fi

  fc=0
  if [[ $ec -ne 0 ]]; then
    fc=$(echo "$out" | grep -ciE 'error TS|error:|FAIL|failed|✖|×' || true)
    [[ "$fc" -eq 0 ]] && fc=1
  fi
  b_fc=$(baseline_failures "$step")
  b_ec=$(baseline_ec "$step")

  if [[ "$SNAP_PRESENT" -eq 0 ]]; then
    if [[ $ec -ne 0 ]]; then
      echo "$out" | tail -n 40
      fail "$step exit $ec (no baseline)"
    else
      info "$step OK"
    fi
    return
  fi

  # New failure: was green (ec0), now red — compare to trusted snapshot only.
  if [[ "$b_ec" -eq 0 && $ec -ne 0 ]]; then
    echo "$out" | tail -n 40
    fail "$step newly failing (baseline was green)"
    return
  fi
  # Counts remain useful for reporting, never authorization. Compare complete
  # diagnostic multisets from the original trusted bytes and in-memory output.
  if [[ $ec -ne 0 ]]; then
    if diag_out=$(printf '%s\0%s' "$SNAP_BYTES" "$out" |
        diagnostic_tool compare "$step" "$cmd" "$ec" 2>&1); then
      info "$step pre-existing diagnostics only (fc=$fc; baseline fc=$b_fc)"
    else
      printf '%s\n' "$out" | tail -n 40
      fail "$step $diag_out"
    fi
  else
    info "$step OK"
  fi
}

run_step typecheck "$(resolve_cmd typecheck GIBSON_TYPECHECK typecheck)"
run_step lint "$(resolve_cmd lint GIBSON_LINT lint)"
run_step test "$(resolve_cmd test GIBSON_TEST test)"
run_step build "$(resolve_cmd build GIBSON_BUILD build)"

# Final authority check before integrity verdict / GREEN.
verify_baseline_authority "before verdict" || true

# --- test-integrity (issue #70) ----------------------------------------------
# Runs even when earlier steps failed so the diagnosis is complete, but only
# when we had a trusted baseline snapshot with test_metrics and a test step ran.
# Candidate metrics are compared against the pre-command snapshot bytes — never
# a post-command re-read of the baseline path.
if [[ "$TEST_STEP_RAN" -eq 1 && "$SNAP_PRESENT" -eq 1 && -f "$TI" ]] && command -v node >/dev/null; then
  if [[ "$SNAP_HAS_METRICS" -ne 1 ]]; then
    fail "test-integrity: baseline $BASELINE lacks test_metrics — re-run gate-baseline.sh"
  else
    # Private temps created AFTER untrusted commands (not discoverable to them).
    HEAD_METRICS=$(mktemp "${TMPDIR:-/tmp}/gibson-head-metrics.XXXXXX")
    BASE_SNAP_FILE=$(mktemp "${TMPDIR:-/tmp}/gibson-base-snap.XXXXXX")
    WAIVER_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-waiver.XXXXXX")
    cleanup_ti_temps() {
      rm -f -- "$HEAD_METRICS" "${HEAD_METRICS}.out" "${HEAD_METRICS}.err" \
        "$BASE_SNAP_FILE" "$WAIVER_TMP" 2>/dev/null || true
    }
    # shellcheck disable=SC2064
    trap cleanup_ti_temps EXIT

    if [[ -L "$HEAD_METRICS" || ! -f "$HEAD_METRICS" ]] \
      || [[ -L "$BASE_SNAP_FILE" || ! -f "$BASE_SNAP_FILE" ]] \
      || [[ -L "$WAIVER_TMP" || ! -f "$WAIVER_TMP" ]]; then
      fail "test-integrity: private metric temps are not regular files (fail closed)"
    else
      printf '%s' "$SNAP_BYTES" >"$BASE_SNAP_FILE"
      printf '%s\n' "$TEST_STEP_OUT" >"${HEAD_METRICS}.out"
      if [[ -L "${HEAD_METRICS}.out" || ! -f "${HEAD_METRICS}.out" || ! -r "${HEAD_METRICS}.out" ]]; then
        fail "test-integrity: captured test output is non-regular/symlink/unreadable (fail closed)"
      else
        set +e
        node "$TI" parse --input "${HEAD_METRICS}.out" --out "$HEAD_METRICS" 2>"${HEAD_METRICS}.err"
        parse_rc=$?
        set -e
        if [[ $parse_rc -ne 0 ]]; then
          cat "${HEAD_METRICS}.err" >&2 || true
          fail "test-integrity: could not parse test metrics from runner output (fail closed)"
        else
          if [[ -L "$HEAD_METRICS" || ! -f "$HEAD_METRICS" || ! -r "$HEAD_METRICS" ]]; then
            fail "test-integrity: head metrics file is non-regular/unreadable (fail closed)"
          else
            # Authority still intact immediately before compare.
            if verify_baseline_authority "before integrity compare"; then
              printf '%s' "$WAIVER_TEXT" >"$WAIVER_TMP"
              set +e
              ti_out=$(node "$TI" compare \
                --base "$BASE_SNAP_FILE" \
                --head "$HEAD_METRICS" \
                --waiver-file "$WAIVER_TMP" \
                --trusted-source "local-baseline(${BASELINE})" 2>&1)
              ti_rc=$?
              set -e
              # Always surface the sensor output (includes WAIVER accepted lines)
              echo "$ti_out" >&2
              if [[ $ti_rc -ne 0 ]]; then
                fail "test-integrity: suite reduced or skips inflated without an exact visible waiver"
              else
                info "test-integrity OK"
              fi
            fi
          fi
        fi
      fi
    fi
    cleanup_ti_temps
    trap - EXIT
  fi
elif [[ "$TEST_STEP_RAN" -eq 1 && "$SNAP_PRESENT" -eq 1 && ! -f "$TI" ]]; then
  fail "test-integrity: scripts/test-integrity.mjs missing — cannot verify suite size"
elif [[ "$TEST_STEP_RAN" -eq 1 && "$SNAP_PRESENT" -eq 0 ]]; then
  # No trusted baseline at start: integrity cannot run. If a file appeared, the
  # authority check already failed. Bootstrap semantics otherwise preserved.
  :
fi

# One last authority check before declaring GREEN.
verify_baseline_authority "final" || true

if [[ "$FAILED" -ne 0 ]]; then
  die "green gate failed — fix new failures before commit"
fi
info "GREEN — zero new failures vs. baseline"
exit 0
