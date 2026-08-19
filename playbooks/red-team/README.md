# Gibson — Red-Team Module


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../../AGENTS.md). This file must not add, drop, or weaken those rules.

Red-team is **one playbook on Gibson, not Gibson's identity**. Gibson is a portable SDLC
harness; this playbook is the adversarial audit capability it can run: a repeatable protocol
you point at an app to find security, auth, payment, PII/consent, and business-logic flaws
before they ship — and before you pay for a third-party review.

## How it fits

```
Gibson (harness)
  └─ playbooks/red-team/            ← this playbook
       ├─ PROTOCOL.md               ← the six-phase adversarial protocol (app-agnostic)
       ├─ targets/                  ← one profile per app under test
       │    └─ conference-os.md     ← first target: the money + PII app
       └─ findings/                 ← dated findings ledgers, one per run
            └─ TEMPLATE.md
  └─ playbooks/recipes/
       ├─ red-team.yaml             ← Goose recipe mirror (validation-only scaffold)
       └─ red-team.toolchain.json   ← exact tool pins for a reproducible run
```

It sits alongside the other role playbooks (`builder`, `reviewer`, `security`, …) and is
dispatched the same way. It deepens the `security` role for a scheduled audit; it does not
replace the pipeline's per-PR security gate.

## Machine-readable recipe (issue #25 — partial)

`playbooks/recipes/red-team.yaml` is a **Goose Recipe type 1.0.0** mirror of this
playbook for pinned Goose CLI **v1.45.0**. It references `PROTOCOL.md`, an exact
`targets/` profile path, and `findings/TEMPLATE.md` from disk — it does **not** fork
doctrine text. Tool versions live in `playbooks/recipes/red-team.toolchain.json`.

### What is green vs what is not

| Check | Status on this slice |
|---|---|
| Offline structural sensor `scripts/tests/goose-recipes.test.sh` | Required green gate (no network, no Goose binary, no credentials) |
| Official `goose recipe validate` | Optional; if `goose` is absent, report **NOT RUN** — that is not external validation success |
| Live red-team execution against a target | **Owner-gated** — requires Mark's one-time supervised read-only lab approval for **#28** (fake data, test payment mode, exact target, cost/credential approval) |
| Permission / in-session enforcement | **Not decided** — deferred to **#35** |
| Issue #25 | **Remains open** until a Mark-authorized #28 run produces a stamped findings ledger |

Do not upgrade this boundary. Do not claim readiness, enforcement, or authorization
from a green offline sensor alone.

### Validation-only path (authorized today)

```bash
# Offline structural sensor (required)
scripts/tests/goose-recipes.test.sh

# Optional official Goose schema check — only if the pinned CLI is already installed
# (do not install Goose from this playbook). Absence → report NOT RUN.
goose --version   # expect 1.45.0 when present
goose recipe validate "$GIBSON/playbooks/recipes/red-team.yaml"
```

### Live run path (not authorized by this slice)

An actual #28 run requires Mark's supervised approval first. When that gate opens,
stamp the findings ledger using `findings/TEMPLATE.md` (recipe SHA-256, toolchain-lock
SHA-256, target-profile SHA-256, Goose version/digest, start/end UTC, supervised mode,
sanitized transcript reference). Never write secrets, real PII, credential paths, or
absolute private home paths into the ledger.

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
Live Goose recipe dispatch is not authorized until the #28 lab gate above clears.
