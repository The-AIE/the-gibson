---
title: "Memory"
nav_exclude: true
---

# memory/

The fleet's durable memory. See docs/09 for the full doctrine.

- `LESSONS.md` — append-only failure→fix ledger. Read at session start
  (tag-filtered), written per Law 9.
- `DECISIONS.md` — ADR-lite records with revisit conditions.
- `incidents/` — one `I-NNN.md` per incident. `incidents/INDEX.md` is the only map from an incident id to a lesson id. A missing evidence value is the word `unknown`. Schema: [lesson ledger](../docs/schemas/lesson-ledger.md).

Rules: append, don't rewrite history; every lesson links its harness fix; the
historian sweeps weekly and promotes Mission Control runtime memories that proved
durable.
