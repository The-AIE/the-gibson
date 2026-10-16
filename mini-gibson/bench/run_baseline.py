#!/usr/bin/env python3
"""Gibson Bench baseline runner.

Runs one configuration over the tasks in a bench file and writes one JSONL trace
per task plus results.json. Scoring is deterministic: the hidden test files from
the task's PR are copied in AFTER the episode and must pass. The model never
sees them and never grades itself.

Configurations (see manifest.v0.1.json):
  raw        same tools, same step cap, no harness policy
  harness    adds: phase prompt, inspect-before-edit, evidence gate with a repair
             budget of 3 (cheap syntax checks on changed files), then done
  (LoRA      = the harness config with --model pointing at the adapter)

Agents:
  llm        an OpenAI-compatible endpoint (vLLM). Uses a JSON-in-text action
             protocol, so it does not depend on server-side tool-call parsing.
  noop       does nothing. Sanity check: must score 0%.
  oracle     applies the reference (non-test) patch. Sanity check: must score 100%.
             Run noop and oracle first; if either is wrong the bench is broken.

Optional: --jev scores the final diff with the Jev semantic gate and records the
verdict next to the test result, giving the data needed to calibrate its
thresholds (does Jev agree with the tests?). Needs TYPESAFE_API_KEY.

Example:
  python3 run_baseline.py --repo /path/to/the-gibson --bench bench.json \
      --config harness --agent llm --model nemotron-base --out runs/harness
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from envs.gibson import Action, GibsonEnv, Task, TerminalState, Verification  # noqa: E402
from envs.gibson.reward import evidence_reward  # noqa: E402

RUNNERS = {".sh": ["bash"], ".mjs": ["node", "--test"], ".js": ["node", "--test"]}
CHECKERS = {".sh": ["bash", "-n"], ".mjs": ["node", "--check"], ".js": ["node", "--check"]}
MAX_STEPS = 30
MAX_REPAIRS = 3
TOOL_TIMEOUT = 60
TOOLS = ("list_dir", "read_file", "search", "write_file", "run_test_file")

PHASE_PROMPT = (
    "Work in phases: SCOUT (read the relevant code and tests), PLAN (say what you will change and why), "
    "BUILD (make the smallest change), TEST (run an existing test file that covers it), then DONE. "
    "You may not edit before you have read something. Do not say DONE until you have run a test."
)
RAW_PROMPT = "You are a software engineer fixing an issue in the repository at the current directory."
PROTOCOL = (
    "Reply with exactly one JSON object per turn in a ```json fenced block: "
    '{"tool": "<name>", "arguments": {...}} using one of: '
    "list_dir(path), read_file(path), search(pattern), write_file(path, content), run_test_file(path). "
    'When finished reply with {"tool": "done", "arguments": {"summary": "..."}}.'
)


def sh(cmd: list[str], cwd: Path, timeout: int = TOOL_TIMEOUT) -> tuple[int, str]:
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr)[-4000:]
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except FileNotFoundError as e:
        return 127, str(e)


def git(repo: Path, *a: str) -> str:
    r = subprocess.run(["git", "-C", str(repo), *a], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"git {' '.join(a)}: {r.stderr.strip()}")
    return r.stdout


# ---- tools (confined to the worktree) -----------------------------------------

def make_tools(wt: Path, state: dict, harness: bool):
    def safe(p: str) -> Path:
        q = (wt / p).resolve()
        if wt.resolve() not in q.parents and q != wt.resolve():
            raise PermissionError("path escapes the repository")
        if ".git" in q.relative_to(wt.resolve()).parts:
            raise PermissionError(".git is off limits")
        return q

    def list_dir(a):
        state["read"] = True
        return {"entries": sorted(x.name + ("/" if x.is_dir() else "") for x in safe(a.get("path", ".")).iterdir())[:200]}

    def read_file(a):
        state["read"] = True
        return {"content": safe(a["path"]).read_text(encoding="utf-8", errors="replace")[:12000]}

    def search(a):
        state["read"] = True
        _, out = sh(["git", "grep", "-n", "-I", "--max-count=5", "-e", str(a["pattern"])], wt)
        return {"matches": out[:4000]}

    def write_file(a):
        if harness and not state.get("read"):
            raise PermissionError("inspect before edit: read something first")
        p = safe(a["path"])
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(a["content"], encoding="utf-8")
        state["edited"].add(a["path"])
        return {"written": a["path"], "bytes": len(a["content"])}

    def run_test_file(a):
        p = safe(a["path"])
        runner = RUNNERS.get(p.suffix)
        if not runner:
            raise ValueError("unsupported test file type")
        code, out = sh(runner + [a["path"]], wt)
        state["tested"] = True
        return {"exit_code": code, "output_tail": out[-2000:]}

    return {"list_dir": list_dir, "read_file": read_file, "search": search, "write_file": write_file, "run_test_file": run_test_file}


# ---- agents -------------------------------------------------------------------

def chat(endpoint: str, model: str, messages: list[dict], api_key: str | None) -> str:
    body = json.dumps({"model": model, "messages": messages, "temperature": 0, "max_tokens": 2048}).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(endpoint.rstrip("/") + "/v1/chat/completions", data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)["choices"][0]["message"]["content"]


def parse_action(text: str) -> dict | None:
    m = re.search(r"```json\s*(\{.*?\})\s*```", text, re.S) or re.search(r"(\{.*\})", text, re.S)
    if not m:
        return None
    try:
        obj = json.loads(m.group(1))
        return obj if isinstance(obj, dict) and "tool" in obj else None
    except json.JSONDecodeError:
        return None


def evidence_gate(wt: Path, state: dict) -> str | None:
    """Cheap, deterministic checks on files the agent changed. Returns a failure message or None."""
    for f in sorted(state["edited"]):
        checker = CHECKERS.get(Path(f).suffix)
        if checker and (wt / f).exists():
            code, out = sh(checker + [f], wt)
            if code != 0:
                return f"syntax check failed for {f}: {out[-500:]}"
    if not state.get("tested"):
        return "no test has been run yet; run an existing test file that covers your change"
    return None


def run_llm_agent(env: GibsonEnv, task: Task, args, wt: Path, state: dict, harness: bool, trace) -> str:
    system = (PHASE_PROMPT if harness else RAW_PROMPT) + "\n" + PROTOCOL
    messages = [{"role": "system", "content": system}, {"role": "user", "content": task.issue}]
    final = ""
    for step in range(MAX_STEPS):
        reply = chat(args.endpoint, args.model, messages, os.getenv("VLLM_API_KEY"))
        trace({"kind": "model_reply", "step": step, "text": reply[:4000]})
        messages.append({"role": "assistant", "content": reply})
        action = parse_action(reply)
        if action is None:
            messages.append({"role": "user", "content": "Invalid reply. " + PROTOCOL})
            continue
        if action["tool"] == "done":
            final = str(action.get("arguments", {}).get("summary", ""))
            if harness:
                problem = evidence_gate(wt, state)
                if problem:
                    try:
                        env.note_repair()
                    except RuntimeError:
                        trace({"kind": "repair_budget_exceeded"})
                        return final
                    messages.append({"role": "user", "content": f"Evidence gate: {problem}. Fix it, then say done."})
                    continue
            return final
        obs, _ = env.step(Action(action["tool"], action.get("arguments", {})))
        trace({"kind": "tool", "step": step, "tool": action["tool"], "result": obs.tool_result})
        messages.append({"role": "user", "content": json.dumps(obs.tool_result)[:6000]})
    return final


def apply_oracle(repo: Path, wt: Path, rec: dict, state: dict) -> str:
    files = [f for f in git(repo, "diff", "--name-only", rec["base_commit"], rec["head_commit"]).split() if f not in rec["test_files"]]
    patch = git(repo, "diff", rec["base_commit"], rec["head_commit"], "--", *files)
    p = subprocess.run(["git", "-C", str(wt), "apply", "-"], input=patch, text=True, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("oracle patch did not apply: " + p.stderr[:300])
    state["edited"].update(files)
    return "oracle patch applied"


# ---- scoring ------------------------------------------------------------------

def hidden_tests_pass(repo: Path, wt: Path, rec: dict) -> bool:
    for f in rec["test_files"]:
        blob = subprocess.run(["git", "-C", str(repo), "show", f"{rec['head_commit']}:{f}"], capture_output=True)
        if blob.returncode != 0:
            continue
        (wt / f).parent.mkdir(parents=True, exist_ok=True)
        (wt / f).write_bytes(blob.stdout)
    for f in rec["test_files"]:
        code, _ = sh(RUNNERS[Path(f).suffix] + [f], wt, timeout=120)
        if code != 0:
            return False
    return True


def run_task(repo: Path, rec: dict, args, out: Path) -> dict:
    tmp = Path(tempfile.mkdtemp(prefix="gibson-run-"))
    wt = tmp / "wt"
    git(repo, "worktree", "add", "--detach", str(wt), rec["base_commit"])
    state: dict = {"read": False, "edited": set(), "tested": False}
    harness = args.config == "harness"
    trace_path = out / f"{rec['task_id']}.jsonl"
    started = time.time()

    with trace_path.open("w", encoding="utf-8") as tf:
        def trace(ev: dict) -> None:
            tf.write(json.dumps({"t": round(time.time() - started, 2), **ev}) + "\n")

        diff_text = {"v": ""}
        result: dict = {}

        def verifier(task: Task, events: list[dict]) -> Verification:
            passed = hidden_tests_pass(repo, wt, rec)
            diff_text["v"] = subprocess.run(["git", "-C", str(wt), "diff", "HEAD"], capture_output=True, text=True).stdout
            v = Verification(
                terminal_state=TerminalState.VERIFIED if passed else TerminalState.FAILED,
                requirement_satisfied=passed,
                tests_pass=passed,
                regression_test_added=None,
                lint_pass=None,
                typecheck_pass=None,
                unrelated_changes=False,
                unresolved_tool_errors=any(e.get("kind") == "tool_error" for e in events[-3:]),
                verifier_pass=passed,
            )
            v.reward_components = evidence_reward(v)
            return v

        env = GibsonEnv(make_tools(wt, state, harness), verifier)
        try:
            env.reset(Task(rec["task_id"], str(wt), rec["issue"], TOOLS, MAX_REPAIRS))
            if args.agent == "llm":
                final = run_llm_agent(env, env._task, args, wt, state, harness, trace)  # noqa: SLF001
            elif args.agent == "oracle":
                final = apply_oracle(repo, wt, rec, state)
            else:
                final = "noop"
            claimed_done = args.agent != "noop" and bool(final or state["edited"])
            v = env.verify()
            result = {
                "task_id": rec["task_id"], "config": args.config, "agent": args.agent, "model": args.model,
                "resolved": v.tests_pass, "terminal_state": v.terminal_state.value, "claimed_done": claimed_done,
                "false_done": claimed_done and not v.tests_pass, "files_edited": sorted(state["edited"]),
                "steps": sum(1 for e in env.events if e["kind"].startswith("tool")), "seconds": round(time.time() - started, 1),
            }
            if args.jev and diff_text["v"]:
                from envs.gibson.jev_verifier import JevJudge, build_state

                f = JevJudge().judge(build_state(env._task, v, diff_text["v"], final, ""))  # noqa: SLF001
                result["jev"] = {"verdict": f.verdict, "probabilities": f.probabilities, "reasons": f.reasons}
        except Exception as exc:  # one bad task must not sink the run
            result = {"task_id": rec["task_id"], "config": args.config, "resolved": False, "error": f"{type(exc).__name__}: {exc}"}
        trace({"kind": "result", **{k: v for k, v in result.items() if k != "jev"}})
    subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(wt)], capture_output=True)
    shutil.rmtree(tmp, ignore_errors=True)
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True, type=Path)
    ap.add_argument("--bench", required=True, type=Path, help="bench file with a 'tasks' list (see freeze_bench.py)")
    ap.add_argument("--split", default="development")
    ap.add_argument("--config", choices=["raw", "harness"], default="harness")
    ap.add_argument("--agent", choices=["llm", "noop", "oracle"], default="llm")
    ap.add_argument("--model", default="nemotron-base")
    ap.add_argument("--endpoint", default=f"http://{os.getenv('VLLM_HOST', '127.0.0.1')}:{os.getenv('VLLM_PORT', '8000')}")
    ap.add_argument("--jev", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    bench = json.loads(args.bench.read_text())
    tasks = [t for t in bench["tasks"] if t.get("split") == args.split]
    tasks = tasks[: args.limit] if args.limit else tasks
    args.out.mkdir(parents=True, exist_ok=True)
    results = [run_task(args.repo, t, args, args.out) for t in tasks]
    n = len(results) or 1
    summary = {
        "bench_sha256": bench.get("sha256"), "split": args.split, "config": args.config, "agent": args.agent, "model": args.model,
        "tasks": len(results), "resolved": sum(r["resolved"] for r in results),
        "task_resolution_rate": round(sum(r["resolved"] for r in results) / n, 3),
        "false_done_rate": round(sum(bool(r.get("false_done")) for r in results) / n, 3),
        "errors": sum("error" in r for r in results), "results": results,
    }
    (args.out / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "results"}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
