#!/usr/bin/env bash
# Fixture gate. A bad marker fails only while the enforce flag is on.
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
echo "LESSON_PROOF_GATE_SAW_FIXTURE"
if [[ "$marker" != "bad" && "$marker" != "ok" ]]; then
  exit 2
fi
if [[ "$LESSON_PROOF_ENFORCE" == "1" && "$marker" == "bad" ]]; then
  exit 1
fi
exit 0
