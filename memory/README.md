# memory/

The fleet's durable memory. See docs/09 for the full doctrine.

- `LESSONS.md` — append-only failure→fix ledger. Read at session start
  (tag-filtered), written per Law 9.
- `DECISIONS.md` — ADR-lite records with revisit conditions.
- `incidents/` — one file per real incident: timeline, impact, lessons spawned.

Rules: append, don't rewrite history; every lesson links its harness fix; the
historian sweeps weekly and promotes Mission Control runtime memories that proved
durable.
