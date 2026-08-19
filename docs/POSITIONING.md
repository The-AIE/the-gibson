# Gibson, Millwright & Chatterbuilt — Positioning & Portfolio Fit


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> STATUS: names DECIDED (Gibson, Millwright). Monetization model DECIDED (open core engine +
> commercial bundle). Open questions remain `OPEN`.

## One line
**Gibson is a complete, open source agent harness for vibecoders — free.** The money is the
**Chatterbuilt bundle**: everything commercial packaged together. **ConferenceOS** is the
reference demonstration of that bundle in use.

## The stack

| Layer | Name | What it is | How it's sold |
|-------|------|------------|----------------|
| Authority | **AIOS** | Book + operating model. The "why." | Free (book); front door to assessment |
| Engine | **Gibson** (open source) | The full harness: orchestration, adapters (multi-host), memory, playbooks, multi-model, local models, vibecoding DX. Complete and uncrippled | **Free / open source** |
| Commercial bundle | **Chatterbuilt** | Everything commercial, bundled: the Crew (Crew Chief, Website, Answering, Visibility) + the **Millwright** build-and-maintain role, hosting, managed governance, support, AIOS library, annual assessment | **One bundle** (AIE Premium economics) |
| Role inside the bundle | **Millwright** | The technical build-and-maintain capability on Gibson — installs, aligns, keeps the machinery running, and bridges to the Crew. A role in Chatterbuilt, **not a separate SKU** | Bundled in Chatterbuilt |
| Reference demo | **ConferenceOS** | A real product built and run on Gibson + Chatterbuilt — proof, not a pitch: "here is how we use Chatterbuilt" | Demonstration |
| Audience | **AIE Network** | Newsletters, distribution, conversion | Free / sponsorship |
| Consulting | **Peripety Labs** | AIOS Readiness Assessment + engagements | Paid engagements |

Red-team is a **playbook that runs on Gibson** (first target: ConferenceOS) — under `playbooks/`.

## The monetization model (decided)
**Open source engine + commercial bundle.** Not open-core feature-gating. Gibson is a complete,
uncrippled harness that a lone vibecoder can use forever for free — that is the community and the
top of funnel. The commercial offer is the **bundle**: the productized, hosted, crew-connected,
supported experience (Chatterbuilt), sold as one package rather than à la carte tiers on top of
Gibson. The boundary is *packaging, service, and the Crew* — not withheld engine features.

Why this is the right line: a crippled OSS core starves the community; a complete OSS core plus a
genuinely valuable bundle (the Crew, hosting, support, done-for-you) is the model that has worked
for open source companies before. The thing a business pays for is the bundle and the Crew, not
permission to use Gibson.

## ConferenceOS as demonstration
ConferenceOS is repositioned from "a separate SaaS we also sell" to **the reference
implementation** — a real, running product that shows what Gibson + Chatterbuilt build. It is the
proof behind the pitch (and the first target of the red-team playbook, so it is also where we
prove the security discipline).

`OPEN` (owner Mark): does ConferenceOS keep its own P&L / event-team buyer *and also* serve as the
demo, or does it fold entirely into the Chatterbuilt story? The prior source-of-truth had it as a
separate-P&L outlier; this repositioning needs that reconciled.

## The name ladder (decided)
**Gibson** (the open engine / the underground) -> **Millwright** (the technical operator who runs
the machinery and directs a crew) -> **Crew Chief** (the crew running itself for a non-technical
owner). Cyberpunk world for the open source engine; trades world for the commercial bundle.
Millwright inherits CodeWright's craftsman DNA without the collision (no competing AI/dev-tool
product surfaced; only the trade + union locals). `OPEN`: formal USPTO / domain check before
public use, per the AIOS/Rutgers rule.

## Repo follow-ups
- Reframe red-team as `playbooks/red-team/`; PR #22's `red-team/PROTOCOL.md` over-claimed the harness.
- Fix `red-team/PRIOR-ART.md`: Goose and ruv's metaharness are harness-level **peers**; use
  build-on-vs-borrow, and the metaharness spike applies to **Gibson first**.
- Gibson's public README should read "the open source harness for vibecoders."

## metaharness fit
ruv's metaharness ("separate the factory from the product; users see only your brand") mirrors the
Gibson -> Chatterbuilt structure. The build-on-vs-borrow spike belongs at the **Gibson** layer.
