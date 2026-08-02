---
title: "Changelog"
nav_exclude: true
---

# Changelog

Written for fork owners deciding whether to take an update: what changed, why,
and any migration note. Sync PRs (docs/18) quote the relevant entries verbatim.

## Unreleased

The solo loop stops handing off work nobody reviewed (#55).

- **`scripts/loop.sh`** — the cross-vendor review in front of a supervisor handoff
  is now a gate rather than a notice. A **receipt** (`gibson/second-opinion.receipt`)
  is written only when `second-opinion.sh` exits 0, and it names the runner, the
  reviewers, the head SHA, and the base branch *and* its exact tip. A stale
  `gibson/second-opinion.md` no longer satisfies the gate, a review of a head that
  has moved is not reused, and neither is a review of a base that has since
  advanced — a different base is a different diff. Reviews and handoffs resolve the
  target repo's own default branch from the remote instead of trusting stale local
  refs. No receipt, no handoff: the branch stays queued in loop-state.
  **Scope, stated plainly:** the receipt is an operational control over what the
  driver will do, **not** a tamper-proof one. It is a same-user file under
  `<repo>/gibson/`, so anything running as that user — including the agents the
  gate constrains — can write one. Isolating it is separate hardening (docs/22),
  and this change does not do it.
- **`scripts/devin-supervisor.sh`** — a pinned handoff (`--sha`, plus `--base-sha`)
  refuses to go out unless the branch exists on the remote and its tip still matches,
  and it describes the change by those exact commits rather than by branch names this
  clone may have stale copies of. The rendered message keeps a blank line before its
  `## Task` heading, so the pinned-SHA clause and the task do not arrive as one
  run-on line.
- **`scripts/check-active-work.mjs`** (new) — claim-isolation gate for CI
  `pull_request` runs. It diffs the merge base against the head, so appending your own
  claim passes while touching a claim that already existed on the base fails. Renames
  are scored as delete + add (`--no-renames`), because rename detection reports only
  the destination and would let a claim file be moved — to another claim id, or out of
  `docs/claims/` entirely — with its deletion invisible to the gate. Deleting a live
  claim is refused **even for the branch that owns it**: the ownership exemption covers
  renewing your own claim, not releasing it, which happens on main with
  `release-claim.sh` (docs/05). A base ref it cannot resolve is a loud error, never a
  green "no changed files".
- **Sensors:** `scripts/tests/loop-handoff.test.sh`, `scripts/tests/second-opinion.test.sh`,
  and `scripts/tests/check-active-work.test.sh` pin the above in both directions —
  the ways each gate must fail closed and the ways it must still pass. They drive the
  real scripts against stubs and temp git repos; no network, no Devin API.
- **Docs:** `docs/22-devin-cloud-supervisor.md` records the receipt's scope and the
  isolation work it does not cover; `scripts/README.md` carries the new inventory rows.
- **Migration:** none for existing flags, but a `--supervisor devin` loop that
  previously handed off without a completed cross-vendor review will now hold the
  branch in loop-state instead. That is the intended behaviour change; supply
  `--reviewers` with a vendor distinct from `--runner` to let handoffs proceed.

One command in, target repos harness-neutral out.

- **`skills/`** (new) — a nested Claude Code skill layer: `/gibson <repo> [goal]`
  runs audit → resources → setup → direct → run. It wraps the existing scripts,
  playbooks, and doctrine rather than reimplementing them, so the harness keeps
  one source of truth and the owner gets one command. Install by symlinking into
  `~/.claude/skills` (`skills/README.md`). No script behaviour changed.
  The skills describe what the loop and supervisor actually do — including where a
  human still has to act — instead of implying the loop merges on its own. The
  `loop.sh`/supervisor gaps they were written against are the #55 gaps fixed in the
  entry above; `gibson-setup` installs the claim-isolation sensor that came with it.

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

Target repos stop knowing about The Gibson.

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

Claiming stops being the thing that conflicts.

- **`scripts/claim.sh`** — a claim is now one file, `docs/claims/issue-<N>-<slug>.md`,
  instead of an appended row in the shared `docs/active-work.md` table. Every lane
  was appending to the same last line, so the ledger meant to prevent collisions
  became the collision — and blocked green product PRs touching none of those
  issues (L-023). Separate paths cannot conflict.
- **`scripts/claim.sh`** also refuses a second claim on an already-claimed issue
  (L-028: two builders, same issue, different slugs, a wasted build each, twice).
  A deliberate slice passes `--slice`; scope overlap is still refused either way.
  It no longer moves your canonical checkout to commit the claim (L-009).
- **`scripts/claims-status.sh`** (new) — the single view the table used to give,
  generated rather than hand-maintained: `--issue`, `--markdown`, STALE after 24h.
- **`scripts/release-claim.sh`** — releases claim files and legacy rows alike.
- **`playbooks/release.md`** — when `gh pr merge` fails inside a pinned fleet
  worktree, merge via the API rather than force-checking-out main under a running
  lane (L-020).
- **Migration:** none required. Legacy `docs/active-work.md` rows are still read as
  live claims and still released, so existing lanes drain normally; new claims land
  as files. The table can be deleted once it is empty.


A skipped UX or DAST gate is now either earned or a failure.

- **`scripts/ux-surface.sh`** (new) — classifies a diff as UI-affecting or not, so
  `gibson-ux-eval` can skip a pure-library PR instantly instead of waiting five
  minutes on a preview it will never use (L-034). Per-repo patterns live in
  `.gibson/ux-surface.conf`; the defaults assume a conventional `app/`
  `components/` `public/` layout. If the script is not vendored, CI assumes UI.
- **`ci/ux-eval.yml`, `ci/security.yml`** — when a PR *does* touch a user-visible
  surface and no preview resolves, the job now **fails** instead of setting
  `skip=1` and reporting green. That silent skip took UX, ZAP, and the posture
  probe out of two Tier-B merges (L-012). `ux-eval` also annotates any run where
  the contract flows did not execute, so a hard-fail promotion cannot be closed on
  a path CI never ran (L-011).
- **`scripts/preview-url.sh`** — only accepts a deployment whose status is
  `success` (no more grading a still-building deployment), defaults to a 300s
  timeout under `CI`, and adds `--bypass` (uses `VERCEL_AUTOMATION_BYPASS_SECRET`
  for protected previews) and `--probe` (a 401/403 is reported as protection, not
  returned as a working URL).
- **Docs:** `docs/13-adoption.md` gains the preview-access secrets and the rule that
  a hard-fail promotion is unproven until the path has executed once.
- **Migration:** repos with protected previews **must** add
  `VERCEL_AUTOMATION_BYPASS_SECRET` or their UI PRs will now go red where they
  previously went green-by-skipping. That is the intended change, but it is not
  silent — set the secret and vendor `ux-surface.sh` in the same PR.

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
