---
title: "Claude independent research memo"
nav_exclude: true
---

> **Authority:** Non-normative independent product research. This is advice, not source inspection, release review or permission to act.

Model: anthropic/claude-opus-5.5

Response: gen-1793374926-ynPJ48ogXiJh3gnCeSPS

Evidence scope: shared sanitized conceptual brief; no browsing or repository access. Final response preserved below; provider reasoning excluded.

---

# Advisory Memo: Description-to-Release Toolkit and Control Plane

**Status:** Independent product-design research. This is not release approval, certification or a statement about any existing system.

**Basis:** The owner-authored hypothesis, the generic capability descriptions provided, and the six public sources as they were described to me. I did not browse, inspect software or run evaluations. Characterizations of vendors restate those supplied descriptions or my general background knowledge, and any vendor claim needs fresh verification. Labels used below: **[Inference]**, **[Unknown]**, **[Disagreement]**.

---

## A. Critique of the hypothesis

**Restated hypothesis.** A vendor-neutral toolkit can take a nontechnical owner's description and turn it into four things:
- a product specification,
- a bounded scope of work,
- useful increments, and
- a verified release of reliable enterprise software.

**Central tension.** Two parts of the hypothesis pull against each other: the primary user is nontechnical, and the output must be reliable enterprise software.

**[Inference]** Code generation is probably not the binding constraint. The harder problems are:
- **Elicitation.** Does the spec capture what the owner meant?
- **Acceptance judgment.** Can the owner tell whether a scenario was truly satisfied?
- **Non-functional obligations.** Security, data handling, operations and compliance are things the owner cannot specify and cannot verify unaided.

A pipeline that is excellent at turning text into code can still fail at all three.

**Target user.** "Nontechnical owner plus one primary coding model" is a coherent and underserved user.
- It also concentrates risk. The coding model and the owner may share the same blind spots, and nobody with technical judgment sits between them.
- The design must therefore treat independence of verification as structural. Making review optional is not enough.
- **[Disagreement]** The owner should not be the final verifier of enterprise dimensions. For those, the product's honest promise is "we tell you which specialist sign-offs your profile requires." It cannot be "the toolkit verified it."

**Differentiation against the supplied alternatives.**
- **Spec Kit and Kiro specs** (sources 4) already describe a spec → plan/design → tasks flow inside a coding workflow. A plain "spec-driven" claim is therefore not differentiating.
- **OpenHands** (source 5) covers agentic execution.
- **Temporal** (source 5) covers durable workflow execution.
- **Langfuse** (source 3) covers tracing, prompt versions, datasets/evaluations and annotation.
- **Atomic** (sources 1–2) describes intent → criterion → task → evidence → review relationships and semantic provenance, which is close to this artifact-chain idea.
- **GitHub artifact attestations** (source 6) cover build provenance.

**[Inference]** The defensible differentiation is narrower than the hypothesis states. It has three parts:
1. **Owner-legible.** The evidence chain is readable by a nontechnical person.
2. **Enforced authority boundaries.** It is explicit who may change intent, acceptance criteria, evidence and the release decision.
3. **Profile-based enterprise readiness.** Readiness is checked against an applicable profile, not promised generically.

Everything else is integration. Integration is valuable but easy to copy.

**Strongest falsification cases**, any of which should change the plan:
1. **No outcome gain.** Owners using the full chain get no better outcomes than owners using Spec Kit or Kiro plus the same model and time budget, as measured by hidden acceptance tests.
2. **Evidence is not understood.** Owners cannot correctly answer "did this scenario pass, and how do you know?" from the evidence summaries. If so, the evidence is decorative.
3. **Green evidence, bad software.** Defects escape despite all checks passing, because the agent satisfies its own checks (test weakening, mocked behavior, scope narrowing).
4. **Spec drift.** After two or three requirement changes, the spec, scenarios and code diverge, and the chain stops being trusted.
5. **Overhead exceeds value.** Process cost (owner hours, tokens, waiting) exceeds the value for small projects, and enterprise profiles still need the same human specialists either way.

---

## B. Packaging: separate products vs shared contracts vs single repository/deployment

| Option | Strength | Risk |
|---|---|---|
| **Separate products** | Toolkit stays portable and adoptable alone | Duplicated concepts; the control plane invents its own state |
| **Integrated experience via shared contracts** | One mental model; both sides read and write the same versioned artifacts | Requires schema discipline early |
| **One repository and deployment** | Fast iteration, single release | Couples the toolkit to hosted infrastructure and erodes vendor neutrality; hard to undo |

**Recommendation:** shared contracts, staged reversibly.

1. **Stage 1: toolkit only.**
   - All artifacts are Markdown and structured front-matter in the project's Git repository.
   - The "control plane" is at most a generated read-only report.
2. **Stage 2: versioned artifact schema.**
   - Publish a schema covering IDs, states, links and evidence-bundle format.
   - Build a control plane that reads from Git and writes back only through commits and PRs. Decisions become committed records.
3. **Stage 3: consider co-repository or co-deployment.**
   - Do this only if measured friction justifies it, such as schema-sync bugs or release coordination cost.
   - Even then, keep a rule that the control-plane database is a rebuildable cache of the repository.

**Must remain portable:**
- the artifact files and schema,
- stable requirement, scenario and increment IDs,
- the decision log,
- evidence bundles and attestations, and
- the ability to run every check locally or in generic CI without the control plane or any specific model vendor.

**Component-specific cautions:**
- **Atomic, two separate questions.**
  - The supplied description says the Git shim documents limitations with linked Git worktrees. If isolated workspaces rely on `git worktree`, that path must be tested specifically or avoided.
  - The native project's copy-on-write sandboxes are a separate, non-Git-shim path, with different portability implications.
  - **[Unknown]** I cannot say how mature either path is. Treat Atomic as an optional provenance backend behind your own schema, not as the schema itself.
- **Langfuse.**
  - Cloud versus self-host choice, masking of prompts and outputs, and licensing all need assessment. Some features may be licensed differently from the core, and this needs verification.
  - Telemetry must never be the system of record for acceptance evidence.
- **Temporal.** Adopt only if long-running, failure-prone orchestration is observed. Git plus CI may suffice early.

---

## C. The human-readable artifact chain

| # | Artifact | Content | Who may change it |
|---|---|---|---|
| 1 | **Description** (D-vN) | The owner's own words, preserved verbatim and versioned | Owner only |
| 2 | **Clarification and unknowns register** | Questions, assumptions, open unknowns, each marked blocking or non-blocking, with an owner and a revisit trigger | Model proposes; owner resolves |
| 3 | **Accepted spec** (S-vN, content hash) | Goals, users and roles, behaviors, non-goals, applicable enterprise profile, trace links back to the description | Model drafts; **owner accepts**; the acceptance is a committed decision record |
| 4 | **Scope of work** | In scope, out of scope, assumptions, constraints, profile obligations needing specialist sign-off | Owner accepts |
| 5 | **Increments** (INC-n, pinned to S-vN) | User-visible slice, dependencies, scenarios covered | Model proposes; owner approves the order |
| 6 | **Acceptance scenarios** (AC-n) | Plain-language Given/When/Then, including negative and abuse cases; executable form linked | Owner approves the plain text; the executable form is authored **separately** from the implementing run |
| 7 | **Implementation** | PRs linked to INC and AC IDs, built in an isolated workspace | Coding model; **cannot edit** artifacts 3, 6 or 8 |
| 8 | **Independent evidence** | CI results run outside the agent's workspace, scenario pass/fail, diffs to test files flagged, reviewer identity (human or optional second model), build attestation | CI and reviewers only |
| 9 | **Release record** | What shipped, scenarios passed or failed, known gaps, open unknowns, profile sign-offs present or missing, rollback note | **Owner releases**; specialists sign their profile items |

**Versioning and changed requirements.**
- A change request creates a new description version and spec version.
- It also produces an impact report listing affected scenarios, increments and already-shipped behavior. Scenarios are marked superseded, never silently edited.
- Increments stay pinned to the spec version they were built against. A release record states exactly which spec version it satisfies.

**Unknowns.**
- A blocking unknown prevents spec acceptance for the affected section.
- A non-blocking unknown carries forward and must appear in the release record. Unknowns may not silently disappear.

**Authority rule.** No actor may both produce work and certify it. This applies especially to the coding model and its own tests.

---

## D. Value-ordered increments

**1. Description → accepted spec, scenarios and unknowns (no code).**
- *Benefit:* The owner sees their idea made precise, with gaps exposed before any money is spent on building.
- *Minimum deliverable:* The playbook plus a validator for IDs, links, unknowns and non-goals.
- *Acceptance:* The owner can explain back each scenario. Every requirement traces to description text or to a resolved clarification.
- *Negative cases:*
  - A contradictory description is flagged.
  - An ambiguous term becomes an unknown rather than an invented answer.
  - Missing roles or data sensitivity triggers profile questions.
- *Unproven:* That owners actually catch spec errors at this stage.

**2. One increment built in isolation with independent evidence.**
- *Benefit:* The owner receives a working slice plus a one-page evidence summary they can trust.
- *Minimum deliverable:* An isolated workspace, CI run outside the agent, a scenario-to-result mapping, and test-tamper detection.
- *Negative cases:*
  - The agent weakens or deletes a test, and this is flagged and the increment is blocked.
  - A failing scenario blocks "done."
  - An out-of-scope change is flagged.
- *Dependency:* Increment 1.
- *Unproven:* Whether hidden-test escape rates actually drop.

**3. Changed-requirement handling.**
- *Benefit:* The owner can change their mind safely.
- *Minimum deliverable:* A spec diff, an impact report, and superseded-scenario handling.
- *Negative case:* A change that silently breaks a shipped scenario is detected.
- *Dependency:* Increments 1 and 2.
- *Unproven:* That drift stays controlled beyond a few changes.

**4. Release evidence bundle with an applicable profile.**
- *Benefit:* A release the owner can defend to a customer or auditor, with gaps stated honestly.
- *Minimum deliverable:* A release record, artifact attestation (source 6), a profile checklist with specialist sign-off slots, and a rollback note.
- *Negative cases:*
  - Release is blocked when a required sign-off is missing, unless the owner records an explicit risk-acceptance decision.
- *Unproven:* That buyers value the bundle.

**5. Control-plane views over repository artifacts.**
- *Benefit:* Progress, pending decisions and blockers become visible without reading Git.
- *Minimum deliverable:* A read-only dashboard, with decisions captured as commits.
- *Negative case:* The control-plane state diverges from the repository; this must be detectable and rebuildable.
- *Unproven:* Whether this beats GitHub Projects with conventions.

**6. Optional telemetry, evaluation and multi-model review.**
- Includes Langfuse traces and datasets, a second-model reviewer, and durable orchestration.
- Adopt each piece only when a measured failure justifies it.

---

## E. First demonstrator and evaluation

**Demonstrator.** A small internal business application with real enterprise-ish obligations. Example: an expense or leave approval workflow with three roles, an audit log, personal data fields, CSV export and SSO-ready authentication.

**Matched baseline.**
- Same owner profile, same primary model, same time and token budget.
- Baseline condition: Spec Kit or Kiro-style specs (sources 4), or plain agent use, with no evidence chain.

**Held-out design.**
- Briefs are written by someone other than the toolkit designers.
- Hidden acceptance and abuse tests are authored independently before the build. Neither the owner nor the model sees them.
- Two held-out change requests are injected mid-project.
- Use several briefs and several owners if possible.
- **[Inference]** Sample sizes will be small, so treat results as directional and pair numbers with qualitative observation.

**Enterprise-readiness dimensions (profile-selected, not blanket):**
- authentication and authorization,
- data classification, protection and retention,
- audit logging,
- dependency and supply-chain hygiene (including attestation),
- backup, recovery and rollback,
- availability and operations runbook,
- accessibility,
- maintainability by a different team, and
- mapping to the customer's compliance requirements. The mapping is evidence for a human assessor, not a certification.

**Measures:**

| Area | Measures |
|---|---|
| **User value** | Owner-rated fit; owner's ability to correctly interpret evidence (quiz); decisions made with confidence |
| **Design quality** | Spec defects found later; traceability completeness; unknowns surfaced versus later discovered |
| **Delivery speed** | Elapsed time to first accepted increment and to release; owner hours |
| **Reliability** | Hidden-test pass rate; escaped defects; tamper or self-certification incidents; drift after change requests |
| **Total cost** | Model spend, compute, owner time, specialist review time, maintenance of the toolkit itself |

**When to simplify or reject:**
- **No hidden-test advantage.** If there is none over baseline, drop the custom pipeline and keep only the evidence and release-record layer on top of existing tools.
- **Evidence not understood.** If owners misread evidence, redesign the summaries before adding any features.
- **Unused control plane.** If the control plane adds no measured benefit over Git-native views, do not build it.
- **No reduction in specialist work.** If enterprise profiles still require full specialist review with no reduction in effort, reposition the product as a "readiness-gap reporter" rather than a "verified release" tool.

---

## F. Five consequential decisions

1. **System of record.** Git artifacts versus the control-plane database. Recommended: Git, with the control plane as a rebuildable cache.
2. **Verification independence.** Decide who authors executable acceptance tests and where checks run relative to the coding agent.
3. **Profile scope and claim language.** Decide which enterprise profiles exist and the exact wording of "readiness evidence," so that it never reads as certification.
4. **Isolation mechanism.** Choose among plain Git worktrees, containers, or an Atomic-style copy-on-write sandbox, and test the shim worktree limitation explicitly.
5. **Telemetry posture.** Decide self-host versus cloud, masking defaults, and licensing review before any customer data reaches traces.

**Non-obvious alternative worth testing.** Do not build a description-to-release pipeline at all. Build an **agent-agnostic acceptance-and-evidence verifier** that sits alongside whatever spec or agent tool the owner already uses (Spec Kit, Kiro, OpenHands). It would:
- hold the owner-approved scenarios and the unknowns register,
- run independent checks, and
- produce the release record.

**[Inference]** This may capture most of the differentiation at a fraction of the scope. It also directly tests whether the evidence chain, rather than generation, is where the value lies.
