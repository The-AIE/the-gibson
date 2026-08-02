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
"ran fine, did nothing" — only "crashed." Consider a stronger sensor: if
`gibson/loop-state.md`'s `updated:` timestamp hasn't advanced after N
iterations, treat that as a failure too, not just non-zero exit.
**Status:** fixed (grok branch); detection-gap fix not yet implemented
**Tags:** #grok #cli #harness-bug #permissions

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
**Status:** fix-pending (the-gibson#4; guide practiced; sensor not yet automated)
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
**Status:** fix-pending (the-gibson#5; convention in use; playbook text not yet patched)
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
**Status:** fix-pending (the-gibson#7)
**Tags:** #concurrency #claims #release #fleet #local

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
**Status:** fix-pending (the-gibson#9; guide practiced on PR #113; sensor not yet)
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
**Status:** fix-pending (the-gibson#4; L-025 evidence commented 2026-07-25)
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
**Status:** fix-pending (the-gibson#10; practiced manual strip on #117)
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
**Status:** fix-pending (guide; practiced on PR #128 and prior same-day ships)
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
**Status:** fix-pending (guide; practiced on PR #154; playbook not yet patched)
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
**Status:** fix-pending (the-gibson#12; practiced on PR #165)
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
**Status:** fix-pending (guide practiced on template PR#7; sensor the-gibson#14)
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
