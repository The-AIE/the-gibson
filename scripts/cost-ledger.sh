#!/usr/bin/env bash
# cost-ledger.sh - per-iteration cost ledger + cost-per-merged-PR rollup (L-003 / #74 / #141)
set -euo pipefail

usage() {
  cat <<'HELP'
cost-ledger.sh - per-iteration cost ledger (L-003 / issues #74, #141)

WHAT IT DOES
  Records one JSONL event per loop iteration (or hat) with runner/pool, hat,
  wall time, and optional cost signals (tokens, ACUs, flat-rate marker).
  Optional join fields associate fleet runner selection with later iteration
  rows and merged-PR outcomes without inventing usage.
  Summarizes cost-per-merged-PR when given a merged-PR list.

WHY
  L-003: unbounded coordinator sessions hide cost pathology. Unattended loops
  need a meter the morning digest can show.
  #141: per-lane runner selection must join to the same ledger so pool,
  fallback, and merged outcome are attributable.

RISKS
  - Append-only local file; never ships secrets.
  - Missing token/ACU fields stay unknown, never coerced to 0.
  - Does not bill anything.
  - Corrupt or ambiguous merged/join input fails closed (exit 3).

COMMANDS
  cost-ledger.sh append --ledger PATH --runner NAME --hat NAME [options]
  cost-ledger.sh summarize --ledger PATH [--merged-json PATH|--merged-since PATH] [--format text|json]
  cost-ledger.sh --help

APPEND OPTIONS
  --ledger PATH --runner NAME --pool NAME --hat NAME --wall-ms N
  --tokens N --acus N --flat-rate true|false --issue N --pr N
  --iteration N --repo owner/name --note TEXT --now ISO
  --join-key KEY --requested-runner NAME --provider NAME
  --fallback-reason TEXT --event-kind selection|iteration

  Optional #141 join fields are omitted when empty (legacy rows stay valid).
  --runner remains the actual selected runner for backward compatibility.

SUMMARIZE OPTIONS
  --ledger PATH --merged-json PATH --format text|json --period-start ISO
  --merged-since PATH is accepted as a backward-compatible alias of --merged-json.

  Merge attribution is honest: an event counts as merged only when its own
  pr, or a same-join-key event's pr, appears in the merged JSON. Merged PRs
  with no attributed events are reported as lacking cost data — not zero-cost
  success. Ambiguous join_key→PR maps and corrupt merged JSON fail closed.

  Token averages (per PR, per pool, global) are null/unknown unless every
  event represented by that metric recorded tokens — partial coverage never
  becomes a silently lower total. known/total event coverage is always exposed.

  by_pool includes merged/unmerged event counts, distinct attributed merged
  PR counts, merged wall time, and per-merged-PR metrics for load balancing.

EXIT
  0 ok | 2 usage | 3 corrupt
HELP
}

die_usage() { echo "cost-ledger.sh: $*" >&2; exit 2; }
die_corrupt() { echo "cost-ledger.sh: $*" >&2; exit 3; }

CMD="${1:-}"
[[ -n "$CMD" ]] || { usage; exit 2; }
if [[ "$CMD" == "-h" || "$CMD" == "--help" ]]; then usage; exit 0; fi
shift || true

LEDGER="" RUNNER="" POOL="unknown" HAT="" WALL_MS="" TOKENS="" ACUS="" FLAT=""
ISSUE="" PR="" ITER="" REPO="" NOTE="" NOW="" MERGED="" FORMAT="text" PERIOD_START=""
JOIN_KEY="" REQUESTED_RUNNER="" PROVIDER="" FALLBACK_REASON="" EVENT_KIND=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ledger) LEDGER="${2:-}"; shift 2 ;;
    --runner) RUNNER="${2:-}"; shift 2 ;;
    --pool) POOL="${2:-}"; shift 2 ;;
    --hat) HAT="${2:-}"; shift 2 ;;
    --wall-ms) WALL_MS="${2:-}"; shift 2 ;;
    --tokens) TOKENS="${2:-}"; shift 2 ;;
    --acus) ACUS="${2:-}"; shift 2 ;;
    --flat-rate) FLAT="${2:-}"; shift 2 ;;
    --issue) ISSUE="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --iteration) ITER="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --note) NOTE="${2:-}"; shift 2 ;;
    --now) NOW="${2:-}"; shift 2 ;;
    --join-key) JOIN_KEY="${2:-}"; shift 2 ;;
    --requested-runner) REQUESTED_RUNNER="${2:-}"; shift 2 ;;
    --provider) PROVIDER="${2:-}"; shift 2 ;;
    --fallback-reason) FALLBACK_REASON="${2:-}"; shift 2 ;;
    --event-kind) EVENT_KIND="${2:-}"; shift 2 ;;
    --merged-json|--merged-since) MERGED="${2:-}"; shift 2 ;;
    --format) FORMAT="${2:-}"; shift 2 ;;
    --period-start) PERIOD_START="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$LEDGER" ]] || die_usage "--ledger is required"

case "$CMD" in
  append)
    [[ -n "$RUNNER" ]] || die_usage "append requires --runner"
    [[ -n "$HAT" ]] || die_usage "append requires --hat"
    [[ -n "$WALL_MS" ]] || die_usage "append requires --wall-ms"
    [[ "$WALL_MS" =~ ^[0-9]+$ ]] || die_corrupt "--wall-ms must be a non-negative integer"
    if [[ -n "$TOKENS" && ! "$TOKENS" =~ ^[0-9]+$ ]]; then
      die_corrupt "--tokens must be a non-negative integer"
    fi
    if [[ -n "$ISSUE" && ! "$ISSUE" =~ ^[0-9]+$ ]]; then
      die_corrupt "--issue must be a non-negative integer"
    fi
    if [[ -n "$PR" && ! "$PR" =~ ^[0-9]+$ ]]; then
      die_corrupt "--pr must be a non-negative integer"
    fi
    if [[ -n "$ITER" && ! "$ITER" =~ ^[0-9]+$ ]]; then
      die_corrupt "--iteration must be a non-negative integer"
    fi
    if [[ -n "$NOTE" && "$NOTE" == *$'\n'* ]]; then
      die_corrupt "--note must not contain newlines"
    fi
    if [[ -n "$JOIN_KEY" && "$JOIN_KEY" == *$'\n'* ]]; then
      die_corrupt "--join-key must not contain newlines"
    fi
    if [[ -n "$REQUESTED_RUNNER" && "$REQUESTED_RUNNER" == *$'\n'* ]]; then
      die_corrupt "--requested-runner must not contain newlines"
    fi
    if [[ -n "$PROVIDER" && "$PROVIDER" == *$'\n'* ]]; then
      die_corrupt "--provider must not contain newlines"
    fi
    if [[ -n "$FALLBACK_REASON" && "$FALLBACK_REASON" == *$'\n'* ]]; then
      die_corrupt "--fallback-reason must not contain newlines"
    fi
    if [[ -n "$EVENT_KIND" ]]; then
      case "$EVENT_KIND" in
        selection|iteration) ;;
        *) die_corrupt "--event-kind must be selection or iteration" ;;
      esac
    fi
    if [[ -z "$NOW" ]]; then
      NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    fi
    mkdir -p "$(dirname -- "$LEDGER")"
    if [[ -e "$LEDGER" && ! -f "$LEDGER" ]]; then
      die_corrupt "ledger path exists and is not a regular file: $LEDGER"
    fi
    if [[ -L "$LEDGER" ]]; then
      die_corrupt "ledger path must not be a symlink: $LEDGER"
    fi
    export CL_LEDGER="$LEDGER" CL_RUNNER="$RUNNER" CL_POOL="$POOL" CL_HAT="$HAT"
    export CL_WALL="$WALL_MS" CL_TOKENS="${TOKENS:-}" CL_ACUS="${ACUS:-}"
    export CL_FLAT="${FLAT:-}" CL_ISSUE="${ISSUE:-}" CL_PR="${PR:-}"
    export CL_ITER="${ITER:-}" CL_REPO="${REPO:-}" CL_NOTE="${NOTE:-}" CL_NOW="$NOW"
    export CL_JOIN="${JOIN_KEY:-}" CL_REQ_RUNNER="${REQUESTED_RUNNER:-}"
    export CL_PROVIDER="${PROVIDER:-}" CL_FB_REASON="${FALLBACK_REASON:-}"
    export CL_EVENT_KIND="${EVENT_KIND:-}"
    python3 -c '
import json, os, sys
path = os.environ["CL_LEDGER"]
ev = {
    "schema": "gibson.cost.v1",
    "ts": os.environ["CL_NOW"],
    "runner": os.environ["CL_RUNNER"],
    "pool": os.environ["CL_POOL"],
    "hat": os.environ["CL_HAT"],
    "wall_ms": int(os.environ["CL_WALL"]),
}
for k, env in (("tokens","CL_TOKENS"),("acus","CL_ACUS"),("issue","CL_ISSUE"),
               ("pr","CL_PR"),("iteration","CL_ITER"),("repo","CL_REPO"),("note","CL_NOTE"),
               ("join_key","CL_JOIN"),("requested_runner","CL_REQ_RUNNER"),
               ("provider","CL_PROVIDER"),("fallback_reason","CL_FB_REASON"),
               ("event_kind","CL_EVENT_KIND")):
    v = os.environ.get(env) or ""
    if not v:
        continue
    if k in ("tokens","issue","pr","iteration"):
        ev[k] = int(v)
    elif k == "acus":
        try:
            ev[k] = float(v)
        except ValueError:
            print("cost-ledger.sh: corrupt --acus", file=sys.stderr)
            sys.exit(3)
    else:
        ev[k] = v
fr = (os.environ.get("CL_FLAT") or "").lower()
if fr in ("true","1","yes"):
    ev["flat_rate"] = True
elif fr in ("false","0","no"):
    ev["flat_rate"] = False
line = json.dumps(ev, separators=(",", ":"), sort_keys=True) + "\n"
with open(path, "a", encoding="utf-8") as f:
    f.write(line)
print("cost-ledger.sh: appended %s runner=%s hat=%s wall_ms=%s" % (
    ev["ts"], ev["runner"], ev["hat"], ev["wall_ms"]))
'
    ;;
  summarize)
    [[ -f "$LEDGER" ]] || die_corrupt "ledger not found: $LEDGER"
    [[ -L "$LEDGER" ]] && die_corrupt "ledger must not be a symlink"
    export CL_LEDGER="$LEDGER" CL_MERGED="${MERGED:-}" CL_FORMAT="$FORMAT" CL_PERIOD="${PERIOD_START:-}"
    python3 -c '
import json, os, sys
from collections import defaultdict

def fail(msg):
    print("cost-ledger.sh: %s" % msg, file=sys.stderr)
    sys.exit(3)

def as_nonneg_int(val, field, idx, required=False):
    """Strict integer: reject bool, float, numeric string, negatives. None ok if not required."""
    if val is None:
        if required:
            fail("event %d: %s is required" % (idx, field))
        return None
    # bool is a subclass of int — reject before isinstance(int).
    if isinstance(val, bool):
        fail("event %d: %s must be a non-negative integer, not boolean" % (idx, field))
    if isinstance(val, int):
        if val < 0:
            fail("event %d: %s must be non-negative" % (idx, field))
        return val
    # Reject floats (including 1.0) and numeric strings — no silent coercion.
    if isinstance(val, float):
        fail("event %d: %s must be a non-negative integer, not float" % (idx, field))
    if isinstance(val, str):
        fail("event %d: %s must be a non-negative integer, not string" % (idx, field))
    fail("event %d: %s has invalid type" % (idx, field))

def as_optional_str(val, field, idx):
    if val is None:
        return None
    if not isinstance(val, str):
        fail("event %d: %s must be a string" % (idx, field))
    return val

path = os.environ["CL_LEDGER"]
fmt = os.environ.get("CL_FORMAT") or "text"
period = os.environ.get("CL_PERIOD") or ""
merged_path = os.environ.get("CL_MERGED") or ""
events = []
with open(path, "r", encoding="utf-8") as f:
    for i, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError as e:
            fail("corrupt JSONL line %d: %s" % (i, e))
        if not isinstance(ev, dict) or ev.get("schema") != "gibson.cost.v1":
            fail("line %d: missing schema gibson.cost.v1" % i)
        # Validate required / optional numeric fields consistently (fail closed).
        as_nonneg_int(ev.get("wall_ms"), "wall_ms", i, required=True)
        for opt in ("tokens", "issue", "pr", "iteration"):
            if opt in ev and ev[opt] is not None:
                as_nonneg_int(ev[opt], opt, i, required=False)
        if "acus" in ev and ev["acus"] is not None:
            a = ev["acus"]
            if isinstance(a, bool) or not isinstance(a, (int, float)):
                fail("event %d: acus must be a number" % i)
            if a < 0:
                fail("event %d: acus must be non-negative" % i)
        for sfield in ("join_key", "requested_runner", "provider", "fallback_reason",
                       "event_kind", "runner", "pool", "hat", "repo", "note", "ts"):
            if sfield in ev and ev[sfield] is not None:
                as_optional_str(ev[sfield], sfield, i)
        if "flat_rate" in ev and ev["flat_rate"] is not None and not isinstance(ev["flat_rate"], bool):
            fail("event %d: flat_rate must be a boolean" % i)
        if period and str(ev.get("ts") or "") < period:
            continue
        events.append(ev)

# Parse merged PR list (fail closed on corrupt/ambiguous shapes).
merged_numbers = []
merged_set = set()
if merged_path:
    try:
        with open(merged_path, "r", encoding="utf-8") as f:
            merged_raw = json.load(f)
    except Exception as e:
        fail("merged-json: %s" % e)
    if not isinstance(merged_raw, list):
        fail("merged-json must be a JSON array")
    for i, item in enumerate(merged_raw):
        if isinstance(item, int) and not isinstance(item, bool):
            num = item
        elif isinstance(item, dict):
            if "number" not in item:
                fail("merged-json[%d]: missing number" % i)
            num = item["number"]
            if isinstance(num, bool) or not isinstance(num, int):
                fail("merged-json[%d]: number must be an integer" % i)
        else:
            fail("merged-json[%d]: want integer or object with number" % i)
        if num < 0:
            fail("merged-json[%d]: number must be non-negative" % i)
        if num in merged_set:
            fail("merged-json: duplicate PR number %d" % num)
        merged_set.add(num)
        merged_numbers.append(num)

# Build join_key -> PR map. Ambiguous (one key, multiple PRs) fails closed.
join_to_pr = {}
for i, ev in enumerate(events):
    jk = ev.get("join_key")
    if not jk:
        continue
    if not isinstance(jk, str):
        fail("event %d: join_key must be a string" % (i + 1))
    if "pr" not in ev or ev["pr"] is None:
        continue
    pr = as_nonneg_int(ev["pr"], "pr", i + 1, required=False)
    if pr is None:
        continue
    if jk in join_to_pr and join_to_pr[jk] != pr:
        fail("ambiguous join_key %r maps to PRs %s and %s" % (jk, join_to_pr[jk], pr))
    join_to_pr[jk] = pr

def event_pr(ev, idx):
    if "pr" not in ev or ev["pr"] is None:
        return None
    return as_nonneg_int(ev["pr"], "pr", idx, required=False)

def resolved_pr(ev, idx):
    # Prefer the event own pr; otherwise the join_key -> pr map.
    # A join_key that maps to two different PRs already fails closed while
    # building join_to_pr (ambiguous join_key). Once the map is consistent,
    # own != mapped cannot occur for an event that contributed its own pr, so
    # no separate conflict branch is needed (unreachable / redundant).
    own = event_pr(ev, idx)
    if own is not None:
        return own
    jk = ev.get("join_key") or ""
    if not isinstance(jk, str):
        fail("event %d: join_key must be a string" % idx)
    if not jk:
        return None
    return join_to_pr.get(jk)

def empty_pool():
    return {
        "events": 0, "wall_ms": 0,
        "tokens": 0, "tokens_known": 0,
        "merged_events": 0, "unmerged_events": 0,
        "merged_wall_ms": 0,
        "merged_pr_set": set(),
        "merged_tokens": 0, "merged_tokens_known": 0,
    }

by_pool = defaultdict(empty_pool)
by_hat = defaultdict(lambda: {"events": 0, "wall_ms": 0, "tokens": 0, "tokens_known": 0})
total_wall = total_tokens = tokens_known = 0
total_acus = 0.0
acus_known = 0
prs = set()
merged_events = 0
unmerged_events = 0
merged_wall = 0
merged_tokens = 0
merged_tokens_known = 0
per_pr = defaultdict(lambda: {
    "events": 0, "wall_ms": 0, "tokens": 0, "tokens_known": 0, "merged": False
})

for idx, ev in enumerate(events, 1):
    wall = as_nonneg_int(ev.get("wall_ms"), "wall_ms", idx, required=True)
    total_wall += wall
    pool = ev.get("pool") or "unknown"
    if not isinstance(pool, str):
        fail("event %d: pool must be a string" % idx)
    hat = ev.get("hat") or "other"
    if not isinstance(hat, str):
        fail("event %d: hat must be a string" % idx)
    by_pool[pool]["events"] += 1
    by_pool[pool]["wall_ms"] += wall
    by_hat[hat]["events"] += 1
    by_hat[hat]["wall_ms"] += wall
    tok = None
    if "tokens" in ev and ev["tokens"] is not None:
        tok = as_nonneg_int(ev["tokens"], "tokens", idx, required=False)
        total_tokens += tok
        tokens_known += 1
        by_pool[pool]["tokens"] += tok
        by_pool[pool]["tokens_known"] += 1
        by_hat[hat]["tokens"] += tok
        by_hat[hat]["tokens_known"] += 1
    if "acus" in ev and ev["acus"] is not None:
        total_acus += float(ev["acus"])
        acus_known += 1
    rpr = resolved_pr(ev, idx)
    if rpr is not None:
        prs.add(rpr)
        per_pr[rpr]["events"] += 1
        per_pr[rpr]["wall_ms"] += wall
        if tok is not None:
            per_pr[rpr]["tokens"] += tok
            per_pr[rpr]["tokens_known"] += 1
    is_merged = bool(merged_set) and rpr is not None and rpr in merged_set
    if is_merged:
        merged_events += 1
        merged_wall += wall
        per_pr[rpr]["merged"] = True
        by_pool[pool]["merged_events"] += 1
        by_pool[pool]["merged_wall_ms"] += wall
        by_pool[pool]["merged_pr_set"].add(rpr)
        if tok is not None:
            merged_tokens += tok
            merged_tokens_known += 1
            by_pool[pool]["merged_tokens"] += tok
            by_pool[pool]["merged_tokens_known"] += 1
    else:
        unmerged_events += 1
        by_pool[pool]["unmerged_events"] += 1

# Finalize per-pool metrics (distinct merged PRs + honest token averages).
by_pool_out = {}
for pool, d in sorted(by_pool.items()):
    n_mpr = len(d["merged_pr_set"])
    m_ev = d["merged_events"]
    m_tok_known = d["merged_tokens_known"]
    tokens_complete = (d["events"] > 0 and d["tokens_known"] == d["events"])
    merged_tokens_complete = (m_ev > 0 and m_tok_known == m_ev)
    by_pool_out[pool] = {
        "events": d["events"],
        "wall_ms": d["wall_ms"],
        "tokens": d["tokens"] if tokens_complete else None,
        "tokens_known_events": d["tokens_known"],
        "tokens_total_events": d["events"],
        "tokens_coverage_complete": tokens_complete,
        "merged_events": d["merged_events"] if merged_numbers else None,
        "unmerged_events": d["unmerged_events"] if merged_numbers else None,
        "merged_prs": n_mpr if merged_numbers else None,
        "merged_wall_ms": d["merged_wall_ms"] if merged_numbers else None,
        "wall_ms_per_merged_pr": (d["merged_wall_ms"] / n_mpr) if (merged_numbers and n_mpr) else None,
        "tokens_per_merged_pr": (
            (d["merged_tokens"] / n_mpr)
            if (merged_numbers and n_mpr and merged_tokens_complete) else None
        ),
        "merged_tokens_known_events": m_tok_known if merged_numbers else None,
        "merged_tokens_total_events": m_ev if merged_numbers else None,
        "merged_tokens_coverage_complete": merged_tokens_complete if merged_numbers else None,
    }

# Per-merged-PR report: every input merged PR appears; no cost is not success.
# tokens is null unless EVERY event on that PR recorded tokens.
per_merged = {}
merged_with_cost = 0
for num in merged_numbers:
    d = per_pr.get(num)
    if d and d["events"] > 0:
        merged_with_cost += 1
        complete = d["tokens_known"] == d["events"]
        entry = {
            "pr": num,
            "events": d["events"],
            "wall_ms": d["wall_ms"],
            "tokens": d["tokens"] if complete else None,
            "tokens_known_events": d["tokens_known"],
            "tokens_total_events": d["events"],
            "tokens_coverage_complete": complete,
            "has_cost_data": True,
        }
    else:
        entry = {
            "pr": num,
            "events": 0,
            "wall_ms": None,
            "tokens": None,
            "tokens_known_events": 0,
            "tokens_total_events": 0,
            "tokens_coverage_complete": False,
            "has_cost_data": False,
        }
    per_merged[str(num)] = entry

# Global tokens_per_merged_pr: null unless every merged event has tokens.
merged_tokens_complete = (merged_events > 0 and merged_tokens_known == merged_events)
cpm = None
if merged_numbers:
    cpm = {
        "merged_prs_in_input": len(merged_numbers),
        "merged_prs_with_cost": merged_with_cost,
        "merged_events": merged_events,
        "unmerged_events": unmerged_events,
        "merged_wall_ms": merged_wall,
        "wall_ms_per_merged_pr": (merged_wall / merged_with_cost) if merged_with_cost else None,
        "tokens_per_merged_pr": (
            (merged_tokens / merged_with_cost)
            if (merged_with_cost and merged_tokens_complete) else None
        ),
        "tokens_known_events": merged_tokens_known,
        "tokens_total_events": merged_events,
        "tokens_coverage_complete": merged_tokens_complete,
        "per_merged_pr": per_merged,
        # Legacy field: only average over PRs that have attributed cost data.
        "merged_prs": merged_with_cost,
        "events": merged_events,
    }

# Global total_tokens: null unless every event recorded tokens (same honesty
# rule as text output and per-pool / per-hat / per-merged-PR metrics). A partial
# known sum is exposed separately as tokens_known_sum for diagnostics only —
# never as total_tokens (a consumer that ignores coverage must not treat a
# partial sum as complete).
global_tokens_complete = (len(events) > 0 and tokens_known == len(events))
summary = {
    "schema": "gibson.cost.summary.v1",
    "events": len(events),
    "total_wall_ms": total_wall,
    "total_tokens": total_tokens if global_tokens_complete else None,
    "tokens_known_sum": total_tokens if tokens_known else None,
    "tokens_known_events": tokens_known,
    "tokens_total_events": len(events),
    "tokens_coverage_complete": global_tokens_complete,
    "total_acus": total_acus if acus_known else None,
    "acus_known_events": acus_known,
    "by_pool": by_pool_out,
    "by_hat": dict((k, {
        "events": v["events"],
        "wall_ms": v["wall_ms"],
        "tokens": v["tokens"] if (v["events"] > 0 and v["tokens_known"] == v["events"]) else None,
        "tokens_known_events": v["tokens_known"],
        "tokens_total_events": v["events"],
        "tokens_coverage_complete": (v["events"] > 0 and v["tokens_known"] == v["events"]),
    }) for k, v in sorted(by_hat.items())),
    "prs_touched": sorted(prs),
    "merged_events": merged_events if merged_numbers else None,
    "unmerged_events": unmerged_events if merged_numbers else None,
    "cost_per_merged_pr": cpm,
}
if fmt == "json":
    print(json.dumps(summary, indent=2, sort_keys=True))
    sys.exit(0)
print("cost-ledger summary: %d event(s), wall_ms=%d" % (len(events), total_wall))
if tokens_known:
    cov = "complete" if global_tokens_complete else "partial"
    print("  tokens (from %d/%d event(s) with data, coverage=%s): %s" % (
        tokens_known, len(events), cov,
        str(total_tokens) if global_tokens_complete else "unknown (incomplete coverage)"))
else:
    print("  tokens: unknown (no event recorded a token count - not zero)")
if acus_known:
    print("  ACUs (from %d event(s) with data): %s" % (acus_known, total_acus))
else:
    print("  ACUs: unknown")
print("  by pool:")
for pool, d in sorted(by_pool_out.items()):
    if d["tokens_coverage_complete"]:
        tok = ", tokens=%d" % d["tokens"]
    else:
        tok = ", tokens=unknown (%d/%d known)" % (d["tokens_known_events"], d["tokens_total_events"])
    extra = ""
    if merged_numbers:
        extra = ", merged_events=%s unmerged_events=%s merged_prs=%s" % (
            d["merged_events"], d["unmerged_events"], d["merged_prs"])
        if d["merged_prs"]:
            tpm = ("tokens_per_merged_pr=%.1f" % d["tokens_per_merged_pr"]) if d["tokens_per_merged_pr"] is not None else "tokens_per_merged_pr=unknown"
            extra += ", wall_ms_per_merged_pr=%.1f, %s" % (d["wall_ms_per_merged_pr"], tpm)
    print("    %s: events=%d wall_ms=%d%s%s" % (pool, d["events"], d["wall_ms"], tok, extra))
print("  by hat:")
for hat, d in sorted(summary["by_hat"].items()):
    print("    %s: events=%d wall_ms=%d" % (hat, d["events"], d["wall_ms"]))
if cpm:
    if cpm["merged_prs_with_cost"] > 0:
        extra = (", tokens=%.1f" % cpm["tokens_per_merged_pr"]) if cpm["tokens_per_merged_pr"] is not None else ", tokens=unknown (incomplete coverage %d/%d)" % (cpm["tokens_known_events"], cpm["tokens_total_events"])
        print("  cost-per-merged-PR (%d of %d merged PRs with cost data; %d merged events): wall_ms=%.1f%s" % (
            cpm["merged_prs_with_cost"], cpm["merged_prs_in_input"], cpm["merged_events"],
            cpm["wall_ms_per_merged_pr"], extra))
    else:
        print("  cost-per-merged-PR (0 of %d merged PRs with cost data): no attributed events (not zero-cost)" % (
            cpm["merged_prs_in_input"],))
    print("  unmerged events: %d" % cpm["unmerged_events"])
    for num in merged_numbers:
        entry = per_merged[str(num)]
        if entry["has_cost_data"]:
            if entry["tokens_coverage_complete"]:
                tok = ", tokens=%d" % entry["tokens"]
            else:
                tok = ", tokens=unknown (%d/%d known)" % (entry["tokens_known_events"], entry["tokens_total_events"])
            print("    PR #%d: events=%d wall_ms=%d%s" % (num, entry["events"], entry["wall_ms"], tok))
        else:
            print("    PR #%d: no attributed events (not zero-cost success)" % num)
else:
    print("  cost-per-merged-PR: n/a (pass --merged-json with >=1 PR)")
sys.exit(0)
'
    ;;
  *)
    die_usage "unknown command: $CMD (want append|summarize)"
    ;;
esac
