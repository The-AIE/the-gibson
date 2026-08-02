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
- **Invisible characters:** `scripts/injection-scan.sh` across every file the agent
  ingests — skills, prompts, recipes, shared config, docs. Any hit is a blocker
  until a human explains that exact byte.

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

#### Prompt injection & poisoned shared config

The attack that does not look like an attack. In Block's "Operation Pale Fire"
(Jan 2026) the payload was zero-width Unicode inside shared Goose *recipes*:
invisible in the git diff, fully tokenized by the model. The config file was the
delivery vehicle, and review — human or AI reading rendered text — could not see it.

Any fleet-distributed skill pack has this shape: poison one file, every agent that
loads it executes the instruction. Attack it in four directions.

- **Invisible payloads in ingested files.** Run `scripts/injection-scan.sh` (Phase 2)
  and then read the hits: zero-width space/joiner, word joiner, bidi overrides,
  BOM, soft hyphen in any skill, recipe, prompt, MCP manifest, or shared config.
  Ask the reciprocal question too: *would this repo's review process have caught
  it?* If the answer is "a human would have to notice a missing space", the
  scanner is load-bearing and belongs in required CI, not in a playbook.
- **Untrusted content reaching a prompt.** Trace every user-supplied string that
  ends up in a model's context — speaker bios, session titles, profile fields,
  filenames, imported CSV cells, webhook payloads, issue and PR bodies the agent
  reads. For each: is it delimited and labelled as data, or concatenated into the
  instruction block? Try the direct version ("ignore previous instructions and…")
  and the patient version (content that only becomes an instruction once the agent
  summarizes it into another agent's context).
- **Shared config loaded without integrity verification.** Who can write the
  skill/recipe/MCP source the fleet loads? Is there a signature, hash pin, or
  version pin, or does every agent pull tip-of-main? A shared file with no
  integrity check and fleet-wide execution is Critical by blast radius even
  before you find a payload in it — one write is remote code execution across
  every customer.
- **Tool and MCP surface.** Enumerate what an injected instruction could actually
  *do*: which tools run without confirmation, whether a shell tool exists, whether
  an MCP server can be added at runtime, and whether outbound network calls could
  exfiltrate what the agent has read. Injection severity is a function of the
  granted capability, not of the prompt.

**Remediation guidance to hand the target:** strip non-printing characters at load
time rather than trusting authors; show a diff-style preview of any recipe/skill
before it executes; pin and verify shared config; keep untrusted content in a
labelled data channel; and require confirmation per action class (read / write /
shell / MCP call) rather than per session.

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

## Defense-in-depth checklist (agent-runtime targets)

Goose shipped five layers in response to Pale Fire. They are a good spec, so use
them as the checklist for any target that *is* an agent runtime or ships an agent
to customers. Two columns matter, because they are different jobs: what Gibson can
audit from the outside, and what the target must build itself.

| Layer | Gibson audits | Target must implement |
|---|---|---|
| 1. Diff-style preview before a recipe/skill runs | Does executing shared config require a visible confirm step? Is the preview rendered from the *bytes*, not the parsed intent? | Yes — the preview UI/CLI step |
| 2. Strip zero-width / non-printing Unicode at load | `scripts/injection-scan.sh` in required CI, plus a live test: feed a poisoned recipe and see whether it survives the loader | Yes — the load-time sanitizer |
| 3. Granular per-action permissions (read vs write vs shell vs MCP call) | Enumerate the tool surface and record which actions run unattended | Yes — the permission model |
| 4. Background scanning of MCP servers / extensions | Is there any check at all on third-party servers? Are versions pinned? | Yes — the scanner and the pinning |
| 5. Secondary model flagging injection/jailbreak patterns | Phase 4 already does this adversarially, per subsystem | Optional — valuable at fleet scale, not a substitute for layers 1–4 |

Layers 1 and 5 have Gibson analogues already: the human approval gate
(`docs/14-human-gates.md`) and the Phase-4 AI adversarial pass. Do not let that
similarity become a reason to skip verifying them in the target — our gate protects
*our* fleet, not the customer's.

**What we are explicitly not adopting:** Goose's single-agent, no-orchestration
posture. Fewer moving parts is a real security argument and we should be honest
that it is, but multi-role orchestration with claims, gates, and cross-vendor
review is the edge of this harness — and it is also a *defense*: the reviewer that
catches an injected instruction is a different agent, on a different model, that
never read the poisoned file. Harden the orchestration; do not delete it.

## Exit verdict
- **NOT READY** — any open Critical/High, any Phase-2 check red, the client-bundle leak
  check found something, or a fleet-distributed skill/recipe/config loads with no
  integrity verification. List blockers.
- **READY FOR THIRD-PARTY REVIEW** — Phase 2 green and stable, no open Critical/High, secrets
  rotated, payment + PII/consent paths attacked and clean on re-test, surface map current.
  This is the point of diminishing returns on self-audit. Book the review; don't gold-plate past it.

## Downstream — the Chatterbuilt handoff contract
When this protocol graduates into Chatterbuilt's Employee Handbook skill pack, the agent crew
runs it against the customer sites it maintains. The contract:
- The crew runs **Phases 1–5** autonomously and **Phase 6 documentation** to a per-site ledger.
- Any **Critical or High** finding is a **judgment-call escalation** — the crew texts the owner
  (per Crew Chief's approval-gate doctrine), it does not self-remediate money/PII/auth flaws
  unattended. Session-mode vocabulary for that gate lives in
  [docs/autonomy-modes.md](../../docs/autonomy-modes.md) (issue
  [#24](https://github.com/mrhinkle/the-gibson/issues/24)); this protocol does not change
  which findings escalate.
- **Rules of engagement are non-negotiable in the product context:** never runs destructive
  tests against a live customer site, never touches real customer PII — seeded records only.
- Findings feed fleet-wide Employee Handbook updates: a real flaw found on one site becomes a
  standing check across the fleet.
