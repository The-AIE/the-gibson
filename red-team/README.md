# Gibson — Red-Team Module

Gibson is the security/red-team harness for the AIE Network / Peripety Labs portfolio.
This module is the adversarial audit capability: a repeatable protocol you point at an app
to find security, auth, payment, PII/consent, and business-logic flaws before they ship —
and before you pay for a third-party review.

## How it fits

```
Gibson (harness)
  └─ red-team/                      ← this module
       ├─ PROTOCOL.md               ← the six-phase adversarial protocol (app-agnostic)
       ├─ targets/                  ← one profile per app under test
       │    └─ conference-os.md     ← first target: the money + PII app
       └─ findings/                 ← dated findings ledgers, one per run
            └─ TEMPLATE.md
```

## The three-stage path

1. **Build it in Gibson.** The protocol lives here, app-agnostic, so any property can be a
   target. This is the source of truth for how we red-team.
2. **Use it on ConferenceOS first.** ConferenceOS is the highest-stakes app in the portfolio
   — real payments, real attendee PII — so it's target #1. See `targets/conference-os.md`.
3. **Graduate it downstream into Chatterbuilt.** Chatterbuilt is "the reference implementation
   of the AIOS operating model," and its Crew Chief runs on the **Employee Handbook skill
   pack** (the real IP). This red-team protocol becomes a skill in that pack so the agent crew
   can red-team the customer sites it maintains — a product capability, not just internal
   tooling. The handoff contract is in `PROTOCOL.md` (§ Downstream).

## Run it

Point the protocol at a target profile and work the six phases in order. Every run ends with
a verdict (`NOT READY` / `READY FOR THIRD-PARTY REVIEW`) and a dated ledger in `findings/`.
