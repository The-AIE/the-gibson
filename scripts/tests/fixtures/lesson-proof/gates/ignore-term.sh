#!/usr/bin/env bash
# Ignores SIGTERM and blocks in a child sleep. The checker must SIGKILL this
# process. A SIGTERM-only timeout waits until the sleep finishes.
trap '' TERM
set -euo pipefail
LESSON_PROOF_ENFORCE=1

if [[ "$LESSON_PROOF_ENFORCE" == "1" ]]; then
  sleep 30
fi
exit 0
