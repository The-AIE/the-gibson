# local/ — your fork's overlay (upstream never touches this directory)

Everything org-specific lives here. Core files stay pristine so upstream updates
merge cleanly. Full rules: `docs/18-fork-and-upstream.md`.

- `AGENTS.local.md` — loaded by every agent right after `AGENTS.md`; your
  additions and overrides (local wins, except the Ask Contract and human-gate
  removals — see doc 18).
- `docs/` — your org-specific doctrine.
- `playbooks/` — same filename as a core playbook = replaces it; new names extend.
- `gate-commands/` — per-repo gate definitions.

## AGENTS.local.md template

```markdown
# Local overrides — <org name>

## Fleet
<runtimes available, pool shapes for doc 15 routing, MC endpoint>

## Overrides
<threshold changes, extra laws, house style — one per line, each with a why>

## Added human gates
<org-specific gates, numbered G17+ — extensions only; removals need an owner
decision recorded in memory/DECISIONS.md>

## Vocabulary
<org terms agents should use with your operators>
```

This upstream repo ships only this README in `local/` — the directory is yours.
