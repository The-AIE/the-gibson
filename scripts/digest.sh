#!/usr/bin/env bash
# digest.sh — deterministic local owner-digest renderer (issue #72 offline slice)
#
# Reads only explicit local snapshot inputs. Never discovers live GitHub /
# Hermes / provider state. Never delivers, schedules, or ingests answers.
# Delivery adapters, cadence, credentials, and authenticated answer ingestion
# remain owner-gated; issue #72 stays open until Mark selects those.
#
# Portable on macOS Bash 3.2 and Linux. Requires python3 on PATH.
set -euo pipefail

usage() {
  cat <<'EOF'
digest.sh — deterministic local owner-digest renderer (offline)

WHAT IT DOES
  Renders a concise status section plus exactly one existing-format decision
  card per PENDING decision from a local decision ledger, sorted deterministically.
  Optional loop-state, journal, merged-since, and parked-work snapshots add
  facts only when supplied; missing/stale/unknown are labeled honestly.

  Default output is stdout (writes nothing). --output PATH uses same-directory
  atomic rename. --dry-run shows the render without changing the output target.

WHAT IT DOES NOT DO
  Never mutates the ledger, loop-state, journal, PR/issue/release state, or
  marks a decision answered/approved. Never calls gh, hermes, mail, webhooks,
  or network tools. Never executes HERMES_CMD / DIGEST_CMD.
  --ingest and delivery/channel flags are unsupported (owner-gated).

USAGE
  digest.sh --ledger PATH
            [--loop-state PATH] [--journal PATH]
            [--merged-since PATH] [--parked PATH]
            [--now YYYY-MM-DDTHH:MM:SSZ]
            [--period-start YYYY-MM-DDTHH:MM:SSZ]
            [--repo owner/name]
            [--format markdown|json]
            [--output PATH] [--dry-run]
  digest.sh --help

INPUT SNAPSHOTS (all local files; never live discovery)
  --ledger PATH         decision-ledger JSONL (required)
  --loop-state PATH     optional gibson/loop-state.md snapshot
  --journal PATH        optional gibson/journal.md snapshot
  --merged-since PATH   optional JSON snapshot of merges in period
  --parked PATH         optional JSON snapshot of parked work
  --now TS              injectable "now" (default: wall clock UTC)
  --period-start TS     activity window start (default: 7 days before --now)
  --repo owner/name     optional filter / label for multi-repo digests

OUTPUT
  --format markdown     default; human status + decision cards
  --format json         schema-versioned machine-readable digest
  --output PATH         write atomically (regular file only)
  --dry-run             render to stdout; leave --output bytes unchanged

EXIT
  0  rendered successfully (or dry-run success)
  2  usage / validation (bad flags, future timestamps, unsupported --ingest)
  3  corrupt / mismatched / unsafe inputs (malformed ledger/state/snapshots)
  4  output lock/write failure

OWNER-GATED BOUNDARY
  --ingest, --deliver, --channel, --hermes, --email, --imessage, --webhook,
  and HERMES_CMD/DIGEST_CMD are not supported here. Selecting channel,
  recipient, credentials, cadence, authorized responder, retention, replay
  protection, and a live canary remains Mark's decision on issue #72.
EOF
}

die_usage() { echo "digest.sh: $*" >&2; exit 2; }
die_valid() { echo "digest.sh: $*" >&2; exit 2; }
die_corrupt() { echo "digest.sh: $*" >&2; exit 3; }
die_write() { echo "digest.sh: $*" >&2; exit 4; }
info() { echo "digest.sh: $*" >&2; }

# Refuse to honor delivery hooks even if present in the environment.
if [[ -n "${HERMES_CMD:-}" ]]; then
  info "ignoring HERMES_CMD (delivery is owner-gated; not executed)"
fi
if [[ -n "${DIGEST_CMD:-}" ]]; then
  info "ignoring DIGEST_CMD (delivery is owner-gated; not executed)"
fi
# Never export or run them
unset HERMES_CMD DIGEST_CMD 2>/dev/null || true

MAX_SCALAR=4096
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'

require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    die_valid "python3 is required; install python3 or put it on PATH"
  fi
}

validate_scalar() {
  local label="$1" value="$2"
  if [[ -z "$value" ]]; then
    die_valid "$label must be non-empty"
  fi
  if [[ ${#value} -gt $MAX_SCALAR ]]; then
    die_valid "$label exceeds max length"
  fi
  if ! python3 - "$label" "$value" <<'PY'
import sys
label, value = sys.argv[1], sys.argv[2]
for ch in value:
    o = ord(ch)
    if o < 32 or o == 127:
        sys.stderr.write(f"digest.sh: {label} contains control characters or newlines\n")
        sys.exit(1)
if "\x1b" in value:
    sys.stderr.write(f"digest.sh: {label} contains ANSI/escape sequences\n")
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
  if printf '%s' "$path" | grep -Eq '(^|/)\.\.(/|$)'; then
    die_valid "$label rejects path traversal"
  fi
}

validate_utc_ts() {
  local ts="$1" label="$2"
  if ! printf '%s' "$ts" | grep -Eq "$TS_RE"; then
    die_valid "$label must be strict UTC YYYY-MM-DDTHH:MM:SSZ"
  fi
  python3 - "$ts" <<'PY' || die_valid "invalid calendar timestamp for $label: $ts"
import sys
from datetime import datetime
try:
    datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
except ValueError:
    sys.exit(1)
sys.exit(0)
PY
}

ts_to_epoch() {
  python3 - "$1" <<'PY'
import sys
from datetime import datetime, timezone
ts = datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
print(int(ts.timestamp()))
PY
}

# Path safety: normalize trusted system prefix physically (macOS /tmp,/var),
# then require remaining components are real non-symlink dirs/files.
# Checks type via lstat BEFORE any open/cat/hash/redirection (FIFO-safe).
# mode: file-required | file-missing-ok | dir-required
# exit_class: corrupt (3) | write (4)
assert_path_safe() {
  local label="$1" path="$2" mode="$3" exit_class="${4:-corrupt}"
  validate_path_arg "$label" "$path"
  case "$path" in
    /*) ;;
    *) path="$(pwd)/$path" ;;
  esac
  python3 - "$label" "$path" "$mode" "$exit_class" <<'PY' || exit $?
import os, stat, sys

label, path, mode, exit_class = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
code = 4 if exit_class == "write" else 3

def fail(msg):
    sys.stderr.write(f"digest.sh: {label}: {msg}\n")
    sys.exit(code)

if not path or len(path) > 4096:
    fail("path empty or too long")
for ch in path:
    if ord(ch) < 32 or ord(ch) == 127:
        fail("path contains control characters")

norm = os.path.normpath(path)
if not os.path.isabs(norm):
    fail(f"path is not absolute after normalize: {norm}")
comps = [c for c in norm.split(os.sep) if c != ""]
if any(c in (".", "..") for c in comps):
    fail(f"path rejects . or .. components: {norm}")

SYSTEM_ALIAS_ROOTS = {"/tmp", "/var"}
physical = os.sep

for idx, comp in enumerate(comps):
    is_last = idx == len(comps) - 1
    candidate = (os.sep + comp) if physical == os.sep else (physical + os.sep + comp)
    try:
        st = os.lstat(candidate)
    except FileNotFoundError:
        rest = comps[idx:]
        for r in rest:
            if r in ("", ".", "..") or "/" in r:
                fail(f"unsafe missing component: {r!r}")
        if is_last:
            if mode != "file-missing-ok":
                fail(f"missing: {candidate}")
            sys.stdout.write(candidate)
            sys.exit(0)
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
            fail(f"is a symlink (refuse): {candidate}")
        if candidate not in SYSTEM_ALIAS_ROOTS:
            fail(f"planted ancestor symlink (refuse): {candidate}")
        try:
            real = os.path.realpath(candidate)
        except OSError as e:
            fail(f"cannot resolve system alias {candidate}: {e}")
        if os.path.islink(real) or not os.path.isdir(real):
            fail(f"system alias unsafe: {real}")
        physical = real
        continue

    if is_last:
        if mode == "dir-required":
            if not stat.S_ISDIR(st.st_mode):
                fail(f"is not a directory: {candidate}")
            sys.stdout.write(candidate)
            sys.exit(0)
        if stat.S_ISDIR(st.st_mode):
            fail(f"is a directory (refuse): {candidate}")
        if stat.S_ISFIFO(st.st_mode):
            fail(f"is a FIFO (refuse; fail closed): {candidate}")
        if stat.S_ISSOCK(st.st_mode):
            fail(f"is a socket (refuse): {candidate}")
        if stat.S_ISCHR(st.st_mode) or stat.S_ISBLK(st.st_mode):
            fail(f"is a device (refuse): {candidate}")
        if not stat.S_ISREG(st.st_mode):
            fail(f"is not a regular file (refuse): {candidate}")
        sys.stdout.write(candidate)
        sys.exit(0)

    if not stat.S_ISDIR(st.st_mode):
        fail(f"ancestor is not a directory: {candidate}")
    physical = candidate

sys.stdout.write(physical)
sys.exit(0)
PY
}

refuse_unsafe_input() {
  local label="$1" path="$2"
  # Type check via lstat BEFORE any open/cat (FIFO open would block forever).
  assert_path_safe "$label" "$path" "file-required" "corrupt" >/dev/null
  if [[ ! -r "$path" ]]; then
    die_corrupt "$label unreadable: $path"
  fi
}

refuse_unsafe_output() {
  local path="$1"
  # Validate BEFORE any open/hash/cat/redirection (dry-run FIFO must not hang).
  assert_path_safe "output" "$path" "file-missing-ok" "write" >/dev/null
  local dir
  dir=$(dirname -- "$path")
  if [[ -L "$dir" ]]; then
    die_write "output parent is a symlink (refuse): $dir"
  fi
  if [[ ! -d "$dir" ]]; then
    die_write "output parent is not a directory: $dir"
  fi
}

LEDGER=""
LOOP_STATE=""
JOURNAL=""
MERGED_SINCE=""
PARKED=""
NOW_TS=""
PERIOD_START=""
REPO_FILTER=""
FORMAT="markdown"
OUTPUT=""
DRY_RUN=0

owner_gated_boundary() {
  local flag="$1"
  cat >&2 <<EOF
digest.sh: $flag is unsupported in this offline foundation slice.

Owner-gated boundary (issue #72 remains open): delivery channel, recipient,
credentials, cadence, authorized responder, retention, replay protection, and a
live canary must be selected by Mark before any ingest/delivery path is wired.

This tool only renders local snapshots. It does not send messages, schedule
jobs, execute HERMES_CMD/DIGEST_CMD, or record answers.
EOF
  exit 2
}

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
      --ledger)
        [[ $# -ge 2 ]] || die_usage "--ledger requires a path"
        LEDGER="$2"
        shift 2
        ;;
      --loop-state)
        [[ $# -ge 2 ]] || die_usage "--loop-state requires a path"
        LOOP_STATE="$2"
        shift 2
        ;;
      --journal)
        [[ $# -ge 2 ]] || die_usage "--journal requires a path"
        JOURNAL="$2"
        shift 2
        ;;
      --merged-since)
        [[ $# -ge 2 ]] || die_usage "--merged-since requires a path"
        MERGED_SINCE="$2"
        shift 2
        ;;
      --parked)
        [[ $# -ge 2 ]] || die_usage "--parked requires a path"
        PARKED="$2"
        shift 2
        ;;
      --now)
        [[ $# -ge 2 ]] || die_usage "--now requires a UTC timestamp"
        NOW_TS="$2"
        shift 2
        ;;
      --period-start)
        [[ $# -ge 2 ]] || die_usage "--period-start requires a UTC timestamp"
        PERIOD_START="$2"
        shift 2
        ;;
      --repo)
        [[ $# -ge 2 ]] || die_usage "--repo requires owner/name"
        REPO_FILTER="$2"
        shift 2
        ;;
      --format)
        [[ $# -ge 2 ]] || die_usage "--format requires markdown|json"
        FORMAT="$2"
        shift 2
        ;;
      --output)
        [[ $# -ge 2 ]] || die_usage "--output requires a path"
        OUTPUT="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --ingest|--deliver|--channel|--hermes|--email|--imessage|--webhook|--sms|--cron|--schedule)
        owner_gated_boundary "$1"
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
}

# Locate decision-ledger.sh next to this script for list validation reuse.
SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
LEDGER_TOOL="$SCRIPT_DIR/decision-ledger.sh"

render_digest() {
  # All paths validated; export for python
  export DG_LEDGER_JSONL="$1"
  export DG_NOW="$NOW_TS"
  export DG_PERIOD_START="$PERIOD_START"
  export DG_REPO_FILTER="${REPO_FILTER:-}"
  export DG_LOOP_STATE_SUMMARY="${LOOP_STATE_SUMMARY:-}"
  export DG_JOURNAL_SUMMARY="${JOURNAL_SUMMARY:-}"
  export DG_MERGED_JSON="${MERGED_JSON:-}"
  export DG_PARKED_JSON="${PARKED_JSON:-}"
  export DG_FORMAT="$FORMAT"
  export DG_LOOP_STATE_STATUS="${LOOP_STATE_STATUS:-missing}"
  export DG_JOURNAL_STATUS="${JOURNAL_STATUS:-missing}"
  export DG_MERGED_STATUS="${MERGED_STATUS:-missing}"
  export DG_PARKED_STATUS="${PARKED_STATUS:-missing}"

  python3 <<'PY'
import json, os, sys
from datetime import datetime, timezone

def fail(msg, code=3):
    sys.stderr.write(f"digest.sh: {msg}\n")
    sys.exit(code)

fmt = os.environ["DG_FORMAT"]
now_s = os.environ["DG_NOW"]
period_s = os.environ["DG_PERIOD_START"]
repo_filter = os.environ.get("DG_REPO_FILTER") or ""
ledger_path = os.environ["DG_LEDGER_JSONL"]

try:
    now = datetime.strptime(now_s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    period_start = datetime.strptime(period_s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
except ValueError as e:
    fail(f"bad timestamp: {e}", 2)

if period_start > now:
    fail("period-start must not be after --now", 2)

events = []
with open(ledger_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        # Future-created ledger decisions are corrupt/refused and never render.
        created = e.get("created_at")
        if not isinstance(created, str):
            fail("ledger event missing created_at string")
        try:
            cdt = datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            fail(f"ledger event created_at invalid: {created}")
        if cdt > now:
            fail(f"ledger decision created_at is in the future relative to --now: {created}")
        if repo_filter and e.get("repo") != repo_filter:
            continue
        events.append(e)
# Gate is G1..G16 — sort numerically so G6 precedes G12 (string sort would not).
# Sort for display only — never persisted.
events.sort(key=lambda e: (e["repo"], int(e["gate"][1:]), e["id"]))

def load_optional_json(raw, label, status):
    if status == "missing":
        return None, "missing"
    if status == "unknown":
        return None, "unknown"
    if status == "stale":
        return None, "stale"
    if not raw:
        return None, status
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError as e:
        fail(f"malformed {label} snapshot JSON: {e}")
    return obj, status

merged_raw = os.environ.get("DG_MERGED_JSON") or ""
parked_raw = os.environ.get("DG_PARKED_JSON") or ""
merged, merged_status = load_optional_json(merged_raw, "merged-since", os.environ.get("DG_MERGED_STATUS", "missing"))
parked, parked_status = load_optional_json(parked_raw, "parked", os.environ.get("DG_PARKED_STATUS", "missing"))

loop_status = os.environ.get("DG_LOOP_STATE_STATUS", "missing")
loop_summary = os.environ.get("DG_LOOP_STATE_SUMMARY") or ""
journal_status = os.environ.get("DG_JOURNAL_STATUS", "missing")
journal_summary = os.environ.get("DG_JOURNAL_SUMMARY") or ""

def parse_utc(label, value):
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty UTC timestamp string")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        fail(f"{label} is not valid strict UTC: {value}")

# Validate merged snapshot shape when present.
# A merge without valid merged_at, with future time, outside period, mismatched
# repo/source/SHA, or malformed type fails closed or is skipped; it can NEVER
# increment shipped count without a valid in-period merged_at.
ships = []
if merged is not None:
    if not isinstance(merged, dict) or merged.get("schema") != "digest-merged-since:v1":
        fail("merged-since snapshot must be object with schema digest-merged-since:v1")
    # Source identity required when snapshot is present
    snap_repo = merged.get("repo")
    if snap_repo is not None and snap_repo != "" and not isinstance(snap_repo, str):
        fail("merged-since repo must be a string")
    if repo_filter and snap_repo not in (None, "", repo_filter):
        fail(f"merged-since repo mismatch: snapshot={snap_repo} filter={repo_filter}")
    as_of = merged.get("as_of")
    if not as_of:
        fail("merged-since snapshot missing required as_of UTC timestamp")
    as_of_dt = parse_utc("merged-since as_of", as_of)
    if as_of_dt > now:
        fail("merged-since as_of is in the future relative to --now")
    if as_of_dt < period_start:
        # Snapshot itself is older than period: treat as stale/unknown, no ships.
        merged_status = "stale"
        ships = []
    else:
        items = merged.get("merges")
        if items is None:
            items = []
        if not isinstance(items, list):
            fail("merged-since merges must be a list")
        for m in items:
            if not isinstance(m, dict):
                fail("merged-since merge entry must be object")
            if repo_filter and m.get("repo") not in (None, "", repo_filter):
                fail("merged-since entry repo mismatch")
            if snap_repo and m.get("repo") not in (None, "", snap_repo):
                fail("merged-since entry repo mismatches snapshot source identity")
            mt = m.get("merged_at")
            if not mt:
                # Missing merged_at: fail closed — never count as shipped.
                fail("merged-since merge missing required merged_at")
            mdt = parse_utc("merged-since merge merged_at", mt)
            if mdt > now:
                fail("merged-since contains future merge timestamp")
            if mdt < period_start:
                # outside window — skip; does not increment shipped count
                continue
            if mdt > as_of_dt:
                fail("merged-since merge merged_at is after snapshot as_of")
            ships.append(m)

parked_items = []
if parked is not None:
    if not isinstance(parked, dict) or parked.get("schema") != "digest-parked:v1":
        fail("parked snapshot must be object with schema digest-parked:v1")
    if repo_filter and parked.get("repo") not in (None, "", repo_filter):
        fail(f"parked repo mismatch: snapshot={parked.get('repo')} filter={repo_filter}")
    as_of = parked.get("as_of")
    if not as_of:
        fail("parked snapshot missing required as_of UTC timestamp")
    as_of_dt = parse_utc("parked as_of", as_of)
    if as_of_dt > now:
        fail("parked as_of is in the future relative to --now")
    if as_of_dt < period_start:
        parked_status = "stale"
        parked_items = []
    else:
        items = parked.get("items")
        if items is None:
            items = []
        if not isinstance(items, list):
            fail("parked items must be a list")
        for p in items:
            if not isinstance(p, dict):
                fail("parked item must be object")
            if repo_filter and p.get("repo") not in (None, "", repo_filter):
                fail("parked entry repo mismatch")
            parked_items.append(p)

ship_count = len(ships)
pending_count = len(events)

# Quiet active week: period with activity context but zero ships still gets a status message
quiet_week = ship_count == 0

def status_lines():
    lines = []
    lines.append(f"Period: {period_s} → {now_s} (UTC)")
    if repo_filter:
        lines.append(f"Repo: {repo_filter}")
    else:
        lines.append("Repo: (all repos present in ledger / snapshots)")
    if quiet_week:
        lines.append(
            "Ships this period: 0 — quiet active week. "
            "Silence is not success and is not death; work may still be in flight."
        )
    else:
        lines.append(f"Ships this period: {ship_count}")
        for m in ships[:20]:
            title = m.get("title") or m.get("pr") or m.get("ref") or "(untitled)"
            lines.append(f"  - {title}")
    lines.append(f"Pending owner decisions: {pending_count}")
    # Loop health — stale/unknown never render as current healthy activity
    if loop_status == "missing":
        lines.append("Loop health: unknown (no loop-state snapshot supplied)")
    elif loop_status == "invalid":
        lines.append("Loop health: unknown (loop-state snapshot failed validation)")
    elif loop_status == "stale":
        lines.append(f"Loop health: unknown/stale ({loop_summary or 'updated before period-start'})")
    else:
        lines.append(f"Loop health: {loop_summary or 'present'}")
    if journal_status == "missing":
        lines.append("Journal: not supplied")
    elif journal_status == "invalid":
        lines.append("Journal: unknown (snapshot unreadable/invalid)")
    elif journal_status == "stale":
        lines.append(f"Journal: unknown/stale ({journal_summary or 'older than period-start'})")
    else:
        lines.append(f"Journal: {journal_summary or 'present'}")
    if parked_status == "missing":
        lines.append("Parked work: unknown (no parked snapshot supplied)")
    elif parked_status == "stale":
        lines.append("Parked work: unknown/stale (snapshot as_of before period-start)")
    elif parked_status == "empty":
        lines.append("Parked work: 0 items")
    else:
        lines.append(f"Parked work: {len(parked_items)} item(s)")
        for p in parked_items[:20]:
            reason = p.get("reason") or p.get("title") or p.get("pr") or "(parked)"
            lines.append(f"  - {reason}")
    if merged_status == "stale":
        lines.append("Ships source: unknown/stale (merged-since as_of before period-start)")
    lines.append(
        "Delivery/ingest: not wired (offline foundation). "
        "Issue #72 remains open for channel, credentials, cadence, and canary."
    )
    lines.append(
        "Invariants: unanswered cards never auto-approve and never block unrelated work."
    )
    return lines

def card_block(e):
    c = e["card"]
    lines = [
        "```",
        f"WHAT:        {c['what']}",
        f"WHY YOU:     {c['why_you']} ({e['gate']})",
        f"RISK:        {c['risk_level'].capitalize()}. {c['risk_consequence']} Undo: {c['risk_undo']}.",
        f"RECOMMEND:   {c['recommend']}. {c['recommend_rationale']}",
        f"IF YOU WAIT: {c['if_you_wait']}",
        f"SOURCE:      {c['source_ref']} (sha {e['source_sha']})",
        f"ID:          {e['id']}",
        "REPLY:       owner channel not wired in this offline slice — see issue #72.",
        "```",
    ]
    return lines

if fmt == "json":
    out = {
        "schema": "owner-digest:v1",
        "now": now_s,
        "period_start": period_s,
        "repo": repo_filter or None,
        "ships_this_period": ship_count,
        "quiet_active_week": quiet_week,
        "pending_count": pending_count,
        "loop_health": {"status": loop_status, "summary": loop_summary or None},
        "journal": {"status": journal_status, "summary": journal_summary or None},
        "merged_status": merged_status,
        "parked_status": parked_status,
        "parked_count": len(parked_items),
        "merges": ships,
        "parked": parked_items,
        "decisions": events,
        "invariants": {
            "no_auto_approve": True,
            "unanswered_never_blocks_unrelated": True,
            "delivery_owner_gated": True,
            "ingest_owner_gated": True,
        },
        "issue": 72,
        "phase": "offline-foundation",
    }
    sys.stdout.write(json.dumps(out, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    sys.stdout.write("\n")
    sys.exit(0)

# Markdown (required path)
print("# Owner digest (offline foundation)")
print()
print("## Status")
print()
for line in status_lines():
    print(f"- {line}")
print()
print("## Pending decisions")
print()
if not events:
    print("_No pending owner decisions in the local ledger._")
    print()
else:
    for e in events:
        print(f"### {e['gate']} · {e['repo']} · `{e['id'][:12]}…`")
        print()
        for line in card_block(e):
            print(line)
        print()
print("---")
print(
    "_Rendered locally from explicit snapshots. "
    "Not delivered. Not an approval. Related: #72._"
)
print()
PY
}

load_loop_state() {
  LOOP_STATE_STATUS="missing"
  LOOP_STATE_SUMMARY=""
  if [[ -z "$LOOP_STATE" ]]; then
    return 0
  fi
  refuse_unsafe_input "loop-state" "$LOOP_STATE"
  # Lightweight parse: do not require full validate-loop-state dependency for
  # optional snapshot, but fail closed on empty/symlink already done.
  if [[ ! -s "$LOOP_STATE" ]]; then
    LOOP_STATE_STATUS="invalid"
    LOOP_STATE_SUMMARY=""
    die_corrupt "loop-state snapshot is empty"
  fi
  # Extract key fields as data (no eval). Required: hat + strict UTC updated.
  local hat next_hat issue parked updated
  hat=$(grep -E '^hat:' "$LOOP_STATE" | head -1 | sed 's/^hat:[[:space:]]*//')
  next_hat=$(grep -E '^next_hat:' "$LOOP_STATE" | head -1 | sed 's/^next_hat:[[:space:]]*//')
  issue=$(grep -E '^issue:' "$LOOP_STATE" | head -1 | sed 's/^issue:[[:space:]]*//')
  parked=$(grep -E '^parked:' "$LOOP_STATE" | head -1 | sed 's/^parked:[[:space:]]*//')
  updated=$(grep -E '^updated:' "$LOOP_STATE" | head -1 | sed 's/^updated:[[:space:]]*//')
  if [[ -z "$hat" || -z "$updated" ]]; then
    die_corrupt "loop-state snapshot missing required hat/updated fields"
  fi
  # Facts older than period start are stale/unknown — never current healthy.
  if printf '%s' "$updated" | grep -Eq "$TS_RE"; then
    local up_epoch now_epoch period_epoch
    up_epoch=$(ts_to_epoch "$updated")
    now_epoch=$(ts_to_epoch "$NOW_TS")
    period_epoch=$(ts_to_epoch "$PERIOD_START")
    if [[ "$up_epoch" -gt "$now_epoch" ]]; then
      die_corrupt "loop-state updated is in the future relative to --now"
    fi
    if [[ "$up_epoch" -lt "$period_epoch" ]]; then
      LOOP_STATE_STATUS="stale"
      LOOP_STATE_SUMMARY="updated=${updated} before period-start=${PERIOD_START}"
      return 0
    fi
    LOOP_STATE_STATUS="ok"
    LOOP_STATE_SUMMARY="hat=${hat} next_hat=${next_hat:-?} issue=${issue:-?} parked=${parked:-?} updated=${updated}"
  else
    die_corrupt "loop-state updated is not valid UTC: ${updated:-empty}"
  fi
}

load_journal() {
  JOURNAL_STATUS="missing"
  JOURNAL_SUMMARY=""
  if [[ -z "$JOURNAL" ]]; then
    return 0
  fi
  refuse_unsafe_input "journal" "$JOURNAL"
  if [[ ! -s "$JOURNAL" ]]; then
    JOURNAL_STATUS="ok"
    JOURNAL_SUMMARY="empty journal file"
    return 0
  fi
  # Count section headers roughly; treat as opaque text (no eval)
  local lines sections
  lines=$(wc -l < "$JOURNAL" | tr -d '[:space:]')
  sections=$(grep -c -E '^## ' "$JOURNAL" 2>/dev/null || echo 0)
  sections=$(printf '%s' "$sections" | tr -d '[:space:]')
  JOURNAL_STATUS="ok"
  JOURNAL_SUMMARY="lines=${lines} sections≈${sections}"
}

load_merged() {
  MERGED_STATUS="missing"
  MERGED_JSON=""
  if [[ -z "$MERGED_SINCE" ]]; then
    return 0
  fi
  refuse_unsafe_input "merged-since" "$MERGED_SINCE"
  MERGED_JSON=$(cat "$MERGED_SINCE")
  MERGED_STATUS="ok"
}

load_parked() {
  PARKED_STATUS="missing"
  PARKED_JSON=""
  if [[ -z "$PARKED" ]]; then
    return 0
  fi
  refuse_unsafe_input "parked" "$PARKED"
  PARKED_JSON=$(cat "$PARKED")
  PARKED_STATUS="ok"
}

write_output() {
  local content_file="$1"
  if [[ -z "$OUTPUT" ]]; then
    cat "$content_file"
    return 0
  fi
  # Always validate output path type BEFORE any open/hash/cat of the target
  # (digest --dry-run --output FIFO must return promptly).
  refuse_unsafe_output "$OUTPUT"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "dry-run: would write $(wc -c < "$content_file" | tr -d '[:space:]') bytes to $OUTPUT (target unchanged)"
    cat "$content_file"
    return 0
  fi
  local dir base tmp
  dir=$(dirname -- "$OUTPUT")
  base=$(basename -- "$OUTPUT")
  if [[ -L "$dir" ]] || [[ ! -d "$dir" ]]; then
    die_write "output parent is not a real directory: $dir"
  fi
  tmp=$(mktemp "${dir}/.${base}.XXXXXX") || die_write "mktemp failed for output"
  if ! cat "$content_file" > "$tmp"; then
    rm -f -- "$tmp"
    die_write "failed writing temp output"
  fi
  if [[ -L "$tmp" ]] || [[ ! -f "$tmp" ]]; then
    rm -f -- "$tmp"
    die_write "temp output is not a regular file"
  fi
  refuse_unsafe_output "$OUTPUT"
  if ! mv -f -- "$tmp" "$OUTPUT"; then
    rm -f -- "$tmp"
    die_write "atomic rename failed for $OUTPUT"
  fi
  info "wrote digest to $OUTPUT"
}

# ---------------------------------------------------------------------------
main() {
  require_python3
  parse_args "$@"

  [[ -n "$LEDGER" ]] || die_usage "--ledger is required"
  validate_path_arg "ledger" "$LEDGER"
  [[ -f "$LEDGER_TOOL" ]] || die_valid "decision-ledger.sh not found next to digest.sh: $LEDGER_TOOL"

  case "$FORMAT" in
    markdown|json) ;;
    *) die_usage "--format must be markdown|json" ;;
  esac

  if [[ -n "$REPO_FILTER" ]]; then
    validate_scalar "repo" "$REPO_FILTER"
    if ! printf '%s' "$REPO_FILTER" | grep -Eq "$REPO_RE"; then
      die_valid "repo must be owner/name"
    fi
  fi

  if [[ -z "$NOW_TS" ]]; then
    NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  validate_scalar "now" "$NOW_TS"
  validate_utc_ts "$NOW_TS" "now"

  if [[ -z "$PERIOD_START" ]]; then
    PERIOD_START=$(python3 - "$NOW_TS" <<'PY'
import sys
from datetime import datetime, timedelta, timezone
now = datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
start = now - timedelta(days=7)
print(start.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)
  fi
  validate_scalar "period-start" "$PERIOD_START"
  validate_utc_ts "$PERIOD_START" "period-start"

  # Reject future --now vs wall clock only when not in pure test mode?
  # Spec: Reject future ... facts. Injected --now may be any valid past/present
  # relative to snapshots; wall-clock future --now is allowed for tests that set
  # the whole timeline. We reject snapshot facts after --now (done in python).

  if [[ -n "$OUTPUT" ]]; then
    validate_path_arg "output" "$OUTPUT"
    case "$OUTPUT" in
      /*) ;;
      *) OUTPUT="$(pwd)/$OUTPUT" ;;
    esac
    # Type-check BEFORE any later open/hash (FIFO/device/symlink fail promptly).
    OUTPUT=$(assert_path_safe "output" "$OUTPUT" "file-missing-ok" "write") || exit 4
  fi

  # Validate optional snapshot paths before opening (FIFO-safe).
  if [[ -n "$LOOP_STATE" ]]; then
    LOOP_STATE=$(assert_path_safe "loop-state" "$LOOP_STATE" "file-required" "corrupt") || exit 3
  fi
  if [[ -n "$JOURNAL" ]]; then
    JOURNAL=$(assert_path_safe "journal" "$JOURNAL" "file-required" "corrupt") || exit 3
  fi
  if [[ -n "$MERGED_SINCE" ]]; then
    MERGED_SINCE=$(assert_path_safe "merged-since" "$MERGED_SINCE" "file-required" "corrupt") || exit 3
  fi
  if [[ -n "$PARKED" ]]; then
    PARKED=$(assert_path_safe "parked" "$PARKED" "file-required" "corrupt") || exit 3
  fi

  # Validate ledger path type before decision-ledger opens it.
  LEDGER=$(assert_path_safe "ledger" "$LEDGER" "file-required" "corrupt") || exit 3

  # Validate ledger via decision-ledger list (read-only path uses lock + validate)
  # Globals for EXIT trap (locals are gone when EXIT fires under set -u).
  DG_LEDGER_JSONL_TMP=""
  DG_RENDER_TMP=""
  trap 'rm -f "${DG_LEDGER_JSONL_TMP:-}" "${DG_RENDER_TMP:-}"' EXIT

  DG_LEDGER_JSONL_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-digest-ledger.XXXXXX") || die_write "mktemp failed"

  set +e
  "$LEDGER_TOOL" list --ledger "$LEDGER" --format jsonl > "$DG_LEDGER_JSONL_TMP"
  _dg_rc=$?
  set -e
  if [[ "$_dg_rc" -ne 0 ]]; then
    die_corrupt "decision ledger validation failed (exit $_dg_rc)"
  fi

  load_loop_state
  load_journal
  load_merged
  load_parked

  DG_RENDER_TMP=$(mktemp "${TMPDIR:-/tmp}/gibson-digest-out.XXXXXX") || die_write "mktemp failed"
  set +e
  render_digest "$DG_LEDGER_JSONL_TMP" > "$DG_RENDER_TMP"
  _dg_rc=$?
  set -e
  if [[ "$_dg_rc" -ne 0 ]]; then
    exit "${_dg_rc:-3}"
  fi

  # Dry-run with regular-file output: prove target bytes preserved.
  # Path type already validated — never open FIFO/device for size/hash.
  if [[ "$DRY_RUN" -eq 1 && -n "$OUTPUT" && -e "$OUTPUT" && -f "$OUTPUT" && ! -L "$OUTPUT" ]]; then
    local before after sum_before="" sum_after
    before=$(wc -c < "$OUTPUT" | tr -d '[:space:]')
    if command -v shasum >/dev/null 2>&1; then
      sum_before=$(shasum -a 256 "$OUTPUT" | awk '{print $1}')
    fi
    write_output "$DG_RENDER_TMP"
    after=$(wc -c < "$OUTPUT" | tr -d '[:space:]')
    if [[ "$before" != "$after" ]]; then
      die_write "dry-run mutated output target size ($before -> $after)"
    fi
    if [[ -n "$sum_before" ]]; then
      sum_after=$(shasum -a 256 "$OUTPUT" | awk '{print $1}')
      if [[ "$sum_before" != "$sum_after" ]]; then
        die_write "dry-run mutated output target content"
      fi
    fi
  else
    write_output "$DG_RENDER_TMP"
  fi
}

main "$@"
