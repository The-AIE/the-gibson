#!/usr/bin/env bash
# fleet-prepush.test.sh — run the fleet lane pre-push layer's own suite as a Gibson sensor.
#
# WHY
#   fleet/ is the tracked home of the per-worktree pre-push layer (FLEET.md "Coder owns the
#   green loop": refuse main/release targets and force-pushes, require a vendor marker on every
#   introduced commit, run the repo's local gate). Until 2026-10-23 it lived only under
#   ~/.claude/fleet on one Mac, so a defect fixed there (the 2026-10-23 locale default, the-gibson#531) could not be reviewed or
#   versioned. Running its suite here keeps the tracked copy green on every PR.
#
# HERMETIC
#   fleet/test/prepush.test.sh builds its own bare origin and lane clones under mktemp, fakes
#   the reviewers, and points every path the layer would otherwise take under ~/.claude/fleet
#   (logs, identities, review output) at that temp dir. No network, no gh, no codex, no claude.
#   Its last line is the exact "<n> passed, <n> failed" tally run-all.sh reads.
#
# USAGE
#   scripts/tests/fleet-prepush.test.sh
set -uo pipefail
GIBSON=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
exec bash "$GIBSON/fleet/test/prepush.test.sh"
