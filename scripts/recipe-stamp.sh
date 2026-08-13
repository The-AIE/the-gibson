#!/usr/bin/env bash
# recipe-stamp.sh — append a recipe-run audit line to memory/recipe-runs.md (#34)
set -euo pipefail

usage() {
  cat <<'HELP'
recipe-stamp.sh — stamp a Goose recipe run into the fleet audit ledger

WHAT IT DOES
  Appends one markdown table row to memory/recipe-runs.md with role, recipe
  basename, recipe schema version, playbook-sha256 pin, issue, and UTC time.
  Creates the ledger with a header if missing.

WHY
  Issue #34 / #25: runs must leave a reviewable audit trail so a third party
  can see which recipe version executed against which issue.

HOW
  recipe-stamp.sh --role ROLE --recipe PATH [--issue N] [--repo PATH] [--pr N]
  recipe-stamp.sh --help

  --role     builder | reviewer | security | red-team | string
  --recipe   absolute or repo-relative path to the recipe YAML
  --issue    GitHub issue number (optional but recommended)
  --repo     target worktree path (recorded as basename only)
  --pr       pull request number when reviewing
HELP
}

ROLE=""
RECIPE=""
ISSUE=""
REPO=""
PR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --recipe) RECIPE="${2:-}"; shift 2 ;;
    --issue) ISSUE="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "recipe-stamp.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$ROLE" ]] || { echo "recipe-stamp.sh: --role is required" >&2; exit 2; }
[[ -n "$RECIPE" ]] || { echo "recipe-stamp.sh: --recipe is required" >&2; exit 2; }
[[ -f "$RECIPE" ]] || { echo "recipe-stamp.sh: recipe not found: $RECIPE" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GIBSON_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd)
LEDGER="$GIBSON_ROOT/memory/recipe-runs.md"

if [[ ! -d "$GIBSON_ROOT/memory" ]]; then
  echo "recipe-stamp.sh: memory/ missing under $GIBSON_ROOT" >&2
  exit 1
fi

recipe_base=$(basename "$RECIPE")
schema=$(awk -F'"' '/^version:/{print $2; exit}' "$RECIPE" || true)
if [[ -z "$schema" ]]; then
  schema=$(awk '/^version:/{print $2; exit}' "$RECIPE" | tr -d '"' || true)
fi
[[ -n "$schema" ]] || schema="unknown"

pb_sha=$(awk '/^# playbook-sha256:/{print $3; exit}' "$RECIPE" || true)
[[ -n "$pb_sha" ]] || pb_sha="n/a"

if command -v sha256sum >/dev/null 2>&1; then
  recipe_sha=$(sha256sum "$RECIPE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  recipe_sha=$(shasum -a 256 "$RECIPE" | awk '{print $1}')
else
  recipe_sha="unavailable"
fi

utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
repo_base=""
if [[ -n "$REPO" ]]; then
  repo_base=$(basename "$REPO")
fi

if [[ ! -f "$LEDGER" ]]; then
  cat > "$LEDGER" <<'HDR'
---
title: "Recipe run ledger"
nav_exclude: true
---

# Recipe run ledger (append-only)

Stamped by scripts/recipe-stamp.sh when a Goose recipe session ends (#34 / #25).
Do not put secrets, credentials, private home paths, or PII in this file.

| UTC | role | recipe | schema | playbook-sha256 | recipe-sha256 | issue | pr | repo |
|---|---|---|---|---|---|---|---|---|
HDR
fi

if ! grep -qE '^\| UTC \|' "$LEDGER"; then
  echo "recipe-stamp.sh: ledger missing table header — refuse append" >&2
  exit 1
fi

printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
  "$utc" \
  "$ROLE" \
  "$recipe_base" \
  "$schema" \
  "${pb_sha:0:12}…" \
  "${recipe_sha:0:12}…" \
  "${ISSUE:-—}" \
  "${PR:-—}" \
  "${repo_base:-—}" \
  >> "$LEDGER"

echo "recipe-stamp.sh: stamped $ROLE/$recipe_base → memory/recipe-runs.md"
