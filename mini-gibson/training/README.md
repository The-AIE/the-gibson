# Mini Gibson training

## Reference method

Start from NVIDIA's verified Nemotron 3.5 Lightning BF16 LoRA recipe. The reference configuration is the control; changes require a measured reason.

Training goal: engineering-agent behavior, not memorization of Gibson source code.

Train on curated observable trajectories: task contract, repository/tool observations, explicit plans where recorded, tool calls/results, test/review failures, repairs, and verification evidence. Do not synthesize hidden chain-of-thought.

## Gate

Training is blocked until:
- Gibson Bench v0.1 is frozen;
- split/leakage report is frozen;
- 10+ gold trajectories pass provenance validation;
- raw Nemotron and Gibson Harness baselines exist.

Export the adapter/model artifact to a pinned Hugging Face revision and evaluate on untouched temporal and external holdouts before promotion.
