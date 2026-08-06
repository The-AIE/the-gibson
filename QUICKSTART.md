---
title: Quickstart
nav_order: 4
---

# QUICKSTART — clone to first adopted repo

> 🙂 **In plain English:** The shortest honest path from "I just copied this project" to
> "my first app is under the rules." Every step tells you what you are being asked, what
> it does, why it matters, and what could go wrong.

Fastest honest path. Every step uses the **Ask Contract**: what / does / why /
risks. Technical terms are explained inline.

Assume you have: a GitHub account, a target app repo, and at least one agent CLI
(Grok recommended for grind; Claude or Codex fine too).

### Single-model is the primary path

**One model is enough** — full statement:
[VIBECODING.md § One AI is enough](VIBECODING.md#one-model-is-enough).
Point `scripts/loop.sh --runner <one-cli>` at the repo; optional
`--reviewers` / `--supervisor` is an upgrade, not a requirement.

---

## Step 0 — Clone The Gibson

| | |
|---|---|
| **What I'm asking** | Download The Gibson onto your machine. |
| **What it does** | Gives you the rulebook, scripts, and CI templates the AI team follows. |
| **Why** | Agents and you need one shared contract so work is consistent. |
| **Risks** | None meaningful — a folder of docs and scripts. Delete the folder to undo. |

```bash
git clone https://github.com/mrhinkle/the-gibson.git ~/Code/the-gibson
cd ~/Code/the-gibson
```

Optional fork (if you will customize): see [docs/18](docs/18-fork-and-upstream.md),
then `git remote add upstream https://github.com/mrhinkle/the-gibson.git`.

---

## Step 1 — Skim the front door

| | |
|---|---|
| **What I'm asking** | Read two short pages. |
| **What it does** | Orients you: who you are (owner vs operator vs agent). |
| **Why** | Prevents drowning in the full doctrine set on day one. |
| **Risks** | None. |

- Not technical? → [VIBECODING.md](VIBECODING.md) only.  
- Run the fleet? → [GUIDE.md](GUIDE.md) §1–5.  
- Agents? → [AGENTS.md](AGENTS.md).
- Ready-made owner lines? → [docs/prompts.md](docs/prompts.md).
- One model is enough? → [VIBECODING.md](VIBECODING.md#one-model-is-enough). Definition of done? → [docs/21](docs/21-operator-readiness.md).

---

## Step 2 — Pick one target repo

| | |
|---|---|
| **What I'm asking** | Choose a single application repository to adopt first. |
| **What it does** | Focuses the fleet so you get an end-to-end win before multi-repo chaos. |
| **Why** | Adoption is itself a project; one canary proves the loop. |
| **Risks** | Low. Prefer a non-critical app for the first week if you are nervous. |

Example path: `~/Code/acme-app` with GitHub `acme/acme-app`.

---

## Step 3 — Run adoption (or do it with an agent)

| | |
|---|---|
| **What I'm asking** | Install Gibson's contract and checkers into that app via a pull request. |
| **What it does** | Adds agent instructions, claim table, CI workflows, labels — without force-pushing your main branch. |
| **Why** | Until this lands, agents have no shared rules or automatic safety net. |
| **Risks** | Medium: CI can block merges if miscalibrated. Fixable by adjusting workflows or burn-down issues. Nothing goes live until you merge. |

**With an agent:**

```bash
cd ~/Code/the-gibson
grok -p "$(cat playbooks/adopt.md)

Target: ~/Code/acme-app
Remote: acme/acme-app
Gibson: ~/Code/the-gibson
Runtimes: grok
"
```

**Manual core pieces:**

```bash
# In the target repo, on a branch:
# 1) Append templates/target-repo/AGENTS-section.md → AGENTS.md (fill placeholders)
# 2) Create docs/active-work.md claim table header
# 3) Copy ci/*.yml → .github/workflows/ (fill gate commands)
# 4) Vendor scripts you need: preview-url.sh, posture-probe.sh, route-inventory.mjs, gate*.sh, claim*.sh
# 5) gh label create gibson tier-a tier-b tier-c agent-claimed blocked gibson-halt
```

Merge the adoption PR only after you understand the Ask Contract on that PR.

---

## Step 4 — Baseline the green gate

| | |
|---|---|
| **What I'm asking** | Run the automatic quality checker once and record what already fails. |
| **What it does** | Snapshots today's broken tests/types so new work is not blamed for old debt. |
| **Why** | The rule is "no *new* failures," not "perfect repo on day one." |
| **Risks** | Low. Creates a local `.gibson-baseline.json` file (usually not committed). |

```bash
cd ~/Code/acme-app
~/Code/the-gibson/scripts/gate-baseline.sh
```

File burn-down issues for anything red you want fixed over time
([docs/13](docs/13-adoption.md) Step 4).

---

## Step 5 — Ship a canary Tier A issue (single model)

| | |
|---|---|
| **What I'm asking** | Let **one** runner do one small, safe change end-to-end. |
| **What it does** | Proves claim → build → test → review → (eval if UI) → merge → deploy with **zero** touches from you. |
| **Why** | "Adopted" is a behavior, not a checkbox ([docs/13](docs/13-adoption.md) definition). |
| **Risks** | Low if Tier A (docs, copy, isolated component). Use a real but reversible task. |

Example issue body: use the template in [docs/04](docs/04-plan-to-issues.md).

```bash
# Agent builder path
cd ~/Code/acme-app
~/Code/the-gibson/scripts/claim.sh 1 canary-readme 'README.md'
cd ../wt-1-canary-readme
# agent implements …
~/Code/the-gibson/scripts/gate.sh
git commit -s -m "docs: canary for Gibson adoption"
# open PR with Closes #1, get review, merge via release playbook
~/Code/the-gibson/scripts/release-claim.sh 1
```

Or **single-model** solo loop (primary path):

```bash
~/Code/the-gibson/scripts/loop.sh --runner grok --repo ~/Code/acme-app --repo-slug acme/app \
  --solo-platform --max-iterations 20
```

`--solo-platform` (#69) keeps review non-deadlocking when only one vendor CLI is
installed — see [docs/11](docs/11-solo-loop.md).

Optional multi-model upgrade (not required):

```bash
~/Code/the-gibson/scripts/loop.sh --runner grok --repo ~/Code/acme-app \
  --escalate-after 2 --reviewers codex,claude --supervisor devin
```

---

## Step 6 — Confirm "adopted"

| Check | Pass means |
|---|---|
| Tier A canary | Merged + deployed without you babysitting steps |
| Human gates | You only saw decision cards for real owner decisions (or none) |
| Kill switch | You know how to pause (`gibson-halt` / `gibson/HALT`) |
| Digest | You know where status will show up (Hermes / GH / MC) |

---

## Next

- Full operator habits: [GUIDE.md](GUIDE.md)  
- Overnight grind: [docs/11](docs/11-solo-loop.md)  
- Owner-facing prompts: [docs/prompts.md](docs/prompts.md)  
- End-goal checklist: [docs/21-operator-readiness.md](docs/21-operator-readiness.md)  
- Second repo: repeat Steps 2–6  
- Fork sync: `scripts/upstream-sync.sh`  
- Reading map: [docs/00-INDEX.md](docs/00-INDEX.md)

## If you get stuck

| Symptom | Go to |
|---|---|
| Loop burning tokens red | [docs/troubleshooting/loop-wont-go-green.md](docs/troubleshooting/loop-wont-go-green.md) |
| Two agents fighting | [docs/troubleshooting/claim-conflicts.md](docs/troubleshooting/claim-conflicts.md) |
| No preview URL | [docs/troubleshooting/preview-url-failures.md](docs/troubleshooting/preview-url-failures.md) |
| Vocabulary | [docs/00-glossary.md](docs/00-glossary.md) |
