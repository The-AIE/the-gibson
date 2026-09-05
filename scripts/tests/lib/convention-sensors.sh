#!/usr/bin/env bash
# convention-sensors.sh — sourceable convention sensors for #192 remediations.
#
# Source this; do not execute. Each public cs_* function prints hit lines
# (file:line: text) to stdout and returns:
#   0  clean
#   1  violation(s) found
#   2  sensor plumbing failed (fail closed)
#
# Mutation tests in convention-sensors.test.sh call these same functions.
#
# THREAT MODEL: these sensors are drift-ratchets that catch ACCIDENTAL
# convention violations in ordinary code. They are grep-based, not parsers,
# and are NOT a security boundary — Gibson's anti-gaming boundary is the
# gate architecture (ci/gibson-gate.yml), not this lint.
#
# Closed accepted-evasions list (reviewed 2026-08-12, #192 round 6).
# Forms the sensors DO match (plausible accidental drift — keep matching):
#   - JS: static/side-effect/dynamic/re-export relative specifiers, including
#     multiline, template-literal, and comment-injected `from`/`import(`
#   - bash-4 tokens in code or double-quoted expansions
#   - non-canonical SCRIPT_DIR assignments (export/local/declare peeled)
#   - info()/warn() bodies with an unredirected echo/printf
#   - tool invocations in command position, including:
#       tool / |;&&$( tool
#       command tool, command -p tool, command -- tool, command -p -- tool
#       env tool, env NAME=… tool (empty, bare, or quoted values)
#       env -i/-0/--/-u NAME/--unset=NAME plus optional NAME=… then tool
#       prefix assignment NAME=… tool (PATH=… gh, FOO=1 jq)
# Forms that remain accepted evasions (grep cannot close these without
# false-reds or becoming a parser). Do not extend the regexes for these:
#   - quoted-string decoys: `echo "need_cmd jq"` / `echo "... >&2"`
#   - pseudo-heredoc confusion: `echo "<<EOF"` starts heredoc-skip mode
#   - quoted command names: `"mapfile" -t rows`
#   - exec / eval / variable invocation: `exec jq`, `$TOOL`, `"$cmd" jq`
#   - JS import built from an expression: `import(base + "./z")`
#   - JS string-literal decoys: `const s = "import \"./z.mjs\""`
#   - no-op guard definition: `need_cmd() { :; }` then `need_cmd jq` — the
#     sensor matches the call text, not whether the helper actually checks
#   - string-unaware /* */ stripping: a `/*` inside a JS string opens a fake
#     block comment that hides a later real relative import from the matcher
# The list is closed. New findings are accepted-by-default unless they are
# plausible accidental drift — file an issue rather than blocking a batch.
# A deliberate evader defeats any grep sensor. If the threat model changes,
# replace the sensor with a real parser.

# ---------------------------------------------------------------------------
# Vendored mjs self-containment (Fix 1)
# ---------------------------------------------------------------------------

# Paths of scripts/*.mjs named in gibson-gate.yml sparse-checkout and/or
# ci/README.md vendor instructions. Prints one repo-relative path per line.
cs_list_vendored_mjs() {
  local root="${1:-.}"
  local yml="$root/ci/gibson-gate.yml"
  local readme="$root/ci/README.md"
  if [[ ! -f "$yml" ]]; then
    echo "convention-sensors: missing $yml" >&2
    return 2
  fi
  if [[ ! -f "$readme" ]]; then
    echo "convention-sensors: missing $readme" >&2
    return 2
  fi
  local listed
  listed=$(
    {
      awk '
        $0 ~ /sparse-checkout:[[:space:]]*\|?[[:space:]]*$/ { in_sc=1; next }
        in_sc && $0 ~ /^[[:space:]]+[^#[:space:]]/ {
          line=$0
          sub(/^[[:space:]]+/, "", line)
          if (line ~ /^scripts\/[A-Za-z0-9._-]+\.mjs$/) print line
          next
        }
        in_sc && $0 ~ /^[^[:space:]]/ { in_sc=0 }
      ' "$yml" || exit 2
      # Vendor instructions name scripts/<file>.mjs and/or bare `file.mjs`
      # in the adopter vendor list (ci/README.md uses both).
      grep -oE 'scripts/[A-Za-z0-9._-]+\.mjs' "$readme" || true
      # Bare vendor-list filenames (`route-inventory.mjs`) map to
      # scripts/<name>.mjs. Only backtick-quoted basenames — not prose
      # examples like "copy foo.mjs into scripts/" and not path-qualified
      # `dir/foo.mjs`.
      grep -oE '`[A-Za-z0-9._-]+\.mjs`' "$readme" \
        | tr -d '`' | sed 's|^|scripts/|' || true
    } | sort -u
  ) || return 2
  if [[ -z "$listed" ]]; then
    echo "convention-sensors: no scripts/*.mjs named in sparse-checkout or ci/README.md" >&2
    return 2
  fi
  printf '%s\n' "$listed"
}

# Relative import hits in one file. rc 1 = hits, 0 = clean, 2 = plumbing.
# Before matching: strip /* ... */ (including multiline) globally, then strip
# // -to-EOL comments only when preceded by start-of-line or ASCII whitespace
# (so http:// inside a string is left alone). Then collapse whitespace so
# multiline `import { x }\n  from "./z"` and `import(\n  "./z"\n)` are
# visible, including comment-injected forms (`from /* dep */ "./z"`,
# `import(/* webpackChunkName */ "./z")`).
# Matches are mapped back to the original line of the import/from keyword.
# Output: file:line: <original-source line text>  (orig text, not stripped)
# Quote class is ' " and ` (template-literal import(`./z`)).
# Catches every relative specifier starting ./ or ../ :
#   from "./x" / from "../x"          (static import and export ... from)
#   import "./x" / import "../x"      (side-effect import, no from clause)
#   import("./x") / import(`./z`)     (dynamic import, string or template)
#
# Byte-safe on macOS nawk: LC_ALL=C + ASCII-only whitespace tests. A UTF-8
# locale plus `c ~ /[[:space:]]/` on one byte of U+FFFD/em-dash calls towc
# and fails closed (plumbing rc 2) on shipped files such as
# check-active-work.mjs. Diagnostics still print the original line.
cs_mjs_relative_import_hits() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "convention-sensors: missing $f" >&2
    return 2
  fi
  local hits rc
  hits=$(LC_ALL=C LC_CTYPE=C awk -v file="$f" '
    {
      orig[NR] = $0
      src = src $0 "\n"
    }
    function is_ascii_ws(c) {
      return c == " " || c == "\t" || c == "\r" || c == "\f" || c == "\v"
    }
    function strip_block(s,    out, i, n, c, in_block) {
      n = length(s)
      out = ""
      in_block = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (in_block) {
          if (c == "*" && substr(s, i + 1, 1) == "/") {
            out = out "  "
            i++
            in_block = 0
          } else if (c == "\n") {
            out = out "\n"
          } else {
            out = out " "
          }
        } else if (c == "/" && substr(s, i + 1, 1) == "*") {
          out = out "  "
          i++
          in_block = 1
        } else {
          out = out c
        }
      }
      return out
    }
    function strip_line(s,    out, i, n, c, prev, in_line) {
      n = length(s)
      out = ""
      in_line = 0
      prev = "\n"
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (in_line) {
          if (c == "\n") {
            out = out "\n"
            in_line = 0
            prev = "\n"
          }
          continue
        }
        if (c == "/" && substr(s, i + 1, 1) == "/" && (prev == "\n" || is_ascii_ws(prev))) {
          in_line = 1
          i++
          continue
        }
        out = out c
        prev = c
      }
      return out
    }
    END {
      stripped = strip_line(strip_block(src))
      collapsed = ""
      pos = 0
      ln = 1
      last_was_space = 1
      n = length(stripped)
      for (i = 1; i <= n; i++) {
        c = substr(stripped, i, 1)
        if (c == "\n") {
          ln++
          if (!last_was_space) {
            pos++
            collapsed = collapsed " "
            cline[pos] = ln - 1
            last_was_space = 1
          }
          continue
        }
        if (is_ascii_ws(c)) {
          if (!last_was_space) {
            pos++
            collapsed = collapsed " "
            cline[pos] = ln
            last_was_space = 1
          }
        } else {
          pos++
          collapsed = collapsed c
          cline[pos] = ln
          last_was_space = 0
        }
      }
      sq = sprintf("%c", 39)
      dq = sprintf("%c", 34)
      bt = sprintf("%c", 96)
      pat = "(from[[:space:]]+|import[[:space:]]*\\(?[[:space:]]*)[" sq dq bt "]\\.\\.?/"
      search = collapsed
      base = 0
      while (match(search, pat)) {
        abs = base + RSTART
        kw_line = cline[abs]
        key = kw_line
        if (kw_line > 0 && !(key in seen)) {
          seen[key] = 1
          print file ":" kw_line ": " orig[kw_line]
        }
        base = abs + RLENGTH
        search = substr(collapsed, base + 1)
      }
    }
  ' "$f")
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "convention-sensors: normalize failed on $f" >&2
    return 2
  fi
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    return 1
  fi
  return 0
}

# Every vendored-listed scripts/*.mjs must contain no relative import
# (./ or ../ — static, side-effect, dynamic, or re-export).
# ROOT is the repo root (ci/ and scripts/ live there).
cs_vendored_selfcontained() {
  local root="${1:-.}"
  local listed rc f hits all=""
  listed=$(cs_list_vendored_mjs "$root") || return 2
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -f "$root/$f" ]]; then
      echo "convention-sensors: vendored-listed $f missing under $root" >&2
      return 2
    fi
    hits=$(cs_mjs_relative_import_hits "$root/$f")
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      return 2
    fi
    if [[ "$rc" -eq 1 ]]; then
      all="${all}${hits}"$'\n'
    fi
  done <<< "$listed"
  if [[ -n "$all" ]]; then
    printf '%s' "$all"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Shared line walkers
# ---------------------------------------------------------------------------

# Comment-strip for bash-4. mode=keepdq keeps double-quoted spans (so
# echo "${name^^}" is still visible). mode=stripdq also drops double quotes
# (so a status string mentioning mapfile is not itself a hit).
# Prints "<orig_nr>:<stripped>".
_cs_bash4_strip() {
  local f="$1"
  local mode="${2:-keepdq}"
  awk -v mode="$mode" '
    BEGIN { heredoc = "" }
    {
      raw = $0
      if (heredoc != "") {
        t = raw
        sub(/^[\t]+/, "", t)
        if (raw == heredoc || t == heredoc) heredoc = ""
        next
      }
      if (raw ~ /^[[:space:]]*#/) next
      if (index(raw, "<<") > 0 && match(raw, /<<-?[[:space:]]*['\''"]?[A-Za-z_][A-Za-z0-9_]*/)) {
        tok = substr(raw, RSTART, RLENGTH)
        sub(/<<-?[[:space:]]*/, "", tok)
        gsub(/['\''"]/, "", tok)
        heredoc = tok
      }
      line = raw
      out = ""
      in_s = 0
      in_d = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (!in_s && !in_d && c == "#") break
        if (c == "'\''" && !in_d) { in_s = !in_s; continue }
        if (c == "\"" && !in_s) {
          in_d = !in_d
          if (mode == "keepdq") out = out c
          continue
        }
        if (!in_s && (mode == "keepdq" || !in_d)) out = out c
      }
      print NR ":" out
    }
  ' "$f"
}

# Comment-strip + heredoc skip for tool-guard. Keeps quotes (command-position
# scan). Prints "<orig_nr>:<stripped>".
_cs_tool_strip() {
  local f="$1"
  awk '
    BEGIN { heredoc = "" }
    {
      raw = $0
      if (heredoc != "") {
        t = raw
        sub(/^[\t]+/, "", t)
        if (raw == heredoc || t == heredoc) heredoc = ""
        next
      }
      if (raw ~ /^[[:space:]]*#/) next
      if (index(raw, "<<") > 0 && match(raw, /<<-?[[:space:]]*['\''"]?[A-Za-z_][A-Za-z0-9_]*/)) {
        tok = substr(raw, RSTART, RLENGTH)
        sub(/<<-?[[:space:]]*/, "", tok)
        gsub(/['\''"]/, "", tok)
        heredoc = tok
      }
      line = raw
      out = ""
      in_s = 0
      in_d = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (!in_s && !in_d && c == "#") break
        if (c == "'\''" && !in_d) { in_s = !in_s; out = out c; continue }
        if (c == "\"" && !in_s) { in_d = !in_d; out = out c; continue }
        out = out c
      }
      print NR ":" out
    }
  ' "$f"
}

# ---------------------------------------------------------------------------
# bash-4 builtins (Fix 3a)
# ---------------------------------------------------------------------------

cs_bash4_hits() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "convention-sensors: missing $f" >&2
    return 2
  fi
  local tmp tmpq rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/cs-bash4.XXXXXX") || return 2
  tmpq=$(mktemp "${TMPDIR:-/tmp}/cs-bash4q.XXXXXX") || { rm -f "$tmp"; return 2; }
  if ! _cs_bash4_strip "$f" keepdq > "$tmp"; then
    rm -f "$tmp" "$tmpq"
    echo "convention-sensors: bash-4 strip failed on $f" >&2
    return 2
  fi
  if ! _cs_bash4_strip "$f" stripdq > "$tmpq"; then
    rm -f "$tmp" "$tmpq"
    echo "convention-sensors: bash-4 stripdq failed on $f" >&2
    return 2
  fi
  local hits="" pat match line nr orig src
  # Word tokens: scan quote-stripped lines so a status string is not a hit.
  # Parameter expansions: scan with double quotes kept so echo "${name^^}" hits.
  for pat in \
    'word:(^|[^A-Za-z0-9_])mapfile([^A-Za-z0-9_]|$)' \
    'word:(^|[^A-Za-z0-9_])readarray([^A-Za-z0-9_]|$)' \
    'word:declare[[:space:]]+-A' \
    'word:&>>' \
    'dq:\$\{[A-Za-z_][A-Za-z0-9_]*\^\^' \
    'dq:\$\{[A-Za-z_][A-Za-z0-9_]*,,'
  do
    src=$tmpq
    case "$pat" in
      dq:*) src=$tmp; pat=${pat#dq:} ;;
      word:*) pat=${pat#word:} ;;
    esac
    match=$(grep -E "$pat" "$src")
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      rm -f "$tmp" "$tmpq"
      echo "convention-sensors: grep -E failed ($pat) on $f" >&2
      return 2
    fi
    if [[ "$rc" -eq 0 ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        nr=${line%%:*}
        orig=$(sed -n "${nr}p" "$f")
        hits="${hits}${f}:${nr}: ${orig}"$'\n'
      done <<< "$match"
    fi
  done
  rm -f "$tmp" "$tmpq"
  if [[ -n "$hits" ]]; then
    printf '%s' "$hits" | awk 'NF && !seen[$0]++'
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# SCRIPT_DIR convention (Fix 3b)
# ---------------------------------------------------------------------------

SCRIPT_DIR_CANON=$(cat <<'CANON'
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CANON
)

# Peel export/readonly/local/declare (+ short flags) so we see SCRIPT_DIR=...
_cs_peel_assign_prefixes() {
  local t="$1"
  local prev=""
  while [[ "$t" != "$prev" ]]; do
    prev=$t
    case "$t" in
      export[[:space:]]*) t="${t#export}" ;;
      readonly[[:space:]]*) t="${t#readonly}" ;;
      local[[:space:]]*) t="${t#local}" ;;
      declare[[:space:]]*) t="${t#declare}" ;;
      -*[[:space:]]*) t="${t#*[[:space:]]}" ;;
      *) break ;;
    esac
    t="${t#"${t%%[![:space:]]*}"}"
  done
  printf '%s' "$t"
}

cs_script_dir_hits() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "convention-sensors: missing $f" >&2
    return 2
  fi
  local ln=0 prev="" line trimmed code peeled hits=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    ln=$((ln + 1))
    trimmed=${line#"${line%%[![:space:]]*}"}
    if [[ -z "$trimmed" ]]; then
      continue
    fi
    case "$trimmed" in
      \#*)
        prev=$trimmed
        continue
        ;;
    esac
    case "$trimmed" in
      *SCRIPT_DIR=*) ;;
      *)
        prev=$trimmed
        continue
        ;;
    esac
    peeled=$(_cs_peel_assign_prefixes "$trimmed")
    case "$peeled" in
      SCRIPT_DIR=\$*|SCRIPT_DIR=\"\$*) ;;
      *)
        prev=$trimmed
        continue
        ;;
    esac
    case "$prev" in
      \#*SCRIPT_DIR-exempt*)
        prev=$trimmed
        continue
        ;;
    esac
    code=${peeled%%#*}
    code=$(printf '%s' "$code" | sed 's/[[:space:]]*$//')
    if [[ "$code" != "$SCRIPT_DIR_CANON" ]]; then
      hits="${hits}${f}:${ln}: ${trimmed}"$'\n'
    fi
    prev=$trimmed
  done < "$f"
  if [[ -n "$hits" ]]; then
    printf '%s' "$hits"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# info()/warn() stderr (Fix 3c)
# ---------------------------------------------------------------------------

cs_info_warn_hits() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "convention-sensors: missing $f" >&2
    return 2
  fi
  local hits
  hits=$(
    awk '
      function is_def(line) {
        return line ~ /^[[:space:]]*function[[:space:]]+(info|warn)([[:space:]]|\(|\{)/ \
            || line ~ /^[[:space:]]*(info|warn)[[:space:]]*\(\)/
      }
      function brace_delta(s,    i, c, in_s, in_d, d) {
        d = 0; in_s = 0; in_d = 0
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c == "'\''" && !in_d) in_s = !in_s
          else if (c == "\"" && !in_s) in_d = !in_d
          else if (!in_s && !in_d) {
            if (c == "{") d++
            else if (c == "}") d--
          }
        }
        return d
      }
      function check_fn(text, start,    body, rest, n, i, stmt, ok) {
        if (text ~ /\}[[:space:]]*>(\&2|\/dev\/stderr)/) return
        body = text
        sub(/^[^{]*\{/, "", body)
        sub(/\}[^}]*$/, "", body)
        n = split(body, stmts, /[;\n]/)
        ok = 1
        for (i = 1; i <= n; i++) {
          stmt = stmts[i]
          sub(/^[[:space:]]+/, "", stmt)
          if (stmt ~ /^(echo|printf)([[:space:]]|$)/) {
            if (stmt !~ />(\&2|\/dev\/stderr)/ && stmt !~ /1>&2/) ok = 0
          }
        }
        if (!ok) print start ":" defline
      }
      BEGIN { in_fn = 0; depth = 0; start = 0; body = ""; defline = "" }
      {
        line = $0
        if (!in_fn) {
          if (is_def(line)) {
            in_fn = 1
            start = NR
            defline = line
            body = line
            depth = brace_delta(line)
            if (depth <= 0 && line ~ /\{/) {
              check_fn(body, start)
              in_fn = 0
            }
          }
          next
        }
        body = body "\n" line
        depth += brace_delta(line)
        if (depth <= 0) {
          check_fn(body, start)
          in_fn = 0
        }
      }
    ' "$f"
  ) || {
    echo "convention-sensors: info/warn awk failed on $f" >&2
    return 2
  }
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" | while IFS= read -r line; do
      [[ -n "$line" ]] && printf '%s:%s\n' "$f" "$line"
    done
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# tool guards (Fix 3d)
# ---------------------------------------------------------------------------

# True when $1 lives under scripts/delivery-control/ (repo-relative or
# absolute). A path that merely contains a delivery-control directory
# (/tmp/delivery-control/foo.sh) does not count.
_cs_file_in_delivery_control() {
  case "$1" in
    scripts/delivery-control/*|*/scripts/delivery-control/*) return 0 ;;
  esac
  return 1
}

# Peel `. PATH` / `source PATH` to the first argument (quotes stripped).
_cs_peel_source_target() {
  local t="$1"
  t=${t#"${t%%[![:space:]]*}"}
  case "$t" in
    source[[:space:]]*) t=${t#source} ;;
    .[[:space:]]*) t=${t#.} ;;
    *) printf ''; return ;;
  esac
  t=${t#"${t%%[![:space:]]*}"}
  case "$t" in
    \"*) t=${t#\"}; t=${t%%\"*} ;;
    \'*) t=${t#\'}; t=${t%%\'*} ;;
    *) t=${t%%[[:space:]]*} ;;
  esac
  printf '%s' "$t"
}

# True when the source target is exactly scripts/delivery-control/lib.sh
# relative to the repo root. Suffix matches (/tmp/delivery-control/lib.sh,
# ./fake/delivery-control/lib.sh) do not grant. In-tree form
# ${SCRIPT_DIR}/lib.sh (and lib.sh / ./lib.sh) grants only from a file
# under scripts/delivery-control/. scripts/lib/common.sh does not grant.
_cs_target_grants_lib_sh() {
  local target="$1"
  local in_dc="$2"
  case "$target" in
    scripts/delivery-control/lib.sh|./scripts/delivery-control/lib.sh)
      return 0
      ;;
  esac
  if [[ "$in_dc" -eq 1 ]]; then
    case "$target" in
      lib.sh|./lib.sh|\$\{SCRIPT_DIR\}/lib.sh|\$SCRIPT_DIR/lib.sh)
        return 0
        ;;
    esac
  fi
  return 1
}

# Print granting source lines (nr:stripped) from already-stripped input.
# rc 0 = one or more grants, 1 = none, 2 = grep plumbing failed.
_cs_granting_lib_source_hits() {
  local f="$1"
  local stripped="$2"
  local in_dc=0 line target src_lines rc
  if _cs_file_in_delivery_control "$f"; then
    in_dc=1
  fi
  src_lines=$(printf '%s\n' "$stripped" | grep -E '^[0-9]+:[[:space:]]*(\.|source)[[:space:]]+')
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    echo "convention-sensors: sources-lib.sh grep failed on $f" >&2
    return 2
  fi
  [[ "$rc" -eq 0 ]] || return 1
  local any=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    target=$(_cs_peel_source_target "${line#*:}")
    [[ -n "$target" ]] || continue
    if _cs_target_grants_lib_sh "$target" "$in_dc"; then
      printf '%s\n' "$line"
      any=1
    fi
  done <<< "$src_lines"
  [[ "$any" -eq 1 ]]
}

# True when the file sources scripts/delivery-control/lib.sh from its real
# location (source-time need_cmd gh/jq/git). scripts/lib/common.sh does NOT
# count — it only defines need_cmd. ./fake-lib.sh does not count.
cs_file_sources_lib_sh() {
  local f="$1"
  local stripped
  stripped=$(_cs_tool_strip "$f") || return 2
  _cs_granting_lib_source_hits "$f" "$stripped" >/dev/null
}

cs_tool_guard_hits() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "convention-sensors: missing $f" >&2
    return 2
  fi
  case "$f" in
    scripts/tests/*|scripts/lib/*|*/scripts/tests/*|*/scripts/lib/*) return 0 ;;
  esac
  local stripped rc
  stripped=$(_cs_tool_strip "$f") || return 2
  local sources_lib=0 source_line=""
  local src_hits
  src_hits=$(_cs_granting_lib_source_hits "$f" "$stripped")
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    echo "convention-sensors: tool-guard source grep failed on $f" >&2
    return 2
  fi
  if [[ "$rc" -eq 0 ]]; then
    sources_lib=1
    # first matching line number
    source_line=$(printf '%s\n' "$src_hits" | head -1)
    source_line=${source_line%%:*}
  fi

  local tool hits="" first_inv first_guard match line nr
  # NAME=value token: NAME=, NAME=val, NAME="quoted", NAME='quoted'
  local assign='[A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|'\''[^'\'']*'\''|[^[:space:]]*)'
  # env tokens that may precede the command (flags then optional assignments).
  # Longer --flags first so `--` does not steal `--unset=` / `--ignore-environment`.
  local env_tok="(--ignore-environment|--unset=[A-Za-z_][A-Za-z0-9_]*|--null|--|-i|-0|-u[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|${assign})"
  # command invocation flags only. -v / -V / -pv stay guards, not invocations.
  local cmd_flags='(-p[[:space:]]+|--[[:space:]]+)*'
  for tool in jq gh node python3; do
    first_inv=""
    first_guard=""
    # Command-position: start of line, or after | ; && $(
    # Also: `command TOOL` with any number of -p / -- ;
    # `env TOOL` with POSIX env flags (-i -0 -u NAME --unset= --) and
    # NAME= assignments; prefix assignment `NAME=… TOOL` (PATH=… gh).
    # `command -v TOOL` is the guard idiom — do not treat it as invocation.
    # Do NOT treat a bare "(" as command-position — "(gh query failed)" is prose.
    match=$(printf '%s\n' "$stripped" | sed 's/--jq//g' | grep -E \
      "^[0-9]+:[[:space:]]*${tool}([[:space:]]|$)|[|;][[:space:]]*${tool}([[:space:]]|$)|&&[[:space:]]*${tool}([[:space:]]|$)|[$][(][[:space:]]*${tool}([[:space:]]|$)|(^|[^A-Za-z0-9_])command[[:space:]]+${cmd_flags}${tool}([[:space:]]|$)|(^|[^A-Za-z0-9_])env[[:space:]]+(${env_tok}[[:space:]]+)*${tool}([[:space:]]|$)|^[0-9]+:[[:space:]]*(${assign}[[:space:]]+)+${tool}([[:space:]]|$)|[|;][[:space:]]*(${assign}[[:space:]]+)+${tool}([[:space:]]|$)|&&[[:space:]]*(${assign}[[:space:]]+)+${tool}([[:space:]]|$)|[$][(][[:space:]]*(${assign}[[:space:]]+)+${tool}([[:space:]]|$)")
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "convention-sensors: tool-guard inv grep failed ($tool) on $f" >&2
      return 2
    fi
    if [[ "$rc" -eq 0 ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$tool" == "gh" ]] && printf '%s\n' "$line" | grep 'GH_BIN=' >/dev/null; then
          continue
        fi
        nr=${line%%:*}
        if [[ -z "$first_inv" || "$nr" -lt "$first_inv" ]]; then
          first_inv=$nr
        fi
      done <<< "$match"
    fi
    [[ -z "$first_inv" ]] && continue

    case "$tool" in
      python3)
        match=$(printf '%s\n' "$stripped" | grep -E 'need_cmd[[:space:]]+python3|command[[:space:]]+-v[[:space:]]+python3|require_python3')
        ;;
      gh)
        match=$(printf '%s\n' "$stripped" | grep -E 'need_cmd[[:space:]]+gh|command[[:space:]]+-v[[:space:]]+gh|command[[:space:]]+-v[[:space:]]+"\$GH_BIN"|command[[:space:]]+-v[[:space:]]+\$GH_BIN')
        ;;
      *)
        match=$(printf '%s\n' "$stripped" | grep -E "need_cmd[[:space:]]+${tool}|command[[:space:]]+-v[[:space:]]+${tool}")
        ;;
    esac
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "convention-sensors: tool-guard guard grep failed ($tool) on $f" >&2
      return 2
    fi
    if [[ "$rc" -eq 0 ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        nr=${line%%:*}
        if [[ -z "$first_guard" || "$nr" -lt "$first_guard" ]]; then
          first_guard=$nr
        fi
      done <<< "$match"
    fi
    if [[ "$sources_lib" -eq 1 && ( "$tool" == "gh" || "$tool" == "jq" ) ]]; then
      if [[ -z "$first_guard" || "$source_line" -lt "$first_guard" ]]; then
        first_guard=$source_line
      fi
    fi
    if [[ -n "$first_guard" && "$first_guard" -lt "$first_inv" ]]; then
      continue
    fi
    # Report the first unguarded invocation line (original text).
    orig=$(sed -n "${first_inv}p" "$f")
    hits="${hits}${f}  ${tool}  ${first_inv}: ${orig}"$'\n'
  done
  if [[ -n "$hits" ]]; then
    printf '%s' "$hits"
    return 1
  fi
  return 0
}

# Direct-invocation guard: this is a library.
if ! (return 0 2>/dev/null); then
  echo "convention-sensors.sh: source this file; do not execute it." >&2
  exit 2
fi
