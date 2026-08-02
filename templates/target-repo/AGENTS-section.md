# Target-repo AGENTS.md section (template)

<!-- Append this section to the target repo's AGENTS.md at adoption (docs/13).
     Fill every <angle> placeholder.

     Deliberately harness-neutral: it names no vendor and no harness. A repo
     publishes the facts a machine needs to develop it safely; any harness —
     The Gibson, a bare Claude Code or Codex session, something not written
     yet — reads the same section and can take over. Repo-SPECIFICS ONLY:
     doctrine lives in the harness, this section instantiates it.

     Memory conventions: docs/24-agent-memory-conventions.md (Gibson doctrine).
     Seed MEMORY.md from templates/target-repo/MEMORY.md at adoption. -->

## Autonomous development contract

This repo is developed by both humans and coding agents. Any agent or harness
working here reads this section first and obeys it. It states repo facts, not
process doctrine — your harness supplies the process.

Machine-readable companion: `.agents/gate.json` (same commands, parseable).

### Shared agent memory

- **Read** root `<MEMORY.md or memory.md>` (and optional `memory/`) at session start
  before mutating work.
- **Dual-write:** durable lessons go in the repo memory file, not only in a local
  runtime store.
- **No CI loop for pure memory commits:** if a commit touches **only** shared
  memory markdown (`<MEMORY.md or memory.md>`, optional `memory/**`, optional
  `<fleet-memory path>`), do **not** run typecheck/lint/test/build and do **not**
  wait on product CI or review gates. Land the lesson on the default branch
  quickly. Mixed memory + product code uses the normal green gate.
- **Append-only** by default; rebase/pull immediately before writing; on conflict
  in dated sections keep both sides. No secrets in memory files.

### Gate commands (the definition of "green" here)
```bash
<generate>      # e.g. npx prisma generate      — omit the line if N/A
<typecheck>     # e.g. npx tsc --noEmit
<lint>          # e.g. npm run lint
<test>          # e.g. npx vitest run
<build>         # e.g. npm run build
```
All of these must pass before any **product** commit, with **zero new failures versus the
branch point**. Pre-existing failures are recorded, not inherited and not hidden.
Pure memory-only commits are exempt (see Shared agent memory above).

### Ground rules for machine contributors
1. **Never mutate the shared checkout.** One task = one branch = one git
   worktree of your own.
2. **Claim before you touch.** <claim mechanism — e.g. "one
   `- Active-work claim: <slug>` line in an open PR body", or
   "a row in `docs/active-work.md` plus the `agent-claimed` label">.
   Overlapping claim ⇒ stop and coordinate, never race.
3. **Never review or approve your own work.** An independent reviewer — ideally
   a different model — inspects the exact committed head, read-only.
4. **Acceptance criteria are the contract**, verified by a sensor (test, script,
   check), never by assertion.
5. **Report failures verbatim.** Never mark done what you did not verify.
6. **Clean up:** remove the worktree, delete the branch, release the claim.

### Hot files (single claimant, own PR)
| File | Rule |
|---|---|
| <schema path> | additive-only; name the models you touch in the claim |
| package.json | no casual deps; own commit |
| <generated barrels> | never hand-edit — run <generator command> |
| <MEMORY.md or memory.md> | append-only lessons; pure updates skip CI |
| <other> | <rule> |

### Framework warnings
<!-- Pinned-version gotchas that training data gets wrong, e.g.: "This is NOT
     the Next.js you know — read node_modules/next/dist/docs before touching
     route handlers; async { params } is only caught by next build." -->

### Deployment truth (verified <date>)
- Host/project: <name> (<team>)
- Production branch (VERIFIED in the host's settings, not in docs): <branch>
- Merge to <branch> ⇒ <what actually happens, including schema-apply behaviour>
- Preview deployments: <on/off, how the URL is resolved>

### Stop and ask a human for
<!-- The irreversible or human-only actions. Everything NOT listed here, the
     agent resolves itself — including failing tests, flaky CI, and conflicts. -->
- Money: <paths / actions>
- Auth and authorization boundaries: <paths, middleware>
- PII / consent: <paths, models>
- Security boundaries: <headers/CSP config, rate limiting, sandboxing, gate scripts>
- Destructive or irreversible data and schema operations: <schema/migrations paths,
  prod-touching scripts, seed/backfill>
- Secret values, public launches, legal commitments

### Commit and PR conventions
<!-- e.g. "git commit -s (DCO enforced on every PR commit)"; branch naming;
     required labels; whether agents may merge their own reviewed PRs. -->
