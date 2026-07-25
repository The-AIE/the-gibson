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
