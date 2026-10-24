---
title: "ADR-0004: Per-repository review-evidence strictness levels"
nav_exclude: true
---

> **Authority:** Non-normative. Design record and rationale only; it adds no gate and changes no gate. Binding rules live in [`AGENTS.md`](../../AGENTS.md). Nothing in this record is applied until the owner decides.

# ADR-0004 · 2026-10-23 · An adopter starts lenient and each repository chooses its review-evidence rung

**Status:** Proposed. Nothing here is built. The evaluator, the trust file, the workflow and the template are unchanged by this PR.
**Owner decision required:** this record proposes that the shipped default be *less* strict than this repository's own gate. AGENTS.md's ratchet says a gate may only loosen with the owner's sign-off, and D-014 says the owner is out of the review loop, so the record also asks how those two rules apply to a repository lowering its own level (Open questions, Q3). Mark decides; this record is the question, not the answer.
**Decision record:** `memory/DECISIONS.md` D-021 points here.
**Related:** D-006 (adoption is a ladder), D-011 / D-012 / D-015 (review-independence levels E0..E4 and the Tier C floor), D-013 / D-014 (one attestation model; owner out of the loop), D-019 (`ownerCountersignVendors`, the first per-repository policy knob in the trust file, the-gibson#534), ADR-0001 (the-gibson#511).

## Context

The `review-evidence` merge gate has two halves. The **evaluator** (`scripts/pr-review-evidence.mjs`, driven by `.github/workflows/pr-review-evidence.yml` and configured by `config/review-evidence.v1.json`) is portable: it reads only GitHub's API and a committed JSON file, never runs pull-request code, and every one of its decisions is a closed reason token that fails closed. The **producers** of evidence are not portable. Every receipt the evaluator accepts today comes from a GitHub App identity the operator created and installed (lane-bot author Apps, a reviewer-only independent-review App, a vendor connector App), posted by a controller that runs on the operator's own hardware from a private repository, or from the owner's countersign of a hand-run review.

The open source readiness assessment of 2026-10-23 measured what that costs a stranger: an adopter following `playbooks/adopt.md` reaches green `claim-isolation` and `sensors` in about an hour, then stalls for one to two days on **reviewer identity**: creating a GitHub App, installing it, storing its key, writing an identity into the trust file, and standing up something that posts under it. Until then every head is `pending: no-receipt-at-head` and nothing can merge. `docs/13-adoption.md` § "Dedicated reviewer identity (G14 setup, once per org)" documents the stall as a step; it does not remove it.

Mark's direction the same day: *the default could be less strict, and then the user can choose for each project.*

Three facts shape the design:

1. **D-006 already made adoption a ladder** (enforcement before orchestration), but the ladder has one review rung, and it is the operator's own. There is no rung below "signed App identities" and no rung above it that names what delivery control adds.
2. **D-019 introduced the first per-repository policy knob**, `ownerCountersignVendors`, as explicit configuration rather than a constant in code, with the validator refusing dead or misspelled entries. This record generalises that move: policy that differs between repositories lives in committed, validated configuration, never in code and never in a per-push input.
3. **The target repositories already sit at different rungs in practice.** This repository requires `review-evidence` with a closed identity table (D-013/D-014/D-019). The largest target, TargetApp in the ledger's naming, requires `review-evidence` plus `DCO`, `quality` and `build-e2e-required`, runs a sibling evaluator with per-provider capabilities (`routine`, `schema`, `tier-c-delegated`), protects a `release` branch under delivery control (docs/23) and carries migration-safety and post-merge verification. ProductApp requires `gate`, `security-fast`, `authz-matrix`, `posture` and `zap-baseline` and does not require `review-evidence` at all. The difference is real and unrecorded; this record gives it names.

## Decision (proposed)

Add a `reviewPolicy` key to the per-repository delivery configuration, `.agents/gibson-delivery.json` (the file `gibson-ship`'s preflight and `scripts/delivery-control/` already read; see Q9 on the path), carrying an integer **level** 0..3. The evaluator reads the level from the **default branch's committed copy** through the trusted checkout the workflow already performs, and selects which evidence sources count at that level. The adoption flow asks the adopter to choose a level with the Ask Contract and writes `1` unless they choose otherwise.

```json
{
  "repo": "OWNER/REPO",
  "defaultBranch": "main",
  "requiredContexts": ["quality", "review-evidence"],
  "reviewPolicy": {
    "level": 1,
    "referenceWorkflow": ".github/workflows/gibson-review.yml"
  }
}
```

### The four levels

| Level | Name | Who it is for | What clears a head | What is new in the tree |
|---|---|---|---|---|
| **0** | solo | One maintainer, no second model available or wanted | Nothing. `review-evidence` is **published** on every head but is **not a required context**; branch protection does not list it. | The workflow and a minimal trust file (owner as author, `github-actions[bot]` as reviewer). |
| **1** | second-opinion (**shipped default**) | A maintainer or small team that writes with one model and wants another to read every head | A `workflow-review:v1` receipt posted by the repository's **reference reviewer workflow** under the `github-actions` App identity (slug `github-actions`, id 15368), naming a `reviewer-vendor` different from every author vendor on the head. **No adopter-created App.** | The reference workflow plus one repository secret (a model API key the adopter already has). |
| **2** | signed identities | A fleet of agents under distinct vendors (this repository today) | Today's rules unchanged: a formal review or `review-evidence:v1` comment from an identity in the **closed** trust table, bound to a GitHub App by slug and id; lane-bot author identities or owner-identity commits with an `Agent-Vendor:` trailer; same-vendor exclusion; `independent` clears unvendored owner commits; `ownerCountersignVendors` (D-019); unresolved author → failure. | At least one App identity the adopter controls or trusts, with its install and key. |
| **3** | delivery control | A repository whose merge ships to production (TargetApp today) | Level 2 **plus**: `scripts/delivery-control/audit.sh` passes; the Tier C human gates of docs/14 are stops; a `Migration safety` block is required when schema paths change; post-merge verification against the deployed SHA (docs/30; ADR-0003's hypothesis when it is tested); schema merges serialised. | Delivery-control configuration (model, production branch, environment) and the verification wiring. |

Levels are **cumulative**: every guarantee at level *n* holds at level *n+1*. Promotion is a one-key change plus whatever the new rung needs installed; the status description on every head names the level in force ("level 1: pass: github-actions[bot] (anthropic)"), so a reader of any PR knows which rung cleared it.

### What does not loosen at any level

Stated so it cannot be read out of the table above.

- **Fail closed, everywhere the evaluator already does.** `head-moved`, `ambiguous-head`, `api-error` (including a truncated commit list), `config-error` (missing, unreadable, invalid or unknown-key trust file), an unlisted or unverified author at level 2 and above. None of these gains a lenient branch at a lower level.
- **Receipts bind to the exact head.** A receipt at another head is `stale-head-only`; one that predates a base retarget is `stale-base`; a receipt at the wrong head is never evidence at any level.
- **Tampering voids.** An edited machine receipt is a tombstone (`editedAtAll`), an owner-countersigned comment edited by anyone else is a tombstone (`editedByOther`), a comment deleted at or after the newest pass voids that pass (`evidence-deleted`), newest-wins with `fail` dominating on a same-second tie. Level 1 receipts inherit all of this unchanged because they are App-authored comments like every other receipt.
- **The `review-evidence` status is always published.** Level 0 removes it from `requiredContexts`; it never removes the workflow or silences the status. A level-0 repository that later wants level 1 adds one context to branch protection and has history to look back on.
- **The level is read only from the repository's committed default-branch configuration.** The workflow runs on `pull_request_target` and checks out the default branch, never PR code, so a pull request's own copy of `.agents/gibson-delivery.json` is never what the evaluator reads. This mirrors the repo-owned rule of the local pre-push gate's `.fleet-gate`: a gate file counts only as the bytes on the default branch; a copy that is new, edited or deleted in a lane is a gate *change*, and a lane cannot make its own change effective for itself. A pull request that edits `reviewPolicy` is evaluated under the level in force, its diff touches `.agents/`, which `carveOutPath()` already names in the status description as a control-plane path, and the new level applies only to heads evaluated after it merges.
- **Lowering a level is a loosening under the ratchet.** AGENTS.md: "The ratchet may tighten autonomously; it may only loosen with the owner's sign-off." How that sign-off is expressed after D-014 is Q3 below; that it is required is not in question.
- **The hard blocks on actions** in the fleet's operating card (secrets and keys, billing, legal pages, destructive operations, unrequested pushes) are untouched, exactly as D-014 and D-015 left them. Levels govern what counts as review evidence, not what an agent may do.

### Why a level-1 receipt from `github-actions[bot]` is acceptable evidence

The level-1 receipt is a comment posted with the workflow's own `GITHUB_TOKEN`. GitHub stamps such a comment with `performed_via_github_app` = `{ slug: "github-actions", id: 15368 }`, which the evaluator already checks for every App receipt, so the trust table lists `github-actions[bot]` like any other reviewer identity, bound by slug **and** id. What makes the receipt trustworthy is the chain behind that stamp:

1. **The workflow file that runs is the default branch's.** `pull_request_target` reads the workflow from the base repository's default branch, never from the PR. A pull request cannot change which reviewer runs, what prompt it uses, which model it calls, or what it posts. (This is the same trust boundary `pr-review-evidence.yml` already relies on; the reference reviewer workflow carries the same trigger comment and the same `gibson:approved-pr-target` marker.)
2. **The reviewer job never executes PR code.** It checks out the default branch, fetches the PR diff and metadata through the API, sends the diff to the model, and posts the result. The code under review has no path to the job's token or secrets. A workflow that checked out and built the PR head under `pull_request_target` would hand the author the token; the reference workflow is written so it cannot be edited into that shape without a diff on the default branch.
3. **The receipt is machine-verifiable like every other App receipt.** Exact-head binding, edit tombstones, deletion voiding, retarget staleness and newest-wins all apply with no new code, because `collectEvidence` handles it as a comment from a listed App.
4. **The receipt carries a `run-id`, and the evaluator cross-checks it.** The `github-actions` identity is shared by *every* workflow in the repository. A receipt is accepted only when the Actions API confirms that run `run-id` belongs to this repository, ran the configured `referenceWorkflow` path, was triggered by `pull_request_target` (or the hourly sweep) for this pull request, and completed before the comment was created. A comment with no run id, an unknown run id, or a run of any other workflow file is not evidence. This is the check that turns a shared identity into a specific one.
5. **The author's vendor is the one the head declares.** `reviewer-vendor` in the receipt is the vendor the workflow called (from the repository's secret and the workflow's own configuration, not from the PR). The evaluator applies the same-vendor exclusion between that vendor and the author vendors it resolved for the head.

**What a write-access author can still do at level 1**, stated plainly so the rung is chosen with eyes open:

- **Post a forged receipt from another workflow.** Any workflow in the repository with `pull-requests: write` or `issues: write` runs under the same `github-actions[bot]`, and a `pull_request`-triggered workflow runs the PR's copy of its file. Without the run-id cross-check this would be a one-line attack; with it, the forged comment's run id belongs to a different workflow path or to a run whose head is the PR branch, and the receipt is refused. The residual is a change to the reference workflow itself, which lands only through a PR on the default branch, touches `.github/` (a named control-plane path), and is reviewed by the *current* copy of the workflow before it can replace it.
- **Lie about the author's vendor.** At level 1 the `Agent-Vendor:` trailer is self-declared, unlisted authors resolve to vendor `human`, and there are no lane-bot identities to check against. An author who writes with the same vendor the reviewer calls, and omits or falsifies the trailer, obtains a same-vendor second opinion (E2 in D-012's taxonomy, not E3). Level 1 accepts this; it is exactly what level 2's closed identity table and lane-bot Apps close. The receipt records which vendor reviewed, so the gap is visible after the fact, never silent.
- **Cancel or break the run.** Produces no receipt and leaves the head `pending`; it cannot produce a pass.
- **Disable branch protection or the workflow.** Available to administrators at every level and outside the evaluator's reach, as today.

What a write-access author **cannot** do at level 1: edit a receipt into a pass (tombstone), delete a fail to resurrect an older pass (timeline voiding), move a pass from one head to another (exact-head binding), make the reviewer run their code (no checkout of PR code), or pick the reviewer's model and prompt from the PR (default-branch workflow file).

Why the receipt is a comment and not a formal APPROVE review: GitHub refuses pull-request approvals from `GITHUB_TOKEN` unless the repository setting "Allow GitHub Actions to create and approve pull requests" is enabled, and enabling it lets *every* workflow approve. The comment form needs no setting and is the form the evaluator already verifies by App slug and id.

### How the evaluator selects evidence sources per level

Today `collectEvidence` accepts three forms: a formal review by a listed Bot identity, a `review-evidence:v1` comment from a listed App (slug and id), and an `owner-attested-review:v1` comment countersigned by the owner for a vendor with no App presence (minus `appReviewerVendors`, plus `ownerCountersignVendors`). The proposal adds one form and one selector:

| Source | Level 0 | Level 1 | Level 2 | Level 3 |
|---|---|---|---|---|
| `workflow-review:v1` comment from `github-actions[bot]` with a verified `run-id` | counted, informational | **counted** | refused (`identity:workflow-receipt-at-level-2`) | refused |
| Formal review or `review-evidence:v1` comment from a listed App identity (slug + id) | counted, informational | counted if the adopter lists one | **counted** | counted |
| `owner-attested-review:v1` countersign (D-019 rules) | counted, informational | counted | counted | counted |
| Unlisted commit author | resolves to `human` | resolves to `human` | `identity-unresolved` → failure | failure |
| Owner-identity commit, no `Agent-Vendor:` trailer | vendor unknown; any reviewer clears | vendor unknown; any reviewer clears | `independent` reviewer only | `independent` reviewer only |
| Carve-out path touched (control plane, secrets/billing, schema) | named in description | named in description | named in description | **requires a reviewer-only (`independent`) identity's pass** (Q8) |
| `review-evidence` in `requiredContexts` | **no** (the adoption flow omits it; `git-configure.sh --audit` reports if branch protection lists it) | yes | yes | yes |

Mechanics, as proposed for the Tier C implementation PR that would follow acceptance:

- `reviewPolicy` is parsed alongside the trust file by the same strict validator: `level` an integer 0..3; `referenceWorkflow` required at level 1 and refused at other levels; unknown keys refused (`config-error:reviewPolicy:<key>`). **Absent `reviewPolicy`** evaluates as level 2, which is the evaluator's current behaviour, so no existing adopter changes rung by omission; the status description then reads "level 2 (unset)". A present but malformed key is `config-error`, not a default.
- A new marker `workflow-review:v1` with fields `head-sha`, `reviewer-vendor`, `result`, `run-id`, registered in `MARKER_FIELDS` so `delivery-receipt.mjs` re-serialises it from those keys only. The identity entry for `github-actions[bot]` carries a new vendor token `workflow`, which is never a same-vendor match on its own; the vendor used for exclusion is the receipt's `reviewer-vendor`, which must be in `attestationVendors`.
- The run-id cross-check is one `GET /repos/{owner}/{repo}/actions/runs/{run-id}` per receipt, failing closed on API error like every other lookup (`api-error:run-lookup`). `path` must equal `reviewPolicy.referenceWorkflow`, `event` must be `pull_request_target` or `schedule`, `pull_requests[].number` must include this PR, `conclusion` must be `success`, and `updated_at` must not be after the comment's `created_at`.
- `git-configure.sh`'s allowed-key list for the delivery file gains `reviewPolicy`, and its `--audit` reports a level-0 repository whose branch protection requires `review-evidence` (or a level ≥1 repository whose protection does not) as drift, the same L-004 class it reports today for required-check name drift.
- The status description prefixes every verdict with `level N:`; the delivery receipt (`gibson.delivery.v1`) records the level in force at merge.

### The adoption question

Adoption (today `playbooks/adopt.md` Step 2 and `scripts/git-configure.sh`; `adopt.sh` when the open source readiness work ships it) asks the adopter one question with the Ask Contract and writes the answer into `.agents/gibson-delivery.json`:

| Field | Text |
|---|---|
| What I'm asking | Choose how strictly this project checks that every proposed change was read by a second reviewer before it can be merged. The default is **level 1**. |
| What it does | **Level 1 (default):** every pull request is read by a second AI model that runs in your GitHub Actions and posts a pass or fail; a change cannot merge until a model other than the one that wrote it has passed it. Needs one API key you already have. **Level 0:** the same reviewer runs and posts its verdict, but nothing blocks a merge. **Level 2:** reviews count only from identities you register as GitHub Apps, so the system can prove which model wrote and which reviewed; set-up takes a day. **Level 3:** level 2 plus the production safeguards (release branch protection, migration checks, post-deploy verification); offered when the delivery-control audit passes. |
| Why | A second reader catches what the author's model is blind to, and the record on each pull request shows who read what. Starting at level 1 means you get that today, and can raise the bar when the project needs it. |
| Risks | Level 1 trusts the author's own declaration of which model wrote the change; a dishonest contributor with write access could obtain a same-vendor second opinion. Level 0 blocks nothing. Both are visible in the project's pull-request history and can be raised at any time with a one-line change that is itself reviewed. Lowering a level later needs the owner's sign-off. |

Level 3 is offered only when `scripts/delivery-control/audit.sh` passes; otherwise the flow says so and offers level 2 with the audit's fix-list.

### Migration of the three existing repositories

| Repository (ledger name) | Today | Proposed `reviewPolicy.level` | What the migration PR does |
|---|---|---|---|
| this repository | `review-evidence` required; closed identity table; `ownerCountersignVendors: ["codex"]` (pending #534) | **2** | Adds `.agents/gibson-delivery.json` (none exists today) with `level: 2`, `requiredContexts: ["claim-isolation", "sensors", "review-evidence"]`. No evaluator behaviour changes. See Q4 on the file's other fields for a repository with no production deploy. |
| TargetApp | `review-evidence`, `DCO`, `quality`, `build-e2e-required` required; sibling evaluator with per-provider capabilities; `release` branch under delivery control; migration-safety; post-merge smoke | **3** | Declares `level: 3` so receipts, preflight and the adoption report name the rung. Whether TargetApp converges on this evaluator or keeps its sibling and only declares the level is Q5. |
| ProductApp | `gate`, `security-fast`, `authz-matrix`, `posture`, `zap-baseline` required; `review-evidence` **not** required; `merge-on-green` | **to be confirmed** (Q2) | Today's state is level 0 in substance with no workflow publishing the status. Level 1 needs the reference workflow and one secret; level 0 needs the workflow only. Either way the migration PR records the choice instead of leaving it implicit. |

Order: this repository first (it is the implementation's own test bed), TargetApp second (declaration only), ProductApp when Mark confirms its level. No migration PR lowers any repository below what it enforces today.

## Alternatives rejected

- **One global strictness for every adopter** (today's de facto design). It is this repository's own model exported unchanged, and it is the cause of the one-to-two-day stall. Rejected by Mark's direction.
- **Level 2 as the shipped default.** Same stall, now documented. Rejected.
- **Level 0 as the shipped default.** Nothing enforces Law 5 and the adopter never sees what the gate is for; the first thing they learn about review evidence is that it does nothing. Rejected: the default must block *something* so the mechanism is visible.
- **Choosing the level per pull request** (a label, a trailer, a workflow input, an environment variable). A lane could lower its own bar for its own push. Rejected: policy lives in committed, reviewed configuration read from the default branch, the same rule the local pre-push gate applies to `.fleet-gate`.
- **Putting the level in the trust file** (`config/review-evidence.v1.json`). The trust file is evaluator-shaped (identities and vendors); the level is repository policy, belongs beside `requiredContexts` (level 0 *is* a `requiredContexts` difference), and is read by the preflight and delivery-control scripts that never open the trust file. Rejected; the trust file keeps identities.
- **Having the adopter create a GitHub App at level 1.** App creation is the step the default path exists to remove. Rejected for the default; it is level 2.
- **A formal APPROVE from `github-actions[bot]` as the level-1 receipt.** Needs the repository-wide setting that lets every workflow approve pull requests. Rejected; the comment receipt needs no setting and is already verified by slug and id.
- **A third-party review service as the level-1 default** (CodeRabbit or a vendor's own connector). A paid or external dependency chosen for the adopter, and a vendor decision this repository has deliberately not made (its CodeRabbit pilot was evidence-gated, never merge-authoritative). Rejected for the default; both remain available as level-2 identities.
- **A continuous score instead of rungs.** Not auditable: a reader of a PR cannot tell what a `0.7` guaranteed. Rejected; each level names a fixed set of guarantees.
- **Reading the level from the PR's own configuration** so the adoption PR can set it before merge. The adoption PR is the one case where the configuration does not exist yet on the default branch, and it is handled by landing workflow and configuration together; the first sweep after merge reads the committed copy. Rejected: the cost is one merge of the adoption PR under GitHub's defaults; the alternative hands every later lane a lever.

## Open questions for Mark

1. **Default = 1.** Is level 1 (second opinion through the reference workflow, no App) the shipped default, as proposed? The alternative with a case is level 0 with the adoption flow nudging to 1.
2. **ProductApp's level.** Confirm 1 (install the reference workflow and one secret) or record 0 explicitly. Today it is 0 in substance.
3. **Lowering a level after D-014.** The ratchet needs the owner's sign-off to loosen; D-014 removed owner attestation, approval and labels from every head. Options: (a) a PR that lowers `reviewPolicy.level` requires the owner's own merge click and nothing else, the one surviving owner action, as D-019's Tier C PR did; (b) a lowering PR is cleared like any other Tier C change (E3 plus required checks) and the owner's sign-off is the merged decision record; (c) lowering is refused by the validator and only an explicit `reviewPolicy.loweredBy` field with a date and the owner's login unlocks it. Which rule?
4. **This repository's own delivery file.** `.agents/gibson-delivery.json` was designed for targets that deploy (`model`, `productionBranch`, `productionEnvironment`). For a library repository with no production, which fields are required and what does `model` say? A `library` model value, or `null`?
5. **TargetApp's evaluator.** Keep the sibling evaluator and trust file (with its `routine` / `schema` / `tier-c-delegated` capabilities) and only declare `level: 3`, or converge on this repository's evaluator so one implementation carries all four levels? Convergence is real work and a Tier C change on a production repository.
6. **Level-1 vendor choice.** The reference workflow calls one model API with one secret. If the adopter's only key is for the vendor they also write with, level 1 yields a same-vendor second opinion (E2). Accept E2 at level 1 for that adopter, or require that the reviewer key be for a different vendor than the one named in `Agent-Vendor:` trailers on the head (the workflow would refuse to review a head whose declared author vendor equals its own)?
7. **Unlisted authors at level 1 resolve to `human`.** This is what lets a solo adopter merge their own commits without listing every contributor. Accept, or require listing at level 1 too?
8. **Level 3 and carve-out paths.** Should a head touching a control-plane, secrets/billing or schema path at level 3 require a pass from a reviewer-only (`independent`) identity rather than any cross-vendor reviewer? It is stricter than any repository enforces today and would make the Tier C floor machine-checked by path.
9. **Canonical path.** `docs/23-delivery-control.md` and `scripts/git-configure.sh` read a root `.gibson-delivery.json`; `gibson-ship`'s preflight and the template's installation target read `.agents/gibson-delivery.json`; no adopter has either file today. Proposal: `.agents/gibson-delivery.json` is canonical (the `.agents/` prefix is already a carve-out pattern, so a change to it is named in every status description) and `git-configure.sh` reads both during a deprecation window. Confirm?
10. **Names.** `solo`, `second-opinion`, `signed-identities`, `delivery-control` are working names. Keep, or rename?

## Rollout (after the decision)

- [ ] Owner decision on the open questions, recorded in D-021: ____ (date)
- [ ] Tier C implementation PR: `reviewPolicy` parsing and validation, `workflow-review:v1` marker, run-id cross-check, level-prefixed status descriptions, tests for every row of the source table (including the forged-receipt-from-another-workflow case and the absent-key case)
- [ ] Reference reviewer workflow in `templates/target-repo/` with the `gibson:approved-pr-target` marker and no checkout of PR code; a fixture test that a receipt from a different workflow path is refused
- [ ] `git-configure.sh`: `reviewPolicy` in the allowed-key list; level-versus-protection drift in `--audit`
- [ ] `playbooks/adopt.md` Step 2: the Ask Contract card above; `docs/13-adoption.md` § "Dedicated reviewer identity" rewritten as the level-2 step, not the default
- [ ] `docs/23-delivery-control.md`: the level table and the level-3 criteria; `docs/14-human-gates.md`: level 3 is where the gates are stops
- [ ] Migration PRs: this repository (level 2), TargetApp (level 3, declaration), ProductApp (level per Q2)
- [ ] `gibson-ship` preflight reports the level in force beside the required contexts

Revisit when: an adopter at level 1 reports a same-vendor pass that a trailer check would have caught (tighten level 1 per Q6); a level-2 repository has run a month with no owner countersign (D-019's own revisit); or the sibling evaluator in TargetApp and this one disagree on a head (Q5 forces itself).
