---
name: gibson-red-team
description: Run Gibson's repeatable red-team protocol against a target app to find security, auth, payment, PII/consent, and business-logic flaws before they ship — and before any paid third-party review. First target is ConferenceOS (mrhinkle/conference-os). Produces scored findings, files Critical/High as GitHub issues, and reports a readiness verdict. Use when Mark says "red team the app," "run Gibson," "run the red team," "security sweep," "attack conference-os," "are we secure," or "pre-pentest check."
---

# Gibson Red-Team

This skill runs the Gibson red-team protocol. The full method is in `PROTOCOL.md`; the target
under test is defined in `targets/<target>.md` (start with `conference-os.md`).

## Workflow
1. Read `PROTOCOL.md` and the relevant `targets/<target>.md`.
2. Confirm you are pointed at a preview/staging/local build — never destructive against prod.
3. Work Phases 1–6 in order. Log findings to `findings/YYYY-MM-DD-<target>.md` from `TEMPLATE.md`.
4. File Critical/High as GitHub issues on the target repo (`security` + severity labels).
5. Fix, re-run the relevant phase, and only mark a finding closed on a clean re-test.
6. Report the exit verdict: NOT READY or READY FOR THIRD-PARTY REVIEW.

## Downstream
This protocol is built to graduate into Chatterbuilt's Employee Handbook skill pack so the
agent crew can red-team the customer sites it maintains. See `PROTOCOL.md` § Downstream for the
handoff contract (crew runs Phases 1–5; Critical/High escalate to the owner; never touches real
customer PII).
