#!/usr/bin/env bash
# injection-scan.sh — find invisible characters in anything an agent reads (red-team Phase 2)
set -uo pipefail

usage() {
  cat <<'EOF'
injection-scan.sh — scan agent-ingested files for invisible/deceptive Unicode

WHAT IT DOES
  Greps skills, prompts, recipes, and shared config for characters that a code
  reviewer cannot see but a tokenizer can: zero-width spaces/joiners, word
  joiners, bidi overrides, invisible operators, and non-breaking/ideographic
  spaces. Prints file:line:offset with the codepoint named, and exits 1 if any
  are found in a file that reaches a model's context.

WHY
  Goose's "Pale Fire" disclosure (Jan 2026): attackers hid U+200B/U+200C inside
  *shared recipes*. Invisible in a git diff, fully tokenized by the LLM — a
  config file became the injection delivery vehicle, fleet-wide. Any shared
  skill pack has the same shape. A human reviewing that diff sees nothing wrong,
  which is the entire point of the attack, so the check has to be mechanical.

USAGE
  injection-scan.sh [paths...]            # default: the agent-ingested paths below
  injection-scan.sh --all [paths...]      # scan every text file given, not just agent-ingested ones
  injection-scan.sh --list                # print what would be scanned
  injection-scan.sh --help

DEFAULT SCOPE (things a model ingests)
  *.md  *.mdc  *.mdx  *.txt  *.yaml  *.yml  *.json  *.toml
  under: . (repo root), honouring git tracking when inside a git repo

EXIT
  0  clean
  1  suspicious characters found (details on stdout)
  2  usage error

NOTE
  A hit is not automatically an attack — em-dashes are fine, U+00A0 sneaks in from
  copy-paste. A hit means a human must look at that exact byte and say why it is
  there. Silence is the only acceptable steady state for a shared skill pack.
EOF
}

ALL=0
LIST=0
PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --all) ALL=1 ;;
    --list) LIST=1 ;;
    -*) echo "unknown arg: $1" >&2; usage; exit 2 ;;
    *) PATHS+=("$1") ;;
  esac
  shift
done

# codepoint<TAB>name — the set that is invisible or reorders rendering
SUSPECT=$(cat <<'CP'
\xe2\x80\x8b	U+200B ZERO WIDTH SPACE
\xe2\x80\x8c	U+200C ZERO WIDTH NON-JOINER
\xe2\x80\x8d	U+200D ZERO WIDTH JOINER
\xe2\x80\x8e	U+200E LEFT-TO-RIGHT MARK
\xe2\x80\x8f	U+200F RIGHT-TO-LEFT MARK
\xe2\x80\xaa	U+202A LEFT-TO-RIGHT EMBEDDING
\xe2\x80\xab	U+202B RIGHT-TO-LEFT EMBEDDING
\xe2\x80\xac	U+202C POP DIRECTIONAL FORMATTING
\xe2\x80\xad	U+202D LEFT-TO-RIGHT OVERRIDE
\xe2\x80\xae	U+202E RIGHT-TO-LEFT OVERRIDE
\xe2\x81\xa0	U+2060 WORD JOINER
\xe2\x81\xa1	U+2061 FUNCTION APPLICATION
\xe2\x81\xa2	U+2062 INVISIBLE TIMES
\xe2\x81\xa3	U+2063 INVISIBLE SEPARATOR
\xe2\x81\xa4	U+2064 INVISIBLE PLUS
\xe2\x81\xa6	U+2066 LEFT-TO-RIGHT ISOLATE
\xe2\x81\xa7	U+2067 RIGHT-TO-LEFT ISOLATE
\xe2\x81\xa8	U+2068 FIRST STRONG ISOLATE
\xe2\x81\xa9	U+2069 POP DIRECTIONAL ISOLATE
\xef\xbb\xbf	U+FEFF ZERO WIDTH NO-BREAK SPACE (BOM)
\xc2\xa0	U+00A0 NO-BREAK SPACE
\xe3\x80\x80	U+3000 IDEOGRAPHIC SPACE
\xc2\xad	U+00AD SOFT HYPHEN
CP
)

collect() {
  if [[ ${#PATHS[@]} -gt 0 ]]; then
    local p
    for p in "${PATHS[@]}"; do
      if [[ -d "$p" ]]; then find "$p" -type f; else echo "$p"; fi
    done
    return
  fi
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files
  else
    find . -type f -not -path './.git/*'
  fi
}

in_scope() {
  [[ "$ALL" -eq 1 ]] && return 0
  case "$1" in
    *.md|*.mdc|*.mdx|*.txt|*.yaml|*.yml|*.json|*.toml) return 0 ;;
    *) return 1 ;;
  esac
}

FILES=()
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  in_scope "$f" || continue
  FILES+=("$f")
done < <(collect)

if [[ "$LIST" -eq 1 ]]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "injection-scan: nothing in scope"
  exit 0
fi

HITS=0
while IFS=$'\t' read -r esc name; do
  [[ -n "$esc" ]] || continue
  bytes=$(printf '%b' "$esc")
  # -a: treat as text even if the file looks binary; a hit is exactly the kind of
  # thing that makes grep call a file binary.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "$line  <-- $name"
    HITS=$((HITS + 1))
  done < <(grep -a -H -n -b -o -F "$bytes" "${FILES[@]}" 2>/dev/null || true)
done <<< "$SUSPECT"

if [[ "$HITS" -gt 0 ]]; then
  cat <<EOF

injection-scan: $HITS invisible/deceptive character(s) across ${#FILES[@]} agent-ingested file(s).

Each hit needs a human answer to "why is this byte here?". If a shared skill,
recipe, or prompt file is on that list, treat it as compromised until proven
otherwise: it is the Pale Fire shape exactly. Strip with:

  perl -CSD -pi -e 's/[\\x{200B}-\\x{200F}\\x{202A}-\\x{202E}\\x{2060}-\\x{2064}\\x{2066}-\\x{2069}\\x{FEFF}\\x{00AD}]//g' <file>
EOF
  exit 1
fi

echo "injection-scan: clean — ${#FILES[@]} agent-ingested file(s), no invisible characters"
