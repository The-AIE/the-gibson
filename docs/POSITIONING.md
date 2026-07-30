# Gibson & Millwright — Positioning & Portfolio Fit

> STATUS: names DECIDED (Gibson, Millwright). Open questions remain `OPEN`. Mirrors the
> AIE Network source-of-truth style: canonical layering + explicit open decisions.

## One line
**Gibson is the open source agent harness for vibecoders — the engine. Millwright is the
commercial product built on it.** One engine, two doors: a developer door (Millwright) and a
business door (Chatterbuilt).

## The stack (one engine, two doors)

| Layer | Name | What it is | Audience | Gibson visible? |
|-------|------|------------|----------|-----------------|
| Authority | **AIOS** | The book + operating model. The "why." | Everyone | n/a |
| Engine | **Gibson** (open source) | The harness: orchestration, adapters (multi-host), memory, playbooks, multi-model, local models, vibecoding DX | Technical builders / vibecoders | Named, public — the brand |
| Developer door | **Millwright** (commercial) | The pro product on Gibson: power features beyond the OSS core **+ the bridge to the Chatterbuilt Crew**. The paid technical tier | Paying technical operators | Built on Gibson; Gibson credited |
| Business door | **Chatterbuilt** | Same engine, Gibson invisible; non-tech owners experience the Crew (Crew Chief et al.) | Trades / SMB owners | Invisible |
| Audience | **AIE Network** | Newsletters, distribution, conversion | Everyone | n/a |
| Consulting | **Peripety Labs** | AIOS Readiness Assessment + engagements | Mid-market+ | n/a |
| Proving ground | **ConferenceOS** | Separate-P&L app; first target of Gibson's red-team playbook | Event teams | uses Gibson |

Red-team is a **playbook that runs on Gibson** (first target: ConferenceOS), not Gibson's
identity — it belongs under `playbooks/`.

## Why this resolves the overlap
Chatterbuilt was previously described as "a harness / the reference implementation." It is not
a harness — it is a *product on the harness*. Gibson is the one engine both doors share.
"The model is replaceable; the harness is the product" is now the literal org chart, not a
metaphor.

## The name ladder (decided)
**Gibson** (the tools / the underground engine) -> **Millwright** (you, leveled up, the
technical operator who installs and runs the machinery and directs a crew) -> **Crew Chief**
(the crew running itself for a non-technical shop owner). Two metaphor worlds bridged on
purpose: Gibson lives in the cyberpunk/hacker world; Millwright and Crew Chief live in the
trades/crew world, which is exactly where the Gibson->Crew bridge belongs.

- **Millwright** = the tradesperson who installs, aligns, and maintains the machinery. Code is
  the machinery; Millwright is the technical operator who keeps the crew's machines running.
  Inherits CodeWright's craftsman DNA without the collision (Borland's CodeWright IDE was direct
  same-category prior use; "Millwright" surfaced no competing AI/developer-tool product — only
  the trade itself and union locals). `OPEN`: formal USPTO / domain / live-use check before any
  public page, per the AIOS/Rutgers rule.

## The decision that still makes or breaks it: the open-core line `OPEN — owner Mark`
What is free in Gibson vs. held in Millwright. First-pass:
- **Free (Gibson OSS):** harness runtime, adapters, playbook format, memory, local-model
  support, single-builder vibecoding, the red-team playbook.
- **Paid (Millwright):** Crew interaction (the bridge to Chatterbuilt), fleet / multi-agent
  orchestration, hosted memory, managed governance + approval gates, witness-signed releases,
  support.
- **Draw the line at:** *single builder on their own machine = free; talks to the Crew, runs a
  fleet, or is managed for you = paid.* The Crew bridge is the natural paywall — the thing a
  lone vibecoder does not need but a business will pay for, and the seam where Gibson meets
  Chatterbuilt.

## Repo follow-ups
- Reframe red-team as `playbooks/red-team/` (demote from harness identity); PR #22's
  `red-team/PROTOCOL.md` over-claimed the whole harness.
- Fix `red-team/PRIOR-ART.md`: at the *harness* level, Goose and ruv's metaharness are **peers**;
  use the build-on-vs-borrow framing and note the metaharness spike applies to **Gibson first**.
- Gibson's public README should read "the open source harness for vibecoders."

## metaharness fit (central)
ruv's metaharness is a harness *factory* whose core principle is "separate the factory from the
product; users see only your brand" -- exactly the Gibson -> Millwright -> Chatterbuilt
structure. The build-on-vs-borrow spike belongs at the **Gibson** layer, and it should run
*after* the open-core line is set, because it affects what even goes behind the Millwright
paywall.
