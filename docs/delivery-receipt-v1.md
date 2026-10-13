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
| Collector / projector / verifier | `scripts/delivery-receipt.mjs` | `collect` (network), `project` and `verify` (pure) |
| Focused sensors | `scripts/tests/delivery-receipt.test.sh` | Fixtures, red cases, mutation receipts |
| This guide | `docs/delivery-receipt-v1.md` | What the receipt is, and the limits |

`collect` is the only networked step. It shells `gh api`, allowlists fields, and
writes a bundle (`gibson.delivery-bundle.v1`). `project` reads that bundle and
prints a canonical receipt. `verify` fails closed when the receipt disagrees
with its digest, with the bundle, or with the disposition rules.

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
  union of classic branch protection and rulesets. A run matches on context,
  and on `app_id` when the requirement names one. A matching name from a
  different app does not count. The app slug must be recorded. If either
  required-check endpoint was unreadable, `requiredChecks.status` is `unknown`.
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
  request. The ledger has no dollar amount, so `usd` and `usdTotal` stay
  `null`. Two candidate rows that disagree are `unknown`, never summed. No
  matching row is `unknown`, not an empty join.
- **No `.gibson-delivery.json`.** Required checks come from GitHub.
- **A 404 or any other unreadable required-check endpoint is `unknown`.** It
  is not "no required checks".
- **An `owner-attested-review` comment uses a synthetic login that is not an
  identity row.** This slice resolves reviewer vendor from the identity table
  by that login, so the vendor is `unknown` and the receipt is not
  `delivered`. A listed App reviewer is unaffected. Extending the login is a
  later slice, not a second copy of the evaluator.
- **`verify` exit 0 means the receipt is a faithful projection.** It does not
  mean the disposition is `delivered`. An `incomplete` receipt that matches
  its bundle is a pass.

## Running it

Pure Node. No new dependencies. Tests do not use the network. `collect` does.

```bash
node scripts/delivery-receipt.mjs collect --repo OWNER/REPO --pr N --out bundle.json
node scripts/delivery-receipt.mjs project --bundle bundle.json
node scripts/delivery-receipt.mjs verify --receipt receipt.json --bundle bundle.json
```

Optional on `collect`: `--ledger PATH` (local `gibson.cost.v1` JSONL) and
`--config PATH` (default `config/review-evidence.v1.json`). The ledger path is
not stored. Commit messages keep only `Agent-Vendor:` lines. Comment bodies
keep only the review-evidence marker blocks. Absolute paths are refused.

Exit codes: `0` pass, `1` verify or project fail, `2` usage or I/O.

The digest is sha256 over canonical JSON: keys sorted lexicographically by
UTF-16 code unit at every depth, no whitespace, `JSON.stringify` number and
string encoding, top-level `digest` omitted. Key order in a file does not
change the digest. Three vectors live under
`scripts/tests/fixtures/delivery-receipt/`.
