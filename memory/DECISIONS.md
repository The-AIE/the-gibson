---
title: "Decisions"
nav_exclude: true
---

# Decisions (ADR-lite, append-only)

Format: what was decided · alternatives rejected · revisit condition.

## D-001 · 2026-07-24 · Git-markdown is the memory substrate
Decided: fleet memory = Markdown in this repo (lessons/decisions/incidents);
Mission Control's Supabase `memory` table stays for runtime coordination only.
Rejected: vector DB as primary store (ruflo's own data: HNSW pays off after ~1,000
trajectories; we have dozens), MC-table-as-primary (not versioned, not reviewable,
vendor-tied query path).
Revisit when: lessons exceed ~500 entries or grep-recall demonstrably misses.

## D-002 · 2026-07-24 · Agent-agnostic core, vendor-thin adapters
Decided: doctrine only in Markdown + scripts + CI; anything expressible only as a
vendor skill/hook is doctrine-debt.
Rejected: Claude-skills-first (locks the fleet to one runtime; ConferenceOS audit
showed skills were the only non-portable layer).
Revisit when: a runtime emerges that can't consume the core (would indicate the
core grew vendor assumptions).

## D-003 · 2026-07-24 · The Gibson governs itself with its own pipeline
Decided: harness changes are PRs through the same gates; human-gate list, tiers,
and hard-fail thresholds are Tier C.
Rejected: harness-as-config-anyone-edits (self-modification without gates is how a
fleet lobotomizes itself).
Revisit when: never — this one is load-bearing.

## D-004 · 2026-07-24 · Grind/Skilled/Frontier routing with flat-rate-first
Decided: G/S/F task grading; flat-rate pools absorb volume; metered tokens buy
judgment only; escalate on signal (2 same-criterion failures), de-escalate
quarterly on evidence.
Rejected: best-model-for-everything (cost pathology, L-003); cheapest-for-everything
(Tier C evaluation floor is S-grade — bad review is more expensive than good
tokens).
Revisit when: pool pricing changes materially.

## D-005 · 2026-07-24 · Foreman/CodeWright ship free inside the AIE subscription
Decided: no standalone paywall — the Chatterbuilt product (CodeWright + Foreman)
is a free add-on to the theaie.net membership; the MCP token is issued against
the subscription; monetization is the AIE flywheel (users → subscribers →
content → users).
Rejected (for now): audit-free/Blueprint-free/Foreman-paid gradient; standalone
suite pricing.
Revisit when: Foreman usage meaningfully exceeds AIE conversion, or fleet
compute costs per user demand direct pricing.

## D-006 · 2026-08-01 · Adoption is a ladder: enforcement before orchestration
Decided: a target repo adopts The Gibson in two separable steps, and the first one
does not imply the second.

- **Rung 1 — enforcement + doctrine.** Install `templates/target-repo/AGENTS-section.md`
  and `ci/gibson-gate.yml` (plus `ci/security.yml` / `ci/ux-eval.yml` where the repo
  has a preview deployment). Deterministic gates and a written agent contract. An
  interactive coordinator still carves scope, dispatches, and drives the merge train.
- **Rung 2 — orchestration.** Hand the repo to `scripts/loop.sh` / the solo loop
  (`docs/11-solo-loop.md`) to run unattended against its backlog.

A repo may sit on rung 1 indefinitely. Rung 2 requires all of: (a) the repo passes
`playbooks/adopt.md` cleanly, (b) at least one *other* target has demonstrated the
Phase 4 ratchet — an agent-authored harness PR merged through the pipeline, and
(c) the repo's production write path is hardened per `docs/20-delivery-control.md`
if merge ships to production.

First application: **ConferenceOS takes rung 1 now, rung 2 not yet.** It is the
largest target, carries a protected `release` branch and a live merge train, and
chatterbuilt (Phase 3) has not yet closed Phase 4. Adopting both rungs at once
would mean debugging the harness and the product in the same window.

Rejected: all-or-nothing adoption (made ConferenceOS look like a Phase 5 blocker
when its CI could benefit immediately); skipping the harness for big repos entirely
(loses the gates, which are the cheap half).
Revisit when: the Phase 4 ratchet closes on chatterbuilt — then re-evaluate each
rung-1 target for promotion rather than adopting a new one.

## D-007 · 2026-08-04 · Dependency/scope graphs are sensors, not an engine
Decided: keep graph structure implicit in the core; add narrow deterministic graph
*sensors* only where a failure class exists and only because they help build Gibson
itself — (1) a decomposition cycle + critical-path check beside `decompose-lint`, and
(2) a claim scope-overlap (independent-set) check in the claim path. No graph
database, no graph library, no "graph engine" in the core.
Rejected: rebuilding the harness as a "graph engineering harness" (violates D-002 and
primitives-not-features; the graphs are tiny — ≤ ~10 issues, ≤ 3 lanes — so
topological/critical-path/coloring buy nothing that `Blocked by` + serialization do
not); leaving both gaps unsensed (`decompose-lint` cannot catch a dependency cycle;
concurrency relies on string scope-match, the L-023 / 2026-07-18 clobber class).
Revisit when: a single plan routinely exceeds ~30 interdependent issues, or lanes
exceed ~8, where computed graph algorithms materially beat hand rules.

## D-008 · 2026-08-04 · Agent governance — adopt the vocabulary, not the runtime
Decided: The Gibson governs build-time SDLC; runtime agent governance (Microsoft
Agent Governance Toolkit, Mission Control) is a separate, downstream layer. Borrow the
shared standards — map the eight security layers to the OWASP Agentic Top 10, adopt
zero-trust per-actor identity (GitHub App / machine user per lane) to close the
shared-credential seam (docs/20), derive a trust score from retro evidence for routing
(docs/15) — but take no runtime-governance dependency into the core. See docs/25.
Rejected: adopting Microsoft AGT (or similar) as Gibson infrastructure (runtime-only,
Python middleware overlay — wrong layer, heavy vendor dependency, violates D-002);
ignoring the emerging standards (forfeits a governance claim buyers already
understand).
Revisit when: a runtime-governance need appears inside the harness itself (not the
products it ships), or the OWASP/CSA agentic standards consolidate enough to pin a
version.

## D-009 · 2026-08-04 · Per-project coordination knowledge graph is target-side
Decided: a knowledge graph to aid agent coordination belongs to the **target
project**, not the Gibson core — built as an adapter over that repo's existing issues
/ markdown / git (nodes: issues, claims, files/routes, lessons, decisions; edges:
blocks, touches, owns, supersedes), answering "what depends on this / who touches this
file / which lessons touch this route." Same adapter-over-substrate rule as
D-001 / docs/09. It enters the Gibson core only if it demonstrably helps develop the
Gibson (the D-007 sensors are the only current instance).
Rejected: a graph in the Gibson core for every project (couples the harness to a
graph runtime, violates D-002); a mandatory graph DB per target (heavy; most repos
are served by grep + labels); no coordination graph at all (leaves fast
"what depends on what" recall on the table for large targets like ConferenceOS).
Revisit when: a target's coordination load (issues × lanes × hot files) makes
grep-recall miss, or a spike shows the adapter beats labels/serialization on a real
repo.

## D-010 · 2026-08-27 · Ponytail/Caveman-style discipline enters as portable doctrine, not vendor plugins
Decided: the *rule* behind Ponytail (ponytail.dev — a YAGNI decision ladder: necessity check →
existing pattern → stdlib → native feature → installed dependency → one-liner → only then custom
code) and Caveman (token-minimal output discipline) is worth having in Gibson-driven work — it
restates doctrine already in every target repo's CLAUDE.md ("don't add features beyond what the
task requires," "three similar lines beats a premature abstraction"). Per D-002, it enters as
Markdown doctrine (a decision-ladder checklist in the relevant playbook/AGENTS.md section) plus,
if it earns its keep, a portable lint/audit script any vendor's lane can run — never as the vendor
plugins themselves. Caveman is a Claude-only skill; Ponytail's actual mechanism is a per-vendor
plugin (Claude Code, Copilot, Gemini each need their own install) even though its rule is
vendor-agnostic. Depending on either plugin as Gibson's enforcement mechanism would exclude every
non-Claude lane (Grok, Codex, Devin) from the check entirely.
Rejected: installing the Ponytail/Caveman plugins as Gibson infrastructure (violates D-002 —
doctrine expressible only as a vendor skill/hook is doctrine-debt); ignoring the idea because the
tools themselves don't fit (forfeits a real, low-cost discipline improvement that's already
proven out via the tools' own measured numbers).
Revisit when: a target repo's over-engineering rate (measured via retro evidence, not vibes)
justifies the audit-script half of this — i.e. `ponytail-audit`'s bloat-detection logic gets
reimplemented as a portable check rather than staying a claim on ponytail.dev's own numbers.
Until then, the decision ladder is available as doctrine text for any playbook that wants it;
using the actual Ponytail/Caveman tools interactively in an individual Claude session (not as a
Gibson-core mechanism) remains fine and separate from this decision.

## D-011 · 2026-09-05 · Tier C minimum review-independence level is E3 + owner merge
Decided: for #161's taxonomy (E0 self-check .. E4 human authority), the formal
minimum for Tier C changes is **E3 (cross-vendor independent review, exact-head
bound)** as the technical floor, with the repository owner's own merge action
required on top — matching G12 practice already in force. A cross-vendor E3
review is a claim, not proof: the merging party re-runs the checks and reads
the diff before merging on it (existing FLEET.md rule), so this does not permit
merging on an unread AI approval.
Rejected (for now): E4 (a named human reading the diff before any merge,
independent of the merge click itself) — assessed as materially slower per PR
without a demonstrated gap E3 + re-verified merge doesn't already close.
Revisit when: a Tier C merge ships a defect that E3 + re-verification should
have caught but a human diff-read would not have missed, or #161's remaining
tiers (A, B, schema, security, delivery-control) are decided and a consistent
scheme across all of them turns out to need Tier C revisited.

## D-012 · 2026-09-06 · Tier A/B minimum review-independence level is E2
Decided: for #161's taxonomy (E0 self-check .. E4 human authority), the formal
minimum for Tier A (routine) and Tier B (elevated) changes is **E2** — a
separate evaluator identity or same-vendor different model, independently
invoked and read-only. This sits above a same-actor self-check (E0) or a
fresh-context pass by the same actor (E1), which never count as independent,
but below the cross-vendor, exact-head-bound bar (E3) D-011 already set for
Tier C. Schema and security boundaries were not separately addressed here:
AGENTS.md's existing Risk tiers table already routes
money/auth/security-boundary/schema/prod-data changes into Tier C, so they
inherit D-011's E3 + owner-merge minimum rather than needing a distinct
decision. Delivery-control (AGENTS.md's own separate binding section, not
part of the Risk tiers table) is NOT addressed by this decision and has no
minimum yet — #161's acceptance criteria name it as its own owner decision,
and inferring one here would violate #161's own authority boundary.
Rejected (for now): requiring E3 for Tier A/B too — assessed as
disproportionate for routine/elevated work; E2 already rules out solo
self-review while not imposing cross-vendor overhead on every PR.
Revisit when: Tier A/B defect data shows E2 letting through what a
cross-vendor E3 pass would have caught, delivery-control's minimum is
decided separately, or a genuinely separate schema/security tier (distinct
from Tier C) is proposed.

## D-013 · 2026-10-08 · One attestation model: the independent reviewer clears routine work; the owner attests only three carve-outs
Decided (Mark, 2026-10-05 "Remove the owner gate everywhere except agent rule
files, secrets/billing, and schema migrations"; made the only model on
2026-10-08 after a fleet-process review): across The-AIE repositories a routine
pull request is cleared by an independent, cross-vendor reviewer at the exact head
plus the repository's required checks, never by the owner. The reviewer is the
independent-review App (`aie-independent-review[bot]`, reviewer-only, cross-vendor
to every author) where it is wired up (ConferenceOS today); in this repository and
Chatterbuilt, until the App is extended, a listed lane-bot reviewer identity or
CodeRabbit posts the receipt for a review another vendor performed. The owner attests only
the three carve-outs: (a) agent rule and control-plane files (AGENTS.md,
CLAUDE.md, `.github/`, `.agents/`, gate/classifier/merge-on-green/review-evidence
scripts and configs), (b) secrets, Stripe, billing, checkout, payments, api-key
and `.env` paths, (c) schema, migrations and `*.sql`. There is no owner
attestation queue for routine work, and machinery built around the owner signing
routine pull requests is the losing half and is deleted when touched. Agent work
is committed under a lane-bot identity, or under the owner identity with an
`Agent-Vendor:` trailer, so provenance resolves without an attestation.
Why: two models were running at once. The `review-evidence` gate was built to
need the owner's attestation; the owner then said he should not need to approve
or attest anything; the fleet then built the independent reviewer to route
around the gate it had built, while 122 of 139 ConferenceOS merges and 31 of 33
Chatterbuilt merges in the preceding 30 days were still authored as the owner.
Every agent had to work out which model applied, and the losing half kept
generating attestation-queue entries, owner alerts and stalled pull requests
(this repository had 11 open PRs all failing `review-evidence`). Lesson L-094.
Rejected: keeping routine owner attestation as a fallback (it is the second
model by another name); dropping `review-evidence` as a required check (the
check is what makes a reviewer's absence visible; L-087).
Revisit when: the independent-review App is extended to this repository and
Chatterbuilt (retiring the lane-bot/CodeRabbit receipt path), or when a carve-out
class proves to need no human after a quarter of incident-free delegation.

## D-014 · 2026-10-08 · The owner is out of the review loop: cross-vendor review clears every head, including the former carve-outs
Decided (Mark, 2026-10-08, evening: "Remove me from the loop, remove the labels,
fix everything, attribute the commits to Claude"): no pull request in a The-AIE
repository requires the owner's attestation, approval or label. Every head,
including the three classes D-013 reserved for the owner (agent rule and
control-plane files, secrets/billing/payments paths, schema and migrations), is
cleared by an independent cross-vendor review at the exact head plus the
repository's required checks. `needs-mark` and `decision` are no longer merge
holds and were removed from open pull requests. Agent commits are attributed to
their vendor: a lane-bot identity, or the owner identity with an `Agent-Vendor:`
trailer (Claude's work carries `Agent-Vendor: claude` until a Claude lane-bot
App exists). The hard blocks on ACTIONS in `~/.claude/FLEET.md` (handling
secrets and keys, billing and pricing changes, customer-facing legal pages,
destructive operations, commits and pushes nobody asked for) are unchanged:
they govern what an agent may do, not who signs a review.
Why: D-013 still left six Gibson PRs and two Chatterbuilt PRs waiting on one
person, and the harness's own fixes (#454, #457) were carve-outs by its own
definition, so the repository could not repair itself without him. The
review-independence rules (D-011 E3 for Tier C, D-012 E2 for Tier A/B) already
carry the safety; the owner signature on top of them was a second gate that
only stalled.
Rejected: keeping schema/migrations as the one remaining owner class (the
rehearsal gates in ConferenceOS and the cross-vendor review are the controls
that actually catch a bad migration; the signature caught none); keeping the
labels as advisory (a label that does not hold is noise).
Revisit when: a cross-vendor-reviewed change in a former carve-out class causes
an incident the owner signature would plausibly have stopped, or when a Claude
lane-bot identity exists and the trailer path can be retired.

## D-015 · 2026-10-09 · G12 is no longer a human gate: the Tier C floor is E3 plus required checks
Decided (Mark, 2026-10-09, "Go with 1", after asking whether G12 survived D-014):
for Tier C as AGENTS.md defines it (rule 7 and the Risk tiers table: money, auth,
consent/PII, security boundaries, schema, incident alerting, production data) the
human merge gate G12 is retired. A Tier C change requires **E3 (cross-vendor
independent review, exact-head bound) plus the repository's required checks**, and
no owner review, approval, attestation, label or merge action. This supersedes the
clause of D-011 that added "the repository owner's own merge action on top". No
class is dropped from Tier C: only the human merge gate is retired for it.
Adversarial review (fan-out), serialization of stateful changes and every other
Tier C requirement stand. Everything else in D-011 stands too: E3 is still a
claim, not proof, so the merging party re-runs the checks and reads the diff
before merging on it; E4 (a named human reading the diff) remains rejected. The
identifier G12 stays as a stable name for "Tier C review-independence floor" so
existing sensors, receipts and issue text keep resolving until each is amended.
What this does NOT change, stated so a reader cannot skip it:
- The hard blocks on ACTIONS in `~/.claude/FLEET.md` (secrets and keys, billing
  and pricing, customer-facing legal pages, destructive operations, commits and
  pushes nobody asked for), exactly as D-014 left them: they govern what an agent
  may do, not who signs a review.
- Delivery control (AGENTS.md "Delivery control (binding)"): audit, then
  dry-run, then explicit human apply. It is a separate rule and is not touched.
- The ratchet (AGENTS.md "Self-modification bounds"): changes to human gates,
  Tier definitions or hard-fail security layers are Tier C and "may only loosen
  with the owner's sign-off". This record is itself such a loosening, because it
  retires a human gate, and Mark's instruction above is the owner sign-off the
  ratchet requires for THIS change and no other. The ratchet clause is not
  amended here. How D-014 and that clause fit together for future loosenings is
  OPEN: D-014 and AGENTS.md read differently, and AGENTS.md stays the authority
  until an amendment to it merges; the question is listed for the inventory
  below. Until it is decided, any further loosening of a human gate, Tier
  definition or hard-fail security layer still needs the owner's sign-off as
  AGENTS.md says, and the amendments below may retire G12 as described and
  nothing more.
Merge operation for Tier C does not change: D-014 already clears every head on
E3 plus checks. This record exists so the doctrine stops saying something the
fleet does not do.
Known places that still describe the human gate (found by search on 2026-10-09,
not yet amended): AGENTS.md rule 7 (Tier C "gets ... a human merge gate (G12)"),
the G12 line in the human-gates list, the Tier C row of the Risk tiers table
("G12 human merge gate ... Min. E3 + owner merge (D-011)"), the release-role
forbidden list ("merging Tier C/schema without G12"), and the pre-merge checklist
line "Tier C / schema → G12 human approval recorded"; docs/06 (the Risk tiers
table, "human merge gate", and its checklist line "Tier C / schema → human
approval recorded (comment or approval from Mark)"); docs/14; and the GitHub
milestone R0 description, which ends "Tier C/G12 and owner gates remain". The
inventory in step 2 is the complete list.
Amendment order (each lands separately, the existing text and sensors stand until
its own change merges, none is done by this record):
1. This record (memory-only).
2. An inventory of every G12 reference (about 25 files, including the authority
   sensors and their fixtures, the policy candidate, and the formal-review,
   digest and decision-ledger scripts) with the proposed edit for each, plus the
   open D-014 versus ratchet question.
3. Doctrine text first (AGENTS.md, docs/06, docs/14, playbooks/release.md), then
   each authority sensor and fixture in the same pull request as the text it
   guards, so no sensor is ever red against its own doctrine.
4. The contracts that reference a human G12 event are rewritten to the D-015
   model. What the sources say, so the rewrite targets the right text: #225
   says Phase A "activates nothing" and that "Current G12 remains sole Tier-C
   merge authority", and specifies a report-only offline evaluator for a G12
   event comment posted by the `mrhinkle` actor (provider `github-human-owner`) at
   the exact head. #164 says to byte-preserve G12 "until B" and that "Only B's
   owner-approved contract changes release authority". D-015 is Mark's owner
   decision on that question for Tier C, so Phase B's contract is to be written
   to D-015 and does not wait for a separate owner decision on the same point.
   Whether #164, #140 and #160 carry other G12 requirements has not been checked
   and is part of the inventory.
Why: D-014 removed the owner from the loop, but D-011's owner merge action,
AGENTS.md's human merge gate for Tier C, the R0 milestone text ("Tier C/G12 and
owner gates remain") and the #225 and #164 contracts still describe an owner
signature that nobody provides. The R0 critical path runs #225 Phase A, the #161
decision, #225 Phase B and #164, and the R1 milestone lists R0's #208, #225, #161
and #164 as prerequisites of its own scope (#140, #160, #220, #96), so contracts
that encode the owner signature sit on the path to 1.0. The fleet card's rule
applies: doctrine and operation must not disagree.
Rejected: keeping G12 as a recorded but unenforced human gate (doctrine and
operation would disagree, the stale-rule failure); a narrower human gate for
money, consent and PII only (partly reverses D-014, which already rejected a
schema-only owner class).
Accepted risk: agents merge money, auth, PII, security, schema, incident-alerting
and production-data changes on one cross-vendor review, with adversarial review
still required. The floor must fail closed: with no E3 reviewer available the
change waits, it does not drop to a lower level. Reviewer availability is the
live weakness (Grok stalled repeatedly on 2026-10-09; Codex is registered in
config/review-evidence.v1.json with roles [author] only, #470), so availability problems delay merges instead of weakening them.
Revisit when: a Tier C change merged on E3 + checks causes an incident the owner
signature would plausibly have stopped; or Grok is the only E3 reviewer path for
Tier C for more than a week; or the amendment sequence above exposes a sensor
that cannot be reconciled without weakening it.
