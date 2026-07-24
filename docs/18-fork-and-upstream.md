---
title: "18 · Fork it, stay updated"
parent: The Doctrine
nav_order: 18
---

# 18 — Fork & Upstream: Customize Without Losing Updates

> 🙂 **In plain English:** Make your own copy, customize it for your team, and still pull
> in improvements from the original. Your local tweaks stay separate so updates do not
> wipe them out.

The Gibson is designed to be **forked**. You take a copy, adapt it to your fleet,
your repos, and your rules — and you keep receiving upstream improvements (new
gates, better playbooks, fresh lessons) with near-zero merge pain. The trick is
not clever merging; it's a file layout where upstream and fork rarely touch the
same lines.

## Ownership layers

| Layer | Owner | Files | On upstream update |
|---|---|---|---|
| **Core doctrine** | Upstream | `docs/01–18`, `AGENTS.md`, `playbooks/*`, `scripts/*`, `ci/*`, `templates/*`, `README.md`, `VIBECODING.md`, `GUIDE.md` | Fast-forwards cleanly — forks don't edit these |
| **Local overlay** | Fork | `local/**` — overrides, additions, org-specific playbooks and gate commands | Never touched by upstream, by covenant |
| **Fleet memory** | Fork | `memory/LESSONS.md`, `memory/DECISIONS.md`, `memory/incidents/` | Append-only files: upstream's new entries and yours interleave without conflict |

Two covenants make this work:

1. **Upstream never creates or edits anything under `local/`.** That directory is
   structurally yours.
2. **Forks never edit core files directly.** Want different behavior? Override it
   in `local/` (below). Want a core file *fixed*? PR it upstream. Editing core
   in-place is how you orphan yourself from updates — it works, but you're
   choosing to maintain a divergent harness.

## The override mechanism

Deliberately low-tech — precedence by convention, enforced by the doctrine loader
(Law 1) rather than machinery:

- **`local/AGENTS.local.md`** — loaded immediately after `AGENTS.md` by every
  agent, every session. Additions and overrides live here: extra laws, changed
  thresholds, org vocabulary, house style. On conflict, **local wins** — with two
  exceptions that upstream hard-reserves: the Ask Contract may not be weakened,
  and the human-gate list (doc 14) may be *extended* locally but entries may only
  be *removed* by the fork's own human owner, recorded in the fork's
  `memory/DECISIONS.md`.
- **`local/docs/`** — org-specific doctrine (their tiers, their vendors, their
  compliance needs). Core docs may link "see local overrides" but never depend on
  them existing.
- **`local/playbooks/`** — a playbook here with the same filename as a core one
  **replaces** it at dispatch time; new names extend the set.
- **`local/gate-commands/`** — per-repo gate definitions referenced by target-repo
  AGENTS sections, instead of editing `ci/` templates.

Everything else about the pipeline reads config from the target repo or `local/`,
never from edits to core.

## Receiving updates (the sync loop)

Upstream updates are just work — so the fork's **own fleet** performs them through
the normal pipeline:

```
scripts/upstream-sync.sh (scheduled weekly, or on-demand):
  git fetch upstream
  new commits?  → branch chore/upstream-sync-<date>
                → merge upstream/main   (core fast-forwards; memory interleaves;
                                         local/ untouched → conflicts ≈ none)
                → run doctrine checks   (link check, override-shadow report:
                                         "your local/ overrides these files,
                                         upstream changed 2 of them — re-read")
                → open a PR with a plain-language summary of what changed
                  upstream and why (from CHANGELOG.md), per the Ask Contract
```

Gate rules for the sync PR:
- Routine updates (new playbooks, doc improvements, new lessons): normal review,
  merge, done.
- Updates touching **doc 14 (human gates), tier definitions, or hard-fail
  thresholds**: automatically Tier C in the fork — the fork's human owner gets a
  decision card before their harness's stopping rules change underneath them.
  Your harness's brakes never change without your signature, even by upstream.

## Versioning

- Upstream tags releases (`v1.x`) and maintains `CHANGELOG.md` — every entry
  written to be *readable by a fork owner deciding whether to take the update*:
  what changed, why, migration note if any.
- Breaking doctrine changes (renamed files, changed override semantics, new
  required local config) bump the major version and ship with a migration section
  the sync PR quotes verbatim.
- Forks pin nothing: `main` tracks their own work; upstream arrives via sync PRs
  they can sit on as long as they like.

## Contributing back (the ratchet flows uphill)

The self-improvement loop (doc 09) gets a fourth arrow: lessons and fixes that are
**general** — not specific to your org, repos, or secrets — belong upstream, where
every fork inherits them.

- The historian's weekly sweep tags each new lesson `local` or `general`;
  `general` candidates become upstream PRs (a playbook fix, a new Semgrep rule, a
  doc correction).
- **Privacy line:** nothing from `local/`, no target-repo names, no incident
  details, no numbers you wouldn't publish. Upstream lessons are sanitized to the
  pattern, not the story. The sync script's pre-push check greps outbound PRs for
  fork-repo identifiers as a backstop.
- Upstream reviews contributions through its own pipeline (doc 09: the harness
  never gets a lower bar than the code it governs).

## Fork quickstart

1. Fork `mrhinkle/the-gibson` (private is fine); clone.
2. `git remote add upstream https://github.com/mrhinkle/the-gibson.git`
3. Create `local/AGENTS.local.md` from `local/README.md`'s template — your fleet
   names, your thresholds, your house rules.
4. Reset fleet memory: keep upstream's lessons (they're scar tissue you want) or
   archive them to `memory/upstream-seed.md` and start clean — your call, recorded
   in `DECISIONS.md`.
5. Adopt your first repo (doc 13). Schedule `upstream-sync.sh` weekly.
