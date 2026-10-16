#!/usr/bin/env python3
"""Turn validated candidates into a Gibson Bench file and a manifest, with a hash.

Splits are TEMPORAL: the newest tasks become the temporal holdout, so anything
trained on history before `train_cutoff` cannot have seen them. The external
holdout needs tasks from a different repository and is left empty on purpose:
this script will not invent it. An empty external split is reported, not hidden.

By default the manifest stays DRAFT_DO_NOT_TUNE. Freezing is a human decision;
pass --freeze to stamp the hash and set status FROZEN. After that, any change to
the task list changes the hash and the runner's results no longer match.

Usage:
  python3 freeze_bench.py --candidates validated_candidates.json \
      --holdout 8 --out-bench bench.v0.1.json --out-manifest manifest.v0.1.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

KEEP = ("task_id", "pr", "repo", "base_commit", "head_commit", "date", "issue", "test_files", "source_files_changed")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--candidates", required=True, type=Path)
    ap.add_argument("--holdout", type=int, default=8, help="newest N fail-to-pass tasks become the temporal holdout")
    ap.add_argument("--out-bench", required=True, type=Path)
    ap.add_argument("--out-manifest", required=True, type=Path)
    ap.add_argument("--freeze", action="store_true")
    args = ap.parse_args()

    cands = json.loads(args.candidates.read_text())["candidates"]
    good = sorted((c for c in cands if c.get("fail_to_pass")), key=lambda c: c["date"])
    if len(good) <= args.holdout:
        raise SystemExit(f"only {len(good)} fail-to-pass tasks; need more than --holdout={args.holdout}")

    dev, holdout = good[: -args.holdout], good[-args.holdout:]
    tasks = [{**{k: c[k] for k in KEEP}, "split": "development"} for c in dev]
    tasks += [{**{k: c[k] for k in KEEP}, "split": "temporal_gibson_holdout"} for c in holdout]

    digest = hashlib.sha256(json.dumps(tasks, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    train_cutoff = holdout[0]["date"]
    bench = {"schema_version": "gibson-bench-tasks/v0.1", "sha256": digest, "train_cutoff": train_cutoff, "tasks": tasks}
    args.out_bench.write_text(json.dumps(bench, indent=2) + "\n")

    manifest = {
        "schema_version": "gibson-bench/v0.1",
        "status": "FROZEN" if args.freeze else "DRAFT_DO_NOT_TUNE",
        "freeze_required_before_lora": True,
        "bench_file": args.out_bench.name,
        "bench_sha256": digest,
        "train_cutoff": train_cutoff,
        "splits": {
            "development": [t["task_id"] for t in tasks if t["split"] == "development"],
            "temporal_gibson_holdout": [t["task_id"] for t in tasks if t["split"] == "temporal_gibson_holdout"],
            "external_holdout": [],
        },
        "external_holdout_note": "EMPTY: needs fail-to-pass tasks from a repository the model and the harness history never touched.",
        "configurations": ["raw_nemotron", "nemotron_gibson_harness", "mini_gibson_historical_lora"],
        "primary_metric": "task_resolution_rate",
        "secondary_metrics": ["false_done_rate", "jev_agreement_with_tests"],
        "failure_taxonomy": "failure-taxonomy.json",
    }
    args.out_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{len(dev)} development, {len(holdout)} temporal holdout, 0 external. sha256={digest[:12]} status={manifest['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
