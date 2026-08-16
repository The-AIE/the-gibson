# Evidence register — claim-by-claim artifact map

Companion to `DRAFT.md`. Every research-supporting claim, mapped to the specific,
publicly inspectable artifact that grounds it. Artifacts date from the instrumented
day (2026-08-15) and the 2026-08-14 process audit unless noted. Where evidence is
weak, one-sided, or secondhand, that is stated in the *Strength* column — this
register exists to make the paper falsifiable, not flattering.

Repositories: `COS` = The-AIE/conference-os · `GIB` = The-AIE/the-gibson ·
`CB` = mrhinkle/chatterbuilt.

## 1. Identity-diverse review catches what referent/self review misses (vs [1])

| Claim | Artifact | Strength |
| --- | --- | --- |
| First-vendor review (Claude) passed a secret-exposure defect | COS PR #1345, Claude review comment + owner attestation at head `27734b1b` | Direct; self-documented by the reviewer who missed it |
| Second-vendor reviewer (Codex) rejected at the same head, finding the exposure | COS #1345, `CODEX REVIEW RESULT: FAIL` comment (2026-08-15 15:20Z), finding 1 | Direct |
| Fix satisfying the obvious reading was again rejected on platform semantics (`workflow_dispatch` executes dispatched-ref YAML) | COS #1345, Codex re-review at head `c55f50d9`: findings 2/3/4 remediated, finding 1 NOT | Direct; the semantics claim was independently verified against GitHub docs before acting |
| Root fix: trigger removed entirely + regression test asserting absence | COS #1345 final head `bc86ee51`; contract suite 8/8 incl. `workflow_dispatch is absent so branch-authored YAML never runs with secrets`; merged 2026-08-15 16:06Z | Direct |
| One-sidedness caveat | — | The day shows identity-diverse review winning twice; it cannot show the base rate or the reverse case |

## 2. Blind sensors are zero-information channels ([10]); daily sensor-health makes blindness visible

| Claim | Artifact | Strength |
| --- | --- | --- |
| A required lane was red for its entire life, unnoticed | COS `clerk-authz-matrix`: 10/10 most-recent runs `failure` (queried 2026-08-14); COS issue #1336 | Direct |
| The only lane executing the deployed app was also blind | COS `preview-deploy-smoke`: 5 lifetime completed runs, zero green (sensor-health first dry run) | Direct |
| A third finding unknown to anyone surfaced on the sensor's first execution | COS `Release` workflow: `startup_failure` on every tag since 2026-08-06, last green 2026-07-22; root-caused to a fix merged to main but never promoted to the release branch (verified at tag `v0.1.21`); COS issue #1344 | Direct |
| The loop is live in three repos with standing reports | GIB #212, COS #1343, CB #503 (all created by first scheduled/dispatched runs, 2026-08-15) | Direct |
| The loop's own failure mode (platform disables schedules) is watched off-platform | Weekly watchdog scheduled task (operator-side), created 2026-08-15 | Configuration exists; not yet exercised by a real failure |

## 3. Verifier-grounded improvement; advisory-first; reliability gates autonomy ([2])

| Claim | Artifact | Strength |
| --- | --- | --- |
| Review-route measurement shipped advisory (no exit-code/gate change) | COS PR #1335 (merged 2026-08-14): `reviewPath` classification, `avoidableOwnerAttestation`; 19/19 tests at exact head, independently re-run by the reviewer | Direct |
| Automation is gated on measured sensor precision AND recall before promotion | Auto-remediation promotion review (scheduled 2026-08-21): thresholds and repair ladder in the task definition | Design exists; measurement window still open |
| Repair ladder deterministic-first is already practiced | Watchdog design: re-enable + re-dispatch before any model lane | Configuration; not yet exercised |
| Audit-motivating data: owner attestation dominated the gate | 2026-08-14 audit sampling of last 30 merges: trusted review at exact head on 9; none on 11; stale rejection on 8; 634 merges/27 days, median 0.5h | Secondhand (Devin audit, commissioned); sampling method not independently re-run |

## 4. Prose rot: executable config stays true while prose and memories drift

| Claim | Artifact | Strength |
| --- | --- | --- |
| Two knowledge stores held the same wrong fact; machine config held the right one | Devin audit premise & coordinator memory both asserted CodeRabbit was a trusted review provider; `.github/review-evidence-trust.json` (last changed PR #1056) lists only Devin. Correction recorded on COS #1334 + retired-fact memory update | Direct |
| An org transfer silently broke every prose/config copy of a fact | Stale `mrhinkle/*` paths 403ing for App tokens across AGENTS.md/CODEX-HANDOFF/STATE.md (fixed: COS PR #1338, 115 replacements); hardcoded installation ID `150306241` invalidated (live: `153142627`) breaking the push helper; Devin blueprints stale | Direct |
| Countermeasure: live resolution over recorded config | `bot-commit.sh` resolves installation IDs via `GET /repos/{owner}/{repo}/installation`; STATE.md registry deliberately records no installation IDs (COS PR #1346) | Direct |
| Countermeasure: retired-fact rules prevent re-learning corrected errors | COS `scripts/check-doc-facts.mjs` (9 rules, run in PR CI; exercised on PRs #1338/#1347) | Direct |

## 5. Promise-theoretic structure ([8],[9],[10])

| Claim | Artifact | Strength |
| --- | --- | --- |
| Assessment belongs to the promisee: a self-declared PASS is never evidence | Same-actor block (gate refuses evidence from head-commit author); 2026-08-15 instance: coordinator's owner attestation at `27734b1b` **overridden** by trusted provider rejection — receiver authority operating against the coordinator itself | Direct |
| Restricted vocabularies are enforced, and prose fails assessment | Two same-day instances: (a) test-integrity sensor rejected a prose intentionality annotation until it exactly matched `intentional #<issue>` (COS run 31891116211); (b) GIB conventions sensor rejected `unknown flag(s):` wording — contract regex requires literal `unknown flag:` (GIB run 31888219805, rc=2 yet FAIL) | Direct |
| Promises need attributable promisers: credential-backed per-lane identities | Probe commits attributed `author=committer=aie-agent-lanes-mini[bot]` and `...-grok[bot]` (pushed with each App's own token, then deleted); registry in COS STATE.md (PR #1346); forgery doctrine documented after a real 2026-08-03 incident | Direct |
| Stigmergic coordination: four vendors, no shared runtime | Coordination artifacts only: `Active-work claim` lines in open PR bodies (machine-queried before every lane), standing sensor issues, repo doctrine; day's work spanned Claude/Codex/Grok/Devin with no inter-agent messaging | Direct, descriptive |

## 6. Cost-per-completed-task beats token accounting ([3])

| Claim | Artifact | Strength |
| --- | --- | --- |
| Nominal implementation cost is a poor proxy for completed-task cost | Smoke lane: logged Grok inference for the three implementation rounds ≈ $0.44 + $0.31 + $0.13, plus two Codex adversarial reviews and coordinator reviews, three CI proof cycles, before safe merge | Partial: agent-side inference logged; reviewer/coordinator costs not metered |
| Throughput was never the bottleneck | 634 merges/27 days, median 0.5h (audit) | Secondhand |

## 7. The pipeline operates without the human on routine work

| Claim | Artifact | Strength |
| --- | --- | --- |
| Implement→independent review→automated merge, humanless | COS #1335: Devin implemented, Claude reviewed+attested (carve-out, Devin was implementer), automated merge-on-green captain merged. COS #1338 and #1342: captain merged both before the coordinator could — beaten to it twice | Direct |
| Human actions on the day were owner-gated only | Two authorization classes: an elevated-permission workflow dispatch, and App-installation clicks | Direct, self-reported inventory |
| Day totals | 9 merges across 3 repos (COS #1335, #1338, #1342, #1345; GIB #211, #215; CB #500, #501, #502) + 3 PRs pending review pipeline at day's end | Direct |

## 8. The harness does not exempt itself

| Claim | Artifact | Strength |
| --- | --- | --- |
| The sensor suite rejected the sensor-health workflow three times before accepting it | GIB runs 31887481069 (unknown-flag rc=1; unpinned action; workflow-level write perms) and 31888219805 (wording contract) | Direct |
| The test-integrity sensor blocked the smoke suite's own skip | COS run 31891116211 | Direct |
| The coordinator's stale memory was detected and converted to a retired-fact record | CodeRabbit-trust memory corrected 2026-08-15 (see §4 row 1) | Direct |
| Stacked-PR process defect found and recorded | GIB #216 auto-closed when its base branch was deleted on #215's merge; recreated as #218 with the lesson in the PR body | Direct |

## 9. Convergence mechanics adopted from [1]; oracle construction from [12] — status

| Claim | Artifact | Strength |
| --- | --- | --- |
| Convergence variant encoded (refine-to-convergence, frozen spec, two-consecutive-clean) | `spec-gate` skill v1.1.0 (master-skills), 2026-08-15 | Encoded; not yet exercised on a real no-oracle task |
| Tier-capped rounds with human escalation (the cap the convergence runs inside) | GIB #215 merged; #218 (caps config A:1/B:2/C:3, fail-closed resolver) pending merge at register time | Direct / in flight |
| Flow-contract oracle construction | Future work only (DRAFT §10) | Not implemented |

---

*Register compiled 2026-08-15 by the coordinating agent (Claude Fable 5) from
session-verified artifacts; secondhand rows are marked. Update this file whenever a
DRAFT claim changes or a "not yet exercised" row gains its first real exercise —
an evidence register that rots becomes the §4 failure class it documents.*
