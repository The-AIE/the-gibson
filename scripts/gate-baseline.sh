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

# ---------------------------------------------------------------------------
# Path identity + parent-chain authority (Bash 3.2, macOS + Linux)
# Untrusted gate steps must not pre-poison predictable paths, replace parent
# directories with symlinks, or redirect OUT/JOURNAL writes. No discoverable
# scratch is created until after configured commands return. Command output is
# captured in-memory (strict size cap); parser scratch is private + cleaned.
# ---------------------------------------------------------------------------

# Strict in-memory capture cap (characters; metrics output is ASCII-safe).
MAX_CAPTURE_CHARS=$((8 * 1024 * 1024))

# Private parser scratch — created ONLY after untrusted commands return.
SCRATCH=""
cleanup_scratch() {
  if [[ -n "${SCRATCH:-}" && -d "$SCRATCH" ]]; then
    rm -rf -- "$SCRATCH"
  fi
  SCRATCH=""
}
trap cleanup_scratch EXIT

# Portable device:inode for a path (lstat; do not follow final symlink).
# BSD stat first (macOS), GNU fallback (Linux).
path_dev_ino() {
  local p="$1" dev ino
  dev=$(stat -f %d -- "$p" 2>/dev/null) || dev=$(stat -c %d -- "$p" 2>/dev/null) || return 1
  ino=$(stat -f %i -- "$p" 2>/dev/null) || ino=$(stat -c %i -- "$p" 2>/dev/null) || return 1
  [[ -n "$dev" && -n "$ino" ]] || return 1
  printf '%s:%s' "$dev" "$ino"
}

# Refuse to read/write through a symlink or non-regular file (fail closed).
# Missing path is OK (will be created). -e is false for broken symlinks on
# some systems, so also test -L explicitly.
refuse_symlink_or_nonfile() {
  local path="$1"
  local label="$2"
  if [[ -L "$path" ]]; then
    die "$label path is a symlink (refuse; fail closed): $path"
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    die "$label path is not a regular file (refuse; fail closed): $path"
  fi
}

# Print parent path components from immediate parent up to / or . (one per line).
# Supports relative/absolute paths and spaces (no pathname splitting).
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

# Snapshot existing parents. Pre-existing directory *or* symlink parents are
# allowed (macOS /tmp and /var are symlinks); we record lstat identity + kind.
# Stores lines "path<TAB>dev:ino<TAB>kind" (kind = dir|symlink).
snapshot_parent_chain() {
  local target="$1"
  local _snap="" p id kind
  local plist
  plist=$(collect_parent_paths "$target") || die "cannot walk parents of $target"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ -L "$p" ]]; then
      # Pre-existing symlink parent (e.g. macOS /var → /private/var): record it.
      # A *new* symlink introduced after the snapshot is rejected on verify.
      id=$(path_dev_ino "$p") || die "cannot identity symlink parent: $p"
      kind="symlink"
      _snap="${_snap}${p}"$'\t'"${id}"$'\t'"${kind}"$'\n'
    elif [[ -e "$p" ]]; then
      if [[ ! -d "$p" ]]; then
        die "parent path is not a directory (refuse; fail closed): $p"
      fi
      id=$(path_dev_ino "$p") || die "cannot identity parent: $p"
      kind="dir"
      _snap="${_snap}${p}"$'\t'"${id}"$'\t'"${kind}"$'\n'
    fi
  done <<EOF
$plist
EOF
  printf -v "$2" '%s' "$_snap"
}

# True if path appears in a parent snapshot (first TAB field).
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

# After untrusted work: every snapshotted parent must still exist with the same
# lstat identity and kind. Parents that appear only after the snapshot must be
# real directories (not symlinks) — that is the replace-with-symlink attack class.
verify_parent_chain() {
  local target="$1"
  local snap="$2"
  local label="$3"
  local p id kind cur plist line rest

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    p=${line%%$'\t'*}
    rest=${line#*$'\t'}
    id=${rest%%$'\t'*}
    kind=${rest#*$'\t'}
    if [[ "$kind" == "dir" ]]; then
      if [[ -L "$p" ]]; then
        die "$label parent became a symlink (authority drift; fail closed): $p"
      fi
      if [[ ! -d "$p" ]]; then
        die "$label parent missing or not a directory (authority drift; fail closed): $p"
      fi
    elif [[ "$kind" == "symlink" ]]; then
      if [[ ! -L "$p" ]]; then
        die "$label symlink parent changed kind (authority drift; fail closed): $p"
      fi
    else
      die "$label corrupt parent snapshot for: $p"
    fi
    cur=$(path_dev_ino "$p") || die "$label cannot re-identity parent: $p"
    if [[ "$cur" != "$id" ]]; then
      die "$label parent replaced (authority drift; fail closed): $p"
    fi
  done <<EOF
$snap
EOF

  plist=$(collect_parent_paths "$target") || die "cannot re-walk parents of $target"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if _parent_snap_has "$snap" "$p"; then
      continue
    fi
    # Newly present parent component: must be a real directory, never a symlink.
    if [[ -L "$p" ]]; then
      die "$label parent is a new symlink (refuse; fail closed): $p"
    fi
    if [[ -e "$p" && ! -d "$p" ]]; then
      die "$label parent is not a directory (refuse; fail closed): $p"
    fi
  done <<EOF
$plist
EOF
}

# Ensure immediate parent exists as a real directory after chain verification.
ensure_real_parent() {
  local dest="$1"
  local label="$2"
  local snap="$3"
  local dir
  verify_parent_chain "$dest" "$snap" "$label"
  dir=$(dirname -- "$dest")
  if [[ ! -d "$dir" ]]; then
    mkdir -p -- "$dir" || die "cannot create directory for $dest"
  fi
  if [[ -L "$dir" ]]; then
    die "$label parent is a symlink after mkdir (refuse; fail closed): $dir"
  fi
  if [[ ! -d "$dir" ]]; then
    die "$label parent is not a directory after mkdir (refuse; fail closed): $dir"
  fi
  # Re-check full chain (new components must not be symlinks).
  verify_parent_chain "$dest" "$snap" "$label"
}

# Atomic write via sibling mktemp + rename. Revalidates parent identity first.
# Never opens dest for write (so a symlink dest is not followed/truncated).
atomic_write() {
  local dest="$1"
  local parent_snap="$2"
  local dir base tmp
  ensure_real_parent "$dest" "output" "$parent_snap"
  refuse_symlink_or_nonfile "$dest" "output"
  dir=$(dirname -- "$dest")
  base=$(basename -- "$dest")
  # Sibling temp in the same directory so rename stays on one filesystem.
  tmp=$(mktemp "${dir}/.${base}.XXXXXX") || die "mktemp failed for atomic write to $dest"
  if [[ -L "$tmp" || ! -f "$tmp" ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    die "atomic-write temp is not a regular file (fail closed): $tmp"
  fi
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    die "failed writing temp for $dest"
  fi
  # Revalidate parents + leaf after content write, before rename.
  verify_parent_chain "$dest" "$parent_snap" "output"
  if [[ -L "$dest" ]]; then
    rm -f -- "$tmp"
    die "output path is a symlink (refuse; fail closed): $dest"
  fi
  if [[ -e "$dest" && ! -f "$dest" ]]; then
    rm -f -- "$tmp"
    die "output path is not a regular file (refuse; fail closed): $dest"
  fi
  if [[ -L "$tmp" || ! -f "$tmp" ]]; then
    rm -f -- "$tmp"
    die "atomic-write temp became non-regular before rename (fail closed)"
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    die "atomic rename failed for $dest"
  fi
  if [[ -L "$dest" || ! -f "$dest" ]]; then
    die "output path is not a regular file after write (fail closed): $dest"
  fi
}

# Append one journal line via test-integrity.mjs only after parent/leaf checks.
journal_append_safe() {
  local journal_path="$1"
  local parent_snap="$2"
  local old_file="$3"
  local new_file="$4"
  local reason="$5"
  local sha="$6"
  ensure_real_parent "$journal_path" "journal" "$parent_snap"
  if [[ -e "$journal_path" || -L "$journal_path" ]]; then
    refuse_symlink_or_nonfile "$journal_path" "journal"
  fi
  set +e
  jout=$(node "$TI" journal-append \
    --journal "$journal_path" \
    --old "$old_file" \
    --new "$new_file" \
    --reason "$reason" \
    --sha "$sha" 2>&1)
  jrc=$?
  set -e
  if [[ $jrc -ne 0 ]]; then
    die "journal-append failed: $jout"
  fi
  # Leaf must remain a regular file after append.
  if [[ -L "$journal_path" || ! -f "$journal_path" ]]; then
    die "journal path is not a regular file after append (fail closed): $journal_path"
  fi
  verify_parent_chain "$journal_path" "$parent_snap" "journal"
  info "test-integrity journal: $jout"
  info "appended journal entry → $journal_path"
}

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

# ---------------------------------------------------------------------------
# Pre-command authority: OUT / JOURNAL parents + prior baseline bytes/metrics.
# No discoverable scratch directory exists yet.
# ---------------------------------------------------------------------------

refuse_symlink_or_nonfile "$OUT" "baseline --out"
# JOURNAL may be missing; only refuse if present as symlink/nonfile.
if [[ -e "$JOURNAL" || -L "$JOURNAL" ]]; then
  refuse_symlink_or_nonfile "$JOURNAL" "journal --journal"
fi

OUT_PARENT_SNAP=""
JOURNAL_PARENT_SNAP=""
snapshot_parent_chain "$OUT" OUT_PARENT_SNAP
snapshot_parent_chain "$JOURNAL" JOURNAL_PARENT_SNAP

# Snapshot prior OUT content for regenerate comparison (never re-read after
# untrusted commands — a hostile step could rewrite the prior baseline).
PRIOR_OUT_PRESENT=0
PRIOR_OUT_BYTES=""
if [[ -f "$OUT" && ! -L "$OUT" ]]; then
  PRIOR_OUT_PRESENT=1
  # shellcheck disable=SC2002
  PRIOR_OUT_BYTES=$(cat -- "$OUT") || die "cannot read prior baseline: $OUT"
fi

# In-memory step results (no pathname visible to configured commands).
EC_TYPECHECK=0
EC_LINT=0
EC_TEST=0
EC_BUILD=0
FC_TYPECHECK=0
FC_LINT=0
FC_TEST=0
FC_BUILD=0
TEST_CAPTURE=""
TEST_CAPTURED=0

# run_count_failures: capture stdout+stderr and exit status in memory only.
# NEVER invoke via $(...) — that would run in a subshell and drop TEST_CAPTURE
# / EC_* / FC_* assignments. Call directly so globals persist in this shell.
# Never creates files or directories the command can discover/pre-poison.
run_count_failures() {
  local step="$1"
  local cmd="$2"
  local out ec fc
  if [[ -z "$cmd" ]]; then
    case "$step" in
      typecheck) EC_TYPECHECK=0; FC_TYPECHECK=0 ;;
      lint) EC_LINT=0; FC_LINT=0 ;;
      test) EC_TEST=0; FC_TEST=0 ;;
      build) EC_BUILD=0; FC_BUILD=0 ;;
    esac
    return 0
  fi
  info "baseline $step: $cmd"
  set +e
  # shellcheck disable=SC2086
  out=$(eval "$cmd" 2>&1)
  ec=$?
  set -e
  if [[ ${#out} -gt $MAX_CAPTURE_CHARS ]]; then
    die "captured $step output exceeds size cap (${MAX_CAPTURE_CHARS} chars; fail closed)"
  fi
  case "$step" in
    typecheck) EC_TYPECHECK=$ec ;;
    lint) EC_LINT=$ec ;;
    test)
      EC_TEST=$ec
      TEST_CAPTURE=$out
      TEST_CAPTURED=1
      ;;
    build) EC_BUILD=$ec ;;
  esac
  if [[ $ec -ne 0 ]]; then
    fc=$(printf '%s\n' "$out" | grep -ciE 'error TS|error:|FAIL|failed|✖|×' || true)
    [[ "$fc" -eq 0 ]] && fc=1
  else
    fc=0
  fi
  case "$step" in
    typecheck) FC_TYPECHECK=$fc ;;
    lint) FC_LINT=$fc ;;
    test) FC_TEST=$fc ;;
    build) FC_BUILD=$fc ;;
  esac
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

# Direct calls (not command-substitution) so in-memory capture globals stick.
run_count_failures typecheck "$TC"
run_count_failures lint "$LI"
run_count_failures test "$TE"
run_count_failures build "$BU"
fc_tc=$FC_TYPECHECK
fc_li=$FC_LINT
fc_te=$FC_TEST
fc_bu=$FC_BUILD
ec_tc=$EC_TYPECHECK
ec_li=$EC_LINT
ec_te=$EC_TEST
ec_bu=$EC_BUILD

# ---------------------------------------------------------------------------
# Post-command: revalidate OUT/JOURNAL parents, then private parser scratch.
# ---------------------------------------------------------------------------

verify_parent_chain "$OUT" "$OUT_PARENT_SNAP" "output"
verify_parent_chain "$JOURNAL" "$JOURNAL_PARENT_SNAP" "journal"
refuse_symlink_or_nonfile "$OUT" "baseline --out"
if [[ -e "$JOURNAL" || -L "$JOURNAL" ]]; then
  refuse_symlink_or_nonfile "$JOURNAL" "journal --journal"
fi

# --- test metrics (issue #70) -------------------------------------------------
# When a test command was configured, metrics must parse successfully.
# Never skip parsing and continue with test_metrics:null after a test step.
TEST_METRICS_JSON='null'
TEST_METRICS_PRESENT=0

if [[ -n "$TE" ]]; then
  if [[ "$TEST_CAPTURED" -ne 1 ]]; then
    die "test step configured but output was not captured (fail closed)"
  fi

  # Create private parser scratch ONLY now (after untrusted commands returned).
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/gibson-baseline.XXXXXX") \
    || die "could not create private parser scratch directory"
  chmod 700 "$SCRATCH" || die "could not set private permissions on parser scratch"

  test_out_file=$(mktemp "${SCRATCH}/test.out.XXXXXX") \
    || die "mktemp failed for captured test output"
  if [[ -L "$test_out_file" || ! -f "$test_out_file" ]]; then
    die "captured-output path is not a regular file (fail closed): $test_out_file"
  fi
  # Write in-memory capture; exclusive mktemp path is not pre-poisonable by
  # the already-returned command.
  if ! printf '%s\n' "$TEST_CAPTURE" >"$test_out_file"; then
    die "failed writing captured test output (fail closed)"
  fi
  if [[ -L "$test_out_file" || ! -f "$test_out_file" || ! -r "$test_out_file" ]]; then
    die "captured-output state is non-regular/symlink/unreadable (fail closed): $test_out_file"
  fi

  parse_err_file=$(mktemp "${SCRATCH}/parse-err.XXXXXX") \
    || die "mktemp failed for parse stderr"
  if [[ -L "$parse_err_file" || ! -f "$parse_err_file" ]]; then
    die "scratch parse-err is not a regular file (fail closed)"
  fi
  set +e
  parsed=$(node "$TI" parse --input "$test_out_file" 2>"$parse_err_file")
  parse_rc=$?
  set -e
  if [[ $parse_rc -ne 0 ]]; then
    if [[ -f "$parse_err_file" && ! -L "$parse_err_file" ]]; then
      cat "$parse_err_file" >&2 || true
    fi
    die "test step produced unparseable metrics (fail closed). Emit GIBSON_TEST_METRICS or a supported summary (docs/06)."
  fi
  # Re-check capture file was not swapped mid-parse (defensive).
  if [[ -L "$test_out_file" || ! -f "$test_out_file" || ! -r "$test_out_file" ]]; then
    die "captured-output state invalid after parse (fail closed): $test_out_file"
  fi
  TEST_METRICS_JSON=$parsed
  TEST_METRICS_PRESENT=1
fi

# Integrity-reduction guard: compare against PRIOR snapshot (not a post-command
# re-read of OUT). Lowering total or raising skip/todo requires --regenerate.
if [[ "$PRIOR_OUT_PRESENT" -eq 1 && "$TEST_METRICS_PRESENT" -eq 1 ]]; then
  # Ensure private scratch exists for comparison temps (may already from parse).
  if [[ -z "$SCRATCH" || ! -d "$SCRATCH" ]]; then
    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/gibson-baseline.XXXXXX") \
      || die "could not create private scratch for metrics compare"
    chmod 700 "$SCRATCH" || die "could not set private permissions on scratch"
  fi
  OLD_METRICS_FILE=$(mktemp "${SCRATCH}/old-metrics.XXXXXX") \
    || die "mktemp failed for old metrics"
  NEW_METRICS_FILE=$(mktemp "${SCRATCH}/new-metrics.XXXXXX") \
    || die "mktemp failed for new metrics"
  PRIOR_OUT_FILE=$(mktemp "${SCRATCH}/prior-out.XXXXXX") \
    || die "mktemp failed for prior baseline snapshot"
  if [[ -L "$OLD_METRICS_FILE" || ! -f "$OLD_METRICS_FILE" ]] \
    || [[ -L "$NEW_METRICS_FILE" || ! -f "$NEW_METRICS_FILE" ]] \
    || [[ -L "$PRIOR_OUT_FILE" || ! -f "$PRIOR_OUT_FILE" ]]; then
    die "metrics compare temps are not regular files (fail closed)"
  fi
  printf '%s\n' "$TEST_METRICS_JSON" >"$NEW_METRICS_FILE"
  printf '%s' "$PRIOR_OUT_BYTES" >"$PRIOR_OUT_FILE"

  set +e
  node -e "
    const fs=require('fs');
    const b=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
    if(!b.test_metrics){process.exit(2)}
    fs.writeFileSync(process.argv[2], JSON.stringify(b.test_metrics));
  " "$PRIOR_OUT_FILE" "$OLD_METRICS_FILE"
  extract_rc=$?
  set -e

  needs=0
  if [[ $extract_rc -eq 2 ]]; then
    # Legacy baseline without metrics: establishing metrics is not a reduction.
    needs=0
    echo '{"total":0,"skipped":0,"todo":0}' >"$OLD_METRICS_FILE"
  elif [[ $extract_rc -ne 0 ]]; then
    needs=1
    echo '{"total":0,"skipped":0,"todo":0}' >"$OLD_METRICS_FILE"
  else
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
      die "could not compare prior baseline metrics"
    fi
  fi

  if [[ "$needs" -eq 1 ]]; then
    if [[ "$REGENERATE" -ne 1 ]]; then
      die "test-integrity: new metrics reduce the suite (lower total or higher skip/todo) vs $OUT. Re-run with --regenerate --reason \"...\" to journal an intentional reduction."
    fi
    if [[ "$REASON_SET" -ne 1 ]] || [[ -z "${REASON// }" ]]; then
      die "test-integrity: --regenerate requires a nonempty --reason"
    fi
    SHA=$(git rev-parse HEAD 2>/dev/null || echo unknown)
    journal_append_safe "$JOURNAL" "$JOURNAL_PARENT_SNAP" \
      "$OLD_METRICS_FILE" "$NEW_METRICS_FILE" "$REASON" "$SHA"
  fi
elif [[ "$REGENERATE" -eq 1 ]]; then
  if [[ "$REASON_SET" -eq 1 && -n "${REASON// }" && "$TEST_METRICS_PRESENT" -eq 1 && "$PRIOR_OUT_PRESENT" -eq 1 ]]; then
    info "--regenerate noted but metrics did not reduce integrity; no journal entry required"
  fi
fi

UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SHA=$(git rev-parse HEAD 2>/dev/null || echo unknown)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)

# Embed test_metrics JSON (or null) without requiring jq
if [[ "$TEST_METRICS_PRESENT" -eq 1 ]]; then
  METRICS_EMBED=$(node -e "const m=JSON.parse(process.argv[1]);process.stdout.write(JSON.stringify({total:m.total,skipped:m.skipped,todo:m.todo,skip_effective:m.skip_effective,source:m.source}))" "$TEST_METRICS_JSON")
else
  # Only allowed when no test command was configured.
  METRICS_EMBED="null"
fi

# Final write: revalidate parents, sibling temp, atomic rename.
atomic_write "$OUT" "$OUT_PARENT_SNAP" <<EOF
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
if [[ -L "$OUT" ]]; then
  die "output path is a symlink after write (fail closed): $OUT"
fi
cat "$OUT"
