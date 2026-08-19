---
title: "Example · Plan to Issues"
nav_exclude: true
---

# Worked example — PLAN.md → issue set (docs/04)


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../../AGENTS.md). This file must not add, drop, or weaken those rules.

Fictional target: **Northstar Clinic** (`northstar/clinic-web`), a Next.js +
Vercel booking site. Mark's brief: *"Patients should reset their password by
email; it has to work on phones."*

This file is the full artifact trail a decomposer would produce after plan
approval. Copy the shape, not the product details.

---

## PLAN.md (approved)

```markdown
# PLAN: Password reset by email (mobile-first)

## Problem
Patients who forget their password must call the front desk. That wastes staff
time and blocks online booking.

## Users
- Returning patients on mobile Safari/Chrome
- Front-desk staff (indirect beneficiaries)

## Scope
- Request-reset form (email)
- Email with single-use time-limited link
- Set-new-password form
- Mobile-usable layouts for both forms
- Rate limiting on request endpoint

## Non-scope
- Changing email address
- SMS reset
- SSO / OAuth
- Passwordless magic-link login (future plan)

## Architecture sketch
- Existing auth session library stays authoritative
- New routes under app/(auth)/reset/*
- Token table (or provider-hosted tokens if already in use) — **schema change is
  its own deliverable**
- Transactional email via existing Resend integration
- Preview-friendly: no prod emails from preview deploys (mail catcher / flag)

## Risks
- Account enumeration via reset form (mitigate: constant response copy)
- Token leakage in logs/URLs (mitigate: one-time, short TTL, no token in
  analytics)
- Email deliverability delays (copy sets expectation)

## Deliverables

### D1 — Token storage (schema)
Acceptance criteria:
1. Additive migration creates reset token model with userId, hash, expiresAt,
   usedAt nullable.
2. No destructive SQL; migration file present in same change.
3. Deploy apply path rejects non-additive drift (existing guard).

### D2 — Request + email API
Acceptance criteria:
1. POST /api/auth/reset/request accepts email; always returns the same 200 body
   whether or not the user exists.
2. When user exists, email is queued with HTTPS link; token TTL ≤ 60 minutes.
3. More than 5 requests / hour / IP returns 429.
4. Unit tests cover unknown email, known email, and rate limit.

### D3 — Set-password UI + API
Acceptance criteria:
1. /reset/confirm?token=… validates token server-side; invalid/expired shows
   clear error without leaking which failed.
2. New password meets existing policy; on success all sessions for user revoke
   optional (product choice: revoke other sessions = yes).
3. Mobile viewport 375px: form usable without horizontal scroll; tap targets ≥ 44px.
4. Playwright flow: request → (stub mail) → confirm → login with new password.

### D4 — UX polish + a11y
Acceptance criteria:
1. axe critical/serious = 0 on both forms.
2. Keyboard-only completion of both flows.
3. Design language: match existing auth pages (Inter, clinic blue #0B4F6C,
   calm spacing, no new aesthetic).

## Design language (UI)
- Typography: Inter / system UI, 16px body, 24px titles
- Palette: primary #0B4F6C, bg #F7F9FA, error #B42318, success #027A48
- Spacing: 8px grid; form max-width 28rem centered
- Aesthetic intent: clinical calm, high contrast, zero decoration for decoration

## Operator summary
You'll get a "Forgot password?" link on the login page. Patients enter email,
get a message, tap a link, set a new password on their phone. Staff get fewer
reset calls. About three small shippable pieces after the database change.
```

**Approval:** Mark, 2026-07-20 — "Yes, revoke other sessions on reset."

---

## Epic

**Title:** `[epic] Password reset by email`  
**Labels:** `gibson`, `P0`  
**Body:** Tracks PLAN password-reset. Children: #101–#104. Order: 101 → 102 → 103 → 104.

---

## Issue #101 — Schema: password reset tokens

**Labels:** `gibson`, `tier-c`, `P0`, `area-db`

```markdown
## Context
PLAN § D1 — additive token storage for email password reset.
https://…/PLAN.md#d1--token-storage-schema

## Sprint contract (acceptance criteria)
- [ ] AC1 — Migration adds ResetToken (or equivalent) with userId, tokenHash,
      expiresAt, usedAt; FK to User
- [ ] AC2 — `prisma migrate` / deploy path applies on preview without
      --accept-data-loss
- [ ] AC3 — schema-guard CI green (schema + migration in same PR)

## Affected area
prisma/schema.prisma, prisma/migrations/**

## Out of scope
API routes, UI, email copy

## Dependencies
none

## Tier
C
```

---

## Issue #102 — API: request reset + rate limit + email

**Labels:** `gibson`, `tier-b`, `P0`, `area-api`

```markdown
## Context
PLAN § D2. Depends on token table from #101.

## Sprint contract (acceptance criteria)
- [ ] AC1 — POST /api/auth/reset/request always returns identical 200 JSON for
      known and unknown emails
- [ ] AC2 — known user → email job enqueued with single-use link; TTL ≤ 60m
- [ ] AC3 — 6th request within 1h from same IP → 429
- [ ] AC4 — unit/integration tests for AC1–AC3
- [ ] AC5 — no raw token logged; only hash stored

## Affected area
app/api/auth/reset/**, lib/email/**, lib/rate-limit/**

## Out of scope
Confirm UI, session revoke UX copy

## Dependencies
Blocked by #101

## Tier
B
```

---

## Issue #103 — Confirm password UI + API + session revoke

**Labels:** `gibson`, `tier-b`, `P0`, `area-auth`

```markdown
## Context
PLAN § D3. Mark decision: revoke other sessions on success.

## Sprint contract (acceptance criteria)
- [ ] AC1 — GET/POST confirm flow validates token server-side; bad token → generic error
- [ ] AC2 — successful reset updates password hash, marks token used, revokes other sessions
- [ ] AC3 — password policy matches existing signup rules (shared validator)
- [ ] AC4 — Playwright: issue-103-reset-happy.spec.ts against preview (mail stub)
- [ ] AC5 — mobile 375px layout: no horizontal scroll; primary button ≥ 44px height

## Affected area
app/(auth)/reset/**, app/api/auth/reset/confirm/**, lib/auth/**

## Out of scope
Redesign of login page chrome (only add forgot link if missing)

## Dependencies
Blocked by #102

## Tier
B
```

---

## Issue #104 — A11y + design-language conformance

**Labels:** `gibson`, `tier-a`, `P0`, `area-ui`

```markdown
## Context
PLAN § D4 — grade against design language; axe hard-fail.

## Sprint contract (acceptance criteria)
- [ ] AC1 — axe critical/serious = 0 on /reset and /reset/confirm
- [ ] AC2 — keyboard-only completes both flows
- [ ] AC3 — visual match to existing auth pages per design language (ux-eval ≥ 7 craft)

## Affected area
app/(auth)/reset/**

## Out of scope
New brand colors

## Dependencies
Blocked by #103

## Tier
A
```

---

## Decompose lint

```bash
node scripts/decompose-lint.mjs --file docs/examples/fixtures/04-issues.json
# → OK (4 issues)
```

**Sizing notes applied:** schema alone (#101); ≤10 ACs each; hot file
`schema.prisma` serialized via Blocked-by; Tier C only on schema.
