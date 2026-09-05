#!/usr/bin/env bash
# decision-ledger.sh — append-only pending-decision ledger (issue #72 offline slice)
#
# Offline, local-only foundation for owner decision cards. Records PENDING
# decisions only. Never records approval, denial, choice selection, merge
# authorization, or answer ingestion. Delivery, scheduling, and authenticated
# answer ingestion remain owner-gated (issue #72 stays open for those).
#
# Portable on macOS Bash 3.2 and Linux. Requires python3 on PATH for JSON and
# hashing (argv data only — never shell-eval'd). No network, no gh, no Hermes.
set -euo pipefail

usage() {
  cat <<'EOF'
decision-ledger.sh — append-only pending-decision ledger (offline)

WHAT IT DOES
  Stores newline-delimited canonical JSON events (schema decision-ledger:v1)
  for PENDING owner decisions only. Generates a stable full-strength id from
  the canonical identity tuple (repo, gate, source type, source id, source SHA).
  Same identity + same card fields is an idempotent no-op; same id with
  conflicting immutable/card fields fails closed.

  Default ledger path is runtime-local under gibson/ and is never committed.
  Pass --ledger PATH for sensors and operators.

WHAT IT DOES NOT DO
  Never accepts/records approval, denial, choice selection, merge authorization,
  or answer ingestion. Never delivers messages, schedules jobs, or talks to
  GitHub/Hermes/email/iMessage/webhooks. Those remain owner-gated under #72.

USAGE
  decision-ledger.sh add --repo owner/name --gate G12 \
    --source-type pr --source-id 123 --source-sha <40-hex> \
    --what "..." --why-you "..." --risk-level low|medium|high \
    --risk-consequence "..." --risk-undo "..." \
    --recommend Approve|Decline|Wait --recommend-rationale "..." \
    --if-you-wait "..." --source-ref "..." \
    [--created-at YYYY-MM-DDTHH:MM:SSZ] [--ledger PATH]

  decision-ledger.sh list  [--ledger PATH] [--format jsonl|json|markdown]
  decision-ledger.sh status [--ledger PATH]
  decision-ledger.sh show --id <id> [--ledger PATH]
  decision-ledger.sh --help

OPTIONS
  --ledger PATH       ledger JSONL file (default: <cwd>/gibson/decision-ledger.jsonl)
  --format FMT        list output: jsonl (default), json, markdown
  --created-at TS     injectable UTC timestamp for deterministic tests
  --id ID             decision id (show)

CARD FIELDS (one decision per event; all required on add)
  --what              plain-language decision (WHAT)
  --why-you           why this is an owner decision (WHY YOU; gate also required)
  --risk-level        low | medium | high
  --risk-consequence  what could go wrong
  --risk-undo         how to undo
  --recommend         Approve | Decline | Wait
  --recommend-rationale  one-sentence why the fleet recommends this
  --if-you-wait       safe-silence behavior (other work continues)
  --source-ref        human-readable source reference (PR/issue/path + SHA)

IDENTITY (immutable; form the stable id)
  --repo              repository slug owner/name
  --gate              exact gate G1..G16 (docs/14)
  --source-type       pr | issue | loop-state | journal | manual
  --source-id         source identity (PR number, issue number, path key, …)
  --source-sha        exact 40-hex commit/source SHA

EXIT
  0  success or idempotent no-op (identical existing event)
  2  usage / validation error (bad args, invalid gate/repo/SHA/time, hostile input)
  3  corrupt / unsafe storage (malformed JSONL, symlink/non-regular, conflict)
  4  lock or write failure (held lock, unwritable path, atomic rename failed)

SAFETY
  - Values are data only: no eval, no command interpolation, no shell metachar
    execution of ledger content.
  - Scalar argv: no control bytes, ANSI escapes, or newlines.
  - Paths: regular-file leaf only; refuse symlink/FIFO/device/directory targets.
  - Every stored event is re-validated (schema, types, gate, secrets, control,
    recomputed id) on read/list/add. Forged ids and noncanonical JSONL fail closed.
  - Lock before read/write (mkdir lock + ownership token). Same-directory temp +
    atomic rename. Append preserves exact existing byte prefix (never reorders).
  - Stale/held lock fails truthfully; never breaks another writer silently.
  - Never reclaim a symlinked lock path (victim bytes preserved).
  - Secret-like field names and values are refused.
EOF
}

die_usage() { echo "decision-ledger.sh: $*" >&2; exit 2; }
die_valid() { echo "decision-ledger.sh: $*" >&2; exit 2; }
die_corrupt() { echo "decision-ledger.sh: $*" >&2; exit 3; }
die_lock() { echo "decision-ledger.sh: $*" >&2; exit 4; }
info() { echo "decision-ledger.sh: $*" >&2; }

# ---------------------------------------------------------------------------
# Limits and patterns
# ---------------------------------------------------------------------------
MAX_SCALAR=4096
MAX_LEDGER_BYTES=$((8 * 1024 * 1024))
MAX_EVENTS=10000

REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
GATE_RE='^G([1-9]|1[0-6])$'
SHA_RE='^[0-9a-f]{40}$'
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
ID_RE='^[0-9a-f]{64}$'
SOURCE_TYPES='pr issue loop-state journal manual'
RISK_LEVELS='low medium high'
RECOMMENDS='Approve Decline Wait'

require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    die_valid "python3 is required for JSON/hashing; install python3 or put it on PATH"
  fi
}

# Reject control bytes, DEL, ANSI/escape introducers, and newlines in scalars.
# Empty is allowed only when caller permits (most fields require non-empty).
# Uses python3 so macOS Bash 3.2 / BSD grep need not parse \xHH classes.
validate_scalar() {
  local label="$1" value="$2" allow_empty="${3:-0}"
  if [[ -z "$value" ]]; then
    if [[ "$allow_empty" == "1" ]]; then
      return 0
    fi
    die_valid "$label must be non-empty"
  fi
  if [[ ${#value} -gt "$MAX_SCALAR" ]]; then
    die_valid "$label exceeds max length ($MAX_SCALAR)"
  fi
  # Secret-like field names (label is our argv name, not user free text — still check)
  case "$label" in
    *password*|*secret*|*token*|*api-key*|*api_key*|*private-key*|*credential*|*passwd*|*bearer*)
      die_valid "field name looks secret-like (refused): $label"
      ;;
  esac
  if ! python3 - "$label" "$value" <<'PY'
import re, sys
label, value = sys.argv[1], sys.argv[2]
for ch in value:
    o = ord(ch)
    if o < 32 or o == 127:
        sys.stderr.write(f"decision-ledger.sh: {label} contains control characters or newlines (refused)\n")
        sys.exit(1)
if "\x1b" in value:
    sys.stderr.write(f"decision-ledger.sh: {label} contains ANSI/escape sequences (refused)\n")
    sys.exit(1)
secret_value = re.compile(
    r"(-----BEGIN |sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})",
    re.I,
)
if secret_value.search(value):
    sys.stderr.write(f"decision-ledger.sh: {label} value looks secret-like (refused)\n")
    sys.exit(1)
sys.exit(0)
PY
  then
    exit 2
  fi
}

validate_path_arg() {
  local label="$1" path="$2"
  validate_scalar "$label" "$path"
  # Refuse any path component that is exactly ".." (path traversal).
  if printf '%s' "$path" | grep -E '(^|/)\.\.(/|$)' >/dev/null; then
    die_valid "$label rejects path traversal: $path"
  fi
}

# Path safety: normalize a trusted existing prefix physically (macOS /tmp,/var
# aliases), then require remaining components to be real non-symlink
# directories/files. Never follow planted ancestor or leaf symlinks.
# Prints the normalized absolute path on success.
# mode: file-missing-ok | file-required | dir-required
assert_path_safe() {
  local label="$1" path="$2" mode="$3"
  validate_path_arg "$label" "$path"
  case "$path" in
    /*) ;;
    *) path="$(pwd)/$path" ;;
  esac
  python3 - "$label" "$path" "$mode" <<'PY' || exit 3
import os, stat, sys

label, path, mode = sys.argv[1], sys.argv[2], sys.argv[3]

def fail(msg):
    sys.stderr.write(f"decision-ledger.sh: {label}: {msg}\n")
    sys.exit(3)

if not path or len(path) > 4096:
    fail("path empty or too long")
for ch in path:
    o = ord(ch)
    if o < 32 or o == 127:
        fail("path contains control characters")

# Collapse . and redundant slashes without resolving symlinks.
# Reject .. after normalization attempt via manual split.
norm = os.path.normpath(path)
if not os.path.isabs(norm):
    fail(f"path is not absolute after normalize: {norm}")
comps = [c for c in norm.split(os.sep) if c != ""]
if any(c in (".", "..") for c in comps):
    fail(f"path rejects . or .. components: {norm}")

# Known single-level system aliases (macOS /tmp -> private/tmp, /var -> private/var).
SYSTEM_ALIAS_ROOTS = {"/tmp", "/var"}

def is_system_alias(p):
    return p in SYSTEM_ALIAS_ROOTS

physical = os.sep  # verified real directory path
out_comps = []

for idx, comp in enumerate(comps):
    is_last = idx == len(comps) - 1
    if physical == os.sep:
        candidate = os.sep + comp
    else:
        candidate = physical + os.sep + comp

    try:
        st = os.lstat(candidate)
    except FileNotFoundError:
        # Missing: only allowed for trailing leaf when file-missing-ok, or for
        # intermediate dirs we will create under a verified physical parent.
        rest = comps[idx:]
        for r in rest:
            if r in ("", ".", "..") or "/" in r or "\0" in r:
                fail(f"unsafe missing component: {r!r}")
        if is_last:
            if mode != "file-missing-ok":
                fail(f"missing: {candidate}")
            out = candidate
            sys.stdout.write(out)
            sys.exit(0)
        # Intermediate missing — only OK when final leaf is file-missing-ok
        # (mkdir -p under physical parent). Refuse for required paths.
        if mode != "file-missing-ok":
            fail(f"missing ancestor: {candidate}")
        out = physical
        for r in rest:
            out = out + os.sep + r if out != os.sep else os.sep + r
        sys.stdout.write(out)
        sys.exit(0)
    except OSError as e:
        fail(f"cannot lstat {candidate}: {e}")

    if stat.S_ISLNK(st.st_mode):
        if is_last:
            fail(f"is a symlink (refuse; fail closed): {candidate}")
        # Intermediate symlink: allow only known system aliases, resolve once.
        if not is_system_alias(candidate):
            fail(f"planted ancestor symlink (refuse): {candidate}")
        try:
            real = os.path.realpath(candidate)
        except OSError as e:
            fail(f"cannot resolve system alias {candidate}: {e}")
        if os.path.islink(real):
            fail(f"system alias resolves to symlink: {real}")
        if not os.path.isdir(real):
            fail(f"system alias is not a directory: {real}")
        # realpath is trusted system prefix only
        physical = real
        continue

    if is_last:
        if mode == "dir-required":
            if not stat.S_ISDIR(st.st_mode):
                fail(f"is not a directory: {candidate}")
            sys.stdout.write(candidate)
            sys.exit(0)
        # file leaf
        if stat.S_ISDIR(st.st_mode):
            fail(f"is a directory (refuse): {candidate}")
        if stat.S_ISFIFO(st.st_mode):
            fail(f"is a FIFO (refuse; fail closed): {candidate}")
        if stat.S_ISSOCK(st.st_mode):
            fail(f"is a socket (refuse; fail closed): {candidate}")
        if stat.S_ISCHR(st.st_mode) or stat.S_ISBLK(st.st_mode):
            fail(f"is a device (refuse): {candidate}")
        if not stat.S_ISREG(st.st_mode):
            fail(f"is not a regular file (refuse): {candidate}")
        sys.stdout.write(candidate)
        sys.exit(0)

    # Intermediate must be a real directory (not symlink — already handled).
    if not stat.S_ISDIR(st.st_mode):
        fail(f"ancestor is not a directory: {candidate}")
    physical = candidate

sys.stdout.write(physical if physical != os.sep or not comps else (os.sep + os.sep.join(comps)))
sys.exit(0)
PY
}

refuse_unsafe_leaf() {
  local label="$1" path="$2" allow_missing="${3:-0}"
  local mode
  if [[ "$allow_missing" == "1" ]]; then
    mode="file-missing-ok"
  else
    mode="file-required"
  fi
  # assert_path_safe prints normalized path; discard for side-effect check
  assert_path_safe "$label" "$path" "$mode" >/dev/null
}

ensure_parent_dir() {
  local path="$1"
  local dir
  dir=$(dirname -- "$path")
  # Parent must not be a planted symlink (system aliases already normalized).
  # Create missing parents only under a verified physical ancestor.
  if [[ -L "$dir" ]]; then
    die_lock "parent directory is a symlink (refuse): $dir"
  fi
  if [[ ! -d "$dir" ]]; then
    # Validate we can safely create under existing physical prefix
    assert_path_safe "ledger-parent" "$dir" "file-missing-ok" >/dev/null || die_lock "unsafe parent path: $dir"
    mkdir -p -- "$dir" 2>/dev/null || die_lock "cannot create parent directory: $dir"
  fi
  if [[ -L "$dir" ]]; then
    die_lock "parent directory is a symlink after create: $dir"
  fi
  if [[ ! -d "$dir" ]]; then
    die_lock "parent is not a directory: $dir"
  fi
}

# ---------------------------------------------------------------------------
# mkdir lock (Bash 3.2). Ownership token; never reclaim through symlinks.
# ---------------------------------------------------------------------------
LOCK_DIR=""
LOCK_HELD=0
LOCK_TOKEN=""

_lock_is_real_dir() {
  local d="$1"
  [[ -n "$d" ]] || return 1
  [[ ! -L "$d" ]] || return 1
  [[ -d "$d" ]] || return 1
  return 0
}

_lock_remove_known_file() {
  # Remove only a known regular non-symlink file inside a real lock directory.
  local dir="$1" name="$2"
  local f="${dir}/${name}"
  if [[ -L "$f" ]]; then
    die_lock "lock file is a symlink (refuse reclaim/release): $f"
  fi
  if [[ -e "$f" ]]; then
    if [[ ! -f "$f" ]]; then
      die_lock "lock file is not a regular file (refuse): $f"
    fi
    rm -f -- "$f" 2>/dev/null || true
  fi
}

_lock_sleep() {
  # Portable short backoff. Fractional sleep is supported on macOS and Linux.
  # DECISION_LEDGER_LOCK_SLEEP overrides (tests/sensors); empty/invalid → 0.05s.
  # sleep 0 is too fast: validate+write under lock can take >1s, and 200 pure
  # spins exhaust in ~0.3s so concurrent appends fail closed incorrectly.
  local interval="${DECISION_LEDGER_LOCK_SLEEP:-0.05}"
  if ! [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    interval="0.05"
  fi
  sleep "$interval" 2>/dev/null || sleep 1
}

acquire_lock() {
  # Concurrent writers serialize here. Live holders are waited on (bounded);
  # dead pids are reclaimed only for real non-symlink lock directories we own
  # protocol for. Symlinked lock paths fail without deleting any victim byte.
  local parent tries=0 max_tries opid
  # Default: 200 × 0.05s ≈ 10s wall budget — enough for several serialized
  # validates/writes. Held-lock sensors override DECISION_LEDGER_LOCK_TRIES low.
  max_tries="${DECISION_LEDGER_LOCK_TRIES:-200}"
  if ! [[ "$max_tries" =~ ^[1-9][0-9]*$ ]]; then
    max_tries=200
  fi
  parent=$(dirname -- "$LOCK_DIR")
  if [[ -L "$parent" ]]; then
    # System alias parents are normalized earlier for LEDGER; lock sibling uses same parent.
    # If still a symlink here, refuse rather than mkdir through it into a foreign tree.
    die_lock "lock parent is a symlink (refuse): $parent"
  fi
  mkdir -p -- "$parent" 2>/dev/null || die_lock "cannot create lock parent: $parent"
  if [[ -L "$parent" ]] || [[ ! -d "$parent" ]]; then
    die_lock "lock parent is not a real directory: $parent"
  fi

  while [[ $tries -lt $max_tries ]]; do
    # Symlinked lock path: never mkdir, never cat, never rm through it.
    if [[ -L "$LOCK_DIR" ]]; then
      die_lock "ledger lock path is a symlink (refuse; not reclaiming): $LOCK_DIR"
    fi
    if [[ -e "$LOCK_DIR" && ! -d "$LOCK_DIR" ]]; then
      die_lock "ledger lock path exists and is not a directory: $LOCK_DIR"
    fi
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_TOKEN="$$-$(python3 -c 'import secrets; print(secrets.token_hex(16))' 2>/dev/null || printf '%s-%s' "$$" "$RANDOM$RANDOM")"
      # Write ownership before advertising readiness; fail closed on write errors.
      if ! printf '%s\n' "$LOCK_TOKEN" >"$LOCK_DIR/owner" 2>/dev/null; then
        _lock_remove_known_file "$LOCK_DIR" "owner"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        die_lock "cannot write lock owner token"
      fi
      if ! printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null; then
        _lock_remove_known_file "$LOCK_DIR" "pid"
        _lock_remove_known_file "$LOCK_DIR" "owner"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        die_lock "cannot write lock pid"
      fi
      if [[ -L "$LOCK_DIR" || -L "$LOCK_DIR/owner" || -L "$LOCK_DIR/pid" ]]; then
        die_lock "lock path became symlink after create (refuse)"
      fi
      LOCK_HELD=1
      return 0
    fi
    # Contended or pre-existing. Reclaim only when real dir + dead pid.
    if [[ -L "$LOCK_DIR" ]]; then
      die_lock "ledger lock path is a symlink (refuse; not reclaiming): $LOCK_DIR"
    fi
    if ! _lock_is_real_dir "$LOCK_DIR"; then
      tries=$((tries + 1))
      _lock_sleep
      continue
    fi
    if [[ -L "$LOCK_DIR/pid" ]]; then
      die_lock "lock pid path is a symlink (refuse): $LOCK_DIR/pid"
    fi
    opid=""
    if [[ -f "$LOCK_DIR/pid" ]]; then
      opid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    fi
    if [[ -n "$opid" && "$opid" =~ ^[0-9]+$ ]] && ! kill -0 "$opid" 2>/dev/null; then
      # Stale: revalidate still a real directory, remove only known files, rmdir.
      if [[ -L "$LOCK_DIR" ]] || [[ ! -d "$LOCK_DIR" ]]; then
        tries=$((tries + 1))
        _lock_sleep
        continue
      fi
      _lock_remove_known_file "$LOCK_DIR" "pid"
      _lock_remove_known_file "$LOCK_DIR" "owner"
      rmdir "$LOCK_DIR" 2>/dev/null || true
      # After reclaim, retry mkdir immediately (no sleep) so a waiter wins promptly.
      tries=$((tries + 1))
      continue
    fi
    # Live holder or empty-pid race (owner still writing token): backoff and retry.
    tries=$((tries + 1))
    _lock_sleep
  done
  if [[ -L "$LOCK_DIR" ]]; then
    die_lock "ledger lock path is a symlink (refuse): $LOCK_DIR"
  fi
  opid=""
  if _lock_is_real_dir "$LOCK_DIR" && [[ -f "$LOCK_DIR/pid" && ! -L "$LOCK_DIR/pid" ]]; then
    opid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  fi
  if [[ -n "$opid" && "$opid" =~ ^[0-9]+$ ]] && kill -0 "$opid" 2>/dev/null; then
    die_lock "ledger lock held by live pid $opid at $LOCK_DIR (wait budget exhausted)"
  fi
  die_lock "cannot acquire ledger lock at $LOCK_DIR (held or non-reclaimable; wait budget exhausted)"
}

release_lock() {
  if [[ "$LOCK_HELD" -ne 1 || -z "$LOCK_DIR" ]]; then
    LOCK_HELD=0
    return 0
  fi
  # Never delete a lock we do not own; never touch through a symlink.
  if [[ -L "$LOCK_DIR" ]]; then
    LOCK_HELD=0
    LOCK_TOKEN=""
    return 0
  fi
  if [[ ! -d "$LOCK_DIR" ]]; then
    LOCK_HELD=0
    LOCK_TOKEN=""
    return 0
  fi
  if [[ -n "$LOCK_TOKEN" ]]; then
    if [[ -L "$LOCK_DIR/owner" ]]; then
      LOCK_HELD=0
      LOCK_TOKEN=""
      return 0
    fi
    local cur=""
    if [[ -f "$LOCK_DIR/owner" ]]; then
      cur=$(cat "$LOCK_DIR/owner" 2>/dev/null || true)
    fi
    if [[ "$cur" != "$LOCK_TOKEN" ]]; then
      # Not our token — leave it alone.
      LOCK_HELD=0
      LOCK_TOKEN=""
      return 0
    fi
  fi
  if [[ -L "$LOCK_DIR" ]] || [[ ! -d "$LOCK_DIR" ]]; then
    LOCK_HELD=0
    LOCK_TOKEN=""
    return 0
  fi
  _lock_remove_known_file "$LOCK_DIR" "pid"
  _lock_remove_known_file "$LOCK_DIR" "owner"
  rmdir "$LOCK_DIR" 2>/dev/null || true
  LOCK_HELD=0
  LOCK_TOKEN=""
}

# ---------------------------------------------------------------------------
# Identity + JSON helpers (python3 argv only)
# ---------------------------------------------------------------------------

compute_id() {
  # Prints 64-hex sha256 of canonical identity tuple.
  local repo="$1" gate="$2" stype="$3" sid="$4" ssha="$5"
  python3 - "$repo" "$gate" "$stype" "$sid" "$ssha" <<'PY'
import hashlib, sys
repo, gate, stype, sid, ssha = sys.argv[1:6]
# Canonical tuple: explicit field order, exact bytes, trailing newline.
canonical = (
    "decision-ledger:v1\n"
    f"repo={repo}\n"
    f"gate={gate}\n"
    f"source_type={stype}\n"
    f"source_id={sid}\n"
    f"source_sha={ssha}\n"
)
h = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
sys.stdout.write(h)
PY
}

validate_utc_ts() {
  local ts="$1" label="$2"
  if ! printf '%s' "$ts" | grep -E "$TS_RE" >/dev/null; then
    die_valid "$label must be strict UTC YYYY-MM-DDTHH:MM:SSZ"
  fi
  python3 - "$ts" <<'PY' || die_valid "invalid calendar timestamp: $ts"
import sys
from datetime import datetime
ts = sys.argv[1]
try:
    datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
except ValueError:
    sys.exit(1)
sys.exit(0)
PY
}

# Build one canonical JSON event line (compact, sorted keys, no trailing spaces).
build_event_json() {
  python3 - <<'PY'
import json, os, sys

def req(k):
    v = os.environ.get(k, "")
    if v == "":
        sys.stderr.write(f"decision-ledger.sh: missing env for JSON field {k}\n")
        sys.exit(2)
    return v

event = {
    "schema": "decision-ledger:v1",
    "id": req("DL_ID"),
    "status": "PENDING",
    "repo": req("DL_REPO"),
    "gate": req("DL_GATE"),
    "source_type": req("DL_SOURCE_TYPE"),
    "source_id": req("DL_SOURCE_ID"),
    "source_sha": req("DL_SOURCE_SHA"),
    "created_at": req("DL_CREATED_AT"),
    "card": {
        "what": req("DL_WHAT"),
        "why_you": req("DL_WHY_YOU"),
        "risk_level": req("DL_RISK_LEVEL"),
        "risk_consequence": req("DL_RISK_CONSEQUENCE"),
        "risk_undo": req("DL_RISK_UNDO"),
        "recommend": req("DL_RECOMMEND"),
        "recommend_rationale": req("DL_RECOMMEND_RATIONALE"),
        "if_you_wait": req("DL_IF_YOU_WAIT"),
        "source_ref": req("DL_SOURCE_REF"),
    },
}
# Canonical compact JSON: sorted keys, no ASCII whitespace padding, UTF-8, one line.
line = json.dumps(event, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
sys.stdout.write(line)
sys.stdout.write("\n")
PY
}

# Shared Python validator for ledger bytes / path.
# argv: path mode [id_to_find]
# mode:
#   list     — validate + print events sorted by id (display only; never for write)
#   validate — validate only (no stdout body)
#   find-id  — validate; print MATCH_PRESENT + stored line, or MATCH_ABSENT
# Exit 3 on any corrupt/forged/noncanonical content.
_ledger_py_validate() {
  local path="$1" mode="$2" id_to_find="${3:-}"
  python3 - "$path" "$mode" "$id_to_find" "$MAX_EVENTS" "$MAX_SCALAR" <<'PY'
import hashlib, json, re, sys
from datetime import datetime

path, mode, id_to_find = sys.argv[1], sys.argv[2], sys.argv[3]
max_events = int(sys.argv[4])
max_scalar = int(sys.argv[5])

required_top = {
    "schema", "id", "status", "repo", "gate", "source_type",
    "source_id", "source_sha", "created_at", "card",
}
required_card = {
    "what", "why_you", "risk_level", "risk_consequence", "risk_undo",
    "recommend", "recommend_rationale", "if_you_wait", "source_ref",
}
source_types = {"pr", "issue", "loop-state", "journal", "manual"}
risks = {"low", "medium", "high"}
recommends = {"Approve", "Decline", "Wait"}
gate_re = re.compile(r"^G([1-9]|1[0-6])$")
repo_re = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
sha_re = re.compile(r"^[0-9a-f]{40}$")
id_re = re.compile(r"^[0-9a-f]{64}$")
ts_re = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
secret_value = re.compile(
    r"(-----BEGIN |sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})",
    re.I,
)
secret_key = re.compile(
    r"(password|secret|token|api[_-]?key|private[_-]?key|credential|passwd|bearer)",
    re.I,
)

def fail(msg):
    sys.stderr.write(f"decision-ledger.sh: {msg}\n")
    sys.exit(3)

def check_str(label, value, line_no):
    if not isinstance(value, str):
        fail(f"line {line_no}: {label} must be a JSON string (exact type)")
    if value == "":
        fail(f"line {line_no}: {label} must be non-empty")
    if len(value) > max_scalar:
        fail(f"line {line_no}: {label} exceeds max length")
    for ch in value:
        o = ord(ch)
        if o < 32 or o == 127:
            fail(f"line {line_no}: {label} contains control characters")
    if "\x1b" in value:
        fail(f"line {line_no}: {label} contains ANSI/escape sequences")
    if secret_value.search(value):
        fail(f"line {line_no}: {label} value looks secret-like (refused)")

def compute_id(repo, gate, stype, sid, ssha):
    canonical = (
        "decision-ledger:v1\n"
        f"repo={repo}\n"
        f"gate={gate}\n"
        f"source_type={stype}\n"
        f"source_id={sid}\n"
        f"source_sha={ssha}\n"
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()

try:
    with open(path, "rb") as f:
        raw = f.read()
except OSError as e:
    fail(f"cannot read ledger: {e}")

if not raw:
    if mode == "find-id":
        sys.stdout.write("MATCH_ABSENT\n")
    sys.exit(0)

# Invalid UTF-8 → corrupt storage exit 3
try:
    text = raw.decode("utf-8", errors="strict")
except UnicodeDecodeError as e:
    fail(f"invalid UTF-8 in ledger: {e}")

# Canonical JSONL: non-empty file must end with exactly one final newline.
# No blank/partial lines; exactly one canonical JSON object per line.
if not text.endswith("\n"):
    fail("ledger missing final newline (corrupt canonical JSONL)")
if text.endswith("\n\n"):
    fail("ledger has trailing blank line (corrupt canonical JSONL)")

lines = text.split("\n")
# split leaves a final empty string after trailing newline
if lines and lines[-1] == "":
    lines = lines[:-1]
if not lines:
    fail("ledger has newline but no events (corrupt)")

events = []
seen = {}  # id -> canonical json string

for line_no, line in enumerate(lines, 1):
    if line == "":
        fail(f"empty line at ledger line {line_no} (malformed JSONL)")
    if len(line) > 65536:
        fail(f"line {line_no} exceeds max length")
    try:
        obj = json.loads(line)
    except json.JSONDecodeError as e:
        fail(f"malformed JSON at line {line_no}: {e}")
    if not isinstance(obj, dict):
        fail(f"line {line_no}: event must be a JSON object")
    # Reject non-string keys (json module always str keys) and exact key set
    if set(obj.keys()) != required_top:
        missing = required_top - set(obj.keys())
        extra = set(obj.keys()) - required_top
        if missing:
            fail(f"line {line_no}: missing fields {sorted(missing)}")
        fail(f"line {line_no}: unknown or incomplete top-level fields (extra={sorted(extra)})")
    for k in obj.keys():
        if secret_key.search(k):
            fail(f"line {line_no}: secret-like key refused: {k}")

    if obj.get("schema") != "decision-ledger:v1":
        fail(f"line {line_no}: unknown or missing schema (want decision-ledger:v1)")
    if obj.get("status") != "PENDING":
        fail(f"line {line_no}: non-PENDING status refused (ledger is PENDING-only)")

    eid = obj.get("id")
    check_str("id", eid, line_no)
    if not id_re.match(eid):
        fail(f"line {line_no}: id must be 64 lowercase hex")

    for k in ("repo", "gate", "source_type", "source_id", "source_sha", "created_at"):
        check_str(k, obj.get(k), line_no)

    repo = obj["repo"]
    if not repo_re.match(repo) or repo.count("/") != 1:
        fail(f"line {line_no}: repo must be owner/name with safe characters")
    if ".." in repo or repo.startswith(".") or repo.endswith("."):
        fail(f"line {line_no}: repo rejects path-like forms")

    gate = obj["gate"]
    if not gate_re.match(gate):
        fail(f"line {line_no}: gate must be exact G1..G16 (no G01/G0/G17/case/spacing)")

    stype = obj["source_type"]
    if stype not in source_types:
        fail(f"line {line_no}: invalid source_type")

    sha = obj["source_sha"]
    if not sha_re.match(sha):
        fail(f"line {line_no}: source_sha must be 40 lowercase hex")

    created = obj["created_at"]
    if not ts_re.match(created):
        fail(f"line {line_no}: created_at must be strict UTC YYYY-MM-DDTHH:MM:SSZ")
    try:
        datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        fail(f"line {line_no}: created_at is not a valid calendar timestamp")

    # Recompute deterministic id; reject forged 64-hex ids
    expect_id = compute_id(repo, gate, stype, obj["source_id"], sha)
    if eid != expect_id:
        fail(f"line {line_no}: forged or mismatched id (recomputed identity does not match)")

    card = obj.get("card")
    if not isinstance(card, dict):
        fail(f"line {line_no}: card must be object")
    if set(card.keys()) != required_card:
        fail(f"line {line_no}: card fields must be exactly {sorted(required_card)}")
    for ck in required_card:
        if secret_key.search(ck):
            fail(f"line {line_no}: secret-like card key refused: {ck}")
        check_str(f"card.{ck}", card.get(ck), line_no)
    if card["risk_level"] not in risks:
        fail(f"line {line_no}: invalid risk_level")
    if card["recommend"] not in recommends:
        fail(f"line {line_no}: invalid recommend")

    # Canonical encoding: exact compact sorted JSON, no whitespace padding
    canon = json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    if line != canon:
        fail(f"line {line_no}: noncanonical JSON encoding (corrupt storage)")

    if eid in seen:
        if seen[eid] != canon:
            fail(f"duplicate id with conflicting payload: {eid}")
        # exact duplicate line — collapse for display
        continue
    seen[eid] = canon
    events.append(obj)
    if len(events) > max_events:
        fail(f"ledger exceeds max events ({max_events})")

if mode == "validate":
    sys.exit(0)

if mode == "find-id":
    if id_to_find in seen:
        # Compare against a candidate provided via env? For find we only know presence.
        # Caller uses MATCH and then events_equal separately. Emit MATCH_PRESENT + line.
        sys.stdout.write("MATCH_PRESENT\n")
        sys.stdout.write(seen[id_to_find] + "\n")
    else:
        sys.stdout.write("MATCH_ABSENT\n")
    sys.exit(0)

# mode == list: deterministic sort for display only (never persisted)
events.sort(key=lambda e: e["id"])
for e in events:
    sys.stdout.write(json.dumps(e, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    sys.stdout.write("\n")
sys.exit(0)
PY
}

read_validate_ledger() {
  local path="$1"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi
  refuse_unsafe_leaf "ledger" "$path" 0
  if [[ ! -r "$path" ]]; then
    die_corrupt "ledger unreadable: $path"
  fi
  local size
  size=$(wc -c < "$path" | tr -d '[:space:]')
  if [[ "$size" -gt "$MAX_LEDGER_BYTES" ]]; then
    die_corrupt "ledger exceeds max size ($MAX_LEDGER_BYTES bytes)"
  fi
  _ledger_py_validate "$path" "list"
}

validate_ledger_only() {
  local path="$1"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi
  refuse_unsafe_leaf "ledger" "$path" 0
  if [[ ! -r "$path" ]]; then
    die_corrupt "ledger unreadable: $path"
  fi
  local size
  size=$(wc -c < "$path" | tr -d '[:space:]')
  if [[ "$size" -gt "$MAX_LEDGER_BYTES" ]]; then
    die_corrupt "ledger exceeds max size ($MAX_LEDGER_BYTES bytes)"
  fi
  _ledger_py_validate "$path" "validate"
}

events_equal() {
  # Compare two event JSON lines for equality of identity + card fields.
  # created_at is not part of identity: same-content retry with a new timestamp
  # is still an idempotent no-op (first write's timestamp is kept on disk).
  local a="$1" b="$2"
  python3 - "$a" "$b" <<'PY'
import json, sys
a = json.loads(sys.argv[1])
b = json.loads(sys.argv[2])
keys = ("schema", "id", "status", "repo", "gate", "source_type", "source_id", "source_sha", "card")
for k in keys:
    if a.get(k) != b.get(k):
        sys.exit(1)
sys.exit(0)
PY
}

atomic_write_ledger() {
  # dest, content file. Preserves existing bytes on failure.
  # Content must be exact old prefix + optional one new line.
  local dest="$1" content_file="$2"
  local dir base tmp
  dir=$(dirname -- "$dest")
  base=$(basename -- "$dest")
  ensure_parent_dir "$dest"
  refuse_unsafe_leaf "ledger" "$dest" 1
  if [[ -L "$dir" ]]; then
    die_lock "ledger parent is a symlink: $dir"
  fi
  tmp=$(mktemp "${dir}/.${base}.XXXXXX") || die_lock "mktemp failed for $dest"
  if ! cat "$content_file" >"$tmp"; then
    rm -f -- "$tmp"
    die_lock "failed writing temp ledger"
  fi
  if [[ -L "$tmp" ]] || [[ ! -f "$tmp" ]]; then
    rm -f -- "$tmp"
    die_lock "temp ledger is not a regular file"
  fi
  # Revalidate new file fully before rename
  set +e
  _ledger_py_validate "$tmp" "validate"
  local vrc=$?
  set -e
  if [[ "$vrc" -ne 0 ]]; then
    rm -f -- "$tmp"
    die_corrupt "new ledger body failed validation before rename"
  fi
  # If dest existed, new body must preserve exact old byte prefix
  if [[ -f "$dest" && ! -L "$dest" ]]; then
    if ! python3 - "$dest" "$tmp" <<'PY'
import sys
old = open(sys.argv[1], "rb").read()
new = open(sys.argv[2], "rb").read()
if not new.startswith(old):
    sys.stderr.write("decision-ledger.sh: append would not preserve exact old ledger byte prefix\n")
    sys.exit(1)
# Exactly one new line appended (or identical for idempotent — caller avoids rewrite)
if len(new) < len(old):
    sys.exit(1)
sys.exit(0)
PY
    then
      rm -f -- "$tmp"
      die_corrupt "append does not preserve exact old ledger prefix"
    fi
  fi
  refuse_unsafe_leaf "ledger" "$dest" 1
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    die_lock "atomic rename failed for $dest"
  fi
  if [[ -L "$dest" ]] || [[ ! -f "$dest" ]]; then
    die_lock "ledger path unsafe after rename: $dest"
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

CMD=""
LEDGER=""
FORMAT="jsonl"
SHOW_ID=""

# add fields
REPO=""
GATE=""
SOURCE_TYPE=""
SOURCE_ID=""
SOURCE_SHA=""
CREATED_AT=""
WHAT=""
WHY_YOU=""
RISK_LEVEL=""
RISK_CONSEQUENCE=""
RISK_UNDO=""
RECOMMEND=""
RECOMMEND_RATIONALE=""
IF_YOU_WAIT=""
SOURCE_REF=""

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 2
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      add|list|status|show)
        if [[ -n "$CMD" ]]; then
          die_usage "multiple commands: $CMD and $1"
        fi
        CMD="$1"
        shift
        ;;
      approve|deny|approval|denial|accept|reject|answer|ingest|merge|authorize|resolve|close|settle|choose|select)
        die_usage "command '$1' is unsupported: this ledger records PENDING decisions only (no approval/ingestion)"
        ;;
      --ledger)
        [[ $# -ge 2 ]] || die_usage "--ledger requires a path"
        LEDGER="$2"
        shift 2
        ;;
      --format)
        [[ $# -ge 2 ]] || die_usage "--format requires jsonl|json|markdown"
        FORMAT="$2"
        shift 2
        ;;
      --id)
        [[ $# -ge 2 ]] || die_usage "--id requires a decision id"
        SHOW_ID="$2"
        shift 2
        ;;
      --repo)
        [[ $# -ge 2 ]] || die_usage "--repo requires owner/name"
        REPO="$2"
        shift 2
        ;;
      --gate)
        [[ $# -ge 2 ]] || die_usage "--gate requires G1..G16"
        GATE="$2"
        shift 2
        ;;
      --source-type)
        [[ $# -ge 2 ]] || die_usage "--source-type requires a type"
        SOURCE_TYPE="$2"
        shift 2
        ;;
      --source-id)
        [[ $# -ge 2 ]] || die_usage "--source-id requires an identity"
        SOURCE_ID="$2"
        shift 2
        ;;
      --source-sha)
        [[ $# -ge 2 ]] || die_usage "--source-sha requires 40-hex"
        SOURCE_SHA="$2"
        shift 2
        ;;
      --created-at)
        [[ $# -ge 2 ]] || die_usage "--created-at requires UTC timestamp"
        CREATED_AT="$2"
        shift 2
        ;;
      --what)
        [[ $# -ge 2 ]] || die_usage "--what requires text"
        WHAT="$2"
        shift 2
        ;;
      --why-you)
        [[ $# -ge 2 ]] || die_usage "--why-you requires text"
        WHY_YOU="$2"
        shift 2
        ;;
      --risk-level)
        [[ $# -ge 2 ]] || die_usage "--risk-level requires low|medium|high"
        RISK_LEVEL="$2"
        shift 2
        ;;
      --risk-consequence)
        [[ $# -ge 2 ]] || die_usage "--risk-consequence requires text"
        RISK_CONSEQUENCE="$2"
        shift 2
        ;;
      --risk-undo)
        [[ $# -ge 2 ]] || die_usage "--risk-undo requires text"
        RISK_UNDO="$2"
        shift 2
        ;;
      --recommend)
        [[ $# -ge 2 ]] || die_usage "--recommend requires Approve|Decline|Wait"
        RECOMMEND="$2"
        shift 2
        ;;
      --recommend-rationale)
        [[ $# -ge 2 ]] || die_usage "--recommend-rationale requires text"
        RECOMMEND_RATIONALE="$2"
        shift 2
        ;;
      --if-you-wait)
        [[ $# -ge 2 ]] || die_usage "--if-you-wait requires text"
        IF_YOU_WAIT="$2"
        shift 2
        ;;
      --source-ref)
        [[ $# -ge 2 ]] || die_usage "--source-ref requires text"
        SOURCE_REF="$2"
        shift 2
        ;;
      --status|--approve|--deny|--answer|--ingest)
        die_usage "option $1 unsupported: PENDING-only ledger (no approval/ingestion)"
        ;;
      --)
        shift
        break
        ;;
      -*)
        die_usage "unknown option: $1"
        ;;
      *)
        die_usage "unexpected argument: $1"
        ;;
    esac
  done
  [[ -n "$CMD" ]] || die_usage "missing command (add|list|status|show)"
}

default_ledger() {
  printf '%s\n' "$(pwd)/gibson/decision-ledger.jsonl"
}

in_list() {
  local needle="$1"
  shift
  local x
  for x in "$@"; do
    if [[ "$x" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

validate_add_fields() {
  validate_scalar "repo" "$REPO"
  if ! printf '%s' "$REPO" | grep -E "$REPO_RE" >/dev/null; then
    die_valid "repo must be owner/name with safe characters"
  fi
  case "$REPO" in
    */*/*)
      die_valid "repo rejects multi-slash forms"
      ;;
    .*/*|*/*.)
      die_valid "repo rejects path-like forms"
      ;;
    *..*)
      die_valid "repo rejects path traversal"
      ;;
  esac

  validate_scalar "gate" "$GATE"
  if ! printf '%s' "$GATE" | grep -E "$GATE_RE" >/dev/null; then
    die_valid "gate must be exact G1..G16 (uppercase G, no G0/G17)"
  fi

  validate_scalar "source-type" "$SOURCE_TYPE"
  # shellcheck disable=SC2086
  if ! in_list "$SOURCE_TYPE" $SOURCE_TYPES; then
    die_valid "source-type must be one of: $SOURCE_TYPES"
  fi

  validate_scalar "source-id" "$SOURCE_ID"
  validate_scalar "source-sha" "$SOURCE_SHA"
  # normalize SHA to lowercase for identity
  SOURCE_SHA=$(printf '%s' "$SOURCE_SHA" | tr 'A-F' 'a-f')
  if ! printf '%s' "$SOURCE_SHA" | grep -E "$SHA_RE" >/dev/null; then
    die_valid "source-sha must be exactly 40 hex characters"
  fi

  if [[ -z "$CREATED_AT" ]]; then
    CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  validate_scalar "created-at" "$CREATED_AT"
  validate_utc_ts "$CREATED_AT" "created-at"

  validate_scalar "what" "$WHAT"
  validate_scalar "why-you" "$WHY_YOU"
  validate_scalar "risk-level" "$RISK_LEVEL"
  # shellcheck disable=SC2086
  if ! in_list "$RISK_LEVEL" $RISK_LEVELS; then
    die_valid "risk-level must be low|medium|high"
  fi
  validate_scalar "risk-consequence" "$RISK_CONSEQUENCE"
  validate_scalar "risk-undo" "$RISK_UNDO"
  validate_scalar "recommend" "$RECOMMEND"
  # shellcheck disable=SC2086
  if ! in_list "$RECOMMEND" $RECOMMENDS; then
    die_valid "recommend must be Approve|Decline|Wait"
  fi
  validate_scalar "recommend-rationale" "$RECOMMEND_RATIONALE"
  validate_scalar "if-you-wait" "$IF_YOU_WAIT"
  validate_scalar "source-ref" "$SOURCE_REF"
}

cmd_add() {
  validate_add_fields
  local id event_line match_status match_line
  id=$(compute_id "$REPO" "$GATE" "$SOURCE_TYPE" "$SOURCE_ID" "$SOURCE_SHA")
  [[ -n "$id" && ${#id} -eq 64 ]] || die_valid "failed to compute decision id"

  export DL_ID="$id" DL_REPO="$REPO" DL_GATE="$GATE" \
    DL_SOURCE_TYPE="$SOURCE_TYPE" DL_SOURCE_ID="$SOURCE_ID" \
    DL_SOURCE_SHA="$SOURCE_SHA" DL_CREATED_AT="$CREATED_AT" \
    DL_WHAT="$WHAT" DL_WHY_YOU="$WHY_YOU" DL_RISK_LEVEL="$RISK_LEVEL" \
    DL_RISK_CONSEQUENCE="$RISK_CONSEQUENCE" DL_RISK_UNDO="$RISK_UNDO" \
    DL_RECOMMEND="$RECOMMEND" DL_RECOMMEND_RATIONALE="$RECOMMEND_RATIONALE" \
    DL_IF_YOU_WAIT="$IF_YOU_WAIT" DL_SOURCE_REF="$SOURCE_REF"
  event_line=$(build_event_json | tr -d '\n') || die_valid "failed to build event JSON"
  [[ -n "$event_line" ]] || die_valid "empty event JSON"

  acquire_lock

  # Under lock: validate old file, preserve exact bytes as prefix, append one line.
  if [[ -e "$LEDGER" || -L "$LEDGER" ]]; then
    set +e
    validate_ledger_only "$LEDGER"
    _dl_rc=$?
    set -e
    if [[ "$_dl_rc" -ne 0 ]]; then
      release_lock
      exit "${_dl_rc:-3}"
    fi
    # Find existing id in validated store
    local find_out
    find_out=$(mktemp "${TMPDIR:-/tmp}/gibson-dl-find.XXXXXX") || {
      release_lock
      die_lock "mktemp failed"
    }
    set +e
    _ledger_py_validate "$LEDGER" "find-id" "$id" >"$find_out"
    _dl_rc=$?
    set -e
    if [[ "$_dl_rc" -ne 0 ]]; then
      rm -f -- "$find_out"
      release_lock
      exit "${_dl_rc:-3}"
    fi
    match_status=$(head -n 1 "$find_out" | tr -d '\r')
    if [[ "$match_status" == "MATCH_PRESENT" ]]; then
      match_line=$(sed -n '2p' "$find_out")
      rm -f -- "$find_out"
      if events_equal "$match_line" "$event_line"; then
        release_lock
        info "idempotent no-op: decision $id already present (identical)"
        printf '%s\n' "$id"
        return 0
      fi
      release_lock
      die_corrupt "conflicting decision for id $id (same identity tuple, different card/immutable fields)"
    fi
    rm -f -- "$find_out"
  fi

  # Build new body: exact old bytes + one canonical line (or just the new line).
  local new_body
  new_body=$(mktemp "${TMPDIR:-/tmp}/gibson-dl-body.XXXXXX") || {
    release_lock
    die_lock "mktemp failed"
  }
  if [[ -f "$LEDGER" && ! -L "$LEDGER" ]]; then
    # Byte-exact copy of existing prefix
    if ! cat "$LEDGER" >"$new_body"; then
      rm -f -- "$new_body"
      release_lock
      die_lock "failed reading existing ledger for append"
    fi
  else
    : >"$new_body"
  fi
  # Append exactly one canonical JSON line
  if ! printf '%s\n' "$event_line" >>"$new_body"; then
    rm -f -- "$new_body"
    release_lock
    die_lock "failed assembling new ledger body"
  fi

  set +e
  atomic_write_ledger "$LEDGER" "$new_body"
  _dl_rc=$?
  set -e
  rm -f -- "$new_body"
  if [[ "$_dl_rc" -ne 0 ]]; then
    release_lock
    exit "${_dl_rc:-4}"
  fi

  release_lock
  info "appended PENDING decision $id gate=$GATE repo=$REPO"
  printf '%s\n' "$id"
}

cmd_list() {
  case "$FORMAT" in
    jsonl|json|markdown) ;;
    *) die_usage "--format must be jsonl|json|markdown" ;;
  esac
  acquire_lock
  local tmp_out
  tmp_out=$(mktemp "${TMPDIR:-/tmp}/gibson-dl-list.XXXXXX") || die_lock "mktemp failed"
  if [[ -e "$LEDGER" || -L "$LEDGER" ]]; then
    set +e
    read_validate_ledger "$LEDGER" >"$tmp_out"
    _dl_rc=$?
    set -e
    if [[ "$_dl_rc" -ne 0 ]]; then
      rm -f -- "$tmp_out"
      release_lock
      exit "${_dl_rc:-3}"
    fi
  else
    : >"$tmp_out"
  fi
  release_lock

  case "$FORMAT" in
    jsonl)
      cat "$tmp_out"
      ;;
    json)
      python3 - "$tmp_out" <<'PY'
import json, sys
path = sys.argv[1]
events = []
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            events.append(json.loads(line))
out = {"schema": "decision-ledger-list:v1", "count": len(events), "events": events}
sys.stdout.write(json.dumps(out, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
sys.stdout.write("\n")
PY
      ;;
    markdown)
      python3 - "$tmp_out" <<'PY'
import json, sys
path = sys.argv[1]
events = []
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            events.append(json.loads(line))
print(f"# Pending decisions ({len(events)})")
print()
if not events:
    print("_No pending owner decisions in the local ledger._")
    sys.exit(0)
for e in events:
    c = e["card"]
    print(f"## Decision `{e['id'][:12]}…` — {e['gate']} / {e['repo']}")
    print()
    print("```")
    print(f"WHAT:        {c['what']}")
    print(f"WHY YOU:     {c['why_you']} ({e['gate']})")
    print(f"RISK:        {c['risk_level'].capitalize()}. {c['risk_consequence']} Undo: {c['risk_undo']}.")
    print(f"RECOMMEND:   {c['recommend']}. {c['recommend_rationale']}")
    print(f"IF YOU WAIT: {c['if_you_wait']}")
    print(f"SOURCE:      {c['source_ref']} (sha {e['source_sha']})")
    print(f"ID:          {e['id']}")
    print("REPLY:       owner channel not wired in this offline slice — see issue #72.")
    print("```")
    print()
PY
      ;;
  esac
  rm -f -- "$tmp_out"
}

cmd_status() {
  acquire_lock
  local tmp_out count
  tmp_out=$(mktemp "${TMPDIR:-/tmp}/gibson-dl-status.XXXXXX") || die_lock "mktemp failed"
  if [[ -e "$LEDGER" || -L "$LEDGER" ]]; then
    set +e
    read_validate_ledger "$LEDGER" >"$tmp_out"
    _dl_rc=$?
    set -e
    if [[ "$_dl_rc" -ne 0 ]]; then
      rm -f -- "$tmp_out"
      release_lock
      exit "${_dl_rc:-3}"
    fi
  else
    : >"$tmp_out"
  fi
  release_lock
  count=$(wc -l < "$tmp_out" | tr -d '[:space:]')
  printf 'schema: decision-ledger-status:v1\n'
  printf 'pending: %s\n' "$count"
  printf 'ledger: %s\n' "$LEDGER"
  if [[ "$count" -gt 0 ]]; then
    printf 'ids:\n'
    python3 - "$tmp_out" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        print(f"  - {e['id']} {e['gate']} {e['repo']} {e['source_type']}:{e['source_id']}")
PY
  fi
  rm -f -- "$tmp_out"
}

cmd_show() {
  validate_scalar "id" "$SHOW_ID"
  SHOW_ID=$(printf '%s' "$SHOW_ID" | tr 'A-F' 'a-f')
  if ! printf '%s' "$SHOW_ID" | grep -E "$ID_RE" >/dev/null; then
    die_valid "id must be 64 lowercase hex"
  fi
  acquire_lock
  local tmp_out
  tmp_out=$(mktemp "${TMPDIR:-/tmp}/gibson-dl-show.XXXXXX") || die_lock "mktemp failed"
  if [[ -e "$LEDGER" || -L "$LEDGER" ]]; then
    set +e
    read_validate_ledger "$LEDGER" >"$tmp_out"
    _dl_rc=$?
    set -e
    if [[ "$_dl_rc" -ne 0 ]]; then
      rm -f -- "$tmp_out"
      release_lock
      exit "${_dl_rc:-3}"
    fi
  else
    : >"$tmp_out"
  fi
  release_lock
  local line
  line=$(grep -F "\"id\":\"$SHOW_ID\"" "$tmp_out" || true)
  rm -f -- "$tmp_out"
  if [[ -z "$line" ]]; then
    die_valid "decision not found: $SHOW_ID"
  fi
  printf '%s\n' "$line"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
require_python3
parse_args "$@"

if [[ -z "$LEDGER" ]]; then
  LEDGER=$(default_ledger)
fi
validate_path_arg "ledger" "$LEDGER"
# Resolve to absolute for lock sibling stability when relative
case "$LEDGER" in
  /*) ;;
  *) LEDGER="$(pwd)/$LEDGER" ;;
esac
# Path safety (system alias normalize + refuse planted symlinks / special leaves)
LEDGER=$(assert_path_safe "ledger" "$LEDGER" "file-missing-ok") || exit 3

LOCK_DIR="${LEDGER}.lock"
trap release_lock EXIT

case "$CMD" in
  add) cmd_add ;;
  list) cmd_list ;;
  status) cmd_status ;;
  show) cmd_show ;;
  *) die_usage "unknown command: $CMD" ;;
esac
