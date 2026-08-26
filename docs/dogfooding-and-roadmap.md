# The Gibson: dogfooding, the flywheel, and the road to "click magic"

> **Authority:** Non-normative. The *why* behind the harness — the strategy that
> decides what we build next. It must not add, drop, or weaken any rule in
> [`AGENTS.md`](../AGENTS.md).

## The thesis: the harness is the product

`Agent = Model + Harness`. The model is rented and commoditizing; the **harness is the
durable asset** — governance, cross-vendor review, claims, durability, provenance. So the
Gibson is the product. Applications are two things at once:

- **Proving grounds** — real software we ship, whose *second* job is to stress the harness
  and surface its gaps.
- **Beneficiaries** — each harness improvement makes the next application faster and safer.

## The dogfooding flywheel

```
   build an application  ──▶  surfaces a harness gap  ──▶  fix ratchets into the Gibson
          ▲                     (a stall with no timeout,        (portable, not a local patch)
          │                      an auth mis-config, a                     │
          │                      missing gate)                             ▼
   the better harness  ◀──────────────────────────────  every future app inherits the fix
   accelerates the next app
```

This is **Law 9 ("feed the ratchet") elevated to strategy.** The operating principle:
**every task has two outputs — the app improvement AND the harness improvement.** When
work on an application exposes a weakness in how the fleet operates, you do not just patch
the app; you fix the Gibson so the fix is portable and permanent. "The failure that happens
twice becomes a permanent improvement to the harness" is not a slogan — it is how the
product gets built.

## The sequence

1. **ConferenceOS dogfoods the Gibson (now).** A real, launch-driven product under a live
   deadline is the hardest possible test of an autonomous harness — and it has already
   surfaced (and hardened) auth durability, stall timeouts, a liveness watchdog, and a
   completion contract.
2. **The proven Gibson finishes Chatterbuilt** — faster, because the harness is better. This
   is proof point #2: the harness works on a *second* application, not just the one it grew up on.
3. **Then others.** Each new application is cheaper than the last.

The goal is never to improve only ConferenceOS. It is to improve **the Gibson and
Chatterbuilt** — the harness and the next application — on every pass.

## Where this is going: "signup → click → magic"

Today the Gibson needs an expert operator (launchd, SSH, tokens, worktrees). The end state
is a product a stranger can run. But there is one fork that decides everything:

- **Host everything, single-vendor** → we become a me-too hosted agent and **delete the only
  moat we have** (sovereign, multi-vendor, auditable, open). Do not.
- **Hosted control plane + bring-your-own runners** → we host the dashboard, orchestration,
  observability, and onboarding; the customer's own compute executes. Click-magic UX *on top
  of* sovereign, multi-vendor execution. This is how self-hosted CI, Vercel, and Temporal win.
  **This is the path.**

### The moat (why this is not Devin or Cursor)

Devin is hosted and single-vendor; Cursor is editor-first and hosted. Neither can do the one
thing at the Gibson's core: **a different vendor reviews what another vendor wrote** (the
independence floor). As models commoditize, "own the harness, rent the model, prove it across
vendors, keep your code" is a position the incumbents' business models *forbid* them to copy.

### The roadmap (order matters — later steps are worthless without the earlier)

1. **Finish self-healing durability.** Runs unattended for days and weeks without an expert:
   bounded runners, stall/zombie detection, failover, durable auth, cost caps. *A signup page
   cannot save a product that stalls for someone who can't SSH into the machine.* **(In flight.)**
2. **Hosted control plane + BYO runner** — the architecture that gives UX without surrendering
   the moat.
3. **Onboarding + dashboard** — GitHub App one-click install, zero-config safe defaults, a
   dashboard fed by the fleet's own vitals stream.
4. **External proof** — run it on repos that are not ours; publish the numbers.

**The guardrail:** chase click-magic UX *on top of* the sovereign, multi-vendor, auditable
substrate — never *instead of* it.
