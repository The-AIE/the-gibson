---
title: "Incident notice"
nav_exclude: true
---

# Incident notice


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../../AGENTS.md). This file must not add, drop, or weaken those rules.

```
WHAT HAPPENED: {{one_sentence_plain_story}}
IMPACT:        {{who_was_affected_for_how_long}}
NOW:           {{fixed|investigating|rolled_back}}
NEED YOU:      {{Nothing. | Exactly one action: …}}
```

## How to use this

No stack traces. No CVE numbers without translation. If G15/G16, page the owner
and stop related work — this message still stays plain.

### Example

```
WHAT HAPPENED: The site was slow for about 12 minutes because a traffic spike
               overwhelmed one page.
IMPACT:        Some visitors saw long loads; no payments were lost.
NOW:           fixed — extra capacity is on and we are watching.
NEED YOU:      Nothing.
```
