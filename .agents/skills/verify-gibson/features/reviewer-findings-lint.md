# Reviewer findings lint

`scripts/review-findings-lint.mjs` checks a review body: every finding has `kind:` and `class:`, a blocking finding names a `trigger:`, a finding carries every field its kind lists in `requires` (a `pre-existing` finding needs `trigger:` and `base:`), and `VERDICT:` is the last line. Report-only.

## Sub-features

- `lint-clean` exits 0 and prints `clean` for a well-formed review.
- `lint-no-trigger` exits 1 and reports a blocking finding without a trigger.
- `lint-pre-existing` exits 0 for a `pre-existing` finding with `trigger:` and `base:` lines, and exits 1 with `pre-existing finding without base evidence` when the `base:` line is missing.
- `lint-bad-vocab` exits 2 when a kind's `requires` in the vocabulary file is not a list or names an unknown field, whatever the review contains.
- `lint-unknown-flag` exits 2 with `unknown flag:` on stderr.

## How to get to it (user POV)

- `node scripts/review-findings-lint.mjs --file review.md`, or pipe a review body on stdin (step 4c of `playbooks/reviewer.md`).

## Driving it with capture.sh

Preconditions: doctor is ok. Plant the files below under `$TMPDIR`.

- **Plant.** `printf '### Findings\n- none\n\nVERDICT: APPROVE\n' > "$TMPDIR/rv-good.md"` and `printf '### Findings\n- a.ts:1 wrong\n  kind: blocker\n  class: logic\n\nVERDICT: REQUEST_CHANGES\n' > "$TMPDIR/rv-bad.md"`.
- **Clean.** `capture.sh reviewer-findings-lint clean -- node scripts/review-findings-lint.mjs --file "$TMPDIR/rv-good.md"`. Exit `0`; `.out` contains `clean`.
- **Missing trigger.** `capture.sh reviewer-findings-lint no-trigger -- node scripts/review-findings-lint.mjs --file "$TMPDIR/rv-bad.md"`. Exit `1`; `.out` contains `blocking finding without trigger`.
- **Pre-existing.** Plant `printf '### Findings\n- a.ts:1 old bare catch\n  kind: pre-existing\n  class: ignored-error-return\n  trigger: fetch rejects => error swallowed\n  base: a.ts:1 at base is identical; no changed line reaches it\n\nVERDICT: APPROVE\n' > "$TMPDIR/rv-pre.md"` and `grep -v '^  base:' "$TMPDIR/rv-pre.md" > "$TMPDIR/rv-pre-nobase.md"`. `capture.sh reviewer-findings-lint pre-existing -- node scripts/review-findings-lint.mjs --file "$TMPDIR/rv-pre.md"`: exit `0`; `.out` contains `clean`. `capture.sh reviewer-findings-lint pre-existing-no-base -- node scripts/review-findings-lint.mjs --file "$TMPDIR/rv-pre-nobase.md"`: exit `1`; `.out` contains `pre-existing finding without base evidence`.
- **Bad vocabulary.** Plant `sed 's/"requires": \["trigger", "base"\]/"requires": "trigger"/' config/review-finding-classes.v1.json > "$TMPDIR/rv-vocab.json"`. `capture.sh reviewer-findings-lint bad-vocab -- node scripts/review-findings-lint.mjs --classes "$TMPDIR/rv-vocab.json" --file "$TMPDIR/rv-good.md"`. Exit `2`; `.err` contains `invalid requires list`.
- **Unknown flag.** `capture.sh reviewer-findings-lint bad-flag -- node scripts/review-findings-lint.mjs --nope`. Exit `2`; `.err` contains `unknown flag:`.
- **Suite.** `capture.sh reviewer-findings-lint suite -- bash scripts/tests/review-findings-lint.test.sh`. Exit `0`; the last line ends `0 failed`.

## Gotchas

- A finding with no `kind:` line is reported and treated as blocking for the trigger check.
- The vocabularies live in `config/review-finding-classes.v1.json`; an unknown class fails the lint.
- The linter checks that a `pre-existing` finding carries `trigger:` and `base:` lines. It does not check that the diff leaves the defect unreached; that is the reviewer's judgment.
