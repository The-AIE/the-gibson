#!/usr/bin/env bash
# prepush-review.sh — one-pass cross-vendor read of a lane's diff BEFORE its first push.
#
# Why (2026-10-15, Mark): catch blocking defects before CI and before the review of record, so
# they cost one local fix instead of a CI round plus a review round (the fleet's measured cost
# centre). This is a FILTER, not the independent review: it never approves, and the exact-head
# review after green CI still happens. One pass, blocking findings only, no open questions —
# half of August's review rounds fixed nothing because the prompt invited questions.
#
# Reviewer must not be the coder's vendor. Default reviewer: codex (via codex-review.sh, which
# appends the severity contract and validates that a VERDICT was actually produced). If the
# coder is codex, the reviewer is claude (plan mode, read-only).
#
# Usage: prepush-review.sh <worktree> [coder-vendor=grok]
#   The diff base is ALWAYS origin/main (fetched); it is not an argument and not an env var, so the
#   review cannot be pointed at an empty range.
#   PREPUSH_REVIEW_DRY=1  write the prompt+content files and print their paths; do not call a model.
#                         A dry run exits 2 (no verdict): it is never a pass, so an exported variable
#                         cannot turn the peer read into a green signal (Codex review 2026-10-23).
# Exit: 0 PASS, 1 REQUEST_CHANGES, 2 no verdict (treat as NOT a pass), 64 usage
set -uo pipefail
FLEET="$HOME/.claude/fleet"
WT="${1:?usage: prepush-review.sh <worktree> [coder-vendor]}"
[ $# -le 2 ] || { echo "prepush-review: usage: prepush-review.sh <worktree> [coder-vendor] — the base is always origin/main" >&2; exit 64; }
vendor_token() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'; }
CODER="$(vendor_token "${2:-grok}")"; BASE="origin/main"
case "$CODER" in grok|codex|claude|hermes) ;; *) echo "prepush-review: unknown coder vendor '$2' (grok|codex|claude|hermes)" >&2; exit 64 ;; esac
cd "$WT" 2>/dev/null || { echo "prepush-review: no worktree at $WT" >&2; exit 64; }
git fetch -q origin main 2>/dev/null || echo "prepush-review: WARNING fetch of origin/main failed; using the last known ref" >&2
git rev-parse --verify -q "$BASE^{commit}" >/dev/null \
  || { echo "prepush-review: base $BASE is unresolvable — cannot evaluate the diff, NOT a pass (fetch first)" >&2; echo "VERDICT: NONE"; exit 2; }
LANE="$(basename "$WT")"; TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${PREPUSH_REVIEW_OUTDIR:-$FLEET/reviews}/prepush-$LANE-$TS-$$"
mkdir -p "$OUTDIR" || { echo "prepush-review: cannot create $OUTDIR — NOT a pass" >&2; echo "VERDICT: NONE"; exit 2; }
CONTENT="$OUTDIR/diff.patch"; PROMPT="$OUTDIR/prompt.md"; OUT="$OUTDIR/out.log"

{ git diff "$BASE"...HEAD || exit 70; echo; echo "### UNCOMMITTED (working tree vs HEAD)"; git diff HEAD || exit 70; } > "$CONTENT" \
  || { echo "prepush-review: git diff failed — cannot evaluate, NOT a pass" >&2; echo "VERDICT: NONE"; exit 2; }
if ! grep -q '^diff --git' "$CONTENT"; then echo "prepush-review: nothing to review against $BASE"; exit 0; fi

case "$CODER" in
  codex) REVIEWER="${PREPUSH_REVIEWER:-claude}" ;;
  *)     REVIEWER="${PREPUSH_REVIEWER:-codex}" ;;
esac
REVIEWER="$(vendor_token "$REVIEWER")"
case "$REVIEWER" in codex|claude) ;; *) echo "prepush-review: unknown reviewer '$REVIEWER' (codex|claude)" >&2; exit 64 ;; esac
if [ "$REVIEWER" = "$CODER" ]; then
  echo "prepush-review: REFUSED — reviewer '$REVIEWER' is the coder's own vendor; the peer read must be cross-vendor" >&2; exit 64
fi

cat > "$PROMPT" <<P || { echo "prepush-review: cannot write $PROMPT — NOT a pass" >&2; echo "VERDICT: NONE"; exit 2; }
PRE-PUSH PEER READ — one pass, read-only, lane "$LANE", coder vendor: $CODER, base: $BASE.
You are a different vendor from the author. This is a FILTER before the first push, not the review
of record; you approve nothing. Report ONLY findings that would block under the severity contract:
incorrect behaviour, data loss, security/privacy exposure, or a false gate signal, with a concrete
trigger reachable in this diff. No questions, no suggestions, no style, no "consider". If the diff
touches .github/workflows/**, lint config, or test skips/quarantines, report that FIRST as a finding
(the coder may not change the gate to get green). For each finding: file:line, the quoted code,
the trigger, the wrong result. End with exactly one line: VERDICT: PASS or VERDICT: REQUEST_CHANGES.
P

case "$REVIEWER" in
  codex)
    [ -s "$PROMPT" ] || { echo "prepush-review: prompt file empty — NOT a pass" >&2; echo "VERDICT: NONE"; exit 2; }
    [ -n "${PREPUSH_REVIEW_DRY:-}" ] && { echo "prepush-review: DRY reviewer=codex prompt=$PROMPT content=$CONTENT"; echo "VERDICT: NONE (dry run)"; exit 2; }
    # The verdict is the line codex-review.sh PRINTS (its own parsed output), never a grep of the log:
    # the log echoes our prompt, which contains the literal text "VERDICT: PASS" — a grep of it made every
    # REQUEST_CHANGES read as PASS (found by the chatterbuilt#651 lane, 2026-10-15).
    VLINE="$("${PREPUSH_CODEX_REVIEW:-$FLEET/codex-review.sh}" "$PROMPT" "$CONTENT" "$OUT" 2>"$OUTDIR/stderr.log" | grep -E '^VERDICT:' | tail -1)"; rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ] || [ -z "$VLINE" ]; then echo "prepush-review: no verdict (rc=$rc) — NOT a pass" >&2; echo "VERDICT: NONE"; exit 2; fi
    echo "$VLINE"
    case "$VLINE" in "VERDICT: PASS") exit 0 ;; "VERDICT: REQUEST_CHANGES") exit 1 ;; *) echo "prepush-review: unrecognised verdict '$VLINE' — NOT a pass" >&2; exit 2 ;; esac ;;
  claude)
    [ -s "$PROMPT" ] || { echo "prepush-review: prompt file empty — NOT a pass" >&2; echo "VERDICT: NONE"; exit 2; }
    [ -n "${PREPUSH_REVIEW_DRY:-}" ] && { echo "prepush-review: DRY reviewer=claude prompt=$PROMPT content=$CONTENT"; echo "VERDICT: NONE (dry run)"; exit 2; }
    FULL="$OUTDIR/full-prompt.md"
    { cat "$PROMPT" && echo && echo "===== CONTENT UNDER REVIEW (inlined) =====" && cat "$CONTENT"; } > "$FULL" \
      || { echo "prepush-review: cannot assemble the review input — NOT a pass" >&2; echo "VERDICT: NONE"; exit 2; }
    [ -s "$FULL" ] || { echo "prepush-review: empty review input — NOT a pass" >&2; echo "VERDICT: NONE"; exit 2; }
    "${PREPUSH_CLAUDE_BIN:-claude}" -p --permission-mode plan --model sonnet < "$FULL" > "$OUT" 2>&1
    crc=$?
    if [ "$crc" -ne 0 ]; then echo "prepush-review: claude exited $crc — no verdict (NOT a pass)" >&2; echo "VERDICT: NONE"; exit 2; fi
    # The verdict is the LAST non-empty line, exactly; never the last matching substring anywhere in the
    # output, where a finding that quotes the protocol ("... VERDICT: PASS is the format") after a
    # REQUEST_CHANGES read as a pass. Anything else is no verdict. Codex read-only review 2026-10-23.
    V="$(grep -v '^[[:space:]]*$' "$OUT" | tail -1 | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
    case "$V" in
      "VERDICT: PASS") echo "$V"; exit 0 ;;
      "VERDICT: REQUEST_CHANGES") echo "$V"; exit 1 ;;
      *) echo "prepush-review: last line of the review is not a verdict ('$V') — NOT a pass" >&2; echo "VERDICT: NONE"; exit 2 ;;
    esac ;;
  *) echo "prepush-review: unknown reviewer $REVIEWER" >&2; exit 64 ;;
esac
