#!/usr/bin/env bash
# Fixture gate. Every marker fails, including the valid directory.
set -euo pipefail
LESSON_PROOF_ENFORCE=1

fixture=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture)
      if [[ $# -lt 2 ]]; then
        exit 2
      fi
      fixture=$2
      shift 2
      ;;
    *)
      exit 2
      ;;
  esac
done

if [[ -z "$fixture" || ! -f "$fixture/marker" ]]; then
  exit 2
fi
marker=$(tr -d '[:space:]' < "$fixture/marker")
printf '%s\n' "$LESSON_PROOF_ENFORCE" >/dev/null
echo "LESSON_PROOF_GATE_SAW_FIXTURE"
if [[ "$marker" != "bad" && "$marker" != "ok" ]]; then
  exit 2
fi
exit 1
