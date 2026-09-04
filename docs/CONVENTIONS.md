---
title: "Conventions"
nav_exclude: true
---

# The Gibson — Code & Doc Conventions


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

**Status:** Adopted 2026-08-12 (#190). Retrofit batches in the appendix are dispatched separately; a rule is enforced only after its named batch and sensor merge.
**Audience:** Every agent and human changing this repo. Written to be executable by a smaller model: each rule states the target requirement and the existing in-repo pattern to copy; the appendix routes enforcement work and owner decisions.
**Origin:** 2026-08-12 three-lens quality review (scripts A−, doc-system B−, CI/templates/security B−). The repo's defining defect is its own lesson system pointed inward: lessons get filed with discipline but are not consistently applied to Gibson's shipped artifacts. The review found missing concurrency controls in shipped CI templates and silent-skip patterns in `ci/security.yml` and `ci/ux-eval.yml`. Flagship files (`ci/gibson-gate.yml`, `scripts/tests/run-all.sh`, `scripts/formal-review.sh`, `docs/05-concurrency.md`) already demonstrate parts of the target; these conventions make those patterns the floor.

Counts and violations described as "today" are the review snapshot, not a live inventory. The named sensors and open batch issues are the live source of truth as the retrofit lands.

**Prime directive:** When this document names a canonical idiom, home, or helper, use it. If it can't do the job, stop and flag — don't invent a parallel one.

**Meta-rule (the lesson loop closes here):** A lesson's `Status` may not be `fixed` unless Gibson's **own shipped artifacts** (`scripts/`, `ci/`, `templates/`, `adapters/`, playbooks) reflect it. A fix that landed only in a target repo is `fix-pending (issue #N)`, where the issue tracks the harness-side work. This one rule would have prevented the two worst findings of this review.

---

## 1. Shell scripts (`scripts/`, `adapters/`)

- **1.1 Strict-mode table.** Production scripts: `set -euo pipefail`. Sensor/reporting scripts that must survive failing probes: `set -uo pipefail` with a header comment saying why `-e` is omitted. Test suites: `set -uo pipefail`. Sourced libraries: no `set`, header states "never exits on the caller's behalf" (copy `scripts/silent-noop.sh`).
- **1.2 Lint scope is everything executable.** `scripts/tests/run-all.sh` must lint both `scripts/` and `adapters/`, and new executable directories must join that one lint path rather than add a parallel lint. **Current state:** `adapters/` is not yet included; Batch B owns the retrofit and sensor.
- **1.3 Bash 3.2 is enforced by grep, not just `bash -n`.** Sensor fails on non-comment `mapfile|readarray|declare -A|${var^^}|${var,,}|&>>` in any `.sh`. (`bash -n` parses `mapfile` fine and fails only at runtime — the Docker 3.2 check gives false assurance for this class.) Known review-snapshot violation: `scripts/delivery-control/lib.sh`.
- **1.4 One `SCRIPT_DIR` idiom:** `SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)`. Batch B's sensor rejects other spellings.
- **1.5 Logs to stderr, data to stdout.** `info()`/`warn()`/`die()` bodies must redirect to `>&2`. Known review-snapshot violation: the `info()` function in `scripts/claim.sh` writes to stdout and pollutes pipes.
- **1.6 Preflight external tools.** Any script invoking `jq`/`gh`/`node`/`python3` carries a `need_cmd` (extract the helper from `scripts/delivery-control/lib.sh` into the planned *scripts/lib/common.sh*) or `command -v` guard with an install hint (copy `scripts/loop.sh`'s `require_python3`). Version-sensitive tools state a minimum (the jq ≥1.6 check exists because #91 failed *open* on jq-1.6).
- **1.7 Keep what's already right:** GNU-then-BSD fallback ordering with a comment (copy the platform fallback block in `scripts/gate.sh`), `eval` only inside subshell isolation boundaries with the standing comment, capture-or-empty `|| true` idioms, zero `sed -i`/`grep -P`/`readlink -f`, no absolute `/Users/` paths (existing tests already forbid them).

## 2. Node scripts (`scripts/*.mjs`)

- **2.1 Arg parsing fails loud.** Ordinary `.mjs` CLIs use the planned shared helper *scripts/lib/args.mjs* (generalize `scripts/test-integrity.mjs`'s `readFlag()`). A specialized validator may retain a local parser only when it is explicitly allowlisted and meets the same contract: unknown `--flag` → `unknown flag:` or `unknown option:` + exit 2; missing values produce a usage error, never a raw Node stack trace; no unbounded `argv[++i]`. At the review snapshot, `scripts/route-inventory.mjs` — wired into the shipped security gate — silently scanned cwd on a typo'd `--root`.
- **2.2 Enum-valued flags reject unknown values** rather than falling back to a default (the `--trusted-source` fallback in `scripts/test-integrity.mjs` is the review-snapshot counterexample).
- **2.3 Sensor target:** a suite asserts every `.mjs` CLI exits 2 on `--definitely-not-a-flag`. New `.mjs` files ship with at least a smoke test; none may be referenced by shipped CI while having zero coverage. Batch B owns this sensor and the initial `scripts/route-inventory.mjs` / `scripts/decompose-lint.mjs` smoke tests.

## 3. GitHub Actions — `ci/` templates and `.github/workflows/`

`ci/gibson-gate.yml` is the reference for the rules it already demonstrates. Batch A brings the other four `ci/` templates up to the complete contract; `.github/workflows/gibson-self-gate.yml` is a separate self-adoption surface.

- **3.1 SHA-pin every action:** `uses: owner/action@<40-char-sha> # vX.Y.Z`. No mutable tags. The review snapshot found mutable references, including `semgrep/semgrep-action@v1` on a write-capable job. Batch A adds the sensor over workflow YAML.
- **3.2 Every workflow declares `permissions:`** — prefer `permissions: {}` at workflow level + per-job grants. At the review snapshot, `ci/schema-guard.yml` has none and `ci/security.yml`, `ci/ux-eval.yml`, and `ci/retro.yml` grant workflow-wide permissions that only one job needs.
- **3.3 PR-triggered workflows get `concurrency` + `cancel-in-progress: true`** unless annotated `# gibson:stateful-ci`. **Current state:** shipped templates do not yet meet this target; Batch A owns the retrofit and sensor.
- **3.4 Untrusted-input allowlist:** only `*.sha`, `*.number`, `github.repository`, `github.run_id`, `github.run_attempt` may appear in `run:` blocks; everything else goes through `env:`. `pull_request_target` is forbidden without an inline `# gibson:approved-pr-target <issue>` waiver. **Enforcement:** Batch A's sensor, once merged.
- **3.5 Skipped must never look like passed:** any `continue-on-error: true` step or graceful-skip `exit 0` branch must emit `::warning::`/`::notice::` and a `$GITHUB_STEP_SUMMARY` line in the same step — copy the quarantine burn-down pattern from `scripts/tests/run-all.sh`. The review snapshot found silent sites in `ci/security.yml` and `ci/ux-eval.yml`; Batch A owns the fixes and sensor.
- **3.6 Repo-wide bans run on every PR.** A step that greps the whole tree (schema-guard's `--accept-data-loss` ban) may not live behind `paths:` filters — a PR outside the filter can otherwise skip it. The path-independent trigger comment in `ci/gibson-gate.yml` states the pattern; Batch A repairs schema-guard.
- **3.7 Templates carry no operator literals** — no `reviewerLogin: "mrhinkle"`, home paths, or real hostnames; placeholders only. Sensor greps `templates/` and `ci/`.
- **3.8 Template versioning:** every file adopters `cp` carries `# gibson-template-version: <sha>`, and a drift script compares an adopter's copies against `ci/*`. **Current state:** this is a Batch A target, not yet live on `main`.
- **3.9 Gibson runs its own templates.** The repo ships gitleaks/SAST/SCA/test-integrity to adopters and runs none of them on itself; `.github/workflows/gibson-self-gate.yml` uses mutable `@v4` actions its own target contract forbids. Self-adoption scope is a judgment call — the pinning fix is not.

## 4. Secrets & tokens

`scripts/formal-review.sh` is the reference: env-only, never argv, never echoed, hard-refuse if unset, `unset GITHUB_TOKEN` against fallback, identity proven without printing.

- **4.1 No secret in argv.** Ban `curl -H "Authorization: ...$VAR"` (use `--header @file` or `-K -` on stdin) and tokens in `git remote add` URLs (use `git -c http.extraheader=` or `GIT_ASKPASS`; the URL form writes the token to `.git/config` and `ps`). The review snapshot found sites in `scripts/devin-supervisor.sh`, `scripts/deploy-audit.sh`, and `ci/gibson-gate.yml`; Batch D owns these security-sensitive repairs.
- **4.2 Bypass secrets never ride in URLs that reach artifacts.** `scripts/preview-url.sh` returns URL and bypass token separately (header, not query param); `::add-mask::` masks logs only — Playwright/Lighthouse/ZAP reports currently embed the full secret-bearing URL and get uploaded as artifacts. Sensor: `upload-artifact` may not co-occur with an output derived from `scripts/preview-url.sh --bypass`.
- **4.3 Key-bearing templates carry hygiene instructions.** Any plist/env template with `*_API_KEY`/`*_TOKEN`/`*_WEBHOOK_URL` includes `chmod 600` in its install steps. Batch A applies that requirement to `adapters/devin/com.gibson.loop.plist` and sets `KeepAlive` to `{SuccessfulExit: false}` so the documented HALT stops the loop instead of respawning it.

## 5. Gate & control plane

- **5.1 The protected-path list must include the gate itself:** `.github/workflows/**`, `scripts/test-integrity.mjs`, and `scripts/check-active-work.mjs` join the existing `protected_path()` case lists in `scripts/repo-boundary-guard.sh` and `scripts/loop.sh`. **Current state:** those entries are absent; Batch D owns the security-sensitive repair.
- **5.2 Those two duplicated lists get single-sourced** (one generated from the other, or a sensor asserting equality) — they will drift otherwise.
- **5.3 Say what test-integrity is.** It's a disclosure gate, not a prevention gate: the waiver is agent-authored PR-body text and nothing requires human approval when one is present. State this plainly in `docs/06-quality-gates.md` so adopters don't over-trust it. Whether waivers should require human ack is a policy decision (judgment).
- **5.4 The two `TEST_COMMAND` environment copies** in `ci/gibson-gate.yml` get a mechanical equality check against the template's test command so a miscalibrated install cannot silently grade against a weaker suite.

## 6. The documentation system

Markdown is this repo's code. It gets sensors like code does. At the review snapshot, the script harness had extensive executable coverage and no equivalent documentation-sensor suite.

- **6.1 Canonical statements.** Every load-bearing mechanic has exactly one canonical home marked `> **Canonical statement.** Other docs link here; they do not restate this.` (copy the marker in `VIBECODING.md`). First assignments: the **kill switch** (`GUIDE.md` and `docs/16-nontechnical-operation.md` need one owner-approved wording), the **claim mechanism** (target-repo claim files follow the allowed `docs/claims/*` pattern; `AGENTS.md`, `playbooks/builder.md`, `QUICKSTART.md`, and `templates/target-repo/AGENTS-section.md` must link to one canonical statement), **Tier C's definition**, and the **green-gate sequence**.
- **6.2 Deprecated-mechanism list.** A checked-in `.gibson-deprecated` file of `pattern → replacement + lesson`, sensor-enforced; first entry `docs/active-work.md` → `docs/claims/issue-<N>-<slug>.md` (L-023), with `docs/05-concurrency.md` and legacy-read code exempted.
- **6.3 Backtick-path check.** Every `` `docs/…` ``/`playbooks/…`/`scripts/…`/`skills/…`/`templates/…`/`ci/…` path quoted in markdown must exist, with a checked-in allowlist for target-repo paths (`docs/active-work.md`, `docs/claims/*`, `gibson/*`, `local/*`). The review snapshot found stale backticked filenames even though ordinary Markdown links resolved; Batch C fixes them with the sensor.
- **6.4 Index completeness.** `docs/00-INDEX.md` names every `docs/**/*.md`; `playbooks/README.md` every playbook. Stale counts ("the 19 design chapters" — there are 27) die with this sensor.
- **6.5 Loadability budget.** Files in the routine agent load set (`AGENTS.md`, `playbooks/*.md`, `skills/*/SKILL.md`) fail CI over a declared byte budget. The large `memory/LESSONS.md` ledger cannot be a routine mandatory full read without an index (see 7.3). **Live for AGENTS.md (#208):** `scripts/contract-authority.mjs` plus `config/policy/mandatory-read-chain.v1.json` — `AGENTS.md` is the sole always-mandatory human-readable contract; role/job dispatch prompts are conditionally mandatory when dispatched and measured separately; skills remain on-demand.
- **6.6 Adoption checklists install everything the doctrine mandates.** `QUICKSTART.md`'s manual path currently omits `templates/target-repo/MEMORY.md`, which `docs/09-memory-and-self-improvement.md` and `docs/24-agent-memory-conventions.md` make mandatory.

## 7. The lesson ledger (`memory/LESSONS.md`)

- **7.1 Format lint:** heading `^## L-\d{3} · \d{4}-\d{2}-\d{2} · [a-z0-9-]+$`; IDs strictly ascending, newest last; the five spec fields required; `Status` from a closed vocabulary — `fixed | fix-pending (issue #N) | superseded (L-NNN)` — with the parenthetical mandatory on non-`fixed`. The valuable sixth field the newest lessons invented gets legalized as exactly `**General rule:**`. (Today: 9 status spellings, 4 field spellings, ordering violations, and the spec's own example collides with live ID L-047.)
- **7.2 Cited-lesson existence check:** every `L-\d{3}` cited anywhere in the repo must have a heading in the ledger. The review snapshot found cited IDs without headings, including L-009 in claim/release surfaces and L-011 in UX/adoption surfaces. Resolving whether those entries were lost or never written is judgment; detecting missing headings is mechanical.
- **7.3 Generated index target:** *memory/LESSONS-INDEX.md* (ID, date, slug, status, tags; regenerated in CI, diff-checked) becomes the compact entry point that makes `docs/09-memory-and-self-improvement.md`'s promised tag-filtered read real and gives `contract-read-check` something honest to require.
- **7.4 Promotion pressure:** unresolved `fix-pending` lessons stay visible in the generated index. The meta-rule at the top stops "fixed elsewhere" from closing them.
- **7.5 Lint sensor:** `scripts/lesson-ledger-lint.mjs` is the mechanical check for those rules that are already decidable: every `L-NNN` cited under `scripts/`, `ci/`, `docs/`, `playbooks/`, `config/`, `.github/`, `adapters/`, or `templates/` must have a ledger heading; a `fix-pending (issue #N)` status fails when issue N is closed (`gh api`, fail closed unless `--offline`, which skips only that check and says so); a lesson that is not `fixed` fails when a file under `scripts/tests/` names its ID in a pin/regression comment or test name; IDs must be strictly increasing and unique, and every entry must carry `**Status:**` and `**Tags:**`.

## 8. Vendored material (conditional)

- **8.1 Current state:** no `references/` tree exists on `main`. Do not create or repair one merely because this section exists.
- **8.2 If vendored material is proposed:** the same change must add pinned upstream provenance, the applicable license, root `NOTICE` attribution, and a verified checksum manifest. It must state whether any file can execute or make network calls; "inert" is allowed only when executable wiring and operator invocation are both absent.

---

## Appendix: Retrofit batches (lane briefs)

Each batch = one worktree-isolated lane, disjoint file scope, and independent cross-vendor review under `AGENTS.md`. Sensors are the oracle: every batch lands its enforcement sensor in the same PR as the retrofit, so the fix cannot regress.

**Mutation coverage is part of delivering a sensor.** Every sensor ships with planted-violation fixtures it demonstrably fails on — authored by the brief writer, not the implementer, with the verbatim failure lines shown in the report. A sensor that has never been shown to fail is not a sensor; it is a green light wired to nothing. (2026-08-12 review cycle: five of six newly written sensors across two batches passed their suites while structurally unable to fire on the violations they existed to catch.)

**Batch A — CI hardening (§3):** SHA-pin mutable action references; add `permissions:` to schema-guard and narrow workflow-wide grants to per-job; add `concurrency`+`cancel-in-progress` to all shipped templates; make every graceful skip visible; move the destructive-flag ban out from behind path filters; strip the operator literal from the target delivery template; add plist permission/KeepAlive guidance; stamp copied templates and add drift comparison; land mutation-proven sensors for the scoped rules. *Criteria: pin/permissions/concurrency sensors green over `ci/` + `.github/`; zero silent skips.*

**Batch B — script conventions (§1, §2):** widen lint to `adapters/`; add the Bash-4-builtin sensor and rewrite the known `scripts/delivery-control/lib.sh` violation; standardize `SCRIPT_DIR`; fix `scripts/claim.sh` logging; create the planned *scripts/lib/common.sh* and retrofit unguarded tools; create the planned *scripts/lib/args.mjs*, require every `.mjs` CLI to meet the same fail-loud contract, and explicitly document any specialized-parser exception; add unknown-flag and smoke sensors. *Criteria: shellcheck ratchet green with adapters in scope; every `.mjs` CLI rejects unknown flags.*

**Batch C — doc sensors & mechanical drift (§6, §7):** land seven doc sensors (backtick-path check + allowlist, lesson lint, cited-lesson existence, LESSONS-INDEX generator, index completeness, loadability budget, deprecated-mechanism grep); fix purely mechanical drift in claim references, filenames, document counts, adoption steps, and lesson-status spellings. **Excluded:** rewording AGENTS.md Law 2, the kill-switch canonical text, and resolving cited lesson IDs with no ledger heading — those are judgment.

**Batch D — secrets & control plane (§4, §5) — security-sensitive: single senior reviewer, one PR per item:** `preview-url.sh` header-based bypass + artifact sensor; the 3 argv-secret fixes; the git-remote token fix; add the three control-plane protected paths (5.1) and single-source the duplicated lists (5.2); the `TEST_COMMAND` equality check (5.4). Small diffs, big blast radius — review accordingly.

**Batch E — conditional vendoring hygiene (§8):** not dispatchable while `main` has no vendored tree. If vendored material is proposed later, its introducing issue owns provenance, license, attribution, checksums, and an honest execution/network statement in the same reviewed change.

**Not in any batch (judgment-tier, owner decisions):** the kill-switch canonical statement and its propagation; AGENTS.md Law 2 rewording; recovering or renumbering cited lesson IDs with no ledger heading; whether test-integrity waivers require human acknowledgement (5.3); branch protection + CODEOWNERS for `.github/workflows/**` (Batch D's protected-path strings constrain the loop, while branch protection constrains all writers); Gibson self-adopting its shipped security workflows; SECURITY-AUDIT.md refresh; and the LESSONS.md filtered-read doctrine once the index exists.
