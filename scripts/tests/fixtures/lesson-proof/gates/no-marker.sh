#!/usr/bin/env bash
# Fixture gate with no enforce assignment. Bad fails, valid passes.
set -euo pipefail

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
if [[ "$marker" == "bad" ]]; then
  exit 1
fi
if [[ "$marker" == "ok" ]]; then
  exit 0
fi
exit 2
