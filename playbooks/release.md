---
title: "Playbook · Release"
nav_exclude: true
role: release
inputs:
  - approved, all-gates-green PR
  - human approval recorded for Tier C / schema (G12 / G1)
outputs:
  - merge to integration branch
  - verified deploy (commit SHA + READY)
  - post-deploy smoke green
  - cleanup: worktree, branch, claim, issue closed
gates:
  - Closes #N present; contract checkboxes verified
  - CI green (gate + tests + security hard-fail)
  - review VERDICT: APPROVE; UX eval pass when applicable
  - DCO/Signed-off-by survives squash
  - Tier C / schema → human approval
  - one schema merge in flight fleet-wide
forbidden:
  - merging Tier C or schema without human gate
  - more than one schema merge in flight
  - force-pushing main
sources:
  - docs/03-roles.md
  - docs/02-sdlc-pipeline.md (stages 7–8)
  - docs/06-quality-gates.md
  - docs/12-vercel.md
  - docs/23-delivery-control.md
  - playbooks/delivery-control.md
---

# Release — dispatch prompt

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
<path-to-gibson>/scripts/release-preflight.sh 123            # add --partial for a slice
# exit 0 READY · 1 BLOCKED · 4 ADMIN-CANDIDATE (pre-launch operator decision)

# Pre-merge checklist (read-only)
gh pr view 123 --json title,body,mergeable,reviewDecision,statusCheckRollup,labels
gh pr checks 123

# Merge (only when checklist green)
gh pr merge 123 --squash --delete-branch

# If that fails with a checkout/worktree error, DO NOT force-checkout main here:
# you are probably inside a fleet worktree pinned to a feature branch, and
# yanking it out from under a running lane is Law 3 (L-020). Merge server-side:
gh api repos/{owner}/{repo}/pulls/123/merge -f merge_method=squash
git fetch origin && git log --oneline -1 origin/main   # verify the merge commit

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

0. **Delivery control** (when merge = Production ship): audit write path healthy
   (docs/23). Unprotected prod ref → stop; request harden (human apply).
0. `release-preflight.sh <pr>` — verdict READY, or an ADMIN-CANDIDATE you have
   explicitly authorized below. BLOCKED is never merged past.
1. `Closes #<issue>` present; issue contract checkboxes verified (sensors, not
   vibes). **Partial ship?** Run with `--partial`: it must close *nothing*.
2. CI green: gibson-gate, tests, security hard-fail layers. **No merge while
   required checks are pending or red.**
3. Review: newest usable timestamped event across PR reviews **and** comments
   wins (source type does not reorder the stream). Formal review states
   (`APPROVED` / `CHANGES_REQUESTED`) are modeled as events when they carry a
   complete ISO-8601 timestamp with a real civil calendar (strict round-trip;
   impossible dates like `9999-02-31` never normalize into the stream) and
   always precede body `VERDICT` text on the same review; `DISMISSED` reviews
   never authorize via body text. Fractional seconds accept **1–9 digits only**
   (nanosecond precision); **10+ fractional digits are malformed** and never
   enter the stream (no silent truncate — truncating collapsed distinct
   instants past the ninth digit). `reviewDecision` is only a fail-closed
   fallback when no usable event exists and no malformed formal evidence was
   discarded — a newer `VERDICT: REQUEST_CHANGES` blocks even if an older
   formal approval remains. Incomplete/prefix-only timestamps, 10+ fractional
   digits, impossible calendar dates/times, and authorless `APPROVE` events
   never clear the gate; equal-time conflicts prefer `REQUEST_CHANGES`. When
   the verdict source binds a commit SHA, it must match the current PR head —
   stale or absent/null head fails closed. UX eval PASS when user-visible.
4. DCO / `Signed-off-by` intact through squash strategy.
5. Tier C / schema → **human approval recorded** (PR comment/approval from owner).
6. Schema PRs: no other schema merge in flight; migration file present
   (schema-guard).

If any item fails → do not merge; report the missing gate.

### Stage 8 — Deploy + verify

1. Deployment exists for expected commit SHA.
2. State reaches **READY** (merge that never deploys = failure).
3. Smoke: non-destructive contract happy-paths + posture probe.
4. Mechanical failure → retry/redeploy; judgment-shaped → escalate with logs.
5. Rollback = promote previous READY deployment; diagnose in a worktree — never
   debug live in prod.

### Reading the preflight verdict

**READY** — merge.

**BLOCKED** — the reason is printed. Four of them are worth knowing cold:

- *"GitHub will close #N on merge"* on a `--partial` ship. Prose does not stop the
  keyword linker: "does not fully resolve #28" closed #28 anyway, four times
  (L-013). Fix the squash subject/body **and** unlink the issue in the PR's
  Development sidebar — the sidebar link closes independently of the wording.
- *"product-red required check"* — a step ran and failed. That is the code. Fix it.
- *"no formal approval and no VERDICT: line"* — review is fail-closed (Law 5).
  Never merge past this one.
- *Newest VERDICT is REQUEST_CHANGES / stale head* — reviews and comments are
  one timestamped stream; the newest usable event wins regardless of source
  type and regardless of `reviewDecision`. An older formal
  `reviewDecision=APPROVED` must not short-circuit a newer comment
  `VERDICT: REQUEST_CHANGES`. An older comment `VERDICT: APPROVE` must not
  override a newer review `VERDICT: REQUEST_CHANGES` (PR #57 false-green).
  Formal `CHANGES_REQUESTED` / `DISMISSED` state precedes contradictory body
  `VERDICT: APPROVE` text. Timestamps must be a complete ISO-8601 instant with
  a real civil calendar (not a prefix like `9999-99-99Tbogus`, and not an
  impossible date like `9999-02-31` that jq would normalize) and at most
  nanosecond fractional precision (1–9 digits after the decimal; 10+ digits
  are malformed, never silently truncated into the chrono key); authorless
  `APPROVE` never counts as independent; equal timestamps prefer
  `REQUEST_CHANGES`. Malformed formal `APPROVED`/`CHANGES_REQUESTED` evidence
  blocks before any `reviewDecision` aggregate fallback (no drop-then-recover).
  When the source carries a commit SHA, a verdict bound to any SHA other than
  the current head — or when head is absent/null — is fail closed — re-review
  the tip.

**ADMIN-CANDIDATE** — nothing about the product is wrong, but nothing has
authorized the merge either. Two causes:

1. **Same-author review** (L-015 / L-021). GitHub refuses self-approval, so a
   solo loop's `VERDICT: APPROVE` comment is the only review signal it can
   produce — real as process, but not an independent identity, and branch
   protection still blocks the merge. Prefer setting `REVIEWER_CMD` to get a
   cross-vendor reviewer with a different GitHub identity; admin merge is the
   fallback, not the habit.
2. **GitHub Actions infrastructure** (L-033). Required checks that fail in
   seconds with `startup_failure`, no steps, and no runner name — usually
   concurrently across several open PRs — carry no product signal. Re-run once.
   If it repeats identically, it is infra.

Either way, admin merge is **pre-launch only, Tier A/B only**, and only after you
post the checklist the script prints (local gate green on the merge tip, VERDICT
recorded, security CLEAR, tier, infra evidence quoted). Name the skip in that
comment. Never report remote CI as green when it was not. Post-launch, run with
`--launched`: there is no admin path, escalate to the owner instead.

Always re-sync `origin/main` before a merge attempt under a multi-lane fleet.

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

If more than the merged claim is live, name the one you merged; the script then
leaves the sibling rows and keeps `agent-claimed` on the issue:

```bash
release-claim.sh <issue> --claim-id issue-<issue>-<merged-slug>
```

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
(L-027). `--keep-label` is the truthful "no row, sibling still live" path and
must verify the label is still present — a blind success when the label is
absent or unreadable is a false green. Do not invent a claim file just to
satisfy cleanup.

Confirm issue closed by `Closes #` or close explicitly.

### Human-gated items

If G12 / schema / other doc 14 gates apply and human has not approved: **queue for
Mark**, move on (do not block unrelated work). Never force-push main (G3).

## Done means

- [ ] `release-preflight.sh` verdict recorded on the PR (and the admin checklist
      posted verbatim if the merge used the ADMIN-CANDIDATE path)
- [ ] Merged only when checklist complete
- [ ] Deploy verified READY for expected SHA
- [ ] Smoke green
- [ ] Claim / worktree / branch cleaned — `release-claim.sh` exited **0**, not 3
- [ ] Status reported to MC / digest
