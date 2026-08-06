---
title: For Business Owners
nav_order: 2
---

# Vibecoding for Absolutely Everyone

*The no-experience-needed guide to getting software built by your AI team.*

You don't need to code. You don't need to learn tools. You need to be able to
send a text message and answer plain questions about your own business. That's
the whole skill.

---

## What you actually have

Think of it as a **tiny software company that works for you around the clock**:

- A **planner** who turns your idea into a plan you can read.
- **Builders** who do the work.
- **Inspectors** who test everything — including clicking through your site on a
  phone like a real customer — before anything goes live.
- A **security guard** who checks every change for safety problems.
- A **project manager** (that's the one texting you) who only interrupts you
  when a decision genuinely belongs to the owner.

They don't sleep, they don't wait for meetings, and they don't need you to
supervise. They need you for exactly two things: **saying what you want** and
**saying yes or no** when it's owner business.

### One AI is enough {#one-model-is-enough}

> **Canonical statement.** Other Gibson docs link here; they do not restate this.

You do **not** need a fleet of different AI brands. One strong model (the same
one you already talk to) can plan, build, test, and ship under the rules. A
second model is only an optional extra for double-checking sensitive work — never
a requirement. If someone tells you that vibecoding needs three vendors, that is
outdated advice for *this* system.

Multi-model review is an **upgrade path**, not a prerequisite for shipping. The
solo loop primary path is `scripts/loop.sh --runner <one-cli>` against one vendor.

---

## How to ask for things

Just describe the outcome in your own words, like you'd tell a contractor:

> "I want customers to book appointments on my site instead of calling me."

> "The checkout feels slow on my phone."

> "Add a page with prices for my three packages. I'll send you the prices."

**Good asks say the what, not the how.** You don't need to say "add a database" —
you wouldn't tell a plumber which wrench to use. If the team needs details, it
asks you one question at a time, in normal words.

After you ask, you'll get back a short plan in plain English: *what you'll see
change, in what order, roughly when, and what it costs.* Read it. If it matches
what's in your head, say yes. If not, say what's off — that conversation is free
and it's the most valuable five minutes in this whole process.

## The messages you'll get

Only four kinds, ever:

| Message | What it means | What you do |
|---|---|---|
| **Status** | "Here's what shipped. Nothing needs you." | Nothing. Enjoy. |
| **Decision card** | An owner decision: money, going live, deleting things | Reply *yes*, *no*, or ask a question |
| **Question** | The planner needs a business fact only you know | Answer in your own words |
| **Incident notice** | Something broke; here's the one-sentence story | Usually nothing — it says if there's an action |

**Decision cards always include a recommendation** ("I'd approve this, here's
why") and always tell you what happens if you do nothing (answer: nothing bad —
work waits safely, everything else continues). You can't break anything by being
slow to reply, and nothing ever approves itself while you're not looking.

## The five rules of happy vibecoding

1. **Describe problems, not solutions.** "Customers abandon their carts" beats
   "add a popup." The team is good at solutions; only you know the problems.
2. **Look at the preview.** Before anything goes live, you get a link: *"Check
   this on your phone. Reply yes and it goes live."* Actually tap the link. Two
   minutes of you clicking around is worth more than an hour of anyone's testing,
   because you know what *right* looks like for your business.
3. **Say when something feels wrong, even vaguely.** "The new page looks off" is
   useful. "It feels slow" is useful. The team measures before it changes
   anything, so a vague feeling in, a precise fix out.
4. **Never feel dumb for asking.** "What does 'go live' mean here?" gets a real
   answer, every time, before your yes counts. A question is never a wrong answer
   to a card.
5. **You can always say stop.** Text "pause everything" and the whole team stops
   taking new work until you say go. No harm done.

## Tiny glossary (all ten words you'll ever see)

| Word | Means |
|---|---|
| **Live / production** | The real site your customers see |
| **Preview** | A private link showing a change before it's live |
| **Ship / deploy** | Move a finished change to the live site |
| **Roll back** | Undo — put the live site back the way it was (about a minute) |
| **Issue** | One item on the team's to-do list |
| **Plan** | The plain-English summary you approve before building starts |
| **Gate** | A decision reserved for you (money, going live, deleting) |
| **Parked** | Work set aside, waiting — safely, nothing rotting |
| **Digest** | Your regular summary message: shipped / waiting / learned |
| **Audit** | A checkup of your site's speed, cost, and safety, with a report card |

## Recipes: say this, get that

- *"What are you working on?"* → current status, plain words.
- *"What's waiting on me?"* → every open decision card, shortest first.
- *"How's my site doing?"* → the latest report card (speed, cost, errors) — and
  if there isn't a recent one, a checkup gets scheduled.
- *"How much is this all costing?"* → one number for the AI team's work + one
  number for running the site.
- *"Undo that last change."* → rolled back, then a card asking what was wrong so
  it gets fixed properly.
- *"Pause everything."* / *"Okay, go again."* → exactly what they say.

More ready-made lines: [docs/prompts.md](docs/prompts.md).

## When you're worried

Software teams — human or AI — earn trust by being boring: small changes,
previewed first, easy to undo, honestly reported. If a message ever confuses
you, **the confusion is their bug, not yours**. Reply "I don't understand this"
and the team is required to treat that like a failed test: explain it better
*and* fix the wording so it never confuses the next person. That's literally in
their rulebook (docs/16, docs/09 — but you never need to read those).

---

*Under the hood this is The Gibson's Operator mode — the full machinery is
documented in this repo for the technical folks. You're holding the only page
you need.*

**Related:** [Copy-paste prompts](docs/prompts.md) · [Operator readiness checklist](docs/21-operator-readiness.md) · [Quickstart for the technical setup](QUICKSTART.md)
