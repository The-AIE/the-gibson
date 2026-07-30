# Gibson — Positioning & Portfolio Fit (working draft)

> STATUS: DRAFT for Mark's review. Open questions are marked `OPEN`. This mirrors the
> AIE Network source-of-truth style: canonical layering + explicit open decisions.

## One line
**Gibson is an open source agent harness for vibecoders.** It is the *engine*. Two products
are built on it, for two audiences.

## The three layers (open-core)

| Layer | What it is | Audience | Visibility of Gibson |
|-------|------------|----------|----------------------|
| **Gibson** (open source) | The harness itself: orchestration, adapters (multi-host), memory, playbooks, multi-model, local models, vibecoding DX | Technical builders / vibecoders | Named, public, the brand |
| **CodeWright** (commercial) `NAME: working` | The pro product built on Gibson for developers/technical operators. Adds capability beyond the OSS core, including **interacting with the Chatterbuilt Crew** | Paying technical users | Built on Gibson; Gibson credited |
| **Chatterbuilt** (non-technical) | For non-tech people, Gibson is invisible plumbing; they experience the Crew. Gibson's capability surfaces *as part of Chatterbuilt*, never named | Trades / SMB owners | Invisible |

Red-team is a **playbook that runs on Gibson** (first proving ground: ConferenceOS), not
Gibson's identity. It belongs under `playbooks/`.

## Fit with existing brand architecture
- Consistent with the AIOS-vs-Chatterbuilt layering already ratified: AIOS = authority/model;
  **Gibson = the open source engine**; CodeWright + Chatterbuilt = commercial reference
  implementations for two audiences (developer vs. non-developer).
- "The model is replaceable; the harness is the product" (metaharness's thesis) is now literally
  our structure: Gibson is the durable IP, the model underneath is swappable.

## The two decisions that make or break this

### 1. The open-core line `OPEN — owner Mark`
The single most important call: what is free in Gibson vs. held in CodeWright. First-pass:
- **Free (Gibson OSS):** harness runtime, adapters, playbook format, memory, local-model
  support, single-builder vibecoding, the red-team playbook.
- **Paid (CodeWright):** Crew interaction (the bridge to Chatterbuilt), fleet / multi-agent
  orchestration, hosted memory, managed governance + approval gates, witness-signed releases,
  support.
- **Draw the line at:** *single builder on their own machine = free; talks to the Crew, runs a
  fleet, or is managed for you = paid.* From open source history: the free tier must stand alone
  and be genuinely useful (or no community forms), and the paid line must be something a serious
  user will pay for (or no revenue). This line is exactly that boundary.

### 2. The CodeWright name `OPEN — prior-use flag`
"CodeWright" is an existing programmer's editor/IDE (Premia -> Borland, up to v7.5; Wikipedia
page; still downloadable). Same category as ours (a developer coding tool) -- a stronger
conflict than the AIOS/Rutgers case, though the product appears defunct. Per the ratified
AIOS/Rutgers rule, run a USPTO / live-use check before it goes on any public page; Borland IP
may have an owner. Working name until cleared.

## What this changes in the repo (follow-up work)
- Reframe red-team as `playbooks/red-team/` (demote from harness identity); PR #22's
  `red-team/PROTOCOL.md` over-claimed the whole harness.
- Fix `red-team/PRIOR-ART.md`: at the *harness* level, Goose and ruv's metaharness are **peers**,
  not things Gibson merely "isn't." Use the build-on-vs-borrow framing (same as the Chatterbuilt
  PRIOR-ART), and note the metaharness spike applies to **Gibson first**.
- Gibson's public README should read "harness for vibecoders," not anything red-team-specific.

## metaharness fit (now central, not a footnote)
ruv's metaharness is a harness *factory* whose core principle is "separate the factory from the
product; users see only your brand" -- which is exactly the Gibson -> CodeWright -> Chatterbuilt
structure. The build-on-vs-borrow spike therefore belongs at the **Gibson** layer:
- **Build on it:** Gibson adopts metaharness plumbing (CLI, MCP adapter, memory, signing, cost
  router) and we spend our effort on vibecoder DX, the Crew bridge, and the Employee Handbook IP.
- **Borrow from it:** keep Gibson's own thin harness, adopt the patterns (default-deny, mcp-scan,
  Darwin-mode, witness-signed releases, cost routing).
Decide before hardening Gibson's core, because it affects what we even build.
