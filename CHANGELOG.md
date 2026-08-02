---
title: "Changelog"
nav_exclude: true
---

# Changelog

Written for fork owners deciding whether to take an update: what changed, why,
and any migration note. Sync PRs (docs/18) quote the relevant entries verbatim.

## Unreleased

One command in, target repos harness-neutral out.

- **`skills/`** (new) — a nested Claude Code skill layer: `/gibson <repo> [goal]`
  runs audit → resources → setup → direct → run. It wraps the existing scripts,
  playbooks, and doctrine rather than reimplementing them, so the harness keeps
  one source of truth and the owner gets one command. Install by symlinking into
  `~/.claude/skills` (`skills/README.md`). No script behaviour changed.
  The skills disclose the `loop.sh`/supervisor gaps they cannot fix (#55) instead
  of implying the loop merges on its own.

- **`templates/target-repo/AGENTS-section.md`** — rewritten as a harness-neutral
  *Autonomous development contract*: the repo publishes gate commands, ground rules,
  hot files, deploy truth, and its human-only action list, naming no harness and no
  vendor. Any agent — this harness, a bare Claude Code or Codex session, something
  not written yet — can read it and take over. The coupling now points one way.
- **`templates/target-repo/gate.json`** → target's `.agents/gate.json`, the
  machine-readable twin of the gate commands. `scripts/gate.sh` and
  `scripts/gate-baseline.sh` read it first and accept a nested `gate` object so the
  file can carry other agent config.
- **Migration:** none required. `.gibson-gate.json` is still read as a fallback, so
  repos adopted earlier keep working; move the file when convenient.

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

The red-team playbook learns the Pale Fire class.

- **`scripts/injection-scan.sh`** (new) — flags zero-width, bidi-override, BOM and
  soft-hyphen characters in anything a model ingests (skills, prompts, recipes,
  shared config). Block's Goose disclosure hid U+200B/U+200C inside shared recipes:
  invisible in a git diff, fully tokenized by the LLM. Review cannot catch this, so
  the check has to be mechanical. Wired into red-team Phase 2.
- **`playbooks/red-team/PROTOCOL.md`** — new Phase-3 subsection on prompt injection
  and poisoned shared config (invisible payloads, untrusted content reaching a
  prompt, fleet config with no integrity verification, and what the granted tool
  surface lets an injected instruction actually do), plus a five-layer
  defense-in-depth checklist for agent-runtime targets that separates what Gibson
  audits from what the target must build. Fleet-distributed config with no integrity
  check is now a NOT READY blocker on its own.
- **`playbooks/red-team/targets/conference-os.md`** — speaker bios and session
  titles named as the prompt-injection entry points, not just the stored-XSS ones.

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
