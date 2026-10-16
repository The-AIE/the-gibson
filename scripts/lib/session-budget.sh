#!/usr/bin/env bash
# session-budget.sh — finite session allowance for scripts/loop.sh (issue #409).
#
# Sourced by loop.sh and loop-fleet.sh. Not a standalone CLI.
#
# WHAT IT ENFORCES
#   A persisted allowance (gibson/session-budget.json) with session identity,
#   start time, and consumed starts. Defaults are 50 iterations, 480 minutes,
#   and USD 20. 0 on a dimension, or --unbounded, is an explicit opt-out and is
#   journaled. If that line cannot be written, the launch is refused and the
#   allowance created for it is removed. That removal is outside the engine
#   lock: a second launch that already resumed the file can lose it, and the
#   next reserve can start a fresh session. Ordinary relaunch resumes the
#   same allowance. Only
#   --reset-session-budget creates a fresh one. Under the allowance lock,
#   reset is refused while the recorded loop pid is still alive. An
#   interrupted start with no pid, or a pid that is not alive, is what that
#   flag discards. Ordinary relaunch still keeps that start consumed. The
#   reset line is written before either file is deleted. A crash after the
#   line and before either delete leaves the old allowance; the journal line
#   is not proof the files are gone, and the next ordinary launch resumes it.
#   A symlink or
#   non-regular journal or latch leaves the allowance unchanged. A dangling
#   latch is not a missing latch.
#   The stop latch
#   (gibson/session-budget-latch) and the journal receipt are one transaction
#   under the allowance lock: the latch is renamed into place first, then the
#   receipt is appended to the journal only if a final `receipt_end: <id>`
#   line is absent. A fragment that merely contains the receipt id is not
#   that line. The id is derived from the session id, the allowance id (the
#   persisted session id; the allowance schema has no second id), and the
#   stop reason. A later launch that finds the latch without that end line
#   publishes the stored snapshot once. A latched stop for a different lane
#   or repo is refused and does not publish. A launchd KeepAlive relaunch
#   that observes the latch does not start another runner or append another
#   receipt. Two launches that both enter during the lock race in LIMITS
#   can still publish two receipts.
#
# STOPS
#   Checked only at iteration boundaries (before a runner is started, and after
#   it has returned). The session budget never signals the runner. Per-iteration
#   kills stay with --runner-timeout. Wall time can therefore overshoot the cap
#   by the remainder of the last iteration.
#   Precedence when several limits are exhausted at the same boundary:
#   iterations, then wall, then cost. Halt, state-corrupt, error-budget, and
#   stale-budget still exit through their existing paths before this boundary.
#
# COST
#   Exact Decimal sum of JSON-string cost_usd values on gibson.cost.v1 ledger
#   events whose session_id equals this allowance. Tokens, ACUs, and flat_rate
#   are never converted to dollars. No matching cost_usd → "cost: not measured"
#   (not $0). Any matching cost_usd stays "partial": scripts/cost-ledger.sh
#   writes no cost_usd, no session_id, and no session-complete or session-closed
#   marker, so the ledger never certifies that every consumed start was measured.
#   Iteration coverage is not that certificate. One cost_usd event does not
#   establish complete session spend, and cost_status complete is not emitted.
#   The partial receipt names the summed amount and says "not every iteration
#   measured". A partial sum that reaches the cap stops; an unmeasured session
#   does not stop on cost. A metered runner records a line itself. The loop
#   exports GIBSON_SESSION_ID and GIBSON_SESSION_ITERATION before the runner
#   starts.
#
# LIMITS (honest)
#   The allowance file is local state writable by the same user and by the
#   runner. It is not a security boundary against that user. A backward clock
#   is clamped to zero elapsed so it does not instantly exhaust the wall cap.
#   Identity mismatch and a corrupt allowance refuse the launch (no fresh
#   budget) and journal every such launch; KeepAlive can repeat that journal
#   until the operator resets or fixes the invocation. An unreadable ledger
#   latches a distinct blocked state, exits nonzero, and does not grant a new
#   allowance; the next launch rechecks and stays quiet while it is still
#   unreadable.
#   runner_pid is loop.sh's pid, stored when a start is reserved and removed
#   when that start completes. Reset consults it only when it is a non-boolean
#   integer and kill(pid, 0) succeeds. A missing pid, any other JSON type, or
#   a pid that is not alive is an interrupted start. pid_alive treats EPERM as
#   not alive, the same way lock reclaim does. A recycled pid can look alive
#   until that other process exits.
#   The allowance lock is a directory plus a pid file. Two launches that
#   overlap after the directory exists and before that pid file is durable
#   can both enter. Counters can overwrite each other, and two receipts can
#   be published. That race, the opt-out discard race, and a crash between
#   the reset line and the delete are stated limits (The-AIE/the-gibson#499),
#   not closed here.
#
# Caller globals (loop.sh): STATE_DIR JOURNAL EXPECTED_REPO_SLUG MAX iter
#   plus info(). Limits: SB_LIMIT_ITERATIONS SB_LIMIT_WALL_MIN SB_LIMIT_COST_USD
#   SB_UNBOUNDED SB_RESET (all set by loop.sh before the first call).
# shellcheck disable=SC2154

# Result fields filled by sb_engine. Cleared at the start of each call.
SB_STATUS=""
SB_REASON=""
SB_MESSAGE=""
SB_SESSION_ID=""
SB_CREATED=""
SB_OPT_OUT=""
SB_ITERATION=""
SB_COST_STATUS=""
SB_COST_TEXT=""
SB_DIAGNOSIS=""

sb_allowance_path() { printf '%s/session-budget.json' "$STATE_DIR"; }
sb_latch_path() { printf '%s/session-budget-latch' "$STATE_DIR"; }

sb_lane_id() {
  local lane="${GIBSON_LANE_ID:-}"
  if [[ -z "$lane" ]]; then
    printf '%s' "solo"
    return 0
  fi
  printf '%s' "$lane"
}

# Run the engine. Controlled failures return status=fatal with exit 0.
# A nonzero python exit becomes status=fatal (cannot evaluate ≠ success).
sb_engine() {
  local op="$1"
  local err out rc line key val
  SB_STATUS=""
  SB_REASON=""
  SB_MESSAGE=""
  SB_SESSION_ID=""
  SB_CREATED=""
  SB_OPT_OUT=""
  SB_ITERATION=""
  SB_COST_STATUS=""
  SB_COST_TEXT=""
  SB_DIAGNOSIS=""
  err=$(mktemp "${TMPDIR:-/tmp}/gibson-sb.XXXXXX") || return 1
  local abs_state
  if [[ -z "${STATE_DIR:-}" ]]; then
    SB_STATUS="fatal"
    SB_MESSAGE="session budget state dir is unset"
    rm -f "$err"
    return 0
  fi
  mkdir -p -- "$STATE_DIR" || {
    SB_STATUS="fatal"
    SB_MESSAGE="cannot create session budget state dir"
    rm -f "$err"
    return 0
  }
  abs_state=$(CDPATH='' cd -- "$STATE_DIR" && pwd) || {
    SB_STATUS="fatal"
    SB_MESSAGE="cannot resolve session budget state dir"
    rm -f "$err"
    return 0
  }
  set +e
  out=$(
    # $$ is the sourcing shell (loop.sh), including inside this substitution.
    # Python's pid exits before the runner starts, so it cannot mark a live loop.
    SB_OP="$op" \
      SB_STATE_DIR="$abs_state" \
      SB_LIMIT_ITERATIONS="${SB_LIMIT_ITERATIONS:-}" \
      SB_LIMIT_WALL_MIN="${SB_LIMIT_WALL_MIN:-}" \
      SB_LIMIT_COST_USD="${SB_LIMIT_COST_USD:-}" \
      SB_UNBOUNDED="${SB_UNBOUNDED:-0}" \
      SB_RESET="${SB_RESET:-0}" \
      SB_LANE_ID="$(sb_lane_id)" \
      SB_REPO="${EXPECTED_REPO_SLUG:-}" \
      SB_LEDGER="${GIBSON_COST_LEDGER:-}" \
      SB_LEGACY_MAX="${SB_LEGACY_MAX:-}" \
      SB_LEGACY_ITER="${SB_LEGACY_ITER:-}" \
      SB_JOURNAL="${JOURNAL:-}" \
      SB_CRASH_AFTER_LATCH="${SB_CRASH_AFTER_LATCH:-}" \
      SB_HOLD_FILE="${SB_HOLD_FILE:-}" \
      SB_RELEASE_FILE="${SB_RELEASE_FILE:-}" \
      SB_JOURNAL_HOLD_FILE="${SB_JOURNAL_HOLD_FILE:-}" \
      SB_JOURNAL_RELEASE_FILE="${SB_JOURNAL_RELEASE_FILE:-}" \
      SB_LATCH_KIND="${SB_LATCH_KIND:-}" \
      SB_LATCH_REASON="${SB_LATCH_REASON:-}" \
      SB_LATCH_SESSION="${SB_LATCH_SESSION:-}" \
      SB_LOOP_PID="${SB_LOOP_PID:-$$}" \
      python3 - <<'PY'
import errno, hashlib, json, os, re, sys, tempfile, time
from datetime import datetime, timezone
from decimal import Decimal

OUT = {}

def setf(key, value):
    if value is None:
        OUT[key] = ""
        return
    text = str(value)
    if "\n" in text or "\r" in text:
        OUT["status"] = "fatal"
        OUT["message"] = "internal newline in field " + key
        return
    OUT[key] = text

def finish():
    order = [
        "status", "quiet", "reason", "message", "diagnosis", "session_id",
        "created", "opt_out", "iteration", "consumed", "completed", "elapsed",
        "overshoot", "cost_status", "cost_usd", "cost_text", "exhausted",
        "prs_merged", "prs_text", "previous_session_id", "started_at",
        "max_iterations", "max_wall_min", "max_cost_usd", "unbounded",
        "lane_id", "receipt_json",
    ]
    seen = set()
    for key in order:
        if key in OUT:
            sys.stdout.write(key + "=" + OUT[key] + "\n")
            seen.add(key)
    for key in sorted(OUT):
        if key not in seen:
            sys.stdout.write(key + "=" + OUT[key] + "\n")
    sys.exit(0)

def fatal(message):
    setf("status", "fatal")
    setf("quiet", "0")
    setf("message", message)
    finish()

# Canonical non-negative decimal: no exponent, no leading zeros, at most 18
# integer digits and 12 fractional digits. Inside that grammar the sum is
# exact Decimal. Outside it, fail closed — do not infer a value and do not
# treat the row as zero. 0.0000001 and amounts past 9 digits are inside it.
DEC_RE = re.compile(r"^(0|[1-9][0-9]{0,17})(\.[0-9]{1,12})?$")
LANE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")
SID_RE = re.compile(r"^sb-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")

def parse_cost_string(value, where):
    if isinstance(value, bool) or not isinstance(value, str):
        fatal(where + ": cost_usd must be a decimal string, not " + type(value).__name__)
    if not DEC_RE.match(value):
        fatal(where + ": cost_usd is not an exact non-negative decimal string")
    return Decimal(value)

def dec_str(value):
    text = format(value, "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text

def make_receipt_id(session_id, allowance_id, reason):
    # The allowance schema has no id besides session_id. allowance_id is that
    # session_id. The receipt id still mixes both fields with the reason so a
    # different reason cannot reuse the receipt.
    raw = "session=%s\nallowance=%s\nreason=%s" % (session_id, allowance_id, reason)
    return "sbr1-" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]

def env_int(name):
    raw = os.environ.get(name, "")
    if raw == "":
        fatal("missing " + name)
    if not re.match(r"^(0|[1-9][0-9]{0,8})$", raw):
        fatal("invalid integer " + name)
    return int(raw)

def now_utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def parse_started(text):
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        fatal("allowance started_at is not strict UTC")

state_dir = os.environ.get("SB_STATE_DIR", "")
if not state_dir or state_dir.startswith("/") is False:
    # Relative state dirs are refused so a latch cannot be planted elsewhere
    # by a confused caller. loop.sh always passes the target repo's gibson/.
    fatal("session budget state dir must be absolute")
allowance_path = os.path.join(state_dir, "session-budget.json")
latch_path = os.path.join(state_dir, "session-budget-latch")
lock_path = os.path.join(state_dir, "session-budget.lock")
journal_env = os.environ.get("SB_JOURNAL", "")
journal_path = journal_env if journal_env else os.path.join(state_dir, "journal.md")

def pid_alive(pid):
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True

def recorded_loop_pid():
    # SB_LOOP_PID is loop.sh. A non-integer must not be stored as a live pid.
    raw = os.environ.get("SB_LOOP_PID", "").strip()
    if not re.match(r"^[1-9][0-9]{0,9}$", raw):
        return None
    return int(raw)

def release_lock():
    pid_path = os.path.join(lock_path, "pid")
    try:
        current = int(open(pid_path, "r", encoding="utf-8").read().strip() or "0")
    except (OSError, ValueError):
        current = -1
    if current != os.getpid():
        return
    try:
        os.remove(pid_path)
    except OSError:
        pass
    try:
        os.rmdir(lock_path)
    except OSError:
        pass

def acquire_lock():
    os.makedirs(state_dir, exist_ok=True)
    deadline = time.time() + 5
    while True:
        try:
            os.mkdir(lock_path)
            fd = os.open(os.path.join(lock_path, "pid"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            os.write(fd, str(os.getpid()).encode("ascii"))
            os.fsync(fd)
            os.close(fd)
            return
        except FileExistsError:
            pid_path = os.path.join(lock_path, "pid")
            stale = True
            try:
                raw = open(pid_path, "r", encoding="utf-8").read().strip()
                stale = not (raw.isdigit() and pid_alive(int(raw)))
            except OSError:
                stale = True
            if stale:
                try:
                    os.remove(pid_path)
                except OSError:
                    pass
                try:
                    os.rmdir(lock_path)
                except OSError:
                    pass
                continue
            if time.time() > deadline:
                fatal("session budget lock held for 5s; refusing to start a runner")
            time.sleep(0.05)
        except OSError as exc:
            if exc.errno == errno.EEXIST:
                continue
            fatal("session budget lock failed: " + exc.strerror)

def atomic_write(path, data):
    if os.path.islink(path):
        fatal("refusing to write through a symlink: " + os.path.basename(path))
    parent = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", dir=parent)
    try:
        os.write(fd, data)
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(tmp, path)
        tmp = None
    finally:
        if fd is not None:
            os.close(fd)
        if tmp is not None:
            try:
                os.remove(tmp)
            except OSError:
                pass

def read_json_file(path, label):
    if os.path.islink(path):
        fatal(label + " is a symlink; refusing to follow it")
    try:
        raw = open(path, "r", encoding="utf-8").read()
    except OSError as exc:
        fatal(label + " unreadable: " + exc.strerror)
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        fatal(label + " is not JSON; refusing to start a fresh allowance")
    if not isinstance(doc, dict):
        fatal(label + " is not a JSON object")
    return doc

def load_allowance():
    if not os.path.exists(allowance_path):
        return None
    doc = read_json_file(allowance_path, "session allowance")
    if doc.get("schema") != "gibson.session-budget.allowance.v1":
        fatal("session allowance schema is not gibson.session-budget.allowance.v1")
    sid = doc.get("session_id")
    if not isinstance(sid, str) or not SID_RE.match(sid):
        fatal("session allowance has no valid session_id")
    for key in ("consumed_starts", "completed_iterations", "max_iterations", "max_wall_min"):
        value = doc.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            fatal("session allowance field " + key + " is not a non-negative integer")
    cap = doc.get("max_cost_usd")
    if not isinstance(cap, str) or not re.match(r"^(0|[1-9][0-9]{0,8})$", cap):
        fatal("session allowance max_cost_usd is not a whole-dollar string")
    if not isinstance(doc.get("started_at"), str):
        fatal("session allowance missing started_at")
    if not isinstance(doc.get("lane_id"), str) or not LANE_RE.match(doc["lane_id"]):
        fatal("session allowance lane_id is invalid")
    if not isinstance(doc.get("repo"), str) or not doc["repo"]:
        fatal("session allowance repo is invalid")
    if not isinstance(doc.get("unbounded"), bool):
        fatal("session allowance unbounded flag is invalid")
    if doc["completed_iterations"] > doc["consumed_starts"]:
        fatal("session allowance completed_iterations exceeds consumed starts")
    return doc

def load_latch():
    # lexists: a dangling symlink is a latch path, not a missing latch.
    # exists() follows the link and would let a reserve create a new allowance.
    if not os.path.lexists(latch_path):
        return None
    if os.path.islink(latch_path) or not os.path.isfile(latch_path):
        fatal("session budget latch is not a regular file")
    doc = {}
    try:
        lines = open(latch_path, "r", encoding="utf-8").read().splitlines()
    except OSError as exc:
        fatal("session budget latch unreadable: " + exc.strerror)
    for line in lines:
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        doc[key] = value
    kind = doc.get("kind", "")
    if kind not in ("exhausted", "unreadable"):
        fatal("session budget latch kind is invalid")
    if doc.get("journaled") not in ("0", "1"):
        fatal("session budget latch journaled flag is invalid")
    return doc

def write_allowance(doc):
    payload = json.dumps(doc, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
    atomic_write(allowance_path, payload)

def write_latch(kind, reason, session_id, journaled, extra=None):
    lines = [
        "schema=gibson.session-budget.latch.v1",
        "kind=%s" % kind,
        "reason=%s" % reason,
        "session_id=%s" % session_id,
        "journaled=%s" % journaled,
    ]
    if extra:
        for key in sorted(extra):
            value = extra[key]
            if not isinstance(value, str):
                value = str(value)
            if "\n" in value or "\r" in value or "\n" in key or "=" in key:
                fatal("invalid latch field " + key)
            lines.append("%s=%s" % (key, value))
    atomic_write(latch_path, ("\n".join(lines) + "\n").encode("utf-8"))

SNAPSHOT_KEYS = (
    "diagnosis", "lane_id", "repo", "started_at", "iterations_completed", "in_flight",
    "starts_consumed", "wall_seconds", "wall_overshoot_seconds",
    "iteration_budget", "wall_budget_min", "cost_budget_usd", "cost_text",
    "cost_status", "prs_text", "exhausted", "receipt_json", "receipt_id",
    "allowance_id",
)

def journal_has_receipt(receipt_id):
    # Positive evidence is the final receipt_end line, not a substring of the
    # receipt id. A torn or planted fragment can contain "receipt_id" and
    # still be incomplete.
    if not isinstance(receipt_id, str) or not receipt_id:
        return False
    if "\n" in receipt_id or "\r" in receipt_id:
        return False
    if os.path.islink(journal_path) or not os.path.isfile(journal_path):
        return False
    marker = "receipt_end: " + receipt_id
    try:
        lines = open(journal_path, "r", encoding="utf-8").read().splitlines()
    except OSError as exc:
        fatal("session budget journal unreadable: " + exc.strerror)
    return marker in lines

def append_journal(text):
    # Append only the new bytes. Replacing the file dropped a line another
    # writer added after this function had read the old contents. A crash can
    # leave a partial tail. A receipt is published only when its receipt_end
    # line is present, so the next launch writes that stored receipt once.
    if os.path.islink(journal_path):
        fatal("session budget journal is a symlink")
    parent = os.path.dirname(journal_path) or "."
    try:
        os.makedirs(parent, exist_ok=True)
    except OSError as exc:
        fatal("session budget journal directory failed: " + (exc.strerror or "unknown"))
    if os.path.lexists(journal_path):
        if os.path.islink(journal_path) or not os.path.isfile(journal_path):
            fatal("session budget journal is not a regular file")
    else:
        flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(journal_path, flags, 0o644)
        except OSError as exc:
            fatal("session budget journal create failed: " + (exc.strerror or "unknown"))
        try:
            os.write(fd, b"# Gibson loop journal\n")
            os.fsync(fd)
        finally:
            os.close(fd)
    maybe_journal_hold()
    flags = os.O_APPEND | os.O_WRONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = None
    try:
        fd = os.open(journal_path, flags)
        view = text.encode("utf-8")
        while view:
            wrote = os.write(fd, view)
            if wrote <= 0:
                raise OSError("short write")
            view = view[wrote:]
        os.fsync(fd)
    except OSError as exc:
        fatal("session budget journal write failed: " + (getattr(exc, "strerror", None) or str(exc)))
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass

def render_receipt(fields):
    cost_status = fields["cost_status"]
    lines = [
        "",
        "## %s · session-budget" % now_utc(),
        "diagnosis: %s" % fields["diagnosis"],
        "session_id: %s" % fields["session_id"],
        "lane_id: %s" % fields["lane_id"],
        "started_at: %s" % fields["started_at"],
        "iterations_completed: %s" % fields["iterations_completed"],
        "in_flight: %s" % fields["in_flight"],
        "starts_consumed: %s" % fields["starts_consumed"],
        "wall_seconds: %s" % fields["wall_seconds"],
        "wall_overshoot_seconds: %s" % fields["wall_overshoot_seconds"],
        "iteration_budget: %s" % fields["iteration_budget"],
        "wall_budget_min: %s" % fields["wall_budget_min"],
        "cost_budget_usd: %s" % fields["cost_budget_usd"],
        "receipt_id: %s" % fields["receipt_id"],
        fields["cost_text"],
        "cost_status: %s" % cost_status,
        fields["prs_text"],
        "exhausted: %s" % fields["exhausted"],
        "note: stopped at an iteration boundary. The session budget does not kill the runner. Per-iteration kills stay with --runner-timeout. Wall time can overshoot the cap by the remainder of the last iteration.",
    ]
    if cost_status == "not_measured":
        lines.append(
            "note: cost: not measured. Flat-rate or pool runners report no cost_usd. "
            "That is not $0. Iterations and wall-clock still bound the session."
        )
    elif cost_status == "partial":
        lines.append(
            "note: cost is partial; not every iteration measured. Measured dollars "
            "are not a complete session total. One cost_usd event does not establish "
            "complete session spend."
        )
    lines.append(fields["receipt_json"])
    # Last line. journal_has_receipt matches this exact line and nothing earlier.
    lines.append("receipt_end: %s" % fields["receipt_id"])
    return "\n".join(lines) + "\n"

def require_snapshot(fields):
    for key in SNAPSHOT_KEYS:
        if key not in fields or fields[key] == "":
            fatal("session budget latch missing " + key)
    needle = '"receipt_id":"%s"' % fields["receipt_id"]
    if needle not in fields["receipt_json"]:
        fatal("session budget latch receipt does not carry its receipt id")

def latch_extra(fields):
    skip = {"schema", "kind", "reason", "session_id", "journaled"}
    extra = {}
    for key in SNAPSHOT_KEYS:
        if key in skip:
            continue
        extra[key] = fields[key]
    return extra

def maybe_test_hold():
    # Test-only. Unset in production. Holds the allowance lock so a second
    # boundary can block before this stop publishes.
    hold = os.environ.get("SB_HOLD_FILE", "")
    if not hold:
        return
    release = os.environ.get("SB_RELEASE_FILE", "")
    try:
        fd = os.open(hold, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
        os.write(fd, b"held\n")
        os.fsync(fd)
        os.close(fd)
    except OSError as exc:
        fatal("session budget test hold failed: " + exc.strerror)
    deadline = time.time() + 8
    while time.time() < deadline:
        if release and os.path.exists(release):
            return
        time.sleep(0.02)
    fatal("session budget test hold expired")

def maybe_journal_hold():
    # Test-only. Pauses before the receipt bytes are appended, so a
    # concurrent journal line can land and must still be there afterwards.
    hold = os.environ.get("SB_JOURNAL_HOLD_FILE", "")
    if not hold:
        return
    release = os.environ.get("SB_JOURNAL_RELEASE_FILE", "")
    try:
        fd = os.open(hold, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
        os.write(fd, b"held\n")
        os.fsync(fd)
        os.close(fd)
    except OSError as exc:
        fatal("session budget journal hold failed: " + exc.strerror)
    deadline = time.time() + 8
    while time.time() < deadline:
        if release and os.path.exists(release):
            return
        time.sleep(0.02)
    fatal("session budget journal hold expired")

def commit_stop(doc, reason):
    # Lock is already held by acquire_lock. Latch first (atomic rename), then
    # the receipt. A crash between the two leaves the snapshot in the latch;
    # the next launch publishes that snapshot once.
    maybe_test_hold()
    fields = {
        "session_id": doc["session_id"],
        "reason": reason,
        "diagnosis": OUT["diagnosis"],
        "lane_id": OUT["lane_id"],
        "repo": doc["repo"],
        "started_at": OUT["started_at"],
        "iterations_completed": OUT["completed"],
        "in_flight": OUT["in_flight"],
        "starts_consumed": OUT["consumed"],
        "wall_seconds": OUT["elapsed"],
        "wall_overshoot_seconds": OUT["overshoot"],
        "iteration_budget": OUT["max_iterations"],
        "wall_budget_min": OUT["max_wall_min"],
        "cost_budget_usd": OUT["max_cost_usd"],
        "cost_text": OUT["cost_text"],
        "cost_status": OUT["cost_status"],
        "prs_text": OUT["prs_text"],
        "exhausted": OUT["exhausted"],
        "receipt_json": OUT["receipt_json"],
        "receipt_id": OUT["receipt_id"],
        "allowance_id": OUT["allowance_id"],
    }
    require_snapshot(fields)
    extra = latch_extra(fields)
    write_latch("exhausted", reason, doc["session_id"], "0", extra)
    if os.environ.get("SB_CRASH_AFTER_LATCH") == "1":
        # Test hook: latch is durable, receipt is not. os._exit skips the
        # lock release; the next launch reclaims the dead pid.
        os._exit(137)
    if not journal_has_receipt(fields["receipt_id"]):
        append_journal(render_receipt(fields))
    write_latch("exhausted", reason, doc["session_id"], "1", extra)
    setf("status", "stop")
    setf("quiet", "1")

def check_latch_identity(latch, want):
    # A latched stop is still this allowance. A different lane or repo must
    # get the same refusal as a live allowance, not a clean budget stop.
    if not LANE_RE.match(want["lane_id"]):
        fatal("GIBSON_LANE_ID is not a lane id")
    if not want["repo"]:
        fatal("session budget requires a repo slug")
    lane = latch.get("lane_id", "")
    repo = latch.get("repo", "")
    if not isinstance(lane, str) or not lane or not isinstance(repo, str) or not repo:
        fatal("session budget latch missing lane_id or repo")
    if lane != want["lane_id"] or repo != want["repo"]:
        fatal(
            "refusing to resume session %s for lane %s repo %s; allowance is lane %s repo %s. "
            "Resumed identities do not cross-charge another lane. Pass --reset-session-budget "
            "to start a fresh allowance. No runner was started."
            % (latch.get("session_id") or "unknown", want["lane_id"], want["repo"], lane, repo)
        )
    doc = load_allowance()
    if doc is not None:
        check_identity(doc, want)

def publish_latched_stop(latch):
    # Republish the stop-time snapshot. Do not reread the allowance or the
    # ledger: a runner that finishes after the stop must not change the count
    # this receipt already froze, and a later unreadable ledger must not turn
    # a stable stop into a new receipt.
    require_snapshot(latch)
    if "session_id" not in latch or not latch.get("reason"):
        fatal("session budget latch missing session_id or reason")
    reason = latch["reason"]
    setf("status", "stop")
    setf("quiet", "1")
    setf("reason", reason)
    setf("diagnosis", latch["diagnosis"])
    setf("session_id", latch["session_id"])
    setf("cost_text", latch["cost_text"])
    setf("cost_status", latch["cost_status"])
    setf("completed", latch["iterations_completed"])
    setf("consumed", latch["starts_consumed"])
    setf("in_flight", latch["in_flight"])
    rid = latch["receipt_id"]
    if journal_has_receipt(rid):
        if latch.get("journaled") != "1":
            write_latch("exhausted", reason, latch["session_id"], "1", latch_extra(latch))
        return
    append_journal(render_receipt(latch))
    write_latch("exhausted", reason, latch["session_id"], "1", latch_extra(latch))

def new_session_id():
    import secrets
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return "sb-" + stamp + "-" + secrets.token_hex(4)

def want_limits():
    return {
        "max_iterations": env_int("SB_LIMIT_ITERATIONS"),
        "max_wall_min": env_int("SB_LIMIT_WALL_MIN"),
        "max_cost_usd": str(env_int("SB_LIMIT_COST_USD")),
        "unbounded": os.environ.get("SB_UNBOUNDED", "0") == "1",
        "lane_id": os.environ.get("SB_LANE_ID", "solo"),
        "repo": os.environ.get("SB_REPO", ""),
    }

def check_identity(doc, want):
    if not LANE_RE.match(want["lane_id"]):
        fatal("GIBSON_LANE_ID is not a lane id")
    if not want["repo"]:
        fatal("session budget requires a repo slug")
    if doc["lane_id"] != want["lane_id"] or doc["repo"] != want["repo"]:
        fatal(
            "refusing to resume session %s for lane %s repo %s; allowance is lane %s repo %s. "
            "Resumed identities do not cross-charge another lane. Pass --reset-session-budget "
            "to start a fresh allowance. No runner was started."
            % (doc["session_id"], want["lane_id"], want["repo"], doc["lane_id"], doc["repo"])
        )
    if (
        doc["max_iterations"] != want["max_iterations"]
        or doc["max_wall_min"] != want["max_wall_min"]
        or doc["max_cost_usd"] != want["max_cost_usd"]
        or doc["unbounded"] != want["unbounded"]
    ):
        fatal(
            "refusing to resume session %s because this launch's limits "
            "(iterations=%s wall_min=%s cost_usd=%s unbounded=%s) differ from the persisted "
            "allowance (iterations=%s wall_min=%s cost_usd=%s unbounded=%s). Ordinary relaunch "
            "resumes the allowance. Pass --reset-session-budget to start a fresh one. "
            "No runner was started."
            % (
                doc["session_id"],
                want["max_iterations"], want["max_wall_min"], want["max_cost_usd"],
                str(want["unbounded"]).lower(),
                doc["max_iterations"], doc["max_wall_min"], doc["max_cost_usd"],
                str(doc["unbounded"]).lower(),
            )
        )

def scan_ledger(session_id):
    ledger = os.environ.get("SB_LEDGER", "")
    if ledger == "":
        return "not_measured", None, ("not_measured", None), "no-ledger"
    # lexists: a dangling symlink exists as a path and is not a missing file.
    # exists() follows the link and would treat that block as "no ledger".
    if not os.path.lexists(ledger):
        return "not_measured", None, ("not_measured", None), "missing-ledger"
    if os.path.islink(ledger) or not os.path.isfile(ledger):
        fatal("cost ledger is not a regular file; refusing to treat cost as zero")
    try:
        lines = open(ledger, "r", encoding="utf-8").read().splitlines()
    except OSError as exc:
        fatal("cost ledger unreadable; refusing to treat cost as zero: " + exc.strerror)
    measured = []
    merge_seen = False
    merged_prs = set()
    for idx, line in enumerate(lines, 1):
        if line.strip() == "":
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            fatal("cost ledger line %d is not JSON; refusing to treat cost as zero" % idx)
        if not isinstance(ev, dict):
            fatal("cost ledger line %d is not an object" % idx)
        schema = ev.get("schema")
        if schema is None:
            fatal("cost ledger line %d is missing schema; refusing to treat cost as zero" % idx)
        if schema != "gibson.cost.v1":
            continue
        where = "cost ledger line %d" % idx
        sid = ev.get("session_id")
        if sid is None:
            continue
        if not isinstance(sid, str):
            fatal(where + ": session_id must be a string")
        if sid != session_id:
            continue
        # Another session's row was skipped above. A malformed cost_usd on
        # this session still fails closed. A malformed cost_usd on a
        # different session is not this allowance's telemetry.
        if "cost_usd" in ev:
            amount = parse_cost_string(ev.get("cost_usd"), where)
        else:
            amount = None
        iteration = ev.get("iteration", None)
        if iteration is not None:
            if isinstance(iteration, bool) or not isinstance(iteration, int) or iteration < 1:
                fatal(where + ": iteration must be a positive integer")
        if "merged" in ev:
            merged = ev.get("merged")
            if not isinstance(merged, bool):
                fatal(where + ": merged must be a boolean")
            pr = ev.get("pr")
            # Docs: a row counts only when it carries boolean merged AND an
            # integer pr. A merged flag alone is not telemetry, so it must
            # not turn the receipt into prs_merged: 0.
            if isinstance(pr, int) and not isinstance(pr, bool):
                merge_seen = True
                if merged and pr > 0:
                    merged_prs.add(pr)
        if amount is not None:
            measured.append((iteration, amount))
    if not measured:
        prs = ("counted", len(merged_prs)) if merge_seen else ("not_measured", None)
        return "not_measured", None, prs, "no-cost"
    total = sum((amount for _, amount in measured), Decimal("0"))
    prs = ("counted", len(merged_prs)) if merge_seen else ("not_measured", None)
    return "measured", (total, measured), prs, "ok"

def cost_view(doc):
    # Completeness check, exactly:
    # scripts/cost-ledger.sh appends gibson.cost.v1 rows with schema, ts,
    # runner, pool, hat, wall_ms, and optional tokens, acus, issue, pr,
    # iteration, repo, note, join_key, requested_runner, provider,
    # fallback_reason, event_kind, and flat_rate. That writer has no
    # cost_usd, no session_id, and no session-complete or session-closed
    # field. This function sums cost_usd decimal strings a metered runner
    # attached to rows for this session_id. Those rows are measurements.
    # They are not a certificate that every consumed start was measured,
    # and matching iteration numbers do not create one. No matching
    # cost_usd → not_measured. One or more → partial. complete is not
    # returned.
    kind, payload, prs, _how = scan_ledger(doc["session_id"])
    prs_status, prs_count = prs
    if kind == "not_measured":
        return "not_measured", None, "cost: not measured", prs_status, prs_count
    total, _measured = payload
    text_amount = dec_str(total)
    return "partial", total, "cost: partial " + text_amount, prs_status, prs_count

def elapsed_seconds(doc):
    started = parse_started(doc["started_at"])
    delta = datetime.now(timezone.utc) - started
    whole = int(delta.total_seconds())
    if whole < 0:
        return 0
    return whole

def exhaustion(doc):
    elapsed = elapsed_seconds(doc)
    cost_status, total, cost_text, prs_status, prs_count = cost_view(doc)
    exhausted = []
    # --unbounded stores zeros and the flag. Either one means no dimension stops.
    if not doc["unbounded"]:
        if doc["max_iterations"] > 0 and doc["consumed_starts"] >= doc["max_iterations"]:
            exhausted.append("iterations")
        legacy_max = os.environ.get("SB_LEGACY_MAX", "")
        legacy_iter = os.environ.get("SB_LEGACY_ITER", "")
        if (
            doc["max_iterations"] > 0
            and legacy_max not in ("", "-1")
            and legacy_iter != ""
            and legacy_max.lstrip("-").isdigit()
            and legacy_iter.isdigit()
            and int(legacy_max) >= 0
            and int(legacy_iter) >= int(legacy_max)
            and "iterations" not in exhausted
        ):
            exhausted.append("iterations")
        if doc["max_wall_min"] > 0 and elapsed >= doc["max_wall_min"] * 60:
            exhausted.append("wall")
        if (
            doc["max_cost_usd"] != "0"
            and cost_status != "not_measured"
            and total is not None
            and total >= Decimal(doc["max_cost_usd"])
        ):
            exhausted.append("cost")
    overshoot = 0
    if doc["max_wall_min"] > 0:
        cap_s = doc["max_wall_min"] * 60
        if elapsed > cap_s:
            overshoot = elapsed - cap_s
    return exhausted, elapsed, overshoot, cost_status, total, cost_text, prs_status, prs_count

def fill_common(doc, exhausted, elapsed, overshoot, cost_status, total, cost_text, prs_status, prs_count, reason):
    setf("session_id", doc["session_id"])
    setf("consumed", doc["consumed_starts"])
    setf("completed", doc["completed_iterations"])
    setf("elapsed", elapsed)
    setf("overshoot", overshoot)
    setf("cost_status", cost_status)
    setf("cost_usd", dec_str(total) if total is not None else "")
    setf("cost_text", cost_text)
    setf("exhausted", ",".join(exhausted))
    setf("prs_text", "prs_merged: not measured" if prs_status != "counted" else "prs_merged: %d" % prs_count)
    setf("prs_merged", "" if prs_status != "counted" else str(prs_count))
    setf("started_at", doc["started_at"])
    setf("max_iterations", doc["max_iterations"])
    setf("max_wall_min", doc["max_wall_min"])
    setf("max_cost_usd", doc["max_cost_usd"])
    setf("unbounded", "1" if doc["unbounded"] else "0")
    setf("lane_id", doc["lane_id"])
    diagnosis = ""
    if reason in ("iterations", "wall", "cost"):
        diagnosis = "budget: " + reason
    elif reason == "cost-ledger-unreadable":
        diagnosis = "budget: cost-ledger-unreadable"
    setf("diagnosis", diagnosis)
    setf("reason", reason)
    in_flight = 1 if doc["consumed_starts"] > doc["completed_iterations"] else 0
    # Allowance id is the persisted session_id. See make_receipt_id.
    allowance_id = doc["session_id"]
    receipt_id = make_receipt_id(doc["session_id"], allowance_id, reason) if reason else ""
    setf("in_flight", str(in_flight))
    setf("allowance_id", allowance_id)
    setf("receipt_id", receipt_id)
    receipt = {
        "schema": "gibson.session-budget.v1",
        "session_id": doc["session_id"],
        "lane_id": doc["lane_id"],
        "repo": doc["repo"],
        "started_at": doc["started_at"],
        "reason": reason,
        "diagnosis": diagnosis,
        "iterations_completed": doc["completed_iterations"],
        "starts_consumed": doc["consumed_starts"],
        "wall_seconds": elapsed,
        "wall_overshoot_seconds": overshoot,
        "iteration_budget": doc["max_iterations"] if doc["max_iterations"] else None,
        "wall_budget_min": doc["max_wall_min"] if doc["max_wall_min"] else None,
        "cost_budget_usd": None if doc["max_cost_usd"] == "0" else doc["max_cost_usd"],
        "cost_status": cost_status,
        "cost_usd": None if total is None else dec_str(total),
        "cost_text": cost_text,
        "prs_merged": None if prs_status != "counted" else prs_count,
        "prs_text": OUT.get("prs_text", ""),
        "exhausted": exhausted,
        "unbounded": doc["unbounded"],
        "in_flight": in_flight,
        "receipt_id": receipt_id if receipt_id else None,
        "allowance_id": allowance_id,
    }
    setf("receipt_json", json.dumps(receipt, sort_keys=True, separators=(",", ":")))

def opt_out_of(doc):
    if doc["unbounded"]:
        return "all"
    dims = []
    if doc["max_iterations"] == 0:
        dims.append("iterations")
    if doc["max_wall_min"] == 0:
        dims.append("wall")
    if doc["max_cost_usd"] == "0":
        dims.append("cost")
    return ",".join(dims)

op = os.environ.get("SB_OP", "")
acquire_lock()
try:
    want = want_limits()
    if op == "reset":
        # Under the allowance lock: refuse only a start whose recorded loop
        # pid is still alive, append the reset line, then delete. The counter
        # gap is also what a killed runner leaves behind, so counters alone
        # do not refuse. A missing pid, a boolean, or any other non-integer
        # is an interrupted start. A failed journal write does not delete.
        # A symlink or directory is refused before either step.
        for path in (allowance_path, latch_path):
            if not os.path.lexists(path):
                continue
            if os.path.islink(path) or not os.path.isfile(path):
                fatal("refusing to delete a non-regular file during reset: " + os.path.basename(path))
        previous = "none"
        if os.path.isfile(allowance_path) and not os.path.islink(allowance_path):
            try:
                loaded = json.loads(open(allowance_path, "r", encoding="utf-8").read())
            except (OSError, json.JSONDecodeError, AttributeError):
                loaded = None
            if isinstance(loaded, dict):
                sid = loaded.get("session_id", "")
                previous = sid if isinstance(sid, str) and sid else "unreadable"
                consumed = loaded.get("consumed_starts")
                completed = loaded.get("completed_iterations")
                runner = loaded.get("runner_pid")
                if (
                    isinstance(consumed, int) and not isinstance(consumed, bool)
                    and isinstance(completed, int) and not isinstance(completed, bool)
                    and consumed > completed
                    and isinstance(runner, int) and not isinstance(runner, bool)
                    and pid_alive(runner)
                ):
                    fatal("session budget reset refused while a start is in flight")
            else:
                previous = "unreadable"
        append_journal(
            "\n## %s · session-budget-reset\n"
            "diagnosis: operator reset session budget (--reset-session-budget)\n"
            "previous_session_id: %s\n"
            "note: a fresh allowance is created on the next runner start. "
            "Relaunch without this flag resumes the allowance.\n"
            % (now_utc(), previous)
        )
        for path in (allowance_path, latch_path):
            if not os.path.lexists(path):
                continue
            if os.path.islink(path) or not os.path.isfile(path):
                fatal("refusing to delete a non-regular file during reset: " + os.path.basename(path))
            os.remove(path)
        setf("status", "ok")
        setf("previous_session_id", previous)
        finish()

    if op == "latch":
        reason = os.environ.get("SB_LATCH_REASON", "")
        sid = os.environ.get("SB_LATCH_SESSION", "")
        kind = os.environ.get("SB_LATCH_KIND", "exhausted")
        if kind not in ("exhausted", "unreadable"):
            fatal("invalid latch kind")
        if not reason:
            fatal("latch requires a reason")
        if not LANE_RE.match(want["lane_id"]):
            fatal("GIBSON_LANE_ID is not a lane id")
        if not want["repo"]:
            fatal("session budget requires a repo slug")
        write_latch(kind, reason, sid, "1", {
            "lane_id": want["lane_id"],
            "repo": want["repo"],
        })
        setf("status", "ok")
        finish()

    latch = load_latch()
    if latch and latch.get("kind") == "exhausted" and op in ("startup", "reserve", "boundary"):
        check_latch_identity(latch, want)
        publish_latched_stop(latch)
        finish()

    if latch and latch.get("kind") == "unreadable" and op == "startup":
        # The latch names the lane and repo that blocked. A different lane
        # must not clear it. scan_ledger fatals if the ledger is still
        # unreadable. The first stop does not grant an allowance. Recovery
        # clears the latch only after that identity check and only once the
        # ledger is a regular file again.
        check_latch_identity(latch, want)
        doc = load_allowance()
        if doc is None:
            scan_ledger("sb-00000000T000000Z-00000000")
            if os.path.lexists(latch_path) and not os.path.islink(latch_path):
                os.remove(latch_path)
            setf("status", "ok")
            finish()
        check_identity(doc, want)
        scan_ledger(doc["session_id"])
        if os.path.lexists(latch_path) and not os.path.islink(latch_path):
            os.remove(latch_path)
        latch = None

    if op == "startup":
        doc = load_allowance()
        if doc is None:
            setf("status", "ok")
            finish()
        check_identity(doc, want)
        exhausted, elapsed, overshoot, cost_status, total, cost_text, prs_status, prs_count = exhaustion(doc)
        reason = exhausted[0] if exhausted else ""
        fill_common(doc, exhausted, elapsed, overshoot, cost_status, total, cost_text, prs_status, prs_count, reason)
        if exhausted:
            commit_stop(doc, reason)
        else:
            setf("status", "ok")
        finish()

    if op == "reserve":
        doc = load_allowance()
        created = False
        if doc is None:
            if not LANE_RE.match(want["lane_id"]):
                fatal("GIBSON_LANE_ID is not a lane id")
            if not want["repo"]:
                fatal("session budget requires a repo slug")
            doc = {
                "schema": "gibson.session-budget.allowance.v1",
                "session_id": new_session_id(),
                "lane_id": want["lane_id"],
                "repo": want["repo"],
                "started_at": now_utc(),
                "max_iterations": want["max_iterations"],
                "max_wall_min": want["max_wall_min"],
                "max_cost_usd": want["max_cost_usd"],
                "unbounded": want["unbounded"],
                "consumed_starts": 0,
                "completed_iterations": 0,
            }
            created = True
        else:
            check_identity(doc, want)
        # Boundary BEFORE reservation: do not consume a start we will not run.
        # Legacy in-process iter is not applied here; the bottom boundary owns it.
        saved_legacy_max = os.environ.get("SB_LEGACY_MAX")
        saved_legacy_iter = os.environ.get("SB_LEGACY_ITER")
        os.environ["SB_LEGACY_MAX"] = ""
        os.environ["SB_LEGACY_ITER"] = ""
        exhausted, elapsed, overshoot, cost_status, total, cost_text, prs_status, prs_count = exhaustion(doc)
        if saved_legacy_max is None:
            os.environ.pop("SB_LEGACY_MAX", None)
        else:
            os.environ["SB_LEGACY_MAX"] = saved_legacy_max
        if saved_legacy_iter is None:
            os.environ.pop("SB_LEGACY_ITER", None)
        else:
            os.environ["SB_LEGACY_ITER"] = saved_legacy_iter
        if exhausted:
            if created:
                write_allowance(doc)
            reason = exhausted[0]
            fill_common(doc, exhausted, elapsed, overshoot, cost_status, total, cost_text, prs_status, prs_count, reason)
            commit_stop(doc, reason)
            setf("created", "1" if created else "0")
            finish()
        doc["consumed_starts"] += 1
        pid = recorded_loop_pid()
        if pid is None:
            fatal("session budget reserve requires the loop pid")
        doc["runner_pid"] = pid
        write_allowance(doc)
        setf("status", "ok")
        setf("created", "1" if created else "0")
        setf("opt_out", opt_out_of(doc) if created else "")
        setf("session_id", doc["session_id"])
        setf("iteration", doc["consumed_starts"])
        setf("consumed", doc["consumed_starts"])
        finish()

    if op == "complete":
        doc = load_allowance()
        if doc is None:
            fatal("cannot mark a completed iteration without an allowance")
        check_identity(doc, want)
        if doc["completed_iterations"] >= doc["consumed_starts"]:
            fatal("completed iterations would exceed consumed starts")
        doc["completed_iterations"] += 1
        doc.pop("runner_pid", None)
        write_allowance(doc)
        setf("status", "ok")
        setf("session_id", doc["session_id"])
        setf("completed", doc["completed_iterations"])
        setf("consumed", doc["consumed_starts"])
        finish()

    if op == "boundary":
        doc = load_allowance()
        if doc is None:
            fatal("cannot evaluate a session boundary without an allowance")
        check_identity(doc, want)
        exhausted, elapsed, overshoot, cost_status, total, cost_text, prs_status, prs_count = exhaustion(doc)
        reason = exhausted[0] if exhausted else ""
        fill_common(doc, exhausted, elapsed, overshoot, cost_status, total, cost_text, prs_status, prs_count, reason)
        if exhausted:
            commit_stop(doc, reason)
        else:
            setf("status", "ok")
        finish()

    fatal("unknown session budget operation")
finally:
    release_lock()
PY
  ) 2>"$err"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    SB_STATUS="fatal"
    SB_MESSAGE="session budget engine failed (rc=${rc})"
    if [[ -s "$err" ]]; then
      SB_MESSAGE="${SB_MESSAGE}: $(tr '\n' ' ' < "$err")"
    fi
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      status) SB_STATUS=$val ;;
      reason) SB_REASON=$val ;;
      message) SB_MESSAGE=$val ;;
      diagnosis) SB_DIAGNOSIS=$val ;;
      session_id) SB_SESSION_ID=$val ;;
      created) SB_CREATED=$val ;;
      opt_out) SB_OPT_OUT=$val ;;
      iteration) SB_ITERATION=$val ;;
      cost_status) SB_COST_STATUS=$val ;;
      cost_text) SB_COST_TEXT=$val ;;
      *) ;;
    esac
  done <<EOF
$out
EOF
  [[ -n "$SB_STATUS" ]] || {
    SB_STATUS="fatal"
    SB_MESSAGE="session budget engine returned no status"
  }
  return 0
}

# Shell redirects follow symlinks. The engine does not. A refusal or opt-out
# must not be written through a symlink journal.
sb_ensure_journal() {
  if [[ -z "${JOURNAL:-}" ]]; then
    echo "loop.sh: ERROR: session budget: journal path is unset" >&2
    return 1
  fi
  if [[ -L "$JOURNAL" ]]; then
    echo "loop.sh: ERROR: session budget: journal is a symlink" >&2
    return 1
  fi
  if [[ -e "$JOURNAL" && ! -f "$JOURNAL" ]]; then
    echo "loop.sh: ERROR: session budget: journal is not a regular file" >&2
    return 1
  fi
  if [[ -e "$JOURNAL" && ! -w "$JOURNAL" ]]; then
    echo "loop.sh: ERROR: session budget: journal is not writable" >&2
    return 1
  fi
  if [[ ! -e "$JOURNAL" ]]; then
    mkdir -p -- "$(dirname -- "$JOURNAL")" || return 1
    printf '%s\n' "# Gibson loop journal" > "$JOURNAL" || return 1
  fi
}

sb_journal_append() {
  sb_ensure_journal || return 1
  cat >> "$JOURNAL"
}

# The engine has already created this allowance. If the required journal
# line was not written, remove that file so the next launch cannot resume
# an opt-out that was never recorded. A symlink is not removed.
sb_discard_created_allowance() {
  local path
  path=$(sb_allowance_path)
  if [[ -L "$path" ]]; then
    echo "loop.sh: ERROR: session budget: refusing to remove a symlink allowance" >&2
    return 1
  fi
  if [[ -f "$path" ]]; then
    rm -f -- "$path" || return 1
  fi
}

sb_journal_opt_out() {
  [[ -n "${SB_OPT_OUT:-}" ]] || return 0
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · session-budget-opt-out"
    echo "diagnosis: session budget opt-out"
    echo "session_id: ${SB_SESSION_ID}"
    echo "dimensions: ${SB_OPT_OUT}"
    echo "note: 0 or --unbounded is an explicit unlimited dimension. This launch opted out. It is not the default."
  } | sb_journal_append || return 1
}

# True only when nothing is at the path. A symlink, including a dangling one,
# is present. -f and -e both follow and would call that path missing.
sb_path_absent() {
  local path="$1"
  [[ ! -L "$path" && ! -e "$path" ]]
}

sb_emit_stop_info() {
  local reason="${SB_REASON:-}"
  if [[ -n "${SB_DIAGNOSIS:-}" ]]; then
    info "$SB_DIAGNOSIS"
  fi
  if [[ "$reason" == "iterations" && "${MAX:- -1}" -ge 0 ]]; then
    info "max iterations ${MAX} reached"
  fi
  if [[ -n "${SB_COST_TEXT:-}" ]]; then
    info "$SB_COST_TEXT"
  fi
  if [[ "${SB_COST_STATUS:-}" == "not_measured" ]]; then
    info "cost: not measured (flat-rate or pool runners report no cost_usd; not \$0)"
  fi
}

sb_latch_stop() {
  local kind="exhausted"
  if [[ "$SB_REASON" == "cost-ledger-unreadable" ]]; then
    kind="unreadable"
  fi
  # The engine names SB_LATCH_KIND, SB_LATCH_REASON, and SB_LATCH_SESSION
  # on the python command. The latch op reads those three from the process
  # environment and refuses an empty reason, so an unreadable ledger stays
  # latched instead of journaling a new refusal on every relaunch.
  SB_LATCH_KIND="$kind" \
    SB_LATCH_REASON="$SB_REASON" \
    SB_LATCH_SESSION="${SB_SESSION_ID:-}" \
    sb_engine latch || return 1
  [[ "$SB_STATUS" == "ok" ]] || return 1
  return 0
}

# True when an unreadable-ledger latch was already journaled. KeepAlive
# relaunch must not append another journal section for the same block.
sb_unreadable_latched() {
  local latch
  latch=$(sb_latch_path)
  [[ -f "$latch" && ! -L "$latch" ]] || return 1
  grep -q '^kind=unreadable$' "$latch" && grep -q '^journaled=1$' "$latch"
}

# Map an engine result to 0 continue, 2 graceful stop, 1 fatal.
# A budget stop's receipt and latch are already published inside the engine.
sb_apply_status() {
  local saved_message
  case "$SB_STATUS" in
    ok)
      if [[ "${SB_CREATED:-}" == "1" && -n "${SB_OPT_OUT:-}" ]]; then
        # The opt-out line is the record that this launch chose unlimited.
        # Ignoring a failed write would start the runner and leave the
        # allowance for the next launch to resume with no record.
        if ! sb_journal_opt_out; then
          sb_discard_created_allowance || return 1
          return 1
        fi
      fi
      if [[ -n "${SB_SESSION_ID:-}" ]]; then
        export GIBSON_SESSION_ID="$SB_SESSION_ID"
      fi
      if [[ -n "${SB_ITERATION:-}" ]]; then
        export GIBSON_SESSION_ITERATION="$SB_ITERATION"
      fi
      return 0
      ;;
    stop)
      # The engine already renamed the latch and appended the receipt under
      # the same lock. Doing either step again here would race.
      sb_emit_stop_info
      return 2
      ;;
    fatal)
      saved_message="${SB_MESSAGE:-unspecified failure}"
      saved_message=${saved_message:0:400}
      if sb_unreadable_latched; then
        echo "loop.sh: ERROR: session budget: ${saved_message}" >&2
        return 1
      fi
      if [[ "$saved_message" == *cost\ ledger* || "$saved_message" == *unreadable-ledger* ]]; then
        {
          echo ""
          echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · session-budget"
          echo "diagnosis: budget: cost-ledger-unreadable"
          echo "note: the cost ledger could not be evaluated. Cost was not treated as zero and the allowance was not reset."
          echo "detail: ${saved_message}"
        } | sb_journal_append || return 1
        SB_REASON="cost-ledger-unreadable"
        SB_SESSION_ID="${SB_SESSION_ID:-}"
        sb_latch_stop || return 1
      else
        {
          echo ""
          echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · session-budget-refused"
          echo "diagnosis: session budget refused the launch"
          echo "detail: ${saved_message}"
          echo "note: the allowance was not replaced. Ordinary relaunch does not start a fresh budget."
        } | sb_journal_append || return 1
      fi
      echo "loop.sh: ERROR: session budget: ${saved_message}" >&2
      return 1
      ;;
    *)
      echo "loop.sh: ERROR: session budget: engine returned unknown status '${SB_STATUS}'" >&2
      return 1
      ;;
  esac
}

sb_startup_gate() {
  if [[ "${SB_RESET:-0}" == "1" ]]; then
    # The engine holds the allowance lock across the journal append and the
    # delete. A start whose recorded loop pid is still alive is refused
    # before either one. A dead or absent pid is reset.
    sb_engine reset || return 1
    [[ "$SB_STATUS" == "ok" ]] || { echo "loop.sh: ERROR: session budget: ${SB_MESSAGE}" >&2; return 1; }
  fi
  if sb_path_absent "$(sb_allowance_path)" && sb_path_absent "$(sb_latch_path)"; then
    return 0
  fi
  SB_LEGACY_MAX=""
  SB_LEGACY_ITER=""
  sb_engine startup || return 1
  sb_apply_status
}

sb_reserve_start() {
  SB_LEGACY_MAX=""
  SB_LEGACY_ITER=""
  sb_engine reserve || return 1
  sb_apply_status
}

sb_mark_completed() {
  sb_engine complete || return 1
  [[ "$SB_STATUS" == "ok" ]] || {
    echo "loop.sh: ERROR: session budget: ${SB_MESSAGE:-could not record a completed iteration}" >&2
    return 1
  }
  return 0
}

sb_boundary_check() {
  SB_LEGACY_MAX="${MAX:- -1}"
  SB_LEGACY_ITER="${iter:-0}"
  sb_engine boundary || return 1
  sb_apply_status
}

# One stdout line for loop-fleet --status. Missing and unreadable are distinct.
sb_format_rollup() {
  local journal="$1" lane="$2"
  python3 - "$journal" "$lane" <<'PY'
import json, sys
journal, lane = sys.argv[1], sys.argv[2]
prefix = "session-budget lane=" + lane
try:
    text = open(journal, "r", encoding="utf-8").read().splitlines()
except FileNotFoundError:
    sys.stdout.write(prefix + " receipt=none\n")
    sys.exit(0)
except OSError:
    sys.stdout.write(prefix + " receipt=unreadable\n")
    sys.exit(0)
last = ""
for line in text:
    if '"schema":"gibson.session-budget.v1"' in line:
        last = line.strip()
if not last:
    sys.stdout.write(prefix + " receipt=none\n")
    sys.exit(0)
try:
    doc = json.loads(last)
except json.JSONDecodeError:
    sys.stdout.write(prefix + " receipt=unreadable\n")
    sys.exit(0)
if not isinstance(doc, dict) or doc.get("schema") != "gibson.session-budget.v1":
    sys.stdout.write(prefix + " receipt=unreadable\n")
    sys.exit(0)
need = ("session_id", "diagnosis", "iterations_completed", "starts_consumed",
        "wall_seconds", "cost_status", "cost_text", "prs_text", "lane_id")
for key in need:
    if key not in doc:
        sys.stdout.write(prefix + " receipt=unreadable\n")
        sys.exit(0)
sys.stdout.write(
    "%s receipt_lane=%s session=%s diagnosis=%s iterations_completed=%s starts_consumed=%s wall_seconds=%s cost_status=%s %s %s\n"
    % (
        prefix,
        doc["lane_id"],
        doc["session_id"],
        doc["diagnosis"],
        doc["iterations_completed"],
        doc["starts_consumed"],
        doc["wall_seconds"],
        doc["cost_status"],
        doc["cost_text"],
        doc["prs_text"],
    )
)
PY
}
