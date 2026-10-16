---
title: "Delivery receipt v1 (report-only)"
parent: The Doctrine
nav_order: 28
---

# Delivery receipt v1 — report-only read model


> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** This is a frozen report about one pull request.
> It copies facts GitHub already has (who committed, who reviewed that exact
> commit, which required checks passed) and says what those facts add up to.
> It does not merge, deploy, or approve anything. If a fact is missing, the
> report says `unknown`. It does not guess.

## What this is

Issue **#160** (R1 slice) ships a deterministic receipt for **one** pull request.
The receipt is a projection of a frozen evidence bundle. It is not a second
source of truth.

| Artifact | Path | Role |
|---|---|---|
| JSON Schema (documentation of shape) | `config/policy/schema/delivery-receipt-v1.schema.json` | Schema id `gibson.delivery.v1`, closed objects |
| Projector / verifier | `scripts/delivery-receipt.mjs` | `collect` shells `gh api` (or an injected runner), allowlists fields, and writes a frozen bundle. `project` and `verify` are pure. |
| Focused sensors | `scripts/tests/delivery-receipt.test.sh` | Fixtures, red cases, mutation receipts |
| This guide | `docs/delivery-receipt-v1.md` | What the receipt is, and the limits |

`collect` shells `gh api` once per source (pagination recorded per endpoint), allowlists fields, re-serializes review markers from `pr-review-evidence` `MARKER_FIELDS` only, and writes a frozen bundle (`gibson.delivery-bundle.v1`). It refuses an existing `--out` and an unreadable `--ledger` before any network call. Tests inject a `gh` runner (`setGhRunner` or `GIBSON_DELIVERY_GH_FIXTURE`) and do not use the network. `project` reads that bundle and prints a canonical receipt. `verify` fails closed when the receipt disagrees with its digest, with the bundle, or with the disposition rules.

Review identity is not reimplemented. `project` calls `evaluate()`,
`resolveAuthors()`, and `trailerVendors()` from `scripts/pr-review-evidence.mjs`
on the same inputs that script already collects: pull, pulls for the head,
commits, reviews, comments, timeline, files, and `config/review-evidence.v1.json`.
Dismissal, edited receipts, base retarget, a head shared by two open pull
requests, and the commit cap stay inside that function.

`evaluate()` is an open-PR predicate. A merged pull request is not open, so a
direct call returns `ambiguous-head` even when no other open pull request has
that head. The projector makes a second call, still `evaluate()`, only when the
bundle shows the pull request merged, the pulls-for-head list was readable, and
no other open pull request has the same head. A sibling open pull request keeps
the refusal.

## What this is not

- **Not** merge, deploy, or live-canary authority. `#140` owns delivery controls.
  `authority` is always `report-only`. `releaser` is always `unknown`: who
  clicked merge is not evidence.
- **Not** a workflow journal. The #158 journal does not exist. This slice does
  not replay one.
- **Not** an owner gate. D-014 and D-015 removed owner attestation, owner
  approval, and owner labels from the review loop. Those fields are absent
  from the model on purpose. The only label read is `tier-a`, `tier-b`, or
  `tier-c`.
- **Not** a policy-manifest digest. `policyManifestDigest` is the string
  `unknown` until **#164**.
- **Not** the #96 live-dogfood receipt. That fixture belongs to **#96**.
- **Not** proof the bundle still matches GitHub. A receipt proves it is
  consistent with the bundle it names. Re-collect to re-check.
- **Not** a deploy, cleanup, or lessons record. Those objects are
  `{status:"unknown"}` and stay that way in this slice.

## Disposition

`verify` enforces this order. The first match wins.

| Condition | Disposition | Reason |
|---|---|---|
| Bundle/receipt digest mismatch, or the receipt disagrees with a fresh projection | `incomplete` | `contradictory` |
| Pull request closed and not merged | `failed` | `closed-unmerged` |
| Pull request open, and a required check failed or the review verdict is changes-requested | `blocked` | `required-check-failed` and/or `review-fail` |
| Pull request open, otherwise | `parked` | `open` |
| Merged, base branch is not the repository default branch | `incomplete` | `non-default-base` |
| Merged, and every delivered rule below holds | `delivered` | (none) |
| Merged, otherwise | `incomplete` | the gap tokens |

`rolled_back` is reserved. This slice never emits it.

`delivered` requires all of the following. Any `unknown` in a field these rules
need is not delivered.

- The pull request is merged, and its base ref is the repository default branch.
- `evaluate()` returned a pass, recorded as verdict `APPROVE`, independence
  `E3`, and `reviewedHeadSha` equal to the pull request's final head SHA (not a
  branch name).
- The reviewer vendor is known and different from the builder vendor. Builder
  vendor comes from `evaluate()`'s author vendors (lane-bot login or an
  `Agent-Vendor:` trailer on an owner-identity commit). An unresolved vendor
  is `unknown`.
- Every required check is `success` at that head SHA. The required set is the
  union of classic branch protection and rulesets. A check run matches on
  context, and on `app_id` when the requirement names one. A matching name
  from a different app does not count, and the check run's app slug must be
  recorded. A commit status matches on context. When the requirement names an
  app id, an app id GitHub supplied on the status — `app.id`, or the app id in
  the status avatar — has to be that app. A creator with no app id does not
  prove the app. A status with no app id and no creator does not prove it
  either. Only a requirement that names no app id matches on context alone.
  An open pull request uses the combined status, one latest row
  per context. A merged pull request uses the paginated `/statuses` history and
  the check runs: the latest check run by `completed_at`, and the latest status
  by `created_at`, whose full UTC instant is at or before `merged_at`.
  Fractional seconds count. An instant equal to `merged_at` is pre-merge.
  Anything later is ignored for disposition and recorded on `postMerge`. A tie
  at that instant is more than one row, so the context is unmatched. No row at
  or before `merged_at` is unmatched. A clock that is not a UTC RFC3339 instant,
  or a merged pull request with no `merged_at`, sets `requiredChecks.status` to
  `unknown`. If branch protection, the ruleset, or the combined-status endpoint
  was unreadable, `requiredChecks.status` is `unknown` and nothing is matched.
- When G12 applies, `g12.met` is true. G12 applies when the tier is `C` or
  `unknown` (a missing or repeated tier label is `unknown`, and Tier C is
  assumed). `g12.met` is true only when the level is `E3`, the reviewed head
  is the pull request head, and every required check succeeded.
- Pagination on every collected source was exhausted, and comment-editor
  provenance was readable.

## Stated limits

- **Cost, deployment, cleanup, and lessons do not block `delivered` in this
  slice.** They are reserved placeholders. A receipt is not a deploy proof and
  not a live-canary proof. Cost joins a `gibson.cost.v1` ledger row only when
  the row names this pull request, or a join key maps to exactly one pull
  request. `collect` resolves that key and then copies only `ts`, `vendor`,
  `model`, `usd`, `tokensIn`, `tokensOut`, `pr`, and `repo`. `repo` must be an
  `owner/name` slug. `join_key` is not copied. A host path in any ledger field
  (`/Users`, `/home`, `/private/var`, `/private/tmp`, `/var/folders`, `/tmp`,
  `/Volumes`, `/opt/homebrew`, `/usr/local`, `~/`, or a Windows drive path)
  fails `collect` and writes no bundle. `usdTotal` is never summed. A row with
  no dollar amount keeps `usd` null. Two candidate rows that disagree are
  `unknown`, never summed. No matching row is `unknown`, not an empty join.
- **No `.gibson-delivery.json`.** Required checks come from GitHub.
- **A 404 or any other unreadable required-check endpoint is `unknown`.** It
  is not "no required checks".
- **An `owner-attested-review` comment uses a synthetic login that is not an
  identity row.** The reviewer vendor is the `reviewer-vendor` `evaluate()`
  already stored on that evidence identity. The login is not a vendor and is
  not eligibility. `unknown` is never eligible. A vendor that authored a
  commit on the head is not eligible. A listed App reviewer is unchanged.
- **`verify` exit 0 means the receipt is a faithful projection.** It does not
  mean the disposition is `delivered`. An `incomplete` receipt that matches
  its bundle is a pass.

## Running it

Pure Node. No new dependencies. Tests do not use the network.

```bash
node scripts/delivery-receipt.mjs collect --repo OWNER/REPO --pr N --out bundle.json [--ledger PATH] [--config PATH]
node scripts/delivery-receipt.mjs project --bundle bundle.json
node scripts/delivery-receipt.mjs verify --receipt receipt.json --bundle bundle.json
```

A comment marker in a bundle has to already be the re-serialization of the fields `pr-review-evidence` reads (`head-sha`, `result`, and the attestation vendor fields). `collect` drops any other marker text at collection time. `project` and `verify` refuse a bundle that still contains a host path or a marker that is not that re-serialization. A host path in a commit message or in a ledger field fails `collect` and writes no bundle. The same refusal covers `/var/folders`, `/private/tmp`, `/tmp`, `/Volumes`, `/opt/homebrew`, `/usr/local`, and `~/`. `delivered` requires every source, including pulls-for-head and both required-check endpoints, exactly once and exhausted. `pullsForHeadStatus` is `known` only when that pulls-for-head source is present and exhausted. Cost joins a `gibson.cost.v1` row carried in the bundle. An unreadable required-check endpoint is `unknown`, not an empty set. On a merged pull request the match row is the latest full-precision instant at or before `merged_at`; a later instant is a `postMerge` note. An unparseable clock is `unknown`. An open pull request still uses the latest combined status. A required app id does not match a status that has no app id.

Exit codes: `0` pass, `1` verify or project fail, `2` usage or I/O.

The digest is sha256 over canonical JSON: keys sorted lexicographically by
UTF-16 code unit at every depth, no whitespace, `JSON.stringify` number and
string encoding, top-level `digest` omitted. Key order in a file does not
change the digest. Three vectors live under
`scripts/tests/fixtures/delivery-receipt/`.
