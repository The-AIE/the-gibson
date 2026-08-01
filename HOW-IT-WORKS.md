# The Gibson — What It Is and How It Works

**Readable by anyone. Actionable for everyone.**  
If you only read one page after VIBECODING.md, read this.

---

## One-sentence version

The Gibson is a portable, self-improving set of rules and tools that lets AI agents (Claude, Codex, Grok, Hermes, …) plan, build, test, review, secure, and ship real software while a non-technical owner only answers plain-language questions and decision cards.

## Who it is for

| You are… | Start here | What you do |
|---|---|---|
| Non-technical owner (business person) | [VIBECODING.md](VIBECODING.md) | Describe what you want in ordinary words; approve plans and decision cards; look at previews |
| Technical operator / team lead | [QUICKSTART.md](QUICKSTART.md) → [GUIDE.md](GUIDE.md) | Adopt the harness on a repo, run the loop, approve human gates |
| Agent (any model) | [AGENTS.md](AGENTS.md) | Follow the contract; never invent gates; write lessons |
| Fork / security reviewer | This file + [SECURITY-AUDIT.md](SECURITY-AUDIT.md) | Understand controls and residual risks |

## What it actually is (three layers)

1. **Doctrine** — Markdown rules, roles, playbooks, and the Ask Contract (“what / does / why / risks” in plain language every time a human is asked something).
2. **Enforcement** — Shell scripts + GitHub Actions that do not care which model wrote the code: green tests, security scans, UX checks against a real preview, scope claims so agents don’t step on each other.
3. **Memory** — Versioned lessons and decisions in git. When the same failure happens twice it becomes a permanent improvement to the harness itself (the “ratchet”).

The models are rented. The harness is yours and compounds.

## How a non-technical person uses it

1. You describe an outcome in plain English (“customers should book appointments on the site instead of calling”).
2. The system interviews you with business questions only (one at a time).
3. You get a short plain-language plan (the Blueprint). You say yes or correct it.
4. Agents decompose the plan into issues, build in isolated worktrees, test, review each other’s work, scan for security problems, and check the look-and-feel on a private preview link.
5. You receive only four kinds of messages: status, decision card, simple question, or incident notice. Decision cards always include a recommendation and what happens if you do nothing (work waits safely).
6. You look at the preview on your phone and reply “yes” to go live, or “no / change X”.
7. Everything can be rolled back. You can say “pause everything” at any time.

You never see terminals, diffs, YAML, or stack traces.

## The pipeline (what the agents actually do)

```
PLAN → DECOMPOSE → BUILD → TEST → REVIEW → UX-EVAL → SECURITY → MERGE → DEPLOY → RETRO
```

- **Never grade your own homework** — generation and evaluation are separate agents (ideally different models).
- **Security is eight layers** (secrets, SAST, supply chain, AuthZ/IDOR, DAST on previews, adversarial review, AI-surface rules, runtime posture). Some are hard-fail (block ship); report-only findings must be promoted on a schedule.
- **Human gates are few and explicit** (money, go-live, destructive actions, secret rotation, active attacks). Everything else is autonomous by default.

Full detail: [docs/02-sdlc-pipeline.md](docs/02-sdlc-pipeline.md) and [docs/08-security.md](docs/08-security.md).

## Security in one paragraph

Agents produce real code that runs on the internet, so the harness treats security as first-class. Every PR is scanned for secrets and known vulnerable dependencies. Routes are checked against an authorization matrix so one user cannot see another’s data. Preview deployments are scanned with OWASP ZAP. A separate security-minded agent tries to invent attack paths and another tries to refute them. Anything that feeds an LLM is treated as untrusted. Confirmed leaks or active attacks stop the fleet and page a human. See the full [SECURITY-AUDIT.md](SECURITY-AUDIT.md) for the threat model, residual risks, and checklists.

## Self-improvement

Failures are written into `memory/LESSONS.md`. The same failure twice is a harness bug. The preferred fix is a permanent sensor (test, lint rule, CI check) so it can never happen again. The historian role and a weekly automated sweep keep the ratchet moving. The Gibson dogfoods itself — changes to the harness go through the same pipeline as product code.

## How to get started (actionable)

**Non-technical**
1. Read [VIBECODING.md](VIBECODING.md).
2. Connect an MCP-capable assistant (Claude, Cursor, ChatGPT, Grok, …) once the CodeWright/Foreman surface is live, or work with a technical operator who has adopted the harness.
3. Describe what you want. Answer the interview questions. Approve the plan and later decision cards.

**Technical**
1. Clone / fork The Gibson.
2. Follow [QUICKSTART.md](QUICKSTART.md) and [docs/13-adoption.md](docs/13-adoption.md) to install doctrine + CI + scripts into a target repo.
3. Point agents at [AGENTS.md](AGENTS.md).
4. Run the loop; keep human gates closed-list only.
5. After the first real run, file any lessons and promote report-only findings.

**Product / MCP path (in progress)**  
CodeWright (interview + Blueprint) and Foreman (install + status + decisions) tools will let any frontier model guide a non-technical user end-to-end. Tracked under the productization phase; tools will prepare PRs and cards only — humans always approve irreversible steps.

## What success looks like

- A non-technical owner describes an idea, answers a short interview, and later receives a working, secured, previewed feature with a clear “yes to go live” card.
- Technical operators spend time on genuine owner decisions and harness improvements, not on babysitting every commit.
- The same class of bug does not recur; the harness gets stricter or clearer over time.
- Security layers are green or explicitly exceptioned with owners and dates.

## Where to go next

| Need | Document |
|---|---|
| Pure non-tech instructions | [VIBECODING.md](VIBECODING.md) |
| Day-to-day operator manual | [GUIDE.md](GUIDE.md) |
| Full security detail + checklist | [SECURITY-AUDIT.md](SECURITY-AUDIT.md) |
| Reading order by role | [docs/00-INDEX.md](docs/00-INDEX.md) |
| Fork without losing updates | [docs/18-fork-and-upstream.md](docs/18-fork-and-upstream.md) |
| Product MCP design | [docs/19-product-and-mcp.md](docs/19-product-and-mcp.md) |

---

*Named for the supercomputer in Hackers (1995). You don’t hack The Gibson. The Gibson hacks the backlog — safely, repeatedly, and with a paper trail anyone can read.*
