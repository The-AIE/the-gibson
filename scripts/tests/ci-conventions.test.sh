#!/usr/bin/env bash
# ci-conventions.test.sh — sensors for CI template hardening (issue #191)
#
# WHY
#   Batch A pins actions, least-privilege permissions, concurrency, and visible
#   skips. Without a ratchet, the next template edit reintroduces floating tags
#   or silent continue-on-error. These checks enforce the contract over
#   ci/**/*.yml and .github/workflows/*.yml (and operator-literal scrub on
#   templates/). Every check is a function of a directory so planted fixtures
#   can prove the sensor actually fires (mutation coverage).
#
# USAGE
#   scripts/tests/ci-conventions.test.sh
#
# THREAT MODEL: these sensors are drift-ratchets that catch ACCIDENTAL
# convention violations in ordinary block-style GitHub Actions workflows.
# They are grep-based, not a YAML parser, and are NOT a security boundary —
# Gibson's anti-gaming boundary is the gate architecture (ci/gibson-gate.yml),
# not this lint.
# Flow-style sequence-item mappings (`- { ... }`) are rejected wholesale
# rather than parsed for keys. A deliberate evader defeats any grep sensor;
# these cases do not occur in accidental drift. Do not "fix" residuals with
# more regex — if the threat model changes, replace the sensor with a real
# YAML parser.
# Known residual evasions, reviewed and accepted 2026-08-12 (#191 round 4):
#   - annotations constructed via variable indirection
#     (`pfx='::warning::'; echo "${pfx}soft"`)
#   - multi-line string tricks that split a token across YAML lines or
#     shell concatenations (`echo "::warn"ing::`)
#   - `#` inside quoted strings on a genuine summary-write line (naive
#     comment strip cuts at the first `#`)
#   - YAML anchors, aliases, merge keys, or tag constructs
set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
DRIFT_SH="$REPO_ROOT/scripts/gibson-template-drift.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

SHA40='[0-9a-f]{40}'

# Workflow files under a tree (ci templates + live workflows). Missing dirs
# are ignored so planted fixtures can ship only the files they need.
collect_workflows() {
  local root="$1"
  find "$root/ci" "$root/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort
}

# True when a workflow line is a flow-style sequence-item mapping (`- { ... }`).
# Do not inspect keys — any such line is an unsupported YAML shape.
is_flow_style_step_line() {
  printf '%s\n' "$1" | grep -E '^[[:space:]]*-[[:space:]]*\{' >/dev/null
}

# Strip leading whitespace, then an optional YAML list dash, then more
# whitespace. Turns `      - uses: foo` and `uses: foo` into `uses: foo`.
# Comment-only lines become `# ...` and do not match uses:.
normalize_uses_line() {
  local trimmed="$1"
  trimmed=${trimmed#${trimmed%%[![:space:]]*}}
  if [[ "$trimmed" == -* ]]; then
    trimmed=${trimmed#-}
    trimmed=${trimmed#${trimmed%%[![:space:]]*}}
  fi
  printf '%s' "$trimmed"
}

# --- check functions (directory argument) ----------------------------------
# Each prints one violation per line and returns 1 if any, 0 if clean.

# Reject every flow-style sequence-item mapping. One rule, no key sniffing:
# `- { uses: ... }`, `- { name: X, uses: ... }`, `- { continue-on-error: ... }`
# and every future permutation fail the same way with file:line.
check_flow_style_steps() {
  local root="$1"
  local failed=0
  local f rel line raw lineno
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel=${f#"$root"/}
    lineno=0
    while IFS= read -r line; do
      lineno=$((lineno + 1))
      raw=${line#${line%%[![:space:]]*}}
      [[ "$raw" == \#* ]] && continue
      if is_flow_style_step_line "$line"; then
        echo "$rel:$lineno: unsupported YAML shape — use block style"
        failed=1
      fi
    done < "$f"
  done < <(collect_workflows "$root")
  return "$failed"
}

# (a) every uses: is 40-char-SHA-pinned with a trailing comment.
# Quoted values (`uses: "owner/action@<40sha>" # v1`) are valid. Flow-style
# sequence-item mappings (`- { ... }`) are an unsupported YAML shape —
# fail loud with file:line rather than inspecting keys.
check_sha_pin() {
  local root="$1"
  local failed=0
  local f rel line trimmed raw pinned lineno
  pinned=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel=${f#"$root"/}
    lineno=0
    while IFS= read -r line; do
      lineno=$((lineno + 1))
      raw=${line#${line%%[![:space:]]*}}
      [[ "$raw" == \#* ]] && continue
      if is_flow_style_step_line "$line"; then
        echo "$rel:$lineno: unsupported YAML shape — use block style"
        failed=1
        continue
      fi
      trimmed=$(normalize_uses_line "$line")
      [[ "$trimmed" == uses:* ]] || continue
      if printf '%s\n' "$trimmed" | grep -E "^uses:[[:space:]]*[\"']?[^@\"'[:space:]]+@${SHA40}[\"']?[[:space:]]+#[[:space:]]*.+" >/dev/null; then
        pinned=$((pinned + 1))
        continue
      fi
      echo "$rel: unpinned or uncommented uses: → $trimmed"
      failed=1
    done < "$f"
  done < <(collect_workflows "$root")
  if [[ "$failed" -eq 0 && "$pinned" -lt 1 ]]; then
    echo "expected at least one SHA-pinned uses:"
    failed=1
  fi
  return "$failed"
}

# (b) shipped templates deny by default; live workflows stay read-only at top.
check_permissions() {
  local root="$1"
  local failed=0
  local f rel any offenders
  any=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    any=1
    rel=${f#"$root"/}
    if ! grep -Eq '^permissions:' "$f"; then
      echo "$rel missing top-level permissions:"
      failed=1
      continue
    fi
    if [[ "$rel" == ci/* ]]; then
      if ! grep -Eq '^permissions:[[:space:]]*\{\}[[:space:]]*(#.*)?$' "$f"; then
        echo "$rel shipped template must use top-level permissions: {}"
        failed=1
      fi
      continue
    fi
    offenders=$(awk '
      /^permissions:/ {
        in_permissions=1
        if ($0 ~ /write-all/ || $0 ~ /:[[:space:]]*write([[:space:]#]|$)/) print NR ":" $0
        next
      }
      in_permissions && /^[^[:space:]#]/ { in_permissions=0 }
      in_permissions && !/^[[:space:]]*#/ {
        if ($0 ~ /write-all/ || $0 ~ /:[[:space:]]*write([[:space:]#]|$)/) print NR ":" $0
      }
    ' "$f")
    if [[ -n "$offenders" ]]; then
      echo "$rel workflow-level permissions exceed read-only: $offenders"
      failed=1
    fi
  done < <(collect_workflows "$root")
  if [[ "$any" -eq 0 ]]; then
    echo "no workflow files found"
    return 1
  fi
  return "$failed"
}

# True (exit 0) when the file has a PR-class trigger.
# Handles block `on:`, single-line flow `on: [...]`, and wrapped flow arrays
# (`on: [push,\n     pull_request]`) so a line break cannot hide a trigger.
has_pr_trigger() {
  awk '
    /^[[:space:]]*#/ { next }
    /^on:[[:space:]]*$/ { in_on=1; next }
    in_on && /^[^[:space:]#]/ { in_on=0 }
    in_on && /(pull_request|issue_comment|pull_request_review)([:]|$)/ { found=1 }
    /^on:[[:space:]]*(pull_request|issue_comment|pull_request_review)/ { found=1 }
    /^on:[[:space:]]*\[/ {
      in_flow_on=1
      if ($0 ~ /(pull_request|issue_comment|pull_request_review)/) found=1
      if ($0 ~ /\]/) in_flow_on=0
      next
    }
    in_flow_on {
      trimmed=$0
      sub(/^[[:space:]]+/, "", trimmed)
      if (trimmed !~ /^#/ && $0 ~ /(pull_request|issue_comment|pull_request_review)/) found=1
      if ($0 ~ /\]/) in_flow_on=0
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# (c) PR-triggered workflows actively cancel superseded PR runs unless stateful.
check_concurrency() {
  local root="$1"
  local failed=0
  local f rel
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel=${f#"$root"/}
    if grep -Eq '^[[:space:]]*#[[:space:]]*gibson:stateful-ci' "$f"; then
      continue
    fi
    if ! has_pr_trigger "$f"; then
      continue
    fi
    if grep -Eq '^concurrency:' "$f" && grep -Eq \
      '^[[:space:]]*cancel-in-progress:[[:space:]]*(true|\$\{\{[^}]*github\.event_name[^}]*pull_request[^}]*\}\})[[:space:]]*(#.*)?$' "$f"; then
      continue
    fi
    echo "$rel PR-triggered but missing active PR cancel-in-progress"
    failed=1
  done < <(collect_workflows "$root")
  return "$failed"
}

# (d) no hostile direct github.* interpolation inside run commands.
check_untrusted_interpolation() {
  local root="$1"
  local failed=0
  local f rel offenders
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel=${f#"$root"/}
    offenders=$(awk -v rel="$rel" '
      function leading(s,    n) {
        n = 0
        while (substr(s, n+1, 1) == " ") n++
        return n
      }
      function scan(candidate, lineno,    rest, expr, path, allowed) {
        rest = candidate
        while (match(rest, /\$\{\{[[:space:]]*github\.[^}]+[[:space:]]*\}\}/)) {
          expr = substr(rest, RSTART, RLENGTH)
          path = expr
          sub(/^\$\{\{[[:space:]]*github\./, "", path)
          sub(/[[:space:]]*\}\}$/, "", path)
          allowed = 0
          if (path ~ /^event\..*\.sha$/ || path ~ /^event\..*\.number$/) allowed = 1
          if (path == "repository" || path == "run_id" || path == "run_attempt") allowed = 1
          if (!allowed) printf "%s:%d: %s\n", rel, lineno, expr
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
      {
        line = $0
        ind = leading(line)
        if (match(line, /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>]/)) {
          in_run = 1
          run_ind = ind
          next
        }
        if (match(line, /^[[:space:]]*-?[[:space:]]*run:[[:space:]]+[^|>[:space:]]/)) {
          inline = line
          sub(/^[[:space:]]*-?[[:space:]]*run:[[:space:]]+/, "", inline)
          scan(inline, NR)
          in_run = 0
          next
        }
        if (in_run) {
          if (length(line) && ind <= run_ind && line ~ /^[[:space:]]*(- |[A-Za-z0-9_]+:)/) {
            in_run = 0
          } else if (in_run) {
            scan(line, NR)
          }
        }
      }
    ' "$f")
    if [[ -n "$offenders" ]]; then
      echo "$rel forbidden direct github context in run command(s): $offenders"
      failed=1
    fi
  done < <(collect_workflows "$root")
  return "$failed"
}

# True when the file uses pull_request_target as a trigger (not a comment).
# Covers block keys, list items, single-line flow arrays, and wrapped flow
# arrays (`on: [push,\n     pull_request_target]`).
has_pull_request_target() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*pull_request_target:/ { found=1 }
    /^[[:space:]]*-[[:space:]]*pull_request_target[[:space:]]*$/ { found=1 }
    /^on:[[:space:]]*(\[[^]#]*)?pull_request_target/ { found=1 }
    /^on:[[:space:]]*\[/ {
      in_flow_on=1
      if ($0 ~ /pull_request_target/) found=1
      if ($0 ~ /\]/) in_flow_on=0
      next
    }
    in_flow_on {
      trimmed=$0
      sub(/^[[:space:]]+/, "", trimmed)
      if (trimmed !~ /^#/ && $0 ~ /pull_request_target/) found=1
      if ($0 ~ /\]/) in_flow_on=0
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# (e) pull_request_target requires # gibson:approved-pr-target <issue>
check_pull_request_target() {
  local root="$1"
  local failed=0
  local f rel
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel=${f#"$root"/}
    if has_pull_request_target "$f"; then
      if ! grep -Eq 'gibson:approved-pr-target[[:space:]]+[^[:space:]]+' "$f"; then
        echo "$rel uses pull_request_target without # gibson:approved-pr-target <issue>"
        failed=1
      fi
    fi
  done < <(collect_workflows "$root")
  return "$failed"
}

# Extract run: script body from a step block; strip comment lines.
run_script_from_step() {
  printf '%s\n' "$1" | awk '
    function leading(s,    n) {
      n = 0
      while (substr(s, n+1, 1) == " ") n++
      return n
    }
    {
      line = $0
      ind = leading(line)
      if (match(line, /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>]/)) {
        in_run = 1
        run_ind = ind
        next
      }
      if (match(line, /^[[:space:]]*-?[[:space:]]*run:[[:space:]]+[^|>[:space:]]/)) {
        body = line
        sub(/^[[:space:]]*-?[[:space:]]*run:[[:space:]]+/, "", body)
        if (body !~ /^[[:space:]]*#/) print body
        next
      }
      if (in_run) {
        if (length(line) && ind <= run_ind && line ~ /^[[:space:]]*(- |[A-Za-z0-9_]+:)/) {
          in_run = 0
        } else {
          trimmed = line
          sub(/^[[:space:]]+/, "", trimmed)
          if (trimmed ~ /^#/ || trimmed == "") next
          print line
        }
      }
    }
  '
}

# True (exit 0) when continue-on-error at line target is nested under steps:.
is_step_level_coe() {
  local file="$1"
  local target="$2"
  awk -v target="$target" '
    function leading(s,    n) {
      n = 0
      while (substr(s, n+1, 1) == " ") n++
      return n
    }
    { lines[NR] = $0; ind[NR] = leading($0) }
    END {
      coe_ind = ind[target]
      for (i = target - 1; i >= 1; i--) {
        if (length(lines[i]) == 0) continue
        if (lines[i] ~ /^[[:space:]]*#/) continue
        if (ind[i] >= coe_ind) continue
        if (lines[i] ~ /^[[:space:]]*steps:[[:space:]]*$/) exit 0
        if (lines[i] ~ /^[[:space:]]*-[[:space:]]/) continue
        exit 1
      }
      exit 1
    }
  ' "$file"
}

# True when a continue-on-error line is "soft": value is not literal false.
# Bare true, quoted "true" / 'true', and ${{ ... }} all count. Trailing comments
# are stripped before the compare.
is_soft_coe() {
  local line="$1"
  local val
  val=${line#*continue-on-error:}
  val=${val%%#*}
  val=${val#${val%%[![:space:]]*}}
  val=${val%${val##*[![:space:]]}}
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  [[ "$val" != "false" ]]
}

# True when run-script text contains a real annotation emission: a non-comment
# echo/printf whose quoted or bare argument STARTS with ::warning:: or
# ::notice::. Mid-string (`echo "prefix ::warning:: x"`) and shell comments
# (`do_scan # ::warning::`) do not satisfy this.
has_annotation_emission() {
  printf '%s\n' "$1" | grep -E >/dev/null \
    '^[[:space:]]*(echo|printf)[[:space:]]+["'\'']?::(warning|notice)::'
}

# True when the script appends to $GITHUB_STEP_SUMMARY. Trailing shell
# comments are stripped first (`true # >> "$GITHUB_STEP_SUMMARY"` does not
# count), same naive first-`#` cut as is_soft_coe.
has_step_summary_append() {
  local line stripped
  while IFS= read -r line; do
    stripped=${line%%#*}
    if printf '%s\n' "$stripped" | grep -E '>>[[:space:]]*["'\'']?\$\{?GITHUB_STEP_SUMMARY(\}|[^A-Za-z0-9_]|$)' >/dev/null; then
      return 0
    fi
  done <<< "$1"
  return 1
}

# True when the job containing line `target` has a dedicated announce step:
# (i) first step with if: absent, OR any step with if: always() exactly
#     (any other if: value disqualifies the step), and
# (ii) annotation emission + $GITHUB_STEP_SUMMARY append.
job_has_announce_step() {
  local file="$1"
  local target="$2"
  awk -v target="$target" '
    function leading(s,    n) {
      n = 0
      while (substr(s, n+1, 1) == " ") n++
      return n
    }
    function has_ann(script) {
      return script ~ /(^|\n)[[:space:]]*(echo|printf)[[:space:]]+["'"'"']?::(warning|notice)::/
    }
    function has_sum(script,    n, arr, i, line, hash) {
      n = split(script, arr, "\n")
      for (i = 1; i <= n; i++) {
        line = arr[i]
        hash = index(line, "#")
        if (hash > 0) line = substr(line, 1, hash - 1)
        if (line ~ />>[[:space:]]*["'"'"']?\$\{?GITHUB_STEP_SUMMARY(\}|[^A-Za-z0-9_]|$)/) return 1
      }
      return 0
    }
    { lines[NR] = $0; ind[NR] = leading($0); total = NR }
    END {
      coe_ind = ind[target]
      job_start = 0
      job_ind = 0
      for (i = target; i >= 1; i--) {
        if (length(lines[i]) == 0 || lines[i] ~ /^[[:space:]]*#/) continue
        if (ind[i] < coe_ind && lines[i] ~ /^[[:space:]]*[A-Za-z0-9_-]+:/) {
          job_start = i
          job_ind = ind[i]
          break
        }
      }
      if (!job_start) exit 1
      job_end = total
      for (i = job_start + 1; i <= total; i++) {
        if (length(lines[i]) == 0 || lines[i] ~ /^[[:space:]]*#/) continue
        if (ind[i] <= job_ind) {
          job_end = i - 1
          break
        }
      }
      steps_line = 0
      steps_ind = 0
      for (i = job_start; i <= job_end; i++) {
        if (lines[i] ~ /^[[:space:]]*steps:[[:space:]]*$/) {
          steps_line = i
          steps_ind = ind[i]
          break
        }
      }
      if (!steps_line) exit 1
      step_item_ind = -1
      step_n = 0
      for (i = steps_line + 1; i <= job_end; i++) {
        if (length(lines[i]) == 0 || lines[i] ~ /^[[:space:]]*#/) continue
        if (ind[i] <= steps_ind) break
        if (lines[i] ~ /^[[:space:]]*-[[:space:]]/) {
          if (step_item_ind < 0) step_item_ind = ind[i]
          if (ind[i] == step_item_ind) {
            step_n++
            step_start[step_n] = i
            if (step_n > 1) step_end[step_n - 1] = i - 1
          }
        }
      }
      if (step_n == 0) exit 1
      step_end[step_n] = job_end
      for (s = 1; s <= step_n; s++) {
        is_first = (s == 1)
        has_always = 0
        has_other_if = 0
        script = ""
        in_run = 0
        run_ind = 0
        for (i = step_start[s]; i <= step_end[s]; i++) {
          if (lines[i] ~ /^[[:space:]]*-?[[:space:]]*["'"'"']?if["'"'"']?[[:space:]]*:[[:space:]]*/) {
            if (lines[i] ~ /^[[:space:]]*-?[[:space:]]*["'"'"']?if["'"'"']?[[:space:]]*:[[:space:]]*always\(\)[[:space:]]*(#.*)?$/) {
              has_always = 1
            } else {
              has_other_if = 1
            }
          }
          if (match(lines[i], /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>]/)) {
            in_run = 1
            run_ind = ind[i]
            continue
          }
          if (match(lines[i], /^[[:space:]]*-?[[:space:]]*run:[[:space:]]+[^|>[:space:]]/)) {
            body = lines[i]
            sub(/^[[:space:]]*-?[[:space:]]*run:[[:space:]]+/, "", body)
            if (body !~ /^[[:space:]]*#/) script = script body "\n"
            in_run = 0
            continue
          }
          if (in_run) {
            if (length(lines[i]) && ind[i] <= run_ind && lines[i] ~ /^[[:space:]]*(- |[A-Za-z0-9_]+:)/) {
              in_run = 0
            } else {
              trimmed = lines[i]
              sub(/^[[:space:]]+/, "", trimmed)
              if (trimmed ~ /^#/ || trimmed == "") continue
              script = script lines[i] "\n"
            }
          }
        }
        if (has_other_if) continue
        if (!is_first && !has_always) continue
        if (has_ann(script) && has_sum(script)) exit 0
      }
      exit 1
    }
  ' "$file"
}

# (f) soft continue-on-error (job or step) must be visible.
# Soft = any continue-on-error whose value is not literal false (bare true,
# quoted true, ${{ ... }}). Job-level soft jobs need a dedicated announce
# step (if: absent or exactly always() + annotation + GITHUB_STEP_SUMMARY).
# Step-level soft steps need an annotation emission in the step body.
# Annotation = echo/printf whose string STARTS with ::warning:: or ::notice::.
check_visible_skip() {
  local root="$1"
  local failed=0
  local f rel ln rest block script
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel=${f#"$root"/}
    while IFS=: read -r ln rest; do
      [[ -z "$ln" ]] && continue
      is_soft_coe "$rest" || continue
      if is_step_level_coe "$f" "$ln"; then
        block=$(awk -v target="$ln" '
          function leading(s,    n) {
            n = 0
            while (substr(s, n+1, 1) == " ") n++
            return n
          }
          NR == target { hit = 1; coe_ind = leading($0) }
          { lines[NR] = $0; ind[NR] = leading($0); total = NR }
          END {
            if (!hit) exit 1
            start = target
            step_ind = coe_ind
            for (i = target; i >= 1; i--) {
              if (lines[i] ~ /^[[:space:]]*-[[:space:]]/) {
                start = i
                step_ind = ind[i]
                break
              }
            }
            end = total
            for (i = target + 1; i <= total; i++) {
              if (length(lines[i]) == 0) continue
              if (ind[i] <= step_ind && lines[i] ~ /^[[:space:]]*(- |[A-Za-z0-9_]+:)/) {
                end = i - 1
                break
              }
            }
            for (i = start; i <= end; i++) print lines[i]
          }
        ' "$f")
        script=$(run_script_from_step "$block")
        if ! has_annotation_emission "$script" || ! has_step_summary_append "$script"; then
          echo "$rel:$ln continue-on-error step missing active annotation and GITHUB_STEP_SUMMARY in step body"
          failed=1
        fi
      else
        if ! job_has_announce_step "$f" "$ln"; then
          echo "$rel:$ln continue-on-error job missing dedicated announce step (if: absent or always() + annotation + GITHUB_STEP_SUMMARY)"
          failed=1
        fi
      fi
    done < <(grep -nE '^[[:space:]]*continue-on-error:' "$f" || true)
  done < <(collect_workflows "$root")
  return "$failed"
}

# (g) graceful skip/report-only exit 0 branches must be visible in the same step.
check_graceful_skip() {
  local root="$1"
  local failed=0
  local f rel hits
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel=${f#"$root"/}
    hits=$(awk -v rel="$rel" '
      function leading(s,    n) {
        n = 0
        while (substr(s, n+1, 1) == " ") n++
        return n
      }
      function inspect(script, exit_line,    lower, has_ann, has_sum) {
        lower = tolower(script)
        if (lower !~ /(^|[;[:space:]])exit[[:space:]]+0([;[:space:]]|$)/) return
        if (lower !~ /(skip|missing|not[[:space:]]+installed|not[[:space:]]+vendored|report-only|adoption[[:space:]]+gap)/) return
        has_ann = script ~ /(^|\n)[[:space:]]*(echo|printf)[[:space:]]+["'"'"']?::(warning|notice)::/
        has_sum = script ~ />>[[:space:]]*["'"'"']?\$\{?GITHUB_STEP_SUMMARY(\}|[^A-Za-z0-9_]|$)/
        if (!has_ann || !has_sum) {
          printf "%s:%d graceful exit 0 skip/report-only branch missing active annotation and GITHUB_STEP_SUMMARY\n", rel, exit_line
        }
      }
      function flush() {
        if (have_run) inspect(script, exit_line)
        have_run = 0
        script = ""
        exit_line = 0
      }
      {
        line = $0
        ind = leading(line)
        if (match(line, /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>]/)) {
          flush()
          have_run = 1
          run_ind = ind
          next
        }
        if (match(line, /^[[:space:]]*-?[[:space:]]*run:[[:space:]]+[^|>[:space:]]/)) {
          flush()
          body = line
          sub(/^[[:space:]]*-?[[:space:]]*run:[[:space:]]+/, "", body)
          sub(/[[:space:]]+#.*/, "", body)
          inspect(body, NR)
          next
        }
        if (have_run) {
          if (length(line) && ind <= run_ind && line ~ /^[[:space:]]*(- |[A-Za-z0-9_]+:)/) {
            flush()
          } else {
            body = line
            sub(/^[[:space:]]+/, "", body)
            if (body ~ /^#/ || body == "") next
            sub(/[[:space:]]+#.*/, "", body)
            script = script body "\n"
            if (!exit_line && tolower(body) ~ /(^|[;[:space:]])exit[[:space:]]+0([;[:space:]]|$)/) exit_line = NR
          }
        }
      }
      END { flush() }
    ' "$f")
    if [[ -n "$hits" ]]; then
      printf '%s\n' "$hits"
      failed=1
    fi
  done < <(collect_workflows "$root")
  return "$failed"
}

# (h) templates/ and ci/ contain no operator literals (mrhinkle, /Users/).
check_operator_literals() {
  local root="$1"
  local hits scope failed
  failed=0
  for scope in templates ci; do
    [[ -d "$root/$scope" ]] || continue
    hits=$(grep -RInE 'mrhinkle|/Users/' "$root/$scope" 2>/dev/null || true)
    [[ -n "$hits" ]] || continue
    hits=$(printf '%s\n' "$hits" | sed "s#^${root}/##")
    echo "$scope/ operator literals: $hits"
    failed=1
  done
  return "$failed"
}

# Report a planted-fixture failure. needle must appear in the check output.
assert_planted() {
  local n="$1"
  local desc="$2"
  local needle="$3"
  local got="$4"
  if printf '%s\n' "$got" | grep -F "$needle" >/dev/null; then
    ok "mutation $n: $desc"
    echo "  PLANTED[$n] FAIL — $got"
  else
    bad "mutation $n: $desc was NOT rejected (sensor blind): [$got]"
  fi
}

# Control fixture: the check must produce no violations.
assert_clean() {
  local n="$1"
  local desc="$2"
  local got="$3"
  if [[ -z "$got" ]]; then
    ok "mutation $n: $desc"
  else
    bad "mutation $n: $desc was rejected: [$got]"
  fi
}

fixture_content_hash() {
  { grep -v '^# gibson-template-version:' "$1" || true; } | {
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum
    else
      shasum -a 256
    fi
  } | awk '{print $1}'
}

stamp_fixture() {
  local file="$1" hash tmp
  hash=$(fixture_content_hash "$file")
  tmp="${file}.stamped"
  {
    echo "# gibson-template-version: sha256:${hash}"
    grep -v '^# gibson-template-version:' "$file" || true
  } > "$tmp"
  mv "$tmp" "$file"
}

# Exact equivalent of the schema-guard every-PR destructive-flag scan. Keep
# the flag fragments split so installing that workflow in this repo does not
# make this sensor file self-match.
destructive_flag_hits() {
  local root="$1" loss_a loss_b reset_a reset_b pattern
  loss_a='--accept-data'
  loss_b='-loss'
  reset_a='--force'
  reset_b='-reset'
  pattern="${loss_a}${loss_b}|${reset_a}${reset_b}"
  (cd "$root" && git grep -nE -- "$pattern" -- '*.json' '*.sh' '*.ts' '*.js' '*.yml' '*.yaml' 2>/dev/null)
}

# --- clean-tree pass -------------------------------------------------------

WORKFLOWS=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  WORKFLOWS+=("$f")
done < <(collect_workflows "$REPO_ROOT")

[[ ${#WORKFLOWS[@]} -gt 0 ]] || { echo "ci-conventions.test.sh: no workflow files found"; exit 1; }

echo "# flow-style sequence-item mappings (- { ... }) are unsupported"
flow_viol=$(check_flow_style_steps "$REPO_ROOT") || true
if [[ -z "$flow_viol" ]]; then
  ok "no flow-style step mappings (- { ... }) in workflow files"
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    bad "$line"
  done <<< "$flow_viol"
fi

echo "# (a) every uses: is 40-char-SHA-pinned with a trailing comment"
sha_viol=$(check_sha_pin "$REPO_ROOT") || true
if [[ -z "$sha_viol" ]]; then
  pinned=$(grep -hE "uses:[[:space:]]*[^@[:space:]]+@${SHA40}[[:space:]]+#" "${WORKFLOWS[@]}" | wc -l | tr -d ' ')
  ok "all uses: lines are @${SHA40} with trailing # comment ($pinned pinned refs)"
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    bad "$line"
  done <<< "$sha_viol"
fi

echo "# (b) shipped templates deny by default; live workflow top-level grants are read-only"
perm_viol=$(check_permissions "$REPO_ROOT") || true
if [[ -z "$perm_viol" ]]; then
  for f in "${WORKFLOWS[@]}"; do
    ok "${f#"$REPO_ROOT"/} declares permissions:"
  done
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    bad "$line"
  done <<< "$perm_viol"
fi

echo "# (c) PR-triggered workflows actively cancel superseded PR runs (unless stateful)"
conc_viol=$(check_concurrency "$REPO_ROOT") || true
if [[ -z "$conc_viol" ]]; then
  for f in "${WORKFLOWS[@]}"; do
    rel=${f#"$REPO_ROOT"/}
    if grep -Eq '^[[:space:]]*#[[:space:]]*gibson:stateful-ci' "$f"; then
      ok "$rel annotated # gibson:stateful-ci — concurrency not required"
    elif ! has_pr_trigger "$f"; then
      ok "$rel has no PR-class triggers — concurrency not required"
    else
      ok "$rel has active PR cancellation"
    fi
  done
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    bad "$line"
  done <<< "$conc_viol"
fi

echo "# (d) no hostile direct github.* interpolation inside run commands"
untrust_viol=$(check_untrusted_interpolation "$REPO_ROOT") || true
if [[ -z "$untrust_viol" ]]; then
  for f in "${WORKFLOWS[@]}"; do
    ok "${f#"$REPO_ROOT"/} run commands only use allowlisted direct github contexts"
  done
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    bad "$line"
  done <<< "$untrust_viol"
fi

echo "# (e) pull_request_target requires # gibson:approved-pr-target <issue>"
prt_viol=$(check_pull_request_target "$REPO_ROOT") || true
if [[ -z "$prt_viol" ]]; then
  for f in "${WORKFLOWS[@]}"; do
    rel=${f#"$REPO_ROOT"/}
    if has_pull_request_target "$f"; then
      ok "$rel pull_request_target is annotated gibson:approved-pr-target"
    else
      ok "$rel has no pull_request_target trigger"
    fi
  done
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    bad "$line"
  done <<< "$prt_viol"
fi

echo "# (f) soft continue-on-error (job or step) is visible"
vis_viol=$(check_visible_skip "$REPO_ROOT") || true
if [[ -z "$vis_viol" ]]; then
  for f in "${WORKFLOWS[@]}"; do
    rel=${f#"$REPO_ROOT"/}
    if grep -Eq '^[[:space:]]*continue-on-error:' "$f"; then
      ok "$rel continue-on-error is visible (annotation / announce step)"
    else
      ok "$rel has no continue-on-error"
    fi
  done
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    bad "$line"
  done <<< "$vis_viol"
fi

echo "# (g) graceful exit-0 skips/report-only branches are visible"
grace_viol=$(check_graceful_skip "$REPO_ROOT") || true
if [[ -z "$grace_viol" ]]; then
  ok "all graceful skip/report-only exits emit an annotation and step summary"
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    bad "$line"
  done <<< "$grace_viol"
fi

echo "# gibson-template-drift.sh --repo without a value is usage (exit 2)"
drift_rc=0
drift_out=$("$DRIFT_SH" --repo 2>&1) || drift_rc=$?
if [[ "$drift_rc" -eq 2 ]] && printf '%s\n' "$drift_out" | grep -E 'Usage|USAGE|--repo' >/dev/null; then
  ok "--repo with no value prints usage and exits 2"
else
  bad "--repo with no value: expected exit 2 + usage, got rc=${drift_rc} out=${drift_out}"
fi

echo "# live ci/*.yml template stamps are current"
drift_rc=0
drift_out=$("$DRIFT_SH" --gibson "$REPO_ROOT" --repo "$REPO_ROOT" 2>&1) || drift_rc=$?
if [[ "$drift_rc" -eq 0 ]] && printf '%s\n' "$drift_out" | grep -F 'drift=0' >/dev/null; then
  ok "all live ci/*.yml stamps match their content"
else
  bad "live template stamp drift (rc=${drift_rc} out=${drift_out})"
fi

echo "# (h) templates/ and ci/ contain no operator literals (mrhinkle, /Users/)"
op_viol=$(check_operator_literals "$REPO_ROOT") || true
if [[ -z "$op_viol" ]]; then
  ok "templates/ and ci/ are free of mrhinkle and /Users/ literals"
else
  bad "$op_viol"
fi

# --- mutation coverage: one planted fixture per sensor ---------------------
# A sensor that has never been shown to fail is a green light wired to nothing.

MUT=$(mktemp -d "${TMPDIR:-/tmp}/gibson-ci-conv.XXXXXX")
trap 'rm -rf "$MUT"' EXIT

echo "# mutation coverage (planted fixtures must fail their check)"

# 1. list-item tag, not SHA
mkdir -p "$MUT/1/ci"
cat > "$MUT/1/ci/planted.yml" <<'YML'
name: planted-tag
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YML
got=$(check_sha_pin "$MUT/1") || true
assert_planted 1 "list-item - uses: actions/checkout@v4" \
  "unpinned or uncommented uses: → uses: actions/checkout@v4" "$got"

# 2. short SHA with a trailing comment (still unpinned)
mkdir -p "$MUT/2/ci"
cat > "$MUT/2/ci/planted.yml" <<'YML'
name: planted-short
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: foo/bar@abc123 # v1
YML
got=$(check_sha_pin "$MUT/2") || true
assert_planted 2 "short SHA - uses: foo/bar@abc123 # v1" \
  "unpinned or uncommented uses: → uses: foo/bar@abc123 # v1" "$got"

# 3. PR workflow, no permissions: key
mkdir -p "$MUT/3/ci"
cat > "$MUT/3/ci/planted.yml" <<'YML'
name: planted-perms
on: pull_request
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
got=$(check_permissions "$MUT/3") || true
assert_planted 3 "on: pull_request with no permissions:" \
  "ci/planted.yml missing top-level permissions:" "$got"

# 4. PR workflow, no concurrency, unannotated
mkdir -p "$MUT/4/ci"
cat > "$MUT/4/ci/planted.yml" <<'YML'
name: planted-conc
on: pull_request
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
got=$(check_concurrency "$MUT/4") || true
assert_planted 4 "on: pull_request with no concurrency:" \
  "ci/planted.yml PR-triggered but missing active PR cancel-in-progress" "$got"

# 5. untrusted interpolation in a run: block
mkdir -p "$MUT/5/ci"
cat > "$MUT/5/ci/planted.yml" <<'YML'
name: planted-interp
on: pull_request
permissions: {}
concurrency:
  group: x
  cancel-in-progress: true
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "${{ github.event.pull_request.title }}"
YML
got=$(check_untrusted_interpolation "$MUT/5") || true
assert_planted 5 "run: interpolates github.event.pull_request.title" \
  '${{ github.event.pull_request.title }}' "$got"

# 6. inline-array pull_request_target, no waiver
mkdir -p "$MUT/6/ci"
cat > "$MUT/6/ci/planted.yml" <<'YML'
name: planted-prt
on: [push, pull_request_target]
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
got=$(check_pull_request_target "$MUT/6") || true
assert_planted 6 "on: [push, pull_request_target] without waiver" \
  "ci/planted.yml uses pull_request_target without # gibson:approved-pr-target <issue>" "$got"

# 7. continue-on-error whose run: has no annotation; YAML comment does
mkdir -p "$MUT/7/ci"
cat > "$MUT/7/ci/planted.yml" <<'YML'
name: planted-skip
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      # ::warning:: in a YAML comment must not satisfy the sensor
      - name: soft
        continue-on-error: true
        run: |
          echo "no annotation in the script"
YML
got=$(check_visible_skip "$MUT/7") || true
assert_planted 7 "continue-on-error with warning only in a YAML comment" \
  "continue-on-error step missing active annotation and GITHUB_STEP_SUMMARY" "$got"

# 8. templates/ file containing mrhinkle
mkdir -p "$MUT/8/templates"
printf 'mrhinkle\n' > "$MUT/8/templates/planted.txt"
got=$(check_operator_literals "$MUT/8") || true
assert_planted 8 "templates/ contains mrhinkle" \
  "templates/ operator literals:" "$got"

# 9. job-level continue-on-error with no announce step
mkdir -p "$MUT/9/ci"
cat > "$MUT/9/ci/planted.yml" <<'YML'
name: planted-job-coe
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - run: echo hi
YML
got=$(check_visible_skip "$MUT/9") || true
assert_planted 9 "job-level continue-on-error: true with no announce step" \
  "continue-on-error job missing dedicated announce step" "$got"

# 10. step-level expression continue-on-error, no annotation
mkdir -p "$MUT/10/ci"
cat > "$MUT/10/ci/planted.yml" <<'YML'
name: planted-expr-coe
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: soft
        continue-on-error: ${{ github.event_name == 'push' }}
        run: echo hi
YML
got=$(check_visible_skip "$MUT/10") || true
assert_planted 10 "step continue-on-error: \${{ ... }} with no annotation" \
  "continue-on-error step missing active annotation and GITHUB_STEP_SUMMARY" "$got"

# 11. mid-string ::warning:: is not an annotation emission
mkdir -p "$MUT/11/ci"
cat > "$MUT/11/ci/planted.yml" <<'YML'
name: planted-mid-warning
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: soft
        continue-on-error: true
        run: echo "prefix ::warning:: not an annotation"
YML
got=$(check_visible_skip "$MUT/11") || true
assert_planted 11 "echo \"prefix ::warning:: not an annotation\" does not satisfy" \
  "continue-on-error step missing active annotation and GITHUB_STEP_SUMMARY" "$got"

# 12. shell-comment ::warning:: is not an annotation emission
mkdir -p "$MUT/12/ci"
cat > "$MUT/12/ci/planted.yml" <<'YML'
name: planted-hash-warning
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: soft
        continue-on-error: true
        run: do_scan # ::warning:: comment
YML
got=$(check_visible_skip "$MUT/12") || true
assert_planted 12 "do_scan # ::warning:: comment does not satisfy" \
  "continue-on-error step missing active annotation and GITHUB_STEP_SUMMARY" "$got"

# 13. job-level soft job WITH if: always() announce step (must pass)
mkdir -p "$MUT/13/ci"
cat > "$MUT/13/ci/planted.yml" <<'YML'
name: planted-job-announce
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - name: announce
        if: always()
        run: |
          echo "::warning::soft job"
          echo "soft job" >> "$GITHUB_STEP_SUMMARY"
      - run: echo hi
YML
got=$(check_visible_skip "$MUT/13") || true
assert_clean 13 "job-level soft job with if: always() announce step passes" "$got"

# 14. quoted pinned uses must pass (single and double quotes)
mkdir -p "$MUT/14/ci"
cat > "$MUT/14/ci/planted.yml" <<'YML'
name: planted-quoted-pin
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: "owner/action@0123456789abcdef0123456789abcdef01234567" # v1
      - uses: 'owner/action@0123456789abcdef0123456789abcdef01234567' # v1
YML
got=$(check_sha_pin "$MUT/14") || true
assert_clean 14 "quoted pinned uses: pass" "$got"

# 15. flow-style uses mapping is unsupported (must fail, not silently ignore)
mkdir -p "$MUT/15/ci"
cat > "$MUT/15/ci/planted.yml" <<'YML'
name: planted-flow-uses
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - { uses: owner/action@v4 }
YML
got=$(check_sha_pin "$MUT/15") || true
assert_planted 15 "flow-style - { uses: owner/action@v4 }" \
  "unsupported YAML shape — use block style" "$got"

# 16. wrapped-flow pull_request_target without waiver
mkdir -p "$MUT/16/ci"
cat > "$MUT/16/ci/planted.yml" <<'YML'
name: planted-wrapped-prt
on: [push,
     pull_request_target]
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
got=$(check_pull_request_target "$MUT/16") || true
assert_planted 16 "wrapped-flow on: [push, pull_request_target] without waiver" \
  "ci/planted.yml uses pull_request_target without # gibson:approved-pr-target <issue>" "$got"

# 17. drift: template missing its stamp → named diagnostic + rc=1
mkdir -p "$MUT/17/ci" "$MUT/17-repo"
cat > "$MUT/17/ci/planted.yml" <<'YML'
name: planted
on: push
YML
drift_rc=0
got=$("$DRIFT_SH" --gibson "$MUT/17" --repo "$MUT/17-repo" 2>&1) || drift_rc=$?
if [[ "$drift_rc" -eq 1 ]] && printf '%s\n' "$got" | grep -F "DRIFT  planted.yml  template stamp missing" >/dev/null; then
  ok "mutation 17: template missing stamp prints diagnostic and exits 1"
  echo "  PLANTED[17] FAIL — $got"
else
  bad "mutation 17: template missing stamp (rc=${drift_rc} out=${got})"
fi

# 18. drift: installed workflow missing its stamp → named diagnostic + rc=1
mkdir -p "$MUT/18/ci" "$MUT/18-repo/.github/workflows"
cat > "$MUT/18/ci/planted.yml" <<'YML'
name: planted
on: push
permissions: {}
YML
_h=$(grep -v '^# gibson-template-version:' "$MUT/18/ci/planted.yml" | {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    shasum -a 256
  fi
} | awk '{print $1}')
{
  echo "# gibson-template-version: sha256:${_h}"
  cat "$MUT/18/ci/planted.yml"
} > "$MUT/18/ci/planted.yml.tmp"
mv "$MUT/18/ci/planted.yml.tmp" "$MUT/18/ci/planted.yml"
cat > "$MUT/18-repo/.github/workflows/planted.yml" <<'YML'
name: planted
on: push
permissions: {}
YML
drift_rc=0
got=$("$DRIFT_SH" --gibson "$MUT/18" --repo "$MUT/18-repo" 2>&1) || drift_rc=$?
if [[ "$drift_rc" -eq 1 ]] && printf '%s\n' "$got" | grep -F "DRIFT  planted.yml  installed stamp missing" >/dev/null; then
  ok "mutation 18: installed workflow missing stamp prints diagnostic and exits 1"
  echo "  PLANTED[18] FAIL — $got"
else
  bad "mutation 18: installed workflow missing stamp (rc=${drift_rc} out=${got})"
fi

# 19. flow-style uses: not immediately after { (must fail, not parse keys)
mkdir -p "$MUT/19/ci"
cat > "$MUT/19/ci/planted.yml" <<'YML'
name: planted-flow-named-uses
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - { name: Checkout, uses: actions/checkout@v4 }
YML
got=$(check_flow_style_steps "$MUT/19") || true
assert_planted 19 "flow-style - { name: Checkout, uses: actions/checkout@v4 }" \
  "unsupported YAML shape — use block style" "$got"

# 20. flow-style continue-on-error step (must fail, not parse keys)
mkdir -p "$MUT/20/ci"
cat > "$MUT/20/ci/planted.yml" <<'YML'
name: planted-flow-coe
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - { continue-on-error: true, run: "exit 1" }
YML
got=$(check_flow_style_steps "$MUT/20") || true
assert_planted 20 "flow-style - { continue-on-error: true, run: \"exit 1\" }" \
  "unsupported YAML shape — use block style" "$got"

# 21. job-level soft job whose first announce step has if: false (must fail)
mkdir -p "$MUT/21/ci"
cat > "$MUT/21/ci/planted.yml" <<'YML'
name: planted-announce-if-false
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - name: announce
        if: false
        run: |
          echo "::warning::soft job"
          echo "soft job" >> "$GITHUB_STEP_SUMMARY"
      - run: echo hi
YML
got=$(check_visible_skip "$MUT/21") || true
assert_planted 21 "job-level continue-on-error with first announce if: false" \
  "continue-on-error job missing dedicated announce step" "$got"

# 22. announce step whose only summary write is in a trailing comment (must fail)
mkdir -p "$MUT/22/ci"
cat > "$MUT/22/ci/planted.yml" <<'YML'
name: planted-summary-comment
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - name: announce
        if: always()
        run: |
          echo "::warning::soft job"
          true # >> "$GITHUB_STEP_SUMMARY"
      - run: echo hi
YML
got=$(check_visible_skip "$MUT/22") || true
assert_planted 22 "announce summary write only in trailing comment" \
  "continue-on-error job missing dedicated announce step" "$got"

# 23. inline run: hostile PR title interpolation
mkdir -p "$MUT/23/ci"
cat > "$MUT/23/ci/planted.yml" <<'YML'
name: planted-inline-event
on: pull_request
permissions: {}
concurrency:
  group: x
  cancel-in-progress: true
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ github.event.pull_request.title }}"
YML
got=$(check_untrusted_interpolation "$MUT/23") || true
assert_planted 23 "inline run: hostile PR title interpolation" \
  'ci/planted.yml:11: ${{ github.event.pull_request.title }}' "$got"

# 24. direct github.head_ref in a run command
mkdir -p "$MUT/24/ci"
cat > "$MUT/24/ci/planted.yml" <<'YML'
name: planted-head-ref
on: pull_request
permissions: {}
concurrency:
  group: x
  cancel-in-progress: true
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "${{ github.head_ref }}"
YML
got=$(check_untrusted_interpolation "$MUT/24") || true
assert_planted 24 "direct github.head_ref inside run block" \
  '${{ github.head_ref }}' "$got"

# 25. comment-only cancellation must not satisfy a PR workflow
mkdir -p "$MUT/25/ci"
cat > "$MUT/25/ci/planted.yml" <<'YML'
name: planted-comment-cancel
on: pull_request
permissions: {}
concurrency:
  group: x
  # cancel-in-progress: true
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
got=$(check_concurrency "$MUT/25") || true
assert_planted 25 "comment-only cancel-in-progress" \
  "missing active PR cancel-in-progress" "$got"

# 26. workflow-level write-all is not least privilege
mkdir -p "$MUT/26/ci"
cat > "$MUT/26/ci/planted.yml" <<'YML'
name: planted-write-all
on: pull_request
permissions: write-all
concurrency:
  group: x
  cancel-in-progress: true
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
got=$(check_permissions "$MUT/26") || true
assert_planted 26 "shipped template permissions: write-all" \
  "shipped template must use top-level permissions: {}" "$got"

# 27. operator literals in ci/ are covered, not only templates/
mkdir -p "$MUT/27/ci"
cat > "$MUT/27/ci/planted.yml" <<'YML'
# operator: mrhinkle
name: planted-operator
on: push
permissions: {}
jobs: {}
YML
got=$(check_operator_literals "$MUT/27") || true
assert_planted 27 "ci/ contains an operator login" \
  "ci/ operator literals:" "$got"

# 28. graceful missing/skip exit without warning + summary
mkdir -p "$MUT/28/ci"
cat > "$MUT/28/ci/planted.yml" <<'YML'
name: planted-graceful-skip
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "posture probe missing — skip"
          exit 0
YML
got=$(check_graceful_skip "$MUT/28") || true
assert_planted 28 "graceful missing/skip exit without visibility" \
  "ci/planted.yml:10 graceful exit 0 skip/report-only branch missing" "$got"

# 29. a stale template stamp must fail the drift ratchet
mkdir -p "$MUT/29/ci" "$MUT/29-repo"
cat > "$MUT/29/ci/planted.yml" <<'YML'
# gibson-template-version: sha256:0000000000000000000000000000000000000000000000000000000000000000
name: planted-stale-stamp
on: push
permissions: {}
YML
drift_rc=0
got=$("$DRIFT_SH" --gibson "$MUT/29" --repo "$MUT/29-repo" 2>&1) || drift_rc=$?
if [[ "$drift_rc" -eq 1 ]] && printf '%s\n' "$got" | grep -F "template stamp mismatch" >/dev/null; then
  ok "mutation 29: stale template stamp fails with diagnostic"
  echo "  PLANTED[29] FAIL — $got"
else
  bad "mutation 29: stale template stamp (rc=${drift_rc} out=${got})"
fi

# 30. zero-byte installed workflow reports drift instead of dying silently
mkdir -p "$MUT/30/ci" "$MUT/30-repo/.github/workflows"
cat > "$MUT/30/ci/planted.yml" <<'YML'
name: planted-zero-byte
on: push
permissions: {}
YML
stamp_fixture "$MUT/30/ci/planted.yml"
: > "$MUT/30-repo/.github/workflows/planted.yml"
drift_rc=0
got=$("$DRIFT_SH" --gibson "$MUT/30" --repo "$MUT/30-repo" 2>&1) || drift_rc=$?
if [[ "$drift_rc" -eq 1 ]] && printf '%s\n' "$got" | grep -F "installed stamp missing" >/dev/null \
  && printf '%s\n' "$got" | grep -F "drift=1" >/dev/null; then
  ok "mutation 30: zero-byte install emits DRIFT + summary"
  echo "  PLANTED[30] FAIL — $got"
else
  bad "mutation 30: zero-byte install (rc=${drift_rc} out=${got})"
fi

# 31. stamp-only installed workflow reports content drift + summary
mkdir -p "$MUT/31/ci" "$MUT/31-repo/.github/workflows"
cat > "$MUT/31/ci/planted.yml" <<'YML'
name: planted-stamp-only
on: push
permissions: {}
YML
stamp_fixture "$MUT/31/ci/planted.yml"
: > "$MUT/31-repo/.github/workflows/empty-body"
empty_hash=$(fixture_content_hash "$MUT/31-repo/.github/workflows/empty-body")
printf '# gibson-template-version: sha256:%s\n' "$empty_hash" > "$MUT/31-repo/.github/workflows/planted.yml"
drift_rc=0
got=$("$DRIFT_SH" --gibson "$MUT/31" --repo "$MUT/31-repo" 2>&1) || drift_rc=$?
if [[ "$drift_rc" -eq 1 ]] && printf '%s\n' "$got" | grep -F "content hash mismatch" >/dev/null \
  && printf '%s\n' "$got" | grep -F "drift=1" >/dev/null; then
  ok "mutation 31: stamp-only install emits DRIFT + summary"
  echo "  PLANTED[31] FAIL — $got"
else
  bad "mutation 31: stamp-only install (rc=${drift_rc} out=${got})"
fi

# 32. --strict-missing turns an optional missing install into exit 1
mkdir -p "$MUT/32/ci" "$MUT/32-repo"
cat > "$MUT/32/ci/planted.yml" <<'YML'
name: planted-strict-missing
on: push
permissions: {}
YML
stamp_fixture "$MUT/32/ci/planted.yml"
default_rc=0
"$DRIFT_SH" --gibson "$MUT/32" --repo "$MUT/32-repo" >/dev/null 2>&1 || default_rc=$?
strict_rc=0
strict_out=$("$DRIFT_SH" --gibson "$MUT/32" --repo "$MUT/32-repo" --strict-missing 2>&1) || strict_rc=$?
if [[ "$default_rc" -eq 0 && "$strict_rc" -eq 1 ]] \
  && printf '%s\n' "$strict_out" | grep -F "MISSING install" >/dev/null; then
  ok "mutation 32: --strict-missing fails while default remains optional"
  echo "  PLANTED[32] FAIL — $strict_out"
else
  bad "mutation 32: strict missing (default=${default_rc} strict=${strict_rc} out=${strict_out})"
fi

# 33/34. actual destructive-flag scan: installed workflow is clean; planted use fires.
mkdir -p "$MUT/33/repo/.github/workflows"
cp "$REPO_ROOT/ci/schema-guard.yml" "$MUT/33/repo/.github/workflows/schema-guard.yml"
git -C "$MUT/33/repo" init -q
git -C "$MUT/33/repo" add .
scan_rc=0
got=$(destructive_flag_hits "$MUT/33/repo") || scan_rc=$?
if [[ "$scan_rc" -eq 1 && -z "$got" ]]; then
  ok "mutation 33: clean repo containing installed schema guard does not self-match"
else
  bad "mutation 33: clean schema-guard control (rc=${scan_rc} out=${got})"
fi
loss_a='--accept-data'; loss_b='-loss'
mkdir -p "$MUT/33/repo/scripts"
printf '%s\n' "prisma migrate deploy ${loss_a}${loss_b}" > "$MUT/33/repo/scripts/migrate.sh"
git -C "$MUT/33/repo" add scripts/migrate.sh
scan_rc=0
got=$(destructive_flag_hits "$MUT/33/repo") || scan_rc=$?
if [[ "$scan_rc" -eq 0 ]] && printf '%s\n' "$got" | grep -F "scripts/migrate.sh:1" >/dev/null; then
  ok "mutation 34: planted destructive migration flag fails with file:line"
  echo "  PLANTED[34] FAIL — $got"
else
  bad "mutation 34: planted destructive flag (rc=${scan_rc} out=${got})"
fi

# 35. a differently named summary variable must not satisfy visibility
mkdir -p "$MUT/35/ci"
cat > "$MUT/35/ci/planted.yml" <<'YML'
name: planted-summary-prefix
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - name: announce
        if: always()
        run: |
          echo "::warning::soft job"
          echo "soft" >> "$GITHUB_STEP_SUMMARY_UNUSED"
YML
got=$(check_visible_skip "$MUT/35") || true
assert_planted 35 "summary variable prefix is not GITHUB_STEP_SUMMARY" \
  "continue-on-error job missing dedicated announce step" "$got"

# 36/37. non-always if spellings cannot masquerade as an unconditional first step
for n in 36 37; do mkdir -p "$MUT/$n/ci"; done
cat > "$MUT/36/ci/planted.yml" <<'YML'
name: planted-spaced-if
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - name: announce
        if : ${{ github.ref == 'refs/heads/main' }}
        run: |
          echo "::warning::soft job"
          echo "soft" >> "$GITHUB_STEP_SUMMARY"
YML
cat > "$MUT/37/ci/planted.yml" <<'YML'
name: planted-quoted-if
on: push
permissions: {}
jobs:
  j:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - name: announce
        'if': ${{ github.event_name == 'schedule' }}
        run: |
          echo "::warning::soft job"
          echo "soft" >> "$GITHUB_STEP_SUMMARY"
YML
got=$(check_visible_skip "$MUT/36") || true
assert_planted 36 "spaced non-always if key is disqualified" \
  "continue-on-error job missing dedicated announce step" "$got"
got=$(check_visible_skip "$MUT/37") || true
assert_planted 37 "quoted non-always if key is disqualified" \
  "continue-on-error job missing dedicated announce step" "$got"

# 38/39. allowed least-privilege self-gate and PR-only cancellation controls.
mkdir -p "$MUT/38/.github/workflows" "$MUT/39/ci"
cat > "$MUT/38/.github/workflows/planted.yml" <<'YML'
name: planted-live-read-only
on: push
permissions:
  contents: read
jobs: {}
YML
got=$(check_permissions "$MUT/38") || true
assert_clean 38 "live workflow top-level contents: read is allowed" "$got"
cat > "$MUT/39/ci/planted.yml" <<'YML'
name: planted-pr-only-cancel
on:
  pull_request:
  schedule:
    - cron: "0 1 * * *"
permissions: {}
concurrency:
  group: x
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs: {}
YML
got=$(check_concurrency "$MUT/39") || true
assert_clean 39 "PR-only cancellation expression is accepted" "$got"

# --- #274 machine-readable self-gate contract --------------------------------
echo "# #274 command consistency (AGENTS.md, gate.json, sensors job, run-all --no-quarantine)"

GATE_JSON="$REPO_ROOT/.agents/gate.json"
CANON_TEST='bash scripts/tests/run-all.sh --no-quarantine'
if [[ ! -f "$GATE_JSON" ]]; then
  bad "missing .agents/gate.json (Gibson must not fall through to generic defaults)"
else
  gate_vals=$(node -e '
    const g=require(process.argv[1]);
    const keys=["generate","typecheck","lint","test","build"];
    for (const k of keys) {
      if (!Object.prototype.hasOwnProperty.call(g,k)) process.exit(2);
      process.stdout.write(k+"="+JSON.stringify(g[k])+"\n");
    }
  ' "$GATE_JSON") || { bad "gate.json is not parseable or missing a step key"; gate_vals=""; }
  if [[ -n "$gate_vals" ]]; then
    printf '%s\n' "$gate_vals" | grep -x 'generate=""' >/dev/null \
      && ok "gate.json generate is an explicit empty string" \
      || bad "gate.json generate is not an explicit empty string"
    printf '%s\n' "$gate_vals" | grep -x 'typecheck=""' >/dev/null \
      && ok "gate.json typecheck is an explicit empty string" \
      || bad "gate.json typecheck is not an explicit empty string"
    printf '%s\n' "$gate_vals" | grep -x 'lint=""' >/dev/null \
      && ok "gate.json lint is an explicit empty string" \
      || bad "gate.json lint is not an explicit empty string"
    printf '%s\n' "$gate_vals" | grep -x 'build=""' >/dev/null \
      && ok "gate.json build is an explicit empty string" \
      || bad "gate.json build is not an explicit empty string"
    printf '%s\n' "$gate_vals" | grep -x "test=\"${CANON_TEST}\"" >/dev/null \
      && ok "gate.json test is exactly ${CANON_TEST}" \
      || bad "gate.json test drifted (got $(printf '%s\n' "$gate_vals" | grep '^test='))"
  fi
fi

if grep -Fq "$CANON_TEST" "$REPO_ROOT/AGENTS.md" \
  && grep -Fq '.agents/gate.json' "$REPO_ROOT/AGENTS.md"; then
  ok "AGENTS.md names .agents/gate.json and the canonical --no-quarantine command"
else
  bad "AGENTS.md missing machine-readable twin pointer or canonical command"
fi
if tr '\n' ' ' < "$REPO_ROOT/AGENTS.md" | grep -F 'generate → typecheck → lint → test → build' >/dev/null; then
  ok "AGENTS.md still states the full five-step green gate (twin does not weaken it)"
else
  bad "AGENTS.md no longer states generate → typecheck → lint → test → build"
fi

WF="$REPO_ROOT/.github/workflows/gibson-self-gate.yml"
sensors_cmd=$(awk '
  /^  sensors:/ { in_job=1; next }
  in_job && /^  [A-Za-z0-9_]+:/ { in_job=0 }
  in_job && /^      - name: Run every sensor$/ { in_step=1; next }
  in_step && /^      - name:/ { in_step=0 }
  in_job && in_step && /^        run:/ {
    sub(/^        run:[[:space:]]*/, "")
    print
    exit
  }
' "$WF")
if [[ "$sensors_cmd" == "$CANON_TEST" ]]; then
  ok "workflow sensors job Run every sensor is exactly ${CANON_TEST}"
else
  bad "workflow sensors job drifted (got '${sensors_cmd}', want exactly '${CANON_TEST}')"
fi

echo "# #274 metric-contract failure binds into ordinary GREEN/RED before n_fail"
if awk '
  /FAILED="\$FAILED metric-contract"/ { bind=NR }
  /n_fail=\$\(echo "\$FAILED"/ { nfail=NR }
  END { if (bind && nfail && bind < nfail) exit 0; exit 1 }
' "$REPO_ROOT/scripts/tests/run-all.sh"; then
  ok "metric-contract is bound into FAILED before n_fail is computed"
else
  bad "metric-contract failure is not bound into FAILED before n_fail"
fi

echo "# #278 legacy-sentinel attribution reconciles before the GREEN/RED bind"
RA="$REPO_ROOT/scripts/tests/run-all.sh"
if awk '
  /gibson_metrics_reconcile_legacy_sentinels/ && $0 !~ /\(\)/ { rec=NR }
  /FAILED="\$FAILED metric-contract"/ { bind=NR }
  /n_fail=\$\(echo "\$FAILED"/ { nfail=NR }
  END { if (rec && bind && nfail && rec < bind && bind < nfail) exit 0; exit 1 }
' "$RA"; then
  ok "legacy-sentinel reconcile runs before metric-contract bind and n_fail"
else
  bad "legacy-sentinel reconcile is not ordered before metric-contract bind / n_fail"
fi
if grep -Fq 'duplicate sentinel attribution' "$RA" \
  && grep -Fq 'legacy-sentinel name/count drift' "$RA" \
  && grep -Fq 'explicit assertions and sentinel' "$RA"; then
  ok "run-all.sh fails closed on duplicate sentinel, name/count drift, and dual contribution"
else
  bad "run-all.sh missing fail-closed sentinel attribution guards"
fi
# Non-vacuity: deleting each guard string must turn the corresponding grep red.
_mut_src=$(mktemp "${TMPDIR:-/tmp}/gibson-278-runall.XXXXXX")
sed -e '/duplicate sentinel attribution/d' \
    -e '/legacy-sentinel name\/count drift/d' \
    -e '/explicit assertions and sentinel/d' \
    "$RA" > "$_mut_src"
if grep -Fq 'duplicate sentinel attribution' "$_mut_src" \
   || grep -Fq 'legacy-sentinel name/count drift' "$_mut_src" \
   || grep -Fq 'explicit assertions and sentinel' "$_mut_src"; then
  bad "mutation: deleting sentinel attribution guards still grepped true (vacuous)"
else
  ok "mutation: deleting sentinel attribution guards turns the source check red"
fi
rm -f "$_mut_src"
unset _mut_src

echo "# #274 run-all metric contract (no static count, no second gate.json parser)"
if grep -E 'require\(.*gate\.json|readFileSync\([^)]*gate\.json' \
     "$REPO_ROOT/scripts/tests/run-all.sh" >/dev/null; then
  bad "run-all.sh parses .agents/gate.json (second config parser forbidden)"
else
  ok "run-all.sh does not parse .agents/gate.json"
fi
if grep -E 'echo[[:space:]]+["'\'']GIBSON_TEST_METRICS total=[0-9]+' \
     "$REPO_ROOT/scripts/tests/run-all.sh" >/dev/null; then
  bad "run-all.sh appends a static GIBSON_TEST_METRICS count"
else
  ok "run-all.sh does not append a static GIBSON_TEST_METRICS count"
fi

echo "# #279 metrics-contract-fixture early exclusive seam (same-artifact oracle)"
RA="$REPO_ROOT/scripts/tests/run-all.sh"

# Source: production classifier/contributor/reconciler/binder/emitter defined once.
_prod_ok=1
_fn=""
_n=0
for _fn in gibson_metrics_classify gibson_metrics_contribute \
  gibson_metrics_reconcile_legacy_sentinels \
  gibson_run_all_bind_and_print_verdict \
  gibson_metrics_emit_aggregate_or_fail; do
  _n=$(grep -c "^${_fn}()" "$RA" || true)
  if [[ "$_n" -ne 1 ]]; then
    _prod_ok=0
    break
  fi
done
if [[ "$_prod_ok" -eq 1 ]]; then
  ok "production metrics functions are defined exactly once"
else
  bad "production metrics functions are missing or duplicated (${_fn}=${_n})"
fi
unset _prod_ok _fn _n

# Source: fixture runner calls the shared production path, not a copied footer.
if awk '
  /^gibson_run_metrics_contract_fixture\(\)/ { p=1; next }
  p && /^# GIBSON_METRICS_CONTRACT_FIXTURE_DISPATCH/ { p=0 }
  p && /if \[\[ "\$METRICS_CONTRACT_FIXTURE" -eq 1 \]\]/ { p=0 }
  p && /gibson_metrics_contribute/ { c=1 }
  p && /gibson_run_all_bind_and_print_verdict/ { b=1 }
  p && /gibson_metrics_emit_aggregate_or_fail/ { e=1 }
  p && /echo[[:space:]]+["'\''"]GIBSON_TEST_METRICS total=[0-9]+/ { stat=1 }
  END { if (c && b && e && !stat) exit 0; exit 1 }
' "$RA"; then
  ok "fixture runner calls shared contribute/bind/emit (no static aggregate)"
else
  bad "fixture runner does not reuse the production contribute/bind/emit path"
fi

# Source: ordinary path still calls the same functions after the fixture dispatch.
if awk '
  /if \[\[ "\$METRICS_CONTRACT_FIXTURE" -eq 1 \]\]/ { eq=NR }
  /gibson_run_metrics_contract_fixture$/ { if (eq && NR <= eq+3) d=eq }
  /for suite in scripts\/tests\/\*\.test.sh/ { s=NR }
  s && /gibson_metrics_contribute/ { c=NR }
  /gibson_run_all_bind_and_print_verdict/ && $0 !~ /\(\)/ { b=NR }
  /gibson_metrics_emit_aggregate_or_fail/ && $0 !~ /\(\)/ { e=NR }
  END { if (d && s && c && b && e && d < s && s <= c && c < b && b < e) exit 0; exit 1 }
' "$RA"; then
  ok "ordinary path calls shared contribute/bind/emit after fixture dispatch"
else
  bad "ordinary path no longer shares contribute/bind/emit after fixture dispatch"
fi

# Conditional/dispatch contract: parse+validate early without executing;
# skip ordinary preamble when selected; define production functions once;
# dispatch after those definitions and before sensor suites.
_279_conditional_contract() {
  awk '
    /if \[\[ "\$METRICS_CONTRACT_FIXTURE" -eq 1 \]\][[:space:]]*; then/ {
      n_eq1++
      eq1[n_eq1]=NR
    }
    /if \[\[ "\$METRICS_CONTRACT_FIXTURE" -ne 1 \]\][[:space:]]*; then/ {
      n_ne1++
      skip_if=NR
    }
    /cannot be combined/ { comb=NR }
    /echo "== toolchain"/ { tc=NR }
    /SH_FILES=\$\(find scripts adapters/ { fd=NR }
    /source "\$WALL_TIMEOUT_LIB"/ { wt=NR }
    /echo "== injection-scan"/ { inj=NR }
    /if \[\[ "\$TIMEOUT" -gt 0 \]\] && ! suite_timeout_capable/ { to=NR }
    /echo "== sensors"/ { sensors=NR }
    /for suite in scripts\/tests\/\*\.test.sh/ { su=NR }
    /^# --- aggregate metrics/ { agg=NR }
    /^gibson_metrics_classify\(\)/ { classify=NR }
    /^gibson_run_metrics_contract_fixture\(\)/ { fixdef=NR }
    /gibson_run_metrics_contract_fixture/ && $0 !~ /\(\)/ { calls[++n_calls]=NR }
    /exit \$\?/ { exits[++n_exits]=NR }
    END {
      if (n_ne1 != 1 || n_eq1 < 2) exit 1
      parse_if=eq1[1]
      disp_if=eq1[n_eq1]
      if (!parse_if || !skip_if || !disp_if || !comb || !agg) exit 1
      if (!tc || !fd || !wt || !inj || !to || !sensors || !su) exit 1
      if (!classify || !fixdef) exit 1
      parse_exec=0
      disp_call=0
      for (i=1; i<=n_calls; i++) {
        if (calls[i] > parse_if && calls[i] < skip_if) parse_exec=1
        if (calls[i] > disp_if && calls[i] <= disp_if+4) disp_call=calls[i]
      }
      disp_exit=0
      for (i=1; i<=n_exits; i++) {
        if (exits[i] > disp_if && exits[i] <= disp_if+4) disp_exit=exits[i]
      }
      if (parse_exec) exit 1
      if (!disp_call || !disp_exit) exit 1
      if (!(parse_if < skip_if && comb > parse_if && comb < skip_if)) exit 1
      if (!(skip_if < tc && skip_if < fd && skip_if < wt && skip_if < inj && skip_if < to)) exit 1
      if (!(tc < agg && fd < agg && wt < agg && inj < agg && to < agg)) exit 1
      if (!(agg < classify && classify < fixdef && fixdef < disp_if)) exit 1
      if (!(disp_if < disp_call && disp_call < disp_exit && disp_exit <= disp_if+4)) exit 1
      if (!(disp_if < sensors && disp_if < su && sensors < su)) exit 1
      exit 0
    }
  ' "$1"
}

if _279_conditional_contract "$RA"; then
  ok "fixture parse/skip/dispatch contract: validate early, skip preamble, dispatch after functions"
else
  bad "fixture parse/skip/dispatch contract failed (would fall through or execute too early)"
fi

# Source: fixture presence is a pre-scan; ordinary argv keeps origin/main
# immediate --help / --list-quarantine / --self-test-toolchain / unknown-flag
# behavior. Fixture mode is the one and only argument.
_279_parser_contract() {
  awk '
    /for [_A-Za-z0-9]+ in "\$@"/ { forloop=NR }
    forloop && !prescan_set && /METRICS_CONTRACT_FIXTURE=1/ {
      if (NR <= forloop + 8) prescan_set=NR
    }
    /if \[\[ "\$METRICS_CONTRACT_FIXTURE" -eq 1 \]\][[:space:]]*; then/ {
      n_eq1++
      if (n_eq1 == 1) parse_if=NR
    }
    parse_if && !sole && /\$# -ne 1/ {
      if (NR > parse_if && NR <= parse_if + 8) sole=NR
    }
    /while \[\[ \$# -gt 0 \]\]/ { whiles[++nwhile]=NR }
    /-h\|--help\) usage; exit 0/ { help_imm=NR }
    /--list-quarantine\)/ { list_arm=NR }
    /--self-test-toolchain\)/ { st_arm=NR }
    /WANT_HELP=1/ { want=NR }
    /--metrics-contract-fixture\)/ { fixture_arm=NR }
    END {
      if (!forloop || !prescan_set || !parse_if || !sole) exit 1
      if (!(prescan_set < parse_if && sole > parse_if)) exit 1
      if (nwhile < 1) exit 1
      ord=whiles[nwhile]
      if (ord < parse_if) exit 1
      if (!help_imm || help_imm < ord) exit 1
      if (!list_arm || list_arm < ord) exit 1
      if (!st_arm || st_arm < ord) exit 1
      if (list_arm > help_imm || st_arm > help_imm) exit 1
      if (want) exit 1
      if (fixture_arm) exit 1
      exit 0
    }
  ' "$1"
}

if _279_parser_contract "$RA"; then
  ok "fixture pre-scan plus origin/main ordinary parser (immediate help/list/self-test)"
else
  bad "ordinary parser contract failed (deferred flags or missing fixture sole-arg)"
fi

# Non-vacuity: the contract must test the actual skip/dispatch conditions.
_mut_src=$(mktemp "${TMPDIR:-/tmp}/gibson-279-runall.XXXXXX")
sed 's/METRICS_CONTRACT_FIXTURE" -ne 1/METRICS_CONTRACT_FIXTURE" -eq 1/' "$RA" > "$_mut_src"
if _279_conditional_contract "$_mut_src"; then
  bad "mutation: flipping preamble skip to -eq 1 still passed the conditional contract"
else
  ok "mutation: flipping preamble skip to -eq 1 turns the conditional contract red"
fi
sed '/if \[\[ "\$METRICS_CONTRACT_FIXTURE" -ne 1 \]\]/d' "$RA" > "$_mut_src"
if _279_conditional_contract "$_mut_src"; then
  bad "mutation: deleting preamble skip-if still passed the conditional contract"
else
  ok "mutation: deleting preamble skip-if turns the conditional contract red"
fi
sed '/^  gibson_run_metrics_contract_fixture$/d' "$RA" > "$_mut_src"
if _279_conditional_contract "$_mut_src"; then
  bad "mutation: deleting fixture dispatch call still passed the conditional contract"
else
  ok "mutation: deleting fixture dispatch call turns the conditional contract red"
fi
sed 's/\$# -ne 1/\$# -eq 1/' "$RA" > "$_mut_src"
if _279_parser_contract "$_mut_src"; then
  bad "mutation: inverting fixture sole-arg still passed the parser contract"
else
  ok "mutation: inverting fixture sole-arg turns the parser contract red"
fi
sed 's/-h|--help) usage; exit 0/-h|--help) WANT_HELP=1; shift/' "$RA" > "$_mut_src"
if _279_parser_contract "$_mut_src"; then
  bad "mutation: deferring --help still passed the parser contract"
else
  ok "mutation: deferring --help turns the parser contract red"
fi
sed '/for _gibson_arg in "\$@"/d' "$RA" > "$_mut_src"
if _279_parser_contract "$_mut_src"; then
  bad "mutation: deleting fixture pre-scan still passed the parser contract"
else
  ok "mutation: deleting fixture pre-scan turns the parser contract red"
fi
rm -f "$_mut_src"
unset _mut_src
unset -f _279_conditional_contract
unset -f _279_parser_contract

if grep -Fq 'internal contract-test seam only' "$RA" \
   && grep -Fq 'not a complete gate or release substitute' "$RA"; then
  ok "fixture mode is inventoried as incomplete and non-gating"
else
  bad "fixture mode is missing the non-gating inventory text"
fi

# Exclusive combinations: every ordinary mode/flag, any extra/repeated
# argument, and reverse-order fixture combinations exit 2 with the exclusive
# non-gating message (not the ordinary unknown-flag path).
_exclusive_probe() {
  local desc="$1"
  shift
  local out rc=0
  out=$(bash "$RA" "$@" 2>&1) || rc=$?
  if [[ "$rc" -eq 2 ]] \
     && printf '%s\n' "$out" | grep -F 'cannot be combined' >/dev/null \
     && printf '%s\n' "$out" | grep -F 'not a complete gate' >/dev/null \
     && ! printf '%s\n' "$out" | grep -F 'unknown argument' >/dev/null; then
    ok "fixture exclusive with ${desc} (exit 2)"
  else
    bad "fixture did not reject ${desc} (rc=${rc})"
  fi
}
_exclusive_probe "--only" --metrics-contract-fixture --only args.test
_exclusive_probe "--timeout" --metrics-contract-fixture --timeout 1
_exclusive_probe "--no-quarantine" --metrics-contract-fixture --no-quarantine
_exclusive_probe "--list-quarantine" --metrics-contract-fixture --list-quarantine
_exclusive_probe "--self-test-toolchain" --metrics-contract-fixture --self-test-toolchain
_exclusive_probe "--quiet" --metrics-contract-fixture --quiet
_exclusive_probe "--help" --metrics-contract-fixture --help
_exclusive_probe "repeated fixture" --metrics-contract-fixture --metrics-contract-fixture
_exclusive_probe "unknown extra" --metrics-contract-fixture --definitely-not-a-flag
_exclusive_probe "reverse --help" --help --metrics-contract-fixture
_exclusive_probe "reverse --list-quarantine" --list-quarantine --metrics-contract-fixture
_exclusive_probe "reverse --self-test-toolchain" --self-test-toolchain --metrics-contract-fixture
unset -f _exclusive_probe

# Ordinary parser parity with current-main immediate-exit semantics. Trailing
# junk after --help / --list-quarantine / --self-test-toolchain must not become
# unknown-flag failures. Do not invent a stricter ordinary contract.
_ordinary_same() {
  local desc="$1"
  shift
  local bare_rc=0 trail_rc=0
  local bare trail
  bare=$(bash "$RA" "$1" 2>&1) || bare_rc=$?
  trail=$(bash "$RA" "$1" --definitely-not-a-flag 2>&1) || trail_rc=$?
  if [[ "$trail_rc" -eq "$bare_rc" ]] \
     && [[ "$trail" == "$bare" ]] \
     && ! printf '%s\n' "$trail" | grep -F 'unknown argument' >/dev/null; then
    ok "ordinary CLI: ${desc} matches bare ${1} (exit ${bare_rc})"
  else
    bad "ordinary CLI: ${desc} drifted (bare_rc=${bare_rc} trail_rc=${trail_rc})"
  fi
}
_ordinary_same "--help --definitely-not-a-flag" --help
_ordinary_same "--list-quarantine --definitely-not-a-flag" --list-quarantine
unset -f _ordinary_same

help_rc=0
help_out=$(bash "$RA" --help 2>&1) || help_rc=$?
if [[ "$help_rc" -eq 0 ]] \
   && printf '%s\n' "$help_out" | grep -F 'WHAT IT DOES' >/dev/null \
   && printf '%s\n' "$help_out" | grep -F 'internal contract-test seam only' >/dev/null; then
  ok "ordinary CLI: --help exits 0 with usage"
else
  bad "ordinary CLI: --help drifted (rc=${help_rc})"
fi

list_rc=0
list_out=$(bash "$RA" --list-quarantine 2>&1) || list_rc=$?
if [[ "$list_rc" -eq 0 ]] \
   && ! printf '%s\n' "$list_out" | grep -F 'unknown argument' >/dev/null; then
  ok "ordinary CLI: --list-quarantine exits 0"
else
  bad "ordinary CLI: --list-quarantine drifted (rc=${list_rc})"
fi

st_rc=0
st_out=$(bash "$RA" --self-test-toolchain 2>&1) || st_rc=$?
st_trail_rc=0
st_trail=$(bash "$RA" --self-test-toolchain --definitely-not-a-flag 2>&1) || st_trail_rc=$?
if [[ "$st_rc" -eq "$st_trail_rc" ]] \
   && printf '%s\n' "$st_out" | grep -F 'toolchain self-test' >/dev/null \
   && printf '%s\n' "$st_trail" | grep -F 'toolchain self-test' >/dev/null \
   && ! printf '%s\n' "$st_trail" | grep -F 'unknown argument' >/dev/null; then
  ok "ordinary CLI: --self-test-toolchain --definitely-not-a-flag matches bare self-test (exit ${st_rc})"
else
  bad "ordinary CLI: --self-test-toolchain trailing-arg drifted (bare_rc=${st_rc} trail_rc=${st_trail_rc})"
fi
unset help_rc help_out list_rc list_out st_rc st_out st_trail_rc st_trail

unk_rc=0
unk_out=$(bash "$RA" --definitely-not-a-flag 2>&1) || unk_rc=$?
if [[ "$unk_rc" -eq 2 ]] \
   && printf '%s\n' "$unk_out" | grep -F 'unknown argument: --definitely-not-a-flag' >/dev/null; then
  ok "ordinary CLI: unknown flag exits 2"
else
  bad "ordinary CLI: unknown flag drifted (rc=${unk_rc})"
fi
unset unk_rc unk_out

# Capture fixture status and output exactly once.
fixture_rc=0
fixture_out=$(bash "$RA" --metrics-contract-fixture 2>&1) || fixture_rc=$?

# Reject nonzero or empty output before any parsing/arithmetic.
if [[ "$fixture_rc" -ne 0 ]]; then
  bad "metrics-contract-fixture exited ${fixture_rc} (want 0): $(printf '%s\n' "$fixture_out" | tail -n 8)"
elif [[ -z "$fixture_out" ]]; then
  bad "metrics-contract-fixture produced empty output"
else
  ok "metrics-contract-fixture exited 0 with nonempty output"
fi

# Same-artifact oracle: exact 20/4/3, footer order, wall before footer, mutations.
fixture_artifact_ok() {
  local text="$1"
  # Empty or whitespace-only is red before arithmetic.
  if [[ -z "$text" ]] || ! printf '%s\n' "$text" | grep . >/dev/null; then
    return 1
  fi
  printf '%s\n' "$text" | grep -F 'metrics mutation: duplicate machine metric fails closed' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: non-terminal machine evidence fails closed' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: malformed machine metric fails closed' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: malformed machine JSON fails closed' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: negative machine metric fails closed' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: fractional machine metric fails closed' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: overflow machine metric fails closed' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: prefix reserved counters fail closed' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: duplicate sentinel attribution refuses' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: name/count drift refuses' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: one suite cannot contribute both explicit assertions and a sentinel' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: explicit plus sign on a tally count fails closed' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: metric-contract failure is RED without GREEN or aggregate metrics' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: ordinary suite failure is RED with aggregate metrics' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'metrics mutation: green run still prints GREEN and aggregate metrics' >/dev/null || return 1
  printf '%s\n' "$text" | grep -F 'internal contract-test seam; not a complete gate' >/dev/null || return 1
  if printf '%s\n' "$text" | grep -E '^== (toolchain|shellcheck|bash -n|bash 3\.2|bash-4|SCRIPT_DIR|info/warn|tool guards|vendored|mjs unknown-flag|injection-scan|sensors)' >/dev/null; then
    return 1
  fi
  if printf '%s\n' "$text" | grep -E '^run-all: toolchain self-test' >/dev/null; then
    return 1
  fi
  if printf '%s\n' "$text" | grep -E 'args\.test\.sh:' >/dev/null; then
    return 1
  fi
  printf '%s\n' "$text" | awk '
    /^run-all metrics-contract-fixture wall: [0-9]+s$/ { w++ }
    /^run-all legacy-sentinels: metrics-contract-fixture\.legacy\.test\.sh$/ { n++ }
    /^run-all metric-subtotals: explicit-assertions=19 legacy-sentinels=1$/ { d++ }
    /^GIBSON_TEST_METRICS total=20 skipped=4 todo=3$/ { m++ }
    NF { q=pprev; pprev=prev; prev=last; last=$0 }
    END {
      if (w != 1) exit 1
      if (n != 1) exit 1
      if (d != 1) exit 1
      if (m != 1) exit 1
      if (last !~ /^GIBSON_TEST_METRICS total=20 skipped=4 todo=3$/) exit 1
      if (prev !~ /^run-all metric-subtotals: explicit-assertions=19 legacy-sentinels=1$/) exit 1
      if (pprev !~ /^run-all legacy-sentinels: metrics-contract-fixture\.legacy\.test\.sh$/) exit 1
      if (q !~ /^run-all metrics-contract-fixture wall: [0-9]+s$/) exit 1
      exit 0
    }
  '
}

if [[ "$fixture_rc" -eq 0 && -n "$fixture_out" ]] && fixture_artifact_ok "$fixture_out"; then
  ok "fixture artifact is exact 20/4/3 with wall-before-footer and mutation evidence"
else
  bad "fixture artifact failed the same-artifact oracle (rc=${fixture_rc}): $(printf '%s\n' "$fixture_out" | tail -n 12)"
fi

metric_line=$(printf '%s\n' "$fixture_out" | grep -E '^GIBSON_TEST_METRICS total=[0-9]+ skipped=[0-9]+ todo=[0-9]+$' || true)
metric_n=$(printf '%s\n' "$metric_line" | grep -c . || true)
if [[ "$fixture_rc" -eq 0 && "$metric_n" -eq 1 && "$metric_line" == "GIBSON_TEST_METRICS total=20 skipped=4 todo=3" ]]; then
  ok "fixture emits exactly one terminal GIBSON_TEST_METRICS total=20 skipped=4 todo=3"
else
  bad "fixture metric lines=${metric_n} (want exact 20/4/3): ${metric_line}"
fi
diag_line=$(printf '%s\n' "$fixture_out" | grep -E '^run-all metric-subtotals: explicit-assertions=[0-9]+ legacy-sentinels=[0-9]+$' || true)
if [[ "$diag_line" == "run-all metric-subtotals: explicit-assertions=19 legacy-sentinels=1" ]]; then
  ok "fixture subtotals are explicit-assertions=19 legacy-sentinels=1"
else
  bad "fixture subtotals drifted: ${diag_line}"
fi
named_line=$(printf '%s\n' "$fixture_out" | grep -E '^run-all legacy-sentinels:( [A-Za-z0-9._-]+)*$' || true)
named_n=$(printf '%s\n' "$named_line" | grep -c . || true)
if [[ "$named_n" -eq 1 && "$named_line" == "run-all legacy-sentinels: metrics-contract-fixture.legacy.test.sh" ]]; then
  ok "fixture names exactly one legacy sentinel"
else
  bad "fixture named legacy-sentinel lines=${named_n}: ${named_line}"
fi
if printf '%s\n' "$fixture_out" | grep -E '^run-all metrics-contract-fixture wall: [0-9]+s$' >/dev/null; then
  ok "fixture prints metrics-contract-fixture wall before the footer"
else
  bad "fixture missing metrics-contract-fixture wall receipt"
fi

parse_rc=0
parse_out=""
if [[ "$fixture_rc" -ne 0 || -z "$fixture_out" ]]; then
  bad "test-integrity skipped: fixture artifact was empty or nonzero"
else
  parse_out=$(printf '%s\n' "$fixture_out" | node "$REPO_ROOT/scripts/test-integrity.mjs" parse --input /dev/stdin 2>&1) || parse_rc=$?
  if [[ "$parse_rc" -eq 0 ]] \
     && printf '%s\n' "$parse_out" | grep '"total": 20' >/dev/null \
     && printf '%s\n' "$parse_out" | grep '"skipped": 4' >/dev/null \
     && printf '%s\n' "$parse_out" | grep '"todo": 3' >/dev/null; then
    ok "test-integrity parses the fixture aggregate as 20/4/3"
  else
    bad "test-integrity cannot parse fixture output (rc=${parse_rc}): ${parse_out}"
  fi
fi

if [[ "$fixture_rc" -eq 0 ]] \
   && ! printf '%s\n' "$fixture_out" | grep -E '^== (toolchain|shellcheck|bash -n|bash 3\.2|bash-4|SCRIPT_DIR|info/warn|tool guards|vendored|mjs unknown-flag|injection-scan|sensors)' >/dev/null \
   && ! printf '%s\n' "$fixture_out" | grep -E '^run-all: toolchain self-test' >/dev/null; then
  ok "fixture did not execute the skipped ordinary preamble"
else
  bad "fixture executed the skipped ordinary preamble"
fi

# Non-vacuity mutations against the same oracle (counted, deletion-sensitive).
if ! fixture_artifact_ok ""; then
  ok "mutation: empty fixture output is rejected before parsing"
else
  bad "mutation: empty fixture output still passed the oracle"
fi

_zero_agg=$(printf '%s\n' "$fixture_out" | sed \
  -e 's/GIBSON_TEST_METRICS total=20 skipped=4 todo=3/GIBSON_TEST_METRICS total=0 skipped=0 todo=0/' \
  -e 's/explicit-assertions=19/explicit-assertions=0/')
if fixture_artifact_ok "$_zero_agg"; then
  bad "mutation: zero aggregate still passed the oracle"
else
  ok "mutation: zero aggregate turns the oracle red"
fi

_no_mut=$(printf '%s\n' "$fixture_out" | grep -v 'metrics mutation:' || true)
if fixture_artifact_ok "$_no_mut"; then
  bad "mutation: deleting mutation evidence still passed the oracle"
else
  ok "mutation: missing mutation evidence turns the oracle red"
fi

_reorder=$(printf '%s\n' \
  'run-all metric-subtotals: explicit-assertions=19 legacy-sentinels=1' \
  'run-all legacy-sentinels: metrics-contract-fixture.legacy.test.sh' \
  'GIBSON_TEST_METRICS total=20 skipped=4 todo=3')
# Keep mutation evidence from the live artifact but swap the footer order.
_reorder_full=$(printf '%s\n' "$fixture_out" | awk '
  /^run-all metrics-contract-fixture wall: / { next }
  /^run-all legacy-sentinels:/ { next }
  /^run-all metric-subtotals:/ { next }
  /^GIBSON_TEST_METRICS total=/ { next }
  { print }
')
_reorder_full=$(printf '%s\n' "$_reorder_full" \
  'run-all metrics-contract-fixture wall: 0s' \
  'run-all metric-subtotals: explicit-assertions=19 legacy-sentinels=1' \
  'run-all legacy-sentinels: metrics-contract-fixture.legacy.test.sh' \
  'GIBSON_TEST_METRICS total=20 skipped=4 todo=3')
if fixture_artifact_ok "$_reorder_full"; then
  bad "mutation: reordered footer still passed the oracle"
else
  ok "mutation: reordered footer turns the oracle red"
fi

_missing_name=$(printf '%s\n' "$fixture_out" | sed 's/run-all legacy-sentinels: metrics-contract-fixture.legacy.test.sh/run-all legacy-sentinels:/')
if fixture_artifact_ok "$_missing_name"; then
  bad "mutation: missing legacy name still passed the oracle"
else
  ok "mutation: missing legacy name turns the oracle red"
fi

# The empty-args_tally false-green: empty selected-suite tally arithmetic
# becomes 0 and agrees with a zero/empty aggregate under -eq. The new oracle
# must reject that artifact.
_old_empty_tally_false_green() {
  local artifact="$1"
  local args_tally args_p args_f want_total got_total got_explicit got_sent
  args_tally=$(printf '%s\n' "$artifact" | grep -oE 'args\.test\.sh: [0-9]+ passed, [0-9]+ failed' | tail -1)
  args_p=$(printf '%s\n' "$args_tally" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')
  args_f=$(printf '%s\n' "$args_tally" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')
  want_total=$((args_p + args_f))
  got_total=$(printf '%s\n' "$artifact" | grep -oE 'total=[0-9]+' | head -1 | cut -d= -f2)
  got_explicit=$(printf '%s\n' "$artifact" | grep -oE 'explicit-assertions=[0-9]+' | head -1 | cut -d= -f2)
  got_sent=$(printf '%s\n' "$artifact" | grep -oE 'legacy-sentinels=[0-9]+' | head -1 | cut -d= -f2)
  got_total=${got_total:-0}
  got_explicit=${got_explicit:-0}
  got_sent=${got_sent:-0}
  [[ "$got_total" -eq "$want_total" && "$got_explicit" -eq "$want_total" && "$got_sent" -eq 0 ]]
}
_empty_zero=$'run-all metric-subtotals: explicit-assertions=0 legacy-sentinels=0\nGIBSON_TEST_METRICS total=0 skipped=0 todo=0'
if _old_empty_tally_false_green "$_empty_zero" && ! fixture_artifact_ok "$_empty_zero"; then
  ok "mutation: empty-args_tally zero-aggregate false-green is now red"
else
  bad "mutation: empty-args_tally false-green was not turned red"
fi
if _old_empty_tally_false_green "" && ! fixture_artifact_ok ""; then
  ok "mutation: empty-artifact arithmetic false-green is now red"
else
  bad "mutation: empty-artifact arithmetic false-green was not turned red"
fi
unset _zero_agg _no_mut _reorder _reorder_full _missing_name _empty_zero
unset -f _old_empty_tally_false_green

# Alias the captured artifact for the retained footer-shape helpers below.
metric_out=$fixture_out

# Non-vacuity of the footer-shape assertion: syntactically valid footers that
# move the named diagnostic, duplicate a name, or drift the count must fail.
footer_shape_ok() {
  awk '
    /^run-all legacy-sentinels:( [A-Za-z0-9._-]+)*$/ { n++ }
    /^run-all metric-subtotals: explicit-assertions=[0-9]+ legacy-sentinels=[0-9]+$/ { d++ }
    /^GIBSON_TEST_METRICS total=[0-9]+ skipped=[0-9]+ todo=[0-9]+$/ { m++ }
    NF { pprev=prev; prev=last; last=$0 }
    END {
      if (n != 1) exit 1
      if (d != 1) exit 1
      if (m != 1) exit 1
      if (last !~ /^GIBSON_TEST_METRICS total=[0-9]+ skipped=[0-9]+ todo=[0-9]+$/) exit 1
      if (prev !~ /^run-all metric-subtotals: explicit-assertions=[0-9]+ legacy-sentinels=[0-9]+$/) exit 1
      if (pprev !~ /^run-all legacy-sentinels:( [A-Za-z0-9._-]+)*$/) exit 1
      exit 0
    }
  '
}
named_matches_subtotal() {
  awk '
    BEGIN { named=0; sent=""; dup=0 }
    /^run-all legacy-sentinels:/ {
      line=$0
      sub(/^run-all legacy-sentinels: ?/, "", line)
      named=0
      dup=0
      delete seen
      if (line != "") named=split(line, a, / /)
      for (i=1; i<=named; i++) {
        if (a[i] in seen) { dup=1 }
        seen[a[i]]=1
      }
    }
    /legacy-sentinels=[0-9]+/ && /explicit-assertions=/ {
      if (match($0, /legacy-sentinels=[0-9]+/)) {
        split(substr($0, RSTART), kv, /=/)
        sent=kv[2]+0
      }
    }
    END {
      if (dup) exit 1
      if (named == sent) exit 0
      exit 1
    }
  '
}
if printf '%s\n' "$metric_out" | named_matches_subtotal; then
  ok "live named list reconciles with legacy-sentinels subtotal"
else
  bad "live named list does not reconcile with legacy-sentinels subtotal"
fi
_good_footer=$(printf '%s\n' \
  'run-all legacy-sentinels: zeta.test.sh alpha.test.sh' \
  'run-all metric-subtotals: explicit-assertions=0 legacy-sentinels=2' \
  'GIBSON_TEST_METRICS total=2 skipped=0 todo=0')
if printf '%s\n' "$_good_footer" | footer_shape_ok \
   && printf '%s\n' "$_good_footer" | named_matches_subtotal; then
  ok "mutation control: well-formed named sentinel footer is accepted"
else
  bad "mutation control: well-formed named sentinel footer was rejected"
fi
_swap_footer=$(printf '%s\n' \
  'run-all metric-subtotals: explicit-assertions=0 legacy-sentinels=1' \
  'run-all legacy-sentinels: foo.test.sh' \
  'GIBSON_TEST_METRICS total=1 skipped=0 todo=0')
if printf '%s\n' "$_swap_footer" | footer_shape_ok; then
  bad "mutation: named diagnostic after subtotals still passed the footer shape check"
else
  ok "mutation: named diagnostic after subtotals fails the footer shape check"
fi
_dup_footer=$(printf '%s\n' \
  'run-all legacy-sentinels: foo.test.sh foo.test.sh' \
  'run-all metric-subtotals: explicit-assertions=0 legacy-sentinels=2' \
  'GIBSON_TEST_METRICS total=2 skipped=0 todo=0')
if printf '%s\n' "$_dup_footer" | named_matches_subtotal; then
  bad "mutation: duplicate sentinel name still passed name/count reconciliation"
else
  ok "mutation: duplicate sentinel name turns name/count reconciliation red"
fi
_drift_footer=$(printf '%s\n' \
  'run-all legacy-sentinels: foo.test.sh' \
  'run-all metric-subtotals: explicit-assertions=0 legacy-sentinels=2' \
  'GIBSON_TEST_METRICS total=2 skipped=0 todo=0')
if printf '%s\n' "$_drift_footer" | named_matches_subtotal; then
  bad "mutation: name/count drift still passed reconciliation"
else
  ok "mutation: name/count drift turns reconciliation red"
fi
unset _good_footer _swap_footer _dup_footer _drift_footer

echo "# #274 ordinary gate.test.sh is non-recursive and disjoint from --self-contract"
GT="$REPO_ROOT/scripts/tests/gate.test.sh"
if grep -Fq 'ordinary no-argument path (non-recursive; disjoint from --self-contract)' "$GT" \
  && grep -Fq 'opt-in --self-contract path (exact-SHA production baseline; disjoint)' "$GT"; then
  ok "gate.test.sh marks ordinary and --self-contract fixtures as disjoint"
else
  bad "gate.test.sh missing explicit disjoint-fixture markers"
fi
# Ordinary path must not invoke the production suite or --self-contract as a
# command. Quoted comparisons and usage text may name the canonical command.
if grep -nE '(^|[;|&][[:space:]]*)bash[[:space:]]+scripts/tests/run-all\.sh[[:space:]]+--no-quarantine' "$GT" >/dev/null; then
  bad "gate.test.sh ordinary path would invoke the production run-all suite"
else
  ok "gate.test.sh does not invoke bash scripts/tests/run-all.sh --no-quarantine"
fi
# A recursive self-call with --self-contract (not usage text / flag parser) is
# forbidden. Unknown-flag probes may invoke gate.test.sh with other flags.
if grep -nE 'bash[[:space:]].*gate\.test\.sh[[:space:]]+--self-contract' "$GT" >/dev/null; then
  bad "gate.test.sh invokes itself with --self-contract (would recurse under run-all)"
else
  ok "gate.test.sh does not invoke itself with --self-contract"
fi
if grep -Fq 'bash "$SELF_CONTRACT_FIXTURE/scripts/gate-baseline.sh"' "$GT" \
  && grep -Fq 'helper path escaped fixture' "$GT"; then
  ok "self-contract source invokes fixture-owned helper with in-fixture path bound"
else
  bad "self-contract source missing fixture-owned helper invocation or in-fixture bound"
fi

echo
# --- #332 / L-077: no piped quiet grep anywhere under scripts/ or .github/workflows
# A quiet grep exits at the first match. A producer still writing then takes
# SIGPIPE, and under pipefail the pipeline is 141, so an if-test on that
# pipeline silently goes false (pr-claims.test.sh on main at a6afb5f; the
# git-configure.sh label-cache check on main at cdf72ff). A consuming grep
# (stdout to /dev/null) has the same exit semantics and cannot lose that race.
# Part 1 (#334) covered scripts/tests; this is part 2: every .sh/.mjs/.yml under
# scripts/ and .github/workflows, allowlist EMPTY. Pins L-077
# (grep-q-pipefail-undercounts).
#
# A line-oriented grep regex cannot see: a `|` at the END of one line with
# `grep -q` alone on the next (Codex round 1 on #339: `seq 1 N |\n  grep -q x`
# is a reachable false green); .mjs block comments (`/* ... */` spanning
# lines with no per-line `*`); or an over-broad self-exclusion that hides a
# real violation merely because its variable name happened to start the same
# way the sensor's own source does. The perl scanner below tracks per-line
# comment state per file type and the previous line's trailing pipe instead
# of a single-pass grep pipeline; it does not exclude anything by name — the
# sensor's own source was verified empirically to not self-trigger.
GREPQ_HITS=$(perl -e '
use strict; use warnings;

my %ARG1_SHORT = map { $_ => 1 } qw(e f m A B C D d);
my %ARG1_LONG  = map { $_ => 1 } qw(regexp file max-count after-context before-context context devices directories label exclude exclude-from exclude-dir include binary-files);
my %ARG0_LONG  = map { $_ => 1 } qw(ignore-case extended-regexp fixed-strings basic-regexp perl-regexp word-regexp line-regexp invert-match count files-with-matches files-without-match line-number with-filename no-filename only-matching no-messages text recursive dereference-recursive quiet silent);

sub words {
  my ($line) = @_;
  my @w; my $cur = ""; my $i = 0; my $n = length($line);
  my $in_s = 0; my $in_d = 0;
  while ($i < $n) {
    my $c = substr($line, $i, 1);
    if ($in_s) { if ($c eq chr(39)) { $in_s = 0; } else { $cur .= $c; } $i++; next; }
    if ($in_d) {
      if ($c eq chr(34)) { $in_d = 0; $i++; next; }
      if ($c eq chr(92) && $i + 1 < $n) { $cur .= substr($line, $i, 2); $i += 2; next; }
      $cur .= $c; $i++; next;
    }
    if ($c eq chr(39)) { $in_s = 1; $i++; next; }
    if ($c eq chr(34)) { $in_d = 1; $i++; next; }
    if ($c =~ /\s/) { push @w, $cur if $cur ne ""; $cur = ""; $i++; next; }
    $cur .= $c; $i++;
  }
  push @w, $cur if $cur ne "";
  return @w;
}

# GNU grep permutes options past positional arguments by default, so a
# quiet flag can legally appear after the pattern/file words too; this
# walker never stops at a positional word, it just skips over it. It also
# tolerates leading NAME=value environment assignments before the command
# name (handled by the caller, not here).
sub grep_is_quiet {
  my (@w) = @_;
  my $i = 1; # element 0 is the literal word "grep"/"egrep"
  while ($i < @w) {
    my $w = $w[$i];
    if ($w eq "--") { $i += 1; last; }
    if ($w =~ /^--/) {
      my ($name, $eq) = $w =~ /^--([a-z-]+)(=.*)?$/;
      $name //= "";
      if ($name eq "quiet" || $name eq "silent") { return 1; }
      if ($ARG1_LONG{$name}) { $i += ($eq ? 1 : 2); next; }
      if ($ARG0_LONG{$name}) { $i += 1; next; }
      $i += 1; next;
    }
    if ($w =~ /^-(.+)$/) {
      my $body = $1;
      # Walk the bundled short letters one at a time: the first
      # value-consuming letter absorbs everything after it in this same
      # word (its attached value), or the next word if nothing follows;
      # zero-arg letters bundle freely and q may appear among them.
      my @chars = split //, $body;
      my $j = 0;
      while ($j < @chars) {
        my $ch = $chars[$j];
        if ($ARG1_SHORT{$ch}) {
          my $has_attached = ($j < $#chars);
          $i += ($has_attached ? 1 : 2);
          last;
        }
        return 1 if $ch eq "q";
        $j++;
      }
      $i += 1 if $j >= @chars; # word was all zero-arg letters, none consumed above
      next;
    }
    $i += 1; next; # a positional word (pattern/file): skip it, keep scanning (permuted options)
  }
  return 0;
}

sub pipe_segments {
  my ($line) = @_;
  my @segs; my $cur = ""; my $i = 0; my $n = length($line);
  my $in_s = 0; my $in_d = 0;
  while ($i < $n) {
    my $c = substr($line, $i, 1);
    if ($in_s) { $cur .= $c; $i++; $in_s = 0 if $c eq chr(39); next; }
    if ($in_d) {
      if ($c eq chr(92) && $i + 1 < $n) { $cur .= substr($line, $i, 2); $i += 2; next; }
      $cur .= $c; $i++; $in_d = 0 if $c eq chr(34); next;
    }
    if ($c eq chr(39)) { $in_s = 1; $cur .= $c; $i++; next; }
    if ($c eq chr(34)) { $in_d = 1; $cur .= $c; $i++; next; }
    if ($c eq chr(92) && $i + 1 < $n && substr($line, $i + 1, 1) eq "|") { $cur .= substr($line, $i, 2); $i += 2; next; }
    if ($c eq "|") {
      if ($i + 1 < $n && substr($line, $i + 1, 1) eq "|") { $cur .= "||"; $i += 2; next; }
      push @segs, $cur; $cur = ""; $i++; next;
    }
    $cur .= $c; $i++;
  }
  push @segs, $cur;
  return @segs;
}

# Only the command immediately after a pipe receives that pipe stdin; a
# later command joined by &&, ||, or ; on the same segment is a separate,
# unpiped invocation and is out of scope for THIS check (it has no SIGPIPE
# exposure since nothing feeds it via a pipe). Truncate at the first such
# unquoted boundary before scanning for a quiet grep.
sub truncate_at_command_separator {
  my ($line) = @_;
  my $i = 0; my $n = length($line);
  my $in_s = 0; my $in_d = 0;
  while ($i < $n) {
    my $c = substr($line, $i, 1);
    if ($in_s) { $i++; $in_s = 0 if $c eq chr(39); next; }
    if ($in_d) {
      if ($c eq chr(92) && $i + 1 < $n) { $i += 2; next; }
      $i++; $in_d = 0 if $c eq chr(34); next;
    }
    if ($c eq chr(39)) { $in_s = 1; $i++; next; }
    if ($c eq chr(34)) { $in_d = 1; $i++; next; }
    if ($c eq ";") { return substr($line, 0, $i); }
    if ($c eq "&") { return substr($line, 0, $i); } # single & (background) or && (and-list): either way, truncate
    if ($c eq "|" && $i + 1 < $n && substr($line, $i + 1, 1) eq "|") {
      return substr($line, 0, $i);
    }
    $i++;
  }
  return $line;
}

# A command word optionally preceded by one or more NAME=value environment
# assignments (e.g. "LC_ALL=C grep -q x").
sub segment_is_quiet_grep {
  my ($seg) = @_;
  $seg = truncate_at_command_separator($seg);
  my @w = words($seg);
  my $start = 0;
  while ($start < @w && $w[$start] =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { $start++; }
  return 0 unless $start < @w;
  return 0 unless $w[$start] eq "grep" || $w[$start] eq "egrep";
  return grep_is_quiet(@w[$start .. $#w]);
}

my $yaml_block_scalar_re = qr/^[\w.\-]+:\s*[|>][+\-0-9]*\s*$/;

sub mjs_code_lines {
  my ($path) = @_;
  open my $fh, "<", $_ or return ();
  my @raw = <$fh>; close $fh;
  my @out;
  my $in_block = 0; my $in_s = 0; my $in_d = 0; my $in_t = 0;
  for my $line (@raw) {
    chomp $line;
    my $code = "";
    my $i = 0; my $n = length($line);
    while ($i < $n) {
      if ($in_block) {
        my $close = index($line, "*/", $i);
        if ($close == -1) { $i = $n; last; }
        $i = $close + 2; $in_block = 0; next;
      }
      my $c = substr($line, $i, 1);
      if ($in_s) {
        if ($c eq chr(92) && $i + 1 < $n) { $code .= substr($line, $i + 1, 1); $i += 2; next; }
        $i++; $in_s = 0 if $c eq chr(39); next if $c eq chr(39);
        $code .= $c; next;
      }
      if ($in_d) {
        if ($c eq chr(92) && $i + 1 < $n) { $code .= substr($line, $i + 1, 1); $i += 2; next; }
        $i++; $in_d = 0 if $c eq chr(34); next if $c eq chr(34);
        $code .= $c; next;
      }
      if ($in_t) {
        if ($c eq chr(92) && $i + 1 < $n) { $code .= substr($line, $i + 1, 1); $i += 2; next; }
        $i++; $in_t = 0 if $c eq chr(96); next if $c eq chr(96);
        $code .= $c; next;
      }
      if ($c eq chr(39)) { $in_s = 1; $i++; next; }
      if ($c eq chr(34)) { $in_d = 1; $i++; next; }
      if ($c eq chr(96)) { $in_t = 1; $i++; next; }
      if ($c eq "/" && $i + 1 < $n && substr($line, $i + 1, 1) eq "/") { last; }
      if ($c eq "/" && $i + 1 < $n && substr($line, $i + 1, 1) eq "*") {
        my $close = index($line, "*/", $i + 2);
        if ($close == -1) { $in_block = 1; $i = $n; last; }
        $i = $close + 2; next;
      }
      $code .= $c; $i++;
    }
    push @out, $code;
  }
  return @out;
}

# NOTE: this does not evaluate JavaScript. A shell command assembled by
# runtime concatenation, e.g. execSync("yes x | " + "grep -q x") or a
# template interpolation whose substituted expression itself contains
# the pipe/grep text, is invisible here: each string/template literal is
# scanned as its own independent unit, never joined across a + or ${...}
# boundary. Doing that would require partially evaluating JavaScript
# expressions, a different order of problem than this text-level ratchet
# takes on. Documented limitation, not a silent gap.
sub sh_code_lines {
  my ($path) = @_;
  open my $fh, "<", $_ or return ();
  my @raw = <$fh>; close $fh;
  my @out;
  for my $line (@raw) {
    chomp $line;
    my $code = "";
    my $i = 0; my $n = length($line);
    my $in_s = 0; my $in_d = 0;
    while ($i < $n) {
      my $c = substr($line, $i, 1);
      if ($in_s) { $code .= $c; $i++; $in_s = 0 if $c eq chr(39); next; }
      if ($in_d) {
        if ($c eq chr(92) && $i + 1 < $n) { $code .= substr($line, $i, 2); $i += 2; next; }
        $code .= $c; $i++; $in_d = 0 if $c eq chr(34); next;
      }
      if ($c eq chr(39)) { $in_s = 1; $code .= $c; $i++; next; }
      if ($c eq chr(34)) { $in_d = 1; $code .= $c; $i++; next; }
      # A shell comment starts at a # that is the first character of a
      # word (start of line, or preceded by whitespace) — not e.g. the #
      # in a parameter expansion (${value#prefix}) or a bare word
      # (foo#bar).
      if ($c eq "#" && ($i == 0 || substr($line, $i - 1, 1) =~ /\s/)) { last; }
      $code .= $c; $i++;
    }
    push @out, $code;
  }
  return @out;
}

sub scan_file {
  my ($path) = @_;
  my $is_mjs = $path =~ /\.mjs$/;
  my @lines = $is_mjs ? mjs_code_lines($path) : sh_code_lines($path);
  my $prev_trim = "";
  for my $i (0 .. $#lines) {
    my $line = $lines[$i];
    (my $trim = $line) =~ s/^\s+//;
    my @segs = pipe_segments($line);
    my $hit = 0;
    for my $s (1 .. $#segs) {
      if (segment_is_quiet_grep($segs[$s])) { $hit = 1; last; }
    }
    if ($hit) {
      print "$path:" . ($i + 1) . ": $line\n";
      $prev_trim = $trim if $trim ne "";
      next;
    }
    if (@segs == 1
        && $prev_trim =~ /(?<!\|)\|$/
        && $prev_trim !~ $yaml_block_scalar_re
        && segment_is_quiet_grep($segs[0])) {
      print "$path:" . ($i + 1) . ": $line  (continuation: previous line ends in |)\n";
    }
    $prev_trim = $trim if $trim ne "";
  }
}

# Known, deliberate limitations (accepted tradeoffs, not silent gaps):
#  - A .sh/.yml comment is recognized only when # starts at column 0 or is
#    preceded by whitespace, not after every command-separator (e.g. a
#    literal ";#comment" is not recognized as a comment start).
#  - A pipeline or option list continued onto the next physical line via a
#    trailing backslash (not a bare trailing |) is not tracked; only the
#    "ends in a literal |" continuation form is.
#  - Escape handling inside an unquoted grep pattern/argument (e.g. a
#    backslash-escaped semicolon or quote character within the pattern
#    itself, as opposed to shell-level quoting) is not modeled.
#  - A grep wrapped in a compound command or another command (a brace
#    group, a subshell, a case/esac arm, `command grep`, `env … grep`) is
#    not recognized as still receiving the pipelines stdin.
#  - Heredoc bodies and other here-document-style data are scanned as
#    ordinary lines, so example shell text inside a heredoc can read as a
#    real violation.
#  - A .mjs shell command assembled by runtime string concatenation or
#    template interpolation (execSync("a | " + "grep -q b")) is invisible;
#    catching it would require partially evaluating JavaScript.
# Each of these was reproduced adversarially during review and judged out
# of scope for a text-level ratchet: none currently exists anywhere in this
# repository (confirmed by the full-tree scan this PR ran clean against),
# and closing them fully would mean writing most of a real bash/JS parser.

use File::Find;
find(sub {
  return unless -f $_;
  return unless /\.(sh|mjs|yml)$/;
  scan_file($File::Find::name);
}, "scripts", ".github/workflows");
')
if [ -z "$GREPQ_HITS" ]; then
  ok "L-077: no piped quiet grep under scripts/ or .github/workflows (line-continuation and .mjs-block-comment aware, no self-exclusion)"
else
  bad "L-077: piped quiet grep found: $(printf '%s\n' "$GREPQ_HITS" | head -3 | tr '\n' ' ')"
fi
# mutation: every quiet form (same-line, continuation, and mjs-block-comment
# suppression) must be caught or correctly ignored, or the sensor is decoration.
GREPQ_MUT=$(mktemp -d "${TMPDIR:-/tmp}/grepq-mut.XXXXXX")
mkdir -p "$GREPQ_MUT/scripts/tests" "$GREPQ_MUT/.github/workflows"
grepq_scan() {
  ( cd "$GREPQ_MUT" && perl -e '
use strict; use warnings;

my %ARG1_SHORT = map { $_ => 1 } qw(e f m A B C D d);
my %ARG1_LONG  = map { $_ => 1 } qw(regexp file max-count after-context before-context context devices directories label exclude exclude-from exclude-dir include binary-files);
my %ARG0_LONG  = map { $_ => 1 } qw(ignore-case extended-regexp fixed-strings basic-regexp perl-regexp word-regexp line-regexp invert-match count files-with-matches files-without-match line-number with-filename no-filename only-matching no-messages text recursive dereference-recursive quiet silent);

sub words {
  my ($line) = @_;
  my @w; my $cur = ""; my $i = 0; my $n = length($line);
  my $in_s = 0; my $in_d = 0;
  while ($i < $n) {
    my $c = substr($line, $i, 1);
    if ($in_s) { if ($c eq chr(39)) { $in_s = 0; } else { $cur .= $c; } $i++; next; }
    if ($in_d) {
      if ($c eq chr(34)) { $in_d = 0; $i++; next; }
      if ($c eq chr(92) && $i + 1 < $n) { $cur .= substr($line, $i, 2); $i += 2; next; }
      $cur .= $c; $i++; next;
    }
    if ($c eq chr(39)) { $in_s = 1; $i++; next; }
    if ($c eq chr(34)) { $in_d = 1; $i++; next; }
    if ($c =~ /\s/) { push @w, $cur if $cur ne ""; $cur = ""; $i++; next; }
    $cur .= $c; $i++;
  }
  push @w, $cur if $cur ne "";
  return @w;
}

# GNU grep permutes options past positional arguments by default, so a
# quiet flag can legally appear after the pattern/file words too; this
# walker never stops at a positional word, it just skips over it. It also
# tolerates leading NAME=value environment assignments before the command
# name (handled by the caller, not here).
sub grep_is_quiet {
  my (@w) = @_;
  my $i = 1; # element 0 is the literal word "grep"/"egrep"
  while ($i < @w) {
    my $w = $w[$i];
    if ($w eq "--") { $i += 1; last; }
    if ($w =~ /^--/) {
      my ($name, $eq) = $w =~ /^--([a-z-]+)(=.*)?$/;
      $name //= "";
      if ($name eq "quiet" || $name eq "silent") { return 1; }
      if ($ARG1_LONG{$name}) { $i += ($eq ? 1 : 2); next; }
      if ($ARG0_LONG{$name}) { $i += 1; next; }
      $i += 1; next;
    }
    if ($w =~ /^-(.+)$/) {
      my $body = $1;
      # Walk the bundled short letters one at a time: the first
      # value-consuming letter absorbs everything after it in this same
      # word (its attached value), or the next word if nothing follows;
      # zero-arg letters bundle freely and q may appear among them.
      my @chars = split //, $body;
      my $j = 0;
      while ($j < @chars) {
        my $ch = $chars[$j];
        if ($ARG1_SHORT{$ch}) {
          my $has_attached = ($j < $#chars);
          $i += ($has_attached ? 1 : 2);
          last;
        }
        return 1 if $ch eq "q";
        $j++;
      }
      $i += 1 if $j >= @chars; # word was all zero-arg letters, none consumed above
      next;
    }
    $i += 1; next; # a positional word (pattern/file): skip it, keep scanning (permuted options)
  }
  return 0;
}

sub pipe_segments {
  my ($line) = @_;
  my @segs; my $cur = ""; my $i = 0; my $n = length($line);
  my $in_s = 0; my $in_d = 0;
  while ($i < $n) {
    my $c = substr($line, $i, 1);
    if ($in_s) { $cur .= $c; $i++; $in_s = 0 if $c eq chr(39); next; }
    if ($in_d) {
      if ($c eq chr(92) && $i + 1 < $n) { $cur .= substr($line, $i, 2); $i += 2; next; }
      $cur .= $c; $i++; $in_d = 0 if $c eq chr(34); next;
    }
    if ($c eq chr(39)) { $in_s = 1; $cur .= $c; $i++; next; }
    if ($c eq chr(34)) { $in_d = 1; $cur .= $c; $i++; next; }
    if ($c eq chr(92) && $i + 1 < $n && substr($line, $i + 1, 1) eq "|") { $cur .= substr($line, $i, 2); $i += 2; next; }
    if ($c eq "|") {
      if ($i + 1 < $n && substr($line, $i + 1, 1) eq "|") { $cur .= "||"; $i += 2; next; }
      push @segs, $cur; $cur = ""; $i++; next;
    }
    $cur .= $c; $i++;
  }
  push @segs, $cur;
  return @segs;
}

# Only the command immediately after a pipe receives that pipe stdin; a
# later command joined by &&, ||, or ; on the same segment is a separate,
# unpiped invocation and is out of scope for THIS check (it has no SIGPIPE
# exposure since nothing feeds it via a pipe). Truncate at the first such
# unquoted boundary before scanning for a quiet grep.
sub truncate_at_command_separator {
  my ($line) = @_;
  my $i = 0; my $n = length($line);
  my $in_s = 0; my $in_d = 0;
  while ($i < $n) {
    my $c = substr($line, $i, 1);
    if ($in_s) { $i++; $in_s = 0 if $c eq chr(39); next; }
    if ($in_d) {
      if ($c eq chr(92) && $i + 1 < $n) { $i += 2; next; }
      $i++; $in_d = 0 if $c eq chr(34); next;
    }
    if ($c eq chr(39)) { $in_s = 1; $i++; next; }
    if ($c eq chr(34)) { $in_d = 1; $i++; next; }
    if ($c eq ";") { return substr($line, 0, $i); }
    if ($c eq "&") { return substr($line, 0, $i); } # single & (background) or && (and-list): either way, truncate
    if ($c eq "|" && $i + 1 < $n && substr($line, $i + 1, 1) eq "|") {
      return substr($line, 0, $i);
    }
    $i++;
  }
  return $line;
}

# A command word optionally preceded by one or more NAME=value environment
# assignments (e.g. "LC_ALL=C grep -q x").
sub segment_is_quiet_grep {
  my ($seg) = @_;
  $seg = truncate_at_command_separator($seg);
  my @w = words($seg);
  my $start = 0;
  while ($start < @w && $w[$start] =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { $start++; }
  return 0 unless $start < @w;
  return 0 unless $w[$start] eq "grep" || $w[$start] eq "egrep";
  return grep_is_quiet(@w[$start .. $#w]);
}

my $yaml_block_scalar_re = qr/^[\w.\-]+:\s*[|>][+\-0-9]*\s*$/;

sub mjs_code_lines {
  my ($path) = @_;
  open my $fh, "<", $_ or return ();
  my @raw = <$fh>; close $fh;
  my @out;
  my $in_block = 0; my $in_s = 0; my $in_d = 0; my $in_t = 0;
  for my $line (@raw) {
    chomp $line;
    my $code = "";
    my $i = 0; my $n = length($line);
    while ($i < $n) {
      if ($in_block) {
        my $close = index($line, "*/", $i);
        if ($close == -1) { $i = $n; last; }
        $i = $close + 2; $in_block = 0; next;
      }
      my $c = substr($line, $i, 1);
      if ($in_s) {
        if ($c eq chr(92) && $i + 1 < $n) { $code .= substr($line, $i + 1, 1); $i += 2; next; }
        $i++; $in_s = 0 if $c eq chr(39); next if $c eq chr(39);
        $code .= $c; next;
      }
      if ($in_d) {
        if ($c eq chr(92) && $i + 1 < $n) { $code .= substr($line, $i + 1, 1); $i += 2; next; }
        $i++; $in_d = 0 if $c eq chr(34); next if $c eq chr(34);
        $code .= $c; next;
      }
      if ($in_t) {
        if ($c eq chr(92) && $i + 1 < $n) { $code .= substr($line, $i + 1, 1); $i += 2; next; }
        $i++; $in_t = 0 if $c eq chr(96); next if $c eq chr(96);
        $code .= $c; next;
      }
      if ($c eq chr(39)) { $in_s = 1; $i++; next; }
      if ($c eq chr(34)) { $in_d = 1; $i++; next; }
      if ($c eq chr(96)) { $in_t = 1; $i++; next; }
      if ($c eq "/" && $i + 1 < $n && substr($line, $i + 1, 1) eq "/") { last; }
      if ($c eq "/" && $i + 1 < $n && substr($line, $i + 1, 1) eq "*") {
        my $close = index($line, "*/", $i + 2);
        if ($close == -1) { $in_block = 1; $i = $n; last; }
        $i = $close + 2; next;
      }
      $code .= $c; $i++;
    }
    push @out, $code;
  }
  return @out;
}

# NOTE: this does not evaluate JavaScript. A shell command assembled by
# runtime concatenation, e.g. execSync("yes x | " + "grep -q x") or a
# template interpolation whose substituted expression itself contains
# the pipe/grep text, is invisible here: each string/template literal is
# scanned as its own independent unit, never joined across a + or ${...}
# boundary. Doing that would require partially evaluating JavaScript
# expressions, a different order of problem than this text-level ratchet
# takes on. Documented limitation, not a silent gap.
sub sh_code_lines {
  my ($path) = @_;
  open my $fh, "<", $_ or return ();
  my @raw = <$fh>; close $fh;
  my @out;
  for my $line (@raw) {
    chomp $line;
    my $code = "";
    my $i = 0; my $n = length($line);
    my $in_s = 0; my $in_d = 0;
    while ($i < $n) {
      my $c = substr($line, $i, 1);
      if ($in_s) { $code .= $c; $i++; $in_s = 0 if $c eq chr(39); next; }
      if ($in_d) {
        if ($c eq chr(92) && $i + 1 < $n) { $code .= substr($line, $i, 2); $i += 2; next; }
        $code .= $c; $i++; $in_d = 0 if $c eq chr(34); next;
      }
      if ($c eq chr(39)) { $in_s = 1; $code .= $c; $i++; next; }
      if ($c eq chr(34)) { $in_d = 1; $code .= $c; $i++; next; }
      # A shell comment starts at a # that is the first character of a
      # word (start of line, or preceded by whitespace) — not e.g. the #
      # in a parameter expansion (${value#prefix}) or a bare word
      # (foo#bar).
      if ($c eq "#" && ($i == 0 || substr($line, $i - 1, 1) =~ /\s/)) { last; }
      $code .= $c; $i++;
    }
    push @out, $code;
  }
  return @out;
}

sub scan_file {
  my ($path) = @_;
  my $is_mjs = $path =~ /\.mjs$/;
  my @lines = $is_mjs ? mjs_code_lines($path) : sh_code_lines($path);
  my $prev_trim = "";
  for my $i (0 .. $#lines) {
    my $line = $lines[$i];
    (my $trim = $line) =~ s/^\s+//;
    my @segs = pipe_segments($line);
    my $hit = 0;
    for my $s (1 .. $#segs) {
      if (segment_is_quiet_grep($segs[$s])) { $hit = 1; last; }
    }
    if ($hit) {
      print "$path:" . ($i + 1) . ": $line\n";
      $prev_trim = $trim if $trim ne "";
      next;
    }
    if (@segs == 1
        && $prev_trim =~ /(?<!\|)\|$/
        && $prev_trim !~ $yaml_block_scalar_re
        && segment_is_quiet_grep($segs[0])) {
      print "$path:" . ($i + 1) . ": $line  (continuation: previous line ends in |)\n";
    }
    $prev_trim = $trim if $trim ne "";
  }
}

# Known, deliberate limitations (accepted tradeoffs, not silent gaps):
#  - A .sh/.yml comment is recognized only when # starts at column 0 or is
#    preceded by whitespace, not after every command-separator (e.g. a
#    literal ";#comment" is not recognized as a comment start).
#  - A pipeline or option list continued onto the next physical line via a
#    trailing backslash (not a bare trailing |) is not tracked; only the
#    "ends in a literal |" continuation form is.
#  - Escape handling inside an unquoted grep pattern/argument (e.g. a
#    backslash-escaped semicolon or quote character within the pattern
#    itself, as opposed to shell-level quoting) is not modeled.
#  - A grep wrapped in a compound command or another command (a brace
#    group, a subshell, a case/esac arm, `command grep`, `env … grep`) is
#    not recognized as still receiving the pipelines stdin.
#  - Heredoc bodies and other here-document-style data are scanned as
#    ordinary lines, so example shell text inside a heredoc can read as a
#    real violation.
#  - A .mjs shell command assembled by runtime string concatenation or
#    template interpolation (execSync("a | " + "grep -q b")) is invisible;
#    catching it would require partially evaluating JavaScript.
# Each of these was reproduced adversarially during review and judged out
# of scope for a text-level ratchet: none currently exists anywhere in this
# repository (confirmed by the full-tree scan this PR ran clean against),
# and closing them fully would mean writing most of a real bash/JS parser.

use File::Find;
find(sub { return unless -f $_; return unless /\.(sh|mjs|yml)$/; scan_file($File::Find::name); }, "scripts", ".github/workflows");
' )
}
GREPQ_MISSED=""
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep; printf 'seq 1 3 %s\n  %s -q 1\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [continuation-pipe]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep; printf '%s -q x file\n' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: unpiped grep -q on a file]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep; printf 'x || %s -q y file\n' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: ||]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep; printf '# echo x %s %s -q y\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: sh comment]"
: > "$GREPQ_MUT/scripts/tests/planted.mjs"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep; printf '/*\necho x %s %s -q y\n*/\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.mjs"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: mjs block comment]"
: > "$GREPQ_MUT/scripts/tests/planted.mjs"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep; printf 'echo x %s %s -q y\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.mjs"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [mjs executable line missed]"
: > "$GREPQ_MUT/scripts/tests/planted.mjs"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep; printf 'echo x %s %s -F -q y\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [split-cluster -q missed]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep; printf 'echo x %s %s --binary-files=text -q y\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [long-option-before-q missed]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep; printf 'run: echo x %s %s -q y\n' '|' "$GQ" > "$GREPQ_MUT/.github/workflows/planted.yml"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [workflow yml missed]"
: > "$GREPQ_MUT/.github/workflows/planted.yml"
: > "$GREPQ_MUT/scripts/tests/planted.mjs"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep
printf '/* note */ execSync("seq 1 3 %s %s -q 1");\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.mjs"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [mjs same-line inline block comment before real code missed]"
: > "$GREPQ_MUT/scripts/tests/planted.mjs"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep
printf 'const n = 1; /* echo x %s %s -q y */\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.mjs"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: mjs same-line trailing block comment]"
: > "$GREPQ_MUT/scripts/tests/planted.mjs"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep
printf 'execSync("curl https://example.test/data %s %s -q ok");\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.mjs"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [mjs string containing :// mistaken for a comment]"
: > "$GREPQ_MUT/scripts/tests/planted.mjs"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf 'yes x %s %s -e x -q\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [split option-argument grep -e x -q missed]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf 'run: |\n  %s -q pattern file\n' "$GQ" > "$GREPQ_MUT/.github/workflows/planted.yml"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: yaml block-scalar header mistaken for a pipe continuation]"
: > "$GREPQ_MUT/.github/workflows/planted.yml"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep
printf 'yes x %s %s -m1 -q x\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [attached-digit short option grep -m1 -q missed]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf 'yes x %s %s -v z %s %s -q x\n' '|' "$GQ" '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [second grep in a multi-segment pipeline missed]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf 'execSync("printf \\"https://example.test\\" %s %s -q ok")\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.mjs"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [mjs escaped-quote string content missed]"
: > "$GREPQ_MUT/scripts/tests/planted.mjs"
printf 'const t = `\nhttps://x %s\n  %s -q y\n`;\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.mjs"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [mjs multiline template literal missed]"
: > "$GREPQ_MUT/scripts/tests/planted.mjs"
printf 'echo ok # example: yes x %s %s -q x\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: sh trailing inline # comment]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf 'run: echo ok # example: yes x %s %s -q x\n' '|' "$GQ" > "$GREPQ_MUT/.github/workflows/planted.yml"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: yaml trailing inline # comment]"
: > "$GREPQ_MUT/.github/workflows/planted.yml"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep
printf 'yes ${value#prefix} %s %s -q x\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [unquoted-# parameter expansion mistaken for a comment]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf 'yes foo#bar %s %s -q foo\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [bare word containing # mistaken for a comment]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf 'printf %%s Usage: producer \\%s %s -q pattern\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: escaped literal pipe in usage text]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf 'yes x %s LC_ALL=C %s -q x\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [env-var-prefixed grep -q missed]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf 'printf %%s keep %s %s -vequiet\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: -vequiet is -v -e quiet, no real q flag]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf 'yes x %s %s pattern -q\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -n "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [permuted grep pattern -q missed]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
printf '[[ 1 -eq 1 ]] && echo x %s grep -i y >/dev/null && ! %s -q z file\n' '|' "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: unrelated later && grep -q reading a file, not the pipe target]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
# shellcheck disable=SC2209 # intentional: a plain string that happens to look like a command name
GQ=grep
printf 'printf x %s %s x >/dev/null & %s -q y file\n' '|' "$GQ" "$GQ" > "$GREPQ_MUT/scripts/tests/planted.sh"
[ -z "$(grepq_scan)" ] || GREPQ_MISSED="$GREPQ_MISSED [false-positive: unrelated backgrounded & grep -q reading a file, not the pipe target]"
: > "$GREPQ_MUT/scripts/tests/planted.sh"
rm -rf "$GREPQ_MUT"
if [ -z "$GREPQ_MISSED" ]; then
  ok "L-077 mutation: every planted form caught or correctly ignored (continuation, comments incl. mjs blocks, ||, split clusters, long options, yml)"
else
  bad "L-077 mutation: sensor defect:$GREPQ_MISSED"
fi

echo "ci-conventions wall: ${SECONDS}s"
echo "ci-conventions.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
