# 20 — Multi-Model Orchestration: the Coordinator Pattern

How one persistent coordinator model runs a fleet of stateless worker models
(implementers and reviewers from different vendors) without shared memory,
shared inboxes, or humans relaying status. Captured from live operation of the
ConferenceOS support/CRM slate, 2026-07-28/29.

## The shape

One **coordinator** (a session with persistent context, memory, and judgment)
owns the task graph end to end. Every other model is a **worker**: dispatched
headlessly, stateless, and disposable. Workers implement, review, or research;
the coordinator decides, sequences, verifies, and merges.

```
            ┌────────────── coordinator (persistent) ──────────────┐
            │  plans · dispatches · monitors CI · verifies · merges │
            └──┬───────────────┬───────────────┬───────────────────┘
     spec ▼        spec ▼          spec ▼
   implementer      reviewer        researcher
   (e.g. Grok)     (e.g. Codex)    (any vendor)
   cold start      cold start      cold start
   stdout back     stdout back     stdout back
```

## Communication model — there is no channel

Workers never talk to each other, never watch the repo, never poll status, and
never remember prior runs. All coordination is **hub-and-spoke through the
coordinator**:

- **Dispatch is the only input.** A worker gets one prompt. It must carry the
  repo path, exact files, all relevant facts, and acceptance criteria. If the
  spec doesn't contain it, the worker doesn't know it.
- **Stdout is the only output.** The worker's final output returns to the
  coordinator as a command result. No side channels.
- **Status lives with the coordinator.** CI state, PR state, merge order, and
  "what happened while you were running" are the coordinator's job, watched via
  its own monitors (poll loops on checks/PRs that wake it on events). Never ask
  a worker to "check how things are going" — it can't, and shouldn't.

The human never relays between models. If the operator has to tell model B what
model A did, the orchestration has failed.

## Rules that hold under fire

1. **Cross-vendor review, no exceptions.** The model that wrote a change never
   reviews it. Grok implements → Claude or Codex reviews read-only. When the
   coordinator itself authors a fix, it dispatches a *different* vendor to
   review before merging — self-approval is the failure mode this entire
   pattern exists to prevent.
2. **A worker's PASS is a claim, not proof.** The coordinator (or reviewer)
   re-runs the checks and reads the actual diff. Trust nothing that wasn't
   independently re-verified. (Live example: an implementer's "green" schema PR
   was missing half its spec and failed 8 CI checks.)
3. **Anything merged unreviewed gets reviewed anyway.** When merges outrun
   review (operator-driven bulk merges, overnight lanes), the coordinator runs
   a **retroactive adversarial review**: export the merged diffs, dispatch a
   different vendor with an explicit defect-hunting brief per surface
   (mail loops, token handling, injection, authz), demand
   "checked, absent" for every hunted class so silence ≠ safety.
4. **Wait out required checks before merging.** The one time this was skipped,
   main was broken for twelve hours by an import path a first-run CI build had
   already caught. Velocity gained: ~30 minutes. Velocity lost: a day of
   coordinator repair work.
5. **One working directory per agent.** Worktree per lane, disjoint file
   scopes. A coordinator arriving at a checkout that another agent has dirty
   does its work via the hosting API instead of touching that tree.
6. **Specs never carry secrets.** Dispatch ships context to that vendor's
   backend. Secrets move by **blind pipe** — shell commands that transfer
   values from source to destination with prefix-only verification printed,
   so no model's context (coordinator included) ever holds the value.
7. **Fix forward in a dedicated lane.** When worker output breaks the trunk,
   the coordinator repairs it in its own worktree lane: reproduce → fix →
   independently verify (typecheck, lint, targeted tests, full build) →
   cross-vendor review → merge. Repair scope grows honestly (each fix may
   unmask the next failure) but stays in one reviewed PR.

## Failure modes this pattern caught (one night, one repo)

| Failure | Cause | Doctrine that caught it |
|---|---|---|
| Build broken on trunk | merge before required checks | rule 4 |
| Type errors merged | worker never ran tsc; CI OOM masked it | rule 2 |
| Half-implemented spec merged | spec amended after dispatch; worker built from stale issue | rule 2 (reviewer diffs against the *current* spec) |
| Every deploy failing drift check | worker edited an **already-applied migration** — migrate deploy skips applied names, so late edits silently never run. Fix: new guarded delta migration; never edit an applied one | rule 3 |
| 15 latent P1s in production code path | unreviewed merges | rule 3 (retro review found them before traffic did) |

## Shared-credential collisions — the rule learned last

When every actor (coordinator, lanes, the human) operates under ONE account,
two failure modes appear that solo operation never shows:

- **The coordinator merges a lane mid-flight.** A PR that looks done may have a
  driver mid-fix reacting to its own dispatched review. Before attesting or
  merging anything: check commit/comment recency (younger than ~30 min = an
  active lane — coordinate on the thread first) and look for in-flight review
  signals. "CI complete" is not "lane complete."
- **Legitimate actions read as attacks.** A lane that sees an attestation it
  didn't post, under the shared identity, rationally files it as a forged
  credential. Every automated actor must therefore SIGN its side-effects with a
  provenance line naming its lane/session and authority — not to prevent
  forgery (a shared token can't), but so honest actors can recognize each
  other. The structural fix is per-actor identity (GitHub App / machine user
  per lane); until then, provenance discipline is the mitigation.

Both happened in one night on the same repo (conference-os #925/#927/#928):
the coordinator merged a lane's PR 25 seconds after attesting it while the
lane's Codex review — which had found two real defects — was still landing,
and the lane filed the coordinator's attestation as a security incident.
Two correct actors, one identity, zero provenance.

## Cost discipline

Route to the cheapest vendor that clears the quality bar (see
[15-model-economics](15-model-economics.md)): mechanical implementation and
bulk lanes → cheap/fast workers; adversarial review and judgment calls → the
strongest reviewer available *from a different vendor than the author*.
Separate vendor quota pools are the point — parallel throughput without a
single provider's rate ceiling.
