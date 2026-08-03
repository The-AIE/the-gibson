---
name: gibson-setup
description: "Wire a repository for autonomous fleet development: install the Gibson guardrail bundle (AGENTS section, CI gates, labels, branch protection, kill switch) and connect the Devin cloud supervisor as merge captain. Consumes gibson-audit's gap list; idempotent. Third stage of the /gibson pipeline; also standalone ('set up this repo for the fleet', 'gibson-ify this repo', 'install the guardrails')."
---

# gibson-setup — teeth, not just prose

An `AGENTS.md` alone is policy in prose; agents drift from it and nothing
notices. This skill installs the ENFORCEMENT bundle so the rules are checked by
machines. Source of truth: `templates/target-repo/` in the Gibson clone (currently thin —
one file — plus the `ci/` workflows; be honest about that). When a target repo
needs something the templates lack, write it for the target, then contribute
the generalized version back to the Gibson **via a normal worktree branch + PR
(Law 3: never edit the canonical clone directly)** so the next repo gets it
for free.

## Install checklist (drive from the audit's gap list; skip what exists)

1. **AGENTS section** — append `templates/target-repo/AGENTS-section.md` to the
   target's `AGENTS.md` (create if absent). Never overwrite existing content.
2. **CI gates** — test/lint/typecheck/build on every PR, as required checks.
   Reuse the repo's existing CI if present; add the missing jobs only.
   **Verify every referenced script actually exists in the TARGET repo before
   installing any workflow from `ci/`.** `ci/gibson-gate.yml` runs
   `node scripts/check-active-work.mjs` (claim isolation, issue #55) and the
   protected **test-integrity** four-job path (issue #70) that grades with the
   merge-base copy of `scripts/test-integrity.mjs` only. Vendor **both** scripts
   into the target alongside the workflow. Calibrate `<generate>`/`<typecheck>`/
   `<lint>`/`<test>`/`<build>` **and** set `TEST_COMMAND` on both
   `test-integrity-base` and `test-integrity-head` to the same literal as the
   gate test step — never read PR-head `.agents/gate.json` for capture.
   Claim isolation needs `fetch-depth: 0` on the green-gate job.
   Anything the workflow references that you have not vendored must be vendored,
   stubbed, or trimmed — a missing script fails every PR with module-not-found.
   **Install ≠ protect:** copying `gibson-gate.yml` is inert until the owner
   makes `test-integrity` a required check and runs the #68 canaries (no-change
   pass, deletion/skip/hostile-helper/failing-base/missing-artifact fails, exact
   waiver pass, workflow-file modification protection). Branch protection,
   rulesets, fork policy, merge-queue policy, and credentials are owner Ask
   Contract items under #68 — never agent-applied. Merge queues stay off until
   equivalent `merge_group` support is implemented and canaried.
   **Sense before promising:** run
   `scripts/git-configure.sh --audit --repo owner/name --path <target>` and
   **stop setup on unresolved FAIL/OWNER_REQUIRED/UNKNOWN** (exit 1) or tool
   failure (exit 3). Safe reversible adoption settings only:
   `git-configure.sh --dry-run` then `--apply` (labels, `gibson/` gitignore,
   squash + delete-branch-on-merge). Static workflow strings never clear the
   test-integrity canary to PASS.
3. **Risk classifier** — Tier-C auto-labeling for ALL Law 7 categories: money,
   auth, consent/PII, security boundaries, production data (schema/migrations
   included). Start from the Gibson's own `ci/` workflows; where a needed gate
   has no template yet, port the concept from a proven external implementation
   (e.g. conference-os's risk classifier — lives in that repo, not this one)
   and contribute the generalized version back via PR (see rule below).
4. **Review-evidence gate** — PRs need independent review evidence before
   merge; owner attestation path for humans; trusted-provider list for bots
   (Devin's App belongs here IF the owner approves — that file is a security
   boundary, adding to it is always an explicit owner decision, never implied).
   **No local template for this exists yet** — port it from a proven external
   implementation and contribute the generalized version back (rule below).
   Until installed, say plainly the repo has no machine-checked review gate.
5. **Labels + kill switch + safe git settings** — prefer
   `scripts/git-configure.sh --apply` after audit/dry-run for
   `tier-a`/`tier-b`/`tier-c`, `agent-claimed`, `blocked`, `gibson-halt`,
   `halt`, a `gibson/` `.gitignore` entry, and merge defaults (squash on;
   merge-commit/rebase off; delete-branch-on-merge on). The permanent stop is
   the `gibson/HALT` file; `GIBSON_HALT=1` is also checked unconditionally every
   iteration. The `gibson-halt` label is only a SOFT cue — `loop.sh` honors it
   when `gh` is installed and authenticated on the machine running the loop, and
   silently ignores it otherwise. Either also install the small translation
   workflow (label applied → touch `gibson/HALT`) or state plainly that on a box
   without `gh` the label stops nothing and humans must create the HALT file to
   actually stop the fleet.
6. **Branch protection** — required checks + no force-push on the default
   branch. Needs owner-level auth; if unavailable, emit the exact settings as
   an Ask Contract item instead of failing silently. `git-configure.sh` **audits**
   protection and prints remediation; it never applies it (use
   `scripts/delivery-control/apply-branch-protection.sh` with Mark approval).
7. **DCO/sign-off** convention if the repo wants it (audit via git-configure;
   app install remains Mark-owned).
8. **Devin supervisor wiring** — `scripts/devin-supervisor.sh ensure --repo <path>`
   **creates a billed cloud session if none exists (ACUs = real money): this is
   an owner-gated step, always. Ask Contract first, run only on an explicit
   yes** (needs `DEVIN_API_KEY`; set `DEVIN_MAX_ACU` as the cap). Optional
   webhook wake per `adapters/devin/README.md`. Devin = merge captain: reviews
   finished branches and owns PRs; it merges only in the explicit `--merge`
   handoff mode (docs/22) — the default leaves every merge to a human. Tier C
   ends at the human gate in every mode (Law 7).

## Rules

- **Idempotent**: re-running against an already-wired repo changes nothing and
  says so. Diff-then-write, never blind-write.
- **Right-sized, never under-gated**: install the lean baseline everywhere; add
  the heavy machinery where the audit found risk surfaces. But Law 7 is not
  profile-dependent — if ANY money/auth/consent/PII/security/prod-data surface
  exists, its human merge gate gets wired regardless of chosen profile. A
  static brochure site with a contact form still has a PII surface.
- Every owner-credential step (branch protection, App installs, API keys) is an
  Ask Contract item — batched, never a drip.
- Commit the wiring via a normal PR to the target repo, reviewed cross-vendor
  like any other change. Setup is not exempt from the rules it installs.
