---
title: "Lesson ledger schema"
nav_exclude: true
---

# Lesson ledger schema

> **Authority:** Non-normative. Explanation only. Binding commit, pull request, and merge rules live in [`AGENTS.md`](../../AGENTS.md). This file must not add, drop, or weaken those rules.

Git markdown in this repository is the memory substrate ([D-001](../../memory/DECISIONS.md), 2026-07-24). Issue #576 restates that for the self-improvement loop. This page describes the lesson and incident fields that `scripts/lesson-ledger-lint.mjs` checks. It does not execute a proof, merge a pull request, or add a role.

Check it offline:

```bash
node scripts/lesson-ledger-lint.mjs --offline
```

`--offline` skips only the closed-issue lookup. Every other check still runs. Exit 0 means those structural checks found nothing. It does not mean the evidence is correct, the proof ran, or a lesson is healthy. The stdout line `evidence-report` counts `unknown` and `unverified`. The line `lesson-ledger-lint: OK` is printed only when there is no structural finding. `unknown` on that report is not a pass.

An evaluated violation exits 1. That uses the ledger lint that already exists. This schema does not add a workflow, and it does not auto-merge anything.

## Lesson record

A heading is `## L-NNN · YYYY-MM-DD · slug`.

From lesson number 98 upward, the heading must match that shape, and the record must contain these lines. The value may be the word `unknown`. Omitting the line fails, because an absent value is not the word `unknown`.

| Line | Value |
|---|---|
| `**Status:**` | Free text, plus the rules below. `unknown` is allowed. `unknown (no sensor yet)` is prose-only debt. |
| `**Evidence:**` | `unknown`, or a space-separated list of public refs. |
| `**Proof:**` | `unknown`, or `<40 lowercase hex sha> <repo-relative entrypoint> <repo-relative fixture dir>`. |
| `**Reverted attempt:**` | `unknown`, or a short public reason. |
| `**Occurred:**` | `YYYY-MM-DD`. The heading date is the occurrence date. |
| `**Ingested:**` | `YYYY-MM-DD`. When the record was written down. Not the same fact as Occurred. |
| `**Tags:**` | Required, as before. |

Lessons below number 98 may omit Evidence, Proof, Reverted attempt, Occurred, and Ingested. Omission is reported `unknown` and does not fail. An explicit value on an older lesson is checked the same way as a new one.

A public ref is one of:

- `https://github.com/owner/repo/issues/...`
- `https://github.com/owner/repo/pull/...`
- `https://github.com/owner/repo/commit/...`
- `https://github.com/owner/repo/actions/...`
- `owner/repo#N`
- 40 lowercase hex characters

The lint checks shape only. It does not fetch the URL or resolve the commit.

A Proof path is repo-relative to `--root`. It must not be absolute, must not contain `..` or a backslash, and must not be a symlink. The entrypoint must be an existing file and the fixture path an existing directory. When both exist, the report word is `unverified`. This lint does not run the gate. A missing path fails. A symlink fails and is not followed.

`**Status:**` starting with `fixed` and an explicit `**Proof:** unknown` fails. The finding says `unknown is not correct`. `fixed` with the Proof line omitted does not fail. That omission is still reported `unknown` and is not a proof. The existing lesson for issue #412 keeps its `fixed` status and has no Proof line. Adding `**Proof:** unknown` there would fail this rule, so the line is left absent.

`**Status:**` starting with `reverted` requires a Reverted attempt value other than `unknown` and other than omission. The report word `recorded` means the text is present. It does not mean the revert was checked.

This lint does not enforce the whole historical status vocabulary. Strings already in the ledger stay valid. `unknown` and `reverted` are additional allowed values, not a new closed list.

Lesson ids must increase in file order. That order is not occurrence order. A later id may name an earlier Occurred date.

Keep each parsed field on one line, and follow it with another field or a heading. A blank line does not end a field. Prose after the last field is swallowed into that field. Text inside a fence is not a field.

## Incident record

`memory/incidents/I-NNN.md` is one incident. `memory/incidents/INDEX.md` is the only map. Each non-comment line is `I-NNN L-NNN`. `memory/incidents/README.md` is not a second map.

The heading is `## I-NNN · YYYY-MM-DD · slug`. Occurred must equal that date. Ingested is separate. The file also requires Evidence, Proof, Reverted attempt, Status, and exactly one Lesson id that exists in `memory/LESSONS.md`. The index row must name that same lesson. Zero lessons is unmapped. Two lesson ids, or any other text around the id, is multiply mapped. A missing file, a missing row, a duplicate id, or any other regular file in that directory fails.

Several incidents may share one lesson. One incident must not list two lessons. The lint does not freeze the count of incidents.

If `memory/incidents/` is absent, incident checks are skipped. If any `I-NNN.md` exists, `INDEX.md` is required.

## Privacy

These patterns fail closed on Evidence, Proof, Reverted attempt, Occurred, and Ingested, and on the full text of `memory/incidents/` (fences included). The finding names the rule id and does not print the matched text.

| Rule id | Pattern |
|---|---|
| `home-users` | `/Users/` |
| `home-posix` | `/home/` |
| `tilde-path` | `~/` |
| `internal-host` | a dotted name ending in `.internal` or `.local` |
| `pem-key` | a PEM private-key banner |
| `assigned-secret` | `api_key`, `token`, `password`, or `secret` assigned a value of 8 or more non-space characters |

Historical lesson prose is not scanned. A private path in What happened does not fail. The same path on an Evidence line does. A fenced copy is not a lesson field, so a fenced secret in a lesson does not trip the field scrub. That is a limit. Incident files are scrubbed in full, including fences.

## Backfill limits

The public incident list on issue #419 is 24 rows dated 2026-09-07 through 2026-10-03, ingested 2026-10-03 (the day that issue was opened). Each row is an incident file. The lesson states the row and marks root cause `unknown`. The pattern column is a pattern tag, not a verified cause. No backfilled lesson is `fixed`. Proof and Reverted attempt are `unknown` because the public row does not name a proof triple. Evidence is the issue #419 URL, plus the issue or pull URL the row already names. Nothing else is inferred.

The 2026-09-30 row for `ci/gibson-gate.yml` and issue #412 is the existing lesson L-097. It is the same incident, not a later recurrence, so L-097 stays `fixed (#412)` and gains only an Evidence line. No other row was shown to be a recurrence of an already fixed lesson.

Issue #535 is the pre-push locale lesson (empty `LANG` and `LC_ALL`; six database-backed suites failed for a reason unrelated to the code; the gate must export a default locale before any gate command, filling only when unset). It is linked, including pull #531, and it is not marked `fixed`.

Two older lessons had a Harness fix line that was a byte copy of How to apply. Those Harness fix lines now say that no harness artifact was shipped and that the previous text was a copy. The How to apply text is unchanged. No supervision role was added.
