---
title: "Playbook · Delivery control"
nav_exclude: true
role: release
inputs:
  - target repository path and GitHub remote (owner/name)
  - optional .gibson-delivery.json in the target
  - mode: audit | harden | promote | hotfix | freeze | rollback
outputs:
  - audit report (protection + branch-model truth + drift)
  - optional harden of branch protection / Production environment
  - optional promote / hotfix / forward-port actions (after confirm)
gates:
  - audit is always first and read-only
  - harden/promote/hotfix require dry-run then explicit human apply
  - secret rotation never performed (G4 handoff only)
  - force-push never
forbidden:
  - rotating NEON_API_KEY or any long-lived secret
  - silent --apply without dry-run shown to the operator
  - force-push to main / release / production refs
  - promote during freeze without hotfix discipline
sources:
  - docs/23-delivery-control.md
  - docs/12-vercel.md
  - docs/14-human-gates.md
  - playbooks/release.md
  - scripts/delivery-control/
---

# Delivery control — write-path to Production

You enforce **delivery control** ([docs/23](../docs/23-delivery-control.md)): the
git/GitHub locks on whatever ref actually deploys to Production. You complement
the **release** playbook (merge one green PR); you do not re-implement features.

## How to use this

```bash
GIBSON=~/Code/the-gibson
REPO=owner/name   # or set in target .gibson-delivery.json

# Always start here (read-only)
$GIBSON/scripts/delivery-control/audit.sh --repo "$REPO"

# Dry-run harden
$GIBSON/scripts/delivery-control/apply-branch-protection.sh --repo "$REPO"
$GIBSON/scripts/delivery-control/apply-production-env.sh --repo "$REPO"

# Only after the human says apply / "apply protection"
$GIBSON/scripts/delivery-control/apply-branch-protection.sh --repo "$REPO" --apply
$GIBSON/scripts/delivery-control/apply-production-env.sh --repo "$REPO" --apply
$GIBSON/scripts/delivery-control/audit.sh --repo "$REPO"
```

**Dispatch:**
```bash
grok -p "$(cat playbooks/delivery-control.md)

Mode: audit
Target repo: /path/to/target
GitHub: owner/name
"
```

---

## Procedure

### 1. Establish branch-model truth

From Vercel (or target docs **verified** against settings):

- Model A `main-is-prod` · B `release-branch` · C `tag-pin`
- Record Production Branch string exactly

If docs lie about Production Branch → file adoption/fix issue; do not promote.

### 2. Mode: audit (default)

```bash
./scripts/delivery-control/audit.sh --repo owner/name
# optional: --config /path/to/.gibson-delivery.json
```

Report using the template in docs/23 / scripts output:

- Default branch + production branch protection  
- `enforce_admins`, reviews, strict checks, contexts  
- GitHub Production environment rules  
- Commits on default branch not on production branch (model B)  
- **NEON_API_KEY / secret rotation: needed | not needed | owner handoff only**

### 3. Mode: harden

Show dry-run payloads. Ask the human (Ask Contract): what settings change, why,
risks (temporary merge friction if checks are misnamed). On approval:

```bash
./scripts/delivery-control/apply-branch-protection.sh --repo owner/name --apply
./scripts/delivery-control/apply-production-env.sh --repo owner/name --apply
./scripts/delivery-control/audit.sh --repo owner/name
```

If required check **context** names are wrong, update target `.gibson-delivery.json`
and re-run — do not invent CI renames in production.

### 4. Mode: promote (model B only)

Preconditions: freeze off, SHA on default branch, CI green, independent review,
schema checklist if needed, owner sign-off.

```bash
./scripts/delivery-control/promote.sh --repo owner/name --sha <sha> --tag vX.Y.Z --summary "..."
# then --apply after confirm
```

### 5. Mode: hotfix

```bash
./scripts/delivery-control/hotfix-prep.sh --from-tag vX.Y.Z --next vX.Y.Z+1 --root /path/to/target
# implement → PR into production branch → after merge:
./scripts/delivery-control/forward-port.sh --sha <hotfix-sha> --root /path/to/target
```

### 6. Always with release playbook

When merging a PR that **is** the production ship (model A, or model B PR into
`release`): run delivery-control audit first; if unhealthy, **do not merge** —
harden or escalate.

Then continue [playbooks/release.md](release.md) (checks, merge, READY, smoke,
`release-claim.sh`).

### Hard block reminder

**Never rotate secrets** (G4). If CI previously exposed a management key (e.g.
Neon API key in PR-head job env), report:

> Owner should rotate in vendor console and update the GitHub Actions secret.
> Delivery control does not perform rotation.

## Done means

- [ ] Mode completed with audit evidence
- [ ] No secret values in chat or commits
- [ ] Mutating steps only after dry-run + human apply
- [ ] Report includes secret-rotation handoff line
