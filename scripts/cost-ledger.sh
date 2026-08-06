#!/usr/bin/env bash
# cost-ledger.sh - per-iteration cost ledger + cost-per-merged-PR rollup (L-003 / #74)
set -euo pipefail

usage() {
  cat <<'HELP'
cost-ledger.sh - per-iteration cost ledger (L-003 / issue #74)

WHAT IT DOES
  Records one JSONL event per loop iteration (or hat) with runner/pool, hat,
  wall time, and optional cost signals (tokens, ACUs, flat-rate marker).
  Summarizes cost-per-merged-PR when given a merged-PR list.

WHY
  L-003: unbounded coordinator sessions hide cost pathology. Unattended loops
  need a meter the morning digest can show.

RISKS
  - Append-only local file; never ships secrets.
  - Missing token/ACU fields stay unknown, never coerced to 0.
  - Does not bill anything.

COMMANDS
  cost-ledger.sh append --ledger PATH --runner NAME --hat NAME [options]
  cost-ledger.sh summarize --ledger PATH [--merged-since PATH] [--format text|json]
  cost-ledger.sh --help

APPEND OPTIONS
  --ledger PATH --runner NAME --pool NAME --hat NAME --wall-ms N
  --tokens N --acus N --flat-rate true|false --issue N --pr N
  --iteration N --repo owner/name --note TEXT --now ISO

SUMMARIZE OPTIONS
  --ledger PATH --merged-since PATH --format text|json --period-start ISO

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
    --merged-since) MERGED="${2:-}"; shift 2 ;;
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
    if [[ -n "$NOTE" && "$NOTE" == *$'\n'* ]]; then
      die_corrupt "--note must not contain newlines"
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
               ("pr","CL_PR"),("iteration","CL_ITER"),("repo","CL_REPO"),("note","CL_NOTE")):
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
            print("cost-ledger.sh: corrupt JSONL line %d: %s" % (i, e), file=sys.stderr)
            sys.exit(3)
        if not isinstance(ev, dict) or ev.get("schema") != "gibson.cost.v1":
            print("cost-ledger.sh: line %d: missing schema gibson.cost.v1" % i, file=sys.stderr)
            sys.exit(3)
        if period and str(ev.get("ts") or "") < period:
            continue
        events.append(ev)
merged = []
if merged_path:
    try:
        with open(merged_path, "r", encoding="utf-8") as f:
            merged = json.load(f)
        if not isinstance(merged, list):
            raise ValueError("merged-since must be a JSON array")
    except Exception as e:
        print("cost-ledger.sh: merged-since: %s" % e, file=sys.stderr)
        sys.exit(3)
by_pool = defaultdict(lambda: {"events": 0, "wall_ms": 0, "tokens": 0, "tokens_known": 0})
by_hat = defaultdict(lambda: {"events": 0, "wall_ms": 0, "tokens": 0, "tokens_known": 0})
total_wall = total_tokens = tokens_known = 0
total_acus = 0.0
acus_known = 0
prs = set()
for ev in events:
    total_wall += int(ev.get("wall_ms") or 0)
    pool = ev.get("pool") or "unknown"
    hat = ev.get("hat") or "other"
    by_pool[pool]["events"] += 1
    by_pool[pool]["wall_ms"] += int(ev.get("wall_ms") or 0)
    by_hat[hat]["events"] += 1
    by_hat[hat]["wall_ms"] += int(ev.get("wall_ms") or 0)
    if "tokens" in ev and ev["tokens"] is not None:
        t = int(ev["tokens"])
        total_tokens += t
        tokens_known += 1
        by_pool[pool]["tokens"] += t
        by_pool[pool]["tokens_known"] += 1
        by_hat[hat]["tokens"] += t
        by_hat[hat]["tokens_known"] += 1
    if "acus" in ev and ev["acus"] is not None:
        total_acus += float(ev["acus"])
        acus_known += 1
    if ev.get("pr") is not None:
        prs.add(int(ev["pr"]))
merged_count = len(merged) if merged else 0
cpm = None
if merged_count > 0:
    cpm = {
        "merged_prs": merged_count,
        "wall_ms_per_merged_pr": total_wall / merged_count,
        "tokens_per_merged_pr": (total_tokens / merged_count) if tokens_known else None,
        "tokens_known_events": tokens_known,
        "events": len(events),
    }
summary = {
    "schema": "gibson.cost.summary.v1",
    "events": len(events),
    "total_wall_ms": total_wall,
    "total_tokens": total_tokens if tokens_known else None,
    "tokens_known_events": tokens_known,
    "total_acus": total_acus if acus_known else None,
    "acus_known_events": acus_known,
    "by_pool": dict((k, dict(v)) for k, v in sorted(by_pool.items())),
    "by_hat": dict((k, dict(v)) for k, v in sorted(by_hat.items())),
    "prs_touched": sorted(prs),
    "cost_per_merged_pr": cpm,
}
if fmt == "json":
    print(json.dumps(summary, indent=2, sort_keys=True))
    sys.exit(0)
print("cost-ledger summary: %d event(s), wall_ms=%d" % (len(events), total_wall))
if tokens_known:
    print("  tokens (from %d event(s) with data): %d" % (tokens_known, total_tokens))
else:
    print("  tokens: unknown (no event recorded a token count - not zero)")
if acus_known:
    print("  ACUs (from %d event(s) with data): %s" % (acus_known, total_acus))
else:
    print("  ACUs: unknown")
print("  by pool:")
for pool, d in sorted(by_pool.items()):
    tok = (", tokens=%d" % d["tokens"]) if d["tokens_known"] else ", tokens=unknown"
    print("    %s: events=%d wall_ms=%d%s" % (pool, d["events"], d["wall_ms"], tok))
print("  by hat:")
for hat, d in sorted(by_hat.items()):
    print("    %s: events=%d wall_ms=%d" % (hat, d["events"], d["wall_ms"]))
if cpm:
    extra = (", tokens=%.1f" % cpm["tokens_per_merged_pr"]) if cpm["tokens_per_merged_pr"] is not None else ", tokens=unknown"
    print("  cost-per-merged-PR (%d merged): wall_ms=%.1f%s" % (
        cpm["merged_prs"], cpm["wall_ms_per_merged_pr"], extra))
else:
    print("  cost-per-merged-PR: n/a (pass --merged-since with >=1 PR)")
sys.exit(0)
'
    ;;
  *)
    die_usage "unknown command: $CMD (want append|summarize)"
    ;;
esac
