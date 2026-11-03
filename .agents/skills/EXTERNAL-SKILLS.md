# External skills (pinned, not vendored)

These skills are used by the StevieJ product-manager agent but are too large to vendor here
(tens of thousands of lines of templates). Install them from upstream at the pinned commit.

| Skills | Upstream | Pinned commit | License |
|---|---|---|---|
| `product-tracking-model-product`, `product-tracking-design-tracking-plan`, `product-tracking-audit-current-tracking`, `product-tracking-generate-implementation-guide`, `product-tracking-implement-tracking`, `product-tracking-instrument-new-feature`, `product-tracking-business-case` | https://github.com/accoil/product-tracking-skills | `91ae6a6267804e83a792b477f348d00c51d1a6cf` | MIT, Copyright (c) 2026 Accoil |

Install (Claude Code or any agentskills.io runtime, e.g. Hermes):

```bash
git clone https://github.com/accoil/product-tracking-skills /tmp/pts
git -C /tmp/pts checkout 91ae6a6267804e83a792b477f348d00c51d1a6cf
cp -R /tmp/pts/skills/* ~/.claude/skills/        # Hermes: $HERMES_HOME/skills/
```

Bump the pinned commit here when you update.
