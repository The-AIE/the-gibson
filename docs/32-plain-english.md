---
title: The Gibson in Plain English
nav_order: 32
---

# 32 — The Gibson in Plain English

> **Authority:** Non-normative. Explanation, rationale, and history only. Binding commit/PR/merge rules live in [`AGENTS.md`](../AGENTS.md). This file must not add, drop, or weaken those rules.

> 🙂 **In plain English:** Picture a construction site where the crews are AI coding
> agents. The Gibson does not make any crew build better. It is the **building code
> and the inspector**: the rules, checks and records that make good work come out no
> matter which crew did it.

This page is the five-minute version for someone who has never seen the repo. The
full guide is [HOW-IT-WORKS.md](../HOW-IT-WORKS.md); every term below is also in the
[glossary](00-glossary.md).

## The big idea

The Gibson is a **governance harness, not a coding harness**. It does not improve any
agent's coding ability. It is the layer of evidence gates, identities, sensors,
routing and measurement that draws good results out of any platform. Swap Claude for
a newer model, or Grok for something else, and the rules stay put, because the rules
live in the repository (Markdown, scripts and CI), not in an agent. The model is
rented. The harness is yours, and it compounds.

## The assembly line

Pointed at a project, it runs plan → issues → build → test → review → UX check →
security → merge → deploy → retro, and stops only at the 16 listed human gates
([AGENTS.md](../AGENTS.md), rationale in [docs/14](14-human-gates.md)), plus owner-taste calls (product, UX, copy, brand, naming), which it ships technically but leaves as a decision item for the owner.

## Terms of art

| Term | What it means |
|---|---|
| **Harness** | The scaffolding around an agent: instructions, tools and checks. Everything that is not the model. |
| **Gate** | An automatic pass/fail check a change must clear (tests, typecheck, a security scan). Gates are enforced by machines and cannot be talked around. Written rules (`AGENTS.md`) are just as mandatory; a gate is the same rule made unforgettable. |
| **Guide and sensor** | A guide is a written rule that steers before action. A sensor is a check that detects after action that the rule was broken. Guides without sensors drift. |
| **Ratchet** | A rule that only tightens. If the same failure happens twice, it is a harness bug: a lesson is filed and the harness gains a new guide or sensor. |
| **PR (pull request)** | A proposed change, held for review before it joins the main code. |
| **Merge** | Accepting a reviewed change into the main code. |
| **CI** | Continuous integration: the automated checks that run on every PR. |
| **Preview deployment** | A temporary live copy of the app built from a PR, so the real thing is tested in a browser instead of trusting the code on paper. |
| **Worktree and lane** | A worktree is a separate working folder per agent. A lane is one agent's slice of work, with its own worktree and its own list of files it may touch. |
| **Lane bot** | A robot GitHub identity an agent commits under, so reviewers can tell who actually wrote a change. |
| **Coordinator** | The agent that carves scope, dispatches lanes and drives the merge train. |

## The rules that matter most

1. **Never grade your own homework.** The vendor that wrote a change cannot review it.
   If one platform wrote it, a different one reviews it. A worker's "PASS" is a claim,
   not proof; the gate re-run is the proof.
2. **Failure twice is a harness bug.** The fix is a new guide or sensor, not "try
   harder." Lessons go in [`memory/LESSONS.md`](../memory/LESSONS.md).
3. **Match the model to the job.** Cheap, flat-rate capacity absorbs the volume work;
   metered frontier models are reserved for judgment, and a job escalates only after
   repeated failure on the same criterion ([docs/15](15-model-economics.md)).
4. **One agent, one directory.** Worktree per lane, disjoint file scopes, so agents
   cannot corrupt each other's state ([docs/05](05-concurrency.md)).
5. **Humans keep the irreversible calls.** The closed list of human gates covers what
   an owner must decide, and subjective taste calls always go to the owner as a
   decision item. Everything else proceeds on independent review plus green gates.

## Where it stands

Adoption is a ladder ([D-006](../memory/DECISIONS.md)). Rung 1 is the agent contract
plus the CI gate. Rung 2 is the unattended loop, which needs a clean adoption pass,
a demonstrated ratchet elsewhere, and a hardened production write path. Check the
current state of each repo in its own adoption record rather than this page; D-006 defines the ladder. Work-queue management (who is doing
what, the morning brief) belongs to [Agent Kontrol](31-agent-kontrol.md), which never
holds merge authority; only the Gibson's gates do.
