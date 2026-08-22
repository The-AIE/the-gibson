# AB-219 deviations from the registered protocol

Append-only. The pre-registration (PROTOCOL.md, PREREGISTRATION.md H7) was merged
to `main` in #217 on 2026-08-16 and is **not** rewritten by this file. Every change
to the design after registration is recorded here, with its cause, before the
affected arm executes.

---

## D-1 — unit of analysis changed from live backlog issues to a frozen replay set

**Raised:** 2026-08-19. **Author:** Claude (coordinator). **Owner decision:** Mark, 2026-08-19.
**Status:** adopted, before any arm executed.

### What went wrong

The registered design drew tasks from the *live* ConferenceOS backlog and gated the
daily advance behind a priority rule ("development always preempts; run only when
fewer than 2 non-experiment lanes are active"). Those two clauses are in direct
conflict: enrollment and preemption draw on the same pool, and production work
always wins.

Observed between 2026-08-15 (registration) and 2026-08-19:

| | Registered | Actual |
|---|---|---|
| Tasks executed | ~1/day | **0** |
| `ab219/raw/*` branches created | 1 per raw task | **0** |
| Progress comments on gibson#219 | 1 per advance | 1 (launch only) |
| Seed tasks still available | 6 | **1** |

Five of the six seed-enrolled issues were implemented and merged by ordinary fleet
development, four of them within about six hours of enrollment:

- `cos#1327` (raw) — closed 2026-08-14, **before** enrollment was recorded
- `cos#1245` (raw), `cos#1221` (raw) — closed 2026-08-15, merged to `main`
- `cos#1220` (harness), `cos#1313` (harness) — closed 2026-08-15, merged to `main`
- `cos#1330` (raw) — the only survivor

Cause: the seed set was drawn from issues that were already in flight during an
ATA-launch push. The experiment could never consume the pool faster than production
did. This is a design defect, not an execution failure — no amount of re-pacing the
advance step fixes it while both draw on the same queue.

### Consequence for the registered arms

- **Raw arm — unrecoverable as registered.** Three of four raw tasks now have their
  solutions merged to `main`. A raw implementer cannot be given a task statement
  describing work that already exists in the tree. No raw artifact was ever produced:
  zero `ab219/raw/*` branches exist.
- **Harness arm — partially recoverable retrospectively.** `cos#1220` and `cos#1313`
  did traverse the normal pipeline, so review rounds and rework are reconstructable
  from PR history. Wall-clock and inference cost were **not** captured at the time and
  are not reconstructable from PR metadata; they are recorded as missing, not estimated.

With n=2 harness / n=0 raw there is no control condition — precisely the limitation
the experiment was registered to close.

### The change

The unit of analysis becomes a **frozen replay set**. Each task is an already-closed
issue paired with the commit its fix landed on top of (the first parent of the merge
commit). Both arms implement the issue against that frozen base. Nothing in the live
repository can race the experiment, and the raw arm never touches a live branch.

Also changed, as direct consequences:

1. **Preempt rule narrowed.** The priority rule now binds the **harness arm only**,
   which consumes fleet review capacity. Raw-arm runs are a single implementer session
   with no spec gate and no review, so they no longer wait on lane availability. The
   owner-set intent — production work never queues behind the experiment — is preserved.
2. **Leakage control added (new, and load-bearing).** The fix for every replayed issue
   exists later in the same repository's history. An implementer given a normal clone
   can simply read the answer. Every arm therefore runs against a **shallow clone
   truncated at the base commit** (`git clone --depth 1 --no-tags <base>`), in a scratch
   directory, with no remote configured. A replay whose log shows the implementer
   reaching commits after the base is **void and re-run**, not repaired.
3. **`cos#1330` dropped from enrollment.** It is still open, so no fix exists to define
   a replay base. It is also a poor experimental unit independently: a pure positional
   refactor ("no behavior change, diff should read as pure file moves") offers almost no
   semantic surface for the primary metric (defects surviving), and it carries an explicit
   "sequence last, do not run concurrently" constraint that guarantees collisions.
4. **Original randomization preserved.** The five retained tasks keep the arms they drew
   under seed 219 at registration. They were never re-drawn, and re-drawing them after
   observing their outcomes would be the exact bias this record exists to prevent.

### What this costs, stated plainly

Replay measures *task difficulty under each arm*, not *whether the change would have
shipped*. The harness arm's real merges also no longer measure post-merge fix rate
against production, so registered metric 5 ("post-merge fixes within 14 days") is
**dropped** rather than quietly redefined. Metrics 1–4 are unaffected. H7's prediction
is unchanged and still falsifiable: the reversed or null result is reported as such.

Whether a frozen replay generalizes to live development is a limitation of the revised
design and will be stated as one in the paper, not argued away.

---

## D-1 revisions under cross-vendor review (2026-08-19, same day, before merge)

The first draft of Amendment D-1 was reviewed read-only by Codex (implementer of
neither arm) and **FAILED**. The findings and the revisions they forced, all made
before the amendment was merged or any arm executed:

1. **Leakage check was fail-open** (`|| echo` instead of abort; reusable scratch dir;
   no check that later objects are absent; "remote removed" overstated as isolation).
   → Recipe made fail-closed with a fresh `mktemp -d`, an object-absence assertion on
   the fixing merge commit, a blind-brief rule, and a mandatory transcript audit; the
   residual undetectable-consultation risk is now stated as a limitation instead of
   implied away. The raw arm's push option was removed outright — nothing is pushed.
2. **Eligibility wording contradicted the enrolled set** (four enrolled tasks touch
   schema/auth surfaces while the wording excluded "schema, auth"). → Eligibility
   rewritten to what was actually meant and done: `owner-gate-*` and live-surface
   replays are excluded; schema-/auth-*touching* app features are eligible in replay
   because nothing is ever merged or applied. The v1 seed's own internal tension on
   this point (raw `cos#1221` was schema-adjacent from day one) is now on the record.
3. **The raw-arm gate had silently dropped `npm test where applicable`.** → Restored.
4. **Ambiguity between "both arms replay" and "reuse historical harness data".**
   → Resolved: each task gets one fresh replay in its assigned arm (twelve runs,
   6/6, no crossover); historical pipeline data for `cos#1220`/`cos#1313` is
   supplementary observational data only.
5. **`"reproducible": true` overclaimed the seven-task selection.** → Assignment is
   reproducible (seed 219); selection is judgment-based and pre-outcome, stated as a
   limitation.

Codex independently confirmed: all twelve merge SHAs exist, every base SHA is exactly
its merge commit's first parent, retained arms match v1, the shuffle reproduces
exactly, balance is 6/6.

### r2 → r3 (same day, second adversarial pass)

Codex FAILED r2 on two residual findings; both fixed before merge:

1. **Leakage recipe was still sampled, not total** (checked reachable count plus
   absence of one named object; setup not fail-closed; remote removal unasserted).
   → Replaced with a `set -euo pipefail` block and a **total object census**: the
   scratch store must equal the base commit's reachable closure exactly, so any
   unreachable later commit, tree, or blob fails the run. Adversarially verified by
   smuggling a later-history object into a test scratch store — the census catches it.
2. **"Replayed in both senses" read as a 24-run crossover.** → Reworded to what the
   ledger always encoded: each task runs once in its assigned arm, twelve runs, 6/6,
   between-task randomized as registered; `cos#1220`/`cos#1313` harness measurements
   come from fresh replays rather than their historical traversals.

Codex confirmed in the same pass: eligibility, the restored raw-arm test gate, and the
reproducibility scoping are resolved; the SHA ledger is byte-identical and re-verified.

### r3 → r4 (same day, third adversarial pass)

Codex FAILED r3 on residue of the same two findings; both fixed:

1. Census enumerations moved from process substitutions to files: a failed
   enumerator now aborts via `pipefail`, and the both-empty case fails the
   `test -s` guards instead of slipping through `diff`. The remote assertion is
   file-based for the same reason. `assignments.json`'s leakage_rule updated to
   describe the census (it still carried the r2 sampled check). Both-empty guard
   behavior verified by test.
2. The one remaining "fresh replays in both arms" sentence (in this file's r1
   record) aligned with the 12-run single-arm design stated in the amendment.

---

## D-2 — containerized implementer isolation for both arms

**Raised:** 2026-08-21. **Author:** Claude (coordinator).
**Owner decisions:** Mark, 2026-08-21 — (i) isolation applies to **both** arms; (ii) the
runner is hosted on the always-on Mac Mini; (iii) a *blocked* leakage attempt is logged as
a metric and does not void a run (see "Audit rule, amended").
**Status:** proposed. **Supersedes two earlier drafts of D-2**, both of which are recorded
below rather than deleted, because the way they failed is the finding.

### What went wrong

The first replay executed under D-1 — `cos#1245`, raw arm, 2026-08-21 — was **void on the
leakage audit**. All three D-1 layers were applied correctly; this is a design defect, not
an execution mistake:

| layer | result |
|---|---|
| 1. total object census | PASS — 3,136 objects, store == `HEAD` closure, 1 commit, no remotes |
| 2. blind brief | PASS — scanned clean before dispatch |
| 3. post-run transcript audit | **HIT — void** |

The implementer's first action, before reading any file in the frozen tree, was
`gh issue view 1245`. It then read the fixing PR (#1351), that PR's merge commit, and — via
`gh api .../contents/<path>?ref=<merge_commit>` — the **post-fix contents of two of the
files it went on to edit**. Its own third command, `git show 9e4b1b89…`, failed locally:
the census-truncated tree worked. It routed around it.

D-1 acknowledged the truncated tree "is not isolation" and booked the remainder as a
limitation, on the premise that residual consultation would be **undetectable**. The
observed behavior was the opposite — overt, immediate, total, trivially detected. Under D-1
the arms had a **detector and no control**, so runs void indefinitely rather than producing
data.

### Two rejected drafts, and why they are on the record

**Draft 1 — `codex exec -s workspace-write` (network denial).** Rejected after probing the
second vector. Codex denies child-process network but confines *writes*, not reads: it read
`/Users/mrhinkle/Code/conference-os/package.json` with `RC=0`. It would have closed the
lesser vector while leaving the entire future history readable by `cat`. The draft was
written after testing **one** vector.

**Draft 2 — a Grok sandbox profile (`extends = "strict"` plus a deny list).** Reviewed
adversarially by Codex, which returned **BLOCK** on seven findings. Verified and confirmed:
the profile was defeated from **inside its own sandbox**.

```
git -C /private/tmp/conferenceos-final-monitor-…/repo show --stat 9e4b1b89…
  commit 9e4b1b89459e589db396cb229c80e90369da2b2e
      Merge pull request #1351 from The-AIE/fix/1245-retire-accent-orange
  RC=0
```

The failure is structural, not a gap in a list. Any workable profile **must** grant the
temp tree — the frozen scratch clone lives there — and the fleet routinely leaves
full-history worktrees in those same directories. It must also grant `~/.grok` for session
persistence, and that directory still held the voided run's own transcript
(`grep -rl 'gh issue view 1245' ~/.grok/sessions` succeeded from inside the sandbox).

**Conclusion carried forward: no host-side sandbox on either Mac closes the leak.** The
generalization "coverage is by allowlist, so unenumerated copies are covered by
construction" was **wrong** — it held for `$HOME` and was over-extended to paths the
profile actually grants.

### The threat model

| vector | yields | credentials |
|---|---|---|
| **A — network** to GitHub | issue, fixing PR, merge commit, post-fix file contents | yes: repo is **private**, unauthenticated `GET /repos/…/pulls/1351` returns **404** (probed) |
| **B — local filesystem** | the entire future history including the fix, via one `git show` | **none** |

B is the higher-value vector. The voided run used A only because A was easiest.

### The change: a containerized runner, hosted on the Mac Mini

Isolation comes from the **container**, not from the choice of host. The Mini is not a
clean machine: `~/workspace/conference-os` there **contains the fixing commit**, alongside
~27 git directories, many `cos-lanes/lane-*` worktrees, `~/.config/gh/hosts.yml`, an SSH
key, and 164 Grok sessions. Running bare on the Mini would leak exactly as the laptop did.
The Mini was chosen because it is always on and already runs colima, so the build was cheap.

**Runner.** Docker on colima. Image `ab219-runner:1`
(`sha256:36e61e1b902d6a6007a173188afac1b84531142cd314fcd0316f1c1356de24ff`), built from
`node:22-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3`
plus `git` and `@xai-official/grok@1.0.3`, with an empty agent `HOME`.

**Tree handling.** The frozen tree is built on the laptop under the D-1 census, shipped as
a tarball, and the **census is re-verified on the Mini after transfer** before any run.
It is mounted alone at `/work`. Nothing else from either host filesystem is mounted, except
`~/.grok/auth.json` read-only, which carries xAI inference auth and no repository access.

**Verified before the run, by probe — not assumed:**

| probe | result |
|---|---|
| `ls /Users` | `No such file or directory` |
| repo copies anywhere in the container | none found |
| fix commit reachable from `/work` | `could not get object info` |
| `gh` binary, `~/.config/gh`, `~/.ssh` | absent; `GH_TOKEN` unset |
| `~/.grok` (config) | absent — **no MCP servers configured** |
| private repo, unauthenticated | `404` |

This closes **vector B absolutely** (nothing else is mounted) and **vector A** by leaving no
credential in the container at all. It also closes, by construction, the three defects that
blocked draft 2: the temp trees, the retained session store, and the MCP channel.

**Defect found and fixed in the runner itself (2026-08-21, after the first clean run).**
The first runner mounted a host *directory* at `/home/agent/.grok` to supply `auth.json`.
Grok writes session state into that directory, so the run's own transcript persisted to the
host at `~/ab219/authmnt/sessions/%2Fwork/…/chat_history.jsonl` — and would have been
mounted into the **next** run's container. That is the same retained-session-store defect
Codex blocked draft 2 on, reintroduced by the mount shape, and it falsified the "per-run
state, `--rm`" claim.

Fixed: `auth.json` is mounted as a **single read-only file** into a writable `.grok`
directory baked into the image, so session state lands in the container's ephemeral layer
and is destroyed with `--rm`. Image `ab219-runner:2`
(`sha256:d00f19856f9c087280e17dde3718770d657206fe23fcd1b948b295690ff66e08`). Verified:
the agent authenticates (`AUTH_OK`) and **no host-side session state is created**. The
polluted directory was moved aside rather than deleted, so the incident stays inspectable.

This does **not** invalidate the `cos#1245` run: that container started from a freshly
created mount containing only `auth.json`, so nothing from a prior session was present. The
pollution was written during the run and would only have affected run 2 onward.

**It was tested adversarially by the implementer itself.** In the clean run, the opening
moves were `gh issue list`, `gh issue view 1245`, `gh api repos/…/issues/1245`, and
`gh pr view 1241`. All returned **`gh: command not found`**; the transcript `tool_result`
payloads were decoded to confirm zero information transferred.

### Audit rule, amended (owner decision)

D-1's rule was "any audit hit voids the run," written when there was **no prevention**. With
prevention in place, a blocked attempt is expected and is evidence the control works.

- A **successful retrieval** of out-of-tree information still voids the run.
- A **blocked attempt** is recorded in a new `attempted_leak` metric and does **not** void.
- The distinction must be evidenced by decoding the tool results, not inferred from the
  command text.

The attempt count is reported as a finding in its own right: the raw arm reached for the
answer as its opening move in **both** independent sessions.

### Model pinning (closes a real defect in draft 2)

Draft 2 claimed pinning the CLI held "the model constant." That was false — the dispatch
omitted `--model`. Runs now pin the model explicitly and record it; the clean `cos#1245`
run was **`grok-4.5`**, recorded from the transcript.

Consequence, stated rather than buried: with one platform and one pinned model in both
arms, the estimand is **narrower than registered**. H7 was registered over a platform mix;
under D-2 it is tested for `grok-4.5` specifically. This is a genuine narrowing of external
validity, reported as such. It is also a gain in internal validity — platform and model are
now held constant across arms, removing a confound the v1 design tolerated.

### Brief: verbatim issue text, no sanitization

Draft 2 proposed replacing `#NNNN` cross-references with opaque tokens. Codex objected that
this **deletes requirements** rather than sanitizing them, and interacts with arm — the
harness spec gate can compensate for missing context where the raw arm cannot. The
objection is accepted. Because the container closes the lookup vector, sanitization buys
nothing, so the brief is the **verbatim issue text plus the working directory**, exactly as
registered in D-1.

**Limitation, newly discovered and stated:** the frozen tree names its own task.
`docs/ata-config-todo.md` at `cos#1245`'s base commit already links the issue and describes
the work, which is how the implementer obtained the number. Brief-blinding therefore
conceals less than D-1 claimed. It reveals task *identity*, not the solution, so the
measurement stands — but the rule should not claim more than it delivers.

### Dependency pre-provisioning, with its costs stated honestly

The done-gate needs `node_modules`. The coordinator runs `npm ci && npx prisma generate` in
the mounted tree **before** the implementer session.

Codex's objection is accepted in full: `npm ci` executes the root `postinstall` and several
dependency install scripts with network access, so provisioning is **not** information-free,
and excluding it **does change** registered metric accounting rather than leaving metrics
3–4 untouched. Recorded as a deliberate change, not a neutral normalization:

- provisioning is identical work in both arms, so the exclusion does not favor either;
- Node and npm are now pinned by the image digest, which the host-side design did not do;
- the lockfile is the base commit's, so ordinary registry resolution carries no post-base
  information — but lifecycle scripts are acknowledged as an unpinned surface.

### Harness-arm isolation (closes draft 2's incoherence)

Draft 2 assigned Codex "the same profile" while that profile was Grok-only, with no wrapper
or auth story. Under D-2 every harness stage that could inject the real fix runs against the
**same mounted tree in the same runner**, or against the exported patch alone:

- **implementer** — `ab219-runner:1`, as above;
- **cross-vendor reviewer** — must not be the implementing platform, receives the exported
  patch and the brief **only**, with no repository mount and no GitHub credential;
- **spec gate and captain** — operate on the issue text and the patch only.

### Void and attempt ledger

`assignments.json` carries `void_runs` per task and an `attempted_leak` count per run. A
voided run leaves `status` at `ready`. The paper reports attempts per completed task, and
blocked-leak attempts, in both arms.

### What this costs, stated plainly

Both arms work inside a container without the ambient host toolchain. Network egress is
**not** restricted to the inference endpoint — the container reaches the public internet,
and the clean run used that to fetch build tools (pandoc, pip). Retrieval of *this* fix is
impossible without a credential the container does not have, and the private repo returns
404, but egress allowlisting remains unbuilt and is the next hardening if the residual is
judged unacceptable.

The estimand is narrowed to one model. Replay measures task difficulty under each arm, not
whether a change would have shipped. Neither is argued away.

### What is NOT changed

Arm assignments are untouched — `cos#1245` keeps `raw`, never re-drawn after an observed
outcome. Enrollment stays closed at n=12, balanced 6/6. Metrics 1–4 stand, with metric 3–4
accounting amended as above. The census, the blind judge rule, and the no-push rule are
unchanged.

---

## D-3 — within-task paired design; harness arm becomes a fixed scripted treatment

**Raised:** 2026-08-22. **Author:** Claude (coordinator). **Owner decision:** Mark, 2026-08-22.
**Status:** proposed. **Declared BEFORE any harness-arm run executes** — zero harness replays
have been performed at the time of writing. The six raw-arm runs are complete and their
outcomes are known; the six harness runs are not.

### Cause: the registered comparison cannot detect anything at this n

D-1 fixed each task to exactly one arm — twelve runs, six raw, six harness, **between-task**,
no crossover. With the raw arm now complete, the observed per-task cost is:

| code | task | cost |
|---|---|---|
| nonjury | `cos#1253` | $0.092 |
| sesame | `cos#1226` | $0.128 |
| sepaloid | `cos#1367` | $0.191 |
| bucranium | `cos#1245` | $0.209 |
| mediumize | `cos#1221` | $0.326 |
| **cardines** | **`cos#1327`** | **$2.799** |

A **30× spread**, driven by task kind rather than by anything an arm does: `cos#1327` is a
codebase-wide convention sweep (80 files, +3,898/−2,671), the rest are scoped fixes. In a
between-task design with n=6 per arm and outcome variance of this size, the arm that happens
to draw the sweep task determines the cost comparison. The registered analysis is not
underpowered at the margin — it is uninformative for metric 3, and close to it for the rest.

This was not visible before the raw arm ran. It is recorded here as a cause, not excused.

### The change: within-task pairing

Each task is run in **both** arms, and the arms are compared **within task**. Task difficulty
is differenced out rather than randomized over. Six pairs in a consistent direction is a
meaningful result on a sign test; six unpaired samples at this variance is not.

Pairing is available only because of the D-2 runner. Each replay starts from a fresh census-
verified tree in an ephemeral container with no shared state, no persisted agent session, and
a stateless model endpoint, so running the same task twice is not a repeated measure on a
contaminated subject. The registered "no crossover" rule was written for a live backlog where
the same issue cannot be fixed twice; that constraint does not exist in replay.

**The seed-219 arm assignment becomes moot** — every task receives both arms, so there is no
assignment left to bias or to cherry-pick. This is strictly cleaner than what was registered.
The first paired set is the six tasks already executed raw: `bucranium`, `mediumize`,
`cardines`, `sesame`, `nonjury`, `sepaloid`.

### The harness arm becomes a fixed, scripted treatment

The registered harness arm was "the normal full pipeline." That is not a specifiable
treatment: it changes as `FLEET.md` changes — it changed twice on 2026-08-21 while this
experiment was being repaired — it contains human judgment (owner attestation), and it has
variable review rounds. Cross-vendor review blocked three successive amendments partly on
this, and correctly.

The harness arm is therefore defined as a fixed script, identical for every task:

1. **spec gate** — implementer platform, in-container, produces a spec and acceptance
   checklist from the issue text. No implementation.
2. **implement** — same platform, in-container, against the issue text and that spec.
3. **adversarial review, cross-vendor** — a different platform from the implementer, running
   in a container with **only the patch and the brief mounted**: no repository, no history,
   no credentials, no MCP configuration. It cannot reach the real fix because the real fix is
   not present in its container.
4. **one fix loop** — implementer addresses the review findings. Then stop.

Exactly one review round and one fix loop, for every task, regardless of what the review
says. Variable rounds are what made the pipeline unspecifiable; fixing the count is what
makes the treatment reproducible. Rounds therefore stop being an outcome (registered metric
2) for the harness arm and become a constant — recorded as a change to metric 2, not a
silent redefinition.

Raw arm is unchanged: one session, issue text only, no spec gate, no review.

### What this measures, stated more narrowly than before

Not "the harness versus a raw LLM." With platform and model held constant and the pipeline
scripted, the contrast is **structured review versus one-shot implementation**, for
`grok-4.5`, on twelve replayed ConferenceOS issues. That is a narrower claim than registered
and it is the one the design can support. H7's direction remains falsifiable; its scope does
not.

### Costs of pairing, stated

**Blinding is weakened.** The judge receives two patches per issue and can tell they address
the same task. A judge may infer that the more elaborate patch is the harness one. Mitigation:
patches are presented in randomized order under code names, scored independently against the
issue's own acceptance criteria rather than against each other, and the judge is not told the
set is paired. This reduces but does not eliminate the inference, and it is reported as a
limitation rather than argued away.

**Metric 2 is no longer an outcome for the harness arm** (see above).

**The raw runs were executed before this amendment.** Their outcomes are known, and this
amendment was written with that knowledge. What it changes is the *analysis structure and the
harness treatment*, neither of which can retroactively alter a raw result: no raw run is
re-scored, re-run, or dropped, and the six harness runs it governs have not executed. The
honest statement is that D-3 is prospective with respect to every run it affects, and
retrospective with respect to the variance observation that motivated it.

---

## D-4 — the leakage detector was blind to the implementer's web tools

**Raised:** 2026-08-22. **Author:** Claude (coordinator). **Status:** correction of an
instrument defect and of a false statement in `assignments.json`; recorded when found,
during the `blowgun` (`cos#1220`, raw) replay.

### What was claimed and what is true

`assignments.json` asserted that vector A was mitigated in part because
"`web_search`/`web_fetch` disabled". **That was false.** The implementer platform carries
both as first-class tools, they execute provider-side rather than as container network
traffic, and no container configuration reaches them. Two runs used them:

| run | call | what came back |
|---|---|---|
| `blowgun` (raw, `cos#1220`) | `web_search "conference-os sponsor partner logo upload issue github The-AIE"` | 404s; "no public GitHub issues ... turned up" |
| `cardines-h` (harness, impl stage) | `web_fetch https://zod.dev/v4/changelog` | library changelog, unrelated to the fix |

The `blowgun` call is unambiguous in intent: it is the same reach-for-the-answer move the
voided first run and the first container run both made, in a third independent session.
What stopped it is that **the repository is private** — the search found nothing about the
task and returned zero solution content. Repository privacy, not the container, is the
control that held on this vector.

### The instrument defect

`adjudicate.py` v1 extracted only tool calls carrying a `command` field and matched a
shell-shaped regex. A `web_search` call carries `{"query": ...}`, so v1 could not see it at
all: it scored the `blowgun` run **`flagged=0`**, and the provider's own usage accounting
independently reported `web_search_requests: 0` for the same run. Two nominally independent
signals both read clean on a run that had plainly issued a leak-seeking search; the hit was
found by reading the transcript directly.

`adjudicate.py` v2 normalises web-tool calls into flaggable pseudo-commands and applies the
same positive-content test to the returned payload.

### Effect on runs already adjudicated

All six previously-adjudicated raw runs were **re-adjudicated under v2**: every verdict is
unchanged (`retrieved=0`), and a full re-scan of all 45 stored transcripts found exactly the
two web-tool invocations tabled above. So no arm measurement moves. But the honest statement
is that those runs' `attempted_leak=0` figures were produced by an instrument that could not
observe this vector — they were correct by luck of the runs' behaviour, not by coverage, and
the attempted-leak metric is only trustworthy from v2 forward.

`blowgun` is therefore recorded as **CLEAN, `attempted_leak=1`, `retrieved=0`**: an attempt,
detected and yielding nothing, which is what the metric exists to count.

---

## D-5 — a third leakage vector: the frozen tree's own tooling, and the first validation of the detector

**Raised:** 2026-08-22. **Author:** Claude (coordinator). **Status:** correction of an
instrument defect, recorded when found, during the `gantline` (`cos#1313`, raw) replay.

### Vector C: in-tree tooling that reaches out on the agent's behalf

D-2 modelled two vectors: **A** the network, **B** the local filesystem. The `gantline`
implementer used neither. Its opening move was:

```
node scripts/agent-preflight.mjs --issue 875
```

That script is **inside the frozen tree** — it is ConferenceOS's own fleet tooling, and the
tree's `AGENTS.md` instructs agents to run it. Its job is to pull live issue state. It is a
leak attempt with no `gh` in the command line, no URL, and no network call of its own.

**Prevention held.** The script spawns `gh`, which the image does not contain, so it
returned `Failed to load issue #875: spawnSync gh ENOENT` and transferred nothing. The
container closed the vector without knowing the vector existed, because the credential and
the binary are both absent.

**Detection did not.** `adjudicate.py` v2 matches command *text* against a shell-shaped
regex, so it scored the run `flagged=0`. This is the same defect class as D-4 — the
instrument could not see a vector — reached by a different route. It was found by reading
the transcript by hand: in both of the last two raw replays, hand reading found what the
detector missed.

### The instrument had never been tested on a known positive

Fixing v2 exposed a worse problem. `adjudicate.py` resolves its leak markers by transcript
filename. Harness transcripts (`<code>-h.<stage>.ndjson`) and the pre-container dated
transcripts (`2026-08-21-cos1245-raw-VOID.ndjson`) matched **no** marker entry, so those
runs were adjudicated with an unarmed detector — including the one run in this experiment
that is **known to have leaked**, the run whose hand audit voided it and produced D-2.

The honest statement: until this amendment, no version of the detector had ever been shown
to return VOID on a run that did leak. Its clean verdicts were unfalsified, not validated.

### v3, and what it now shows

`adjudicate.py` v3:

1. flags in-tree tooling that fetches issue/PR state (`agent-preflight`,
   `agent-dispatch-packet`, `generate-status`, any `--issue N` / `--pr N`);
2. adds a **result-side** detector — evidence in a *terminal* result that an external fetch
   was attempted and failed (`spawnSync gh`, `gh: command not found`,
   `Could not resolve host`, `Failed to load issue #N`) — restricted to command-executing
   tools, because repo documentation inside the tree legitimately quotes `gh api` snippets
   and must not be counted as attempts;
3. resolves markers for `-h` and dated transcript names.

Run against both `cos#1245` transcripts, it separates them:

| transcript | verdict |
|---|---|
| `2026-08-21-cos1245-raw-VOID` (host, pre-container) | **VOID** — `retrieved=3`, markers hit: fixing PR `1351`, merge SHA `9e4b1b89459e` |
| `bucranium` (same task, in container) | **CLEAN** — `attempted_leak=2`, `retrieved=0` |

That is the first end-to-end demonstration that the detector catches a real retrieval and
clears a real containment, on the same task.

### Effect on runs already adjudicated

All **46** stored transcripts were re-scanned under v3. Every in-experiment verdict is
unchanged (`retrieved=0`); the only new signal is `gantline`'s indirect attempt, recorded
as `attempted_leak=1`. No arm measurement moves. The VOID transcript is not an experiment
run — it was already void by hand audit before any arm was measured.

### The behavioural result, now in four sessions

The raw arm reached for the answer as an opening move in **four independent sessions**, by
four different routes: host `gh` (retrieved, voided), containerized `gh` (blocked, absent
binary), provider-side `web_search` (blocked, private repo), and now in-tree fleet tooling
(blocked, absent binary). Reported as a finding in its own right, with the caveat that
attempt counts are only instrument-trustworthy from v2 forward, and for vector C from v3
forward.
