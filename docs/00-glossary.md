# 00 — Glossary

One-line definitions for Gibson terms. Plain language first; doc links second.

| Term | Definition |
|---|---|
| **Acceptance criteria** | Testable done-statements on an issue; sensors verify them. [docs/04](04-plan-to-issues.md) |
| **Adapter** | Vendor-specific wiring (Claude/Codex/Grok/Hermes) over the same doctrine. Carries **zero rules**. [docs/10](10-vendor-adapters.md) |
| **Agent-claimed** | GitHub label meaning an agent holds the issue; part of the claim protocol. [docs/05](05-concurrency.md) |
| **Ask Contract** | Every human ask states what / does / why / risks, in plain language. [AGENTS.md](../AGENTS.md), [docs/16](16-nontechnical-operation.md) |
| **Baseline** | Failure counts at branch point; green gate allows no *new* failures beyond this. [docs/06](06-quality-gates.md) |
| **Blueprint** | Operator-facing plain-language plan (product name); maps to PLAN.md translation. [docs/19](19-product-and-mcp.md) |
| **Burn-down** | Issues that clear pre-existing gate debt until hard-fail can cover the whole codebase. [docs/13](13-adoption.md) |
| **Canonical checkout** | The shared clone of a target repo — **read-only** for edits; mutation in worktrees. [docs/05](05-concurrency.md) |
| **Claim** | Label + claim-table row asserting scope ownership so agents do not race. [docs/05](05-concurrency.md) |
| **CodeWright** | Guided intake / planning product surface over the planner role. [docs/19](19-product-and-mcp.md) |
| **Computational sensor** | Deterministic check (typecheck, lint, test, ZAP rule). [docs/01](01-principles.md) |
| **Contract (sprint)** | Acceptance criteria agreed before build; evaluators grade against it. [docs/04](04-plan-to-issues.md) |
| **Cross-vendor review** | Reviewer runtime ≠ builder runtime when available. [docs/06](06-quality-gates.md) |
| **Decision card** | Human gate translated into six plain-language fields for Operators. [docs/16](16-nontechnical-operation.md) |
| **Decomposer** | Role that turns PLAN.md into dependency-ordered issues. [docs/03](03-roles.md) |
| **Digest** | Regular status to the owner: shipped / waiting / learned. [docs/16](16-nontechnical-operation.md) |
| **Doctrine** | The rules in AGENTS.md + docs/ — what every agent loads. |
| **Error budget (loop)** | Max consecutive red gate failures before solo loop stops (default 5). [docs/11](11-solo-loop.md) |
| **Fail closed** | Missing/broken quality step **blocks** merge instead of skipping. [docs/06](06-quality-gates.md) |
| **FAN-OUT review** | Parallel per-lens reviewers + adversarial refutation (Tier C). [docs/06](06-quality-gates.md) |
| **Foreman** | Product orchestrator that runs the crew after Blueprint approval. [docs/19](19-product-and-mcp.md) |
| **Fresh context** | New model session per role hat; state in files, not chat memory. [docs/11](11-solo-loop.md) |
| **G / S / F grade** | Grind / Skilled / Frontier task routing for model economics. [docs/15](15-model-economics.md) |
| **Gate (green)** | generate → typecheck → lint → test → build; zero new failures. [docs/06](06-quality-gates.md) |
| **Gate (human)** | Closed list of stops requiring a person (docs/14). |
| **Guide** | Feedforward control: docs, playbooks, scaffolds that steer before action. [docs/01](01-principles.md) |
| **Harness** | Everything that is not the model: doctrine, scripts, CI, memory. [docs/01](01-principles.md) |
| **Harnessability** | How tractable a target repo is for agents (types, boundaries, gates). [docs/13](13-adoption.md) |
| **Hat** | One role worn in a solo-loop step (builder, reviewer, …). [docs/11](11-solo-loop.md) |
| **Hard-fail layer** | Security/quality check that blocks merge (vs report-only). [docs/08](08-security.md) |
| **Historian** | Role that files lessons and harness improvements from exhaust. [docs/03](03-roles.md) |
| **Hot file** | File many issues want (e.g. schema, package.json); special concurrency rules. [docs/05](05-concurrency.md) |
| **Inferential sensor** | LLM judgment check (review, UX grade, exploit reasoning). [docs/01](01-principles.md) |
| **Kill switch** | Halt the solo loop (`gibson/HALT` or `gibson-halt`). [docs/11](11-solo-loop.md) |
| **Lane** | Active mutating claim/worktree; max 3 per target repo. [docs/05](05-concurrency.md) |
| **Lesson** | Append-only memory entry that turns a failure into harness improvement. [docs/09](09-memory-and-self-improvement.md) |
| **Local overlay** | `local/**` in a fork — org overrides upstream never touches. [docs/18](18-fork-and-upstream.md) |
| **Loop state** | `gibson/loop-state.md` — only file a fresh context needs to resume. [docs/11](11-solo-loop.md) |
| **Mission Control (MC)** | Runtime control plane: queue, telemetry, dispatch (separate repo). |
| **Operator tier** | Non-technical owner interface: chat + decision cards only. [docs/16](16-nontechnical-operation.md) |
| **Parked** | Work set aside after bounded retries; safe queue, not failed forever. [docs/11](11-solo-loop.md) |
| **Playbook** | Portable role prompt: frontmatter + dispatch text. [playbooks/](../playbooks/) |
| **Posture probe** | Scripted check of headers, cookies, rate limits vs. a URL. [docs/08](08-security.md) |
| **Preview** | Ephemeral Vercel deploy per PR — UX eval and DAST target. [docs/12](12-vercel.md) |
| **Ratchet** | Failures → lessons → better guides/sensors so the issue can't recur. [docs/09](09-memory-and-self-improvement.md) |
| **Release (role)** | Merges, verifies deploy, smokes, cleans claims. [docs/03](03-roles.md) |
| **Report-only layer** | Security check that files issues but does not yet block (with promotion plan). [docs/08](08-security.md) |
| **Sensor** | Feedback control after action: tests, scanners, reviewers. [docs/01](01-principles.md) |
| **SOLO pass** | One reviewer, all six lenses (default depth). [docs/06](06-quality-gates.md) |
| **Solo loop** | One agent cycling all hats continuously with file handoffs. [docs/11](11-solo-loop.md) |
| **Sprint contract** | See acceptance criteria / contract. |
| **Tier A / B / C** | Risk tiers: routine / elevated / money-auth-PII-schema. [docs/06](06-quality-gates.md) |
| **Worktree** | Separate working copy of a repo so agents never share a directory. [docs/05](05-concurrency.md) |
