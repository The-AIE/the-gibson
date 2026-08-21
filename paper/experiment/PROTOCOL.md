# AB-219 protocol — harness+LLM vs raw LLM (gibson#219)

> **AMENDED 2026-08-19 — deviation D-1 (see `DEVIATIONS.md`).** The registered text
> below is preserved unedited for the record. Where it conflicts with the
> **Amendment D-1** section at the end of this file, the amendment governs:
> the unit of analysis is now a frozen replay set, the preempt rule binds the
> harness arm only, and a shallow-clone leakage control is mandatory.

Registered 2026-08-15, before any arm executed. Owner directives: run continuously
until done; **ConferenceOS and Gibson development always preempt it** (background
priority); task set picked to represent common coding needs.

## Enrollment

Seed set (n=6, spanning common classes — styling fix, file upload, data-model
feature, hardening, API validation, refactor) randomized with seed **219**
(`assignments.json`). Prospective rule: each new eligible Tier A/B product issue
(not meta/harness, not Tier C) is enrolled on arrival until **n=12**; late
assignments balance arms to 6/6 (stratified, same seed sequence).

## Arms

- **raw**: one implementer session (same platform mix as harness arm's
  implementers), given only the issue text. No spec gate, no cross-vendor review,
  no bot identity, no claim protocol. Work lands on `ab219/raw/<issue>` branches —
  **never merged to a real branch, no PR opened**. Done = implementer's own
  definition + green local CI-equivalent (`prisma generate`, `typecheck:ci`,
  `npm test` where applicable).
- **harness**: the normal full pipeline (spec gate → identity-bearing lane →
  sensors → cross-vendor review → evidence gate → captain). Merges land for real.

## Blinding

At judging time, every task's final diff is exported as a unified patch with
normalized metadata (no author, branch, PR body, or commit messages) under a
random code name; the code→arm mapping lives only in `sealed-mapping.json`,
which the judge never receives. Judge = a platform that implemented **neither**
arm of that task (Devin or Codex; never Claude, which coordinates). Judge
receives: issue text + blinded patch; returns: defect list with severities.

## Metrics (primary first)

1. Defects surviving to done, per blind judging.
2. Rework rounds consumed (harness arm) / self-corrections (raw arm).
3. Inference cost per completed task (logged per lane).
4. Wall-clock agent time.
5. For harness-arm merges: post-merge fixes within 14 days.

## Priority rule (owner-set)

The daily advance step runs **only when** fewer than 2 non-experiment
implementation lanes are active across COS/Gibson — development work always
preempts. Skipped days are normal and logged as no-ops.

## Pre-registered prediction (addendum to PREREGISTRATION.md)

**H7:** the harness arm shows fewer surviving defects per task at higher
per-task cost, and lower cost per *defect-free* completion on Tier B tasks.
Null or reversed results are reported as such.

## State

Progress is tracked as comments on gibson#219 (stigmergic — any session can
resume it). Raw-arm branches are deleted after judging; patches retained under
`paper/experiment/diffs/`.

---

## Amendment D-1 (2026-08-19, revised same day under cross-vendor review) — governs where it conflicts with the above

Cause and full accounting: `DEVIATIONS.md`. In short, live-backlog enrollment and the
preempt rule drew on the same queue, production always won, and five of six seed tasks
were merged by ordinary development before any arm ran. A first draft of this amendment
was FAILED by an independent Codex review on 2026-08-19; the revisions it forced are
logged in `DEVIATIONS.md` ("Revisions under cross-vendor review").

### Unit of analysis

A task is an already-closed issue plus a **base commit** — the first parent of the merge
commit of the PR that closed it. Both arms implement the issue text against that base.
`assignments.json` v2 carries the resolved `fixing_pr`, `merge_commit`, and `base_commit`
for all twelve tasks. **Each task is replayed exactly once, in its assigned arm** —
twelve runs total, six raw and six harness, a between-task randomized comparison exactly
as registered; there is no crossover. The clarification this amendment makes is that the
harness measurements for `cos#1220` and `cos#1313` come from **fresh harness replays**,
not from their historical pipeline traversals: that historical PR data (review rounds)
is reported as **supplementary observational data only**, never mixed into the replay
measurements, and its missing cost/wall-clock figures are reported as missing, not
estimated.

### Eligibility (clarified)

Excluded: issues carrying any `owner-gate-*` label, and any task whose replay would
require touching real external services, real user data, or live credentials. Issues
whose fixes *touch* schema, auth code paths, or PII handling are **eligible**: in replay,
neither arm's output is ever merged, deployed, or applied to any database, so the
blast-radius rationale behind the registered "no Tier C" rule does not arise. This is a
change in wording, not in the enrolled set — the registered v1 seed itself enrolled
schema-adjacent tasks (`cos#1221`, `cos#1313`) on the same logic, and the discrepancy
between v1's stated exclusion and its actual seed is now on the record rather than
papered over.

### Leakage control (mandatory, fail-closed)

Every replayed issue's real fix exists later in the same repository's history, and the
implementer runs on a machine where the canonical checkout and GitHub access exist.
The control has three layers; a run failing any one of them is **void and re-run**:

1. **Truncated tree, proven clean by total census.** Always a FRESH scratch directory
(`mktemp -d`), never reused. The whole block runs under `set -euo pipefail` — any
failing command aborts the run; nothing proceeds on a warning:

```bash
set -euo pipefail
SCRATCH=$(mktemp -d)
git init -q "$SCRATCH"
git -C "$SCRATCH" remote add origin file:///Users/mrhinkle/Code/conference-os
git -C "$SCRATCH" fetch --depth 1 --no-tags origin <base_commit>
git -C "$SCRATCH" checkout -q FETCH_HEAD
git -C "$SCRATCH" remote remove origin
# assertions — enumerations land in files so a failed enumerator (which a
# process substitution would hide from diff) aborts via pipefail, and the
# both-enumerators-empty case fails the non-emptiness checks.
git -C "$SCRATCH" cat-file --batch-all-objects --batch-check='%(objectname)' | sort > "$SCRATCH/.all"
git -C "$SCRATCH" rev-list --objects HEAD | awk '{print $1}' | sort -u > "$SCRATCH/.reach"
test -s "$SCRATCH/.all"
test -s "$SCRATCH/.reach"
# TOTAL object census: store == the base commit's reachable closure, exactly.
diff "$SCRATCH/.all" "$SCRATCH/.reach"
test "$(git -C "$SCRATCH" rev-list --count --all)" = 1
git -C "$SCRATCH" remote > "$SCRATCH/.remotes"
test ! -s "$SCRATCH/.remotes"
```

Verified 2026-08-19 on git 2.50.1, file-based form: a depth-1 fetch of a real base
commit passes the census (3,125 objects, store == HEAD closure, zero unreachable); an
adversarial check — writing one later-history object into the scratch store with
`hash-object -w` — makes the census fail; and the both-enumerators-empty failure mode
is caught by the `test -s` non-emptiness guards rather than passing through `diff`.

2. **Blind brief.** The implementer's brief contains the issue text and the scratch path
only — never the canonical repo path, the issue URL, or the PR number.

3. **Transcript audit.** The truncated tree prevents *accidental* leakage; it is not
isolation — the implementer could still read the canonical checkout or GitHub. So after
every run, grep the full transcript/log for: the canonical repo path, `github.com`,
`gh ` invocations, `git fetch`/`git remote add`, the issue number outside the brief, and
the fixing PR number. Any hit ⇒ the run is void and re-run. This is an audit for a
detectable act, not a prevention — the residual risk that an implementer consulted the
fix undetectably is acknowledged in the paper's limitations.

### Arms (amended)

- **raw**: one implementer session, blind brief only, no spec gate, no cross-vendor
  review, no bot identity, no claim. All work stays in the scratch clone; **nothing is
  ever pushed anywhere** — the deliverable is an exported patch. Done = implementer's
  own definition + `npx prisma generate && npm run typecheck:ci` green **+ `npm test`
  where applicable** (the registered raw-arm gate, unchanged).
- **harness**: the normal full pipeline, run against the frozen base rather than `main`.
  Its output is measured, then discarded — it is **not** merged, because the real fix
  already shipped.

### Priority rule (amended)

The preempt rule now binds the **harness arm only**, which consumes fleet review
capacity: a harness replay starts only when fewer than 2 non-experiment implementation
lanes are active. **Raw-arm replays are exempt** — one implementer session, no review,
no lane. Owner intent is preserved: production never queues behind the experiment.

### Metrics (amended)

Registered metrics 1–4 apply to the replay runs, where all four are captured per run.
Registered metric 5 (post-merge fixes within 14 days) is **dropped**, not redefined:
replayed output is never merged, so there is no production window to observe. The
supplementary historical data for `cos#1220`/`cos#1313` covers metric 2 only (rounds);
its metrics 3–4 are missing and reported as missing.

### Task selection for the seven continuation enrollments (limitation, stated)

The seven new tasks were selected by the coordinator from the eligible closed-issue pool
to span distinct common-need classes, **before any replay ran** — selection preceded all
arm outcomes. The selection itself is judgment-based and not algorithmically
reproducible; only the subsequent arm ASSIGNMENT (seed-219 shuffle) is exactly
reproducible. Both facts go in the paper: the assignment is verifiable, the selection is
a stated limitation.

### Limitation created by this amendment

Replay measures task difficulty under each arm, not whether a change would have shipped;
the leakage audit detects consultation of the real fix but cannot make it impossible.
Both are stated as limitations of the design in the paper. Neither is argued away.

---

## Amendment D-2 (2026-08-21) — governs where it conflicts with D-1 and the registered text

Cause and full accounting, including two rejected drafts: `DEVIATIONS.md` (D-2). The first
replay under D-1 was voided — the implementer retrieved the fixing PR and post-fix file
contents as its opening move. D-1 detects that but does not prevent it. Owner decisions
2026-08-21: isolation applies to **both** arms; the runner is hosted on the Mac Mini; a
**blocked** attempt is logged, not voiding.

### Threat model

- **A — network** to GitHub. Needs credentials: the repo is private and unauthenticated
  retrieval of the fixing PR returns **404**.
- **B — local filesystem.** Any checkout with the future history yields the fix via one
  `git show`, with **no** credentials. Higher-value vector.

**No host-side sandbox on either Mac closes both.** Measured: `codex -s workspace-write`
denies network but reads the canonical checkout (`RC=0`); a Grok `strict`-based profile
denies the canonical checkout but not network (`HTTP:200`), and was defeated anyway via the
temp trees and `~/.grok`, both of which any workable profile must grant.

### Leakage control — layer 0: containerized runner

Isolation comes from the **container**, not the host. The Mini is *not* clean —
`~/workspace/conference-os` there contains the fixing commit — it is simply always on and
already running colima.

- Image `ab219-runner:2`
  (`sha256:d00f19856f9c087280e17dde3718770d657206fe23fcd1b948b295690ff66e08`), from
  `node:22-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3`
  plus `git` and `@xai-official/grok@1.0.3`. Empty agent `HOME`.
- The frozen tree is built on the laptop under the D-1 census, shipped as a tarball, and the
  **census is re-verified on the Mini after transfer**. It is mounted alone at `/work`.
- `auth.json` is mounted as a **single read-only FILE** at `/home/agent/.grok/auth.json`,
  never as a directory. Mounting the directory causes Grok to persist session state to the
  host, which would carry the previous run's transcript into the next container — the
  retained-session-store defect, reintroduced by mount shape. Verified after the fix: the
  agent authenticates and **no host-side session state is created**.
- `--rm`, so agent state lands in the ephemeral layer and is destroyed with the container.

```bash
docker run --rm \
  -v <SCRATCH>:/work \
  -v <BRIEF>:/brief.txt:ro \
  -v <AUTH_JSON_FILE>:/home/agent/.grok/auth.json:ro \
  -w /work ab219-runner:2 \
  grok --always-approve --cwd /work --model <PINNED_MODEL> \
       --output-format streaming-messages-json --prompt-file /brief.txt
```

**Probe before every run** (assumption is what voided the first attempt):

| probe | required result |
|---|---|
| `ls /Users` | No such file or directory |
| repo copies in container | none |
| fix commit from `/work` | could not get object info |
| `gh`, `~/.config/gh`, `~/.ssh` | absent; `GH_TOKEN` unset |
| `~/.grok` config | absent (no MCP servers) |
| private repo unauthenticated | 404 |

### Audit rule (amended)

- **Successful retrieval** of out-of-tree information → run is **void** and re-run.
- **Blocked attempt** → recorded in `attempted_leak`, run stands.
- The distinction must be evidenced by decoding tool results, never inferred from command
  text. Attempt counts are reported as a finding: the raw arm reached for the answer as its
  opening move in both independent sessions run so far.

### Model pinning

Runs pin `--model` explicitly and record it (`cos#1245`: **grok-4.5**). Both arms use the
same platform and pinned model, which removes a confound but **narrows the estimand**: H7
was registered over a platform mix and is now tested for one model. Reported as a limitation.

### Brief

**Verbatim issue text** plus the working directory — no sanitization. The container closes
the lookup vector, so sanitization would only delete requirements, and it would interact
with arm (the harness spec gate can compensate where raw cannot).

Limitation: the frozen tree may name its own task — at `cos#1245`'s base commit,
`docs/ata-config-todo.md` links the issue and describes the work. Brief-blinding conceals
task identity less than D-1 claimed; it does not reveal the solution.

### Dependency pre-provisioning

`npm ci && npx prisma generate`, run by the coordinator in the mounted tree before the
implementer session. Excluded from metrics 3–4 in both arms.

Stated honestly: `npm ci` executes `postinstall` and several dependency install scripts with
network, so this is **not** information-free, and the exclusion **changes** registered metric
accounting rather than leaving it untouched. It is identical work in both arms, Node/npm are
pinned by the image digest, and the lockfile is the base commit's.

### Harness-arm isolation

- implementer — `ab219-runner:1`, as above;
- cross-vendor reviewer — not the implementing platform; receives the exported patch and the
  brief **only**, with no repository mount and no GitHub credential;
- spec gate and captain — operate on the issue text and the patch only.

### Limitations created by this amendment

Egress is **not** restricted to the inference endpoint: the container reaches the public
internet, and the clean run used that to fetch build tools. Retrieval of this fix remains
impossible without a credential the container lacks, but egress allowlisting is unbuilt and
is the next hardening. The estimand is narrowed to one model. Replay measures task
difficulty under each arm, not whether a change would have shipped.
