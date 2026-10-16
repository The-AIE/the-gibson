#!/usr/bin/env python3
"""Mine Gibson Bench candidate tasks from merged-PR history (SWE-bench style).

A candidate is a first-parent commit that changes at least one test file AND at
least one non-test source file. For each candidate we record the base commit
(its parent), the head commit, and the test files. With --validate we run the
head's test files against the base tree (must FAIL) and against the head tree
(must PASS). Only fail-to-pass candidates survive.

Outputs candidates only. It never edits the manifest and never freezes anything:
freezing is a human decision (see freeze_bench.py).

The reference patch is never written to the output. Issue text is the commit
subject only (the body often describes the fix).

Usage:
  python3 mine_tasks.py --repo /path/to/the-gibson --validate -o candidates.json
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TEST_RE = re.compile(r"(\.test\.(sh|mjs|js|py)$)|(^|/)tests?/")
SRC_RE = re.compile(r"^(scripts|ci|config|playbooks)/")
PR_RE = re.compile(r"\(#(\d+)\)\s*$")
RUNNERS = {".sh": ["bash"], ".mjs": ["node", "--test"], ".js": ["node", "--test"], ".py": [sys.executable, "-I", "-m", "pytest", "-q"]}


def git(repo: Path, *args: str, check: bool = True) -> str:
    out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and out.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {out.stderr.strip()}")
    return out.stdout


def candidates(repo: Path) -> list[dict]:
    log = git(repo, "log", "--first-parent", "--no-merges", "--format=@@@%H%x1f%aI%x1f%s", "--name-only")
    records: list[dict] = []
    for block in log.split("@@@")[1:]:
        lines = block.splitlines()
        meta = lines[0].split("\x1f")
        files = [ln.strip() for ln in lines[1:] if ln.strip()]
        if len(meta) != 3:
            continue
        sha, date, subject = meta
        tests = [f for f in files if TEST_RE.search(f) and Path(f).suffix in RUNNERS]
        src = [f for f in files if SRC_RE.match(f) and not TEST_RE.search(f)]
        m = PR_RE.search(subject)
        if not (tests and src and m):
            continue
        parent = git(repo, "rev-parse", f"{sha}^", check=False).strip()
        if not parent:
            continue
        records.append({
            "task_id": f"gibson-pr-{m.group(1)}",
            "pr": int(m.group(1)),
            "repo": "The-AIE/the-gibson",
            "base_commit": parent,
            "head_commit": sha,
            "date": date,
            "issue": PR_RE.sub("", subject).strip(),
            "test_files": sorted(tests),
            "source_files_changed": len(src),
        })
    return records


def run_tests(tree: Path, test_files: list[str], timeout: int = 45) -> bool | None:
    """True = all pass, False = a failure, None = could not run (missing tool/timeout)."""
    for f in test_files:
        cmd = RUNNERS[Path(f).suffix] + [f]
        try:
            r = subprocess.run(cmd, cwd=tree, capture_output=True, text=True, timeout=timeout)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return None
        if r.returncode != 0:
            return False
    return True


def validate(repo: Path, rec: dict) -> dict:
    tmp = Path(tempfile.mkdtemp(prefix="gibson-bench-"))
    base, head = tmp / "base", tmp / "head"
    try:
        git(repo, "worktree", "add", "--detach", str(base), rec["base_commit"])
        git(repo, "worktree", "add", "--detach", str(head), rec["head_commit"])
        for f in rec["test_files"]:  # tests as of head, dropped onto the base tree
            src = head / f
            if src.exists():
                (base / f).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, base / f)
        at_base = run_tests(base, rec["test_files"])
        at_head = run_tests(head, rec["test_files"])
        rec = {**rec, "validation": {"base": at_base, "head": at_head}}
        rec["fail_to_pass"] = at_base is False and at_head is True
        return rec
    finally:
        for w in (base, head):
            git(repo, "worktree", "remove", "--force", str(w), check=False)
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True, type=Path)
    ap.add_argument("--validate", action="store_true", help="run tests at base/head and keep only fail-to-pass")
    ap.add_argument("--limit", type=int, default=0, help="validate at most N newest candidates (0 = all)")
    ap.add_argument("-o", "--output", required=True, type=Path)
    args = ap.parse_args()

    recs = sorted(candidates(args.repo), key=lambda r: r["date"])
    print(f"{len(recs)} raw candidates", file=sys.stderr)
    if args.validate:
        pool = recs[-args.limit:] if args.limit else recs
        out = []
        for r in pool:
            v = validate(args.repo, r)
            print(f"  {v['task_id']}: base={v['validation']['base']} head={v['validation']['head']}", file=sys.stderr)
            out.append(v)
        recs = out
    args.output.write_text(json.dumps({"schema_version": "gibson-bench-candidates/v0.1", "candidates": recs}, indent=2) + "\n")
    kept = [r for r in recs if r.get("fail_to_pass")] if args.validate else recs
    print(f"{len(kept)} {'fail-to-pass' if args.validate else 'unvalidated'} candidates -> {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
