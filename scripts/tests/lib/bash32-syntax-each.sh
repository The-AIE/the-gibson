#!/usr/bin/env bash
# bash32-syntax-each.sh — parse each file once with an explicit shell (#300).
# Usage: bash32-syntax-each.sh <shell> <file> [file ...]
# Exit: 0 all parsed, 1 parser failure, 2 invalid usage/environment.
# Never executes checked files. Continues after parser failures.
set -u

if [ "$#" -lt 2 ]; then
  printf '%s\n' "bash32-syntax-each: usage: bash32-syntax-each.sh <shell> <file> [file ...]" >&2
  exit 2
fi

shell=$1
shift

if [ -z "$shell" ]; then
  printf '%s\n' "bash32-syntax-each: parser executable is empty" >&2
  exit 2
fi

parser=""
if [ -f "$shell" ] && [ -x "$shell" ]; then
  parser=$shell
else
  resolved=$(command -v "$shell" 2>/dev/null || true)
  if [ -n "$resolved" ] && [ -f "$resolved" ] && [ -x "$resolved" ]; then
    parser=$resolved
  fi
fi
if [ -z "$parser" ]; then
  printf '%s\n' "bash32-syntax-each: parser not executable: $shell" >&2
  exit 2
fi

for f in "$@"; do
  if [ ! -f "$f" ]; then
    printf '%s\n' "bash32-syntax-each: not a regular file: $f" >&2
    exit 2
  fi
done

# per-file parse (one -n invocation per path)
status=0
for f in "$@"; do
  err=$("$parser" -n "$f" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "bash32-syntax-each: $f" >&2
    if [ -n "$err" ]; then
      printf '%s\n' "$err" >&2
    fi
    status=1
  fi
done
exit "$status"
# end per-file parse
