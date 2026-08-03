---
title: "16 · No terminal required"
parent: The Doctrine
nav_order: 16
---

# 16 — Operating Without a Terminal (Non-Technical Mode)

> 🙂 **In plain English:** You should never need a black terminal window. The crew asks
> you decisions in plain language — what they want, what it does, why it helps, and what
> could go wrong — and you answer in ordinary words.

The Gibson must be runnable by someone who has never opened a terminal and never
will. The fleet's job is long-running autonomous delivery; the operator's job is
answering a small number of plain-language questions. If the operator ever feels
stuck, confused, or needed-but-lost, **that is a harness defect** — file it as a
lesson (doc 09) exactly like a build failure.

## Operator tiers

| Tier | Who | Interface | Sees |
|---|---|---|---|
| **Engineer** | Mark, technical collaborators | GUIDE.md, gh/git, MC dashboard | everything |
| **Operator** | non-technical owner of a product | **chat only** (Hermes: iMessage/Slack/etc.) + the digest | decision cards, plain-language status, the live site |

Everything below defines the Operator tier. Nothing about the pipeline changes —
same gates, same tiers, same doctrine. What changes is the **presentation layer**
and the **defaults**.

## The prime directive: chat is the whole interface

Operators never see: a terminal, a diff, a CI log, a stack trace, YAML, or a raw
error. Hermes is the front-end; every fleet→operator message is one of exactly four
shapes:

1. **Status** — "Shipped today: password reset now works on mobile. Live at
   <url>. Nothing needs you."
2. **Decision card** (a human gate, translated) — see below.
3. **Intake question** — during planning, one question at a time, in their words.
4. **Incident notice** — "The site had a problem for 12 minutes; it's fixed;
   here's what happened in one sentence; no action needed / here's the one action
   needed."

Operator→fleet is free-form natural language. "The checkout feels slow" is a valid
work order — the planner turns it into a plan; the operator approves the plan as a
plain-language summary ("Here's what I'll do, in order, and what you'll see
change"), never as PLAN.md.

## Decision cards (human gates, translated)

Every gate from doc 14 reaches an Operator as a card with six fields, all in plain
language, no jargon word uncarried:

```
WHAT:        Ready to publish the new pricing page to your live site.
WHY YOU:     It changes what customers pay — that always needs the owner. (G6/G7)
RISK:        Low. It can be undone in about a minute.
RECOMMEND:   Approve. It matches the plan you okayed on Tuesday.
IF YOU WAIT: Nothing breaks. Other work continues. I'll re-ask in 3 days.
REPLY:       "yes" / "no" / any question you have.
```

Card rules:
- **One decision per card.** Never a list of approvals.
- **A recommendation is mandatory.** Presenting options without advice is how
  non-technical operators get stuck — the fleet is the expert; it must say what it
  would do and why.
- **"Do nothing" is always described.** Silence must be safe: an unanswered card
  never blocks unrelated work (doc 14's queue rule) and never times out into
  auto-approval. Gates wait; the fleet re-asks on a gentle cadence and, after two
  re-asks, routes the card to the Engineer tier if one exists.
- **Stable id + local ledger are offline artifacts**, not the chat channel.
  `scripts/decision-ledger.sh` / `scripts/digest.sh` may draft and render cards
  with a deterministic id for later delivery; they do not send messages, schedule
  jobs, or record yes/no answers. Live owner-channel wiring (Hermes or fallback)
  remains open under issue #72.
- **Questions are answered, not deflected.** An operator asking "what does
  'undone' mean here?" gets a real answer on the card's thread before a yes/no is
  accepted.

## Stricter defaults for Operator-tier repos

Autonomy is *higher* (fewer interruptions), and the irreversibility budget is
*lower*:

- Spending gate (G5) threshold: **$0** — every dollar is a card.
- Tier C merges: always carded, never batched.
- Anything G1–G4 (destructive class): carded **and** requires the Engineer tier
  if one is configured; otherwise the fleet's answer is "no" by default.
- Production launches ship behind a preview link first: "Look at this link on
  your phone. Reply yes and it goes live."

## Never stuck: the unstick ladder

The core promise is long-running processes that don't die quietly. Codified:

1. **Self-heal** (minutes) — retries, mechanical remediation, the doc 11 error
   budget. The operator hears nothing.
2. **Reroute** (hours) — escalate the grade (doc 15), park and pick other work,
   re-queue for a different runtime. The operator hears nothing.
3. **Translate & ask** (only if the blocker is a genuine human gate or G10
   ambiguity) — one decision card in plain language. *The fleet never asks an
   Operator a technical question.* If the question can't be phrased in the
   operator's vocabulary, it isn't their question — route it to the Engineer tier
   or resolve it autonomously and note the judgment call in the PR.
4. **Digest visibility** (always) — parked and waiting items appear in the digest
   with plain reasons, so nothing is silently wedged. A card unanswered for 7
   days triggers a summary card: "Here's everything waiting on you, shortest
   first." Offline, `scripts/digest.sh` can render that picture from local
   snapshots only; **shipping the digest to the owner is still owner-gated**
   (issue #72). Silence on the owner channel is not success and is not proof the
   fleet stopped — but silence also never means auto-approval.

**Heartbeat guarantee:** an Operator-tier repo produces at least one status
message per active week even when nothing shipped ("Working on X, nothing needs
you") — silence reads as death to a non-technical owner, and trust is the actual
uptime metric. The offline renderer enforces a **quiet active week** status line
when a period has zero ships; live delivery of that heartbeat still depends on
the owner-channel choices tracked in issue #72.

## The Ask Contract (every request, every tier)

Decision cards cover gates; this covers **everything else the fleet ever asks a
user** — including technical setup and installation steps, and including
Engineer-tier users, because "assume not a traditional developer" is the default
for everyone. Four fields, always:

| Field | Answers | Example (installing the CI gate) |
|---|---|---|
| **What I'm asking** | The action, one sentence | "I'd like to add an automatic checker to your project on GitHub." |
| **What it does** | The actual effect, their vocabulary | "Every time new code is proposed, it runs the tests and safety scans before anything can be accepted." |
| **Why** | Benefit tied to their goal | "It means nothing reaches your live site without passing inspection — even work done while you're asleep." |
| **Risks** | What could go wrong, likelihood, undo path | "Low risk: it can block work if a check is misconfigured, which shows up as a red X, and it can be removed with one click. It never touches your live site directly." |

Rules:
- **Terminology is explained inline on first use**, every session — "a *preview*
  (a private link showing the change before it's live)". Users don't carry a
  glossary between conversations; the fleet does.
- **Steps come with narration.** A multi-step installation is presented as
  numbered steps, each with its own what/does/why — never a block of commands to
  paste on faith. If the user must run something themselves, say what they'll
  see when it works and what it looks like when it doesn't.
- **No bare asks.** A naked "can I proceed?", a bare command, or an unexplained
  yes/no is a contract violation — same class as a skipped gate.
- **Answers before approvals.** Any question about an ask gets answered before a
  yes is accepted (same rule as decision cards).

## Intake without vocabulary

Non-technical briefs arrive as outcomes ("I want customers to book without
calling me"). The planner's intake interview (playbooks/plan.md) asks only
business questions — who, what, when, what does success look like, what must
never happen — and the plan comes back as: what you'll see, in what order,
roughly when, and what it'll cost. Technical scope lives in PLAN.md for the
fleet; the operator approves the translation, and the translation is contractual
(if the plain summary and PLAN.md diverge, the summary wins and the divergence is
a lesson).

## Stop the crew from your phone (remote kill switch)

The fleet can run for hours without you. If something looks wrong and you are
away from the machine, you still have an off switch — no terminal, no SSH.

**What I'm asking:** On the GitHub mobile app, open any issue on the project and
add the label `gibson-halt`.

**What it does:** Within up to a few work cycles (default: up to three
iterations of the hot loop; every iteration if the loop is in single-step mode)
the unattended loop notices the label, stops cleanly, and will not hand more
work to the cloud supervisor. Your live site is not touched; only the automatic
worker pauses.

**Why:** So you can freeze the crew from another room or another city without
needing the computer that is running it.

**Risks:** Low. To start again, remove the `gibson-halt` label from that issue
(or from every issue that has it) and launch the loop once more — a fresh launch
runs normally after GitHub confirms the stop is gone **on the same project**
that was stopped. Nothing is deleted; queued work stays queued. If GitHub itself
is down **before** the stop was ever confirmed, the remote stop cannot see the
label and the local machine keeps going until someone can set the on-box stop
(`gibson/HALT`); that is intentional so a GitHub outage does not freeze every
project at once. **After** the loop has already seen and recorded a remote stop,
a later GitHub outage or rate limit keeps the crew stopped (so a phone halt is
not undone by a flaky API) until a successful check confirms both remote stop
paths are clear on that same project. Pointing the repo at a different GitHub
project does **not** clear an earlier stop — restore the original project and
clear the label/file there, or have an engineer remove the on-box
`gibson/halt-latch` only after verifying it is safe. Concurrent auto-restarts
while stopped journal the reason once (they do not spam or restart work).

Engineers can also commit an empty file named `.gibson-halt` on the project's
default branch (usually `main`) — same effect, cleared by deleting the file.
The label path above is the one-line phone workflow; the file is the backup when
labels are awkward. Details: [doc 11](11-solo-loop.md), [doc 22](22-devin-cloud-supervisor.md).

## Provenance

This tier is the productized version of the Chatterbuilt thesis (agent-run
websites for non-technical SMBs) — The Gibson's Operator mode is the engine that
model runs on, and Chatterbuilt is its first intended customer (ROADMAP Phase 3).

---
[← 15 · Spending AI money wisely](15-model-economics.md) · [Home](../index.md) · [17 · Site checkups and tune-ups →](17-deployment-optimization.md)
