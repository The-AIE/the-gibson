# Target Profile — ConferenceOS

**Repo:** github.com/mrhinkle/conference-os
**Why target #1:** the only portfolio app with **real payments and real attendee PII**. Real
money + real people = the highest blast radius in the portfolio. Everything in this profile is
weighted toward those two.

## Stack (know the map before you attack)
- **Next.js (App Router)** — routes, server actions, and API/route handlers are the surface.
- **Prisma + Neon Postgres**, a **shared prod** database — merging a schema change to `main`
  triggers a live `prisma db push`. **A red-team run must never mutate the schema.**
- **Vercel** (team the-aie) — preview deploys are your test target; watch for preview leaks.
- **Payments** and **consent/PII** flows are the crown jewels.

## Rules of engagement (ConferenceOS-specific, in addition to PROTOCOL.md)
1. Attack a **Vercel preview deploy or local instance**, never prod. Read-only recon on prod ok.
2. **No schema changes** during a run — schema is shared-prod and pushes live.
3. Seed a **fake attendee + fake order** for any test that touches personal data or payment.
4. Use **Stripe test mode** for all payment attacks; never a live key.

## Priority attack map (work top-down)
1. **Auth / IDOR** — can attendee A read or mutate attendee B's order, ticket, or profile by
   changing an ID? Test every object-scoped route and server action.
2. **Payments** — price/quantity tampering client-side; **is the Stripe webhook signature
   verified?** replay a captured webhook; forge one; double-submit checkout; coupon reuse/stack.
3. **PII / consent** — API response over-fetch; PII in logs/errors; consent enforced before
   the gated action; attendee data export/erasure reach; CSV injection in exported attendee lists.
4. **Injection** — any Prisma `$queryRaw`; stored XSS in speaker bios / session titles.
   Those same fields are the **prompt-injection** entry points: speaker bios, session
   titles and descriptions are attacker-authored, free-text, and land in front of any
   agent that summarizes, moderates, or answers questions about the programme. Test
   the classic payload and the patient one (text that only becomes an instruction once
   another agent ingests the summary), and run `scripts/injection-scan.sh` over any
   seeded/imported content — a zero-width payload in a bio survives every review that
   reads rendered text (PROTOCOL Phase 3, "poisoned shared config").
5. **Business logic** — capacity/waitlist bypass, duplicate registration, registering for a
   paid tier without paying, ticket-transfer abuse.

## Integration points to check
- If any agent/LLM feature reads attendee-authored content, walk the five-layer
  defense-in-depth table in PROTOCOL.md — bios reaching a prompt turns this from a
  web-app audit into an agent-runtime audit.
- Cross-reference existing `cos-review` (money/consent/PII lens) and `cos-testing` (Playwright
  e2e) — reuse their coverage; don't duplicate.
- File Critical/High findings as issues on `mrhinkle/conference-os`, labeled `security` + severity.

## Out of scope
The Vite marketing sites (theaie-net, allthingsai-org) are near-static and reputational-risk
only — not worth a full red-team pass. Keep this scoped to ConferenceOS.
