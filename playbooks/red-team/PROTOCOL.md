# Gibson Red-Team Protocol

A repeatable adversarial audit you run on demand. The goal is to exhaust every flaw a
motivated attacker or a self-directed expert could find, so that when you pay a third-party
firm you are buying the deep business-logic and design findings only humans catch — not a
report that says "you leaked a key and your endpoints have no auth check."

Run this:
- Before any release that touches auth, payments, registration, or the data schema.
- On a standing cadence (quarterly is sane for an app with money + PII).
- Immediately before requesting third-party pentest quotes — the exit verdict is the "ready" gate.

## Rules of engagement (read before you attack)

1. Run against a preview/staging deploy or a local instance, never destructive tests against
   prod. Read-only recon against prod is fine; anything that writes, deletes, or floods runs
   against a non-prod target with seeded test data.
2. Never exfiltrate real PII. If a test would pull live personal data, seed a fake record and
   attack that instead.
3. No schema mutations as part of the test.
4. Log every finding to the ledger as you go (`findings/YYYY-MM-DD-<target>.md`).

Target-specific rules of engagement live in the target's profile under `targets/`.

## The six phases

### Phase 1 — Map the attack surface
Enumerate every way data enters or leaves before attacking any of it: routes, server actions,
API/route handlers, webhook receivers, every input surface, every env var (flag anything that
ships to the browser), every outbound call. Output: a one-page surface map — it doubles as the
onboarding doc you hand a paid reviewer.

### Phase 2 — Automated sweep (must be green before manual work is worth it)
- **Secrets:** `gitleaks` and `trufflehog` across full git *history*. Any hit → rotate immediately.
- **Dependencies:** `npm audit` + Socket.dev for malicious/typosquatted packages.
- **SAST:** Semgrep (default + framework rulesets); CodeQL if available.
- **Client-bundle leak check:** build, then grep the output for keys/tokens/connection strings.
- **Types:** strict mode on; build fails on type errors.

### Phase 3 — Adversarial subsystem attacks (the core)
Attack each subsystem with intent, not a checklist. The question is "how do I abuse this."
- **Auth & access control:** IDOR/BOLA on every object-scoped route; missing function-level
  authz; session/token handling; tenant isolation.
- **Payments:** price/amount tampering; webhook signature verification + replay/forgery;
  idempotency/race; coupon abuse; refund/transfer abuse.
- **PII & consent:** response over-fetch; PII in logs and errors; consent actually enforced;
  export/erasure reach; CSV injection in exports.
- **Injection & untrusted input:** raw SQL, stored XSS in user content, SSRF via user-supplied URLs.
- **Infra & abuse:** rate limiting / DoS on expensive endpoints; secret exposure; preview-deploy leaks.
- **Business logic:** capacity/waitlist bypass, duplicate registration, paying-tier bypass,
  promo stacking, ticket-transfer abuse.

### Phase 4 — AI adversarial pass
For each subsystem, point an agent at the code with **attack framing**, not review framing:
"Find every route touching payments and tell me how an unauthenticated attacker abuses it."
Per-subsystem, not whole-repo. Feed results into Phase 5.

### Phase 5 — Triage & score (by blast radius)
- **Critical** — remote, unauthenticated, hits money or PII. Fix before anything ships.
- **High** — authenticated but crosses a trust boundary (IDOR, missing authz, price tamper).
- **Medium** — needs unusual conditions or limited blast radius.
- **Low** — hardening / defense-in-depth.

### Phase 6 — Document & close the loop
Write every finding to the dated ledger (`findings/`, using `TEMPLATE.md`). File Critical/High
as GitHub issues on the target's repo, labeled `security` + severity. Fix, then **re-run the
relevant phase** — a finding isn't closed until a second pass comes back quiet.

## Exit verdict
- **NOT READY** — any open Critical/High, any Phase-2 check red, or the client-bundle leak
  check found something. List blockers.
- **READY FOR THIRD-PARTY REVIEW** — Phase 2 green and stable, no open Critical/High, secrets
  rotated, payment + PII/consent paths attacked and clean on re-test, surface map current.
  This is the point of diminishing returns on self-audit. Book the review; don't gold-plate past it.

## Downstream — the Chatterbuilt handoff contract
When this protocol graduates into Chatterbuilt's Employee Handbook skill pack, the agent crew
runs it against the customer sites it maintains. The contract:
- The crew runs **Phases 1–5** autonomously and **Phase 6 documentation** to a per-site ledger.
- Any **Critical or High** finding is a **judgment-call escalation** — the crew texts the owner
  (per Crew Chief's approval-gate doctrine), it does not self-remediate money/PII/auth flaws
  unattended.
- **Rules of engagement are non-negotiable in the product context:** never runs destructive
  tests against a live customer site, never touches real customer PII — seeded records only.
- Findings feed fleet-wide Employee Handbook updates: a real flaw found on one site becomes a
  standing check across the fleet.
