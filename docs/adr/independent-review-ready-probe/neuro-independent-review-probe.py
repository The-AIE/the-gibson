#!/usr/bin/env python3
"""Ready probe for the independent reviewer.

Runs every 60 seconds from launchd. One GraphQL call per covered repository
answers "is any open pull request reviewable right now?" (required contexts
green on the current head, review evidence not yet terminal, head not already
published or exhausted). When a head becomes reviewable for the first time,
the probe runs the existing controller wrapper once. Everything else is
unchanged: the controller keeps its own lock, its per-head published map, its
attempt and daily budgets, and the 15-minute scan still runs as the fallback.

Single-flight is preserved three ways:
  * probe.lock stops two probes overlapping;
  * the controller's controller.lock stops a probe-started run overlapping a
    scheduled run (the loser prints "another instance holds the lock" and the
    probe records nothing, so it retries next minute);
  * probe.json records each head the controller has DECIDED after a probe run.
    The wrapper prints one line per pull request it reached ("repo#N skip
    <reason>" or "repo#N <sha> pass|fail"); a head is recorded only when its
    line is present and the reason is not one that means "try again"
    (required-context, snapshot-changed, snapshot-unreadable, halt). A head the
    controller skips for a reason the probe cannot see (missing-vendor-hint,
    diff-too-large, ...) is therefore fired once and then left to the fallback
    scan, exactly as today. A head the controller never reached (halt,
    vendor-state-not-plain, budget-run) is not recorded and fires again next
    minute.

The probe never writes the controller's journal or state.json. It imports the
controller module only for its policy loader, GitHub App client and key
helpers, so there is one source of truth for authentication.

Python 3.9 compatible (the Mini's system python).
"""

import argparse
import fcntl
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOCK_HELD_LINE = "another instance holds the lock"
CACHE_TTL_DAYS = 14
# Skip reasons after which the same head should fire again on the next probe.
RETRY_REASONS = frozenset(["required-context", "snapshot-changed", "snapshot-unreadable", "halt"])
DECISION_RE = re.compile(r"^(?P<repo>[^\s#]+)#(?P<number>\d+) (?P<rest>.+)$")

READY_QUERY = (
    "query($owner:String!,$name:String!,$base:String!){"
    "repository(owner:$owner,name:$name){"
    "pullRequests(states:OPEN,first:100,baseRefName:$base){"
    "pageInfo{hasNextPage}"
    "nodes{number isDraft headRefOid headRepository{nameWithOwner}"
    "commits(last:1){nodes{commit{statusCheckRollup{"
    "contexts(first:100){pageInfo{hasNextPage}nodes{__typename "
    "... on CheckRun{name status conclusion startedAt completedAt databaseId}"
    "... on StatusContext{context state createdAt}}}}}}}}}}}"
)


def _load_controller(path):
    spec = importlib.util.spec_from_file_location("neuro_independent_review", str(path))
    if spec is None or spec.loader is None:
        raise SystemExit("controller module is unreadable: {0}".format(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _now():
    return datetime.now(timezone.utc)


def _stamp(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def _log(message):
    sys.stdout.write("{0} {1}\n".format(_stamp(_now()), message))
    sys.stdout.flush()


def _acquire(path):
    handle = open(path, "a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def _order_key(node):
    """Latest signal wins, like the controller's _latest(): newest stamp, then id."""
    stamp = node.get("completedAt") or node.get("startedAt") or node.get("createdAt") or ""
    try:
        ident = int(node.get("databaseId") or 0)
    except (TypeError, ValueError):
        ident = 0
    return (stamp, ident)


def _context_states(rollup):
    """Map context name -> (kind, status, conclusion/state) for the head commit."""
    out = {}
    if not isinstance(rollup, dict):
        return out
    contexts = rollup.get("contexts") or {}
    if (contexts.get("pageInfo") or {}).get("hasNextPage"):
        # More than 100 contexts: treat as not ready; the fallback scan decides.
        return None
    newest = {}
    for node in contexts.get("nodes") or []:
        if not isinstance(node, dict):
            continue
        kind = node.get("__typename")
        if kind == "CheckRun":
            name = node.get("name")
            entry = ("check", node.get("status"), node.get("conclusion"))
        elif kind == "StatusContext":
            name = node.get("context")
            entry = ("status", "COMPLETED", node.get("state"))
        else:
            continue
        key = _order_key(node)
        if name not in newest or key > newest[name]:
            newest[name] = key
            out[name] = entry
    return out


def _green(entry):
    if entry is None:
        return False
    _kind, status, outcome = entry
    return status == "COMPLETED" and outcome == "SUCCESS"


# Outcomes that mean "still running" for a completed status/check. Anything else
# on a completed signal (SUCCESS, FAILURE, ERROR, CANCELLED, TIMED_OUT, NEUTRAL,
# SKIPPED, ACTION_REQUIRED, STALE, STARTUP_FAILURE) is terminal for the probe.
# This is stricter than the controller's own evidence test, which treats only
# success/failure as terminal: the probe is a pre-filter, so being conservative
# costs at most one fallback tick and can never start a run the controller would
# not have started on its own.
NOT_TERMINAL = frozenset(["PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"])


def _terminal(entry):
    if entry is None:
        return False
    _kind, status, outcome = entry
    return status == "COMPLETED" and outcome is not None and outcome not in NOT_TERMINAL


def ready_heads(controller, github, policy, repository, state):
    """Return [(number, head)] that look reviewable and are not yet published."""
    repo = repository["name"]
    owner, name = repo.split("/", 1)
    _status, _headers, payload = github._repo_json(
        repo,
        "POST",
        "/graphql",
        {
            "query": READY_QUERY,
            "variables": {"owner": owner, "name": name, "base": repository["defaultBranch"]},
        },
    )
    document = controller._decode_json(payload)
    if not isinstance(document, dict) or document.get("errors"):
        raise controller.IncompleteRead("ready query failed")
    pulls = (((document.get("data") or {}).get("repository") or {}).get("pullRequests") or {})
    if (pulls.get("pageInfo") or {}).get("hasNextPage"):
        _log("{0}: more than 100 open pull requests; probe covers the first page only".format(repo))
    published = state.get("published") or {}
    attempts = state.get("attempts") or {}
    evidence = policy["reviewEvidenceContext"]
    required = policy["requiredContexts"]
    max_attempts = int(policy["maxAttemptsPerHead"])
    found = []
    for pull in pulls.get("nodes") or []:
        if not isinstance(pull, dict) or pull.get("isDraft"):
            continue
        head = pull.get("headRefOid")
        number = pull.get("number")
        if not isinstance(head, str) or controller.SHA_RE.fullmatch(head) is None:
            continue
        if ((pull.get("headRepository") or {}).get("nameWithOwner")) != repo:
            continue
        key = controller._published_key(repo, head)
        if key in published:
            continue
        if int(attempts.get(key, 0) or 0) >= max_attempts:
            continue
        commits = ((pull.get("commits") or {}).get("nodes") or [])
        rollup = (((commits[0] if commits else {}) or {}).get("commit") or {}).get("statusCheckRollup")
        states = _context_states(rollup)
        if states is None:
            continue
        if _terminal(states.get(evidence)):
            continue
        if all(_green(states.get(context)) for context in required):
            found.append((int(number), head))
    return found


def decided_heads(output, candidates):
    """Candidates the controller reached and settled, from the wrapper's stdout.

    ``candidates`` is a list of (repo, number, head, key). A candidate is settled
    when the output holds a line for its repo and number that is a pass/fail
    verdict for that exact head, or a skip whose reason is not in RETRY_REASONS.
    """
    decisions = {}
    for line in output.splitlines():
        match = DECISION_RE.match(line.strip())
        if match is None:
            continue
        decisions.setdefault((match.group("repo"), int(match.group("number"))), []).append(
            match.group("rest")
        )
    settled = []
    for repo, number, head, key in candidates:
        for rest in decisions.get((repo, number), []):
            parts = rest.split()
            if parts[0] == "skip":
                reason = parts[1] if len(parts) > 1 else ""
                if reason not in RETRY_REASONS:
                    settled.append((repo, number, head, key))
                    break
            elif len(parts) == 2 and parts[0] == head and parts[1] in ("pass", "fail"):
                settled.append((repo, number, head, key))
                break
    return settled


def _load_cache(path):
    if not path.exists():
        return {}
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    return document if isinstance(document, dict) else {}


def _store_cache(path, cache):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        handle.write(json.dumps(cache, sort_keys=True))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def _prune(cache, now):
    cutoff = now - timedelta(days=CACHE_TTL_DAYS)
    kept = {}
    for key, record in cache.items():
        try:
            when = datetime.strptime(record.get("triggered", ""), "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc
            )
        except (AttributeError, ValueError):
            continue
        if when >= cutoff:
            kept[key] = record
    return kept


def _run_timeout(policy):
    """Longest a wrapper run may take: every slot at the reviewer timeout, plus the scan."""
    per_pull = int(policy.get("reviewerTimeoutSeconds") or 900)
    slots = int(policy.get("maxPullsPerRun") or 1)
    return per_pull * slots + 300


class _Completed(object):
    def __init__(self, stdout, returncode):
        self.stdout = stdout
        self.returncode = returncode


def run_wrapper(path, timeout):
    """Run the wrapper in its own process group; on timeout kill the whole group.

    Killing only the direct child would let the controller (or a vendor CLI it
    spawned) outlive the probe and keep controller.lock, which would park the
    fallback scan. SIGKILL to the group reaps every descendant that stayed in
    it. Returns (stdout, returncode, timed_out).
    """
    import signal

    child = subprocess.Popen(
        [path],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        output, _ = child.communicate(timeout=timeout)
        return output or "", child.returncode, False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            output, _ = child.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            output = ""
        return output or "", child.returncode, True


def main(argv=None):
    parser = argparse.ArgumentParser(prog="neuro-independent-review-probe")
    parser.add_argument("--policy", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--run-script", required=True, help="the existing controller wrapper")
    parser.add_argument(
        "--controller",
        default=str(Path(__file__).resolve().parent / "neuro-independent-review.py"),
    )
    parser.add_argument("--dry-run", action="store_true", help="report readiness; run nothing; write nothing")
    args = parser.parse_args(argv)

    controller = _load_controller(args.controller)
    policy = controller.load_policy(args.policy)
    state_dir = Path(args.state_dir)
    if not args.dry_run:
        state_dir.mkdir(parents=True, exist_ok=True)

    lock = None if args.dry_run else _acquire(state_dir / "probe.lock")
    if not args.dry_run and lock is None:
        _log("another probe holds the lock")
        return 0
    try:
        state = controller.load_state(state_dir / "state.json")
        github = controller.GitHubClient(policy["appId"], policy["appSlug"], policy["privateKeyPath"])
        cache_path = state_dir / "probe.json"
        loaded = _load_cache(cache_path)
        cache = _prune(loaded, _now())
        if cache != loaded and not args.dry_run:
            _store_cache(cache_path, cache)
        candidates = []
        for repository in policy["repositories"]:
            for number, head in ready_heads(controller, github, policy, repository, state):
                key = controller._published_key(repository["name"], head)
                if key in cache:
                    continue
                candidates.append((repository["name"], number, head, key))
        if args.dry_run:
            for repo, number, head, _key in candidates:
                _log("ready {0}#{1} {2}".format(repo, number, head))
            if not candidates:
                _log("nothing newly reviewable")
            return 0
        if not candidates:
            return 0
        for repo, number, head, _key in candidates:
            _log("trigger {0}#{1} {2}".format(repo, number, head))
        started = time.monotonic()
        output, returncode, timed_out = run_wrapper(args.run_script, _run_timeout(policy))
        if timed_out:
            sys.stdout.write(output)
            # A timed-out run is settled for the probe's purposes: these heads go
            # to the fallback scan only, so a hung wrapper cannot be re-fired by
            # the probe every minute and starve the scheduled job of the lock.
            now = _stamp(_now())
            for repo, number, _head, key in candidates:
                cache[key] = {"number": number, "triggered": now, "timeout": True}
            _store_cache(cache_path, cache)
            _log("controller killed after {0}s; heads left for the fallback scan".format(_run_timeout(policy)))
            return 0
        completed = _Completed(output, returncode)
        output = completed.stdout or ""
        sys.stdout.write(output)
        if LOCK_HELD_LINE in output:
            _log("controller busy; will retry next probe")
            return 0
        if completed.returncode != 0:
            _log("controller exited {0}; heads left for the fallback scan".format(completed.returncode))
            return 0
        settled = decided_heads(output, candidates)
        now = _stamp(_now())
        for repo, number, _head, key in settled:
            cache[key] = {"number": number, "triggered": now}
        if settled:
            _store_cache(cache_path, cache)
        for repo, number, _head, _key in candidates:
            if (repo, number) not in {(s[0], s[1]) for s in settled}:
                _log("not settled {0}#{1}; fires again next probe".format(repo, number))
        _log("controller finished in {0:.0f}s".format(time.monotonic() - started))
        return 0
    finally:
        if lock is not None:
            lock.close()


if __name__ == "__main__":
    sys.exit(main())
