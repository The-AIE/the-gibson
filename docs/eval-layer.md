---
title: "Eval layer (Langfuse)"
nav_exclude: true
---

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

# Eval layer

> **Non-normative.** Binding rules live in [`AGENTS.md`](../AGENTS.md). This page explains the eval scripts added in #583.

Gates tell you a change is safe to merge. Evals tell you whether the agent doing the work is any good, and whether a cheaper model or a different harness is good enough. This layer is four small scripts, no new dependencies, and works with no account at all.

## The loop

```
cost-ledger rows ──► eval-trace.mjs ──► traces (local JSONL, and Langfuse when keys are set)
dataset.v1.jsonl ──► eval-run.mjs   ──► .gibson-evals/runs/<variant>.json ──► eval-gate.mjs (pass/fail)
                          ▲
                   runner (the agent under test) + optional grader (Deming)
```

| Script | Job |
|---|---|
| `scripts/eval-dataset-lint.mjs` | Shape-check `evals/dataset.v1.jsonl` (15-30 cases, unique ids, machine-checkable `expect`, tier A/B/C) |
| `scripts/eval-run.mjs` | Run every case against `--runner`, score it, save a run file, send traces + scores. `--compare A B` diffs two saved runs |
| `scripts/eval-gate.mjs` | Exit nonzero below `--min-pass-rate`. Missing, empty, forged, grader-errored or case-set-mismatched results fail (run must cover every ID in `--dataset`, default `evals/dataset.v1.jsonl`) |
| `scripts/eval-trace.mjs` | Convert cost-ledger rows into Langfuse traces |

## Try it with no account

```bash
node scripts/eval-dataset-lint.mjs
node scripts/eval-run.mjs --variant cheap  --runner './my-runner.sh --model cheap'
node scripts/eval-run.mjs --variant strong --runner './my-runner.sh --model strong'
node scripts/eval-run.mjs --compare cheap strong
node scripts/eval-gate.mjs --variant strong --min-pass-rate 0.8
```

Results land in `.gibson-evals/` (gitignore it; it can hold prompts).

## The runner contract

Your runner reads one case as JSON on stdin (`{"id","input","tier"}`), prints its answer on stdout, and may print one stderr line:

```
GIBSON_EVAL_COST {"usd": 0.01, "tokens": 1234}
```

If any case omits cost, the run's total cost is `null` (unknown). It is never summed from a partial set.

## The grader seam (Deming)

`--grader CMD` receives `{"case","output","exit_code"}` on stdin and must print `{"verdict":"pass"|"fail","reason":"..."}`. A case passes only when its `expect` passes **and** the grader says pass. A grader that crashes, hangs, prints non-JSON or returns any other verdict fails the case and is counted in `grader_errors`; the gate fails on any grader error. This is Law 5: an unreadable grade is never a pass.

## Sending traces to Langfuse

Set these in the environment (or as repo secrets for the opt-in workflow):

```
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LANGFUSE_HOST=https://cloud.langfuse.com   # optional; EU/US cloud or your own host
```

The scripts post to Langfuse's REST ingestion endpoint with Basic auth. A remote host must be `https://` (plain `http://` is accepted only for localhost). With no keys they write locally and say `SKIPPED`. If the upload fails they say `FAILED` and keep the local copy; a down collector never fails a run.

**Secrets handling.** Keys come from the environment only. Before anything is written or sent, strings are scrubbed for Langfuse keys, common API-key shapes, GitHub/Slack tokens, AWS key ids and bearer tokens, plus the literal key values. That is a backstop, not permission to put secrets in prompts or ledger rows.

## CI

`.github/workflows/eval-gate.yml` is the opt-in job: manual `workflow_dispatch` with your `runner` command runs the real dataset and gates on the pass rate; it is never a required check. A weekly scheduled run (and a dispatch with an empty `runner`) executes a deterministic smoke test of the eval layer itself (`evals/smoke.v1.jsonl` echoed through `jq`, no model calls, no secrets) so the standing workflow keeps a recent green run and stays truthful in sensor-health. Promote the real run to a deployment gate once a dataset has earned a threshold you believe. Per the Gibson rules, that promotion is its own change.

## What is deliberately not here

- Langfuse **dataset runs / experiment UI sync.** Traces and scores are sent; mirroring the dataset into Langfuse datasets is a follow-up.
- Real model calls in CI. The runner is yours.
- Account creation, keys and plan choice. Those are owner decisions (G5, G14).
