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

## D-2 — implementer isolation for both arms; dependency pre-provisioning; brief sanitization

**Raised:** 2026-08-21. **Author:** Claude (coordinator). **Owner decision:** Mark, 2026-08-21
("both" — isolation applies to both arms, not the raw arm alone).
**Status:** proposed. **One task executed under D-1 and was voided; see below.**

### What went wrong

The first replay executed under D-1 — `cos#1245`, raw arm, 2026-08-21 — was **void on the
leakage audit**. All three registered layers were applied correctly; this is a design
defect, not an execution mistake:

| layer | result |
|---|---|
| 1. total object census | PASS — 3,136 objects, store == `HEAD` closure exactly, `rev-list --count --all` = 1, `git remote` empty |
| 2. blind brief | PASS — scanned clean for canonical path, issue URL, fixing-PR number before dispatch |
| 3. post-run transcript audit | **HIT — void** |

The implementer's **first action, before reading any file in the frozen tree**, was
`gh issue view 1245 --repo The-AIE/conference-os`. It then read the fixing PR (#1351), that
PR's merge commit, and — via `gh api .../contents/<path>?ref=<merge_commit>` — the
**post-fix contents of two of the files it went on to edit**.

Its own third command, `git show 9e4b1b89… --stat`, failed locally: the census-truncated
tree worked exactly as designed. The implementer routed around it.

### Why this is a design defect

D-1 acknowledged the truncated tree "prevents *accidental* leakage; it is not isolation,"
and booked the remainder as a limitation on the premise that residual consultation would be
**undetectable**. The observed behavior is the opposite: overt, immediate, total, trivially
detected. Under D-1 the arms have a **detector and no control**, so runs void indefinitely
rather than producing data.

A second defect: Codex flagged on 2026-08-19 that "the task statement is not
frozen/sanitized." D-1 closed it only partway — the brief rule bars the canonical path,
issue URL, and fixing-PR number, but passes the issue **body** verbatim, and that body
contained `#1239` and `#1241`: a direct pivot to the fix.

### The threat model, corrected

The first draft of this amendment prescribed network denial alone. That draft was wrong,
and the error is recorded rather than quietly replaced: it was written after testing **one**
leakage vector. There are two, and they are independent.

| vector | what it yields | credentials needed |
|---|---|---|
| **A. network** — `gh`/`curl` to GitHub | issue, fixing PR, merge commit, post-fix file contents | yes (repo is private; unauthenticated `GET /repos/The-AIE/conference-os/pulls/1351` returns **404**) |
| **B. local filesystem** — the canonical checkout at `/Users/mrhinkle/Code/conference-os` and ~40 sibling worktrees | the **entire** future history, including the exact fix commit, via `git -C … show <merge_commit>` | **none** |

Vector B is the higher-value one: zero friction, no credentials, and it hands over the
literal diff. The voided run used A only because A was easiest, not because B was closed.

### Controls, measured on the host rather than assumed

All four probes run 2026-08-21 on this machine (macOS):

| mechanism | vector A (network) | vector B (canonical checkout) |
|---|---|---|
| `grok --sandbox strict` | ❌ `HTTP:200` — **not blocked** | ✅ `Operation not permitted` — **blocked** |
| `codex exec -s workspace-write` | ✅ `curl: (6) Could not resolve host` — **blocked** | ❌ `RC=0`, file read — **not blocked** |

**Neither CLI closes both vectors on macOS.** Grok's own documentation states that
child-network blocking "is enforced on **Linux only** (via seccomp). On macOS it is a
no-op." Codex's sandbox confines *writes*, not reads. This is a hard platform constraint,
not a configuration oversight, and it is the reason the first draft's
`codex exec -s workspace-write` prescription is rejected here: it would have closed the
lesser vector while leaving the entire future history readable by `cat`.

### The change

**1. Both arms run under an identical isolation profile (owner decision, 2026-08-21).**

Applying isolation to the raw arm alone would hand the harness arm capabilities the raw arm
lacks, and the primary metric would partly measure that asymmetry. Both arms get the same
profile, so any residual depresses both equally.

**2. The profile: Grok with a project-scoped custom sandbox, chosen because it closes
vector B.**

Written to `.grok/sandbox.toml` **inside the disposable scratch tree** (per-run, never in
the user's global config), and dispatched with credentials scrubbed and the model's own
retrieval tools disabled:

```toml
[profiles.ab219]
extends = "strict"
read_only = ["/Users/mrhinkle/.hermes/node", "/Users/mrhinkle/.local/bin"]
deny = ["/Users/mrhinkle/Code", "/Users/mrhinkle/.config/gh", "/Users/mrhinkle/.ssh", "/Users/mrhinkle/Documents"]
```

```bash
env -u GH_TOKEN -u GITHUB_TOKEN \
  grok --always-approve --cwd "$SCRATCH" --sandbox ab219 --disable-web-search -p "$(cat "$BRIEF")"
```

Verified on the host, same day, all three in one probe:

- `node --version` → `v22.22.3` — the toolchain stays usable. This grant is **required**:
  plain `strict` confines reads to CWD plus system paths, and `node` lives under
  `$HOME/.hermes`, so `strict` alone makes the registered done-gate unrunnable.
- `head /Users/mrhinkle/Code/conference-os/package.json` → `Operation not permitted` —
  **vector B closed, kernel-enforced.**
- `curl https://api.github.com/` → `HTTP:200` — **vector A is NOT closed.** Stated here
  rather than implied away.

**The control is an allowlist, not a denylist — this matters for coverage.** `extends =
"strict"` confines reads to the working directory plus system paths; the `deny` list is
belt-and-braces, not load-bearing. Probed the same day: under the `ab219` profile,
`ls /Users/mrhinkle` itself returns `Operation not permitted`. So local copies of the
repository that nobody enumerated are covered **by construction** rather than by having been
listed. That was checked against real examples: a filesystem scan found two further
conference-os checkouts outside the deny list — `/Users/mrhinkle/conference-os` and
`/Users/mrhinkle/cos-bakeoff/conference-os` — and both were denied by the profile anyway
(`Operation not permitted`). Independently, neither contains the fixing commit
`9e4b1b89…` (they track a different fork), but the coverage argument does not rest on that.

**3. What actually closes vector A, and what does not.**

Raw outbound sockets remain available; that is not fixable for Grok on macOS. The *specific*
leak is nonetheless closed by three independent facts, each verified:

- the repository is **private**, and unauthenticated retrieval of the fixing PR returns
  **404** (probed);
- `GH_TOKEN`/`GITHUB_TOKEN` are scrubbed from the environment, and `~/.config/gh` is in the
  kernel `deny` list, so no credential is reachable;
- `--disable-web-search` removes the model's own `web_search`/`web_fetch` tools.

So retrieval of *this fix* over the network requires a credential that does not exist in
the session. General web access survives, and that residual is **detection-only**, covered
by the retained transcript audit. It is stated as a limitation, not argued away.

**4. Literal network denial for both arms is deferred, with the reason recorded.**

The owner asked for both arms to lose network. On this hardware that is not achievable for
the CLI that closes vector B, and the CLI that does deny network leaves vector B wide open —
which would be a net loss. Achieving both simultaneously requires running implementers in a
container or VM with the scratch tree as the only mount and egress restricted to the
inference endpoint. Docker is installed on this host (20.10.24) but the daemon is not
running, and building a runner image with an authenticated CLI inside is a real piece of
infrastructure, not a flag. It is recorded as the recommended hardening if the residual in
item 3 is judged unacceptable; it is **not** silently substituted for what was asked.

**5. Implementer platform pinned to Grok for both arms.**

Forced by item 2. Side effect, in the experiment's favor: platform is held **constant**
across arms, so the comparison is harness-vs-raw holding the model fixed — the contrast H7
actually predicts — rather than a comparison across vendors, which the v1 design tolerated.

Consequences, stated:

- The harness arm's cross-vendor reviewer must not be Grok; it is **Codex**, also run under
  the same isolation profile, since a reviewer that can read the canonical checkout could
  inject the real fix through review feedback.
- The blind judge must be **Devin**: the registered rule bars a platform that implemented
  either arm (Grok, both), Claude never judges, and Codex has seen harness-arm output as its
  reviewer. If Devin is unavailable, judging **blocks** rather than falling back.

**6. Dependency pre-provisioning by the coordinator, before dispatch.**

The done-gate (`npx prisma generate && npm run typecheck:ci`, `npm test` where applicable)
needs `node_modules`, and installing it needs network the implementer will not have. The
coordinator therefore runs `npm ci && npx prisma generate` in the scratch tree **before** the
implementer session, with network available.

This is a strict improvement to the measurement, not only a workaround: dependency install
is identical work in both arms and was previously charged to the arm (in the voided run,
`npm ci` consumed a visible share of 5m41s). It is **excluded** from metrics 3 and 4 in both
arms. `node_modules` is git-ignored, so it cannot enter an exported patch, and it derives
solely from the lockfile **at the base commit**, carrying no post-base information.

**7. Brief sanitization; the sanitized text becomes the artifact of record.**

Before dispatch, every `#NNNN` cross-reference in the issue body is replaced with an opaque
token (`[REF-A]`, `[REF-B]`, …), and every `owner/repo` slug and URL is removed — in addition
to D-1's bars. The sanitized brief is stored at `paper/experiment/briefs/<code-name>.txt` and
is the task statement given to the blind judge, so implementer and judge see the same text.

**8. Void runs are recorded, not discarded.**

`assignments.json` gains a `void_runs` array per task. A voided run leaves `status` at
`ready` and appends a record (date, arm, cause, evidence path). The paper reports
attempts-per-completed-task; dropping void runs silently would misstate the cost of both arms.

**9. The audit is retained unchanged as the backstop.**

Prevention does not retire detection — item 3 explicitly depends on it. The transcript audit
runs exactly as under D-1 and additionally records the sandbox profile in force. Any hit
still voids.

### What this costs, stated plainly

Both arms now work without documentation lookup or package search, which real developers and
real harness lanes have. The depression is **symmetric**, so the between-arm comparison
holds, but absolute per-task performance under replay is a floor rather than a realistic
estimate. This stacks on the external-validity limitation D-1 already created.

Vector A is mitigated by credential denial rather than by network denial. Vector B is closed
at the kernel. The residual — a session that reaches the public internet for something other
than this private repository — is detectable and not prevented.

### What is NOT changed

Arm assignments are untouched: `cos#1245` keeps `raw`, and no arm is re-drawn after an
observed outcome — the voided run produced no measurement, and re-drawing on it would be the
exact bias the ledger exists to prevent. Enrollment stays closed at n=12, balanced 6/6.
Metrics 1–4 stand. The census and the no-push rule are unchanged.
