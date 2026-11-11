---
title: "Should we adopt OpenSpec?"
nav_exclude: true
---

> **Authority:** Non-normative research addendum. This recommendation changes no repository contract, installs no tooling and grants no implementation, merge or live-operation permission.

# Should we adopt OpenSpec?

## Recommendation

**Trial OpenSpec as the readable specification/change layer before building our own.** Use the existing Gibson execution/evidence machinery and Agent Kontrol presentation. Decide wider adoption from one bounded comparison, rather than migrating the backlog immediately.

This answers the owner's later OpenSpec question. It is Codex source research, not a recommendation independently reviewed by the four external model contributors. The website reader was unavailable and an automated site fetch returned 403; research used the project's public repository, whose README identifies openspec.dev as its documentation home. No installation, initialization or functional drive was performed.

## Version and evidence

Inspecting the release API and source identified **v1.15.0**, published October 24, 2026, at **8e0288df12d401b0e183e2f47254d22528c1dffb**. The decisive README, license, CLI/agent-contract/Stores docs, verification template and default schema have identical Git blob IDs at that release and inspected main **6d04a1b58dedc95729d34e4f223d9d483aae210a**. The findings below therefore apply to that release, rather than assuming moving-main features are released. [Release](https://github.com/Fission-AI/OpenSpec/releases/tag/v1.15.0).

The source is MIT-licensed. The npm path requires Node 20.19 or newer; standalone binaries are also distributed. This establishes distribution choices, not installation safety or zero total cost; model/runtime/maintenance costs remain separate. [README](https://github.com/Fission-AI/OpenSpec/blob/8e0288df12d401b0e183e2f47254d22528c1dffb/README.md), [license](https://github.com/Fission-AI/OpenSpec/blob/8e0288df12d401b0e183e2f47254d22528c1dffb/LICENSE).

## What we should reuse

| OpenSpec asset | Fit in Goal 1 | Gibson connection still needed |
|---|---|---|
| Change proposal | Why this change, intended outcome and boundaries | Record accepted intent/version and unresolved consequential decisions |
| Capability requirements and scenarios | Readable product behavior and proposed deltas | Stable requirement references, meaningful tests and applicable assurance |
| Design artifact | Technical choices and consequences | Existing architecture constraints and independently reviewed implementation |
| Tasks and artifact dependencies | Candidate implementation scope | Useful release slices, existing-work reconciliation, admitted issues/claims and dependency checks |
| Status/validation/assistant guidance | Consistent artifact handling across tools | Interpret status narrowly and preserve current role/contract outputs |
| Sync/archive | Maintain specs and change history | Explicit acceptance/evidence binding, recovery and actual release status |

These are documented/source capabilities, not our tested integration. The default workflow is defined in the [released schema](https://github.com/Fission-AI/OpenSpec/blob/8e0288df12d401b0e183e2f47254d22528c1dffb/schemas/spec-driven/schema.yaml).

## Preserve distinct meanings of done

The machine contract's `isPlanningComplete` and compatibility alias `isComplete` mean planning artifacts exist. They do not mean implementation is done. Task/apply progress is another fact. [Agent contract](https://github.com/Fission-AI/OpenSpec/blob/8e0288df12d401b0e183e2f47254d22528c1dffb/docs/agent-contract.md). Lowercase `x-` metadata offers a possible reference hook without forking, but OpenSpec treats it as opaque; Gibson must validate any evidence/authority binding it owns. [CLI metadata contract](https://github.com/Fission-AI/OpenSpec/blob/8e0288df12d401b0e183e2f47254d22528c1dffb/docs/cli.md).

The assistant verification workflow covers completeness/correctness/coherence and explicitly distinguishes apply state from a verification verdict. It is useful guidance, not Gibson's independent exact-head review or a demonstrated deployment. [Verification template](https://github.com/Fission-AI/OpenSpec/blob/8e0288df12d401b0e183e2f47254d22528c1dffb/src/core/templates/workflows/verify-change.ts).

Archive merges deltas into main specs and moves the change; CLI options include skipping spec updates or validation. **Archived cannot mean shipped.** Some archive failures may follow partial filesystem effects, so inspect before retrying. Structural validation, checked tasks and synchronized specs cannot substitute for required tests/review/deployment evidence. [CLI contract](https://github.com/Fission-AI/OpenSpec/blob/8e0288df12d401b0e183e2f47254d22528c1dffb/docs/cli.md).

## One canonical home per fact

Trial the OpenSpec requirement/change artifacts as the specification input and produce the current required Gibson PLAN/numbered-criterion and issue-contract handoffs from that version. Keep an explicit source/version link and avoid two independently writable copies of the same requirement. The trial must settle the mapping before a real adoption; this document does not change the planner's required output.

Keep GitHub source/checks/reviewer identity, deployment observations and Agent Kontrol transactional runtime facts authoritative in their current homes. OpenSpec task completion cannot acquire a claim, override a denied gate, or authenticate a release. Its change folder is a planning unit; it does not replace physical worktree isolation or cross-host claim admission.

Stores provide a separate Git-backed planning home but are **beta** and do not automatically push/pull or route implementation to the right code repository. Start the first trial in one existing repository. Introduce a Store only if actual cross-repository ownership requires it. [Stores guide](https://github.com/Fission-AI/OpenSpec/blob/8e0288df12d401b0e183e2f47254d22528c1dffb/docs/stores-beta/user-guide.md).

## Bounded trial and adoption decision

1. Select one small existing/brownfield capability and a later requirement change. Refresh its current implementation, owner and claims first; admission is separate from this proposal.
2. Pin v1.15.0 and inspect generated assistant/configuration files before any init/update in an admitted workspace. Disable optional telemetry for the trial unless separately chosen. Existing AGENTS/role/review authority remains binding.
3. Produce proposal/spec/design/tasks and the required Gibson handoffs; compare against current templates at matched context and effort. Measure invented/missed requirements, owner clarification effort, scenario coverage, useful scope and change maintenance.
4. Connect one acceptance scenario to exact-source evidence, show unknown deployment honestly, and exercise the changed requirement. Agent Kontrol presentation is optional for this first comparison.
5. Adopt more broadly only if the owner understands scope better or total rework falls at acceptable maintenance cost. Keep the existing files as an exit path. A failed trial may justify simpler artifacts instead of a new framework.

**Negative cases:** valid/complete planning with failed tests; archived tasks without a verified deployment; stale spec/source/review bindings; an unknown authority decision treated as accepted; unresolved/wrong Store or repository selection; a modified requirement dropping an existing scenario; interrupted archive with partial effects. Each must remain visible and must not produce an invented release claim.

No blanket superiority over Spec Kit/Kiro is established by OpenSpec's own comparison copy. The trial should compare actual current behavior, rather than reproduce vendor positioning as independent evidence.
