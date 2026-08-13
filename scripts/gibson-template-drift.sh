#!/usr/bin/env bash
# gibson-template-drift.sh — compare an adopter's installed workflows to ci/* templates
#
# WHY
#   Adopters copy ci/*.yml into .github/workflows/. Without a drift check, pins,
#   permissions, and concurrency hardenings rot silently after upstream bumps.
#   This sensor reports which installed files diverge from the shipped templates
#   (and which templates are missing).
#
# USAGE
#   /path/to/the-gibson/scripts/gibson-template-drift.sh
#   /path/to/the-gibson/scripts/gibson-template-drift.sh --gibson /path/to/the-gibson
#   /path/to/the-gibson/scripts/gibson-template-drift.sh --repo /path/to/adopter
#
# EXIT
#   0  no drift (every present pair matches; missing installs are reported as
#      warnings but do not fail — adopters may install a subset)
#   1  content drift detected on at least one installed pair
#   2  usage / environment error
#
# Template stamp: each ci/*.yml starts with
#   # gibson-template-version: sha256:<hash>
# where <hash> is sha256 of the file EXCLUDING that stamp line. Self-contained
# — no git objects needed. Drift = stamp missing or recomputed hash mismatch.
set -euo pipefail

usage() {
  cat <<'HELP'
gibson-template-drift.sh — report drift between ci/* templates and installed workflows

WHAT IT DOES
  For each ci/<name>.yml in the Gibson checkout, looks for a same-named file under
  the adopter repo's .github/workflows/ (then ci/). Verifies the
  # gibson-template-version: sha256:<hash> stamp by recomputing the hash of the
  file excluding that line. Drift = stamp missing or hash mismatch. Also reports
  when an installed copy's content hash differs from the shipped template.

WHY
  SHA pins, permissions: {}, and concurrency blocks rot when adopters copy once
  and never re-sync. A drift report is the sensor that keeps Batch A honest.

USAGE
  gibson-template-drift.sh [--gibson PATH] [--repo PATH] [--strict-missing] [--help]

  --gibson PATH       Gibson source tree (default: parent of scripts/)
  --repo PATH         Adopter checkout (default: cwd)
  --strict-missing    Fail (exit 1) when a template has no installed counterpart
  --help              This help

EXIT
  0 match / only missing installs (unless --strict-missing)
  1 content drift (or missing, with --strict-missing)
  2 usage error
HELP
}

GIBSON=""
REPO=""
STRICT_MISSING=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --gibson|--repo)
      flag=$1
      if [[ $# -lt 2 ]]; then
        echo "gibson-template-drift: $flag requires a path" >&2
        usage >&2
        exit 2
      fi
      if [[ "$flag" == --gibson ]]; then
        GIBSON=$2
      else
        REPO=$2
      fi
      shift 2
      ;;
    --strict-missing) STRICT_MISSING=1; shift ;;
    *) echo "gibson-template-drift: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -z "$GIBSON" ]]; then
  GIBSON=$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd)
fi
if [[ -z "$REPO" ]]; then
  REPO=$(pwd)
fi

die() { echo "gibson-template-drift: ERROR: $*" >&2; exit 2; }
info() { echo "gibson-template-drift: $*" >&2; }

[[ -d "$GIBSON/ci" ]] || die "no ci/ under Gibson tree: $GIBSON"
[[ -d "$REPO" ]] || die "repo path not a directory: $REPO"

# Hash of file content excluding the stamp line. Portable: sha256sum / shasum / openssl.
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

content_sha256() {
  # An empty or stamp-only file is valid input to the hasher. grep -v returns
  # 1 when it selects no lines; tolerate that no-content case so the caller
  # emits a named DRIFT diagnostic and final summary instead of dying silently.
  { grep -v '^# gibson-template-version:' "$1" || true; } | sha256_stdin
}

read_stamp() {
  # Deliberate tolerance: grep exits 1 on no-match. That empty result feeds
  # the explicit "stamp missing" branches below — this is the diagnostic path,
  # not gate plumbing.
  grep -E '^# gibson-template-version:' "$1" 2>/dev/null | head -n1 | awk '{print $3}' || true
}

# Normalize for a human diff: drop the stamp line and trailing whitespace.
normalize() {
  grep -v '^# gibson-template-version:' "$1" | sed -e 's/[[:space:]]*$//'
}

DRIFT=0
MISSING=0
MATCHED=0
CHECKED=0

shopt -s nullglob
templates=("$GIBSON"/ci/*.yml)
shopt -u nullglob
[[ ${#templates[@]} -gt 0 ]] || die "no ci/*.yml templates in $GIBSON"

for tmpl in "${templates[@]}"; do
  base=$(basename "$tmpl")
  candidates=(
    "$REPO/.github/workflows/$base"
    "$REPO/ci/$base"
  )
  found=""
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      found="$c"
      break
    fi
  done

  CHECKED=$((CHECKED + 1))
  tmpl_hash=$(content_sha256 "$tmpl")
  tmpl_stamp=$(read_stamp "$tmpl")
  tmpl_expected="sha256:${tmpl_hash}"
  ver=${tmpl_stamp:-unknown}

  if [[ -z "$tmpl_stamp" ]]; then
    DRIFT=$((DRIFT + 1))
    info "DRIFT  $base  template stamp missing"
    found=""
  elif [[ "$tmpl_stamp" != "$tmpl_expected" ]]; then
    DRIFT=$((DRIFT + 1))
    info "DRIFT  $base  template stamp mismatch (stamp=$tmpl_stamp computed=$tmpl_expected)"
    found=""
  fi

  if [[ -z "$found" ]]; then
    if [[ -n "$tmpl_stamp" && "$tmpl_stamp" == "$tmpl_expected" ]]; then
      MISSING=$((MISSING + 1))
      info "MISSING install for template $base (template-version=$ver)"
    fi
    continue
  fi

  inst_hash=$(content_sha256 "$found")
  inst_stamp=$(read_stamp "$found")
  inst_expected="sha256:${inst_hash}"

  if [[ -z "$inst_stamp" ]]; then
    DRIFT=$((DRIFT + 1))
    info "DRIFT  $base  installed stamp missing (installed=${found#"$REPO"/})"
    continue
  fi
  if [[ "$inst_stamp" != "$inst_expected" ]]; then
    DRIFT=$((DRIFT + 1))
    info "DRIFT  $base  installed stamp mismatch (stamp=$inst_stamp computed=$inst_expected)"
    continue
  fi
  if [[ "$inst_hash" != "$tmpl_hash" ]]; then
    DRIFT=$((DRIFT + 1))
    info "DRIFT  $base  installed=${found#"$REPO"/}  content hash mismatch template-version=$ver"
    diff -u <(normalize "$tmpl") <(normalize "$found") | head -n 40 >&2 || true
    continue
  fi

  MATCHED=$((MATCHED + 1))
  info "OK  $base  (installed at ${found#"$REPO"/}, template-version=$ver)"
done

echo
echo "gibson-template-drift: checked=$CHECKED matched=$MATCHED missing=$MISSING drift=$DRIFT"

if [[ "$DRIFT" -gt 0 ]]; then
  exit 1
fi
if [[ "$STRICT_MISSING" -eq 1 && "$MISSING" -gt 0 ]]; then
  exit 1
fi
exit 0
