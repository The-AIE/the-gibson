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

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
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
  printf '%s\n' "$1" | grep -Eq '^[[:space:]]*-[[:space:]]*\{'
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
      if printf '%s\n' "$trimmed" | grep -Eq "^uses:[[:space:]]*[\"']?[^@\"'[:space:]]+@${SHA40}[\"']?[[:space:]]+#[[:space:]]*.+"; then
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

# (b) every workflow file declares a top-level permissions: key.
check_permissions() {
  local root="$1"
  local failed=0
  local f rel any
  any=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    any=1
    rel=${f#"$root"/}
    if ! grep -Eq '^permissions:' "$f"; then
      echo "$rel missing top-level permissions:"
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

# (c) PR-triggered workflows have concurrency.cancel-in-progress unless stateful.
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
    if grep -Eq '^concurrency:' "$f" && grep -Eq 'cancel-in-progress:[[:space:]]*true' "$f"; then
      continue
    fi
    echo "$rel PR-triggered but missing concurrency.cancel-in-progress: true"
    failed=1
  done < <(collect_workflows "$root")
  return "$failed"
}

# (d) no hostile github.event.* inside run: blocks (allowlist only).
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
      {
        line = $0
        ind = leading(line)
        if (match(line, /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>]/)) {
          in_run = 1
          run_ind = ind
          next
        }
        if (in_run) {
          if (length(line) && ind <= run_ind && line ~ /^[[:space:]]*(- |[A-Za-z0-9_]+:)/) {
            in_run = 0
            if (match(line, /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*[|>]/)) {
              in_run = 1
              run_ind = ind
              next
            }
          } else if (in_run) {
            rest = line
            while (match(rest, /\$\{\{[[:space:]]*github\.event\.[^}]+[[:space:]]*\}\}/)) {
              expr = substr(rest, RSTART, RLENGTH)
              path = expr
              sub(/^\$\{\{[[:space:]]*github\.event\./, "", path)
              sub(/[[:space:]]*\}\}$/, "", path)
              allowed = 0
              if (path ~ /\.sha$/ || path ~ /\.number$/ || path == "sha" || path == "number") allowed = 1
              if (path == "repository" || path == "run_id" || path == "run_attempt") allowed = 1
              if (!allowed) {
                printf "%s:%d: %s\n", rel, NR, expr
              }
              rest = substr(rest, RSTART + RLENGTH)
            }
          }
        }
      }
    ' "$f")
    if [[ -n "$offenders" ]]; then
      echo "$rel forbidden github.event in run: block(s): $offenders"
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
  printf '%s\n' "$1" | grep -Eq \
    '^[[:space:]]*(echo|printf)[[:space:]]+["'\'']?::(warning|notice)::'
}

# True when the script appends to $GITHUB_STEP_SUMMARY. Trailing shell
# comments are stripped first (`true # >> "$GITHUB_STEP_SUMMARY"` does not
# count), same naive first-`#` cut as is_soft_coe.
has_step_summary_append() {
  local line stripped
  while IFS= read -r line; do
    stripped=${line%%#*}
    if printf '%s\n' "$stripped" | grep -Eq '>>[[:space:]]*["'\'']?\$\{?GITHUB_STEP_SUMMARY'; then
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
        if (line ~ />>[[:space:]]*["'"'"']?\$\{?GITHUB_STEP_SUMMARY/) return 1
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
          if (lines[i] ~ /^[[:space:]]*-?[[:space:]]*if:[[:space:]]*/) {
            if (lines[i] ~ /^[[:space:]]*-?[[:space:]]*if:[[:space:]]*always\(\)[[:space:]]*(#.*)?$/) {
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
        if ! has_annotation_emission "$script"; then
          echo "$rel:$ln continue-on-error step missing ::warning:: or ::notice:: in step body"
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

# (g) templates/ contains no operator literals (mrhinkle, /Users/).
check_operator_literals() {
  local root="$1"
  local hits
  if [[ ! -d "$root/templates" ]]; then
    return 0
  fi
  hits=$(grep -RInE 'mrhinkle|/Users/' "$root/templates" 2>/dev/null || true)
  if [[ -z "$hits" ]]; then
    return 0
  fi
  hits=$(printf '%s\n' "$hits" | sed "s#^${root}/##")
  echo "templates/ operator literals: $hits"
  return 1
}

# Report a planted-fixture failure. needle must appear in the check output.
assert_planted() {
  local n="$1"
  local desc="$2"
  local needle="$3"
  local got="$4"
  if printf '%s\n' "$got" | grep -Fq "$needle"; then
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

echo "# (b) every workflow file declares permissions:"
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

echo "# (c) PR-triggered workflows have concurrency.cancel-in-progress (unless stateful)"
conc_viol=$(check_concurrency "$REPO_ROOT") || true
if [[ -z "$conc_viol" ]]; then
  for f in "${WORKFLOWS[@]}"; do
    rel=${f#"$REPO_ROOT"/}
    if grep -Eq '^[[:space:]]*#[[:space:]]*gibson:stateful-ci' "$f"; then
      ok "$rel annotated # gibson:stateful-ci — concurrency not required"
    elif ! has_pr_trigger "$f"; then
      ok "$rel has no PR-class triggers — concurrency not required"
    else
      ok "$rel has concurrency.cancel-in-progress: true"
    fi
  done
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    bad "$line"
  done <<< "$conc_viol"
fi

echo "# (d) no hostile github.event.* inside run: blocks (allowlist only)"
untrust_viol=$(check_untrusted_interpolation "$REPO_ROOT") || true
if [[ -z "$untrust_viol" ]]; then
  for f in "${WORKFLOWS[@]}"; do
    ok "${f#"$REPO_ROOT"/} run: blocks only use allowlisted github.event fields"
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

echo "# gibson-template-drift.sh --repo without a value is usage (exit 2)"
drift_out=$("$DRIFT_SH" --repo 2>&1) || drift_rc=$?
drift_rc=${drift_rc:-0}
if [[ "$drift_rc" -eq 2 ]] && printf '%s\n' "$drift_out" | grep -Eq 'Usage|USAGE|--repo'; then
  ok "--repo with no value prints usage and exits 2"
else
  bad "--repo with no value: expected exit 2 + usage, got rc=${drift_rc} out=${drift_out}"
fi

echo "# (g) templates/ contains no operator literals (mrhinkle, /Users/)"
op_viol=$(check_operator_literals "$REPO_ROOT") || true
if [[ -z "$op_viol" ]]; then
  if [[ -d "$REPO_ROOT/templates" ]]; then
    ok "templates/ free of mrhinkle and /Users/ literals"
  else
    ok "no templates/ directory (N/A)"
  fi
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
  "ci/planted.yml PR-triggered but missing concurrency.cancel-in-progress: true" "$got"

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
  "continue-on-error step missing ::warning:: or ::notice:: in step body" "$got"

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
  "continue-on-error step missing ::warning:: or ::notice:: in step body" "$got"

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
  "continue-on-error step missing ::warning:: or ::notice:: in step body" "$got"

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
  "continue-on-error step missing ::warning:: or ::notice:: in step body" "$got"

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
if [[ "$drift_rc" -eq 1 ]] && printf '%s\n' "$got" | grep -Fq "DRIFT  planted.yml  template stamp missing"; then
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
if [[ "$drift_rc" -eq 1 ]] && printf '%s\n' "$got" | grep -Fq "DRIFT  planted.yml  installed stamp missing"; then
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

echo
echo "ci-conventions.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
