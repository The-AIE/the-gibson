---
name: testing-gibson-harness
description: How to runtime-test The Gibson's bash harness (loop.sh, second-opinion.sh, devin-supervisor.sh) — scratch repos, vendor-CLI auth reality, PATH shims, mock Devin API, and macOS bash 3.2 portability checks.
---

# Testing the Gibson harness (shell-only, no UI)

There is no web UI and no test suite: everything is bash + plain node. Test with the
shell tool directly; do not record a screen video.

## Scratch target repo (2 minutes)

```bash
rm -rf /tmp/scratch && mkdir /tmp/scratch && cd /tmp/scratch
git init -q -b main && git config user.email t@t.co && git config user.name tester
echo 'def add(a,b): return a-b' > calc.py
printf 'import calc\nassert calc.add(2,2)==4\n' > test_calc.py
git add -A && git commit -qm init
git checkout -qb feat/x && echo 'def add(a,b): return a-b  # wip' > calc.py && git commit -qam wip
```
A repo with **no git remote** is useful on purpose: it exercises the `SLUG` basename
fallback in `devin-supervisor.sh`. Scripts create `<repo>/gibson/` themselves.

## Vendor CLI auth is the usual blocker — check it FIRST

```bash
codex exec --sandbox read-only --cd /tmp/scratch 'say ok'   # 401 if unauthenticated
claude -p --output-format text --permission-mode plan 'say ok'  # "Not logged in"
grok -p 'say ok'                                            # "Not signed in" / 403 no credits
```
Auth for these is typically only on the user's own Mac mini. An `XAI_API_KEY` may be
present yet still fail with `403 permission-denied: … team doesn't have any credits`
— an API key existing does not mean tokens are available. Report a blocked tier as
blocked-by-auth, and prove the harness plumbing separately (below) rather than
claiming a live-model pass.

## Reading the captured reviewer/runner output

`second-opinion.sh` captures `2>&1`, and the vendor CLIs put verbose structured logs
on **stderr** while the model text streams on **stdout** — so `gibson/second-opinion.md`
can be ~500 KB of `INFO` lines with the review interleaved token-by-token. Do not
conclude "no verdict" from a huge file. De-interleave first:

```bash
sed 's/\x1b\[[0-9;]*m//g' gibson/second-opinion.md \
  | perl -pe 's/20\d\d-\d\d-\d\dT[0-9:.]+Z\s+(INFO|WARN|ERROR|DEBUG)\b.*$//' \
  | tr -d '\n' | fold -w 160
```
The same trick recovers grok's token usage: `grep -ao '"usage":{[^}]*}' log | tail -1`.

## Prove dispatch plumbing without a live model: PATH shims

```bash
mkdir -p /tmp/shims && cat > /tmp/shims/codex <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > /tmp/shims/codex-argv.txt   # assert flags e.g. --sandbox read-only
cat > /tmp/shims/codex-stdin.txt                 # assert the rendered prompt + diff
echo "1. VERDICT: approve"
SH
chmod +x /tmp/shims/codex
PATH=/tmp/shims:$PATH ./scripts/second-opinion.sh --repo /tmp/scratch --reviewers codex --author grok --base main --branch feat/x
```
A shim that touches a file also proves the *author-skip* rule negatively: with
`--reviewers grok --author grok` the shim marker must NOT appear and the script must
exit non-zero.

## Prompt-passing bug class (regression watch)

Rendered playbooks start with YAML frontmatter (`---`). Any runner/reviewer invoked
as `cli -p "$(cat file)"` will abort with `error: unknown option '---`, *before*
auth. Always distinguish a parse failure from an auth failure by running the same CLI
with a plain prompt. Correct forms: `grok --prompt-file FILE`,
`claude -p … < FILE`, `codex exec … - < FILE`.

## Devin supervisor: live vs mock

- Live needs `DEVIN_API_KEY`. Keep spend low: `DEVIN_MAX_ACU=3`, reuse one session
  (`ensure` twice must return the same id), never pass `--merge`.
- `handoff --dry-run` needs no key and prints the exact assembled message — use it to
  assert branch/base/diffstat/merge-clause/second-opinion content.
- Verify a real handoff server-side: `GET /v1/sessions/{id}` and look for the
  "New candidate from the Gibson loop." message; do not trust local logs alone.
- Mock the API for the webhook-wake path (no spend): a tiny node server on 127.0.0.1
  serving `GET /v1/sessions/{id}` → `{"status_enum":"expired"}` and
  `GET /v1/sessions?limit=20` → a live `gibson`-tagged session only after the webhook
  is hit. Point `DEVIN_API_BASE`/`DEVIN_WEBHOOK_URL` at it. Note the poller sleeps 15s
  before its first list call.
- Unreachable API check: `DEVIN_API_BASE=http://127.0.0.1:9` must leave `handoff:`
  queued in `gibson/loop-state.md` and keep the loop's exit code 0.

## Driving a real model iteration cheaply

One `--once` run of `loop.sh --runner grok` on a tiny scratch repo costs ~16 k prompt /
~200 completion tokens and converges on a one-line fix. Give it an unambiguous
`next_action:` in `gibson/loop-state.md` and a red gate; then assert red→green,
`git status` showing the edit, and that loop-state/journal were updated by the model.
**Run the driver from a neutral empty cwd** (e.g. `/tmp/neutral`), not from the Gibson
checkout: `loop.sh` does not pass `--cwd` to grok, and the runner uses
`--permission-mode bypassPermissions`, so a stray write would otherwise land on the
canonical checkout. Diff `git status --porcelain` of the Gibson repo before/after as a
guard.

## Driving the loop without spending vendor tokens

`HERMES_CMD='true' ./scripts/loop.sh --runner hermes --repo /tmp/scratch --supervisor devin --once`
gives a *successful* iteration, which is the only way the supervisor-handoff branch is
reached; `HERMES_CMD='false'` gives a failing one, which reaches the escalation branch.

To assert *what arguments* the loop hands the supervisor (e.g. the assembled `--task`
string) without spending anything, copy `scripts/loop.sh` to `/tmp/gib/scripts/` next to
a stub `devin-supervisor.sh` that appends `"$@"` to a file, and run it with
`--gibson /path/to/the-gibson` so playbooks still resolve.

## Claim harness (claim.sh / pr-claims.sh / claims-status.sh / claim-reaper.sh / release-claim.sh)

Claims live in **open draft-PR bodies** (`- Active-work claim: <id>`, `- Isolation: dedicated
worktree`, `- Issue:`, `- Claim scope:`, `- Session:`, `- Claimed:`), with the legacy
`docs/claims/*.md` and `docs/active-work.md` ledgers still read as a fallback. Testing this needs
two fakes, because the Devin bot token normally **cannot create GitHub repos**
(`gh repo create` → `Resource not accessible by integration (createRepository)`) and may have zero
permissions on the target repo — check that first, and expect to fake GitHub rather than use it.

- **Fake branch protection with a real git hook.** `git init --bare` a scratch remote and drop a
  `pre-receive` hook that rejects `refs/heads/main` (echo GitHub's `GH006 Protected branch update
  failed` wording) and appends every attempted ref to `$GIT_DIR/push-attempts.log`. Rejection then
  happens in real push machinery, and that log is independent proof of what the harness *tried* to
  push — much stronger than only diffing the branch SHA. Seed `main` with the hook renamed away.
- **Fake `gh` with a JSON store, not with `true`.** A PATH shim backed by `prs.json` / `labels.json`
  where `pr create` stores the exact `--body-file` bytes and `pr list --json … --jq …` pipes real PR
  objects through **the real jq program from `pr-claims.sh`**. Make any unimplemented subcommand
  `exit 3` so an unexpected call is loud. Useful knobs: `GH_FAIL_PR_CREATE=1` (injected failure for
  the atomicity test), a variant that prints junk instead of a `…/pull/N` URL, and `GH_NOW` to pin
  `createdAt`/`updatedAt` so reaper staleness is deterministic together with
  `GIBSON_CLAIMS_NOW_EPOCH`.
- **Legacy-fallback tests must be mutation-checked.** "claim.sh refused" does not tell you *which*
  source refused. Prove the test has teeth by deleting the legacy branch of `claim_scope` in a
  throwaway copy of `scripts/` and confirming the same command then wrongly exits 0.
- **Beware pipefail when reasoning about `cmd | awk … && return 0`.** `awk` exits 0 after printing
  nothing, but these scripts run `set -euo pipefail`, so the pipeline still inherits the *left*
  command's failure and does not short-circuit. A mutation reintroducing that form may look fine;
  the robust form is capturing the output and testing `[[ -n … ]]`.
- Regression baselining is cheap here: `git worktree add /tmp/gib-main origin/main` and run the same
  scenario with the old scripts. That is how you separate "PR broke it" from pre-existing failures
  (e.g. `release-claim.test.sh`'s renewal-race fixture, and `claim-reaper.test.sh` aborting at
  `line 276: File: unbound variable` on GNU `stat` — both reproduce on unmodified `main`).
- Watch for teardown gaps: releasing a claim may close the PR and `exit 0` **before** the worktree /
  local branch / remote branch cleanup, which then makes re-claiming the same issue+slug die on
  `worktree path already exists`. Always assert post-release state *and* an immediate re-claim.

## macOS bash 3.2 portability (the user runs a Mac mini)

```bash
docker run --rm -v $PWD:/g:ro bash:3.2 bash -n /g/scripts/loop.sh
```

`bash:3.2` is Alpine-based and has **no git/jq**, so `bash -n` is all you get out of the box. For a
real end-to-end 3.2 run, build a one-line image first — this is worth doing, not just syntax checks:

```Dockerfile
FROM bash:3.2
RUN apk add --no-cache git jq coreutils
```
Inside the container set `git config --global --add safe.directory '*'` and
`commit.gpgsign false`, or git operations on mounted scratch repos fail for unrelated reasons.
Also run the scripts end-to-end under 3.2 with tiny `sh` stubs for `git`, `node` and
`curl` on PATH — `devin-supervisor.sh` hard-requires `curl` and `node` to exist even
for `--dry-run`. Watch for `declare -A`, `mapfile`, `${var^^}`, and empty-array
expansion under `set -u`.

## Gotcha: exit codes of `[[ … ]] && echo` as a script's last statement

Under `set -e` this makes a successful command exit 1 (hit by
`devin-supervisor.sh status` when the session has no PR). Always capture `EXIT=$?`
for every documented command, not just its stdout.

## Devin Secrets Needed

- `DEVIN_API_KEY` — live supervisor tier (create/status/message).
- `XAI_API_KEY` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` — only if a live model tier
  must be proven; otherwise expect those tiers to be blocked by auth.
