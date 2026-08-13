#!/usr/bin/env bash
# run-all.sh — Gibson's own green gate (issue #89)
set -uo pipefail

usage() {
  cat <<'EOF'
run-all.sh — run every Gibson sensor and report one verdict

WHAT IT DOES
  1. shellcheck -S warning over scripts/**/*.sh and adapters/**/*.sh, compared to
     scripts/tests/shellcheck-baseline.txt — a NEW finding fails, a fixed one
     tells you to shrink the baseline.
  2. bash -n over the same files (and, when docker is available, bash 3.2 too,
     because stock macOS ships 3.2 and half our portability scars come from it).
  3. scripts/injection-scan.sh over everything an agent ingests.
  4. Every scripts/tests/*.test.sh.

  Suites listed in the QUARANTINE block below are known-red with a burn-down
  issue. They still run, they are still reported, and they do not fail the gate
  — but a quarantined suite that starts PASSING also fails the gate, so the list
  can only shrink (Law 9). Nothing here is ever silently skipped (Law 8).

WHY
  Gibson had thirteen sensor suites and no CI, so four of them were red on main
  and nobody noticed (#90). A sensor nobody runs is documentation.

USAGE
  scripts/tests/run-all.sh [--only PATTERN] [--timeout SECONDS]
                           [--no-quarantine] [--list-quarantine] [--quiet]
  scripts/tests/run-all.sh --self-test-toolchain
  scripts/tests/run-all.sh --help

  --only PATTERN          run only suites whose filename matches PATTERN
  --timeout SECONDS       per-suite timeout (default 600; 0 disables)
  --no-quarantine         treat quarantined suites as required — the burn-down view
  --list-quarantine       print the quarantine list with issue links and exit
  --quiet                 suite summary lines only, no per-assertion output
  --self-test-toolchain   offline checks for ShellCheck version parsing/mismatch
                          and single-source pin wiring (no network, no sensors).
                          The ordinary path also runs these checks and fails the
                          gate if they go red.

EXIT
  0  everything required is green
  1  a required check failed, or a quarantined suite unexpectedly passed
  2  usage error
EOF
}

# --- quarantine -------------------------------------------------------------
# suite<TAB>issue<TAB>one-line reason. Shrink this; never grow it without a PR
# that says why in the body.
QUARANTINE=$(cat <<'EOF'
EOF
)

# Minimum jq. release-preflight uses strict civil-calendar round-trips and must
# not fail-open on older jq (#91 fixed: never use `$label` as a jq param — it is
# a keyword on jq 1.6 and the compile error left MALFORMED empty → READY).
# Floor stays at 1.6 (Ubuntu 22.04 default); raise only with a failing sensor.
JQ_MIN_MAJOR=1
JQ_MIN_MINOR=6

# Exact ShellCheck pin (#138). The baseline is an exact-set ratchet: findings
# differ across tool versions (SC2218 accuracy changed in 0.11.0). CI installs
# this same version from the official koalaman release asset; local operators
# must match or the gate fails with a plain remediation message below.
#
# MACHINE SOURCE OF TRUTH for version + official asset digests. Strict
# assignment lines (name=value, no quotes/spaces) so .github/workflows/
# gibson-self-gate.yml can extract the Linux pin without restating it.
# A version bump updates these constants only; the workflow reads them.
SHELLCHECK_REQUIRED_VERSION=0.11.0
SHELLCHECK_SHA256_DARWIN_AARCH64=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79
SHELLCHECK_SHA256_DARWIN_X86_64=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
SHELLCHECK_SHA256_LINUX_X86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/../.." && pwd)
BASELINE="$SCRIPT_DIR/shellcheck-baseline.txt"
# shellcheck source=lib/convention-sensors.sh
. "$SCRIPT_DIR/lib/convention-sensors.sh"
WORKFLOW_SELF_GATE="$REPO_ROOT/.github/workflows/gibson-self-gate.yml"

# Parse "ShellCheck … version: X.Y.Z" (or a bare X.Y.Z) → X.Y.Z, else empty.
# Pure string logic — no PATH lookup — so offline self-tests can exercise it.
# Distro revision suffixes (e.g. 0.11.0-1) are NOT normalized: the full remainder
# is returned and fails the exact pin match (official binaries print bare X.Y.Z).
parse_shellcheck_version() {
  local raw="${1:-}" v
  v=$(printf '%s\n' "$raw" | awk '
    /^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+/ {
      sub(/^version:[[:space:]]*/, ""); print; exit
    }
    /^[0-9]+\.[0-9]+\.[0-9]+$/ { print; exit }
  ')
  printf '%s' "$v"
}

# True when a parsed version equals the exact pin (used by SC_OK gating).
shellcheck_version_matches_pin() {
  local got="${1:-}"
  [[ -n "$got" && "$got" == "$SHELLCHECK_REQUIRED_VERSION" ]]
}

# Plain-language install path to the official pinned release assets (no package
# manager "latest"). Digests come from the single-source constants above.
print_shellcheck_install_remediation() {
  local v="$SHELLCHECK_REQUIRED_VERSION"
  cat <<EOF
         Install official ShellCheck ${v} from the koalaman release assets
         (exact pin — package-manager "latest" is not durable for this gate):

           Release page:
             https://github.com/koalaman/shellcheck/releases/tag/v${v}

           Assets (download the one for your OS/CPU):
             • macOS Apple Silicon:
                 shellcheck-v${v}.darwin.aarch64.tar.xz
                 SHA-256: ${SHELLCHECK_SHA256_DARWIN_AARCH64}
             • macOS Intel:
                 shellcheck-v${v}.darwin.x86_64.tar.xz
                 SHA-256: ${SHELLCHECK_SHA256_DARWIN_X86_64}
             • Linux x86_64:
                 shellcheck-v${v}.linux.x86_64.tar.xz
                 SHA-256: ${SHELLCHECK_SHA256_LINUX_X86_64}

           Then:
             1. Verify the downloaded file's SHA-256 matches the digest above
                (or the digest published on that release page).
             2. Extract the shellcheck binary and put it on your PATH
                (e.g. install -m 0755 shellcheck /usr/local/bin/shellcheck).
             3. Confirm: shellcheck --version  →  version: ${v}

         CI extracts the Linux version + digest from these same constants
         (see .github/workflows/gibson-self-gate.yml) — do not restate them there.
EOF
}

# Assert executable single-source ShellCheck pin wiring in a workflow file.
# Comments that merely mention the constant names must NOT satisfy this.
# Full-line comments are stripped before required executable-wiring greps so
# commented-out command text (extract_strict, GITHUB_OUTPUT emit, sc_pin
# consumers) cannot satisfy the check. Forbidden version/digest restatements
# still scan the raw file, including comments.
# Prints a short reason on stdout and returns 1 on failure; silent return 0
# when wiring is correct.
#
# Required executable wiring (active / non-comment content only):
#   - extract_strict SHELLCHECK_REQUIRED_VERSION
#   - extract_strict SHELLCHECK_SHA256_LINUX_X86_64
#   - both version=${version} and digest=${digest} actively emitted to
#     GITHUB_OUTPUT via one exact four-line brace-group sequence (strict
#     state machine; surrounding whitespace allowed on each line; no extra,
#     duplicate, reordered, blank, conditional, redirected, or piped line
#     inside the candidate):
#       1. opener:  {
#       2. version: echo "version=${version}"
#       3. digest:  echo "digest=${digest}"
#       4. closer:  } >> "$GITHUB_OUTPUT"
#     So `echo "version=${version}" >/dev/null` does not credit a pin key —
#     the block redirect would only capture remaining stdout. An inner
#     `exec >/dev/null` between opener and the pin echos also fails closed:
#     remaining group stdout is redirected away from GITHUB_OUTPUT. A
#     conditional closer such as `} && echo "unrelated=x" >> "$GITHUB_OUTPUT"`
#     is rejected: brace stdout is not redirected to GITHUB_OUTPUT. Direct
#     same-line emits are not accepted either. Independent greps are NOT
#     enough; log-only echos of the correct values fail closed.
#   - install step consumes steps.sc_pin.outputs.version and .digest
# Forbidden (raw file, including comments):
#   - any fixed-string restatement of the pinned version or digests
#     (URL literals, alternate keys, colon/equals assignments, comments).
# Version/digest matches are always fixed-string (grep -F) — never interpolate
# the pin into an unescaped ERE.
assert_workflow_shellcheck_pin_wiring() {
  local wf="$1"
  local reasons=""
  local filtered=""
  local emit_rc=0
  if [[ ! -f "$wf" ]]; then
    printf '%s' "missing workflow file"
    return 1
  fi
  # Strip full-line comments (optional leading whitespace + #) for required
  # executable-wiring checks only. Inline trailing comments remain.
  filtered=$(mktemp "${TMPDIR:-/tmp}/sc-pin-active.XXXXXX") || {
    printf '%s' "mktemp failed for active-wiring filter"
    return 1
  }
  if ! sed '/^[[:space:]]*#/d' "$wf" >"$filtered"; then
    rm -f "$filtered"
    printf '%s' "failed to strip full-line comments"
    return 1
  fi
  # Strict extract_strict calls for both keys (not bare identifier mentions).
  if ! grep -Eq 'extract_strict[[:space:]]+SHELLCHECK_REQUIRED_VERSION([[:space:]]|$)' "$filtered"; then
    reasons="${reasons}missing extract_strict SHELLCHECK_REQUIRED_VERSION; "
  fi
  if ! grep -Eq 'extract_strict[[:space:]]+SHELLCHECK_SHA256_LINUX_X86_64([[:space:]]|$)' "$filtered"; then
    reasons="${reasons}missing extract_strict SHELLCHECK_SHA256_LINUX_X86_64; "
  fi
  # Coupled emit check: strict four-line consecutive state machine only.
  # Accept exactly, in order: trimmed `{`, exact version echo, exact digest
  # echo, trimmed `} >> "$GITHUB_OUTPUT"`. Any extra, duplicate, reordered,
  # blank, conditional, redirected, or piped line invalidates the candidate
  # (including inner `exec >/dev/null` and per-echo >/dev/null). Fail closed
  # on same-line forms and conditional closers that merely co-locate >> and
  # GITHUB_OUTPUT. Deterministic awk over the already comment-filtered stream
  # (macOS / Bash 3.2 / POSIX awk).
  # shellcheck disable=SC2016 # intentional literal ${version}/${digest} pins
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function is_plain_v(s) { return trim(s) == "echo \"version=${version}\"" }
    function is_plain_d(s) { return trim(s) == "echo \"digest=${digest}\"" }
    function is_plain_opener(s) { return trim(s) == "{" }
    function is_plain_closer(s) { return trim(s) == "} >> \"$GITHUB_OUTPUT\"" }
    {
      line = $0
      # Strict consecutive sequence: state 0 idle, 1 after {, 2 after version,
      # 3 after digest; only exact closer from state 3 credits. Any mismatch
      # resets (opener may restart a new candidate).
      if (is_plain_opener(line)) {
        state = 1
        next
      }
      if (state == 1) {
        if (is_plain_v(line)) state = 2
        else state = 0
      } else if (state == 2) {
        if (is_plain_d(line)) state = 3
        else state = 0
      } else if (state == 3) {
        if (is_plain_closer(line)) ok = 1
        state = 0
      }
    }
    END {
      if (ok) exit 0
      exit 1
    }
  ' "$filtered"
  emit_rc=$?
  if [[ "$emit_rc" -ne 0 ]]; then
    reasons="${reasons}version=\${version} and digest=\${digest} not both actively emitted inside one exact { ... } >> \"\$GITHUB_OUTPUT\" brace group; "
  fi
  # Install step must consume the pin step outputs.
  if ! grep -Fq 'steps.sc_pin.outputs.version' "$filtered"; then
    reasons="${reasons}missing steps.sc_pin.outputs.version consumer; "
  fi
  if ! grep -Fq 'steps.sc_pin.outputs.digest' "$filtered"; then
    reasons="${reasons}missing steps.sc_pin.outputs.digest consumer; "
  fi
  rm -f "$filtered"
  # Literal-safe: no restated digests anywhere (raw file, including comments).
  if grep -Fq "$SHELLCHECK_SHA256_LINUX_X86_64" "$wf" 2>/dev/null ||
     grep -Fq "$SHELLCHECK_SHA256_DARWIN_AARCH64" "$wf" 2>/dev/null ||
     grep -Fq "$SHELLCHECK_SHA256_DARWIN_X86_64" "$wf" 2>/dev/null; then
    reasons="${reasons}restates a pin digest; "
  fi
  # Literal-safe: reject the exact pinned version anywhere (URL, keys, =/:,
  # comments). Fixed-string only — do not interpolate into unescaped ERE.
  if grep -Fq "$SHELLCHECK_REQUIRED_VERSION" "$wf" 2>/dev/null; then
    reasons="${reasons}restates pinned version literal ${SHELLCHECK_REQUIRED_VERSION}; "
  fi
  if [[ -n "$reasons" ]]; then
    printf '%s' "$reasons"
    return 1
  fi
  return 0
}

# Minimal executable wiring that should PASS the assertion (control fixture).
# Intentionally omits any restated version/digest literal.
_write_good_pin_wiring_fixture() {
  cat >"$1" <<'EOF'
# Resolve ShellCheck pin from run-all.sh
- name: Resolve ShellCheck pin from run-all.sh
  id: sc_pin
  run: |
    pin_file="scripts/tests/run-all.sh"
    version=$(extract_strict SHELLCHECK_REQUIRED_VERSION '[0-9]+\.[0-9]+\.[0-9]+')
    digest=$(extract_strict SHELLCHECK_SHA256_LINUX_X86_64 '[0-9a-f]{64}')
    {
      echo "version=${version}"
      echo "digest=${digest}"
    } >> "$GITHUB_OUTPUT"
- name: Install ShellCheck (official release, single-source pin)
  run: |
    SC_VERSION="${{ steps.sc_pin.outputs.version }}"
    SC_SHA256="${{ steps.sc_pin.outputs.digest }}"
    curl -fsSL -o shellcheck.tar.xz "https://github.com/koalaman/shellcheck/releases/download/v${SC_VERSION}/shellcheck-v${SC_VERSION}.linux.x86_64.tar.xz"
EOF
}

# Offline deterministic checks for version parsing / mismatch / single-source
# wiring (no network). Invoked by the ordinary run-all path (CI) and by the
# focused entry point --self-test-toolchain.
self_test_toolchain() {
  local fail=0 got mismatch wf reason mut_dir mut_wf
  # Parse expectations track the pin constant so a future bump cannot leave a
  # hardcoded "0.11.0" expectation that contradicts the new pin.
  got=$(parse_shellcheck_version $'ShellCheck - shell script analysis tool\nversion: '"${SHELLCHECK_REQUIRED_VERSION}"$'\nlicense: GNU')
  if [[ "$got" == "$SHELLCHECK_REQUIRED_VERSION" ]]; then
    echo "  ok   — parse full --version banner → ${SHELLCHECK_REQUIRED_VERSION}"
  else
    echo "  FAIL — parse full banner expected ${SHELLCHECK_REQUIRED_VERSION} got '$got'"; fail=1
  fi
  got=$(parse_shellcheck_version "1.2.3")
  if [[ "$got" == "1.2.3" ]]; then
    echo "  ok   — parse bare version → 1.2.3"
  else
    echo "  FAIL — parse bare expected 1.2.3 got '$got'"; fail=1
  fi
  got=$(parse_shellcheck_version "not-a-version")
  if [[ -z "$got" ]]; then
    echo "  ok   — parse garbage → empty"
  else
    echo "  FAIL — parse garbage expected empty got '$got'"; fail=1
  fi
  # Dynamic mismatch: never equal the pin, even if a later pin happens to equal
  # a formerly hardcoded wrong sample (e.g. 0.9.0).
  mismatch="0.0.0"
  if [[ "$mismatch" == "$SHELLCHECK_REQUIRED_VERSION" ]]; then
    mismatch="0.0.1"
  fi
  got=$(parse_shellcheck_version "version: ${mismatch}")
  if [[ "$got" != "$SHELLCHECK_REQUIRED_VERSION" ]]; then
    echo "  ok   — mismatch detected (got $got, need $SHELLCHECK_REQUIRED_VERSION)"
  else
    echo "  FAIL — mismatch self-test unexpectedly matched"; fail=1
  fi
  # SC_OK gating uses shellcheck_version_matches_pin once; exercise that helper.
  if shellcheck_version_matches_pin "$SHELLCHECK_REQUIRED_VERSION"; then
    echo "  ok   — pin matches helper accepts required version"
  else
    echo "  FAIL — pin matches helper rejected required version"; fail=1
  fi
  if shellcheck_version_matches_pin "$mismatch"; then
    echo "  FAIL — pin matches helper accepted wrong version ($mismatch)"; fail=1
  else
    echo "  ok   — pin matches helper rejects other version ($mismatch)"
  fi
  if shellcheck_version_matches_pin ""; then
    echo "  FAIL — pin matches helper accepted empty"; fail=1
  else
    echo "  ok   — pin matches helper rejects empty"
  fi
  # Digest constants: non-empty, 64 lowercase hex (official GitHub asset shape).
  local digests_ok=1
  for got in \
      "$SHELLCHECK_SHA256_DARWIN_AARCH64" \
      "$SHELLCHECK_SHA256_DARWIN_X86_64" \
      "$SHELLCHECK_SHA256_LINUX_X86_64"; do
    if [[ "$got" =~ ^[0-9a-f]{64}$ ]]; then
      : # ok
    else
      echo "  FAIL — digest constant bad shape (want 64 lowercase hex): '$got'"
      fail=1
      digests_ok=0
    fi
  done
  if [[ "$digests_ok" -eq 1 ]]; then
    echo "  ok   — digest constants are 64 lowercase hex (darwin aarch64/x86_64, linux x86_64)"
  fi
  # Workflow must have executable single-source pin wiring and must not restate
  # version/digests. Bare constant names in comments alone are not enough.
  wf="$WORKFLOW_SELF_GATE"
  if [[ ! -f "$wf" ]]; then
    echo "  FAIL — missing workflow $wf"; fail=1
  else
    if reason=$(assert_workflow_shellcheck_pin_wiring "$wf"); then
      echo "  ok   — workflow has executable extract_strict + GITHUB_OUTPUT + sc_pin consumer wiring"
      echo "  ok   — workflow does not restate pin version/digest literals (fixed-string)"
    else
      echo "  FAIL — workflow pin wiring: ${reason}"; fail=1
    fi
    if ! grep -Fq 'scripts/tests/run-all.sh' "$wf"; then
      echo "  FAIL — workflow does not reference pin source scripts/tests/run-all.sh"; fail=1
    else
      echo "  ok   — workflow references pin source scripts/tests/run-all.sh"
    fi
  fi
  # Deterministic mutation fixtures: comments-only / missing consumer / restated
  # version forms must fail closed; a minimal good fixture must pass.
  mut_dir=$(mktemp -d "${TMPDIR:-/tmp}/sc-pin-mut.XXXXXX") || {
    echo "  FAIL — mktemp for pin-wiring mutation fixtures"; fail=1; mut_dir=""
  }
  if [[ -n "$mut_dir" ]]; then
    # Control: good wiring passes.
    mut_wf="$mut_dir/good.yml"
    _write_good_pin_wiring_fixture "$mut_wf"
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  ok   — mutation control: good extract+output+consume wiring passes"
    else
      echo "  FAIL — mutation control: good wiring rejected: ${reason}"; fail=1
    fi

    # Comments alone (same bare strings as the old weak check) must fail.
    mut_wf="$mut_dir/comments-only.yml"
    cat >"$mut_wf" <<'EOF'
# Exact ShellCheck pin — machine source is scripts/tests/run-all.sh
# (SHELLCHECK_REQUIRED_VERSION + SHELLCHECK_SHA256_LINUX_X86_64). Do not
# restate version/digest here; extract strict assignment lines only.
- name: Install ShellCheck
  run: |
    # hardcoded install — no extract_strict, no GITHUB_OUTPUT, no sc_pin
    curl -fsSL -o shellcheck.tar.xz "https://example.invalid/shellcheck.tar.xz"
EOF
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  FAIL — mutation comments-only unexpectedly passed wiring check"; fail=1
    else
      echo "  ok   — mutation: comments-only wiring fails closed"
    fi

    # Exact accepted wiring operations, every line a full-line comment — must
    # fail closed. Proves greps cannot be satisfied by commented-out command text.
    mut_wf="$mut_dir/commented-out-wiring.yml"
    cat >"$mut_wf" <<'EOF'
# version=$(extract_strict SHELLCHECK_REQUIRED_VERSION '[0-9]+\.[0-9]+\.[0-9]+')
# digest=$(extract_strict SHELLCHECK_SHA256_LINUX_X86_64 '[0-9a-f]{64}')
# echo "version=${version}" >> "$GITHUB_OUTPUT"
# echo "digest=${digest}" >> "$GITHUB_OUTPUT"
# SC_VERSION="${{ steps.sc_pin.outputs.version }}"
# SC_SHA256="${{ steps.sc_pin.outputs.digest }}"
EOF
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  FAIL — mutation commented-out-wiring unexpectedly passed"; fail=1
    else
      echo "  ok   — mutation: commented-out exact wiring fails closed"
    fi

    # Extract + GITHUB_OUTPUT present but install does not consume sc_pin outputs.
    mut_wf="$mut_dir/missing-consumer.yml"
    cat >"$mut_wf" <<'EOF'
- name: Resolve ShellCheck pin from run-all.sh
  id: sc_pin
  run: |
    pin_file="scripts/tests/run-all.sh"
    version=$(extract_strict SHELLCHECK_REQUIRED_VERSION '[0-9]+\.[0-9]+\.[0-9]+')
    digest=$(extract_strict SHELLCHECK_SHA256_LINUX_X86_64 '[0-9a-f]{64}')
    {
      echo "version=${version}"
      echo "digest=${digest}"
    } >> "$GITHUB_OUTPUT"
- name: Install ShellCheck
  run: |
    SC_VERSION="hardcoded-not-from-sc-pin"
    SC_SHA256="also-hardcoded"
EOF
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  FAIL — mutation missing-consumer unexpectedly passed"; fail=1
    else
      echo "  ok   — mutation: missing steps.sc_pin.outputs consumer fails closed"
    fi

    # Extract present but neither value written to GITHUB_OUTPUT.
    mut_wf="$mut_dir/missing-github-output.yml"
    cat >"$mut_wf" <<'EOF'
- name: Resolve ShellCheck pin from run-all.sh
  id: sc_pin
  run: |
    version=$(extract_strict SHELLCHECK_REQUIRED_VERSION '[0-9]+\.[0-9]+\.[0-9]+')
    digest=$(extract_strict SHELLCHECK_SHA256_LINUX_X86_64 '[0-9a-f]{64}')
    echo "resolved but not emitted"
- name: Install ShellCheck
  run: |
    SC_VERSION="${{ steps.sc_pin.outputs.version }}"
    SC_SHA256="${{ steps.sc_pin.outputs.digest }}"
EOF
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  FAIL — mutation missing-GITHUB_OUTPUT unexpectedly passed"; fail=1
    else
      echo "  ok   — mutation: missing GITHUB_OUTPUT emit fails closed"
    fi

    # Active log echos of the correct version=/digest= values PLUS an active
    # unrelated GITHUB_OUTPUT write must fail closed. Independent greps would
    # pass this fixture; the coupled emit check must not.
    mut_wf="$mut_dir/log-only-unrelated-github-output.yml"
    cat >"$mut_wf" <<'EOF'
- name: Resolve ShellCheck pin from run-all.sh
  id: sc_pin
  run: |
    pin_file="scripts/tests/run-all.sh"
    version=$(extract_strict SHELLCHECK_REQUIRED_VERSION '[0-9]+\.[0-9]+\.[0-9]+')
    digest=$(extract_strict SHELLCHECK_SHA256_LINUX_X86_64 '[0-9a-f]{64}')
    echo "version=${version}"
    echo "digest=${digest}"
    echo "unrelated=not-the-pin" >> "$GITHUB_OUTPUT"
- name: Install ShellCheck
  run: |
    SC_VERSION="${{ steps.sc_pin.outputs.version }}"
    SC_SHA256="${{ steps.sc_pin.outputs.digest }}"
EOF
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  FAIL — mutation log-only+unrelated-GITHUB_OUTPUT unexpectedly passed"; fail=1
    else
      echo "  ok   — mutation: log-only correct values + unrelated GITHUB_OUTPUT fails closed"
    fi

    # Same-line log-only pin text coupled via && to an unrelated GITHUB_OUTPUT
    # redirect must fail closed. A naive "key + >> + GITHUB_OUTPUT on one line"
    # check would false-green this fixture.
    mut_wf="$mut_dir/same-line-log-only-unrelated-github-output.yml"
    cat >"$mut_wf" <<'EOF'
- name: Resolve ShellCheck pin from run-all.sh
  id: sc_pin
  run: |
    pin_file="scripts/tests/run-all.sh"
    version=$(extract_strict SHELLCHECK_REQUIRED_VERSION '[0-9]+\.[0-9]+\.[0-9]+')
    digest=$(extract_strict SHELLCHECK_SHA256_LINUX_X86_64 '[0-9a-f]{64}')
    echo "version=${version}" && echo "unrelated=x" >> "$GITHUB_OUTPUT"
    echo "digest=${digest}" && echo "other=y" >> "$GITHUB_OUTPUT"
- name: Install ShellCheck
  run: |
    SC_VERSION="${{ steps.sc_pin.outputs.version }}"
    SC_SHA256="${{ steps.sc_pin.outputs.digest }}"
EOF
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  FAIL — mutation same-line log-only+unrelated-GITHUB_OUTPUT unexpectedly passed"; fail=1
    else
      echo "  ok   — mutation: same-line log-only pin text + unrelated GITHUB_OUTPUT fails closed"
    fi

    # Brace group with closer >> GITHUB_OUTPUT but pin echos silenced via
    # inner >/dev/null — only remaining stdout reaches GITHUB_OUTPUT. Must
    # fail closed; substring pin-text credit would false-green this.
    mut_wf="$mut_dir/brace-inner-dev-null.yml"
    cat >"$mut_wf" <<'EOF'
- name: Resolve ShellCheck pin from run-all.sh
  id: sc_pin
  run: |
    pin_file="scripts/tests/run-all.sh"
    version=$(extract_strict SHELLCHECK_REQUIRED_VERSION '[0-9]+\.[0-9]+\.[0-9]+')
    digest=$(extract_strict SHELLCHECK_SHA256_LINUX_X86_64 '[0-9a-f]{64}')
    {
      echo "version=${version}" >/dev/null
      echo "digest=${digest}" >/dev/null
      echo "unrelated=x"
    } >> "$GITHUB_OUTPUT"
- name: Install ShellCheck
  run: |
    SC_VERSION="${{ steps.sc_pin.outputs.version }}"
    SC_SHA256="${{ steps.sc_pin.outputs.digest }}"
EOF
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  FAIL — mutation brace-inner-dev-null unexpectedly passed"; fail=1
    else
      echo "  ok   — mutation: brace-group pin echos with inner >/dev/null fails closed"
    fi

    # Conditional closer: exact plain pin echos inside braces, but the closer
    # is `} && echo "unrelated=x" >> "$GITHUB_OUTPUT"`. Brace-group stdout is
    # not redirected to GITHUB_OUTPUT; token co-location of >> and
    # GITHUB_OUTPUT on the closer must not false-green.
    mut_wf="$mut_dir/conditional-closer.yml"
    cat >"$mut_wf" <<'EOF'
- name: Resolve ShellCheck pin from run-all.sh
  id: sc_pin
  run: |
    pin_file="scripts/tests/run-all.sh"
    version=$(extract_strict SHELLCHECK_REQUIRED_VERSION '[0-9]+\.[0-9]+\.[0-9]+')
    digest=$(extract_strict SHELLCHECK_SHA256_LINUX_X86_64 '[0-9a-f]{64}')
    {
      echo "version=${version}"
      echo "digest=${digest}"
    } && echo "unrelated=x" >> "$GITHUB_OUTPUT"
- name: Install ShellCheck
  run: |
    SC_VERSION="${{ steps.sc_pin.outputs.version }}"
    SC_SHA256="${{ steps.sc_pin.outputs.digest }}"
EOF
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  FAIL — mutation conditional-closer unexpectedly passed"; fail=1
    else
      echo "  ok   — mutation: conditional closer (} && … >> GITHUB_OUTPUT) fails closed"
    fi

    # Inner exec redirects remaining brace-group stdout to /dev/null before the
    # plain pin echos; neither pin reaches GITHUB_OUTPUT. Exact key lines alone
    # must not false-green — only the strict consecutive four-line sequence.
    mut_wf="$mut_dir/brace-inner-exec-dev-null.yml"
    cat >"$mut_wf" <<'EOF'
- name: Resolve ShellCheck pin from run-all.sh
  id: sc_pin
  run: |
    pin_file="scripts/tests/run-all.sh"
    version=$(extract_strict SHELLCHECK_REQUIRED_VERSION '[0-9]+\.[0-9]+\.[0-9]+')
    digest=$(extract_strict SHELLCHECK_SHA256_LINUX_X86_64 '[0-9a-f]{64}')
    {
      exec >/dev/null
      echo "version=${version}"
      echo "digest=${digest}"
    } >> "$GITHUB_OUTPUT"
- name: Install ShellCheck
  run: |
    SC_VERSION="${{ steps.sc_pin.outputs.version }}"
    SC_SHA256="${{ steps.sc_pin.outputs.digest }}"
EOF
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  FAIL — mutation brace-inner-exec-dev-null unexpectedly passed"; fail=1
    else
      echo "  ok   — mutation: brace-group with inner exec >/dev/null fails closed"
    fi

    # Version restatement forms: colon env, equals, alternate key, URL, comment.
    # Each starts from good wiring then injects the exact pin literal.
    local form body
    for form in \
      "colon:SC_VERSION: ${SHELLCHECK_REQUIRED_VERSION}" \
      "equals:SC_VERSION=${SHELLCHECK_REQUIRED_VERSION}" \
      "altkey:PIN_VERSION: ${SHELLCHECK_REQUIRED_VERSION}" \
      "url:https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_REQUIRED_VERSION}/shellcheck-v${SHELLCHECK_REQUIRED_VERSION}.linux.x86_64.tar.xz" \
      "comment:# pinned ShellCheck is ${SHELLCHECK_REQUIRED_VERSION}"; do
      body="${form#*:}"
      form="${form%%:*}"
      mut_wf="$mut_dir/version-${form}.yml"
      _write_good_pin_wiring_fixture "$mut_wf"
      printf '\n# mutation inject\n%s\n' "$body" >>"$mut_wf"
      if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
        echo "  FAIL — mutation version-${form} restatement unexpectedly passed"; fail=1
      else
        echo "  ok   — mutation: version restatement (${form}) fails closed"
      fi
    done

    # Digest restatement (literal-safe, same family as version).
    mut_wf="$mut_dir/digest-restate.yml"
    _write_good_pin_wiring_fixture "$mut_wf"
    printf '\nSC_SHA256: %s\n' "$SHELLCHECK_SHA256_LINUX_X86_64" >>"$mut_wf"
    if reason=$(assert_workflow_shellcheck_pin_wiring "$mut_wf"); then
      echo "  FAIL — mutation digest restatement unexpectedly passed"; fail=1
    else
      echo "  ok   — mutation: digest restatement fails closed"
    fi

    rm -rf "$mut_dir"
  fi
  if [[ "$fail" -eq 0 ]]; then
    echo "run-all: toolchain self-test GREEN"
    return 0
  fi
  echo "run-all: toolchain self-test RED"
  return 1
}

ONLY=""
TIMEOUT=600
USE_QUARANTINE=1
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --no-quarantine) USE_QUARANTINE=0; shift ;;
    --quiet) QUIET=1; shift ;;
    --list-quarantine)
      echo "$QUARANTINE" | while IFS="$(printf '\t')" read -r s i r; do
        [[ -n "$s" ]] || continue
        printf '%-28s #%-4s %s\n' "$s" "$i" "$r"
      done
      exit 0 ;;
    --self-test-toolchain)
      self_test_toolchain
      exit $?
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run-all.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*) echo "run-all.sh: --timeout wants a whole number of seconds" >&2; exit 2 ;;
esac

cd "$REPO_ROOT" || exit 2

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
[[ -t 1 ]] || { RED=""; GRN=""; YEL=""; OFF=""; }

FAILED=""      # names of required checks that failed
QUARANTINED="" # quarantined suites that failed as expected
ESCAPED=""     # quarantined suites that passed — shrink the list

quarantine_issue() {
  echo "$QUARANTINE" | awk -F'\t' -v s="$1" '$1 == s { print $2; exit }'
}

is_quarantined() {
  [[ "$USE_QUARANTINE" -eq 1 ]] && [[ -n "$(quarantine_issue "$1")" ]]
}

# Run a command with a timeout when one is available; 124 means it hung.
run_limited() {
  if [[ "$TIMEOUT" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" "$@"
  else
    "$@"
  fi
}

# scripts/ and adapters/ — both ship bash that must stay Bash-3.2 clean
# (adapters/goose/*.sh enter the gate here; #192).
SH_FILES=$(find scripts adapters -name '*.sh' -type f | sort)

# --- 0. toolchain -----------------------------------------------------------
echo "== toolchain"
# Offline self-test runs in the ordinary path CI invokes (not only via the
# focused --self-test-toolchain entry point). A red self-test fails the gate.
echo "  — offline toolchain self-test"
if self_test_toolchain; then
  :
else
  FAILED="$FAILED toolchain-self-test"
fi
if command -v jq >/dev/null 2>&1; then
  JQ_V=$(jq --version 2>/dev/null | sed 's/^jq-//')
  JQ_MAJ=${JQ_V%%.*}; JQ_REST=${JQ_V#*.}; JQ_MIN=${JQ_REST%%.*}
  case "$JQ_MAJ$JQ_MIN" in
    *[!0-9]*|'') echo "${RED}  FAIL${OFF} — cannot read jq version ('$JQ_V')"; FAILED="$FAILED jq-version" ;;
    *)
      if [[ "$JQ_MAJ" -gt "$JQ_MIN_MAJOR" ]] ||
         { [[ "$JQ_MAJ" -eq "$JQ_MIN_MAJOR" ]] && [[ "$JQ_MIN" -ge "$JQ_MIN_MINOR" ]]; }; then
        echo "${GRN}  ok${OFF}   — jq $JQ_V"
      else
        echo "${RED}  FAIL${OFF} — jq $JQ_V is below ${JQ_MIN_MAJOR}.${JQ_MIN_MINOR}: release-preflight accepts"
        echo "         unverifiable approval timestamps on this jq and returns READY (#91)"
        FAILED="$FAILED jq-too-old"
      fi ;;
  esac
else
  echo "${RED}  FAIL${OFF} — jq not installed; preflight and several sensors need it"
  FAILED="$FAILED jq-missing"
fi

# Exact ShellCheck version (same pin as .github/workflows/gibson-self-gate.yml).
# Probe once: SC_OK=1 only when the parsed version equals the pin; baseline
# compare reuses this flag and never re-runs shellcheck --version.
SC_OK=0
SC_V=""
if command -v shellcheck >/dev/null 2>&1; then
  SC_RAW=$(shellcheck --version 2>/dev/null || true)
  SC_V=$(parse_shellcheck_version "$SC_RAW")
  if [[ -z "$SC_V" ]]; then
    echo "${RED}  FAIL${OFF} — cannot read shellcheck version from:"
    echo "$SC_RAW" | sed 's/^/         /'
    FAILED="$FAILED shellcheck-version"
  elif shellcheck_version_matches_pin "$SC_V"; then
    SC_OK=1
    echo "${GRN}  ok${OFF}   — shellcheck $SC_V (exact pin for baseline semantics)"
  else
    echo "${RED}  FAIL${OFF} — shellcheck $SC_V is not the pinned $SHELLCHECK_REQUIRED_VERSION"
    echo "         The ShellCheck baseline is an exact-set ratchet: different tool"
    echo "         versions report different findings, so local and CI must match."
    echo "         There is no version override — a wrong tool is a red gate by design."
    echo
    print_shellcheck_install_remediation
    FAILED="$FAILED shellcheck-version-mismatch"
  fi
else
  echo "${RED}  FAIL${OFF} — shellcheck not installed; the gate cannot vouch for these scripts"
  print_shellcheck_install_remediation
  FAILED="$FAILED shellcheck-missing"
fi

# The claim suites build throwaway repos and commit into them, so they need an
# identity. Inherit one if the host has it; otherwise supply a local one rather
# than failing for a reason that has nothing to do with the code under test.
if [[ -z "${GIT_AUTHOR_EMAIL:-}" ]] && ! git config user.email >/dev/null 2>&1; then
  export GIT_AUTHOR_NAME="gibson-run-all" GIT_AUTHOR_EMAIL="run-all@gibson.invalid"
  export GIT_COMMITTER_NAME="gibson-run-all" GIT_COMMITTER_EMAIL="run-all@gibson.invalid"
  echo "${YEL}  NOTE${OFF} — no git identity on this host; using a throwaway one (#101)"
fi

# --- 1. shellcheck vs baseline ---------------------------------------------
# Gated on SC_OK from the single toolchain probe above (no second --version).
echo "== shellcheck (-S warning, vs baseline)"
if [[ "$SC_OK" -eq 1 ]]; then
  # shellcheck disable=SC2086
  # awk, not sed: "\t" in a sed replacement is a literal t on BSD sed (#93 is
  # the same lesson one layer down — portability shims that work by accident).
  CURRENT=$(shellcheck -S warning -f gcc $SH_FILES 2>/dev/null |
    awk 'match($0, /\[SC[0-9]+\]$/) {
           code = substr($0, RSTART + 1, RLENGTH - 2)
           split($0, a, ":")
           print a[1] "\t" code
         }' | sort -u || true)
  BASE=$( [[ -f "$BASELINE" ]] && grep -vE '^\s*(#|$)' "$BASELINE" | sort || true )

  NEWF=$(comm -23 <(echo "$CURRENT") <(echo "$BASE") | grep -E '\S' || true)
  GONE=$(comm -13 <(echo "$CURRENT") <(echo "$BASE") | grep -E '\S' || true)

  if [[ -n "$NEWF" ]]; then
    echo "${RED}  FAIL${OFF} — new shellcheck findings not in the baseline:"
    echo "$NEWF" | sed 's/^/         /'
    FAILED="$FAILED shellcheck"
  elif [[ -n "$GONE" ]]; then
    echo "${RED}  FAIL${OFF} — baseline entries no longer reported; delete them from"
    echo "         $(basename "$BASELINE") so the ratchet holds:"
    echo "$GONE" | sed 's/^/         /'
    FAILED="$FAILED shellcheck-baseline-stale"
  else
    echo "${GRN}  ok${OFF}   — no findings outside the baseline (shellcheck $SC_V)"
  fi
elif command -v shellcheck >/dev/null 2>&1; then
  echo "${YEL}  SKIP${OFF} — shellcheck baseline compare requires $SHELLCHECK_REQUIRED_VERSION"
  echo "         (version check already failed above; not comparing against a wrong tool)"
else
  echo "${YEL}  SKIP${OFF} — shellcheck missing (already failed in toolchain)"
fi

# --- 2. syntax --------------------------------------------------------------
echo "== bash -n"
SYNTAX_BAD=""
for f in $SH_FILES; do
  bash -n "$f" 2>/tmp/run-all-syntax.$$ || {
    echo "${RED}  FAIL${OFF} — $f"; sed 's/^/         /' /tmp/run-all-syntax.$$
    SYNTAX_BAD=1
  }
done
rm -f /tmp/run-all-syntax.$$
if [[ -n "$SYNTAX_BAD" ]]; then FAILED="$FAILED bash-n"; else
  echo "${GRN}  ok${OFF}   — $(echo "$SH_FILES" | wc -l | tr -d ' ') scripts parse"
fi

echo "== bash 3.2 (stock macOS)"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  if run_limited docker run --rm -v "$REPO_ROOT:/w" -w /w bash:3.2 \
       bash -n $SH_FILES >/tmp/run-all-32.$$ 2>&1; then
    echo "${GRN}  ok${OFF}   — parses under bash 3.2"
  else
    echo "${RED}  FAIL${OFF} — bash 3.2 syntax:"; sed 's/^/         /' /tmp/run-all-32.$$
    FAILED="$FAILED bash-3.2"
  fi
  rm -f /tmp/run-all-32.$$
else
  echo "${YEL}  SKIP${OFF} — no usable docker; bash 3.2 unverified on this host"
fi

# --- 2b. bash-4 builtins (runtime-only on 3.2; bash -n does not catch them) --
# mapfile/readarray/declare -A / ${var^^} / ${var,,} / &>> parse under bash -n
# on modern bash but fail at RUNTIME on stock macOS 3.2.57. Grep sensor (#192).
# One grep -E per pattern over comment-stripped lines. Plumbing errors fail
# the sensor (no 2>/dev/null || true). Double-quoted spans stay visible so
# echo "${name^^}" is not hidden.
echo "== bash-4 builtins (grep sensor)"
BASH4_HITS=""
BASH4_PLUMB=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  hits=$(cs_bash4_hits "$f")
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    BASH4_PLUMB=1
    BASH4_HITS="${BASH4_HITS}${f}: sensor plumbing failed"$'\n'
  elif [[ "$rc" -eq 1 ]]; then
    BASH4_HITS="${BASH4_HITS}${hits}"$'\n'
  fi
done <<< "$SH_FILES"

if [[ "$BASH4_PLUMB" -ne 0 ]]; then
  echo "${RED}  FAIL${OFF} — bash-4 sensor plumbing failed (fail closed):"
  printf '%s' "$BASH4_HITS" | sed 's/^/         /'
  FAILED="$FAILED bash-4-builtins-plumbing"
elif [[ -n "$BASH4_HITS" ]]; then
  echo "${RED}  FAIL${OFF} — bash-4-only constructs (fail at runtime on macOS 3.2):"
  printf '%s' "$BASH4_HITS" | sed 's/^/         /'
  FAILED="$FAILED bash-4-builtins"
else
  echo "${GRN}  ok${OFF}   — no mapfile/readarray/declare -A/\${^^}/\${,,}/&>> in code"
fi

# --- 2c. SCRIPT_DIR spelling (#192) ----------------------------------------
# Canonical form (CDPATH guard + double-dash + BASH_SOURCE):
#   SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Sourced libraries that intentionally never set SCRIPT_DIR (claim-guards,
# stream-capture, silent-noop body, delivery-control/lib) are fine — this
# sensor only rejects non-canonical *assignments*.
echo "== SCRIPT_DIR convention"
SCRIPT_DIR_HITS=""
SCRIPT_DIR_PLUMB=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  hits=$(cs_script_dir_hits "$f")
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    SCRIPT_DIR_PLUMB=1
    SCRIPT_DIR_HITS="${SCRIPT_DIR_HITS}${f}: sensor plumbing failed"$'\n'
  elif [[ "$rc" -eq 1 ]]; then
    SCRIPT_DIR_HITS="${SCRIPT_DIR_HITS}${hits}"$'\n'
  fi
done <<< "$SH_FILES"

if [[ "$SCRIPT_DIR_PLUMB" -ne 0 ]]; then
  echo "${RED}  FAIL${OFF} — SCRIPT_DIR sensor plumbing failed (fail closed):"
  printf '%s' "$SCRIPT_DIR_HITS" | sed 's/^/         /'
  FAILED="$FAILED script-dir-plumbing"
elif [[ -n "$SCRIPT_DIR_HITS" ]]; then
  echo "${RED}  FAIL${OFF} — non-canonical SCRIPT_DIR assignment(s):"
  printf '%s' "$SCRIPT_DIR_HITS" | sed 's/^/         /'
  echo "         want: $SCRIPT_DIR_CANON"
  FAILED="$FAILED script-dir-convention"
else
  echo "${GRN}  ok${OFF}   — all SCRIPT_DIR assignments match the canonical form"
fi

# --- 2d. info()/warn() must write to stderr (#192) --------------------------
# info() on stdout pollutes pipes (claim.sh used to). Every info/warn body
# must redirect to >&2.
echo "== info/warn stderr"
INFO_WARN_HITS=""
INFO_WARN_PLUMB=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  hits=$(cs_info_warn_hits "$f")
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    INFO_WARN_PLUMB=1
    INFO_WARN_HITS="${INFO_WARN_HITS}${f}: sensor plumbing failed"$'\n'
  elif [[ "$rc" -eq 1 ]]; then
    INFO_WARN_HITS="${INFO_WARN_HITS}${hits}"$'\n'
  fi
done <<< "$SH_FILES"

if [[ "$INFO_WARN_PLUMB" -ne 0 ]]; then
  echo "${RED}  FAIL${OFF} — info/warn sensor plumbing failed (fail closed):"
  printf '%s' "$INFO_WARN_HITS" | sed 's/^/         /'
  FAILED="$FAILED info-warn-plumbing"
elif [[ -n "$INFO_WARN_HITS" ]]; then
  echo "${RED}  FAIL${OFF} — info()/warn() without >&2 (stdout pollutes pipes):"
  printf '%s' "$INFO_WARN_HITS" | sed 's/^/         /'
  FAILED="$FAILED info-warn-stderr"
else
  echo "${GRN}  ok${OFF}   — info()/warn() bodies redirect to stderr"
fi

# --- 2e. tool guards: jq / gh / node / python3 (#192) -----------------------
# A production script that *invokes* one of these tools must also *guard* it
# (need_cmd X, command -v X, require_python3, or command -v "$GH_BIN").
# Test files are allowlisted. Scripts that only mention a tool in help text
# are not invocations (command-position match only).
echo "== tool guards (jq/gh/node/python3)"
# TOOL_GUARD_BASELINE: pre-existing unguarded invocations outside this batch's
# retrofit list. Shrink only — do not grow without a burn-down note.
# file<TAB>tool
TOOL_GUARD_BASELINE=$(cat <<'EOF'
scripts/loop.sh	node
EOF
)
TOOL_GUARD_HITS=""
TOOL_GUARD_PLUMB=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  hits=$(cs_tool_guard_hits "$f")
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    TOOL_GUARD_PLUMB=1
    TOOL_GUARD_HITS="${TOOL_GUARD_HITS}${f}: sensor plumbing failed"$'\n'
    continue
  fi
  [[ "$rc" -eq 0 || -z "$hits" ]] && continue
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # hit format: "file  tool  N: orig"
    _tf=${line%%  *}
    _rest=${line#*  }
    _tt=${_rest%%  *}
    if echo "$TOOL_GUARD_BASELINE" | grep -qxF "${_tf}	${_tt}"; then
      continue
    fi
    TOOL_GUARD_HITS="${TOOL_GUARD_HITS}${line}"$'\n'
  done <<< "$hits"
done <<< "$SH_FILES"

# Ratchet: baseline entries that no longer fire (file now line-order guarded)
# must be removed.
TOOL_GUARD_STALE=""
while IFS= read -r row; do
  [[ -z "$row" || "$row" =~ ^# ]] && continue
  bf=${row%%	*}; bt=${row#*	}
  [[ -f "$bf" ]] || { TOOL_GUARD_STALE="${TOOL_GUARD_STALE}${row} (missing file)"$'\n'; continue; }
  _now=$(cs_tool_guard_hits "$bf") || true
  if ! printf '%s\n' "$_now" | grep -q "  ${bt}  "; then
    TOOL_GUARD_STALE="${TOOL_GUARD_STALE}${row}"$'\n'
  fi
done <<< "$TOOL_GUARD_BASELINE"

if [[ "$TOOL_GUARD_PLUMB" -ne 0 ]]; then
  echo "${RED}  FAIL${OFF} — tool-guard sensor plumbing failed (fail closed):"
  printf '%s' "$TOOL_GUARD_HITS" | sed 's/^/         /'
  FAILED="$FAILED tool-guards-plumbing"
elif [[ -n "$TOOL_GUARD_HITS" ]]; then
  echo "${RED}  FAIL${OFF} — tool invoked without need_cmd/command -v guard:"
  printf '%s' "$TOOL_GUARD_HITS" | sed 's/^/         /'
  FAILED="$FAILED tool-guards"
elif [[ -n "$TOOL_GUARD_STALE" ]]; then
  echo "${RED}  FAIL${OFF} — tool-guard baseline entries no longer needed; remove them:"
  printf '%s' "$TOOL_GUARD_STALE" | sed 's/^/         /'
  FAILED="$FAILED tool-guards-baseline-stale"
else
  echo "${GRN}  ok${OFF}   — jq/gh/node/python3 invocations are guarded (or baselined)"
fi

# --- 2g. vendored mjs self-containment (#192) -------------------------------
# ci/gibson-gate.yml sparse-checks out ONLY scripts/test-integrity.mjs into
# the isolated grader. Adopters vendor that file plus check-active-work.mjs
# and route-inventory.mjs as single files (ci/README.md names the latter
# bare). A relative import (./ or ../ — static, side-effect, dynamic, or
# re-export) dies with ERR_MODULE_NOT_FOUND.
echo "== vendored mjs self-containment"
VENDOR_HITS=""
VENDOR_RC=0
VENDOR_HITS=$(cs_vendored_selfcontained "$REPO_ROOT") || VENDOR_RC=$?
if [[ "$VENDOR_RC" -eq 2 ]]; then
  echo "${RED}  FAIL${OFF} — vendored-mjs sensor plumbing failed (fail closed)"
  printf '%s\n' "$VENDOR_HITS" | sed 's/^/         /'
  FAILED="$FAILED vendored-mjs-plumbing"
elif [[ "$VENDOR_RC" -ne 0 ]]; then
  echo "${RED}  FAIL${OFF} — vendored scripts/*.mjs must be single-file (no relative import ./ or ../):"
  printf '%s' "$VENDOR_HITS" | sed 's/^/         /'
  FAILED="$FAILED vendored-mjs-selfcontained"
else
  echo "${GRN}  ok${OFF}   — vendored-listed scripts/*.mjs have no relative imports"
fi

# --- 2f. mjs unknown-flag contract (#192) -----------------------------------
# Every scripts/*.mjs must exit 2 on --definitely-not-a-flag with
# "unknown flag:" or "unknown option:" on stderr. args.mjs uses "flag";
# policy-manifest.mjs (upstream #188) uses "option". Do not retrofit that
# parser — the contract is the exit code plus either wording.
echo "== mjs unknown-flag"
MJS_FLAG_HITS=""
if command -v node >/dev/null 2>&1; then
  while IFS= read -r mjs; do
    [[ -f "$mjs" ]] || continue
    _outf=$(mktemp "${TMPDIR:-/tmp}/mjs-flag-out.XXXXXX")
    _errf=$(mktemp "${TMPDIR:-/tmp}/mjs-flag-err.XXXXXX")
    node "$mjs" --definitely-not-a-flag >"$_outf" 2>"$_errf"
    rc=$?
    if [[ "$rc" -ne 2 ]] || ! grep -qE 'unknown (flag|option):' "$_errf"; then
      MJS_FLAG_HITS="${MJS_FLAG_HITS}${mjs} (rc=$rc stderr=$(head -1 "$_errf") stdout=$(head -1 "$_outf"))"$'\n'
    fi
    rm -f "$_outf" "$_errf"
  done < <(find scripts -maxdepth 1 -name '*.mjs' -type f | sort)
  if [[ -n "$MJS_FLAG_HITS" ]]; then
    echo "${RED}  FAIL${OFF} — scripts/*.mjs must exit 2 on unknown --flag:"
    printf '%s' "$MJS_FLAG_HITS" | sed 's/^/         /'
    FAILED="$FAILED mjs-unknown-flag"
  else
    n_mjs=$(find scripts -maxdepth 1 -name '*.mjs' -type f | wc -l | tr -d ' ')
    echo "${GRN}  ok${OFF}   — $n_mjs scripts/*.mjs reject --definitely-not-a-flag (exit 2)"
  fi
else
  echo "${RED}  FAIL${OFF} — node not installed; cannot probe mjs unknown-flag contract"
  FAILED="$FAILED mjs-unknown-flag-node-missing"
fi

# --- 3. injection scan ------------------------------------------------------
echo "== injection-scan"
if [[ -x scripts/injection-scan.sh ]]; then
  if OUT=$(./scripts/injection-scan.sh 2>&1); then
    echo "${GRN}  ok${OFF}   — ${OUT##*$'\n'}"
  else
    echo "${RED}  FAIL${OFF} — invisible characters found:"; echo "$OUT" | sed 's/^/         /'
    FAILED="$FAILED injection-scan"
  fi
else
  echo "${RED}  FAIL${OFF} — scripts/injection-scan.sh missing or not executable"
  FAILED="$FAILED injection-scan-missing"
fi

# --- 4. sensor suites -------------------------------------------------------
echo "== sensors"

# Predicate used below: shell-construction diagnostics must never green a
# nominally-passing suite (#153 review round 7). Mutation proof for the exact
# six-unbound-variable class observed under set -u + unquoted fixture heredocs.
suite_has_shell_construction_diag() {
  # stdin: suite captured stdout+stderr
  grep -qE 'unbound variable|command not found|:[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]+not found'
}
{
  _mut_probe=$(mktemp "${TMPDIR:-/tmp}/gibson-runall-shell-diag.XXXXXX")
  {
    echo "  ok   — synthetic"
    for _i in 1 2 3 4 5 6; do
      echo "scripts/tests/release-claim.test.sh: line 1391: \$2: unbound variable"
    done
    echo "release-claim.test.sh: 507 passed, 0 failed"
  } > "$_mut_probe"
  if suite_has_shell_construction_diag < "$_mut_probe"; then
    echo "${GRN}  ok${OFF}   — mutation: six-unbound-variable class is rejected by the shell-diag gate"
  else
    echo "${RED}  FAIL${OFF} — mutation: six-unbound-variable class slipped the shell-diag gate"
    FAILED="$FAILED shell-diag-mutation"
  fi
  # Clean green tally with no diagnostics must not trip the gate.
  {
    echo "  ok   — synthetic"
    echo "release-claim.test.sh: 507 passed, 0 failed"
  } > "$_mut_probe"
  if suite_has_shell_construction_diag < "$_mut_probe"; then
    echo "${RED}  FAIL${OFF} — mutation: clean suite tally falsely tripped the shell-diag gate"
    FAILED="$FAILED shell-diag-mutation-false-positive"
  else
    echo "${GRN}  ok${OFF}   — mutation: clean suite tally does not trip the shell-diag gate"
  fi
  rm -f "$_mut_probe"
  unset _mut_probe _i
}

for suite in scripts/tests/*.test.sh; do
  name=$(basename "$suite")
  [[ -z "$ONLY" || "$name" == *"$ONLY"* ]] || continue

  if [[ ! -x "$suite" ]]; then
    echo "${RED}  FAIL${OFF} — $name is not executable"
    FAILED="$FAILED $name"
    continue
  fi

  out=$(run_limited "$suite" 2>&1); ec=$?
  # grep -o, not a greedy sed capture: `.*([0-9]+ passed` eats all but the last
  # digit and turns "42 passed" into "2 passed".
  # Prefer extended tally (goose-validate disposition, #95); fall back to plain.
  tally=$(echo "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed(, goose-validate: [^[:space:]]+)?' | tail -1)
  [[ -n "$tally" ]] || tally="no tally line"
  [[ "$ec" -eq 124 ]] && tally="timed out after ${TIMEOUT}s"

  # Shell-construction diagnostics must never green a nominally-passing suite
  # (#153 review round 7). An unquoted heredoc under `set -u` can print
  # `unbound variable` six times while the suite still tallies 0 failed and
  # exits 0 — --quiet used to hide that. Reject only diagnostic classes that
  # prove the suite (or a fixture it generated) is misconstructed, not
  # ordinary assertion text that happens to mention those phrases.
  shell_diag=""
  if printf '%s\n' "$out" | suite_has_shell_construction_diag; then
    shell_diag=$(printf '%s\n' "$out" | grep -E \
      'unbound variable|command not found|:[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]+not found' |
      head -20)
  fi

  if [[ "$QUIET" -eq 0 && ( "$ec" -ne 0 || -n "$shell_diag" ) ]]; then
    echo "$out" | grep -E '^\s*FAIL|unbound variable|command not found|:[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]+not found' |
      head -20 | sed 's/^/         /'
  fi

  if [[ -n "$shell_diag" ]]; then
    echo "${RED}  FAIL${OFF} — $name: shell construction diagnostic with tally '$tally' (exit $ec)"
    echo "$shell_diag" | head -6 | sed 's/^/         /'
    FAILED="$FAILED $name"
  elif [[ "$ec" -eq 0 ]]; then
    if is_quarantined "$name"; then
      echo "${RED}  FAIL${OFF} — $name PASSES but is quarantined (#$(quarantine_issue "$name")) — remove it from the list"
      ESCAPED="$ESCAPED $name"
    else
      echo "${GRN}  ok${OFF}   — $name: $tally"
    fi
  elif is_quarantined "$name"; then
    echo "${YEL}  KNOWN${OFF}— $name: $tally (quarantined, #$(quarantine_issue "$name"))"
    QUARANTINED="$QUARANTINED $name"
  else
    echo "${RED}  FAIL${OFF} — $name: $tally (exit $ec)"
    FAILED="$FAILED $name"
  fi
done

# --- verdict ----------------------------------------------------------------
echo
n_fail=$(echo "$FAILED" | wc -w | tr -d ' ')
n_quar=$(echo "$QUARANTINED" | wc -w | tr -d ' ')
n_esc=$(echo "$ESCAPED" | wc -w | tr -d ' ')

if [[ "$n_quar" -gt 0 ]]; then
  echo "quarantined (known red, burn-down issues open):$QUARANTINED"
fi
if [[ "$n_esc" -gt 0 ]]; then
  echo "quarantined but passing — shrink the list:$ESCAPED"
fi
if [[ "$n_fail" -gt 0 ]]; then
  echo "failed:$FAILED"
fi

if [[ "$n_fail" -eq 0 && "$n_esc" -eq 0 ]]; then
  echo "run-all: GREEN — 0 failed, $n_quar quarantined"
  exit 0
fi
echo "run-all: RED — $n_fail failed, $n_esc escaped quarantine, $n_quar quarantined"
exit 1
