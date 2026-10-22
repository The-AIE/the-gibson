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
    probe does NOT record the trigger, so it retries next minute);
  * probe.json records each head the probe has already fired for, so a head the
    controller then skips for an unrelated reason (missing-vendor-hint,
    diff-too-large, ...) is fired at most once and otherwise left to the
    fallback scan, exactly as today. A snapshot-changed skip in the journal
    re-arms the head, because that skip discards a review after it started and
    the head is usually still current and still green.

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
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOCK_HELD_LINE = "another instance holds the lock"
CACHE_TTL_DAYS = 14

READY_QUERY = (
    "query($owner:String!,$name:String!,$base:String!){"
    "repository(owner:$owner,name:$name){"
    "pullRequests(states:OPEN,first:100,baseRefName:$base){"
    "pageInfo{hasNextPage}"
    "nodes{number isDraft headRefOid headRepository{nameWithOwner}"
    "commits(last:1){nodes{commit{statusCheckRollup{"
    "contexts(first:100){pageInfo{hasNextPage}nodes{__typename "
    "... on CheckRun{name status conclusion}"
    "... on StatusContext{context state}}}}}}}}}}}"
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


def _context_states(rollup):
    """Map context name -> (kind, status, conclusion/state) for the head commit."""
    out = {}
    if not isinstance(rollup, dict):
        return out
    contexts = rollup.get("contexts") or {}
    if (contexts.get("pageInfo") or {}).get("hasNextPage"):
        # More than 100 contexts: treat as not ready; the fallback scan decides.
        return None
    for node in contexts.get("nodes") or []:
        if not isinstance(node, dict):
            continue
        if node.get("__typename") == "CheckRun":
            out[node.get("name")] = ("check", node.get("status"), node.get("conclusion"))
        elif node.get("__typename") == "StatusContext":
            out[node.get("context")] = ("status", "COMPLETED", node.get("state"))
    return out


def _green(entry):
    if entry is None:
        return False
    _kind, status, outcome = entry
    return status == "COMPLETED" and outcome == "SUCCESS"


def _terminal(entry):
    if entry is None:
        return False
    _kind, status, outcome = entry
    return status == "COMPLETED" and outcome in ("SUCCESS", "FAILURE")


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


def _parse_stamp(text):
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def _rearm_after_snapshot_changed(cache, journal_path, tail_bytes=262144):
    """Drop cache entries whose head the controller abandoned as snapshot-changed.

    A snapshot-changed skip means the review was discarded after it started
    (head, base, labels or files moved). The head is often still the current one
    and still green, so it must be eligible to fire again immediately instead of
    waiting for the fallback scan. Only the journal tail is read.
    """
    if not journal_path.exists() or not cache:
        return cache
    try:
        with journal_path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - tail_bytes))
            lines = handle.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return cache
    latest = {}
    for line in lines:
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict) or record.get("reason") != "snapshot-changed":
            continue
        when = _parse_stamp(record.get("time"))
        key = (record.get("repo"), record.get("number"))
        if when is not None and (key not in latest or when > latest[key]):
            latest[key] = when
    if not latest:
        return cache
    kept = {}
    for key, record in cache.items():
        repo = key.split("@", 1)[0]
        triggered = _parse_stamp(record.get("triggered"))
        changed = latest.get((repo, record.get("number")))
        if triggered is not None and changed is not None and changed > triggered:
            _log("re-arm {0}#{1}: snapshot-changed at {2}".format(repo, record.get("number"), _stamp(changed)))
            continue
        kept[key] = record
    return kept


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
    state_dir.mkdir(parents=True, exist_ok=True)

    lock = None if args.dry_run else _acquire(state_dir / "probe.lock")
    if not args.dry_run and lock is None:
        _log("another probe holds the lock")
        return 0
    try:
        state = controller.load_state(state_dir / "state.json")
        github = controller.GitHubClient(policy["appId"], policy["appSlug"], policy["privateKeyPath"])
        cache_path = state_dir / "probe.json"
        cache = _prune(_load_cache(cache_path), _now())
        cache = _rearm_after_snapshot_changed(cache, state_dir / "journal.jsonl")
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
        completed = subprocess.run(
            [args.run_script],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        output = completed.stdout or ""
        sys.stdout.write(output)
        if LOCK_HELD_LINE in output:
            _log("controller busy; will retry next probe")
            return 0
        if completed.returncode != 0:
            _log("controller exited {0}; heads left for the fallback scan".format(completed.returncode))
            return 0
        now = _stamp(_now())
        for repo, number, _head, key in candidates:
            cache[key] = {"number": number, "triggered": now}
        _store_cache(cache_path, cache)
        _log("controller finished in {0:.0f}s".format(time.monotonic() - started))
        return 0
    finally:
        if lock is not None:
            lock.close()


if __name__ == "__main__":
    sys.exit(main())
