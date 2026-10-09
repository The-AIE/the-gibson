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
  local mjs outf errf rc hits=0
  while IFS= read -r mjs; do
    [[ -f "$mjs" ]] || continue
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
  return "$hits"
}
