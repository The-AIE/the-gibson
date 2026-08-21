# Research: "Specifying AI-SDLC Processes: A Protocol Language for Human-Agent Boundaries"

**Prifti (Birkbeck), De Meo (Messina), Provetti (Birkbeck)** — arXiv:2606.20615v3
(2026-08-16), under review at ACM TOSEM. https://arxiv.org/abs/2606.20615
Reference implementation open source (Apache 2.0):
https://github.com/snodo-dev/snodo, with a Lean 4 mechanisation of the core theorem.
Full read 2026-08-19 (Claude, Cowork session); filed as external validation and
prior art for the-gibson's thesis.

## Their thesis (which is our thesis)

> As foundation models converge, the durable engineering asset is the formally
> specified, executable process, not the model.

A DSL for AI-SDLC processes: protocols = modes + validators + disagreement
policy + constraints. The organising idea is **policy/mechanism separation** —
protocols declare intent; enforcement primitives (unforgeable validation
tokens, capability boundaries at the MCP tool layer, non-overridable blockers,
hash-chained audit log) realise it structurally. Theorem 4.4: for any
well-formed protocol the enforcement invariants hold on **every execution
trace** — validation cannot be skipped, reordered after execution, or
overridden by any agent decision, closed under recursive subtask spawning.

## The headline empirical result

On SWE-bench Verified, the **identical bug-fix methodology**:

- delivered as **prose prompt instructions** → statistically indistinguishable
  from no methodology at all (null in every run);
- delivered as an **executed, validated, self-correcting process** → **+14–22
  points absolute resolve rate**, replicated across seeds and two model tiers
  (n up to 191). Significance varied by run and comparator (Table 3 includes
  McNemar p=0.064, p=0.004 and p=0.015 cells alongside p<0.0001);
  https://arxiv.org/html/2606.20615#S6.SS5.

This is our "prose is advisory; gates are law" rule (FLEET.md, 2026-08-19)
measured under controlled conditions. Ablation: the gain is the *executed
loop* itself — plain advisory scaffolding matched the engine on the benchmark;
the engine's additional guarantees (non-skippability under drifting/adversarial
agents, audit, enforceable escalation) are exactly what oracle-graded
benchmarks structurally cannot score (their Corollary 4.2).

## Findings that map directly onto gibson doctrine

1. **Silent-failure/stall trade (Prop 4.1).** Structural enforcement bounds
   silent failure at a weighted product of agent and validator miss rates and
   converts the remainder into *visible, audited stalls*. Behavioural
   compliance does the reverse: zero stalls, cumulative silent failure
   (~0.45 at 5 pipeline stages, ~0.91 at 20 in their model; ~5.6× reduction
   under enforcement at N=5). Our needs-mark queue and hard blocks are the
   stall side of this trade — the queue backing up is the mechanism working.
2. **Validator correlation ρ justifies cross-vendor review.** Quorum benefit
   collapses as validators share blind spots (ρ→1 = one effective validator);
   "methodological diversity lowers ρ but cannot drive it to zero." Same-model
   review maximises ρ. This is the analytical case for our different-platform
   reviewer rule.
3. **Capability floor (Cor 4.3, observed).** Enforcement multiplies a capable
   agent and cannot substitute for one: on a ~15% base-capability coder the
   whole effect collapsed (recovery rounds re-sample the same failure
   distribution). Routing implication: don't send work to a weak model and
   expect the gates to save it.
4. **Model commodity.** Cheap model under the executed process (69.1%) beat the
   strong model bare (48.9–50.0%), p=0.0005; the process compresses the tier
   gap (69.1 vs 72.4 under process). Supports routing to the cheapest platform
   that clears the bar *provided the process is enforced* — the process layer
   is worth more than a model-tier upgrade.
5. **Task-tailored enforcement targets.** A generic elaboration-inducing
   protocol *reduced* bug-fix resolution (bigger diffs resolve less); the fix
   was inverting the target to minimality ("surgeon"), while feature work
   needs the opposite ("warden": decomposition + completeness + regression
   containment). Enforcement target must match the task class's failure mode —
   worth encoding in lane specs (bug lanes: minimality validator; feature
   lanes: scope/completeness validator).
6. **Byzantine asymmetry of hard gates.** One always-blocking validator stalls
   everything (fail-closed by design — cheap, loud, audited, one human
   adjudication); passing bad work requires compromising a quorum majority
   under unanimous. Their mitigations for false-blockers: severity caps,
   verdict-distribution monitoring — relevant to our sensor doctrine ("fix at
   source, never annotate around a correct catch" still holds; a *repeatedly*
   blocking validator is an operational signal).
7. **Separation of Duties as infrastructure (their 2+N / Axiom 1).** Producer
   mode cannot merge; reviewer mode cannot edit; disjoint tool sets at the MCP
   boundary; the only thing crossing the boundary is the artifact, carrying no
   authority. Our bot-identity + same-actor attestation gate approximates this
   socially; theirs enforces it at the tool layer. Adoption candidate for
   rung-2 hardening.
8. **Governance overhead ≈1% of inference latency** (33ms per governed task
   step vs ~3s inference). The overhead objection to structural enforcement is
   empirically small; the real cost is stalls, which is the intended trade.

## Honest limits (theirs and ours)

Evaluated on one task type (bug fixing), one open-weight model family, one
enforced primitive; quorums/2+N validated in simulation only. SWE-bench
contamination possible (paired design controls the between-arm gap, not
absolute rates). The theorem guarantees validation *occurs*, not that
validators are *good* — validator quality bounds system quality. Protocol
evolution governance (who may change a protocol, what review it needs) is
explicitly out of scope for them — that is precisely what our doctrine-change
rules (dated changelog + cross-vendor review) cover.

## Actions

- Cite as prior art alongside MetaGPT/FlowAgent/SAGA when writing up gibson's
  AQ externalization (ROADMAP) — their positioning section is a ready-made map
  of the adjacent formalisms.
- The-AIE/the-gibson#227 (ratchet advisory doctrine into gates) is the gibson
  move this paper validates; the +14–22pt result is the expected-value
  argument for finishing it.
- Candidate future adoptions, in rough order of value: task-tailored
  enforcement targets in lane specs (surgeon/warden split); tool-layer SoD for
  rung-2 targets; validation-token-style unforgeable evidence for gate
  outcomes (our per-SHA gate fields are the nearest existing analog).

## Source map — the full validation bundle (read 2026-08-19)

The paper above is the deepest single validation, but the architecture rests on
five independent literatures. Links for cold agents and future write-ups:

1. **Stigmergic coordination (repo-as-truth).** Bolici, Howison & Crowston,
   "Stigmergic coordination in FLOSS development teams," *Cognitive Systems
   Research* 38 (2016): distributed developers coordinate through the artifact,
   often more effectively than through discussion.
   https://www.sciencedirect.com/science/article/pii/S1389041715000339
   (program overview: https://crowston.syr.edu/stigmergy)
   We read this as support for treating the repository as the coordination
   medium (repo-as-truth).
2. **Self-preference bias (cross-vendor review).** Panickssery, Bowman &
   Feng, "LLM Evaluators Recognize and Favor Their Own Generations," NeurIPS
   2024: self-preference correlates linearly with self-recognition. We read
   this as: same-model review is structurally compromised.
   https://proceedings.neurips.cc/paper_files/paper/2024/file/7f1f0218e45f5414c79c0679633e47bc-Paper-Conference.pdf
   Follow-up quantification: https://arxiv.org/abs/2604.22891
3. **Intrinsic self-correction fails (external gates).** Huang et al., "Large
   Language Models Cannot Self-Correct Reasoning Yet," ICLR 2024: self-review
   without external signal often degrades answers. We read this as the case
   for external gates rather than self-review.
   https://arxiv.org/abs/2310.01798
4. **Failure taxonomy (governance is the bottleneck).** Cemri et al., "Why Do
   Multi-Agent LLM Systems Fail?" (MAST, 1,600+ annotated traces): ~42%
   specification/design, ~37% inter-agent misalignment, ~21% verification.
   We read this as: the large majority of failures are governance-layer, not
   model-capability.
   https://arxiv.org/abs/2503.13657
5. **Process-as-artifact (SOPs reduce cascading error).** Hong et al.,
   "MetaGPT: Meta Programming for a Multi-Agent Collaborative Framework,"
   ICLR 2024 (oral). https://arxiv.org/abs/2308.00352
   We read the AI-SDLC protocol paper above (arXiv:2606.20615) as superseding
   prompt-encoded SOPs with structurally enforced ones.

Caveat that travels with the bundle: convergent support, not end-to-end proof —
no study validates a four-vendor repo-governed fleet as a whole. Describe the
architecture as research-aligned, never research-proven.
