# FAQ

Seeded from questions that show up in the first month of operating The Gibson.
Short answers; deep links for the rest.

## What is The Gibson?

A **portable SDLC harness** for AI agent fleets: Markdown doctrine, shell scripts,
and CI gates. Models are rented; the harness is yours and compounds. Start:
[README.md](README.md), agents load [AGENTS.md](AGENTS.md).

## Do I need to be a developer?

No. If you only want software built, read [VIBECODING.md](VIBECODING.md). You
approve plans and decision cards in plain language ([docs/16](docs/16-nontechnical-operation.md)).

## What do I install first?

[QUICKSTART.md](QUICKSTART.md): clone → optional fork overlay → adopt one repo →
canary Tier A issue. Operator-facing install always uses the Ask Contract
(what / does / why / risks).

## Will agents change production without asking?

Routine merges of already-gated work deploy per your Vercel branch model
([docs/12](docs/12-vercel.md)). **First** public launches, money, destructive ops,
and Tier C merges stop for you ([docs/14](docs/14-human-gates.md)). Silence never
auto-approves a gate.

## What's a "green gate"?

Before every commit: generate → typecheck → lint → test → build with **zero new
failures** vs. the branch-point baseline ([docs/06](docs/06-quality-gates.md)).
Scripts: `scripts/gate-baseline.sh`, `scripts/gate.sh`.

## Why worktrees and claims?

So two agents cannot silently overwrite each other (incident L-001). Canonical
checkout is read-only; each issue gets a worktree + claim row
([docs/05](docs/05-concurrency.md)).

## Can one agent run the whole pipeline alone?

Yes — **solo loop** ([docs/11](docs/11-solo-loop.md)): `scripts/loop.sh --runner grok --repo …`.
Same gates; hats run in fresh contexts with file handoffs. Prefer cross-vendor
review when a second runtime exists.

## Which model should do what?

**G/S/F**: Grind → Grok first; Skilled → Codex/Claude; Frontier → best available
for planning, Tier C review, incidents ([docs/15](docs/15-model-economics.md)).
Flat-rate pools absorb volume; metered tokens buy judgment.

## How do I stop everything?

- Solo loop: `touch gibson/HALT` or set `GIBSON_HALT=1`  
- Repo: add label `gibson-halt`  
- Operator chat: "pause everything" (Hermes)

## What is Tier C?

Money, auth, consent/PII, security boundaries, schema, prod data — adversarial
review + **human merge gate** ([docs/06](docs/06-quality-gates.md)).

## How does the harness improve itself?

Failures that happen twice (or escape gates) become lessons in
`memory/LESSONS.md` and preferably a new sensor or guide ([docs/09](docs/09-memory-and-self-improvement.md)).
That is the **ratchet**.

## Can I fork this?

Yes — customize under `local/`, never edit core if you want clean upstream merges
([docs/18](docs/18-fork-and-upstream.md)). Weekly: `scripts/upstream-sync.sh`.

## Where are the role prompts?

[playbooks/](playbooks/) — one file per role plus loop, adopt, deploy-audit.

## UX eval keeps skipping — is that a pass?

No. No preview URL means the deployment was not evaluated ([docs/07](docs/07-uiux-evaluation.md)).
See [docs/troubleshooting/preview-url-failures.md](docs/troubleshooting/preview-url-failures.md).

## ZAP failed on something harmless. Merge anyway?

Only if you verified false positive and documented an allowlist with a lesson —
do not globally disable hard-fail layers ([docs/08](docs/08-security.md),
[troubleshooting](docs/troubleshooting/zap-false-positives.md)).

## What's Mission Control vs The Gibson?

**Gibson** = how agents work (doctrine + gates). **Mission Control** = who works
(queue, telemetry, dispatch). They compose; either can exist alone with reduced
power.

## What's Foreman / CodeWright?

Product names for the Operator-facing layer: CodeWright guides the plan
(Blueprint); Foreman runs the crew ([docs/19](docs/19-product-and-mcp.md)). Free
add-on to the AIE subscription (D-005).

## I don't understand a message the team sent. Is that on me?

No. Confusion is a **harness defect** — reply that you don't understand; they must
explain and fix the wording ([docs/16](docs/16-nontechnical-operation.md)).
