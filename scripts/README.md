# scripts/ — deterministic harness tooling (specs)

No-model by design (docs/15: "no-model checks stay no-model"). Implementations are
DOC-BACKLOG P0.4; specs below are the contract.

| Script | Contract |
|---|---|
| `claim.sh <issue> <slug> <scope...>` | Atomic claim: `agent-claimed` label → verify no live-claim overlap in `docs/active-work.md` → append claim row, commit -s to main, push → create worktree `../wt-<issue>-<slug>` + branch. Exit non-zero (and undo label) on any conflict. |
| `release-claim.sh <issue>` | Post-merge cleanup: remove worktree, delete branch, delete claim row (own signed commit), remove label. |
| `gate-baseline.sh` | Record branch-point failure counts (typecheck/lint/test) to `.gibson-baseline.json`. |
| `gate.sh` | Run the target's gate commands; diff failures vs. baseline; exit non-zero on any NEW failure. |
| `decompose-lint.mjs` | Validate an issue set: every issue has contract / area / tier / dependencies; contract criteria ≤10; schema changes are standalone issues. |
| `route-inventory.mjs` | Emit the route×role authz matrix scaffold from the framework's route tree (Next.js App Router first). Spec: docs/08 layer 4. |
| `posture-probe.sh <url>` | Assert headers (CSP/HSTS/frame), cookie flags, rate-limit 429 on burst against public POSTs. Spec: docs/08 layer 8. |
| `loop.sh --runner <grok\|hermes\|claude\|codex> --repo <path>` | The solo-loop driver: per docs/11 — kill-switch check, hat dispatch with fresh context (`<runner> -p "$(render playbooks/loop-step.md)"`), loop-state/journal management, error budget, MC heartbeat. |
| `preview-url.sh <pr>` | Resolve the PR's Vercel preview URL from the GitHub deployment event (fallback: `vercel inspect`). |
