# Deployments card

`deployments.json` is the data the skill reads at step 7. One object per deploy target, nothing
remembered: every value was read from Vercel, GitHub or the reviewer host on `verified`. When a
read disagrees with a row, fix the row before promoting.

Fields: `name`, `repo` (owner/name), `defaultBranch`, `productionBranch` (the deploy project's
setting; `null` when the repo has no such branch), `deploy.provider`, `deploy.project`,
`deploy.team`, `deploy.source` (`git` or `cli` as observed on the latest production deployment),
`deploy.command` (when `cli`), `aliases`, `syncFrom` (the core repo and how merges arrive),
`reviewEvidence` (trust file path and who watches the repo), `postDeployConfig` (how install
config is applied), `stalePaths` (branches or projects that look like a promote path and are not),
`verified` (ISO date), `notes`.

Adding a target: copy a row, fill it from live reads, date it. A repo with no row is not promoted
by gibson-ship.
