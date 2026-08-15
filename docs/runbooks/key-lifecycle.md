---
title: "Key lifecycle runbook"
nav_exclude: true
---

# Key lifecycle — per-lane GitHub App identities

> 🙂 **In plain English:** Three robot identities commit and push agent work.
> Each one has a private key file on a specific machine. This page says where
> those files live, how to shut an identity off if a machine is compromised,
> and how to check whether a key file is getting old. It does **not** rotate
> anything by itself.

**Issue:** [#221](https://github.com/The-AIE/the-gibson/issues/221)
**Human gate:** secret rotation is **G4** ([docs/14-human-gates.md](../14-human-gates.md)).
An agent may write the runbook and run the advisory age sensor. An agent may
**not** generate, replace, suspend, or delete a live key unless Mark is
executing this runbook.

This file contains **no key material**. Only identity names, App IDs, and
host paths.

---

## Rotation cadence — OWNER DECISION

**OWNER DECISION — proposed 180d, not in force until Mark approves.**

Until that decision lands, the age sensor below is advisory only: it prints
`STALE` when a key file's mtime is older than the threshold you pass, and it
still exits 0. Nothing in CI, the solo loop, or this runbook treats 180 days
as policy.

Proposed (not approved):

| Secret | Proposed age | In force? |
|---|---|---|
| Per-lane GitHub App private keys | 180 days | **no** — owner decision pending |
| Vercel automation-bypass secret | 180 days (same proposal) | **no** — owner decision pending |

---

## Host-key inventory

Private keys live **outside every checkout**. Never copy a `.pem` into a
repo, worktree, gist, PR, or session transcript.

| Identity | Bot login | App ID | Key file | Host |
|---|---|---|---|---|
| `cos-agent-lanes` | `cos-agent-lanes[bot]` | `4445745` | `~/.claude/secrets/cos-agent-app.pem` | Mark's Mac |
| `aie-agent-lanes-grok` | `aie-agent-lanes-grok[bot]` | `4603934` | `~/.claude/secrets/aie-agent-lanes-grok.pem` | Mark's Mac |
| `aie-agent-lanes-mini` | `aie-agent-lanes-mini[bot]` | `4603933` | `~/.claude/secrets/aie-agent-lanes-mini.pem` | **Mac Mini pending** — file currently lives on Mark's Mac at the same path |

Non-secret identity configs (App ID, bot name/email, key *path*):
`~/.claude/fleet/identities/<grok\|mini>.env`. The legacy
`cos-agent-lanes` helper is `~/.claude/fleet/cos-bot-commit.sh`. The
general helper is `~/.claude/fleet/bot-commit.sh`.

Installation IDs are **not** inventoried here on purpose. Resolve them live
so an org transfer cannot strand a hardcoded number:

```bash
# After minting a short-lived App JWT (see bot-commit.sh):
#   GET /app/installations
#   GET /repos/{owner}/{repo}/installation
```

Conference-os still records one historical installation id for
`cos-agent-lanes` in that repo's `STATE.md`. Treat it as a hint, then
re-resolve.

---

## Per-identity revocation

Use this when a host may be compromised, a `.pem` may have leaked, or you
are executing an approved rotation. Repeat the same four steps for **each**
identity that lived on the affected host.

Generating a new private key does **not** invalidate the old one. A GitHub
App can have several keys at once. Revocation is: suspend → delete the old
key → install the new file on trusted hosts only → unsuspend → probe.

### 1. Suspend every installation of that App

Authenticate **as the App** (JWT from the current private key), not as a
user and not as an installation.

```bash
# List installations (JWT in APP_JWT):
curl -sS \
  -H "Authorization: Bearer ${APP_JWT}" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/app/installations

# Suspend one installation (blocks that App on that account):
curl -sS -X PUT \
  -H "Authorization: Bearer ${APP_JWT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/suspended"
```

GitHub App owners can only suspend via the API, and must suspend each
installation individually. A suspended installation cannot mint tokens or
read the account.

If the private key is already gone, suspend from the App's settings page
instead (GitHub UI: the App → Installations → Suspend).

### 2. Generate a new key and delete the old one

There is no REST endpoint that issues a new GitHub App private key.

1. GitHub → Settings → Developer settings → GitHub Apps → the App.
2. **Generate a private key.** Download the new `.pem` to a trusted
   machine only.
3. **Delete the old private key** on that same page. Leaving it listed
   means the leaked key still works.

### 3. Replace the file on trusted hosts only

```bash
# Example for aie-agent-lanes-grok on Mark's Mac.
# Use the inventory path for the identity you are rotating.
install -m 600 /path/to/downloaded.pem ~/.claude/secrets/aie-agent-lanes-grok.pem
```

Do **not** copy the new key onto a host you have not wiped or replaced.
For `aie-agent-lanes-mini`, keep the file on Mark's Mac until the Mac Mini
placement is no longer pending; then move it and delete the Mac copy.

Confirm `~/.claude/fleet/identities/*.env` still points `APP_KEY` at the
same path.

### 4. Unsuspend, then verify with a probe commit

```bash
curl -sS -X DELETE \
  -H "Authorization: Bearer ${APP_JWT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/suspended"
```

Mint the JWT for the unsuspend call from the **new** key.

Probe (does both halves: bot author/committer **and** App-token push):

```bash
# Grok or Mini identity, any repo that App is installed on:
~/.claude/fleet/bot-commit.sh <grok|mini> <worktree> <branch> <owner/repo> <<'MSG'
chore: probe commit after key rotation
MSG

# Legacy cos-agent-lanes (conference-os):
~/.claude/fleet/cos-bot-commit.sh <worktree> <branch> <<'MSG'
chore: probe commit after key rotation
MSG
```

Then:

```bash
gh api "repos/<owner>/<repo>/commits/<sha>" \
  -q '"author=\(.author.login) committer=\(.committer.login)"'
```

Both fields must be that identity's `[bot]` login. If either is `mrhinkle`,
the push used the wrong credential — fix it before any real work uses the
new key. Delete the probe commit's branch when the check is done (do not
force-push `main`).

---

## Age sensor (advisory)

[`scripts/key-age-check.sh`](../../scripts/key-age-check.sh) reads key-file
mtimes and compares them to a threshold in days. It prints a table. It
**always exits 0** after a successful run, including when rows are `STALE`.
A nonzero exit is a usage error only.

```bash
# Check the three inventory paths on this machine:
scripts/key-age-check.sh --threshold 180

# Check explicit files (tests and other hosts):
scripts/key-age-check.sh --threshold 180 /path/to/one.pem /path/to/two.pem
```

The sensor never prints file contents, never calls GitHub, and never
rotates anything. `STALE` means "show this to Mark"; it is not
authorization to rotate (G4).

---

## Vercel automation-bypass secret

Provisioned 2026-08-15 for protected preview URLs. The rotation
**procedure** lives in the ConferenceOS runbook:

[`docs/runbooks/preview-deploy-smoke.md`](https://github.com/The-AIE/conference-os/blob/main/docs/runbooks/preview-deploy-smoke.md)
in `The-AIE/conference-os` (path: `docs/runbooks/preview-deploy-smoke.md`).

This Gibson runbook does **not** duplicate that procedure. Cadence and an
age alarm for the bypass secret are the same owner decision as the App
keys (proposed 180d, not in force). `key-age-check.sh` will score any file
you point it at; it has no default path for the Vercel secret.

---

## What this runbook does not do

- It does not put a rotation on the calendar.
- It does not revoke a key merely by generating a new one.
- It does not place the Mini key on the Mac Mini (still pending).
- It does not rotate Vercel, npm, or any other secret.
