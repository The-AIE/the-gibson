#!/usr/bin/env bash
# session-budget.sh — finite session allowance for scripts/loop.sh (issue #409).
#
# Sourced by loop.sh and loop-fleet.sh. Not a standalone CLI.
#
# WHAT IT ENFORCES
#   A persisted allowance (gibson/session-budget.json) with session identity,
#   start time, and consumed starts. Defaults are 50 iterations, 480 minutes,
#   and USD 20. 0 on a dimension, or --unbounded, is an explicit opt-out and is
#   journaled. Ordinary relaunch resumes the same allowance. Only
#   --reset-session-budget creates a fresh one. An atomic latch
#   (gibson/session-budget-latch) keeps a budget stop from being forgotten by
#   launchd KeepAlive.
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
#   (not $0). A measured subset that does not cover every completed iteration,
#   or any event that lacks an iteration id, stays "partial": one cost_usd event
#   does not establish complete session spend. A partial or complete sum that
#   reaches the cap stops; an unmeasured session does not stop on cost.
#   scripts/cost-ledger.sh is not modified and its append path does not write
#   cost_usd. A metered runner records a line itself. The loop exports
#   GIBSON_SESSION_ID and GIBSON_SESSION_ITERATION before the runner starts.
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
#
# Caller globals (loop.sh): STATE_DIR JOURNAL EXPECTED_REPO_SLUG MAX iter
#   plus info(). Limits: SB_LIMIT_ITERATIONS SB_LIMIT_WALL_MIN SB_LIMIT_COST_USD
#   SB_UNBOUNDED SB_RESET (all set by loop.sh before the first call).
# shellcheck disable=SC2154

# Result fields filled by sb_engine. Cleared at the start of each call.
SB_STATUS=""
SB_QUIET=""
SB_REASON=""
SB_MESSAGE=""
SB_SESSION_ID=""
SB_CREATED=""
SB_OPT_OUT=""
SB_ITERATION=""
SB_CONSUMED=""
SB_COMPLETED=""
SB_ELAPSED=""
SB_OVERSHOOT=""
SB_COST_STATUS=""
SB_COST_TEXT=""
SB_EXHAUSTED=""
SB_PRS_TEXT=""
SB_PREVIOUS_SESSION_ID=""
SB_STARTED_AT=""
SB_MAX_ITERATIONS=""
SB_MAX_WALL_MIN=""
SB_MAX_COST_USD=""
SB_LANE_STORED=""
SB_DIAGNOSIS=""
SB_RECEIPT_JSON=""

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
  SB_QUIET=""
  SB_REASON=""
  SB_MESSAGE=""
  SB_SESSION_ID=""
  SB_CREATED=""
  SB_OPT_OUT=""
  SB_ITERATION=""
  SB_CONSUMED=""
  SB_COMPLETED=""
  SB_ELAPSED=""
  SB_OVERSHOOT=""
  SB_COST_STATUS=""
  SB_COST_TEXT=""
  SB_EXHAUSTED=""
  SB_PRS_TEXT=""
  SB_PREVIOUS_SESSION_ID=""
  SB_STARTED_AT=""
  SB_MAX_ITERATIONS=""
  SB_MAX_WALL_MIN=""
  SB_MAX_COST_USD=""
  SB_LANE_STORED=""
  SB_DIAGNOSIS=""
  SB_RECEIPT_JSON=""
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
      python3 - <<'PY'
import errno, json, os, re, sys, tempfile, time
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

DEC_RE = re.compile(r"^(0|[1-9][0-9]{0,8})(\.[0-9]{1,6})?$")
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

def pid_alive(pid):
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True

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
    if not os.path.exists(latch_path):
        return None
    if os.path.islink(latch_path):
        fatal("session budget latch is a symlink")
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

def write_latch(kind, reason, session_id, journaled):
    body = (
        "schema=gibson.session-budget.latch.v1\n"
        "kind=%s\n"
        "reason=%s\n"
        "session_id=%s\n"
        "journaled=%s\n"
    ) % (kind, reason, session_id, journaled)
    atomic_write(latch_path, body.encode("utf-8"))

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
    if not os.path.exists(ledger):
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
        if "cost_usd" in ev:
            amount = parse_cost_string(ev.get("cost_usd"), where)
        else:
            amount = None
        sid = ev.get("session_id")
        if sid is None:
            continue
        if not isinstance(sid, str):
            fatal(where + ": session_id must be a string")
        if sid != session_id:
            continue
        iteration = ev.get("iteration", None)
        if iteration is not None:
            if isinstance(iteration, bool) or not isinstance(iteration, int) or iteration < 1:
                fatal(where + ": iteration must be a positive integer")
        if "merged" in ev:
            merged = ev.get("merged")
            if not isinstance(merged, bool):
                fatal(where + ": merged must be a boolean")
            merge_seen = True
            pr = ev.get("pr")
            if merged and isinstance(pr, int) and not isinstance(pr, bool) and pr > 0:
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
    kind, payload, prs, _how = scan_ledger(doc["session_id"])
    prs_status, prs_count = prs
    if kind == "not_measured":
        return "not_measured", None, "cost: not measured", prs_status, prs_count
    total, measured = payload
    completed = doc["completed_iterations"]
    consumed = doc["consumed_starts"]
    iters = [item[0] for item in measured]
    covered = (
        completed >= 1
        and consumed == completed
        and all(isinstance(item, int) and 1 <= item <= completed for item in iters)
        and set(iters) >= set(range(1, completed + 1))
    )
    text_amount = dec_str(total)
    if covered:
        return "complete", total, "cost: " + text_amount, prs_status, prs_count
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
        previous = ""
        if os.path.exists(allowance_path) and not os.path.islink(allowance_path):
            try:
                previous = json.loads(open(allowance_path, "r", encoding="utf-8").read()).get("session_id", "")
            except (OSError, json.JSONDecodeError, AttributeError):
                previous = "unreadable"
            if not isinstance(previous, str):
                previous = "unreadable"
        for path in (allowance_path, latch_path):
            if os.path.lexists(path):
                if os.path.islink(path):
                    fatal("refusing to delete a symlink during reset: " + os.path.basename(path))
                os.remove(path)
        setf("status", "ok")
        setf("previous_session_id", previous or "none")
        finish()

    if op == "latch":
        reason = os.environ.get("SB_LATCH_REASON", "")
        sid = os.environ.get("SB_LATCH_SESSION", "")
        kind = os.environ.get("SB_LATCH_KIND", "exhausted")
        if kind not in ("exhausted", "unreadable"):
            fatal("invalid latch kind")
        if not reason:
            fatal("latch requires a reason")
        write_latch(kind, reason, sid, "1")
        setf("status", "ok")
        finish()

    latch = load_latch()
    if latch and latch.get("kind") == "exhausted" and op in ("startup", "reserve", "boundary"):
        setf("status", "stop")
        setf("quiet", "1" if latch.get("journaled") == "1" else "0")
        setf("reason", latch.get("reason", "iterations"))
        setf("diagnosis", "budget: " + latch.get("reason", "iterations"))
        setf("session_id", latch.get("session_id", ""))
        # Already journaled: do not rescan the ledger. A later unreadable
        # ledger must not turn a stable budget stop into a new receipt.
        if latch.get("journaled") == "1":
            finish()
        doc = load_allowance()
        if doc is not None:
            try:
                exhausted, elapsed, overshoot, cost_status, total, cost_text, prs_status, prs_count = exhaustion(doc)
            except SystemExit:
                raise
            fill_common(doc, exhausted, elapsed, overshoot, cost_status, total, cost_text, prs_status, prs_count, latch.get("reason", "iterations"))
            setf("quiet", "1" if latch.get("journaled") == "1" else "0")
            setf("diagnosis", "budget: " + latch.get("reason", "iterations"))
            setf("reason", latch.get("reason", "iterations"))
        finish()

    if latch and latch.get("kind") == "unreadable" and op == "startup":
        # Recheck. scan_ledger fatals by finish() if still unreadable.
        # The first unreadable stop does not grant an allowance. Recovery
        # must still clear the latch once the ledger is a regular file again,
        # so a later launch can create a fresh allowance. A still-unreadable
        # ledger fatals and does not create one.
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
            setf("status", "stop")
            setf("quiet", "0")
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
            setf("status", "stop")
            setf("quiet", "0")
            setf("created", "1" if created else "0")
            finish()
        doc["consumed_starts"] += 1
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
            setf("status", "stop")
            setf("quiet", "0")
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
      quiet) SB_QUIET=$val ;;
      reason) SB_REASON=$val ;;
      message) SB_MESSAGE=$val ;;
      diagnosis) SB_DIAGNOSIS=$val ;;
      session_id) SB_SESSION_ID=$val ;;
      created) SB_CREATED=$val ;;
      opt_out) SB_OPT_OUT=$val ;;
      iteration) SB_ITERATION=$val ;;
      consumed) SB_CONSUMED=$val ;;
      completed) SB_COMPLETED=$val ;;
      elapsed) SB_ELAPSED=$val ;;
      overshoot) SB_OVERSHOOT=$val ;;
      cost_status) SB_COST_STATUS=$val ;;
      cost_text) SB_COST_TEXT=$val ;;
      exhausted) SB_EXHAUSTED=$val ;;
      prs_text) SB_PRS_TEXT=$val ;;
      previous_session_id) SB_PREVIOUS_SESSION_ID=$val ;;
      started_at) SB_STARTED_AT=$val ;;
      max_iterations) SB_MAX_ITERATIONS=$val ;;
      max_wall_min) SB_MAX_WALL_MIN=$val ;;
      max_cost_usd) SB_MAX_COST_USD=$val ;;
      lane_id) SB_LANE_STORED=$val ;;
      receipt_json) SB_RECEIPT_JSON=$val ;;
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

sb_ensure_journal() {
  mkdir -p "$STATE_DIR"
  if [[ ! -e "$JOURNAL" && ! -L "$JOURNAL" ]]; then
    echo "# Gibson loop journal" > "$JOURNAL"
  fi
}

sb_journal_opt_out() {
  [[ -n "${SB_OPT_OUT:-}" ]] || return 0
  sb_ensure_journal
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · session-budget-opt-out"
    echo "diagnosis: session budget opt-out"
    echo "session_id: ${SB_SESSION_ID}"
    echo "dimensions: ${SB_OPT_OUT}"
    echo "note: 0 or --unbounded is an explicit unlimited dimension. This launch opted out. It is not the default."
  } >> "$JOURNAL"
}

sb_journal_reset() {
  sb_ensure_journal
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · session-budget-reset"
    echo "diagnosis: operator reset session budget (--reset-session-budget)"
    echo "previous_session_id: ${SB_PREVIOUS_SESSION_ID:-none}"
    echo "note: a fresh allowance is created on the next runner start. Relaunch without this flag resumes the allowance."
  } >> "$JOURNAL"
}

sb_journal_receipt() {
  sb_ensure_journal
  {
    echo ""
    echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · session-budget"
    echo "diagnosis: ${SB_DIAGNOSIS}"
    echo "session_id: ${SB_SESSION_ID}"
    echo "lane_id: ${SB_LANE_STORED}"
    echo "started_at: ${SB_STARTED_AT}"
    echo "iterations_completed: ${SB_COMPLETED}"
    echo "starts_consumed: ${SB_CONSUMED}"
    echo "wall_seconds: ${SB_ELAPSED}"
    echo "wall_overshoot_seconds: ${SB_OVERSHOOT}"
    echo "iteration_budget: ${SB_MAX_ITERATIONS}"
    echo "wall_budget_min: ${SB_MAX_WALL_MIN}"
    echo "cost_budget_usd: ${SB_MAX_COST_USD}"
    echo "${SB_COST_TEXT}"
    echo "cost_status: ${SB_COST_STATUS}"
    echo "${SB_PRS_TEXT}"
    echo "exhausted: ${SB_EXHAUSTED}"
    echo "note: stopped at an iteration boundary. The session budget does not kill the runner. Per-iteration kills stay with --runner-timeout. Wall time can overshoot the cap by the remainder of the last iteration."
    if [[ "$SB_COST_STATUS" == "not_measured" ]]; then
      echo "note: cost: not measured. Flat-rate or pool runners report no cost_usd. That is not \$0. Iterations and wall-clock still bound the session."
    elif [[ "$SB_COST_STATUS" == "partial" ]]; then
      echo "note: cost is partial. Measured dollars are not a complete session total. One cost_usd event does not establish complete session spend."
    fi
    echo "${SB_RECEIPT_JSON}"
  } >> "$JOURNAL"
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
# sb_engine clears SB_* at entry, so snapshot anything still needed after a
# nested latch call.
sb_apply_status() {
  local saved_diag saved_reason saved_cost_text saved_cost_status saved_message
  case "$SB_STATUS" in
    ok)
      if [[ "${SB_CREATED:-}" == "1" && -n "${SB_OPT_OUT:-}" ]]; then
        sb_journal_opt_out
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
      saved_diag="${SB_DIAGNOSIS:-}"
      saved_reason="${SB_REASON:-}"
      saved_cost_text="${SB_COST_TEXT:-}"
      saved_cost_status="${SB_COST_STATUS:-}"
      if [[ "${SB_QUIET:-}" != "1" ]]; then
        if [[ -n "${SB_RECEIPT_JSON:-}" ]]; then
          sb_journal_receipt || return 1
        fi
        sb_latch_stop || return 1
      fi
      SB_DIAGNOSIS="$saved_diag"
      SB_REASON="$saved_reason"
      SB_COST_TEXT="$saved_cost_text"
      SB_COST_STATUS="$saved_cost_status"
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
        sb_ensure_journal
        {
          echo ""
          echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · session-budget"
          echo "diagnosis: budget: cost-ledger-unreadable"
          echo "note: the cost ledger could not be evaluated. Cost was not treated as zero and the allowance was not reset."
          echo "detail: ${saved_message}"
        } >> "$JOURNAL"
        SB_REASON="cost-ledger-unreadable"
        SB_SESSION_ID="${SB_SESSION_ID:-}"
        sb_latch_stop || return 1
      else
        sb_ensure_journal
        {
          echo ""
          echo "## $(date -u +"%Y-%m-%dT%H:%M:%SZ") · session-budget-refused"
          echo "diagnosis: session budget refused the launch"
          echo "detail: ${saved_message}"
          echo "note: the allowance was not replaced. Ordinary relaunch does not start a fresh budget."
        } >> "$JOURNAL"
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
    sb_engine reset || return 1
    [[ "$SB_STATUS" == "ok" ]] || { echo "loop.sh: ERROR: session budget: ${SB_MESSAGE}" >&2; return 1; }
    sb_journal_reset
  fi
  if [[ ! -f "$(sb_allowance_path)" && ! -f "$(sb_latch_path)" ]]; then
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
