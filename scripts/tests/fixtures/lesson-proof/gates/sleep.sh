#!/usr/bin/env bash
# Fixture gate that does not finish inside the checker timeout.
set -euo pipefail
LESSON_PROOF_ENFORCE=1

if [[ "$LESSON_PROOF_ENFORCE" == "1" ]]; then
  sleep 30
fi
exit 0
