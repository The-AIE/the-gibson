---
title: "Ecosystem and product positioning"
nav_exclude: true
---

> **Authority:** Non-normative research proposal. Binding behavior remains in AGENTS.md; this document adds no gate, permission or deployed capability.

# Ecosystem and product positioning

Official documentation was inspected on **2026-10-30**. These are documentary capabilities, not our hands-on performance, security or enterprise-readiness certification. Vendor claims remain vendor evidence until reproduced.

## Map the layers before choosing tools

| Layer | Existing offering or seam | Research implication |
|---|---|---|
| Product/specification workflow | GitHub Spec Kit, Kiro, Gibson planner/decomposer | Compare planning fidelity and usable scope before designing another spec framework |
| Coding-agent execution/workspaces | Existing coding agents, OpenHands | Keep execution replaceable; a runner does not own product acceptance or release authority |
| Intent/change/provenance | Git/GitHub and Atomic.dev | Significant overlap with the proposed traceability value; evaluate reuse rather than assume an empty market |
| Runtime coordination/owner experience | Agent Kontrol | Existing task/decision/progress surfaces are a plausible integration home |
| AI telemetry and evaluation | Langfuse/OpenTelemetry | Integrate observations/experiments rather than create a second trace product |
| Durable execution | Existing transactional jobs/events, optionally Temporal | Select from measured recovery needs; do not require a new workflow cluster for the first spec |
| Build/source provenance | CI and GitHub artifact attestations | Reuse evidence binding; provenance and secure/useful behavior remain different claims |
| Product-to-release explanation | Candidate Gibson + Agent Kontrol experience | Differentiation is a hypothesis about understandable, accountable outcomes across tools |

## Atomic.dev: overlap and optional interoperability

Atomic describes a semantic change graph linking intent, criteria, tasks, code changes, evidence, provenance and review. That overlaps directly with a traceability-led Gibson proposition. It merits comparison as an adjacent alternative or adapter, not dismissal as an app generator. [Official features](https://atomic.dev/features/).

Evaluate its native model separately from Git compatibility. Basic views share a working copy; the current Git shim does not manage linked Git worktrees. The native repository also documents copy-on-write sandboxes and OCI stage/seal facilities, so it would be wrong to infer that Atomic lacks physical isolation generally. [Git shim and known limits](https://docs.atomic.dev/getting-started/git-shim), [native project](https://github.com/atomicdotdev/atomic).

Proposed experiment: a disposable repository, with separate native-sandbox and shim tracks, tests source/change identity, isolated edits, scope, stale-review rejection, evidence preservation, crash/replay and export/exit. Compare against the current Git-native approach at matched work. Published performance improvements are not reproduced results. No live adoption, installation, hook replacement or migration is authorized by this package.

## Langfuse: measurement adapter

Langfuse documents tracing, model cost/latency, prompt versions, datasets/experiments, annotations, feedback and evaluation. Its OpenTelemetry support makes it a candidate for observing the planning/execution/learning chain. Link observations by stable product/spec/increment/run/evidence identifiers; an evaluation score never grants independent reviewer identity or release authority. [Overview](https://langfuse.com/docs).

Its deployment is a separate decision. Self-hosting includes web/worker services and several storage components; a local Compose trial is not high-availability operation. Review the core/commercial feature boundary and data-handling obligations before adoption. [Architecture](https://langfuse.com/self-hosting), [license boundary](https://langfuse.com/self-hosting/license-key).

Default experiment content should be identifiers, timings, category/verdict and observed usage/cost. Full prompts, source and transcripts need a deliberate data/retention decision. Masking must be checked on the actual export path. [Masking](https://langfuse.com/docs/observability/features/masking). No Langfuse instance or data export is activated by this research.

## Specification toolkits

GitHub Spec Kit documents a specification-to-planning/tasks/implementation process with agent integrations. Benchmark or adapt its artifacts; Gibson must demonstrate value beyond producing similar documents. [Official documentation](https://github.github.com/spec-kit/).

Kiro documents feature specifications and a shorter quick-spec path. It is a useful comparator for varying ceremony with uncertainty and risk. The first user should not need a large architecture ritual for a familiar bounded fix. [Feature specs](https://kiro.dev/docs/specs/feature-specs/), [quick spec](https://kiro.dev/docs/specs/quick-spec/).

A comparison should measure invented requirements, constraint preservation, owner correction effort, useful decomposition, change impact and verified delivery—not document length or which vocabulary a tool uses.

## Execution and durability

OpenHands provides execution/workspace/sandbox components with differing deployment/license choices. It is an adapter candidate, not a reason to create another agent runtime or weaken repository acceptance. [Component overview](https://docs.openhands.dev/overview/introduction).

Temporal provides durable execution and recovery mechanisms. Compare it only if current transactional jobs/events cannot satisfy actual crash/replay/human-wait requirements at acceptable cost. It is optional infrastructure, not a prerequisite to getting a readable spec accepted. [Durable AI execution](https://docs.temporal.io/ai).

## Supply-chain evidence

GitHub artifact attestations can bind build artifacts to source/workflow identity. Verification of provenance does not establish secure code, a completed user journey, or permission to launch. Reuse that evidence where appropriate rather than invent signing infrastructure in the product's first increment. [Artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations).

## Candidate build/integrate/defer boundary

**Own, if validated:** understandable product intent/decisions; requirement-to-useful-increment linkage; applicable evidence contracts; and a truthful explanation of readiness, release and observed outcome.

**Integrate:** planning artifacts where they fit, coding agents/workspaces, source hosting/CI/deployment, optional Langfuse/OTel measurement, and optional Atomic provenance after compatibility evidence.

**Defer:** a replacement VCS, generic scheduler, mandatory graph database, full observability backend, compulsory multi-model consensus and literal repository consolidation. Revisit a deferred item when the comparison identifies a real unmet need and includes operating/migration/exit cost.

The evaluation must permit an ecosystem product to remove a Gibson work item. An architecture that insists on owning every overlapping layer has not yet demonstrated its value.
