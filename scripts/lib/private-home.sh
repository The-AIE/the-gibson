#!/usr/bin/env bash
# private-home.sh — where operator-specific records are written (#530)
#
# Source this; do not execute. Bash 3.2 portable. Quiet on source.
#
# Gibson's public tree holds doctrine and mechanism. Records that describe one
# operator's own deployment (hosts, private repositories, local paths, run
# ledgers) belong in a private checkout instead. Every script that writes such a
# record resolves its destination through gibson_private_home, so a deployment
# redirects all of them with one setting and nothing else changes.
#
# Usage:
#   SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
#   # shellcheck source=lib/private-home.sh
#   . "$SCRIPT_DIR/lib/private-home.sh"
#   HOME_DIR=$(gibson_private_home "$GIBSON_ROOT") || exit 2
#   LEDGER="$HOME_DIR/memory/recipe-runs.md"

# gibson_private_home DEFAULT_ROOT
#   Prints GIBSON_PRIVATE_HOME when set, otherwise DEFAULT_ROOT (unchanged
#   behavior for forks and adopters). A set value must be an absolute path to an
#   existing directory; anything else is an error, never a silent fallback to the
#   public tree.
gibson_private_home() {
  local d="${GIBSON_PRIVATE_HOME:-}"
  if [[ -z "$d" ]]; then
    printf '%s\n' "${1:-.}"
    return 0
  fi
  case "$d" in
    /*) ;;
    *)
      echo "private-home: GIBSON_PRIVATE_HOME must be an absolute path (got: $d)" >&2
      return 2
      ;;
  esac
  if [[ ! -d "$d" ]]; then
    echo "private-home: GIBSON_PRIVATE_HOME is not a directory: $d" >&2
    return 2
  fi
  printf '%s\n' "$d"
}

if ! (return 0 2>/dev/null); then
  echo "private-home.sh: ERROR: nothing to run — this file is a sourceable library, not a command." >&2
  exit 2
fi
