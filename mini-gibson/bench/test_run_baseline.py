"""Exercises the runner's LLM-agent path against a scripted local server (no GPU, no model).

Needs a clone of the Gibson repo: GIBSON_REPO=/path/to/the-gibson python3 -m pytest bench
"""
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from argparse import Namespace
from pathlib import Path

import pytest

from . import run_baseline as rb

REPO = os.getenv("GIBSON_REPO")
BENCH = Path(__file__).with_name("bench.v0.1.json")
pytestmark = pytest.mark.skipif(not (REPO and BENCH.exists()), reason="set GIBSON_REPO and generate bench.v0.1.json")


def action(tool, **arguments):
    return "```json\n" + json.dumps({"tool": tool, "arguments": arguments}) + "\n```"


def serve(replies):
    state = {"i": 0}

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            text = replies[min(state["i"], len(replies) - 1)]
            state["i"] += 1
            body = json.dumps({"choices": [{"message": {"content": text}}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def run(config, replies, tmp_path):
    rec = json.loads(BENCH.read_text())["tasks"][0]
    srv = serve(replies)
    try:
        args = Namespace(config=config, agent="llm", model="stub", endpoint=f"http://127.0.0.1:{srv.server_port}", jev=False)
        result = rb.run_task(Path(REPO), rec, args, tmp_path)
    finally:
        srv.shutdown()
    trace = [json.loads(line) for line in (tmp_path / f"{rec['task_id']}.jsonl").read_text().splitlines()]
    return result, trace


def test_harness_denies_edit_before_read_and_enforces_the_evidence_gate(tmp_path):
    replies = [action("write_file", path="NOTES.txt", content="x"), action("read_file", path="README.md")] + [action("done", summary="finished")]
    result, trace = run("harness", replies, tmp_path)
    denied = [e for e in trace if e["kind"] == "tool" and e["result"] and e["result"].get("error") == "PermissionError"]
    assert denied, "write before read should be denied in the harness config"
    assert any(e["kind"] == "repair_budget_exceeded" for e in trace), "never-tested 'done' must exhaust the repair budget"
    assert result["resolved"] is False
    assert result["false_done"] is True  # claimed done, hidden tests say no


def test_raw_config_allows_edit_without_reading_and_stops_at_done(tmp_path):
    replies = [action("write_file", path="NOTES.txt", content="x"), action("done", summary="finished")]
    result, trace = run("raw", replies, tmp_path)
    assert result["files_edited"] == ["NOTES.txt"]
    assert not any(e["kind"] == "repair_budget_exceeded" for e in trace)
    assert result["false_done"] is True


def test_tools_cannot_escape_the_worktree(tmp_path):
    replies = [action("read_file", path="../../etc/passwd"), action("done", summary="x")]
    _, trace = run("raw", replies, tmp_path)
    escape = [e for e in trace if e["kind"] == "tool" and e["result"] and e["result"].get("error") == "PermissionError"]
    assert escape
