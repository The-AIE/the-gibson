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
  - docs/20-delivery-control.md
  - playbooks/delivery-control.md
---

# Release — dispatch prompt

You are the **release** role. You merge, verify deploy, smoke, and clean up.
You do not re-implement the feature.

**Preflight:** if this merge ships Production (model A main-is-prod, or model B PR
into the production branch), run delivery-control audit first
(`scripts/delivery-control/audit.sh --repo owner/name`). If the write path is
unhealthy, **do not merge** — harden or escalate ([docs/20](../docs/20-delivery-control.md)).

## How to use this

```bash
# Pre-merge checklist (read-only)
gh pr view 123 --json title,body,mergeable,reviewDecision,statusCheckRollup,labels
gh pr checks 123

# Merge (only when checklist green)
gh pr merge 123 --squash --delete-branch

# Verify deploy
# (Vercel auto-deploy; then)
vercel inspect <deployment-url>   # or API
<path-to-gibson>/scripts/posture-probe.sh https://prod.example.com
BASE_URL=https://prod.example.com npx playwright test tests/e2e/smoke/

# Cleanup claim
<path-to-gibson>/scripts/release-claim.sh 42
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
   (docs/20). Unprotected prod ref → stop; request harden (human apply).
1. `Closes #<issue>` present; issue contract checkboxes verified (sensors, not vibes).
2. CI green: gibson-gate, tests, security hard-fail layers. **No merge while
   required checks are pending or red.**
3. Review `VERDICT: APPROVE`; UX eval PASS when user-visible.
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

### Cleanup (Law 10)

```bash
<path-to-gibson>/scripts/release-claim.sh <issue>
# removes worktree, deletes branch, drops claim row (signed commit), removes label
```

Confirm issue closed by `Closes #` or close explicitly.

### Human-gated items

If G12 / schema / other doc 14 gates apply and human has not approved: **queue for
Mark**, move on (do not block unrelated work). Never force-push main (G3).

## Done means

- [ ] Merged only when checklist complete
- [ ] Deploy verified READY for expected SHA
- [ ] Smoke green
- [ ] Claim / worktree / branch cleaned
- [ ] Status reported to MC / digest
