---
title: "Changelog"
nav_exclude: true
---

# Changelog

Written for fork owners deciding whether to take an update: what changed, why,
and any migration note. Sync PRs (docs/18) quote the relevant entries verbatim.

## Unreleased

The release hat stops re-diagnosing the same three merge calls.

- **`scripts/release-preflight.sh`** — read-only pre-merge verdict, exit 0 READY /
  1 BLOCKED / 4 ADMIN-CANDIDATE. Reads `closingIssuesReferences` so a partial ship
  cannot silently close its issue on negated prose (L-013); accepts a
  `VERDICT: APPROVE` comment as the review of record when GitHub's same-author rule
  makes a formal approval impossible, and grades it ADMIN-CANDIDATE rather than
  READY because branch protection still blocks the merge (L-015 / L-021); separates
  GitHub Actions `startup_failure` / no-steps / no-runner infra red from a step that
  actually failed (L-033). Tier C and `--launched` have no admin path at all.
- **`scripts/tests/release-preflight.test.sh`** — fixture-driven, fake `gh` on PATH,
  no network.
- **Playbooks:** `release.md` runs preflight as step 0 of stage 7 and documents how
  to read each verdict; `reviewer.md` documents the same-author `VERDICT:` fallback
  and that it is a review signal, not merge authorization.
- **Migration:** none. The script is additive; nothing calls it automatically.

release-claim stops half-finishing cleanup.

- **`scripts/release-claim.sh`** — commits the claim-row removal from a throwaway
  worktree on main, so it no longer needs (or moves) the canonical checkout and no
  longer strands rows when that checkout is on a feature branch or dirty (L-009).
  `--claim-id` releases one slice of a multi-slice issue and keeps `agent-claimed`
  while sibling rows remain (L-024). Label removal is re-read and verified instead
  of assumed (L-027). `--prefix` matches namespaced ids (`issue-template-<N>-*`) and
  `--repo` points the label call at a product repo that differs from the claim-table
  repo (L-036 / L-037). Unfinished cleanup now exits **3** and names what is still
  live rather than printing OK.
- **`scripts/tests/release-claim.test.sh`** — first shell test in the repo; the four
  lessons above are now sensors, not guide lines (Law 9).
- **Migration:** none. Existing `release-claim.sh <issue>` calls behave the same,
  except that a previously-silent partial cleanup is now a non-zero exit. Fleets
  that treat any non-zero as fatal should special-case 3 as "finish by hand".

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
