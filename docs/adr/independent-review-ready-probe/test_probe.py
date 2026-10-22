#!/usr/bin/env python3
"""Smoke tests for the ready probe. Run: python3 -m unittest test_probe (from this directory)."""

import importlib.util
import json
import re
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("probe", HERE / "neuro-independent-review-probe.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)

REPO = "The-AIE/conference-os"
HEAD = "b78ed59503d996094a415d79545d3e2c12cbeecd"
OTHER = "931568082c6e5dce75a7cf3f7b8e839e279c2b9d"


class FakeController:
    SHA_RE = re.compile(r"^[0-9a-f]{40}$")

    class IncompleteRead(Exception):
        pass

    @staticmethod
    def _decode_json(payload):
        return json.loads(payload)

    @staticmethod
    def _published_key(repo, head):
        return "{0}@{1}".format(repo, head)


class FakeGitHub:
    def __init__(self, document):
        self.document = document
        self.calls = 0

    def _repo_json(self, repo, method, path, body=None):
        self.calls += 1
        assert method == "POST" and path == "/graphql"
        return 200, {}, json.dumps(self.document)


def check(name, status, conclusion, started="2026-10-22T00:00:00Z", ident=1):
    return {
        "__typename": "CheckRun",
        "name": name,
        "status": status,
        "conclusion": conclusion,
        "startedAt": started,
        "completedAt": None,
        "databaseId": ident,
    }


def status(context, state, created="2026-10-22T00:00:00Z", ident=1):
    return {"__typename": "StatusContext", "context": context, "state": state, "createdAt": created}


def rollup(nodes, more=False):
    return {"contexts": {"pageInfo": {"hasNextPage": more}, "nodes": nodes}}


def pull(number, head, nodes, draft=False, head_repo=REPO):
    return {
        "number": number,
        "isDraft": draft,
        "headRefOid": head,
        "headRepository": {"nameWithOwner": head_repo},
        "commits": {"nodes": [{"commit": {"statusCheckRollup": rollup(nodes)}}]},
    }


def document(pulls):
    return {"data": {"repository": {"pullRequests": {"pageInfo": {"hasNextPage": False}, "nodes": pulls}}}}


POLICY = {
    "requiredContexts": ["DCO", "quality", "build-e2e-required"],
    "reviewEvidenceContext": "review-evidence",
    "maxAttemptsPerHead": 2,
    "maxPullsPerRun": 3,
    "reviewerTimeoutSeconds": 900,
}
REPOSITORY = {"name": REPO, "defaultBranch": "main"}
GREEN = [
    status("DCO", "SUCCESS"),
    check("quality", "COMPLETED", "SUCCESS"),
    check("build-e2e-required", "COMPLETED", "SUCCESS"),
    check("review-evidence", "IN_PROGRESS", None),
]


class ContextStates(unittest.TestCase):
    def test_latest_run_wins_regardless_of_order(self):
        nodes = [
            check("quality", "COMPLETED", "SUCCESS", started="2026-10-22T00:10:00Z", ident=2),
            check("quality", "IN_PROGRESS", None, started="2026-10-22T00:20:00Z", ident=3),
            check("quality", "COMPLETED", "FAILURE", started="2026-10-22T00:00:00Z", ident=1),
        ]
        states = probe._context_states(rollup(nodes))
        self.assertEqual(states["quality"], ("check", "IN_PROGRESS", None))
        self.assertFalse(probe._green(states["quality"]))

    def test_status_context_is_terminal_on_success_or_failure(self):
        states = probe._context_states(rollup([status("review-evidence", "PENDING"), status("DCO", "SUCCESS")]))
        self.assertFalse(probe._terminal(states["review-evidence"]))
        self.assertTrue(probe._green(states["DCO"]))
        self.assertTrue(probe._terminal(probe._context_states(rollup([status("x", "FAILURE")]))["x"]))

    def test_more_than_100_contexts_is_not_ready(self):
        self.assertIsNone(probe._context_states(rollup([], more=True)))


class ReadyHeads(unittest.TestCase):
    def ready(self, pulls, state=None):
        github = FakeGitHub(document(pulls))
        found = probe.ready_heads(FakeController, github, POLICY, REPOSITORY, state or {})
        self.assertEqual(github.calls, 1)
        return found

    def test_green_unpublished_head_is_ready(self):
        self.assertEqual(self.ready([pull(2357, HEAD, GREEN)]), [(2357, HEAD)])

    def test_published_or_exhausted_or_draft_or_fork_is_not(self):
        key = FakeController._published_key(REPO, HEAD)
        self.assertEqual(self.ready([pull(2357, HEAD, GREEN)], {"published": {key: {}}}), [])
        self.assertEqual(self.ready([pull(2357, HEAD, GREEN)], {"attempts": {key: 2}}), [])
        self.assertEqual(self.ready([pull(2357, HEAD, GREEN, draft=True)]), [])
        self.assertEqual(self.ready([pull(2357, HEAD, GREEN, head_repo="someone/fork")]), [])

    def test_missing_or_pending_required_context_is_not_ready(self):
        self.assertEqual(self.ready([pull(2357, HEAD, GREEN[:2])]), [])
        pending = GREEN[:2] + [check("build-e2e-required", "IN_PROGRESS", None)]
        self.assertEqual(self.ready([pull(2357, HEAD, pending)]), [])

    def test_terminal_review_evidence_is_not_ready(self):
        done = GREEN[:3] + [check("review-evidence", "COMPLETED", "FAILURE")]
        self.assertEqual(self.ready([pull(2357, HEAD, done)]), [])

    def test_graphql_error_raises(self):
        github = FakeGitHub({"errors": [{"message": "nope"}]})
        with self.assertRaises(FakeController.IncompleteRead):
            probe.ready_heads(FakeController, github, POLICY, REPOSITORY, {})


class DecidedHeads(unittest.TestCase):
    CANDIDATES = [(REPO, 2357, HEAD, "k1"), (REPO, 2360, OTHER, "k2"), (REPO, 2361, OTHER, "k3")]

    def settled_numbers(self, output):
        return [c[1] for c in probe.decided_heads(output, self.CANDIDATES)]

    def test_verdict_and_unrelated_skip_settle(self):
        out = "{0}#2357 {1} fail\n{0}#2360 skip missing-vendor-hint\n".format(REPO, HEAD)
        self.assertEqual(self.settled_numbers(out), [2357, 2360])

    def test_retry_reasons_and_missing_lines_do_not_settle(self):
        out = "{0}#2357 skip required-context\n{0}#2360 skip snapshot-changed\nhalt\n".format(REPO)
        self.assertEqual(self.settled_numbers(out), [])

    def test_verdict_for_a_different_head_does_not_settle(self):
        out = "{0}#2357 {1} pass\n".format(REPO, OTHER)
        self.assertEqual(self.settled_numbers(out), [])

    def test_lock_line_settles_nothing(self):
        self.assertEqual(self.settled_numbers("another instance holds the lock\n"), [])


class RunTimeout(unittest.TestCase):
    def test_timeout_covers_every_slot(self):
        self.assertEqual(probe._run_timeout(POLICY), 900 * 3 + 300)


if __name__ == "__main__":
    unittest.main()
