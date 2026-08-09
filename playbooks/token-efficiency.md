---
title: "Playbook · Token efficiency"
nav_exclude: true
role: operator
inputs:
  - work type and risk tier for the next unit (docs/04, docs/06)
  - which runner pools are actually installed and healthy (CLIs on PATH)
  - live claim table via scripts/claims-status.sh (WIP / overlap)
  - optional existing gibson/cost-ledger.jsonl for the target repo
outputs:
  - graded dispatch (G / S / F) with chosen runner and escalate path
  - bounded run (retries, error/stale budgets, stop or park decision)
  - cost-ledger event(s) and optional summarize rollup when measured
  - plain-language status: continue / reroute / stop with quality evidence
gates:
  - flat-rate-first for volume; metered only for judgment that needs it (docs/15)
  - never grade below the task's minimum capability floor
  - green gate, exact-head CI, cross-vendor review, and deploy/runtime verification stay absolute (docs/06, docs/12, docs/20)
  - no-model checks stay no-model (scripts/*, ci/*)
  - missing usage stays unknown — never invent tokens or dollars
forbidden:
  - weakening gates, truncating required evidence, or reusing stale reviews
  - routing Tier B/C evaluation below S, or Tier C adversarial below F
  - changing billing, plan settings, keys, env secrets, or provider routing config
  - inventing fixed dollar prices or assuming a vendor's current plan rate
  - treating flat-rate / subscription usage as free or unlimited
  - unbounded coordinators / infinite retry on the same failure
sources:
  - docs/15-model-economics.md
  - docs/20-multi-model-orchestration.md
  - docs/11-solo-loop.md
  - docs/05-concurrency.md
  - docs/06-quality-gates.md
  - docs/12-vercel.md
  - docs/08-security.md
  - docs/16-nontechnical-operation.md
  - memory/LESSONS.md (L-003, L-007)
  - playbooks/release.md
  - scripts/cost-ledger.sh
  - scripts/loop.sh
  - scripts/second-opinion.sh
  - scripts/claims-status.sh
  - scripts/gate.sh
  - scripts/gate-baseline.sh
  - scripts/posture-probe.sh
---

# Token efficiency — route, bound, measure, preserve quality

> 🙂 **In plain English:** Spend the *right* amount of AI attention — not the least,
> not the most. Use cheaper pools for bulk work that sensors catch, save stronger
> minds for judgment, measure what you used, and never cut corners on tests or
> independent review to "save tokens."

This playbook is the **operator procedure**. Doctrine lives in
[docs/15](../docs/15-model-economics.md) (why) and
[docs/20](../docs/20-multi-model-orchestration.md) (coordinator shape). Do not
duplicate those docs here — execute them.

## Efficiency ≠ minimization

| Efficient (do this) | Minimizing that breaks quality (never this) |
|---|---|
| Route grind to a flat-rate pool | Skip the green gate to "save a run" |
| Bound retries; escalate on signal | Truncate required contract evidence |
| Fresh context per hat; small capsules | Reuse yesterday's review on a new head |
| Cache deterministic outputs safely | Grade Tier C with a grind-only model |
| Record tokens when known; unknown stays blank | Invent `$` costs or fake cache hits |
| Park after the budget, pick other work | Infinite loop on the same red check |

**Standing order:** if a shortcut weakens security, accessibility, correctness,
owner gates, exact-head CI, or cross-vendor review — it is not efficiency. It is
debt. (L-003 fixed unbounded spend; L-005 forbids fail-open review skip.)

---

## How to use this

**Engineer (copy/paste — real scripts only):**

```bash
GIBSON=~/Code/the-gibson   # or this clone
REPO=~/Code/acme-app       # target checkout or worktree
REPO_SLUG=owner/name       # safe placeholder — replace with the target's origin slug

# 0) No-model: who holds what (WIP). claims-status.sh reads docs/claims from the
#    *current* git working tree — run it inside the target, not Gibson's clone.
(cd "$REPO" && "$GIBSON/scripts/claims-status.sh" --markdown)

# 1) Green-gate baseline in the *target* worktree BEFORE any write-capable
#    runner (loop.sh) mutates the tree. Record once at branch point.
(cd "$REPO" && "$GIBSON/scripts/gate-baseline.sh")

# 2) Solo grind on a flat-rate runner (default budgets: error 5; stale = error).
#    --repo-slug is required (see loop.sh --help) and must match origin.
"$GIBSON/scripts/loop.sh" \
  --runner grok \
  --repo "$REPO" \
  --repo-slug "$REPO_SLUG" \
  --max-iterations 20 \
  --error-budget 5 \
  --stale-budget 5 \
  --escalate-after 2

# 3) Cross-vendor read-only review of the exact branch tip (not self-review)
"$GIBSON/scripts/second-opinion.sh" \
  --repo "$REPO" \
  --author grok \
  --reviewers codex,claude \
  --out "$REPO/gibson/second-opinion.md"

# 4) Green gate before each commit (compares to the branch-point baseline).
(cd "$REPO" && "$GIBSON/scripts/gate.sh")

# 5) Record one measured iteration (aggregate tokens optional — omit if unknown)
"$GIBSON/scripts/cost-ledger.sh" append \
  --ledger "$REPO/gibson/cost-ledger.jsonl" \
  --runner grok \
  --pool flat-rate \
  --hat builder \
  --wall-ms 120000 \
  --flat-rate true \
  --issue 42 \
  --pr 123 \
  --iteration 1 \
  --repo "$REPO_SLUG"
# optional when the runtime reports an aggregate count: --tokens N
# (no --input-tokens / --output-tokens / --cache-tokens flags today — see §9)

# 6) Roll up (optional merged-PR list is a JSON array file you already have)
"$GIBSON/scripts/cost-ledger.sh" summarize \
  --ledger "$REPO/gibson/cost-ledger.jsonl" \
  --format text
```

**Headless agent dispatch (load this playbook, then grade the next unit):**

Do **not** pass this playbook through `grok -p "$(cat …)"`. Playbooks begin with
YAML frontmatter (`---`), which Grok's arg parser mis-reads as a flag when the
body is inlined as a `-p` value (L-007). Gibson's loop uses `--prompt-file`;
mirror that. Put target/issue/work metadata in the same prompt file (or a short
brief that points at this playbook) so nothing is lost and nothing starts with
an unquoted `---` CLI value.

```bash
GIBSON=~/Code/the-gibson
REPO=~/Code/acme-app
REPO_SLUG=owner/name
PROMPT_FILE="$(mktemp -t te-dispatch.XXXXXX.md)"
{
  cat "$GIBSON/playbooks/token-efficiency.md"
  printf '\n\n## Dispatch context\n\n'
  printf 'Target repo: %s\n' "$REPO"
  printf 'Repo slug: %s\n' "$REPO_SLUG"
  printf 'Issue / PR: #42 / #123\n'
  printf 'Work type: Tier A builder hat\n'
  printf 'Installed runners: grok, codex\n'
  printf 'Mode: grade + bound + measure (no billing changes)\n'
} > "$PROMPT_FILE"
# plan = read-only grade; use bypassPermissions only when the agent must act
grok --prompt-file "$PROMPT_FILE" --cwd "$REPO" --permission-mode plan
rm -f "$PROMPT_FILE"
```

**Claude Code / Codex:** load this playbook by path or paste, then the target
path, slug, and issue. Prefer file/stdin paths over dash-prefixed CLI values when
the body starts with YAML frontmatter. Local override:
`local/playbooks/token-efficiency.md` if present
([docs/18](../docs/18-fork-and-upstream.md)).

**Operator (chat only):** you never run the shell. Ask the fleet:
"Is this run efficient *and* still safe?" Expect the plain checklist at the end
of this file, not a terminal dump.

---

## 1. Grade the work (G / S / F)

Every dispatch gets one **capability grade** before a runner is chosen
([docs/15](../docs/15-model-economics.md)):

| Grade | Meaning | Default examples | Minimum floor |
|---|---|---|---|
| **G — Grind** | High volume; sensors catch most wrong answers | Solo-loop iterations, Tier A builds, lint/mechanical refactors, research sweeps, scaffold | G ok |
| **S — Skilled** | Multi-file reasoning; sensors catch *some* failure | Tier B builds, integration tests, standard reviews, UX eval runs, clear-plan decompose | **S min** for Tier B/C *evaluation* |
| **F — Frontier** | Judgment-heavy; failure expensive or invisible | Planning, Tier C adversarial review, security exploit reasoning, architecture, incidents, harness changes | **F min** for Tier C adversarial / taste |

**Two structural rules:**

1. Generation may be cheap; **evaluation of Tier B/C is never graded below S.**
   A G generator + F reviewer is a good trade.
2. **Cross-vendor beats same-vendor at equal grade** ([docs/20](../docs/20-multi-model-orchestration.md)
   rule 1). Prefer the *other* pool for review.

Do **not** hard-code vendor list prices here. Plans change; the procedure does not.

## 2. Flat-rate-first routing (no fixed prices)

| Pool shape | Marginal cost character | Prefer for | Watch for |
|---|---|---|---|
| **Flat-rate / saturable subscription** | Near-zero until the pool is saturated | G volume, overnight solo loop, bulk implement | Saturation → queue or shift other G work; do not silently dump to metered |
| **Subscription with usage caps** | Zero until cap, then real | S daytime feature work; reserve headroom for F | Burning the cap on grind that a flat-rate pool could absorb |
| **Metered API (any vendor)** | Full price per use | Only judgment that truly needs that API | Using metered for lint loops, retries, research sweeps |

**Standing order:** flat-rate pools absorb volume; metered tokens buy judgment.
Never invent a dollar figure. When a runtime reports cost, record it; when it
does not, leave cost unknown.

### Routing table by hat (defaults, not dogma)

| Hat / work | Start grade | Prefer pool shape | Escalate when |
|---|---|---|---|
| Solo-loop builder (Tier A) | G | Flat-rate | Same criterion fails 3×; or scope is actually Tier B/C |
| Builder (Tier B) | S | Subscription (skilled) or flat-rate if clearing the bar | Two same-criterion fails after enrich; framework subtlety |
| Builder / review (Tier C) | S build / **F review** | Strongest available *different* vendor for review | F fails twice → park (not more models) |
| Test-engineer | G–S | Flat-rate first | Flaky contract design needs S |
| Reviewer | S (B) / F (C) | Other vendor than author | Author and only-available reviewer same vendor → block or human gate |
| UX evaluator | S | Any that can drive Playwright | Sensor-blind visual judgment |
| Security adversarial | F | Other vendor; never self | Missing reviewer CLI → fail closed (L-005) |
| Release / delivery-control audit | G scripts + S judgment | Scripts first (`scripts/delivery-control/`, `gate.sh`) | Promote/harden always human-gated |
| Historian / lesson file | G | Flat-rate | — |
| Coordinator (docs/20) | S–F judgment only | Persistent session; **dispatch** grind to workers | Unbounded coordinator session (L-003) |

If a runner CLI is missing, **do not pretend it ran.** Fail closed on review;
reroute implement work only when another pool still clears the grade floor.

## 3. WIP and concurrency

Live inventory (no model). The script inspects the **current working directory's**
git tree (`docs/claims/`), so enter the target first:

```bash
(cd "$REPO" && "$GIBSON/scripts/claims-status.sh" --markdown)
```

| Rule | Why |
|---|---|
| **Default WIP ≤ 3 live lanes** on a fleet (decision graph stays tiny — [docs/25](../docs/25-trust-and-governance.md), D-006 context) | Coordination cost grows faster than token burn |
| One issue → one claim → one worktree → one branch ([docs/05](../docs/05-concurrency.md)) | L-001 clobber class |
| Overlap with a live claim → stop and coordinate | Never race |
| STALE claims (>24h) → verify activity before renew/release | Dead lanes block the fleet |
| Canonical checkout is read-only | All mutation in worktrees |

More open PRs is not more progress if CI and review cannot keep up.

## 4. Bounded retries and escalation

Use the ladder from [docs/15](../docs/15-model-economics.md); operationalize with
`scripts/loop.sh` budgets:

```text
attempt at grade N
  → same criterion fails twice     → one retry with enriched context (diff, logs, contract)
  → fails again (3rd)              → escalate one grade; hand over loop-state + failure history
  → F-grade fails twice            → not a model problem: park, file lesson (docs/09)
```

| Budget | Tooling default | Meaning |
|---|---|---|
| Error budget | `loop.sh --error-budget 5` | Consecutive failures before stop |
| Stale / no-progress | `loop.sh --stale-budget N` (default = error budget) | Exit 0 with no substantive state progress (L-008) |
| Escalate after | `loop.sh --escalate-after N` + `second-opinion.sh` | Cross-vendor read-only opinion **before** budget exhausts |
| Max iterations | `loop.sh --max-iterations N` | Hard cap for unattended runs |
| Resolve rounds | docs/11: ~3 REQUEST_CHANGES cycles | Then park PR + handoff note |

**Protection against paying for identical failures:** do not re-dispatch the same
prompt after the same red check without new evidence (log snippet, failing test
name, contract criterion id). Enrich or escalate; never thrash.

## 5. Context discipline (capsules, not novels)

| Practice | Do | Don't |
|---|---|---|
| **Minimal capsule** | Issue contract, exact file list, acceptance criteria, failing check excerpt, relevant lesson tags | Whole repo, full chat history, unrelated PRs |
| **Progressive disclosure** | Point to paths; let the worker read what it needs | Paste five large files "just in case" |
| **Fresh context per hat** | docs/11: each hat reloads artifacts from disk | One mega-session wearing every hat |
| **Summaries / checkpoints** | Write loop-state, journal, PR body; compact metered sessions before half the window | Rely on the model "remembering" overnight |
| **Stable handoffs** | Machine-readable: claim file, loop-state keys, cost-ledger JSONL, gate output | Ambiguous "it's mostly done" chat |
| **When fresh beats carry-over** | New hat, new vendor, post-failure escalate, after merge | Carrying a long failed transcript into review |

Bounded workers: **one issue, exact file list, short output contract.**
Unbounded coordinators are the documented cost pathology (L-003).

## 6. Deterministic / no-model checks first

These are scripts and CI — not prompts ([docs/15](../docs/15-model-economics.md)):

| Check | Command / location |
|---|---|
| Claims / WIP | `(cd "$REPO" && "$GIBSON/scripts/claims-status.sh")` — CWD must be the target |
| Green gate | `(cd "$REPO" && "$GIBSON/scripts/gate-baseline.sh")` once at branch point (before write-capable loop), then `(cd "$REPO" && "$GIBSON/scripts/gate.sh")` before commits |
| Loop state schema | `"$GIBSON/scripts/validate-loop-state.sh" "$REPO/gibson/loop-state.md"` |
| Injection / deceptive Unicode | `"$GIBSON/scripts/injection-scan.sh"` (pass paths under the agent-ingested tree) |
| Cross-vendor review dispatch | `"$GIBSON/scripts/second-opinion.sh" --repo "$REPO"` (still a model, but **read-only** and not self) |
| Cost append / summarize | `"$GIBSON/scripts/cost-ledger.sh"` (`--ledger` under `$REPO/gibson/`) |
| Delivery-control audit | `"$GIBSON/scripts/delivery-control/audit.sh" --repo "$REPO_SLUG"` |
| CI on exact head | Required checks on the PR head SHA — see §8 |
| Deploy / runtime | READY + smoke / posture-probe after merge or vs preview — see §8 (not the same as CI green) |

Run no-model sensors before spending a skilled/frontier call on something a
script already answers.

## 7. Cache and reuse (only where safe)

| Safe to reuse | Unsafe to reuse |
|---|---|
| Deterministic gate output for the **same** commit | Review written for a previous SHA |
| Generated inventory (route matrix) until code changes | "LGTM" from the authoring model |
| Lesson / decision memory (tag-filtered) | Stale claim that another lane released |
| Playbook text and contract templates | Billing quotes or remembered plan prices |
| Cost-ledger history (append-only) | Fabricated token counts to "complete" a row |

Cache hits never replace **exact-head** verification after new commits.

## 8. Quality invariants (non-negotiable)

1. **Green gate** before every commit, run from the **target worktree** after a
   branch-point baseline (`gate-baseline.sh` then `gate.sh` —
   [docs/06](../docs/06-quality-gates.md)).
2. **Exact-head CI:** required checks must run on the PR's current head SHA.
   A missing check is not a pass ([docs/20](../docs/20-multi-model-orchestration.md)
   Chatterbuilt lesson). Fail closed — do **not** grep human-readable
   `gh pr checks` text, and do **not** treat a missing required set as green.
   Verified against installed `gh` (`gh pr checks --help` JSON fields;
   `conclusion` is **not** among them on current CLI — use `name`, `state`,
   `bucket`):

   ```bash
   REPO_SLUG=owner/name          # replace
   PR=123                        # replace
   SHA=REPLACE_WITH_EXACT_HEAD   # replace with the claimed tip SHA

   # Live PR head must equal the claimed SHA (not an ancestor, not a sibling tip).
   test "$(gh pr view "$PR" --repo "$REPO_SLUG" --json headRefOid --jq .headRefOid)" = "$SHA"

   # Existence evidence only: some Actions run exists for this head. This is NOT
   # a pass signal and does not inspect required checks.
   gh api "repos/${REPO_SLUG}/actions/runs?head_sha=${SHA}" \
     --jq 'if (.total_count // 0) < 1 then error("no actions runs for head") else .total_count end' \
     >/dev/null

   # Complete required-check set. Fields supported here (gh 2.x): name, state,
   # bucket — there is no `conclusion` field on `gh pr checks --json` (confirmed
   # via `gh pr checks --json` / --help). Success = every required check has
   # bucket "pass". Empty required set or CLI failure (including "no required
   # checks reported") fails closed — never treat a missing set as green.
   required_json="$(gh pr checks "$PR" --repo "$REPO_SLUG" --required --json name,state,bucket)" \
     || exit 1
   test "$(printf '%s\n' "$required_json" | jq 'length')" -gt 0 || exit 1
   printf '%s\n' "$required_json" | jq -e 'all(.[]; .bucket == "pass")' >/dev/null
   ```

3. **Cross-vendor review** — author never approves self (Law 5, docs/20 rule 1).
4. **A worker PASS is a claim** — re-run checks; read the actual diff.
5. **Owner / human gates** unchanged ([docs/14](../docs/14-human-gates.md)).
6. **No secrets in capsules** — blind pipe for credentials (docs/20 rule 6).
7. **Deployment / runtime verification** — green CI and a green local gate prove
   the *commit*, not the *running system*. For product surfaces after merge (or
   against a PR preview when evaluating UX/security): confirm the deployment is
   for the expected commit SHA and reaches **READY**
   ([docs/12](../docs/12-vercel.md), [playbooks/release.md](release.md)); run
   post-deploy smoke (`BASE_URL=… npx playwright test …` contract happy-paths)
   and, when applicable, `"$GIBSON/scripts/posture-probe.sh" "$BASE_URL"`
   ([docs/08](../docs/08-security.md)). Docs-only / no product surface: content
   verification on `origin/main` after the merge commit lands — not a Vercel
   READY wait (release playbook). **Never treat "CI green" as "deployed runtime
   verified."**

Token savings that violate any row above are forbidden by this playbook's
frontmatter.

## 9. Measurement and telemetry

Use `scripts/cost-ledger.sh` (schema `gibson.cost.v1`). Record what you know;
**never coerce missing fields to zero.** Flat-rate / subscription usage is
**not free** — it saturates and still burns wall time; metered usage bills per
use. Never invent dollar prices.

### What the ledger persists today

`cost-ledger.sh append` accepts only the flags in `cost-ledger.sh --help`.
Issue #149 asks for input / output / cache token measurement **when available**;
today the script stores at most one optional aggregate token count, not a
typed breakout:

| Signal | Ledger field / flag | Notes |
|---|---|---|
| Runner / pool | `--runner`, `--pool`, `--flat-rate true\|false` | Pool shape, not a price |
| Hat | `--hat` (builder, reviewer, …) | |
| Wall time | `--wall-ms` (required on append) | Always known |
| Tokens (aggregate) | `--tokens N` | **Only** when a runtime reports a total. Loop may pass this via `GIBSON_COST_TOKENS` when set. Omit when unknown — never `0` as a stand-in |
| ACUs / vendor units | `--acus` | When applicable |
| Issue / PR / iteration / repo | `--issue`, `--pr`, `--iteration`, `--repo` | |
| Free-text note | `--note` | Single line; no secrets |
| Outcome | Not a ledger dollar field | PR merge state via GitHub; journal; optional `summarize --merged-since` JSON for cost-or-effort per merged PR |
| Attempts / rework | Outside the event schema | Iteration count, escalate events, REQUEST_CHANGES rounds in journal / loop-state |
| Cost USD | **Not invented by this script** | Record only if a runtime or operator supplies a real figure elsewhere |

There are **no** `--input-tokens`, `--output-tokens`, or `--cache-tokens` flags
and no separate JSON keys for those breakouts in `gibson.cost.v1` today. Do not
document or call flags the script does not implement.

### Richer runtime breakouts (when the CLI prints them)

Some runtimes print input / output / cache (or prompt / completion) counts in
their own UI, logs, or session summaries. When those numbers are real:

1. Prefer the runtime's own record as the source of truth for the breakout.
2. Copy the breakout into the iteration **journal**, loop-state note, or PR
   status comment so the fleet can read it later.
3. If you also have a trustworthy **aggregate** total, you may pass that single
   total as `--tokens` on the ledger event. If you only have a partial
   breakout, leave ledger `tokens` omitted rather than summing invented parts.
4. Never fabricate cache hits, input, or output to "complete" a row.

### Coordination with runner routing (#141)

This playbook describes the **measurement and routing contract** operators
follow (flat-rate-first grades, pool shape, what to record). Per-lane primary /
fallback runner selection and failover implementation live in issue **#141** —
do not implement routing machinery in documentation. When #141 lands, ledger
rows should still record selected runner, pool, and (when known) aggregate
tokens without inventing usage.

```bash
# After a run window
"$GIBSON/scripts/cost-ledger.sh" summarize \
  --ledger "$REPO/gibson/cost-ledger.jsonl" \
  --format text
```

Weekly retro question: **cost (or wall-time / known tokens) per merged PR per
pool** — the number [docs/15](../docs/15-model-economics.md) exists to push down
— without lowering the merge quality bar. Summarize reports tokens only from
events that recorded them; missing stays unknown, not zero.

Never log credentials, raw `.env`, or full metered invoices into the ledger.

## 10. Stop / park / continue

| Condition | Action |
|---|---|
| Error or stale budget exhausted | **Stop** the loop; read journal; escalate or park |
| Same criterion failed through F twice | **Park** issue/PR; file lesson; pick other work |
| Human gate (docs/14) | Queue decision card; do not burn retries waiting |
| Missing reviewer for required cross-vendor | **Block merge** (fail closed) |
| Pool saturated / rate limited | Reroute G work or pause; do not silent-fail into metered without a grade reason |
| Kill switch | `touch "$REPO/gibson/HALT"` or `GIBSON_HALT=1` ([docs/11](../docs/11-solo-loop.md)) |
| Green + independent review + exact-head CI | **Continue** / release path |

Parked work is visible (digest / journal), never silent.

---

## Plain-language operator checklist

Use this without opening a terminal. Ask the fleet each question; expect yes/no
plus one sentence of evidence.

### Before a run

- [ ] What is shipping, in one plain sentence?
- [ ] Is this ordinary (A), careful (B), or high-stakes money/auth/privacy (C)?
- [ ] Is the crew using the bulk/cheaper pool for bulk work, and a stronger
      different reviewer when stakes need judgment?
- [ ] Is active WIP **≤ 3 lanes**, with no overlapping file work?
- [ ] Is there a kill switch and a retry limit so this cannot spin all night on
      open-ended quota or spend? (Flat-rate pools are **not free** — they
      saturate and still burn wall time.)

### During / after

- [ ] Did the automatic tests and build run on the **latest** version of the change?
- [ ] Did a **different** AI (or person) review than the one that wrote it?
- [ ] Did we record how long it took and, when known, how much attention it used
      (including input/output/cache breakouts in the journal when the runtime
      printed them — without guessing numbers or inventing ledger fields)?
- [ ] If something failed twice the same way, did we change approach or stop —
      not hammer the same button?
- [ ] For product surfaces: was the **deployed** URL checked (expected commit,
      READY, smoke / posture) — not only "CI said green"?
- [ ] Did anyone skip a safety check "to save cost"? If yes → **not done**.

### Decide

| You see… | You say… |
|---|---|
| Tests green, other-vendor review, deploy/runtime verified when needed, clear summary | **Continue / ship** (or approve the human gate card) |
| Same failure repeating, no new info | **Stop and park**; ask for a plain handoff |
| Only the author said it is fine | **Reroute** to an independent review |
| High-stakes work on the weakest pool only | **Reroute** up a grade before merge |
| CI green but no one checked the live/preview app | **Not done** for product surfaces — demand deploy/runtime verification |
| Numbers look "too cheap" and evidence is thin | **Do not celebrate** — demand the checklist above |

---

## Worked examples

### A — Overnight Tier A backlog (efficient)

```bash
# 1) WIP: active WIP ≤ 3 lanes; no overlapping file work
(cd "$REPO" && "$GIBSON/scripts/claims-status.sh" --markdown)

# 2) Solo grind on a flat-rate pool (quota/saturation still real — not free)
"$GIBSON/scripts/loop.sh" \
  --runner grok \
  --repo "$REPO" \
  --repo-slug "$REPO_SLUG" \
  --max-iterations 20 \
  --error-budget 5 \
  --stale-budget 5 \
  --escalate-after 2

# 3) Each hat gets a fresh context; state in gibson/loop-state.md (driver-managed)

# 4) On stall: cross-vendor read-only opinion for another vendor
"$GIBSON/scripts/second-opinion.sh" \
  --repo "$REPO" \
  --out "$REPO/gibson/second-opinion.md"

# 5) Morning rollup (journal any runtime I/O/cache breakouts when printed)
"$GIBSON/scripts/cost-ledger.sh" summarize \
  --ledger "$REPO/gibson/cost-ledger.jsonl" \
  --format text
# Merge only with exact-head green, independent review, and deploy/runtime
# verification when the change has a product surface (§8).
```

### B — False economy (forbidden)

Builder skips `gate.sh`, pastes "LGTM" from the same session, reuses a review from
yesterday's commit, and marks the PR cheap. **Rejected by this playbook** —
minimization, not efficiency.

### C — Tier C auth change (spend judgment deliberately)

1. Implement on S (or G if sensors are strong) in a dedicated worktree.
2. Review and security adversarial on **F from another vendor**.
3. Human merge gate (docs/14 / Tier C). Metered or capped subscription spend here
   is expected; grinding auth on G-only with no F review is not.

---

## Done means

- [ ] Next unit graded G/S/F with a pool shape, not a memorized price list
- [ ] Budgets and escalate path stated (or loop flags set, including `--repo-slug`)
- [ ] Capsule is minimal; fresh context per hat
- [ ] No-model checks run in the **target** tree where they apply
- [ ] Quality invariants intact (gate, exact-head CI, cross-vendor, deploy/runtime)
- [ ] Ledger holds only supported fields; richer token breakouts live in journal
      when available — no invented usage
- [ ] Continue / reroute / stop decided with evidence

## Relationship to other docs

| Doc / tool | Job vs this playbook |
|---|---|
| [docs/15](../docs/15-model-economics.md) | Doctrine: grades, pools, ladder |
| [docs/20](../docs/20-multi-model-orchestration.md) | Coordinator/worker communication rules |
| [docs/11](../docs/11-solo-loop.md) | Solo loop state machine |
| [playbooks/dogfood-overnight.md](dogfood-overnight.md) | One overnight launch recipe |
| [playbooks/loop-step.md](loop-step.md) | Single-hat prompt body |
| `scripts/cost-ledger.sh` | Meter append/summarize |
| `scripts/loop.sh` / `second-opinion.sh` | Bound + escalate |

Doctrine does not restate this procedure; this procedure does not re-litigate
doctrine.
