---
title: "Changelog"
nav_exclude: true
---

# Changelog

Written for fork owners deciding whether to take an update: what changed, why,
and any migration note. Sync PRs (docs/18) quote the relevant entries verbatim.

## v0.1.3 — 2026-07-24

Docs site: GitHub Pages + navigation + plain-English callouts.

- **Navigation:** just-the-docs front matter on operator docs, AGENTS, glossary,
  reading order; doctrine parent page with chapters 01–19 as children; secondary
  pages (roadmap, changelog, playbooks, adapters, examples, memory) rendered but
  `nav_exclude` so the sidebar stays clean.
- **Plain English:** callouts after the H1 on docs 01–19, AGENTS.md, GUIDE.md, and
  QUICKSTART.md for non-technical readers.
- **Footers:** prev / Home / next links at the bottom of each doctrine chapter.
- Migration: none. Forks that already published Pages will pick this up on sync.

## v0.1.0 — 2026-07-24

Initial public doctrine.

- Core: design docs 01–18, AGENTS.md contract (Ten Laws + Ask Contract),
  operator GUIDE, VIBECODING guide, memory seeds (L-001–L-005, D-001–D-004),
  target-repo templates, `gibson-gate.yml` CI template, script specs, roadmap.
- Fork model: `local/` overlay, ownership layers, sync loop, contribute-back
  rules (doc 18).
- Migration: n/a (first release).

## v0.1.2 — 2026-07-24

Documentation and tooling backlog (DOC-BACKLOG P0–P2) filled for first fleet run.

- **Playbooks:** nine role dispatch prompts, `loop-step.md`, `adopt.md`,
  `deploy-audit.md`, Operator message templates (`playbooks/templates/`).
- **Scripts:** claim/release-claim, gate-baseline/gate, decompose-lint,
  route-inventory, posture-probe, preview-url, loop, deploy-audit, upstream-sync
  (POSIX bash / plain Node, `--help` Ask Contract on each).
- **CI templates:** security.yml, ux-eval.yml, schema-guard.yml, retro.yml.
- **Depth:** worked examples (docs 04/07/08), troubleshooting guides, glossary,
  adapter READMEs (claude-code, codex, grok, hermes).
- **Operator docs:** QUICKSTART, FAQ, docs/00-INDEX, README Mermaid architecture
  diagram, GUIDE end-to-end walkthrough.
- Migration: none for forks. Optional: vendor new `scripts/` and `ci/` into
  adopted target repos at next adoption or burn-down PR.

## v0.1.1 — 2026-07-24

- Public release under Apache-2.0 (LICENSE + NOTICE; copyright Mark Hinkle).
- Product naming confirmed in doc 19: Foreman (orchestrator), CodeWright
  (vibecoding guide), Blueprint (the plan); business model = free add-on to the
  AIE subscription (D-005).
- Migration: none.
