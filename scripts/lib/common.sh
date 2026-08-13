#!/usr/bin/env bash
# common.sh — shared helpers for Gibson shell scripts (#192)
#
# Source this; do not execute. Free of `set -e` / `set -u` — never exits on the
# caller's behalf merely by being sourced. Individual helpers may exit when
# *invoked* (need_cmd fails closed if a required tool is missing); that is
# intentional. A library that exits 0 having done nothing on source is the
# silent-success class silent-noop exists to catch — we stay quiet on source.
#
# Bash 3.2 portable. No mapfile, no associative arrays, no ${var^^}.
#
# Sibling: scripts/delivery-control/lib.sh sources this file. delivery-control
# is not copyable standalone — copy this sibling with it.
#
# Usage:
#   SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
#   # shellcheck source=lib/common.sh
#   . "$SCRIPT_DIR/lib/common.sh"
#   need_cmd jq

# need_cmd NAME — require NAME on PATH or exit 1 with an install hint.
# Message shape matches the former delivery-control/lib.sh helper so callers
# that grepped "missing required command:" keep working.
need_cmd() {
  local c="${1:-}"
  if [[ -z "$c" ]]; then
    echo "common.sh: need_cmd requires a command name" >&2
    return 2
  fi
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "error: missing required command: $c" >&2
    echo "  install '$c' (or put it on PATH) and re-run" >&2
    exit 1
  fi
}

# Direct-invocation guard (same class as silent-noop): this is a library.
if ! (return 0 2>/dev/null); then
  echo "common.sh: ERROR: nothing to run — this file is a sourceable library, not a command." >&2
  echo "common.sh: source it from a script, e.g. . \"\$SCRIPT_DIR/lib/common.sh\"" >&2
  exit 2
fi
