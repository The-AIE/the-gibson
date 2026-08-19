---
title: "Decision card (human gate → Operator)"
nav_exclude: true
---

# Decision card (human gate → Operator)


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../../AGENTS.md). This file must not add, drop, or weaken those rules.

```
WHAT:        {{one_sentence_decision_in_plain_language}}
WHY YOU:     {{why_this_is_an_owner_decision}} ({{gate_id e.g. G6/G7/G12}})
RISK:        {{low|medium|high}}. {{what_could_go_wrong}} Undo: {{how_to_undo}}.
RECOMMEND:   {{Approve|Decline|Wait}}. {{one_sentence_why_fleet_recommends_this}}
IF YOU WAIT: {{what_happens_if_silent — always safe; other work continues}}
REPLY:       "yes" / "no" / any question you have.
```

## Offline ledger (stable id — not a delivery channel)

Pending owner decisions may be recorded offline with
`scripts/decision-ledger.sh` (schema `decision-ledger:v1`). Each event gets a
**stable full-strength id** from the identity tuple (repo, gate G1–G16, source
type, source id, exact 40-hex source SHA). The local ledger and id are **offline
artifacts for draft/queue/render only** — they are not a delivery channel, not
merge authorization, and not answer ingestion.

- **One decision per card.** Never batch multiple approvals on one card.
- **PENDING only.** The ledger never records approval, denial, choice selection,
  or merge authorization.
- **Unanswered cards** never auto-approve and never block unrelated work.
- **Delivery + ingest remain owner-gated** (issue #72): channel, recipient,
  credentials, cadence, authorized responder, retention, replay protection, and a
  live canary are Mark's decisions. Do not treat a rendered card as delivered.

```bash
# Record a PENDING decision locally (runtime ledger under gibson/ by default):
scripts/decision-ledger.sh add --repo owner/name --gate G12 \
  --source-type pr --source-id 123 --source-sha <40-hex> \
  --what "..." --why-you "..." --risk-level medium \
  --risk-consequence "..." --risk-undo "..." \
  --recommend Approve --recommend-rationale "..." \
  --if-you-wait "..." --source-ref "PR #123"

# Render a local digest (no send, no ingest):
scripts/digest.sh --ledger gibson/decision-ledger.jsonl

# Fill and (later, when channel is chosen) send as a single message. Never batch.
cat playbooks/templates/decision-card.md
```

### Example (pricing page launch)

```
WHAT:        Ready to publish the new pricing page to your live site.
WHY YOU:     It changes what customers pay — that always needs the owner. (G6/G7)
RISK:        Low. It can be undone in about a minute by rolling back the deploy.
RECOMMEND:   Approve. It matches the plan you okayed on Tuesday.
IF YOU WAIT: Nothing breaks. Other work continues. I'll re-ask in 3 days.
REPLY:       "yes" / "no" / any question you have.
```

### Example (Tier C merge)

```
WHAT:        Ready to accept a change that touches how people sign in.
WHY YOU:     Login and security changes always need your go-ahead. (G12)
RISK:        Medium. A bug could lock people out until we roll back (~1 minute).
RECOMMEND:   Approve. Tests and two reviewers signed off; preview looks correct.
IF YOU WAIT: The change stays off the live site. Other tasks keep moving.
REPLY:       "yes" / "no" / any question you have.
```
