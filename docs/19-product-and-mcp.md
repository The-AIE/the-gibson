# 19 — Productization: Chatterbuilt Foreman, CodeWright & the Guided-Setup MCP

*(Names confirmed 2026-07-24: **Foreman** and **CodeWright**.)*

## The naming system (the whole product in one story)

> You talk to the **CodeWright** — like a millwright or a playwright, a
> tradesperson who crafts working things, except what they craft is code. The
> CodeWright listens, asks about your business, and drafts your **Blueprint** —
> a plan in plain language you approve. The **Foreman** takes the Blueprint and
> runs the crew until it's live. You only get pulled in for owner decisions.

| Name | Is | Maps to (harness) |
|---|---|---|
| **CodeWright** | The vibecoding guide — intake, design language, the Blueprint | planner role + doc 16 intake + frontend-design skill |
| **Blueprint** | The plain-language plan the owner approves | PLAN.md's operator translation (contractual per doc 16) |
| **Foreman** | The orchestrator — runs the build across ALL Chatterbuilt subprojects | Gibson pipeline + Mission Control dispatch + decision cards |

The trade-craft register is deliberate: *millwright* is instantly legible to
blue-collar owners — the person who installs and keeps the machinery running.
Free/paid line in the same vocabulary: **talking to the CodeWright is free
(interview, audit, Blueprint); hiring the Foreman is the product.**

## The open-core split

| | The Gibson | Chatterbuilt Foreman |
|---|---|---|
| What | The open harness engine (this repo) | The productized tier in the Chatterbuilt suite |
| Audience | Fork owners, technical operators | Non-technical business owners (doc 16 Operator tier) |
| Distribution | GitHub fork (doc 18) | **MCP connection + managed onboarding** |
| Revenue | none (it's the moat's foundation) | Suite tier — pairs with the Coordinator virtual-employee tier; Foreman runs the *software* side of the same promise |

The strategic fit: Chatterbuilt's thesis is agent-run software for SMBs. The
Website Agent maintains the site; **Foreman is what maintains everything else** —
features, fixes, audits, optimizations — using Gibson machinery with Operator-tier
presentation. Same flywheel as the suite: support content routes to theaie.net.

## Why an MCP is the right front door

The repo is *pull*-based: you read docs and act. Non-technical users don't pull —
they need a guide that **paces** them. An MCP server flips the interaction: the
user connects Foreman to whatever assistant they already use (Claude, ChatGPT,
Cursor — anything speaking MCP), and their assistant becomes a Gibson-literate
guide, because every tool response carries the instructions, the skill content,
and the Ask Contract framing the assistant needs to walk the user through the
next step correctly.

This is the proven `ask_the_manual` pattern from the existing Chatterbuilt MCP,
promoted to a full product: **tools that return skills** — procedural knowledge
served just-in-time, versioned server-side (updating a skill updates every user's
next session, no client change), with the doctrine's guardrails embedded in the
tool output itself.

## Tool surface (v1)

CodeWright tools (the guided design walk — the free tier):

- `codewright_start` — entry point. Assesses where the user is (nothing yet / has
  a site / has a repo), returns the appropriate first step, Ask-Contract
  formatted. Every subsequent tool returns `next_step` so the assistant always
  knows how to continue the walk — the user can drop off and resume; state lives
  server-side.
- `codewright_interview` — the doc 16 intake, one business question at a time;
  produces the **Blueprint** (plain-language) + PLAN.md pair. Calls the planner
  skill with the frontend-design skill for the design language ("what should it
  look and feel like" as swatch/mood choices, not CSS).
- `codewright_audit` — runs docs 13 + 17 read-only against their repo/URL;
  returns the scorecard translated ("your site loads in 4.1s on phones; good is
  2.5s") plus the top-5 fixes with impact.

Foreman tools (the build — the product):

- `foreman_install` — generates their AGENTS section, CI gates, and labels as a
  PR to their repo, each piece explained what/does/why/risks before it asks for
  the merge. Never pushes directly; the PR *is* the ask.

Operation (after setup):

- `foreman_status` — plain-language fleet status for their project.
- `foreman_decisions` — pending decision cards; `foreman_approve` /
  `foreman_decline` record the answer (approval happens through the user's own
  assistant chat — same channel they already trust).
- `ask_the_foreman` — the manual, conversational; also the "I don't understand
  this" hook that files confusion-lessons per doc 16.

Design rules for every tool:
1. **Responses are agent instructions, not just data** — each includes how to
   present this to *this* user (tier-aware), the Ask Contract fields, and the
   explicit next step.
2. **No tool performs an irreversible act.** Tools prepare PRs, cards, and plans;
   humans click merge/approve. The MCP inherits doc 14 wholesale.
3. **Skills are server-side content**, versioned with the harness (doc 18 sync
   applies to them like everything else).

## Architecture sketch

Next.js + `mcp-handler` on Vercel (the Mission Control / chatterbuilt-mcp
pattern), backed by the same store style: `users`, `projects`, `walk_state`
(resumable onboarding), `decision_cards`, `skills` (or skills-from-repo at build
time). Auth: per-user token issued at chatterbuilt.com signup — which is also the
licensing hook for the suite tier. Fleet side unchanged: Foreman's server talks
to Mission Control for dispatch and reads the user's Gibson fork/config for
doctrine.

## What stays honest

The CodeWright without a Foreman attached is a very good guided auditor and
planner — that alone is the free tier. The paid tier attaches the Foreman (the
fleet: Mark's, or the user's own runtimes) to actually execute the Blueprint.
The gradient: **audit free → Blueprint free → the Foreman is the product.**
