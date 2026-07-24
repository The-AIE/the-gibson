---
title: "Decision card (human gate → Operator)"
nav_exclude: true
---

# Decision card (human gate → Operator)

```
WHAT:        {{one_sentence_decision_in_plain_language}}
WHY YOU:     {{why_this_is_an_owner_decision}} ({{gate_id e.g. G6/G7/G12}})
RISK:        {{low|medium|high}}. {{what_could_go_wrong}} Undo: {{how_to_undo}}.
RECOMMEND:   {{Approve|Decline|Wait}}. {{one_sentence_why_fleet_recommends_this}}
IF YOU WAIT: {{what_happens_if_silent — always safe; other work continues}}
REPLY:       "yes" / "no" / any question you have.
```

## How to use this

```bash
# Hermes / agent: fill and send as a single message. Never batch multiple cards.
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
