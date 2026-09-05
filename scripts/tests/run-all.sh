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
  scripts/tests/run-all.sh [--only PATTERN] [--timeout SECONDS] [--jobs N]
                           [--wall-budget SECONDS] [--no-quarantine]
                           [--list-quarantine] [--quiet]
  scripts/tests/run-all.sh --self-test-toolchain
  scripts/tests/run-all.sh --metrics-contract-fixture
  scripts/tests/run-all.sh --help

  --only PATTERN[,...]    run only suites whose filename contains any PATTERN
  --timeout SECONDS       per-suite timeout (default 600; 0 disables).
                          Nonzero values use scripts/lib/wall-timeout.sh
                          (perl/python3 process-group watchdog; Bash 3.2).
                          Fails closed before suites if that watchdog cannot
                          start; never silently unbounded. 0 is the explicit
                          opt-out.
  --jobs N                run up to N suites concurrently (default: CPU count,
                          or $GIBSON_TEST_JOBS). Output is still printed one
                          suite at a time in discovery order, so the verdict
                          and metrics are identical to a serial run. 1 = serial.
  --wall-budget SECONDS   gate wall-time budget (default $GIBSON_GATE_WALL_BUDGET,
                          else 0 = report only). A green run that takes longer
                          than this is RED with the slowest suites named, so
                          feedback time is a ratchet like any other sensor.
  --no-quarantine         treat quarantined suites as required — the burn-down view
  --list-quarantine       print the quarantine list with issue links and exit
  --quiet                 suite summary lines only, no per-assertion output
  --self-test-toolchain   offline checks for ShellCheck version parsing/mismatch
                          and single-source pin wiring (no network, no sensors).
                          The ordinary path also runs these checks and fails the
                          gate if they go red.
  --metrics-contract-fixture
                          internal contract-test seam only. Exclusive;
                          not a complete gate or release substitute.
                          Do not combine with other modes. Does not run
                          toolchain, discovery, timeout, injection, isolation,
                          or scripts/tests/*.test.sh.

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
JOBS="${GIBSON_TEST_JOBS:-}"
WALL_BUDGET="${GIBSON_GATE_WALL_BUDGET:-0}"
USE_QUARANTINE=1
QUIET=0
METRICS_CONTRACT_FIXTURE=0

# GIBSON_METRICS_CONTRACT_FIXTURE_PRESCAN
# Presence-only. Do not parse ordinary flags here: --help / --list-quarantine /
# --self-test-toolchain must keep origin/main immediate-exit semantics, so
# trailing arguments cannot change those commands. Guard $# before expanding
# "$@" — Bash 3.2 + set -u treats empty "$@" as unbound.
if [[ $# -gt 0 ]]; then
  for _gibson_arg in "$@"; do
    if [[ "$_gibson_arg" == "--metrics-contract-fixture" ]]; then
      METRICS_CONTRACT_FIXTURE=1
      break
    fi
  done
  unset _gibson_arg
fi

# GIBSON_METRICS_CONTRACT_FIXTURE_PARSE
# Exclusive internal seam: fixture must be the one and only argument. Validate
# now. Do not execute the fixture until the production metrics functions are
# defined below.
if [[ "$METRICS_CONTRACT_FIXTURE" -eq 1 ]]; then
  if [[ $# -ne 1 || "$1" != "--metrics-contract-fixture" ]]; then
    echo "run-all.sh: --metrics-contract-fixture is exclusive and cannot be combined with other modes" >&2
    echo "run-all.sh: --metrics-contract-fixture is an internal contract-test seam, not a complete gate" >&2
    usage >&2
    exit 2
  fi
else
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only) ONLY="${2:-}"; shift 2 ;;
      --timeout) TIMEOUT="${2:-}"; shift 2 ;;
      --jobs) JOBS="${2:-}"; shift 2 ;;
      --wall-budget) WALL_BUDGET="${2:-}"; shift 2 ;;
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
fi

# GIBSON_METRICS_CONTRACT_FIXTURE_SKIP_PREAMBLE
# Ordinary timeout, discovery, toolchain, injection, isolation, and suite
# preamble. Skipped when --metrics-contract-fixture was selected above.
# Body is intentionally unindented so this skip is a small conditional boundary
# rather than a thousand-line re-indent of the ordinary path.
if [[ "$METRICS_CONTRACT_FIXTURE" -ne 1 ]]; then
case "$TIMEOUT" in
  ''|*[!0-9]*) echo "run-all.sh: --timeout wants a whole number of seconds" >&2; exit 2 ;;
esac

# Suite concurrency. Suites are independent processes that sandbox themselves
# under mktemp, so they can run side by side; only their reporting is serial.
if [[ -z "$JOBS" ]]; then
  JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
fi
case "$JOBS" in
  ''|*[!0-9]*|0) echo "run-all.sh: --jobs wants a whole number >= 1" >&2; exit 2 ;;
esac
case "$WALL_BUDGET" in
  ''|*[!0-9]*) echo "run-all.sh: --wall-budget wants a whole number of seconds (0 = report only)" >&2; exit 2 ;;
esac

# Portable suite timeout (#260): reuse scripts/lib/wall-timeout.sh — do not
# duplicate its process-group watchdog, and do not depend on GNU timeout.
WALL_TIMEOUT_LIB="$SCRIPT_DIR/../lib/wall-timeout.sh"
if [[ ! -f "$WALL_TIMEOUT_LIB" ]]; then
  echo "run-all.sh: missing lib/wall-timeout.sh (looked in $SCRIPT_DIR/../lib)" >&2
  exit 2
fi
# shellcheck disable=SC1090,SC1091
source "$WALL_TIMEOUT_LIB"
if ! declare -F run_with_wall_timeout >/dev/null 2>&1; then
  echo "run-all.sh: lib/wall-timeout.sh did not define run_with_wall_timeout" >&2
  exit 2
fi

# Nonzero TIMEOUT needs perl or python3 so the helper can setpgrp + tree-kill.
suite_timeout_capable() {
  command -v perl >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1
}

if [[ "$TIMEOUT" -gt 0 ]] && ! suite_timeout_capable; then
  echo "run-all.sh: --timeout ${TIMEOUT} requires perl or python3 for the portable process-group watchdog (no unbounded fallback). Install one, or pass --timeout 0 to opt out explicitly." >&2
  exit 2
fi

# TIMEOUT 0 = explicit unbounded. Nonzero → helper (124 on wall expiry).
run_limited() {
  if [[ "$TIMEOUT" -eq 0 ]]; then
    "$@"
    return $?
  fi
  run_with_wall_timeout "$TIMEOUT" "$@"
}

cd "$REPO_ROOT" || exit 2
RUN_ALL_T0=$SECONDS

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
  bash -n "$f" 2>"${TMPDIR:-/tmp}/run-all-syntax.$$" || {
    echo "${RED}  FAIL${OFF} — $f"; sed 's/^/         /' "${TMPDIR:-/tmp}/run-all-syntax.$$"
    SYNTAX_BAD=1
  }
done
rm -f "${TMPDIR:-/tmp}/run-all-syntax.$$"
if [[ -n "$SYNTAX_BAD" ]]; then FAILED="$FAILED bash-n"; else
  echo "${GRN}  ok${OFF}   — $(echo "$SH_FILES" | wc -l | tr -d ' ') scripts parse"
fi

echo "== bash 3.2 (stock macOS)"
BASH32_DOCKER_USABLE=0
BASH32_PATHS_SHA256=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  BASH32_DOCKER_USABLE=1
  # shellcheck disable=SC2086
  if run_limited docker run --rm -v "$REPO_ROOT:/w" -w /w bash:3.2 \
       bash scripts/tests/lib/bash32-syntax-each.sh bash $SH_FILES >"${TMPDIR:-/tmp}/run-all-32.$$" 2>&1; then
    bash32_n=$(printf '%s\n' "$SH_FILES" | wc -l | tr -d ' ')
    bash32_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
      bash32_hash=$(printf '%s\n' "$SH_FILES" | LC_ALL=C sort | sha256sum | awk '{print $1}') || bash32_hash=""
    elif command -v shasum >/dev/null 2>&1; then
      bash32_hash=$(printf '%s\n' "$SH_FILES" | LC_ALL=C sort | shasum -a 256 | awk '{print $1}') || bash32_hash=""
    elif command -v openssl >/dev/null 2>&1; then
      bash32_hash=$(printf '%s\n' "$SH_FILES" | LC_ALL=C sort | openssl dgst -sha256 | awk '{print $NF}') || bash32_hash=""
    fi
    bash32_hash=$(printf '%s' "$bash32_hash" | tr 'A-F' 'a-f')
    bash32_parsed=$bash32_n
    if [[ -n "$bash32_n" && "$bash32_n" -gt 0 && "$bash32_n" -eq "$bash32_parsed" ]] \
       && printf '%s' "$bash32_hash" | grep -E '^[0-9a-f]{64}$' >/dev/null; then
      echo "GIBSON_BASH32_SYNTAX schema=gibson.bash32-syntax/v1 discovered=${bash32_n} parsed=${bash32_parsed} paths_sha256=${bash32_hash}"
      BASH32_PATHS_SHA256=$bash32_hash
    else
      echo "${RED}  FAIL${OFF} — bash 3.2 syntax: malformed count/digest evidence"
      FAILED="$FAILED bash-3.2"
    fi
    unset bash32_n bash32_parsed bash32_hash
  else
    echo "${RED}  FAIL${OFF} — bash 3.2 syntax:"; sed 's/^/         /' "${TMPDIR:-/tmp}/run-all-32.$$"
    FAILED="$FAILED bash-3.2"
  fi
  rm -f "${TMPDIR:-/tmp}/run-all-32.$$"
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
    if echo "$TOOL_GUARD_BASELINE" | grep -xF "${_tf}	${_tt}" >/dev/null; then
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
  if ! printf '%s\n' "$_now" | grep "  ${bt}  " >/dev/null; then
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

fi
# GIBSON_METRICS_CONTRACT_FIXTURE_SKIP_PREAMBLE_END

# --- aggregate metrics production seam (#274/#279) --------------------------
# Exactly one terminal GIBSON_TEST_METRICS line, derived from selected suite
# receipts. Not a static count and not a second parser of .agents/gate.json.
# Precedence per selected suite (exactly once), from the last non-empty line:
# terminal machine metric; else exact terminal passed/failed tally plus
# skip/todo on that line; else one legacy no-tally sentinel. Duplicate or
# non-terminal GIBSON_TEST_METRICS, and malformed / negative / fractional /
# overflow input, fail closed. Metric-contract failure is bound into FAILED
# before n_fail/GREEN/RED so the one final verdict cannot print GREEN. Do not
# emit GIBSON_TEST_METRICS when the metric contract failed.
# Defined once. Fixture mode skips the ordinary preamble above and dispatches
# immediately after these functions, before sensor suites execute.
GIBSON_METRICS_MAX_SAFE=9007199254740991

# Reset production metric accumulators. Fixture and ordinary paths both call
# this; it is not a test-only finalizer and does not emit receipts.
gibson_metrics_init() {
  METRIC_TOTAL=0
  METRIC_SKIPPED=0
  METRIC_TODO=0
  METRIC_EXPLICIT=0
  METRIC_SENTINEL=0
  METRIC_SENTINEL_NAMES=""
  METRIC_EXPLICIT_NAMES=""
  METRIC_CONTRACT_FAIL=0
  METRIC_CONTRACT_REASON=""
}

gibson_metrics_fail() {
  METRIC_CONTRACT_FAIL=1
  if [[ -z "$METRIC_CONTRACT_REASON" ]]; then
    METRIC_CONTRACT_REASON="$1"
  fi
}

# Non-negative integer, no leading zeros (except 0), <= MAX_SAFE_INTEGER.
gibson_metrics_is_uinteger() {
  local n="$1" max="$GIBSON_METRICS_MAX_SAFE" len i c1 c2
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
    0) return 0 ;;
    0*) return 1 ;;
  esac
  len=${#n}
  if [[ "$len" -gt 16 ]]; then return 1; fi
  if [[ "$len" -lt 16 ]]; then return 0; fi
  i=0
  while [[ "$i" -lt 16 ]]; do
    c1=${n:$i:1}
    c2=${max:$i:1}
    if [[ "$c1" -gt "$c2" ]]; then return 1; fi
    if [[ "$c1" -lt "$c2" ]]; then return 0; fi
    i=$((i + 1))
  done
  return 0
}

gibson_metrics_add_into() {
  local cur amt sum
  eval "cur=\$$1"
  amt="$2"
  if ! gibson_metrics_is_uinteger "$cur" || ! gibson_metrics_is_uinteger "$amt"; then
    gibson_metrics_fail "non-integer add ($1)"
    return 1
  fi
  sum=$((cur + amt))
  if [[ "$sum" -lt "$cur" ]] || ! gibson_metrics_is_uinteger "$sum"; then
    gibson_metrics_fail "overflow adding to $1"
    return 1
  fi
  eval "$1=\$sum"
}

# Parse one KV body: total=N skipped=M todo=K (all three required; no extras).
# Sets _gmt _gms _gmd. Returns 0 on success.
gibson_metrics_parse_kv() {
  local body="$1" tok val seen_t=0 seen_s=0 seen_d=0
  local oldifs globoff=0
  _gmt=""; _gms=""; _gmd=""
  case "$-" in *f*) globoff=1 ;; esac
  set -f
  oldifs=$IFS
  IFS=' '
  # shellcheck disable=SC2086
  set -- $body
  IFS=$oldifs
  if [[ "$globoff" -eq 0 ]]; then set +f; fi
  if [[ "$#" -eq 0 ]]; then return 1; fi
  for tok in "$@"; do
    case "$tok" in
      total=*)
        [[ "$seen_t" -eq 0 ]] || return 1
        val=${tok#total=}
        gibson_metrics_is_uinteger "$val" || return 1
        _gmt=$val; seen_t=1
        ;;
      skipped=*)
        [[ "$seen_s" -eq 0 ]] || return 1
        val=${tok#skipped=}
        gibson_metrics_is_uinteger "$val" || return 1
        _gms=$val; seen_s=1
        ;;
      todo=*)
        [[ "$seen_d" -eq 0 ]] || return 1
        val=${tok#todo=}
        gibson_metrics_is_uinteger "$val" || return 1
        _gmd=$val; seen_d=1
        ;;
      *) return 1 ;;
    esac
  done
  [[ "$seen_t" -eq 1 && "$seen_s" -eq 1 && "$seen_d" -eq 1 ]] || return 1
  return 0
}

# Strict JSON object: exactly one raw total/skipped/todo key each (duplicate
# keys fail closed regardless of value), each a non-negative safe integer, no
# extra keys, no trailing text. Reject backslash/escaped key spelling before
# parse: this schema is fixed ASCII keys and numeric values, and JSON.parse
# collapses unicode-escaped keys while the raw exact-key count does not.
# Payload is env data (inert); Node is already required for this repo's
# sensors. Bash-3.2 stays the classifier.
gibson_metrics_parse_json() {
  local json="$1" parsed
  _gmt=""; _gms=""; _gmd=""
  command -v node >/dev/null 2>&1 || return 1
  parsed=$(GIBSON_METRICS_JSON="$json" node -e '
const s = process.env.GIBSON_METRICS_JSON || "";
if (s.includes("\\")) process.exit(1);
let o;
try { o = JSON.parse(s); } catch (e) { process.exit(1); }
if (!o || typeof o !== "object" || Array.isArray(o)) process.exit(1);
const keys = Object.keys(o);
if (keys.length !== 3) process.exit(1);
if (!Object.prototype.hasOwnProperty.call(o, "total") ||
    !Object.prototype.hasOwnProperty.call(o, "skipped") ||
    !Object.prototype.hasOwnProperty.call(o, "todo")) process.exit(1);
function fieldOk(key) {
  const n = o[key];
  if (typeof n !== "number" || !Number.isInteger(n) || n < 0 || n > 9007199254740991) {
    return false;
  }
  const occ = s.match(new RegExp("\"" + key + "\"\\s*:", "g"));
  if (!occ || occ.length !== 1) return false;
  const m = s.match(new RegExp("\"" + key + "\"\\s*:\\s*(-?\\d+)"));
  if (!m) return false;
  return m[1] === String(n);
}
if (!fieldOk("total") || !fieldOk("skipped") || !fieldOk("todo")) process.exit(1);
process.stdout.write(String(o.total) + " " + String(o.skipped) + " " + String(o.todo));
' 2>/dev/null) || return 1
  [[ -n "$parsed" ]] || return 1
  _gmt=${parsed%% *}
  parsed=${parsed#* }
  _gms=${parsed%% *}
  _gmd=${parsed#* }
  gibson_metrics_is_uinteger "$_gmt" || return 1
  gibson_metrics_is_uinteger "$_gms" || return 1
  gibson_metrics_is_uinteger "$_gmd" || return 1
  return 0
}

# Skip+todo must not exceed total.
gibson_metrics_bounds_ok() {
  local t="$1" s="$2" d="$3" sk
  sk=$((s + d))
  if [[ "$sk" -lt "$s" ]]; then return 1; fi
  if [[ "$sk" -gt "$t" ]]; then return 1; fi
  return 0
}

# Extract N from "<N> <word>" on a tally suffix. Empty → default.
# Duplicate, fractional, or signed forms fail (print nothing, return 1).
# Callers pass the exact terminal tally suffix, not a prefixed line.
gibson_metrics_tally_count() {
  local line="$1" word="$2" default="$3" raw n num
  if printf '%s\n' "$line" | grep -E -- "-[0-9]+[[:space:]]+${word}" >/dev/null; then
    return 1
  fi
  if printf '%s\n' "$line" | grep -E -- "[+][0-9]+[[:space:]]+${word}" >/dev/null; then
    return 1
  fi
  n=$(printf '%s\n' "$line" | grep -oE "[0-9]+(\.[0-9]+)?[[:space:]]+${word}" | grep -c . || true)
  if [[ "$n" -eq 0 ]]; then
    printf '%s' "$default"
    return 0
  fi
  if [[ "$n" -gt 1 ]]; then return 1; fi
  raw=$(printf '%s\n' "$line" | grep -oE "[0-9]+(\.[0-9]+)?[[:space:]]+${word}" | tail -1)
  num=${raw%%[[:space:]]*}
  num=${num%% *}
  gibson_metrics_is_uinteger "$num" || return 1
  printf '%s' "$num"
}

gibson_metrics_last_nonempty() {
  printf '%s\n' "$1" | awk 'NF { last=$0 } END { printf "%s", last }'
}

# Exact terminal tally suffix: "<n> passed, <n> failed" with optional skipped/
# todo and optional goose-validate clause. Trailing garbage is not this shape.
gibson_metrics_tally_suffix_re='[0-9]+[[:space:]]+passed,[[:space:]]+[0-9]+[[:space:]]+failed(,[[:space:]]+[0-9]+[[:space:]]+skipped)?(,[[:space:]]+[0-9]+[[:space:]]+todo)?(, goose-validate: [^[:space:]]+)?'

gibson_metrics_tally_suffix() {
  printf '%s\n' "$1" | grep -oE "${gibson_metrics_tally_suffix_re}[[:space:]]*$" || true
}

gibson_metrics_is_exact_tally() {
  printf '%s\n' "$1" | grep -E >/dev/null \
    "(^|[^0-9+-])${gibson_metrics_tally_suffix_re}[[:space:]]*$"
}

# Classify one suite receipt from the exact last non-empty line.
# Prints: kind total skipped todo
# kind is machine|tally|sentinel. Return 1 on contract failure (prints error ...).
# Duplicate, non-terminal, or bare GIBSON_TEST_METRICS markers fail closed. A
# tally is eligible only when that last line ends with the exact supported
# suffix; counts come only from that suffix. Reserved passed/failed/skipped/todo
# counters in a prefix, and explicit +N counts, fail closed. Otherwise a
# visible legacy sentinel, unless malformed metric evidence requires RED.
gibson_metrics_marker_re='^[[:space:]]*GIBSON_TEST_METRICS([[:space:]]|$)'
gibson_metrics_classify() {
  local receipt="$1" machine_n last body passed failed skipped todo total suffix prefix
  _gmt=0; _gms=0; _gmd=0
  last=$(gibson_metrics_last_nonempty "$receipt")
  machine_n=$(printf '%s\n' "$receipt" | grep -cE "$gibson_metrics_marker_re" || true)
  if [[ "$machine_n" -gt 1 ]]; then
    echo "error duplicate-machine-metric"
    return 1
  fi
  if [[ "$machine_n" -eq 1 ]]; then
    if ! printf '%s\n' "$last" | grep -E "$gibson_metrics_marker_re" >/dev/null; then
      echo "error non-terminal-machine-metric"
      return 1
    fi
    body=${last#*GIBSON_TEST_METRICS}
    body=${body#${body%%[![:space:]]*}}
    if [[ "$body" == \{* ]]; then
      gibson_metrics_parse_json "$body" || { echo "error malformed-machine-json"; return 1; }
    else
      gibson_metrics_parse_kv "$body" || { echo "error malformed-machine-kv"; return 1; }
    fi
    gibson_metrics_bounds_ok "$_gmt" "$_gms" "$_gmd" || { echo "error skip-todo-exceeds-total"; return 1; }
    echo "machine ${_gmt} ${_gms} ${_gmd}"
    return 0
  fi
  if printf '%s\n' "$last" | grep -E -- '-[0-9]+[[:space:]]+(passed|failed|skipped|todo)' >/dev/null; then
    echo "error negative-tally"
    return 1
  fi
  if printf '%s\n' "$last" | grep -E '[+][0-9]+[[:space:]]+(passed|failed|skipped|todo)' >/dev/null; then
    echo "error signed-tally"
    return 1
  fi
  if printf '%s\n' "$last" | grep -E '[0-9]+\.[0-9]+[[:space:]]+(passed|failed|skipped|todo)' >/dev/null; then
    echo "error fractional-tally"
    return 1
  fi
  if ! gibson_metrics_is_exact_tally "$last"; then
    echo "sentinel 1 0 0"
    return 0
  fi
  suffix=$(gibson_metrics_tally_suffix "$last")
  if [[ -z "$suffix" ]]; then
    echo "error missing-tally-suffix"
    return 1
  fi
  prefix=${last%"$suffix"}
  if [[ -n "$prefix" ]] && printf '%s\n' "$prefix" | grep -E '[0-9]+[[:space:]]+(passed|failed|skipped|todo)' >/dev/null; then
    echo "error prefix-tally-counter"
    return 1
  fi
  passed=$(gibson_metrics_tally_count "$suffix" passed "") || { echo "error duplicate-or-bad-passed"; return 1; }
  failed=$(gibson_metrics_tally_count "$suffix" failed "") || { echo "error duplicate-or-bad-failed"; return 1; }
  if [[ -z "$passed" || -z "$failed" ]]; then
    echo "error missing-passed-or-failed"
    return 1
  fi
  skipped=$(gibson_metrics_tally_count "$suffix" skipped 0) || { echo "error duplicate-or-bad-skipped"; return 1; }
  todo=$(gibson_metrics_tally_count "$suffix" todo 0) || { echo "error duplicate-or-bad-todo"; return 1; }
  total=$((passed + failed + skipped + todo))
  if [[ "$total" -lt "$passed" ]] || ! gibson_metrics_is_uinteger "$total"; then
    echo "error overflow-tally"
    return 1
  fi
  echo "tally ${total} ${skipped} ${todo}"
  return 0
}

# True when $1 appears as a whole word in space-separated $2.
gibson_metrics_name_in_list() {
  local name="$1" list="$2"
  [[ -n "$name" ]] || return 1
  case " $list " in
    *" $name "*) return 0 ;;
    *) return 1 ;;
  esac
}

gibson_metrics_contribute() {
  local receipt="$1" name="$2" classified kind total skipped todo
  classified=$(gibson_metrics_classify "$receipt") || {
    gibson_metrics_fail "suite $name: ${classified:-classify-failed}"
    return 1
  }
  kind=${classified%% *}
  total=$(printf '%s\n' "$classified" | awk '{print $2}')
  skipped=$(printf '%s\n' "$classified" | awk '{print $3}')
  todo=$(printf '%s\n' "$classified" | awk '{print $4}')
  case "$kind" in
    machine|tally)
      if gibson_metrics_name_in_list "$name" "$METRIC_SENTINEL_NAMES"; then
        gibson_metrics_fail "suite $name: explicit assertions and sentinel"
        return 1
      fi
      gibson_metrics_add_into METRIC_TOTAL "$total" || return 1
      gibson_metrics_add_into METRIC_SKIPPED "$skipped" || return 1
      gibson_metrics_add_into METRIC_TODO "$todo" || return 1
      gibson_metrics_add_into METRIC_EXPLICIT "$total" || return 1
      if ! gibson_metrics_name_in_list "$name" "$METRIC_EXPLICIT_NAMES"; then
        METRIC_EXPLICIT_NAMES="${METRIC_EXPLICIT_NAMES}${METRIC_EXPLICIT_NAMES:+ }$name"
      fi
      ;;
    sentinel)
      if gibson_metrics_name_in_list "$name" "$METRIC_EXPLICIT_NAMES"; then
        gibson_metrics_fail "suite $name: explicit assertions and sentinel"
        return 1
      fi
      if gibson_metrics_name_in_list "$name" "$METRIC_SENTINEL_NAMES"; then
        gibson_metrics_fail "suite $name: duplicate sentinel attribution"
        return 1
      fi
      gibson_metrics_add_into METRIC_TOTAL 1 || return 1
      gibson_metrics_add_into METRIC_SENTINEL 1 || return 1
      METRIC_SENTINEL_NAMES="${METRIC_SENTINEL_NAMES}${METRIC_SENTINEL_NAMES:+ }$name"
      ;;
    *)
      gibson_metrics_fail "suite $name: unknown kind $kind"
      return 1
      ;;
  esac
}

# Named legacy-sentinel list must match the numeric subtotal, contain no
# duplicate names, and share no suite with explicit assertion attribution.
gibson_metrics_reconcile_legacy_sentinels() {
  local named=0 seen="" tok globoff=0 dup="" dual=""
  case "$-" in *f*) globoff=1 ;; esac
  set -f
  # shellcheck disable=SC2086
  for tok in $METRIC_SENTINEL_NAMES; do
    case " $seen " in
      *" $tok "*) dup=$tok; break ;;
    esac
    seen="${seen}${seen:+ }$tok"
    named=$((named + 1))
    case " $METRIC_EXPLICIT_NAMES " in
      *" $tok "*) dual=$tok; break ;;
    esac
  done
  if [[ "$globoff" -eq 0 ]]; then set +f; fi
  if [[ -n "$dup" ]]; then
    gibson_metrics_fail "duplicate sentinel attribution: $dup"
    return 1
  fi
  if [[ -n "$dual" ]]; then
    gibson_metrics_fail "suite $dual: explicit assertions and sentinel"
    return 1
  fi
  if [[ "$named" -ne "$METRIC_SENTINEL" ]]; then
    gibson_metrics_fail "legacy-sentinel name/count drift (named=${named} count=${METRIC_SENTINEL})"
    return 1
  fi
  return 0
}

gibson_metrics_assert_class() {
  local receipt="$1" want="$2" desc="$3" got
  got=$(gibson_metrics_classify "$receipt") || got="error classify-rc"
  if [[ "$got" == "$want" ]]; then
    echo "${GRN}  ok${OFF}   — metrics mutation: $desc"
    return 0
  fi
  echo "${RED}  FAIL${OFF} — metrics mutation: $desc (got '$got' want '$want')"
  FAILED="$FAILED metrics-contract-mutation"
  return 1
}

gibson_metrics_assert_error() {
  local receipt="$1" desc="$2" got rc=0
  got=$(gibson_metrics_classify "$receipt") || rc=$?
  if [[ "$rc" -ne 0 && "$got" == error* ]]; then
    echo "${GRN}  ok${OFF}   — metrics mutation: $desc"
    return 0
  fi
  echo "${RED}  FAIL${OFF} — metrics mutation: $desc (got '$got' rc=$rc)"
  FAILED="$FAILED metrics-contract-mutation"
  return 1
}

# Fold metric-contract failure into FAILED, then count n_fail and print the
# one GREEN/RED verdict. Diagnosis is printed first so a contract failure
# cannot display GREEN. Sets verdict_rc. Does not emit GIBSON_TEST_METRICS.
gibson_run_all_bind_and_print_verdict() {
  local n_fail n_quar n_esc
  gibson_metrics_reconcile_legacy_sentinels || true
  if [[ "$METRIC_CONTRACT_FAIL" -ne 0 ]]; then
    echo "run-all: metric contract RED — $METRIC_CONTRACT_REASON" >&2
    FAILED="$FAILED metric-contract"
  fi
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

  verdict_rc=1
  if [[ "$n_fail" -eq 0 && "$n_esc" -eq 0 ]]; then
    echo "run-all: GREEN — 0 failed, $n_quar quarantined"
    verdict_rc=0
  else
    echo "run-all: RED — $n_fail failed, $n_esc escaped quarantine, $n_quar quarantined"
    verdict_rc=1
  fi
}

# Emit the aggregate machine line only when the metric contract held.
# Returns verdict_rc, or 1 when the contract failed (no machine line).
gibson_metrics_emit_aggregate_or_fail() {
  if [[ "$METRIC_CONTRACT_FAIL" -ne 0 ]]; then
    return 1
  fi
  echo "run-all legacy-sentinels:${METRIC_SENTINEL_NAMES:+ }${METRIC_SENTINEL_NAMES}"
  echo "run-all metric-subtotals: explicit-assertions=${METRIC_EXPLICIT} legacy-sentinels=${METRIC_SENTINEL}"
  echo "GIBSON_TEST_METRICS total=${METRIC_TOTAL} skipped=${METRIC_SKIPPED} todo=${METRIC_TODO}"
  return "$verdict_rc"
}

# Synthetic verdict probe: subshell with caller-supplied FAILED/ESCAPED and
# metric-contract flag. No production env injection hook; no recursive run-all.
# Stderr is merged so the diagnosis is observable. Exit status is the finish rc.
gibson_metrics_verdict_probe() {
  (
    FAILED="$1"
    ESCAPED="$2"
    QUARANTINED=""
    METRIC_CONTRACT_FAIL="$3"
    METRIC_CONTRACT_REASON="$4"
    METRIC_TOTAL=3
    METRIC_SKIPPED=0
    METRIC_TODO=0
    METRIC_EXPLICIT=3
    METRIC_SENTINEL=0
    METRIC_SENTINEL_NAMES=""
    METRIC_EXPLICIT_NAMES=""
    verdict_rc=1
    gibson_run_all_bind_and_print_verdict
    gibson_metrics_emit_aggregate_or_fail
    exit $?
  ) 2>&1
}

gibson_metrics_run_contract_mutations() {
  # Synthetic receipts only — never a static production count and never a
  # parse of .agents/gate.json. Shared by fixture and ordinary paths.
  gibson_metrics_assert_class \
    $'ok\nGIBSON_TEST_METRICS total=10 skipped=1 todo=2\n' \
    "machine 10 1 2" \
    "terminal machine KV is used"
  gibson_metrics_assert_class \
    $'ok\nGIBSON_TEST_METRICS {"total":9,"skipped":0,"todo":1}\n' \
    "machine 9 0 1" \
    "terminal machine JSON is used"
  gibson_metrics_assert_class \
    $'probe: 2 passed, 0 failed\nsuite: 4 passed, 1 failed, 3 skipped, 1 todo\n' \
    "tally 9 3 1" \
    "terminal passed/failed tally plus skip/todo"
  gibson_metrics_assert_class \
    $'no numbers here\n' \
    "sentinel 1 0 0" \
    "legacy no-tally sentinel"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS total=10 skipped=0 todo=0\nGIBSON_TEST_METRICS total=7 skipped=0 todo=0\n' \
    "duplicate machine metric fails closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS total=-1 skipped=0 todo=0\n' \
    "negative machine metric fails closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS total=1.5 skipped=0 todo=0\n' \
    "fractional machine metric fails closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS total=9007199254740993 skipped=0 todo=0\n' \
    "overflow machine metric fails closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS total=nope skipped=0 todo=0\n' \
    "malformed machine metric fails closed"
  gibson_metrics_assert_error \
    $'suite: 4.5 passed, 0 failed\n' \
    "fractional tally fails closed"
  gibson_metrics_assert_error \
    $'ok\nGIBSON_TEST_METRICS total=10 skipped=1 todo=2\nmore output after machine\n' \
    "non-terminal machine evidence fails closed"
  gibson_metrics_assert_class \
    $'suite: 4 passed, 1 failed, 3 skipped, 1 todo\nmore output after tally\n' \
    "sentinel 1 0 0" \
    "non-terminal tally falls back to the visible legacy sentinel"
  gibson_metrics_assert_class \
    $'goose-recipes.test.sh: 218 passed, 0 failed, goose-validate: NOT\ngoose recipe validate status: NOT RUN\n' \
    "sentinel 1 0 0" \
    "tally then trailing status remains a sentinel"
  gibson_metrics_assert_class \
    $'goose recipe validate status: NOT RUN\ngoose-recipes.test.sh: 218 passed, 0 failed, goose-validate: NOT\n' \
    "tally 218 0 0" \
    "status then terminal tally contributes explicit assertions"
  gibson_metrics_assert_error \
    $'suite: -1 passed, 0 failed\n' \
    "negative tally fails closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS total=10 skipped=0 todo=0 trailing\n' \
    "trailing garbage on a machine receipt fails closed"
  gibson_metrics_assert_class \
    $'suite: 4 passed, 0 failed trailing garbage\n' \
    "sentinel 1 0 0" \
    "tally trailing garbage is not the exact supported shape (legacy sentinel)"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS {"total":1,"skipped":0,"todo":0,}\n' \
    "malformed machine JSON fails closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS {"total":1,"skipped":0,"todo":0}{"x":1}\n' \
    "trailing JSON after a machine object fails closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS {"total":1,"skipped":0,"todo":0,"extra":1}\n' \
    "extra JSON key on a machine receipt fails closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS {"total":1,"total":1,"skipped":0,"todo":0}\n' \
    "same-value duplicate JSON keys fail closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS {"total":1,"total":2,"skipped":0,"todo":0}\n' \
    "differing-value duplicate JSON keys fail closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS {"total":1,"to\\u0074al":1,"skipped":0,"todo":0}\n' \
    "escaped JSON key semantic duplicate fails closed"
  gibson_metrics_assert_error \
    $'ok\nGIBSON_TEST_METRICS\n' \
    "bare machine marker fails closed"
  gibson_metrics_assert_error \
    $'GIBSON_TEST_METRICS\nGIBSON_TEST_METRICS total=1 skipped=0 todo=0\n' \
    "bare nonterminal plus terminal machine marker fails closed"
  gibson_metrics_assert_error \
    $'99 skipped; suite: 4 passed, 0 failed\n' \
    "prefix reserved counters fail closed"
  gibson_metrics_assert_error \
    $'+1 passed, 0 failed\n' \
    "explicit plus sign on a tally count fails closed"

  # Verdict-binding mutations: synthetic globals only — no env injection hook
  # and no recursive run-all.
  _vrc=0
  _vout=$(gibson_metrics_verdict_probe "" "" 1 "synthetic-verdict-bind") || _vrc=$?
  if [[ "$_vrc" -ne 0 ]] \
     && printf '%s\n' "$_vout" | grep -F 'run-all: metric contract RED — synthetic-verdict-bind' >/dev/null \
     && printf '%s\n' "$_vout" | grep -E '^run-all: RED' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -F 'run-all: GREEN' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -E '^GIBSON_TEST_METRICS' >/dev/null; then
    echo "${GRN}  ok${OFF}   — metrics mutation: metric-contract failure is RED without GREEN or aggregate metrics"
  else
    echo "${RED}  FAIL${OFF} — metrics mutation: metric-contract verdict bind (rc=${_vrc} out=$(printf '%s' "$_vout" | tr '\n' '|'))"
    FAILED="$FAILED metrics-verdict-mutation"
  fi

  _vrc=0
  _vout=$(gibson_metrics_verdict_probe "" "" 0 "") || _vrc=$?
  if [[ "$_vrc" -eq 0 ]] \
     && printf '%s\n' "$_vout" | grep -F 'run-all: GREEN' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -E '^run-all: RED' >/dev/null \
     && printf '%s\n' "$_vout" | grep -E '^GIBSON_TEST_METRICS total=' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -F 'run-all: metric contract RED' >/dev/null; then
    echo "${GRN}  ok${OFF}   — metrics mutation: green run still prints GREEN and aggregate metrics"
  else
    echo "${RED}  FAIL${OFF} — metrics mutation: green verdict bind (rc=${_vrc} out=$(printf '%s' "$_vout" | tr '\n' '|'))"
    FAILED="$FAILED metrics-verdict-mutation"
  fi

  _vrc=0
  _vout=$(gibson_metrics_verdict_probe "foo.test.sh" "" 0 "") || _vrc=$?
  if [[ "$_vrc" -ne 0 ]] \
     && printf '%s\n' "$_vout" | grep -E '^run-all: RED' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -F 'run-all: GREEN' >/dev/null \
     && printf '%s\n' "$_vout" | grep -E '^GIBSON_TEST_METRICS total=' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -F 'run-all: metric contract RED' >/dev/null; then
    echo "${GRN}  ok${OFF}   — metrics mutation: ordinary suite failure is RED with aggregate metrics"
  else
    echo "${RED}  FAIL${OFF} — metrics mutation: suite-failure verdict bind (rc=${_vrc} out=$(printf '%s' "$_vout" | tr '\n' '|'))"
    FAILED="$FAILED metrics-verdict-mutation"
  fi

  # #278 sentinel attribution / reconciliation mutations. Synthetic contributes
  # in a subshell — never a recursive run-all and never a static production count.
  _vrc=0
  _vout=$(
    exec 2>&1
    FAILED=""
    ESCAPED=""
    QUARANTINED=""
    METRIC_CONTRACT_FAIL=0
    METRIC_CONTRACT_REASON=""
    METRIC_TOTAL=0
    METRIC_SKIPPED=0
    METRIC_TODO=0
    METRIC_EXPLICIT=0
    METRIC_SENTINEL=0
    METRIC_SENTINEL_NAMES=""
    METRIC_EXPLICIT_NAMES=""
    verdict_rc=1
    gibson_metrics_contribute $'no tally\n' "dup.test.sh" || true
    gibson_metrics_contribute $'no tally\n' "dup.test.sh" || true
    gibson_run_all_bind_and_print_verdict
    gibson_metrics_emit_aggregate_or_fail
    exit $?
  ) || _vrc=$?
  if [[ "$_vrc" -ne 0 ]] \
     && printf '%s\n' "$_vout" | grep -F 'run-all: metric contract RED — suite dup.test.sh: duplicate sentinel attribution' >/dev/null \
     && printf '%s\n' "$_vout" | grep -E '^run-all: RED' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -F 'run-all: GREEN' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -E '^GIBSON_TEST_METRICS' >/dev/null; then
    echo "${GRN}  ok${OFF}   — metrics mutation: duplicate sentinel attribution refuses"
  else
    echo "${RED}  FAIL${OFF} — metrics mutation: duplicate sentinel attribution (rc=${_vrc} out=$(printf '%s' "$_vout" | tr '\n' '|'))"
    FAILED="$FAILED metrics-sentinel-attribution-mutation"
  fi

  _vrc=0
  _vout=$(
    exec 2>&1
    FAILED=""
    ESCAPED=""
    QUARANTINED=""
    METRIC_CONTRACT_FAIL=0
    METRIC_CONTRACT_REASON=""
    METRIC_TOTAL=0
    METRIC_SKIPPED=0
    METRIC_TODO=0
    METRIC_EXPLICIT=0
    METRIC_SENTINEL=0
    METRIC_SENTINEL_NAMES=""
    METRIC_EXPLICIT_NAMES=""
    verdict_rc=1
    gibson_metrics_contribute $'no tally\n' "drift.test.sh" || true
    METRIC_SENTINEL=2
    gibson_run_all_bind_and_print_verdict
    gibson_metrics_emit_aggregate_or_fail
    exit $?
  ) || _vrc=$?
  if [[ "$_vrc" -ne 0 ]] \
     && printf '%s\n' "$_vout" | grep -F 'run-all: metric contract RED — legacy-sentinel name/count drift (named=1 count=2)' >/dev/null \
     && printf '%s\n' "$_vout" | grep -E '^run-all: RED' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -F 'run-all: GREEN' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -E '^GIBSON_TEST_METRICS' >/dev/null; then
    echo "${GRN}  ok${OFF}   — metrics mutation: name/count drift refuses"
  else
    echo "${RED}  FAIL${OFF} — metrics mutation: name/count drift (rc=${_vrc} out=$(printf '%s' "$_vout" | tr '\n' '|'))"
    FAILED="$FAILED metrics-sentinel-attribution-mutation"
  fi

  _vrc=0
  _vout=$(
    exec 2>&1
    FAILED=""
    ESCAPED=""
    QUARANTINED=""
    METRIC_CONTRACT_FAIL=0
    METRIC_CONTRACT_REASON=""
    METRIC_TOTAL=0
    METRIC_SKIPPED=0
    METRIC_TODO=0
    METRIC_EXPLICIT=0
    METRIC_SENTINEL=0
    METRIC_SENTINEL_NAMES=""
    METRIC_EXPLICIT_NAMES=""
    verdict_rc=1
    gibson_metrics_contribute $'suite: 4 passed, 0 failed\n' "both.test.sh" || true
    gibson_metrics_contribute $'no tally\n' "both.test.sh" || true
    gibson_run_all_bind_and_print_verdict
    gibson_metrics_emit_aggregate_or_fail
    exit $?
  ) || _vrc=$?
  if [[ "$_vrc" -ne 0 ]] \
     && printf '%s\n' "$_vout" | grep -F 'run-all: metric contract RED — suite both.test.sh: explicit assertions and sentinel' >/dev/null \
     && printf '%s\n' "$_vout" | grep -E '^run-all: RED' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -F 'run-all: GREEN' >/dev/null \
     && ! printf '%s\n' "$_vout" | grep -E '^GIBSON_TEST_METRICS' >/dev/null; then
    echo "${GRN}  ok${OFF}   — metrics mutation: one suite cannot contribute both explicit assertions and a sentinel"
  else
    echo "${RED}  FAIL${OFF} — metrics mutation: dual explicit/sentinel attribution (rc=${_vrc} out=$(printf '%s' "$_vout" | tr '\n' '|'))"
    FAILED="$FAILED metrics-sentinel-attribution-mutation"
  fi

  _vrc=0
  _vout=$(
    exec 2>&1
    FAILED=""
    ESCAPED=""
    QUARANTINED=""
    METRIC_CONTRACT_FAIL=0
    METRIC_CONTRACT_REASON=""
    METRIC_TOTAL=0
    METRIC_SKIPPED=0
    METRIC_TODO=0
    METRIC_EXPLICIT=0
    METRIC_SENTINEL=0
    METRIC_SENTINEL_NAMES=""
    METRIC_EXPLICIT_NAMES=""
    verdict_rc=1
    gibson_metrics_contribute $'no tally\n' "zeta.test.sh" || true
    gibson_metrics_contribute $'no tally\n' "alpha.test.sh" || true
    gibson_run_all_bind_and_print_verdict
    gibson_metrics_emit_aggregate_or_fail
    exit $?
  ) || _vrc=$?
  if [[ "$_vrc" -eq 0 ]] \
     && printf '%s\n' "$_vout" | grep -F 'run-all: GREEN' >/dev/null \
     && printf '%s\n' "$_vout" | grep -E '^run-all legacy-sentinels: zeta.test.sh alpha.test.sh$' >/dev/null \
     && printf '%s\n' "$_vout" | grep -E '^run-all metric-subtotals: explicit-assertions=0 legacy-sentinels=2$' >/dev/null \
     && printf '%s\n' "$_vout" | grep -E '^GIBSON_TEST_METRICS total=2 skipped=0 todo=0$' >/dev/null; then
    echo "${GRN}  ok${OFF}   — metrics mutation: named legacy-sentinel diagnostic matches the numeric subtotal"
  else
    echo "${RED}  FAIL${OFF} — metrics mutation: named sentinel diagnostic (rc=${_vrc} out=$(printf '%s' "$_vout" | tr '\n' '|'))"
    FAILED="$FAILED metrics-sentinel-attribution-mutation"
  fi
  unset _vout _vrc
}

# Internal contract-test seam (#279). Private literals only; no env/file/stdin
# extra-argument injection. Derives the aggregate through the same production
# classifier, contributor, reconciler, verdict binder, and aggregate emitter
# as the ordinary path. Not a complete gate or release substitute.
gibson_run_metrics_contract_fixture() {
  local t0
  t0=$SECONDS
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
  [[ -t 1 ]] || { RED=""; GRN=""; YEL=""; OFF=""; }
  FAILED=""
  QUARANTINED=""
  ESCAPED=""
  verdict_rc=1
  gibson_metrics_init
  echo "run-all: --metrics-contract-fixture (internal contract-test seam; not a complete gate)"
  gibson_metrics_run_contract_mutations
  # Mutations run in subshells or only set FAILED. Re-init accumulators so the
  # successful derive is a clean production contribute/bind/emit; FAILED is
  # not an accumulator and is preserved.
  gibson_metrics_init

  # Private fixture receipts owned by this function. The terminal machine
  # line is the classifier input; the preceding 10/1/2 human tally conflicts
  # with it (human would be 13/2/0) and must not be used.
  gibson_metrics_contribute \
    $'10 passed, 1 failed, 2 skipped\nGIBSON_TEST_METRICS total=10 skipped=1 todo=2\n' \
    "metrics-contract-fixture.machine.test.sh" || true
  gibson_metrics_contribute \
    $'4 passed, 1 failed, 3 skipped, 1 todo\n' \
    "metrics-contract-fixture.tally.test.sh" || true
  gibson_metrics_contribute \
    $'legacy fixture has no tally line\n' \
    "metrics-contract-fixture.legacy.test.sh" || true

  echo
  gibson_run_all_bind_and_print_verdict
  echo "run-all metrics-contract-fixture wall: $((SECONDS - t0))s"
  gibson_metrics_emit_aggregate_or_fail
  return $?
}

# GIBSON_METRICS_CONTRACT_FIXTURE_DISPATCH
# Execute only after production functions are defined and after the ordinary
# preamble has been skipped. Must exit before sensor suites.
if [[ "$METRICS_CONTRACT_FIXTURE" -eq 1 ]]; then
  gibson_run_metrics_contract_fixture
  exit $?
fi

gibson_metrics_init

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

# Metric-contract mutation coverage (#274): synthetic receipts only — never a
# static production count and never a parse of .agents/gate.json.
gibson_metrics_run_contract_mutations

# gibson_forward_bash32_bench begin
# Forward one captured GIBSON_BASH32_BENCH line onto ordinary run-all stdout.
# Usage: gibson_forward_bash32_bench <suite_ec> <expected_paths_sha256> <docker_usable>
# Captured suite stdout/stderr is read from stdin. Bash 3.2 + set -u safe.
# Stdout: the one validated receipt, or empty. Never assertion chatter.
# Exit 0: forwarded, or not required (docker unused at the production preamble).
# Exit 1: fail closed; no green receipt.
#
# Safe arithmetic digit bound: 18 decimal digits. 10^18-1 fits in signed
# 64-bit, so $((candidate - baseline)) and the later -le 5000 test cannot
# overflow once this bound holds. Baseline and candidate must be canonical
# non-negative decimals (0, or [1-9][0-9]* with no leading zeros) of at
# most 18 digits. Reported delta must be a canonical signed decimal of at
# most 18 magnitude digits (optional leading '-', never -0, never leading
# zeros). Recompute exact candidate-baseline only after those bounds hold.
# Emit the sole receipt only when the reported delta string equals that
# recomputed value exactly and the recomputed value is <= 5000. Overflow,
# inconsistent delta, alternate encodings, or arithmetic errors emit no
# receipt and return 1.
gibson_forward_bash32_bench() {
  local _fwd_ec _fwd_digest _fwd_usable _fwd_n _fwd_match _fwd_line
  local _fwd_parsed _fwd_baseline _fwd_candidate _fwd_delta _fwd_hash
  local _fwd_recomputed _fwd_mag _fwd_max_digits
  _fwd_ec=${1-}
  _fwd_digest=${2-}
  _fwd_usable=${3-}
  _fwd_max_digits=18

  if [ "$_fwd_usable" = "0" ]; then
    while IFS= read -r _fwd_line || [ -n "${_fwd_line:-}" ]; do
      :
    done
    return 0
  fi
  if [ "$_fwd_usable" != "1" ]; then
    while IFS= read -r _fwd_line || [ -n "${_fwd_line:-}" ]; do
      :
    done
    return 1
  fi

  case "$_fwd_ec" in
    0) ;;
    *)
      while IFS= read -r _fwd_line || [ -n "${_fwd_line:-}" ]; do
        :
      done
      return 1
      ;;
  esac

  _fwd_n=0
  _fwd_match=""
  while IFS= read -r _fwd_line || [ -n "${_fwd_line:-}" ]; do
    case "$_fwd_line" in
      GIBSON_BASH32_BENCH*)
        _fwd_n=$((_fwd_n + 1))
        _fwd_match=$_fwd_line
        ;;
    esac
  done

  if [ "$_fwd_n" -ne 1 ]; then
    return 1
  fi

  _fwd_parsed=$(printf '%s\n' "$_fwd_match" | awk '
    NF != 8 { exit 1 }
    $1 != "GIBSON_BASH32_BENCH" { exit 1 }
    $2 != "schema=gibson.bash32-bench/v1" { exit 1 }
    $3 != "samples=3" { exit 1 }
    $8 != "status=pass" { exit 1 }
    {
      n = split($4, b, "=")
      if (n != 2 || b[1] != "baseline_median_ms") exit 1
      n = split($5, c, "=")
      if (n != 2 || c[1] != "candidate_median_ms") exit 1
      n = split($6, d, "=")
      if (n != 2 || d[1] != "delta_ms") exit 1
      n = split($7, h, "=")
      if (n != 2 || h[1] != "paths_sha256") exit 1
      print b[2], c[2], d[2], h[2]
      exit 0
    }
  ') || return 1

  _fwd_baseline=$(printf '%s\n' "$_fwd_parsed" | awk '{print $1}')
  _fwd_candidate=$(printf '%s\n' "$_fwd_parsed" | awk '{print $2}')
  _fwd_delta=$(printf '%s\n' "$_fwd_parsed" | awk '{print $3}')
  _fwd_hash=$(printf '%s\n' "$_fwd_parsed" | awk '{print $4}')

  case "$_fwd_baseline" in
    0) ;;
    ''|*[!0-9]*) return 1 ;;
    0*) return 1 ;;
  esac
  if [ "${#_fwd_baseline}" -gt "$_fwd_max_digits" ]; then
    return 1
  fi
  case "$_fwd_candidate" in
    0) ;;
    ''|*[!0-9]*) return 1 ;;
    0*) return 1 ;;
  esac
  if [ "${#_fwd_candidate}" -gt "$_fwd_max_digits" ]; then
    return 1
  fi
  _fwd_mag=$_fwd_delta
  case "$_fwd_delta" in
    0) ;;
    -*)
      _fwd_mag=${_fwd_delta#-}
      case "$_fwd_mag" in
        ''|*[!0-9]*|0*) return 1 ;;
      esac
      ;;
    ''|*[!0-9]*) return 1 ;;
    0*) return 1 ;;
  esac
  if [ "${#_fwd_mag}" -gt "$_fwd_max_digits" ]; then
    return 1
  fi
  if ! printf '%s' "$_fwd_hash" | grep -E '^[0-9a-f]{64}$' >/dev/null; then
    return 1
  fi
  if [ "$_fwd_hash" != "$_fwd_digest" ]; then
    return 1
  fi
  _fwd_recomputed=$((_fwd_candidate - _fwd_baseline)) || return 1
  if [ "$_fwd_delta" != "$_fwd_recomputed" ]; then
    return 1
  fi
  if ! [ "$_fwd_recomputed" -le 5000 ]; then
    return 1
  fi
  printf '%s\n' "$_fwd_match"
  return 0
}
# gibson_forward_bash32_bench end

# gibson_suite_read_capture begin
# Classify one finished suite capture. Timeout wins over "no tally line".
# $1 capture prefix (.out/.ec/.elapsed), $2 timeout seconds (0 = none).
# Sets: _gs_out _gs_ec _gs_elapsed _gs_tally
gibson_suite_read_capture() {
  local cap="$1" timeout="${2:-0}"
  _gs_out=""
  _gs_ec=1
  _gs_elapsed=0
  _gs_tally="no tally line"

  if [[ -f "$cap.out" ]]; then
    _gs_out=$(cat "$cap.out" 2>/dev/null || true)
  fi
  if [[ -s "$cap.elapsed" ]]; then
    _gs_elapsed=$(cat "$cap.elapsed" 2>/dev/null || echo 0)
  fi
  case "$_gs_elapsed" in
    ''|*[!0-9]*) _gs_elapsed=0 ;;
  esac

  if [[ -s "$cap.ec" ]]; then
    _gs_ec=$(cat "$cap.ec")
  else
    # Wrapper died before recording rc. A wall-budget kill must never
    # surface as "no tally line" (#319 AC4) — but only a run that actually
    # reached the budget is a timeout; a wrapper that died early (mkdir
    # ENOSPC, setup failure) is a runner failure and stays RED as such.
    if [[ "$timeout" -gt 0 && "$_gs_elapsed" -ge "$timeout" ]]; then
      _gs_ec=124
    else
      _gs_out="run-all: suite produced no exit-code capture after ${_gs_elapsed}s (runner/setup failure, not a timeout)"
      _gs_ec=1
    fi
  fi
  case "$_gs_ec" in
    ''|*[!0-9]*) _gs_ec=1 ;;
  esac

  if [[ "$timeout" -gt 0 ]]; then
    # rc 124 is a timeout only when the wall was actually reached (5s slack);
    # a suite that exits 124 early is an ordinary failure.
    if [[ "$_gs_ec" -eq 124 && "$_gs_elapsed" -ge $((timeout - 5)) ]]; then
      _gs_tally="timed out after ${timeout}s"
      return 0
    fi
    if [[ "$_gs_elapsed" -ge "$timeout" && "$_gs_ec" -ne 0 ]]; then
      case "$_gs_ec" in
        137|143|130)
          _gs_ec=124
          _gs_tally="timed out after ${timeout}s"
          return 0
          ;;
      esac
    fi
  fi

  if [[ -f "$cap.out" ]]; then
    _gs_tally=$(grep -oE '[0-9]+ passed, [0-9]+ failed(, goose-validate: [^[:space:]]+)?' "$cap.out" 2>/dev/null | tail -1)
  fi
  [[ -n "$_gs_tally" ]] || _gs_tally="no tally line"
  return 0
}
# gibson_suite_read_capture end

# Suites run as background processes (at most $JOBS at once), each capturing
# stdout+stderr, exit code, and elapsed seconds into a scratch directory.
# Reporting below consumes those captures in discovery order, so the printed
# transcript, FAILED binding, and metrics do not depend on scheduling.
SUITE_CAPTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gibson-runall-suites.XXXXXX") || {
  echo "run-all.sh: mktemp for suite captures failed" >&2
  exit 2
}

# On EXIT/INT/TERM/HUP stop any suites still running (whole process trees —
# a suite may have forked node/docker/git children) before removing captures,
# so a cancelled gate does not leave orphans burning the runner.
suite_pids=()
kill_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
  kill -TERM "$1" 2>/dev/null || true
}
run_all_cleanup() {
  local p
  for p in "${suite_pids[@]+"${suite_pids[@]}"}"; do
    kill -0 "$p" 2>/dev/null && kill_tree "$p"
  done
  for p in "${suite_pids[@]+"${suite_pids[@]}"}"; do
    wait "$p" 2>/dev/null || true
  done
  rm -rf "$SUITE_CAPTURE_DIR"
}
trap 'run_all_cleanup' EXIT
trap 'run_all_cleanup; trap - INT; kill -INT $$' INT
trap 'run_all_cleanup; trap - TERM; kill -TERM $$' TERM
trap 'run_all_cleanup; trap - HUP; kill -HUP $$' HUP

run_suite_captured() {
  # $1 suite path, $2 capture prefix
  local t0=$SECONDS ec=1 suite="$1" cap="$2" suite_tmp
  suite_tmp="${cap}.tmpdir"
  mkdir -p "$suite_tmp" || return 1
  _gs_write_cap() {
    printf '%s\n' "${ec:-1}" >"${cap}.ec"
    printf '%s\n' "$((SECONDS - t0))" >"${cap}.elapsed"
  }
  _gs_on_sig() {
    ec="${1:-1}"
    _gs_write_cap
    trap - EXIT
    exit "$ec"
  }
  trap '_gs_write_cap' EXIT
  trap '_gs_on_sig 130' INT
  trap '_gs_on_sig 143' TERM
  trap '_gs_on_sig 129' HUP
  unset FLEET_WALL_TIMEOUT_TEST_PUBLISH \
        FLEET_WALL_TIMEOUT_TEST_HOLD_READY \
        FLEET_WALL_TIMEOUT_TEST_HOLD_IN_GRACE \
        FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_LEADER_TRACK \
        FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_WATCHER_TRACK \
        FLEET_WALL_TIMEOUT_TEST_HOLD_BEFORE_WAIT \
        FLEET_WALL_TIMEOUT_TEST_HOLD_AFTER_LEADER_WAIT \
        FAKE_GH_STATE GIBSON_GH_MUTATION_LOG
  export TMPDIR="$suite_tmp"
  run_limited "$suite" >"${cap}.out" 2>&1
  ec=$?
  _gs_write_cap
  trap - EXIT INT TERM HUP
}

# --only accepts a comma-separated list of substrings; any match selects.
suite_selected() {
  local name="$1" rest="$ONLY" pat
  [[ -n "$rest" ]] || return 0
  while [[ -n "$rest" ]]; do
    pat="${rest%%,*}"
    if [[ "$rest" == *,* ]]; then rest="${rest#*,}"; else rest=""; fi
    [[ -n "$pat" && "$name" == *"$pat"* ]] && return 0
  done
  return 1
}

SELECTED_SUITES=""
for suite in scripts/tests/*.test.sh; do
  name=$(basename "$suite")
  suite_selected "$name" || continue
  SELECTED_SUITES="$SELECTED_SUITES $suite"
done

# Bash 3.2 has no `wait -n`, so reap *any* finished child by polling: a slot
# frees as soon as its suite ends, not when the oldest one does.
reap_finished_suites() {
  local p live=()
  for p in "${suite_pids[@]+"${suite_pids[@]}"}"; do
    if kill -0 "$p" 2>/dev/null; then
      live+=("$p")
    else
      wait "$p" 2>/dev/null
    fi
  done
  suite_pids=("${live[@]+"${live[@]}"}")
}

echo "  (running up to $JOBS suites concurrently)"
for suite in $SELECTED_SUITES; do
  [[ -x "$suite" ]] || continue
  while [[ "${#suite_pids[@]}" -ge "$JOBS" ]]; do
    reap_finished_suites
    [[ "${#suite_pids[@]}" -ge "$JOBS" ]] && sleep 0.2
  done
  run_suite_captured "$suite" "$SUITE_CAPTURE_DIR/$(basename "$suite")" &
  suite_pids+=("$!")
done
for pid in "${suite_pids[@]+"${suite_pids[@]}"}"; do
  wait "$pid" 2>/dev/null
done

for suite in $SELECTED_SUITES; do
  name=$(basename "$suite")

  if [[ ! -x "$suite" ]]; then
    echo "${RED}  FAIL${OFF} — $name is not executable"
    FAILED="$FAILED $name"
    gibson_metrics_contribute "" "$name" || true
    continue
  fi

  cap="$SUITE_CAPTURE_DIR/$name"
  if [[ -s "$cap.ec" ]]; then
    out=$(cat "$cap.out"); ec=$(cat "$cap.ec")
    suite_elapsed=$(cat "$cap.elapsed" 2>/dev/null || echo 0)
  else
    out="run-all: suite produced no exit-code capture (runner crashed?)"; ec=1
    suite_elapsed=0
  fi
  # Overlay timeout classification after the capture-to-locals seam that
  # bash32-syntax-each.test.sh pins. Wall-budget kills must not surface as
  # "no tally line" (#319 AC4). Grep the file, never echo "$out" (ARG_MAX).
  gibson_suite_read_capture "$cap" "$TIMEOUT"
  out="$_gs_out"
  ec="$_gs_ec"
  suite_elapsed="$_gs_elapsed"
  tally="$_gs_tally"
  gibson_metrics_contribute "$out" "$name" || true

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
      head -20 || true)
  fi

  if [[ "$QUIET" -eq 0 && ( "$ec" -ne 0 || -n "$shell_diag" ) ]]; then
    printf '%s\n' "$out" | grep -E '^\s*FAIL|unbound variable|command not found|:[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]+not found' |
      head -20 | sed 's/^/         /' || true
  fi

  # gibson_suite_loop_diag begin
  # Require/forward the bash32 bench receipt only when the focused suite is
  # nominally clean (exit 0, no shell-construction diagnostic). Nonzero exit
  # and shell_diag keep their existing timeout/tally/quarantine/ordinary
  # branches and must never print a benchmark receipt.
  bash32_bench_ok=1
  bash32_bench_line=""
  if [[ "$name" == "bash32-syntax-each.test.sh" && "$ec" -eq 0 && -z "$shell_diag" ]]; then
    bash32_bench_line=$(printf '%s\n' "$out" | gibson_forward_bash32_bench "$ec" "$BASH32_PATHS_SHA256" "$BASH32_DOCKER_USABLE") || bash32_bench_ok=0
  fi

  if [[ "$bash32_bench_ok" -eq 0 ]]; then
    echo "${RED}  FAIL${OFF} — $name: bash 3.2 benchmark receipt missing or invalid (exit $ec, ${suite_elapsed}s)"
    FAILED="$FAILED $name"
  elif [[ -n "$shell_diag" ]]; then
    echo "${RED}  FAIL${OFF} — $name: shell construction diagnostic with tally '$tally' (exit $ec, ${suite_elapsed}s)"
    echo "$shell_diag" | head -6 | sed 's/^/         /'
    FAILED="$FAILED $name"
  elif [[ "$ec" -eq 0 ]]; then
    if is_quarantined "$name"; then
      echo "${RED}  FAIL${OFF} — $name PASSES but is quarantined (#$(quarantine_issue "$name")) — remove it from the list (${suite_elapsed}s)"
      ESCAPED="$ESCAPED $name"
    else
      echo "${GRN}  ok${OFF}   — $name: $tally (${suite_elapsed}s)"
      if [[ -n "$bash32_bench_line" ]]; then
        printf '%s\n' "$bash32_bench_line"
      fi
    fi
  elif is_quarantined "$name"; then
    echo "${YEL}  KNOWN${OFF}— $name: $tally (quarantined, #$(quarantine_issue "$name"), ${suite_elapsed}s)"
    QUARANTINED="$QUARANTINED $name"
  else
    echo "${RED}  FAIL${OFF} — $name: $tally (exit $ec, ${suite_elapsed}s)"
    FAILED="$FAILED $name"
  fi
  # gibson_suite_loop_diag end
done

# --- wall-time budget -------------------------------------------------------
RUN_ALL_WALL=$((SECONDS - RUN_ALL_T0))
if [[ "$WALL_BUDGET" -gt 0 && "$RUN_ALL_WALL" -gt "$WALL_BUDGET" ]]; then
  echo
  echo "${RED}  FAIL${OFF} — wall-budget: gate took ${RUN_ALL_WALL}s, budget ${WALL_BUDGET}s (jobs=$JOBS). Slowest suites:"
  for f in "$SUITE_CAPTURE_DIR"/*.elapsed; do
    [[ -f "$f" ]] || continue
    printf '%s\t%s\n' "$(cat "$f")" "$(basename "${f%.elapsed}")"
  done | sort -rn | head -5 | while IFS="$(printf '\t')" read -r secs sname; do
    printf '         %5ss  %s\n' "$secs" "$sname"
  done
  echo "         Speed the slow suites up or split them; raising the budget is a ratchet loosening and needs owner sign-off."
  FAILED="$FAILED wall-budget"
fi

# --- verdict ----------------------------------------------------------------
echo
gibson_run_all_bind_and_print_verdict
echo "run-all wall: ${RUN_ALL_WALL}s (budget ${WALL_BUDGET}s, jobs=$JOBS)"
gibson_metrics_emit_aggregate_or_fail
exit $?
