---
title: "Fleet Lessons"
nav_exclude: true
---

# Fleet Lessons (append-only)

Format: see docs/09. Newest last. Filed by any agent per Law 9; swept weekly by the
historian. These seeds are imported from pre-Gibson history so the fleet starts
with scar tissue, not amnesia.

## L-001 · 2026-07-18 · worktree-isolation-founding-incident
**What happened:** Two sessions edited the same ConferenceOS checkout; one silently
clobbered the other's uncommitted schema work (Broadcast models, `isVendor`,
`smsConsent`); ~75 type errors, recovered only from a stash.
**Root cause:** shared mutable checkout.
**Harness fix:** canonical checkout read-only; all mutation in per-session worktrees
(docs/05 Layer 1).
**Status:** fixed
**Tags:** #concurrency #git

## L-002 · 2026-07 · schema-without-migration-blocks-deploys
**What happened:** A schema edit without a migration file passed CI, then blocked
~20 consecutive production deploys (ConferenceOS #442).
**Root cause:** CI validated code, not migration-history coherence.
**Harness fix:** schema-guard workflow — schema diff without migration file fails
the PR (docs/12).
**Status:** fixed
**Tags:** #schema #ci #vercel

## L-003 · 2026-07-20 · unbounded-coordinator-cost
**What happened:** One 547-message coordinator session cost $119.65 with no
compaction checkpoint; run total $120.68.
**Root cause:** unbounded scope + unbounded context in a metered pool.
**Harness fix:** bounded workers (one issue, exact file list, short output
contract); fresh-context-per-hat; checkpoint before half the window; grind work
routed to flat-rate pools (docs/15).
**Status:** fixed
**Tags:** #cost #routing

## L-004 · 2026-07 · docs-describe-aspiration-not-wiring
**What happened:** RELEASING.md described `release`→prod while Vercel's Production
Branch was `main` — every main merge was a silent prod deploy.
**Root cause:** documentation recorded intent, not verified configuration.
**Harness fix:** adoption audits verify the real Production Branch and write the
truth into the target AGENTS.md (docs/12, docs/13).
**Status:** fixed
**Tags:** #vercel #docs

## L-005 · 2026-07 · reviewer-absence-silently-skips
**What happened:** Mission Control's dispatcher skipped cross-vendor review when the
reviewer CLI was missing (`shutil.which` guard) — good work shipped unreviewed
without anyone deciding that.
**Root cause:** fail-open default on a quality gate.
**Harness fix:** Gibson rule — missing/broken reviewer blocks the merge (docs/06).
**Status:** fix-pending (dispatcher patch — see ROADMAP Phase 2)
**Tags:** #review #fail-closed

## L-006 · 2026-07-24 · doc-backlog-handoff-scope
**What happened:** DOC-BACKLOG P0–P2 handoff executed as focused commits on
`main` per operator instruction, while Law 3 / target-repo rules still say
mutation only in worktrees. Harness self-work on this repo is operator-gated.
**Root cause:** operational contract for *target* repos vs. harness-authoring
workflow were not spelled out as separate lanes.
**Harness fix:** When editing The Gibson itself under an explicit human handoff
to `main`, record it; for product target repos, Law 3 remains absolute. Future:
prefer harness changes via PR + cross-runtime review (D-003) even when the
operator allows direct main for speed.
**Status:** fix-pending (process note; no code gate yet)
**Tags:** #process #gibson #docs

## L-007 · 2026-07-24 · grok-runner-frontmatter-arg-parsing
**What happened:** `scripts/loop.sh`'s grok runner invoked `grok -p "$(cat "$prompt_file")"`.
Rendered playbooks start with YAML frontmatter (`---`), which grok's clap-style
arg parser mis-reads as an unrecognized flag when passed as a value string
rather than a file path — every solo-loop iteration would have failed before
doing any work. Same root cause hit manually during chatterbuilt adoption
(`grok -p "$(cat adopt.md)..."` failed identically; fixed there with
`--prompt-file`).
**Root cause:** passing multi-line, dash-prefixed content as a `-p`/`--single`
argument value instead of via `--prompt-file <path>`.
**Harness fix:** `invoke_runner`'s grok branch now uses `grok --prompt-file
"$prompt_file"`. Untested: whether `claude`/`codex`/`hermes` branches have the
same exposure (same playbook content, different flag conventions) — worth a
dry-run check before relying on them unattended.
**Status:** fixed (grok branch only)
**Tags:** #grok #cli #harness-bug

## L-008 · 2026-07-24 · grok-runner-silent-noop-without-permission-mode
**What happened:** Even after fixing L-007's arg-parsing bug, the solo loop
still burned 100+ iterations against mrhinkle/chatterbuilt with zero real
work — no claim, no worktree, no commit, `gibson/loop-state.md` never
updated. Each iteration returned a shallow one-line paraphrase of its own
instructions in under 10 seconds and exited cleanly (exit 0), so the driver's
error budget never tripped — it looked healthy while doing nothing.
**Root cause:** `invoke_runner`'s grok branch never passed a permission-mode
flag. In headless/non-interactive invocation there's no TTY to approve tool
calls, so grok can't act — it can only narrate. The `claude` branch already
had `--permission-mode acceptEdits`; `codex` had `--full-auto`; grok had
neither.
**Harness fix:** grok branch now passes `--permission-mode bypassPermissions`.
**Detection gap this exposes:** exit-code-based error budgets don't catch
"ran fine, did nothing" — only "crashed." A stronger sensor is required: if
`gibson/loop-state.md` has no *substantive* change after N exit-0 iterations
(clock-only `updated:` rewrites do not count — a clock is not progress), treat
that as failure too.
**Detection-gap status (issue #63):** implemented. `scripts/silent-noop.sh`
exposes `silent_noop_progressed BEFORE AFTER` (substantive fingerprint; excludes
only column-zero `updated:`). `scripts/loop.sh` runs it after #75 schema +
freshness pass and runner exit 0, comparing the exact pre-run snapshot to live
state. No-progress journals once, increments shared failure and `--stale-budget`
once each, never restores or hands off. state-corrupt and runner-failure take
precedence and do not run the sensor. Stop at the earlier of error-budget or
stale-budget with a distinct no-progress diagnosis.
**Status:** fixed (grok branch + detection gap via #63)
**Tags:** #grok #cli #harness-bug #permissions #L-008 #silent-noop

## L-009 · 2026-09-04 · claim-commit-never-moves-caller-checkout
**What happened:** Claim and release-claim used to mutate the claim ledger by
checking out `main` in the caller's tree. A dirty long-lived feature branch
then stranded the claim row or moved the operator's checkout out from under
them.
**Root cause:** Ledger mutation ran in the caller's working copy instead of a
disposable worktree on main.
**Harness fix:** `claim.sh` and `release-claim.sh` commit claim-row changes in
a throwaway worktree; they never move the canonical checkout
(`scripts/release-claim.sh`, `scripts/claim.sh`, `playbooks/release.md`).
**Status:** fixed (reconstructed 2026-09-04 from scripts/release-claim.sh; pinned by scripts/tests/claim.test.sh, scripts/tests/release-claim.test.sh)
**Tags:** #git #claims #worktree #release

## L-010 · 2026-09-04 · dead-agent-must-release-the-lane
**What happened:** A hung or crashed agent can leave a claim, lock, or worktree
held indefinitely; the loop waits for a human to notice rather than reclaiming
the lane.
**Root cause:** Exit paths did not guarantee release of claims, locks, and
worktrees; a dead process kept the lane.
**Harness fix:** `trap EXIT` (and equivalent) must release every claim, lock,
and worktree hold on completion OR failure. A dead agent must never keep a
lane (`docs/liveness-contract.md` clause 6).
**Status:** reconstructed 2026-09-04 from docs/liveness-contract.md
**Tags:** #liveness #claims #concurrency #fail-closed

## L-011 · 2026-09-04 · hard-fail-promotion-unproven-until-path-runs
**What happened:** A Playwright / UX-eval flow was promoted to hard-fail and
the burn-down issue closed while CI skipped the promoted path every run —
static sensors (workflow grep, baseline file) went green without the job ever
executing.
**Root cause:** Promotion and burn-down closure were keyed off config and docs,
not on evidence that the promoted path actually ran in CI.
**Harness fix:** Do not close a burn-down issue or treat a hard-fail promotion
as done until one CI run has executed the promoted path (or an explicit dated
deferral is recorded). `ci/ux-eval.yml` annotates runs where contract flows did
not execute (`docs/13-adoption.md`, `scripts/ux-surface.sh`).
**Status:** reconstructed 2026-09-04 from ci/ux-eval.yml
**Tags:** #ci #ux-eval #fail-closed #adoption

## L-012 · 2026-07-24 · preview-url-ci-skip-under-vercel-protection
**What happened:** On chatterbuilt (and fleet PRs generally), CI jobs
`gibson-ux-eval` / `zap-baseline` / `posture` often SUCCESS via **skip** because
`preview-url.sh` times out (default 180s) or cannot authenticate past Vercel
Deployment Protection SSO — even when a READY branch deploy exists. Observed
from early adoption PRs (#81/#82) through ongoing fleet work including PR #101
security hat (L5/L8 CI skip; prod posture-probe compensated). Live agents
recover with `vercel curl` + protection-bypass outside CI; hard-fail DAST/UX
paths stay unproven in Actions.
**Root cause:** Preview resolution + Deployment Protection not wired for CI
(timeout race; missing `VERCEL_AUTOMATION_BYPASS_SECRET` path); workflows treat
missing BASE_URL as soft skip (annotated) rather than non-pass when Tier B/C
UI/security surface needs a live target.
**Harness fix:** Sensor preferred (the-gibson#2): longer CI timeout; wait for
READY; inject bypass secret; fail/annotate non-pass (not skip-as-green) when
Tier B/C needs preview. Guide: security/ux hats must not claim L5/L8/UX CI
skip as hard-fail pass; compensate with live preview or prod posture when
appropriate. **Do not** loosen Tier C human gates.
**Status:** fix-pending (the-gibson#2)
**Tags:** #ci #preview #vercel #security #ux-eval #local

## L-013 · 2026-07-25 · partial-pr-autoclose-despite-related-only
**What happened:** Multi-phase issues (esp. chatterbuilt #28) auto-close on
partial PR merge even when the PR body uses `Related: #N` / "partial progress"
and deliberately avoids Closes/Fixes/Resolves. Observed on #28 for PRs #52
("Does not close #28"), #83 ("Does not fully resolve #28"), #84 (Related-only
still closed — Development sidebar / keyword linker), and again #100 (phase 5;
squash title `feat(#28):…`; body had explicit L-013 note; still auto-closed;
release reopened). Same class hit other multi-slice issues (#15, #25, #26).
**Root cause:** GitHub's closing keyword linker is brittle (negations not
parsed; "resolve"/"close" near `#N` still match) and Development-sidebar issue
links can close independent of body wording. PR title `feat(#N):` alone is not
enough to explain all cases.
**Harness fix:** (1) Guide — release playbook pre-merge:
`gh pr view N --json closingIssuesReferences` must be `[]` for partial ships;
squash subject/body: Related-only, no close/fix/resolve verbs near `#N`.
(2) Post-merge: if issue closed and PR was partial, reopen + comment residual.
(3) Sensor still fix-pending: release preflight script hard-fails when
`closingIssuesReferences` is non-empty while body marks partial / Related-only.
**Status:** fixed (pinned by scripts/tests/release-preflight.test.sh)
**Tags:** #github #release #partial-ship #process #local

## L-015 · 2026-07-25 · same-author-github-approve-blocked
**What happened:** Solo-loop reviewer (same GitHub account as PR author) cannot
`gh pr review --approve` — GitHub rejects self-approval. PR #100 and prior
chatterbuilt solo PRs used a PR **comment** ending in `VERDICT: APPROVE`
instead. Release accepted that as the formal review signal.
**Root cause:** GitHub policy + solo loop often uses one operator account for
builder and reviewer hats (Law 5 wants a different agent, not always a
different GitHub identity).
**Harness fix:** Guide — reviewer playbook: when `--approve` fails for
same-author, post `gh pr review --comment` with final line exactly
`VERDICT: APPROVE` (or `REQUEST_CHANGES`). Release treats that line as the
merge gate when `reviewDecision` is empty/blocked for same-author. Prefer
`REVIEWER_CMD` cross-vendor when set (true different identity).
**Status:** fixed (pinned by scripts/tests/release-preflight.test.sh)
**Tags:** #review #github #solo-loop #process #general

## L-020 · 2026-07-25 · gh-pr-merge-fails-when-worktree-holds-branch
**What happened:** Release on fleet worktree `wt-mcpknow` (branch
`feat/28-mcp-knowledge-phase5`) could not complete `gh pr merge --squash` —
local `gh` merge path wanted a main checkout the worktree could not provide
(other worktrees / branch already checked out). Squash-merge via GitHub API
succeeded (`6b8d6aa`); DCO/Signed-off-by preserved; remote branch deleted
after.
**Root cause:** `gh pr merge` local merge helpers assume a flexible checkout;
fleet worktrees pin one feature branch and must not checkout main (Law 3 /
multi-worktree safety).
**Harness fix:** Guide — release playbook: if `gh pr merge` fails with
checkout/worktree errors, fall back to API
`gh api repos/{owner}/{repo}/pulls/{n}/merge -f merge_method=squash`
(or equivalent), then verify merge commit on `origin/main`, deploy, smoke.
Do not force-checkout main in a fleet worktree.
**Status:** fix-pending (the-gibson#6; practiced on PR #100; playbook not yet patched)
**Tags:** #release #github #worktree #solo-loop #general

## L-021 · 2026-07-25 · verdict-comment-not-enough-for-branch-protection
**What happened:** chatterbuilt PR #98 (articles lane, fleet wt-articles) had
hard CI green, cross-vendor Claude APPROVE, security CLEAR, UX skip, and a
same-author PR comment ending in `VERDICT: APPROVE` (L-015 workaround). Release
still could not complete a normal non-admin merge: base-branch / required-review
policy + owner cannot `gh pr review --approve` self, compounded by concurrent
fleet merges racing main (required re-sync). Resolved with re-sync then **admin
squash merge** (`3193b28`); issue #23 closed; smoke green.
**Root cause:** GitHub branch protection evaluates formal `reviewDecision`, not
the solo-loop `VERDICT: APPROVE` comment convention. L-015 unblocks *process*
signaling but not GitHub *mergeability* when reviews are required. Fleet
concurrency on `main` is expected and separate (re-sync before merge).
**Harness fix:** (1) Guide — release playbook: when blocked only by missing
formal APPROVED review on same-author PRs, document gates (CI green +
`VERDICT: APPROVE` line + security clear + Tier), then either (a) admin
squash with explicit checklist in the merge comment, or (b) obtain real
`--approve` from a different GitHub identity / `REVIEWER_CMD` that can post
a formal review. (2) Prefer (b) so admin is rare. (3) Always re-sync with
`origin/main` under multi-lane fleet before merge attempts.
**Status:** fix-pending (guide; playbook not yet patched; practiced on PR #98)
**Tags:** #release #github #branch-protection #solo-loop #review #general

## L-022 · 2026-07-25 · gitleaks-security-fast-cross-lane-until-pr-scoped
**What happened:** chatterbuilt fleet PR #96 (autopilot marketing, wt-autopilot)
had CI `security-fast` red for the whole gate path even though `gitleaks` on
`main..HEAD` for that PR was clean. Residual findings were SAMPLE_KEY fixtures
from concurrent #59 (`feat/59-claim-page`), not this PR's introduced risk.
Security hat correctly CLEAR'd PR-introduced risk; release still could not merge
until `origin/main` (gitleaks PR-range scope + AC5 SHA inject) was merged into
the feature branch and the check went green.
**Root cause:** Secret scanners that are not strictly scoped to the PR commit
range (or fleets running branches that predate the scope fix) make one lane's
fixtures fail unrelated lanes' required checks. Cross-lane CI bleed under high
fleet concurrency.
**Harness fix:** Sensor — chatterbuilt `db92db4` / `710e9a7` scope gitleaks to
PR/push commit range and inject SHAs via env. Guide — security + release: (1)
always re-check `gitleaks` on `main..HEAD` for *this* PR before treating
security-fast red as this-lane risk; (2) merge/rebase `origin/main` so CI harness
fixes apply before parking on a red security-fast; (3) do not close or block a
marketing PR solely for out-of-range fixtures on another branch.
**Status:** fixed (sensor on chatterbuilt main; re-sync still operator/release duty)
**Tags:** #security #ci #gitleaks #fleet #concurrency #local

## L-023 · 2026-07-25 · active-work-claim-table-merge-conflicts
**What happened:** Release on PR #96 had to resolve `docs/active-work.md` claim
conflicts when re-syncing with `main`. Multiple concurrent fleet lanes
(issue-59, issue-24, issue-73, issue-15, issue-19, …) each append/remove claim
rows in the same markdown table, so merges of green feature PRs repeatedly
conflict on that one file even when product paths do not overlap.
**Root cause:** A single shared mutable claim ledger is a hot file under max
mutating lanes; table rows are not append-only at the git hunk level.
**Harness fix:** Prefer sensors/process: (1) claim primarily via GitHub
`agent-claimed` label + issue comment; treat `docs/active-work.md` as optional
human dashboard, or (2) per-lane claim snippets under `docs/claims/<lane>.md`
assembled by a script, or (3) release playbook: auto-resolve active-work by
taking union of claim rows and re-running `release-claim.sh` post-merge. Until
then, release may resolve claim-table conflicts only (no product code) when
unblocking an otherwise green merge.
**Status:** fixed (pinned by scripts/tests/claim.test.sh, scripts/tests/release-claim.test.sh)
**Tags:** #concurrency #claims #release #fleet #local

## L-024 · 2026-07-25 · release-claim-wipes-residual-sibling-claims
**What happened:** After chatterbuilt PR #113 (slice-9 magnet → preview-plan)
merged as a Tier B PRE-LAUNCH partial ship, Law 10 cleanup via
`release-claim.sh 15` would have stripped **all** `issue-15-*` claim rows,
removed every `wt-15-*` worktree, and dropped `agent-claimed` from #15 —
including the live residual F1 claim `issue-15-demo-stale-plan-clear`
(PR #115) that another lane had already filed. Release correctly skipped
re-running release-claim (merged slug already gone; residual protected).
#15 stayed OPEN (L-013 Related-only; `closingIssuesReferences: []`).
**Root cause:** `release-claim.sh` keys cleanup on issue number only
(`grep issue-N-`, remove label on #N) and assumes one claim per issue end-of-life.
Multi-slice issues keep residuals under new claim slugs while the parent issue
stays open.
**Harness fix:** (1) Sensor — add `--claim-id`/`--slug` so only that row +
matching worktree/branch are removed; retain `agent-claimed` if any
`issue-N-*` row remains. (2) Guide — release playbook: before cleanup, inspect
`origin/main` claims for residual sibling rows; never blind-run full
`release-claim.sh N` on partial ships. Related L-013 / L-023 / the-gibson#7.
**Status:** fixed (pinned by scripts/tests/claim.test.sh, scripts/tests/release-claim.test.sh)
**Tags:** #release #claims #partial-ship #solo-loop #local #process

## L-025 · 2026-07-25 · conventional-commit-fix-title-autoclose
**What happened:** chatterbuilt PR #115 (partial AC7 stale previewPlan clear)
merged with intended Related-only residual body, but GitHub still populated
`closingIssuesReferences: [#15]` and auto-closed multi-slice issue #15. Release
reopened + residual comment (L-013 recovery path). Title was
`fix(#15): clear stale previewPlan on magnet re-submit (F1)`.
**Root cause:** Conventional-commit PR titles `fix(#N):` / `fixes(#N):` are
GitHub closing keywords. Agents use them by habit for "bugfix" slices even
when the parent issue is multi-phase and must stay open. Related-only body
cannot override a closing-keyword title/link. L-013 already forbids
fix/close/resolve near `#N` for partials; the `fix(#N):` title form is the
highest-frequency miss.
**Harness fix:** (1) Guide — for multi-slice / Related-only PRs never use
`fix|close|resolve|closes|fixes|resolves` in title; prefer
`feat(scope): … (related #N)` or `chore(…): …` without issue-closing keywords.
(2) Sensor (extends the-gibson#4) — release preflight hard-fails when title
matches closing-keyword+#N **or** `closingIssuesReferences` non-empty while
body marks partial/Related-only. (3) Practice — reopen + residual already
proven on #115.
**Status:** fixed (pinned by scripts/tests/release-preflight.test.sh)
**Tags:** #github #release #partial-ship #process #local #conventional-commits

## L-026 · 2026-07-25 · mcp-landing-free-tools-list-lags-entitlements
**What happened:** After chatterbuilt PR #117 merged `set_autopilot` (and earlier
`improve_my_site` from #3), production https://chatterbuilt-mcp.vercel.app/ HTTP 200
and Vercel READY on merge SHA, but the hand-written free-tools list in
`apps/mcp/app/page.tsx` still omitted both tools. Deploy smoke looking only at HTTP
200 + page title would miss product-discoverability drift.
**Root cause:** MCP marketing landing free/licensed tool lists are static JSX, not
derived from `entitlements.ts` FREE_TOOLS (or transport registration). Shipping a new
free tool updates registry + start_here sensors but not the public catalog page.
**Harness fix:** (1) Sensor — unit/snapshot test that every free entitlement tool
appears in page.tsx free list (or generate list from entitlements). (2) Guide —
builder playbook: new free tool → update page.tsx in same PR. (3) Residual noted on
#24 historian cleanup; do not invent standalone Tier-A issue without sprint contract.
**Status:** fixed (chatterbuilt #119 / PR #120 squash fbb002a — `lib/tool-catalog.ts`
derives free/licensed from `toolsForTier`; `tool-catalog.test.ts` + page wiring
sensors; prod smoke 2026-07-25 all L-026 names on chatterbuilt-mcp.vercel.app)
**Tags:** #mcp #docs #deploy-smoke #local #discoverability

## L-027 · 2026-07-25 · release-claim-label-residual-silent-fail
**What happened:** After chatterbuilt PR #117 (set_autopilot product dial)
merged and `release-claim.sh 24` committed bab9878 (claim row gone from
`docs/active-work.md`, worktree/branch gone), the GitHub `agent-claimed`
label remained on #24. Release hat had to re-strip the label manually.
Script log line claimed "removed agent-claimed from #24" even when removal
did not stick.
**Root cause:** `scripts/release-claim.sh` label cleanup is
`gh issue edit … --remove-label agent-claimed 2>/dev/null || true` then
unconditionally logs success. `gh` failures (auth, rate limit, wrong
repo resolution from non-canonical cwd, label already absent vs edit
error) are swallowed; Law 10 label half of cleanup is not verified.
**Harness fix:** (1) Sensor — after label remove, `gh issue view --json
labels` and hard-fail (or non-zero exit) if `agent-claimed` still present
when no residual sibling claim rows remain. (2) Do not swallow `gh` stderr
on label edit; log real error. (3) Guide — release playbook: after
release-claim, re-read issue labels before declaring Law 10 done (release
hat already practiced this on #117). Sibling of L-024 (keep label when
residuals exist) — this is the inverse miss (label left when no residual).
**Status:** fixed (pinned by scripts/tests/release-claim.test.sh)
**Tags:** #release #claims #law-10 #solo-loop #local #process

## L-028 · 2026-07-25 · release-hat-finds-pr-already-merged
**What happened:** On chatterbuilt fleet (suggestq and siblings), release hats
repeatedly arrive after the PR is already squash-merged — PR #113, #117, #120,
and again #128 (#123 preview-url wiring, squash 9aecfe6 @ 09:15:26Z concurrent
with security handoff, merged_by mrhinkle). Release correctly verified gates
post-facto, deploy READY, smoke, and Law 10 (often `release-claim` already on
main) without re-merging. Playbook still documents only the happy path "you
merge" and does not name the already-MERGED branch.
**Root cause:** Multi-lane / human-or-concurrent merge races the solo-loop
security→release handoff; `playbooks/release.md` Stage 7 assumes the hat is
the merger, not a post-merge verifier.
**Harness fix:** (1) Guide — release playbook Stage 7: first check
`gh pr view N --json state,mergedAt,mergeCommit`; if MERGED, skip merge,
verify Closes/closingIssuesReferences + CI on merge SHA + deploy/smoke + Law
10, and **never** re-run destructive cleanup if claim row / worktree / branch
already gone (pair L-024). (2) Optional sensor — loop-state note template for
"post-merge verify only" so historian exhaust is unambiguous. Practiced on
#128; playbook text not yet patched.
**Status:** fixed (pinned by scripts/tests/claim.test.sh)
**Tags:** #release #solo-loop #concurrency #process #general

## L-029 · 2026-07-25 · release-claim-fails-on-fleet-worktree-cwd
**What happened:** After chatterbuilt PR #134 (handyman preset, a0f058b) merged,
release ran Law 10 cleanup from fleet worktree `wt-suggestq` (branch
`feat/26-prepare-agent-suggestion`, not main). `release-claim.sh 131` failed
(pathspec / non-main commit path). Cleanup completed only after re-running from
the product main clone (`/Users/mrhinkle/Code/chatterbuilt` on main → ec7ce3e
stripped issue-131 claim row). Worktree/branch/label cleanup had already
succeeded; the claim-table commit was the half that needed main.
**Root cause:** `scripts/release-claim.sh` defaults `GIBSON_CANONICAL` to `cwd`
and then `git checkout main` with stderr swallowed. Solo-loop release often runs
from a fleet worktree that must not (or cannot) checkout main (Law 3 /
multi-worktree). Script usage docs imply "cd to repo root" without requiring the
**main checkout** or an explicit `GIBSON_CANONICAL` to the product main path.
Sibling of L-020 (merge from worktree) and L-027 (label silent fail) — same
family, different stage (claim-row commit on main).
**Harness fix:** (1) Guide — release playbook: always
`GIBSON_CANONICAL=<product-main-clone> /path/to/release-claim.sh N` (or `cd`
there first); never rely on fleet worktree cwd. (2) Sensor — after the main
checkout attempt, hard-fail if `HEAD` is not `main`/`master` (stop swallowing
checkout errors); prefer refusing to commit claim rows from a non-main branch.
(3) Practice — run claim-table strip from product main when script fails mid-way.
**Status:** fix-pending (guide; practiced on PR #134; sensor not yet)
**Tags:** #release #claims #law-10 #worktree #solo-loop #general #process

## L-030 · 2026-07-25 · versions-pin-thrash-under-concurrent-claims
**What happened:** chatterbuilt PR #135 (digest mapper #132) re-synced
`origin/main` **three times** under strict required checks before squash
merge `5255de5`. Concurrent lanes each bumped the content pin on the same
hot file: #131 handyman → **0.4.28**, #133 landscaping → **0.4.29**, #132
digest mapper finally **0.4.30** (UNIT-132-versions + historical UNIT-131/133
pins). Builder initially soft-coord'd / deferred pin against claim
`issue-131-handyman-preset` on `versions.json`; release still paid triple
CI re-sync cost. Decomposer had serialized #133 behind #131 for
`presets.ts`/`presets.test.ts`/`versions.json`, but left #132 concurrent
despite its versions AC.
**Root cause:** `apps/mcp/content/versions.json` (and pin sensors) is a
fleet-wide serial hotspot. Soft-coord notes in PR bodies do not prevent
overlapping claims when multiple sprint contracts each require a pin.
**Harness fix:** (1) Guide — decomposer: any issue whose AC list requires a
content/versions pin must be **Blocked by** every open claim whose scope
includes `versions.json` (same rule as presets hot files), **or** the pin
AC must be explicitly deferred to a follow-up issue with no product code.
(2) Guide — builder: if `versions.json` is already in another live claim
row, do not expand claim scope onto it mid-flight; re-pin only at release
re-sync with one final bump. (3) Optional sensor — claim/decomposer lint
flags dual live claims that both list `versions.json`.
**Status:** fix-pending (guide; practiced thrice-resync on PR #135; no
sensor yet)
**Tags:** #concurrency #versions #soft-coord #solo-loop #local #release
#decomposition

## L-031 · 2026-07-25 · dual-claim-race-same-open-issue
**What happened:** chatterbuilt #140 was claimed twice within ~30s by concurrent
solo builders: `issue-140-local-findability` @ 11:03:45Z (PR #143 primary) and
`issue-140-local-findability-heuristics` @ 11:04:14Z (PR #142 closed as
duplicate). Both mutated the same paths (`suggest-improvement.ts`/tests). Claim
table briefly held 4 rows (over max 3); orphan heuristics row needed later
cleanup. Release still shipped #143 cleanly (7f432c8); parent #19 stayed OPEN.
**Root cause:** Claim is optimistic append (`docs/active-work.md` row +
`agent-claimed` label) with no exclusive lease. Concurrent fleet sessions can
both see an unclaimed issue, both pass free-slot checks against a stale table,
and both open PRs. Label add is not an atomic mutex.
**Harness fix:** (1) Guide — builder claim protocol: immediately before append,
re-read `gh issue view N --json labels` + `origin/main:docs/active-work.md`;
abort if `agent-claimed` or any `issue-N-*` row exists. (2) Sensor preferred —
claim helper that fails if label already present (or uses a single
compare-and-swap path: comment lease id, then label). (3) Max-lanes: refuse a
4th claim row even when free-slot looked open at start of the race. (4) On
detecting a twin PR for the same issue, close the later PR as duplicate and
drop the orphan claim before release (practiced on #142).
**Status:** fix-pending (guide; practiced dual-PR recovery on #140/#142/#143;
sensor not yet)
**Tags:** #concurrency #claims #solo-loop #fleet #local #process

## L-032 · 2026-07-25 · release-claim-misses-fleet-lane-worktrees
**What happened:** After chatterbuilt PR #144 (articles P2 trades #141, squash
`6436094`) release-claim stripped the claim row (`860457e`) and dropped
`agent-claimed`, but Law 10 worktree cleanup still required a **manual**
`rm` of `/Users/mrhinkle/Code/fleet/wt-articles`. Script only probes
`$(dirname CANONICAL)/wt-${ISSUE}-*` (and `wt-${ISSUE}-${SLUG}`); fleet
lanes live under `Code/fleet/wt-<lane>` with non-issue names (`wt-articles`,
`wt-suggestq`, `wt-mcpknow`, `wt-autopilot`). Journal release step recorded
the miss explicitly.
**Root cause:** Two worktree conventions in parallel — Gibson
`claim.sh`/`release-claim.sh` (`../wt-<issue>-<slug>` next to product clone)
vs fleet lane directories (`Code/fleet/wt-<lane>`). release-claim has no
knowledge of the fleet root or the absolute path used at claim time.
**Harness fix:** (1) Guide — release playbook Law 10: after release-claim,
verify the worktree path recorded in claim/session notes (or scan
`$FLEET_ROOT/wt-*` / known fleet dir) and remove leftovers; do not treat
script exit 0 alone as worktree-clean. (2) Sensor preferred — claim row or
loop-state records absolute `worktree:` path; `release-claim.sh` accepts
`--worktree` / reads it and removes that path too. (3) Long-term: one
naming convention (issue-slug under fleet root, or always via claim.sh).
**Status:** fix-pending (guide practiced on PR #144; sensor not yet)
**Tags:** #release #claims #law-10 #fleet #worktree #solo-loop #local #process

## L-033 · 2026-07-25 · gha-startup-failure-not-product-red
**What happened:** chatterbuilt PR #154 (weekly_site_digest pendingSuggestions,
#151, Tier A) had local apps/mcp gate fully GREEN (tsc + lint + 578 tests +
build) and local gitleaks clean, plus VERDICT: APPROVE (L-015) and security
CLEAR. Required remote GHA workflows (gate / security-fast / ux / security)
stuck in fleet-wide `startup_failure` — empty steps, empty `runner_name`,
re-runs failed the same way on this PR and concurrent #148 / #59. Product
risk was not indicated; infra never scheduled a runner. Release admin
squash-merged under PRE-LAUNCH (L-021 path + `enforce_admins=false`) →
`0097222`; Vercel SUCCESS; smoke + posture GREEN; Law 10 cleanup clean.
Parent #18 stayed OPEN (L-013 Closes #151 only).
**Root cause:** GitHub Actions runner/infra outages surface as red required
checks (`startup_failure`) with no job log. Release doctrine ("wait for CI
green") does not distinguish infra startup failure from a real product gate
red, so solo release either deadlocks or invents an ad-hoc admin path without
a named checklist.
**Harness fix:** (1) Guide — release playbook: classify required-check reds —
if conclusion is `startup_failure` / jobs show empty steps / empty runner and
the same pattern is concurrent across multiple open PRs, treat as **infra**,
not product. Under **PRE-LAUNCH** only: after re-run once fails the same way,
admin-merge is allowed when **all** of: local full gate green on the merge
SHA/branch tip, VERDICT APPROVE (or formal review), security CLEAR, Tier A/B
(not Tier C human gate), and an explicit release comment listing the infra
evidence + checklist. (2) Do **not** claim remote CI green when it was not —
name the skip. (3) At launch: this path is human-gated; no auto-admin on any
CI red. (4) Prefer sensor later — release preflight script flags
startup_failure vs failed step so the hat does not re-diagnose from UI.
**Status:** fixed (pinned by scripts/tests/release-preflight.test.sh)
**Tags:** #ci #github-actions #release #solo-loop #pre-launch #infra #general
#process

## L-034 · 2026-07-25 · pure-lib-ux-eval-ci-waits-for-unused-preview
**What happened:** chatterbuilt PR #165 (missing-social-links, #163) was
MCP pure-function only (`suggest-improvement.ts` + tests). UX-evaluator
correctly **skip PASS** (no user-visible surface). Required CI job
`gibson-ux-eval` still ran full preview resolve (`preview-url.sh` timeout
300s, ~6m wall) before skip/pass. Release noted pending ux-eval as part of
the branch-policy block that forced **admin squash** (with empty
`reviewDecision` / L-021). Same class on earlier MCP-only ships (e.g. #108
prepare-agent-docs): hat skip is free, CI still pays the preview wait.
**Root cause:** `ux-eval.yml` has no path filter — every non-draft PR waits
on Vercel preview resolution even when the diff cannot affect marketing UI
or Playwright contract surfaces. Soft-skip after timeout (L-012) still
consumes the window and can keep required checks pending during release.
**Harness fix:** (1) **Sensor** — path-filter or early-exit `ux-eval.yml`
(and optionally zap/posture) when the PR touches no user-visible paths
(e.g. only `apps/mcp/lib/**` / tests; no `marketing/**`, pages, components,
or e2e contracts) → immediate annotated SUCCESS/skip without preview wait.
(2) **Guide** — release: for pure-lib Tier A after hard CI green, do not
treat pending ux-eval as product risk once path-filter would have skipped;
still wait when UI paths are in the diff. (3) Do **not** loosen Tier C
gates or drop live UX for real UI PRs. Distinct from L-012 (preview
protection / soft-skip when a live target is needed).
**Status:** fixed (pinned by scripts/tests/ux-surface.test.sh; previously fix-pending the-gibson#12, practiced on PR #165)
**Tags:** #ci #ux-eval #preview #path-filter #solo-loop #release #local
#process

## L-035 · 2026-07-25 · gitleaks-fixtures-must-not-match-secret-shapes
**What happened:** chatterbuilt PR #166 (missing-payment-deposit-url, #164)
first failed required `security-fast` because UNIT-164-ac2-secrets-not-cta used
realistic Stripe-shaped values (`sk_live_…`, `sk_test_…`, `rk_live_…`) as
fixtures proving secret/server keys are **not** payment CTAs. Reviewer
REQUEST_CHANGES (round 0→1); builder rewrote values to
`ENV_ONLY_*` / `*_SECRET_PLACEHOLDER` while keeping real field names; PR-range
gitleaks clean; security-fast green; squash `eb50458`.
**Root cause:** Tests that assert "secrets must not silence CTAs" naturally use
secret-shaped strings; gitleaks scans the PR commit range including test files
and treats those shapes as leaks. Product code only needs non-URL secret-ish
strings — not real key prefixes.
**Harness fix:** (1) Guide — builder/test-engineer: when fixtures must look
"secret-like" to product code, keep field **names** real (`stripeSecretKey`,
etc.) but use non-gitleaks **values** (`SECRET_PLACEHOLDER`,
`ENV_ONLY_NOT_A_PAYMENT_LINK`, `SERVER_SECRET_PLACEHOLDER`). Never put
`sk_`/`rk_`/`pk_live`/`AKIA`/Bearer-token shapes in tests. (2) Sensor already
works (gitleaks) — do not allowlist secret-shaped fixtures casually. (3)
Distinct from L-022 (cross-lane bleed of *other* PRs' fixtures onto this
check).
**Status:** fixed in product (PR #166); guide playbook text not yet patched
**Tags:** #security #gitleaks #tests #solo-loop #local #process

## L-036 · 2026-07-25 · cross-repo-template-product-vs-claim-table
**What happened:** Solo loop shipped chatterbuilt #194 brand contract as
`chatterbuilt-template` PR #3 (squash `bae7874`) while claims, `agent-claimed`,
loop-state, and journal lived in `mrhinkle/chatterbuilt`. Sibling work was first
filed as monorepo #195/#196 (wrong repo), CLOSED, and refiled as template #5/#6.
PR #3's `Closes mrhinkle/chatterbuilt#194` closed the monorepo issue but left
**template #4** (same AC, correct repo) OPEN. Post-merge smoke on template
`main` failed once for missing `node_modules` after worktree removal; `npm ci`
then tsc/lint/14 tests/build green. Deploy N/A (template has no Vercel project);
UX/security drove local production, not a preview URL.
**Root cause:** Solo-loop playbooks and AGENTS assume one product checkout.
Chatterbuilt's installable site template is a **sibling GitHub repo** with its
own issues/PRs; the monorepo only holds the claim table and fleet memory for
that work.
**Harness fix:** (1) **Guide** — builder/decomposer/release for `template/*`
or epic #193 children: product cwd/worktree = `chatterbuilt-template`; open
issues/PRs on **that** repo; keep claim rows + `GIBSON_CANONICAL` on
`chatterbuilt` main for Law 10 only. Dual-link monorepo epic (#193) in issue
body; do not implement template code in the monorepo. (2) **Release** — after
merge, close the **product-repo** issue that matches the PR (or verify
`closingIssuesReferences` on both repos); `npm ci` on a fresh main checkout
before smoke when the feature worktree is gone. (3) **Decomposer** — file new
template work on `mrhinkle/chatterbuilt-template` first; monorepo issues for
template code are trackers only if dual-linked, never the sole home.
**Status:** fix-pending (guide; practiced on template#3 / #194; playbook text
not yet patched)
**Tags:** #cross-repo #template #claims #release #solo-loop #local #process

## L-037 · 2026-07-25 · release-claim-misses-namespaced-template-claim-ids
**What happened:** After squash-merge of chatterbuilt-template PR #7 (`74faf7a`,
closes product #5), release Law 10 needed to strip monorepo claim row
`issue-template-5-palette-tokens` (L-036: product work on template repo, claim
table on `chatterbuilt`). `release-claim.sh 5` greps only `issue-5-` and
reported no claim row; worktree/branch cleanup and label removal on the
**wrong** default repo would also miss or misfire. Release stripped the row
manually → monorepo `34314db`, removed `agent-claimed` on template#5 via
`gh --repo mrhinkle/chatterbuilt-template`. Second cross-repo template ship
after L-036; this gap was not named there.
**Root cause:** Cross-repo claims namespace the claim id (`issue-template-N-*`)
to avoid colliding with monorepo issue `N`, but `release-claim.sh` keys solely
on `issue-${ISSUE}-` and assumes product issue + claim table live in the same
`GIBSON_CANONICAL` repo. Script truth ≠ L-036 practice.
**Harness fix:** (1) **Guide — release** for template/* work: never assume
`release-claim.sh N` alone is Law 10 done. After merge: (a) strip monorepo
rows matching `issue-template-N-` (or the exact claim id from loop-state /
active-work); (b) remove `agent-claimed` with
`gh issue edit N --repo mrhinkle/chatterbuilt-template`; (c) remove product
worktree under the template clone (or absolute path in loop-state). Prefer
`GIBSON_CANONICAL=~/Code/chatterbuilt` for the claim-table commit only.
(2) **Sensor preferred** — `release-claim.sh` accepts optional prefix
(`template`) or claim-id glob so `issue-template-N-*` matches; label cleanup
takes `--repo owner/name`. File as harness-improvement if not shipped
in-session. (3) **Builder** — when claiming template issues, record full claim
id in loop-state `notes` so release does not guess.
**Status:** fixed (pinned by scripts/tests/release-claim.test.sh)
**Tags:** #cross-repo #template #claims #release-claim #release #solo-loop
#local #process #law-10

## L-038 · 2026-07-25 · css-token-migration-must-lock-derived-identity
**What happened:** chatterbuilt-template PR #7 tokenized the palette into
`lib/theme.ts` + CSS variables. Unit/contract sensors locked `:root` hex
tokens and "no camo/bench" renames; local gate stayed green (31→32 tests).
Reviewer still REQUEST_CHANGES (F1): default chrome decorative gradients and
shadows used different `color-mix` / opacity percentages than pre-token
`main` (`--accent-dim` radial 0.15 vs 0.08, glow 0.25 vs 0.12, steel/shadow
mixes). Visual identity of amendmentworks default chrome drifted while token
hexes matched. Builder fixed with identity-preserving `color-mix` percentages
and `CONTRACT-5-default-chrome-identity` sensor; reviewer APPROVE @ `8bf98cc`.
**Root cause:** Token migration sensors checked the new abstraction (var
hexes) but not the **pre/post computed identity** of derived surfaces
(opacities, mixes, gradients). Gate green ≠ chrome unchanged.
**Harness fix:** (1) **Guide — builder/test-engineer** when replacing hard-coded
colors with tokens: add a contract that freezes derived decorative values
(color-mix percentages, alpha stops) against the pre-change baseline, not only
the token table. Prefer one sensor named for the migration (e.g.
`CONTRACT-*-default-chrome-identity`). (2) **Reviewer** — for palette/theme
PRs, diff `globals.css` decorative rules against merge-base even when unit
tests pass. (3) Product fix shipped in template PR#7; no fleet sensor required
beyond the pattern.
**Status:** fixed in product (template PR#7 / `8bf98cc` + sensor); guide
playbook text not yet patched
**Tags:** #css #tokens #theme #tests #review #template #solo-loop #local
#process

## L-039 · 2026-07-25 · token-only-wcag-sensors-miss-composed-surfaces
**What happened:** chatterbuilt-demo-church PR#4 (Riverbend rebrand) shipped
token-level WCAG sensors (`CONTRACT-1-contrast-aa`) that asserted body/muted/
accent AA on theme hex pairs. Local gate + CI green (22→24 tests after
test-engineer). Cross-vendor reviewer REQUEST_CHANGES: Hero used dark scrims
over imagery with light `text-foreground` (~1.07:1 on mobile H1); `mutedDim`
`#77818a` ~3.65:1 on cream/panel. Token table was AA; **composed** surfaces
were not. Round-1 fix: cream scrims + `mutedDim` `#5e6870` + composed-surface
sensors (no-dark-scrim, cream@92% blend model). Re-pass APPROVE @ `7beec67`;
UX 25/25 axe 0; merged `13db10e`.
**Root cause:** Contrast sensors checked the theme abstraction (fg/bg hex
ratios) not the rendered stack (image + scrim opacity + text color). Gate green
≠ accessible on real hero/overlays. Same class as L-038 (sensors lock tokens,
not derived reality) but for a11y rather than chrome identity.
**Harness fix:** (1) **Guide — test-engineer/builder** when AC claims WCAG AA
on themed marketing pages: add composed-surface sensors for hero/scrim/
overlay paths (forbid dark wash under light text; model blended bg@opacity ×
fg ≥ 4.5:1), not only token pair tables. (2) **Reviewer** — for palette/rebrand
PRs, recompute contrast on hero and muted-on-elevated, not only `theme.ts`.
(3) Product + sensors fixed in demo-church PR#4; pattern reusable across
demo-fleet rebrands (epic #193).
**Status:** fixed in product (demo-church PR#4 / `13db10e` + composed sensors);
guide playbook text not yet patched
**Tags:** #a11y #wcag #contrast #theme #tests #review #demo-fleet #solo-loop
#local #process

## L-040 · 2026-07-25 · accent-as-small-text-on-elevated-fails-despite-token-aa
**What happened:** chatterbuilt-demo-hvac PR#4 (Ridgeway Heating & Air rebrand)
shipped token WCAG sensors + L-039 ground hero scrims + white-on-accent CTA AA.
Round-0 gate green (23 tests). UX eval hard-failed axe serious color-contrast
on home `#offers` date labels: `text-accent` `#b35f0a` on elevated `#183049` ≈
2.92:1 (need 4.5:1). Craft 6. Round-1 fix: eyebrows → `text-steel`; CTA accent
fill kept for white labels; sensor `CONTRACT-1-offers-eyebrow-contrast`. Re-pass
36/36, Craft 8, security CLEAR, merge `824e09e`.
**Root cause:** Brand accent is dual-use — large-fill CTA chrome can meet AA with
white labels while the same hex as small text on elevated panels fails. Token
pair tables and CTA-only sensors do not lock "accent not used as body/eyebrow
text on elevated surfaces." Sibling of L-039 (composed vs token) for a different
composition class (role dual-use, not scrim stack).
**Harness fix:** (1) **Guide — builder/test-engineer** for demo-fleet rebrands:
never put `text-accent` on small copy over elevated/ground panels; reserve accent
for fills, borders, and icons with AA-checked labels; sensor-lock offer/eyebrow
paths as non-accent (steel/muted). (2) **UX** — axe re-drive home seasonal
blocks after palette ships, not only hero. (3) Product + sensor fixed in
demo-hvac PR#4 @ `c4ffbce` / main `824e09e`.
**Status:** fixed in product (demo-hvac PR#4); guide playbook text not yet
patched
**Tags:** #a11y #wcag #contrast #theme #tests #ux-eval #demo-fleet #solo-loop
#local #process

## L-041 · 2026-07-26 · accent-fill-for-cta-breaks-global-eyebrow-text
**What happened:** chatterbuilt-demo-detailer PR#4 (Crestline Auto Detailing
rebrand) applied L-040 day-1 as **steel only on Events card eyebrows**. Round-0
gate green (27 tests). Reviewer REQUEST_CHANGES: global `.eyebrow { color:
var(--accent) }` and ~15 other small-text surfaces used fill accent `#0c6b78`
→ 3.16/2.95/2.67:1 on ground/panel/elevated (need 4.5). Same blaze accent on
template main had been ~6:1 as text — deep cyan chosen so **white CTA labels**
pass AA automatically fails **every** accent-as-text path. Hero body scrims
(L-039) were fine; hero eyebrow still failed. Round-1: dual tokens — keep dark
`accent` fill for CTAs; add lighter `accentText` (`#3eb8c8`) + `--accent-text`
/ `text-accent-text`; repoint `.eyebrow` + all small-text surfaces; sensors
`CONTRACT-1-accent-text-aa`, `eyebrow-uses-accent-text`, dual-use proof that
fill fails as text. Re-pass APPROVE @ `44507c4`; UX 41/41 axe 0; merge
`26fa95e`.
**Root cause:** (1) L-040 harness fix named one path ("steel for eyebrows")
and one surface class (offers); builders under-applied it. (2) When brand
needs **colored** small text, steel is wrong. (3) Fill accent optimized for
white-on-CTA AA is often too dark for body-size text on elevated grounds —
global CSS binding `.eyebrow` to fill accent multiplies one bad ratio across
every section. Token+CTA sensors green ≠ accent-as-text AA.
**Harness fix:** (1) **Guide — builder** on demo-fleet rebrands: after picking
fill accent for white CTA AA, immediately ratio-check fill-as-text on
ground/panel/elevated. If any < 4.5, invent `accentText` (lighter role) the
same day — do not ship fill accent as small text. Never bind global `.eyebrow`
to fill `accent`. (2) **Sensors day-1:** (a) white-on-fill CTA ≥ 4.5; (b)
fill-as-text on elevated **fails** (dual-use proof); (c) `accentText` (or
steel) ≥ 4.5 on all grounds; (d) global `.eyebrow` uses text role, not fill;
(e) lock DemoBanner/Footer/section eyebrows, not only Events/offers. (3)
**Reviewer** — for palette PRs, recompute accent on every `text-accent` /
`.eyebrow` hit, not only offers. Sibling of L-040 (role dual-use) with the
missing global-CSS + dual-token recipe. Product fixed in detailer PR#4.
**Status:** fixed in product (demo-detailer PR#4 / `44507c4` + main
`26fa95e`); guide playbook text not yet patched
**Tags:** #a11y #wcag #contrast #theme #tests #review #demo-fleet #solo-loop
#local #process #l-040

## L-042 · 2026-07-26 · contract-sensors-match-comments-or-decoys
**What happened:** chatterbuilt-demo-restaurant PR#4 (Linden Table rebrand)
had product B1″/G1/I1 CLEAR on tip `d852bd9` / `37b62cc` (hero glow→cream
order; gallery light captions on `from-black/90`), gate green (42 tests).
Reviewer still REQUEST_CHANGES at round 3 and parked: residual **sensor**
false-greens — **G1-S** regex matched a `from-black/90` mention in a comment
(or elsewhere) rather than co-located `className` on the caption open tag;
**B1″-S2** accepted a dual-glow decoy (two glow-like layers) because the
unique `bg-hero-glow` + `data-hero-layer` same-tag lock was missing. Mutants
(comment-only `/90`, `from-black/20`, dual-glow, cream-before-glow) stayed
GREEN under the old sensors. TE unparked with co-location sensors @ `018f7e5`
(mutants RED; product restore 42/42); reviewer re-pass APPROVE; UX 48/48;
merge `8fc4d1a`.
**Root cause:** Contract sensors that grep the file for a token string (opacity
stop, layer name) without requiring **same-tag / open-tag co-location** with
the product attribute, and without a **unique decoy-resistant** identifier,
can pass while the live DOM still violates the acceptance criterion. Gate
green ≠ criterion locked.
**Harness fix:** (1) **Guide — test-engineer** for CSS/DOM contract sensors:
assert the criterion on the **product node** (open-tag `className` / same
element as `data-*`), never a bare file-wide string match that a comment or
unrelated class can satisfy. Prefer product-derived values (e.g. opacity ≥
0.90 from source) over hard-coded comment echoes. (2) **Mutant battery day-1**
before calling sensors green: comment-only match, wrong opacity, dual/decoy
layers, order inversion — each must go RED, then product restore GREEN.
(3) **Reviewer** — when product reads CLEAR but sensors exist, re-run at least
one mutant; REQUEST_CHANGES on sensor-only false-greens is valid (park rules
apply). Product fixed sensors in demo-restaurant PR#4 @ `018f7e5`.
**Status:** fixed in product (demo-restaurant PR#4 / `018f7e5` + main
`8fc4d1a`); guide playbook text not yet patched
**Tags:** #tests #sensors #false-green #review #demo-fleet #solo-loop #local
#process #contract

## L-043 · 2026-07-26 · residual-source-vertical-chrome-missed-by-rebrand-sensors
**What happened:** Demo-fleet rebrands (contractor template → vertical brand)
repeatedly shipped gate-green with **source-vertical chrome strings** still
user-visible. (1) demo-restaurant PR#4: contact form "Project type" / "What
needs fixing?", contact API "quote request", then contact hero hard-coded
"Quotes, scheduling, and project questions" — REQUEST_CHANGES rounds 0–2
before sensors banned contractor phrases. (2) demo-civic PR#4 (Riverside
Heights): day-1 carried L-039/L-041/L-042 and had `contact-no-contractor-chrome`
partial coverage (39/39 green), but reviewer still REQUEST_CHANGES on tip
`64ce9a0` — contact hero residual, ChatWidget placeholder, kb-search
NO_MATCH, Schedule book/consult fallbacks, Services DEFAULT fair-quotes.
Builder round-1 purged + **+5 residual-chrome sensors** → 44/44 @ `3dbb81f`;
re-pass APPROVE; UX PASS; merge `93ff8cf`. Same failure class twice across
verticals; second hit after partial sensors proves map was incomplete.
**Root cause:** Rebrand contract maps lock theme/fonts/brand/camo/WCAG and
sometimes *one* contact surface, but not a **full residual-vocabulary sweep**
across secondary chrome (chat widget, KB fallbacks, schedule defaults,
services DEFAULT, hard-coded page heroes, API subject lines). Gate green ≠
source vertical gone from every user-visible string.
**Harness fix:** (1) **Guide — builder day-1** on every demo-fleet rebrand:
grep product tree (not only `content/site.ts`) for source lexicon (quote,
project type, scheduling, book/consult, fair-quotes, contractor CTAs, prior
vertical nouns) and rewrite *or* wire to site.* before first push. (2)
**Sensors day-1** — residual-chrome battery that bans source phrases in
contact page/form/route, ChatWidget, kb-search strings, Schedule fallbacks,
Services DEFAULT, hard-coded heroes; assert site.* wiring for each. (3)
**Reviewer** — open contact + chat + schedule + one service page even when
unit map is green; REQUEST_CHANGES on any source-vertical chrome is valid.
Product fixed in restaurant PR#4 + civic PR#4 @ `3dbb81f` / main `93ff8cf`.
Carry on etsy-maker#1 (and any remaining rebrands) day-1 — do not rediscover
at review.
**Status:** fixed in product (demo-civic PR#4 + prior restaurant); guide
playbook text not yet patched
**Tags:** #copy #rebrand #sensors #false-green #review #demo-fleet #solo-loop
#local #process #contract #l-042-sibling

## L-044 · 2026-07-26 · rebrand-sensors-miss-silhouette-geometry-and-pov
**What happened:** demo-etsy-maker#1 / PR#4 day-1 shipped with L-039/L-041/L-042/L-043
sensors green (44→45/45). Reviewer REQUEST_CHANGES on tip `4db2124` still found:
(1) **product/gallery SVGs shared one vase path** — fills/captions changed only;
catalog cards misrepresented distinct SKUs (mug/plate/bowls/platter/pour-over);
(2) **first-person maker-voice AC soft-failed** — hero/story stayed third-person
product framing while sensors only locked pottery keywords. Both passed the
criterion→sensor map and CI Sensors step; caught only at multi-lens review
(Codex + orchestrator). Round-1 builder fixed distinct silhouettes + first-person
POV; TE locked +6 regression sensors → 51/51; re-pass APPROVE; merge `4e59ce6`.
**Root cause:** Rebrand sensors treat imagery as "file present + no camo path +
fills" and voice as "keyword lexicon," not **geometry uniqueness** (distinct
`path d=` / silhouette families per product slug) or **grammatical POV**
(first-person pronouns / process-I voice). Gate green ≠ imagery AC or voice AC.
**Harness fix:** (1) **Sensors day-1** — assert N product SVGs do not share the
same primary path geometry (hash path `d=` or min unique path count); ban
shared silhouette across service/gallery assets. (2) **Voice** — for first-person
verticals, assert hero/story contain first-person markers (`I ` / `my ` / `we `
process claims) and ban third-person studio boilerplate that contradicts the AC.
(3) **Reviewer** — open product card grid; one glance for "same vase recolored"
is a valid REQUEST_CHANGES even when unit map is green. Product fixed etsy-maker
PR#4 @ `7fb0b6e` / sensors `44326f7` / main `4e59ce6`.
**Status:** fixed in product (demo-etsy-maker PR#4); guide playbook text not yet patched
**Tags:** #rebrand #sensors #false-green #imagery #voice #review #demo-fleet #solo-loop #local #contract #l-042-sibling

## L-045 · 2026-07-26 · residual-nonstring-chrome-icons-and-hardcoded-palette
**What happened:** After L-043 (residual **string** chrome), demo-etsy-maker#1
day-1 carried residual-chrome string sensors and passed them, but reviewer still
REQUEST_CHANGES on tip `4db2124` for **non-string** source residuals:
(1) `IconBadge` / `site.ts` still used tactical `crosshair|shield|wrench` icons
on pottery service cards (contractor IconName union + wrench default);
(2) `ChatWidget` FAB kept hard-coded blaze
`shadow-[0_8px_28px_rgba(242,98,46,0.4)]` — source vertical palette on every
page. String battery green ≠ residual chrome gone. Round-1: maker IconBadge set
+ `var(--accent-glow)`; sensors locked; merge `4e59ce6`. Same residual-chrome
class as L-043, second surface family (icons + hard-coded rgba), second vertical.
**Root cause:** L-043 harness fix scoped the residual-chrome battery to **copy
phrases** in contact/chat/kb/schedule/services. It did not cover component
**IconName unions**, default glyphs, or **hard-coded source accent rgba/hex** in
components (FAB glow, shadows, borders).
**Harness fix:** (1) **Guide — builder day-1** — grep `components/` for source
palette literals (`#f2622e`, `242,98,46`, blaze/camo icon names) and rewrite to
theme tokens / vertical IconName set before first push. (2) **Sensors day-1** —
ban residual tactical icon names when vertical ≠ contractor; assert FAB/glow uses
`var(--accent-glow)` or theme token, not raw source rgba. (3) **Reviewer** —
scan IconBadge + ChatWidget even when residual-string map is green. Sibling of
L-043 (string chrome) for non-string residual. Product fixed etsy-maker PR#4.
**Status:** fixed in product (demo-etsy-maker PR#4); guide playbook text not yet patched
**Tags:** #rebrand #sensors #false-green #icons #palette #review #demo-fleet #solo-loop #local #contract #l-043-sibling

## L-046 · 2026-07-29 · unprotected-production-write-path
**What happened:** ConferenceOS Production Branch was `release`, but `release` had
no branch protection; `main` had checks without `enforce_admins` or required
reviews; GitHub Production environment had zero protection rules. Security audit
blocked production-readiness on delivery control, not only application bugs.
**Root cause:** release playbook covered per-PR merge/verify; nothing audited or
hardened the *infrastructure* write path to Production. Docs can claim model B
while the prod branch stays mergeable by anyone with write.
**Harness fix:** docs/23 delivery-control + `scripts/delivery-control/` audit/harden
(portable); adoption + release preflight require audit; secret rotation stays G4
(owner only — never agent-rotated Neon keys).
**Status:** fixed in harness (doc 23 / scripts); targets re-audit at adoption
**Tags:** #release #github #branch-protection #vercel #security #adoption

## L-047 · 2026-08-02 · a-gate-that-reviews-the-wrong-diff-manufactures-evidence
**What happened:** The issue-#55 Law 5 gate in `loop.sh` shipped with two silent
substitutions. It never passed `--base`, so `second-opinion.sh` defaulted to
`main` — in a `master`/`develop` repo that ref does not exist, and the old
`git diff "$BASE...$BRANCH" || git diff "$BASE"` fallback then reviewed the
WORKING TREE instead. Separately, `resolve_handoff_sha` could return an
`ls-remote` SHA whose object was absent from the local clone (pushed from another
worktree), so the driver wrote a receipt naming a commit no reviewer could read.
**Root cause:** the gate's sensors asserted "a review happened," never "a review
of *this* diff happened." Defaults (`main`) and fallbacks (`git diff BASE`) are
how a gate keeps returning success after its premise stops holding — and because
it emits a receipt, the wrong answer is now documented as the right one.
**Harness fix:** `loop.sh` resolves the target repo's real base and fails closed
on every miss (branch stays queued). The first cut pinned only the head, and
review caught the mirror-image hole: naming the base by branch let a receipt for
the same head be reused after `main` advanced, which is a different diff. So the
base is now pinned the same way the head is — when an origin exists, one live
`ls-remote --symref` yields the current default branch *and* its current tip
(stale `origin/HEAD` and stale `refs/heads/main` are not trusted); no origin at
all falls back to a verified local main/master. `second-opinion.sh` gets the exact
base SHA, `devin-supervisor.sh` gets the branch name it opens the PR into, both
objects are fetched and verified locally before any review, and the receipt binds
base name + base SHA + head branch + head SHA + author + reviewers. `second-opinion.sh`
dies on an unresolvable base or branch instead of falling back to the working
tree. Regressions in `scripts/tests/loop-handoff.test.sh` (non-main trunk, stale
local origin/HEAD, missing local object, remote base advance, unresolvable
base/pin) and `scripts/tests/second-opinion.test.sh`.
A third review round found two survivors of the same species. (a) With an origin
reachable but carrying no `refs/heads/<branch>`, `resolve_handoff_sha` fell back
to the LOCAL branch ref — so a never-pushed branch was reviewed and handed to a
supervisor that opens PRs from the remote and would never see that commit, and
`devin-supervisor.sh` dies on an absent/unreachable remote branch when `--sha` is
pinned. A fourth round found the last shard of that same fallback: keeping local
refs "only for a repo with no origin at all" still let an origin-less queued
handoff spend a distinct-vendor review and only *then* hit the supervisor's
no-origin refusal. `resolve_handoff_sha` is reached only from the Devin handoff
path, so it now has no local-ref fallback whatsoever — no origin is a block
before the review, not a die() one script later, and the origin-less and
never-pushed cases in `loop-handoff.test.sh` both assert "no review spent, no
receipt, no supervisor call, still queued". (b) The
handoff message's diffstat was still `git diff --stat "$BASE...$BRANCH"` — two
NAMES, read in a clone whose refs may be stale or carry local-only commits — so
the supervisor could be shown a diff nobody reviewed. `--base-sha` was added and
the driver passes both exact endpoints; names remain in the prose for PR
targeting, and an unreadable object yields an explicit `n/a`, never a substitute
diff. Also recorded honestly: the receipt is an operational control, not a
security boundary (same-user filesystem isolation is separate work).
**Generalisation:** pinning one endpoint of a diff is not pinning the diff. A
receipt must name every value the comparison depends on, or it certifies a
comparison nobody performed — and every remaining *name* in the path (a fallback
ref, a diffstat range) is a place the certified comparison can quietly differ
from the one actually shown.
**Status:** fixed in harness
**Tags:** #loop #law5 #gates #git #sensors #issue-55

## L-048 · 2026-08-03 · release-cmd-acceptEdits-blocks-gh
**What happened:** chatterbuilt docs lane release of PR #346 (#311) shelled out to
`RELEASE_CMD=claude … --permission-mode acceptEdits`. Claude could not run Bash
or `gh` (permission deny). Merge stalled until a retry with
`bypassPermissions` succeeded (squash → `45f9593`). Same class hit the parallel
mcpcore lane on PR #347. Fleet default in
`~/.claude/fleet/loop-fleet.sh` was
`RELEASE_CMD=…--permission-mode acceptEdits`.
**Root cause:** Claude `acceptEdits` auto-approves **file edits only**. Cross-
vendor release operators need Bash + `gh pr merge`. L-008 already fixed the
main grok runner for headless noop; RELEASE_CMD was a separate shell-out and
kept the weaker mode (and adapter docs even recommended acceptEdits).
**Harness fix:** (1) Fleet default RELEASE_CMD → `bypassPermissions`
(`~/.claude/fleet/loop-fleet.sh`). (2) Guide — adapters/grok README three-way
split example, playbooks/release.md, playbooks/loop-step.md: release identity
must allow Bash/gh; verify with `gh pr view --json state,mergedAt` after
shell-out. (3) Do not use acceptEdits for merge shell-outs.
**Status:** fixed (fleet default + guides this session)
**Tags:** #release #permissions #claude #solo-loop #harness-bug #general

## L-049 · 2026-08-03 · docs-only-smoke-is-main-content-not-vercel
**What happened:** After merging docs-only PR #346 (#311 onboarding runbook
close), release verified ship by checking contract tokens on `main`
(ONBOARDING-RUNBOOK OWNER/VERIFIED/NOT BUILT/sprint-contract/photo-sources,
README index, Released marker) rather than waiting for a marketing/MCP Vercel
READY deploy. That was the correct smoke; generic Stage-8 "wait for READY"
would have wasted minutes or false-failed a pure docs ship.
**Root cause:** Release playbook Stage 8 assumes product deploy surfaces.
Docs-only / specs-only Tier A PRs do not change Vercel roots (`marketing`,
`apps/mcp`) and need no deploy wait.
**Harness fix:** Guide — playbooks/release.md Stage 8 docs-only branch: fetch
`origin/main`, `git show` / grep contract tokens from the PR body; skip READY
wait and posture probe for pure docs/specs. Product-surface PRs keep full
deploy+smoke. Practiced on #311.
**Status:** fixed (guide this session)
**Tags:** #release #docs #smoke #solo-loop #general

## L-050 · 2026-08-03 · portability-shim-that-succeeds-for-the-wrong-reason
**What happened:** `claim-reaper.test.sh` died mid-run on Linux with
`line 276: File: unbound variable`. The line was a normal-looking BSD/GNU shim:
`stat -f %m "$f" 2>/dev/null || stat -c %Y "$f"`. On Linux `stat -f` means
*filesystem* status, so the first branch **succeeded** — printing a multi-line
block starting `  File: "/tmp"` — and `[[ ... -gt ... ]]` evaluated that text as
arithmetic, where the bare word `File` is an unset variable under `set -u`.
**Root cause:** an `A || B` fallback assumes A *fails* on the platform B is for.
`stat -f` doesn't fail on Linux; it means something else. The fallback never
fired, and the wrong answer flowed on silently — the crash was luck. The same
pattern is live in `claim-reaper.sh` (`%m` → mount point), `loop.sh` and
`gate.sh`/`gate-baseline.sh` (`%d`/`%i` → free blocks / filesystem ID), where
there is no `set -u` crash to give it away (#99).
**Harness fix:** probe GNU first, BSD second, and terminate with an explicit
default: `stat -c %Y f 2>/dev/null || stat -f %m f 2>/dev/null || echo 0`. Same
ordering rule as the `date -u -d` / `date -u -j -f` shim in `claims-status.sh`.
**Rule of thumb:** a cross-platform fallback is only safe when the wrong branch
*errors*. If a flag exists on both platforms with different meanings, order by
which one you can detect, and give the chain a terminating default.
**Status:** fixed in the test (#93) and production call sites (#99: gate.sh, gate-baseline.sh, loop.sh, claim-reaper.sh) with a gate.test.sh sensor that asserts two files on one filesystem get distinct path_dev_ino identities and that every production site is exact GNU-first form.
**Tags:** #portability #shell #sensors

## L-051 · 2026-08-08 · unpinned-shellcheck-makes-exact-set-ratchet-nondeterministic
**What happened:** PR #142 removed `scripts/tests/loop-state.test.sh SC2218` from
the ShellCheck baseline after a late `make_runner_cmd` redefinition. Locally
(ShellCheck 0.11.0) the baseline-only change was green; shared CI (unpinned apt
ShellCheck 0.9.x/0.10.x) failed with `NEWF` containing SC2218 (reproduced 31×).
Issue #138 / PR #147 had to repair the structural cause *and* make the analyzer
contract deterministic so the same ratchet could not disagree across hosts.
**Root cause:** an exact-set finding ratchet is nondeterministic when the
analyzer version is not part of the contract. SC2218 accuracy changed between
ShellCheck ≤0.10 and 0.11.0; treating a tool-version delta as source debt (or
as a baseline-only green) was false.
**Harness fix:** (1) Structurally de-duplicate `make_runner_cmd` — one early
definition with issue-#63 behaviors, no late redefinition, no suppressions.
(2) Pin official ShellCheck version + platform digests in
`scripts/tests/run-all.sh` (`SHELLCHECK_REQUIRED_VERSION` + named SHA-256
constants). (3) CI (`.github/workflows/gibson-self-gate.yml`) extracts the one
machine source via strict assignment lines, verifies shapes, installs the
official linux.x86_64 asset with digest check, asserts version equality, and
fails closed if PATH does not select the pin. (4) Offline mutation-backed
`self_test_toolchain` (ordinary `run-all.sh` path + `--self-test-toolchain`)
proves extract/wiring/mutations fail closed without network.
**General rule / Rule of thumb:** pin the analyzer and its acquisition path
before comparing exact findings; do not treat a tool-version delta as source
debt or as a baseline-only green.
**Status:** fixed in #138 / PR #147
**Tags:** #toolchain #ci #ratchet #shellcheck #sensors #issue-138 #pr-147

## L-052 · 2026-08-15 · hermetic-identity-fallback-inherits-ci
**What happened:** PR #215 (`feat/204-signing-at-commit-time`) was green locally
(`setup-hooks.test.sh` 21/21) and red in gibson-self-gate: 20 passed, 1 failed
with `added trailer did not name the committer`. The hook had added
`Signed-off-by: gibson-ci <ci@gibson.invalid>` — the actual committer — while
the assertion grepped for the fixture name `gibson-sensor`.
**Root cause:** the suite used `${GIT_COMMITTER_NAME:-gibson-sensor}`. That is
not hermetic. gibson-self-gate writes `GIT_COMMITTER_NAME=gibson-ci` into
`GITHUB_ENV` (the #101 runner-identity pin). `${VAR:-default}` keeps the CI
value, so the hook (correctly, via `git var GIT_COMMITTER_IDENT`) signed as
`gibson-ci` and the hardcoded name check failed. Local runs had no
`GIT_COMMITTER_*` and therefore used the fallback, hiding the failure.
**Harness fix:** (1) `prepare-commit-msg` now composes `Name <email>` from
`GIT_COMMITTER_*`, then `git var`, then `user.name`/`user.email`, and refuses
to add a trailer unless both name and email are non-empty. (2) The sensor
overwrites the hermetic identity (no `:-` inherit) and still asserts
`gibson-sensor` plus the matching email. A test that greps a fallback name
must pin that name, not inherit the host.
**Status:** fixed (PR #215 follow-up)
**Tags:** #dco #hooks #ci #sensors #identity #issue-204 #pr-215

## L-053 · 2026-08-21 · cancel-in-progress-plus-always-stamps-false-reds
**What happened:** ConferenceOS workflows combining `concurrency:
cancel-in-progress` with status-publishing steps under `if: always()` stamped
false-red commit statuses from cancelled runs (ConferenceOS #1458, two
workflows): a superseded run's publish step fired with empty outputs /
`JOB_STATUS=cancelled`, fell into the `case` fallthrough, and wrote "failed
closed" on a head whose surviving run later passed. Merge captains triaged
phantom reds for days.
**Root cause:** `always()` runs on cancellation too; a status published from a
cancelled run is a verdict from a run that decided nothing. Naive fix
(skip-on-cancel) can fail OPEN — if cancellation lands between
resolve-head and invalidate-prior-status, a stale `success` survives. The
sound fixes are step-order-dependent: stamp `pending` on cancellation when
the step can still run (evaluator pattern), or skip-on-cancel ONLY when a
`pending` stamp is already guaranteed before the publish guard can pass
(smoke pattern).
**Harness fix:** before adding `cancel-in-progress` to any workflow that
publishes commit statuses, audit every `always()` step for cancelled-state
fallthrough; pick pending-on-cancel vs skip-on-cancel by whether a prior
pending stamp is guaranteed. ConferenceOS PRs #1462/#1468 are the worked
examples.
**Status:** fixed in ConferenceOS; audit other repos when adding concurrency
**Tags:** #ci #github-actions #concurrency #false-red

## L-054 · 2026-08-21 · vercel-cost-and-noise-controls
**What happened:** ConferenceOS's Vercel bill and PR signal were dominated by
two misconfigurations, not by build speed: (1) builds queued serially until
the owner enabled Elastic concurrency (the machine-tier upgrade under
consideration would have bought nothing — canonical builds were already
3–5 min); (2) a demo project built every PR branch against a shared preview
DB and failed 100% of the time (ConferenceOS #1391), billing minutes and
stamping a guaranteed-red check that trained everyone to ignore red X's.
**Root cause:** per-project build triggers default to "every branch"; demo/
secondary projects have no business building PR branches.
**Harness fix:** secondary/demo Vercel projects get an Ignored Build Step
(`if [ "$VERCEL_ENV" == "production" ]; then exit 1; else exit 0; fi` —
exit 1 = build, exit 0 = skip); check Elastic/concurrent builds before
paying for bigger build machines. Candidate doctrine home: docs/12 +
docs/17.
**Status:** applied in ConferenceOS; doctrine docs not yet updated
**Tags:** #vercel #cost #ci-noise #deployment

## L-055 · 2026-08-21 · npm-cache-is-repo-posture-dependent
**What happened:** Porting ConferenceOS's CI cache work (setup-node
`cache: npm`, ESLint `--cache --cache-strategy content`, Next.js
`.next/cache`) to other repos: Chatterbuilt's calibrated gate took it
cleanly (PR chatterbuilt#518), but this repo's own gate sensor
(`gate.test.sh` phase-2: "no secrets/cache/env/OIDC") REJECTED `cache:` in
`ci/gibson-gate.yml` — deliberately: the template's base/head
test-integrity jobs execute untrusted PR code, and a cache shared across
that boundary is a poisoning surface.
**Root cause:** cache safety depends on the workflow's trust architecture,
not on the cache mechanism. Single-trust-boundary gates (one checkout of
the merge ref, npm ci verifying lockfile integrity hashes) can cache;
multi-job untrusted-code architectures ban it on purpose.
**Harness fix:** none needed here — the sensor did its job and blocked the
transplant. Lesson: run the target repo's own sensors BEFORE pushing a
ported "improvement"; a green idea in one repo can be a designed-out
anti-pattern in another.
**Status:** working as designed
**Tags:** #ci #cache #security #calibrate-dont-transplant

## L-056 · 2026-08-21 · authority-matchers-need-adversarial-mutation-witnesses
**What happened:** The #208 authority sensor passed 250 tests while missing
live claims hidden by connective modifiers, modified self-subjects, HTML
comments, operative frontmatter outside playbooks, and past/perfect verb forms.
It also silently skipped the no-shrink proof when pinned git evidence was
unavailable and rejected the fork overlay that AGENTS.md explicitly permits.
**Root cause:** The matcher and discovery exemptions evolved faster than their
positive/negative mutation matrix; some historical fixtures were vacuous
because the scanner never recognized the verb form they purported to test.
**Harness fix:** Every authority relation, carve-out, file-class exemption, and
evidence dependency needs a paired adversarial mutation witness. Treat HTML
comments as agent-visible input, and fail closed when pinned evidence cannot be
read.
**Status:** fixed in #208 follow-up
**Tags:** #authority #sensors #mutation-testing #fail-closed #issue-208

## L-057 · 2026-08-27 · new-ci-job-needs-its-own-dependency-install
**What happened:** A new report-only CI job (ConferenceOS PR #1617) imported a
shared lib module (which imports `typescript` at load time) but the workflow
never ran `npm ci` before invoking the script. Every real hosted run crashed
with `ERR_MODULE_NOT_FOUND`. Because the step was `continue-on-error: true`,
the crash was silently converted into a green check — the sensor had never
actually evaluated a single PR, including its own self-reported "0/20 false
positives" measurement, which was therefore meaningless (the script never ran
to produce it). An independent cross-vendor review (Codex) caught this by
reading the actual hosted Actions log, not by trusting the PR's local claims.
**Root cause:** `continue-on-error: true` (correct for an advisory, non-blocking
sensor) converts EVERY failure mode into the same green signal, including
"the check never ran at all." A missing dependency-install step is invisible
locally (dev machines already have `node_modules`) and only surfaces on a
clean CI runner.
**Harness fix:** any new CI job that runs a script must install dependencies as
an explicit early step, verified against a real hosted run (not just local),
before any claim about the check's behavior (false-positive rate, pass/fail
distribution) is trusted. `continue-on-error` sensors need a second, narrower
guarantee: prove the step can fail in a way that's visible somewhere (a
required upstream install step, a startup self-check) even though the sensor
step itself can't block.
**Status:** fixed in ConferenceOS #1617
**Tags:** #ci #github-actions #false-gate-signal #dependency-install

## L-058 · 2026-08-27 · dont-transform-git-diff-paths-before-classifying-them
**What happened:** Same sensor as L-057, next two review rounds. First: the
path parser called `.trim()` on `git diff --name-only -z` output, so a file
literally named with a leading space (` tests/unit/fake.test.ts`) got
normalized into a real `tests/` path and false-matched a "was this tested"
classifier. Fixed narrowly. Third round: the SAME classifier also converted
backslashes to forward slashes ("Windows path" defensiveness), so a file
literally named with a backslash (`tests\unit\fake.test.ts` — a normal,
Git-legal filename on Linux, not a path separator there) false-matched the
same way. The second fix removed the transformation function entirely rather
than patching around a third variant.
**Root cause:** `git diff -z` already emits the canonical, separator-normalized
form — Git internally only ever uses `/`, on every platform, and preserves
filenames byte-for-byte with NUL termination specifically so tools don't have
to guess where whitespace or separators belong. Any transformation applied to
that output before classification is unnecessary by construction and can only
ever manufacture a false match, never a legitimate one.
**Harness fix:** when parsing `git diff`/`git log` machine-readable output
(`-z`, `--name-only`, `--name-status`), treat the emitted path as already
correct — no `.trim()`, no separator rewriting, no case-folding. If a
transformation feels necessary, that's a signal the input source isn't
actually raw git output.
**Status:** fixed in ConferenceOS #1617 (both variants; regression tests added
for both the leading-space and literal-backslash cases)
**Tags:** #ci #git #false-gate-signal #path-parsing

## L-059 · 2026-08-27 · npm-audit-fixAvailable-can-point-backward
**What happened:** While scoping a security-gate CVE-severity ratchet
(ConferenceOS #1613/#1612), the plan assumed `npm audit`'s suggested fix
version for a Prisma-chain CVE (`6.12.0`) was an upgrade path. By the time the
fix was dispatched (same day, fast-moving repo), the installed `prisma` was
already at `7.9.1` — `6.12.0` was a downgrade, not a fix. The dispatched
builder caught this by re-running `npm audit` fresh in its own worktree
rather than trusting the coordinator's numbers, and correctly refused to
take `--force`.
**Root cause:** `npm audit`'s `fixAvailable` field names A version that
resolves the advisory in its own dependency graph, not necessarily one that
is newer than what's currently installed — on a fast-moving repo, "installed"
and "what the coordinator checked earlier today" can already differ.
**Harness fix:** any spec or issue that names a specific "fix to version X"
must be treated as a claim to re-verify at execution time, not a fact to
carry forward — the builder role should always re-run the actual audit/check
locally before acting on a coordinator-supplied version number, and a spec
should say so explicitly rather than assume its own numbers stay current.
**Status:** working as designed once flagged; tracking issue corrected
(ConferenceOS #1612)
**Tags:** #security #dependencies #stale-spec #verify-dont-trust

## L-060 · 2026-08-27 · dispatching-a-review-onto-a-pr-another-coordinator-already-owns-wastes-a-full-loop
**What happened:** A second session ran a full 4-round dispatch → cross-vendor
review → fix loop on ConferenceOS PRs #1616/#1617, unaware that the repo's
primary coordinator (the launchd roster — the ONE coordinator for this repo
per docs/13) was independently also working the same PRs on its own hourly
cycle. The primary coordinator's own review completed and merged both PRs
first. Separately, a THIRD agent (Devin) pushed one more commit onto the
#1617 branch after the second session's last reviewed head — a benign 1-line
test-isolation fix, but it meant the actually-merged commit was never
reviewed by the loop the second session ran; it was covered only by the
primary coordinator's own (different, valid) review pass.
**Root cause:** "Count before you add" (docs/13) was not checked before
dispatching — the second session had no visibility into whether a coordinator
already owned these PRs, and the lane-collision surface (any agent, including
Devin, can push to an open PR branch with no ownership arbiter) compounded it.
**Harness fix:** before dispatching a review/fix loop onto an open PR, check
for signs of an existing owning coordinator (recent bot activity, an
attestation comment, a merge that lands mid-loop) — the same signals
`lane-check.sh` already checks for claiming a NEW issue apply to reviewing an
EXISTING PR too. No product harm resulted here, but the second session's
review rounds 1-3 were fully redundant work once the primary coordinator's
own cycle picked the PRs up.
**Status:** no fix needed beyond the existing "count before you add" doctrine
(docs/13) — logged because the collision was real and the doctrine wasn't
checked, not because the doctrine was wrong
**Tags:** #concurrency #coordination #fleet #devin

## L-061 · 2026-08-19 · empty-agent-output-diagnosis
**What happened:** A delegated Codex/Grok review that produces no verdict has four distinct causes — quota, a crashing MCP server, oversized tool input, and untrusted-directory refusal — and exit code 0 does not mean it worked.
A delegated review that returns **no analysis** has at least four causes. They look
identical from the shell, and **`codex exec` exits 0 on most of them** — never treat a
zero exit or a plausible-looking log as a passing review.

1. **Quota** (2026-08-04) — `ERROR: You've hit your usage limit`, landing in the *tail of
   an earlier* file, not the empty one. Quota windows roll; test rather than trust the
   stated reset time.
2. **A crashing MCP server** (2026-08-19) — `rmcp::transport::worker: worker quit with
   fatal: Transport channel closed, when AuthRequired`. One bad server kills the whole
   session mid-run. Cost three reviews before it was spotted. Fix: `enabled = false` on
   that server in `~/.codex/config.toml`.
3. **Oversized tool-read input** (2026-08-19) — asking Codex to read a ~100KB diff via a
   tool call at `xhigh` reasoning ends the run right after the tool output: no final
   message, no `tokens used` marker, **exit 0**. Inline the content instead, and split it.
4. **Untrusted directory** (2026-08-19) — `Not inside a trusted directory and
   --skip-git-repo-check was not specified`, a 115-byte log, exit 1. Happens whenever the
   dispatcher does not `cd` into a repo first.

**Why it matters:** each of these can be reported as "the reviewer found nothing," which
is the worst possible failure — it converts a broken tool into false assurance on a PR.

**How to apply:** dispatch through **`~/.claude/fleet/codex-review.sh`**, which inlines the
content, refuses input over 30KB, passes `--skip-git-repo-check`, and — the point of it —
**requires a `VERDICT:` line outside the echoed prompt**, exiting non-zero and saying
"do NOT report this as a passing review" when there isn't one. A healthy completed run ends
with a `tokens used` line; its absence is the tell. Cheap liveness check first:
`codex exec -s read-only "Reply with exactly: PONG" < /dev/null`.

Related: [[feedback_mission_control_fleet_routing]], [[feedback_never_verify_with_the_authors_example]].
**Harness fix:** dispatch through **`~/.claude/fleet/codex-review.sh`**, which inlines the content, refuses input over 30KB, passes `--skip-git-repo-check`, and — the point of it — **requires a `VERDICT:` line outside the echoed prompt**, exiting non-zero and saying "do NOT report this as a passing review" when there isn't one. A healthy completed run ends with a `tokens used` line; its absence is the tell. Cheap liveness check first: `codex exec -s read-only "Reply with exactly: PONG" < /dev/null`.
**Status:** intake 2026-09-04 from fleet memory `feedback_empty_agent_output_diagnosis.md` (no sensor yet)
**Tags:** #codex #diff #fleet #grok #intake #liveness #review

## L-062 · 2026-08-09 · backgrounded-cli-agents-not-dead
**What happened:** A backgrounded grok/codex run that prints nothing and 'exits' is usually still alive — ps before re-dispatching, or you get concurrent writers in one worktree.
Backgrounding `grok --always-approve -p` or `codex exec` with `nohup … &` produces a run
that looks dead within seconds: the wrapper returns, the log holds 0–200 bytes, and the
harness reports the command completed with exit code 0. **The agent is usually still
running.** Output is buffered and only flushes much later.

On 2026-08-09 this caused a real collision on the conferenceos-website test-suite lane. Two
Grok runs launched 40 seconds apart both looked dead, so a third worker (a Claude subagent)
was dispatched into the same worktree. All three wrote concurrently — files were replaced
wholesale mid-edit and a `tests/` tree was deleted out from under its own author. The
subagent caught it by running `ps` and refused to add a fourth writer.

**Why:** the "empty output = dead" heuristic from [[feedback_empty_agent_output_diagnosis]]
covers quota exhaustion, where the process really is gone. Buffered-but-alive looks
identical from the log alone, and the harness's completion notification describes the
*wrapper*, not the agent. Trusting it violates the one-working-directory-per-agent rule in
`~/.claude/FLEET.md` in the one way that rule exists to prevent.

**How to apply:** before re-dispatching to the same directory, run
`ps -eo pid,lstart,command | grep -E "codex exec|grok --always"` and confirm nothing is
alive. If something is, either wait or `kill` it deliberately — do not add a writer. Prefer
one owner per worktree over racing two vendors at the same task; when a dispatch genuinely
needs replacing, kill the old PID first and reset the worktree (`git checkout --`) so the
new owner starts from a known state rather than someone else's half-finished edits.

Related: [[feedback_mission_control_fleet_routing]], [[feedback_delegate_coding_to_grok]].
**Harness fix:** before re-dispatching to the same directory, run `ps -eo pid,lstart,command | grep -E "codex exec|grok --always"` and confirm nothing is alive. If something is, either wait or `kill` it deliberately — do not add a writer. Prefer one owner per worktree over racing two vendors at the same task; when a dispatch genuinely needs replacing, kill the old PID first and reset the worktree (`git checkout --`) so the new owner starts from a known state rather than someone else's half-finished edits.
**Status:** intake 2026-09-04 from fleet memory `feedback_backgrounded_cli_agents_not_dead.md` (no sensor yet)
**Tags:** #codex #fleet #grok #intake #lane #pid #worktree

## L-063 · 2026-08-16 · timed-out-post-may-have-landed
**What happened:** A timed-out tool call that POSTs can still succeed server-side — verify before retrying
Two browser `javascript_tool` calls that POSTed to Mission Control's /api/tasks timed
out client-side (30s, pane hidden) but BOTH succeeded server-side; a third retry via
curl then made three duplicate tasks, and the dispatcher started two Grok runners in
the same worktree (2026-08-16).

**Why:** tool timeout ≠ request failure. Side-effectful requests (POST/PATCH) can land
after the tool gives up.

**How to apply:** after ANY timed-out call that had side effects, first QUERY for the
effect (list tasks, check the resource) before retrying. For queues specifically,
prefer idempotency: include a client-generated key in the title/description and check
for it. Related: [[project-mission-control-gibson-view]].
**Harness fix:** after ANY timed-out call that had side effects, first QUERY for the effect (list tasks, check the resource) before retrying. For queues specifically, prefer idempotency: include a client-generated key in the title/description and check for it. Related: [[project-mission-control-gibson-view]].
**Status:** intake 2026-09-04 from fleet memory `feedback_timed_out_post_may_have_landed.md` (no sensor yet)
**Tags:** #fleet #grok #intake #worktree

## L-064 · 2026-08-17 · codex-exec-stdin-hang
**What happened:** codex exec hangs forever on \"Reading additional input from stdin...\" when launched without a closed stdin — redirect </dev/null.
`codex exec -s read-only "<prompt>"` can hang indefinitely printing only
`Reading additional input from stdin...` even though the prompt was passed as an
argument. It burns a review slot silently: the process stays alive, the output
file stays 0 bytes, and `ps` shows it running, so it looks like a slow review
rather than a stuck one. Observed 2026-08-16: a cross-vendor review of COS PR
#1360 sat for 26+ hours and produced nothing; exit code 144 on kill, with that
one line as the entire output.

**Why:** the fleet card's dispatch pattern
(`codex exec -s read-only "review the diff in <repo>"`) does not close stdin.
When launched from a non-interactive/backgrounded shell, codex waits on stdin
for more prompt text that never arrives.

**How to apply:** always redirect stdin when dispatching codex non-interactively —
`codex exec -s read-only --cd <dir> "<prompt>" < /dev/null`. When a codex lane
produces 0 bytes, check the output file for the stdin line *before* assuming a
quota limit (see [[feedback_empty_agent_output_diagnosis]]) — the two failure
modes look identical from `ps` but have different fixes. Related:
[[feedback_backgrounded_cli_agents_not_dead]], [[feedback_mission_control_fleet_routing]].
**Harness fix:** always redirect stdin when dispatching codex non-interactively — `codex exec -s read-only --cd <dir> "<prompt>" < /dev/null`. When a codex lane produces 0 bytes, check the output file for the stdin line *before* assuming a quota limit (see [[feedback_empty_agent_output_diagnosis]]) — the two failure modes look identical from `ps` but have different fixes. Related: [[feedback_backgrounded_cli_agents_not_dead]], [[feedback_mission_control_fleet_routing]].
**Status:** intake 2026-09-04 from fleet memory `feedback_codex_exec_stdin_hang.md` (no sensor yet)
**Tags:** #codex #diff #fleet #intake #lane #review #stdin

## L-065 · 2026-09-04 · never-reconstruct-sha-from-short-form
**What happened:** Never write a full-length SHA you have not read verbatim from a command — reconstructing one from an abbreviated form fabricates an identifier.
**Never write out a 40-character SHA unless the exact string was read verbatim from a
command's output in this session.** If only the abbreviated form is on hand (`git rev-parse
--short`, `git log --oneline`, a `${SHA:0:8}` in a status table), fetch the full value
before using it:

```bash
gh pr view <n> --repo <owner/repo> --json headRefOid -q .headRefOid
git rev-parse HEAD
```

Happened 2026-08-18 on conference-os PR #1393: only `1edb22a9` had ever been printed, and a
full-length `1edb22a9e1e0e0d1cb8e93c0b7d0e0a6a5a06f9c` was written into an
`owner-review-attestation:v1` block. The real head was `1edb22a914e828010c8b09ec5490f2bfd5992a0d`
— first eight characters right, remaining thirty-two invented. It required a public
retraction on the PR.

**Why:** attestation, `--match-head-commit`, and `--force-with-lease` all take a full SHA.
The gates match exactly, so a fabricated value fails closed and authorizes nothing — the
damage is a false cryptographic identifier in a permanent audit record, not a bad merge.
Inert is not the same as harmless.

**How to apply:** any command or comment containing a 40-char hex string must have that
string flow from a captured variable or a command substitution, never from composition.
Prefer `SHA=$(gh pr view ... -q .headRefOid)` and interpolate `$SHA`. When a SHA must be
typed into prose (a PR comment, a commit message), print it first and copy from that output.

The same rule covers any opaque identifier that cannot be validated by inspection —
installation IDs, deployment IDs, tokens, migration directory timestamps.

Related: [[project_cos_pr_gate_fields]], [[feedback_never_gh_pr_update_branch_cos]],
[[project_cos_attestation_self_review_block]].
**Harness fix:** any command or comment containing a 40-char hex string must have that string flow from a captured variable or a command substitution, never from composition. Prefer `SHA=$(gh pr view ... -q .headRefOid)` and interpolate `$SHA`. When a SHA must be typed into prose (a PR comment, a commit message), print it first and copy from that output.
**Status:** intake 2026-09-04 from fleet memory `feedback_never_reconstruct_sha_from_short_form.md` (no sensor yet)
**Tags:** #fleet #intake #merge #review #sha

## L-066 · 2026-09-04 · lane-check-before-claim
**What happened:** Run lane-check.sh before claiming a conference-os issue — worktree lists and open PRs are lagging signals.
Before claiming or dispatching any conference-os issue, run
`FLEET_DRIVER=<task-name> ~/.claude/fleet/lane-check.sh --claim <issue>`.
Exit 1 means taken. Never decide an issue is free from `git worktree list` or
the open-PR list alone.

**Why:** both signals lag reality. On 2026-08-18 `lane-1397` had a worktree and
two commits at 14:59, but its PR did not exist and the canonical checkout did
not register the worktree until 15:47. `cos-backlog-driver` claimed the same
issue at 15:35 against both signals while both were silent, then had to retract
the claim publicly. `ata-launch-driver` and `cos-backlog-driver` are separate
scheduled tasks driving the same repo, so a peer driver is always assumed live.

**How to apply:** the script checks six signals — worktree dirs on disk, local
branches, remote branches, open PRs, live grok/codex processes, and a shared
intent registry at `~/.claude/fleet/claims/` covering the window before any of
the rest exist. Claims are atomic (noclobber) and advisory; one older than 12h
reports stale. Release with `--release <issue>` when the PR opens. If you
override a hit, name which hit and why — never silently. Wired as mandatory into
both driver SKILL.md files and documented in [[fleet-card-discovery]].
Related: [[feedback-mission-control-fleet-routing]], [[feedback-space-per-repo]].
**Harness fix:** the script checks six signals — worktree dirs on disk, local branches, remote branches, open PRs, live grok/codex processes, and a shared intent registry at `~/.claude/fleet/claims/` covering the window before any of the rest exist. Claims are atomic (noclobber) and advisory; one older than 12h reports stale. Release with `--release <issue>` when the PR opens. If you override a hit, name which hit and why — never silently. Wired as mandatory into both driver SKILL.md files and documented in [[fleet-card-discovery]]. Related: [[feedback-mission-control-fleet-routing]], [[feedback-space-per-repo]].
**Status:** intake 2026-09-04 from fleet memory `feedback_lane_check_before_claim.md` (no sensor yet)
**Tags:** #claim #codex #fleet #grok #intake #lane #worktree

## L-067 · 2026-09-04 · never-verify-with-the-authors-example
**What happened:** Never confirm a doc comment or PR claim using the example that claim supplies — pick the adversarial case the author didn't choose.
**When code claims a property, verify it with an input the author did not pick.** Reusing
the example from the doc comment or PR description restates the claim; it does not test it.
Authors choose examples that work.

Cost, 2026-08-18, conference-os PR #1393. `findUnresolvedLegalPlaceholders` matched
`/\[([A-Z][A-Z0-9]+(?:[ _-][A-Z0-9]+)*)\]/g` and its comment said requiring ALL-CAPS keeps
markdown links safe, citing `[Privacy Policy](/privacy)`. The attestation repeated that
example and passed. But it only passes because it is *mixed case*. An ALL-CAPS label —
`[FAQ](/faq)`, `[GDPR](/gdpr)`, `[CCPA](/ccpa)`, i.e. exactly how legal documents cite
regulations — still matches and is wrongly reported as an unresolved placeholder. Filed as
#1401 after the PR had merged. Effect: an organizer whose Terms cite GDPR is blocked from
go-live by the readiness gate that PR introduced.

**How to apply:** for any claimed invariant, spend thirty seconds building the case that
breaks it before agreeing.
- Regex "only matches X" -> feed it the near-miss that is *almost* X.
- "Handles timezones" -> pick a zone where host, UTC, and target all disagree.
- "Additive only" -> diff it, do not read the summary.
- Boundary claims -> test the boundary value itself, not one comfortably inside.

A one-line node/python probe against the real function beats reasoning about it. The four
defects found in this session's own work all survived reasoning and died to a probe.

Related: [[feedback_never_reconstruct_sha_from_short_form]], [[ai_verification_language]],
[[project_cos_pr_gate_fields]].
**Harness fix:** for any claimed invariant, spend thirty seconds building the case that breaks it before agreeing. - Regex "only matches X" -> feed it the near-miss that is *almost* X. - "Handles timezones" -> pick a zone where host, UTC, and target all disagree. - "Additive only" -> diff it, do not read the summary. - Boundary claims -> test the boundary value itself, not one comfortably inside.
**Status:** intake 2026-09-04 from fleet memory `feedback_never_verify_with_the_authors_example.md` (no sensor yet)
**Tags:** #claim #diff #fleet #gate #intake

## L-068 · 2026-09-04 · verify-worker-by-pid-before-regating
**What happened:** Before gating, committing, or re-dispatching on a worker's worktree, confirm the worker exited by PID — a long `-p` prompt truncates ps/pgrep pattern matches and makes a live Grok look dead
2026-08-21: a Grok lane on chatterbuilt #521 looked finished (git showed 10 changed files, my
`ps | grep` showed no matching process) so I ran the gate on its tree and dispatched a second Grok
into the same worktree. The first Grok (pid 6466) was still running — the prompt passed via `-p`
is long and contains an em-dash, so my pattern-based grep missed it. Two agents in one checkout
for ~2 seconds before I killed the duplicate.

**Why:** `ps`/`pgrep -f` pattern matches against a multi-KB argv are fragile (truncation, unicode,
parentheses). Git state cannot tell you whether a worker is done; only the process can.

**How to apply:** capture the worker's PID at dispatch (`$!` or `pgrep -n -f grok`), and wait with
`kill -0 $pid` — never a text pattern. Do not gate, commit, or re-dispatch on a worktree until that
PID is gone AND the worker's log shows its final summary. An almost-empty log with changed files
means "still running", not "done quietly". Related: [[feedback_backgrounded_cli_agents_not_dead]],
[[feedback_lane_check_before_claim]].
**Harness fix:** capture the worker's PID at dispatch (`$!` or `pgrep -n -f grok`), and wait with `kill -0 $pid` — never a text pattern. Do not gate, commit, or re-dispatch on a worktree until that PID is gone AND the worker's log shows its final summary. An almost-empty log with changed files means "still running", not "done quietly". Related: [[feedback_backgrounded_cli_agents_not_dead]], [[feedback_lane_check_before_claim]].
**Status:** intake 2026-09-04 from fleet memory `feedback_verify_worker_by_pid_before_regating.md` (no sensor yet)
**Tags:** #fleet #gate #grok #intake #lane #pid #worktree

## L-069 · 2026-09-04 · never-wait-on-review-evidence
**What happened:** A merge chain must not wait for "no pending checks" before attesting — review-evidence only clears after the attestation, so the wait can never be satisfied
2026-08-21: I wrote merge chains as `wait until no check is pending → attest → merge`. On
ConferenceOS that deadlocks: `review-evidence` is a required context that stays **pending until
the owner attestation comment is posted**, so the precondition can never be met. #1471 and #1473
both sat with Codex APPROVE and every other context green while their watchers spun.

**Why:** `review-evidence` is not a CI result — it is the gate's record of *human/authorized*
evidence at the exact head. Treating it like a build step inverts cause and effect.

**How to apply:** wait only on the *machine* contexts — `quality`, `build-e2e-required`, `DCO`
(plus `sast` / `Neon schema rehearsal` when they apply) — then post the attestation, then poll
`repos/$R/commits/<sha>/status` for `review-evidence == success`, then merge with
`--match-head-commit`. Also: the red **`Evaluate review evidence (trusted base)`** *check-run* is
the #1458 cancellation artifact and is not the gate; the required target is the `review-evidence`
**commit status**. Related: [[project_cos_pr_gate_fields]], [[feedback_review_evidence_trusted_rejection]],
[[project_cos_branch_protection_truth]].
**Harness fix:** wait only on the *machine* contexts — `quality`, `build-e2e-required`, `DCO` (plus `sast` / `Neon schema rehearsal` when they apply) — then post the attestation, then poll `repos/$R/commits/<sha>/status` for `review-evidence == success`, then merge with `--match-head-commit`. Also: the red **`Evaluate review evidence (trusted base)`** *check-run* is the #1458 cancellation artifact and is not the gate; the required target is the `review-evidence` **commit status**. Related: [[project_cos_pr_gate_fields]], [[feedback_review_evidence_trusted_rejection]], [[project_cos_branch_protection_truth]].
**Status:** intake 2026-09-04 from fleet memory `feedback_never_wait_on_review_evidence.md` (no sensor yet)
**Tags:** #attest #ci #codex #fleet #gate #intake #merge #review #sha

## L-070 · 2026-09-04 · guards-must-prove-not-assert
**What happened:** The fleet's recurring defect class — a guard whose claim is broader than what it proves; check what is persisted, not what a caller asserts.
Every ConferenceOS guard defect in the 2026-08-21 batch was one shape: **a guard whose claim is
broader than what it proves.** Named instances:

- **#1469 / PR #1482** — verified a caller-supplied `sourcePath` *label*, not the value. A company
  invented in code passed by claiming a manifest-listed path. Fixed by requiring the value to occur
  in the manifest-listed file. Then round 4 found it coerced the value *twice* — compared one form,
  returned another — so compared ≠ persisted again.
- **#1470 / PR #1478** — `isProductionDatabaseHost()` returned `false` when parsing failed, making
  "cannot parse" and "is safe" the same branch. Also defaulted to a host set omitting demo
  production, so the resolver printed a full `DATABASE_URL` **with password** to stdout.
- **#1485 / PR #1486** — the ratchet built to catch this class *reproduced it*: a `Mutation-proof:`
  marker requires an author to **name** a test, never that the test would fail. Provenance by
  assertion again. Real enforcement filed as #1487.

**How to apply:** when reviewing or designing a guard, ask what it *executes*, not what it accepts.
Prefer output-level assertions (run the thing, inspect what was persisted) over source-text or
syntax-position proxies. Treat these as automatic red flags:
- a check that reads a value the caller supplies as evidence about that same caller;
- any value coerced/normalized more than once between the check and the write;
- `return false` / `return safe` on a parse or lookup failure — failure must refuse;
- a gate that cannot fail without someone choosing to make it fail;
- a sensor that does not include its own enforcement files in its scope.

**Why:** none of these were caught by CI. All were caught by a careful reader or an adversarial
cross-vendor review, usually 3–5 rounds in. Prose and markers bind only cooperating agents.
See [[feedback_never_verify_with_the_authors_example]] and [[feedback_cos_sensors_fix_at_source]].
**Harness fix:** when reviewing or designing a guard, ask what it *executes*, not what it accepts. Prefer output-level assertions (run the thing, inspect what was persisted) over source-text or syntax-position proxies. Treat these as automatic red flags: - a check that reads a value the caller supplies as evidence about that same caller; - any value coerced/normalized more than once between the check and the write; - `return false` / `return safe` on a parse or lookup failure — failure must refuse; - a gate that cannot fail without someone choosing to make it fail; - a sensor that does not include its own enforcement files in its scope.
**Status:** intake 2026-09-04 from fleet memory `feedback_guards_must_prove_not_assert.md` (no sensor yet)
**Tags:** #ci #claim #fleet #gate #intake #review #sensor

## L-071 · 2026-09-04 · never-chunk-a-coherent-diff
**What happened:** Chunking one logical change for review yields a graceful refusal that reads like a pass; send it whole with a raised cap.
`codex-review.sh` refuses input over `CODEX_REVIEW_MAX_BYTES`. The tempting fix — split the diff —
is wrong for a single logical change, and it has now cost real safety, not just rounds.

**The evidence (2026-08-21, ConferenceOS PR #1478).** The diff was sent in chunks. Codex returned
`REFUTE` on the allowlist/resolver chunk — a *graceful refusal to verdict*, which reads like
"nothing blocking here." Re-sent as ONE WHOLE PACKET with the cap raised, the same reviewer on the
same code returned `REQUEST_CHANGES` with four findings, including a path that printed a production
`DATABASE_URL` with its password to stdout. **Chunking produced a verdict that looked like a pass
and was not one.** Same failure had already appeared on #1472 and #1482.

**How to apply:**
- Split a diff ONLY where the parts are genuinely independent (unrelated files, separable concerns).
- For one coherent change that exceeds the cap, raise `CODEX_REVIEW_MAX_BYTES` for that invocation
  and send it whole.
- `REFUTE` / any non-`VERDICT:` output is **not** a pass. Read the last `VERDICT:` line; if it is
  the prompt echo, there was no verdict — diagnose, do not report a pass.
- A bare `PASS` without the `VERDICT:` prefix is also not a verdict. Re-run stating the format
  requirement rather than reading it generously — see [[feedback_never_wait_on_review_evidence]].
**Harness fix:** - Split a diff ONLY where the parts are genuinely independent (unrelated files, separable concerns). - For one coherent change that exceeds the cap, raise `CODEX_REVIEW_MAX_BYTES` for that invocation and send it whole. - `REFUTE` / any non-`VERDICT:` output is **not** a pass. Read the last `VERDICT:` line; if it is the prompt echo, there was no verdict — diagnose, do not report a pass. - A bare `PASS` without the `VERDICT:` prefix is also not a verdict. Re-run stating the format requirement rather than reading it generously — see [[feedback_never_wait_on_review_evidence]].
**Status:** intake 2026-09-04 from fleet memory `feedback_never_chunk_a_coherent_diff.md` (no sensor yet)
**Tags:** #codex #diff #fleet #intake #review

## L-072 · 2026-09-04 · one-mutation-proves-one-mutation
**What happened:** A mutation proof establishes only the mutation you performed — never read one red test as proving the whole class.
Mutation-proving a test (break it → red → restore → green) is the right way to show a test is not
vacuous. The trap is reading ONE red as proof of the class. It happened twice on 2026-08-21:

- **PR #1486** — I mutated the workflow step with `continue-on-error: true`, saw 2 tests go red, and
  called the "step is blocking" assertion proven. Codex then listed `if: ${{ false }}`,
  `run: true || node …`, `run: node … || :`, and a skipped decoy job — all pass the assertion.
- **PR #1462** — I appended a canonical `function githubIfRuns()` and saw 4 tests red. Codex's words:
  *"the coordinator's mutation confirms the canonical spelling is caught, but not the broader
  invariant"* — indentation, `async function`, `export const`, typed/destructured bindings, a
  differently-named copy, and a third-file helper all evade it.

**How to apply:**
- Enumerate the evasion space FIRST, then mutate one case per branch you intend to claim. If the
  space is open-ended (YAML step neutralization, regex-based source checks), pattern matching is the
  wrong mechanism — either use a syntax-aware check (the repo already parses with the TypeScript
  AST) or narrow the assertion's stated guarantee to exactly the forms it detects.
- Validate the mutated artifact before believing the red. A `perl`/`sed` edit that corrupts YAML or
  syntax produces a red that proves nothing — on #1486 my first attempt inserted mid-line and the
  failures were parse noise. Re-check with a real parser, then re-run.
- An honest narrow claim beats an overstated broad one. Say which forms are covered and which are not.

**Why:** every finding in this batch was some version of claiming more than was proven — see
[[feedback_guards_must_prove_not_assert]] and [[feedback_never_verify_with_the_authors_example]].
**Harness fix:** - Enumerate the evasion space FIRST, then mutate one case per branch you intend to claim. If the space is open-ended (YAML step neutralization, regex-based source checks), pattern matching is the wrong mechanism — either use a syntax-aware check (the repo already parses with the TypeScript AST) or narrow the assertion's stated guarantee to exactly the forms it detects. - Validate the mutated artifact before believing the red. A `perl`/`sed` edit that corrupts YAML or syntax produces a red that proves nothing — on #1486 my first attempt inserted mid-line and the failures were parse noise. Re-check with a real parser, then re-run. - An honest narrow claim beats an overstated broad one. Say which forms are covered and which are not.
**Status:** intake 2026-09-04 from fleet memory `feedback_one_mutation_proves_one_mutation.md` (no sensor yet)
**Tags:** #claim #codex #fleet #intake

## L-073 · 2026-09-04 · unstable-is-not-blocked
**What happened:** A PR in UNSTABLE is mergeable — only NON-required checks are red; judge by the required contexts, never the rollup.
`mergeStateStatus` rollups mislead. On 2026-08-22 two ConferenceOS PRs (#1468, #1490) sat unmerged
while **all four required contexts were green**, because `UNSTABLE` was read as "blocked".

- **BLOCKED** — a required context is failing/pending, or an owner gate is unsatisfied.
- **UNSTABLE** — mergeable; some NON-required check is red.
- **CLEAN** — everything green.

ConferenceOS `main` requires exactly: `quality`, `build-e2e-required`, `DCO`, `review-evidence`.
Re-query it (`gh api repos/<o>/<r>/branches/main/protection --jq '.required_status_checks.contexts'`)
rather than trusting memory — it changes.

Routinely-red NON-required checks that must never stop a merge: `Evaluate review evidence (trusted
base)` when its runs were **cancelled** (COS #1458), `Agent quality sensors` while a sensor bug is
being fixed, `Vercel – conference-os-demo` / `-ata` (intentional Ignored Build Step, #1391), `triage`
and `Neon schema rehearsal` when *skipping*.

**How to apply:** before concluding a PR is blocked, list the required contexts and check each one.
`~/.claude/fleet/pr-queue-watch.sh` does this per PR and buckets them. See
[[feedback_never_wait_on_review_evidence]].
**Harness fix:** before concluding a PR is blocked, list the required contexts and check each one. `~/.claude/fleet/pr-queue-watch.sh` does this per PR and buckets them. See [[feedback_never_wait_on_review_evidence]].
**Status:** intake 2026-09-04 from fleet memory `feedback_unstable_is_not_blocked.md` (no sensor yet)
**Tags:** #fleet #gate #intake #merge #review #sensor

## L-074 · 2026-09-04 · lane-branch-must-be-the-pr-head
**What happened:** Create a lane worktree ON the PR's head branch — branching off it orphans the work and makes attestations name a SHA the PR does not have.
On 2026-08-22 I created a lane with
`git worktree add ~/Code/lane-1468 -B fix/1458-preview-smoke-cancel origin/<PR head branch>` —
a NEW branch off the PR's head branch. Four review rounds, several pushes and an owner attestation
later, PR #1468's head was still the original commit: the work was on a branch the PR did not track,
and the attestation named a SHA that was not the PR head, so `review-evidence` correctly refused it.

**How to apply:**
- Take the head branch name from the PR and USE it:
  `git worktree add ~/Code/lane-<n> -B "$(gh pr view <n> --json headRefName --jq .headRefName)" "origin/$(gh pr view <n> --json headRefName --jq .headRefName)"`.
- Before attesting, assert the PR head equals the SHA you are attesting:
  `gh pr view <n> --json headRefOid` must match `git rev-parse HEAD` in the lane.
- Recovery, if it already happened: if your branch is a strict superset
  (`git merge-base --is-ancestor <pr-head> <your-branch>`), fast-forward the PR's real head branch
  with `bot-push.sh` — never `gh pr update-branch`, which lands as the owner
  ([[feedback_never_gh_pr_update_branch_cos]]).

Related: [[feedback_never_reconstruct_sha_from_short_form]].
**Harness fix:** - Take the head branch name from the PR and USE it: `git worktree add ~/Code/lane-<n> -B "$(gh pr view <n> --json headRefName --jq .headRefName)" "origin/$(gh pr view <n> --json headRefName --jq .headRefName)"`. - Before attesting, assert the PR head equals the SHA you are attesting: `gh pr view <n> --json headRefOid` must match `git rev-parse HEAD` in the lane. - Recovery, if it already happened: if your branch is a strict superset (`git merge-base --is-ancestor <pr-head> <your-branch>`), fast-forward the PR's real head branch with `bot-push.sh` — never `gh pr update-branch`, which lands as the owner ([[feedback_never_gh_pr_update_branch_cos]]).
**Status:** intake 2026-09-04 from fleet memory `feedback_lane_branch_must_be_the_pr_head.md` (no sensor yet)
**Tags:** #fleet #intake #lane #merge #review #sha #worktree

## L-075 · 2026-09-04 · pr-base-sha-is-frozen
**What happened:** A PR's base SHA is fixed when the PR opens — never load CI-gate code from it, or a stale-base PR bypasses the gate.
`github.event.pull_request.base.sha` is frozen at PR-open time and does NOT advance when the base
branch does. Two consequences, both hit on 2026-08-22:

1. **A new CI step that executes code from the frozen base crashes on every older PR.** COS #1486 ran
   its analyzer from the `trusted-base` checkout; every PR opened before it merged had a base without
   the script — `ERR_MODULE_NOT_FOUND`, whole sensor job red, all in-flight PRs at once.
2. **"Skip when the tool is absent from the base" is a REACHABLE BYPASS.** An author pushes a new head
   to any still-open pre-gate PR; the `synchronize` run keeps the old base, the skip fires, and the
   REQUIRED check reports success **without analyzing the new head**. Works from a fork. Telling the
   author to rebase does not help — rebasing the head does not move the frozen base.

**How to apply:** execute gate code from a ref guaranteed to contain it — for `pull_request_target`
that is `github.sha` (the execution commit / base-branch tip) — and pass the frozen `base.sha` only as
COMPARISON DATA. The fix that landed is COS #1494. Install the runtime in that checkout (`npm ci`) and
make both SHAs resolvable, failing loudly if they are not: "cannot run" must never equal "passed"
([[feedback_guards_must_prove_not_assert]]).
**Harness fix:** execute gate code from a ref guaranteed to contain it — for `pull_request_target` that is `github.sha` (the execution commit / base-branch tip) — and pass the frozen `base.sha` only as COMPARISON DATA. The fix that landed is COS #1494. Install the runtime in that checkout (`npm ci`) and make both SHAs resolvable, failing loudly if they are not: "cannot run" must never equal "passed" ([[feedback_guards_must_prove_not_assert]]).
**Status:** intake 2026-09-04 from fleet memory `feedback_pr_base_sha_is_frozen.md` (no sensor yet)
**Tags:** #ci #fleet #gate #intake #sensor #sha

## L-076 · 2026-09-04 · jointly-unsatisfiable-rules
**What happened:** Two individually-correct rules can be jointly unsatisfiable — when a rule "keeps being forgotten", check whether following it is actually possible.
On 2026-08-22 ConferenceOS lanes were drifting 69, 105 and 130 commits behind main, producing CI
failures whose messages named entirely the wrong cause (a missing lockfile that was present; a
missing export that existed). It looked like agents kept forgetting to sync.

They could not sync. Two rules, each correct:

1. **Keep the lane current with main** — otherwise CI runs current main's workflows and sensors
   against a stale tree.
2. **Push as the lane bot; never push commits authored by the owner** (#925 same-actor check makes
   an owner-authored head un-attestable).

Syncing pulls in main's MERGE commits — and the owner authors those, because the owner merges PRs.
So `bot-push.sh` refused every post-sync push. Following rule 1 made rule 2 impossible. The drift was
the only reachable state.

**The fix was scope, not discipline:** the guard checked the whole push range; it now checks only
commits the PR INTRODUCES (`--not origin/main`), and fails closed to the strict check when
`origin/main` cannot be resolved. Verified both directions — an owner commit arriving from main is
allowed, an owner commit made in the lane is still refused and named.

**How to apply.** When a rule "keeps being violated", or a corrective action keeps not happening,
first ask whether following it is POSSIBLE given the other rules and tooling. Reach for a test that
exercises the two rules TOGETHER, not each alone — both guards passed their own tests. Symptoms that
this is what you are looking at: a step everyone agrees on that never gets done; a tool that refuses
in exactly the situation its companion tool creates; error messages that describe a downstream
symptom rather than the blocked action.

Related: [[feedback_guards_must_prove_not_assert]], [[feedback_never_verify_with_the_authors_example]].
**Harness fix:** none yet — rule is prose; candidate for a sensor
**Status:** intake 2026-09-04 from fleet memory `feedback_jointly_unsatisfiable_rules.md` (no sensor yet)
**Tags:** #ci #fleet #intake #lane #merge

## L-077 · 2026-09-04 · grep-q-pipefail-undercounts
**What happened:** Under `set -o pipefail`, `producer | grep -q` is nondeterministic and silently fails — use `grep -c` (consumes all input) when the result feeds a count or an `&&`.
`grep -q` exits at the FIRST match. If the producer (awk, cat, a long command) is still writing,
it takes SIGPIPE and exits 141; under `set -o pipefail` the whole pipeline is then non-zero, so
`... | grep -q PAT && count=$((count+1))` skips the increment. Whether it happens depends on
buffering, so it looks like a flaky or wrong result, not a bug.

On 2026-08-23 `finding-classes.sh` — the daily learning-loop metric — reported **0** for a class with
**10** real hits this way. A hand-written copy of the same loop gave 10. The instrumented run showed
the counter branch simply never executing.

**How to apply:** in any script with `pipefail`, never put `grep -q` (or `head -n`, `-m1`) at the end
of a pipeline whose exit status matters. Use `hits=$(producer | grep -c PAT)` and test the number —
`grep -c` reads all input, so the producer always finishes cleanly. The fleet tooling tests now assert
the counter has no `grep -q` in its counting pipeline.

Related: [[feedback_guards_must_prove_not_assert]] — a measurement tool that undercounts is the defect
class it exists to measure.
**Harness fix:** in any script with `pipefail`, never put `grep -q` (or `head -n`, `-m1`) at the end of a pipeline whose exit status matters. Use `hits=$(producer | grep -c PAT)` and test the number — `grep -c` reads all input, so the producer always finishes cleanly. The fleet tooling tests now assert the counter has no `grep -q` in its counting pipeline.
**Status:** intake 2026-09-04 from fleet memory `feedback_grep_q_pipefail_undercounts.md` (no sensor yet)
**Tags:** #fleet #intake

## L-078 · 2026-09-04 · reattest-at-live-head
**What happened:** Read the PR head SHA immediately before attesting/reviewing, not from earlier in the session — a PR that gains a commit invalidates a stale attestation and the gate correctly refuses it.
2026-08-23: attested ConferenceOS #1525 at head `3e198997` and could not understand why
`review-evidence` stayed `pending`. The gate was working perfectly — it evaluated the LIVE head
`8fe322a1` (the PR had gained an 18-line lib change + 64 lines of tests after I first read the SHA),
found no attestation matching that head, and stamped pending with "awaiting evidence." Both my
attestation AND the Codex review had been done against the stale `3e198997`.

Root cause: I captured the head SHA early in the session and reused it. Concurrent lanes take time;
a PR's head moves.

**How to apply:**
- Read `gh pr view N --json headRefOid` IMMEDIATELY before dispatching a review, and again immediately
  before attesting. Never reuse a SHA read more than a few minutes earlier.
- Before attesting, assert the independent review was against the CURRENT head, not an earlier one —
  if the head moved since review, re-review the delta first.
- `git diff A..B` can report 0 when the local ref lags; trust `gh api .../compare` or fetch first.
- The gate refusing a stale attestation is CORRECT behavior, not a bug to work around. Do not nudge/
  edit/re-trigger to force it through — fix the SHA.

Related: [[feedback_pr_base_sha_is_frozen]] (base SHA frozen) is the mirror image — this is about the HEAD moving.
**Harness fix:** - Read `gh pr view N --json headRefOid` IMMEDIATELY before dispatching a review, and again immediately before attesting. Never reuse a SHA read more than a few minutes earlier. - Before attesting, assert the independent review was against the CURRENT head, not an earlier one — if the head moved since review, re-review the delta first. - `git diff A..B` can report 0 when the local ref lags; trust `gh api .../compare` or fetch first. - The gate refusing a stale attestation is CORRECT behavior, not a bug to work around. Do not nudge/ edit/re-trigger to force it through — fix the SHA.
**Status:** intake 2026-09-04 from fleet memory `feedback_reattest_at_live_head.md` (no sensor yet)
**Tags:** #codex #diff #fleet #gate #intake #review #sha

## L-079 · 2026-09-04 · scheduler-registration-verify
**What happened:** Cowork scheduled tasks — creation/update can silently fail to register or flip enabled=false; always verify with a list call
The Cowork scheduled-task registry is flaky in three observed ways (2026-08-19):
(1) a SKILL.md directory can exist while the task was never registered — it never
runs and nothing warns (this silently killed ata-launch-driver, cos-backlog-driver,
and auto-remediation-promotion-review from 2026-08-15 for four days);
(2) create_scheduled_task can report success while the task doesn't appear in
list_scheduled_tasks (happened to cos-dispatch-pump);
(3) update_scheduled_task with only prompt/description can flip enabled=false as a
side effect, and unrelated tasks can lose their enabled state during registry churn.

**Why:** "Created" ≠ "scheduled". A dead automation looks identical to a quiet one.

**Update 2026-08-19 14:10:** the registry dropped ALL FIVE velocity tasks a second
time. Root cause pattern: tasks created from inside a scheduled-task run session
do not persist. RESOLUTION: the COS drivers now run on launchd (com.cos.review-pump
hourly, com.cos.backlog-driver 2h, com.cos.launch-driver 4x daily, com.cos.daily-digest
07:32) via ~/.claude/fleet/bin/run-driver.sh, which reads the SKILL.md bodies from
~/.claude/scheduled-tasks/<name>/ — the on-disk prompts remain the source of truth.
Cowork scheduled tasks are NOT used for COS drivers anymore.

**How to apply:** After EVERY create/update/delete of a scheduled task, call
list_scheduled_tasks and verify the task appears with enabled=true and a sane
nextRunAt — and glance at the OTHER tasks' enabled flags too. Periodically diff
`ls ~/.claude/scheduled-tasks/` against the list output to catch orphaned dirs.
**Harness fix:** After EVERY create/update/delete of a scheduled task, call list_scheduled_tasks and verify the task appears with enabled=true and a sane nextRunAt — and glance at the OTHER tasks' enabled flags too. Periodically diff `ls ~/.claude/scheduled-tasks/` against the list output to catch orphaned dirs.
**Status:** intake 2026-09-04 from fleet memory `feedback_scheduler_registration_verify.md` (no sensor yet)
**Tags:** #diff #fleet #intake #review

## L-080 · 2026-08-29 · review-diffs-three-dot
**What happened:** Generate review diffs with three-dot (merge-base) `origin/main...HEAD`, never two-dot — two-dot shows main's newer commits as reversed and produces false FAIL verdicts
On 2026-08-29, PR #1713's Codex review returned a false blocking FAIL ("PR removes resolveDefaultFrom") because the inlined diff was generated with `git diff origin/main..HEAD` after a sibling PR (#1710) had merged to main: two-dot diffs show main-side additions as deletions. A squash merge applies only merge-base-relative changes, so none of it was real.

**Why:** two-dot = direct tree comparison; three-dot = merge-base comparison, which is what actually merges.

**How to apply:** every `codex-review.sh` content diff and any reviewer-facing diff uses `git diff origin/main...HEAD` (three-dot). Better still, merge origin/main into the lane branch before generating the diff — that also pre-empts merge-time conflicts. Related: [[topic-fleet-verification-gotchas]].
**Harness fix:** every `codex-review.sh` content diff and any reviewer-facing diff uses `git diff origin/main...HEAD` (three-dot). Better still, merge origin/main into the lane branch before generating the diff — that also pre-empts merge-time conflicts. Related: [[topic-fleet-verification-gotchas]].
**Status:** intake 2026-09-04 from fleet memory `feedback_review_diffs_three_dot.md` (no sensor yet)
**Tags:** #codex #diff #fleet #intake #lane #merge #review

## L-081 · 2026-08-24 · noop-indistinguishable-from-success
**What happened:** A rehearsal/verification gate a no-op trivially satisfies proves nothing — require a positive attestation from trusted tooling.
A verification gate that checks "did the artifact return to / match a captured
state" is defeated by a **no-op**: if the process under test never ran, the
artifact is unchanged, and the check passes having proven nothing. Found on the
Neon COW schema-rehearsal gate (cos #1529/#1437 round 3): a malicious same-repo PR
could poison `$GITHUB_PATH` / swap `node_modules/.bin` so the migrate/vitest steps
silently no-op, leaving the DB byte-identical to the pre-apply baseline; the
authentic rollback verifier then saw "no reverse diff, schema matches capture" and
went green. The DB was never touched.

**Why:** This is the sharp, testable form of [[feedback_guards_must_prove_not_assert]].
The gate claimed "migrations apply and roll back cleanly" but only proved "the DB
is unchanged," which a no-op satisfies for free. A fresh/isolated runner does NOT
fix it — the missing thing is a *positive* attestation that the expected
post-process state ever existed.

**How to apply:** For any rehearsal/round-trip/rollback gate, require a trusted
positive attestation, not just a match-to-baseline. Apply the untrusted input as
DATA using TRUSTED tooling (don't let the thing under test supply its own verifier
or PATH), capture the expected post-state with trusted tooling, and fail closed
unless the live state equals that trusted post-state BEFORE checking the round-trip.
When reviewing a verifier, always ask: "does a no-op / empty / unchanged input pass
this?" If yes, it is a false-green. Enumerate the evasion space per
[[feedback_one_mutation_proves_one_mutation]].
**Harness fix:** For any rehearsal/round-trip/rollback gate, require a trusted positive attestation, not just a match-to-baseline. Apply the untrusted input as DATA using TRUSTED tooling (don't let the thing under test supply its own verifier or PATH), capture the expected post-state with trusted tooling, and fail closed unless the live state equals that trusted post-state BEFORE checking the round-trip. When reviewing a verifier, always ask: "does a no-op / empty / unchanged input pass this?" If yes, it is a false-green. Enumerate the evasion space per [[feedback_one_mutation_proves_one_mutation]].
**Status:** intake 2026-09-04 from fleet memory `feedback_noop_indistinguishable_from_success.md` (no sensor yet)
**Tags:** #diff #fleet #gate #intake

## L-082 · 2026-08-29 · lane-spec-files-ship-in-bot-commits
**What happened:** bot-commit.sh stages EVERYTHING in the worktree — dispatch artifacts like LANE-SPEC.md get committed and merged to main unless removed first
`~/.claude/fleet/bot-commit.sh` stages the entire worktree before committing. On 2026-08-29, LANE-SPEC.md (the dispatch spec written into the lane worktree root) shipped to conference-os main inside PR #1707's squash, then add/add-conflicted with the sibling lane's spec on #1708's merge-main (resolved by deleting it in the merge commit).

**Why:** the spec file is coordination material, not repo content; two lanes both writing `LANE-SPEC.md` at the worktree root guarantees an add/add conflict the moment one merges.

**How to apply:** keep dispatch specs OUT of the worktree — write them to the scratchpad and pass the path to the implementer — or `git rm --cached`/delete them before running bot-commit.sh. Check `git status --short` for non-source files before every bot-commit. Related: [[topic-fleet-verification-gotchas]].
**Harness fix:** keep dispatch specs OUT of the worktree — write them to the scratchpad and pass the path to the implementer — or `git rm --cached`/delete them before running bot-commit.sh. Check `git status --short` for non-source files before every bot-commit. Related: [[topic-fleet-verification-gotchas]].
**Status:** intake 2026-09-04 from fleet memory `feedback_lane_spec_files_ship_in_bot_commits.md` (no sensor yet)
**Tags:** #fleet #intake #lane #merge #worktree
