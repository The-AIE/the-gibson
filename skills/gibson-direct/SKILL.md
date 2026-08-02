---
name: gibson-direct
description: "The owner's product-direction interface to the Gibson: turn plain-English goals into a well-scoped plan and decomposed, acceptance-criteria'd issues the fleet can build from — and answer the fleet's product questions on the owner's behalf where direction already covers them. For owners who don't read code. Trigger: 'here's what I want built', 'product direction', 'turn this into a plan/issues', or when gibson-audit finds no usable backlog."
---

# gibson-direct — where the human plugs in

The owner's recurring job in the Gibson model is product direction (spend, credential, and Tier-C approvals still come to them as explicit gates). This skill makes
that one job cheap and everything downstream of it automatic. Everything shown
to the owner follows the Ask Contract; nothing assumes they read code.

## Mode 1: direction → plan → issues

1. Take the owner's goal in whatever form it arrives (a sentence, a rant, a
   competitor URL). Play it back as: users, jobs-to-be-done, what DONE looks
   like, what's explicitly out of scope. One confirmation round, not twenty
   questions — propose defaults, let them veto (they picked you to decide).
2. Run `playbooks/planner.md` to produce the plan, then `playbooks/decomposer.md`
   to cut it into issues. Every issue gets acceptance criteria a SENSOR can
   verify (test, script, evaluator) — Law 6: no criterion, no merge. Lint with
   `scripts/decompose-lint.mjs`.
3. File the issues (labels, milestone, priority order). Show the owner the LIST
   in plain English — titles + one-line what-you'll-get — not the issue bodies.

## Mode 2: standing context (answering the fleet's questions)

Builders hit product forks constantly ("should deleting a project cascade?").
Most have answers derivable from recorded direction. Maintain
`gibson/PRODUCT-DIRECTION.md` in the target repo:
- the confirmed goal statement, personas, out-of-scope list
- every product decision the owner has made, dated, in their words
- standing taste rules (e.g. "nothing standard-looking", tone, brand)

When a fleet question arrives: answer it FROM this file if covered (cite the
line); queue it for the owner ONLY if genuinely novel — then record their
answer so it's never asked again. The file is the owner's proxy; keeping it
sharp is what makes "minimum intervention" true. Never invent product
preferences that aren't recorded — a wrong guess silently baked into software
is worse than one batched question.

## Interruption budget

Product-direction questions batch into the digest unless they BLOCK all lanes
(then one focused Ask Contract interrupt). Aim: the owner hears from the
Gibson once or twice a day, answers in plain English in under five minutes,
and everything else just ships.
