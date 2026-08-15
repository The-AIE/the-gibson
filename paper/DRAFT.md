# The Gibson: an evidence-gated, cross-vendor harness for agent-driven software development, with a fully instrumented day of operation

**Mark R. Hinkle** — Peripety Labs (mrhinkle@peripety.com)

*Draft v0.1, 2026-08-15. Prepared with AI assistance (Claude Fable 5, Anthropic) under the
author's direction; all claims were checked against repository artifacts (issues, pull
requests, CI runs, commit attribution) that are cited inline and independently inspectable.*

---

## Abstract

We describe The Gibson, a software-development-lifecycle harness that coordinates coding
agents from four vendors (Anthropic Claude, OpenAI Codex, xAI Grok, Cognition Devin)
across production repositories under a single discipline: **no artifact is trusted on the
authority of the agent that produced it**. The harness relocates trust from agents to
machine-checkable evidence — exact-head review attestations, per-lane cryptographic bot
identities, CI sensors that classify their own health, and retired-fact checkers that
prevent corrected errors from being re-learned. Its self-improvement mechanism is
deliberately not agent self-modification: following the direction independently validated
by verifier-grounded harness optimization [2], every lesson is converted into the most
executable artifact feasible (CI sensor > audited doctrine rule > repository memory >
agent memory), and new checks enter advisory-first, promoting to blocking only after
their precision and recall are measured. We report a fully instrumented day of operation
(2026-08-15) during which the harness's newest sensor discovered two previously unknown
defects in its first execution; a three-round cross-vendor review cycle caught a
secret-exposure vulnerability twice — including once on a point of platform semantics
that both the implementing agent and the first reviewing agent missed; and the review
pipeline (implement → independent review → automated merge captain) operated end-to-end
without human intervention on routine work. We argue, against the single-agent
spec-convergence result of [1], that separation of review by *identity* (different
vendor) catches failure classes that separation by *referent* (fresh session, frozen
specification) cannot, because distinct models have distinct knowledge gaps; and we
adopt [1]'s convergence mechanics for the no-oracle case. Limitations are stated in
full: this is a single deployment, operated by its author, with small numbers.

**Keywords:** coding agents; multi-agent software engineering; code review; verification
loops; DevOps; self-improving processes.

---

## 1. Introduction

Coding agents are now fast enough that throughput is rarely the constraint. In the
27 days preceding the process audit that motivated this paper's measurement apparatus,
the primary repository under study merged 634 pull requests with a median time-to-merge
of 0.5 hours¹. The constraints that actually bound the system were, in order:

1. **Review authority.** A machine-enforced review gate existed, but the majority of
   merges cleared it through the human owner's attestation — the owner was the
   bottleneck, and the system had no metric for *which* route satisfied the gate.
2. **Blind sensors.** A required CI lane guarding authorization behavior had *never*
   passed in its lifetime, and nothing noticed: its failures carried no information
   because no one was reacting to them. A second lane — the only one that executed
   the deployed application — was later found to be in the same state.
3. **Prose rot.** Operational knowledge stored as prose (documentation, agent
   memories, audit premises) drifted from machine reality. On a single day, an
   auditing agent's premise and a coordinating agent's memory held the same wrong
   fact about the review gate's trust configuration, while the machine-readable
   config held the right one.

The Gibson is the harness built to attack these constraints. Its animating principle,
adopted as doctrine on 2026-08-15 after the evidence above accumulated in one session:
**a lesson only sticks if it is executable.** Prose is where knowledge goes to rot;
checks are where it survives.

¹ Figures from the 2026-08-14 process audit (Cognition Devin, commissioned by the
author); the audit's sampling of the most recent 30 merges found a trusted-provider
review at the exact merged head on 9, no trusted review at all on 11, and a stale
rejection from a superseded head on 8.

## 2. Related work

**Spec-first convergence.** Abenhaïm [1] reports a 189-file invariant-dismantling
refactor in a 717k-line codebase completed correctly on first execution with no human
review and no test oracle, via 14 specification-refinement cycles against the real
source and 17 code-versus-frozen-spec verification cycles (201 defects removed before
first run; stopping rule: two consecutive zero-finding passes). We adopt the
convergence mechanics for no-oracle work (§6.3) but reject the paper's implied
sufficiency of *referent* separation (fresh session of the same agent, audited against
a frozen document) as a substitute for *identity* separation: §7.2 documents a same-day
counterexample in which a second vendor's reviewer twice caught a security defect that
both the implementer and the first reviewer missed on knowledge grounds. [1] is a
single self-reported case and is treated as pattern evidence, not proof.

**Verifier-grounded harness optimization.** Kulkarni et al. [2] show that improving a
fixed harness's constraint verifiers and repair policies matches or beats recursive
agent self-modification at 4–5.5× lower compute, that 86% of realized gains flowed
through verifiers with F1 ≥ 0.80, and that verifier failures concentrate where the
underlying data lacks explicit fields. The Gibson's design predates our reading of [2]
but is convergent: invest in the checking substrate, gate automation on verifier
reliability, and fix observability before logic (§8). We adopt their repair ladder
(deterministic repair → bounded model repair → human escalation) for the harness's
planned auto-remediation stage.

**Cost-optimal routing.** Manoharan et al. [3] argue that enterprise agent spend
should be optimized on *expected cost per completed task* — pricing retries,
escalations, and wait time — rather than token cost, with routing organized by task
category × difficulty and deployed in stages. The Gibson's routing doctrine
(implementation to cost-efficient platforms, judgment to a top tier, human authority
reserved for owner-gated classes) is an instance of this framework arrived at
operationally; §7.2 supplies the kind of datum their framework prices: a
security-adjacent change whose nominal implementation cost was under a dollar of
inference consumed three implementation rounds and two adversarial review rounds
before it was safe to merge. [3] reports no empirical results; our outcome ledger
(§10) is positioned to supply exactly that class of evidence.

**Theoretical framing.** Promise Theory [8] holds that autonomous agents cannot be
obligated, only make voluntary promises about their own behavior, and that the
assessment of whether a promise was kept belongs to the promisee, never the promiser.
The Gibson is usefully read as an engineered instance of this: pull-request gate
fields (scope claims, isolation declarations, verification checklists) are promises
from identifiable agents; reviews and attestations are assessments by independent
promisees; the rule that no agent's self-declared PASS is evidence is not a policy
preference but the promise-theoretic structure itself. Burgess's application of the
framework to responsibility attribution for AI agents [9] parallels the harness's
owner-attestation model, in which a human's structured attestation is itself a
promise — one that accepts responsibility for agent-lane work — and the per-lane
credential-backed identities (§4.1) exist precisely so that promises have
attributable promisers. Three further correspondences from [8] are load-bearing
here. *Restricted vocabularies:* machine-assessed promises in the harness are
deliberately narrow grammars (structured evidence comments binding a head SHA and
result; exact-format intentionality annotations) — and §7.4 records a same-day
instance of a prose-formatted annotation failing assessment until it matched the
restricted grammar, precisely the comprehension-fidelity trade [8] predicts.
*Trust economics:* monitoring cost scales with distrust, so review depth is
tier-scaled — mechanical work gets checklist assessment, security-adjacent work gets
multi-round adversarial assessment. *Stigmergic coordination:* agents here
coordinate almost entirely through environmental memory — claims in open
pull-request bodies, standing report issues, repository doctrine — rather than
real-time messaging, which is what lets four vendors' agents cooperate without any
shared runtime; [8]'s warning that stigmergic memory is a security surface is the
prompt-injection class, and is why observed content is never treated as
instruction in this harness.

**Industrial practice.** Loop engineering [6,7] structures agent work as
outer-system-driven find/execute/check cycles with a second agent reviewing; Anthropic's
guidance recommends a reviewer with no memory of the change. Cloudflare's review system
processes tens of thousands of merge requests with domain-specialized reviewer agents
over human-authored code [11 in 1]; the Bun rewrite shipped a million generated lines
against a pre-existing million-assertion oracle [13 in 1]. The Gibson differs from all
three in that it (a) spans four vendors with enforced role separation, (b) operates on
repositories where agent-authored code is the norm rather than the exception, and
(c) treats its own process as the primary object of measurement.

## 3. What we are trying to achieve

The goal is **self-improving software development**, defined operationally, not
aspirationally: the system detects its own failures within one day; every detected
failure class is converted into an artifact that prevents recurrence without relying on
any agent's memory; the conversion itself is audited (prose-only lessons are tracked as
debt); and every new enforcement mechanism must prove its reliability on measured data
before it is allowed to act autonomously. Velocity is a consequence: the audit that
motivated this work found waste concentrated not in agent speed but in review rework
and misdirected implementation — so the harness spends its intelligence budget on
specification quality and review depth, and its automation budget on making the
feedback loops permanent.

## 4. System overview

The harness spans three production repositories (the harness's own repository, a
~4,100-model conference-management platform, and an AI-operated small-business website
product) and four agent platforms with a standing division of labor: implementation
routes to cost-efficient platforms (Grok, Devin), review and judgment to a top
reasoning tier (Claude, Codex), and the human owner retains exclusive authority over
money, consent, authentication boundaries, schema, and production promotion.

### 4.1 Roles and identity

Three roles are structurally distinct per change: **implementer**, **independent
reviewer**, and **merge captain**. The gate refuses review evidence from the identity
that authored the head commit (the same-actor block). This is enforceable only because
identities are real: each lane commits under its own GitHub App bot identity — with
per-lane private keys, commit author *and* committer set to the bot, and pushes
performed with the App's own installation token, never a human credential. Attribution
spoofing (bot email over human token) is treated as forgery and is itself documented
doctrine. Installation IDs are resolved live per repository rather than recorded,
because an organization transfer silently invalidated a hardcoded ID and broke the
push path for a week — an instance of the prose-rot class (§1) occurring in
configuration.

### 4.2 The evidence gate

Every pull request requires authenticated review evidence bound to the **exact current
head SHA**; any push or rebase invalidates prior evidence. Evidence routes, in
precedence order: a trusted provider's approving review at the head; a trusted
provider's structured evidence comment; an explicit owner attestation (a structured
comment embedding the head SHA). A trusted provider's *rejection* at the current head
overrides an otherwise valid owner attestation. Owner attestation is doctrine-defined
as a carve-out, not the default: the merge captain must check for trusted-provider
evidence first, and a stale rejection from a superseded head is not a verdict on the
current one. Since 2026-08-14 the merge audit classifies every merge by which route
actually cleared the gate, making duplicated review effort measurable rather than
anecdotal.

### 4.3 Sensors

CI lanes are treated as sensors, and sensors themselves are monitored. A daily job
classifies every active workflow from its recent run history: **BLIND** (≥3 completed
runs, never green — in the causal-information sense of [10], a channel whose verdicts
carry no information about the property it guards), **FAILING** (was green once,
none in the window), **IDLE** (with its latest-ever conclusion surfaced, so a failing
lane cannot hide by going quiet), or OK. Findings land in a standing issue updated in
place, with a notification comment only when the finding set changes. The loop is
advisory (the job itself stays green; a script error fails the job, making the loop
its own visible sensor), and it is watched from outside the platform by a weekly
scheduler because the platform silently disables scheduled workflows after 60 days of
repository inactivity — the watchdog exists precisely because the failure mode of a
watchdog is silence. Complementary sensors include a retired-facts checker (corrected
wrong beliefs become rules that no document may reassert), a test-integrity sensor
(dynamic test registrations and weakened assertions are blocked unless explicitly
annotated as intentional against an issue), commit-time DCO enforcement, and script
contract conventions (unknown-flag behavior, SHA-pinned actions, least-privilege
workflow permissions) enforced by a mutation-tested sensor suite.

### 4.4 The specification gate

Before an implementation lane is dispatched, the specification is scored against a
seven-line rubric (problem statement; testable acceptance criteria; edge cases;
hot-file/overlap claim; test plan with exact verification commands; rollback story;
tier classification) and — for non-trivial tiers — adversarially red-teamed by a
top-tier model asking, among other questions, *what will the implementer guess wrong?*
Findings amend the specification before any implementer sees it; the implementer brief
embeds exact verification commands and constraints (including which files other open
work has claimed). Gate scores are recorded per issue so a monthly audit can correlate
specification quality with downstream rework — if gated specifications do not reduce
review rounds, the gate is redesigned or dropped. For work with no test oracle, the
gate escalates to the convergence variant adopted from [1]: refine the specification
against the real source until a pass returns zero findings, freeze it, and audit the
implementation against the frozen artifact until two consecutive clean passes, inside
the tier's round cap.

## 5. Design patterns

The harness's recurring patterns, each of which exists because a specific failure
occurred and was converted upward on the artifact ladder:

1. **The artifact ladder.** Tier 1: executable check (sensor, hook, lint rule,
   retired-fact rule). Tier 2: doctrine rule plus a compliance auditor that measures
   adherence after the fact. Tier 3: repository memory readable by every agent.
   Tier 4: agent-local memory — never the only home of a lesson that affects others.
2. **Advisory-first promotion.** Every new check ships measuring, not blocking; it is
   promoted only after baseline data establishes its reliability. ([2] supplies the
   quantitative rationale: gains flow overwhelmingly through high-F1 verifiers.)
3. **Exact-head evidence.** All review evidence binds to a commit SHA; nothing carries
   across a rebase implicitly. Carryover across clean rebases is an explicit,
   fail-closed computation, not an assumption.
4. **Identity is credential-backed.** An attribution claim that is not backed by the
   matching credential's cryptographic action is treated as forgery, because the
   review gate's independence checks are only as real as the identities they compare.
5. **Live resolution over recorded configuration.** Anything an external platform can
   silently invalidate (installation IDs, deployment URLs) is resolved at use time.
6. **Fail closed, loudly, with the diagnosis in the failure message.** The
   authorization lane's redirect-loop detector names its own probable cause; the
   sensor-health report explains what BLIND means and how to act on it. A failure
   message is the documentation most likely to be read.
7. **One working directory per agent; claims are public.** Concurrent lanes operate
   in disjoint git worktrees with machine-checked file-scope claims carried in open
   pull-request bodies.

## 6. The feedback loops

Six standing loops, each with a trigger, a verdict mechanism, and a route by which a
verdict becomes an artifact:

| Loop | Cadence | Verifies / rejects |
| --- | --- | --- |
| Sensor health | daily | every CI lane's ability to carry information |
| Watchdog | weekly, off-platform | the sensor-health loop itself |
| Merge quality (review-path + cadence audit) | weekly | which route cleared each gate; burst and lag anomalies |
| Retro-to-artifact | on cap breach / repeat failure | that lessons became executable artifacts, not prose |
| Process audit | monthly | drift between documentation, memory, and machine config; review-authority distribution |
| Promotion review | scheduled after baseline windows | whether an advisory check's precision/recall justify autonomy |

The verify-or-reject flow for a single change composes: specification gate →
implementation in an isolated identity-bearing lane → CI sensors → independent
cross-vendor review at the exact head → evidence gate → automated merge captain →
post-merge sensors. Rejections route back to the implementer with the reviewer's
findings; acceptance is never self-declared.

## 7. A fully instrumented day (2026-08-15)

All artifacts cited here are public in the repositories' issues, pull requests, and
CI runs.

### 7.1 The sensor loop's first day

The sensor-health job's first dry run against the conference platform surfaced, in
addition to the known-blind authorization lane, **two previously unknown findings**:
the preview-deploy smoke lane — the only lane that executes the deployed application —
was itself BLIND (5 lifetime runs, never green), and the release workflow had failed
on every tag for nine days (its fix had landed on the default branch but was never
promoted to the release branch, and tag-triggered runs execute the workflow at the
tag's commit). Root-cause investigation attributed the smoke lane's lifelong blindness
to a deployment-protection bypass secret that had never been provisioned in any
repository, old or new.

### 7.2 Three review rounds on a secret-bearing workflow

The smoke lane's reconstruction (implemented by Grok, committed under the lane bot
identity) passed the author-side checks and this coordinator's independent review, and
achieved the repository's first-ever successful execution of the deployed application
in CI (9 assertions passed). It was then **rejected twice** by a second-vendor
reviewer (Codex): first for allowing a write-capable dispatcher to run branch-authored
test code with the bypass secret; then — after a fix that pinned checkout to the
default branch — for the subtler platform semantics that `workflow_dispatch` executes
the workflow *YAML itself* from the dispatched ref, so branch-authored YAML retained
secret access regardless of checkout. The final remediation removed the dispatch
trigger entirely and added a regression test asserting its absence. Both rejections
were verified against platform documentation before being acted on; both were correct.
We take this as direct evidence for the claim in §2: the first reviewer and the
implementer shared a knowledge gap that a fresh session of either would likely have
shared as well; a different vendor's model did not.

### 7.3 The pipeline without the human

On the same day, the measurement pull request that instruments review routes was
implemented by one vendor (Devin), independently reviewed and attested by another
(Claude, operating as delegated captain), and merged by the repository's automated
merge-on-green captain; a second and third documentation change flowed through the
identical path with the roles differently assigned. The human owner's direct
contributions to the day's nine merges were two one-time authorizations (a workflow
dispatch requiring elevated permissions, and app-installation clicks) — consistent
with the design goal of reserving human authority for genuinely owner-gated decisions.

### 7.4 The loops applying to their own rollout

The day also supplied the counter-evidence discipline the harness depends on: the
sensor conventions suite rejected the sensor-health workflow itself three times
(unknown-flag contract, unpinned actions, over-broad permissions) before accepting it;
the test-integrity sensor blocked the smoke suite's dynamic skip until it was
explicitly annotated; and the coordinating agent's own stale memory about the gate's
trust configuration was detected by comparison against machine config and corrected
into a retired-fact record. The harness does not exempt its own components.

## 8. What we deliberately did not build

**Agent self-modification.** Following the cost result in [2] and our own prose-rot
evidence, improvement effort goes into verifiers and configuration, not into agents
rewriting themselves. AutoDesign [11] demonstrates the opposite architecture
succeeding — recursive meta-harness optimization (+12.4% from a learned harness,
under $3 per autonomous loop) — but in a domain with a cheap, trustworthy automated
scoring oracle and contained blast radius. We read the two results as jointly
identifying the deciding variable: **oracle quality and rollout cost**, not
self-modification per se. Most of this harness's domain fails that test; the one
corner that passes it — the sensor scripts, which carry mutation-tested suites that
constitute exactly such an oracle — makes bounded meta-optimization of the sensors
themselves admissible future work rather than doctrine violation.

**Autonomous remediation (yet).** The sensor loops currently file findings; they do
not dispatch fixes. Promotion to a deterministic-first repair ladder (re-run /
re-enable / known-fix scripts, then at most one spec-gated model lane, then human
escalation) is scheduled for review against one week of measured sensor precision and
recall, with money/auth/consent/schema/production categorically excluded from
autonomous action.

**A single shared agent identity.** Convenience argued for it; the review gate's
integrity argued otherwise and won.

## 9. Limitations

1. **Single deployment, operated by its author.** Nothing here establishes a
   distribution of outcomes across teams or codebases.
2. **Small numbers.** One instrumented day; audit samples of 30 merges; sensor
   precision/recall windows measured in days.
3. **Self-reported.** The artifacts are public and independently inspectable
   (issues, PRs, CI runs, commit attribution), but the narrative selection is ours.
4. **Model dependency.** Results were obtained with specific frontier models in
   specific roles; the division of labor may not transfer.
5. **Cost accounting is partial.** Per-lane inference costs were logged for some
   lanes (individual implementation lanes on this day ran $0.13–$0.44 in inference)
   but not comprehensively across platforms.
6. **The central claims are one-sided tests.** The day shows identity-diverse review
   catching what referent-separated review missed; it cannot show how often the
   reverse occurs.

## 10. Future work

Measured promotion of auto-remediation (§8); extraction of the harness's proven
patterns into a versioned adoption pack any repository can stamp and keep in sync;
porting the retired-facts checker harness-wide; and the strongest test available to a
system like this one: publishing the outcome ledger's before/after deltas — review
rounds per change, avoidable attestations, time-to-detection, and expected cost per
completed task by route [3] — across a multi-month window, so both the harness's
value claim and its routing policy are falsifiable by its own instruments.

## References

[1] J. Abenhaïm. *Specification-first convergence with an AI coding agent.* arXiv:2608.12440, 2026.
[2] V. Kulkarni, S. Paul, A. Kumar, N. Tzou, S. Chappidi. *SBCO: Self-supervised, verifier-grounded harness optimization for planning agents.* arXiv:2608.10157, 2026.
[3] S. Manoharan et al. *Task-to-model optimization for enterprise LLM coding assistants.* arXiv:2608.08528, 2026.
[4] SWE-bench; [5] SWE-agent; [6] A. Osmani, *Loop engineering*, 2026; [7] Anthropic, agentic coding guidance, 2026 — as cited in [1].
[8] M. Burgess. *Cooperation in human and machine agents: Promise Theory considerations.* arXiv:2604.10505, 2026; M. Burgess, J. Bergstra, *Promise Theory: Principles and Applications*, 2014/2019.
[9] M. Burgess. *Legal responsibilities using autonomous agents for artificial intelligence.* arXiv:2608.08022, 2026.
[10] M. Burgess. *Information and causality in Promise Theory.* arXiv:2004.12661, 2020.
[11] Y. Luo et al. *AutoDesign: Meta-harness optimization for long-horizon agentic design.* arXiv:2608.13560, 2026.

*Repository artifacts cited throughout are available in the The-AIE organization's
public issue and CI history; the harness's own documentation index is
`docs/00-INDEX.md` in this repository.*
