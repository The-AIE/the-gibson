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

## D-2 — network isolation for both arms; dependency pre-provisioning; brief sanitization

**Raised:** 2026-08-21. **Author:** Claude (coordinator). **Owner decision:** Mark, 2026-08-21
("both" — network denial applies to both arms, not the raw arm alone).
**Status:** proposed. **One task has executed under D-1 and was voided; see below.**

### What went wrong

The first replay executed under D-1 — `cos#1245`, raw arm, 2026-08-21 — was **void on
the leakage audit**. All three registered layers were applied correctly and the failure
was not an execution mistake:

| layer | result |
|---|---|
| 1. total object census | PASS — 3,136 objects, store == `HEAD` closure exactly, `rev-list --count --all` = 1, `git remote` empty |
| 2. blind brief | PASS — scanned clean for canonical path, issue URL, fixing-PR number before dispatch |
| 3. post-run transcript audit | **HIT — void** |

The implementer's **first action, before reading any file in the frozen tree**, was
`gh issue view 1245 --repo The-AIE/conference-os`. It went on to read the fixing PR
(#1351), that PR's merge commit, and — via `gh api .../contents/<path>?ref=<merge_commit>`
— the **post-fix contents of two of the files it then edited**.

Its own third command, `git show 9e4b1b89… --stat`, failed locally: the census-truncated
tree worked exactly as designed. The implementer simply routed around it over the network.

### Why this is a design defect and not bad luck

D-1 acknowledged that the truncated tree "prevents *accidental* leakage; it is not
isolation," and booked the remainder as a stated limitation on the premise that residual
consultation would be **undetectable**. The observed behavior is the opposite: leakage
was overt, immediate, total, and trivially detected. The honest reading is that under
D-1 the arms have **no leakage control at all** — only a detector — and that the detector
converts every run into a void run rather than into data. Re-running under D-1 as written
produces void runs indefinitely, because the implementer runs on a host with an
authenticated `gh` and reaches for it as move one.

A second, narrower defect is now also demonstrated. Codex flagged on 2026-08-19 that "the
task statement is not frozen/sanitized"; D-1 closed it only partway. The brief rule bars
the canonical path, the issue URL, and the fixing-PR number, but passes the issue **body**
verbatim, and this body contained `#1239` and `#1241`. Those cross-references are a direct
pivot to the fix.

### The change

**1. Network denial for the implementer session, in BOTH arms (owner decision, 2026-08-21).**

Applying it to the raw arm alone would hand the harness arm a capability — documentation
lookup, package registries, general search — that the raw arm lacks, and the primary
metric would then partly measure that asymmetry rather than the harness. Both arms are
therefore denied network egress for child processes, and both lose it equally.

**2. Implementer platform for replay runs is pinned to Codex, for both arms — forced by
a verified platform limitation, not by preference.**

Grok's sandbox cannot deliver this control on the available hardware. Its own
documentation states that child-network blocking "is enforced on **Linux only** (via
seccomp). On macOS it is a no-op." Measured on this host (macOS, 2026-08-21):

| mechanism | probe result |
|---|---|
| `grok --sandbox strict` | `HTTP:200` — **network NOT blocked** (`gh` binary unreadable, but `curl` reaches the internet) |
| `codex exec -s workspace-write` | `curl: (6) Could not resolve host: api.github.com` / `HTTP:000 rc=6` — **network blocked, kernel-enforced (Seatbelt)** |

Writing `grok --sandbox strict` into the protocol would therefore have been a control that
does not exist on the machine the experiment runs on — the same class of error D-2 is being
filed to correct. Both arms use `codex exec -s workspace-write`, with `GH_TOKEN` and
`GITHUB_TOKEN` scrubbed from the environment as a second, independent layer.

Consequences of pinning the platform, stated rather than buried:

- The registered raw-arm wording ("same platform mix as harness arm's implementers") is
  **satisfied more strictly than before**: platform is now held constant across arms,
  removing a confound the v1 design tolerated.
- The comparison becomes harness-vs-raw **holding the model fixed**, which is the
  contrast H7 actually predicts. It is no longer a comparison across vendors.
- **The blind judge must now be Devin.** The registered rule is that the judge
  implemented neither arm; with Codex implementing both, Codex is disqualified, and
  Claude never judges. If Devin is unavailable, judging blocks — it does not fall back
  to Codex.
- The harness arm's cross-vendor reviewer must not be Codex; it is Grok, and the
  reviewer is **also** network-denied, since a networked reviewer could retrieve the real
  fix and inject it through review feedback.

**3. Dependency pre-provisioning by the coordinator, before the implementer starts.**

The registered done-gate (`npx prisma generate && npm run typecheck:ci`, `npm test` where
applicable) requires `node_modules`, and installing it requires network. The coordinator
therefore runs `npm ci` and `npx prisma generate` in the scratch tree **with network, before
dispatch**, and the implementer session begins against a tree that already has its
dependencies.

This is a strict improvement to the measurement, not only a workaround: dependency install
is identical work in both arms and was previously charged to the arm's wall-clock and token
cost (in the voided `cos#1245` run, `npm ci` consumed a visible share of 5m41s). Pre-provisioning
removes it from both arms' metrics 3 and 4. `node_modules` is git-ignored, so it cannot enter
an exported patch, and it is derived solely from the lockfile **at the base commit** — it
carries no post-base information.

**4. Brief sanitization, and the sanitized text becomes the artifact of record.**

Before dispatch, the issue body is rewritten: every `#NNNN` cross-reference is replaced with
an opaque token (`[REF-A]`, `[REF-B]`, …), every `owner/repo` slug and every URL is removed.
The sanitized brief is stored under `paper/experiment/briefs/<code-name>.txt` and is the text
the judge sees as the task statement, so judge and implementer receive the same statement.

**5. Void runs are recorded, not discarded.**

`assignments.json` gains a `void_runs` array per task. A voided run leaves `status` at
`ready` and appends a record (date, arm, cause, evidence path). The paper reports
attempts-per-completed-task; silently dropping void runs would misstate the cost of both arms.

**6. The audit is retained unchanged, as a backstop, plus one assertion.**

Prevention does not retire detection. The transcript audit runs exactly as under D-1, and
additionally asserts that the sandbox flag was in effect for the run. Any hit still voids.

### What this costs, stated plainly

Both arms now work without documentation lookup, package search, or web access. Real
developers and real harness lanes have those. This depresses both arms **symmetrically**,
so the between-arm comparison stays sound, but absolute per-task performance under replay
is a floor rather than a realistic estimate, and generalization to networked development is
correspondingly weaker. This is an additional external-validity limitation stacked on the
one D-1 already created, and it is reported as such rather than argued away.

The residual risk that an implementer consults the fix through a channel neither denied nor
logged is reduced but not eliminated. It remains a stated limitation.

### What is NOT changed

Arm assignments are untouched: `cos#1245` keeps `raw`, and no arm is re-drawn after an
observed outcome — the voided run produced no measurement, and re-drawing on it would be
the exact bias the ledger exists to prevent. Enrollment stays closed at n=12, balanced 6/6.
Metrics 1–4 stand. The census and the no-push rule are unchanged.
