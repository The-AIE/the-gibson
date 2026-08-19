---
title: "Preview URL resolution failures"
nav_exclude: true
---

# Preview URL resolution failures


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../../AGENTS.md). This file must not add, drop, or weaken those rules.

## Symptoms

- `preview-url.sh` times out
- UX-eval / ZAP jobs skip with "no preview"
- `BASE_URL` empty in Playwright

## Why

Docs/07 rule zero: **no invented URLs**. Missing preview is a real blocker, not a
skip to green.

## Checklist

| Check | Action |
|---|---|
| Vercel Git integration | Project connected to the GitHub repo |
| Deployment for head SHA | GitHub → PR → Checks / Deployments |
| `gh` auth | `gh auth status` |
| Timeout too low | `preview-url.sh 123 --timeout 300` |
| Draft PR | Vercel may not deploy drafts — mark ready |
| Protection / spend limits | Vercel paused deploys |
| Wrong org token | `GH_TOKEN` needs `deployments:read` |

## Recovery

```bash
gh pr checks 123
gh api repos/ORG/REPO/deployments?sha=SHA --jq '.[].environment'
./scripts/preview-url.sh 123 --timeout 300

# Last resort (still real URL from vercel CLI)
vercel ls --meta githubCommitSha=SHA
```

## CI policy

Skipping ZAP/UX when preview is missing must **not** count as pass on Tier B/C UI
work — annotate the PR and re-run when READY.
