---
title: "Changelog"
nav_exclude: true
---

# Changelog

Written for fork owners deciding whether to take an update: what changed, why,
and any migration note. Sync PRs (docs/18) quote the relevant entries verbatim.

## Unreleased

Cloud supervisor + cross-vendor escalation for the solo loop.

- **`scripts/devin-supervisor.sh`** — one persistent Devin cloud session per repo
  (`ensure` / `status` / `wake` / `handoff`) that reviews finished branches and owns
  GitHub: PR, CI, and merge with `--merge`. Session id cached in
  `<repo>/gibson/devin-session.json`; a session that ended is replaced through
  `DEVIN_WEBHOOK_URL` (Devin webhook automation), falling back to the sessions API.
- **`scripts/second-opinion.sh`** — cross-vendor read-only review of a diff that
  refuses to let a runner review its own work (AGENTS.md Law 5, docs/20 rule 1).
- **`scripts/loop.sh`** — new `--escalate-after N`, `--reviewers`, and
  `--supervisor devin`. Escalation writes `gibson/second-opinion.md`; handoff is a
  file protocol: the agent sets `handoff: <branch>` in loop-state, the driver
  forwards it and clears the field.
- **Docs:** `docs/22-devin-cloud-supervisor.md` (escalation ladder, cost routing,
  merge authority), `adapters/devin/` including a launchd job for a resident
  loop on macOS.
- Migration: none — all new flags are off by default and the existing loop behaves
  exactly as before. Forks that render loop-state themselves may want to add the
  `handoff:` field.

## v0.1.4 — 2026-07-29

Delivery control (production write-path) as portable doctrine.

- **Doctrine:** [docs/23-delivery-control.md](docs/23-delivery-control.md) — branch
  models A/B/C, pass criteria, harden/promote/hotfix modes, explicit **no secret
  rotation** (G4). Distills ConferenceOS release-manager lessons without COS-only
  check names or Neon key handling.
- **Playbook:** [playbooks/delivery-control.md](playbooks/delivery-control.md);
  release + adopt playbooks preflight audit when merge ships Production.
- **Scripts:** [scripts/delivery-control/](scripts/delivery-control/) — audit,
  apply-branch-protection, apply-production-env, promote, hotfix-prep,
  forward-port (dry-run default; `--apply` + confirm).
- **Template:** `templates/target-repo/gibson-delivery.json` for target check
  contexts and branch model.
- Migration: optional. At next adoption or burn-down, run `audit.sh` on each
  live target; harden only with operator apply. Forks sync doc 23 + scripts via
  normal upstream-sync.

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
