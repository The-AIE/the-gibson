---
title: "Playbook · Release"
nav_exclude: true
role: release
inputs:
  - approved, all-gates-green PR
  - one independent approval at the exact head + required checks green for Tier C / schema (G12 floor, D-015)
outputs:
  - "merge to integration branch"
  - "verified deploy (commit SHA + READY)"
  - "post-deploy smoke green"
  - "cleanup: worktree, branch, claim, issue closed"
  - "delivery-control audit → dry-run → human-apply when asked"
gates:
  - "Closes #N present; contract checkboxes verified"
  - "CI green (gate + tests + security hard-fail)"
  - "one native GitHub APPROVED review at the current head; UX eval pass when applicable"
  - "DCO/Signed-off-by survives squash"
  - "Tier C / schema → G12 floor met (independent approval at the exact head, required checks green)"
  - "one schema merge in flight fleet-wide"
forbidden:
  - "merging Tier C or schema before the G12 floor is met"
  - "more than one schema merge in flight"
  - "force-pushing main"
  - "rotating secrets (G4)"
  - "silent `--apply` without dry-run"
sources:
  - docs/03-roles.md
  - docs/02-sdlc-pipeline.md (stages 7–8)
  - docs/06-quality-gates.md
  - docs/12-vercel.md
  - docs/23-delivery-control.md
  - playbooks/delivery-control.md
---

# Release — dispatch prompt


> **Authority:** Conditionally mandatory dispatch prompt when this role/job is active. Binding commit/PR/merge rules live only in [`AGENTS.md`](../AGENTS.md). Frontmatter `gates:` / `forbidden:` / role outputs are routing mirrors of that contract and must not introduce obligations absent from AGENTS.md.

You are the **release** role. You merge, verify deploy, smoke, and clean up.
You do not re-implement the feature.

**Preflight:** if this merge ships Production (model A main-is-prod, or model B PR
into the production branch), run delivery-control audit first
(`scripts/delivery-control/audit.sh --repo owner/name`). If the write path is
unhealthy, **do not merge** — harden or escalate ([docs/23](../docs/23-delivery-control.md)).

## How to use this

```bash
# Pre-merge verdict (read-only) — run this first; it decides the three calls
# that used to be re-diagnosed by hand on every PR (L-013, L-015/L-021, L-033)
<path-to-gibson>/scripts/release-preflight.sh 123
# Reservation provenance is report-only (`scripts/claim-provenance.mjs`,
# schema gibson.claim-provenance/v1). It does not feed READY/APPROVE, reviewer
# independence, or merge/release authority. A verified empty reservation does
# not launder later ordinary commits. `claim.sh` requires both live snapshots
# to be OPEN; report-only inspection of a stable CLOSED or MERGED PR is allowed.
# Report-only delivery receipt (#160). Not merge, deploy, or canary authority.
node <path-to-gibson>/scripts/delivery-receipt.mjs --help
#
# Post-merge positive canary (#273): after the schema writer/reader land, the
# first new v2 claim must classify exactly one reservation before implementation
# begins. Keep `Refs #<issue>` on that landing PR until the canary succeeds;
# do not close the tracking issue on merge alone. If the canary fails, existing
# claim rollback closes only that new claim.
#
# Required pre-merge: hard-fails partial ships that would still close #N (L-013/L-025).
# Partial is auto-detected from Related-only body or a partial marker; or pass --partial.
# exit 0 READY · 1 BLOCKED · 4 ADMIN-CANDIDATE (pre-launch operator decision)

# Pre-merge checklist (read-only)
MERGE_STATE=$(gh pr view 123 --json headRefOid,baseRefName \
  --jq '[.headRefOid, .baseRefName] | @tsv') || exit 1
IFS=$'\t' read -r MERGE_SHA BASE_REF <<< "$MERGE_STATE"
if [[ ! "$MERGE_SHA" =~ ^[0-9a-f]{40}$ ]] || ! git check-ref-format "refs/heads/$BASE_REF"; then
  echo "Cannot establish a valid PR head and base branch; stop before merging." >&2
  exit 1
fi
gh pr view 123 --json title,body,mergeable,reviewDecision,statusCheckRollup,labels || exit 1
gh pr checks 123 || exit 1

# Merge only after verifying the full checklist for MERGE_SHA.
gh pr merge 123 --squash --delete-branch --match-head-commit "$MERGE_SHA"

# If that fails with a checkout/worktree error, DO NOT force-checkout main here:
# you are probably inside a fleet worktree pinned to a feature branch, and
# yanking it out from under a running lane is Law 3 (L-020). Merge server-side:
gh api --method PUT repos/{owner}/{repo}/pulls/123/merge -f merge_method=squash -f sha="$MERGE_SHA"
# Verify the actual merge commit on this PR's target, including non-main targets.
LANDED_STATE=$(gh pr view 123 --json state,baseRefName,mergeCommit \
  --jq '[.state, .baseRefName, .mergeCommit.oid] | @tsv') || exit 1
IFS=$'\t' read -r PR_STATE LANDED_BASE LANDED_SHA <<< "$LANDED_STATE"
if [[ "$PR_STATE" != "MERGED" || "$LANDED_BASE" != "$BASE_REF" || ! "$LANDED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Cannot verify the PR's merge on its expected target; stop." >&2
  exit 1
fi
git fetch origin "refs/heads/$BASE_REF" || exit 1
git merge-base --is-ancestor "$LANDED_SHA" FETCH_HEAD || exit 1
git show --no-patch --oneline "$LANDED_SHA"

# Verify deploy
# (Vercel auto-deploy; then)
vercel inspect <deployment-url>   # or API
<path-to-gibson>/scripts/posture-probe.sh https://prod.example.com
BASE_URL=https://prod.example.com npx playwright test tests/e2e/smoke/

# Cleanup claim (one slice of a multi-lane issue? add --claim-id issue-42-<slug>)
<path-to-gibson>/scripts/release-claim.sh 42
<path-to-gibson>/scripts/claims-status.sh --issue 42   # expect: no live claims
```

**Dispatch:**
```bash
grok -p "$(cat playbooks/release.md)

PR: #123
Repo: /path/to/target
Canonical: /path/to/target
"
```

---

## Procedure

### Stage 7 — Merge (ordered checklist)

1. Refresh the complete current head/base and introduced range, claims and
   acceptance evidence. All criteria must be verified; preserve DCO and vendor
   provenance across inherited commits and the final squash.
2. Require actual passing code/security checks at the current head. A skipped
   check is not proof it ran. Honor unresolved owner and dependency holds.
3. Read the genuine native APPROVED review from one independent reviewer of
   this head and full introduced range. No unresolved blocking finding may be
   ignored. Stale, partial, dismissed or same-author evidence does not clear
   review; a successful sweep or release-preflight READY is insufficient.
4. Tier C/schema: the same reviewer covers adversarial cases and the G12
   approval/check floor. Serialize schema changes and require the migration
   artifact when applicable; source approval never authorizes a live migration.
5. Verify automatic deployment effects against any active deployment hold.
   Merge serially with the expected-head guard only after all applicable gates
   pass; do not use admin bypass. Verify the resulting target/main SHA and
   permitted post-main checks before counting a source delivery.

Native approval is the normal path. Legacy `VERDICT: APPROVE` /
`VERDICT: REQUEST_CHANGES` adapters remain compatibility inputs, not a second
approval requirement or a replacement for unmet native branch protection.
Follow the staged [rollout](../docs/review-protocol.md#rollout) when the repository
still requires the old review-evidence check. Never mark that check green by assertion.

### Stage 8 — Deploy + verify

When deployment is authorized (a source-only merge leaves deployment held):

1. Deployment exists for expected commit SHA.
2. State reaches **READY** (merge that never deploys = failure).
3. Smoke: non-destructive contract happy-paths + posture probe.
4. Mechanical failure → retry/redeploy; judgment-shaped → escalate with logs.
5. Rollback = promote previous READY deployment; diagnose in a worktree — never
   debug live in prod.

**Docs-only / no product surface (Tier A docs or specs, no Vercel root change):**
skip the READY deploy wait. Smoke is content verification on `origin/main`
after the merge commit lands: `git fetch origin main` then `git show` / grep
the contract tokens the PR claimed (runbook headings, README index entry,
Released marker, etc.). Do not wait on marketing or MCP deploys for a pure
`docs/**` / `specs/**` ship. Product-surface PRs still follow steps 1–5 above
(L-049).

### RELEASE_CMD (when set)

Shell the actual merge to the configured release identity (third vendor —
neither builder nor reviewer). The merge agent must be able to run **Bash and
`gh`**. Claude `acceptEdits` only auto-approves file edits and **blocks**
Bash/gh — that failed the first merge attempt on product-app #311/PR #346
(L-048). Prefer:

```bash
export RELEASE_CMD='claude -p --output-format text --permission-mode bypassPermissions'
```

Always re-verify with `gh pr view <N> --json state,mergedAt,mergeCommit` after
the shell-out returns; do not trust narration alone. Fall through to a direct
merge only if `RELEASE_CMD` is unset.

### Reading the preflight verdict

`release-preflight.sh` is a diagnostic helper, not an independent reviewer.
READY alone cannot establish complete current-head review or authorize a
deployment. ADMIN-CANDIDATE does not authorize bypass. Use the Stage 7 checks
and actual repository protection; identify the missing evidence rather than
requesting a duplicate review when a valid unchanged-range approval exists.

### Cleanup (Law 10)

```bash
<path-to-gibson>/scripts/release-claim.sh <issue>
# removes worktree, deletes branch, drops claim row (signed commit), removes label
```

Before you run it, check the claim table on `origin/main` for **sibling claims** on
the same issue — multi-slice issues ship one slice at a time (L-024):

```bash
git show origin/main:docs/active-work.md | grep -E "issue-([a-z0-9]+-)?<issue>-"
# and/or:
git ls-tree --name-only origin/main docs/claims/ | grep -E "issue-([a-z0-9]+-)?<issue>-"
```

**Bare multi-claim refuse (#65):** if more than one live claim exists for the
issue and you omit `--claim-id`, `release-claim.sh` exits **1** before any
dry-run plan or mutation and prints the exact matching ids (sorted). Pick one
with a **literal** `--claim-id` (never an ERE/glob). A single live claim may
still use the bare form; the script freezes that exact id before cleanup and
never carries a broad issue regex into row deletion. Legacy rows are matched on
the claim-id column only — text in scope/session/notes is inert.

If more than the merged claim is live, name the one you merged; the script then
leaves the sibling rows and keeps `agent-claimed` on the issue:

```bash
release-claim.sh <issue> --claim-id issue-<issue>-<merged-slug>
```

**Claim already merged/closed and no ledger row exists at all (#153).** Current
`claim.sh` records the claim only in the draft PR's body, never in a ledger
row — that PR *is* the claim, from reservation through review to merge or
close. If the ledger genuinely has nothing for this exact id (a plain
`release-claim.sh <issue>` finding nothing to strip is expected here, not a
bug), name the exact claim id and repo and `release-claim.sh` verifies it
directly against that finished PR instead:

```bash
release-claim.sh <issue> --claim-id issue-<issue>-<slug> --repo owner/name
```

This binds the release to the exact issue, claim id, PR number, head branch,
exact head SHA, base repository (re-derived from the PR's own URL, never
trusted from `--repo` alone), cross-repository=false, and terminal state
(MERGED or CLOSED) before touching anything — an **open** PR, ambiguous
matches, a cross-repository/fork PR, a mismatched issue/branch/scope, a
malformed or truncated evidence row, or a `gh` query failure all refuse before
any worktree, branch, or label mutation. A CLOSED PR is never described as
"merged" — MERGED requires a real merge-commit SHA, CLOSED requires the
opposite (no merge-commit SHA at all); either/neither is refused as a
state/evidence mismatch.

Two compatibility rules make this usable on a repository that has real
history. First, the terminal lookup is **candidate-first**: it inspects only
the PRs whose body carries your exact claim id, so one unrelated historical PR
using a pre-#153 body format cannot permanently block every future release.
Second, an exact candidate that *itself* predates the machine markers is read
under a strict **legacy terminal-claim schema**: when both `- Claim scope:`
and `- Issue: #` are entirely absent, the issue comes from exactly one
`Closes #<n>.` line and the scope from exactly one `## Cumulative scope`
section of backticked path bullets. Nothing is invented. A marker-only body,
prose instead of bullets, a missing/duplicated closing line or scope section,
an unsafe path, or a *current*-format body missing one required field all
still refuse — as does a candidate whose `Closes` number disagrees with its
claim id. If your release stops here, fix the PR body; do not weaken the
check.

Only after every identity check above passes does the script prove the
*registered* worktree at the exact expected path (never a default-path guess)
is on that exact branch, is clean (no uncommitted or untracked changes), and
is at that exact head SHA — or, for a real merge, safely contained in the
merge commit. Any failure there — dirty, wrong branch, unregistered directory,
SHA mismatch — leaves the worktree and branch untouched and exits incomplete;
it never `rm -rf`s an unregistered/default-path directory and never
force-removes a dirty worktree. No ledger row is ever invented to make this
work.

Sibling protection still applies, verified with a **fresh** GitHub read taken
after mutation, not a snapshot from before it: a live sibling claim — ledger
row **or** another open PR-body claim for the same issue — keeps
`agent-claimed` until the last one is verified gone. That post-mutation
GitHub read is **fail-closed**: a query failure or a malformed row there
preserves `agent-claimed` and reports incomplete (exit 3) rather than
guessing the claim is gone.

**The PR's identity is bound before it is closed.** `gh pr close` is the first
mutation on this path, so the repository binding *and* the head-branch binding run
before it: the PR's head branch must be exactly the branch this claim id derives from
(`feat/<issue>-<slug>`). An exact claim marker in the body of a PR on an unrelated
branch is not authority to close that PR, and that mismatch is a plain refusal —
**exit 1**, PR still open, no label edit, no worktree or branch touched — including
under `--dry-run`.

**Closing the PR is the release; proving it is a separate step.** When the claim is
still an open PR, `release-claim.sh` closes it and then re-reads that closed PR's
own terminal evidence to bind an exact head SHA before removing anything. If that
terminal read fails, comes back ambiguous, contradicts the PR's own state, **or
returns no row at all**, the run is a **partial mutation** — the claim is released,
but nothing about the worktree or the branches was proven. An absent terminal row
after a close does not mean there is nothing left; it means this run cannot see the
PR it just closed. All of those take the close-only path: worktree, both branch
refs and `agent-claimed` all preserved, `INCOMPLETE`, **exit 3**, and a `RECOVERY:`
line naming the bound re-run to finish the job:

```bash
release-claim.sh <issue> --claim-id issue-<issue>-<slug> --repo owner/name --pr <pr-number>
```

Run that once the evidence reads cleanly and the exact verified cleanup
(registered-worktree proof, head-SHA containment, compare-and-swap branch deletes)
takes over. Because every close-only outcome is `INCOMPLETE`, that path never
removes `agent-claimed` — the only route to a verified label removal after a close
is the exact terminal cleanup that proved the artifacts first. The same evidence
failure **before** any mutation is a plain refusal — exit **1**, nothing done — and
it names which binding failed instead of collapsing into "no live claim". Read the
exit code as: **1 = refused, nothing done; 3 = did part of the work, here is
exactly what is left.**

**A closed PR must really be closed.** The claim inventory only lists a PR while it
carries a well-formed claim marker, so a PR that is still open with its marker
removed or rewritten vanishes from that view and looks exactly like a PR that
closed. After the close, `release-claim.sh` therefore also asks a body-agnostic
open-PR inventory (`pr-claims.sh list-open-numbers`) whether that exact PR number
is still open. If it is — or if that read cannot be completed — the run refuses
success, preserves the label and every artifact, and exits 3.

**The repository has to be the same repository.** All of the above authorizes
deleting a worktree, a branch, and a label, so before any of it runs
`release-claim.sh` proves that the checkout it is cleaning up (`GIBSON_CANONICAL`,
default: cwd) has an origin remote that normalizes to exactly the repository the
PR evidence came from — https, `ssh://`, and scp-like `git@github.com:owner/name.git`
forms all normalize, case-insensitively, with optional port and `.git`. A fork or
a second clone carries the same branch names and the same commits by construction;
that is not identity and it is refused with nothing mutated. If you hit this, you
are almost certainly standing in the wrong checkout — `cd` to the right one, or
pass `GIBSON_CANONICAL=`, rather than reaching for `--repo` to make the message go
away.

**Releasing a claim id that has been used more than once.** A claim id is free
again once its PR is terminal, so a later lane may reuse it. Two terminal PRs then
carry the same id and the id-only lookup refuses as ambiguous — correctly, because
"which one?" genuinely has two answers. Releasing the *current* open claim never
runs into this (that path binds to the PR number it just closed). To release an
older or already-terminal generation by hand, name the PR:

```bash
release-claim.sh <issue> --claim-id issue-<issue>-<slug> --pr <pr-number> --repo owner/name
```

Every check above still applies to that exact PR — naming it narrows the question,
it does not relax the answer.

**Empty ledger is valid only on a real commit ref with a readable tree.** After
the last claim file is gone, `docs/claims/` is untracked in git and
`docs/active-work.md` may be absent — that is zero live claims on a valid
`origin/main` (or main/master) whose tree objects are readable, not a corrupt
ledger. A missing, unborn, or non-commit main/master ref — a commit whose
referenced tree is unavailable/corrupt — or a ledger path that still exists in
the tree but whose blob/object is unreadable/corrupt — is **not** an empty
ledger: the script inspects tree entries first and fails hard **before** any
label mutation. True path absence is allowed; missing live blobs are not.
Cleanup must still complete without inventing a row when the ref is valid, the
tree is readable, and the ledger is empty. Operator paths:

```bash
# Live sibling still owns the issue, but no claim file is on origin/main
# (sibling lane elsewhere, or claim never filed): keep the label explicitly.
# --keep-label verifies agent-claimed is still present on GitHub (exit 3 if
# the product repo is unresolved or the label is absent/unreadable).
release-claim.sh <issue> --repo owner/name --keep-label

# Final completed lane: empty ledger and no live sibling → remove agent-claimed
# (default). Exit 0 only when removal is verified; exit 3 if it is not.
release-claim.sh <issue> --repo owner/name
```

Cross-repo template work records claim ids as `issue-template-<N>-<slug>` in the
monorepo while the issue lives in the template repo (L-036 / L-037):

```bash
GIBSON_CANONICAL=~/Code/monorepo \
  release-claim.sh 5 --prefix template --repo acme/acme-template
```

You do **not** need the canonical checkout on `main`, clean or otherwise — the
claim-row commit happens in a throwaway worktree (L-009).

**Exit 3 means cleanup did not finish** — the claim row or the `agent-claimed`
label postcondition failed and the message says which. Law 10 is not done until
you fix it by hand; an unverified label removal is how #24 stayed claimed
(L-027). **Label removal is gated (#65):** default removal runs only after every
requested target was successfully removed **and** a fresh, fully validated
reread of the **exact remote-tracking ref that received the cleanup push**
(`origin/main` or `origin/master` — same branch the strip pushed to; same
strict ref/tree/blob proofs as #61, plus cleanup-commit lineage) shows no
target and no sibling remain. Post-mutation reread never falls back to local
`main`/`master`, `HEAD`, or a pre-mutation residual plan: a missing or
unreadable `origin/<base>` after a successful push is incomplete, not an empty
ledger. If strip/push fails, a target is still live, fetch or ref/tree/blob
validation fails, the cleanup-pushed SHA is missing/unreadable after a
successful push, cleanup lineage cannot be proven on the exact remote ref, or
the parse is incomplete/ambiguous, the script preserves `agent-claimed`, never
claims the label was removed, and exits 3. Lineage proof after a successful
cleanup push is mandatory — never skippable when the capture SHA is empty. Target absent + sibling present → keep/verify
label; target absent + no sibling → remove/verify unless `--keep-label`.
`--keep-label` is the truthful "no row, sibling still live" path and must
verify the label is still present — a blind success when the label is absent or
unreadable is a false green. Do not invent a claim file just to satisfy cleanup.

Confirm issue closed by `Closes #` or close explicitly.

### Human-gated items

If the Tier C / schema G12 floor applies and the one independent approval at the
exact head, or the required checks, is missing: the PR is not mergeable yet.
Check existing approvals and review attempts first. Wait for pending checks;
reconcile any running or uncertain review before requesting another. Request a
new review only when it is needed and permitted by the review protocol and
remaining allowance. Do not queue a routine review gap for Mark.

If another doc 14 human gate applies (not the Tier C review floor) and the human
has not approved: **queue for Mark**, move on (do not block unrelated work).
Never force-push main (G3).

## Done means

- [ ] Native approval, exact head/range, acceptance and actual required checks recorded
- [ ] Merged only when checklist complete; target/main SHA and post-main checks verified
- [ ] If deployment authorized: READY for expected SHA and smoke green
- [ ] If deployment held: hold preserved; source integration reported separately
- [ ] Claim / worktree / branch cleaned — `release-claim.sh` exited **0**, not 3
- [ ] Status reported to AK / digest
