---
title: "Conventions"
nav_exclude: true
---

# The Gibson — Code & Doc Conventions

**Status:** Adopted 2026-08-12 (#190). Retrofit batches in the appendix are dispatched as separate issues.
**Audience:** Every agent and human changing this repo. Written to be executable by a smaller model: each rule states the requirement, the existing in-repo pattern to copy, and its enforcement.
**Origin:** 2026-08-12 three-lens quality review (scripts A−, doc-system B−, CI/templates/security B−). The repo's defining defect is its own lesson system pointed inward: lessons get filed with discipline but not applied to Gibson's own shipped artifacts — L-055 is "fixed" in ConferenceOS while none of the 5 shipped CI templates has a `concurrency` block, and L-056's warn-and-skip anti-pattern sits in `ci/security.yml` and `ci/ux-eval.yml` today. The flagship file in each tier (`gibson-gate.yml`, `run-all.sh`, `formal-review.sh`, `docs/05-concurrency.md`) already embodies the right rule; these conventions make the flagship the floor.

**Prime directive:** When this document names a canonical idiom, home, or helper, use it. If it can't do the job, stop and flag — don't invent a parallel one.

**Meta-rule (the lesson loop closes here):** A lesson's `Status` may not be `fixed` unless Gibson's **own shipped artifacts** (`scripts/`, `ci/`, `templates/`, `adapters/`, playbooks) reflect it. A fix that landed only in a target repo is `fix-pending (harness: issue #N)`. This one rule would have prevented the two worst findings of this review.

---

## 1. Shell scripts (`scripts/`, `adapters/`)

- **1.1 Strict-mode table.** Production scripts: `set -euo pipefail`. Sensor/reporting scripts that must survive failing probes: `set -uo pipefail` with a header comment saying why `-e` is omitted. Test suites: `set -uo pipefail` (already 26/26). Sourced libraries: no `set`, header states "never exits on the caller's behalf" (copy `silent-noop.sh`).
- **1.2 Lint scope is everything executable.** `run-all.sh` lints `find scripts adapters …` — not just `scripts/`. New executable directories join the find, never a parallel lint.
- **1.3 Bash 3.2 is enforced by grep, not just `bash -n`.** Sensor fails on non-comment `mapfile|readarray|declare -A|${var^^}|${var,,}|&>>` in any `.sh`. (`bash -n` parses `mapfile` fine and fails only at runtime — the Docker 3.2 check gives false assurance for this class.) Known violation to fix: `delivery-control/lib.sh:52`.
- **1.4 One `SCRIPT_DIR` idiom:** `SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)`. Sensor rejects the other spellings (22 sites, 3 variants today).
- **1.5 Logs to stderr, data to stdout.** `info()`/`warn()`/`die()` bodies must redirect to `>&2`. Known violation: `claim.sh:87` writes to stdout and pollutes pipes.
- **1.6 Preflight external tools.** Any script invoking `jq`/`gh`/`node`/`python3` carries a `need_cmd` (extract `delivery-control/lib.sh:6-11` into `scripts/lib/common.sh`) or `command -v` guard with an install hint (copy `loop.sh`'s `require_python3`). Version-sensitive tools state a minimum (the jq ≥1.6 check exists because #91 failed *open* on jq-1.6).
- **1.7 Keep what's already right:** GNU-then-BSD fallback ordering with a comment (`gate.sh:100` is the template), `eval` only inside subshell isolation boundaries with the standing comment, capture-or-empty `|| true` idioms, zero `sed -i`/`grep -P`/`readlink -f`, no absolute `/Users/` paths (tests already forbid them).

## 2. Node scripts (`scripts/*.mjs`)

- **2.1 Arg parsing fails loud.** Every `.mjs` uses a shared `scripts/lib/args.mjs` (generalize `test-integrity.mjs`'s `readFlag()`): unknown `--flag` → `unknown flag: X` + exit 2; missing value after a flag → usage error, never a raw Node stack trace; no unbounded `argv[++i]` (14 sites today, and `route-inventory.mjs` — wired into the shipped security gate — silently scans cwd on a typo'd `--root`).
- **2.2 Enum-valued flags reject unknown values** rather than falling back to a default (`test-integrity.mjs:1029`'s `--trusted-source` fallback is the counterexample).
- **2.3 Sensor:** a suite asserts every `.mjs` exits 2 on `--definitely-not-a-flag`. New `.mjs` files ship with at least a smoke test; none may be referenced by shipped CI while having zero coverage (`route-inventory.mjs`, `decompose-lint.mjs` today).

## 3. GitHub Actions — `ci/` templates and `.github/workflows/`

`ci/gibson-gate.yml` is the reference file. Every rule below is something it already does; the other five workflows are brought up to it.

- **3.1 SHA-pin every action:** `uses: owner/action@<40-char-sha> # vX.Y.Z`. No mutable tags (22 violations today; `semgrep/semgrep-action@v1` with `pull-requests: write` is the worst). Sensor: regex over `**/*.yml`.
- **3.2 Every workflow declares `permissions:`** — prefer `permissions: {}` at workflow level + per-job grants. `schema-guard.yml` has none at all; `security.yml`/`ux-eval.yml`/`retro.yml` grant workflow-wide what only one job needs.
- **3.3 PR-triggered workflows get `concurrency` + `cancel-in-progress: true`** unless annotated `# gibson:stateful-ci`. This is L-055, applied at home (0 of 5 shipped templates have it).
- **3.4 Untrusted-input allowlist:** only `*.sha`, `*.number`, `github.repository`, `github.run_id`, `github.run_attempt` may appear in `run:` blocks; everything else goes through `env:`. Currently 0 violations — the sensor keeps it 0. `pull_request_target` forbidden without an inline `# gibson:approved-pr-target <issue>` waiver.
- **3.5 Skipped must never look like passed** (L-056, made mechanical): any `continue-on-error: true` step or graceful-skip `exit 0` branch must emit `::warning::`/`::notice::` and a `$GITHUB_STEP_SUMMARY` line in the same step — copy the quarantine burn-down pattern from `run-all.sh`. Five silent sites in `security.yml`/`ux-eval.yml` today.
- **3.6 Repo-wide bans run on every PR.** A step that greps the whole tree (schema-guard's `--accept-data-loss` ban) may not live behind `paths:` filters — a PR touching only `package.json` skips it today. `gibson-gate.yml:21` states the doctrine; schema-guard violates it.
- **3.7 Templates carry no operator literals** — no `reviewerLogin: "mrhinkle"`, home paths, or real hostnames; placeholders only. Sensor greps `templates/` and `ci/`.
- **3.8 Template versioning:** every file adopters `cp` carries `# gibson-template-version: <sha>`, and a `gibson-drift` script compares an adopter's copies against `ci/*`. Without this, no lesson fix ever propagates (the L-055 gap is structural, not one-off).
- **3.9 Gibson runs its own templates.** The repo ships gitleaks/SAST/SCA/test-integrity to adopters and runs none of them on itself; `gibson-self-gate.yml` uses the unpinned `@v4` actions its own template forbids. Self-adoption scope is a judgment call — the pinning fix is not.

## 4. Secrets & tokens

`formal-review.sh` is the reference: env-only, never argv, never echoed, hard-refuse if unset, `unset GITHUB_TOKEN` against fallback, identity proven without printing.

- **4.1 No secret in argv.** Ban `curl -H "Authorization: ...$VAR"` (use `--header @file` or `-K -` on stdin) and tokens in `git remote add` URLs (use `git -c http.extraheader=` or `GIT_ASKPASS`; the URL form writes the token to `.git/config` and `ps`). Three sites today: `devin-supervisor.sh:390,394`, `deploy-audit.sh:82`, `gibson-gate.yml:140,148`.
- **4.2 Bypass secrets never ride in URLs that reach artifacts.** `preview-url.sh` returns URL and bypass token separately (header, not query param); `::add-mask::` masks logs only — Playwright/Lighthouse/ZAP reports currently embed the full secret-bearing URL and get uploaded as artifacts. Sensor: `upload-artifact` may not co-occur with an output derived from `preview-url.sh --bypass`.
- **4.3 Key-bearing templates carry hygiene instructions.** Any plist/env template with `*_API_KEY`/`*_TOKEN`/`*_WEBHOOK_URL` includes `chmod 600` in its install steps (`adapters/devin/com.gibson.loop.plist` today). Same file: `KeepAlive` should be `{SuccessfulExit: false}` so the documented HALT actually stops the loop instead of respawning it every ~10s.

## 5. Gate & control plane

- **5.1 The protected-path list includes the gate itself:** `.github/workflows/**`, `scripts/test-integrity.mjs`, `scripts/check-active-work.mjs` join the `protected_path()` case lists. Today a PR can rewrite the `test-integrity` job to `exit 0` and the required check goes green — the single worst finding of this review, and a three-string fix to a list that already exists (`repo-boundary-guard.sh:59-66`, `loop.sh:571-580`).
- **5.2 Those two duplicated lists get single-sourced** (one generated from the other, or a sensor asserting equality) — they will drift otherwise.
- **5.3 Say what test-integrity is.** It's a disclosure gate, not a prevention gate: the waiver is agent-authored PR-body text and nothing requires human approval when one is present. State this plainly in `docs/06-quality-gates.md` so adopters don't over-trust it. Whether waivers should require human ack is a policy decision (judgment).
- **5.4 The three hand-copied `TEST_COMMAND` literals** in `gibson-gate.yml` (lines 60/283/352) get a mechanical equality check so a miscalibrated install can't silently grade against a weaker suite.

## 6. The documentation system

Markdown is this repo's code. It gets sensors like code does — today 26 CI suites guard the scripts and zero guard the docs.

- **6.1 Canonical statements.** Every load-bearing mechanic has exactly one canonical home marked `> **Canonical statement.** Other docs link here; they do not restate this.` (the `VIBECODING.md:34` pattern — used exactly once today). First four assignments, because each is currently stated in ≥4 conflicting word-sets: the **kill switch** (the HALT file is the dependable stop; the label is best-effort — `GUIDE.md` and `docs/16` currently invert this), the **claim mechanism** (one file per claim in `docs/claims/`; the `active-work.md` table is deprecated per L-023 — yet `AGENTS.md` Law 2, `builder.md`, `QUICKSTART.md`, and the adopter template all still teach the table), **Tier C's definition** (five word-sets; schema in or out must be decided once), and the **green-gate sequence** (already consistent — protect it).
- **6.2 Deprecated-mechanism list.** A checked-in `.gibson-deprecated` file of `pattern → replacement + lesson`, sensor-enforced; first entry `docs/active-work.md` → `docs/claims/issue-<N>-<slug>.md` (L-023), with `docs/05-concurrency.md` and legacy-read code exempted.
- **6.3 Backtick-path check.** Every `` `docs/…` ``/`playbooks/…`/`scripts/…`/`skills/…`/`templates/…`/`ci/…` path quoted in markdown must exist, with a checked-in allowlist for target-repo paths (`docs/active-work.md`, `docs/claims/*`, `gibson/*`, `local/*`). Markdown links already all resolve — the rot is exclusively in backticked paths (`playbooks/decompose.md`, `docs/20-delivery-control.md`, `docs/GOOSE-FLEET-REEVALUATION.md` today).
- **6.4 Index completeness.** `docs/00-INDEX.md` names every `docs/**/*.md`; `playbooks/README.md` every playbook. Stale counts ("the 19 design chapters" — there are 27) die with this sensor.
- **6.5 Loadability budget.** Files in the routine agent load set (`AGENTS.md`, `playbooks/*.md`, `skills/*/SKILL.md`) fail CI over a declared byte budget (~12KB). `memory/LESSONS.md` at 74KB cannot be a Law-1 mandatory read without an index (see 7.3).
- **6.6 Adoption checklists install everything the doctrine mandates.** QUICKSTART's manual path currently omits `templates/target-repo/MEMORY.md`, which `docs/09` + `docs/24` make mandatory.

## 7. The lesson ledger (`memory/LESSONS.md`)

- **7.1 Format lint:** heading `^## L-\d{3} · \d{4}-\d{2}-\d{2} · [a-z0-9-]+$`; IDs strictly ascending, newest last; the five spec fields required; `Status` from a closed vocabulary — `fixed | fix-pending (issue #N) | superseded (L-NNN)` — with the parenthetical mandatory on non-`fixed`. The valuable sixth field the newest lessons invented gets legalized as exactly `**General rule:**`. (Today: 9 status spellings, 4 field spellings, ordering violations, and the spec's own example collides with live ID L-047.)
- **7.2 Cited-lesson existence check:** every `L-\d{3}` cited anywhere in the repo must have a heading in the ledger. Eight cited IDs don't exist today, including L-009 (cited by `claim.sh` and `release.md`) and L-011 (cited by `ux-surface.sh` and `docs/13`) — resolving whether those entries were lost or never written is judgment; the 15-line sensor is not.
- **7.3 Generated `memory/LESSONS-INDEX.md`** (ID, date, slug, status, tags; regenerated in CI, diff-checked) — the ~2k-token entry point that makes `docs/09`'s promised "tag-filtered read" real instead of aspirational, and gives `contract-read-check` something honest to require.
- **7.4 Promotion pressure:** 20 of 48 lessons are `fix-pending`. The index makes the burn-down visible; the meta-rule at the top stops "fixed elsewhere" from closing them.

## 8. Vendored material (`references/`)

- **8.1 A vendored tree requires:** a row in `references/README.md` with a 40-char pinned SHA, a vendored `LICENSE*` file (`vercel-optimize` lacks one), an attribution entry in root `NOTICE` (currently 3 lines naming only Gibson), and a `SHA256SUMS` manifest verified in CI so local edits to the 89 `.mjs` files are detectable.
- **8.2 The inertness claim must be true.** `references/README.md:7` says nothing executes; lines 36-42 describe `vercel-optimize` calling the live Vercel API, and 7 files carry the executable bit. Fix the sentence: vendored trees are operator-invoked at most, never auto-triggered (which grep confirms), and say exactly that.

---

## Appendix: Retrofit batches (lane briefs)

Each batch = one worktree-isolated lane, disjoint file scope, cross-vendor review per FLEET.md. Sensors are the oracle: every batch lands its enforcement sensor in the same PR as the retrofit, so the fix can't regress.

**Mutation coverage is part of delivering a sensor.** Every sensor ships with planted-violation fixtures it demonstrably fails on — authored by the brief writer, not the implementer, with the verbatim failure lines shown in the report. A sensor that has never been shown to fail is not a sensor; it is a green light wired to nothing. (2026-08-12 review cycle: five of six newly written sensors across two batches passed their suites while structurally unable to fire on the violations they existed to catch.)

**Batch A — CI hardening (§3):** SHA-pin all 22 tag-pinned actions; add `permissions:` to schema-guard and narrow the workflow-wide grants to per-job; add `concurrency`+`cancel-in-progress` to all 5 templates (closes L-055 at home); add `::warning::` + step-summary lines to the 5 silent-skip sites (closes L-056 at home); move the destructive-flag ban out from behind path filters; strip `reviewerLogin: "mrhinkle"` and add the plist `chmod 600` + `KeepAlive {SuccessfulExit: false}`; stamp `# gibson-template-version:` and add the drift-compare script; land sensors 3.1–3.7. *Criteria: pin/permissions/concurrency sensors green over `ci/` + `.github/`; zero silent skips.*

**Batch B — script conventions (§1, §2):** widen lint to `adapters/`; Bash-4-builtin grep sensor + rewrite `lib.sh:52` as `while read -r`; standardize 22 `SCRIPT_DIR` sites; fix `claim.sh` `info()` to stderr + sensor; extract `scripts/lib/common.sh` (`need_cmd`) and retrofit the 5 unguarded scripts; create `scripts/lib/args.mjs` and retrofit all 9 `.mjs` + the exits-2-on-unknown-flag sensor; smoke tests for `route-inventory.mjs` and `decompose-lint.mjs`. *Criteria: shellcheck ratchet green with adapters in scope; every `.mjs` rejects unknown flags.*

**Batch C — doc sensors & mechanical drift (§6, §7):** land the six doc sensors (backtick-path check + allowlist, lesson lint, cited-lesson existence, LESSONS-INDEX generator, index completeness, loadability budget, deprecated-mechanism grep); fix the purely mechanical drift — builder.md/QUICKSTART/adopter-template claim-table references → `docs/claims/` (per the canonical statement, once §6.1 assigns it), `decompose.md` → `decomposer.md`, doc-count staleness, QUICKSTART's missing `MEMORY.md` step, normalize the 9 status spellings to the closed vocabulary. **Excluded:** rewording AGENTS.md Law 2, the kill-switch canonical text, and resolving the 8 phantom lesson IDs — those are judgment.

**Batch D — secrets & control plane (§4, §5) — security-sensitive: single senior reviewer, one PR per item:** `preview-url.sh` header-based bypass + artifact sensor; the 3 argv-secret fixes; the git-remote token fix; add the three control-plane protected paths (5.1) and single-source the duplicated lists (5.2); the `TEST_COMMAND` equality check (5.4). Small diffs, big blast radius — review accordingly.

**Batch E — vendoring hygiene (§8):** NOTICE attributions; obtain/vendor the missing LICENSE; `SHA256SUMS` + CI verification; correct the inertness sentence.

**Not in any batch (judgment-tier, owner decisions):** the kill-switch canonical statement and its propagation (safety-critical wording — the operator-facing docs currently teach the *less* reliable stop as primary); AGENTS.md Law 2 rewording; recovering or renumbering the 8 phantom lesson IDs; whether test-integrity waivers require human ack (5.3); branch protection + CODEOWNERS for `.github/workflows/**` (the protected-path strings in Batch D stop the loop's own agents; only branch protection stops everyone); Gibson self-adopting its shipped security workflows (F7 scope); SECURITY-AUDIT.md refresh (a week stale, silent on `references/` and the Actions supply chain — the two surfaces that changed most recently); the LESSONS.md filtered-read doctrine once the index exists.
