# Reviewer findings lint

`scripts/review-findings-lint.mjs` checks a review body: every finding has `kind:` and `class:`, a blocking finding names a `trigger:`, and `VERDICT:` is the last line. Report-only.

## Sub-features

- `lint-clean` exits 0 and prints `clean` for a well-formed review.
- `lint-no-trigger` exits 1 and reports a blocking finding without a trigger.
- `lint-unknown-flag` exits 2 with `unknown flag:` on stderr.

## How to get to it (user POV)

- `node scripts/review-findings-lint.mjs --file review.md`, or pipe a review body on stdin (step 4c of `playbooks/reviewer.md`).

## Driving it with capture.sh

Preconditions: doctor is ok. Plant two files under `$TMPDIR`.

- **Plant.** `printf '### Findings\n- none\n\nVERDICT: APPROVE\n' > "$TMPDIR/rv-good.md"` and `printf '### Findings\n- a.ts:1 wrong\n  kind: blocker\n  class: logic\n\nVERDICT: REQUEST_CHANGES\n' > "$TMPDIR/rv-bad.md"`.
- **Clean.** `capture.sh lint clean -- node scripts/review-findings-lint.mjs --file "$TMPDIR/rv-good.md"`. Exit `0`; `.out` contains `clean`.
- **Missing trigger.** `capture.sh lint no-trigger -- node scripts/review-findings-lint.mjs --file "$TMPDIR/rv-bad.md"`. Exit `1`; `.out` contains `blocking finding without trigger`.
- **Unknown flag.** `capture.sh lint bad-flag -- node scripts/review-findings-lint.mjs --nope`. Exit `2`; `.err` contains `unknown flag:`.
- **Suite.** `capture.sh lint suite -- bash scripts/tests/review-findings-lint.test.sh`. Exit `0`; the last line ends `0 failed`.

## Gotchas

- A finding with no `kind:` line is reported and treated as blocking for the trigger check.
- The vocabularies live in `config/review-finding-classes.v1.json`; an unknown class fails the lint.
