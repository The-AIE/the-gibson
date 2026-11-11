# Contributing to The Gibson

Thanks for helping. The Gibson is a governance harness for coding agents: evidence gates, roles, sensors and routing that sit in the repository, not in any one agent. Contributions from people and from agents are both welcome, and both go through the same gates.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). To report a vulnerability, see [SECURITY.md](SECURITY.md); please do not open a public issue for one.

## License and sign-off

The Gibson is licensed under [Apache-2.0](LICENSE). Contributions are accepted on the same terms (section 5 of the license): you license your contribution to the project under Apache-2.0, and you keep your copyright.

We use the [Developer Certificate of Origin](https://developercertificate.org/) instead of a CLA. Sign off every commit:

```bash
git commit -s -m "your message"
```

That adds a `Signed-off-by: Your Name <you@example.com>` line, certifying that you have the right to submit the change. CI checks every commit in a pull request for it, and the trailer has to survive a squash. If you forgot, `git rebase --signoff origin/main` adds it to your branch.

## Before you start

- Search the existing issues and pull requests; someone may have solved it or be working on it.
- For anything bigger than a typo, open an issue first. Say what is wrong and how we would know it is fixed (the acceptance criteria). A short discussion up front saves a rewrite.
- Look at the [docs index](docs/00-INDEX.md) and [AGENTS.md](AGENTS.md), which is the operating contract for every agent and the best summary of how the project works.

## Making a change

1. Fork the repository and branch from `main`.
2. Make the change. Add or update a test for any behavior change; docs-only changes need no test.
3. Run the checks locally before you push:

   ```bash
   bash scripts/prepush.sh --base origin/main      # fast convention checks on what you changed
   bash scripts/tests/run-all.sh --no-quarantine   # the full suite; it takes a while
   ```

   You need `bash`, `git` and Node 22 (what CI uses). Scripts must stay portable to macOS's Bash 3.2.
4. Open a pull request and fill in the template.

### How risky is your change?

State the tier in your pull request (the full table is in [AGENTS.md](AGENTS.md)):

| Tier | What it covers | Review |
|---|---|---|
| A | Routine: docs, tests, isolated changes | One independent review, standard checks |
| B | Elevated: shared modules, more than 150 lines or 6 files | Full review |
| C | Money, auth, personal data, security boundaries, schema | Adversarial review at the exact head, plus required checks |

## What happens to your pull request

- The required checks are `claim-isolation`, `sensors` and `review-evidence`.
- `review-evidence` needs an independent review of the **exact head commit**. Pushing a new commit invalidates the earlier review, so batch your fixes.
- The sensors run the whole suite, a DCO check and a public-hygiene scan (see below).
- Maintainers merge once the checks and the review pass.

If you run an agent fleet against this repository, your agents follow [AGENTS.md](AGENTS.md): claim an issue with `scripts/claim.sh` before touching it, work in a worktree of your own, and name the agent's vendor in a commit trailer.

## Keep the public tree public

This repository holds the harness: doctrine, scripts, templates and tests. Do not commit private host names, private repository names, local paths, credentials, or records about your own deployment (run ledgers, lessons or decisions that name your systems). The sensor `scripts/public-hygiene.mjs` fails a pull request that does. If you use the Gibson on your own fleet, point `GIBSON_PRIVATE_HOME` at a private checkout so those records land there; see [docs/09](docs/09-memory-and-self-improvement.md).

## Where things are

- [QUICKSTART.md](QUICKSTART.md) and [GUIDE.md](GUIDE.md) for using it.
- [docs/18-fork-and-upstream.md](docs/18-fork-and-upstream.md) if you want to fork it and keep taking upstream changes.
- [CHANGELOG.md](CHANGELOG.md) for what changed and why.
