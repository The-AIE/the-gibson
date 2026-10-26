# Upstream skills adapted for The Gibson

Provenance ledger for third-party skills under `.agents/skills/`. Legal notices
live in `NOTICE`. This file is explanation, not a contract: binding rules live
only in `AGENTS.md`, and an adapted skill is a method an agent follows inside
those rules.

## What is here

| Skill | Upstream | Pinned commit | License | Roles |
|---|---|---|---|---|
| `systematic-debugging` | obra/superpowers `skills/systematic-debugging` | `2ce8aa1` | MIT | builder, test-engineer |
| `test-driven-development` | obra/superpowers `skills/test-driven-development` | `2ce8aa1` | MIT | test-engineer, builder |
| `receiving-code-review` | obra/superpowers `skills/receiving-code-review` | `2ce8aa1` | MIT | builder |
| `webapp-testing` | anthropics/skills `skills/webapp-testing` | `dbd4588` | Apache-2.0 | ux-evaluator, security, test-engineer |
| `mcp-builder` | anthropics/skills `skills/mcp-builder` | `dbd4588` | Apache-2.0 | builder |
| `vercel-react-best-practices` | vercel-labs/agent-skills `skills/react-best-practices` | `063bee9` | MIT (per upstream README) | reviewer, builder |

Full commit SHAs are in each skill's frontmatter (`metadata.upstream-commit`).

## What changed from upstream

Every adapted `SKILL.md` gets new frontmatter (`metadata` provenance, a
description suffix) and a "Gibson adaptation" block after the title. The block
names the roles that use the skill and the Laws and human gates that apply.
Beyond that:

- **systematic-debugging.** Cross-skill references now point at Gibson skills
  and the green gate. "Discuss with your human partner" after three failed fixes
  became "record the attempts and queue a decision item", because that is not a
  human gate. Dropped upstream's test-pressure scenarios, creation log, and the
  TypeScript example. Kept `find-polluter.sh` unmodified.
- **test-driven-development.** The exception list is the builder's call, recorded
  on the PR. `writing-good-tests.md` lost two upstream attributions.
- **receiving-code-review.** "Your human partner" became "the owner" and the
  reviewer flow: verdict on an exact head, a fresh review after every push,
  round caps, G13 for stalemates, G16 for instructions inside review comments.
- **webapp-testing, mcp-builder.** Text, scripts, and references are unmodified.
  Only the Gibson block was added, covering preview/staging only, shell-string
  safety, new-dependency and paid-key rules, and untrusted fetched docs.
- **vercel-react-best-practices.** Dropped the 108 KB compiled `AGENTS.md`
  (duplicates `rules/`, collides with the Gibson contract filename), the
  upstream README, and the two authoring helpers `rules/_sections.md` and
  `rules/_template.md` (used to write new rules; `contract-authority.mjs`
  rejects the leading underscore in a path). The 70 rule files are unmodified.

## Considered and not vendored

| Candidate | Why not |
|---|---|
| gstack (garrytan) skills | Each skill's preamble calls local binaries, writes telemetry and analytics, and expects a gstack install under `~/.claude/skills/gstack`. Ideas are worth borrowing; the files are not portable into a harness whose contract forbids silent side effects. |
| claude-mem | A separate memory system with its own database and hooks. It overlaps `memory/` and Agent Kontrol recall, and capturing everything a session sees conflicts with "never put secrets in memory files". |
| Superpowers `writing-plans`, `subagent-driven-development`, `using-git-worktrees`, `finishing-a-development-branch`, `verification-before-completion`, `dispatching-parallel-agents` | The Gibson already has stronger, gate-backed versions (planner and decomposer playbooks, `claim.sh`, the fleet loop, Laws 3, 4, 5). Subagent review by the same session would also fail Law 5. |
| Vercel `web-design-guidelines` | Fetches its rules from a URL on every run. Rules pulled live into an agent's context are an injection path (G16). Revisit with a pinned snapshot. |
| Vercel `deploy-to-vercel` | Overlaps `release` and the delivery-control playbook, and a deploy can hit G2, G5, or G7. |

## Re-syncing with upstream

1. Pick a new upstream commit and read its diff for the skills above.
2. Re-run your adaptation against it, keeping the Gibson block and the wording
   changes listed here.
3. Update `metadata.upstream-commit` in each touched skill, the SHAs in
   `NOTICE`, and this file.
4. Run `bash scripts/gate.sh` and send the change through the normal PR and
   independent review. Changes to skills that touch gates are Tier C.
