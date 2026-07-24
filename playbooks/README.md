# playbooks/ — the portable skill format

One file per role (docs/03) + `loop-step.md` (docs/11) + `adopt.md` (docs/13).
A playbook = frontmatter (role, inputs, outputs, gates) + the dispatch prompt.

The same file renders to every runtime (docs/10): a Claude Code skill wraps it, a
Codex/Grok dispatch inlines it (`codex exec --full-auto "$(cat …)"` /
`grok -p "$(cat …)"`), a Hermes cron job templates it. One source, five runtimes —
anything expressible only as a vendor skill is doctrine-debt.

Authoring queue and order: docs/DOC-BACKLOG.md P0.1–P0.3.
