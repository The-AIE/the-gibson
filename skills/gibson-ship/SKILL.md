---
name: gibson-ship
description: "Take a pull request in any Gibson-wired repository from open to live: PR-body preflight against the repo's own claim parser, wait for the repo's required contexts, one advisory pre-review, hand-off to the independent reviewer the repo's evidence gate trusts, merge at the reviewed head, promote through the install's own repo and deploy project (deployments card as data), verify the deploy, then apply install config last. Use whenever a PR exists and the goal is landing it or getting it live: 'ship this PR', 'get #N merged', 'land this', 'why is there no review yet', 'what is blocking #N', 'is it live yet', 'promote this to <install>', 'the gate failed', or before posting an owner attestation, running another review, or pushing to a PR under review. Stage 6 of the /gibson pipeline (merge → deploy+verify); also standalone. Defers to gibson-run for the coding loop and to the repo's own schema skill for the schema change itself."
---

# gibson-ship — PR open → live, without tripping the gates

The gates on a wired repo are machines that read exact fields on exact heads. The hour-long
"merge" stories come from an agent guessing what the machines want. This skill reads the rules
from the target repo and the reviewer's own state, and refuses to guess.

One skill for every repo. It does not carry a per-repo profile table. It reads, in the target
checkout:

| Source | Used for | Fallback when absent |
|---|---|---|
| `.agents/gibson-delivery.json` (`templates/target-repo/`) | `defaultBranch`, `productionBranch`, `requiredContexts`, `model` | branch protection via `gh api repos/<r>/branches/<default>/protection` |
| `.agents/gate.json` | the green gate to re-run at the exact head | AGENTS.md's gate line |
| `scripts/check-active-work.mjs` | the PR-body claim parser CI runs (`parsePullRequestMetadata` when exported; otherwise the two claim lines `claim.sh` writes) | the two lines, literally |
| `config/review-evidence.v1.json` or `.github/review-evidence-trust.json` | who the `review-evidence` gate trusts, and the independence rule | read the `review-evidence` status description and stop |
| `references/deployments.json` (this skill) | where a merge becomes a live site and how | none: a repo with no card row is not promoted by this skill |

Verified on 2026-10-21 against The-AIE/conference-os and The-AIE/the-gibson. Re-verify before
encoding anything new; this skill is only useful while it matches the machines.

## Non-negotiables

- Never push to a PR while an independent review of it is running. Check the reviewer's state first.
- Never merge another PR to the default branch while a review you are waiting on is running. The
  Mini controller's snapshot pins the base sha; a base move discards the whole paid review
  (`snapshot-changed`), the same as a push would (the-gibson ADR-0001, conference-os#2356/#2357).
- Never post an owner attestation on a head whose commits are authored or committed under the
  owner login. Both evaluators reject it (same-actor, #925) and a PASS attestation is not required
  anywhere since D-014.
- CLI reviews (Codex, Grok, Claude run by hand) are advisory. They post nothing the gate reads.
  Run one, fix everything it found, push once.
- Do not expect a reviewer before the repo's required contexts are green. Every reviewer here skips
  until they are.
- Merge only with `--match-head-commit <reviewed head>`. Never force-push the default branch.
- Promotion goes through the row on the deployments card. A push to a branch nothing deploys from
  is a no-op, not a promotion. Verify the live deploy path before using it.
- Schema or Tier C: the repo's own floor (conference-os: migration-safety snippet, delegated App
  evidence; the-gibson: E3 at the exact head plus required checks, D-015). Production apply is
  delivery control: audit, dry-run, explicit human apply.
- Whoever wrote it does not review it. A PASS from the author's vendor is a claim, not evidence.

## Step 1. Preflight, before `gh pr create` and before every later push

```bash
bash ~/.claude/skills/gibson-ship/scripts/gibson-ship-preflight.sh <pr-body.md> [pr-number]
```

Run inside the PR's worktree. It exits non-zero on any miss. What it checks, from the repo:

1. **Claim lines.** Exactly one `- Active-work claim: <kebab-slug>` and one
   `- Isolation: dedicated worktree` (or `isolated hosted checkout`). conference-os parses them in
   CI `quality`; the-gibson's `claim.sh` writes them and the claim is the open PR itself. The slug
   must be unique across open PRs. Placeholders (`<exact-claim-slug>`, `none`, `tbd`) fail.
2. **DCO.** `Signed-off-by` on every commit. Both repos require it; it must survive the squash.
3. **Vendor hint on every commit.** `Agent-Vendor:` trailer, or a lane-bot author login (read from
   GitHub when a PR number is given, because logins are not visible locally). The Mini controller
   skips a PR forever as `missing-vendor-hint` without one, and `mixed-authoring-vendors` when
   two vendors appear; the-gibson's attestation path needs the author vendor too.
4. **Schema.** If `prisma/migrations/**` or `prisma/schema.prisma` changed, the body needs the
   repo's migration-safety block (conference-os: `### Migration safety (#460)`); the PR is schema
   for the rest of this skill.
5. **Head contains the default-branch tip.** Merge captains refuse heads behind base, and a rebase
   later is another head that resets review (carryover only when nothing on base touched your
   files). Rebase once, now.
6. **Required contexts resolved.** Prints where they came from (installed config or branch
   protection) so step 2 waits on the right names.

## Step 2. Wait for the required contexts

```bash
bash ~/.claude/skills/gibson-ship/scripts/gibson-ship-status.sh <pr-number> [owner/repo]
```

Nothing produces a review before they are green. On conference-os that is `DCO`, `quality`,
`build-e2e-required` (20 to 30 minutes after a push); on the-gibson `claim-isolation`, `sensors`.
Use the wait for step 3.

## Step 3. One pre-review, one push

One read-only review of the exact head by a vendor that authored none of the commits, under the
fleet severity contract (fixed text in the Mini controller's `REVIEW_PROMPT`; the same words the
App's vendors get):

> Only a finding that causes incorrect behaviour, data loss, security or privacy exposure, or a
> false gate signal (a test that cannot fail, a weakened or deleted assertion, a check that cannot
> fail), with a concrete trigger reachable in this diff, may block. Everything else is a
> non-blocking note.

Batch every blocking fix, re-run step 1, push once. Each push is a new head; reviewers review heads.

## Step 4. Hand off to the independent reviewer the repo trusts

Read the trust file to see who can clear `review-evidence` here, then act on that:

- **conference-os** (`.github/review-evidence-trust.json`): `aie-independent-review[bot]` (the Mac
  Mini App; independent of the implementer, capabilities routine + schema + tier-c-delegated),
  `chatgpt-codex-connector` comments, `coderabbitai[bot]` reviews. Mini mechanics: launchd
  `com.peripety.neuro-independent-review`, 900 s tick, ascending PR number, 3 reviews per run,
  20 per day, 2 attempts per head, two vendors in sequence (900 s each), one comment with a
  `review-evidence:v1` block. Journal: `~/Library/Application Support/Neuro/independent-review/state/journal.jsonl`
  on `mac-mini`. The status script prints the PR's lines. Decode them literally:

  | reason | meaning | do |
  |---|---|---|
  | `required-context` | a required context is not green | wait |
  | `missing-vendor-hint` / `mixed-authoring-vendors` | commit trailers | fix trailers, push once / admin merge only |
  | `snapshot-changed` | head, base sha, labels or a context moved mid-review | stop pushing and stop merging to base; next tick retries |
  | `diff-too-large` / `diff-incomplete` | over 200 kB or truncated compare | split |
  | `already-published` / `attempts` / `halt` | evidence exists / 2 no-verdict attempts / halted | read the comment / check `run.err.log` / ask Mark |
  | `"vendors": [..], "result": pass|fail` | a review ran | pass → step 6; fail → fix, push once |

  On demand: the controller takes no PR argument (`--policy`, `--trusted-root`, `--state-dir`,
  `--dry-run`). `ssh mac-mini 'launchctl kickstart gui/$(id -u)/com.peripety.neuro-independent-review'`
  starts a sweep early; `controller.lock` makes a kick during a run exit at once. Kick only when
  step 2 is green and no run is in progress. ADR-0001 (the-gibson#511) proposes a 60 s ready probe.

- **the-gibson** (`config/review-evidence.v1.json`): identities with `reviewer` role are
  `aie-agent-lanes-grok[bot]`, `devin-ai-integration[bot]`, `coderabbitai[bot]`,
  `aie-independent-review[bot]`; `attestationVendors` lists who an owner attestation may name as
  the reviewing vendor. The sweep workflow (`.github/workflows/pr-review-evidence.yml`) stamps
  every open head. **The Mini App does not review the-gibson today**, and adding it is not a
  `policy.json` edit: the controller's `requiredContexts` are one global list (conference-os's
  three) and its gate adapter imports classifier and captain scripts from one `--trusted-root`
  (a conference-os checkout). Covering a second repo needs per-repo contexts and per-repo trusted
  roots in the controller. Until then a Gibson PR is cleared by a lane-bot vendor review at the
  exact head or Devin, per the trust file.

**Owner attestation**, on either repo: only when the head's commits are attributed to someone
other than the owner login (lane bots), only in a session Mark started, only after a
cross-vendor PASS at the exact head, with `head-sha` re-read right before posting, and never
naming the author's vendor as reviewer. Otherwise the gate answers "same-actor".

## Step 6. Merge at the reviewed head

Where a merge captain runs (conference-os `merge-on-green.yml`; the-gibson's Devin `--merge`
handoff when enabled), do nothing once evidence is green and the head contains the base tip;
confirm with `gh pr view <n> --json state,mergeCommit`. Schema or Tier C is Mark's go to land even
when a captain may merge it; if he says wait, apply the repo's halt (label or `gibson/HALT`).

Manual:

```bash
HEAD=$(gh pr view <n> --json headRefOid --jq .headRefOid)
gh pr merge <n> --squash --match-head-commit "$HEAD"
```

A `--match-head-commit` failure means the head moved after review; do not retry on the new SHA
until `review-evidence` is green on it. After merge: worktree and branch removed, claim released
the repo's way (conference-os: closing the PR releases it; the-gibson: `scripts/release-claim.sh`
with exact head and branch), integration preview READY for the merge commit.

## Step 7. Promote to the install

Merging to the default branch ships nothing to a live site. Read
`references/deployments.json`; the row for the install says where and how. Generic shape:

1. **Verify the path first.** Read the deploy project and its latest production deployment
   (Vercel: `get_deployment` with git info, or `vercel inspect <url> --scope <team>`). Record
   `source` (`git` or `cli`), the repo and branch if present, and the aliases. If it disagrees with
   the card, fix the card, then promote. The ATA path went stale silently in October 2026.
2. **Sync PR** in a worktree of the install repo from its default branch:
   `git cherry-pick -x <core merge commit>` (several core merges may share one PR, listed
   individually). Same claim lines as step 1; title `chore(core): sync <core> #NNNN (<summary>)`;
   body names core PRs, merge SHAs, migrations yes/no, what ran locally.
3. **Clear its gate** as in steps 2 to 4, with that repo's trust file.
4. **Merge** per the row.
5. **Deploy** per the row. Where the project's Production Branch is a branch the repo does not have,
   production is a CLI deploy from the merged default-branch checkout; record the deployed SHA in
   the sync PR, because a CLI deployment carries no git metadata. Delivery control applies:
   audit, dry-run, explicit human apply.

## Step 8. Verify, then configure

1. New production deployment `READY`, target production, public hostname in `alias`.
2. The affected route on the public hostname shows the change (curl for markup or headers; headless
   Chrome when visual). READY with old markup means the alias did not move or the wrong checkout
   was deployed.
3. Only now the install-specific config: MCP call, admin setting, env var, seed. Separate and
   last, so a failed deploy never leaves config pointing at code that is not live. Record it on
   the sync PR or the core PR.
4. Write the outcome to Cortex (`cortex-write`): PR numbers, merge SHA, deployment id, config.

## What this prevents (conference-os#2357, 2026-10-21)

Body without claim fields (quality failed); owner attestation on owner-authored commits
(same-actor, retracted); three CLI reviews (none counted); review discarded when the base moved
under it (`snapshot-changed`); reviewer expected before `build-e2e-required` (`required-context`,
twice); promotion assumed to a core branch nothing deploys from. Each is a rule above.

## Self-improvement

New journal reason, changed required context, new install, new evaluator: verify against the repo
and the reviewer first, then scripts, then a rule here with the why, then the card. Open the change
as a normal worktree branch and PR on the-gibson (Law 3).
