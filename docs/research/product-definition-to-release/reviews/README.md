---
title: "Research contributions"
nav_exclude: true
---

> **Authority:** Non-normative research. These memos are advisory input, not source inspection, formal release review or permission to act.

# Research contributions

## Received independent first passes

| Contributor | Actual requested/reported model | Memo | Provider-reported cost |
|---|---|---|---|
| Codex | This session's platform-resolved Codex model | [Initial source-informed memo](codex-initial.md) | Not separately reported |
| GLM | z-ai/glm-5.3 | [GLM 5.3](glm-5.3.md) | $0.02808696 |
| Kimi | moonshotai/kimi-k3.1-pro | [Kimi](kimi.md) | $0.064174 |
| Grok | x-ai/grok-4.7 | [Grok](grok.md) | $0.037136 |
| Claude | anthropic/claude-opus-5.5 | [Claude](claude.md) | $0.150304 |

All four external first passes completed with finish reason stop. Their final responses were recovered from retained result artifacts after a transport timeout, without repeating the generation calls. The first-round provider-reported cost is $0.27970096.

Read the [cross-model synthesis](synthesis.md) for convergence, substantive disagreement and recommendations not adopted. [The manifest](contributions.json) records requested input digest, response identities, finish reason, usage/cost and final-response hashes. [Final response data](responses.json) preserves the substantive text; provider reasoning and connection/account metadata are excluded.

## Scope and method

The four external models received the same [sanitized conceptual brief](shared-brief.md) independently, before seeing other answers. They had no browsing or repository access. Their first passes are conceptual research, not code audits. Codex's repository inspection is a separate richer evidence stream; internal Codex audit assistance is not relabeled as an external model.

## Received public-source follow-ups

One bounded [public-source follow-up](source-followup-brief.md) supplied the existing toolkit/control-plane source summary plus each model's own original memo, without other models' opinions. It excludes live operational and recovery details. The models did not browse or inspect code. The source-summary framing is shared input, not four independently rediscovered source findings.

| Contributor | Delta memo | Actual outcome | Provider-reported cost |
|---|---|---|---|
| GLM 5.3 | [Source delta](glm-5.3-source-delta.md) | Completed (`stop`) | $0.002511989 |
| Kimi | [Source delta](kimi-source-delta.md) | Completed (`stop`) | $0.035736 |
| Grok | [Source delta](grok-source-delta.md) | Completed (`stop`) | $0.020224 |
| Claude | [Source delta](claude-source-delta.md) | Partial (`content_filter`), ends mid-sentence | $0.088116 |

The second-round provider-reported cost is $0.146587989; the combined total is **$0.426288949**. These figures are provider usage reports, not a billing audit or productivity benchmark. The partial Claude text is retained without regeneration or a synthesized ending. Its initial memo is complete.

[Exact follow-up request bodies](source-followup-requests.json) and [final response data](source-followup-responses.json) preserve inputs and actual text/metadata, excluding provider reasoning text and account/connection identifiers. Input and memo digests are in the manifest. Read the synthesis for the resulting reuse-first plan and remaining disagreement.

## Collaboration rules

Preserve the independent originals and identify later changes by source/claim. Separate documentary capabilities from actual running behavior, and treat model opinions as hypotheses. Do not invent consensus, performance results or certification. No research memo substitutes for the existing independent exact-head release process or changes its current authority.
