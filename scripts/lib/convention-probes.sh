#!/usr/bin/env bash
# convention-probes.sh — fast convention probes shared by run-all.sh and prepush.sh (#465)
#
# Sourced, never executed. One definition per probe, so the local pre-push
# check and the gate cannot drift apart. Each function prints findings to
# stdout and returns 0 clean, 1 findings, 2 cannot run (missing tool).

# cp_bash_n FILE... — `bash -n` each file; prints "<file>" then the parser
# message for every file that does not parse.
cp_bash_n() {
  local f err bad=0
  for f in "$@"; do
    err=$(bash -n "$f" 2>&1) || { printf '%s\n%s\n' "$f" "$err"; bad=1; }
  done
  return "$bad"
}

# cp_mjs_unknown_flag — every scripts/*.mjs must exit 2 on an unknown flag
# with "unknown flag:" or "unknown option:" on stderr (#192). Run from the
# repo root. Prints one line per offender.
cp_mjs_unknown_flag() {
  command -v node >/dev/null 2>&1 || return 2
  local mjs outf errf rc hits=0 seen=0
  while IFS= read -r mjs; do
    [[ -f "$mjs" ]] || continue
    seen=$((seen + 1))
    outf=$(mktemp "${TMPDIR:-/tmp}/mjs-flag-out.XXXXXX")
    errf=$(mktemp "${TMPDIR:-/tmp}/mjs-flag-err.XXXXXX")
    node "$mjs" --definitely-not-a-flag >"$outf" 2>"$errf" </dev/null
    rc=$?
    if [[ "$rc" -ne 2 ]] || ! grep -qE 'unknown (flag|option):' "$errf"; then
      printf '%s (rc=%s stderr=%s stdout=%s)\n' "$mjs" "$rc" "$(head -1 "$errf")" "$(head -1 "$outf")"
      hits=1
    fi
    rm -f "$outf" "$errf"
  done < <(find scripts -maxdepth 1 -name '*.mjs' -type f | sort)
  # Probing nothing is not a pass (find missing/failing must not read as green).
  [[ "$seen" -gt 0 ]] || { echo "no scripts/*.mjs found to probe"; return 2; }
  return "$hits"
}

# cp_recipe_hash_drift RECIPE PLAYBOOK — the recipe's "# playbook-sha256:" pin
# must equal the playbook's current sha256. 0 match, 1 drift (prints pin and
# actual), 2 no sha256 tool, 3 recipe has no pin.
cp_recipe_hash_drift() {
  local recipe="$1" playbook="$2" pinned actual
  pinned=$(awk '/^# playbook-sha256:/{print $3; exit}' "$recipe" 2>/dev/null || true)
  [[ -n "$pinned" ]] || { echo "no playbook-sha256 pin"; return 3; }
  if command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$playbook" 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$playbook" 2>/dev/null | awk '{print $1}')
  else
    return 2
  fi
  [[ -n "$actual" ]] || return 2
  [[ "$pinned" == "$actual" ]] && return 0
  printf 'pin=%s... actual=%s...\n' "${pinned:0:12}" "${actual:0:12}"
  return 1
}

# cp_recipe_hash_all — every playbooks/recipes/X.yaml that declares "# playbook: P"
# must have P present and a matching "# playbook-sha256:" pin; recipes with no
# "# playbook:" header (e.g. red-team) are out of scope. A missing playbook or a
# removed pin is reported, never skipped. Prints one line per problem.
cp_recipe_hash_all() {
  local r name pb out rc worst=0
  for r in playbooks/recipes/*.yaml; do
    [[ -f "$r" ]] || continue
    name=$(basename "$r" .yaml)
    pb=$(awk '/^# playbook: /{print $3; exit}' "$r")
    [[ -n "$pb" ]] || continue
    if [[ ! -f "$pb" ]]; then echo "$name: declared playbook $pb is missing"; worst=1; continue; fi
    out=$(cp_recipe_hash_drift "$r" "$pb"); rc=$?
    case "$rc" in
      0) ;;
      2) echo "$name: cannot hash (need shasum or sha256sum)"; [[ "$worst" -lt 2 ]] && worst=2 ;;
      *) echo "$name: $out"; worst=1 ;;
    esac
  done
  return "$worst"
}
