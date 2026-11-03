# External skills (pinned, not vendored)

These skills are used by the StevieJ product-manager agent but are too large to vendor here
(tens of thousands of lines of templates). Install them from upstream at the pinned commit.

| Skills | Upstream | Pinned commit | License |
|---|---|---|---|
| `product-tracking-model-product`, `product-tracking-design-tracking-plan`, `product-tracking-audit-current-tracking`, `product-tracking-generate-implementation-guide`, `product-tracking-implement-tracking`, `product-tracking-instrument-new-feature`, `product-tracking-business-case` | https://github.com/accoil/product-tracking-skills | `91ae6a6267804e83a792b477f348d00c51d1a6cf` | MIT, Copyright (c) 2026 Accoil |

Install (any agentskills.io runtime). Set `SKILLS_DIR` to your runtime's skills folder:
Claude Code uses `~/.claude/skills`; Hermes uses `$HERMES_HOME/skills` (default `~/.hermes/skills`).

```bash
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"   # Hermes: SKILLS_DIR="${HERMES_HOME:-$HOME/.hermes}/skills"
tmp="$(mktemp -d)"
git clone https://github.com/accoil/product-tracking-skills "$tmp/pts" &&
git -C "$tmp/pts" checkout --detach 91ae6a6267804e83a792b477f348d00c51d1a6cf &&
mkdir -p "$SKILLS_DIR" &&
cp -R "$tmp/pts/skills/." "$SKILLS_DIR/"
```

Bump the pinned commit here when you update.
