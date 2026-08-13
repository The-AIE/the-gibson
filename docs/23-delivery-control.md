---
title: "23 · Delivery control"
parent: The Doctrine
nav_order: 23
---

# 23 — Delivery Control: Who Can Write Production

> 🙂 **In plain English:** Before the crew merges code that goes live, we check that
> the *door to production* is locked the right way — reviews required, tests green,
> and no secret shortcuts for admins. This chapter is that lock checklist. Rotating
> passwords and API keys stays a human-only job (gate G4).

The **`release` role** ([playbooks/release.md](../playbooks/release.md)) merges a
green PR and verifies the deploy. **Delivery control** is the layer underneath:
infrastructure that makes "merge = production" (or "push to `release` = production")
honest and hard to bypass.

ConferenceOS lesson (also in [doc 12](12-vercel.md)): docs said `release`→prod while
Vercel's Production Branch was still `main`, and `release` had **no** branch
protection. Delivery control exists so that class of failure is *sensed* at adoption
and *fixed* with a deliberate harden pass — not discovered by a security audit after
the fact.

## What this is / is not

| This doc | Not this doc |
|---|---|
| Branch protection, required checks, Production env approvals | Per-PR merge checklist (playbook `release`) |
| Truth table: which git ref is live Production | UX eval, DAST, Lighthouse (docs 07–08, 17) |
| Promote / hotfix / freeze when the target uses a release branch | Product packaging (doc 19) |
| Explicit **no secret rotation** by agents | Minting or storing credentials |

## Branch-model truth table (required at adoption)

Document what is **actually** wired (Vercel Project → Settings → Git → Production
Branch, not aspirational prose):

| Model | Production advances when… | Merge to `main` means… | Delivery-control weight |
|---|---|---|---|
| **A · main-is-prod** | `main` moves | **Live deploy** | Merge gate = deploy gate. Protect `main` strictly. |
| **B · release-branch** | `release` (or named prod branch) moves | Preview / staging only | Protect **both** `main` and prod branch; promote is a deliberate step. |
| **C · tag/pin** | Operator deploys an exact tag | Integration only | Protect default branch; pin advance is G-OWN-style owner step. |

**Fail adoption** (or file a P0 fix-list item) if:

- Merge-to-main is live Production (model A) **and** `main` is unprotected, or
  `enforce_admins` is off, or required reviews = 0, or status checks are non-strict.
- Model B is claimed but the prod branch is unprotected.
- Docs claim model B while Vercel Production Branch is still `main` (lie).

## Pass criteria ("delivery control healthy")

For every branch that can reach Production (at least the default branch; also the
prod branch in model B):

- [ ] Branch protection **on**
- [ ] `enforce_admins: true` (admins cannot skip gates)
- [ ] ≥1 required approving review; stale reviews dismissed
- [ ] Required status checks present; **`strict: true`** (branch must be up to date)
- [ ] Force-push and branch deletion **disabled**
- [ ] Conversation resolution required (when the plan supports it)

For GitHub Environments used for Production (when the org uses them):

- [ ] Environment has ≥1 required reviewer **or** documented why not
- [ ] Deployment branch policy limits to the production ref(s)
- [ ] Admin bypass off when the plan allows

## Modes (Release Manager / release role)

| Mode | Mutates? | When |
|---|---|---|
| **audit** | No | Adoption (doc 13), monthly drift, before any promote |
| **harden** | Yes (GitHub settings) | After Mark approves; dry-run first |
| **promote** | Yes (git prod branch / tag) | Model B only; verified SHA on `main` |
| **hotfix** | Yes | Prod broken; branch from prod tag; forward-port `main` |
| **freeze** | Process | Live event; non-hotfix promotes blocked |
| **rollback** | Yes | Bad deploy; prefer previous Vercel READY deployment |

Automation: [scripts/delivery-control/](../scripts/delivery-control/)  
Playbook: [playbooks/delivery-control.md](../playbooks/delivery-control.md)

All mutating scripts **default to dry-run**. `--apply` requires an interactive
confirm (type `apply`) unless `GIBSON_ASSUME_YES=1` is set for a controlled CI
context (prefer never in agent chat).

## Target configuration (portable)

Targets may ship a small JSON file so scripts know check names and model:

`.gibson-delivery.json` (optional; sensible defaults if missing):

```json
{
  "repo": "owner/name",
  "model": "release-branch",
  "defaultBranch": "main",
  "productionBranch": "release",
  "requiredContexts": [
    "quality",
    "DCO",
    "secrets",
    "dependencies",
    "build-e2e-required",
    "review-evidence"
  ],
  "productionEnvironment": "Production",
  "reviewerLogin": "CHANGEME-reviewer"
}
```

| Field | Meaning |
|---|---|
| `model` | `main-is-prod` \| `release-branch` \| `tag-pin` |
| `requiredContexts` | GitHub status check **context** names (exact strings branch protection requires) |
| `productionEnvironment` | GitHub Environment name for reviewers, or `null` to skip |
| `reviewerLogin` | Default required reviewer for Production env harden |

Do **not** put secrets in this file.

## Hard blocks (agents)

Aligned with [doc 14](14-human-gates.md):

| Block | Gate | Instead |
|---|---|---|
| Rotate `NEON_API_KEY` or any long-lived secret | **G4** | Document need; owner rotates in vendor console + secret store |
| Force-push shared branches | **G3** | Fast-forward / new commits only |
| Bypass protection "just this once" | — | Fix the gate or queue for Mark |
| Promote during freeze without hotfix discipline | G7 / process | Hotfix path only |
| Destructive production schema | **G1** | Additive-only; human gate |

**Secret rotation is never "delivery control work."** Audit may *report* that a key
was exposed to PR-head CI; the owner rotates. Agents may open Settings URLs and wait;
they never invent, echo, or commit secret values.

## Relationship to the `release` playbook

```
delivery-control audit (healthy write path)
        │
        ▼
release playbook: merge green PR → verify READY → smoke → cleanup
        │
        ▼  (model B only)
optional promote: FF production branch from verified main SHA → tag → smoke
```

If delivery control is unhealthy, the release role **refuses merge** when merge
would ship to Production, files a fix-list item, and runs or requests **harden**
(with Mark's apply approval).

## Promote / hotfix (model B sketch)

Full operator detail lives in the target's `RELEASING.md` when present. Portable
minimum:

**Promote:** freeze off → SHA on default branch → CI green → independent review →
schema checklist if needed → FF production branch → wait READY → tag → smoke.

**Hotfix:** branch from prod tag → smallest fix → PR into production branch →
tag patch → **forward-port to default branch**.

**Rollback:** Vercel → promote previous Production deployment (preferred); or
re-point production branch to prior tag when schema remains additive.

## Adoption and drift

1. **Adoption (doc 13):** run `scripts/delivery-control/audit.sh`; grade fails if
   prod write path is unprotected.
2. **Monthly / historian:** re-audit; drift → issue, not silent.
3. **ConferenceOS reference implementation:** app-specific protocol and scripts may
   live in the target (`docs/runbooks/release-manager-protocol.md`); Gibson keeps
   the portable contract here.

---
[← 22 · Devin cloud supervisor](22-devin-cloud-supervisor.md) · [Home](../index.md) · [Prompts →](prompts.md)
