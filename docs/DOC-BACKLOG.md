# Documentation Backlog — Grok Handoff

The design docs (01–15) are the spec and carry the *why*. This file is the writing
queue for expanding them into exceptional, complete documentation. Grok: work top to
bottom; one PR per item; match the existing voice (rules cite their reasons; tables
over prose walls; no marketing tone). The style contract is doc 00 conventions:
every claim traceable, every rule why-linked, examples runnable.

## P0 — needed before first fleet run

1. **playbooks/** — one dispatch playbook per role (9), each: frontmatter (role,
   inputs, outputs, gates), then the full prompt. Source material: docs/03 role
   contracts + docs/02 stage rules. `builder.md`, `reviewer.md`, `ux-evaluator.md`
   first.
2. **playbooks/loop-step.md** — the solo-loop hat prompt (doc 11), parameterized by
   `{{hat}}`, `{{loop_state}}`.
3. **playbooks/adopt.md** — the adoption procedure (doc 13) as an executable
   playbook with the audit checklist inline.
4. **scripts/ real implementations** — `loop.sh`, `claim.sh`, `gate-baseline.sh`,
   `gate.sh`, `decompose-lint.mjs`, `route-inventory.mjs` (Next.js first). Specs in
   scripts/README.md.
5. **ci/ working workflows** — `gibson-gate.yml`, `security.yml`, `ux-eval.yml`,
   `retro.yml` filled in and tested against a sandbox repo.

5b. **scripts/deploy-audit.sh + playbooks/deploy-audit.md** — doc 17's inspect
   mode as runnable tooling (Vercel API/MCP: analytics, runtime + build logs;
   bundle analyzer; log queries) emitting the scorecard + top-5 report.
5c. **Decision-card + Operator message templates** — doc 16's four message shapes
   as fill-in templates Hermes renders; includes the plain-language translation
   rules and the "confusion is a bug" feedback wiring.
5d. **VIBECODING.md hardening** — test the guide on 2–3 actual non-technical
   readers; every point of confusion is a lesson (doc 09) and a rewrite.

## P1 — depth passes on existing docs

6. **Per-doc worked examples**: doc 04 (a real PLAN.md → real issue set, full
   text), doc 07 (a complete Playwright flow spec + eval report sample), doc 08
   (a filled authz matrix for a 3-role app).
7. **Troubleshooting guides**: loop won't go green; claim conflicts; preview URL
   resolution failures; ZAP false positives; flaky visual diffs.
8. **docs/00-glossary.md** — every Gibson term (green gate, ratchet, hat, lane,
   claim, tier, grade G/S/F, parked) with one-line definitions.
9. **Adapter READMEs** (4): exact setup per runtime — install, auth, doctrine
   loading, dispatch invocation, telemetry wiring, cost capture. Test each on the
   actual machine.

## P2 — polish

10. **Architecture diagram** (Mermaid in README): pipeline, roles, stores, MC
    relationship.
11. **FAQ.md** — seeded from questions Mark actually asks during first month.
12. **Case study** — first adopted repo, before/after: cost per PR, cycle time,
    escaped defects. This is the marketing artifact and the proof.

## Rules for this work

- Docs PRs go through the normal pipeline (review by a different runtime — the
  harness governs itself, doc 09).
- Never contradict docs 01–15 silently; a conflict is a finding — raise it in the
  PR body.
- Runnable > descriptive: if a doc explains a procedure, the procedure should also
  exist as a script or playbook the doc links to.
