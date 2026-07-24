# The Gibson — target-repo AGENTS.md section (template)

<!-- Append this section to the target repo's AGENTS.md at adoption (docs/13).
     Fill every <angle> placeholder. Keep it to repo-SPECIFICS ONLY — doctrine
     lives in the Gibson repo; this section points, it never copies. -->

## The Gibson

This repo is operated by The Gibson harness: <gibson-repo-url>. Load its AGENTS.md
before working here. Repo-specifics below override nothing — they instantiate.

### Gate commands (the green gate here)
```bash
<generate>      # e.g. npx prisma generate
<typecheck>     # e.g. npx tsc --noEmit
<lint>          # e.g. npm run lint
<test>          # e.g. npx vitest run
<build>         # e.g. npm run build
```

### Hot files
| File | Rule |
|---|---|
| <schema path> | additive-only, single claimant, models named in claim, own PR |
| package.json | no casual deps; own commit |
| <other> | <rule> |

### Framework warnings
<!-- pinned-version gotchas, e.g.: "This is NOT the Next.js you know — read
     node_modules/next/dist/docs before route/handler/config code; async
     { params } in route handlers is only caught by next build." -->

### Deployment truth (verified <date>)
- Vercel project: <name> (team <team>)
- Production Branch (VERIFIED in settings, not docs): <branch>
- Merge to <branch> ⇒ <what actually happens, incl. schema apply behavior>
- Preview deployments: <on/off, URL resolution method>

### Tier C surface map
<!-- The paths where Tier C treatment is automatic: -->
- Money: <paths>
- Auth: <paths, middleware>
- PII/consent: <paths, models>
- Schema: <path>

### Claims
Claim table: `docs/active-work.md` · labels: `agent-claimed`, `blocked`,
`gibson-halt` · max mutating lanes: 3
