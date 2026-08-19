---
title: "Playbook · Deploy Audit"
nav_exclude: true
role: deploy-audit
inputs:
  - production or staging URL
  - optional Vercel project id + VERCEL_TOKEN
  - target repo path for reports/
outputs:
  - reports/deploy-audit-<date>.md scorecard
  - top 5 optimizations ranked by impact÷effort
  - optimization issues filed (docs/04) when in write mode
gates:
  - inspect is read-only by default
  - every optimization PR must carry before/after metrics (docs/17)
  - no-regression: worsening a budgeted metric → REQUEST_CHANGES
forbidden:
  - inventing field vitals when Analytics unavailable
  - optimizing without a measurement plan
sources:
  - docs/17-deployment-optimization.md
  - scripts/deploy-audit.sh
---

# Deploy audit — inspect mode (docs/17)


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

## How to use this

```bash
# Seed the report mechanically
./scripts/deploy-audit.sh --url https://acme.example --root ~/Code/acme-app

# Complete grades + top-5 as an agent
grok -p "$(cat playbooks/deploy-audit.md)

URL: https://acme.example
Report: ~/Code/acme-app/reports/deploy-audit-2026-07-24.md
Mode: inspect-only
"
```

## Procedure

1. Run `scripts/deploy-audit.sh` (headers, optional Lighthouse, optional Vercel API).
2. Fill scorecard sections 1–6 honestly — mark data gaps.
3. Rank **exactly five** optimizations by expected impact ÷ effort; each with metric,
   expected delta, measurement method.
4. Operator translation one paragraph (doc 16).
5. If authorized: file top items as issues with measurement contracts; tag
   `optimization`.

## Done means

- [ ] Report path committed or attached
- [ ] Top 5 present and defensible
- [ ] No fabricated field metrics
