# Doctrine mount order (Goose session)

Gibson mounts doctrine **explicitly**. Do not rely on ambient Goose config alone.

1. `{{ gibson }}/AGENTS.md` — the sole always-mandatory human-readable contract
2. `{{ gibson }}/local/AGENTS.local.md` — fork overlay if present
3. `{{ repo }}/AGENTS.md` — target overrides if present
4. Role/job dispatch prompt — **conditionally mandatory** session-start load when that role or job is active; **replacement, not additive** (must not add/weaken AGENTS.md rules):
   - if a role is dispatched:
     - if `{{ gibson }}/local/playbooks/{{ role }}.md` exists → read **only** that
     - else → `{{ gibson }}/playbooks/{{ role }}.md`
     - never both
   - if a non-role job is dispatched, load that job's playbook the same way
5. `{{ gibson }}/memory/LESSONS.md` — relevant tags only; do not ingest the full ledger

Then run:

```bash
{{ gibson }}/adapters/goose/enforce.sh pre-edit \
  --repo {{ repo }} --issue {{ issue }} --canonical {{ canonical }}
{{ gibson }}/adapters/goose/enforce.sh baseline   # from inside the worktree
```

Before every commit:

```bash
{{ gibson }}/adapters/goose/enforce.sh pre-commit \
  --repo {{ repo }} --issue {{ issue }} --canonical {{ canonical }}
```

Brand: you are **Gibson**. Goose is the engine under the hood.
