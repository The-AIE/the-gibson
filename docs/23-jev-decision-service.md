---
title: "Optional Jev decision service"
nav_order: 30
---

# Optional Jev decision service

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

Jev supplies bounded structured advice. It is disabled by default and is not a coding model, reviewer, supervisor executor, or source of verification authority. The existing deterministic gates, human gates, tool permissions, retry budgets, and exact-head review requirements remain authoritative under `AGENTS.md`.

The intent follows [Mini Gibson's Jev manifest](https://github.com/mrhinkle/mini-gibson/blob/7f07206fdb6aadb716258166a1ffe120221010d3/integrations/jev.yaml). The implementation calls the [official TypeSafe API](https://docs.typesafe.ai/api) directly, with no SDK dependency or MCP intermediary. Endpoint `https://api.typesafe.ai/v1/systemone` and model `jev-1.13.0` are pinned; aliases and endpoint overrides are refused. This is a versioned, opt-in integration, not provider account provisioning or production activation.

## Supported advice

| Use | Answers | Integration point |
| --- | --- | --- |
| `supervisor-escalation` | `action`: continue, retry_infrastructure, stop, human_escalation; `needs_human`: Noul probability; `run_risk`: Score | Optional receipt when the existing loop escalates; the existing reviewer still runs |
| `model-or-agent-routing` | `route`: hermes, codex, claude_code, grok, human | Explicit operator query; no automatic dispatch or reviewer selection |
| `tool-call-guard` | `allow_tool_call`: Noul probability; `risk`: Score | Metadata classification for an external caller; the answer grants no permission |
| `benchmark-anomaly-triage` | `anomaly_class`: expected_task_failure, infrastructure_failure, telemetry_corruption, requires_human_review | Report-only query for an external evaluator; no relabeling or score changes |

Gibson currently has no central tool interceptor or model benchmark runner. The last two modes are callable interfaces, not automatic enforcement. They do not replace Evidence Gate logic in an adopter or in Mini Gibson. No question or accepted answer can award `VERIFIED`, promote an adapter, generate code, supply a rationale, or inspect hidden benchmark answers. Strict enum/boolean/count summaries exclude code, free text, raw tool arguments, test answers, credentials, and personal data. Caller metadata still discloses operational information to TypeSafe when enabled.

## Configuration and activation

`config/jev.v1.json` is the complete nonsecret configuration. `integrations/jev/config.schema.json` documents its closed schema. Unknown fields (including keys, URLs, permissions, and arbitrary questions) are rejected. API credentials are read only from the server-side process environment as `TYPESAFE_API_KEY`; never place a key in config, a request file, command arguments, source control, or browser code. This change creates no key and makes no paid live requests.

For an intentional operator query, put a valid summary request in a local JSON file, provide the key through your existing environment manager, and run:

```bash
GIBSON_JEV_ENABLED=1 node scripts/jev-decision.mjs --request summary.json --out jev-advice-001.json
```

`GIBSON_JEV_ENABLED` accepts only `0` or `1` and overrides `enabled` for that CLI invocation. When disabled, no key is required and there are zero network requests. CLI configuration/file/JSON errors exit 2 with sanitized diagnostics. Flag parsing follows repository conventions and may echo an invalid option token or enum value, so credentials must stay in the environment. An unavailable service returns an explicit fallback receipt with exit 0. A receipt write failure exits 1. Output basenames must match `jev-[a-z0-9-]+.json`. Files are created exclusively with private permissions; existing files and Gibson's review-receipt filenames are refused. Each output is immutable rather than a replaceable gate receipt.

The supervisor loop additionally requires both `GIBSON_JEV_ENABLED=1` and `GIBSON_JEV_OPERATOR_MODE=1`. The second flag is the operator's explicit assertion that the loop is outside causal scoring. The hook runs only after review-round eligibility and skips calls when halted. It sends only failure count, an unknown phase/infrastructure summary, a red gate status, and zero infrastructure retries (the loop does not maintain that telemetry). It writes a unique `gibson/jev-escalation-*.json` receipt and a filename-only journal entry. Nothing reads that receipt into a coding prompt, second-opinion artifact, evidence receipt, loop state, retry decision, or supervisor handoff. The loop-summary adapter accepts the four native runners (`grok`, `codex`, `claude`, `hermes`) and counts from 0 to 100; unsupported runner values or counts produce a configuration error and leave escalation in control. Missing credentials, service failures, and hook timeouts also leave the existing escalation path in control.

## Summary request

`integrations/jev/request.schema.json` defines all four summary shapes. Every property is required unless explicitly optional, and extra keys are forbidden. For example, an operator escalation query is:

```json
{
  "use": "supervisor-escalation",
  "state": {
    "phase": "build",
    "infrastructure_health": "degraded",
    "consecutive_failures": 2,
    "retry_count": 0,
    "gate_status": "red",
    "halted": false
  },
  "experiment": {"mode": "operator"}
}
```

Summary schemas deliberately offer less context than the Mini Gibson manifest's abstract state inputs. They are useful for bounded advice, not arbitrary operational reasoning. Counts are limited to 0–100. CLI input files are regular nonsymlink files bounded to 16 KiB; validated state is bounded to 4 KiB, response bytes to 32 KiB. There is one provider attempt, no retry loop, redirects are refused, and the configurable 50–10,000 ms deadline covers response headers and body. The loop has a separate 15-second outer bound. Returned fields, types, enums, model version, probability distributions, choice winner, Score legend, and weighted Score must validate before recording answers.

## Experimental fairness and audit

Jev adds causal capacity whenever its answers affect an experiment's routing, retries, tool choices, labels, or scores. It must either operate completely outside scored causal loops or be identically configured across every compared arm under a frozen policy. Merely calling it advisory does not establish fairness.

The default `experiment_policy` is `excluded_from_scored_loop`. A request declaring `experiment.mode=scored` is refused before network access. To use the service identically across arms, set `experiment_policy=identical_across_all_arms` in an explicit enabled configuration and put its computed `policyHash(config)` in each scored request's `experiment.frozen_policy_hash`. The hash covers enabled state, pinned model/endpoint, confidence threshold, deadline, experiment policy, fixed questions/version, byte limits, and one-attempt policy. Both arms must use the same calling points, input construction, deterministic consumption rules, availability/fallback handling, and configuration. An evaluator must independently check their receipts. The hash check cannot prove another arm's setup or that an `outside-scored-loop` declaration is truthful. Routing is refused outside `operator` mode even with a matching scored policy.

Do not set the loop's operator flags during benchmark scoring. Perform anomaly triage only after outcomes and scores are locked if it is declared outside the scored loop. Do not feed advice into an implementing agent unless explicitly included identically across arms; this implementation never does so. Do not use Jev advice to retry task failures merely to obtain a pass.

`integrations/jev/receipt.schema.json` documents receipts. They contain the validated typed answers (including probabilities/confidence when available), state SHA-256, effective policy SHA-256, question-set version, model/endpoint, latency, experiment mode, status, and a fixed fallback/error reason. They contain no raw state, key, provider error text, code, or free-form explanation. State hashes are integrity fingerprints, not encryption or anonymization: a small state space can be enumerated to recover the hashed values. Low-confidence responses retain validated answers for audit but have `status=fallback`; they are not actionable advice. Noul uncertainty is measured by the larger of yes/no probability; Choice/Score use provider confidence. Thresholds need validation on your own workload. A successful API response is not a gate success, an approval, or a `VERIFIED` award.

## Validation and limitations

The offline suite `scripts/tests/jev-decision.test.sh` exercises fixed official response shapes, disabled behavior, malformed/oversized data, credential handling, full-body deadlines, confidence fallback, scored-loop refusal, frozen policy matching, immutable output, and no execution authority. It uses stubbed responses and no real API key. Existing loop, handoff, review-round, state, and gate suites exercise the unchanged deterministic path. Older loop suites inherit the parent environment, so enabled operator flags and a real key can trigger live calls during those tests. For an offline full run, clear those variables for that command:

```bash
env -u GIBSON_JEV_ENABLED -u GIBSON_JEV_OPERATOR_MODE -u TYPESAFE_API_KEY \
  bash scripts/tests/run-all.sh --no-quarantine
```

The dedicated Jev test wrapper clears these variables itself. A local timeout does not establish that the provider did not process or charge for a request. Receipts do not retain provider usage or cost, so they do not provide billing reconciliation.

This draft does not claim live TypeSafe connectivity, decision quality, model calibration, availability, cross-arm fairness, a tool interception layer, benchmark execution, or production readiness. There is no alternative provider/generative fallback, automatic retry/route/permission change, or verified model promotion. Activation and any provider spend are separate owner decisions. The pinned model and question set require a reviewed code/config change before upgrading.
