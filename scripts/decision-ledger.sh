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
  - Lock before read/write (mkdir lock). Same-directory temp + atomic rename.
  - Stale/held lock fails truthfully; never breaks another writer silently.
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
  if printf '%s' "$path" | grep -Eq '(^|/)\.\.(/|$)'; then
    die_valid "$label rejects path traversal: $path"
  fi
}

# Portable lstat: regular non-symlink file?
is_regular_file() {
  local p="$1"
  if [[ -L "$p" ]]; then
    return 1
  fi
  if [[ -f "$p" ]]; then
    return 0
  fi
  return 1
}

refuse_unsafe_leaf() {
  local label="$1" path="$2" allow_missing="${3:-0}"
  # Check symlink and FIFO/socket BEFORE any open/read (FIFO open blocks forever).
  if [[ -L "$path" ]]; then
    die_corrupt "$label is a symlink (refuse; fail closed): $path"
  fi
  if [[ -p "$path" ]]; then
    die_corrupt "$label is a FIFO (refuse; fail closed): $path"
  fi
  if [[ -S "$path" ]]; then
    die_corrupt "$label is a socket (refuse; fail closed): $path"
  fi
  if [[ -e "$path" ]]; then
    if [[ -d "$path" ]]; then
      die_corrupt "$label is a directory (refuse): $path"
    fi
    if [[ ! -f "$path" ]]; then
      die_corrupt "$label is not a regular file (device/special refused): $path"
    fi
  else
    if [[ "$allow_missing" != "1" ]]; then
      die_corrupt "$label missing: $path"
    fi
  fi
}

ensure_parent_dir() {
  local path="$1"
  local dir
  dir=$(dirname -- "$path")
  if [[ -L "$dir" ]]; then
    # Parent may be a symlink (macOS /var); only refuse if leaf would be weird.
    # Creating under a symlink parent is OK if final leaf is regular.
    :
  fi
  if [[ ! -d "$dir" ]]; then
    mkdir -p -- "$dir" 2>/dev/null || die_lock "cannot create parent directory: $dir"
  fi
  if [[ ! -d "$dir" ]]; then
    die_lock "parent is not a directory: $dir"
  fi
}

# ---------------------------------------------------------------------------
# mkdir lock (Bash 3.2). Stale reclaim only when recorded pid is dead.
# ---------------------------------------------------------------------------
LOCK_DIR=""
LOCK_HELD=0

acquire_lock() {
  # Concurrent writers serialize here. Live holders are waited on (bounded);
  # dead pids are reclaimed. After the wait budget, fail truthfully — never
  # break another writer silently and never truncate the ledger.
  # DECISION_LEDGER_LOCK_TRIES overrides the spin budget (sensors/tests).
  local parent tries=0 max_tries opid
  max_tries="${DECISION_LEDGER_LOCK_TRIES:-200}"
  # Guard: empty/non-numeric override must not create an infinite loop.
  if ! [[ "$max_tries" =~ ^[1-9][0-9]*$ ]]; then
    max_tries=200
  fi
  parent=$(dirname -- "$LOCK_DIR")
  mkdir -p -- "$parent" 2>/dev/null || die_lock "cannot create lock parent: $parent"
  while [[ $tries -lt $max_tries ]]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
      LOCK_HELD=1
      return 0
    fi
    opid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [[ -n "$opid" && "$opid" =~ ^[0-9]+$ ]] && ! kill -0 "$opid" 2>/dev/null; then
      # Stale: holder is dead. Reclaim carefully; another waiter may race.
      rm -f "$LOCK_DIR/pid" 2>/dev/null || true
      rmdir "$LOCK_DIR" 2>/dev/null || true
      tries=$((tries + 1))
      continue
    fi
    # Live holder or non-reclaimable shape: brief yield, then retry.
    # sleep 0 yields without multi-second stalls (Bash 3.2 / macOS portable).
    tries=$((tries + 1))
    sleep 0
  done
  opid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [[ -n "$opid" && "$opid" =~ ^[0-9]+$ ]] && kill -0 "$opid" 2>/dev/null; then
    die_lock "ledger lock held by live pid $opid at $LOCK_DIR (wait budget exhausted)"
  fi
  die_lock "cannot acquire ledger lock at $LOCK_DIR (held or non-reclaimable; wait budget exhausted)"
}

release_lock() {
  if [[ "$LOCK_HELD" -eq 1 && -n "$LOCK_DIR" ]]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
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
  if ! printf '%s' "$ts" | grep -Eq "$TS_RE"; then
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

# Parse and validate ledger file; print canonical JSONL of PENDING events sorted by id.
# Fails closed on any bad line, duplicate conflict, unknown schema, non-PENDING status.
read_validate_ledger() {
  local path="$1"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    # Empty ledger is valid
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
  python3 - "$path" "$MAX_EVENTS" <<'PY'
import json, sys

path = sys.argv[1]
max_events = int(sys.argv[2])
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

def fail(msg):
    sys.stderr.write(f"decision-ledger.sh: {msg}\n")
    sys.exit(3)

events = []
seen = {}  # id -> canonical json string

try:
    with open(path, "rb") as f:
        raw = f.read()
except OSError as e:
    fail(f"cannot read ledger: {e}")

if not raw:
    sys.exit(0)

# Truncation / missing final newline is still parseable line-by-line, but a
# mid-line cut that is not valid JSON fails closed.
text = raw.decode("utf-8", errors="strict")
lines = text.split("\n")
# Allow a single trailing empty line after final newline; refuse interior empties
# that would mean blank records, and refuse if file has no content after strip
# of only trailing newline handling.
line_no = 0
for line in lines:
    if line == "" and line_no == len(lines) - 1:
        # trailing newline after last event
        continue
    line_no += 1
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
    missing = required_top - set(obj.keys())
    if missing:
        fail(f"line {line_no}: missing fields {sorted(missing)}")
    extra = set(obj.keys()) - required_top
    if extra:
        fail(f"line {line_no}: unknown top-level fields {sorted(extra)}")
    if obj.get("schema") != "decision-ledger:v1":
        fail(f"line {line_no}: unknown or missing schema (want decision-ledger:v1)")
    if obj.get("status") != "PENDING":
        # This ledger only stores PENDING; any other status is corrupt / out of contract
        fail(f"line {line_no}: non-PENDING status refused (ledger is PENDING-only)")
    eid = obj.get("id")
    if not isinstance(eid, str) or len(eid) != 64 or any(c not in "0123456789abcdef" for c in eid):
        fail(f"line {line_no}: id must be 64 lowercase hex")
    for k in ("repo", "gate", "source_type", "source_id", "source_sha", "created_at"):
        if not isinstance(obj.get(k), str) or obj[k] == "":
            fail(f"line {line_no}: {k} must be non-empty string")
    card = obj.get("card")
    if not isinstance(card, dict):
        fail(f"line {line_no}: card must be object")
    if set(card.keys()) != required_card:
        fail(f"line {line_no}: card fields must be exactly {sorted(required_card)}")
    for ck in required_card:
        if not isinstance(card[ck], str) or card[ck] == "":
            fail(f"line {line_no}: card.{ck} must be non-empty string")
        if any(ord(c) < 32 or ord(c) == 127 for c in card[ck]):
            fail(f"line {line_no}: card.{ck} contains control characters")
    if obj["source_type"] not in source_types:
        fail(f"line {line_no}: invalid source_type")
    if card["risk_level"] not in risks:
        fail(f"line {line_no}: invalid risk_level")
    if card["recommend"] not in recommends:
        fail(f"line {line_no}: invalid recommend")
    gate = obj["gate"]
    if not (len(gate) >= 2 and gate[0] == "G"):
        fail(f"line {line_no}: invalid gate")
    try:
        gn = int(gate[1:])
    except ValueError:
        fail(f"line {line_no}: invalid gate")
    if gn < 1 or gn > 16:
        fail(f"line {line_no}: gate out of range G1..G16")
    sha = obj["source_sha"]
    if len(sha) != 40 or any(c not in "0123456789abcdef" for c in sha):
        fail(f"line {line_no}: source_sha must be 40 lowercase hex")
    # Canonical form for conflict detection
    canon = json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    if eid in seen:
        if seen[eid] != canon:
            fail(f"duplicate id with conflicting payload: {eid}")
        # exact duplicate line — skip re-add to events for list, but note ok
        continue
    seen[eid] = canon
    events.append(obj)
    if len(events) > max_events:
        fail(f"ledger exceeds max events ({max_events})")

# Deterministic sort by id
events.sort(key=lambda e: e["id"])
for e in events:
    sys.stdout.write(json.dumps(e, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    sys.stdout.write("\n")
sys.exit(0)
PY
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

atomic_append_or_replace() {
  # path, new full content via stdin. Preserves existing bytes on failure.
  local dest="$1"
  local dir base tmp
  dir=$(dirname -- "$dest")
  base=$(basename -- "$dest")
  ensure_parent_dir "$dest"
  refuse_unsafe_leaf "ledger" "$dest" 1
  tmp=$(mktemp "${dir}/.${base}.XXXXXX") || die_lock "mktemp failed for $dest"
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    die_lock "failed writing temp ledger"
  fi
  if [[ -L "$tmp" ]] || [[ ! -f "$tmp" ]]; then
    rm -f "$tmp"
    die_lock "temp ledger is not a regular file"
  fi
  # Re-check dest leaf before rename
  refuse_unsafe_leaf "ledger" "$dest" 1
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
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
  if ! printf '%s' "$REPO" | grep -Eq "$REPO_RE"; then
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
  if ! printf '%s' "$GATE" | grep -Eq "$GATE_RE"; then
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
  if ! printf '%s' "$SOURCE_SHA" | grep -Eq "$SHA_RE"; then
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
  local id event_line tmp_out match_line
  id=$(compute_id "$REPO" "$GATE" "$SOURCE_TYPE" "$SOURCE_ID" "$SOURCE_SHA")
  [[ -n "$id" && ${#id} -eq 64 ]] || die_valid "failed to compute decision id"

  export DL_ID="$id" DL_REPO="$REPO" DL_GATE="$GATE" \
    DL_SOURCE_TYPE="$SOURCE_TYPE" DL_SOURCE_ID="$SOURCE_ID" \
    DL_SOURCE_SHA="$SOURCE_SHA" DL_CREATED_AT="$CREATED_AT" \
    DL_WHAT="$WHAT" DL_WHY_YOU="$WHY_YOU" DL_RISK_LEVEL="$RISK_LEVEL" \
    DL_RISK_CONSEQUENCE="$RISK_CONSEQUENCE" DL_RISK_UNDO="$RISK_UNDO" \
    DL_RECOMMEND="$RECOMMEND" DL_RECOMMEND_RATIONALE="$RECOMMEND_RATIONALE" \
    DL_IF_YOU_WAIT="$IF_YOU_WAIT" DL_SOURCE_REF="$SOURCE_REF"
  # Command substitution strips trailing newlines — capture body without relying on them.
  event_line=$(build_event_json | tr -d '\n') || die_valid "failed to build event JSON"
  [[ -n "$event_line" ]] || die_valid "empty event JSON"

  acquire_lock
  # Validate existing ledger under lock
  tmp_out=$(mktemp "${TMPDIR:-/tmp}/gibson-dl-read.XXXXXX") || die_lock "mktemp failed"
  if [[ -e "$LEDGER" || -L "$LEDGER" ]]; then
    set +e
    read_validate_ledger "$LEDGER" > "$tmp_out"
    _dl_rc=$?
    set -e
    if [[ "$_dl_rc" -ne 0 ]]; then
      rm -f "$tmp_out"
      release_lock
      exit "${_dl_rc:-3}"
    fi
  else
    : > "$tmp_out"
  fi

  match_line=$(grep -F "\"id\":\"$id\"" "$tmp_out" 2>/dev/null || true)
  if [[ -n "$match_line" ]]; then
    # Exactly one match expected after validate (duplicates collapsed if identical)
    local count
    count=$(grep -c -F "\"id\":\"$id\"" "$tmp_out" || true)
    if [[ "$count" -gt 1 ]]; then
      rm -f "$tmp_out"
      release_lock
      die_corrupt "multiple events with id $id after validate"
    fi
    if events_equal "$match_line" "$event_line"; then
      rm -f "$tmp_out"
      release_lock
      info "idempotent no-op: decision $id already present (identical)"
      printf '%s\n' "$id"
      return 0
    fi
    # Conflict: same id, different payload
    rm -f "$tmp_out"
    release_lock
    die_corrupt "conflicting decision for id $id (same identity tuple, different card/immutable fields)"
  fi

  # Append via rewrite of validated events + new event (drops exact-dupe lines).
  # Build content in a temp file first — do NOT pipe into the writer function
  # (pipeline RHS is a subshell on Bash 3.2; die/exit codes and traps would fork).
  local new_body
  new_body=$(mktemp "${TMPDIR:-/tmp}/gibson-dl-body.XXXXXX") || die_lock "mktemp failed"
  {
    cat "$tmp_out"
    # Always terminate the JSONL record with a newline.
    printf '%s\n' "$event_line"
  } > "$new_body" || {
    rm -f "$tmp_out" "$new_body"
    release_lock
    die_lock "failed assembling new ledger body"
  }
  set +e
  atomic_append_or_replace "$LEDGER" < "$new_body"
  _dl_rc=$?
  set -e
  if [[ "$_dl_rc" -ne 0 ]]; then
    rm -f "$tmp_out" "$new_body"
    release_lock
    exit "${_dl_rc:-4}"
  fi

  rm -f "$tmp_out" "$new_body"
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
    read_validate_ledger "$LEDGER" > "$tmp_out"
    _dl_rc=$?
    set -e
    if [[ "$_dl_rc" -ne 0 ]]; then
      rm -f "$tmp_out"
      release_lock
      exit "${_dl_rc:-3}"
    fi
  else
    : > "$tmp_out"
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
  rm -f "$tmp_out"
}

cmd_status() {
  acquire_lock
  local tmp_out count
  tmp_out=$(mktemp "${TMPDIR:-/tmp}/gibson-dl-status.XXXXXX") || die_lock "mktemp failed"
  if [[ -e "$LEDGER" || -L "$LEDGER" ]]; then
    set +e
    read_validate_ledger "$LEDGER" > "$tmp_out"
    _dl_rc=$?
    set -e
    if [[ "$_dl_rc" -ne 0 ]]; then
      rm -f "$tmp_out"
      release_lock
      exit "${_dl_rc:-3}"
    fi
  else
    : > "$tmp_out"
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
  rm -f "$tmp_out"
}

cmd_show() {
  validate_scalar "id" "$SHOW_ID"
  SHOW_ID=$(printf '%s' "$SHOW_ID" | tr 'A-F' 'a-f')
  if ! printf '%s' "$SHOW_ID" | grep -Eq "$ID_RE"; then
    die_valid "id must be 64 lowercase hex"
  fi
  acquire_lock
  local tmp_out
  tmp_out=$(mktemp "${TMPDIR:-/tmp}/gibson-dl-show.XXXXXX") || die_lock "mktemp failed"
  if [[ -e "$LEDGER" || -L "$LEDGER" ]]; then
    set +e
    read_validate_ledger "$LEDGER" > "$tmp_out"
    _dl_rc=$?
    set -e
    if [[ "$_dl_rc" -ne 0 ]]; then
      rm -f "$tmp_out"
      release_lock
      exit "${_dl_rc:-3}"
    fi
  else
    : > "$tmp_out"
  fi
  release_lock
  local line
  line=$(grep -F "\"id\":\"$SHOW_ID\"" "$tmp_out" || true)
  rm -f "$tmp_out"
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

LOCK_DIR="${LEDGER}.lock"
trap release_lock EXIT

case "$CMD" in
  add) cmd_add ;;
  list) cmd_list ;;
  status) cmd_status ;;
  show) cmd_show ;;
  *) die_usage "unknown command: $CMD" ;;
esac
