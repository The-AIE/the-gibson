# Mini Gibson

Reproducible small-model engineering-agent experiment for the NVIDIA × Red Hat Small Models Hack.

## Stack

- Hugging Face Hub: immutable model/dataset/adapter artifacts
- NVIDIA Brev: disposable GPU compute
- NeMo Megatron Bridge: Nemotron 3.5 Lightning LoRA training/export
- vLLM: OpenAI-compatible inference and LoRA serving
- Hermes: `mini-gibson` agent profile
- Gibson: tools, state/recovery policy, evidence gate, telemetry, and benchmark

## Bootstrap

1. Copy `env/versions.env.example` to `env/versions.env`.
2. Replace every `UNPINNED` value with an immutable revision/digest before benchmark runs.
3. Inject `HF_TOKEN` and any vLLM API key as runtime secrets; never commit them.
4. Run `bash env/setup-brev.sh`.
5. Run `bash env/verify-env.sh`.
6. Start inference with `bash inference/serve-vllm.sh`.
7. Run `python3 inference/smoke-test.py`.

The verifier intentionally fails when reproducibility-critical revisions remain unpinned.

## Training gate

Do not train until Gibson Bench v0.1 and its splits are frozen, at least ten gold trajectories validate, and A/B baselines are captured.

Historical LoRA is promoted only if it improves held-out evidence.

## Story, bench and the Jev gate

- [NARRATIVE.md](NARRATIVE.md): the problem, what we hope to see, what we learn if it fails.
- `bench/mine_tasks.py` mines fail-to-pass tasks from merged PRs; `bench/freeze_bench.py` splits them by date and hashes the result. The manifest stays `DRAFT_DO_NOT_TUNE` until a human freezes it.
- `bench/run_baseline.py` runs `raw` or `harness` over a split with a `llm`, `noop` or `oracle` agent. Run `noop` (must score 0%) and `oracle` (must score 100%) before trusting any model result.
- `envs/gibson/jev_verifier.py` is the optional Jev semantic gate. It can only downgrade a result. Needs `pip install typesafe-sdk` and `TYPESAFE_API_KEY`.
- Tests: `GIBSON_REPO=/path/to/the-gibson python3 -m pytest bench envs` (from `mini-gibson/`).
