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
   → Resolved: all twelve tasks get fresh replays in both arms; historical pipeline
   data for `cos#1220`/`cos#1313` is supplementary observational data only.
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
